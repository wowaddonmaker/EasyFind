local _, ns = ...

local Search = ns.Search
local Calculator = ns.Calculator
local Results = ns.Results
local Rows = ns.ResultRows
local Shortcuts = ns.ResultShortcuts
local L = ns.L

local CreateFrame = CreateFrame

local RESULT_SHORTCUT = Shortcuts.RESULT_SHORTCUT

function Rows.CreateCalculatorWidgets(resultRow, index)
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
    calcExpressionHint:SetText(L["CALC_COPY_HINT"])
    calcExpressionHint:SetJustifyH("CENTER")
    calcExpressionHint:SetTextColor(0.72, 0.72, 0.72, 1.0)
    calcExpressionHint:SetPoint("TOP", calcExpressionText, "BOTTOM", 0, -1)
    calcExpressionHint:Hide()
    resultRow.calcExpressionHint = calcExpressionHint

    local calcResultHint = calcCard:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    calcResultHint:SetText(L["CALC_COPY_HINT"])
    calcResultHint:SetJustifyH("CENTER")
    calcResultHint:SetTextColor(0.72, 0.72, 0.72, 1.0)
    calcResultHint:SetPoint("TOP", calcResultText, "BOTTOM", 0, -1)
    calcResultHint:Hide()
    resultRow.calcResultHint = calcResultHint

    local calcExpressionButton = CreateFrame("Button", nil, calcCard)
    calcExpressionButton:RegisterForClicks("LeftButtonUp")
    calcExpressionButton:SetFrameLevel(resultRow:GetFrameLevel() + 10)
    calcExpressionButton:SetScript("OnEnter", function()
        Calculator:HoverCalculatorTarget(resultRow, "expression")
    end)
    calcExpressionButton:SetScript("OnLeave", function()
        Calculator:RestoreCalculatorTarget(resultRow)
    end)
    calcExpressionButton:SetScript("OnClick", function()
        Search:SetSelectedIndex(index)
        Search:SetToggleFocused(false)
        Results:UpdateSelectionHighlight(true)
        Calculator:ArmCalculatorPartFromRow(resultRow, "expression", "click")
    end)
    calcExpressionButton:Hide()
    resultRow.calcExpressionButton = calcExpressionButton

    local calcResultButton = CreateFrame("Button", nil, calcCard)
    calcResultButton:RegisterForClicks("LeftButtonUp")
    calcResultButton:SetFrameLevel(resultRow:GetFrameLevel() + 10)
    calcResultButton:SetScript("OnEnter", function()
        Calculator:HoverCalculatorTarget(resultRow, "result")
    end)
    calcResultButton:SetScript("OnLeave", function()
        Calculator:RestoreCalculatorTarget(resultRow)
    end)
    calcResultButton:SetScript("OnClick", function()
        Search:SetSelectedIndex(index)
        Search:SetToggleFocused(false)
        Results:UpdateSelectionHighlight(true)
        Calculator:ArmCalculatorPartFromRow(resultRow, "result", "click")
    end)
    calcResultButton:Hide()
    resultRow.calcResultButton = calcResultButton

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
    Shortcuts:LayoutResultShortcut(resultRow)

end

