local _, ns = ...

local Results = ns.Results
local Shortcuts = ns.ResultShortcuts

local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local THEMES = {}

function Results:ApplySearchWindowFill(frame)
    if not frame then return end
    ns.ApplyThemeFill(frame)
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
    chromeGlyph     = {1.0, 1.0, 1.0},
    mutedGlyph      = {0.58, 0.58, 0.58, 0.85},
    textFaint       = {0.5, 0.5, 0.5},
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

-- UI theme palettes: color-only overlays on the shared Modern layout, so
-- themes can never drift structurally. ApplyUITheme mutates the LIVE slot
-- tables in place (ns.SEARCH_WINDOW_FILL_COLOR and Modern's color slots);
-- every consumer unpacks them at paint time, so the repaint rides the two
-- existing full passes (Search:UpdateFontSize + RefreshResults) with no
-- per-consumer wiring. Theme names are product names and stay untranslated.
ns.UI_THEME_ORDER = { "Black", "Midnight", "Ocean", "Amethyst", "Crimson", "Sky", "Linen", "Mint", "Rose" }
ns.UI_THEME_PALETTES = {
    Black = {
        windowFill = {0.052, 0.052, 0.060},
        pathColor = {0.65, 0.60, 0.55, 1.0},
        pathColorHover = {1.0, 1.0, 1.0, 1.0},
        leafColor = {0.9, 0.9, 0.9},
        chromeGlyph = {1.0, 1.0, 1.0},
        mutedGlyph = {0.58, 0.58, 0.58, 0.85},
        textFaint = {0.50, 0.50, 0.50},
        accent = {0.85, 0.65, 0.15, 0.80},
        controlAccent = {0.17, 0.48, 0.72},
        selection = {0.25, 0.5, 0.9, 0.35},
        separator = {0.5, 0.45, 0.3, 0.35},
        backdropColor = {0.12, 0.10, 0.08, 0.95},
        backdropBorder = {0.50, 0.48, 0.45, 1.0},
    },
    -- Indigo-blue galaxy dust: real smoke footage layered and gradient-mapped
    -- (the showcase video backdrop), calibrated to the dark-theme text
    -- envelope. windowFill is the art's average for swatches and fallbacks.
    Midnight = {
        windowFill = {0.090, 0.108, 0.355},
        fillTexture = "Interface\\AddOns\\EasyFind\\textures\\CombinedFillGalaxy",
        -- Gradient stops serve the MENUS (which opt out of the art
        -- viewport) and the pre-relaunch window fallback. Hue-traveling
        -- like Ocean/Crimson: deep blue-indigo rising into violet-purple
        -- (the galaxy art's own drift), not a single-hue brightness ramp.
        windowFillBottom = {0.030, 0.050, 0.230},
        windowFillTop = {0.200, 0.105, 0.480},
        pathColor = {0.70, 0.74, 0.90, 1.0},
        pathColorHover = {1.0, 1.0, 1.0, 1.0},
        leafColor = {0.94, 0.95, 1.0},
        chromeGlyph = {1.0, 1.0, 1.0},
        mutedGlyph = {0.66, 0.70, 0.86, 0.85},
        textFaint = {0.52, 0.57, 0.78},
        accent = {0.48, 0.62, 1.0, 0.80},
        selection = {0.34, 0.52, 1.0, 0.35},
        separator = {0.42, 0.48, 0.74, 0.35},
        backdropColor = {0.07, 0.08, 0.22, 0.95},
        backdropBorder = {0.42, 0.48, 0.74, 1.0},
    },
    Ocean = {
        windowFill = {0.055, 0.120, 0.200},
        -- Hue-traveling gradient: abyss navy rising into cyan-steel.
        windowFillBottom = {0.020, 0.050, 0.100},
        windowFillTop = {0.090, 0.190, 0.300},
        pathColor = {0.55, 0.62, 0.72, 1.0},
        pathColorHover = {1.0, 1.0, 1.0, 1.0},
        leafColor = {0.88, 0.92, 0.96},
        chromeGlyph = {1.0, 1.0, 1.0},
        mutedGlyph = {0.58, 0.58, 0.58, 0.85},
        textFaint = {0.40, 0.48, 0.60},
        accent = {0.25, 0.60, 0.95, 0.80},
        selection = {0.25, 0.55, 0.95, 0.35},
        separator = {0.30, 0.45, 0.60, 0.35},
        backdropColor = {0.10, 0.14, 0.21, 0.95},
        backdropBorder = {0.35, 0.45, 0.58, 1.0},
    },
    Amethyst = {
        windowFill = {0.130, 0.055, 0.190},
        -- Deep violet rising into magenta-purple.
        windowFillBottom = {0.060, 0.020, 0.100},
        windowFillTop = {0.200, 0.090, 0.280},
        pathColor = {0.68, 0.58, 0.72, 1.0},
        pathColorHover = {1.0, 1.0, 1.0, 1.0},
        leafColor = {0.93, 0.88, 0.95},
        chromeGlyph = {1.0, 1.0, 1.0},
        mutedGlyph = {0.58, 0.58, 0.58, 0.85},
        textFaint = {0.50, 0.42, 0.58},
        accent = {0.72, 0.45, 0.95, 0.80},
        selection = {0.60, 0.35, 0.85, 0.35},
        separator = {0.50, 0.35, 0.60, 0.35},
        backdropColor = {0.16, 0.10, 0.19, 0.95},
        backdropBorder = {0.48, 0.38, 0.55, 1.0},
    },
    Crimson = {
        windowFill = {0.145, 0.045, 0.040},
        -- Maroon-black rising into ember red-orange.
        windowFillBottom = {0.070, 0.015, 0.030},
        windowFillTop = {0.220, 0.070, 0.050},
        pathColor = {0.72, 0.55, 0.55, 1.0},
        pathColorHover = {1.0, 1.0, 1.0, 1.0},
        leafColor = {0.95, 0.88, 0.88},
        chromeGlyph = {1.0, 1.0, 1.0},
        mutedGlyph = {0.58, 0.58, 0.58, 0.85},
        textFaint = {0.58, 0.42, 0.44},
        accent = {0.90, 0.25, 0.30, 0.80},
        selection = {0.90, 0.25, 0.30, 0.30},
        separator = {0.60, 0.30, 0.32, 0.35},
        backdropColor = {0.17, 0.08, 0.10, 0.95},
        backdropBorder = {0.55, 0.35, 0.36, 1.0},
    },
    Sky = {
        light = true,
        windowFill = {0.63, 0.76, 0.88},
        windowFillBottom = {0.58, 0.71, 0.84},
        windowFillTop = {0.68, 0.81, 0.92},
        pathColor = {0.11, 0.23, 0.38, 1.0},
        pathColorHover = {0.05, 0.17, 0.36, 1.0},
        leafColor = {0.10, 0.28, 0.52},
        chromeGlyph = {0.10, 0.28, 0.52},
        mutedGlyph = {0.10, 0.28, 0.52, 1.0},
        textFaint = {0.24, 0.35, 0.48},
        accent = {0.15, 0.45, 0.80, 0.85},
        selection = {0.20, 0.45, 0.85, 0.25},
        separator = {0.25, 0.35, 0.45, 0.30},
        backdropColor = {0.55, 0.69, 0.82, 0.97},
        backdropBorder = {0.40, 0.52, 0.65, 1.0},
    },
    Linen = {
        light = true,
        windowFill = {0.82, 0.82, 0.72},
        windowFillBottom = {0.76, 0.76, 0.65},
        windowFillTop = {0.87, 0.87, 0.78},
        pathColor = {0.26, 0.24, 0.10, 1.0},
        pathColorHover = {0.26, 0.23, 0.07, 1.0},
        leafColor = {0.30, 0.26, 0.08},
        chromeGlyph = {0.30, 0.26, 0.08},
        mutedGlyph = {0.30, 0.26, 0.08, 1.0},
        textFaint = {0.40, 0.38, 0.27},
        accent = {0.55, 0.45, 0.15, 0.85},
        selection = {0.45, 0.40, 0.20, 0.25},
        separator = {0.40, 0.38, 0.28, 0.30},
        backdropColor = {0.75, 0.75, 0.65, 0.97},
        backdropBorder = {0.55, 0.53, 0.44, 1.0},
    },
    Mint = {
        light = true,
        windowFill = {0.68, 0.80, 0.70},
        windowFillBottom = {0.62, 0.75, 0.64},
        windowFillTop = {0.74, 0.85, 0.76},
        pathColor = {0.10, 0.28, 0.15, 1.0},
        pathColorHover = {0.05, 0.26, 0.12, 1.0},
        leafColor = {0.07, 0.34, 0.18},
        chromeGlyph = {0.07, 0.34, 0.18},
        mutedGlyph = {0.07, 0.34, 0.18, 1.0},
        textFaint = {0.24, 0.39, 0.29},
        accent = {0.15, 0.55, 0.30, 0.85},
        selection = {0.18, 0.55, 0.30, 0.25},
        separator = {0.24, 0.38, 0.27, 0.30},
        backdropColor = {0.60, 0.74, 0.63, 0.97},
        backdropBorder = {0.40, 0.56, 0.44, 1.0},
    },
    Rose = {
        light = true,
        windowFill = {0.86, 0.70, 0.76},
        windowFillBottom = {0.80, 0.62, 0.69},
        windowFillTop = {0.91, 0.77, 0.83},
        pathColor = {0.36, 0.13, 0.20, 1.0},
        pathColorHover = {0.37, 0.09, 0.18, 1.0},
        leafColor = {0.44, 0.10, 0.22},
        chromeGlyph = {0.44, 0.10, 0.22},
        mutedGlyph = {0.44, 0.10, 0.22, 1.0},
        textFaint = {0.46, 0.31, 0.37},
        accent = {0.85, 0.30, 0.45, 0.85},
        selection = {0.85, 0.30, 0.45, 0.25},
        separator = {0.55, 0.32, 0.38, 0.30},
        backdropColor = {0.80, 0.63, 0.70, 0.97},
        backdropBorder = {0.65, 0.45, 0.50, 1.0},
    },
}

local function CopySlot(dst, src)
    local n = #src
    if #dst > n then n = #dst end
    for i = 1, n do dst[i] = src[i] end
end

function ns.ApplyUITheme(themeName, skipRepaint)
    local palette = ns.UI_THEME_PALETTES[themeName] or ns.UI_THEME_PALETTES.Black
    local modern = THEMES["Modern"]
    ns.ACTIVE_UI_PALETTE = palette
    CopySlot(ns.SEARCH_WINDOW_FILL_COLOR, palette.windowFill)
    CopySlot(modern.pathColor, palette.pathColor)
    CopySlot(modern.pathColorHover, palette.pathColorHover)
    CopySlot(modern.leafColor, palette.leafColor)
    CopySlot(modern.chromeGlyph, palette.chromeGlyph)
    CopySlot(modern.mutedGlyph, palette.mutedGlyph)
    CopySlot(modern.textFaint, palette.textFaint)
    CopySlot(modern.selectionColor, palette.selection)
    CopySlot(modern.separatorColor, palette.separator)
    CopySlot(modern.resultsBackdropColor, palette.backdropColor)
    CopySlot(modern.resultsBackdropBorderColor, palette.backdropBorder)
    for i = 1, #modern.indentColors do
        CopySlot(modern.indentColors[i], palette.accent)
    end
    modern.lightTheme = palette.light or nil
    -- Shared control colors (tab text, button/table fills) are LIVE ns
    -- tables consumed by creation paints, state handlers, and hover
    -- closures alike; mutating them here rethemes all three uniformly.
    -- Light themes derive theme-hued darks; dark themes restore canon.
    local function setColor(dst, r, g, b, a)
        dst[1], dst[2], dst[3] = r, g, b
        if dst[4] ~= nil or a ~= nil then dst[4] = a end
    end
    if palette.light then
        local leaf = modern.leafColor
        local fillC = ns.SEARCH_WINDOW_FILL_COLOR
        local function mixDark(dst, f, a)
            setColor(dst,
                leaf[1] * (1 - f) + fillC[1] * f,
                leaf[2] * (1 - f) + fillC[2] * f,
                leaf[3] * (1 - f) + fillC[3] * f, a)
        end
        mixDark(ns.BTN_FILL_NORMAL, 0.30)
        -- Hover sits a step LIGHTER than resting (more fill in the mix),
        -- matching how the nav tabs behave, instead of the dark-canon slate.
        mixDark(ns.BTN_FILL_HOVER, 0.45)
        mixDark(ns.BTN_FILL_PRESSED, 0.18)
        mixDark(ns.SECTION_TABLE_FILL, 0.32, 0.92)
        -- Nav pills invert against the card-colored column (the keybind
        -- scheme): selected = window-fill pill, hover = a step lighter
        -- than the column, both carrying window-fill text.
        setColor(ns.NAV_SELECTED_FILL, fillC[1], fillC[2], fillC[3], 0.95)
        mixDark(ns.NAV_HOVER_FILL, 0.45, 0.85)
        -- The panel gloss renders near 0.8x the window fill, so anything
        -- meant to read as a card or inset must sit clearly below that.
        -- Between the panel gloss (~0.8x) and the old too-dark 0.6x:
        -- dark enough to read as a card, light enough for dark text.
        setColor(ns.PANEL_CARD_FILL, fillC[1] * 0.70, fillC[2] * 0.70, fillC[3] * 0.70)
        setColor(ns.EDITBOX_INSET_FILL, fillC[1] * 0.55, fillC[2] * 0.55, fillC[3] * 0.55)
        -- Cyan links vanish on light fills; the live link tables flip to
        -- dark blues so event-time readers stay correct.
        setColor(ns.LINK_COLOR, 0.05, 0.28, 0.58)
        setColor(ns.LINK_HOVER, 0.10, 0.40, 0.78)
        setColor(ns.TEXT_PRIMARY, modern.pathColorHover[1], modern.pathColorHover[2], modern.pathColorHover[3])
        setColor(ns.TEXT_BODY, modern.textFaint[1], modern.textFaint[2], modern.textFaint[3])
    else
        setColor(ns.BTN_FILL_NORMAL, 0.160, 0.190, 0.250)
        setColor(ns.BTN_FILL_HOVER, 0.220, 0.270, 0.340)
        setColor(ns.BTN_FILL_PRESSED, 0.120, 0.140, 0.190)
        setColor(ns.SECTION_TABLE_FILL, 0.075, 0.075, 0.085, 0.92)
        setColor(ns.NAV_SELECTED_FILL, 0.16, 0.19, 0.25, 0.95)
        setColor(ns.NAV_HOVER_FILL, 0.12, 0.14, 0.19, 0.85)
        setColor(ns.PANEL_CARD_FILL, 0.05, 0.05, 0.06)
        setColor(ns.EDITBOX_INSET_FILL, 0.02, 0.02, 0.03)
        setColor(ns.LINK_COLOR, 0.44, 0.84, 1.0)
        setColor(ns.LINK_HOVER, 0.72, 0.94, 1.0)
        setColor(ns.TEXT_PRIMARY, 1.00, 0.97, 0.86)
        setColor(ns.TEXT_BODY, 0.78, 0.78, 0.80)
    end
    -- Toggle/segment accent follows the theme (Black pins the classic blue
    -- via controlAccent; its gold accent drives indents and glow, which
    -- would read wrong on control fills).
    local controlAccent = palette.controlAccent or palette.accent
    setColor(ns.CONTROL_ACCENT, controlAccent[1], controlAccent[2], controlAccent[3])
    -- Menus that are OPEN during the flip never get their OnShow refill;
    -- restyle them right now so nothing wears the previous theme.
    if ns.RestyleShownMenuPanels then
        ns.RestyleShownMenuPanels()
    end
    -- Chevrons register weakly at creation; repaint them all here so
    -- popups without their own restyle hook can never go stale.
    if ns.Utils and ns.Utils.RetintChevrons then
        ns.Utils.RetintChevrons()
    end
    if ns.RestyleCardFills then
        ns.RestyleCardFills()
    end
    -- Rows retint their hover glow lazily against this generation (the
    -- per-render cost is one field compare on pooled rows).
    ns.uiThemeGeneration = (ns.uiThemeGeneration or 0) + 1
    -- Let registered windows (calculator popup) restyle to the new palette
    -- while open.
    if ns.FireThemeCallbacks then ns.FireThemeCallbacks() end
    if skipRepaint then return end
    if ns.Search then
        if ns.Search.UpdateFontSize then ns.Search:UpdateFontSize() end
        if ns.Search.RefreshResults then ns.Search:RefreshResults() end
    end
end

-- Light palettes kill the font drop shadow: dark shadows under dark text
-- on a light fill read as smearing. Cached per fontstring so the per-row
-- per-keystroke cost is one field compare; the cache resets when
-- SetScaledFont actually re-applies a font object (which restores the
-- object's own shadow).
local function ApplyThemeShadow(fontString)
    local wantLight = THEMES["Modern"].lightTheme and true or false
    if fontString._efShadowLight == wantLight then return end
    fontString._efShadowLight = wantLight
    fontString:SetShadowColor(0, 0, 0, wantLight and 0 or 1)
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
    ApplyThemeShadow(fontString)
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
    -- between keystrokes, so skip the pair when those are unchanged (field
    -- compares: a concatenated signature would allocate per row per render).
    local db = EasyFind.db
    local font = db and db.font or "Default"
    local fontSize = db and db.fontSize or 1.0
    if fontString._efSFBase == baseFontObject and fontString._efSFFont == font
       and fontString._efSFSize == fontSize then
        return
    end
    fontString._efSFBase = baseFontObject
    fontString._efSFFont = font
    fontString._efSFSize = fontSize
    fontString:SetFontObject(baseFontObject)
    -- SetFontObject restored the object's own shadow; force re-apply.
    fontString._efShadowLight = nil
    ScaleFont(fontString, baseFontObject)
end

-- Every theme except Black swaps the additive row glow for a rounded
-- full-row wash (window fill nudged toward the text color, see
-- ns.RowWashColor), shown for hover and keyboard selection alike. The
-- frame sits one level below its row so row content renders above it,
-- and it dies with the row.
function Results:UpdateRowWash(row)
    local washR, washG, washB = ns.RowWashColor()
    local wants = washR and (row._efHlLocked or row._efHlHover)
    local hl = row.hoverWash
    if not wants then
        if hl then hl:Hide() end
        return
    end
    if not hl then
        hl = CreateFrame("Frame", nil, row)
        -- Row frames sit inset from the window (icon gutter, scrollbar
        -- lane); the wash spans the scroll child's near-full width so it
        -- hugs the window edges like the window's own fill does.
        hl:SetPoint("TOP", row, "TOP", 0, 0)
        hl:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
        local scrollChild = row:GetParent()
        hl:SetPoint("LEFT", scrollChild, "LEFT", 4, 0)
        -- The right edge stops short of the scrollbar lane (edge inset +
        -- thumb + a hair of breathing room) instead of running under it.
        hl:SetPoint("RIGHT", scrollChild, "RIGHT", -(ns.SCROLLBAR_EDGE_INSET + ns.SCROLLBAR_THUMB_W + 2), 0)
        hl:SetFrameLevel(row:GetFrameLevel() > 0 and row:GetFrameLevel() - 1 or 0)
        ns.CreateRoundedRectBorder(hl)
        -- Panel ON first (fill cells are born hidden), then ring off:
        -- the documented ordering for fill-only rounded frames.
        ns.SetRoundedRectBorderShown(hl, true)
        ns.SetRoundedRectRingShown(hl, false)
        row.hoverWash = hl
    end
    -- Corner curvature sits between the window's full curve and a subtle
    -- card round, clamped to the row height so short rows don't overlap
    -- their corners.
    local rowH = row:GetHeight() or 0
    local barH = 22
    if rowH > 0 and rowH < barH then barH = rowH end
    if hl._efBarH ~= barH then
        hl._efBarH = barH
        ns.SetRoundedRectBarHeight(hl, barH)
    end
    -- The wash paints on top of the window's own fill, so it fades with
    -- the window-opacity setting and sits a step below solid (RowWashAlpha),
    -- rather than a fixed alpha of 1 over a translucent window.
    ns.SetRoundedRectFill(hl, washR, washG, washB, ns.RowWashAlpha(), true)
    hl:Show()
end

-- Single owner for keyboard/menu selection state so the light-theme wash
-- and the built-in highlight can never drift apart.
function Results:SetRowHighlightLocked(row, locked)
    row._efHlLocked = locked and true or nil
    if locked then
        if row.LockHighlight then row:LockHighlight() end
    else
        if row.UnlockHighlight then row:UnlockHighlight() end
    end
    Results:UpdateRowWash(row)
end

function Results:ApplyResultRowFonts(row, theme)
    if not row then return end
    theme = theme or Results:GetActiveTheme()
    -- Hover/selection glow follows the theme accent: ADD glow on dark
    -- themes, normal-blend wash on light ones (ADD cannot darken).
    if row.GetHighlightTexture and row._efHLGen ~= ns.uiThemeGeneration then
        row._efHLGen = ns.uiThemeGeneration
        local hlTex = row:GetHighlightTexture()
        local accent = theme.indentColors and theme.indentColors[1]
        local washActive = ns.RowWashColor() ~= nil
        if hlTex and accent then
            if washActive then
                -- Non-Black themes replace the glow with the rounded
                -- full-row wash (UpdateRowWash); the built-in texture
                -- goes fully transparent so hover/LockHighlight keep
                -- driving state without painting anything.
                hlTex:SetAlpha(0)
            else
                -- Black keeps the classic glow exactly as shipped:
                -- untinted atlas at full alpha. Accent-tinting the
                -- already-gold art only darkens it.
                hlTex:SetAlpha(1)
                hlTex:SetBlendMode("ADD")
                hlTex:SetVertexColor(1, 1, 1, 1)
            end
        end
        if not washActive and row.hoverWash then
            row.hoverWash:Hide()
        end
    end
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
