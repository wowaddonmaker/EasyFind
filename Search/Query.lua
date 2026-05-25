local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Tooltips = ns.ResultTooltips
local Filters = ns.Filters
local Utils = ns.Utils
local UIPins = ns.UIPins
local SearchText = ns.SearchText

local ipairs, pairs = Utils.ipairs, Utils.pairs
local slower = SearchText.Normalize
local tinsert, tsort = Utils.tinsert, Utils.tsort
local wipe = wipe

local IsUIItemPinned = UIPins.IsPinned
local collapsedNodes = Results._collapsedNodes
local flatEntries = Results._flatEntries
local flatCombined = Results._flatCombined
local SCRATCH = Results._SCRATCH
local heavySearchLoading = false

local function FlatNameLess(ra, rb)
    local sa, sb = ra.score or 0, rb.score or 0
    if sa ~= sb then return sa > sb end
    return (ra.data.name or "") < (rb.data.name or "")
end
local function QueryLooksBossRelated(text)
    if not text then return false end
    for word in slower(text):gmatch("%S+") do
        word = word:gsub("^%p+", ""):gsub("%p+$", "")
        if word == "boss" or word == "bosses"
           or word == "dungeon" or word == "dungeons"
           or word == "raid" or word == "raids" then
            return true
        end
    end
    return false
end

local function RefreshSearchAfterHeavyLoad(anyChanged)
    if not anyChanged then return end
    local currentText = Search:GetSearchFrame() and Search:GetSearchFrame().editBox and Search:GetSearchFrame().editBox:GetText()
    if Search:GetSearchFrame() and Search:GetSearchFrame().editBox and Search:GetSearchFrame().editBox:HasFocus()
       and currentText and currentText ~= "" then
        Search:OnSearchTextChanged(currentText, true)
    end
end

-- GET_ITEM_INFO_RECEIVED arrives async after the client requests item
-- data from the server. Loot stat enrichment ("haste ring") queues the
-- item when GetItemStats returns nil for an uncached item; this handler
-- retries enrichment and refreshes the active search so newly-matchable
-- loot surfaces without the user having to retype.
--
-- Throttled with SafeAfter(0.15) so a burst of arrivals coalesces into
-- one search refresh instead of N.
local itemInfoFrame = CreateFrame("Frame")
local pendingItemRefresh = false
local function RefreshSearchAfterItemInfo()
    pendingItemRefresh = false
    local frame = Search:GetSearchFrame()
    local editBox = frame and frame.editBox
    local currentText = editBox and editBox:GetText()
    if editBox and editBox:HasFocus() and currentText and currentText ~= "" then
        Search:OnSearchTextChanged(currentText, true)
    end
end
itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
    if not ns.Database or not ns.Database.ResolvePendingStatEnrichment then return end
    local enriched = ns.Database:ResolvePendingStatEnrichment(itemID, success)
    if enriched and not pendingItemRefresh then
        pendingItemRefresh = true
        Utils.SafeAfter(0.15, RefreshSearchAfterItemInfo)
    end
end)

local function MaybeLoadHeavySearchData(text, needsHeavy, filters)
    if not ns.Database then return end
    if QueryLooksBossRelated(text) and ns.Database.EnsureDynamicProviderLoaded then
        ns.Database:EnsureDynamicProviderLoaded("bosses", RefreshSearchAfterHeavyLoad)
    end
    if filters and filters.statistics ~= false and ns.Database.EnsureDynamicProviderLoaded then
        ns.Database:EnsureDynamicProviderLoaded("statistics", RefreshSearchAfterHeavyLoad)
    end
    if heavySearchLoading or not ns.Database.LoadHeavyDynamicSearchData then return end
    if not needsHeavy then return end
    heavySearchLoading = true
    local started = ns.Database:LoadHeavyDynamicSearchData(function(anyChanged)
        heavySearchLoading = false
        -- Only re-run search when a provider actually loaded fresh data.
        -- Without this gate, every keystroke after providers are loaded
        -- result re-rendering and SearchUI's per-iteration scratch.
        RefreshSearchAfterHeavyLoad(anyChanged)
    end)
    if not started then heavySearchLoading = false end
end

function Search:OnSearchTextChanged(text, force)
    -- Suppress re-renders while SelectResult is clearing text/focus
    if Search:IsSelectingResult() then return end
    -- A pending OnTextChanged timer can fire after focus has shifted
    -- away from the editbox (user clicked outside, OR clicked an
    -- inline child widget like a slider that StripAutocomplete then
    -- triggers a SetText on via the focus-loss hook). Just bail:
    -- don't re-render, but also don't hide. The outside-click paths
    -- (GLOBAL_MOUSE_DOWN, OnEditFocusLost) decide whether to actually
    -- hide based on cursor position. Calling HideResults here also
    -- tore down the panel during slider drags, which is exactly what
    -- we want to avoid.
    -- `force` lets internal callers (pin/unpin from the right-click
    -- menu) re-render after the pin popup briefly stole focus.
    if not force and Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        and not Search:GetSearchFrame().editBox:HasFocus() then
        return
    end
    -- Treat whitespace-only as empty (pins show on focus, not on blank spaces)
    if text then text = strtrim(text) end
    Tooltips:ClearResultTooltips()
    local quickFilter = self:GetQuickFilter()
    if not text or text == "" then
        if ns.Database and ns.Database.CancelDynamicWarmup then
            ns.Database:CancelDynamicWarmup()
        end
        -- Normally only show pins when focused. Forced refreshes (ESC clear,
        -- pin-menu actions) also rebuild pins so stale typed results disappear.
        if force or (Search:GetSearchFrame() and Search:GetSearchFrame().editBox and Search:GetSearchFrame().editBox:HasFocus()) then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    local commandEntries = (not quickFilter) and self:GetSearchBarCommandSuggestionEntries(text)
    if commandEntries then
        self:ShowHierarchicalResults(commandEntries)
        return
    end

    wipe(collapsedNodes)
    local calculatorData = (not quickFilter) and self:EvaluateCalculatorExpression(text) or nil
    local calculatorLauncher = (not quickFilter and not calculatorData)
        and self:GetCalculatorLauncherMatch(text) or nil
    local needsHeavy = not calculatorData and not calculatorLauncher and (
        (ns.Database and ns.Database.QueryNeedsHeavySearchData
            and ns.Database:QueryNeedsHeavySearchData(text))
        or self:QuickFilterNeedsHeavyData(quickFilter)
    )
    if not force and not needsHeavy and ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end
    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Collection items (mounts/toys/pets/outfits/appearance sets) are
    -- skipped when their own filter is off OR the parent Collections
    -- toggle is off. Loot is independent.
    local filters = quickFilter and nil or EasyFind.db.uiSearchFilters
    MaybeLoadHeavySearchData(text, needsHeavy, filters)
    local collectionsOff = filters and filters.collections == false
    local optionsOff = filters and filters.options == false
    local statisticsOff = filters and filters.statistics == false
    local skipCategories
    if filters then
        local mountsOff = collectionsOff or filters.mounts == false
        local toysOff   = collectionsOff or filters.toys == false
        local petsOff   = collectionsOff or filters.pets == false
        local outfitsOff = collectionsOff or filters.outfits == false
        local heirloomsOff = collectionsOff or filters.heirlooms == false
        local appsetsOff = collectionsOff or filters.appearanceSets == false
        local lootOff    = filters.loot == false
        local bagsOff    = filters.bags == false
        local macrosOff  = filters.macros == false
        local gameOptOff  = optionsOff or filters.gameOptions == false
        local addonOptOff = optionsOff or filters.addonOptions == false
        local abilitiesOff = filters.abilities == false
        local bossesOff = filters.bosses == false
        local titlesOff = filters.titles == false
        local gearSetsOff = filters.gearSets == false
        if mountsOff or toysOff or petsOff or outfitsOff or lootOff
           or appsetsOff or bagsOff or macrosOff or gameOptOff or addonOptOff
           or abilitiesOff or bossesOff or heirloomsOff or titlesOff or gearSetsOff
           or statisticsOff then
            skipCategories = SCRATCH.skipCategories
            wipe(skipCategories)
            if mountsOff    then skipCategories["Mount"] = true end
            if toysOff      then skipCategories["Toy"] = true end
            if petsOff      then skipCategories["Pet"] = true end
            if outfitsOff   then skipCategories["Outfit"] = true end
            if heirloomsOff then skipCategories["Heirloom"] = true end
            if lootOff      then skipCategories["Loot"] = true end
            if appsetsOff   then skipCategories["Appearance Set"] = true end
            if bagsOff      then skipCategories["Bag"] = true end
            if macrosOff    then skipCategories["Macro"] = true end
            if gameOptOff   then skipCategories["Game Settings"] = true end
            if addonOptOff  then skipCategories["AddOn Settings"] = true end
            if abilitiesOff then skipCategories["Ability"] = true end
            if bossesOff    then skipCategories["Boss"] = true end
            if titlesOff    then skipCategories["Title"] = true end
            if gearSetsOff  then skipCategories["Gear Set"] = true end
            if statisticsOff then
                skipCategories["Statistic"] = true
                skipCategories["Statistics"] = true
            end
        end
    end
    local results
    if calculatorData or calculatorLauncher then
        results = SCRATCH.calculatorResults
        wipe(results)
    else
        results = ns.Database:SearchUI(text, skipCategories)
    end

    -- Inject user-defined alias hits at the front. Aliases bypass
    -- bucket filters so a saved shortcut is always reachable, even if
    -- the user has the underlying category turned off in the filter
    -- menu. Dedupe against already-present results by data identity.
    if ns.Aliases then
        local aliasMatches = ns.Aliases:GetMatches(text:lower())
        if aliasMatches then
            wipe(SCRATCH.aliasSeen)
            local seen = SCRATCH.aliasSeen
            for _, r in ipairs(results) do seen[r.data] = true end
            for i = #aliasMatches, 1, -1 do
                local hit = aliasMatches[i]
                if not seen[hit.data] then
                    local data = hit.data
                    if data and data.mapSearchResult then
                        local wrapped = {}
                        for k, v in pairs(data) do wrapped[k] = v end
                        wrapped.query = (hit.alias and hit.alias.text) or text
                        data = wrapped
                    end
                    tinsert(results, 1, { data = data, score = math.huge, isAlias = true })
                    seen[hit.data] = true
                end
            end
            wipe(seen)
        end
    end

    if quickFilter then
        wipe(SCRATCH.quickFilterResults)
        local filtered = SCRATCH.quickFilterResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r and self:QuickFilterAllowsData(r.data, quickFilter) then
                fi = fi + 1
                filtered[fi] = r
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Bucket-aware Search filter: drop Search entries whose bucket
    -- (abilities / achievements / currencies / reputations / bags /
    -- options) is unchecked. Base Search entries have no bucket and are
    -- always searchable. Options is a parent toggle: when off, both
    -- gameOptions and addonOptions buckets are treated as off.
    -- abilityHidePassives also drops isPassive ability rows here so
    -- the filter applies regardless of which bucket is on.
    local hidePassives = EasyFind.db.abilityHidePassives
    local hideAchievementHeaders = EasyFind.db.hideAchievementHeaders
    local hideGuildAchievements = EasyFind.db.hideGuildAchievements
    if filters and (filters.abilities == false or filters.bosses == false
                    or filters.achievements == false or filters.statistics == false
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false
                    or filters.titles == false or filters.gearSets == false
                    or filters.talents == false
                    or hidePassives or hideAchievementHeaders or hideGuildAchievements) then
        wipe(SCRATCH.filteredResults)
        local filtered = SCRATCH.filteredResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r.isAlias then
                fi = fi + 1
                filtered[fi] = r
            else
                local d = r.data
                local bucket = Filters:GetUIBucket(d)
                local bucketOff = bucket and filters[bucket] == false
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                local passiveOff = hidePassives and d and d.category == "Ability" and d.isPassive
                local headerOff = hideAchievementHeaders and d
                    and d.category == "Achievement Category"
                local guildAchievementOff = hideGuildAchievements and self:IsGuildAchievementData(d)
                if not passiveOff and not headerOff and not guildAchievementOff
                   and (not bucket or (not bucketOff and not parentOff)) then
                    fi = fi + 1
                    filtered[fi] = r
                end
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Currency filter mode: kept in DB so it can drive bidirectional
    -- sync with the in-game CurrencyFrame's filter dropdown later, but
    -- we deliberately don't prune our own search results here. The
    -- in-game tab shows every currency the character has discovered
    -- (zero-quantity warband-transferable ones included), and an
    -- earlier per-cache `isAccountTransferable` check was hiding some
    -- of those because the flag's truthiness varied across builds.
    -- Showing everything keeps search at least as inclusive as the
    -- in-game tab regardless of what mode is selected.

    local mapResults
    if not calculatorData and not calculatorLauncher and ns.MapSearch and ns.MapSearch.SearchForUI
       and ((quickFilter and quickFilter.key == "map")
            or (not quickFilter and filters and filters.map ~= false)) then
        mapResults = ns.MapSearch:SearchForUI(text)
    end

    wipe(flatCombined)
    local combined = flatCombined
    if calculatorData then
        combined[#combined + 1] = { data = calculatorData, score = math.huge }
    elseif calculatorLauncher then
        combined[#combined + 1] = { data = calculatorLauncher, score = math.huge }
    end
    for ri = 1, #results do combined[#combined + 1] = results[ri] end
    if mapResults then
        for ri = 1, #mapResults do combined[#combined + 1] = mapResults[ri] end
    end
    if #combined > 1 then tsort(combined, FlatNameLess) end

    -- Hard cap on visible results. The scoring step already ranks by
    -- relevance; everything past the cap is noise the user has to scroll
    -- through. Pinned items aren't in this set (they only show on empty
    -- query), so the cap is a clean top-N over the actual search match
    -- list. 15 matches the original uiMaxResults default.
    local TOP_N = 15
    if #combined > TOP_N then
        for ri = #combined, TOP_N + 1, -1 do combined[ri] = nil end
    end

    -- Inline achievement results: drive Blizzard's indexed achievement
    -- search and surface its results directly in our dropdown. First
    -- call for a given query kicks off the (already-built) index lookup
    -- and returns nothing; ACHIEVEMENT_SEARCH_UPDATED fires next frame
    -- and we re-render with the cached results. Score each one through
    -- ScoreName so they interleave naturally with mount / toy / setting
    -- hits ranked off the same query, instead of clumping at a fixed
    -- band.
    if not calculatorData and not calculatorLauncher and text ~= ""
       and ((quickFilter and quickFilter.key == "achievements")
            or (not quickFilter and (not filters or filters.achievements ~= false))) then
        local achHits = self:RequestAchievementSearch(text)
        if achHits and ns.Database and ns.Database.ScoreName then
            local lowerQ = slower(text)
            local qLen = #lowerQ
            -- Blizzard's index returns matches across name + description
            -- + criteria; we only want name matches here. Base Search entries
            -- still cover direct navigation to achievement categories, so
            -- drop anything ScoreName can't rank against the achievement
            -- name itself. Re-check IsStatisticAchievement: the cache can
            -- predate stats data loading and admit stat IDs.
            for ai = 1, #achHits do
                local entry = achHits[ai]
                local score = ns.Database:ScoreName(entry.nameLower, lowerQ, qLen)
                if score and score > 0
                   and not (hideGuildAchievements and self:IsGuildAchievementData(entry))
                   and not (statisticsOff and entry.achievementID
                            and ns.Database:IsStatisticAchievement(entry.achievementID)) then
                    combined[#combined + 1] = { data = entry, score = score }
                end
            end
        end
    end

    local n = 0
    for ri = 1, #combined do
        local d = combined[ri] and combined[ri].data
        if d then
            n = n + 1
            local e = flatEntries[n]
            if not e then
                e = {}
                flatEntries[n] = e
            end
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.isPinned = (not d.noPin and IsUIItemPinned(d)) and true or false
            e.data = d
        end
    end
    for i = n + 1, #flatEntries do
        flatEntries[i] = nil
    end

    -- Stable partition: pinned matches float to the top, non-pinned
    -- follow. Each group keeps its score-sorted order. Pinned items
    -- the user has stuck stay at the head of every relevant search.
    if n > 1 then
        local pinnedBuf = SCRATCH.pinnedFlat or {}
        SCRATCH.pinnedFlat = pinnedBuf
        local otherBuf = SCRATCH.otherFlat or {}
        SCRATCH.otherFlat = otherBuf
        wipe(pinnedBuf)
        wipe(otherBuf)
        for i = 1, n do
            local e = flatEntries[i]
            if e.isPinned then
                pinnedBuf[#pinnedBuf + 1] = e
            else
                otherBuf[#otherBuf + 1] = e
            end
        end
        if #pinnedBuf > 0 and #pinnedBuf < n then
            local out = 0
            for i = 1, #pinnedBuf do
                out = out + 1
                flatEntries[out] = pinnedBuf[i]
            end
            for i = 1, #otherBuf do
                out = out + 1
                flatEntries[out] = otherBuf[i]
            end
        end
    end

    self:ShowHierarchicalResults(flatEntries)
end
