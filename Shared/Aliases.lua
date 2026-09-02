local _, ns = ...

---@class AliasInfo
---@field text string original (untrimmed) alias text
---@field key string canonical entry key produced by Aliases:GetEntryKey
---@field name string display name of the aliased entry
---@field snapshot table? captured fields for map/zone and catalog-item aliases (see Aliases:Add)

---@class Aliases
local Aliases = {}
if ns then ns.Aliases = Aliases end

local Utils = ns.Utils
local SearchText = ns.SearchText
local strtrim = strtrim
local sformat = string.format
local mfloor = Utils.mfloor
local ssub = Utils.ssub
local smatch = Utils.smatch
local tinsert = Utils.tinsert
local tsort = Utils.tsort
local time = time

-- All alias keys go through SearchText.Normalize so non-English user input
-- ("Münzen", "Élune", etc.) lowercases consistently. WoW's string.lower
-- is ASCII-only and leaves non-ASCII bytes untouched, which would make
-- "MÜNZEN" and "münzen" hash to different keys.
local normalize = SearchText.Normalize

local function IsMapAliasTarget(data)
    return data and (data.mapSearchResult or data.isZone or data.isDungeonEntrance
        or data.zoneMapID or data.entranceMapID
        or (data.category and (data.x or data.entranceX or data.mapID or data.coordMapID)))
end

local function MapAliasKey(data)
    local name = normalize(data.name or "")
    if name == "" then return nil end
    local mapID = data.mapID or data.coordMapID or data.zoneMapID
        or data.entranceMapID or data.parentMapID
        or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
        or 0
    local x = data.x or data.entranceX or 0
    local y = data.y or data.entranceY or 0
    return sformat("map:%s:%d:%s:%d:%d",
        data.category or "location", mapID, name,
        mfloor(x * 10000 + 0.5), mfloor(y * 10000 + 0.5))
end

-- Inverse of MapAliasKey: rebuild a navigable map row straight from its key.
-- Map results aren't in uiSearchData (they're generated live from the map APIs),
-- so a saved reference resolves by reconstructing from the key it stored, no
-- snapshot needed. Covers zones and POIs precisely; the key can't tell a dungeon
-- entrance's own map from its parent zone, so entrances degrade to a map jump.
local function ReconstructMapData(key)
    if type(key) ~= "string" then return nil end
    local body = key:match("^map:(.+)$")
    if not body then return nil end
    local category, mapID, rest = body:match("^([^:]*):(%d+):(.+)$")
    if not category or not rest then return nil end
    local name, xi, yi = rest:match("^(.-):(%d+):(%d+)$")
    if not name then return nil end
    mapID = tonumber(mapID)
    local isZone = category == "zone"
    -- The key stores the NORMALIZED (lowercased) name; showing it raw put
    -- "eastern kingdoms" rows in the results whenever a saved reference
    -- resolved by reconstruction (live map caches now trim on idle, so
    -- that path actually runs). Recover the display name from the
    -- authoritative source: C_Map for zones, the static POI table for
    -- coordinate entries; the key's name stays the fallback.
    local properName
    if isZone and mapID then
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
        if info and info.name and info.name ~= "" then properName = info.name end
    elseif mapID and ns.STATIC_LOCATIONS then
        local locs = ns.STATIC_LOCATIONS[mapID]
        if locs then
            local xn, yn = tonumber(xi), tonumber(yi)
            for i = 1, #locs do
                local poi = locs[i]
                if mfloor((poi.x or 0) * 10000 + 0.5) == xn
                   and mfloor((poi.y or 0) * 10000 + 0.5) == yn then
                    properName = poi.name
                    break
                end
            end
        end
    end
    return {
        name = properName or name,
        nameLower = name,
        category = category,
        mapSearchResult = true,
        mapID = mapID,
        x = tonumber(xi) / 10000,
        y = tonumber(yi) / 10000,
        isZone = isZone or nil,
        zoneMapID = isZone and mapID or nil,
    }
end

---Returns the canonical key for an entry, used to dedupe aliases and to
---look an entry up later. Returns nil if the entry has no identifying fields.
---@param data table?
---@return string?
function Aliases:GetEntryKey(data)
    if not data then return nil end
    if data.mountID       then return "mount:"          .. data.mountID end
    if data.toyItemID     then return "toy:"            .. data.toyItemID end
    if data.petID         then return "pet:"            .. data.petID end
    if data.outfitID      then return "outfit:"         .. data.outfitID end
    if data.transmogSetID then return "appearanceSet:"  .. data.transmogSetID end
    if data.macroIndex    then return "macro:"          .. data.macroIndex end
    if data.factionID     then return "reputation:"     .. data.factionID end
    if data.achievementID then return "achievement:"    .. data.achievementID end
    if data.itemID and data.category == "Loot" then return "loot:" .. data.itemID end
    if data.catalogItem and data.itemID then return "catalogitem:" .. data.itemID end
    if data.category == "Currency" and data.steps then
        for i = 1, #data.steps do
            local cid = data.steps[i].currencyID
            if cid then return "currency:" .. cid end
        end
    end
    if IsMapAliasTarget(data) then
        return MapAliasKey(data)
    end
    if data.path and #data.path > 0 then
        return "ui:" .. table.concat(data.path, ">") .. ">" .. (data.name or "")
    end
    if data.name then return "ui:" .. data.name end
    return nil
end

-- key -> entry index over uiSearchData. FindEntryByKey is hit per shortkey on
-- every populate and per alias on every keystroke; a linear scan there lagged the
-- search bar. The index is built lazily, reused across calls, and dropped by
-- InvalidateKeyIndex when search data changes (ResetSearchCache), with a length
-- guard as a backstop, so lookups are O(1).
local keyIndex
local keyIndexLen

function Aliases:InvalidateKeyIndex()
    keyIndex = nil
end

local function EntryKeyIndex(data)
    if keyIndex and keyIndexLen == #data then return keyIndex end
    local idx = {}
    for i = 1, #data do
        local entry = data[i]
        local k = Aliases:GetEntryKey(entry)
        if k and idx[k] == nil then idx[k] = entry end
    end
    keyIndex = idx
    keyIndexLen = #data
    return idx
end

-- Rows that never live in uiSearchData (built per query by a provider)
-- resolve through a registered resolver for their key prefix. The provider
-- registers next to its own code; this file stays ignorant of provider
-- internals. History demands it: map rows, catalog items, and achievements
-- each shipped as bespoke branches here, and each was a silent learn/alias
-- bug first.
local keyResolvers = {}

function Aliases:RegisterKeyResolver(prefix, resolver)
    keyResolvers[prefix] = resolver
end

function Aliases:FindEntryByKey(key)
    if not key then return nil end
    local data = ns.Database and ns.Database.uiSearchData
    if data then
        local hit = EntryKeyIndex(data)[key]
        if hit then return hit end
    end
    -- Aliases keep a snapshot (it preserves the proper-case name and icon for
    -- display); honour it first so aliased map rows render exactly as captured.
    if EasyFind and EasyFind.db and EasyFind.db.aliases then
        for _, info in pairs(EasyFind.db.aliases) do
            if info.key == key and info.snapshot then
                return info.snapshot
            end
        end
    end
    local prefix = smatch(key, "^(%w+):")
    local resolver = prefix and keyResolvers[prefix]
    if resolver then
        return resolver(key)
    end
    return nil
end

-- Map rows are generated live from the map APIs; their resolver is the key
-- inverse defined above.
Aliases:RegisterKeyResolver("map", ReconstructMapData)

-- Map/zone/POI rows come from the live map search, not uiSearchData, so a saved
-- reference (alias or shortkey) can't look them up later by key. Capture the
-- fields needed to reproduce the row so resolution can fall back to this. Returns
-- nil for rows that resolve normally from uiSearchData (collections, abilities,
-- panels), which intentionally bind only where they currently exist.
function Aliases:BuildSnapshot(data)
    -- Catalog items never live in uiSearchData (their rows are built per
    -- query from the packed item blob), so FindEntryByKey can never resolve
    -- them; the snapshot IS the row. Mirror the exact field set ItemSearch
    -- builds so the captured row renders and acts like a natural one.
    if data and data.catalogItem and data.itemID then
        return {
            itemID = data.itemID,
            catalogItem = true,
            lookupRow = true,
            category = data.category,
            name = data.name,
            nameLower = data.nameLower,
            quality = data.quality,
        }
    end
    if not IsMapAliasTarget(data) then return nil end
    local currentMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    return {
        name = data.name,
        nameLower = data.nameLower,
        category = data.category,
        icon = data.icon,
        mapSearchResult = true,
        mapID = data.mapID or data.coordMapID or data.entranceMapID or data.zoneMapID or currentMapID,
        zoneName = data.zoneName,
        pathPrefix = data.pathPrefix,
        x = data.x, y = data.y,
        keywords = data.keywords,
        isZone = data.isZone,
        zoneMapID = data.zoneMapID,
        zoneParentMapID = data.zoneParentMapID,
        parentMapID = data.parentMapID,
        coordMapID = data.coordMapID,
        entranceMapID = data.entranceMapID,
        entranceX = data.entranceX,
        entranceY = data.entranceY,
        entranceIcon = data.entranceIcon,
        entranceCategory = data.entranceCategory,
        isDungeonEntrance = data.isDungeonEntrance,
    }
end

---Stores an alias pointing at the given entry. Returns true on success,
---false if the alias text or entry is unsuitable.
---@param aliasText string
---@param data table
---@return boolean
function Aliases:Add(aliasText, data)
    if not EasyFind or not EasyFind.db then return false end
    aliasText = strtrim(aliasText or "")
    if aliasText == "" then return false end
    local key = Aliases:GetEntryKey(data)
    if not key then return false end
    if type(EasyFind.db.aliases) ~= "table" then
        EasyFind.db.aliases = {}
    end
    local snapshot = self:BuildSnapshot(data)
    EasyFind.db.aliases[normalize(aliasText)] = {
        text = aliasText,
        key  = key,
        name = data.name or aliasText,
        snapshot = snapshot,
    }
    return true
end

function Aliases:Remove(aliasText)
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return end
    EasyFind.db.aliases[normalize(strtrim(aliasText or ""))] = nil
end

-- Category alias (GitHub #21): the trigger binds to a whole map category
-- ("mapcat:flightmaster") instead of one row. When it matches, the query
-- pipeline expands it to the nearest results of that category, so "fm" can
-- surface the local flight masters on top no matter what else matches.
function Aliases:AddCategory(aliasText, category, name)
    if not (EasyFind and EasyFind.db) then return false end
    aliasText = strtrim(aliasText or "")
    if aliasText == "" or not category then return false end
    if type(EasyFind.db.aliases) ~= "table" then
        EasyFind.db.aliases = {}
    end
    EasyFind.db.aliases[normalize(aliasText)] = {
        text = aliasText,
        key  = "mapcat:" .. category,
        name = name or category,
    }
    return true
end

-- Add/replace an alias by stable row key (used by the options table, where the
-- live entry may not be present to call Add).
function Aliases:AddByKey(aliasText, key, name)
    if not (EasyFind and EasyFind.db and key) then return false end
    aliasText = strtrim(aliasText or "")
    if aliasText == "" then return false end
    EasyFind.db.aliases = EasyFind.db.aliases or {}
    EasyFind.db.aliases[normalize(aliasText)] = { text = aliasText, key = key, name = name or aliasText }
    return true
end

-- Remove every alias pointing at a given row key.
function Aliases:RemoveByKey(key)
    if not (EasyFind and EasyFind.db and EasyFind.db.aliases and key) then return end
    for storedKey, info in pairs(EasyFind.db.aliases) do
        if info.key == key then EasyFind.db.aliases[storedKey] = nil end
    end
end

function Aliases:ClearAll()
    if not EasyFind or not EasyFind.db then return end
    EasyFind.db.aliases = {}
end

function Aliases:ForEach(cb)
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return end
    for _, info in pairs(EasyFind.db.aliases) do
        cb(info.text, info)
    end
end

-- Flat list of {text, key, name} for import/export.
function Aliases:ExportList()
    local out = {}
    if EasyFind and EasyFind.db and EasyFind.db.aliases then
        for _, info in pairs(EasyFind.db.aliases) do
            out[#out + 1] = { text = info.text, key = info.key, name = info.name }
        end
    end
    return out
end

-- True if an alias for this trigger text already exists.
function Aliases:HasAlias(text)
    if not (EasyFind and EasyFind.db and EasyFind.db.aliases) then return false end
    if type(text) ~= "string" then return false end
    return EasyFind.db.aliases[normalize(text)] ~= nil
end

function Aliases:ImportList(list, skipExisting)
    if type(list) ~= "table" or not (EasyFind and EasyFind.db) then return 0 end
    EasyFind.db.aliases = EasyFind.db.aliases or {}
    local n = 0
    for i = 1, #list do
        local r = list[i]
        if r and r.text and strtrim(r.text) ~= "" and r.key then
            local normKey = normalize(r.text)
            if not (skipExisting and EasyFind.db.aliases[normKey]) then
                EasyFind.db.aliases[normKey] = {
                    text = r.text, key = r.key, name = r.name or r.text,
                }
                n = n + 1
            end
        end
    end
    return n
end

-- Blacklist: rows the user never wants in any search results, keyed by
-- the same stable row keys as aliases and shortkeys (one identity scheme,
-- one owner: GetEntryKey). Stored as db.blacklist[key] = {name, category}
-- so the options tab can list and restore entries without the live row.
-- Suppression happens at ONE gate per surface via Blacklist:Contains.
local Blacklist = {}
ns.Blacklist = Blacklist

-- Cached count so the per-keystroke HasAny gate is a number compare;
-- invalidated on every mutation and lazily recounted.
local blacklistCount

function Blacklist:HasAny()
    if blacklistCount == nil then
        local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
        local n = 0
        if type(store) == "table" then
            for _ in pairs(store) do n = n + 1 end
        end
        blacklistCount = n
    end
    return blacklistCount > 0
end

-- Hot path (result emit, per row): the entry key is computed once per
-- entry lifetime and cached on the entry (false = unkeyable), so steady
-- state is one rawget and one table lookup, no allocations.
function Blacklist:Contains(data)
    if not data then return false end
    local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
    if not store then return false end
    local key = rawget(data, "_efBLKey")
    if key == nil then
        key = Aliases:GetEntryKey(data) or false
        rawset(data, "_efBLKey", key)
    end
    return key ~= false and store[key] ~= nil
end

function Blacklist:Add(data)
    if not (EasyFind and EasyFind.db) then return false end
    local key = Aliases:GetEntryKey(data)
    if not key then return false end
    if type(EasyFind.db.blacklist) ~= "table" then
        EasyFind.db.blacklist = {}
    end
    EasyFind.db.blacklist[key] = { name = data.name or key, category = data.category }
    blacklistCount = nil
    -- A pin is a standing search result; keeping it while blacklisted
    -- would make the blacklist look broken. Shortkeys stay: they fire
    -- without search and killing a bind silently is worse.
    if ns.UIPins and ns.UIPins.IsPinned(data) then
        ns.UIPins.Unpin(data)
    end
    return true
end

function Blacklist:RemoveByKey(key)
    local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
    if not (store and key) then return end
    store[key] = nil
    blacklistCount = nil
end

function Blacklist:ClearAll()
    if not (EasyFind and EasyFind.db) then return end
    EasyFind.db.blacklist = {}
    blacklistCount = nil
end

function Blacklist:ForEach(cb)
    local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
    if not store then return end
    for key, info in pairs(store) do
        cb(key, info)
    end
end

-- Flat list of {key, name, category} for import/export (same shape family
-- as Aliases:ExportList).
function Blacklist:ExportList()
    local out = {}
    local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
    if store then
        for key, info in pairs(store) do
            out[#out + 1] = { key = key, name = info.name, category = info.category }
        end
    end
    return out
end

-- True if this row key is already blacklisted.
function Blacklist:Has(key)
    local store = EasyFind and EasyFind.db and EasyFind.db.blacklist
    return type(store) == "table" and key ~= nil and store[key] ~= nil
end

function Blacklist:ImportList(list, skipExisting)
    if type(list) ~= "table" or not (EasyFind and EasyFind.db) then return 0 end
    if type(EasyFind.db.blacklist) ~= "table" then
        EasyFind.db.blacklist = {}
    end
    local n = 0
    for i = 1, #list do
        local r = list[i]
        if r and r.key then
            if not (skipExisting and EasyFind.db.blacklist[r.key]) then
                EasyFind.db.blacklist[r.key] = { name = r.name or r.key, category = r.category }
                n = n + 1
            end
        end
    end
    blacklistCount = nil
    return n
end

-- Learned picks: choosing a result after typing a query teaches the ranking,
-- so that result surfaces on top the next time the same query is typed (below
-- explicit aliases, which are deliberate and must win). Same identity scheme
-- as aliases/shortkeys/blacklist: one stable key per row via GetEntryKey.
-- Stored as db.queryLearn[query] = { key, n, at, snapshot? }. Last pick wins;
-- n and at are kept for the LRU cap and future weighting. Map rows carry a
-- snapshot like aliases do, so a learned map pick renders as captured.
local Learned = {}
ns.Learned = Learned

local LEARN_CAP = 200

local function TrimLearned(store)
    local count = 0
    for _ in pairs(store) do count = count + 1 end
    while count > LEARN_CAP do
        local oldestQuery, oldestAt
        for query, rec in pairs(store) do
            local at = rec.at or 0
            if not oldestAt or at < oldestAt then
                oldestAt = at
                oldestQuery = query
            end
        end
        store[oldestQuery] = nil
        count = count - 1
    end
end

function Learned:RecordPick(data, typedQuery)
    if not (EasyFind and EasyFind.db) then return end
    if EasyFind.db.learnFromPicks == false then return end
    local query = normalize(strtrim(typedQuery or ""))
    if query == "" then return end
    local key = Aliases:GetEntryKey(data)
    if not key then return end
    if type(EasyFind.db.queryLearn) ~= "table" then
        EasyFind.db.queryLearn = {}
    end
    local store = EasyFind.db.queryLearn
    local rec = store[query]
    if rec and rec.key == key then
        rec.n = (rec.n or 0) + 1
        rec.at = time()
        return
    end
    store[query] = { key = key, n = 1, at = time(), snapshot = Aliases:BuildSnapshot(data) }
    TrimLearned(store)
end

---Returns the entry learned for this (already-normalized) query, or nil.
---Exact match wins; otherwise a prefix relation in either direction counts
---("glad mo" surfaces the pick learned under "glad mount", and typing past
---it to "glad mounts" keeps it). The longest learned query wins ties.
---Typing LESS than a learned query only counts from 4 characters: shorter
---fragments ("gl") are on the way to too many things for one taught habit
---to own them, and the natural ranking should win there. Typing past a
---learned query has no such floor -- it is always at least as specific as
---what was taught.
local LEARN_PREFIX_MIN = 4
function Learned:GetBoost(queryLower)
    if not (EasyFind and EasyFind.db) then return nil end
    if EasyFind.db.learnFromPicks == false then return nil end
    local store = EasyFind.db.queryLearn
    if type(store) ~= "table" then return nil end
    local rec = store[queryLower]
    if not rec and #queryLower >= 2 then
        local bestLen = 0
        for learnedQuery, learnedRec in pairs(store) do
            local ll, ql = #learnedQuery, #queryLower
            if ll > bestLen and ll ~= ql and (ql > ll or ql >= LEARN_PREFIX_MIN) then
                local shorter = ll < ql and ll or ql
                if ssub(learnedQuery, 1, shorter) == ssub(queryLower, 1, shorter) then
                    bestLen = ll
                    rec = learnedRec
                end
            end
        end
    end
    if not rec or not rec.key then return nil end
    local entry = Aliases:FindEntryByKey(rec.key)
    if not entry then entry = rec.snapshot end
    return entry
end

function Learned:ClearAll()
    if EasyFind and EasyFind.db then EasyFind.db.queryLearn = {} end
end

local function ScoreDesc(a, b) return a.score > b.score end

---Returns aliases matching the (already-lowered) query, best match first.
---An alias is scored against the query with the SAME name scorer the rest
---of search uses (Database:ScoreName -- exact, prefix, word-boundary,
---substring, initials, fuzzy typo tolerance with its length thresholds).
---Being an alias decides how high the row is boosted, never whether it
---matches, so aliases get the identical spell protection result names do:
---typos hit at the scorer's tolerance (5+ char queries, name within the
---edit window), gibberish past the alias scores zero and drops the boost,
---and an exact alias outscores a prefix one (GitHub #20).
---Non-exact matches honour the search's 2-character minimum; an exact
---alias fires at any length so a 1-character alias keeps working.
---Nil if no matches or no query.
---@param queryLower string?
---@return { data: table, alias: AliasInfo, score: number }[]?
function Aliases:GetMatches(queryLower)
    if not queryLower or queryLower == "" then return nil end
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return nil end
    local db = ns.Database
    if not (db and db.ScoreName) then return nil end
    local qLen = #queryLower
    local out
    for storedKey, info in pairs(EasyFind.db.aliases) do
        local score
        if storedKey == queryLower or qLen >= 2 then
            score = db:ScoreName(storedKey, queryLower, qLen)
        end
        if score and score > 0 then
            -- Category aliases resolve to a marker the query pipeline
            -- expands into the nearest rows of that category at inject
            -- time; there is no single row to look up here.
            local mapCat = info.key and info.key:match("^mapcat:(.+)$")
            local entry
            if mapCat then
                entry = { mapCategoryAlias = mapCat, name = info.name }
            else
                entry = Aliases:FindEntryByKey(info.key)
            end
            if entry then
                out = out or {}
                tinsert(out, { data = entry, alias = info, score = score })
            end
        end
    end
    if out and #out > 1 then tsort(out, ScoreDesc) end
    return out
end

return Aliases
