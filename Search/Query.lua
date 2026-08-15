local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Tooltips = ns.ResultTooltips
local Filters = ns.Filters
local Utils = ns.Utils
local UIPins = ns.UIPins
local SearchText = ns.SearchText

local ipairs, pairs = Utils.ipairs, Utils.pairs
local InCombatLockdown = InCombatLockdown
local slower = SearchText.Normalize
local tinsert, tsort = Utils.tinsert, Utils.tsort
local wipe = wipe

local IsUIItemPinned = UIPins.IsPinned
local collapsedNodes = Results._collapsedNodes
local flatEntries = Results._flatEntries
local flatCombined = Results._flatCombined
local SCRATCH = Results._SCRATCH
local SearchEngine = ns.SearchEngine

local function FlatNameLess(ra, rb)
    local sa, sb = ra.score or 0, rb.score or 0
    if sa ~= sb then return sa > sb end
    local na, nb = ra.data.name or "", rb.data.name or ""
    if #na ~= #nb then return #na < #nb end
    return na < nb
end
-- Re-run the active search after async data changes (provider loads,
-- item-info arrivals, Database cache resets). A quick-filter browse
-- ("@outfits") has empty text but still needs the re-search once its
-- data finishes loading in the background.
function Search:RefreshActiveSearch()
    local frame = Search:GetSearchFrame()
    if not (frame and frame:IsShown()) then return end
    local typed = Search:GetTypedQuery()
    if typed ~= "" or Search:GetQuickFilter() then
        Search:OnSearchTextChanged(typed, true)
    end
end

local searchRefreshQueued = false
-- Repaint only. Providers that changed the dataset already invalidated
-- through Database:ResetSearchCache, whose coalesced deferred re-run is
-- the single ordered repaint path. Routing THIS callback through the
-- reset nuked the incremental-narrowing caches on every async arrival --
-- item-info responses stream in bursts for seconds after a loot query,
-- so each burst forced full rescans and repaints: visible keystroke lag
-- and result lists swapping after they were already shown.
local function RefreshSearchAfterProviderLoad(anyChanged)
    if not anyChanged then return end
    if searchRefreshQueued then return end
    searchRefreshQueued = true
    Utils.SafeAfter(0, function()
        searchRefreshQueued = false
        Search:RefreshActiveSearch()
        -- A provider finishing may have added the row a shortkey points at;
        -- rebind any shortkeys skipped because their provider had not loaded
        -- yet. No-op once every shortkey resolves.
        if ns.Shortkeys and ns.Shortkeys.ReapplyIfPending then
            ns.Shortkeys:ReapplyIfPending()
        end
    end)
end

-- GET_ITEM_INFO_RECEIVED arrives async after the client requests item
-- data from the server. Loot stat enrichment ("haste ring") queues the
-- item when GetItemStats returns nil for an uncached item; this handler
-- retries enrichment and refreshes the active search so newly-matchable
-- loot surfaces without the user having to retype.
--
-- Throttled with SafeAfter(0.75) so a burst of arrivals coalesces into
-- one search refresh instead of N. Not snappier: each refresh is a full
-- cold re-score plus render, and a fresh loot cache enriches hundreds of
-- items in a stream; a short coalesce window turns that into a sustained
-- frame-rate collapse while a loot search is open.
local itemInfoFrame = CreateFrame("Frame")
local pendingItemRefresh = false
local function RefreshSearchAfterItemInfo()
    pendingItemRefresh = false
    RefreshSearchAfterProviderLoad(true)
end
itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
    if not ns.Database or not ns.Database.ResolvePendingStatEnrichment then return end
    local enriched = ns.Database:ResolvePendingStatEnrichment(itemID, success)
    if enriched and not pendingItemRefresh then
        pendingItemRefresh = true
        Utils.SafeAfter(0.75, RefreshSearchAfterItemInfo)
    end
end)

-- The user-typed query, excluding any inline-autocomplete suffix. Every
-- programmatic re-search must use this instead of editBox:GetText(): with
-- a suggestion showing, GetText() returns the completed candidate ("amani
-- battle bear" for typed "amani"), and re-searching the completed text
-- silently narrows the live results to the suggestion.
function Search:GetTypedQuery()
    local sf = self:GetSearchFrame()
    local eb = sf and sf.editBox
    if not eb then return "" end
    if eb.HasAutocomplete and eb.HasAutocomplete() and eb.GetTypedText then
        return eb.GetTypedText() or ""
    end
    return eb:GetText() or ""
end

-- Stable partition: pinned matches float to the top, non-pinned follow.
-- Each group keeps its score-sorted order. ONE implementation for every
-- rendered list (main results and the "/" command palette) so pin
-- behavior cannot drift between them.
local function FloatPinnedFirst(list, n)
    if n <= 1 then return end
    local pinnedBuf = SCRATCH.pinnedFlat or {}
    SCRATCH.pinnedFlat = pinnedBuf
    local otherBuf = SCRATCH.otherFlat or {}
    SCRATCH.otherFlat = otherBuf
    wipe(pinnedBuf)
    wipe(otherBuf)
    for i = 1, n do
        local e = list[i]
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
            list[out] = pinnedBuf[i]
        end
        for i = 1, #otherBuf do
            out = out + 1
            list[out] = otherBuf[i]
        end
    end
end

function Search:OnSearchTextChanged(text, force)
    -- The search UI is dormant in combat (the bar hides at combat start
    -- and cannot reopen), and rendering results would resize/show frames
    -- that ancestor secure row buttons -- protected operations. Any stray
    -- programmatic call in combat is a silent no-op.
    if InCombatLockdown() then return end
    -- Central guard for the whole caller class: if the incoming text is
    -- the autocomplete-COMPLETED editbox text while a suggestion is live,
    -- search what the user actually typed instead. Callers that pass
    -- editBox:GetText() during a suggestion would otherwise narrow the
    -- results to the suggestion. Accepted suggestions are unaffected
    -- (accepting updates the typed text, so HasAutocomplete is false).
    if text and text ~= "" then
        local guardFrame = Search:GetSearchFrame()
        local guardBox = guardFrame and guardFrame.editBox
        if guardBox and guardBox.HasAutocomplete and guardBox.HasAutocomplete()
           and guardBox.GetTypedText and text == (guardBox:GetText() or "") then
            text = guardBox.GetTypedText() or text
        end
    end
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
    if (not text or text == "") and not quickFilter then
        if ns.Database and ns.Database.CancelDynamicWarmup then
            ns.Database:CancelDynamicWarmup()
        end
        -- Pins stay visible whenever there ARE pins, not only while focused:
        -- they show on bar-open before any typing, and clicking a bar control
        -- (filter or apps button) drops editbox focus and re-runs this path --
        -- which must not then hide the pins the user is looking at. A truly
        -- outside click is handled by the results panel's own click closer.
        local hasFocus = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
            and Search:GetSearchFrame().editBox:HasFocus()
        local hasPins = Results.HasPinnedItems and Results:HasPinnedItems()
        if force or hasFocus or hasPins then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    local activeFilters = EasyFind.db.uiSearchFilters
    -- NOT `quickFilter and nil or activeFilters`: `x and nil or y` always
    -- yields y in Lua, which silently fed the filter menu into the engine
    -- under a quick filter and blocked its provider from loading.
    local providerFilters = not quickFilter and activeFilters or nil
    local providerContext = SearchEngine and SearchEngine:BuildContext(text, quickFilter, providerFilters)
    local explicitStatistics = providerContext and SearchEngine
        and SearchEngine.LooksLikeStatistics and SearchEngine:LooksLikeStatistics(providerContext)
    local explicitBosses = providerContext and SearchEngine
        and SearchEngine.LooksLikeBosses and SearchEngine:LooksLikeBosses(providerContext)

    local commandsOff = activeFilters and activeFilters.commands == false
    local commandEntries = (not quickFilter) and (not commandsOff)
        and self:GetSearchBarCommandSuggestionEntries(text)
    if commandEntries then
        FloatPinnedFirst(commandEntries, #commandEntries)
        self:ShowHierarchicalResults(commandEntries)
        return
    end

    wipe(collapsedNodes)
    local calculatorData = (not quickFilter) and self:EvaluateCalculatorExpression(text) or nil
    local calculatorLauncher = (not quickFilter and not calculatorData)
        and self:GetCalculatorLauncherMatch(text) or nil
    -- Inline answers ("gold", "ilvl", "durability"): a live value pinned
    -- above the results, which keep flowing beneath it.
    local answerEntry = (not quickFilter and not calculatorData) and ns.Answers
        and ns.Answers.GetAnswerEntry
        and ns.Answers:GetAnswerEntry(text) or nil
    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Collection items (mounts/toys/pets/outfits/appearance sets) are
    -- skipped when their own filter is off OR the parent Collections
    -- toggle is off. Loot is independent. Same nil-under-quick-filter
    -- value the engine got: a quick filter ignores the filter menu.
    local filters = providerFilters
    local optionsOff = filters and filters.options == false
    local statisticsOff = filters and filters.statistics == false and not explicitStatistics
    local skipCategories
    if filters then
        -- Category skip set derives from the shared map so the filter menu,
        -- the providers, and this cascade cannot drift apart.
        if ns.CategoryMap.BuildSkipCategories(filters, SCRATCH.skipCategories,
                explicitStatistics, explicitBosses) then
            skipCategories = SCRATCH.skipCategories
        end
    end
    local results
    if calculatorData or calculatorLauncher then
        results = SCRATCH.calculatorResults
        wipe(results)
    elseif quickFilter and (not text or text == "") then
        -- Quick-filter browse: no query text, so surface the whole category
        -- (e.g. "@outfits" lists every outfit). SearchUI returns nothing for an
        -- empty query, so collect the category's entries directly here.
        SCRATCH.browseResults = SCRATCH.browseResults or {}
        results = SCRATCH.browseResults
        wipe(results)
        local data = ns.Database.uiSearchData
        for i = 1, #data do
            if self:QuickFilterAllowsData(data[i], quickFilter) then
                results[#results + 1] = { data = data[i], score = 0 }
            end
        end
    else
        results = ns.Database:SearchUI(text, skipCategories)
    end
    if providerContext and not calculatorData and not calculatorLauncher then
        SearchEngine:RequestProviders(providerContext, RefreshSearchAfterProviderLoad, #results)
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

    -- Blacklist gate: the ONE suppression point for main-search results.
    -- Runs after alias injection on purpose (blacklist beats an alias
    -- pointing at the same row) and copies into scratch like the other
    -- passes; `results` may be the engine's cached candidate set and must
    -- not be mutated. Free when the blacklist is empty.
    if ns.Blacklist and ns.Blacklist:HasAny() then
        SCRATCH.blacklistResults = SCRATCH.blacklistResults or {}
        wipe(SCRATCH.blacklistResults)
        local filtered = SCRATCH.blacklistResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r and not ns.Blacklist:Contains(r.data) then
                fi = fi + 1
                filtered[fi] = r
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
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
    local macroGeneralOff = EasyFind.db.macroFilterGeneral == false
    local macroCharOff = EasyFind.db.macroFilterChar == false
    local bossDungeonOff = EasyFind.db.bossFilterDungeon == false
    local bossRaidOff = EasyFind.db.bossFilterRaid == false
    local hideJunk = EasyFind.db.bagHideJunk == true
    -- Statistics carry a live value, so this is filtered HERE rather than at
    -- populate: the populate path also writes the persisted statistic cache,
    -- and filtering there would bake the choice into the cache and force a
    -- re-scan on every change. Query-time also keeps it honest as values
    -- change during play. "all" costs nothing -- the gate below stays off.
    local statMode = EasyFind.db.statisticFilterMode
    if statMode == "all" then statMode = nil end
    local specRowsOff = EasyFind.db.talentShowSpecs == false
    local loadoutRowsOff = EasyFind.db.talentShowLoadouts == false
    local commandNativeOff = EasyFind.db.commandShowNative == false
    local commandCustomOff = EasyFind.db.commandShowCustom == false
    local bossesFilterOff = filters and filters.bosses == false and not explicitBosses
    local statisticsFilterOff = filters and filters.statistics == false and not explicitStatistics
    if filters and (filters.abilities == false or bossesFilterOff
                    or filters.achievements == false or statisticsFilterOff
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.bank == false
                    or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false
                    or filters.titles == false or filters.gearSets == false
                    or filters.talents == false or filters.commands == false
                    or hidePassives or hideAchievementHeaders or hideGuildAchievements
                    or macroGeneralOff or macroCharOff or bossDungeonOff or bossRaidOff
                    or hideJunk or commandNativeOff or commandCustomOff
                    or statMode or specRowsOff or loadoutRowsOff) then
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
                if (explicitStatistics and bucket == "statistics")
                   or (explicitBosses and bucket == "bosses") then
                    bucketOff = false
                end
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                local passiveOff = hidePassives and d and d.category == "Ability" and d.isPassive
                local headerOff = hideAchievementHeaders and d
                    and d.category == "Achievement Category"
                local guildAchievementOff = hideGuildAchievements and self:IsGuildAchievementData(d)
                local macroTypeOff = d and d.category == "Macro"
                    and ((d.macroIsChar and macroCharOff) or (not d.macroIsChar and macroGeneralOff))
                local bossTypeOff = d and d.category == "Boss"
                    and ((d.isRaidBoss and bossRaidOff) or (not d.isRaidBoss and bossDungeonOff))
                local junkOff = hideJunk and d and d.category == "Bag" and d.quality == 0
                local statOff = false
                if statMode and d and d.statisticID then
                    local _, hasValue = ns.GetStatisticValue(d.statisticID)
                    statOff = (statMode == "recorded") ~= hasValue
                end
                local talentSwapOff = d and ((d.specSetIndex and specRowsOff)
                    or (d.loadoutConfigID and loadoutRowsOff))
                local commandTypeOff = d and d.category == "Command"
                    and ((d.isNativeCommand and commandNativeOff) or (not d.isNativeCommand and commandCustomOff))
                if not passiveOff and not headerOff and not guildAchievementOff
                   and not macroTypeOff and not bossTypeOff and not junkOff
                   and not commandTypeOff and not statOff and not talentSwapOff
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
        -- Math row at the top; launcher row sits beneath it so the user
        -- can open the popup with the current expression. Two distinct
        -- scores so the math row always sorts above (math.huge - 1 is
        -- still math.huge in IEEE doubles, so use a finite huge instead).
        combined[#combined + 1] = { data = calculatorData, score = math.huge }
        combined[#combined + 1] = { data = ns.Calculator._calculator.LAUNCHER, score = 1e308 }
    elseif calculatorLauncher then
        combined[#combined + 1] = { data = calculatorLauncher, score = math.huge }
    end
    if answerEntry then
        combined[#combined + 1] = { data = answerEntry, score = math.huge }
    end
    for ri = 1, #results do combined[#combined + 1] = results[ri] end
    if mapResults then
        for ri = 1, #mapResults do combined[#combined + 1] = mapResults[ri] end
    end
    -- Catalog items: the full game item DB (Search/ItemSearch.lua scans the
    -- packed blob). Appended BEFORE the sort/cap so they compete for the
    -- TOP_N slots by the same ScoreName relevance rather than flooding past
    -- it. Gated on the General Catalog sub-filter (@gen, or its @items
    -- umbrella parent); IsProviderFilterOff walks the items-parent cascade
    -- so unchecking Items hides all three overlays. English-primary; display
    -- name and icon resolve live at render.
    if not calculatorData and not calculatorLauncher and text ~= "" and ns.ItemSearch
       and ns.Database and ns.Database.ScoreName
       and ((quickFilter and (quickFilter.key == "items" or quickFilter.key == "catalog"))
            or (not quickFilter and (not filters
                 or not ns.CategoryMap.IsProviderFilterOff(filters, "catalog")))) then
        local itemHits = ns.ItemSearch:Search(text, function(nameLower, ql, qLen)
            return ns.Database:ScoreName(nameLower, ql, qLen)
        end)
        if itemHits then
            for ii = 1, #itemHits do combined[#combined + 1] = itemHits[ii] end
        end
    end
    if #combined > 1 then tsort(combined, FlatNameLess) end

    -- Hard cap on visible results. The scoring step already ranks by
    -- relevance; everything past the cap is noise the user has to scroll
    -- through. Pinned items aren't in this set (they only show on empty
    -- query), so the cap is a clean top-N over the actual search match
    -- list. 15 matches the original uiMaxResults default.
    -- Fill the cap from the sorted list, skipping catalog rows this client
    -- cannot resolve. Done HERE rather than in ItemSearch so the resolvable
    -- check runs on roughly the number of rows actually shown, not on every
    -- scored match -- a three-letter query can match thousands.
    local TOP_N = 15
    local kept = 0
    for ri = 1, #combined do
        local d = combined[ri].data
        if not (d and d.catalogItem and not ns.ItemSearch:IsResolvable(d.itemID)) then
            kept = kept + 1
            combined[kept] = combined[ri]
            if kept >= TOP_N then break end
        end
    end
    for ri = #combined, kept + 1, -1 do combined[ri] = nil end

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

    FloatPinnedFirst(flatEntries, n)

    self:ShowHierarchicalResults(flatEntries)
end
