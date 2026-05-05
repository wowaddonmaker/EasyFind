local _, ns = ...

local UI = {}
ns.UI = UI

local Utils = ns.Utils
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
local DARK_PANEL_BG = ns.DARK_PANEL_BG

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local GetCursorPosition  = GetCursorPosition
local InCombatLockdown   = InCombatLockdown
local HideUIPanel        = HideUIPanel
local wipe               = wipe

local EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
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
local MAX_BUTTON_POOL = 50  -- Maximum buttons (scroll handles overflow beyond this)
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult
local deferredRepRefreshPending = false  -- deferred re-render to let IsTruncated() settle
local outfitCdStart, outfitCdDuration = 0, 0  -- shared outfit swap cooldown
local lastEquippedOutfitID                     -- tracks most recent equip for immediate green tint

-- Shell-style search history. historyIndex 0 == "live" buffer (whatever
-- the user has actually typed). Stepping UP increments toward older
-- entries; DOWN decrements back toward 0. Once we hit 0, the next DOWN
-- key falls through to the result-navigation path so the user can drop
-- into the highlighted result row without an extra keystroke.
local historyIndex = 0
local historyDraft = ""           -- User's in-flight text, restored when stepping back to index 0

-- PIN HELPERS

local function GetUIPinKey(data)
    if not data or not data.name then return "" end
    return data.name .. "|" .. tconcat(data.path or {}, ">")
end

-- Copy storable fields from a search entry for SavedVariables pinning.
-- Uses explicit field access (not pairs) so metatable __index fields are included.
local CLEAN_SIMPLE_FIELDS = {"name", "nameLower", "category", "buttonFrame", "flashLabel", "icon",
    "mountID", "spellID", "toyItemID", "petID", "speciesID", "outfitID", "heirloomItemID",
    "macroIndex", "macroIsChar", "bagID", "bagSlot", "bagItemLink",
    "itemID", "encounterID", "instanceID", "lootSlotName", "lootSourceName", "lootInstanceName", "lootSourceType",
    "transmogSetID",
    "factionID", "hasRepBar", "canQueue", "isPvP", "isPvE"}
-- Tables to copy. Some are arrays (path, steps, keywords) and some are
-- string-keyed maps (lootItemLinks = {[difficulty] = link}), so iterate
-- with pairs rather than ipairs.
local CLEAN_TABLE_FIELDS = {"path", "steps", "keywords", "keywordsLower", "lootItemLinks"}

local function CleanUIForStorage(data)
    local clean = {}
    for fi = 1, #CLEAN_SIMPLE_FIELDS do
        local k = CLEAN_SIMPLE_FIELDS[fi]
        local v = data[k]
        if v ~= nil then clean[k] = v end
    end
    for fi = 1, #CLEAN_TABLE_FIELDS do
        local k = CLEAN_TABLE_FIELDS[fi]
        local v = data[k]
        if v then
            local copy = {}
            for k2, v2 in pairs(v) do
                if type(v2) == "table" then
                    local sub = {}
                    for sk, sv in pairs(v2) do sub[sk] = sv end
                    copy[k2] = sub
                else
                    copy[k2] = v2
                end
            end
            clean[k] = copy
        end
    end
    return clean
end

-- Collection-type pins (mounts, toys, pets, outfits, loot) are character-specific.
-- All other pins are account-wide.
local function IsCollectionPin(data)
    return data and (data.mountID or data.toyItemID or data.petID or data.outfitID
        or data.heirloomItemID
        or (data.itemID and data.category == "Loot"))
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
    map           = { tex = 1121272, coords = { 0.3457, 0.3856, 0.2549, 0.2951 } },
    -- Ability / boss: matches the filter-menu icons (boss tab + overview tab
    -- glyphs from the Encounter Journal spritesheet). The row's per-entry
    -- icon (spell icon / boss portrait) is pushed to the RIGHT side.
    ability       = { tex = 522972, coords = { 0.904, 0.996, 0.707, 0.748 } },
    boss          = { tex = 522972, coords = { 0.855, 0.949, 0.524, 0.566 } },
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
local function GetFlatSubtext(data)
    if not data then return "" end
    if data.path and #data.path > 0 then
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

-- Hint shown only on the currently-selected row, replacing the normal
-- subtext so the user knows what Enter / left-click will do without
-- cluttering every other row. Returns nil for entries whose action
-- isn't worth labelling (UI navigation, settings — the row name itself
-- already tells you what happens).
local function GetActionHint(data)
    if not data then return nil end
    if data.titleID then return "Select to apply as your title" end
    if data.mountID then return "Select to summon mount" end
    if data.petID then return "Select to summon pet" end
    if data.toyItemID then return "Select to use toy" end
    if data.heirloomItemID then return "Select to add heirloom to bags" end
    if data.outfitID then return "Select to wear outfit" end
    if data.gearSetID then return "Select to equip gear set" end
    if data.transmogSetID then return "Select to preview appearance set" end
    if data.spellID and data.category == "Ability" then return "Select to cast" end
    if data.macroIndex then return "Select to run macro" end
    if data.itemID and data.category == "Bag" then
        if data.equipLoc and data.equipLoc ~= "" then
            return "Select to equip item"
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
    if data.settingType == "dropdown" and data.settingVariable then
        return "Select to cycle value"
    end
    if data.settingType == "checkbox" and data.settingVariable then
        return "Select to toggle"
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

local charKey -- "Name-Realm", set on first use
local function GetCharKey()
    if not charKey then
        local name = UnitName("player")
        local realm = GetRealmName()
        charKey = name and realm and (name .. "-" .. realm) or "Unknown"
    end
    return charKey
end

local function GetPinList(data)
    if IsCollectionPin(data) then
        local key = GetCharKey()
        local perChar = EasyFind.db.pinnedUIItemsPerChar
        if not perChar[key] then perChar[key] = {} end
        return perChar[key]
    end
    return EasyFind.db.pinnedUIItems
end

local function GetAllPins()
    local all = {}
    for _, pin in ipairs(EasyFind.db.pinnedUIItems) do
        all[#all + 1] = pin
    end
    local key = GetCharKey()
    local charPins = EasyFind.db.pinnedUIItemsPerChar and EasyFind.db.pinnedUIItemsPerChar[key]
    if charPins then
        for _, pin in ipairs(charPins) do
            all[#all + 1] = pin
        end
    end
    return all
end

local function IsUIItemPinned(data)
    local key = GetUIPinKey(data)
    -- Check both lists for collection pins (may exist in either due to migration)
    for _, pin in ipairs(EasyFind.db.pinnedUIItems) do
        if GetUIPinKey(pin) == key then return true end
    end
    if IsCollectionPin(data) then
        local charKey = GetCharKey()
        local charPins = EasyFind.db.pinnedUIItemsPerChar and EasyFind.db.pinnedUIItemsPerChar[charKey]
        if charPins then
            for _, pin in ipairs(charPins) do
                if GetUIPinKey(pin) == key then return true end
            end
        end
    end
    return false
end

local function PinUIItem(data)
    if IsUIItemPinned(data) then return end
    local clean = CleanUIForStorage(data)
    clean.isPinned = true
    tinsert(GetPinList(data), clean)
end

local function UnpinUIItem(data)
    local key = GetUIPinKey(data)
    -- Remove from whichever list contains it
    local items = EasyFind.db.pinnedUIItems
    for i = #items, 1, -1 do
        if GetUIPinKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
    if IsCollectionPin(data) then
        local ck = GetCharKey()
        local charPins = EasyFind.db.pinnedUIItemsPerChar and EasyFind.db.pinnedUIItemsPerChar[ck]
        if charPins then
            for i = #charPins, 1, -1 do
                if GetUIPinKey(charPins[i]) == key then
                    tremove(charPins, i)
                    return
                end
            end
        end
    end
end
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


-- Sync pinned outfit names/icons with current outfit data.
-- Called when TRANSMOG_OUTFITS_CHANGED fires (outfits renamed/deleted).
function UI:SyncOutfitPins()
    if not C_TransmogOutfitInfo or not C_TransmogOutfitInfo.GetOutfitsInfo then return end
    local outfits = C_TransmogOutfitInfo.GetOutfitsInfo()
    if not outfits then return end

    -- Build lookup: outfitID -> { name, icon }
    local lookup = {}
    for _, info in ipairs(outfits) do
        lookup[info.outfitID] = info
    end

    -- Update both pin lists
    local function syncList(pins)
        if not pins then return end
        for i = #pins, 1, -1 do
            local pin = pins[i]
            if pin.outfitID then
                local info = lookup[pin.outfitID]
                if info then
                    pin.name = info.name
                    pin.nameLower = info.name:lower()
                    pin.icon = info.icon
                else
                    -- Outfit was deleted, remove pin
                    tremove(pins, i)
                end
            end
        end
    end

    syncList(EasyFind.db.pinnedUIItems)
    local ck = GetCharKey()
    local charPins = EasyFind.db.pinnedUIItemsPerChar and EasyFind.db.pinnedUIItemsPerChar[ck]
    syncList(charPins)
end

-- Right-click context menu with Pin/Unpin and optional Guide row.
-- Anchored BOTTOMLEFT at cursor so it opens above the pointer.
local EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
local PIN_MENU_ROW_H = 22
local PIN_MENU_WIDTH = 96
local pinPopup

local function CreatePinMenuRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(PIN_MENU_ROW_H)
    row:RegisterForClicks("LeftButtonUp")
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.label = label
    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    icon:Hide()
    row.icon = icon
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    return row
end

-- Hide when the cursor leaves the popup's bounding box. A child row's OnLeave
local function ShowPinPopup(btn, isPinned, onPinAction, onGuide, onAddAlias)
    if not pinPopup then
        pinPopup = CreateFrame("Frame", "EasyFindPinPopup", UIParent, "BackdropTemplate")
        pinPopup:SetFrameStrata("FULLSCREEN_DIALOG")
        pinPopup:SetToplevel(true)
        pinPopup:EnableMouse(true)
        pinPopup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        pinPopup:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])
        pinPopup.guideRow = CreatePinMenuRow(pinPopup)
        pinPopup.guideRow.label:SetText("Guide")
        pinPopup.guideRow.icon:SetTexture(EYE_ICON_TEX)
        pinPopup.guideRow.icon:Show()
        pinPopup.pinRow = CreatePinMenuRow(pinPopup)
        pinPopup.aliasRow = CreatePinMenuRow(pinPopup)
        pinPopup.aliasRow.label:SetText("Add Alias")

        -- Continuous outside-cursor poll: hides the popup once the
        -- cursor has been outside for a short grace window. Combined
        -- with GLOBAL_MOUSE_DOWN/UP for instant click-out dismissal
        -- (with a small post-show grace so the right-click that
        -- opened the popup doesn't immediately close it).
        pinPopup:SetScript("OnShow", function(self)
            self._showedAt = GetTime()
            self._outsideSince = nil
            self._hasEntered = false
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            self:RegisterEvent("GLOBAL_MOUSE_UP")
        end)
        pinPopup:SetScript("OnHide", function(self)
            self._outsideSince = nil
            self._hasEntered = false
            self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            self:UnregisterEvent("GLOBAL_MOUSE_UP")
        end)
        pinPopup:SetScript("OnUpdate", function(self)
            if self:IsMouseOver() then
                self._outsideSince = nil
                self._hasEntered = true
                return
            end
            -- Don't start the outside timer until the cursor has reached
            -- the popup at least once. Otherwise the popup can close
            -- before the user has a chance to move the mouse onto it.
            if not self._hasEntered then return end
            local now = GetTime()
            if not self._outsideSince then
                self._outsideSince = now
                return
            end
            if now - self._outsideSince > 0.3 then
                self:Hide()
            end
        end)
        pinPopup:SetScript("OnEvent", function(self, event)
            if event ~= "GLOBAL_MOUSE_DOWN" and event ~= "GLOBAL_MOUSE_UP" then
                return
            end
            if self._showedAt and (GetTime() - self._showedAt) < 0.05 then
                return
            end
            if not self:IsMouseOver() then
                self:Hide()
            end
        end)
    end

    pinPopup.pinRow:Show()
    pinPopup.pinRow.label:SetText(isPinned and "Unpin" or "Pin")
    pinPopup.pinRow:SetScript("OnClick", function()
        pinPopup:Hide()
        if onPinAction then onPinAction() end
    end)

    -- Stack rows top-to-bottom in this order: Guide (if applicable),
    -- Pin/Unpin, Add Alias (if applicable). Each anchor chains off
    -- the previous visible row so dropping one shifts the rest up.
    local rowsShown = 0
    local lastStackedRow
    local function StackRow(row)
        row:ClearAllPoints()
        if rowsShown == 0 then
            row:SetPoint("TOPLEFT", pinPopup, "TOPLEFT", 4, -4)
            row:SetPoint("TOPRIGHT", pinPopup, "TOPRIGHT", -4, -4)
        else
            row:SetPoint("TOPLEFT", lastStackedRow, "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", lastStackedRow, "BOTTOMRIGHT", 0, 0)
        end
        row:Show()
        rowsShown = rowsShown + 1
        lastStackedRow = row
    end

    if onGuide then
        pinPopup.guideRow:SetScript("OnClick", function()
            pinPopup:Hide()
            onGuide()
        end)
        StackRow(pinPopup.guideRow)
    else
        pinPopup.guideRow:Hide()
        pinPopup.guideRow:SetScript("OnClick", nil)
    end

    StackRow(pinPopup.pinRow)

    if onAddAlias then
        pinPopup.aliasRow:SetScript("OnClick", function()
            pinPopup:Hide()
            onAddAlias()
        end)
        StackRow(pinPopup.aliasRow)
    else
        pinPopup.aliasRow:Hide()
        pinPopup.aliasRow:SetScript("OnClick", nil)
    end

    pinPopup:SetSize(PIN_MENU_WIDTH, PIN_MENU_ROW_H * rowsShown + 8)

    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    pinPopup:ClearAllPoints()
    pinPopup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    pinPopup:Show()
end

-- Centralized icon setter - resets texture state before applying to prevent
-- atlas/texture bleed between rows.
local function SetRowIcon(btn, kind, value, iconSize)
    -- Cache the (kind, value, size) we last applied. The hot path on
    -- every keystroke re-renders rows whose icon hasn't changed at all
    -- (incremental narrowing keeps top-N rows the same), so skipping
    -- the SetTexture / SetAtlas / SetTexCoord burst when nothing
    -- changed is one of the bigger per-keystroke wins.
    local sz = iconSize or 16
    -- Cache key is the raw value (numeric fileID or the full coords
    -- table). Table identity is what we want: two distinct sprite-sheet
    -- entries with the same fileID but different coords are distinct
    -- tables, so they correctly miss the cache.
    if btn._iconKind == kind and btn._iconValKey == value and btn._iconSize == sz then
        if kind == "hidden" then return end
        btn.icon:Show()
        return
    end
    btn._iconKind   = kind
    btn._iconValKey = value
    btn._iconSize   = sz

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
local unearnedTooltip      -- Custom tooltip for unearned currencies
local activeKeybindBtn

-- THEME DEFINITIONS
local THEMES = {}

-- Modern: quest-log style - raised tab headers, golden tree lines, grey border
THEMES["Modern"] = {
    rowHeight       = 22,
    indentPx        = 20,          -- matches INDENT_PX so tree lines align
    lineWidth       = 2,
    resultsWidth    = 350,
    resultsPadTop   = 10,
    resultsPadBot   = 10,
    resultsPadLeft  = 12,
    btnWidth        = 366,
    iconSize        = 16,
    pathIconSize    = 14,
    -- fonts
    pathFont        = ns.SEARCHBAR_FONT,
    leafFont        = ns.LEAF_FONT,
    pathColor       = {0.65, 0.60, 0.55, 1.0},   -- muted gray-tan (normal state)
    pathColorHover  = {1.0, 1.0, 1.0, 1.0},      -- white (hover state)
    leafColor       = {0.9, 0.9, 0.9},           -- light grey items
    -- tree lines - warm gold (single colour at every depth)
    showTreeLines   = true,
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
    showHeaderTab   = true,
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

    -- Prewarm: 3s after login (after dynamic data has finished loading)
    -- run a throwaway search so the first-char inverted index gets
    -- built and the per-bucket scratch tables get allocated. Without
    -- this, the user's first real keystroke pays a 100ms+ cold tax.
    C_Timer.After(3, function()
        if ns.Database and ns.Database.SearchUI then
            ns.Database:SearchUI("zz")
        end
    end)
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
    searchFrame:SetFrameStrata("MEDIUM")
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
    local WHITE8x8 = "Interface\\BUTTONS\\WHITE8x8"
    ns.CreateSearchBorder(searchFrame)

    -- Combined visual frame: 9-slice rounded rect that morphs from a
    -- pill (results closed: height == bar height) to a rounded
    -- rectangle (results open: height == bar height + results panel
    -- height). Sibling of searchFrame at the same frame level - 1 so
    -- its draw layers sit behind the bar's content; anchored to
    -- searchFrame so it follows movement / resizing.
    containerFrame = CreateFrame("Frame", "EasyFindContainerFrame", UIParent)
    UI.containerFrame = containerFrame
    containerFrame:SetFrameStrata("MEDIUM")
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
    -- Kept for Demo.lua / legacy references; no longer a clickable toggle.
    searchFrame.modeBtn = iconHolder
    -- No-op shim so legacy pcalls from Demo.lua succeed.
    ns.UpdateModeButtonVisual = ns.UpdateModeButtonVisual or function() end

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
        if escCatcher then escCatcher:Hide() end
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
                if g and g:IsShown() and g:IsMouseOver() then
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

    local pendingUISearchTimer
    local lastTypedLen = 0
    local lastSearchTime = 0
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
        historyIndex = 0
        historyDraft = ""
        if pendingUISearchTimer then pendingUISearchTimer:Cancel() end
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
        pendingUISearchTimer = C_Timer.NewTimer(delay, function()
            pendingUISearchTimer = nil
            lastSearchTime = GetTime()
            UI:OnSearchTextChanged(typedNow)
            if grew and editBox.UpdateAutocomplete then
                editBox.UpdateAutocomplete()
            end
        end)
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

    editBox:SetScript("OnEscapePressed", function(self)
        if UI:CloseFilterDropdownIfOpen() then
            self:SetFocus()
            return
        end
        if self:GetText() == "" then
            UI:Hide()
            return
        end
        self:SetText("")
        self.placeholder:Show()
        UI:HideResults()
    end)

    -- Chrome-style inline autocomplete: same helper MapTab uses.
    -- Attached AFTER all SetScript calls above so HookScript-based
    -- handlers don't get clobbered. The candidate source is the first
    -- visible result row name, so the suggested completion always
    -- aligns with what the user lands on if they press Enter.
    Utils.AttachAutocomplete(editBox, {
        findCandidate = function(typed)
            if not typed or typed == "" then return nil end
            local lower = typed:lower()
            for i = 1, MAX_BUTTON_POOL do
                local row = resultButtons[i]
                if not row or not row:IsShown() then break end
                local nm = row.data and row.data.name
                if nm and #nm >= #typed then
                    local prefix = nm:sub(1, #typed):lower()
                    if prefix == lower and nm:lower() ~= lower then
                        return nm
                    end
                end
            end
            return nil
        end,
    })

    -- After Tab confirms an autocomplete suggestion, re-run the search
    -- so the result list reflects the now-full text. Without this the
    -- visible results stay on the original typed prefix even though the
    -- editbox shows the confirmed candidate.
    editBox:HookScript("OnTabPressed", function(self)
        local current = self:GetText() or ""
        if current == "" then return end
        UI:OnSearchTextChanged(current, true)
    end)

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
            if UI:CloseFilterDropdownIfOpen() then
                if searchFrame and searchFrame.editBox then
                    searchFrame.editBox:SetFocus()
                end
            elseif toolbarFocus > 0 then
                ClearToolbarFocus()
                if selectedIndex == 0 then
                    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                end
            elseif toggleFocused then
                toggleFocused = false
                UI:UpdateSelectionHighlight()
            else
                selectedIndex = 0
                toggleFocused = false
                Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
                UI:UpdateSelectionHighlight(true)
            end
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
            if rd and (rd.outfitID or rd.toyItemID or rd.spellID
               or rd.mountID or rd.macroIndex
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

    -- UISpecialFrames fallback: WoW closes these on ESC before opening the
    -- game menu.  Shown after the editbox loses focus with results visible so
    -- the next ESC clears+closes instead of toggling the game menu.
    escCatcher = CreateFrame("Frame", "EasyFindEscCatcher", searchFrame)
    escCatcher:SetSize(1, 1)
    escCatcher:Hide()
    tinsert(UISpecialFrames, "EasyFindEscCatcher")
    escCatcher:SetScript("OnHide", function()
        if searchFrame.editBox:HasFocus() then return end
        if not resultsFrame or not resultsFrame:IsShown() then return end
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
        selectedIndex = 0
        toggleFocused = false
        searchFrame.editBox:SetText("")
        searchFrame.editBox.placeholder:Show()
        UI:HideResults()
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
    end)
    searchFrame:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    searchFrame:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not EasyFind.db.autoHide then return end
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
                if g and g:IsShown() and g:IsMouseOver() then return end
            end
        end
        local extras = {
            _G["EasyFindPinPopup"],
            _G["EasyFindUIWizard"],
        }
        for _, g in ipairs(extras) do
            if g and g:IsShown() and g:IsMouseOver() then return end
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
      iconCoords = { 0.904, 0.996, 0.707, 0.748 } },
    { key = "achievements", label = "Achievements", iconAtlas = "UI-HUD-MicroMenu-Achievements-Up" },
    { key = "bags",        label = "Bags",        iconAtlas = "bag-main" },
    -- Bosses: EJ overview tab icon from texture 522972.
    { key = "bosses",      label = "Bosses",      iconTex = 522972,
      iconCoords = { 0.855, 0.949, 0.524, 0.566 } },
    { key = "macros",      label = "Macros",      iconTex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    { key = "collections",  label = "Collections",  iconAtlas = "UI-HUD-MicroMenu-Collections-Up",
      flyoutSubFilters = {
          { key = "appearanceSets", label = "Appearance Sets", iconTex = "Interface\\Icons\\INV_Helmet_03", hasOptions = true },
          { key = "gearSets",       label = "Gear Sets",       iconAtlas = "equipmentmanager-spec-border" },
          { key = "heirlooms",      label = "Heirlooms",       iconTex = 133877 },
          { key = "mounts",         label = "Mounts",          iconTex = 132261 },
          { key = "outfits",        label = "Outfits",         iconTex = 132649 },
          { key = "pets",           label = "Pets",            iconTex = 631719 },
          { key = "toys",           label = "Toys",            iconTex = 454046 },
      } },
    { key = "currencies",  label = "Currencies",  iconTex = 136452 },
    -- Gear: treasure-chest icon from the Encounter Journal loot tab
    -- spritesheet (texture 522972) for visual consistency with the
    -- in-game loot UI.
    { key = "loot",        label = "Gear",        iconTex = 522972,
      iconCoords = { 0.730, 0.824, 0.618, 0.660 } },
    { key = "map",         label = "Map Search",  iconTex = 1121272,
      iconCoords = { 0.3457, 0.3856, 0.2549, 0.2951 } },
    { key = "options",     label = "Options",     iconTex = 1121272,
      iconCoords = { 0.4451, 0.4705, 0.8079, 0.8344 },
      flyoutSubFilters = {
          { key = "gameOptions",  label = "Game Options",  iconAtlas = "QuestLog-icon-setting" },
          { key = "addonOptions", label = "AddOn Options", iconAtlas = "QuestLog-icon-setting", iconColor = { 1.0, 0.78, 0.35 } },
      } },
    { key = "reputations", label = "Reputations", iconTex = 1121272,
      iconCoords = { 0.3783, 0.4072, 0.9066, 0.9350 } },
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
    ["Achievements"]       = "achievements",
    ["Guild Achievements"] = "achievements",
    ["Statistics"]         = "achievements",
    ["Currency"]           = "currencies",
    ["Reputation"]         = "reputations",
    ["Bag"]                = "bags",
    ["Macro"]              = "macros",
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
        if ns.Database and ns.Database.PopulateDynamicTransmogSets then
            ns.Database:PopulateDynamicTransmogSets()
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
                self:Hide()
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
        -- indicator used elsewhere in the WoW UI.
        if opt.flyoutSubFilters then
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
                    EasyFind.db.uiSearchFilters[sub.key] = self:GetChecked()
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
            popup:SetSize(SUB_POPUP_WIDTH, SUB_PAD * 2 + #opt.flyoutSubFilters * SUB_ROW_H)

            -- Sync sub-row checked state from current DB values.
            local function SyncSubChecks()
                local f = EasyFind.db.uiSearchFilters
                for _, sub in ipairs(opt.flyoutSubFilters) do
                    local sr = subRows[sub.key]
                    if sr then sr:SetChecked(f[sub.key] ~= false) end
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
                -- Slam any sibling flyout shut on entry so quickly
                -- moving between adjacent flyout rows can't paint two
                -- popups on top of each other (the 0.15s grace timer
                -- would otherwise leave the previous one hanging).
                for _, sibling in ipairs(dropdown.flyoutPopups or {}) do
                    if sibling ~= popup and sibling:IsShown() then
                        sibling:Hide()
                    end
                end
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

        -- Map Search: was a local/global radio pair, but the MapTab
        -- model shows both scopes together and that's what UI search
        -- now does too — the toggle above is just on/off.

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

                subRow:SetScript("OnClick", function(self)
                    EasyFind.db[sub.dbKey] = self:GetChecked()
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
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
                    if ns.Database and ns.Database.PopulateDynamicLoot then
                        ns.Database:PopulateDynamicLoot()
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
                    if ns.Database.PopulateDynamicLoot then
                        ns.Database:PopulateDynamicLoot()
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
                    if sr.dbKey and sr.SetChecked then
                        sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
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
            self:Hide()
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
        ForEachFilterKey(function(key)
            if filters[key] ~= false then allUnchecked = false end
        end)
        local newState = allUnchecked
        ForEachFilterKey(function(key)
            filters[key] = newState
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
            if changed and ns.Database.PopulateDynamicTransmogSets then
                ns.Database:PopulateDynamicTransmogSets()
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
            if searchFrame.editBox and not searchFrame.editBox:IsMouseOver() then
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
        if self._demoSuspend then return end
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
    -- Expose the checkRows table so the demo system can hover/click
    -- specific filter rows (e.g., "map") by key without duplicating the
    -- layout logic.
    dropdown.checkRows = checkRows
end

function UI:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", searchFrame, "BackdropTemplate")
    resultsFrame:SetWidth(380)  -- Wide to accommodate tree indentation
    resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 2)
    resultsFrame:SetFrameStrata("MEDIUM")
    resultsFrame:SetFrameLevel(searchFrame:GetFrameLevel() + 1)

    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })

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
            if g and g:IsShown() and g:IsMouseOver() then return end
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

    -- Plain ScrollFrame for clipping + mouse wheel
    local scrollFrame = CreateFrame("ScrollFrame", nil, resultsFrame)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(mmax(0, mmin(range, cur - delta * 72)))
    end)
    resultsFrame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    resultsFrame.scrollChild = scrollChild

    -- Minimal retail-style scrollbar (overlays right edge, no content squish)
    resultsFrame.scrollBar = ns.Utils.CreateMinimalScrollBar(scrollFrame, resultsFrame)

    for i = 1, MAX_BUTTON_POOL do
        local resultRow = self:CreateResultButton(i)
        resultButtons[i] = resultRow
    end

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
local MAX_DEPTH  = #INDENT_COLORS

-- Session-only collapse state for path nodes (cleared on every new search)
local collapsedNodes = {}   -- key = "name_depth", value = true
local cachedHierarchical    -- last full hierarchical list for re-rendering after toggle
local expandedContainers = {}  -- tracks which containers have had children injected

-- Reusable tables for grouping results (wiped each search to avoid per-keystroke allocations)
local groupUI, groupMounts, groupToys, groupPets, groupOutfits, groupLoot, groupAppearanceSets, groupMap = {}, {}, {}, {}, {}, {}, {}, {}
local groupAchievements, groupCurrencies, groupReputations = {}, {}, {}
local groupBags, groupOptions = {}, {}
local groupHeirlooms = {}
local uiSectionHeader = {
    name = "UI Elements", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local achievementSectionHeader = {
    name = "Achievements", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local currencySectionHeader = {
    name = "Currencies", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local reputationSectionHeader = {
    name = "Reputations", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local mountSectionHeader = {
    name = "Mounts", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local toySectionHeader = {
    name = "Toys", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local petSectionHeader = {
    name = "Pets", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local outfitSectionHeader = {
    name = "Outfits", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local heirloomSectionHeader = {
    name = "Heirlooms", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local lootSectionHeader = {
    name = "Gear", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local appearanceSetSectionHeader = {
    name = "Appearance Sets", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local mapSectionHeader = {
    name = "Map Search", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local bagsSectionHeader = {
    name = "Bags", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local optionsSectionHeader = {
    name = "Game Options", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}

-- Flat-list mode scratch: reused entry pool keeps per-keystroke allocations
-- low when uiHideHeaders is on. flatEntries holds recyclable entry tables;
-- flatCombined is the merged-results buffer that gets sorted by score.
local flatEntries = {}
local flatCombined = {}

local PB = {
    ui = {}, ach = {}, cur = {}, rep = {},
    mounts = {}, toys = {}, pets = {},
    outfits = {}, loot = {}, appsets = {},
    bags = {}, options = {}, heirlooms = {},
}

local SCRATCH = {
    visible = {},
    isLastChild = {},
    catSepYPositions = {},
    bestCatScore = {},
    catGroups = {},
}

local function CatGroupCompare(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.key < b.key
end

local function BuildBucketInto(group, bucketResults)
    if #bucketResults == 0 then return end
    local hier = ns.Database:BuildHierarchicalResults(bucketResults)
    for hi = 1, #hier do
        local entry = hier[hi]
        if entry.isContainer then
            collapsedNodes[entry.name .. "_" .. (entry.depth or 0)] = true
        end
        group[#group + 1] = entry
    end
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

-- Expand a container node: inject its database children into cachedHierarchical.
local function ExpandContainer(entry, entryIndex)
    if not entry or not entry.data or not entry.isContainer then return end
    local key = entry.name .. "_" .. (entry.depth or 0)
    if expandedContainers[key] then return end  -- already expanded

    local children = ns.Database:GetContainerChildren(entry.data)
    if #children == 0 then return end

    local childDepth = (entry.depth or 0) + 1
    -- Build child entries and insert right after the container in cachedHierarchical
    local toInsert = {}
    for _, childData in ipairs(children) do
        -- Check if this child is itself a container
        local childIsContainer = false
        local fp = {}
        if childData.path then
            for _, p in ipairs(childData.path) do fp[#fp + 1] = p end
        end
        fp[#fp + 1] = childData.name
        -- Quick check: any item in the DB has this as a path prefix?
        for _, dbItem in ipairs(ns.Database.uiSearchData or {}) do
            if dbItem.path then
                local match = true
                for i = 1, #fp do
                    if not dbItem.path[i] or dbItem.path[i] ~= fp[i] then
                        match = false; break
                    end
                end
                if match and #dbItem.path >= #fp then
                    childIsContainer = true; break
                end
            end
        end

        toInsert[#toInsert + 1] = {
            name = childData.name,
            depth = childDepth,
            isPathNode = childIsContainer,
            data = childData,
            isContainer = childIsContainer or nil,
        }
        -- Start child containers collapsed too
        if childIsContainer then
            collapsedNodes[childData.name .. "_" .. childDepth] = true
        end
    end

    -- Insert after entryIndex
    for i = #toInsert, 1, -1 do
        tinsert(cachedHierarchical, entryIndex + 1, toInsert[i])
    end

    expandedContainers[key] = true
    entry.isContainer = nil  -- no longer needs lazy expansion
end

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

    -- Retail theme: full-width dark gradient behind headers (Event Schedule style)
    local headerGrad = resultRow:CreateTexture(nil, "BACKGROUND", nil, 1)
    headerGrad:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
    headerGrad:SetBlendMode("ADD")
    headerGrad:SetVertexColor(0.35, 0.27, 0.08, 0.6)
    headerGrad:SetAllPoints()
    headerGrad:Hide()
    resultRow.headerGrad = headerGrad

    -- Thin horizontal separator line at the bottom of each row
    local separator = resultRow:CreateTexture(nil, "ARTWORK", nil, 0)
    separator:SetColorTexture(0.5, 0.45, 0.3, 0.3)
    separator:SetHeight(1)
    separator:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 4, 0)
    separator:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 0)
    separator:Hide()
    resultRow.separator = separator

    -- Retail: raised tab header (quest-log style with atlas textures)
    local headerTab = CreateFrame("Button", nil, resultRow)
    headerTab:SetAllPoints()
    headerTab:RegisterForClicks("LeftButtonUp")
    headerTab:SetScript("OnClick", function(self, mouseButton)
        local row = self:GetParent()
        if mouseButton == "RightButton" then
            local postClick = row:GetScript("PostClick")
            if postClick then postClick(row, mouseButton) end
            return
        end
        if row.data then
            UI:SelectResult(row.data)
        end
    end)
    headerTab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    headerTab:Hide()
    resultRow.headerTab = headerTab

    -- Background texture using QuestLog-tab atlas
    local tabBg = headerTab:CreateTexture(nil, "BACKGROUND")
    tabBg:SetAllPoints()
    tabBg:SetAtlas("QuestLog-tab")
    resultRow.tabBg = tabBg

    -- Hover overlay: same atlas, additive blend, manually shown/hidden
    local tabHoverOverlay = headerTab:CreateTexture(nil, "ARTWORK", nil, -1)
    tabHoverOverlay:SetAllPoints()
    tabHoverOverlay:SetAtlas("QuestLog-tab")
    tabHoverOverlay:SetBlendMode("ADD")
    tabHoverOverlay:SetAlpha(0.40)
    tabHoverOverlay:Hide()
    resultRow.tabHoverOverlay = tabHoverOverlay

    -- +/- toggle button on right side (filter-button style)
    local toggleBtn = CreateFrame("Button", nil, headerTab)
    toggleBtn:SetSize(26, 25)
    toggleBtn:SetPoint("RIGHT", headerTab, "RIGHT", -8, 0)
    toggleBtn:SetFrameLevel(headerTab:GetFrameLevel() + 2)
    toggleBtn:RegisterForClicks("LeftButtonUp")
    toggleBtn:SetScript("OnClick", function(self)
        local row = self:GetParent():GetParent()
        if row.isPinHeader then
            EasyFind.db.pinsCollapsed = not EasyFind.db.pinsCollapsed
            if cachedHierarchical then
                UI:ShowHierarchicalResults(cachedHierarchical, true)
            end
        elseif row.isPathNode then
            local key = (row.pathNodeName or "") .. "_" .. (row.pathNodeDepth or 0)
            local wasCollapsed = collapsedNodes[key]
            collapsedNodes[key] = not collapsedNodes[key]
            if wasCollapsed and row._containerEntry and cachedHierarchical then
                for idx, entry in ipairs(cachedHierarchical) do
                    if entry == row._containerEntry then
                        ExpandContainer(entry, idx)
                        break
                    end
                end
            end
            if cachedHierarchical then
                UI:ShowHierarchicalResults(cachedHierarchical, true)
            end
        else
            return
        end
        -- Rebuild repurposes rows, clearing visual state. Re-show btnBg
        -- for whichever toggleBtn is now under the cursor.
        for i = 1, MAX_BUTTON_POOL do
            local rb = resultButtons[i]
            if rb and rb.toggleBtn and rb.toggleBtn:IsMouseOver() then
                rb.toggleBtn.btnBg:Show()
                break
            end
        end
    end)

    local toggleBtnBg = toggleBtn:CreateTexture(nil, "ARTWORK")
    toggleBtnBg:SetAllPoints()
    toggleBtnBg:SetTexture(796424)
    toggleBtnBg:Hide()
    toggleBtn.btnBg = toggleBtnBg

    local toggleIcon = toggleBtn:CreateTexture(nil, "OVERLAY")
    toggleIcon:SetSize(18, 17)
    toggleIcon:SetPoint("CENTER")
    toggleIcon:SetAtlas("QuestLog-icon-expand")
    resultRow.toggleIcon = toggleIcon

    toggleBtn:SetHighlightTexture(130757)
    toggleBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        local row = self:GetParent():GetParent()
        if row.tabHoverOverlay then row.tabHoverOverlay:Show() end
        if row.tabText then row.tabText:SetTextColor(0.90, 0.88, 0.85, 1.0) end
    end)
    toggleBtn:SetScript("OnLeave", function(self)
        self.btnBg:Hide()
        local row = self:GetParent():GetParent()
        if not self:GetParent():IsMouseOver() then
            if row.tabHoverOverlay then row.tabHoverOverlay:Hide() end
            if row.tabText then
                if row._isMatch then
                    row.tabText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)
                else
                    row.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0)
                end
            end
        end
    end)
    resultRow.toggleBtn = toggleBtn

    local toggleHighlight = headerTab:CreateTexture(nil, "OVERLAY")
    toggleHighlight:SetSize(26, 25)
    toggleHighlight:SetPoint("CENTER", toggleBtn, "CENTER", 0, 0)
    toggleHighlight:SetColorTexture(0.3, 0.6, 1.0, 0.4)
    toggleHighlight:Hide()
    resultRow.toggleHighlight = toggleHighlight

    -- Header name text (child of headerTab)
    local tabText = headerTab:CreateFontString(nil, "OVERLAY", "Game15Font_Shadow")
    tabText:SetPoint("LEFT", headerTab, "LEFT", 10, 0)
    tabText:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)
    tabText:SetJustifyH("LEFT")
    tabText:SetMaxLines(1)
    tabText:SetTextColor(0.60, 0.58, 0.55, 1.0)    -- muted gray (normal state)
    resultRow.tabText = tabText

    -- Hover handlers: brighten tab bg, text near-white, icon bright yellow
    headerTab:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        if parent.tabHoverOverlay then
            parent.tabHoverOverlay:Show()
        end
        if parent.tabText then
            parent.tabText:SetTextColor(0.90, 0.88, 0.85, 1.0)  -- soft white (slightly muted)
        end
        -- Show tooltip for unearned currencies
        if parent.isUnearnedCurrency and unearnedTooltip then
            local tooltipText = parent.isPathNode and "This tab does not exist on this character yet" or "Currency not yet earned"
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
    end)
    headerTab:SetScript("OnLeave", function(self)
        local parent = self:GetParent()
        if parent.tabHoverOverlay then
            parent.tabHoverOverlay:Hide()
        end
        if parent.tabText then
            if parent._isMatch then
                parent.tabText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)   -- back to gold
            else
                parent.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0) -- back to gray
            end
        end
        -- Hide tooltip for unearned currencies
        if unearnedTooltip then
            unearnedTooltip:Hide()
        end
    end)

    -- Tab selection highlight (keyboard nav, child of headerTab)
    local tabSelTex = headerTab:CreateTexture(nil, "BACKGROUND")
    tabSelTex:SetAllPoints()
    tabSelTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    tabSelTex:SetBlendMode("ADD")
    tabSelTex:SetVertexColor(0.3, 0.6, 1.0, 0.4)
    tabSelTex:Hide()
    resultRow.tabSelectionHighlight = tabSelTex

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
        local applied = false
        if Settings and Settings.GetSetting then
            local sok, settObj = pcall(Settings.GetSetting, variable)
            if sok and settObj and settObj.SetValue then
                pcall(settObj.SetValue, settObj, newVal)
                applied = true
            end
        end
        if not applied and SetCVar then
            SetCVar(variable, newVal)
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
        if valText then
            if newVal == mfloor(newVal) then
                valText:SetText(tostring(mfloor(newVal)))
            else
                valText:SetText(sformat("%.2f", newVal))
            end
        end
    end)
    resultRow.settingSlider = settingSlider

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

    local settingSliderValue = sliderGroup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    settingSliderValue:SetPoint("BOTTOM", sliderGroup, "TOP", 0, -2)
    settingSliderValue:SetTextColor(0.7, 0.7, 0.7, 1.0)
    settingSliderValue:SetShadowOffset(1, -1)
    resultRow.settingSliderValue = settingSliderValue

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
            end, onGuide, onAddAlias)
            return
        end

        -- Don't allow clicking unearned currencies
        if self.isUnearnedCurrency then
            return
        end

        -- Setting click: keep the search panel open so the user can
        -- adjust multiple settings, retest, retoggle, etc. without
        -- having to reopen the search.
        --   Checkbox: toggle inline (no need to open the panel at all).
        --   Slider: the inline slider widget IS the editor; row click
        --     is a no-op so dragging the slider doesn't also fire a
        --     row click that opens the panel.
        --   Dropdown / other: open the Settings panel for editing but
        --     leave the search results visible underneath.
        if self.data and self.data.settingType == "keybind" and self.data.bindingAction then
            -- Keybind row: the inline kb1/kb2 buttons own the click and
            -- manage their own keyboard capture (via blockFocus on the
            -- editbox). A bare row click does nothing here; refocusing
            -- the editbox would clear blockFocus mid-capture and hand
            -- the next keystroke to the search bar instead of the bind.
            return
        end
        if self.data and self.data.settingVariable then
            local stype = self.data.settingType
            if stype == "checkbox" then
                UI:ToggleSettingCheckbox(self.data)
            elseif stype == "slider" then
                -- Slider widget handles its own drag/click. The row
                -- still receives a "click" because the slider is a
                -- child, so refocus the editbox to keep results open
                -- (OnEditFocusLost would otherwise hide them).
                if searchFrame and searchFrame.editBox
                   and not (navFrame and navFrame:IsKeyboardEnabled()) then
                    searchFrame.editBox.blockFocus = nil
                    searchFrame.editBox:SetFocus()
                end
            elseif stype == "dropdown" then
                -- Cycle to the next dropdown value inline. Falls back to
                -- opening the panel only if we can't enumerate options
                -- (variable not found in any live category layout).
                if not UI:CycleSettingDropdown(self.data) then
                    UI:OpenSettingNoClose(self.data)
                end
            else
                UI:OpenSettingNoClose(self.data)
            end
            return
        end

        -- Pin header: toggle collapse
        if self.isPinHeader then
            EasyFind.db.pinsCollapsed = not EasyFind.db.pinsCollapsed
            if cachedHierarchical then
                UI:ShowHierarchicalResults(cachedHierarchical, true)
            end
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
                    local wasCollapsed = collapsedNodes[key]
                    collapsedNodes[key] = not collapsedNodes[key]
                    if wasCollapsed and self._containerEntry and cachedHierarchical then
                        for idx, entry in ipairs(cachedHierarchical) do
                            if entry == self._containerEntry then
                                ExpandContainer(entry, idx)
                                break
                            end
                        end
                    end
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
        -- Keybinding row: show the action name plus current bindings.
        if self.data and self.data.settingType == "keybind" and self.data.bindingAction then
            local action = self.data.bindingAction
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
                    local valStr = (n == mfloor(n)) and tostring(mfloor(n)) or sformat("%.2f", n)
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
            -- Mount tooltip (show on icon hover)
            if self.icon.mountID and self.icon.spellID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetMountBySpellID(self.icon.spellID)
                GameTooltip:Show()
            -- Toy tooltip with live cooldown refresh
            elseif self.icon.toyItemID then
                local toyItemID = self.icon.toyItemID
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
                    BattlePetToolTip_ShowLink(link)
                elseif link then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(link)
                    GameTooltip:Show()
                end
            -- Outfit tooltip
            elseif self.icon.outfitID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local itemLink = self.data and ns.Database and ns.Database:GetLootItemLink(self.data)
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(self.icon.lootItemID)
                end
                GameTooltip:Show()
            -- Heirloom tooltip
            elseif self.icon.heirloomItemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.icon.heirloomItemID)
                GameTooltip:Show()
            -- Ability tooltip (must come after mount, since mount entries
            -- carry both mountID and spellID and use the mount tooltip).
            elseif self.icon.spellID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if GameTooltip.SetSpellByID then
                    GameTooltip:SetSpellByID(self.icon.spellID)
                else
                    GameTooltip:SetHyperlink("spell:" .. self.icon.spellID)
                end
                GameTooltip:Show()
            -- Bag item tooltip
            elseif self.icon.bagItemID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
    if not text or text == "" then
        -- Only show pins if the editbox still has focus (avoid re-showing
        -- after SelectResult clears the text)
        if searchFrame and searchFrame.editBox and searchFrame.editBox:HasFocus() then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    -- Clear collapse state so every new search starts fully expanded
    collapsedNodes = {}
    expandedContainers = {}

    if ns.Database.ResetHierEntryPool then
        ns.Database:ResetHierEntryPool()
    end

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
        local gearSetsOff = collectionsOff or filters.gearSets == false
        if mountsOff or toysOff or petsOff or outfitsOff or lootOff
           or appsetsOff or bagsOff or macrosOff or gameOptOff or addonOptOff
           or abilitiesOff or bossesOff or heirloomsOff or titlesOff or gearSetsOff then
            skipCategories = {}
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
            local seen = {}
            for _, r in ipairs(results) do seen[r.data] = true end
            for i = #aliasMatches, 1, -1 do
                local hit = aliasMatches[i]
                if not seen[hit.data] then
                    tinsert(results, 1, { data = hit.data, score = math.huge, isAlias = true })
                    seen[hit.data] = true
                end
            end
        end
    end

    -- Bucket-aware UI filter: drop UI entries whose bucket
    -- (ui / abilities / achievements / currencies / reputations / bags
    -- / options) is unchecked. Options is a parent toggle: when off,
    -- both gameOptions and addonOptions buckets are treated as off.
    if filters and (filters.ui == false or filters.abilities == false
                    or filters.bosses == false
                    or filters.achievements == false
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false) then
        local filtered = {}
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r.isAlias then
                fi = fi + 1
                filtered[fi] = r
            else
                local bucket = GetUIBucket(r.data)
                local bucketOff = bucket and filters[bucket] == false
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                if not bucket or (not bucketOff and not parentOff) then
                    fi = fi + 1
                    filtered[fi] = r
                end
            end
        end
        results = filtered
    end

    -- Map Search: search static locations and dungeon entrances, merge into results
    local mapResults
    if filters and filters.map ~= false and ns.MapSearch and ns.MapSearch.SearchForUI then
        mapResults = ns.MapSearch:SearchForUI(text)
    end

    wipe(SCRATCH.bestCatScore)
    local bestCatScore = SCRATCH.bestCatScore
    for ri = 1, #results do
        local r = results[ri]
        local d = r.data
        local s = r.score or 0
        local cat
        if d.mountID then cat = "mounts"
        elseif d.toyItemID then cat = "toys"
        elseif d.petID then cat = "pets"
        elseif d.outfitID then cat = "outfits"
        elseif d.heirloomItemID then cat = "heirlooms"
        elseif d.itemID and d.category == "Loot" then cat = "loot"
        elseif d.transmogSetID then cat = "appearanceSets"
        else cat = GetUIBucket(d) or "ui"
        end
        if s > (bestCatScore[cat] or 0) then bestCatScore[cat] = s end
    end
    if mapResults then
        for ri = 1, #mapResults do
            local s = mapResults[ri].score or 0
            if s > (bestCatScore.map or 0) then bestCatScore.map = s end
        end
    end
    -- Boost loot category when the query exactly matches a slot name (e.g., "legs", "ring")
    if bestCatScore.loot and ns.lootSlotNames then
        local queryLower = slower(text)
        if ns.lootSlotNames[queryLower] then
            bestCatScore.loot = mmax(bestCatScore.loot, 200)
        end
    end

    local hideHeaders = EasyFind.db.uiHideHeaders
    local hierarchical
    if hideHeaders then
        -- Flat-list mode: single score-sorted list. UI results, map
        -- results, collections, settings — everything gets ranked
        -- together purely on score. Category clustering (used to
        -- live here) hid genuinely better matches behind weaker ones
        -- in higher-priority buckets, e.g. a name-prefix UI hit
        -- lost to a same-bucket map result that only matched via
        -- initials, because the map bucket sorted alphabetically
        -- by zone before yielding to the next bucket.
        wipe(flatCombined)
        local combined = flatCombined
        for ri = 1, #results do combined[#combined + 1] = results[ri] end
        if mapResults then
            for ri = 1, #mapResults do combined[#combined + 1] = mapResults[ri] end
        end
        if #combined > 1 then tsort(combined, FlatNameLess) end

        local n = 0
        for ri = 1, #combined do
            n = n + 1
            local e = flatEntries[n]
            if not e then
                e = {}
                flatEntries[n] = e
            end
            local d = combined[ri].data
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.data = d
        end
        for i = n + 1, #flatEntries do
            flatEntries[i] = nil
        end
        hierarchical = flatEntries
    else

    local pb = PB
    wipe(pb.ui); wipe(pb.ach); wipe(pb.cur); wipe(pb.rep)
    wipe(pb.mounts); wipe(pb.toys); wipe(pb.pets)
    wipe(pb.outfits); wipe(pb.loot); wipe(pb.appsets)
    wipe(pb.bags); wipe(pb.options); wipe(pb.heirlooms)
    for ri = 1, #results do
        local r = results[ri]
        local d = r.data
        if d.mountID then
            pb.mounts[#pb.mounts + 1] = r
        elseif d.toyItemID then
            pb.toys[#pb.toys + 1] = r
        elseif d.petID then
            pb.pets[#pb.pets + 1] = r
        elseif d.outfitID then
            pb.outfits[#pb.outfits + 1] = r
        elseif d.heirloomItemID then
            pb.heirlooms[#pb.heirlooms + 1] = r
        elseif d.itemID and d.category == "Loot" then
            pb.loot[#pb.loot + 1] = r
        elseif d.transmogSetID then
            pb.appsets[#pb.appsets + 1] = r
        else
            local bucket = UI_BUCKET_BY_CATEGORY[d.category]
            if bucket == "achievements" then
                pb.ach[#pb.ach + 1] = r
            elseif bucket == "currencies" then
                pb.cur[#pb.cur + 1] = r
            elseif bucket == "reputations" then
                pb.rep[#pb.rep + 1] = r
            elseif bucket == "bags" then
                pb.bags[#pb.bags + 1] = r
            elseif bucket == "options" then
                pb.options[#pb.options + 1] = r
            else
                pb.ui[#pb.ui + 1] = r
            end
        end
    end

    -- Reuse module-level group tables to hold the per-bucket hierarchies.
    wipe(groupUI); wipe(groupAchievements); wipe(groupCurrencies); wipe(groupReputations)
    wipe(groupMounts); wipe(groupToys); wipe(groupPets)
    wipe(groupOutfits); wipe(groupLoot); wipe(groupAppearanceSets); wipe(groupMap)
    wipe(groupBags); wipe(groupOptions); wipe(groupHeirlooms)

    BuildBucketInto(groupUI,           pb.ui)
    BuildBucketInto(groupAchievements, pb.ach)
    BuildBucketInto(groupCurrencies,   pb.cur)
    BuildBucketInto(groupReputations,  pb.rep)
    BuildBucketInto(groupBags,         pb.bags)
    BuildBucketInto(groupOptions,      pb.options)
    BuildBucketInto(groupMounts,       pb.mounts)
    BuildBucketInto(groupToys,         pb.toys)
    BuildBucketInto(groupPets,         pb.pets)
    BuildBucketInto(groupOutfits,      pb.outfits)
    BuildBucketInto(groupHeirlooms,    pb.heirlooms)
    BuildBucketInto(groupLoot,         pb.loot)
    BuildBucketInto(groupAppearanceSets, pb.appsets)
    -- Keep `hierarchical` defined for the rest of the function;
    -- it gets rebuilt below by appending each section in catGroups order.
    hierarchical = nil

    -- Map results: group by top-ancestor continent so parent/children
    -- nest with collapsible headers (matches MapTab's layout). A group
    -- with only one entry renders flat — no point wrapping a single
    -- result in its own header. Groups with the parent zone itself as
    -- a match promote the parent entry to the header's navigate target.
    if mapResults then
        local getAncestor = ns.MapTab and ns.MapTab.GetTopAncestor
        if not getAncestor then
            -- Fallback if MapTab isn't loaded yet (unlikely but safe).
            for _, r in ipairs(mapResults) do
                groupMap[#groupMap + 1] = {
                    name = r.data.name, depth = 1,
                    isPathNode = false, isMatch = true, data = r.data,
                }
            end
        else
            local groupsByAncestor = {}
            local ancestorOrder = {}
            for _, r in ipairs(mapResults) do
                local d = r.data
                local mapID = d.mapID or d.zoneMapID or d.entranceMapID
                local ancestor = mapID and getAncestor(ns.MapTab, mapID)
                if not ancestor or ancestor == "" then ancestor = "Other" end
                local g = groupsByAncestor[ancestor]
                if not g then
                    g = { items = {}, bestScore = 0, selfMatch = nil }
                    groupsByAncestor[ancestor] = g
                    ancestorOrder[#ancestorOrder + 1] = ancestor
                end
                -- Detect "the zone IS its own top ancestor" (Eastern
                -- Kingdoms matching while all its child zones also
                -- match) so the parent header can point at it rather
                -- than a synthesized one.
                if d.name == ancestor and d.isZone then
                    g.selfMatch = r
                else
                    g.items[#g.items + 1] = r
                end
                local s = r.score or 0
                if s > g.bestScore then g.bestScore = s end
            end
            for _, ancestor in ipairs(ancestorOrder) do
                local g = groupsByAncestor[ancestor]
                local total = #g.items + (g.selfMatch and 1 or 0)
                if total > 1 then
                    -- Parent header, then children at depth 2
                    local headerData = g.selfMatch and g.selfMatch.data
                        or { name = ancestor, mapSearchResult = true, isZone = true }
                    groupMap[#groupMap + 1] = {
                        name = ancestor, depth = 1,
                        isPathNode = true, isMatch = true,
                        data = headerData,
                    }
                    for _, r in ipairs(g.items) do
                        groupMap[#groupMap + 1] = {
                            name = r.data.name, depth = 2,
                            isPathNode = false, isMatch = true,
                            data = r.data,
                        }
                    end
                else
                    -- Single-item group: render flat, no wrapping header.
                    local r = g.selfMatch or g.items[1]
                    if r then
                        groupMap[#groupMap + 1] = {
                            name = r.data.name, depth = 1,
                            isPathNode = false, isMatch = true,
                            data = r.data,
                        }
                    end
                end
            end
        end
    end
    -- Sort categories by best match score so the most relevant category appears first
    wipe(SCRATCH.catGroups)
    local catGroups = SCRATCH.catGroups
    local n = 0
    if #groupUI > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "ui"; g.score = bestCatScore.ui or 0 end
    if #groupAchievements > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "achievements"; g.score = bestCatScore.achievements or 0 end
    if #groupCurrencies > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "currencies"; g.score = bestCatScore.currencies or 0 end
    if #groupReputations > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "reputations"; g.score = bestCatScore.reputations or 0 end
    if #groupBags > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "bags"; g.score = bestCatScore.bags or 0 end
    if #groupOptions > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "options"; g.score = bestCatScore.options or 0 end
    if #groupMounts > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "mounts"; g.score = bestCatScore.mounts or 0 end
    if #groupToys > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "toys"; g.score = bestCatScore.toys or 0 end
    if #groupPets > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "pets"; g.score = bestCatScore.pets or 0 end
    if #groupOutfits > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "outfits"; g.score = bestCatScore.outfits or 0 end
    if #groupHeirlooms > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "heirlooms"; g.score = bestCatScore.heirlooms or 0 end
    if #groupLoot > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "loot"; g.score = bestCatScore.loot or 0 end
    if #groupAppearanceSets > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "appearanceSets"; g.score = bestCatScore.appearanceSets or 0 end
    if #groupMap > 0 then n = n + 1; local g = catGroups[n] or {}; catGroups[n] = g; g.key = "map"; g.score = bestCatScore.map or 0 end
    tsort(catGroups, CatGroupCompare)

    hierarchical = {}
    for _, cat in ipairs(catGroups) do
        if cat.key == "ui" then
            if #hierarchical > 0 then
                hierarchical[#hierarchical + 1] = uiSectionHeader
            end
            for _, e in ipairs(groupUI) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "achievements" then
            hierarchical[#hierarchical + 1] = achievementSectionHeader
            for _, e in ipairs(groupAchievements) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "currencies" then
            hierarchical[#hierarchical + 1] = currencySectionHeader
            for _, e in ipairs(groupCurrencies) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "reputations" then
            hierarchical[#hierarchical + 1] = reputationSectionHeader
            for _, e in ipairs(groupReputations) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "bags" then
            hierarchical[#hierarchical + 1] = bagsSectionHeader
            for _, e in ipairs(groupBags) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "options" then
            hierarchical[#hierarchical + 1] = optionsSectionHeader
            for _, e in ipairs(groupOptions) do hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "mounts" then
            hierarchical[#hierarchical + 1] = mountSectionHeader
            for _, e in ipairs(groupMounts) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "toys" then
            hierarchical[#hierarchical + 1] = toySectionHeader
            for _, e in ipairs(groupToys) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "pets" then
            hierarchical[#hierarchical + 1] = petSectionHeader
            for _, e in ipairs(groupPets) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "outfits" then
            hierarchical[#hierarchical + 1] = outfitSectionHeader
            for _, e in ipairs(groupOutfits) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "heirlooms" then
            hierarchical[#hierarchical + 1] = heirloomSectionHeader
            for _, e in ipairs(groupHeirlooms) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "loot" then
            hierarchical[#hierarchical + 1] = lootSectionHeader
            local slotGroups = {}
            local slotOrder = {}
            for _, e in ipairs(groupLoot) do
                local slot = (e.data and e.data.lootSlotName) or "Other"
                if not slotGroups[slot] then
                    slotGroups[slot] = {}
                    slotOrder[#slotOrder + 1] = slot
                end
                slotGroups[slot][#slotGroups[slot] + 1] = e
            end
            for _, slot in ipairs(slotOrder) do
                hierarchical[#hierarchical + 1] = {
                    name = slot, depth = 1, isPathNode = true,
                    isMatch = false, isSectionHeader = false,
                }
                local instGroups = {}
                local instOrder = {}
                for _, e in ipairs(slotGroups[slot]) do
                    local inst = (e.data and e.data.lootInstanceName) or "Unknown"
                    if not instGroups[inst] then
                        instGroups[inst] = {}
                        instOrder[#instOrder + 1] = inst
                    end
                    instGroups[inst][#instGroups[inst] + 1] = e
                end
                for _, inst in ipairs(instOrder) do
                    hierarchical[#hierarchical + 1] = {
                        name = inst, depth = 2, isPathNode = true,
                        isMatch = false, isSectionHeader = false,
                    }
                    for _, e in ipairs(instGroups[inst]) do
                        e.depth = 3
                        hierarchical[#hierarchical + 1] = e
                    end
                end
            end
        elseif cat.key == "appearanceSets" then
            hierarchical[#hierarchical + 1] = appearanceSetSectionHeader
            for _, e in ipairs(groupAppearanceSets) do e.depth = 1; hierarchical[#hierarchical + 1] = e end
        elseif cat.key == "map" then
            hierarchical[#hierarchical + 1] = mapSectionHeader
            for _, e in ipairs(groupMap) do hierarchical[#hierarchical + 1] = e end
        end
    end

    end -- end if hideHeaders / else branch

    -- Prepend pinned items at the top (always visible regardless of query).
    -- In flat-headerless mode, skip the "Pinned Paths" header but still show pins
    -- on top so quick-launches stay accessible.
    local pins = GetAllPins()
    if #pins > 0 then
        local pinnedEntries = {}
        if not hideHeaders then
            pinnedEntries[#pinnedEntries + 1] = {
                isPinHeader = true,
                name = "Pinned Paths",
                depth = 0,
                isPathNode = true,
                isMatch = false,
            }
        end
        for _, pin in ipairs(pins) do
            tinsert(pinnedEntries, {
                name = pin.name,
                depth = 0,
                isPathNode = false,
                isMatch = true,
                isPinned = true,
                isFlat = hideHeaders or nil,
                data = pin,
            })
        end
        -- Combine: pinned header + pins first, then all search results
        -- (pinned items may also appear in results - intentional so the user
        -- can see where the path stands in the full hierarchy)
        for _, entry in ipairs(hierarchical) do
            tinsert(pinnedEntries, entry)
        end
        hierarchical = pinnedEntries
    end

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
    -- state (theme, collapse state, hide-headers, results-above) hasn't
    -- changed since the last render, the visible output would be byte-
    -- for-byte identical. Skip the entire per-row layout pass — this is
    -- the typical case during typing once the top results stabilize.
    do
        -- collapsedNodes is wiped to a fresh empty table on every
        -- search, so identity comparison would always miss during
        -- typing. Snapshot a single key (or nil if empty) — a click on
        -- a collapse toggle adds or removes a key, which we'll see.
        local theme = EasyFind.db.resultsTheme
        local hideHeaders = EasyFind.db.uiHideHeaders
        local above = EasyFind.db.uiResultsAbove
        local collapsedKey = next(collapsedNodes)
        local n = #hierarchical
        local last = self._lastRenderSig
        local same = last and last.n == n
            and last.theme == theme
            and last.hideHeaders == hideHeaders
            and last.above == above
            and last.collapsedKey == collapsedKey
            and last.pinsCollapsed == EasyFind.db.pinsCollapsed
            and resultsFrame:IsShown()
        if same then
            for hi = 1, n do
                local e = hierarchical[hi]
                if last[hi * 2 - 1] ~= e.data or last[hi * 2] ~= (e.depth or 0) then
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
        last.hideHeaders = hideHeaders
        last.above = above
        last.collapsedKey = collapsedKey
        last.pinsCollapsed = EasyFind.db.pinsCollapsed
        for hi = 1, n do
            local e = hierarchical[hi]
            last[hi * 2 - 1] = e.data
            last[hi * 2] = e.depth or 0
        end
        for i = n * 2 + 1, #last do last[i] = nil end
    end

    local theme = GetActiveTheme()
    local rowH  = theme.rowHeight
    local indPx = theme.indentPx
    local padT  = theme.resultsPadTop

    -- Scale row icons to match leaf font height so icon top/bottom
    -- align with text top/bottom instead of overflowing the cap line.
    local iconScale = 1.15
    local leafFontObj = _G[theme.leafFont]
    local leafFontPx = 10
    if leafFontObj and leafFontObj.GetFont then
        local _, sz = leafFontObj:GetFont()
        if sz and sz > 0 then leafFontPx = sz end
    end
    local rowIconSize = math.floor(leafFontPx * iconScale + 0.5)
    if rowIconSize < 12 then rowIconSize = 12 end
    if rowIconSize > (theme.iconSize or 16) then rowIconSize = theme.iconSize or 16 end

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

    -- Apply background atlas if specified (e.g. quest log background)
    if not resultsFrame.bgAtlasTex then
        local tex = resultsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
        -- Stretch horizontally to fill frame, but keep native height (clipped by frame)
        tex:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 4, -4)
        tex:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -4, 4)
        resultsFrame.bgAtlasTex = tex
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

            if entry.isPinHeader then
                if EasyFind.db.pinsCollapsed then
                    skipPins = true
                end
            elseif entry.isPathNode then
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

    local maxVisibleHeight = EasyFind.db.uiResultsHeight or 280
    local willScroll = visibleN * rowH > maxVisibleHeight
    local scrollInset = 0
    if willScroll and resultsFrame.scrollBar then
        scrollInset = resultsFrame.scrollBar:GetWidth()
    end

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
    local CAT_SEP_HEIGHT = 9  -- same dimensions as pin separator
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

    -- Section labels carry their own pair of gold rules, so the
    -- separator-above-label was just doubling up on the visual cut.
    -- Keep the table around for the render loop's lookup but never
    -- populate it.
    local catSepBeforeIndex = {}

    local yOffset = 0
    local pinEndYOffset = 0
    wipe(SCRATCH.catSepYPositions)
    local catSepYPositions = SCRATCH.catSepYPositions
    local hasSideBySideRepBar = false
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = resultButtons[i]
        if i <= count then
            local entry = visible[i]
            local data = entry.data
            local depth = entry.depth or 0

            -- Pin separator gap: add once at the transition row
            if hasResultsAfterPins and i == lastPinIndex + 1 then
                pinEndYOffset = yOffset
                yOffset = yOffset + PIN_SEP_HEIGHT
            end

            -- Category separator gap (between UI, Mount, and Toy groups)
            if catSepBeforeIndex[i] then
                catSepYPositions[#catSepYPositions + 1] = yOffset
                yOffset = yOffset + CAT_SEP_HEIGHT
            end

            -- Small gap between pinned items (not after pin header)
            if entry.isPinned and i > 1 and visible[i - 1] and not visible[i - 1].isPinHeader then
                yOffset = yOffset + 4
            end

            -- Reposition for theme row height. Flat-list entries are taller
            -- to fit the name + path subtext stack with breathing room above
            -- the name and below the path so neither bleeds into the rep bar.
            local padL = theme.resultsPadLeft or 10
            local entryRowH = entry.isFlat and (rowH + 20) or rowH
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
            -- Secure action attributes. Cache the (type, value) we last
            -- applied to this row so we only re-issue SetAttribute when
            -- the row's data actually changed. SetAttribute on a secure
            -- button is the single most expensive thing we do per row,
            -- and incremental narrowing keeps the same row.data on most
            -- rows from one keystroke to the next, so most renders end
            -- up no-ops here.
            if not InCombatLockdown() then
                local newType, newKey, newVal
                if data and data.toyItemID then
                    newType, newKey, newVal = "toy", "toy", data.toyItemID
                elseif data and data.mountID then
                    newType, newKey, newVal = "macro", "macrotext", "/cancelform [form]"
                elseif data and data.outfitID then
                    newType, newKey, newVal = "action", "action", 0
                elseif data and data.spellID then
                    newType, newKey, newVal = "spell", "spell", data.spellName or data.spellID
                elseif data and data.itemID and data.category == "Bag" then
                    newType, newKey, newVal = "item", "item", data.name
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
            resultRow._containerEntry = entry.isContainer and entry or nil
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
                resultRow.headerTab:Hide()
                resultRow.headerGrad:Hide()
                local isCollapsed = EasyFind.db.pinsCollapsed
                local expandAtlas = theme.expandAtlas or "QuestLog-icon-expand"
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                resultRow.pinToggle:SetAtlas(isCollapsed and expandAtlas or collapseAtlas)
                resultRow.pinToggle:Show()
                resultRow.pinHeaderLine:Show()
                -- Position text: left-aligned, right-bounded by toggle
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", 2, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.pinToggle, "LEFT", -4, 0)
                resultRow.text:SetText(entry.name)
                resultRow.text:SetFontObject(theme.pathFont)
                resultRow.text:SetTextColor(0.7, 0.7, 0.7, 1.0)
            elseif entry.isSectionHeader then
                -- Lightweight inline section label: centered text
                -- between two faint horizontal rules. Used for
                -- category dividers (UI / Mounts / Toys / Map / ...)
                -- so they cost less vertical space than a full
                -- parent-tab header and don't waste a parent indent.
                resultRow.headerTab:Hide()
                resultRow.headerGrad:Hide()
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
            elseif theme.showHeaderTab and entry.isPathNode then
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
                resultRow.headerGrad:Hide()
            else
                resultRow.headerTab:Hide()
                -- Gradient header (Classic fallback)
                local showGrad = theme.showHeaderBar and entry.isPathNode
                if showGrad then
                    resultRow.headerGrad:SetAllPoints()
                    local gradAlpha = mmax(0.25, 0.6 - depth * 0.1)
                    resultRow.headerGrad:SetVertexColor(0.35, 0.27, 0.08, gradAlpha)
                end
                resultRow.headerGrad:SetShown(showGrad)
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
                        local sz = entryRowH - 14
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
                    resultRow.text:SetPoint("TOPLEFT", leftAnchor, "TOPRIGHT", 6, -5)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    resultRow.text:SetText(entry.name)
                    resultRow.text:SetFontObject(theme.pathFont)
                    if isUnearnedCurrency then
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        resultRow.text:SetTextColor(1.0, 1.0, 1.0, 1.0)
                    end

                    resultRow.pathSubtext:ClearAllPoints()
                    resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -1)
                    resultRow.pathSubtext:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    resultRow.pathSubtext:SetText(GetFlatSubtext(data))
                    resultRow.pathSubtext:SetFontObject(theme.leafFont)
                    resultRow.pathSubtext:SetTextColor(0.55, 0.55, 0.55, 1.0)
                    resultRow.pathSubtext:Show()
                else
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end

                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    resultRow.text:SetText(entry.name)

                    if resultRow.pathSubtext then
                        resultRow.pathSubtext:Hide()
                    end

                    -- Style: path nodes vs leaf results, themed
                    if entry.isPathNode then
                        resultRow.text:SetFontObject(theme.pathFont)
                        if entry.isMatch then
                            resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                        else
                            resultRow.text:SetTextColor(unpack(theme.pathColor))
                        end
                    elseif isUnearnedCurrency then
                        -- Gray out unearned currencies
                        resultRow.text:SetFontObject(theme.leafFont)
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    elseif entry.isMatch then
                        resultRow.text:SetFontObject(theme.leafFont)
                        resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                    else
                        resultRow.text:SetFontObject(theme.leafFont)
                        resultRow.text:SetTextColor(unpack(theme.leafColor))
                    end
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
                    local sz = entry.isFlat and (entryRowH - 14) or rowIconSize
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
            elseif not iconSet and data and (data.mountID or data.toyItemID or data.petID or data.outfitID or data.heirloomItemID or data.transmogSetID or (data.spellID and data.category == "Ability") or (data.encounterID and data.category == "Boss") or (data.macroIndex and data.category == "Macro") or (data.bagID and data.category == "Bag")) then
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
                    kb1:SetText(k1 or "Not Bound")
                    kb2:SetText(k2 or "Not Bound")
                end
                kb1._bindingAction = action
                kb1._refresh = refresh
                kb2._bindingAction = action
                kb2._refresh = refresh
                refresh()
                resultRow.settingKeybindGroup:Show()
                if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
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
                    slider._updating = true
                    slider:SetMinMaxValues(sMin, sMax)
                    slider:SetValueStep(stepVal)
                    slider:SetValue(numVal)
                    slider._updating = false
                    resultRow.settingSliderGroup:Show()

                    local displayVal
                    if numVal == mfloor(numVal) then
                        displayVal = tostring(mfloor(numVal))
                    else
                        displayVal = sformat("%.2f", numVal)
                    end
                    resultRow.settingSliderValue:SetText(displayVal)

                    resultRow.settingState:Hide()
                    resultRow.settingCheck:Hide()
                    resultRow.amountText:Hide()
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
                    if data.settingType == "dropdown" and data.settingOptions == nil
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                        data.settingOptions = ns.BlizzOptionsSearch.GetOptionsForVariable(data.settingVariable) or false
                    end
                    if data.settingOptions and rawVal ~= nil then
                        for oi = 1, #data.settingOptions do
                            local o = data.settingOptions[oi]
                            if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                                val = o.label or val
                                break
                            end
                        end
                    end
                    if val and val ~= "" then
                        resultRow.amountText:SetText("|cFFAAAAaa" .. val .. "|r")
                        resultRow.amountText:ClearAllPoints()
                        resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                        resultRow.amountText:Show()
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
            end

            -- Flat-list icon sizing. The LEFT icon (UI/map/pin or flatCatIcon)
            -- is large since it's the row's visual anchor. The RIGHT icon
            -- (currency, mount, toy, pet, outfit, appearance set, loot)
            -- gets a mid-sized treatment so it's recognizable without
            -- dominating the row.
            if entry.isFlat and resultRow.icon and resultRow.icon:IsShown() then
                local d = entry.data
                local rightSideIcon = d and (d.mountID or d.toyItemID or d.petID
                    or d.outfitID or d.transmogSetID or d.category == "Currency"
                    or (d.itemID and d.category == "Loot"))
                if rightSideIcon then
                    local rightSize = entryRowH - 18
                    if rightSize < (theme.iconSize or 16) then
                        rightSize = theme.iconSize or 16
                    end
                    resultRow.icon:SetSize(rightSize, rightSize)
                else
                    local flatIconSize = entryRowH - 14
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
                    or d.outfitID or d.transmogSetID or d.category == "Currency"
                    or (d.itemID and d.category == "Loot"))

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
                    resultRow.text:SetPoint("TOPLEFT", leftAnchor, "TOPRIGHT", 6, -7)
                else
                    local flatIndent = depth * indPx + 4
                    resultRow.text:SetPoint("TOPLEFT", resultRow, "TOPLEFT", flatIndent, -7)
                end
                if rightAnchor == resultRow then
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                else
                    resultRow.text:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
                end

                resultRow.pathSubtext:ClearAllPoints()
                resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -1)
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

            -- Measure text height and expand row if text wraps
            -- Skip header tabs: they have SetMaxLines(1) and can't wrap.
            local actualH = resultRow:GetHeight()
            local textObj
            if theme.showHeaderTab and entry.isPathNode and resultRow.headerTab:IsShown() then
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
                    if resultRow.headerTab:IsShown() then
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
            -- that belong to a non-active spec line (offSpecID > 0).
            if data and data.isOffSpec then
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

            yOffset = yOffset + actualH
            resultRow:Show()
        else
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
            resultRow.headerGrad:Hide()
            resultRow.headerTab:Hide()
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

    -- If scrollbar appeared but we didn't reserve space for it (e.g. stacked rep rows
    -- pushed content past maxVisibleHeight), retroactively narrow all visible rows
    -- so they don't bleed into the scrollbar.
    if hasScroll and scrollInset == 0 and resultsFrame.scrollBar then
        local scrollBarW = resultsFrame.scrollBar:GetWidth()
        scrollInset = scrollBarW
        for i = 1, count do
            resultButtons[i]:SetWidth(resultButtons[i]:GetWidth() - scrollBarW)
        end
    end

    -- Size the results frame and scroll child
    resultsFrame:SetHeight(padT + theme.resultsPadBot + visibleHeight)
    resultsFrame.scrollChild:SetWidth(resultsFrame:GetWidth() - scrollInset)
    resultsFrame.scrollChild:SetHeight(totalContentHeight)

    -- Position scroll frame inside results frame (accounting for padding)
    resultsFrame.scrollFrame:ClearAllPoints()
    resultsFrame.scrollFrame:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 0, -padT)
    resultsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, theme.resultsPadBot)

    -- Reset scroll position on new search (preserve on expand/collapse toggle)
    if not preserveScroll then
        resultsFrame.scrollFrame:SetVerticalScroll(0)
    end

    if resultsFrame.scrollBar then
        resultsFrame.scrollBar:SetShown(hasScroll)
        if hasScroll then
            local scrollCenterX = resultsFrame:GetWidth() * 0.96
            resultsFrame.scrollBar:ClearAllPoints()
            resultsFrame.scrollBar:SetPoint("CENTER", resultsFrame, "TOPLEFT", scrollCenterX, -resultsFrame:GetHeight() / 2)
            resultsFrame.scrollBar:UpdateBarHeight()
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
    -- Legacy function, redirects to hierarchical
    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    self:ShowHierarchicalResults(hierarchical)
end

function UI:RefreshResults()
    -- Re-render current results with the active theme (called when theme changes)
    self:UpdateSearchBarTheme()
    -- Only re-render if results are currently visible; don't resurrect old results
    if cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        local savedIndex = selectedIndex
        local savedToggle = toggleFocused
        self:ShowHierarchicalResults(cachedHierarchical)
        -- ShowHierarchicalResults resets selectedIndex to 0; restore it for
        -- deferred re-renders (rep bar IsTruncated settle) so keyboard
        -- navigation isn't disrupted.
        if savedIndex > 0 then
            selectedIndex = savedIndex
            toggleFocused = savedToggle
            self:UpdateSelectionHighlight()
        end
    end
end

-- Toggle a boolean setting in place (clicked from a result row).
-- Tries the Settings API first (handles non-CVar settings like action
-- bar visibility), falls back to GetCVar/SetCVar.
function UI:ToggleSettingCheckbox(data)
    if not data or not data.settingVariable then return end
    local var = data.settingVariable
    local toggled = false
    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, var)
        if sok and settObj and settObj.GetValue and settObj.SetValue then
            local vok, curVal = pcall(settObj.GetValue, settObj)
            if vok then
                if type(curVal) == "boolean" then
                    pcall(settObj.SetValue, settObj, not curVal)
                    toggled = true
                elseif curVal == "1" or curVal == "0" then
                    pcall(settObj.SetValue, settObj, curVal == "1" and "0" or "1")
                    toggled = true
                end
            end
        end
    end
    if not toggled and GetCVar then
        local cur = GetCVar(var)
        if cur and SetCVar then
            SetCVar(var, cur == "1" and "0" or "1")
        end
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
function UI:CycleSettingDropdown(data)
    if not data or not data.settingVariable then return false end
    local var = data.settingVariable
    local opts = data.settingOptions
    if not opts and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
        opts = ns.BlizzOptionsSearch.GetOptionsForVariable(var)
        if opts then data.settingOptions = opts end
    end
    if not opts or #opts == 0 then return false end

    local settObj
    if Settings and Settings.GetSetting then
        local sok, s = pcall(Settings.GetSetting, var)
        if sok then settObj = s end
    end
    local curVal
    if settObj and settObj.GetValue then
        local vok, v = pcall(settObj.GetValue, settObj)
        if vok then curVal = v end
    end
    if curVal == nil and GetCVar then curVal = GetCVar(var) end

    local curIdx
    for i = 1, #opts do
        local v = opts[i].value
        if v == curVal or tostring(v) == tostring(curVal) then
            curIdx = i
            break
        end
    end
    local nextIdx = (curIdx or 0) % #opts + 1
    local nextVal = opts[nextIdx].value

    local applied = false
    if settObj and settObj.SetValue then
        applied = pcall(settObj.SetValue, settObj, nextVal)
    end
    if not applied and SetCVar then
        pcall(SetCVar, var, tostring(nextVal))
    end

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
function UI:CloseFilterDropdownIfOpen()
    if not searchFrame then return false end
    local dropdown = searchFrame.filterDropdown
    if not dropdown then return false end
    local closedAny = false
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
    if escCatcher then escCatcher:Hide() end
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
    selectedIndex = 0
    toggleFocused = false
    self:UpdateSelectionHighlight(true)
end

function UI:ShowPinnedItems()
    if not resultsFrame then return end
    local pins = GetAllPins()
    if #pins == 0 then
        self:HideResults()
        return
    end

    -- Build synthetic hierarchical entries and delegate to the same renderer
    -- used during search, so pinned items look identical in both cases.
    collapsedNodes = {}
    expandedContainers = {}
    local hideHeaders = EasyFind.db.uiHideHeaders
    local entries = {}
    if not hideHeaders then
        entries[#entries + 1] = {
            isPinHeader = true,
            name = "Pinned Paths",
            depth = 0,
            isPathNode = true,
            isMatch = false,
        }
    end
    for _, pin in ipairs(pins) do
        tinsert(entries, {
            name = pin.name,
            depth = 0,
            isPathNode = false,
            isMatch = true,
            isPinned = true,
            isFlat = hideHeaders or nil,
            data = pin,
        })
    end
    self:ShowHierarchicalResults(entries)
end

function UI:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    if resultsFrame:IsShown() and resultButtons[1]:IsShown() and resultButtons[1].data then
        self:SelectResult(resultButtons[1].data)
    end
end

function UI:CountVisibleResults()
    local count = 0
    for i = 1, MAX_BUTTON_POOL do
        if resultButtons[i]:IsShown() then
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
        -- Leaf rows (no headerTab): LockHighlight pins the shared
        -- row HighlightTexture so keyboard selection looks identical
        -- to mouse hover. Header rows skip the row highlight — their
        -- visual is carried by tabHoverOverlay inside the tab to match
        -- mouse hover exactly (rather than painting a row-wide glow
        -- that extends past the tab).
        local isHeaderRow = resultRow.headerTab and resultRow.headerTab:IsShown()
        if resultRow.LockHighlight then
            if i == selectedIndex and not toggleFocused and not isHeaderRow then
                resultRow:LockHighlight()
            else
                resultRow:UnlockHighlight()
            end
        end
        -- Retired blue glow: keyboard selection now uses the same
        -- tabHoverOverlay the mouse-hover path does so the two paths
        -- look identical. Keep the texture reference silent.
        if resultRow.tabSelectionHighlight then
            resultRow.tabSelectionHighlight:Hide()
        end
        if resultRow.toggleHighlight then
            local showToggle = i == selectedIndex and toggleFocused
            local isPinToggle = resultRow.isPinHeader and resultRow.pinToggle and resultRow.pinToggle:IsShown()
            if showToggle and isPinToggle then
                resultRow.toggleHighlight:ClearAllPoints()
                resultRow.toggleHighlight:SetPoint("CENTER", resultRow.pinToggle, "CENTER", 0, 0)
            end
            resultRow.toggleHighlight:SetShown(showToggle and isPinToggle)
            if resultRow.toggleBtn then
                if resultRow.toggleBtn.btnBg then
                    resultRow.toggleBtn.btnBg:SetShown(showToggle and not isPinToggle)
                end
                if showToggle and not isPinToggle then
                    resultRow.toggleBtn:LockHighlight()
                else
                    resultRow.toggleBtn:UnlockHighlight()
                end
            end
            -- Tab overlay shows for keyboard selection on a non-pin
            -- header whether the cursor is on the row body (not
            -- toggleFocused) or on the toggle button (toggleFocused).
            -- Pin headers use their own pin-toggle highlight instead.
            local isHeaderSelected = i == selectedIndex
                and resultRow.headerTab and resultRow.headerTab:IsShown()
                and not isPinToggle
            if resultRow.tabHoverOverlay then
                resultRow.tabHoverOverlay:SetShown(isHeaderSelected)
            end
            if resultRow.tabText then
                if isHeaderSelected then
                    resultRow.tabText:SetTextColor(0.90, 0.88, 0.85, 1.0)
                elseif not resultRow.headerTab:IsMouseOver() then
                    if resultRow._isMatch then
                        resultRow.tabText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)
                    else
                        resultRow.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0)
                    end
                end
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

    -- Bind Enter to the selected result button for any secure-action row
    -- (spell/toy/macro/action/item) so the secure dispatch fires on keypress
    -- the same as a mouse click. Without this, Enter on an ability would
    -- fall through ActivateSelected → SelectResult, which intentionally
    -- no-ops for spell/toy data because casting is protected.
    if not InCombatLockdown() then
        local selRow = selectedIndex > 0 and resultButtons[selectedIndex]
        local rd = selRow and selRow.data
        local secureRow = rd and (rd.outfitID or rd.toyItemID or rd.spellID
            or rd.mountID or rd.macroIndex
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
        if resultRow:IsShown() then
            -- Don't allow activating unearned currencies
            if resultRow.isUnearnedCurrency then
                return
            end

            -- Pin header: toggle collapse
            if resultRow.isPinHeader then
                EasyFind.db.pinsCollapsed = not EasyFind.db.pinsCollapsed
                if cachedHierarchical then
                    local savedIndex = selectedIndex
                    local savedToggle = toggleFocused
                    self:ShowHierarchicalResults(cachedHierarchical, true)
                    selectedIndex = savedIndex
                    toggleFocused = savedToggle
                    self:UpdateSelectionHighlight()
                end
                return
            end

            if resultRow.isPathNode and toggleFocused then
                -- Toggle collapse when focus is on the +/- control
                local key = (resultRow.pathNodeName or "") .. "_" .. (resultRow.pathNodeDepth or 0)
                local wasCollapsed = collapsedNodes[key]
                collapsedNodes[key] = not collapsedNodes[key]
                if wasCollapsed and resultRow._containerEntry and cachedHierarchical then
                    for idx, entry in ipairs(cachedHierarchical) do
                        if entry == resultRow._containerEntry then
                            ExpandContainer(entry, idx)
                            break
                        end
                    end
                end
                if cachedHierarchical then
                    local savedIndex = selectedIndex
                    local savedToggle = toggleFocused
                    self:ShowHierarchicalResults(cachedHierarchical, true)
                    selectedIndex = savedIndex
                    toggleFocused = savedToggle
                    self:UpdateSelectionHighlight()
                end
            elseif resultRow.data then
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

    -- Toy: handled by SecureActionButton on mousedown (UseToyByItemID is protected)
    if data.toyItemID then return end

    -- Ability: cast via SecureActionButton (CastSpell is protected). The spell
    -- attribute was set when the row was bound, so the click already fired the
    -- cast — don't try to walk the (no-op) steps[] guide here.
    if data.spellID then return end

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
            local hasUseEffect = (C_Item and C_Item.GetItemSpell and C_Item.GetItemSpell(data.itemID))
                or (GetItemSpell and GetItemSpell(data.itemID))
            local isEquippable = IsEquippableItem and IsEquippableItem(data.itemID)
            if hasUseEffect or isEquippable then
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

    -- Macro: open MacroFrame and select the macro slot.
    if data.macroIndex then
        if useFast then
            UI:OpenMacroFrameAt(data.macroIndex, data.macroIsChar)
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
                else
                    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                    local scrollBox = infoFrame and infoFrame.BossesScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejBoss)
                        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local text = Utils.GetButtonText(btn)
                            return text and slower(text) == targetName
                        end)
                        if bossBtn then ClickButton(bossBtn) end
                    end
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
    searchFrame:Hide()
    searchFrame.setSmartShowVisible(false)
    self:HideResults()
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:SetShown(searchFrame.editBox:GetText() == "")
    EasyFind.db.visible = false

    searchFrame.hoverZone:SetShown(EasyFind.db.smartShow)
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
        self:ShowHierarchicalResults(cachedHierarchical, true)
        if savedIndex > 0 then
            selectedIndex = savedIndex
            toggleFocused = savedToggle
            self:UpdateSelectionHighlight()
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
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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

    -- Buttons sit just below the panel, centered as a pair around the
    -- panel's vertical midline. "See demo" on the LEFT, "Got it" on the
    -- RIGHT. Anchoring TOP to the panel's BOTTOM places them outside the
    -- frame so they don't crowd the keybind section above.
    local seeDemoBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    seeDemoBtn:SetSize(100, 22)
    seeDemoBtn:SetPoint("TOPLEFT", panel, "BOTTOM", 4, -8)
    seeDemoBtn:SetText("See demo")

    local gotItBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    gotItBtn:SetSize(100, 22)
    gotItBtn:SetPoint("TOPRIGHT", panel, "BOTTOM", -4, -8)
    gotItBtn:SetText("Got it")

    -- During setup: allow drag without holding Shift
    searchFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    -- Forward declarations for the demo frames so FinishSetup can clean
    -- them up regardless of whether the player went through See Demo.
    local demoFrame
    local startDemo

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
        if demoFrame then demoFrame:Hide() end
        -- Clear the demo suspend flag so the dropdown auto-close works
        if searchFrame.filterDropdown then
            searchFrame.filterDropdown._demoSuspend = nil
        end

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

    startDemo = function()
        ns.Demo.Start({
            searchFrame = searchFrame,
            resultsFrame = resultsFrame,
            resultButtons = resultButtons,
            finishSetup = FinishSetup,
        })
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

    seeDemoBtn:SetScript("OnClick", function()
        -- Save position + apply preferences, then skip straight to the
        -- interactive demo (no mode-intro step in between).
        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
        EasyFind.db.smartShow = smartShowCheckbox:GetChecked()
        EasyFind.db.staticOpacity = not fadeCheckbox:GetChecked()
        UI:UpdateSmartShow()

        -- Hide all setup-mode chrome before the demo takes over the
        -- search bar. Without this, the gold "Drag to move" glow
        -- lingers on top of the demo.
        panel:Hide()
        resizer:Hide()
        glow:SetScript("OnUpdate", nil)
        glow:Hide()
        startDemo()
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

    local function ScaleFont(fontString, baseFontObject)
        local obj = _G[baseFontObject]
        if not obj then return end
        local path, baseSize, flags = obj:GetFont()
        fontString:SetFont(path, baseSize * scale, flags)
        fontString:SetJustifyH(fontString:GetJustifyH())
    end

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
        local row = resultButtons[i]
        ScaleFont(row.text, theme.leafFont)
        ScaleFont(row.tabText, theme.pathFont)
        if row.pathSubtext then
            ScaleFont(row.pathSubtext, theme.leafFont)
        end
        if row.amountText then
            ScaleFont(row.amountText, "GameFontNormalSmall")
        end
        if row.repBarText then
            ScaleFont(row.repBarText, "GameFontNormalSmall")
        end
    end

    -- Re-layout visible results with new row heights
    if cachedHierarchical and resultsFrame and resultsFrame:IsShown() then
        self:ShowHierarchicalResults(cachedHierarchical, true)
    end
end
