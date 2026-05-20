local _, ns = ...

local UI = {}
ns.UI = UI

function UI:ApplySearchWindowFill(frame)
    if not frame then return end
    local c = ns.SEARCH_WINDOW_FILL_COLOR or {0.052, 0.052, 0.060}
    ns.SetRoundedRectBorderFillColor(frame, c[1], c[2], c[3], 1)
end

local Utils = ns.Utils
local UIPins = ns.UIPins
local GetButtonText         = Utils.GetButtonText
local ClickButton           = Utils.ClickButton
local select, ipairs = Utils.select, Utils.ipairs
local sfind, slower         = Utils.sfind, Utils.slower
local mmin, mmax = Utils.mmin, Utils.mmax
local mfloor = Utils.mfloor

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local GetCursorPosition  = GetCursorPosition
local InCombatLockdown   = InCombatLockdown

function UI:GetDefaultSearchBarPoint()
    local parentH = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 768
    return "CENTER", "CENTER", 0, parentH / 6
end

function UI:GetSearchBarHeight()
    local h = EasyFind and EasyFind.db and EasyFind.db.uiSearchBarHeight or ns.SEARCHBAR_HEIGHT
    return mmax(24, mmin(56, h or ns.SEARCHBAR_HEIGHT or 30))
end

local CHARACTER_TAB_SUBFRAME = {
    [1] = "PaperDollFrame",
    [2] = "ReputationFrame",
    [3] = "TokenFrame",
}

local function SecureCall(fn, ...)
    if not fn then return false end
    if securecallfunction then
        securecallfunction(fn, ...)
    else
        pcall(fn, ...)
    end
    return true
end

local function SecureShowUIPanel(frame)
    if not frame or not ShowUIPanel then return false end
    return SecureCall(ShowUIPanel, frame)
end

local function IsPlayerSpellsTabSelected(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if not frame then return false end
    if frame.GetTab then
        local currentTab = frame:GetTab()
        if currentTab == tabIndex then return true end
    end
    if tabIndex == 1 and frame.SpecFrame and frame.SpecFrame:IsShown() then
        return true
    elseif tabIndex == 2 and frame.TalentsFrame and frame.TalentsFrame:IsShown() then
        return true
    elseif tabIndex == 2 and ClassTalentFrame and ClassTalentFrame:IsShown() then
        return true
    elseif tabIndex == 3 and frame.SpellBookFrame and frame.SpellBookFrame:IsShown() then
        return true
    end
    return false
end

local function OpenPlayerSpellsFrame(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if frame and frame:IsShown() then
        return true
    end

    -- Opening PlayerSpellsFrame through the microbutton taints Blizzard's
    -- ShowUIPanel/UIParent path. Call Blizzard's opener through
    -- securecallfunction so later protected panel work, including
    -- CharacterFrame status bars, does not inherit EasyFind taint.
    local util = _G.PlayerSpellsUtil
    if util and SecureCall(util.TogglePlayerSpellsFrame, tabIndex) then
        return true
    end

    return ClickButton(_G["PlayerSpellsMicroButton"])
end

local function IsCharacterTabSelected(tabIndex)
    if not tabIndex then return CharacterFrame and CharacterFrame:IsShown() end
    if not (CharacterFrame and CharacterFrame:IsShown()) then return false end
    if PanelTemplates_GetSelectedTab
       and PanelTemplates_GetSelectedTab(CharacterFrame) == tabIndex then
        return true
    end
    if tabIndex == 1 then
        return (PaperDollFrame and PaperDollFrame:IsShown())
            or (CharacterStatsPane and CharacterStatsPane:IsShown())
    elseif tabIndex == 2 then
        return ReputationFrame and ReputationFrame:IsShown()
    elseif tabIndex == 3 then
        return (TokenFrame and TokenFrame:IsShown())
            or (CurrencyFrame and CurrencyFrame:IsShown())
    end
    return false
end

local function OpenCharacterFrame(tabIndex)
    if IsCharacterTabSelected(tabIndex) then return true end

    local subFrame = CHARACTER_TAB_SUBFRAME[tabIndex] or "PaperDollFrame"
    if SecureCall(_G.ToggleCharacter, subFrame) then
        return true
    end

    return ClickButton(_G["CharacterMicroButton"])
end

local function OpenButtonFrame(buttonFrame, nextStep)
    if buttonFrame == "PlayerSpellsMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "PlayerSpellsFrame"
            and nextStep.tabIndex or nil
        return OpenPlayerSpellsFrame(tabIndex)
    elseif buttonFrame == "CharacterMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "CharacterFrame"
            and nextStep.tabIndex or nil
        return OpenCharacterFrame(tabIndex)
    end

    local stepFrame = Utils.GetFrameByPath(buttonFrame) or _G[buttonFrame]
    if stepFrame then return ClickButton(stepFrame) end
    return false
end


function UI:SecureShowUIPanel(frame)
    return SecureShowUIPanel(frame)
end

function UI:OpenButtonFrame(buttonFrame, nextStep)
    return OpenButtonFrame(buttonFrame, nextStep)
end
function UI:IsPlayerSpellsTabSelected(tabIndex)
    return IsPlayerSpellsTabSelected(tabIndex)
end

function UI:OpenPlayerSpellsFrame(tabIndex)
    return OpenPlayerSpellsFrame(tabIndex)
end

function UI:OpenCharacterFrame(tabIndex)
    return OpenCharacterFrame(tabIndex)
end
local searchFrame
local resultsFrame
local selectedIndex = 0   -- 0 = none selected, 1..N = highlighted row
local toggleFocused = false -- true = Tab moved focus to expand/collapse toggle
local navFrame             -- Keyboard capture frame for results navigation
local escCatcher           -- UISpecialFrames fallback for second-ESC-to-close
local activeKeybindBtn
-- Combined-frame backdrop: rounded-rect 9-slice that wraps the bar
-- alone (collapsed to a pill when results are hidden) or the bar
-- plus the results dropdown (rounded rectangle when open). Sibling
-- of searchFrame, anchored to it; grows downward to cover
-- resultsFrame when ShowHierarchicalResults runs.
local containerFrame
local resultButtons = {}
local MAX_BUTTON_POOL = 100
UI.RESULT_SHORTCUT = {
    max = 8,
    width = 34,
    iconSize = 14,
    rightPad = 0,
    gap = -4,
    icon = "Interface\\AddOns\\EasyFind\\textures\\alt-key",
}
local RESULT_SHORTCUT = UI.RESULT_SHORTCUT
local CALCULATOR_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\calculator-icon"
local petFavoriteOverrides = {}
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult
function UI:GetSearchFrame()
    return searchFrame
end

function UI:GetResultsFrame()
    return resultsFrame
end

function UI:SetResultsFrame(frame)
    resultsFrame = frame
end

function UI:GetNavFrame()
    return navFrame
end

function UI:GetResultButtons()
    return resultButtons
end

function UI:GetSelectedIndex()
    return selectedIndex
end

function UI:SetSelectedIndex(index)
    selectedIndex = index or 0
end

function UI:SetToggleFocused(focused)
    toggleFocused = focused and true or false
end
function UI:GetContainerFrame()
    return containerFrame
end

function UI:SetSelectingResult(selecting)
    selectingResult = selecting and true or false
end

function UI:IsSelectingResult()
    return selectingResult
end

function UI:IsInCombat()
    return inCombat
end

function UI:GetPetFavoriteOverrides()
    return petFavoriteOverrides
end

function UI:GetActiveKeybindButton()
    return activeKeybindBtn
end

function UI:SetActiveKeybindButton(button)
    activeKeybindBtn = button
end

function UI:StopActiveKeybindCapture()
    local button = activeKeybindBtn
    if button and button._stopCapture then
        button._stopCapture(button)
    end
end

-- Shell-style search history. historyIndex 0 == "live" buffer (whatever
-- the user has actually typed). Stepping UP increments toward older
-- entries; DOWN decrements back toward 0. Once we hit 0, the next DOWN
-- key falls through to the result-navigation path so the user can drop
-- into the highlighted result row without an extra keystroke.
local historyIndex = 0
local historyDraft = ""           -- User's in-flight text, restored when stepping back to index 0

function UI:GetSearchHistoryIndex()
    return historyIndex
end

function UI:SetSearchHistoryIndex(index)
    historyIndex = index or 0
end

function UI:GetSearchHistoryDraft()
    return historyDraft
end

function UI:SetSearchHistoryDraft(text)
    historyDraft = text or ""
end

function UI:ResetSearchHistory()
    historyIndex = 0
    historyDraft = ""
end

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
    statistic     = { tex = 1121272, coords = { 0.1997, 0.2437, 0.5933, 0.6266 } },
    map           = { tex = 1121272, coords = { 0.3457, 0.3856, 0.2549, 0.2951 } },
    -- Ability / boss: matches the filter-menu icons (boss tab + overview tab
    -- glyphs from the Encounter Journal spritesheet). The row's per-entry
    -- icon (spell icon / boss portrait) is pushed to the RIGHT side.
    ability       = { tex = 522972, coords = { 0.904, 0.996, 0.707, 0.748 } },
    boss          = { tex = 522972, coords = { 0.855, 0.949, 0.524, 0.566 } },
    talent        = { atlas = "UI-HUD-MicroMenu-SpecTalents-Up" },
    achievement   = { atlas = "UI-HUD-MicroMenu-Achievements-Up" },
    macro         = { tex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    bag           = { atlas = "bag-main" },
    loot          = { tex = 522972, coords = { 0.730, 0.824, 0.618, 0.660 } },
    setting       = { atlas = "QuestLog-icon-setting" },
    -- Addon settings get a warm tint so they're distinguishable at a
    -- glance from the silvery-grey game-settings cogwheel.
    settingAddon  = { atlas = "QuestLog-icon-setting", color = { 1.0, 0.78, 0.35 } },
    title         = { tex = 514608, coords = { 0.016, 0.531, 0.324, 0.461 } },
    calculator    = { tex = CALCULATOR_ICON_TEX },
    -- Resolved lazily from PaperDollSidebarTab3 so the icon always
    -- matches whatever sprite-sheet region Blizzard uses for the
    -- Equipment Manager sidebar tab. Filled in by ResolveGearSetIcon().
    gearSet       = { atlas = "equipmentmanager-spec-border" },
}

local BOSS_PORTRAIT_TEXCOORD = { 0.22, 0.78, 0, 1 }

local function IsBossResultData(data)
    return data and data.encounterID and data.category == "Boss"
end

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
    if data.calculatorResult or data.calculatorLauncher then return FLAT_CATEGORY_ICONS.calculator end
    if data.searchCommand then return FLAT_CATEGORY_ICONS.setting end
    if data.quickFilterDef then
        local key = data.quickFilterDef.key
        if key == "abilities" then return FLAT_CATEGORY_ICONS.ability end
        if key == "achievements" then return FLAT_CATEGORY_ICONS.achievement end
        if key == "statistics" then return FLAT_CATEGORY_ICONS.statistic end
        if key == "bags" then return FLAT_CATEGORY_ICONS.bag end
        if key == "bosses" then return FLAT_CATEGORY_ICONS.boss end
        if key == "macros" then return FLAT_CATEGORY_ICONS.macro end
        if key == "collections" then return FLAT_CATEGORY_ICONS.mount end
        if key == "appearanceSets" then return FLAT_CATEGORY_ICONS.appearanceSet end
        if key == "heirlooms" then return FLAT_CATEGORY_ICONS.heirloom end
        if key == "mounts" then return FLAT_CATEGORY_ICONS.mount end
        if key == "outfits" then return FLAT_CATEGORY_ICONS.outfit end
        if key == "pets" then return FLAT_CATEGORY_ICONS.pet end
        if key == "toys" then return FLAT_CATEGORY_ICONS.toy end
        if key == "gearSets" then return FLAT_CATEGORY_ICONS.gearSet end
        if key == "currencies" then return FLAT_CATEGORY_ICONS.currency end
        if key == "loot" then return FLAT_CATEGORY_ICONS.loot end
        if key == "map" then return FLAT_CATEGORY_ICONS.map end
        if key == "reputations" then return FLAT_CATEGORY_ICONS.reputation end
        if key == "talents" then return FLAT_CATEGORY_ICONS.talent end
        if key == "titles" then return FLAT_CATEGORY_ICONS.title end
        return FLAT_CATEGORY_ICONS.setting
    end
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
    if data.statisticID or data.category == "Statistic" then return FLAT_CATEGORY_ICONS.statistic end
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

function UI:GetFlatCategoryIcon(data)
    return GetFlatCategoryIcon(data)
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
    -- before the next element). Callers must invoke this AFTER the
    -- text's final RIGHT anchor target has its size for this row --
    -- e.g. after amountText:SetText or after re-anchoring to the boss
    -- icon -- otherwise the clip uses the previous row's leftover
    -- bound and over-truncates.
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
    if data.calculatorResult then return "Expression" end
    if data.calculatorLauncher then return "Alt+C to open" end
    if data.searchCommandDesc then return data.searchCommandDesc end
    if data.quickFilterAliasText then return data.quickFilterAliasText end
    if data.quickFilterDef then return data.quickFilterDef.label or "Quick Filter" end
    if data.path and #data.path > 0 then
        return data.path[#data.path]
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
-- isn't worth labelling (UI navigation, settings: the row name itself
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

function UI:OpenContainerBag(bag)
    if bag == nil then return false end
    if bag == 0 and OpenBackpack then
        local ok = pcall(OpenBackpack)
        if ok then return true end
    end
    local openBag = OpenBag or (C_Container and C_Container.OpenBag)
    if openBag then
        return pcall(openBag, bag)
    end
    return false
end

function UI:OpenContainerBagLocations(locations, fallbackBag)
    local opened = false
    if locations then
        local seen = {}
        for _, loc in ipairs(locations) do
            if loc.bag ~= nil and not seen[loc.bag] then
                seen[loc.bag] = true
                opened = self:OpenContainerBag(loc.bag) or opened
            end
        end
    elseif fallbackBag ~= nil then
        opened = self:OpenContainerBag(fallbackBag) or opened
    end
    return opened
end

function UI:OpenBagItemLocation(data)
    if not data then return end
    self:OpenContainerBagLocations(data.bagLocations, data.bagID)
    if data.steps and #data.steps >= 2 and ns.Highlight and ns.Highlight.StartGuideAtStep then
        data.steps[2]._efContainerSlotFound = nil
        ns.Highlight:StartGuideAtStep(data, 2)
    end
end

UI.NON_EQUIP_LOCS = {
    INVTYPE_NON_EQUIP = true,
    INVTYPE_NON_EQUIP_IGNORE = true,
    INVTYPE_AMMO = true,
    INVTYPE_QUIVER = true,
}

UI.EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_NECK = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_BODY = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_FINGER = true,
    INVTYPE_TRINKET = true,
    INVTYPE_CLOAK = true,
    INVTYPE_WEAPON = true,
    INVTYPE_SHIELD = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_HOLDABLE = true,
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
    INVTYPE_RELIC = true,
    INVTYPE_TABARD = true,
    INVTYPE_BAG = true,
    INVTYPE_PROFESSION_TOOL = true,
    INVTYPE_PROFESSION_GEAR = true,
}

function UI:IsRealEquipLoc(slot)
    return type(slot) == "string"
        and self.EQUIP_LOCS[slot] == true
        and not self.NON_EQUIP_LOCS[slot]
end

function UI:GetItemEquipLoc(itemID)
    local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getItemInfoInstant then return nil end

    local info, _, _, equipLoc = getItemInfoInstant(itemID)
    if type(info) == "table" then
        return info.itemEquipLoc or info.equipLoc or info.inventoryType
    end
    return equipLoc
end

function UI:GetBagItemActionKind(data)
    if not data or not data.itemID or data.category ~= "Bag" then return nil end

    -- Only treat items with a real gear slot as "equippable". Empty /
    -- NON_EQUIP / AMMO / QUIVER are not gear slots.
    local slot = data.equipLoc
    if not self:IsRealEquipLoc(slot) then
        slot = self:GetItemEquipLoc(data.itemID)
    end
    if self:IsRealEquipLoc(slot) then
        return "equip"
    end

    local hasUseEffect = (C_Item and C_Item.GetItemSpell and C_Item.GetItemSpell(data.itemID))
        or (GetItemSpell and GetItemSpell(data.itemID))
    if hasUseEffect then return "use" end

    if GetItemInfo then
        local itemType = select(6, GetItemInfo(data.itemID))
        if itemType == "Consumable" then
            return "use"
        elseif itemType == "Container" or itemType == "Quest" then
            return "open"
        end
    end

    return "show"
end

local function GetActionHint(data)
    if not data then return nil end
    if data.calculatorResult then return "Select result for Ctrl+C" end
    if data.quickFilterDef then return "Select to filter results" end
    if data.titleID then return "Select to apply as your title" end
    if data.mountID then return "Select to summon mount | Ctrl+click to show in journal" end
    if data.petID or data.speciesID then return "Select to summon pet | Ctrl+click to show in journal" end
    if data.toyItemID then
        return data.isToyboxOnly and "Select to show in Toy Box" or "Select to use toy | Ctrl+click to show in Toy Box"
    end
    if data.heirloomItemID then return "Select to add heirloom to bags" end
    if data.outfitID then return "Select to wear outfit | Ctrl+click to show in transmogrification" end
    if data.gearSetID then return "Select to equip gear set" end
    if data.transmogSetID then return "Select to preview | Ctrl+click to try on" end
    if data.spellID and data.category == "Ability" then
        return IsSpellbookOnlyAbility(data) and "Select to show in spellbook" or "Select to cast"
    end
    if data.macroIndex then return "Select to run macro | Ctrl+click to edit" end
    if data.itemID and data.category == "Bag" then
        local actionKind = UI:GetBagItemActionKind(data)
        if actionKind == "equip" then
            return "Select to equip item | Ctrl+click to show in bags"
        elseif actionKind == "open" then
            return "Select to open item | Ctrl+click to show in bags"
        elseif actionKind == "use" then
            return "Select to use item | Ctrl+click to show in bags"
        end
        return "Select to show in bags"
    end
    if data.mapSearchResult then
        if data.isZone then return "Select to open map to location" end
        return "Select to pin location on map"
    end
    if data.encounterID and data.category == "Boss" then
        return "Select to open Encounter Journal"
    end
    if (data.settingType == "checkbox" or data.settingType == "checkboxSlider")
       and data.settingVariable then
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

function UI:KeepPinnedResultsOpenBriefly()
    if #GetAllPins() == 0 then return false end
    UI._keepPinnedResultsOpenUntil = (GetTime and GetTime() or 0) + 0.35
    if searchFrame and searchFrame.editBox
       and strtrim(searchFrame.editBox:GetText() or "") == "" then
        UI:ShowPinnedItems()
    end
    return true
end

local function IsOptionsSurfaceMouseOver()
    local function hasFocus(frame)
        if not frame or not frame:IsShown() then return false end
        if GetMouseFoci then
            local foci = GetMouseFoci()
            if foci then
                for i = 1, #foci do
                    local f = foci[i]
                    while f do
                        if f == frame then return true end
                        f = f.GetParent and f:GetParent()
                    end
                end
            end
        elseif GetMouseFocus then
            local f = GetMouseFocus()
            while f do
                if f == frame then return true end
                f = f.GetParent and f:GetParent()
            end
        end
        return false
    end
    local function isInside(frame)
        return Utils.IsFrameOrChildMouseOver(frame) or hasFocus(frame)
    end

    local frame = ns.optionsFrame
    if isInside(frame) then return true end
    if not frame then return false end
    local guards = {
        frame.indicatorFlyout,
        frame.colorFlyout,
        frame.fontFlyout,
        frame.mapTabGroup and frame.mapTabGroup.flyout,
        frame.mapPinGroup and frame.mapPinGroup.flyout,
        frame.automationGroup and frame.automationGroup.flyout,
    }
    for i = 1, #guards do
        if isInside(guards[i]) then return true end
    end
    return false
end

local unearnedTooltip

function UI:GetUnearnedTooltip()
    return unearnedTooltip
end

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

local THEMES = {}

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
    expandIcon      = "Interface\\Buttons\\UI-PlusButton-Up",
    collapseIcon    = "Interface\\Buttons\\UI-MinusButton-Up",
    highlightTex    = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    selectionColor  = {0.25, 0.5, 0.9, 0.35},
    showHeaderBar   = false,
    showHeaderTab   = false,
    headerTabAtlas  = "QuestLog-tab",             -- WoW atlas for tab background
    headerHighlightAlpha = 0.40,                  -- highlight layer alpha
    expandAtlas     = "QuestLog-icon-expand",     -- plus sign atlas
    collapseAtlas   = "QuestLog-icon-shrink",     -- minus sign atlas
    toggleNormalAlpha = 0.60,                     -- muted yellow (normal state)
    toggleHoverAlpha  = 1.0,                      -- bright yellow (hover state)
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
    ScaleFont(row.calcExpressionText, "GameFontHighlightLarge")
    ScaleFont(row.calcArrowText, "GameFontHighlight")
    ScaleFont(row.calcResultText, "GameFontHighlightLarge")
    ScaleFont(row.calcExpressionHint, "GameFontDisableSmall")
    ScaleFont(row.calcResultHint, "GameFontDisableSmall")
    ScaleFont(row.calcActionTitle, "GameFontHighlightSmall")
    ScaleFont(row.calcActionDesc, "GameFontDisableSmall")
    ScaleFont(row.calcActionKey, "GameFontDisableSmall")
    ScaleFont(row.calcActionAfter, "GameFontDisableSmall")
    ScaleFont(row.repBarText, "GameFontNormalSmall")
    ScaleFont(row.settingSliderValue, "GameFontNormalSmall")
    ScaleFont(row.shortcutNumberText, "GameFontDisableSmall")
    if UI.LayoutResultShortcut then
        UI:LayoutResultShortcut(row)
    end
end

local function IsSecureActionResult(data)
    return data and (data.outfitID or data.toyItemID
        or (data.spellID and not IsSpellbookOnlyAbility(data))
        or data.mountID or data.macroIndex or data.slashCommand
        or (data.itemID and data.category == "Bag"
            and UI:GetBagItemActionKind(data) ~= "show"))
end

function UI:GetFlatSubtext(data)
    return GetFlatSubtext(data)
end

function UI:ClearActionHint()
    return ClearActionHint()
end

function UI:ApplyActionHint(row)
    return ApplyActionHint(row)
end

function UI:ShowPinPopup(...)
    return ShowPinPopup(...)
end

function UI:ClearResultTooltips()
    return ClearResultTooltips()
end

function UI:SetRowIcon(btn, kind, value, iconSize)
    return SetRowIcon(btn, kind, value, iconSize)
end

function UI:GetActiveTheme()
    return GetActiveTheme()
end

function UI:SetScaledFont(fontString, baseFontObject)
    return SetScaledFont(fontString, baseFontObject)
end

function UI:ApplyResultRowFonts(row, theme)
    return ApplyResultRowFonts(row, theme)
end

function UI:IsSecureActionResult(data)
    return IsSecureActionResult(data)
end

function UI:IsBossResultData(data)
    return IsBossResultData(data)
end

function UI:GetBossPortraitTexCoord()
    return BOSS_PORTRAIT_TEXCOORD
end

function UI:AbbrevBinding(binding)
    return AbbrevBinding(binding)
end

function UI:SetClippedText(fontString, text)
    return SetClippedText(fontString, text)
end

function UI:AnchorTooltipAtCursor(tooltip, ownerFrame)
    return AnchorTooltipAtCursor(tooltip, ownerFrame)
end

function UI:AnchorGearTooltip(tooltip, ownerFrame)
    return AnchorGearTooltip(tooltip, ownerFrame)
end

function UI:GetActionHint(data)
    return GetActionHint(data)
end
local function GetResultShortcutIndex(key)
    if not resultsFrame or not resultsFrame:IsShown() then return nil end
    if not IsAltKeyDown or not IsAltKeyDown() then return nil end
    if (IsControlKeyDown and IsControlKeyDown())
       or (IsShiftKeyDown and IsShiftKeyDown()) then
        return nil
    end
    local digit = tonumber(key)
    if not digit then
        digit = tonumber((key or ""):match("^NUMPAD([1-8])$"))
    end
    if digit and digit >= 1 and digit <= RESULT_SHORTCUT.max then
        return digit
    end
    return nil
end

local function ShouldShowResultShortcutHints()
    return not (EasyFind and EasyFind.db and EasyFind.db.showResultShortcutHints == false)
end

function UI:ShouldShowResultShortcutHints()
    return ShouldShowResultShortcutHints()
end

function UI:LayoutResultShortcut(row)
    if not (row and row.shortcutGroup) then return end
    local scale = EasyFind.db.fontSize or 1.0
    local extra = mmax(0, scale - 1.0)
    local numberW = mmax(9, mfloor(8 * scale + 5))
    local groupW = mmax(RESULT_SHORTCUT.width, RESULT_SHORTCUT.iconSize + numberW + 14 + mfloor(extra * 12 + 0.5))
    local rightPad = RESULT_SHORTCUT.rightPad + mfloor(extra * 14 + 0.5)
    local groupH = mmax(16, mfloor(16 * mmin(scale, 1.35) + 0.5))

    row.shortcutGroup:ClearAllPoints()
    row.shortcutGroup:SetPoint("RIGHT", row, "RIGHT", -rightPad, 0)
    row.shortcutGroup:SetSize(groupW, groupH)

    if row.shortcutNumberText then
        row.shortcutNumberText:ClearAllPoints()
        row.shortcutNumberText:SetPoint("RIGHT", row.shortcutGroup, "RIGHT", 0, 0)
        row.shortcutNumberText:SetWidth(numberW)
        row.shortcutNumberText:SetJustifyH("RIGHT")
        if row.shortcutNumberText.SetWordWrap then row.shortcutNumberText:SetWordWrap(false) end
        if row.shortcutNumberText.SetNonSpaceWrap then row.shortcutNumberText:SetNonSpaceWrap(false) end
        if row.shortcutNumberText.SetMaxLines then row.shortcutNumberText:SetMaxLines(1) end
    end
    if row.shortcutAltIcon and row.shortcutNumberText then
        row.shortcutAltIcon:ClearAllPoints()
        row.shortcutAltIcon:SetSize(RESULT_SHORTCUT.iconSize, RESULT_SHORTCUT.iconSize)
        row.shortcutAltIcon:SetPoint("RIGHT", row.shortcutNumberText, "LEFT", 2, 0)
    end
end

function UI:CreateUnearnedTooltip()
    unearnedTooltip = CreateFrame("Frame", "EasyFindUnearnedTooltip", UIParent, "BackdropTemplate")
    unearnedTooltip:SetFrameStrata("TOOLTIP")
    unearnedTooltip:SetFrameLevel(9999)
    unearnedTooltip:SetClampedToScreen(true)

    unearnedTooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    unearnedTooltip:SetBackdropColor(0, 0, 0, 0.95)
    unearnedTooltip:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local text = unearnedTooltip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    text:SetText("Currency not yet earned")
    text:SetTextColor(1, 1, 1, 1)
    unearnedTooltip.text = text

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
        UI:EnsureResultButton(i):Hide()
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
    local barH = self:GetSearchBarHeight()
    searchFrame:SetSize(250, barH)
    -- FULLSCREEN_DIALOG keeps the search bar above the default UI's
    -- DIALOG-strata menus (Game Menu, Options panel, etc.) so opening
    -- the bar from inside any in-game menu still puts our results on
    -- top instead of getting buried.
    searchFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetClampedToScreen(true)

    if EasyFind.db.uiSearchPosition then
        local pos = EasyFind.db.uiSearchPosition
        searchFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        local point, relPoint, x, y = self:GetDefaultSearchBarPoint()
        searchFrame:SetPoint(point, UIParent, relPoint, x, y)
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
    self:ApplySearchWindowFill(containerFrame)

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
    ns.SetRoundedRectBorderBgAlpha(containerFrame, ns.SEARCH_WINDOW_ALPHA or 0.95)

    -- Static magnifying-glass icon (non-interactive, flush left)
    local contentSz = barH * ns.SEARCHBAR_FILL
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
    searchFrame.iconHolder = iconHolder

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
            -- Alt+L to keep editing from the end.
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
        -- Shift-drag deliberately clears focus while blockFocus is set so
        -- the editbox does not steal the drag. Do not run the normal
        -- click-outside cleanup path from that synthetic focus loss.
        if self._dragMoving then
            self:HighlightText(0, 0)
            return
        end
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
        if not onGuard and IsOptionsSurfaceMouseOver() then onGuard = true end
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
                if UI._keepPinnedResultsOpenUntil then
                    local keepUntil = UI._keepPinnedResultsOpenUntil
                    UI._keepPinnedResultsOpenUntil = nil
                    local now = GetTime and GetTime() or 0
                    if now <= keepUntil and #GetAllPins() > 0 then
                        UI:ShowPinnedItems()
                        if searchFrame.editBox.blockFocus then
                            searchFrame.editBox.blockFocus = nil
                        end
                        return
                    end
                end
                -- Don't hide if spec/class flyouts are open
                local sf = _G["EasyFindSpecFlyout"]
                local ssf = _G["EasyFindSpecSubFlyout"]
                if (sf and sf:IsShown()) or (ssf and ssf:IsShown()) then return end
                local dd = _G["EasyFindUIFilterDropdown"]
                if dd and dd:IsShown() then return end
                if IsOptionsSurfaceMouseOver() then return end
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
    Utils.SafeOnUpdate(pendingUISearchFrame, function(self)
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
    local function ResetPendingUISearch()
        pendingUISearchFrame:Hide()
        pendingUISearchText = ""
        pendingUISearchGrew = false
        pendingUISearchDue = 0
        lastTypedLen = 0
        historyIndex = 0
        historyDraft = ""
    end
    editBox.ResetPendingSearch = ResetPendingUISearch
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
        if not userInput then
            if self:GetText() == "" and self.ResetPendingSearch then
                self:ResetPendingSearch()
            end
            return
        end
        if self.IsAutocompleteBackspaceStrip and self:IsAutocompleteBackspaceStrip() then return end
        historyIndex = 0
        historyDraft = ""
        if UI:HandleQuickFilterTextChanged(self) then return end
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
        -- doesn't focus the result row, they'd have to press Enter
        -- a second time. Stripping here puts the text back to what
        -- the user typed before WoW's default handler runs.
        if self.StripAutocomplete then self:StripAutocomplete() end
        local typed = strtrim(self:GetText() or "")

        -- /command parser. Anything starting with "/" is treated as a
        -- bar command, not a search query. /reset restores the default
        -- position and size, /resize opens the drag-to-resize overlay.
        if typed:sub(1, 1) == "/" then
            UI:RunSearchBarCommand(typed)
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
            local row = resultButtons[idx]
            if row and row.data and row.data.calculatorResult then
                UI:ArmCalculatorResultFromRow(row, "key")
            end
            return
        end
        UI:ActivateSelected("key")
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
                local quickDef = row.data and row.data.quickFilterDef
                local quickToken = quickDef and UI:GetQuickFilterCompletionToken(quickDef, typed)
                if quickToken then
                    return quickToken
                end
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
        backspaceAutocompleteTarget = function(_, typed)
            if not UI._quickFilterSuggestionsActive or not typed then return nil end
            if not typed:match("^%s*@[%w_%-:]*$") then return nil end
            local text = typed:sub(1, -2)
            return text, #text
        end,
        onBackspaceAutocompleteRestored = function(box, text)
            if box and box.placeholder then
                box.placeholder:SetShown((box:GetText() or "") == "")
            end
            if box and box.ResetPendingSearch then
                box:ResetPendingSearch()
            end
            if box and UI:UpdateQuickFilterSuggestions(box) then
                return
            end
            UI:OnSearchTextChanged(text or "", true)
        end,
        onAccepted = function(text)
            if text and text ~= "" then
                local box = searchFrame and searchFrame.editBox
                if box and text:match("^%s*@[%w_%-:]+$") and UI:UpdateQuickFilterSuggestions(box) then
                    return
                end
                UI:OnSearchTextChanged(text, true)
            end
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
        -- Inner circle (clips hover bg + highlight): keep the same radius
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

    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
    self:CreateQuickFilterPill(searchFrame, editBox, iconHolder, filterBtn)
    self:UpdateQuickFilterPill()

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
        -- Alt+letter: set propagate=false up front; late suppression can leak
        -- the char into the editbox before OnChar sees the new state.
        if IsAltKeyDown() and key and key:match("^[A-Z]$") then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        end
        UI:HandleCalculatorPasteIntoSearch(self, key)
        if UI:HandleCalculatorOpenShortcut(self, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end
        if UI:HandleQuickFilterKeyDown(self, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        local shortcutIndex = GetResultShortcutIndex(key)
        if shortcutIndex then
            local shortcutResult = UI:ActivateVisibleResultShortcut(shortcutIndex)
            if shortcutResult then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", shortcutResult == "binding")
                return
            end
        end

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
            elseif key == "L" and IsAltKeyDown() then
                self:AcceptAutocomplete("alt-l")
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
        local isUpHist   = key == "UP"   or (IsAltKeyDown() and key == "K")
        local isDownHist = key == "DOWN" or (IsAltKeyDown() and key == "J")
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
            -- nav so DOWN/Alt+J jumps into the first row.
        end

        if resultsFrame and resultsFrame:IsShown() and selectedIndex == 0 then
            if EasyFind.db.uiResultsAbove then
                if key == "UP" then UI:JumpToEnd() end
            else
                if key == "DOWN" then UI:MoveSelection(1) end
            end
        end
        -- Alt+J/K walks into the
        -- result list once history navigation has been exhausted by
        -- the branch above. Single-step only (no key-repeat) because
        -- MoveSelection transfers keyboard focus to navFrame and the
        -- subsequent KeyUp event gets lost in the focus transition,
        -- leaving the repeat ticker firing forever and cascading
        -- through the entire result list.
        if IsAltKeyDown() then
            if key == "J" then
                UI:MoveSelection(1)
            elseif key == "K" then
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

    -- toggle button (chevron / pin toggle) and back. Shared by Tab,
    -- Shift+Tab, and the Alt+L / Alt+H vim aliases below.
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

        if UI:HandleCalculatorOpenShortcut(searchFrame and searchFrame.editBox, key) then return end
        if UI:HandleCalculatorCopyConfirmKey(key) then return end
        if UI:HandleCalculatorCopyKey(key) then return end

        -- Alt+H/J/K/L: vim-style nav aliases. J/K = down/up;
        -- add Shift to jump sections like Shift+Up/Down.
        -- H/L = focus cycle (Shift+Tab / Tab).
        if IsAltKeyDown() and key == "J" then
            if IsShiftKeyDown() then
                UI:JumpToNextSection(1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(1) end)
            end
            return
        elseif IsAltKeyDown() and key == "K" then
            if IsShiftKeyDown() then
                UI:JumpToNextSection(-1)
            else
                StartKeyRepeat(key, function() UI:MoveSelection(-1) end)
            end
            return
        elseif IsAltKeyDown() and key == "L" then
            CycleFocus(false)
            return
        elseif IsAltKeyDown() and key == "H" then
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
            -- be re-selected after the rebuild, letting the user spam
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
            if UI._quickFilterSuggestionsActive and UI:AcceptQuickFilterSuggestion() then
                return
            end
            CycleFocus(IsShiftKeyDown())
        elseif key == "ENTER" then
            if toolbarFocus > 0 then
                local controls = GetToolbarControls()
                local target = controls[toolbarFocus]
                if target then target:Click() end
            else
                UI:ActivateSelected("key")
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
        if UI:HandleCalculatorOpenShortcut(searchFrame and searchFrame.editBox, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        if UI:IsCalculatorCopyConfirmKey(key) then
            UI:RearmActiveCalculatorCopy("confirm")
            Utils.SafeAfter(0, function()
                UI:ConfirmCalculatorCopied()
            end)
            -- Ctrl+C must not leak to gameplay keybinds. The hidden editbox is
            -- already focused and selected; swallowing propagation still lets
            -- the client copy that selected text.
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        local shortcutIndex = GetResultShortcutIndex(key)
        if shortcutIndex then
            local shortcutResult = UI:ActivateVisibleResultShortcut(shortcutIndex)
            if shortcutResult then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", shortcutResult == "binding")
                return
            end
        end

        -- Secure-action rows: let Enter propagate to the override
        -- binding so the secure click dispatch fires (same as a mouse
        -- click). Without this navFrame swallows Enter and the
        -- override binding never sees the key. Abilities, mounts,
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
        elseif UI:IsCalculatorCopyKey(key) then
            consume = true
        elseif IsAltKeyDown() and (key == "J" or key == "K" or key == "L" or key == "H") then
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
    -- UISpecialFrames registration removed: any insecure mutation of
    -- a frame in that table can taint Blizzard's ESC pipeline, and we
    -- mutate this frame heavily. Our editbox's OnEscapePressed and the
    -- searchFrame's keyboard handler at the navFrame level handle ESC
    -- on their own, so giving up the UISpecialFrames fallback is safe.
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
    -- filter buttons) is handled by Left/Right and Alt+H/Alt+L
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
        local point, _, relPoint, x, y = self:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
    end)

    self:UpdateScale()
    self:UpdateOpacity()

    local function GetEffectiveAlpha()
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
        UI:HideQuickFilterSuggestions()
    end)
    searchFrame:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not EasyFind.db.autoHide then return end
        -- Minimap button click is in flight: skip autoHide so the button's
        -- own OnClick toggle is the only state change. Set in OnMouseDown
        -- of the minimap button (Core/Main.lua), cleared in OnMouseUp.
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
        if IsOptionsSurfaceMouseOver() then return end
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
    local wasShown = searchFrame:IsShown()
    if not wasShown and self._quickFilter then
        self:ClearQuickFilter(false)
        if searchFrame.editBox then
            if searchFrame.editBox.ResetPendingSearch then searchFrame.editBox:ResetPendingSearch() end
            searchFrame.editBox:SetText("")
            if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
        end
    end
    searchFrame:Show()
    -- Belt-and-suspenders: OnShow hook also calls this, but if searchFrame
    -- was already shown the hook didn't fire and escCatcher would be left
    -- hidden, leaving ESC without a target when the editbox is unfocused.
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

    -- Bar is toggled off: the hover zone must not linger and eat clicks.
    searchFrame.hoverZone:Hide()
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
    -- Pending Apply-flagged settings: the popup must preempt the
    -- text-clear and panel-close branches so Cancel preserves the
    -- exact pre-ESC state (text, scroll, pending change). The helper
    -- also lifts the popup above our results panel strata.
    if self:ShowUnappliedSettingsPopup() then return end
    if (editBox and editBox:GetText() ~= "") or self._quickFilter then
        if editBox and editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        if editBox then
            editBox:SetText("")
            if editBox.placeholder then editBox.placeholder:Show() end
        end
        self:ClearQuickFilter(false)
        self:HideQuickFilterSuggestions()
        Refocus()
        -- Programmatic SetText intentionally does not run the throttled
        -- search path. Rebuild immediately so stale typed results are
        -- replaced by pinned rows, or hidden when there are no pins.
        self:OnSearchTextChanged("", true)
        return
    end
    self:Hide()
end

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
                SecureCall(C_CurrencyInfo.ExpandCurrencyList, i, true)
            end
            return true
        end
    end
    return false
end

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

function UI:ClickPortraitMenuOption(optionName)
    local optionNameLower = slower(optionName)

    -- Search through open dropdown frames for the matching button
    -- Modern WoW uses the Menu system
    local function searchFrame(frame, depth)
        if not frame or depth > 5 then return false end

        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            if child and child:IsShown() then
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
    if UI._cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        local savedIndex = selectedIndex
        local savedToggle = toggleFocused
        -- Bypass ShowHierarchicalResults' render-skip cache. Setting
        -- toggles, slider writes, and dropdown cycles keep the same
        -- entry.data reference, so the row-by-row layout pass would be
        -- skipped and the on-screen checkbox/value/slider would stay
        -- stale until the result list rebuilt from scratch.
        self._lastRenderSig = nil
        self:ShowHierarchicalResults(UI._cachedHierarchical, true)
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
    local alpha = ns.SEARCH_WINDOW_ALPHA or 0.95
    if containerFrame then
        self:ApplySearchWindowFill(containerFrame)
        ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
    end
end

function UI:UpdateSearchBarTheme()
    if not searchFrame then return end
    local alpha = ns.SEARCH_WINDOW_ALPHA or 0.95
    searchFrame:SetBackdrop(nil)
    -- Pill stays hidden; container provides the rounded silhouette.
    ns.SetSearchBorderShown(searchFrame, false)
    if containerFrame then
        ns.SetRoundedRectBorderShown(containerFrame, true)
        ns.SetRoundedRectBarHeight(containerFrame, self:GetSearchBarHeight())
        self:ApplySearchWindowFill(containerFrame)
        ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
    end
end

function UI:UpdateSearchBarHeight()
    self:UpdateFontSize()
end

function UI:UpdateSmartShow()
    if not searchFrame then return end
    local enabled = EasyFind.db.smartShow
    if enabled then
        -- Smart Show owns the bar; it stays enabled and starts shown, then
        -- tucks away on its own if the mouse isn't near it.
        EasyFind.db.visible = true
        searchFrame.hoverZone:Show()
        if not inCombat then
            searchFrame:Show()
            searchFrame.smartShowFadeIn()
            C_Timer.After(1.5, function()
                if EasyFind.db.smartShow then searchFrame.smartShowFadeOut() end
            end)
        end
    else
        -- Disable smart show: hide hover zone, cancel any pending fade-out
        -- timer (the player may be mid-hover-out when they flip the toggle),
        -- and restore normal opacity.
        searchFrame.hoverZone:Hide()
        if searchFrame.cancelSmartShowTimer then searchFrame.cancelSmartShowTimer() end
        UIFrameFadeRemoveFrame(searchFrame)
        searchFrame.setSmartShowVisible(true)
        if EasyFind.db.autoHide then
            return
        end
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
        local point, relPoint, x, y = self:GetDefaultSearchBarPoint()
        searchFrame:SetPoint(point, UIParent, relPoint, x, y)
        EasyFind.db.uiSearchPosition = nil
    end
end

function UI:ResetPositionAndSize()
    if EasyFind and EasyFind.db then
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.uiSearchScale = 1.0
        EasyFind.db.uiSearchWidth = 1.54
        EasyFind.db.uiSearchBarHeight = ns.SEARCHBAR_HEIGHT or 30
        EasyFind.db.uiResultsScale = 1.0
        EasyFind.db.uiResultsWidth = 350
        EasyFind.db.uiResultsHeight = 280
    end
    self:ResetPosition()
    self:UpdateScale()
    self:UpdateWidth()
    self:UpdateSearchBarHeight()
    self:RefreshResults()
end

function UI:UpdateFontSize()
    if not searchFrame then return end

    ScaleFont(searchFrame.editBox, ns.SEARCHBAR_FONT)
    ScaleFont(searchFrame.editBox.placeholder, ns.SEARCHBAR_FONT)

    local barH = UI:GetSearchBarHeight()
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
    local alpha = ns.SEARCH_WINDOW_ALPHA or 0.95
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        if containerFrame then
            ns.SetRoundedRectBarHeight(containerFrame, barH)
            self:ApplySearchWindowFill(containerFrame)
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
            edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
        local c = ns.SEARCH_WINDOW_FILL_COLOR or {0.052, 0.052, 0.060}
        searchFrame:SetBackdropColor(c[1], c[2], c[3], alpha)
    end

    for i = 1, #resultButtons do
        ApplyResultRowFonts(resultButtons[i], theme)
    end

    -- Re-layout visible results with new row heights
    if UI._cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        self:ShowHierarchicalResults(UI._cachedHierarchical, true)
    end
end
