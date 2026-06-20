local _, ns = ...

local Utils = ns.Utils
local L = ns.L
local MapUtils = {}
ns.MapUtils = MapUtils

local pairs = Utils.pairs
local ipairs = Utils.ipairs
local tconcat = Utils.tconcat
local slower = Utils.slower
local pcall = Utils.pcall
local wipe = wipe
local C_Map = C_Map
local GetMapInfo = C_Map and C_Map.GetMapInfo
local GetMapChildrenInfo = C_Map and C_Map.GetMapChildrenInfo
local GetMapInfoAtPosition = C_Map and C_Map.GetMapInfoAtPosition
local GetMapRectOnMap = C_Map and C_Map.GetMapRectOnMap

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

function MapUtils.GetContinentForMap(mapID)
    local id = mapID
    for _ = 1, 10 do
        local info = GetMapInfo and GetMapInfo(id)
        if not info then return nil end
        if info.mapType == Enum.UIMapType.Continent then return id end
        id = MapUtils.GetParentMapID(id, info)
        if not id or id == 0 then return nil end
    end
end

-- Handles zones not in a direct parent-child relationship (e.g. Stormwind
-- projected onto Elwynn Forest) via their shared continent.
function MapUtils.GetMapRectViaContinent(mapID, viewMapID)
    if not GetMapRectOnMap then return nil end
    local c1 = MapUtils.GetContinentForMap(mapID)
    local c2 = MapUtils.GetContinentForMap(viewMapID)
    if not c1 or c1 ~= c2 then return nil end

    local ok1, tL, tR, tT, tB = pcall(GetMapRectOnMap, mapID, c1)
    local ok2, vL, vR, vT, vB = pcall(GetMapRectOnMap, viewMapID, c1)
    if not ok1 or not tL or not ok2 or not vL then return nil end

    local vW, vH = vR - vL, vB - vT
    if vW == 0 or vH == 0 then return nil end

    return (tL - vL) / vW, (tR - vL) / vW, (tT - vT) / vH, (tB - vT) / vH
end

-- Orphan zones (Vision of Stormwind, etc.) return all zeros from
-- GetMapRectOnMap and have no continent projection. Bugged zones (Uldum,
-- Vale) return valid rects, so this won't match them.
function MapUtils.IsOrphanZone(mapID)
    if not GetMapInfo or not GetMapRectOnMap then return false end
    local info = GetMapInfo(mapID)
    if not info or not info.parentMapID then return false end
    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, mapID, info.parentMapID)
    if not ok or not left then return true end
    if left ~= 0 or right ~= 0 or top ~= 0 or bottom ~= 0 then return false end
    local pL, pR, pT, pB = MapUtils.GetMapRectViaContinent(mapID, info.parentMapID)
    if not pL then return true end
    return pL == 0 and pR == 0 and pT == 0 and pB == 0
end

-- A zone may exist under multiple mapIDs (TBC IQD 122 vs Midnight versions).
-- Find a same-named child of viewMapID that has a valid rect, else return
-- the original mapID unchanged.
function MapUtils.ResolveZoneForMap(mapID, viewMapID)
    if not GetMapInfo or not GetMapRectOnMap then return mapID end
    local info = GetMapInfo(mapID)
    if not info or not info.name then return mapID end

    local ok, left, right = pcall(GetMapRectOnMap, mapID, viewMapID)
    if ok and left and (right - left) > 0 then return mapID end

    local children = GetMapChildrenInfo and GetMapChildrenInfo(viewMapID, nil, false)
    if not children then return mapID end

    local targetName = slower(info.name)
    for _, child in ipairs(children) do
        if child.mapID ~= mapID and slower(child.name) == targetName then
            local ok2, cL, cR = pcall(GetMapRectOnMap, child.mapID, viewMapID)
            if ok2 and cL and (cR - cL) > 0 then
                Utils.DebugPrint("ResolveZoneForMap:", mapID, "->", child.mapID, "on", viewMapID)
                return child.mapID
            end
        end
    end

    return mapID
end

-- minCount=2 finds a zone on 2+ sides (catches cities like Ironforge where
-- Dun Morogh surrounds 3/4 sides); minCount=1 finds the first hit (catches
-- Stormwind where only 1-2 probes hit a named zone).
function MapUtils.FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, minCount)
    if not GetMapInfoAtPosition then return nil end
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local offsets = {
        { left - 0.02, centerY },
        { right + 0.02, centerY },
        { centerX, top - 0.02 },
        { centerX, bottom + 0.02 },
    }
    local counts = {}
    local zones = {}
    for i = 1, #offsets do
        local px, py = offsets[i][1], offsets[i][2]
        if px >= 0 and px <= 1 and py >= 0 and py <= 1 then
            local info = GetMapInfoAtPosition(parentMapID, px, py)
            if info and info.mapID ~= mapID and info.mapType == Enum.UIMapType.Zone then
                counts[info.mapID] = (counts[info.mapID] or 0) + 1
                zones[info.mapID] = info
            end
        end
    end
    local bestID, bestCount
    for id, count in pairs(counts) do
        if count >= minCount and (not bestCount or count > bestCount) then
            bestID, bestCount = id, count
        end
    end
    if bestID then return zones[bestID] end
end

function MapUtils.FindContainingZone(targetMapID, viewMapID)
    if not GetMapInfo or not GetMapRectOnMap or not GetMapInfoAtPosition then return nil end

    local ok, cL, cR, cT, cB = pcall(GetMapRectOnMap, targetMapID, viewMapID)
    if not ok or not cL or (cR - cL) <= 0 then return nil end

    local targetArea = (cR - cL) * (cB - cT)
    local cx, cy = (cL + cR) / 2, (cT + cB) / 2
    local candidates = {}

    local containing = GetMapInfoAtPosition(viewMapID, cx, cy)
    if containing and containing.mapID ~= targetMapID and containing.mapType == Enum.UIMapType.Zone then
        candidates[#candidates + 1] = containing
    end

    local surrounding = MapUtils.FindSurroundingZone(viewMapID, targetMapID, cL, cR, cT, cB, 1)
    if surrounding then
        candidates[#candidates + 1] = surrounding
    end

    for i = 1, #candidates do
        local candidate = candidates[i]
        local ok2, sL, sR, sT, sB = pcall(GetMapRectOnMap, candidate.mapID, viewMapID)
        if ok2 and sL and cL >= sL and cR <= sR and cT >= sT and cB <= sB then
            local containArea = (sR - sL) * (sB - sT)
            -- < 25% gates city-sized targets; larger ratios are API bugs.
            if targetArea < containArea * 0.25 then
                return candidate
            end
        end
    end
end

function MapUtils.ExpandZoneAbbrev(token)
    return token and ZONE_ABBREVIATIONS[token] or nil
end

-- A top-level root map (Cosmic, or a World-tier map like Azeroth) that should
-- never show in a displayed breadcrumb. Matched by mapType, not by name, so the
-- stripping works on every locale.
function MapUtils.IsRootMap(mapID)
    if not mapID then return false end
    local info = GetMapInfo(mapID)
    return (info and info.mapType and info.mapType <= Enum.UIMapType.World) or false
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
        if not parentInfo or not parentName or parentInfo.mapType <= Enum.UIMapType.World or parentID == 0 then
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
            local isCosmic = info.mapType == Enum.UIMapType.Cosmic
            breadcrumbParts[#breadcrumbParts + 1] = isCosmic and L["MAP_COSMIC_WORLD"] or info.name
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
