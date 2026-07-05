local _, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local L       = ns.L
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tostring = Utils.tostring
local tinsert = Utils.tinsert
local IsMouseButtonDown = IsMouseButtonDown

local SMALL_HIGHLIGHT_FONT = _G["GameFontHighlightSmall"] or _G["GameFontNormalSmall"] or _G["GameFontNormal"]

-- Themed confirm dialog for the reset buttons (replaces the Blizzard
-- StaticPopup style). Reset is the accept verb; Cancel is implicit.
local function ShowResetConfirm(text, onAccept)
    ns.ShowThemedDialog({ text = text, acceptText = _G["RESET"] or "Reset", onAccept = onAccept })
end

-- Indicator style and color are stored in the DB as stable English keys
-- (locale-independent). These map a stored key to its localized display
-- label so the picker shows translated text without changing the value.
local STYLE_LABEL_KEY = {
    ["EasyFind Arrow"]      = "OPT_INDICATOR_STYLE_EASYFIND",
    ["Classic Quest Arrow"] = "OPT_INDICATOR_STYLE_CLASSIC",
    ["Minimap Player Arrow"] = "OPT_INDICATOR_STYLE_MINIMAP",
    ["Low-res Gauntlet"]    = "OPT_INDICATOR_STYLE_LOWRES",
    ["HD Gauntlet"]         = "OPT_INDICATOR_STYLE_HD",
}
local COLOR_LABEL_KEY = {
    Yellow = "OPT_COLOR_YELLOW", Gold = "OPT_COLOR_GOLD", Orange = "OPT_COLOR_ORANGE",
    Red = "OPT_COLOR_RED", Green = "OPT_COLOR_GREEN", Blue = "OPT_COLOR_BLUE",
    Purple = "OPT_COLOR_PURPLE", White = "OPT_COLOR_WHITE",
}
local function StyleLabel(value)
    local key = value and STYLE_LABEL_KEY[value]
    return (key and L[key]) or value
end
local function ColorLabel(value)
    local key = value and COLOR_LABEL_KEY[value]
    return (key and L[key]) or value
end

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
local UI_DEFAULTS = {
    smartShow = false,
    autoHide = true,
    lockPosition = false,
    uiResultsAbove = false,
    showResultShortcutHints = true,
    fontSize = ns.DEFAULT_FONT_SIZE,
    searchWindowOpacity = ns.SEARCH_WINDOW_ALPHA,
    uiSearchScale = 1.0,
    uiSearchWidth = 1.54,
    uiSearchBarHeight = ns.SEARCHBAR_HEIGHT,
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
    uiSearchPosition = NIL,
    uiResultsHeight = 280,
    uiResultsRows = 6,
    wowheadLocale = "auto",
    uiSearchFilters = DEFAULT_UI_FILTERS,
    uiMapFilters = {
        zones = true,
        instances = true,
        flightpath = false,
        travel = true,
        services = true,
        rares = true,
    },
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

-- Restored from ns.DB_DEFAULTS so the reset can never drift from the
-- first-run defaults (a duplicated copy here once re-enabled auto-track).
local MAP_RESET_KEYS = {
    "iconScale", "mapPinHighlight", "blinkingPins", "autoPinClear",
    "autoTrackPins", "globalSearchFilters", "localSearchFilters",
    "mapTabFilters", "alwaysShowRares", "mapTabShowRecent",
    "mapTabAutoExpand", "mapTabRecentCount",
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

local function ApplyDefaultKeys(keys)
    for i = 1, #keys do
        local key = keys[i]
        local value = ns.DB_DEFAULTS[key]
        if type(value) == "table" then
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
    if ns.Search.UpdateSmartShow then ns.Search:UpdateSmartShow(false) end
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

    if optionsFrame.uiFontPresetRow then optionsFrame.uiFontPresetRow:SetValue(EasyFind.db.fontSize or ns.DEFAULT_FONT_SIZE) end
    if optionsFrame.searchScaleRow then optionsFrame.searchScaleRow:SetValue(EasyFind.db.uiSearchScale or 1.0) end
    if optionsFrame.resultRowsRow then optionsFrame.resultRowsRow:SetValue(EasyFind.db.uiResultsRows or 6) end
    if optionsFrame.SetWowheadSelection then optionsFrame.SetWowheadSelection(EasyFind.db.wowheadLocale or "auto") end
    if optionsFrame.searchOpacityRow then optionsFrame.searchOpacityRow:SetValue(EasyFind.db.searchWindowOpacity or ns.SEARCH_WINDOW_ALPHA) end
    if optionsFrame.mapIconPresetRow then optionsFrame.mapIconPresetRow:SetValue(EasyFind.db.iconScale or 0.8) end
    if optionsFrame.recentCountStepper then optionsFrame.recentCountStepper:SetValue(EasyFind.db.mapTabRecentCount or 3) end

    if optionsFrame.visibilityModeRow then optionsFrame.visibilityModeRow:SetValue(GetVisibilityModeValue()) end
    if optionsFrame.lockPositionCheckbox then optionsFrame.lockPositionCheckbox:SetChecked(EasyFind.db.lockPosition or false) end
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

    if optionsFrame.RetintIndicatorPreviews then optionsFrame.RetintIndicatorPreviews() end
    if optionsFrame.fontBtnText then optionsFrame.fontBtnText:SetText(EasyFind.db.font or (_G["DEFAULT"] or "Default")) end

    local clr = EasyFind.db.indicatorColor or "Yellow"
    local rgb = ns.INDICATOR_COLORS[clr] or ns.INDICATOR_COLORS.Yellow
    if optionsFrame.colorBtnText then
        optionsFrame.colorBtnText:SetText(ColorLabel(clr))
        optionsFrame.colorBtnText:SetTextColor(Utils.RGB(rgb))
    end
    -- Account keybind store only: a stale native binding saved by an old
    -- version must never shadow what the player actually set here.
    if optionsFrame.toggleFocusBtn then optionsFrame.toggleFocusBtn:SetText(EasyFind:GetAccountKeybind("EASYFIND_TOGGLE_FOCUS") or (_G["NOT_BOUND"] or "Not Bound")) end
    if optionsFrame.mapFocusBtn then optionsFrame.mapFocusBtn:SetText(EasyFind:GetAccountKeybind("EASYFIND_MAP_FOCUS") or (_G["NOT_BOUND"] or "Not Bound")) end
    if optionsFrame.clearBtn then optionsFrame.clearBtn:SetText(EasyFind:GetAccountKeybind("EASYFIND_CLEAR") or (_G["NOT_BOUND"] or "Not Bound")) end
end

local PaintRoundedFill = ns.SetRoundedRectFill
-- One fill for the panel's table/section backdrops (alias+shortkey table,
-- keybinding and map setting groups) so they read as a single surface.
local SECTION_TABLE_FILL = {0.075, 0.075, 0.085, 0.92}
local function HideRoundedBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
end
local HideRoundedFrameBorder = HideRoundedBorder

local function PaintControlFill(frame, color, alpha)
    PaintRoundedFill(frame, color[1], color[2], color[3], alpha or 1, true)
end

local function StyleSelectorButton(btnFrame, height)
    btnFrame:SetBackdrop(nil)
    ns.CreateRoundedRectBorder(btnFrame)
    ns.SetRoundedRectBarHeight(btnFrame, mmin(height or 22, 10))
    HideRoundedFrameBorder(btnFrame)
    PaintControlFill(btnFrame, ns.BTN_FILL_NORMAL, 1)
    btnFrame:HookScript("OnEnter", function(self)
        if self:IsEnabled() then PaintControlFill(self, ns.BTN_FILL_HOVER, 1) end
    end)
    btnFrame:HookScript("OnLeave", function(self)
        if self:IsEnabled() then PaintControlFill(self, ns.BTN_FILL_NORMAL, 1) end
    end)
    btnFrame:HookScript("OnMouseDown", function(self)
        if self:IsEnabled() then PaintControlFill(self, ns.BTN_FILL_PRESSED, 1) end
    end)
    btnFrame:HookScript("OnMouseUp", function(self)
        if self:IsEnabled() then
            PaintControlFill(self, self:IsMouseOver() and ns.BTN_FILL_HOVER or ns.BTN_FILL_NORMAL, 1)
        end
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

-- Every selector flyout registers here; opening one closes the rest so
-- two can never overlap on screen.
local optionsFlyouts = {}

local function CreateFlyoutPanel(btnFrame, globalPrefix, width, numChoices)
    local flyout = CreateFrame("Frame", globalPrefix .. "Flyout", btnFrame, "BackdropTemplate")
    optionsFlyouts[#optionsFlyouts + 1] = flyout
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
        if opening then
            for i = 1, #optionsFlyouts do
                if optionsFlyouts[i] ~= flyout then optionsFlyouts[i]:Hide() end
            end
        end
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

-- Every choice flyout tags its default option. Physical key tokens
-- aside, the tag itself is Blizzard-localized for free.
local function DefaultTag(label)
    return label .. " (" .. (_G["DEFAULT"] or "Default") .. ")"
end

local function AddFlyoutOptions(flyout, choices, itemWidth, onSelect, labelFn, styleFn)
    local rows = {}
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
        label:SetText(labelFn and labelFn(name) or name)
        flyoutBtn._label = label
        if styleFn then styleFn(flyoutBtn, name, label) end
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
        rows[i] = flyoutBtn
    end
    -- Width rule: rows fit their widest label (plus any right-side icon a
    -- styleFn added via _rightIconW); itemWidth is the minimum. Anchored
    -- labels clip silently, so measure unwrapped.
    local contentW = 0
    for i = 1, #rows do
        local label = rows[i]._label
        local getter = label.GetUnboundedStringWidth or label.GetStringWidth
        local w = 6 + getter(label) + 6 + (rows[i]._rightIconW or 0)
        if w > contentW then contentW = w end
    end
    local rowW = mmax(itemWidth, mfloor(contentW + 0.5))
    if rowW > itemWidth then
        for i = 1, #rows do rows[i]:SetWidth(rowW) end
        flyout:SetWidth(rowW + 6)
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
    local rowW = width or (compact and 220 or 330)
    checkbox:SetSize(rowW, rowH)
    checkbox:RegisterForClicks("LeftButtonUp")
    -- Only the toggle itself is interactive. A row-wide hit area made the
    -- hover tooltip fire from anywhere on the line and clicks land on what
    -- reads as inert label space.
    local toggleRightOff = compact and 4 or 8
    checkbox:SetHitRectInsets(rowW - toggleW - toggleRightOff - 8, 0, 0, 0)

    local rowBg = CreateFrame("Frame", nil, checkbox)
    rowBg:EnableMouse(false)
    ns.CreateRoundedRectBorder(rowBg)
    ns.SetRoundedRectBarHeight(rowBg, toggleH + 10)
    HideRoundedFrameBorder(rowBg)
    PaintRoundedFill(rowBg, 1, 1, 1, 0)
    checkbox.rowBg = rowBg

    local text = checkbox:CreateFontString(nil, "OVERLAY", compact and "GameFontHighlightSmall" or "GameFontNormalSmall")
    text:SetPoint("LEFT", checkbox, "LEFT", compact and 6 or 8, 0)
    text:SetJustifyH("LEFT")
    checkbox.Text = text

    local track = CreateFrame("Frame", nil, checkbox)
    track:SetSize(toggleW, toggleH)
    track:SetPoint("RIGHT", checkbox, "RIGHT", compact and -4 or -8, 0)
    track:EnableMouse(false)
    ns.CreateRoundedRectBorder(track)
    ns.SetRoundedRectBarHeight(track, toggleH)
    HideRoundedFrameBorder(track)
    checkbox.track = track

    -- The hover fill hugs the toggle, matching the interactive hit area,
    -- instead of lighting the whole row from a toggle hover.
    rowBg:SetPoint("TOPLEFT", track, "TOPLEFT", -6, 5)
    rowBg:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 6, -5)

    text:SetPoint("RIGHT", track, "LEFT", -8, 0)
    ns.MakeEllipsisLabel(text, label or "")

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
        local rowAlpha = self._efHover and enabled and 0.055 or 0
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
        self._efHover = true
        UpdateVisual(self)
    end)
    checkbox:HookScript("OnLeave", function(self)
        self._efHover = nil
        UpdateVisual(self)
    end)
    if tooltipText then
        Utils.AttachDelayedTooltip(checkbox, "ANCHOR_RIGHT", function()
            return label, tooltipText
        end)
    end
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
local NAV_SELECTED = { 0.16, 0.19, 0.25, 0.95 }
local NAV_HOVER = { 0.12, 0.14, 0.19, 0.85 }
local NAV_CLEAR = { 0, 0, 0, 0 }

local function TintRoundedFill(frame, r, g, b)
    ns.SetRoundedRectFill(frame, r, g, b, 1, true)
end

local function StyleWizardBackground(frame)
    -- Panel translucency comes from the caller's frame-level SetAlpha
    -- (OPTIONS_PANEL_ALPHA); the fill cells stay opaque.
    ns.StyleWizardPanel(frame, 1)
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
    PaintRoundedFill(group, unpack(SECTION_TABLE_FILL))
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
        SetModernButtonFill(btn, unpack(ns.BTN_FILL_DISABLED))
        if btn._label then btn._label:SetTextColor(Utils.RGB(TEXT_DIM, 1)) end
    elseif active then
        SetModernButtonFill(btn, 0.17, 0.48, 0.72)
        if btn._label then btn._label:SetTextColor(1, 1, 1, 1) end
    elseif hover then
        SetModernButtonFill(btn, unpack(ns.BTN_FILL_HOVER))
        if btn._label then btn._label:SetTextColor(1, 1, 1, 1) end
    else
        SetModernButtonFill(btn, unpack(ns.BTN_FILL_NORMAL))
        if btn._label then btn._label:SetTextColor(Utils.RGB(TEXT_BODY, 1)) end
    end
end

local function CreateSegmentedPresetRow(parent, labelText, choices, getter, setter, tooltipText, width)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 330, 30)
    row.enabled = true

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -188, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
    ns.MakeEllipsisLabel(label, labelText)
    row.label = label

    -- Sized and right-anchored to line up exactly with the flyout selector
    -- buttons (SELECTOR_BTN_W x 22 at RIGHT -8) used by the dropdown rows.
    local trackW, trackH = 170, 22
    local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
    track:SetSize(trackW, trackH)
    track:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    ns.CreateRoundedRectBorder(track)
    ns.SetRoundedRectBarHeight(track, trackH)
    PaintControlFill(track, ns.BTN_FILL_NORMAL, 0.96)
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
        text:SetPoint("LEFT", btn, "LEFT", 4, 0)
        text:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
        text:SetJustifyH("CENTER")
        ns.MakeEllipsisLabel(text, choice.label, { tooltip = false })
        btn._label = text
        btn:SetScript("OnClick", function(self)
            if not row.enabled then return end
            local value = self.choice.value
            row:SetValue(value)
            RunSoon(function() setter(value) end)
        end)
        Utils.AttachDelayedTooltip(btn, "ANCHOR_RIGHT", function(self)
            local tipBody = self.choice.tooltip or tooltipText
            if not tipBody then return nil end
            return self.choice.tooltip and self.choice.label or labelText, tipBody
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
        PaintControlFill(track, enabled and ns.BTN_FILL_NORMAL or ns.BTN_FILL_DISABLED, 0.96)
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
    ns.MakeEllipsisLabel(label, labelText)
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
        end)
        btn:SetScript("OnLeave", function(self)
            PaintPresetButton(self, row.activeValue == self.choice.value, false, row.enabled)
        end)
        if tooltipText then
            Utils.AttachDelayedTooltip(btn, "ANCHOR_RIGHT", function()
                return labelText, tooltipText
            end)
        end
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
        Utils.AttachDelayedTooltip(row, "ANCHOR_RIGHT", function()
            return labelText, tooltipText
        end)
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

-- Per-tab builders, split out of Options:Initialize: Lua caps any single
-- function at 200 local variables and the one-piece builder crossed the
-- limit. Each tab now owns its function (and local budget); the pieces
-- they share ride the ctx table built in Initialize.

local function BuildHomeTab(ctx)
    local CreateTab, SwitchToTab, FRAME_W = ctx.CreateTab, ctx.SwitchToTab, ctx.FRAME_W
    local FlashBindButton = ctx.FlashBindButton
    local homeTab = CreateTab(L["OPT_TAB_HOME"])
    local homeIcon = homeTab:CreateTexture(nil, "ARTWORK")
    homeIcon:SetSize(80, 80)
    homeIcon:SetPoint("TOPLEFT", homeTab, "TOPLEFT", 12, -8)
    homeIcon:SetTexture("Interface\\AddOns\\EasyFind\\textures\\Spyglass")

    local homeTitle = homeTab:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    local titlePath, _, titleFlags = homeTitle:GetFont()
    if titlePath then homeTitle:SetFont(titlePath, 28, titleFlags) end
    homeTitle:SetPoint("LEFT", homeIcon, "RIGHT", 14, 0)
    homeTitle:SetText(L["OPT_ADDON_NAME"])

    local homeVersion = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    homeVersion:SetPoint("BOTTOMLEFT", homeTitle, "BOTTOMRIGHT", 6, 2)
    local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("EasyFind", "Version")
    homeVersion:SetText("|cFF888888v" .. (tocVersion or "") .. "|r")

    local FLOW_FONT = "GameFontHighlightSmall"
    local FLOW_W = FRAME_W - 24

    local homeQuick = ns.BuildFlowText(homeTab, L["OPT_HOME_QUICKSTART"], {
        width = FLOW_W,
        font = FLOW_FONT,
        textColor = { 1, 1, 1 },
        linkDispatch = {
            setbind = function()
                if ctx.bindsTabIndex then SwitchToTab(ctx.bindsTabIndex) end
                FlashBindButton()
            end,
            maptab = function()
                if ns.MapTab and ns.MapTab.Focus then ns.MapTab:Focus() end
            end,
            tutorial = function()
                optionsFrame:Hide()
                if ns.Wizard and ns.Wizard.Show then ns.Wizard:Show(ns.Wizard.FEATURES_PAGE) end
            end,
        },
    })
    homeQuick:SetPoint("TOPLEFT", homeIcon, "BOTTOMLEFT", 0, -20)
    local thankYou = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    thankYou:SetPoint("BOTTOMRIGHT", homeTab, "BOTTOMRIGHT", -16, 4)
    thankYou:SetText(L["OPT_HOME_WELCOME"])
    thankYou:SetTextColor(1, 1, 1, 1)

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

    CreateURLBox(homeTab, "https://www.curseforge.com/wow/addons/easyfind", homeQuick, -6)

end

local function BuildGeneralBindsTab(ctx)
    local CreateTab, GetCurrentKeybindText, MakeKeybindTooltip = ctx.CreateTab, ctx.GetCurrentKeybindText, ctx.MakeKeybindTooltip
    local StartCapture, SELECTOR_ROW_W, SELECTOR_BTN_W = ctx.StartCapture, ctx.SELECTOR_ROW_W, ctx.SELECTOR_BTN_W
    local sec3 = CreateTab(L["OPT_TAB_GENERAL_BINDS"])
    ctx.bindsTabIndex = sec3.tabIndex

    -- Selector rows parent to this tab, so the helper lives here.
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

    local minimapBtnCheckbox = CreateCheckbox(sec3, "MinimapBtn", L["OPT_SHOW_MINIMAP_BUTTON"],
        L["OPT_MINIMAP_BTN_TT"])
    local aliasMessageCheckbox = CreateCheckbox(sec3, "AliasMessages", L["OPT_SHOW_ALIAS_MESSAGES"],
        L["OPT_ALIAS_MSG_TT"])
    aliasMessageCheckbox:SetPoint("TOPLEFT", sec3, "TOPLEFT", 8, -8)
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


    local indicatorRow, indicatorLabel = CreateSelectorRow(minimapBtnCheckbox, L["OPT_INDICATOR_STYLE"])

    local indicatorChoices = {"EasyFind Arrow", "Classic Quest Arrow", "Minimap Player Arrow", "Low-res Gauntlet", "HD Gauntlet"}

    local indicatorBtnFrame, indicatorBtnText = CreateFlyoutSelector(
        indicatorRow, "EasyFindIndicator", SELECTOR_BTN_W, indicatorLabel, StyleLabel(EasyFind.db.indicatorStyle or "EasyFind Arrow")
    )
    -- Previews render exactly like the live indicator: style texture
    -- tinted with the currently selected indicator color.
    local function ApplyIndicatorIcon(tex, name)
        local info = ns.GetIndicatorStyleInfo and ns.GetIndicatorStyleInfo(name)
        if not info then tex:Hide() return end
        tex:SetTexture(info.texture)
        if info.texCoord then
            tex:SetTexCoord(unpack(info.texCoord))
        else
            tex:SetTexCoord(0, 1, 0, 1)
        end
        local rgb = ns.INDICATOR_COLORS[EasyFind.db.indicatorColor or "Yellow"]
            or ns.INDICATOR_COLORS.Yellow
        tex:SetVertexColor(Utils.RGB(rgb))
        tex:Show()
    end
    local indicatorRowIcons = {}
    local indicatorBtnIcon = indicatorBtnFrame:CreateTexture(nil, "OVERLAY")
    indicatorBtnIcon:SetSize(14, 14)
    -- The selector text is a centered fontstring spanning the bar, so the
    -- icon anchors off the text's center plus half its rendered width to
    -- sit just after the style name rather than at the bar's right edge.
    local function SetIndicatorSelection(name)
        indicatorBtnText:SetText(StyleLabel(name))
        ApplyIndicatorIcon(indicatorBtnIcon, name)
        indicatorBtnIcon:ClearAllPoints()
        indicatorBtnIcon:SetPoint("LEFT", indicatorBtnText, "CENTER",
            (indicatorBtnText:GetStringWidth() / 2) + 5, 0)
    end
    SetIndicatorSelection(EasyFind.db.indicatorStyle or "EasyFind Arrow")
    local defaultIndicatorStyle = (ns.DB_DEFAULTS and ns.DB_DEFAULTS.indicatorStyle) or "EasyFind Arrow"
    local function IndicatorStyleFlyoutLabel(name)
        local label = StyleLabel(name)
        if name == defaultIndicatorStyle then label = DefaultTag(label) end
        return label
    end
    local indicatorFlyout = CreateFlyoutPanel(indicatorBtnFrame, "EasyFindIndicator", SELECTOR_BTN_W, #indicatorChoices)
    AddFlyoutOptions(indicatorFlyout, indicatorChoices, SELECTOR_BTN_W - 6, function(name)
        EasyFind.db.indicatorStyle = name
        SetIndicatorSelection(name)
        if ns.MapSearch then
            ns.MapSearch:RefreshIndicators()
        end
    end, IndicatorStyleFlyoutLabel, function(flyoutBtn, name, label)
        local icon = label:GetParent():CreateTexture(nil, "OVERLAY")
        icon:SetSize(13, 13)
        icon:SetPoint("RIGHT", label:GetParent(), "RIGHT", -4, 0)
        ApplyIndicatorIcon(icon, name)
        indicatorRowIcons[#indicatorRowIcons + 1] = { icon = icon, style = name }
        flyoutBtn._rightIconW = 13 + 4
    end)
    local function RetintIndicatorPreviews()
        SetIndicatorSelection(EasyFind.db.indicatorStyle or "EasyFind Arrow")
        for i = 1, #indicatorRowIcons do
            ApplyIndicatorIcon(indicatorRowIcons[i].icon, indicatorRowIcons[i].style)
        end
    end
    optionsFrame.indicatorBtnText = indicatorBtnText
    optionsFrame.SetIndicatorSelection = SetIndicatorSelection
    optionsFrame.RetintIndicatorPreviews = RetintIndicatorPreviews
    optionsFrame.indicatorFlyout = indicatorFlyout

    local colorRow, colorLabel = CreateSelectorRow(indicatorRow, L["OPT_INDICATOR_COLOR"])

    local colorChoices = {"Yellow", "Gold", "Orange", "Red", "Green", "Blue", "Purple", "White"}
    local colorRGB = ns.INDICATOR_COLORS

    local colorBtnFrame, colorBtnText = CreateFlyoutSelector(
        colorRow, "EasyFindColor", SELECTOR_BTN_W, colorLabel, ColorLabel(EasyFind.db.indicatorColor or "Yellow")
    )
    local currentColor = EasyFind.db.indicatorColor or "Yellow"
    local currentRGB = colorRGB[currentColor] or colorRGB.Yellow
    colorBtnText:SetTextColor(Utils.RGB(currentRGB))

    local colorFlyout = CreateFlyoutPanel(colorBtnFrame, "EasyFindColor", SELECTOR_BTN_W, #colorChoices)

    local defaultIndicatorColor = (ns.DB_DEFAULTS and ns.DB_DEFAULTS.indicatorColor) or "Yellow"
    local colorRowBtns = {}
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
        label:SetText(name == defaultIndicatorColor and DefaultTag(ColorLabel(name)) or ColorLabel(name))
        label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
        colorBtn._label = label
        colorRowBtns[i] = colorBtn

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
            colorBtnText:SetText(ColorLabel(name))
            colorBtnText:SetTextColor(Utils.RGB(rgb))
            colorFlyout:Hide()
            if ns.MapSearch then
                ns.MapSearch:RefreshIndicators()
            end
            if optionsFrame.RetintIndicatorPreviews then optionsFrame.RetintIndicatorPreviews() end
        end)
    end
    local colorContentW = 0
    for i = 1, #colorRowBtns do
        local label = colorRowBtns[i]._label
        local getter = label.GetUnboundedStringWidth or label.GetStringWidth
        local w = 6 + getter(label) + 6
        if w > colorContentW then colorContentW = w end
    end
    local colorRowW = mmax(SELECTOR_BTN_W - 6, mfloor(colorContentW + 0.5))
    if colorRowW > SELECTOR_BTN_W - 6 then
        for i = 1, #colorRowBtns do colorRowBtns[i]:SetWidth(colorRowW) end
        colorFlyout:SetWidth(colorRowW + 6)
    end

    optionsFrame.colorBtnText = colorBtnText
    optionsFrame.colorFlyout = colorFlyout

    -- The indicator only appears during guides and on map pins, so
    -- explain what it even is; many players never enter guide mode.
    indicatorRow:EnableMouse(true)
    Utils.AttachDelayedTooltip(indicatorRow, "ANCHOR_RIGHT", function()
        return L["OPT_INDICATOR_STYLE"], L["OPT_INDICATOR_STYLE_TT"]
    end)
    colorRow:EnableMouse(true)
    Utils.AttachDelayedTooltip(colorRow, "ANCHOR_RIGHT", function()
        return L["OPT_INDICATOR_COLOR"], L["OPT_INDICATOR_COLOR_TT"]
    end)

    local fontRow, fontLabel = CreateSelectorRow(colorRow, L["OPT_FONT"])

    local fontChoices = ns.FONT_CHOICES
    local function FontLabel(name)
        if name == "Default" then return _G["DEFAULT"] or "Default" end
        return name
    end
    local fontBtnFrame, fontBtnText = CreateFlyoutSelector(
        fontRow, "EasyFindFont", SELECTOR_BTN_W, fontLabel, FontLabel(EasyFind.db.font or "Default")
    )
    local fontFlyout = CreateFlyoutPanel(fontBtnFrame, "EasyFindFont", SELECTOR_BTN_W, #fontChoices)
    local function StyleFontChoiceRow(_, name, label)
        -- Each row previews its own font and stays immune to the global
        -- font choice (see ns.RegisterAddonFont), so the whole list keeps
        -- rendering after a selection instead of blanking.
        label._efFontPreview = true
        local path = ns.GetFontChoicePath and ns.GetFontChoicePath(name)
        if path then
            local _, size, flags = label:GetFont()
            label:SetFont(path, size, flags)
        end
    end
    AddFlyoutOptions(fontFlyout, fontChoices, SELECTOR_BTN_W - 6, function(name)
        EasyFind.db.font = name
        fontBtnText:SetText(FontLabel(name))
        if ns.RegisterAddonFontsIn then ns.RegisterAddonFontsIn(optionsFrame) end
        if ns.RefreshAddonFont then ns.RefreshAddonFont() end
        if ns.Search then
            if ns.Search.UpdateFontSize then ns.Search:UpdateFontSize() end
            if ns.Search.RefreshResults then ns.Search:RefreshResults() end
        end
    end, FontLabel, StyleFontChoiceRow)
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
                self:SetText((_G["NOT_BOUND"] or "Not Bound"))
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


    ctx.sec3 = sec3
end

local function BuildSearchTab(ctx)
    local CreateTab, SELECTOR_ROW_W, SELECTOR_BTN_W = ctx.CreateTab, ctx.SELECTOR_ROW_W, ctx.SELECTOR_BTN_W
    local CreateFlyoutPresetRow, RESET_BTN_W = ctx.CreateFlyoutPresetRow, ctx.RESET_BTN_W
    local sec1 = CreateTab(L["OPT_TAB_SEARCH"])

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
            { label = L["OPT_VISIBILITY_AUTOHIDE"], value = VISIBILITY_AUTO,
              tooltip = L["OPT_VISIBILITY_AUTOHIDE_TT"] },
            { label = L["OPT_VISIBILITY_SMARTSHOW"], value = VISIBILITY_SMART,
              tooltip = L["OPT_VISIBILITY_SMARTSHOW_TT"] },
        },
        GetVisibilityModeValue,
        SetVisibilityMode,
        nil,
        SELECTOR_ROW_W)
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
            { label = L["OPT_RESULTS_BELOW"], value = RESULTS_BELOW,
              tooltip = L["OPT_RESULTS_BELOW_TT"] },
            { label = L["OPT_RESULTS_ABOVE"], value = RESULTS_ABOVE,
              tooltip = L["OPT_RESULTS_ABOVE_TT"] },
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
        nil,
        SELECTOR_ROW_W)
    resultsDirectionRow:SetPoint("TOPLEFT", visibilityModeRow, "BOTTOMLEFT", 0, -2)
    optionsFrame.resultsDirectionRow = resultsDirectionRow

    -- Append a live example of the hint badge (the alt-key glyph + a number)
    -- so the label shows exactly what the rows display.
    local altHintExample = " (|TInterface\\AddOns\\EasyFind\\textures\\alt-key:16:16|t1)"
    local resultShortcutHintsCheckbox = CreateCheckbox(sec1, "ResultShortcutHints",
        L["OPT_SHOW_ALT_HINTS"] .. altHintExample,
        L["OPT_ALT_HINTS_TT"])
    resultShortcutHintsCheckbox:SetPoint("TOPLEFT", resultsDirectionRow, "BOTTOMLEFT", 0, -2)
    resultShortcutHintsCheckbox:SetChecked(EasyFind.db.showResultShortcutHints ~= false)
    resultShortcutHintsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showResultShortcutHints = self:GetChecked()
        if self.RefreshVisual then self:RefreshVisual() end
        RunSoon(function()
            if ns.Search and ns.Search.RefreshResults then ns.Search:RefreshResults() end
            if ns.ResultShortcuts and ns.ResultShortcuts.UpdateVisibleResultShortcuts then
                ns.ResultShortcuts:UpdateVisibleResultShortcuts()
            end
        end)
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
    local uiFontPresetRow = CreateFlyoutPresetRow(sec1, L["OPT_FONT_SIZE"], fontSizeChoices,
        function() return EasyFind.db.fontSize or ns.DEFAULT_FONT_SIZE end,
        function(value)
            EasyFind.db.fontSize = value
            if ns.Search and ns.Search.UpdateFontSize then
                ns.Search:UpdateFontSize()
            end
        end, "EasyFindFontSize", ns.DEFAULT_FONT_SIZE, L["OPT_FONT_SIZE_TT"])
    uiFontPresetRow:SetPoint("TOPLEFT", resultsDirectionRow, "BOTTOMLEFT", 0, -8)
    optionsFrame.uiFontPresetRow = uiFontPresetRow

    -- Uniform zoom for the whole search UI (bar, results, popups) that
    -- can't drift element proportions.
    local scaleChoices = {
        { label = "50%",  value = 0.5  }, { label = "75%",  value = 0.75 },
        { label = "100%", value = 1.0  }, { label = "125%", value = 1.25 },
        { label = "150%", value = 1.5  },
    }
    local scaleRow = CreateFlyoutPresetRow(sec1, L["OPT_SEARCH_SCALE"], scaleChoices,
        function() return EasyFind.db.uiSearchScale or 1.0 end,
        function(value)
            EasyFind.db.uiSearchScale = value
            -- resultsFrame is a CHILD of searchFrame, so it already inherits the
            -- bar scale. Keep its own scale at 1.0 so it is not scaled twice.
            EasyFind.db.uiResultsScale = 1.0
            if ns.Search and ns.Search.UpdateScale then ns.Search:UpdateScale() end
        end, "EasyFindSearchScale", 1.0, L["OPT_SEARCH_SCALE_TT"])
    scaleRow:SetPoint("TOPLEFT", uiFontPresetRow, "BOTTOMLEFT", 0, -8)
    optionsFrame.searchScaleRow = scaleRow

    -- How many result rows the dropdown shows before scrolling. Replaces
    -- the old pixel-height drag: the viewport height derives from row count
    -- so it stays correct at any scale and font size.
    local resultRowsChoices = {
        { label = "1", value = 1 }, { label = "2", value = 2 },
        { label = "3", value = 3 }, { label = "4", value = 4 },
        { label = "5", value = 5 }, { label = "6", value = 6 },
        { label = "7", value = 7 }, { label = "8", value = 8 },
    }
    local resultRowsRow = CreateFlyoutPresetRow(sec1, L["OPT_RESULT_ROWS"], resultRowsChoices,
        function() return EasyFind.db.uiResultsRows or 6 end,
        function(value)
            EasyFind.db.uiResultsRows = value
            RunSoon(function()
                if ns.Search and ns.Search.RefreshResults then ns.Search:RefreshResults() end
            end)
        end, "EasyFindResultRows", 6, L["OPT_RESULT_ROWS_TT"])
    resultRowsRow:SetPoint("TOPLEFT", scaleRow, "BOTTOMLEFT", 0, -8)
    optionsFrame.resultRowsRow = resultRowsRow

    local opacityChoices = {
        { label = "75%",  value = 0.75 },
        { label = "85%",  value = 0.85 },
        { label = "95%",  value = 0.95 },
        { label = "100%", value = 1.00 },
    }
    local searchOpacityRow = CreateFlyoutPresetRow(sec1, L["OPT_SEARCH_OPACITY"], opacityChoices,
        function() return EasyFind.db.searchWindowOpacity or ns.SEARCH_WINDOW_ALPHA end,
        function(value)
            EasyFind.db.searchWindowOpacity = value
            RunSoon(function()
                if ns.Search and ns.Search.UpdateOpacity then ns.Search:UpdateOpacity() end
            end)
        end, "EasyFindOpacity", ns.SEARCH_WINDOW_ALPHA, L["OPT_SEARCH_OPACITY_TT"])
    searchOpacityRow:SetPoint("TOPLEFT", resultRowsRow, "BOTTOMLEFT", 0, -8)
    optionsFrame.searchOpacityRow = searchOpacityRow



    -- Wowhead link language: which wowhead.com site the row right-click "Wowhead"
    -- option points at. "Auto" follows the client locale.
    local wowheadValues, wowheadLabelByValue = {}, {}
    for _, entry in ipairs(ns.WOWHEAD_LOCALES) do
        wowheadValues[#wowheadValues + 1] = entry.value
        wowheadLabelByValue[entry.value] = entry.label
    end
    local function WowheadLocaleLabel(v)
        if v == "auto" then return L["WOWHEAD_LOCALE_AUTO"] end
        return wowheadLabelByValue[v] or v
    end

    local wowheadRow = CreateFrame("Frame", nil, sec1)
    wowheadRow:SetSize(SELECTOR_ROW_W, 24)
    wowheadRow:SetPoint("TOPLEFT", searchOpacityRow, "BOTTOMLEFT", 0, -8)
    local wowheadRowLabel = wowheadRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wowheadRowLabel:SetPoint("LEFT", wowheadRow, "LEFT", 8, 0)
    wowheadRowLabel:SetPoint("RIGHT", wowheadRow, "RIGHT", -SELECTOR_BTN_W - 18, 0)
    wowheadRowLabel:SetJustifyH("LEFT")
    wowheadRowLabel:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
    wowheadRowLabel:SetText(L["OPT_WOWHEAD_LOCALE"])

    local wowheadBtnFrame, wowheadBtnText = CreateFlyoutSelector(
        wowheadRow, "EasyFindWowhead", SELECTOR_BTN_W, wowheadRowLabel,
        WowheadLocaleLabel(EasyFind.db.wowheadLocale or "auto")
    )
    local function WowheadFlyoutLabel(v)
        if v == "auto" then
            return DefaultTag(WowheadLocaleLabel(v))
        end
        return WowheadLocaleLabel(v)
    end
    local wowheadFlyout = CreateFlyoutPanel(wowheadBtnFrame, "EasyFindWowhead", SELECTOR_BTN_W, #wowheadValues)
    AddFlyoutOptions(wowheadFlyout, wowheadValues, SELECTOR_BTN_W - 6, function(value)
        EasyFind.db.wowheadLocale = value
        wowheadBtnText:SetText(WowheadLocaleLabel(value))
    end, WowheadFlyoutLabel)
    optionsFrame.wowheadBtnText = wowheadBtnText
    optionsFrame.SetWowheadSelection = function(value)
        wowheadBtnText:SetText(WowheadLocaleLabel(value))
    end
    optionsFrame.wowheadFlyout = wowheadFlyout
    wowheadRow:EnableMouse(true)
    Utils.AttachDelayedTooltip(wowheadRow, "ANCHOR_RIGHT", function()
        return L["OPT_WOWHEAD_LOCALE"], L["OPT_WOWHEAD_LOCALE_TT"]
    end)
    Utils.AttachDelayedTooltip(wowheadBtnFrame, "ANCHOR_RIGHT", function()
        return L["OPT_WOWHEAD_LOCALE"], L["OPT_WOWHEAD_LOCALE_TT"]
    end)

    optionsFrame:HookScript("OnShow", function(self)
        if ns.RegisterAddonFontsIn then ns.RegisterAddonFontsIn(self) end
    end)

    lockPositionCheckbox:ClearAllPoints()
    lockPositionCheckbox:SetPoint("TOPLEFT", wowheadRow, "BOTTOMLEFT", 0, -8)
    resultShortcutHintsCheckbox:ClearAllPoints()
    resultShortcutHintsCheckbox:SetPoint("TOPLEFT", lockPositionCheckbox, "BOTTOMLEFT", 0, -2)

    local function RefreshUIPresetRows()
        if optionsFrame.uiFontPresetRow then
            optionsFrame.uiFontPresetRow:SetValue(EasyFind.db.fontSize or ns.DEFAULT_FONT_SIZE)
        end
    end
    optionsFrame.RefreshUIPresetRows = RefreshUIPresetRows

    local resetUIBtn = CreateModernButton(sec1)
    resetUIBtn:SetSize(RESET_BTN_W, 20)
    resetUIBtn:SetPoint("BOTTOMLEFT", sec1, "BOTTOMLEFT", 16, 8)
    resetUIBtn:SetText(L["OPT_RESET_SETTINGS"])
    resetUIBtn:SetScript("OnClick", function()
        ShowResetConfirm(L["POPUP_RESET_UI_SEARCH_SETTINGS"], function() Options:DoResetUI() end)
    end)

    local resetUIPosBtn = CreateModernButton(sec1)
    resetUIPosBtn:SetSize(RESET_BTN_W, 20)
    resetUIPosBtn:SetPoint("LEFT", resetUIBtn, "RIGHT", 8, 0)
    resetUIPosBtn:SetText(L["OPT_RESET_POSITIONS"])
    resetUIPosBtn:SetScript("OnClick", function()
        ShowResetConfirm(L["POPUP_RESET_UI_SEARCH_POSITIONS"], function() Options:DoResetUIPositions() end)
    end)

end

local function BuildMapTab(ctx)
    local CreateTab, FRAME_W, COL_LEFT = ctx.CreateTab, ctx.FRAME_W, ctx.COL_LEFT
    local RESET_BTN_W = ctx.RESET_BTN_W
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
        ShowResetConfirm(L["POPUP_RESET_MAP_SEARCH_SETTINGS"], function() Options:DoResetMap() end)
    end)

    mapControls = {
        resetMapBtn, mapTabSettings, mapIconSettings, mapPinSettings
    }
    UpdateMapToggleVisual()

end

local function BuildShortcutsTab(ctx)
    local CreateTab, FRAME_W = ctx.CreateTab, ctx.FRAME_W
    local sec4 = CreateTab(L["OPT_TAB_SHORTCUTS"])

    local shortcutText = sec4:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shortcutText:SetPoint("TOPLEFT", sec4, "TOPLEFT", 8, -8)
    shortcutText:SetWidth(FRAME_W - 60)
    shortcutText:SetJustifyH("LEFT")
    shortcutText:SetSpacing(2)
    shortcutText:SetText(L["OPT_SHORTCUTS_TEXT"])

end

local function BuildAliasesTab(ctx)
    local CreateTab, FRAME_W, RESET_BTN_W = ctx.CreateTab, ctx.FRAME_W, ctx.RESET_BTN_W
    local sec3 = ctx.sec3
    local aliasesTab = CreateTab(L["OPT_TAB_ALIASES"])
    Options._aliasesTabIndex = aliasesTab.tabIndex

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
    PaintControlFill(aliasSearchShell, ns.BTN_FILL_PRESSED, 1)

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

    -- Share row: scope selector + export / import of aliases and/or shortkeys.
    local exportInclAlias, exportInclShortkey = true, true
    local function CurrentScope()
        if exportInclAlias and exportInclShortkey then return "both" end
        if exportInclAlias then return "alias" end
        if exportInclShortkey then return "shortkey" end
        return nil
    end
    local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"
    local cogBtn
    local exportMenu
    local ShowExportScopeMenu
    ShowExportScopeMenu = function()
        exportMenu = Utils.ShowCursorMenu("EasyFindExportScopeMenu", {
            { text = L["SHORTKEY_SCOPE_ALIASES"], icon = exportInclAlias and CHECK_TEX or nil,
              onClick = function() exportInclAlias = not exportInclAlias; ShowExportScopeMenu() end },
            { text = L["SHORTKEY_SCOPE_SHORTKEYS"], icon = exportInclShortkey and CHECK_TEX or nil,
              onClick = function() exportInclShortkey = not exportInclShortkey; ShowExportScopeMenu() end },
        }, {
            -- Stay open until clicked out (like the search bar filter menu), and
            -- anchor under the cog so toggling a box doesn't move the menu.
            stayOpen = true,
            anchorFrame = cogBtn,
            toggleOwner = cogBtn,
            point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT", offsetY = -2,
        })
    end

    local sharePopup
    local function BuildSharePopup()
        local f = CreateFrame("Frame", "EasyFindSharePopup", UIParent, "BackdropTemplate")
        f:SetSize(440, 200)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        ns.StyleMenuPanel(f)

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOP", 0, -12)

        local boxFrame = CreateFrame("Frame", nil, f)
        boxFrame:SetPoint("TOPLEFT", 14, -34)
        boxFrame:SetPoint("TOPRIGHT", -14, -34)
        boxFrame:SetHeight(112)
        ns.CreateRoundedRectBorder(boxFrame)
        ns.SetRoundedRectBarHeight(boxFrame, 8)
        ns.SetRoundedRectBorderShown(boxFrame, false)
        ns.SetRoundedRectFill(boxFrame, 0.02, 0.02, 0.03, 1)

        -- Plain ScrollFrame + the minimal overlay scrollbar the results
        -- window uses; the Blizzard template's arrow-button bar reads dated.
        local scroll = CreateFrame("ScrollFrame", "EasyFindShareScroll", boxFrame)
        scroll:SetPoint("TOPLEFT", 8, -8)
        scroll:SetPoint("BOTTOMRIGHT", -14, 8)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject("GameFontHighlightSmall")
        eb:SetWidth(384)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
        scroll:SetScrollChild(eb)
        f.editBox = eb
        Utils.CreateMinimalScrollBar(scroll, boxFrame)

        -- Ctrl-C confirmation, matching the Wowhead copy box: flash
        -- "Copied" under the code box and fade it out. No bottom Close
        -- button; the top-right X covers dismissal.
        local copiedHolder = CreateFrame("Frame", nil, f)
        copiedHolder:SetPoint("TOP", boxFrame, "BOTTOM", 0, -4)
        copiedHolder:SetSize(140, 16)
        copiedHolder:Hide()
        local copied = copiedHolder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        copied:SetPoint("CENTER")
        copied:SetText(L["COPIED"])
        local copiedFade = copiedHolder:CreateAnimationGroup()
        local fadeAnim = copiedFade:CreateAnimation("Alpha")
        fadeAnim:SetFromAlpha(1)
        fadeAnim:SetToAlpha(0)
        fadeAnim:SetStartDelay(0.8)
        fadeAnim:SetDuration(0.8)
        copiedFade:SetScript("OnFinished", function() copiedHolder:Hide() end)
        eb:SetScript("OnKeyDown", function(_, key)
            if key ~= "C" or not IsControlKeyDown() then return end
            copiedFade:Stop()
            copiedHolder:SetAlpha(1)
            copiedHolder:Show()
            copiedFade:Play()
        end)

        f.importBtn = ns.CreateModernButton(f, L["SHORTKEY_IMPORT"], 90, 22)
        f.importBtn:SetPoint("BOTTOMRIGHT", -14, 12)

        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        f.hint:SetPoint("BOTTOMLEFT", 14, 16)

        local x = ns.CreateCloseX(f, 14)
        x:SetPoint("TOPRIGHT", -8, -8)
        x:SetScript("OnClick", function() f:Hide() end)
        -- ESC closes the popup even when the code box lost focus, via
        -- Blizzard's UISpecialFrames pipeline (no keyboard capture).
        tinsert(UISpecialFrames, "EasyFindSharePopup")
        f:Hide()
        return f
    end

    local function ShowShareString(isExport, str)
        if not sharePopup then sharePopup = BuildSharePopup() end
        local f = sharePopup
        if isExport then
            f.title:SetText(L["SHORTKEY_EXPORT_TITLE"] .. " (Ctrl+C)")
            f.hint:SetText("")
            Utils.SetEditBoxReadOnlyText(f.editBox, str or "")
            f.importBtn:Hide()
            f:Show()
            f.editBox:SetFocus()
            f.editBox:HighlightText()
        else
            f.title:SetText(L["SHORTKEY_IMPORT_TITLE"])
            f.hint:SetText(L["SHORTKEY_IMPORT_HINT"])
            Utils.SetEditBoxReadOnlyText(f.editBox, nil)
            f.editBox:SetText("")
            f.importBtn:Show()
            f.importBtn:SetScript("OnClick", function()
                local na, nk = nil, nil
                if ns.Shortkeys then na, nk = ns.Shortkeys:ApplyImportString(f.editBox:GetText(), CurrentScope()) end
                f:Hide()
                if EasyFind and EasyFind.Print then
                    if na == nil then
                        EasyFind:Print(L["SHORTKEY_IMPORT_BAD"])
                    else
                        EasyFind:Print((L["SHORTKEY_IMPORTED"]):format((na or 0) + (nk or 0)))
                    end
                end
                if RefreshAliasList then RefreshAliasList() end
            end)
            f:Show()
            f.editBox:SetFocus()
        end
    end

    local shareTools = CreateFrame("Frame", nil, aliasesTab)
    shareTools:SetPoint("TOPLEFT", aliasTools, "BOTTOMLEFT", 0, -6)
    shareTools:SetPoint("RIGHT", aliasesTab, "RIGHT", -8, 0)
    shareTools:SetHeight(22)

    -- Export / import use the same visible resting fill as other option buttons,
    -- with the scope cogwheel tucked into the right edge of the export button.
    -- Import matches export's width.
    local SHARE_BTN_W = 92
    local SHARE_BTN_FILL = { ns.BTN_FILL_NORMAL[1], ns.BTN_FILL_NORMAL[2], ns.BTN_FILL_NORMAL[3], 0.92 }
    local function UseShareButtonFill(btn)
        ns.SetRoundedRectBorderFillColor(btn, unpack(SHARE_BTN_FILL))
        btn:HookScript("OnLeave", function(self)
            if self:IsEnabled() then ns.SetRoundedRectBorderFillColor(self, unpack(SHARE_BTN_FILL)) end
        end)
        btn:HookScript("OnMouseUp", function(self)
            if self:IsEnabled() and not self:IsMouseOver() then
                ns.SetRoundedRectBorderFillColor(self, unpack(SHARE_BTN_FILL))
            end
        end)
    end

    local exportBtn = CreateModernButton(shareTools, L["SHORTKEY_EXPORT"], SHARE_BTN_W, 22)
    exportBtn:SetPoint("LEFT", shareTools, "LEFT", 0, 0)
    UseShareButtonFill(exportBtn)
    -- Shift the label left so it stays centered in the space left of the cog.
    exportBtn._label:ClearAllPoints()
    exportBtn._label:SetPoint("CENTER", exportBtn, "CENTER", -9, 0)
    exportBtn:SetScript("OnClick", function()
        local str = ns.Shortkeys and ns.Shortkeys:BuildExportString(CurrentScope()) or ""
        ShowShareString(true, str)
    end)

    cogBtn = CreateFrame("Button", nil, exportBtn)
    cogBtn:SetSize(18, 18)
    cogBtn:SetPoint("RIGHT", exportBtn, "RIGHT", -4, 0)
    local cogTex = cogBtn:CreateTexture(nil, "ARTWORK")
    cogTex:SetPoint("CENTER")
    cogTex:SetSize(15, 15)
    cogTex:SetAtlas("QuestLog-icon-setting")
    cogBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    cogBtn:SetScript("OnClick", function()
        if exportMenu and exportMenu:IsShown() then
            exportMenu:Hide()
        else
            ShowExportScopeMenu()
        end
    end)

    local importBtn = CreateModernButton(shareTools, L["SHORTKEY_IMPORT"], SHARE_BTN_W, 22)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    UseShareButtonFill(importBtn)
    importBtn:SetScript("OnClick", function() ShowShareString(false) end)

    Utils.AttachDelayedTooltip(exportBtn, "ANCHOR_TOP", function()
        return L["SHORTKEY_EXPORT"], L["OPT_EXPORT_BTN_TT"]
    end)
    Utils.AttachDelayedTooltip(importBtn, "ANCHOR_TOP", function()
        return L["SHORTKEY_IMPORT"], L["OPT_IMPORT_BTN_TT"]
    end)

    -- Column geometry shared by the header and every row so they line up. Rows
    -- sit at the scroll inset (6) + row inset (4) = 10 from the table's left and
    -- are FRAME_W-42 wide; the header mirrors that.
    local COL_GAP = 6
    local REMOVE_RIGHT = 4
    local REMOVE_W = 20
    local SK_COL_W = 86
    local ALIAS_COL_W = 120
    local NAME_LEFT = 10
    local HEADER_H = 14

    local HEADER_TOP = 7
    local DIVIDER_Y = HEADER_TOP + HEADER_H + 3
    local SCROLL_TOP = DIVIDER_Y + 4

    local aliasList = CreateFrame("Frame", nil, aliasesTab)
    aliasList:SetPoint("TOPLEFT", shareTools, "BOTTOMLEFT", 0, -8)
    aliasList:SetPoint("BOTTOMRIGHT", aliasesTab, "BOTTOMRIGHT", -8, 8)
    ns.CreateRoundedRectBorder(aliasList)
    ns.SetRoundedRectBarHeight(aliasList, 8)
    HideRoundedFrameBorder(aliasList)
    PaintRoundedFill(aliasList, unpack(SECTION_TABLE_FILL))

    -- Column header inside the table, with a thin divider under it.
    local aliasColHeader = CreateFrame("Frame", nil, aliasList)
    aliasColHeader:SetSize(FRAME_W - 42, HEADER_H)
    aliasColHeader:SetPoint("TOPLEFT", aliasList, "TOPLEFT", 10, -HEADER_TOP)
    local function MakeColHeader(text, justify)
        local fs = aliasColHeader:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetText(text)
        fs:SetJustifyH(justify)
        return fs
    end
    local hSk = MakeColHeader(L["OPT_COL_SHORTKEY"], "CENTER")
    hSk:SetWidth(SK_COL_W)
    hSk:SetPoint("RIGHT", aliasColHeader, "RIGHT", -(REMOVE_RIGHT + REMOVE_W + COL_GAP), 0)
    local hAlias = MakeColHeader(L["OPT_COL_ALIAS"], "CENTER")
    hAlias:SetWidth(ALIAS_COL_W)
    hAlias:SetPoint("RIGHT", hSk, "LEFT", -COL_GAP, 0)
    local hObject = MakeColHeader(L["OPT_COL_OBJECT"], "LEFT")
    hObject:SetPoint("LEFT", aliasColHeader, "LEFT", NAME_LEFT, 0)
    hObject:SetPoint("RIGHT", hAlias, "LEFT", -8, 0)

    local headerDivider = aliasList:CreateTexture(nil, "ARTWORK")
    headerDivider:SetColorTexture(1, 1, 1, 0.09)
    headerDivider:SetHeight(1)
    headerDivider:SetPoint("TOPLEFT", aliasList, "TOPLEFT", 8, -DIVIDER_Y)
    headerDivider:SetPoint("TOPRIGHT", aliasList, "TOPRIGHT", -8, -DIVIDER_Y)

    local aliasScroll = CreateFrame("ScrollFrame", nil, aliasList)
    aliasScroll:SetPoint("TOPLEFT", aliasList, "TOPLEFT", 6, -SCROLL_TOP)
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
    -- Delayed tooltip showing the full text, but only when the cell is actually
    -- truncated (has an ellipsis). ~0.5s hover delay, the usual tooltip feel.
    local truncTipToken = 0
    local function ShowTruncTip(anchor, fontString, fullText)
        truncTipToken = truncTipToken + 1
        if not (fontString and fontString.IsTruncated and fontString:IsTruncated()) then return end
        if not fullText or fullText == "" then return end
        local myToken = truncTipToken
        Utils.SafeAfter(0.5, function()
            if myToken ~= truncTipToken or not anchor:IsMouseOver() then return end
            GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
            GameTooltip:SetText(fullText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
    end
    local function HideTruncTip()
        truncTipToken = truncTipToken + 1
        GameTooltip:Hide()
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

        row.removeBtn = CreateModernButton(row, "x", REMOVE_W, 18)
        row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -REMOVE_RIGHT, 0)

        -- Columns: item name (fills left), then alias, then shortkey.
        row.skBtn = CreateModernButton(row, "", SK_COL_W, 20)
        row.skBtn:SetPoint("RIGHT", row.removeBtn, "LEFT", -COL_GAP, 0)
        row.skBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        row.aliasBtn = CreateModernButton(row, "", ALIAS_COL_W, 20)
        row.aliasBtn:SetPoint("RIGHT", row.skBtn, "LEFT", -COL_GAP, 0)
        -- Constrain the label so a long alias truncates with an ellipsis, which
        -- IsTruncated() then reports to gate the hover tooltip.
        row.aliasBtn._label:SetWidth(ALIAS_COL_W - 10)
        row.aliasBtn._label:SetWordWrap(false)
        row.aliasBtn:HookScript("OnEnter", function(self)
            ShowTruncTip(self, self._label, self._fullText)
        end)
        row.aliasBtn:HookScript("OnLeave", HideTruncTip)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.nameText:SetPoint("LEFT", row, "LEFT", NAME_LEFT, 0)
        row.nameText:SetPoint("RIGHT", row.aliasBtn, "LEFT", -8, 0)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        -- Hover region over the name for its own truncation tooltip.
        row.nameHover = CreateFrame("Frame", nil, row)
        row.nameHover:SetPoint("TOPLEFT", row, "TOPLEFT", NAME_LEFT, 0)
        row.nameHover:SetPoint("BOTTOMRIGHT", row.aliasBtn, "BOTTOMLEFT", -8, 0)
        row.nameHover:EnableMouse(true)
        row.nameHover:SetScript("OnEnter", function(self)
            PaintRoundedFill(row.bg, 1, 1, 1, 0.055)
            ShowTruncTip(self, row.nameText, row.nameText._fullText)
        end)
        row.nameHover:SetScript("OnLeave", function()
            PaintRoundedFill(row.bg, 1, 1, 1, 0)
            HideTruncTip()
        end)

        row:SetScript("OnEnter", function(self)
            PaintRoundedFill(self.bg, 1, 1, 1, 0.055)
        end)
        row:SetScript("OnLeave", function(self)
            PaintRoundedFill(self.bg, 1, 1, 1, 0)
        end)
        aliasRowPool[idx] = row
        return row
    end

    -- Merge aliases and shortkeys by their shared row key so each row shows
    -- both, with either editable in place.
    RefreshAliasList = function()
        ReleaseAliasRows()
        local query = (aliasSearchBox and aliasSearchBox:GetText() or ""):lower()

        local byKey, order = {}, {}
        local function ensure(rk, name)
            local e = byKey[rk]
            if not e then
                e = { key = rk, name = name, aliases = {} }
                byKey[rk] = e
                order[#order + 1] = e
            end
            if name and (not e.name or e.name == "") then e.name = name end
            return e
        end
        if ns.Aliases then
            ns.Aliases:ForEach(function(text, info)
                if info.key then
                    local e = ensure(info.key, info.name)
                    e.aliases[#e.aliases + 1] = info.text or text
                end
            end)
        end
        if ns.Shortkeys then
            ns.Shortkeys:ForEach(function(rk, info, isChar)
                local e = ensure(rk, info.name)
                e.shortkey = info.key
                e.charSpecific = isChar
            end)
        end

        local total = #order
        local entries = {}
        for i = 1, total do
            local e = order[i]
            e.aliasText = table.concat(e.aliases, ", ")
            local haystack = (e.aliasText .. " " .. (e.name or "") .. " " .. (e.shortkey or "")):lower()
            if query == "" or string.find(haystack, query, 1, true) then
                entries[#entries + 1] = e
            end
        end
        table.sort(entries, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)

        clearAliasesBtn:SetEnabled(total > 0)
        clearAliasesBtn:SetAlpha(total > 0 and 1 or 0.45)
        aliasEmpty:SetText(total == 0 and L["OPT_NO_SAVED_ALIASES"] or L["OPT_NO_ALIASES_MATCH"])
        aliasEmpty:SetShown(#entries == 0)

        local rowH = 28
        local y = -4
        for i = 1, #entries do
            local e = entries[i]
            local row = AcquireAliasRow(i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", aliasContent, "TOPLEFT", 4, y)
            row.aliasBtn:SetText(e.aliasText ~= "" and ("|cFFFFD100" .. e.aliasText .. "|r") or L["SHORTKEY_CELL_ADD"])
            row.skBtn:SetText(e.shortkey and ("|cFF8CD3FF" .. e.shortkey .. "|r") or L["SHORTKEY_CELL_ADD"])
            row.nameText:SetText(e.name or "?")
            row.aliasBtn._fullText = e.aliasText
            row.nameText._fullText = e.name

            row.aliasBtn:SetScript("OnClick", function()
                ns.ShowThemedDialog({
                    text = (L["PROMPT_ALIAS_FOR"]):format(e.name or "?"),
                    hasEditBox = true,
                    editBoxDefault = e.aliasText,
                    maxLetters = 64,
                    acceptText = _G["SAVE"] or "Save",
                    onAccept = function(txt)
                        txt = strtrim(txt or "")
                        if not (e.key and ns.Aliases) then return end
                        ns.Aliases:RemoveByKey(e.key)
                        if txt ~= "" then ns.Aliases:AddByKey(txt, e.key, e.name) end
                        if RefreshAliasList then RefreshAliasList() end
                    end,
                })
            end)
            row.skBtn:SetScript("OnClick", function(_, button)
                if button == "RightButton" then
                    if ns.Shortkeys then ns.Shortkeys:Remove(e.key) end
                    RefreshAliasList()
                    return
                end
                if not ns.Shortkeys then return end
                local cs = e.charSpecific
                if cs == nil then
                    local d = ns.Aliases and ns.Aliases:FindEntryByKey(e.key)
                    cs = (d and ns.Shortkeys:IsCharacterSpecific(d)) or false
                end
                ns.Shortkeys:PromptForKeyByKey(e.key, e.name, cs)
            end)
            row.removeBtn:SetScript("OnClick", function()
                if ns.Aliases then ns.Aliases:RemoveByKey(e.key) end
                if ns.Shortkeys then ns.Shortkeys:Remove(e.key) end
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
    ns.RefreshShortkeyTable = RefreshAliasList

    clearAliasesBtn:SetScript("OnClick", function()
        ns.ShowThemedDialog({
            text = L["POPUP_CLEAR_ALIASES"],
            acceptText = _G["CLEAR"] or "Clear",
            onAccept = function()
                if ns.Aliases then ns.Aliases:ClearAll() end
                if ns.Shortkeys then ns.Shortkeys:ClearAll() end
                RefreshAliasList()
            end,
        })
    end)

    -- These two stay Blizzard StaticPopups for now: they chain (disable ->
    -- reload prompt) and use a custom decline label, pending a themed-dialog
    -- migration decision.
    StaticPopupDialogs["EASYFIND_DISABLE_MAP_SEARCH"] = {
        text = L["POPUP_DISABLE_MAP_SEARCH"] .. "\n\n" .. L["POPUP_DISABLE_MAP_SEARCH_DETAIL"],
        button1 = _G["DISABLE"] or "Disable",
        button2 = _G["CANCEL"] or "Cancel",
        OnAccept = function()
            EasyFind.db.enableMapSearch = false
            optionsFrame.UpdateMapToggleVisual()
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
        button2 = L["POPUP_BTN_LATER"],
        OnAccept = function() ReloadUI() end,
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
        Options:ConfirmResetAll()
    end)
    Utils.AttachDelayedTooltip(resetAllBtn, "ANCHOR_TOP", function()
        return L["OPT_RESET_ALL_SETTINGS"], L["OPT_RESET_ALL_TT_DESC"], L["OPT_RESET_ALL_TT_CMD"]
    end)

    local resetPosBtn = CreateModernButton(sec3)
    resetPosBtn:SetSize(RESET_BTN_W, 20)
    resetPosBtn:SetPoint("LEFT", resetAllBtn, "RIGHT", 8, 0)
    resetPosBtn:SetText(L["OPT_RESET_ALL_POSITIONS"])
    resetPosBtn:SetScript("OnClick", function()
        ShowResetConfirm(L["POPUP_RESET_ALL_POSITIONS"], function() Options:DoResetPositions() end)
    end)
    Utils.AttachDelayedTooltip(resetPosBtn, "ANCHOR_TOP", function()
        return L["OPT_RESET_ALL_POSITIONS"], L["OPT_RESET_POS_TT_DESC"], L["OPT_RESET_POS_TT_CMD"]
    end)

end

local function BuildFeedbackTab(ctx)
    local CreateTab, RESET_BTN_W = ctx.CreateTab, ctx.RESET_BTN_W
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
    Utils.AttachDelayedTooltip(bugBtn, "ANCHOR_TOP", function()
        return L["OPT_REPORT_BUG"], L["OPT_REPORT_BUG_TT_DESC"], L["OPT_REPORT_BUG_TT_CMD"]
    end)

    local featureBtn = CreateModernButton(feedbackTab)
    featureBtn:SetSize(RESET_BTN_W, 20)
    featureBtn:SetPoint("LEFT", bugBtn, "RIGHT", 12, 0)
    featureBtn:SetText(L["OPT_REQUEST_FEATURE"])
    featureBtn:SetScript("OnClick", function()
        EasyFind:OpenFeatureRequest()
    end)
    Utils.AttachDelayedTooltip(featureBtn, "ANCHOR_TOP", function()
        return L["OPT_REQUEST_FEATURE"], L["OPT_REQUEST_FEATURE_TT_DESC"], L["OPT_REQUEST_FEATURE_TT_CMD"]
    end)
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
    -- Escape closes the standalone window like every Blizzard panel.
    -- While embedded in the Settings canvas, CloseSpecialWindows hides
    -- both this frame and the Settings panel in the same pass.
    tinsert(UISpecialFrames, "EasyFindOptionsFrame")

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

    local closeBtn = ns.CreateCloseX(optionsFrame)
    closeBtn:SetPoint("TOPRIGHT", -10, -10)
    closeBtn:SetScript("OnClick", function() optionsFrame:Hide() end)
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


    local function FlashBindButton()
        local target = optionsFrame.toggleFocusBtn
        if not target then return end
        local glow = target.efBindGlow
        if not glow then
            glow = CreateFrame("Frame", nil, target)
            glow:SetPoint("TOPLEFT", target, "TOPLEFT", -3, 3)
            glow:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 3, -3)
            glow:SetFrameLevel(target:GetFrameLevel() + 4)
            local function MakeEdge()
                local edge = glow:CreateTexture(nil, "OVERLAY")
                edge:SetColorTexture(1, 0.82, 0, 1)
                return edge
            end
            local topEdge = MakeEdge()
            topEdge:SetPoint("TOPLEFT"); topEdge:SetPoint("TOPRIGHT"); topEdge:SetHeight(2)
            local bottomEdge = MakeEdge()
            bottomEdge:SetPoint("BOTTOMLEFT"); bottomEdge:SetPoint("BOTTOMRIGHT"); bottomEdge:SetHeight(2)
            local leftEdge = MakeEdge()
            leftEdge:SetPoint("TOPLEFT"); leftEdge:SetPoint("BOTTOMLEFT"); leftEdge:SetWidth(2)
            local rightEdge = MakeEdge()
            rightEdge:SetPoint("TOPRIGHT"); rightEdge:SetPoint("BOTTOMRIGHT"); rightEdge:SetWidth(2)
            local pulse = glow:CreateAnimationGroup()
            for i = 1, 3 do
                local up = pulse:CreateAnimation("Alpha")
                up:SetFromAlpha(0); up:SetToAlpha(1); up:SetDuration(0.22); up:SetOrder(i * 2 - 1)
                local down = pulse:CreateAnimation("Alpha")
                down:SetFromAlpha(1); down:SetToAlpha(0); down:SetDuration(0.22); down:SetOrder(i * 2)
            end
            pulse:SetScript("OnFinished", function() glow:Hide() end)
            glow.pulse = pulse
            target.efBindGlow = glow
        end
        glow.pulse:Stop()
        glow:SetAlpha(0)
        glow:Show()
        glow.pulse:Play()
    end

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
        content.tabIndex = index
        tinsert(tabFrames, content)

        return content
    end

    -- Standalone "Tutorial" entry pinned to the sidebar bottom. Not a tab:
    -- it closes the panel and opens the tutorial wizard, same as the
    -- {L:tutorial} link on the Home page, and wears the same link blue.
    local tutorialBtn = CreateFrame("Button", nil, sidebar)
    tutorialBtn:SetSize(SIDEBAR_W - 16, 28)
    tutorialBtn:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 8, 8)
    ns.CreateRoundedRectBorder(tutorialBtn)
    ns.SetRoundedRectBarHeight(tutorialBtn, 10)
    ns.SetRoundedRectBorderBgAlpha(tutorialBtn, 0)
    HideRoundedBorder(tutorialBtn)
    SetNavButtonBg(tutorialBtn, NAV_CLEAR)
    local TUTORIAL_LINK_COLOR = ns.LINK_COLOR or { 0.44, 0.84, 1.0 }
    local TUTORIAL_LINK_HOVER = ns.LINK_HOVER or { 1, 1, 1 }
    local tutorialLabel = tutorialBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tutorialLabel:SetPoint("LEFT", tutorialBtn, "LEFT", 10, 0)
    tutorialLabel:SetPoint("RIGHT", tutorialBtn, "RIGHT", -10, 0)
    tutorialLabel:SetJustifyH("LEFT")
    tutorialLabel:SetText(L["OPT_TAB_TUTORIAL"])
    tutorialLabel:SetTextColor(TUTORIAL_LINK_COLOR[1], TUTORIAL_LINK_COLOR[2], TUTORIAL_LINK_COLOR[3], 1)
    tutorialBtn:SetScript("OnEnter", function(self)
        SetNavButtonBg(self, NAV_HOVER)
        tutorialLabel:SetTextColor(TUTORIAL_LINK_HOVER[1], TUTORIAL_LINK_HOVER[2], TUTORIAL_LINK_HOVER[3], 1)
    end)
    tutorialBtn:SetScript("OnLeave", function(self)
        SetNavButtonBg(self, NAV_CLEAR)
        tutorialLabel:SetTextColor(TUTORIAL_LINK_COLOR[1], TUTORIAL_LINK_COLOR[2], TUTORIAL_LINK_COLOR[3], 1)
    end)
    tutorialBtn:SetScript("OnClick", function()
        optionsFrame:Hide()
        if ns.Wizard and ns.Wizard.Show then ns.Wizard:Show(ns.Wizard.FEATURES_PAGE) end
    end)

    local function GetCurrentKeybindText(action)
        -- Account store only; see SyncOptionControls for why native
        -- bindings are ignored for EasyFind's own actions.
        return EasyFind:GetAccountKeybind(action) or (_G["NOT_BOUND"] or "Not Bound")
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
                local combo = Utils.CaptureKeybindCombo(key)
                if not combo then return end
                if combo == "stop" then
                    StopCapture(self, action)
                    return
                end
                EasyFind:SetAccountKeybind(action, combo)
                StopCapture(self, action)
            end)
        end
    end

    local function MakeKeybindTooltip(keybindBtn, titleText, line1)
        Utils.AttachDelayedTooltip(keybindBtn, "ANCHOR_RIGHT", function()
            return titleText, line1, L["OPT_KB_CLEAR_HINT"]
        end)
    end

    local SELECTOR_ROW_W = FRAME_W - 16
    local SELECTOR_BTN_W = 170

    -- Flyout-dropdown version of a preset row: same {label,value} choices and
    -- getter/setter as CreatePresetRow, but a single dropdown (like the indicator
    -- selector) instead of a button row. globalPrefix names the flyout frames and
    -- must be unique. Returns the row, which carries :SetValue for refresh.
    local function CreateFlyoutPresetRow(parent, labelText, choices, getter, setter, globalPrefix, defaultValue, tooltipText)
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(SELECTOR_ROW_W, 24)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -SELECTOR_BTN_W - 18, 0)
        label:SetJustifyH("LEFT")
        label:SetTextColor(Utils.RGB(NORMAL_TEXT, 1))
        label:SetText(labelText)

        local function LabelFor(value)
            for _, c in ipairs(choices) do
                if c.value == value then return c.label end
            end
            return tostring(value)
        end

        -- The default choice is tagged "(Default)" inside the flyout only;
        -- the button always shows the bare label, even when default is picked.
        local function FlyoutLabelFor(value)
            if defaultValue ~= nil and value == defaultValue then
                return LabelFor(value) .. " (" .. (_G["DEFAULT"] or "Default") .. ")"
            end
            return LabelFor(value)
        end
        local btnFrame, btnText = CreateFlyoutSelector(row, globalPrefix, SELECTOR_BTN_W, label, LabelFor(getter()))
        local values = {}
        for i = 1, #choices do values[i] = choices[i].value end
        local flyout = CreateFlyoutPanel(btnFrame, globalPrefix, SELECTOR_BTN_W, #values)
        AddFlyoutOptions(flyout, values, SELECTOR_BTN_W - 6, function(value)
            setter(value)
            btnText:SetText(LabelFor(value))
        end, FlyoutLabelFor)

        if tooltipText then
            row:EnableMouse(true)
            Utils.AttachDelayedTooltip(row, "ANCHOR_RIGHT", function()
                return labelText, tooltipText
            end)
            Utils.AttachDelayedTooltip(btnFrame, "ANCHOR_RIGHT", function()
                return labelText, tooltipText
            end)
        end

        row.flyout = flyout
        row.SetValue = function(self, value) btnText:SetText(LabelFor(value)) end
        return row
    end
    local RESET_BTN_W = 120


    local ctx = {
        CreateTab = CreateTab, SwitchToTab = SwitchToTab,
        FRAME_W = FRAME_W, COL_LEFT = COL_LEFT,
        FlashBindButton = FlashBindButton,
        GetCurrentKeybindText = GetCurrentKeybindText,
        MakeKeybindTooltip = MakeKeybindTooltip, StartCapture = StartCapture,
        SELECTOR_ROW_W = SELECTOR_ROW_W, SELECTOR_BTN_W = SELECTOR_BTN_W,
        CreateFlyoutPresetRow = CreateFlyoutPresetRow,
        RESET_BTN_W = RESET_BTN_W,
    }
    BuildHomeTab(ctx)
    BuildGeneralBindsTab(ctx)
    BuildSearchTab(ctx)
    BuildMapTab(ctx)
    BuildShortcutsTab(ctx)
    BuildAliasesTab(ctx)
    BuildFeedbackTab(ctx)

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

function Options:ConfirmResetAll()
    ShowResetConfirm(L["POPUP_RESET_ALL_SETTINGS"], function() Options:DoResetAll() end)
end

function Options:ConfirmResetPositions()
    ShowResetConfirm(L["POPUP_RESET_ALL_POSITIONS"], function() Options:DoResetPositions() end)
end

function Options:DoResetAll()
    local needsReload = EasyFind.db.enableMapSearch == false
    EasyFind:ResetSettingsToDefaults()
    if EasyFind.ResetAccountKeybindsToDefaults then
        EasyFind:ResetAccountKeybindsToDefaults()
    end
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
    ApplyDefaultKeys(MAP_RESET_KEYS)
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
        optionsFrame:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -10)
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

function Options:OpenAtAliases()
    self:Show()
    if optionsFrame and optionsFrame.SwitchToTab and self._aliasesTabIndex then
        optionsFrame.SwitchToTab(self._aliasesTabIndex)
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
