local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Filters = ns.Filters
local Calculator = ns.Calculator
local SearchHistory = ns.SearchHistory
local OptionsSurface = ns.OptionsSurface
local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Rows = ns.ResultRows
local Shortcuts = ns.ResultShortcuts
local L = ns.L

local Utils = ns.Utils
local slower = Utils.slower
local mmin, mmax = Utils.mmin, Utils.mmax

local GOLD_COLOR = ns.GOLD_COLOR
local SEARCH_ICON_TEXTURE = ns.SEARCH_ICON_TEX

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local IsMouseButtonDown  = IsMouseButtonDown
local IsAltKeyDown       = IsAltKeyDown
local IsControlKeyDown   = IsControlKeyDown
local InCombatLockdown   = InCombatLockdown

function Search:GetDefaultSearchBarPoint()
    local parentH = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 768
    return "CENTER", "CENTER", 0, parentH / 6
end

-- The search bar height tracks the font size (so the default font lands at the
-- default bar height); it is not independently resizable.
local DEFAULT_FONT_SIZE = ns.DEFAULT_FONT_SIZE
function Search:GetSearchBarHeight()
    local fontSize = (EasyFind and EasyFind.db and EasyFind.db.fontSize) or DEFAULT_FONT_SIZE
    return mmax(24, mmin(56, ns.SEARCHBAR_HEIGHT * fontSize / DEFAULT_FONT_SIZE))
end

local searchFrame
local resultsFrame
local selectedIndex = 0   -- 0 = none selected, 1..N = highlighted row
local toggleFocused = false -- true = Tab moved focus to expand/collapse toggle
local navFrame             -- Keyboard capture frame for results navigation
local activeKeybindBtn
-- Combined-frame backdrop: rounded-rect 9-slice that wraps the bar
-- alone (collapsed to a pill when results are hidden) or the bar
-- plus the results dropdown (rounded rectangle when open). Sibling
-- of searchFrame, anchored to it; grows downward to cover
-- resultsFrame when ShowHierarchicalResults runs.
local containerFrame
local resultButtons = {}
local MAX_BUTTON_POOL = 100
local petFavoriteOverrides = {}
local inCombat = false
local selectingResult = false  -- guard: suppress OnTextChanged re-renders during SelectResult
function Search:GetSearchFrame()
    return searchFrame
end

function Search:GetResultsFrame()
    return resultsFrame
end

function Search:SetResultsFrame(frame)
    resultsFrame = frame
end

function Search:GetNavFrame()
    return navFrame
end

function Search:GetResultButtons()
    return resultButtons
end

function Search:GetSelectedIndex()
    return selectedIndex
end

function Search:SetSelectedIndex(index)
    selectedIndex = index or 0
end

function Search:SetToggleFocused(focused)
    toggleFocused = focused and true or false
end

function Search:GetToggleFocused()
    return toggleFocused
end

function Search:GetContainerFrame()
    return containerFrame
end

function Search:SetSelectingResult(selecting)
    selectingResult = selecting and true or false
end

function Search:IsSelectingResult()
    return selectingResult
end

function Search:GetPetFavoriteOverrides()
    return petFavoriteOverrides
end

function Search:GetActiveKeybindButton()
    return activeKeybindBtn
end

function Search:SetActiveKeybindButton(button)
    activeKeybindBtn = button
end

function Search:StopActiveKeybindCapture()
    local button = activeKeybindBtn
    if button and button._stopCapture then
        button._stopCapture(button)
    end
end

function Search:Initialize()
    self:CreateUnearnedTooltip()
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    -- ESC-override predicate inputs: results visibility changes re-arm.
    if resultsFrame then
        resultsFrame:HookScript("OnShow", Utils.RefreshEscArm)
        resultsFrame:HookScript("OnHide", Utils.RefreshEscArm)
    end
    self:RegisterCombatEvents()
    self:HookBlizzardFilterChanges()

    if EasyFind.db.autoHide then
        searchFrame:Hide()
    elseif EasyFind.db.visible ~= false then
        searchFrame:Show()
        if EasyFind.db.smartShow then
            searchFrame.hoverZone:Show()
            searchFrame:SetAlpha(0)
            searchFrame.setSmartShowVisible(false)
        end
    else
        searchFrame:Hide()
        if EasyFind.db.smartShow then
            searchFrame.hoverZone:Show()
        end
    end

    inCombat = InCombatLockdown()
    if inCombat and not (ns.GetVisibilityMode() == ns.VISIBILITY_ALWAYS
            and EasyFind.db.combatHide == false) then
        searchFrame:Hide()
    end

    self:UpdateScale()
    self:UpdateWidth()
    self:UpdateFontSize()
    -- Provider warm happens on FIRST FOCUS (see OnEditFocusGained), not
    -- here: this runs at login, and warming the whole searchable universe
    -- (bags, pets, mounts, toys, achievements, ...) at login held tens of
    -- MB resident for every character in every session, searched or not.
    -- The staggered chain lands within a few frames of focus, and any
    -- provider a beat behind the first keystroke loads on demand exactly
    -- as before.
    if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.EnsureFastGameOptions then
        ns.BlizzOptionsSearch:EnsureFastGameOptions()
    end

    -- Block auto-focus on creation - WoW may focus visible EditBoxes after creation.
    -- Block for two frames (enough for WoW's auto-focus to fire and get rejected).
    -- Always Show never expires the block: the bar is visible at reload and
    -- WoW's auto-focus can land after any fixed frame window on heavy loads.
    -- A silently focused box then eats the first unfocused-looking ESC (the
    -- original perma-show era bug). Every legitimate focus path clears
    -- blockFocus itself before SetFocus, so keeping the block costs nothing.
    searchFrame.editBox.blockFocus = true
    searchFrame.editBox:ClearFocus()
    Utils.SafeAfter(0, function()
        Utils.SafeAfter(0, function()
            if searchFrame and searchFrame.editBox
                and ns.GetVisibilityMode() ~= ns.VISIBILITY_ALWAYS then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:ClearFocus()
            end
        end)
    end)
    -- Loading-screen focus is sticky: ClearFocus during the load screen
    -- can silently no-op, so an auto-focus that lands mid-load survives
    -- with blockFocus still up and the focused box then eats the first
    -- ESC and ENTER of the session. Settle pass: after entering world,
    -- keep clearing any focus that arrived while blockFocus was up until
    -- it sticks (2s window, self-cancelling).
    local settleFrame = CreateFrame("Frame")
    settleFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    settleFrame:SetScript("OnEvent", function(self)
        local settleElapsed = 0
        Utils.SafeOnUpdate(self, function(_, elapsed)
            settleElapsed = settleElapsed + (elapsed or 0)
            local editBox = searchFrame and searchFrame.editBox
            if editBox and editBox.blockFocus and editBox:HasFocus() then
                editBox:ClearFocus()
            end
            -- Same settle treatment for the C-level capture flag: while
            -- unfocused it must read propagate=true no matter what load
            -- ordering left behind.
            if editBox and not editBox:HasFocus() then
                Utils.SafeCallMethod(editBox, "SetPropagateKeyboardInput", true)
            end
            if settleElapsed > 2 then
                self:SetScript("OnUpdate", nil)
            end
        end)
    end)

    -- First-run wizard for new installs (sleek central modal, no in-place
    -- overlay). Bar stays hidden until the user finishes the tutorial.
    if not EasyFind.db.tutorialDone then
        Utils.SafeAfter(0.3, function()
            if ns.Wizard and ns.Wizard.Show then ns.Wizard:Show() end
        end)
    end

end

-- Two-state strata: LOW while idle (HUD behind every window), DIALOG while
-- ACTIVE -- results open OR the editbox holding keyboard focus. Focus counts:
-- typing with no results yet (one letter, a query with no hits) must not
-- drop the bar behind other windows mid-keystroke. Driven by the results
-- frame's OnShow/OnHide hooks plus the editbox focus hooks; combat never
-- flips it because results visibility changes in combat are alpha-based,
-- not Show/Hide.
function Search:UpdateStackStrata()
    local editBox = searchFrame and searchFrame.editBox
    local active = (resultsFrame and resultsFrame:IsShown())
        or (editBox and editBox:HasFocus())
    local strata = active and "DIALOG" or "LOW"
    if searchFrame then
        searchFrame:SetFrameStrata(strata)
        if searchFrame.toolbarHighlight then
            searchFrame.toolbarHighlight:SetFrameStrata(strata)
        end
    end
    if containerFrame then containerFrame:SetFrameStrata(strata) end
    if resultsFrame then resultsFrame:SetFrameStrata(strata) end
end

function Search:WarmSearchHotPath()
    -- Warm only what a render can show at once; the pool grows on demand
    -- (EnsureResultButton) for the rare deep container browse. Building
    -- all 100 rows here was over a MB of frames nothing ever displayed.
    for i = 1, 20 do
        Results:EnsureResultButton(i):Hide()
    end
end

-- Kept-visible-in-combat state: the bar is a protected frame in combat
-- (secure result rows are its descendants, see Search:Hide), so the
-- mid-fight "toggle" is an alpha flip, never Show/Hide, and the mouse
-- shield makes the visible bar fully inert (only the toggle works).
local combatToggledOff = false
local isMovingNow = false
local BAR_DIM_ALPHA = 0.6

-- ONE owner for the Always Show bar's alpha: combat toggle beats combat
-- dim beats move dim beats full. Only applies in Always Show; the other
-- modes keep their own fade machinery.
local function ApplyAlwaysBarAlpha()
    if not searchFrame or not searchFrame:IsShown() then return end
    if ns.GetVisibilityMode() ~= ns.VISIBILITY_ALWAYS then return end
    local alpha = 1
    if inCombat then
        if combatToggledOff then
            alpha = 0
        elseif EasyFind.db.combatDim and EasyFind.db.combatHide == false then
            alpha = BAR_DIM_ALPHA
        end
    elseif EasyFind.db.moveDim and isMovingNow
        and not (searchFrame.editBox and searchFrame.editBox:HasFocus()) then
        alpha = BAR_DIM_ALPHA
    end
    searchFrame:SetAlpha(alpha)
end

function Search:UpdateMoveDim()
    ApplyAlwaysBarAlpha()
end

local function EnsureCombatShield()
    if searchFrame.combatShield then return searchFrame.combatShield end
    local shield = CreateFrame("Frame", nil, searchFrame)
    shield:SetAllPoints(searchFrame)
    shield:SetFrameLevel(searchFrame:GetFrameLevel() + 40)
    shield:EnableMouse(true)
    shield:Hide()
    searchFrame.combatShield = shield
    return shield
end

function Search:RegisterCombatEvents()
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    ns.eventFrame:RegisterEvent("PLAYER_STARTED_MOVING")
    ns.eventFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
    -- Move-dim undims while typing; focus changes re-resolve the alpha.
    searchFrame.editBox:HookScript("OnEditFocusGained", ApplyAlwaysBarAlpha)
    searchFrame.editBox:HookScript("OnEditFocusLost", ApplyAlwaysBarAlpha)
    searchFrame.editBox:HookScript("OnEditFocusGained", function() Search:UpdateStackStrata() end)
    searchFrame.editBox:HookScript("OnEditFocusLost", function() Search:UpdateStackStrata() end)
    ns.eventFrame:HookScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            inCombat = true
            combatToggledOff = false
            -- Always Show with combatHide off keeps the BAR up through
            -- combat. Results and focus still clear unconditionally: the
            -- result rows are secure buttons whose combat-boundary
            -- teardown (secure hide owners, binding clears) assumes it.
            if not (ns.GetVisibilityMode() == ns.VISIBILITY_ALWAYS
                    and EasyFind.db.combatHide == false) then
                searchFrame:Hide()
                searchFrame.hoverZone:Hide()
            else
                Search:CloseFilterDropdownIfOpen()
                EnsureCombatShield():Show()
                ApplyAlwaysBarAlpha()
            end
            Results:HideResults()
            searchFrame.editBox:ClearFocus()
        elseif event == "PLAYER_STARTED_MOVING" then
            isMovingNow = true
            ApplyAlwaysBarAlpha()
            return
        elseif event == "PLAYER_STOPPED_MOVING" then
            isMovingNow = false
            ApplyAlwaysBarAlpha()
            return
        elseif event == "PLAYER_REGEN_ENABLED" then
            inCombat = false
            combatToggledOff = false
            if searchFrame.combatShield then searchFrame.combatShield:Hide() end
            ApplyAlwaysBarAlpha()
            -- autoHide stays hidden after combat; reopens via bind.
            if not EasyFind.db.autoHide then
                if EasyFind.db.visible ~= false then
                    searchFrame:Show()
                    if EasyFind.db.smartShow then
                        searchFrame.hoverZone:Show()
                        searchFrame:SetAlpha(0)
                        searchFrame.setSmartShowVisible(false)
                    end
                elseif EasyFind.db.smartShow then
                    searchFrame.hoverZone:Show()
                end
            end
        end
    end)
end

function Search:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "EasyFindSearchFrame", UIParent, "BackdropTemplate")
    Search.searchFrame = searchFrame
    local barH = self:GetSearchBarHeight()
    searchFrame:SetSize(250, barH)
    -- FULLSCREEN_DIALOG keeps the search bar above the default Search's
    -- DIALOG-strata menus (Game Menu, Options panel, etc.) so opening
    -- the bar from inside any in-game menu still puts our results on
    -- top instead of getting buried.
    -- Idle bar is HUD, not a window: LOW, so every game window (map,
    -- character panel, bags = MEDIUM and up) covers it. While results are
    -- open the whole stack rises to DIALOG like a Blizzard dropdown menu
    -- (above action bars and windows, below tooltips); see
    -- Search:UpdateStackStrata. Menus that open from the bar (filter
    -- dropdown, calculator, inline dropdown) are DIALOG statically.
    searchFrame:SetFrameStrata("LOW")
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetClampedToScreen(true)

    if EasyFind.db.uiSearchPosition then
        local pos = EasyFind.db.uiSearchPosition
        searchFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        local point, relPoint, x, y = self:GetDefaultSearchBarPoint()
        searchFrame:SetPoint(point, UIParent, relPoint, x, y)
    end

    local theme = Results:GetActiveTheme()
    ns.CreateSearchBorder(searchFrame)

    -- Combined visual frame: 9-slice rounded rect that morphs from a
    -- pill (results closed: height == bar height) to a rounded
    -- rectangle (results open: height == bar height + results panel
    -- height). Sibling of searchFrame at the same frame level - 1 so
    -- its draw layers sit behind the bar's content; anchored to
    -- searchFrame so it follows movement / resizing.
    containerFrame = CreateFrame("Frame", "EasyFindContainerFrame", UIParent)
    Search.containerFrame = containerFrame
    containerFrame:SetFrameStrata("LOW")
    containerFrame:SetFrameLevel(math.max(0, searchFrame:GetFrameLevel() - 1))
    containerFrame:SetPoint("TOPLEFT",  searchFrame, "TOPLEFT",  0, 0)
    containerFrame:SetPoint("TOPRIGHT", searchFrame, "TOPRIGHT", 0, 0)
    containerFrame:SetPoint("BOTTOM",   searchFrame, "BOTTOM",   0, 0)
    ns.CreateRoundedRectBorder(containerFrame)
    ns.CreateRoundedRectDivider(containerFrame)
    ns.SetRoundedRectBarHeight(containerFrame, searchFrame:GetHeight())
    self:ApplySearchWindowFill(containerFrame)

    -- Sibling-of-searchFrame so the container's textures sit BEHIND
    -- the bar's content (children would render in front). The trade-
    -- off is that searchFrame:Hide / :Show no longer cascades, so
    -- mirror visibility by hand. Same for alpha so SmartShow fades
    -- match.
    searchFrame:HookScript("OnShow", function() containerFrame:Show() end)
    searchFrame:HookScript("OnHide", function() containerFrame:Hide() end)
    hooksecurefunc(searchFrame, "SetAlpha", function(_, a)
        containerFrame:SetAlpha(a or 1)
    end)
    if not searchFrame:IsShown() then containerFrame:Hide() end

    searchFrame:SetBackdrop(nil)
    -- Pill on searchFrame is hidden; the container provides the
    -- visual now. Pill setup is still kept (CreateSearchBorder
    -- above) so anything that pokes searchFrame.searchBorder
    -- doesn't crash, but the textures stay invisible.
    ns.SetSearchBorderShown(searchFrame, false)
    -- Fill on, then ring per the user's border setting. BorderShown shows
    -- fill AND ring, so the ring re-apply MUST come after it: this pair
    -- being ordered the other way around (ring first, panel-on later)
    -- silently re-showed the border for borderless users on every reload
    -- until any options resync ran.
    ns.SetRoundedRectBorderShown(containerFrame, true)
    ns.SetRoundedRectRingShown(containerFrame, EasyFind.db.windowBorder ~= false)
    ns.SetRoundedRectBorderBgAlpha(containerFrame, ns.GetSearchWindowAlpha())

    -- Static magnifying-glass icon (non-interactive, flush left)
    local contentSz = barH * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE

    local iconHolder = CreateFrame("Frame", nil, searchFrame)
    iconHolder:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    iconHolder:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    iconHolder:SetPoint("LEFT", searchFrame, "LEFT", 0, 0)
    iconHolder:SetWidth(searchFrame:GetHeight())
    iconHolder:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    local searchIcon = iconHolder:CreateTexture(nil, "OVERLAY")
    searchIcon:SetSize(iconSz, iconSz)
    searchIcon:SetPoint("CENTER")
    searchIcon:SetTexture(SEARCH_ICON_TEXTURE)
    iconHolder.icon = searchIcon
    searchFrame.searchIcon = searchIcon
    searchFrame.modeBtn = iconHolder
    searchFrame.iconHolder = iconHolder

    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetHeight(contentSz)
    editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", searchFrame, "RIGHT", -8, 0)
    editBox:SetFontObject(ns.SEARCHBAR_FONT)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)
    -- The propagate flag is enforced from OUTSIDE the key handler at every
    -- unfocus boundary: an UNFOCUSED editbox consumes keys at the C level
    -- from its frame flags alone (visible + keyboard-enabled +
    -- propagate=false, and this bar is FULLSCREEN_DIALOG, topmost in
    -- dispatch), WITHOUT running OnKeyDown -- so an in-handler guard can
    -- never fire. Measured in the escprobe capture: propagate=false at
    -- pristine login ate ENTER and ESC until the first ESC knocked the
    -- state loose. Focused typing still sets per-key propagation inside
    -- OnKeyDown, which does run for a FOCUSED box.
    Utils.SafeCallMethod(editBox, "SetPropagateKeyboardInput", true)
    editBox:HookScript("OnEditFocusLost", function(self)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
    end)

    -- Editbox click handling: plain left-click focuses the input
    -- While the bar is dragged, re-render the open results on a short
    -- throttle so the screen-fit row clamp tracks the position live. The
    -- render cache keys on the frame edge, so unmoved ticks early-out.
    local dragRefreshTicker
    local function StopDragRefresh()
        if dragRefreshTicker then
            dragRefreshTicker:Cancel()
            dragRefreshTicker = nil
        end
        Results:RefreshShownResults()
    end
    local function StartDragRefresh()
        if dragRefreshTicker then return end
        dragRefreshTicker = C_Timer.NewTicker(0.1, function()
            -- Self-terminate if the drag ended without a clean stop (e.g. the
            -- mouse was released off the editbox, so its OnMouseUp never
            -- fired). Without this the ticker leaks into a permanent per-0.1s
            -- re-render that lags the whole UI, including typing.
            if not IsMouseButtonDown("LeftButton") then
                StopDragRefresh()
                return
            end
            local ok = pcall(function()
                Results:RefreshShownResults()
            end)
            if not ok and dragRefreshTicker then
                dragRefreshTicker:Cancel()
                dragRefreshTicker = nil
            end
        end)
    end

    -- (native behavior). Shift+left-click drags the bar -- the
    -- editbox consumes presses so the parent's RegisterForDrag never
    -- fires over the input area; the drag has to live here.
    editBox:HookScript("OnMouseDown", function(self, button)
        if searchFrame.setupMode then
            self.blockFocus = true
            return
        end
        if button ~= "LeftButton" then return end
        if EasyFind.db.lockPosition then return end
        if not IsShiftKeyDown() then return end
        self.blockFocus = true
        self._dragMoving = true
        if self:HasFocus() then self:ClearFocus() end
        searchFrame:StartMoving()
        StartDragRefresh()
    end)
    editBox:HookScript("OnMouseUp", function(self)
        if self._dragMoving and searchFrame:IsMovable() then
            searchFrame:StopMovingOrSizing()
            local point, _, relPoint, x, y = searchFrame:GetPoint()
            EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
            StopDragRefresh()
        end
        self._dragMoving = false
        self.blockFocus = nil
    end)


    local placeholder = editBox:CreateFontString(nil, "ARTWORK", ns.SEARCHBAR_FONT)
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetPoint("RIGHT", editBox, "RIGHT", -2, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetWordWrap(false)
    placeholder:SetTextColor(0.5, 0.5, 0.5, 1.0)
    placeholder:SetText(L["SEARCH_PLACEHOLDER"])
    editBox.placeholder = placeholder

    editBox:SetScript("OnEditFocusGained", function(self)
        if self.blockFocus then
            -- A real click on the box is a legitimate focus request: the
            -- block only rejects WoW's load-time auto-focus, which never
            -- arrives with the cursor pressed on the box. Without this,
            -- the never-expiring Always Show block eats the session's
            -- first click (parent OnMouseDown can't clear it, the
            -- editbox consumes presses over the input area).
            if self:IsMouseOver() and IsMouseButtonDown("LeftButton")
                and not self._dragMoving and not searchFrame.setupMode then
                self.blockFocus = nil
            else
                self:ClearFocus()
                return
            end
        end
        if selectedIndex > 0 then
            selectedIndex = 0
            toggleFocused = false
            Results:UpdateSelectionHighlight(true)
        end
        -- Clicking back into the box must drop any toolbar keyboard focus, or the
        -- focused button's locked highlight (apps grid) stays lit.
        if searchFrame.ClearToolbarFocus then searchFrame.ClearToolbarFocus() end
        -- FOCUS is the search-intent signal (never login, never mere
        -- always-show visibility). First focus warms the provider universe
        -- (staggered, one per frame; the chain ends in WarmSearchHotPath),
        -- so the searchable database exists only in sessions that search.
        if not searchFrame._efProvidersWarmed then
            searchFrame._efProvidersWarmed = true
            if ns.Database and ns.Database.LoadDeferredSyncProvidersStaggered then
                ns.Database:LoadDeferredSyncProvidersStaggered()
            elseif ns.Database and ns.Database.WarmSearchHotPath then
                ns.Database:WarmSearchHotPath()
            end
        end
        -- Pull in the item catalog's LoadOnDemand
        -- companion now, off the keystroke path, but ONLY if its filter is
        -- on -- with the General Catalog unchecked it never loads at all.
        if ns.RequestItemCatalog and not ns.ItemSearch and ns.CategoryMap then
            local uiFilters = EasyFind.db and EasyFind.db.uiSearchFilters
            if not (uiFilters and ns.CategoryMap.IsProviderFilterOff(uiFilters, "catalog")) then
                ns.RequestItemCatalog(false)
            end
        end
        local text = self:GetText() or ""
        if text == "" then
            -- ShowEmptyQueryView, never ShowPinnedItems directly: an active
            -- quick filter owns the empty-text view (@icons renders the
            -- grid). Focus bounces off the filter menu and back were
            -- killing the icon grid here.
            Results:ShowEmptyQueryView()
        else
            -- Refocus with leftover text: select all so the user can
            -- start typing fresh (overwrites) or hit Right Arrow /
            -- Alt+L to keep editing from the end.
            self:HighlightText(0, #text)
            self:SetCursorPosition(#text)
            -- Re-show results if they were closed by a prior click-out.
            if resultsFrame and not resultsFrame:IsShown() then
                Search:OnSearchTextChanged(text, true)
            end
        end
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        -- Skip cleanup when SelectResult is actively clearing text/focus
        if selectingResult then return end
        -- Shift-drag deliberately clears focus while blockFocus is set so
        -- the editbox does not steal the drag. Do not run the normal
        -- click-outside cleanup path from that synthetic focus loss.
        if self._dragMoving then
            self:HighlightText(0, 0)
            return
        end
        -- Intentional unfocus while a row context menu opens: keys belong
        -- to the menu, and the results (pinned view included) must stay
        -- exactly as they are. Set around ClearFocus in ShowResultContextMenu.
        if self._menuUnfocus then
            self:HighlightText(0, 0)
            return
        end
        -- Drop any active text highlight (the focus-gained "select all"
        -- or autocomplete suffix) so leftover text doesn't keep its
        -- selection box after we click away. Re-focus re-applies it.
        self:HighlightText(0, 0)
        -- Entering keyboard-nav mode (Enter / DOWN from the search bar)
        -- programmatically yanks focus so navFrame can take the keys.
        -- Don't treat that as a click-outside; the click-outside path
        -- is handled by resultsFrame's GLOBAL_MOUSE_DOWN handler. Grid
        -- nav is the same yank (its focus index is set before ClearFocus).
        if selectedIndex > 0 then return end
        if Results.IsIconGridNavActive and Results:IsIconGridNavActive() then return end
        -- Click on a guard frame (results, dropdown, popups) keeps
        -- the results visible. Anywhere else (including empty world)
        -- hides them in one click instead of needing a second click
        -- after the autocomplete strip.
        local onGuard = false
        if resultsFrame and resultsFrame:IsMouseOver() then onGuard = true end
        if not onGuard and OptionsSurface:IsOptionsSurfaceMouseOver() then onGuard = true end
        if not onGuard and Filters.IsMouseInFilterChain() then onGuard = true end
        if not onGuard and Utils.IsClickGuardMouseOver() then onGuard = true end
        if not onGuard and resultsFrame and resultsFrame:IsShown() then
            Results:HideResults()
        end
        -- Hover Show: losing focus must arm the fade-out even when text
        -- remains, or a typed-in bar can never hide again.
        if EasyFind.db.smartShow and not onGuard then
            searchFrame.smartShowFadeOut()
        end
        if strtrim(self:GetText()) == "" then
            self:SetText("")  -- Clear any stray whitespace
            self.placeholder:Show()
            -- Defer hide by one frame so pending pin/result clicks (LeftButtonDown)
            -- can fire before the results frame is hidden.  Without the delay the
            -- parent frame hides and the child button never receives its OnClick.
            Utils.SafeAfter(0, function()
                -- The focus-stealing click landed on a guarded surface (a grid
                -- cell, the copy box, a popup): rows/cells handle their own
                -- dismissal, and hiding here would kill the results before an
                -- up-click cell handler ever fires (the deferred hide lands a
                -- frame after mouse-down, well before a human mouse-up).
                if onGuard then return end
                if selectingResult then return end
                if searchFrame.editBox:HasFocus() then return end
                if navFrame and navFrame:IsKeyboardEnabled() then return end
                if strtrim(searchFrame.editBox:GetText()) ~= "" then return end
                if Results:ConsumeKeepPinnedResultsOpen() and Results:HasPinnedItems() then
                    Results:ShowEmptyQueryView()
                    if searchFrame.editBox.blockFocus then
                        searchFrame.editBox.blockFocus = nil
                    end
                    return
                end
                -- Don't hide if spec/class flyouts are open
                local sf = _G["EasyFindSpecFlyout"]
                local ssf = _G["EasyFindSpecSubFlyout"]
                if (sf and sf:IsShown()) or (ssf and ssf:IsShown()) then return end
                local dd = _G["EasyFindUIFilterDropdown"]
                if dd and dd:IsShown() then return end
                if OptionsSurface:IsOptionsSurfaceMouseOver() then return end
                Results:HideResults()
                -- Now that results are hidden, let smart show fade the bar out
                if EasyFind.db.smartShow then
                    searchFrame.smartShowFadeOut()
                end
            end)
        end
    end)

    local lastTypedLen = 0
    local lastSearchTime = 0
    local pendingUISearchText = ""
    local pendingUISearchGrew = false
    local pendingUISearchDue = 0
    local pendingUISearchFrame = CreateFrame("Frame")
    pendingUISearchFrame:Hide()
    Utils.SafeOnUpdate(pendingUISearchFrame, function(self)
        if GetTime() < pendingUISearchDue then return end
        self:Hide()
        local typedNow = pendingUISearchText
        local grew = pendingUISearchGrew
        pendingUISearchText = ""
        pendingUISearchGrew = false
        lastSearchTime = GetTime()
        Search:OnSearchTextChanged(typedNow)
        if grew and editBox.UpdateAutocomplete then
            editBox.UpdateAutocomplete()
        end
    end)
    local function ResetPendingUISearch()
        pendingUISearchFrame:Hide()
        pendingUISearchText = ""
        pendingUISearchGrew = false
        pendingUISearchDue = 0
        lastTypedLen = 0
        SearchHistory:ResetSearchHistory()
    end
    editBox.ResetPendingSearch = ResetPendingUISearch
    local SEARCH_THROTTLE = 0.05  -- 50ms cap on search/render frequency
    editBox:SetScript("OnTextChanged", function(self, userInput)
        self.placeholder:SetShown(self:GetText() == "")
        if userInput then
            local restored, restoreText = Utils.ConsumeSuppressedAltNavChar(self)
            if restored then
                self.placeholder:SetShown((restoreText or "") == "")
                return
            end
            -- Defensive leak repair: the consumer can fail to match when
            -- NavigateSearchHistory's SetText raced with the J/K
            -- character insertion (the snapshot text becomes stale before
            -- the consumer runs, so the "restoreText + key inserted"
            -- check no longer matches the current text).
            --
            -- If a nav repeat is active, any user-input text change here
            -- is a leak, not a real keystroke. Strip a trailing J or K,
            -- re-arm the snapshot for subsequent leaks, and bail out of
            -- the normal "user typed" flow. Without this bail, the
            -- ResetSearchHistory call below would set historyIndex=0
            -- mid-cascade and the Alt+K/UP walk would oscillate instead
            -- of progressing toward the oldest entry.
            local frame = Search:GetSearchFrame()
            if frame and frame.IsAltNavRepeatKey and frame.IsAltNavRepeatKey() then
                local text = self:GetText() or ""
                local lastChar = text:sub(-1):lower()
                if lastChar == "j" or lastChar == "k" then
                    local cleaned = text:sub(1, -2)
                    self:SetText(cleaned)
                    self:SetCursorPosition(#cleaned)
                    self.placeholder:SetShown(cleaned == "")
                    Utils.SuppressNextAltNavChar(self, lastChar)
                end
                return
            end
        end
        -- Skip every non-user text change. WoW defers OnTextChanged
        -- dispatch by one frame, so by the time the autocomplete's
        -- programmatic SetText fires this handler the in-band
        -- programmatic flag has already been reset to false. The only
        -- reliable signal is the userInput parameter WoW passes us:
        -- true for real keystrokes / paste, false for SetText / Insert
        -- / Clear / etc. Without this gate every keystroke produces
        -- two searches (the user's and the autocomplete suffix's),
        -- doubling per-keystroke cost.
        if not userInput then
            if self:GetText() == "" and self.ResetPendingSearch then
                self:ResetPendingSearch()
            end
            return
        end
        if self.IsAutocompleteBackspaceStrip and self:IsAutocompleteBackspaceStrip() then return end
        SearchHistory:ResetSearchHistory()
        if Filters:HandleQuickFilterTextChanged(self) then return end
        -- Search query is the text up to the cursor -- anything past
        -- the cursor is unaccepted autocomplete suffix and must not
        -- feed into search results. Programmatic autocomplete SetText
        -- is filtered above via IsAutocompleteProgrammatic, so the
        -- cursor read here is always from a real keystroke.
        local cursorPos = self:GetCursorPosition() or #(self:GetText() or "")
        local typedNow = (self:GetText() or ""):sub(1, cursorPos)
        local grew = #typedNow > lastTypedLen
        lastTypedLen = #typedNow
        local elapsed = GetTime() - lastSearchTime
        local delay = elapsed >= SEARCH_THROTTLE and 0 or (SEARCH_THROTTLE - elapsed)
        pendingUISearchText = typedNow
        pendingUISearchGrew = grew
        pendingUISearchDue = GetTime() + delay
        pendingUISearchFrame:Show()
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        -- Strip any visible autocomplete suffix first. WoW's EditBox
        -- swallows the Enter when there's a text selection (treating
        -- it like a "deselect" rather than confirm), so without this
        -- the user's first Enter visually clears the highlight but
        -- doesn't focus the result row, they'd have to press Enter
        -- a second time. Stripping here puts the text back to what
        -- the user typed before WoW's default handler runs.
        if self.StripAutocomplete then self:StripAutocomplete() end
        local typed = strtrim(self:GetText() or "")

        -- Slash commands (/reset, /options, ...) are ordinary result rows, so
        -- Enter focuses the first one and a second Enter runs it, exactly like
        -- every other result. Commands aren't recorded in search history.
        if typed ~= "" and typed:sub(1, 1) ~= "/" then
            SearchHistory:PushSearchHistory(typed)
        end
        SearchHistory:ResetSearchHistory()

        -- Enter with the icon grid open: focus the first visible cell,
        -- the grid's equivalent of "focus the first result".
        if Results.IsIconGridShown and Results:IsIconGridShown()
           and not (Results.IsIconGridNavActive and Results:IsIconGridNavActive()) then
            Results:MoveIconGridFocus(0, 1)
            return
        end
        -- Enter on the search bar: focus the first result. Prefer the
        -- first non-pinned row so a fresh search jumps past leftover
        -- pinned shortcuts; fall back to the first pinned row when
        -- pinned results are all that's available. A second Enter on
        -- the focused row activates it.
        if selectedIndex == 0 then
            local target, firstPinned
            for i = 1, MAX_BUTTON_POOL do
                local row = resultButtons[i]
                if not row or not row:IsShown() then break end
                if not row.isPinHeader then
                    if row.isPinned then
                        if not firstPinned then firstPinned = i end
                    else
                        target = i
                        break
                    end
                end
            end
            local idx = target or firstPinned
            if not idx then return end
            selectedIndex = idx
            toggleFocused = false
            Results:UpdateSelectionHighlight()
            local row = resultButtons[idx]
            if row and row.data and row.data.calculatorResult then
                Calculator:ArmCalculatorResultFromRow(row, "key")
            end
            return
        end
        Results:ActivateSelected("key")
    end)

    editBox:SetScript("OnEscapePressed", function(_)
        Search:HandleEscape()
    end)

    -- Chrome-style inline autocomplete: same helper MapTab uses.
    -- Attached AFTER all SetScript calls above so HookScript-based
    -- handlers don't get clobbered. The candidate source is the first
    -- visible result row name, so the suggested completion always
    -- aligns with what the user lands on if they press Enter.
    -- Strip WoW inline markup from item / quest names so the autocomplete
    -- suggestion doesn't leak atlas / color / texture / hyperlink codes
    -- ("|A:professions-chaticon-quality-...|a", "|cffrrggbb...|r", etc.).
    -- Markup is usually preceded by a space ("Item Name |A:...|a"); after
    -- stripping the markup, also collapse runs of whitespace and trim the
    -- result so the suggestion ends cleanly.
    local function StripMarkup(s)
        if not s then return s end
        s = s:gsub("|A:[^|]*|a", "")
        s = s:gsub("|T[^|]*|t", "")
        s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        s = s:gsub("|H[^|]+|h(.-)|h", "%1")
        s = s:gsub("%s+", " ")
        s = s:match("^%s*(.-)%s*$") or s
        return s
    end

    Utils.AttachAutocomplete(editBox, {
        enabled = function() return EasyFind.db.searchAutocomplete ~= false end,
        findCandidate = function(typed)
            if not typed or typed == "" then return nil end
            local lower = typed:lower()
            for i = 1, MAX_BUTTON_POOL do
                local row = resultButtons[i]
                if not row or not row:IsShown() then break end
                local quickDef = row.data and row.data.quickFilterDef
                local quickToken = quickDef and Filters:GetQuickFilterCompletionToken(quickDef, typed)
                if quickToken then
                    return quickToken
                end
                local rawName = row.data and row.data.name
                local nm = StripMarkup(rawName)
                if nm and #nm >= #typed then
                    local prefix = nm:sub(1, #typed):lower()
                    if prefix == lower and nm:lower() ~= lower then
                        return nm
                    end
                end
            end
            return nil
        end,
        backspaceAutocompleteTarget = function(_, typed)
            if not Filters:IsQuickFilterSuggestionsActive() or not typed then return nil end
            if not typed:match("^%s*@[%w_%-:]*$") then return nil end
            local text = typed:sub(1, -2)
            return text, #text
        end,
        onBackspaceAutocompleteRestored = function(box, text)
            if box and box.placeholder then
                box.placeholder:SetShown((box:GetText() or "") == "")
            end
            if box and box.ResetPendingSearch then
                box:ResetPendingSearch()
            end
            if box and Filters:UpdateQuickFilterSuggestions(box) then
                return
            end
            Search:OnSearchTextChanged(text or "", true)
        end,
        onAccepted = function(text)
            if text and text ~= "" then
                local box = searchFrame and searchFrame.editBox
                if box and text:match("^%s*@[%w_%-:]+$") and Filters:UpdateQuickFilterSuggestions(box) then
                    return
                end
                Search:OnSearchTextChanged(text, true)
            end
        end,
    })

    -- Shift+click link insertion: when the search bar has focus, shift-clicking
    -- an item in bags / an achievement in the achievement frame / a spell in
    -- the spellbook etc. routes the link's display name into our editbox the
    -- same way it does into a chat editbox. ChatEdit_InsertLink is the shared
    -- hook the default Search uses for this; hooking it lets us pick up the link
    -- when our box is the active typing target.
    if not Search._chatLinkHooked then
        Search._chatLinkHooked = true
        hooksecurefunc("ChatEdit_InsertLink", function(text)
            if not text or text == "" then return end
            local box = searchFrame and searchFrame.editBox
            if box and box:IsVisible() and box:HasFocus() then
                -- Strip the hyperlink wrapper so the search engine sees a
                -- plain query string ("Hearthstone" instead of |cff...|H...).
                local name = text:match("|h%[(.-)%]|h") or text
                box:Insert(name)
            end
        end)
    end

    local filterBtn = CreateFrame("Button", "EasyFindUIFilterButton", searchFrame)
    filterBtn:SetPoint("TOP", searchFrame, "TOP", 0, 0)
    filterBtn:SetPoint("BOTTOM", searchFrame, "BOTTOM", 0, 0)
    filterBtn:SetPoint("RIGHT", searchFrame, "RIGHT", 0, 0)
    filterBtn:SetWidth(searchFrame:GetHeight())
    -- Sit well above the rounded container's pill border so the filter
    -- button's circular hover/highlight isn't visually clipped by the bar.
    filterBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 50)

    local filterArrow = filterBtn:CreateTexture(nil, "OVERLAY")
    filterArrow:SetSize(11, 11)
    -- 1px down: a downward triangle's optical center (centroid, a third up
    -- from the base) sits above its bounding-box center, so a box-centered
    -- arrow reads high against the round glow, tip at the glow's middle.
    filterArrow:SetPoint("CENTER", 0, -1)
    -- Custom flat triangle (textures/filter-arrow.tga) rather than a cropped
    -- Blizzard texture, so it stays crisp at higher search scales.
    filterArrow:SetTexture(ns.FILTER_ARROW_TEX)
    filterArrow:SetBlendMode("ADD")
    filterArrow:SetVertexColor(1, 1, 1)
    filterBtn.arrow = filterArrow

    local filterBtnBg = filterBtn:CreateTexture(nil, "ARTWORK")
    filterBtnBg:SetAllPoints()
    filterBtnBg:SetTexture(796424)
    filterBtnBg:Hide()
    filterBtn.btnBg = filterBtnBg

    filterBtn:SetHighlightTexture(130757)

    -- Round-pill bar theme: clip the original Blizzard hover/highlight
    -- textures into a circle that fits inside the bar's right-cap
    -- silhouette. AddMaskTexture preserves the originals' colors
    -- (dark hover bg, blue ADD highlight) and just clips the shape.
    if theme.searchBarRounded then
        -- Round blue hover glow. Blizzard's hover bg (796424) and highlight
        -- (130757) are FILE textures that ignore AddMaskTexture here (square). So
        -- drive btnBg with our own glow texture: a radial blue->navy gradient that
        -- fades to transparent corners (round on its own, no mask) with a deep-blue
        -- shadow rim instead of a hard fade to black. Colors are baked in, so a
        -- plain white tint, normal-alpha blended (~90% opaque), inset to sit
        -- inside the bar's right-cap silhouette. The glow is the whole hover
        -- and focus look; the old gold perimeter ring on top of it read as
        -- redundant next to the apps button's plain glow.
        local innerInset = 6
        filterBtnBg:SetTexture("Interface\\AddOns\\EasyFind\\textures\\filter-glow")
        filterBtnBg:SetVertexColor(1, 1, 1)
        filterBtnBg:SetBlendMode("BLEND")
        filterBtnBg:ClearAllPoints()
        filterBtnBg:SetPoint("TOPLEFT",     filterBtn, "TOPLEFT",      innerInset, -innerInset)
        filterBtnBg:SetPoint("BOTTOMRIGHT", filterBtn, "BOTTOMRIGHT", -innerInset,  innerInset)
        local hl = filterBtn:GetHighlightTexture()
        if hl then hl:SetTexture(nil) end
    end

    local FILTER_TOOLTIP_DELAY = ns.TOOLTIP_HOVER_DELAY
    filterBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        local token = (self._tooltipToken or 0) + 1
        self._tooltipToken = token
        Utils.SafeAfter(FILTER_TOOLTIP_DELAY, function()
            if self._tooltipToken ~= token or not self:IsMouseOver() then return end
            if searchFrame.filterDropdown and searchFrame.filterDropdown:IsShown() then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            ns.ResultTooltips.ApplySearchTooltipScale(GameTooltip)
            GameTooltip:SetText(L["FILTER_RESULTS"])
            GameTooltip:AddLine(L["FILTER_RESULTS_TT"], 1, 1, 1, true)
            GameTooltip:Show()
        end)
    end)
    filterBtn:SetScript("OnLeave", function(self)
        self._tooltipToken = (self._tooltipToken or 0) + 1
        -- The button stays ENGAGED (hover look) the whole time its menu is
        -- open, like a result row during its context menu.
        local dd = searchFrame.filterDropdown
        if not self.keyboardFocused and not (dd and dd:IsShown()) then
            self.btnBg:Hide()
        end
        GameTooltip_Hide()
    end)
    -- Engage/disengage from the dropdown's lifecycle (hooked where the
    -- dropdown is created); disengage respects hover/keyboard focus.
    filterBtn.SetMenuEngaged = function(self, engaged)
        if engaged then
            self.btnBg:Show()
        elseif not self:IsMouseOver() and not self.keyboardFocused then
            self.btnBg:Hide()
        end
    end
    searchFrame.filterBtn = filterBtn

    editBox:ClearAllPoints()
    editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    editBox:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
    self:CreateQuickFilterPill(searchFrame, editBox, iconHolder, filterBtn)
    self:UpdateQuickFilterPill()

    -- Click anywhere on the search frame to focus the editbox (enables blinking cursor).
    -- Use HookScript to preserve SmartShow OnLeave handlers;
    -- skip focus if SmartShow is active and editbox is empty (prevents the bar getting stuck visible).
    -- Skip when the click landed on one of the toolbar buttons - they have their
    -- own behavior, and stealing keyboard focus here would yank it away from any
    -- other editable frame the player is currently using (chat, mail, /say, etc).
    searchFrame:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or IsShiftKeyDown() or self.setupMode then return end
        if (filterBtn and filterBtn:IsMouseOver())
           or (iconHolder and iconHolder:IsMouseOver()) then
            return
        end
        if activeKeybindBtn and activeKeybindBtn._stopCapture then
            activeKeybindBtn._stopCapture(activeKeybindBtn)
        end
        editBox.blockFocus = nil
        editBox:SetFocus()
    end)

    -- Shared key-repeat helper (also used by MapTab). Attaches its own
    -- OnUpdate to searchFrame; action fires immediately on Start, then
    -- at an accelerating cadence while the key is held.
    local keyRepeat = Utils.CreateKeyRepeat(searchFrame)
    local StartKeyRepeat = keyRepeat.Start
    local StopKeyRepeat  = keyRepeat.Stop
    searchFrame.StartKeyRepeat = StartKeyRepeat
    searchFrame.StopKeyRepeat  = StopKeyRepeat
    searchFrame.IsRepeatKey    = keyRepeat.IsKey

    local function MoveDown1() Results:MoveSelection(1) end
    local function MoveDown5() Results:MoveSelection(5) end
    local function MoveUp5() Results:MoveSelection(-5) end
    local function GridFocusLeft() Results:MoveIconGridFocus(-1, 0) end
    local function GridFocusRight() Results:MoveIconGridFocus(1, 0) end
    -- Results-above mode: UP from the editbox should land on the LAST row
    -- (visually closest to the search bar), then step up from there as the
    -- key continues to be held. Asymmetric with the below-mode case, which
    -- can use MoveDown1 directly since MoveSelection(1) lands on row 1 from
    -- selectedIndex==0 and steps from there.
    local function EnterAboveOrStepUp()
        -- Grid nav active counts as "already entered" even though
        -- selectedIndex stays 0: keep stepping instead of re-jumping to
        -- the end on every held tick.
        if selectedIndex == 0
           and not (Results.IsIconGridNavActive and Results:IsIconGridNavActive()) then
            Results:JumpToEnd()
        else
            Results:MoveSelection(-1, true, true)
        end
    end
    -- Any held nav key (Alt+J/K or plain UP/DOWN) counts as an active nav
    -- repeat. History.lua uses this to decide whether to preserve the
    -- ticker across a NavigateSearchHistory re-render. Restricting this
    -- to J/K broke held UP/DOWN crossing into history.
    searchFrame.IsAltNavRepeatKey = function()
        return keyRepeat.IsKey("J") or keyRepeat.IsKey("K")
            or keyRepeat.IsKey("UP") or keyRepeat.IsKey("DOWN")
    end

    local function RefocusEditBoxAfterNav()
        if selectedIndex ~= 0 then return end
        -- Grid nav keeps selectedIndex at 0 while it owns the keys; a key
        -- RELEASE must not snap focus back to the editbox mid-navigation
        -- (that refocus was why every key after the first Down landed in
        -- the editbox: UP walked history, LEFT/RIGHT moved the caret).
        if Results.IsIconGridNavActive and Results:IsIconGridNavActive() then return end
        if not searchFrame or not searchFrame:IsShown() then return end
        if not editBox then return end
        -- Restore the original MaxLetters that the alt-nav lock saved
        -- (see OnKeyDown alt+J/K branch). Has to happen here because
        -- this is the canonical "alt-nav cascade is fully over" hook,
        -- fired by both normal release and timeout paths.
        if editBox._altNavMaxLettersSaved then
            editBox:SetMaxLetters(editBox._altNavMaxLettersSaved)
            editBox._altNavMaxLettersSaved = nil
        end
        if editBox:HasFocus() then return end
        editBox.blockFocus = nil
        editBox:SetFocus()
    end

    local function StopRepeatAndMaybeRefocus(key)
        key = Utils.NormalizeKey(key)
        if not keyRepeat.IsKey(key) then return end
        -- When the navFrame loses keyboard mid-hold (e.g., MoveSelection
        -- lands selectedIndex=0 and UpdateSelectionHighlight calls
        -- EnableKeyboard(false)), WoW dispatches a synthetic OnKeyUp for
        -- the held key. We must NOT stop the ticker in that case, or the
        -- cascade dies the moment it crosses the results->editbox
        -- boundary. The real OnKeyUp arrives when the user actually
        -- releases the key. Use the alias-aware helper because WoW's
        -- IsKeyDown spells arrow keys as "UPARROW"/"DOWNARROW" while
        -- OnKeyDown reports "UP"/"DOWN".
        if Utils.IsPhysicalKeyDown(key) then return end
        StopKeyRepeat(key)
        RefocusEditBoxAfterNav()
    end

    -- When the cascade crosses from results into history nav, the editbox
    -- needs focus so the user sees a properly focused search bar instead
    -- of an unfocused one with text walking through it. The earlier
    -- UpdateSelectionHighlight (skipRefocus=true) deliberately did not
    -- refocus, so we do it here at the crossing point.
    local function RefocusEditBoxForHistoryNav()
        if not editBox then return end
        if editBox:HasFocus() then return end
        editBox.blockFocus = nil
        editBox:SetFocus()
    end

    local function StepAltJ()
        if SearchHistory:IsSearchHistoryActive() then
            RefocusEditBoxForHistoryNav()
            return SearchHistory:NavigateSearchHistory(-1)
        end
        return Results:MoveSelection(1, true, true)
    end

    local function StepAltK()
        -- Grid nav keeps selectedIndex at 0 (it has its own focus index);
        -- without this check UP inside the grid fell through to history.
        if selectedIndex > 0
           or (Results.IsIconGridNavActive and Results:IsIconGridNavActive()) then
            return Results:MoveSelection(-1, true, true)
        end
        RefocusEditBoxForHistoryNav()
        return SearchHistory:NavigateSearchHistory(1)
    end

    local function StartAltNavRepeat(key, step)
        Utils.StartAltNavRepeat(keyRepeat, key, editBox, step, RefocusEditBoxAfterNav)
    end

    -- Arrow key / Tab navigation for results dropdown.
    -- IMPORTANT: Block propagation while the editbox has focus so that
    -- typed letters never trigger the player's game keybinds. The one
    -- exception is EasyFind's own bindings (TOGGLE_FOCUS, MAP_FOCUS,
    -- CLEAR): the toggle key has to close the bar from inside the
    -- editbox, otherwise it just types as a character and the user
    -- can't dismiss with the same key they used to open.
    editBox:SetScript("OnKeyDown", function(self, key)
        -- UNFOCUSED: never consume. A visible EditBox with an OnKeyDown
        -- script joins WoW's keyboard-capture chain even without focus,
        -- and any path that leaves propagate=false here eats EVERY key
        -- (ENTER never opens chat, ESC dies) until one keypress happens
        -- to reset it -- the Always Show first-keys-after-reload bug,
        -- proven by the escprobe capture (focus=none, no overrides,
        -- EasyFindSearchBox visible+keyboard-enabled+propagate=false).
        if not self:HasFocus() then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            return
        end
        local navKey = key and key:upper() or key
        -- Alt+letter: set propagate=false up front; late suppression can leak
        -- the char into the editbox before OnChar sees the new state.
        if IsAltKeyDown() and navKey and navKey:match("^[A-Z]$") then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        end
        if IsAltKeyDown() and (navKey == "J" or navKey == "K") then
            Utils.SuppressNextAltNavChar(self, navKey)
        end
        Search:HandleCalculatorPasteIntoSearch(self, key)
        if Search:HandleCalculatorOpenShortcut(self, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end
        if Filters:HandleQuickFilterKeyDown(self, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        local shortcutIndex = Shortcuts:GetResultShortcutIndex(key)
        if shortcutIndex then
            -- Alt+digit still inserts the digit character into the focused
            -- editbox (propagate only governs the game side). The snapshot
            -- repair the Alt+J/K nav keys use cannot cover this: shortcut
            -- activation may rewrite the text (apply a quick filter, clear
            -- the box) before the char event lands, invalidating the
            -- snapshot. Swallow the char itself at OnChar instead, keyed by
            -- the digit CHAR: shortcutIndex is that digit for both
            -- spellings of the key ("4" and "NUMPAD4"). The navFrame copy
            -- of this block needs none of this: in keyboard-nav mode the
            -- editbox is unfocused, so no character can insert.
            Utils.SwallowNextCharInsert(self, tostring(shortcutIndex))
            local shortcutResult = Shortcuts:ActivateVisibleResultShortcut(shortcutIndex)
            if shortcutResult then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", shortcutResult == "binding")
                return
            end
        end

        -- Match the keybind capture's combo format: ALT-CTRL-SHIFT-key.
        -- GetBindingAction is the correct API (GetBindingByKey doesn't
        -- exist) and returns the binding name for a given key combo.
        local mod = ""
        if IsAltKeyDown()     then mod = mod .. "ALT-"  end
        if IsControlKeyDown() then mod = mod .. "CTRL-" end
        if IsShiftKeyDown()   then mod = mod .. "SHIFT-" end
        local boundAction = GetBindingAction and GetBindingAction(mod .. key)
        if boundAction and string.sub(boundAction, 1, 9) == "EASYFIND_" then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            return
        end
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            if key == "RIGHT" or key == "ARROWRIGHT" then
                self:AcceptAutocomplete("right")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            elseif navKey == "L" and IsAltKeyDown() then
                self:AcceptAutocomplete("alt-l")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
        end
        -- Tab with no autocomplete pending: hand focus to the toolbar ring
        -- (filter button). With a suggestion visible, OnTabPressed accepts
        -- it instead. Quick-filter suggestion Tab is consumed earlier by
        -- HandleQuickFilterKeyDown.
        if key == "TAB" then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            if not (self.HasAutocomplete and self:HasAutocomplete()) then
                self._menuUnfocus = true
                self:ClearFocus()
                self._menuUnfocus = nil
                Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
                if searchFrame.SetToolbarFocus then searchFrame.SetToolbarFocus(1) end
            end
            return
        end
        -- ENTER with autocomplete highlight visible: WoW's default
        -- editbox processing treats the first Enter as "deselect"
        -- and silently swallows it without firing OnEnterPressed.
        -- Strip the suggestion now so Enter falls through cleanly
        -- on the user's first press instead of needing two presses.
        if key == "ENTER" and self.StripAutocomplete then
            self:StripAutocomplete()
        end
        -- Shell-style history. UP walks back toward older entries
        -- (capped at the oldest); DOWN walks forward toward newer
        -- entries until we land back on the live draft, then drops
        -- into the results list. Drop-into-results works regardless
        -- of buffer content: the user wants keyboard nav into rows
        -- without having to press Enter first, even mid-edit.
        local isAltJ = IsAltKeyDown() and navKey == "J"
        local isAltK = IsAltKeyDown() and navKey == "K"
        if isAltK or isAltJ then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            -- Hard-block character insertion while alt is held. WoW's
            -- SetPropagateKeyboardInput(false) does NOT prevent the
            -- editbox from accepting OS-level auto-repeat characters, so
            -- we use SetMaxLetters at the current text length: the
            -- editbox physically refuses any further input. History nav
            -- still works because NavigateSearchHistory raises the limit
            -- before SetText and lowers it back to the new length after.
            -- The saved original MaxLetters is restored on alt release.
            if not self._altNavMaxLettersSaved then
                self._altNavMaxLettersSaved = self:GetMaxLetters() or 0
                self:SetMaxLetters(#(self:GetText() or ""))
            end
            StartAltNavRepeat(navKey, isAltK and StepAltK or StepAltJ)
            return
        end

        local isUpHist   = key == "UP"
        local isDownHist = key == "DOWN"
        if isUpHist then
            if SearchHistory:NavigateSearchHistory(1) then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
            -- At history ceiling: swallow the key so it can't fall
            -- through to result navigation or game keybinds.
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        elseif isDownHist then
            if SearchHistory:IsSearchHistoryActive() then
                SearchHistory:NavigateSearchHistory(-1)
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
            -- historyIndex == 0 (live draft): fall through to result
            -- nav so DOWN/Alt+J jumps into the first row.
        end

        if resultsFrame and resultsFrame:IsShown() and selectedIndex == 0 then
            -- Use StartKeyRepeat (not the action directly) so holding the key
            -- keeps cascading after focus shifts to the navFrame. OnKeyDown
            -- only fires once per physical press; the repeat ticker is what
            -- makes hold-to-cascade work.
            if EasyFind.db.uiResultsAbove then
                if key == "UP" then StartKeyRepeat("UP", EnterAboveOrStepUp) end
            else
                if key == "DOWN" then StartKeyRepeat("DOWN", MoveDown1) end
            end
        end
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    end)

    -- Mirror the navFrame OnKeyUp: a key whose down event landed on the
    -- editbox needs to terminate its hold-repeat ticker on release here
    -- too, otherwise it keeps stepping after the user lets go.
    editBox:SetScript("OnKeyUp", function(_, key)
        StopRepeatAndMaybeRefocus(key)
    end)

    searchFrame.editBox = editBox

    -- Toolbar keyboard focus: 0 = editbox, 1+ = toolbar control index
    local toolbarFocus = 0

    local toolbarHighlight = CreateFrame("Frame", nil, UIParent)
    toolbarHighlight:SetFrameStrata("LOW")
    toolbarHighlight:SetFrameLevel(searchFrame:GetFrameLevel() + 100)
    toolbarHighlight:Hide()
    searchFrame.toolbarHighlight = toolbarHighlight
    local tbHL = toolbarHighlight:CreateTexture(nil, "OVERLAY")
    tbHL:SetAllPoints()
    tbHL:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    tbHL:SetBlendMode("ADD")
    tbHL:SetVertexColor(Utils.RGB(GOLD_COLOR, 0.5))
    toolbarHighlight.tex = tbHL

    local TOOLBAR_CONTROLS = { filterBtn }
    local function GetToolbarControls()
        -- Apps button sits left of the filter button, so Tab visits it first.
        -- Rebuilt in place (no allocation) since the apps button is created after
        -- this closure and can be toggled off.
        local apps = searchFrame.appsBtn
        if apps and apps:IsShown() then
            TOOLBAR_CONTROLS[1] = apps
            TOOLBAR_CONTROLS[2] = filterBtn
        else
            TOOLBAR_CONTROLS[1] = filterBtn
            TOOLBAR_CONTROLS[2] = nil
        end
        return TOOLBAR_CONTROLS
    end

    local function SetToolbarFocus(idx)
        local prevControls = GetToolbarControls()
        local prevTarget = prevControls[toolbarFocus]
        if prevTarget then
            prevTarget.keyboardFocused = nil
            if prevTarget.btnBg then prevTarget.btnBg:Hide() end
            if prevTarget.UnlockHighlight then prevTarget:UnlockHighlight() end
            if prevTarget.RefreshReveal then prevTarget.RefreshReveal() end
        end
        toolbarFocus = idx
        local controls = GetToolbarControls()
        local target = controls[idx]
        if target then
            target.keyboardFocused = true
            if target.RefreshReveal then target.RefreshReveal() end
            if target.btnBg then
                target.btnBg:Show()
                if target.LockHighlight then target:LockHighlight() end
                toolbarHighlight:Hide()
            elseif target.LockHighlight and target:GetHighlightTexture() then
                -- Buttons with their own hover highlight (apps grid) light that
                -- up on focus, matching hover instead of a plain focus box.
                target:LockHighlight()
                toolbarHighlight:Hide()
            else
                toolbarHighlight:SetParent(target)
                toolbarHighlight:ClearAllPoints()
                toolbarHighlight:SetAllPoints(target)
                toolbarHighlight:Show()
            end
        else
            toolbarHighlight:Hide()
        end
    end

    local function ClearToolbarFocus()
        local controls = GetToolbarControls()
        local prevTarget = controls[toolbarFocus]
        if prevTarget then
            prevTarget.keyboardFocused = nil
            if prevTarget.btnBg then prevTarget.btnBg:Hide() end
            if prevTarget.UnlockHighlight then prevTarget:UnlockHighlight() end
            if prevTarget.RefreshReveal then prevTarget.RefreshReveal() end
        end
        toolbarFocus = 0
        toolbarHighlight:Hide()
    end
    searchFrame.ClearToolbarFocus = ClearToolbarFocus
    searchFrame.SetToolbarFocus = SetToolbarFocus

    -- Keyboard capture frame for navigating results without editbox focus
    navFrame = CreateFrame("Frame", nil, searchFrame)
    navFrame:SetSize(1, 1)
    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
    Utils.SafeCallMethod(navFrame, "SetPropagateKeyboardInput", false)

    -- toggle button (chevron / pin toggle) and back. Shared by Tab,
    -- Shift+Tab, and the Alt+L / Alt+H vim aliases below.
    local function CycleFocus(reverse)
        if reverse then
            if selectedIndex > 0 and toggleFocused then
                toggleFocused = false
                Results:UpdateSelectionHighlight()
            elseif toolbarFocus > 0 then
                if toolbarFocus == 1 then
                    ClearToolbarFocus()
                    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                    searchFrame.editBox.blockFocus = nil
                    searchFrame.editBox:SetFocus()
                else
                    SetToolbarFocus(toolbarFocus - 1)
                end
            end
        else
            if selectedIndex > 0 and not toggleFocused then
                local row = resultButtons[selectedIndex]
                local hasToggle = row and row.isPathNode and (
                    (row.headerTab and row.headerTab:IsShown()) or
                    (row.isPinHeader and row.pinToggle and row.pinToggle:IsShown())
                )
                if hasToggle then
                    toggleFocused = true
                    Results:UpdateSelectionHighlight()
                end
            elseif toolbarFocus > 0 then
                local controls = GetToolbarControls()
                if toolbarFocus >= #controls then
                    ClearToolbarFocus()
                    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
                    searchFrame.editBox.blockFocus = nil
                    searchFrame.editBox:SetFocus()
                else
                    SetToolbarFocus(toolbarFocus + 1)
                end
            end
        end
    end

    local function HandleNavKeyDown(key)
        if Utils.IsModifierKey(key) then return end

        if Search:HandleCalculatorOpenShortcut(searchFrame and searchFrame.editBox, key) then return end
        if Search:HandleCalculatorCopyConfirmKey(key) then return end
        if Search:HandleCalculatorCopyKey(key) then return end

        local alt = IsAltKeyDown()
        local ctrl = IsControlKeyDown()
        local shift = IsShiftKeyDown()

        -- Alt+H/J/K/L: vim-style nav aliases. J/K = down/up;
        -- add Shift to jump sections like Shift+Up/Down.
        -- H/L = focus cycle (Shift+Tab / Tab).
        if alt and key == "J" then
            if shift then
                Results:JumpToNextSection(1)
            else
                StartAltNavRepeat(key, StepAltJ)
            end
            return
        elseif alt and key == "K" then
            if shift then
                Results:JumpToNextSection(-1)
            else
                StartAltNavRepeat(key, StepAltK)
            end
            return
        elseif alt and key == "L" then
            -- On the grid, H/L are horizontal moves (vim left/right);
            -- everywhere else they cycle focus like Tab/Shift+Tab.
            if Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
                Results:MoveIconGridFocus(1, 0)
            else
                CycleFocus(false)
            end
            return
        elseif alt and key == "H" then
            if Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
                Results:MoveIconGridFocus(-1, 0)
            else
                CycleFocus(true)
            end
            return
        end

        if (key == "LEFT" or key == "RIGHT")
           and Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
            StartKeyRepeat(key, key == "LEFT" and GridFocusLeft or GridFocusRight)
            return
        end

        if key == "DOWN" then
            if ctrl then
                Results:JumpToEnd()
            elseif shift then
                Results:JumpToNextSection(1)
            else
                -- StepAltJ (not MoveDown1) so a held DOWN that crosses the
                -- results boundary in above mode continues into history
                -- navigation rather than dying at the editbox. Same
                -- semantics as Alt+J; in below mode the boundary case
                -- never triggers because DOWN past last clamps.
                StartKeyRepeat(key, StepAltJ)
            end
        elseif key == "UP" then
            if ctrl then
                Results:JumpToStart()
            elseif shift then
                Results:JumpToNextSection(-1)
            else
                -- StepAltK (not MoveUp1) so a held UP that exits past the
                -- first row in below mode continues into history-back nav
                -- rather than dying at the editbox. Same semantics as
                -- Alt+K; in above mode the boundary case never triggers
                -- because UP past first clamps.
                StartKeyRepeat(key, StepAltK)
            end
        elseif key == "SPACE" then
            -- SPACE on a highlighted group/pin header toggles collapse.
            -- Consumed unconditionally while navigating so it never
            -- leaks through to the editbox (which would otherwise
            -- refocus on the next UpdateSelectionHighlight and insert a
            -- literal space character into the search text).
            --
            -- Toggling also rebuilds the result list (via
            -- ShowHierarchicalResults), which wipes selectedIndex.
            -- Snapshot the row's identity first so the same header can
            -- be re-selected after the rebuild, letting the user spam
            -- Space to collapse/expand without losing selection.
            if selectedIndex > 0 then
                local row = resultButtons[selectedIndex]
                if row then
                    local savedPinHeader    = row.isPinHeader
                    local savedPathName     = row.isPathNode and row.pathNodeName
                    local savedPathDepth    = row.isPathNode and row.pathNodeDepth
                    if row.isPinHeader and row.pinToggle and row.pinToggle:IsShown() then
                        local handler = row.pinToggle:GetScript("OnClick")
                        if handler then handler(row.pinToggle, "LeftButton") end
                    elseif row.toggleBtn and row.toggleBtn:IsShown() then
                        local handler = row.toggleBtn:GetScript("OnClick")
                        if handler then handler(row.toggleBtn, "LeftButton") end
                    end
                    for i = 1, MAX_BUTTON_POOL do
                        local rb = resultButtons[i]
                        if not rb then break end
                        if rb:IsShown() then
                            local match = false
                            if savedPinHeader and rb.isPinHeader then
                                match = true
                            elseif savedPathName and rb.isPathNode
                               and rb.pathNodeName == savedPathName
                               and rb.pathNodeDepth == savedPathDepth then
                                match = true
                            end
                            if match then
                                selectedIndex = i
                                toggleFocused = false
                                Results:UpdateSelectionHighlight()
                                break
                            end
                        end
                    end
                end
            end
            return
        elseif key == "PAGEDOWN" then
            StartKeyRepeat(key, MoveDown5)
        elseif key == "PAGEUP" then
            StartKeyRepeat(key, MoveUp5)
        elseif key == "HOME" then
            Results:JumpToStart()
        elseif key == "END" then
            Results:JumpToEnd()
        elseif key == "TAB" then
            if Filters:IsQuickFilterSuggestionsActive() and Filters:AcceptQuickFilterSuggestion() then
                return
            end
            -- Tab on the grid's focused cell = its context menu, exactly
            -- like Tab on a focused result row.
            if not shift and Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
                if Results:OpenIconGridFocusMenu() then
                    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
                    return
                end
            end
            if not shift and selectedIndex > 0 and not toggleFocused then
                local row = resultButtons[selectedIndex]
                if row and Rows.ShowResultContextMenu and Rows:ShowResultContextMenu(row, true) then
                    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
                    return
                end
            end
            CycleFocus(shift)
        elseif key == "ENTER" then
            if toolbarFocus > 0 then
                local controls = GetToolbarControls()
                local target = controls[toolbarFocus]
                if target then target:Click() end
            else
                Results:ActivateSelected("key")
            end
        elseif key == "ESCAPE" then
            -- Reset nav state inline (toolbarFocus / selectedIndex /
            -- toggleFocused are locals to this closure, so we can't move
            -- this into HandleEscape without exposing them). Then route
            -- through HandleEscape so the same close-menus / clear-text /
            -- hide-bar decision tree runs as the editBox and unfocused-ESC
            -- paths. Single ESC closes the bar when no menus are open.
            if toolbarFocus > 0 then
                ClearToolbarFocus()
            end
            if selectedIndex > 0 or toggleFocused then
                selectedIndex = 0
                toggleFocused = false
                Results:UpdateSelectionHighlight(true)
            end
            if Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
                Results:ExitIconGridNav(false)
            end
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
            if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
            Search:HandleEscape()
        else
            -- If no selection and editbox isn't focused, let the key propagate
            -- to the game (e.g. WASD movement) instead of typing into the bar.
            if selectedIndex == 0 and not searchFrame.editBox:HasFocus()
               and not (Results.IsIconGridNavActive and Results:IsIconGridNavActive()) then
                Utils.SafeCallMethod(navFrame, "SetPropagateKeyboardInput", true)
                return
            end
            -- Selection is active and a non-nav key was pressed: swallow it.
            -- Previously this branch yanked focus back to the editbox and
            -- inserted the typed character, which felt like the bar was
            -- still capturing input even though the user had committed to
            -- the results list. To type more, press ESC (back to editbox)
            -- or click the bar.
            ClearToolbarFocus()
        end
    end

    navFrame:SetScript("OnKeyDown", function(self, key)
        -- SELF-HEALING INVARIANT: nav keyboard with no nav context is a
        -- stray enable left by an init/teardown race (measured: the
        -- escprobe login capture showed keyboard=true selectedIndex=0,
        -- and this frame -- visible + keyboard-enabled + propagate=false
        -- -- ate the session's first ENTER and ESC; the ESC branch below
        -- disabling keyboard is exactly why one ESC "fixed" it). With no
        -- selection, no toolbar focus, and no results shown, disarm and
        -- propagate this very key so nothing is ever eaten.
        if selectedIndex == 0 and toolbarFocus == 0
            and not (resultsFrame and resultsFrame:IsShown()) then
            Utils.SafeCallMethod(self, "EnableKeyboard", false)
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            return
        end
        if Search:HandleCalculatorOpenShortcut(searchFrame and searchFrame.editBox, key) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        if Calculator:IsCalculatorCopyConfirmKey(key) then
            Search:RearmActiveCalculatorCopy("confirm")
            Utils.SafeAfter(0, function()
                Search:ConfirmCalculatorCopied()
            end)
            -- Ctrl+C must not leak to gameplay keybinds. The hidden editbox is
            -- already focused and selected; swallowing propagation still lets
            -- the client copy that selected text.
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            return
        end

        local shortcutIndex = Shortcuts:GetResultShortcutIndex(key)
        if shortcutIndex then
            local shortcutResult = Shortcuts:ActivateVisibleResultShortcut(shortcutIndex)
            if shortcutResult then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", shortcutResult == "binding")
                return
            end
        end

        -- Secure-action rows: let Enter propagate to the override
        -- binding so the secure click dispatch fires (same as a mouse
        -- click). Without this navFrame swallows Enter and the
        -- override binding never sees the key.
        if key == "ENTER" and selectedIndex > 0 and not InCombatLockdown() then
            local selRow = resultButtons[selectedIndex]
            local rd = selRow and selRow.data
            if rd and Icons:IsSecureActionResult(rd) then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
                return
            end
        end
        -- Decide whether this key is one we actually use for nav. If
        -- not (e.g. WASD movement, plain SPACE for jumping, ability
        -- bar keys), propagate to the game so the player isn't
        -- stranded just because a result is highlighted.
        local consume = false
        if key == "DOWN" or key == "UP" or key == "PAGEDOWN" or key == "PAGEUP"
            or key == "HOME" or key == "END" or key == "TAB" or key == "ENTER"
            or key == "ESCAPE" then
            consume = true
        elseif (key == "LEFT" or key == "RIGHT")
            and Results.IsIconGridNavActive and Results:IsIconGridNavActive() then
            -- Horizontal moves only exist on the icon grid; everywhere else
            -- LEFT/RIGHT stay game keys (turning).
            consume = true
        elseif Calculator:IsCalculatorCopyKey(key) then
            consume = true
        elseif IsAltKeyDown() and (key == "J" or key == "K" or key == "L" or key == "H") then
            consume = true
        elseif key == "SPACE" then
            -- Only consume SPACE when it would do something here:
            -- toggling the collapse on the focused header. A leaf row
            -- has no toggle, so SPACE means "jump" and must reach the
            -- game.
            local row = selectedIndex > 0 and resultButtons[selectedIndex]
            local hasToggle = row and (
                (row.isPinHeader and row.pinToggle and row.pinToggle:IsShown())
                or (row.toggleBtn and row.toggleBtn:IsShown()))
            if hasToggle then consume = true end
        end
        if consume then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            HandleNavKeyDown(key)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        StopRepeatAndMaybeRefocus(key)
    end)

    -- Unfocused-ESC path: while the bar is shown, a transient ESCAPE
    -- override (Utils.AttachEscClose) routes ESC into the same unified
    -- HandleEscape the focused path uses. Never UISpecialFrames: Blizzard's
    -- CloseWindows reads each registered name out of _G, and reading an
    -- addon-created global taints its execution for the session (combat
    -- ADDON_ACTION_BLOCKED / secret-value storms; see taint.log). A focused
    -- editbox still consumes ESC ahead of any binding, so the focused flow
    -- is untouched; copy/share popups shown on top register later and take
    -- ESC first (LIFO), matching the old catcher's deferral to them.
    Utils.AttachEscClose(searchFrame, function()
        Search:HandleEscape(true)
    end, function()
        -- Always Show eats ESC only while EasyFind state is dismissable
        -- (open menus, visible results, text, quick filter). A bare
        -- persistent bar must let ESC reach the game.
        if ns.GetVisibilityMode() ~= ns.VISIBILITY_ALWAYS then return true end
        return Search:HasDismissableEscState()
    end)
    if searchFrame.filterDropdown then
        searchFrame.filterDropdown:HookScript("OnShow", Utils.RefreshEscArm)
        searchFrame.filterDropdown:HookScript("OnHide", Utils.RefreshEscArm)
    end


    -- Tab confirms autocomplete suggestion only. Toolbar nav (clear /
    -- filter buttons) is handled by Left/Right and Alt+H/Alt+L
    -- elsewhere; routing Tab into it stomped the autocomplete confirm.

    -- Plain drag moves the bar (no modifier required). Lock Position
    -- in Options disables movement entirely. The editbox area uses
    -- manual movement detection above so a click can still focus it.
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if EasyFind.db.lockPosition then return end
        self:StartMoving()
        StartDragRefresh()
    end)
    searchFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
        StopDragRefresh()
    end)

    self:UpdateScale()
    self:UpdateOpacity()

    -- Smart Show: invisible hover zone that triggers show/hide
    local hoverZone = CreateFrame("Frame", "EasyFindHoverZone", UIParent)
    hoverZone:SetFrameStrata("LOW")
    hoverZone:SetFrameLevel(searchFrame:GetFrameLevel() - 1)
    hoverZone:EnableMouse(true)
    hoverZone:SetSize(340, 76)  -- larger than the search bar to catch the mouse nearby
    hoverZone:SetPoint("CENTER", searchFrame, "CENTER", 0, 0)
    hoverZone:Hide()
    searchFrame.hoverZone = hoverZone

    local smartShowVisible = false
    local smartShowTimer = nil

    local function SmartShowFadeIn()
        if smartShowTimer then smartShowTimer:Cancel(); smartShowTimer = nil end
        if EasyFind.db.visible == false then return end
        if not smartShowVisible then
            smartShowVisible = true
            UIFrameFadeIn(searchFrame, 0.15, searchFrame:GetAlpha(), 1.0)
            searchFrame:Show()
        end
    end

    local function SmartShowFadeOut()
        if EasyFind.db.visible == false then return end
        if searchFrame.editBox:HasFocus() then return end
        if resultsFrame and resultsFrame:IsShown() then return end
        -- Don't hide while the player is actively resizing the bar
        if searchFrame.resizing then return end
        if smartShowTimer then smartShowTimer:Cancel() end
        smartShowTimer = C_Timer.NewTimer(0.4, function()
            smartShowTimer = nil
            -- Re-check conditions after the delay. Smart Show might have
            -- been disabled while the timer was pending (e.g., unchecked
            -- from the tutorial or options panel mid-hover-out) in which
            -- case we must not fade the bar out.
            if not EasyFind.db.smartShow then return end
            if searchFrame.editBox:HasFocus() then return end
            if resultsFrame and resultsFrame:IsShown() then return end
            if searchFrame.resizing then return end
            if hoverZone:IsMouseOver() or searchFrame:IsMouseOver() then return end
            smartShowVisible = false
            UIFrameFadeOut(searchFrame, 0.25, searchFrame:GetAlpha(), 0)
            Utils.SafeAfter(0.25, function()
                if not smartShowVisible and EasyFind.db.smartShow then
                    searchFrame:SetAlpha(0)
                end
            end)
        end)
    end

    hoverZone:SetScript("OnEnter", SmartShowFadeIn)
    hoverZone:SetScript("OnLeave", SmartShowFadeOut)
    searchFrame:HookScript("OnEnter", function()
        if EasyFind.db.smartShow then SmartShowFadeIn() end
    end)
    searchFrame:HookScript("OnLeave", function()
        if EasyFind.db.smartShow then SmartShowFadeOut() end
    end)

    searchFrame.smartShowFadeIn = SmartShowFadeIn
    searchFrame.smartShowFadeOut = SmartShowFadeOut
    searchFrame.smartShowVisible = function() return smartShowVisible end
    searchFrame.setSmartShowVisible = function(val) smartShowVisible = val end
    searchFrame.cancelSmartShowTimer = function()
        if smartShowTimer then
            smartShowTimer:Cancel()
            smartShowTimer = nil
        end
    end

    self:CreateUIFilterDropdown(filterBtn, searchFrame, editBox)
    -- Built after the filter button exists: the apps button anchors to its
    -- left edge, so it cannot be placed before there is one.
    if ns.AppsMenu then ns.AppsMenu:Create(searchFrame, filterBtn) end

    -- Hover-reveal for the configurable bar controls: an unchecked "Show
    -- filter button" keeps the button clickable at alpha 0 until its spot
    -- is hovered, focused, or its menu is open (same idea as hover-show).
    local filterDropdown = _G["EasyFindUIFilterDropdown"]
    Utils.InstallBarControlReveal(filterBtn,
        function() return EasyFind.db.showFilterButton ~= false end,
        function() return filterDropdown and filterDropdown:IsShown() end)
    if filterDropdown then
        filterDropdown:HookScript("OnShow", filterBtn.RefreshReveal)
        filterDropdown:HookScript("OnHide", filterBtn.RefreshReveal)
    end

    -- Click-away dismissal listens permanently, not per-OnShow: any show
    -- path that finds the frame technically already Shown (smart show
    -- keeps it shown at alpha 0) skips OnShow entirely, and a bar shown
    -- that way could never be dismissed. The handler's guards below make
    -- the always-on registration free when hidden or not in auto-hide.
    searchFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
    searchFrame:HookScript("OnHide", function()
        Search:HideQuickFilterSuggestions()
    end)
    searchFrame:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not self:IsShown() then return end
        if not EasyFind.db.autoHide then return end
        -- Minimap button click is in flight: skip autoHide so the button's
        -- own OnClick toggle is the only state change. Set in OnMouseDown
        -- of the minimap button (Core/Main.lua), cleared in OnMouseUp.
        if EasyFind._minimapClickActive then return end
        -- An inline setting-dropdown popup is open. It lives on UIParent
        -- as a separate top-level frame, so a click inside it is "outside"
        -- our search bar and would otherwise close the bar before the
        -- popup's OnClick callback runs.
        if EasyFind._inlineDropdownMenuOpen then return end
        -- Grace window after a popup row was selected. Some setting
        -- writes dispatch follow-up events (CVAR updates etc.) that
        -- reach this handler with the popup already hidden.
        if EasyFind._popupGraceUntil and GetTime() < EasyFind._popupGraceUntil then return end
        -- WoW's actual click-target focus stack. Use this rather than
        -- IsMouseOver: GetMouseFoci is what the click dispatch itself
        -- uses, so a frame in this list is guaranteed to receive the
        -- click. Catches the minimap button (and any other "click target
        -- that should NOT close the bar") even if our OnMouseDown flag
        -- races against this event handler.
        -- Data broker launchers count the same way. Their buttons belong to
        -- whichever display hosts them, so we cannot name them up front or
        -- hook them early enough to win the flag race -- the launcher records
        -- each button it is clicked through instead, and this check covers it
        -- from then on. Without it the bar closes here on mouse-DOWN and the
        -- launcher's mouse-UP handler reopens it, so it blinks instead of
        -- toggling shut.
        local mmBtn = _G["EasyFindMinimapButton"]
        local launchers = ns.brokerLauncherButtons
        local function IsLauncherTarget(frame)
            if not frame then return false end
            if mmBtn and frame == mmBtn then return true end
            return (launchers and launchers[frame]) and true or false
        end
        if GetMouseFoci then
            local foci = GetMouseFoci()
            if foci then
                for i = 1, #foci do
                    if IsLauncherTarget(foci[i]) then return end
                end
            end
        elseif GetMouseFocus and IsLauncherTarget(GetMouseFocus()) then
            return
        end
        if self:IsMouseOver() then return end
        if Utils.IsFrameVisiblyMouseOver(resultsFrame) then return end
        if OptionsSurface:IsOptionsSurfaceMouseOver() then return end
        -- Any active cursor menu and its flyout cascade (right-click menu, the
        -- Send-link channel submenu) count as inside. Those submenus are
        -- separate pooled frames on UIParent, not children of the pin popup.
        if Utils.IsCursorMenuMouseOver() then return end
        if activeKeybindBtn then return end
        -- The filter dropdown and every popup it spawns; IsMouseInFilterChain
        -- owns that union via dropdown.guardFrames.
        if Filters.IsMouseInFilterChain() then return end
        -- Every floating EasyFind window (apps menu, pin popup, copy box,
        -- wizard, ...) lives in the shared click-guard registry.
        if Utils.IsClickGuardMouseOver() then return end
        Search:Hide()
    end)

end

-- Top-level filter list, alphabetical. Collections stays compact via a
-- flyout: the row carries a yellow expand arrow on the right; hovering
-- it opens a popup of sub-filter checkboxes (Mounts/Toys/Pets/Outfits/
-- Appearance Sets). Each sub-filter still owns its own filters[key]
-- value; only the rendering changed.
function Search:Focus()
    if not searchFrame or not searchFrame:IsShown() then return end
    if inCombat then return end
    -- Toggle: if already focused, unfocus; otherwise focus
    if searchFrame.editBox:HasFocus() then
        searchFrame.editBox:ClearFocus()
    else
        -- Delay by one frame so the keybind key-press doesn't get typed
        Utils.SafeAfter(0, function()
            if searchFrame and searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function Search:Show(andFocus)
    if not searchFrame then return end
    if inCombat then return end
    local wasShown = searchFrame:IsShown()
    if not wasShown and Filters:GetQuickFilter() then
        self:ClearQuickFilter(false)
        if searchFrame.editBox then
            if searchFrame.editBox.ResetPendingSearch then searchFrame.editBox:ResetPendingSearch() end
            searchFrame.editBox:SetText("")
            if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
        end
    end
    searchFrame:Show()
    if not (EasyFind.db.smartShow and not EasyFind.db.autoHide) then
        searchFrame:SetAlpha(1.0)
    end
    EasyFind.db.visible = true
    if EasyFind.db.smartShow and not EasyFind.db.autoHide then
        searchFrame.hoverZone:Show()
        searchFrame.smartShowFadeIn()
        Utils.SafeAfter(1.5, function()
            if EasyFind.db.smartShow then
                searchFrame.smartShowFadeOut()
            end
        end)
    end
    if andFocus or EasyFind.db.autoHide then
        Utils.SafeAfter(0, function()
            if searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function Search:Hide()
    if not searchFrame then return end
    if ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end
    -- Close any open filter dropdown / flyouts so they don't linger
    -- on screen after the bar is toggled off via keybind.
    self:CloseFilterDropdownIfOpen()
    -- SafeCallMethod: the frame ancestors secure result rows, so Hide is a
    -- protected operation in combat and must degrade quietly.
    Utils.SafeCallMethod(searchFrame, "Hide")
    searchFrame.setSmartShowVisible(false)
    self:HideResults()
    searchFrame.editBox:ClearFocus()
    searchFrame.editBox.placeholder:SetShown(searchFrame.editBox:GetText() == "")
    EasyFind.db.visible = false

    -- Bar is toggled off: the hover zone must not linger and eat clicks.
    searchFrame.hoverZone:Hide()
end

-- Unified ESC handler: collapses every menu state we care about into one
-- decision tree. Called from editBox:OnEscapePressed (focused path) and
-- the AttachEscClose override bind (unfocused path) so ESC behaves the
-- same regardless of which frame currently holds keyboard input.
--   Filter dropdown / flyouts open: close them all + refocus editbox.
--   Editbox has text:               clear text + refocus.
--   Otherwise:                      hide the search bar.
-- fromUnfocused: ESC arrived via the override bind, i.e. the player was
-- NOT typing. That path closes popups or the window and must never clear
-- text or grant editbox focus; the staged clear-and-refocus behavior
-- below belongs to the focused flow only.
function Search:HandleEscape(fromUnfocused)
    -- Put a carried catalog item down FIRST, and before the shown-check: our
    -- ESCAPE override displaces the engine's own "ESC clears the cursor", so
    -- without this the item rides the cursor through every ESC press and the
    -- next click anywhere fires its drop (popping the chat editbox open) --
    -- which is what read as "ESC is broken" after clicking a catalog row.
    if ns.ClearCarriedItemLink and ns.ClearCarriedItemLink() then return true end
    if not searchFrame or not searchFrame:IsShown() then return false end
    local editBox = searchFrame.editBox
    -- ESC always aborts any active nav-repeat cascade. We do this
    -- before the cleanup below, because the text-clear path calls
    -- ResetPendingSearch -> ResetSearchHistory which sets
    -- historyIndex=0. If the ticker were still alive after that
    -- (HideResults from OnSearchTextChanged("", true) deliberately
    -- preserves the ticker when a nav-repeat key is held, to keep the
    -- async heavy-search refresh case working), its next tick would
    -- NavigateSearchHistory(1) from index 0 and walk through all
    -- history entries again, infinitely cycling. Stopping the ticker
    -- here also lets us release the alt-nav MaxLetters lock so the
    -- editbox accepts typed input again after ESC.
    if searchFrame.StopKeyRepeat then searchFrame.StopKeyRepeat() end
    if editBox and editBox._altNavMaxLettersSaved then
        editBox:SetMaxLetters(editBox._altNavMaxLettersSaved)
        editBox._altNavMaxLettersSaved = nil
    end
    local function Refocus()
        if not editBox then return end
        -- Three SetFocus attempts spread across timing windows: synchronous
        -- (works when dropdown:OnHide already ran), next-frame (handles the
        -- normal Hide cascade), and short-deferred (handles editbox state
        -- machine quirks after a Hide chain). Whichever lands first wins;
        -- subsequent SetFocus on an already-focused editbox is a no-op.
        editBox.blockFocus = nil
        editBox:SetFocus()
        Utils.SafeAfter(0, function()
            if not searchFrame or not searchFrame:IsShown() or not editBox then return end
            if editBox:HasFocus() then return end
            editBox.blockFocus = nil
            editBox:SetFocus()
        end)
        Utils.SafeAfter(0.05, function()
            if not searchFrame or not searchFrame:IsShown() or not editBox then return end
            if editBox:HasFocus() then return end
            editBox.blockFocus = nil
            editBox:SetFocus()
        end)
    end
    self._escClosingMenus = true
    -- One layer per ESC press: the deepest open filter popup first, then
    -- its parent, then the dropdown itself; only then does ESC move on to
    -- text-clear / bar-hide. CloseTopFilterLayer owns the depth order.
    local closedAny = Filters.CloseTopFilterLayer and Filters.CloseTopFilterLayer() or false
    -- The apps dropdown is its own single layer, closed only when no
    -- filter layer consumed this press.
    local escSearchFrame = self:GetSearchFrame()
    if not closedAny and escSearchFrame and escSearchFrame.appsDropdown
       and escSearchFrame.appsDropdown:IsShown() then
        escSearchFrame.appsDropdown:Hide()
        closedAny = true
    end
    self._escClosingMenus = nil
    if closedAny then
        if not fromUnfocused then Refocus() end
        return true
    end
    -- Pending Apply-flagged settings: the popup must preempt the
    -- text-clear and panel-close branches so Cancel preserves the
    -- exact pre-ESC state (text, scroll, pending change). The helper
    -- also lifts the popup above our results panel strata.
    if self:ShowUnappliedSettingsPopup() then return true end
    if fromUnfocused then
        if ns.GetVisibilityMode() == ns.VISIBILITY_ALWAYS then
            -- Fully persistent: only reachable while dismissable state
            -- exists (the arming predicate). Clear it; the bar stays, and
            -- only the toggle paths (keybind, /ef toggle, minimap icon)
            -- ever hide it.
            if editBox and (editBox:GetText() ~= "" or Filters:GetQuickFilter()) then
                if editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
                editBox:SetText("")
                if editBox.placeholder then editBox.placeholder:Show() end
                self:ClearQuickFilter(false)
                self:HideQuickFilterSuggestions()
                self:OnSearchTextChanged("", true)
                return true
            end
            -- Nothing but the results panel left to close. Report whether it
            -- was actually up: claiming a dismissal that did not happen is
            -- what let the ESC override swallow every press.
            local hadResults = resultsFrame and resultsFrame:IsShown()
            Results:HideResults()
            return hadResults and true or false
        end
        self:Hide()
        -- Hide is protected while secure rows are parented here, so it can
        -- degrade to a no-op; only claim the key if the bar really went away.
        return not searchFrame:IsShown()
    end
    if (editBox and editBox:GetText() ~= "") or Filters:GetQuickFilter() then
        if editBox and editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        if editBox then
            editBox:SetText("")
            if editBox.placeholder then editBox.placeholder:Show() end
        end
        self:ClearQuickFilter(false)
        self:HideQuickFilterSuggestions()
        Refocus()
        -- Programmatic SetText intentionally does not run the throttled
        -- search path. Rebuild immediately so stale typed results are
        -- replaced by pinned rows, or hidden when there are no pins.
        self:OnSearchTextChanged("", true)
        return true
    end
    if ns.GetVisibilityMode() == ns.VISIBILITY_ALWAYS then
        -- Focused ESC on an empty box drops focus but keeps the bar.
        if editBox then editBox:ClearFocus() end
        return true
    end
    self:Hide()
    return not searchFrame:IsShown()
end

-- True while HandleEscape is driving the filter-dropdown close cascade,
-- so its OnHide handlers skip the keyboard handoff / ClearFocus paths.
function Search:IsEscClosingMenus()
    return self._escClosingMenus
end

-- Dev probe surface: key-capture state in one read.
function Search:GetKeyNavDebug()
    return {
        navKeyboard = navFrame and navFrame:IsKeyboardEnabled() or false,
        selectedIndex = selectedIndex,
        editBoxFocus = searchFrame and searchFrame.editBox
            and searchFrame.editBox:HasFocus() or false,
        blockFocus = (searchFrame and searchFrame.editBox
            and searchFrame.editBox.blockFocus) and true or false,
    }
end

-- True while EasyFind has state ESC can dismiss. This is the ESC-override
-- arming predicate for Always Show; Utils.RefreshEscArm re-evaluates it
-- when menus or results open and close.
function Search:HasDismissableEscState()
    -- A catalog item carried on the cursor is dismissable: ESC puts it down.
    if ns.HasCarriedItemLink and ns.HasCarriedItemLink() then return true end
    if searchFrame and searchFrame.filterDropdown
        and searchFrame.filterDropdown:IsShown() then
        return true
    end
    if resultsFrame and resultsFrame:IsShown() then return true end
    local editBox = searchFrame and searchFrame.editBox
    if editBox and editBox:GetText() ~= "" then return true end
    if Filters.GetQuickFilter and Filters:GetQuickFilter() then return true end
    return false
end

function Search:ExpandFactionHeader(headerName)
    local headerNameLower = slower(headerName)
    local i, data = Utils.FindFactionByPredicate(function(d)
        return d.isHeader and d.name and slower(d.name) == headerNameLower
    end)
    if not i then return false end
    if not data.isHeaderExpanded then
        C_Reputation.ExpandFactionHeader(i)
    end
    return true
end

function Search:Toggle()
    if not searchFrame then return end
    if inCombat then
        -- Show/Hide are protected here (secure rows are descendants).
        -- The kept-shown Always bar toggles VISUALLY via alpha; the
        -- shield stays for the fight, so its rect remains inert. Other
        -- modes stay blocked in combat, as before.
        if searchFrame:IsShown() and searchFrame.combatShield
            and searchFrame.combatShield:IsShown() then
            combatToggledOff = not combatToggledOff
            ApplyAlwaysBarAlpha()
        end
        return
    end
    local tuckedBySmartShow = EasyFind.db.autoHide and (searchFrame:GetAlpha() or 1) <= 0.01
    if searchFrame:IsShown() and EasyFind.db.visible ~= false and not tuckedBySmartShow then
        self:Hide()
    else
        self:Show(false)
    end
end

function Search:ToggleFocus()
    if not searchFrame then return end
    if inCombat then return end
    local tuckedBySmartShow = EasyFind.db.autoHide and (searchFrame:GetAlpha() or 1) <= 0.01
    if searchFrame:IsShown() and EasyFind.db.visible ~= false and not tuckedBySmartShow then
        self:Hide()
    else
        self:Show(false)
        Utils.SafeAfter(0, function()
            if searchFrame and searchFrame:IsShown() then
                searchFrame.editBox.blockFocus = nil
                searchFrame.editBox:SetFocus()
            end
        end)
    end
end

function Search:UpdateScale()
    local scale = EasyFind.db.uiSearchScale or 1.0
    if searchFrame then
        searchFrame:SetScale(scale)
    end
    -- containerFrame holds the rounded-rect border + fill and is a SIBLING of
    -- searchFrame (not a child, so its textures draw behind the bar content),
    -- so it must be scaled too -- otherwise its corners keep their unscaled
    -- radius while it stretches to match the scaled bar.
    if containerFrame then
        containerFrame:SetScale(scale)
    end
    self:UpdateResultsScale()
end

function Search:UpdateResultsScale()
    if resultsFrame then
        resultsFrame:SetScale(EasyFind.db.uiResultsScale or 1.0)
        self:RefreshResults()
    end
end

function Search:UpdateWidth()
    if searchFrame then
        local w = 250 * (EasyFind.db.uiSearchWidth or 1.0)
        searchFrame:SetWidth(w)
    end
    self:UpdateResultsWidth()
end

function Search:UpdateResultsWidth()
    if resultsFrame then
        local w = EasyFind.db.uiResultsWidth
        if w and w > 1 then
            resultsFrame:SetWidth(w)
        end
    end
end

function Search:RefreshResults()
    local savedIndex = selectedIndex
    local savedToggle = toggleFocused
    -- Bypass the render-skip cache: setting toggles, slider writes, and
    -- dropdown cycles keep the same entry.data reference, so the row-by-row
    -- layout pass would be skipped and the on-screen checkbox/value/slider
    -- would stay stale until the result list rebuilt from scratch.
    if not Results:RefreshShownResults(true) then return end
    if savedIndex > 0 then
        selectedIndex = savedIndex
        toggleFocused = savedToggle
        self:UpdateSelectionHighlight()
    end
    -- Re-apply the hover action hint. Re-render rewrote pathSubtext
    -- back to GetFlatSubtext, so the row the cursor is still over
    -- would otherwise revert to the unhovered subtext after a click.
    for i = 1, #resultButtons do
        local row = resultButtons[i]
        if Utils.IsFrameVisiblyMouseOver(row) then
            Handlers:ApplyActionHint(row)
            break
        end
    end
end

-- Re-run the search pipeline against the current editbox text. Use this when a
-- setting flips the structure of the result list (flat vs hierarchical), since
-- RefreshResults only re-renders the cached list.
function Search:RebuildOpenResults()
    if not searchFrame or not searchFrame.editBox then return end
    if not resultsFrame or not resultsFrame:IsShown() then return end
    local text = searchFrame.editBox:GetText()
    if text and text ~= "" then
        self:OnSearchTextChanged(text)
    else
        Results:ShowEmptyQueryView()
    end
end

function Search:UpdateOpacity()
    if not searchFrame then return end
    local alpha = ns.GetSearchWindowAlpha()
    if containerFrame then
        self:ApplySearchWindowFill(containerFrame)
        ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
    end
    local filterDropdown = _G["EasyFindUIFilterDropdown"]
    if filterDropdown then
        ns.ApplyMenuOpacity(filterDropdown)
    end
end

function Search:UpdateSearchBarHeight()
    self:UpdateFontSize()
end

-- Re-run the hover-reveal decision for both configurable bar controls,
-- called when either "Show ... button" setting flips in options.
function Search:RefreshBarControlReveal()
    if not searchFrame then return end
    if searchFrame.filterBtn and searchFrame.filterBtn.RefreshReveal then
        searchFrame.filterBtn.RefreshReveal()
    end
    if searchFrame.appsBtn and searchFrame.appsBtn.RefreshReveal then
        searchFrame.appsBtn.RefreshReveal()
    end
end

-- forceShow=false is the programmatic-refresh mode (settings reset):
-- visibility settings are re-applied without pulling a closed bar onto
-- the screen. Every other caller keeps the interactive default, where
-- flipping the visibility mode previews the bar.
-- Live re-apply of the window border setting: the bar's container plus
-- every filter-menu surface (the dropdown and all registered guard
-- popups; frames without a rounded-rect border no-op).
function Search:UpdateWindowBorders()
    local shown = EasyFind.db.windowBorder ~= false
    if containerFrame then ns.SetRoundedRectRingShown(containerFrame, shown) end
    local dropdown = searchFrame and searchFrame.filterDropdown
    if dropdown then
        ns.SetRoundedRectRingShown(dropdown, shown)
        if dropdown.guardFrames then
            for i = 1, #dropdown.guardFrames do
                ns.SetRoundedRectRingShown(dropdown.guardFrames[i], shown)
            end
        end
    end
end

function Search:UpdateSmartShow(forceShow)
    if not searchFrame then return end
    if forceShow == nil then forceShow = true end
    local enabled = EasyFind.db.smartShow
    if enabled then
        -- Smart Show owns the bar; it stays enabled and starts shown, then
        -- tucks away on its own if the mouse isn't near it.
        EasyFind.db.visible = true
        searchFrame.hoverZone:Show()
        if not inCombat and (forceShow or searchFrame:IsShown()) then
            searchFrame:Show()
            searchFrame.smartShowFadeIn()
            Utils.SafeAfter(1.5, function()
                if EasyFind.db.smartShow then searchFrame.smartShowFadeOut() end
            end)
        end
    else
        -- Disable smart show: hide hover zone, cancel any pending fade-out
        -- timer (the player may be mid-hover-out when they flip the toggle),
        -- and restore normal opacity.
        searchFrame.hoverZone:Hide()
        if searchFrame.cancelSmartShowTimer then searchFrame.cancelSmartShowTimer() end
        UIFrameFadeRemoveFrame(searchFrame)
        searchFrame.setSmartShowVisible(true)
        searchFrame:SetAlpha(1.0)
        if inCombat then return end
        -- Reconcile the shown state from scratch. Coming from Hover Show the
        -- frame is already Shown (at alpha 0), so a plain Show() would not
        -- re-fire OnShow, and Auto-Hide registers its GLOBAL_MOUSE_DOWN
        -- click-away dismissal only in OnShow. Without the Hide first, a
        -- reset that flips Hover Show to Auto-Hide leaves the bar fully
        -- visible and undismissable. Hiding first makes OnShow fire cleanly.
        local wasShown = searchFrame:IsShown()
        searchFrame:Hide()
        if EasyFind.db.visible ~= false and (forceShow or wasShown) then
            searchFrame:Show()
        end
    end
end

function Search:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        local point, relPoint, x, y = self:GetDefaultSearchBarPoint()
        searchFrame:SetPoint(point, UIParent, relPoint, x, y)
        EasyFind.db.uiSearchPosition = nil
    end
end

function Search:ResetPositionAndSize()
    if EasyFind and EasyFind.db then
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.uiSearchScale = 1.0
        EasyFind.db.uiSearchWidth = 1.54
        EasyFind.db.uiSearchBarHeight = ns.SEARCHBAR_HEIGHT
        EasyFind.db.fontSize = DEFAULT_FONT_SIZE
        EasyFind.db.uiResultsScale = 1.0
        EasyFind.db.uiResultsWidth = 350
        EasyFind.db.uiResultsRows = 6
    end
    self:ResetPosition()
    self:UpdateScale()
    self:UpdateWidth()
    self:UpdateSearchBarHeight()
    self:RefreshResults()
end

function Search:UpdateFontSize()
    if not searchFrame then return end

    if ns.RegisterAddonFontsIn then ns.RegisterAddonFontsIn(searchFrame) end

    Search:ScaleFont(searchFrame.editBox, ns.SEARCHBAR_FONT)
    Search:ScaleFont(searchFrame.editBox.placeholder, ns.SEARCHBAR_FONT)

    local barH = Search:GetSearchBarHeight()
    local contentSz = barH * ns.SEARCHBAR_FILL
    local iconSz = contentSz * ns.SEARCHBAR_ICON_SCALE
    searchFrame:SetHeight(barH)
    searchFrame.editBox:SetHeight(contentSz)
    searchFrame.searchIcon:SetSize(iconSz, iconSz)
    if searchFrame.modeBtn then
        searchFrame.modeBtn:SetWidth(barH)
    end
    if searchFrame.filterBtn then
        searchFrame.filterBtn:SetWidth(barH)
    end
    -- The apps button is a square like the filter button; keep it square as the
    -- bar height changes, or it drifts out of the right-hand cluster on rescale.
    if searchFrame.appsBtn then
        searchFrame.appsBtn:SetWidth(barH)
    end

    local theme = Results:GetActiveTheme()
    local WHITE8x8 = "Interface\\BUTTONS\\WHITE8x8"
    local alpha = ns.GetSearchWindowAlpha()
    -- Input text follows the theme's primary text color; the EditBox
    -- default is white, which vanishes on the light palettes. Shadow off
    -- on light fills (dark shadow under dark text reads as smearing).
    if searchFrame.editBox then
        searchFrame.editBox:SetTextColor(unpack(theme.leafColor))
        searchFrame.editBox:SetShadowColor(0, 0, 0, theme.lightTheme and 0 or 1)
        -- Placeholder ("Type to search...") sits between the fill and the
        -- main text color per theme, never a fixed neutral gray.
        if searchFrame.editBox.placeholder and theme.textFaint then
            searchFrame.editBox.placeholder:SetTextColor(theme.textFaint[1], theme.textFaint[2], theme.textFaint[3], 1)
        end
    end
    -- The quick-filter pill (@filter chip) follows the theme's control fill
    -- and the bar's scaled/custom font, so it rides this pass instead of
    -- keeping the previous theme's colors after a live flip.
    local quickFilterPill = searchFrame.quickFilterPill
    if quickFilterPill then
        -- One painter owns the pill's fill and label color (the same theme wash
        -- the options stepper buttons use); this pass only re-runs it so a live
        -- theme flip lands, and rescales the font.
        Filters:PaintQuickFilterPill(quickFilterPill, quickFilterPill:IsMouseOver())
        if quickFilterPill.text then
            Search:ScaleFont(quickFilterPill.text, "GameFontHighlightSmall")
        end
    end
    -- Chrome glyphs (spyglass, filter arrow) flip polarity with the theme;
    -- content icons (ability art, category icons) are never tinted. The
    -- arrow's ADD blend washes out on light fills, so it blends normally
    -- there.
    local glyph = theme.chromeGlyph
    if glyph then
        if searchFrame.searchIcon then
            searchFrame.searchIcon:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
        end
        local filterBtn = searchFrame.filterBtn
        if filterBtn and filterBtn.arrow then
            filterBtn.arrow:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
            filterBtn.arrow:SetBlendMode(theme.lightTheme and "BLEND" or "ADD")
        end
        -- Apps 3x3 dots track the same chrome-glyph color flip as the filter
        -- arrow, so they stay readable on light themes.
        if ns.AppsMenu and ns.AppsMenu.SetGlyphColor then
            ns.AppsMenu:SetGlyphColor(glyph[1], glyph[2], glyph[3], 1)
        end
        -- Toolbar focus ring (the circle around the filter button): gold
        -- ADD glow on dark themes; light themes tint it with their main
        -- text color and blend normally (ADD cannot darken a light fill).
        local tbTex = searchFrame.toolbarHighlight and searchFrame.toolbarHighlight.tex
        if tbTex then
            if theme.lightTheme then
                tbTex:SetBlendMode("BLEND")
                tbTex:SetVertexColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3], 0.35)
            else
                tbTex:SetBlendMode("ADD")
                tbTex:SetVertexColor(Utils.RGB(GOLD_COLOR, 0.5))
            end
        end
        -- Filter-button hover glow: the baked blue art reads wrong on light
        -- themes and vertex tint can only darken, never lighten, so light
        -- palettes swap it for a lightened fill disc instead.
        if filterBtn and filterBtn.btnBg and theme.searchBarRounded then
            if theme.lightTheme then
                local windowFill = ns.SEARCH_WINDOW_FILL_COLOR
                filterBtn.btnBg:SetTexture("Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle")
                filterBtn.btnBg:SetVertexColor(
                    mmin(1, windowFill[1] * 1.12),
                    mmin(1, windowFill[2] * 1.12),
                    mmin(1, windowFill[3] * 1.12), 0.95)
            else
                filterBtn.btnBg:SetTexture("Interface\\AddOns\\EasyFind\\textures\\filter-glow")
                filterBtn.btnBg:SetVertexColor(1, 1, 1, 1)
            end
        end
    end
    if theme.searchBarRounded then
        searchFrame:SetBackdrop(nil)
        if containerFrame then
            ns.SetRoundedRectBarHeight(containerFrame, barH)
            self:ApplySearchWindowFill(containerFrame)
            ns.SetRoundedRectBorderBgAlpha(containerFrame, alpha)
            -- If results are open, the divider stays at the bar's
            -- new bottom (= barH).
            if resultsFrame and resultsFrame:IsShown() then
                ns.SetRoundedRectDivider(containerFrame, barH, true)
            end
        end
    else
        searchFrame:SetBackdrop({
            bgFile = WHITE8x8,
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 20,
            insets = { left = 5, right = 5, top = 5, bottom = 5 }
        })
        searchFrame:SetBackdropColor(Utils.RGB(ns.SEARCH_WINDOW_FILL_COLOR, alpha))
    end

    for i = 1, #resultButtons do
        Results:ApplyResultRowFonts(resultButtons[i], theme)
    end

    -- Re-layout visible results with new row heights
    Results:RefreshShownResults()
end
