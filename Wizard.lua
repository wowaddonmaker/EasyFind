local _, ns = ...

local Wizard = {}
ns.Wizard = Wizard

local Utils = ns.Utils
local SafeCallMethod = Utils.SafeCallMethod
local SafeAfter = Utils.SafeAfter or function(d, fn) C_Timer.After(d, fn) end

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

-- Wizard FontStrings opt into the user-selectable font system. The
-- registry tracks each one so the Options "Font" selector can re-apply
-- on change without re-creating the wizard. By default it's "Default"
-- (Friz Quadrata via the original GameFont template); picking "Inter"
-- swaps each registered string to the matching Inter weight.
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

-- Two visual styles, both monochrome:
--   solid   : subtle dark fill, dim text that brightens on hover
--   ghost   : no fill at all, dim text that brightens on hover
--   rounded : same TC9 rounded-pill silhouette the keybind buttons use,
--             dark gray fill, white text always
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
        -- Half this gives the corner radius. ~5px corners read as
        -- "rounded but not a pill" -- enough softness to feel
        -- modern, not so much it loses button identity.
        ns.SetRoundedRectBarHeight(b, 10)
        ns.SetRoundedRectBorderBgAlpha(b, 1)
        -- Hide the perimeter ring entirely; at 5-px corners the
        -- 256-px border texture downscales to a stairstep that no
        -- amount of pixel-snap tweaking smooths over. Just the fill
        -- silhouette reads as a clean rounded rectangle.
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
    if EasyFind.db.lastSeenVersion == nil then
        EasyFind.db.lastSeenVersion = ns.version
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
    -- Inter SemiBold at the size already implied by the GameFont
    -- template (the SetFont call below preserves size automatically).
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
    -- 50% larger than the GameFontNormalHuge baseline.
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
    -- Holder owns the external anchor (TOPLEFT/TOPRIGHT in BuildPage2).
    -- The tile inside is pinned to the holder's CENTER so SetScale
    -- grows the tile symmetrically around its midpoint instead of
    -- expanding from a corner.
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(222, 112)

    local tile = CreateFrame("Button", nil, holder)
    tile:SetSize(222, 112)
    tile:SetPoint("CENTER", holder, "CENTER", 0, 0)
    tile:RegisterForClicks("LeftButtonUp")

    -- Soft rounded silhouette via the same TC9 fill the search bar
    -- uses; corner radius = ~6px so the box reads as "rounded but not
    -- a pill". Hide the bright perimeter ring (it aliases at small
    -- corner sizes) and skip a separate edge layer -- the rounded
    -- fill alone defines the shape.
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

    -- Hover lift: scale the tile up symmetrically. Because the tile
    -- is anchored to the holder's CENTER, SetScale grows it outward
    -- around that midpoint rather than expanding from a corner.
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

    -- Page 2 has two states: a 4-tile grid and per-tile detail views.
    -- Both states are full-page subframes; clicking a tile swaps grid
    -- for that tile's detail; the in-detail back arrow returns to grid.
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

    local function CreateDetailView(headerText)
        local d = CreateFrame("Frame", nil, p)
        d:SetAllPoints(p)
        d:Hide()

        local back = MakeButton(d, "< Back", "ghost", 64)
        back:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
        back:SetScript("OnClick", ShowGrid)

        local h = HeaderText(d, headerText, "GameFontNormalLarge")
        h:SetPoint("TOP", d, "TOP", 0, -28)

        local body = BodyText(d, "Details coming soon.")
        body:SetPoint("TOP", h, "BOTTOM", 0, -16)
        body:SetWidth(WIZ_W - 120)

        detailViews[#detailViews + 1] = d
        return d
    end

    local d1 = CreateDetailView("Search")
    local d2 = CreateDetailView("Map Search Tab")
    local d3 = CreateDetailView("Click & Right-click")
    local d4 = CreateDetailView("Pin Anything")

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

    -- Anchor lower-row tiles directly to the grid so a tile's hover
    -- scale doesn't ripple position changes onto its neighbor.
    local t3 = FeatureTile(grid, "UI-HUD-MicroMenu-SpellbookAbilities-Up", nil, nil,
        "Click & Right-click",
        "Left-click activates the result (cast, use, equip, navigate). Right-click opens Pin / Alias / Guide menu.",
        function() ShowDetail(d3) end)
    t3:SetPoint("TOPLEFT", grid, "TOPLEFT", 38, -222)

    local t4 = FeatureTile(grid, "Waypoint-MapPin-ChatIcon", nil, nil,
        "Pin Anything",
        "Pin frequently-used results for quick access.",
        function() ShowDetail(d4) end)
    t4:SetPoint("TOPRIGHT", grid, "TOPRIGHT", -38, -222)

    -- Reset to grid each time the page is entered so navigating away
    -- and back doesn't leave a stale detail view open.
    p.OnEnter = ShowGrid

    return p
end

-- One capture-button widget per binding. Rounded fill (same TC9
-- 9-slice the search bar uses, pinned at button height for a true
-- pill silhouette) plus a soft center glow stack -- two stacked
-- white squares with low alpha and ADD blend, the smaller one
-- brighter, fading outward like a worn-down key polished by years
-- of presses. Right-click clears the binding, Esc cancels capture.
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

    -- Rounded silhouette (corner radius = btnHeight/2 = 20px = full pill).
    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, 40)
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    -- Hide the perimeter ring; the fill silhouette alone reads as a
    -- clean rounded rectangle and avoids the aliased outline.
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

    -- Worn-key center glow: two horizontal-gradient halves meeting at
    -- the button's centerline. Each half fades from transparent at
    -- the outer edge to a soft warm tint at the centerline, so the
    -- composite peaks in the middle and dies away symmetrically.
    -- ADD blend keeps the rounded silhouette unaffected. Glow height
    -- is kept inside the rounded interior so its rectangular top
    -- and bottom edges fall within the flat middle of the pill.
    local function MakeGlowHalf(anchorEdge, fromAlpha, toAlpha)
        local g = btn:CreateTexture(nil, "ARTWORK")
        g:SetTexture("Interface\\Buttons\\WHITE8x8")
        g:SetBlendMode("ADD")
        g:SetSize(80, 18)
        g:SetPoint(anchorEdge, btn, "CENTER", 0, 0)
        g:SetGradient("HORIZONTAL",
            CreateColor(1, 0.96, 0.82, fromAlpha),
            CreateColor(1, 0.96, 0.82, toAlpha))
        return g
    end
    local glowL = MakeGlowHalf("RIGHT", 0, 0.07)
    local glowR = MakeGlowHalf("LEFT",  0.07, 0)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("CENTER")
    ApplyInter(fs, "semibold")
    btn._label = fs

    local function setHover(hover)
        local peak = hover and 0.14 or 0.07
        glowL:SetGradient("HORIZONTAL",
            CreateColor(1, 0.96, 0.82, 0),
            CreateColor(1, 0.96, 0.82, peak))
        glowR:SetGradient("HORIZONTAL",
            CreateColor(1, 0.96, 0.82, peak),
            CreateColor(1, 0.96, 0.82, 0))
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

    local sub = BodyText(p,
        "These are the key combos that open each search bar.\n" ..
        "Ctrl+Space and Ctrl+M are clean defaults, but anything works.")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -10)
    sub:SetWidth(WIZ_W - 100)

    local uiKb  = CreateKbWidget(p, TOGGLE_ACTION, "Search Bar")
    local mapKb = CreateKbWidget(p, MAP_ACTION,    "Map Search")
    kbWidgets = { uiKb, mapKb }

    -- Stacked layout: search bar on top, map search below.
    uiKb.label:SetPoint("RIGHT", uiKb.btn, "LEFT", -14, 0)
    uiKb.btn:SetPoint("TOP", sub, "BOTTOM", 40, -28)

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
        -- First-time default: if the player hasn't bound the map
        -- search yet, suggest CTRL-M. Doesn't override existing
        -- bindings or other actions already on that combo.
        if not GetBindingKey(MAP_ACTION) then
            local ownerOfCtrlM = GetBindingAction and GetBindingAction("CTRL-M")
            if not ownerOfCtrlM or ownerOfCtrlM == "" then
                SetBinding("CTRL-M", MAP_ACTION)
                SaveBindings(GetCurrentBindingSet())
            end
        end
        for i = 1, #kbWidgets do RefreshKbWidget(kbWidgets[i]) end
    end

    return p
end

local function BulletRow(parent, header, body)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(WIZ_W - 110, 1)

    local dot = row:CreateTexture(nil, "OVERLAY")
    dot:SetSize(6, 6)
    dot:SetTexture(DOT_FILLED)
    dot:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    dot:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -6)

    local h = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetText(header)
    h:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1)
    h:SetPoint("TOPLEFT", dot, "TOPRIGHT", 10, 6)
    ApplyInter(h, "semibold")

    local b = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b:SetText(body)
    b:SetTextColor(TEXT_BODY[1], TEXT_BODY[2], TEXT_BODY[3], 1)
    b:SetJustifyH("LEFT")
    b:SetJustifyV("TOP")
    b:SetSpacing(2)
    b:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -2)
    b:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    ApplyInter(b, "regular")

    row:SetHeight(h:GetStringHeight() + b:GetStringHeight() + 10)
    row.header = h
    row.body = b
    return row
end

local function BuildPage4(parent)
    local p = MakePage(parent)

    local title = HeaderText(p, "You're all set", "GameFontNormalLarge")
    title:SetPoint("TOP", p, "TOP", 0, -28)

    local sub = BodyText(p, "A few last things to know.")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)

    local rows = {}

    local r1 = BulletRow(p,
        "Open it",
        "Press your hotkey to open the search bar from anywhere. Click outside (or pick a result) and it tucks away.")
    r1:SetPoint("TOPLEFT", p, "TOPLEFT", 50, -84)
    rows[1] = r1

    local r2 = BulletRow(p,
        "Move it",
        "Drag the bar anywhere on the screen. Lock it from Options if you don't want it moving.")
    r2:SetPoint("TOPLEFT", r1, "BOTTOMLEFT", 0, -10)

    local r3 = BulletRow(p,
        "Reset its spot",
        "Type :reset in the search bar to send it back to the top of the screen, or use Reset Positions in Options.")
    r3:SetPoint("TOPLEFT", r2, "BOTTOMLEFT", 0, -10)

    local r4 = BulletRow(p,
        "Tweak everything",
        "Type /ef to open Options: themes, indicator style, hotkeys, filters, map pins, and more.")
    r4:SetPoint("TOPLEFT", r3, "BOTTOMLEFT", 0, -10)

    p.OnEnter = function()
        local current = GetBindingKey(TOGGLE_ACTION)
        local bindLabel = current
            and ("|cffFFD100" .. current .. "|r")
            or  "|cffff6e6e(no key bound; set one in Options)|r"
        rows[1].body:SetText(
            "Press " .. bindLabel .. " to open the search bar from anywhere. Click outside (or pick a result) and it tucks away.")
        rows[1]:SetHeight(rows[1].header:GetStringHeight() + rows[1].body:GetStringHeight() + 10)
    end

    return p
end

local BANNER_H = 38

local function CreateFrameOnce()
    if frame then return frame end

    local f = CreateFrame("Frame", "EasyFindWizard", UIParent)
    f:SetSize(WIZ_W, WIZ_H)
    -- Shrink the wizard's overall footprint without resizing internal
    -- layout (fonts, buttons, anchors all stay the same pixel sizes).
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

    -- Same rounded rect 9-slice the search bar / results panel use.
    -- Pin a small bar height so the corner radius is fixed at ~10px
    -- instead of half the frame height. Tint the fill dark gray
    -- (not pure black) so it reads as a panel rather than a void.
    ns.CreateRoundedRectBorder(f)
    ns.SetRoundedRectBarHeight(f, 16)
    ns.SetRoundedRectBorderBgAlpha(f, PANEL_BG_ALPHA)
    -- Hide the bright border ring; its corner cells render as visible
    -- horizontal bands against the gradient fill, breaking the smooth
    -- top-to-bottom gloss. The fill silhouette is enough.
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

    -- Glossy sheen: one continuous vertical gradient mapped across the
    -- 9-slice. Each cell receives gradient stops sampled from its
    -- vertical position in the frame (top corners get the top of the
    -- ramp, middle row spans the bulk of the gradient, bottom corners
    -- get the bottom). The result reads as one smooth top-to-bottom
    -- gloss across the whole panel; the texture's alpha handles the
    -- rounded silhouette so nothing pokes past the corners.
    local function ApplyGloss(self)
        local fill = self.combinedBorder and self.combinedBorder.fill
        if not fill then return end
        local H = self:GetHeight()
        if not H or H <= 0 then return end
        local corner = (self.cbBarHeight or 32) / 2

        -- Visible banding from 8-bit color comes from too few color
        -- steps spread across too many pixels. To make bands
        -- effectively invisible we PACK a wide brightness range into
        -- the transition zone -- many 8-bit color values per pixel
        -- means each band is only a couple pixels tall. Smoothstep
        -- on top so the slope varies and bands can't space evenly.
        local DARK_FRAC = 0.90  -- top 90% pure dark base; transition concentrated in bottom 10%
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
            return lerp(0.022, 0.20, t),  -- r
                   lerp(0.022, 0.20, t),  -- g
                   lerp(0.030, 0.22, t)   -- b
        end

        -- Relaxed pixel snapping lets the GPU sub-pixel-blend the
        -- vertex colors instead of hard-aligning each color stop to
        -- the nearest pixel row, which softens the transitions.
        for _, cell in pairs(fill) do
            if cell.SetSnapToPixelGrid then cell:SetSnapToPixelGrid(false) end
            if cell.SetTexelSnappingBias then cell:SetTexelSnappingBias(0) end
        end

        local function ramp(cell, yTop, yBot)
            if not cell then return end
            local r1, g1, b1 = colorAtY(yTop)
            local r2, g2, b2 = colorAtY(yBot)
            -- VERTICAL gradient: first color = bottom, second = top.
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

    -- Crisp X built from two rotated 1px lines so it stays sharp at
    -- any UI scale (no font hinting, no texture filtering blur).
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
    -- Leave room for the inset banner: BANNER_INSET (6) + BANNER_H (38)
    -- + a small gap (4) so page content doesn't kiss the banner top.
    pageHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 6 + BANNER_H + 4)

    pages = {
        BuildPage1(pageHost),
        BuildPage2(pageHost),
        BuildPage3(pageHost),
        BuildPage4(pageHost),
    }

    -- Footer banner: a self-contained rounded panel floating inside
    -- the main window with the same corner radius as the wizard
    -- frame, inset a few pixels on every edge so it reads as its own
    -- element. Slightly darker than the gradient base but not pitch
    -- black -- enough contrast to anchor the back/continue cluster.
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

    -- Page indicator dots: vertically centered in the banner, anchored
    -- to the LEFT so they stay flush left.
    local DOT_GAP = 14
    local DOT_SZ  = 9
    local DOT_ACTIVE = 11
    -- Dots and buttons live INSIDE the banner so they render above
    -- the banner's rounded fill instead of being hidden behind it.
    for i = 1, #pages do
        local d = footer:CreateTexture(nil, "OVERLAY")
        d:SetSize(DOT_SZ, DOT_SZ)
        d:SetTexture(DOT_FILLED)
        d:SetPoint("LEFT", footer, "LEFT", 14 + DOT_ACTIVE / 2 + (i - 1) * (DOT_SZ + DOT_GAP), 0)
        dots[i] = d
    end

    -- Right cluster: [Back] [Continue]. Continue is the only action
    -- button (rounded fill, white text); Back stays as a quiet ghost
    -- link. To skip, the user clicks the X in the top-right.
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
            self:SetPropagateKeyboardInput(true)
            return
        end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            FinishWizard(false)
        else
            self:SetPropagateKeyboardInput(true)
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
