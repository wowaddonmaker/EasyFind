local _, ns = ...

local Utils = ns.Utils
local MapUtils = {}
ns.MapUtils = MapUtils

local tconcat = Utils.tconcat
local slower = Utils.slower
local wipe = wipe
local C_Map = C_Map
local GetMapInfo = C_Map and C_Map.GetMapInfo

local PATH_STRIP_ROOTS = { "World", "Azeroth", "Cosmic" }
local STRIPPED_ROOTS = { World = true, Azeroth = true, Cosmic = true }

local PARENT_OVERRIDES = {
    [2346] = 2274,
}

local ZONE_ABBREVIATIONS = {
    sw = "stormwind city",
    stormwind = "stormwind city",
    og = "orgrimmar",
    org = "orgrimmar",
    ["if"] = "ironforge",
    tb = "thunder bluff",
    uc = "undercity",
    darn = "darnassus",
    exo = "the exodar",
    smc = "silvermoon city",
    silvermoon = "silvermoon city",
    dal = "dalaran",
    bb = "booty bay",
    sh = "shattrath city",
    shatt = "shattrath city",
    shat = "shattrath city",
    daz = "dazar'alor",
    bor = "boralus",
    orib = "oribos",
    vald = "valdrakken",
    zand = "zandalar",
    kt = "kul tiras",
    ek = "eastern kingdoms",
    kali = "kalimdor",
    dk = "acherus: the ebon hold",
    nr = "northrend",
    ol = "outland",
    tbc = "outland",
    sl = "shadowlands",
    wod = "draenor",
    di = "dragon isles",
    df = "dragon isles",
    bi = "broken isles",
    leg = "broken isles",
    mop = "pandaria",
    tww = "khaz algar",
}

MapUtils.PARENT_OVERRIDES = PARENT_OVERRIDES
MapUtils.ZONE_ABBREVIATIONS = ZONE_ABBREVIATIONS

function MapUtils.GetParentMapID(mapID, info)
    return PARENT_OVERRIDES[mapID] or (info and info.parentMapID)
end

function MapUtils.ExpandZoneAbbrev(token)
    return token and ZONE_ABBREVIATIONS[token] or nil
end

function MapUtils.FormatPathPrefix(pathStr)
    if type(pathStr) ~= "string" or pathStr == "" then return pathStr end
    for i = 1, #PATH_STRIP_ROOTS do
        local root = PATH_STRIP_ROOTS[i] .. " > "
        if pathStr:sub(1, #root) == root then
            pathStr = pathStr:sub(#root + 1)
        else
            break
        end
    end
    return STRIPPED_ROOTS[pathStr] and "" or pathStr
end

local topAncestorCache = {}
function MapUtils.GetTopAncestor(mapID)
    if not mapID or mapID == 0 then return nil end
    local cached = topAncestorCache[mapID]
    if cached ~= nil then
        if cached == false then return nil end
        return cached.name, cached.mapID
    end
    local current = mapID
    local resultName, resultID
    for _ = 1, 20 do
        local info = GetMapInfo and GetMapInfo(current)
        if not info then break end
        local parentID = MapUtils.GetParentMapID(current, info)
        local parentInfo = parentID and parentID ~= 0 and GetMapInfo(parentID) or nil
        local parentName = parentInfo and parentInfo.name
        if not parentInfo or not parentName or STRIPPED_ROOTS[parentName] or parentID == 0 then
            resultName = info.name
            resultID = current
            break
        end
        current = parentID
    end
    if resultName then
        topAncestorCache[mapID] = { name = resultName, mapID = resultID }
    else
        topAncestorCache[mapID] = false
    end
    return resultName, resultID
end

local zoneUnderAncestorCache = {}
function MapUtils.GetZoneUnderAncestor(mapID, ancestorMapID)
    if not mapID or not ancestorMapID or mapID == ancestorMapID then return nil end
    local cacheKey = mapID .. "_" .. ancestorMapID
    local cached = zoneUnderAncestorCache[cacheKey]
    if cached ~= nil then
        if cached == false then return nil end
        return cached.name, cached.mapID
    end
    local current = mapID
    for _ = 1, 20 do
        local info = GetMapInfo and GetMapInfo(current)
        if not info then break end
        local parentID = MapUtils.GetParentMapID(current, info)
        if parentID == ancestorMapID then
            zoneUnderAncestorCache[cacheKey] = { name = info.name, mapID = current }
            return info.name, current
        end
        if not parentID or parentID == 0 then break end
        current = parentID
    end
    zoneUnderAncestorCache[cacheKey] = false
    return nil
end

local ancestorNamesCache = {}
function MapUtils.GetAncestorNames(mapID)
    if not mapID or mapID == 0 then return {} end
    local cached = ancestorNamesCache[mapID]
    if cached then return cached end
    local names = {}
    local current = mapID
    for _ = 1, 20 do
        local info = GetMapInfo and GetMapInfo(current)
        if not info then break end
        if info.name and info.name ~= "" then
            names[#names + 1] = slower(info.name)
        end
        local parentID = MapUtils.GetParentMapID(current, info)
        if not parentID or parentID == 0 then break end
        current = parentID
    end
    ancestorNamesCache[mapID] = names
    return names
end

local mapPathCache = {}
function MapUtils.GetMapPath(mapID)
    if not mapID then return {} end
    local cached = mapPathCache[mapID]
    if cached then return cached end
    local path = {}
    local currentID = mapID
    for _ = 1, 15 do
        local info = GetMapInfo and GetMapInfo(currentID)
        if not info then break end
        path[#path + 1] = { mapID = currentID, name = info.name, mapType = info.mapType }
        currentID = MapUtils.GetParentMapID(currentID, info)
        if not currentID or currentID == 0 then break end
    end
    local n = #path
    for i = 1, n / 2 do
        local j = n - i + 1
        path[i], path[j] = path[j], path[i]
    end
    mapPathCache[mapID] = path
    return path
end

local breadcrumbParts = {}
function MapUtils.BuildBreadcrumb(data, separator)
    if not data then return nil end
    local mapID = data.mapID or data.zoneMapID or data.entranceMapID or data.parentMapID
    if not mapID or not GetMapInfo then return data.name end

    wipe(breadcrumbParts)
    local current = mapID
    local leafName = data.name and slower(data.name) or ""
    for _ = 1, 20 do
        local info = GetMapInfo(current)
        if not info then break end
        if info.name and slower(info.name) ~= leafName then
            breadcrumbParts[#breadcrumbParts + 1] = info.name == "Cosmic" and "World" or info.name
        end
        local parentID = MapUtils.GetParentMapID(current, info)
        if not parentID or parentID == 0 then break end
        current = parentID
    end
    local n = #breadcrumbParts
    if n == 0 then
        wipe(breadcrumbParts)
        return data.name
    end
    for i = 1, n / 2 do
        local j = n - i + 1
        breadcrumbParts[i], breadcrumbParts[j] = breadcrumbParts[j], breadcrumbParts[i]
    end
    breadcrumbParts[n + 1] = data.name
    local result = tconcat(breadcrumbParts, separator or "  >  ")
    wipe(breadcrumbParts)
    return result
end
