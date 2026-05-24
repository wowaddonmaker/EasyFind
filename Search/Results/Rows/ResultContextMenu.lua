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
    if keyboardMode then
        extra.keyboardMode = true
        extra.onHide = function()
            local navFrame = Search:GetNavFrame()
            if navFrame and Search:GetSelectedIndex() > 0
               and Search:GetSearchFrame() and Search:GetSearchFrame():IsShown() then
                Utils.SafeCallMethod(navFrame, "EnableKeyboard", true)
            end
        end
        local navFrame = Search:GetNavFrame()
        if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
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
            Results:ShowPinnedItems()
            if pinsRemain and editBox
               and not (Search:GetNavFrame() and Search:GetNavFrame():IsKeyboardEnabled()) then
                editBox.blockFocus = nil
                editBox:SetFocus()
            end
        else
            Search:OnSearchTextChanged(text, true)
        end
    end, onGuide, onAddAlias, extra)
    FocusKeyboardMenu(menu)
    Utils.SafeAfter(0, function()
        FocusKeyboardMenu(menu)
    end)
    return menu and true or false
end
