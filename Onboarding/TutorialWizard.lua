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
local GetBindingKey = GetBindingKey
local IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown = IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown

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
local MAP_SEARCH_TUTORIAL_IMAGE = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-map-search-hires"
local MAP_SEARCH_TUTORIAL_TEXCOORD = TutorialTexCoord(1326, 612, 2048, 1024)
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
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-shortkey-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_SHORTKEYS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-wowhead-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_WOWHEAD"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-filters-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["OPT_HOME_FILTER"],
        -- HD Gauntlet cursor on the filter button to show how to open the menu.
        overlay = {
            tex = GAUNTLET_CURSOR_TEX,
            texCoord = GAUNTLET_CURSOR_TEXCOORD,
            size = 34,
            ox = 367, oy = 16,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-quickfilters-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_AT_PREFIX"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-bags-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_QUICK_FILTERS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-currency-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_CURRENCY_REP"],
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
            ox = 285, oy = 152,
        },
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-settings-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_INLINE_SETTINGS"],
    },
}
local USE_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-01-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_GEAR"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-mounts-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_MOUNTS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-02-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_MACROS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-abilities-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_ABILITIES"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-03-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_TOYS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-commands-hires",
        texCoord = TutorialTexCoord(908, 420, 1024, 512),
        w = 454, h = 210,
        text = L["TUT_SLIDE_USE_COMMANDS"],
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
            ox = 372, oy = 100,
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

    holder.tile = tile
    return holder
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

    local function CreateDetailView(headerText, detailText, opts)
        opts = opts or {}
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, L["TUT_BTN_BACK_ARROW"], "ghost", 64)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, headerText, "GameFontNormalLarge", HEADER_MAX_W)
        h:SetPoint("TOP", d, "TOP", 0, -28)

        if opts.image then
            local image = d:CreateTexture(nil, "ARTWORK")
            SetTutorialImage(image, opts.image, opts.texCoord)
            image:SetSize(opts.imageW or 410, opts.imageH or 233)
            image:SetPoint("TOP", h, "BOTTOM", 0, -12)

            local body = BodyText(d, detailText or "")
            body:SetPoint("TOP", image, "BOTTOM", 0, -10)
            body:SetWidth(opts.textW or (WIZ_W - 96))
            body:SetJustifyH("LEFT")
            body:SetSpacing(2)
        else
            local body = BodyText(d, detailText or "")
            body:SetPoint("TOP", h, "BOTTOM", 0, -16)
            body:SetWidth(WIZ_W - 120)
        end

        detailViews[#detailViews + 1] = d
        return d
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
            if slideFlow then
                slideFlow:Hide()
                slideFlow:SetParent(nil)
                slideFlow = nil
            end
            slideFlow = ns.BuildFlowText(d, slide.text or "", {
                width = SLIDE_FLOW_WIDTH,
                font = "GameFontHighlightSmall",
                linkDispatch = linkDispatch,
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
    local d2 = CreateDetailView(L["TUT_FEATURE_MAP"],
        L["TUT_MAP_TAB_DESC"],
        { image = MAP_SEARCH_TUTORIAL_IMAGE, texCoord = MAP_SEARCH_TUTORIAL_TEXCOORD, imageW = 486, imageH = 224, textW = WIZ_W - 92 })
    local d3 = CreateCarouselDetailView(L["TUT_FEATURE_ACTIONS"], USE_TUTORIAL_SLIDES)
    actionsDeck = d3
    local d4 = CreateCarouselDetailView(L["TUT_FEATURE_CALCULATOR"], CALCULATOR_TUTORIAL_SLIDES)

    local t1 = FeatureTile(grid, nil, "Interface\\AddOns\\EasyFind\\textures\\Spyglass", nil,
        L["TUT_FEATURE_SEARCH"],
        L["TUT_FEATURE_SEARCH_DESC"],
        function() ShowDetail(d1) end)
    t1:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -96)

    local t2 = FeatureTile(grid, "Waypoint-MapPin-Untracked", nil, nil,
        L["TUT_FEATURE_MAP"],
        L["TUT_FEATURE_MAP_DESC"],
        function() ShowDetail(d2) end)
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
            if Utils.IsModifierKey(key) then return end
            if key == "ESCAPE" then
                StopKeybindCapture()
                return
            end
            local hasMod = IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()
            if not hasMod and Utils.IsReservedBareKey(key) then return end
            EasyFind:SetAccountKeybind(action, Utils.ModifierCombo(key))
            StopKeybindCapture()
        end)
    end)

    return w
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

    uiKb.btn:SetPoint("TOP", sub, "BOTTOM", 0, -34)
    uiKb.label:SetPoint("BOTTOM", uiKb.btn, "TOP", 0, 6)

    mapKb.btn:SetPoint("TOP", uiKb.btn, "BOTTOM", 0, -44)
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

    ns.CreateRoundedRectBorder(f)
    ns.SetRoundedRectBarHeight(f, 16)
    ns.SetRoundedRectBorderBgAlpha(f, PANEL_BG_ALPHA)
    -- Border ring hidden: its corner cells band against the gradient fill.
    ns.SetRoundedRectBorderEdgeShown(f, false)
    ns.SetRoundedRectBorderFillColor(f, 0.04, 0.04, 0.05, 1)

    -- Single vertical gradient mapped across the 9-slice; each cell's
    -- gradient stops are sampled from its vertical position in the frame.
    local function ApplyGloss(self)
        local fill = self.combinedBorder and self.combinedBorder.fill
        if not fill then return end
        local H = self:GetHeight()
        if not H or H <= 0 then return end
        local corner = (self.cbBarHeight or 32) / 2

        -- Pack the brightness ramp into the bottom 10% so 8-bit banding
        -- collapses into a couple-pixel transition; smoothstep so the
        -- slope varies and bands cannot space evenly.
        local DARK_FRAC = 0.90
        local function smoothstep(t)
            if t <= 0 then return 0 end
            if t >= 1 then return 1 end
            return t * t * (3 - 2 * t)
        end
        local function lerp(a, b, t) return a + (b - a) * t end
        local function colorAtY(y)
            local t = y / H
            if t < DARK_FRAC then t = 0
            else t = smoothstep((t - DARK_FRAC) / (1 - DARK_FRAC)) end
            return lerp(0.022, 0.20, t),
                   lerp(0.022, 0.20, t),
                   lerp(0.030, 0.22, t)
        end

        -- Relaxed pixel snapping lets the GPU sub-pixel-blend vertex
        -- colors instead of snapping color stops to the nearest pixel row.
        for _, cell in pairs(fill) do
            if cell.SetSnapToPixelGrid then cell:SetSnapToPixelGrid(false) end
            if cell.SetTexelSnappingBias then cell:SetTexelSnappingBias(0) end
        end

        local function ramp(cell, yTop, yBot)
            if not cell then return end
            local r1, g1, b1 = colorAtY(yTop)
            local r2, g2, b2 = colorAtY(yBot)
            -- VERTICAL: first color is bottom, second is top.
            cell:SetGradient("VERTICAL",
                CreateColor(r2, g2, b2, 1),
                CreateColor(r1, g1, b1, 1))
        end

        local yTopRowTop, yTopRowBot = 0,         corner
        local yMidRowTop, yMidRowBot = corner,    H - corner
        local yBotRowTop, yBotRowBot = H - corner, H

        ramp(fill.tl, yTopRowTop, yTopRowBot)
        ramp(fill.tm, yTopRowTop, yTopRowBot)
        ramp(fill.tr, yTopRowTop, yTopRowBot)
        ramp(fill.ml, yMidRowTop, yMidRowBot)
        ramp(fill.mm, yMidRowTop, yMidRowBot)
        ramp(fill.mr, yMidRowTop, yMidRowBot)
        ramp(fill.bl, yBotRowTop, yBotRowBot)
        ramp(fill.bm, yBotRowTop, yBotRowBot)
        ramp(fill.br, yBotRowTop, yBotRowBot)
    end
    ApplyGloss(f)
    f:HookScript("OnSizeChanged", ApplyGloss)

    local closeBtn = ns.CreateCloseX(f)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
    closeBtn:SetScript("OnClick", function() FinishWizard(false) end)

    local pageHost = CreateFrame("Frame", nil, f)
    pageHost:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    pageHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 6 + BANNER_H + 4)

    pages = {
        BuildPage1(pageHost),
        BuildPage2(pageHost),
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
