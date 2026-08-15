local _, ns = ...

local Results = ns.Results
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent

-- The apps menu: a 3x3 dot grid beside the filter button that drops a list of
-- apps, exactly as the filter button drops its filters.
local AppsMenu = {}
ns.AppsMenu = AppsMenu

local ROW_H = 24
local PAD = 6
local ICON = 16

-- The launcher list. Today only the calculator ships inside EasyFind; app
-- entries join this list as they release.
function ns.BuildApplicationEntries()
    local apps = {}
    local calculator = ns.Calculator and ns.Calculator._calculator
    if calculator and calculator.LAUNCHER then
        apps[#apps + 1] = calculator.LAUNCHER
    end
    return apps
end

-- The waffle: 3x3 round dots, drawn rather than shipped so it tints with the
-- theme like the rest of the bar chrome. A white square gets a circular alpha
-- mask -- SetColorTexture alone draws hard squares, which is not a dot grid.
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function CreateGridGlyph(parent, size)
    local glyph = CreateFrame("Frame", nil, parent)
    glyph:SetSize(size, size)
    local cell = size / 3
    local dot = cell * 0.72
    glyph.dots = {}
    for row = 0, 2 do
        for col = 0, 2 do
            local tex = glyph:CreateTexture(nil, "OVERLAY")
            tex:SetColorTexture(1, 1, 1, 1)
            tex:SetSize(dot, dot)
            tex:SetPoint("CENTER", glyph, "TOPLEFT", (col + 0.5) * cell, -(row + 0.5) * cell)
            local mask = glyph:CreateMaskTexture()
            mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(tex)
            tex:AddMaskTexture(mask)
            glyph.dots[#glyph.dots + 1] = tex
        end
    end
    return glyph
end

function AppsMenu:SetGlyphColor(r, g, b, a)
    local glyph = self.button and self.button.glyph
    if not glyph then return end
    for i = 1, #glyph.dots do
        glyph.dots[i]:SetVertexColor(r, g, b, a or 1)
    end
end

local function BuildRows(dropdown)
    local apps = ns.BuildApplicationEntries and ns.BuildApplicationEntries() or {}
    dropdown.rows = dropdown.rows or {}

    for i = 1, #apps do
        local app = apps[i]
        local row = dropdown.rows[i]
        if not row then
            row = CreateFrame("Button", nil, dropdown)
            row:SetHeight(ROW_H)
            row:SetPoint("LEFT", dropdown, "LEFT", PAD, 0)
            row:SetPoint("RIGHT", dropdown, "RIGHT", -PAD, 0)

            -- Same rounded hover pill as every other menu row; the shared
            -- installer owns the highlight texture and wash behavior.
            Utils.InstallMenuRowHighlight(row)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(ICON, ICON)
            row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.label:SetJustifyH("LEFT")

            row:SetScript("OnClick", function(self)
                if not self.app then return end
                dropdown:Hide()
                Results:HideResults()
                ns.ResultHandlers:SelectResult(self.app)
            end)
            dropdown.rows[i] = row
        end

        row.app = app
        row:SetPoint("TOPLEFT", dropdown, "TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)

        local iconDef = ns.ResultIcons and ns.ResultIcons:GetFlatCategoryIcon(app)
        local tex = (iconDef and iconDef.tex) or app.icon
        if tex then
            row.icon:SetTexture(tex)
            row.icon:SetTexCoord(unpack(iconDef and iconDef.coords or { 0, 1, 0, 1 }))
            -- All app icons follow the theme's chrome-glyph color (same source as
            -- the filter arrow and the 3x3 dots), desaturated first so every icon
            -- tints uniformly and stays readable on light themes.
            local gc = ns.ChromeGlyphColor()
            row.icon:SetDesaturated(true)
            row.icon:SetVertexColor(gc[1], gc[2], gc[3], 1)
            row.icon:Show()
        else
            row.icon:Hide()
        end
        row.label:SetText(app.name or "")
        -- Same font as result-row titles (pathFont), like every menu.
        local theme = Results.GetActiveTheme and Results:GetActiveTheme()
        Results:SetScaledFont(row.label, (theme and theme.pathFont) or ns.LEAF_FONT)
        row:Show()
    end

    for i = #apps + 1, #dropdown.rows do
        dropdown.rows[i]:Hide()
    end

    -- Wash mode and tint follow the active theme; re-run per build so rows
    -- created this open (or a theme swapped since last open) paint right.
    Utils.RefreshMenuRowHighlights(dropdown, dropdown.rows)

    -- Fit the widest label rather than a fixed width, so short names don't
    -- leave a slab of empty space on the right. icon + gap + text + edge
    -- padding, clamped to a sane range.
    local widest = 0
    for i = 1, #apps do
        local w = dropdown.rows[i].label:GetStringWidth() or 0
        if w > widest then widest = w end
    end
    local menuW = ICON + 8 + widest + PAD * 2 + 6
    if menuW < 90 then menuW = 90 end
    if menuW > 200 then menuW = 200 end

    dropdown:SetSize(menuW, PAD * 2 + #apps * ROW_H)
    return #apps
end

function AppsMenu:Create(searchFrame, filterBtn)
    if self.button then return self.button end

    -- No apps available this session (calculator companion disabled, nothing
    -- else installed): no button, and the editbox keeps its full width. Addon
    -- enable state cannot change without a reload, so one check at creation
    -- covers the session.
    local apps = ns.BuildApplicationEntries and ns.BuildApplicationEntries() or {}
    if #apps == 0 then return nil end

    local btn = CreateFrame("Button", "EasyFindUIAppsButton", searchFrame)
    btn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    btn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    -- Immediately left of the filter button, so the bar's right-hand controls
    -- read as one cluster. A slightly narrower button pulls the whole control
    -- (glyph AND its hover glow together) closer to the filter button, instead
    -- of nudging just the glyph, which left the glow offset.
    btn:SetPoint("RIGHT", filterBtn, "LEFT", 0, 0)
    btn:SetWidth(searchFrame:GetHeight() - 6)
    btn:SetFrameLevel(searchFrame:GetFrameLevel() + 50)

    local glyph = CreateGridGlyph(btn, 16)
    glyph:SetPoint("CENTER")
    btn.glyph = glyph
    btn:SetHighlightTexture(130757)

    -- The editBox's right edge is anchored to the filter button, so it lies over
    -- this button's whole footprint. An EditBox is mouse-enabled for typing, so
    -- it eats every click meant for the button and the menu never opens. Pull
    -- the text field in to stop at the apps button's left edge instead.
    if searchFrame.editBox then
        searchFrame.editBox:SetPoint("RIGHT", btn, "LEFT", -4, 0)
    end

    -- Same strata/level as the filter dropdown, its proven sibling.
    local dropdown = CreateFrame("Frame", "EasyFindUIAppsDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("DIALOG")
    -- Children need level headroom (rows +1, hover pill between); at 9999
    -- they clamp against the 10000 ceiling.
    dropdown:SetFrameLevel(9000)
    dropdown:EnableMouse(true)
    dropdown:Hide()
    ns.StyleMenuPanel(dropdown)

    -- Same outside-click close the filter dropdown uses: a menu that will not
    -- go away when you click past it is worse than no menu.
    dropdown:SetScript("OnUpdate", function(self)
        local inside = Utils.IsFrameVisiblyMouseOver(self) or Utils.IsFrameVisiblyMouseOver(btn)
        if not inside and not self._mouseWasInside
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            self:Hide()
        end
        self._mouseWasInside = inside
    end)

    btn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
            return
        end
        -- Rebuilt per open: an app that became available must appear without
        -- a reload.
        if BuildRows(dropdown) == 0 then return end

        -- Anchor maths lifted from the filter dropdown, including opening
        -- upward when results grow upward.
        local barScale = EasyFind.db.uiSearchScale or 1.0
        dropdown:SetScale(barScale)
        local scale = searchFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
        local left = btn:GetLeft() * scale
        dropdown:ClearAllPoints()
        if EasyFind.db.uiResultsAbove then
            dropdown:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, searchFrame:GetTop() * scale)
        else
            dropdown:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, searchFrame:GetBottom() * scale)
        end
        dropdown:Show()
    end)

    -- The apps button stays engaged (its highlight locked) while its menu is
    -- open, like every other menu-owner button.
    dropdown:HookScript("OnShow", function() btn:LockHighlight() end)
    dropdown:HookScript("OnHide", function() btn:UnlockHighlight() end)

    -- Hover-reveal when "Show app button" is off: clickable at alpha 0 until
    -- its spot is hovered, focused, or this menu is open.
    Utils.InstallBarControlReveal(btn,
        function() return EasyFind.db.showAppsButton ~= false end,
        function() return dropdown:IsShown() end)
    dropdown:HookScript("OnShow", btn.RefreshReveal)
    dropdown:HookScript("OnHide", btn.RefreshReveal)

    self.button = btn
    self.dropdown = dropdown
    searchFrame.appsBtn = btn
    searchFrame.appsDropdown = dropdown

    -- Filter menu and apps menu are peers: opening one closes the other rather
    -- than stacking two panels over the same bar.
    if Results.CloseFilterDropdownIfOpen then
        btn:HookScript("OnClick", function()
            if dropdown:IsShown() then Results:CloseFilterDropdownIfOpen() end
        end)
    end
    return btn
end
