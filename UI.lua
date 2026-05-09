local _, ns = ...

local UI = {}
ns.UI = UI

local Utils = ns.Utils
local UIPins = ns.UIPins
local GetButtonText         = Utils.GetButtonText
local SearchFrameTreeFuzzy  = Utils.SearchFrameTreeFuzzy
local ClickButton           = Utils.ClickButton
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower         = Utils.sfind, Utils.slower
local tinsert, tconcat, tremove, tsort = Utils.tinsert, Utils.tconcat, Utils.tremove, Utils.tsort
local mmin, mmax = Utils.mmin, Utils.mmax
local mfloor = Utils.mfloor
local sformat = Utils.sformat

local GOLD_COLOR = ns.GOLD_COLOR
local DEFAULT_OPACITY = ns.DEFAULT_OPACITY
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local GetCursorPosition  = GetCursorPosition
local InCombatLockdown   = InCombatLockdown
local wipe               = wipe

local REP_BAR_WIDTH = 100

local searchFrame
local resultsFrame
-- Combined-frame backdrop: rounded-rect 9-slice that wraps the bar
-- alone (collapsed to a pill when results are hidden) or the bar
-- plus the results dropdown (rounded rectangle when open). Sibling
-- of searchFrame, anchored to it; grows downward to cover
-- resultsFrame when ShowHierarchicalResults runs.
local containerFrame
local resultButtons = {}
local MAX_BUTTON_POOL = 100
-- Hard render cap on the search-match portion of the result list. Pinned
-- items are counted separately. Pre-render cap in OnSearchTextChanged
-- already trims to 15 before flattening; this is a backstop for any
-- other call path (alias views, container expansion) that lands here.
local MAX_SEARCH_RESULT_ROWS = 15
local EnsureResultButton
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult
local deferredRepRefreshPending = false  -- deferred re-render to let IsTruncated() settle
local idleTrimSerial = 0
local outfitCdStart, outfitCdDuration = 0, 0  -- shared outfit swap cooldown
local lastEquippedOutfitID                     -- tracks most recent equip for immediate green tint

-- Shell-style search history. historyIndex 0 == "live" buffer (whatever
-- the user has actually typed). Stepping UP increments toward older
-- entries; DOWN decrements back toward 0. Once we hit 0, the next DOWN
-- key falls through to the result-navigation path so the user can drop
-- into the highlighted result row without an extra keystroke.
local historyIndex = 0
local historyDraft = ""           -- User's in-flight text, restored when stepping back to index 0

-- LEFT-side category icons for flat mode. Collection items (mounts, toys,
-- etc.) push their item-specific icon to the right side of the row, leaving
-- the left empty; we fill it with the same icon used in the filter dropdown
-- so each row carries an at-a-glance category cue. Numeric entries are
-- texture FileDataIDs; strings are texture paths or atlas names (atlas key).
local FLAT_CATEGORY_ICONS = {
    mount         = { tex = 132261 },
    toy           = { tex = 454046 },
    pet           = { tex = 631719 },
    outfit        = { tex = 132649 },
    heirloom      = { tex = 133877 },
    appearanceSet = { tex = "Interface\\Icons\\INV_Helmet_03" },
    currency      = { tex = 136452 },  -- Same coin/AH glyph the map uses
    reputation    = { tex = 1121272, coords = { 0.3783, 0.4072, 0.9066, 0.9350 } },
    map           = { tex = 1121272, coords = { 0.3457, 0.3856, 0.2549, 0.2951 } },
    -- Ability / boss: matches the filter-menu icons (boss tab + overview tab
    -- glyphs from the Encounter Journal spritesheet). The row's per-entry
    -- icon (spell icon / boss portrait) is pushed to the RIGHT side.
    ability       = { tex = 522972, coords = { 0.904, 0.996, 0.707, 0.748 } },
    boss          = { tex = 522972, coords = { 0.855, 0.949, 0.524, 0.566 } },
    talent        = { atlas = "UI-HUD-MicroMenu-SpellbookAbilities-Up" },
    achievement   = { atlas = "UI-HUD-MicroMenu-Achievements-Up" },
    macro         = { tex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    bag           = { atlas = "bag-main" },
    loot          = { tex = 522972, coords = { 0.730, 0.824, 0.618, 0.660 } },
    setting       = { atlas = "QuestLog-icon-setting" },
    -- Addon settings get a warm tint so they're distinguishable at a
    -- glance from the silvery-grey game-settings cogwheel.
    settingAddon  = { atlas = "QuestLog-icon-setting", color = { 1.0, 0.78, 0.35 } },
    title         = { tex = 514608, coords = { 0.016, 0.531, 0.324, 0.461 } },
    -- Resolved lazily from PaperDollSidebarTab3 so the icon always
    -- matches whatever sprite-sheet region Blizzard uses for the
    -- Equipment Manager sidebar tab. Filled in by ResolveGearSetIcon().
    gearSet       = { atlas = "equipmentmanager-spec-border" },
}

local function ResolveGearSetIcon()
    local entry = FLAT_CATEGORY_ICONS.gearSet
    if entry and entry._resolved then return end
    local tab = _G["PaperDollSidebarTab3"]
    if not tab or not tab.GetRegions then return end
    for ri = 1, select("#", tab:GetRegions()) do
        local region = select(ri, tab:GetRegions())
        if region and region:GetObjectType() == "Texture"
           and region:GetDrawLayer() == "ARTWORK" then
            local tex = region:GetTexture()
            if tex and not (type(tex) == "string" and tex:find("^RT")) then
                local ulX, ulY, _, _, _, _, lrX, lrY = region:GetTexCoord()
                FLAT_CATEGORY_ICONS.gearSet = {
                    tex = tex,
                    coords = { ulX, lrX, ulY, lrY },
                    _resolved = true,
                }
            end
            return
        end
    end
end

-- Reputation icon by faction side. Either-faction (nil) uses the same
-- crest as the filter button; Alliance/Horde get their faction-specific
-- crests. All cropped from the shared 1121272 sprite sheet.
local REP_FACTION_ICONS = {
    alliance = { tex = 1121272, coords = { 0.4740, 0.5055, 0.8371, 0.8706 } },
    horde    = { tex = 1121272, coords = { 0.4743, 0.5058, 0.8707, 0.9042 } },
    either   = { tex = 1121272, coords = { 0.3783, 0.4072, 0.9066, 0.9350 } },
}

local function GetFlatCategoryIcon(data)
    if not data then return nil end
    if data.mountID then return FLAT_CATEGORY_ICONS.mount end
    if data.toyItemID then return FLAT_CATEGORY_ICONS.toy end
    if data.petID then return FLAT_CATEGORY_ICONS.pet end
    if data.outfitID then return FLAT_CATEGORY_ICONS.outfit end
    if data.heirloomItemID then return FLAT_CATEGORY_ICONS.heirloom end
    if data.transmogSetID then return FLAT_CATEGORY_ICONS.appearanceSet end
    if data.spellID and data.category == "Ability" then return FLAT_CATEGORY_ICONS.ability end
    if data.category == "Talent" then return FLAT_CATEGORY_ICONS.talent end
    if data.achievementID and data.category == "Achievement" then return FLAT_CATEGORY_ICONS.achievement end
    if data.encounterID and data.category == "Boss" then return FLAT_CATEGORY_ICONS.boss end
    if data.macroIndex and data.category == "Macro" then return FLAT_CATEGORY_ICONS.macro end
    if data.bagID and data.category == "Bag" then return FLAT_CATEGORY_ICONS.bag end
    if data.itemID and data.category == "Loot" then return FLAT_CATEGORY_ICONS.loot end
    if data.category == "Game Settings" then return FLAT_CATEGORY_ICONS.setting end
    if data.category == "AddOn Settings" then return FLAT_CATEGORY_ICONS.settingAddon end
    if data.category == "Currency" then return FLAT_CATEGORY_ICONS.currency end
    if data.titleID then return FLAT_CATEGORY_ICONS.title end
    if data.gearSetID then
        ResolveGearSetIcon()
        return FLAT_CATEGORY_ICONS.gearSet
    end
    if data.category == "Reputation" and data.factionID then
        return REP_FACTION_ICONS[data.factionSide or "either"]
    end
    if data.mapSearchResult then return FLAT_CATEGORY_ICONS.map end
    return nil
end

-- Compose the small subtext shown under a flat-list result (Alfred-style).
-- UI entries get their breadcrumb path; collection items and map results fall
-- back to a category label or zone name so every row carries some context.
-- Abbreviate a binding string for display in the inline keybind buttons.
-- "SHIFT-PAGEDOWN" -> "S-PgDn", etc. WoW returns keynames in
-- MODIFIER-KEY uppercase form; we only shorten the parts that commonly
-- overflow the 60-ish-px keybind button.
local KEY_ABBREV = {
    SHIFT = "S", CTRL = "C", ALT = "A", META = "M",
    PAGEDOWN = "PgDn", PAGEUP = "PgUp",
    HOME = "Home", END = "End",
    DELETE = "Del", INSERT = "Ins",
    BACKSPACE = "BkSp", SPACE = "Spc",
    ESCAPE = "Esc", ENTER = "Ent",
    PRINTSCREEN = "PrtSc",
    MOUSEWHEELUP = "MWU", MOUSEWHEELDOWN = "MWD",
    BUTTON3 = "MB3", BUTTON4 = "MB4", BUTTON5 = "MB5",
}
local function AbbrevBinding(binding)
    if not binding or binding == "" then return "Not Bound" end
    local out = {}
    for part in binding:gmatch("[^%-]+") do
        local up = part:upper()
        local short = KEY_ABBREV[up]
        if not short then
            -- NUMPAD0-9 -> Num0, NUMPADDIVIDE -> Num/, etc.
            local n = up:match("^NUMPAD(%d)$")
            if n then short = "Num" .. n end
        end
        out[#out + 1] = short or part
    end
    return table.concat(out, "-")
end

-- Set a FontString's text and append "..." when the rendered string
-- exceeds the FontString's anchor-bounded width. Used for result-row
-- titles and any other single-line label that must clip cleanly
-- instead of overflowing into the next row's space (WoW doesn't
-- auto-add ellipses for anchor-clipped FontStrings).
local function SetClippedText(fs, text)
    if not fs then return end
    fs:SetText(text or "")
    if not text or text == "" then return end
    -- Use anchor-derived bounds (GetLeft / GetRight) instead of
    -- GetWidth(): GetWidth() on an L+R anchored FontString can return
    -- the natural string width when the text overflows, which then
    -- causes the trim loop to stop at a string that's far shorter than
    -- the actual visible bound (premature ellipsis with empty space
    -- before the next element).
    local left, right = fs:GetLeft(), fs:GetRight()
    local maxW
    if left and right and right > left then
        maxW = right - left
    else
        maxW = fs:GetWidth() or 0
    end
    if not maxW or maxW <= 0 then return end
    local getW = fs.GetUnboundedStringWidth
    local strW = getW and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
    if strW <= maxW then return end
    for cut = #text - 1, 1, -1 do
        local trimmed = text:sub(1, cut) .. "..."
        fs:SetText(trimmed)
        local w = getW and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
        if w <= maxW then return end
    end
end

local function GetFlatSubtext(data)
    if not data then return "" end
    if data.path and #data.path > 0 then
        local cat = data.category
        if data.achievementID or cat == "Achievement" or cat == "Achievements" then
            return data.path[#data.path]
        end
        return tconcat(data.path, " > ")
    end
    if data.mapSearchResult then
        local cat = data.category
        local typeLabel
        if cat == "dungeon" then typeLabel = "Dungeon"
        elseif cat == "raid" then typeLabel = "Raid"
        elseif cat == "delve" then typeLabel = "Delve"
        end
        -- Use only the immediate parent zone, not the full continent path.
        -- pathPrefix can be "Continent > Region > Zone"; take the last segment.
        local zone = data.zoneName or data.pathPrefix
        if zone then
            local lastSep = zone:find(">[^>]*$")
            if lastSep then
                zone = zone:sub(lastSep + 1):match("^%s*(.-)%s*$")
            end
        end
        if typeLabel and zone and zone ~= "" then
            return typeLabel .. ": " .. zone
        elseif typeLabel then
            return typeLabel
        end
        return zone or "Map"
    end
    if data.mountID then return "Mount" end
    if data.toyItemID then return "Toy" end
    if data.petID then return "Pet" end
    if data.outfitID then return "Outfit" end
    if data.heirloomItemID then return "Heirloom" end
    if data.transmogSetID then return "Appearance Set" end
    if data.itemID and data.category == "Loot" then
        return data.lootInstanceName or "Loot"
    end
    if data.category == "Ability" and data.treeName and data.treeName ~= "" then
        return data.treeName .. " Ability"
    end
    return data.category or ""
end

local function IsSpellbookOnlyAbility(data)
    return data and data.category == "Ability" and data.spellID and data.isSpellbookOnly
end

-- Hint shown only on the currently-selected row, replacing the normal
-- subtext so the user knows what Enter / left-click will do without
-- cluttering every other row. Returns nil for entries whose action
-- isn't worth labelling (UI navigation, settings — the row name itself
-- already tells you what happens).
-- Default tooltip placement for non-gear results. The default UI sets
-- the tooltip's bottom-right corner just up-and-left of the cursor
-- (with a small diagonal buffer so the tooltip doesn't sit literally
-- under the cursor arrow). ANCHOR_CURSOR puts it bottom-center at the
-- cursor instead, so we anchor manually. We also hook OnUpdate to
-- track cursor motion while the tooltip is owned by the row, mirroring
-- how default ANCHOR_CURSOR follows the mouse.
local TOOLTIP_CURSOR_OFFSET_X = -8
local TOOLTIP_CURSOR_OFFSET_Y = 16

local function PlaceTooltipBottomRightAtCursor(tooltip)
    tooltip:ClearAllPoints()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    if scale == 0 then scale = 1 end
    tooltip:SetPoint(
        "BOTTOMRIGHT", UIParent, "BOTTOMLEFT",
        (cx / scale) + TOOLTIP_CURSOR_OFFSET_X,
        (cy / scale) + TOOLTIP_CURSOR_OFFSET_Y
    )
end

local function AnchorTooltipAtCursor(tooltip, ownerFrame)
    tooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    PlaceTooltipBottomRightAtCursor(tooltip)
    tooltip._easyFindCursorFollow = ownerFrame
    if not tooltip._easyFindCursorHooked then
        tooltip._easyFindCursorHooked = true
        tooltip:HookScript("OnUpdate", function(self)
            if self._easyFindCursorFollow and self:IsOwned(self._easyFindCursorFollow) then
                PlaceTooltipBottomRightAtCursor(self)
            end
        end)
        tooltip:HookScript("OnHide", function(self)
            self._easyFindCursorFollow = nil
        end)
    end
end

-- Special placement for GEAR tooltips: items render with an attached
-- item-compare frame doubled in width, so cursor-anchored tooltips
-- end up covering the result row that spawned them. Anchor to the
-- search/results panel's outside edge (whichever side has more screen
-- room) so the cursor and our own UI both stay clear.
local function AnchorGearTooltip(tooltip, ownerFrame)
    tooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    tooltip:ClearAllPoints()

    local panel = (resultsFrame and resultsFrame:IsShown()) and resultsFrame
                  or (searchFrame and searchFrame:IsShown()) and searchFrame
                  or ownerFrame

    local left = panel and panel:GetLeft()
    local right = panel and panel:GetRight()
    local top = panel and panel:GetTop()
    local screenW = UIParent:GetWidth() or 0

    if left and right and top and screenW > 0 then
        local roomRight = screenW - right
        local roomLeft = left
        local gap = 8
        if roomRight >= roomLeft then
            tooltip:SetPoint("TOPLEFT", panel, "TOPRIGHT", gap, 0)
        else
            tooltip:SetPoint("TOPRIGHT", panel, "TOPLEFT", -gap, 0)
        end
        return
    end

    -- Fallback when the panel isn't measurable.
    tooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
end

local function GetActionHint(data)
    if not data then return nil end
    if data.titleID then return "Select to apply as your title" end
    if data.mountID then return "Select to summon mount" end
    if data.petID then return "Select to summon pet" end
    if data.toyItemID then
        return data.isToyboxOnly and "Select to show in Toy Box" or "Select to use toy"
    end
    if data.heirloomItemID then return "Select to add heirloom to bags" end
    if data.outfitID then return "Select to wear outfit" end
    if data.gearSetID then return "Select to equip gear set" end
    if data.transmogSetID then return "Select to preview | Ctrl+click to try on" end
    if data.spellID and data.category == "Ability" then
        return IsSpellbookOnlyAbility(data) and "Select to show in spellbook" or "Select to cast"
    end
    if data.macroIndex then return "Select to run macro | Ctrl+click to edit" end
    if data.itemID and data.category == "Bag" then
        -- Only treat items with a real gear slot as "equippable". Some
        -- consumables flunk IsEquippableItem at the database level, so
        -- key off equipLoc directly: empty / NON_EQUIP / AMMO / QUIVER
        -- aren't gear slots and should still read "Select to use".
        local slot = data.equipLoc
        if slot and slot ~= "" and slot ~= "INVTYPE_NON_EQUIP"
           and slot ~= "INVTYPE_AMMO" and slot ~= "INVTYPE_QUIVER" then
            return "Select to equip item"
        end
        -- Containers / quest items / wrapped boxes: the right-click
        -- action opens the contents, not "use". GetItemInfo returns the
        -- item type as the 6th value.
        if GetItemInfo then
            local itemType = select(6, GetItemInfo(data.itemID))
            if itemType == "Container" or itemType == "Quest" then
                return "Select to open item"
            end
        end
        return "Select to use item"
    end
    if data.mapSearchResult then
        if data.isZone then return "Select to open map to location" end
        return "Select to pin location on map"
    end
    if data.encounterID and data.category == "Boss" then
        return "Select to open Encounter Journal"
    end
    if data.settingType == "checkbox" and data.settingVariable then
        return "Select to toggle | Ctrl+click to open settings menu"
    end
    if data.settingVariable or data.bindingAction then
        return "Select to open settings menu"
    end
    return nil
end

-- Tracks the row currently displaying an action hint so we can restore
-- its normal subtext when selection moves away.
local actionHintRow

-- Restore the canonical pathSubtext on the row currently showing a hint.
local function ClearActionHint()
    if actionHintRow and actionHintRow.pathSubtext then
        actionHintRow.pathSubtext:SetText(GetFlatSubtext(actionHintRow.data))
        actionHintRow.pathSubtext:SetTextColor(0.55, 0.55, 0.55, 1.0)
    end
    actionHintRow = nil
end

-- Apply the action hint to a row's pathSubtext if one exists for its
-- data. Restores any previously hinted row first so only one row carries
-- a hint at a time.
local function ApplyActionHint(row)
    if not row or not row.pathSubtext or not row.pathSubtext:IsShown() then return end
    local hint = GetActionHint(row.data)
    if not hint then return end
    if actionHintRow == row then return end
    ClearActionHint()
    row.pathSubtext:SetText(hint)
    row.pathSubtext:SetTextColor(0.85, 0.78, 0.55, 1.0)
    actionHintRow = row
end

local GetAllPins = UIPins.GetAll
local IsUIItemPinned = UIPins.IsPinned
local PinUIItem = UIPins.Pin
local UnpinUIItem = UIPins.Unpin
UI.PinUIItem = PinUIItem
UI.UnpinUIItem = UnpinUIItem

-- Apply a full transmog set to the DressUpFrame using Blizzard's own
-- DressUpTransmogSet. The function's first parameter is misleadingly named
-- "setID" in older docs but actually takes a table of itemModifiedAppearanceIDs
-- (the sources to dress up). Passing a raw setID into it is the mistake that
-- makes Blizzard's code appear broken.
function UI:DressUpAppearanceSet(setID)
    if not setID or not C_TransmogSets then return end

    local allIDs = C_TransmogSets.GetAllSourceIDs
        and C_TransmogSets.GetAllSourceIDs(setID)
    if not allIDs or #allIDs == 0 then
        EasyFind:Print("could not load sources for this appearance set.")
        return
    end

    if DressUpTransmogSet then
        DressUpTransmogSet(allIDs)
    end
end


function UI:SyncOutfitPins()
    UIPins.SyncOutfits()
end

local function ShowPinPopup(_, isPinned, onPinAction, onGuide, onAddAlias, extra)
    Utils.ShowPinMenu("EasyFindPinPopup", isPinned, onPinAction, onGuide, onAddAlias, {
        strata = "TOOLTIP",
        level = 100,
        width = 96,
        rowHeight = 22,
    }, extra)
end

local unearnedTooltip

local function ClearResultTooltips()
    if unearnedTooltip then unearnedTooltip:Hide() end
    if BattlePetTooltip then BattlePetTooltip:Hide() end
    if GameTooltip then
        for i = 1, #resultButtons do
            local row = resultButtons[i]
            if row then
                if row.toyTooltipTicker then
                    row.toyTooltipTicker:Cancel()
                    row.toyTooltipTicker = nil
                end
                if GameTooltip:IsOwned(row) then
                    GameTooltip:Hide()
                end
            end
        end
    end
    if ns.MapSearch and ns.MapSearch.ClearUIPreview then
        ns.MapSearch:ClearUIPreview()
    end
end

local function SetRowIcon(btn, kind, value, iconSize)
    local sz = iconSize or 16
    btn.icon:SetTexture(nil)
    btn.icon:SetTexCoord(0, 1, 0, 1)
    btn.icon:SetVertexColor(1, 1, 1, 1)
    -- Clear mount/toy/pet tooltip data and cooldown from previous render
    btn.icon.mountID = nil
    btn.icon.toyItemID = nil
    btn.icon.petID = nil
    btn.icon.spellID = nil
    btn.icon.outfitID = nil
    btn.icon.heirloomItemID = nil
    btn.icon.bagItemID = nil
    btn.icon.lootItemID = nil
    if btn.iconCooldown then btn.iconCooldown:Hide() end
    if btn._lockOverlay then btn._lockOverlay:Hide() end
    if kind == "atlas" then
        btn.icon:SetAtlas(value)
    elseif kind == "file" or kind == "path" then
        if type(value) == "table" and value.file then
            btn.icon:SetTexture(value.file)
            if value.coords then
                local c = value.coords
                btn.icon:SetTexCoord(c[1], c[2], c[3], c[4])
            end
        else
            btn.icon:SetTexture(value)
        end
    elseif kind == "hidden" then
        btn.icon:Hide()
        return
    end
    btn.icon:SetSize(sz, sz)
    btn.icon:Show()
end

local selectedIndex = 0   -- 0 = none selected, 1..N = highlighted row
local toggleFocused = false -- true = Tab moved focus to expand/collapse toggle
local navFrame             -- Keyboard capture frame for results navigation
local escCatcher           -- UISpecialFrames fallback for second-ESC-to-close
local activeKeybindBtn

-- THEME DEFINITIONS
local THEMES = {}

-- Modern: quest-log style - raised tab headers, golden tree lines, grey border
THEMES["Modern"] = {
    rowHeight       = 20,
    indentPx        = 20,          -- matches INDENT_PX so tree lines align
    lineWidth       = 2,
    resultsWidth    = 350,
    resultsPadTop   = 8,
    resultsPadBot   = 8,
    resultsPadLeft  = 12,
    btnWidth        = 366,
    iconSize        = 15,
    pathIconSize    = 13,
    -- fonts
    pathFont        = ns.SEARCHBAR_FONT,
    leafFont        = ns.LEAF_FONT,
    pathColor       = {0.65, 0.60, 0.55, 1.0},   -- muted gray-tan (normal state)
    pathColorHover  = {1.0, 1.0, 1.0, 1.0},      -- white (hover state)
    leafColor       = {0.9, 0.9, 0.9},           -- light grey items
    -- tree lines - warm gold (single colour at every depth)
    showTreeLines   = false,
    indentColors    = {
        {0.85, 0.65, 0.15, 0.80},
        {0.85, 0.65, 0.15, 0.80},
        {0.85, 0.65, 0.15, 0.80},
        {0.85, 0.65, 0.15, 0.80},
        {0.85, 0.65, 0.15, 0.80},
        {0.85, 0.65, 0.15, 0.80},
    },
    -- icons for collapse/expand (Classic left-side only)
    expandIcon      = "Interface\\Buttons\\UI-PlusButton-Up",
    collapseIcon    = "Interface\\Buttons\\UI-MinusButton-Up",
    -- highlight
    highlightTex    = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    selectionColor  = {0.25, 0.5, 0.9, 0.35},
    -- header bar disabled (headerTab used instead)
    showHeaderBar   = false,
    -- header tab: quest-log style with atlas textures
    showHeaderTab   = false,
    headerTabAtlas  = "QuestLog-tab",             -- WoW atlas for tab background
    headerHighlightAlpha = 0.40,                  -- highlight layer alpha
    -- +/- button atlases
    expandAtlas     = "QuestLog-icon-expand",     -- plus sign atlas
    collapseAtlas   = "QuestLog-icon-shrink",     -- minus sign atlas
    toggleNormalAlpha = 0.60,                     -- muted yellow (normal state)
    toggleHoverAlpha  = 1.0,                      -- bright yellow (hover state)
    -- separators off
    showSeparators  = false,
    separatorColor  = {0.5, 0.45, 0.3, 0.35},
    -- results backdrop - grey tooltip border, quest log background
    resultsBackdrop = {
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    },
    resultsBgAtlas          = "QuestLog-main-background",    -- quest log dark background
    resultsBackdropColor       = {0.12, 0.10, 0.08, 0.95},
    resultsBackdropBorderColor = {0.50, 0.48, 0.45, 1.0},   -- grey
    -- search bar style
    searchBarRounded = true,   -- rounded Common-Input-Border style
}

local function GetActiveTheme()
    return THEMES["Modern"]
end

local function ScaleFont(fontString, baseFontObject)
    if not fontString then return end
    local obj = _G[baseFontObject]
    if not obj then return end
    local path, baseSize, flags = obj:GetFont()
    fontString:SetFont(path, baseSize * (EasyFind.db.fontSize or 1.0), flags)
    fontString:SetJustifyH(fontString:GetJustifyH())
end

local function SetScaledFont(fontString, baseFontObject)
    if not fontString then return end
    fontString:SetFontObject(baseFontObject)
    ScaleFont(fontString, baseFontObject)
end

local function ApplyResultRowFonts(row, theme)
    if not row then return end
    theme = theme or GetActiveTheme()
    ScaleFont(row.text, theme.leafFont)
    ScaleFont(row.tabText, theme.pathFont)
    ScaleFont(row.sectionLabelText, "GameFontNormalSmall")
    ScaleFont(row.pathSubtext, theme.leafFont)
    ScaleFont(row.amountText, "GameFontNormalSmall")
    ScaleFont(row.repBarText, "GameFontNormalSmall")
    ScaleFont(row.settingSliderValue, "GameFontNormalSmall")
end

function UI:CreateUnearnedTooltip()
    -- Create simple tooltip frame
    unearnedTooltip = CreateFrame("Frame", "EasyFindUnearnedTooltip", UIParent, "BackdropTemplate")
    unearnedTooltip:SetFrameStrata("TOOLTIP")
    unearnedTooltip:SetFrameLevel(9999)
    unearnedTooltip:SetClampedToScreen(true)

    -- Simple black background with border
    unearnedTooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    unearnedTooltip:SetBackdropColor(0, 0, 0, 0.95)
    unearnedTooltip:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    -- Text with larger font
    local text = unearnedTooltip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    text:SetText("Currency not yet earned")
    text:SetTextColor(1, 1, 1, 1)
    unearnedTooltip.text = text

    -- Auto-size tooltip to fit text with padding
    local textWidth = text:GetStringWidth()
    local textHeight = text:GetStringHeight()
    unearnedTooltip:SetSize(textWidth + 20, textHeight + 16)  -- Add padding

    unearnedTooltip:Hide()
end

function UI:Initialize()
    self:CreateUnearnedTooltip()
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    self:RegisterCombatEvents()
    self:HookBlizzardFilterChanges()

    if EasyFind.db.autoHide then
        searchFrame:Hide()
    elseif EasyFind.db.visible ~= false then
        searchFrame:Show()
        if EasyFind.db.smartShow then
            searchFrame.hoverZone:Show()
            searchFrame:SetAlpha(0)
            searchFrame.setSmartShowVisible(false)
        end
    else
        searchFrame:Hide()
        if EasyFind.db.smartShow then
            searchFrame.hoverZone:Show()
        end
    end

    inCombat = InCombatLockdown()
    if inCombat then
        searchFrame:Hide()
    end

    self:UpdateScale()
    self:UpdateWidth()
    self:UpdateFontSize()

    -- Block auto-focus on creation - WoW may focus visible EditBoxes after creation.
    -- Block for two frames (enough for WoW's auto-focus to fire and get rejected).
    searchFrame.editBox.blockFocus = true
    searchFrame.editBox:ClearFocus()
    C_Timer.After(0, function()
        C_Timer.After(0, function()
            if searchFrame and searchFrame.editBox then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:ClearFocus()
            end
        end)
    end)

    -- First-run wizard for new installs (sleek central modal, no in-place
    -- overlay). Bar stays hidden until the user finishes the tutorial.
    if not EasyFind.db.tutorialDone then
        C_Timer.After(0.3, function()
            if ns.Wizard and ns.Wizard.Show then ns.Wizard:Show() end
        end)
    end

end

function UI:WarmSearchHotPath()
    for i = 1, MAX_BUTTON_POOL do
        EnsureResultButton(i):Hide()
    end
end

function UI:RegisterCombatEvents()
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    ns.eventFrame:HookScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            inCombat = true
            searchFrame:Hide()
            searchFrame.hoverZone:Hide()
            UI:HideResults()
            searchFrame.editBox:ClearFocus()
        elseif event == "PLAYER_REGEN_ENABLED" then
            inCombat = false
            -- autoHide stays hidden after combat; reopens via bind.
            if not EasyFind.db.autoHide then
                if EasyFind.db.visible ~= false then
                    searchFrame:Show()
                    if EasyFind.db.smartShow then
                        searchFrame.hoverZone:Show()
                        searchFrame:SetAlpha(0)
                        searchFrame.setSmartShowVisible(false)
                    end
                elseif EasyFind.db.smartShow then
                    searchFrame.hoverZone:Show()
                end
            end
        end
    end)
end

function UI:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "EasyFindSearchFrame", UIParent, "BackdropTemplate")
    UI.searchFrame = searchFrame
    searchFrame:SetSize(250, ns.SEARCHBAR_HEIGHT)
    -- FULLSCREEN_DIALOG keeps the search bar above the default UI's
    -- DIALOG-strata menus (Game Menu, Options panel, etc.) so opening
    -- the bar from inside any in-game menu still puts our results on
    -- top instead of getting buried.
    searchFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetClampedToScreen(true)

    -- Apply saved position or default
    if EasyFind.db.uiSearchPosition then
        local pos = EasyFind.db.uiSearchPosition
        searchFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -12)
    end

    local theme = GetActiveTheme()
    ns.CreateSearchBorder(searchFrame)

    -- Combined visual frame: 9-slice rounded rect that morphs from a
    -- pill (results closed: height == bar height) to a rounded
    -- rectangle (results open: height == bar height + results panel
    -- height). Sibling of searchFrame at the same frame level - 1 so
    -- its draw layers sit behind the bar's content; anchored to
    -- searchFrame so it follows movement / resizing.
    containerFrame = CreateFrame("Frame", "EasyFindContainerFrame", UIParent)
    UI.containerFrame = containerFrame
    containerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    containerFrame:SetFrameLevel(math.max(0, searchFrame:GetFrameLevel() - 1))
    containerFrame:SetPoint("TOPLEFT",  searchFrame, "TOPLEFT",  0, 0)
    containerFrame:SetPoint("TOPRIGHT", searchFrame, "TOPRIGHT", 0, 0)
    containerFrame:SetPoint("BOTTOM",   searchFrame, "BOTTOM",   0, 0)
    ns.CreateRoundedRectBorder(containerFrame)
    ns.CreateRoundedRectDivider(containerFrame)
    ns.SetRoundedRectBarHeight(containerFrame, searchFrame:GetHeight())

    -- Sibling-of-searchFrame so the container's textures sit BEHIND
    -- the bar's content (children would render in front). The trade-
    -- off is that searchFrame:Hide / :Show no longer cascades, so
    -- mirror visibility by hand. Same for alpha so SmartShow fades
    -- match.
    searchFrame:HookScript("OnShow", function() containerFrame:Show() end)
    searchFrame:HookScript("OnHide", function() containerFrame:Hide() end)
    hooksecurefunc(searchFrame, "SetAlpha", function(_, a)
        containerFrame:SetAlpha(a or 1)
    end)
    if not searchFrame:IsShown() then containerFrame:Hide() end

    searchFrame:SetBackdrop(nil)
    -- Pill on searchFrame is hidden; the container provides the
    -- visual now. Pill setup is still kept (CreateSearchBorder
    -- above) so anything that pokes searchFrame.searchBorder
    -- doesn't crash, but the textures stay invisible.
    ns.SetSearchBorderShown(searchFrame, false)
    ns.SetRoundedRectBorderShown(containerFrame, true)
    ns.SetRoundedRectBorderBgAlpha(containerFrame, EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)

    -- Static magnifying-glass icon (non-interactive, flush left)
    local contentSz = ns.SEARCHBAR_HEIGHT * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE

    local iconHolder = CreateFrame("Frame", nil, searchFrame)
    iconHolder:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    iconHolder:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    iconHolder:SetPoint("LEFT", searchFrame, "LEFT", 0, 0)
    iconHolder:SetWidth(searchFrame:GetHeight())
    iconHolder:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    local searchIcon = iconHolder:CreateTexture(nil, "OVERLAY")
    searchIcon:SetSize(iconSz, iconSz)
    searchIcon:SetPoint("CENTER")
    searchIcon:SetAtlas("common-search-magnifyingglass")
    iconHolder.icon = searchIcon
    searchFrame.searchIcon = searchIcon
    searchFrame.modeBtn = iconHolder

    -- Editbox
    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetHeight(contentSz)
    editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", searchFrame, "RIGHT", -8, 0)
    editBox:SetFontObject(ns.SEARCHBAR_FONT)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)

    -- Editbox click handling: plain left-click focuses the input
    -- (native behavior). Shift+left-click drags the bar -- the
    -- editbox consumes presses so the parent's RegisterForDrag never
    -- fires over the input area; the drag has to live here.
    editBox:HookScript("OnMouseDown", function(self, button)
        if searchFrame.setupMode then
            self.blockFocus = true
            return
        end
        if button ~= "LeftButton" then return end
        if EasyFind.db.lockPosition then return end
        if not IsShiftKeyDown() then return end
        self.blockFocus = true
        self._dragMoving = true
        if self:HasFocus() then self:ClearFocus() end
        searchFrame:StartMoving()
    end)
    editBox:HookScript("OnMouseUp", function(self)
        if self._dragMoving and searchFrame:IsMovable() then
            searchFrame:StopMovingOrSizing()
            local point, _, relPoint, x, y = searchFrame:GetPoint()
            EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
        end
        self._dragMoving = false
        self.blockFocus = nil
    end)


    local placeholder = editBox:CreateFontString(nil, "ARTWORK", ns.SEARCHBAR_FONT)
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetPoint("RIGHT", editBox, "RIGHT", -2, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    placeholder:SetTextColor(0.5, 0.5, 0.5, 1.0)
    placeholder:SetText("Type to search...")
    editBox.placeholder = placeholder

    editBox:SetScript("OnEditFocusGained", function(self)
        if self.blockFocus then
            self:ClearFocus()
            return
        end
        if EasyFind.EnsureDynamicLoaded then EasyFind:EnsureDynamicLoaded() end
        if selectedIndex > 0 then
            selectedIndex = 0
            toggleFocused = false
            UI:UpdateSelectionHighlight(true)
        end
        local text = self:GetText() or ""
        if text == "" then
            UI:ShowPinnedItems()
        else
            -- Refocus with leftover text: select all so the user can
            -- start typing fresh (overwrites) or hit Right Arrow /
            -- Ctrl+L to keep editing from the end.
            self:HighlightText(0, #text)
            self:SetCursorPosition(#text)
            -- Re-show results if they were closed by a prior click-out.
            if resultsFrame and not resultsFrame:IsShown() then
                UI:OnSearchTextChanged(text, true)
            end
        end
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        -- Skip cleanup when SelectResult is actively clearing text/focus
        if selectingResult then return end
        -- Drop any active text highlight (the focus-gained "select all"
        -- or autocomplete suffix) so leftover text doesn't keep its
        -- selection box after we click away. Re-focus re-applies it.
        self:HighlightText(0, 0)
        -- Entering keyboard-nav mode (Enter / DOWN from the search bar)
        -- programmatically yanks focus so navFrame can take the keys.
        -- Don't treat that as a click-outside; the click-outside path
        -- is handled by resultsFrame's GLOBAL_MOUSE_DOWN handler.
        if selectedIndex > 0 then return end
        -- Click on a guard frame (results, dropdown, popups) keeps
        -- the results visible. Anywhere else (including empty world)
        -- hides them in one click instead of needing a second click
        -- after the autocomplete strip.
        local onGuard = false
        if resultsFrame and resultsFrame:IsMouseOver() then onGuard = true end
        if not onGuard then
            local guards = {
                _G["EasyFindUIFilterDropdown"],
                _G["EasyFindPinPopup"],
                _G["EasyFindAsOptionsPopup"],
                _G["EasyFindAsClassPopup"],
                _G["EasyFindGearOptionsPopup"],
                _G["EasyFindDiffPopup"],
                _G["EasyFindSpecPopup"],
                _G["EasyFindSpecFlyout"],
            }
            for _, g in ipairs(guards) do
                if Utils.IsFrameOrChildMouseOver(g) then
                    onGuard = true
                    break
                end
            end
        end
        if not onGuard and resultsFrame and resultsFrame:IsShown() then
            UI:HideResults()
        end
        if strtrim(self:GetText()) == "" then
            self:SetText("")  -- Clear any stray whitespace
            self.placeholder:Show()
            -- Defer hide by one frame so pending pin/result clicks (LeftButtonDown)
            -- can fire before the results frame is hidden.  Without the delay the
            -- parent frame hides and the child button never receives its OnClick.
            C_Timer.After(0, function()
                if selectingResult then return end
                if searchFrame.editBox:HasFocus() then return end
                if navFrame and navFrame:IsKeyboardEnabled() then return end
                if strtrim(searchFrame.editBox:GetText()) ~= "" then return end
                -- Don't hide if spec/class flyouts are open
                local sf = _G["EasyFindSpecFlyout"]
                local ssf = _G["EasyFindSpecSubFlyout"]
                if (sf and sf:IsShown()) or (ssf and ssf:IsShown()) then return end
                local dd = _G["EasyFindUIFilterDropdown"]
                if dd and dd:IsShown() then return end
                UI:HideResults()
                -- Now that results are hidden, let smart show fade the bar out
                if EasyFind.db.smartShow then
                    searchFrame.smartShowFadeOut()
                end
            end)
        end
    end)

    local lastTypedLen = 0
    local lastSearchTime = 0
    local pendingUISearchText = ""
    local pendingUISearchGrew = false
    local pendingUISearchDue = 0
    local pendingUISearchFrame = CreateFrame("Frame")
    pendingUISearchFrame:Hide()
    pendingUISearchFrame:SetScript("OnUpdate", function(self)
        if GetTime() < pendingUISearchDue then return end
        self:Hide()
        local typedNow = pendingUISearchText
        local grew = pendingUISearchGrew
        pendingUISearchText = ""
        pendingUISearchGrew = false
        lastSearchTime = GetTime()
        UI:OnSearchTextChanged(typedNow)
        if grew and editBox.UpdateAutocomplete then
            editBox.UpdateAutocomplete()
        end
    end)
    local SEARCH_THROTTLE = 0.05  -- 50ms cap on search/render frequency
    editBox:SetScript("OnTextChanged", function(self, userInput)
        self.placeholder:SetShown(self:GetText() == "")
        -- Skip every non-user text change. WoW defers OnTextChanged
        -- dispatch by one frame, so by the time the autocomplete's
        -- programmatic SetText fires this handler the in-band
        -- programmatic flag has already been reset to false. The only
        -- reliable signal is the userInput parameter WoW passes us:
        -- true for real keystrokes / paste, false for SetText / Insert
        -- / Clear / etc. Without this gate every keystroke produces
        -- two searches (the user's and the autocomplete suffix's),
        -- doubling per-keystroke cost.
        if not userInput then return end
        if self.IsAutocompleteBackspaceStrip and self:IsAutocompleteBackspaceStrip() then return end
        historyIndex = 0
        historyDraft = ""
        -- Search query is the text up to the cursor -- anything past
        -- the cursor is unaccepted autocomplete suffix and must not
        -- feed into search results. Programmatic autocomplete SetText
        -- is filtered above via IsAutocompleteProgrammatic, so the
        -- cursor read here is always from a real keystroke.
        local cursorPos = self:GetCursorPosition() or #(self:GetText() or "")
        local typedNow = (self:GetText() or ""):sub(1, cursorPos)
        local grew = #typedNow > lastTypedLen
        lastTypedLen = #typedNow
        local elapsed = GetTime() - lastSearchTime
        local delay = elapsed >= SEARCH_THROTTLE and 0 or (SEARCH_THROTTLE - elapsed)
        pendingUISearchText = typedNow
        pendingUISearchGrew = grew
        pendingUISearchDue = GetTime() + delay
        pendingUISearchFrame:Show()
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        -- Strip any visible autocomplete suffix first. WoW's EditBox
        -- swallows the Enter when there's a text selection (treating
        -- it like a "deselect" rather than confirm), so without this
        -- the user's first Enter visually clears the highlight but
        -- doesn't focus the result row — they'd have to press Enter
        -- a second time. Stripping here puts the text back to what
        -- the user typed before WoW's default handler runs.
        if self.StripAutocomplete then self:StripAutocomplete() end
        local typed = strtrim(self:GetText() or "")

        -- /command parser. Anything starting with "/" is treated as a
        -- bar command, not a search query. /reset snaps the bar back to
        -- the top of the screen, /resize opens the drag-to-resize overlay.
        if typed:sub(1, 1) == "/" then
            local cmd = typed:lower():sub(2)
            self:SetText("")
            self.placeholder:Show()
            UI:HideResults()
            if cmd == "reset" or cmd == "resetpos" or cmd == "resetposition" then
                UI:ResetPosition()
                EasyFind:Print("Search bar position reset.")
            elseif cmd == "resize" or cmd == "rescale" then
                if ns.Rescaler and ns.Rescaler.Enter then
                    ns.Rescaler:Enter("ui")
                end
            elseif cmd == "options" or cmd == "o" or cmd == "config" or cmd == "settings" then
                EasyFind:OpenOptions()
            elseif cmd == "tutorial" or cmd == "wizard" or cmd == "welcome" then
                if ns.Wizard and ns.Wizard.Show then
                    EasyFind.db.tutorialDone = false
                    ns.Wizard:Show()
                end
            else
                EasyFind:Print("Unknown command: /" .. cmd)
            end
            return
        end

        if typed ~= "" then
            UI:PushSearchHistory(typed)
        end
        historyIndex = 0
        historyDraft = ""

        -- Enter on the search bar: focus the first result. Prefer the
        -- first non-pinned row so a fresh search jumps past leftover
        -- pinned shortcuts; fall back to the first pinned row when
        -- pinned results are all that's available. A second Enter on
        -- the focused row activates it.
        if selectedIndex == 0 then
            local target, firstPinned
            for i = 1, MAX_BUTTON_POOL do
                local row = resultButtons[i]
                if not row or not row:IsShown() then break end
                if not row.isPinHeader then
                    if row.isPinned then
                        if not firstPinned then firstPinned = i end
                    else
                        target = i
                        break
                    end
                end
            end
            local idx = target or firstPinned
            if not idx then return end
            selectedIndex = idx
            toggleFocused = false
            UI:UpdateSelectionHighlight()
            return
        end
        UI:ActivateSelected()
    end)

    editBox:SetScript("OnEscapePressed", function(_)
        UI:HandleEscape()
    end)

    -- Chrome-style inline autocomplete: same helper MapTab uses.
    -- Attached AFTER all SetScript calls above so HookScript-based
    -- handlers don't get clobbered. The candidate source is the first
    -- visible result row name, so the suggested completion always
    -- aligns with what the user lands on if they press Enter.
    -- Strip WoW inline markup from item / quest names so the autocomplete
    -- suggestion doesn't leak atlas / color / texture / hyperlink codes
    -- ("|A:professions-chaticon-quality-...|a", "|cffrrggbb...|r", etc.).
    -- Markup is usually preceded by a space ("Item Name |A:...|a"); after
    -- stripping the markup, also collapse runs of whitespace and trim the
    -- result so the suggestion ends cleanly.
    local function StripMarkup(s)
        if not s then return s end
        s = s:gsub("|A:[^|]*|a", "")
        s = s:gsub("|T[^|]*|t", "")
        s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        s = s:gsub("|H[^|]+|h(.-)|h", "%1")
        s = s:gsub("%s+", " ")
        s = s:match("^%s*(.-)%s*$") or s
        return s
    end

    Utils.AttachAutocomplete(editBox, {
        findCandidate = function(typed)
            if not typed or typed == "" then return nil end
            local lower = typed:lower()
            for i = 1, MAX_BUTTON_POOL do
                local row = resultButtons[i]
                if not row or not row:IsShown() then break end
                local rawName = row.data and row.data.name
                local nm = StripMarkup(rawName)
                if nm and #nm >= #typed then
                    local prefix = nm:sub(1, #typed):lower()
                    if prefix == lower and nm:lower() ~= lower then
                        return nm
                    end
                end
            end
            return nil
        end,
        onAccepted = function(text)
            if text and text ~= "" then UI:OnSearchTextChanged(text, true) end
        end,
    })

    -- Shift+click link insertion: when the search bar has focus, shift-clicking
    -- an item in bags / an achievement in the achievement frame / a spell in
    -- the spellbook etc. routes the link's display name into our editbox the
    -- same way it does into a chat editbox. ChatEdit_InsertLink is the shared
    -- hook the default UI uses for this; hooking it lets us pick up the link
    -- when our box is the active typing target.
    if not UI._chatLinkHooked then
        UI._chatLinkHooked = true
        hooksecurefunc("ChatEdit_InsertLink", function(text)
            if not text or text == "" then return end
            local box = searchFrame and searchFrame.editBox
            if box and box:IsVisible() and box:HasFocus() then
                -- Strip the hyperlink wrapper so the search engine sees a
                -- plain query string ("Hearthstone" instead of |cff...|H...).
                local name = text:match("|h%[(.-)%]|h") or text
                box:Insert(name)
            end
        end)
    end

    -- Filter button (inside search bar, flush right)
    local filterBtn = CreateFrame("Button", "EasyFindUIFilterButton", searchFrame)
    filterBtn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    filterBtn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    filterBtn:SetPoint("RIGHT", searchFrame, "RIGHT", 0, 0)
    filterBtn:SetWidth(searchFrame:GetHeight())
    -- Sit well above the rounded container's pill border so the filter
    -- button's circular hover/highlight isn't visually clipped by the bar.
    filterBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 50)

    local filterArrow = filterBtn:CreateTexture(nil, "OVERLAY")
    filterArrow:SetSize(11, 11)
    filterArrow:SetPoint("CENTER")
    filterArrow:SetTexture(423808)
    filterArrow:SetTexCoord(0.453, 0.203, 0.453, 0.016, 0.641, 0.203, 0.641, 0.016)
    filterArrow:SetDesaturated(true)
    filterArrow:SetBlendMode("ADD")
    filterArrow:SetVertexColor(1, 1, 1)
    filterBtn.arrow = filterArrow

    local filterBtnBg = filterBtn:CreateTexture(nil, "ARTWORK")
    filterBtnBg:SetAllPoints()
    filterBtnBg:SetTexture(796424)
    filterBtnBg:Hide()
    filterBtn.btnBg = filterBtnBg

    filterBtn:SetHighlightTexture(130757)

    -- Round-pill bar theme: clip the original Blizzard hover/highlight
    -- textures into a circle that fits inside the bar's right-cap
    -- silhouette. AddMaskTexture preserves the originals' colors
    -- (dark hover bg, blue ADD highlight) and just clips the shape.
    if theme.searchBarRounded and filterBtn.CreateMaskTexture then
        local CIRCLE_TEX = "Interface\\AddOns\\EasyFind\\Textures\\FilterButtonCircle"
        -- Inner circle (clips hover bg + highlight) — keep the same radius
        -- as the gold ring's inner edge so the ring sits flush around it.
        local innerInset = 6
        local circleMask = filterBtn:CreateMaskTexture(nil, "ARTWORK")
        circleMask:SetTexture(CIRCLE_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        circleMask:SetPoint("TOPLEFT",     filterBtn, "TOPLEFT",      innerInset, -innerInset)
        circleMask:SetPoint("BOTTOMRIGHT", filterBtn, "BOTTOMRIGHT", -innerInset,  innerInset)
        filterBtnBg:AddMaskTexture(circleMask)
        local hl = filterBtn:GetHighlightTexture()
        if hl and hl.AddMaskTexture then
            hl:AddMaskTexture(circleMask)
        end

        -- Gold perimeter ring: outer gold disc + black inner disc layered
        -- on top so only a thin annulus of gold shows around the inner
        -- circle. Hidden by default and revealed alongside the hover bg
        -- in OnEnter / keyboard focus, so the resting state matches the
        -- pre-ring look. ringInset is just 1px outside the inner circle
        -- to keep the ring stroke thin.
        local ringInset = innerInset - 1
        local ringMask = filterBtn:CreateMaskTexture(nil, "BACKGROUND")
        ringMask:SetTexture(CIRCLE_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        ringMask:SetPoint("TOPLEFT",     filterBtn, "TOPLEFT",      ringInset, -ringInset)
        ringMask:SetPoint("BOTTOMRIGHT", filterBtn, "BOTTOMRIGHT", -ringInset,  ringInset)

        local ringDisc = filterBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
        ringDisc:SetColorTexture(1.0, 0.82, 0.0, 1)
        ringDisc:SetPoint("TOPLEFT",     filterBtn, "TOPLEFT",      ringInset, -ringInset)
        ringDisc:SetPoint("BOTTOMRIGHT", filterBtn, "BOTTOMRIGHT", -ringInset,  ringInset)
        ringDisc:AddMaskTexture(ringMask)
        ringDisc:Hide()

        local ringInner = filterBtn:CreateTexture(nil, "BACKGROUND", nil, 2)
        ringInner:SetColorTexture(0, 0, 0, 1)
        ringInner:SetPoint("TOPLEFT",     filterBtn, "TOPLEFT",      innerInset, -innerInset)
        ringInner:SetPoint("BOTTOMRIGHT", filterBtn, "BOTTOMRIGHT", -innerInset,  innerInset)
        ringInner:AddMaskTexture(circleMask)
        ringInner:Hide()

        filterBtn.ringDisc = ringDisc
        filterBtn.ringInner = ringInner
    end

    local function SetRingShown(self, shown)
        if self.ringDisc then self.ringDisc:SetShown(shown) end
        if self.ringInner then self.ringInner:SetShown(shown) end
    end

    filterBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        SetRingShown(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Filter Results")
        GameTooltip:AddLine("Choose which result types to show.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    filterBtn:SetScript("OnLeave", function(self)
        if not self.keyboardFocused then
            self.btnBg:Hide()
            SetRingShown(self, false)
        end
        GameTooltip_Hide()
    end)
    searchFrame.filterBtn = filterBtn

    -- Anchor editBox right edge to the filter button zone.
    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)

    -- Click anywhere on the search frame to focus the editbox (enables blinking cursor).
    -- Use HookScript to preserve SmartShow OnLeave handlers;
    -- skip focus if SmartShow is active and editbox is empty (prevents the bar getting stuck visible).
    -- Skip when the click landed on one of the toolbar buttons - they have their
    -- own behavior, and stealing keyboard focus here would yank it away from any
    -- other editable frame the player is currently using (chat, mail, /say, etc).
    searchFrame:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or IsShiftKeyDown() or self.setupMode then return end
        if (filterBtn and filterBtn:IsMouseOver())
           or (iconHolder and iconHolder:IsMouseOver()) then
            return
        end
        if activeKeybindBtn and activeKeybindBtn._stopCapture then
            activeKeybindBtn._stopCapture(activeKeybindBtn)
        end
        editBox.blockFocus = nil
        editBox:SetFocus()
    end)

    -- Shared key-repeat helper (also used by MapTab). Attaches its own
    -- OnUpdate to searchFrame; action fires immediately on Start, then
    -- at an accelerating cadence while the key is held.
    local keyRepeat = Utils.CreateKeyRepeat(searchFrame)
    local StartKeyRepeat = keyRepeat.Start
    local StopKeyRepeat  = keyRepeat.Stop
    searchFrame.StartKeyRepeat = StartKeyRepeat
    searchFrame.StopKeyRepeat  = StopKeyRepeat
    searchFrame.IsRepeatKey    = keyRepeat.IsKey

    -- Arrow key / Tab navigation for results dropdown.
    -- IMPORTANT: Block propagation while the editbox has focus so that
    -- typed letters never trigger the player's game keybinds. The one
    -- exception is EasyFind's own bindings (TOGGLE_FOCUS, MAP_FOCUS,
    -- CLEAR): the toggle key has to close the bar from inside the
    -- editbox, otherwise it just types as a character and the user
    -- can't dismiss with the same key they used to open.
    editBox:SetScript("OnKeyDown", function(self, key)
        -- Match the keybind capture's combo format: ALT-CTRL-SHIFT-key.
        -- GetBindingAction is the correct API (GetBindingByKey doesn't
        -- exist) and returns the binding name for a given key combo.
        local mod = ""
        if IsAltKeyDown()     then mod = mod .. "ALT-"  end
        if IsControlKeyDown() then mod = mod .. "CTRL-" end
        if IsShiftKeyDown()   then mod = mod .. "SHIFT-" end
        local boundAction = GetBindingAction and GetBindingAction(mod .. key)
        if boundAction and string.sub(boundAction, 1, 9) == "EASYFIND_" then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            return
        end
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            if key == "RIGHT" or key == "ARROWRIGHT" then
                self:AcceptAutocomplete("right")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            elseif key == "L" and IsControlKeyDown() then
                self:AcceptAutocomplete("ctrl-l")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
        end
        -- ENTER with autocomplete highlight visible: WoW's default
        -- editbox processing treats the first Enter as "deselect"
        -- and silently swallows it without firing OnEnterPressed.
        -- Strip the suggestion now so Enter falls through cleanly
        -- on the user's first press instead of needing two presses.
        if key == "ENTER" and self.StripAutocomplete then
            self:StripAutocomplete()
        end
        -- Shell-style history. UP walks back toward older entries
        -- (capped at the oldest); DOWN walks forward toward newer
        -- entries until we land back on the live draft, then drops
        -- into the results list. Drop-into-results works regardless
        -- of buffer content: the user wants keyboard nav into rows
        -- without having to press Enter first, even mid-edit.
        local isUpHist   = key == "UP"   or (IsControlKeyDown() and (key == "K" or key == "P"))
        local isDownHist = key == "DOWN" or (IsControlKeyDown() and (key == "J" or key == "N"))
        if isUpHist then
            if UI:NavigateSearchHistory(1) then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
            -- At history ceiling: swallow the key so it can't fall
            -- through to result navigation or game keybinds.
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        elseif isDownHist then
            if historyIndex > 0 then
                UI:NavigateSearchHistory(-1)
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
            -- historyIndex == 0 (live draft): fall through to result
            -- nav so DOWN/Ctrl+J jumps into the first row.
        end

        if resultsFrame and resultsFrame:IsShown() and selectedIndex == 0 then
            if EasyFind.db.uiResultsAbove then
                if key == "UP" then UI:JumpToEnd() end
            else
                if key == "DOWN" then UI:MoveSelection(1) end
            end
        end
        -- Ctrl+J/K (and the emacs-equivalent Ctrl+N/P) walk into the
        -- result list once history navigation has been exhausted by
        -- the branch above. Single-step only (no key-repeat) because
        -- MoveSelection transfers keyboard focus to navFrame and the
        -- subsequent KeyUp event gets lost in the focus transition,
        -- leaving the repeat ticker firing forever and cascading
        -- through the entire result list.
        if IsControlKeyDown() then
            if key == "J" or key == "N" then
                UI:MoveSelection(1)
            elseif key == "K" or key == "P" then
                UI:MoveSelection(-1)
            end
        end
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    end)

    -- Mirror the navFrame OnKeyUp: a key whose down event landed on the
    -- editbox needs to terminate its hold-repeat ticker on release here
    -- too, otherwise it keeps stepping after the user lets go.
    editBox:SetScript("OnKeyUp", function(_, key)
        if keyRepeat.IsKey(key) then StopKeyRepeat(key) end
    end)

    searchFrame.editBox = editBox

    -- Toolbar keyboard focus: 0 = editbox, 1+ = toolbar control index
    local toolbarFocus = 0

    local toolbarHighlight = CreateFrame("Frame", nil, UIParent)
    toolbarHighlight:SetFrameStrata("MEDIUM")
    toolbarHighlight:SetFrameLevel(searchFrame:GetFrameLevel() + 100)
    toolbarHighlight:Hide()
    local tbHL = toolbarHighlight:CreateTexture(nil, "OVERLAY")
    tbHL:SetAllPoints()
    tbHL:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    tbHL:SetBlendMode("ADD")
    tbHL:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.5)

    local function GetToolbarControls()
        return { filterBtn }
    end

    local function SetToolbarFocus(idx)
        -- Clear previous button state
        local prevControls = GetToolbarControls()
        local prevTarget = prevControls[toolbarFocus]
        if prevTarget then
            prevTarget.keyboardFocused = nil
            if prevTarget.btnBg then prevTarget.btnBg:Hide() end
            if prevTarget.ringDisc then prevTarget.ringDisc:Hide() end
            if prevTarget.ringInner then prevTarget.ringInner:Hide() end
            if prevTarget.UnlockHighlight then prevTarget:UnlockHighlight() end
        end
        toolbarFocus = idx
        local controls = GetToolbarControls()
        local target = controls[idx]
        if target then
            target.keyboardFocused = true
            if target.btnBg then
                target.btnBg:Show()
                if target.ringDisc then target.ringDisc:Show() end
                if target.ringInner then target.ringInner:Show() end
                if target.LockHighlight then target:LockHighlight() end
                toolbarHighlight:Hide()
            else
                toolbarHighlight:SetParent(target)
                toolbarHighlight:ClearAllPoints()
                toolbarHighlight:SetAllPoints(target)
                toolbarHighlight:Show()
            end
        else
            toolbarHighlight:Hide()
        end
    end

    local function ClearToolbarFocus()
        local controls = GetToolbarControls()
        local prevTarget = controls[toolbarFocus]
        if prevTarget then
            prevTarget.keyboardFocused = nil
            if prevTarget.btnBg then prevTarget.btnBg:Hide() end
            if prevTarget.ringDisc then prevTarget.ringDisc:Hide() end
            if prevTarget.ringInner then prevTarget.ringInner:Hide() end
            if prevTarget.UnlockHighlight then prevTarget:UnlockHighlight() end
        end
        toolbarFocus = 0
        toolbarHighlight:Hide()
    end
    searchFrame.ClearToolbarFocus = ClearToolbarFocus

    -- Keyboard capture frame for navigating results without editbox focus
    navFrame = CreateFrame("Frame", nil, searchFrame)
    navFrame:SetSize(1, 1)
    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
    Utils.SafeCallMethod(navFrame, "SetPropagateKeyboardInput", false)

    -- Cycle focus through editBox → [clearBtn] → filterBtn → row →
    -- toggle button (chevron / pin toggle) and back. Shared by Tab,
    -- Shift+Tab, and the Ctrl+L / Ctrl+H vim aliases below.
    local function CycleFocus(reverse)
        if reverse then
            if selectedIndex > 0 and toggleFocused then
                toggleFocused = false
                UI:UpdateSelectionHighlight()
            elseif toolbarFocus > 0 then
                if toolbarFocus == 1 then
                    ClearToolbarFocus()
                    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                    searchFrame.editBox.blockFocus = nil
                    searchFrame.editBox:SetFocus()
                else
                    SetToolbarFocus(toolbarFocus - 1)
                end
            end
        else
            if selectedIndex > 0 and not toggleFocused then
                local row = resultButtons[selectedIndex]
                local hasToggle = row and row.isPathNode and (
                    (row.headerTab and row.headerTab:IsShown()) or
                    (row.isPinHeader and row.pinToggle and row.pinToggle:IsShown())
                )
                if hasToggle then
                    toggleFocused = true
                    UI:UpdateSelectionHighlight()
                end
            elseif toolbarFocus > 0 then
                local controls = GetToolbarControls()
                if toolbarFocus >= #controls then
                    ClearToolbarFocus()
                    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                    searchFrame.editBox.blockFocus = nil
                    searchFrame.editBox:SetFocus()
                else
                    SetToolbarFocus(toolbarFocus + 1)
                end
            end
        end
    end

    local function HandleNavKeyDown(key)
        if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
           or key == "LALT" or key == "RALT" then return end

        -- Ctrl+H/J/K/L: vim-style nav aliases. J/K = down/up (also
        -- N/P emacs-style); add Shift to jump sections like Shift+Up/Down.
        -- H/L = focus cycle (Shift+Tab / Tab).
        if IsControlKeyDown() and (key == "J" or key == "N") then
            if IsShiftKeyDown() then
                UI:JumpToNextSection(1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(1) end)
            end
            return
        elseif IsControlKeyDown() and (key == "K" or key == "P") then
            if IsShiftKeyDown() then
                UI:JumpToNextSection(-1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(-1) end)
            end
            return
        elseif IsControlKeyDown() and key == "L" then
            CycleFocus(false)
            return
        elseif IsControlKeyDown() and key == "H" then
            CycleFocus(true)
            return
        end

        if key == "DOWN" then
            if IsControlKeyDown() then
                UI:JumpToEnd()
            elseif IsShiftKeyDown() then
                UI:JumpToNextSection(1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(1) end)
            end
        elseif key == "UP" then
            if IsControlKeyDown() then
                UI:JumpToStart()
            elseif IsShiftKeyDown() then
                UI:JumpToNextSection(-1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(-1) end)
            end
        elseif key == "SPACE" then
            -- SPACE on a highlighted group/pin header toggles collapse.
            -- Consumed unconditionally while navigating so it never
            -- leaks through to the editbox (which would otherwise
            -- refocus on the next UpdateSelectionHighlight and insert a
            -- literal space character into the search text).
            --
            -- Toggling also rebuilds the result list (via
            -- ShowHierarchicalResults), which wipes selectedIndex.
            -- Snapshot the row's identity first so the same header can
            -- be re-selected after the rebuild — letting the user spam
            -- Space to collapse/expand without losing selection.
            if selectedIndex > 0 then
                local row = resultButtons[selectedIndex]
                if row then
                    local savedPinHeader    = row.isPinHeader
                    local savedPathName     = row.isPathNode and row.pathNodeName
                    local savedPathDepth    = row.isPathNode and row.pathNodeDepth
                    if row.isPinHeader and row.pinToggle and row.pinToggle:IsShown() then
                        local handler = row.pinToggle:GetScript("OnClick")
                        if handler then handler(row.pinToggle, "LeftButton") end
                    elseif row.toggleBtn and row.toggleBtn:IsShown() then
                        local handler = row.toggleBtn:GetScript("OnClick")
                        if handler then handler(row.toggleBtn, "LeftButton") end
                    end
                    for i = 1, MAX_BUTTON_POOL do
                        local rb = resultButtons[i]
                        if not rb then break end
                        if rb:IsShown() then
                            local match = false
                            if savedPinHeader and rb.isPinHeader then
                                match = true
                            elseif savedPathName and rb.isPathNode
                               and rb.pathNodeName == savedPathName
                               and rb.pathNodeDepth == savedPathDepth then
                                match = true
                            end
                            if match then
                                selectedIndex = i
                                toggleFocused = false
                                UI:UpdateSelectionHighlight()
                                break
                            end
                        end
                    end
                end
            end
            return
        elseif key == "PAGEDOWN" then
            StartKeyRepeat(key, function() UI:MoveSelection(5) end)
        elseif key == "PAGEUP" then
            StartKeyRepeat(key, function() UI:MoveSelection(-5) end)
        elseif key == "HOME" then
            UI:JumpToStart()
        elseif key == "END" then
            UI:JumpToEnd()
        elseif key == "TAB" then
            -- Ring order: editBox → [clearBtn] → filterBtn → wrap back to editBox
            CycleFocus(IsShiftKeyDown())
        elseif key == "ENTER" then
            if toolbarFocus > 0 then
                local controls = GetToolbarControls()
                local target = controls[toolbarFocus]
                if target then target:Click() end
            else
                UI:ActivateSelected()
            end
        elseif key == "ESCAPE" then
            -- Reset nav state inline (toolbarFocus / selectedIndex /
            -- toggleFocused are locals to this closure, so we can't move
            -- this into HandleEscape without exposing them). Then route
            -- through HandleEscape so the same close-menus / clear-text /
            -- hide-bar decision tree runs as the editBox and escCatcher
            -- paths. Single ESC closes the bar when no menus are open.
            if toolbarFocus > 0 then
                ClearToolbarFocus()
            end
            if selectedIndex > 0 or toggleFocused then
                selectedIndex = 0
                toggleFocused = false
                UI:UpdateSelectionHighlight(true)
            end
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
            if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
            UI:HandleEscape()
        else
            -- If no selection and editbox isn't focused, let the key propagate
            -- to the game (e.g. WASD movement) instead of typing into the bar.
            if selectedIndex == 0 and not searchFrame.editBox:HasFocus() then
                Utils.SafeCallMethod(navFrame, "SetPropagateKeyboardInput", true)
                return
            end
            -- Selection is active and a non-nav key was pressed: swallow it.
            -- Previously this branch yanked focus back to the editbox and
            -- inserted the typed character, which felt like the bar was
            -- still capturing input even though the user had committed to
            -- the results list. To type more, press ESC (back to editbox)
            -- or click the bar.
            ClearToolbarFocus()
        end
    end

    navFrame:SetScript("OnKeyDown", function(self, key)
        -- Secure-action rows: let Enter propagate to the override
        -- binding so the secure click dispatch fires (same as a mouse
        -- click). Without this navFrame swallows Enter and the
        -- override binding never sees the key — abilities, mounts,
        -- macros, bag items, toys, outfits all need this gate.
        if key == "ENTER" and selectedIndex > 0 and not InCombatLockdown() then
            local selRow = resultButtons[selectedIndex]
            local rd = selRow and selRow.data
            if rd and (rd.outfitID or rd.toyItemID
               or (rd.spellID and not IsSpellbookOnlyAbility(rd))
               or rd.mountID or rd.macroIndex or rd.slashCommand
               or (rd.itemID and rd.category == "Bag")) then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
                return
            end
        end
        -- Decide whether this key is one we actually use for nav. If
        -- not (e.g. WASD movement, plain SPACE for jumping, ability
        -- bar keys), propagate to the game so the player isn't
        -- stranded just because a result is highlighted.
        local consume = false
        if key == "DOWN" or key == "UP" or key == "PAGEDOWN" or key == "PAGEUP"
            or key == "HOME" or key == "END" or key == "TAB" or key == "ENTER"
            or key == "ESCAPE" then
            consume = true
        elseif IsControlKeyDown() and (key == "J" or key == "N" or key == "K"
            or key == "P" or key == "L" or key == "H") then
            consume = true
        elseif key == "SPACE" then
            -- Only consume SPACE when it would do something here:
            -- toggling the collapse on the focused header. A leaf row
            -- has no toggle, so SPACE means "jump" and must reach the
            -- game.
            local row = selectedIndex > 0 and resultButtons[selectedIndex]
            local hasToggle = row and (
                (row.isPinHeader and row.pinToggle and row.pinToggle:IsShown())
                or (row.toggleBtn and row.toggleBtn:IsShown()))
            if hasToggle then consume = true end
        end
        if consume then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            HandleNavKeyDown(key)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        if keyRepeat.IsKey(key) then StopKeyRepeat(key) end
    end)

    -- UISpecialFrames fallback: shown whenever the search bar is visible so
    -- WoW always has a target for ESC, even after the editbox loses focus
    -- (clicking the filter button, hovering a sub-flyout, etc). WoW Hides
    -- the catcher on ESC; OnHide runs the unified HandleEscape and re-Shows
    -- the catcher if the bar is still open so the next ESC also fires.
    -- Parented to UIParent (not searchFrame) so the OnHide signal isn't
    -- entangled with parent-cascade hides during reload / autoHide flows.
    escCatcher = CreateFrame("Frame", "EasyFindEscCatcher", UIParent)
    escCatcher:SetSize(1, 1)
    escCatcher:Hide()
    tinsert(UISpecialFrames, "EasyFindEscCatcher")
    escCatcher:SetScript("OnHide", function(self)
        if not searchFrame or not searchFrame:IsShown() then return end
        -- editBox having focus means WoW's ESC pipeline already routed to
        -- OnEscapePressed; this OnHide is a side-effect of something else
        -- (autoHide hide, etc) and shouldn't drive ESC behavior.
        if searchFrame.editBox and searchFrame.editBox:HasFocus() then return end
        UI:HandleEscape()
        if searchFrame:IsShown() then self:Show() end
    end)

    -- Tab confirms autocomplete suggestion only. Toolbar nav (clear /
    -- filter buttons) is handled by Left/Right and Ctrl+H/Ctrl+L
    -- elsewhere; routing Tab into it stomped the autocomplete confirm.

    -- Plain drag moves the bar (no modifier required). Lock Position
    -- in Options disables movement entirely. The editbox area uses
    -- manual movement detection above so a click can still focus it.
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if EasyFind.db.lockPosition then return end
        self:StartMoving()
    end)
    searchFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, relPoint, x, y = self:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
    end)

    -- Apply saved scale
    self:UpdateScale()
    self:UpdateOpacity()

    -- Movement fade: reduce opacity while player is moving (like the world map)
    local MOVE_FADE_FACTOR = 0.4
    local moveFading = false  -- true when alpha is reduced due to movement

    local function GetEffectiveAlpha()
        if moveFading then return MOVE_FADE_FACTOR end
        return 1.0
    end
    searchFrame.getEffectiveAlpha = GetEffectiveAlpha

    -- Smart Show: invisible hover zone that triggers show/hide
    local hoverZone = CreateFrame("Frame", "EasyFindHoverZone", UIParent)
    hoverZone:SetFrameStrata("MEDIUM")
    hoverZone:SetFrameLevel(searchFrame:GetFrameLevel() - 1)
    hoverZone:EnableMouse(true)
    hoverZone:SetSize(340, 76)  -- larger than the search bar to catch the mouse nearby
    hoverZone:SetPoint("CENTER", searchFrame, "CENTER", 0, 0)
    hoverZone:Hide()
    searchFrame.hoverZone = hoverZone

    -- Track whether the mouse is over the zone or the bar
    local smartShowVisible = false
    local smartShowTimer = nil

    local function SmartShowFadeIn()
        if smartShowTimer then smartShowTimer:Cancel(); smartShowTimer = nil end
        if EasyFind.db.visible == false then return end
        if not smartShowVisible then
            smartShowVisible = true
            UIFrameFadeIn(searchFrame, 0.15, searchFrame:GetAlpha(), GetEffectiveAlpha())
            searchFrame:Show()
        end
    end

    local function SmartShowFadeOut()
        if EasyFind.db.visible == false then return end
        -- Don't hide if the editbox has focus or contains text
        if searchFrame.editBox:HasFocus() or searchFrame.editBox:GetText() ~= "" then return end
        -- Don't hide if results are showing
        if resultsFrame and resultsFrame:IsShown() then return end
        -- Don't hide while the player is actively resizing the bar
        if searchFrame.resizing then return end
        if smartShowTimer then smartShowTimer:Cancel() end
        smartShowTimer = C_Timer.NewTimer(0.4, function()
            smartShowTimer = nil
            -- Re-check conditions after the delay. Smart Show might have
            -- been disabled while the timer was pending (e.g., unchecked
            -- from the tutorial or options panel mid-hover-out) in which
            -- case we must not fade the bar out.
            if not EasyFind.db.smartShow then return end
            if searchFrame.editBox:HasFocus() or searchFrame.editBox:GetText() ~= "" then return end
            if resultsFrame and resultsFrame:IsShown() then return end
            if searchFrame.resizing then return end
            if hoverZone:IsMouseOver() or searchFrame:IsMouseOver() then return end
            smartShowVisible = false
            UIFrameFadeOut(searchFrame, 0.25, searchFrame:GetAlpha(), 0)
            C_Timer.After(0.25, function()
                if not smartShowVisible and EasyFind.db.smartShow then
                    searchFrame:SetAlpha(0)
                end
            end)
        end)
    end

    hoverZone:SetScript("OnEnter", SmartShowFadeIn)
    hoverZone:SetScript("OnLeave", SmartShowFadeOut)
    searchFrame:HookScript("OnEnter", function()
        if EasyFind.db.smartShow then SmartShowFadeIn() end
    end)
    searchFrame:HookScript("OnLeave", function()
        if EasyFind.db.smartShow then SmartShowFadeOut() end
    end)

    searchFrame.smartShowFadeIn = SmartShowFadeIn
    searchFrame.smartShowFadeOut = SmartShowFadeOut
    searchFrame.smartShowVisible = function() return smartShowVisible end
    searchFrame.setSmartShowVisible = function(val) smartShowVisible = val end
    searchFrame.cancelSmartShowTimer = function()
        if smartShowTimer then
            smartShowTimer:Cancel()
            smartShowTimer = nil
        end
    end

    -- OnUpdate: detect movement and adjust opacity accordingly (throttled to ~10Hz)
    local moveCheckAccum = 0
    searchFrame:HookScript("OnUpdate", function(self, elapsed)
        moveCheckAccum = moveCheckAccum + elapsed
        if moveCheckAccum < 0.1 then return end
        moveCheckAccum = 0

        if EasyFind.db.staticOpacity then
            if moveFading then
                moveFading = false
                self:SetAlpha(1.0)
            end
            return
        end
        if EasyFind.db.smartShow and not smartShowVisible then return end
        -- While the player is resizing the bar, keep it fully visible so
        -- they can see the live size/font changes.
        if self.resizing then
            if moveFading then
                moveFading = false
                UIFrameFadeRemoveFrame(self)
                self:SetAlpha(1.0)
            end
            return
        end

        local speed = GetUnitSpeed("player")
        local hovering = self:IsMouseOver()
            or (resultsFrame and resultsFrame:IsShown() and resultsFrame:IsMouseOver())
        local shouldFade = speed > 0 and not hovering

        if shouldFade ~= moveFading then
            moveFading = shouldFade
            UIFrameFadeRemoveFrame(self)
            self:SetAlpha(GetEffectiveAlpha())
        end
    end)

    -- UI search filter dropdown
    self:CreateUIFilterDropdown(filterBtn, searchFrame, editBox)

    searchFrame:HookScript("OnShow", function(self)
        if EasyFind.db.autoHide then
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        end
        -- Arm the UISpecialFrames catcher: gives ESC a target even when
        -- the editbox lacks focus (clicking the filter button, hovering a
        -- flyout). escCatcher's OnHide consolidates the close behavior.
        if escCatcher then escCatcher:Show() end
    end)
    searchFrame:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    searchFrame:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not EasyFind.db.autoHide then return end
        -- Minimap button click is in flight: skip autoHide so the button's
        -- own OnClick toggle is the only state change. Set in OnMouseDown
        -- of the minimap button (Core.lua), cleared in OnMouseUp.
        if EasyFind._minimapClickActive then return end
        -- An inline setting-dropdown popup is open. It lives on UIParent
        -- as a separate top-level frame, so a click inside it is "outside"
        -- our search bar and would otherwise close the bar before the
        -- popup's OnClick callback runs.
        if EasyFind._inlineDropdownMenuOpen then return end
        -- Grace window after a popup row was selected. Some setting
        -- writes dispatch follow-up events (CVAR updates etc.) that
        -- reach this handler with the popup already hidden.
        if EasyFind._popupGraceUntil and GetTime() < EasyFind._popupGraceUntil then return end
        -- WoW's actual click-target focus stack. Use this rather than
        -- IsMouseOver: GetMouseFoci is what the click dispatch itself
        -- uses, so a frame in this list is guaranteed to receive the
        -- click. Catches the minimap button (and any other "click target
        -- that should NOT close the bar") even if our OnMouseDown flag
        -- races against this event handler.
        local mmBtn = _G["EasyFindMinimapButton"]
        if mmBtn then
            if GetMouseFoci then
                local foci = GetMouseFoci()
                if foci then
                    for i = 1, #foci do
                        if foci[i] == mmBtn then return end
                    end
                end
            elseif GetMouseFocus and GetMouseFocus() == mmBtn then
                return
            end
        end
        if self:IsMouseOver() then return end
        if resultsFrame and resultsFrame:IsShown() and resultsFrame:IsMouseOver() then return end
        if activeKeybindBtn then return end
        local dropdown = self.filterDropdown
        if dropdown and dropdown:IsShown() and dropdown:IsMouseOver() then return end
        -- Every sub-popup the filter dropdown spawns (flyout sub-filters,
        -- options popups, spec/class flyouts, etc.) registers itself in
        -- dropdown.guardFrames. Walk that list so a click inside any of
        -- them never dismisses the search bar.
        if dropdown and dropdown.guardFrames then
            for i = 1, #dropdown.guardFrames do
                local g = dropdown.guardFrames[i]
                if Utils.IsFrameOrChildMouseOver(g) then return end
            end
        end
        local extras = {
            _G["EasyFindPinPopup"],
            _G["EasyFindUIWizard"],
        }
        for _, g in ipairs(extras) do
            if Utils.IsFrameOrChildMouseOver(g) then return end
        end
        UI:Hide()
    end)

end

-- Top-level filter list, alphabetical. Collections stays compact via a
-- flyout: the row carries a yellow expand arrow on the right; hovering
-- it opens a popup of sub-filter checkboxes (Mounts/Toys/Pets/Outfits/
-- Appearance Sets). Each sub-filter still owns its own filters[key]
-- value; only the rendering changed.
local UI_FILTER_OPTIONS = {
    -- Abilities: boss-skull icon from the Encounter Journal boss tab
    -- spritesheet (texture 522972).
    { key = "abilities",   label = "Abilities",   iconTex = 522972,
      iconCoords = { 0.904, 0.996, 0.707, 0.748 },
      flyoutRadio = {
          checkboxes = {
              { dbKey = "abilityHidePassives", label = "Hide Passives",
                onChange = function(v) if UI.ApplySpellBookHidePassives then UI:ApplySpellBookHidePassives(v) end end },
          },
      } },
    { key = "achievements", label = "Achievements", iconAtlas = "UI-HUD-MicroMenu-Achievements-Up" },
    { key = "bags",        label = "Bags",        iconAtlas = "bag-main" },
    -- Bosses: EJ overview tab icon from texture 522972.
    { key = "bosses",      label = "Bosses",      iconTex = 522972,
      iconCoords = { 0.855, 0.949, 0.524, 0.566 } },
    { key = "macros",      label = "Macros",      iconTex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    { key = "collections",  label = "Collections",  iconAtlas = "UI-HUD-MicroMenu-Collections-Up",
      flyoutSubFilters = {
          { key = "appearanceSets", label = "Appearance Sets", iconTex = "Interface\\Icons\\INV_Helmet_03", hasOptions = true },
          { key = "heirlooms",      label = "Heirlooms",       iconTex = 133877 },
          { key = "mounts",         label = "Mounts",          iconTex = 132261 },
          { key = "outfits",        label = "Outfits",         iconTex = 132649 },
          { key = "pets",           label = "Pets",            iconTex = 631719 },
          { key = "toys",           label = "Toys",            iconTex = 454046 },
      } },
    { key = "gearSets",    label = "Gear Sets",   iconAtlas = "equipmentmanager-spec-border" },
    { key = "currencies",  label = "Currencies",  iconTex = 136452,
      flyoutRadio = {
          dbKey = "currencyFilterMode",
          options = {
              { value = "warband", label = CURRENCY_FILTER_TYPE_TRANSFERABLE or "All Warband Transferable" },
              { value = "all",     label = (CURRENCY_FILTER_TYPE_CHARACTER and UnitName and UnitName("player")
                                           and CURRENCY_FILTER_TYPE_CHARACTER:format(UnitName("player")))
                                          or ((UnitName and UnitName("player") or "This Character") .. " Only") },
          },
          onChange = function(v) if UI.ApplyTokenFrameFilter then UI:ApplyTokenFrameFilter(v) end end,
      } },
    -- Gear: treasure-chest icon from the Encounter Journal loot tab
    -- spritesheet (texture 522972) for visual consistency with the
    -- in-game loot UI. hasFlyout flags the row to draw the chevron --
    -- the actual flyout (difficulty, spec, iLvl) is built inline below
    -- via gearOptionsPopup, not via flyoutSubFilters.
    { key = "loot",        label = "Gear",        iconTex = 522972,
      iconCoords = { 0.730, 0.824, 0.618, 0.660 }, hasFlyout = true },
    { key = "map",         label = "Map Search",  iconTex = 1121272,
      iconCoords = { 0.3457, 0.3856, 0.2549, 0.2951 },
      flyoutSubFilters = {
          { key = "zones",      label = "Zones",        dbTable = "mapTabFilters" },
          { key = "instances",  label = "Instances",    dbTable = "mapTabFilters" },
          { key = "flightpath", label = "Flight Paths", dbTable = "mapTabFilters" },
          { key = "travel",     label = "Travel",       dbTable = "mapTabFilters" },
          { key = "services",   label = "Services",     dbTable = "mapTabFilters" },
          { key = "rares",      label = "Rares",        dbTable = "mapTabFilters" },
      } },
    { key = "options",     label = "Options",     iconTex = 1121272,
      iconCoords = { 0.4451, 0.4705, 0.8079, 0.8344 },
      flyoutSubFilters = {
          { key = "gameOptions",  label = "Game Options",  iconAtlas = "QuestLog-icon-setting" },
          { key = "addonOptions", label = "AddOn Options", iconAtlas = "QuestLog-icon-setting", iconColor = { 1.0, 0.78, 0.35 } },
      } },
    { key = "reputations", label = "Reputations", iconTex = 1121272,
      iconCoords = { 0.3783, 0.4072, 0.9066, 0.9350 },
      flyoutRadio = {
          dbKey = "reputationFilterMode",
          options = {
              { value = "all",     label = "All" },
              { value = "warband", label = "Warband" },
              { value = "char",    label = (UnitName and UnitName("player")) or "This Character" },
          },
          onChange = function(v) if UI.ApplyReputationFilter then UI:ApplyReputationFilter(v) end end,
          checkboxes = {
              { dbKey = "showLegacyReputations", label = "Show Legacy Reputations",
                onChange = function(v) if UI.ApplyReputationShowLegacy then UI:ApplyReputationShowLegacy(v) end end },
          },
      } },
    -- Talents: leaf icon from the talents atlas spritesheet (4556093),
    -- visually consistent with the in-game talent tree.
    { key = "talents",     label = "Talents",     iconAtlas = "UI-HUD-MicroMenu-SpellbookAbilities-Up" },
    -- Title icon from PaperDollSidebarTab2 (Titles tab) spritesheet 514608.
    { key = "titles",      label = "Titles",      iconTex = 514608,
      iconCoords = { 0.016, 0.531, 0.324, 0.461 } },
    { key = "ui",          label = "UI Elements", iconAtlas = "common-search-magnifyingglass" },
}

-- All filter keys (top-level + sub-filters in flyouts). Used by Toggle
-- All / OnShow sync so flyout-hosted filters update too.
local function ForEachFilterKey(callback)
    for _, opt in ipairs(UI_FILTER_OPTIONS) do
        callback(opt.key, opt)
        if opt.flyoutSubFilters then
            for _, sub in ipairs(opt.flyoutSubFilters) do
                callback(sub.key, sub)
            end
        end
    end
end

-- Module-level helpers for bucketing UI search results into one of:
-- "achievements" / "currencies" / "reputations" / "ui" (UI elements).
-- Used both in the per-keystroke filter and category sort.
local UI_BUCKET_BY_CATEGORY = {
    ["Ability"]            = "abilities",
    ["Boss"]               = "bosses",
    ["Achievement"]        = "achievements",
    ["Achievements"]       = "achievements",
    ["Guild Achievements"] = "achievements",
    ["Statistics"]         = "achievements",
    ["Currency"]           = "currencies",
    ["Reputation"]         = "reputations",
    ["Bag"]                = "bags",
    ["Macro"]              = "macros",
    ["Talent"]             = "talents",
    ["Title"]              = "titles",
    ["Gear Set"]           = "gearSets",
    ["Game Settings"]      = "gameOptions",
    ["AddOn Settings"]     = "addonOptions",
}

local function GetUIBucket(d)
    -- Returns one of the bucket keys for non-collection / non-map UI
    -- entries, or nil for entries handled by a separate dedicated filter.
    if not d then return nil end
    if d.mountID or d.toyItemID or d.petID or d.outfitID or d.heirloomItemID
       or d.transmogSetID
       or (d.itemID and d.category == "Loot") or d.mapSearchResult then
        return nil
    end
    return UI_BUCKET_BY_CATEGORY[d.category] or "ui"
end

-- Builds the Appearance Sets options popup: a class selector button +
-- four checkboxes (Collected, Not Collected, PvE, PvP). Returns the
-- popup frame and a sync function that re-reads EasyFind.db state.
-- Caller positions/shows the popup and decides when to call sync.
function UI:BuildAppearanceSetOptionsPopup(StylePopup, CreateRadioTexture,
        ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox)
    local FLYOUT_ROW_H = 20
    local CLASSPOPUP_WIDTH = 160
    local OPTIONS_WIDTH = 160
    local CB_ROW_H = 22
    local CLASS_BTN_H = 27
    local PAD = 6

    local CLASS_COLORS = RAID_CLASS_COLORS
    local classes = {}
    for classIdx = 1, GetNumClasses() do
        local className, classFile, classID = GetClassInfo(classIdx)
        if className and classFile then
            classes[#classes + 1] = {
                classID = classID, className = className, classFile = classFile,
            }
        end
    end

    local function ClassColorString(classFile)
        local c = CLASS_COLORS[classFile]
        return c and string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) or ""
    end

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("transmogSets")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            UI:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindAsOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    -- Class selector button at the top
    local classBtn = CreateFrame("Button", nil, optionsPopup)
    classBtn:SetSize(OPTIONS_WIDTH - PAD * 2, CLASS_BTN_H)
    classBtn:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, -PAD)
    local cbBg = classBtn:CreateTexture(nil, "BACKGROUND")
    cbBg:SetAtlas("common-dropdown-textholder")
    cbBg:SetAllPoints()
    local cbArrow = classBtn:CreateTexture(nil, "OVERLAY")
    cbArrow:SetAtlas("common-dropdown-a-button-hover")
    cbArrow:SetSize(20, 20)
    cbArrow:SetPoint("RIGHT", -2, -1)
    cbArrow:SetVertexColor(0.7, 0.7, 0.7)
    local cbLabel = classBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    cbLabel:SetPoint("LEFT", 8, 0)
    cbLabel:SetPoint("RIGHT", cbArrow, "LEFT", -2, 0)
    cbLabel:SetJustifyH("LEFT")
    cbLabel:SetWordWrap(false)
    classBtn:SetScript("OnEnter", function() cbArrow:SetVertexColor(1, 1, 1) end)
    classBtn:SetScript("OnLeave", function() cbArrow:SetVertexColor(0.7, 0.7, 0.7) end)

    local function UpdateClassLabel()
        local cf = EasyFind.db.appearanceSetClass
        if not cf then
            local _, _, cid = UnitClass("player")
            for _, cls in ipairs(classes) do
                if cls.classID == cid then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        elseif cf == "all" then
            cbLabel:SetText("All Classes")
            return
        elseif type(cf) == "table" and cf.classID then
            for _, cls in ipairs(classes) do
                if cls.classID == cf.classID then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        end
        cbLabel:SetText("All Classes")
    end
    UpdateClassLabel()

    -- Class popup (opens to the right of the class button)
    local classPopup = CreateFrame("Frame", "EasyFindAsClassPopup", UIParent, "BackdropTemplate")
    classPopup:SetFrameStrata("TOOLTIP")
    classPopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(classPopup)
    classPopup:EnableMouse(true)
    classPopup:Hide()
    classPopup:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() and not classBtn:IsMouseOver()
                and not optionsPopup:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    local classRows = {}
    local allRow = CreateFrame("Button", nil, classPopup)
    allRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
    allRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
    local allRadio, allSetRadio = CreateRadioTexture(allRow)
    allRadio:SetPoint("LEFT", 4, 0)
    local allLbl = allRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    allLbl:SetPoint("LEFT", allRadio, "RIGHT", 4, 0)
    allLbl:SetText("All Classes")
    local allHL = allRow:CreateTexture(nil, "HIGHLIGHT")
    allHL:SetAllPoints()
    allHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
    allRow._setRadioChecked = allSetRadio
    allRow._classID = nil
    allRow:SetScript("OnClick", function()
        EasyFind.db.appearanceSetClass = "all"
        UpdateClassLabel()
        classPopup:Hide()
        ApplyFilterSelection()
    end)
    classRows[#classRows + 1] = allRow

    for _, cls in ipairs(classes) do
        local clsRow = CreateFrame("Button", nil, classPopup)
        clsRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
        clsRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
        local cRadio, cSetRadio = CreateRadioTexture(clsRow)
        cRadio:SetPoint("LEFT", 4, 0)
        local cLbl = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        cLbl:SetPoint("LEFT", cRadio, "RIGHT", 4, 0)
        cLbl:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
        local cHL = clsRow:CreateTexture(nil, "HIGHLIGHT")
        cHL:SetAllPoints()
        cHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        clsRow._setRadioChecked = cSetRadio
        clsRow._classID = cls.classID
        clsRow:SetScript("OnClick", function()
            EasyFind.db.appearanceSetClass = { classID = cls.classID }
            UpdateClassLabel()
            classPopup:Hide()
            ApplyFilterSelection()
        end)
        classRows[#classRows + 1] = clsRow
    end

    local function LayoutClassPopup()
        local py = -6
        local cf = EasyFind.db.appearanceSetClass
        for _, r in ipairs(classRows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", classPopup, "TOPLEFT", 8, py)
            r:Show()
            if r._setRadioChecked then
                local match = false
                if not r._classID then
                    match = cf == "all"
                else
                    if type(cf) == "table" and cf.classID == r._classID then
                        match = true
                    elseif not cf then
                        local _, _, cid = UnitClass("player")
                        match = r._classID == cid
                    end
                end
                r._setRadioChecked(match)
            end
            py = py - FLYOUT_ROW_H
        end
        classPopup:SetSize(CLASSPOPUP_WIDTH, -py + 6)
    end

    classBtn:SetScript("OnClick", function(self)
        if classPopup:IsShown() then
            classPopup:Hide()
            return
        end
        LayoutClassPopup()
        classPopup:SetScale(optionsPopup:GetScale())
        classPopup:ClearAllPoints()
        classPopup:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
        classPopup:Show()
    end)

    -- Filter checkboxes
    local filterDefs = {
        { dbKey = "appearanceSetCollected",     label = "Collected" },
        { dbKey = "appearanceSetNotCollected",  label = "Not Collected" },
        { dbKey = "appearanceSetPvE",           label = "PvE" },
        { dbKey = "appearanceSetPvP",           label = "PvP" },
    }

    local cbRows = {}
    local cy = -(PAD + CLASS_BTN_H + 6)
    for si, def in ipairs(filterDefs) do
        local cbRow = CreateFrame("CheckButton", nil, optionsPopup)
        cbRow:SetSize(OPTIONS_WIDTH - PAD * 2, CB_ROW_H)
        cbRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, cy)

        cbRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cbRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetNormalTexture():ClearAllPoints()
        cbRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

        cbRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cbRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetCheckedTexture():ClearAllPoints()
        cbRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local cbText = cbRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        cbText:SetPoint("LEFT", cbRow:GetNormalTexture(), "RIGHT", 4, 0)
        cbText:SetText(def.label)

        local cbHL = cbRow:CreateTexture(nil, "HIGHLIGHT")
        cbHL:SetAllPoints()
        cbHL:SetColorTexture(1, 1, 1, 0.1)

        local val = EasyFind.db[def.dbKey]
        if val == nil then val = true end
        cbRow:SetChecked(val)
        cbRow.dbKey = def.dbKey

        cbRow:SetScript("OnClick", function(self)
            EasyFind.db[def.dbKey] = self:GetChecked()
            ApplyFilterSelection()
        end)

        cbRows[si] = cbRow
        cy = cy - CB_ROW_H
        if si == 2 then
            local sep = optionsPopup:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 4, cy + 2)
            sep:SetPoint("TOPRIGHT", optionsPopup, "TOPRIGHT", -(PAD + 4), cy + 2)
            sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            cy = cy - 6
        end
    end
    optionsPopup:SetSize(OPTIONS_WIDTH, -cy + PAD)

    -- Hide nested class popup whenever the options popup itself hides.
    optionsPopup:HookScript("OnHide", function() classPopup:Hide() end)

    -- Outside-click: close immediately when the user clicks anywhere
    -- that isn't this popup or its nested class popup. The owning
    -- sub-row hover handler is responsible for re-showing on rehover.
    optionsPopup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self._owningRow and self._owningRow:IsMouseOver() then return end
        if classPopup:IsShown() and classPopup:IsMouseOver() then return end
        self:Hide()
    end)

    local function SyncFromDB()
        for _, sr in ipairs(cbRows) do
            if sr.dbKey then
                sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
            end
        end
        UpdateClassLabel()
    end

    return optionsPopup, SyncFromDB
end

function UI:CreateUIFilterDropdown(toggleBtn, anchorFrame, searchEditBox)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    -- Single source of truth for which side-flyout (sub-filters / radio /
    -- gear options) is currently visible. Any popup that opens hides
    -- whatever was active so sweeping between rows can never leave a
    -- previous flyout lingering, even rows whose popup wasn't tracked
    -- in dropdown.flyoutPopups.
    local activeFlyoutPopup
    local function SetActiveFlyout(popup)
        if activeFlyoutPopup and activeFlyoutPopup ~= popup and activeFlyoutPopup:IsShown() then
            activeFlyoutPopup:Hide()
        end
        activeFlyoutPopup = popup
    end
    local function ClearActiveFlyout(popup)
        if activeFlyoutPopup == popup then activeFlyoutPopup = nil end
    end

    local dropdown = CreateFrame("Frame", "EasyFindUIFilterDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    -- Bump everything in the filter menu uniformly: 1.5x larger fonts,
    -- icons, paddings, and row heights without rewriting the hardcoded
    -- pixel sizes scattered through the row builders.
    dropdown:SetScale(1.5)
    dropdown:Hide()
    dropdown:EnableMouse(true)
    -- Popups that should prevent the dropdown from closing on outside-click.
    -- Each sub-filter registers its popups here instead of hardcoding frame names.
    -- Stashed on the dropdown so the search bar's autoHide handler can also
    -- consult it (otherwise clicks inside a flyout dismiss the bar).
    local dropdownGuardFrames = {}
    dropdown.guardFrames = dropdownGuardFrames
    dropdown:SetClampedToScreen(true)

    dropdown:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local ICON_SIZE = 14

    -- Shared constants for dropdown popups and radio buttons (one place to tweak)
    local RADIO_SIZE = 14
    local RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\radio-off"
    local RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\radio-on"
    local POPUP_BG_COLOR = { 0.05, 0.05, 0.05, 0.95 }
    local POPUP_BORDER_COLOR = { 0.6, 0.6, 0.6, 1 }
    local POPUP_BACKDROP = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }
    local ROW_HIGHLIGHT_COLOR = { 1, 1, 1, 0.1 }

    local function StylePopup(frame)
        frame:SetBackdrop(POPUP_BACKDROP)
        frame:SetBackdropColor(unpack(POPUP_BG_COLOR))
        frame:SetBackdropBorderColor(unpack(POPUP_BORDER_COLOR))
    end

    -- Creates a single radio texture that swaps between off/on states.
    -- Returns the texture and a SetChecked(bool) function.
    local function CreateRadioTexture(parent)
        local tex = parent:CreateTexture(nil, "ARTWORK")
        tex:SetSize(RADIO_SIZE, RADIO_SIZE)
        tex:SetTexture(RADIO_OFF_TEX)
        local function SetChecked(checked)
            tex:SetTexture(checked and RADIO_ON_TEX or RADIO_OFF_TEX)
        end
        return tex, SetChecked
    end

    -- "Uncheck All" toggle at the top
    local uncheckRow = CreateFrame("Button", nil, dropdown)
    uncheckRow:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
    uncheckRow:SetPoint("TOPLEFT", 8, -PADDING_TOP)
    local uncheckLabel = uncheckRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    uncheckLabel:SetPoint("LEFT", 8, 0)
    uncheckLabel:SetText("Toggle All")
    local uncheckHL = uncheckRow:CreateTexture(nil, "HIGHLIGHT")
    uncheckHL:SetAllPoints()
    uncheckHL:SetColorTexture(1, 1, 1, 0.1)

    local checkRows = {}
    local checkRowsByIndex = {}
    local LayoutDropdown  -- forward declaration
    local dropdownKeyboardMode = false

    -- Reusable keyboard nav for popup menus (diff popup, spec popup, class flyout).
    -- Uses a single dropdownKeyboardMode flag: when true, any popup hiding returns
    -- keyboard to the dropdown. No parent tracking needed.
    local function AddPopupKeyboardNav(popup, getRows)
        local popupFocus = 0
        local popupHL = popup:CreateTexture(nil, "BACKGROUND")
        popupHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        popupHL:Hide()

        local function SetPopupFocus(idx)
            local rows = getRows()
            popupFocus = idx
            local target = rows[idx]
            if target then
                popupHL:SetParent(target)
                popupHL:ClearAllPoints()
                popupHL:SetAllPoints(target)
                popupHL:Show()
            else
                popupHL:Hide()
            end
        end

        Utils.SafeCallMethod(popup, "EnableKeyboard", false)
        Utils.SafeCallMethod(popup, "SetPropagateKeyboardInput", false)

        popup:HookScript("OnKeyDown", function(self, key)
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            local rows = getRows()
            if key == "DOWN" then
                searchFrame.StartKeyRepeat(key, function()
                    local r = getRows()
                    local next = popupFocus + 1
                    if next > #r then next = 1 end
                    SetPopupFocus(next)
                end)
            elseif key == "UP" then
                searchFrame.StartKeyRepeat(key, function()
                    local r = getRows()
                    local prev = popupFocus - 1
                    if prev < 1 then prev = #r end
                    SetPopupFocus(prev)
                end)
            elseif key == "ENTER" then
                local target = rows[popupFocus]
                if target and target.Click then target:Click() end
            elseif key == "ESCAPE" then
                -- Route through HandleEscape: closes the parent dropdown
                -- and any sibling popups together, refocuses editbox.
                -- Bare self:Hide() only hits this popup and leaves the
                -- main dropdown / nested popups behind.
                UI:HandleEscape()
            else
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            end
        end)
        popup:HookScript("OnKeyUp", function(_, key)
            if searchFrame.IsRepeatKey(key) then searchFrame.StopKeyRepeat() end
        end)

        popup:HookScript("OnShow", function(self)
            if dropdownKeyboardMode then
                -- Disable keyboard on whoever currently has it
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
                local sp = _G["EasyFindSpecPopup"]
                if sp then Utils.SafeCallMethod(sp, "EnableKeyboard", false) end
                local cf = _G["EasyFindSpecFlyout"]
                if cf then Utils.SafeCallMethod(cf, "EnableKeyboard", false) end
                local dp = _G["EasyFindDiffPopup"]
                if dp then Utils.SafeCallMethod(dp, "EnableKeyboard", false) end
                Utils.SafeCallMethod(self, "EnableKeyboard", true)
                SetPopupFocus(1)
            end
        end)

        popup:HookScript("OnHide", function(self)
            popupFocus = 0
            popupHL:Hide()
            Utils.SafeCallMethod(self, "EnableKeyboard", false)
            if dropdownKeyboardMode and dropdown:IsShown() then
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", true)
            end
        end)
    end

    for i, opt in ipairs(UI_FILTER_OPTIONS) do
        -- Children of a parent filter (e.g., Collections > Mounts) render
        -- indented; their visible width shrinks by SUB_INDENT so the
        -- right-edge icon stays inside the dropdown.
        local rowWidth = DROPDOWN_WIDTH - 16
        if opt.parentKey then rowWidth = rowWidth - 24 end
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(rowWidth, ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key
        row.parentKey = opt.parentKey

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        -- Category icon sits between the checkbox and label so the row
        -- reads left-to-right as [check][icon][name]. Supports atlas,
        -- raw fileID, or fileID + texCoords for sprite-sheet sub-icons.
        local icon
        if opt.iconAtlas or opt.iconTex then
            icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
            -- Gear sets pulls its icon from PaperDollSidebarTab3 so the
            -- filter row matches whatever sprite Blizzard ships, instead
            -- of the spec-border placeholder. Resolve once, then prefer
            -- the cached tex/coords over the static iconAtlas fallback.
            if opt.key == "gearSets" then
                ResolveGearSetIcon()
                local resolved = FLAT_CATEGORY_ICONS.gearSet
                if resolved and resolved._resolved and resolved.tex then
                    icon:SetTexture(resolved.tex)
                    if resolved.coords then
                        icon:SetTexCoord(resolved.coords[1], resolved.coords[2],
                                         resolved.coords[3], resolved.coords[4])
                    end
                else
                    icon:SetAtlas(opt.iconAtlas)
                end
            elseif opt.iconAtlas then
                icon:SetAtlas(opt.iconAtlas)
            else
                icon:SetTexture(opt.iconTex)
                if opt.iconCoords then
                    icon:SetTexCoord(opt.iconCoords[1], opt.iconCoords[2],
                                     opt.iconCoords[3], opt.iconCoords[4])
                end
            end
            row.iconTex = icon
        end

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        if icon then
            label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        else
            label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        end
        label:SetText(opt.label)
        row.label = label

        -- Right-pointing chevron on rows that have a flyout, signalling
        -- the row expands to the right. Mirrors the standard submenu
        -- indicator used elsewhere in the WoW UI. flyoutSubFilters drives
        -- the auto-built sub-filter popup; hasFlyout opts in rows whose
        -- flyout is built inline below (Gear → gearOptionsPopup).
        if opt.flyoutSubFilters or opt.flyoutRadio or opt.hasFlyout then
            local chev = row:CreateTexture(nil, "OVERLAY")
            chev:SetAtlas("common-icon-forwardarrow")
            chev:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
            chev:SetPoint("RIGHT", -4, 0)
            chev:SetVertexColor(0.85, 0.85, 0.85, 1)
            row.flyoutChevron = chev
            -- Anchor the label's right edge to the chevron so long names
            -- truncate cleanly instead of running under it.
            label:SetPoint("RIGHT", chev, "LEFT", -4, 0)
            label:SetWordWrap(false)
            label:SetJustifyH("LEFT")
            row:HookScript("OnEnter", function() chev:SetVertexColor(1, 1, 1, 1) end)
            row:HookScript("OnLeave", function() chev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
        end

        -- Flyout sub-filters (e.g. Collections > Mounts/Toys/Pets/...).
        -- Hovering the row opens a popup containing one CheckButton per
        -- sub-filter. Each sub-filter writes through to filters[subKey]
        -- like a regular top-level filter so search uses them as-is.
        if opt.flyoutSubFilters then
            local SUB_POPUP_WIDTH = 180
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local CHK = CHECK_SIZE
            local SUB_ICON = ICON_SIZE

            -- Parent to UIParent + TOOLTIP strata mirrors the loot
            -- spec/class popups; nesting under `dropdown` left clicks
            -- routed back to the dropdown's own outside-click handler
            -- and the popup felt unclickable.
            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            -- Sibling registry so each flyout's ShowPopup can hide
            -- every other flyout on entry (kills overlap on quick
            -- row-to-row hover transitions).
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            -- Outside-click: close on click outside the popup. Nested
            -- options popups (e.g. appearance set options) act as
            -- guards so clicking inside them keeps this popup open.
            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                local opts = self._appearanceSetOptionsPopup
                if opts and opts:IsShown() and opts:IsMouseOver() then return end
                self:Hide()
            end)

            local subRows = {}
            for si, sub in ipairs(opt.flyoutSubFilters) do
                local subRow = CreateFrame("CheckButton", nil, popup)
                subRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                subRow:SetHitRectInsets(0, 0, 0, 0)
                subRow:SetPoint("TOPLEFT", popup, "TOPLEFT", SUB_PAD, -(SUB_PAD + (si - 1) * SUB_ROW_H))

                subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                subRow:GetNormalTexture():SetSize(CHK, CHK)
                subRow:GetNormalTexture():ClearAllPoints()
                subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

                subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                subRow:GetCheckedTexture():SetSize(CHK, CHK)
                subRow:GetCheckedTexture():ClearAllPoints()
                subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

                local subIcon
                if sub.iconAtlas or sub.iconTex then
                    subIcon = subRow:CreateTexture(nil, "ARTWORK")
                    subIcon:SetSize(SUB_ICON, SUB_ICON)
                    subIcon:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                    if sub.iconAtlas then
                        subIcon:SetAtlas(sub.iconAtlas)
                    else
                        subIcon:SetTexture(sub.iconTex)
                    end
                    if sub.iconColor then
                        subIcon:SetVertexColor(unpack(sub.iconColor))
                    end
                end

                local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                if subIcon then
                    subLabel:SetPoint("LEFT", subIcon, "RIGHT", 4, 0)
                else
                    subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                end
                subLabel:SetText(sub.label)

                if sub.hasOptions then
                    local subChev = subRow:CreateTexture(nil, "OVERLAY")
                    subChev:SetAtlas("common-icon-forwardarrow")
                    subChev:SetSize(SUB_ICON - 2, SUB_ICON - 2)
                    subChev:SetPoint("RIGHT", -4, 0)
                    subChev:SetVertexColor(0.85, 0.85, 0.85, 1)
                    subLabel:SetPoint("RIGHT", subChev, "LEFT", -4, 0)
                    subLabel:SetWordWrap(false)
                    subLabel:SetJustifyH("LEFT")
                    subRow:HookScript("OnEnter", function() subChev:SetVertexColor(1, 1, 1, 1) end)
                    subRow:HookScript("OnLeave", function() subChev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
                end

                local subHL = subRow:CreateTexture(nil, "HIGHLIGHT")
                subHL:SetAllPoints()
                subHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                subRow:SetScript("OnClick", function(self)
                    local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                   or EasyFind.db.uiSearchFilters
                    target[sub.key] = self:GetChecked()
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)

                subRows[si] = subRow
                subRows[sub.key] = subRow

                -- Appearance Sets has its own nested options popup (class
                -- selector + Collected/Not Collected/PvE/PvP filters)
                -- that opens to the right of this sub-row on hover.
                if sub.hasOptions and sub.key == "appearanceSets" then
                    local optionsPopup, syncOptions = UI:BuildAppearanceSetOptionsPopup(
                        StylePopup, CreateRadioTexture, ROW_HIGHLIGHT_COLOR, CHECK_SIZE,
                        searchEditBox)
                    UI._SyncAppearanceSetOptions = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._appearanceSetOptionsPopup = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup

                    local optHideTimer
                    local function HideOptionsNow()
                        if optionsPopup:IsMouseOver() or subRow:IsMouseOver() then return end
                        optionsPopup:Hide()
                    end
                    local function ScheduleHideOptions()
                        if optHideTimer then optHideTimer:Cancel() end
                        optHideTimer = C_Timer.NewTimer(0.15, function()
                            optHideTimer = nil
                            HideOptionsNow()
                        end)
                    end

                    subRow:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                        syncOptions()
                        optionsPopup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                        optionsPopup:ClearAllPoints()
                        optionsPopup:SetPoint("TOPLEFT", subRow, "TOPRIGHT", 4, 0)
                        optionsPopup:Show()
                    end)
                    subRow:HookScript("OnLeave", ScheduleHideOptions)
                    optionsPopup:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                    end)
                    optionsPopup:HookScript("OnLeave", ScheduleHideOptions)

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end
            end
            -- Sibling sub-rows hide the appearance set options popup so it
            -- doesn't linger when the cursor moves to a non-options row.
            if popup._appearanceSetOptionsPopup then
                local optionsPopup = popup._appearanceSetOptionsPopup
                for _, srOther in ipairs(subRows) do
                    if srOther ~= subRows.appearanceSets then
                        srOther:HookScript("OnEnter", function()
                            optionsPopup:Hide()
                        end)
                    end
                end
            end
            row.flyoutSubRows = subRows

            -- "Hide tooltips" checkbox at the bottom of the collections
            -- flyout. Toggles the per-group EasyFind.db.hideTooltips
            -- setting that the OnEnter handlers consult before showing
            -- mount / toy / pet / heirloom / appearance set tooltips.
            local extraRows = 0
            local hideTipRow
            if opt.key == "collections" then
                hideTipRow = CreateFrame("CheckButton", nil, popup)
                hideTipRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                hideTipRow:SetHitRectInsets(0, 0, 0, 0)
                hideTipRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + #opt.flyoutSubFilters * SUB_ROW_H))
                hideTipRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                hideTipRow:GetNormalTexture():SetSize(CHK, CHK)
                hideTipRow:GetNormalTexture():ClearAllPoints()
                hideTipRow:GetNormalTexture():SetPoint("LEFT", 4, 0)
                hideTipRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                hideTipRow:GetCheckedTexture():SetSize(CHK, CHK)
                hideTipRow:GetCheckedTexture():ClearAllPoints()
                hideTipRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)
                local lbl = hideTipRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", hideTipRow:GetNormalTexture(), "RIGHT", 4, 0)
                lbl:SetText("Hide tooltips")
                local hl = hideTipRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                hideTipRow:SetScript("OnClick", function(self)
                    EasyFind.db.hideTooltips = EasyFind.db.hideTooltips or {}
                    EasyFind.db.hideTooltips.collections = self:GetChecked() and true or false
                end)
                row.hideTooltipsRow = hideTipRow
                extraRows = 1
            end
            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + (#opt.flyoutSubFilters + extraRows) * SUB_ROW_H)

            -- Sync sub-row checked state from current DB values.
            local function SyncSubChecks()
                for _, sub in ipairs(opt.flyoutSubFilters) do
                    local sr = subRows[sub.key]
                    if sr then
                        local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        sr:SetChecked(target[sub.key] ~= false)
                    end
                end
                if hideTipRow then
                    local ht = EasyFind.db.hideTooltips
                    hideTipRow:SetChecked(ht and ht.collections == true)
                end
            end
            row.SyncFlyoutSubChecks = SyncSubChecks

            -- Show on hover of either the parent row or the arrow.
            -- Hide when the cursor leaves both the row and the popup,
            -- with a small grace timer so brief gaps between them don't
            -- snap the menu shut.
            local function PositionPopup()
                popup:ClearAllPoints()
                popup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
            end
            local hideTimer
            local function ShowPopup()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
                SetActiveFlyout(popup)
                SyncSubChecks()
                popup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                PositionPopup()
                popup:Show()
            end
            local function MaybeHide()
                if popup:IsMouseOver() or row:IsMouseOver() then return end
                if popup._appearanceSetOptionsPopup
                    and popup._appearanceSetOptionsPopup:IsShown()
                    and popup._appearanceSetOptionsPopup:IsMouseOver() then
                    return
                end
                popup:Hide()
            end
            local function ScheduleHide()
                if hideTimer then hideTimer:Cancel() end
                hideTimer = C_Timer.NewTimer(0.15, function()
                    hideTimer = nil
                    MaybeHide()
                end)
            end

            -- Need to call ShowPopup from row's OnEnter (set lower in
            -- the loop), so stash it on the row for the OnClick handler.
            row.ShowFlyoutPopup = ShowPopup
            row.ScheduleHideFlyoutPopup = ScheduleHide

            popup:HookScript("OnLeave", ScheduleHide)
            popup:HookScript("OnEnter", function()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
            end)
            row:HookScript("OnEnter", ShowPopup)
            row:HookScript("OnLeave", ScheduleHide)
            -- Close when the parent dropdown closes so the popup can't
            -- linger over other UI.
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end

        -- Radio + checkbox flyout. radio.options renders radio rows that
        -- write radio.dbKey; radio.checkboxes renders independent toggles
        -- below. Either section may be omitted (e.g. Abilities has only a
        -- "Hide Passives" checkbox; Currencies has only the radio set).
        if opt.flyoutRadio and not opt.flyoutSubFilters then
            local radio = opt.flyoutRadio
            local SUB_POPUP_WIDTH = 200
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local options = radio.options or {}
            local checkboxes = radio.checkboxes or {}
            local hasSeparator = #options > 0 and #checkboxes > 0
            local SEPARATOR_H = hasSeparator and 8 or 0

            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                self:Hide()
            end)

            local radioRows = {}
            for ri, optionDef in ipairs(options) do
                local rRow = CreateFrame("Button", nil, popup)
                rRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                rRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + (ri - 1) * SUB_ROW_H))

                local bullet = rRow:CreateTexture(nil, "ARTWORK")
                bullet:SetAtlas("common-dropdown-tickradial")
                bullet:SetSize(14, 14)
                bullet:SetPoint("LEFT", 4, 0)

                local tick = rRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-radialtick-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = rRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", bullet, "RIGHT", 6, 0)
                lbl:SetText(optionDef.label)

                local hl = rRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                rRow.tick = tick
                rRow.value = optionDef.value
                rRow:SetScript("OnClick", function(self)
                    EasyFind.db[radio.dbKey] = self.value
                    for _, otherRow in ipairs(radioRows) do
                        otherRow.tick:SetShown(otherRow.value == self.value)
                    end
                    if radio.onChange then radio.onChange(self.value) end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)

                radioRows[ri] = rRow
            end

            local checkboxRows = {}
            local cbStartY = SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H
            for ci, cbDef in ipairs(checkboxes) do
                local cRow = CreateFrame("Button", nil, popup)
                cRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                cRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(cbStartY + (ci - 1) * SUB_ROW_H))

                local box = cRow:CreateTexture(nil, "ARTWORK")
                box:SetAtlas("common-dropdown-ticksquare")
                box:SetSize(12, 12)
                box:SetPoint("LEFT", 5, 0)

                local tick = cRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-checkmark-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = cRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", box, "RIGHT", 6, 0)
                lbl:SetText(cbDef.label)

                local hl = cRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                cRow.tick = tick
                cRow.dbKey = cbDef.dbKey
                cRow.onChange = cbDef.onChange
                cRow:SetScript("OnClick", function(self)
                    local cur = EasyFind.db[self.dbKey]
                    local next = not cur
                    EasyFind.db[self.dbKey] = next
                    self.tick:SetShown(next)
                    if self.onChange then self.onChange(next) end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
                checkboxRows[ci] = cRow
            end

            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + #options * SUB_ROW_H + SEPARATOR_H + #checkboxes * SUB_ROW_H)

            if hasSeparator then
                local sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetColorTexture(1, 1, 1, 0.12)
                sep:SetHeight(1)
                sep:SetPoint("LEFT", popup, "LEFT", SUB_PAD, 0)
                sep:SetPoint("RIGHT", popup, "RIGHT", -SUB_PAD, 0)
                sep:SetPoint("TOP", popup, "TOP", 0,
                    -(SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H * 0.5))
            end

            local function SyncRadio()
                if radio.dbKey then
                    local cur = EasyFind.db[radio.dbKey]
                    for _, rRow in ipairs(radioRows) do
                        rRow.tick:SetShown(rRow.value == cur)
                    end
                end
                for _, cRow in ipairs(checkboxRows) do
                    cRow.tick:SetShown(EasyFind.db[cRow.dbKey] and true or false)
                end
            end
            row.SyncFlyoutSubChecks = SyncRadio

            local function PositionPopup()
                popup:ClearAllPoints()
                popup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
            end
            local hideTimer
            local function ShowPopup()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
                SetActiveFlyout(popup)
                SyncRadio()
                popup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                PositionPopup()
                popup:Show()
            end
            local function MaybeHide()
                if popup:IsMouseOver() or row:IsMouseOver() then return end
                popup:Hide()
            end
            local function ScheduleHide()
                if hideTimer then hideTimer:Cancel() end
                hideTimer = C_Timer.NewTimer(0.15, function()
                    hideTimer = nil
                    MaybeHide()
                end)
            end
            row.ShowFlyoutPopup = ShowPopup
            row.ScheduleHideFlyoutPopup = ScheduleHide
            popup:HookScript("OnLeave", ScheduleHide)
            popup:HookScript("OnEnter", function()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
            end)
            row:HookScript("OnEnter", ShowPopup)
            row:HookScript("OnLeave", ScheduleHide)
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end


        -- Loot/Gear: side popup with difficulty + spec selector + iLvl
        -- upgrades checkbox. Opens to the right of the Gear filter row
        -- on hover, like the Collections sub-flyout.
        if opt.key == "loot" then
            local GEAR_POPUP_WIDTH = 200
            local GEAR_POPUP_PAD = 8

            local gearOptionsPopup = CreateFrame("Frame", "EasyFindGearOptionsPopup", UIParent, "BackdropTemplate")
            gearOptionsPopup:SetFrameStrata("TOOLTIP")
            StylePopup(gearOptionsPopup)
            gearOptionsPopup:EnableMouse(true)
            gearOptionsPopup:Hide()
            row.gearOptionsPopup = gearOptionsPopup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = gearOptionsPopup

            local lootSubDefs = {
                { dbKey = "lootUpgradesOnly", label = "iLvl Upgrades Only" },
                { dbKey = "hideTooltips.loot", label = "Hide tooltips" },
            }
            local lootSubRows = {}
            for si, sub in ipairs(lootSubDefs) do
                local subRow = CreateFrame("CheckButton", nil, gearOptionsPopup)
                subRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, ROW_HEIGHT)
                subRow:SetHitRectInsets(0, 0, 0, 0)

                subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                subRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                subRow:GetNormalTexture():ClearAllPoints()
                subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

                subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                subRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                subRow:GetCheckedTexture():ClearAllPoints()
                subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

                local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                subLabel:SetText(sub.label)

                local subHL = subRow:CreateTexture(nil, "HIGHLIGHT")
                subHL:SetAllPoints()
                subHL:SetColorTexture(1, 1, 1, 0.1)

                subRow.dbKey = sub.dbKey
                lootSubRows[si] = subRow

                -- Resolve "a.b" dotted keys into a getter/setter so the
                -- nested hideTooltips.loot toggle lives alongside the
                -- flat lootUpgradesOnly checkbox without duplicating
                -- this whole subRow setup.
                local function resolveDbPath()
                    local parent, leaf = sub.dbKey:match("^(.-)%.([^%.]+)$")
                    if parent then
                        EasyFind.db[parent] = EasyFind.db[parent] or {}
                        return EasyFind.db[parent], leaf
                    end
                    return EasyFind.db, sub.dbKey
                end

                subRow:SetScript("OnClick", function(self)
                    local tbl, leaf = resolveDbPath()
                    tbl[leaf] = self:GetChecked() and true or false
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
                subRow.resolveDbPath = resolveDbPath
            end

            -- Separator line between iLvl Upgrades checkbox and the
            -- difficulty/spec selectors.
            local lootSep = gearOptionsPopup:CreateTexture(nil, "ARTWORK")
            lootSep:SetHeight(1)
            lootSep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            row.lootSep = lootSep

            -- Difficulty dropdown (single-select, matches EJ style)
            local DIFF_OPTIONS = {
                { key = "lfr",    label = "Raid Finder" },
                { key = "normal", label = "Normal" },
                { key = "heroic", label = "Heroic" },
                { key = "mythic", label = "Mythic" },
            }
            local DIFF_LABELS = { lfr = "Raid Finder", normal = "Normal", heroic = "Heroic", mythic = "Mythic" }

            local diffBtn = CreateFrame("Button", nil, gearOptionsPopup)
            diffBtn:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
            local diffBg = diffBtn:CreateTexture(nil, "BACKGROUND")
            diffBg:SetAtlas("common-dropdown-textholder")
            diffBg:SetAllPoints()
            local diffArrow = diffBtn:CreateTexture(nil, "OVERLAY")
            diffArrow:SetAtlas("common-dropdown-a-button-hover")
            diffArrow:SetSize(20, 20)
            diffArrow:SetPoint("RIGHT", -2, -1)
            diffArrow:SetVertexColor(0.7, 0.7, 0.7)
            local diffText = diffBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            diffText:SetPoint("LEFT", 8, 0)
            diffText:SetPoint("RIGHT", diffArrow, "LEFT", -2, 0)
            diffText:SetJustifyH("LEFT")
            diffText:SetWordWrap(false)
            diffBtn:SetScript("OnEnter", function()
                diffArrow:SetVertexColor(1, 1, 1)
            end)
            diffBtn:SetScript("OnLeave", function()
                diffArrow:SetVertexColor(0.7, 0.7, 0.7)
            end)

            local function UpdateDiffLabel()
                local key = EasyFind.db.lootDifficulty or "normal"
                diffText:SetText(DIFF_LABELS[key] or "Normal")
            end

            -- Difficulty popup menu
            local diffPopup = CreateFrame("Frame", "EasyFindDiffPopup", UIParent, "BackdropTemplate")
            diffPopup:SetFrameStrata("TOOLTIP")
            diffPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
            StylePopup(diffPopup)
            diffPopup:EnableMouse(true)
            diffPopup:Hide()

            local diffPopupRows = {}
            local py = -6
            for _, def in ipairs(DIFF_OPTIONS) do
                local dRow = CreateFrame("Button", nil, diffPopup)
                dRow:SetSize(130, 20)
                dRow:SetPoint("TOPLEFT", 8, py)
                local radio, setRadioChecked = CreateRadioTexture(dRow)
                radio:SetPoint("LEFT", 0, 0)
                local dLabel = dRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                dLabel:SetPoint("LEFT", radio, "RIGHT", 4, 0)
                dLabel:SetText(def.label)
                local dHL = dRow:CreateTexture(nil, "HIGHLIGHT")
                dHL:SetAllPoints()
                dHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                dRow._diffKey = def.key
                dRow._setRadioChecked = setRadioChecked
                dRow:SetScript("OnClick", function()
                    EasyFind.db.lootDifficulty = def.key
                    UpdateDiffLabel()
                    diffPopup:Hide()
                    if ns.Database and ns.Database.RefreshDynamicCategory then
                        ns.Database:RefreshDynamicCategory("loot")
                    end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
                diffPopupRows[#diffPopupRows + 1] = dRow
                py = py - 20
            end
            diffPopup:SetSize(146, -py + 6)

            local function SyncDiffRadios()
                local key = EasyFind.db.lootDifficulty or "normal"
                for _, dr in ipairs(diffPopupRows) do
                    dr._setRadioChecked(dr._diffKey == key)
                end
            end

            diffBtn:SetScript("OnClick", function()
                if diffPopup:IsShown() then
                    diffPopup:Hide()
                else
                    SyncDiffRadios()
                    diffPopup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                    diffPopup:ClearAllPoints()
                    diffPopup:SetPoint("TOPLEFT", diffBtn, "BOTTOMLEFT", 0, 2)
                    diffPopup:Show()
                end
            end)
            diffPopup:SetScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            diffPopup:SetScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            diffPopup:SetScript("OnEvent", function(self, event)
                if event == "GLOBAL_MOUSE_DOWN" then
                    if not self:IsMouseOver() and not diffBtn:IsMouseOver() then
                        self:Hide()
                    end
                end
            end)

            AddPopupKeyboardNav(diffPopup, function() return diffPopupRows end)
            dropdownGuardFrames[#dropdownGuardFrames + 1] = diffPopup

            row.diffBtn = diffBtn
            row.diffPopup = diffPopup
            row.UpdateDiffButtons = function()
                UpdateDiffLabel()
            end


            -- Build class/spec data
            local CLASS_COLORS = RAID_CLASS_COLORS
            local allClassSpecs = {}
            for classIdx = 1, GetNumClasses() do
                local className, classFile, classID = GetClassInfo(classIdx)
                if className then
                    local specs = {}
                    for specIdx = 1, GetNumSpecializationsForClassID(classID) do
                        local sid, sname, _, sicon = GetSpecializationInfoForClassID(classID, specIdx)
                        if sid then
                            specs[#specs + 1] = { specID = sid, specName = sname, specIcon = sicon }
                        end
                    end
                    if #specs > 0 then
                        allClassSpecs[#allClassSpecs + 1] = {
                            classID = classID, className = className,
                            classFile = classFile, specs = specs,
                        }
                    end
                end
            end


            local FLYOUT_ROW_H = 20
            local POPUP_WIDTH = 180
            local CLASSFLYOUT_WIDTH = 160
            -- Determine which class to display in the spec popup.
            -- Always returns a class (falls back to player's class for "all" or nil).
            local function GetSelectedClass()
                local lf = EasyFind.db.lootFilter
                if type(lf) == "table" and lf.classID then
                    for _, cls in ipairs(allClassSpecs) do
                        if cls.classID == lf.classID then return cls end
                    end
                end
                -- Default: player's class
                local _, _, playerClassID = UnitClass("player")
                for _, cls in ipairs(allClassSpecs) do
                    if cls.classID == playerClassID then return cls end
                end
                return allClassSpecs[1]
            end

            -- Apply single selection and rebuild from cache
            local function ApplyFilterSelection()
                if ns.Database then
                    if ns.Database.RefreshDynamicCategory then
                        ns.Database:RefreshDynamicCategory("loot")
                    end
                    ns.Database:SyncEJLootFilter()
                end
                if searchEditBox:GetText() ~= "" then
                    UI:OnSearchTextChanged(searchEditBox:GetText())
                end
            end

            -- Update the spec selector label from lootFilter
            local function UpdateSpecLabel()
                local lbl = row.specSelectLabel
                if not lbl then return end
                local lf = EasyFind.db.lootFilter
                if not lf then
                    -- Default: player's class + current spec, matching EJ format
                    local si = GetSpecialization and GetSpecialization()
                    local _, sname
                    if si then _, sname = GetSpecializationInfo(si) end
                    local className, classFile = UnitClass("player")
                    local cc = classFile and CLASS_COLORS[classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    if sname and className then
                        lbl:SetText(colorStr .. className .. " (" .. sname .. ")|r")
                    else
                        lbl:SetText(colorStr .. (className or "Current Spec") .. "|r")
                    end
                elseif lf == "all" then
                    lbl:SetText("All Classes")
                elseif lf.classID then
                    local cls
                    for _, c in ipairs(allClassSpecs) do
                        if c.classID == lf.classID then cls = c; break end
                    end
                    if not cls then lbl:SetText("?"); return end
                    local cc = CLASS_COLORS[cls.classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    if lf.specID then
                        local sname
                        for _, s in ipairs(cls.specs) do
                            if s.specID == lf.specID then sname = s.specName; break end
                        end
                        lbl:SetText(colorStr .. cls.className .. " (" .. (sname or "?") .. ")|r")
                    else
                        -- All specs for this class
                        lbl:SetText(colorStr .. cls.className .. "|r")
                    end
                end
            end

            -- Check if a filter value matches the current lootFilter
            local function IsFilterMatch(filterVal)
                local lf = EasyFind.db.lootFilter
                -- nil lootFilter = current spec; resolve to player class+spec for comparison
                if not lf then
                    if filterVal == nil then return true end
                    if type(filterVal) == "table" and filterVal.specID then
                        local _, _, cid = UnitClass("player")
                        local si = GetSpecialization and GetSpecialization()
                        local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
                        return filterVal.classID == cid and filterVal.specID == sid
                    end
                    return false
                end
                if filterVal == "all" and lf == "all" then return true end
                if type(filterVal) == "table" and type(lf) == "table" then
                    if filterVal.classID == lf.classID then
                        if filterVal.specID == nil and lf.specID == nil then return true end
                        if filterVal.specID == lf.specID then return true end
                    end
                end
                return false
            end

            -------------------------------------------------------------------
            -- Main spec popup (opens BELOW the bar)
            -- Layout: "Class >" row, then class header, then specs, then "All Specializations"
            -------------------------------------------------------------------
            local specPopup = CreateFrame("Frame", "EasyFindSpecPopup", UIParent, "BackdropTemplate")
            specPopup:SetFrameStrata("TOOLTIP")
            specPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
            StylePopup(specPopup)
            specPopup:EnableMouse(true)
            specPopup:Hide()

            -------------------------------------------------------------------
            -- Class flyout (opens to the RIGHT of the "Class" row)
            -------------------------------------------------------------------
            local classFlyout = CreateFrame("Frame", "EasyFindSpecFlyout", UIParent, "BackdropTemplate")
            classFlyout:SetFrameStrata("TOOLTIP")
            classFlyout:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 30)
            StylePopup(classFlyout)
            classFlyout:EnableMouse(true)
            classFlyout:Hide()

            local LayoutSpecPopup  -- forward declaration for closures below

            -- Helper: create a radio-style row
            local function CreateRadioRow(parent, label, filterVal, width)
                local btn = CreateFrame("Button", nil, parent)
                btn:SetSize(width - 16, FLYOUT_ROW_H)
                btn:SetFrameLevel(parent:GetFrameLevel() + 10)
                local radio, setChecked = CreateRadioTexture(btn)
                radio:SetPoint("LEFT", 4, 0)
                local lbl = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", radio, "RIGHT", 4, 0)
                lbl:SetText(label)
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                btn._setRadioChecked = setChecked
                btn._filterVal = filterVal
                return btn
            end

            -------------------------------------------------------------------
            -- Build class flyout rows (right panel): All Classes + each class
            -------------------------------------------------------------------
            local classFlyoutRows = {}
            -- "All Classes"
            local allClassRow = CreateRadioRow(classFlyout, "All Classes", "all", CLASSFLYOUT_WIDTH)
            allClassRow:SetScript("OnClick", function()
                EasyFind.db.lootFilter = "all"
                UpdateSpecLabel()
                classFlyout:Hide()
                if not classFlyout._keyboardParent then specPopup:Hide() end
                ApplyFilterSelection()
                if specPopup:IsShown() then LayoutSpecPopup() end
            end)
            classFlyoutRows[#classFlyoutRows + 1] = allClassRow
            -- Each class
            for _, cls in ipairs(allClassSpecs) do
                local clsRow = CreateRadioRow(classFlyout, "", { classID = cls.classID }, CLASSFLYOUT_WIDTH)
                -- Override label with class-colored text
                local ccl = CLASS_COLORS[cls.classFile]
                local csStr = ccl and string.format("|cff%02x%02x%02x", ccl.r * 255, ccl.g * 255, ccl.b * 255) or ""
                local clsLabel = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                clsLabel:SetPoint("LEFT", 22, 0)
                clsLabel:SetText(csStr .. cls.className .. "|r")
                clsRow:SetScript("OnClick", function()
                    EasyFind.db.lootFilter = { classID = cls.classID }
                    UpdateSpecLabel()
                    classFlyout:Hide()
                    if not classFlyout._keyboardParent then specPopup:Hide() end
                    ApplyFilterSelection()
                    if specPopup:IsShown() then LayoutSpecPopup() end
                end)
                classFlyoutRows[#classFlyoutRows + 1] = clsRow
            end

            local function LayoutClassFlyout()
                local fy = -6
                local lvl = classFlyout:GetFrameLevel() + 10
                for _, r in ipairs(classFlyoutRows) do
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", classFlyout, "TOPLEFT", 8, fy)
                    r:SetFrameLevel(lvl)
                    r:Show()
                    if r._setRadioChecked then
                        local lf = EasyFind.db.lootFilter
                        local match = false
                        if r._filterVal == "all" and lf == "all" then
                            match = true
                        elseif type(r._filterVal) == "table" then
                            if type(lf) == "table" and r._filterVal.classID == lf.classID then
                                match = true
                            elseif not lf then
                                -- nil = current spec; dot the player's class
                                local _, _, cid = UnitClass("player")
                                match = r._filterVal.classID == cid
                            end
                        end
                        r._setRadioChecked(match)
                    end
                    fy = fy - FLYOUT_ROW_H
                end
                classFlyout:SetSize(CLASSFLYOUT_WIDTH, -fy + 6)
            end

            -------------------------------------------------------------------
            -- Build spec popup rows (main dropdown below bar)
            -------------------------------------------------------------------
            -- Row 1: "Class" with arrow (opens class flyout to the right)
            local classSelectBtn = CreateFrame("Button", nil, specPopup)
            classSelectBtn:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
            classSelectBtn:SetFrameLevel(specPopup:GetFrameLevel() + 10)
            local csLabel = classSelectBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            csLabel:SetPoint("LEFT", 8, 0)
            csLabel:SetText("Class")
            local csArrow = classSelectBtn:CreateTexture(nil, "ARTWORK")
            csArrow:SetSize(16, 16)
            csArrow:SetPoint("RIGHT", -4, 0)
            csArrow:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
            local csHL = classSelectBtn:CreateTexture(nil, "HIGHLIGHT")
            csHL:SetAllPoints()
            csHL:SetColorTexture(1, 1, 1, 0.1)
            local function OpenClassFlyout()
                LayoutClassFlyout()
                classFlyout:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                classFlyout:ClearAllPoints()
                classFlyout:SetPoint("TOPLEFT", classSelectBtn, "TOPRIGHT", 2, 6)
                classFlyout:Show()
            end
            classSelectBtn:SetScript("OnEnter", function() OpenClassFlyout() end)
            classSelectBtn:SetScript("OnClick", function() OpenClassFlyout() end)

            -- Spec rows (rebuilt each time popup opens based on selected class)
            local specRadioRows = {}
            local MAX_SPECS = 5 -- druid has 4 + "All Specializations" = 5
            for si = 1, MAX_SPECS do
                local sRow = CreateRadioRow(specPopup, "", nil, POPUP_WIDTH)
                sRow:Hide()
                specRadioRows[si] = sRow
            end

            -- Class header (non-clickable, shows selected class name)
            local classHeader = CreateFrame("Frame", nil, specPopup)
            classHeader:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
            classHeader:SetFrameLevel(specPopup:GetFrameLevel() + 10)
            local classHeaderLabel = classHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            classHeaderLabel:SetPoint("LEFT", 8, 0)

            LayoutSpecPopup = function()
                local selCls = GetSelectedClass()
                local py = -6
                local lvl = specPopup:GetFrameLevel() + 10

                -- Row 1: "Class >"
                classSelectBtn:ClearAllPoints()
                classSelectBtn:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                classSelectBtn:SetFrameLevel(lvl)
                classSelectBtn:Show()
                py = py - FLYOUT_ROW_H

                if selCls then
                    -- Class header
                    local cc = CLASS_COLORS[selCls.classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    classHeaderLabel:SetText(colorStr .. selCls.className .. "|r")
                    classHeader:ClearAllPoints()
                    classHeader:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                    classHeader:SetFrameLevel(lvl)
                    classHeader:Show()
                    py = py - FLYOUT_ROW_H

                    -- Spec rows
                    local ri = 1
                    for _, spec in ipairs(selCls.specs) do
                        local sRow = specRadioRows[ri]
                        if sRow then
                            -- Update label and filter value
                            local children = { sRow:GetRegions() }
                            for _, child in ipairs(children) do
                                if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                                    if child:GetPoint() then
                                        local _, rel = child:GetPoint()
                                        if rel and rel:GetObjectType() == "Texture" then
                                            child:SetText(spec.specName)
                                        end
                                    end
                                end
                            end
                            sRow._filterVal = { classID = selCls.classID, specID = spec.specID }
                            sRow._setRadioChecked(IsFilterMatch(sRow._filterVal))
                            sRow:SetScript("OnClick", function()
                                EasyFind.db.lootFilter = { classID = selCls.classID, specID = spec.specID }
                                UpdateSpecLabel()
                                classFlyout:Hide()
                                specPopup:Hide()
                                ApplyFilterSelection()
                            end)
                            sRow:SetScript("OnEnter", function()
                                classFlyout:Hide()
                            end)
                            sRow:ClearAllPoints()
                            sRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                            sRow:SetFrameLevel(lvl)
                            sRow:Show()
                            py = py - FLYOUT_ROW_H
                            ri = ri + 1
                        end
                    end

                    -- "All Specializations" row
                    local allRow = specRadioRows[ri]
                    if allRow then
                        local children = { allRow:GetRegions() }
                        for _, child in ipairs(children) do
                            if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                                if child:GetPoint() then
                                    local _, rel = child:GetPoint()
                                    if rel and rel:GetObjectType() == "Texture" then
                                        child:SetText("All Specializations")
                                    end
                                end
                            end
                        end
                        allRow._filterVal = { classID = selCls.classID }
                        allRow._setRadioChecked(IsFilterMatch(allRow._filterVal))
                        allRow:SetScript("OnClick", function()
                            EasyFind.db.lootFilter = { classID = selCls.classID }
                            UpdateSpecLabel()
                            classFlyout:Hide()
                            specPopup:Hide()
                            ApplyFilterSelection()
                        end)
                        allRow:SetScript("OnEnter", function()
                            classFlyout:Hide()
                        end)
                        allRow:ClearAllPoints()
                        allRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                        allRow:SetFrameLevel(lvl)
                        allRow:Show()
                        py = py - FLYOUT_ROW_H
                        ri = ri + 1
                    end

                    -- Hide unused rows
                    for hi = ri, MAX_SPECS do
                        specRadioRows[hi]:Hide()
                    end
                else
                    classHeader:Hide()
                    for _, sr in ipairs(specRadioRows) do sr:Hide() end
                end

                specPopup:SetSize(POPUP_WIDTH, -py + 6)
            end

            -------------------------------------------------------------------
            -- Spec selector dropdown bar
            -------------------------------------------------------------------
            local specSelectRow = CreateFrame("Button", nil, gearOptionsPopup)
            specSelectRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
            local specBg = specSelectRow:CreateTexture(nil, "BACKGROUND")
            specBg:SetAtlas("common-dropdown-textholder")
            specBg:SetAllPoints()
            local specSelectArrow = specSelectRow:CreateTexture(nil, "OVERLAY")
            specSelectArrow:SetAtlas("common-dropdown-a-button-hover")
            specSelectArrow:SetSize(20, 20)
            specSelectArrow:SetPoint("RIGHT", -2, -1)
            specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
            local specSelectLabel = specSelectRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            specSelectLabel:SetPoint("LEFT", 8, 0)
            specSelectLabel:SetPoint("RIGHT", specSelectArrow, "LEFT", -2, 0)
            specSelectLabel:SetJustifyH("LEFT")
            specSelectLabel:SetWordWrap(false)

            specSelectRow:SetScript("OnEnter", function()
                specSelectArrow:SetVertexColor(1, 1, 1)
            end)
            specSelectRow:SetScript("OnLeave", function()
                specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
            end)
            specSelectRow:SetScript("OnClick", function()
                if specPopup:IsShown() then
                    specPopup:Hide()
                else
                    LayoutSpecPopup()
                    specPopup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                    specPopup:ClearAllPoints()
                    specPopup:SetPoint("TOPLEFT", specSelectRow, "BOTTOMLEFT", 0, 2)
                    specPopup:Show()
                end
            end)

            row.specSelectRow = specSelectRow
            row.specSelectLabel = specSelectLabel

            local function GetSpecPopupNavRows()
                local rows = { classSelectBtn }
                for _, sr in ipairs(specRadioRows) do
                    if sr:IsShown() then rows[#rows + 1] = sr end
                end
                return rows
            end

            -- Close on outside click
            specPopup:SetScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            specPopup:SetScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                classFlyout:Hide()
            end)
            specPopup:SetScript("OnEvent", function(self, event)
                if event == "GLOBAL_MOUSE_DOWN" then
                    if not self:IsMouseOver()
                        and not classFlyout:IsMouseOver()
                        and not specSelectRow:IsMouseOver() then
                        self:Hide()
                    end
                end
            end)

            -- Close class flyout when mouse leaves both panels
            classFlyout:SetScript("OnUpdate", function(self)
                if self:IsKeyboardEnabled() then return end
                if not self:IsMouseOver() and not specPopup:IsMouseOver() then
                    if not self._leaveTimer then
                        self._leaveTimer = C_Timer.NewTimer(0.2, function()
                            self._leaveTimer = nil
                            if not self:IsMouseOver() and not classSelectBtn:IsMouseOver() then
                                self:Hide()
                            end
                        end)
                    end
                else
                    if self._leaveTimer then
                        self._leaveTimer:Cancel()
                        self._leaveTimer = nil
                    end
                end
            end)

            -- Register loot popups as dropdown guard frames
            dropdownGuardFrames[#dropdownGuardFrames + 1] = specPopup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = classFlyout

            -- Close flyouts when dropdown hides
            dropdown:HookScript("OnHide", function()
                classFlyout:Hide()
                specPopup:Hide()
            end)

            -- Keyboard nav MUST be added AFTER SetScript calls above
            AddPopupKeyboardNav(specPopup, GetSpecPopupNavRows)
            AddPopupKeyboardNav(classFlyout, function() return classFlyoutRows end)

            -- Keep EasyFindSpecFlyout/EasyFindSpecSubFlyout names for dropdown close guard
            local specFlyout = classFlyout
            row.specFlyout = specFlyout
            row.allClassSpecs = allClassSpecs
            row.lootSubRows = lootSubRows

            -- Layout the controls inside the gear options popup, top-down.
            local gy = -GEAR_POPUP_PAD
            diffBtn:ClearAllPoints()
            diffBtn:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
            gy = gy - 27 - 4
            specSelectRow:ClearAllPoints()
            specSelectRow:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
            gy = gy - 27 - 6
            lootSep:ClearAllPoints()
            lootSep:SetPoint("LEFT", gearOptionsPopup, "LEFT", GEAR_POPUP_PAD, 0)
            lootSep:SetPoint("RIGHT", gearOptionsPopup, "RIGHT", -GEAR_POPUP_PAD, 0)
            lootSep:SetPoint("TOP", 0, gy)
            gy = gy - 6
            for _, sr in ipairs(lootSubRows) do
                sr:ClearAllPoints()
                sr:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
                gy = gy - ROW_HEIGHT
            end
            gearOptionsPopup:SetSize(GEAR_POPUP_WIDTH, -gy + GEAR_POPUP_PAD)

            -- Hover-to-show wiring on the Gear filter row, mirroring the
            -- Collections sub-flyout pattern (with grace timer).
            local gearHideTimer
            local function MaybeHideGear()
                if gearOptionsPopup:IsMouseOver() or row:IsMouseOver() then return end
                local sp = _G["EasyFindSpecPopup"]
                if sp and sp:IsShown() and sp:IsMouseOver() then return end
                if classFlyout:IsShown() and classFlyout:IsMouseOver() then return end
                if row.diffPopup and row.diffPopup:IsShown() and row.diffPopup:IsMouseOver() then return end
                gearOptionsPopup:Hide()
            end
            local function ScheduleHideGear()
                if gearHideTimer then gearHideTimer:Cancel() end
                gearHideTimer = C_Timer.NewTimer(0.15, function()
                    gearHideTimer = nil
                    MaybeHideGear()
                end)
            end
            local function ShowGear()
                if gearHideTimer then gearHideTimer:Cancel(); gearHideTimer = nil end
                SetActiveFlyout(gearOptionsPopup)
                if row.UpdateDiffButtons then row.UpdateDiffButtons() end
                UpdateSpecLabel()
                for _, sr in ipairs(lootSubRows) do
                    if sr.dbKey and sr.SetChecked then
                        sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
                    end
                end
                gearOptionsPopup:SetScale((EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0))
                gearOptionsPopup:ClearAllPoints()
                gearOptionsPopup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
                gearOptionsPopup:Show()
            end
            row.ShowGearOptionsPopup = ShowGear
            row:HookScript("OnEnter", ShowGear)
            row:HookScript("OnLeave", ScheduleHideGear)
            gearOptionsPopup:HookScript("OnEnter", function()
                if gearHideTimer then gearHideTimer:Cancel(); gearHideTimer = nil end
            end)
            gearOptionsPopup:HookScript("OnLeave", ScheduleHideGear)
            gearOptionsPopup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            gearOptionsPopup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                if row.diffPopup then row.diffPopup:Hide() end
                local sp = _G["EasyFindSpecPopup"]
                if sp then sp:Hide() end
                classFlyout:Hide()
                ClearActiveFlyout(self)
            end)
            -- Outside-click: nested diff/spec/class popups act as guards
            -- so clicks inside them don't dismiss the gear options.
            gearOptionsPopup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                if row.diffPopup and row.diffPopup:IsShown() and row.diffPopup:IsMouseOver() then return end
                local sp = _G["EasyFindSpecPopup"]
                if sp and sp:IsShown() and sp:IsMouseOver() then return end
                if classFlyout:IsShown() and classFlyout:IsMouseOver() then return end
                self:Hide()
            end)
            dropdown:HookScript("OnHide", function() gearOptionsPopup:Hide() end)

            row.updateLootToggle = function()
                for _, sr in ipairs(lootSubRows) do
                    if sr.SetChecked and sr.resolveDbPath then
                        local tbl, leaf = sr.resolveDbPath()
                        sr:SetChecked(tbl[leaf] == true)
                    end
                end
                UpdateSpecLabel()
                if row.UpdateDiffButtons then row.UpdateDiffButtons() end
            end
        end

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)

        local kbHighlight = row:CreateTexture(nil, "BACKGROUND")
        kbHighlight:SetAllPoints()
        kbHighlight:SetColorTexture(1, 1, 1, 0.1)
        kbHighlight:Hide()
        row.kbHighlight = kbHighlight

        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db.uiSearchFilters
            filters[opt.key] = self:GetChecked()
            if self.updateLootToggle then self.updateLootToggle() end
            LayoutDropdown()
            if searchEditBox:GetText() ~= "" then
                UI:OnSearchTextChanged(searchEditBox:GetText())
            end
        end)

        checkRows[opt.key] = row
        checkRowsByIndex[i] = row
    end

    -- Layout: positions all rows including map sub-rows, adjusts dropdown height
    local SUB_INDENT = 24
    local dropdownNavRows = {}  -- ordered list of navigable rows (rebuilt on layout)
    local dropdownFocus = 0
    local dropdownKbHighlight = dropdown:CreateTexture(nil, "BACKGROUND")
    dropdownKbHighlight:SetColorTexture(1, 1, 1, 0.1)
    dropdownKbHighlight:Hide()

    local function SetDropdownFocus(idx)
        dropdownFocus = idx
        local target = dropdownNavRows[idx]
        if target then
            dropdownKbHighlight:SetParent(target)
            dropdownKbHighlight:ClearAllPoints()
            dropdownKbHighlight:SetAllPoints(target)
            dropdownKbHighlight:Show()
        else
            dropdownKbHighlight:Hide()
        end
    end

    local function ClearDropdownFocus()
        dropdownFocus = 0
        dropdownKbHighlight:Hide()
    end

    function LayoutDropdown()
        local savedFocus = dropdownFocus
        wipe(dropdownNavRows)
        dropdownKbHighlight:Hide()
        local filters = EasyFind.db.uiSearchFilters
        local y = -PADDING_TOP
        -- Toggle All row
        uncheckRow:ClearAllPoints()
        uncheckRow:SetPoint("TOPLEFT", 8, y)
        dropdownNavRows[#dropdownNavRows + 1] = uncheckRow
        y = y - ROW_HEIGHT
        -- Filter rows
        for i, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRowsByIndex[i]
            -- Hide a child row entirely when its parent toggle is off
            local parentVisible = (not opt.parentKey) or (filters[opt.parentKey] ~= false)
            if not parentVisible then
                row:Hide()
            else
                local rowIndent = opt.parentKey and SUB_INDENT or 0
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 8 + rowIndent, y)
                row:Show()
                dropdownNavRows[#dropdownNavRows + 1] = row
                y = y - ROW_HEIGHT
            end
        end
        dropdown:SetSize(DROPDOWN_WIDTH, -y + PADDING_BOTTOM)
        -- Restore keyboard focus if it was active
        if savedFocus > 0 and dropdown:IsKeyboardEnabled() then
            if savedFocus > #dropdownNavRows then savedFocus = #dropdownNavRows end
            SetDropdownFocus(savedFocus)
        end
    end

    -- Keyboard navigation for the dropdown
    Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
    Utils.SafeCallMethod(dropdown, "SetPropagateKeyboardInput", false)

    dropdown:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        if key == "DOWN" then
            searchFrame.StartKeyRepeat(key, function()
                local next = dropdownFocus + 1
                if next > #dropdownNavRows then next = 1 end
                SetDropdownFocus(next)
            end)
        elseif key == "UP" then
            if dropdownFocus <= 1 then
                self._escapedViaKeyboard = true
                self:Hide()
                return
            end
            searchFrame.StartKeyRepeat(key, function()
                local prev = dropdownFocus - 1
                if prev < 1 then prev = 1 end
                SetDropdownFocus(prev)
            end)
        elseif key == "ENTER" then
            local target = dropdownNavRows[dropdownFocus]
            if target and target.Click then
                target:Click()
            end
        elseif key == "ESCAPE" then
            self._escapedViaKeyboard = true
            -- Route through HandleEscape so flyouts/popups close together
            -- and the editbox refocuses, instead of just self:Hide() which
            -- only hits the main dropdown.
            UI:HandleEscape()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    dropdown:SetScript("OnKeyUp", function(_, key)
        if searchFrame.IsRepeatKey(key) then searchFrame.StopKeyRepeat() end
    end)

    -- (keyboard OnShow/OnHide hooks moved after SetScript calls below)

    -- Uncheck All: toggles all checkboxes off, or all back on if already all unchecked
    uncheckRow:SetScript("OnClick", function()
        local filters = EasyFind.db.uiSearchFilters
        local allUnchecked = true
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            if target[key] ~= false then allUnchecked = false end
        end)
        local newState = allUnchecked
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            target[key] = newState
        end)
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRows[opt.key]
            if row then
                row:SetChecked(newState)
                if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
            end
        end
        local lootRow = checkRows["loot"]
        if lootRow and lootRow.updateLootToggle then lootRow.updateLootToggle() end
        LayoutDropdown()
        if searchEditBox:GetText() ~= "" then
            UI:OnSearchTextChanged(searchEditBox:GetText())
        end
    end)

    LayoutDropdown()

    dropdown:SetScript("OnShow", function(self)
        local filters = EasyFind.db.uiSearchFilters
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
            if row.updateLootToggle then row.updateLootToggle() end
            if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
        end
        LayoutDropdown()
    end)

    dropdown:SetScript("OnHide", function() end)

    -- Keyboard: enable when opened via Enter on filter button
    dropdown:HookScript("OnShow", function(self)
        -- Sync appearance set filters from the default UI. Only repopulate
        -- if something actually changed, so opening the dropdown is cheap.
        if ns.Database and ns.Database.SyncTransmogSetFiltersFromUI then
            local db = EasyFind.db
            local beforeClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local beforeCollected = db.appearanceSetCollected
            local beforeNotCollected = db.appearanceSetNotCollected
            local beforePvE = db.appearanceSetPvE
            local beforePvP = db.appearanceSetPvP

            ns.Database:SyncTransmogSetFiltersFromUI()

            local afterClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local changed = beforeClassID ~= afterClassID
                or beforeCollected ~= db.appearanceSetCollected
                or beforeNotCollected ~= db.appearanceSetNotCollected
                or beforePvE ~= db.appearanceSetPvE
                or beforePvP ~= db.appearanceSetPvP
            if changed and ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("transmogSets")
                if searchEditBox and searchEditBox:GetText() ~= "" then
                    UI:OnSearchTextChanged(searchEditBox:GetText())
                end
            end

            if UI._SyncAppearanceSetOptions then
                UI._SyncAppearanceSetOptions()
            end
        end
        if searchFrame.filterBtn and searchFrame.filterBtn.keyboardFocused then
            dropdownKeyboardMode = true
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
            Utils.SafeCallMethod(self, "EnableKeyboard", true)
            SetDropdownFocus(1)
        end
    end)

    -- Keyboard: cleanup on hide
    dropdown:HookScript("OnHide", function(self)
        ClearDropdownFocus()
        Utils.SafeCallMethod(self, "EnableKeyboard", false)
        if self._escapedViaKeyboard then
            self._escapedViaKeyboard = nil
            dropdownKeyboardMode = false
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
        else
            dropdownKeyboardMode = false
            if searchFrame.ClearToolbarFocus then searchFrame.ClearToolbarFocus() end
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
            if searchFrame.filterBtn then
                local fb = searchFrame.filterBtn
                fb.keyboardFocused = nil
                -- Don't wipe the hover highlight if the cursor is still on
                -- the filter button (the common case when clicking the
                -- button to toggle the dropdown closed). Otherwise the
                -- outline disappears and OnEnter doesn't re-fire until
                -- the cursor leaves and comes back.
                if not fb:IsMouseOver() then
                    if fb.btnBg then fb.btnBg:Hide() end
                    if fb.ringDisc then fb.ringDisc:Hide() end
                    if fb.ringInner then fb.ringInner:Hide() end
                    if fb.UnlockHighlight then fb:UnlockHighlight() end
                end
            end
            -- Skip the ClearFocus when HandleEscape is driving the close —
            -- it intentionally refocuses the editbox so the user can keep
            -- typing. ClearFocus + same-frame SetFocus can lose to internal
            -- editbox state, hence the flag instead of relying on order.
            if searchFrame.editBox and not searchFrame.editBox:IsMouseOver()
               and not UI._escClosingMenus then
                searchFrame.editBox:ClearFocus()
            end
        end
    end)

    -- Close when clicking outside (but not when interacting with sub-filter popups).
    -- Both LeftButton AND RightButton trigger close — without the right-button
    -- check, right-clicking outside dismisses the search bar (whose handler
    -- listens for GLOBAL_MOUSE_DOWN regardless of button) but leaves the
    -- filter dropdown stuck open.
    dropdown:SetScript("OnUpdate", function(self)
        if self:IsShown()
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            if not self:IsMouseOver() and not toggleBtn:IsMouseOver() then
                for _, guard in ipairs(dropdownGuardFrames) do
                    if guard:IsShown() and guard:IsMouseOver() then return end
                end
                self:Hide()
            end
        end
    end)

    -- Toggle on filter button click
    toggleBtn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            local barScale = (EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0)
            dropdown:SetScale(barScale)
            local scale = anchorFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
            local right = anchorFrame:GetRight() * scale
            local bottom = anchorFrame:GetBottom() * scale
            dropdown:ClearAllPoints()
            dropdown:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
            dropdown:Show()
        end
    end)

    searchFrame.filterDropdown = dropdown
end

function EnsureResultButton(index)
    local row = resultButtons[index]
    if not row then
        row = UI:CreateResultButton(index)
        resultButtons[index] = row
    end
    return row
end

function UI:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", searchFrame, "BackdropTemplate")
    resultsFrame:SetWidth(380)  -- Wide to accommodate tree indentation
    resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 2)
    resultsFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    resultsFrame:SetFrameLevel(searchFrame:GetFrameLevel() + 1)

    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })

    local theme = GetActiveTheme()
    local bgAtlasTex = resultsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgAtlasTex:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 4, -4)
    bgAtlasTex:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -4, 4)
    if theme.resultsBgAtlas then
        bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
    end
    bgAtlasTex:Hide()
    resultsFrame.bgAtlasTex = bgAtlasTex

    resultsFrame:Hide()

    -- Click-outside-to-close: hides the results frame on any click that
    -- isn't on the search bar, results frame, or one of its associated
    -- popups (filter dropdown, pin/right-click menu, gear/collections
    -- option popups). Hover-out doesn't close — that's too sensitive.
    resultsFrame:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    resultsFrame:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    resultsFrame:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if searchFrame and searchFrame:IsMouseOver() then return end
        local guards = {
            _G["EasyFindUIFilterDropdown"],
            _G["EasyFindPinPopup"],
            _G["EasyFindAsOptionsPopup"],
            _G["EasyFindAsClassPopup"],
            _G["EasyFindGearOptionsPopup"],
            _G["EasyFindDiffPopup"],
            _G["EasyFindSpecPopup"],
            _G["EasyFindSpecFlyout"],
        }
        for _, g in ipairs(guards) do
            if Utils.IsFrameOrChildMouseOver(g) then return end
        end
        UI:HideResults()
    end)

    local resizeTimer
    resultsFrame:SetScript("OnSizeChanged", function()
        if not resultsFrame:IsShown() or not cachedHierarchical then return end  -- luacheck: ignore 113
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.02, function()
            resizeTimer = nil
            UI:ShowHierarchicalResults(cachedHierarchical, true)  -- luacheck: ignore 113
        end)
    end)

    -- Plain ScrollFrame for clipping. Wheel handler is wired up by
    -- CreateMinimalScrollBar so wheel events route through the eased path.
    local scrollFrame = CreateFrame("ScrollFrame", nil, resultsFrame)
    resultsFrame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    resultsFrame.scrollChild = scrollChild

    -- Minimal retail-style scrollbar (overlays right edge, no content squish)
    resultsFrame.scrollBar = ns.Utils.CreateMinimalScrollBar(scrollFrame, resultsFrame)

    -- Pin section separator line (golden, shown between pinned items and search results)
    local pinSeparator = scrollChild:CreateTexture(nil, "ARTWORK")
    pinSeparator:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    pinSeparator:SetHeight(1)
    pinSeparator:Hide()
    resultsFrame.pinSeparator = pinSeparator

    -- Category separator lines (between result category groups)
    local categorySeps = {}
    for sepIdx = 1, 6 do
        local sep = scrollChild:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.3)
        sep:SetHeight(1.5)
        sep:Hide()
        categorySeps[sepIdx] = sep
    end
    resultsFrame.categorySeps = categorySeps
end

-- Per-depth indent line colors. Used as a fallback when a theme's
-- indentColors array doesn't define a color for the requested depth.
local INDENT_COLORS = {
    {0.40, 0.85, 1.00, 0.80},
    {1.00, 0.55, 0.10, 0.80},
    {0.55, 1.00, 0.35, 0.80},
    {1.00, 0.40, 0.70, 0.80},
    {0.70, 0.55, 1.00, 0.80},
    {1.00, 0.90, 0.20, 0.80},
}

local INDENT_PX  = 20  -- pixels per depth level (icon 16 + 4 gap)
local LINE_X_OFF = 10  -- horizontal offset within each depth column (clears tab rounded corner)
local LINE_W     = 2   -- connector line thickness
local MAX_DEPTH  = 0

-- Session-only collapse state for path nodes (cleared on every new search)
local collapsedNodes = {}   -- key = "name_depth", value = true
local cachedHierarchical    -- last full hierarchical list for re-rendering after toggle

local flatEntries = {}
local flatCombined = {}
local pinnedSearchEntries = {}
local pinnedSearchPinEntries = {}
local pinnedOnlyEntries = {}

-- Inline achievement search: drive Blizzard's own indexed achievement
-- search system (the one that powers the AchievementFrame's search box)
-- in the background. SetAchievementSearchString builds an internal
-- index on first call and emits ACHIEVEMENT_SEARCH_UPDATED when results
-- are ready; GetFilteredAchievementID(i) reads them out. We pre-warm
-- the index once after login so per-keystroke searches are instant,
-- and we synthesize result rows on the fly without pre-loading any of
-- the ~25k achievement entries into our own search index.
local ACHIEVEMENT_PROTO = {
    keywords      = {},
    keywordsLower = {},
    category      = "Achievement",
    buttonFrame   = "AchievementMicroButton",
    path          = { "Achievements" },
}
local ACHIEVEMENT_MT = { __index = ACHIEVEMENT_PROTO }
local achievementEntryByID = {}
local achSearchCache = {}
local achSearchPending = nil
local achSearchListener
local achSearchPrewarmed = false
local ACH_MAX_RESULTS = 8

local function GetOrCreateAchievementEntry(id, name, icon)
    local entry = achievementEntryByID[id]
    if entry then
        if name and entry.name ~= name then
            entry.name = name
            entry.nameLower = slower(name)
        end
        if icon and entry.icon ~= icon then entry.icon = icon end
        return entry
    end
    entry = setmetatable({
        name = name,
        nameLower = slower(name or ""),
        achievementID = id,
        icon = icon,
        steps = { { buttonFrame = "AchievementMicroButton", achievementID = id } },
    }, ACHIEVEMENT_MT)
    achievementEntryByID[id] = entry
    return entry
end

local function CollectAchievementSearchResults(query)
    local getNum = _G["GetNumFilteredAchievements"]
    local getID  = _G["GetFilteredAchievementID"]
    local getInfo = _G["GetAchievementInfo"]
    if not getNum or not getID or not getInfo then return nil end
    local count = getNum() or 0
    if count == 0 then return {} end
    local capped = count > ACH_MAX_RESULTS and ACH_MAX_RESULTS or count
    local results = {}
    for i = 1, capped do
        local id = getID(i)
        if id then
            local _, name, _, _, _, _, _, _, _, icon = getInfo(id)
            if name and name ~= "" then
                results[#results + 1] = GetOrCreateAchievementEntry(id, name, icon)
            end
        end
    end
    return results
end

local function EnsureAchievementSearchListener()
    if achSearchListener then return end
    achSearchListener = CreateFrame("Frame")
    achSearchListener:RegisterEvent("ACHIEVEMENT_SEARCH_UPDATED")
    achSearchListener:SetScript("OnEvent", function()
        local pending = achSearchPending
        if not pending then return end
        achSearchPending = nil
        local results = CollectAchievementSearchResults(pending)
        if results then achSearchCache[pending] = results end
        local eb = searchFrame and searchFrame.editBox
        if eb then
            -- Compare against the typed prefix (cursor-position cut),
            -- not the full editbox text. The autocomplete suffix is
            -- selected past the cursor and would make full text != pending.
            local full = eb:GetText() or ""
            local cursor = eb:GetCursorPosition() or #full
            local typedPrefix = strtrim(full:sub(1, cursor))
            if typedPrefix == pending then
                UI:OnSearchTextChanged(typedPrefix, true)
            end
        end
    end)
end

function UI:RequestAchievementSearch(query)
    if not query or #query < 2 then return nil end
    local cached = achSearchCache[query]
    if cached then return cached end
    local setSearch = _G["SetAchievementSearchString"]
    if not setSearch then return nil end
    EnsureAchievementSearchListener()
    achSearchPending = query
    pcall(setSearch, query)
    return nil
end

function UI:PrewarmAchievementSearch()
    if achSearchPrewarmed then return end
    achSearchPrewarmed = true
    local loadUI = _G["AchievementFrame_LoadUI"]
    if loadUI then pcall(loadUI) end
    EnsureAchievementSearchListener()
    local setSearch = _G["SetAchievementSearchString"]
    if not setSearch then return end
    -- Trigger the one-time index build off the player's typing path.
    -- A nonsensical query that won't match anything keeps the search
    -- box visually empty if the user opens AchievementFrame later.
    pcall(setSearch, "\1")
    if Utils and Utils.SafeAfter then
        Utils.SafeAfter(0.5, function() pcall(setSearch, "") end)
    end
end

local SCRATCH = {
    visible = {},
    isLastChild = {},
    catSepYPositions = {},
    aliasSeen = {},
    filteredResults = {},
    skipCategories = {},
}

UI._flatEntries = flatEntries
UI._flatCombined = flatCombined
UI._pinnedSearchEntries = pinnedSearchEntries
UI._pinnedSearchPinEntries = pinnedSearchPinEntries
UI._SCRATCH = SCRATCH
UI._resultButtons = resultButtons

local heavySearchLoading = false

local function MaybeLoadHeavySearchData(text, needsHeavy)
    if heavySearchLoading or not ns.Database or not ns.Database.LoadHeavyDynamicSearchData then return end
    if not needsHeavy then return end
    heavySearchLoading = true
    local started = ns.Database:LoadHeavyDynamicSearchData(function(anyChanged)
        heavySearchLoading = false
        -- Only re-run search when a provider actually loaded fresh data.
        -- Without this gate, every keystroke after providers are loaded
        -- triggers heavy-load chain → callback → search → heavy-load
        -- chain → ... an infinite loop that allocates ~10 MB/sec across
        -- result re-rendering and SearchUI's per-iteration scratch.
        if not anyChanged then return end
        local currentText = searchFrame and searchFrame.editBox and searchFrame.editBox:GetText()
        if searchFrame and searchFrame.editBox and searchFrame.editBox:HasFocus()
           and currentText and currentText ~= "" then
            UI:OnSearchTextChanged(currentText, true)
        end
    end)
    if not started then heavySearchLoading = false end
end

local function RefocusSearchEditBox()
    if searchFrame and searchFrame.editBox
       and not (navFrame and navFrame:IsKeyboardEnabled()) then
        searchFrame.editBox.blockFocus = nil
        searchFrame.editBox:SetFocus()
    end
end

local function ReadSettingVariable(variable)
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.GetValue then
            local vok, value = pcall(settObj.GetValue, settObj)
            if vok then return value end
        end
    end
    if GetCVar then
        local ok, value = pcall(GetCVar, variable)
        if ok then return value end
    end
end

local function WriteSettingVariable(variable, value)
    -- Prefer the per-setting object: GetSetting returns nil for variables
    -- the Settings panel doesn't know about, so a successful SetValue here
    -- means the write actually went somewhere. Settings.SetValue (static)
    -- is a silent no-op for unregistered variables, so we skip it.
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.SetValue then
            -- Coerce to the setting's declared variable type before
            -- writing. Type mismatches (e.g. passing "1" to a number
            -- setting) make Setting:SetValue silently no-op, which
            -- looks like a flicker on our row: pcall succeeds but
            -- the underlying value never changes.
            local writeValue = value
            if settObj.GetVariableType then
                local tok, vtype = pcall(settObj.GetVariableType, settObj)
                if tok and type(vtype) == "string" then
                    if vtype == "number" then
                        writeValue = tonumber(value) or value
                    elseif vtype == "string" then
                        writeValue = tostring(value)
                    elseif vtype == "boolean" then
                        if type(value) == "boolean" then
                            writeValue = value
                        elseif value == "1" or value == 1 or value == "true" then
                            writeValue = true
                        elseif value == "0" or value == 0 or value == "false" then
                            writeValue = false
                        end
                    end
                end
            end
            if pcall(settObj.SetValue, settObj, writeValue) then
                -- Settings flagged with CommitFlag.Apply stage to
                -- pendingValue (graphics, resolution, etc.) and need
                -- the user to commit. Tell BlizzOptionsSearch so the
                -- floating Apply/Revert bar can surface the change.
                if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.NotePendingApply then
                    ns.BlizzOptionsSearch:NotePendingApply(variable)
                end
                -- Verify: SetValue can succeed on the call but reject
                -- the value internally. Read back to confirm it took.
                if settObj.GetValue then
                    local rok, raw = pcall(settObj.GetValue, settObj)
                    if rok and (raw == writeValue or tostring(raw) == tostring(writeValue)) then
                        return true
                    end
                else
                    return true
                end
            end
        end
    end
    -- CVar fallback for raw CVars not registered with the Settings panel.
    -- Booleans need explicit "1"/"0" — tostring(true) gives "true", which
    -- a CVar slot would store literally and break the next read.
    if SetCVar then
        local cvarVal
        if type(value) == "boolean" then
            cvarVal = value and "1" or "0"
        else
            cvarVal = tostring(value)
        end
        if pcall(SetCVar, variable, cvarVal) then return true end
    end
    return false
end

local function ActivateSettingResult(data, ctrlHeld)
    if not data or not data.settingVariable then return false end
    local stype = data.settingType
    if stype == "checkbox" and not ctrlHeld then
        -- Plain click toggles inline. Ctrl+click falls through to open
        -- the in-game Settings panel for the same variable.
        UI:ToggleSettingCheckbox(data)
    else
        -- Slider / keybind / dropdown / unknown: open the Settings
        -- panel for that variable. Inline editors (slider drag, kb1/kb2
        -- capture, dropdown paddles) sit on top of the row and consume
        -- their own clicks, so the row click reaching us means the user
        -- clicked the label area and wants to navigate to the setting.
        UI:OpenSettingNoClose(data)
    end
    return true
end

-- Within-group ordering for flat-list mode. Score-first so the best
-- matches stay at the top — alphabetical was burying high-scoring
-- prefix matches (e.g. "Skull Bash" for query "skull") below low-
-- scoring fuzzy matches (e.g. "Armor Skills" via "skill"). Path/name
-- only break ties between equally-scored results so siblings under
-- the same parent still cluster predictably.
local function FlatNameLess(ra, rb)
    local sa, sb = ra.score or 0, rb.score or 0
    if sa ~= sb then return sa > sb end
    return (ra.data.name or "") < (rb.data.name or "")
end

-- Custom popup for inline setting dropdowns. Replaces MenuUtil.CreateContextMenu
-- because MenuUtil's option buttons can have a click target that's narrower than
-- the visible label for very long strings, which silently swallows selection.
-- This popup auto-sizes to the longest label so every row's clickable area
-- matches its visible text exactly.
local inlineDropdownPopup
local inlineDropdownRows = {}
local function GetInlineDropdownPopup()
    if inlineDropdownPopup then return inlineDropdownPopup end
    local p = CreateFrame("Frame", "EasyFindInlineDropdownPopup", UIParent, "BackdropTemplate")
    -- Match the bar's FULLSCREEN_DIALOG so the popup renders ABOVE the
    -- bar instead of behind it. Other popups (filter dropdown sub-menus,
    -- spec/class flyouts) already use TOOLTIP which sits above this.
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetFrameLevel(200)
    p:Hide()
    p:EnableMouse(true)
    p:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    p:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    p:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self.owner and self.owner:IsMouseOver() then return end
        self:Hide()
    end)
    p:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        EasyFind._inlineDropdownMenuOpen = true
    end)
    p:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        EasyFind._inlineDropdownMenuOpen = false
    end)
    inlineDropdownPopup = p
    return p
end

local function GetInlineDropdownRow(popup, index)
    local row = inlineDropdownRows[index]
    if row then return row end
    row = CreateFrame("Button", nil, popup)
    row:SetHeight(20)
    local radio = row:CreateTexture(nil, "ARTWORK")
    radio:SetSize(14, 14)
    radio:SetTexture("Interface\\AddOns\\EasyFind\\radio-off")
    radio:SetPoint("LEFT", 6, 0)
    row.radio = radio
    local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("LEFT", radio, "RIGHT", 6, 0)
    lbl:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetMaxLines(1)
    row.lbl = lbl
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    inlineDropdownRows[index] = row
    return row
end

local function ShowInlineSettingDropdown(owner, opts, getCurrent, onSelect)
    local popup = GetInlineDropdownPopup()
    popup.owner = owner
    -- Hide any prior rows in the pool.
    for i = 1, #inlineDropdownRows do
        inlineDropdownRows[i]:Hide()
        inlineDropdownRows[i]:SetScript("OnClick", nil)
    end
    -- Measure longest label so the popup auto-sizes.
    local maxTextW = 0
    local probe = popup._probeFS
    if not probe then
        probe = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        probe:Hide()
        popup._probeFS = probe
    end
    for i = 1, #opts do
        local label = opts[i].label or tostring(opts[i].value)
        probe:SetText(label)
        local w = (probe.GetUnboundedStringWidth and probe:GetUnboundedStringWidth())
            or (probe.GetStringWidth and probe:GetStringWidth())
            or 0
        if w > maxTextW then maxTextW = w end
    end
    local PAD_LR = 6 + 14 + 6 + 6     -- left pad + radio + gap + right pad
    local PAD_TOP = 8
    local PAD_BOT = 8
    local ROW_H = 20
    local popupW = math.max(140, math.ceil(maxTextW) + PAD_LR + 12)
    local popupH = PAD_TOP + (#opts * ROW_H) + PAD_BOT
    popup:SetSize(popupW, popupH)
    popup:ClearAllPoints()
    popup:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    -- Build rows.
    local cur = getCurrent and getCurrent() or nil
    for i = 1, #opts do
        local opt = opts[i]
        local row = GetInlineDropdownRow(popup, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 6, -PAD_TOP - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", popup, "RIGHT", -6, 0)
        row.lbl:SetText(opt.label or tostring(opt.value))
        local checked = cur == opt.value or tostring(cur) == tostring(opt.value)
        row.radio:SetTexture(checked and "Interface\\AddOns\\EasyFind\\radio-on" or "Interface\\AddOns\\EasyFind\\radio-off")
        local optValue = opt.value
        row:SetScript("OnClick", function()
            if onSelect then onSelect(optValue) end
            EasyFind._popupGraceUntil = GetTime() + 0.2
            popup:Hide()
        end)
        row:Show()
    end
    popup:Show()
    popup:Raise()
end

UI.HideInlineSettingDropdown = function()
    if inlineDropdownPopup and inlineDropdownPopup:IsShown() then
        inlineDropdownPopup:Hide()
    end
end

-- Expand a container node: inject its database children into cachedHierarchical.
function UI:CreateResultButton(index)
    local scrollChild = resultsFrame.scrollChild
    local resultRow = CreateFrame("Button", "EasyFindResultButton"..index, scrollChild, "SecureActionButtonTemplate")
    resultRow:SetSize(360, 22)
    resultRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, -8 - (index - 1) * 22)

    -- Single highlight texture for both mouse hover and keyboard
    -- selection via LockHighlight, so the two paths look identical.
    -- Uses Blizzard's tapered quest-log row glow atlas.
    resultRow:SetHighlightAtlas("QuestLog-quest-glow-yellow")
    local hlTex = resultRow:GetHighlightTexture()
    if hlTex then hlTex:SetBlendMode("ADD") end

    -- Thin horizontal separator line at the bottom of each row
    local separator = resultRow:CreateTexture(nil, "ARTWORK", nil, 0)
    separator:SetColorTexture(0.5, 0.45, 0.3, 0.3)
    separator:SetHeight(1)
    separator:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 4, 0)
    separator:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 0)
    separator:Hide()
    resultRow.separator = separator

    -- Tree connector textures per depth level
    resultRow.treeVert   = {}   -- vertical │ pass-through for ancestors
    resultRow.treeBranch = {}   -- horizontal ─ branch connector
    resultRow.treeElbow  = {}   -- vertical half-line for └ / ├

    for d = 1, MAX_DEPTH do
        local c = INDENT_COLORS[d]
        local xCenter = (d - 1) * INDENT_PX + LINE_X_OFF

        local vert = resultRow:CreateTexture(nil, "BACKGROUND")
        vert:SetColorTexture(c[1], c[2], c[3], 1)
        vert:SetWidth(LINE_W)
        vert:SetPoint("TOP",    resultRow, "TOPLEFT",    xCenter, 3)
        vert:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", xCenter, -1)
        vert:Hide()
        resultRow.treeVert[d] = vert

        local elbow = resultRow:CreateTexture(nil, "BACKGROUND")
        elbow:SetColorTexture(c[1], c[2], c[3], 1)
        elbow:SetWidth(LINE_W)
        elbow:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
        elbow:SetHeight(13)
        elbow:Hide()
        resultRow.treeElbow[d] = elbow

        local branch = resultRow:CreateTexture(nil, "BACKGROUND")
        branch:SetColorTexture(c[1], c[2], c[3], 1)
        branch:SetHeight(LINE_W)
        branch:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -11)
        branch:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -11)
        branch:Hide()
        resultRow.treeBranch[d] = branch
    end

    local icon = resultRow:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 0, 0)
    resultRow.icon = icon

    -- Cooldown sweep overlay for toy icons
    local iconCooldown = CreateFrame("Cooldown", nil, resultRow, "CooldownFrameTemplate")
    iconCooldown:SetDrawEdge(true)
    iconCooldown:SetHideCountdownNumbers(true)
    iconCooldown:Hide()
    resultRow.iconCooldown = iconCooldown

    -- Pin indicator (small map pin badge on the icon)
    local pinIcon = resultRow:CreateTexture(nil, "OVERLAY")
    pinIcon:SetSize(13, 13)
    pinIcon:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", -4, -1)
    pinIcon:SetAtlas("Waypoint-MapPin-ChatIcon")
    pinIcon:Hide()
    resultRow.pinIcon = pinIcon

    -- Pin header toggle icon (expand/collapse, right-aligned on the button itself)
    local pinToggle = resultRow:CreateTexture(nil, "ARTWORK")
    pinToggle:SetSize(14, 14)
    pinToggle:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    pinToggle:SetAtlas("QuestLog-icon-shrink")
    pinToggle:Hide()
    resultRow.pinToggle = pinToggle

    -- Pin header underline (thin golden line below the header text)
    local pinHeaderLine = resultRow:CreateTexture(nil, "ARTWORK")
    pinHeaderLine:SetHeight(1)
    pinHeaderLine:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    pinHeaderLine:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 0, 0)
    pinHeaderLine:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", 0, 0)
    pinHeaderLine:Hide()
    resultRow.pinHeaderLine = pinHeaderLine

    -- Section-label visuals: centered fontstring flanked by two faint
    -- gold rules (matches MapTab's "Pinned" / "This Zone" / etc. style).
    -- Used for category headers (UI/Mounts/Toys/...) instead of the
    -- chunkier QuestLog-tab parent header so categories take less
    -- vertical space and don't waste a parent indent.
    local sectionLabelLeft = resultRow:CreateTexture(nil, "ARTWORK")
    sectionLabelLeft:SetHeight(1)
    sectionLabelLeft:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    sectionLabelLeft:Hide()
    resultRow.sectionLabelLeft = sectionLabelLeft

    local sectionLabelRight = resultRow:CreateTexture(nil, "ARTWORK")
    sectionLabelRight:SetHeight(1)
    sectionLabelRight:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    sectionLabelRight:Hide()
    resultRow.sectionLabelRight = sectionLabelRight

    local sectionLabelText = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabelText:SetPoint("CENTER", resultRow, "CENTER", 0, 0)
    sectionLabelText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
    sectionLabelText:Hide()
    resultRow.sectionLabelText = sectionLabelText

    -- Right-aligned currency amount label
    local amountText = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    amountText:SetJustifyH("RIGHT")
    amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
    amountText:Hide()
    resultRow.amountText = amountText

    -- Right-aligned setting state widget (checkbox + optional checkmark
    -- overlay for boolean settings). For dropdowns we reuse amountText
    -- to show the current value; this widget is the boolean visual.
    -- The box stays visible whether checked or not; the checkmark is
    -- a separate overlay that toggles on/off, so the box doesn't
    -- vanish behind the checkmark when the setting is enabled.
    local settingState = resultRow:CreateTexture(nil, "OVERLAY")
    settingState:SetSize(16, 16)
    settingState:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    settingState:SetAtlas("checkbox-minimal")
    settingState:Hide()
    resultRow.settingState = settingState

    local settingCheck = resultRow:CreateTexture(nil, "OVERLAY", nil, 1)
    settingCheck:SetSize(16, 16)
    settingCheck:SetPoint("CENTER", settingState, "CENTER", 0, 0)
    settingCheck:SetAtlas("checkmark-minimal")
    settingCheck:Hide()
    resultRow.settingCheck = settingCheck

    -- SliderWithSteppers-style widget for slider settings. The minus
    -- and plus buttons step the value by data.settingStep. The slider
    -- itself supports drag and click-on-track. Frame levels are bumped
    -- above the parent row so clicks land on the widget, not the row.
    local sliderGroup = CreateFrame("Frame", nil, resultRow)
    sliderGroup:SetSize(140, 18)
    sliderGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
    sliderGroup:SetFrameLevel(resultRow:GetFrameLevel() + 5)
    sliderGroup:Hide()
    resultRow.settingSliderGroup = sliderGroup

    local function applySettingValue(variable, newVal)
        if not variable then return end
        -- Same priority as WriteSettingVariable: object-based first
        -- (only registered settings expose a Setting object), then
        -- SetCVar for raw CVars. The slider only ever passes numbers,
        -- so type-conversion edge cases don't matter here, but mirror
        -- the same shape so the two writers stay in sync.
        if Settings and Settings.GetSetting then
            local sok, settObj = pcall(Settings.GetSetting, variable)
            if sok and settObj and settObj.SetValue then
                if pcall(settObj.SetValue, settObj, newVal) then
                    -- Slider drag goes through here, not WriteSettingVariable,
                    -- so trigger the same Apply-flag tracking so the per-row
                    -- apply ext appears.
                    if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.NotePendingApply then
                        ns.BlizzOptionsSearch:NotePendingApply(variable)
                    end
                    return
                end
            end
        end
        if SetCVar then
            pcall(SetCVar, variable, tostring(newVal))
        end
    end

    local function clampToRange(value, slider)
        local minV, maxV = slider:GetMinMaxValues()
        if value < minV then return minV end
        if value > maxV then return maxV end
        return value
    end

    local stepBack = CreateFrame("Button", nil, sliderGroup)
    stepBack:SetSize(11, 18)
    stepBack:SetPoint("LEFT", sliderGroup, "LEFT", 0, 0)
    stepBack:EnableMouse(true)
    local stepBackTex = stepBack:CreateTexture(nil, "ARTWORK")
    stepBackTex:SetAllPoints()
    stepBackTex:SetAtlas("Minimal_SliderBar_Button_Left")
    stepBack:SetHighlightAtlas("Minimal_SliderBar_Button_Left", "ADD")
    resultRow.settingStepBack = stepBack

    local stepFwd = CreateFrame("Button", nil, sliderGroup)
    stepFwd:SetSize(11, 18)
    stepFwd:SetPoint("RIGHT", sliderGroup, "RIGHT", 0, 0)
    stepFwd:EnableMouse(true)
    local stepFwdTex = stepFwd:CreateTexture(nil, "ARTWORK")
    stepFwdTex:SetAllPoints()
    stepFwdTex:SetAtlas("Minimal_SliderBar_Button_Right")
    stepFwd:SetHighlightAtlas("Minimal_SliderBar_Button_Right", "ADD")
    resultRow.settingStepFwd = stepFwd

    local settingSlider = CreateFrame("Slider", nil, sliderGroup)
    settingSlider:SetPoint("LEFT", stepBack, "RIGHT", 2, 0)
    settingSlider:SetPoint("RIGHT", stepFwd, "LEFT", -2, 0)
    settingSlider:SetHeight(16)
    settingSlider:EnableMouse(true)
    settingSlider:SetOrientation("HORIZONTAL")
    -- Match Blizzard's SliderWithSteppers atlases (Minimal_SliderBar_*).
    -- Track is composed of Left/Right endcaps + a stretchable Middle.
    -- Thumb is the diamond Minimal_SliderBar_Button atlas.
    local trackLeft = settingSlider:CreateTexture(nil, "ARTWORK")
    trackLeft:SetAtlas("Minimal_SliderBar_Left", true)
    trackLeft:SetPoint("LEFT", 0, 0)
    local trackRight = settingSlider:CreateTexture(nil, "ARTWORK")
    trackRight:SetAtlas("Minimal_SliderBar_Right", true)
    trackRight:SetPoint("RIGHT", 0, 0)
    local trackMid = settingSlider:CreateTexture(nil, "ARTWORK")
    trackMid:SetAtlas("_Minimal_SliderBar_Middle", false)
    trackMid:SetPoint("LEFT", trackLeft, "RIGHT", 0, 0)
    trackMid:SetPoint("RIGHT", trackRight, "LEFT", 0, 0)
    trackMid:SetHeight(16)
    -- Need a real texture file before GetThumbTexture returns a
    -- valid Texture object; UI-SliderBar-Button-Horizontal is a
    -- guaranteed core texture. We immediately swap to the Minimal
    -- diamond atlas via SetAtlas on the same texture.
    settingSlider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = settingSlider:GetThumbTexture()
    if thumb then
        thumb:SetAtlas("Minimal_SliderBar_Button", true)
        thumb:SetSize(20, 19)
    end
    if settingSlider.SetObeyStepOnDrag then settingSlider:SetObeyStepOnDrag(true) end
    settingSlider:EnableMouseWheel(false)
    settingSlider:SetScript("OnMouseWheel", nil)
    settingSlider:SetScript("OnValueChanged", function(self, newVal)
        if self._updating then return end
        applySettingValue(self._settingVar, newVal)
        local valText = resultRow.settingSliderValue
        if not valText then return end
        local fmt = self._settingFormatter
        if not fmt and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
            fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(self._settingVar)
            if fmt then self._settingFormatter = fmt end
        end
        local displayVal
        if fmt then
            local fok, formatted = pcall(fmt, newVal)
            if fok and formatted ~= nil then
                local ft = type(formatted)
                if ft == "string" and formatted ~= "" then
                    displayVal = formatted
                elseif ft == "number" then
                    displayVal = (formatted == mfloor(formatted))
                        and tostring(mfloor(formatted))
                        or sformat("%.2f", formatted)
                end
            end
        end
        if not displayVal then
            displayVal = (newVal == mfloor(newVal))
                and tostring(mfloor(newVal))
                or sformat("%.2f", newVal)
        end
        valText:SetText(displayVal)
    end)
    resultRow.settingSlider = settingSlider

    -- Refresh once on drag-release so the per-row apply ext appears for
    -- Apply-flagged sliders. OnValueChanged fires per-tick during drag,
    -- which would be too expensive to refresh on; OnMouseUp fires once.
    settingSlider:HookScript("OnMouseUp", function() UI:RefreshResults() end)

    stepBack:SetScript("OnClick", function()
        local slider = resultRow.settingSlider
        if not slider:IsShown() then return end
        local cur = slider:GetValue()
        local step = slider:GetValueStep()
        if step == 0 then step = 1 end
        slider:SetValue(clampToRange(cur - step, slider))
    end)
    stepFwd:SetScript("OnClick", function()
        local slider = resultRow.settingSlider
        if not slider:IsShown() then return end
        local cur = slider:GetValue()
        local step = slider:GetValueStep()
        if step == 0 then step = 1 end
        slider:SetValue(clampToRange(cur + step, slider))
    end)

    -- Slider/stepper clicks bypass resultRow's PostClick (clicks on a
    -- child frame don't bubble to the parent button) so the row's own
    -- "refocus editbox" path never runs. Restore focus on mouse-up so
    -- the user can resume typing or arrow-navigating without having
    -- to click the search bar again.
    local function refocusEditbox()
        if not (searchFrame and searchFrame.editBox) then return end
        if navFrame and navFrame:IsKeyboardEnabled() then return end
        searchFrame.editBox.blockFocus = nil
        searchFrame.editBox:SetFocus()
    end
    settingSlider:HookScript("OnMouseUp", refocusEditbox)
    stepBack:HookScript("OnMouseUp", refocusEditbox)
    stepFwd:HookScript("OnMouseUp", refocusEditbox)

    -- Inline keybind editor: two buttons (primary / alternate) showing
    -- the current binding text. Click captures the next keypress and
    -- assigns it to the action. Right-click clears the binding.
    local keybindGroup = CreateFrame("Frame", nil, resultRow)
    keybindGroup:SetSize(140, 20)
    keybindGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
    keybindGroup:SetFrameLevel(resultRow:GetFrameLevel() + 5)
    keybindGroup:Hide()
    resultRow.settingKeybindGroup = keybindGroup

    local function MakeKeybindButton(parent)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(66, 20)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.08, 0.08, 0.08, 0.85)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0.4, 0.4, 0.5, 0.4)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetText("Not Bound")
        local txt = btn:GetFontString()
        if txt then txt:SetPoint("CENTER") end
        local border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
        border:SetAllPoints()
        if border.SetBackdrop then
            border:SetBackdrop({
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            border:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
        end
        -- Forward hover to the parent result row so its tooltip stays
        -- visible when the cursor moves from the row onto these buttons
        -- (Buttons consume hover events, so the row's OnEnter/OnLeave
        -- doesn't see them otherwise).
        btn:HookScript("OnEnter", function(self)
            local rowEnter = resultRow:GetScript("OnEnter")
            if rowEnter then rowEnter(resultRow) end
        end)
        btn:HookScript("OnLeave", function(self)
            local rowLeave = resultRow:GetScript("OnLeave")
            if rowLeave then rowLeave(resultRow) end
        end)
        return btn
    end

    local kb1 = MakeKeybindButton(keybindGroup)
    kb1:SetPoint("LEFT", keybindGroup, "LEFT", 0, 0)
    resultRow.settingKeybind1 = kb1

    local kb2 = MakeKeybindButton(keybindGroup)
    kb2:SetPoint("RIGHT", keybindGroup, "RIGHT", 0, 0)
    resultRow.settingKeybind2 = kb2

    local function StopKeybindCapture(btn)
        if not btn._waitingForKey then return end
        btn._waitingForKey = false
        Utils.SafeCallMethod(btn, "EnableKeyboard", false)
        btn:UnlockHighlight()
        btn:SetScript("OnKeyDown", nil)
        if activeKeybindBtn == btn then activeKeybindBtn = nil end
        if btn._refresh then btn._refresh() end
        -- Defer the editbox re-enable + refocus to next frame: the
        -- captured key's OnChar event still has to fire after this
        -- OnKeyDown handler returns, and refocusing now would let the
        -- editbox receive the character ("A" → bound to A AND typed
        -- into the search bar). Letting the disabled editbox swallow
        -- the OnChar first prevents the leak.
        Utils.SafeAfter(0, function()
            if searchFrame and searchFrame.editBox then
                searchFrame.editBox:SetEnabled(true)
            end
            refocusEditbox()
        end)
    end
    kb1._stopCapture = StopKeybindCapture
    kb2._stopCapture = StopKeybindCapture

    local function StartKeybindCapture(btn, action, slot)
        if btn._waitingForKey then
            StopKeybindCapture(btn)
            return
        end
        if activeKeybindBtn and activeKeybindBtn ~= btn then
            StopKeybindCapture(activeKeybindBtn)
        end
        activeKeybindBtn = btn
        btn._waitingForKey = true
        btn:SetText("Press a key...")
        btn:LockHighlight()
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox.blockFocus = true
            searchFrame.editBox:ClearFocus()
            searchFrame.editBox:SetEnabled(false)
        end
        Utils.SafeCallMethod(btn, "EnableKeyboard", true)
        btn:SetScript("OnKeyDown", function(self, key)
            if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL"
               or key == "RCTRL" or key == "LALT" or key == "RALT" then
                return
            end
            if key == "ESCAPE" then
                StopKeybindCapture(self)
                return
            end
            local hasMod = IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()
            if not hasMod and (key == "SPACE" or key == "ENTER"
                or key == "W" or key == "A" or key == "S" or key == "D") then
                return
            end
            local combo = ""
            if IsAltKeyDown()     then combo = combo .. "ALT-"   end
            if IsControlKeyDown() then combo = combo .. "CTRL-"  end
            if IsShiftKeyDown()   then combo = combo .. "SHIFT-" end
            combo = combo .. key
            -- Only clear the slot we're editing so the other slot
            -- (primary vs alt) stays intact.
            local k1, k2 = GetBindingKey(action)
            local oldKey = (slot == 1) and k1 or k2
            if oldKey then SetBinding(oldKey) end
            SetBinding(combo, action)
            SaveBindings(GetCurrentBindingSet())
            StopKeybindCapture(self)
        end)
    end

    local function MakeBindingClickHandler(slot)
        return function(self, mouseButton)
            local action = self._bindingAction
            if not action then return end
            if mouseButton == "RightButton" then
                if self._waitingForKey then StopKeybindCapture(self); return end
                local k1, k2 = GetBindingKey(action)
                local oldKey = (slot == 1) and k1 or k2
                if oldKey then SetBinding(oldKey) end
                SaveBindings(GetCurrentBindingSet())
                if self._refresh then self._refresh() end
                refocusEditbox()
                return
            end
            StartKeybindCapture(self, action, slot)
        end
    end
    kb1:SetScript("OnClick", MakeBindingClickHandler(1))
    kb2:SetScript("OnClick", MakeBindingClickHandler(2))

    -- Hovering a kb button overrides the row's action-hint subtext with a
    -- Per-slot GameTooltip explaining the rebind workflow. Lives on the
    -- kb buttons themselves so the row's subtext stays focused on what
    -- clicking the row does ("Select to open settings menu").
    local function MakeKbHoverHandler(slotLabel)
        return function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Bind " .. slotLabel .. " key", 1, 1, 1)
            GameTooltip:AddLine("Click then press a key combination.", 0.85, 0.78, 0.55, true)
            GameTooltip:AddLine("Right-click to clear.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end
    end
    local function KbLeaveHandler()
        GameTooltip:Hide()
    end
    kb1:HookScript("OnEnter", MakeKbHoverHandler("primary"))
    kb1:HookScript("OnLeave", KbLeaveHandler)
    kb2:HookScript("OnEnter", MakeKbHoverHandler("alternate"))
    kb2:HookScript("OnLeave", KbLeaveHandler)

    -- Inline dropdown widget for settings whose options enumerate. Matches
    -- the in-game SettingsDropdownWithSteppers control:
    --   prev/next: common-dropdown-c-button-hover-2 (25x25 paddle body)
    --     overlaid with common-dropdown-icon-prev / -icon-next chevron
    --   center: common-dropdown-c-button-hover-1 (stretchable body)
    --     with common-dropdown-c-button-hover-arrow chevron + gold text
    -- WoW Midnight only ships the "-hover" atlases for these (no idle
    -- variant), so we use the hover atlas as the always-visible body.
    local dropdownGroup = CreateFrame("Frame", nil, resultRow)
    dropdownGroup:SetSize(180, 25)
    dropdownGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
    dropdownGroup:SetFrameLevel(resultRow:GetFrameLevel() + 5)
    dropdownGroup:Hide()
    resultRow.settingDropdownGroup = dropdownGroup

    local function MakePaddleButton(parent, iconAtlas)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(25, 25)
        local body = btn:CreateTexture(nil, "BACKGROUND")
        body:SetAllPoints()
        body:SetAtlas("common-dropdown-c-button-hover-2", false)
        local icon = btn:CreateTexture(nil, "OVERLAY")
        icon:SetSize(17, 17)
        icon:SetAtlas(iconAtlas, false)
        icon:SetPoint("CENTER", 0, 0)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetAtlas("common-dropdown-c-button-hover-2", false)
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.4)
        return btn
    end

    local ddPrev = MakePaddleButton(dropdownGroup, "common-dropdown-icon-back")
    ddPrev:SetPoint("LEFT", dropdownGroup, "LEFT", 0, 0)
    resultRow.settingDropdownPrev = ddPrev

    local ddNext = MakePaddleButton(dropdownGroup, "common-dropdown-icon-next")
    ddNext:SetPoint("RIGHT", dropdownGroup, "RIGHT", 0, 0)
    resultRow.settingDropdownNext = ddNext

    local ddCenter = CreateFrame("Button", nil, dropdownGroup)
    ddCenter:SetPoint("LEFT", ddPrev, "RIGHT", 2, 0)
    ddCenter:SetPoint("RIGHT", ddNext, "LEFT", -2, 0)
    ddCenter:SetHeight(25)
    local ddBg = ddCenter:CreateTexture(nil, "BACKGROUND")
    ddBg:SetAllPoints()
    ddBg:SetAtlas("common-dropdown-c-button-hover-1", false)
    local ddHover = ddCenter:CreateTexture(nil, "HIGHLIGHT")
    ddHover:SetAllPoints()
    ddHover:SetAtlas("common-dropdown-c-button-hover-1", false)
    ddHover:SetBlendMode("ADD")
    ddHover:SetAlpha(0.4)
    local ddArrow = ddCenter:CreateTexture(nil, "OVERLAY")
    ddArrow:SetSize(12, 5)
    ddArrow:SetAtlas("common-dropdown-c-button-hover-arrow", false)
    ddArrow:SetPoint("RIGHT", ddCenter, "RIGHT", -8, 0)
    ddCenter:SetNormalFontObject("GameFontNormal")
    local ddTxt = ddCenter:GetFontString()
    if ddTxt then
        ddTxt:SetTextColor(1, 0.82, 0, 1)
        ddTxt:SetPoint("LEFT", ddCenter, "LEFT", 8, 0)
        ddTxt:SetPoint("RIGHT", ddArrow, "LEFT", -4, 0)
        ddTxt:SetJustifyH("CENTER")
        ddTxt:SetWordWrap(false)
        ddTxt:SetNonSpaceWrap(false)
        ddTxt:SetMaxLines(1)
    end
    resultRow.settingDropdownLabel = ddCenter
    -- Width-bounded truncation with ellipses. Anchor-clipped FontStrings
    -- silently chop with no marker, so we measure and append "..." when
    -- the value would overflow the chevron-padded button.
    resultRow.SetSettingDropdownText = function(self, value)
        local btn = self.settingDropdownLabel
        if not btn then return end
        value = value or ""
        btn:SetText(value)
        local fs = btn:GetFontString()
        if not fs then return end
        local btnW = btn:GetWidth() or 0
        -- Reserve room for: 8px left pad + chevron at -8 from right (12 wide,
        -- so 20 from right edge) + 8px gap before the chevron = 36 total.
        local maxW = btnW - 38
        if maxW <= 0 or #value == 0 then return end
        local function getW()
            return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                or (fs.GetStringWidth and fs:GetStringWidth())
                or 0
        end
        if getW() <= maxW then return end
        for cut = #value - 1, 1, -1 do
            btn:SetText(value:sub(1, cut) .. "...")
            if getW() <= maxW then return end
        end
    end

    -- Open our custom dropdown popup on click. Reads opts/current value
    -- from whatever data the row has *now*, since rows are pooled and the
    -- same physical button serves different settings across renders. We
    -- avoid MenuUtil here because its option click target can be narrower
    -- than the visible label for very long strings, silently swallowing
    -- selection on the longest entry.
    ddCenter:SetScript("OnClick", function(self)
        local rowData = resultRow.data
        if not rowData or not rowData.settingVariable then return end
        local opts = rowData.settingOptions
        if not opts and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
            opts = ns.BlizzOptionsSearch.GetOptionsForVariable(rowData.settingVariable)
            if opts then rowData.settingOptions = opts end
        end
        if not opts or #opts == 0 then return end
        local var = rowData.settingVariable
        ShowInlineSettingDropdown(self, opts,
            function() return ReadSettingVariable(var) end,
            function(value) UI:SetSettingDropdownValue(rowData, value) end)
    end)

    ddPrev:SetScript("OnClick", function()
        if resultRow.data then UI:CycleSettingDropdown(resultRow.data, -1) end
    end)
    ddNext:SetScript("OnClick", function()
        if resultRow.data then UI:CycleSettingDropdown(resultRow.data, 1) end
    end)

    ddPrev:HookScript("OnMouseUp", refocusEditbox)
    ddNext:HookScript("OnMouseUp", refocusEditbox)
    ddCenter:HookScript("OnMouseUp", refocusEditbox)

    local settingSliderValue = sliderGroup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    settingSliderValue:SetPoint("BOTTOM", sliderGroup, "TOP", 0, -2)
    settingSliderValue:SetTextColor(0.7, 0.7, 0.7, 1.0)
    settingSliderValue:SetShadowOffset(1, -1)
    resultRow.settingSliderValue = settingSliderValue

    -- Per-row Apply / Reset section. Settings flagged with
    -- CommitFlag.Apply (graphics, resolution, etc.) stage their value
    -- to setting.pendingValue instead of writing through; the row grows
    -- to expose the buttons inline so the change can be committed
    -- without leaving the search.
    local APPLY_EXT_H = 22
    local applyExt = CreateFrame("Frame", nil, resultRow)
    applyExt:SetHeight(APPLY_EXT_H)
    applyExt:SetPoint("TOPLEFT", resultRow, "BOTTOMLEFT", 6, -2)
    applyExt:SetPoint("TOPRIGHT", resultRow, "BOTTOMRIGHT", -6, -2)
    applyExt:Hide()

    local applyExtSep = applyExt:CreateTexture(nil, "ARTWORK")
    applyExtSep:SetColorTexture(0.85, 0.78, 0.55, 0.55)
    applyExtSep:SetHeight(1)
    applyExtSep:SetPoint("TOPLEFT", applyExt, "TOPLEFT", 0, 0)
    applyExtSep:SetPoint("TOPRIGHT", applyExt, "TOPRIGHT", 0, 0)

    local resetBtn = CreateFrame("Button", nil, applyExt, "UIPanelButtonTemplate")
    resetBtn:SetSize(58, 18)
    resetBtn:SetText("Reset")
    resetBtn:SetPoint("RIGHT", applyExt, "CENTER", -2, -2)
    local applyBtn = CreateFrame("Button", nil, applyExt, "UIPanelButtonTemplate")
    applyBtn:SetSize(58, 18)
    applyBtn:SetText("Apply")
    applyBtn:SetPoint("LEFT", applyExt, "CENTER", 2, -2)
    applyBtn:SetScript("OnClick", function()
        local v = resultRow.data and resultRow.data.settingVariable
        if v and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.ApplyVariable then
            ns.BlizzOptionsSearch:ApplyVariable(v)
            UI:RefreshResults()
        end
    end)
    resetBtn:SetScript("OnClick", function()
        local v = resultRow.data and resultRow.data.settingVariable
        if v and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.RevertVariable then
            ns.BlizzOptionsSearch:RevertVariable(v)
            UI:RefreshResults()
        end
    end)
    resultRow.settingApplyExt = applyExt
    resultRow.settingApplyExtH = APPLY_EXT_H

    -- Right-aligned reputation standing bar
    -- Structure: repBar (dark bg + border) → repClip (clips fill) → repFillFrame (colored, same shape)
    --            repBar → repTextOverlay (text on top of everything)
    local repBarBackdrop = {
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 8, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }

    local repBar = CreateFrame("Frame", nil, resultRow, BackdropTemplateMixin and "BackdropTemplate")
    repBar:SetSize(REP_BAR_WIDTH, 19)
    repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
    if repBar.SetBackdrop then
        repBar:SetBackdrop(repBarBackdrop)
        repBar:SetBackdropColor(0.06, 0.06, 0.06, 1.0)
        repBar:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    repBar:Hide()
    resultRow.repBar = repBar

    -- Clip frame controls how much of the fill is visible (left→right)
    local repClip = CreateFrame("Frame", nil, repBar)
    repClip:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repClip:SetPoint("BOTTOMLEFT", repBar, "BOTTOMLEFT", 0, 0)
    repClip:SetWidth(REP_BAR_WIDTH)
    repClip:SetClipsChildren(true)
    resultRow.repClip = repClip

    -- Fill frame: same rounded shape as repBar, but colored; clipped by repClip
    local repFill = CreateFrame("Frame", nil, repClip, BackdropTemplateMixin and "BackdropTemplate")
    repFill:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repFill:SetPoint("BOTTOMRIGHT", repBar, "BOTTOMRIGHT", 0, 0)
    if repFill.SetBackdrop then
        repFill:SetBackdrop(repBarBackdrop)
        repFill:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    resultRow.repFill = repFill

    -- Glossy bar texture (same as WoW default bars); backdrop bgColor matches fill
    -- color so the flat corners blend seamlessly with the glossy center
    local repBarTex = repFill:CreateTexture(nil, "ARTWORK")
    repBarTex:SetPoint("TOPLEFT", repFill, "TOPLEFT", 3, -3)
    repBarTex:SetPoint("BOTTOMRIGHT", repFill, "BOTTOMRIGHT", -3, 3)
    repBarTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    resultRow.repBarTex = repBarTex

    -- Text overlay above everything (not clipped)
    local repTextOverlay = CreateFrame("Frame", nil, repBar)
    repTextOverlay:SetAllPoints()
    repTextOverlay:SetFrameLevel(repFill:GetFrameLevel() + 3)
    local repBarText = repTextOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repBarText:SetPoint("CENTER", repBar, "CENTER", 0, 0)
    repBarText:SetTextColor(1.0, 1.0, 1.0, 1.0)
    repBarText:SetShadowOffset(1, -1)
    resultRow.repBarText = repBarText

    local text = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", amountText, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    -- Single-line, no wrap. The render path uses SetClippedText below
    -- to append "..." when the name is too wide for the available
    -- horizontal space, matching how the dropdown widget truncates.
    text:SetWordWrap(false)
    text:SetNonSpaceWrap(false)
    text:SetMaxLines(1)
    resultRow.text = text

    -- Path subtext (flat-headerless mode only). Anchored under the name in the
    -- render path; hidden by default since most rendering branches don't use it.
    -- Single-line, truncated on overflow so long paths can't wrap into the next row.
    local pathSubtext = resultRow:CreateFontString(nil, "OVERLAY", ns.LEAF_FONT)
    pathSubtext:SetJustifyH("LEFT")
    pathSubtext:SetWordWrap(false)
    pathSubtext:SetNonSpaceWrap(false)
    pathSubtext:SetMaxLines(1)
    pathSubtext:Hide()
    resultRow.pathSubtext = pathSubtext

    -- Flat-mode left-side category icon. Shown for collection rows where the
    -- main icon is repositioned to the right (mounts/toys/pets/outfits/sets),
    -- so the row still has a visual left anchor next to the name+path stack.
    local flatCatIcon = resultRow:CreateTexture(nil, "ARTWORK")
    flatCatIcon:Hide()
    resultRow.flatCatIcon = flatCatIcon

    -- LeftButtonDown for the secure cast: type=spell silently no-ops
    -- on LeftButtonUp for many spells (this was confirmed in the TBC
    -- version where Down works perfectly). RegisterForDrag would
    -- defer the Down click and break that, so we route drag-to-bar
    -- through Shift+click instead (handled in PreClick below).
    resultRow:RegisterForClicks("LeftButtonDown", "RightButtonUp")

    -- Shift+drag on a row picks the action up onto the cursor (for
    -- placing on action bars, banks, etc.) instead of casting. We
    -- can't use RegisterForDrag here because it defers the Down
    -- click and silently breaks type=spell casts. So we do it
    -- manually: PreClick detects Shift and clears the secure type
    -- so the cast doesn't fire, OnMouseDown records the press
    -- position, OnUpdate watches for movement, and the actual
    -- Pickup* call happens once the cursor has moved past the
    -- 5px drag threshold. Plain shift+click without movement
    -- does nothing — matches Blizzard's action-bar drag feel.
    -- C_Spell.PickupSpell is preferred over the legacy global since
    -- Midnight phased PickupSpell out for some spells.
    local function PickupSpellCompat(spellID)
        if C_Spell and C_Spell.PickupSpell then
            C_Spell.PickupSpell(spellID)
        elseif PickupSpell then
            PickupSpell(spellID)
        end
    end
    local function PickupRowAction(d)
        if InCombatLockdown() then return end
        ClearCursor()
        if d.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
            local _, spellID = C_MountJournal.GetMountInfoByID(d.mountID)
            if spellID then PickupSpellCompat(spellID) end
        elseif d.petID and C_PetJournal and C_PetJournal.PickupPet then
            C_PetJournal.PickupPet(d.petID)
        elseif d.toyItemID and C_ToyBox and C_ToyBox.PickupToyBoxItem then
            C_ToyBox.PickupToyBoxItem(d.toyItemID)
        elseif d.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
            C_TransmogOutfitInfo.PickupOutfit(d.outfitID)
        elseif d.macroIndex and PickupMacro then
            PickupMacro(d.macroIndex)
        elseif d.spellID then
            PickupSpellCompat(d.spellID)
        elseif d.bagID and d.bagSlot then
            local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
            if pickup then
                pickup(d.bagID, d.bagSlot)
            elseif d.itemID and PickupItem then
                PickupItem(d.itemID)
            end
        elseif d.itemID and PickupItem then
            PickupItem(d.itemID)
        end
    end
    local DRAG_PX = 5
    -- HookScript not SetScript: SecureActionButtonTemplate uses the
    -- native OnMouseDown / OnMouseUp handlers internally to dispatch
    -- the secure click. SetScript would replace them and break casts.
    resultRow:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if not IsShiftKeyDown() then return end
        if not self.data then return end
        local x, y = GetCursorPosition()
        self._dragOriginX, self._dragOriginY = x, y
    end)
    resultRow:HookScript("OnUpdate", function(self)
        if not self._dragOriginX then return end
        local x, y = GetCursorPosition()
        local dx, dy = x - self._dragOriginX, y - self._dragOriginY
        if dx * dx + dy * dy < DRAG_PX * DRAG_PX then return end
        self._dragOriginX, self._dragOriginY = nil, nil
        self._pickedUp = true
        if self.data then PickupRowAction(self.data) end
    end)
    resultRow:HookScript("OnMouseUp", function(self)
        self._dragOriginX, self._dragOriginY = nil, nil
        -- If we picked up this cycle and the user released over an
        -- action bar slot, place it (emulates native drag-drop, which
        -- we can't get via RegisterForDrag because it'd defer the Down
        -- click and break casts).
        if not self._pickedUp then return end
        if InCombatLockdown() then return end
        local cursorType = GetCursorInfo and GetCursorInfo()
        if not cursorType then return end
        local foci
        if GetMouseFoci then
            foci = GetMouseFoci()
        elseif GetMouseFocus then
            foci = { GetMouseFocus() }
        end
        if not foci then return end
        for i = 1, #foci do
            local f = foci[i]
            local slot = f and (f.action or (f.GetAttribute and f:GetAttribute("action")))
            if slot then
                if PlaceAction then PlaceAction(slot) end
                ClearCursor()
                break
            end
        end
    end)
    resultRow:SetScript("PreClick", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        if InCombatLockdown() then return end

        local d = self.data

        -- Shift held: kill the cast for this click. The pickup (if any)
        -- happens via the OnMouseDown / OnUpdate drag detection above —
        -- this branch only ensures the secure handler is a no-op so
        -- nothing fires when the user hasn't moved yet. Setting the
        -- skip-navigation flag here (not waiting for OnUpdate) is what
        -- prevents PostClick from closing the window before OnUpdate
        -- has had a chance to detect movement and pick up the action.
        if d and IsShiftKeyDown() then
            self:SetAttribute("type", nil)
            self._lastAttrType = nil
            self._lastAttrKey = nil
            self._lastAttrVal = nil
            self._pickedUp = true
            return
        end

        -- Ctrl + macro: suppress the secure macro run so PostClick can
        -- open MacroFrame for editing instead. SelectResult's macro
        -- branch reads IsControlKeyDown() to pick the edit path.
        if d and d.macroIndex and IsControlKeyDown() then
            self:SetAttribute("type", nil)
            self._lastAttrType = nil
            self._lastAttrKey = nil
            self._lastAttrVal = nil
            return
        end

        -- Outfit equip: place onto a temp action slot, then the secure
        -- UseAction dispatch fires on the action attribute.
        local outfitID = d and d.outfitID
        if not outfitID then return end
        if outfitCdStart > 0 and outfitCdDuration - (GetTime() - outfitCdStart) > 0 then
            return
        end
        local tempSlot = ns.Database and ns.Database:FindEmptyActionSlot()
        if not tempSlot then
            self._outfitSlot = nil
            self:SetAttribute("type", nil)
            self:SetAttribute("action", nil)
            return
        end
        self._outfitSlot = tempSlot
        self._outfitID = outfitID
        self:SetAttribute("action", tempSlot)
        if C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
            C_TransmogOutfitInfo.PickupOutfit(outfitID)
            PlaceAction(tempSlot)
            ClearCursor()
            if not HasAction(tempSlot) then
                self._outfitSlot = nil
                self._outfitID = nil
                self:SetAttribute("type", nil)
                self:SetAttribute("action", nil)
            end
        end
    end)
    resultRow:SetScript("PostClick", function(self, mouseButton, down)
        -- Shift+click pickup: cursor is holding the action for the
        -- user to drop on a bar. Don't navigate away or close.
        if self._pickedUp then
            self._pickedUp = nil
            return
        end
        -- Block result selection if outfit equip is on cooldown (keep results open).
        -- Toys are deliberately NOT checked here: GetItemCooldown returns the
        -- cast-time of a freshly-started channel as a "cooldown", which would
        -- keep the window open every time you click a cast-toy (Hearthstone,
        -- garrison hearthstone, etc.). Outfit cooldown is a real swap-lockout
        -- we manage ourselves, so it's safe to gate on.
        if self.data and mouseButton == "LeftButton" and self.data.outfitID
           and outfitCdStart > 0
           and outfitCdDuration - (GetTime() - outfitCdStart) > 0 then
            if searchFrame and searchFrame.editBox and not navFrame:IsKeyboardEnabled() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
            return
        end

        -- Clean up temp action slot after outfit equip.
        if self._outfitSlot then
            local slot = self._outfitSlot
            self._outfitSlot = nil
            -- Record equip immediately so green tint and cooldown
            -- are correct when results re-render (API lags behind).
            if self._outfitID then
                lastEquippedOutfitID = self._outfitID
                outfitCdStart = GetTime()
                outfitCdDuration = 4
                self._outfitID = nil
            end
            -- Delay slot cleanup one frame so UseAction fully completes
            C_Timer.After(0, function()
                -- Read actual cooldown duration if available
                local start, dur = GetActionCooldown(slot)
                if start and dur and dur > 0 then
                    outfitCdStart, outfitCdDuration = start, dur
                end
                PickupAction(slot)
                ClearCursor()
            end)
        end
        -- Right-click: show pin/unpin popup (plus Guide row if entry has a guide path)
        if mouseButton == "RightButton" and self.data then
            local pinData = self.data
            local isPinned = IsUIItemPinned(pinData)
            local hasGuide = pinData.steps or pinData.transmogSetID
                or (pinData.category == "Loot" and pinData.itemID)
                or pinData.mapSearchResult
            local onGuide = hasGuide and function()
                UI:SelectResult(pinData, true)
            end or nil
            local canAlias = ns.Aliases and ns.Aliases:GetEntryKey(pinData) ~= nil
            local onAddAlias = canAlias and function()
                UI:PromptForAlias(pinData)
            end or nil
            local extra
            if pinData.achievementID and pinData.category == "Achievement" then
                local achID = pinData.achievementID
                local isTracked = UI:IsAchievementTracked(achID)
                extra = {
                    isTracked = isTracked,
                    onTrack = function() UI:ToggleAchievementTracked(achID) end,
                }
            elseif pinData.category == "Currency" and pinData.currencyID then
                local cid = pinData.currencyID
                extra = {
                    isOnBackpack = UI:IsCurrencyOnBackpack(cid),
                    onToggleBackpack = function() UI:ToggleCurrencyBackpack(cid) end,
                }
                if UI:IsCurrencyTransferable(cid) then
                    extra.onTransfer = function() UI:RouteCurrencyTransfer(pinData) end
                end
            elseif pinData.transmogSetID then
                local sid = pinData.transmogSetID
                extra = {
                    isFavorite = UI:IsTransmogSetFavorite(sid),
                    onToggleFavorite = function() UI:ToggleTransmogSetFavorite(sid) end,
                }
            elseif pinData.petID then
                local pid = pinData.petID
                local cageable = UI:IsPetCageable(pid)
                extra = {
                    onSummon = function() UI:SummonPet(pid) end,
                    onRename = function() UI:RenamePet(pid) end,
                    isFavorite = UI:IsPetFavorite(pid),
                    onToggleFavorite = function() UI:TogglePetFavorite(pid) end,
                    onCageOrRelease = function()
                        if cageable then UI:CagePet(pid) else UI:ReleasePet(pid) end
                    end,
                    isCageable = cageable,
                }
            end
            ShowPinPopup(self, isPinned, function()
                if isPinned then
                    UnpinUIItem(pinData)
                else
                    PinUIItem(pinData)
                end
                local editBox = searchFrame and searchFrame.editBox
                local text = editBox and editBox:GetText() or ""
                if text == "" then
                    UI:ShowPinnedItems()
                else
                    UI:OnSearchTextChanged(text, true)
                end
            end, onGuide, onAddAlias, extra)
            return
        end

        -- Don't allow clicking unearned currencies
        if self.isUnearnedCurrency then
            return
        end

        -- Setting click. Checkbox: toggle inline (Ctrl+click opens the
        -- panel). Everything else (slider / keybind / dropdown): open
        -- the panel so the user lands on the setting they searched for.
        -- Inline editors (slider drag, kb1/kb2 capture, dropdown
        -- paddles) sit on top of the row and consume their own clicks,
        -- so reaching this handler means the user clicked the label.
        if ActivateSettingResult(self.data, IsControlKeyDown()) then return end

        if self.isPinHeader then
            return
        end

        if self.isPathNode then
            -- Retail theme: headerTab and toggleBtn handle clicks directly
            local isRetailHeader = self.headerTab and self.headerTab:IsShown()
            if isRetailHeader then
                if self.data then
                    UI:SelectResult(self.data)
                end
            else
                -- Classic: +/- icon on left side - 35px zone from icon start
                local cursorX = GetCursorPosition()
                local scale = self:GetEffectiveScale()
                local btnLeft = self:GetLeft() * scale
                local depth = self.pathNodeDepth or 0
                local iconLeft = btnLeft + depth * 20 * scale  -- INDENT_PX = 20
                local isToggleClick = cursorX <= (iconLeft + 35 * scale)

                if isToggleClick then
                    local key = (self.pathNodeName or "") .. "_" .. (self.pathNodeDepth or 0)
                    collapsedNodes[key] = not collapsedNodes[key]
                    if cachedHierarchical then
                        UI:ShowHierarchicalResults(cachedHierarchical, true)
                    end
                elseif self.data then
                    UI:SelectResult(self.data)
                end
            end
        elseif self.data then
            UI:SelectResult(self.data)
        end
    end)

    -- Tooltip for unearned currencies, mounts, and toys
    resultRow:SetScript("OnEnter", function(self)
        -- Hover-based action hint (mirrors keyboard selection hint).
        ApplyActionHint(self)
        -- Macro rows: resolve the #showtooltip / first cast/use line to a
        -- spell or item via the macro APIs and surface that tooltip. Falls
        -- back to displaying the macro body when neither resolves.
        if self.data and self.data.macroIndex and self.data.category == "Macro" then
            local idx = self.data.macroIndex
            local spellID
            if GetMacroSpell then
                local _, _, sid = GetMacroSpell(idx)
                spellID = sid
            end
            local itemName, itemLink
            if not spellID and GetMacroItem then
                itemName, itemLink = GetMacroItem(idx)
            end
            AnchorTooltipAtCursor(GameTooltip, self)
            if spellID and GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(spellID)
            elseif itemLink and GameTooltip.SetHyperlink then
                GameTooltip:SetHyperlink(itemLink)
            elseif itemName and GameTooltip.SetItemByID and select(2, GetItemInfo(itemName)) then
                GameTooltip:SetHyperlink(select(2, GetItemInfo(itemName)))
            else
                GameTooltip:SetText(self.data.name or "Macro", 1, 1, 1)
                if self.data.macroBody and self.data.macroBody ~= "" then
                    GameTooltip:AddLine(self.data.macroBody, 0.7, 0.7, 0.7, true)
                end
            end
            GameTooltip:Show()
            return
        end
        -- Talent / Ability rows: show the spell tooltip (talents share the
        -- spell tooltip surface). Mirrors the icon-OnEnter path so the row
        -- itself produces a tooltip even when the cursor is on the name.
        if self.data and self.data.spellID
           and (self.data.category == "Talent" or self.data.category == "Ability") then
            AnchorTooltipAtCursor(GameTooltip, self)
            if GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(self.data.spellID)
            else
                GameTooltip:SetHyperlink("spell:" .. self.data.spellID)
            end
            GameTooltip:Show()
            return
        end
        -- Currency row: show the currency tooltip (icon + description +
        -- amount). Routed early so it doesn't fall through to the
        -- generic icon-tooltip block, which only checks mount / toy /
        -- pet / etc. fields and would otherwise miss currencies.
        if self.data and self.data.category == "Currency" and self.data.currencyID then
            local cid = self.data.currencyID
            AnchorTooltipAtCursor(GameTooltip, self)
            if GameTooltip.SetCurrencyByID then
                GameTooltip:SetCurrencyByID(cid)
            elseif C_CurrencyInfo and C_CurrencyInfo.GetCurrencyLink then
                local lok, link = pcall(C_CurrencyInfo.GetCurrencyLink, cid)
                if lok and link and GameTooltip.SetHyperlink then
                    GameTooltip:SetHyperlink(link)
                end
            end
            GameTooltip:Show()
            return
        end
        -- Keybinding row: show the action name plus current bindings.
        if self.data and self.data.settingType == "keybind" and self.data.bindingAction then
            local action = self.data.bindingAction
            AnchorTooltipAtCursor(GameTooltip, self)
            GameTooltip:SetText(self.data.name or action, 1, 1, 1)
            local k1, k2 = GetBindingKey(action)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(sformat("Primary: %s", k1 or "Not Bound"), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(sformat("Alternate: %s", k2 or "Not Bound"), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click a button to capture, right-click to clear.",
                0.5, 0.5, 0.5, true)
            GameTooltip:Show()
            return
        end
        -- Game Settings: show the setting's tooltip text plus current
        -- value. Resolved via BlizzOptionsSearch's tooltip cache (live
        -- SettingsPanel + OPTION_TOOLTIP_* globals).
        if self.data and self.data.settingVariable then
            local var = self.data.settingVariable
            local tipText
            if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetTooltipForVariable then
                tipText = ns.BlizzOptionsSearch.GetTooltipForVariable(var, self.data.name)
            end
            AnchorTooltipAtCursor(GameTooltip, self)
            GameTooltip:SetText(self.data.name or var, 1, 1, 1)
            if tipText then
                GameTooltip:AddLine(tipText, 1, 0.82, 0, true)
            end
            -- Slider: append current value + range
            if self.data.settingType == "slider" and self.data.settingMin and self.data.settingMax then
                local cur
                if Settings and Settings.GetSetting then
                    local sok, settObj = pcall(Settings.GetSetting, var)
                    if sok and settObj and settObj.GetValue then
                        local vok, v = pcall(settObj.GetValue, settObj)
                        if vok then cur = v end
                    end
                end
                if cur == nil and GetCVar then cur = GetCVar(var) end
                local n = tonumber(cur)
                if n then
                    GameTooltip:AddLine(" ")
                    if not self.data.settingFormatter
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                        local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(var)
                        if fmt then self.data.settingFormatter = fmt end
                    end
                    local valStr
                    if self.data.settingFormatter then
                        local fok, f = pcall(self.data.settingFormatter, n)
                        if fok and f ~= nil then
                            local ft = type(f)
                            if ft == "string" and f ~= "" then
                                valStr = f
                            elseif ft == "number" then
                                valStr = (f == mfloor(f)) and tostring(mfloor(f)) or sformat("%.2f", f)
                            end
                        end
                    end
                    if not valStr then
                        valStr = (n == mfloor(n)) and tostring(mfloor(n)) or sformat("%.2f", n)
                    end
                    GameTooltip:AddLine(sformat("Current: %s   (%s - %s)",
                        valStr,
                        tostring(self.data.settingMin),
                        tostring(self.data.settingMax)), 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
            return
        end

        if self.isUnearnedCurrency then
            if unearnedTooltip then
                local tooltipText = self.isPathNode and "This tab does not exist on this character yet" or "Currency not yet earned"
                unearnedTooltip.text:SetText(tooltipText)
                local textWidth = unearnedTooltip.text:GetStringWidth()
                local textHeight = unearnedTooltip.text:GetStringHeight()
                unearnedTooltip:SetSize(textWidth + 20, textHeight + 16)
                local scale = UIParent:GetEffectiveScale()
                local x, y = GetCursorPosition()
                unearnedTooltip:ClearAllPoints()
                unearnedTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 10, y / scale + 10)
                unearnedTooltip:Show()
            end
        elseif self.data and self.data.mapSearchResult then
            -- Map result: preview pin on world map if it happens to be open
            if ns.MapSearch and ns.MapSearch.PreviewUIResult then
                ns.MapSearch:PreviewUIResult(self.data)
            end
        elseif self.data and self.icon and self.icon:IsShown() then
            -- Per-flyout tooltip suppression. Collections covers the
            -- mount / toy / pet / outfit / heirloom / appearance set
            -- group; loot (the gear flyout's "Hide tooltips") covers
            -- itemized gear results AND any bag item that's actual
            -- gear — the entry being a "Bag" by category is incidental
            -- to where it lives, the user-facing class of thing is
            -- "gear" either way.
            local ht = EasyFind.db.hideTooltips
            local ic = self.icon
            if ht and ht.collections and (ic.mountID or ic.toyItemID or ic.petID
                or ic.outfitID or ic.heirloomItemID or ic.transmogSetID) then
                return
            end
            if ht and ht.loot then
                if ic.lootItemID then return end
                if ic.bagItemID and self.data and self.data.equipLoc then
                    local slot = self.data.equipLoc
                    if slot ~= "" and slot ~= "INVTYPE_NON_EQUIP"
                       and slot ~= "INVTYPE_AMMO" and slot ~= "INVTYPE_QUIVER" then
                        return
                    end
                end
            end
            -- Mount tooltip (show on icon hover)
            if self.icon.mountID and self.icon.spellID then
                AnchorTooltipAtCursor(GameTooltip, self)
                GameTooltip:SetMountBySpellID(self.icon.spellID)
                GameTooltip:Show()
            -- Toy tooltip with live cooldown refresh
            elseif self.icon.toyItemID then
                local toyItemID = self.icon.toyItemID
                AnchorTooltipAtCursor(GameTooltip, self)
                GameTooltip:SetToyByItemID(toyItemID)
                GameTooltip:Show()
                self.toyTooltipTicker = C_Timer.NewTicker(1, function()
                    if GameTooltip:IsOwned(self) then
                        GameTooltip:SetToyByItemID(toyItemID)
                    end
                end)
            -- Pet tooltip (use BattlePetToolTip via the link, since GameTooltip
            -- only renders battle pet links as raw escape codes)
            elseif self.icon.petID then
                local link = C_PetJournal and C_PetJournal.GetBattlePetLink
                    and C_PetJournal.GetBattlePetLink(self.icon.petID)
                if link and BattlePetToolTip_ShowLink then
                    AnchorTooltipAtCursor(GameTooltip, self)
                    BattlePetToolTip_ShowLink(link)
                elseif link then
                    AnchorTooltipAtCursor(GameTooltip, self)
                    GameTooltip:SetHyperlink(link)
                    GameTooltip:Show()
                end
            -- Outfit tooltip
            elseif self.icon.outfitID then
                AnchorTooltipAtCursor(GameTooltip, self)
                GameTooltip:SetText(self.data and self.data.name or "Outfit")
                GameTooltip:AddLine("Instant", 1, 1, 1)
                GameTooltip:AddLine("Transmogrify the appearance of your\nweapons and armor", 0, 1, 0)
                local activeID = lastEquippedOutfitID
                    or (C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                        and C_TransmogOutfitInfo.GetActiveOutfitID())
                if activeID and activeID == self.icon.outfitID then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Currently equipped", 0.3, 1, 0.3)
                else
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Click to equip", 1, 0.82, 0)
                end
                if C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Lock Appearance:", 1, 1, 1)
                    GameTooltip:AddLine("Prevent this appearance from being\nreplaced by a Situation", 1, 0.82, 0)
                    if C_TransmogOutfitInfo.IsLockedOutfit(self.icon.outfitID) then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Currently locked", 0.3, 1, 0.3)
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("<Right Click icon on action bar\nor transmog window to toggle>", 0.5, 0.5, 0.5)
                end
                GameTooltip:Show()
            -- Loot item tooltip
            elseif self.icon.lootItemID then
                AnchorGearTooltip(GameTooltip, self)
                local itemLink = self.data and ns.Database and ns.Database:GetLootItemLink(self.data)
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(self.icon.lootItemID)
                end
                GameTooltip:Show()
            -- Heirloom tooltip
            elseif self.icon.heirloomItemID then
                AnchorGearTooltip(GameTooltip, self)
                GameTooltip:SetItemByID(self.icon.heirloomItemID)
                GameTooltip:Show()
            -- Ability tooltip (must come after mount, since mount entries
            -- carry both mountID and spellID and use the mount tooltip).
            elseif self.icon.spellID then
                AnchorTooltipAtCursor(GameTooltip, self)
                if GameTooltip.SetSpellByID then
                    GameTooltip:SetSpellByID(self.icon.spellID)
                else
                    GameTooltip:SetHyperlink("spell:" .. self.icon.spellID)
                end
                GameTooltip:Show()
            -- Bag item tooltip. Real gear (helm/chest/weapon/etc.) gets
            -- the panel-edge buffer because of the compare frame; bag
            -- consumables / containers are normal-sized so they follow
            -- the cursor like everything else.
            elseif self.icon.bagItemID then
                local slot = self.data and self.data.equipLoc
                local isGear = slot and slot ~= "" and slot ~= "INVTYPE_NON_EQUIP"
                              and slot ~= "INVTYPE_AMMO" and slot ~= "INVTYPE_QUIVER"
                if isGear then
                    AnchorGearTooltip(GameTooltip, self)
                else
                    AnchorTooltipAtCursor(GameTooltip, self)
                end
                local link = self.data and self.data.bagItemLink
                if link then
                    GameTooltip:SetHyperlink(link)
                else
                    GameTooltip:SetItemByID(self.icon.bagItemID)
                end
                GameTooltip:Show()
            end
        end
    end)

    resultRow:SetScript("OnLeave", function(self)
        if unearnedTooltip then
            unearnedTooltip:Hide()
        end
        if self.toyTooltipTicker then
            self.toyTooltipTicker:Cancel()
            self.toyTooltipTicker = nil
        end
        if GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
        -- BattlePetTooltip is a separate frame; hide it on row leave so
        -- the pet card doesn't linger after the cursor moves away.
        if self.data and self.data.petID and BattlePetTooltip then
            BattlePetTooltip:Hide()
        end
        -- Clear map preview if we were showing one
        if self.data and self.data.mapSearchResult and ns.MapSearch and ns.MapSearch.ClearUIPreview then
            ns.MapSearch:ClearUIPreview()
        end
        -- Restore hint to whatever the keyboard has selected (or clear).
        if actionHintRow == self then
            ClearActionHint()
            local selRow = selectedIndex > 0 and resultButtons[selectedIndex] or nil
            if selRow and selRow ~= self and not toggleFocused then
                ApplyActionHint(selRow)
            end
        end
    end)

    ApplyResultRowFonts(resultRow)
    resultRow:Hide()
    return resultRow
end

-- Prepend `text` to EasyFindDB.uiSearchHistory, dedupe by removing
-- any prior occurrence (case-insensitive) and trim to the configured
-- limit. The most recent search lives at index 1.
function UI:PushSearchHistory(text)
    if not EasyFind.db then return end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" then
        hist = {}
        EasyFind.db.uiSearchHistory = hist
    end
    local lower = text:lower()
    for i = #hist, 1, -1 do
        if hist[i] and hist[i]:lower() == lower then
            tremove(hist, i)
        end
    end
    tinsert(hist, 1, text)
    local limit = EasyFind.db.uiSearchHistoryLimit or 500
    while #hist > limit do tremove(hist) end
end

-- Prompt the user for an alias text and bind it to `data`. Uses a
-- StaticPopup with a single edit box so we don't need to hand-build a
-- dialog frame. Pre-fills with the current search text so saving an
-- alias for whatever just matched is one keystroke.
StaticPopupDialogs["EASYFIND_ADD_ALIAS"] = {
    text = "Alias for %s:",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 64,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    OnShow = function(self, data)
        local eb = self.editBox or self.EditBox
        if eb then
            eb:SetText("")
            eb:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local eb = self.editBox or self.EditBox
        local txt = eb and eb:GetText() or ""
        if strtrim(txt) == "" then return end
        if ns.Aliases and ns.Aliases:Add(txt, data) then
            local searchEditBox = searchFrame and searchFrame.editBox
            local current = searchEditBox and searchEditBox:GetText() or ""
            if current ~= "" then UI:OnSearchTextChanged(current) end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        if parent.button1 then parent.button1:Click() end
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
}

function UI:PromptForAlias(data)
    if not data then return end
    local label = data.name or "this entry"
    StaticPopup_Show("EASYFIND_ADD_ALIAS", label, nil, data)
end

-- Step through search history from the editbox. Direction +1 = older,
-- -1 = newer. Returns true if the editbox was updated, false if the
-- caller should fall through to its default key behavior (e.g. DOWN
-- past the newest entry should drop into result navigation).
function UI:NavigateSearchHistory(direction)
    if not EasyFind.db then return false end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" or #hist == 0 then return false end
    local editBox = searchFrame and searchFrame.editBox
    if not editBox then return false end

    -- Capture the user's in-flight buffer the first time we step away
    -- from index 0 so DOWN-back-to-0 restores it instead of clobbering
    -- their typing.
    if historyIndex == 0 and direction > 0 then
        historyDraft = editBox:GetText() or ""
    end

    local newIndex = historyIndex + direction
    if newIndex < 0 then return false end
    if newIndex > #hist then newIndex = #hist end
    if newIndex == historyIndex then return false end

    historyIndex = newIndex
    if newIndex == 0 then
        editBox:SetText(historyDraft or "")
    else
        editBox:SetText(hist[newIndex] or "")
    end
    editBox:SetCursorPosition(#editBox:GetText())
    -- Programmatic SetText fires OnTextChanged with userInput=false, which
    -- the OnTextChanged hook now ignores (so the autocomplete suffix can't
    -- feed back into the search query). History nav still wants a fresh
    -- result render for the recalled query, so kick it manually.
    UI:OnSearchTextChanged(editBox:GetText() or "")
    return true
end

function UI:OnSearchTextChanged(text, force)
    -- Suppress re-renders while SelectResult is clearing text/focus
    if selectingResult then return end
    -- A pending OnTextChanged timer can fire after focus has shifted
    -- away from the editbox (user clicked outside, OR clicked an
    -- inline child widget like a slider that StripAutocomplete then
    -- triggers a SetText on via the focus-loss hook). Just bail —
    -- don't re-render, but also don't hide. The outside-click paths
    -- (GLOBAL_MOUSE_DOWN, OnEditFocusLost) decide whether to actually
    -- hide based on cursor position. Calling HideResults here also
    -- tore down the panel during slider drags, which is exactly what
    -- we want to avoid.
    -- `force` lets internal callers (pin/unpin from the right-click
    -- menu) re-render after the pin popup briefly stole focus.
    if not force and searchFrame and searchFrame.editBox
        and not searchFrame.editBox:HasFocus() then
        return
    end
    -- Treat whitespace-only as empty (pins show on focus, not on blank spaces)
    if text then text = strtrim(text) end
    ClearResultTooltips()
    if not text or text == "" then
        if ns.Database and ns.Database.CancelDynamicWarmup then
            ns.Database:CancelDynamicWarmup()
        end
        -- Only show pins if the editbox still has focus (avoid re-showing
        -- after SelectResult clears the text)
        if searchFrame and searchFrame.editBox and searchFrame.editBox:HasFocus() then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    wipe(collapsedNodes)
    local needsHeavy = ns.Database and ns.Database.QueryNeedsHeavySearchData
        and ns.Database:QueryNeedsHeavySearchData(text)
    if not force and not needsHeavy and ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end
    MaybeLoadHeavySearchData(text, needsHeavy)

    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Collection items (mounts/toys/pets/outfits/appearance sets) are
    -- skipped when their own filter is off OR the parent Collections
    -- toggle is off. Loot is independent.
    local filters = EasyFind.db.uiSearchFilters
    local collectionsOff = filters and filters.collections == false
    local optionsOff = filters and filters.options == false
    local skipCategories
    if filters then
        local mountsOff = collectionsOff or filters.mounts == false
        local toysOff   = collectionsOff or filters.toys == false
        local petsOff   = collectionsOff or filters.pets == false
        local outfitsOff = collectionsOff or filters.outfits == false
        local heirloomsOff = collectionsOff or filters.heirlooms == false
        local appsetsOff = collectionsOff or filters.appearanceSets == false
        local lootOff    = filters.loot == false
        local bagsOff    = filters.bags == false
        local macrosOff  = filters.macros == false
        local gameOptOff  = optionsOff or filters.gameOptions == false
        local addonOptOff = optionsOff or filters.addonOptions == false
        local abilitiesOff = filters.abilities == false
        local bossesOff = filters.bosses == false
        local titlesOff = filters.titles == false
        local gearSetsOff = filters.gearSets == false
        if mountsOff or toysOff or petsOff or outfitsOff or lootOff
           or appsetsOff or bagsOff or macrosOff or gameOptOff or addonOptOff
           or abilitiesOff or bossesOff or heirloomsOff or titlesOff or gearSetsOff then
            skipCategories = SCRATCH.skipCategories
            wipe(skipCategories)
            if mountsOff    then skipCategories["Mount"] = true end
            if toysOff      then skipCategories["Toy"] = true end
            if petsOff      then skipCategories["Pet"] = true end
            if outfitsOff   then skipCategories["Outfit"] = true end
            if heirloomsOff then skipCategories["Heirloom"] = true end
            if lootOff      then skipCategories["Loot"] = true end
            if appsetsOff   then skipCategories["Appearance Set"] = true end
            if bagsOff      then skipCategories["Bag"] = true end
            if macrosOff    then skipCategories["Macro"] = true end
            if gameOptOff   then skipCategories["Game Settings"] = true end
            if addonOptOff  then skipCategories["AddOn Settings"] = true end
            if abilitiesOff then skipCategories["Ability"] = true end
            if bossesOff    then skipCategories["Boss"] = true end
            if titlesOff    then skipCategories["Title"] = true end
            if gearSetsOff  then skipCategories["Gear Set"] = true end
        end
    end
    local _perfT0 = ns.PERF and debugprofilestop() or 0
    local results = ns.Database:SearchUI(text, skipCategories)
    local _perfTSearch = ns.PERF and debugprofilestop() or 0

    -- Inject user-defined alias hits at the front. Aliases bypass
    -- bucket filters so a saved shortcut is always reachable, even if
    -- the user has the underlying category turned off in the filter
    -- menu. Dedupe against already-present results by data identity.
    if ns.Aliases then
        local aliasMatches = ns.Aliases:GetMatches(text:lower())
        if aliasMatches then
            wipe(SCRATCH.aliasSeen)
            local seen = SCRATCH.aliasSeen
            for _, r in ipairs(results) do seen[r.data] = true end
            for i = #aliasMatches, 1, -1 do
                local hit = aliasMatches[i]
                if not seen[hit.data] then
                    tinsert(results, 1, { data = hit.data, score = math.huge, isAlias = true })
                    seen[hit.data] = true
                end
            end
            wipe(seen)
        end
    end

    -- Bucket-aware UI filter: drop UI entries whose bucket
    -- (ui / abilities / achievements / currencies / reputations / bags
    -- / options) is unchecked. Options is a parent toggle: when off,
    -- both gameOptions and addonOptions buckets are treated as off.
    -- abilityHidePassives also drops isPassive ability rows here so
    -- the filter applies regardless of which bucket is on.
    local hidePassives = EasyFind.db.abilityHidePassives
    if filters and (filters.ui == false or filters.abilities == false
                    or filters.bosses == false
                    or filters.achievements == false
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false
                    or filters.titles == false or filters.gearSets == false
                    or filters.talents == false
                    or hidePassives) then
        wipe(SCRATCH.filteredResults)
        local filtered = SCRATCH.filteredResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r.isAlias then
                fi = fi + 1
                filtered[fi] = r
            else
                local d = r.data
                local bucket = GetUIBucket(d)
                local bucketOff = bucket and filters[bucket] == false
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                local passiveOff = hidePassives and d and d.category == "Ability" and d.isPassive
                if not passiveOff and (not bucket or (not bucketOff and not parentOff)) then
                    fi = fi + 1
                    filtered[fi] = r
                end
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Currency filter mode: kept in DB so it can drive bidirectional
    -- sync with the in-game CurrencyFrame's filter dropdown later, but
    -- we deliberately don't prune our own search results here. The
    -- in-game tab shows every currency the character has discovered
    -- (zero-quantity warband-transferable ones included), and an
    -- earlier per-cache `isAccountTransferable` check was hiding some
    -- of those because the flag's truthiness varied across builds.
    -- Showing everything keeps search at least as inclusive as the
    -- in-game tab regardless of what mode is selected.

    -- Map Search: search static locations and dungeon entrances, merge into results
    local mapResults
    if filters and filters.map ~= false and ns.MapSearch and ns.MapSearch.SearchForUI then
        mapResults = ns.MapSearch:SearchForUI(text)
    end

    wipe(flatCombined)
    local combined = flatCombined
    for ri = 1, #results do combined[#combined + 1] = results[ri] end
    if mapResults then
        for ri = 1, #mapResults do combined[#combined + 1] = mapResults[ri] end
    end
    if #combined > 1 then tsort(combined, FlatNameLess) end

    -- Hard cap on visible results. The scoring step already ranks by
    -- relevance; everything past the cap is noise the user has to scroll
    -- through. Pinned items aren't in this set (they only show on empty
    -- query), so the cap is a clean top-N over the actual search match
    -- list. 15 matches the original uiMaxResults default.
    local TOP_N = 15
    if #combined > TOP_N then
        for ri = #combined, TOP_N + 1, -1 do combined[ri] = nil end
    end

    -- Inline achievement results: drive Blizzard's indexed achievement
    -- search and surface its results directly in our dropdown. First
    -- call for a given query kicks off the (already-built) index lookup
    -- and returns nothing; ACHIEVEMENT_SEARCH_UPDATED fires next frame
    -- and we re-render with the cached results. Score each one through
    -- ScoreName so they interleave naturally with mount / toy / setting
    -- hits ranked off the same query, instead of clumping at a fixed
    -- band.
    if text ~= "" and (not filters or filters.achievements ~= false) then
        local achHits = self:RequestAchievementSearch(text)
        if achHits and ns.Database and ns.Database.ScoreName then
            local lowerQ = slower(text)
            local qLen = #lowerQ
            -- Blizzard's index returns matches across name + description
            -- + criteria; we only want name matches here (the user has
            -- the UI Elements filter for navigating to achievement
            -- categories by their subtext). Drop anything ScoreName
            -- can't rank against the name itself.
            for ai = 1, #achHits do
                local entry = achHits[ai]
                local score = ns.Database:ScoreName(entry.nameLower, lowerQ, qLen)
                if score and score > 0 then
                    combined[#combined + 1] = { data = entry, score = score }
                end
            end
        end
    end

    local n = 0
    for ri = 1, #combined do
        local d = combined[ri] and combined[ri].data
        if d then
            n = n + 1
            local e = flatEntries[n]
            if not e then
                e = {}
                flatEntries[n] = e
            end
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.isPinned = IsUIItemPinned(d) and true or false
            e.data = d
        end
    end
    for i = n + 1, #flatEntries do
        flatEntries[i] = nil
    end

    local hierarchical = flatEntries
    -- Pins are quick-access entries that only show when the search bar is
    -- empty (handled by ShowPinnedItems). During an active text search we
    -- skip them so a user who pinned 6 settings doesn't see them prepended
    -- to every unrelated query like "achieve".
    wipe(pinnedSearchEntries)
    local _perfTBuild = ns.PERF and debugprofilestop() or 0
    self:ShowHierarchicalResults(hierarchical)
    if ns.PERF then
        local now = debugprofilestop()
        EasyFind:Print(string.format(
            "perf: q=%q  search=%.2fms  build=%.2fms  render=%.2fms  total=%.2fms  rows=%d",
            text or "",
            _perfTSearch - _perfT0,
            _perfTBuild  - _perfTSearch,
            now          - _perfTBuild,
            now          - _perfT0,
            #hierarchical))
    end
end

-- Helper function to get icon from a button frame
local function GetButtonIcon(frameName)
    local frame = _G[frameName]
    if not frame then return nil end

    -- For MicroButtons - use the textureName property to build atlas
    -- Atlas format: "UI-HUD-MicroMenu-<textureName>-Up"
    if frame.textureName then
        local atlas = "UI-HUD-MicroMenu-" .. frame.textureName .. "-Up"
        return atlas, true -- true means it's an atlas
    end

    -- MicroButtons without textureName (e.g. CharacterMicroButton) use a portrait
    -- render texture that produces garbage when captured. Skip region scanning for these.
    if frame.IsMicroButton or (frameName and frameName:find("MicroButton")) then
        return nil
    end

    -- Try common icon region names
    local iconRegions = {"Icon", "icon", "NormalTexture", "normalTexture"}
    for _, regionName in ipairs(iconRegions) do
        local region = frame[regionName]
        if region and region.GetTexture then
            local texture = region:GetTexture()
            if texture then
                return texture
            end
        end
    end

    -- Fallback: iterate through regions
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            if texture and type(texture) == "number" then
                return texture
            end
        end
    end

    return nil
end

function UI:ShowHierarchicalResults(hierarchical, preserveScroll)
    if not hierarchical or #hierarchical == 0 then
        self:HideResults()
        return
    end
    if not resultsFrame then return end

    -- Cache the FULL (unfiltered) list so collapse toggles can re-render
    cachedHierarchical = hierarchical

    -- Render-skip: if the input list is identical (same length, same
    -- data refs and same depth at every index) AND the relevant view
    -- state (theme, collapse state, results-above) hasn't
    -- changed since the last render, the visible output would be byte-
    -- for-byte identical. Skip the entire per-row layout pass — this is
    -- the typical case during typing once the top results stabilize.
    do
        -- collapsedNodes is wiped to a fresh empty table on every
        -- search, so identity comparison would always miss during
        -- typing. Snapshot a single key (or nil if empty) — a click on
        -- a collapse toggle adds or removes a key, which we'll see.
        local theme = EasyFind.db.resultsTheme
        local above = EasyFind.db.uiResultsAbove
        local collapsedKey = next(collapsedNodes)
        local fontScale = EasyFind.db.fontSize or 1.0
        local searchW = searchFrame and searchFrame:GetWidth() or 0
        local customResultsW = EasyFind.db.uiResultsWidth or 0
        local maxResultsH = EasyFind.db.uiResultsHeight or 280
        local n = #hierarchical
        local last = self._lastRenderSig
        local same = last and last.n == n
            and last.theme == theme
            and last.above == above
            and last.collapsedKey == collapsedKey
            and last.fontScale == fontScale
            and last.searchW == searchW
            and last.customResultsW == customResultsW
            and last.maxResultsH == maxResultsH
            and resultsFrame:IsShown()
        if same then
            for hi = 1, n do
                local e = hierarchical[hi]
                local stride = (hi - 1) * 3
                if last[stride + 1] ~= e.data
                   or last[stride + 2] ~= (e.depth or 0)
                   or last[stride + 3] ~= (e.isPinned and 1 or 0) then
                    same = false
                    break
                end
            end
        end
        if same then
            self._renderSkips = (self._renderSkips or 0) + 1
            return
        end
        self._renderRuns = (self._renderRuns or 0) + 1
        if not last then last = {}; self._lastRenderSig = last end
        last.n = n
        last.theme = theme
        last.above = above
        last.collapsedKey = collapsedKey
        last.fontScale = fontScale
        last.searchW = searchW
        last.customResultsW = customResultsW
        last.maxResultsH = maxResultsH
        for hi = 1, n do
            local e = hierarchical[hi]
            local stride = (hi - 1) * 3
            last[stride + 1] = e.data
            last[stride + 2] = e.depth or 0
            last[stride + 3] = e.isPinned and 1 or 0
        end
        for i = n * 3 + 1, #last do last[i] = nil end
    end

    ClearResultTooltips()

    local theme = GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local rowH  = mfloor(theme.rowHeight * fontScale + 0.5)
    if rowH < theme.rowHeight then rowH = theme.rowHeight end
    local flatExtraH = mfloor(16 * fontScale + 0.5)
    if flatExtraH < 16 then flatExtraH = 16 end
    local stackGap = mfloor(2 * fontScale + 0.5)
    if stackGap < 2 then stackGap = 2 end
    local stackHalfGap = stackGap * 0.5
    local indPx = theme.indentPx
    local padT  = mfloor((theme.resultsPadTop or 0) * fontScale + 0.5)
    if padT < theme.resultsPadTop then padT = theme.resultsPadTop end
    local padB = mfloor((theme.resultsPadBot or 0) * fontScale + 0.5)
    if padB < theme.resultsPadBot then padB = theme.resultsPadBot end

    -- Scale row icons to match leaf font height so icon top/bottom
    -- align with text top/bottom instead of overflowing the cap line.
    local iconScale = 1.12
    local leafFontObj = _G[theme.leafFont]
    local leafFontPx = 10
    if leafFontObj and leafFontObj.GetFont then
        local _, sz = leafFontObj:GetFont()
        if sz and sz > 0 then leafFontPx = sz end
    end
    local rowIconSize = math.floor(leafFontPx * fontScale * iconScale + 0.5)
    if rowIconSize < 12 then rowIconSize = 12 end
    local maxIconSize = math.floor((theme.iconSize or 16) * fontScale + 0.5)
    if maxIconSize < (theme.iconSize or 16) then maxIconSize = theme.iconSize or 16 end
    if rowIconSize > maxIconSize then rowIconSize = maxIconSize end

    -- Apply theme backdrop to results frame
    resultsFrame:SetBackdrop(theme.resultsBackdrop)
    if theme.resultsBackdropColor then
        resultsFrame:SetBackdropColor(unpack(theme.resultsBackdropColor))
    end
    if theme.resultsBackdropBorderColor then
        resultsFrame:SetBackdropBorderColor(unpack(theme.resultsBackdropBorderColor))
    end
    -- Width: in rounded-theme + dropdown-below mode, the dropdown
    -- silhouette merges with the bar, so it has to match the bar's
    -- exact width. Otherwise honor the user's saved customW (legacy
    -- floating-results behavior).
    local roundedDocked = theme.searchBarRounded and not EasyFind.db.uiResultsAbove
    if roundedDocked and searchFrame then
        resultsFrame:SetWidth(searchFrame:GetWidth())
    else
        local customW = EasyFind.db.uiResultsWidth
        resultsFrame:SetWidth((customW and customW > 1) and customW or theme.resultsWidth)
    end

    if theme.resultsBgAtlas then
        resultsFrame.bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
        resultsFrame.bgAtlasTex:Show()
        resultsFrame:SetClipsChildren(true)
    else
        resultsFrame.bgAtlasTex:Hide()
        resultsFrame:SetClipsChildren(false)
    end

    wipe(SCRATCH.visible)
    local visible = SCRATCH.visible
    local visibleN = 0
    local skipBelowDepth = nil
    local skipPins = false

    for hi = 1, #hierarchical do
        local entry = hierarchical[hi]
        local d = entry.depth or 0

        if skipBelowDepth then
            if d <= skipBelowDepth then
                skipBelowDepth = nil
            end
        end

        if not (skipPins and entry.isPinned) and not skipBelowDepth then
            if skipPins and not entry.isPinned then
                skipPins = false
            end
            visibleN = visibleN + 1
            visible[visibleN] = entry

            if entry.isPathNode then
                local key = entry.name .. "_" .. d
                if collapsedNodes[key] then
                    skipBelowDepth = d
                end
            end
        end
    end

    -- Count pin-related visible entries (header + pinned items)
    local pinSlots = 0
    for vi = 1, visibleN do
        local entry = visible[vi]
        if entry.isPinHeader or entry.isPinned then
            pinSlots = pinSlots + 1
        end
    end

    local count = mmin(visibleN, MAX_BUTTON_POOL)
    if pinSlots < visibleN then
        count = mmin(count, pinSlots + MAX_SEARCH_RESULT_ROWS)
    end

    local maxVisibleHeight = EasyFind.db.uiResultsHeight or 280
    local willScroll = visibleN * rowH > maxVisibleHeight
    local scrollInset = 0

    wipe(SCRATCH.isLastChild)
    local isLastChild = SCRATCH.isLastChild
    for i = 1, count do
        local d = visible[i].depth or 0
        if d > 0 then
            local foundSibling = false
            for j = i + 1, count do
                local dj = visible[j].depth or 0
                if dj < d then break end
                if dj == d then foundSibling = true; break end
            end
            isLastChild[i] = not foundSibling
        end
    end

    -- Determine pin separator placement
    local PIN_SEP_HEIGHT = 9  -- 4px gap + 1px line + 4px gap
    local lastPinIndex = 0
    local hasResultsAfterPins = false
    for i = 1, count do
        if visible[i].isPinHeader or visible[i].isPinned then
            lastPinIndex = i
        end
    end
    if lastPinIndex > 0 and lastPinIndex < count then
        hasResultsAfterPins = true
    end

    local yOffset = 0
    local pinEndYOffset = 0
    wipe(SCRATCH.catSepYPositions)
    local catSepYPositions = SCRATCH.catSepYPositions
    local hasSideBySideRepBar = false
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = i <= count and EnsureResultButton(i) or resultButtons[i]
        if resultRow and i <= count then
            local entry = visible[i]
            local data = entry.data
            local depth = entry.depth or 0

            -- Pin separator gap: add once at the transition row
            if hasResultsAfterPins and i == lastPinIndex + 1 then
                pinEndYOffset = yOffset
                yOffset = yOffset + PIN_SEP_HEIGHT
            end

            -- Small gap between pinned items (not after pin header)
            if entry.isPinned and i > 1 and visible[i - 1] and not visible[i - 1].isPinHeader then
                yOffset = yOffset + 4
            end

            -- Reposition for theme row height. Flat-list entries are taller
            -- to fit the name + path subtext stack with breathing room above
            -- the name and below the path so neither bleeds into the rep bar.
            local padL = theme.resultsPadLeft or 10
            local entryRowH = entry.isFlat and (rowH + flatExtraH) or rowH
            resultRow:SetSize(resultsFrame:GetWidth() - padL * 2 - scrollInset, entryRowH)
            resultRow:ClearAllPoints()
            resultRow:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", padL, -yOffset)

            -- Selection visual is now carried by the row's built-in
            -- HighlightTexture (atlas set in CreateResultRow), shared
            -- with mouse hover; no separate selectionHighlight texture.
            if resultRow.UnlockHighlight then resultRow:UnlockHighlight() end

            -- Always hide section-label visuals up front. The section-
            -- header branch below re-shows them when applicable; rows
            -- recycled from a previous section-header role would
            -- otherwise leak the gold rules across normal rows.
            if resultRow.sectionLabelText then
                resultRow.sectionLabelText:Hide()
                resultRow.sectionLabelLeft:Hide()
                resultRow.sectionLabelRight:Hide()
            end

            resultRow.data = data
            -- Reset every icon.* tooltip-identifier the OnEnter handler
            -- looks at. Without this, rows recycled from a previous
            -- render leak their old category's tooltip — e.g. a row
            -- that was "Felfire Hawk" (mount) becoming "Bronze Bullion"
            -- (currency) keeps icon.mountID set, so OnEnter shows the
            -- mount tooltip instead. Only the mount/toy/.../bag branch
            -- below resets these per-field; categories like currency,
            -- reputation, achievement, settings never enter that branch
            -- and used to inherit stale state.
            if resultRow.icon then
                resultRow.icon.mountID = nil
                resultRow.icon.toyItemID = nil
                resultRow.icon.petID = nil
                resultRow.icon.spellID = nil
                resultRow.icon.outfitID = nil
                resultRow.icon.heirloomItemID = nil
                resultRow.icon.bagItemID = nil
                resultRow.icon.lootItemID = nil
            end
            -- Secure action attributes. Cache the (type, value) we last
            -- applied to this row so we only re-issue SetAttribute when
            -- the row's data actually changed. SetAttribute on a secure
            -- button is the single most expensive thing we do per row,
            -- and incremental narrowing keeps the same row.data on most
            -- rows from one keystroke to the next, so most renders end
            -- up no-ops here.
            if not InCombatLockdown() then
                local newType, newKey, newVal
                if data and data.toyItemID and not data.isToyboxOnly then
                    -- Unusable toys (faction-restricted etc.) skip the
                    -- secure use type so PostClick can route them to the
                    -- ToyBox instead of silently no-op'ing on click.
                    newType, newKey, newVal = "toy", "toy", data.toyItemID
                elseif data and data.mountID then
                    newType, newKey, newVal = "macro", "macrotext", "/cancelform [form]"
                elseif data and data.outfitID then
                    newType, newKey, newVal = "action", "action", 0
                elseif data and data.spellID and data.category ~= "Talent"
                       and not IsSpellbookOnlyAbility(data) then
                    -- Talents share the spellID field but should never cast
                    -- on click -- the click navigates to the talents tree
                    -- and highlights the node. Skip the secure cast type so
                    -- only PostClick / SelectResult handle the talent path.
                    newType, newKey, newVal = "spell", "spell", data.spellName or data.spellID
                elseif data and data.itemID and data.category == "Bag" then
                    newType, newKey, newVal = "item", "item", data.name
                elseif data and data.macroIndex and data.category == "Macro"
                       and data.macroBody and data.macroBody ~= "" then
                    newType, newKey, newVal = "macro", "macrotext", data.macroBody
                elseif data and data.slashCommand then
                    newType, newKey, newVal = "macro", "macrotext", data.slashCommand
                end
                if resultRow._lastAttrType ~= newType
                   or resultRow._lastAttrKey ~= newKey
                   or resultRow._lastAttrVal ~= newVal then
                    -- Strip the previously-set value (if any) before
                    -- applying the new one so stale attributes from the
                    -- prior data don't leak through.
                    if resultRow._lastAttrKey then
                        resultRow:SetAttribute(resultRow._lastAttrKey, nil)
                    end
                    resultRow:SetAttribute("type", newType)
                    if newKey then
                        resultRow:SetAttribute(newKey, newVal)
                    end
                    resultRow._lastAttrType = newType
                    resultRow._lastAttrKey  = newKey
                    resultRow._lastAttrVal  = newVal
                end
            end
            resultRow.isPathNode = entry.isPathNode
            resultRow.isSectionHeader = entry.isSectionHeader or false
            resultRow.isPinHeader = entry.isPinHeader or false
            resultRow.isPinned = entry.isPinned or false
            resultRow.pathNodeName = entry.isPathNode and entry.name or nil
            resultRow.pathNodeDepth = entry.isPathNode and depth or nil
            if resultRow.pinIcon then resultRow.pinIcon:Hide() end
            if resultRow.pinToggle then resultRow.pinToggle:Hide() end
            if resultRow.pinHeaderLine then resultRow.pinHeaderLine:Hide() end

            -- Tree connector drawing
            for d = 1, MAX_DEPTH do
                resultRow.treeVert[d]:Hide()
                resultRow.treeElbow[d]:Hide()
                resultRow.treeBranch[d]:Hide()
            end

            if theme.showTreeLines and depth > 0 then
                local halfRow = rowH * 0.5
                local lineColor = theme.indentColors[depth] or theme.indentColors[1] or INDENT_COLORS[depth]
                local xCenter = (depth - 1) * INDENT_PX + LINE_X_OFF

                resultRow.treeElbow[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                resultRow.treeElbow[depth]:ClearAllPoints()
                resultRow.treeElbow[depth]:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
                resultRow.treeElbow[depth]:SetHeight(halfRow + 2)
                resultRow.treeElbow[depth]:Show()

                resultRow.treeBranch[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                resultRow.treeBranch[depth]:ClearAllPoints()
                resultRow.treeBranch[depth]:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -halfRow)
                resultRow.treeBranch[depth]:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -halfRow)
                resultRow.treeBranch[depth]:Show()

                if not isLastChild[i] then
                    resultRow.treeVert[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                    resultRow.treeVert[depth]:ClearAllPoints()
                    resultRow.treeVert[depth]:SetPoint("TOP",    resultRow, "TOPLEFT",    xCenter, 3)
                    resultRow.treeVert[depth]:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", xCenter, -1)
                    resultRow.treeVert[depth]:Show()
                end

                for d = 1, depth - 1 do
                    local stillActive = false
                    for j = i + 1, count do
                        local siblingDepth = visible[j].depth or 0
                        if siblingDepth < d then break end
                        if siblingDepth == d then stillActive = true; break end
                    end
                    if stillActive then
                        local ancestorColor = theme.indentColors[d] or theme.indentColors[1] or INDENT_COLORS[d]
                        local ancestorX = (d - 1) * INDENT_PX + LINE_X_OFF
                        resultRow.treeVert[d]:SetColorTexture(ancestorColor[1], ancestorColor[2], ancestorColor[3], 1)
                        resultRow.treeVert[d]:ClearAllPoints()
                        resultRow.treeVert[d]:SetPoint("TOP",    resultRow, "TOPLEFT",    ancestorX, 3)
                        resultRow.treeVert[d]:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", ancestorX, -1)
                        resultRow.treeVert[d]:Show()
                    end
                end
            end

            -- Header styling
            resultRow._isMatch = entry.isMatch and entry.isPathNode
            if entry.isPinHeader then
                -- Pin header: plain text + toggle icon + underline (no tab/gradient)
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                resultRow.pinToggle:SetAtlas(collapseAtlas)
                resultRow.pinToggle:Show()
                resultRow.pinHeaderLine:Show()
                -- Position text: left-aligned, right-bounded by toggle
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", 2, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.pinToggle, "LEFT", -4, 0)
                SetScaledFont(resultRow.text, theme.pathFont)
                resultRow.text:SetTextColor(0.7, 0.7, 0.7, 1.0)
                SetClippedText(resultRow.text, entry.name)
            elseif entry.isSectionHeader then
                -- Lightweight inline section label: centered text
                -- between two faint horizontal rules. Used for
                -- category dividers (UI / Mounts / Toys / Map / ...)
                -- so they cost less vertical space than a full
                -- parent-tab header and don't waste a parent indent.
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
                resultRow.text:SetText("")
                resultRow.sectionLabelText:SetText(entry.name)
                resultRow.sectionLabelText:Show()
                resultRow.sectionLabelLeft:ClearAllPoints()
                resultRow.sectionLabelLeft:SetPoint("LEFT", resultRow, "LEFT", 6, 0)
                resultRow.sectionLabelLeft:SetPoint("RIGHT", resultRow.sectionLabelText, "LEFT", -6, 0)
                resultRow.sectionLabelLeft:Show()
                resultRow.sectionLabelRight:ClearAllPoints()
                resultRow.sectionLabelRight:SetPoint("LEFT", resultRow.sectionLabelText, "RIGHT", 6, 0)
                resultRow.sectionLabelRight:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                resultRow.sectionLabelRight:Show()
            elseif theme.showHeaderTab and entry.isPathNode and resultRow.headerTab then
                -- Quest-log raised tab header
                local tabInset = depth * indPx
                resultRow.headerTab:ClearAllPoints()
                resultRow.headerTab:SetPoint("TOPLEFT", resultRow, "TOPLEFT", tabInset, 0)
                resultRow.headerTab:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", 0, 0)
                resultRow.headerTab:Show()
                -- Set +/- atlas and header name on the tab
                local key = entry.name .. "_" .. depth
                local isCollapsed = collapsedNodes[key]
                local expandAtlas = theme.expandAtlas or "QuestLog-icon-expand"
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                local toggleAtlas = isCollapsed and expandAtlas or collapseAtlas
                resultRow.toggleIcon:SetAtlas(toggleAtlas)
                -- Reset tabText anchors (may have been re-anchored to repBar)
                resultRow.tabText:ClearAllPoints()
                resultRow.tabText:SetPoint("LEFT", resultRow.headerTab, "LEFT", 10, 0)
                resultRow.tabText:SetPoint("RIGHT", resultRow.toggleBtn, "LEFT", -4, 0)
                resultRow.tabText:SetText(entry.name)
                -- Matched path nodes get gold text; non-matches stay muted gray
                if resultRow._isMatch then
                    resultRow.tabText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)   -- gold
                else
                    resultRow.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0) -- muted gray
                end
                -- Normal icon/text hidden - SetRowIcon("hidden") handles icon below
                resultRow.text:SetText("")
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
            else
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                -- Gradient header (Classic fallback)
                local showGrad = theme.showHeaderBar and entry.isPathNode
                if showGrad and resultRow.headerGrad then
                    resultRow.headerGrad:SetAllPoints()
                    local gradAlpha = mmax(0.25, 0.6 - depth * 0.1)
                    resultRow.headerGrad:SetVertexColor(0.35, 0.27, 0.08, gradAlpha)
                end
                if resultRow.headerGrad then resultRow.headerGrad:SetShown(showGrad) end
            end

            -- Separator line between rows (skip for pin header which has its own underline)
            -- Separator is anchored at BOTTOM of the row (line below this row).
            if not entry.isPinHeader and theme.showSeparators then
                local sc = theme.separatorColor
                resultRow.separator:SetColorTexture(sc[1], sc[2], sc[3], sc[4])
                resultRow.separator:Show()
            elseif entry.isPinned and not entry.isPinHeader then
                local nextEntry = visible[i + 1]
                if nextEntry and nextEntry.isPinned and not nextEntry.isPinHeader then
                    resultRow.separator:SetColorTexture(0.4, 0.4, 0.4, 0.4)
                    resultRow.separator:Show()
                else
                    resultRow.separator:Hide()
                end
            else
                resultRow.separator:Hide()
            end

            -- Check if this is a currency that hasn't been discovered yet
            -- (not just quantity == 0, but truly never earned/discovered)
            -- Runs for ALL currency nodes regardless of theme
            local isUnearnedCurrency = false
            if data and data.category == "Currency" then
                if entry.isPathNode then
                    -- For parent currency nodes, check if ALL children are unearned
                    -- Look ahead in the visible list to find children
                    local hasAnyEarnedChild = false
                    local hasAnyChild = false
                    for j = i + 1, count do
                        local childEntry = visible[j]
                        local childDepth = childEntry.depth or 0
                        -- Stop when we leave this parent's subtree
                        if childDepth <= depth then
                            break
                        end
                        -- Only check immediate children at depth + 1
                        if childDepth == depth + 1 and childEntry.data and childEntry.data.steps then
                            hasAnyChild = true
                            for _, step in ipairs(childEntry.data.steps) do
                                if step.currencyID then
                                    local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(step.currencyID)
                                    if currencyInfo and (currencyInfo.quantity > 0 or
                                        (currencyInfo.totalEarned and currencyInfo.totalEarned > 0) or
                                        currencyInfo.useTotalEarnedForMaxQty or
                                        currencyInfo.discovered == true) then
                                        hasAnyEarnedChild = true
                                        break
                                    end
                                end
                            end
                            if hasAnyEarnedChild then break end
                        end
                    end
                    -- If we found children but NONE are earned, mark parent as unearned
                    if hasAnyChild and not hasAnyEarnedChild then
                        isUnearnedCurrency = true
                    end
                elseif data.steps then
                    -- For leaf currency nodes, check the currency itself
                    for _, step in ipairs(data.steps) do
                        if step.currencyID then
                            local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(step.currencyID)
                            if currencyInfo and currencyInfo.quantity == 0 then
                                -- Only mark as unearned if it's never been discovered
                                local isDiscovered = (currencyInfo.totalEarned and currencyInfo.totalEarned > 0) or
                                                     (currencyInfo.useTotalEarnedForMaxQty) or
                                                     (currencyInfo.discovered == true)
                                if not isDiscovered then
                                    isUnearnedCurrency = true
                                end
                            end
                            break
                        end
                    end
                end
            end
            resultRow.isUnearnedCurrency = isUnearnedCurrency
            resultRow.isPathNode = entry.isPathNode  -- Store for tooltip text

            -- Position icon & text (non-tab, non-pin-header rows)
            if not entry.isPinHeader and not entry.isSectionHeader and not (theme.showHeaderTab and entry.isPathNode) then
                local indentPixels = depth * indPx
                resultRow.icon:ClearAllPoints()

                if entry.isFlat then
                    -- Flat-list layout (Alfred-style):
                    --   icon left (vertically centered), name + path stack to its right.
                    -- pathSubtext has SetWordWrap(false) so long paths truncate
                    -- horizontally rather than wrapping into the next row.
                    -- For collection rows (mounts/toys/etc.) the main icon is
                    -- pushed to the RIGHT later in the loop to display the
                    -- mount/toy/pet/etc. portrait. We show flatCatIcon (the
                    -- filter-menu category icon) on the LEFT so the row still
                    -- has a visual anchor next to the name+path stack.
                    local catIconDef = GetFlatCategoryIcon(data)
                    local leftAnchor
                    if catIconDef then
                        local sz = entryRowH - 16
                        if catIconDef.atlas then
                            resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
                            resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                        else
                            resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                            if catIconDef.coords then
                                resultRow.flatCatIcon:SetTexCoord(unpack(catIconDef.coords))
                            else
                                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                            end
                        end
                        if catIconDef.color then
                            resultRow.flatCatIcon:SetVertexColor(unpack(catIconDef.color))
                        else
                            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
                        end
                        resultRow.flatCatIcon:SetSize(sz, sz)
                        resultRow.flatCatIcon:ClearAllPoints()
                        resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels + 2, 0)
                        resultRow.flatCatIcon:Show()
                        leftAnchor = resultRow.flatCatIcon
                    else
                        resultRow.flatCatIcon:Hide()
                        resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels + 2, 0)
                        leftAnchor = resultRow.icon
                    end

                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("BOTTOMLEFT", leftAnchor, "RIGHT", 6, stackHalfGap)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    SetScaledFont(resultRow.text, theme.pathFont)
                    if isUnearnedCurrency then
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        resultRow.text:SetTextColor(1.0, 1.0, 1.0, 1.0)
                    end
                    SetClippedText(resultRow.text, entry.name)

                    resultRow.pathSubtext:ClearAllPoints()
                    resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -stackGap)
                    resultRow.pathSubtext:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    resultRow.pathSubtext:SetText(GetFlatSubtext(data))
                    SetScaledFont(resultRow.pathSubtext, theme.leafFont)
                    resultRow.pathSubtext:SetTextColor(0.55, 0.55, 0.55, 1.0)
                    resultRow.pathSubtext:Show()
                else
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end

                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)

                    if resultRow.pathSubtext then
                        resultRow.pathSubtext:Hide()
                    end

                    -- Style: path nodes vs leaf results, themed
                    if entry.isPathNode then
                        SetScaledFont(resultRow.text, theme.pathFont)
                        if entry.isMatch then
                            resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                        else
                            resultRow.text:SetTextColor(unpack(theme.pathColor))
                        end
                    elseif isUnearnedCurrency then
                        -- Gray out unearned currencies
                        SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    elseif entry.isMatch then
                        SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                    else
                        SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(unpack(theme.leafColor))
                    end
                    SetClippedText(resultRow.text, entry.name)
                end
            else
                if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
                if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
            end

            -- Set icon
            local iconSet = false
            -- Clear leftover cooldown sweep from prior render. Only the
            -- toy/ability/outfit branch re-enables it; every other branch
            -- (map results, currencies, settings, etc.) leaves it alone, so
            -- without this clear a recycled row keeps the previous sweep.
            if resultRow.iconCooldown then resultRow.iconCooldown:Hide() end
            local isCurrencyItem = data and data.category == "Currency"
            local isCurrencyLeaf = isCurrencyItem and not entry.isPathNode
            local isReputationLeaf = data and data.category == "Reputation" and not entry.isPathNode

            if entry.isSectionHeader then
                -- Section dividers: no icon, no main text. The
                -- centered sectionLabelText handles the visual.
                SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                resultRow.amountText:Hide()
                if resultRow.repBar then resultRow.repBar:Hide() end
                iconSet = true

            elseif entry.isPinHeader then
                -- Pin header: no row icon (toggle is handled by pinToggle)
                SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                iconSet = true

            elseif theme.showHeaderTab and entry.isPathNode then
                SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                iconSet = true

            elseif entry.isPathNode then
                local key = entry.name .. "_" .. depth
                local nodeCollapsed = collapsedNodes[key]
                local iconPath = nodeCollapsed and theme.expandIcon or theme.collapseIcon
                SetRowIcon(resultRow, "path", iconPath, theme.pathIconSize)
                iconSet = true
            end

            -- Resolve currency icon on the fly if not cached
            if not iconSet and isCurrencyItem and data and not data.icon and data.steps then
                for si = #data.steps, 1, -1 do
                    local cid = data.steps[si].currencyID
                    if cid then
                        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                            local ok, ci = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
                            if ok and ci and ci.iconFileID and ci.iconFileID ~= 0 then
                                data.icon = ci.iconFileID
                            end
                        end
                        break
                    end
                end
            end

            -- Currency leaves: icon goes right of amount, not left of name
            if isCurrencyLeaf and data and data.steps then
                local quantity, iconFileID
                for si = #data.steps, 1, -1 do
                    local cid = data.steps[si].currencyID
                    if cid and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                        local ok, ci = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
                        if ok and ci then
                            quantity = ci.quantity
                            iconFileID = data.icon or (ci.iconFileID ~= 0 and ci.iconFileID) or nil
                        end
                        break
                    end
                end

                -- Amount text
                if quantity then
                    resultRow.amountText:SetText(tostring(quantity))
                    if isUnearnedCurrency then
                        resultRow.amountText:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        resultRow.amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
                    end
                    resultRow.amountText:Show()
                else
                    resultRow.amountText:Hide()
                end

                -- Move icon to right side (right of amount text)
                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    -- Anchor amount text to left of icon
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
                else
                    SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end

                -- Show unified currency category icon on the LEFT (matches map AH glyph).
                -- indentPixels matches the non-currency leaf calculation so the
                -- currency icon lines up horizontally with normal row icons.
                local indentPixels = depth * indPx
                local leftAnchor
                local catIconDef = FLAT_CATEGORY_ICONS.currency
                if catIconDef and resultRow.flatCatIcon then
                    local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
                    if catIconDef.atlas then
                        resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
                    else
                        resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                    end
                    resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
                    resultRow.flatCatIcon:SetSize(sz, sz)
                    resultRow.flatCatIcon:ClearAllPoints()
                    resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.flatCatIcon:Show()
                    leftAnchor = resultRow.flatCatIcon
                end

                resultRow.text:ClearAllPoints()
                if leftAnchor then
                    resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
                else
                    resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                end
                resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                iconSet = true

            -- Mount/Toy/Pet leaves: icon goes to right side (same layout as currency icons)
            elseif not iconSet and data and (data.mountID or data.toyItemID or data.petID or data.outfitID or data.heirloomItemID or data.transmogSetID or (data.spellID and data.category == "Ability") or (data.spellID and data.category == "Talent") or (data.encounterID and data.category == "Boss") or (data.macroIndex and data.category == "Macro") or (data.bagID and data.category == "Bag")) then
                local iconFileID = data.icon
                local rightOffset = -5

                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                    resultRow.icon:Show()
                    resultRow.icon.mountID = data.mountID
                    resultRow.icon.toyItemID = data.toyItemID
                    resultRow.icon.petID = data.petID
                    resultRow.icon.spellID = data.spellID
                    resultRow.icon.outfitID = data.outfitID
                    resultRow.icon.heirloomItemID = data.heirloomItemID
                    resultRow.icon.bagItemID = (data.category == "Bag") and data.itemID or nil
                    resultRow.icon.lootItemID = nil
                    -- Red tint on mount icons when in combat (can't mount)
                    if data.mountID and InCombatLockdown() then
                        resultRow.icon:SetVertexColor(1, 0.3, 0.3, 1)
                    -- Green tint on currently equipped outfit
                    elseif data.outfitID then
                        local activeID = lastEquippedOutfitID
                            or (C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                                and C_TransmogOutfitInfo.GetActiveOutfitID())
                        if activeID and activeID == data.outfitID then
                            resultRow.icon:SetVertexColor(0.3, 1, 0.3, 1)
                        else
                            resultRow.icon:SetVertexColor(1, 1, 1, 1)
                        end
                    -- Talents: desaturate the per-talent icon if not in
                    -- the player's current allocation. Allocated talents
                    -- (chosen choice option, or non-zero rank on regular
                    -- nodes) render full color.
                    elseif data.category == "Talent" then
                        if data.talentIsAllocated then
                            resultRow.icon:SetVertexColor(1, 1, 1, 1)
                        else
                            resultRow.icon:SetVertexColor(0.4, 0.4, 0.4, 1)
                        end
                    else
                        resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    end
                else
                    SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end

                -- Outfit lock overlay (dashed border when locked)
                if data.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
                    UI:UpdateOutfitLockOverlay(resultRow, C_TransmogOutfitInfo.IsLockedOutfit(data.outfitID))
                elseif resultRow._lockOverlay then
                    resultRow._lockOverlay:Hide()
                end

                -- Cooldown sweep overlay (toys, abilities, outfits)
                resultRow.amountText:Hide()
                if data.toyItemID and iconFileID and GetItemCooldown then
                    local startTime, duration = GetItemCooldown(data.toyItemID)
                    if startTime and duration and duration > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(startTime, duration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                elseif data.spellID and data.category == "Ability" and iconFileID and C_Spell and C_Spell.GetSpellCooldown then
                    local cd = C_Spell.GetSpellCooldown(data.spellID)
                    if cd and cd.startTime and cd.duration and cd.duration > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(cd.startTime, cd.duration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                elseif data.outfitID and outfitCdStart > 0 then
                    local remaining = outfitCdDuration - (GetTime() - outfitCdStart)
                    if remaining > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(outfitCdStart, outfitCdDuration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                else
                    resultRow.iconCooldown:Hide()
                end

                local indentPixels = depth * indPx + 4
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                iconSet = true

            -- Loot items: icon on right with source name inline
            elseif not iconSet and data and data.itemID and data.category == "Loot" then
                local iconFileID = data.icon
                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    resultRow.icon.lootItemID = data.itemID
                    resultRow.icon.mountID = nil
                    resultRow.icon.toyItemID = nil
                    resultRow.icon.petID = nil
                    resultRow.icon.spellID = nil
                    resultRow.icon.outfitID = nil
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.amountText:Hide()
                resultRow.iconCooldown:Hide()
                -- Show source info after item name
                if data.lootSourceName then
                    resultRow.text:SetText(data.name .. "  |cff888888" .. data.lootSourceName .. "|r")
                end
                local indentPixels = depth * indPx + 4
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                iconSet = true

            -- Map search results: per-POI icon (flightmaster, bank, dungeon
            -- entrance, etc.) on the RIGHT. The LEFT generic-map glyph is
            -- already handled by the flat-mode block above via GetFlatCategoryIcon
            -- (which returns FLAT_CATEGORY_ICONS.map for mapSearchResult rows).
            elseif not iconSet and data and data.mapSearchResult then
                resultRow.amountText:Hide()
                local mapIcon = data.icon
                if mapIcon then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    if type(mapIcon) == "table" then
                        resultRow.icon:SetTexture(mapIcon.file)
                        local c = mapIcon.coords
                        resultRow.icon:SetTexCoord(c[1], c[2], c[3], c[4])
                    elseif type(mapIcon) == "string" and sfind(mapIcon, "^atlas:") then
                        resultRow.icon:SetAtlas(mapIcon:sub(7))
                    else
                        resultRow.icon:SetTexture(mapIcon)
                    end
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                else
                    SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
                if mapIcon then
                    resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                else
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end
                iconSet = true

            -- Reputation leaves: faction-side crest on the LEFT, rep bar on
            -- the right (rendered later in the showRepBar block).
            elseif not iconSet and isReputationLeaf and data and data.factionID then
                local repIcon = REP_FACTION_ICONS[data.factionSide or "either"]
                if repIcon then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexture(repIcon.tex)
                    if repIcon.coords then
                        local c = repIcon.coords
                        resultRow.icon:SetTexCoord(c[1], c[2], c[3], c[4])
                    else
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    end
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    local indentPixels = depth * indPx + 4
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.icon:Show()
                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                end
                resultRow.amountText:Hide()
                resultRow.amountText:ClearAllPoints()
                resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                iconSet = true

            else
                resultRow.amountText:Hide()
                -- Reset amount text anchor for non-currency rows
                resultRow.amountText:ClearAllPoints()
                resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
            end

            -- Reputation bar: show on leaves and on path nodes with actual rep bars
            -- (hasRepBar is false for pure grouping headers like Horde, Alliance)
            local showRepBar = data and data.factionID and
                (isReputationLeaf or (entry.isPathNode and data.category == "Reputation" and data.hasRepBar ~= false))
            if showRepBar then
                local fill, standingText, barR, barG, barB
                local fid = data.factionID

                -- Priority 1: Renown factions (TWW, Dragonflight, Shadowlands)
                if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                    local ok, md = pcall(C_MajorFactions.GetMajorFactionData, fid)
                    if ok and md and md.renownLevel then
                        local level = md.renownLevel or 0
                        standingText = "Renown " .. level
                        local atMax = C_MajorFactions.HasMaximumRenown
                            and C_MajorFactions.HasMaximumRenown(fid)
                        if atMax then
                            fill = 1.0
                        else
                            local earned = md.renownReputationEarned or 0
                            local threshold = md.renownLevelThreshold or 1
                            fill = (threshold > 0) and (earned / threshold) or 1.0
                        end
                        barR, barG, barB = 0.0, 0.55, 0.78
                    end
                end

                -- Priority 2: Friendship factions (Sabellian, Wrathion, etc.)
                if not standingText and C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
                    local ok, fd = pcall(C_GossipInfo.GetFriendshipReputation, fid)
                    if ok and fd and fd.friendshipFactionID and fd.friendshipFactionID > 0 then
                        standingText = fd.reaction or ""
                        local cur = fd.standing or 0
                        local minR = fd.reactionThreshold or 0
                        local maxR = fd.nextThreshold or 0
                        if maxR > minR then
                            fill = (cur - minR) / (maxR - minR)
                        elseif cur > 0 then
                            fill = 1.0
                        else
                            fill = 0.0
                        end
                        barR, barG, barB = 0.0, 0.60, 0.0
                    end
                end

                -- Priority 3: Traditional factions (Friendly, Honored, etc.)
                if not standingText and C_Reputation and C_Reputation.GetFactionDataByID then
                    local ok, rd = pcall(C_Reputation.GetFactionDataByID, fid)
                    if ok and rd and rd.reaction then
                        local standing = rd.reaction
                        standingText = _G["FACTION_STANDING_LABEL" .. standing] or ""
                        local cur  = rd.currentStanding or 0
                        local minR = rd.currentReactionThreshold or 0
                        local maxR = rd.nextReactionThreshold or 0
                        if maxR > minR then
                            fill = (cur - minR) / (maxR - minR)
                        else
                            fill = 1.0
                        end
                        local barColor = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing]
                        if barColor then
                            barR, barG, barB = barColor.r, barColor.g, barColor.b
                        else
                            barR, barG, barB = 0.5, 0.5, 0.5
                        end
                    end
                end

                if standingText then
                    if fill < 0 then fill = 0 end
                    if fill > 1 then fill = 1 end
                    resultRow.repBarTex:SetVertexColor(barR, barG, barB, 1.0)
                    if resultRow.repFill.SetBackdropColor then
                        resultRow.repFill:SetBackdropColor(barR, barG, barB, 1.0)
                    end
                    resultRow.repClip:SetWidth(mmax(fill * REP_BAR_WIDTH, 0.1))
                    resultRow.repBarText:SetText(standingText)

                    if entry.isPathNode and theme.showHeaderTab then
                        -- Tab theme: place rep bar left of the toggle icon
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow.toggleBtn, "LEFT", -4, 0)
                        resultRow.tabText:ClearAllPoints()
                        resultRow.tabText:SetPoint("LEFT", resultRow.headerTab, "LEFT", 10, 0)
                        resultRow.tabText:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                    elseif entry.isPathNode then
                        -- Side-by-side by default; IsTruncated() reflects the previous frame's
                        -- layout, which is accurate for stable results. A deferred re-render
                        -- corrects it after first render or scale/width changes.
                        local indentPixels = depth * indPx + 4
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                        resultRow.text:ClearAllPoints()
                        resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                        resultRow.text:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                        if resultRow.text:IsTruncated() then
                            resultRow.text:ClearAllPoints()
                            resultRow.text:SetPoint("TOPLEFT", resultRow, "TOPLEFT", indentPixels, -3)
                            resultRow.text:SetPoint("TOPRIGHT", resultRow, "TOPRIGHT", -6, -3)
                            resultRow.repBar:ClearAllPoints()
                            resultRow.repBar:SetPoint("BOTTOM", resultRow, "BOTTOM", 0, 5)
                            resultRow:SetHeight(rowH + 25)
                        else
                            hasSideBySideRepBar = true
                        end
                    else
                        -- Leaf: side-by-side by default, stack only if text truncates
                        SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                        local indentPixels = depth * indPx + 4
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                        resultRow.text:ClearAllPoints()
                        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                        resultRow.text:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                        if resultRow.text:IsTruncated() then
                            resultRow.text:ClearAllPoints()
                            resultRow.text:SetPoint("TOPLEFT", resultRow, "TOPLEFT", indentPixels, -3)
                            resultRow.text:SetPoint("TOPRIGHT", resultRow, "TOPRIGHT", -6, -3)
                            resultRow.repBar:ClearAllPoints()
                            resultRow.repBar:SetPoint("BOTTOM", resultRow, "BOTTOM", 0, 5)
                            resultRow:SetHeight(rowH + 25)
                        else
                            hasSideBySideRepBar = true
                        end
                        iconSet = true
                    end
                    resultRow.repBar:Show()
                else
                    resultRow.repBar:Hide()
                end

                if not entry.isPathNode then iconSet = true end
            else
                resultRow.repBar:Hide()
            end

            -- Game Settings: cogwheel atlas in non-flat mode (flat mode
            -- uses flatCatIcon via GetFlatCategoryIcon).
            if not iconSet and data and data.category == "Game Settings" then
                SetRowIcon(resultRow, "atlas", "QuestLog-icon-setting", rowIconSize)
                iconSet = true
            end

            if not iconSet and data and data.iconAtlas then
                SetRowIcon(resultRow, "atlas", data.iconAtlas, rowIconSize)
                iconSet = true
            end

            if not iconSet and data and data.icon then
                SetRowIcon(resultRow, "file", data.icon, rowIconSize)
                iconSet = true
            end

            -- Portrait menu items: use the player portrait as the icon
            if not iconSet and data and data.steps then
                for _, step in ipairs(data.steps) do
                    if step.portraitMenu or step.portraitMenuOption then
                        SetPortraitTexture(resultRow.icon, "player")
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                        resultRow.icon:SetSize(rowIconSize, rowIconSize)
                        resultRow.icon:Show()
                        iconSet = true
                        break
                    end
                end
            end

            -- Resolve sidebar tab icons at runtime (e.g. Equipment Manager, Titles)
            -- The tab textures are sprite sheets - copy the ARTWORK-layer texture
            -- along with its tex coords so only the icon portion is shown.
            if not iconSet and data and data.steps then
                for _, step in ipairs(data.steps) do
                    if step.sidebarIndex then
                        local tab = _G["PaperDollSidebarTab" .. step.sidebarIndex]
                        if tab then
                            -- Find the ARTWORK-layer texture (the actual icon region)
                            for ri = 1, select("#", tab:GetRegions()) do
                                local region = select(ri, tab:GetRegions())
                                if region and region:GetObjectType() == "Texture"
                                   and region:GetDrawLayer() == "ARTWORK" then
                                    local tex = region:GetTexture()
                                    -- Skip render targets (e.g. RTPortrait1 for the player model)
                                    if tex and type(tex) == "string" and tex:find("^RT") then
                                        break
                                    end
                                    if tex then
                                        local ulX, ulY, llX, llY, urX, urY, lrX, lrY = region:GetTexCoord()
                                        resultRow.icon:SetTexture(tex)
                                        resultRow.icon:SetTexCoord(ulX, ulY, llX, llY, urX, urY, lrX, lrY)
                                        resultRow.icon:SetSize(rowIconSize, rowIconSize)
                                        resultRow.icon:Show()
                                        iconSet = true
                                    end
                                    break
                                end
                            end
                            -- Fallback for render target tabs: use player portrait
                            if not iconSet then
                                SetPortraitTexture(resultRow.icon, "player")
                                resultRow.icon:SetTexCoord(0, 1, 0, 1)
                                resultRow.icon:SetSize(rowIconSize, rowIconSize)
                                resultRow.icon:Show()
                                iconSet = true
                            end
                        end
                        break
                    end
                end
            end

            -- Skip buttonFrame fallback for currency items - their inherited
            -- "CharacterMicroButton" produces a wrong MicroMenu atlas icon.
            if not iconSet and not isCurrencyItem and data and data.buttonFrame then
                local texture, isAtlas = GetButtonIcon(data.buttonFrame)
                if texture then
                    local kind = isAtlas and "atlas" or "file"
                    SetRowIcon(resultRow, kind, texture, rowIconSize)
                    iconSet = true
                end
            end

            if not iconSet then
                SetRowIcon(resultRow, "file", 134400, rowIconSize)
            end

            -- Setting state visualization. Checkbox: check/uncheck atlas
            -- (toggle inline via PostClick). Slider: actual draggable
            -- slider widget with value label. Dropdown/other: current
            -- value as muted text (click opens panel to edit).
            local isKeybindEntry = data and data.settingType == "keybind" and data.bindingAction
            if isKeybindEntry and not entry.isPathNode then
                -- Keybinding row: two inline buttons showing current
                -- primary/alternate keys. Refresh function lets the
                -- buttons re-read GetBindingKey after a capture/clear.
                local action = data.bindingAction
                local kb1 = resultRow.settingKeybind1
                local kb2 = resultRow.settingKeybind2
                local function refresh()
                    local k1, k2 = GetBindingKey(action)
                    kb1:SetText(AbbrevBinding(k1))
                    kb2:SetText(AbbrevBinding(k2))
                end
                kb1._bindingAction = action
                kb1._refresh = refresh
                kb2._bindingAction = action
                kb2._refresh = refresh
                refresh()
                resultRow.settingKeybindGroup:Show()
                if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                resultRow.settingState:Hide()
                resultRow.settingCheck:Hide()
                resultRow.amountText:Hide()
                resultRow.text:SetPoint("RIGHT", resultRow.settingKeybindGroup, "LEFT", -4, 0)
            elseif data and data.settingVariable and not entry.isPathNode then
                if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
                local settingType = data.settingType
                if settingType == "checkbox" then
                    local isOn = false
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, v = pcall(settObj.GetValue, settObj)
                            if vok then
                                isOn = (v == true or v == "1" or v == 1)
                            end
                        end
                    end
                    if not isOn and GetCVar then
                        local val = GetCVar(data.settingVariable)
                        isOn = (val == "1")
                    end
                    resultRow.settingState:Show()
                    resultRow.settingCheck:SetShown(isOn)
                    resultRow.amountText:Hide()
                    if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                    if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    -- Re-anchor text RIGHT to settingState so the row name
                    -- truncates at the checkbox instead of overlapping it.
                    resultRow.text:SetPoint("RIGHT", resultRow.settingState, "LEFT", -4, 0)
                elseif settingType == "slider" and data.settingMin and data.settingMax then
                    -- Read current value
                    local rawVal
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, v = pcall(settObj.GetValue, settObj)
                            if vok then rawVal = v end
                        end
                    end
                    if rawVal == nil and GetCVar then
                        rawVal = GetCVar(data.settingVariable)
                    end
                    local numVal = tonumber(rawVal) or data.settingMin

                    local sMin, sMax = data.settingMin, data.settingMax
                    local stepVal = data.settingStep or 1
                    if sMax <= sMin then sMax = sMin + 1 end
                    local slider = resultRow.settingSlider
                    slider._settingVar = data.settingVariable
                    slider._settingFormatter = data.settingFormatter
                    slider._updating = true
                    slider:SetMinMaxValues(sMin, sMax)
                    slider:SetValueStep(stepVal)
                    slider:SetValue(numVal)
                    slider._updating = false
                    resultRow.settingSliderGroup:Show()

                    -- Curated SETTINGS_DATA rows don't ship with a
                    -- formatter; pull from the live registry on demand
                    -- so the inline value matches Blizzard's panel
                    -- (Mouse Look Speed raw 180 -> displayed "5.5").
                    if not data.settingFormatter
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                        local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(data.settingVariable)
                        if fmt then data.settingFormatter = fmt end
                    end
                    local displayVal
                    if data.settingFormatter then
                        local fok, formatted = pcall(data.settingFormatter, numVal)
                        if fok and formatted ~= nil then
                            local ft = type(formatted)
                            if ft == "string" and formatted ~= "" then
                                displayVal = formatted
                            elseif ft == "number" then
                                displayVal = (formatted == mfloor(formatted))
                                    and tostring(mfloor(formatted))
                                    or sformat("%.2f", formatted)
                            end
                        end
                    end
                    if not displayVal then
                        if numVal == mfloor(numVal) then
                            displayVal = tostring(mfloor(numVal))
                        else
                            displayVal = sformat("%.2f", numVal)
                        end
                    end
                    resultRow.settingSliderValue:SetText(displayVal)

                    resultRow.settingState:Hide()
                    resultRow.settingCheck:Hide()
                    resultRow.amountText:Hide()
                    if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
                else
                    -- Dropdown / other: show current value as text
                    local val, rawVal
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, raw = pcall(settObj.GetValue, settObj)
                            if vok and raw ~= nil then
                                rawVal = raw
                                val = tostring(raw)
                            end
                        end
                    end
                    if (not val or val == "") and GetCVar then
                        rawVal = GetCVar(data.settingVariable)
                        val = rawVal
                    end
                    -- Lazily cache the option list so subsequent renders
                    -- can translate raw values (often opaque ints) into
                    -- the localized label the dropdown actually shows.
                    if data.settingType == "dropdown" and not data.settingOptions
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                        local opts = ns.BlizzOptionsSearch.GetOptionsForVariable(data.settingVariable)
                        if opts then data.settingOptions = opts end
                    end
                    local optList = (data.settingType == "dropdown" and type(data.settingOptions) == "table")
                        and data.settingOptions or nil
                    if optList and rawVal ~= nil then
                        for oi = 1, #optList do
                            local o = optList[oi]
                            if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                                val = o.label or val
                                break
                            end
                        end
                    end
                    if optList and #optList > 0 then
                        -- Inline dropdown widget: paddle arrows + center
                        -- button styled like the in-game Settings dropdown.
                        if resultRow.SetSettingDropdownText then
                            resultRow:SetSettingDropdownText(val or "")
                        else
                            resultRow.settingDropdownLabel:SetText(val or "")
                        end
                        resultRow.settingDropdownGroup:Show()
                        resultRow.amountText:Hide()
                        resultRow.text:SetPoint("RIGHT", resultRow.settingDropdownGroup, "LEFT", -4, 0)
                    else
                        -- No enumerable options: muted text fallback. Click
                        -- opens the panel via OpenSettingNoClose.
                        if val and val ~= "" then
                            resultRow.amountText:SetText("|cFFAAAAaa" .. val .. "|r")
                            resultRow.amountText:ClearAllPoints()
                            resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                            resultRow.amountText:Show()
                        end
                        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    end
                    resultRow.settingState:Hide()
                    resultRow.settingCheck:Hide()
                    if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                end
            else
                resultRow.settingState:Hide()
                resultRow.settingCheck:Hide()
                if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            end

            -- Flat-list icon sizing. The LEFT icon (UI/map/pin or flatCatIcon)
            -- is large since it's the row's visual anchor. The RIGHT icon
            -- (currency, mount, toy, pet, outfit, appearance set, loot)
            -- gets a mid-sized treatment so it's recognizable without
            -- dominating the row.
            if entry.isFlat and resultRow.icon and resultRow.icon:IsShown() then
                local d = entry.data
                local rightSideIcon = d and (d.mountID or d.toyItemID or d.petID
                    or d.outfitID or d.heirloomItemID or d.transmogSetID
                    or d.category == "Currency"
                    or (d.itemID and d.category == "Loot")
                    or (d.spellID and d.category == "Talent")
                    or (d.spellID and d.category == "Ability")
                    or (d.encounterID and d.category == "Boss")
                    or (d.macroIndex and d.category == "Macro")
                    or (d.bagID and d.category == "Bag")
                    or (d.achievementID and d.category == "Achievement")
                    or d.mapSearchResult)
                if rightSideIcon then
                    local rightSize = entryRowH - 20
                    if rightSize < (theme.iconSize or 16) then
                        rightSize = theme.iconSize or 16
                    end
                    resultRow.icon:SetSize(rightSize, rightSize)
                else
                    local flatIconSize = entryRowH - 16
                    resultRow.icon:SetSize(flatIconSize, flatIconSize)
                end
            end

            -- Flat-mode positioning fixup: category-specific blocks above
            -- (currency, mount/toy/pet, loot, map, repBar) re-anchor text using
            -- LEFT (vertical center) which collapses the name+path stack.
            -- Re-apply flat anchoring last so layout is consistent across
            -- all categories and the path subtext is bounded by the rep bar
            -- when one is shown (so it stays out of the bar's horizontal area).
            if entry.isFlat then
                local catShown = resultRow.flatCatIcon and resultRow.flatCatIcon:IsShown()
                local d = data
                local mainIconOnRight = d and (d.mountID or d.toyItemID or d.petID
                    or d.outfitID or d.heirloomItemID or d.transmogSetID
                    or d.category == "Currency"
                    or (d.itemID and d.category == "Loot")
                    or (d.spellID and d.category == "Talent")
                    or (d.spellID and d.category == "Ability")
                    or (d.encounterID and d.category == "Boss")
                    or (d.macroIndex and d.category == "Macro")
                    or (d.bagID and d.category == "Bag")
                    or (d.achievementID and d.category == "Achievement")
                    or d.mapSearchResult)

                local leftAnchor
                if catShown then
                    leftAnchor = resultRow.flatCatIcon
                elseif not mainIconOnRight and resultRow.icon:IsShown() then
                    leftAnchor = resultRow.icon
                end

                local rightAnchor, rightOffset
                if resultRow.repBar and resultRow.repBar:IsShown() then
                    rightAnchor = resultRow.repBar
                    rightOffset = -4
                elseif mainIconOnRight and resultRow.icon:IsShown() then
                    rightAnchor = resultRow.icon
                    rightOffset = -4
                elseif resultRow.settingSliderGroup and resultRow.settingSliderGroup:IsShown() then
                    rightAnchor = resultRow.settingSliderGroup
                    rightOffset = -4
                elseif resultRow.settingKeybindGroup and resultRow.settingKeybindGroup:IsShown() then
                    rightAnchor = resultRow.settingKeybindGroup
                    rightOffset = -4
                elseif resultRow.settingState and resultRow.settingState:IsShown() then
                    rightAnchor = resultRow.settingState
                    rightOffset = -4
                elseif resultRow.amountText and resultRow.amountText:IsShown() then
                    rightAnchor = resultRow.amountText
                    rightOffset = -4
                else
                    rightAnchor = resultRow
                    rightOffset = -8
                end

                resultRow.text:ClearAllPoints()
                if leftAnchor then
                    resultRow.text:SetPoint("BOTTOMLEFT", leftAnchor, "RIGHT", 6, stackHalfGap)
                else
                    local flatIndent = depth * indPx + 4
                    resultRow.text:SetPoint("BOTTOMLEFT", resultRow, "LEFT", flatIndent, stackHalfGap)
                end
                if rightAnchor == resultRow then
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                else
                    resultRow.text:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
                end

                resultRow.pathSubtext:ClearAllPoints()
                resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -stackGap)
                if rightAnchor == resultRow then
                    resultRow.pathSubtext:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                else
                    resultRow.pathSubtext:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
                end
                resultRow.pathSubtext:Show()
            end

            -- Show pin indicator for pinned entries
            if entry.isPinned and resultRow.pinIcon then
                -- Anchor pin icon to left edge of text, not the (possibly hidden) row icon
                resultRow.pinIcon:ClearAllPoints()
                resultRow.pinIcon:SetPoint("RIGHT", resultRow.text, "LEFT", 0, 0)
                resultRow.pinIcon:Show()
                -- Pinned entries during search: show path prefix in name
                -- (skipped in flat mode, where the path already shows as subtext)
                if not entry.isFlat and data and data.path and #data.path > 0 then
                    local prefix = tconcat(data.path, " > ")
                    resultRow.text:SetText("|cff888888" .. prefix .. " >|r " .. (data.name or ""))
                end
            end

            -- Per-row Apply / Reset extension for settings that staged
            -- a pendingValue (CommitFlag.Apply -- graphics, resolution).
            -- The extension sits BELOW the row as a separate visual
            -- element so the row's own contents (icon, name, inline
            -- editors) don't shift; only the y-cursor below advances to
            -- make room.
            local hasPendingApply = false
            if data and data.settingVariable and ns.BlizzOptionsSearch
               and ns.BlizzOptionsSearch.HasPendingChange then
                hasPendingApply = ns.BlizzOptionsSearch:HasPendingChange(data.settingVariable)
            end
            if resultRow.settingApplyExt then
                resultRow.settingApplyExt:SetShown(hasPendingApply)
            end

            -- Measure text height and expand row if text wraps
            -- Skip header tabs: they have SetMaxLines(1) and can't wrap.
            local actualH = resultRow:GetHeight()
            local textObj
            if theme.showHeaderTab and entry.isPathNode and resultRow.headerTab and resultRow.headerTab:IsShown() then
                textObj = nil
            elseif not entry.isPinHeader then
                textObj = resultRow.text
            end
            if textObj then
                local textHeight = textObj:GetStringHeight()
                local minH = textHeight / ns.SEARCHBAR_FILL
                if minH > actualH then
                    actualH = minH
                    resultRow:SetHeight(actualH)
                    if resultRow.headerTab and resultRow.headerTab:IsShown() then
                        resultRow.headerTab:SetHeight(actualH)
                    end
                    -- Reposition tree connectors for taller row
                    if theme.showTreeLines and depth > 0 then
                        local halfRow = actualH * 0.5
                        local xCenter = (depth - 1) * INDENT_PX + LINE_X_OFF
                        resultRow.treeElbow[depth]:ClearAllPoints()
                        resultRow.treeElbow[depth]:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
                        resultRow.treeElbow[depth]:SetHeight(halfRow + 2)
                        resultRow.treeBranch[depth]:ClearAllPoints()
                        resultRow.treeBranch[depth]:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -halfRow)
                        resultRow.treeBranch[depth]:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -halfRow)
                    end
                end
            end

            -- Off-spec abilities: desaturate the icon and dim the text
            -- to match the spellbook's greyed-out treatment for spells
            -- that belong to a non-active spec line. Active passives
            -- (current-spec, not castable but the player has them) stay
            -- full-color -- they're still "yours". Click for both still
            -- routes to the spellbook page since neither can be cast.
            if data.isOffSpec then
                if resultRow.icon then
                    resultRow.icon:SetVertexColor(0.4, 0.4, 0.4, 1.0)
                end
                if resultRow.text then
                    resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                end
                if resultRow.pathSubtext then
                    resultRow.pathSubtext:SetTextColor(0.4, 0.4, 0.4, 1.0)
                end
            end

            -- Reserve y-cursor space for the apply extension (sits below
            -- the row at -2 offset). Row's own bounds are unchanged.
            if hasPendingApply and resultRow.settingApplyExtH then
                actualH = actualH + resultRow.settingApplyExtH + 2
            end
            yOffset = yOffset + actualH
            resultRow:Show()
        elseif resultRow then
            resultRow:Hide()
            resultRow.isPinHeader = false
            if not InCombatLockdown() then
                resultRow:SetAttribute("type", nil)
                resultRow:SetAttribute("toy", nil)
                resultRow:SetAttribute("action", nil)
                resultRow:SetAttribute("spell", nil)
                resultRow:SetAttribute("macro", nil)
                resultRow:SetAttribute("macrotext", nil)
            end
            if resultRow.headerGrad then resultRow.headerGrad:Hide() end
            if resultRow.headerTab then resultRow.headerTab:Hide() end
            resultRow.separator:Hide()
            resultRow.repBar:Hide()
            if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
            if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
            for d = 1, MAX_DEPTH do
                resultRow.treeVert[d]:Hide()
                resultRow.treeElbow[d]:Hide()
                resultRow.treeBranch[d]:Hide()
            end
        end
    end

    -- Show/hide pin separator between pinned items and search results
    if resultsFrame.pinSeparator then
        if hasResultsAfterPins then
            resultsFrame.pinSeparator:ClearAllPoints()
            resultsFrame.pinSeparator:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, -pinEndYOffset - 4)
            resultsFrame.pinSeparator:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, -pinEndYOffset - 4)
            resultsFrame.pinSeparator:Show()
        else
            resultsFrame.pinSeparator:Hide()
        end
    end

    -- Show/hide category separator lines (between UI, Mount, Toy groups)
    if resultsFrame.categorySeps then
        for si = 1, #resultsFrame.categorySeps do
            local sep = resultsFrame.categorySeps[si]
            if catSepYPositions[si] then
                sep:ClearAllPoints()
                sep:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, -catSepYPositions[si] - 4)
                sep:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, -catSepYPositions[si] - 4)
                sep:Show()
            else
                sep:Hide()
            end
        end
    end

    -- Calculate total content height vs max visible height
    local totalContentHeight = yOffset
    local hasScroll = totalContentHeight > maxVisibleHeight
    local visibleHeight = hasScroll and maxVisibleHeight or totalContentHeight

    -- Size the results frame and scroll child
    resultsFrame:SetHeight(padT + padB + visibleHeight)
    resultsFrame.scrollChild:SetWidth(resultsFrame:GetWidth() - scrollInset)
    resultsFrame.scrollChild:SetHeight(totalContentHeight)

    -- Position scroll frame inside results frame (accounting for padding)
    resultsFrame.scrollFrame:ClearAllPoints()
    resultsFrame.scrollFrame:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 0, -padT)
    resultsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, padB)

    -- Reset scroll position on new search (preserve on expand/collapse toggle)
    if not preserveScroll then
        resultsFrame.scrollFrame:SetVerticalScroll(0)
    end

    if resultsFrame.scrollBar then
        resultsFrame.scrollBar:SetShown(hasScroll)
        if hasScroll then
            resultsFrame.scrollBar:UpdateThumb(totalContentHeight, visibleHeight)
        end
    end

    -- Anchor results above or below based on setting. The combined
    -- silhouette (rounded-rect container) only makes sense when the
    -- dropdown sits BELOW the bar; if the user has flipped to "above"
    -- mode, fall back to the legacy gap-with-own-backdrop look.
    local belowMode = not EasyFind.db.uiResultsAbove
    local roundedTheme = GetActiveTheme().searchBarRounded
    resultsFrame:ClearAllPoints()
    if belowMode then
        resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 0)
    else
        resultsFrame:SetPoint("BOTTOM", searchFrame, "TOP", 0, -5)
    end

    -- In rounded+below mode the resultsFrame backdrop is owned by
    -- the container; clear its own and hide any bg atlas so the
    -- unified silhouette reads as one shape.
    if roundedTheme and belowMode then
        resultsFrame:SetBackdrop(nil)
        if resultsFrame.bgAtlasTex then resultsFrame.bgAtlasTex:Hide() end
        if containerFrame then
            containerFrame:ClearAllPoints()
            containerFrame:SetPoint("TOPLEFT",     searchFrame,  "TOPLEFT",     0, 0)
            containerFrame:SetPoint("TOPRIGHT",    searchFrame,  "TOPRIGHT",    0, 0)
            containerFrame:SetPoint("BOTTOMLEFT",  resultsFrame, "BOTTOMLEFT",  0, 0)
            containerFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, 0)
            -- Divider line at the bar's bottom edge: doubles as the
            -- visual separator between search content and results.
            ns.SetRoundedRectDivider(containerFrame, searchFrame:GetHeight(), true)
        end
    end

    resultsFrame:Show()

    -- If any rep bar row is in side-by-side mode, schedule one deferred re-render so
    -- IsTruncated() can reflect the layout we just set (it reads the previous frame's state).
    if hasSideBySideRepBar and not deferredRepRefreshPending then
        deferredRepRefreshPending = true
        local selfRef = self
        ns.Utils.SafeAfter(0, function()
            deferredRepRefreshPending = false
            selfRef:RefreshResults()
        end)
    end

    -- Reset keyboard selection whenever results change
    selectedIndex = 0
    toggleFocused = false
    self:UpdateSelectionHighlight()
end

function UI:ShowResults(results)
    if not results or #results == 0 then
        self:HideResults()
        return
    end

    local n = 0
    for ri = 1, #results do
        local r = results[ri]
        local d = r and (r.data or r)
        if d then
            n = n + 1
            local e = flatEntries[n]
            if not e then
                e = {}
                flatEntries[n] = e
            end
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.data = d
        end
    end
    for i = n + 1, #flatEntries do
        flatEntries[i] = nil
    end
    self:ShowHierarchicalResults(flatEntries)
end

-- Toggle a boolean setting in place (clicked from a result row).
-- Tries the Settings API first (handles non-CVar settings like action
-- bar visibility), falls back to GetCVar/SetCVar.
function UI:ToggleSettingCheckbox(data)
    if not data or not data.settingVariable then return end
    local var = data.settingVariable
    local curVal = ReadSettingVariable(var)
    if type(curVal) == "boolean" then
        WriteSettingVariable(var, not curVal)
    elseif curVal == "1" or curVal == "0" then
        WriteSettingVariable(var, curVal == "1" and "0" or "1")
    elseif curVal == "true" or curVal == "false" then
        WriteSettingVariable(var, curVal == "true" and "false" or "true")
    elseif curVal == 1 or curVal == 0 then
        WriteSettingVariable(var, curVal == 1 and 0 or 1)
    end
    -- Refresh the row so the checkbox state updates without closing
    -- the search panel. Keeps focus on the editbox so the user can
    -- toggle multiple settings without retyping.
    self:RefreshResults()
    if searchFrame and searchFrame.editBox
       and not (navFrame and navFrame:IsKeyboardEnabled()) then
        searchFrame.editBox.blockFocus = nil
        searchFrame.editBox:SetFocus()
    end
end

-- Advance a dropdown setting to its next value inline. Returns true if
-- we found options and applied a new value; false if the variable
-- wasn't enumerable (caller should fall back to opening the panel).
-- direction: +1 next (default), -1 prev. Wraps around at either end.
function UI:CycleSettingDropdown(data, direction)
    if not data or not data.settingVariable then return false end
    local var = data.settingVariable
    local opts = data.settingOptions
    if not opts and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
        opts = ns.BlizzOptionsSearch.GetOptionsForVariable(var)
        if opts then data.settingOptions = opts end
    end
    if not opts or #opts == 0 then return false end

    local curVal = ReadSettingVariable(var)

    local curIdx
    for i = 1, #opts do
        local v = opts[i].value
        if v == curVal or tostring(v) == tostring(curVal) then
            curIdx = i
            break
        end
    end
    local n = #opts
    local step = direction or 1
    local nextIdx = ((curIdx or 1) - 1 + step) % n + 1
    local nextVal = opts[nextIdx].value

    if not WriteSettingVariable(var, nextVal) then return false end

    self:RefreshResults()
    if searchFrame and searchFrame.editBox
       and not (navFrame and navFrame:IsKeyboardEnabled()) then
        searchFrame.editBox.blockFocus = nil
        searchFrame.editBox:SetFocus()
    end
    return true
end

-- Apply a specific value picked from the dropdown popup (no cycle).
function UI:SetSettingDropdownValue(data, value)
    if not data or not data.settingVariable then return false end
    if not WriteSettingVariable(data.settingVariable, value) then return false end
    self:RefreshResults()
    if searchFrame and searchFrame.editBox
       and not (navFrame and navFrame:IsKeyboardEnabled()) then
        searchFrame.editBox.blockFocus = nil
        searchFrame.editBox:SetFocus()
    end
    return true
end

-- Open the Settings panel to a setting (slider/dropdown/etc.) without
-- closing the EasyFind search results. Mirrors ToggleSettingCheckbox's
-- "stay open" behavior so users can edit one setting in the panel and
-- still see / re-toggle others in the result list.
function UI:OpenSettingNoClose(data)
    if not data or not data.steps or not data.steps[1] then return end
    if ns.BlizzOptionsSearch then
        ns.BlizzOptionsSearch:HandleStep(data.steps[1])
    end
    -- Refresh in case the panel itself altered values that affect the
    -- displayed amountText (e.g. dropdown selection updated).
    self:RefreshResults()
end

-- Close the filter dropdown and any nested sub-popups in one call.
-- Returns true if anything was actually visible (so callers can decide
-- whether to consume the ESC keystroke vs fall through to text-clear /
-- window-close behavior). Walks dropdown.guardFrames so ESC works the
-- same regardless of how deep the user has navigated into sub-filters.
-- Every popup frame the filter dropdown can spawn. Named globals so a
-- brute-force walk catches popups not registered in dropdownGuardFrames
-- (classPopup is parented to UIParent without ever being added to the
-- guard list, etc), and so the close path doesn't depend on the cascade
-- chain firing in the right order.
local FILTER_POPUP_NAMES = {
    "EasyFindAsClassPopup",
    "EasyFindAsOptionsPopup",
    "EasyFindGearOptionsPopup",
    "EasyFindDiffPopup",
    "EasyFindSpecPopup",
    "EasyFindSpecFlyout",
    "EasyFindSpecSubFlyout",
}

function UI:CloseFilterDropdownIfOpen()
    if not searchFrame then return false end
    local dropdown = searchFrame.filterDropdown
    if not dropdown then return false end
    local closedAny = false
    -- Brute-force hide every named popup. classPopup is never registered
    -- in guardFrames; relying on the cascade-via-OnHide chain misses it
    -- when the parent popup is already hidden. Hide by name is idempotent
    -- and order-independent.
    for i = 1, #FILTER_POPUP_NAMES do
        local f = _G[FILTER_POPUP_NAMES[i]]
        if f and f.IsShown and f:IsShown() then
            f:Hide()
            closedAny = true
        end
    end
    -- Collections / Options flyout popups are unnamed; reach them via the
    -- dropdown.flyoutPopups registry.
    if dropdown.flyoutPopups then
        for i = 1, #dropdown.flyoutPopups do
            local popup = dropdown.flyoutPopups[i]
            if popup and popup:IsShown() then
                popup:Hide()
                closedAny = true
            end
        end
    end
    if dropdown.guardFrames then
        for i = 1, #dropdown.guardFrames do
            local guard = dropdown.guardFrames[i]
            if guard and guard:IsShown() then
                guard:Hide()
                closedAny = true
            end
        end
    end
    if dropdown:IsShown() then
        dropdown:Hide()
        closedAny = true
    end
    return closedAny
end

function UI:HideResults()
    if not searchFrame then return end
    if activeKeybindBtn and activeKeybindBtn._stopCapture then
        activeKeybindBtn._stopCapture(activeKeybindBtn)
    end
    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
    if searchFrame.ClearToolbarFocus then searchFrame.ClearToolbarFocus() end
    if not resultsFrame then return end
    resultsFrame:Hide()
    -- Collapse the combined container back to bar-only height: the
    -- two top anchors stay pinned to the bar, the bottom snaps back
    -- to the bar's BOTTOM. Without this the rounded-rect would still
    -- cover the (now empty) dropdown area below.
    if containerFrame then
        containerFrame:ClearAllPoints()
        containerFrame:SetPoint("TOPLEFT",  searchFrame, "TOPLEFT",  0, 0)
        containerFrame:SetPoint("TOPRIGHT", searchFrame, "TOPRIGHT", 0, 0)
        containerFrame:SetPoint("BOTTOM",   searchFrame, "BOTTOM",   0, 0)
        ns.SetRoundedRectDivider(containerFrame, 0, false)
    end
    if resultsFrame.pinSeparator then
        resultsFrame.pinSeparator:Hide()
    end
    if resultsFrame.categorySeps then
        for _, sep in ipairs(resultsFrame.categorySeps) do sep:Hide() end
    end
    if resultsFrame.truncIndicator then
        resultsFrame.truncIndicator:Hide()
    end
    if resultsFrame.truncSeparator then
        resultsFrame.truncSeparator:Hide()
    end
    cachedHierarchical = nil
    self._lastRenderSig = nil
    for i = 1, #resultButtons do
        local row = resultButtons[i]
        if row then
            row.data = nil
            row:Hide()
            if row.icon then
                row.icon.mountID = nil
                row.icon.toyItemID = nil
                row.icon.petID = nil
                row.icon.spellID = nil
                row.icon.outfitID = nil
                row.icon.heirloomItemID = nil
                row.icon.bagItemID = nil
                row.icon.lootItemID = nil
            end
        end
    end
    selectedIndex = 0
    toggleFocused = false
    self:UpdateSelectionHighlight(true)

    if ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end

    idleTrimSerial = idleTrimSerial + 1
    local serial = idleTrimSerial
    if C_Timer and C_Timer.After then
        C_Timer.After(60, function()
            if serial ~= idleTrimSerial then return end
            if resultsFrame and resultsFrame:IsShown() then return end
            if ns.Database and ns.Database.TrimSearchMemory then
                ns.Database:TrimSearchMemory()
            end
            if ns.MapSearch and ns.MapSearch.TrimSearchMemory then
                ns.MapSearch:TrimSearchMemory()
            end
        end)
    end
end

function UI:ShowPinnedItems()
    if not resultsFrame then return end
    local pins = GetAllPins()
    if #pins == 0 then
        self:HideResults()
        return
    end

    wipe(collapsedNodes)
    local entries = pinnedOnlyEntries
    for i, pin in ipairs(pins) do
        local e = entries[i]
        if not e then
            e = {}
            entries[i] = e
        end
        e.name = pin.name
        e.depth = 0
        e.isPathNode = false
        e.isMatch = true
        e.isPinned = true
        e.isFlat = true
        e.data = pin
    end
    for i = #pins + 1, #entries do
        entries[i] = nil
    end
    self:ShowHierarchicalResults(entries)
end

function UI:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    local first = resultButtons[1]
    if resultsFrame:IsShown() and first and first:IsShown() and first.data then
        if ActivateSettingResult(first.data) then return end
        self:SelectResult(first.data)
    end
end

function UI:CountVisibleResults()
    local count = 0
    for i = 1, MAX_BUTTON_POOL do
        local row = resultButtons[i]
        if row and row:IsShown() then
            count = i
        else
            break
        end
    end
    return count
end

function UI:MoveSelection(delta)
    -- CountVisibleResults walks the button pool and trusts each row's
    -- :IsShown(), but child rows of a hidden resultsFrame still report
    -- shown — so a leftover row from a prior search would let Ctrl+J
    -- yank focus into nothing on an empty bar. Gate on the frame.
    if not resultsFrame or not resultsFrame:IsShown() then return end
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return end

    local newIndex = selectedIndex + delta
    if EasyFind.db.uiResultsAbove then
        -- Above: exit to editbox past last result, clamp at first
        if newIndex > visibleCount then newIndex = 0
        elseif newIndex < 1 then newIndex = 1 end
    else
        -- Below: exit to editbox past first result, clamp at last
        if newIndex < 0 then newIndex = 0
        elseif newIndex > visibleCount then newIndex = visibleCount end
    end

    selectedIndex = newIndex
    toggleFocused = false
    self:UpdateSelectionHighlight()
end

function UI:JumpToStart()
    if self:CountVisibleResults() > 0 then
        selectedIndex = 1
        toggleFocused = false
        self:UpdateSelectionHighlight()
    end
end

function UI:JumpToEnd()
    local visibleCount = self:CountVisibleResults()
    if visibleCount > 0 then
        selectedIndex = visibleCount
        toggleFocused = false
        self:UpdateSelectionHighlight()
    end
end

function UI:JumpToNextSection(direction)
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return end

    local startIdx = selectedIndex
    if startIdx == 0 then
        startIdx = direction > 0 and 0 or visibleCount + 1
    end

    -- Find the first non-pinned row index (UI search section start)
    local uiSectionStart = 0
    for i = 1, visibleCount do
        local row = resultButtons[i]
        if row and not row.isPinHeader and not row.isPinned then
            uiSectionStart = i
            break
        end
    end

    -- Find the next section boundary in the given direction.
    -- Boundaries: first non-pinned row (UI search) + any isSectionHeader row.
    local idx = startIdx + direction
    while idx >= 1 and idx <= visibleCount do
        local row = resultButtons[idx]
        if row and (row.isSectionHeader or idx == uiSectionStart) then
            selectedIndex = idx
            toggleFocused = false
            self:UpdateSelectionHighlight()
            return
        end
        idx = idx + direction
    end
end

function UI:UpdateSelectionHighlight(skipRefocus)
    -- Action-hint overlay: replaces the selected row's pathSubtext with
    -- a "Select to ..." hint so the user knows what Enter / left-click
    -- will do, without cluttering every row. Restored to the canonical
    -- subtext (recomputed via GetFlatSubtext) when selection moves.
    local newSelRow = selectedIndex > 0 and resultButtons[selectedIndex] or nil
    if newSelRow and not toggleFocused then
        if not GetActionHint(newSelRow.data) then ClearActionHint() end
        ApplyActionHint(newSelRow)
    else
        ClearActionHint()
    end

    for i = 1, MAX_BUTTON_POOL do
        local resultRow = resultButtons[i]
        if not resultRow then break end
        local isHeaderRow = resultRow.headerTab and resultRow.headerTab:IsShown()
        if resultRow.LockHighlight then
            if i == selectedIndex and not isHeaderRow then
                resultRow:LockHighlight()
            else
                resultRow:UnlockHighlight()
            end
        end
    end
    if selectedIndex > 0 then
        if resultButtons[selectedIndex] then
            Utils.ScrollToButton(resultsFrame.scrollFrame, resultButtons[selectedIndex])
        end
        if searchFrame.editBox:HasFocus() then
            searchFrame.editBox:ClearFocus()
        end
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
    else
        local wasNavigating = navFrame:IsKeyboardEnabled()
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
        if wasNavigating and not skipRefocus and not searchFrame.editBox:HasFocus() then
            searchFrame.editBox.blockFocus = nil
            searchFrame.editBox:SetFocus()
        end
    end

    -- Secure rows need Enter bound to the row button so protected actions fire.
    if not InCombatLockdown() then
        local selRow = selectedIndex > 0 and resultButtons[selectedIndex]
        local rd = selRow and selRow.data
        local secureRow = rd and (rd.outfitID or rd.toyItemID
            or (rd.spellID and not IsSpellbookOnlyAbility(rd))
            or rd.mountID or rd.macroIndex or rd.slashCommand
            or (rd.itemID and rd.category == "Bag"))
        if secureRow then
            local btnName = selRow:GetName()
            if btnName then
                SetOverrideBindingClick(navFrame, true, "ENTER", btnName, "LeftButton")
            end
        else
            ClearOverrideBindings(navFrame)
        end
    end
end

function UI:ActivateSelected()
    if selectedIndex > 0 and selectedIndex <= MAX_BUTTON_POOL then
        local resultRow = resultButtons[selectedIndex]
        if resultRow and resultRow:IsShown() then
            -- Don't allow activating unearned currencies
            if resultRow.isUnearnedCurrency then
                return
            end

            if resultRow.isPinHeader then
                return
            end

            if resultRow.isPathNode and toggleFocused then
                -- Toggle collapse when focus is on the +/- control
                local key = (resultRow.pathNodeName or "") .. "_" .. (resultRow.pathNodeDepth or 0)
                collapsedNodes[key] = not collapsedNodes[key]
                if cachedHierarchical then
                    local savedIndex = selectedIndex
                    local savedToggle = toggleFocused
                    self:ShowHierarchicalResults(cachedHierarchical, true)
                    selectedIndex = savedIndex
                    toggleFocused = savedToggle
                    self:UpdateSelectionHighlight()
                end
            elseif resultRow.data then
                if ActivateSettingResult(resultRow.data) then return end
                self:SelectResult(resultRow.data)
            end
            return
        end
    end
    -- Fallback: select first result if nothing is highlighted
    self:SelectFirstResult()
end

-- Hide vendor-only transmog controls when opened via search (not at an NPC).
-- Shows a message explaining full functionality requires a transmogrifier.
-- Restores everything when the frame closes.
-- Show or hide the lock overlay on a result row's outfit icon.
function UI:UpdateOutfitLockOverlay(resultRow, isLocked)
    if not resultRow.icon then return end
    if not resultRow._lockOverlay then
        local overlay = resultRow:CreateTexture(nil, "OVERLAY")
        overlay:SetAtlas("transmog-outfit-spellFrame-active")
        overlay:SetPoint("CENTER", resultRow.icon, "CENTER", 0, 0)
        resultRow._lockOverlay = overlay

    end
    local size = (resultRow.icon:GetWidth() or 16) + 6
    resultRow._lockOverlay:SetSize(size, size)
    resultRow._lockOverlay:SetShown(isLocked)
end

function UI:ApplyTransmogBrowseMode()
    if not TransmogFrame then return end

    -- Collect vendor-only frames to hide
    local hidden = {}
    local outfitCollection = TransmogFrame.OutfitCollection
    if outfitCollection then
        if outfitCollection.PurchaseOutfitButton then
            outfitCollection.PurchaseOutfitButton:Hide()
            hidden[#hidden + 1] = outfitCollection.PurchaseOutfitButton
        end
        if outfitCollection.SaveOutfitButton then
            outfitCollection.SaveOutfitButton:Hide()
            hidden[#hidden + 1] = outfitCollection.SaveOutfitButton
        end
    end
    if outfitCollection and outfitCollection.MoneyFrame then
        outfitCollection.MoneyFrame:Hide()
        hidden[#hidden + 1] = outfitCollection.MoneyFrame
    end

    -- Hide the Situations tab (vendor-only feature)
    local wardrobeCollection = TransmogFrame.WardrobeCollection
    local tabHeaders = wardrobeCollection and wardrobeCollection.TabHeaders
    if tabHeaders then
        for _, tab in ipairs({ tabHeaders:GetChildren() }) do
            if tab.GetText and tab:GetText() == "Situations" then
                tab:Hide()
                hidden[#hidden + 1] = tab
                break
            end
        end
    end

    -- Disable right-click on outfit name buttons (shows "Change Name/Icon"
    -- which doesn't work without a vendor). ScrollBox items are recycled,
    -- so re-register on each visible frame and hook the ScrollBox update.
    local outfitScrollBox = outfitCollection and outfitCollection.OutfitList
        and outfitCollection.OutfitList.ScrollBox
    if outfitScrollBox and outfitScrollBox.EnumerateFrames then
        local function disableOutfitRightClick()
            for _, itemFrame in outfitScrollBox:EnumerateFrames() do
                local outfitBtn = itemFrame.OutfitButton
                if outfitBtn and outfitBtn.RegisterForClicks then
                    outfitBtn:RegisterForClicks("LeftButtonUp")
                end
            end
        end
        disableOutfitRightClick()
        -- Re-apply when ScrollBox recycles frames (scroll, resize)
        if not outfitScrollBox._efBrowseHooked then
            outfitScrollBox._efBrowseHooked = true
            hooksecurefunc(outfitScrollBox, "Update", function()
                if TransmogFrame._efBrowseMode then
                    disableOutfitRightClick()
                end
            end)
        end
    end
    TransmogFrame._efBrowseMode = true

    TransmogFrame._efHiddenFrames = hidden

    -- Browse-mode message (left panel, where vendor buttons were)
    if not TransmogFrame._efBrowseMsg then
        local msg = TransmogFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetText("Visit a transmogrification vendor for full functionality.")
        msg:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
        msg:SetJustifyH("CENTER")
        TransmogFrame._efBrowseMsg = msg
    end
    local msg = TransmogFrame._efBrowseMsg
    msg:ClearAllPoints()
    local anchor = outfitCollection and outfitCollection.PurchaseOutfitButton
    if anchor then
        msg:SetPoint("TOP", anchor, "TOP", 0, 0)
    elseif outfitCollection then
        msg:SetPoint("BOTTOM", outfitCollection, "BOTTOM", 0, 20)
    else
        msg:SetPoint("BOTTOM", TransmogFrame, "BOTTOM", 0, 30)
    end
    msg:SetWidth((outfitCollection and outfitCollection:GetWidth() - 20) or 280)
    msg:Show()

    -- Situations message (top right, near the hidden tab)
    if not TransmogFrame._efSituationsMsg then
        local sitMsg = TransmogFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sitMsg:SetText("See transmogrification vendor\nto adjust Situations settings.")
        sitMsg:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
        sitMsg:SetJustifyH("RIGHT")
        TransmogFrame._efSituationsMsg = sitMsg
    end
    local sitMsg = TransmogFrame._efSituationsMsg
    sitMsg:ClearAllPoints()
    if tabHeaders then
        sitMsg:SetPoint("LEFT", tabHeaders, "RIGHT", 8, 6)
    else
        sitMsg:SetPoint("TOPRIGHT", TransmogFrame, "TOPRIGHT", -40, -55)
    end
    sitMsg:Show()

    -- Restore on hide (one-shot hook, reads _efHiddenFrames at fire time)
    if not TransmogFrame._efBrowseHooked then
        TransmogFrame._efBrowseHooked = true
        TransmogFrame:HookScript("OnHide", function(self)
            self._efBrowseMode = nil
            if self._efHiddenFrames then
                for _, frame in ipairs(self._efHiddenFrames) do
                    frame:Show()
                end
                self._efHiddenFrames = nil
            end
            if self._efBrowseMsg then
                self._efBrowseMsg:Hide()
            end
            if self._efSituationsMsg then
                self._efSituationsMsg:Hide()
            end
            -- Restore right-click on outfit buttons
            local oc = self.OutfitCollection
            local sb = oc and oc.OutfitList and oc.OutfitList.ScrollBox
            if sb and sb.EnumerateFrames then
                for _, itemFrame in sb:EnumerateFrames() do
                    local outfitBtn = itemFrame.OutfitButton
                    if outfitBtn and outfitBtn.RegisterForClicks then
                        outfitBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    end
                end
            end
        end)
    end
end

local function ExtractSlot(value)
    return value.slotIndex
        or value.spellBookIndex
        or value.spellBookItemSlotIndex
        or value.spellBookItemIndex
        or value.itemIndex
        or value.slot
        or value.index
end

local function ExtractBank(value)
    return value.spellBank
        or value.spellBookBank
        or value.spellBookItemBank
        or value.bank
end

local function ExtractSpecID(value)
    local specID = value.specID
    if specID ~= nil and specID ~= 0 then return specID end
    if value.spellBookSpecID ~= nil then return value.spellBookSpecID end
    local offSpecID = value.offSpecID
    if offSpecID ~= nil and offSpecID ~= 0 then return offSpecID end
    return specID
end

local function HasSlotMismatch(value, targetSlot, targetBank)
    if not targetSlot then return false end
    local valueSlot = ExtractSlot(value)
    if not valueSlot then return false end
    if valueSlot ~= targetSlot then return true end
    if not targetBank then return false end
    local valueBank = ExtractBank(value)
    if valueBank ~= nil and valueBank ~= targetBank then return true end
    return false
end

local function HasSpecMismatch(value, targetSpecID)
    if targetSpecID == nil then return false end
    local valueSpecID = ExtractSpecID(value)
    return valueSpecID ~= nil and valueSpecID ~= targetSpecID
end

local function SpellRecordMatches(value, target, seen)
    if not value then return false end
    local vt = type(value)
    if vt == "number" then
        if target.spellBookSpecID ~= nil or target.spellBookIndex then return false end
        return value == target.spellID or value == target.spellBookSpellID
    end
    if vt ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true

    local targetSpell = target.spellBookSpellID or target.spellID
    local targetSlot = target.spellBookIndex
    local targetBank = target.spellBookBank
    local targetSpecID = target.spellBookSpecID

    if targetSpecID ~= nil then
        local specID = ExtractSpecID(value)
        if specID and specID == targetSpecID then
            local slot = ExtractSlot(value)
            if slot and targetSlot and slot == targetSlot then return true end
            if targetSpell and (value.spellID == targetSpell
                or value.actionID == targetSpell) then return true end
        end
    end

    if targetSlot then
        local bank = ExtractBank(value)
        local slot = ExtractSlot(value)
        if slot == targetSlot
            and (not targetBank or bank == nil or bank == targetBank)
            and not HasSpecMismatch(value, targetSpecID) then
            return true
        end
    end

    -- When the target carries disambiguation hints (specID or slot),
    -- spellID/name matches REQUIRE the value to carry a matching
    -- specID or slot. Without that, a sibling row with no slot/spec
    -- exposed (e.g. SpellBookItemInfo returned by a Button method)
    -- would match by spellID alone and the wrong "Wrath" wins.
    local needsDisambig = target.spellBookSpecID ~= nil
        or target.spellBookIndex ~= nil
    local function valueHasMatchingDisambig()
        local valueSpec = ExtractSpecID(value)
        if targetSpecID and valueSpec and valueSpec == targetSpecID then
            return true
        end
        local valueSlot = ExtractSlot(value)
        if targetSlot and valueSlot and valueSlot == targetSlot then
            return true
        end
        return false
    end

    if targetSpell and (value.spellID == targetSpell
        or value.spellId == targetSpell
        or value.actionID == targetSpell
        or value.actionId == targetSpell
        or value.id == targetSpell) then
        if not HasSpecMismatch(value, targetSpecID)
            and not HasSlotMismatch(value, targetSlot, targetBank)
            and (not needsDisambig or valueHasMatchingDisambig()) then
            return true
        end
    end

    local targetName = target.nameLower or (target.spellName and slower(target.spellName))
    if targetName and value.name and slower(value.name) == targetName then
        if not HasSpecMismatch(value, targetSpecID)
            and not HasSlotMismatch(value, targetSlot, targetBank)
            and (not needsDisambig or valueHasMatchingDisambig()) then
            return true
        end
    end

    if value.data and value.data ~= value and SpellRecordMatches(value.data, target, seen) then return true end
    if value.elementData and value.elementData ~= value and SpellRecordMatches(value.elementData, target, seen) then return true end
    if value.spellInfo and value.spellInfo ~= value and SpellRecordMatches(value.spellInfo, target, seen) then return true end
    if value.spellBookItemInfo and value.spellBookItemInfo ~= value and SpellRecordMatches(value.spellBookItemInfo, target, seen) then return true end
    if value.spellBookItemData and value.spellBookItemData ~= value and SpellRecordMatches(value.spellBookItemData, target, seen) then return true end
    if value.itemInfo and value.itemInfo ~= value and SpellRecordMatches(value.itemInfo, target, seen) then return true end
    return false
end

local function SpellFrameMatchesSelf(frame, target)
    if not frame then return false end

    local targetSlot = target.spellBookIndex
    local targetBank = target.spellBookBank
    if targetSlot and frame.GetItemSlotIndex then
        local sok, slot = pcall(frame.GetItemSlotIndex, frame)
        if sok and slot == targetSlot then
            if not targetBank or not frame.GetSpellBookItemBank then
                return true
            end
            local bok, bank = pcall(frame.GetSpellBookItemBank, frame)
            if not bok or bank == nil or bank == targetBank then
                return true
            end
        end
    end

    if frame.GetElementData then
        local ok, data = pcall(frame.GetElementData, frame)
        if ok and SpellRecordMatches(data, target) then return true end
    end
    if frame.GetSpellID then
        local ok, id = pcall(frame.GetSpellID, frame)
        if ok and SpellRecordMatches(id, target) then return true end
    end
    if frame.GetSpellBookItemInfo then
        local ok, info = pcall(frame.GetSpellBookItemInfo, frame)
        if ok and SpellRecordMatches(info, target) then return true end
    end
    if SpellRecordMatches(frame.data, target) then return true end
    if SpellRecordMatches(frame.elementData, target) then return true end
    if SpellRecordMatches(frame.spellInfo, target) then return true end
    if SpellRecordMatches(frame.spellBookItemInfo, target) then return true end
    if SpellRecordMatches(frame.spellBookItemData, target) then return true end
    return false
end

local function SpellFrameMatches(frame, target)
    if SpellFrameMatchesSelf(frame, target) then return true end
    if frame and frame.GetParent then
        local parent = frame:GetParent()
        if parent and SpellFrameMatchesSelf(parent, target) then return true end
        if parent and parent.GetParent then
            local gp = parent:GetParent()
            if gp and SpellFrameMatchesSelf(gp, target) then return true end
        end
    end
    return false
end

local function SpellFrameTextMatches(frame, target)
    local targetName = target and (target.nameLower or (target.spellName and slower(target.spellName)))
    if not targetName then return false end
    local text = GetButtonText(frame)
    return text and slower(text) == targetName
end

local function GetTabSkillLineName(tab)
    if not tab then return nil end
    if type(tab.tabText) == "string" and tab.tabText ~= "" then
        return tab.tabText
    end
    if tab.skillLineInfo and type(tab.skillLineInfo.name) == "string" then
        return tab.skillLineInfo.name
    end
    if type(tab.skillLine) == "table" and type(tab.skillLine.name) == "string" then
        return tab.skillLine.name
    end
    if tab.elementData and type(tab.elementData.name) == "string" then
        return tab.elementData.name
    end
    if tab.GetElementData then
        local ok, ed = pcall(tab.GetElementData, tab)
        if ok and ed and type(ed.name) == "string" then return ed.name end
    end
    if tab.tooltipText and type(tab.tooltipText) == "string" then
        return tab.tooltipText
    end
    if tab.GetText then
        local ok, txt = pcall(tab.GetText, tab)
        if ok and type(txt) == "string" and txt ~= "" then return txt end
    end
    local btnText = GetButtonText(tab)
    if btnText and btnText ~= "" then return btnText end
    return nil
end

local function FindSpellbookCategoryTab(frame, data)
    local book = frame and frame.SpellBookFrame
    local tabSystem = book and book.CategoryTabSystem
    if not tabSystem or not tabSystem.GetChildren then return nil end

    local targetName = data and data.spellBookCategoryName
    local targetLower = targetName and slower(targetName)
    local targetIsGeneral = targetLower == slower(_G.GENERAL or "general")

    local seen = {}
    local candidates = {}
    local function add(tab)
        if tab and not seen[tab] and tab.Click then
            seen[tab] = true
            candidates[#candidates + 1] = tab
        end
    end
    if tabSystem.tabs then
        for _, tab in ipairs(tabSystem.tabs) do add(tab) end
    end
    local children = { tabSystem:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child:IsShown() then add(child) end
    end

    local generalLower = slower(_G.GENERAL or "general")
    local function isGeneralTab(tab)
        local name = GetTabSkillLineName(tab)
        if name and slower(name) == generalLower then return true end
        local text = GetButtonText(tab)
        if text and slower(text) == generalLower then return true end
        return false
    end

    if targetIsGeneral then
        for i = 1, #candidates do
            if isGeneralTab(candidates[i]) then return candidates[i] end
        end
    else
        local classLower = UnitClass and slower(UnitClass("player") or "") or ""
        for i = 1, #candidates do
            local name = GetTabSkillLineName(candidates[i])
            if name and classLower ~= "" and slower(name) == classLower then
                return candidates[i]
            end
        end
        for i = 1, #candidates do
            if not isGeneralTab(candidates[i]) then return candidates[i] end
        end
    end

    return nil
end

local function GetSpellbookPagedFrame(frame)
    local book = frame and frame.SpellBookFrame
    return book and (book.PagedSpellsFrame or book) or nil
end

local function SpellbookPageButton(frame, key)
    local paged = GetSpellbookPagedFrame(frame)
    local controls = paged and paged.PagingControls
    return controls and controls[key] or nil
end

local function CanClickButton(btn)
    if not btn or not btn:IsShown() then return false end
    if btn.IsEnabled then
        local ok, enabled = pcall(btn.IsEnabled, btn)
        if ok then return enabled end
    end
    return btn.Click ~= nil
end

local function ClickSpellbookPage(frame, key)
    local btn = SpellbookPageButton(frame, key)
    if not CanClickButton(btn) then return false end
    return ClickButton(btn)
end

local function RewindSpellbookToFirstPage(frame)
    for _ = 1, 12 do
        if not ClickSpellbookPage(frame, "PrevPageButton") then break end
    end
end

local function GetSpellbookDataProvider(paged)
    if not paged then return nil, nil end
    local function probe(frame)
        if not frame then return nil end
        if frame.GetDataProvider then
            local ok, dp = pcall(frame.GetDataProvider, frame)
            if ok and dp then return dp end
        end
        return nil
    end
    local dp = probe(paged)
    if dp then return dp, paged end
    if paged.GetChildren then
        for _, child in ipairs({ paged:GetChildren() }) do
            local cdp = probe(child)
            if cdp then return cdp, child end
            if child and child.GetChildren then
                for _, gc in ipairs({ child:GetChildren() }) do
                    local gdp = probe(gc)
                    if gdp then return gdp, gc end
                end
            end
        end
    end
    return nil, nil
end

local function FindSpellElementInSection(paged, data)
    local dp = GetSpellbookDataProvider(paged)
    if not dp then return nil end

    local size = dp.GetSize and dp:GetSize() or 0
    if size == 0 and not dp.Enumerate then return nil end

    local targetSpellID = data.spellBookSpellID or data.spellID
    local targetSlot = data.spellBookIndex
    local targetBank = data.spellBookBank
    local targetSpecID = data.spellBookSpecID
    local targetNameLower = data.nameLower
        or (data.spellName and slower(data.spellName))
        or (data.name and slower(data.name))
    local targetSectionLower = data.spellBookCategoryName
        and slower(data.spellBookCategoryName)

    local currentSection
    local fallback
    local function inspect(elem)
        if elem then
            local info = elem.spellBookItemInfo or elem.spellInfo or elem.spellBookItemData
            local isSpellElement = info or elem.spellID or elem.actionID or ExtractSlot(elem)
            if not isSpellElement then
                local hdr = elem.name or elem.title or elem.text or elem.header
                if type(hdr) == "string" and hdr ~= "" then
                    currentSection = slower(hdr)
                end
            else
                info = info or elem
                local elemSlot = ExtractSlot(elem) or ExtractSlot(info)
                local elemBank = ExtractBank(elem) or ExtractBank(info)
                local elemSpecID = ExtractSpecID(elem) or ExtractSpecID(info)
                local specOK = targetSpecID == nil or elemSpecID == nil
                    or elemSpecID == targetSpecID
                local match = false
                if specOK and targetSlot and elemSlot == targetSlot
                    and (not targetBank or elemBank == nil or elemBank == targetBank) then
                    match = true
                elseif specOK and targetSpellID
                    and not HasSlotMismatch(elem, targetSlot, targetBank)
                    and not HasSlotMismatch(info, targetSlot, targetBank)
                    and (elem.spellID == targetSpellID
                        or elem.actionID == targetSpellID
                        or info.spellID == targetSpellID
                        or info.actionID == targetSpellID) then
                    match = true
                elseif specOK and targetNameLower and info.name
                    and not HasSlotMismatch(elem, targetSlot, targetBank)
                    and not HasSlotMismatch(info, targetSlot, targetBank)
                    and slower(info.name) == targetNameLower then
                    match = true
                end
                if match then
                    if targetSectionLower and currentSection == targetSectionLower then
                        return elem
                    end
                    fallback = fallback or elem
                end
            end
        end
        return nil
    end

    if dp.Enumerate then
        for a, b in dp:Enumerate() do
            local found = inspect(b or a)
            if found then return found end
        end
    else
        for i = 1, size do
            local elem = dp.Find and dp:Find(i)
            local found = inspect(elem)
            if found then return found end
        end
    end
    return fallback
end

local function ScrollSpellbookToElement(paged, elem)
    if not elem then return false end
    local _, host = GetSpellbookDataProvider(paged)
    if host and host.ScrollToElementData then
        local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
        pcall(host.ScrollToElementData, host, elem, alignCenter)
        return true
    end
    return false
end

local function FindVisibleButtonForElement(paged, elem)
    if not elem then return nil end
    local _, host = GetSpellbookDataProvider(paged)
    if host and host.EnumerateFrames then
        for _, f in host:EnumerateFrames() do
            if f and f:IsShown() and f.GetElementData then
                local ok, ed = pcall(f.GetElementData, f)
                if ok and ed == elem then return f end
            end
        end
    end
    return nil
end

local function HideHighlightOnHover(frame)
    if not frame or frame._efHideHighlightOnHover or not frame.HookScript then return end
    frame._efHideHighlightOnHover = true
    frame:HookScript("OnEnter", function()
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end)
    if frame.IsMouseOver and frame:IsMouseOver() then
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end
end

local function FindSpellbookButton(root, target, scroll, candidate)
    if not root then return nil end
    local nextCandidate = candidate
    if root.Click then
        nextCandidate = root
    elseif root.GetScript then
        local ok, onClick = pcall(root.GetScript, root, "OnClick")
        if ok and onClick then nextCandidate = root end
    end
    if root.EnumerateFrames and root.GetDataProvider then
        if scroll then
            Utils.ScrollBoxScrollTo(root, function(data)
                return SpellRecordMatches(data, target)
            end)
        end
        local hasID = target and (target.spellBookSpellID or target.spellID)
        local btn = Utils.ScrollBoxFindButton(root, function(frame)
            if SpellFrameMatches(frame, target) then return true end
            if not hasID and SpellFrameTextMatches(frame, target) then return true end
            return false
        end)
        if btn then return btn end
    end
    local hasID = target and (target.spellBookSpellID or target.spellID)
    if SpellFrameMatches(root, target) then
        return nextCandidate or root
    end
    if not hasID and SpellFrameTextMatches(root, target) then
        return nextCandidate or root
    end
    if root.GetChildren then
        for _, child in ipairs({ root:GetChildren() }) do
            if child and child:IsShown() then
                local found = FindSpellbookButton(child, target, scroll, nextCandidate)
                if found then return found end
            end
        end
    end
    return nil
end

-- Open the Collections > Toys tab and surface the target toy. For
-- unusable toys (faction-restricted etc.) the secure use no-ops, so we
-- route here instead. SetFilterString filters the ToyBox to just this
-- toy's name -- the cleanest "highlight": the player sees only the toy
-- they were looking for. Restoring the prior filter is left to the
-- player; once they're done they can clear the search field.
function UI:OpenToyInToyBox(data)
    if not data or not data.toyItemID then return end
    local highlight = ns.Highlight
    local TOY_TAB = 3

    local function step(attempt)
        local journal = _G["CollectionsJournal"]
        if not (journal and journal:IsShown()) then
            local micro = _G["CollectionsMicroButton"]
            if micro then ClickButton(micro) end
            if attempt < 30 then
                C_Timer.After(0.05, function() step(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("CollectionsJournal", TOY_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("CollectionsJournal", TOY_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                C_Timer.After(0, function() step(attempt + 1) end)
            end
            return
        end
        if C_ToyBox and C_ToyBox.SetFilterString then
            C_ToyBox.SetFilterString(data.name or "")
            if C_ToyBox.ForceToyRefilter then C_ToyBox.ForceToyRefilter() end
        end
    end

    step(1)
end

-- Open PlayerSpellsFrame to the Talents tab and drive Blizzard's own
-- search box at PlayerSpellsFrame.TalentsFrame.SearchBox with the
-- talent name. The game's native search highlights matching nodes
-- with the spyglass icon -- no need for our own highlight pass.
-- Cleanest path: matches the visual the player already recognizes
-- and works for hero / sub-tree talents without us walking parents.
function UI:OpenTalentInTalentsTab(data)
    local highlight = ns.Highlight
    local TALENTS_TAB = 2

    local function ensureFrameOnTab(attempt)
        local frame = _G["PlayerSpellsFrame"]
        if not (frame and frame:IsShown()) then
            local util = _G.PlayerSpellsUtil
            if util and util.TogglePlayerSpellsFrame then
                pcall(util.TogglePlayerSpellsFrame, TALENTS_TAB)
            else
                ClickButton(_G["PlayerSpellsMicroButton"])
            end
            if attempt < 30 then
                C_Timer.After(0.05, function() ensureFrameOnTab(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("PlayerSpellsFrame", TALENTS_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("PlayerSpellsFrame", TALENTS_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                C_Timer.After(0, function() ensureFrameOnTab(attempt + 1) end)
            end
            return
        end
        -- Frame open and on Talents tab: light up the matching talent
        -- button's SearchIcon directly. Each talent button is parented
        -- to TalentsFrame.ButtonsParent (or a hero/sub-tree container)
        -- and frame-named after the talent itself, so the cleanest path
        -- is: walk children, match by GetName(), Show() the SearchIcon.
        local talentsFrame = frame.TalentsFrame
        local targetLower = (data.name or ""):lower()

        local function nameOf(btn)
            if not btn or not btn.GetName then return nil end
            local n = btn:GetName()
            return n and n:lower() or nil
        end

        -- Recursive search: choice nodes nest the actual option button
        -- one (or more) levels below ButtonsParent's direct child, so a
        -- fixed 2-level walk misses them. Cap depth so we don't spin on
        -- weird parent loops.
        local function searchTree(frame, depth)
            if not frame or depth > 5 then return nil end
            if frame.SearchIcon and nameOf(frame) == targetLower then
                return frame
            end
            if frame.GetChildren then
                local kids = { frame:GetChildren() }
                for i = 1, #kids do
                    local found = searchTree(kids[i], depth + 1)
                    if found then return found end
                end
            end
            return nil
        end

        local function findMatchingButton()
            if not talentsFrame then return nil end
            local containers = {
                talentsFrame.ButtonsParent,
                talentsFrame.HeroTalentsContainer,
                talentsFrame.SubTreeContainer,
            }
            for _, parent in ipairs(containers) do
                local found = searchTree(parent, 0)
                if found then return found end
            end
            return nil
        end

        local tries = 0
        local function showSpyglass()
            tries = tries + 1
            local btn = findMatchingButton()
            if btn and btn.SearchIcon and btn.SearchIcon.Show then
                -- Bump strata above the talent button's own ARTWORK / OVERLAY
                -- siblings so the spyglass isn't occluded by the talent
                -- icon's connectors and glow textures.
                if btn.SearchIcon.SetFrameStrata then
                    btn.SearchIcon:SetFrameStrata("HIGH")
                end
                if btn.SearchIcon.SetFrameLevel and btn.GetFrameLevel then
                    btn.SearchIcon:SetFrameLevel(btn:GetFrameLevel() + 10)
                end
                btn.SearchIcon:Show()
                if ns.Highlight and ns.Highlight.RegisterTalentSearchIcon then
                    ns.Highlight:RegisterTalentSearchIcon(btn, targetLower, nameOf)
                end
                return
            end
            if tries < 20 then
                C_Timer.After(0.05, showSpyglass)
            end
        end
        C_Timer.After(0, showSpyglass)
    end

    ensureFrameOnTab(1)
end

function UI:OpenAbilityInSpellbook(data)
    local highlight = ns.Highlight
    local categoryClicked = false
    local rewound = false
    local triedElementScroll = false
    local targetElement
    local pagesAdvanced = 0
    local MAX_PAGES = 20

    local function openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if frame and frame:IsShown() then
            if highlight and highlight.IsTabSelected
               and not highlight:IsTabSelected("PlayerSpellsFrame", 3) then
                local tab = highlight.GetTabButton
                    and highlight:GetTabButton("PlayerSpellsFrame", 3)
                ClickButton(tab)
                return true
            end
            return false
        end

        local util = _G.PlayerSpellsUtil
        if util and util.TogglePlayerSpellsFrame then
            pcall(util.TogglePlayerSpellsFrame, 3)
        else
            ClickButton(_G["PlayerSpellsMicroButton"])
        end
        return true
    end

    local function reveal(attempt)
        local needsRetry = openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if needsRetry then
            if attempt < 36 then
                C_Timer.After(0.05, function() reveal(attempt + 1) end)
            end
            return
        end
        local root = frame and frame.SpellBookFrame
        if not root or not root:IsShown() then
            if attempt < 36 then
                C_Timer.After(0.05, function() reveal(attempt + 1) end)
            end
            return
        end

        if not categoryClicked then
            local tab = FindSpellbookCategoryTab(frame, data)
            if tab then
                categoryClicked = true
                rewound = false
                triedElementScroll = false
                targetElement = nil
                pagesAdvanced = 0
                ClickButton(tab)
                if attempt < 36 then
                    C_Timer.After(0, function() reveal(attempt + 1) end)
                end
                return
            end
        end

        local paged = GetSpellbookPagedFrame(frame) or root

        if not triedElementScroll then
            triedElementScroll = true
            targetElement = FindSpellElementInSection(paged, data)
            if targetElement and ScrollSpellbookToElement(paged, targetElement) then
                C_Timer.After(0, function() reveal(attempt + 1) end)
                return
            end
        end

        -- Validator passed to HighlightFrame's watcher. ScrollBox button
        -- pools repurpose the same physical button for different spells
        -- when the user pages the spellbook, so the frame stays visible
        -- but stops representing the search target. This re-checks the
        -- spell identity each tick and clears the highlight on mismatch.
        local function stillRepresentsTarget(f)
            return SpellFrameMatchesSelf(f, data)
        end

        if targetElement then
            local elementBtn = FindVisibleButtonForElement(paged, targetElement)
            if elementBtn and highlight then
                if highlight.HighlightSpellbookSpell then
                    highlight:HighlightSpellbookSpell(elementBtn, stillRepresentsTarget)
                else
                    highlight:HighlightFrame(elementBtn, nil, stillRepresentsTarget)
                    HideHighlightOnHover(elementBtn)
                end
                return
            end
        end

        local btn = FindSpellbookButton(paged, data, false)
        if btn and highlight then
            if highlight.HighlightSpellbookSpell then
                highlight:HighlightSpellbookSpell(btn, stillRepresentsTarget)
            else
                highlight:HighlightFrame(btn, nil, stillRepresentsTarget)
                HideHighlightOnHover(btn)
            end
            return
        end

        if not rewound then
            RewindSpellbookToFirstPage(frame)
            rewound = true
            pagesAdvanced = 0
            C_Timer.After(0, function() reveal(attempt + 1) end)
            return
        end

        if pagesAdvanced < MAX_PAGES
           and ClickSpellbookPage(frame, "NextPageButton") then
            pagesAdvanced = pagesAdvanced + 1
            C_Timer.After(0, function() reveal(attempt + 1) end)
            return
        end
        if attempt < 36 then
            C_Timer.After(0.05, function() reveal(attempt + 1) end)
        end
    end

    C_Timer.After(0.05, function() reveal(1) end)
end

function UI:SelectResult(data, forceGuide)
    if not data then return end
    local useFast = not forceGuide

    selectingResult = true
    searchFrame.editBox:SetText("")
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:Show()
    selectingResult = false
    if EasyFind.db.autoHide then
        self:Hide()
    else
        self:HideResults()
    end

    -- Slash-command actions (e.g. Pet Dismiss → /dismisspet) fire via
    -- the secure macrotext attribute set when the row was rendered. The
    -- click already ran the command; nothing else for SelectResult to do.
    if data.slashCommand then return end



    -- Transmogrification panel: load and show TransmogFrame
    if data.steps and data.steps[1] and data.steps[1].loadTransmog then
        if not TransmogFrame then
            Transmog_LoadUI()
        end
        if TransmogFrame then
            ShowUIPanel(TransmogFrame)
            self:ApplyTransmogBrowseMode()
        end
        return
    end

    -- Blizzard Settings panel: open the named category directly.
    -- Both fast and guide modes do the same thing here -- there's no
    -- multi-step guide to walk for an in-game settings category.
    if data.steps and data.steps[1] and data.steps[1].settingsCategory then
        if ns.BlizzOptionsSearch then
            ns.BlizzOptionsSearch:HandleStep(data.steps[1])
        end
        return
    end

    -- Outfit: equip handled by SecureActionButton (mouse click or Enter binding).
    if data.outfitID then return end

    -- Loot: Ctrl+click opens dressing room, regular click navigates EJ
    if data.itemID and data.category == "Loot" then
        local lootLink = ns.Database and ns.Database:GetLootItemLink(data)
        if IsControlKeyDown() and lootLink then
            if DressUpItemLink(lootLink) then
                return
            end
        end

        -- Sync EJ loot filter so the item is visible when we navigate there
        if ns.Database then ns.Database:SyncEJLootFilter() end

        local isRaid = data.lootSourceType == "Raid"
        local tabIndex = isRaid and 5 or 4
        local ejDiffID = ns.Database and ns.Database:GetEJDifficultyID(data.lootSourceType)
        local guideData = {
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = tabIndex },
                { waitForFrame = "EncounterJournal", ejInstance = data.lootInstanceName, ejInstanceID = data.instanceID },
                { waitForFrame = "EncounterJournal", ejBoss = data.lootSourceName, ejEncounterID = data.encounterID },
                { waitForFrame = "EncounterJournal", ejLootTab = true, ejDifficultyID = ejDiffID },
                { waitForFrame = "EncounterJournal", ejLootItem = data.itemID, ejLootItemName = data.name },
            },
        }

        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Appearance Set: Ctrl+click opens dressing room with full set, regular click navigates.
    -- For pinned entries saved before transmogSetID was persisted, recover the
    -- ID by looking up the set name in the live database.
    if data.category == "Appearance Set" and not data.transmogSetID and data.name and ns.Database then
        data.transmogSetID = ns.Database:GetTransmogSetIDByName(data.name)
    end
    if data.transmogSetID then
        if IsControlKeyDown() then
            self:DressUpAppearanceSet(data.transmogSetID)
            return
        end

        local setID = data.transmogSetID
        local GetBaseSetID = C_TransmogSets.GetBaseSetID
        local baseID = GetBaseSetID and GetBaseSetID(setID) or setID
        local guideData = {
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 5 },
                { waitForFrame = "WardrobeCollectionFrame", wardrobeSetsTab = true },
                { waitForFrame = "WardrobeCollectionFrame", transmogSetID = baseID },
            },
        }
        if baseID ~= setID then
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantDropdown = true }
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantSetID = setID }
        end
        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Mount: summon/dismiss (secure macro handles cancelform on click)
    if data.mountID then
        if C_MountJournal and C_MountJournal.SummonByID then
            C_MountJournal.SummonByID(data.mountID)
        end
        return
    end

    -- Heirloom: create the item in the player's bags. Mirrors clicking
    -- a tile in the HeirloomsJournal: API hands you a fresh copy.
    if data.heirloomItemID then
        if C_Heirloom and C_Heirloom.CreateHeirloom then
            C_Heirloom.CreateHeirloom(data.heirloomItemID)
        end
        return
    end

    -- Title: set as current. SetCurrentTitle is unprotected and updates
    -- the player's nameplate immediately, no journal navigation needed.
    if data.titleID then
        if SetCurrentTitle then SetCurrentTitle(data.titleID) end
        return
    end

    -- Gear set: equip via Equipment Manager. Skipped in combat — the
    -- API silently fails there, so no point trying.
    if data.gearSetID then
        if InCombatLockdown() then return end
        if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
            C_EquipmentSet.UseEquipmentSet(data.gearSetID)
        end
        return
    end

    -- Toy: usable toys fire via the SecureActionButton type=toy attribute
    -- (set on the row when rendered). Unusable toys (faction-restricted,
    -- etc.) fall through here -- route them to the ToyBox so the player
    -- can at least see the toy in their collection. Mirrors how unusable
    -- abilities navigate to the spellbook instead of attempting a cast.
    if data.toyItemID then
        if data.isToyboxOnly then
            self:OpenToyInToyBox(data)
        end
        return
    end

    -- Talents: open Talents tab and highlight the matching node. Routed
    -- here (before the generic spellID branch) because talents share the
    -- spellID field with abilities but should never cast.
    if data.category == "Talent" and data.talentNodeID then
        self:OpenTalentInTalentsTab(data)
        return
    end

    if data.spellID then
        if forceGuide or IsSpellbookOnlyAbility(data) then
            self:OpenAbilityInSpellbook(data)
        end
        return
    end

    -- Pet: summon/dismiss. Stored petID can go stale (released, caged,
    -- traded) -- look up a fresh owned GUID by speciesID first, fall
    -- back to the cached petID only as a last resort.
    if data.petID or data.speciesID then
        if C_PetJournal then
            local guid = data.petID
            if data.speciesID and C_PetJournal.FindPetIDByName then
                -- Walk the journal to find any owned pet of this species.
                if C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
                    local total = C_PetJournal.GetNumPets()
                    for i = 1, total or 0 do
                        local pid, sid, owned = C_PetJournal.GetPetInfoByIndex(i)
                        if owned and sid == data.speciesID then
                            guid = pid
                            break
                        end
                    end
                end
            end
            if guid and C_PetJournal.SummonPetByGUID then
                C_PetJournal.SummonPetByGUID(guid)
                if guid ~= data.petID then data.petID = guid end
            end
        end
        return
    end

    -- Map search result: open world map and search
    if data.mapSearchResult then
        if ns.MapSearch and ns.MapSearch.HandleUISearchClick then
            ns.MapSearch:HandleUISearchClick(data, forceGuide)
        end
        return
    end

    -- Bag item: usable items (consumables, equippables) fire /use via the
    -- SecureActionButton on click — no bag UI needed. Non-usable items
    -- open the bag(s) containing them and highlight the slot.
    if data.itemID and data.category == "Bag" then
        if useFast then
            -- Skip bag-open for anything the secure click will already act
            -- on: explicit Use spells, equippable gear, AND broad item
            -- types that "use" via right-click without a Use:tooltip line
            -- (Consumable / Container / Quest). Without the type fallback,
            -- right-click-openable containers like lockboxes still hit
            -- the bag-open path, so the bag visibly pops AND the
            -- container opens -- the user only wants the latter.
            local hasUseEffect = (C_Item and C_Item.GetItemSpell and C_Item.GetItemSpell(data.itemID))
                or (GetItemSpell and GetItemSpell(data.itemID))
            local isEquippable = IsEquippableItem and IsEquippableItem(data.itemID)
            local itemType
            if not hasUseEffect and not isEquippable and GetItemInfo then
                itemType = select(6, GetItemInfo(data.itemID))
            end
            if hasUseEffect or isEquippable
               or itemType == "Consumable" or itemType == "Container"
               or itemType == "Quest" then
                return
            end
            local openBag = (C_Container and C_Container.OpenBag) or OpenBag
            if openBag and data.bagLocations then
                local seen = {}
                for _, loc in ipairs(data.bagLocations) do
                    if not seen[loc.bag] then
                        seen[loc.bag] = true
                        pcall(openBag, loc.bag)
                    end
                end
            elseif openBag then
                pcall(openBag, data.bagID)
            end
            if data.steps and #data.steps >= 2 and ns.Highlight and ns.Highlight.StartGuideAtStep then
                ns.Highlight:StartGuideAtStep(data, 2)
            end
            return
        end
        if not data.steps or #data.steps == 0 then return end
    end

    -- Macro: default click runs the macro (handled by the row's secure
    -- macro attribute). Ctrl+click opens MacroFrame for editing —
    -- PreClick clears the secure type when Ctrl is held so the macro
    -- doesn't also fire. Right-click → Guide opens MacroFrame as a
    -- guide via forceGuide=true.
    if data.macroIndex then
        if useFast then
            if IsControlKeyDown() then
                UI:OpenMacroFrameAt(data.macroIndex, data.macroIsChar)
            end
            return
        end
        if data.steps then EasyFind:StartGuide(data) end
        return
    end

    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end

    if useFast and data.steps then
        -- Portrait menu can't be automated (secure frame restriction)
        local mustGuide = false
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                mustGuide = true
                break
            end
        end

        if mustGuide then
            EasyFind:StartGuide(data)
        else
            self:DirectOpen(data)
        end
    elseif data.steps then
        -- Step-by-step guide mode
        EasyFind:StartGuide(data)
    end
end

local EncounterDataMatches
EncounterDataMatches = function(value, targetID, targetName)
    if not value then return false end
    if targetID and (value.encounterID == targetID or value.journalEncounterID == targetID or value.id == targetID) then
        return true
    end
    local name = value.name or value.title or value.text
    if targetName and name and slower(name) == targetName then return true end
    local nested = value.data or value.elementData
    if nested and nested ~= value then
        return EncounterDataMatches(nested, targetID, targetName)
    end
    return false
end

local function GetEJBossesScrollBox()
    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
    return infoFrame and infoFrame.BossesScrollBox
end

local function EncounterFrameMatches(btn, targetID, targetName)
    local edata = btn.GetElementData and btn:GetElementData()
    if EncounterDataMatches(edata, targetID, targetName) then return true end
    if targetID and (btn.encounterID == targetID or btn.journalEncounterID == targetID or btn.id == targetID) then
        return true
    end
    local text = GetButtonText(btn)
    return targetName and text and slower(text) == targetName
end

local function RevealEJEncounter(step)
    local targetID = step.ejEncounterID
    local targetName = step.ejBoss and slower(step.ejBoss)
    local function reveal()
        local scrollBox = GetEJBossesScrollBox()
        if not scrollBox then return end
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return EncounterDataMatches(edata, targetID, targetName)
        end)
        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
            return EncounterFrameMatches(btn, targetID, targetName)
        end)
        if bossBtn and bossBtn.GetElementData and scrollBox.ScrollToElementData then
            local edata = bossBtn:GetElementData()
            if edata then
                scrollBox:ScrollToElementData(edata, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
            end
        end
    end
    reveal()
    if C_Timer and C_Timer.After then C_Timer.After(0.05, reveal) end
end

-- Direct open mode - programmatically navigates to the target as far as possible.
-- Executes ALL steps that represent clickable navigation (tabs, categories, buttons).
-- Only falls back to highlighting when the final step is a non-navigable UI region
-- that the user needs to visually locate (e.g. PvP Talents tray, War Mode button).
function UI:DirectOpen(data)
    if not data or not data.steps or #data.steps == 0 then return end

    local steps = data.steps
    local totalSteps = #steps
    local Highlight = ns.Highlight

    -- For reputation steps, pre-expand all needed headers via API.
    local needsReputationResync = false
    for _, step in ipairs(steps) do
        if step.factionHeader then
            needsReputationResync = true
            if C_Reputation and C_Reputation.GetNumFactions then
                local headerNameLower = slower(step.factionHeader)
                local numFactions = C_Reputation.GetNumFactions()
                for i = 1, numFactions do
                    local factionData = C_Reputation.GetFactionDataByIndex(i)
                    if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
                        local isCollapsed = false
                        if factionData.isHeaderExpanded ~= nil then
                            isCollapsed = not factionData.isHeaderExpanded
                        elseif factionData.isCollapsed ~= nil then
                            isCollapsed = factionData.isCollapsed
                        end
                        if isCollapsed then
                            C_Reputation.ExpandFactionHeader(i)
                        end
                        break
                    end
                end
            end
        end
    end

    -- For currency steps, pre-expand all needed headers via API (synchronous
    -- data update) and track that we need a TokenFrame resync after the tab opens.
    local needsCurrencyResync = false
    for _, step in ipairs(steps) do
        if step.currencyHeader then
            needsCurrencyResync = true
            local headerNameLower = slower(step.currencyHeader)
            if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
                local size = C_CurrencyInfo.GetCurrencyListSize()
                for i = 1, size do
                    local info = C_CurrencyInfo.GetCurrencyListInfo(i)
                    if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
                        if not info.isHeaderExpanded then
                            C_CurrencyInfo.ExpandCurrencyList(i, true)
                        end
                        break
                    end
                end
            end
        end
    end

    -- Determine whether a step is "navigable" (can be auto-executed) vs "highlight-only"
    -- (just points at a UI region the user needs to see).
    -- A step is navigable if it has any clickable action property.
    local function isStepNavigable(step)
        if step.buttonFrame then return true end
        if step.gameMenuText then return true end
        if step.tabIndex then return true end
        if step.sideTabIndex then return true end
        if step.pvpSideTabIndex then return true end
        if step.sidebarButtonFrame or step.sidebarIndex then return true end
        if step.statisticsCategory then return true end
        if step.achievementCategory then return true end
        if step.currencyHeader then return true end
        if step.currencyID then return true end
        if step.factionHeader then return true end
        if step.factionID then return true end
        if step.searchButtonText then return true end
        if step.portraitMenuOption then return true end
        if step.ejInstance then return true end
        if step.ejBoss then return true end
        if step.ejLootTab then return true end
        if step.wardrobeSetsTab then return true end
        if step.transmogSetID then return true end
        if step.transmogVariantDropdown then return true end
        if step.transmogVariantSetID then return true end
        -- regionFrames alone (no searchButtonText) = highlight-only (e.g. PvP Talents)
        -- waitForFrame alone = just waiting for a frame to appear, not navigable
        -- text alone = instruction text, not navigable
        return false
    end

    local lastStep = steps[totalSteps]
    local finalStepNavigable = isStepNavigable(lastStep)

    -- Queue entries (canQueue): navigate to the panel but highlight the final step
    -- instead of clicking it. Auto-clicking taints the frame, blocking protected
    -- queue actions (JoinBattlefield, etc.) when the user clicks them afterward.
    -- TODO: investigate ForceInsecureReset() as alternative
    if data.canQueue and finalStepNavigable then
        finalStepNavigable = false
    end

    -- How many steps to execute programmatically:
    -- If final step is navigable, execute ALL steps (no highlight needed).
    -- If final step is highlight-only, execute all but the last, then highlight it.
    local executeCount = finalStepNavigable and totalSteps or (totalSteps - 1)

    -- If there's nothing to execute programmatically (single highlight-only step),
    -- just start the normal guide.
    if executeCount == 0 then
        EasyFind:StartGuide(data)
        return
    end

    -- Execute all navigable steps synchronously in one frame. WoW frame
    -- operations (ClickButton, tab selection) process immediately, so
    -- child frames are available right after their parent is shown.
    -- The only exception is currency/reputation tab resync, which toggles
    -- tabs and needs one frame for the ScrollBox to rebuild.
    local function executeFrom(start)
        for i = start, executeCount do
            local step = steps[i]

            if step.loadTransmog then
                if not TransmogFrame then
                    Transmog_LoadUI()
                end
                if TransmogFrame then
                    ShowUIPanel(TransmogFrame)
                    UI:ApplyTransmogBrowseMode()
                end
                return
            end

            -- Game Menu button by text: open the menu (if not already)
            -- and click the labeled child. Handles unnamed dynamic-ID
            -- buttons in modern GameMenuFrame.
            if step.gameMenuText then
                if not GameMenuFrame:IsShown() then
                    pcall(GameMenuFrame.Show, GameMenuFrame)
                end
                local btn = Highlight:FindGameMenuButton(step.gameMenuText)
                if btn then ClickButton(btn) end
            end

            if step.buttonFrame then
                -- EncounterJournal: set selectedTab BEFORE opening so Blizzard's
                -- own init calls SetTab with our value (clean call stack, no taint)
                if step.buttonFrame == "EJMicroButton" then
                    local nextStep = steps[i + 1]
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.tabIndex then
                        EncounterJournal_LoadUI()
                        EncounterJournal.selectedTab = nextStep.tabIndex
                        ShowUIPanel(EncounterJournal)
                        -- Skip the tab step, continue from the step after it.
                        -- Defer one frame so the ScrollBox populates its items.
                        local resume = i + 2
                        C_Timer.After(0, function() executeFrom(resume) end)
                        return
                    end
                    -- Boss navigation: set tier + dungeon/raid tab before showing
                    -- so the InstanceSelect ScrollBox populates with the right
                    -- tier's instances on first paint. ShowUIPanel is a no-op
                    -- when EJ is already shown (OnShow / SetTab won't refire),
                    -- so we still need an explicit tab click to apply the new
                    -- tier when the user re-opens onto a different expansion.
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.ejTier then
                        EncounterJournal_LoadUI()
                        if EJ_SelectTier then EJ_SelectTier(nextStep.ejTier) end
                        local tabIdx = nextStep.ejTabIsRaid and 5 or 4
                        EncounterJournal.selectedTab = tabIdx
                        ShowUIPanel(EncounterJournal)
                        local tabBtn = Highlight:GetTabButton("EncounterJournal", tabIdx)
                        if tabBtn then ClickButton(tabBtn) end
                        local resume = i + 2
                        C_Timer.After(0, function() executeFrom(resume) end)
                        return
                    end
                end
                local stepFrame = Utils.GetFrameByPath(step.buttonFrame) or _G[step.buttonFrame]
                if stepFrame then ClickButton(stepFrame) end
            end

            if step.waitForFrame and step.tabIndex then

                local resync = false
                if step.waitForFrame == "CharacterFrame" then
                    if needsCurrencyResync and step.tabIndex == 3 then
                        resync = true
                        needsCurrencyResync = false
                    elseif needsReputationResync and step.tabIndex == 2 then
                        resync = true
                        needsReputationResync = false
                    end
                end
                if resync then
                    -- Toggle tabs to force ScrollBox rebuild with expanded headers.
                    -- Needs one frame to propagate; defer remaining steps.
                    ClickButton(Highlight:GetTabButton("CharacterFrame", 1))
                    local waitFrame = step.waitForFrame
                    local tabIdx = step.tabIndex
                    local resume = i + 1
                    C_Timer.After(0.05, function()
                        ClickButton(Highlight:GetTabButton(waitFrame, tabIdx))
                        executeFrom(resume)
                    end)
                    return
                elseif step.waitForFrame ~= "EncounterJournal" then
                    ClickButton(Highlight:GetTabButton(step.waitForFrame, step.tabIndex))
                end
            end

            if step.sideTabIndex then
                ClickButton(Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex))
            end

            if step.pvpSideTabIndex then
                ClickButton(Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex))
            end

            if step.sidebarButtonFrame or step.sidebarIndex then
                self:ClickCharacterSidebar(step.sidebarIndex)
            end

            local categoryToClick = step.statisticsCategory or step.achievementCategory
            if categoryToClick then
                self:ClickAchievementCategory(categoryToClick)
            end

            if step.achievementID then
                self:OpenAchievementByID(step.achievementID)
            end

            -- EJ tier + dungeon/raid tab (boss navigation when EJ is already
            -- open). The EJMicroButton fast path handles the cold-open case;
            -- this branch handles re-opens on a different tier.
            if step.waitForFrame == "EncounterJournal" and step.ejTier then
                if EJ_SelectTier then EJ_SelectTier(step.ejTier) end
                local tabIdx = step.ejTabIsRaid and 5 or 4
                EncounterJournal.selectedTab = tabIdx
                local tabBtn = Highlight:GetTabButton("EncounterJournal", tabIdx)
                if tabBtn then ClickButton(tabBtn) end
                -- Defer remaining steps so the InstanceSelect ScrollBox can
                -- rebuild with the new tier's instances before we look up
                -- the target instance by name.
                local resume = i + 1
                C_Timer.After(0, function() executeFrom(resume) end)
                return
            end

            -- EJ instance: prefer the EncounterJournal_DisplayInstance API
            -- (synchronous, no ScrollBox race) when we have the instanceID,
            -- otherwise fall back to scanning visible buttons by name.
            if step.ejInstance then
                local displayInstance = _G["EncounterJournal_DisplayInstance"]
                if step.ejInstanceID and displayInstance then
                    pcall(displayInstance, step.ejInstanceID)
                else
                    local scrollBox = _G["EncounterJournalInstanceSelect"] and _G["EncounterJournalInstanceSelect"].ScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejInstance)
                        local instBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local text = Utils.GetButtonText(btn)
                            return text and slower(text) == targetName
                        end)
                        if instBtn then ClickButton(instBtn) end
                    end
                end
                -- Display rebuilds the BossesScrollBox dataprovider, but
                -- buttons / overview content aren't laid out until next
                -- frame. Defer so the ejBoss/ejLootTab step that follows
                -- scans a populated list.
                local nextStep = steps[i + 1]
                if nextStep and (nextStep.ejBoss or nextStep.ejLootTab) then
                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ boss: prefer EncounterJournal_DisplayEncounter API when we
            -- have the encounterID. Falls back to ScrollBox button scan.
            if step.ejBoss then
                local displayEncounter = _G["EncounterJournal_DisplayEncounter"]
                if step.ejEncounterID and displayEncounter then
                    pcall(displayEncounter, step.ejEncounterID)
                    RevealEJEncounter(step)
                else
                    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                    local scrollBox = infoFrame and infoFrame.BossesScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejBoss)
                        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
                            return EncounterDataMatches(edata, step.ejEncounterID, targetName)
                        end)
                        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            return EncounterFrameMatches(btn, step.ejEncounterID, targetName)
                        end)
                        if bossBtn then ClickButton(bossBtn) end
                    end
                    RevealEJEncounter(step)
                end
                -- ejLootTab needs a frame for the boss content to settle
                -- before we click the loot tab (otherwise Overview eats
                -- the click and the loot list never appears).
                local nextStep = steps[i + 1]
                if nextStep and nextStep.ejLootTab then
                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ loot tab: click
            if step.ejLootTab then
                if step.ejDifficultyID and ns.Database then
                    ns.Database:SetEJDifficulty(step.ejDifficultyID)
                end
                local lootTab = _G["EncounterJournalEncounterFrameInfoLootTab"]
                if lootTab then ClickButton(lootTab) end
            end

            -- EJ loot item: highlight only (last step)
            if step.ejLootItem and i == executeCount then
                local Highlight = ns.Highlight
                local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                local scrollBox = infoFrame and (
                    (infoFrame.LootContainer and infoFrame.LootContainer.ScrollBox)
                    or infoFrame.LootScrollBox or infoFrame.ScrollBox
                )
                if scrollBox then
                    local targetID = step.ejLootItem
                    local itemName = step.ejLootItemName
                    C_Timer.After(0.05, function()
                        local itemBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local edata = btn.GetElementData and btn:GetElementData()
                            if edata and edata.itemID == targetID then return true end
                            if itemName then
                                local text = Utils.GetButtonText(btn)
                                if text then
                                    local clean = slower(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                                    if clean == slower(itemName) then return true end
                                end
                            end
                            return false
                        end)
                        if itemBtn and Highlight then
                            Highlight:HighlightFrame(itemBtn)
                            local checkHover
                            checkHover = function()
                                if itemBtn:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    C_Timer.After(0.1, checkHover)
                                end
                            end
                            C_Timer.After(0.3, checkHover)
                        end
                    end)
                end
            end

            -- Wardrobe Sets tab: click the Sets tab within WardrobeCollectionFrame.
            -- Defer remaining steps so the SetsCollectionFrame ScrollBox populates.
            if step.wardrobeSetsTab then
                local wcf = _G["WardrobeCollectionFrame"]
                local setsTab = Highlight:GetTabButton("WardrobeCollectionFrame", 2)
                if setsTab then
                    ClickButton(setsTab)
                end
                if wcf then
                    local scf = wcf.SetsCollectionFrame
                    if not scf or not scf:IsShown() then
                        if wcf.SetTab then
                            pcall(wcf.SetTab, wcf, 2)
                        elseif PanelTemplates_SetTab then
                            pcall(PanelTemplates_SetTab, wcf, 2)
                        end
                    end
                end
                if i < executeCount then
                    local resume = i + 1
                    C_Timer.After(0.1, function() executeFrom(resume) end)
                    return
                end
            end

            -- Transmog set: scroll via SetScrollPercentage + select
            if step.transmogSetID and i == executeCount then
                local scf = _G["WardrobeCollectionFrame"]
                    and _G["WardrobeCollectionFrame"].SetsCollectionFrame
                if scf then
                    C_Timer.After(0.1, function()
                        local lc = scf.ListContainer
                        local scrollBox = lc and lc.ScrollBox
                        if scrollBox and scrollBox.SetScrollPercentage then
                            local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
                            if dp then
                                local finder = dp.FindElementDataByPredicate or dp.FindByPredicate
                                local found = finder and finder(dp, function(ed)
                                    return ed and ed.setID == step.transmogSetID
                                end)
                                if found then
                                    local idx = dp.FindIndex and dp:FindIndex(found)
                                    local total = dp.GetSize and dp:GetSize()
                                    if idx and total and total > 1 then
                                        scrollBox:SetScrollPercentage((idx - 1) / (total - 1))
                                    end
                                end
                            end
                        end
                        if lc and lc.SelectElementDataMatchingSetID then
                            pcall(lc.SelectElementDataMatchingSetID, lc, step.transmogSetID)
                        end
                    end)
                end
            end

            -- Currency/faction headers pre-expanded via API, nothing to execute

            if step.currencyID then
                Highlight:ScrollToCurrencyRow(step.currencyID)
                if i == executeCount then
                    -- ScrollBox needs one frame to update after scroll; defer highlight
                    local cID = step.currencyID
                    C_Timer.After(0.05, function()
                        local currencyRow = Highlight:GetCurrencyRowButton(cID)
                        if currencyRow then
                            Highlight:HighlightFrame(currencyRow, nil)
                            local checkHover
                            checkHover = function()
                                if currencyRow:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    C_Timer.After(0.1, checkHover)
                                end
                            end
                            C_Timer.After(0.3, checkHover)
                        end
                    end)
                end
            end

            if step.factionID then
                Highlight:ScrollToFactionRow(step.factionID)
                if i == executeCount then
                    local fID = step.factionID
                    C_Timer.After(0.05, function()
                        local factionRow = Highlight:GetFactionRowButton(fID)
                        if factionRow then
                            Highlight:HighlightFrame(factionRow, nil)
                            local checkHover
                            checkHover = function()
                                if factionRow:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    C_Timer.After(0.1, checkHover)
                                end
                            end
                            C_Timer.After(0.3, checkHover)
                        end
                    end)
                end
            end

            if step.searchButtonText then
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    ClickButton(SearchFrameTreeFuzzy(parentFrame, slower(step.searchButtonText)))
                end
            end
        end

        -- Hand off remaining steps to the guided highlight. DirectOpen
        -- is left-click "open + show me where" — not the right-click
        -- guided walkthrough, so flag the data so the highlight ticker
        -- cancels (instead of rewinding to step 1 and reopening) if the
        -- user closes the parent window with the highlight still active.
        if not finalStepNavigable and Highlight then
            data.noCourseCorrect = true
            Highlight:StartGuideAtStep(data, executeCount + 1)
        end
    end

    executeFrom(1)
end

-- Helper function to click Character Frame sidebar buttons
function UI:ClickCharacterSidebar(sidebarIndex)
    -- The sidebar buttons are PaperDollSidebarTab1/2/3 inside PaperDollSidebarTabs
    -- (confirmed via Frame Inspector)

    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end

    -- Switch to the Character tab (tab 1) first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(CharacterFrame) ~= 1 then
        ClickButton(_G["CharacterFrameTab1"])
    end

    -- Method 1: Try PaperDollSidebarTab buttons directly (Frame Inspector confirmed names)
    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab then
        if sidebarTab:IsShown() then
            return ClickButton(sidebarTab)
        else
            -- Tab exists but isn't shown yet - try after a brief delay
            C_Timer.After(0.2, function()
                if sidebarTab:IsShown() then ClickButton(sidebarTab) end
            end)
            return true
        end
    end

    -- Method 2: Search PaperDollSidebarTabs container children by index
    local sidebarTabs = _G["PaperDollSidebarTabs"]
    if not sidebarTabs and PaperDollFrame then
        sidebarTabs = PaperDollFrame.SidebarTabs
    end
    if sidebarTabs then
        local nTabs = select("#", sidebarTabs:GetChildren())
        if sidebarIndex <= nTabs then
            return ClickButton(select(sidebarIndex, sidebarTabs:GetChildren()))
        end
    end

    -- Method 3: Try the ToggleSidebarTab function if available
    if PaperDollFrame and PaperDollFrame.ToggleSidebarTab then
        PaperDollFrame:ToggleSidebarTab(sidebarIndex)
        return true
    end

    return false
end

-- Helper function to click an achievement or statistics category button
function UI:ClickAchievementCategory(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end

    local categoryNameLower = slower(categoryName)

    -- Primary: use the data provider to find the category and select it via Blizzard API
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if dataProvider then
            local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
            if finder then
                local elementData = finder(dataProvider, function(data)
                    if not data then return false end
                    local catID = data.id
                    if not catID or type(catID) ~= "number" then return false end
                    if GetCategoryInfo then
                        local title = GetCategoryInfo(catID)
                        if title and slower(title) == categoryNameLower then return true end
                    end
                    return false
                end)
                if elementData then
                    -- Expand parent if hidden
                    if elementData.hidden and elementData.id and AchievementFrameCategories_ExpandToCategory then
                        AchievementFrameCategories_ExpandToCategory(elementData.id)
                        if AchievementFrameCategories_UpdateDataProvider then
                            AchievementFrameCategories_UpdateDataProvider()
                        end
                        -- Re-find after expanding
                        elementData = finder(dataProvider, function(data)
                            if not data then return false end
                            local catID = data.id
                            if not catID or type(catID) ~= "number" then return false end
                            if GetCategoryInfo then
                                local title = GetCategoryInfo(catID)
                                if title and slower(title) == categoryNameLower then return true end
                            end
                            return false
                        end)
                        if not elementData then return false end
                    end
                    -- Try Blizzard's official selection function
                    if AchievementFrameCategories_SelectElementData then
                        AchievementFrameCategories_SelectElementData(elementData)
                        return true
                    end
                    -- Fallback: scroll to it and click the visible button
                    scrollBox:ScrollToElementData(elementData)
                    local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
                    if frame and ClickButton(frame) then return true end
                end
            end
        end

    end

    return false
end

-- Achievement watch/tracking. Modern WoW (Midnight) routes achievement
-- tracking through C_ContentTracking with Enum.ContentTrackingType
-- .Achievement. Older clients exposed top-level
-- IsTrackedAchievement / AddTrackedAchievement /
-- RemoveTrackedAchievement. We try the modern API first then fall back.
local function GetAchievementContentType()
    if Enum and Enum.ContentTrackingType
       and Enum.ContentTrackingType.Achievement ~= nil then
        return Enum.ContentTrackingType.Achievement
    end
    return nil
end

function UI:IsAchievementTracked(achievementID)
    if not achievementID then return false end
    local ct = GetAchievementContentType()
    if ct ~= nil and C_ContentTracking and C_ContentTracking.IsTracking then
        local ok, tracked = pcall(C_ContentTracking.IsTracking, ct, achievementID)
        if ok then return tracked and true or false end
    end
    local fn = _G["IsTrackedAchievement"]
    if fn then
        local ok, tracked = pcall(fn, achievementID)
        if ok then return tracked and true or false end
    end
    return false
end

function UI:ToggleAchievementTracked(achievementID)
    if not achievementID then return end
    local tracked = self:IsAchievementTracked(achievementID)
    local ct = GetAchievementContentType()
    if ct ~= nil and C_ContentTracking and C_ContentTracking.StartTracking then
        if tracked then
            -- StopTracking REQUIRES a third arg (Enum.ContentTrackingStopType);
            -- omitting it causes the call to silently no-op. .User is the
            -- "user clicked to stop tracking" reason.
            local stopType = (Enum and Enum.ContentTrackingStopType
                              and Enum.ContentTrackingStopType.User) or 0
            pcall(C_ContentTracking.StopTracking, ct, achievementID, stopType)
        else
            pcall(C_ContentTracking.StartTracking, ct, achievementID)
        end
        return
    end
    if tracked then
        local stop = _G["RemoveTrackedAchievement"]
        if stop then pcall(stop, achievementID) end
    else
        local start = _G["AddTrackedAchievement"]
        if start then pcall(start, achievementID) end
    end
end

-- Pet (battle pet) right-click actions. petID here is a Blizzard pet
-- GUID string returned by GetPetInfoByIndex / similar, NOT a numeric
-- speciesID. All wrappers no-op gracefully when the pet APIs aren't
-- available.
function UI:SummonPet(petID)
    if petID and C_PetJournal and C_PetJournal.SummonPetByGUID then
        pcall(C_PetJournal.SummonPetByGUID, petID)
    end
end

function UI:IsPetFavorite(petID)
    if not petID or not C_PetJournal then return false end
    if C_PetJournal.GetPetInfoByPetID then
        local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, isFav = pcall(C_PetJournal.GetPetInfoByPetID, petID)
        if ok and isFav then return true end
    end
    return false
end

function UI:TogglePetFavorite(petID)
    if not petID or not C_PetJournal or not C_PetJournal.SetFavorite then return end
    local fav = self:IsPetFavorite(petID)
    pcall(C_PetJournal.SetFavorite, petID, (not fav) and 1 or 0)
end

-- Returns true when the pet is cage-eligible (tradeable). Blizzard's
-- context menu shows "Put In Cage" for these and "Release" for the
-- rest; we mirror that distinction so the user gets the same affordance.
function UI:IsPetCageable(petID)
    if not petID or not C_PetJournal then return false end
    if C_PetJournal.PetIsTradable then
        local ok, val = pcall(C_PetJournal.PetIsTradable, petID)
        if ok then return val and true or false end
    end
    return false
end

function UI:CagePet(petID)
    if not petID or not C_PetJournal or not C_PetJournal.CagePetByID then return end
    pcall(C_PetJournal.CagePetByID, petID)
end

function UI:ReleasePet(petID)
    if not petID or not C_PetJournal or not C_PetJournal.ReleasePetByID then return end
    StaticPopup_Show("EASYFIND_PET_RELEASE_CONFIRM", nil, nil, petID)
end

StaticPopupDialogs["EASYFIND_PET_RELEASE_CONFIRM"] = {
    text = "Are you sure you want to permanently release this pet? This cannot be undone.",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, petID)
        if petID and C_PetJournal and C_PetJournal.ReleasePetByID then
            pcall(C_PetJournal.ReleasePetByID, petID)
        end
    end,
}

function UI:RenamePet(petID)
    if not petID then return end
    StaticPopup_Show("EASYFIND_PET_RENAME", nil, nil, petID)
end

StaticPopupDialogs["EASYFIND_PET_RENAME"] = {
    text = "New name for this pet:",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 16,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    OnShow = function(self, petID)
        local eb = self.editBox or self.EditBox
        if not eb then return end
        local existing = ""
        if petID and C_PetJournal and C_PetJournal.GetPetInfoByPetID then
            local ok, _, customName, _, _, _, _, _, name = pcall(C_PetJournal.GetPetInfoByPetID, petID)
            if ok then existing = customName or name or "" end
        end
        eb:SetText(existing)
        eb:HighlightText()
        eb:SetFocus()
    end,
    OnAccept = function(self, petID)
        local eb = self.editBox or self.EditBox
        local txt = eb and eb:GetText() or ""
        if petID and C_PetJournal and C_PetJournal.SetCustomName then
            pcall(C_PetJournal.SetCustomName, petID, txt)
        end
    end,
}

-- Transmog (appearance) set favorite toggle. The favorite flag lives on
-- the BASE set (not the per-class / per-difficulty variants), so we
-- always resolve to the base ID before reading or writing. Without this
-- step, SetIsFavorite is a silent no-op when called with a variant ID.
local function ResolveTransmogBaseSetID(setID)
    if not setID or not C_TransmogSets then return setID end
    if C_TransmogSets.GetBaseSetID then
        local ok, baseID = pcall(C_TransmogSets.GetBaseSetID, setID)
        if ok and baseID and baseID ~= 0 then return baseID end
    end
    return setID
end

function UI:IsTransmogSetFavorite(setID)
    if not setID or not C_TransmogSets then return false end
    local baseID = ResolveTransmogBaseSetID(setID)
    if C_TransmogSets.GetIsFavorite then
        local ok, fav = pcall(C_TransmogSets.GetIsFavorite, baseID)
        if ok and fav then return true end
    end
    if C_TransmogSets.GetSetInfo then
        local ok, info = pcall(C_TransmogSets.GetSetInfo, baseID)
        if ok and type(info) == "table" and info.favoriteSetID then return true end
        if ok and type(info) == "table" and info.favorite then return true end
    end
    return false
end

function UI:ToggleTransmogSetFavorite(setID)
    if not setID or not C_TransmogSets then return end
    local baseID = ResolveTransmogBaseSetID(setID)
    local fav = self:IsTransmogSetFavorite(baseID)
    if C_TransmogSets.SetIsFavorite then
        pcall(C_TransmogSets.SetIsFavorite, baseID, not fav)
    elseif C_TransmogSets.MarkSetFavorite then
        pcall(C_TransmogSets.MarkSetFavorite, baseID, not fav)
    end
end

-- Backpack-tracker toggle for currencies. Mirrors what the in-game
-- "Show on backpack" checkbox in the Currency tab does.
function UI:IsCurrencyOnBackpack(currencyID)
    if not currencyID or currencyID == 0 or not C_CurrencyInfo then return false end
    -- The enumeration list is authoritative. The CurrencyInfo struct's
    -- `isShowInBackpack` flag in modern builds indicates *capability*
    -- (the currency is allowed to be tracked), not current state — so
    -- using it always read as on, the toggle always tried to add, and
    -- removal silently no-op'd.
    local getInfo = C_CurrencyInfo.GetBackpackCurrencyInfo
    if getInfo then
        local cap = (_G["MAX_WATCHED_TOKENS"]) or 3
        for i = 1, cap do
            local bok, bi = pcall(getInfo, i)
            if not bok or type(bi) ~= "table" then break end
            local id = bi.currencyTypesID or bi.currencyID
            -- Require a non-zero ID match. Some clients return a
            -- placeholder table for unused tracker slots with id=0 /
            -- name="" / nil quantity instead of returning nil; without
            -- this guard, comparing against currencyID still works but
            -- we'd false-positive if the caller ever passed 0 or nil
            -- through (defended above) — keep the explicit check so a
            -- future mistake at a call site can't bite.
            if id and id ~= 0 and id == currencyID then return true end
        end
        return false
    end
    -- Fallback for builds that don't expose the enumeration: trust the
    -- inline flag from GetCurrencyInfo.
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or type(info) ~= "table" then return false end
    return info.isShowInBackpack and true or false
end

-- Force a dropdown's trigger label to re-read its IsSelected callback.
-- Modern WowDropdownMenu builds the displayed selection text inside
-- SetupMenu's generator; calling GenerateMenu rebuilds and re-evaluates.
local function RefreshDropdownLabel(dropdown)
    if not dropdown then return end
    if dropdown.GenerateMenu then pcall(dropdown.GenerateMenu, dropdown)
    elseif dropdown.RefreshMenu then pcall(dropdown.RefreshMenu, dropdown)
    elseif dropdown.SignalUpdate then pcall(dropdown.SignalUpdate, dropdown) end
end

-- Currency filter. API: C_CurrencyInfo.SetCurrencyFilter(filterType).
-- DiscoveredAndAllAccountTransferable = "warband"; DiscoveredOnly = "all".
function UI:ApplyTokenFrameFilter(mode)
    if not mode or not C_CurrencyInfo or not C_CurrencyInfo.SetCurrencyFilter then return end
    if not Enum or not Enum.CurrencyFilterType then return end
    local target = (mode == "warband")
        and Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable
        or  Enum.CurrencyFilterType.DiscoveredOnly
    local current = C_CurrencyInfo.GetCurrencyFilter and C_CurrencyInfo.GetCurrencyFilter()
    if current == target then return end
    -- Mirror Blizzard's SetFilterTypeSelected: clear in-flight selection
    -- so the popup doesn't try to render a row that no longer exists.
    if TokenFrame then
        TokenFrame.selectedToken = nil
        TokenFrame.selectedID = nil
    end
    if TokenFramePopup and TokenFramePopup.Hide then TokenFramePopup:Hide() end
    pcall(C_CurrencyInfo.SetCurrencyFilter, target)
    if TokenFrame and TokenFrame:IsShown() then
        if TokenFrame.Update then pcall(TokenFrame.Update, TokenFrame) end
        RefreshDropdownLabel(TokenFrame.filterDropdown)
    end
end

-- Reputation sort type. API: C_Reputation.SetReputationSortType(sortType).
-- None = "all"; Account = "warband"; Character = "char".
function UI:ApplyReputationFilter(mode)
    if not mode or not C_Reputation or not C_Reputation.SetReputationSortType then return end
    if not Enum or not Enum.ReputationSortType then return end
    local sortType
    if mode == "warband" then
        sortType = Enum.ReputationSortType.Account
    elseif mode == "char" then
        sortType = Enum.ReputationSortType.Character
    else
        sortType = Enum.ReputationSortType.None
    end
    local current = C_Reputation.GetReputationSortType and C_Reputation.GetReputationSortType()
    if current == sortType then return end
    pcall(C_Reputation.SetReputationSortType, sortType)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

-- Show Legacy Reputations. API: C_Reputation.SetLegacyReputationsShown(bool).
function UI:ApplyReputationShowLegacy(show)
    if not C_Reputation or not C_Reputation.SetLegacyReputationsShown then return end
    show = show and true or false
    local current = C_Reputation.AreLegacyReputationsShown and C_Reputation.AreLegacyReputationsShown()
    if current == show then return end
    pcall(C_Reputation.SetLegacyReputationsShown, show)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

-- Hide Passives. CVar-backed: spellBookHidePassives ("0" / "1").
-- Mirrors SpellBookFrameMixin:SetupSettingsDropdown's SetSelected logic.
function UI:ApplySpellBookHidePassives(hide)
    hide = hide and true or false
    if GetCVarBool and GetCVarBool("spellBookHidePassives") == hide then return end
    if SetCVar then pcall(SetCVar, "spellBookHidePassives", hide and "1" or "0") end
    local frame = PlayerSpellsFrame and PlayerSpellsFrame.SpellBookFrame
    if frame and frame:IsShown() and frame.UpdateDisplayedSpells then
        pcall(frame.UpdateDisplayedSpells, frame, true, false)
    end
end

-- Bidirectional sync from Blizzard back to our DB. Hook the same
-- C_*Info setters Blizzard's own dropdowns call so toggling the
-- in-game UI updates our flyout state. The popup syncs from DB on
-- next show, so we don't need to refresh anything live.
function UI:HookBlizzardFilterChanges()
    if C_CurrencyInfo and C_CurrencyInfo.SetCurrencyFilter and Enum and Enum.CurrencyFilterType then
        hooksecurefunc(C_CurrencyInfo, "SetCurrencyFilter", function(filterType)
            local mode = (filterType == Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable)
                and "warband" or "all"
            if EasyFind.db and EasyFind.db.currencyFilterMode ~= mode then
                EasyFind.db.currencyFilterMode = mode
            end
        end)
    end
    if C_Reputation and C_Reputation.SetReputationSortType and Enum and Enum.ReputationSortType then
        hooksecurefunc(C_Reputation, "SetReputationSortType", function(sortType)
            local mode
            if sortType == Enum.ReputationSortType.Account then mode = "warband"
            elseif sortType == Enum.ReputationSortType.Character then mode = "char"
            else mode = "all" end
            if EasyFind.db and EasyFind.db.reputationFilterMode ~= mode then
                EasyFind.db.reputationFilterMode = mode
            end
        end)
    end
    if C_Reputation and C_Reputation.SetLegacyReputationsShown then
        hooksecurefunc(C_Reputation, "SetLegacyReputationsShown", function(show)
            show = show and true or false
            if EasyFind.db and EasyFind.db.showLegacyReputations ~= show then
                EasyFind.db.showLegacyReputations = show
            end
        end)
    end
    -- Hide Passives is CVar-backed; CVAR_UPDATE fires on any change.
    local cvarFrame = CreateFrame("Frame")
    cvarFrame:RegisterEvent("CVAR_UPDATE")
    cvarFrame:SetScript("OnEvent", function(_, _, name, value)
        if not name then return end
        local n = slower(name)
        if n == "spellbookhidepassives" then
            local hide = value == "1" or value == 1 or value == true
            if EasyFind.db and EasyFind.db.abilityHidePassives ~= hide then
                EasyFind.db.abilityHidePassives = hide
            end
        end
    end)
end

function UI:ToggleCurrencyBackpack(currencyID)
    if not currencyID or not C_CurrencyInfo then return end
    local on = self:IsCurrencyOnBackpack(currencyID)
    local target = not on

    -- Backpack tracker caps at 3. When the user tries to ADD a fourth,
    -- raise the same red UIErrorsFrame message Blizzard's default UI
    -- shows instead of silently dropping the call.
    if target and C_CurrencyInfo.GetBackpackCurrencyInfo then
        local cap = (_G["MAX_WATCHED_TOKENS"]) or 3
        local count = 0
        for i = 1, cap + 1 do
            local bok, bi = pcall(C_CurrencyInfo.GetBackpackCurrencyInfo, i)
            if not bok or type(bi) ~= "table" then break end
            count = count + 1
        end
        if count >= cap then
            local msg = (_G["TOKEN_BACKPACK_FULL_MESSAGE"])
                or string.format("You may only watch %d currencies at a time", cap)
            local errFrame = _G["UIErrorsFrame"]
            if errFrame and errFrame.AddMessage then
                errFrame:AddMessage(msg, 1.0, 0.1, 0.1, 1.0)
            end
            return
        end
    end

    -- SetCurrencyBackpackByID takes a currency ID directly. The older
    -- SetCurrencyBackpack takes a *list index* (which is why it
    -- silently no-op'd / hit the wrong currency when called with an
    -- ID). Prefer the by-ID variant when available.
    if C_CurrencyInfo.SetCurrencyBackpackByID then
        pcall(C_CurrencyInfo.SetCurrencyBackpackByID, currencyID, target)
    elseif C_CurrencyInfo.SetCurrencyBackpack then
        pcall(C_CurrencyInfo.SetCurrencyBackpack, currencyID, target)
    end

    -- Force the visible backpack token strip to refresh now. The
    -- SetCurrency* call updates state but doesn't always notify the
    -- ContainerFrame's token row when the bag is already open, so the
    -- user sees stale icons until they close and reopen. Call every
    -- update entry-point we know about; whichever exists in this
    -- client wins, the rest no-op.
    local candidates = {
        _G["BackpackTokenFrame"],
        _G["BackpackTokenFrame_Update"],
    }
    for _, c in ipairs(candidates) do
        if type(c) == "function" then
            pcall(c)
        elseif type(c) == "table" then
            if c.Update then pcall(c.Update, c) end
            if c.UpdateTokens then pcall(c.UpdateTokens, c) end
        end
    end
    -- Container frames host the token row in modern bag UI. Iterate
    -- the standard ContainerFrame1..N looking for an Update method.
    for i = 1, 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf.Update then pcall(cf.Update, cf) end
        local tokenFrame = cf and cf.tokenFrame
        if tokenFrame and tokenFrame.Update then
            pcall(tokenFrame.Update, tokenFrame)
        end
    end
end

function UI:IsCurrencyTransferable(currencyID)
    return ns.Database and ns.Database.IsCurrencyAccountTransferable
       and ns.Database:IsCurrencyAccountTransferable(currencyID) or false
end

-- Open the Currency tab to the given currency, then click the
-- TokenFramePopup's transfer toggle. The first half mirrors what a
-- left-click on the row would do; we then chain a deferred click on
-- the transfer button once the popup is laid out.
function UI:RouteCurrencyTransfer(pinData)
    if not pinData then return end
    self:SelectResult(pinData)
    if not Utils or not Utils.SafeAfter then return end
    local function clickTransfer()
        local btn = _G["TokenFramePopup"] and _G["TokenFramePopup"].CurrencyTransferToggleButton
        if btn and btn:IsShown() and btn.Click then
            btn:Click()
        end
    end
    Utils.SafeAfter(0.1, clickTransfer)
    Utils.SafeAfter(0.25, clickTransfer)
end

-- Open the AchievementFrame to a specific achievement. Tries Blizzard's
-- modern OpenAchievementFrameToAchievement first; falls back to the
-- legacy AchievementFrame_SelectAchievement; finally just shows the
-- frame so the user can find it manually.
function UI:OpenAchievementByID(achievementID)
    if not achievementID then return end
    if _G["AchievementFrame_LoadUI"] then
        pcall(_G["AchievementFrame_LoadUI"])
    end
    local frame = _G["AchievementFrame"]
    if frame and not frame:IsShown() and ShowUIPanel then
        ShowUIPanel(frame)
    end
    local opener = _G["OpenAchievementFrameToAchievement"]
    if opener then
        pcall(opener, achievementID)
        return
    end
    local selector = _G["AchievementFrame_SelectAchievement"]
    if selector then
        pcall(selector, achievementID)
    end
end


-- Helper function to click a side tab (PvE Group Finder tabs)
-- Helper to extract text from various button types
function UI:GetButtonText(frame)
    return GetButtonText(frame)
end

function UI:Focus()
    if not searchFrame or not searchFrame:IsShown() then return end
    if inCombat then return end
    -- Toggle: if already focused, unfocus; otherwise focus
    if searchFrame.editBox:HasFocus() then
        searchFrame.editBox:ClearFocus()
    else
        -- Delay by one frame so the keybind key-press doesn't get typed
        C_Timer.After(0, function()
            if searchFrame and searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function UI:Show(andFocus)
    if not searchFrame then return end
    if inCombat then return end
    searchFrame:Show()
    -- Belt-and-suspenders: OnShow hook also calls this, but if searchFrame
    -- was already shown the hook didn't fire and escCatcher would be left
    -- hidden — leaving ESC without a target when the editbox is unfocused.
    if escCatcher then escCatcher:Show() end
    EasyFind.db.visible = true
    if EasyFind.db.smartShow and not EasyFind.db.autoHide then
        searchFrame.hoverZone:Show()
        searchFrame.smartShowFadeIn()
        C_Timer.After(1.5, function()
            if EasyFind.db.smartShow then
                searchFrame.smartShowFadeOut()
            end
        end)
    end
    if andFocus or EasyFind.db.autoHide then
        C_Timer.After(0, function()
            if searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function UI:Hide()
    if not searchFrame then return end
    if ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end
    -- Close any open filter dropdown / flyouts so they don't linger
    -- on screen after the bar is toggled off via keybind.
    self:CloseFilterDropdownIfOpen()
    searchFrame:Hide()
    if escCatcher then escCatcher:Hide() end
    searchFrame.setSmartShowVisible(false)
    self:HideResults()
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:SetShown(searchFrame.editBox:GetText() == "")
    EasyFind.db.visible = false

    searchFrame.hoverZone:SetShown(EasyFind.db.smartShow)
end

-- Unified ESC handler: collapses every menu state we care about into one
-- decision tree. Called from editBox:OnEscapePressed (focused path) and
-- escCatcher:OnHide (unfocused path) so ESC behaves the same regardless of
-- which frame currently holds keyboard input.
--   Filter dropdown / flyouts open: close them all + refocus editbox.
--   Editbox has text:               clear text + refocus.
--   Otherwise:                      hide the search bar.
function UI:HandleEscape()
    if not searchFrame or not searchFrame:IsShown() then return end
    local editBox = searchFrame.editBox
    local function Refocus()
        if not editBox then return end
        -- Three SetFocus attempts spread across timing windows: synchronous
        -- (works when dropdown:OnHide already ran), next-frame (handles the
        -- normal Hide cascade), and short-deferred (handles editbox state
        -- machine quirks after a Hide chain). Whichever lands first wins;
        -- subsequent SetFocus on an already-focused editbox is a no-op.
        editBox.blockFocus = nil
        editBox:SetFocus()
        C_Timer.After(0, function()
            if not searchFrame or not searchFrame:IsShown() or not editBox then return end
            if editBox:HasFocus() then return end
            editBox.blockFocus = nil
            editBox:SetFocus()
        end)
        C_Timer.After(0.05, function()
            if not searchFrame or not searchFrame:IsShown() or not editBox then return end
            if editBox:HasFocus() then return end
            editBox.blockFocus = nil
            editBox:SetFocus()
        end)
    end
    self._escClosingMenus = true
    local closedAny = self:CloseFilterDropdownIfOpen()
    self._escClosingMenus = nil
    if closedAny then
        Refocus()
        return
    end
    if editBox and editBox:GetText() ~= "" then
        editBox:SetText("")
        if editBox.placeholder then editBox.placeholder:Show() end
        self:HideResults()
        Refocus()
        return
    end
    self:Hide()
end

-- Helper function to expand a currency header by name
function UI:ExpandCurrencyHeader(headerName)
    -- Click the header button - this is what the game actually responds to.
    -- C_CurrencyInfo.ExpandCurrencyList exists but does not reliably trigger
    -- TokenFrame to rebuild its list in Midnight.
    local headerBtn = ns.Highlight and ns.Highlight:GetCurrencyHeaderButton(headerName)
    if headerBtn then
        return ClickButton(headerBtn)
    end
    -- Fallback: try the API directly
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end
    local headerNameLower = slower(headerName)
    local size = C_CurrencyInfo.GetCurrencyListSize()
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
            if not info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, true)
            end
            return true
        end
    end
    return false
end

-- Helper function to expand a faction header by name
function UI:ExpandFactionHeader(headerName)
    if not C_Reputation or not C_Reputation.GetNumFactions then return false end

    local headerNameLower = slower(headerName)
    local numFactions = C_Reputation.GetNumFactions()

    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
            if not factionData.isHeaderExpanded then
                C_Reputation.ExpandFactionHeader(i)
            end
            return true
        end
    end
    return false
end

-- Helper function to open the player portrait right-click menu
function UI:OpenPortraitMenu()
    if not PlayerFrame then return end

    -- Method 1: Modern WoW - PlayerFrame has a dropdown system via PlayerFrameDropDown
    local dropDown = _G["PlayerFrameDropDown"]
    if dropDown then
        if ToggleDropDownMenu then
            ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
            return
        end
    end

    -- Method 2: Try Click() which goes through the WoW frame pipeline
    if PlayerFrame.Click then
        pcall(PlayerFrame.Click, PlayerFrame, "RightButton")
        return
    end

    -- Method 3: Try UnitPopup API
    if UnitPopup_ShowMenu then
        UnitPopup_ShowMenu(PlayerFrame, "SELF", "player")
        return
    end

    -- Method 4: Modern Menu system
    if PlayerFrame.unit and Menu and Menu.ModifyMenu then
        -- Try to invoke the right-click behavior via secure handler
        if PlayerFrame.ToggleMenu then
            PlayerFrame:ToggleMenu()
        end
    end
end

-- Helper function to click a portrait menu option by name
function UI:ClickPortraitMenuOption(optionName)
    local optionNameLower = slower(optionName)

    -- Search through open dropdown frames for the matching button
    -- Modern WoW uses the Menu system
    local function searchFrame(frame, depth)
        if not frame or depth > 5 then return false end

        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            if child and child:IsShown() then
                -- Check for text on this frame
                local text = nil
                if child.GetText then text = child:GetText() end
                if not text then
                    for j = 1, select("#", child:GetRegions()) do
                        local region = select(j, child:GetRegions())
                        if region and region.GetText then
                            local t = region:GetText()
                            if t then text = t; break end
                        end
                    end
                end

                if text and sfind(slower(text), optionNameLower) then
                    if ClickButton(child) then return true end
                end

                if searchFrame(child, depth + 1) then return true end
            end
        end
        return false
    end

    -- Search common dropdown/menu frames
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            if searchFrame(dropdown, 0) then return true end
        end
    end

    -- Also check UIParent children for modern menu frames
    for i = 1, select("#", UIParent:GetChildren()) do
        local child = select(i, UIParent:GetChildren())
        if child and child:IsShown() then
            local strata = child:GetFrameStrata()
            if strata == "FULLSCREEN_DIALOG" or strata == "DIALOG" then
                if searchFrame(child, 0) then return true end
            end
        end
    end

    return false
end

function UI:Toggle()
    if not searchFrame then return end
    if searchFrame:IsShown() and EasyFind.db.visible ~= false then
        self:Hide()
    else
        self:Show(false)
    end
end

function UI:ToggleFocus()
    if not searchFrame then return end
    if inCombat then return end
    if searchFrame:IsShown() then
        self:Hide()
    else
        self:Show(false)
        C_Timer.After(0, function()
            if searchFrame and searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function UI:UpdateScale()
    if searchFrame then
        local scale = EasyFind.db.uiSearchScale or 1.0
        searchFrame:SetScale(scale)
    end
    self:UpdateResultsScale()
end

function UI:UpdateResultsScale()
    if resultsFrame then
        resultsFrame:SetScale(EasyFind.db.uiResultsScale or 1.0)
        self:RefreshResults()
    end
end

function UI:UpdateWidth()
    if searchFrame then
        local w = 250 * (EasyFind.db.uiSearchWidth or 1.0)
        searchFrame:SetWidth(w)
    end
    self:UpdateResultsWidth()
end

function UI:UpdateResultsWidth()
    if resultsFrame then
        local w = EasyFind.db.uiResultsWidth
        if w and w > 1 then
            resultsFrame:SetWidth(w)
        end
    end
end

function UI:RefreshResults()
    if cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        local savedIndex = selectedIndex
        local savedToggle = toggleFocused
        -- Bypass ShowHierarchicalResults' render-skip cache. Setting
        -- toggles, slider writes, and dropdown cycles keep the same
        -- entry.data reference, so the row-by-row layout pass would be
        -- skipped and the on-screen checkbox/value/slider would stay
        -- stale until the result list rebuilt from scratch.
        self._lastRenderSig = nil
        self:ShowHierarchicalResults(cachedHierarchical, true)
        if savedIndex > 0 then
            selectedIndex = savedIndex
            toggleFocused = savedToggle
            self:UpdateSelectionHighlight()
        end
        -- Re-apply the hover action hint. Re-render rewrote pathSubtext
        -- back to GetFlatSubtext, so the row the cursor is still over
        -- would otherwise revert to the unhovered subtext after a click.
        for i = 1, #resultButtons do
            local row = resultButtons[i]
            if row and row:IsShown() and row:IsMouseOver() then
                ApplyActionHint(row)
                break
            end
        end
    end
end

-- Re-run the search pipeline against the current editbox text. Use this when a
-- setting flips the structure of the result list (flat vs hierarchical), since
-- RefreshResults only re-renders the cached list.
function UI:RebuildOpenResults()
    if not searchFrame or not searchFrame.editBox then return end
    if not resultsFrame or not resultsFrame:IsShown() then return end
    local text = searchFrame.editBox:GetText()
    if text and text ~= "" then
        self:OnSearchTextChanged(text)
    else
        self:ShowPinnedItems()
    end
end

function UI:UpdateOpacity()
    if not searchFrame then return end
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    if containerFrame then
        ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
    end
end

function UI:UpdateSearchBarTheme()
    if not searchFrame then return end
    local scale = EasyFind.db.fontSize or 1.0
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    searchFrame:SetBackdrop(nil)
    -- Pill stays hidden; container provides the rounded silhouette.
    ns.SetSearchBorderShown(searchFrame, false)
    if containerFrame then
        ns.SetRoundedRectBorderShown(containerFrame, true)
        ns.SetRoundedRectBarHeight(containerFrame, ns.SEARCHBAR_HEIGHT * scale)
        ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
    end
end

function UI:UpdateSmartShow()
    if not searchFrame then return end
    local enabled = EasyFind.db.smartShow
    if enabled then
        -- Enable smart show: show hover zone, start hidden
        searchFrame.hoverZone:Show()
        if EasyFind.db.visible ~= false and not inCombat then
            -- Start transparent - hover to reveal
            searchFrame:SetAlpha(0)
            searchFrame:Show()
            searchFrame.setSmartShowVisible(false)
        end
    else
        -- Disable smart show: hide hover zone, cancel any pending fade-out
        -- timer (the player may be mid-hover-out when they flip the toggle),
        -- and restore normal opacity.
        searchFrame.hoverZone:Hide()
        if searchFrame.cancelSmartShowTimer then searchFrame.cancelSmartShowTimer() end
        UIFrameFadeRemoveFrame(searchFrame)
        searchFrame.setSmartShowVisible(true)
        if EasyFind.db.visible ~= false and not inCombat then
            local alpha = searchFrame.getEffectiveAlpha and searchFrame.getEffectiveAlpha() or 1.0
            searchFrame:SetAlpha(alpha)
            searchFrame:Show()
        end
    end
end

function UI:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -12)
        EasyFind.db.uiSearchPosition = nil
    end
end

-- WHAT'S NEW POPUP
-- Shown once per version update for returning users.
function UI:ShowWhatsNew(version)
    if _G["EasyFindWhatsNew"] then return end

    local f = CreateFrame("Frame", "EasyFindWhatsNew", UIParent, "BackdropTemplate")
    f:SetSize(470, 265)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Escape to close
    tinsert(UISpecialFrames, "EasyFindWhatsNew")

    -- Close button (X)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cffFFD100EasyFind|r - New Features")

    -- Version subtitle
    local verText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verText:SetPoint("TOP", title, "BOTTOM", 0, -4)
    verText:SetText("|cff999999v" .. (version or "?") .. "|r")

    -- Feature body
    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -58)
    body:SetWidth(f:GetWidth() - 32)
    body:SetJustifyH("LEFT")
    body:SetSpacing(4)
    body:SetText(
        "|cffFFD100\226\128\162|r |cffffffffLoot Search|r\n" ..
        "        Search dungeon and raid loot by name, slot, stats, or source\n" ..
        "        Filter by class, spec, and difficulty\n" ..
        "        Click to navigate directly to the item in the Encounter Journal\n" ..
        "|cffFFD100\226\128\162|r |cffffffffTransmog Outfits|r\n" ..
        "        Saved outfits appear in search results, click to equip\n" ..
        "        Browse the transmog window without a vendor (search \"tmog\")\n" ..
        "\n|cff999999Enable Loot and Outfits in the filter dropdown (arrow button\n" ..
        "inside the search bar) to see these results.|r"
    )

    -- Footer - anchored below body so it can't overlap
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("TOP", body, "BOTTOM", 0, -12)
    footer:SetText("Full changelog on CurseForge and GitHub")

    -- "Got it" button - anchored below footer
    local okBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    okBtn:SetSize(90, 24)
    okBtn:SetPoint("TOP", footer, "BOTTOM", 0, -8)
    okBtn:SetText("Got it")
    okBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    -- Auto-size frame height: 58 top padding + body + 12 gap + footer + 8 gap + button + 16 bottom padding
    f:SetHeight(58 + body:GetStringHeight() + 12 + footer:GetStringHeight() + 8 + okBtn:GetHeight() + 16)
    f:Show()
end

-- OPEN MACRO FRAME AT SLOT
-- Midnight's MacroFrame has no SelectionBehavior; the slot ScrollBox
-- holds buttons whose elementData is a plain integer (slot index within
-- the tab). Scroll the slot into view, then walk visible frames and
-- Click() the one whose elementData matches -- this fires the same
-- internal selection path the user's mouse click would.
function UI:OpenMacroFrameAt(macroIdx, isChar)
    if C_AddOns and C_AddOns.LoadAddOn then
        C_AddOns.LoadAddOn("Blizzard_MacroUI")
    elseif LoadAddOn then
        LoadAddOn("Blizzard_MacroUI")
    end
    if ShowMacroFrame then ShowMacroFrame() end
    local tabIdx = isChar and 2 or 1
    local slotInTab = isChar
        and (macroIdx - (MAX_ACCOUNT_MACROS or 120))
        or macroIdx
    local function clickSlot()
        local mf = MacroFrame
        if not mf or not mf:IsShown() then return false end
        local tabBtn = _G["MacroFrameTab" .. tabIdx]
        if tabBtn and tabBtn.Click and (mf.selectedTab or 1) ~= tabIdx then
            tabBtn:Click()
        end
        local sb = mf.MacroSelector and mf.MacroSelector.ScrollBox
        if not sb or not sb.ForEachFrame then return false end
        if sb.ScrollToElementDataIndex then
            sb:ScrollToElementDataIndex(slotInTab)
        end
        local clicked = false
        sb:ForEachFrame(function(btn)
            if clicked then return true end
            local ed = btn.GetElementData and btn:GetElementData()
            if ed == slotInTab then
                if btn.Click then btn:Click() end
                clicked = true
                return true
            end
        end)
        return clicked
    end
    if not clickSlot() then
        C_Timer.After(0, function()
            if not clickSlot() then
                C_Timer.After(0.1, function()
                    if not clickSlot() then
                        C_Timer.After(0.3, clickSlot)
                    end
                end)
            end
        end)
    end
end

-- FIRST-TIME SETUP OVERLAY
-- Shown once on fresh install to let the user position & scale the search bar
-- and learn about Fast vs Guide mode. Persisted account-wide via
-- EasyFind.db.setupComplete.
function UI:ShowFirstTimeSetup()
    if not searchFrame then return end
    if EasyFind.db.setupComplete then return end

    -- Force search bar visible during setup (override SmartShow / hidden state)
    EasyFind.db.visible = true
    searchFrame:Show()
    searchFrame:SetAlpha(1.0)
    -- Dim just the search bar backdrop (not child frames like the overlay)
    searchFrame:SetBackdropColor(0.2, 0.2, 0.2, 0.4)
    searchFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.4)
    if searchFrame.hoverZone then searchFrame.hoverZone:Hide() end
    searchFrame.setSmartShowVisible(true)

    -- Block editbox interaction during setup
    searchFrame.setupMode = true
    searchFrame.editBox:EnableMouse(false)

    -- Golden glow overlay (port of the v1.5.0 setup glow). 6px outset
    -- from the search bar, pulsing fill, gold border, "Drag to move"
    -- label centered on top.
    local glow = CreateFrame("Frame", "EasyFindSetupGlow", searchFrame, "BackdropTemplate")
    glow:SetPoint("TOPLEFT", searchFrame, "TOPLEFT", -6, 6)
    glow:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", 6, -6)
    glow:SetFrameStrata("DIALOG")
    glow:SetFrameLevel(100)
    glow:EnableMouse(false)  -- clicks pass through to search bar
    glow:SetIgnoreParentAlpha(true)  -- stay opaque when search bar fades

    glow:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    glow:SetBackdropColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.20)
    glow:SetBackdropBorderColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)

    -- Gentle pulse on the gold fill
    local pulseUp = true
    local pulseAlpha = 0.20
    glow:SetScript("OnUpdate", function(self, elapsed)
        if pulseUp then
            pulseAlpha = pulseAlpha + elapsed * 0.12
            if pulseAlpha >= 0.35 then pulseAlpha = 0.35; pulseUp = false end
        else
            pulseAlpha = pulseAlpha - elapsed * 0.12
            if pulseAlpha <= 0.12 then pulseAlpha = 0.12; pulseUp = true end
        end
        self:SetBackdropColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], pulseAlpha)
    end)

    -- Centered label overlaid on the glow (like edit-mode frame labels).
    local setupLabel = glow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setupLabel:SetPoint("CENTER", glow, "CENTER", 0, 0)
    setupLabel:SetText("Drag to move")
    setupLabel:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.9)

    -- Resize handle (bottom-left corner of the search bar). Parents to
    -- searchFrame so it fades in sync when Smart Show hides the bar.
    local resizer = CreateFrame("Button", nil, searchFrame)
    resizer:SetFrameStrata("DIALOG")
    resizer:SetFrameLevel(searchFrame:GetFrameLevel() + 20)
    resizer:SetSize(16, 16)
    resizer:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", 0, 0)
    resizer:EnableMouse(true)

    -- Bright gold grabber: additive blend mode over a solid-gold vertex
    -- color makes the lines read well on any background. The Blizzard
    -- grabber texture is already oriented for bottom-right, so no flip.
    local function styleResizerTex(tex)
        tex:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
        tex:SetBlendMode("ADD")
    end
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    styleResizerTex(resizer:GetNormalTexture())
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    styleResizerTex(resizer:GetHighlightTexture())
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    styleResizerTex(resizer:GetPushedTexture())

    resizer:SetScript("OnEnter", function(self)
        if self.dragging then return end  -- don't show tooltip mid-drag
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    resizer:SetScript("OnLeave", GameTooltip_Hide)

    local function scaleResizerVisual()
        local s = mmax(0.5, mmin(2.0, EasyFind.db.fontSize or 1.0))
        resizer:SetSize(16 * s, 16 * s)
    end

    -- Dragging the bottom-left corner resizes the bar in two axes at once:
    --   horizontal  -> uiSearchWidth (symmetric growth around a locked top-center)
    --   vertical    -> fontSize (which also grows the bar height downward)
    --
    -- Uses OnMouseDown (not RegisterForDrag) so there's no 4-pixel drag
    -- threshold: the bar starts resizing the instant the cursor moves.
    -- Delta-from-start math keeps the cursor locked to wherever on the
    -- resizer the user originally clicked - if they clicked the middle
    -- of the hitbox, the middle of the hitbox follows the cursor.
    resizer.dragging = false
    resizer:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        GameTooltip_Hide()  -- hide the hover tooltip while dragging
        self.dragging = true
        searchFrame.resizing = true

        -- Snapshot the current top-center as a stationary anchor for
        -- symmetric horizontal growth and top-down vertical growth.
        local left, right, top = searchFrame:GetLeft(), searchFrame:GetRight(), searchFrame:GetTop()
        if not (left and right and top) then
            self.dragging = false
            searchFrame.resizing = nil
            return
        end
        self.anchorCenterX = (left + right) / 2
        self.anchorTopY = top
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOP", UIParent, "BOTTOMLEFT", self.anchorCenterX, self.anchorTopY)

        -- Snapshot starting cursor position and starting db values so the
        -- per-frame math can compute deltas absolutely without drift and
        -- without snapping the corner to the cursor at drag start.
        self.startCx, self.startCy = GetCursorPosition()
        self.startWidth = EasyFind.db.uiSearchWidth or 1.0
        self.startFont = EasyFind.db.fontSize or 1.0
    end)

    local function stopResize(self)
        if not self.dragging then return end
        self.dragging = false
        searchFrame.resizing = nil
        self.anchorCenterX = nil
        self.anchorTopY = nil
        self.startCx = nil
        self.startCy = nil
        self.startWidth = nil
        self.startFont = nil

        -- Persist the new TOP-anchored position so the bar sticks after drag.
        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
    end

    resizer:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        stopResize(self)
    end)

    resizer:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        -- If the user released the button outside the hitbox, OnMouseUp
        -- won't fire - bail out when we detect the button is no longer down.
        if not IsMouseButtonDown("LeftButton") then
            stopResize(self)
            return
        end
        if not (self.startCx and self.startCy and self.startWidth and self.startFont) then return end

        local cx, cy = GetCursorPosition()
        local effScale = searchFrame:GetEffectiveScale() or 1.0
        if effScale <= 0 then return end

        -- Delta from the cursor's starting position (in raw screen pixels).
        local dxScreen = cx - self.startCx
        local dyScreen = cy - self.startCy

        -- Bottom-right corner: cursor moving RIGHT should grow the bar
        -- symmetrically, cursor moving DOWN should grow the font/height.
        --   d(uiSearchWidth) =  dxScreen / (effScale * 125)
        --   d(fontSize)      = -dyScreen / (effScale * SEARCHBAR_HEIGHT)
        local newWidth = self.startWidth + dxScreen / (effScale * 125)
        local newFont  = self.startFont  - dyScreen / (effScale * ns.SEARCHBAR_HEIGHT)

        newWidth = mmax(0.5, mmin(2.5, newWidth))
        newFont = mmax(0.5, mmin(2.0, newFont))

        EasyFind.db.uiSearchWidth = newWidth
        EasyFind.db.fontSize = newFont
        UI:UpdateWidth()
        UI:UpdateFontSize()
        scaleResizerVisual()
    end)

    -- Set the initial resizer size to match the current font scale
    scaleResizerVisual()

    -- Fixed panel width — comfortably holds the keybind rows and
    -- two-button bottom strip without wrapping.
    local panelWidth = 290

    -- Instruction panel (anchored below the search bar)
    local panel = CreateFrame("Frame", nil, searchFrame, "BackdropTemplate")
    panel:SetSize(panelWidth, 245)
    panel:SetPoint("TOP", searchFrame, "BOTTOM", 0, -6)
    panel:SetIgnoreParentAlpha(true)  -- survive Smart Show fade
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 14,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    panel:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)

    -- "Setup" header (centered, just under the panel top).
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOP", panel, "TOP", 0, -10)
    header:SetText("Setup")

    -- Horizontal separator immediately under the header.
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("LEFT", panel, "LEFT", 12, 0)
    sep:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
    sep:SetPoint("TOP", header, "BOTTOM", 0, -8)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Smart Show checkbox aligned to the panel's left margin (sep is
    -- already anchored at panel.left + 12 so 0 keeps the checkbox box
    -- flush with the separator without further indentation).
    local smartShowCheckbox = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    smartShowCheckbox:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -6)
    smartShowCheckbox.Text:SetText("|cffFFD100Smart Show|r |cff999999(Recommended)|r")
    smartShowCheckbox:SetChecked(false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        -- Apply live so the player can see the hover behavior immediately,
        -- same as the matching toggle in /ef options. The tutorial panel
        -- has SetIgnoreParentAlpha(true) so it stays visible even when the
        -- search bar fades out.
        EasyFind.db.smartShow = self:GetChecked()
        UI:UpdateSmartShow()
    end)

    -- Smart Show description - uses same font as checkbox text for consistency
    local smartDesc = smartShowCheckbox:CreateFontString(nil, "OVERLAY")
    smartDesc:SetFontObject(smartShowCheckbox.Text:GetFontObject())
    smartDesc:SetPoint("TOPLEFT", smartShowCheckbox.Text, "BOTTOMLEFT", 0, -2)
    smartDesc:SetWidth(panelWidth - 60)
    smartDesc:SetJustifyH("LEFT")
    smartDesc:SetText("|cff999999Bar hides when your mouse moves away and reappears when you hover near it.|r")

    -- Fade While Moving checkbox (default checked - staticOpacity defaults to false, meaning fade IS active)
    local fadeCheckbox = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    fadeCheckbox:SetPoint("TOPLEFT", smartShowCheckbox, "TOPLEFT", 0, -(26 + smartDesc:GetStringHeight() + 8))
    fadeCheckbox.Text:SetText("|cffFFD100Fade While Moving|r")
    fadeCheckbox:SetChecked(true)
    fadeCheckbox:SetScript("OnClick", function(self)
        -- Update live so the user can see the effect immediately
        EasyFind.db.staticOpacity = not self:GetChecked()
    end)

    local fadeDesc = fadeCheckbox:CreateFontString(nil, "OVERLAY")
    fadeDesc:SetFontObject(fadeCheckbox.Text:GetFontObject())
    fadeDesc:SetPoint("TOPLEFT", fadeCheckbox.Text, "BOTTOMLEFT", 0, -2)
    fadeDesc:SetWidth(panelWidth - 60)
    fadeDesc:SetJustifyH("LEFT")
    fadeDesc:SetText("|cff999999Reduces bar opacity while you're moving.|r")

    -- Keybind rows. Each row = [label] [keybind button] [recommended hint].
    -- Click the button to capture a key, right-click to clear, Esc to cancel —
    -- mirrors the keybind UI in /ef Options > Shortcuts.
    local function GetKeybindLabel(action)
        local k1 = GetBindingKey(action)
        return k1 or "Not Bound"
    end

    local function StopKeybindCapture(btn, action)
        btn.waitingForKey = false
        btn:SetText(GetKeybindLabel(action))
        btn:UnlockHighlight()
        Utils.SafeCallMethod(btn, "EnableKeyboard", false)
        btn:SetScript("OnKeyDown", nil)
    end

    -- Two-column symmetric layout. Row 1 = labels, row 2 = buttons.
    -- Each column is centered in half the panel; the label and button
    -- inside a column share an x-center, so the button sits directly
    -- under its label.
    local KEYBIND_BTN_W = 110
    local LEFT_COL_X    = panelWidth / 4   -- center of the left half
    local RIGHT_COL_X   = panelWidth * 3/4 -- center of the right half

    -- Section header for the keybind row, with a thin divider underneath
    -- so it reads as a labeled subsection rather than two loose buttons.
    local keybindHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keybindHeader:SetText("Keybindings")
    keybindHeader:SetPoint("TOP", fadeDesc, "BOTTOM", 0, -14)

    local keybindDivider = panel:CreateTexture(nil, "ARTWORK")
    keybindDivider:SetColorTexture(1, 1, 1, 0.18)
    keybindDivider:SetHeight(1)
    keybindDivider:SetPoint("LEFT", panel, "LEFT", 24, 0)
    keybindDivider:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
    keybindDivider:SetPoint("TOP", keybindHeader, "BOTTOM", 0, -4)

    -- Invisible row anchor: y is locked to the divider so the labels
    -- below sit a fixed gap under it. Width spans the panel so label
    -- x = row.left + colCenterX places each label center on its column.
    -- Using a single-anchor TOP on each label avoids the over-constrained
    -- x that two SetPoints would create.
    local keybindRow = CreateFrame("Frame", nil, panel)
    keybindRow:SetHeight(1)
    keybindRow:SetPoint("LEFT",  panel, "LEFT")
    keybindRow:SetPoint("RIGHT", panel, "RIGHT")
    keybindRow:SetPoint("TOP",   keybindDivider, "BOTTOM", 0, -10)

    local function CreateKeybindLabel(text, colCenterX)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetText(text)
        lbl:SetPoint("TOP", keybindRow, "TOPLEFT", colCenterX, 0)
        return lbl
    end

    local function CreateKeybindButton(label, anchorLabel, action, recommended)
        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        btn:SetSize(KEYBIND_BTN_W, 22)
        btn:SetPoint("TOP", anchorLabel, "BOTTOM", 0, -4)
        btn:SetText(GetKeybindLabel(action))
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then
                local o1, o2 = GetBindingKey(action)
                if o1 then SetBinding(o1) end
                if o2 then SetBinding(o2) end
                SaveBindings(GetCurrentBindingSet())
                self:SetText("Not Bound")
                return
            end
            if self.waitingForKey then
                StopKeybindCapture(self, action)
                return
            end
            self.waitingForKey = true
            self:SetText("Press a key...")
            self:LockHighlight()
            Utils.SafeCallMethod(self, "EnableKeyboard", true)
            self:SetScript("OnKeyDown", function(s, key)
                if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
                   or key == "LALT" or key == "RALT" then return end
                if key == "ESCAPE" then
                    StopKeybindCapture(s, action)
                    return
                end
                -- Reject bare SPACE/ENTER/movement keys -- they're vital
                -- defaults (jump, accept, WASD) and silently overwriting
                -- them on a stray keypress during capture has bricked
                -- spacebar after a /reload more than once. Only bind
                -- these when modified.
                local hasMod = IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()
                if not hasMod and (key == "SPACE" or key == "ENTER"
                    or key == "W" or key == "A" or key == "S" or key == "D") then
                    return
                end
                local combo = ""
                if IsAltKeyDown() then combo = combo .. "ALT-" end
                if IsControlKeyDown() then combo = combo .. "CTRL-" end
                if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
                combo = combo .. key
                local o1, o2 = GetBindingKey(action)
                if o1 then SetBinding(o1) end
                if o2 then SetBinding(o2) end
                SetBinding(combo, action)
                SaveBindings(GetCurrentBindingSet())
                StopKeybindCapture(s, action)
            end)
        end)
        btn:HookScript("OnEnter", function(self)
            AnchorTooltipAtCursor(GameTooltip, self)
            GameTooltip:AddLine("Recommended: " .. recommended, 1, 1, 1, true)
            GameTooltip:AddLine("Click to bind. Right-click to clear.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        btn:HookScript("OnLeave", GameTooltip_Hide)
        return btn
    end

    local toggleLabel = CreateKeybindLabel("Toggle bar", LEFT_COL_X)
    local mapLabel    = CreateKeybindLabel("Open map search", RIGHT_COL_X)
    CreateKeybindButton("toggle", toggleLabel, "EASYFIND_TOGGLE_FOCUS", "Ctrl+Space")
    CreateKeybindButton("map",    mapLabel,    "EASYFIND_MAP_FOCUS",    "Ctrl+M")

    local gotItBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    gotItBtn:SetSize(100, 22)
    gotItBtn:SetPoint("TOP", panel, "BOTTOM", 0, -8)
    gotItBtn:SetText("Got it")

    -- During setup: allow drag without holding Shift
    searchFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    local function FinishSetup()
        EasyFind.db.setupComplete = true

        -- Save current position
        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}

        -- Destroy overlays & restore normal state
        searchFrame.setupMode = nil
        searchFrame.editBox:EnableMouse(true)
        UI:UpdateSearchBarTheme()  -- restore proper backdrop colors
        glow:SetScript("OnUpdate", nil)
        glow:Hide()
        resizer:SetScript("OnUpdate", nil)
        resizer:Hide()
        panel:Hide()

        -- Restore shift-only drag
        searchFrame:SetScript("OnDragStart", function(self)
            if IsShiftKeyDown() then
                self:StartMoving()
            end
        end)

        -- Apply preferences from setup checkboxes
        EasyFind.db.smartShow = smartShowCheckbox:GetChecked()
        EasyFind.db.staticOpacity = not fadeCheckbox:GetChecked()
        UI:UpdateSmartShow()

        -- Record current version so What's New won't fire on next login
        -- (brand-new users don't need to see it - all features are new for them)
        EasyFind.db.lastSeenVersion = ns.version
    end

    gotItBtn:SetScript("OnClick", FinishSetup)

    -- Escape closes the whole tutorial from the positioning panel.
    panel:EnableKeyboard(true)
    panel:SetPropagateKeyboardInput(true)
    panel:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            FinishSetup()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

end

-- Flash a label on the search frame (used for Currency hint)
function UI:FlashLabel(labelText)
    if not searchFrame or not searchFrame.label then return end

    local label = searchFrame.label
    local originalText = label:GetText()
    local originalR, originalG, originalB = label:GetTextColor()

    -- Set to the hint text
    label:SetText(labelText)
    label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])

    -- Create flash animation
    local flashCount = 0
    local ticker
    ticker = C_Timer.NewTicker(0.3, function()
        local ok, _ = pcall(function()
            flashCount = flashCount + 1
            if flashCount % 2 == 0 then
                label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
            else
                label:SetTextColor(1, 1, 1)
            end
            if flashCount >= 6 then
                label:SetText(originalText)
                label:SetTextColor(originalR, originalG, originalB)
                ticker:Cancel()
            end
        end)
        if not ok then
            ticker:Cancel()
        end
    end)
end

function UI:UpdateFontSize()
    local scale = EasyFind.db.fontSize or 1.0

    if not searchFrame then return end

    ScaleFont(searchFrame.editBox, ns.SEARCHBAR_FONT)
    ScaleFont(searchFrame.editBox.placeholder, ns.SEARCHBAR_FONT)

    local barH = ns.SEARCHBAR_HEIGHT * scale
    local contentSz = barH * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE
    searchFrame:SetHeight(barH)
    searchFrame.editBox:SetHeight(contentSz)
    searchFrame.searchIcon:SetSize(iconSz, iconSz)
    if searchFrame.modeBtn then
        searchFrame.modeBtn:SetWidth(barH)
    end
    if searchFrame.filterBtn then
        searchFrame.filterBtn:SetWidth(barH)
    end

    local theme = GetActiveTheme()
    local WHITE8x8 = "Interface\\BUTTONS\\WHITE8x8"
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        if containerFrame then
            ns.SetRoundedRectBarHeight(containerFrame, barH)
            ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
            -- If results are open, the divider stays at the bar's
            -- new bottom (= barH).
            if resultsFrame and resultsFrame:IsShown() then
                ns.SetRoundedRectDivider(containerFrame, barH, true)
            end
        end
    else
        searchFrame:SetBackdrop({
            bgFile = WHITE8x8,
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20 * scale,
            insets = { left = 5 * scale, right = 5 * scale, top = 5 * scale, bottom = 5 * scale }
        })
        searchFrame:SetBackdropColor(0, 0, 0, alpha)
    end

    for i = 1, #resultButtons do
        ApplyResultRowFonts(resultButtons[i], theme)
    end

    -- Re-layout visible results with new row heights
    if cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        self:ShowHierarchicalResults(cachedHierarchical, true)
    end
end
