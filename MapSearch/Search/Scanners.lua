local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapSearchData = ns.MapSearchData
local Search = ns.MapSearchSearch

local pairs, ipairs, type, select = Utils.pairs, Utils.ipairs, Utils.type, Utils.select
local tinsert = Utils.tinsert
local slower = Utils.slower
local mfloor = Utils.mfloor
local pcall = Utils.pcall
local wipe = wipe

local CATEGORY_ICONS = MapSearchData.CATEGORY_ICONS
local STATIC_LOCATIONS = ns.STATIC_LOCATIONS or MapSearchData.STATIC_LOCATIONS or {}

local GetMapInfo = C_Map.GetMapInfo
local GetMapChildrenInfo = C_Map.GetMapChildrenInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetMapInfoAtPosition = C_Map.GetMapInfoAtPosition
local GetAreaPOIForMap = C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap
local GetAreaPOIInfo = C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo
local GetDelvesForMap = C_AreaPoiInfo and C_AreaPoiInfo.GetDelvesForMap
local GetVignettes = C_VignetteInfo and C_VignetteInfo.GetVignettes
local GetVignetteInfo = C_VignetteInfo and C_VignetteInfo.GetVignetteInfo
local GetVignettePosition = C_VignetteInfo and C_VignetteInfo.GetVignettePosition

local PreparePOI = Search.PreparePOI
local PreparePOIList = Search.PreparePOIList

Search.staticLocationCache = Search.staticLocationCache or {}
Search.emptyStaticLocations = Search.emptyStaticLocations or {}
local staticLocationCache = Search.staticLocationCache
local emptyStaticLocations = Search.emptyStaticLocations
function MapSearch:ScanFlightMasters(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not C_TaxiMap or not C_TaxiMap.GetTaxiNodesForMap then return {} end

    local results = {}
    local nodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
    if not nodes then return results end

    local playerFaction = UnitFactionGroup("player")
    local FPFaction = Enum.FlightPathFaction

    -- Only filter adjacent-zone bleed on zone-level maps.
    local fmMapInfo = GetMapInfo(mapID)
    local fmParentInfo = fmMapInfo and fmMapInfo.parentMapID and GetMapInfo(fmMapInfo.parentMapID)
    local fmShouldFilter = fmParentInfo and fmParentInfo.mapType == Enum.UIMapType.Continent
    -- Continent scans resolve per-node so each FM gets the child zone it
    -- belongs to; MapTab uses parentMapID for sub-grouping under continent.
    local resolvePerNode = (fmMapInfo and fmMapInfo.mapType == Enum.UIMapType.Continent) or fmShouldFilter

    for _, node in ipairs(nodes) do
        if node.name and node.position then
            local skip = false
            if node.faction and FPFaction then
                if (node.faction == FPFaction.Horde and playerFaction ~= "Horde")
                    or (node.faction == FPFaction.Alliance and playerFaction ~= "Alliance") then
                    skip = true
                end
            end
            if not skip then
                local x, y = node.position.x, node.position.y
                if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    local fmInclude = true
                    local nodeParentMapID = mapID
                    if resolvePerNode then
                        local posInfo = GetMapInfoAtPosition and GetMapInfoAtPosition(mapID, x, y)
                        if posInfo and posInfo.mapID then
                            nodeParentMapID = posInfo.mapID
                            if fmShouldFilter then
                                fmInclude = (posInfo.mapID == mapID or posInfo.parentMapID == mapID)
                            end
                        elseif fmShouldFilter then
                            fmInclude = false
                        end
                    end
                    if fmInclude then
                        local entry = {
                            name = node.name .. " (Flight Master)",
                            category = "flightmaster",
                            icon = "atlas:TaxiNode_Neutral",
                            isStatic = true,
                            x = x,
                            y = y,
                            parentMapID = nodeParentMapID,
                            -- coordMapID gates hover previews so an FM scanned
                            -- in one zone doesn't render a pin in another.
                            coordMapID = mapID,
                            keywords = {"flight", "fly", "taxi", "fp", "flight master"},
                        }
                        tinsert(results, PreparePOI(entry))
                    end
                end
            end
        end
    end
    return results
end

function MapSearch:ScanAllFlightMasters()
    if Search.cachedAllFlightMasters then return Search.cachedAllFlightMasters end
    if not C_TaxiMap or not C_TaxiMap.GetTaxiNodesForMap then return {} end

    local allNodes = {}
    local seen = {}

    local function collectFromMaps(parentMapID, depth)
        if depth > 6 then return end
        local children = GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end

        for _, child in ipairs(children) do
            if child.name then
                local mt = child.mapType
                -- Zones only: continent scans duplicate child-zone results
                -- with a coordMapID wrong for whatever the player views.
                if mt == Enum.UIMapType.Zone then
                    local nodes = self:ScanFlightMasters(child.mapID)
                    for _, node in ipairs(nodes) do
                        local key = node.name .. "|" .. child.mapID
                        if not seen[key] then
                            seen[key] = true
                            local mapInfo = GetMapInfo(child.mapID)
                            node.pathPrefix = mapInfo and mapInfo.name or ""
                            tinsert(allNodes, node)
                        end
                    end
                end
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    collectFromMaps(child.mapID, depth + 1)
                end
            end
        end
    end

    local cosmicChildren = GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            collectFromMaps(child.mapID, 0)
        end
    end

    Search.cachedAllFlightMasters = allNodes
    MapSearch._cachedFlightMasters = allNodes
    return allNodes
end

function MapSearch:GetStaticLocations(mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
    if not mapID then return emptyStaticLocations end

    local includeDevPOIs = EasyFindDevDB and EasyFindDevDB.rawPOIs
    local cached = not includeDevPOIs and staticLocationCache[mapID]
    if cached then return cached end

    local results = {}

    local locations = STATIC_LOCATIONS[mapID]
    if locations then
        for _, loc in ipairs(locations) do
            local entry = {
                name = loc.name,
                category = loc.category,
                icon = loc.icon,
                isStatic = true,
                mapID = mapID,
                coordMapID = mapID,
                x = loc.x,
                y = loc.y,
                keywords = loc.keywords,
            }
            tinsert(results, PreparePOI(entry))
        end
    end

    -- Dev POIs (recorder) skipped when their name already exists in static.
    if includeDevPOIs then
        local staticNames = {}
        if locations then
            for _, loc in ipairs(locations) do
                staticNames[slower(loc.name)] = true
            end
        end
        for _, poi in ipairs(includeDevPOIs) do
            if poi.mapID == mapID and not staticNames[slower(poi.label or "")] then
                local entry = {
                    name = poi.label,
                    category = poi.category or "unknown",
                    icon = nil,
                    isStatic = true,
                    mapID = mapID,
                    coordMapID = mapID,
                    x = poi.x,
                    y = poi.y,
                    keywords = {},
                }
                tinsert(results, PreparePOI(entry))
            end
        end
    end

    if not includeDevPOIs then
        staticLocationCache[mapID] = results
    end
    return results
end

function MapSearch:ScanVignettes(mapID)
    local rares = {}
    if not GetVignettes or not GetVignettePosition then return rares end

    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return rares end
    local guids = GetVignettes()
    if not guids then return rares end

    for _, guid in ipairs(guids) do
        local info = GetVignetteInfo and GetVignetteInfo(guid)
        if info and info.name and not info.isDead then
            local atlas = info.atlasName
            if atlas == "VignetteKill" or atlas == "VignetteKillElite" then
                -- Stay strict to the viewed map; player-map fallback would
                -- show unrelated rares when the user browses another zone.
                local pos = GetVignettePosition(guid, mapID)
                if pos then
                    local entry = {
                        name = info.name,
                        category = "rare",
                        icon = CATEGORY_ICONS.rare,
                        x = pos.x,
                        y = pos.y,
                        vignetteGUID = guid,
                        keywords = {"rare", "rares"},
                    }
                    rares[#rares + 1] = PreparePOI(entry)
                end
            end
        end
    end

    return rares
end

function MapSearch:UpdateRareTracking()
    if not EasyFind.db.alwaysShowRares then
        self:ClearHighlight()
        return
    end
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    if self:HasActivePinState() or self._previewing then return end

    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return end

    local playerMapID = GetBestMapForUnit("player")
    if mapID ~= playerMapID then
        self:ClearHighlight()
        return
    end

    if mapID ~= Search.rareTrackMapID then
        wipe(Search.rareTrackCache)
        wipe(Search.rareDeadGUIDs)
        Search.rareTrackMapID = mapID
    end

    local rares = self:ScanVignettes()
    local activeGUIDs = {}
    for _, rare in ipairs(rares) do
        if not rare.isAggregate and rare.vignetteGUID and not Search.rareDeadGUIDs[rare.vignetteGUID] then
            activeGUIDs[rare.vignetteGUID] = true
            rare.inRange = true
            Search.rareTrackCache[rare.vignetteGUID] = rare
        end
    end

    -- Mark rares that left range as dead to block corpse-vignette resurrects.
    for guid, rare in pairs(Search.rareTrackCache) do
        if not activeGUIDs[guid] then
            if rare.inRange then
                Search.rareTrackCache[guid] = nil
                Search.rareDeadGUIDs[guid] = true
            end
        end
    end

    local individuals = {}
    for _, rare in pairs(Search.rareTrackCache) do
        if rare.x and rare.y then
            individuals[#individuals + 1] = rare
        end
    end

    if #individuals > 0 then
        self:ShowMultipleWaypoints(individuals)
    else
        self:ClearHighlight()
    end
end

function MapSearch:ScanMapPOIs(mapID)
    local pois = {}
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return pois end

    local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if not canvas then return pois end

    local areaPOIs = GetAreaPOIForMap(mapID)
    if areaPOIs then
        for _, poiID in ipairs(areaPOIs) do
            local poiInfo = GetAreaPOIInfo(mapID, poiID)
            -- Skip POIs that render on this map but belong to an adjacent one.
            if poiInfo and poiInfo.isPrimaryMapForPOI == false then
                poiInfo = nil
            end
            if poiInfo and poiInfo.name then
                local poiName = slower(poiInfo.name or "")
                local desc = slower(poiInfo.description or "")
                local category = MapSearchData.ResolveAreaPOICategory(poiName, desc)

                if category then
                    local entry = {
                        name = poiInfo.name,
                        pin = nil,
                        pinType = category,
                        category = category,
                        icon = nil,
                        isStatic = true,
                        x = poiInfo.position.x,
                        y = poiInfo.position.y,
                    }
                    tinsert(pois, PreparePOI(entry))
                end
            end
        end
    end

    if GetDelvesForMap then
        local delveIDs = GetDelvesForMap(mapID)
        if delveIDs then
            for _, delvePoiID in ipairs(delveIDs) do
                local dInfo = GetAreaPOIInfo(mapID, delvePoiID)
                if dInfo and dInfo.name and dInfo.position then
                    local entry = {
                        name = dInfo.name,
                        category = "delve",
                        icon = nil,
                        isStatic = true,
                        isDungeonEntrance = true,
                        x = dInfo.position.x,
                        y = dInfo.position.y,
                        keywords = {"delve", "delves", "instance"},
                    }
                    tinsert(pois, PreparePOI(entry))
                end
            end
        end
    end

    for i = 1, select("#", canvas:GetChildren()) do
        local pin = select(i, canvas:GetChildren())
        if pin and pin:IsShown() then
            local info = self:GetPinInfo(pin)
            if info then
                tinsert(pois, info)
            end
        end
    end

    -- Dedupe: prefer the canvas-scan entry since its live pin reference lets
    -- SelectResult glow the native icon in place.
    local deduped = {}
    local seenByKey = {}
    for _, poi in ipairs(pois) do
        local key
        if poi.x and poi.y and poi.category then
            key = poi.category .. "|" .. mfloor(poi.x * 1000) .. "|" .. mfloor(poi.y * 1000)
        end
        if not key then
            tinsert(deduped, poi)
        else
            local existingIdx = seenByKey[key]
            if not existingIdx then
                tinsert(deduped, poi)
                seenByKey[key] = #deduped
            elseif poi.pin and not deduped[existingIdx].pin then
                deduped[existingIdx] = poi
            end
        end
    end
    return PreparePOIList(deduped)
end

local PIN_SKIP_ATLAS = {
    ["Waypoint-MapPin-Tracked"]   = true,
    ["Waypoint-MapPin-Untracked"] = true,
    ["UI-QuestPoi-OuterGlow"]     = true,
}

-- Native Blizzard pin atlases we recognize by sight. Used as a fallback when
-- the pin's other Lua metadata (areaPoiInfo, vignetteInfo) doesn't categorize
-- it - some data providers expose pins as plain Frames with only an atlas to
-- tell you what they are (e.g., trading post, quartermaster, chromie).
local PIN_ATLAS_TYPES = {
    ["ChromieTime-32x32"]         = { name = "Chromie",       category = "chromie" },
    ["trading-post-minimap-icon"] = { name = "Trading Post",  category = "tradingpost" },
    ["Quartermaster"]             = { name = "Quartermaster", category = "quartermaster" },
}

-- Inspect a pin's textures and return the first known atlas identity, plus
-- the first non-generic ARTWORK atlas as a fallback icon. atlasName /
-- atlasCategory are nil when the pin has no recognized atlas; atlasIcon may
-- still be set (any non-generic ARTWORK atlas).
local function ScanPinAtlasIdentity(pin)
    local atlasName, atlasCategory, atlasIcon
    for _, region in pairs({pin:GetRegions()}) do
        if region.GetAtlas then
            local a = region:GetAtlas()
            if a and a ~= "" and not PIN_SKIP_ATLAS[a]
               and region:GetDrawLayer() == "ARTWORK" then
                if not atlasIcon then
                    atlasIcon = "atlas:" .. a
                end
                if not atlasName then
                    local known = PIN_ATLAS_TYPES[a]
                    if known then
                        atlasName = known.name
                        atlasCategory = known.category
                    end
                end
            end
        end
    end
    return atlasName, atlasCategory, atlasIcon
end

-- Returns the live native canvas pin whose GetPinInfo name matches the
-- given name (case-insensitive). Used when hovering / clicking results
-- whose data.pin was lost across the local-vs-global cache boundary
-- (AppendGlobalInstanceSearchSources doesn't carry pin references), so
-- highlight can still glow the in-game pin instead of falling back to an
-- EasyFind waypoint overlay.
function MapSearch:FindNativePinByName(name)
    if not name or name == "" then return nil end
    local canvas = WorldMapFrame and WorldMapFrame.ScrollContainer
        and WorldMapFrame.ScrollContainer.Child
    if not canvas then return nil end
    local needle = slower(name)
    local count = select("#", canvas:GetChildren())
    for i = 1, count do
        local pin = select(i, canvas:GetChildren())
        if pin and pin:IsShown() then
            local info = self:GetPinInfo(pin)
            if info and info.name and slower(info.name) == needle then
                return pin
            end
        end
    end
    return nil
end

function MapSearch:GetPinInfo(pin)
    if not pin or not pin:IsShown() then return nil end

    -- Pre-scan atlases. Used as a fallback for any code path below that
    -- would otherwise return nil due to unrecognized areaPoiInfo names or
    -- vignette types we don't normally track.
    local atlasName, atlasCategory, atlasIcon = ScanPinAtlasIdentity(pin)

    local name = nil
    local icon = atlasIcon
    local pinType = "unknown"
    local category = nil

    -- Flight masters - handled by ScanFlightMasters() with proper zone filtering
    if pin.taxiNodeData then
        return nil
    end

    -- Delve entrance pins
    if pin.pinTemplate == "DelveEntrancePinTemplate" and pin.name then
        return {
            name = pin.name,
            pin = pin,
            pinType = "delve",
            category = "delve",
            icon = nil,
            isStatic = false,
            isDungeonEntrance = true,
            x = pin.normalizedX,
            y = pin.normalizedY,
        }
    end

    -- Area POIs (boats, zeppelins, portals, etc) - but NOT quests
    if pin.areaPoiInfo then
        name = pin.areaPoiInfo.name or pin.areaPoiInfo.description

        local poiName = slower(name or "")
        local poiDesc = slower(pin.areaPoiInfo.description or "")
        category = MapSearchData.ResolvePinAreaPOICategory(poiName, poiDesc)
        if category then
            pinType = category
            if category == "chromie" then
                icon = "atlas:ChromieTime-32x32"
            end
        elseif atlasCategory then
            -- API name doesn't match our keyword list, but the pin's atlas
            -- tells us what it is (e.g., a vendor NPC name like "Boots
            -- Murphy" on a Quartermaster atlas). Keep the API name and
            -- adopt the atlas-derived category.
            category = atlasCategory
            pinType = atlasCategory
        else
            return nil
        end
    end

    -- Vignettes: treasures get the treasure category. Other vignette types
    -- (vendors, services) are still useful if their atlas tells us what
    -- they are; otherwise rares are handled by ScanVignettes() (which
    -- provides GUID for super-tracking) so we drop them here.
    if pin.vignetteInfo then
        if pin.vignetteInfo.vignetteType == 2 then
            name = pin.vignetteInfo.name
            pinType = "vignette"
            category = "treasure"
        elseif atlasCategory then
            name = name or pin.vignetteInfo.name
            category = atlasCategory
            pinType = atlasCategory
        else
            return nil
        end
    end

    -- SKIP quests entirely - don't include them
    if pin.questID then
        return nil
    end

    -- SKIP world quests too
    if pin.worldQuest then
        return nil
    end

    -- Dungeon/Raid instances - handled by ScanDungeonEntrances() with proper zone filtering
    if pin.journalInstanceID then
        return nil
    end

    -- No areaPoiInfo / vignetteInfo categorization happened: fall back to
    -- whatever the atlas pre-scan identified. This is the path for plain
    -- Frame pins that have no Lua metadata at all (e.g., trading post,
    -- quartermaster on some maps).
    if not category and atlasCategory then
        category = atlasCategory
        pinType = atlasCategory
    end
    if not name and atlasName then
        name = atlasName
    end

    -- Final fallback raw texture scan if we still have no icon at all
    if not icon then
        if pin.Texture and pin.Texture.GetTexture then
            local tex = pin.Texture:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        elseif pin.Icon and pin.Icon.GetTexture then
            local tex = pin.Icon:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        end
    end

    if not name or name == "" or not category then
        return nil
    end

    -- Extract coordinates from pin data (more reliable than screen-position math)
    local pinX, pinY
    if pin.areaPoiInfo and pin.areaPoiInfo.position then
        pinX = pin.areaPoiInfo.position.x
        pinY = pin.areaPoiInfo.position.y
    elseif pin.vignetteInfo and pin.vignetteInfo.vignetteGUID then
        local pos = GetVignettePosition and GetVignettePosition(pin.vignetteInfo.vignetteGUID, WorldMapFrame:GetMapID())
        if pos then
            pinX = pos.x
            pinY = pos.y
        end
    end
    -- Fallback: MapCanvasPinMixin exposes GetPosition on data-provider pins
    if not pinX and pin.GetPosition then
        local ok, px, py = pcall(pin.GetPosition, pin)
        if ok and px and py and px >= 0 and px <= 1 and py >= 0 and py <= 1 then
            pinX = px
            pinY = py
        end
    end

    -- Filter out pins from adjacent zones using extracted coordinates
    if pinX and pinY then
        local mapID = WorldMapFrame:GetMapID()
        if mapID then
            local posInfo = GetMapInfoAtPosition and GetMapInfoAtPosition(mapID, pinX, pinY)
            if posInfo and posInfo.mapID ~= mapID and posInfo.parentMapID ~= mapID then
                return nil
            end
        end
    end

    return {
        name = name,
        pin = pin,
        pinType = pinType,
        category = category,
        icon = icon,
        isStatic = false,
        x = pinX,
        y = pinY,
    }
end
