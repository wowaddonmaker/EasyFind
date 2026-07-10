local _, ns = ...

local Database = {}
ns.Database = Database

local Utils   = ns.Utils
local L       = ns.L
local SearchText = ns.SearchText
local ipairs, pairs = Utils.ipairs, Utils.pairs
local sfind, ssub = Utils.sfind, Utils.ssub
-- All index-side casing uses SearchText.Normalize so entry.nameLower and
-- entry.keywordsLower for non-English text actually lowercase (string.lower
-- skips bytes >= 0x80, leaving "Übermacht" partly uppercase). The search
-- pipeline uses the same Normalize on queries, so both sides agree.
local slower = SearchText.Normalize
local select, type, tostring = select, type, tostring
local wipe = wipe
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_CurrencyInfo = C_CurrencyInfo
local C_Reputation = C_Reputation
local C_MountJournal = C_MountJournal
local C_ToyBox = C_ToyBox
local C_PetJournal = C_PetJournal
local C_EncounterJournal = C_EncounterJournal
local band, lshift = bit.band, bit.lshift

local uiSearchData = {}
Database.uiSearchData = uiSearchData
local knownCurrencyIDs = {}

-- Module-wide shared empty keyword table. FlattenTree entries without
-- per-node keywords previously each got a fresh `{}`. Reference-sharing
-- one immutable empty table is safe because nothing tinserts into
-- entry.keywords on these entries (the search prefix index treats it
-- as a list-of-strings; an empty list yields no matches either way).
local EMPTY_KEYWORDS = {}

local function RemoveEntriesByCategory(category)
    local before = #uiSearchData
    local writeIdx = 0
    for i = 1, before do
        local entry = uiSearchData[i]
        if entry.category ~= category then
            writeIdx = writeIdx + 1
            uiSearchData[writeIdx] = entry
        end
    end
    for i = before, writeIdx + 1, -1 do
        uiSearchData[i] = nil
    end
    -- Populate bookkeeping, consumed by the dynamic-provider completion:
    -- a populate that removed nothing (first load) only APPENDS, and the
    -- search cache can extend its candidate set instead of a full reset.
    -- Every populate calls this before adding, so setting the fields here
    -- covers sync and async providers alike.
    Database._populateRemoved = writeIdx < before
    Database._populateAppendFrom = writeIdx + 1
    -- Removals compact uiSearchData, invalidating the q-gram index's
    -- stored positions; appends are picked up incrementally.
    if writeIdx < before and ns.SearchIndex then
        ns.SearchIndex:MarkDirty()
    end
end

local function RemoveEntriesWithField(field)
    local before = #uiSearchData
    local writeIdx = 0
    for i = 1, before do
        local entry = uiSearchData[i]
        if not entry[field] then
            writeIdx = writeIdx + 1
            uiSearchData[writeIdx] = entry
        end
    end
    for i = before, writeIdx + 1, -1 do
        uiSearchData[i] = nil
    end
    if writeIdx < before and ns.SearchIndex then
        ns.SearchIndex:MarkDirty()
    end
end

function Database:_RemoveEntriesByCategory(category)
    RemoveEntriesByCategory(category)
end

local partialSearchRefreshPending = false
local lastPartialSearchRefreshMs = 0

function Database:SchedulePartialSearchRefresh(minIntervalMs)
    if partialSearchRefreshPending then return end

    local now = debugprofilestop and debugprofilestop() or 0
    minIntervalMs = minIntervalMs or 150
    local delay = 0
    if now > 0 and lastPartialSearchRefreshMs > 0 then
        local elapsed = now - lastPartialSearchRefreshMs
        if elapsed < minIntervalMs then
            delay = (minIntervalMs - elapsed) / 1000
        end
    end

    partialSearchRefreshPending = true
    local function run()
        partialSearchRefreshPending = false
        lastPartialSearchRefreshMs = debugprofilestop and debugprofilestop() or 0
        if Database.ResetSearchCache then Database:ResetSearchCache() end
        if ns.Search and ns.Search.RefreshActiveSearch then
            ns.Search:RefreshActiveSearch()
        end
    end

    if Utils.SafeAfter then
        Utils.SafeAfter(delay, run)
    else
        run()
    end
end

function Database:Initialize()
    self:BuildUIDatabase()
end

-- WoW has shipped three names/shapes for warband-shared currency; check all so
-- detection doesn't regress when Blizzard renames a field.
function Database:IsCurrencyAccountTransferable(currencyID)
    if not currencyID or not C_CurrencyInfo then return false end
    local fns = {
        C_CurrencyInfo.IsAccountTransferableCurrency,
        C_CurrencyInfo.IsAccountWideCurrency,
    }
    for i = 1, #fns do
        local fn = fns[i]
        if fn then
            local ok, val = pcall(fn, currencyID)
            if ok and val then return true end
        end
    end
    if C_CurrencyInfo.GetCurrencyInfo then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
        if ok and type(info) == "table" then
            if info.isAccountTransferable then return true end
            if info.isAccountWide then return true end
            if info.transferPercentage and info.transferPercentage > 0 then return true end
        end
    end
    return false
end

function Database:PopulateDynamicCurrencies()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end
    if C_CurrencyInfo.GetCurrencyListSize() == 0 then
        -- Currency list not streamed yet (CURRENCY_DISPLAY_UPDATE pending):
        -- not-ready, and checked BEFORE the category wipe so a transient
        -- zero read cannot empty previously good entries mid-session.
        return false
    end

    RemoveEntriesByCategory("Currency")
    wipe(knownCurrencyIDs)

    local headersWeExpanded = {}
    for pass = 1, 50 do
        local size = C_CurrencyInfo.GetCurrencyListSize()
        local didExpand = false
        for i = 1, size do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and not info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, true)
                headersWeExpanded[info.name] = true
                didExpand = true
                break -- indices shift after expand, restart
            end
        end
        if not didExpand then break end
    end

    local size = C_CurrencyInfo.GetCurrencyListSize()
    local injected = 0

    local baseSteps = {
        { buttonFrame = "CharacterMicroButton" },
        { waitForFrame = "CharacterFrame", tabIndex = 3 },
    }

    local headerStack = {}

    local function pushHeader(name, depth)
        while #headerStack > 0 and headerStack[#headerStack].depth >= depth do
            headerStack[#headerStack] = nil
        end
        headerStack[#headerStack + 1] = { name = name, depth = depth }
    end

    local function buildHeaderSteps()
        local steps = {}
        for _, s in ipairs(baseSteps) do steps[#steps + 1] = s end
        for _, h in ipairs(headerStack) do
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", currencyHeader = h.name }
        end
        return steps
    end

    local function buildPath()
        local path = {_G["CHARACTER_BUTTON"] or "Character Info", _G["CURRENCY"] or "Currency"}
        for _, h in ipairs(headerStack) do
            path[#path + 1] = h.name .. L["UITREE_SUFFIX_CURRENCIES"]
        end
        return path
    end

    local currencyIconMap = {}

    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info then
            local depth = info.currencyListDepth or 0

            if info.currencyID and info.iconFileID then
                currencyIconMap[info.currencyID] = info.iconFileID
            end

            if info.isHeader then
                pushHeader(info.name, depth)

                local headerKey = "header_" .. slower(info.name)
                if not knownCurrencyIDs[headerKey] then
                    knownCurrencyIDs[headerKey] = true

                    local headerNameLower = slower(info.name)
                    local entry = {
                        name = info.name .. L["UITREE_SUFFIX_CURRENCIES"],
                        keywords = {headerNameLower, headerNameLower .. " currencies", headerNameLower .. " currency"},
                        category = "Currency",
                        buttonFrame = "CharacterMicroButton",
                        path = buildPath(),
                        steps = buildHeaderSteps(),
                    }
                    entry.path[#entry.path] = nil
                    entry.nameLower = slower(entry.name)
                    entry.keywordsLower = {}
                    for j, kw in ipairs(entry.keywords) do
                        entry.keywordsLower[j] = slower(kw)
                    end
                    uiSearchData[#uiSearchData + 1] = entry
                    injected = injected + 1
                end
            elseif info.currencyID and not knownCurrencyIDs[info.currencyID] then
                local currName = info.name
                local immediateHeader = headerStack[#headerStack]
                local immediateHeaderName = immediateHeader and immediateHeader.name or "Unknown"

                local currSteps = buildHeaderSteps()
                currSteps[#currSteps + 1] = { waitForFrame = "CharacterFrame", currencyID = info.currencyID }

                local words = {}
                local currNameLower = slower(currName)
                for word in currNameLower:gmatch("%S+") do
                    if #word > 2 then
                        words[#words + 1] = word
                    end
                end
                words[#words + 1] = slower(immediateHeaderName) .. " " .. currNameLower

                local isAccountTransferable = Database:IsCurrencyAccountTransferable(info.currencyID)
                local entry = {
                    name = currName,
                    keywords = words,
                    category = "Currency",
                    buttonFrame = "CharacterMicroButton",
                    path = buildPath(),
                    steps = currSteps,
                    icon = info.iconFileID or nil,
                    currencyID = info.currencyID,
                    isAccountTransferable = isAccountTransferable,
                }
                entry.nameLower = slower(entry.name)
                entry.keywordsLower = {}
                for j, kw in ipairs(entry.keywords) do
                    entry.keywordsLower[j] = slower(kw)
                end
                uiSearchData[#uiSearchData + 1] = entry
                knownCurrencyIDs[info.currencyID] = true
                injected = injected + 1
            end
        end
    end

    if injected > 0 then
        Utils.DebugPrint("Injected", injected, "dynamic currency entries from C_CurrencyInfo")
    end

    -- Use rawget so lazy-hydrated entries (Boss, Statistic) aren't
    -- force-materialized just for an icon scan they can't satisfy:
    -- their steps never reference currencyIDs.
    for _, item in ipairs(uiSearchData) do
        local steps = rawget(item, "steps")
        if not item.icon and steps then
            for _, step in ipairs(steps) do
                if step.currencyID and currencyIconMap[step.currencyID] then
                    item.icon = currencyIconMap[step.currencyID]
                    break
                end
            end
        end
    end

    -- Collapse from deepest first (indices shift after each collapse).
    for pass = 1, 50 do
        local sz = C_CurrencyInfo.GetCurrencyListSize()
        local didCollapse = false
        for i = sz, 1, -1 do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and info.isHeaderExpanded and headersWeExpanded[info.name] then
                C_CurrencyInfo.ExpandCurrencyList(i, false)
                headersWeExpanded[info.name] = nil
                didCollapse = true
                break -- indices shift, restart from end
            end
        end
        if not didCollapse then break end
    end

    -- Surface warband-transferable currencies the player has on OTHER characters.
    -- Without this, the "All Warband Transferable" filter only shows currencies
    -- the current character has touched.
    do
        local extraIDs
        if C_CurrencyInfo.GetAccountCurrencyTypes then
            local ok, list = pcall(C_CurrencyInfo.GetAccountCurrencyTypes)
            if ok and type(list) == "table" then extraIDs = list end
        end
        if extraIDs then
            for _, cid in ipairs(extraIDs) do
                if not knownCurrencyIDs[cid]
                   and self:IsCurrencyAccountTransferable(cid) then
                    local fok, finfo = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
                    local cname = (fok and type(finfo) == "table" and finfo.name) or nil
                    if cname and cname ~= "" then
                        local cnameLower = slower(cname)
                        local kw = { cnameLower, "currency", "warband" }
                        local entry = {
                            name = cname,
                            keywords = kw,
                            category = "Currency",
                            buttonFrame = "CharacterMicroButton",
                            path = { _G["CHARACTER_BUTTON"] or "Character Info", _G["CURRENCY"] or "Currency" },
                            steps = {
                                { buttonFrame = "CharacterMicroButton" },
                                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                                { waitForFrame = "CharacterFrame", currencyID = cid },
                            },
                            icon = (fok and finfo.iconFileID) or nil,
                            currencyID = cid,
                            isAccountTransferable = true,
                        }
                        entry.nameLower = cnameLower
                        entry.keywordsLower = { cnameLower, "currency", "warband" }
                        uiSearchData[#uiSearchData + 1] = entry
                        knownCurrencyIDs[cid] = true
                    end
                end
            end
        end
    end

    return true
end

function Database:PopulateDynamicReputations()
    if not C_Reputation or not C_Reputation.GetNumFactions then return false end
    local liveFactions = C_Reputation.GetNumFactions()
    if not liveFactions or liveFactions == 0 then
        -- Faction list not streamed yet (UPDATE_FACTION pending): not-ready,
        -- and checked BEFORE the category wipe so a transient zero read
        -- cannot empty previously good entries mid-session.
        return false
    end

    RemoveEntriesByCategory("Reputation")

    local headersWeExpanded = {}
    for pass = 1, 50 do
        local numFactions = C_Reputation.GetNumFactions()
        local didExpand = false
        for i = 1, numFactions do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.isHeader then
                local isCollapsed = false
                if factionData.isHeaderExpanded ~= nil then
                    isCollapsed = not factionData.isHeaderExpanded
                elseif factionData.isCollapsed ~= nil then
                    isCollapsed = factionData.isCollapsed
                end

                if isCollapsed then
                    C_Reputation.ExpandFactionHeader(i)
                    headersWeExpanded[factionData.name] = true
                    didExpand = true
                    break -- indices shift after expand, restart
                end
            end
        end
        if not didExpand then break end
    end

    local numFactions = C_Reputation.GetNumFactions()
    local injected = 0

    local baseSteps = {
        { buttonFrame = "CharacterMicroButton" },
        { waitForFrame = "CharacterFrame", tabIndex = 2 },
    }

    local currentExpansion
    local currentFactionGroup

    -- Per-(expansion, group) MT cache. All factions sharing the same
    -- expansion+group inherit category/buttonFrame/path/header-step-prefix
    -- via __index. Only `name`/`nameLower`/`keywords`/`keywordsLower`/
    -- `factionID`/`factionSide`/`hasRepBar` plus the trailing factionID
    -- step are per-entry; the leading nav steps live on the proto's
    -- `steps` field.
    local repMTByKey = {}
    local function getRepMT()
        local key = (currentExpansion or "") .. "\31" .. (currentFactionGroup or "")
        local cached = repMTByKey[key]
        if cached then return cached end

        local steps = {}
        for _, s in ipairs(baseSteps) do steps[#steps + 1] = s end
        if currentExpansion then
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", factionHeader = currentExpansion }
        end
        if currentFactionGroup then
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", factionHeader = currentFactionGroup }
        end

        local path = { _G["CHARACTER_BUTTON"] or "Character Info", _G["REPUTATION"] or "Reputation" }
        if currentExpansion then path[#path + 1] = currentExpansion end
        if currentFactionGroup then path[#path + 1] = currentFactionGroup end

        local prefixLen = #steps
        local proto = {
            category    = "Reputation",
            buttonFrame = "CharacterMicroButton",
            path        = path,
        }
        local mt = {
            __index = function(t, k)
                if k == "steps" then
                    local v = {}
                    for i = 1, prefixLen do v[i] = steps[i] end
                    v[prefixLen + 1] = {
                        waitForFrame = "CharacterFrame",
                        factionID = t.factionID,
                    }
                    rawset(t, "steps", v)
                    return v
                end
                return proto[k]
            end,
            __index_proto = proto,
        }
        repMTByKey[key] = mt
        return mt
    end

    local ALLIANCE_HEADER = (FACTION_ALLIANCE or "Alliance"):lower()
    local HORDE_HEADER    = (FACTION_HORDE    or "Horde"):lower()

    local function injectFaction(factionData)
        local isDiscovered = (factionData.currentStanding and factionData.currentStanding > 0) or
                             (factionData.isWatched == true)
        if not isDiscovered then return end

        local keywords = {}
        local factionNameLower = slower(factionData.name)
        for word in factionNameLower:gmatch("%S+") do
            if #word > 2 then
                keywords[#keywords + 1] = word
            end
        end
        keywords[#keywords + 1] = factionNameLower

        local factionSide
        if currentFactionGroup then
            local groupLower = slower(currentFactionGroup)
            if groupLower == ALLIANCE_HEADER then
                factionSide = "alliance"
            elseif groupLower == HORDE_HEADER then
                factionSide = "horde"
            end
        end

        uiSearchData[#uiSearchData + 1] = setmetatable({
            name           = factionData.name,
            nameLower      = factionNameLower,
            keywords       = keywords,
            factionID      = factionData.factionID,
            factionSide    = factionSide,
            hasRepBar      = not factionData.isHeader or factionData.isHeaderWithRep,
        }, getRepMT())
        injected = injected + 1
    end

    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.name then
            if factionData.isHeader then
                if not factionData.isChild then
                    currentExpansion = factionData.name
                    currentFactionGroup = nil
                else
                    currentFactionGroup = nil
                    if factionData.factionID and factionData.factionID > 0 then
                        injectFaction(factionData)
                    end
                    currentFactionGroup = factionData.name
                end
            elseif factionData.factionID then
                injectFaction(factionData)
            end
        end
    end

    if injected > 0 then
        Utils.DebugPrint("Injected", injected, "dynamic reputation entries from C_Reputation")
    end

    for pass = 1, 50 do
        local numFactionsPost = C_Reputation.GetNumFactions()
        local didCollapse = false
        for i = numFactionsPost, 1, -1 do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.isHeader and headersWeExpanded[factionData.name] then
                local isExpanded = false
                if factionData.isHeaderExpanded ~= nil then
                    isExpanded = factionData.isHeaderExpanded
                elseif factionData.isCollapsed ~= nil then
                    isExpanded = not factionData.isCollapsed
                end

                if isExpanded then
                    C_Reputation.CollapseFactionHeader(i)
                    headersWeExpanded[factionData.name] = nil
                    didCollapse = true
                    break -- indices shift, restart from end
                end
            end
        end
        if not didCollapse then break end
    end
    return true
end

local MOUNT_PROTO = {
    keywords     = {"mount", "ride"},
    keywordsLower = {"mount", "ride"},
    category     = "Mount",
    path         = {},
    steps        = {},
}
local MOUNT_MT = { __index = MOUNT_PROTO }

local HOUSING_PROTO = {
    keywords      = {"housing", "decor", "decoration", "furniture"},
    keywordsLower = {"housing", "decor", "decoration", "furniture"},
    category      = "Housing",
    path          = {},
    steps         = {},
}
local HOUSING_MT = { __index = HOUSING_PROTO }

local MOUNT_TYPE_GROUND_ONLY = 230
local MOUNT_TYPE_AMPHIBIOUS = 231
local MOUNT_TYPE_AQUATIC = 254
local MOUNT_TYPE_RIDE_ALONG = 412

local function MountTypePassesFilters(mountTypeID, db)
    if not mountTypeID then return true end
    local ground = not db or db.mountTypeGround ~= false
    local flying = not db or db.mountTypeFlying ~= false
    local aquatic = not db or db.mountTypeAquatic ~= false
    local rideAlong = not db or db.mountTypeRideAlong ~= false

    if mountTypeID == MOUNT_TYPE_GROUND_ONLY then return ground end
    if mountTypeID == MOUNT_TYPE_AMPHIBIOUS then return ground or aquatic end
    if mountTypeID == MOUNT_TYPE_AQUATIC then return aquatic end
    if mountTypeID == MOUNT_TYPE_RIDE_ALONG then return rideAlong end
    return flying
end

function Database:MountPassesSearchFilters(data)
    if not data or not data.mountID then return false end
    local db = EasyFind and EasyFind.db
    if not db then return true end

    if data.isCollected then
        if db.mountFilterCollected == false then return false end
    elseif db.mountFilterNotCollected == false then
        return false
    end

    local unusableOnThisChar = data.shouldHideOnChar or (data.isCollected and data.isUsable == false)
    if unusableOnThisChar and not db.mountFilterUnusable then return false end
    if not MountTypePassesFilters(data.mountTypeID, db) then return false end

    local sourceFilters = db.mountSourceFilters
    local sourceType = data.mountSourceType
    if sourceType and type(sourceFilters) == "table" and sourceFilters[sourceType] == false then
        return false
    end

    return true
end

local TOY_PROTO = {
    keywords     = {"toy", "fun"},
    keywordsLower = {"toy", "fun"},
    category     = "Toy",
    path         = {},
    steps        = {},
}
local TOY_MT = { __index = TOY_PROTO }

local PET_PROTO = {
    keywords     = {"pet", "companion", "battle pet"},
    keywordsLower = {"pet", "companion", "battle pet"},
    category     = "Pet",
    path         = {},
    steps        = {},
}
local PET_MT = { __index = PET_PROTO }

local OUTFIT_PROTO = {
    keywords     = {"outfit", "appearance"},
    keywordsLower = {"outfit", "appearance"},
    category     = "Outfit",
    path         = {},
    steps        = {},
}
local OUTFIT_MT = { __index = OUTFIT_PROTO }

local HEIRLOOM_PROTO = {
    keywords     = {"heirloom"},
    keywordsLower = {"heirloom"},
    category     = "Heirloom",
    path         = {},
    steps        = {},
}
local HEIRLOOM_MT = { __index = HEIRLOOM_PROTO }

local LOOT_PROTO = {
    category    = "Loot",
    path        = {},
    steps       = {},
    lootEntry   = true, -- use loot-specific scoring (toggle-aware keyword matching)
}

-- Per-encounter MT cache. Every loot drop from the same encounter
-- shares `encounterID`, `instanceID`, `lootSourceName`, `lootInstanceName`,
-- `lootSourceType` plus all the LOOT_PROTO statics. With ~50 unique
-- encounters across ~138 loot entries, hoisting these 5 fields onto a
-- shared proto removes them from per-entry storage.
local lootEncounterMTCache = {}
local function GetLootEncounterMT(encID, instID, encName, instName, isRaid)
    local cached = lootEncounterMTCache[encID]
    if cached then return cached end
    local proto = {
        category         = "Loot",
        path             = LOOT_PROTO.path,
        steps            = LOOT_PROTO.steps,
        lootEntry        = true,
        encounterID      = encID,
        instanceID       = instID,
        lootSourceName   = encName,
        lootInstanceName = instName,
        lootSourceType   = isRaid and "Raid" or "Dungeon",
    }
    local mt = { __index = proto }
    lootEncounterMTCache[encID] = mt
    return mt
end

local TRANSMOG_SET_PROTO = {
    category = "Appearance Set",
    path     = {},
    steps    = {},
}
local TRANSMOG_SET_MT = { __index = TRANSMOG_SET_PROTO }

local APPEARANCE_ITEM_PROTO = {
    category = "Appearance",
    path     = {},
    steps    = {},
}
local APPEARANCE_ITEM_MT = { __index = APPEARANCE_ITEM_PROTO }

local TITLE_PROTO = {
    keywords     = {"title"},
    keywordsLower = {"title"},
    category     = "Title",
    path         = {},
    steps        = {},
}
local TITLE_MT = { __index = TITLE_PROTO }

local GEAR_SET_PROTO = {
    keywords     = {"gear", "set", "equipment", "equip", "loadout"},
    keywordsLower = {"gear", "set", "equipment", "equip", "loadout"},
    category     = "Gear Set",
    path         = {},
    steps        = {},
}
local GEAR_SET_MT = { __index = GEAR_SET_PROTO }


local SLOT_KEYWORDS = {
    INVTYPE_HEAD            = {"helm", "helmet", "head"},
    INVTYPE_NECK            = {"neck", "necklace", "amulet"},
    INVTYPE_SHOULDER        = {"shoulder", "shoulders", "pauldrons"},
    INVTYPE_CHEST           = {"chest", "chestpiece"},
    INVTYPE_ROBE            = {"chest", "robe", "chestpiece"},
    INVTYPE_WAIST           = {"waist", "belt"},
    INVTYPE_LEGS            = {"legs", "leggings", "pants"},
    INVTYPE_FEET            = {"feet", "boots"},
    INVTYPE_WRIST           = {"wrist", "bracers"},
    INVTYPE_HAND            = {"hands", "gloves", "gauntlets"},
    INVTYPE_FINGER          = {"ring", "finger"},
    INVTYPE_TRINKET         = {"trinket"},
    INVTYPE_CLOAK           = {"cloak", "back", "cape"},
    INVTYPE_WEAPON          = {"weapon", "one hand"},
    INVTYPE_WEAPONMAINHAND  = {"weapon", "main hand"},
    INVTYPE_WEAPONOFFHAND   = {"weapon", "off hand", "offhand"},
    INVTYPE_2HWEAPON        = {"weapon", "two hand", "2h"},
    INVTYPE_SHIELD          = {"shield", "off hand"},
    INVTYPE_RANGED          = {"ranged", "weapon"},
    INVTYPE_RANGEDRIGHT     = {"ranged", "weapon", "wand"},
    INVTYPE_HOLDABLE        = {"off hand", "held"},
}

local STAT_KEYWORD_MAP = {
    ITEM_MOD_CRIT_RATING_SHORT    = {"crit", "critical strike"},
    ITEM_MOD_HASTE_RATING_SHORT   = {"haste"},
    ITEM_MOD_MASTERY_RATING_SHORT = {"mastery"},
    ITEM_MOD_VERSATILITY          = {"vers", "versatility"},
    ITEM_MOD_INTELLECT_SHORT      = {"int", "intellect"},
    ITEM_MOD_AGILITY_SHORT        = {"agi", "agility"},
    ITEM_MOD_STRENGTH_SHORT       = {"str", "strength"},
}

-- Bump when STAT_KEYWORD_MAP or the enrichment logic changes so the persisted
-- lootStatCache rebuilds (v2 clears entries cemented empty by incomplete reads).
ns.LOOT_STAT_CACHE_VER = 2

-- Shared tokenizer for the lazy search-word vocabularies below: splits a
-- phrase into words, dedupes into the lookup, optionally collecting a list.
local function AddLookupWords(lookup, phrase, list)
    for part in phrase:gmatch("%S+") do
        if not lookup[part] then
            lookup[part] = true
            if list then list[#list + 1] = part end
        end
    end
end

local slotSearchWordLookup, slotSearchWordList
local function IsLootSlotSearchWord(word)
    if not slotSearchWordLookup then
        slotSearchWordLookup = {}
        slotSearchWordList = {}
        for _, words in pairs(SLOT_KEYWORDS) do
            for i = 1, #words do
                AddLookupWords(slotSearchWordLookup, words[i], slotSearchWordList)
            end
        end
    end
    if slotSearchWordLookup[word] then return true end
    -- The loot scorer accepts a query word that is a PREFIX of a slot keyword
    -- ("boot" scores against "boots"), so gear-context detection must too, or
    -- "haste boot" is vetoed while "haste boots" matches. 1-char words stay
    -- out to avoid mid-type context flicker.
    if #word < 2 then return false end
    for i = 1, #slotSearchWordList do
        if sfind(slotSearchWordList[i], word, 1, true) == 1 then return true end
    end
    return false
end

function Database:IsLootSlotSearchWord(word)
    return IsLootSlotSearchWord(word)
end

local lockGen = 0
local function BumpLockGen()
    lockGen = lockGen + 1
end

local GetAvailableLFGCategories = C_LFGList and C_LFGList.GetAvailableCategories
local lfgAvailableCategories

function Database:InvalidateLFGAvailability()
    lfgAvailableCategories = nil
    BumpLockGen()
end

-- Level-gated LFG categories (rated arenas on a low-level character) are
-- absent from C_LFGList.GetAvailableCategories(), so guides into them
-- dead-end. Fail open while the list is empty (early login) so nothing is
-- wrongly locked before the API is ready.
local function IsLFGCategoryLocked(categoryID)
    if not GetAvailableLFGCategories then return false end
    if not lfgAvailableCategories then
        local categories = GetAvailableLFGCategories()
        if not categories or #categories == 0 then return false end
        lfgAvailableCategories = {}
        for i = 1, #categories do lfgAvailableCategories[categories[i]] = true end
    end
    return not lfgAvailableCategories[categoryID]
end

function Database:IsLFGCategoryLocked(categoryID)
    return IsLFGCategoryLocked(categoryID)
end

-- Lockedness is fully generic: the guide's own step probe reports targets it
-- can observe right now (existing-but-disabled buttons, categories absent
-- from a populated list), and a per-character learned set remembers step
-- signatures whose execution dead-ended, so entries behind a UI the client
-- has not loaded this session still gray after one failed attempt. Learned
-- locks clear on level-up, the main unlock vector. No per-feature rules.
local STEP_TARGET_KEYS = {
    "lfgCategoryID", "pvpSideTabIndex", "sideTabIndex", "tabIndex",
    "searchButtonText", "sidebarButtonFrame", "currencyID", "factionID",
    "achievementID", "statisticID",
}

-- Steps are static, shared table objects (FlattenTree reuses parent step
-- arrays across entries), so signatures and lock verdicts memoize on the step
-- itself. lockGen bumps whenever lock state can actually change; between
-- bumps a probe costs one field compare per step instead of a finder walk
-- per visible row per keystroke (the bench log caught that as a 40% warm
-- regression).
local function StepSignature(step)
    local sig = step._efSig
    if sig == nil then
        sig = false
        for i = 1, #STEP_TARGET_KEYS do
            local key = STEP_TARGET_KEYS[i]
            local value = step[key]
            if value ~= nil then
                sig = key .. ":" .. tostring(value)
                break
            end
        end
        step._efSig = sig
    end
    if sig then return sig end
    return nil
end

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local function LearnedLocks()
    local db = EasyFind and EasyFind.db
    if not db then return nil end
    db.learnedStepLocks = db.learnedStepLocks or {}
    local key = CharKey()
    db.learnedStepLocks[key] = db.learnedStepLocks[key] or {}
    return db.learnedStepLocks[key]
end

function Database:LearnStepLock(step)
    local sig = StepSignature(step)
    if not sig then return end
    local locks = LearnedLocks()
    if locks then locks[sig] = true end
    BumpLockGen()
end

function Database:OnPlayerLevelUp()
    lfgAvailableCategories = nil
    local db = EasyFind and EasyFind.db
    if db and db.learnedStepLocks then
        db.learnedStepLocks[CharKey()] = nil
    end
    BumpLockGen()
end

function Database:IsStepLocked(step)
    if step._efLockGen == lockGen then
        return step._efLockState
    end
    step._efLockGen = lockGen
    local locked = false
    local highlight = ns.Highlight
    if highlight and highlight.GetStepLockState
       and highlight:GetStepLockState(step) == "locked" then
        locked = true
    else
        local sig = StepSignature(step)
        if sig then
            local locks = LearnedLocks()
            locked = (locks and locks[sig]) == true
        end
    end
    step._efLockState = locked
    return locked
end

---Reason a result cannot be navigated on this character, or nil when it can.
---Resolved at render time for visible rows only, so cost is O(visible rows).
function Database:GetEntryLockedReason(entry)
    local steps = entry.steps
    if not steps then return nil end
    for i = 1, #steps do
        if self:IsStepLocked(steps[i]) then
            return L["TOOLTIP_RESULT_LOCKED"]
        end
    end
    return nil
end
-- v2: slot keywords rebuilt with the journal filterType fallback; older caches
-- carry entries with missing/stale lootSlotKw and must re-scan.
-- v3: amnesty for caches poisoned by cold-journal scans. The journal fills
-- from the server asynchronously; scans used to mark specs as fully scanned
-- even when encounters returned no data yet, permanently sticking an empty
-- or partial cache. Discarding forces one clean re-scan under the fixed
-- scan (which now waits for EJ_LOOT_DATA_RECIEVED and refuses to mark
-- specs complete on unresolved reads).
ns.LOOT_ITEM_CACHE_VER = 3
ns.BOSS_CACHE_VER = 1
ns.STATISTIC_CACHE_VER = 1

local heavySearchWordLookup
local function AddHeavySearchWord(word)
    if not word or word == "" then return end
    word = slower(word)
    heavySearchWordLookup[word] = true
    if #word > 2 and ssub(word, #word, #word) ~= "s" then
        heavySearchWordLookup[word .. "s"] = true
    end
end

local function AddHeavySearchWords(words)
    for i = 1, #words do
        for word in words[i]:gmatch("%S+") do
            AddHeavySearchWord(word)
        end
    end
end

local function GetHeavySearchWordLookup()
    if heavySearchWordLookup then return heavySearchWordLookup end
    heavySearchWordLookup = {}
    AddHeavySearchWords({
        "loot", "item", "gear", "armor", "boss", "bosses",
        "dungeon", "raid", "weapon",
    })
    for equipLoc, words in pairs(SLOT_KEYWORDS) do
        AddHeavySearchWord(_G[equipLoc])
        AddHeavySearchWords(words)
    end
    for statKey, words in pairs(STAT_KEYWORD_MAP) do
        AddHeavySearchWord(_G[statKey])
        AddHeavySearchWords(words)
    end
    return heavySearchWordLookup
end

local statSearchWordLookup
local function IsLootStatSearchWord(word)
    if not statSearchWordLookup then
        statSearchWordLookup = {}
        for statKey, words in pairs(STAT_KEYWORD_MAP) do
            local label = _G[statKey]
            if label then
                AddLookupWords(statSearchWordLookup, slower(label))
            end
            for i = 1, #words do
                AddLookupWords(statSearchWordLookup, words[i])
            end
        end
    end
    return statSearchWordLookup[word] or false
end

function Database:IsLootStatSearchWord(word)
    return IsLootStatSearchWord(word)
end

function Database:QueryNeedsHeavySearchData(text)
    if not text then return false end
    local lookup = GetHeavySearchWordLookup()
    local query = slower(text)
    if self.NormalizeSearchQuery then
        query = self:NormalizeSearchQuery(query)
    end
    for word in query:gmatch("%S+") do
        word = word:gsub("^%p+", ""):gsub("%p+$", "")
        if lookup[word] then return true end
    end
    return false
end

local SLOT_DISPLAY = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder",
    INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WAIST = "Waist",
    INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_WRIST = "Wrist",
    INVTYPE_HAND = "Hands", INVTYPE_FINGER = "Ring", INVTYPE_TRINKET = "Trinket",
    INVTYPE_CLOAK = "Cloak", INVTYPE_WEAPON = "Weapon", INVTYPE_WEAPONMAINHAND = "Main Hand",
    INVTYPE_WEAPONOFFHAND = "Off Hand", INVTYPE_2HWEAPON = "Two-Hand",
    INVTYPE_SHIELD = "Shield", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
    INVTYPE_HOLDABLE = "Off Hand",
}

-- The journal's own slot classification (EncounterJournalItemInfo.filterType)
-- mapped to the INVTYPE keys SLOT_KEYWORDS/SLOT_DISPLAY use. Fallback for loot
-- whose GetItemInfoInstant equipLoc is empty (tier tokens and other non-equip
-- items the journal still files under a slot) so they stay findable by slot word.
local FILTER_TO_INVTYPE = {}
do
    local slotFilter = Enum and Enum.ItemSlotFilterType
    if slotFilter then
        local byName = {
            Head = "INVTYPE_HEAD", Neck = "INVTYPE_NECK", Shoulder = "INVTYPE_SHOULDER",
            Cloak = "INVTYPE_CLOAK", Chest = "INVTYPE_CHEST", Wrist = "INVTYPE_WRIST",
            Hand = "INVTYPE_HAND", Waist = "INVTYPE_WAIST", Legs = "INVTYPE_LEGS",
            Feet = "INVTYPE_FEET", MainHand = "INVTYPE_WEAPONMAINHAND",
            OffHand = "INVTYPE_WEAPONOFFHAND", Finger = "INVTYPE_FINGER",
            Trinket = "INVTYPE_TRINKET",
        }
        for enumName, invType in pairs(byName) do
            local enumValue = slotFilter[enumName]
            if enumValue then FILTER_TO_INVTYPE[enumValue] = invType end
        end
    end
end

-- C_EncounterJournal functions may not exist until EncounterJournal_LoadUI(),
-- so resolve at call time. Prefer the C_ namespace over stale EJ_* globals.
local function EJ(name)
    return (C_EncounterJournal and C_EncounterJournal[name]) or _G["EJ_" .. name]
end

local lootEntries = {}
local lootScanGeneration = 0
local bossScanGeneration = 0
local lootItemCache = {}
Database._lootItemCache = lootItemCache
local lootSpecsScanned = {}
-- Journal loot data arrives from the server per encounter; the permanent
-- listener flags the active scan so its state machine re-reads a cell it
-- was holding on instead of misreading "not loaded yet" as "no loot".
local lootEventFrame
local activeLootScan
local lootItemCacheHydrated = false
local lootSearchDataHydrated = false
local bossCacheHydrated = false
local statisticCacheHydrated = false

local function CopyArray(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for i = 1, #src do out[i] = src[i] end
    return out
end

local function HydratePersistedLootCache()
    if lootItemCacheHydrated then return end
    lootItemCacheHydrated = true
    local db = EasyFind and EasyFind.db
    local saved = db and db.lootItemCache
    if type(saved) ~= "table" or db.lootItemCacheVer ~= ns.LOOT_ITEM_CACHE_VER then return end

    local items = saved.items or saved
    for rawID, raw in pairs(items) do
        if type(raw) == "table" then
            local itemID = raw.itemID or tonumber(rawID)
            local name = raw.name
            if itemID and name and name ~= "" and raw.encounterID and raw.instanceID then
                local entry = {
                    name = name,
                    nameLower = raw.nameLower or slower(name),
                    icon = raw.icon,
                    itemID = itemID,
                    keywords = EMPTY_KEYWORDS,
                    lootSlotKw = CopyArray(raw.lootSlotKw),
                    lootSourceKw = CopyArray(raw.lootSourceKw),
                    lootStatKw = CopyArray(raw.lootStatKw),
                    lootItemLinks = type(raw.lootItemLinks) == "table" and Utils.DeepCopy(raw.lootItemLinks) or {},
                    lootSlotName = raw.lootSlotName,
                    _cachedSpecs = CopyArray(raw._cachedSpecs),
                    _cachedDiffs = CopyArray(raw._cachedDiffs),
                    _statsEnriched = raw._statsEnriched == true,
                }
                lootItemCache[itemID] = setmetatable(entry, GetLootEncounterMT(
                    raw.encounterID,
                    raw.instanceID,
                    raw.lootSourceName,
                    raw.lootInstanceName,
                    raw.lootSourceType == "Raid"
                ))
            end
        end
    end

    if type(saved.specsScanned) == "table" then
        for key, value in pairs(saved.specsScanned) do
            if value then lootSpecsScanned[key] = true end
        end
    end
end

local function PersistLootCache()
    local db = EasyFind and EasyFind.db
    if not db then return end

    local saved = {
        version = ns.LOOT_ITEM_CACHE_VER,
        specsScanned = {},
        items = {},
    }
    for key in pairs(lootSpecsScanned) do
        saved.specsScanned[key] = true
    end
    for itemID, entry in pairs(lootItemCache) do
        saved.items[itemID] = {
            itemID = itemID,
            name = entry.name,
            icon = entry.icon,
            lootSlotKw = CopyArray(entry.lootSlotKw),
            lootSourceKw = CopyArray(entry.lootSourceKw),
            lootStatKw = CopyArray(entry.lootStatKw),
            lootItemLinks = type(entry.lootItemLinks) == "table" and Utils.DeepCopy(entry.lootItemLinks) or nil,
            lootSlotName = entry.lootSlotName,
            _cachedSpecs = CopyArray(entry._cachedSpecs),
            _cachedDiffs = CopyArray(entry._cachedDiffs),
            _statsEnriched = entry._statsEnriched == true,
            encounterID = entry.encounterID,
            instanceID = entry.instanceID,
            lootSourceName = entry.lootSourceName,
            lootInstanceName = entry.lootInstanceName,
            lootSourceType = entry.lootSourceType,
        }
    end
    db.lootItemCache = saved
    db.lootItemCacheVer = ns.LOOT_ITEM_CACHE_VER
end

local LOOT_DIFF_IDS = {
    lfr     = { raid = 17 },
    normal  = { dungeon = 1,  raid = 14 },
    heroic  = { dungeon = 2,  raid = 15 },
    mythic  = { dungeon = 23, raid = 16 },
}

function Database:GetEJDifficultyID(sourceType)
    local diffKey = EasyFind.db.lootDifficulty or "normal"
    local diffIDs = LOOT_DIFF_IDS[diffKey]
    if not diffIDs then return nil end
    local srcKey = sourceType == "Raid" and "raid" or "dungeon"
    return diffIDs[srcKey]
end

function Database:SetEJDifficulty(diffID)
    if not diffID then return end
    local setDiff = EJ("SetDifficulty")
    if setDiff then setDiff(diffID) end
end

function Database:SyncEJLootFilter()
    local setFilter = EJ("SetLootFilter")
    if not setFilter then return end
    -- Suppress so our own push doesn't re-trigger the loot forward hook.
    EasyFind._lootFilterHookSuppress = true
    local lf = EasyFind.db.lootFilter
    if not lf then
        local _, _, cid = UnitClass("player")
        local si = GetSpecialization and GetSpecialization()
        local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
        if cid and sid then
            setFilter(cid, sid)
        end
    elseif lf == "all" then
        setFilter(0, 0)
    elseif lf.specID then
        setFilter(lf.classID, lf.specID)
    elseif lf.classID then
        setFilter(lf.classID, 0)
    end
    EasyFind._lootFilterHookSuppress = false
end

-- Push our heirloom class/spec choice into the Heirlooms Journal so its list
-- (and ours, which reads searchFiltered) line up. Suppressed flag keeps the
-- journal->db hook from echoing back during our own write.
function Database:SyncHeirloomJournalFilter()
    if not C_Heirloom or not C_Heirloom.SetClassAndSpecFilters then return end
    local f = EasyFind.db and EasyFind.db.heirloomFilter
    local classID, specID
    if not f then
        local _, _, cid = UnitClass("player")
        local si = GetSpecialization and GetSpecialization()
        local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
        classID, specID = cid or 0, sid or 0
    elseif f == "all" then
        classID, specID = 0, 0
    elseif f.specID then
        classID, specID = f.classID, f.specID
    else
        classID, specID = f.classID, 0
    end
    EasyFind._heirloomHookSuppress = true
    pcall(C_Heirloom.SetClassAndSpecFilters, classID, specID)
    EasyFind._heirloomHookSuppress = false
end

-- All spec IDs for a class; shared by the scan planner (BuildLootSpecPairs)
-- and the rebuild filter (RebuildLootSearchData) so their class-wide
-- expansions can never drift apart.
local function ClassSpecIDs(classID)
    local specs = {}
    for specIdx = 1, GetNumSpecializationsForClassID(classID) do
        local specID = GetSpecializationInfoForClassID(classID, specIdx)
        if specID then specs[#specs + 1] = specID end
    end
    return specs
end

local function RebuildLootSearchData()
    -- Filter in place to avoid O(n^2) tremove.
    local writeIdx = 0
    for i = 1, #uiSearchData do
        if uiSearchData[i].category ~= "Loot" then
            writeIdx = writeIdx + 1
            uiSearchData[writeIdx] = uiSearchData[i]
        end
    end
    for i = #uiSearchData, writeIdx + 1, -1 do
        uiSearchData[i] = nil
    end
    wipe(lootEntries)

    -- lootFilter: nil = current spec, "all" = all classes,
    --   {classID=N} = whole class, {classID=N, specID=M} = specific spec
    local lootFilter = EasyFind.db.lootFilter
    local wantSpec = {}
    local wantAll = false
    if not lootFilter then
        local _, _, cid = UnitClass("player")
        local si = GetSpecialization and GetSpecialization()
        local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
        if cid and sid then
            wantSpec[cid .. "-" .. sid] = true
        elseif cid then
            -- Unspecced character: class-wide.
            for _, specID in ipairs(ClassSpecIDs(cid)) do
                wantSpec[cid .. "-" .. specID] = true
            end
        end
    elseif lootFilter == "all" then
        wantAll = true
    elseif lootFilter.specID then
        wantSpec[lootFilter.classID .. "-" .. lootFilter.specID] = true
    elseif lootFilter.classID then
        for _, specID in ipairs(ClassSpecIDs(lootFilter.classID)) do
            wantSpec[lootFilter.classID .. "-" .. specID] = true
        end
    end

    local wantDiff = EasyFind.db.lootDifficulty or "normal"

    for _, entry in pairs(lootItemCache) do
        local specMatch = wantAll
        if not specMatch then
            for _, spKey in ipairs(entry._cachedSpecs) do
                if wantSpec[spKey] then specMatch = true; break end
            end
        end
        if specMatch then
            local diffMatch = false
            for _, dk in ipairs(entry._cachedDiffs) do
                if dk == wantDiff then diffMatch = true; break end
            end
            if diffMatch then
                uiSearchData[#uiSearchData + 1] = entry
                lootEntries[#lootEntries + 1] = entry
            end
        end
    end
    lootSearchDataHydrated = true
end

local DIFF_PRIORITY = { "mythic", "heroic", "normal", "lfr" }

-- Recovers setID for pinned sets saved before transmogSetID was persisted.
function Database:GetTransmogSetIDByName(name)
    if not name or not C_TransmogSets or not C_TransmogSets.GetAllSets then return nil end
    local allSets = C_TransmogSets.GetAllSets()
    if not allSets then return nil end
    for i = 1, #allSets do
        local s = allSets[i]
        if s and s.name == name then return s.setID end
    end
    return nil
end

function Database:GetLootItemLink(entry)
    local links = entry.lootItemLinks
    -- Serialized pins lose lootItemLinks, so fall back to the live cache.
    if not links and entry.itemID then
        local live = lootItemCache[entry.itemID]
        if live then links = live.lootItemLinks end
    end
    if not links then return nil end
    local selected = EasyFind.db.lootDifficulty or "normal"
    if links[selected] then return links[selected] end
    for _, dk in ipairs(DIFF_PRIORITY) do
        if links[dk] then return links[dk] end
    end
    return nil
end

-- Loot entries whose stats weren't in the client cache when we tried
-- to enrich them. GET_ITEM_INFO_RECEIVED retries these once the server
-- replies, then refreshes the active search so newly-enriched matches
-- surface without the user having to retype.
local pendingStatEnrichment = {}
Database._pendingStatEnrichment = pendingStatEnrichment

function Database:EnrichLootStats(entry)
    if entry._statsEnriched then return end
    local itemID = entry.itemID
    -- Item stats are immutable, so a persisted result is always valid and skips
    -- the async item-data fetch entirely (makes gear/stat search instant on
    -- every login after the first, even with a cold client item cache).
    local cache = EasyFind.db and EasyFind.db.lootStatCache
    if itemID and cache and cache[itemID] then
        entry.lootStatKw = cache[itemID]
        entry._statsEnriched = true
        return
    end
    local link = Database:GetLootItemLink(entry)
    local GetItemStatsFn = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not GetItemStatsFn then return end
    local stats = link and GetItemStatsFn(link)
    if not stats and itemID then
        stats = GetItemStatsFn("item:" .. itemID)
    end
    if not stats or not next(stats) then
        -- Item data not fully loaded (nil or empty stats table). Queue for
        -- retry on GET_ITEM_INFO_RECEIVED and nudge the client to fetch, so we
        -- never cache an incomplete read and cement gear out of stat search.
        if itemID then
            pendingStatEnrichment[itemID] = entry
            if C_Item and C_Item.RequestLoadItemDataByID then
                pcall(C_Item.RequestLoadItemDataByID, itemID)
            end
        end
        return
    end
    local statKw = entry.lootStatKw or {}
    for statKey, searchWords in pairs(STAT_KEYWORD_MAP) do
        if stats[statKey] then
            for _, word in ipairs(searchWords) do
                statKw[#statKw + 1] = word
            end
        end
    end
    entry.lootStatKw = statKw
    entry._statsEnriched = true
    if itemID and cache then
        cache[itemID] = statKw   -- persist for instant enrichment next login
    end
end

-- Called from the GET_ITEM_INFO_RECEIVED event handler. Returns true
-- when at least one queued entry successfully enriched, so the caller
-- can decide whether to re-run the active search.
function Database:ResolvePendingStatEnrichment(itemID, success)
    if not success then
        -- Failed fetch: drop the pending entry so we don't retry forever.
        pendingStatEnrichment[itemID] = nil
        return false
    end
    local entry = pendingStatEnrichment[itemID]
    if not entry then return false end
    pendingStatEnrichment[itemID] = nil
    Database:EnrichLootStats(entry)
    return entry._statsEnriched == true
end

function Database:PopulateDynamicMounts()
    if not C_MountJournal or not C_MountJournal.GetMountIDs then return false end

    -- Guards precede the wipe: bailing after RemoveEntriesByCategory leaves
    -- the dataset without the category and no cache invalidation behind it.
    local mountIDs = C_MountJournal.GetMountIDs()
    if not mountIDs then return false end

    RemoveEntriesByCategory("Mount")

    for _, mountID in ipairs(mountIDs) do
        local name, spellID, icon, _, isUsable, sourceType, _,
              _, _, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
        if name then
            local mountTypeID
            if C_MountJournal.GetMountInfoExtraByID then
                mountTypeID = select(5, C_MountJournal.GetMountInfoExtraByID(mountID))
            end
            local entry = {
                name = name,
                icon = icon,
                mountID = mountID,
                spellID = spellID,
                isCollected = isCollected and true or false,
                isUsable = isUsable and true or false,
                shouldHideOnChar = shouldHideOnChar and true or false,
                mountSourceType = sourceType,
                mountTypeID = mountTypeID,
                nameLower = slower(name),
            }
            if self:MountPassesSearchFilters(entry) then
                uiSearchData[#uiSearchData + 1] = setmetatable(entry, MOUNT_MT)
            end
        end
    end
    return true
end

-- Housing decor catalog: one entry per owned catalog entry, enumerated via
-- the async catalog searcher (results arrive through a callback after
-- RunSearch). The searcher and its callback are created once and reused;
-- a repopulate while a search is in flight cancels the older request.
local housingSearcher
local housingSearchDone

function Database:FinishHousingResults(done)
    local searcher = housingSearcher
    if not (C_HousingCatalog and searcher) then
        done(false)
        return
    end
    local okIDs, entryIDs = pcall(searcher.GetCatalogSearchResults, searcher)
    if not okIDs or type(entryIDs) ~= "table" then
        done(false, "cancelled")
        return
    end
    -- Build the replacement set fully before touching uiSearchData. A
    -- repopulate can land mid-search (HOUSING_STORAGE_UPDATED marks the
    -- provider dirty liberally), and wiping before the searcher proves it
    -- has data made live results vanish until the next retry.
    local GetCatalogEntryInfo = C_HousingCatalog.GetCatalogEntryInfo
    local fresh = {}
    for i = 1, #entryIDs do
        local okInfo, info = pcall(GetCatalogEntryInfo, entryIDs[i])
        if okInfo and info and info.name and info.name ~= "" then
            fresh[#fresh + 1] = setmetatable({
                name = info.name,
                nameLower = slower(info.name),
                icon = info.iconTexture,
                housingEntryID = entryIDs[i],
                housingRecordID = info.recordID,
                housingNumStored = info.totalNumStored,
                housingNumPlaced = info.totalNumPlaced,
                housingQuality = info.quality,
                housingSourceText = info.sourceText,
            }, HOUSING_MT)
        end
    end
    -- Zero entries usually means the catalog wasn't streamed in yet (login
    -- warm path). Keep the existing entries and report "cancelled" so the
    -- provider stays dirty and retries on the next query instead of caching
    -- an empty category all session.
    if #fresh == 0 then
        done(false, "cancelled")
        return
    end
    RemoveEntriesByCategory("Housing")
    for i = 1, #fresh do
        uiSearchData[#uiSearchData + 1] = fresh[i]
    end
    done(true)
end

-- Blizzard's live catalog searcher exists only while the housing catalog UI is
-- loaded (Blizzard_HousingDashboard). It carries the player's current catalog
-- filter state; EasyFind mirrors it so housing search matches the catalog window.
local function BlizzardCatalogSearcher()
    local dash = _G["HousingDashboardFrame"]
    local content = dash and dash.CatalogContent
    local s = content and content.catalogSearcher
    if type(s) ~= "userdata" then return nil end
    local ok, hasGetter = pcall(function() return s.GetSortType ~= nil end)
    if ok and hasGetter then return s end
    return nil
end

-- Iterate every (groupID, tagID) across the catalog's filter tag groups,
-- calling fn(groupID, tagID). Shared by the read/apply filter paths.
local function ForEachHousingFilterTag(fn)
    if not (C_HousingCatalog and C_HousingCatalog.GetAllFilterTagGroups) then return end
    local ok, groups = pcall(C_HousingCatalog.GetAllFilterTagGroups)
    if not ok or type(groups) ~= "table" then return end
    for gi = 1, #groups do
        local grp = groups[gi]
        local gid = grp and grp.groupID
        local tags = grp and grp.tags
        if gid and tags then
            for ti = 1, #tags do
                local tid = tags[ti] and tags[ti].tagID
                if tid then fn(gid, tid) end
            end
        end
    end
end

-- Copy the live catalog filter state (Blizzard UI -> EasyFind DB). Returns false
-- and leaves EasyFind's stored filters untouched when the catalog UI isn't loaded.
-- Mirrors the transmog SyncTransmogSetFiltersFromUI read pattern (run on menu
-- open + before each populate; no polling). Category is deliberately not synced:
-- it is the catalog's left-sidebar navigation, not part of the Filter menu.
function Database:SyncHousingFiltersFromBlizzard()
    local db = EasyFind.db
    if db and db.housingFiltersPendingPush then
        -- An unpushed menu change is the newest intent; push it instead of
        -- reading Blizzard's stale state back over it.
        return self:WriteHousingFiltersToBlizzard()
    end
    local s = BlizzardCatalogSearcher()
    if not (s and db) then return false end
    local function readState(method)
        local ok, v = pcall(s[method], s)
        if ok then return v end
    end
    local collected = readState("IsCollectedActive")
    local uncollected = readState("IsUncollectedActive")
    db.housingCollection = (collected and uncollected and "all")
        or (uncollected and "uncollected") or "collected"
    db.housingDyeableOnly = readState("IsCustomizableOnlyActive") and true or false
    db.housingCollectionBonusOnly = readState("IsFirstAcquisitionBonusOnlyActive") and true or false
    db.housingIndoors = readState("IsAllowedIndoorsActive") ~= false
    db.housingOutdoors = readState("IsAllowedOutdoorsActive") ~= false
    db.housingSortType = readState("GetSortType") or 0
    local tags = {}
    db.housingTags = tags
    -- Record every group explicitly: a present-but-empty group table means
    -- "all tags off" (real user state), while a missing group means "no
    -- stored preference" and the write path leaves the searcher's default.
    ForEachHousingFilterTag(function(gid, tid)
        local grpState = tags[gid]
        if not grpState then grpState = {}; tags[gid] = grpState end
        local okS, active = pcall(s.GetFilterTagStatus, s, gid, tid)
        if okS and active then
            grpState[tid] = true
        end
    end)
    return true
end

-- Apply EasyFind's stored housing filter state to a searcher (Blizzard's shared
-- one or our own). Does not RunSearch. Category is left untouched (navigation).
local function ApplyHousingFilters(searcher, db)
    if not (searcher and db) then return end
    local mode = db.housingCollection or "collected"
    if searcher.SetCollected then searcher:SetCollected(mode ~= "uncollected") end
    if searcher.SetUncollected then searcher:SetUncollected(mode ~= "collected") end
    if searcher.SetCustomizableOnly then searcher:SetCustomizableOnly(db.housingDyeableOnly == true) end
    if searcher.SetFirstAcquisitionBonusOnly then
        searcher:SetFirstAcquisitionBonusOnly(db.housingCollectionBonusOnly == true)
    end
    if searcher.SetAllowedIndoors then searcher:SetAllowedIndoors(db.housingIndoors ~= false) end
    if searcher.SetAllowedOutdoors then searcher:SetAllowedOutdoors(db.housingOutdoors ~= false) end
    if searcher.SetSortType then searcher:SetSortType(db.housingSortType or 0) end
    if searcher.SetFilterTagStatus then
        local tags = db.housingTags
        ForEachHousingFilterTag(function(gid, tid)
            -- Missing group = no stored preference; leave the searcher's
            -- default (all tags on) instead of forcing the group off.
            local grpState = tags and tags[gid]
            if grpState then
                pcall(searcher.SetFilterTagStatus, searcher, gid, tid, grpState[tid] == true)
            end
        end)
    end
end

-- While a menu change could not be pushed (no catalog UI loaded), watch for a
-- searcher appearing and push then. Armed only while a push is pending, so it
-- costs nothing in normal play.
local housingPushArmed = false
local function ArmHousingPendingPush()
    if housingPushArmed then return end
    housingPushArmed = true
    local function tick()
        local db = EasyFind and EasyFind.db
        if not (db and db.housingFiltersPendingPush) then
            housingPushArmed = false
            return
        end
        if BlizzardCatalogSearcher() then
            housingPushArmed = false
            Database:WriteHousingFiltersToBlizzard()
            return
        end
        Utils.SafeAfter(1, tick)
    end
    Utils.SafeAfter(1, tick)
end

-- Cross-session arming: a pending push saved last session must survive the
-- user opening the catalog before ever touching EasyFind this session.
function Database:ArmHousingPendingPushIfNeeded()
    local db = EasyFind and EasyFind.db
    if db and db.housingFiltersPendingPush then ArmHousingPendingPush() end
end

-- EasyFind -> Blizzard: push EasyFind's stored filter state onto the live catalog
-- searcher and re-run it, so the catalog window reflects EasyFind's filters.
function Database:WriteHousingFiltersToBlizzard()
    local db = EasyFind.db
    if not db then return false end
    local s = BlizzardCatalogSearcher()
    if not s then
        -- No live catalog UI: a silently dropped push plus the next read-back
        -- erases the user's change (lost update -- menu changes made with the
        -- catalog closed REVERTED). Persist the intent; push when one exists.
        db.housingFiltersPendingPush = true
        ArmHousingPendingPush()
        return false
    end
    pcall(function()
        ApplyHousingFilters(s, db)
        if s.RunSearch then s:RunSearch() end
    end)
    db.housingFiltersPendingPush = false
    return true
end

function Database:PopulateDynamicHousingAsync(done)
    if not (C_HousingCatalog and C_HousingCatalog.CreateCatalogSearcher) then
        done(false)
        return
    end
    if housingSearchDone then
        local cancelled = housingSearchDone
        housingSearchDone = nil
        cancelled(false, "cancelled")
    end
    if not housingSearcher then
        local okCreate, searcher = pcall(C_HousingCatalog.CreateCatalogSearcher)
        if not okCreate or not searcher then
            -- "cancelled", not a plain false: a plain completion marks the
            -- provider loaded-and-empty for the whole session, and searcher
            -- creation can fail early in a fresh session before the housing
            -- subsystem is up. Cancelled keeps it retryable per search.
            done(false, "cancelled")
            return
        end
        housingSearcher = searcher
        pcall(function()
            if searcher.SetAutoUpdateOnParamChanges then
                searcher:SetAutoUpdateOnParamChanges(false)
            end
            searcher:SetResultsUpdatedCallback(function()
                local finish = housingSearchDone
                housingSearchDone = nil
                if finish then
                    Database:FinishHousingResults(finish)
                end
            end)
        end)
    end
    housingSearchDone = done
    -- Mirror the live catalog filter state (Blizzard UI -> EasyFind DB) so our
    -- housing results match what the player has filtered in the catalog window.
    self:SyncHousingFiltersFromBlizzard()
    local okRun = pcall(function()
        local searcher = housingSearcher
        searcher:SetSearchText("")
        ApplyHousingFilters(searcher, EasyFind.db)
        if searcher.SetBaseVariantOnly then searcher:SetBaseVariantOnly(true) end
        searcher:RunSearch()
    end)
    if not okRun then
        housingSearchDone = nil
        done(false, "cancelled")
        return
    end
    -- Watchdog: on a fresh session the catalog can stay silent (the
    -- results callback never fires until the server sends data), which
    -- would leave this provider's scheduler job "running" forever and
    -- housing absent all session. Time out as cancelled so the next
    -- search retries; a late callback is a no-op because the pending
    -- completion is cleared here first.
    if Utils.SafeAfter then
        Utils.SafeAfter(4, function()
            if housingSearchDone == done then
                housingSearchDone = nil
                done(false, "cancelled")
            end
        end)
    end
end

function Database:PopulateDynamicToys()
    if not C_ToyBox then return false end

    local GetToyInfo = C_ToyBox.GetToyInfo
    local GetNumFilteredToys = C_ToyBox.GetNumFilteredToys
    local GetToyFromIndex = C_ToyBox.GetToyFromIndex
    if not GetToyInfo or not GetNumFilteredToys or not GetToyFromIndex then return false end

    local hasFilterAPI = C_ToyBox.GetCollectedShown and C_ToyBox.SetCollectedShown
    local savedCollected = hasFilterAPI and C_ToyBox.GetCollectedShown()
    local savedUncollected = C_ToyBox.GetUncollectedShown and C_ToyBox.GetUncollectedShown()
    local savedString = C_ToyBox.GetFilterString and C_ToyBox.GetFilterString() or ""

    if hasFilterAPI then C_ToyBox.SetCollectedShown(true) end
    if C_ToyBox.SetUncollectedShown then C_ToyBox.SetUncollectedShown(false) end
    if C_ToyBox.SetAllSourceTypeFilters then C_ToyBox.SetAllSourceTypeFilters(true) end
    if C_ToyBox.SetAllExpansionTypeFilters then C_ToyBox.SetAllExpansionTypeFilters(true) end
    if C_ToyBox.SetFilterString then C_ToyBox.SetFilterString("") end
    if C_ToyBox.ForceToyRefilter then C_ToyBox.ForceToyRefilter() end

    local function restoreFilters()
        if hasFilterAPI then C_ToyBox.SetCollectedShown(savedCollected) end
        if C_ToyBox.SetUncollectedShown then C_ToyBox.SetUncollectedShown(savedUncollected) end
        if C_ToyBox.SetFilterString then C_ToyBox.SetFilterString(savedString) end
        if C_ToyBox.ForceToyRefilter then C_ToyBox.ForceToyRefilter() end
    end

    local numToys = GetNumFilteredToys()
    if not numToys or numToys == 0 then
        -- Zero filtered toys at login means the toy box has not streamed
        -- yet (TOYS_UPDATED pending), not an empty collection: not-ready,
        -- and BEFORE the category wipe so a transient zero read cannot
        -- empty previously good entries mid-session.
        restoreFilters()
        return false
    end

    RemoveEntriesByCategory("Toy")

    for i = 1, numToys do
        local itemID = GetToyFromIndex(i)
        if itemID and itemID > 0 then
            local _, toyName, toyIcon = GetToyInfo(itemID)
            if toyName and toyName ~= "" then
                -- Tag faction/class-restricted toys so the click handler routes to
                -- ToyBox highlight instead of a silently no-op secure use.
                -- IsToyUsable matches the default UI's Use button state; the broader
                -- IsUsableItem can fail when item info isn't cached at PLAYER_LOGIN.
                local isUsable = true
                if C_ToyBox and C_ToyBox.IsToyUsable then
                    local ok, usable = pcall(C_ToyBox.IsToyUsable, itemID)
                    if ok and usable == false then isUsable = false end
                end
                local entry = setmetatable({
                    name = toyName,
                    icon = toyIcon,
                    toyItemID = itemID,
                    nameLower = slower(toyName),
                }, TOY_MT)
                if not isUsable then entry.isToyboxOnly = true end
                uiSearchData[#uiSearchData + 1] = entry
            end
        end
    end

    restoreFilters()
    return true
end

function Database:PopulateDynamicPets()
    if not C_PetJournal or not C_PetJournal.GetNumPets then return false end

    local savedCollected = C_PetJournal.IsFilterChecked and C_PetJournal.IsFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED)
    local savedNotCollected = C_PetJournal.IsFilterChecked and C_PetJournal.IsFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED)
    local savedString = C_PetJournal.GetSearchFilter and C_PetJournal.GetSearchFilter() or ""

    if C_PetJournal.SetFilterChecked then
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, false)
    end
    if C_PetJournal.SetAllPetSourcesChecked then C_PetJournal.SetAllPetSourcesChecked(true) end
    if C_PetJournal.SetAllPetTypesChecked then C_PetJournal.SetAllPetTypesChecked(true) end
    if C_PetJournal.SetSearchFilter then C_PetJournal.SetSearchFilter("") end

    local function restoreFilters()
        if C_PetJournal.SetFilterChecked then
            if savedCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, savedCollected) end
            if savedNotCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, savedNotCollected) end
        end
        if C_PetJournal.SetSearchFilter then C_PetJournal.SetSearchFilter(savedString) end
    end

    local numPets = C_PetJournal.GetNumPets()
    if not numPets or numPets == 0 then
        -- Zero pets before PET_JOURNAL_LIST_UPDATE means the journal has
        -- not streamed yet: not-ready, and BEFORE the category wipe so a
        -- transient zero read cannot empty previously good entries.
        restoreFilters()
        return false
    end

    RemoveEntriesByCategory("Pet")

    local seen = {}
    for i = 1, numPets do
        local petID, speciesID, owned, _, _, _, _,
              speciesName, icon = C_PetJournal.GetPetInfoByIndex(i)
        if speciesName and speciesName ~= "" and owned and not seen[speciesID] then
            seen[speciesID] = true
            uiSearchData[#uiSearchData + 1] = setmetatable({
                name = speciesName,
                icon = icon,
                petID = petID,
                speciesID = speciesID,
                nameLower = slower(speciesName),
            }, PET_MT)
        end
    end

    restoreFilters()
    return true
end

function Database:PopulateDynamicHeirlooms()
    if not C_Heirloom or not C_Heirloom.GetHeirloomItemIDs then return false end

    -- Align the journal's class/spec filter with our saved choice first, so the
    -- searchFiltered flag below reflects it.
    self:SyncHeirloomJournalFilter()

    local ids = C_Heirloom.GetHeirloomItemIDs()
    if type(ids) ~= "table" then return false end

    local hasHeirloom = C_Heirloom.PlayerHasHeirloom
    local getInfo = C_Heirloom.GetHeirloomInfo
    if not getInfo then return false end

    -- Readiness = streamed item names, NOT post-filter survivors: a user
    -- filter that legitimately hides every heirloom must still count as
    -- loaded, or the provider re-runs forever. Checked BEFORE the wipe so
    -- a not-ready read cannot empty previously good entries.
    local streamed = 0
    for _, itemID in ipairs(ids) do
        if getInfo(itemID) then streamed = streamed + 1 end
    end
    if streamed == 0 then return false end

    RemoveEntriesByCategory("Heirloom")

    local getItemIcon = C_Item and C_Item.GetItemIconByID
    for _, itemID in ipairs(ids) do
        -- searchFiltered (7th return) reflects the journal's class/spec filter:
        -- true means this heirloom isn't usable by the selected class/spec, so it
        -- would be hidden in the journal and can't be navigated to. Skip it so
        -- our results stay in sync with the Heirlooms Journal class dropdown.
        local name, _, _, icon, _, source, searchFiltered = getInfo(itemID)
        if not searchFiltered then
            if (not icon or icon == 0) and getItemIcon then
                icon = getItemIcon(itemID)
            end
            if name and name ~= "" then
                local entry = setmetatable({
                    name = name,
                    nameLower = slower(name),
                    icon = icon,
                    heirloomItemID = itemID,
                    isCollected = ((not hasHeirloom) or hasHeirloom(itemID)) and true or false,
                    heirloomSourceType = source,
                }, HEIRLOOM_MT)
                if self:HeirloomPassesSearchFilters(entry) then
                    uiSearchData[#uiSearchData + 1] = entry
                end
            end
        end
    end
    return true
end

function Database:HeirloomPassesSearchFilters(data)
    if not data or not data.heirloomItemID then return false end
    local db = EasyFind and EasyFind.db
    if not db then return true end

    if data.isCollected then
        if db.heirloomFilterCollected == false then return false end
    elseif db.heirloomFilterNotCollected == false then
        return false
    end

    local sourceFilters = db.heirloomSourceFilters
    local sourceType = data.heirloomSourceType
    if sourceType and type(sourceFilters) == "table" and sourceFilters[sourceType] == false then
        return false
    end

    return true
end

-- Title names contain a "%s" placeholder for the player name; strip it so
-- "the Insane" displays instead of "%s the Insane".
function Database:PopulateDynamicTitles()
    local getNum = GetNumTitles
    local getName = GetTitleName
    local isKnown = IsTitleKnown
    if not getNum or not getName or not isKnown then return false end

    local total = getNum()
    if not total or total <= 0 then return false end

    -- GetNumTitles is static client data, but IsTitleKnown reads the
    -- server-sent known list (KNOWN_TITLES_UPDATE): zero known titles at
    -- login means it has not arrived, not that the character has none.
    -- Checked BEFORE the wipe so a not-ready read cannot empty previously
    -- good entries mid-session.
    local known = 0
    for titleID = 1, total do
        if isKnown(titleID) then known = known + 1 end
    end
    if known == 0 then return false end

    RemoveEntriesByCategory("Title")

    for titleID = 1, total do
        if isKnown(titleID) then
            local raw = getName(titleID)
            if raw and raw ~= "" then
                local display = raw:gsub("%%s", ""):gsub("^%s+", ""):gsub("%s+$", "")
                if display == "" then display = raw end
                uiSearchData[#uiSearchData + 1] = setmetatable({
                    name = display,
                    titleID = titleID,
                    nameLower = slower(display),
                }, TITLE_MT)
            end
        end
    end
    return true
end


function Database:PopulateDynamicGearSets()
    if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then return false end

    local ids = C_EquipmentSet.GetEquipmentSetIDs()
    if type(ids) ~= "table" then return false end

    RemoveEntriesByCategory("Gear Set")

    local getInfo = C_EquipmentSet.GetEquipmentSetInfo
    if not getInfo then return false end

    for _, setID in ipairs(ids) do
        local name, iconFileID = getInfo(setID)
        if name and name ~= "" then
            uiSearchData[#uiSearchData + 1] = setmetatable({
                name = name,
                icon = iconFileID,
                gearSetID = setID,
                nameLower = slower(name),
            }, GEAR_SET_MT)
        end
    end
    if self.ResetSearchCache then self:ResetSearchCache() end
    return true
end

function Database:PopulateDynamicOutfits()
    if not C_TransmogOutfitInfo or not C_TransmogOutfitInfo.GetOutfitsInfo then return false end

    RemoveEntriesByCategory("Outfit")
    local outfits = C_TransmogOutfitInfo.GetOutfitsInfo()
    if not outfits then return false end

    -- The player can give several outfits the same name; identical result
    -- rows then look like equipping picks the "wrong" one even though the
    -- click equips exactly the row's outfit. Suffix duplicates so each row
    -- is distinguishable and verifiable.
    local nameCounts = {}
    for i = 1, #outfits do
        local info = outfits[i]
        if info and not info.isDisabled and info.name then
            nameCounts[info.name] = (nameCounts[info.name] or 0) + 1
        end
    end
    local nameSeen = {}

    for index, info in ipairs(outfits) do
        if not info.isDisabled then
            local displayName = info.name
            if displayName and (nameCounts[displayName] or 0) > 1 then
                nameSeen[displayName] = (nameSeen[displayName] or 0) + 1
                displayName = displayName .. " (" .. nameSeen[displayName] .. ")"
            end
            local entry = setmetatable({
                name = displayName,
                icon = info.icon,
                outfitID = info.outfitID,
                outfitIndex = index,
                nameLower = slower(displayName),
            }, OUTFIT_MT)
            uiSearchData[#uiSearchData + 1] = entry
        end
    end
    return true
end

function Database:PopulateDynamicCommands()
    RemoveEntriesByCategory("Command")
    local entries = ns.SearchCommands and ns.SearchCommands.BuildCommandSearchData
        and ns.SearchCommands:BuildCommandSearchData()
    if not entries then return false end
    for i = 1, #entries do
        uiSearchData[#uiSearchData + 1] = entries[i]
    end
    return true
end

function Database:SyncTransmogSetFiltersFromUI()
    local db = EasyFind and EasyFind.db
    if not db then return end
    local getFilter = C_TransmogSets and (C_TransmogSets.GetBaseSetsFilter or C_TransmogSets.GetSetsFilter)
    if getFilter then
        -- Enum: 1=Collected, 2=Not Collected, 3=PvE, 4=PvP
        local ok1, v1 = pcall(getFilter, 1)
        local ok2, v2 = pcall(getFilter, 2)
        local ok3, v3 = pcall(getFilter, 3)
        local ok4, v4 = pcall(getFilter, 4)
        if ok1 then db.appearanceSetCollected = v1 end
        if ok2 then db.appearanceSetNotCollected = v2 end
        if ok3 then db.appearanceSetPvE = v3 end
        if ok4 then db.appearanceSetPvP = v4 end
    end
    -- Class is intentionally NOT read here. This runs on filter-menu open and as
    -- the Sets populate `pre`, both BEFORE our own class push settles, so reading
    -- the game's (stale, player-class) Sets filter would overwrite the user's
    -- chosen class every time -- the Items/Sets flip-flop. Game->db for the class
    -- comes from the SetTransmogSetsClassFilter forward hook instead.
end

function Database:PopulateDynamicTransmogSets()
    if not C_TransmogSets or not C_TransmogSets.GetAllSets then return false end

    RemoveEntriesWithField("transmogSetID")
    -- Without this, a query typed before repopulate (e.g. "cauldron" while
    -- Druid sets were active) reuses prevCandidates and misses the new entries.
    if self.ResetSearchCache then self:ResetSearchCache() end

    local allSets = C_TransmogSets.GetAllSets()
    if not allSets then return false end

    local db = EasyFind and EasyFind.db
    if not db then return false end
    local classFilter = db.appearanceSetClass
    local showCollected = not db or db.appearanceSetCollected ~= false
    local showNotCollected = not db or db.appearanceSetNotCollected ~= false
    local showPvE = not db or db.appearanceSetPvE ~= false
    local showPvP = not db or db.appearanceSetPvP ~= false

    -- Guard against the Core/Main.lua hooksecurefunc re-entering Populate.
    if C_TransmogSets.SetTransmogSetsClassFilter then
        EasyFind._tmogClassHookSuppress = true
        if not classFilter then
            local _, _, cid = UnitClass("player")
            if cid then C_TransmogSets.SetTransmogSetsClassFilter(cid) end
        elseif classFilter ~= "all" and type(classFilter) == "table" and classFilter.classID then
            C_TransmogSets.SetTransmogSetsClassFilter(classFilter.classID)
        end
        EasyFind._tmogClassHookSuppress = false
    end

    -- BaseSetsFilter enum: 1=Collected, 2=Not Collected, 3=PvE, 4=PvP
    local syncFilter = C_TransmogSets.SetBaseSetsFilter or C_TransmogSets.SetSetsFilter
    if syncFilter then
        pcall(syncFilter, 1, showCollected)
        pcall(syncFilter, 2, showNotCollected)
        pcall(syncFilter, 3, showPvE)
        pcall(syncFilter, 4, showPvP)
    end

    local wcf = _G["WardrobeCollectionFrame"]
    local scf = wcf and wcf.SetsCollectionFrame
    if scf and scf:IsShown() then
        if scf.SetDataSource then pcall(scf.SetDataSource, scf) end
        if scf.UpdateUI then pcall(scf.UpdateUI, scf) end
        if scf.Refresh then pcall(scf.Refresh, scf) end
    end
    if wcf and wcf.ClassDropdown and wcf.ClassDropdown.Update then
        pcall(wcf.ClassDropdown.Update, wcf.ClassDropdown)
    end

    local wantMask
    if not classFilter then
        local _, _, cid = UnitClass("player")
        wantMask = cid and lshift(1, cid - 1) or 0
    elseif classFilter == "all" then
        wantMask = nil
    elseif type(classFilter) == "table" and classFilter.classID then
        wantMask = lshift(1, classFilter.classID - 1)
    end

    local GetSetPrimaryAppearances = C_TransmogSets.GetSetPrimaryAppearances
    local GetSourceIcon = C_TransmogCollection and C_TransmogCollection.GetSourceIcon

    for i = 1, #allSets do
        local setInfo = allSets[i]
        -- Variants share visuals with their base set and aren't navigable in the Sets list.
        local isBaseSet = true
        if C_TransmogSets.GetBaseSetID then
            local bid = C_TransmogSets.GetBaseSetID(setInfo.setID)
            isBaseSet = not bid or bid == setInfo.setID
        end
        if isBaseSet and setInfo.name and setInfo.name ~= "" and not setInfo.hiddenUntilCollected then
            local cm = setInfo.classMask or 0
            local classOk = not wantMask or cm == 0 or cm < 0 or band(cm, wantMask) ~= 0

            local label = setInfo.label or ""
            local labelLower = slower(label)
            local isPvP = sfind(labelLower, "pvp") or sfind(labelLower, "season")
                or sfind(labelLower, "gladiator") or sfind(labelLower, "aspirant")
                or sfind(labelLower, "combatant")
            local sourceOk = (isPvP and showPvP) or (not isPvP and showPvE)

            local collected = setInfo.collected
            local collectedOk = true
            if not (showCollected and showNotCollected) then
                if collected and not showCollected then collectedOk = false end
                if not collected and not showNotCollected then collectedOk = false end
            end

            if classOk and sourceOk and collectedOk then
                local nameLower = slower(setInfo.name)
                local kw = {"set", "transmog", "tmog", "xmog", "appearance"}
                local kwLen = 3
                if label ~= "" then
                    kwLen = kwLen + 1
                    kw[kwLen] = labelLower
                end
                if setInfo.description and setInfo.description ~= "" then
                    local descLower = slower(setInfo.description)
                    if descLower ~= nameLower then
                        kwLen = kwLen + 1
                        kw[kwLen] = descLower
                    end
                end

                local icon
                if GetSetPrimaryAppearances and GetSourceIcon then
                    local appearances = GetSetPrimaryAppearances(setInfo.setID)
                    if appearances and appearances[1] then
                        local sourceID = appearances[1].appearanceID
                        if sourceID then
                            icon = GetSourceIcon(sourceID)
                        end
                    end
                end

                uiSearchData[#uiSearchData + 1] = setmetatable({
                    name = setInfo.name,
                    nameLower = nameLower,
                    transmogSetID = setInfo.setID,
                    icon = icon,
                    keywords = kw,
                }, TRANSMOG_SET_MT)
            end
        end
    end
    return true
end


-- One transmog slot (default Head) is enumerated per populate. The whole-game
-- list is far too large (~3600 head visuals alone), so the slot + class + source
-- filters from the Appearances > Items menu scope it down to a searchable set.
function Database:PopulateDynamicAppearanceItems()
    local C = C_TransmogCollection
    if not C or not C.GetCategoryAppearances then return false end

    RemoveEntriesWithField("appearanceItemID")
    if self.ResetSearchCache then self:ResetSearchCache() end

    local db = EasyFind and EasyFind.db
    if not db then return false end

    local showCollected = db.appearanceItemCollected ~= false
    local showNotCollected = db.appearanceItemNotCollected == true
    if not showCollected and not showNotCollected then return true end

    local classFilter = db.appearanceItemClass
    local sourceFilters = db.appearanceItemSourceFilters

    -- An all-off source filter (every type disabled) would hide the entire
    -- collection -- never intended, usually an accidental Toggle All. Treat it
    -- as no filter and clear the stale state so the menu reflects all-on again.
    if type(sourceFilters) == "table" then
        local anyEnabled = false
        for st = 1, 12 do
            if _G["TRANSMOG_SOURCE_" .. st] and sourceFilters[st] ~= false then
                anyEnabled = true
                break
            end
        end
        if not anyEnabled then
            db.appearanceItemSourceFilters = nil
            sourceFilters = nil
        end
    end

    -- Push our class choice into the journal filter so the list matches the Items
    -- tab. Changing it refreshes the collection ASYNCHRONOUSLY: reading
    -- GetCategoryAppearances right after returns a stale/empty list (the wardrobe
    -- is mid-rebuild). So only set it when it actually differs, then DEFER -- the
    -- change fires TRANSMOG_COLLECTION_UPDATED, whose handler re-runs us once the
    -- per-class list has settled. Guarded against the Core hooksecurefunc re-entry.
    if C.SetClassFilter and C.GetClassFilter then
        local _, _, playerClassID = UnitClass("player")
        local targetClass = playerClassID
        if classFilter == "all" then
            targetClass = 0
        elseif type(classFilter) == "table" and classFilter.classID then
            targetClass = classFilter.classID
        end
        local okCur, currentClass = pcall(C.GetClassFilter)
        if targetClass and okCur and currentClass ~= targetClass then
            EasyFind._appItemClassHookSuppress = true
            pcall(C.SetClassFilter, targetClass)
            EasyFind._appItemClassHookSuppress = false
            -- Reverse sync: the transmog wardrobe does NOT auto-refresh on
            -- SetClassFilter (unlike the EJ on SetLootFilter), so push the change
            -- into the open Appearances > Items panel ourselves. Mirrors the Sets
            -- provider's wardrobe refresh (scf:UpdateUI + ClassDropdown:Update).
            local wcf = _G["WardrobeCollectionFrame"]
            if wcf then
                if wcf.ClassDropdown and wcf.ClassDropdown.Update then
                    pcall(wcf.ClassDropdown.Update, wcf.ClassDropdown)
                end
                local icf = wcf.ItemsCollectionFrame
                if icf and icf.RefreshVisualsList and icf.IsShown and icf:IsShown() then
                    pcall(icf.RefreshVisualsList, icf)
                end
            end
            -- Data now refreshing; the event re-run builds the settled list.
            -- Fallback in case TRANSMOG_COLLECTION_UPDATED doesn't arrive.
            EasyFind._appItemClassDeferred = true
            local database = self
            if Utils and Utils.SafeAfter then
                Utils.SafeAfter(0.7, function()
                    if EasyFind._appItemClassDeferred and database.RefreshDynamicCategory then
                        database:RefreshDynamicCategory("appearanceItems")
                    end
                end)
            end
            return true
        end
    end
    EasyFind._appItemClassDeferred = nil

    -- One slot at a time (default Head) so the slot filter keeps results
    -- focused. Stale/non-numeric saved values fall back to Head.
    local slot = db.appearanceItemSlot
    if type(slot) ~= "number" then
        slot = (Enum.TransmogCollectionType and Enum.TransmogCollectionType.Head) or 1
    end
    local slotCats = { slot }

    -- Appearance data is gated behind the on-demand Collections addon; until it
    -- loads, GetCategoryAppearances returns nothing. Load it once so search works
    -- even if the player never opened the Appearances journal this session. The
    -- TRANSMOG_COLLECTION_UPDATED handler re-runs us once the data settles.
    local probe = C.GetCategoryAppearances(slotCats[1])
    if (not probe or #probe == 0) and C_AddOns and C_AddOns.LoadAddOn
       and not C_AddOns.IsAddOnLoaded("Blizzard_Collections") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_Collections")
        probe = C.GetCategoryAppearances(slotCats[1])
    end
    if not probe or #probe == 0 then return false end

    -- Arm the reverse slot-sync hooks now that Collections is loaded.
    if ns.Filters and ns.Filters.EnsureWardrobeItemSlotHooks then
        ns.Filters:EnsureWardrobeItemSlotHooks()
    end

    local GetSources = C.GetAppearanceSources
    local GetSourceInfo = C.GetSourceInfo
    local GetSourceIcon = C.GetSourceIcon
    local getCatInfo = C.GetCategoryInfo

    for ci = 1, #slotCats do
        local catID = slotCats[ci]
        local appearances = C.GetCategoryAppearances(catID)
        if appearances and #appearances > 0 then
            local slotName
            if getCatInfo then
                local okN, n = pcall(getCatInfo, catID)
                if okN and type(n) == "string" and n ~= "" then slotName = n end
            end
            local kw = { "appearance", "transmog", "tmog", "xmog" }
            if slotName then kw[#kw + 1] = slower(slotName) end

            for i = 1, #appearances do
                local app = appearances[i]
                -- Pre-skip appearances that can contribute no visible source
                -- (e.g. collected-only and this whole appearance is uncollected).
                local appOk = (app.isCollected and showCollected)
                    or (not app.isCollected and showNotCollected)
                if appOk and app.visualID and GetSources then
                    local sources = GetSources(app.visualID)
                    if sources then
                        -- One entry per source item, not per appearance. Items
                        -- that share a visual (e.g. "Cowl of Sina's Stalwarts"
                        -- and another cowl) are each searchable by their own
                        -- name, all navigating to the same appearance.
                        for s = 1, #sources do
                            local src = sources[s]
                            local collectedOk = (src.isCollected and showCollected)
                                or (not src.isCollected and showNotCollected)
                            local st = src.sourceType
                            local srcOk = not sourceFilters or not st or sourceFilters[st] ~= false
                            if collectedOk and srcOk then
                                local name
                                if GetSourceInfo and src.sourceID then
                                    local info = GetSourceInfo(src.sourceID)
                                    if info and info.name and info.name ~= "" then name = info.name end
                                end
                                if not name and src.itemID and GetItemInfo then
                                    name = GetItemInfo(src.itemID)
                                end
                                if name and name ~= "" then
                                    local icon = GetSourceIcon and src.sourceID and GetSourceIcon(src.sourceID)
                                    uiSearchData[#uiSearchData + 1] = setmetatable({
                                        name = name,
                                        nameLower = slower(name),
                                        appearanceItemID = src.sourceID,
                                        appearanceVisualID = app.visualID,
                                        appearanceSlot = catID,
                                        appearanceSlotName = slotName,
                                        icon = icon,
                                        keywords = kw,
                                    }, APPEARANCE_ITEM_MT)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return true
end

function Database:PopulateDynamicAppearanceItemsAsync(done)
    done = done or function() end
    if not Utils.SafeAfter then
        local ready = self:PopulateDynamicAppearanceItems()
        done(ready ~= false, ready == false and "cancelled" or nil)
        return
    end

    local C = C_TransmogCollection
    if not C or not C.GetCategoryAppearances then done(false, "cancelled"); return end

    RemoveEntriesWithField("appearanceItemID")
    if self.ResetSearchCache then self:ResetSearchCache() end

    local db = EasyFind and EasyFind.db
    if not db then done(false, "cancelled"); return end

    local showCollected = db.appearanceItemCollected ~= false
    local showNotCollected = db.appearanceItemNotCollected == true
    if not showCollected and not showNotCollected then done(true); return end

    local classFilter = db.appearanceItemClass
    local sourceFilters = db.appearanceItemSourceFilters

    if type(sourceFilters) == "table" then
        local anyEnabled = false
        for st = 1, 12 do
            if _G["TRANSMOG_SOURCE_" .. st] and sourceFilters[st] ~= false then
                anyEnabled = true
                break
            end
        end
        if not anyEnabled then
            db.appearanceItemSourceFilters = nil
            sourceFilters = nil
        end
    end

    if C.SetClassFilter and C.GetClassFilter then
        local _, _, playerClassID = UnitClass("player")
        local targetClass = playerClassID
        if classFilter == "all" then
            targetClass = 0
        elseif type(classFilter) == "table" and classFilter.classID then
            targetClass = classFilter.classID
        end
        local okCur, currentClass = pcall(C.GetClassFilter)
        if targetClass and okCur and currentClass ~= targetClass then
            EasyFind._appItemClassHookSuppress = true
            pcall(C.SetClassFilter, targetClass)
            EasyFind._appItemClassHookSuppress = false
            local wcf = _G["WardrobeCollectionFrame"]
            if wcf then
                if wcf.ClassDropdown and wcf.ClassDropdown.Update then
                    pcall(wcf.ClassDropdown.Update, wcf.ClassDropdown)
                end
                local icf = wcf.ItemsCollectionFrame
                if icf and icf.RefreshVisualsList and icf.IsShown and icf:IsShown() then
                    pcall(icf.RefreshVisualsList, icf)
                end
            end
            EasyFind._appItemClassDeferred = true
            local database = self
            Utils.SafeAfter(0.7, function()
                if EasyFind._appItemClassDeferred and database.RefreshDynamicCategory then
                    database:RefreshDynamicCategory("appearanceItems")
                end
            end)
            done(true)
            return
        end
    end
    EasyFind._appItemClassDeferred = nil

    local slot = db.appearanceItemSlot
    if type(slot) ~= "number" then
        slot = (Enum.TransmogCollectionType and Enum.TransmogCollectionType.Head) or 1
    end

    local probe = C.GetCategoryAppearances(slot)
    if (not probe or #probe == 0) and C_AddOns and C_AddOns.LoadAddOn
       and not C_AddOns.IsAddOnLoaded("Blizzard_Collections") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_Collections")
        probe = C.GetCategoryAppearances(slot)
    end
    if not probe or #probe == 0 then done(false, "cancelled"); return end

    if ns.Filters and ns.Filters.EnsureWardrobeItemSlotHooks then
        ns.Filters:EnsureWardrobeItemSlotHooks()
    end

    local GetSources = C.GetAppearanceSources
    local GetSourceInfo = C.GetSourceInfo
    local GetSourceIcon = C.GetSourceIcon
    local getCatInfo = C.GetCategoryInfo
    if not GetSources then done(false, "cancelled"); return end

    local appearances = C.GetCategoryAppearances(slot)
    if not appearances or #appearances == 0 then done(false, "cancelled"); return end

    local slotName
    if getCatInfo then
        local okN, n = pcall(getCatInfo, slot)
        if okN and type(n) == "string" and n ~= "" then slotName = n end
    end
    local kw = { "appearance", "transmog", "tmog", "xmog" }
    if slotName then kw[#kw + 1] = slower(slotName) end

    local appIndex = 1
    local sources
    local sourceIndex = 1
    local app
    local budgetMs = 3

    local function scheduleStep(step)
        Utils.SafeAfter(0, function()
            local ok, err = xpcall(step, Utils.ErrorHandler)
            if not ok then done(false, err) end
        end)
    end

    local function step()
        local start = debugprofilestop and debugprofilestop() or 0
        while appIndex <= #appearances do
            if not sources then
                app = appearances[appIndex]
                local appOk = app and ((app.isCollected and showCollected)
                    or (not app.isCollected and showNotCollected))
                sources = appOk and app.visualID and GetSources(app.visualID) or false
                sourceIndex = 1
            end

            if sources and sources ~= false then
                while sourceIndex <= #sources do
                    local src = sources[sourceIndex]
                    sourceIndex = sourceIndex + 1
                    local collectedOk = src and ((src.isCollected and showCollected)
                        or (not src.isCollected and showNotCollected))
                    local st = src and src.sourceType
                    local srcOk = not sourceFilters or not st or sourceFilters[st] ~= false
                    if collectedOk and srcOk then
                        local name
                        if GetSourceInfo and src.sourceID then
                            local info = GetSourceInfo(src.sourceID)
                            if info and info.name and info.name ~= "" then name = info.name end
                        end
                        if not name and src.itemID and GetItemInfo then
                            name = GetItemInfo(src.itemID)
                        end
                        if name and name ~= "" then
                            local icon = GetSourceIcon and src.sourceID and GetSourceIcon(src.sourceID)
                            uiSearchData[#uiSearchData + 1] = setmetatable({
                                name = name,
                                nameLower = slower(name),
                                appearanceItemID = src.sourceID,
                                appearanceVisualID = app.visualID,
                                appearanceSlot = slot,
                                appearanceSlotName = slotName,
                                icon = icon,
                                keywords = kw,
                            }, APPEARANCE_ITEM_MT)
                        end
                    end
                    if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                        scheduleStep(step)
                        return
                    end
                end
            end

            appIndex = appIndex + 1
            sources = nil
            app = nil
            if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                scheduleStep(step)
                return
            end
        end
        done(true)
    end

    scheduleStep(step)
end

local function AppendClassSpecPairs(specPairs, classID)
    for _, specID in ipairs(ClassSpecIDs(classID)) do
        specPairs[#specPairs + 1] = { classID = classID, specID = specID }
    end
end

local function AppendAllClassSpecPairs(specPairs)
    for classIdx = 1, GetNumClasses() do
        local _, _, classID = GetClassInfo(classIdx)
        if classID then
            AppendClassSpecPairs(specPairs, classID)
        end
    end
end

local function BuildLootSpecPairs(scanAllSpecs)
    local specPairs = {}
    if scanAllSpecs then
        AppendAllClassSpecPairs(specPairs)
    else
        local lootFilter = EasyFind.db.lootFilter
        if not lootFilter then
            local _, _, cid = UnitClass("player")
            local si = GetSpecialization and GetSpecialization()
            local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
            if cid and sid then
                specPairs[1] = { classID = cid, specID = sid }
            elseif cid then
                -- Unspecced character (below level 10): class-wide, so low
                -- alts still get loot results instead of an empty scan plan.
                AppendClassSpecPairs(specPairs, cid)
            end
        elseif lootFilter == "all" then
            AppendAllClassSpecPairs(specPairs)
        elseif lootFilter.specID then
            specPairs[1] = { classID = lootFilter.classID, specID = lootFilter.specID }
        elseif lootFilter.classID then
            AppendClassSpecPairs(specPairs, lootFilter.classID)
        end
    end
    return specPairs
end

local function GetLootSpecsToScan(specPairs)
    local needScan = {}
    for _, sp in ipairs(specPairs) do
        local key = sp.classID .. "-" .. sp.specID
        if not lootSpecsScanned[key] then
            needScan[#needScan + 1] = sp
        end
    end
    return needScan
end

local function GetLootDiffPairs(isRaid)
    local diffPairs = {}
    local st = isRaid and "raid" or "dungeon"
    for diffKey, ids in pairs(LOOT_DIFF_IDS) do
        if ids[st] then
            diffPairs[#diffPairs + 1] = { key = diffKey, id = ids[st] }
        end
    end
    return diffPairs
end

function Database:HydrateCachedLoot()
    if lootSearchDataHydrated then return false end
    HydratePersistedLootCache()
    if not next(lootItemCache) then return false end

    local specPairs = BuildLootSpecPairs(false)
    if #specPairs == 0 then return false end

    local needScan = GetLootSpecsToScan(specPairs)
    RebuildLootSearchData()
    if #needScan == 0 and self.MarkDynamicProviderLoaded then
        self:MarkDynamicProviderLoaded("loot")
    end
    return true
end

local function CacheLootInfo(database, lootInfo, inst, encName, encID, diff, sp, spKey, GetItemInfoInstantFn)
    local itemID = lootInfo.itemID
    if not itemID then return end
    local cached = lootItemCache[itemID]
    if cached then
        local changed = false
        local foundSp = false
        for _, sk in ipairs(cached._cachedSpecs) do
            if sk == spKey then foundSp = true; break end
        end
        if not foundSp then
            cached._cachedSpecs[#cached._cachedSpecs + 1] = spKey
            changed = true
        end

        local foundDf = false
        for _, dk in ipairs(cached._cachedDiffs) do
            if dk == diff.key then foundDf = true; break end
        end
        if not foundDf then
            cached._cachedDiffs[#cached._cachedDiffs + 1] = diff.key
            if lootInfo.link and cached.lootItemLinks then
                cached.lootItemLinks[diff.key] = lootInfo.link
            end
            changed = true
        end
        return changed
    end

    local itemName = lootInfo.name
    if not itemName or itemName == "" then return end
    local _, _, _, equipLoc, instIcon = GetItemInfoInstantFn(itemID)
    if not (equipLoc and SLOT_KEYWORDS[equipLoc]) and lootInfo.filterType then
        equipLoc = FILTER_TO_INVTYPE[lootInfo.filterType] or equipLoc
    end
    local slotKws = {}
    local slotKwVals = equipLoc and SLOT_KEYWORDS[equipLoc]
    if slotKwVals then
        for _, w in ipairs(slotKwVals) do slotKws[#slotKws + 1] = w end
    end

    local sourceKws = {}
    if encName then
        for w in encName:lower():gmatch("%a+") do sourceKws[#sourceKws + 1] = w end
    end
    if inst.name then
        for w in inst.name:lower():gmatch("%a+") do sourceKws[#sourceKws + 1] = w end
    end

    local itemLinks = {}
    if lootInfo.link then itemLinks[diff.key] = lootInfo.link end
    local entry = setmetatable({
        name = itemName,
        nameLower = slower(itemName),
        icon = lootInfo.icon or instIcon,
        itemID = itemID,
        keywords = EMPTY_KEYWORDS,
        lootSlotKw = slotKws,
        lootSourceKw = sourceKws,
        lootStatKw = {},
        lootItemLinks = itemLinks,
        lootSlotName = equipLoc and SLOT_DISPLAY[equipLoc],
        _cachedSpecs = { spKey },
        _cachedDiffs = { diff.key },
    }, GetLootEncounterMT(encID, inst.id, encName, inst.name, inst.isRaid))

    if lootInfo.link then
        database:EnrichLootStats(entry)
    end
    lootItemCache[itemID] = entry
    return true
end

function Database:CancelDynamicScans(includeBosses)
    lootScanGeneration = lootScanGeneration + 1
    if includeBosses then
        bossScanGeneration = bossScanGeneration + 1
    end
end

-- scanAllSpecs=true pre-caches every class/spec combo (loading screen path).
function Database:PopulateDynamicLoot(scanAllSpecs)
    if InCombatLockdown() then return false end
    HydratePersistedLootCache()

    local specPairs = BuildLootSpecPairs(scanAllSpecs)
    if #specPairs == 0 then return false end

    local needScan = GetLootSpecsToScan(specPairs)

    if #needScan == 0 then
        RebuildLootSearchData()
        return
    end

    -- EJ loot tables require the UI loaded first.
    if not EncounterJournal then
        EncounterJournal_LoadUI()
    end

    local EJ_GetCurrentTier     = EJ("GetCurrentTier")
    local EJ_SelectTier         = EJ("SelectTier")
    local EJ_GetInstanceByIndex = EJ("GetInstanceByIndex")
    local EJ_SelectInstance     = EJ("SelectInstance")
    local EJ_GetEncounterInfoByIndex = EJ("GetEncounterInfoByIndex")
    local EJ_SelectEncounter    = EJ("SelectEncounter")
    local EJ_SetDifficulty      = EJ("SetDifficulty")
    local EJ_SetLootFilter      = EJ("SetLootFilter")
    local EJ_SetSlotFilter      = EJ("SetSlotFilter")
    local EJ_GetLootInfoByIndex = EJ("GetLootInfoByIndex")
    local EJ_GetNumLoot         = EJ("GetNumLoot")

    if not EJ_GetCurrentTier or not EJ_GetInstanceByIndex or not EJ_GetLootInfoByIndex then
        Utils.DebugPrint("Loot scan aborted: EJ APIs not available")
        return false
    end

    -- Bump generation so any in-flight staggered scan aborts.
    lootScanGeneration = lootScanGeneration + 1
    local myGen = lootScanGeneration

    -- Suppress EJ UI events during scan.
    local ejFrame = _G["EncounterJournal"]
    local savedOnEvent
    if ejFrame then
        savedOnEvent = ejFrame:GetScript("OnEvent")
        ejFrame:SetScript("OnEvent", nil)
    end

    local savedTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    local instances = {}
    local function collectInstances(isRaid)
        local idx = 1
        while true do
            local instID, instName = EJ_GetInstanceByIndex(idx, isRaid)
            if not instID then break end
            instances[#instances + 1] = { id = instID, name = instName, isRaid = isRaid }
            idx = idx + 1
        end
    end
    collectInstances(false)
    collectInstances(true)

    local GetItemInfoInstant = GetItemInfoInstant

    for _, inst in ipairs(instances) do
        if myGen ~= lootScanGeneration then break end
        EJ_SelectInstance(inst.id)
        local diffPairs = GetLootDiffPairs(inst.isRaid)

        local encIdx = 1
        while true do
            local encName, _, encID = EJ_GetEncounterInfoByIndex(encIdx)
            if not encName then break end

            for _, diff in ipairs(diffPairs) do
                for _, sp in ipairs(needScan) do
                    local spKey = sp.classID .. "-" .. sp.specID
                    EJ_SelectInstance(inst.id)
                    EJ_SelectEncounter(encID)
                    if EJ_SetDifficulty then
                        EJ_SetDifficulty(diff.id)
                    end
                    if EJ_SetSlotFilter then
                        EJ_SetSlotFilter(Enum.ItemSlotFilterType.NoFilter)
                    end
                    if EJ_SetLootFilter then
                        EasyFind._lootFilterHookSuppress = true
                        EJ_SetLootFilter(sp.classID, sp.specID)
                        EasyFind._lootFilterHookSuppress = false
                    end

                    -- Count-driven like Blizzard's own reader: the count call
                    -- also issues the server request for this encounter's
                    -- loot, so even a cold pass primes a later attempt.
                    local numLoot = EJ_GetNumLoot and EJ_GetNumLoot() or 0
                    for li = 1, numLoot do
                        local lootInfo = EJ_GetLootInfoByIndex(li)
                        if lootInfo and lootInfo.name then
                            CacheLootInfo(Database, lootInfo, inst, encName, encID, diff, sp, spKey, GetItemInfoInstant)
                        end
                    end
                end
            end
            encIdx = encIdx + 1
        end
    end

    if savedTier and EJ_SelectTier then EJ_SelectTier(savedTier) end
    if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
    -- This synchronous fallback cannot wait for EJ_LOOT_DATA_RECIEVED, so it
    -- cannot tell a cold journal from genuinely empty loot. It keeps what it
    -- caches but never marks specs as scanned; the async path (the one that
    -- always runs in practice) certifies them once its reads resolve.
    PersistLootCache()
    RebuildLootSearchData()
    -- Restore the EJ loot filter to the user's choice; the scan swept it across
    -- specs, so the journal would otherwise show the last-scanned spec.
    Database:SyncEJLootFilter()
    Utils.SafeAfter(0, function()
        collectgarbage("step", 200)
    end)
end

function Database:PopulateDynamicLootAsync(done, scanAllSpecs)
    if InCombatLockdown() then done(false, "cancelled"); return end
    HydratePersistedLootCache()
    if not Utils.SafeAfter then
        local ready = self:PopulateDynamicLoot(scanAllSpecs)
        done(ready ~= false, ready == false and "cancelled" or nil)
        return
    end

    local specPairs = BuildLootSpecPairs(scanAllSpecs)
    if #specPairs == 0 then
        done(false, "cancelled")
        return
    end

    local needScan = GetLootSpecsToScan(specPairs)
    if #needScan == 0 then
        RebuildLootSearchData()
        done(true)
        return
    end

    if not EncounterJournal then
        EncounterJournal_LoadUI()
    end

    local EJ_GetCurrentTier     = EJ("GetCurrentTier")
    local EJ_SelectTier         = EJ("SelectTier")
    local EJ_GetInstanceByIndex = EJ("GetInstanceByIndex")
    local EJ_SelectInstance     = EJ("SelectInstance")
    local EJ_GetEncounterInfoByIndex = EJ("GetEncounterInfoByIndex")
    local EJ_SelectEncounter    = EJ("SelectEncounter")
    local EJ_SetDifficulty      = EJ("SetDifficulty")
    local EJ_SetLootFilter      = EJ("SetLootFilter")
    local EJ_SetSlotFilter      = EJ("SetSlotFilter")
    local EJ_GetLootInfoByIndex = EJ("GetLootInfoByIndex")
    -- EJ_GetNumLoot is what makes the client REQUEST the selected
    -- encounter's loot list from the server; reading items blind never
    -- triggers the fetch, which is how scans stayed cold forever.
    -- EJ_IsLootListOutOfDate disambiguates "empty" from "still loading".
    local EJ_GetNumLoot         = EJ("GetNumLoot")
    local EJ_IsLootListOutOfDate = EJ("IsLootListOutOfDate")

    if not EJ_GetCurrentTier or not EJ_GetInstanceByIndex or not EJ_GetLootInfoByIndex
       or not EJ_GetNumLoot then
        done(false, "cancelled")
        return
    end

    lootScanGeneration = lootScanGeneration + 1
    local myGen = lootScanGeneration
    local ejFrame = _G["EncounterJournal"]
    local savedOnEvent
    if ejFrame then
        savedOnEvent = ejFrame:GetScript("OnEvent")
        ejFrame:SetScript("OnEvent", nil)
    end
    local savedTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    local instances = {}
    local function collectInstances(isRaid)
        local idx = 1
        while true do
            local instID, instName = EJ_GetInstanceByIndex(idx, isRaid)
            if not instID then break end
            instances[#instances + 1] = { id = instID, name = instName, isRaid = isRaid }
            idx = idx + 1
        end
    end
    collectInstances(false)
    collectInstances(true)

    local state = {
        instIdx = 1,
        encIdx = 1,
        diffIdx = 1,
        specIdx = 1,
        lootIdx = 1,
        diffPairs = nil,
        encName = nil,
        encID = nil,
        prepared = false,
        waiting = false,
        waitDeadline = nil,
        lootDataDirty = false,
    }
    local GetItemInfoInstantFn = GetItemInfoInstant
    local budgetMs = 4
    local partialLootChanged = false
    -- Cumulative, unlike partialLootChanged which resets on every budget
    -- flush: did this sweep cache anything at all?
    local sweepCachedAny = false
    -- True when any cell gave up waiting for journal data or had pending
    -- item slots: the sweep's results are kept (partial data is real data)
    -- but the specs are NOT marked scanned, so a later session retries
    -- instead of permanently trusting a cold-journal snapshot.
    local scanIncomplete = false

    if not lootEventFrame then
        lootEventFrame = CreateFrame("Frame")
        lootEventFrame:RegisterEvent("EJ_LOOT_DATA_RECIEVED")
        lootEventFrame:SetScript("OnEvent", function()
            if activeLootScan then activeLootScan.lootDataDirty = true end
        end)
    end
    activeLootScan = state

    local function finish(changed, err)
        if activeLootScan == state then activeLootScan = nil end
        if savedTier and EJ_SelectTier then EJ_SelectTier(savedTier) end
        if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
        if changed and scanIncomplete and not sweepCachedAny
           and not next(lootItemCache) then
            -- Entirely cold sweep AND no usable cache at all: report a
            -- transient failure so the provider is not marked loaded for
            -- the session pinned to an empty category; a later search
            -- retries the scan. When a hydrated cache exists, fall through
            -- instead: its data must be rebuilt into search even if this
            -- sweep added nothing new.
            Database:SyncEJLootFilter()
            done(false, "cancelled")
            return
        end
        if changed then
            if not scanIncomplete then
                for _, sp in ipairs(needScan) do
                    lootSpecsScanned[sp.classID .. "-" .. sp.specID] = true
                end
            end
            PersistLootCache()
            RebuildLootSearchData()
            Database:SyncEJLootFilter()
            collectgarbage("step", 200)
        end
        done(changed, err)
    end

    local function step()
        if myGen ~= lootScanGeneration then
            finish(false, "cancelled")
            return
        end

        local start = debugprofilestop and debugprofilestop() or 0
        while true do
            local inst = instances[state.instIdx]
            if not inst then
                finish(true)
                return
            end

            if not state.diffPairs then
                EJ_SelectInstance(inst.id)
                state.diffPairs = GetLootDiffPairs(inst.isRaid)
                state.encIdx = 1
                state.diffIdx = 1
                state.specIdx = 1
                state.lootIdx = 1
                state.prepared = false
            end

            if not state.encName then
                local encName, _, encID = EJ_GetEncounterInfoByIndex(state.encIdx)
                if not encName then
                    state.instIdx = state.instIdx + 1
                    state.diffPairs = nil
                    state.encName = nil
                    state.encID = nil
                    state.prepared = false
                else
                    state.encName = encName
                    state.encID = encID
                end
            elseif not state.diffPairs[state.diffIdx] then
                state.encIdx = state.encIdx + 1
                state.diffIdx = 1
                state.specIdx = 1
                state.lootIdx = 1
                state.encName = nil
                state.encID = nil
                state.prepared = false
            elseif not needScan[state.specIdx] then
                state.diffIdx = state.diffIdx + 1
                state.specIdx = 1
                state.lootIdx = 1
                state.prepared = false
            elseif state.waiting then
                -- Holding on a cell whose loot list the client reported as
                -- out of date: the EJ_GetNumLoot call in prepare requested
                -- it from the server, now wait for the arrival event.
                if state.lootDataDirty then
                    -- Data landed: re-assert the selection and re-evaluate
                    -- this same cell.
                    state.lootDataDirty = false
                    state.waiting = false
                    state.prepared = false
                elseif GetTime() > state.waitDeadline then
                    -- Nothing arrived in time: skip the cell, keep whatever
                    -- the sweep does collect, but refuse to certify the
                    -- specs as scanned.
                    scanIncomplete = true
                    state.waiting = false
                    state.waitDeadline = nil
                    state.specIdx = state.specIdx + 1
                    state.lootIdx = 1
                    state.prepared = false
                else
                    Utils.SafeAfter(0.1, function()
                        local ok, err = xpcall(step, Utils.ErrorHandler)
                        if not ok then finish(false, err) end
                    end)
                    return
                end
            else
                local diff = state.diffPairs[state.diffIdx]
                local sp = needScan[state.specIdx]
                local spKey = sp.classID .. "-" .. sp.specID
                if not state.prepared then
                    EJ_SelectInstance(inst.id)
                    EJ_SelectEncounter(state.encID)
                    if EJ_SetDifficulty then EJ_SetDifficulty(diff.id) end
                    if EJ_SetSlotFilter then EJ_SetSlotFilter(Enum.ItemSlotFilterType.NoFilter) end
                    if EJ_SetLootFilter then
                        EasyFind._lootFilterHookSuppress = true
                        EJ_SetLootFilter(sp.classID, sp.specID)
                        EasyFind._lootFilterHookSuppress = false
                    end
                    state.lootIdx = 1
                    -- The count call doubles as the server request for this
                    -- encounter's loot list (this is how Blizzard's own UI
                    -- reads it; item probes alone never trigger the fetch).
                    state.cellNum = EJ_GetNumLoot()
                    state.cellStale = EJ_IsLootListOutOfDate and EJ_IsLootListOutOfDate() or false
                    state.cellPending = false
                    state.prepared = true
                end

                if state.cellStale then
                    -- List not authoritative yet: hold for the event. The
                    -- deadline is set once per cell and survives retries.
                    state.waiting = true
                    if not state.waitDeadline then
                        state.waitDeadline = GetTime() + 1.5
                    end
                else
                    local processed = 0
                    while processed < 8 do
                        if state.lootIdx > (state.cellNum or 0) then
                            -- Cell complete. A fresh list with count 0 is
                            -- PROVABLY empty (spec/difficulty with no
                            -- loot), so it neither waits nor taints the
                            -- certification.
                            if state.cellPending then scanIncomplete = true end
                            state.waitDeadline = nil
                            state.specIdx = state.specIdx + 1
                            state.lootIdx = 1
                            state.prepared = false
                            break
                        end
                        local lootInfo = EJ_GetLootInfoByIndex(state.lootIdx)
                        if lootInfo and lootInfo.name and lootInfo.itemID then
                            if CacheLootInfo(self, lootInfo, inst, state.encName, state.encID, diff, sp, spKey, GetItemInfoInstantFn) then
                                partialLootChanged = true
                                sweepCachedAny = true
                            end
                        else
                            -- Slot exists per the count but its item data
                            -- is still pending: keep going, remember the
                            -- gap so the specs are not certified.
                            state.cellPending = true
                        end
                        state.lootIdx = state.lootIdx + 1
                        processed = processed + 1
                    end
                end
            end

            if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                if partialLootChanged then
                    partialLootChanged = false
                    RebuildLootSearchData()
                    if self.SchedulePartialSearchRefresh then
                        -- 750ms, not snappier: each refresh is a full cold
                        -- re-score plus render (the cache is reset), and a
                        -- first-time scan flushes for minutes; at 150ms the
                        -- refresh stream alone drags the frame rate down
                        -- while a loot search is open.
                        self:SchedulePartialSearchRefresh(750)
                    end
                end
                Utils.SafeAfter(0, function()
                    local ok, err = xpcall(step, Utils.ErrorHandler)
                    if not ok then finish(false, err) end
                end)
                return
            end
        end
    end

    Utils.SafeAfter(0, function()
        local ok, err = xpcall(step, Utils.ErrorHandler)
        if not ok then finish(false, err) end
    end)
end

function Database:PopulateDynamicMacros()
    if not GetNumMacros or not GetMacroInfo then return false end

    RemoveEntriesByCategory("Macro")
    if self.ResetSearchCache then self:ResetSearchCache() end

    local numGlobal, numPerChar = GetNumMacros()
    local MAX_ACCOUNT = MAX_ACCOUNT_MACROS or 120

    local function injectMacro(macroIdx, isCharSpecific)
        local name, iconTexture, body = GetMacroInfo(macroIdx)
        if not name or name == "" then return end
        local nameLower = slower(name)
        local kw = { "macro", nameLower }
        -- Index macro body words so "/castsequence Hearthstone" is reachable by "hearthstone".
        if body and body ~= "" then
            local cleanBody = body:gsub("#show[^\n]*", ""):gsub("/", " ")
            for word in cleanBody:gmatch("[%w']+") do
                local wl = slower(word)
                if #wl >= 3 then kw[#kw + 1] = wl end
            end
        end
        local tabIdx = isCharSpecific and 2 or 1
        local entry = {
            name = name,
            nameLower = nameLower,
            keywords = kw,
            category = "Macro",
            icon = iconTexture,
            macroIndex = macroIdx,
            macroBody = body,
            macroIsChar = isCharSpecific,
            buttonFrame = "MainMenuMicroButton",
            path = { _G["MACROS"] or "Macros", isCharSpecific and (_G["CHARACTER"] or "Character") or (_G["GENERAL"] or "General") },
            steps = {
                { buttonFrame = "MainMenuMicroButton" },
                { gameMenuText = _G["MACROS"] or "Macros" },
                { waitForFrame = "MacroFrame", tabIndex = tabIdx },
                { waitForFrame = "MacroFrame", macroIndex = macroIdx },
            },
        }
        uiSearchData[#uiSearchData + 1] = entry
    end

    for i = 1, numGlobal do
        injectMacro(i, false)
    end
    for i = 1, numPerChar do
        injectMacro(MAX_ACCOUNT + i, true)
    end
    return true
end

function Database:PopulateDynamicAbilities()
    RemoveEntriesByCategory("Ability")
    if self.ResetSearchCache then self:ResetSearchCache() end

    local SBOOK = C_SpellBook
    if not SBOOK or not SBOOK.GetSpellBookItemInfo
       or not SBOOK.GetNumSpellBookSkillLines or not SBOOK.GetSpellBookSkillLineInfo then
        return false
    end
    local BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
    local SPELL_TYPE = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    local FLYOUT_TYPE = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Flyout
    local GetFlyoutInfoFn = GetFlyoutInfo
    local GetFlyoutSlotInfoFn = GetFlyoutSlotInfo

    local seen = {}

    local function injectAbility(name, subName, spellID, iconID, lineName, lineSpecID, isOffSpec, isPassive, slotIndex)
        if not name or name == "" or not spellID then return end
        local displayName = (subName and subName ~= "") and (name .. " (" .. subName .. ")") or name
        local nameLower = slower(displayName)
        local kw = { slower(name), "ability", "abilities" }
        if lineName and lineName ~= "" then
            kw[#kw + 1] = slower(lineName)
        end
        uiSearchData[#uiSearchData + 1] = {
            name = displayName,
            nameLower = nameLower,
            keywords = kw,
            category = "Ability",
            treeName = lineName,
            isOffSpec = isOffSpec or false,
            isPassive = isPassive,
            isSpellbookOnly = isOffSpec or isPassive,
            icon = iconID,
            spellID = spellID,
            spellBookSpellID = spellID,
            spellBookIndex = slotIndex,
            spellBookBank = BANK,
            spellBookCategoryName = lineName,
            spellBookSpecID = lineSpecID,
            spellName = name,
            steps = { { spellID = spellID } },
        }
    end

    local numLines = SBOOK.GetNumSpellBookSkillLines() or 0
    for tab = 1, numLines do
        local lineInfo = SBOOK.GetSpellBookSkillLineInfo(tab)
        local offset = lineInfo and lineInfo.itemIndexOffset or 0
        local numSpells = lineInfo and lineInfo.numSpellBookItems or 0
        local lineName = lineInfo and lineInfo.name
        local lineSpecID = lineInfo and lineInfo.specID
        local offSpecID = lineInfo and lineInfo.offSpecID
        if (lineSpecID == nil or lineSpecID == 0)
            and offSpecID and offSpecID ~= 0 then
            lineSpecID = offSpecID
        end
        local isOffSpec = lineInfo and lineInfo.offSpecID
            and lineInfo.offSpecID ~= 0 or false
        for s = offset + 1, offset + numSpells do
            local itemInfo = SBOOK.GetSpellBookItemInfo(s, BANK)
            if itemInfo and itemInfo.name and itemInfo.name ~= "" and itemInfo.actionID then
                if (not SPELL_TYPE or itemInfo.itemType == SPELL_TYPE) then
                    local seenKey = itemInfo.actionID .. ":" .. tab .. ":" .. (lineSpecID or "")
                    if not seen[seenKey] then
                        seen[seenKey] = true
                        injectAbility(itemInfo.name, itemInfo.subName, itemInfo.actionID,
                            itemInfo.iconID, lineName, lineSpecID, isOffSpec, itemInfo.isPassive, s)
                    end
                elseif FLYOUT_TYPE and itemInfo.itemType == FLYOUT_TYPE
                       and GetFlyoutInfoFn and GetFlyoutSlotInfoFn then
                    -- The flyout itself isn't castable; inject its slot spells
                    -- and keep the flyout name as a keyword so "switch flight" works.
                    local flyoutID = itemInfo.actionID
                    local flyoutName, _, numSlots, isKnown = GetFlyoutInfoFn(flyoutID)
                    if isKnown and numSlots and numSlots > 0 then
                        local flyoutKw = flyoutName and flyoutName ~= ""
                            and slower(flyoutName) or nil
                        for slot = 1, numSlots do
                            local slotSpellID, _, slotIsKnown, slotSpellName = GetFlyoutSlotInfoFn(flyoutID, slot)
                            if slotIsKnown and slotSpellID and slotSpellName then
                                local slotIcon = C_Spell and C_Spell.GetSpellTexture
                                    and C_Spell.GetSpellTexture(slotSpellID)
                                local seenKey = tostring(slotSpellID) .. ":" .. tostring(tab)
                                    .. ":" .. tostring(lineSpecID or "")
                                if not seen[seenKey] then
                                    seen[seenKey] = true
                                    injectAbility(slotSpellName, nil, slotSpellID,
                                        slotIcon, lineName, lineSpecID, isOffSpec, false, s)
                                    if flyoutKw then
                                        local injected = uiSearchData[#uiSearchData]
                                        injected.keywords[#injected.keywords + 1] = flyoutKw
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return true
end

-- Dungeon/raid initialisms that pick non-leading letters (e.g. "BWL" from
-- blackWing) which the standard prefix scoring can't reach. Exposed so
-- MapSearch can inject the same aliases on dungeon-entrance POIs.
local INSTANCE_ABBRS = {
    ["blackwing lair"]    = {"bwl"},
    ["blackrock depths"]  = {"brd"},
    ["blackfathom deeps"] = {"bfd"},
    ["ragefire chasm"]    = {"rfc"},
    ["razorfen downs"]    = {"rfd"},
    ["razorfen kraul"]    = {"rfk"},
    ["scarlet monastery"] = {"sm"},
    ["scarlet halls"]     = {"sm"},
    ["shadowfang keep"]   = {"sfk"},
    ["zul'farrak"]        = {"zf"},
    ["wailing caverns"]   = {"wc"},
    ["icecrown citadel"]  = {"icc"},
    ["black temple"]      = {"bt"},
    ["naxxramas"]         = {"nax", "naxx"},
}
ns.INSTANCE_ABBRS = INSTANCE_ABBRS

-- Boss entries are the biggest single category in uiSearchData (~3 MB
-- on a fully-loaded EJ tier set). path is only read at render time for
-- entries currently in view; steps is only read on click. Stripping both
-- from the stored entry and hydrating lazily on first access (cached
-- back onto the entry afterward) drops the cold per-entry footprint
-- substantially while keeping data.path / data.steps callers unchanged.
-- Per-instance metatable cache. Every Boss entry in the same instance
-- shares everything except name/nameLower/encounterID/icon, so the
-- proto+lazy-step factory is built once per instance and reused. Cache
-- is wiped at the start of each Boss scan to handle EJ patches that
-- re-id an instance.
local bossInstanceMTCache = {}

local function ClearBossInstanceCache()
    wipe(bossInstanceMTCache)
end

local function GetBossInstanceMT(tier, isRaid, instID, instName)
    local cached = bossInstanceMTCache[instID]
    if cached then return cached end

    local instLower = slower(instName or "")
    local kw = { instLower, "boss", "bosses" }
    local abbrs = INSTANCE_ABBRS[instLower]
    if abbrs then
        for ai = 1, #abbrs do kw[#kw + 1] = abbrs[ai] end
    end

    local pathArr = { isRaid and "Raid" or "Dungeon", instName }
    local baseStep1 = { buttonFrame = "EJMicroButton" }
    local baseStep2 = { waitForFrame = "EncounterJournal", ejTier = tier, ejTabIsRaid = isRaid }
    local baseStep3 = { waitForFrame = "EncounterJournal", ejInstance = instName, ejInstanceID = instID }

    local proto = {
        category          = "Boss",
        isRaidBoss        = isRaid,
        ejTier            = tier,
        instanceID        = instID,
        instanceName      = instName,
        instanceNameLower = instLower,
        keywords          = kw,
        path              = pathArr,
    }
    local mt = {
        __index = function(t, k)
            if k == "steps" then
                local v = {
                    baseStep1, baseStep2, baseStep3,
                    { waitForFrame = "EncounterJournal", ejBoss = t.name, ejEncounterID = t.encounterID },
                }
                rawset(t, "steps", v)
                return v
            end
            return proto[k]
        end,
        __index_proto = proto,
    }
    bossInstanceMTCache[instID] = mt
    return mt
end

local function BuildBossEntry(tier, isRaid, instID, instName, encName, encID, icon)
    return setmetatable({
        name = encName,
        nameLower = slower(encName),
        encounterID = encID,
        icon = icon,
    }, GetBossInstanceMT(tier, isRaid, instID, instName))
end

local function AddBossEntry(tier, isRaid, instID, instName, encName, encID, getCreatureInfo)
    local icon
    if getCreatureInfo then
        local ok, _, _, _, _, iconImage = pcall(getCreatureInfo, 1, encID)
        if ok and iconImage and iconImage ~= 0 then
            icon = iconImage
        end
    end

    local entry = BuildBossEntry(tier, isRaid, instID, instName, encName, encID, icon)
    uiSearchData[#uiSearchData + 1] = entry
    return entry
end

local function AddBossCacheRow(cacheRows, tier, isRaid, instID, instName, encName, encID, icon)
    if not cacheRows then return end
    cacheRows[#cacheRows + 1] = {
        tier = tier,
        isRaid = isRaid and true or false,
        instanceID = instID,
        instanceName = instName,
        name = encName,
        encounterID = encID,
        icon = icon,
    }
end

local function PersistBossCache(cacheRows)
    local db = EasyFind and EasyFind.db
    if not db or not cacheRows then return end
    db.bossCache = {
        version = ns.BOSS_CACHE_VER,
        entries = cacheRows,
    }
    db.bossCacheVer = ns.BOSS_CACHE_VER
end

local function HydratePersistedBossCache()
    if bossCacheHydrated then return false end
    bossCacheHydrated = true

    local db = EasyFind and EasyFind.db
    local saved = db and db.bossCache
    if type(saved) ~= "table" or db.bossCacheVer ~= ns.BOSS_CACHE_VER then
        return false
    end
    local entries = saved.entries
    if type(entries) ~= "table" or #entries == 0 then return false end

    RemoveEntriesByCategory("Boss")
    ClearBossInstanceCache()

    local inserted = 0
    for i = 1, #entries do
        local raw = entries[i]
        if type(raw) == "table"
           and raw.name and raw.name ~= ""
           and raw.encounterID and raw.instanceID and raw.instanceName then
            uiSearchData[#uiSearchData + 1] = BuildBossEntry(
                raw.tier or 1,
                raw.isRaid == true,
                raw.instanceID,
                raw.instanceName,
                raw.name,
                raw.encounterID,
                raw.icon
            )
            inserted = inserted + 1
        end
    end
    if inserted == 0 then return false end

    if Database.ResetSearchCache then Database:ResetSearchCache() end
    return true
end

function Database:HydrateCachedBosses()
    local changed = HydratePersistedBossCache()
    if changed and self.MarkDynamicProviderLoaded then
        self:MarkDynamicProviderLoaded("bosses")
    end
    return changed
end

function Database:PopulateDynamicBosses()
    if HydratePersistedBossCache() then return true end

    RemoveEntriesByCategory("Boss")
    ClearBossInstanceCache()
    if self.ResetSearchCache then self:ResetSearchCache() end

    if not EncounterJournal then
        EncounterJournal_LoadUI()
    end

    local getNumTiers       = EJ("GetNumTiers") or _G.EJ_GetNumTiers
    local getCurrentTier    = EJ("GetCurrentTier") or _G.EJ_GetCurrentTier
    local selectTier        = EJ("SelectTier") or _G.EJ_SelectTier
    local getInstanceByIdx  = EJ("GetInstanceByIndex")
    local selectInstance    = EJ("SelectInstance")
    local getEncounterByIdx = EJ("GetEncounterInfoByIndex")
    local getCreatureInfo   = EJ("GetCreatureInfo") or _G.EJ_GetCreatureInfo
    if not getInstanceByIdx or not getEncounterByIdx or not selectTier then
        return
    end

    -- Suppress EJ UI events so opening the journal mid-scan can't fight us.
    local ejFrame = _G["EncounterJournal"]
    local savedOnEvent
    if ejFrame then
        savedOnEvent = ejFrame:GetScript("OnEvent")
        ejFrame:SetScript("OnEvent", nil)
    end

    local savedTier = getCurrentTier and getCurrentTier()
    local numTiers = (getNumTiers and getNumTiers()) or 10
    local cacheRows = {}

    for tier = 1, numTiers do
        selectTier(tier)
        for _, isRaid in ipairs({ false, true }) do
            local idx = 1
            while true do
                local instID, instName = getInstanceByIdx(idx, isRaid)
                if not instID then break end
                if selectInstance then selectInstance(instID) end

                local encIdx = 1
                while true do
                    local encName, _, encID = getEncounterByIdx(encIdx)
                    if not encName then break end

                    local entry = AddBossEntry(tier, isRaid, instID, instName, encName, encID, getCreatureInfo)
                    AddBossCacheRow(cacheRows, tier, isRaid, instID, instName, encName, encID, entry and entry.icon)
                    encIdx = encIdx + 1
                end

                idx = idx + 1
            end
        end
    end

    if savedTier and selectTier then selectTier(savedTier) end
    if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
    PersistBossCache(cacheRows)
    return true
end

function Database:PopulateDynamicBossesAsync(done)
    if not Utils.SafeAfter then
        self:PopulateDynamicBosses()
        done(true)
        return
    end
    if HydratePersistedBossCache() then
        done(true)
        return
    end

    RemoveEntriesByCategory("Boss")
    ClearBossInstanceCache()
    if self.ResetSearchCache then self:ResetSearchCache() end

    if not EncounterJournal then
        EncounterJournal_LoadUI()
    end

    local getNumTiers       = EJ("GetNumTiers") or _G.EJ_GetNumTiers
    local getCurrentTier    = EJ("GetCurrentTier") or _G.EJ_GetCurrentTier
    local selectTier        = EJ("SelectTier") or _G.EJ_SelectTier
    local getInstanceByIdx  = EJ("GetInstanceByIndex")
    local selectInstance    = EJ("SelectInstance")
    local getEncounterByIdx = EJ("GetEncounterInfoByIndex")
    local getCreatureInfo   = EJ("GetCreatureInfo") or _G.EJ_GetCreatureInfo
    if not getInstanceByIdx or not getEncounterByIdx or not selectTier then
        done(false)
        return
    end

    bossScanGeneration = bossScanGeneration + 1
    local myGen = bossScanGeneration
    local ejFrame = _G["EncounterJournal"]
    local savedOnEvent
    if ejFrame then
        savedOnEvent = ejFrame:GetScript("OnEvent")
        ejFrame:SetScript("OnEvent", nil)
    end

    local savedTier = getCurrentTier and getCurrentTier()
    local numTiers = (getNumTiers and getNumTiers()) or 10
    local state = { tier = 1, raidIdx = 1, instIdx = 1, encIdx = 1, instID = nil, instName = nil }
    local raidModes = { false, true }
    local budgetMs = 4
    local cacheRows = {}
    local emittedSinceRefresh = false

    local function finish(changed, err)
        if savedTier and selectTier then selectTier(savedTier) end
        if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
        if changed then PersistBossCache(cacheRows) end
        done(changed, err)
    end

    local function step()
        if myGen ~= bossScanGeneration then
            finish(false, "cancelled")
            return
        end

        local start = debugprofilestop and debugprofilestop() or 0
        while state.tier <= numTiers do
            selectTier(state.tier)
            local isRaid = raidModes[state.raidIdx]
            if isRaid == nil then
                state.tier = state.tier + 1
                state.raidIdx = 1
                state.instIdx = 1
                state.encIdx = 1
                state.instID = nil
                state.instName = nil
            elseif not state.instID then
                local instID, instName = getInstanceByIdx(state.instIdx, isRaid)
                if not instID then
                    state.raidIdx = state.raidIdx + 1
                    state.instIdx = 1
                    state.encIdx = 1
                else
                    state.instID = instID
                    state.instName = instName
                    state.encIdx = 1
                    if selectInstance then selectInstance(instID) end
                end
            else
                local processed = 0
                while processed < 10 do
                    local encName, _, encID = getEncounterByIdx(state.encIdx)
                    if not encName then
                        state.instIdx = state.instIdx + 1
                        state.instID = nil
                        state.instName = nil
                        state.encIdx = 1
                        break
                    end
                    local entry = AddBossEntry(state.tier, isRaid, state.instID, state.instName, encName, encID, getCreatureInfo)
                    AddBossCacheRow(cacheRows, state.tier, isRaid, state.instID, state.instName, encName, encID, entry and entry.icon)
                    emittedSinceRefresh = true
                    state.encIdx = state.encIdx + 1
                    processed = processed + 1
                end
            end

            if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                if emittedSinceRefresh and self.SchedulePartialSearchRefresh then
                    emittedSinceRefresh = false
                    self:SchedulePartialSearchRefresh(150)
                end
                Utils.SafeAfter(0, function()
                    local ok, err = xpcall(step, Utils.ErrorHandler)
                    if not ok then finish(false, err) end
                end)
                return
            end
        end

        finish(true)
    end

    Utils.SafeAfter(0, function()
        local ok, err = xpcall(step, Utils.ErrorHandler)
        if not ok then finish(false, err) end
    end)
end

function Database:PopulateDynamicTalents()
    RemoveEntriesByCategory("Talent")
    if self.ResetSearchCache then self:ResetSearchCache() end

    if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID
       or not C_Traits or not C_Traits.GetConfigInfo
       or not C_Traits.GetTreeNodes or not C_Traits.GetNodeInfo
       or not C_Traits.GetEntryInfo or not C_Traits.GetDefinitionInfo then
        return false
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return false end

    local cfgOk, configInfo = pcall(C_Traits.GetConfigInfo, configID)
    if not cfgOk or type(configInfo) ~= "table" or type(configInfo.treeIDs) ~= "table" then
        return false
    end

    -- Per-tree proto. Talents in the same tree share category, keywords,
    -- buttonFrame, path, talentConfigID, talentTreeID, and the first two
    -- navigation steps. With ~3 trees driving ~140 entries, each entry
    -- shrinks from 15 fields to 7.
    local treeMTByID = {}
    local SHARED_TALENT_KW = { "talent", "talents", "spec" }
    local function getTreeMT(treeID)
        local cached = treeMTByID[treeID]
        if cached then return cached end
        local baseStep1 = { buttonFrame = "PlayerSpellsMicroButton" }
        local baseStep2 = { waitForFrame = "PlayerSpellsFrame", tabIndex = 2 }
        local proto = {
            category       = "Talent",
            buttonFrame    = "PlayerSpellsMicroButton",
            keywords       = SHARED_TALENT_KW,
            keywordsLower  = SHARED_TALENT_KW,
            path           = { _G["TALENTS"] or "Talents" },
            talentConfigID = configID,
            talentTreeID   = treeID,
        }
        local mt = {
            __index = function(t, k)
                if k == "steps" then
                    local v = {
                        baseStep1, baseStep2,
                        { talentNodeID = t.talentNodeID, talentTreeID = treeID },
                    }
                    rawset(t, "steps", v)
                    return v
                end
                return proto[k]
            end,
            __index_proto = proto,
        }
        treeMTByID[treeID] = mt
        return mt
    end

    local seen = {}

    local function injectEntry(treeID, nodeID, entryID, isChoice, nodeInfo)
        local eok, entryInfo = pcall(C_Traits.GetEntryInfo, configID, entryID)
        if not eok or type(entryInfo) ~= "table" then return end
        local defID = entryInfo.definitionID
        if not defID then return end
        local dok, defInfo = pcall(C_Traits.GetDefinitionInfo, defID)
        if not dok or type(defInfo) ~= "table" then return end

        local spellID = defInfo.spellID or defInfo.overriddenSpellID
        local name = defInfo.overrideName
        local icon
        if spellID and C_Spell and C_Spell.GetSpellInfo then
            local sok, spellInfo = pcall(C_Spell.GetSpellInfo, spellID)
            if sok and spellInfo then
                if not name or name == "" then name = spellInfo.name end
                icon = spellInfo.iconID
            end
        end
        if not name or name == "" then return end
        if seen[name .. "|" .. (spellID or 0)] then return end
        seen[name .. "|" .. (spellID or 0)] = true

        -- Row renderer desaturates the icon for unspecced talents.
        local isAllocated
        if isChoice then
            isAllocated = nodeInfo.activeEntry and nodeInfo.activeEntry.entryID == entryID
        else
            isAllocated = (nodeInfo.activeRank or 0) > 0
        end

        uiSearchData[#uiSearchData + 1] = setmetatable({
            name = name,
            nameLower = slower(name),
            icon = icon,
            spellID = spellID,
            spellName = name,
            talentNodeID = nodeID,
            talentEntryID = entryID,
            talentIsChoice = isChoice or false,
            talentIsAllocated = isAllocated and true or false,
        }, getTreeMT(treeID))
    end

    for _, treeID in ipairs(configInfo.treeIDs) do
        local nok, nodeIDs = pcall(C_Traits.GetTreeNodes, treeID)
        if nok and type(nodeIDs) == "table" then
            for _, nodeID in ipairs(nodeIDs) do
                local niok, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
                if niok and type(nodeInfo) == "table" and type(nodeInfo.entryIDs) == "table" then
                    local isChoice = #nodeInfo.entryIDs > 1
                    for _, entryID in ipairs(nodeInfo.entryIDs) do
                        injectEntry(treeID, nodeID, entryID, isChoice, nodeInfo)
                    end
                end
            end
        end
    end
    return true
end

function Database:PopulateDynamicBags()
    local CONT = C_Container
    local getNumSlots = (CONT and CONT.GetContainerNumSlots) or GetContainerNumSlots
    local getItemInfo = (CONT and CONT.GetContainerItemInfo)  or GetContainerItemInfo
    if not getNumSlots or not getItemInfo then return false end

    local isRealEquipLoc = Utils.IsRealEquipLoc
    local getEquipLoc = Utils.GetItemEquipLoc
    local getQuality = C_Item and C_Item.GetItemQualityByID

    RemoveEntriesByCategory("Bag")
    if self.ResetSearchCache then self:ResetSearchCache() end

    local itemMap = {}
    local order = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots = getNumSlots(bag) or 0
        for slot = 1, slots do
            local raw = getItemInfo(bag, slot)
            if raw then
                local itemID, texture, link, count
                if type(raw) == "table" then
                    itemID, texture, link, count = raw.itemID, raw.iconFileID, raw.hyperlink, raw.stackCount
                else
                    -- Classic-era multi-return layout.
                    texture = raw
                    local _
                    _, count, _, _, _, _, link, _, _, itemID = getItemInfo(bag, slot)
                end
                if itemID then
                    local entry = itemMap[itemID]
                    if not entry then
                        entry = { texture = texture, link = link, totalCount = 0, locations = {} }
                        itemMap[itemID] = entry
                        order[#order + 1] = itemID
                    end
                    entry.totalCount = entry.totalCount + (count or 1)
                    entry.locations[#entry.locations + 1] = { bag = bag, slot = slot }
                end
            end
        end
    end

    for _, itemID in ipairs(order) do
        local info = itemMap[itemID]
        local name = info.link and info.link:match("%[(.-)%]") or (GetItemInfo and GetItemInfo(itemID)) or ((_G["ITEM"] or "Item") .. " " .. itemID)
        local quality
        if getQuality then
            quality = getQuality(itemID)
        elseif GetItemInfo then
            quality = select(3, GetItemInfo(itemID))
        end
        local equipLoc = getEquipLoc(itemID)
        local isEquippable = isRealEquipLoc(equipLoc)
        local first = info.locations[1]
        local bagBtn = first.bag == 0 and "MainMenuBarBackpackButton"
            or ("CharacterBag" .. (first.bag - 1) .. "Slot")
        local nameLower = slower(name)
        local kw = { "bag", "item", "inventory", nameLower }
        uiSearchData[#uiSearchData + 1] = {
            name = name,
            nameLower = nameLower,
            keywords = kw,
            category = "Bag",
            icon = info.texture,
            itemID = itemID,
            quality = quality,
            equipLoc = equipLoc,
            isEquippable = isEquippable,
            bagID = first.bag,
            bagSlot = first.slot,
            bagItemLink = info.link,
            bagCount = info.totalCount,
            bagLocations = info.locations,
            buttonFrame = bagBtn,
            steps = {
                { buttonFrame = bagBtn },
                { containerBag = first.bag, containerSlot = first.slot, allLocations = info.locations },
            },
        }
    end
    return true
end

function Database:_ResetDynamicProviderCaches()
    wipe(knownCurrencyIDs)
    wipe(lootEntries)
    wipe(lootItemCache)
    wipe(lootSpecsScanned)
    wipe(lootEncounterMTCache)
    wipe(pendingStatEnrichment)
    lootItemCacheHydrated = false
    lootSearchDataHydrated = false
    bossCacheHydrated = false
    statisticCacheHydrated = false
end

function Database:_ResetHeavyProviderCaches()
    wipe(lootEntries)
    wipe(lootItemCache)
    wipe(lootSpecsScanned)
    wipe(lootEncounterMTCache)
    wipe(pendingStatEnrichment)
    lootItemCacheHydrated = false
    lootSearchDataHydrated = false
    bossCacheHydrated = false
    statisticCacheHydrated = false
end

-- Aliases the API category names don't carry. Words from the name itself
-- are auto-tokenized; only put acronyms and shortenings here.
local CATEGORY_KEYWORD_OVERLAY = {
    ["rated battlegrounds"]      = {"rbg", "rated bg"},
    ["alterac valley"]           = {"av"},
    ["arathi basin"]             = {"ab"},
    ["eye of the storm"]         = {"eots"},
    ["warsong gulch"]            = {"wsg"},
    ["wintergrasp"]              = {"wg"},
    ["strand of the ancients"]   = {"sota"},
    ["isle of conquest"]         = {"ioc"},
    ["temple of kotmogu"]        = {"tok"},
    ["silvershard mines"]        = {"ssm"},
    ["the burning crusade"]      = {"tbc", "burning crusade"},
    ["wrath of the lich king"]   = {"wotlk", "wrath", "lich king"},
    ["mists of pandaria"]        = {"mop", "pandaria"},
    ["warlords of draenor"]      = {"wod", "draenor"},
    ["battle for azeroth"]       = {"bfa"},
    ["shadowlands"]              = {"sl"},
    ["dragonflight"]             = {"df"},
    ["the war within"]           = {"tww", "war within"},
    ["feats of strength"]        = {"fos"},
    ["player vs. player"]        = {"pvp"},
    ["dungeons & raids"]         = {"dungeons", "raids"},
}

local CATEGORY_FLAG_GUILD = 0x00000001
local RefreshStatisticsCategoryIDs
local IsInStatisticsCategoryTree
local MarkID
local HasID

local function buildCategoryEntry(opts)
    local nameLower = slower(opts.categoryName)
    local kw = { nameLower }
    local words = SearchText.Tokenize(nameLower)
    for i = 1, #words do
        local w = words[i]
        if #w > 2 and w ~= nameLower then kw[#kw + 1] = w end
    end
    local overlay = CATEGORY_KEYWORD_OVERLAY[nameLower]
    if overlay then
        for i = 1, #overlay do kw[#kw + 1] = overlay[i] end
    end
    local entry = {
        name = opts.displayName,
        keywords = kw,
        category = opts.category,
        buttonFrame = "AchievementMicroButton",
        path = opts.path,
        steps = opts.steps,
        isGuildAchievement = opts.isGuildAchievement and true or nil,
    }
    entry.nameLower = slower(opts.displayName)
    entry.keywordsLower = {}
    for j = 1, #kw do entry.keywordsLower[j] = slower(kw[j]) end
    return entry
end

function Database:PopulateDynamicAchievements()
    if not GetCategoryList or not GetCategoryInfo then return false end
    -- Midnight's GetCategoryList can include statistic tracker IDs. Filter
    -- them out here; the async Statistics pass refreshes us later with the
    -- full row-ID set as a backup.

    RemoveEntriesByCategory("Achievement Category")

    local categories = GetCategoryList()
    if not categories then return false end

    local statsCatSet = RefreshStatisticsCategoryIDs()

    local catMap = {}
    for i = 1, #categories do
        local catID = categories[i]
        if not HasID(statsCatSet, catID) and not HasID(Database.statisticIDs, catID) then
            local name, parentID, flags = GetCategoryInfo(catID)
            if name and name ~= ""
               and not IsInStatisticsCategoryTree(catID, parentID)
               and not Database:IsStatisticAchievement(catID) then
                catMap[catID] = {
                    id = catID, name = name, parentID = parentID,
                    isGuild = band(flags or 0, CATEGORY_FLAG_GUILD) == 1,
                    children = {},
                }
            end
        end
    end

    local roots = {}
    for _, cat in pairs(catMap) do
        local parent = cat.parentID and cat.parentID ~= -1 and catMap[cat.parentID]
        if parent then
            parent.children[#parent.children + 1] = cat
        else
            roots[#roots + 1] = cat
        end
    end

    local function emit(cat, parentChain, isGuildBranch)
        local prefix = isGuildBranch and "Guild: " or ""
        local pathRoot = isGuildBranch
            and { _G["ACHIEVEMENTS"] or "Achievements", _G["GUILD_ACHIEVEMENTS_TITLE"] or "Guild Achievements" }
            or { _G["ACHIEVEMENTS"] or "Achievements", L["UITREE_PERSONAL_ACHIEVEMENTS"] }

        local steps = {
            { buttonFrame = "AchievementMicroButton" },
            { waitForFrame = "AchievementFrame", tabIndex = isGuildBranch and 2 or 1 },
        }
        local path = {}
        for i = 1, #pathRoot do path[i] = pathRoot[i] end
        for i = 1, #parentChain do
            local parent = parentChain[i]
            local pn = parent.name
            steps[#steps + 1] = {
                waitForFrame = "AchievementFrame",
                achievementCategory = pn,
                achievementCategoryID = parent.id,
            }
            path[#path + 1] = pn
        end
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementCategory = cat.name,
            achievementCategoryID = cat.id,
        }

        uiSearchData[#uiSearchData + 1] = buildCategoryEntry({
            displayName  = prefix .. cat.name,
            categoryName = cat.name,
            category     = "Achievement Category",
            path         = path,
            steps        = steps,
            isGuildAchievement = isGuildBranch,
        })

        if #cat.children > 0 then
            local nextChain = {}
            for i = 1, #parentChain do nextChain[i] = parentChain[i] end
            nextChain[#nextChain + 1] = cat
            for i = 1, #cat.children do emit(cat.children[i], nextChain, isGuildBranch) end
        end
    end

    for i = 1, #roots do emit(roots[i], {}, roots[i].isGuild) end
    return true
end

-- statisticIDs: achievement IDs that are statistic trackers. Populated by
-- PopulateDynamicStatistics so consumers that enumerate achievements via
-- Blizzard APIs can filter trackers out (they show under Statistics, not as
-- duplicate Achievement rows).
Database.statisticIDs = Database.statisticIDs or {}
Database.statisticsCategoryIDs = Database.statisticsCategoryIDs or {}
Database.statisticsCategoryChildIDs = Database.statisticsCategoryChildIDs or {}
Database.statisticsComplete = Database.statisticsComplete or false
Database.statisticsVersion = Database.statisticsVersion or 0

MarkID = function(set, id)
    if id == nil then return end
    set[id] = true
    local numericID = tonumber(id)
    if numericID then set[numericID] = true end
end

HasID = function(set, id)
    if id == nil then return false end
    if set[id] == true then return true end
    local numericID = tonumber(id)
    return numericID and set[numericID] == true or false
end

RefreshStatisticsCategoryIDs = function(statCats)
    wipe(Database.statisticsCategoryIDs)
    wipe(Database.statisticsCategoryChildIDs)
    if not statCats and GetStatisticsCategoryList then
        statCats = GetStatisticsCategoryList()
    end
    if statCats then
        for i = 1, #statCats do
            MarkID(Database.statisticsCategoryIDs, statCats[i])
        end
    end
    return Database.statisticsCategoryIDs
end

IsInStatisticsCategoryTree = function(categoryID, parentID)
    if not categoryID then return false end
    local statCats = Database.statisticsCategoryIDs
    if HasID(statCats, categoryID) then return true end
    if HasID(statCats, parentID) then return true end

    local cached = Database.statisticsCategoryChildIDs[categoryID]
    if cached ~= nil then return cached end

    local current = parentID
    local seen
    while current and current ~= -1 do
        if HasID(statCats, current) then
            Database.statisticsCategoryChildIDs[categoryID] = true
            return true
        end
        if not GetCategoryInfo then break end
        seen = seen or {}
        if seen[current] then break end
        seen[current] = true
        local _, nextParentID = GetCategoryInfo(current)
        current = nextParentID
    end

    Database.statisticsCategoryChildIDs[categoryID] = false
    return false
end

function Database:IsStatisticAchievement(achievementID)
    if not achievementID then return false end
    if HasID(Database.statisticIDs, achievementID) then return true end
    if not GetCategoryInfo then return false end
    if not next(Database.statisticsCategoryIDs) then RefreshStatisticsCategoryIDs() end
    local getAchievementCategory = _G["GetAchievementCategory"]
    if getAchievementCategory then
        local categoryID = getAchievementCategory(achievementID)
        if IsInStatisticsCategoryTree(categoryID, nil) then return true end
        local categoryParentID
        if categoryID then
            local _
            _, categoryParentID = GetCategoryInfo(categoryID)
        end
        if IsInStatisticsCategoryTree(categoryID, categoryParentID) then return true end
    end
    local _, parentID = GetCategoryInfo(achievementID)
    return IsInStatisticsCategoryTree(achievementID, parentID)
end

-- Bumping during a scan causes the in-flight time-sliced loop to bail.
local statsScanGeneration = 0
local STAT_KEYWORDS_EMPTY = {}
local statisticMTCache = {}

local function CopyStatisticChain(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for i = 1, #src do
        local cat = src[i]
        if type(cat) == "table" then
            out[i] = { id = cat.id, name = cat.name }
        end
    end
    return out
end

local function StatisticChainKey(chain)
    local key = ""
    if type(chain) ~= "table" then return key end
    for i = 1, #chain do
        local cat = chain[i]
        key = key .. "\30" .. tostring(cat and cat.id or "") .. "\31" .. tostring(cat and cat.name or "")
    end
    return key
end

local function GetStatisticMT(path, categoryChain)
    local key = StatisticChainKey(categoryChain)
    local cached = statisticMTCache[key]
    if cached then return cached end

    local stepsPrefix = {
        { buttonFrame = "AchievementMicroButton" },
        { waitForFrame = "AchievementFrame", tabIndex = 3 },
    }
    for i = 1, #categoryChain do
        local cat = categoryChain[i]
        stepsPrefix[#stepsPrefix + 1] = {
            waitForFrame = "AchievementFrame",
            statisticsCategory = cat.name,
            statisticsCategoryID = cat.id,
        }
    end

    local proto = {
        category      = "Statistic",
        buttonFrame   = "AchievementMicroButton",
        keywords      = STAT_KEYWORDS_EMPTY,
        keywordsLower = STAT_KEYWORDS_EMPTY,
        path          = path,
    }
    local prefixLen = #stepsPrefix
    local mt = {
        __index = function(t, k)
            if k == "steps" then
                local steps = {}
                for s = 1, prefixLen do steps[s] = stepsPrefix[s] end
                steps[prefixLen + 1] = {
                    waitForFrame = "AchievementFrame",
                    statisticID = t.statisticID,
                    statisticName = t.name,
                }
                rawset(t, "steps", steps)
                return steps
            end
            return proto[k]
        end,
        __index_proto = proto,
    }
    statisticMTCache[key] = mt
    return mt
end

local function BuildStatisticEntry(name, id, path, categoryChain)
    categoryChain = categoryChain or {}
    path = path or { _G["ACHIEVEMENTS"] or "Achievements", _G["STATISTICS"] or "Statistics" }
    return setmetatable({
        name = name,
        nameLower = slower(name),
        statisticID = id,
        statisticCategoryChain = categoryChain,
    }, GetStatisticMT(path, categoryChain))
end

local function AddStatisticCacheRow(cacheRows, id, name, path, categoryChain)
    if not cacheRows then return end
    cacheRows[#cacheRows + 1] = {
        id = id,
        name = name,
        path = CopyArray(path),
        categoryChain = CopyStatisticChain(categoryChain),
    }
end

local function PersistStatisticsCache(cacheRows, categories)
    local db = EasyFind and EasyFind.db
    if not db or not cacheRows then return end
    db.statisticCache = {
        version = ns.STATISTIC_CACHE_VER,
        categoryIDs = CopyArray(categories),
        entries = cacheRows,
    }
    db.statisticCacheVer = ns.STATISTIC_CACHE_VER
end

local function HydratePersistedStatisticsCache()
    if statisticCacheHydrated then return false end
    statisticCacheHydrated = true

    local db = EasyFind and EasyFind.db
    local saved = db and db.statisticCache
    if type(saved) ~= "table" or db.statisticCacheVer ~= ns.STATISTIC_CACHE_VER then
        return false
    end
    local entries = saved.entries
    if type(entries) ~= "table" or #entries == 0 then return false end

    RemoveEntriesByCategory("Statistic")
    wipe(Database.statisticIDs)
    Database.statisticsComplete = true
    RefreshStatisticsCategoryIDs(saved.categoryIDs)

    local inserted = 0
    for i = 1, #entries do
        local raw = entries[i]
        if type(raw) == "table" and raw.id and raw.name and raw.name ~= "" then
            local path = CopyArray(raw.path)
            local chain = CopyStatisticChain(raw.categoryChain)
            uiSearchData[#uiSearchData + 1] = BuildStatisticEntry(raw.name, raw.id, path, chain)
            MarkID(Database.statisticIDs, raw.id)
            inserted = inserted + 1
        end
    end
    if inserted == 0 then return false end

    Database.statisticsVersion = Database.statisticsVersion + 1
    if Database.ResetSearchCache then Database:ResetSearchCache() end
    return true
end

function Database:HydrateCachedStatistics()
    local changed = HydratePersistedStatisticsCache()
    if changed and self.MarkDynamicProviderLoaded then
        self:MarkDynamicProviderLoaded("statistics")
    end
    return changed
end

function Database:PopulateDynamicStatisticsAsync(done)
    if not GetStatisticsCategoryList or not GetCategoryInfo
       or not Utils.SafeAfter then
        local ok = self:PopulateDynamicStatistics()
        done(ok)
        return
    end
    if HydratePersistedStatisticsCache() then
        done(true)
        return
    end

    RemoveEntriesByCategory("Statistic")
    wipe(Database.statisticIDs)
    Database.statisticsComplete = false
    statsScanGeneration = statsScanGeneration + 1
    local myGen = statsScanGeneration

    local categories = GetStatisticsCategoryList()
    if not categories then done(false); return end
    RefreshStatisticsCategoryIDs(categories)

    local catMap = {}
    for i = 1, #categories do
        local catID = categories[i]
        local name, parentID = GetCategoryInfo(catID)
        if name and name ~= "" then
            catMap[catID] = { id = catID, name = name, parentID = parentID, children = {} }
        end
    end

    local roots = {}
    for _, cat in pairs(catMap) do
        local parent = cat.parentID and cat.parentID ~= -1 and catMap[cat.parentID]
        if parent then
            parent.children[#parent.children + 1] = cat
        else
            roots[#roots + 1] = cat
        end
    end

    local queue = {}

    local function enqueueCategory(cat, parentChain)
        local path = { _G["ACHIEVEMENTS"] or "Achievements", _G["STATISTICS"] or "Statistics" }
        local categoryChain = {}
        for i = 1, #parentChain do
            local parent = parentChain[i]
            categoryChain[#categoryChain + 1] = { id = parent.id, name = parent.name }
            path[#path + 1] = parent.name
        end
        categoryChain[#categoryChain + 1] = { id = cat.id, name = cat.name }
        path[#path + 1] = cat.name

        if GetCategoryNumAchievements then
            local total = GetCategoryNumAchievements(cat.id) or 0
            if total == 0 and #cat.children == 0 then
                total = GetCategoryNumAchievements(cat.id, true) or 0
            end
            for i = 1, total do
                queue[#queue + 1] = {
                    catID = cat.id, rowIndex = i,
                    path = path,
                    categoryChain = categoryChain,
                }
            end
        end

        if #cat.children > 0 then
            local nextChain = {}
            for i = 1, #parentChain do nextChain[i] = parentChain[i] end
            nextChain[#nextChain + 1] = cat
            for i = 1, #cat.children do enqueueCategory(cat.children[i], nextChain) end
        end
    end
    for i = 1, #roots do enqueueCategory(roots[i], {}) end

    -- Keywords skipped; the unique stat name is enough for the scorer.
    local seenStatisticIDs = {}
    local cacheRows = {}
    local function processRow(item)
        if not GetAchievementInfo then return end
        local id, title = GetAchievementInfo(item.catID, item.rowIndex)
        if not (id and title and title ~= "") then return end
        if HasID(seenStatisticIDs, id) then
            MarkID(Database.statisticIDs, id)
            return
        end
        MarkID(seenStatisticIDs, id)
        MarkID(Database.statisticIDs, id)
        local entry = BuildStatisticEntry(title, id, item.path, item.categoryChain)
        uiSearchData[#uiSearchData + 1] = entry
        AddStatisticCacheRow(cacheRows, id, title, item.path, item.categoryChain)
        return true
    end

    -- Wider budget for the post-login scan: 2ms left stats unsearchable for seconds.
    local BUDGET_MS = 6
    local cursor = 1
    local emittedSinceRefresh = 0
    local function step()
        if myGen ~= statsScanGeneration then
            done(false, "cancelled")
            return
        end
        local startMs = debugprofilestop and debugprofilestop() or 0
        while cursor <= #queue do
            if processRow(queue[cursor]) then
                emittedSinceRefresh = emittedSinceRefresh + 1
            end
            cursor = cursor + 1
            if debugprofilestop and (debugprofilestop() - startMs) > BUDGET_MS then
                if emittedSinceRefresh > 0 and Database.SchedulePartialSearchRefresh then
                    emittedSinceRefresh = 0
                    Database:SchedulePartialSearchRefresh(150)
                end
                Utils.SafeAfter(0, step)
                return
            end
        end
        -- Refresh achievements so the full stat row-ID set is available
        -- as a backup to the live category-tree filter.
        Database.statisticsComplete = true
        Database.statisticsVersion = Database.statisticsVersion + 1
        PersistStatisticsCache(cacheRows, categories)
        if Database.RefreshDynamicCategory then
            Database:RefreshDynamicCategory("achievements")
        end
        done(true)
    end
    step()
end

function Database:PopulateDynamicStatistics()
    if not GetStatisticsCategoryList or not GetCategoryInfo then return false end
    if HydratePersistedStatisticsCache() then return true end

    RemoveEntriesByCategory("Statistic")
    wipe(Database.statisticIDs)
    Database.statisticsComplete = false
    statsScanGeneration = statsScanGeneration + 1

    local categories = GetStatisticsCategoryList()
    if not categories then return false end
    RefreshStatisticsCategoryIDs(categories)

    local catMap = {}
    for i = 1, #categories do
        local catID = categories[i]
        local name, parentID = GetCategoryInfo(catID)
        if name and name ~= "" then
            catMap[catID] = {
                id = catID, name = name, parentID = parentID, children = {},
            }
        end
    end

    local roots = {}
    for _, cat in pairs(catMap) do
        local parent = cat.parentID and cat.parentID ~= -1 and catMap[cat.parentID]
        if parent then
            parent.children[#parent.children + 1] = cat
        else
            roots[#roots + 1] = cat
        end
    end

    -- Sync fallback path when timers are unavailable.
    local seenStatisticIDs = {}
    local cacheRows = {}
    local function emit(cat, parentChain)
        local pathBase = { _G["ACHIEVEMENTS"] or "Achievements", _G["STATISTICS"] or "Statistics" }
        local categoryChain = {}
        for i = 1, #parentChain do
            local parent = parentChain[i]
            local pn = parent.name
            categoryChain[#categoryChain + 1] = { id = parent.id, name = pn }
            pathBase[#pathBase + 1] = pn
        end
        categoryChain[#categoryChain + 1] = { id = cat.id, name = cat.name }
        pathBase[#pathBase + 1] = cat.name

        if GetCategoryNumAchievements and GetAchievementInfo then
            local total = GetCategoryNumAchievements(cat.id)
            if (total or 0) == 0 and #cat.children == 0 then
                total = GetCategoryNumAchievements(cat.id, true)
            end
            for i = 1, (total or 0) do
                local id, title = GetAchievementInfo(cat.id, i)
                if id and title and title ~= "" then
                    if HasID(seenStatisticIDs, id) then
                        MarkID(Database.statisticIDs, id)
                    else
                        MarkID(seenStatisticIDs, id)
                        MarkID(Database.statisticIDs, id)
                        local path = {}
                        for p = 1, #pathBase do path[p] = pathBase[p] end
                        local entry = BuildStatisticEntry(title, id, path, categoryChain)
                        uiSearchData[#uiSearchData + 1] = entry
                        AddStatisticCacheRow(cacheRows, id, title, path, categoryChain)
                    end
                end
            end
        end

        if #cat.children > 0 then
            local nextChain = {}
            for i = 1, #parentChain do nextChain[i] = parentChain[i] end
            nextChain[#nextChain + 1] = cat
            for i = 1, #cat.children do emit(cat.children[i], nextChain) end
        end
    end

    for i = 1, #roots do emit(roots[i], {}) end
    Database.statisticsComplete = true
    Database.statisticsVersion = Database.statisticsVersion + 1
    PersistStatisticsCache(cacheRows, categories)
    return true
end

-- Children inherit buttonFrame/category and accumulate path + steps.
-- The five shared fields (category, buttonFrame, path, steps, keywords)
-- live on a per-(category, buttonFrame, path, steps, keywords) proto MT
-- so each entry only stores its unique fields (name + optional icon/etc).
-- Most siblings collapse to the same MT, dropping hash slots from 6-7
-- to 1-2 per entry. With Lua's power-of-2 hash sizing that's cap=8 to
-- cap=2 (~192 bytes per entry × ~500 static entries).
local flattenMTCache = {}
local function GetFlattenMT(category, buttonFrame, path, steps, keywords)
    local key = (category or "") .. "\31"
             .. (buttonFrame or "") .. "\31"
             .. tostring(path) .. "\31"
             .. tostring(steps) .. "\31"
             .. tostring(keywords)
    local cached = flattenMTCache[key]
    if cached then return cached end
    local proto = {
        category    = category,
        buttonFrame = buttonFrame,
        path        = path,
        steps       = steps,
        keywords    = keywords,
    }
    local mt = { __index = proto }
    flattenMTCache[key] = mt
    return mt
end

function Database:FlattenTree(tree, parentPath, parentSteps, parentButtonFrame, parentCategory, parentIsPvP, parentIsPvE)
    parentPath = parentPath or {}
    parentSteps = parentSteps or {}

    for _, node in ipairs(tree) do
        local myButtonFrame = node.buttonFrame or parentButtonFrame
        local myCategory = node.category or parentCategory
        -- isPvP/isPvE propagate from any ancestor node that set the flag.
        -- Defining the flag at the tree level avoids the previous post-
        -- flatten loop that string-matched path elements ("Group Finder",
        -- "Dungeons & Raids", "Player vs. Player") and broke on non-
        -- English clients.
        local myIsPvP = node.isPvP or parentIsPvP or nil
        local myIsPvE = node.isPvE or parentIsPvE or nil

        -- Reuse parent array when node adds nothing.
        local mySteps
        if node.steps then
            mySteps = {}
            for _, s in ipairs(parentSteps) do mySteps[#mySteps + 1] = s end
            for _, s in ipairs(node.steps) do mySteps[#mySteps + 1] = s end
        else
            mySteps = parentSteps
        end

        local myKeywords = node.keywords or EMPTY_KEYWORDS
        local mt = GetFlattenMT(myCategory, myButtonFrame, parentPath, mySteps, myKeywords)
        local entry = setmetatable({ name = node.name }, mt)
        if node.icon then entry.icon = node.icon end
        if node.available then entry.available = node.available end
        if node.canQueue then entry.canQueue = true end
        if node.slashCommand then entry.slashCommand = node.slashCommand end
        if myIsPvP then entry.isPvP = true end
        if myIsPvE then entry.isPvE = true end

        uiSearchData[#uiSearchData + 1] = entry

        if node.children then
            local childPath = {}
            for i = 1, #parentPath do childPath[i] = parentPath[i] end
            childPath[#childPath + 1] = node.name
            self:FlattenTree(node.children, childPath, mySteps, myButtonFrame, myCategory, myIsPvP, myIsPvE)
        end
    end
end

local GROUP_FINDER_SUBCATEGORY_ICONS = {
    dungeonFinder = { icon = 133076, frame = "GroupFinderFrameGroupButton1" },
    raidFinder = { icon = 341547, frame = "GroupFinderFrameGroupButton2" },
    premadeGroups = { icon = 464820, frame = "GroupFinderFrameGroupButton3" },
    pvpQuickMatch = { icon = 236396, frame = "PVPQueueFrame.CategoryButton1" },
    pvpRated = { icon = 236368, frame = "PVPQueueFrame.CategoryButton2" },
    pvpPremade = { icon = 464820, frame = "PVPQueueFrame.CategoryButton3" },
    pvpTraining = { icon = 236179, frame = "PVPQueueFrame.CategoryButton4" },
}

local function EntryIsUnderGroupFinder(item)
    if item and item.buttonFrame == "LFDMicroButton" then return true end
    local steps = item and item.steps
    if not steps then return false end
    for i = 1, #steps do
        if steps[i] and steps[i].buttonFrame == "LFDMicroButton" then return true end
    end
    return false
end

local function GetGroupFinderSubcategoryIcon(item)
    local steps = item and item.steps
    if not steps then return nil end
    for i = 1, #steps do
        local step = steps[i]
        if step then
            if step.pvpSideTabIndex == 1 then return GROUP_FINDER_SUBCATEGORY_ICONS.pvpQuickMatch end
            if step.pvpSideTabIndex == 2 then return GROUP_FINDER_SUBCATEGORY_ICONS.pvpRated end
            if step.pvpSideTabIndex == 3 then return GROUP_FINDER_SUBCATEGORY_ICONS.pvpPremade end
            if step.pvpSideTabIndex == 4 then return GROUP_FINDER_SUBCATEGORY_ICONS.pvpTraining end
            if step.sideTabIndex == 1 then return GROUP_FINDER_SUBCATEGORY_ICONS.dungeonFinder end
            if step.sideTabIndex == 2 then return GROUP_FINDER_SUBCATEGORY_ICONS.raidFinder end
            if step.sideTabIndex == 3 then return GROUP_FINDER_SUBCATEGORY_ICONS.premadeGroups end
        end
    end
    return nil
end

local function ApplyGroupFinderSubcategoryIcon(item)
    if item.specificIcon or item.specificIconFrame or not EntryIsUnderGroupFinder(item) then return end
    local iconDef = GetGroupFinderSubcategoryIcon(item)
    if iconDef then
        item.specificIcon = iconDef.icon
        item.specificIconFrame = iconDef.frame
    end
end

function Database:BuildUIDatabase()
    -- Each node: { name, keywords, [category], [buttonFrame], [steps], [children] }
    -- category and buttonFrame inherit from parent; steps prepends parent steps;
    -- path is auto-built from ancestor names.
    local uiTree = {

        {
            name = _G["CHARACTER_BUTTON"] or "Character Info",
            keywords = {"character", "char", "attributes"},
            category = "Menu Bar",
            buttonFrame = "CharacterMicroButton",
            steps = {{ buttonFrame = "CharacterMicroButton" }},
            children = {
                {
                    name = _G["PAPERDOLL_SIDEBAR_STATS"] or "Character Stats",
                    keywords = {"character stats", "character sheet", "paperdoll", "equipment", "gear stats", "item level"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 1 },
                    },
                },
                {
                    name = _G["PAPERDOLL_SIDEBAR_TITLES"] or _G["TITLES"] or "Titles",
                    keywords = {"titles", "title", "name title"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 2 },
                    },
                },
                {
                    name = _G["EQUIPMENT_MANAGER"] or "Equipment Manager",
                    keywords = {"equipment manager", "gear sets", "equipment sets", "outfitter", "save gear", "load gear", "gear manager"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 3 },
                    },
                },
                {
                    name = _G["REPUTATION"] or "Reputation",
                    keywords = {"reputation", "rep", "faction", "factions", "standing", "renown"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 2 },
                    },
                },
                {
                    name = _G["CURRENCY"] or "Currency",
                    keywords = {"currency", "currencies", "tokens", "money"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 3 },
                    },
                },
            },
        },

        {
            name = _G["TRADE_SKILLS"] or _G["PROFESSIONS_BUTTON"] or "Professions",
            keywords = {"professions", "profession", "crafting", "trade skills", "skills"},
            category = "Menu Bar",
            buttonFrame = "ProfessionMicroButton",
            steps = {{ buttonFrame = "ProfessionMicroButton" }},
        },

        {
            name = _G["PLAYERSPELLS_BUTTON"] or "Talents & Spellbook",
            keywords = {"talents and spellbook", "class abilities"},
            category = "Menu Bar",
            buttonFrame = "PlayerSpellsMicroButton",
            steps = {{ buttonFrame = "PlayerSpellsMicroButton" }},
            children = {
                {
                    name = _G["SPECIALIZATION"] or "Specialization",
                    keywords = {"specialization", "spec", "class spec", "change spec", "switch spec"},
                    category = "Talents",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 1 }},
                },
                {
                    name = _G["TALENTS"] or "Talents",
                    keywords = {"talent tree", "talent points", "class talents", "hero talents", "talents"},
                    category = "Talents",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 2 }},
                    children = {
                        {
                            name = _G["TALENT_FRAME_DROP_DOWN_PVP_TALENTS"] or _G["PVP_TALENTS"] or "PvP Talents",
                            isPvP = true,
                            keywords = {"pvp talents", "pvp abilities", "battleground talents", "pvp"},
                            steps = {{ waitForFrame = "PlayerSpellsFrame", regionFrames = { "PlayerSpellsFrame.TalentsFrame.PvPTalentSlotTray" } }},
                        },
                        {
                            name = _G["WAR_MODE"] or _G["PVP_LABEL_WAR_MODE"] or "War Mode",
                            isPvP = true,
                            keywords = {"war mode", "warmode", "pvp toggle", "world pvp", "pvp on", "pvp off", "pvp"},
                            steps = {{ waitForFrame = "PlayerSpellsFrame", regionFrames = { "PlayerSpellsFrame.TalentsFrame.WarmodeButton" } }},
                        },
                    },
                },
                {
                    name = _G["SPELLBOOK"] or "Spellbook",
                    keywords = {"spellbook", "spells", "abilities", "skills", "spell book"},
                    category = "Menu Bar",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = _G["ACHIEVEMENTS"] or "Achievements",
            keywords = {"achievement", "achievements", "achieve", "points"},
            category = "Menu Bar",
            buttonFrame = "AchievementMicroButton",
            steps = {{ buttonFrame = "AchievementMicroButton" }},
            children = {
                {
                    name = _G["STATISTICS"] or "Statistics",
                    keywords = {"statistics", "stats tab", "player statistics"},
                    category = "Statistics",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = _G["QUESTLOG_BUTTON"] or _G["QUEST_LOG"] or "Quest Log",
            keywords = {"quest", "quests", "objectives", "log", "journal"},
            category = "Menu Bar",
            buttonFrame = "QuestLogMicroButton",
            steps = {{ buttonFrame = "QuestLogMicroButton" }},
        },

        {
            name = _G["HOUSING_DASHBOARD_FRAMETITLE"] or _G["HOUSING_MICRO_BUTTON"] or "Housing Dashboard",
            keywords = {"housing", "house", "home", "dashboard", "player housing"},
            category = "Menu Bar",
            buttonFrame = "HousingMicroButton",
            steps = {{ buttonFrame = "HousingMicroButton" }},
        },

        {
            name = _G["GUILD_AND_COMMUNITIES"] or "Guild & Communities",
            keywords = {"guild", "communities", "social", "clan"},
            category = "Menu Bar",
            buttonFrame = "GuildMicroButton",
            steps = {{ buttonFrame = "GuildMicroButton" }},
        },

        {
            name = _G["LFG_TITLE"] or _G["GROUP_FINDER"] or "Group Finder",
            keywords = {"lfg", "lfd", "lfr", "finder", "queue", "group finder"},
            category = "Menu Bar",
            buttonFrame = "LFDMicroButton",
            steps = {{ buttonFrame = "LFDMicroButton" }},
            children = {
                {
                    name = _G["GROUP_FINDER"] or "Dungeons & Raids",
                    isPvE = true,
                    keywords = {"dungeons", "raids", "dungeons and raids"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 1 }},
                    children = {
                        { name = _G["LOOKING_FOR_DUNGEON"] or _G["DUNGEON_FINDER"] or "Dungeon Finder", keywords = {"dungeon finder", "lfd", "random dungeon", "heroic dungeon", "normal dungeon", "dungeon queue"}, canQueue = true, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 1 }} },
                        { name = _G["RAID_FINDER"] or _G["LOOKING_FOR_RAID"] or "Raid Finder", keywords = {"raid finder", "lfr", "looking for raid", "raid queue", "random raid"}, canQueue = true, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 2 }} },
                        { name = (_G["GUILD_INTEREST_QUEST"] or "Questing") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"questing", "quest", "quest group", "quest lfg", "find quest group", "premade questing", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 1 }} },
                        { name = (_G["DELVES_LABEL"] or "Delves") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"delves", "delve group", "delve lfg", "find delve group", "premade delves", "delve", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 121 }} },
                        { name = (_G["DUNGEONS"] or "Dungeons") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"dungeons", "dungeon group", "dungeon lfg", "find dungeon group", "premade dungeons", "m+ group", "mythic group", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 2 }} },
                        { name = (_G["RAIDS"] or "Raids") .. " - " .. (_G["EXPANSION_NAME10"] or "The War Within") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"raids", "raids the war within", "raid group", "raid lfg", "find raid group", "premade raids", "tww raid", "war within raid", "nerub-ar", "liberation of undermine", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 3, lfgFilters = (Enum and Enum.LFGListFilter and Enum.LFGListFilter.Recommended) or 0x1 }} },
                        { name = (_G["RAIDS"] or "Raids") .. " - " .. L["UITREE_LEGACY"] .. L["UITREE_SUFFIX_PREMADE"], keywords = {"raids", "raids legacy", "legacy raid", "old raid", "legacy raid group", "legacy lfg", "transmog raid", "tmog raid", "mount run", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 3, lfgFilters = (Enum and Enum.LFGListFilter and Enum.LFGListFilter.NotRecommended) or 0x2 }} },
                        { name = (_G["CUSTOM"] or "Custom") .. L["UITREE_SUFFIX_PVE_GROUP"], keywords = {"custom", "custom pve", "custom group", "custom lfg", "pve custom", "premade"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 6 }} },
                    },
                },

                {
                    name = _G["PVP"] or _G["PLAYER_V_PLAYER"] or "Player vs. Player",
                    isPvP = true,
                    keywords = {"pvp", "player vs player", "battleground", "arena", "bg"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 2 }},
                    children = {
                        {
                            name = _G["PVP_TAB_HONOR"] or "Quick Match",
                            keywords = {"quick match", "random bg", "random battleground", "casual pvp", "unrated", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 1 }},
                            children = {
                                { name = _G["SKIRMISH"] or "Arena Skirmish", keywords = {"arena skirmish", "skirmish", "unrated arena", "casual arena", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.Arena1Button", "HonorFrame.ArenaSkirmish"}, searchButtonText = "Arena Skirmish" }} },
                                { name = _G["RANDOM_BATTLEGROUND"] or "Random Battleground", keywords = {"random bg", "random battleground", "casual bg", "unrated bg", "battleground"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.RandomBGButton", "HonorFrame.RandomBG"}, searchButtonText = "Random Battlegrounds" }} },
                                { name = _G["RANDOM_EPIC_BATTLEGROUND"] or "Random Epic Battleground", keywords = {"random epic bg", "random epic battleground", "epic bg", "epic battleground", "ashran", "alterac", "isle of conquest"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.RandomEpicBGButton", "HonorFrame.RandomEpicBG"}, searchButtonText = "Random Epic Battlegrounds" }} },
                                { name = _G["LFG_CATEGORY_BATTLEFIELD"] or "Brawl", keywords = {"brawl", "pvp brawl", "weekly brawl", "packed house"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.BrawlButton"}, searchButtonText = "Brawl" }} },
                            },
                        },
                        {
                            name = _G["PVP_TAB_CONQUEST"] or "Rated",
                            keywords = {"rated", "rated pvp", "conquest", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 2 }},
                            children = {
                                { name = _G["PVP_RATED_SOLO_SHUFFLE"] or "Solo Shuffle", keywords = {"solo shuffle", "shuffle", "solo arena", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedSoloShuffle"}, searchButtonText = "Solo Arena" }} },
                                { name = _G["CONQUEST_BRACKET_NAME_2V2"] or _G["PVP_BRACKET_1"] or "2v2 Arena", keywords = {"2v2", "2s", "twos", "2v2 arena", "two vs two", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena2v2"}, searchButtonText = "2v2" }} },
                                { name = _G["PVP_BRACKET_2"] or "3v3 Arena", keywords = {"3v3", "3s", "threes", "3v3 arena", "three vs three", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena3v3"}, searchButtonText = "3v3" }} },
                                { name = _G["PVP_RATED_BATTLEGROUNDS"] or "Rated Battlegrounds", keywords = {"rbg", "rated bg", "rated battleground", "rated battlegrounds", "10v10", "ten vs ten"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBG"} }} },
                                { name = L["UITREE_SOLO_BATTLEGROUNDS"] .. L["UITREE_SUFFIX_BLITZ"], keywords = {"solo bg", "solo battleground", "solo battlegrounds", "battleground", "blitz", "battleground blitz"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBGBlitz"}, searchButtonText = "Solo Battlegrounds" }} },
                            },
                        },
                        { name = L["UITREE_ARENAS"] .. L["UITREE_SUFFIX_PREMADE"], keywords = {"arena premade", "arena group", "arena lfg", "find arena", "arena", "premade"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 4 }} },
                        { name = (_G["SKIRMISH"] or "Arena Skirmish") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"arena skirmish premade", "skirmish group", "skirmish lfg", "skirmish", "premade"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 7 }} },
                        { name = (_G["BATTLEGROUNDS"] or "Battlegrounds") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"bg premade", "battleground group", "bg lfg", "find bg", "battleground", "premade"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 8 }} },
                        { name = (_G["PVP_RATED_BATTLEGROUNDS"] or "Rated Battlegrounds") .. L["UITREE_SUFFIX_PREMADE"], keywords = {"rated bg premade", "rbg premade", "rbg group", "rbg lfg", "rated battleground", "premade"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 9 }} },
                        { name = (_G["CUSTOM"] or "Custom") .. L["UITREE_SUFFIX_PVP_GROUP"], keywords = {"custom pvp", "custom group", "custom lfg", "pvp custom", "custom", "premade"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }, { waitForFrame = "PVEFrame", lfgCategoryID = 6 }} },
                        {
                            name = _G["PVP_TAB_TRAINING_GROUNDS"] or "Training Grounds",
                            keywords = {"training", "training grounds", "practice", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 4 }},
                            children = {
                                { name = L["UITREE_RANDOM_BATTLEGROUNDS"] .. L["UITREE_SUFFIX_TRAINING_GROUNDS"], keywords = {"random bg", "random battleground", "random battlegrounds", "training battleground", "bonus battleground"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"TrainingGroundsFrame.BonusTrainingGroundList.RandomTrainingGroundButton"}, searchButtonText = "Random Battlegrounds" }} },
                            },
                        },
                    },
                },

                {
                    name = _G["CHALLENGES"] or "Mythic+ Dungeons",
                    isPvE = true,
                    keywords = {"mythic", "mythic+", "m+", "keystone", "mythic plus", "keys"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = _G["COLLECTIONS"] or "Warband Collections",
            keywords = {"collections", "warband"},
            category = "Menu Bar",
            buttonFrame = "CollectionsMicroButton",
            steps = {{ buttonFrame = "CollectionsMicroButton" }},
            children = {
                { name = _G["MOUNTS"] or "Mounts", keywords = {"mounts", "mount", "riding", "mount collection", "flying"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 1 }} },
                { name = _G["PET_JOURNAL"] or _G["PETS"] or "Pet Journal", keywords = {"pets", "pet", "battle pets", "companion", "pet collection", "critter", "pet journal"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 2 }} },
                { name = _G["TOY_BOX"] or "Toy Box", keywords = {"toys", "toy", "toybox", "toy box", "fun items"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 3 }} },
                { name = _G["HEIRLOOMS"] or "Heirlooms", keywords = {"heirlooms", "heirloom", "leveling gear", "bind on account", "boa"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 4 }} },
                { name = _G["WARDROBE"] or "Appearances", keywords = {"transmog", "tmog", "xmog", "transmogrification", "appearance", "appearances", "wardrobe", "cosmetic", "looks", "mog"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 5 }} },
                { name = _G["WARBAND_SCENES"] or "Campsites", keywords = {"campsites", "campsite", "camp", "camping", "rest area"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 6 }} },
            },
        },

        {
            name = _G["TRANSMOGRIFICATION"] or "Transmogrification",
            keywords = {"transmogrification", "transmog", "tmog", "xmog", "mog", "wardrobe", "appearance"},
            category = "Transmogrification",
            icon = { file = 6119963, coords = { 0.0183, 0.2629, 0.0131, 0.5152 } },
            steps = {{ loadTransmog = true }},
        },

        {
            name = _G["ADVENTURE_JOURNAL"] or "Adventure Guide",
            keywords = {"adventure", "guide", "dungeon journal", "encounters", "loot", "boss", "journal"},
            category = "Menu Bar",
            buttonFrame = "EJMicroButton",
            steps = {{ buttonFrame = "EJMicroButton" }},
            children = {
                { name = _G["JOURNEYS_LABEL"] or "Journeys", keywords = {"journeys", "journey", "adventure journeys"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 1 }}, children = {
                    { name = L["UITREE_GREAT_VAULT"] .. L["UITREE_SUFFIX_REWARDS"], keywords = {"great vault", "vault", "weekly rewards", "weekly chest", "rewards"}, category = "Adventure Guide", icon = { file = 1121272, coords = { 0.2002, 0.2411, 0.6081, 0.6508 } }, steps = {{ buttonFrame = "EncounterJournalInstanceSelect.GreatVaultButton" }} },
                }},
                { name = _G["MONTHLY_ACTIVITIES_TAB"] or "Traveler's Log", keywords = {"traveler", "travelers log", "traveler log", "travel log"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 2 }} },
                { name = _G["AJ_SUGGESTED_CONTENT_TAB"] or "Suggested Content", keywords = {"suggested", "suggested content", "recommendations"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 3 }} },
                { name = (_G["DUNGEONS"] or "Dungeons") .. L["UITREE_SUFFIX_JOURNAL"], keywords = {"dungeon journal", "dungeon guide", "dungeon encounters", "dungeon bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 4 }} },
                { name = (_G["RAIDS"] or "Raids") .. L["UITREE_SUFFIX_JOURNAL"], keywords = {"raid journal", "raid guide", "raid encounters", "raid bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 5 }} },
                { name = _G["LOOT_JOURNAL_ITEM_SETS"] or "Item Sets", keywords = {"item sets", "tier sets", "set bonuses", "class sets"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 6 }} },
                { name = _G["EJ_TUTORIALS"] or "Tutorials", keywords = {"tutorials", "tutorial", "help guide", "how to"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 7 }} },
            },
        },

        -- /click routes through secure dispatch so the micro button's OnClick
        -- fires from a hardware event; ToggleGameMenu's ClearTarget needs that.
        -- /run ShowUIPanel(GameMenuFrame) here forbid-errors on ClearTarget.
        {
            name = _G["MAINMENU_BUTTON"] or _G["GAMEMENU_BUTTON"] or "Game Menu",
            -- "options"/"settings" belong to the guided Options child below;
            -- carrying them here made the direct-open menu row outrank it.
            keywords = {"menu", "escape", "esc", "logout", "quit", "exit", "interface"},
            category = "Menu Bar",
            buttonFrame = "MainMenuMicroButton",
            slashCommand = "/click MainMenuMicroButton",
            children = {
                {
                    name = _G["GAMEMENU_OPTIONS"] or _G["OPTIONS"] or "Options",
                    keywords = {"options", "game options", "settings", "game settings", "system"},
                    steps = {
                        { buttonFrame = "MainMenuMicroButton" },
                        { gameMenuText = _G["GAMEMENU_OPTIONS"] or _G["OPTIONS"] or "Options" },
                    },
                },
            },
        },
        {
            name = _G["HELP_BUTTON"] or _G["HELP_LABEL"] or "Help",
            keywords = {"help", "support", "ticket", "bug", "report", "gm"},
            category = "Menu Bar",
            buttonFrame = "HelpMicroButton",
            steps = {{ buttonFrame = "HelpMicroButton" }},
        },
        {
            name = _G["BLIZZARD_STORE"] or _G["STORE"] or "Shop",
            keywords = {"shop", "store", "blizzard shop", "cash shop", "buy", "purchase", "micro transaction"},
            category = "Menu Bar",
            buttonFrame = "StoreMicroButton",
            -- ToggleStoreUI is protected; programmatic
            -- StoreMicroButton:Click() raises ADDON_ACTION_FORBIDDEN.
            -- Routing through /click treats the press as a hardware
            -- event in secure code, matching the Game Menu entry.
            slashCommand = "/click StoreMicroButton",
        },

        {
            name = L["UITREE_PORTRAIT_MENU"],
            keywords = {"portrait", "portrait menu", "right click portrait", "player frame menu"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            steps = {{ portraitMenu = true }},
            children = {
                { name = _G["SET_FOCUS"] or "Set Focus", keywords = {"set focus", "focus target", "focus frame", "focus"}, steps = {{ portraitMenuOption = _G["SET_FOCUS"] or "Set Focus" }} },
                { name = _G["SELF_HIGHLIGHT_OPTION"] or "Self Highlight", keywords = {"self highlight", "highlight self", "outline", "self outline"}, steps = {{ portraitMenuOption = _G["SELF_HIGHLIGHT_OPTION"] or "Self Highlight" }} },
                { name = _G["RAID_TARGET_ICON"] or "Target Marker Icon", keywords = {"target marker", "raid marker", "skull", "cross", "star", "moon", "marker icon", "raid icon", "world marker"}, steps = {{ portraitMenuOption = _G["RAID_TARGET_ICON"] or "Target Marker Icon" }} },
                { name = _G["SELECT_LOOT_SPECIALIZATION"] or "Loot Specialization", keywords = {"loot spec", "loot specialization", "loot preference"}, steps = {{ portraitMenuOption = _G["SELECT_LOOT_SPECIALIZATION"] or "Loot Specialization" }} },
                { name = _G["DUNGEON_DIFFICULTY"] or "Dungeon Difficulty", keywords = {"dungeon difficulty", "normal dungeon", "heroic dungeon", "mythic dungeon", "instance difficulty"}, steps = {{ portraitMenuOption = _G["DUNGEON_DIFFICULTY"] or "Dungeon Difficulty" }} },
                { name = _G["RAID_DIFFICULTY"] or "Raid Difficulty", keywords = {"raid difficulty", "normal raid", "heroic raid", "mythic raid", "raid size"}, steps = {{ portraitMenuOption = _G["RAID_DIFFICULTY"] or "Raid Difficulty" }} },
                {
                    name = _G["RESET_INSTANCES"] or "Reset All Instances",
                    keywords = {"reset instances", "reset all instances", "instance reset", "dungeon reset"},
                    available = function()
                        local inInstance = IsInInstance()
                        if inInstance then return false end
                        if IsInGroup() and not UnitIsGroupLeader("player") then return false end
                        return true
                    end,
                    steps = {{ portraitMenuOption = _G["RESET_INSTANCES"] or "Reset All Instances" }},
                },
                { name = _G["HUD_EDIT_MODE_MENU"] or _G["EDIT_MODE"] or "Edit Mode", keywords = {"edit mode", "ui layout", "customize ui", "move frames", "hud edit", "ui editor"}, steps = {{ portraitMenuOption = _G["HUD_EDIT_MODE_MENU"] or _G["EDIT_MODE"] or "Edit Mode" }} },
                { name = _G["VOICE_CHAT"] or "Voice Chat", keywords = {"voice chat", "voice", "voip", "talk", "microphone", "mic"}, steps = {{ portraitMenuOption = _G["VOICE_CHAT"] or "Voice Chat" }} },
                { name = _G["PVP_FLAG"] or "PvP Flag", isPvP = true, keywords = {"pvp flag", "pvp toggle", "player vs player flag", "pvp enable", "war mode"}, steps = {{ portraitMenuOption = _G["PVP_FLAG"] or "PvP Flag" }} },
            },
        },

        {
            name = _G["BAGSLOT"] or _G["INVENTORY_TOOLTIP"] or "Bags / Inventory",
            keywords = {"bags", "bag", "inventory", "backpack", "items", "storage"},
            category = "Inventory",
            iconAtlas = "bag-main",
            steps = {{ buttonFrame = "MainMenuBarBackpackButton" }},
        },
        {
            name = _G["FRIENDS_LIST"] or _G["FRIENDS"] or "Friends List",
            keywords = {"friends", "social", "bnet", "battlenet", "contacts", "whisper", "online"},
            category = "Social",
            icon = 132175,
            steps = {{ buttonFrame = "QuickJoinToastButton" }},
        },
        {
            name = L["UITREE_TOGGLE_WORLD_MAP"],
            keywords = {"map", "world map", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run ToggleWorldMap()",
        },
        {
            name = _G["BINDING_NAME_TOGGLEBATTLEFIELDMINIMAP"] or "Toggle Zone Map",
            keywords = {"zone map", "battlefield map", "floating map", "area map", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run C_AddOns.LoadAddOn('Blizzard_BattlefieldMap'); if BattlefieldMapFrame then BattlefieldMapFrame:SetShown(not BattlefieldMapFrame:IsShown()) end",
        },
        {
            name = _G["BINDING_NAME_TOGGLEMINIMAP"] or "Toggle Minimap",
            keywords = {"minimap", "mini map", "tracking", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run MinimapCluster:SetShown(not MinimapCluster:IsShown())",
        },
        {
            name = L["UITREE_CALENDAR"],
            keywords = {"calendar", "events", "holidays", "schedule"},
            category = "Social",
            icon = 134939,
            slashCommand = "/click GameTimeFrame",
        },

        -- /dismisspet only handles hunter/warlock pets; the second line
        -- toggles the active battle-pet companion (dismissing it).
        {
            name = L["UITREE_DISMISS_PET"],
            keywords = {"dismiss", "dismiss pet", "pet", "companion", "summon",
                        "battle pet", "critter", "minion"},
            category = "Action",
            icon = 631719,
            slashCommand = "/dismisspet\n/run local g = C_PetJournal and C_PetJournal.GetSummonedPetGUID and C_PetJournal.GetSummonedPetGUID(); if g then C_PetJournal.SummonPetByGUID(g) end",
        },
    }

    self:FlattenTree(uiTree)

    for _, item in ipairs(uiSearchData) do
        item.nameLower = slower(item.name)
        if item.keywords then
            local kws = item.keywords
            local needsCopy = false
            for i = 1, #kws do
                local k = kws[i]
                if k ~= slower(k) then needsCopy = true; break end
            end
            if needsCopy then
                local lowered = {}
                for i = 1, #kws do lowered[i] = slower(kws[i]) end
                item.keywordsLower = lowered
            end
            -- When `kws` is already lowercase, leave keywordsLower nil.
            -- Readers fall back to entry.keywords, saving one hash slot
            -- per entry. Across ~5000 entries that's ~160 KB.
        end
        if not item.icon and not item.buttonFrame then
            item.icon = 134400
        end
    end

    -- isPvP / isPvE are set during FlattenTree from explicit flags on the
    -- uiTree nodes — see "Player vs. Player", "Dungeons & Raids", etc.
    -- Entries with category="PvP" (individual PvP queue rows like Arena
    -- Skirmish) also count as PvP for filter purposes.
    for _, item in ipairs(uiSearchData) do
        ApplyGroupFinderSubcategoryIcon(item)
        if not item.isPvP and item.category == "PvP" then
            item.isPvP = true
        end
    end
end

-- Build at load time (before ADDON_LOADED) so other modules can reference
-- uiSearchData during their own init. Not routed through SafeInit, so wrap.
local initOk, initErr = xpcall(Database.Initialize, Utils.ErrorHandler, Database)
if not initOk then
    print("|cffff4444" .. L["ERR_DATABASE_INIT_FAILED"] .. tostring(initErr) .. "|r")
end
