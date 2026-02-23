-- =============================================================================
-- EasyFind Transport Graph
-- Static transport network data + Dijkstra shortest-path solver for GPS routing.
-- Nodes = zone mapIDs. Edges = transport connections (portals, boats, tram, etc.)
-- =============================================================================
local ADDON_NAME, ns = ...

local TransportGraph = {}
ns.TransportGraph = TransportGraph

local Utils    = ns.Utils
local pairs    = Utils.pairs
local ipairs   = Utils.ipairs
local tinsert  = Utils.tinsert
local tremove  = Utils.tremove
local tsort    = Utils.tsort
local sformat  = Utils.sformat
local mmin     = Utils.mmin
local tostring = Utils.tostring

local C_Map    = C_Map
local UnitFactionGroup = UnitFactionGroup

-- =============================================================================
-- CONTINENT IDS (for same-continent detection)
-- =============================================================================
local CONTINENT_MAP = {
    -- Eastern Kingdoms
    [13] = 13,
    -- Kalimdor
    [12] = 12,
    -- Outland
    [101] = 101,
    -- Northrend
    [113] = 113,
    -- Pandaria (The Wandering Isle → Pandaria continent)
    [424] = 424,
    -- Draenor
    [572] = 572,
    -- Broken Isles
    [619] = 619,
    -- Argus
    [905] = 905,
    -- Kul Tiras
    [876] = 876,
    -- Zandalar
    [875] = 875,
    -- Shadowlands (The Maw / Oribos area)
    [1550] = 1550,
    -- Dragon Isles
    [1978] = 1978,
    -- Khaz Algar
    [2274] = 2274,
}

-- =============================================================================
-- CONTINENT HUBS — fallback for zones that don't resolve via hierarchy
-- Maps continent mapID → array of hub node mapIDs (first match used).
-- Used when a zone is on a known continent but isn't a child of any hub node.
-- =============================================================================
local CONTINENT_HUBS = {
    -- List ALL transport nodes per continent — ResolveNode tries each in order.
    -- Hierarchy walk usually finds a closer one before we reach this fallback.
    [13]   = {84, 87, 90, 480, 10},  -- Eastern Kingdoms → SW, IF, UC, Silvermoon, N.Stranglethorn
    [12]   = {85, 88},               -- Kalimdor → Orgrimmar, Thunder Bluff
    [101]  = {111},                   -- Outland → Shattrath
    [113]  = {125, 114},              -- Northrend → Dalaran, Borean Tundra
    [424]  = {525},                   -- Pandaria → Jade Forest (Shrine)
    [572]  = {588},                   -- Draenor → Ashran
    [619]  = {627},                   -- Broken Isles → Dalaran (Legion)
    [876]  = {1161},                  -- Kul Tiras → Boralus
    [875]  = {1165},                  -- Zandalar → Dazar'alor
    [1550] = {1670},                  -- Shadowlands → Oribos
    [1978] = {2112},                  -- Dragon Isles → Valdrakken
    [2274] = {2339},                  -- Khaz Algar → Dornogal
}

-- =============================================================================
-- HUB FACTION AFFINITY
-- Which faction can actually REACH each old-world hub via inbound transport.
-- nil = neutral (expansion hubs reachable by both via portal rooms).
-- Used by continent fallback to avoid routing Horde→Stormwind or Alliance→Undercity.
-- =============================================================================
local HUB_FACTION = {
    [84]  = "Alliance",  -- Stormwind: inbound via Alliance portals only
    [87]  = "Alliance",  -- Ironforge: inbound via tram from Stormwind only
    [90]  = "Horde",     -- Undercity: inbound via Org zeppelin only
    [480] = "Horde",     -- Silvermoon: inbound via UC translocation only
    [10]  = "Horde",     -- N.Stranglethorn/Grom'gol: inbound via Org zeppelin only
    [88]  = "Horde",     -- Thunder Bluff: inbound via Org zeppelin only
}

-- =============================================================================
-- NODE ALIASES — sub-zones that should resolve to their parent hub
-- Portal rooms, harbors, etc. → parent city mapID
-- =============================================================================
local NODE_ALIASES = {
    -- Stormwind sub-zones
    [1553] = 84,   -- Stormwind portal room (Sanctum of the Sages) → Stormwind
    -- Orgrimmar sub-zones
    [1554] = 85,   -- Orgrimmar portal room (Pathfinder's Den) → Orgrimmar
    -- Ironforge
    [87] = 87,
    -- Undercity
    [90] = 90,
    -- Silvermoon City
    [480] = 480,
    -- Thunder Bluff
    [88] = 88,
    -- Darnassus
    [89] = 89,
    -- Dalaran (Northrend)
    [125] = 125,
    -- Borean Tundra (Northrend boat/zep arrival)
    [114] = 114,
    -- Dalaran (Legion)
    [627] = 627,
    -- Jade Forest / Pandaria hub
    [525] = 525,
    -- Ashran / Draenor hub
    [588] = 588,
    -- Boralus
    [1161] = 1161,
    -- Dazar'alor
    [1165] = 1165,
    -- Oribos
    [1670] = 1670,
    -- Valdrakken
    [2112] = 2112,
    -- Dornogal
    [2339] = 2339,
    -- Shattrath
    [111] = 111,
    -- Northern Stranglethorn / Grom'gol (zeppelin dock)
    -- NOTE: mapID 10 needs in-game verification via /devmap
    -- These are Cataclysm-split zones that should resolve to the zeppelin dock
    [10] = 10,
    [50] = 10,    -- Northern Stranglethorn → zeppelin dock
    [210] = 10,   -- The Cape of Stranglethorn → zeppelin dock (nearest transport)
    [224] = 10,   -- Stranglethorn Vale (parent zone if it exists) → zeppelin dock
}

-- =============================================================================
-- STATIC TRANSPORT EDGES
-- Each entry: departure zone → list of connections
-- Fields: to, x, y (departure coords), cost (seconds), type, label, faction, bidir
-- =============================================================================
local STATIC_EDGES = {
    -- =========================================================================
    -- DORNOGAL (Khaz Algar hub — current expansion)
    -- =========================================================================
    [2339] = {
        { to = 84,   x = 0.4185, y = 0.2830, cost = 5, type = "portal", label = "Portal to Stormwind",  faction = "Alliance" },
        { to = 85,   x = 0.4185, y = 0.2830, cost = 5, type = "portal", label = "Portal to Orgrimmar",  faction = "Horde" },
    },

    -- =========================================================================
    -- STORMWIND (Alliance hub — Eastern Kingdoms)
    -- =========================================================================
    [84] = {
        -- Portal room (Sanctum of the Sages) — coords are portal room area
        { to = 1670, x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Oribos" },
        { to = 2112, x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Valdrakken" },
        { to = 2339, x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Dornogal" },
        { to = 627,  x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Dalaran (Legion)" },
        { to = 1161, x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Boralus",       faction = "Alliance" },
        { to = 525,  x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Jade Forest",   faction = "Alliance" },
        { to = 111,  x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Shattrath" },
        { to = 71,   x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Tanaris (CoT)" },
        { to = 624,  x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Azsuna" },
        { to = 588,  x = 0.50, y = 0.87, cost = 5, type = "portal", label = "Portal to Ashran",        faction = "Alliance" },
        -- Deeprun Tram
        { to = 87,   x = 0.6667, y = 0.3468, cost = 60, type = "tram", label = "Deeprun Tram to Ironforge", bidir = true },
        -- Harbor boats
        { to = 1161, x = 0.22, y = 0.56, cost = 90, type = "boat", label = "Boat to Boralus",          faction = "Alliance" },
        { to = 114,  x = 0.22, y = 0.56, cost = 120, type = "boat", label = "Boat to Borean Tundra",   faction = "Alliance", bidir = true },
    },

    -- =========================================================================
    -- ORGRIMMAR (Horde hub — Kalimdor)
    -- =========================================================================
    [85] = {
        -- Portal room (Pathfinder's Den) — coords from StaticLocations
        { to = 1670, x = 0.5799, y = 0.8829, cost = 5, type = "portal", label = "Portal to Oribos" },
        { to = 2112, x = 0.5711, y = 0.8817, cost = 5, type = "portal", label = "Portal to Valdrakken" },
        { to = 2339, x = 0.5846, y = 0.9091, cost = 5, type = "portal", label = "Portal to Dornogal" },
        { to = 627,  x = 0.5641, y = 0.9160, cost = 5, type = "portal", label = "Portal to Dalaran (Legion)" },
        { to = 1165, x = 0.5720, y = 0.8980, cost = 5, type = "portal", label = "Portal to Dazar'alor",    faction = "Horde" },
        { to = 525,  x = 0.5754, y = 0.9155, cost = 5, type = "portal", label = "Portal to Jade Forest",   faction = "Horde" },
        { to = 111,  x = 0.5697, y = 0.9086, cost = 5, type = "portal", label = "Portal to Shattrath" },
        { to = 71,   x = 0.5643, y = 0.9163, cost = 5, type = "portal", label = "Portal to Tanaris (CoT)" },
        { to = 624,  x = 0.5704, y = 0.8815, cost = 5, type = "portal", label = "Portal to Azsuna" },
        { to = 588,  x = 0.5579, y = 0.9161, cost = 5, type = "portal", label = "Portal to Ashran",        faction = "Horde" },
        { to = 480,  x = 0.5534, y = 0.9049, cost = 5, type = "portal", label = "Portal to Silvermoon City", faction = "Horde" },
        -- Zeppelins
        { to = 90,   x = 0.45, y = 0.10, cost = 90, type = "zeppelin", label = "Zeppelin to Undercity",      bidir = true },
        { to = 10,   x = 0.45, y = 0.10, cost = 90, type = "zeppelin", label = "Zeppelin to Stranglethorn",  bidir = true },
        { to = 88,   x = 0.45, y = 0.10, cost = 90, type = "zeppelin", label = "Zeppelin to Thunder Bluff" },
        { to = 114,  x = 0.45, y = 0.10, cost = 120, type = "zeppelin", label = "Zeppelin to Borean Tundra", bidir = true },
    },

    -- =========================================================================
    -- THUNDER BLUFF (Horde — Kalimdor, zeppelin dock)
    -- =========================================================================
    [88] = {
        { to = 85, x = 0.1452, y = 0.2582, cost = 90, type = "zeppelin", label = "Zeppelin to Orgrimmar" },
    },

    -- =========================================================================
    -- NORTHERN STRANGLETHORN / GROM'GOL (Horde — Eastern Kingdoms, zeppelin dock)
    -- NOTE: mapID 10 needs in-game verification via /devmap — may be 50 instead
    -- No explicit outbound edges — bidir return zeppelin to Org is generated
    -- automatically by Dijkstra from Org's bidir edge.
    -- =========================================================================
    [10] = {},

    -- =========================================================================
    -- IRONFORGE (Alliance — Eastern Kingdoms)
    -- =========================================================================
    [87] = {
        { to = 84, x = 0.73, y = 0.50, cost = 60, type = "tram", label = "Deeprun Tram to Stormwind", bidir = true },
    },

    -- =========================================================================
    -- UNDERCITY (Horde — Eastern Kingdoms)
    -- =========================================================================
    [90] = {
        -- Reverse zeppelin to Org handled by bidir on Org's edge
        { to = 480, x = 0.54, y = 0.11, cost = 5, type = "portal", label = "Orb of Translocation to Silvermoon", faction = "Horde", bidir = true },
    },

    -- =========================================================================
    -- SILVERMOON CITY (Horde — Eastern Kingdoms)
    -- =========================================================================
    [480] = {
        -- Reverse translocation to UC handled by bidir on UC's edge
        -- Silvermoon has no other outbound portals; routes go via UC → Org
    },

    -- =========================================================================
    -- ORIBOS (Shadowlands hub)
    -- =========================================================================
    [1670] = {
        { to = 84,   x = 0.2097, y = 0.4600, cost = 5, type = "portal", label = "Portal to Stormwind",  faction = "Alliance" },
        { to = 85,   x = 0.2097, y = 0.4600, cost = 5, type = "portal", label = "Portal to Orgrimmar",  faction = "Horde" },
    },

    -- =========================================================================
    -- VALDRAKKEN (Dragon Isles hub)
    -- =========================================================================
    [2112] = {
        { to = 84,   x = 0.53, y = 0.63, cost = 5, type = "portal", label = "Portal to Stormwind",  faction = "Alliance" },
        { to = 85,   x = 0.53, y = 0.63, cost = 5, type = "portal", label = "Portal to Orgrimmar",  faction = "Horde" },
        { to = 2339, x = 0.53, y = 0.63, cost = 5, type = "portal", label = "Portal to Dornogal" },
    },

    -- =========================================================================
    -- DALARAN — Legion (Broken Isles hub)
    -- =========================================================================
    [627] = {
        { to = 84,   x = 0.40, y = 0.63, cost = 5, type = "portal", label = "Portal to Stormwind",  faction = "Alliance" },
        { to = 85,   x = 0.55, y = 0.24, cost = 5, type = "portal", label = "Portal to Orgrimmar",  faction = "Horde" },
    },

    -- =========================================================================
    -- DALARAN — Northrend
    -- =========================================================================
    [125] = {
        { to = 84,  x = 0.40, y = 0.63, cost = 5, type = "portal", label = "Portal to Stormwind",    faction = "Alliance" },
        { to = 85,  x = 0.55, y = 0.24, cost = 5, type = "portal", label = "Portal to Orgrimmar",    faction = "Horde" },
        { to = 71,  x = 0.26, y = 0.45, cost = 5, type = "portal", label = "Portal to Tanaris (CoT)" },
    },

    -- =========================================================================
    -- BOREAN TUNDRA (Northrend entry point — boats/zeppelins)
    -- =========================================================================
    [114] = {
        -- Reverse boat/zep to SW/Org handled by bidir on their edges
        -- Same-continent flight to Dalaran Northrend
        { to = 125, x = 0.50, y = 0.50, cost = 180, type = "flight", label = "Fly to Dalaran" },
    },

    -- =========================================================================
    -- SHATTRATH (Outland hub)
    -- =========================================================================
    [111] = {
        { to = 84,  x = 0.57, y = 0.48, cost = 5, type = "portal", label = "Portal to Stormwind",    faction = "Alliance" },
        { to = 85,  x = 0.56, y = 0.49, cost = 5, type = "portal", label = "Portal to Orgrimmar",    faction = "Horde" },
    },

    -- =========================================================================
    -- BORALUS (Alliance BfA hub — Kul Tiras)
    -- =========================================================================
    [1161] = {
        { to = 84,   x = 0.70, y = 0.17, cost = 5, type = "portal", label = "Portal to Stormwind",   faction = "Alliance" },
        { to = 87,   x = 0.70, y = 0.17, cost = 5, type = "portal", label = "Portal to Ironforge",   faction = "Alliance" },
        { to = 525,  x = 0.70, y = 0.17, cost = 5, type = "portal", label = "Portal to Jade Forest", faction = "Alliance" },
        { to = 111,  x = 0.70, y = 0.17, cost = 5, type = "portal", label = "Portal to Shattrath",   faction = "Alliance" },
    },

    -- =========================================================================
    -- DAZAR'ALOR (Horde BfA hub — Zandalar)
    -- =========================================================================
    [1165] = {
        { to = 85,   x = 0.50, y = 0.37, cost = 5, type = "portal", label = "Portal to Orgrimmar",     faction = "Horde" },
        { to = 88,   x = 0.50, y = 0.37, cost = 5, type = "portal", label = "Portal to Thunder Bluff", faction = "Horde" },
        { to = 480,  x = 0.50, y = 0.37, cost = 5, type = "portal", label = "Portal to Silvermoon",    faction = "Horde" },
        { to = 111,  x = 0.50, y = 0.37, cost = 5, type = "portal", label = "Portal to Shattrath",     faction = "Horde" },
    },

    -- =========================================================================
    -- JADE FOREST (Pandaria — Shrine portals)
    -- =========================================================================
    [525] = {
        -- Shrine of Seven Stars (Alliance) / Shrine of Two Moons (Horde)
        { to = 84,   x = 0.85, y = 0.34, cost = 5, type = "portal", label = "Portal to Stormwind",   faction = "Alliance" },
        { to = 85,   x = 0.56, y = 0.32, cost = 5, type = "portal", label = "Portal to Orgrimmar",   faction = "Horde" },
    },

    -- =========================================================================
    -- ASHRAN (Draenor hub — Stormshield / Warspear)
    -- =========================================================================
    [588] = {
        { to = 84,   x = 0.36, y = 0.59, cost = 5, type = "portal", label = "Portal to Stormwind",   faction = "Alliance" },
        { to = 85,   x = 0.60, y = 0.51, cost = 5, type = "portal", label = "Portal to Orgrimmar",   faction = "Horde" },
    },
}

-- Expose for dev tools (TransportRecorder reads this for audit/snap)
TransportGraph.STATIC_EDGES = STATIC_EDGES

-- =============================================================================
-- AUTO-RESOLVE COORDINATES FROM MAP API
-- Queries C_AreaPoiInfo for portal/transport POIs in each hub zone at runtime.
-- This eliminates the need for manual coordinate recording — the same data the
-- world map uses to show portal icons is pulled automatically.
-- Fallback: ns.STATIC_LOCATIONS for zones where the API returns no data.
-- =============================================================================
local coordsResolved = false

local C_AreaPoiInfo = C_AreaPoiInfo

-- Destination zone names that differ from map POI portal names.
-- Maps destination mapID → keyword to search for in portal POI names.
local DEST_NAME_OVERRIDES = {
    [1165] = "Zuldazar",       -- C_Map says "Dazar'alor", portal labeled "Zuldazar (BfA)"
}

-- Sub-zone mapIDs to also query for each hub (portal rooms, harbors, etc.)
local SUB_ZONE_MAPS = {
    [84]  = {1553},   -- Stormwind → portal room (Sanctum of the Sages)
    [85]  = {1554},   -- Orgrimmar → portal room (Pathfinder's Den)
}

--- Query C_AreaPoiInfo for transport-related POIs in a given map.
--- @param mapID number
--- @return table[] Array of {name, x, y}
local function QueryMapTransportPOIs(mapID)
    local results = {}
    if not C_AreaPoiInfo then return results end
    local poiIDs = C_AreaPoiInfo.GetAreaPOIForMap(mapID)
    if not poiIDs then return results end

    for _, poiID in ipairs(poiIDs) do
        local info = C_AreaPoiInfo.GetAreaPOIInfo(mapID, poiID)
        if info and info.name and info.position then
            local n = info.name:lower()
            if n:find("portal", 1, true) or n:find("tram", 1, true)
                or n:find("boat", 1, true) or n:find("ship", 1, true)
                or n:find("zeppelin", 1, true) or n:find("ferry", 1, true) then
                tinsert(results, {
                    name = info.name,
                    x = info.position.x,
                    y = info.position.y,
                })
            end
        end
    end
    return results
end

--- Match a transport edge to a POI entry by destination zone name.
--- Works with both API POIs and StaticLocations entries (anything with .name, .x, .y).
--- @param entries table[] Array of {name, x, y} entries
--- @param edge table Transport edge with .to (destination mapID)
--- @return table|nil Matching entry
local function FindNameMatch(entries, edge)
    local searchName = DEST_NAME_OVERRIDES[edge.to]
    if not searchName then
        local destInfo = C_Map.GetMapInfo(edge.to)
        searchName = destInfo and destInfo.name
    end
    if not searchName then return nil end

    local kw = searchName:lower()

    -- Pass 1: full destination name substring (e.g. "Oribos" in "Oribos Portal")
    for _, entry in ipairs(entries) do
        if entry.name:lower():find(kw, 1, true) then
            return entry
        end
    end

    -- Pass 2: first word only (handles "Shattrath City" → "Shattrath (TBC) Portal")
    local firstWord = kw:match("^(%S+)")
    if firstWord and firstWord ~= kw then
        for _, entry in ipairs(entries) do
            if entry.name:lower():find(firstWord, 1, true) then
                return entry
            end
        end
    end

    return nil
end

--- Resolve all edge coordinates. Runs once lazily on first route request.
--- Primary: C_AreaPoiInfo live API. Fallback: StaticLocations.
local function ResolveEdgeCoords()
    if coordsResolved then return end
    coordsResolved = true

    local staticLocs = ns.STATIC_LOCATIONS

    for nodeID, edges in pairs(STATIC_EDGES) do
        -- Query live API for this hub + any sub-zones (portal rooms)
        local pois = QueryMapTransportPOIs(nodeID)
        local subZones = SUB_ZONE_MAPS[nodeID]
        if subZones then
            for _, subMapID in ipairs(subZones) do
                local subPOIs = QueryMapTransportPOIs(subMapID)
                for _, poi in ipairs(subPOIs) do
                    tinsert(pois, poi)
                end
            end
        end

        -- Build StaticLocations transport entries as fallback
        local staticTransport = {}
        local locs = staticLocs and staticLocs[nodeID]
        if locs then
            for _, loc in ipairs(locs) do
                if loc.category == "portal" or loc.category == "tram"
                    or loc.category == "boat" or loc.category == "zeppelin" then
                    tinsert(staticTransport, loc)
                end
            end
        end

        -- Count portal-only entries for generic fallback (e.g. "Other Continents")
        local apiPortalOnly = {}
        for _, poi in ipairs(pois) do
            if poi.name:lower():find("portal", 1, true) then
                tinsert(apiPortalOnly, poi)
            end
        end
        local staticPortalOnly = {}
        for _, loc in ipairs(staticTransport) do
            if loc.category == "portal" then
                tinsert(staticPortalOnly, loc)
            end
        end

        for _, edge in ipairs(edges) do
            if edge.type == "portal" or edge.type == "tram"
                or edge.type == "boat" or edge.type == "zeppelin" then
                -- Try live API POIs first (name match)
                local match = #pois > 0 and FindNameMatch(pois, edge)
                if match then
                    edge.x = match.x
                    edge.y = match.y
                    edge._resolved = "api"
                elseif #staticTransport > 0 then
                    -- Fallback to StaticLocations (name match)
                    match = FindNameMatch(staticTransport, edge)
                    if match then
                        edge.x = match.x
                        edge.y = match.y
                        edge._resolved = "static"
                    end
                end

                -- Generic fallback: if still unresolved and there's exactly one
                -- portal entry (e.g. "Other Continents"), use it for all portal edges
                if not edge._resolved and edge.type == "portal" then
                    if #apiPortalOnly == 1 then
                        edge.x = apiPortalOnly[1].x
                        edge.y = apiPortalOnly[1].y
                        edge._resolved = "api"
                    elseif #staticPortalOnly == 1 then
                        edge.x = staticPortalOnly[1].x
                        edge.y = staticPortalOnly[1].y
                        edge._resolved = "static"
                    end
                end
            end
        end
    end

    -- =========================================================================
    -- APPLY SNAPS: override coords from /devt snap recordings in SavedVariables.
    -- Keyed by "nodeID-destID", e.g. "85-88" for Org→TB edge.
    -- =========================================================================
    local snaps = EasyFindDevDB and EasyFindDevDB.transportSnaps
    if snaps then
        for nodeID, edges in pairs(STATIC_EDGES) do
            for _, edge in ipairs(edges) do
                local snapKey = sformat("%d-%d", nodeID, edge.to)
                local snap = snaps[snapKey]
                if snap and snap.x and snap.y then
                    edge.x = snap.x
                    edge.y = snap.y
                    edge._resolved = "snap"
                end
            end
        end
    end

    -- =========================================================================
    -- MERGE RECORDED EDGES: add new edges from /devt record into the live graph.
    -- Each record needs: mapID (from), to (dest mapID), x, y.
    -- Records without a 'to' field are coordinate-only (used for snap-like fixes).
    -- =========================================================================
    local recorded = EasyFindDevDB and EasyFindDevDB.transportEdges
    if recorded then
        for _, rec in ipairs(recorded) do
            if rec.mapID and rec.to and rec.x and rec.y then
                -- Ensure the source node exists in STATIC_EDGES
                if not STATIC_EDGES[rec.mapID] then
                    STATIC_EDGES[rec.mapID] = {}
                end
                -- Check for duplicate (same from→to)
                local isDup = false
                for _, edge in ipairs(STATIC_EDGES[rec.mapID]) do
                    if edge.to == rec.to then
                        -- Update existing edge coords
                        edge.x = rec.x
                        edge.y = rec.y
                        edge._resolved = "recorded"
                        isDup = true
                        break
                    end
                end
                if not isDup then
                    tinsert(STATIC_EDGES[rec.mapID], {
                        to      = rec.to,
                        x       = rec.x,
                        y       = rec.y,
                        cost    = rec.cost or 90,
                        type    = rec.type or "portal",
                        label   = rec.label or "Recorded transport",
                        faction = rec.faction,
                        _resolved = "recorded",
                    })
                end
            end
        end
    end
end

-- Expose for dev tools
TransportGraph.ResolveEdgeCoords = ResolveEdgeCoords
TransportGraph.QueryMapTransportPOIs = QueryMapTransportPOIs

-- =============================================================================
-- MAP → CONTINENT CACHE
-- Walks up the map hierarchy to find the continent parent.
-- =============================================================================
local mapContinentCache = {}

local function GetContinentForMap(mapID)
    if not mapID then return nil end
    if mapContinentCache[mapID] then return mapContinentCache[mapID] end

    local id = mapID
    for _ = 1, 10 do  -- safety limit
        if CONTINENT_MAP[id] then
            mapContinentCache[mapID] = id
            return id
        end
        local info = C_Map.GetMapInfo(id)
        if not info or not info.parentMapID or info.parentMapID == 0 then break end
        id = info.parentMapID
    end

    mapContinentCache[mapID] = nil
    return nil
end

-- =============================================================================
-- NODE RESOLUTION
-- Resolves a mapID to the nearest graph node by walking up the hierarchy.
-- =============================================================================
function TransportGraph:ResolveNode(mapID)
    if not mapID then return nil end

    -- Direct alias?
    if NODE_ALIASES[mapID] then
        local alias = NODE_ALIASES[mapID]
        if STATIC_EDGES[alias] then return alias end
    end

    -- Direct node?
    if STATIC_EDGES[mapID] then return mapID end

    -- Walk up hierarchy
    local id = mapID
    for _ = 1, 10 do
        local info = C_Map.GetMapInfo(id)
        if not info or not info.parentMapID or info.parentMapID == 0 then break end
        id = info.parentMapID
        if NODE_ALIASES[id] then
            local alias = NODE_ALIASES[id]
            if STATIC_EDGES[alias] then return alias end
        end
        if STATIC_EDGES[id] then return id end
    end

    -- Continent fallback: find the zone's continent and use its primary hub.
    -- Faction-aware: prefer hubs reachable by the player's faction first.
    local continent = GetContinentForMap(mapID)
    if continent and CONTINENT_HUBS[continent] then
        local hubs = CONTINENT_HUBS[continent]
        local playerFaction = UnitFactionGroup("player")
        -- Phase 1: faction-matching or neutral hubs
        for _, hubID in ipairs(hubs) do
            if STATIC_EDGES[hubID] then
                local hf = HUB_FACTION[hubID]
                if not hf or hf == playerFaction then
                    return hubID
                end
            end
        end
        -- Phase 2: any hub (cross-faction fallback)
        for _, hubID in ipairs(hubs) do
            if STATIC_EDGES[hubID] then
                return hubID
            end
        end
    end

    return nil
end

-- =============================================================================
-- RESOLVE DESTINATION
-- Given a destination mapID (could be a zone, dungeon zone, etc.), find the
-- graph node we should route TO plus a "last mile" flag.
-- Returns: nodeMapID, needsLastMile
-- =============================================================================
function TransportGraph:ResolveDestination(mapID)
    if not mapID then return nil, false end

    -- If the dest IS a graph node, no last mile needed
    if STATIC_EDGES[mapID] then return mapID, false end
    if NODE_ALIASES[mapID] and STATIC_EDGES[NODE_ALIASES[mapID]] then
        return NODE_ALIASES[mapID], false
    end

    -- Walk up to find nearest hub; destination itself needs last mile
    local node = self:ResolveNode(mapID)
    if node then
        -- If resolved to self (mapID is a child of a hub), route to the hub
        return node, (node ~= mapID)
    end

    return nil, false
end

-- =============================================================================
-- CHECK SAME CONTINENT
-- =============================================================================
function TransportGraph:SameContinent(mapA, mapB)
    local cA = GetContinentForMap(mapA)
    local cB = GetContinentForMap(mapB)
    if cA and cB and cA == cB then return true end
    return false
end

-- =============================================================================
-- DIJKSTRA'S ALGORITHM
-- FindRoute(fromMapID, toMapID) → array of steps or nil
-- Each step: {from, to, x, y, label, type, cost}
-- =============================================================================
function TransportGraph:FindRoute(fromMapID, toMapID)
    if not fromMapID or not toMapID then return nil end
    if fromMapID == toMapID then return nil end  -- already there

    -- Lazy-resolve portal coords from StaticLocations on first route request
    ResolveEdgeCoords()

    local playerFaction = UnitFactionGroup("player")

    -- Build adjacency from static edges (faction-filtered)
    local adj = {}
    for node, edges in pairs(STATIC_EDGES) do
        adj[node] = adj[node] or {}
        for _, edge in ipairs(edges) do
            -- Faction filter
            if edge.faction and edge.faction ~= "NONE" and edge.faction ~= playerFaction then
                -- skip: wrong faction
            else
                tinsert(adj[node], edge)

                -- Bidirectional edges
                if edge.bidir then
                    adj[edge.to] = adj[edge.to] or {}
                    tinsert(adj[edge.to], {
                        to = node,
                        x = edge.x, y = edge.y,  -- departure coords (reversed)
                        cost = edge.cost,
                        type = edge.type,
                        label = edge.label .. " (return)",
                        faction = edge.faction,
                    })
                end
            end
        end
    end

    -- Dijkstra
    local dist = { [fromMapID] = 0 }
    local prev = {}
    local visited = {}
    local queue = { fromMapID }

    while #queue > 0 do
        -- Find unvisited node with smallest distance
        local bestIdx, bestNode, bestDist = nil, nil, math.huge
        for i, node in ipairs(queue) do
            local d = dist[node] or math.huge
            if d < bestDist then
                bestIdx, bestNode, bestDist = i, node, d
            end
        end

        if not bestNode or bestDist == math.huge then break end
        if bestNode == toMapID then break end  -- found shortest path

        tremove(queue, bestIdx)
        visited[bestNode] = true

        local edges = adj[bestNode]
        if edges then
            for _, edge in ipairs(edges) do
                if not visited[edge.to] then
                    local newDist = bestDist + edge.cost
                    if not dist[edge.to] or newDist < dist[edge.to] then
                        dist[edge.to] = newDist
                        prev[edge.to] = { from = bestNode, edge = edge }
                        -- Add to queue if not already present
                        local inQueue = false
                        for _, q in ipairs(queue) do
                            if q == edge.to then inQueue = true; break end
                        end
                        if not inQueue then
                            tinsert(queue, edge.to)
                        end
                    end
                end
            end
        end
    end

    -- No path found?
    if not prev[toMapID] then return nil end

    -- Reconstruct path
    local steps = {}
    local node = toMapID
    while prev[node] do
        local p = prev[node]
        tinsert(steps, 1, {
            from  = p.from,
            to    = p.edge.to,
            x     = p.edge.x,
            y     = p.edge.y,
            label = p.edge.label,
            type  = p.edge.type,
            cost  = p.edge.cost,
        })
        node = p.from
    end

    return steps
end

-- =============================================================================
-- GET NODE NAME (for display)
-- =============================================================================
function TransportGraph:GetNodeName(mapID)
    if not mapID then return "Unknown" end
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name or ("Map " .. tostring(mapID))
end

-- =============================================================================
-- DEBUG: dump graph info
-- =============================================================================
function TransportGraph:DumpGraph()
    local playerFaction = UnitFactionGroup("player")
    local count = 0
    for node, edges in pairs(STATIC_EDGES) do
        local name = self:GetNodeName(node)
        local validEdges = 0
        for _, edge in ipairs(edges) do
            if not edge.faction or edge.faction == playerFaction then
                validEdges = validEdges + 1
            end
        end
        if validEdges > 0 then
            print(sformat("  |cFFFFD100%s|r (mapID %d) — %d connections", name, node, validEdges))
            count = count + 1
        end
    end
    print(sformat("|cFF00FF00TransportGraph:|r %d nodes in graph for %s", count, playerFaction))
end
