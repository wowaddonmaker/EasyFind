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

    if parentName == "Cosmic" then
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
    wipe(worldZonePrefixSeen)
    for i = 1, #zones do
        local zone = zones[i]
        zone.nameLower = zone.nameLower or slower(zone.name)
        IndexWorldZoneText(zone, zone.nameLower)
    end
    for abbrev, target in pairs(ZONE_ABBREVIATIONS) do
        for i = 1, #zones do
            local zone = zones[i]
            if zone.nameLower == target then
                AddWorldZonePrefix(zone, abbrev)
                break
            end
        end
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
    local zones
    local candidates

    if MapSearch:IsGlobalSearchActive() then
        zones = self:BuildWorldZoneCache()
        if not worldZonePrefixReady then BuildWorldZonePrefixIndex(zones) end
        candidates = worldZonePrefixIndex[ssub(query, 1, 2)]
            or worldZonePrefixIndex[ssub(query, 1, 1)]
            or emptyWorldZones

    else
        zones = self:GetDirectChildZones()
        candidates = zones
    end

    local cacheKey = MapSearch:IsGlobalSearchActive() and "global_" or "local_"
    local cache = searchZonesCache[cacheKey]
    local cachedHit = cache.entries[query]
    if cachedHit then
        cache.lastQuery = query
        return cachedHit
    end
    if cache.lastQuery ~= ""
       and #query > #cache.lastQuery
       and query:sub(1, #cache.lastQuery) == cache.lastQuery then
        local prev = cache.entries[cache.lastQuery]
        if prev then candidates = prev end
    end

    local matches = {}
    local abbrevTarget = ZONE_ABBREVIATIONS[query]  -- check once outside loop

    for _, zone in ipairs(candidates) do
        -- nameLower is cached on the zone so slower() is paid once per zone,
        -- not per keystroke (global mode = 1500 zones).
        local nameLower = zone.nameLower
        if not nameLower then
            nameLower = slower(zone.name)
            zone.nameLower = nameLower
        end
        local score = ns.Database:ScoreName(nameLower, query, #query)

        if abbrevTarget and nameLower == abbrevTarget then
            score = mmax(score, 200)
        end

        -- Don't inject ancestor matches: the renderer expands the matched
        -- parent via GetWorldChildren so all children show consistently.

        if score >= 50 then
            zone.score = score
            tinsert(matches, zone)
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
local zoneGroupPool = {}
local zoneGroupPoolN = 0
local zoneGroupByKey = {}
local zoneGroupResults = {}
local zonePathParts = {}

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
        wipe(zonePathParts)
        for i = 1, #path do zonePathParts[i] = tostring(path[i].mapID) end
        zone.parentPathKey = tconcat(zonePathParts, ">", 1, #path)
        wipe(zonePathParts)
        for i = 1, #path do zonePathParts[i] = path[i].name end
        zone.parentPathDisplay = tconcat(zonePathParts, " > ", 1, #path)
        zone.parentPathMapID = path[#path].mapID
    else
        zone.parentPathKey = tostring(zone.parentMapID or 0)
        zone.parentPathDisplay = zone.parentName or ""
        zone.parentPathMapID = zone.parentMapID
    end
end

local function GetZoneGroup()
    zoneGroupPoolN = zoneGroupPoolN + 1
    local group = zoneGroupPool[zoneGroupPoolN]
    if not group then
        group = { zones = {} }
        zoneGroupPool[zoneGroupPoolN] = group
    else
        wipe(group.zones)
    end
    group.parentMapID = nil
    group.parentPath = nil
    group.isGrouped = nil
    return group
end

function MapSearch:GroupZonesByParent(zones)
    zoneGroupPoolN = 0
    wipe(zoneGroupByKey)
    wipe(zoneGroupResults)

    for i = 1, #zones do
        local zone = zones[i]
        EnsureZoneGroupFields(zone)
        local key = zone.parentPathKey
        local group = zoneGroupByKey[key]
        if not group then
            group = GetZoneGroup()
            group.parentMapID = zone.parentPathMapID
            group.parentPath = zone.parentPathDisplay
            zoneGroupByKey[key] = group
            zoneGroupResults[#zoneGroupResults + 1] = group
        end
        group.zones[#group.zones + 1] = zone
    end

    for i = 1, #zoneGroupResults do
        local group = zoneGroupResults[i]
        local count = #group.zones
        if count > 1 then tsort(group.zones, ZoneNameLess) end
        group.isGrouped = count >= 2
    end

    tsort(zoneGroupResults, ZoneGroupLess)
    return zoneGroupResults
end

