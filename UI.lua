local ADDON_NAME, ns = ...

local UI = {}
ns.UI = UI

local Utils = ns.Utils
local GetButtonText         = Utils.GetButtonText
local SearchFrameTree       = Utils.SearchFrameTree
local SearchFrameTreeFuzzy  = Utils.SearchFrameTreeFuzzy
local ClickButton           = Utils.ClickButton
local DebugPrint            = Utils.DebugPrint
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local tinsert, tsort, tconcat, tremove = Utils.tinsert, Utils.tsort, Utils.tconcat, Utils.tremove
local mmin, mmax = Utils.mmin, Utils.mmax

local GOLD_COLOR = ns.GOLD_COLOR
local YELLOW_HIGHLIGHT = ns.YELLOW_HIGHLIGHT
local DEFAULT_OPACITY = ns.DEFAULT_OPACITY
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER
local DARK_PANEL_BG = ns.DARK_PANEL_BG
local RESULT_ICON_SIZE = ns.RESULT_ICON_SIZE

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local GetCursorPosition  = GetCursorPosition
local hooksecurefunc     = hooksecurefunc
local wipe               = wipe

local searchFrame
local resultsFrame
local resultButtons = {}
local MAX_BUTTON_POOL = 50  -- Maximum buttons (scroll handles overflow beyond this)
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult

-- PIN HELPERS

local function GetUIPinKey(data)
    if not data or not data.name then return "" end
    return data.name .. "|" .. tconcat(data.path or {}, ">")
end

local function CleanUIForStorage(data)
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        elseif t == "table" then
            -- Deep-copy simple arrays (path, steps, keywords)
            if k == "path" or k == "steps" or k == "keywords" then
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
    end
    return clean
end

local function IsUIItemPinned(data)
    local key = GetUIPinKey(data)
    for _, pin in ipairs(EasyFind.db.pinnedUIItems) do
        if GetUIPinKey(pin) == key then return true end
    end
    return false
end

local function PinUIItem(data)
    if IsUIItemPinned(data) then return end
    local clean = CleanUIForStorage(data)
    clean.isPinned = true
    tinsert(EasyFind.db.pinnedUIItems, clean)
end

local function UnpinUIItem(data)
    local key = GetUIPinKey(data)
    local items = EasyFind.db.pinnedUIItems
    for i = #items, 1, -1 do
        if GetUIPinKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
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
    if kind == "atlas" then
        btn.icon:SetAtlas(value)
    elseif kind == "file" or kind == "path" then
        btn.icon:SetTexture(value)
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
local unearnedTooltip      -- Custom tooltip for unearned currencies

-- THEME DEFINITIONS
local THEMES = {}

-- Classic: colorful tree connectors, +/- icons, gold leaf text
THEMES["Classic"] = {
    rowHeight       = 22,
    indentPx        = 20,
    lineWidth       = 2,
    resultsWidth    = 380,
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
    resultsWidth    = 390,
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

    -- Block focus during init window - prevents stealing keyboard input on login/reload.
    -- Something (possibly the WoW client) focuses visible EditBoxes after creation;
    -- blockFocus rejects it in OnEditFocusGained regardless of timing.
    searchFrame.editBox.blockFocus = true
    searchFrame.editBox:ClearFocus()
    C_Timer.After(1, function()
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox.blockFocus = nil
            searchFrame.editBox:ClearFocus()
        end
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
    searchFrame:SetFrameStrata("HIGH")
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

    -- Apply theme-appropriate backdrop (border only - atlas fills the background)
    local theme = GetActiveTheme()
    if theme.searchBarRounded then
        searchFrame:SetBackdrop({
            edgeFile = TOOLTIP_BORDER,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)
    else
        searchFrame:SetBackdrop({
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
    end

    local bgTex = searchFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgTex:SetPoint("TOPLEFT", 4, -4)
    bgTex:SetPoint("BOTTOMRIGHT", -4, 4)
    bgTex:SetColorTexture(0, 0, 0, EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
    searchFrame.bgTex = bgTex

    -- Search icon
    local contentSz = ns.SEARCHBAR_HEIGHT * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(iconSz, iconSz)
    searchIcon:SetPoint("LEFT", searchFrame, "LEFT", 12, 0)
    searchIcon:SetAtlas("common-search-magnifyingglass")
    searchFrame.searchIcon = searchIcon

    -- Editbox
    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetHeight(contentSz)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
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
        -- Text and results stay visible; user can click back in to resume
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

    local function StartKeyRepeat(key, action)
        action()
        repeatKey = key
        repeatAction = action
        repeatHeld = 0
        repeatNext = REPEAT_INITIAL
        repeatActive = true
    end

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

    -- Toolbar keyboard focus: 0 = editbox, 1 = clear button
    local toolbarFocus = 0

    local toolbarHighlight = CreateFrame("Frame", nil, UIParent)
    toolbarHighlight:SetFrameStrata("FULLSCREEN_DIALOG")
    toolbarHighlight:SetFrameLevel(10000)
    toolbarHighlight:Hide()
    local tbHL = toolbarHighlight:CreateTexture(nil, "OVERLAY")
    tbHL:SetAllPoints()
    tbHL:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    tbHL:SetBlendMode("ADD")
    tbHL:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.5)

    local function GetToolbarControls()
        local controls = {}
        if clearTextBtn:IsShown() then
            tinsert(controls, clearTextBtn)
        end
        return controls
    end

    local function SetToolbarFocus(idx)
        toolbarFocus = idx
        local controls = GetToolbarControls()
        local target = controls[idx]
        if target then
            toolbarHighlight:SetParent(target)
            toolbarHighlight:ClearAllPoints()
            toolbarHighlight:SetAllPoints(target)
            toolbarHighlight:Show()
        else
            toolbarHighlight:Hide()
        end
    end

    local function ClearToolbarFocus()
        toolbarFocus = 0
        toolbarHighlight:Hide()
    end
    searchFrame.ClearToolbarFocus = ClearToolbarFocus

    -- Keyboard capture frame for navigating results without editbox focus
    navFrame = CreateFrame("Frame", nil, searchFrame)
    navFrame:SetSize(1, 1)
    navFrame:EnableKeyboard(false)
    navFrame:SetPropagateKeyboardInput(false)

    local function HandleNavKeyDown(key)
        if key == "DOWN" then
            if IsControlKeyDown() then
                UI:JumpToEnd()
            else
                StartKeyRepeat(key, function() UI:MoveSelection(1) end)
            end
        elseif key == "UP" then
            if IsControlKeyDown() then
                UI:JumpToStart()
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
            if IsShiftKeyDown() then
                if selectedIndex > 0 and toggleFocused then
                    toggleFocused = false
                    UI:UpdateSelectionHighlight()
                else
                    local controls = GetToolbarControls()
                    if #controls > 0 and (toolbarFocus > 0 or selectedIndex == 0) then
                        local newIdx = (toolbarFocus > 0) and (toolbarFocus - 1) or #controls
                        if newIdx == 0 then
                            ClearToolbarFocus()
                            selectedIndex = 0
                            UI:UpdateSelectionHighlight()
                        else
                            SetToolbarFocus(newIdx)
                        end
                    else
                        StartKeyRepeat(key, function() UI:MoveSelection(-1) end)
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
                    local newIdx = toolbarFocus + 1
                    if newIdx > #controls then
                        ClearToolbarFocus()
                        selectedIndex = 0
                        UI:UpdateSelectionHighlight()
                    else
                        SetToolbarFocus(newIdx)
                    end
                else
                    StartKeyRepeat(key, function() UI:MoveSelection(1) end)
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
            elseif toggleFocused then
                toggleFocused = false
                UI:UpdateSelectionHighlight()
            else
                selectedIndex = 0
                toggleFocused = false
                navFrame:EnableKeyboard(false)
                if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
                UI:UpdateSelectionHighlight(true)
            end
        elseif key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
               or key == "LALT" or key == "RALT" then
            -- Modifier keys alone: stay in nav mode
        else
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
        HandleNavKeyDown(key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        if repeatKey == key then StopKeyRepeat() end
    end)

    -- Shift+Tab from editbox: transition to toolbar navigation
    -- Tab from editbox: toolbar first, then results
    editBox:HookScript("OnKeyDown", function(self, key)
        if key ~= "TAB" then return end
        local controls = GetToolbarControls()
        if IsShiftKeyDown() then
            if #controls > 0 then
                self:ClearFocus()
                navFrame:EnableKeyboard(true)
                SetToolbarFocus(#controls)
            end
        else
            if #controls > 0 then
                self:ClearFocus()
                navFrame:EnableKeyboard(true)
                SetToolbarFocus(1)
            elseif resultsFrame and resultsFrame:IsShown() and selectedIndex == 0 then
                UI:MoveSelection(1)
            end
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
    hoverZone:SetFrameStrata("HIGH")
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

    -- OnUpdate: detect movement and adjust opacity accordingly
    searchFrame:HookScript("OnUpdate", function(self)
        -- Skip if user wants static opacity
        if EasyFind.db.staticOpacity then
            if moveFading then
                moveFading = false
                self:SetAlpha(1.0)
            end
            return
        end
        -- Don't interfere while SmartShow has the bar hidden
        if EasyFind.db.smartShow and not smartShowVisible then return end

        local speed = GetUnitSpeed("player")
        local moving = speed > 0
        local hovering = self:IsMouseOver()
            or (resultsFrame and resultsFrame:IsShown() and resultsFrame:IsMouseOver())

        local shouldFade = moving and not hovering

        if shouldFade ~= moveFading then
            moveFading = shouldFade
            -- Cancel any active UIFrameFade animation so it can't overwrite our alpha
            UIFrameFadeRemoveFrame(self)
            self:SetAlpha(GetEffectiveAlpha())
        end
    end)
end

function UI:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", searchFrame, "BackdropTemplate")
    resultsFrame:SetWidth(380)  -- Wide to accommodate tree indentation
    resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 5)
    resultsFrame:SetFrameStrata("HIGH")
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
        if not resultsFrame:IsShown() or not cachedHierarchical then return end
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.02, function()
            resizeTimer = nil
            UI:ShowHierarchicalResults(cachedHierarchical, true)
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
    local resultRow = CreateFrame("Button", "EasyFindResultButton"..index, scrollChild)
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
    headerTab:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        parent:GetScript("OnClick")(parent)
    end)
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

    -- +/- button texture on right side (using atlas)
    local toggleIcon = headerTab:CreateTexture(nil, "ARTWORK")
    toggleIcon:SetSize(18, 17)
    toggleIcon:SetPoint("RIGHT", headerTab, "RIGHT", -8, 0)
    toggleIcon:SetAtlas("QuestLog-icon-expand")
    resultRow.toggleIcon = toggleIcon

    local toggleHighlight = resultRow:CreateTexture(nil, "OVERLAY")
    toggleHighlight:SetSize(26, 25)
    toggleHighlight:SetPoint("CENTER", toggleIcon, "CENTER", 0, 0)
    toggleHighlight:SetColorTexture(1, 1, 0, 0.3)
    toggleHighlight:Hide()
    resultRow.toggleHighlight = toggleHighlight

    -- Header name text (child of headerTab)
    local tabText = headerTab:CreateFontString(nil, "OVERLAY", "Game15Font_Shadow")
    tabText:SetPoint("LEFT", headerTab, "LEFT", 10, 0)
    tabText:SetPoint("RIGHT", toggleIcon, "LEFT", -4, 0)
    tabText:SetJustifyH("LEFT")
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
        if parent.toggleIcon then
            parent.toggleIcon:SetVertexColor(1.0, 1.0, 0.0, 1.0)  -- bright pure yellow
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
        if parent.toggleIcon then
            parent.toggleIcon:SetVertexColor(1.0, 1.0, 1.0, 1.0)  -- normal (atlas provides color)
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
    local REP_BAR_WIDTH = 100
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
    resultRow:SetScript("OnClick", function(self, mouseButton, down)
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
            -- Check if click was near the +/- toggle icon
            local cursorX = GetCursorPosition()
            local scale = self:GetEffectiveScale()
            local isRetailHeader = self.headerTab and self.headerTab:IsShown()
            local isToggleClick = false

            if isRetailHeader then
                -- Retail: toggle icon on right side - generous 55px zone
                local btnRight = self:GetRight() * scale
                isToggleClick = cursorX >= (btnRight - 55 * scale)
            else
                -- Classic: +/- icon on left side - 35px zone from icon start
                local btnLeft = self:GetLeft() * scale
                local depth = self.pathNodeDepth or 0
                local iconLeft = btnLeft + depth * 20 * scale  -- INDENT_PX = 20
                isToggleClick = cursorX <= (iconLeft + 35 * scale)
            end

            if isToggleClick then
                local key = (self.pathNodeName or "") .. "_" .. (self.pathNodeDepth or 0)
                local wasCollapsed = collapsedNodes[key]
                collapsedNodes[key] = not collapsedNodes[key]
                -- Lazy-expand container nodes on first open
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
        elseif self.data then
            UI:SelectResult(self.data)
        end
    end)

    -- Tooltip for unearned currencies
    resultRow:SetScript("OnEnter", function(self)
        if self.isUnearnedCurrency then
            if unearnedTooltip then
                -- Update tooltip text based on whether it's a parent tab or individual currency
                local tooltipText = self.isPathNode and "This tab does not exist on this character yet" or "Currency not yet earned"
                unearnedTooltip.text:SetText(tooltipText)

                -- Resize tooltip to fit text
                local textWidth = unearnedTooltip.text:GetStringWidth()
                local textHeight = unearnedTooltip.text:GetStringHeight()
                unearnedTooltip:SetSize(textWidth + 20, textHeight + 16)

                -- Position tooltip at cursor
                local scale = UIParent:GetEffectiveScale()
                local x, y = GetCursorPosition()
                unearnedTooltip:ClearAllPoints()
                unearnedTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 10, y / scale + 10)
                unearnedTooltip:Show()
            end
        end
    end)

    resultRow:SetScript("OnLeave", function(self)
        -- Only hide our custom tooltip - let WoW manage GameTooltip naturally
        if unearnedTooltip then
            unearnedTooltip:Hide()
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
    local results = ns.Database:SearchUI(text)
    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    -- Container nodes (search results that have database children which didn't
    -- match the query) start collapsed - user can expand to browse children.
    for _, entry in ipairs(hierarchical) do
        if entry.isContainer then
            local key = entry.name .. "_" .. (entry.depth or 0)
            collapsedNodes[key] = true
        end
    end

    -- Prepend pinned items at the top (always visible regardless of query)
    local pins = EasyFind.db.pinnedUIItems
    if pins and #pins > 0 then
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
        tex:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -4, -4)
        resultsFrame.bgAtlasTex = tex
    end
    if theme.resultsBgAtlas then
        local info = C_Texture.GetAtlasInfo(theme.resultsBgAtlas)
        if info then
            resultsFrame.bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)  -- false = allow stretching
            resultsFrame.bgAtlasTex:SetHeight(info.height)  -- native height, clipped by frame
        else
            resultsFrame.bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
            resultsFrame.bgAtlasTex:SetHeight(468)  -- fallback
        end
        resultsFrame.bgAtlasTex:Show()
        resultsFrame:SetClipsChildren(true)
    else
        resultsFrame.bgAtlasTex:Hide()
        resultsFrame:SetClipsChildren(false)
    end
    
    -- ----------------------------------------------------------------
    -- Build the visible list by filtering out children of collapsed nodes
    -- ----------------------------------------------------------------
    local visible = {}
    local skipBelowDepth = nil  -- when set, skip entries deeper than this
    local skipPins = false       -- when pin header is collapsed, skip pinned entries

    for _, entry in ipairs(hierarchical) do
        local d = entry.depth or 0

        -- If we're skipping children of a collapsed node, check depth
        if skipBelowDepth then
            if d > skipBelowDepth then
                -- Still inside collapsed subtree - skip
            else
                -- Back to same or higher depth - stop skipping
                skipBelowDepth = nil
            end
        end

        -- Skip pinned items when pin header is collapsed
        if skipPins and entry.isPinned then
            -- skip this pinned entry
        elseif not skipBelowDepth then
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

    -- Pre-compute whether scrolling will be needed so buttons can be narrower
    local maxVisibleRows = EasyFind.db.uiMaxResults or 10
    local willScroll = count > maxVisibleRows
    local scrollInset = willScroll and 10 or 0

    -- ----------------------------------------------------------------
    -- Pre-compute last-child flags on the VISIBLE list
    -- ----------------------------------------------------------------
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

    -- ----------------------------------------------------------------
    -- Determine pin separator placement
    -- ----------------------------------------------------------------
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

    -- ----------------------------------------------------------------
    -- Render visible rows
    -- ----------------------------------------------------------------
    local yOffset = 0
    local pinEndYOffset = 0
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
            resultRow.isPathNode = entry.isPathNode
            resultRow.isPinHeader = entry.isPinHeader or false
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
            if not entry.isPinHeader and theme.showSeparators then
                local sc = theme.separatorColor
                resultRow.separator:SetColorTexture(sc[1], sc[2], sc[3], sc[4])
                resultRow.separator:Show()
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
            if entry.isPinHeader then
                -- Pin header: text already positioned in header styling; hide icon
            elseif not (theme.showHeaderTab and entry.isPathNode) then
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
                    resultRow.repClip:SetWidth(mmax(fill * 100, 0.1))
                    resultRow.repBarText:SetText(standingText)

                    if entry.isPathNode and theme.showHeaderTab then
                        -- Tab theme: place rep bar left of the toggle icon
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow.toggleIcon, "LEFT", -4, 0)
                        resultRow.tabText:ClearAllPoints()
                        resultRow.tabText:SetPoint("LEFT", resultRow.headerTab, "LEFT", 10, 0)
                        resultRow.tabText:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                    elseif entry.isPathNode then
                        -- Classic theme: rep bar on right, text between icon and bar
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                    else
                        -- Leaf: default position, hide icon, anchor text to bar
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                        SetRowIcon(resultRow, "hidden", nil, theme.iconSize)
                        local indentPixels = depth * indPx + 4
                        resultRow.text:ClearAllPoints()
                        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                        resultRow.text:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
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
                -- Gray separator between pinned items (skip after header, skip last pin)
                local isLastPin = (i == lastPinIndex)
                if i > 1 and not isLastPin and visible[i - 1] and not visible[i - 1].isPinHeader then
                    resultRow.separator:SetColorTexture(0.4, 0.4, 0.4, 0.4)
                    resultRow.separator:Show()
                end
            end

            -- Measure text height and expand row if text wraps
            local actualH = rowH
            local textObj
            if theme.showHeaderTab and entry.isPathNode and resultRow.headerTab:IsShown() then
                textObj = resultRow.tabText
            elseif not entry.isPinHeader then
                textObj = resultRow.text
            end
            if textObj then
                local textHeight = textObj:GetStringHeight()
                local minH = textHeight / ns.SEARCHBAR_FILL
                if minH > rowH then
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

    -- Calculate total content height vs max visible height
    local totalContentHeight = yOffset
    local maxVisibleHeight = maxVisibleRows * rowH
    local hasScroll = totalContentHeight > maxVisibleHeight
    local visibleHeight = hasScroll and maxVisibleHeight or totalContentHeight

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

    -- Stretch background texture if the frame is taller than the texture's native height
    if theme.resultsBgAtlas and resultsFrame.bgAtlasTex and resultsFrame.bgAtlasTex:IsShown() then
        local frameHeight = resultsFrame:GetHeight()
        local currentTexHeight = resultsFrame.bgAtlasTex:GetHeight()
        if frameHeight > currentTexHeight then
            resultsFrame.bgAtlasTex:SetHeight(frameHeight - 8)
        end
    end

    -- Anchor results above or below based on setting
    resultsFrame:ClearAllPoints()
    if EasyFind.db.uiResultsAbove then
        resultsFrame:SetPoint("BOTTOM", searchFrame, "TOP", 0, -5)
    else
        resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, 5)
    end

    resultsFrame:Show()

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
        self:ShowHierarchicalResults(cachedHierarchical)
    end
end

function UI:HideResults()
    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
    if searchFrame.ClearToolbarFocus then searchFrame.ClearToolbarFocus() end
    resultsFrame:Hide()
    if resultsFrame.pinSeparator then
        resultsFrame.pinSeparator:Hide()
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
    local pins = EasyFind.db.pinnedUIItems
    if not pins or #pins == 0 then
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

function UI:UpdateSelectionHighlight(skipRefocus)
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = resultButtons[i]
        if resultRow.selectionHighlight then
            resultRow.selectionHighlight:SetShown(i == selectedIndex and not toggleFocused)
        end
        -- Tab selection highlight (Retail theme)
        if resultRow.tabSelectionHighlight then
            resultRow.tabSelectionHighlight:SetShown(i == selectedIndex and resultRow.headerTab:IsShown() and not toggleFocused)
        end
        if resultRow.toggleHighlight then
            local showToggle = i == selectedIndex and toggleFocused
            if showToggle then
                resultRow.toggleHighlight:ClearAllPoints()
                if resultRow.isPinHeader and resultRow.pinToggle and resultRow.pinToggle:IsShown() then
                    resultRow.toggleHighlight:SetPoint("CENTER", resultRow.pinToggle, "CENTER", 0, 0)
                else
                    resultRow.toggleHighlight:SetPoint("CENTER", resultRow.toggleIcon, "CENTER", 0, 0)
                end
            end
            resultRow.toggleHighlight:SetShown(showToggle)
        end
    end
    if selectedIndex > 0 then
        if resultButtons[selectedIndex] then
            Utils.ScrollToButton(resultsFrame.scrollFrame, resultButtons[selectedIndex])
        end
        if searchFrame.editBox:HasFocus() then
            searchFrame.editBox:ClearFocus()
        end
        navFrame:EnableKeyboard(true)
    else
        local wasNavigating = navFrame:IsKeyboardEnabled()
        navFrame:EnableKeyboard(false)
        if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
        if wasNavigating and not skipRefocus and not searchFrame.editBox:HasFocus() then
            searchFrame.editBox:SetFocus()
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

            if resultRow.isPathNode then
                -- Toggle collapse for path nodes
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

function UI:SelectResult(data)
    selectingResult = true
    searchFrame.editBox:SetText("")
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:Show()
    selectingResult = false
    self:HideResults()

    if not data then return end
    
    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end
    
    if EasyFind.db.directOpen and data.steps then
        -- Portrait menu entries can't be automated (secure frame restriction) - always use guide mode
        local hasPortraitMenu = false
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                hasPortraitMenu = true
                break
            end
        end
        
        if hasPortraitMenu then
            EasyFind:StartGuide(data)
        else
            -- Direct open mode - execute the navigation directly
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
        -- regionFrames alone (no searchButtonText) = highlight-only (e.g. PvP Talents)
        -- waitForFrame alone = just waiting for a frame to appear, not navigable
        -- text alone = instruction text, not navigable
        return false
    end

    local lastStep = steps[totalSteps]
    local finalStepNavigable = isStepNavigable(lastStep)

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

    local function executeStep(stepIndex)
        -- Done executing - either finished completely or hand off to highlight
        if stepIndex > executeCount then
            if not finalStepNavigable then
                -- Final step is highlight-only - show it to the user
                C_Timer.After(0.15, function()
                    if Highlight then
                        Highlight:StartGuideAtStep(data, totalSteps)
                    end
                end)
            end
            -- If final step was navigable, we already executed it - nothing more to do
            return
        end

        local step = steps[stepIndex]
        local nextDelay = 0.1

        -- Click a micro menu button (like LFDMicroButton, CharacterMicroButton, etc.)
        if step.buttonFrame then
            local stepFrame = _G[step.buttonFrame]
            if stepFrame then ClickButton(stepFrame) end
            nextDelay = 0.15
        end

        -- Click a main tab (Dungeons & Raids / Player vs. Player / etc.)
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
                -- Headers were pre-expanded via API. Toggle tabs to force
                -- the ScrollBox to rebuild with the expanded state.
                ClickButton(Highlight:GetTabButton("CharacterFrame", 1))
                C_Timer.After(0.05, function()
                    ClickButton(Highlight:GetTabButton(step.waitForFrame, step.tabIndex))
                end)
                nextDelay = 0.2
            else
                ClickButton(Highlight:GetTabButton(step.waitForFrame, step.tabIndex))
                nextDelay = 0.15
            end
        end

        -- Click a PvE side tab (Dungeon Finder / Raid Finder / Premade Groups)
        if step.sideTabIndex then
            C_Timer.After(0.05, function()
                ClickButton(Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex))
            end)
            nextDelay = 0.2
        end

        -- Click a PvP side tab (Quick Match / Rated / Premade Groups / Training Grounds)
        if step.pvpSideTabIndex then
            C_Timer.After(0.05, function()
                ClickButton(Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex))
            end)
            nextDelay = 0.2
        end

        -- Click a Character Frame sidebar tab
        if step.sidebarButtonFrame or step.sidebarIndex then
            self:ClickCharacterSidebar(step.sidebarIndex)
            nextDelay = 0.15
        end

        -- Click a statistics or achievement category
        local categoryToClick = step.statisticsCategory or step.achievementCategory
        if categoryToClick then
            self:ClickAchievementCategory(categoryToClick)
            nextDelay = 0.3
        end

        -- Currency headers are pre-expanded via API. Skip these steps
        -- (the tab resync below handles syncing TokenFrame's display).
        if step.currencyHeader then
            nextDelay = 0.05
        end

        -- Scroll to a currency
        if step.currencyID then
            Highlight:ScrollToCurrencyRow(step.currencyID)
            -- If this is the last step, highlight it
            if stepIndex == executeCount then
                C_Timer.After(0.05, function()
                    local currencyRow = Highlight:GetCurrencyRowButton(step.currencyID)
                    if currencyRow then
                        Highlight:HighlightFrame(currencyRow, nil)
                        -- Set up hover detection to clear highlight
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
            nextDelay = 0.15
        end

        -- Faction headers are pre-expanded via API (same as currency).
        if step.factionHeader then
            nextDelay = 0.05
        end

        -- Scroll to a faction
        if step.factionID then
            Highlight:ScrollToFactionRow(step.factionID)
            -- If this is the last step, highlight it
            if stepIndex == executeCount then
                C_Timer.After(0.05, function()
                    local factionRow = Highlight:GetFactionRowButton(step.factionID)
                    if factionRow then
                        Highlight:HighlightFrame(factionRow, nil)
                        -- Set up hover detection to clear highlight
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
            nextDelay = 0.15
        end

        -- Click a button found by text search (Premade Groups categories, PvP queue buttons, etc.)
        if step.searchButtonText then
            C_Timer.After(0.05, function()
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    ClickButton(SearchFrameTreeFuzzy(parentFrame, slower(step.searchButtonText)))
                end
            end)
            nextDelay = 0.3
        end

        -- Chain to the next step after a delay
        C_Timer.After(nextDelay, function()
            executeStep(stepIndex + 1)
        end)
    end

    -- Start executing from step 1
    executeStep(1)
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

--- Helper function to expand a faction header by name
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
    
    -- Method 2: Try the OnClick handler directly (simulates right-click)
    local handler = PlayerFrame:GetScript("OnClick")
    if handler then
        handler(PlayerFrame, "RightButton")
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
    if searchFrame:IsShown() and EasyFind.db.visible ~= false then
        self:Hide()
    else
        self:Show(false)
    end
end

function UI:ToggleFocus()
    if not searchFrame then return end
    if inCombat then return end
    if searchFrame:IsShown() and searchFrame.editBox:HasFocus() then
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

function UI:UpdateOpacity()
    if searchFrame and searchFrame.bgTex then
        local alpha = EasyFind.db.searchBarOpacity or DEFAULT_OPACITY
        searchFrame.bgTex:SetColorTexture(0, 0, 0, alpha)
    end
end

function UI:UpdateSearchBarTheme()
    if not searchFrame then return end
    local theme = GetActiveTheme()
    if theme.searchBarRounded then
        searchFrame:SetBackdrop({
            edgeFile = TOOLTIP_BORDER,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)
    else
        searchFrame:SetBackdrop({
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
        searchFrame:SetBackdropBorderColor(1, 1, 1, 1)
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
    f:SetSize(410, 300)
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
        "|cffFFD100\226\128\162|r |cffffffffMap Search Filters|r\n" ..
        "        Filter global & local search by zones, dungeons, raids, and more\n" ..
        "|cffFFD100\226\128\162|r |cffffffffNative Waypoint Tracking|r\n" ..
        "        Pins now place a real game waypoint\n" ..
        "|cffFFD100\226\128\162|r |cffffffffScrollable Results|r\n" ..
        "        Search results are now scrollable (no more hard cutoff)\n" ..
        "|cffFFD100\226\128\162|r |cffffffffMinimap Button|r\n" ..
        "        Optional minimap icon to quickly open or focus the search bar"
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

    f:Show()
end

-- FIRST-TIME SETUP OVERLAY
-- Shown once on fresh install to let the user position & scale the search
-- bar before normal use.  Persisted via EasyFind.db.setupComplete.
function UI:ShowFirstTimeSetup()
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

    -- ── Golden glow overlay ─────────────────────────────────────────────
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

    -- ── Resize handle (bottom-left corner) ──────────────────────────────
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

    -- ── Instruction panel (anchored below the glow) ─────────────────────
    local panel = CreateFrame("Frame", nil, glow, "BackdropTemplate")
    panel:SetSize(340, 260)
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
    smartShowCheckbox.Text:SetText("|cffFFD100Smart Show|r")
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
    smartDesc:SetText(
        "|cff999999If enabled, the bar hides when your mouse|r\n" ..
        "|cff999999moves away and reappears when you hover near|r\n" ..
        "|cff999999it. If kept unchecked, the bar stays visible and can be|r\n" ..
        "|cff999999toggled with the minimap button or|r\n" ..
        "|cffFFD100/ef show|r |cff999999and|r |cffFFD100/ef hide|r|cff999999.|r"
    )

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
    footer:SetText("|cff666666These and more settings can be changed in |cffFFD100/ef o|r|cff666666.|r")

    -- Done button
    local doneBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 12)
    doneBtn:SetText("Done")

    -- ── During setup: allow drag WITHOUT holding Shift ───────────────────
    searchFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    -- ── Done handler: persist, cleanup, restore normal drag ─────────────
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
        local ok, err = pcall(function()
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

    local theme = GetActiveTheme()
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
