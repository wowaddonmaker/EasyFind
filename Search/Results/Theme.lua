local _, ns = ...

local Results = ns.Results
local Shortcuts = ns.ResultShortcuts
local Utils = ns.Utils

local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local THEMES = {}

function Results:ApplySearchWindowFill(frame)
    if not frame then return end
    ns.SetRoundedRectBorderFillColor(frame, Utils.RGB(ns.SEARCH_WINDOW_FILL_COLOR, 1))
end

THEMES["Modern"] = {
    rowHeight       = 20,
    indentPx        = 20,
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
    pathColor       = {0.65, 0.60, 0.55, 1.0},
    pathColorHover  = {1.0, 1.0, 1.0, 1.0},
    leafColor       = {0.9, 0.9, 0.9},
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
    headerTabAtlas  = "QuestLog-tab",
    headerHighlightAlpha = 0.40,
    expandAtlas     = "QuestLog-icon-expand",
    collapseAtlas   = "QuestLog-icon-shrink",
    toggleNormalAlpha = 0.60,
    toggleHoverAlpha  = 1.0,
    showSeparators  = false,
    separatorColor  = {0.5, 0.45, 0.3, 0.35},
    resultsBackdrop = {
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    },
    resultsBgAtlas          = "QuestLog-main-background",
    resultsBackdropColor       = {0.12, 0.10, 0.08, 0.95},
    resultsBackdropBorderColor = {0.50, 0.48, 0.45, 1.0},
    searchBarRounded = true,
}

function Results:GetActiveTheme()
    return THEMES["Modern"]
end

local function ScaleFont(fontString, baseFontObject)
    if not fontString then return end
    local obj = _G[baseFontObject]
    if not obj then return end
    local path, baseSize, flags = obj:GetFont()
    if ns.GetAddonFontPath then
        path = ns.GetAddonFontPath(nil, path)
    end
    local size = baseSize * (EasyFind.db.fontSize or 1.0)
    -- SetFont re-rasterizes and runs ~13x per row per render (per keystroke).
    -- Font and size are stable between keystrokes, so skip the call when the
    -- fontstring already carries the exact font: with a custom TTF selected,
    -- the redundant per-render SetFont storm is a real typing hitch.
    local curPath, curSize, curFlags = fontString:GetFont()
    if curPath ~= path or curSize ~= size or (curFlags or "") ~= (flags or "") then
        fontString:SetFont(path, size, flags)
    end
end

function Results:ScaleFont(fontString, baseFontObject)
    return ScaleFont(fontString, baseFontObject)
end

function Results:SetScaledFont(fontString, baseFontObject)
    if not fontString then return end
    -- Runs per row per render (per keystroke). SetFontObject resets the font,
    -- so ScaleFont's own skip can't fire here and a custom TTF gets re-set
    -- every render, which is a real typing hitch. The applied font only
    -- depends on the base object, the font choice, and the scale, all stable
    -- between keystrokes, so skip the pair when that signature is unchanged.
    local db = EasyFind.db
    local sig = baseFontObject .. "\0" .. (db and db.font or "Default")
        .. "\0" .. tostring(db and db.fontSize or 1.0)
    if fontString._efScaledFontSig == sig then return end
    fontString._efScaledFontSig = sig
    fontString:SetFontObject(baseFontObject)
    ScaleFont(fontString, baseFontObject)
end

function Results:ApplyResultRowFonts(row, theme)
    if not row then return end
    theme = theme or Results:GetActiveTheme()
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
    ScaleFont(row.repBarText, "GameFontNormalSmall")
    ScaleFont(row.settingSliderValue, "GameFontNormalSmall")
    ScaleFont(row.shortcutNumberText, "GameFontDisableSmall")
    if Shortcuts.LayoutResultShortcut then
        Shortcuts:LayoutResultShortcut(row)
    end
end
