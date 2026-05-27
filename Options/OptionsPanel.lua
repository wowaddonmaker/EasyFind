local _, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local L       = ns.L
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tostring = Utils.tostring
local tinsert = Utils.tinsert
local IsMouseButtonDown = IsMouseButtonDown
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown

local SMALL_HIGHLIGHT_FONT = _G["GameFontHighlightSmall"] or _G["GameFontNormalSmall"] or _G["GameFontNormal"]

local OPTIONS_PANEL_ALPHA = 0.9
local OPTIONS_FRAME_STRATA = "FULLSCREEN_DIALOG"
local OPTIONS_FRAME_LEVEL = 700

local optionsFrame
local isInitialized = false
local blizzardRegistered = false

local VISIBILITY_AUTO = 0
local VISIBILITY_SMART = 1
local RESULTS_BELOW = 0
local RESULTS_ABOVE = 1

local NIL = {}
local DEFAULT_UI_FILTERS = {
    achievements = true, statistics = false, currencies = true,
    reputations = true, collections = true, gameOptions = true,
    addonOptions = true, mounts = true, toys = true, pets = true,
    outfits = true, heirlooms = true, loot = true, appearanceSets = true,
    bags = true, macros = true, options = true, abilities = true,
    bosses = true, gearSets = true, talents = true, titles = true,
    map = true,
}
local DEFAULT_GLOBAL_SEARCH_FILTERS = { zones = true, dungeons = true, raids = true, delves = true }
local DEFAULT_LOCAL_SEARCH_FILTERS = { instances = true, travel = true, services = true, rares = true }
local DEFAULT_MAP_TAB_FILTERS = {
    zones = true, instances = true, flightpath = false, travel = true,
    services = true, rares = true,
}

local UI_DEFAULTS = {
    smartShow = false,
    autoHide = true,
    lockPosition = false,
    uiResultsAbove = false,
    showResultShortcutHints = true,
    fontSize = 0.9,
    uiSearchScale = 1.0,
    uiSearchWidth = 1.54,
    uiSearchBarHeight = ns.SEARCHBAR_HEIGHT,
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
    uiSearchPosition = NIL,
    uiResultsHeight = 280,
    uiSearchFilters = DEFAULT_UI_FILTERS,
    lootSpecs = NIL,
    lootSearchSlots = true,
    lootSearchStats = true,
    lootUpgradesOnly = false,
    lootDifficulty = "normal",
    mountFilterCollected = true,
    mountFilterNotCollected = false,
    mountFilterUnusable = false,
    mountTypeGround = true,
    mountTypeFlying = true,
    mountTypeAquatic = true,
    mountTypeRideAlong = true,
    mountSourceFilters = {},
    achievementFilterMode = "all",
    hideAchievementHeaders = true,
    hideGuildAchievements = true,
    appearanceSetClass = NIL,
    appearanceSetCollected = true,
    appearanceSetNotCollected = true,
    appearanceSetPvE = true,
    appearanceSetPvP = true,
    uiMapSearchLocal = true,
}

local MAP_DEFAULTS = {
    iconScale = 0.8,
    mapPinHighlight = true,
    blinkingPins = false,
    autoPinClear = true,
    autoTrackPins = true,
    globalSearchFilters = DEFAULT_GLOBAL_SEARCH_FILTERS,
    localSearchFilters = DEFAULT_LOCAL_SEARCH_FILTERS,
    mapTabFilters = DEFAULT_MAP_TAB_FILTERS,
    alwaysShowRares = false,
}

local GENERAL_DEFAULTS = {
    tutorialDone = false,
    resultsTheme = "Modern",
    font = "Default",
    indicatorStyle = "EasyFind Arrow",
    indicatorColor = "Yellow",
    showLoginMessage = false,
    showAliasMessages = true,
    showMinimapButton = true,
    minimapButtonAngle = 200,
    visible = true,
    enableMapSearch = true,
    nativePinScale = 1.5,
    pinnedUIItems = {},
    pinnedUIItemsPerChar = {},
    pinnedMapItems = {},
    optionsPosition = NIL,
}

local UI_POSITION_DEFAULTS = {
    uiSearchPosition = NIL,
    uiSearchScale = 1.0,
    uiSearchWidth = 1.54,
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
}

local CloneTable = ns.Utils.DeepCopy

local function ApplyDefaults(defaults)
    for key, value in pairs(defaults) do
        if value == NIL then
            EasyFind.db[key] = nil
        elseif type(value) == "table" then
            EasyFind.db[key] = CloneTable(value)
        else
            EasyFind.db[key] = value
        end
    end
end

local function LiftPopupAboveOptions(self)
    self:SetFrameStrata("TOOLTIP")
    self:SetFrameLevel(1000)
end

local function ResetOptionsPosition()
    EasyFind.db.optionsPosition = nil
    if optionsFrame then
        optionsFrame:ClearAllPoints()
        optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function RunSoon(fn)
    Utils.SafeAfter(0, fn)
end

local function ClearMapRuntime()
    if not ns.MapSearch then return end
    pcall(ns.MapSearch.ClearAll, ns.MapSearch)
    pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch)
    ns.MapSearch.pendingWaypoint = nil
end

local function RefreshUIRuntime(resetPosition)
    if ns.Highlight and ns.Highlight.ClearAll then pcall(ns.Highlight.ClearAll, ns.Highlight) end
    if not (_G["EasyFindSearchFrame"] and ns.Search) then return end
    if resetPosition and ns.Search.ResetPosition then ns.Search:ResetPosition() end
    if ns.Search.UpdateScale then ns.Search:UpdateScale() end
    if ns.Search.UpdateWidth then ns.Search:UpdateWidth() end
    if ns.Search.UpdateOpacity then ns.Search:UpdateOpacity() end
    if ns.Search.UpdateSearchBarHeight then ns.Search:UpdateSearchBarHeight() end
    if ns.Search.UpdateSmartShow then ns.Search:UpdateSmartShow() end
    if ns.Search.UpdateFontSize then ns.Search:UpdateFontSize() end
    if ns.Search.RefreshResults then ns.Search:RefreshResults() end
end

local function RefreshMapRuntime()
    ClearMapRuntime()
    if ns.MapSearch then
        if ns.MapSearch.UpdateIconScales then ns.MapSearch:UpdateIconScales() end
        if ns.MapSearch.RefreshIndicators then ns.MapSearch:RefreshIndicators() end
    end
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then uiInd:SetScale(EasyFind.db.iconScale or 0.8) end
end

local function GetVisibilityModeValue()
    return EasyFind and EasyFind.db
        and EasyFind.db.smartShow
        and EasyFind.db.autoHide == false
        and VISIBILITY_SMART
        or VISIBILITY_AUTO
end

local function GetResultsDirectionValue()
    return EasyFind and EasyFind.db
        and EasyFind.db.uiResultsAbove
        and RESULTS_ABOVE
        or RESULTS_BELOW
end

local function SyncOptionControls()
    if not optionsFrame then return end

    if optionsFrame.uiFontPresetRow then optionsFrame.uiFontPresetRow:SetValue(EasyFind.db.fontSize or 0.9) end
    if optionsFrame.mapIconPresetRow then optionsFrame.mapIconPresetRow:SetValue(EasyFind.db.iconScale or 0.8) end
    if optionsFrame.recentCountStepper then optionsFrame.recentCountStepper:SetValue(EasyFind.db.mapTabRecentCount or 3) end

    if optionsFrame.visibilityModeRow then optionsFrame.visibilityModeRow:SetValue(GetVisibilityModeValue()) end
    if optionsFrame.lockPositionCheckbox then optionsFrame.lockPositionCheckbox:SetChecked(EasyFind.db.lockPosition or false) end
    if optionsFrame.loginMessageCheckbox then optionsFrame.loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage == true) end
    if optionsFrame.aliasMessageCheckbox then optionsFrame.aliasMessageCheckbox:SetChecked(EasyFind.db.showAliasMessages ~= false) end
    if optionsFrame.resultsDirectionRow then optionsFrame.resultsDirectionRow:SetValue(GetResultsDirectionValue()) end
    if optionsFrame.resultShortcutHintsCheckbox then optionsFrame.resultShortcutHintsCheckbox:SetChecked(EasyFind.db.showResultShortcutHints ~= false) end
    if optionsFrame.minimapBtnCheckbox then optionsFrame.minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton ~= false) end
    if optionsFrame.rareTrackCheckbox then optionsFrame.rareTrackCheckbox:SetChecked(EasyFind.db.alwaysShowRares or false) end

    if optionsFrame.mapTabShowRecentCheckbox then optionsFrame.mapTabShowRecentCheckbox:SetChecked(EasyFind.db.mapTabShowRecent ~= false) end
    if optionsFrame.UpdateRecentCountEnabled then optionsFrame.UpdateRecentCountEnabled() end
    if optionsFrame.mapPinHighlightCheckbox then optionsFrame.mapPinHighlightCheckbox:SetChecked(EasyFind.db.mapPinHighlight ~= false) end
    if optionsFrame.blinkingPinsCheckbox then optionsFrame.blinkingPinsCheckbox:SetChecked(EasyFind.db.blinkingPins or false) end
    if optionsFrame.autoTrackPinsCheckbox then optionsFrame.autoTrackPinsCheckbox:SetChecked(EasyFind.db.autoTrackPins ~= false) end
    if optionsFrame.autoPinClearCheckbox then optionsFrame.autoPinClearCheckbox:SetChecked(EasyFind.db.autoPinClear ~= false) end
    if optionsFrame.UpdateMapToggleVisual then optionsFrame.UpdateMapToggleVisual() end

    if optionsFrame.indicatorBtnText then optionsFrame.indicatorBtnText:SetText(EasyFind.db.indicatorStyle or "EasyFind Arrow") end
    if optionsFrame.fontBtnText then optionsFrame.fontBtnText:SetText(EasyFind.db.font or "Default") end

    local clr = EasyFind.db.indicatorColor or "Yellow"
    local rgb = ns.INDICATOR_COLORS[clr] or ns.INDICATOR_COLORS.Yellow
    if optionsFrame.colorBtnText then
        optionsFrame.colorBtnText:SetText(clr)
        optionsFrame.colorBtnText:SetTextColor(Utils.RGB(rgb))
    end
    if optionsFrame.toggleFocusBtn then optionsFrame.toggleFocusBtn:SetText(GetBindingKey("EASYFIND_TOGGLE_FOCUS") or EasyFind:GetAccountKeybind("EASYFIND_TOGGLE_FOCUS") or L["OPT_KB_NOT_BOUND"]) end
    if optionsFrame.mapFocusBtn then optionsFrame.mapFocusBtn:SetText(GetBindingKey("EASYFIND_MAP_FOCUS") or EasyFind:GetAccountKeybind("EASYFIND_MAP_FOCUS") or L["OPT_KB_NOT_BOUND"]) end
    if optionsFrame.clearBtn then optionsFrame.clearBtn:SetText(GetBindingKey("EASYFIND_CLEAR") or EasyFind:GetAccountKeybind("EASYFIND_CLEAR") or L["OPT_KB_NOT_BOUND"]) end
end

local PaintRoundedFill = ns.SetRoundedRectFill
local function HideRoundedBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
end
local HideRoundedFrameBorder = HideRoundedBorder

local function StyleSelectorButton(btnFrame, height)
    btnFrame:SetBackdrop(nil)
    ns.CreateRoundedRectBorder(btnFrame)
    ns.SetRoundedRectBarHeight(btnFrame, mmin(height or 22, 10))
    HideRoundedFrameBorder(btnFrame)
    PaintRoundedFill(btnFrame, 0.095, 0.095, 0.108, 1)
    btnFrame:HookScript("OnEnter", function(self)
        if self:IsEnabled() then PaintRoundedFill(self, 0.155, 0.155, 0.172, 1) end
    end)
    btnFrame:HookScript("OnLeave", function(self)
        if self:IsEnabled() then PaintRoundedFill(self, 0.095, 0.095, 0.108, 1) end
    end)
end

local function CreateFlyoutSelector(parent, globalPrefix, width, anchor, initialText)
    local btnFrame = CreateFrame("Button", globalPrefix .. "Button", parent, "BackdropTemplate")
    btnFrame:SetSize(width, 22)
    btnFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    StyleSelectorButton(btnFrame, 22)

    local btnText = btnFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnText:SetPoint("LEFT", btnFrame, "LEFT", 8, 0)
    btnText:SetPoint("RIGHT", btnFrame, "RIGHT", -18, 0)
    btnText:SetJustifyH("CENTER")
    btnText:SetText(initialText)

    local arrow = btnFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    arrow:SetPoint("RIGHT", btnFrame, "RIGHT", -6, 0)
    arrow:SetText("v")
    btnFrame.arrow = arrow

    return btnFrame, btnText
end

local function CreateFlyoutPanel(btnFrame, globalPrefix, width, numChoices)
    local flyout = CreateFrame("Frame", globalPrefix .. "Flyout", btnFrame, "BackdropTemplate")
    flyout:SetSize(width, numChoices * 20 + 6)
    flyout:SetPoint("TOPRIGHT", btnFrame, "BOTTOMRIGHT", 0, -2)
    flyout:SetFrameStrata("FULLSCREEN_DIALOG")
    flyout:SetFrameLevel((optionsFrame and optionsFrame:GetFrameLevel() or OPTIONS_FRAME_LEVEL) + 20)
    flyout:SetBackdrop(nil)
    ns.CreateRoundedRectBorder(flyout)
    ns.SetRoundedRectBarHeight(flyout, 10)
    HideRoundedFrameBorder(flyout)
    PaintRoundedFill(flyout, 0.08, 0.08, 0.09, 1)
    flyout:Hide()

    btnFrame:SetScript("OnClick", function()
        local opening = not flyout:IsShown()
        flyout:SetShown(opening)
        if btnFrame.arrow then btnFrame.arrow:SetText(opening and "^" or "v") end
    end)

    flyout:SetScript("OnShow", function(self)
        self:SetFrameLevel((optionsFrame and optionsFrame:GetFrameLevel() or OPTIONS_FRAME_LEVEL) + 20)
        self:SetScript("OnUpdate", function(self)
            if not self:IsMouseOver() and not btnFrame:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                    self:Hide()
                end
            end
        end)
    end)
    flyout:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        if btnFrame.arrow then btnFrame.arrow:SetText("v") end
    end)

    return flyout
end

local function AddFlyoutOptions(flyout, choices, itemWidth, onSelect)
    for i, name in ipairs(choices) do
        local flyoutBtn = CreateFrame("Button", nil, flyout)
        flyoutBtn:SetSize(itemWidth, 18)
        flyoutBtn:SetPoint("TOPLEFT", flyout, "TOPLEFT", 3, -3 - (i - 1) * 20)
        local rowBg = CreateFrame("Frame", nil, flyoutBtn)
        rowBg:SetAllPoints()
        rowBg:EnableMouse(false)
        ns.CreateRoundedRectBorder(rowBg)
        ns.SetRoundedRectBarHeight(rowBg, 9)
        HideRoundedFrameBorder(rowBg)
        PaintRoundedFill(rowBg, 1, 1, 1, 0)
        local label = flyoutBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", flyoutBtn, "LEFT", 6, 0)
        label:SetPoint("RIGHT", flyoutBtn, "RIGHT", -6, 0)
        label:SetJustifyH("LEFT")
        label:SetText(name)
        flyoutBtn:SetScript("OnEnter", function()
            PaintRoundedFill(rowBg, 1, 1, 1, 0.06)
        end)
        flyoutBtn:SetScript("OnLeave", function()
            PaintRoundedFill(rowBg, 1, 1, 1, 0)
        end)
        flyoutBtn:SetScript("OnClick", function()
            onSelect(name)
            flyout:Hide()
        end)
    end
end

-- Stays a CheckButton so existing option code can keep using SetChecked /
-- GetChecked and OnClick callbacks.
local function CreateCheckbox(parent, name, label, tooltipText, compact, width)
    local frameName = name and ("EasyFindOptions" .. name .. "Checkbox") or nil
    local rowH = compact and 22 or 28
    local toggleW = compact and 28 or 32
    local toggleH = compact and 14 or 16
    local knobSize = toggleH - 2
    local checkbox = CreateFrame("CheckButton", frameName, parent)
    checkbox:SetSize(width or (compact and 220 or 330), rowH)
    checkbox:RegisterForClicks("LeftButtonUp")

    local rowBg = CreateFrame("Frame", nil, checkbox)
    rowBg:SetAllPoints()
    rowBg:EnableMouse(false)
    ns.CreateRoundedRectBorder(rowBg)
    ns.SetRoundedRectBarHeight(rowBg, 8)
    HideRoundedFrameBorder(rowBg)
    PaintRoundedFill(rowBg, 1, 1, 1, 0)
    checkbox.rowBg = rowBg

    local text = checkbox:CreateFontString(nil, "OVERLAY", compact and "GameFontHighlightSmall" or "GameFontNormalSmall")
    text:SetPoint("LEFT", checkbox, "LEFT", compact and 6 or 8, 0)
    text:SetJustifyH("LEFT")
    text:SetText(label or "")
    checkbox.Text = text

    local track = CreateFrame("Frame", nil, checkbox)
    track:SetSize(toggleW, toggleH)
    track:SetPoint("RIGHT", checkbox, "RIGHT", compact and -4 or -8, 0)
    track:EnableMouse(false)
    ns.CreateRoundedRectBorder(track)
    ns.SetRoundedRectBarHeight(track, toggleH)
    HideRoundedFrameBorder(track)
    checkbox.track = track

    text:SetPoint("RIGHT", track, "LEFT", -8, 0)

    local knob = CreateFrame("Frame", nil, track)
    knob:SetSize(knobSize, knobSize)
    knob:EnableMouse(false)
    ns.CreateRoundedRectBorder(knob)
    ns.SetRoundedRectBarHeight(knob, knobSize)
    HideRoundedFrameBorder(knob)
    PaintRoundedFill(knob, 0.96, 0.96, 0.96, 1)
    checkbox.knob = knob

    local function UpdateVisual(self)
        local enabled = self:IsEnabled()
        local checked = self:GetChecked()
        local rowAlpha = self:IsMouseOver() and enabled and 0.055 or 0
        PaintRoundedFill(self.rowBg, 1, 1, 1, rowAlpha)
        if checked and enabled then
            PaintRoundedFill(track, 0.17, 0.48, 0.72, 1)
            text:SetTextColor(1, 1, 1, 1)
        elseif checked then
            PaintRoundedFill(track, 0.13, 0.25, 0.34, 1)
            text:SetTextColor(0.55, 0.55, 0.55, 1)
        elseif enabled then
            PaintRoundedFill(track, 0.23, 0.23, 0.25, 1)
            text:SetTextColor(0.88, 0.88, 0.88, 1)
        else
            PaintRoundedFill(track, 0.13, 0.13, 0.14, 1)
            text:SetTextColor(0.50, 0.50, 0.50, 1)
        end

        knob:ClearAllPoints()
        if checked then
            knob:SetPoint("RIGHT", track, "RIGHT", -1, 0)
        else
            knob:SetPoint("LEFT", track, "LEFT", 1, 0)
        end
    end

    local rawSetChecked = checkbox.SetChecked
    checkbox.SetChecked = function(self, checked)
        rawSetChecked(self, checked)
        UpdateVisual(self)
    end
    checkbox.RefreshVisual = UpdateVisual
    checkbox.GetFontString = function(self) return self.Text end
    checkbox.SetText = function(self, value)
        self.Text:SetText(value or "")
    end

    -- Callers SetScript their own OnClick, which wipes a HookScript; wrap
    -- SetScript so the toggle always repaints synchronously on click.
    local rawSetScript = checkbox.SetScript
    checkbox.SetScript = function(self, scriptType, handler)
        if scriptType == "OnClick" and handler then
            rawSetScript(self, "OnClick", function(s, ...)
                UpdateVisual(s)
                handler(s, ...)
            end)
        else
            rawSetScript(self, scriptType, handler)
        end
    end

    checkbox:HookScript("OnClick", UpdateVisual)
    checkbox:HookScript("OnEnter", function(self)
        UpdateVisual(self)
        if tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    checkbox:HookScript("OnLeave", function(self)
        UpdateVisual(self)
        if tooltipText then GameTooltip_Hide() end
    end)
    checkbox:HookScript("OnEnable", UpdateVisual)
    checkbox:HookScript("OnDisable", UpdateVisual)

    UpdateVisual(checkbox)
    return checkbox
end

local DISABLED_TEXT = { 0.5, 0.5, 0.5 }
local NORMAL_TEXT = {1.0, 1.0, 1.0}
local OPTIONS_PANEL_SCALE = 0.88
local TEXT_PRIMARY = ns.TEXT_PRIMARY
local TEXT_BODY = ns.TEXT_BODY
local TEXT_DIM = ns.TEXT_DIM
local SECTION_TITLE_TEXT = ns.GOLD_COLOR
local NAV_SELECTED = { 0.15, 0.15, 0.17, 0.95 }
local NAV_HOVER = { 0.11, 0.11, 0.13, 0.85 }
local NAV_CLEAR = { 0, 0, 0, 0 }

local function TintRoundedFill(frame, r, g, b)
    ns.SetRoundedRectFill(frame, r, g, b, 1, true)
end

local function ApplyWizardPanelGloss(frame)
    local fill = frame.combinedBorder and frame.combinedBorder.fill
    if not fill then return end
    local H = frame:GetHeight()
    if not H or H <= 0 then return end
    local corner = (frame.cbBarHeight or 32) / 2
    local darkFrac = 0.90
    local function smoothstep(t)
        if t <= 0 then return 0 end
        if t >= 1 then return 1 end
        return t * t * (3 - 2 * t)
    end
    local function lerp(a, b, t) return a + (b - a) * t end
    local function colorAtY(y)
        local t = y / H
        if t < darkFrac then t = 0 else t = smoothstep((t - darkFrac) / (1 - darkFrac)) end
        return lerp(0.022, 0.20, t), lerp(0.022, 0.20, t), lerp(0.030, 0.22, t)
    end
    local function ramp(cell, yTop, yBot)
        if not cell then return end
        local r1, g1, b1 = colorAtY(yTop)
        local r2, g2, b2 = colorAtY(yBot)
        cell:SetGradient("VERTICAL", CreateColor(r2, g2, b2, 1), CreateColor(r1, g1, b1, 1))
    end
    ramp(fill.tl, 0, corner); ramp(fill.tm, 0, corner); ramp(fill.tr, 0, corner)
    ramp(fill.ml, corner, H - corner); ramp(fill.mm, corner, H - corner); ramp(fill.mr, corner, H - corner)
    ramp(fill.bl, H - corner, H); ramp(fill.bm, H - corner, H); ramp(fill.br, H - corner, H)
end

local function StyleWizardBackground(frame)
    ns.CreateRoundedRectBorder(frame)
    ns.SetRoundedRectBarHeight(frame, 16)
    ns.SetRoundedRectBorderBgAlpha(frame, OPTIONS_PANEL_ALPHA)
    HideRoundedBorder(frame)
    TintRoundedFill(frame, 0.04, 0.04, 0.05)
    ApplyWizardPanelGloss(frame)
    frame:HookScript("OnSizeChanged", ApplyWizardPanelGloss)
end

local function CreateModernCloseButton(parent)
    local closeBtn = CreateFrame("Button", nil, parent)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, -10)
    local function MakeStroke()
        local tex = closeBtn:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetSize(16, 1.5)
        tex:SetPoint("CENTER")
        return tex
    end
    local stroke1 = MakeStroke(); stroke1:SetRotation(math.pi / 4)
    local stroke2 = MakeStroke(); stroke2:SetRotation(-math.pi / 4)
    local function SetColor(r, g, b)
        stroke1:SetVertexColor(r, g, b, 1)
        stroke2:SetVertexColor(r, g, b, 1)
    end
    SetColor(Utils.RGB(TEXT_DIM))
    closeBtn:SetScript("OnEnter", function() SetColor(1, 1, 1) end)
    closeBtn:SetScript("OnLeave", function() SetColor(Utils.RGB(TEXT_DIM)) end)
    closeBtn:SetScript("OnClick", function() parent:Hide() end)
    return closeBtn
end

local SetModernButtonFill = ns.SetRoundedRectBorderFillColor
local SetModernButtonAlpha = ns.SetRoundedRectBorderBgAlpha

local function SetNavButtonBg(btn, color)
    SetModernButtonFill(btn, Utils.RGB(color, 1))
    SetModernButtonAlpha(btn, color[4] or 1)
end

local CreateModernButton = ns.CreateModernButton

local function CreateSettingsGroup(parent, width, height)
    local group = CreateFrame("Frame", nil, parent)
    group:SetSize(width, height)
    ns.CreateRoundedRectBorder(group)
    ns.SetRoundedRectBarHeight(group, 8)
    HideRoundedBorder(group)
    PaintRoundedFill(group, 0.060, 0.060, 0.070, 0.94)
    group.controls = {}
    group.AddControl = function(self, control)
        if control then tinsert(self.controls, control) end
        return control
    end
    group.SetGroupEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1.0 or 0.35)
        for _, control in ipairs(self.controls) do
            if control.SetGroupEnabled then
                control:SetGroupEnabled(enabled)
            elseif control.Enable and control.Disable then
                if enabled then control:Enable() else control:Disable() end
            end
        end
    end
    return group
end

local function FindNearestChoice(choices, value)
    local best = choices[1]
    local bestDelta
    for _, choice in ipairs(choices) do
        local delta = math.abs((value or choice.value) - choice.value)
        if not bestDelta or delta < bestDelta then
            best = choice
            bestDelta = delta
        end
    end
    return best
end

local function PaintPresetButton(btn, active, hover, enabled)
    if not enabled then
        SetModernButtonFill(btn, 0.070, 0.070, 0.080)
        if btn._label then btn._label:SetTextColor(Utils.RGB(TEXT_DIM, 1)) end
    elseif active then
        SetModernButtonFill(btn, 0.17, 0.48, 0.72)
        if btn._label then btn._label:SetTextColor(1, 1, 1, 1) end
    elseif hover then
        SetModernButtonFill(btn, 0.155, 0.155, 0.172)
        if btn._label then btn._label:SetTextColor(1, 1, 1, 1) end
    else
        SetModernButtonFill(btn, 0.095, 0.095, 0.108)
        if btn._label then btn._label:SetTextColor(Utils.RGB(TEXT_BODY, 1)) end
    end
end

local function CreateSegmentedPresetRow(parent, labelText, choices, getter, setter, tooltipText, width)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 330, 30)
    row.enabled = true

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -214, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
    label:SetText(labelText)
    row.label = label

    local trackW, trackH = 198, 24
    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(trackW, trackH)
    track:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    ns.CreateRoundedRectBorder(track)
    ns.SetRoundedRectBarHeight(track, trackH)
    ns.SetRoundedRectFill(track, 0.045, 0.047, 0.055, 0.96, true)
    HideRoundedFrameBorder(track)
    row.track = track

    local node = CreateFrame("Frame", nil, track, "BackdropTemplate")
    node:SetFrameLevel(track:GetFrameLevel() + 1)
    node:SetHeight(trackH - 4)
    ns.CreateRoundedRectBorder(node)
    ns.SetRoundedRectBarHeight(node, trackH - 4)
    HideRoundedFrameBorder(node)
    ns.SetRoundedRectFill(node, 0.17, 0.48, 0.72, 1, true)
    row.node = node

    row.buttons = {}
    local halfW = (trackW - 4) / 2
    for i = 1, 2 do
        local choice = choices[i]
        local btn = CreateFrame("Button", nil, track)
        btn:SetFrameLevel(track:GetFrameLevel() + 2)
        btn:SetSize(halfW, trackH)
        btn:SetPoint("LEFT", track, "LEFT", 2 + (i - 1) * halfW, 0)
        btn.choice = choice
        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("CENTER")
        text:SetText(choice.label)
        btn._label = text
        btn:SetScript("OnClick", function(self)
            if not row.enabled then return end
            local value = self.choice.value
            row:SetValue(value)
            RunSoon(function() setter(value) end)
        end)
        btn:SetScript("OnEnter", function(self)
            if tooltipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(labelText)
                GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function()
            if tooltipText then GameTooltip_Hide() end
        end)
        row.buttons[i] = btn
    end

    row.SetValue = function(self, value)
        local choice = FindNearestChoice(choices, value)
        self.activeValue = choice and choice.value
        local activeIndex = self.activeValue == choices[2].value and 2 or 1
        node:ClearAllPoints()
        node:SetWidth(halfW)
        node:SetPoint("LEFT", track, "LEFT", 2 + (activeIndex - 1) * halfW, 0)
        for i, btn in ipairs(self.buttons) do
            local active = activeIndex == i
            local enabled = self.enabled
            local c = enabled and (active and NORMAL_TEXT or TEXT_BODY) or DISABLED_TEXT
            btn._label:SetTextColor(Utils.RGB(c, 1))
        end
    end
    row.SetGroupEnabled = function(self, enabled)
        self.enabled = enabled
        self:SetAlpha(enabled and 1.0 or 0.35)
        if self.label then
            local c = enabled and NORMAL_TEXT or DISABLED_TEXT
            self.label:SetTextColor(Utils.RGB(c, 1))
        end
        ns.SetRoundedRectFill(track, enabled and 0.045 or 0.035, enabled and 0.047 or 0.035, enabled and 0.055 or 0.040, 0.96, true)
        for _, btn in ipairs(self.buttons) do
            if enabled then btn:Enable() else btn:Disable() end
        end
        self:SetValue(self.activeValue or getter())
    end

    row:SetValue(getter())
    return row
end

local function CreatePresetRow(parent, labelText, choices, getter, setter, tooltipText, width)
    if #choices == 2 then
        return CreateSegmentedPresetRow(parent, labelText, choices, getter, setter, tooltipText, width)
    end

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 330, 28)
    row.enabled = true

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    local controlW = (#choices == 3) and 174 or 184
    label:SetPoint("RIGHT", row, "RIGHT", -controlW - 18, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
    label:SetText(labelText)
    row.label = label

    row.buttons = {}
    local btnW = math.floor(controlW / #choices)
    local right = -8
    for i = #choices, 1, -1 do
        local choice = choices[i]
        local btn = CreateModernButton(row, choice.label, btnW, 20)
        ns.SetRoundedRectBarHeight(btn, 16)
        btn.choice = choice
        btn:SetPoint("RIGHT", row, "RIGHT", right, 0)
        right = right - btnW - 2
        btn:SetScript("OnClick", function(self)
            if not row.enabled then return end
            local value = self.choice.value
            row:SetValue(value)
            RunSoon(function() setter(value) end)
        end)
        btn:SetScript("OnEnter", function(self)
            PaintPresetButton(self, row.activeValue == self.choice.value, true, row.enabled)
            if tooltipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(labelText)
                GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function(self)
            PaintPresetButton(self, row.activeValue == self.choice.value, false, row.enabled)
            if tooltipText then GameTooltip_Hide() end
        end)
        row.buttons[i] = btn
    end

    row.SetValue = function(self, value)
        local choice = FindNearestChoice(choices, value)
        self.activeValue = choice and choice.value
        for _, btn in ipairs(self.buttons) do
            PaintPresetButton(btn, self.activeValue == btn.choice.value, false, self.enabled)
        end
    end
    row.SetGroupEnabled = function(self, enabled)
        self.enabled = enabled
        self:SetAlpha(enabled and 1.0 or 0.35)
        if self.label then
            local c = enabled and NORMAL_TEXT or DISABLED_TEXT
            self.label:SetTextColor(Utils.RGB(c, 1))
        end
        for _, btn in ipairs(self.buttons) do
            if enabled then btn:Enable() else btn:Disable() end
            PaintPresetButton(btn, self.activeValue == btn.choice.value, false, enabled)
        end
    end

    row:SetValue(getter())
    return row
end

local function CreateStepperRow(parent, labelText, minVal, maxVal, getter, setter, tooltipText, width)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 330, 28)
    row.enabled = true

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -112, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
    label:SetText(labelText)

    local plusBtn = CreateModernButton(row, "+", 24, 20)
    plusBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    local valueText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetSize(32, 20)
    valueText:SetPoint("RIGHT", plusBtn, "LEFT", -4, 0)
    valueText:SetJustifyH("CENTER")
    local minusBtn = CreateModernButton(row, "-", 24, 20)
    minusBtn:SetPoint("RIGHT", valueText, "LEFT", -4, 0)

    local function SetValue(value)
        value = mmax(minVal, mmin(maxVal, mfloor((value or minVal) + 0.5)))
        setter(value)
        valueText:SetText(tostring(value))
    end
    local function Step(delta)
        if row.enabled then SetValue((getter() or minVal) + delta) end
    end
    minusBtn:SetScript("OnClick", function() Step(-1) end)
    plusBtn:SetScript("OnClick", function() Step(1) end)

    if tooltipText then
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(labelText)
            GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end

    row.SetValue = function(_, value)
        valueText:SetText(tostring(mmax(minVal, mmin(maxVal, mfloor((value or minVal) + 0.5)))))
    end
    row.SetGroupEnabled = function(self, enabled)
        self.enabled = enabled
        self:SetAlpha(enabled and 1.0 or 0.35)
        local c = enabled and NORMAL_TEXT or DISABLED_TEXT
        label:SetTextColor(Utils.RGB(c, 1))
        if enabled then
            minusBtn:Enable()
            plusBtn:Enable()
        else
            minusBtn:Disable()
            plusBtn:Disable()
        end
    end
    row:SetValue(getter())
    return row
end

local function SetControlsEnabled(controls, enabled)
    for _, ctrl in ipairs(controls) do
        local objType = ctrl.GetObjectType and ctrl:GetObjectType()
        if objType == "CheckButton" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
            if ctrl.Text then
                local r, g, b = enabled and 1.0 or DISABLED_TEXT[1], enabled and 1.0 or DISABLED_TEXT[2], enabled and 1.0 or DISABLED_TEXT[3]
                ctrl.Text:SetTextColor(r, g, b)
            end
            if ctrl.RefreshVisual then ctrl:RefreshVisual() end
        elseif objType == "Slider" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
            if ctrl.Text then
                ctrl.Text:SetTextColor(enabled and NORMAL_TEXT[1] or DISABLED_TEXT[1], enabled and NORMAL_TEXT[2] or DISABLED_TEXT[2], enabled and NORMAL_TEXT[3] or DISABLED_TEXT[3])
            end
            if ctrl.Low then ctrl.Low:SetTextColor(enabled and 0.7 or 0.4, enabled and 0.7 or 0.4, enabled and 0.7 or 0.4) end
            if ctrl.High then ctrl.High:SetTextColor(enabled and 0.7 or 0.4, enabled and 0.7 or 0.4, enabled and 0.7 or 0.4) end
            if ctrl.valueText then ctrl.valueText:SetTextColor(enabled and 1.0 or 0.4, enabled and 1.0 or 0.4, enabled and 1.0 or 0.4) end
            if ctrl.inputBox then
                if enabled then ctrl.inputBox:Enable(); ctrl.inputBox:SetTextColor(1, 1, 1)
                else ctrl.inputBox:Disable(); ctrl.inputBox:SetTextColor(0.4, 0.4, 0.4) end
            end
            if ctrl.suffixLabel then ctrl.suffixLabel:SetTextColor(enabled and 1 or 0.4, enabled and 1 or 0.4, enabled and 1 or 0.4) end
            if ctrl.resetBtn then
                if enabled then ctrl.resetBtn:Enable() else ctrl.resetBtn:Disable() end
            end
        elseif objType == "Button" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
        elseif objType == "Frame" then
            if ctrl.SetGroupEnabled then
                ctrl:SetGroupEnabled(enabled)
            else
                ctrl:SetAlpha(enabled and 1.0 or 0.35)
            end
        end
    end
end

function Options:Initialize()
    if isInitialized then return end

    local WINDOW_W   = 544
    local WINDOW_H   = 408
    local SIDEBAR_W  = 132
    local FRAME_W    = WINDOW_W - SIDEBAR_W - 46
    local COL_LEFT   = 4

    optionsFrame = CreateFrame("Frame", "EasyFindOptionsFrame", UIParent, "BackdropTemplate")
    ns.optionsFrame = optionsFrame
    optionsFrame:SetSize(WINDOW_W, WINDOW_H)
    optionsFrame:SetScale(OPTIONS_PANEL_SCALE)
    if EasyFind.db.optionsPosition then
        local pos = EasyFind.db.optionsPosition
        optionsFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    optionsFrame:SetFrameStrata(OPTIONS_FRAME_STRATA)
    optionsFrame:SetFrameLevel(OPTIONS_FRAME_LEVEL)
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        EasyFind.db.optionsPosition = {point, relPoint, x, y}
    end)

    optionsFrame:SetBackdrop(nil)

    local bgTex = CreateFrame("Frame", nil, optionsFrame)
    bgTex:SetAllPoints(optionsFrame)
    bgTex:EnableMouse(false)
    StyleWizardBackground(bgTex)
    bgTex:SetAlpha(OPTIONS_PANEL_ALPHA)
    optionsFrame.bgTex = bgTex

    local sidebar = CreateFrame("Frame", nil, optionsFrame)
    sidebar:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 10, -10)
    sidebar:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 10, 10)
    sidebar:SetWidth(SIDEBAR_W)
    optionsFrame.sidebar = sidebar
    ns.CreateRoundedRectBorder(sidebar)
    ns.SetRoundedRectBarHeight(sidebar, 14)
    ns.SetRoundedRectBorderBgAlpha(sidebar, 0.72)
    HideRoundedBorder(sidebar)
    TintRoundedFill(sidebar, 0.022, 0.022, 0.028)

    local divider = optionsFrame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 8, -2)
    divider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 8, 2)
    divider:SetWidth(1)
    divider:SetColorTexture(1, 1, 1, 0.08)

    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 4, -6)
    title:SetText(L["OPT_SETTINGS_TITLE"])
    title:SetTextColor(Utils.RGB(TEXT_BODY, 1))
    optionsFrame.titleText = title

    local closeBtn = CreateModernCloseButton(optionsFrame)
    optionsFrame.closeBtn = closeBtn

    local contentBorder = CreateFrame("Frame", nil, optionsFrame)
    contentBorder:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", SIDEBAR_W + 32, -46)
    contentBorder:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -14, 14)
    optionsFrame.contentBorder = contentBorder

    local tabFrames = {}
    local tabButtons = {}

    local function SetTabActive(btn, active)
        btn.isActive = active
        if active then
            SetNavButtonBg(btn, NAV_SELECTED)
            btn.label:SetTextColor(Utils.RGB(TEXT_PRIMARY, 1))
        else
            SetNavButtonBg(btn, NAV_CLEAR)
            btn.label:SetTextColor(Utils.RGB(TEXT_BODY, 1))
        end
    end

    local function SwitchToTab(index)
        for i, tf in ipairs(tabFrames) do
            tf:SetShown(i == index)
            SetTabActive(tabButtons[i], i == index)
        end
    end
    optionsFrame.SwitchToTab = SwitchToTab

    local function CreateTab(tabName)
        local index = #tabFrames + 1

        local btn = CreateFrame("Button", nil, sidebar)
        btn:SetSize(SIDEBAR_W - 16, 28)
        btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, -34 - (index - 1) * 32)
        ns.CreateRoundedRectBorder(btn)
        ns.SetRoundedRectBarHeight(btn, 10)
        ns.SetRoundedRectBorderBgAlpha(btn, 0)
        HideRoundedBorder(btn)
        SetNavButtonBg(btn, NAV_CLEAR)

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", btn, "LEFT", 10, 0)
        label:SetPoint("RIGHT", btn, "RIGHT", -10, 0)
        label:SetJustifyH("LEFT")
        label:SetText(tabName)
        label:SetTextColor(Utils.RGB(TEXT_BODY, 1))
        btn.label = label

        btn:SetScript("OnEnter", function(self)
            if not self.isActive then
                SetNavButtonBg(self, NAV_HOVER)
                self.label:SetTextColor(Utils.RGB(TEXT_PRIMARY, 1))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if not self.isActive then
                SetNavButtonBg(self, NAV_CLEAR)
                self.label:SetTextColor(Utils.RGB(TEXT_BODY, 1))
            end
        end)
        btn:SetScript("OnClick", function() SwitchToTab(index) end)
        tinsert(tabButtons, btn)

        local content = CreateFrame("Frame", nil, contentBorder)
        content:SetAllPoints(contentBorder)
        content:Hide()
        tinsert(tabFrames, content)

        return content
    end

    local function GetCurrentKeybindText(action)
        local key1, key2 = GetBindingKey(action)
        if key1 then return key1 end
        if key2 then return key2 end
        return EasyFind:GetAccountKeybind(action) or L["OPT_KB_NOT_BOUND"]
    end

    local function StopCapture(keybindBtn, action)
        keybindBtn.waitingForKey = false
        keybindBtn:SetText(GetCurrentKeybindText(action))
        keybindBtn:UnlockHighlight()
        Utils.SafeCallMethod(keybindBtn, "EnableKeyboard", false)
        keybindBtn:SetScript("OnKeyDown", nil)
    end

    local function StartCapture(keybindBtn, action)
        if keybindBtn.waitingForKey then
            StopCapture(keybindBtn, action)
        else
            keybindBtn.waitingForKey = true
            keybindBtn:SetText(L["OPT_KB_PRESS_KEY"])
            keybindBtn:LockHighlight()
            Utils.SafeCallMethod(keybindBtn, "EnableKeyboard", true)
            keybindBtn:SetScript("OnKeyDown", function(self, key)
                if Utils.IsModifierKey(key) then return end
                if key == "ESCAPE" then
                    StopCapture(self, action)
                    return
                end
                -- Bare SPACE / ENTER / WASD silently overwriting jump,
                -- accept, or movement on a stray capture-keypress has
                -- bricked spacebar after /reload before. Only bind these
                -- when modified.
                local hasMod = IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()
                if not hasMod and Utils.IsReservedBareKey(key) then return end
                EasyFind:SetAccountKeybind(action, Utils.ModifierCombo(key))
                StopCapture(self, action)
            end)
        end
    end

    local function MakeKeybindTooltip(keybindBtn, titleText, line1)
        keybindBtn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(titleText)
            GameTooltip:AddLine(line1, 1, 1, 1, true)
            GameTooltip:AddLine(L["OPT_KB_CLEAR_HINT"], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        keybindBtn:HookScript("OnLeave", GameTooltip_Hide)
    end

    local homeTab = CreateTab(L["OPT_TAB_HOME"])
    local homeIcon = homeTab:CreateTexture(nil, "ARTWORK")
    homeIcon:SetSize(48, 48)
    homeIcon:SetPoint("TOPLEFT", homeTab, "TOPLEFT", 12, -4)
    homeIcon:SetTexture("Interface\\AddOns\\EasyFind\\textures\\Spyglass")

    local homeTitle = homeTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    homeTitle:SetPoint("LEFT", homeIcon, "RIGHT", 12, 6)
    homeTitle:SetText(L["OPT_ADDON_NAME"])

    local homeVersion = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    homeVersion:SetPoint("LEFT", homeTitle, "RIGHT", 6, 0)
    local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("EasyFind", "Version")
    homeVersion:SetText("|cFF888888v" .. (tocVersion or "") .. "|r")

    local homeDesc = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    homeDesc:SetPoint("TOPLEFT", homeIcon, "BOTTOMLEFT", 0, -14)
    homeDesc:SetPoint("RIGHT", homeTab, "RIGHT", -12, 0)
    homeDesc:SetJustifyH("LEFT")
    homeDesc:SetSpacing(3)
    homeDesc:SetText(
        "|cFFFFD100Quick start:|r  Type in the search bar to find UI panels, map locations, "
        .. "and more. Click a result to navigate there.\n\n"
        .. "Use the |cFFFFD100filter button|r on the search bar to add mounts, toys, pets, and "
        .. "map results to your searches. The world map's |cFFFFD100EasyFind|r tab handles "
        .. "zones, dungeons, and points of interest directly on the map.\n\n"
        .. "For a full walkthrough, see the CurseForge page:"
    )

    local thankYou = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    thankYou:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -16, 6)
    thankYou:SetText(L["OPT_HOME_WELCOME"])

    local function CreateURLBox(parent, url, anchor, yOff)
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetSize(FRAME_W - 60, 18)
        box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
        box:SetAutoFocus(false)
        box:SetFontObject(SMALL_HIGHLIGHT_FONT)
        box:SetText(url)
        box:SetCursorPosition(0)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnTextChanged", function(self) self:SetText(url); self:SetCursorPosition(0) end)
        box:SetScript("OnMouseUp", function(self)
            if not self:IsMouseOver() then self:ClearFocus() end
        end)
        return box
    end

    CreateURLBox(homeTab, "https://www.curseforge.com/wow/addons/easyfind", homeDesc, -6)

    local sec3 = CreateTab(L["OPT_TAB_GENERAL_BINDS"])

    local loginMessageCheckbox = CreateCheckbox(sec3, "LoginMessage", L["OPT_SHOW_LOGIN_MESSAGE"],
        L["OPT_LOGIN_MESSAGE_TT"])
    loginMessageCheckbox:SetPoint("TOPLEFT", sec3, "TOPLEFT", 8, -8)
    loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage == true)
    loginMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showLoginMessage = self:GetChecked()
    end)
    optionsFrame.loginMessageCheckbox = loginMessageCheckbox

    local minimapBtnCheckbox = CreateCheckbox(sec3, "MinimapBtn", L["OPT_SHOW_MINIMAP_BUTTON"],
        L["OPT_MINIMAP_BTN_TT"])
    local aliasMessageCheckbox = CreateCheckbox(sec3, "AliasMessages", L["OPT_SHOW_ALIAS_MESSAGES"],
        L["OPT_ALIAS_MSG_TT"])
    aliasMessageCheckbox:SetPoint("TOPLEFT", loginMessageCheckbox, "BOTTOMLEFT", 0, -2)
    aliasMessageCheckbox:SetChecked(EasyFind.db.showAliasMessages ~= false)
    aliasMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showAliasMessages = self:GetChecked()
    end)
    optionsFrame.aliasMessageCheckbox = aliasMessageCheckbox

    minimapBtnCheckbox:SetPoint("TOPLEFT", aliasMessageCheckbox, "BOTTOMLEFT", 0, -2)
    minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton ~= false)
    minimapBtnCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showMinimapButton = self:GetChecked()
        EasyFind:UpdateMinimapButton()
    end)
    optionsFrame.minimapBtnCheckbox = minimapBtnCheckbox

    local SELECTOR_ROW_W = FRAME_W - 16
    local SELECTOR_BTN_W = 170
    local function CreateSelectorRow(anchor, labelText)
        local row = CreateFrame("Frame", nil, sec3)
        row:SetSize(SELECTOR_ROW_W, 24)
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -SELECTOR_BTN_W - 18, 0)
        label:SetJustifyH("LEFT")
        label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
        label:SetText(labelText)
        return row, label
    end

    local indicatorRow, indicatorLabel = CreateSelectorRow(minimapBtnCheckbox, L["OPT_INDICATOR_STYLE"])

    local indicatorChoices = {"EasyFind Arrow", "Classic Quest Arrow", "Minimap Player Arrow", "Low-res Gauntlet", "HD Gauntlet"}

    local indicatorBtnFrame, indicatorBtnText = CreateFlyoutSelector(
        indicatorRow, "EasyFindIndicator", SELECTOR_BTN_W, indicatorLabel, EasyFind.db.indicatorStyle or "EasyFind Arrow"
    )
    local indicatorFlyout = CreateFlyoutPanel(indicatorBtnFrame, "EasyFindIndicator", SELECTOR_BTN_W, #indicatorChoices)
    AddFlyoutOptions(indicatorFlyout, indicatorChoices, SELECTOR_BTN_W - 6, function(name)
        EasyFind.db.indicatorStyle = name
        indicatorBtnText:SetText(name)
        if ns.MapSearch then
            ns.MapSearch:RefreshIndicators()
        end
    end)
    optionsFrame.indicatorBtnText = indicatorBtnText
    optionsFrame.indicatorFlyout = indicatorFlyout

    local colorRow, colorLabel = CreateSelectorRow(indicatorRow, L["OPT_INDICATOR_COLOR"])

    local colorChoices = {"Yellow", "Gold", "Orange", "Red", "Green", "Blue", "Purple", "White"}
    local colorRGB = ns.INDICATOR_COLORS

    local colorBtnFrame, colorBtnText = CreateFlyoutSelector(
        colorRow, "EasyFindColor", SELECTOR_BTN_W, colorLabel, EasyFind.db.indicatorColor or "Yellow"
    )
    local currentColor = EasyFind.db.indicatorColor or "Yellow"
    local currentRGB = colorRGB[currentColor] or colorRGB.Yellow
    colorBtnText:SetTextColor(Utils.RGB(currentRGB))

    local colorFlyout = CreateFlyoutPanel(colorBtnFrame, "EasyFindColor", SELECTOR_BTN_W, #colorChoices)

    for i, name in ipairs(colorChoices) do
        local rgb = colorRGB[name]
        local colorBtn = CreateFrame("Button", nil, colorFlyout)
        colorBtn:SetSize(SELECTOR_BTN_W - 6, 18)
        colorBtn:SetPoint("TOPLEFT", colorFlyout, "TOPLEFT", 3, -3 - (i - 1) * 20)
        local rowBg = CreateFrame("Frame", nil, colorBtn)
        rowBg:SetAllPoints()
        rowBg:EnableMouse(false)
        ns.CreateRoundedRectBorder(rowBg)
        ns.SetRoundedRectBarHeight(rowBg, 9)
        HideRoundedFrameBorder(rowBg)
        PaintRoundedFill(rowBg, 1, 1, 1, 0)

        local label = colorBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", colorBtn, "LEFT", 6, 0)
        label:SetPoint("RIGHT", colorBtn, "RIGHT", -6, 0)
        label:SetJustifyH("CENTER")
        label:SetText(name)
        label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))

        colorBtn:SetScript("OnEnter", function(self)
            PaintRoundedFill(rowBg, 1, 1, 1, 0.06)
            label:SetTextColor(1, 1, 1)
        end)
        colorBtn:SetScript("OnLeave", function(self)
            PaintRoundedFill(rowBg, 1, 1, 1, 0)
            label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
        end)
        colorBtn:SetScript("OnClick", function()
            EasyFind.db.indicatorColor = name
            colorBtnText:SetText(name)
            colorBtnText:SetTextColor(Utils.RGB(rgb))
            colorFlyout:Hide()
            if ns.MapSearch then
                ns.MapSearch:RefreshIndicators()
            end
        end)
    end

    optionsFrame.colorBtnText = colorBtnText
    optionsFrame.colorFlyout = colorFlyout

    local fontRow, fontLabel = CreateSelectorRow(colorRow, L["OPT_FONT"])

    local fontChoices = ns.FONT_CHOICES
    local fontBtnFrame, fontBtnText = CreateFlyoutSelector(
        fontRow, "EasyFindFont", SELECTOR_BTN_W, fontLabel, EasyFind.db.font or "Default"
    )
    local fontFlyout = CreateFlyoutPanel(fontBtnFrame, "EasyFindFont", SELECTOR_BTN_W, #fontChoices)
    AddFlyoutOptions(fontFlyout, fontChoices, SELECTOR_BTN_W - 6, function(name)
        EasyFind.db.font = name
        fontBtnText:SetText(name)
        if ns.RefreshAddonFont then ns.RefreshAddonFont() end
    end)
    optionsFrame.fontBtnText = fontBtnText
    optionsFrame.fontFlyout = fontFlyout

    local keybindHeader = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    keybindHeader:SetPoint("TOPLEFT", fontRow, "BOTTOMLEFT", 8, -18)
    keybindHeader:SetText(L["OPT_KEYBINDS_HEADER"])
    keybindHeader:SetTextColor(Utils.RGB(SECTION_TITLE_TEXT, 1))

    local keybindDefs = {
        { label = L["OPT_KEYBIND_TOGGLE_SEARCH"], action = "EASYFIND_TOGGLE_FOCUS" },
        { label = L["OPT_KEYBIND_OPEN_MAP_TAB"],  action = "EASYFIND_MAP_FOCUS" },
        { label = L["OPT_KEYBIND_CLEAR_ALL"],     action = "EASYFIND_CLEAR" },
    }

    local keybindTooltips = {
        EASYFIND_TOGGLE_FOCUS = { L["OPT_KEYBIND_TOGGLE_SEARCH"], L["OPT_KB_TOGGLE_TT_DESC"] },
        EASYFIND_MAP_FOCUS    = { L["OPT_KEYBIND_OPEN_MAP_TAB"],  L["OPT_KB_MAP_TT_DESC"] },
        EASYFIND_CLEAR        = { L["OPT_KEYBIND_CLEAR_ALL"],     L["OPT_KB_CLEAR_TT_DESC"] },
    }

    local keybindButtons = {}
    local KEYBIND_ROW_H = 24
    local KEYBIND_BTN_W = 116
    local KEYBIND_LABEL_W = 168
    local keybindSettings = CreateSettingsGroup(sec3, SELECTOR_ROW_W, KEYBIND_ROW_H * #keybindDefs + 8)
    keybindSettings:SetPoint("TOPLEFT", keybindHeader, "BOTTOMLEFT", 0, -3)
    optionsFrame.keybindSettings = keybindSettings

    for i, def in ipairs(keybindDefs) do
        local row = i - 1

        local rowFrame = CreateFrame("Frame", nil, keybindSettings)
        rowFrame:SetSize(SELECTOR_ROW_W, KEYBIND_ROW_H)
        rowFrame:SetPoint("TOPLEFT", keybindSettings, "TOPLEFT", 0, -4 - row * KEYBIND_ROW_H)

        local rowLabel = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rowLabel:SetPoint("LEFT", rowFrame, "LEFT", 8, 0)
        rowLabel:SetText(def.label .. ":")
        rowLabel:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))

        local keybindBtn = CreateModernButton(rowFrame)
        keybindBtn:SetNormalFontObject("GameFontHighlightSmall")
        keybindBtn:SetHighlightFontObject("GameFontHighlightSmall")
        keybindBtn:SetSize(KEYBIND_BTN_W, 20)
        keybindBtn:SetPoint("LEFT", rowLabel, "LEFT", KEYBIND_LABEL_W, 0)
        keybindBtn:SetText(GetCurrentKeybindText(def.action))
        keybindBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                EasyFind:SetAccountKeybind(def.action, nil)
                self:SetText(L["OPT_KB_NOT_BOUND"])
            else
                StartCapture(self, def.action)
            end
        end)
        keybindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local tip = keybindTooltips[def.action]
        if tip then
            MakeKeybindTooltip(keybindBtn, tip[1], tip[2])
        end

        keybindButtons[def.action] = keybindBtn
    end
    optionsFrame.toggleFocusBtn = keybindButtons["EASYFIND_TOGGLE_FOCUS"]
    optionsFrame.mapFocusBtn    = keybindButtons["EASYFIND_MAP_FOCUS"]
    optionsFrame.clearBtn       = keybindButtons["EASYFIND_CLEAR"]

    local RESET_BTN_W = 120

    local sec1 = CreateTab(L["OPT_TAB_SEARCH"])

    local resizeUIBtn = CreateModernButton(sec1)
    resizeUIBtn:SetSize(RESET_BTN_W, 20)
    resizeUIBtn:SetPoint("BOTTOMLEFT", sec1, "BOTTOMLEFT", 16, 32)
    resizeUIBtn:SetText(L["OPT_RESIZE_UI_SEARCH"])
    resizeUIBtn:SetScript("OnClick", function()
        if ns.Rescaler then ns.Rescaler:Enter("ui") end
    end)
    resizeUIBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["OPT_RESIZE_UI_TT"])
        GameTooltip:Show()
    end)
    resizeUIBtn:HookScript("OnLeave", GameTooltip_Hide)

    local visibilityModeRow
    local function ApplyVisibilityMode(value)
        local smart = value == VISIBILITY_SMART
        EasyFind.db.smartShow = smart
        EasyFind.db.autoHide = not smart
        if visibilityModeRow then visibilityModeRow:SetValue(value) end
        RunSoon(function()
            if EasyFind.db.smartShow then
                if ns.Search and ns.Search.Show then ns.Search:Show(false) end
                if ns.Search and ns.Search.UpdateSmartShow then ns.Search:UpdateSmartShow() end
            else
                if ns.Search and ns.Search.UpdateSmartShow then ns.Search:UpdateSmartShow() end
                if ns.Search and ns.Search.Hide then ns.Search:Hide() end
            end
        end)
    end

    local function SetVisibilityMode(value)
        ApplyVisibilityMode(value)
    end

    visibilityModeRow = CreatePresetRow(sec1, L["OPT_VISIBILITY"],
        {
            { label = L["OPT_VISIBILITY_AUTOHIDE"], value = VISIBILITY_AUTO },
            { label = L["OPT_VISIBILITY_SMARTSHOW"], value = VISIBILITY_SMART },
        },
        GetVisibilityModeValue,
        SetVisibilityMode,
        "Auto-Hide opens EasyFind from your keybind and hides it when you press Escape or click away. Smart Show uses a hover zone near the search bar.",
        330)
    visibilityModeRow:SetPoint("TOPLEFT", sec1, "TOPLEFT", 16, -8)
    optionsFrame.visibilityModeRow = visibilityModeRow

    local initialVisibility = GetVisibilityModeValue()
    EasyFind.db.smartShow = initialVisibility == VISIBILITY_SMART
    EasyFind.db.autoHide = initialVisibility ~= VISIBILITY_SMART
    visibilityModeRow:SetValue(initialVisibility)

    local lockPositionCheckbox = CreateCheckbox(sec1, "LockPosition", L["OPT_LOCK_POSITION"],
        L["OPT_LOCK_POSITION_TT"])
    lockPositionCheckbox:SetPoint("TOPLEFT", visibilityModeRow, "BOTTOMLEFT", 0, -2)
    lockPositionCheckbox:SetChecked(EasyFind.db.lockPosition or false)
    lockPositionCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.lockPosition = self:GetChecked()
    end)
    optionsFrame.lockPositionCheckbox = lockPositionCheckbox

    local resultsDirectionRow = CreatePresetRow(sec1, L["OPT_RESULTS_DIRECTION"],
        {
            { label = L["OPT_RESULTS_BELOW"], value = RESULTS_BELOW },
            { label = L["OPT_RESULTS_ABOVE"], value = RESULTS_ABOVE },
        },
        GetResultsDirectionValue,
        function(value)
            EasyFind.db.uiResultsAbove = value == RESULTS_ABOVE
            if optionsFrame.resultsDirectionRow then
                optionsFrame.resultsDirectionRow:SetValue(value)
            end
            RunSoon(function()
                if ns.Search and ns.Search.RefreshResults then ns.Search:RefreshResults() end
            end)
        end,
        L["OPT_RESULTS_DIRECTION_TT"],
        330)
    resultsDirectionRow:SetPoint("TOPLEFT", visibilityModeRow, "BOTTOMLEFT", 0, -2)
    optionsFrame.resultsDirectionRow = resultsDirectionRow

    local resultShortcutHintsCheckbox = CreateCheckbox(sec1, "ResultShortcutHints", L["OPT_SHOW_ALT_HINTS"],
        L["OPT_ALT_HINTS_TT"])
    resultShortcutHintsCheckbox:SetPoint("TOPLEFT", resultsDirectionRow, "BOTTOMLEFT", 0, -2)
    resultShortcutHintsCheckbox:SetChecked(EasyFind.db.showResultShortcutHints ~= false)
    resultShortcutHintsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showResultShortcutHints = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        RunSoon(function()
            if ns.Search and ns.Search.RefreshResults then
                ns.Search:RefreshResults()
            end
        end)
    end)
    optionsFrame.resultShortcutHintsCheckbox = resultShortcutHintsCheckbox

    local fontSizeChoices = {
        { label = L["OPT_FONT_SMALL"], value = 0.80 },
        { label = L["OPT_FONT_MED"],   value = 0.90 },
        { label = L["OPT_FONT_LARGE"], value = 1.15 },
        { label = L["OPT_FONT_XL"],    value = 1.35 },
    }
    local uiFontPresetRow = CreatePresetRow(sec1, L["OPT_FONT_SIZE"], fontSizeChoices,
        function() return EasyFind.db.fontSize or 0.9 end,
        function(value)
            EasyFind.db.fontSize = value
            if ns.Search and ns.Search.UpdateFontSize then
                ns.Search:UpdateFontSize()
            end
        end,
        L["OPT_FONT_SIZE_TT"])
    uiFontPresetRow:SetPoint("TOPLEFT", resultsDirectionRow, "BOTTOMLEFT", 0, -8)
    optionsFrame.uiFontPresetRow = uiFontPresetRow

    lockPositionCheckbox:ClearAllPoints()
    lockPositionCheckbox:SetPoint("TOPLEFT", uiFontPresetRow, "BOTTOMLEFT", 0, -8)
    resultShortcutHintsCheckbox:ClearAllPoints()
    resultShortcutHintsCheckbox:SetPoint("TOPLEFT", lockPositionCheckbox, "BOTTOMLEFT", 0, -2)

    local function RefreshUIPresetRows()
        if optionsFrame.uiFontPresetRow then
            optionsFrame.uiFontPresetRow:SetValue(EasyFind.db.fontSize or 0.9)
        end
    end
    optionsFrame.RefreshUIPresetRows = RefreshUIPresetRows

    local resetUIBtn = CreateModernButton(sec1)
    resetUIBtn:SetSize(RESET_BTN_W, 20)
    resetUIBtn:SetPoint("BOTTOMLEFT", sec1, "BOTTOMLEFT", 16, 8)
    resetUIBtn:SetText(L["OPT_RESET_SETTINGS"])
    resetUIBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_UI")
    end)

    local resetUIPosBtn = CreateModernButton(sec1)
    resetUIPosBtn:SetSize(RESET_BTN_W, 20)
    resetUIPosBtn:SetPoint("LEFT", resetUIBtn, "RIGHT", 8, 0)
    resetUIPosBtn:SetText(L["OPT_RESET_POSITIONS"])
    resetUIPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_UI_POS")
    end)

    local sec2 = CreateTab(L["OPT_TAB_MAP"])

    local mapEnableCheckbox = CreateCheckbox(sec2, "EnableMap", L["OPT_ENABLE_MAP_MODULE"],
        L["OPT_ENABLE_MAP_TT"],
        false, 222)
    mapEnableCheckbox:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_LEFT, -6)
    mapEnableCheckbox:SetChecked(EasyFind.db.enableMapSearch ~= false)

    local mapControls = {}
    local function UpdateMapToggleVisual()
        local enabled = EasyFind.db.enableMapSearch ~= false
        mapEnableCheckbox:SetChecked(enabled)
        SetControlsEnabled(mapControls, enabled)
        if optionsFrame.UpdateRecentCountEnabled then optionsFrame.UpdateRecentCountEnabled() end
    end
    optionsFrame.UpdateMapToggleVisual = UpdateMapToggleVisual

    mapEnableCheckbox:SetScript("OnClick", function(self)
        if self:GetChecked() then
            EasyFind.db.enableMapSearch = true
            UpdateMapToggleVisual()
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        else
            StaticPopup_Show("EASYFIND_DISABLE_MAP_SEARCH")
            self:SetChecked(true)
        end
    end)

    local mapSep = sec2:CreateTexture(nil, "ARTWORK")
    mapSep:SetPoint("TOPLEFT", sec2, "TOPLEFT", 6, -40)
    mapSep:SetPoint("RIGHT", sec2, "RIGHT", -6, 0)
    mapSep:SetHeight(1)
    mapSep:SetColorTexture(0.8, 0.65, 0.0, 0.6)

    local GROUP_W = FRAME_W - 16
    local ROW_H = 28

    local mapTabLabel = sec2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapTabLabel:SetPoint("TOPLEFT", sec2, "TOPLEFT", 8, -48)
    mapTabLabel:SetText(L["OPT_MAP_TAB_SECTION"])
    mapTabLabel:SetTextColor(Utils.RGB(SECTION_TITLE_TEXT, 1))

    local mapTabSettings = CreateSettingsGroup(sec2, GROUP_W, ROW_H * 2 + 8)
    mapTabSettings:SetPoint("TOPLEFT", mapTabLabel, "BOTTOMLEFT", 0, -3)
    optionsFrame.mapTabSettings = mapTabSettings

    local mapTabShowRecentCheckbox = CreateCheckbox(mapTabSettings, "MapTabShowRecent", L["OPT_SHOW_RECENT_SEARCHES"],
        L["OPT_SHOW_RECENT_TT"], false, GROUP_W)
    mapTabShowRecentCheckbox:SetPoint("TOPLEFT", mapTabSettings, "TOPLEFT", 0, -4)
    mapTabShowRecentCheckbox:SetChecked(EasyFind.db.mapTabShowRecent ~= false)
    optionsFrame.mapTabShowRecentCheckbox = mapTabShowRecentCheckbox

    local recentCountStepper = CreateStepperRow(mapTabSettings, L["OPT_RECENT_COUNT"], 1, 10,
        function() return EasyFind.db.mapTabRecentCount or 3 end,
        function(value)
            EasyFind.db.mapTabRecentCount = value
            local list = EasyFind.db.mapTabRecentSearches
            if list then
                while #list > value do table.remove(list) end
            end
            if ns.MapTab and ns.MapTab.RefreshIfOpen then ns.MapTab:RefreshIfOpen() end
        end,
        L["OPT_RECENT_COUNT_TT"], GROUP_W)
    recentCountStepper:SetPoint("TOPLEFT", mapTabShowRecentCheckbox, "BOTTOMLEFT", 0, 0)
    optionsFrame.recentCountStepper = recentCountStepper

    local function UpdateRecentCountEnabled()
        recentCountStepper:SetGroupEnabled(EasyFind.db.enableMapSearch ~= false and EasyFind.db.mapTabShowRecent ~= false)
    end
    optionsFrame.UpdateRecentCountEnabled = UpdateRecentCountEnabled
    mapTabShowRecentCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.mapTabShowRecent = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        UpdateRecentCountEnabled()
        RunSoon(function()
            if ns.MapTab and ns.MapTab.RefreshIfOpen then ns.MapTab:RefreshIfOpen() end
        end)
    end)
    UpdateRecentCountEnabled()

    mapTabSettings:AddControl(mapTabShowRecentCheckbox)
    mapTabSettings:AddControl(recentCountStepper)

    local mapIconsLabel = sec2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapIconsLabel:SetPoint("TOPLEFT", mapTabSettings, "BOTTOMLEFT", 0, -6)
    mapIconsLabel:SetText(L["OPT_EF_MAP_ICONS_SECTION"])
    mapIconsLabel:SetTextColor(Utils.RGB(SECTION_TITLE_TEXT, 1))

    local mapIconSettings = CreateSettingsGroup(sec2, GROUP_W, ROW_H * 3 + 8)
    mapIconSettings:SetPoint("TOPLEFT", mapIconsLabel, "BOTTOMLEFT", 0, -3)
    optionsFrame.mapIconSettings = mapIconSettings

    local mapPinHighlightCheckbox = CreateCheckbox(mapIconSettings, "MapPinHighlight", L["OPT_HIGHLIGHT_BOX"],
        L["OPT_HIGHLIGHT_BOX_TT"], false, GROUP_W)
    mapPinHighlightCheckbox:SetPoint("TOPLEFT", mapIconSettings, "TOPLEFT", 0, -4)
    mapPinHighlightCheckbox:SetChecked(EasyFind.db.mapPinHighlight ~= false)
    mapPinHighlightCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.mapPinHighlight = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        RunSoon(function()
            if ns.MapSearch and ns.MapSearch.UpdatePinHighlight then ns.MapSearch:UpdatePinHighlight() end
        end)
    end)
    optionsFrame.mapPinHighlightCheckbox = mapPinHighlightCheckbox

    local blinkingPinsCheckbox = CreateCheckbox(mapIconSettings, "BlinkingPins", L["OPT_BLINKING"],
        L["OPT_BLINKING_TT"], false, GROUP_W)
    blinkingPinsCheckbox:SetPoint("TOPLEFT", mapPinHighlightCheckbox, "BOTTOMLEFT", 0, 0)
    blinkingPinsCheckbox:SetChecked(EasyFind.db.blinkingPins or false)
    blinkingPinsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.blinkingPins = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        RunSoon(function()
            if ns.MapSearch and ns.MapSearch.UpdateBlinkingPins then ns.MapSearch:UpdateBlinkingPins() end
        end)
    end)
    optionsFrame.blinkingPinsCheckbox = blinkingPinsCheckbox

    local iconSizeChoices = {
        { label = L["OPT_FONT_SMALL"], value = 0.65 },
        { label = L["OPT_FONT_MED"],   value = 0.80 },
        { label = L["OPT_FONT_LARGE"], value = 1.05 },
        { label = L["OPT_FONT_XL"],    value = 1.30 },
    }
    local mapIconPresetRow = CreatePresetRow(mapIconSettings, L["OPT_ICON_SIZE"], iconSizeChoices,
        function() return EasyFind.db.iconScale or 0.8 end,
        function(value)
            EasyFind.db.iconScale = value
            if ns.MapSearch and ns.MapSearch.UpdateIconScales then
                ns.MapSearch:UpdateIconScales()
            end
            local uiInd = _G["EasyFindIndicatorFrame"]
            if uiInd then
                uiInd:SetScale(EasyFind.db.iconScale or 0.8)
            end
        end,
        L["OPT_ICON_SIZE_TT"], GROUP_W)
    mapIconPresetRow:SetPoint("TOPLEFT", blinkingPinsCheckbox, "BOTTOMLEFT", 0, 0)
    optionsFrame.mapIconPresetRow = mapIconPresetRow

    mapIconSettings:AddControl(mapPinHighlightCheckbox)
    mapIconSettings:AddControl(blinkingPinsCheckbox)
    mapIconSettings:AddControl(mapIconPresetRow)

    local mapPinsLabel = sec2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapPinsLabel:SetPoint("TOPLEFT", mapIconSettings, "BOTTOMLEFT", 0, -6)
    mapPinsLabel:SetText(L["OPT_MAP_PINS_SECTION"])
    mapPinsLabel:SetTextColor(Utils.RGB(SECTION_TITLE_TEXT, 1))

    local mapPinSettings = CreateSettingsGroup(sec2, GROUP_W, ROW_H * 3 + 8)
    mapPinSettings:SetPoint("TOPLEFT", mapPinsLabel, "BOTTOMLEFT", 0, -3)
    optionsFrame.mapPinSettings = mapPinSettings

    local rareTrackCheckbox = CreateCheckbox(mapPinSettings, "RareTrack", L["OPT_AUTO_TRACK_RARES"],
        L["OPT_AUTO_TRACK_RARES_TT"], false, GROUP_W)
    rareTrackCheckbox:SetPoint("TOPLEFT", mapPinSettings, "TOPLEFT", 0, -4)
    rareTrackCheckbox:SetChecked(EasyFind.db.alwaysShowRares or false)
    rareTrackCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.alwaysShowRares = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        RunSoon(function()
            if ns.MapSearch then
                ns.MapSearch:UpdateRareTracking()
                if ns.MapSearch.UpdateAutoTrackLabel then
                    ns.MapSearch:UpdateAutoTrackLabel()
                end
            end
        end)
    end)
    optionsFrame.rareTrackCheckbox = rareTrackCheckbox

    local autoTrackPinsCheckbox = CreateCheckbox(mapPinSettings, "AutoTrackPins", L["OPT_AUTO_TRACK_MAP_PINS"],
        L["OPT_AUTO_TRACK_PINS_TT"], false, GROUP_W)
    autoTrackPinsCheckbox:SetPoint("TOPLEFT", rareTrackCheckbox, "BOTTOMLEFT", 0, 0)
    autoTrackPinsCheckbox:SetChecked(EasyFind.db.autoTrackPins ~= false)
    autoTrackPinsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.autoTrackPins = self:GetChecked()
    end)
    optionsFrame.autoTrackPinsCheckbox = autoTrackPinsCheckbox

    local autoPinClearCheckbox = CreateCheckbox(mapPinSettings, "AutoPinClear", L["OPT_AUTO_CLEAR_MAP_PINS"],
        L["OPT_AUTO_PIN_CLEAR_TT"], false, GROUP_W)
    autoPinClearCheckbox:SetPoint("TOPLEFT", autoTrackPinsCheckbox, "BOTTOMLEFT", 0, 0)
    autoPinClearCheckbox:SetChecked(EasyFind.db.autoPinClear ~= false)
    autoPinClearCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.autoPinClear = self:GetChecked()
    end)
    optionsFrame.autoPinClearCheckbox = autoPinClearCheckbox

    mapPinSettings:AddControl(rareTrackCheckbox)
    mapPinSettings:AddControl(autoTrackPinsCheckbox)
    mapPinSettings:AddControl(autoPinClearCheckbox)

    local resetMapBtn = CreateModernButton(sec2)
    resetMapBtn:SetSize(RESET_BTN_W, 20)
    resetMapBtn:SetPoint("TOPRIGHT", sec2, "TOPRIGHT", -8, -8)
    resetMapBtn:SetText(L["OPT_RESET_SETTINGS"])
    resetMapBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_MAP")
    end)

    mapControls = {
        resetMapBtn, mapTabSettings, mapIconSettings, mapPinSettings
    }
    UpdateMapToggleVisual()

    local sec4 = CreateTab(L["OPT_TAB_SHORTCUTS"])

    local shortcutText = sec4:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shortcutText:SetPoint("TOPLEFT", sec4, "TOPLEFT", 8, -8)
    shortcutText:SetWidth(FRAME_W - 60)
    shortcutText:SetJustifyH("LEFT")
    shortcutText:SetSpacing(2)
    shortcutText:SetText(L["OPT_SHORTCUTS_TEXT"])

    local aliasesTab = CreateTab(L["OPT_TAB_ALIASES"])

    local aliasTitle = aliasesTab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    aliasTitle:SetPoint("TOPLEFT", aliasesTab, "TOPLEFT", 8, -8)
    aliasTitle:SetText(L["OPT_SAVED_ALIASES"])

    local aliasHeader = aliasesTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    aliasHeader:SetPoint("TOPLEFT", aliasTitle, "BOTTOMLEFT", 0, -6)
    aliasHeader:SetPoint("RIGHT", aliasesTab, "RIGHT", -10, 0)
    aliasHeader:SetJustifyH("LEFT")
    aliasHeader:SetText(L["OPT_ALIASES_EMPTY_HINT"])

    local RefreshAliasList
    local aliasTools = CreateFrame("Frame", nil, aliasesTab)
    aliasTools:SetPoint("TOPLEFT", aliasHeader, "BOTTOMLEFT", 0, -8)
    aliasTools:SetPoint("RIGHT", aliasesTab, "RIGHT", -8, 0)
    aliasTools:SetHeight(24)

    local clearAliasesBtn = CreateModernButton(aliasTools, L["OPT_CLEAR_ALL_BTN"], 78, 22)
    clearAliasesBtn:SetPoint("RIGHT", aliasTools, "RIGHT", 0, 0)

    local aliasSearchShell = CreateFrame("Frame", nil, aliasTools)
    aliasSearchShell:SetPoint("LEFT", aliasTools, "LEFT", 0, 0)
    aliasSearchShell:SetPoint("RIGHT", clearAliasesBtn, "LEFT", -8, 0)
    aliasSearchShell:SetHeight(22)
    ns.CreateRoundedRectBorder(aliasSearchShell)
    ns.SetRoundedRectBarHeight(aliasSearchShell, 10)
    HideRoundedFrameBorder(aliasSearchShell)
    PaintRoundedFill(aliasSearchShell, 0.075, 0.075, 0.085, 1)

    local aliasSearchIcon = aliasSearchShell:CreateTexture(nil, "OVERLAY")
    aliasSearchIcon:SetSize(13, 13)
    aliasSearchIcon:SetPoint("LEFT", aliasSearchShell, "LEFT", 7, 0)
    aliasSearchIcon:SetAtlas("common-search-magnifyingglass")
    aliasSearchIcon:SetAlpha(0.65)

    local aliasSearchBox = CreateFrame("EditBox", nil, aliasSearchShell)
    aliasSearchBox:SetPoint("LEFT", aliasSearchIcon, "RIGHT", 6, 0)
    aliasSearchBox:SetPoint("RIGHT", aliasSearchShell, "RIGHT", -8, 0)
    aliasSearchBox:SetHeight(18)
    aliasSearchBox:SetAutoFocus(false)
    aliasSearchBox:SetFontObject(SMALL_HIGHLIGHT_FONT)
    aliasSearchBox:SetMaxLetters(64)

    local aliasSearchPlaceholder = aliasSearchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    aliasSearchPlaceholder:SetPoint("LEFT", aliasSearchBox, "LEFT", 0, 0)
    aliasSearchPlaceholder:SetText(L["OPT_SEARCH_ALIASES_PLACEHOLDER"])
    aliasSearchPlaceholder:SetTextColor(0.55, 0.55, 0.58, 1)
    aliasSearchBox.placeholder = aliasSearchPlaceholder
    aliasSearchBox:SetScript("OnTextChanged", function(self)
        aliasSearchPlaceholder:SetShown((self:GetText() or "") == "")
        if RefreshAliasList then RefreshAliasList() end
    end)
    aliasSearchBox:SetScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then
            self:SetText("")
        else
            self:ClearFocus()
        end
    end)

    local aliasList = CreateFrame("Frame", nil, aliasesTab)
    aliasList:SetPoint("TOPLEFT", aliasTools, "BOTTOMLEFT", 0, -8)
    aliasList:SetPoint("BOTTOMRIGHT", aliasesTab, "BOTTOMRIGHT", -8, 8)
    ns.CreateRoundedRectBorder(aliasList)
    ns.SetRoundedRectBarHeight(aliasList, 8)
    HideRoundedFrameBorder(aliasList)
    PaintRoundedFill(aliasList, 0.075, 0.075, 0.085, 0.92)

    local aliasScroll = CreateFrame("ScrollFrame", nil, aliasList)
    aliasScroll:SetPoint("TOPLEFT", aliasList, "TOPLEFT", 6, -6)
    aliasScroll:SetPoint("BOTTOMRIGHT", aliasList, "BOTTOMRIGHT", -10, 6)

    local aliasContent = CreateFrame("Frame", nil, aliasScroll)
    aliasContent:SetSize(FRAME_W - 42, 1)
    aliasScroll:SetScrollChild(aliasContent)

    local aliasScrollBar = ns.Utils and ns.Utils.CreateMinimalScrollBar and ns.Utils.CreateMinimalScrollBar(aliasScroll, aliasList)
    local aliasEmpty = aliasContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    aliasEmpty:SetPoint("TOPLEFT", aliasContent, "TOPLEFT", 8, -8)
    aliasEmpty:SetText(L["OPT_NO_SAVED_ALIASES"])

    local aliasRowPool = {}
    local function ReleaseAliasRows()
        for i = 1, #aliasRowPool do aliasRowPool[i]:Hide() end
    end
    local function UpdateAliasScrollBar()
        if not aliasScrollBar then return end
        local contentH = aliasContent:GetHeight() or 0
        local viewH = aliasScroll:GetHeight() or 0
        if contentH > viewH + 1 then
            aliasScrollBar:Show()
            aliasScrollBar:UpdateThumb(contentH, viewH)
        else
            aliasScroll:SetVerticalScroll(0)
            aliasScrollBar:Hide()
        end
    end
    local function AcquireAliasRow(idx)
        local row = aliasRowPool[idx]
        if row then row:Show(); return row end
        row = CreateFrame("Frame", nil, aliasContent)
        row:SetSize(FRAME_W - 42, 26)
        row:EnableMouse(true)
        row.bg = CreateFrame("Frame", nil, row)
        row.bg:SetAllPoints()
        row.bg:EnableMouse(false)
        ns.CreateRoundedRectBorder(row.bg)
        ns.SetRoundedRectBarHeight(row.bg, 8)
        HideRoundedFrameBorder(row.bg)
        PaintRoundedFill(row.bg, 1, 1, 1, 0)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.text:SetJustifyH("LEFT")
        row.removeBtn = CreateModernButton(row, "x", 20, 18)
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.text:SetPoint("RIGHT", row.removeBtn, "LEFT", -8, 0)
        row:SetScript("OnEnter", function(self)
            PaintRoundedFill(self.bg, 1, 1, 1, 0.055)
        end)
        row:SetScript("OnLeave", function(self)
            PaintRoundedFill(self.bg, 1, 1, 1, 0)
        end)
        aliasRowPool[idx] = row
        return row
    end

    RefreshAliasList = function()
        ReleaseAliasRows()
        if not ns.Aliases then
            clearAliasesBtn:Disable()
            aliasEmpty:SetText(L["OPT_NO_SAVED_ALIASES"])
            aliasEmpty:Show()
            return
        end
        local query = aliasSearchBox and aliasSearchBox:GetText() or ""
        query = query:lower()
        local entries = {}
        local total = 0
        ns.Aliases:ForEach(function(text, info)
            total = total + 1
            local aliasText = info.text or text or ""
            local targetName = info.name or ""
            local haystack = (aliasText .. " " .. targetName):lower()
            if query == "" or string.find(haystack, query, 1, true) then
                entries[#entries + 1] = info
            end
        end)
        table.sort(entries, function(a, b) return (a.text or ""):lower() < (b.text or ""):lower() end)
        clearAliasesBtn:SetEnabled(total > 0)
        clearAliasesBtn:SetAlpha(total > 0 and 1 or 0.45)
        aliasEmpty:SetText(total == 0 and "No saved aliases." or "No aliases match.")
        aliasEmpty:SetShown(#entries == 0)
        local rowH = 28
        local y = -4
        for i, info in ipairs(entries) do
            local row = AcquireAliasRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", aliasContent, "TOPLEFT", 4, y)
            row.text:SetText(("|cFFFFD100%s|r  -> %s"):format(info.text or "?", info.name or "?"))
            row.removeBtn:SetScript("OnClick", function()
                if ns.Aliases then ns.Aliases:Remove(info.text) end
                RefreshAliasList()
            end)
            y = y - rowH
        end
        aliasContent:SetHeight(math.max(32, -y + 4))
        UpdateAliasScrollBar()
        Utils.SafeAfter(0, UpdateAliasScrollBar)
    end
    aliasScroll:SetScript("OnSizeChanged", UpdateAliasScrollBar)
    aliasContent:HookScript("OnSizeChanged", UpdateAliasScrollBar)
    aliasesTab:HookScript("OnShow", RefreshAliasList)
    optionsFrame.RefreshAliasList = RefreshAliasList

    StaticPopupDialogs["EASYFIND_CLEAR_ALIASES"] = {
        text = L["POPUP_CLEAR_ALIASES"],
        button1 = _G["CLEAR"] or "Clear",
        button2 = CANCEL or "Cancel",
        OnAccept = function()
            if ns.Aliases then ns.Aliases:ClearAll() end
            RefreshAliasList()
        end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    clearAliasesBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_CLEAR_ALIASES")
    end)

    StaticPopupDialogs["EASYFIND_RESET_ALL"] = {
        text = L["POPUP_RESET_ALL_SETTINGS"],
        button1 = _G["RESET"] or "Reset",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function() Options:DoResetAll() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_POSITIONS"] = {
        text = L["POPUP_RESET_ALL_POSITIONS"],
        button1 = _G["RESET"] or "Reset",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function() Options:DoResetPositions() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_DISABLE_MAP_SEARCH"] = {
        text = L["POPUP_DISABLE_MAP_SEARCH"] .. "\n\nThis will remove map search, pins, map overlay features, and the EasyFind tab on the world map. You can re-enable it later from options.",
        button1 = _G["DISABLE"] or "Disable",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function()
            EasyFind.db.enableMapSearch = false
            UpdateMapToggleVisual()
            if ns.MapSearch then
                pcall(ns.MapSearch.ClearAll, ns.MapSearch)
                pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch)
            end
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RELOAD_PROMPT"] = {
        text = L["POPUP_RELOAD_UI"],
        button1 = _G["RELOADUI"] or "Reload Now",
        button2 = "Later",
        OnAccept = function() ReloadUI() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_UI"] = {
        text = L["POPUP_RESET_UI_SEARCH_SETTINGS"],
        button1 = _G["RESET"] or "Reset",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function() Options:DoResetUI() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_MAP"] = {
        text = L["POPUP_RESET_MAP_SEARCH_SETTINGS"],
        button1 = _G["RESET"] or "Reset",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function() Options:DoResetMap() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_UI_POS"] = {
        text = L["POPUP_RESET_UI_SEARCH_POSITIONS"],
        button1 = _G["RESET"] or "Reset",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function() Options:DoResetUIPositions() end,
        OnShow = LiftPopupAboveOptions,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    local resetAllBtn = CreateModernButton(sec3)
    resetAllBtn:SetSize(RESET_BTN_W, 20)
    resetAllBtn:SetPoint("BOTTOMLEFT", sec3, "BOTTOMLEFT", 16, 8)
    resetAllBtn:SetText(L["OPT_RESET_ALL_SETTINGS"])
    resetAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_ALL")
    end)
    resetAllBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["OPT_RESET_ALL_SETTINGS"])
        GameTooltip:AddLine(L["OPT_RESET_ALL_TT_DESC"], 1, 1, 1, true)
        GameTooltip:AddLine(L["OPT_RESET_ALL_TT_CMD"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resetAllBtn:HookScript("OnLeave", GameTooltip_Hide)

    local resetPosBtn = CreateModernButton(sec3)
    resetPosBtn:SetSize(RESET_BTN_W, 20)
    resetPosBtn:SetPoint("LEFT", resetAllBtn, "RIGHT", 8, 0)
    resetPosBtn:SetText(L["OPT_RESET_ALL_POSITIONS"])
    resetPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_POSITIONS")
    end)

    local feedbackTab = CreateTab(L["OPT_TAB_FEEDBACK"])

    local feedbackDesc = feedbackTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    feedbackDesc:SetPoint("TOPLEFT", feedbackTab, "TOPLEFT", 12, -16)
    feedbackDesc:SetPoint("RIGHT", feedbackTab, "RIGHT", -12, 0)
    feedbackDesc:SetJustifyH("LEFT")
    feedbackDesc:SetSpacing(3)
    feedbackDesc:SetText(L["OPT_FEEDBACK_DESC"])

    local bugBtn = CreateModernButton(feedbackTab)
    bugBtn:SetSize(RESET_BTN_W, 20)
    bugBtn:SetPoint("TOPLEFT", feedbackDesc, "BOTTOMLEFT", 0, -12)
    bugBtn:SetText(L["OPT_REPORT_BUG"])
    bugBtn:SetScript("OnClick", function()
        EasyFind:OpenBugReport()
    end)
    bugBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["OPT_REPORT_BUG"])
        GameTooltip:AddLine(L["OPT_REPORT_BUG_TT_DESC"], 1, 1, 1, true)
        GameTooltip:AddLine(L["OPT_REPORT_BUG_TT_CMD"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    bugBtn:HookScript("OnLeave", GameTooltip_Hide)

    local featureBtn = CreateModernButton(feedbackTab)
    featureBtn:SetSize(RESET_BTN_W, 20)
    featureBtn:SetPoint("LEFT", bugBtn, "RIGHT", 12, 0)
    featureBtn:SetText(L["OPT_REQUEST_FEATURE"])
    featureBtn:SetScript("OnClick", function()
        EasyFind:OpenFeatureRequest()
    end)
    featureBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["OPT_REQUEST_FEATURE"])
        GameTooltip:AddLine(L["OPT_REQUEST_FEATURE_TT_DESC"], 1, 1, 1, true)
        GameTooltip:AddLine(L["OPT_REQUEST_FEATURE_TT_CMD"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    featureBtn:HookScript("OnLeave", GameTooltip_Hide)

    SwitchToTab(1)

    optionsFrame:Hide()

    isInitialized = true
    self:RegisterWithBlizzardOptions()
end

function Options:DoResetPositions()
    EasyFind.db.uiSearchPosition = nil
    if ns.Search and ns.Search.ResetPosition then ns.Search:ResetPosition() end
    ResetOptionsPosition()
end

function Options:DoResetAll()
    local needsReload = EasyFind.db.enableMapSearch == false
    ApplyDefaults(UI_DEFAULTS)
    ApplyDefaults(MAP_DEFAULTS)
    ApplyDefaults(GENERAL_DEFAULTS)
    ResetOptionsPosition()
    ClearMapRuntime()

    SyncOptionControls()
    if ns.RefreshAddonFont then ns.RefreshAddonFont() end
    RefreshUIRuntime(true)
    RefreshMapRuntime()
    EasyFind:UpdateMinimapButton()

    if needsReload then
        StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
    end
end

function Options:DoResetUI()
    ApplyDefaults(UI_DEFAULTS)
    SyncOptionControls()
    RefreshUIRuntime(true)
end

function Options:DoResetMap()
    ApplyDefaults(MAP_DEFAULTS)
    SyncOptionControls()
    RefreshMapRuntime()
end

function Options:DoResetUIPositions()
    ApplyDefaults(UI_POSITION_DEFAULTS)
    SyncOptionControls()
    RefreshUIRuntime(true)
end

function Options:RegisterWithBlizzardOptions()
    if blizzardRegistered then return end
    blizzardRegistered = true

    local panel = CreateFrame("Frame")
    panel.name = "EasyFind"

    panel:SetScript("OnShow", function(self)
        if not isInitialized then Options:Initialize() end
        Options.embedded = true
        Options.embedding = true

        optionsFrame.titleText:Hide()
        optionsFrame.closeBtn:Hide()
        optionsFrame.bgTex:Hide()
        optionsFrame:SetBackdrop(nil)
        optionsFrame:SetScale(1)

        optionsFrame:SetParent(self)
        optionsFrame:ClearAllPoints()
        optionsFrame:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 34)
        optionsFrame:SetFrameStrata("HIGH")
        optionsFrame:SetMovable(false)
        optionsFrame:RegisterForDrag()

        Options:Show()
        Options.embedding = false
    end)

    panel:SetScript("OnHide", function()
        if not Options.embedded then return end
        Options:RestoreStandalone()
        optionsFrame:Hide()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    else
        InterfaceOptions_AddCategory(panel)
    end

    local settingsRoot = SettingsPanel or InterfaceOptionsFrame
    if settingsRoot then
        local restoreOnClose = false
        settingsRoot:HookScript("OnShow", function()
            local sf = _G["EasyFindSearchFrame"]
            restoreOnClose = sf and sf:IsShown() or false
            if sf then sf:Hide() end
            if ns.Search and ns.Search.HideResults then ns.Search:HideResults() end
        end)
        settingsRoot:HookScript("OnHide", function()
            if restoreOnClose then
                restoreOnClose = false
                local sf = _G["EasyFindSearchFrame"]
                if sf then sf:Show() end
            end
        end)
    end
end

function Options:Show()
    if not isInitialized then
        self:Initialize()
    end

    if self.embedded and not self.embedding then
        self:RestoreStandalone()
    end

    SyncOptionControls()

    if not self.embedded and optionsFrame.bgTex then
        optionsFrame.bgTex:SetAlpha(OPTIONS_PANEL_ALPHA)
        optionsFrame:SetFrameStrata(OPTIONS_FRAME_STRATA)
        optionsFrame:SetFrameLevel(OPTIONS_FRAME_LEVEL)
    end
    optionsFrame:Show()
    optionsFrame:Raise()
end

function Options:RestoreStandalone()
    self.embedded = false

    optionsFrame.titleText:Show()
    optionsFrame.closeBtn:Show()
    optionsFrame.bgTex:Show()
    optionsFrame.bgTex:SetAlpha(OPTIONS_PANEL_ALPHA)
    optionsFrame:SetBackdrop(nil)
    optionsFrame:SetScale(OPTIONS_PANEL_SCALE)

    optionsFrame:SetParent(UIParent)
    optionsFrame:SetFrameStrata(OPTIONS_FRAME_STRATA)
    optionsFrame:SetFrameLevel(OPTIONS_FRAME_LEVEL)
    optionsFrame:SetMovable(true)
    optionsFrame:RegisterForDrag("LeftButton")

    optionsFrame:ClearAllPoints()
    if EasyFind.db.optionsPosition then
        local pos = EasyFind.db.optionsPosition
        optionsFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function Options:Hide()
    if optionsFrame then
        optionsFrame:Hide()
    end
end

function Options:Toggle()
    if not isInitialized then
        self:Initialize()
    end

    if self.embedded then
        self:RestoreStandalone()
        self:Show()
        return
    end

    if optionsFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
