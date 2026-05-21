local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils
local UIPins = ns.UIPins
local GOLD_COLOR = ns.GOLD_COLOR

local ipairs = Utils.ipairs
local wipe = wipe
local StaticPopup_Visible = StaticPopup_Visible
local StaticPopup_Show = StaticPopup_Show

local MAX_BUTTON_POOL = 100
local GetAllPins = UIPins.GetAll
local pinnedOnlyEntries = {}
local idleTrimSerial = 0

local function ResultsFrame()
    return UI:GetResultsFrame()
end

local function FlatEntries()
    return UI._flatEntries
end

local function CollapsedNodes()
    return UI._collapsedNodes
end
function UI:ShowResults(results)
    if not results or #results == 0 then
        self:HideResults()
        return
    end

    local n = 0
    for ri = 1, #results do
        local r = results[ri]
        local d = r and (r.data or r)
        if d then
            n = n + 1
            local e = FlatEntries()[n]
            if not e then
                e = {}
                FlatEntries()[n] = e
            end
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.data = d
        end
    end
    for i = n + 1, #FlatEntries() do
        FlatEntries()[i] = nil
    end
    self:ShowHierarchicalResults(FlatEntries())
end

-- Toggle a boolean setting in place (clicked from a result row).
-- Tries the Settings API first (handles non-CVar settings like action
-- bar visibility), falls back to GetCVar/SetCVar.

function UI:ToggleSettingCheckbox(data)
    if not data or not data.settingVariable then return end
    local var = data.settingVariable
    local curVal = UI:ReadSettingVariable(var)
    if type(curVal) == "boolean" then
        UI:WriteSettingVariable(var, not curVal)
    elseif curVal == "1" or curVal == "0" then
        UI:WriteSettingVariable(var, curVal == "1" and "0" or "1")
    elseif curVal == "true" or curVal == "false" then
        UI:WriteSettingVariable(var, curVal == "true" and "false" or "true")
    elseif curVal == 1 or curVal == 0 then
        UI:WriteSettingVariable(var, curVal == 1 and 0 or 1)
    end
    -- Refresh the row so the checkbox state updates without closing
    -- the search panel. Keeps focus on the editbox so the user can
    -- toggle multiple settings without retyping.
    self:RefreshResults()
    if UI:GetSearchFrame() and UI:GetSearchFrame().editBox
       and not (UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled()) then
        UI:GetSearchFrame().editBox.blockFocus = nil
        UI:GetSearchFrame().editBox:SetFocus()
    end
end

-- Advance a dropdown setting to its next value inline. Returns true if
-- we found options and applied a new value; false if the variable
-- wasn't enumerable (caller should fall back to opening the panel).
-- direction: +1 next (default), -1 prev. Wraps around at either end.
function UI:CycleSettingDropdown(data, direction)
    if not data or not data.settingVariable then return false end
    local var = data.settingVariable
    local opts = data.settingOptions
    if not opts and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
        opts = ns.BlizzOptionsSearch.GetOptionsForVariable(var)
        if opts then data.settingOptions = opts end
    end
    if not opts or #opts == 0 then return false end

    local curVal = UI:ReadSettingVariable(var)

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

    if not UI:WriteSettingVariable(var, nextVal) then return false end

    self:RefreshResults()
    if UI:GetSearchFrame() and UI:GetSearchFrame().editBox
       and not (UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled()) then
        UI:GetSearchFrame().editBox.blockFocus = nil
        UI:GetSearchFrame().editBox:SetFocus()
    end
    return true
end

function UI:SetSettingDropdownValue(data, value)
    if not data or not data.settingVariable then return false end
    if not UI:WriteSettingVariable(data.settingVariable, value) then return false end
    self:RefreshResults()
    if UI:GetSearchFrame() and UI:GetSearchFrame().editBox
       and not (UI:GetNavFrame() and UI:GetNavFrame():IsKeyboardEnabled()) then
        UI:GetSearchFrame().editBox.blockFocus = nil
        UI:GetSearchFrame().editBox:SetFocus()
    end
    return true
end

-- Open the Settings panel to a setting (slider/dropdown/etc.) without
-- closing the EasyFind search results. Mirrors ToggleSettingCheckbox's
-- "stay open" behavior so users can edit one setting in the panel and
-- still see / re-toggle others in the result list.
function UI:OpenSettingNoClose(data)
    if not data or not data.steps or not data.steps[1] then return end
    if ns.BlizzOptionsSearch then
        ns.BlizzOptionsSearch:HandleStep(data.steps[1])
    end
    -- Refresh in case the panel itself altered values that affect the
    -- displayed amountText (e.g. dropdown selection updated).
    self:RefreshResults()
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
    "EasyFindGearOptionsPopup",
    "EasyFindMountOptionsPopup",
    "EasyFindMountSourcePopup",
    "EasyFindDiffPopup",
    "EasyFindSpecPopup",
    "EasyFindSpecFlyout",
    "EasyFindSpecSubFlyout",
}

function UI:CloseFilterDropdownIfOpen()
    if not UI:GetSearchFrame() then return false end
    local closedAny = Utils.HideCursorMenus and Utils.HideCursorMenus() or false
    local dropdown = UI:GetSearchFrame().filterDropdown
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
-- pollute other StaticPopup1 uses elsewhere in the UI.
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

function UI:FindPopupSlot(popupName)
    return FindPopupSlot(popupName)
end

function UI:LiftPopupStrata(popup)
    return LiftPopupStrata(popup)
end
-- Show the unapplied-settings popup (if not already up) and lift its
-- strata above the results panel. Returns true if the popup is now
-- visible (so the caller can short-circuit its dismiss path).
function UI:ShowUnappliedSettingsPopup()
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

function UI:RequestHideResults()
    if ResultsFrame() and ResultsFrame():IsShown() and self:ShowUnappliedSettingsPopup() then
        return
    end
    self:HideResults()
end

function UI:HideResults()
    if not UI:GetSearchFrame() then return end
    UI:StopActiveKeybindCapture()
    self:ClearCalculatorCopyHighlight()
    self:ReleaseCalculatorCopyBox()
    if UI:GetSearchFrame().StopKeyRepeat and not UI._preserveSearchNavRepeat then
        UI:GetSearchFrame().StopKeyRepeat()
    end
    if UI:GetSearchFrame().ClearToolbarFocus then UI:GetSearchFrame().ClearToolbarFocus() end
    UI:ClearResultShortcutBindings()
    if not ResultsFrame() then return end
    ResultsFrame():Hide()
    -- Collapse the combined container back to bar-only height: the
    -- two top anchors stay pinned to the bar, the bottom snaps back
    -- to the bar's BOTTOM. Without this the rounded-rect would still
    -- cover the (now empty) dropdown area below.
    if UI:GetContainerFrame() then
        UI:GetContainerFrame():ClearAllPoints()
        UI:GetContainerFrame():SetPoint("TOPLEFT",  UI:GetSearchFrame(), "TOPLEFT",  0, 0)
        UI:GetContainerFrame():SetPoint("TOPRIGHT", UI:GetSearchFrame(), "TOPRIGHT", 0, 0)
        UI:GetContainerFrame():SetPoint("BOTTOM",   UI:GetSearchFrame(), "BOTTOM",   0, 0)
        ns.SetRoundedRectDivider(UI:GetContainerFrame(), 0, false)
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
    UI._cachedHierarchical = nil
    self._lastRenderSig = nil
    for i = 1, #UI:GetResultButtons() do
        local row = UI:GetResultButtons()[i]
        if row then
            row.data = nil
            row._efShortcutIndex = nil
            row._efShortcutBindingReady = nil
            row._efContentTop = nil
            row._efContentBottom = nil
            row:Hide()
            if row.shortcutGroup then row.shortcutGroup:Hide() end
            if row.icon then
                row.icon.mountID = nil
                row.icon.toyItemID = nil
                row.icon.petID = nil
                row.icon.spellID = nil
                row.icon.outfitID = nil
                row.icon.heirloomItemID = nil
                row.icon.gearSetID = nil
                row.icon.bagItemID = nil
                row.icon.achievementID = nil
                row.icon.lootItemID = nil
            end
        end
    end
    UI:SetSelectedIndex(0)
    UI:SetToggleFocused(false)
    self:UpdateSelectionHighlight(true, UI._preserveSearchNavRepeat)

    if ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end

    idleTrimSerial = idleTrimSerial + 1
    local serial = idleTrimSerial
    Utils.SafeAfter(60, function()
        if serial ~= idleTrimSerial then return end
        if ResultsFrame() and ResultsFrame():IsShown() then return end
        if ns.Database and ns.Database.TrimSearchMemory then
            ns.Database:TrimSearchMemory()
        end
        if ns.MapSearch and ns.MapSearch.TrimSearchMemory then
            ns.MapSearch:TrimSearchMemory()
        end
    end)
end

function UI:ShowPinnedItems()
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

function UI:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    local first = UI:GetResultButtons()[1]
    if ResultsFrame():IsShown() and first and first:IsShown() and first.data then
        if UI:ActivateSettingResult(first.data) then return end
        self:SelectResult(first.data)
    end
end

function UI:CountVisibleResults()
    local count = 0
    for i = 1, MAX_BUTTON_POOL do
        local row = UI:GetResultButtons()[i]
        if row and row:IsShown() then
            count = i
        else
            break
        end
    end
    return count
end

function UI:MoveSelection(delta, skipRefocus, keepRepeat)
    -- CountVisibleResults walks the button pool and trusts each row's
    -- :IsShown(), but child rows of a hidden ResultsFrame() still report
    -- shown, so a leftover row from a prior search would let Alt+J
    -- yank focus into nothing on an empty bar. Gate on the frame.
    if not ResultsFrame() or not ResultsFrame():IsShown() then return false end
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return false end

    local oldIndex = UI:GetSelectedIndex()
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

    UI:SetSelectedIndex(newIndex)
    UI:SetToggleFocused(false)
    self:UpdateSelectionHighlight(skipRefocus, keepRepeat)
    return newIndex ~= oldIndex
end

function UI:JumpToStart()
    if self:CountVisibleResults() > 0 then
        UI:SetSelectedIndex(1)
        UI:SetToggleFocused(false)
        self:UpdateSelectionHighlight()
    end
end

function UI:JumpToEnd()
    local visibleCount = self:CountVisibleResults()
    if visibleCount > 0 then
        UI:SetSelectedIndex(visibleCount)
        UI:SetToggleFocused(false)
        self:UpdateSelectionHighlight()
    end
end

function UI:JumpToNextSection(direction)
    local visibleCount = self:CountVisibleResults()
    if visibleCount == 0 then return end

    local startIdx = UI:GetSelectedIndex()
    if startIdx == 0 then
        startIdx = direction > 0 and 0 or visibleCount + 1
    end

    local uiSectionStart = 0
    for i = 1, visibleCount do
        local row = UI:GetResultButtons()[i]
        if row and not row.isPinHeader and not row.isPinned then
            uiSectionStart = i
            break
        end
    end

    -- Find the next section boundary in the given direction.
    -- Boundaries: first non-pinned row (UI search) + any isSectionHeader row.
    local idx = startIdx + direction
    while idx >= 1 and idx <= visibleCount do
        local row = UI:GetResultButtons()[idx]
        if row and (row.isSectionHeader or idx == uiSectionStart) then
            UI:SetSelectedIndex(idx)
            UI:SetToggleFocused(false)
            self:UpdateSelectionHighlight()
            return
        end
        idx = idx + direction
    end
end

function UI:UpdateSelectionHighlight(skipRefocus, keepRepeat)
    -- Action-hint overlay: replaces the selected row's pathSubtext with
    -- a "Select to ..." hint so the user knows what Enter / left-click
    -- will do, without cluttering every row. Restored to the canonical
    -- subtext (recomputed via GetFlatSubtext) when selection moves.
    local newSelRow = UI:GetSelectedIndex() > 0 and UI:GetResultButtons()[UI:GetSelectedIndex()] or nil
    if newSelRow and not UI:GetToggleFocused() then
        if not UI:GetActionHint(newSelRow.data) then UI:ClearActionHint() end
        UI:ApplyActionHint(newSelRow)
    else
        UI:ClearActionHint()
    end

    for i = 1, MAX_BUTTON_POOL do
        local resultRow = UI:GetResultButtons()[i]
        if not resultRow then break end
        local isHeaderRow = resultRow.headerTab and resultRow.headerTab:IsShown()
        if resultRow.LockHighlight then
            if i == UI:GetSelectedIndex() and not isHeaderRow then
                resultRow:LockHighlight()
            else
                resultRow:UnlockHighlight()
            end
        end
    end
    if UI:GetSelectedIndex() > 0 then
        if UI:GetResultButtons()[UI:GetSelectedIndex()] then
            Utils.ScrollToButton(ResultsFrame().scrollFrame, UI:GetResultButtons()[UI:GetSelectedIndex()])
        end
        if UI:GetSearchFrame().editBox:HasFocus() then
            UI:GetSearchFrame().editBox:ClearFocus()
        end
        Utils.SafeCallMethod(UI:GetNavFrame(), "EnableKeyboard", true)
        if newSelRow and not UI:GetToggleFocused() and newSelRow.data and newSelRow.data.calculatorResult then
            self:ArmCalculatorSelectionForKeyboard(newSelRow)
        end
    else
        local wasNavigating = UI:GetNavFrame():IsKeyboardEnabled()
        Utils.SafeCallMethod(UI:GetNavFrame(), "EnableKeyboard", false)
        if not keepRepeat and UI:GetSearchFrame().StopKeyRepeat then UI:GetSearchFrame().StopKeyRepeat() end
        if wasNavigating and not skipRefocus and not UI:GetSearchFrame().editBox:HasFocus() then
            UI:GetSearchFrame().editBox.blockFocus = nil
            UI:GetSearchFrame().editBox:SetFocus()
        end
    end

    -- Secure rows need Enter bound to the row button so protected actions fire.
    if not InCombatLockdown() then
        local selRow = UI:GetSelectedIndex() > 0 and UI:GetResultButtons()[UI:GetSelectedIndex()]
        local rd = selRow and selRow.data
        local secureRow = rd and UI:IsSecureActionResult(rd)
        if secureRow then
            local btnName = selRow:GetName()
            if btnName then
                SetOverrideBindingClick(UI:GetNavFrame(), true, "ENTER", btnName, "LeftButton")
            end
        else
            ClearOverrideBindings(UI:GetNavFrame())
        end
    end
end

function UI:ActivateResultRow(resultRow, source)
    if not resultRow or not resultRow:IsShown() then return false end
    if resultRow.isUnearnedCurrency or resultRow.isPinHeader or resultRow.isSectionHeader then
        return true
    end
    if not resultRow.data then return false end

    if resultRow.data.quickFilterDef then
        return self:ApplyQuickFilter(resultRow.data.quickFilterDef, "")
    end
    if resultRow.data.searchCommand then
        return self:RunSearchBarCommand("/" .. resultRow.data.searchCommand)
    end
    if resultRow.data.calculatorLauncher then
        return self:OpenCalculator("")
    end
    if UI:ActivateSettingResult(resultRow.data) then return true end
    if resultRow.data.calculatorResult then
        self:ArmCalculatorResultFromRow(resultRow, source or "click")
        return true
    end
    self:SelectResult(resultRow.data)
    return true
end

function UI:ActivateSelected(source)
    if UI:GetSelectedIndex() > 0 and UI:GetSelectedIndex() <= MAX_BUTTON_POOL then
        local resultRow = UI:GetResultButtons()[UI:GetSelectedIndex()]
        if resultRow and resultRow:IsShown() then
            if resultRow.isPathNode and UI:GetToggleFocused() then
                local key = (resultRow.pathNodeName or "") .. "_" .. (resultRow.pathNodeDepth or 0)
                CollapsedNodes()[key] = not CollapsedNodes()[key]
                if UI._cachedHierarchical then
                    local savedIndex = UI:GetSelectedIndex()
                    local savedToggle = UI:GetToggleFocused()
                    self:ShowHierarchicalResults(UI._cachedHierarchical, true)
                    UI:SetSelectedIndex(savedIndex)
                    UI:SetToggleFocused(savedToggle)
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

function UI:UpdateOutfitLockOverlay(resultRow, isLocked)
    if not resultRow.icon then return end
    if not resultRow._lockOverlay then
        local overlay = resultRow:CreateTexture(nil, "OVERLAY")
        overlay:SetAtlas("transmog-outfit-spellFrame-active")
        overlay:SetPoint("CENTER", resultRow.icon, "CENTER", 0, 0)
        resultRow._lockOverlay = overlay

    end
    local size = (resultRow.icon:GetWidth() or 16) + 6
    resultRow._lockOverlay:SetSize(size, size)
    resultRow._lockOverlay:SetShown(isLocked)
end

function UI:ApplyTransmogBrowseMode()
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
        for _, tab in ipairs({ tabHeaders:GetChildren() }) do
            if tab.GetText and tab:GetText() == "Situations" then
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
        msg:SetText("Visit a transmogrification vendor for full functionality.")
        msg:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
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
        sitMsg:SetText("See transmogrification vendor\nto adjust Situations settings.")
        sitMsg:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
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
