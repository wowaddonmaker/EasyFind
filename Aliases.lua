-- User-defined search aliases. Each alias maps a short user-typed
-- string to a stable identifier that points at one Database entry.
-- Aliases survive reloads/relogs (stored in EasyFindDB.aliases) and
-- inject the matching entry into the search results when the user
-- types text that prefix-matches the alias.

local _, ns = ...
local Aliases = {}
ns.Aliases = Aliases

local Utils = ns.Utils
local sfind, slower, strtrim = Utils.sfind, Utils.slower, strtrim
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
    return "map:" .. (data.category or "location") .. ":" .. tostring(mapID)
        .. ":" .. name .. ":" .. tostring(math.floor(x * 10000 + 0.5))
        .. ":" .. tostring(math.floor(y * 10000 + 0.5))
end

-- Build a stable, type-prefixed key for a Database entry. Used both
-- to record an alias target and to find the matching entry later.
-- Returns nil when the entry doesn't expose a stable identifier
-- (e.g. transient pin headers).
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
    -- UI Elements: identify by full path + name. Path may be empty
    -- for top-level entries, so fall back to the bare name.
    if data.path and #data.path > 0 then
        return "ui:" .. table.concat(data.path, ">") .. ">" .. (data.name or "")
    end
    if data.name then return "ui:" .. data.name end
    return nil
end

-- Find the live Database entry that matches a stored alias key. The
-- live entry is what the renderer needs (icons, tooltip targets,
-- secure attributes) so the alias hit looks identical to a normal
-- search hit. Returns nil if the entry has been removed (e.g. mount
-- relearned with a different ID).
function Aliases:FindEntryByKey(key)
    if not key or not ns.Database or not ns.Database.uiSearchData then return nil end
    local data = ns.Database.uiSearchData
    for i = 1, #data do
        local entry = data[i]
        if Aliases:GetEntryKey(entry) == key then return entry end
    end
    -- Map results don't live in uiSearchData (they come from
    -- MapSearch:SearchForUI). Fall back to the snapshot stored when
    -- the alias was added so the alias hit still renders.
    if EasyFind and EasyFind.db and EasyFind.db.aliases then
        for _, info in pairs(EasyFind.db.aliases) do
            if info.key == key and info.snapshot then
                return info.snapshot
            end
        end
    end
    return nil
end

-- Persist an alias. The text is trimmed and lowercased so search
-- matching can stay case-insensitive without per-keystroke lower()
-- calls. Replaces any prior alias with the same text.
function Aliases:Add(aliasText, data)
    if not EasyFind or not EasyFind.db then return false end
    aliasText = strtrim(aliasText or "")
    if aliasText == "" then return false end
    local key = Aliases:GetEntryKey(data)
    if not key then return false end
    if type(EasyFind.db.aliases) ~= "table" then
        EasyFind.db.aliases = {}
    end
    -- Map results aren't in uiSearchData, so FindEntryByKey can't
    -- recover them later. Snapshot the renderable fields so the alias
    -- hit still works after a /reload.
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

-- Remove a previously stored alias by its (case-insensitive) text.
function Aliases:Remove(aliasText)
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return end
    EasyFind.db.aliases[slower(strtrim(aliasText or ""))] = nil
end

function Aliases:ClearAll()
    if not EasyFind or not EasyFind.db then return end
    EasyFind.db.aliases = {}
end

-- Walk all stored aliases. cb(aliasText, info) for each entry.
function Aliases:ForEach(cb)
    if not EasyFind or not EasyFind.db or not EasyFind.db.aliases then return end
    for _, info in pairs(EasyFind.db.aliases) do
        cb(info.text, info)
    end
end

-- Look up entries whose alias prefix-matches the lowercase query.
-- Returns a list of `{ data = liveEntry, alias = info }` so callers
-- can highlight the alias text in the result row if they want.
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
