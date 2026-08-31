local _, ns = ...

local UIPins = {}
ns.UIPins = UIPins

local Utils = ns.Utils
local ipairs, pairs, type = Utils.ipairs, Utils.pairs, Utils.type
local tconcat, tinsert, tremove = Utils.tconcat, Utils.tinsert, Utils.tremove

local charKey

local SIMPLE_FIELDS = {
    "name", "nameLower", "category", "buttonFrame", "icon",
    "specificIcon", "specificIconFrame",
    "mountID", "spellID", "isSpellbookOnly", "toyItemID", "petID", "speciesID", "outfitID", "heirloomItemID",
    -- Cold mount summonability: without these the snapshot reads as
    -- non-summonable and opens the journal instead of summoning. isToyboxOnly
    -- keeps a restricted toy off the secure "use" path.
    "isCollected", "isUsable", "shouldHideOnChar", "isToyboxOnly",
    "macroIndex", "macroIsChar", "bagID", "bagSlot", "bagItemLink",
    "itemID", "encounterID", "instanceID", "lootSlotName", "lootSourceName", "lootInstanceName", "lootSourceType",
    -- Catalog items: itemID alone is not enough -- catalogItem is the
    -- renderer's branch discriminator (icon resolution, name fallback) and
    -- lookupRow drives the click/drag pickup; without them a pinned catalog
    -- row showed "?" and acted like nothing.
    "catalogItem", "lookupRow", "quality",
    "transmogSetID",
    -- Collection action IDs each SelectResult branch gates on; absent, a cold
    -- title/gear-set/talent/appearance shortkey fell through to a panel open.
    "titleID", "gearSetID", "talentNodeID",
    "appearanceItemID", "appearanceVisualID", "appearanceSlot",
    "factionID", "hasRepBar", "canQueue", "isPvP", "isPvE",
    -- Required for the row renderer to recognize a map result and
    -- place icons in the correct slots.
    "mapSearchResult", "isZone", "mapID", "zoneName", "pathPrefix",
    "zoneMapType", "zoneParentMapID",
    -- Coords + entrance fields so a PINNED map POI navigates on click and drops
    -- its pin (shortkeys rebuild these from the row key instead).
    "x", "y", "zoneMapID", "coordMapID", "parentMapID",
    "entranceMapID", "entranceX", "entranceY", "entranceIcon",
    "entranceCategory", "isDungeonEntrance",
    "achievementID",
    -- Housing decor: recordID + name drive the catalog-navigation guide. Without
    -- it a housing shortkey's snapshot can't route until the housing provider
    -- loads (i.e. until the dashboard has been opened this session).
    "housingRecordID",
    -- Commands: strings only; nativeRun (a function) cannot persist and is
    -- re-resolved by name on selection.
    "searchCommand", "searchCommandDesc", "slashCommand", "isNativeCommand",
    -- Settings rows: the primary click action (inline checkbox toggle via
    -- ActivateSettingResult) is driven by these; without them a restored row
    -- can only fall through to opening the Settings panel. settingOptions is
    -- deliberately absent -- it re-resolves via GetOptionsForVariable.
    "settingVariable", "settingType", "cbVariable", "sliderVariable",
    "dropdownVariable", "settingMin", "settingMax", "quickKeybindActivate",
    -- Keybind toggle rows: bindingAction performs the action cold; customToggle
    -- marks the EasyFind-owned single-action rows (left-click only).
    "bindingAction", "customToggle",
    -- Spec/loadout swap rows: the index/configID RunTalentSwap replays.
    "specSetIndex", "loadoutConfigID",
    -- Profession rows: spellName arms the secure cast-to-open; the skill line
    -- and IDs drive SelectResult's opener tiering for recipe and cast-less
    -- rows. Absent, a restored profession row falls through every branch.
    -- professionName is the row's subtext (the profession, e.g. "Inscription").
    "spellName", "professionSkillLine", "professionName", "professionOpenID", "professionRecipeID",
}

local TABLE_FIELDS = {
    "path", "steps", "keywords", "keywordsLower", "lootItemLinks",
}

function UIPins.GetKey(data)
    if not data or not data.name then return "" end
    -- Catalog items: name|path collapses rarity variants of the same item
    -- name into ONE pin (they have no path and share the name) -- pinning
    -- one pinned them all. Their identity is the itemID, via the same
    -- GetEntryKey the aliases/learned/blacklist systems share. Other row
    -- kinds keep the historical name|path key: every existing pin and
    -- shortkey is stored under it, and a wholesale rekey would orphan them.
    if data.catalogItem and data.itemID and ns.Aliases and ns.Aliases.GetEntryKey then
        local entryKey = ns.Aliases:GetEntryKey(data)
        if entryKey then return entryKey end
    end
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
-- Shortkeys stores the same snapshot with each bind so a shortkey's action
-- survives without its provider loaded (see Shared/Shortkeys.lua).
UIPins.CleanForStorage = CleanForStorage

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
    for index, info in ipairs(outfits) do
        lookup[info.outfitID] = { info = info, index = index }
    end

    local function syncList(pins)
        if not pins then return end
        for i = #pins, 1, -1 do
            local pin = pins[i]
            if pin.outfitID then
                local outfit = lookup[pin.outfitID]
                if outfit then
                    local info = outfit.info
                    pin.name = info.name
                    pin.nameLower = info.name:lower()
                    pin.icon = info.icon
                    pin.outfitIndex = outfit.index
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
