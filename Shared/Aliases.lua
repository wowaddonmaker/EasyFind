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
local sfind, slower, strtrim = Utils.sfind, Utils.slower, strtrim
local sformat = string.format
local mfloor = Utils.mfloor
local tinsert = Utils.tinsert

local function IsMapAliasTarget(data)
    return data and (data.mapSearchResult or data.isZone or data.isDungeonEntrance
        or data.zoneMapID or data.entranceMapID
        or (data.category and (data.x or data.entranceX or data.mapID or data.coordMapID)))
end

local function MapAliasKey(data)
    local name = slower(data.name or "")
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

function Aliases:FindEntryByKey(key)
    if not key or not ns.Database or not ns.Database.uiSearchData then return nil end
    local data = ns.Database.uiSearchData
    for i = 1, #data do
        local entry = data[i]
        if Aliases:GetEntryKey(entry) == key then return entry end
    end
    if EasyFind and EasyFind.db and EasyFind.db.aliases then
        for _, info in pairs(EasyFind.db.aliases) do
            if info.key == key and info.snapshot then
                return info.snapshot
            end
        end
    end
    return nil
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
    local snapshot
    if IsMapAliasTarget(data) then
        local currentMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        snapshot = {
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
    EasyFind.db.aliases[slower(aliasText)] = {
        text = aliasText,
        key  = key,
        name = data.name or aliasText,
        snapshot = snapshot,
    }
    return true
end

function Aliases:Remove(aliasText)
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return end
    EasyFind.db.aliases[slower(strtrim(aliasText or ""))] = nil
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
