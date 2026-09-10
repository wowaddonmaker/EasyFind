local _, ns = ...
local L = ns.L

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

-- The launcher list. App entries join this list as they release.
function ns.BuildApplicationEntries()
    local apps = {}
    local calculator = ns.Calculator and ns.Calculator._calculator
    if calculator and calculator.LAUNCHER then
        apps[#apps + 1] = calculator.LAUNCHER
    end
    -- Icon Search (GitHub #22): opens the @icons grid, same entry point as
    -- the searchable launcher row. iconSearchLauncher picks its own glyph in
    -- GetFlatCategoryIcon; without it, nativeRun lands on the command icon.
    -- Hidden when its LoadOnDemand companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Icons")) then
        apps[#apps + 1] = {
            name = ns.L["ICON_SEARCH_APP"],
            iconSearchLauncher = true,
            noPin = true,
            nativeRun = function()
                if ns.RequestIconSearch and ns.RequestIconSearch() then
                    ns.Results:OpenIconSearch()
                end
            end,
        }
    end
    -- Snippets opens the options panel landed on its tab: the tab is the
    -- one management surface (list, search, create, edit), and the menu is
    -- its discoverable front door. category "Snippet" gives the row its
    -- glyph; nativeRun runs BEFORE the snippet-category branch in
    -- SelectResult, so this opens the list, not the per-snippet editor.
    -- The panel is a LoadOnDemand companion: request it before touching
    -- ns.Options (the options tutorial button shipped broken for skipping
    -- exactly this).
    -- Hidden when the snippets companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Snippets")) then
        apps[#apps + 1] = {
            name = L["FILTER_SNIPPETS"],
            category = "Snippet",
            snippetsLauncher = true,
            noPin = true,
            nativeRun = function()
                if ns.RequestOptionsPanel and ns.RequestOptionsPanel()
                   and ns.Options and ns.Options.OpenAtSnippets then
                    ns.Options:OpenAtSnippets()
                end
            end,
        }
    end
    -- Clipboard history opens its own list (@clipboard). Hidden when the
    -- clipboard companion is disabled in the AddOns list.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clipboard")) then
        apps[#apps + 1] = {
            name = L["FILTER_CLIPBOARD"],
            clipboardLauncher = true,
            noPin = true,
            icon = ns.CLIPBOARD_ICON_TEX,
            nativeRun = function()
                if ns.Clipboard and ns.Clipboard.OpenList then ns.Clipboard:OpenList() end
            end,
        }
    end
    return apps
end

-- Stable ids for the extension buttons (Search/ExtensionButtons.lua): an
-- app is known by its launcher flag, never by its localized name.
local APP_ID_FLAGS = {
    { "calculator", "calculatorLauncher" },
    { "icons", "iconSearchLauncher" },
    { "snippets", "snippetsLauncher" },
    { "clipboard", "clipboardLauncher" },
}
function ns.ApplicationEntryID(app)
    if not app then return nil end
    for i = 1, #APP_ID_FLAGS do
        if app[APP_ID_FLAGS[i][2]] then return APP_ID_FLAGS[i][1] end
    end
    return nil
end
-- The live launcher entry for an id, or for a stored copy of one (a
-- shortkey snapshot keeps the flag but not the run function).
function ns.FindApplicationEntry(idOrData)
    if not idOrData then return nil end
    local id = type(idOrData) == "table" and ns.ApplicationEntryID(idOrData) or idOrData
    if not id then return nil end
    local apps = ns.BuildApplicationEntries()
    for i = 1, #apps do
        if ns.ApplicationEntryID(apps[i]) == id then return apps[i] end
    end
    return nil
end

-- Whether an extension's own surface is up right now, and how to take it
-- down: the calculator popup, the icon grid or the clipboard list in the
-- results (the pill comes off and the results close, leaving the bar),
-- the options panel on the snippets page. Every launch surface (menu row,
-- extension button, compartment) toggles through these, so a second
-- click closes what the first opened.
function ns.IsApplicationOpen(app)
    if not app then return false end
    if app.calculatorLauncher then
        local calc = ns.Calculator and ns.Calculator._calculator
        local frame = calc and calc.popupFrame
        return frame ~= nil and frame:IsShown()
    end
    local Filters = ns.Filters
    local qf = Filters and Filters.GetQuickFilter and Filters:GetQuickFilter()
    local resultsShown = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
        and ns.Search:GetResultsFrame():IsShown()
    if app.iconSearchLauncher then
        return resultsShown and qf ~= nil and qf.key == "icons"
    end
    if app.clipboardLauncher then
        return resultsShown and qf ~= nil and qf.key == "clipboard"
    end
    if app.snippetsLauncher then
        local frame = ns.optionsFrame
        return frame ~= nil and frame:IsShown() and ns.Options and ns.Options.CurrentExtensionPage
            and ns.Options:CurrentExtensionPage() == "snippets"
    end
    return false
end

function ns.CloseApplication(app)
    if not app then return end
    if app.calculatorLauncher then
        local calc = ns.Calculator and ns.Calculator._calculator
        if calc and calc.popupFrame then calc.popupFrame:Hide() end
        return
    end
    if app.iconSearchLauncher or app.clipboardLauncher then
        if ns.Filters and ns.Filters.ClearQuickFilter then ns.Filters:ClearQuickFilter(false) end
        if Results and Results.HideResults then Results:HideResults() end
        return
    end
    if app.snippetsLauncher and ns.Options and ns.Options.Hide then
        ns.Options:Hide()
    end
end

-- The results-based extension showing right now ("icons", "clipboard"),
-- or nil. The outside-click closers ask before they hide.
function ns.CurrentApplicationSurfaceID()
    local Filters = ns.Filters
    local qf = Filters and Filters.GetQuickFilter and Filters:GetQuickFilter()
    local key = qf and qf.key
    if key ~= "icons" and key ~= "clipboard" then return nil end
    local rf = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
    if not (rf and rf:IsShown()) then return nil end
    return key
end

-- An outside mouse-down takes the icon grid or the clipboard list down a
-- beat before the click on a launch surface (extension button, broker
-- launcher, compartment row) lands, so the toggle would find it closed
-- and reopen what the user meant to close. The closers note what they
-- took down; launching that same extension within the gesture is the
-- close, and does nothing more.
local DISMISS_GRACE = 0.6
local dismissedID, dismissedAt
function ns.NoteApplicationDismissed(id)
    if not id then return end
    dismissedID, dismissedAt = id, GetTime()
end
local function JustDismissed(app)
    if not dismissedID then return false end
    if GetTime() - (dismissedAt or 0) > DISMISS_GRACE then
        dismissedID = nil
        return false
    end
    return ns.ApplicationEntryID(app) == dismissedID
end

-- Whether the bar was hidden when a launch opened it. Closing that
-- extension from a launch surface then takes the bar down too, so the
-- press that opened everything closes everything; opened while the bar
-- was already up, the close leaves the bar where it was.
local launchOpenedBar = {}
-- Visible to the user, not merely Shown: Hover Show keeps the frame
-- shown at alpha 0 while faded out, and a faded-out bar is a hidden
-- bar for this rule.
local function BarShown()
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if not (sf and sf:IsShown()) then return false end
    local db = EasyFind and EasyFind.db
    if db and db.smartShow and not db.autoHide and sf.smartShowVisible then
        return sf.smartShowVisible() and true or false
    end
    return (sf:GetAlpha() or 1) > 0.01
end
local function HideBarIfLaunchOpened(app)
    local id = ns.ApplicationEntryID(app)
    if not (id and launchOpenedBar[id]) then return end
    launchOpenedBar[id] = nil
    if BarShown() and ns.Search.Hide then ns.Search:Hide() end
end

function ns.ToggleApplication(app)
    if not app then return end
    if JustDismissed(app) then
        dismissedID = nil
        HideBarIfLaunchOpened(app)
        return
    end
    if ns.IsApplicationOpen(app) then
        ns.CloseApplication(app)
        HideBarIfLaunchOpened(app)
        return
    end
    local id = ns.ApplicationEntryID(app)
    if id then launchOpenedBar[id] = not BarShown() end
    Results:HideResults()
    ns.ResultHandlers:SelectResult(app)
end

-- Extension settings pages. The options panel's Extensions tab shows one
-- page per registered extension, picked from a strip at the top. Bundled
-- extensions register their pages from the options companion; others
-- register here: { id, name, icon, coords, companion, build = function(page) }.
-- `build` fills `page` (a frame filling the tab under the strip) once.
ns.ExtensionPages = ns.ExtensionPages or {}
function ns.RegisterExtensionPage(def)
    if not (def and def.id and def.build) then return end
    local pages = ns.ExtensionPages
    for i = 1, #pages do
        if pages[i].id == def.id then pages[i] = def; return end
    end
    pages[#pages + 1] = def
    if ns.Options and ns.Options.RefreshExtensionPages then ns.Options:RefreshExtensionPages() end
end

-- The searchable launcher row: typing "icons" / "icon search" (or the
-- localized app name) offers a row that opens the icon grid. CORE-owned:
-- it is an entry point to the LoadOnDemand companion, so it must exist
-- before the companion has ever loaded (and hide when the companion is
-- disabled outright).
local iconLauncherRow
function ns.Results:GetIconSearchLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Icons") then
        return nil
    end
    local q = text:lower()
    local target = (ns.L["ICON_SEARCH_APP"] or ""):lower()
    local sfind = ns.Utils.sfind
    if not (sfind(target, q, 1, true)
            or sfind("icon search", q, 1, true)
            or sfind("icons", q, 1, true)) then
        return nil
    end
    iconLauncherRow = iconLauncherRow or {
        name = ns.L["ICON_SEARCH_APP"],
        iconSearchLauncher = true,
        noPin = true,
        -- Injected at match time, never in uiSearchData: a learned key for
        -- it can never resolve, so the record would only be dead weight.
        noLearn = true,
        nativeRun = function()
            if ns.RequestIconSearch and ns.RequestIconSearch() then
                ns.Results:OpenIconSearch()
            end
        end,
    }
    return iconLauncherRow
end

-- The waffle: 3x3 round dots, drawn rather than shipped so it tints with the
-- theme like the rest of the bar chrome. A white square gets a circular alpha
-- mask -- SetColorTexture alone draws hard squares, which is not a dot grid.
-- The clipboard history launcher row: typing "clipboard" / "clip" /
-- "history" (or the localized app name) offers the row that opens the
-- @clipboard list. Core-owned like the icon launcher: the entries
-- themselves never appear in a search, only this door to them.
local clipboardLauncherRow
function ns.Results:GetClipboardLauncherMatch(text)
    if not text or #text < 3 then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clipboard") then return nil end
    local q = ns.Utils.slower(text)
    local target = ns.Utils.slower(ns.L["FILTER_CLIPBOARD"] or "clipboard")
    local sfind = ns.Utils.sfind
    if not (sfind(target, q, 1, true)
            or sfind("clipboard", q, 1, true)
            or sfind("clipboard history", q, 1, true)
            or sfind("history", q, 1, true)) then
        return nil
    end
    clipboardLauncherRow = clipboardLauncherRow or {
        name = ns.L["FILTER_CLIPBOARD"],
        clipboardLauncher = true,
        noPin = true,
        noLearn = true,
        icon = ns.CLIPBOARD_ICON_TEX,
        nativeRun = function()
            if ns.Clipboard and ns.Clipboard.OpenList then ns.Clipboard:OpenList() end
        end,
    }
    return clipboardLauncherRow
end

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
-- The tutorial's Apps tile draws the same waffle so the tile and the live
-- bar button read as one thing; exported so that replica cannot drift.
ns.CreateGridGlyph = CreateGridGlyph

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
                ns.ToggleApplication(self.app)
            end)
            -- Dragging a row out makes a button for that extension on
            -- screen (Search/ExtensionButtons.lua); the menu gets out of
            -- the way and a ghost rides the cursor until the drop.
            -- Press-and-move, not the frame drag events (those depend on
            -- the row keeping the mouse, which a menu row does not always
            -- get): a press followed by movement past a few pixels while
            -- the button is still held starts the drag.
            row:HookScript("OnMouseDown", function(self, button)
                if button ~= "LeftButton" or not (self.app and ns.ExtensionButtons) then return end
                local sx, sy = GetCursorPosition()
                self._efPress = { x = sx, y = sy }
                self:SetScript("OnUpdate", function(row2)
                    local press = row2._efPress
                    if not press then row2:SetScript("OnUpdate", nil); return end
                    if not IsMouseButtonDown("LeftButton") then
                        row2._efPress = nil
                        row2:SetScript("OnUpdate", nil)
                        return
                    end
                    local cx, cy = GetCursorPosition()
                    if (cx - press.x) ^ 2 + (cy - press.y) ^ 2 < 36 then return end
                    row2._efPress = nil
                    row2:SetScript("OnUpdate", nil)
                    dropdown:Hide()
                    ns.ExtensionButtons:BeginDragFromMenu(row2.app)
                end)
            end)
            dropdown.rows[i] = row
        end

        row.app = app
        row:SetPoint("TOPLEFT", dropdown, "TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)

        -- The app's own glyph, not GetFlatCategoryIcon: launcher data resolves
        -- to the apps waffle there (result rows), which says nothing in a menu
        -- where every row is an app.
        local iconDef = ns.ResultIcons and (ns.ResultIcons:GetAppGlyphIcon(app)
            or ns.ResultIcons:GetFlatCategoryIcon(app))
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
    -- of nudging just the glyph, which left the glow offset. The +4 tucks it
    -- into the filter button's inner glow margin: with the old gold ring gone
    -- the visible gap between the two glyphs read too wide.
    btn:SetPoint("RIGHT", filterBtn, "LEFT", 4, 0)
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

    -- Outside-click close, EVENT-driven like AttachOutsideClickClose: the
    -- event registers only while the menu is shown and fires only on actual
    -- clicks, so an open menu costs nothing per frame. (This replaced an
    -- every-frame OnUpdate poll that showed up as constant CPU whenever the
    -- menu was open.) GLOBAL_MOUSE_DOWN dispatches before click handlers
    -- run, so a click on a row still reads as inside.
    dropdown:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    dropdown:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    dropdown:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not (Utils.IsFrameVisiblyMouseOver(self) or Utils.IsFrameVisiblyMouseOver(btn)) then
            self:Hide()
        end
    end)

    -- Keyboard nav, armed only when the menu is OPENED from the keyboard
    -- (Tab to the apps button, Enter): same row-focus pattern as the filter
    -- popups. ESC/LEFT close just this menu and hand the keys back to the
    -- toolbar ring, so the apps button stays focused for the next press.
    -- Capturing keys here is also half the peer-exclusion fix: Tab cycles
    -- rows instead of walking on to the filter button while this is open.
    local appsFocus = 0
    local function SetAppsFocus(idx)
        local rows = dropdown.rows or {}
        local prev = rows[appsFocus]
        if prev and prev.SetMenuHighlightFocused then prev:SetMenuHighlightFocused(false) end
        appsFocus = idx
        local target = rows[idx]
        if target and target.SetMenuHighlightFocused then target:SetMenuHighlightFocused(true) end
    end
    local function VisibleAppRows()
        local rows = dropdown.rows or {}
        local n = 0
        for i = 1, #rows do
            if rows[i]:IsShown() then n = n + 1 end
        end
        return n
    end
    Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
    Utils.SafeCallMethod(dropdown, "SetPropagateKeyboardInput", false)
    dropdown:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        local count = VisibleAppRows()
        if (key == "DOWN" or key == "TAB") and count > 0 then
            SetAppsFocus(appsFocus % count + 1)
        elseif key == "UP" and count > 0 then
            SetAppsFocus((appsFocus - 2) % count + 1)
        elseif key == "ENTER" then
            local row = dropdown.rows and dropdown.rows[appsFocus]
            if row then row:Click() end
        elseif key == "ESCAPE" or key == "LEFT" then
            self:Hide()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    dropdown:HookScript("OnHide", function(self)
        SetAppsFocus(0)
        Utils.SafeCallMethod(self, "EnableKeyboard", false)
        local nav = ns.Search and ns.Search.GetNavFrame and ns.Search:GetNavFrame()
        if nav and btn.keyboardFocused then
            Utils.SafeCallMethod(nav, "EnableKeyboard", true)
        end
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
        -- Opened from the toolbar ring (Tab + Enter): move keys from the
        -- nav frame into the menu and focus the first app.
        if btn.keyboardFocused then
            local nav = ns.Search and ns.Search.GetNavFrame and ns.Search:GetNavFrame()
            if nav then Utils.SafeCallMethod(nav, "EnableKeyboard", false) end
            Utils.SafeCallMethod(dropdown, "EnableKeyboard", true)
            SetAppsFocus(1)
        end
    end)

    -- The apps button stays engaged (its highlight locked) while its menu is
    -- open, like every other menu-owner button.
    dropdown:HookScript("OnShow", function() btn:LockHighlight() end)
    dropdown:HookScript("OnHide", function()
        -- The locked highlight doubles as the toolbar-ring focus visual.
        -- After a keyboard close (ESC back to the button) the ring still
        -- owns this button, so the light must stay on; unlocking here was
        -- why focus survived "under the hood" but showed nothing.
        if not btn.keyboardFocused then btn:UnlockHighlight() end
    end)

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
