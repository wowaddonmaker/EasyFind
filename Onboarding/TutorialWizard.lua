local _, ns = ...

local Wizard = {}
ns.Wizard = Wizard
Wizard.FEATURES_PAGE = 2

local Utils = ns.Utils
local L = ns.L
local SafeCallMethod = Utils.SafeCallMethod
local SafeAfter = Utils.SafeAfter

local CreateFrame   = CreateFrame
local UIParent      = UIParent
local InCombatLockdown = InCombatLockdown
local GetBindingKey = GetBindingKey

local GOLD       = ns.GOLD_COLOR
local WIZ_W, WIZ_H = 544, 408
local TUTORIAL_IMAGE_MAX_W = 516
local TUTORIAL_IMAGE_MAX_H = 240
local TOGGLE_ACTION = "EASYFIND_TOGGLE_FOCUS"
local MAP_ACTION    = "EASYFIND_MAP_FOCUS"

local PANEL_BG_ALPHA = 0.97
local TEXT_PRIM      = ns.TEXT_PRIMARY
local TEXT_BODY      = ns.TEXT_BODY
local TEXT_DIM       = ns.TEXT_DIM
local TUTORIAL_IMAGE_TINT = 1.0

local function TutorialTexCoord(contentW, contentH, canvasW, canvasH)
    return { 0, contentW / canvasW, 0, contentH / canvasH }
end

local DOT_FILLED = "Interface\\COMMON\\Indicator-Yellow"
local CALCULATOR_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\calculator-icon"
-- HD Gauntlet cursor (same FileDataID and texCoord as the HD Gauntlet
-- indicator style), reused for slide overlay hints. texCoord is read-only.
local GAUNTLET_CURSOR_TEX = 6116532
local GAUNTLET_CURSOR_TEXCOORD = { 0.0, 0.24, 0.0, 0.42 }
local SEARCH_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-gearstats-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_SEARCH_INTRO"],
        -- Hovering the "Alt + num" span rings the badge on the first row.
        hoverRings = {
            ["hl:altnum"] = { x = 428, y = 104, w = 42, h = 22 },
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-pets-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_ALT_NUMBERS"],
        -- HD Gauntlet cursor resting on the result row to show it's hovered.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 300, oy = 140,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-rowmenu-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_PINNING"],
        -- HD Gauntlet cursor on the highlighted Pin menu row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 272, oy = 112,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-shortkey-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_SHORTKEYS"],
        -- HD Gauntlet cursor on the highlighted Add shortkey menu row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 328, oy = 151,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-wowhead-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_WOWHEAD"],
        -- HD Gauntlet cursor on the highlighted Wowhead menu row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 368, oy = 188,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-sendlink-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_SEND_LINK"],
        -- HD Gauntlet cursor on the highlighted Send link menu row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 280, oy = 108,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-filters-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_FILTER_MENU"],
        -- HD Gauntlet cursor on the filter button to show how to open the menu.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 34,
            ox = 362, oy = 12,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-quickfilters-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_AT_PREFIX"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-currency-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_CURRENCY_REP"],
        -- HD Gauntlet cursor on the highlighted Show as XP bar menu row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 28,
            ox = 286, oy = 219,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-macros-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_MACROS"],
        -- HD Gauntlet cursor resting on the hovered macro row.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 285, oy = 180,
        },
    },
}
local USE_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-gear-outfit-title-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_GEAR_OUTFIT_TITLE"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-mounts-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_MOUNTS"],
        -- Cursor just right of the modifier hint's "Drag".
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 375, oy = 92,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-macros-abilities-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_MACROS_ABILITIES"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-toys-commands-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_TOYS_COMMANDS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-settings-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_INLINE_SETTINGS"],
    },
}
local CALCULATOR_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-calculator-visual-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_FEATURE_CALCULATOR_DESC"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-calculator-copy-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_CALC_COPY_DESC"],
        -- Cursor sitting just right of "Ctrl+C to copy".
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 382, oy = 100,
        },
    },
}
local MAP_SEARCH_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-intro-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_MAP_INTRO_DESC"],
        -- Cursor on the map's search tab in the right-side tab strip.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 430, oy = 206,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-zones-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_MAP_TAB_DESC"],
        -- Cursor on the Crystalsong Forest row, just left of the arrow tail.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 188, oy = 88,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-hover-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_MAP_HOVER_DESC"],
        -- Cursor on the panel's Training Dummies row, just right of the word.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 158, oy = 146,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-rares-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_MAP_RARES_DESC"],
        -- Cursor on the highlighted Ash'an rare result; the arrow ties it to
        -- its spot on the map.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 240, oy = 145,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-autotrack-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_MAP_AUTOTRACK_DESC"],
        -- Cursor on the Rares filter toggle in the cog menu.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 30,
            ox = 195, oy = 176,
        },
    },
}

local function ApplyInter(fs, weight, sizeOverride, flags)
    if ns.RegisterAddonFont then
        ns.RegisterAddonFont(fs, weight, sizeOverride, flags)
    end
end

local frame
local pages = {}
local pageIdx = 1
local dots = {}
local backBtn, nextBtn

local function MakeButton(parent, text, variant, w)
    local b = CreateFrame("Button", nil, parent)
    local h = (variant == "rounded") and 20 or 18
    b:SetSize(w or 96, h)

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    ApplyInter(fs, "semibold", 10)
    b._label = fs

    if variant == "rounded" then
        ns.CreateRoundedRectBorder(b)
        ns.SetRoundedRectBarHeight(b, 8)
        ns.SetRoundedRectBorderBgAlpha(b, 1)
        -- Border ring hidden: 256px texture aliases badly at ~5px corners.
        ns.SetRoundedRectBorderEdgeShown(b, false)
        local function tintFill(rr, gg, bb)
            ns.SetRoundedRectFill(b, rr, gg, bb, 1, true)
        end
        tintFill(0.18, 0.18, 0.20)
        fs:SetTextColor(1, 1, 1, 1)
        b:SetScript("OnEnter",     function() tintFill(0.26, 0.26, 0.28) end)
        b:SetScript("OnLeave",     function() tintFill(0.18, 0.18, 0.20) end)
        b:SetScript("OnMouseDown", function() tintFill(0.12, 0.12, 0.14) end)
        b:SetScript("OnMouseUp",   function(self)
            tintFill(self:IsMouseOver() and 0.26 or 0.18,
                     self:IsMouseOver() and 0.26 or 0.18,
                     self:IsMouseOver() and 0.28 or 0.20)
        end)
        return b
    end

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    b._bg = bg

    local function setVisual(state)
        if variant == "ghost" then
            bg:SetColorTexture(0, 0, 0, 0)
        else
            if state == "pressed" then
                bg:SetColorTexture(0.10, 0.10, 0.11, 1)
            elseif state == "hover" then
                bg:SetColorTexture(0.18, 0.18, 0.20, 1)
            else
                bg:SetColorTexture(0.13, 0.13, 0.15, 1)
            end
        end
        if state == "hover" or state == "pressed" then
            fs:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
        else
            fs:SetTextColor(Utils.RGB(TEXT_DIM, 1))
        end
    end
    setVisual("normal")
    b:SetScript("OnEnter",     function() setVisual("hover") end)
    b:SetScript("OnLeave",     function() setVisual("normal") end)
    b:SetScript("OnMouseDown", function() setVisual("pressed") end)
    b:SetScript("OnMouseUp",   function(self)
        if self:IsMouseOver() then setVisual("hover") else setVisual("normal") end
    end)
    return b
end

local function ShowPage(i)
    if i < 1 or i > #pages then return end
    pageIdx = i
    for idx, p in ipairs(pages) do
        p:SetShown(idx == i)
    end
    for idx, d in ipairs(dots) do
        if idx == i then
            d:SetVertexColor(Utils.RGB(GOLD, 1))
            d:SetSize(11, 11)
        else
            d:SetVertexColor(0.32, 0.32, 0.36, 1)
            d:SetSize(9, 9)
        end
    end
    backBtn:SetShown(i > 1)
    if i == #pages then
        nextBtn._label:SetText(L["TUT_BTN_OPEN_BAR"])
    elseif i == 1 then
        nextBtn._label:SetText(L["TUT_BTN_GET_STARTED"])
    else
        nextBtn._label:SetText(L["TUT_BTN_CONTINUE"])
    end
    if pages[i].OnEnter then pages[i].OnEnter() end
end

local function FinishWizard(openBar)
    if not frame then return end
    EasyFind.db.tutorialDone = true
    EasyFind.db.setupComplete = true
    if ns.version then
        EasyFind.db.lastSeenVersion = ns.version
        if ns.version == ns.REVAMPED_TUTORIAL_VERSION then
            EasyFind.db.revampedTutorialVersion = ns.REVAMPED_TUTORIAL_VERSION
        end
    end
    SafeCallMethod(frame, "EnableKeyboard", false)
    frame:Hide()
    if openBar and ns.Search and ns.Search.Show then
        SafeAfter(0.05, function() ns.Search:Show(true) end)
    end
end

local function MakePage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    p:Hide()
    return p
end

local function HeaderText(parent, text, font, maxWidth)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalHuge")
    ApplyInter(fs, "semibold")
    fs:SetText(text)
    fs:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    if maxWidth and maxWidth > 0 then
        ns.AttachEllipsisToFontString(fs, text, maxWidth)
    end
    return fs
end

-- Inner width available for headers inside the wizard panel. The wizard frame
-- is WIZ_W wide; subtract margins for the back arrow on the left and the
-- close-X on the right so a long localised title gets ellipsised instead of
-- overflowing under the chrome.
local HEADER_MAX_W = WIZ_W - 140

local function BodyText(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ApplyInter(fs, "regular")
    fs:SetText(text)
    fs:SetTextColor(Utils.RGB(TEXT_BODY, 1))
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(4)
    return fs
end

local function FitSize(srcW, srcH, maxW, maxH)
    if not srcW or not srcH or srcW <= 0 or srcH <= 0 then
        return maxW, maxH
    end
    local scale = math.min(maxW / srcW, maxH / srcH)
    return srcW * scale, srcH * scale
end

local function SetTutorialImage(texture, image, texCoord)
    texture:SetTexture(image)
    if texCoord then
        texture:SetTexCoord(unpack(texCoord))
    else
        texture:SetTexCoord(0, 1, 0, 1)
    end
    texture:SetVertexColor(TUTORIAL_IMAGE_TINT, TUTORIAL_IMAGE_TINT, TUTORIAL_IMAGE_TINT, 1)
end

local function BuildPage1(parent)
    local p = MakePage(parent)

    local logo = p:CreateTexture(nil, "OVERLAY")
    logo:SetSize(108, 108)
    logo:SetTexture("Interface\\AddOns\\EasyFind\\textures\\Spyglass")
    logo:SetPoint("TOP", p, "TOP", 0, -40)

    local version = ns.version or (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("EasyFind", "Version")) or "2.0.0"
    local title = HeaderText(p, L["TUT_WELCOME_TITLE"]:format(version), nil, HEADER_MAX_W)
    title:SetPoint("TOP", logo, "BOTTOM", 0, -22)
    do
        local path, sz, fl = title:GetFont()
        if sz then title:SetFont(path, sz * 1.5, fl or "") end
    end

    local sub = BodyText(p, L["TUT_WELCOME_SUBTITLE"])
    sub:SetPoint("TOP", title, "BOTTOM", 0, -16)
    sub:SetWidth(WIZ_W - 120)
    sub:SetTextColor(Utils.RGB(TEXT_DIM, 1))

    return p
end

local function FeatureTile(parent, atlas, file, coords, title, desc, onClick)
    -- Tile anchored to holder CENTER so hover SetScale grows symmetrically.
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(222, 112)

    local tile = CreateFrame("Button", nil, holder)
    tile:SetSize(222, 112)
    tile:SetPoint("CENTER", holder, "CENTER", 0, 0)
    tile:RegisterForClicks("LeftButtonUp")

    ns.CreateRoundedRectBorder(tile)
    ns.SetRoundedRectBarHeight(tile, 10)
    ns.SetRoundedRectBorderBgAlpha(tile, 0.95)
    ns.SetRoundedRectFill(tile, 0.05, 0.05, 0.06, 1, true)
    ns.SetRoundedRectBorderEdgeShown(tile, false)

    local icon = tile:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", tile, "TOPLEFT", 14, -14)
    if atlas then
        icon:SetAtlas(atlas)
    elseif file then
        icon:SetTexture(file)
        if coords then icon:SetTexCoord(unpack(coords)) end
    end

    local fs = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetTextColor(Utils.RGB(GOLD, 1))
    fs:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
    fs:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    fs:SetJustifyH("LEFT")
    ApplyInter(fs, "semibold")
    -- Let the helper auto-derive width from L+R anchors on each fit; passing
    -- fs:GetWidth() here would freeze maxWidth to the FontString's natural
    -- string width (anchors aren't resolved yet at creation), which then
    -- triggers spurious truncation on the hover SetScale.
    ns.MakeEllipsisLabel(fs, title)

    local body = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetText(desc)
    body:SetTextColor(Utils.RGB(TEXT_BODY, 1))
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(2)
    body:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -6)
    body:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    ApplyInter(body, "regular")

    tile:SetScript("OnEnter", function(self)
        self:SetScale(1.04)
        ns.SetRoundedRectBorderFillColor(self, 0.09, 0.09, 0.11, 1)
    end)
    tile:SetScript("OnLeave", function(self)
        self:SetScale(1.00)
        ns.SetRoundedRectBorderFillColor(self, 0.05, 0.05, 0.06, 1)
    end)
    if onClick then
        tile:SetScript("OnClick", onClick)
    end

    tile.icon = icon
    holder.tile = tile
    return holder
end

-- The Map feature tile mirrors the world-map side tab players actually click:
-- the QuestLog-tab-side silhouette with the gold search glyph centered on it
-- (see MapSearch/MapTab.lua CreateTabFrame). Rendered at the atlas's native
-- proportions, scaled into the tile's icon slot; the glyph keeps the live tab's
-- ~20/55 glyph-to-tab height ratio and its active gold tint.
local MAP_TAB_TILE_H = 44
local function BuildMapSideTabReplica(tile, anchor)
    local silo = tile:CreateTexture(nil, "BACKGROUND")
    silo:SetAtlas("QuestLog-tab-side", true)
    local nw, nh = silo:GetSize()
    local scale = (nh and nh > 0) and (MAP_TAB_TILE_H / nh) or 1
    silo:SetSize((nw or 34) * scale, (nh or MAP_TAB_TILE_H) * scale)
    silo:SetPoint("CENTER", anchor, "CENTER", 0, 0)

    local mag = tile:CreateTexture(nil, "ARTWORK")
    mag:SetTexture(ns.SEARCH_ICON_TEX)
    mag:SetTexCoord(unpack(ns.SEARCH_ICON_COORDS))
    local magSize = MAP_TAB_TILE_H * 20 / 55
    mag:SetSize(magSize, magSize)
    mag:SetPoint("CENTER", silo, "CENTER", 0, 0)
    mag:SetVertexColor(Utils.RGB(GOLD))

    -- Show the tab as selected, mirroring CreateTabFrame's setGlow(tab, true):
    -- the same select-glow atlas, scaled with the silhouette so the halo sits
    -- around the tab exactly as it does live.
    local glow = tile:CreateTexture(nil, "OVERLAY")
    glow:SetAtlas("QuestLog-Tab-side-Glow-Select", true)
    local gw, gh = glow:GetSize()
    glow:SetSize((gw or 44) * scale, (gh or 55) * scale)
    glow:SetPoint("CENTER", silo, "CENTER", 0, 0)
end

local FILTER_CIRCLE_TEX = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"

local function BuildFilterCircle(parent, d)
    local circle = CreateFrame("Frame", nil, parent)
    circle:SetSize(d, d)
    if circle.CreateMaskTexture then
        local ringInset = d * 0.167
        local innerInset = ringInset + Utils.mmax(1, d * 0.045)
        local ringMask = circle:CreateMaskTexture(nil, "BACKGROUND")
        ringMask:SetTexture(FILTER_CIRCLE_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        ringMask:SetPoint("TOPLEFT", circle, "TOPLEFT", ringInset, -ringInset)
        ringMask:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", -ringInset, ringInset)
        local circleMask = circle:CreateMaskTexture(nil, "ARTWORK")
        circleMask:SetTexture(FILTER_CIRCLE_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        circleMask:SetPoint("TOPLEFT", circle, "TOPLEFT", innerInset, -innerInset)
        circleMask:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", -innerInset, innerInset)
        local ringDisc = circle:CreateTexture(nil, "BACKGROUND", nil, 1)
        ringDisc:SetColorTexture(1.0, 0.82, 0.0, 1)
        ringDisc:SetPoint("TOPLEFT", circle, "TOPLEFT", ringInset, -ringInset)
        ringDisc:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", -ringInset, ringInset)
        ringDisc:AddMaskTexture(ringMask)
        local ringInner = circle:CreateTexture(nil, "BACKGROUND", nil, 2)
        ringInner:SetColorTexture(Utils.RGB(ns.SEARCH_WINDOW_FILL_COLOR, 1))
        ringInner:SetPoint("TOPLEFT", circle, "TOPLEFT", innerInset, -innerInset)
        ringInner:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", -innerInset, innerInset)
        ringInner:AddMaskTexture(circleMask)
    end
    local arrow = circle:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(423808)
    arrow:SetTexCoord(0.453, 0.203, 0.453, 0.016, 0.641, 0.203, 0.641, 0.016)
    arrow:SetDesaturated(true)
    arrow:SetBlendMode("ADD")
    arrow:SetVertexColor(1, 1, 1)
    arrow:SetSize(d * 0.36, d * 0.36)
    arrow:SetPoint("CENTER")
    return circle
end

local function BuildSearchBarReplica(parent, w, h)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(w, h)
    ns.CreateRoundedRectBorder(bar)
    ns.SetRoundedRectBarHeight(bar, h)
    ns.SetRoundedRectBorderFillColor(bar, Utils.RGB(ns.SEARCH_WINDOW_FILL_COLOR, 1))
    ns.SetRoundedRectBorderBgAlpha(bar, ns.SEARCH_WINDOW_ALPHA)

    local iconSz = h * ns.SEARCHBAR_FILL * ns.SEARCHBAR_ICON_SCALE
    local icon = bar:CreateTexture(nil, "OVERLAY")
    icon:SetSize(iconSz, iconSz)
    icon:SetPoint("CENTER", bar, "LEFT", h / 2, 0)
    icon:SetAtlas("common-search-magnifyingglass")

    local placeholder = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    placeholder:SetPoint("LEFT", bar, "LEFT", h, 0)
    placeholder:SetPoint("RIGHT", bar, "RIGHT", -h, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    placeholder:SetText(L["SEARCH_PLACEHOLDER"])
    placeholder:SetTextColor(0.5, 0.5, 0.5)

    local filter = BuildFilterCircle(bar, h)
    filter:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    return bar
end

local function BuildPage2(parent)
    local p = MakePage(parent)

    local grid = CreateFrame("Frame", nil, p)
    grid:SetAllPoints(p)

    local title = HeaderText(grid, L["TUT_FEATURES_TITLE"], "GameFontNormalLarge", HEADER_MAX_W)
    title:SetPoint("TOP", grid, "TOP", 0, -28)

    local sub = BodyText(grid, L["TUT_FEATURES_SUBTITLE"])
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)

    local detailViews = {}

    -- In a submenu the footer nav (Back / Continue / page dots) is hidden; the
    -- only navigation is each detail view's own top-left back arrow.
    local function SetFooterNavShown(shown)
        backBtn:SetShown(shown and pageIdx > 1)
        nextBtn:SetShown(shown)
        for i = 1, #dots do dots[i]:SetShown(shown) end
    end

    local function ShowGrid()
        grid:Show()
        for i = 1, #detailViews do detailViews[i]:Hide() end
        SetFooterNavShown(true)
    end

    local function ShowDetail(d)
        grid:Hide()
        for i = 1, #detailViews do detailViews[i]:Hide() end
        d:Show()
        SetFooterNavShown(false)
    end

    -- The macros search slide links to the Actionables deck; forward-declared
    -- because that deck is created further down.
    local actionsDeck
    local function GoToActionsDeck()
        if actionsDeck then ShowDetail(actionsDeck) end
    end

    local function CreateCarouselDetailView(headerText, slides)
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, L["TUT_BTN_BACK_ARROW"], "ghost", 52)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, headerText, "GameFontNormalLarge", HEADER_MAX_W)
        h:SetPoint("TOP", d, "TOP", 0, -28)

        local image = d:CreateTexture(nil, "ARTWORK")
        image:SetPoint("TOP", h, "BOTTOM", 0, -10)

        local overlayTex = d:CreateTexture(nil, "OVERLAY")
        overlayTex:Hide()

        -- Gold ring shown over the slide image while a hover span in the
        -- slide text is hovered (slide.hoverRings maps span id -> rect).
        local hoverRingTex = d:CreateTexture(nil, "OVERLAY")
        hoverRingTex:SetTexture("Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-ring")
        hoverRingTex:Hide()

        local liveDemo
        for _, s in ipairs(slides) do
            if s.live == "searchbar" then
                liveDemo = BuildSearchBarReplica(d, s.w, s.h)
                liveDemo:SetPoint("TOP", h, "BOTTOM", 0, -48)
                liveDemo:Hide()
                break
            end
        end

        -- Inline link chips inside the slide body. Use {L:id}text{/L} in the L
        -- string; ns.BuildFlowText word-wraps and turns link atoms into chips
        -- with glow + pulse on hover, matching the options-home tutorial chip.
        local SLIDE_FLOW_WIDTH = WIZ_W - 104
        local linkDispatch = {
            ["options:aliases"] = function()
                FinishWizard(false)
                if ns.Options and ns.Options.OpenAtAliases then
                    ns.Options:OpenAtAliases()
                end
            end,
            ["wizard:actions"] = function()
                GoToActionsDeck()
            end,
        }
        local slideFlow

        local controls = CreateFrame("Frame", nil, d)
        controls:SetSize(148, 18)
        -- Park the slide nav inside the footer box (its Back/Continue are hidden
        -- in a carousel), freeing the body's bottom strip for a taller image.
        controls:SetPoint("CENTER", frame, "BOTTOM", 0, 20)
        controls:SetFrameLevel(frame:GetFrameLevel() + 50)

        local prev = MakeButton(controls, "<", "ghost", 26)
        prev:SetPoint("LEFT", controls, "LEFT", 0, 0)

        local next = MakeButton(controls, ">", "ghost", 26)
        next:SetPoint("RIGHT", controls, "RIGHT", 0, 0)

        local counter = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        counter:SetPoint("CENTER", controls, "CENTER", 0, 0)
        counter:SetTextColor(Utils.RGB(TEXT_DIM, 1))
        ApplyInter(counter, "regular", 10)

        local idx = 1
        local function ShowSlide(newIdx)
            local count = #slides
            if count == 0 then return end
            if newIdx < 1 then newIdx = count end
            if newIdx > count then newIdx = 1 end
            idx = newIdx

            local slide = slides[idx]
            overlayTex:Hide()
            hoverRingTex:Hide()
            if slideFlow then
                slideFlow:Hide()
                slideFlow:SetParent(nil)
                slideFlow = nil
            end
            local dispatch = linkDispatch
            if slide.hoverRings then
                dispatch = {}
                for id, fn in pairs(linkDispatch) do dispatch[id] = fn end
                for id, ring in pairs(slide.hoverRings) do
                    dispatch[id] = {
                        onEnter = function()
                            hoverRingTex:ClearAllPoints()
                            hoverRingTex:SetPoint("TOPLEFT", image, "TOPLEFT", ring.x, -ring.y)
                            hoverRingTex:SetSize(ring.w, ring.h)
                            hoverRingTex:Show()
                        end,
                        onLeave = function() hoverRingTex:Hide() end,
                    }
                end
            end
            slideFlow = ns.BuildFlowText(d, slide.text or "", {
                width = SLIDE_FLOW_WIDTH,
                font = "GameFontHighlightSmall",
                linkDispatch = dispatch,
                textColor = TEXT_BODY,
                interWeight = "regular",
                interSize = 11,
            })
            slideFlow:ClearAllPoints()
            if slide.live and liveDemo then
                image:Hide()
                liveDemo:Show()
                slideFlow:SetPoint("TOP", liveDemo, "BOTTOM", 0, -16)
            else
                if liveDemo then liveDemo:Hide() end
                image:Show()
                SetTutorialImage(image, slide.image, slide.texCoord)
                local w, hgt = FitSize(slide.w, slide.h, TUTORIAL_IMAGE_MAX_W, TUTORIAL_IMAGE_MAX_H)
                image:SetSize(w, hgt)
                slideFlow:SetPoint("TOP", image, "BOTTOM", 0, -8)
                local ov = slide.overlay
                if ov then
                    overlayTex:SetTexture(ov.tex)
                    overlayTex:SetTexCoord(unpack(ov.texCoord or { 0, 1, 0, 1 }))
                    overlayTex:SetSize(ov.size or 28, ov.size or 28)
                    overlayTex:SetRotation(ov.rotation or 0)
                    overlayTex:ClearAllPoints()
                    overlayTex:SetPoint("TOPLEFT", image, "TOPLEFT", ov.ox or 0, -(ov.oy or 0))
                    overlayTex:Show()
                end
            end
            counter:SetText(idx .. " / " .. count)
        end

        prev:SetScript("OnClick", function() ShowSlide(idx - 1) end)
        next:SetScript("OnClick", function() ShowSlide(idx + 1) end)
        d.OnEnter = function() ShowSlide(idx) end
        ShowSlide(1)

        detailViews[#detailViews + 1] = d
        return d
    end

    local d1 = CreateCarouselDetailView(L["TUT_FEATURE_SEARCH"], SEARCH_TUTORIAL_SLIDES)
    local d2 = CreateCarouselDetailView(L["TUT_FEATURE_MAP"], MAP_SEARCH_TUTORIAL_SLIDES)
    local d3 = CreateCarouselDetailView(L["TUT_FEATURE_ACTIONS"], USE_TUTORIAL_SLIDES)
    actionsDeck = d3
    local d4 = CreateCarouselDetailView(L["TUT_FEATURE_CALCULATOR"], CALCULATOR_TUTORIAL_SLIDES)

    local t1 = FeatureTile(grid, nil, "Interface\\AddOns\\EasyFind\\textures\\Spyglass", nil,
        L["TUT_FEATURE_SEARCH"],
        L["TUT_FEATURE_SEARCH_DESC"],
        function() ShowDetail(d1) end)
    t1:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -96)

    local t2 = FeatureTile(grid, nil, nil, nil,
        L["TUT_FEATURE_MAP"],
        L["TUT_FEATURE_MAP_DESC"],
        function() ShowDetail(d2) end)
    BuildMapSideTabReplica(t2.tile, t2.tile.icon)
    t2:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -38, -96)

    -- Anchor each lower tile to the grid so a hover scale doesn't move its sibling.
    local t3 = FeatureTile(grid, "UI-HUD-MicroMenu-SpellbookAbilities-Up", nil, nil,
        L["TUT_FEATURE_ACTIONS"],
        L["TUT_FEATURE_ACTIONS_DESC"],
        function() ShowDetail(d3) end)
    t3:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -222)

    local t4 = FeatureTile(grid, nil, CALCULATOR_ICON_TEX, nil,
        L["TUT_FEATURE_CALCULATOR"],
        L["TUT_FEATURE_CALCULATOR_DESC"],
        function() ShowDetail(d4) end)
    t4:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -38, -222)

    p.OnEnter = ShowGrid

    return p
end

local kbWidgets = {}
local kbWaitingFor

local function RefreshKbWidget(widget)
    local cur = GetBindingKey(widget.action) or EasyFind:GetAccountKeybind(widget.action)
    widget.btn._label:SetText(cur or _G["NOT_BOUND"] or "Not Bound")
end

local function StopKeybindCapture()
    if not kbWaitingFor then return end
    local widget = kbWaitingFor
    kbWaitingFor = nil
    SafeCallMethod(widget.btn, "EnableKeyboard", false)
    widget.btn:SetScript("OnKeyDown", nil)
    RefreshKbWidget(widget)
end

local function CreateKbWidget(parent, action, label)
    local w = { action = action }

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    lbl:SetText(label)
    lbl:SetTextColor(Utils.RGB(TEXT_DIM, 1))
    ApplyInter(lbl, "regular")
    w.label = lbl

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(208, 40)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    w.btn = btn

    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, 40)
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    ns.SetRoundedRectBorderFillColor(btn, 0.18, 0.18, 0.20, 1)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("CENTER")
    ApplyInter(fs, "semibold")
    btn._label = fs

    local function tintFill(rr, gg, bb)
        ns.SetRoundedRectBorderFillColor(btn, rr, gg, bb, 1)
    end

    local function setHover(hover)
        tintFill(hover and 0.24 or 0.18,
                 hover and 0.24 or 0.18,
                 hover and 0.26 or 0.20)
        fs:SetTextColor(hover and 1 or TEXT_PRIM[1],
                        hover and 1 or TEXT_PRIM[2],
                        hover and 1 or TEXT_PRIM[3], 1)
    end
    setHover(false)
    btn:SetScript("OnEnter", function() setHover(true) end)
    btn:SetScript("OnLeave", function() setHover(false) end)

    btn:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            EasyFind:SetAccountKeybind(action, nil)
            RefreshKbWidget(w)
            return
        end
        if kbWaitingFor == w then
            StopKeybindCapture()
            return
        end
        if kbWaitingFor then StopKeybindCapture() end
        kbWaitingFor = w
        self._label:SetText(L["TUT_KB_PRESS_KEY"])
        SafeCallMethod(self, "EnableKeyboard", true)
        self:SetScript("OnKeyDown", function(s, key)
            local combo = Utils.CaptureKeybindCombo(key)
            if not combo then return end
            if combo == "stop" then
                StopKeybindCapture()
                return
            end
            EasyFind:SetAccountKeybind(action, combo)
            StopKeybindCapture()
        end)
    end)

    return w
end

-- Show-method picker: radio per visibility mode, with the three combat
-- checkbox lines indented under Always Show (same semantics as the
-- options flyout: toggling any sub-line force-selects Always Show, and
-- "Dim in combat" needs "Hide in combat" off). Writes straight to the db
-- through the shared owners; the bar stays hidden until the wizard ends,
-- so no live Show/Hide side effects run here.
local function BuildPageShowMethod(parent)
    local p = MakePage(parent)

    local title = HeaderText(p, L["TUT_SHOWMETHOD_HEADER"], "GameFontNormalLarge", HEADER_MAX_W)
    title:SetPoint("TOP", p, "TOP", 0, -36)

    local sub = BodyText(p, L["TUT_SHOWMETHOD_BODY"])
    sub:SetPoint("TOP", title, "BOTTOM", 0, -10)
    sub:SetWidth(WIZ_W - 100)

    local column = CreateFrame("Frame", nil, p)
    column:SetSize(WIZ_W - 170, 216)
    column:SetPoint("TOP", sub, "BOTTOM", 0, -14)

    local modeRows = {}
    local subChecks = {}

    local function RefreshAll()
        local mode = ns.GetVisibilityMode()
        for i = 1, #modeRows do
            local row = modeRows[i]
            row.radio:SetTexture(mode == row.mode and ns.RADIO_ON_TEX or ns.RADIO_OFF_TEX)
        end
        local isAlways = mode == ns.VISIBILITY_ALWAYS
        for i = 1, #subChecks do
            local line = subChecks[i]
            local enabled = isAlways and (not line.needsCombatShown
                or EasyFind.db.combatHide == false)
            line.check:SetShown(line.getter())
            local dim = enabled and 1 or 0.4
            line.box:SetAlpha(dim)
            line.check:SetAlpha(dim)
            line.lbl:SetAlpha(dim)
            line.enabled = enabled
        end
    end

    local function AddModeRow(mode, labelText, descText, yOffset, rowH)
        local row = CreateFrame("Button", nil, column)
        row:SetSize(column:GetWidth(), rowH)
        row:SetPoint("TOPLEFT", column, "TOPLEFT", 0, yOffset)
        local radio = row:CreateTexture(nil, "ARTWORK")
        radio:SetSize(14, 14)
        radio:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        radio:SetTexture(ns.RADIO_OFF_TEX)
        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("LEFT", radio, "RIGHT", 6, 0)
        lbl:SetText(labelText)
        local desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", radio, "TOPRIGHT", 6, -18)
        desc:SetWidth(column:GetWidth() - 24)
        desc:SetJustifyH("LEFT")
        desc:SetText(descText)
        desc:SetTextColor(Utils.RGB(TEXT_DIM, 1))
        row:SetScript("OnClick", function()
            ns.SetVisibilityMode(mode)
            RefreshAll()
        end)
        modeRows[#modeRows + 1] = { mode = mode, radio = radio }
        return row
    end

    local function AddSubCheck(labelText, yOffset, opts)
        local line = CreateFrame("Button", nil, column)
        line:SetSize(column:GetWidth() - 22, 17)
        line:SetPoint("TOPLEFT", column, "TOPLEFT", 22, yOffset)
        local box = line:CreateTexture(nil, "ARTWORK")
        box:SetSize(12, 12)
        box:SetPoint("LEFT", line, "LEFT", 0, 0)
        box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
        box:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local check = line:CreateTexture(nil, "OVERLAY")
        check:SetSize(12, 12)
        check:SetPoint("CENTER", box, "CENTER", 0, 0)
        check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        check:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local lbl = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", box, "RIGHT", 4, 0)
        lbl:SetText(labelText)
        local entry = {
            box = box, check = check, lbl = lbl,
            getter = opts.getter, needsCombatShown = opts.needsCombatShown,
        }
        line:SetScript("OnClick", function()
            if entry.needsCombatShown and EasyFind.db.combatHide ~= false
                and ns.GetVisibilityMode() == ns.VISIBILITY_ALWAYS then
                return
            end
            opts.setter(not opts.getter())
            ns.SetVisibilityMode(ns.VISIBILITY_ALWAYS)
            RefreshAll()
        end)
        subChecks[#subChecks + 1] = entry
        return line
    end

    AddModeRow(ns.VISIBILITY_AUTO,
        L["OPT_VISIBILITY_AUTOHIDE"] .. " (" .. L["TUT_RECOMMENDED"] .. ")",
        L["OPT_VISIBILITY_AUTOHIDE_TT"], 0, 44)
    AddModeRow(ns.VISIBILITY_SMART,
        L["OPT_VISIBILITY_SMARTSHOW"],
        L["OPT_VISIBILITY_SMARTSHOW_TT"], -48, 44)
    AddModeRow(ns.VISIBILITY_ALWAYS,
        L["OPT_VISIBILITY_ALWAYS"],
        L["OPT_VISIBILITY_ALWAYS_TT"], -96, 44)
    AddSubCheck(L["OPT_COMBAT_HIDE_SHORT"], -152, {
        getter = function() return EasyFind.db.combatHide ~= false end,
        setter = function(v) EasyFind.db.combatHide = v and true or false end,
    })
    AddSubCheck(L["OPT_COMBAT_DIM"], -170, {
        getter = function() return EasyFind.db.combatDim == true end,
        setter = function(v) EasyFind.db.combatDim = v and true or false end,
        needsCombatShown = true,
    })
    AddSubCheck(L["OPT_MOVE_DIM"], -188, {
        getter = function() return EasyFind.db.moveDim == true end,
        setter = function(v)
            EasyFind.db.moveDim = v and true or false
            if ns.Search and ns.Search.UpdateMoveDim then
                ns.Search:UpdateMoveDim()
            end
        end,
    })

    local note = BodyText(p, L["TUT_SHOWMETHOD_NOTE"])
    note:SetPoint("TOP", column, "BOTTOM", 0, -4)
    note:SetWidth(WIZ_W - 100)

    p.OnEnter = RefreshAll

    return p
end

local function BuildPage3(parent)
    local p = MakePage(parent)

    local title = HeaderText(p, L["TUT_KEYBIND_HEADER"], "GameFontNormalLarge", HEADER_MAX_W)
    title:SetPoint("TOP", p, "TOP", 0, -36)

    local sub = BodyText(p, "")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -10)
    sub:SetWidth(WIZ_W - 100)

    local uiKb  = CreateKbWidget(p, TOGGLE_ACTION, L["TUT_KEYBIND_SEARCH_BAR"])
    local mapKb = CreateKbWidget(p, MAP_ACTION,    L["TUT_KEYBIND_MAP_TAB"])
    kbWidgets = { uiKb, mapKb }

    local KB_GROUP_GAP = 44
    uiKb.btn:SetPoint("BOTTOM", p, "CENTER", 0, KB_GROUP_GAP / 2)
    uiKb.label:SetPoint("BOTTOM", uiKb.btn, "TOP", 0, 6)

    mapKb.btn:SetPoint("TOP", uiKb.btn, "BOTTOM", 0, -KB_GROUP_GAP)
    mapKb.label:SetPoint("BOTTOM", mapKb.btn, "TOP", 0, 6)

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetText(L["TUT_KEYBIND_CAPTURE_HINT"])
    hint:SetTextColor(Utils.RGB(TEXT_DIM, 1))
    hint:SetPoint("BOTTOM", p, "BOTTOM", 0, 22)
    hint:SetWidth(WIZ_W - 100)
    hint:SetJustifyH("CENTER")
    ApplyInter(hint, "regular")

    p.OnEnter = function()
        if kbWaitingFor then StopKeybindCapture() end
        for i = 1, #kbWidgets do RefreshKbWidget(kbWidgets[i]) end
    end

    return p
end

local BANNER_H = 29

local function CreateFrameOnce()
    if frame then return frame end

    local f = CreateFrame("Frame", "EasyFindWizard", UIParent)
    f:SetSize(WIZ_W, WIZ_H)
    f:SetScale(0.88)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(220)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    frame = f

    ns.StyleWizardPanel(f, PANEL_BG_ALPHA)

    local closeBtn = ns.CreateCloseX(f)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
    closeBtn:SetScript("OnClick", function() FinishWizard(false) end)

    local pageHost = CreateFrame("Frame", nil, f)
    pageHost:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    pageHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 6 + BANNER_H + 4)

    pages = {
        BuildPage1(pageHost),
        BuildPage2(pageHost),
        BuildPageShowMethod(pageHost),
        BuildPage3(pageHost),
    }

    local BANNER_INSET = 5
    local footer = CreateFrame("Frame", nil, f)
    footer:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  BANNER_INSET, BANNER_INSET)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BANNER_INSET, BANNER_INSET)
    footer:SetHeight(BANNER_H)
    ns.CreateRoundedRectBorder(footer)
    ns.SetRoundedRectBarHeight(footer, 12)
    ns.SetRoundedRectBorderBgAlpha(footer, 1)
    ns.SetRoundedRectFill(footer, 0.075, 0.075, 0.085, 1, true)
    ns.SetRoundedRectBorderEdgeShown(footer, false)

    local DOT_GAP = 11
    local DOT_SZ  = 7
    local DOT_ACTIVE = 9
    for i = 1, #pages do
        local d = footer:CreateTexture(nil, "OVERLAY")
        d:SetSize(DOT_SZ, DOT_SZ)
        d:SetTexture(DOT_FILLED)
        d:SetPoint("LEFT", footer, "LEFT", 12 + DOT_ACTIVE / 2 + (i - 1) * (DOT_SZ + DOT_GAP), 0)
        dots[i] = d
    end

    nextBtn = MakeButton(footer, L["TUT_BTN_CONTINUE"], "rounded", 78)
    nextBtn:SetPoint("RIGHT", footer, "RIGHT", -8, 0)

    backBtn = MakeButton(footer, L["TUT_BTN_BACK"], "ghost", 42)
    backBtn:SetPoint("RIGHT", nextBtn, "LEFT", -5, 0)
    backBtn:SetScript("OnClick", function() ShowPage(pageIdx - 1) end)

    nextBtn:SetScript("OnClick", function()
        if pageIdx >= #pages then
            FinishWizard(true)
        else
            ShowPage(pageIdx + 1)
        end
    end)

    f:SetScript("OnKeyDown", function(self, key)
        if kbWaitingFor then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            return
        end
        if key == "ESCAPE" then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            FinishWizard(false)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)

    return f
end

function Wizard:IsShown()
    return frame and frame:IsShown()
end

function Wizard:Show(startPage)
    -- Keyboard capture setup is protected in combat; silently decline.
    if InCombatLockdown() then return end
    CreateFrameOnce()
    if ns.Search and ns.Search.Hide then ns.Search:Hide() end
    local page = startPage or 1
    if page > #pages then page = #pages elseif page < 1 then page = 1 end
    pageIdx = page
    frame:Show()
    SafeCallMethod(frame, "EnableKeyboard", true)
    SafeCallMethod(frame, "SetPropagateKeyboardInput", true)
    ShowPage(page)
end

function Wizard:Hide()
    if frame then
        SafeCallMethod(frame, "EnableKeyboard", false)
        frame:Hide()
    end
end
