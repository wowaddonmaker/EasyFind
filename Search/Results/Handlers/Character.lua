local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ClickButton = Utils.ClickButton
local select, ipairs = Utils.select, Utils.ipairs
local slower = Utils.slower
local CreateFrame = CreateFrame
local C_Reputation = C_Reputation
local C_CurrencyInfo = C_CurrencyInfo
local MAX_WATCHED_TOKENS_CAP = _G["MAX_WATCHED_TOKENS"] or 3

function Handlers:ClickCharacterSidebar(sidebarIndex)
    -- The sidebar buttons are PaperDollSidebarTab1/2/3 inside PaperDollSidebarTabs
    -- (confirmed via Frame Inspector)

    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end

    -- Switch to the Character tab (tab 1) first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(CharacterFrame) ~= 1 then
        Openers:OpenCharacterFrame(1)
    end

    -- Method 1: Try PaperDollSidebarTab buttons directly (Frame Inspector confirmed names)
    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab then
        if sidebarTab:IsShown() then
            return ClickButton(sidebarTab)
        else
            -- Tab exists but isn't shown yet - try after a brief delay
            Utils.SafeAfter(0.2, function()
                if sidebarTab:IsShown() then ClickButton(sidebarTab) end
            end)
            return true
        end
    end

    -- Method 2: Search PaperDollSidebarTabs container children by index
    local sidebarTabs = _G["PaperDollSidebarTabs"]
    if not sidebarTabs and PaperDollFrame then
        sidebarTabs = PaperDollFrame.SidebarTabs
    end
    if sidebarTabs then
        local nTabs = select("#", sidebarTabs:GetChildren())
        if sidebarIndex <= nTabs then
            return ClickButton(select(sidebarIndex, sidebarTabs:GetChildren()))
        end
    end

    -- Method 3: Try the ToggleSidebarTab function if available
    if PaperDollFrame and PaperDollFrame.ToggleSidebarTab then
        PaperDollFrame:ToggleSidebarTab(sidebarIndex)
        return true
    end

    return false
end

function Handlers:IsCurrencyOnBackpack(currencyID)
    if not currencyID or currencyID == 0 or not C_CurrencyInfo then return false end
    -- The enumeration list is authoritative. The CurrencyInfo struct's
    -- `isShowInBackpack` flag in modern builds indicates *capability*
    -- (the currency is allowed to be tracked), not current state, so
    -- using it always read as on, the toggle always tried to add, and
    -- removal silently no-op'd.
    local getInfo = C_CurrencyInfo.GetBackpackCurrencyInfo
    if getInfo then
        local cap = MAX_WATCHED_TOKENS_CAP
        for i = 1, cap do
            local bok, bi = pcall(getInfo, i)
            if not bok or type(bi) ~= "table" then break end
            local id = bi.currencyTypesID or bi.currencyID
            -- Require a non-zero ID match. Some clients return a
            -- placeholder table for unused tracker slots with id=0 /
            -- name="" / nil quantity instead of returning nil; without
            -- this guard, comparing against currencyID still works but
            -- we'd false-positive if the caller ever passed 0 or nil
            -- through (defended above): keep the explicit check so a
            -- future mistake at a call site can't bite.
            if id and id ~= 0 and id == currencyID then return true end
        end
        return false
    end
    -- Fallback for builds that don't expose the enumeration: trust the
    -- inline flag from GetCurrencyInfo.
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or type(info) ~= "table" then return false end
    return info.isShowInBackpack and true or false
end

-- Force a dropdown's trigger label to re-read its IsSelected callback.
-- Modern WowDropdownMenu builds the displayed selection text inside
-- SetupMenu's generator; calling GenerateMenu rebuilds and re-evaluates.
local function RefreshDropdownLabel(dropdown)
    if not dropdown then return end
    if dropdown.GenerateMenu then pcall(dropdown.GenerateMenu, dropdown)
    elseif dropdown.RefreshMenu then pcall(dropdown.RefreshMenu, dropdown)
    elseif dropdown.SignalUpdate then pcall(dropdown.SignalUpdate, dropdown) end
end

-- Currency filter. API: C_CurrencyInfo.SetCurrencyFilter(filterType).
-- DiscoveredAndAllAccountTransferable = "warband"; DiscoveredOnly = "all".
function Handlers:ApplyTokenFrameFilter(mode)
    if not mode or not C_CurrencyInfo or not C_CurrencyInfo.SetCurrencyFilter then return end
    if not Enum or not Enum.CurrencyFilterType then return end
    local target = (mode == "warband")
        and Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable
        or  Enum.CurrencyFilterType.DiscoveredOnly
    local current = C_CurrencyInfo.GetCurrencyFilter and C_CurrencyInfo.GetCurrencyFilter()
    if current == target then return end
    -- Mirror Blizzard's SetFilterTypeSelected: clear in-flight selection
    -- so the popup doesn't try to render a row that no longer exists.
    if TokenFrame then
        TokenFrame.selectedToken = nil
        TokenFrame.selectedID = nil
    end
    if TokenFramePopup and TokenFramePopup.Hide then TokenFramePopup:Hide() end
    pcall(C_CurrencyInfo.SetCurrencyFilter, target)
    if TokenFrame and TokenFrame:IsShown() then
        if TokenFrame.Update then pcall(TokenFrame.Update, TokenFrame) end
        RefreshDropdownLabel(TokenFrame.filterDropdown)
    end
end

-- Reputation sort type. API: C_Reputation.SetReputationSortType(sortType).
-- None = "all"; Account = "warband"; Character = "char".
function Handlers:ApplyReputationFilter(mode)
    if not mode or not C_Reputation or not C_Reputation.SetReputationSortType then return end
    if not Enum or not Enum.ReputationSortType then return end
    local sortType
    if mode == "warband" then
        sortType = Enum.ReputationSortType.Account
    elseif mode == "char" then
        sortType = Enum.ReputationSortType.Character
    else
        sortType = Enum.ReputationSortType.None
    end
    local current = C_Reputation.GetReputationSortType and C_Reputation.GetReputationSortType()
    if current == sortType then return end
    pcall(C_Reputation.SetReputationSortType, sortType)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

-- Show Legacy Reputations. API: C_Reputation.SetLegacyReputationsShown(bool).
function Handlers:ApplyReputationShowLegacy(show)
    if not C_Reputation or not C_Reputation.SetLegacyReputationsShown then return end
    show = show and true or false
    local current = C_Reputation.AreLegacyReputationsShown and C_Reputation.AreLegacyReputationsShown()
    if current == show then return end
    pcall(C_Reputation.SetLegacyReputationsShown, show)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

local function GetReputationFactionIndexByID(factionID)
    if not factionID then return nil end
    return Utils.FindFactionByPredicate(function(d) return d.factionID == factionID end)
end

function Handlers:IsReputationWatched(factionID)
    if not factionID then return false end
    if C_Reputation then
        if C_Reputation.GetFactionDataByID then
            local ok, factionData = pcall(C_Reputation.GetFactionDataByID, factionID)
            if ok and factionData and factionData.isWatched then return true end
        end
        if C_Reputation.GetWatchedFactionData then
            local ok, watchedData = pcall(C_Reputation.GetWatchedFactionData)
            if ok and watchedData and watchedData.factionID == factionID then return true end
        end
    end

    local getWatched = _G["GetWatchedFactionInfo"]
    if getWatched then
        local ok, _, _, _, _, _, watchedFactionID = pcall(getWatched)
        if ok and watchedFactionID == factionID then return true end
    end
    return false
end

local function RefreshReputationSurfaces()
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
    if Search and Search.RefreshResults then Search:RefreshResults() end
end

function Handlers:ToggleReputationWatched(factionID)
    if not factionID then return false end

    local clearWatch = Handlers:IsReputationWatched(factionID)
    if C_Reputation and C_Reputation.SetWatchedFactionByID then
        local ok = pcall(C_Reputation.SetWatchedFactionByID, clearWatch and 0 or factionID)
        if ok then
            RefreshReputationSurfaces()
            return true
        end
    end

    local setWatchedIndex = _G["SetWatchedFactionIndex"]
    if setWatchedIndex then
        local factionIndex = clearWatch and 0 or GetReputationFactionIndexByID(factionID)
        if factionIndex then
            local ok = pcall(setWatchedIndex, factionIndex)
            if ok then
                RefreshReputationSurfaces()
                return true
            end
        end
    end
    return false
end

-- Hide Passives. CVar-backed: spellBookHidePassives ("0" / "1").

function Handlers:HookBlizzardFilterChanges()
    if C_CurrencyInfo and C_CurrencyInfo.SetCurrencyFilter and Enum and Enum.CurrencyFilterType then
        hooksecurefunc(C_CurrencyInfo, "SetCurrencyFilter", function(filterType)
            if not EasyFind.db then return end
            EasyFind.db.currencyFilterMode = (filterType == Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable)
                and "warband" or "all"
        end)
    end
    if C_Reputation and C_Reputation.SetReputationSortType and Enum and Enum.ReputationSortType then
        hooksecurefunc(C_Reputation, "SetReputationSortType", function(sortType)
            if not EasyFind.db then return end
            if sortType == Enum.ReputationSortType.Account then
                EasyFind.db.reputationFilterMode = "warband"
            elseif sortType == Enum.ReputationSortType.Character then
                EasyFind.db.reputationFilterMode = "char"
            else
                EasyFind.db.reputationFilterMode = "all"
            end
        end)
    end
    if C_Reputation and C_Reputation.SetLegacyReputationsShown then
        hooksecurefunc(C_Reputation, "SetLegacyReputationsShown", function(show)
            if not EasyFind.db then return end
            EasyFind.db.showLegacyReputations = show and true or false
        end)
    end
    -- Hide Passives is CVar-backed; CVAR_UPDATE fires on any change.
    local cvarFrame = CreateFrame("Frame")
    cvarFrame:RegisterEvent("CVAR_UPDATE")
    cvarFrame:SetScript("OnEvent", function(_, _, name, value)
        if not name or not EasyFind.db then return end
        if slower(name) == "spellbookhidepassives" then
            EasyFind.db.abilityHidePassives = value == "1" or value == 1 or value == true
        end
    end)
end

function Handlers:ToggleCurrencyBackpack(currencyID)
    if not currencyID or not C_CurrencyInfo then return end
    local on = self:IsCurrencyOnBackpack(currencyID)
    local target = not on

    -- Backpack tracker caps at 3. When the user tries to ADD a fourth,
    -- raise the same red UIErrorsFrame message Blizzard's default Search
    -- shows instead of silently dropping the call.
    if target and C_CurrencyInfo.GetBackpackCurrencyInfo then
        local cap = MAX_WATCHED_TOKENS_CAP
        local count = 0
        for i = 1, cap + 1 do
            local bok, bi = pcall(C_CurrencyInfo.GetBackpackCurrencyInfo, i)
            if not bok or type(bi) ~= "table" then break end
            count = count + 1
        end
        if count >= cap then
            local msg = (_G["TOKEN_BACKPACK_FULL_MESSAGE"])
                or string.format(ns.L["MSG_CURRENCY_WATCH_LIMIT"], cap)
            local errFrame = _G["UIErrorsFrame"]
            if errFrame and errFrame.AddMessage then
                errFrame:AddMessage(msg, 1.0, 0.1, 0.1, 1.0)
            end
            return
        end
    end

    -- SetCurrencyBackpackByID takes a currency ID directly. The older
    -- SetCurrencyBackpack takes a *list index* (which is why it
    -- silently no-op'd / hit the wrong currency when called with an
    -- ID). Prefer the by-ID variant when available.
    if C_CurrencyInfo.SetCurrencyBackpackByID then
        pcall(C_CurrencyInfo.SetCurrencyBackpackByID, currencyID, target)
    elseif C_CurrencyInfo.SetCurrencyBackpack then
        pcall(C_CurrencyInfo.SetCurrencyBackpack, currencyID, target)
    end

    -- Force the visible backpack token strip to refresh now. The
    -- SetCurrency* call updates state but doesn't always notify the
    -- ContainerFrame's token row when the bag is already open, so the
    -- user sees stale icons until they close and reopen. Call every
    -- update entry-point we know about; whichever exists in this
    -- client wins, the rest no-op.
    local candidates = {
        _G["BackpackTokenFrame"],
        _G["BackpackTokenFrame_Update"],
    }
    for _, c in ipairs(candidates) do
        if type(c) == "function" then
            pcall(c)
        elseif type(c) == "table" then
            if c.Update then pcall(c.Update, c) end
            if c.UpdateTokens then pcall(c.UpdateTokens, c) end
        end
    end
    -- Container frames host the token row in modern bag Search. Iterate
    -- the standard ContainerFrame1..N looking for an Update method.
    for i = 1, 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf.Update then pcall(cf.Update, cf) end
        local tokenFrame = cf and cf.tokenFrame
        if tokenFrame and tokenFrame.Update then
            pcall(tokenFrame.Update, tokenFrame)
        end
    end
end

function Handlers:IsCurrencyTransferable(currencyID)
    return ns.Database and ns.Database.IsCurrencyAccountTransferable
       and ns.Database:IsCurrencyAccountTransferable(currencyID) or false
end

-- Open the Currency tab and walk the live transfer flow: SelectResult only
-- opens the tab and highlights the row, but the Transfer button lives in
-- TokenFramePopup, which appears only once the currency row is clicked. So
-- click the row, then its Transfer toggle, which opens CurrencyTransferMenu.
function Handlers:RouteCurrencyTransfer(pinData)
    if not pinData then return end
    local currencyID = pinData.currencyID
    -- Keep the currency-row highlight persistent (no hover-dismiss) because
    -- it's an intermediate step here -- the destination is the Transfer
    -- button on the popup, not the row itself.
    if ns.Highlight and ns.Highlight.SetPersistentCurrencyHighlight then
        ns.Highlight:SetPersistentCurrencyHighlight(true)
    end
    self:SelectResult(pinData)
    if not (currencyID and Utils and Utils.SafeAfter and ns.Highlight) then return end

    -- Auto-clicking the currency row taints the final transfer call, so we
    -- let the player click it; then we move the highlight to Transfer.
    local highlightDone = false
    local function watchForPopup(remaining)
        if highlightDone then return end
        local popup = _G["TokenFramePopup"]
        local btn = popup and popup.CurrencyTransferToggleButton
        if popup and popup:IsShown() and btn and btn:IsShown() then
            highlightDone = true
            ns.Highlight:StartGuide({
                steps = { { buttonFrame = "TokenFramePopup.CurrencyTransferToggleButton" } }
            })
            return
        end
        if remaining > 0 then
            Utils.SafeAfter(0.2, function() watchForPopup(remaining - 1) end)
        end
    end
    Utils.SafeAfter(0.2, function() watchForPopup(50) end)
end

-- Open the AchievementFrame to a specific achievement. Tries Blizzard's
-- modern OpenAchievementFrameToAchievement first; falls back to the
-- legacy AchievementFrame_SelectAchievement; finally just shows the
