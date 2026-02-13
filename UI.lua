local ADDON_NAME, ns = ...

local UI = {}
ns.UI = UI

local Utils = ns.Utils
local GetButtonText    = Utils.GetButtonText
local SearchFrameTree  = Utils.SearchFrameTree
local DebugPrint       = Utils.DebugPrint
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local tinsert, tsort, tconcat = Utils.tinsert, Utils.tsort, Utils.tconcat
local mmin, mmax = Utils.mmin, Utils.mmax

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
local MAX_BUTTON_POOL = 30  -- Maximum buttons we'll ever create (extra for smart cap extension)
local inCombat = false

-- Centralized icon setter — resets texture state before applying to prevent
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

-- Get the current max results setting (user-configurable)
local function GetMaxResults()
    return EasyFind.db.maxResults or 12
end
local selectedIndex = 0   -- 0 = none selected, 1..N = highlighted row
local unearnedTooltip      -- Custom tooltip for unearned currencies

-- =============================================================================
-- THEME DEFINITIONS
-- =============================================================================
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
    pathFont        = "GameFontNormal",
    leafFont        = "GameFontNormal",
    pathColor       = {0.7, 0.7, 0.7},
    leafColor       = {1, 0.82, 0},
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

-- Retail: quest-log style — raised tab headers, golden tree lines, grey border
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
    pathFont        = "Game15Font_Shadow",   -- exact quest log font
    leafFont        = "GameFontHighlight",
    pathColor       = {0.65, 0.60, 0.55, 1.0},   -- muted gray-tan (normal state)
    pathColorHover  = {1.0, 1.0, 1.0, 1.0},      -- white (hover state)
    leafColor       = {0.9, 0.9, 0.9},           -- light grey items
    -- tree lines — warm gold (single colour at every depth)
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
    -- results backdrop — grey tooltip border, quest log background
    resultsBackdrop = {
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
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
    unearnedTooltip:SetFrameLevel(9999)  -- Ensure it's on top
    unearnedTooltip:SetClampedToScreen(true)

    -- Simple black background with border
    unearnedTooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
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
    
    -- Check if already in combat
    inCombat = InCombatLockdown()
    if inCombat then
        searchFrame:Hide()
    end

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
    searchFrame:SetSize(300, 36)
    searchFrame:SetFrameStrata("HIGH")
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetClampedToScreen(true)
    
    -- Apply saved position or default
    if EasyFind.db.uiSearchPosition then
        local pos = EasyFind.db.uiSearchPosition
        searchFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -5)
    end
    
    -- Apply theme-appropriate backdrop
    local theme = GetActiveTheme()
    if theme.searchBarRounded then
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropColor(0.45, 0.45, 0.45, 0.95)
        searchFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    else
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
    end
    
    -- Search icon
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(16, 16)
    searchIcon:SetPoint("LEFT", searchFrame, "LEFT", 12, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    
    -- Editbox
    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetSize(175, 20)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)

    -- Block focus when Shift is held (shift = drag, not type) unless already typing
    editBox:HookScript("OnMouseDown", function(self)
        if IsShiftKeyDown() and not self:HasFocus() then
            C_Timer.After(0, function() self:ClearFocus() end)
        end
        if searchFrame.setupMode then
            C_Timer.After(0, function() self:ClearFocus() end)
        end
    end)
    
    local placeholder = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search your UI here")
    editBox.placeholder = placeholder
    
    editBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
    end)
    
    editBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
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
    
    -- Arrow key / Tab navigation for results dropdown.
    -- IMPORTANT: Always block propagation while the editbox has focus so that
    -- typed letters never trigger the player's game keybinds.
    editBox:SetScript("OnKeyDown", function(self, key)
        if resultsFrame and resultsFrame:IsShown() then
            if key == "DOWN" then
                UI:MoveSelection(1)
            elseif key == "UP" then
                UI:MoveSelection(-1)
            elseif key == "TAB" then
                if IsShiftKeyDown() then
                    UI:MoveSelection(-1)
                else
                    UI:MoveSelection(1)
                end
            end
        end
        -- Never propagate keyboard input to game binds while the search box is focused
        self:SetPropagateKeyboardInput(false)
    end)
    
    searchFrame.editBox = editBox
    
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
        local base = EasyFind.db.searchBarOpacity or 1.0
        if moveFading then return base * MOVE_FADE_FACTOR end
        return base
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
        -- Don't hide during first-time setup (user is positioning the bar)
        if searchFrame.setupMode then return end
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
                self:SetAlpha(EasyFind.db.searchBarOpacity or 1.0)
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

    for i = 1, MAX_BUTTON_POOL do
        local btn = self:CreateResultButton(i)
        resultButtons[i] = btn
    end

    -- Truncation indicator separator line (golden, matching tree lines)
    local truncSeparator = resultsFrame:CreateTexture(nil, "ARTWORK")
    truncSeparator:SetColorTexture(1.0, 0.82, 0.0, 0.6)  -- Golden color matching tree lines
    truncSeparator:SetHeight(1)
    truncSeparator:SetPoint("BOTTOMLEFT", resultsFrame, "BOTTOMLEFT", 10, 30)
    truncSeparator:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -10, 30)
    truncSeparator:Hide()
    resultsFrame.truncSeparator = truncSeparator

    -- Truncation indicator: shown when more results exist than can be displayed
    local truncIndicator = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    truncIndicator:SetPoint("BOTTOM", resultsFrame, "BOTTOM", 0, 12)
    truncIndicator:SetTextColor(0.7, 0.7, 0.7, 1.0)
    truncIndicator:SetText("More results available. Increase limit or hide this message in /ef o")
    truncIndicator:Hide()
    resultsFrame.truncIndicator = truncIndicator
end

-- Vibrant indent line colors for each depth level (used by Classic theme)
local INDENT_COLORS = THEMES["Classic"].indentColors

local INDENT_PX  = 20  -- pixels per depth level (icon 16 + 4 gap)
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
        table.insert(cachedHierarchical, entryIndex + 1, toInsert[i])
    end

    expandedContainers[key] = true
    entry.isContainer = nil  -- no longer needs lazy expansion
end

function UI:CreateResultButton(index)
    local btn = CreateFrame("Button", "EasyFindResultButton"..index, resultsFrame)
    btn:SetSize(360, 22)
    btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, -8 - (index - 1) * 22)
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    -- Persistent selection highlight (for keyboard navigation)
    local selTex = btn:CreateTexture(nil, "BACKGROUND")
    selTex:SetAllPoints()
    selTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    selTex:SetBlendMode("ADD")
    selTex:SetVertexColor(0.3, 0.6, 1.0, 0.4)
    selTex:Hide()
    btn.selectionHighlight = selTex
    
    -- Retail theme: full-width dark gradient behind headers (Event Schedule style)
    local headerGrad = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    headerGrad:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
    headerGrad:SetBlendMode("ADD")
    headerGrad:SetVertexColor(0.35, 0.27, 0.08, 0.6)
    headerGrad:SetAllPoints()
    headerGrad:Hide()
    btn.headerGrad = headerGrad
    
    -- Thin horizontal separator line at the bottom of each row
    local separator = btn:CreateTexture(nil, "ARTWORK", nil, 0)
    separator:SetColorTexture(0.5, 0.45, 0.3, 0.3)
    separator:SetHeight(1)
    separator:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 4, 0)
    separator:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 0)
    separator:Hide()
    btn.separator = separator
    
    -- Retail: raised tab header (quest-log style with atlas textures)
    local headerTab = CreateFrame("Button", nil, btn)
    headerTab:SetAllPoints()
    headerTab:RegisterForClicks("LeftButtonUp")
    headerTab:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        parent:GetScript("OnClick")(parent)
    end)
    headerTab:Hide()
    btn.headerTab = headerTab
    
    -- Background texture using QuestLog-tab atlas
    local tabBg = headerTab:CreateTexture(nil, "BACKGROUND")
    tabBg:SetAllPoints()
    tabBg:SetAtlas("QuestLog-tab")
    btn.tabBg = tabBg
    
    -- Hover overlay: same atlas, additive blend, manually shown/hidden
    local tabHoverOverlay = headerTab:CreateTexture(nil, "ARTWORK", nil, -1)
    tabHoverOverlay:SetAllPoints()
    tabHoverOverlay:SetAtlas("QuestLog-tab")
    tabHoverOverlay:SetBlendMode("ADD")
    tabHoverOverlay:SetAlpha(0.40)
    tabHoverOverlay:Hide()
    btn.tabHoverOverlay = tabHoverOverlay
    
    -- +/- button texture on right side (using atlas)
    local toggleIcon = headerTab:CreateTexture(nil, "ARTWORK")
    toggleIcon:SetSize(18, 17)
    toggleIcon:SetPoint("RIGHT", headerTab, "RIGHT", -8, 0)
    toggleIcon:SetAtlas("QuestLog-icon-expand")
    btn.toggleIcon = toggleIcon
    
    -- Header name text (child of headerTab)
    local tabText = headerTab:CreateFontString(nil, "OVERLAY", "Game15Font_Shadow")
    tabText:SetPoint("LEFT", headerTab, "LEFT", 10, 0)
    tabText:SetPoint("RIGHT", toggleIcon, "LEFT", -4, 0)
    tabText:SetJustifyH("LEFT")
    tabText:SetTextColor(0.60, 0.58, 0.55, 1.0)    -- muted gray (normal state)
    btn.tabText = tabText
    
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
                parent.tabText:SetTextColor(1.0, 0.82, 0.0, 1.0)   -- back to gold
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
    btn.tabSelectionHighlight = tabSelTex
    
    -- Tree connector textures per depth level
    -- Each level gets: a vertical pass-through line AND a horizontal branch line
    btn.treeVert   = {}   -- vertical │ lines (pass-through for ancestors)
    btn.treeBranch = {}   -- horizontal ─ branch connector at this row's own depth
    btn.treeElbow  = {}   -- vertical half-line for └ (last child) vs ├ (mid child)
    
    for d = 1, MAX_DEPTH do
        local c = INDENT_COLORS[d]
        local xCenter = (d - 1) * INDENT_PX + 5  -- center X of this depth's column
        
        -- Full-height vertical pass-through line (for ancestor depths still active)
        local vert = btn:CreateTexture(nil, "BACKGROUND")
        vert:SetColorTexture(c[1], c[2], c[3], c[4])
        vert:SetWidth(LINE_W)
        vert:SetPoint("TOP",    btn, "TOPLEFT",    xCenter, 2)
        vert:SetPoint("BOTTOM", btn, "BOTTOMLEFT", xCenter, -2)
        vert:Hide()
        btn.treeVert[d] = vert
        
        -- Half-height vertical elbow (top half only — for ├ and └ at this row's depth)
        local elbow = btn:CreateTexture(nil, "BACKGROUND")
        elbow:SetColorTexture(c[1], c[2], c[3], c[4])
        elbow:SetWidth(LINE_W)
        elbow:SetPoint("TOP", btn, "TOPLEFT", xCenter, 2)
        elbow:SetHeight(13)  -- half the row height + a bit
        elbow:Hide()
        btn.treeElbow[d] = elbow
        
        -- Horizontal branch line (goes from the vertical line rightward to the icon)
        local branch = btn:CreateTexture(nil, "BACKGROUND")
        branch:SetColorTexture(c[1], c[2], c[3], c[4])
        branch:SetHeight(LINE_W)
        branch:SetPoint("LEFT",  btn, "TOPLEFT", xCenter, -11)
        branch:SetPoint("RIGHT", btn, "TOPLEFT", xCenter + INDENT_PX - 2, -11)
        branch:Hide()
        btn.treeBranch[d] = branch
    end
    
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 0, 0)
    btn.icon = icon
    
    -- Right-aligned currency amount label
    local amountText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amountText:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    amountText:SetJustifyH("RIGHT")
    amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
    amountText:Hide()
    btn.amountText = amountText

    -- Right-aligned reputation standing bar
    -- Structure: repBar (dark bg + border) → repClip (clips fill) → repFillFrame (colored, same shape)
    --            repBar → repTextOverlay (text on top of everything)
    local REP_BAR_WIDTH = 100
    local repBarBackdrop = {
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }

    local repBar = CreateFrame("Frame", nil, btn, BackdropTemplateMixin and "BackdropTemplate")
    repBar:SetSize(REP_BAR_WIDTH, 19)
    repBar:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
    if repBar.SetBackdrop then
        repBar:SetBackdrop(repBarBackdrop)
        repBar:SetBackdropColor(0.06, 0.06, 0.06, 1.0)
        repBar:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    repBar:Hide()
    btn.repBar = repBar

    -- Clip frame controls how much of the fill is visible (left→right)
    local repClip = CreateFrame("Frame", nil, repBar)
    repClip:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repClip:SetPoint("BOTTOMLEFT", repBar, "BOTTOMLEFT", 0, 0)
    repClip:SetWidth(REP_BAR_WIDTH)
    repClip:SetClipsChildren(true)
    btn.repClip = repClip

    -- Fill frame: same rounded shape as repBar, but colored; clipped by repClip
    local repFill = CreateFrame("Frame", nil, repClip, BackdropTemplateMixin and "BackdropTemplate")
    repFill:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repFill:SetPoint("BOTTOMRIGHT", repBar, "BOTTOMRIGHT", 0, 0)
    if repFill.SetBackdrop then
        repFill:SetBackdrop(repBarBackdrop)
        repFill:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    btn.repFill = repFill

    -- Glossy bar texture (same as WoW default bars); backdrop bgColor matches fill
    -- color so the flat corners blend seamlessly with the glossy center
    local repBarTex = repFill:CreateTexture(nil, "ARTWORK")
    repBarTex:SetPoint("TOPLEFT", repFill, "TOPLEFT", 3, -3)
    repBarTex:SetPoint("BOTTOMRIGHT", repFill, "BOTTOMRIGHT", -3, 3)
    repBarTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    btn.repBarTex = repBarTex

    -- Text overlay above everything (not clipped)
    local repTextOverlay = CreateFrame("Frame", nil, repBar)
    repTextOverlay:SetAllPoints()
    repTextOverlay:SetFrameLevel(repFill:GetFrameLevel() + 3)
    local repBarText = repTextOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repBarText:SetPoint("CENTER", repBar, "CENTER", 0, 0)
    repBarText:SetTextColor(1.0, 1.0, 1.0, 1.0)
    repBarText:SetShadowOffset(1, -1)
    btn.repBarText = repBarText

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", amountText, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    btn.text = text
    
    btn:SetScript("OnClick", function(self, mouseButton, down)
        -- Don't allow clicking unearned currencies
        if self.isUnearnedCurrency then
            return
        end

        if self.isPathNode then
            -- Check if click was near the +/- toggle icon
            local cursorX = GetCursorPosition()
            local scale = self:GetEffectiveScale()
            local isRetailHeader = self.headerTab and self.headerTab:IsShown()
            local isToggleClick = false

            if isRetailHeader then
                -- Retail: toggle icon on right side — generous 55px zone
                local btnRight = self:GetRight() * scale
                isToggleClick = cursorX >= (btnRight - 55 * scale)
            else
                -- Classic: +/- icon on left side — 35px zone from icon start
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
                    UI:ShowHierarchicalResults(cachedHierarchical)
                end
            elseif self.data then
                UI:SelectResult(self.data)
            end
        elseif self.data then
            UI:SelectResult(self.data)
        end
    end)

    -- Tooltip for unearned currencies
    btn:SetScript("OnEnter", function(self)
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

    btn:SetScript("OnLeave", function(self)
        -- Only hide our custom tooltip - let WoW manage GameTooltip naturally
        if unearnedTooltip then
            unearnedTooltip:Hide()
        end
    end)

    btn:Hide()
    return btn
end

function UI:OnSearchTextChanged(text)
    -- Clear collapse state so every new search starts fully expanded
    collapsedNodes = {}
    expandedContainers = {}
    local results = ns.Database:SearchUI(text)
    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    -- Container nodes (search results that have database children which didn't
    -- match the query) start collapsed — user can expand to browse children.
    for _, entry in ipairs(hierarchical) do
        if entry.isContainer then
            local key = entry.name .. "_" .. (entry.depth or 0)
            collapsedNodes[key] = true
        end
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

function UI:ShowHierarchicalResults(hierarchical)
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
    resultsFrame:SetWidth(theme.resultsWidth)
    
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
    
    for _, entry in ipairs(hierarchical) do
        local d = entry.depth or 0
        
        -- If we're skipping children of a collapsed node, check depth
        if skipBelowDepth then
            if d > skipBelowDepth then
                -- Still inside collapsed subtree — skip
            else
                -- Back to same or higher depth — stop skipping
                skipBelowDepth = nil
            end
        end
        
        if not skipBelowDepth then
            tinsert(visible, entry)
            
            -- If this is a collapsed path node, start skipping its children
            if entry.isPathNode then
                local key = entry.name .. "_" .. d
                if collapsedNodes[key] then
                    skipBelowDepth = d
                end
            end
        end
    end
    
    local maxResults = GetMaxResults()
    local count = mmin(#visible, maxResults)

    -- Smart cap: if the last visible row is a group header with items beyond
    -- the cap, extend to include its contents so the user never sees a
    -- dangling header with nothing beneath it.  Applies to both gray
    -- ancestors and gold match nodes that the user expanded.
    if not EasyFind.db.hardResultsCap and count < #visible then
        while count < #visible do
            local last = visible[count]
            -- Stop if the last row is a leaf — the result is complete
            if not last.isPathNode then break end
            -- Last row is a group header — extend to show its contents
            local headerDepth = last.depth or 0
            local extended = false
            for j = count + 1, #visible do
                local entry = visible[j]
                local d = entry.depth or 0
                if d <= headerDepth then break end -- left the group
                count = j
                extended = true
            end
            if not extended then break end
        end
    end

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
    -- Render visible rows
    -- ----------------------------------------------------------------
    for i = 1, MAX_BUTTON_POOL do
        local btn = resultButtons[i]
        if i <= count then
            local entry = visible[i]
            local data = entry.data
            local depth = entry.depth or 0
            
            -- Reposition for theme row height
            local padL = theme.resultsPadLeft or 10
            btn:SetSize(theme.btnWidth, rowH)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", padL, -padT - (i - 1) * rowH)
            
            -- Selection highlight color
            btn.selectionHighlight:SetVertexColor(unpack(theme.selectionColor))
            
            btn.data = data
            btn.isPathNode = entry.isPathNode
            btn.pathNodeName = entry.isPathNode and entry.name or nil
            btn.pathNodeDepth = entry.isPathNode and depth or nil
            btn._containerEntry = entry.isContainer and entry or nil
            
            -- ---- Tree connector drawing ----
            for d = 1, MAX_DEPTH do
                btn.treeVert[d]:Hide()
                btn.treeElbow[d]:Hide()
                btn.treeBranch[d]:Hide()
            end
            
            if theme.showTreeLines and depth > 0 then
                local halfRow = rowH * 0.5
                local tc = theme.indentColors[depth] or theme.indentColors[1] or INDENT_COLORS[depth]
                local xCenter = (depth - 1) * INDENT_PX + 5
                
                -- Recolor + reposition branch/elbow for active theme's row height
                btn.treeBranch[depth]:SetColorTexture(tc[1], tc[2], tc[3], tc[4])
                btn.treeBranch[depth]:ClearAllPoints()
                btn.treeBranch[depth]:SetPoint("LEFT",  btn, "TOPLEFT", xCenter, -halfRow)
                btn.treeBranch[depth]:SetPoint("RIGHT", btn, "TOPLEFT", xCenter + INDENT_PX - 2, -halfRow)
                btn.treeBranch[depth]:Show()
                
                btn.treeElbow[depth]:SetColorTexture(tc[1], tc[2], tc[3], tc[4])
                btn.treeElbow[depth]:ClearAllPoints()
                btn.treeElbow[depth]:SetPoint("TOP", btn, "TOPLEFT", xCenter, 2)
                btn.treeElbow[depth]:SetHeight(halfRow + 2)
                btn.treeElbow[depth]:Show()
                
                if not isLastChild[i] then
                    btn.treeVert[depth]:SetColorTexture(tc[1], tc[2], tc[3], tc[4])
                    btn.treeVert[depth]:Show()
                end
                
                for d = 1, depth - 1 do
                    local stillActive = false
                    for j = i + 1, count do
                        local dj = visible[j].depth or 0
                        if dj < d then break end
                        if dj == d then stillActive = true; break end
                    end
                    if stillActive then
                        local ac = theme.indentColors[d] or theme.indentColors[1] or INDENT_COLORS[d]
                        btn.treeVert[d]:SetColorTexture(ac[1], ac[2], ac[3], ac[4])
                        btn.treeVert[d]:Show()
                    end
                end
            end
            
            -- ---- Header styling ----
            btn._isMatch = entry.isMatch and entry.isPathNode
            if theme.showHeaderTab and entry.isPathNode then
                -- Quest-log raised tab header
                local tabInset = depth * indPx
                btn.headerTab:ClearAllPoints()
                btn.headerTab:SetPoint("TOPLEFT", btn, "TOPLEFT", tabInset, 0)
                btn.headerTab:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
                btn.headerTab:Show()
                -- Set +/- atlas and header name on the tab
                local key = entry.name .. "_" .. depth
                local isCollapsed = collapsedNodes[key]
                local expandAtlas = theme.expandAtlas or "QuestLog-icon-expand"
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                local toggleAtlas = isCollapsed and expandAtlas or collapseAtlas
                btn.toggleIcon:SetAtlas(toggleAtlas)
                btn.tabText:SetText(entry.name)
                -- Matched path nodes get gold text; non-matches stay muted gray
                if btn._isMatch then
                    btn.tabText:SetTextColor(1.0, 0.82, 0.0, 1.0)   -- gold
                else
                    btn.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0) -- muted gray
                end
                -- Normal icon/text hidden — SetRowIcon("hidden") handles icon below
                btn.text:SetText("")
                btn.headerGrad:Hide()
            else
                btn.headerTab:Hide()
                -- Gradient header (Classic fallback)
                local showGrad = theme.showHeaderBar and entry.isPathNode
                if showGrad then
                    btn.headerGrad:SetAllPoints()
                    local gradAlpha = mmax(0.25, 0.6 - depth * 0.1)
                    btn.headerGrad:SetVertexColor(0.35, 0.27, 0.08, gradAlpha)
                end
                btn.headerGrad:SetShown(showGrad)
            end
            
            -- Separator line between rows
            if theme.showSeparators then
                local sc = theme.separatorColor
                btn.separator:SetColorTexture(sc[1], sc[2], sc[3], sc[4])
            end
            btn.separator:SetShown(theme.showSeparators)

            -- Check if this is a currency that hasn't been discovered yet
            -- (not just quantity == 0, but truly never earned/discovered)
            -- This check must run for ALL currency nodes regardless of theme
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
            btn.isUnearnedCurrency = isUnearnedCurrency
            btn.isPathNode = entry.isPathNode  -- Store for tooltip text

            -- ---- Position icon & text (non-tab rows) ----
            if not (theme.showHeaderTab and entry.isPathNode) then
                local indentPixels = depth * indPx
                btn.icon:ClearAllPoints()
                btn.icon:SetPoint("LEFT", btn, "LEFT", indentPixels, 0)

                btn.text:ClearAllPoints()
                btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
                btn.text:SetPoint("RIGHT", btn.amountText, "LEFT", -4, 0)
                btn.text:SetText(entry.name)

                -- Style: path nodes vs leaf results, themed
                if entry.isPathNode then
                    btn.text:SetFontObject(theme.pathFont)
                    if entry.isMatch then
                        btn.text:SetTextColor(1.0, 0.82, 0.0, 1.0) -- gold for matches
                    else
                        btn.text:SetTextColor(unpack(theme.pathColor))
                    end
                elseif isUnearnedCurrency then
                    -- Gray out unearned currencies
                    btn.text:SetFontObject(theme.leafFont)
                    btn.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                elseif entry.isMatch then
                    btn.text:SetFontObject(theme.leafFont)
                    btn.text:SetTextColor(1.0, 0.82, 0.0, 1.0) -- gold for matches
                else
                    btn.text:SetFontObject(theme.leafFont)
                    btn.text:SetTextColor(unpack(theme.leafColor))
                end
            end
            
            -- ---- Set icon ----
            local iconSet = false
            local isCurrencyItem = data and data.category == "Currency"
            local isCurrencyLeaf = isCurrencyItem and not entry.isPathNode
            local isReputationLeaf = data and data.category == "Reputation" and not entry.isPathNode

            if theme.showHeaderTab and entry.isPathNode then
                SetRowIcon(btn, "hidden", nil, theme.iconSize)
                iconSet = true

            elseif entry.isPathNode then
                local key = entry.name .. "_" .. depth
                local iconPath = collapsedNodes[key] and theme.expandIcon or theme.collapseIcon
                SetRowIcon(btn, "path", iconPath, theme.pathIconSize)
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
                    btn.amountText:SetText(tostring(quantity))
                    if isUnearnedCurrency then
                        btn.amountText:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        btn.amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
                    end
                    btn.amountText:Show()
                else
                    btn.amountText:Hide()
                end

                -- Move icon to right side (right of amount text)
                if iconFileID then
                    btn.icon:SetTexture(nil)
                    btn.icon:SetTexCoord(0, 1, 0, 1)
                    btn.icon:SetTexture(iconFileID)
                    btn.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                    btn.icon:ClearAllPoints()
                    btn.icon:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
                    btn.icon:Show()
                    -- Anchor amount text to left of icon
                    btn.amountText:ClearAllPoints()
                    btn.amountText:SetPoint("RIGHT", btn.icon, "LEFT", -3, 0)
                else
                    SetRowIcon(btn, "hidden", nil, theme.iconSize)
                    btn.amountText:ClearAllPoints()
                    btn.amountText:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
                end

                -- Anchor name text from indent to amount (no left icon, tiny buffer)
                local indentPixels = depth * indPx + 4
                btn.text:ClearAllPoints()
                btn.text:SetPoint("LEFT", btn, "LEFT", indentPixels, 0)
                btn.text:SetPoint("RIGHT", btn.amountText, "LEFT", -4, 0)
                iconSet = true

            else
                btn.amountText:Hide()
                -- Reset amount text anchor for non-currency rows
                btn.amountText:ClearAllPoints()
                btn.amountText:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
            end

            -- Reputation leaves: show standing bar on the right instead of icon
            if isReputationLeaf and data and data.factionID then
                local fill, standingText, barR, barG, barB
                local fid = data.factionID

                -- Priority 1: Renown factions (TWW, Dragonflight, Shadowlands)
                if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                    local ok, md = pcall(C_MajorFactions.GetMajorFactionData, fid)
                    if ok and md and md.renownLevel then
                        local level = md.renownLevel or 0
                        standingText = "Renown " .. level
                        -- Check if at max renown (bar should be full)
                        local atMax = C_MajorFactions.HasMaximumRenown
                            and C_MajorFactions.HasMaximumRenown(fid)
                        if atMax then
                            fill = 1.0
                        else
                            local earned = md.renownReputationEarned or 0
                            local threshold = md.renownLevelThreshold or 1
                            fill = (threshold > 0) and (earned / threshold) or 1.0
                        end
                        barR, barG, barB = 0.0, 0.55, 0.78  -- teal/cyan like WoW renown bars
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
                        barR, barG, barB = 0.0, 0.60, 0.0  -- green for friendship
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
                            fill = 1.0  -- Exalted or capped
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
                    btn.repBarTex:SetVertexColor(barR, barG, barB, 1.0)
                    if btn.repFill.SetBackdropColor then
                        btn.repFill:SetBackdropColor(barR, barG, barB, 1.0)
                    end
                    btn.repClip:SetWidth(math.max(fill * 100, 0.1))
                    btn.repBarText:SetText(standingText)
                    btn.repBar:Show()
                else
                    btn.repBar:Hide()
                end

                -- Hide left icon, anchor text to left of bar
                SetRowIcon(btn, "hidden", nil, theme.iconSize)
                local indentPixels = depth * indPx + 4
                btn.text:ClearAllPoints()
                btn.text:SetPoint("LEFT", btn, "LEFT", indentPixels, 0)
                btn.text:SetPoint("RIGHT", btn.repBar, "LEFT", -4, 0)
                iconSet = true
            else
                btn.repBar:Hide()
            end

            if not iconSet and data and data.icon then
                SetRowIcon(btn, "file", data.icon, theme.iconSize)
                iconSet = true
            end

            -- Resolve sidebar tab icons at runtime (e.g. Equipment Manager, Titles)
            -- The tab textures are sprite sheets — copy the ARTWORK-layer texture
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
                                    if tex then
                                        local ulX, ulY, llX, llY, urX, urY, lrX, lrY = region:GetTexCoord()
                                        btn.icon:SetTexture(tex)
                                        btn.icon:SetTexCoord(ulX, ulY, llX, llY, urX, urY, lrX, lrY)
                                        btn.icon:SetSize(theme.iconSize or 16, theme.iconSize or 16)
                                        btn.icon:Show()
                                        iconSet = true
                                    end
                                    break
                                end
                            end
                        end
                        break
                    end
                end
            end

            -- Skip buttonFrame fallback for currency items — their inherited
            -- "CharacterMicroButton" produces a wrong MicroMenu atlas icon.
            if not iconSet and not isCurrencyItem and data and data.buttonFrame then
                local texture, isAtlas = GetButtonIcon(data.buttonFrame)
                if texture then
                    local kind = isAtlas and "atlas" or "file"
                    SetRowIcon(btn, kind, texture, theme.iconSize)
                    iconSet = true
                end
            end

            if not iconSet then
                SetRowIcon(btn, "file", 134400, theme.iconSize)
            end

            btn:Show()
        else
            btn:Hide()
            btn.headerGrad:Hide()
            btn.headerTab:Hide()
            btn.separator:Hide()
            btn.repBar:Hide()
            for d = 1, MAX_DEPTH do
                btn.treeVert[d]:Hide()
                btn.treeElbow[d]:Hide()
                btn.treeBranch[d]:Hide()
            end
        end
    end
    
    -- Show/hide truncation indicator and separator
    local showTruncation = #visible > count and (EasyFind.db.showTruncationMessage ~= false)

    -- Add extra padding for truncation message if it will be shown
    local truncPadding = showTruncation and 25 or 0
    resultsFrame:SetHeight(padT + theme.resultsPadBot + count * rowH + truncPadding)
    if resultsFrame.truncIndicator then
        if showTruncation then
            resultsFrame.truncIndicator:Show()
        else
            resultsFrame.truncIndicator:Hide()
        end
    end
    if resultsFrame.truncSeparator then
        if showTruncation then
            resultsFrame.truncSeparator:Show()
        else
            resultsFrame.truncSeparator:Hide()
        end
    end

    -- Stretch background texture if the frame is taller than the texture's native height
    if theme.resultsBgAtlas and resultsFrame.bgAtlasTex:IsShown() then
        local frameHeight = resultsFrame:GetHeight()
        local currentTexHeight = resultsFrame.bgAtlasTex:GetHeight()
        -- Only stretch if frame is taller; never shrink below native height
        if frameHeight > currentTexHeight then
            resultsFrame.bgAtlasTex:SetHeight(frameHeight - 8)  -- Account for insets
        end
    end

    resultsFrame:Show()

    -- Reset keyboard selection whenever results change
    selectedIndex = 0
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
    resultsFrame:Hide()
    if resultsFrame.truncIndicator then
        resultsFrame.truncIndicator:Hide()
    end
    if resultsFrame.truncSeparator then
        resultsFrame.truncSeparator:Hide()
    end
    selectedIndex = 0
    self:UpdateSelectionHighlight()
end

function UI:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    if resultsFrame:IsShown() and resultButtons[1]:IsShown() and resultButtons[1].data then
        self:SelectResult(resultButtons[1].data)
    end
end

function UI:MoveSelection(delta)
    -- Count visible buttons
    local visibleCount = 0
    for i = 1, MAX_BUTTON_POOL do
        if resultButtons[i]:IsShown() then
            visibleCount = i
        else
            break
        end
    end
    if visibleCount == 0 then return end
    
    local newIndex = selectedIndex + delta
    -- Wrap around
    if newIndex < 1 then
        newIndex = visibleCount
    elseif newIndex > visibleCount then
        newIndex = 1
    end
    
    selectedIndex = newIndex
    self:UpdateSelectionHighlight()
end

function UI:UpdateSelectionHighlight()
    for i = 1, MAX_BUTTON_POOL do
        local btn = resultButtons[i]
        if btn.selectionHighlight then
            btn.selectionHighlight:SetShown(i == selectedIndex)
        end
        -- Tab selection highlight (Retail theme)
        if btn.tabSelectionHighlight then
            btn.tabSelectionHighlight:SetShown(i == selectedIndex and btn.headerTab:IsShown())
        end
    end
end

function UI:ActivateSelected()
    if selectedIndex > 0 and selectedIndex <= MAX_BUTTON_POOL then
        local btn = resultButtons[selectedIndex]
        if btn:IsShown() then
            -- Don't allow activating unearned currencies
            if btn.isUnearnedCurrency then
                return
            end

            if btn.isPathNode then
                -- Toggle collapse for path nodes
                local key = (btn.pathNodeName or "") .. "_" .. (btn.pathNodeDepth or 0)
                local wasCollapsed = collapsedNodes[key]
                collapsedNodes[key] = not collapsedNodes[key]
                if wasCollapsed and btn._containerEntry and cachedHierarchical then
                    for idx, entry in ipairs(cachedHierarchical) do
                        if entry == btn._containerEntry then
                            ExpandContainer(entry, idx)
                            break
                        end
                    end
                end
                if cachedHierarchical then
                    self:ShowHierarchicalResults(cachedHierarchical)
                end
            elseif btn.data then
                self:SelectResult(btn.data)
            end
            return
        end
    end
    -- Fallback: select first result if nothing is highlighted
    self:SelectFirstResult()
end

function UI:SelectResult(data)
    searchFrame.editBox:SetText("")
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:Show()
    self:HideResults()
    
    if not data then return end
    
    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end
    
    -- Check if direct open is enabled
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

    -- Check if this is a reputation navigation - if so, collapse all headers first for clean state
    local hasReputationSteps = false
    for _, step in ipairs(steps) do
        if step.factionHeader or step.factionID then
            hasReputationSteps = true
            break
        end
    end
    if hasReputationSteps then
        self:CollapseAllReputationHeaders()
    end

    -- Check if this is a currency navigation - if so, collapse all headers first for clean state
    local hasCurrencySteps = false
    for _, step in ipairs(steps) do
        if step.currencyHeader or step.currencyID then
            hasCurrencySteps = true
            break
        end
    end
    if hasCurrencySteps then
        self:CollapseAllCurrencyHeaders()
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
        -- Done executing — either finished completely or hand off to highlight
        if stepIndex > executeCount then
            if not finalStepNavigable then
                -- Final step is highlight-only — show it to the user
                C_Timer.After(0.15, function()
                    if Highlight then
                        Highlight:StartGuideAtStep(data, totalSteps)
                    end
                end)
            end
            -- If final step was navigable, we already executed it — nothing more to do
            return
        end

        local step = steps[stepIndex]
        local nextDelay = 0.1

        -- Click a micro menu button (like LFDMicroButton, CharacterMicroButton, etc.)
        if step.buttonFrame then
            local btn = _G[step.buttonFrame]
            if btn then
                if btn.Click then
                    btn:Click()
                elseif btn:GetScript("OnClick") then
                    btn:GetScript("OnClick")(btn)
                end
            end
            nextDelay = 0.15
        end

        -- Click a main tab (Dungeons & Raids / Player vs. Player / etc.)
        if step.waitForFrame and step.tabIndex then
            local tabBtn = Highlight:GetTabButton(step.waitForFrame, step.tabIndex)
            if tabBtn and tabBtn.Click then
                tabBtn:Click()
            elseif tabBtn and tabBtn:GetScript("OnClick") then
                tabBtn:GetScript("OnClick")(tabBtn, "LeftButton")
            end
            nextDelay = 0.15
        end

        -- Click a PvE side tab (Dungeon Finder / Raid Finder / Premade Groups)
        if step.sideTabIndex then
            C_Timer.After(0.05, function()
                local sideBtn = Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex)
                if sideBtn then
                    if sideBtn.Click then
                        sideBtn:Click()
                    elseif sideBtn:GetScript("OnClick") then
                        sideBtn:GetScript("OnClick")(sideBtn, "LeftButton")
                    end
                end
            end)
            nextDelay = 0.2
        end

        -- Click a PvP side tab (Quick Match / Rated / Premade Groups / Training Grounds)
        if step.pvpSideTabIndex then
            C_Timer.After(0.05, function()
                local pvpBtn = Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex)
                if pvpBtn then
                    if pvpBtn.Click then
                        pvpBtn:Click()
                    elseif pvpBtn:GetScript("OnClick") then
                        pvpBtn:GetScript("OnClick")(pvpBtn, "LeftButton")
                    end
                end
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

        -- Expand a currency header
        if step.currencyHeader then
            -- Check if already expanded first
            local isExpanded = Highlight:IsCurrencyHeaderExpanded(step.currencyHeader)
            if isExpanded == false then
                -- Need to expand it
                self:ExpandCurrencyHeader(step.currencyHeader)
                nextDelay = 0.15  -- Wait for UI to update
            else
                -- Already expanded, no need to wait
                nextDelay = 0.05
            end
        end

        -- Scroll to a currency
        if step.currencyID then
            Highlight:ScrollToCurrencyRow(step.currencyID)
            -- If this is the last step, highlight it
            if stepIndex == executeCount then
                C_Timer.After(0.05, function()
                    local btn = Highlight:GetCurrencyRowButton(step.currencyID)
                    if btn then
                        Highlight:HighlightFrame(btn, nil)
                        -- Set up hover detection to clear highlight
                        local checkHover
                        checkHover = function()
                            if btn:IsMouseOver() then
                                Highlight:HideHighlight()
                            else
                                C_Timer.After(0.1, checkHover)
                            end
                        end
                        C_Timer.After(0.1, checkHover)
                    end
                end)
            end
            nextDelay = 0.15
        end

        -- Expand a faction header
        if step.factionHeader then
            -- Check if already expanded first
            local isExpanded = Highlight:IsFactionHeaderExpanded(step.factionHeader)
            if isExpanded == false then
                -- Need to expand it
                self:ExpandFactionHeader(step.factionHeader)
                nextDelay = 0.15  -- Wait for UI to update
            else
                -- Already expanded, no need to wait
                nextDelay = 0.05
            end
        end

        -- Scroll to a faction
        if step.factionID then
            Highlight:ScrollToFactionRow(step.factionID)
            -- If this is the last step, highlight it
            if stepIndex == executeCount then
                C_Timer.After(0.05, function()
                    local btn = Highlight:GetFactionRowButton(step.factionID)
                    if btn then
                        Highlight:HighlightFrame(btn, nil)
                        -- Set up hover detection to clear highlight
                        local checkHover
                        checkHover = function()
                            if btn:IsMouseOver() then
                                Highlight:HideHighlight()
                            else
                                C_Timer.After(0.1, checkHover)
                            end
                        end
                        C_Timer.After(0.1, checkHover)
                    end
                end)
            end
            nextDelay = 0.15
        end

        -- Click a button found by text search (Premade Groups categories, PvP queue buttons, etc.)
        if step.searchButtonText then
            C_Timer.After(0.05, function()
                local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
                local searchText = slower(step.searchButtonText)
                -- Search within the relevant parent frame
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    local btn = SearchFrameTreeFuzzy(parentFrame, searchText)
                    if btn then
                        if btn.Click then
                            btn:Click()
                        elseif btn.GetScript and btn:GetScript("OnClick") then
                            btn:GetScript("OnClick")(btn, "LeftButton")
                        end
                    end
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
    
    -- Ensure we're on the Character tab (tab 1) first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(CharacterFrame) ~= 1 then
        local tabBtn = _G["CharacterFrameTab1"]
        if tabBtn and tabBtn.Click then
            tabBtn:Click()
        end
    end
    
    -- Method 1: Try PaperDollSidebarTab buttons directly (Frame Inspector confirmed names)
    local sidebarTabName = "PaperDollSidebarTab" .. sidebarIndex
    local sidebarTab = _G[sidebarTabName]
    if sidebarTab then
        if sidebarTab:IsShown() then
            if sidebarTab.Click then
                sidebarTab:Click()
                return true
            elseif sidebarTab:GetScript("OnClick") then
                sidebarTab:GetScript("OnClick")(sidebarTab, "LeftButton")
                return true
            end
        else
            -- Tab exists but isn't shown yet - try after a brief delay
            C_Timer.After(0.2, function()
                if sidebarTab:IsShown() then
                    if sidebarTab.Click then
                        sidebarTab:Click()
                    elseif sidebarTab:GetScript("OnClick") then
                        sidebarTab:GetScript("OnClick")(sidebarTab, "LeftButton")
                    end
                end
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
            local tab = select(sidebarIndex, sidebarTabs:GetChildren())
            if tab then
                if tab.Click then
                    tab:Click()
                    return true
                elseif tab:GetScript("OnClick") then
                    tab:GetScript("OnClick")(tab, "LeftButton")
                    return true
                end
            end
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
    
    -- Helper to click a button
    local function tryClick(btn)
        if btn.Click then
            btn:Click()
            return true
        elseif btn.GetScript and btn:GetScript("OnClick") then
            btn:GetScript("OnClick")(btn, "LeftButton")
            return true
        end
        return false
    end
    
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
                    if frame and tryClick(frame) then return true end
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

-- Helper function to scroll to a specific currency by ID
function UI:ScrollToCurrency(currencyID)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end
    
    -- The currency list is a flat list; find the index of our target
    local size = C_CurrencyInfo.GetCurrencyListSize()
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            -- Found it - try to scroll the TokenFrame to this index
            if TokenFrame and TokenFrame.ScrollBox then
                -- Modern ScrollBox API
                local dataProvider = TokenFrame.ScrollBox:GetDataProvider()
                if dataProvider then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.currencyIndex == i
                    end)
                    if scrollData then
                        TokenFrame.ScrollBox:ScrollToElementData(scrollData)
                        -- Highlight the row briefly
                        C_Timer.After(0.1, function()
                            if TokenFrame.ScrollBox then
                                for _, frame in TokenFrame.ScrollBox:EnumerateFrames() do
                                    if frame.currencyID == currencyID then
                                        -- Flash the highlight
                                        if frame.Highlight then
                                            frame.Highlight:SetAlpha(0.3)
                                            C_Timer.After(0.5, function()
                                                if frame.Highlight then
                                                    frame.Highlight:SetAlpha(0)
                                                end
                                            end)
                                        end
                                        break
                                    end
                                end
                            end
                        end)
                    end
                end
            end
            return true
        end
    end
    return false
end

--- Helper function to collapse all reputation headers for a clean navigation state
function UI:CollapseAllReputationHeaders()
    if not C_Reputation or not C_Reputation.GetNumFactions then return end

    -- Collapse all headers, iterating from the end to handle nested structures
    for pass = 1, 50 do
        local numFactions = C_Reputation.GetNumFactions()
        local didCollapse = false
        for i = numFactions, 1, -1 do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.isHeader then
                local isExpanded = factionData.isHeaderExpanded or (factionData.isCollapsed ~= nil and not factionData.isCollapsed)
                if isExpanded then
                    C_Reputation.CollapseFactionHeader(i)
                    didCollapse = true
                    break -- indices shift after collapse, restart
                end
            end
        end
        if not didCollapse then break end
    end
end

--- Helper function to collapse all currency headers for a clean navigation state
function UI:CollapseAllCurrencyHeaders()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return end

    -- Collapse all headers, iterating from the end to handle nested structures
    for pass = 1, 50 do
        local size = C_CurrencyInfo.GetCurrencyListSize()
        local didCollapse = false
        for i = size, 1, -1 do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, false)
                didCollapse = true
                break -- indices shift after collapse, restart
            end
        end
        if not didCollapse then break end
    end
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

--- Helper function to scroll to a specific faction by ID
function UI:ScrollToFaction(factionID)
    if not C_Reputation or not C_Reputation.GetNumFactions then return false end

    -- Find the index of the target faction
    local numFactions = C_Reputation.GetNumFactions()
    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and not factionData.isHeader and factionData.factionID == factionID then
            -- Found it - try to scroll the ReputationFrame to this index
            if ReputationFrame and ReputationFrame.ScrollBox then
                -- Modern ScrollBox API
                local dataProvider = ReputationFrame.ScrollBox:GetDataProvider()
                if dataProvider then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.factionID == factionID
                    end)
                    if scrollData then
                        ReputationFrame.ScrollBox:ScrollToElementData(scrollData)
                        -- Highlight the row briefly
                        C_Timer.After(0.1, function()
                            if ReputationFrame.ScrollBox then
                                for _, frame in ReputationFrame.ScrollBox:EnumerateFrames() do
                                    if frame.factionID == factionID then
                                        -- Flash the highlight
                                        if frame.Content and frame.Content.Background then
                                            frame.Content.Background:SetAlpha(0.3)
                                            C_Timer.After(0.5, function()
                                                if frame.Content and frame.Content.Background then
                                                    frame.Content.Background:SetAlpha(0)
                                                end
                                            end)
                                        end
                                        break
                                    end
                                end
                            end
                        end)
                    end
                end
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
                    if child.Click then
                        child:Click()
                        return true
                    elseif child:GetScript("OnClick") then
                        child:GetScript("OnClick")(child, "LeftButton")
                        return true
                    end
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
        self:Show(true)
    end
end

function UI:UpdateScale()
    if searchFrame then
        local scale = EasyFind.db.uiSearchScale or 1.0
        searchFrame:SetScale(scale)
        if resultsFrame then
            resultsFrame:SetScale(scale)
        end
    end
end

function UI:UpdateOpacity()
    if searchFrame then
        local alpha = searchFrame.getEffectiveAlpha and searchFrame.getEffectiveAlpha()
            or (EasyFind.db.searchBarOpacity or 1.0)
        -- Only set alpha if smart show isn't actively hiding
        if not EasyFind.db.smartShow or (searchFrame.smartShowVisible and searchFrame.smartShowVisible()) then
            searchFrame:SetAlpha(alpha)
        end
    end
end

function UI:UpdateSearchBarTheme()
    if not searchFrame then return end
    local theme = GetActiveTheme()
    if theme.searchBarRounded then
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropColor(0.45, 0.45, 0.45, 0.95)
        searchFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    else
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
        searchFrame:SetBackdropColor(1, 1, 1, 1)
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
            -- Start transparent — hover to reveal
            searchFrame:SetAlpha(0)
            searchFrame:Show()
            searchFrame.setSmartShowVisible(false)
        end
    else
        -- Disable smart show: hide hover zone, restore normal opacity
        searchFrame.hoverZone:Hide()
        searchFrame.setSmartShowVisible(true)
        if EasyFind.db.visible ~= false and not inCombat then
            local alpha = searchFrame.getEffectiveAlpha and searchFrame.getEffectiveAlpha()
                or (EasyFind.db.searchBarOpacity or 1.0)
            searchFrame:SetAlpha(alpha)
            searchFrame:Show()
        end
    end
end

function UI:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -5)
        EasyFind.db.uiSearchPosition = nil
    end
end

-- =========================================================================
-- FIRST-TIME SETUP OVERLAY
-- Shown once on fresh install to let the user position & scale the search
-- bar before normal use.  Persisted via EasyFind.db.setupComplete.
-- =========================================================================
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

    glow:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    glow:SetBackdropColor(1, 0.82, 0, 0.20)
    glow:SetBackdropBorderColor(1, 0.78, 0, 1.0)

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
        self:SetBackdropColor(1, 0.82, 0, pulseAlpha)
    end)

    -- "EasyFind" label overlaid on the glow (like edit-mode frame labels)
    local setupLabel = glow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setupLabel:SetPoint("CENTER", glow, "CENTER", 0, 0)
    setupLabel:SetText("EasyFind")
    setupLabel:SetTextColor(1, 0.82, 0, 0.7)

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
            searchFrame:SetScale(newScale)
            if resultsFrame then resultsFrame:SetScale(newScale) end
        end
        self.lastY = cy
    end)

    -- ── Instruction panel (anchored below the glow) ─────────────────────
    local panel = CreateFrame("Frame", nil, glow, "BackdropTemplate")
    panel:SetSize(340, 150)
    panel:SetPoint("TOP", glow, "BOTTOM", 0, -6)
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropColor(0.1, 0.1, 0.1, 0.95)

    -- Top header lines (centered)
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header:SetPoint("TOP", panel, "TOP", 0, -12)
    header:SetWidth(310)
    header:SetJustifyH("CENTER")
    header:SetText(
        "|cffffffffDrag the search bar to position it.|r\n" ..
        "|cffffffffUse the corner handle to resize.|r"
    )

    -- Bullet points (left-aligned, anchored below header)
    local bullets = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bullets:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    bullets:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -8)
    bullets:SetJustifyH("LEFT")
    bullets:SetText(
        "\226\128\162 |cff999999Hold |cffFFD100Shift|r|cff999999 + drag to reposition later.|r\n" ..
        "\226\128\162 |cff999999The bar auto-hides when not in use. To keep it|r\n" ..
        "|cff999999  visible, open |cffFFD100/ef o|r|cff999999 and disable |cffFFD100Smart Show|r|cff999999.|r"
    )

    -- Done button
    local doneBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    doneBtn:SetSize(80, 22)
    doneBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 30)
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

        -- Restore SmartShow if it was enabled
        if EasyFind.db.smartShow then
            UI:UpdateSmartShow()
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
    label:SetTextColor(1, 0.82, 0)  -- Gold color
    
    -- Create flash animation
    local flashCount = 0
    local ticker
    ticker = C_Timer.NewTicker(0.3, function()
        flashCount = flashCount + 1
        if flashCount % 2 == 0 then
            label:SetTextColor(1, 0.82, 0)
        else
            label:SetTextColor(1, 1, 1)
        end
        
        if flashCount >= 6 then
            -- Restore original
            label:SetText(originalText)
            label:SetTextColor(originalR, originalG, originalB)
            ticker:Cancel()
        end
    end)
end
