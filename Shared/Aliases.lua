local _, ns = ...

---@class AliasInfo
---@field text string original (untrimmed) alias text
---@field key string canonical entry key produced by Aliases:GetEntryKey
---@field name string display name of the aliased entry
---@field snapshot table? captured fields for map/zone aliases (see Aliases:Add)

---@class Aliases
local Aliases = {}
if ns then ns.Aliases = Aliases end

local Utils = ns.Utils
local SearchText = ns.SearchText
local sfind, strtrim = Utils.sfind, strtrim
local sformat = string.format
local mfloor = Utils.mfloor
local tinsert = Utils.tinsert

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
    return {
        name = name,
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
    if data.itemID and data.category == "Loot" then return "loot:" .. data.itemID end
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
    -- Otherwise rebuild map rows from the key (shortkeys, imports, legacy).
    return ReconstructMapData(key)
end

-- Map/zone/POI rows come from the live map search, not uiSearchData, so a saved
-- reference (alias or shortkey) can't look them up later by key. Capture the
-- fields needed to reproduce the row so resolution can fall back to this. Returns
-- nil for rows that resolve normally from uiSearchData (collections, abilities,
-- panels), which intentionally bind only where they currently exist.
function Aliases:BuildSnapshot(data)
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

function Aliases:ImportList(list)
    if type(list) ~= "table" or not (EasyFind and EasyFind.db) then return 0 end
    EasyFind.db.aliases = EasyFind.db.aliases or {}
    local n = 0
    for i = 1, #list do
        local r = list[i]
        if r and r.text and strtrim(r.text) ~= "" and r.key then
            EasyFind.db.aliases[normalize(r.text)] = {
                text = r.text, key = r.key, name = r.name or r.text,
            }
            n = n + 1
        end
    end
    return n
end

---Returns aliases whose stored key contains the (already-lowered) query as
---a substring. Nil if there are no matches or no query.
---@param queryLower string?
---@return { data: table, alias: AliasInfo }[]?
function Aliases:GetMatches(queryLower)
    if not queryLower or queryLower == "" then return nil end
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return nil end
    local out
    for storedKey, info in pairs(EasyFind.db.aliases) do
        if sfind(storedKey, queryLower, 1, true) then
            local entry = Aliases:FindEntryByKey(info.key)
            if entry then
                out = out or {}
                tinsert(out, { data = entry, alias = info })
            end
        end
    end
    return out
end

return Aliases
