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
local wipe               = wipe

local LIGHTNING_BOLT_TEX = "Interface\\AddOns\\EasyFind-loot-search\\textures\\lightning-bolt"
local REP_BAR_WIDTH = 100

local searchFrame
local resultsFrame
local resultButtons = {}
local MAX_BUTTON_POOL = 50  -- Maximum buttons (scroll handles overflow beyond this)
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult
local deferredRepRefreshPending = false  -- deferred re-render to let IsTruncated() settle
local outfitCdStart, outfitCdDuration = 0, 0  -- shared outfit swap cooldown
local lastEquippedOutfitID                     -- tracks most recent equip for immediate green tint

-- PIN HELPERS

local function GetUIPinKey(data)
    if not data or not data.name then return "" end
    return data.name .. "|" .. tconcat(data.path or {}, ">")
end

-- Copy storable fields from a search entry for SavedVariables pinning.
-- Uses explicit field access (not pairs) so metatable __index fields are included.
local CLEAN_SIMPLE_FIELDS = {"name", "nameLower", "category", "buttonFrame", "flashLabel", "icon",
    "mountID", "spellID", "toyItemID", "petID", "speciesID", "outfitID",
    "itemID", "encounterID", "instanceID", "lootSlotName", "lootSourceName", "lootInstanceName", "lootSourceType",
    "factionID", "hasRepBar", "canQueue", "isPvP", "isPvE"}
local CLEAN_TABLE_FIELDS = {"path", "steps", "keywords", "keywordsLower"}

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
            local arr = {}
            for i2, v2 in ipairs(v) do
                if type(v2) == "table" then
                    local sub = {}
                    for sk, sv in pairs(v2) do sub[sk] = sv end
                    arr[i2] = sub
                else
                    arr[i2] = v2
                end
            end
            clean[k] = arr
        end
    end
    return clean
end

-- Collection-type pins (mounts, toys, pets, outfits, loot) are character-specific.
-- All other pins are account-wide.
local function IsCollectionPin(data)
    return data and (data.mountID or data.toyItemID or data.petID or data.outfitID
        or (data.itemID and data.category == "Loot"))
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

-- Simple pin context popup (BOTTOMLEFT anchored at cursor so it opens above)
local pinPopup
local function ShowPinPopup(btn, isPinned, onAction)
    if not pinPopup then
        pinPopup = CreateFrame("Button", "EasyFindPinPopup", UIParent, "BackdropTemplate")
        pinPopup:SetSize(80, 28)
        pinPopup:SetFrameStrata("TOOLTIP")
        pinPopup:SetFrameLevel(10000)
        pinPopup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        pinPopup:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])
        local label = pinPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        pinPopup.label = label
        pinPopup:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        -- Delayed hide: brief grace period so the popup doesn't vanish when
        -- the cursor drifts a pixel outside the button
        pinPopup:SetScript("OnLeave", function(self)
            if self._hideTimer then self._hideTimer:Cancel() end
            self._hideTimer = C_Timer.NewTimer(0.25, function()
                if not self:IsMouseOver() then self:Hide() end
            end)
        end)
        pinPopup:SetScript("OnEnter", function(self)
            if self._hideTimer then self._hideTimer:Cancel(); self._hideTimer = nil end
        end)
    end
    pinPopup.label:SetText(isPinned and "Unpin" or "Pin")
    pinPopup:SetScript("OnClick", function(self)
        self:Hide()
        onAction()
    end)
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    pinPopup:ClearAllPoints()
    pinPopup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    if pinPopup._hideTimer then pinPopup._hideTimer:Cancel(); pinPopup._hideTimer = nil end
    pinPopup:Show()
end

-- Centralized icon setter - resets texture state before applying to prevent
-- atlas/texture bleed between rows.
local function SetRowIcon(btn, kind, value, iconSize)
    btn.icon:SetTexture(nil)
    btn.icon:SetTexCoord(0, 1, 0, 1)
    btn.icon:SetVertexColor(1, 1, 1, 1)
    -- Clear mount/toy/pet tooltip data and cooldown from previous render
    btn.icon.mountID = nil
    btn.icon.toyItemID = nil
    btn.icon.petID = nil
    btn.icon.spellID = nil
    btn.icon.outfitID = nil
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
    btn.icon:SetSize(iconSize or 16, iconSize or 16)
    btn.icon:Show()
end

local selectedIndex = 0   -- 0 = none selected, 1..N = highlighted row
local toggleFocused = false -- true = Tab moved focus to expand/collapse toggle
local navFrame             -- Keyboard capture frame for results navigation
local escCatcher           -- UISpecialFrames fallback for second-ESC-to-close
local unearnedTooltip      -- Custom tooltip for unearned currencies

-- THEME DEFINITIONS
local THEMES = {}

-- Classic: colorful tree connectors, +/- icons, gold leaf text
THEMES["Classic"] = {
    rowHeight       = 22,
    indentPx        = 20,
    lineWidth       = 2,
    resultsWidth    = 350,
    resultsPadTop   = 8,
    resultsPadBot   = 8,
    btnWidth        = 360,
    iconSize        = 16,
    pathIconSize    = 14,
    -- fonts
    pathFont        = ns.SEARCHBAR_FONT,
    leafFont        = ns.LEAF_FONT,
    pathColor       = {0.7, 0.7, 0.7},
    leafColor       = GOLD_COLOR,
    -- tree lines
    showTreeLines   = true,
    indentColors    = {
        {0.40, 0.85, 1.00, 0.80},
        {1.00, 0.55, 0.10, 0.80},
        {0.55, 1.00, 0.35, 0.80},
        {1.00, 0.40, 0.70, 0.80},
        {0.70, 0.55, 1.00, 0.80},
        {1.00, 0.90, 0.20, 0.80},
    },
    -- icons for collapse/expand
    expandIcon      = "Interface\\Buttons\\UI-PlusButton-Up",
    collapseIcon    = "Interface\\Buttons\\UI-MinusButton-Up",
    -- highlight
    highlightTex    = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    selectionColor  = {0.3, 0.6, 1.0, 0.4},
    -- header bar (disabled in classic)
    showHeaderBar   = false,
    -- results backdrop
    resultsBackdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    },
}

-- Retail: quest-log style - raised tab headers, golden tree lines, grey border
THEMES["Retail"] = {
    rowHeight       = 28,
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
    return THEMES[EasyFind.db.resultsTheme or "Classic"] or THEMES["Classic"]
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

    if EasyFind.db.visible ~= false then
        searchFrame:Show()
        -- Apply smart show on startup
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

    -- First-time setup overlay for new installs
    if EasyFind.db.firstInstall and not EasyFind.db.setupComplete then
        C_Timer.After(0.3, function() self:ShowFirstTimeSetup() end)
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
            if EasyFind.db.visible ~= false then
                searchFrame:Show()
                if EasyFind.db.smartShow then
                    searchFrame.hoverZone:Show()
                    searchFrame:SetAlpha(0)
                    searchFrame.setSmartShowVisible(false)
                end
            else
                if EasyFind.db.smartShow then
                    searchFrame.hoverZone:Show()
                end
            end
        end
    end)
end

function UI:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "EasyFindSearchFrame", UIParent, "BackdropTemplate")
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
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        ns.SetSearchBorderShown(searchFrame, true)
        ns.SetSearchBorderBgAlpha(searchFrame, EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
    else
        searchFrame:SetBackdrop({
            bgFile = WHITE8x8,
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
        searchFrame:SetBackdropColor(0, 0, 0, EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
        ns.SetSearchBorderShown(searchFrame, false)
    end

    -- Mode toggle button (search icon area, flush left)
    local contentSz = ns.SEARCHBAR_HEIGHT * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE

    local modeBtn = CreateFrame("Button", "EasyFindModeButton", searchFrame)
    modeBtn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    modeBtn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    modeBtn:SetPoint("LEFT", searchFrame, "LEFT", 0, 0)
    modeBtn:SetWidth(searchFrame:GetHeight())
    modeBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    local modeIcon = modeBtn:CreateTexture(nil, "OVERLAY")
    modeIcon:SetSize(iconSz, iconSz)
    modeIcon:SetPoint("CENTER")
    modeBtn.icon = modeIcon

    local modeBtnBg = modeBtn:CreateTexture(nil, "ARTWORK")
    modeBtnBg:SetAllPoints()
    modeBtnBg:SetTexture(796424)
    modeBtnBg:Hide()
    modeBtn.btnBg = modeBtnBg

    modeBtn:SetHighlightTexture(130757)
    searchFrame.modeBtn = modeBtn
    searchFrame.searchIcon = modeIcon

    local function UpdateModeButtonVisual(btn)
        if EasyFind.db.directOpen then
            btn.icon:SetAtlas(nil)
            btn.icon:SetTexture(LIGHTNING_BOLT_TEX)
        else
            btn.icon:SetTexture(nil)
            btn.icon:SetAtlas("common-search-magnifyingglass")
        end
    end
    ns.UpdateModeButtonVisual = UpdateModeButtonVisual

    modeBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if EasyFind.db.directOpen then
            GameTooltip:SetText("Fast Search (ON)")
            GameTooltip:AddLine("Click to switch to step-by-step guided mode.", 1, 1, 1, true)
        else
            GameTooltip:SetText("Standard Search")
            GameTooltip:AddLine("Click to enable fast search (opens panels directly).", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)

    modeBtn:SetScript("OnLeave", function(self)
        if not self.keyboardFocused then self.btnBg:Hide() end
        GameTooltip_Hide()
    end)

    modeBtn:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = not EasyFind.db.directOpen
        UpdateModeButtonVisual(self)
        ns.Highlight:ClearAll()
        local optPanel = _G["EasyFindOptionsFrame"]
        if optPanel and optPanel.directOpenCheckbox then
            optPanel.directOpenCheckbox:SetChecked(EasyFind.db.directOpen)
        end
    end)

    UpdateModeButtonVisual(modeBtn)

    -- Editbox
    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetHeight(contentSz)
    editBox:SetPoint("LEFT", modeBtn, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", searchFrame, "RIGHT", -8, 0)
    editBox:SetFontObject(ns.SEARCHBAR_FONT)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)

    -- Block focus when Shift is held (shift = drag, not type) unless already typing
    editBox:HookScript("OnMouseDown", function(self)
        if IsShiftKeyDown() and not self:HasFocus() then
            self.blockFocus = true
            searchFrame:StartMoving()
        end
        if searchFrame.setupMode then
            self.blockFocus = true
        end
    end)
    editBox:HookScript("OnMouseUp", function(self)
        self.blockFocus = nil
        if searchFrame:IsMovable() then
            searchFrame:StopMovingOrSizing()
            local point, _, relPoint, x, y = searchFrame:GetPoint()
            EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
        end
    end)

    local placeholder = editBox:CreateFontString(nil, "ARTWORK", ns.SEARCHBAR_FONT)
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetPoint("RIGHT", editBox, "RIGHT", -2, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    placeholder:SetTextColor(0.5, 0.5, 0.5, 1.0)
    placeholder:SetText("Search your UI here")
    editBox.placeholder = placeholder

    editBox:SetScript("OnEditFocusGained", function(self)
        if self.blockFocus then
            self:ClearFocus()
            return
        end
        if escCatcher then escCatcher:Hide() end
        self.placeholder:Hide()
        if selectedIndex > 0 then
            selectedIndex = 0
            toggleFocused = false
            UI:UpdateSelectionHighlight(true)
        end
        if self:GetText() == "" then
            UI:ShowPinnedItems()
        end
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        -- Skip cleanup when SelectResult is actively clearing text/focus
        if selectingResult then return end
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

    editBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        UI:OnSearchTextChanged(self:GetText())
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        UI:ActivateSelected()
    end)

    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        -- Text and results stay visible; user can click back in to resume.
    end)

    -- Clear-text X button (grey circle X, matching retail quest log style)
    -- Only visible when there is text in the editbox.
    local clearTextBtn = Utils.CreateClearButton(searchFrame, "EasyFindClearTextButton")
    clearTextBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    clearTextBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        editBox.placeholder:Show()
        UI:HideResults()
    end)
    clearTextBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Clear search text")
        GameTooltip:Show()
    end)
    clearTextBtn:SetScript("OnLeave", GameTooltip_Hide)
    searchFrame.clearTextBtn = clearTextBtn

    -- Filter button (inside search bar, flush right)
    local filterBtn = CreateFrame("Button", "EasyFindUIFilterButton", searchFrame)
    filterBtn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    filterBtn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    filterBtn:SetPoint("RIGHT", searchFrame, "RIGHT", 0, 0)
    filterBtn:SetWidth(searchFrame:GetHeight())
    filterBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

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

    filterBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Filter Results")
        GameTooltip:AddLine("Choose which result types to show.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    filterBtn:SetScript("OnLeave", function(self)
        if not self.keyboardFocused then self.btnBg:Hide() end
        GameTooltip_Hide()
    end)
    searchFrame.filterBtn = filterBtn

    -- Reposition clear button to left of filter button
    clearTextBtn:ClearAllPoints()
    clearTextBtn:SetPoint("RIGHT", filterBtn, "LEFT", -2, 0)

    -- Anchor editBox right edge to left of clear button area (filter button zone)
    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", modeBtn, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)

    -- Click anywhere on the search frame to focus the editbox (enables blinking cursor)
    -- Use HookScript to preserve SmartShow OnLeave handlers;
    -- skip focus if SmartShow is active and editbox is empty (prevents the bar getting stuck visible)
    searchFrame:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not IsShiftKeyDown() and not self.setupMode then
            editBox:SetFocus()
        end
    end)

    -- Show/hide the clear-text X based on whether there's text
    editBox:HookScript("OnTextChanged", function(self)
        clearTextBtn:SetShown(self:GetText() ~= "")
    end)

    -- Key repeat with progressive acceleration for held arrow/tab keys.
    -- Starts at REPEAT_INITIAL delay, accelerates toward REPEAT_FAST over REPEAT_ACCEL seconds.
    local REPEAT_INITIAL = 0.30
    local REPEAT_FAST    = 0.05
    local REPEAT_ACCEL   = 1.5
    local repeatKey, repeatAction, repeatHeld, repeatNext
    local repeatActive = false

    local function StopKeyRepeat()
        repeatKey = nil
        repeatAction = nil
        repeatActive = false
    end
    searchFrame.StopKeyRepeat = StopKeyRepeat
    searchFrame.IsRepeatKey = function(key) return repeatKey == key end

    local function StartKeyRepeat(key, action)
        action()
        repeatKey = key
        repeatAction = action
        repeatHeld = 0
        repeatNext = REPEAT_INITIAL
        repeatActive = true
    end
    searchFrame.StartKeyRepeat = StartKeyRepeat

    searchFrame:SetScript("OnUpdate", function(_, elapsed)
        if not repeatActive then return end
        repeatHeld = repeatHeld + elapsed
        repeatNext = repeatNext - elapsed
        if repeatNext <= 0 then
            repeatAction()
            local t = repeatHeld / REPEAT_ACCEL
            if t > 1 then t = 1 end
            repeatNext = REPEAT_INITIAL + (REPEAT_FAST - REPEAT_INITIAL) * t
        end
    end)

    -- Arrow key / Tab navigation for results dropdown.
    -- IMPORTANT: Always block propagation while the editbox has focus so that
    -- typed letters never trigger the player's game keybinds.
    editBox:SetScript("OnKeyDown", function(self, key)
        if resultsFrame and resultsFrame:IsShown() and selectedIndex == 0 then
            if EasyFind.db.uiResultsAbove then
                if key == "UP" then UI:JumpToEnd() end
            else
                if key == "DOWN" then UI:MoveSelection(1) end
            end
        end
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
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
        local controls = {}
        tinsert(controls, modeBtn)
        if clearTextBtn:IsShown() then
            tinsert(controls, clearTextBtn)
        end
        tinsert(controls, filterBtn)
        return controls
    end

    local function SetToolbarFocus(idx)
        -- Clear previous button state
        local prevControls = GetToolbarControls()
        local prevTarget = prevControls[toolbarFocus]
        if prevTarget then
            prevTarget.keyboardFocused = nil
            if prevTarget.btnBg then prevTarget.btnBg:Hide() end
            if prevTarget.UnlockHighlight then prevTarget:UnlockHighlight() end
        end
        toolbarFocus = idx
        local controls = GetToolbarControls()
        local target = controls[idx]
        if target then
            target.keyboardFocused = true
            if target.btnBg then
                target.btnBg:Show()
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

    local function HandleNavKeyDown(key)
        if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
           or key == "LALT" or key == "RALT" then return end

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
        elseif key == "PAGEDOWN" then
            StartKeyRepeat(key, function() UI:MoveSelection(5) end)
        elseif key == "PAGEUP" then
            StartKeyRepeat(key, function() UI:MoveSelection(-5) end)
        elseif key == "HOME" then
            UI:JumpToStart()
        elseif key == "END" then
            UI:JumpToEnd()
        elseif key == "TAB" then
            -- Ring order: modeBtn(1) → editBox → [clearBtn] → filterBtn → wrap
            -- EditBox sits between toolbar index 1 and 2
            if IsShiftKeyDown() then
                if selectedIndex > 0 and toggleFocused then
                    toggleFocused = false
                    UI:UpdateSelectionHighlight()
                elseif toolbarFocus > 0 then
                    if toolbarFocus == 1 then
                        local controls = GetToolbarControls()
                        SetToolbarFocus(#controls)
                    elseif toolbarFocus == 2 then
                        ClearToolbarFocus()
                        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
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
                    if toolbarFocus == 1 then
                        ClearToolbarFocus()
                        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                        searchFrame.editBox:SetFocus()
                    elseif toolbarFocus >= #controls then
                        SetToolbarFocus(1)
                    else
                        SetToolbarFocus(toolbarFocus + 1)
                    end
                end
            end
        elseif key == "ENTER" then
            if toolbarFocus > 0 then
                local controls = GetToolbarControls()
                local target = controls[toolbarFocus]
                if target then target:Click() end
            else
                UI:ActivateSelected()
            end
        elseif key == "ESCAPE" then
            if toolbarFocus > 0 then
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
            ClearToolbarFocus()
            selectedIndex = 0
            toggleFocused = false
            UI:UpdateSelectionHighlight()
            if not IsControlKeyDown() and not IsAltKeyDown() and #key == 1 then
                local char = IsShiftKeyDown() and key or slower(key)
                searchFrame.editBox:Insert(char)
            end
        end
    end

    navFrame:SetScript("OnKeyDown", function(self, key)
        -- Outfits/toys: let Enter propagate to the override binding
        -- so the secure action handler fires (same as mouse click).
        if key == "ENTER" and selectedIndex > 0 and not InCombatLockdown() then
            local selRow = resultButtons[selectedIndex]
            local rd = selRow and selRow.data
            if rd and (rd.outfitID or rd.toyItemID) then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
                return
            end
        end
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        HandleNavKeyDown(key)
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        if repeatKey == key then StopKeyRepeat() end
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

    -- Tab/Shift+Tab from editbox: navigate toolbar controls
    -- Controls are ordered left-to-right: modeBtn, [clearTextBtn], filterBtn
    -- EditBox sits between modeBtn and clearTextBtn/filterBtn, so:
    --   Shift+Tab (left) → modeBtn (index 1)
    --   Tab (right) → first control after editBox (index 2)
    editBox:HookScript("OnKeyDown", function(self, key)
        if key ~= "TAB" then return end
        self:ClearFocus()
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
        if IsShiftKeyDown() then
            SetToolbarFocus(1)
        else
            SetToolbarFocus(2)
        end
    end)

    -- Draggable with Shift key
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self:StartMoving()
        end
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
        if smartShowTimer then smartShowTimer:Cancel() end
        smartShowTimer = C_Timer.NewTimer(0.4, function()
            smartShowTimer = nil
            -- Re-check conditions after the delay
            if searchFrame.editBox:HasFocus() or searchFrame.editBox:GetText() ~= "" then return end
            if resultsFrame and resultsFrame:IsShown() then return end
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
end

local UI_FILTER_OPTIONS = {
    { key = "ui",     label = "UI Search",  iconAtlas = "common-search-magnifyingglass" },
    { key = "map",    label = "Map Search", iconAtlas = "Waypoint-MapPin-ChatIcon" },
    { key = "mounts", label = "Mounts",     iconTex = 132261 },  -- Ability_Mount_RidingHorse
    { key = "toys",   label = "Toys",       iconTex = 454046 },  -- Trade_Archaeology_ChestofTinyGlassAnimals
    { key = "pets",   label = "Pets",       iconTex = 132599 },  -- PetJournalPortrait (Inv_Box_PetCarrier_01)
    { key = "outfits", label = "Outfits",  iconTex = 132649 },  -- INV_Chest_Cloth_17
    { key = "loot",    label = "Loot",     iconTex = 132281 },  -- INV_Sword_04
}

function UI:CreateUIFilterDropdown(toggleBtn, anchorFrame, searchEditBox)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    local dropdown = CreateFrame("Frame", "EasyFindUIFilterDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    dropdown:Hide()
    dropdown:EnableMouse(true)
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
    local RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind-loot-search\\radio-off"
    local RADIO_ON_TEX = "Interface\\AddOns\\EasyFind-loot-search\\radio-on"
    local DROPDOWN_BAR_SIZE = { 120, 27 }
    local DROPDOWN_ARROW_SIZE = { 20, 20 }
    local DROPDOWN_ARROW_DIM = 0.7
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

    local function CreateDropdownBar(parent)
        local bar = CreateFrame("Button", nil, parent)
        bar:SetSize(unpack(DROPDOWN_BAR_SIZE))
        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAtlas("common-dropdown-textholder")
        bg:SetAllPoints()
        local arrow = bar:CreateTexture(nil, "OVERLAY")
        arrow:SetAtlas("common-dropdown-a-button-hover")
        arrow:SetSize(unpack(DROPDOWN_ARROW_SIZE))
        arrow:SetPoint("RIGHT", -2, -1)
        arrow:SetVertexColor(DROPDOWN_ARROW_DIM, DROPDOWN_ARROW_DIM, DROPDOWN_ARROW_DIM)
        local label = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", 8, 0)
        label:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        bar:SetScript("OnEnter", function() arrow:SetVertexColor(1, 1, 1) end)
        bar:SetScript("OnLeave", function() arrow:SetVertexColor(DROPDOWN_ARROW_DIM, DROPDOWN_ARROW_DIM, DROPDOWN_ARROW_DIM) end)
        bar:Hide()
        return bar, label, arrow
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
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        label:SetText(opt.label)
        row.label = label

        if opt.iconAtlas or opt.iconTex then
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPoint("RIGHT", -4, 0)
            if opt.iconAtlas then
                icon:SetAtlas(opt.iconAtlas)
            else
                icon:SetTexture(opt.iconTex)
            end
        end

        -- Map Search: indented local/global sub-options (radio-style, one active at a time)
        if opt.key == "map" then
            local SUB_INDENT = 24
            local mapSubRows = {}

            for si, sub in ipairs({ { key = true, label = "Local (Zone)" }, { key = false, label = "Global (All Zones)" } }) do
                local subRow = CreateFrame("CheckButton", nil, dropdown)
                subRow:SetSize(DROPDOWN_WIDTH - 16 - SUB_INDENT, ROW_HEIGHT)
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

                subRow.isLocalKey = sub.key
                mapSubRows[si] = subRow

                subRow:SetScript("OnClick", function()
                    EasyFind.db.uiMapSearchLocal = sub.key
                    for _, sr in ipairs(mapSubRows) do
                        sr:SetChecked((EasyFind.db.uiMapSearchLocal ~= false) == sr.isLocalKey)
                    end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
            end

            row.mapSubRows = mapSubRows
            row.updateMapToggle = function()
                local isLocal = EasyFind.db.uiMapSearchLocal ~= false
                local mapChecked = EasyFind.db.uiSearchFilters and EasyFind.db.uiSearchFilters.map ~= false
                for si, sr in ipairs(mapSubRows) do
                    sr:SetChecked(isLocal == sr.isLocalKey)
                    sr:SetShown(mapChecked)
                end
            end

            -- Wrap the original OnClick to also show/hide sub-rows
            local origMapRowIdx = i
            row.mapSubRowIdx = origMapRowIdx
        end

        -- Loot: indented sub-options for search mode and spec toggle
        if opt.key == "loot" then
            local SUB_INDENT = 24
            local lootSubDefs = {
                { dbKey = "lootUpgradesOnly", label = "iLvl Upgrades Only" },
            }
            local lootSubRows = {}
            for si, sub in ipairs(lootSubDefs) do
                local subRow = CreateFrame("CheckButton", nil, dropdown)
                subRow:SetSize(DROPDOWN_WIDTH - 16 - SUB_INDENT, ROW_HEIGHT)
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

            -- Separator line under Loot checkbox
            local lootSep = dropdown:CreateTexture(nil, "ARTWORK")
            lootSep:SetHeight(1)
            lootSep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            lootSep:Hide()
            row.lootSep = lootSep

            -- Difficulty dropdown (single-select, matches EJ style)
            local DIFF_OPTIONS = {
                { key = "lfr",    label = "Raid Finder" },
                { key = "normal", label = "Normal" },
                { key = "heroic", label = "Heroic" },
                { key = "mythic", label = "Mythic" },
            }
            local DIFF_LABELS = { lfr = "Raid Finder", normal = "Normal", heroic = "Heroic", mythic = "Mythic" }

            local diffBtn = CreateFrame("Button", nil, dropdown)
            diffBtn:SetSize(120, 27)
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
            diffBtn:Hide()

            local function UpdateDiffLabel()
                local key = EasyFind.db.lootDifficulty or "normal"
                diffText:SetText(DIFF_LABELS[key] or "Normal")
            end

            -- Difficulty popup menu
            local diffPopup = CreateFrame("Frame", "EasyFindDiffPopup", UIParent, "BackdropTemplate")
            diffPopup:SetFrameStrata("TOOLTIP")
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
            local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
            local BACKDROP_POPUP = {
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = TOOLTIP_BORDER, edgeSize = 14,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            }

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
            StylePopup(specPopup)
            specPopup:EnableMouse(true)
            specPopup:Hide()

            -------------------------------------------------------------------
            -- Class flyout (opens to the RIGHT of the "Class" row)
            -------------------------------------------------------------------
            local classFlyout = CreateFrame("Frame", "EasyFindSpecFlyout", UIParent, "BackdropTemplate")
            classFlyout:SetFrameStrata("TOOLTIP")
            StylePopup(classFlyout)
            classFlyout:EnableMouse(true)
            classFlyout:Hide()

            -- Also keep "EasyFindSpecSubFlyout" name for the dropdown close guard
            local specSubFlyout = classFlyout

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
            csArrow:SetTexture("Interface\\AddOns\\EasyFind-loot-search\\flyout-arrow")
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

            local function LayoutSpecPopup()
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
            local specSelectRow = CreateFrame("Button", nil, dropdown)
            specSelectRow:SetSize(120, 27)
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
            row.updateLootToggle = function()
                local lootChecked = EasyFind.db.uiSearchFilters and EasyFind.db.uiSearchFilters.loot ~= false
                for _, sr in ipairs(lootSubRows) do
                    if sr.dbKey and sr.SetChecked then
                        sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
                    end
                    sr:SetShown(lootChecked)
                end
                if row.lootSep then
                    row.lootSep:SetShown(lootChecked)
                end
                if row.specSelectRow then
                    row.specSelectRow:SetShown(lootChecked)
                end
                if row.diffBtn then
                    row.diffBtn:SetShown(lootChecked)
                    if lootChecked and row.UpdateDiffButtons then
                        row.UpdateDiffButtons()
                    end
                    if not lootChecked and row.diffPopup then
                        row.diffPopup:Hide()
                    end
                end
                UpdateSpecLabel()
                if not lootChecked then
                    local sp = _G["EasyFindSpecPopup"]
                    if sp then sp:Hide() end
                    specFlyout:Hide()
                end
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
            if self.updateMapToggle then self.updateMapToggle() end
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
        local y = -PADDING_TOP
        -- Toggle All row
        uncheckRow:ClearAllPoints()
        uncheckRow:SetPoint("TOPLEFT", 8, y)
        dropdownNavRows[#dropdownNavRows + 1] = uncheckRow
        y = y - ROW_HEIGHT
        -- Filter rows
        for i, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRowsByIndex[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 8, y)
            dropdownNavRows[#dropdownNavRows + 1] = row
            y = y - ROW_HEIGHT
            -- Map sub-rows
            if row.mapSubRows then
                local mapChecked = EasyFind.db.uiSearchFilters and EasyFind.db.uiSearchFilters.map ~= false
                for _, sr in ipairs(row.mapSubRows) do
                    if mapChecked then
                        sr:ClearAllPoints()
                        sr:SetPoint("TOPLEFT", 8 + SUB_INDENT, y)
                        sr:Show()
                        dropdownNavRows[#dropdownNavRows + 1] = sr
                        y = y - ROW_HEIGHT
                    else
                        sr:Hide()
                    end
                end
            end
            -- Loot sub-rows
            if row.lootSubRows then
                local lootChecked = EasyFind.db.uiSearchFilters and EasyFind.db.uiSearchFilters.loot ~= false
                -- Separator line under Loot
                if row.lootSep then
                    if lootChecked then
                        row.lootSep:ClearAllPoints()
                        row.lootSep:SetPoint("LEFT", 8 + SUB_INDENT, 0)
                        row.lootSep:SetPoint("RIGHT", dropdown, "RIGHT", -8, 0)
                        row.lootSep:SetPoint("TOP", 0, y - 2)
                        row.lootSep:Show()
                        y = y - 6
                    else
                        row.lootSep:Hide()
                    end
                end
                -- Spec selector dropdown bar
                if row.specSelectRow then
                    if lootChecked then
                        row.specSelectRow:ClearAllPoints()
                        row.specSelectRow:SetPoint("TOPLEFT", 8 + SUB_INDENT, y)
                        row.specSelectRow:Show()
                        dropdownNavRows[#dropdownNavRows + 1] = row.specSelectRow
                        y = y - 24
                    else
                        row.specSelectRow:Hide()
                    end
                end
                -- Difficulty dropdown button
                if row.diffBtn then
                    if lootChecked then
                        row.diffBtn:ClearAllPoints()
                        row.diffBtn:SetPoint("TOPLEFT", 8 + SUB_INDENT, y)
                        row.diffBtn:Show()
                        dropdownNavRows[#dropdownNavRows + 1] = row.diffBtn
                        y = y - 28
                    else
                        row.diffBtn:Hide()
                    end
                end
                -- Checkbox sub-options
                for _, sr in ipairs(row.lootSubRows) do
                    if lootChecked then
                        sr:ClearAllPoints()
                        sr:SetPoint("TOPLEFT", 8 + SUB_INDENT, y)
                        sr:Show()
                        dropdownNavRows[#dropdownNavRows + 1] = sr
                        y = y - ROW_HEIGHT
                    else
                        sr:Hide()
                    end
                end
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
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            if filters[opt.key] ~= false then
                allUnchecked = false
                break
            end
        end
        local newState = allUnchecked
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            filters[opt.key] = newState
            checkRows[opt.key]:SetChecked(newState)
        end
        local mapRow = checkRows["map"]
        if mapRow and mapRow.updateMapToggle then mapRow.updateMapToggle() end
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
            if row.updateMapToggle then row.updateMapToggle() end
            if row.updateLootToggle then row.updateLootToggle() end
        end
        LayoutDropdown()
    end)

    dropdown:SetScript("OnHide", function() end)

    -- Keyboard: enable when opened via Enter on filter button
    dropdown:HookScript("OnShow", function(self)
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
                searchFrame.filterBtn.keyboardFocused = nil
                if searchFrame.filterBtn.btnBg then searchFrame.filterBtn.btnBg:Hide() end
                if searchFrame.filterBtn.UnlockHighlight then searchFrame.filterBtn:UnlockHighlight() end
            end
            if searchFrame.editBox and not searchFrame.editBox:IsMouseOver() then
                searchFrame.editBox:ClearFocus()
            end
        end
    end)

    -- Close when clicking outside (but not when interacting with spec/class flyouts)
    dropdown:SetScript("OnUpdate", function(self)
        if self:IsShown() and IsMouseButtonDown("LeftButton") then
            if not self:IsMouseOver() and not toggleBtn:IsMouseOver() then
                local sf = _G["EasyFindSpecFlyout"]
                local sp = _G["EasyFindSpecPopup"]
                local dp = _G["EasyFindDiffPopup"]
                if (sf and sf:IsShown() and sf:IsMouseOver())
                    or (sp and sp:IsShown() and sp:IsMouseOver())
                    or (dp and dp:IsShown() and dp:IsMouseOver()) then
                    return
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

-- Vibrant indent line colors for each depth level (used by Classic theme)
local INDENT_COLORS = THEMES["Classic"].indentColors

local INDENT_PX  = 20  -- pixels per depth level (icon 16 + 4 gap)
local LINE_X_OFF = 10  -- horizontal offset within each depth column (clears tab rounded corner)
local LINE_W     = 2   -- connector line thickness
local MAX_DEPTH  = #INDENT_COLORS

-- Session-only collapse state for path nodes (cleared on every new search)
local collapsedNodes = {}   -- key = "name_depth", value = true
local cachedHierarchical    -- last full hierarchical list for re-rendering after toggle
local expandedContainers = {}  -- tracks which containers have had children injected

-- Reusable tables for grouping results (wiped each search to avoid per-keystroke allocations)
local groupUI, groupMounts, groupToys, groupPets, groupOutfits, groupLoot, groupMap = {}, {}, {}, {}, {}, {}, {}
local uiSectionHeader = {
    name = "UI", depth = 0, isPathNode = true,
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
local lootSectionHeader = {
    name = "Loot", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}
local mapSectionHeader = {
    name = "Map Search", depth = 0, isPathNode = true,
    isMatch = false, isSectionHeader = true,
}

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

    resultRow:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    -- Persistent selection highlight (for keyboard navigation)
    local selTex = resultRow:CreateTexture(nil, "BACKGROUND")
    selTex:SetAllPoints()
    selTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    selTex:SetBlendMode("ADD")
    selTex:SetVertexColor(0.3, 0.6, 1.0, 0.4)
    selTex:Hide()
    resultRow.selectionHighlight = selTex

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
    pinIcon:SetSize(10, 10)
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

    -- Right-aligned currency amount label
    local amountText = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    amountText:SetJustifyH("RIGHT")
    amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
    amountText:Hide()
    resultRow.amountText = amountText

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

    resultRow:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    -- PreClick: find an empty action slot, place the outfit on it,
    -- so the secure handler's UseAction can equip it.
    resultRow:SetScript("PreClick", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        local outfitID = self.data and self.data.outfitID
        if not outfitID then return end
        -- Block if outfit swap is on cooldown
        if outfitCdStart > 0 and outfitCdDuration - (GetTime() - outfitCdStart) > 0 then
            return
        end
        local tempSlot = ns.Database and ns.Database:FindEmptyActionSlot()
        if not tempSlot then
            -- No empty slot: clear action attribute so UseAction doesn't fire
            -- on a random slot. SelectResult will handle the fallback.
            self._outfitSlot = nil
            if not InCombatLockdown() then
                self:SetAttribute("type", nil)
                self:SetAttribute("action", nil)
            end
            return
        end
        self._outfitSlot = tempSlot
        self._outfitID = outfitID
        if not InCombatLockdown() then
            self:SetAttribute("action", tempSlot)
        end
        if C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
            C_TransmogOutfitInfo.PickupOutfit(outfitID)
            PlaceAction(tempSlot)
            ClearCursor()
            -- Verify placement succeeded (some slots reject non-class actions)
            if not HasAction(tempSlot) then
                self._outfitSlot = nil
                self._outfitID = nil
                if not InCombatLockdown() then
                    self:SetAttribute("type", nil)
                    self:SetAttribute("action", nil)
                end
            end
        end
    end)
    resultRow:SetScript("PostClick", function(self, mouseButton, down)
        -- Block result selection if toy or outfit is on cooldown (keep results open).
        -- Must run before the outfit cleanup block which sets the cooldown timestamp.
        if self.data and mouseButton == "LeftButton" then
            local onCooldown = false
            if self.data.toyItemID and GetItemCooldown then
                local cdStart, cdDur = GetItemCooldown(self.data.toyItemID)
                if cdStart and cdDur and cdDur > 0 then onCooldown = true end
            end
            if self.data.outfitID and outfitCdStart > 0 then
                if outfitCdDuration - (GetTime() - outfitCdStart) > 0 then onCooldown = true end
            end
            if onCooldown then
                -- Mouse click: refocus editbox so OnEditFocusLost doesn't hide results.
                -- Keyboard (via override binding): navFrame has keyboard, don't steal focus.
                if searchFrame and searchFrame.editBox and not navFrame:IsKeyboardEnabled() then
                    searchFrame.editBox:SetFocus()
                end
                return
            end
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
        -- Right-click: show pin/unpin popup
        if mouseButton == "RightButton" and self.data then
            local pinData = self.data
            local isPinned = IsUIItemPinned(pinData)
            ShowPinPopup(self, isPinned, function()
                if isPinned then
                    UnpinUIItem(pinData)
                else
                    PinUIItem(pinData)
                end
                local editBox = searchFrame and searchFrame.editBox
                local text = editBox and editBox:GetText() or ""
                if text == "" and editBox and editBox:HasFocus() then
                    UI:ShowPinnedItems()
                else
                    UI:OnSearchTextChanged(text)
                end
            end)
            return
        end

        -- Don't allow clicking unearned currencies
        if self.isUnearnedCurrency then
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
            -- Pet tooltip
            elseif self.icon.petID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if C_PetJournal and C_PetJournal.GetPetInfoByPetID then
                    local _, speciesID = C_PetJournal.GetPetInfoByPetID(self.icon.petID)
                    if speciesID and BattlePetToolTip_ShowLink then
                        local link = C_PetJournal.GetBattlePetLink and C_PetJournal.GetBattlePetLink(self.icon.petID)
                        if link then
                            GameTooltip:SetText(link)
                            GameTooltip:Show()
                        end
                    end
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
        if self.data and (self.data.mountID or self.data.toyItemID or self.data.petID or self.data.outfitID
            or (self.data.itemID and self.data.category == "Loot")) then
            GameTooltip:Hide()
        end
        -- Clear map preview if we were showing one
        if self.data and self.data.mapSearchResult and ns.MapSearch and ns.MapSearch.ClearUIPreview then
            ns.MapSearch:ClearUIPreview()
        end
    end)

    resultRow:Hide()
    return resultRow
end

function UI:OnSearchTextChanged(text)
    -- Suppress re-renders while SelectResult is clearing text/focus
    if selectingResult then return end
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

    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Mount/Toy/Pet categories are skippable here (actual collection items).
    -- The "ui" filter is handled post-search since UI entries span many categories.
    local filters = EasyFind.db.uiSearchFilters
    local skipCategories
    if filters then
        if filters.mounts == false or filters.toys == false or filters.pets == false or filters.outfits == false or filters.loot == false then
            skipCategories = {}
            if filters.mounts == false then skipCategories["Mount"] = true end
            if filters.toys == false then skipCategories["Toy"] = true end
            if filters.pets == false then skipCategories["Pet"] = true end
            if filters.outfits == false then skipCategories["Outfit"] = true end
            if filters.loot == false then skipCategories["Loot"] = true end
        end
    end
    local results = ns.Database:SearchUI(text, skipCategories)

    -- "UI Search" filter: hide results that aren't collection items or map results
    if filters and filters.ui == false then
        local filtered = {}
        for _, r in ipairs(results) do
            local rd = r.data
            if rd and (rd.mountID or rd.toyItemID or rd.petID or rd.outfitID or (rd.itemID and rd.category == "Loot") or rd.mapSearchResult) then
                filtered[#filtered + 1] = r
            end
        end
        results = filtered
    end

    -- Map Search: search static locations and dungeon entrances, merge into results
    local mapResults
    if filters and filters.map ~= false and ns.MapSearch and ns.MapSearch.SearchForUI then
        mapResults = ns.MapSearch:SearchForUI(text)
    end

    -- Compute best score per category from flat results (before hierarchy loses scores)
    local bestCatScore = {}
    for _, r in ipairs(results) do
        local d = r.data
        local s = r.score or 0
        local cat
        if d.mountID then cat = "mounts"
        elseif d.toyItemID then cat = "toys"
        elseif d.petID then cat = "pets"
        elseif d.outfitID then cat = "outfits"
        elseif d.itemID and d.category == "Loot" then cat = "loot"
        else cat = "ui"
        end
        if s > (bestCatScore[cat] or 0) then bestCatScore[cat] = s end
    end
    if mapResults then
        for _, r in ipairs(mapResults) do
            local s = r.score or 0
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

    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    -- Container nodes (search results that have database children which didn't
    -- match the query) start collapsed - user can expand to browse children.
    for _, entry in ipairs(hierarchical) do
        if entry.isContainer then
            local key = entry.name .. "_" .. (entry.depth or 0)
            collapsedNodes[key] = true
        end
    end

    -- Group results by type: UI entries first, then collection groups, then map.
    -- Each non-UI group gets a collapsible section header.
    -- Reuse module-level tables to avoid per-keystroke allocations.
    wipe(groupUI)
    wipe(groupMounts)
    wipe(groupToys)
    wipe(groupPets)
    wipe(groupOutfits)
    wipe(groupLoot)
    wipe(groupMap)
    for _, entry in ipairs(hierarchical) do
        local d = entry.data
        if d and d.mountID then
            groupMounts[#groupMounts + 1] = entry
        elseif d and d.toyItemID then
            groupToys[#groupToys + 1] = entry
        elseif d and d.petID then
            groupPets[#groupPets + 1] = entry
        elseif d and d.outfitID then
            groupOutfits[#groupOutfits + 1] = entry
        elseif d and d.itemID and d.category == "Loot" then
            groupLoot[#groupLoot + 1] = entry
        else
            groupUI[#groupUI + 1] = entry
        end
    end
    -- Map results come from a separate search, wrap them as hierarchical entries
    if mapResults then
        for _, r in ipairs(mapResults) do
            groupMap[#groupMap + 1] = {
                name = r.data.name,
                depth = 1,
                isPathNode = false,
                isMatch = true,
                data = r.data,
            }
        end
    end
    -- Sort categories by best match score so the most relevant category appears first
    local catGroups = {}
    if #groupUI > 0 then catGroups[#catGroups + 1] = { key = "ui", score = bestCatScore.ui or 0 } end
    if #groupMounts > 0 then catGroups[#catGroups + 1] = { key = "mounts", score = bestCatScore.mounts or 0 } end
    if #groupToys > 0 then catGroups[#catGroups + 1] = { key = "toys", score = bestCatScore.toys or 0 } end
    if #groupPets > 0 then catGroups[#catGroups + 1] = { key = "pets", score = bestCatScore.pets or 0 } end
    if #groupOutfits > 0 then catGroups[#catGroups + 1] = { key = "outfits", score = bestCatScore.outfits or 0 } end
    if #groupLoot > 0 then catGroups[#catGroups + 1] = { key = "loot", score = bestCatScore.loot or 0 } end
    if #groupMap > 0 then catGroups[#catGroups + 1] = { key = "map", score = bestCatScore.map or 0 } end
    tsort(catGroups, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.key < b.key
    end)

    hierarchical = {}
    for _, cat in ipairs(catGroups) do
        if cat.key == "ui" then
            if #hierarchical > 0 then
                hierarchical[#hierarchical + 1] = uiSectionHeader
            end
            for _, e in ipairs(groupUI) do hierarchical[#hierarchical + 1] = e end
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
        elseif cat.key == "map" then
            hierarchical[#hierarchical + 1] = mapSectionHeader
            for _, e in ipairs(groupMap) do hierarchical[#hierarchical + 1] = e end
        end
    end

    -- Prepend pinned items at the top (always visible regardless of query)
    local pins = GetAllPins()
    if #pins > 0 then
        local pinnedEntries = {
            -- "Pinned Paths" collapsible header
            {
                isPinHeader = true,
                name = "Pinned Paths",
                depth = 0,
                isPathNode = true,
                isMatch = false,
            },
        }
        for _, pin in ipairs(pins) do
            tinsert(pinnedEntries, {
                name = pin.name,
                depth = 0,
                isPathNode = false,
                isMatch = true,
                isPinned = true,
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

    self:ShowHierarchicalResults(hierarchical)
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

    local theme = GetActiveTheme()
    local rowH  = theme.rowHeight
    local indPx = theme.indentPx
    local padT  = theme.resultsPadTop

    -- Apply theme backdrop to results frame
    resultsFrame:SetBackdrop(theme.resultsBackdrop)
    if theme.resultsBackdropColor then
        resultsFrame:SetBackdropColor(unpack(theme.resultsBackdropColor))
    end
    if theme.resultsBackdropBorderColor then
        resultsFrame:SetBackdropBorderColor(unpack(theme.resultsBackdropBorderColor))
    end
    local customW = EasyFind.db.uiResultsWidth
    resultsFrame:SetWidth((customW and customW > 1) and customW or theme.resultsWidth)

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

    -- Build the visible list by filtering out children of collapsed nodes
    local visible = {}
    local skipBelowDepth = nil  -- when set, skip entries deeper than this
    local skipPins = false       -- when pin header is collapsed, skip pinned entries

    for _, entry in ipairs(hierarchical) do
        local d = entry.depth or 0

        -- If we're skipping children of a collapsed node, check depth
        if skipBelowDepth then
            if d <= skipBelowDepth then
                skipBelowDepth = nil
            end
        end

        if not (skipPins and entry.isPinned) and not skipBelowDepth then
            if skipPins and not entry.isPinned then
                skipPins = false  -- past the pin section
            end
            tinsert(visible, entry)

            -- Pin header: check pinsCollapsed instead of collapsedNodes
            if entry.isPinHeader then
                if EasyFind.db.pinsCollapsed then
                    skipPins = true
                end
            -- Regular collapsed path node
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
    for _, entry in ipairs(visible) do
        if entry.isPinHeader or entry.isPinned then
            pinSlots = pinSlots + 1
        end
    end

    -- Show all results (scroll handles overflow)
    local count = mmin(#visible, MAX_BUTTON_POOL)

    -- Pre-compute whether scrolling will be needed so buttons can be narrower.
    -- Rough estimate: if all rows at base height exceed the limit, a scrollbar likely appears.
    local maxVisibleHeight = EasyFind.db.uiResultsHeight or 280
    local willScroll = #visible * rowH > maxVisibleHeight
    local scrollInset = 0
    if willScroll and resultsFrame.scrollBar then
        scrollInset = resultsFrame.scrollBar:GetWidth()
    end

    -- Pre-compute last-child flags on the VISIBLE list
    local isLastChild = {}
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

    -- Pre-compute section header separator positions
    local catSepBeforeIndex = {}
    for i = 2, count do
        if visible[i].isSectionHeader then
            local prev = visible[i - 1]
            if not prev.isPinHeader and not prev.isPinned then
                catSepBeforeIndex[i] = true
            end
        end
    end

    -- Render visible rows
    local yOffset = 0
    local pinEndYOffset = 0
    local catSepYPositions = {}
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

            -- Reposition for theme row height
            local padL = theme.resultsPadLeft or 10
            resultRow:SetSize(resultsFrame:GetWidth() - padL * 2 - scrollInset, rowH)
            resultRow:ClearAllPoints()
            resultRow:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", padL, -yOffset)

            -- Selection highlight color
            resultRow.selectionHighlight:SetVertexColor(unpack(theme.selectionColor))

            resultRow.data = data
            -- Set secure action attributes for toys, mounts, and outfits
            if not InCombatLockdown() then
                if data and data.toyItemID then
                    resultRow:SetAttribute("type", "toy")
                    resultRow:SetAttribute("toy", data.toyItemID)
                    resultRow:SetAttribute("macrotext", nil)
                    resultRow:SetAttribute("action", nil)
                elseif data and data.mountID then
                    resultRow:SetAttribute("type", "macro")
                    resultRow:SetAttribute("macrotext", "/cancelform [form]")
                    resultRow:SetAttribute("toy", nil)
                    resultRow:SetAttribute("action", nil)
                elseif data and data.outfitID then
                    -- type="action" is set here; PreClick sets the actual slot dynamically
                    resultRow:SetAttribute("type", "action")
                    resultRow:SetAttribute("action", 0)
                    resultRow:SetAttribute("toy", nil)
                    resultRow:SetAttribute("macrotext", nil)
                else
                    resultRow:SetAttribute("type", nil)
                    resultRow:SetAttribute("toy", nil)
                    resultRow:SetAttribute("macrotext", nil)
                    resultRow:SetAttribute("action", nil)
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
            if not entry.isPinHeader and not (theme.showHeaderTab and entry.isPathNode) then
                local indentPixels = depth * indPx
                resultRow.icon:ClearAllPoints()
                resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)

                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                resultRow.text:SetText(entry.name)

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

            -- Set icon
            local iconSet = false
            local isCurrencyItem = data and data.category == "Currency"
            local isCurrencyLeaf = isCurrencyItem and not entry.isPathNode
            local isReputationLeaf = data and data.category == "Reputation" and not entry.isPathNode

            if entry.isPinHeader then
                -- Pin header: no row icon (toggle is handled by pinToggle)
                SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
                iconSet = true

            elseif theme.showHeaderTab and entry.isPathNode then
                SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
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
                    resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    -- Anchor amount text to left of icon
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
                else
                    SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end

                -- Anchor name text from indent to amount (no left icon, tiny buffer)
                local indentPixels = depth * indPx + 4
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                iconSet = true

            -- Mount/Toy/Pet leaves: icon goes to right side (same layout as currency icons)
            elseif not iconSet and data and (data.mountID or data.toyItemID or data.petID or data.outfitID) then
                local iconFileID = data.icon
                local rightOffset = -5

                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                    resultRow.icon:Show()
                    resultRow.icon.mountID = data.mountID
                    resultRow.icon.toyItemID = data.toyItemID
                    resultRow.icon.petID = data.petID
                    resultRow.icon.spellID = data.spellID
                    resultRow.icon.outfitID = data.outfitID
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
                    SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
                end

                -- Outfit lock overlay (dashed border when locked)
                if data.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
                    UI:UpdateOutfitLockOverlay(resultRow, C_TransmogOutfitInfo.IsLockedOutfit(data.outfitID))
                elseif resultRow._lockOverlay then
                    resultRow._lockOverlay:Hide()
                end

                -- Cooldown sweep overlay (toys and outfits)
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
                    resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    resultRow.icon.lootItemID = data.itemID
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
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

            -- Map search results: left-side category icon + nav pin on right
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
                    resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                    resultRow.icon:ClearAllPoints()
                    local indentPixels = depth * indPx + 4
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.icon:Show()
                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                else
                    local indentPixels = depth * indPx + 4
                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                end
                resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
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
                        SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
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

            if not iconSet and data and data.icon then
                SetRowIcon(resultRow, "file", data.icon, theme.iconSize)
                iconSet = true
            end

            -- Portrait menu items: use the player portrait as the icon
            if not iconSet and data and data.steps then
                for _, step in ipairs(data.steps) do
                    if step.portraitMenu or step.portraitMenuOption then
                        SetPortraitTexture(resultRow.icon, "player")
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                        resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
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
                                        resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
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
                                resultRow.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
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
                    SetRowIcon(resultRow, kind, texture, theme.iconSize)
                    iconSet = true
                end
            end

            if not iconSet then
                SetRowIcon(resultRow, "file", 134400, theme.iconSize)
            end

            -- Show pin indicator for pinned entries
            if entry.isPinned and resultRow.pinIcon then
                -- Anchor pin icon to left edge of text, not the (possibly hidden) row icon
                resultRow.pinIcon:ClearAllPoints()
                resultRow.pinIcon:SetPoint("RIGHT", resultRow.text, "LEFT", 0, 0)
                resultRow.pinIcon:Show()
                -- Pinned entries during search: show path prefix in name
                if data and data.path and #data.path > 0 then
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

            yOffset = yOffset + actualH
            resultRow:Show()
        else
            resultRow:Hide()
            resultRow.isPinHeader = false
            if not InCombatLockdown() then
                resultRow:SetAttribute("type", nil)
                resultRow:SetAttribute("toy", nil)
                resultRow:SetAttribute("action", nil)
            end
            resultRow.headerGrad:Hide()
            resultRow.headerTab:Hide()
            resultRow.separator:Hide()
            resultRow.repBar:Hide()
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

    -- Anchor results above or below based on setting
    resultsFrame:ClearAllPoints()
    if EasyFind.db.uiResultsAbove then
        resultsFrame:SetPoint("BOTTOM", searchFrame, "TOP", 0, -5)
    else
        resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 2)
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

function UI:HideResults()
    if not searchFrame then return end
    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
    if searchFrame.ClearToolbarFocus then searchFrame.ClearToolbarFocus() end
    if not resultsFrame then return end
    resultsFrame:Hide()
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
    local entries = {
        -- "Pinned Paths" collapsible header
        {
            isPinHeader = true,
            name = "Pinned Paths",
            depth = 0,
            isPathNode = true,
            isMatch = false,
        },
    }
    for _, pin in ipairs(pins) do
        tinsert(entries, {
            name = pin.name,
            depth = 0,
            isPathNode = false,
            isMatch = true,
            isPinned = true,
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
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = resultButtons[i]
        if not resultRow then break end
        if resultRow.selectionHighlight then
            resultRow.selectionHighlight:SetShown(i == selectedIndex and not toggleFocused)
        end
        -- Tab selection highlight (Retail theme)
        if resultRow.tabSelectionHighlight then
            resultRow.tabSelectionHighlight:SetShown(i == selectedIndex and resultRow.headerTab:IsShown() and not toggleFocused)
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
            if resultRow.tabHoverOverlay then
                resultRow.tabHoverOverlay:SetShown(showToggle and not isPinToggle)
            end
            if resultRow.tabText then
                if showToggle and not isPinToggle then
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
            searchFrame.editBox:SetFocus()
        end
    end

    -- Bind Enter to the selected result button when it's an outfit or toy,
    -- so the secure action handler fires on keypress (same as mouse click).
    if not InCombatLockdown() then
        local selRow = selectedIndex > 0 and resultButtons[selectedIndex]
        local rd = selRow and selRow.data
        if rd and (rd.outfitID or rd.toyItemID) then
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
    local situationsTab
    if tabHeaders then
        for _, tab in ipairs({ tabHeaders:GetChildren() }) do
            if tab.GetText and tab:GetText() == "Situations" then
                tab:Hide()
                hidden[#hidden + 1] = tab
                situationsTab = tab
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

function UI:SelectResult(data)
    if not data then return end

    selectingResult = true
    searchFrame.editBox:SetText("")
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:Show()
    selectingResult = false
    self:HideResults()

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

    -- Outfit: equip handled by SecureActionButton (mouse click or Enter binding).
    if data.outfitID then return end

    -- Loot: Shift+click opens dressing room, regular click navigates EJ
    if data.itemID and data.category == "Loot" then
        local lootLink = ns.Database and ns.Database:GetLootItemLink(data)
        if IsShiftKeyDown() and lootLink then
            DressUpItemLink(lootLink)
            return
        end

        -- Sync EJ loot filter so the item is visible when we navigate there
        if ns.Database then ns.Database:SyncEJLootFilter() end

        local isRaid = data.lootSourceType == "Raid"
        local tabIndex = isRaid and 5 or 4
        local guideData = {
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = tabIndex },
                { waitForFrame = "EncounterJournal", ejInstance = data.lootInstanceName },
                { waitForFrame = "EncounterJournal", ejBoss = data.lootSourceName, ejEncounterID = data.encounterID },
                { waitForFrame = "EncounterJournal", ejLootTab = true },
                { waitForFrame = "EncounterJournal", ejLootItem = data.itemID, ejLootItemName = data.name },
            },
        }

        if EasyFind.db.directOpen then
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

    -- Toy: handled by SecureActionButton on mousedown (UseToyByItemID is protected)
    if data.toyItemID then return end

    -- Pet: summon/dismiss
    if data.petID then
        if C_PetJournal and C_PetJournal.SummonPetByGUID then
            C_PetJournal.SummonPetByGUID(data.petID)
        end
        return
    end

    -- Map search result: open world map and search
    if data.mapSearchResult then
        if ns.MapSearch and ns.MapSearch.HandleUISearchClick then
            ns.MapSearch:HandleUISearchClick(data)
        end
        return
    end

    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end

    if EasyFind.db.directOpen and data.steps then
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

            -- EJ instance: find by name in ScrollBox and click
            if step.ejInstance then
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

            -- EJ boss: find by name in BossesScrollBox and click
            if step.ejBoss then
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

            -- EJ loot tab: click
            if step.ejLootTab then
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

        -- Hand off remaining steps to the guided highlight
        if not finalStepNavigable and Highlight then
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
    if EasyFind.db.smartShow then
        searchFrame.hoverZone:Show()
        -- Briefly reveal the bar then let smart-show fade it back out
        searchFrame.smartShowFadeIn()
        C_Timer.After(1.5, function()
            if EasyFind.db.smartShow then
                searchFrame.smartShowFadeOut()
            end
        end)
    end
    if andFocus then
        -- Delay focus by one frame so the keybind key-press that triggered
        -- this Show() doesn't get typed into the editbox.
        C_Timer.After(0, function()
            if searchFrame:IsShown() then
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
    searchFrame.editBox.placeholder:Show()
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

function UI:UpdateOpacity()
    if not searchFrame then return end
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    local theme = GetActiveTheme()
    if theme.searchBarRounded then
        ns.SetSearchBorderBgAlpha(searchFrame, alpha)
    else
        searchFrame:SetBackdropColor(0, 0, 0, alpha)
    end
end

function UI:UpdateSearchBarTheme()
    if not searchFrame then return end
    local theme = GetActiveTheme()
    local scale = EasyFind.db.fontSize or 1.0
    local WHITE8x8 = "Interface\\BUTTONS\\WHITE8x8"
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        ns.SetSearchBorderShown(searchFrame, true)
        ns.ScaleSearchBorder(searchFrame, scale)
        ns.SetSearchBorderBgAlpha(searchFrame, alpha)
    else
        searchFrame:SetBackdrop({
            bgFile = WHITE8x8,
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20 * scale,
            insets = { left = 5 * scale, right = 5 * scale, top = 5 * scale, bottom = 5 * scale }
        })
        searchFrame:SetBackdropBorderColor(1, 1, 1, 1)
        searchFrame:SetBackdropColor(0, 0, 0, alpha)
        ns.SetSearchBorderShown(searchFrame, false)
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
        -- Disable smart show: hide hover zone, restore normal opacity
        searchFrame.hoverZone:Hide()
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
    f:SetSize(410, 265)
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
        "|cffFFD100\226\128\162|r |cffffffffRare Mob Tracking|r\n" ..
        "        Active rares appear as searchable pins on the world map\n" ..
        "        Toggle auto-tracking to pin all nearby rares automatically\n" ..
        "|cffFFD100\226\128\162|r |cffffffffGreat Vault|r\n" ..
        "        Rewards panel now searchable in UI search"
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

-- FIRST-TIME SETUP OVERLAY
-- Shown once on fresh install to let the user position & scale the search
-- bar before normal use.  Persisted via EasyFind.db.setupComplete.
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

    -- Golden glow overlay
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

    -- "EasyFind" label overlaid on the glow (like edit-mode frame labels)
    local setupLabel = glow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setupLabel:SetPoint("CENTER", glow, "CENTER", 0, 0)
    setupLabel:SetText("EasyFind")
    setupLabel:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)

    -- Resize handle (bottom-left corner)
    local resizer = CreateFrame("Button", nil, glow)
    resizer:SetSize(16, 16)
    resizer:SetPoint("BOTTOMLEFT", glow, "BOTTOMLEFT", 0, 0)
    resizer:EnableMouse(true)
    resizer:RegisterForDrag("LeftButton")

    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:GetNormalTexture():SetTexCoord(1, 0, 0, 1)   -- flip for bottom-left
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:GetHighlightTexture():SetTexCoord(1, 0, 0, 1)
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizer:GetPushedTexture():SetTexCoord(1, 0, 0, 1)

    resizer:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    resizer:SetScript("OnLeave", GameTooltip_Hide)

    resizer.dragging = false
    resizer.lastY = nil
    resizer:SetScript("OnDragStart", function(self)
        self.dragging = true
        local _, cy = GetCursorPosition()
        self.lastY = cy / UIParent:GetEffectiveScale()
    end)
    resizer:SetScript("OnDragStop", function(self)
        self.dragging = false
        self.lastY = nil
    end)
    resizer:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local _, cy = GetCursorPosition()
        cy = cy / UIParent:GetEffectiveScale()
        if self.lastY then
            local dy = self.lastY - cy   -- drag down = bigger for bottom-left handle
            local curScale = EasyFind.db.uiSearchScale or 1.0
            local newScale = curScale + dy * 0.005
            newScale = mmax(0.5, mmin(2.0, newScale))
            EasyFind.db.uiSearchScale = newScale
            EasyFind.db.uiResultsScale = newScale
            searchFrame:SetScale(newScale)
            if resultsFrame then resultsFrame:SetScale(newScale) end
        end
        self.lastY = cy
    end)

    -- Instruction panel (anchored below the glow)
    local panel = CreateFrame("Frame", nil, glow, "BackdropTemplate")
    panel:SetSize(340, 215)
    panel:SetPoint("TOP", glow, "BOTTOM", 0, -6)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])

    -- Top header lines (centered)
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header:SetPoint("TOP", panel, "TOP", 0, -12)
    header:SetWidth(310)
    header:SetJustifyH("CENTER")
    header:SetText(
        "|cffffffffDrag the search bar to position it.|r\n" ..
        "|cffffffffUse the corner handle to resize.|r"
    )

    -- Tip line (left-aligned, anchored below header)
    local tip = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    tip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -8)
    tip:SetJustifyH("LEFT")
    tip:SetText(
        "\226\128\162 |cff999999Hold |cffFFD100Shift|r|cff999999 + drag to reposition later.|r"
    )

    -- Horizontal separator between tip and Smart Show section
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -6)
    sep:SetPoint("TOPRIGHT", tip, "BOTTOMRIGHT", 0, -6)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Smart Show checkbox (default checked - matches DB_DEFAULTS.smartShow = true)
    local smartShowCheckbox = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    smartShowCheckbox:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -6)
    smartShowCheckbox.Text:SetText("|cffFFD100Smart Show|r |cff999999(Recommended)|r")
    smartShowCheckbox:SetChecked(false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        -- Update live so the user can see the hover behavior immediately
        EasyFind.db.smartShow = self:GetChecked()
        UI:UpdateSmartShow()
    end)

    -- Smart Show description - uses same font as checkbox text for consistency
    local smartDesc = smartShowCheckbox:CreateFontString(nil, "OVERLAY")
    smartDesc:SetFontObject(smartShowCheckbox.Text:GetFontObject())
    smartDesc:SetPoint("TOPLEFT", smartShowCheckbox.Text, "BOTTOMLEFT", 0, -2)
    smartDesc:SetWidth(284)
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
    fadeDesc:SetWidth(284)
    fadeDesc:SetJustifyH("LEFT")
    fadeDesc:SetText("|cff999999Reduces bar opacity while your character is moving.|r")

    -- Footer note
    local footer = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    footer:SetPoint("BOTTOM", panel, "BOTTOM", 0, 36)
    footer:SetWidth(310)
    footer:SetJustifyH("CENTER")
    footer:SetText("|cff666666These and more settings can be changed in |cffFFD100/ef|r|cff666666.|r")

    -- Done button
    local doneBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 12)
    doneBtn:SetText("Done")

    -- During setup: allow drag without holding Shift
    searchFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    -- Done handler: persist, cleanup, restore normal drag
    doneBtn:SetScript("OnClick", function()
        EasyFind.db.setupComplete = true

        -- Save current position
        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}

        -- Destroy overlay & restore normal state
        searchFrame.setupMode = nil
        searchFrame.editBox:EnableMouse(true)
        UI:UpdateSearchBarTheme()  -- restore proper backdrop colors
        glow:SetScript("OnUpdate", nil)
        resizer:SetScript("OnUpdate", nil)
        glow:Hide()
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
    local clearSz = ns.CLEAR_BTN_SIZE * scale
    searchFrame:SetHeight(barH)
    searchFrame.editBox:SetHeight(contentSz)
    searchFrame.searchIcon:SetSize(iconSz, iconSz)
    if searchFrame.modeBtn then
        searchFrame.modeBtn:SetWidth(barH)
    end
    if searchFrame.filterBtn then
        searchFrame.filterBtn:SetWidth(barH)
    end
    if searchFrame.clearTextBtn then
        searchFrame.clearTextBtn:SetSize(clearSz, clearSz)
    end

    local theme = GetActiveTheme()
    local WHITE8x8 = "Interface\\BUTTONS\\WHITE8x8"
    local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        ns.ScaleSearchBorder(searchFrame, scale)
        ns.SetSearchBorderBgAlpha(searchFrame, alpha)
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
