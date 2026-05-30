local _, ns = ...

local Wizard = {}
ns.Wizard = Wizard

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
local TUTORIAL_IMAGE_MAX_W = 486
local TUTORIAL_IMAGE_MAX_H = 218
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
local SEARCH_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-01-hires",
        texCoord = TutorialTexCoord(1302, 404, 2048, 512),
        w = 651, h = 202,
        text = L["TUT_SLIDE_SEARCH_INTRO"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-02-hires",
        texCoord = TutorialTexCoord(1310, 534, 2048, 1024),
        w = 655, h = 267,
        text = L["TUT_SLIDE_ALT_NUMBERS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-09-hires",
        texCoord = TutorialTexCoord(972, 436, 1024, 512),
        w = 486, h = 218,
        text = L["TUT_SLIDE_PINNING"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-03-hires",
        texCoord = TutorialTexCoord(1324, 1222, 2048, 2048),
        w = 662, h = 611,
        text = L["TUT_SLIDE_FILTER_MENU"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-05-hires",
        texCoord = TutorialTexCoord(1314, 1186, 2048, 2048),
        w = 657, h = 593,
        text = L["TUT_SLIDE_AT_PREFIX"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-04-hires",
        texCoord = TutorialTexCoord(1344, 440, 2048, 512),
        w = 672, h = 220,
        text = L["TUT_SLIDE_QUICK_FILTERS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-06-hires",
        texCoord = TutorialTexCoord(1320, 534, 2048, 1024),
        w = 660, h = 267,
        text = L["TUT_SLIDE_QUICK_FILTERS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-07-hires",
        texCoord = TutorialTexCoord(1316, 552, 2048, 1024),
        w = 658, h = 276,
        text = L["TUT_SLIDE_MACROS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-search-08-hires",
        texCoord = TutorialTexCoord(1292, 530, 2048, 1024),
        w = 646, h = 265,
        text = L["TUT_SLIDE_INLINE_SETTINGS"],
    },
}
local USE_TUTORIAL_SLIDES = {
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-01-hires",
        texCoord = TutorialTexCoord(1316, 304, 2048, 512),
        w = 658, h = 152,
        text = L["TUT_SLIDE_USE_GEAR"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-02-hires",
        texCoord = TutorialTexCoord(1316, 552, 2048, 1024),
        w = 658, h = 276,
        text = L["TUT_SLIDE_USE_MACROS"],
    },
    {
        image = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-use-03-hires",
        texCoord = TutorialTexCoord(1314, 890, 2048, 1024),
        w = 657, h = 445,
        text = L["TUT_SLIDE_USE_TOYS"],
    },
}
local CALCULATOR_TUTORIAL_IMAGE = "Interface\\AddOns\\EasyFind\\Onboarding\\Images\\tutorial-calculator-visual-hires"
local CALCULATOR_TUTORIAL_TEXCOORD = TutorialTexCoord(1944, 896, 2048, 1024)

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

local function HeaderText(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalHuge")
    ApplyInter(fs, "semibold")
    fs:SetText(text)
    fs:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    return fs
end

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
    local title = HeaderText(p, L["TUT_WELCOME_TITLE"]:format(version))
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
    fs:SetText(title)
    fs:SetTextColor(Utils.RGB(GOLD, 1))
    fs:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
    ApplyInter(fs, "semibold")

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

local function BuildPage2(parent)
    local p = MakePage(parent)

    local grid = CreateFrame("Frame", nil, p)
    grid:SetAllPoints(p)

    local title = HeaderText(grid, L["TUT_FEATURES_TITLE"], "GameFontNormalLarge")
    title:SetPoint("TOP", grid, "TOP", 0, -28)

    local sub = BodyText(grid, L["TUT_FEATURES_SUBTITLE"])
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)

    local detailViews = {}

    local function ShowGrid()
        grid:Show()
        for i = 1, #detailViews do detailViews[i]:Hide() end
    end

    local function ShowDetail(d)
        grid:Hide()
        for i = 1, #detailViews do detailViews[i]:Hide() end
        d:Show()
    end

    local function CreateDetailView(headerText, detailText, opts)
        opts = opts or {}
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, L["TUT_BTN_BACK_ARROW"], "ghost", 64)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, headerText, "GameFontNormalLarge")
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

        local h = HeaderText(d, headerText, "GameFontNormalLarge")
        h:SetPoint("TOP", d, "TOP", 0, -28)

        local image = d:CreateTexture(nil, "ARTWORK")
        image:SetPoint("TOP", h, "BOTTOM", 0, -10)

        local slideText = BodyText(d, "")
        slideText:SetPoint("TOP", image, "BOTTOM", 0, -8)
        slideText:SetWidth(WIZ_W - 104)
        slideText:SetJustifyH("LEFT")
        slideText:SetSpacing(2)

        local controls = CreateFrame("Frame", nil, d)
        controls:SetSize(148, 18)
        controls:SetPoint("BOTTOM", d, "BOTTOM", 0, 6)

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
            SetTutorialImage(image, slide.image, slide.texCoord)
            local w, hgt = FitSize(slide.w, slide.h, TUTORIAL_IMAGE_MAX_W, TUTORIAL_IMAGE_MAX_H)
            image:SetSize(w, hgt)
            slideText:SetText(slide.text or "")
            counter:SetText(idx .. " / " .. count)
        end

        prev:SetScript("OnClick", function() ShowSlide(idx - 1) end)
        next:SetScript("OnClick", function() ShowSlide(idx + 1) end)
        d.OnEnter = function() ShowSlide(idx) end
        ShowSlide(1)

        detailViews[#detailViews + 1] = d
        return d
    end

    local function CreateCalculatorDetailView()
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, L["TUT_BTN_BACK_ARROW"], "ghost", 52)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, L["TUT_FEATURE_CALCULATOR"], "GameFontNormalLarge")
        h:SetPoint("TOP", d, "TOP", 0, -28)

        local visual = d:CreateTexture(nil, "ARTWORK")
        SetTutorialImage(visual, CALCULATOR_TUTORIAL_IMAGE, CALCULATOR_TUTORIAL_TEXCOORD)
        visual:SetSize(486, 224)
        visual:SetPoint("TOP", h, "BOTTOM", 0, -10)

        local body = BodyText(d,
            "Type math into search for instant results, or search calculator and press Alt+C to open the full calculator.")
        body:SetPoint("TOP", visual, "BOTTOM", 0, -10)
        body:SetWidth(WIZ_W - 104)
        body:SetJustifyH("LEFT")
        body:SetSpacing(2)

        detailViews[#detailViews + 1] = d
        return d
    end

    local d1 = CreateCarouselDetailView(L["TUT_FEATURE_SEARCH"], SEARCH_TUTORIAL_SLIDES)
    local d2 = CreateDetailView(L["TUT_FEATURE_MAP"],
        L["TUT_MAP_TAB_DESC"],
        { image = MAP_SEARCH_TUTORIAL_IMAGE, texCoord = MAP_SEARCH_TUTORIAL_TEXCOORD, imageW = 486, imageH = 224, textW = WIZ_W - 92 })
    local d3 = CreateCarouselDetailView(L["TUT_FEATURE_ACTIONS"], USE_TUTORIAL_SLIDES)
    local d4 = CreateCalculatorDetailView()

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

    local title = HeaderText(p, L["TUT_KEYBIND_HEADER"], "GameFontNormalLarge")
    title:SetPoint("TOP", p, "TOP", 0, -36)

    local sub = BodyText(p, "")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -10)
    sub:SetWidth(WIZ_W - 100)

    local uiKb  = CreateKbWidget(p, TOGGLE_ACTION, L["TUT_KEYBIND_SEARCH_BAR"])
    local mapKb = CreateKbWidget(p, MAP_ACTION,    L["TUT_KEYBIND_MAP_TAB"])
    kbWidgets = { uiKb, mapKb }

    uiKb.label:SetPoint("RIGHT", uiKb.btn, "LEFT", -14, 0)
    uiKb.btn:SetPoint("TOP", sub, "BOTTOM", 0, -38)

    mapKb.label:SetPoint("RIGHT", mapKb.btn, "LEFT", -14, 0)
    mapKb.btn:SetPoint("TOP", uiKb.btn, "BOTTOM", 0, -32)

    -- recommended bindings, shown as a labeled column to the right of the buttons
    local uiRec = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    uiRec:SetText("Alt + Space")
    uiRec:SetPoint("LEFT", uiKb.btn, "RIGHT", 16, 0)
    uiRec:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    ApplyInter(uiRec, "semibold")

    local mapRec = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mapRec:SetText("Alt + M")
    mapRec:SetPoint("LEFT", mapKb.btn, "RIGHT", 16, 0)
    mapRec:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    ApplyInter(mapRec, "semibold")

    local recHeader = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    recHeader:SetText(L["TUT_KEYBIND_RECOMMENDED"])
    recHeader:SetPoint("BOTTOMLEFT", uiRec, "TOPLEFT", 0, 10)
    recHeader:SetTextColor(Utils.RGB(TEXT_DIM, 1))
    ApplyInter(recHeader, "regular")

    local recHeader2 = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    recHeader2:SetText(L["TUT_KEYBIND_RECOMMENDED"])
    recHeader2:SetPoint("BOTTOMLEFT", mapRec, "TOPLEFT", 0, 10)
    recHeader2:SetTextColor(Utils.RGB(TEXT_DIM, 1))
    ApplyInter(recHeader2, "regular")

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

    -- Two rotated 1px lines so the X stays sharp at any Search scale.
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
    local function MakeStroke()
        local t = closeBtn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetSize(16, 1.5)
        t:SetPoint("CENTER")
        return t
    end
    local stroke1 = MakeStroke(); stroke1:SetRotation(math.pi / 4)
    local stroke2 = MakeStroke(); stroke2:SetRotation(-math.pi / 4)
    local function setX(r, g, b)
        stroke1:SetVertexColor(r, g, b, 1)
        stroke2:SetVertexColor(r, g, b, 1)
    end
    setX(Utils.RGB(TEXT_DIM))
    closeBtn:SetScript("OnEnter", function() setX(1, 1, 1) end)
    closeBtn:SetScript("OnLeave", function() setX(Utils.RGB(TEXT_DIM)) end)
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

function Wizard:Show()
    CreateFrameOnce()
    if ns.Search and ns.Search.Hide then ns.Search:Hide() end
    pageIdx = 1
    frame:Show()
    SafeCallMethod(frame, "EnableKeyboard", true)
    SafeCallMethod(frame, "SetPropagateKeyboardInput", true)
    ShowPage(1)
end

function Wizard:Hide()
    if frame then
        SafeCallMethod(frame, "EnableKeyboard", false)
        frame:Hide()
    end
end
