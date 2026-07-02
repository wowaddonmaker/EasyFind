local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapUtils = ns.MapUtils

local pairs, ipairs = Utils.pairs, Utils.ipairs
local tinsert, tsort, tconcat, tremove = Utils.tinsert, Utils.tsort, Utils.tconcat, Utils.tremove
local ssub, slower = Utils.ssub, Utils.slower
local mmax = Utils.mmax
local pcall, tostring = Utils.pcall, Utils.tostring
local wipe = wipe

local GetMapInfo = C_Map.GetMapInfo
local GetMapChildrenInfo = C_Map.GetMapChildrenInfo
local GetMapRectOnMap = C_Map.GetMapRectOnMap
local ZONE_ABBREVIATIONS = MapUtils.ZONE_ABBREVIATIONS

local function ZoneMatchLess(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
end

local cachedWorldZones
local worldZonePrefixIndex = {}
local worldZonePrefixSeen = {}
local worldZonePrefixReady = false
local emptyWorldZones = {}

function MapSearch:ResetWorldZoneCache()
    cachedWorldZones = nil
    wipe(worldZonePrefixIndex)
    wipe(worldZonePrefixSeen)
    worldZonePrefixReady = false
end

function MapSearch:HasWorldZoneCache()
    return cachedWorldZones ~= nil
end
function MapSearch:GetDirectChildZones(mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
    if not mapID then return {} end

    local zones = {}
    local seen = {}

    local children = GetMapChildrenInfo(mapID, nil, false)
    if children then
        for _, child in ipairs(children) do
            if child.name and not seen[child.mapID] then
                local mt = child.mapType
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    seen[child.mapID] = true
                    tinsert(zones, {
                        mapID = child.mapID,
                        name = child.name,
                        mapType = child.mapType,
                        parentMapID = mapID
                    })
                end
            end
        end
    end

    return zones
end

function MapSearch:GetMapHierarchy(mapID)
    local hierarchy = {}
    local currentID = mapID
    local maxDepth = 10

    while currentID and maxDepth > 0 do
        local mapInfo = GetMapInfo(currentID)
        if mapInfo then
            tinsert(hierarchy, 1, {
                mapID = currentID,
                name = mapInfo.name,
                mapType = mapInfo.mapType
            })
            currentID = mapInfo.parentMapID
        else
            break
        end
        maxDepth = maxDepth - 1
    end

    return hierarchy
end

function MapSearch:GetAllWorldZones(startMapID, depth, parentPath)
    depth = depth or 0
    parentPath = parentPath or {}

    local allZones = {}
    local maxDepth = 6

    if depth > maxDepth then return allZones end

    local children = GetMapChildrenInfo(startMapID, nil, false)
    if not children then return allZones end

    local parentInfo = GetMapInfo(startMapID)
    local parentName = parentInfo and parentInfo.name or ""
    local parentType = parentInfo and parentInfo.mapType

    -- The Cosmic map's localized name differs per client; match the enum, not
    -- the English string. Root segments are dropped from displayed breadcrumbs
    -- by mapType (MapUtils.IsRootMap), so this sentinel only surfaces for a zone
    -- parented directly to Cosmic.
    if parentType == Enum.UIMapType.Cosmic then
        parentName = "World"
    end

    for _, child in ipairs(children) do
        if child.name then
            local fullPath = {}
            for i = 1, #parentPath do
                fullPath[i] = parentPath[i]
            end
            if parentName ~= "" then
                tinsert(fullPath, {mapID = startMapID, name = parentName})
            end

            local mt = child.mapType
            local includeDungeon = false
            if mt == Enum.UIMapType.Dungeon then
                if parentType == Enum.UIMapType.Zone then
                    includeDungeon = true
                elseif parentType == Enum.UIMapType.Continent then
                    local ok, dL, dR = pcall(GetMapRectOnMap, child.mapID, startMapID)
                    includeDungeon = ok and dL and (dR - dL) > 0
                end
            end
            if mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan
               and (mt ~= Enum.UIMapType.Dungeon or includeDungeon) then
                tinsert(allZones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = startMapID,
                    parentName = parentName,
                    path = fullPath,
                    depth = depth
                })

                local subZones = self:GetAllWorldZones(child.mapID, depth + 1, fullPath)
                for _, subZone in ipairs(subZones) do
                    tinsert(allZones, subZone)
                end
            end
        end
    end

    return allZones
end

-- LRU per-mode (local/global) so backspace hits cache and typing
-- extensions narrow from the most recent entry.
local SEARCH_CACHE_MAX = 32
local searchZonesCache = {
    local_  = { entries = {}, order = {}, lastQuery = "" },
    global_ = { entries = {}, order = {}, lastQuery = "" },
}
local function ResetSearchZonesCache()
    for _, c in pairs(searchZonesCache) do
        wipe(c.entries); wipe(c.order); c.lastQuery = ""
    end
end
ns.MapSearch.ResetSearchZonesCache = ResetSearchZonesCache

local function CachePut(cache, query, value)
    if cache.entries[query] == nil then
        cache.order[#cache.order + 1] = query
        if #cache.order > SEARCH_CACHE_MAX then
            local oldest = tremove(cache.order, 1)
            cache.entries[oldest] = nil
        end
    end
    cache.entries[query] = value
    cache.lastQuery = query
end

local function AddWorldZonePrefix(zone, prefix)
    if worldZonePrefixSeen[prefix] == zone then return end
    worldZonePrefixSeen[prefix] = zone
    local bucket = worldZonePrefixIndex[prefix]
    if not bucket then
        bucket = {}
        worldZonePrefixIndex[prefix] = bucket
    end
    bucket[#bucket + 1] = zone
end

local function IndexWorldZoneText(zone, text)
    if not text then return end
    for word in text:gmatch("%S+") do
        local len = #word
        if len >= 1 then AddWorldZonePrefix(zone, ssub(word, 1, 1)) end
        if len >= 2 then AddWorldZonePrefix(zone, ssub(word, 1, 2)) end
    end
end

local function BuildWorldZonePrefixIndex(zones)
    wipe(worldZonePrefixIndex)
    local byName = {}
    for i = 1, #zones do
        local zone = zones[i]
        zone.nameLower = zone.nameLower or slower(zone.name)
        IndexWorldZoneText(zone, zone.nameLower)
        byName[zone.nameLower] = byName[zone.nameLower] or zone
    end
    for abbrev, target in pairs(ZONE_ABBREVIATIONS) do
        local zone = byName[target]
        if zone then AddWorldZonePrefix(zone, abbrev) end
    end
    wipe(worldZonePrefixSeen)
    worldZonePrefixReady = true
end

function MapSearch:BuildWorldZoneCache()
    if cachedWorldZones then return cachedWorldZones end

    local worldPath = {{mapID = 946, name = "World"}}
    local zones = {}
    local cosmicChildren = GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            if child.name then
                tinsert(zones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = 946,
                    parentName = "World",
                    path = worldPath,
                    depth = 0
                })
            end
            local worldZones = self:GetAllWorldZones(child.mapID, 0, worldPath)
            for _, z in ipairs(worldZones) do
                tinsert(zones, z)
            end
        end
    end
    cachedWorldZones = zones
    BuildWorldZonePrefixIndex(zones)
    return zones
end

function MapSearch:SearchZones(query)
    if not query or query == "" then return {} end

    query = slower(query)
    if ns.Database and ns.Database.NormalizeSearchQuery then
        query = ns.Database:NormalizeSearchQuery(query)
    end
    local isGlobal = MapSearch:IsGlobalSearchActive()
    local zones
    local candidates

    if isGlobal then
        zones = self:BuildWorldZoneCache()
        if not worldZonePrefixReady then BuildWorldZonePrefixIndex(zones) end
        candidates = worldZonePrefixIndex[ssub(query, 1, 2)]
            or worldZonePrefixIndex[ssub(query, 1, 1)]
            or emptyWorldZones

    else
        zones = self:GetDirectChildZones()
        -- Also let the currently-viewed map match its own name, so searching
        -- e.g. "Northrend" while viewing Northrend surfaces it (selecting it
        -- navigates in to reveal its children) instead of returning nothing.
        local viewedMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        local viewedInfo = viewedMapID and GetMapInfo(viewedMapID)
        if viewedInfo and viewedInfo.name then
            zones[#zones + 1] = {
                mapID = viewedMapID,
                name = viewedInfo.name,
                mapType = viewedInfo.mapType,
                parentMapID = viewedInfo.parentMapID,
            }
        end
        candidates = zones
    end

    local cacheKey = isGlobal and "global_" or "local_"
    local cache = searchZonesCache[cacheKey]
    local cachedHit = cache.entries[query]
    if cachedHit then
        cache.lastQuery = query
        return cachedHit
    end
    if cache.lastQuery ~= ""
       and #query > #cache.lastQuery
       and ssub(query, 1, #cache.lastQuery) == cache.lastQuery then
        local prev = cache.entries[cache.lastQuery]
        if prev then candidates = prev end
    end

    local matches = {}
    local abbrevTarget = ZONE_ABBREVIATIONS[query]  -- check once outside loop

    local qLen = #query
    for i = 1, #candidates do
        local zone = candidates[i]
        local nameLower = zone.nameLower
        if not nameLower then
            nameLower = slower(zone.name)
            zone.nameLower = nameLower
        end
        local score = ns.Database:ScoreName(nameLower, query, qLen)

        if abbrevTarget and nameLower == abbrevTarget then
            score = mmax(score, 200)
        end

        if score >= 50 then
            zone.score = score
            matches[#matches + 1] = zone
        end
    end

    tsort(matches, ZoneMatchLess)

    if #matches > 0 then
        CachePut(cache, query, matches)
    else
        cache.lastQuery = query
    end

    return matches
end

-- Groups only when multiple results share the EXACT SAME parent path.
local GROUP_STATE = {
    pool = {},
    poolN = 0,
    byKey = {},
    results = {},
    pathParts = {},
}

local function ZoneNameLess(a, b)
    return a.name < b.name
end

local function ZoneGroupLess(a, b)
    return (a.parentPath or "") < (b.parentPath or "")
end

local function EnsureZoneGroupFields(zone)
    if zone.parentPathKey then return end
    local path = zone.path
    if path and #path > 0 then
        local parts = GROUP_STATE.pathParts
        wipe(parts)
        for i = 1, #path do parts[i] = tostring(path[i].mapID) end
        zone.parentPathKey = tconcat(parts, ">")
        wipe(parts)
        local n = 0
        for i = 1, #path do
            if not MapUtils.IsRootMap(path[i].mapID) then
                n = n + 1
                parts[n] = path[i].name
            end
        end
        zone.parentPathDisplay = tconcat(parts, " > ", 1, n)
        wipe(parts)
        zone.parentPathMapID = path[#path].mapID
    else
        zone.parentPathKey = tostring(zone.parentMapID or 0)
        zone.parentPathDisplay = zone.parentName or ""
        zone.parentPathMapID = zone.parentMapID
    end
end

local function GetZoneGroup()
    GROUP_STATE.poolN = GROUP_STATE.poolN + 1
    local group = GROUP_STATE.pool[GROUP_STATE.poolN]
    if not group then
        group = { zones = {} }
        GROUP_STATE.pool[GROUP_STATE.poolN] = group
    else
        wipe(group.zones)
    end
    group.parentMapID = nil
    group.parentPath = nil
    group.isGrouped = nil
    return group
end

function MapSearch:GroupZonesByParent(zones)
    GROUP_STATE.poolN = 0
    local byKey = GROUP_STATE.byKey
    local results = GROUP_STATE.results
    wipe(byKey)
    wipe(results)

    for i = 1, #zones do
        local zone = zones[i]
        EnsureZoneGroupFields(zone)
        local key = zone.parentPathKey
        local group = byKey[key]
        if not group then
            group = GetZoneGroup()
            group.parentMapID = zone.parentPathMapID
            group.parentPath = zone.parentPathDisplay
            byKey[key] = group
            results[#results + 1] = group
        end
        group.zones[#group.zones + 1] = zone
    end

    for i = 1, #results do
        local group = results[i]
        local count = #group.zones
        if count > 1 then tsort(group.zones, ZoneNameLess) end
        group.isGrouped = count >= 2
    end

    tsort(results, ZoneGroupLess)
    return results
end

