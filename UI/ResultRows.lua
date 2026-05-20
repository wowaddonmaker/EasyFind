local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils
local UIPins = ns.UIPins

local select = Utils.select
local sformat = Utils.sformat
local mfloor = Utils.mfloor

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = GameTooltip
local UIParent = UIParent
local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown

local REP_BAR_WIDTH = 100
local RESULT_SHORTCUT = UI.RESULT_SHORTCUT
local IsUIItemPinned = UIPins.IsPinned
local PinUIItem = UIPins.Pin
local UnpinUIItem = UIPins.Unpin

local INDENT_COLORS = {
    {0.40, 0.85, 1.00, 0.80},
    {1.00, 0.55, 0.10, 0.80},
    {0.55, 1.00, 0.35, 0.80},
    {1.00, 0.40, 0.70, 0.80},
    {0.70, 0.55, 1.00, 0.80},
    {1.00, 0.90, 0.20, 0.80},
}
local INDENT_PX  = 20
local LINE_X_OFF = 10
local LINE_W     = 2
local MAX_DEPTH  = 0
local outfitCdStart, outfitCdDuration = 0, 0
local lastEquippedOutfitID

function UI:GetOutfitCooldownState()
    return outfitCdStart, outfitCdDuration, lastEquippedOutfitID
end

function UI:IsOutfitCooldownActive()
    return outfitCdStart > 0 and outfitCdDuration - (GetTime() - outfitCdStart) > 0
end

local function ResultsFrame()
    return UI:GetResultsFrame()
end

local function CollapsedNodes()
    return UI._collapsedNodes
end


local function AnchorTooltipAtCursor(tooltip, ownerFrame)
    return UI:AnchorTooltipAtCursor(tooltip, ownerFrame)
end

local function AnchorGearTooltip(tooltip, ownerFrame)
    return UI:AnchorGearTooltip(tooltip, ownerFrame)
end

local function GetUnearnedTooltip()
    return UI:GetUnearnedTooltip()
end
local function RefocusSearchEditBox()
    if UI:GetSearchFrame() and UI:GetSearchFrame().editBox
       and not (UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled()) then
        UI:GetSearchFrame().editBox.blockFocus = nil
        UI:GetSearchFrame().editBox:SetFocus()
    end
end
function UI:RefocusSearchEditBox() RefocusSearchEditBox() end

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
    -- Booleans need explicit "1"/"0": tostring(true) gives "true", which
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

function UI:ReadSettingVariable(variable)
    return ReadSettingVariable(variable)
end

function UI:WriteSettingVariable(variable, value)
    return WriteSettingVariable(variable, value)
end
local function ActivateSettingResult(data, ctrlHeld)
    if not data or not data.settingVariable then return false end
    local stype = data.settingType
    if (stype == "checkbox" or stype == "checkboxSlider") and not ctrlHeld then
        -- Plain click toggles inline. Ctrl+click falls through to open
        -- the in-game Settings panel for the same variable. For
        -- checkboxSlider, the cb variable lives at data.settingVariable
        -- so the existing toggle path Just Works.
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

function UI:ActivateSettingResult(data, ctrlHeld)
    return ActivateSettingResult(data, ctrlHeld)
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
    radio:SetTexture("Interface\\AddOns\\EasyFind\\Images\\radio-off")
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
    local cur = getCurrent and getCurrent() or nil
    for i = 1, #opts do
        local opt = opts[i]
        local row = GetInlineDropdownRow(popup, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 6, -PAD_TOP - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", popup, "RIGHT", -6, 0)
        row.lbl:SetText(opt.label or tostring(opt.value))
        local checked = cur == opt.value or tostring(cur) == tostring(opt.value)
        row.radio:SetTexture(checked and "Interface\\AddOns\\EasyFind\\Images\\radio-on" or "Interface\\AddOns\\EasyFind\\Images\\radio-off")
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

function UI:CreateResultButton(index)
    local scrollChild = ResultsFrame().scrollChild
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

    resultRow.treeVert   = {}
    resultRow.treeBranch = {}
    resultRow.treeElbow  = {}

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

    local calcCard = CreateFrame("Frame", nil, resultRow)
    ns.CreateRoundedRectBorder(calcCard)
    ns.SetRoundedRectBarHeight(calcCard, 12)
    ns.SetRoundedRectBorderFillColor(calcCard, 0.095, 0.095, 0.108, 1)
    ns.SetRoundedRectBorderColor(calcCard, 0.34, 0.34, 0.36, 0.92)
    calcCard:Hide()
    resultRow.calcCard = calcCard

    local calcDivider = calcCard:CreateTexture(nil, "ARTWORK")
    calcDivider:SetColorTexture(0.30, 0.30, 0.32, 0)
    calcDivider:SetWidth(1)
    resultRow.calcDivider = calcDivider

    local calcDividerTop = calcCard:CreateTexture(nil, "ARTWORK")
    calcDividerTop:SetColorTexture(0.34, 0.34, 0.36, 0.86)
    calcDividerTop:SetWidth(1)
    calcDividerTop:Hide()
    resultRow.calcDividerTop = calcDividerTop

    local calcDividerBottom = calcCard:CreateTexture(nil, "ARTWORK")
    calcDividerBottom:SetColorTexture(0.34, 0.34, 0.36, 0.86)
    calcDividerBottom:SetWidth(1)
    calcDividerBottom:Hide()
    resultRow.calcDividerBottom = calcDividerBottom

    local calcExpressionHighlight = calcCard:CreateTexture(nil, "BORDER")
    calcExpressionHighlight:SetColorTexture(1.0, 0.82, 0.22, 0.20)
    calcExpressionHighlight:Hide()
    resultRow.calcExpressionHighlight = calcExpressionHighlight

    local calcResultHighlight = calcCard:CreateTexture(nil, "BORDER")
    calcResultHighlight:SetColorTexture(1.0, 0.82, 0.22, 0.20)
    calcResultHighlight:Hide()
    resultRow.calcResultHighlight = calcResultHighlight

    local calcExpressionFlash = calcCard:CreateTexture(nil, "OVERLAY")
    calcExpressionFlash:SetColorTexture(0.48, 1.0, 0.62, 0.35)
    calcExpressionFlash:Hide()
    calcExpressionFlash.anim = calcExpressionFlash:CreateAnimationGroup()
    local expressionFlashAlpha = calcExpressionFlash.anim:CreateAnimation("Alpha")
    expressionFlashAlpha:SetFromAlpha(0.42)
    expressionFlashAlpha:SetToAlpha(0)
    expressionFlashAlpha:SetDuration(0.42)
    expressionFlashAlpha:SetSmoothing("OUT")
    calcExpressionFlash.anim:SetScript("OnFinished", function()
        calcExpressionFlash:Hide()
    end)
    resultRow.calcExpressionFlash = calcExpressionFlash

    local calcResultFlash = calcCard:CreateTexture(nil, "OVERLAY")
    calcResultFlash:SetColorTexture(0.48, 1.0, 0.62, 0.35)
    calcResultFlash:Hide()
    calcResultFlash.anim = calcResultFlash:CreateAnimationGroup()
    local resultFlashAlpha = calcResultFlash.anim:CreateAnimation("Alpha")
    resultFlashAlpha:SetFromAlpha(0.42)
    resultFlashAlpha:SetToAlpha(0)
    resultFlashAlpha:SetDuration(0.42)
    resultFlashAlpha:SetSmoothing("OUT")
    calcResultFlash.anim:SetScript("OnFinished", function()
        calcResultFlash:Hide()
    end)
    resultRow.calcResultFlash = calcResultFlash

    local calcExpressionText = calcCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    calcExpressionText:SetJustifyH("CENTER")
    calcExpressionText:SetWordWrap(false)
    calcExpressionText:SetTextColor(0.96, 0.96, 0.96, 1.0)
    resultRow.calcExpressionText = calcExpressionText

    local calcArrowText = calcCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    calcArrowText:SetText("=")
    calcArrowText:SetTextColor(0.86, 0.86, 0.86, 1.0)
    resultRow.calcArrowText = calcArrowText

    local calcResultText = calcCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    calcResultText:SetJustifyH("CENTER")
    calcResultText:SetWordWrap(false)
    calcResultText:SetTextColor(0.96, 0.96, 0.96, 1.0)
    resultRow.calcResultText = calcResultText

    local calcExpressionHint = calcCard:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcExpressionHint:SetText("Ctrl+C to copy")
    calcExpressionHint:SetJustifyH("CENTER")
    calcExpressionHint:SetTextColor(0.72, 0.72, 0.72, 1.0)
    calcExpressionHint:SetPoint("TOP", calcExpressionText, "BOTTOM", 0, -1)
    calcExpressionHint:Hide()
    resultRow.calcExpressionHint = calcExpressionHint

    local calcResultHint = calcCard:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcResultHint:SetText("Ctrl+C to copy")
    calcResultHint:SetJustifyH("CENTER")
    calcResultHint:SetTextColor(0.72, 0.72, 0.72, 1.0)
    calcResultHint:SetPoint("TOP", calcResultText, "BOTTOM", 0, -1)
    calcResultHint:Hide()
    resultRow.calcResultHint = calcResultHint

    local calcExpressionButton = CreateFrame("Button", nil, calcCard)
    calcExpressionButton:RegisterForClicks("LeftButtonUp")
    calcExpressionButton:SetFrameLevel(resultRow:GetFrameLevel() + 10)
    calcExpressionButton:SetScript("OnEnter", function()
        UI:HoverCalculatorTarget(resultRow, "expression")
    end)
    calcExpressionButton:SetScript("OnLeave", function()
        UI:RestoreCalculatorTarget(resultRow)
    end)
    calcExpressionButton:SetScript("OnClick", function()
        UI:SetSelectedIndex(index)
        UI:SetToggleFocused(false)
        UI:UpdateSelectionHighlight(true)
        UI:ArmCalculatorPartFromRow(resultRow, "expression", "click")
    end)
    calcExpressionButton:Hide()
    resultRow.calcExpressionButton = calcExpressionButton

    local calcResultButton = CreateFrame("Button", nil, calcCard)
    calcResultButton:RegisterForClicks("LeftButtonUp")
    calcResultButton:SetFrameLevel(resultRow:GetFrameLevel() + 10)
    calcResultButton:SetScript("OnEnter", function()
        UI:HoverCalculatorTarget(resultRow, "result")
    end)
    calcResultButton:SetScript("OnLeave", function()
        UI:RestoreCalculatorTarget(resultRow)
    end)
    calcResultButton:SetScript("OnClick", function()
        UI:SetSelectedIndex(index)
        UI:SetToggleFocused(false)
        UI:UpdateSelectionHighlight(true)
        UI:ArmCalculatorPartFromRow(resultRow, "result", "click")
    end)
    calcResultButton:Hide()
    resultRow.calcResultButton = calcResultButton

    local calcActionBar = CreateFrame("Button", nil, resultRow)
    calcActionBar:RegisterForClicks("LeftButtonUp")
    calcActionBar:SetFrameLevel(resultRow:GetFrameLevel() + 10)
    self:StyleCalculatorButton(calcActionBar, 22)
    calcActionBar:SetScript("OnClick", function()
        UI:SetSelectedIndex(index)
        UI:SetToggleFocused(false)
        UI:UpdateSelectionHighlight(true)
        local data = resultRow.data
        UI:OpenCalculator(data and data.calculatorExpression or nil)
    end)
    calcActionBar:Hide()
    resultRow.calcActionBar = calcActionBar

    local calcActionIcon = calcActionBar:CreateTexture(nil, "ARTWORK")
    calcActionIcon:SetSize(15, 15)
    calcActionIcon:SetPoint("LEFT", calcActionBar, "LEFT", 8, 0)
    calcActionIcon:SetTexture("Interface\\AddOns\\EasyFind\\textures\\calculator-icon")
    calcActionIcon:SetTexCoord(0, 1, 0, 1)
    resultRow.calcActionIcon = calcActionIcon

    local calcActionTitle = calcActionBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    calcActionTitle:SetPoint("LEFT", calcActionIcon, "RIGHT", 7, 0)
    calcActionTitle:SetJustifyH("LEFT")
    calcActionTitle:SetText("Calculator")
    calcActionTitle:SetTextColor(0.96, 0.96, 0.96, 1)
    calcActionTitle:SetWordWrap(false)
    if calcActionTitle.SetMaxLines then calcActionTitle:SetMaxLines(1) end
    resultRow.calcActionTitle = calcActionTitle

    local calcActionDesc = calcActionBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcActionDesc:SetPoint("LEFT", calcActionTitle, "RIGHT", 5, 0)
    calcActionDesc:SetText("")
    calcActionDesc:SetTextColor(0.58, 0.58, 0.60, 1)
    calcActionDesc:SetWordWrap(false)
    if calcActionDesc.SetMaxLines then calcActionDesc:SetMaxLines(1) end
    calcActionDesc:Hide()
    resultRow.calcActionDesc = calcActionDesc

    local calcActionAfter = calcActionBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcActionAfter:SetPoint("RIGHT", calcActionBar, "RIGHT", -10, 0)
    calcActionAfter:SetText("to open")
    calcActionAfter:SetTextColor(0.58, 0.58, 0.60, 1)
    calcActionAfter:SetWordWrap(false)
    if calcActionAfter.SetMaxLines then calcActionAfter:SetMaxLines(1) end
    resultRow.calcActionAfter = calcActionAfter

    local calcActionKeyCap = CreateFrame("Frame", nil, calcActionBar)
    calcActionKeyCap:SetSize(38, 15)
    calcActionKeyCap:SetPoint("RIGHT", calcActionAfter, "LEFT", -6, 0)
    ns.CreateRoundedRectBorder(calcActionKeyCap)
    ns.SetRoundedRectBarHeight(calcActionKeyCap, 7)
    ns.SetRoundedRectBorderBgAlpha(calcActionKeyCap, 1)
    self:SetCalculatorRoundedFill(calcActionKeyCap, 0.13, 0.13, 0.15, 1, 0.30, 0.30, 0.32, 0.95)
    resultRow.calcActionKeyCap = calcActionKeyCap

    local calcActionKey = calcActionKeyCap:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcActionKey:SetPoint("CENTER")
    calcActionKey:SetText("Alt+C")
    calcActionKey:SetTextColor(0.86, 0.86, 0.88, 1)
    calcActionKey:SetWordWrap(false)
    if calcActionKey.SetMaxLines then calcActionKey:SetMaxLines(1) end
    resultRow.calcActionKey = calcActionKey

    local shortcutGroup = CreateFrame("Frame", nil, resultRow)
    shortcutGroup:Hide()
    resultRow.shortcutGroup = shortcutGroup

    local shortcutAltIcon = shortcutGroup:CreateTexture(nil, "OVERLAY")
    shortcutAltIcon:SetTexture(RESULT_SHORTCUT.icon)
    shortcutAltIcon:SetSize(RESULT_SHORTCUT.iconSize, RESULT_SHORTCUT.iconSize)
    shortcutAltIcon:SetVertexColor(0.58, 0.58, 0.58, 0.85)
    resultRow.shortcutAltIcon = shortcutAltIcon

    local shortcutNumberText = shortcutGroup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    shortcutNumberText:SetJustifyH("RIGHT")
    shortcutNumberText:SetTextColor(0.58, 0.58, 0.58, 0.85)
    shortcutNumberText:SetText("")
    resultRow.shortcutNumberText = shortcutNumberText
    self:LayoutResultShortcut(resultRow)

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
        if not (UI:GetSearchFrame() and UI:GetSearchFrame().editBox) then return end
        if UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled() then return end
        UI:GetSearchFrame().editBox.blockFocus = nil
        UI:GetSearchFrame().editBox:SetFocus()
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
        if UI:GetActiveKeybindButton() == btn then UI:SetActiveKeybindButton(nil) end
        if btn._refresh then btn._refresh() end
        -- Defer the editbox re-enable + refocus to next frame: the
        -- captured key's OnChar event still has to fire after this
        -- OnKeyDown handler returns, and refocusing now would let the
        -- into the search bar). Letting the disabled editbox swallow
        -- the OnChar first prevents the leak.
        Utils.SafeAfter(0, function()
            if UI:GetSearchFrame() and UI:GetSearchFrame().editBox then
                UI:GetSearchFrame().editBox:SetEnabled(true)
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
        local activeKeybindBtn = UI:GetActiveKeybindButton()
        if activeKeybindBtn and activeKeybindBtn ~= btn then
            StopKeybindCapture(activeKeybindBtn)
        end
        UI:SetActiveKeybindButton(btn)
        btn._waitingForKey = true
        btn:SetText("Press a key...")
        btn:LockHighlight()
        if UI:GetSearchFrame() and UI:GetSearchFrame().editBox then
            UI:GetSearchFrame().editBox.blockFocus = true
            UI:GetSearchFrame().editBox:ClearFocus()
            UI:GetSearchFrame().editBox:SetEnabled(false)
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
        -- Toggle: a second click on the same button closes the
        -- already-open popup instead of re-opening it.
        if inlineDropdownPopup and inlineDropdownPopup:IsShown()
           and inlineDropdownPopup.owner == self then
            inlineDropdownPopup:Hide()
            return
        end
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
    local function bothVars(d)
        if not d then return nil, nil end
        local primary = d.settingVariable
        local secondary
        if d.sliderVariable and d.sliderVariable ~= primary then
            secondary = d.sliderVariable
        end
        return primary, secondary
    end
    applyBtn:SetScript("OnClick", function()
        if not ns.BlizzOptionsSearch or not ns.BlizzOptionsSearch.ApplyVariable then return end
        local primary, secondary = bothVars(resultRow.data)
        if primary then ns.BlizzOptionsSearch:ApplyVariable(primary) end
        if secondary then ns.BlizzOptionsSearch:ApplyVariable(secondary) end
        UI:RefreshResults()
        RefocusSearchEditBox()
    end)
    resetBtn:SetScript("OnClick", function()
        if not ns.BlizzOptionsSearch or not ns.BlizzOptionsSearch.RevertVariable then return end
        local primary, secondary = bothVars(resultRow.data)
        if primary then ns.BlizzOptionsSearch:RevertVariable(primary) end
        if secondary then ns.BlizzOptionsSearch:RevertVariable(secondary) end
        UI:RefreshResults()
        RefocusSearchEditBox()
    end)
    resultRow.settingApplyExt = applyExt
    resultRow.settingApplyExtH = APPLY_EXT_H

    -- Right-aligned reputation standing bar
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

    local repClip = CreateFrame("Frame", nil, repBar)
    repClip:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repClip:SetPoint("BOTTOMLEFT", repBar, "BOTTOMLEFT", 0, 0)
    repClip:SetWidth(REP_BAR_WIDTH)
    repClip:SetClipsChildren(true)
    resultRow.repClip = repClip

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
    -- does nothing, matches Blizzard's action-bar drag feel.
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
        -- happens via the OnMouseDown / OnUpdate drag detection above:
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

        -- Ctrl + secure action: suppress the default activation so
        -- PostClick can reveal the owning Blizzard UI instead.
        if d and IsControlKeyDown()
           and (d.macroIndex or d.mountID or d.toyItemID or d.outfitID
                or (d.itemID and d.category == "Bag")) then
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
           and not (IsControlKeyDown and IsControlKeyDown())
           and outfitCdStart > 0
           and outfitCdDuration - (GetTime() - outfitCdStart) > 0 then
            if UI:GetSearchFrame() and UI:GetSearchFrame().editBox and not UI:GetNavFrame():IsKeyboardEnabled() then
                UI:GetSearchFrame().editBox.blockFocus = nil
                UI:GetSearchFrame().editBox:SetFocus()
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
            if self.data.calculatorResult or self.data.quickFilterDef then return end
            local pinData = self.data
            local isPinned = IsUIItemPinned(pinData)
            local hasGuide = pinData.steps or pinData.transmogSetID
                or (pinData.category == "Loot" and pinData.itemID)
                or pinData.petID or pinData.speciesID
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
                    onTrack = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:ToggleAchievementTracked(achID)
                    end,
                }
            elseif pinData.category == "Currency" and pinData.currencyID then
                local cid = pinData.currencyID
                extra = {
                    isOnBackpack = UI:IsCurrencyOnBackpack(cid),
                    onToggleBackpack = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:ToggleCurrencyBackpack(cid)
                    end,
                }
                if UI:IsCurrencyTransferable(cid) then
                    extra.onTransfer = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:RouteCurrencyTransfer(pinData)
                    end
                end
            elseif pinData.transmogSetID then
                local sid = pinData.transmogSetID
                extra = {
                    isFavorite = UI:IsTransmogSetFavorite(sid),
                    onToggleFavorite = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:ToggleTransmogSetFavorite(sid)
                    end,
                }
            elseif pinData.petID then
                local pid = pinData.petID
                local cageable = UI:IsPetCageable(pid)
                extra = {
                    onSummon = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:SummonPet(pid)
                    end,
                    onRename = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:RenamePet(pid)
                    end,
                    isFavorite = UI:IsPetFavorite(pid),
                    onToggleFavorite = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        UI:TogglePetFavorite(pid)
                    end,
                    onCageOrRelease = function()
                        UI:KeepPinnedResultsOpenBriefly()
                        if cageable then UI:CagePet(pid) else UI:ReleasePet(pid) end
                    end,
                    isCageable = cageable,
                }
            end
            UI:ShowPinPopup(self, isPinned, function()
                if isPinned then
                    UnpinUIItem(pinData)
                else
                    PinUIItem(pinData)
                end
                local editBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
                local text = editBox and editBox:GetText() or ""
                if text == "" then
                    local pinsRemain = UI:KeepPinnedResultsOpenBriefly()
                    UI:ShowPinnedItems()
                    if pinsRemain and editBox
                       and not (UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled()) then
                        editBox.blockFocus = nil
                        editBox:SetFocus()
                    end
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
                local cursorX = GetCursorPosition()
                local scale = self:GetEffectiveScale()
                local btnLeft = self:GetLeft() * scale
                local depth = self.pathNodeDepth or 0
                local iconLeft = btnLeft + depth * 20 * scale  -- INDENT_PX = 20
                local isToggleClick = cursorX <= (iconLeft + 35 * scale)

                if isToggleClick then
                    local key = (self.pathNodeName or "") .. "_" .. (self.pathNodeDepth or 0)
                    CollapsedNodes()[key] = not CollapsedNodes()[key]
                    if UI._cachedHierarchical then
                        UI:ShowHierarchicalResults(UI._cachedHierarchical, true)
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
        UI:ApplyActionHint(self)
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
            if GetUnearnedTooltip() then
                local tooltipText = self.isPathNode and "This tab does not exist on this character yet" or "Currency not yet earned"
                GetUnearnedTooltip().text:SetText(tooltipText)
                local textWidth = GetUnearnedTooltip().text:GetStringWidth()
                local textHeight = GetUnearnedTooltip().text:GetStringHeight()
                GetUnearnedTooltip():SetSize(textWidth + 20, textHeight + 16)
                local scale = UIParent:GetEffectiveScale()
                local x, y = GetCursorPosition()
                GetUnearnedTooltip():ClearAllPoints()
                GetUnearnedTooltip():SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 10, y / scale + 10)
                GetUnearnedTooltip():Show()
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
            -- gear. The entry being a "Bag" by category is incidental
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
            elseif self.icon.lootItemID then
                AnchorGearTooltip(GameTooltip, self)
                local itemLink = self.data and ns.Database and ns.Database:GetLootItemLink(self.data)
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(self.icon.lootItemID)
                end
                GameTooltip:Show()
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
        if GetUnearnedTooltip() then
            GetUnearnedTooltip():Hide()
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
        if self.data and self.data.mapSearchResult and ns.MapSearch and ns.MapSearch.ClearUIPreview then
            ns.MapSearch:ClearUIPreview()
        end
        if UI:IsActionHintRow(self) then
            UI:ClearActionHint()
            local selRow = UI:GetSelectedIndex() > 0 and UI:GetResultButtons()[UI:GetSelectedIndex()] or nil
            if selRow and selRow ~= self and not UI:GetToggleFocused() then
                UI:ApplyActionHint(selRow)
            end
        end
    end)

    UI:ApplyResultRowFonts(resultRow)
    resultRow:Hide()
    return resultRow
end

-- Prepend `text` to EasyFindDB.uiSearchHistory, dedupe by removing
-- any prior occurrence (case-insensitive) and trim to the configured
-- limit. The most recent search lives at index 1.
