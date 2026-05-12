local _, ns = ...

local Wizard = {}
ns.Wizard = Wizard

local Utils = ns.Utils
local SafeCallMethod = Utils.SafeCallMethod
local SafeAfter = Utils.SafeAfter

local CreateFrame   = CreateFrame
local UIParent      = UIParent
local GetBindingKey = GetBindingKey
local SetBinding    = SetBinding
local SaveBindings  = SaveBindings
local GetCurrentBindingSet = GetCurrentBindingSet
local IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown = IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown

local GOLD       = ns.GOLD_COLOR or { 1.0, 0.82, 0.0 }
local WIZ_W, WIZ_H = 544, 408
local TOGGLE_ACTION = "EASYFIND_TOGGLE_FOCUS"
local MAP_ACTION    = "EASYFIND_MAP_FOCUS"

local PANEL_BG_ALPHA = 0.97
local TEXT_PRIM      = { 1.00, 0.97, 0.86 }
local TEXT_BODY      = { 0.78, 0.78, 0.80 }
local TEXT_DIM       = { 0.55, 0.55, 0.58 }

local DOT_FILLED = "Interface\\COMMON\\Indicator-Yellow"

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
    local h = (variant == "rounded") and 26 or 24
    b:SetSize(w or 96, h)

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    ApplyInter(fs, "semibold", 12)
    b._label = fs

    if variant == "rounded" then
        ns.CreateRoundedRectBorder(b)
        ns.SetRoundedRectBarHeight(b, 10)
        ns.SetRoundedRectBorderBgAlpha(b, 1)
        -- Border ring hidden: 256px texture aliases badly at ~5px corners.
        if b.combinedBorder and b.combinedBorder.border then
            for _, t in pairs(b.combinedBorder.border) do
                t:Hide()
            end
        end
        if b.combinedBorder and b.combinedBorder.fill then
            for _, t in pairs(b.combinedBorder.fill) do
                if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
                if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
            end
        end
        local function tintFill(rr, gg, bb)
            if not (b.combinedBorder and b.combinedBorder.fill) then return end
            for _, t in pairs(b.combinedBorder.fill) do
                t:SetVertexColor(rr, gg, bb, 1)
            end
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
            fs:SetTextColor(TEXT_PRIM[1], TEXT_PRIM[2], TEXT_PRIM[3], 1)
        else
            fs:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], 1)
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
            d:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
            d:SetSize(11, 11)
        else
            d:SetVertexColor(0.32, 0.32, 0.36, 1)
            d:SetSize(9, 9)
        end
    end
    backBtn:SetShown(i > 1)
    if i == #pages then
        nextBtn._label:SetText("Open Bar")
    elseif i == 1 then
        nextBtn._label:SetText("Get Started")
    else
        nextBtn._label:SetText("Continue")
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
    if openBar and ns.UI and ns.UI.Show then
        SafeAfter(0.05, function() ns.UI:Show(true) end)
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
    fs:SetTextColor(TEXT_PRIM[1], TEXT_PRIM[2], TEXT_PRIM[3], 1)
    return fs
end

local function BodyText(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ApplyInter(fs, "regular")
    fs:SetText(text)
    fs:SetTextColor(TEXT_BODY[1], TEXT_BODY[2], TEXT_BODY[3], 1)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(4)
    return fs
end

local function BuildPage1(parent)
    local p = MakePage(parent)

    local logo = p:CreateTexture(nil, "OVERLAY")
    logo:SetSize(108, 108)
    logo:SetTexture("Interface\\AddOns\\EasyFind\\Textures\\Spyglass")
    logo:SetPoint("TOP", p, "TOP", 0, -40)

    local version = ns.version or (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("EasyFind", "Version")) or "2.0.0"
    local title = HeaderText(p, "Welcome to EasyFind v" .. version)
    title:SetPoint("TOP", logo, "BOTTOM", 0, -22)
    do
        local path, sz, fl = title:GetFont()
        if sz then title:SetFont(path, sz * 1.5, fl or "") end
    end

    local sub = BodyText(p, "Your shortcut to everything in WoW.")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -16)
    sub:SetWidth(WIZ_W - 120)
    sub:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], 1)

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
    if tile.combinedBorder and tile.combinedBorder.fill then
        for _, t in pairs(tile.combinedBorder.fill) do
            t:SetVertexColor(0.05, 0.05, 0.06, 1)
            if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
            if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        end
    end
    if tile.combinedBorder and tile.combinedBorder.border then
        for _, t in pairs(tile.combinedBorder.border) do t:Hide() end
    end

    local icon = tile:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", tile, "TOPLEFT", 14, -14)
    if atlas then
        icon:SetAtlas(atlas)
    elseif file then
        icon:SetTexture(file)
        if coords then icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
    end

    local fs = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(title)
    fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1)
    fs:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
    ApplyInter(fs, "semibold")

    local body = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetText(desc)
    body:SetTextColor(TEXT_BODY[1], TEXT_BODY[2], TEXT_BODY[3], 1)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(2)
    body:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -6)
    body:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
    ApplyInter(body, "regular")

    tile:SetScript("OnEnter", function(self)
        self:SetScale(1.04)
        if self.combinedBorder and self.combinedBorder.fill then
            for _, t in pairs(self.combinedBorder.fill) do
                t:SetVertexColor(0.09, 0.09, 0.11, 1)
            end
        end
    end)
    tile:SetScript("OnLeave", function(self)
        self:SetScale(1.00)
        if self.combinedBorder and self.combinedBorder.fill then
            for _, t in pairs(self.combinedBorder.fill) do
                t:SetVertexColor(0.05, 0.05, 0.06, 1)
            end
        end
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

    local title = HeaderText(grid, "What you can do", "GameFontNormalLarge")
    title:SetPoint("TOP", grid, "TOP", 0, -28)

    local sub = BodyText(grid, "Type once. Find anything.")
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

    local function CreateDetailView(headerText, detailText)
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, "< Back", "ghost", 64)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, headerText, "GameFontNormalLarge")
        h:SetPoint("TOP", d, "TOP", 0, -28)

        local body = BodyText(d, detailText or "")
        body:SetPoint("TOP", h, "BOTTOM", 0, -16)
        body:SetWidth(WIZ_W - 120)

        detailViews[#detailViews + 1] = d
        return d
    end

    local d1 = CreateDetailView("Search",
        "Search panels, settings, achievements, statistics, abilities, talents, titles, reputations, currencies, mounts, toys, pets, outfits, transmogs, heirlooms, gear sets, bag items, bosses, loot, macros, map places, and addon options.\n\n" ..
        "Right-click a result for contextual actions like Guide, Pin, Add Alias, favorite toggles, tracking, pet actions, and other row-specific tools. Pins keep important results available before typing; aliases let your own words find the same result.")
    local d2 = CreateDetailView("Map Search Tab",
        "Use the Map Search tab for location-first browsing: banks, flight masters, dungeons, raids, zones, and useful points of interest.")
    local d3 = CreateDetailView("Item/Ability Use",
        "Use supported results directly from the list: cast abilities, summon mounts and pets, use toys, swap outfits, view or try on transmogs, add heirlooms to bags, consume usable bag items, equip gear from bags, and open ordinary bag items in their bag slot.")
    local d4 = CreateDetailView("Calculator",
        "Type math straight into search, including 1+23, 1*7, sin(30), tan(45), or 5!. Select the expression or result and press Ctrl+C, or press Alt+C to open the calculator.")

    local t1 = FeatureTile(grid, nil, "Interface\\AddOns\\EasyFind\\Textures\\Spyglass", nil,
        "Search",
        "Search any panel, tab, setting, mount, toy, currency, achievement, or vendor item.",
        function() ShowDetail(d1) end)
    t1:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -96)

    local t2 = FeatureTile(grid, "Waypoint-MapPin-Untracked", nil, nil,
        "Map Search Tab",
        "Dedicated map browsing for banks, flight masters, dungeons, raids, and zones. Also reachable from Standard Search.",
        function() ShowDetail(d2) end)
    t2:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -38, -96)

    -- Anchor each lower tile to the grid so a hover scale doesn't move its sibling.
    local t3 = FeatureTile(grid, "UI-HUD-MicroMenu-SpellbookAbilities-Up", nil, nil,
        "Item/Ability Use",
        "Cast, use, equip, summon, swap, or open supported results directly from the list.",
        function() ShowDetail(d3) end)
    t3:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -222)

    local t4 = FeatureTile(grid, nil, "Interface\\Icons\\INV_Misc_Note_05", nil,
        "Calculator",
        "Type expressions, copy the result, or open the full calculator with Alt+C.",
        function() ShowDetail(d4) end)
    t4:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -38, -222)

    p.OnEnter = ShowGrid

    return p
end

local kbWidgets = {}
local kbWaitingFor

local function RefreshKbWidget(widget)
    local cur = GetBindingKey(widget.action)
    widget.btn._label:SetText(cur or "Not bound")
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
    lbl:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], 1)
    ApplyInter(lbl, "regular")
    w.label = lbl

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(208, 40)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    w.btn = btn

    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, 40)
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    if btn.combinedBorder and btn.combinedBorder.border then
        for _, t in pairs(btn.combinedBorder.border) do
            t:Hide()
        end
    end
    if btn.combinedBorder and btn.combinedBorder.fill then
        for _, t in pairs(btn.combinedBorder.fill) do
            t:SetVertexColor(0.18, 0.18, 0.20, 1)
        end
    end

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("CENTER")
    ApplyInter(fs, "semibold")
    btn._label = fs

    local function tintFill(rr, gg, bb)
        if not (btn.combinedBorder and btn.combinedBorder.fill) then return end
        for _, t in pairs(btn.combinedBorder.fill) do
            t:SetVertexColor(rr, gg, bb, 1)
        end
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
            local o1, o2 = GetBindingKey(action)
            if o1 then SetBinding(o1) end
            if o2 then SetBinding(o2) end
            SaveBindings(GetCurrentBindingSet())
            RefreshKbWidget(w)
            return
        end
        if kbWaitingFor == w then
            StopKeybindCapture()
            return
        end
        if kbWaitingFor then StopKeybindCapture() end
        kbWaitingFor = w
        self._label:SetText("Press a key...")
        SafeCallMethod(self, "EnableKeyboard", true)
        self:SetScript("OnKeyDown", function(s, key)
            if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
               or key == "LALT" or key == "RALT" then return end
            if key == "ESCAPE" then
                StopKeybindCapture()
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
            local o1, o2 = GetBindingKey(action)
            if o1 then SetBinding(o1) end
            if o2 then SetBinding(o2) end
            SetBinding(combo, action)
            SaveBindings(GetCurrentBindingSet())
            StopKeybindCapture()
        end)
    end)

    return w
end

local function BuildPage3(parent)
    local p = MakePage(parent)

    local title = HeaderText(p, "Pick your hotkeys", "GameFontNormalLarge")
    title:SetPoint("TOP", p, "TOP", 0, -36)

    local sub = BodyText(p, "")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -10)
    sub:SetWidth(WIZ_W - 100)

    local uiKb  = CreateKbWidget(p, TOGGLE_ACTION, "Search Bar")
    local mapKb = CreateKbWidget(p, MAP_ACTION,    "Map Search Tab")
    kbWidgets = { uiKb, mapKb }

    uiKb.label:SetPoint("RIGHT", uiKb.btn, "LEFT", -14, 0)
    uiKb.btn:SetPoint("TOP", sub, "BOTTOM", 40, -38)

    mapKb.label:SetPoint("RIGHT", mapKb.btn, "LEFT", -14, 0)
    mapKb.btn:SetPoint("TOP", uiKb.btn, "BOTTOM", 0, -16)

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetText("Click a button, then press your keys. Right-click to clear. Esc cancels capture.")
    hint:SetTextColor(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3], 1)
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

local BANNER_H = 38

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
    if f.combinedBorder and f.combinedBorder.border then
        for _, t in pairs(f.combinedBorder.border) do
            t:Hide()
        end
    end
    if f.combinedBorder and f.combinedBorder.fill then
        for _, t in pairs(f.combinedBorder.fill) do
            t:SetVertexColor(0.04, 0.04, 0.05, 1)
        end
    end

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

    -- Two rotated 1px lines so the X stays sharp at any UI scale.
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
    setX(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3])
    closeBtn:SetScript("OnEnter", function() setX(1, 1, 1) end)
    closeBtn:SetScript("OnLeave", function() setX(TEXT_DIM[1], TEXT_DIM[2], TEXT_DIM[3]) end)
    closeBtn:SetScript("OnClick", function() FinishWizard(false) end)

    local pageHost = CreateFrame("Frame", nil, f)
    pageHost:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    pageHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 6 + BANNER_H + 4)

    pages = {
        BuildPage1(pageHost),
        BuildPage2(pageHost),
        BuildPage3(pageHost),
    }

    local BANNER_INSET = 6
    local footer = CreateFrame("Frame", nil, f)
    footer:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  BANNER_INSET, BANNER_INSET)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BANNER_INSET, BANNER_INSET)
    footer:SetHeight(BANNER_H)
    ns.CreateRoundedRectBorder(footer)
    ns.SetRoundedRectBarHeight(footer, 16)
    ns.SetRoundedRectBorderBgAlpha(footer, 1)
    if footer.combinedBorder and footer.combinedBorder.fill then
        for _, t in pairs(footer.combinedBorder.fill) do
            t:SetVertexColor(0.075, 0.075, 0.085, 1)
            if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
            if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        end
    end
    if footer.combinedBorder and footer.combinedBorder.border then
        for _, t in pairs(footer.combinedBorder.border) do t:Hide() end
    end

    local DOT_GAP = 14
    local DOT_SZ  = 9
    local DOT_ACTIVE = 11
    for i = 1, #pages do
        local d = footer:CreateTexture(nil, "OVERLAY")
        d:SetSize(DOT_SZ, DOT_SZ)
        d:SetTexture(DOT_FILLED)
        d:SetPoint("LEFT", footer, "LEFT", 14 + DOT_ACTIVE / 2 + (i - 1) * (DOT_SZ + DOT_GAP), 0)
        dots[i] = d
    end

    nextBtn = MakeButton(footer, "Continue", "rounded", 96)
    nextBtn:SetPoint("RIGHT", footer, "RIGHT", -10, 0)

    backBtn = MakeButton(footer, "Back", "ghost", 50)
    backBtn:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
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
    if ns.UI and ns.UI.Hide then ns.UI:Hide() end
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
