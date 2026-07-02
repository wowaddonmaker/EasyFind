local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapUtils = ns.MapUtils
local MapSearchData = ns.MapSearchData
local Search = ns.MapSearchSearch

local pairs, ipairs, type = Utils.pairs, Utils.ipairs, Utils.type
local tinsert, tconcat = Utils.tinsert, Utils.tconcat
local sfind, slower = Utils.sfind, Utils.slower
local pcall = Utils.pcall
local SafeAfter = Utils.SafeAfter

local GLOBAL_SEARCH_CATEGORIES = MapSearchData.GLOBAL_SEARCH_CATEGORIES
local STATIC_LOCATIONS = ns.STATIC_LOCATIONS or MapSearchData.STATIC_LOCATIONS or {}
local GLOBAL_INSTANCE_CACHE_JOB = "map:global-instances"
local GLOBAL_INSTANCE_CACHE_BUDGET_MS = 2

local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local wipe = wipe

local GetMapInfo = C_Map.GetMapInfo
local GetMapChildrenInfo = C_Map.GetMapChildrenInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetAreaPOIInfo = C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo
local GetDelvesForMap = C_AreaPoiInfo and C_AreaPoiInfo.GetDelvesForMap
local GetDungeonEntrancesForMap = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
local GetMapRectOnMap = C_Map.GetMapRectOnMap

local normalizeName = Search.NormalizeName
local GetNameLower = Search.GetNameLower
local GetNameNorm = Search.GetNameNorm
local PreparePOI = Search.PreparePOI
local BuildEntranceLookup = Search.BuildEntranceLookup
local EnrichZoneWithEntrance = Search.EnrichZoneWithEntrance
local MapTabFlightPathsEnabled = Search.MapTabFlightPathsEnabled
local reuseInstanceNameNorm = Search.reuseInstanceNameNorm

Search.staticLocationCache = Search.staticLocationCache or {}
Search.emptyFlightMasters = Search.emptyFlightMasters or {}
local staticLocationCache = Search.staticLocationCache
local emptyFlightMasters = Search.emptyFlightMasters

-- [continentID][lowerName] = ownerZoneMapID. Rejects adjacent-zone bleed
-- without a strict whitelist (entrances with no owner get benefit of doubt).
local continentInstanceOwners = {}
local function GetContinentInstanceOwners(continentID)
    if continentInstanceOwners[continentID] then
        return continentInstanceOwners[continentID]
    end
    local owners = {}
    local function scan(parentID, ownerZoneID, depth)
        if depth > 5 then return end
        local children = GetMapChildrenInfo(parentID, nil, false)
        if children then
            for _, child in ipairs(children) do
                if child.name then
                    local mt = child.mapType
                    if mt == Enum.UIMapType.Dungeon or mt == Enum.UIMapType.Raid then
                        if ownerZoneID then
                            owners[slower(child.name)] = ownerZoneID
                        end
                    else
                        -- First Zone becomes the owner; sub-zones inherit.
                        local newOwner = ownerZoneID
                        if not newOwner and mt == Enum.UIMapType.Zone then
                            newOwner = child.mapID
                        end
                        scan(child.mapID, newOwner, depth + 1)
                    end
                end
            end
        end
    end
    scan(continentID, nil, 0)
    continentInstanceOwners[continentID] = owners
    return owners
end

local function ClassifyDungeonEntrance(entrance)
    if entrance.journalInstanceID and EJ_GetInstanceInfo then
        local _, _, _, _, _, _, _, _, _, _, _, isRaid = EJ_GetInstanceInfo(entrance.journalInstanceID)
        if isRaid then return "raid" end
    end
    return "dungeon"
end

local function BuildDungeonEntranceKeywords(name, category)
    local keywords = { category, "instance", "entrance" }
    local abbrs = ns.INSTANCE_ABBRS and ns.INSTANCE_ABBRS[slower(name)]
    if abbrs then
        for i = 1, #abbrs do
            keywords[#keywords + 1] = abbrs[i]
        end
    end
    return keywords
end

local function AppendDungeonEntrance(results, seen, entrance, x, y, mapID, parentLabel)
    local key = slower(entrance.name)
    if seen[key] then return end
    seen[key] = true

    local category = ClassifyDungeonEntrance(entrance)
    local entry = {
        name = entrance.name,
        category = category,
        icon = nil,
        isStatic = true,
        isDungeonEntrance = true,
        entranceMapID = mapID,
        x = x,
        y = y,
        pathPrefix = parentLabel,
        keywords = BuildDungeonEntranceKeywords(entrance.name, category),
    }
    tinsert(results, PreparePOI(entry))
end

local function GetProjectionRect(fromMapID, toMapID)
    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, fromMapID, toMapID)
    if ok and left and (right - left) > 0 and (bottom - top) > 0 then
        return left, right, top, bottom
    end
    return nil
end

local function AppendZoneDungeonEntrances(results, seen, mapID, owners, parentLabel)
    local entrances = GetDungeonEntrancesForMap(mapID)
    if not entrances then return end

    for _, entrance in ipairs(entrances) do
        if entrance.name and entrance.position then
            local ownerZone = owners and owners[slower(entrance.name)]
            if not ownerZone or ownerZone == mapID then
                AppendDungeonEntrance(results, seen, entrance,
                    entrance.position.x, entrance.position.y, mapID, parentLabel)
            end
        end
    end
end

local function AppendProjectedContinentEntrances(results, seen, mapID, continentID, owners, parentLabel)
    if not (continentID and owners) then return end

    local left, right, top, bottom = GetProjectionRect(mapID, continentID)
    if not left then return end

    local entrances = GetDungeonEntrancesForMap(continentID)
    if not entrances then return end

    for _, entrance in ipairs(entrances) do
        if entrance.name and entrance.position and not seen[slower(entrance.name)] then
            local ownerZone = owners[slower(entrance.name)]
            if ownerZone == mapID then
                local x = (entrance.position.x - left) / (right - left)
                local y = (entrance.position.y - top) / (bottom - top)
                AppendDungeonEntrance(results, seen, entrance, x, y, mapID, parentLabel)
            end
        end
    end
end

function MapSearch:FindEntranceOnMap(name, mapID)
    local nameNorm = normalizeName(name)
    if GetDungeonEntrancesForMap then
        local entrances = GetDungeonEntrancesForMap(mapID)
        if entrances then
            for _, ej in ipairs(entrances) do
                if ej.name and ej.position then
                    local ejNorm = normalizeName(ej.name)
                    if ejNorm == nameNorm or sfind(ejNorm, nameNorm, 1, true) or sfind(nameNorm, ejNorm, 1, true) then
                        return ej.position.x, ej.position.y
                    end
                end
            end
        end
    end
    if GetDelvesForMap and GetAreaPOIInfo then
        local delveIDs = GetDelvesForMap(mapID)
        if delveIDs then
            for _, poiID in ipairs(delveIDs) do
                local dInfo = GetAreaPOIInfo(mapID, poiID)
                if dInfo and dInfo.name and dInfo.position then
                    local dNorm = normalizeName(dInfo.name)
                    if dNorm == nameNorm or sfind(dNorm, nameNorm, 1, true) or sfind(nameNorm, dNorm, 1, true) then
                        return dInfo.position.x, dInfo.position.y
                    end
                end
            end
        end
    end
    return nil
end

function MapSearch:ScanDungeonEntrances(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not GetDungeonEntrancesForMap then return {} end

    local results = {}
    local seen = {}
    local mapInfo = GetMapInfo(mapID)
    local parentInfo = mapInfo and mapInfo.parentMapID and GetMapInfo(mapInfo.parentMapID)
    local parentLabel = mapInfo and mapInfo.name or ""

    local useContinent = parentInfo and parentInfo.mapType == Enum.UIMapType.Continent
    local continentID = useContinent and parentInfo.mapID or nil
    local owners = continentID and GetContinentInstanceOwners(continentID) or nil

    AppendZoneDungeonEntrances(results, seen, mapID, owners, parentLabel)
    AppendProjectedContinentEntrances(results, seen, mapID, continentID, owners, parentLabel)

    return results
end

local globalInstanceCache

-- Map state may grow as Blizzard lazy-loads it; invalidate so a first-search
-- call doesn't fix a partial cache (missing Northrend children, etc.).
local localScanCache = nil
-- Promoted zone-style POIs with breadcrumb paths, so BuildResults doesn't
-- allocate ~300 tables per keystroke.
local promotedInstancePOIs = nil
local globalInstanceCacheBuilding = false
local globalInstanceCacheWaiters
local globalInstanceCacheJobScheduler
local globalInstanceCacheBuildToken = 0
local BuildPromotedInstanceCache

local function ReleaseGlobalMapCaches()
    globalInstanceCacheBuildToken = globalInstanceCacheBuildToken + 1
    globalInstanceCache = nil
    globalInstanceCacheBuilding = false
    globalInstanceCacheWaiters = nil
    promotedInstancePOIs = nil
    Search.uiGlobalInstanceRefreshPending = nil
    Search.cachedAllFlightMasters = nil
    MapSearch._cachedFlightMasters = nil
    if ns.MapSearch.ResetSearchPoisCache then ns.MapSearch.ResetSearchPoisCache() end
end

local function CollectMapGarbage()
    if collectgarbage then
        collectgarbage("step", 300)
        collectgarbage("step", 300)
    end
end

do
    local invalidator = CreateFrame("Frame")
    invalidator:RegisterEvent("PLAYER_ENTERING_WORLD")
    invalidator:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    invalidator:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
    invalidator:SetScript("OnEvent", function()
        if ns.MapSearch.ResetWorldZoneCache then ns.MapSearch:ResetWorldZoneCache() end
        ReleaseGlobalMapCaches()
        localScanCache = nil
        wipe(staticLocationCache)
        -- Reset helpers are below this block, so go through the namespace.
        if ns.MapSearch.ResetSearchZonesCache then ns.MapSearch.ResetSearchZonesCache() end
        if ns.MapSearch.ResetSearchPoisCache  then ns.MapSearch.ResetSearchPoisCache()  end
        SafeAfter(0.2, function()
            if ns.MapSearch.BuildWorldZoneCache then ns.MapSearch:BuildWorldZoneCache() end
        end)
    end)
end

-- Character-zone events don't fire when the player browses the world map
-- UI, so flush local-scope caches on map change to avoid bleed.
do
    local function FlushLocalCaches()
        localScanCache = nil
        wipe(staticLocationCache)
        if ns.MapSearch.ResetSearchZonesCache then ns.MapSearch.ResetSearchZonesCache() end
        if ns.MapSearch.ResetSearchPoisCache  then ns.MapSearch.ResetSearchPoisCache()  end
    end
    if WorldMapFrame and type(WorldMapFrame.OnMapChanged) == "function" then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", FlushLocalCaches)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            if WorldMapFrame and type(WorldMapFrame.OnMapChanged) == "function" then
                hooksecurefunc(WorldMapFrame, "OnMapChanged", FlushLocalCaches)
            end
        end)
    end
end

-- Caches all local-mode scans by mapID. Per-keystroke scans without this
-- run hundreds of ms in busy zones.
local function GetLocalScans(self, mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()) or 0
    local includeFlightMasters = MapTabFlightPathsEnabled()
    local cache = localScanCache
    if cache and cache.mapID == mapID and cache.includeFlightMasters == includeFlightMasters then
        return cache.dynamicPOIs, cache.dungeonEntrances,
               cache.flightMasters, cache.vignetteRares
    end
    local dynamicPOIs      = self:ScanMapPOIs(mapID)
    local dungeonEntrances = self:ScanDungeonEntrances(mapID)
    local flightMasters    = includeFlightMasters and self:ScanFlightMasters(mapID) or emptyFlightMasters
    local vignetteRares    = self:ScanVignettes(mapID)
    localScanCache = {
        mapID = mapID,
        includeFlightMasters = includeFlightMasters,
        dynamicPOIs = dynamicPOIs, dungeonEntrances = dungeonEntrances,
        flightMasters = flightMasters, vignetteRares = vignetteRares,
    }
    return dynamicPOIs, dungeonEntrances, flightMasters, vignetteRares
end

local function AppendSearchCandidate(out, existingNames, zoneNames, entry, markExisting)
    local nameLower = GetNameLower(entry)
    if zoneNames and zoneNames[nameLower] then return false end
    if existingNames and existingNames[nameLower] then return false end

    out[#out + 1] = entry
    if markExisting and existingNames then
        existingNames[nameLower] = true
    end
    return true
end

local function AppendLocalSearchSources(self, out, existingNames, zoneNames, mapID, markStaticNames)
    local dynamicPOIs, dungeonEntrances, flightMasters, vignetteRares = GetLocalScans(self, mapID)
    local staticLocations = self:GetStaticLocations(mapID)

    -- Coordinate-bearing sources come first so they win deduplication over
    -- pin-only map canvas entries with the same display name.
    for _, entrance in ipairs(dungeonEntrances) do
        AppendSearchCandidate(out, existingNames, zoneNames, entrance, true)
    end
    for _, fm in ipairs(flightMasters) do
        AppendSearchCandidate(out, existingNames, zoneNames, fm, true)
    end
    for _, rare in ipairs(vignetteRares) do
        if rare.isAggregate then
            out[#out + 1] = rare
        else
            AppendSearchCandidate(out, existingNames, zoneNames, rare, true)
        end
    end
    for _, poi in ipairs(dynamicPOIs) do
        AppendSearchCandidate(out, existingNames, zoneNames, poi, true)
    end
    for _, loc in ipairs(staticLocations) do
        -- MapTab keeps duplicate static names so SearchPOIs can group/pin them;
        -- UI search wants one row per name, so callers choose whether to mark.
        AppendSearchCandidate(out, existingNames, zoneNames, loc, markStaticNames)
    end

    return dungeonEntrances
end

local function MarkGlobalInstanceSeen(seen, nameSeen, name, mapID)
    if not name then return false end
    local key = name .. "|" .. mapID
    if seen[key] then return false end
    seen[key] = true

    local nameKey = normalizeName(name)
    if nameSeen[nameKey] then return false end
    nameSeen[nameKey] = true
    return true
end

local function AppendGlobalDungeonEntrances(self, out, seen, nameSeen, mapID)
    local entrances = self:ScanDungeonEntrances(mapID)
    for _, entrance in ipairs(entrances) do
        if MarkGlobalInstanceSeen(seen, nameSeen, entrance.name, mapID) then
            tinsert(out, entrance)
        end
    end
end

local function AppendGlobalDelves(out, seen, nameSeen, mapID)
    if not (GetDelvesForMap and GetAreaPOIInfo) then return end

    local delveIDs = GetDelvesForMap(mapID)
    if not delveIDs then return end

    local mapInfo
    for _, poiID in ipairs(delveIDs) do
        local info = GetAreaPOIInfo(mapID, poiID)
        if info and info.name and info.position
           and MarkGlobalInstanceSeen(seen, nameSeen, info.name, mapID) then
            if not mapInfo then mapInfo = GetMapInfo(mapID) end
            local entry = {
                name = info.name,
                category = "delve",
                icon = nil,
                isStatic = true,
                isDungeonEntrance = true,
                entranceMapID = mapID,
                x = info.position.x,
                y = info.position.y,
                pathPrefix = mapInfo and mapInfo.name or "",
                keywords = {"delve", "delves", "instance"},
            }
            tinsert(out, PreparePOI(entry))
        end
    end
end

local function AppendGlobalStaticLocations(out, seen, nameSeen, mapID)
    local locations = STATIC_LOCATIONS[mapID]
    if not locations then return end

    local mapInfo = GetMapInfo(mapID)
    local mapName = mapInfo and mapInfo.name or ""
    for _, loc in ipairs(locations) do
        if GLOBAL_SEARCH_CATEGORIES[loc.category]
           and MarkGlobalInstanceSeen(seen, nameSeen, loc.name, mapID) then
            local entry = {
                name = loc.name,
                category = loc.category,
                icon = loc.icon,
                isStatic = true,
                isDungeonEntrance = true,
                entranceMapID = mapID,
                x = loc.x,
                y = loc.y,
                pathPrefix = mapName,
                keywords = loc.keywords,
            }
            tinsert(out, PreparePOI(entry))
        end
    end
end

local CollectGlobalInstanceMap
CollectGlobalInstanceMap = function(self, out, seen, nameSeen, parentMapID)
    local children = GetMapChildrenInfo(parentMapID, nil, false)
    if not children then return end

    for _, child in ipairs(children) do
        AppendGlobalDungeonEntrances(self, out, seen, nameSeen, child.mapID)
        AppendGlobalDelves(out, seen, nameSeen, child.mapID)
        AppendGlobalStaticLocations(out, seen, nameSeen, child.mapID)
        CollectGlobalInstanceMap(self, out, seen, nameSeen, child.mapID)
    end
end

local function NotifyGlobalInstanceCacheWaiters(ready)
    local waiters = globalInstanceCacheWaiters
    globalInstanceCacheWaiters = nil
    if not waiters then return end
    for i = 1, #waiters do
        pcall(waiters[i], ready)
    end
end

local function BuildGlobalInstanceCacheSync(self)
    if globalInstanceCache then return globalInstanceCache end

    globalInstanceCacheBuildToken = globalInstanceCacheBuildToken + 1
    globalInstanceCacheBuilding = false
    globalInstanceCache = {}
    CollectGlobalInstanceMap(self, globalInstanceCache, {}, {}, 946)
    NotifyGlobalInstanceCacheWaiters(true)
    return globalInstanceCache
end

local function FinishGlobalInstanceCacheBuild(self, token, cache, done)
    if token ~= globalInstanceCacheBuildToken then
        globalInstanceCacheBuilding = false
        done(false, "cancelled")
        return
    end

    globalInstanceCache = cache or {}
    globalInstanceCacheBuilding = false
    if BuildPromotedInstanceCache then
        BuildPromotedInstanceCache(self)
    end
    NotifyGlobalInstanceCacheWaiters(true)
    done()
end

local function RunGlobalInstanceCacheBuild(self, done)
    if globalInstanceCache then
        NotifyGlobalInstanceCacheWaiters(true)
        done()
        return
    end
    if globalInstanceCacheBuilding then
        done(false, "already running")
        return
    end

    if not SafeAfter then
        BuildGlobalInstanceCacheSync(self)
        done()
        return
    end

    globalInstanceCacheBuilding = true
    globalInstanceCacheBuildToken = globalInstanceCacheBuildToken + 1
    local token = globalInstanceCacheBuildToken
    local cache, seen, nameSeen = {}, {}, {}
    local rootChildren = GetMapChildrenInfo(946, nil, false)
    local stack = rootChildren and {{ children = rootChildren, index = 1 }} or {}

    local function step()
        if token ~= globalInstanceCacheBuildToken then
            globalInstanceCacheBuilding = false
            done(false, "cancelled")
            return
        end

        local startMs = debugprofilestop and debugprofilestop() or 0
        local processed = 0
        while #stack > 0 do
            local frame = stack[#stack]
            local child = frame.children and frame.children[frame.index]
            if not child then
                stack[#stack] = nil
            else
                frame.index = frame.index + 1
                AppendGlobalDungeonEntrances(self, cache, seen, nameSeen, child.mapID)
                AppendGlobalDelves(cache, seen, nameSeen, child.mapID)
                AppendGlobalStaticLocations(cache, seen, nameSeen, child.mapID)

                local children = GetMapChildrenInfo(child.mapID, nil, false)
                if children and #children > 0 then
                    stack[#stack + 1] = { children = children, index = 1 }
                end

                processed = processed + 1
                if debugprofilestop then
                    if (debugprofilestop() - startMs) >= GLOBAL_INSTANCE_CACHE_BUDGET_MS then
                        SafeAfter(0, step)
                        return
                    end
                elseif processed >= 20 then
                    SafeAfter(0, step)
                    return
                end
            end
        end

        FinishGlobalInstanceCacheBuild(self, token, cache, done)
    end

    SafeAfter(0, step)
end

local function EnsureGlobalInstanceCacheJob(self)
    local sched = ns.Scheduler
    if not sched then return nil end
    if globalInstanceCacheJobScheduler == sched then return sched end

    globalInstanceCacheJobScheduler = sched
    sched:Register(GLOBAL_INSTANCE_CACHE_JOB, {
        cancelGroup = "map-global-instances",
        run = function(_, done)
            RunGlobalInstanceCacheBuild(self, done)
        end,
    })
    return sched
end

function MapSearch:HasGlobalInstanceCache()
    return globalInstanceCache ~= nil
end

function MapSearch:RequestGlobalInstanceCache(onDone)
    if globalInstanceCache then
        if onDone then pcall(onDone, true) end
        return false
    end

    if onDone then
        globalInstanceCacheWaiters = globalInstanceCacheWaiters or {}
        globalInstanceCacheWaiters[#globalInstanceCacheWaiters + 1] = onDone
    end

    local sched = EnsureGlobalInstanceCacheJob(self)
    if not sched then
        RunGlobalInstanceCacheBuild(self, function() end)
        return true
    end

    local status = sched:Status(GLOBAL_INSTANCE_CACHE_JOB)
    if status == "complete" then
        sched:Reset(GLOBAL_INSTANCE_CACHE_JOB)
        status = sched:Status(GLOBAL_INSTANCE_CACHE_JOB)
    end
    if status ~= "queued" and status ~= "running" then
        sched:Enqueue(GLOBAL_INSTANCE_CACHE_JOB)
    end
    return true
end

function MapSearch:GetGlobalInstanceCache()
    if globalInstanceCache then return globalInstanceCache end
    return BuildGlobalInstanceCacheSync(self)
end

BuildPromotedInstanceCache = function(self)
    if promotedInstancePOIs then return promotedInstancePOIs end

    local zones = self:BuildWorldZoneCache()
    local instancePOIs = self:GetGlobalInstanceCache()
    local pathForMap = {}
    local parts = {}
    for _, zone in ipairs(zones) do
        if zone.path and not pathForMap[zone.mapID] then
            wipe(parts)
            for _, p in ipairs(zone.path) do
                if not MapUtils.IsRootMap(p.mapID) then
                    parts[#parts + 1] = p.name
                end
            end
            -- Continents have only root-type ancestors (Azeroth is a World
            -- map): keep the nearest one so their breadcrumb isn't empty.
            if #parts == 0 and #zone.path > 0 then
                parts[1] = zone.path[#zone.path].name
            end
            parts[#parts + 1] = zone.name
            pathForMap[zone.mapID] = tconcat(parts, " > ")
        end
    end

    promotedInstancePOIs = {}
    for _, poi in ipairs(instancePOIs) do
        local fullPath = pathForMap[poi.entranceMapID]
        local entry = {
            name = poi.name, category = poi.category, icon = poi.icon,
            isZone = true, isStatic = poi.isStatic,
            isDungeonEntrance = poi.isDungeonEntrance,
            zoneMapID = poi.entranceMapID, entranceMapID = poi.entranceMapID,
            entranceX = poi.x, entranceY = poi.y,
            entranceIcon = poi.icon, entranceCategory = poi.category,
            pathPrefix = fullPath or poi.pathPrefix, keywords = poi.keywords,
        }
        promotedInstancePOIs[#promotedInstancePOIs + 1] = PreparePOI(entry)
    end
    return promotedInstancePOIs
end

local function AppendZoneSearchResults(out, zoneNames, groupedZones, existingNames)
    for _, group in ipairs(groupedZones) do
        for _, zone in ipairs(group.zones) do
            local nameLower = GetNameLower(zone)
            zoneNames[nameLower] = true
            if not existingNames or not existingNames[nameLower] then
                out[#out + 1] = {
                    name = zone.name,
                    nameLower = zone.nameLower,
                    nameNorm = zone.nameNorm,
                    category = "zone",
                    icon = 237382,
                    isZone = true,
                    zoneMapID = zone.mapID,
                    zoneMapType = zone.mapType,
                    zoneParentMapID = zone.parentMapID,
                    pathPrefix = group.parentPath,
                    score = zone.score,
                }
            end
        end
    end
end

local function GetInstanceNameNorms(instancePOIs)
    wipe(reuseInstanceNameNorm)
    for _, poi in ipairs(instancePOIs) do
        if poi.isDungeonEntrance then
            reuseInstanceNameNorm[GetNameNorm(poi)] = true
        end
    end
    return reuseInstanceNameNorm
end

local function SuppressCoveredDungeonZones(out, zoneNames, instancePOIs)
    local instanceNameNorm = GetInstanceNameNorms(instancePOIs)
    local writeIdx = 0
    for i = 1, #out do
        local poi = out[i]
        local keep = true
        if poi.isZone and poi.zoneMapType == Enum.UIMapType.Dungeon then
            local poiNorm = GetNameNorm(poi)
            for instNorm in pairs(instanceNameNorm) do
                if sfind(instNorm, poiNorm, 1, true) or sfind(poiNorm, instNorm, 1, true) then
                    zoneNames[GetNameLower(poi)] = nil
                    zoneNames[poiNorm] = nil
                    keep = false
                    break
                end
            end
        end
        if keep then
            writeIdx = writeIdx + 1
            out[writeIdx] = poi
        end
    end
    for i = #out, writeIdx + 1, -1 do
        out[i] = nil
    end
end

local function EnrichZoneSearchResults(out, zoneNames, instancePOIs)
    local entranceLookup = BuildEntranceLookup(instancePOIs)
    for _, poi in ipairs(out) do
        if poi.isZone and poi.zoneMapID then
            local entrance = entranceLookup[GetNameLower(poi)]
            if entrance then
                EnrichZoneWithEntrance(poi, entrance)
                zoneNames[GetNameLower(entrance)] = true
            end
        end
    end
end

local function ClearPerQueryResultState(poi)
    poi.score = nil
    poi.duplicateKey = nil
    poi.allInstances = nil
end

local function AppendPromotedInstanceResults(self, out, zoneNames)
    local promoted = BuildPromotedInstanceCache(self)
    for i = 1, #promoted do
        local poi = promoted[i]
        ClearPerQueryResultState(poi)
        if not zoneNames[GetNameLower(poi)] and not zoneNames[GetNameNorm(poi)] then
            out[#out + 1] = poi
        end
    end
end

local function AppendGlobalInstanceSearchSources(self, out, zoneNames)
    local instancePOIs = self:GetGlobalInstanceCache()
    SuppressCoveredDungeonZones(out, zoneNames, instancePOIs)
    EnrichZoneSearchResults(out, zoneNames, instancePOIs)
    AppendPromotedInstanceResults(self, out, zoneNames)
end

-- Legacy PvP vendors live in the faction capitals but are findable from any
-- zone, so they belong on the global ("Around the World") path, never forced
-- into "This Zone". The viewed/anchor zone's own vendor is skipped because it
-- already surfaces there as an ordinary static.
local function AppendAlwaysFindableLocations(self, out, nameSet, excludeMapID)
    for _, loc in ipairs(self:GetAlwaysFindableLocations()) do
        if loc.mapID ~= excludeMapID then
            local nameLower = GetNameLower(loc)
            if not (nameSet and nameSet[nameLower]) then
                ClearPerQueryResultState(loc)
                out[#out + 1] = loc
                if nameSet then nameSet[nameLower] = true end
            end
        end
    end
end

function MapSearch:BuildGlobalSearchCaches()
    self:BuildWorldZoneCache()
    self:RequestGlobalInstanceCache()
    local mapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())
    if mapID and WorldMapFrame then
        GetLocalScans(self, mapID)
        self:GetStaticLocations(mapID)
    end
end

function MapSearch:WarmUISearchCaches()
    self:BuildWorldZoneCache()
    self:RequestGlobalInstanceCache()
    local mapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())
    if mapID and WorldMapFrame then
        GetLocalScans(self, mapID)
        self:GetStaticLocations(mapID)
    end
end


function Search.ClearLocalCaches()
    localScanCache = nil
    wipe(staticLocationCache)
end

Search.ReleaseGlobalMapCaches = ReleaseGlobalMapCaches
Search.CollectMapGarbage = CollectMapGarbage
Search.GetLocalScans = GetLocalScans
Search.AppendSearchCandidate = AppendSearchCandidate
Search.AppendLocalSearchSources = AppendLocalSearchSources
Search.BuildPromotedInstanceCache = BuildPromotedInstanceCache
Search.AppendZoneSearchResults = AppendZoneSearchResults
Search.AppendGlobalInstanceSearchSources = AppendGlobalInstanceSearchSources
Search.AppendAlwaysFindableLocations = AppendAlwaysFindableLocations
