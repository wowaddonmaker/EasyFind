local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapSearchData = ns.MapSearchData
local Search = ns.MapSearchSearch

local pairs, ipairs = Utils.pairs, Utils.ipairs
local tinsert, tsort, tremove = Utils.tinsert, Utils.tsort, Utils.tremove
local slower = Utils.slower
local mmin, mmax = Utils.mmin, Utils.mmax
local wipe = wipe

local CATEGORIES = MapSearchData.CATEGORIES

local GetBestMapForUnit = C_Map.GetBestMapForUnit

local GetCategoryIcon = Search.GetCategoryIcon
local GetFilterBucket = Search.GetFilterBucket
local GetMapPinKey = Search.GetMapPinKey
local MapTabFlightPathsEnabled = Search.MapTabFlightPathsEnabled
local WipeScratchTables = Search.WipeScratchTables
local GetNameLower = Search.GetNameLower
local PreparePOI = Search.PreparePOI
local BuildEntranceLookup = Search.BuildEntranceLookup
local EnrichZoneWithEntrance = Search.EnrichZoneWithEntrance
local AppendLocalSearchSources = Search.AppendLocalSearchSources
local AppendZoneSearchResults = Search.AppendZoneSearchResults
local AppendGlobalInstanceSearchSources = Search.AppendGlobalInstanceSearchSources
local ReleaseGlobalMapCaches = Search.ReleaseGlobalMapCaches
local CollectMapGarbage = Search.CollectMapGarbage

local reuseAllPOIs = Search.reuseAllPOIs
local reuseZoneNames = Search.reuseZoneNames
local reuseExistingNames = Search.reuseExistingNames
local reuseFilteredResults = Search.reuseFilteredResults
local reusePinnedKeys = Search.reusePinnedKeys
local reusePinned = Search.reusePinned
local reuseFiltered = Search.reuseFiltered
local reuseSearchResults = Search.reuseSearchResults
local reuseSearchSeen = Search.reuseSearchSeen
local reuseSearchDuplicates = Search.reuseSearchDuplicates
local reuseUISearchPOIs = Search.reuseUISearchPOIs
local reuseUISearchExistingNames = Search.reuseUISearchExistingNames
local reuseUISearchZoneNames = Search.reuseUISearchZoneNames
local reuseUISearchFiltered = Search.reuseUISearchFiltered
local reuseUISearchResults = Search.reuseUISearchResults
local reuseUISearchResultData = Search.reuseUISearchResultData
local UI_MAP_RESULT_CAP = Search.UI_MAP_RESULT_CAP
-- Pure result computation: takes a query and a global-mode flag, returns the
-- ranked + filtered + pin-merged result list. No rendering. Safe to call
-- from MapTab or any other renderer that wants both local and global sets.
-- Temporarily sets the module-level `Search.isGlobalSearch` so transitively-called
-- helpers (SearchZones, GetGlobalInstanceCache, ...) see the requested mode.
function MapSearch:BuildResults(text, isGlobal, skipPins)
    local savedGlobalFlag = Search.isGlobalSearch
    Search.isGlobalSearch = isGlobal and true or false

    -- Search for zones (works for both local and global mode)
    local zoneMatches = {}
    if self:IsOnContinentMap() or isGlobal then
        zoneMatches = self:SearchZones(text)
    end

    wipe(reuseAllPOIs)
    wipe(reuseZoneNames)
    local allPOIs = reuseAllPOIs
    local zoneNames = reuseZoneNames

    local groupedZones = self:GroupZonesByParent(zoneMatches)
    AppendZoneSearchResults(allPOIs, zoneNames, groupedZones)

    -- Global search: zones + dungeon/raid/delve entrances (skip service POIs)
    --
    -- Instances get ONE authoritative source: the global instance cache.
    -- Dungeon-type zone results from SearchZones are suppressed when the
    -- cache covers them. Cache entries are promoted to zone-style display
    -- (with full breadcrumb paths) using a mapID-to-path lookup.
    if isGlobal then
        AppendGlobalInstanceSearchSources(self, allPOIs, zoneNames)

        if MapTabFlightPathsEnabled() then
            local allFMs = self:ScanAllFlightMasters()
            for i = 1, #allFMs do
                local fm = allFMs[i]
                fm.score = nil
                fm.duplicateKey = nil
                fm.allInstances = nil
                if not zoneNames[GetNameLower(fm)] then
                    allPOIs[#allPOIs + 1] = fm
                end
            end
        end
    else
        wipe(reuseExistingNames)
        local existingNames = reuseExistingNames
        local dungeonEntrances = AppendLocalSearchSources(self, allPOIs, existingNames, zoneNames, nil, false)

        local entranceLookup = BuildEntranceLookup(dungeonEntrances)
        for _, poi in ipairs(allPOIs) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[GetNameLower(poi)]
                if entrance then
                    EnrichZoneWithEntrance(poi, entrance)
                end
            end
        end

        -- Local mode normally only sees POIs in the current zone, so
        -- abbreviations like "rfc" -> Ragefire Chasm fall flat unless
        -- the player happens to be standing in Orgrimmar. The UI search
        -- bar always pulls the global instance cache; the map search
        -- bar should match that for consistency. Add globally-cached
        -- dungeon / raid / delve entrances as additional candidates so
        -- a name or abbreviation hit surfaces them regardless of
        -- current zone. They still get scored alongside local POIs.
    end

    local results = self:SearchPOIs(allPOIs, text)

    -- Apply global search filters (zones / dungeons / raids / delves)
    if isGlobal then
        local filters = EasyFind.db.globalSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            local dominated = false
            if r.isZone and filters.zones == false then
                dominated = true
            elseif r.category == "dungeon" and filters.dungeons == false then
                dominated = true
            elseif r.category == "raid" and filters.raids == false then
                dominated = true
            elseif r.category == "delve" and filters.delves == false then
                dominated = true
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    else
        -- Apply local search filters (instances / travel / services / rares / treasures)
        local filters = EasyFind.db.localSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            local dominated = false
            local cat = r.category
            local parentCat = cat and CATEGORIES[cat] and CATEGORIES[cat].parent
            if (cat == "dungeon" or cat == "raid" or cat == "delve" or parentCat == "instance") and filters.instances == false then
                dominated = true
            elseif (cat == "flightmaster" or cat == "zeppelin" or cat == "boat" or cat == "portal" or cat == "tram" or parentCat == "travel") and filters.travel == false then
                dominated = true
            elseif (parentCat == "service" or cat == "service") and filters.services == false then
                dominated = true
            elseif cat == "rare" and filters.rares == false then
                dominated = true
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    end

    -- Prepend pinned items with header (always shown at top regardless of query).
    -- Callers that render their own pinned section (e.g. MapTab) pass skipPins.
    local pins = not skipPins and EasyFind.db.pinnedMapItems or nil
    if pins and #pins > 0 then
        wipe(reusePinnedKeys)
        wipe(reusePinned)
        local pinnedKeys = reusePinnedKeys
        local pinned = reusePinned
        -- Header row
        tinsert(pinned, { isPinHeader = true, name = "Pinned" })
        if not EasyFind.db.mapPinsCollapsed then
            for _, pin in ipairs(pins) do
                local copy = {}
                for k, v in pairs(pin) do copy[k] = v end
                copy.isPinned = true
                tinsert(pinned, copy)
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        else
            for _, pin in ipairs(pins) do
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        end
        wipe(reuseFiltered)
        local filtered = reuseFiltered
        for _, r in ipairs(results) do
            if not pinnedKeys[GetMapPinKey(r)] then
                tinsert(filtered, r)
            end
        end
        for _, r in ipairs(filtered) do
            tinsert(pinned, r)
        end
        results = pinned
    end

    Search.isGlobalSearch = savedGlobalFlag
    return results
end

-- Per-query cache for SearchPOIs, mirrors the SearchZones cache. Keeps
-- recent queries so backspace re-hits cached results instead of doing
-- a fresh scan. Extension of the last query still narrows from its
-- match set.
local SEARCH_CACHE_MAX = 32
local searchPoisCache = {
    local_  = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
    global_ = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
}
local function ResetSearchPoisCache()
    for _, c in pairs(searchPoisCache) do
        wipe(c.entries); wipe(c.order); c.lastQuery = ""; c.lastCategory = nil
    end
end
ns.MapSearch.ResetSearchPoisCache = ResetSearchPoisCache

local function ClearMapSearchScratch()
    WipeScratchTables()
end

function MapSearch:TrimSearchMemory()
    if self.ResetSearchZonesCache then self.ResetSearchZonesCache() end
    ResetSearchPoisCache()
    ReleaseGlobalMapCaches()
    Search.ClearLocalCaches()
    ClearMapSearchScratch()
    CollectMapGarbage()
end

function MapSearch:ReleaseIdleSearchMemory()
    ReleaseGlobalMapCaches()
    Search.ClearLocalCaches()
    ClearMapSearchScratch()
    CollectMapGarbage()
end

local function POIResultLess(a, b)
    if a.score == b.score then
        if a.isZone and not b.isZone then return true end
        if b.isZone and not a.isZone then return false end
        return (a.name or "") < (b.name or "")
    end
    return a.score > b.score
end

local function GetPOIDuplicateKey(poi)
    return (poi.name or "") .. (poi.category or "")
        .. (poi.isZone and (poi.pathPrefix or "") or "")
end

local function ResolveSearchCache(query, matchedCategory, defaultCandidates)
    local cacheKey = Search.isGlobalSearch and "global_" or "local_"
    local cache = searchPoisCache[cacheKey]
    local cachedHit = cache.entries[query]
    if cachedHit and cachedHit.matchedCategory == matchedCategory then
        cache.lastQuery = query
        cache.lastCategory = matchedCategory
        return cache, cachedHit.results, true, false
    end

    if cache.lastQuery ~= ""
       and #query > #cache.lastQuery
       and query:sub(1, #cache.lastQuery) == cache.lastQuery
       and cache.lastCategory == matchedCategory then
        local previous = cache.entries[cache.lastQuery]
        if previous then
            return cache, previous.results, false, true
        end
    end

    return cache, defaultCandidates, false, false
end

local function ClearCachedCandidateScores(candidates)
    for i = 1, #candidates do
        candidates[i].score = nil
    end
end

local function ScorePOIForQuery(poi, query)
    if poi.isZone and poi.score then return poi.score end

    local score = ns.Database:ScoreName(GetNameLower(poi), query, #query)
    if poi.keywords then
        if not poi.kwLower then PreparePOI(poi) end
        score = mmax(score, ns.Database:ScoreKeywords(poi.kwLower, query, #query))
    end
    return score
end

local function AddScoredPOI(results, seen, duplicates, poi, key, score)
    if not duplicates[key] then duplicates[key] = {} end
    tinsert(duplicates[key], poi)

    if seen[key] then return end
    seen[key] = true
    poi.score = score
    poi.duplicateKey = key
    tinsert(results, poi)
end

local function AppendNameMatches(results, seen, duplicates, candidates, query)
    for _, poi in ipairs(candidates) do
        local score = ScorePOIForQuery(poi, query)
        if score >= 50 then
            AddScoredPOI(results, seen, duplicates, poi, GetPOIDuplicateKey(poi), score)
        end
    end
end

local function GetCategoryMatchScore(poi, matchedCategory, relatedCategories)
    if poi.category == matchedCategory then return 150 end
    if relatedCategories then
        for _, category in ipairs(relatedCategories) do
            if poi.category == category then return 100 end
        end
    end
    return 0
end

local function AppendCategoryMatches(results, seen, duplicates, pois, matchedCategory, relatedCategories)
    if not matchedCategory then return end

    for _, poi in ipairs(pois) do
        if poi.category then
            local key = GetPOIDuplicateKey(poi)
            if not seen[key] then
                local score = GetCategoryMatchScore(poi, matchedCategory, relatedCategories)
                if score > 0 then
                    AddScoredPOI(results, seen, duplicates, poi, key, score)
                end
            end
        end
    end
end

local function AttachDuplicateSets(results, duplicates)
    for _, result in ipairs(results) do
        if not result.allInstances and result.duplicateKey and duplicates[result.duplicateKey] then
            result.allInstances = duplicates[result.duplicateKey]
        end
    end
end

local function StoreSearchResults(cache, query, matchedCategory, results)
    if #results == 0 then return end

    local snapshot = {}
    for i = 1, #results do snapshot[i] = results[i] end
    if cache.entries[query] == nil then
        cache.order[#cache.order + 1] = query
        if #cache.order > SEARCH_CACHE_MAX then
            local oldest = tremove(cache.order, 1)
            cache.entries[oldest] = nil
        end
    end
    cache.entries[query] = { matchedCategory = matchedCategory, results = snapshot }
end

function MapSearch:SearchPOIs(pois, query, noCache)
    query = slower(query)
    if ns.Database and ns.Database.NormalizeSearchQuery then
        query = ns.Database:NormalizeSearchQuery(query)
    end
    wipe(reuseSearchResults)
    wipe(reuseSearchSeen)
    wipe(reuseSearchDuplicates)
    local results = reuseSearchResults
    local seen = reuseSearchSeen
    local duplicates = reuseSearchDuplicates

    local matchedCategory = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or nil

    local cache
    local candidates = pois
    local candidatesAreCached = false
    if not noCache then
        local cachedHit
        cache, candidates, cachedHit, candidatesAreCached = ResolveSearchCache(query, matchedCategory, pois)
        if cachedHit then return candidates end
    end

    if candidatesAreCached then
        ClearCachedCandidateScores(candidates)
    end

    AppendNameMatches(results, seen, duplicates, candidates, query)
    AppendCategoryMatches(results, seen, duplicates, pois, matchedCategory, relatedCategories)
    AttachDuplicateSets(results, duplicates)

    tsort(results, POIResultLess)

    if noCache then return results end

    StoreSearchResults(cache, query, matchedCategory, results)
    cache.lastQuery = query
    cache.lastCategory = matchedCategory

    return results
end

-- Search for the UI search bar, mirroring the real map search pipeline.
-- Gathers the same POI sources (dynamic, static, entrances, flight masters),
-- runs SearchPOIs with the same scoring, and returns results for UI display.
function MapSearch:SearchForUI(query)
    if not query or query == "" or #query < 2 then return nil end
    if self.HasWorldZoneCache and not self:HasWorldZoneCache() then return nil end

    -- Use the player's current zone as the local anchor so UI-bar map
    -- results reflect what's actually around them rather than wherever
    -- the WorldMapFrame happens to be viewing.
    local searchMapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())

    -- Gather POIs from both local and global sources in a single pass
    -- so the UI bar shows results regardless of zone scope, matching
    -- how the MapTab surfaces both "This Zone" and "Across the World"
    -- content without asking the user to pick.
    wipe(reuseUISearchPOIs)
    wipe(reuseUISearchExistingNames)
    local pois = reuseUISearchPOIs
    local existingNames = reuseUISearchExistingNames

    do
        AppendLocalSearchSources(self, pois, existingNames, nil, searchMapID, true)
    end

    -- Always also pull in global zone + instance results. Dedup against
    -- existingNames so the local sources take priority for any POI that
    -- exists in both (same ownership rule as MapTab's local-first pass).
    do
        local savedGlobalFlag = Search.isGlobalSearch
        Search.isGlobalSearch = true
        local zoneMatches = self:SearchZones(query)
        Search.isGlobalSearch = savedGlobalFlag
        local groupedZones = self:GroupZonesByParent(zoneMatches)
        wipe(reuseUISearchZoneNames)
        local zoneNames = reuseUISearchZoneNames

        AppendZoneSearchResults(pois, zoneNames, groupedZones, existingNames)

        -- Always build/use the instance cache so dungeons / raids / delves
        -- show up in UI search alongside zones and POIs.
        AppendGlobalInstanceSearchSources(self, pois, zoneNames)
    end

    if #pois == 0 then return nil end

    -- Run the same scoring pipeline as the real map search
    local scored = self:SearchPOIs(pois, query, true)
    if not scored or #scored == 0 then return nil end

    -- Apply the MapTab cog filters so the UI search bar surfaces the
    -- same buckets the user picked there. Mirrors FilterAndDedupe in
    -- MapSearch/MapTab.lua: any POI whose bucket is explicitly disabled
    -- (filters[bucket] == false) drops out. Buckets without a saved
    -- value default to enabled, same convention DB_DEFAULTS uses.
    do
        local mtFilters = EasyFind.db.mapTabFilters
        if mtFilters then
            wipe(reuseUISearchFiltered)
            local filtered = reuseUISearchFiltered
            for _, r in ipairs(scored) do
                local bucket = GetFilterBucket(r)
                if mtFilters[bucket] ~= false then
                    filtered[#filtered + 1] = r
                end
            end
            scored = filtered
            if #scored == 0 then return nil end
        end
    end

    local results = reuseUISearchResults
    local resultCap = mmin(#scored, UI_MAP_RESULT_CAP)
    for ri = 1, resultCap do
        local r = scored[ri]
        local cat = r.category or "location"
        local d = reuseUISearchResultData[ri]
        if not d then
            d = {}
            reuseUISearchResultData[ri] = d
        end
        d.name = r.name
        d.nameLower = GetNameLower(r)
        d.category = cat
        d.icon = r.icon or GetCategoryIcon(cat)
        d.mapSearchResult = true
        d.mapID = r.mapID or r.zoneMapID or r.entranceMapID or searchMapID
        d.zoneName = r.zoneName or r.pathPrefix
        d.pathPrefix = r.pathPrefix
        d.x = r.x or r.entranceX
        d.y = r.y or r.entranceY
        d.keywords = r.keywords
        d.query = query
        d.isZone = nil
        d.zoneMapID = nil
        d.entranceMapID = nil
        d.entranceX = nil
        d.entranceY = nil
        d.entranceIcon = nil
        d.entranceCategory = nil
        d.isDungeonEntrance = nil
        if r.isZone then
            d.isZone = true
            d.zoneMapID = r.zoneMapID
            d.entranceMapID = r.entranceMapID
            d.entranceX = r.entranceX
            d.entranceY = r.entranceY
            d.entranceIcon = r.entranceIcon
            d.entranceCategory = r.entranceCategory
        end
        if r.isDungeonEntrance then
            d.isDungeonEntrance = true
            if not d.entranceMapID then
                d.entranceMapID = r.entranceMapID
            end
        end
        local out = results[ri]
        if not out then
            out = {}
            results[ri] = out
        end
        out.score = r.score or 50
        out.data = d
    end
    for i = resultCap + 1, #results do
        results[i] = nil
    end

    return results
end
