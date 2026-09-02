local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils
local Calculator = ns.Calculator
local History = ns.SearchHistory
local L = ns.L
local UIPins = ns.UIPins
local GOLD_COLOR = ns.GOLD_COLOR

local ipairs = Utils.ipairs
local mmax, mfloor = math.max, math.floor
local PORTRAIT_ALPHA_MASK = ns.PORTRAIT_ALPHA_MASK
local wipe = wipe
local StaticPopup_Visible = StaticPopup_Visible
local StaticPopup_Show = StaticPopup_Show

local MAX_BUTTON_POOL = 100
local GetAllPins = UIPins.GetAll
local pinnedOnlyEntries = {}
-- Name of the row button ENTER is currently override-bound to (nil = no
-- binding). Binding writes are dedup'd against it: redundant writes near
-- the combat boundary put Blizzard's key re-attach pass on EasyFind's
-- execution and detonate protected bar updates (measured autopsy:
-- PetActionBar:SetShownBase blocked 0.3s after a no-op
-- ClearOverrideBindings from this file).
local navEnterBound

local function ResultsFrame()
    return Search:GetResultsFrame()
end

local function ResultsShownForSweep()
    local rf = ResultsFrame()
    return rf and rf:IsShown() or false
end

local function TrimAfterUISearch()
    if ns.Database and ns.Database.TrimSearchMemory then
        ns.Database:TrimSearchMemory()
    end
    if ns.MapSearch and ns.MapSearch.TrimSearchMemory then
        ns.MapSearch:TrimSearchMemory()
    end
end

local function CollapsedNodes()
    return Results._collapsedNodes
end

-- Advance a dropdown setting to its next value inline. Returns true if
-- we found options and applied a new value; false if the variable
-- wasn't enumerable (caller should fall back to opening the panel).
-- direction: +1 next (default), -1 prev. Wraps around at either end.
function Results:CycleSettingDropdown(data, direction)
    if not data or not data.settingVariable then return false end
    -- Checkbox+dropdown composites toggle via settingVariable (the cb)
    -- while the dropdown half reads and writes its own variable.
    local var = data.dropdownVariable or data.settingVariable
    local opts = data.settingOptions
    if not opts and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
        opts = ns.BlizzOptionsSearch.GetOptionsForVariable(var)
        if opts then data.settingOptions = opts end
    end
    if not opts or #opts == 0 then return false end

    local curVal = Rows:ReadSettingVariable(var)

    local curIdx
    for i = 1, #opts do
        local v = opts[i].value
        if v == curVal or tostring(v) == tostring(curVal) then
            curIdx = i
            break
        end
    end
    local n = #opts
    local step = direction or 1
    local nextIdx = ((curIdx or 1) - 1 + step) % n + 1
    local nextVal = opts[nextIdx].value

    if not Rows:WriteSettingVariable(var, nextVal) then return false end

    Search:RefreshResults()
    if Search:GetSearchFrame() and Search:GetSearchFrame().editBox
       and not (Search:GetNavFrame() and Search:GetNavFrame():IsKeyboardEnabled()) then
        Search:GetSearchFrame().editBox.blockFocus = nil
        Search:GetSearchFrame().editBox:SetFocus()
    end
    return true
end

function Results:SetSettingDropdownValue(data, value)
    if not data or not data.settingVariable then return false end
    if not Rows:WriteSettingVariable(data.dropdownVariable or data.settingVariable, value) then return false end
    Search:RefreshResults()
    if Search:GetSearchFrame() and Search:GetSearchFrame().editBox
       and not (Search:GetNavFrame() and Search:GetNavFrame():IsKeyboardEnabled()) then
        Search:GetSearchFrame().editBox.blockFocus = nil
        Search:GetSearchFrame().editBox:SetFocus()
    end
    return true
end

-- Open the Settings panel to a setting (slider/dropdown/etc.) without
-- closing the EasyFind search results. Mirrors ToggleSettingCheckbox's
-- "stay open" behavior so users can edit one setting in the panel and
-- still see / re-toggle others in the result list.
function Results:OpenSettingNoClose(data)
    if not data or not data.steps or not data.steps[1] then return end
    if ns.BlizzOptionsSearch then
        ns.BlizzOptionsSearch:HandleStep(data.steps[1])
    end
    -- Refresh in case the panel itself altered values that affect the
    -- displayed amountText (e.g. dropdown selection updated).
    Search:RefreshResults()
end

-- Close the filter dropdown and any nested sub-popups in one call.
-- Returns true if anything was actually visible (so callers can decide
-- whether to consume the ESC keystroke vs fall through to text-clear /
-- window-close behavior). Walks dropdown.guardFrames so ESC works the
-- same regardless of how deep the user has navigated into sub-filters.
-- Every popup frame the filter dropdown can spawn. Named globals so a
-- brute-force walk catches popups not registered in dropdownGuardFrames
-- (classPopup is parented to UIParent without ever being added to the
-- guard list, etc), and so the close path doesn't depend on the cascade
-- chain firing in the right order.
local FILTER_POPUP_NAMES = {
    "EasyFindAsClassPopup",
    "EasyFindAsOptionsPopup",
    "EasyFindLootOptionsPopup",
    "EasyFindMountOptionsPopup",
    "EasyFindMountSourcePopup",
    "EasyFindDiffPopup",
    "EasyFindSpecPopup",
    "EasyFindSpecFlyout",
    "EasyFindSpecSubFlyout",
}

function Results:CloseFilterDropdownIfOpen()
    if not Search:GetSearchFrame() then return false end
    local closedAny = Utils.HideCursorMenus and Utils.HideCursorMenus() or false
    local dropdown = Search:GetSearchFrame().filterDropdown
    if not dropdown then return closedAny end
    -- Brute-force hide every named popup. classPopup is never registered
    -- in guardFrames; relying on the cascade-via-OnHide chain misses it
    -- when the parent popup is already hidden. Hide by name is idempotent
    -- and order-independent.
    for i = 1, #FILTER_POPUP_NAMES do
        local f = _G[FILTER_POPUP_NAMES[i]]
        if f and f.IsShown and f:IsShown() then
            f:Hide()
            closedAny = true
        end
    end
    -- Collections / Options flyout popups are unnamed; reach them via the
    -- dropdown.flyoutPopups registry.
    if dropdown.flyoutPopups then
        for i = 1, #dropdown.flyoutPopups do
            local popup = dropdown.flyoutPopups[i]
            if popup and popup:IsShown() then
                popup:Hide()
                closedAny = true
            end
        end
    end
    if dropdown.guardFrames then
        for i = 1, #dropdown.guardFrames do
            local guard = dropdown.guardFrames[i]
            if guard and guard:IsShown() then
                guard:Hide()
                closedAny = true
            end
        end
    end
    if dropdown:IsShown() then
        dropdown:Hide()
        closedAny = true
    end
    return closedAny
end

-- Explicit user-close request: shows the unapplied-changes popup if
-- there are pending Apply-flagged settings, otherwise hides directly.
-- Used by the click-outside-to-close watcher and ESC handlers; the
-- internal HideResults callers (no-results refresh, etc.) skip it.
-- StaticPopup_Show lands the popup in StaticPopup1..4 depending on
-- which slots are busy. Walk all four to find the one we just opened.
local function FindPopupSlot(popupName)
    for i = 1, 4 do
        local p = _G["StaticPopup" .. i]
        if p and p:IsShown() and p.which == popupName then return p end
    end
    return nil
end

-- The default DIALOG strata renders behind our FULLSCREEN_DIALOG
-- results panel. Lift the popup to TOOLTIP for the duration of its
-- visibility, then restore the original strata on hide so we don't
-- pollute other StaticPopup1 uses elsewhere in the Search.
local function LiftPopupStrata(popup)
    if not popup or popup._easyFindStrataLifted then return end
    popup._easyFindStrataLifted = true
    popup._easyFindOriginalStrata = popup:GetFrameStrata()
    popup:SetFrameStrata("TOOLTIP")
    if not popup._easyFindStrataRestoreHooked then
        popup._easyFindStrataRestoreHooked = true
        popup:HookScript("OnHide", function(self)
            if self._easyFindStrataLifted then
                if self._easyFindOriginalStrata then
                    self:SetFrameStrata(self._easyFindOriginalStrata)
                end
                self._easyFindStrataLifted = nil
                self._easyFindOriginalStrata = nil
            end
        end)
    end
end

function Results:FindPopupSlot(popupName)
    return FindPopupSlot(popupName)
end

function Results:LiftPopupStrata(popup)
    return LiftPopupStrata(popup)
end
-- Show the unapplied-settings popup (if not already up) and lift its
-- strata above the results panel. Returns true if the popup is now
-- visible (so the caller can short-circuit its dismiss path).
function Results:ShowUnappliedSettingsPopup()
    if not (ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetPendingApplyCount
            and ns.BlizzOptionsSearch:GetPendingApplyCount() > 0) then
        return false
    end
    local already = StaticPopup_Visible
        and StaticPopup_Visible("EASYFIND_UNAPPLIED_SETTINGS")
    if not already and StaticPopup_Show then
        StaticPopup_Show("EASYFIND_UNAPPLIED_SETTINGS")
    end
    LiftPopupStrata(FindPopupSlot("EASYFIND_UNAPPLIED_SETTINGS"))
    return true
end

-- The ONE owner of "what does an empty query show": an active quick
-- filter's view (the @icons grid, a category list) or, with no filter,
-- the pinned items. Every caller that reacts to an emptied/refocused box
-- or a pin/blacklist action routes here; calling ShowPinnedItems directly
-- stomps a live filter view (that exact bug killed the icon grid from
-- OnEditFocusGained).
function Results:ShowEmptyQueryView()
    if ns.Filters and ns.Filters.GetQuickFilter and ns.Filters:GetQuickFilter() then
        Search:OnSearchTextChanged("", true)
    else
        self:ShowPinnedItems()
    end
end

function Results:RequestHideResults()
    if ResultsFrame() and ResultsFrame():IsShown() and self:ShowUnappliedSettingsPopup() then
        return
    end
    self:HideResults()
end

function Results:HideResults()
    if not Search:GetSearchFrame() then return end
    Search:StopActiveKeybindCapture()
    self:ClearCalculatorCopyHighlight()
    self:ReleaseCalculatorCopyBox()
    if self.HideIconGrid then
        self:HideIconGrid()
        self:ReleaseIconGridMemory()
    end
    -- Don't kill an active nav-repeat ticker from inside HideResults.
    -- History:IsPreservingNavRepeat covers the synchronous
    -- NavigateSearchHistory window. The IsAltNavRepeatKey check covers the
    -- async case: a query provider can refresh results seconds after
    -- the synchronous window cleared the preserve flag, and without
    -- this extra guard the resulting HideResults would kill the cascade
    -- mid-history. Both checks together keep the ticker alive whenever any
    -- alt-nav (Alt+J/K) or arrow-nav (UP/DOWN) key is currently held.
    local searchFrame = Search:GetSearchFrame()
    local navRepeatActive = searchFrame.IsAltNavRepeatKey
        and searchFrame.IsAltNavRepeatKey()
    if searchFrame.StopKeyRepeat
       and not History:IsPreservingNavRepeat()
       and not navRepeatActive then
        searchFrame.StopKeyRepeat()
    end
    if Search:GetSearchFrame().ClearToolbarFocus then Search:GetSearchFrame().ClearToolbarFocus() end
    Search:ClearResultShortcutBindings()
    if not ResultsFrame() then return end
    -- SafeCallMethod: the results frame ancestors secure row buttons, so
    -- Hide is a protected operation in combat and must degrade quietly.
    Utils.SafeCallMethod(ResultsFrame(), "Hide")
    -- Collapse the combined container back to bar-only height: the
    -- two top anchors stay pinned to the bar, the bottom snaps back
    -- to the bar's BOTTOM. Without this the rounded-rect would still
    -- cover the (now empty) dropdown area below.
    if Search:GetContainerFrame() then
        Search:GetContainerFrame():ClearAllPoints()
        Search:GetContainerFrame():SetPoint("TOPLEFT",  Search:GetSearchFrame(), "TOPLEFT",  0, 0)
        Search:GetContainerFrame():SetPoint("TOPRIGHT", Search:GetSearchFrame(), "TOPRIGHT", 0, 0)
        Search:GetContainerFrame():SetPoint("BOTTOM",   Search:GetSearchFrame(), "BOTTOM",   0, 0)
        ns.SetRoundedRectDivider(Search:GetContainerFrame(), 0, false)
    end
    if ResultsFrame().pinSeparator then
        ResultsFrame().pinSeparator:Hide()
    end
    if ResultsFrame().categorySeps then
        for _, sep in ipairs(ResultsFrame().categorySeps) do sep:Hide() end
    end
    if ResultsFrame().truncIndicator then
        ResultsFrame().truncIndicator:Hide()
    end
    if ResultsFrame().truncSeparator then
        ResultsFrame().truncSeparator:Hide()
    end
    Results._cachedHierarchical = nil
    self._lastRenderSig = nil
    for i = 1, #Search:GetResultButtons() do
        local row = Search:GetResultButtons()[i]
        if row then
            row.data = nil
            row._efShortcutIndex = nil
            row._efShortcutBindingReady = nil
            row._efContentTop = nil
            row._efContentBottom = nil
            row:Hide()
            if row.shortcutGroup then row.shortcutGroup:Hide() end
            if row.icon then
                Icons.ClearRowIconLeafIDs(row.icon)
            end
        end
    end
    Search:SetSelectedIndex(0)
    Search:SetToggleFocused(false)
    self:UpdateSelectionHighlight(true, History:IsPreservingNavRepeat())

    if ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end

    -- Close boundary: the session's garbage stops being produced here, so
    -- the shared sweep claims it instead of letting it sit in the meter
    -- (mechanics and rationale in Utils.NoteSurfaceClosed).
    Utils.NoteSurfaceClosed("uiSearch", ResultsShownForSweep, TrimAfterUISearch)
end

function Results:ShowPinnedItems()
    if not ResultsFrame() then return end
    local pins = GetAllPins()
    if #pins == 0 then
        self:HideResults()
        return
    end

    wipe(CollapsedNodes())
    local entries = pinnedOnlyEntries
    local quickFilter = self:GetQuickFilter()
    local n = 0
    for _, pin in ipairs(pins) do
        if not quickFilter or self:QuickFilterAllowsData(pin, quickFilter) then
            n = n + 1
            local e = entries[n]
            if not e then
                e = {}
                entries[n] = e
            end
            e.name = pin.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isPinned = true
            e.isFlat = true
            e.data = pin
        end
    end
    if n == 0 then
        self:HideResults()
        return
    end
    for i = n + 1, #entries do
        entries[i] = nil
    end
    self:ShowHierarchicalResults(entries)
end

function Results:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    local shownResults = ResultsFrame()
    local first = Search:GetResultButtons()[1]
    if shownResults and shownResults:IsShown() and first and first:IsShown() and first.data then
        if Rows:ActivateSettingResult(first.data) then return end
        self:SelectResult(first.data)
    end
end

function Results:CountVisibleResults()
    local count = 0
    for i = 1, MAX_BUTTON_POOL do
        local row = Search:GetResultButtons()[i]
        if row and row:IsShown() then
            count = i
        else
            break
        end
    end
    return count
end

function Results:MoveSelection(delta, skipRefocus, keepRepeat)
    -- CountVisibleResults walks the button pool and trusts each row's
    -- :IsShown(), but child rows of a hidden ResultsFrame() still report
    -- shown, so a leftover row from a prior search would let Alt+J
    -- yank focus into nothing on an empty bar. Gate on the frame.
    if not ResultsFrame() or not ResultsFrame():IsShown() then return false end
    -- The icon grid owns the panel: every vertical-motion caller (DOWN/UP,
    -- Alt+J/K, PageUp/Down, held repeats) becomes a row move on the grid.
    if self.IsIconGridShown and self:IsIconGridShown() then
        return self:MoveIconGridFocus(0, delta)
    end
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return false end

    local oldIndex = Search:GetSelectedIndex()
    local newIndex = oldIndex + delta
    if EasyFind.db.uiResultsAbove then
        -- Above: exit to editbox past last result, clamp at first
        if newIndex > visibleCount then newIndex = 0
        elseif newIndex < 1 then newIndex = 1 end
    else
        -- Below: exit to editbox past first result, clamp at last
        if newIndex < 0 then newIndex = 0
        elseif newIndex > visibleCount then newIndex = visibleCount end
    end

    Search:SetSelectedIndex(newIndex)
    Search:SetToggleFocused(false)
    self:UpdateSelectionHighlight(skipRefocus, keepRepeat)
    return newIndex ~= oldIndex
end

function Results:JumpToStart()
    if self.IsIconGridNavActive and self:IsIconGridNavActive() then
        return self:JumpIconGridFocus(false)
    end
    if self:CountVisibleResults() > 0 then
        Search:SetSelectedIndex(1)
        Search:SetToggleFocused(false)
        self:UpdateSelectionHighlight()
    end
end

function Results:JumpToEnd()
    if self.IsIconGridNavActive and self:IsIconGridNavActive() then
        return self:JumpIconGridFocus(true)
    end
    local visibleCount = self:CountVisibleResults()
    if visibleCount > 0 then
        Search:SetSelectedIndex(visibleCount)
        Search:SetToggleFocused(false)
        self:UpdateSelectionHighlight()
    end
end

function Results:JumpToNextSection(direction)
    -- No sections on the icon grid; the closest jump is a page.
    if self.IsIconGridNavActive and self:IsIconGridNavActive() then
        return self:MoveIconGridFocus(0, direction * 5)
    end
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return end

    local startIdx = Search:GetSelectedIndex()
    if startIdx == 0 then
        startIdx = direction > 0 and 0 or visibleCount + 1
    end

    local uiSectionStart = 0
    for i = 1, visibleCount do
        local row = Search:GetResultButtons()[i]
        if row and not row.isPinHeader and not row.isPinned then
            uiSectionStart = i
            break
        end
    end

    -- Find the next section boundary in the given direction.
    -- Boundaries: first non-pinned row (Search search) + any isSectionHeader row.
    local idx = startIdx + direction
    while idx >= 1 and idx <= visibleCount do
        local row = Search:GetResultButtons()[idx]
        if row and (row.isSectionHeader or idx == uiSectionStart) then
            Search:SetSelectedIndex(idx)
            Search:SetToggleFocused(false)
            self:UpdateSelectionHighlight()
            return
        end
        idx = idx + direction
    end
end

function Results:UpdateSelectionHighlight(skipRefocus, keepRepeat)
    -- Action-hint overlay: replaces the selected row's pathSubtext with
    -- a "Select to ..." hint so the user knows what Enter / left-click
    -- will do, without cluttering every row. Restored to the canonical
    -- subtext (recomputed via GetFlatSubtext) when selection moves.
    local newSelRow = Search:GetSelectedIndex() > 0 and Search:GetResultButtons()[Search:GetSelectedIndex()] or nil
    if newSelRow and not Search:GetToggleFocused() then
        if not Handlers:GetActionHint(newSelRow.data) then Handlers:ClearActionHint() end
        Handlers:ApplyActionHint(newSelRow)
    else
        Handlers:ClearActionHint()
    end

    for i = 1, MAX_BUTTON_POOL do
        local resultRow = Search:GetResultButtons()[i]
        if not resultRow then break end
        local isHeaderRow = resultRow.headerTab and resultRow.headerTab:IsShown()
        if resultRow.LockHighlight then
            if i == Search:GetSelectedIndex() and not isHeaderRow then
                Results:SetRowHighlightLocked(resultRow, true)
            elseif not resultRow._efContextMenuHeld then
                Results:SetRowHighlightLocked(resultRow, false)
            end
        end
    end
    if Search:GetSelectedIndex() > 0 then
        if Search:GetResultButtons()[Search:GetSelectedIndex()] then
            Utils.ScrollToButton(ResultsFrame().scrollFrame, Search:GetResultButtons()[Search:GetSelectedIndex()])
        end
        if Search:GetSearchFrame().editBox:HasFocus() then
            Search:GetSearchFrame().editBox:ClearFocus()
        end
        Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", true)
        if newSelRow and not Search:GetToggleFocused() and newSelRow.data and newSelRow.data.calculatorResult then
            self:ArmCalculatorSelectionForKeyboard(newSelRow)
        elseif Calculator._calculator and Calculator._calculator.activeData then
            Calculator:ClearCalculatorCopyHighlight()
        end
    else
        if Calculator._calculator and Calculator._calculator.activeData then
            Calculator:ClearCalculatorCopyHighlight()
        end
        local wasNavigating = Search:GetNavFrame():IsKeyboardEnabled()
        Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", false)
        -- Same guard as HideResults: don't kill an active nav-repeat
        -- ticker from a re-render that happens to land selectedIndex=0.
        -- The async heavy-search refresh path calls this with
        -- keepRepeat=nil; without the IsAltNavRepeatKey guard the
        -- cascade would die at a random history entry.
        local searchFrame = Search:GetSearchFrame()
        local navRepeatActive = searchFrame.IsAltNavRepeatKey
            and searchFrame.IsAltNavRepeatKey()
        if not keepRepeat and not navRepeatActive and searchFrame.StopKeyRepeat then
            searchFrame.StopKeyRepeat()
        end
        if wasNavigating and not skipRefocus and not searchFrame.editBox:HasFocus() then
            searchFrame.editBox.blockFocus = nil
            searchFrame.editBox:SetFocus()
        end
    end

    -- Secure rows need Enter bound to the row button so protected actions
    -- fire. The binding lives on the secure show/hide owner (see
    -- ResultsFrame.lua): its _onhide snippet clears it in secure execution,
    -- so this insecure path only ever writes while the dropdown is shown.
    local bindOwner = Results._navBindOwner
    if bindOwner and bindOwner:IsShown() and not InCombatLockdown() then
        local selRow = Search:GetSelectedIndex() > 0 and Search:GetResultButtons()[Search:GetSelectedIndex()]
        local rd = selRow and selRow.data
        local secureRow = rd and Icons:IsSecureActionResult(rd)
        local btnName = secureRow and selRow:GetName() or nil
        if btnName ~= navEnterBound then
            if btnName then
                SetOverrideBindingClick(bindOwner, true, "ENTER", btnName, "LeftButton")
            else
                ClearOverrideBindings(bindOwner)
            end
            navEnterBound = btnName
        end
    end
end

-- The secure _onhide snippet cleared the owner's bindings; sync bookkeeping.
function Results:NoteNavBindingCleared()
    navEnterBound = nil
end

function Results:ActivateResultRow(resultRow, source)
    if not resultRow or not resultRow:IsShown() then return false end
    if resultRow.isUnearnedCurrency or resultRow.lockedReason
       or resultRow.isPinHeader or resultRow.isSectionHeader then
        return true
    end
    if not resultRow.data then return false end

    if resultRow.data.quickFilterDef then
        return self:ApplyQuickFilter(resultRow.data.quickFilterDef, "")
    end
    if resultRow.data.searchCommand then
        -- Capture before dismissing: FinishResultSelection clears the search,
        -- which rebuilds the rows and nils out resultRow.data.
        local cmd = resultRow.data.searchCommand
        self:FinishResultSelection()
        return self:RunSearchBarCommand("/" .. cmd)
    end
    if resultRow.data.nativeRun then
        local run = resultRow.data.nativeRun
        self:FinishResultSelection()
        run()
        return true
    end
    if resultRow.data.specSetIndex or resultRow.data.loadoutConfigID then
        local specIndex, loadoutID = resultRow.data.specSetIndex,
            resultRow.data.loadoutConfigID
        self:FinishResultSelection()
        if ns.RunTalentSwap then ns.RunTalentSwap(specIndex, loadoutID) end
        return true
    end
    if resultRow.data.calculatorLauncher then
        return self:OpenCalculator("")
    end
    if Rows:ActivateSettingResult(resultRow.data) then return true end
    if resultRow.data.calculatorResult then
        self:ArmCalculatorResultFromRow(resultRow, source or "click")
        return true
    end
    if resultRow.data.copyText then
        if ns.RowCopy then ns.RowCopy:ArmFor(resultRow) end
        return true
    end
    self:SelectResult(resultRow.data)
    return true
end

function Results:ActivateSelected(source)
    -- Enter on the grid's focused cell = the left-click action (the cell menu).
    if self.IsIconGridNavActive and self:IsIconGridNavActive() then
        if self:ActivateIconGridFocus() then return end
    end
    if Search:GetSelectedIndex() > 0 and Search:GetSelectedIndex() <= MAX_BUTTON_POOL then
        local resultRow = Search:GetResultButtons()[Search:GetSelectedIndex()]
        if resultRow and resultRow:IsShown() then
            if resultRow.isPathNode and Search:GetToggleFocused() then
                local key = (resultRow.pathNodeName or "") .. "_" .. (resultRow.pathNodeDepth or 0)
                CollapsedNodes()[key] = not CollapsedNodes()[key]
                if Results._cachedHierarchical then
                    local savedIndex = Search:GetSelectedIndex()
                    local savedToggle = Search:GetToggleFocused()
                    self:ShowHierarchicalResults(Results._cachedHierarchical, true)
                    Search:SetSelectedIndex(savedIndex)
                    Search:SetToggleFocused(savedToggle)
                    self:UpdateSelectionHighlight()
                end
            else
                self:ActivateResultRow(resultRow, source or "key")
            end
            return
        end
    end
    -- Fallback: select first result if nothing is highlighted
    self:SelectFirstResult()
end

function Results:UpdateOutfitLockOverlay(resultRow, isLocked)
    if not resultRow.icon then return end
    if not resultRow._lockOverlay then
        local overlay = resultRow:CreateTexture(nil, "OVERLAY")
        overlay:SetTexture("Interface\\AddOns\\EasyFind\\textures\\lock-dashes")
        overlay:SetVertexColor(Utils.RGB(GOLD_COLOR, 1))
        overlay:SetPoint("CENTER", resultRow.icon, "CENTER", 0, 0)
        resultRow._lockOverlay = overlay
        -- Four dot-chains (one per edge) cycled by a FlipBook: they rest on
        -- their edge then whip clockwise through each corner to the next.
        local ag = overlay:CreateAnimationGroup()
        ag:SetLooping("REPEAT")
        local fb = ag:CreateAnimation("FlipBook")
        fb:SetFlipBookRows(8)
        fb:SetFlipBookColumns(4)
        fb:SetFlipBookFrames(32)
        fb:SetDuration(0.9)
        resultRow._lockAnim = ag
    end
    local size = (resultRow.icon:GetWidth() or 16) + 2
    resultRow._lockOverlay:SetSize(size, size)
    resultRow._lockOverlay:SetShown(isLocked)
    if isLocked then
        resultRow._lockAnim:Play()
    else
        resultRow._lockAnim:Stop()
    end
end

-- Spec badge on a gear set's icon: the Equipment Manager marks a set that is
-- assigned to a specialization with that spec's icon in the corner, so our
-- rows do the same. Lazily created and anchored to the row icon (the lock
-- overlay pattern); hidden for sets with no assignment.
function Results:UpdateGearSetSpecBadge(resultRow, specIcon)
    if not resultRow.icon then return end
    if not resultRow._specBadge then
        -- Circular, bottom-right corner, same as the Equipment Manager. The
        -- portrait alpha mask is Blizzard's standard round-crop. No disc or
        -- ring behind it: the round crop alone reads cleanly, and the dark
        -- backing just muddied the corner.
        local badge = resultRow:CreateTexture(nil, "OVERLAY", nil, 7)
        badge:SetPoint("BOTTOMRIGHT", resultRow.icon, "BOTTOMRIGHT", 3, -3)
        resultRow._specBadge = badge

        local badgeMask = resultRow:CreateMaskTexture()
        badgeMask:SetTexture(PORTRAIT_ALPHA_MASK,
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        badgeMask:SetAllPoints(badge)
        badge:AddMaskTexture(badgeMask)
    end
    if specIcon then
        local size = mmax(8, mfloor((resultRow.icon:GetWidth() or 16) + 0.5))
        resultRow._specBadge:SetSize(size, size)
        resultRow._specBadge:SetTexture(specIcon)
    end
    resultRow._specBadge:SetShown(specIcon and true or false)
end

function Results:ApplyTransmogBrowseMode()
    if not TransmogFrame then return end

    local hidden = {}
    local outfitCollection = TransmogFrame.OutfitCollection
    if outfitCollection then
        if outfitCollection.PurchaseOutfitButton then
            outfitCollection.PurchaseOutfitButton:Hide()
            hidden[#hidden + 1] = outfitCollection.PurchaseOutfitButton
        end
        if outfitCollection.SaveOutfitButton then
            outfitCollection.SaveOutfitButton:Hide()
            hidden[#hidden + 1] = outfitCollection.SaveOutfitButton
        end
    end
    if outfitCollection and outfitCollection.MoneyFrame then
        outfitCollection.MoneyFrame:Hide()
        hidden[#hidden + 1] = outfitCollection.MoneyFrame
    end

    local wardrobeCollection = TransmogFrame.WardrobeCollection
    local tabHeaders = wardrobeCollection and wardrobeCollection.TabHeaders
    if tabHeaders then
        -- Try Blizzard's localized global first, fall back to English so
        -- the literal still works on enUS even if the global moves. Tab
        -- text is rendered with localized labels on non-English clients,
        -- so a raw "Situations" compare fails everywhere except enUS.
        local situationsLabel = (_G["TRANSMOG_OUTFITS_SITUATIONS"]
            or _G["TRANSMOG_SITUATION"]
            or "Situations")
        for _, tab in ipairs({ tabHeaders:GetChildren() }) do
            if tab.GetText and tab:GetText() == situationsLabel then
                tab:Hide()
                hidden[#hidden + 1] = tab
                break
            end
        end
    end

    -- Disable right-click on outfit name buttons (shows "Change Name/Icon"
    -- which doesn't work without a vendor). ScrollBox items are recycled,
    -- so re-register on each visible frame and hook the ScrollBox update.
    local outfitScrollBox = outfitCollection and outfitCollection.OutfitList
        and outfitCollection.OutfitList.ScrollBox
    if outfitScrollBox and outfitScrollBox.EnumerateFrames then
        local function disableOutfitRightClick()
            for _, itemFrame in outfitScrollBox:EnumerateFrames() do
                local outfitBtn = itemFrame.OutfitButton
                if outfitBtn and outfitBtn.RegisterForClicks then
                    outfitBtn:RegisterForClicks("LeftButtonUp")
                end
            end
        end
        disableOutfitRightClick()
        -- Re-apply when ScrollBox recycles frames (scroll, resize)
        if not outfitScrollBox._efBrowseHooked then
            outfitScrollBox._efBrowseHooked = true
            hooksecurefunc(outfitScrollBox, "Update", function()
                if TransmogFrame._efBrowseMode then
                    disableOutfitRightClick()
                end
            end)
        end
    end
    TransmogFrame._efBrowseMode = true

    TransmogFrame._efHiddenFrames = hidden

    -- Browse-mode message (left panel, where vendor buttons were)
    if not TransmogFrame._efBrowseMsg then
        local msg = TransmogFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetText(L["TMOG_VENDOR_REQUIRED"])
        msg:SetTextColor(Utils.RGB(GOLD_COLOR))
        msg:SetJustifyH("CENTER")
        TransmogFrame._efBrowseMsg = msg
    end
    local msg = TransmogFrame._efBrowseMsg
    msg:ClearAllPoints()
    local anchor = outfitCollection and outfitCollection.PurchaseOutfitButton
    if anchor then
        msg:SetPoint("TOP", anchor, "TOP", 0, 0)
    elseif outfitCollection then
        msg:SetPoint("BOTTOM", outfitCollection, "BOTTOM", 0, 20)
    else
        msg:SetPoint("BOTTOM", TransmogFrame, "BOTTOM", 0, 30)
    end
    msg:SetWidth((outfitCollection and outfitCollection:GetWidth() - 20) or 280)
    msg:Show()

    -- Situations message (top right, near the hidden tab)
    if not TransmogFrame._efSituationsMsg then
        local sitMsg = TransmogFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sitMsg:SetText(L["TMOG_VENDOR_SITUATIONS"])
        sitMsg:SetTextColor(Utils.RGB(GOLD_COLOR))
        sitMsg:SetJustifyH("RIGHT")
        TransmogFrame._efSituationsMsg = sitMsg
    end
    local sitMsg = TransmogFrame._efSituationsMsg
    sitMsg:ClearAllPoints()
    if tabHeaders then
        sitMsg:SetPoint("LEFT", tabHeaders, "RIGHT", 8, 6)
    else
        sitMsg:SetPoint("TOPRIGHT", TransmogFrame, "TOPRIGHT", -40, -55)
    end
    sitMsg:Show()

    -- Restore on hide (one-shot hook, reads _efHiddenFrames at fire time)
    if not TransmogFrame._efBrowseHooked then
        TransmogFrame._efBrowseHooked = true
        TransmogFrame:HookScript("OnHide", function(self)
            self._efBrowseMode = nil
            if self._efHiddenFrames then
                for _, frame in ipairs(self._efHiddenFrames) do
                    frame:Show()
                end
                self._efHiddenFrames = nil
            end
            if self._efBrowseMsg then
                self._efBrowseMsg:Hide()
            end
            if self._efSituationsMsg then
                self._efSituationsMsg:Hide()
            end
            local oc = self.OutfitCollection
            local sb = oc and oc.OutfitList and oc.OutfitList.ScrollBox
            if sb and sb.EnumerateFrames then
                for _, itemFrame in sb:EnumerateFrames() do
                    local outfitBtn = itemFrame.OutfitButton
                    if outfitBtn and outfitBtn.RegisterForClicks then
                        outfitBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    end
                end
            end
        end)
    end
end
