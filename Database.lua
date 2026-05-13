local _, ns = ...

local Database = {}
ns.Database = Database

local Utils   = ns.Utils
local ipairs = Utils.ipairs
local tsort = Utils.tsort
local sfind, slower, ssub = Utils.sfind, Utils.slower, Utils.ssub
local sbyte = string.byte
local mmin, mmax, mabs = Utils.mmin, Utils.mmax, Utils.mabs
local C_CurrencyInfo = C_CurrencyInfo
local band, lshift = bit.band, bit.lshift

-- FIFO-bounded; oldest prefixes evict when the ring buffer wraps.
local wordCache = {}
local wordCacheKeys = {}
local wordCacheHead = 1
local WORD_CACHE_MAX = 256

local function GetWords(str)
    local cached = wordCache[str]
    if cached then return cached end
    local words = {}
    for w in str:gmatch("[%w']+") do
        words[#words + 1] = w
    end
    local oldKey = wordCacheKeys[wordCacheHead]
    if oldKey then wordCache[oldKey] = nil end
    wordCacheKeys[wordCacheHead] = str
    wordCacheHead = wordCacheHead + 1
    if wordCacheHead > WORD_CACHE_MAX then wordCacheHead = 1 end
    wordCache[str] = words
    return words
end

local dlPrev2, dlPrev, dlCurr = {}, {}, {}

local scoreNameUsedWords = {}

local function scoreDescending(a, b) return a.score > b.score end

local uiSearchData = {}
Database.uiSearchData = uiSearchData
Database._wordCache = wordCache
local knownCurrencyIDs = {}

local function RemoveEntriesByCategory(category)
    local writeIdx = 0
    for i = 1, #uiSearchData do
        local entry = uiSearchData[i]
        if entry.category ~= category then
            writeIdx = writeIdx + 1
            uiSearchData[writeIdx] = entry
        end
    end
    for i = #uiSearchData, writeIdx + 1, -1 do
        uiSearchData[i] = nil
    end
end

local function RemoveEntriesWithField(field)
    local writeIdx = 0
    for i = 1, #uiSearchData do
        local entry = uiSearchData[i]
        if not entry[field] then
            writeIdx = writeIdx + 1
            uiSearchData[writeIdx] = entry
        end
    end
    for i = #uiSearchData, writeIdx + 1, -1 do
        uiSearchData[i] = nil
    end
end

function Database:_RemoveEntriesByCategory(category)
    RemoveEntriesByCategory(category)
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
        local path = {"Character Info", "Currency"}
        for _, h in ipairs(headerStack) do
            path[#path + 1] = h.name .. " Currencies"
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
                        name = info.name .. " Currencies",
                        keywords = {headerNameLower, headerNameLower .. " currencies", headerNameLower .. " currency"},
                        category = "Currency",
                        buttonFrame = "CharacterMicroButton",
                        path = buildPath(),
                        steps = buildHeaderSteps(),
                        flashLabel = "Currency",
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
                    flashLabel = "Currency",
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

    for _, item in ipairs(uiSearchData) do
        if not item.icon and item.steps then
            for _, step in ipairs(item.steps) do
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
                            path = { "Character Info", "Currency" },
                            steps = {
                                { buttonFrame = "CharacterMicroButton" },
                                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                                { waitForFrame = "CharacterFrame", currencyID = cid },
                            },
                            flashLabel = "Currency",
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

    local currentExpansion = nil
    local currentFactionGroup = nil


    local function buildHeaderSteps()
        local steps = {}
        for _, s in ipairs(baseSteps) do steps[#steps + 1] = s end
        if currentExpansion then
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", factionHeader = currentExpansion }
        end
        if currentFactionGroup then
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", factionHeader = currentFactionGroup }
        end
        return steps
    end

    local function buildPath()
        local path = {"Character Info", "Reputation"}
        if currentExpansion then
            path[#path + 1] = currentExpansion
        end
        if currentFactionGroup then
            path[#path + 1] = currentFactionGroup
        end
        return path
    end

    local ALLIANCE_HEADER = (FACTION_ALLIANCE or "Alliance"):lower()
    local HORDE_HEADER    = (FACTION_HORDE    or "Horde"):lower()

    local function injectFaction(factionData)
        local isDiscovered = (factionData.currentStanding and factionData.currentStanding > 0) or
                             (factionData.isWatched == true)
        if not isDiscovered then return end

        local steps = buildHeaderSteps()
        steps[#steps + 1] = { waitForFrame = "CharacterFrame", factionID = factionData.factionID }

        local path = buildPath()

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

        local entry = {
            name = factionData.name,
            keywords = keywords,
            category = "Reputation",
            buttonFrame = "CharacterMicroButton",
            path = path,
            steps = steps,
            factionID = factionData.factionID,
            factionSide = factionSide,
            hasRepBar = not factionData.isHeader or factionData.isHeaderWithRep,
        }

        entry.nameLower = factionNameLower
        entry.keywordsLower = {}
        for j, kw in ipairs(entry.keywords) do
            entry.keywordsLower[j] = kw
        end

        uiSearchData[#uiSearchData + 1] = entry
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
    keywords     = {"outfit", "transmog", "tmog", "mog", "appearance", "keymog"},
    keywordsLower = {"outfit", "transmog", "tmog", "mog", "appearance", "keymog"},
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
local LOOT_MT = { __index = LOOT_PROTO }

local TRANSMOG_SET_PROTO = {
    category = "Appearance Set",
    path     = {},
    steps    = {},
}
local TRANSMOG_SET_MT = { __index = TRANSMOG_SET_PROTO }

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
    for equipLoc, words in _G.pairs(SLOT_KEYWORDS) do
        AddHeavySearchWord(_G[equipLoc])
        AddHeavySearchWords(words)
    end
    for statKey, words in _G.pairs(STAT_KEYWORD_MAP) do
        AddHeavySearchWord(_G[statKey])
        AddHeavySearchWords(words)
    end
    return heavySearchWordLookup
end

local statSearchWordLookup
local function IsLootStatSearchWord(word)
    if not statSearchWordLookup then
        statSearchWordLookup = {}
        for statKey, words in _G.pairs(STAT_KEYWORD_MAP) do
            local label = _G[statKey]
            if label then
                for part in slower(label):gmatch("%S+") do
                    statSearchWordLookup[part] = true
                end
            end
            for i = 1, #words do
                for part in words[i]:gmatch("%S+") do
                    statSearchWordLookup[part] = true
                end
            end
        end
    end
    return statSearchWordLookup[word] or false
end

function Database:QueryNeedsHeavySearchData(text)
    if not text then return false end
    local lookup = GetHeavySearchWordLookup()
    for word in slower(text):gmatch("%S+") do
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

-- Powers loot-category boost for slot queries (e.g. "legs").
local lootSlotNames = {}
for _, displayName in pairs(SLOT_DISPLAY) do
    lootSlotNames[slower(displayName)] = true
end
ns.lootSlotNames = lootSlotNames

-- C_EncounterJournal functions may not exist until EncounterJournal_LoadUI(),
-- so resolve at call time. Prefer the C_ namespace over stale EJ_* globals.
local function EJ(name)
    return (C_EncounterJournal and C_EncounterJournal[name]) or _G["EJ_" .. name]
end

local lootEntries = {}
local lootScanGeneration = 0
local bossScanGeneration = 0
local lootItemCache = {}
local lootSpecsScanned = {}
Database._lootItemCache = lootItemCache
Database._lootEntries = lootEntries
Database._lootSpecsScanned = lootSpecsScanned

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

-- EJ_SetDifficulty requires an instance of the matching type to be selected
-- first, so this saves and restores the current selection.
function Database:SyncEJDifficulty()
    local selectInst = EJ("SelectInstance")
    local getInst = EJ("GetInstanceByIndex")
    local setDiff = EJ("SetDifficulty")
    local getInstInfo = EJ("GetInstanceInfo")
    if not selectInst or not getInst or not setDiff then return end

    -- journalInstanceID is the 12th return of EJ_GetInstanceInfo.
    local savedInstID = getInstInfo and select(12, getInstInfo())

    local dungeonDiffID = self:GetEJDifficultyID("Dungeon")
    if dungeonDiffID then
        local dInstID = getInst(1, false)
        if dInstID then
            selectInst(dInstID)
            setDiff(dungeonDiffID)
        end
    end

    local raidDiffID = self:GetEJDifficultyID("Raid")
    if raidDiffID then
        local rInstID = getInst(1, true)
        if rInstID then
            selectInst(rInstID)
            setDiff(raidDiffID)
        end
    end

    if savedInstID and savedInstID > 0 then
        selectInst(savedInstID)
    end
end

function Database:SyncEJLootFilter()
    local setFilter = EJ("SetLootFilter")
    if not setFilter then return end
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
        end
    elseif lootFilter == "all" then
        wantAll = true
    elseif lootFilter.specID then
        wantSpec[lootFilter.classID .. "-" .. lootFilter.specID] = true
    elseif lootFilter.classID then
        for specIdx = 1, GetNumSpecializationsForClassID(lootFilter.classID) do
            local specID = GetSpecializationInfoForClassID(lootFilter.classID, specIdx)
            if specID then wantSpec[lootFilter.classID .. "-" .. specID] = true end
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

function Database:EnrichLootStats(entry)
    if entry._statsEnriched then return end
    local link = Database:GetLootItemLink(entry)
    local GetItemStatsFn = GetItemStats or (C_Item and C_Item.GetItemStats)
    if not GetItemStatsFn then return end
    local stats = link and GetItemStatsFn(link)
    if not stats and entry.itemID then
        stats = GetItemStatsFn("item:" .. entry.itemID)
    end
    if not stats then return end
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
end

-- Outfit equip uses a temporary action bar slot rediscovered each click so we
-- don't overwrite user actions: PreClick places the outfit, secure handler
-- calls UseAction, PostClick clears the slot.
local outfitEntries = {}

function Database:PopulateDynamicMounts()
    if not C_MountJournal or not C_MountJournal.GetMountIDs then return false end

    RemoveEntriesByCategory("Mount")

    local mountIDs = C_MountJournal.GetMountIDs()
    if not mountIDs then return false end

    for _, mountID in ipairs(mountIDs) do
        local name, spellID, icon, _, _, _, _,
              _, _, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
        if name and isCollected and not shouldHideOnChar then
            uiSearchData[#uiSearchData + 1] = setmetatable({
                name = name,
                icon = icon,
                mountID = mountID,
                spellID = spellID,
                nameLower = slower(name),
            }, MOUNT_MT)
        end
    end
    return true
end

function Database:PopulateDynamicToys()
    if not C_ToyBox then return false end

    RemoveEntriesByCategory("Toy")

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

    local numToys = GetNumFilteredToys()
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

    if hasFilterAPI then C_ToyBox.SetCollectedShown(savedCollected) end
    if C_ToyBox.SetUncollectedShown then C_ToyBox.SetUncollectedShown(savedUncollected) end
    if C_ToyBox.SetFilterString then C_ToyBox.SetFilterString(savedString) end
    if C_ToyBox.ForceToyRefilter then C_ToyBox.ForceToyRefilter() end
    return true
end

function Database:PopulateDynamicPets()
    if not C_PetJournal or not C_PetJournal.GetNumPets then return false end

    RemoveEntriesByCategory("Pet")

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

    local numPets = C_PetJournal.GetNumPets()
    if not numPets then
        if C_PetJournal.SetFilterChecked then
            if savedCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, savedCollected) end
            if savedNotCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, savedNotCollected) end
        end
        if C_PetJournal.SetSearchFilter then C_PetJournal.SetSearchFilter(savedString) end
        return false
    end

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

    if C_PetJournal.SetFilterChecked then
        if savedCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, savedCollected) end
        if savedNotCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, savedNotCollected) end
    end
    if C_PetJournal.SetSearchFilter then C_PetJournal.SetSearchFilter(savedString) end
    return true
end

function Database:PopulateDynamicHeirlooms()
    if not C_Heirloom or not C_Heirloom.GetHeirloomItemIDs then return false end

    RemoveEntriesByCategory("Heirloom")

    local ids = C_Heirloom.GetHeirloomItemIDs()
    if type(ids) ~= "table" then return false end

    local hasHeirloom = C_Heirloom.PlayerHasHeirloom
    local getInfo = C_Heirloom.GetHeirloomInfo
    if not getInfo then return false end

    local getItemIcon = C_Item and C_Item.GetItemIconByID
    for _, itemID in ipairs(ids) do
        local owned = (not hasHeirloom) or hasHeirloom(itemID)
        if owned then
            local name, _, _, icon = getInfo(itemID)
            if (not icon or icon == 0) and getItemIcon then
                icon = getItemIcon(itemID)
            end
            if name and name ~= "" then
                uiSearchData[#uiSearchData + 1] = setmetatable({
                    name = name,
                    nameLower = slower(name),
                    icon = icon,
                    heirloomItemID = itemID,
                }, HEIRLOOM_MT)
            end
        end
    end
    if self.ResetSearchCache then self:ResetSearchCache() end
    return true
end

-- Title names contain a "%s" placeholder for the player name; strip it so
-- "the Insane" displays instead of "%s the Insane".
function Database:PopulateDynamicTitles()
    local getNum = GetNumTitles
    local getName = GetTitleName
    local isKnown = IsTitleKnown
    if not getNum or not getName or not isKnown then return false end

    RemoveEntriesByCategory("Title")

    local total = getNum()
    if not total or total <= 0 then return false end

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
    if self.ResetSearchCache then self:ResetSearchCache() end
    return true
end


function Database:PopulateDynamicGearSets()
    if not C_EquipmentSet or not C_EquipmentSet.GetEquipmentSetIDs then return false end

    RemoveEntriesByCategory("Gear Set")

    local ids = C_EquipmentSet.GetEquipmentSetIDs()
    if type(ids) ~= "table" then return false end

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
    wipe(outfitEntries)

    local outfits = C_TransmogOutfitInfo.GetOutfitsInfo()
    if not outfits then return false end

    for _, info in ipairs(outfits) do
        if not info.isDisabled then
            local entry = setmetatable({
                name = info.name,
                icon = info.icon,
                outfitID = info.outfitID,
                nameLower = slower(info.name),
            }, OUTFIT_MT)
            uiSearchData[#uiSearchData + 1] = entry
            outfitEntries[#outfitEntries + 1] = entry
        end
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
    local getClass = C_TransmogSets and C_TransmogSets.GetTransmogSetsClassFilter
    if getClass then
        local ok, classID = pcall(getClass)
        if ok and classID then
            local _, _, playerClassID = UnitClass("player")
            if classID == playerClassID then
                db.appearanceSetClass = nil
            else
                db.appearanceSetClass = { classID = classID }
            end
        end
    end
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

    -- Guard against the Core.lua hooksecurefunc re-entering Populate.
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
                local kw = {"set", "transmog", "appearance"}
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
                    keywordsLower = kw,
                }, TRANSMOG_SET_MT)
            end
        end
    end
    return true
end

function Database:FindEmptyActionSlot()
    -- Skip 121-168 (bonus/override/vehicle/stance bars) since they may reject
    -- non-class-specific actions like totem or stance slots.
    for slot = 180, 169, -1 do
        if not HasAction(slot) then return slot end
    end
    for slot = 120, 1, -1 do
        if not HasAction(slot) then return slot end
    end
end

local function BuildLootSpecPairs(scanAllSpecs)
    local specPairs = {}
    if scanAllSpecs then
        for classIdx = 1, GetNumClasses() do
            local _, _, classID = GetClassInfo(classIdx)
            if classID then
                for specIdx = 1, GetNumSpecializationsForClassID(classID) do
                    local specID = GetSpecializationInfoForClassID(classID, specIdx)
                    if specID then
                        specPairs[#specPairs + 1] = { classID = classID, specID = specID }
                    end
                end
            end
        end
    else
        local lootFilter = EasyFind.db.lootFilter
        if not lootFilter then
            local _, _, cid = UnitClass("player")
            local si = GetSpecialization and GetSpecialization()
            local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
            if cid and sid then
                specPairs[1] = { classID = cid, specID = sid }
            end
        elseif lootFilter == "all" then
            for classIdx = 1, GetNumClasses() do
                local _, _, classID = GetClassInfo(classIdx)
                if classID then
                    for specIdx = 1, GetNumSpecializationsForClassID(classID) do
                        local specID = GetSpecializationInfoForClassID(classID, specIdx)
                        if specID then
                            specPairs[#specPairs + 1] = { classID = classID, specID = specID }
                        end
                    end
                end
            end
        elseif lootFilter.specID then
            specPairs[1] = { classID = lootFilter.classID, specID = lootFilter.specID }
        elseif lootFilter.classID then
            for specIdx = 1, GetNumSpecializationsForClassID(lootFilter.classID) do
                local specID = GetSpecializationInfoForClassID(lootFilter.classID, specIdx)
                if specID then
                    specPairs[#specPairs + 1] = { classID = lootFilter.classID, specID = specID }
                end
            end
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
    local pairs = {}
    local st = isRaid and "raid" or "dungeon"
    for diffKey, ids in _G.pairs(LOOT_DIFF_IDS) do
        if ids[st] then
            pairs[#pairs + 1] = { key = diffKey, id = ids[st] }
        end
    end
    return pairs
end

local function CacheLootInfo(database, lootInfo, inst, encName, encID, diff, sp, spKey, GetItemInfoInstantFn)
    local itemID = lootInfo.itemID
    if not itemID then return end
    local cached = lootItemCache[itemID]
    if cached then
        local foundSp = false
        for _, sk in ipairs(cached._cachedSpecs) do
            if sk == spKey then foundSp = true; break end
        end
        if not foundSp then
            cached._cachedSpecs[#cached._cachedSpecs + 1] = spKey
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
        end
        return
    end

    local itemName = lootInfo.name
    if not itemName or itemName == "" then return end
    local _, _, _, equipLoc, instIcon = GetItemInfoInstantFn(itemID)
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
        encounterID = encID,
        instanceID = inst.id,
        keywords = {},
        keywordsLower = {},
        lootSlotKw = slotKws,
        lootSourceKw = sourceKws,
        lootStatKw = {},
        lootItemLinks = itemLinks,
        lootSlotName = equipLoc and SLOT_DISPLAY[equipLoc],
        lootSourceName = encName,
        lootInstanceName = inst.name,
        lootSourceType = inst.isRaid and "Raid" or "Dungeon",
        _cachedSpecs = { spKey },
        _cachedDiffs = { diff.key },
    }, LOOT_MT)

    if lootInfo.link then
        database:EnrichLootStats(entry)
    end
    lootItemCache[itemID] = entry
end

function Database:CancelDynamicScans(includeBosses)
    lootScanGeneration = lootScanGeneration + 1
    if includeBosses then
        bossScanGeneration = bossScanGeneration + 1
    end
end

-- scanAllSpecs=true pre-caches every class/spec combo (loading screen path).
function Database:PopulateDynamicLoot(scanAllSpecs)
    if InCombatLockdown() then return end

    local specPairs = BuildLootSpecPairs(scanAllSpecs)
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

    if not EJ_GetCurrentTier or not EJ_GetInstanceByIndex or not EJ_GetLootInfoByIndex then
        Utils.DebugPrint("Loot scan aborted: EJ APIs not available")
        return
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
                        EJ_SetLootFilter(sp.classID, sp.specID)
                    end

                    local li = 1
                    while true do
                        local lootInfo = EJ_GetLootInfoByIndex(li)
                        if not lootInfo or not lootInfo.name then break end
                        CacheLootInfo(Database, lootInfo, inst, encName, encID, diff, sp, spKey, GetItemInfoInstant)
                        li = li + 1
                    end
                end
            end
            encIdx = encIdx + 1
        end
    end

    if savedTier and EJ_SelectTier then EJ_SelectTier(savedTier) end
    if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
    for _, sp in ipairs(needScan) do
        lootSpecsScanned[sp.classID .. "-" .. sp.specID] = true
    end
    RebuildLootSearchData()
    Utils.SafeAfter(0, function()
        collectgarbage("step", 200)
    end)
end

function Database:PopulateDynamicLootAsync(done, scanAllSpecs)
    if InCombatLockdown() then done(false); return end
    if not C_Timer or not C_Timer.After then
        self:PopulateDynamicLoot(scanAllSpecs)
        done(true)
        return
    end

    local specPairs = BuildLootSpecPairs(scanAllSpecs)
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

    if not EJ_GetCurrentTier or not EJ_GetInstanceByIndex or not EJ_GetLootInfoByIndex then
        done(false)
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
    }
    local GetItemInfoInstantFn = GetItemInfoInstant
    local budgetMs = 4

    local function finish(changed, err)
        if savedTier and EJ_SelectTier then EJ_SelectTier(savedTier) end
        if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
        if changed then
            for _, sp in ipairs(needScan) do
                lootSpecsScanned[sp.classID .. "-" .. sp.specID] = true
            end
            RebuildLootSearchData()
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
            else
                local diff = state.diffPairs[state.diffIdx]
                local sp = needScan[state.specIdx]
                local spKey = sp.classID .. "-" .. sp.specID
                if not state.prepared then
                    EJ_SelectInstance(inst.id)
                    EJ_SelectEncounter(state.encID)
                    if EJ_SetDifficulty then EJ_SetDifficulty(diff.id) end
                    if EJ_SetSlotFilter then EJ_SetSlotFilter(Enum.ItemSlotFilterType.NoFilter) end
                    if EJ_SetLootFilter then EJ_SetLootFilter(sp.classID, sp.specID) end
                    state.lootIdx = 1
                    state.prepared = true
                end

                local processed = 0
                while processed < 8 do
                    local lootInfo = EJ_GetLootInfoByIndex(state.lootIdx)
                    if not lootInfo or not lootInfo.name then
                        state.specIdx = state.specIdx + 1
                        state.lootIdx = 1
                        state.prepared = false
                        break
                    end
                    CacheLootInfo(self, lootInfo, inst, state.encName, state.encID, diff, sp, spKey, GetItemInfoInstantFn)
                    state.lootIdx = state.lootIdx + 1
                    processed = processed + 1
                end
            end

            if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                C_Timer.After(0, function()
                    local ok, err = xpcall(step, Utils.ErrorHandler)
                    if not ok then finish(false, err) end
                end)
                return
            end
        end
    end

    C_Timer.After(0, function()
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
            keywordsLower = kw,
            category = "Macro",
            icon = iconTexture,
            macroIndex = macroIdx,
            macroBody = body,
            macroIsChar = isCharSpecific,
            buttonFrame = "MainMenuMicroButton",
            path = { "Macros", isCharSpecific and "Character" or "General" },
            steps = {
                { buttonFrame = "MainMenuMicroButton" },
                { gameMenuText = "Macros" },
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
            keywordsLower = kw,
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
                    local seenKey = tostring(itemInfo.actionID) .. ":" .. tostring(tab)
                        .. ":" .. tostring(lineSpecID or "")
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

local function AddBossEntry(tier, isRaid, instID, instName, encName, encID, getCreatureInfo)
    local nameLower = slower(encName)
    local instLower = slower(instName or "")
    local kw = { instLower, "boss", "bosses" }
    local abbrs = INSTANCE_ABBRS[instLower]
    if abbrs then
        for ai = 1, #abbrs do
            kw[#kw + 1] = abbrs[ai]
        end
    end

    local icon
    if getCreatureInfo then
        local ok, _, _, _, _, iconImage = pcall(getCreatureInfo, 1, encID)
        if ok and iconImage and iconImage ~= 0 then
            icon = iconImage
        end
    end

    uiSearchData[#uiSearchData + 1] = {
        name = encName,
        nameLower = nameLower,
        keywords = kw,
        keywordsLower = kw,
        category = "Boss",
        icon = icon,
        encounterID = encID,
        instanceID = instID,
        instanceName = instName,
        instanceNameLower = instLower,
        isRaidBoss = isRaid,
        ejTier = tier,
        path = { isRaid and "Raid" or "Dungeon", instName },
        steps = {
            { buttonFrame = "EJMicroButton" },
            { waitForFrame = "EncounterJournal", ejTier = tier, ejTabIsRaid = isRaid },
            { waitForFrame = "EncounterJournal", ejInstance = instName, ejInstanceID = instID },
            { waitForFrame = "EncounterJournal", ejBoss = encName, ejEncounterID = encID },
        },
    }
end

function Database:PopulateDynamicBosses()
    RemoveEntriesByCategory("Boss")
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

                    AddBossEntry(tier, isRaid, instID, instName, encName, encID, getCreatureInfo)
                    encIdx = encIdx + 1
                end

                idx = idx + 1
            end
        end
    end

    if savedTier and selectTier then selectTier(savedTier) end
    if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
end

function Database:PopulateDynamicBossesAsync(done)
    if not C_Timer or not C_Timer.After then
        self:PopulateDynamicBosses()
        done(true)
        return
    end

    RemoveEntriesByCategory("Boss")
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

    local function finish(changed, err)
        if savedTier and selectTier then selectTier(savedTier) end
        if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
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
                    AddBossEntry(state.tier, isRaid, state.instID, state.instName, encName, encID, getCreatureInfo)
                    state.encIdx = state.encIdx + 1
                    processed = processed + 1
                end
            end

            if debugprofilestop and (debugprofilestop() - start) >= budgetMs then
                C_Timer.After(0, function()
                    local ok, err = xpcall(step, Utils.ErrorHandler)
                    if not ok then finish(false, err) end
                end)
                return
            end
        end

        finish(true)
    end

    C_Timer.After(0, function()
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

        local nameLower = slower(name)
        local kw = { "talent", "talents", "spec", nameLower }
        uiSearchData[#uiSearchData + 1] = {
            name = name,
            nameLower = nameLower,
            keywords = kw,
            keywordsLower = kw,
            category = "Talent",
            icon = icon,
            spellID = spellID,
            spellName = name,
            talentConfigID = configID,
            talentTreeID = treeID,
            talentNodeID = nodeID,
            talentEntryID = entryID,
            talentIsChoice = isChoice or false,
            talentIsAllocated = isAllocated and true or false,
            buttonFrame = "PlayerSpellsMicroButton",
            path = { "Talents" },
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 2 },
                { talentNodeID = nodeID, talentTreeID = treeID },
            },
        }
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
    local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getNumSlots or not getItemInfo then return false end

    local nonEquipLocs = {
        INVTYPE_NON_EQUIP = true,
        INVTYPE_NON_EQUIP_IGNORE = true,
        INVTYPE_AMMO = true,
        INVTYPE_QUIVER = true,
    }
    local equipLocs = {
        INVTYPE_HEAD = true,
        INVTYPE_NECK = true,
        INVTYPE_SHOULDER = true,
        INVTYPE_BODY = true,
        INVTYPE_CHEST = true,
        INVTYPE_ROBE = true,
        INVTYPE_WAIST = true,
        INVTYPE_LEGS = true,
        INVTYPE_FEET = true,
        INVTYPE_WRIST = true,
        INVTYPE_HAND = true,
        INVTYPE_FINGER = true,
        INVTYPE_TRINKET = true,
        INVTYPE_CLOAK = true,
        INVTYPE_WEAPON = true,
        INVTYPE_SHIELD = true,
        INVTYPE_2HWEAPON = true,
        INVTYPE_WEAPONMAINHAND = true,
        INVTYPE_WEAPONOFFHAND = true,
        INVTYPE_HOLDABLE = true,
        INVTYPE_RANGED = true,
        INVTYPE_RANGEDRIGHT = true,
        INVTYPE_THROWN = true,
        INVTYPE_RELIC = true,
        INVTYPE_TABARD = true,
        INVTYPE_BAG = true,
        INVTYPE_PROFESSION_TOOL = true,
        INVTYPE_PROFESSION_GEAR = true,
    }
    local function isRealEquipLoc(equipLoc)
        return type(equipLoc) == "string"
            and equipLocs[equipLoc] == true
            and not nonEquipLocs[equipLoc]
    end
    local function getEquipLoc(itemID)
        if not getItemInfoInstant then return nil end
        local info, _, _, equipLoc = getItemInfoInstant(itemID)
        if type(info) == "table" then
            return info.itemEquipLoc or info.equipLoc or info.inventoryType
        end
        return equipLoc
    end

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
        local name = info.link and info.link:match("%[(.-)%]") or (GetItemInfo and GetItemInfo(itemID)) or ("Item " .. itemID)
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
            keywordsLower = kw,
            category = "Bag",
            icon = info.texture,
            itemID = itemID,
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
    wipe(outfitEntries)
end

function Database:_ResetHeavyProviderCaches()
    wipe(lootEntries)
    wipe(lootItemCache)
    wipe(lootSpecsScanned)
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
    for w in nameLower:gmatch("[%w']+") do
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
        flashLabel = opts.flashLabel,
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
            and { "Achievements", "Guild Achievements" }
            or { "Achievements", "Personal Achievements" }

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
            flashLabel   = "Achievements",
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

function Database:PopulateDynamicStatisticsAsync(done)
    if not GetStatisticsCategoryList or not GetCategoryInfo
       or not C_Timer or not C_Timer.After then
        local ok = self:PopulateDynamicStatistics()
        done(ok)
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

    -- Per-category setup built once per category and shared via __index proto
    -- so each row only stores its unique fields (name, statisticID, steps).
    local STAT_KEYWORDS_EMPTY = {}
    local queue = {}

    local function enqueueCategory(cat, parentChain)
        local stepsPrefix = {
            { buttonFrame = "AchievementMicroButton" },
            { waitForFrame = "AchievementFrame", tabIndex = 3 },
        }
        local path = { "Achievements", "Statistics" }
        for i = 1, #parentChain do
            local parent = parentChain[i]
            local pn = parent.name
            stepsPrefix[#stepsPrefix + 1] = {
                waitForFrame = "AchievementFrame",
                statisticsCategory = pn,
                statisticsCategoryID = parent.id,
            }
            path[#path + 1] = pn
        end
        stepsPrefix[#stepsPrefix + 1] = {
            waitForFrame = "AchievementFrame",
            statisticsCategory = cat.name,
            statisticsCategoryID = cat.id,
        }
        path[#path + 1] = cat.name

        local proto = {
            category      = "Statistic",
            buttonFrame   = "AchievementMicroButton",
            flashLabel    = "Statistics",
            keywords      = STAT_KEYWORDS_EMPTY,
            keywordsLower = STAT_KEYWORDS_EMPTY,
            path          = path,
        }
        local protoMT = { __index = proto }
        local prefixLen = #stepsPrefix

        if GetCategoryNumAchievements then
            local total = GetCategoryNumAchievements(cat.id) or 0
            if total == 0 and #cat.children == 0 then
                total = GetCategoryNumAchievements(cat.id, true) or 0
            end
            for i = 1, total do
                queue[#queue + 1] = {
                    catID = cat.id, rowIndex = i,
                    stepsPrefix = stepsPrefix, prefixLen = prefixLen,
                    protoMT = protoMT,
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
        local stepsPrefix = item.stepsPrefix
        local steps = {}
        for s = 1, item.prefixLen do steps[s] = stepsPrefix[s] end
        steps[item.prefixLen + 1] = {
            waitForFrame = "AchievementFrame",
            statisticID = id,
            statisticName = title,
        }
        local entry = setmetatable({
            name = title,
            nameLower = slower(title),
            statisticID = id,
            steps = steps,
        }, item.protoMT)
        uiSearchData[#uiSearchData + 1] = entry
    end

    local BUDGET_MS = 2
    local cursor = 1
    local function step()
        if myGen ~= statsScanGeneration then
            done(false, "cancelled")
            return
        end
        local startMs = debugprofilestop and debugprofilestop() or 0
        while cursor <= #queue do
            processRow(queue[cursor])
            cursor = cursor + 1
            if debugprofilestop and (debugprofilestop() - startMs) > BUDGET_MS then
                C_Timer.After(0, step)
                return
            end
        end
        -- Refresh achievements so the full stat row-ID set is available
        -- as a backup to the live category-tree filter.
        Database.statisticsComplete = true
        Database.statisticsVersion = Database.statisticsVersion + 1
        if Database.RefreshDynamicCategory then
            Database:RefreshDynamicCategory("achievements")
        end
        done(true)
    end
    step()
end

function Database:PopulateDynamicStatistics()
    if not GetStatisticsCategoryList or not GetCategoryInfo then return false end
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

    -- Sync fallback path for environments without C_Timer.
    local seenStatisticIDs = {}
    local function emit(cat, parentChain)
        local baseSteps = {
            { buttonFrame = "AchievementMicroButton" },
            { waitForFrame = "AchievementFrame", tabIndex = 3 },
        }
        local pathBase = { "Achievements", "Statistics" }
        for i = 1, #parentChain do
            local parent = parentChain[i]
            local pn = parent.name
            baseSteps[#baseSteps + 1] = {
                waitForFrame = "AchievementFrame",
                statisticsCategory = pn,
                statisticsCategoryID = parent.id,
            }
            pathBase[#pathBase + 1] = pn
        end
        baseSteps[#baseSteps + 1] = {
            waitForFrame = "AchievementFrame",
            statisticsCategory = cat.name,
            statisticsCategoryID = cat.id,
        }
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
                        local steps = {}
                        for s = 1, #baseSteps do steps[s] = baseSteps[s] end
                        -- Leaf step must be ONLY statisticID + statisticName.
                        -- Including statisticsCategory here lets that handler
                        -- match first (it runs before statisticID) and cancel
                        -- the guide since the category is already selected.
                        steps[#steps + 1] = {
                            waitForFrame = "AchievementFrame",
                            statisticID = id,
                            statisticName = title,
                        }
                        local path = {}
                        for p = 1, #pathBase do path[p] = pathBase[p] end
                        local entry = buildCategoryEntry({
                            displayName  = title,
                            categoryName = title,
                            category     = "Statistic",
                            path         = path,
                            steps        = steps,
                            flashLabel   = "Statistics",
                        })
                        entry.statisticID = id
                        uiSearchData[#uiSearchData + 1] = entry
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
    return true
end

-- Children inherit buttonFrame/category and accumulate path + steps.
function Database:FlattenTree(tree, parentPath, parentSteps, parentButtonFrame, parentCategory)
    parentPath = parentPath or {}
    parentSteps = parentSteps or {}

    for _, node in ipairs(tree) do
        local myButtonFrame = node.buttonFrame or parentButtonFrame
        local myCategory = node.category or parentCategory

        -- Reuse parent array when node adds nothing.
        local mySteps
        if node.steps then
            mySteps = {}
            for _, s in ipairs(parentSteps) do mySteps[#mySteps + 1] = s end
            for _, s in ipairs(node.steps) do mySteps[#mySteps + 1] = s end
        else
            mySteps = parentSteps
        end

        -- path = parent names leading here, NOT including self.
        local entry = {
            name = node.name,
            keywords = node.keywords or {},
            category = myCategory,
            buttonFrame = myButtonFrame,
            path = {},
            steps = mySteps,
        }
        for i = 1, #parentPath do entry.path[i] = parentPath[i] end
        if node.flashLabel then entry.flashLabel = node.flashLabel end
        if node.icon then entry.icon = node.icon end
        if node.available then entry.available = node.available end
        if node.canQueue then entry.canQueue = true end
        if node.slashCommand then entry.slashCommand = node.slashCommand end

        uiSearchData[#uiSearchData + 1] = entry

        if node.children then
            local childPath = {}
            for i = 1, #parentPath do childPath[i] = parentPath[i] end
            childPath[#childPath + 1] = node.name
            self:FlattenTree(node.children, childPath, mySteps, myButtonFrame, myCategory)
        end
    end
end

function Database:BuildUIDatabase()
    -- Each node: { name, keywords, [category], [buttonFrame], [steps], [children] }
    -- category and buttonFrame inherit from parent; steps prepends parent steps;
    -- path is auto-built from ancestor names.
    local uiTree = {

        {
            name = "Character Info",
            keywords = {"character", "char", "attributes"},
            category = "Menu Bar",
            buttonFrame = "CharacterMicroButton",
            steps = {{ buttonFrame = "CharacterMicroButton" }},
            children = {
                {
                    name = "Character Stats",
                    keywords = {"character stats", "character sheet", "paperdoll", "equipment", "gear stats", "item level"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 1 },
                    },
                },
                {
                    name = "Titles",
                    keywords = {"titles", "title", "name title"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 2 },
                    },
                },
                {
                    name = "Equipment Manager",
                    keywords = {"equipment manager", "gear sets", "equipment sets", "outfitter", "save gear", "load gear", "gear manager"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 1 },
                        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 3 },
                    },
                },
                {
                    name = "Reputation",
                    keywords = {"reputation", "rep", "faction", "factions", "standing", "renown"},
                    category = "Character Info",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 2 },
                    },
                },
                {
                    name = "Currency",
                    keywords = {"currency", "currencies", "tokens", "money"},
                    category = "Character Info",
                    flashLabel = "Currency",
                    steps = {
                        { waitForFrame = "CharacterFrame", tabIndex = 3 },
                    },
                },
            },
        },

        {
            name = "Professions",
            keywords = {"professions", "profession", "crafting", "trade skills", "skills"},
            category = "Menu Bar",
            buttonFrame = "ProfessionMicroButton",
            steps = {{ buttonFrame = "ProfessionMicroButton" }},
        },

        {
            name = "Talents & Spellbook",
            keywords = {"talents and spellbook", "class abilities"},
            category = "Menu Bar",
            buttonFrame = "PlayerSpellsMicroButton",
            steps = {{ buttonFrame = "PlayerSpellsMicroButton" }},
            children = {
                {
                    name = "Specialization",
                    keywords = {"specialization", "spec", "class spec", "change spec", "switch spec"},
                    category = "Talents",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 1 }},
                },
                {
                    name = "Talents",
                    keywords = {"talent tree", "talent points", "class talents", "hero talents", "talents"},
                    category = "Talents",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 2 }},
                    children = {
                        {
                            name = "PvP Talents",
                            keywords = {"pvp talents", "pvp abilities", "battleground talents", "pvp"},
                            steps = {{ waitForFrame = "PlayerSpellsFrame", regionFrames = { "FIND_PVP_TALENTS" }, text = "PvP Talents are at the bottom right of the Talents pane" }},
                        },
                        {
                            name = "War Mode",
                            keywords = {"war mode", "warmode", "pvp toggle", "world pvp", "pvp on", "pvp off", "pvp"},
                            steps = {{ waitForFrame = "PlayerSpellsFrame", regionFrames = { "PlayerSpellsFrame.TalentsFrame.WarmodeButton" } }},
                        },
                    },
                },
                {
                    name = "Spellbook",
                    keywords = {"spellbook", "spells", "abilities", "skills", "spell book"},
                    category = "Talents",
                    steps = {{ waitForFrame = "PlayerSpellsFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = "Achievements",
            keywords = {"achievement", "achievements", "achieve", "points"},
            category = "Menu Bar",
            buttonFrame = "AchievementMicroButton",
            steps = {{ buttonFrame = "AchievementMicroButton" }},
            children = {
                {
                    name = "Achievements Tab",
                    keywords = {"achievements", "achievement tab", "personal achievements"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 1 }},
                },

                {
                    name = "Statistics",
                    keywords = {"statistics", "stats tab", "player statistics"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = "Quest Log",
            keywords = {"quest", "quests", "objectives", "log", "journal"},
            category = "Menu Bar",
            buttonFrame = "QuestLogMicroButton",
            steps = {{ buttonFrame = "QuestLogMicroButton" }},
        },

        {
            name = "Housing Dashboard",
            keywords = {"housing", "house", "home", "dashboard", "player housing"},
            category = "Menu Bar",
            buttonFrame = "HousingMicroButton",
            steps = {{ buttonFrame = "HousingMicroButton" }},
        },

        {
            name = "Guild & Communities",
            keywords = {"guild", "communities", "social", "clan"},
            category = "Menu Bar",
            buttonFrame = "GuildMicroButton",
            steps = {{ buttonFrame = "GuildMicroButton" }},
        },

        {
            name = "Group Finder",
            keywords = {"lfg", "lfd", "lfr", "finder", "queue", "group finder"},
            category = "Menu Bar",
            buttonFrame = "LFDMicroButton",
            steps = {{ buttonFrame = "LFDMicroButton" }},
            children = {
                {
                    name = "Dungeons & Raids",
                    keywords = {"dungeons", "raids", "dungeons and raids"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 1 }},
                    children = {
                        { name = "Dungeon Finder", keywords = {"dungeon finder", "lfd", "random dungeon", "heroic dungeon", "normal dungeon", "dungeon queue"}, canQueue = true, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 1 }} },
                        { name = "Raid Finder", keywords = {"raid finder", "lfr", "looking for raid", "raid queue", "random raid"}, canQueue = true, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 2 }} },
                        {
                            name = "Premade Groups (PvE)",
                            keywords = {"premade", "premade groups", "custom group", "find group", "make group", "list group"},
                            steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }},
                            children = {
                                { name = "Questing (Premade)", keywords = {"questing", "quest", "quest group", "quest lfg", "find quest group", "premade questing"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Questing", text = "Select Questing from the Premade Groups list" }} },
                                { name = "Delves (Premade)", keywords = {"delves", "delve group", "delve lfg", "find delve group", "premade delves", "delve"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Delves", text = "Select Delves from the Premade Groups list" }} },
                                { name = "Dungeons (Premade)", keywords = {"dungeons", "dungeon group", "dungeon lfg", "find dungeon group", "premade dungeons", "m+ group", "mythic group"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Dungeons", text = "Select Dungeons from the Premade Groups list" }} },
                                { name = "Raids - The War Within (Premade)", keywords = {"raids", "raids the war within", "raid group", "raid lfg", "find raid group", "premade raids", "tww raid", "war within raid", "nerub-ar", "liberation of undermine"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Raids - The War Within", text = "Select Raids - The War Within from the Premade Groups list" }} },
                                { name = "Raids - Legacy (Premade)", keywords = {"raids", "raids legacy", "legacy raid", "old raid", "legacy raid group", "legacy lfg", "transmog raid", "tmog raid", "mount run"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Raids - Legacy", text = "Select Raids - Legacy from the Premade Groups list" }} },
                                { name = "Custom PvE Group", keywords = {"custom", "custom pve", "custom group", "custom lfg", "pve custom"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Custom", text = "Select Custom from the Premade Groups list" }} },
                            },
                        },
                    },
                },

                {
                    name = "Player vs. Player",
                    keywords = {"pvp", "player vs player", "battleground", "arena", "bg"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 2 }},
                    children = {
                        {
                            name = "Quick Match",
                            keywords = {"quick match", "random bg", "random battleground", "casual pvp", "unrated", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 1 }},
                            children = {
                                { name = "Arena Skirmish", keywords = {"arena skirmish", "skirmish", "unrated arena", "casual arena", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.Arena1Button", "HonorFrame.ArenaSkirmish"}, searchButtonText = "Arena Skirmish", text = "Select Arena Skirmish from the list" }} },
                                { name = "Random Battleground", keywords = {"random bg", "random battleground", "casual bg", "unrated bg", "battleground"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.RandomBGButton", "HonorFrame.RandomBG"}, searchButtonText = "Random Battlegrounds", text = "Select Random Battlegrounds from the list" }} },
                                { name = "Random Epic Battleground", keywords = {"random epic bg", "random epic battleground", "epic bg", "epic battleground", "ashran", "alterac", "isle of conquest"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.RandomEpicBGButton", "HonorFrame.RandomEpicBG"}, searchButtonText = "Random Epic Battlegrounds", text = "Select Random Epic Battlegrounds from the list" }} },
                                { name = "Brawl", keywords = {"brawl", "pvp brawl", "weekly brawl", "packed house"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.BonusFrame.BrawlButton"}, searchButtonText = "Brawl", text = "Select the Brawl option from the list" }} },
                            },
                        },
                        {
                            name = "Rated",
                            keywords = {"rated", "rated pvp", "conquest", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 2 }},
                            children = {
                                { name = "Solo Shuffle", keywords = {"solo shuffle", "shuffle", "solo arena", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedSoloShuffle"}, searchButtonText = "Solo Arena", text = "Solo Shuffle is the first option in the Rated panel" }} },
                                { name = "2v2 Arena", keywords = {"2v2", "2s", "twos", "2v2 arena", "two vs two", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena2v2"}, searchButtonText = "2v2", text = "2v2 Arena is in the Rated panel" }} },
                                { name = "3v3 Arena", keywords = {"3v3", "3s", "threes", "3v3 arena", "three vs three", "arena"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena3v3"}, searchButtonText = "3v3", text = "3v3 Arena is in the Rated panel" }} },
                                { name = "Rated Battlegrounds", keywords = {"rbg", "rated bg", "rated battleground", "rated battlegrounds", "10v10", "ten vs ten"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBG"}, text = "Rated Battlegrounds is in the Rated panel" }} },
                                { name = "Solo Battlegrounds (Blitz)", keywords = {"solo bg", "solo battleground", "solo battlegrounds", "battleground", "blitz", "battleground blitz"}, category = "PvP", canQueue = true, steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBGBlitz"}, searchButtonText = "Solo Battlegrounds", text = "Solo Battlegrounds (Blitz) is in the Rated panel" }} },
                            },
                        },
                        {
                            name = "Premade Groups (PvP)",
                            keywords = {"pvp premade", "pvp groups", "bg group", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }},
                            children = {
                                { name = "Arenas (Premade)", keywords = {"arena premade", "arena group", "arena lfg", "find arena", "arena"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Arenas", text = "Select Arenas from the Premade Groups list" }} },
                                { name = "Arena Skirmishes (Premade)", keywords = {"arena skirmish premade", "skirmish group", "skirmish lfg", "skirmish"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Arena Skirmishes", text = "Select Arena Skirmishes from the Premade Groups list" }} },
                                { name = "Battlegrounds (Premade)", keywords = {"bg premade", "battleground group", "bg lfg", "find bg", "battleground"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Battlegrounds", text = "Select Battlegrounds from the Premade Groups list" }} },
                                { name = "Rated Battlegrounds (Premade)", keywords = {"rated bg premade", "rbg premade", "rbg group", "rbg lfg", "rated battleground"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Rated Battlegrounds", text = "Select Rated Battlegrounds from the Premade Groups list" }} },
                                { name = "Custom PvP Group", keywords = {"custom pvp", "custom group", "custom lfg", "pvp custom", "custom"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Custom", text = "Select Custom from the Premade Groups list" }} },
                            },
                        },
                        {
                            name = "Training Grounds",
                            keywords = {"training", "training grounds", "practice", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 4 }},
                            children = {
                                { name = "Random Battlegrounds (Training Grounds)", keywords = {"random bg", "random battleground", "random battlegrounds", "training battleground", "bonus battleground"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"TrainingGroundsFrame.BonusTrainingGroundList.RandomTrainingGroundButton"}, searchButtonText = "Random Battlegrounds", text = "Select Random Battlegrounds in Training Grounds" }} },
                            },
                        },
                    },
                },

                {
                    name = "Mythic+ Dungeons",
                    keywords = {"mythic", "mythic+", "m+", "keystone", "mythic plus", "keys"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 3 }},
                },
            },
        },

        {
            name = "Warband Collections",
            keywords = {"collections", "warband"},
            category = "Menu Bar",
            buttonFrame = "CollectionsMicroButton",
            steps = {{ buttonFrame = "CollectionsMicroButton" }},
            children = {
                { name = "Mounts", keywords = {"mounts", "mount", "riding", "mount collection", "flying"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 1 }} },
                { name = "Pet Journal", keywords = {"pets", "pet", "battle pets", "companion", "pet collection", "critter", "pet journal"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 2 }} },
                { name = "Toy Box", keywords = {"toys", "toy", "toybox", "toy box", "fun items"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 3 }} },
                { name = "Heirlooms", keywords = {"heirlooms", "heirloom", "leveling gear", "bind on account", "boa"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 4 }} },
                { name = "Appearances (Transmog)", keywords = {"transmog", "tmog", "transmogrification", "appearance", "appearances", "wardrobe", "cosmetic", "looks", "mog"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 5, text = "Click the Appearances tab" }} },
                { name = "Campsites", keywords = {"campsites", "campsite", "camp", "camping", "rest area"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 6 }} },
            },
        },

        {
            name = "Transmogrification",
            keywords = {"transmogrification", "transmog", "tmog", "mog", "wardrobe", "outfit", "outfits", "appearance", "keymog"},
            category = "Transmogrification",
            icon = { file = 6119963, coords = { 0.0183, 0.2629, 0.0131, 0.5152 } },
            steps = {{ loadTransmog = true }},
        },

        {
            name = "Adventure Guide",
            keywords = {"adventure", "guide", "dungeon journal", "encounters", "loot", "boss", "journal"},
            category = "Menu Bar",
            buttonFrame = "EJMicroButton",
            steps = {{ buttonFrame = "EJMicroButton" }},
            children = {
                { name = "Journeys", keywords = {"journeys", "journey", "adventure journeys"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 1, text = "Click the Journeys tab" }}, children = {
                    { name = "Great Vault (Rewards)", keywords = {"great vault", "vault", "weekly rewards", "weekly chest", "rewards"}, category = "Adventure Guide", icon = { file = 1121272, coords = { 0.2007, 0.2407, 0.5456, 0.5862 } }, steps = {{ buttonFrame = "EncounterJournalInstanceSelect.GreatVaultButton" }} },
                }},
                { name = "Traveler's Log", keywords = {"traveler", "travelers log", "traveler log", "travel log"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 2, text = "Click the Traveler's Log tab" }} },
                { name = "Suggested Content", keywords = {"suggested", "suggested content", "recommendations"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 3, text = "Click the Suggested Content tab" }} },
                { name = "Dungeons (Journal)", keywords = {"dungeon journal", "dungeon guide", "dungeon encounters", "dungeon bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 4, text = "Click the Dungeons tab" }} },
                { name = "Raids (Journal)", keywords = {"raid journal", "raid guide", "raid encounters", "raid bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 5, text = "Click the Raids tab" }} },
                { name = "Item Sets", keywords = {"item sets", "tier sets", "set bonuses", "class sets"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 6, text = "Click the Item Sets tab" }} },
                { name = "Tutorials", keywords = {"tutorials", "tutorial", "help guide", "how to"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 7, text = "Click the Tutorials tab" }} },
            },
        },

        -- /click routes through secure dispatch so the micro button's OnClick
        -- fires from a hardware event; ToggleGameMenu's ClearTarget needs that.
        -- /run ShowUIPanel(GameMenuFrame) here forbid-errors on ClearTarget.
        {
            name = "Game Menu",
            keywords = {"menu", "settings", "options", "escape", "esc", "logout", "quit", "exit", "interface"},
            category = "Menu Bar",
            buttonFrame = "MainMenuMicroButton",
            slashCommand = "/click MainMenuMicroButton",
        },
        {
            name = "Help",
            keywords = {"help", "support", "ticket", "bug", "report", "gm"},
            category = "Menu Bar",
            buttonFrame = "HelpMicroButton",
            steps = {{ buttonFrame = "HelpMicroButton" }},
        },
        {
            name = "Shop",
            keywords = {"shop", "store", "blizzard shop", "cash shop", "buy", "purchase", "micro transaction"},
            category = "Menu Bar",
            buttonFrame = "StoreMicroButton",
            steps = {{ buttonFrame = "StoreMicroButton" }},
            children = {
                { name = "Shop Appearances", keywords = {"transmog", "tmog", "appearance"}, category = "Shop", steps = {{ waitForFrame = "StoreFrame", text = "Browse the Appearances section in the shop" }} },
            },
        },

        {
            name = "Portrait Menu",
            keywords = {"portrait", "portrait menu", "right click portrait", "player frame menu"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            steps = {{ portraitMenu = true }},
            children = {
                { name = "Set Focus", keywords = {"set focus", "focus target", "focus frame", "focus"}, steps = {{ portraitMenuOption = "Set Focus" }} },
                { name = "Self Highlight", keywords = {"self highlight", "highlight self", "outline", "self outline"}, steps = {{ portraitMenuOption = "Self Highlight" }} },
                { name = "Target Marker Icon", keywords = {"target marker", "raid marker", "skull", "cross", "star", "moon", "marker icon", "raid icon", "world marker"}, steps = {{ portraitMenuOption = "Target Marker Icon" }} },
                { name = "Loot Specialization", keywords = {"loot spec", "loot specialization", "loot preference"}, steps = {{ portraitMenuOption = "Loot Specialization" }} },
                { name = "Dungeon Difficulty", keywords = {"dungeon difficulty", "normal dungeon", "heroic dungeon", "mythic dungeon", "instance difficulty"}, steps = {{ portraitMenuOption = "Dungeon Difficulty" }} },
                { name = "Raid Difficulty", keywords = {"raid difficulty", "normal raid", "heroic raid", "mythic raid", "raid size"}, steps = {{ portraitMenuOption = "Raid Difficulty" }} },
                {
                    name = "Reset All Instances",
                    keywords = {"reset instances", "reset all instances", "instance reset", "dungeon reset"},
                    available = function()
                        local inInstance = IsInInstance()
                        if inInstance then return false end
                        if IsInGroup() and not UnitIsGroupLeader("player") then return false end
                        return true
                    end,
                    steps = {{ portraitMenuOption = "Reset All Instances" }},
                },
                { name = "Edit Mode", keywords = {"edit mode", "ui layout", "customize ui", "move frames", "hud edit", "ui editor"}, steps = {{ portraitMenuOption = "Edit Mode" }} },
                { name = "Voice Chat", keywords = {"voice chat", "voice", "voip", "talk", "microphone", "mic"}, steps = {{ portraitMenuOption = "Voice Chat" }} },
                { name = "PvP Flag", keywords = {"pvp flag", "pvp toggle", "player vs player flag", "pvp enable", "war mode"}, steps = {{ portraitMenuOption = "PvP Flag" }} },
            },
        },

        {
            name = "Bags / Inventory",
            keywords = {"bags", "bag", "inventory", "backpack", "items", "storage"},
            category = "Inventory",
            iconAtlas = "bag-main",
            steps = {{ buttonFrame = "MainMenuBarBackpackButton" }},
        },
        {
            name = "Friends List",
            keywords = {"friends", "social", "bnet", "battlenet", "contacts", "whisper", "online"},
            category = "Social",
            icon = 132175,
            steps = {{ buttonFrame = "QuickJoinToastButton" }},
        },
        {
            name = "Toggle World Map",
            keywords = {"map", "world map", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run ToggleWorldMap()",
        },
        {
            name = "Toggle Zone Map",
            keywords = {"zone map", "battlefield map", "floating map", "area map", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run C_AddOns.LoadAddOn('Blizzard_BattlefieldMap'); if BattlefieldMapFrame then BattlefieldMapFrame:SetShown(not BattlefieldMapFrame:IsShown()) end",
        },
        {
            name = "Toggle Minimap",
            keywords = {"minimap", "mini map", "tracking", "navigation", "toggle"},
            category = "Navigation",
            icon = 134269,
            slashCommand = "/run MinimapCluster:SetShown(not MinimapCluster:IsShown())",
        },
        {
            name = "Calendar",
            keywords = {"calendar", "events", "holidays", "schedule"},
            category = "Social",
            icon = 134939,
            slashCommand = "/click GameTimeFrame",
        },

        -- /dismisspet only handles hunter/warlock pets; the second line
        -- toggles the active battle-pet companion (dismissing it).
        {
            name = "Dismiss Pet",
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
            else
                item.keywordsLower = kws
            end
        end
        if not item.icon and not item.buttonFrame then
            item.icon = 134400
        end
    end

    local PVP_NAMES = {
        ["PvP Talents"] = true, ["War Mode"] = true, ["PvP Flag"] = true,
    }
    for _, item in ipairs(uiSearchData) do
        if item.category == "PvP" or PVP_NAMES[item.name]
            or sfind(item.name, "Player vs. Player", 1, true) then
            item.isPvP = true
        elseif item.path then
            for _, p in ipairs(item.path) do
                if sfind(p, "Player vs. Player", 1, true) then
                    item.isPvP = true
                    break
                end
            end
        end
        if not item.isPvP and item.path then
            local underGroupFinder = false
            for _, p in ipairs(item.path) do
                if p == "Group Finder" then underGroupFinder = true end
                if underGroupFinder and (p == "Dungeons & Raids" or p == "Mythic+ Dungeons") then
                    item.isPvE = true
                    break
                end
            end
        end
        if not item.isPvE then
            local n = item.name
            if (n == "Dungeons & Raids" or n == "Dungeon Finder" or n == "Raid Finder"
                or n == "Mythic+ Dungeons" or n == "Premade Groups (PvE)") then
                if item.path then
                    for _, p in ipairs(item.path) do
                        if p == "Group Finder" then
                            item.isPvE = true
                            break
                        end
                    end
                end
            end
        end
    end
end

-- Suppresses fuzzy/initials matches between word pairs that are close in
-- edit distance but semantically opposite.
local FUZZY_BLOCKLIST = {
    ["pvp"] = { ["pve"] = true },
    ["pve"] = { ["pvp"] = true },
    -- "ability"/"abilities" are keywords on every Ability entry; without
    -- this, typing "agility" drags every ability into results.
    ["agility"]   = { ["ability"] = true, ["abilities"] = true },
    ["ability"]   = { ["agility"] = true },
    ["abilities"] = { ["agility"] = true },
}

-- Initials Strategy 2 may step over these for free ("lfg" = Looking For
-- Group, "tot" = Throne of Thunder). Hitting a non-stopword content word
-- without matching breaks the chain so accidental letter alignment doesn't
-- score (e.g. "sound" wrongly hitting "Shurrai, Atrocity of the Undersea").
local INITIALS_STOPWORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["or"] = true, ["in"] = true, ["on"] = true,
    ["at"] = true, ["by"] = true, ["for"] = true, ["to"] = true,
    ["with"] = true, ["from"] = true,
}

function Database:FindAtWordBoundary(text, query)
    local found = sfind(text, query, 1, true)
    if not found then return false end
    if found == 1 then return true end
    -- 32=space 45=- 40=( 58=: 47=/ 46=.
    while found do
        local prev = sbyte(text, found - 1)
        if prev == 32 or prev == 45 or prev == 40
           or prev == 58 or prev == 47 or prev == 46 then
            return true
        end
        found = sfind(text, query, found + 1, true)
    end
    return false
end

function Database:ScoreInitials(text, query)
    local words = GetWords(text)
    if #words < 2 then return 0 end

    local blocked = FUZZY_BLOCKLIST[query]
    if blocked then
        for wi = 1, #words do
            if blocked[words[wi]] then return 0 end
        end
    end

    local queryLen = #query
    local numWords = #words

    -- Strategy 1: pure initials. "rb" → R(ated) B(attlegrounds).
    if queryLen <= numWords then
        local allMatch = true
        for i = 1, queryLen do
            if sbyte(query, i) ~= sbyte(words[i], 1) then
                allMatch = false
                break
            end
        end
        if allMatch then
            local bonus = (queryLen == numWords) and 135 or 130
            return bonus
        end
    end

    -- Strategy 2: greedy word-prefix walk. "raba" → ra(ndom) ba(ttleground).
    -- Stopwords may be skipped (so "tot" → Throne Of Thunder works).
    local qi = 1
    local wordsMatched = 0
    for wi = 1, numWords do
        if qi > queryLen then break end
        local w = words[wi]
        local matchLen = 0
        while qi + matchLen <= queryLen and matchLen < #w do
            if sbyte(query, qi + matchLen) == sbyte(w, matchLen + 1) then
                matchLen = matchLen + 1
            else
                break
            end
        end
        if matchLen > 0 then
            qi = qi + matchLen
            wordsMatched = wordsMatched + 1
        elseif wordsMatched > 0 and not INITIALS_STOPWORDS[w] then
            break
        end
    end
    if qi > queryLen and wordsMatched >= 2 then
        return 110 + mmin(wordsMatched * 3, 20)
    end

    return 0
end

function Database:ScoreFuzzy(text, query, queryLen)
    -- Length-scaled typo budget (1 edit per ~4 chars). Without this,
    -- "skull" fuzzy-matches "spell" and similar unrelated 40%-diff words.
    local maxEdits
    if queryLen >= 8 then maxEdits = 2
    elseif queryLen >= 4 then maxEdits = 1
    else return 0
    end

    local queryFirst = sbyte(query, 1)
    local bestScore = 0
    local blocked = FUZZY_BLOCKLIST[query]
    local textWords = GetWords(text)
    for wi = 1, #textWords do
        local word = textWords[wi]
        -- First-letter must match: typos rarely hit the first char.
        if sbyte(word, 1) == queryFirst
           and not (blocked and blocked[word]) then
            local wordLen = #word
            local lenDiff = wordLen - queryLen
            if lenDiff < 0 then lenDiff = -lenDiff end
            if lenDiff <= maxEdits then
                local dist = Database:DamerauLevenshtein(query, word, queryLen, wordLen)
                if dist == 1 and maxEdits >= 1 then
                    bestScore = mmax(bestScore, 85)
                elseif dist == 2 and maxEdits >= 2 then
                    bestScore = mmax(bestScore, 45)
                end
            end
        end
    end
    return bestScore
end

-- First-char constraint avoids spurious hits like "ahn'" in "magtheridon's".
function Database:IsSubsequence(word, query, queryLen)
    if sbyte(word, 1) ~= sbyte(query, 1) then return false end
    local wi = 1
    local wordLen = #word
    local firstPos
    for qi = 1, queryLen do
        local qc = sbyte(query, qi)
        local found = false
        while wi <= wordLen do
            if sbyte(word, wi) == qc then
                if not firstPos then firstPos = wi end
                wi = wi + 1
                found = true
                break
            end
            wi = wi + 1
        end
        if not found then return false end
    end
    -- Reject sparse matches: "inn" in "instance" hits i(1)n(2)n(6), span 6 > 5.
    return (wi - 1) - firstPos + 1 <= queryLen * 2 - 1
end

-- Damerau-Levenshtein with transpositions, capped at 2.
function Database:DamerauLevenshtein(s1, s2, len1, len2)
    if mabs(len1 - len2) > 2 then return 3 end

    local prev2, prev, curr = dlPrev2, dlPrev, dlCurr

    for j = 0, len2 do prev[j] = j end

    for i = 1, len1 do
        curr[0] = i
        local minInRow = i
        local c1 = sbyte(s1, i)
        local c1Prev = i > 1 and sbyte(s1, i - 1) or nil
        for j = 1, len2 do
            local c2 = sbyte(s2, j)
            local cost = (c1 == c2) and 0 or 1
            curr[j] = mmin(
                prev[j] + 1,
                curr[j - 1] + 1,
                prev[j - 1] + cost
            )
            if i > 1 and j > 1
                and c1 == sbyte(s2, j - 1)
                and c1Prev == c2 then
                curr[j] = mmin(curr[j], prev2[j - 2] + cost)
            end
            if curr[j] < minInRow then minInRow = curr[j] end
        end
        if minInRow > 2 then return 3 end
        prev2, prev, curr = prev, curr, prev2
    end
    return prev[len2]
end

-- Fast pre-filter: every distinct char in query must appear somewhere in text.
local reuseCouldMatchSet = {}
function Database:CouldMatch(text, query)
    local tlen, qlen = #text, #query
    if qlen == 0 then return true end
    if tlen == 0 then return false end
    local seen = reuseCouldMatchSet
    for k in pairs(seen) do seen[k] = nil end
    for i = 1, tlen do
        seen[text:byte(i)] = true
    end
    for i = 1, qlen do
        local qb = query:byte(i)
        if qb ~= 32 and not seen[qb] then
            return false
        end
    end
    return true
end

-- exact → starts-with → word-boundary → substring → initials → fuzzy.
function Database:ScoreName(nameLower, query, queryLen, optQueryWords)
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    if not Database:CouldMatch(nameLower, query) then return 0 end

    local score = 0

    if nameLower == query then
        score = 200
    elseif sfind(nameLower, query, 1, true) == 1 then
        score = 150
    elseif Database:FindAtWordBoundary(nameLower, query) then
        score = 120
    elseif sfind(nameLower, query, 1, true) then
        score = 30
    end

    if score < 130 then
        local initScore = Database:ScoreInitials(nameLower, query)
        if initScore > score then score = initScore end
    end

    if score < 100 and queryLen >= 4 then
        local fuzzyScore = Database:ScoreFuzzy(nameLower, query, queryLen)
        if fuzzyScore > score then score = fuzzyScore end
    end

    -- Vowel-stripped abbreviations: "qtr" → quartermaster, "windrnr" → windrunner.
    if score < 50 and queryLen >= 3 and not sfind(query, " ", 1, true) then
        local nameWords = GetWords(nameLower)
        for wi = 1, #nameWords do
            local word = nameWords[wi]
            local wordLen = #word
            if queryLen <= 4 then
                if wordLen >= queryLen * 2 and Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 55)
                    break
                end
            elseif queryLen <= 8 and wordLen > queryLen and queryLen / wordLen >= 0.6 then
                if Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 60)
                    break
                end
            end
        end
    end

    -- Multi-word query: all words must match. Fires even after an inferior
    -- low-score path so "estern kingd" → "Eastern Kingdoms" can still surface.
    if score < 100 and sfind(query, " ", 1, true) then
        local queryWords = optQueryWords
        if not queryWords then
            queryWords = {}
            for w in query:gmatch("%S+") do
                queryWords[#queryWords + 1] = w
            end
        end
        if #queryWords >= 2 then
            local nameWords = GetWords(nameLower)
            local allMatched = true
            local totalWordScore = 0
            wipe(scoreNameUsedWords)
            local usedNameWords = scoreNameUsedWords
            for qwi = 1, #queryWords do
                local qw = queryWords[qwi]
                local qwLen = #qw
                local bestWordScore = 0
                local bestIdx = 0
                for ni = 1, #nameWords do
                    if not usedNameWords[ni] then
                        local nw = nameWords[ni]
                        local ws = 0
                        if nw == qw then
                            ws = 100
                        elseif sfind(nw, qw, 1, true) == 1 then
                            ws = 90
                        elseif sfind(nw, qw, 1, true) then
                            ws = 50
                        elseif qwLen >= 4 and sbyte(nw, 1) == sbyte(qw, 1) then
                            local nwLen = #nw
                            local maxEdits = qwLen >= 8 and 2 or 1
                            if nwLen >= qwLen - maxEdits and nwLen <= qwLen + maxEdits then
                                local dist = Database:DamerauLevenshtein(qw, nw, qwLen, nwLen)
                                if dist == 1 then
                                    ws = 75
                                elseif dist == 2 and maxEdits >= 2 then
                                    ws = 40
                                end
                            end
                            if ws == 0 and qwLen <= 8 and nwLen > qwLen and qwLen / nwLen >= 0.6 then
                                if Database:IsSubsequence(nw, qw, qwLen) then
                                    ws = 45
                                end
                            end
                        elseif qwLen == 3 then
                            local nwLen = #nw
                            if nwLen >= qwLen * 2 and Database:IsSubsequence(nw, qw, qwLen) then
                                ws = 45
                            end
                        end
                        if ws > bestWordScore then
                            bestWordScore = ws
                            bestIdx = ni
                        end
                    end
                end
                if bestWordScore > 0 then
                    usedNameWords[bestIdx] = true
                    totalWordScore = totalWordScore + bestWordScore
                else
                    allMatched = false
                    break
                end
            end
            if allMatched then
                local avgScore = totalWordScore / #queryWords
                local wordScore = mmin(110, avgScore)
                if wordScore > score then score = wordScore end
            end
        end
    end

    return score
end

function Database:ScoreKeywords(keywordsLower, query, queryLen, optQueryWords)
    if not keywordsLower then return 0 end

    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    local queryWords = optQueryWords
    if not queryWords then
        queryWords = {}
        for word in query:gmatch("%S+") do
            queryWords[#queryWords + 1] = word
        end
    end

    -- Single-word: take BEST kw match, not sum. Summing let items with
    -- redundant keywords ("reputation" + "reputation achievements") beat
    -- items with a better name match.
    local numKeywords = #keywordsLower
    if #queryWords == 1 then
        local best = 0
        for ki = 1, numKeywords do
            local kw = keywordsLower[ki]
            local kwScore = 0
            if kw == query then
                -- Short abbreviations (2-3 chars) get boosted above initials.
                kwScore = queryLen <= 3 and 140 or 80
            elseif sfind(kw, query, 1, true) == 1 then
                kwScore = 70
            elseif Database:FindAtWordBoundary(kw, query) then
                kwScore = 55
            end
            if kwScore < 60 and queryLen >= 3 then
                local initScore = Database:ScoreInitials(kw, query)
                if initScore > 0 then
                    local penalty = queryLen == 3 and 70 or 20
                    kwScore = mmax(kwScore, initScore - penalty)
                end
            end
            if kwScore < 40 and queryLen >= 4 then
                local kf = Database:ScoreFuzzy(kw, query, queryLen)
                if kf > 0 then kwScore = mmax(kwScore, kf) end
            end
            if kwScore < 50 and queryLen >= 3 then
                local kwWords = GetWords(kw)
                for kwi = 1, #kwWords do
                    local kwWord = kwWords[kwi]
                    local kwWordLen = #kwWord
                    if queryLen <= 4 and kwWordLen >= queryLen * 2 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 60)
                            break
                        end
                    elseif queryLen <= 8 and kwWordLen > queryLen and queryLen / kwWordLen >= 0.6 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 55)
                            break
                        end
                    end
                end
            end
            if kwScore > best then best = kwScore end
        end
        return best
    end

    -- Multi-word: all words >= 2 chars must match. Single-char words are
    -- SKIPPED (not failed) so mid-type queries like "feral a" don't empty
    -- prevCandidates and silently kill the next "feral abil" extension.
    local total = 0
    for qwi = 1, #queryWords do
        local queryWord = queryWords[qwi]
        local queryWordLen = #queryWord
        local bestScore = 0

        if queryWordLen >= 2 then
            for ki = 1, numKeywords do
                local kw = keywordsLower[ki]
                local kwScore = 0
                if kw == queryWord then
                    kwScore = 80
                elseif sfind(kw, queryWord, 1, true) == 1 then
                    kwScore = 70
                elseif Database:FindAtWordBoundary(kw, queryWord) then
                    kwScore = 55
                end
                if kwScore < 60 and queryWordLen >= 3 then
                    local initScore = Database:ScoreInitials(kw, queryWord)
                    if initScore > 0 then
                        local penalty = queryWordLen == 3 and 70 or 20
                        kwScore = mmax(kwScore, initScore - penalty)
                    end
                end
                if kwScore < 40 and queryWordLen >= 4 then
                    local kf = Database:ScoreFuzzy(kw, queryWord, queryWordLen)
                    if kf > 0 then kwScore = mmax(kwScore, kf) end
                end

                if kwScore > bestScore then
                    bestScore = kwScore
                end
            end
            if bestScore == 0 then
                return 0
            end
            total = total + bestScore
        end
    end

    return total
end

-- When the user extends the previous query (e.g. "mou" → "moun"), only
-- re-score entries that matched before instead of the full dataset.
local function ScoreSingleFieldWord(fieldWord, queryWord, queryWordLen)
    if fieldWord == queryWord then return 100 end
    if sfind(fieldWord, queryWord, 1, true) == 1 then return 90 end
    if fieldWord .. "s" == queryWord or queryWord .. "s" == fieldWord then return 82 end
    if sfind(fieldWord, queryWord, 1, true) then return 50 end
    if queryWordLen >= 3 then
        local fieldLen = #fieldWord
        if fieldLen > queryWordLen and queryWordLen <= 8
           and queryWordLen / fieldLen >= 0.45
           and Database:IsSubsequence(fieldWord, queryWord, queryWordLen) then
            return 55
        end
    end
    if queryWordLen >= 4 and sbyte(fieldWord, 1) == sbyte(queryWord, 1) then
        local fieldLen = #fieldWord
        local maxEdits = queryWordLen >= 8 and 2 or 1
        if fieldLen >= queryWordLen - maxEdits and fieldLen <= queryWordLen + maxEdits then
            local dist = Database:DamerauLevenshtein(fieldWord, queryWord, fieldLen, queryWordLen)
            if dist <= maxEdits then return mmax(45, 85 - dist * 20) end
        end
    end
    return 0
end

local function ScoreFieldWords(words, queryWord, queryWordLen)
    local best = 0
    for i = 1, #words do
        local score = ScoreSingleFieldWord(words[i], queryWord, queryWordLen)
        if score > best then best = score end
    end
    return best
end

function Database:ScoreEntryFields(data, queryWords)
    if not queryWords or #queryWords < 2 then return 0 end
    local total = 0
    local matched = 0
    local nameMatches = 0
    local nameWords = GetWords(data.nameLower or "")
    local keywordsLower = data.keywordsLower

    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        local qwLen = #qw
        if qwLen >= 2 or (qwLen == 1 and qi == #queryWords and matched > 0) then
            local nameBest = ScoreFieldWords(nameWords, qw, qwLen)
            local kwBest = 0
            if keywordsLower then
                for ki = 1, #keywordsLower do
                    local kw = keywordsLower[ki]
                    local kwScore = ScoreSingleFieldWord(kw, qw, qwLen)
                    if kwScore < 90 then
                        kwScore = mmax(kwScore, ScoreFieldWords(GetWords(kw), qw, qwLen))
                    end
                    if kwScore > kwBest then kwBest = kwScore end
                end
            end
            local best
            if nameBest > 0 then
                best = nameBest
                nameMatches = nameMatches + 1
            else
                best = kwBest
            end
            if best == 0 then return 0 end
            total = total + best
            matched = matched + 1
        end
    end

    if matched < 2 then return 0 end
    -- Discount pure-keyword matches: keyword sums (90/word) beat the
    -- avg-capped name-only score (110 max), so an item whose keyword list
    -- contains "Eastern Kingdoms" would outrank the actual zone.
    if nameMatches == 0 then
        total = math.floor(total * 0.45)
    end
    return total + matched * 5
end

local prevQuery = ""
local prevSkipKey = ""
local prevCandidates = {}

local prefixIndex = {}
local prefixIndexSeen = {}
local prefixIndexReady = false
local prefixCandidateBuf = {}
local prefixCandidateSeen = {}
Database._prefixIndex = prefixIndex

local function AddPrefixIndexEntry(entry, prefix)
    if prefixIndexSeen[prefix] == entry then return end
    prefixIndexSeen[prefix] = entry
    local bucket = prefixIndex[prefix]
    if not bucket then
        bucket = {}
        prefixIndex[prefix] = bucket
    end
    bucket[#bucket + 1] = entry
end

local function IndexPrefixText(entry, text)
    if not text then return end
    for word in text:gmatch("%S+") do
        local len = #word
        if len >= 1 then AddPrefixIndexEntry(entry, ssub(word, 1, 1)) end
        if len >= 2 then AddPrefixIndexEntry(entry, ssub(word, 1, 2)) end
    end
end

local function IndexPrefixList(entry, list)
    if not list then return end
    for i = 1, #list do
        local text = list[i]
        if type(text) == "string" then IndexPrefixText(entry, text) end
    end
end

function Database:BuildSearchPrefixIndex()
    wipe(prefixIndex)
    wipe(prefixIndexSeen)
    for i = 1, #uiSearchData do
        local entry = uiSearchData[i]
        IndexPrefixText(entry, entry.nameLower)
        IndexPrefixList(entry, entry.keywordsLower)
        IndexPrefixList(entry, entry.lootSlotKw)
        IndexPrefixList(entry, entry.lootStatKw)
        IndexPrefixList(entry, entry.lootSourceKw)
    end
    wipe(prefixIndexSeen)
    prefixIndexReady = true
end

function Database:WarmSearchHotPath()
    if not prefixIndexReady then
        self:BuildSearchPrefixIndex()
    end
end

local function ClearPrefixBuckets()
    wipe(prefixIndex)
    prefixIndexReady = false
end

local function GetPrefixBucket(prefix)
    return prefixIndex[prefix] or false
end

local function AddPrefixCandidateBucket(bucket)
    if not bucket then return end
    for i = 1, #bucket do
        local entry = bucket[i]
        if not prefixCandidateSeen[entry] then
            prefixCandidateSeen[entry] = true
            prefixCandidateBuf[#prefixCandidateBuf + 1] = entry
        end
    end
end

local function GetMultiTokenPrefixCandidates(queryWords)
    wipe(prefixCandidateBuf)
    wipe(prefixCandidateSeen)
    for i = 1, #queryWords do
        local word = queryWords[i]
        local len = #word
        if len >= 2 then
            AddPrefixCandidateBucket(GetPrefixBucket(ssub(word, 1, 2)))
        elseif len == 1 then
            AddPrefixCandidateBucket(GetPrefixBucket(word))
        end
    end
    wipe(prefixCandidateSeen)
    return #prefixCandidateBuf > 0 and prefixCandidateBuf or nil
end

function Database:ResetSearchCache()
    if self._dynamicBatchLoading then
        self._dynamicBatchChanged = true
        return
    end
    prevQuery = ""
    prevSkipKey = ""
    wipe(prevCandidates)
    local hadPrefixIndex = prefixIndexReady
    ClearPrefixBuckets()
    if hadPrefixIndex then self:BuildSearchPrefixIndex() end
end

local resultsBuf = {}
local resultsQueryWords = {}
local resultEntryPool = {}
Database._resultsBuf = resultsBuf
Database._resultEntryPool = resultEntryPool

function Database:TrimSearchMemory()
    self:UnloadDynamicSearchData()
    wipe(resultsBuf)
    wipe(resultsQueryWords)
    wipe(resultEntryPool)
    wipe(wordCache)
    wipe(wordCacheKeys)
    wordCacheHead = 1
    ClearPrefixBuckets()
end

function Database:SearchUI(query, skipCategories)
    if not query or query == "" or #query < 2 then
        prevQuery = ""
        wipe(prevCandidates)
        wipe(resultsBuf)
        return resultsBuf
    end

    -- Without a ready prefix index, every search linearly scans the full
    -- 1500+ entry uiSearchData each keystroke. Build once on demand.
    if not prefixIndexReady then
        self:BuildSearchPrefixIndex()
    end

    query = slower(query)
    local queryLen = #query

    -- Pre-trim trailing whitespace so scoring doesn't match() per entry.
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then prevQuery = ""; wipe(prevCandidates); wipe(resultsBuf); return resultsBuf end
    end

    wipe(resultsQueryWords)
    local queryWords = resultsQueryWords
    for w in query:gmatch("%S+") do
        queryWords[#queryWords + 1] = w
    end

    -- Gates: without "boss" in the query, bosses match name only ("icc"
    -- alone shouldn't flood with bosses). Achievements (~175 entries with
    -- broad keywords) are gated behind "ach"/"stat" or a strong name match.
    local bossQueryWord = false
    local achQueryWord = false
    local lootStatQueryWord = false
    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        if qw == "boss" or qw == "bosses" then
            bossQueryWord = true
        end
        if IsLootStatSearchWord(qw) then
            lootStatQueryWord = true
        end
        if ssub(qw, 1, 3) == "ach" or qw == "stat" or qw == "stats"
           or qw == "statistic" or qw == "statistics" then
            achQueryWord = true
        end
    end

    local skipKey = skipCategories and (
        (skipCategories["Mount"] and "M" or "") ..
        (skipCategories["Toy"] and "T" or "") ..
        (skipCategories["Pet"] and "P" or "") ..
        (skipCategories["Outfit"] and "O" or "") ..
        (skipCategories["Heirloom"] and "H" or "") ..
        (skipCategories["Loot"] and "L" or "")
    ) or ""

    -- prevCandidates can miss entries the now-more-permissive pass matches:
    --   1. A gate flipped on ("icc bos" → "icc boss"). Boss/ach entries
    --      were never scored before the flip.
    --   2. A word was appended to a stat-keyword query ("haste" →
    --      "haste ring"). Loot rings aren't in the "ha" prefix bucket
    --      (lootStatKw is enriched lazily); the "ri" bucket pulls them in.
    -- Either case bypasses extension and rebuilds via the prefix lookup.
    local prevLootStat, prevBossWord, prevAchWord = false, false, false
    local prevWordCount = 0
    if prevQuery ~= "" then
        for prevWord in prevQuery:gmatch("%S+") do
            prevWordCount = prevWordCount + 1
            if IsLootStatSearchWord(prevWord) then prevLootStat = true end
            if prevWord == "boss" or prevWord == "bosses" then
                prevBossWord = true
            end
            if ssub(prevWord, 1, 3) == "ach" or prevWord == "stat" or prevWord == "stats"
               or prevWord == "statistic" or prevWord == "statistics" then
                prevAchWord = true
            end
        end
    end
    local addedNewWord = #queryWords > prevWordCount
    local gatingShifted =
        (lootStatQueryWord and not prevLootStat)
        or (bossQueryWord and not prevBossWord)
        or (achQueryWord and not prevAchWord)
        or (lootStatQueryWord and addedNewWord)

    local searchSet
    local prevLen = #prevQuery
    if prevLen > 0 and skipKey == prevSkipKey
        and queryLen > prevLen and ssub(query, 1, prevLen) == prevQuery
        and not gatingShifted then
        searchSet = prevCandidates
    else
        if prefixIndexReady then
            if #queryWords >= 2 then
                searchSet = GetMultiTokenPrefixCandidates(queryWords)
            else
                local key2 = ssub(query, 1, 2)
                searchSet = GetPrefixBucket(key2)
                if not searchSet then
                    searchSet = GetPrefixBucket(ssub(query, 1, 1))
                end
            end
        else
            searchSet = uiSearchData
        end
        if not searchSet or #searchSet == 0 then
            wipe(resultsBuf)
            wipe(prevCandidates)
            prevQuery = query
            prevSkipKey = skipKey
            return resultsBuf
        end
    end

    wipe(resultsBuf)
    local results = resultsBuf
    local resultsN = 0
    local candidateIdx = 0

    local searchCount = #searchSet
    for i = 1, searchCount do
        local data = searchSet[i]
        if not (skipCategories and skipCategories[data.category])
           and not (data.available and not data.available()) then
            local nameLower = data.nameLower
            local score
            if data.lootEntry then
                if lootStatQueryWord and not data._statsEnriched then
                    Database:EnrichLootStats(data)
                end
                -- Each query word scores against name + slot + stats + source
                -- kws; best match wins; an unmatched word eliminates the item.
                local totalScore = 0

                local nameWords = GetWords(nameLower)
                for qi = 1, #queryWords do
                    local qw = queryWords[qi]
                    local qwLen = #qw
                    local bestWord = 0

                    -- Name match must outrank lootSourceKw (boss name) below,
                    -- else loot named for the query gets buried under same-
                    -- boss loot that only matched via the encounter name.
                    for ni = 1, #nameWords do
                        local nw = nameWords[ni]
                        if nw == qw then
                            bestWord = mmax(bestWord, qi == 1 and 130 or 120)
                        elseif ssub(nw, 1, qwLen) == qw then
                            bestWord = mmax(bestWord, qi == 1 and 115 or 105)
                        end
                    end

                    if data.lootSlotKw then
                        for ki = 1, #data.lootSlotKw do
                            local kw = data.lootSlotKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, qwLen <= 3 and 140 or 80)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    if data.lootStatKw then
                        for ki = 1, #data.lootStatKw do
                            local kw = data.lootStatKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, qwLen <= 3 and 140 or 80)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    -- Prefix on boss/dungeon name must beat 1-edit fuzzy (85)
                    -- on unrelated names, so "nexu" -> Nexus-Point Xenas gear
                    -- doesn't rank below misspellings of other entries.
                    if data.lootSourceKw then
                        for ki = 1, #data.lootSourceKw do
                            local kw = data.lootSourceKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, 110)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 100)
                            end
                        end
                    end

                    if bestWord == 0 then
                        totalScore = 0
                        break
                    end
                    totalScore = totalScore + bestWord
                end

                score = totalScore
            elseif data.category == "Boss" and not bossQueryWord then
                score = Database:ScoreName(nameLower, query, queryLen, queryWords)
            else
                local cat = data.category
                local isAchEntry = cat == "Achievements" or cat == "Guild Achievements"
                                   or cat == "Statistics"
                if isAchEntry and not achQueryWord then
                    -- Strong name matches only (skip kw score) so short kw
                    -- aliases don't drag every achievement category in.
                    if nameLower == query then
                        score = 200
                    elseif sfind(nameLower, query, 1, true) == 1 then
                        score = 150
                    elseif Database:FindAtWordBoundary(nameLower, query) then
                        score = 120
                    else
                        score = 0
                    end
                else
                    -- MAX, not SUM. Many entries duplicate their name into
                    -- keywordsLower; a sum double-counts the same fuzzy hit.
                    score = mmax(
                        Database:ScoreName(nameLower, query, queryLen, queryWords),
                        Database:ScoreKeywords(data.keywordsLower, query, queryLen, queryWords)
                    )
                    if #queryWords >= 2 then
                        score = mmax(score, Database:ScoreEntryFields(data, queryWords))
                    end
                end
            end

            if score >= 30 then
                resultsN = resultsN + 1
                local r = resultEntryPool[resultsN]
                if not r then
                    r = {}
                    resultEntryPool[resultsN] = r
                end
                r.data = data
                r.score = score
                r.isAlias = nil
                results[resultsN] = r
                candidateIdx = candidateIdx + 1
                prevCandidates[candidateIdx] = data
            end
        end
    end
    for i = candidateIdx + 1, #prevCandidates do
        prevCandidates[i] = nil
    end
    prevQuery = query
    prevSkipKey = skipKey

    tsort(results, scoreDescending)
    local SEARCH_RESULT_CAP = 250
    if resultsN > SEARCH_RESULT_CAP then
        for i = SEARCH_RESULT_CAP + 1, resultsN do results[i] = nil end
        for i = SEARCH_RESULT_CAP + 1, #resultEntryPool do
            resultEntryPool[i] = nil
        end
        resultsN = SEARCH_RESULT_CAP
    end
    -- Drop stale data refs so a broad-then-narrow search doesn't keep
    -- the broad refs alive forever.
    for i = resultsN + 1, #resultEntryPool do
        local r = resultEntryPool[i]
        if r and r.data then
            r.data = nil
            r.score = nil
            r.isAlias = nil
        end
    end
    return results
end

-- Build at load time (before ADDON_LOADED) so other modules can reference
-- uiSearchData during their own init. Not routed through SafeInit, so wrap.
local initOk, initErr = pcall(Database.Initialize, Database)
if not initOk then
    print("|cffff4444EasyFind Database failed to initialize: " .. tostring(initErr) .. "|r")
end
