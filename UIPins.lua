local _, ns = ...

local UIPins = {}
ns.UIPins = UIPins

local Utils = ns.Utils
local ipairs, pairs, type = Utils.ipairs, Utils.pairs, Utils.type
local tconcat, tinsert, tremove = Utils.tconcat, Utils.tinsert, Utils.tremove

local charKey

local SIMPLE_FIELDS = {
    "name", "nameLower", "category", "buttonFrame", "flashLabel", "icon",
    "mountID", "spellID", "toyItemID", "petID", "speciesID", "outfitID", "heirloomItemID",
    "macroIndex", "macroIsChar", "bagID", "bagSlot", "bagItemLink",
    "itemID", "encounterID", "instanceID", "lootSlotName", "lootSourceName", "lootInstanceName", "lootSourceType",
    "transmogSetID",
    "factionID", "hasRepBar", "canQueue", "isPvP", "isPvE",
    -- Map-search fields. Without these the row's render branch can't
    -- recognize the entry as a map result, so the general icon goes
    -- missing and the specific icon falls back to the LEFT slot.
    "mapSearchResult", "isZone", "mapID", "zoneName", "pathPrefix",
    "zoneMapType", "zoneParentMapID",
    "achievementID",
}

local TABLE_FIELDS = {
    "path", "steps", "keywords", "keywordsLower", "lootItemLinks",
}

function UIPins.GetKey(data)
    if not data or not data.name then return "" end
    return data.name .. "|" .. tconcat(data.path or {}, ">")
end

local function CleanForStorage(data)
    local clean = {}
    for i = 1, #SIMPLE_FIELDS do
        local key = SIMPLE_FIELDS[i]
        local value = data[key]
        if value ~= nil then clean[key] = value end
    end
    for i = 1, #TABLE_FIELDS do
        local key = TABLE_FIELDS[i]
        local value = data[key]
        if value then
            local copy = {}
            for k, v in pairs(value) do
                if type(v) == "table" then
                    local sub = {}
                    for sk, sv in pairs(v) do sub[sk] = sv end
                    copy[k] = sub
                else
                    copy[k] = v
                end
            end
            clean[key] = copy
        end
    end
    return clean
end

function UIPins.IsCollection(data)
    return data and (data.mountID or data.toyItemID or data.petID or data.outfitID
        or data.heirloomItemID
        or (data.itemID and data.category == "Loot"))
end

function UIPins.GetCharKey()
    if not charKey then
        local name = UnitName("player")
        local realm = GetRealmName()
        charKey = name and realm and (name .. "-" .. realm) or "Unknown"
    end
    return charKey
end

local function GetPinList(data)
    local db = EasyFind and EasyFind.db
    if not db then return nil end
    if UIPins.IsCollection(data) then
        local key = UIPins.GetCharKey()
        db.pinnedUIItemsPerChar = db.pinnedUIItemsPerChar or {}
        db.pinnedUIItemsPerChar[key] = db.pinnedUIItemsPerChar[key] or {}
        return db.pinnedUIItemsPerChar[key]
    end
    db.pinnedUIItems = db.pinnedUIItems or {}
    return db.pinnedUIItems
end

function UIPins.GetAll()
    local db = EasyFind and EasyFind.db
    local all = {}
    if not db then return all end
    for _, pin in ipairs(db.pinnedUIItems or {}) do
        all[#all + 1] = pin
    end
    local charPins = db.pinnedUIItemsPerChar and db.pinnedUIItemsPerChar[UIPins.GetCharKey()]
    if charPins then
        for _, pin in ipairs(charPins) do
            all[#all + 1] = pin
        end
    end
    return all
end

function UIPins.IsPinned(data)
    local db = EasyFind and EasyFind.db
    if not db then return false end
    local key = UIPins.GetKey(data)
    for _, pin in ipairs(db.pinnedUIItems or {}) do
        if UIPins.GetKey(pin) == key then return true end
    end
    if UIPins.IsCollection(data) then
        local charPins = db.pinnedUIItemsPerChar and db.pinnedUIItemsPerChar[UIPins.GetCharKey()]
        if charPins then
            for _, pin in ipairs(charPins) do
                if UIPins.GetKey(pin) == key then return true end
            end
        end
    end
    return false
end

function UIPins.Pin(data)
    local list = GetPinList(data)
    if not list then return end
    local clean = CleanForStorage(data)
    clean.isPinned = true
    -- If a stale entry exists (e.g. saved before a new field was added
    -- to SIMPLE_FIELDS), replace it in place so the next render picks
    -- up the fresh fields.
    local key = UIPins.GetKey(data)
    for i, existing in ipairs(list) do
        if UIPins.GetKey(existing) == key then
            list[i] = clean
            return
        end
    end
    tinsert(list, clean)
end

function UIPins.Unpin(data)
    local db = EasyFind and EasyFind.db
    if not db then return end
    local key = UIPins.GetKey(data)
    local items = db.pinnedUIItems or {}
    for i = #items, 1, -1 do
        if UIPins.GetKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
    if UIPins.IsCollection(data) then
        local charPins = db.pinnedUIItemsPerChar and db.pinnedUIItemsPerChar[UIPins.GetCharKey()]
        if charPins then
            for i = #charPins, 1, -1 do
                if UIPins.GetKey(charPins[i]) == key then
                    tremove(charPins, i)
                    return
                end
            end
        end
    end
end

function UIPins.SyncOutfits()
    local db = EasyFind and EasyFind.db
    if not db or not C_TransmogOutfitInfo or not C_TransmogOutfitInfo.GetOutfitsInfo then return end
    local outfits = C_TransmogOutfitInfo.GetOutfitsInfo()
    if not outfits then return end

    local lookup = {}
    for _, info in ipairs(outfits) do
        lookup[info.outfitID] = info
    end

    local function syncList(pins)
        if not pins then return end
        for i = #pins, 1, -1 do
            local pin = pins[i]
            if pin.outfitID then
                local info = lookup[pin.outfitID]
                if info then
                    pin.name = info.name
                    pin.nameLower = info.name:lower()
                    pin.icon = info.icon
                else
                    tremove(pins, i)
                end
            end
        end
    end

    syncList(db.pinnedUIItems)
    local charPins = db.pinnedUIItemsPerChar and db.pinnedUIItemsPerChar[UIPins.GetCharKey()]
    syncList(charPins)
end
