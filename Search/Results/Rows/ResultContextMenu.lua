local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Handlers = ns.ResultHandlers
local Utils = ns.Utils
local UIPins = ns.UIPins

local IsUIItemPinned = UIPins.IsPinned
local PinUIItem = UIPins.Pin
local UnpinUIItem = UIPins.Unpin

function Rows:ShowResultContextMenu(row, keyboardMode)
    if not row or not row.data then return false end
    if row.data.calculatorResult or row.data.quickFilterDef then return false end

    local pinData = row.data
    local isPinned = IsUIItemPinned(pinData)
    local hasGuide = pinData.steps or pinData.transmogSetID
        or (pinData.category == "Loot" and pinData.itemID)
        or pinData.petID or pinData.speciesID
        or pinData.mapSearchResult
    local onGuide = hasGuide and function()
        Handlers:SelectResult(pinData, true)
    end or nil
    local canAlias = ns.Aliases and ns.Aliases:GetEntryKey(pinData) ~= nil
    local onAddAlias = canAlias and function()
        Handlers:PromptForAlias(pinData)
    end or nil
    local extra
    if pinData.achievementID and pinData.category == "Achievement" then
        local achID = pinData.achievementID
        local isTracked = Handlers:IsAchievementTracked(achID)
        extra = {
            isTracked = isTracked,
            onTrack = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:ToggleAchievementTracked(achID)
            end,
        }
    elseif pinData.category == "Currency" and pinData.currencyID then
        local cid = pinData.currencyID
        extra = {
            isOnBackpack = Handlers:IsCurrencyOnBackpack(cid),
            onToggleBackpack = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:ToggleCurrencyBackpack(cid)
            end,
        }
        if Handlers:IsCurrencyTransferable(cid) then
            extra.onTransfer = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:RouteCurrencyTransfer(pinData)
            end
        end
    elseif pinData.category == "Reputation" and pinData.factionID then
        local fid = pinData.factionID
        extra = {
            isWatchedFaction = Handlers:IsReputationWatched(fid),
            onToggleWatchedFaction = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:ToggleReputationWatched(fid)
            end,
        }
    elseif pinData.transmogSetID then
        local sid = pinData.transmogSetID
        extra = {
            isFavorite = Handlers:IsTransmogSetFavorite(sid),
            onToggleFavorite = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:ToggleTransmogSetFavorite(sid)
            end,
        }
    elseif pinData.petID then
        local pid = pinData.petID
        local cageable = Handlers:IsPetCageable(pid)
        extra = {
            onSummon = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:SummonPet(pid)
            end,
            onRename = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:RenamePet(pid)
            end,
            isFavorite = Handlers:IsPetFavorite(pid),
            onToggleFavorite = function()
                Results:KeepPinnedResultsOpenBriefly()
                Handlers:TogglePetFavorite(pid)
            end,
            onCageOrRelease = function()
                Results:KeepPinnedResultsOpenBriefly()
                if cageable then Handlers:CagePet(pid) else Handlers:ReleasePet(pid) end
            end,
            isCageable = cageable,
        }
    end

    extra = extra or {}
    extra.disabled = (row.isUnearnedCurrency or row.lockedReason) and true or nil
    if pinData.category == "Bag" and pinData.bagID ~= nil and pinData.bagSlot then
        extra.onDestroyItem = function()
            Handlers:DestroyBagItem(pinData)
        end
    end
    if pinData.snippetIndex then
        local snippetIndex = pinData.snippetIndex
        extra.onSnippetInsert = function()
            ns.Snippets:RunByName(pinData.name)
        end
        extra.onSnippetEdit = function()
            ns.Snippets:OpenEditor(snippetIndex)
        end
        extra.onSnippetDelete = function()
            ns.Snippets:DeleteWithConfirm(snippetIndex)
        end
        -- Notes is a separate sibling addon; offer the note action only
        -- when it is installed and enabled for this character.
        local notesState = C_AddOns and C_AddOns.GetAddOnEnableState
            and C_AddOns.GetAddOnEnableState("EasyFind_Notes")
        if notesState and notesState > 0 then
            extra.onSnippetInsertNote = function()
                ns.Snippets:InsertIntoNote(pinData.name)
            end
        end
    end
    local wowheadUrl = ns.GetWowheadLink and ns.GetWowheadLink(pinData)
    if wowheadUrl then
        extra.onWowhead = function()
            ns.ShowCopyBox(wowheadUrl, ns.L["WOWHEAD_COPY_HINT"]:format(pinData.name or ""))
        end
    end
    local chatLink = ns.GetResultLink and ns.GetResultLink(pinData)
    if chatLink then
        extra.sendLink = { link = chatLink, name = pinData.name }
        local addNoteRows = ns.BuildAddNoteRows and ns.BuildAddNoteRows(chatLink, pinData.name)
        if addNoteRows then extra.addNoteRows = addNoteRows end
    end
    local skKey = ns.Shortkeys and ns.Shortkeys:GetEntryKey(pinData)
    if skKey then
        extra.hasShortkey = ns.Shortkeys:Get(skKey) ~= nil
        extra.onAddShortkey = function() ns.Shortkeys:PromptForKey(pinData) end
    end
    -- Blacklist shares the alias key gate: any keyable row can be hidden
    -- from all future results. The Blacklist options tab is the undo path.
    if canAlias and ns.Blacklist then
        extra.onBlacklist = function()
            if not ns.Blacklist:Add(pinData) then return end
            if ns.RefreshBindTables then ns.RefreshBindTables() end
            local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
            local text = editBox and editBox:GetText() or ""
            if text == "" then
                Results:KeepPinnedResultsOpenBriefly()
                Results:ShowEmptyQueryView()
            else
                Search:OnSearchTextChanged(text, true)
            end
        end
    end
    local function FocusKeyboardMenu(menu)
        if not keyboardMode or not menu or not menu:IsShown() then return end
        local navFrame = Search:GetNavFrame()
        if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
        if menu.FocusKeyboard then
            menu:FocusKeyboard(1)
        else
            Utils.SafeCallMethod(menu, "EnableKeyboard", true)
            Utils.SafeCallMethod(menu, "SetPropagateKeyboardInput", false)
            if menu.SetKeyboardIndex then menu.SetKeyboardIndex(menu, 1) end
        end
    end
    local kbOnHide
    if keyboardMode then
        extra.keyboardMode = true
        kbOnHide = function()
            local navFrame = Search:GetNavFrame()
            if navFrame and Search:GetSelectedIndex() > 0
               and Search:GetSearchFrame() and Search:GetSearchFrame():IsShown() then
                Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
            end
        end
        local navFrame = Search:GetNavFrame()
        if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
    end

    -- Keep the right-clicked row highlighted for as long as its menu is open,
    -- so it stays clear which row the menu belongs to even as the cursor moves
    -- onto the menu. Restored to the selection state when the menu hides.
    extra.onHide = function()
        row._efContextMenuHeld = nil
        Results:SetRowHighlightLocked(row, false)
        Results:UpdateSelectionHighlight(true)
        if kbOnHide then kbOnHide() end
    end

    local menu = Results:ShowPinPopup(row, isPinned, function()
        if isPinned then
            UnpinUIItem(pinData)
        else
            PinUIItem(pinData)
        end
        local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        local text = editBox and editBox:GetText() or ""
        if text == "" then
            local pinsRemain = Results:KeepPinnedResultsOpenBriefly()
            Results:ShowEmptyQueryView()
            if pinsRemain and editBox
               and not (Search:GetNavFrame() and Search:GetNavFrame():IsKeyboardEnabled()) then
                editBox.blockFocus = nil
                editBox:SetFocus()
            end
        else
            Search:OnSearchTextChanged(text, true)
        end
    end, onGuide, onAddAlias, extra)
    if menu then
        -- Typing belongs to the menu now (keyboard rows, ESC to close);
        -- drop the editbox focus so keystrokes don't land in the query.
        -- The flag stops OnEditFocusLost's click-away cleanup from
        -- hiding the results (the empty-text pinned view especially).
        local searchFrame = Search:GetSearchFrame()
        local editBox = searchFrame and searchFrame.editBox
        if editBox then
            editBox._menuUnfocus = true
            editBox:ClearFocus()
            editBox._menuUnfocus = nil
        end
        row._efContextMenuHeld = true
        Results:SetRowHighlightLocked(row, true)
        Handlers:ApplyActionHint(row)
    end
    FocusKeyboardMenu(menu)
    Utils.SafeAfter(0, function()
        FocusKeyboardMenu(menu)
    end)
    return menu and true or false
end
