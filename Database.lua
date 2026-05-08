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

-- Word split cache: avoids per-call gmatch + table creation in scoring hot path.
-- Key = lowercase string, value = array of words split on [%w']+.
-- FIFO-bounded so per-keystroke prefixes ("a", "ac", "ach", ...) do not
-- accumulate forever. Most recent prefixes stay in cache; oldest evict
-- when the ring buffer wraps. Cap of 256 covers normal typing patterns
-- with room to spare while keeping retained memory in the low-KB range.
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

-- Reusable row tables for DamerauLevenshtein (avoids 3 table allocs per call)
local dlPrev2, dlPrev, dlCurr = {}, {}, {}

-- Reusable scratch for ScoreName's per-word matching path. Was allocated
-- per-entry per-search in the multi-word query branch (3700+ entries x
-- many keystrokes per second = major GC pressure during typing).
local scoreNameUsedWords = {}

-- Reusable sort comparator (avoids closure creation per SearchUI call)
local function scoreDescending(a, b) return a.score > b.score end

local uiSearchData = {}
Database.uiSearchData = uiSearchData  -- exposed for container expansion
Database._wordCache = wordCache        -- exposed for DevMem diagnostics
-- Track which currencyIDs are already in the static database
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

-- Defensive multi-spelling check for "is this currency warband-shared".
-- WoW has shipped at least three names / shapes for this concept across
-- builds; check all of them so detection doesn't regress when Blizzard
-- renames a field. Reused by both the per-currency populator and the
-- warband-fill pass.
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

-- Called after PLAYER_LOGIN when C_CurrencyInfo is available
-- Scans the WoW currency list and injects any currencies not already in the static database
function Database:PopulateDynamicCurrencies()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end

    RemoveEntriesByCategory("Currency")
    wipe(knownCurrencyIDs)

    -- Expand all collapsed headers so we can see every currency
    -- Track which ones we expand so we can collapse them back afterward
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

    -- Read the full flat list and inject any missing currencies
    local size = C_CurrencyInfo.GetCurrencyListSize()
    local injected = 0

    -- The steps that every currency inherits (open Character frame + Currency tab)
    local baseSteps = {
        { buttonFrame = "CharacterMicroButton" },
        { waitForFrame = "CharacterFrame", tabIndex = 3 },
    }

    -- Track the nested header stack so we generate correct multi-level steps.
    -- Each element: { name = "Legacy", depth = 0 }
    -- The currencyListDepth field (11.0.0+) controls indentation:
    --   0 = top-level header (Dungeon and Raid, Legacy, etc.)
    --   1 = sub-header (War Within under Legacy)
    --   etc.
    -- For currencies (non-header), depth indicates which header they belong to.
    local headerStack = {} -- ordered list, headerStack[1] = shallowest

    -- Helper: trim the stack so it only contains entries shallower than `depth`,
    -- then push a new header at that depth.
    local function pushHeader(name, depth)
        -- Remove anything at depth >= the new header's depth
        while #headerStack > 0 and headerStack[#headerStack].depth >= depth do
            headerStack[#headerStack] = nil
        end
        headerStack[#headerStack + 1] = { name = name, depth = depth }
    end

    -- Helper: build currencyHeader steps for the full header chain
    local function buildHeaderSteps()
        local steps = {}
        for _, s in ipairs(baseSteps) do steps[#steps + 1] = s end
        for _, h in ipairs(headerStack) do
            steps[#steps + 1] = { waitForFrame = "CharacterFrame", currencyHeader = h.name }
        end
        return steps
    end

    -- Helper: build the path array for the current header chain
    local function buildPath()
        local path = {"Character Info", "Currency"}
        for _, h in ipairs(headerStack) do
            path[#path + 1] = h.name .. " Currencies"
        end
        return path
    end

    -- Build a currencyID → icon map from the list scan (GetCurrencyListInfo is reliable)
    local currencyIconMap = {}

    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info then
            local depth = info.currencyListDepth or 0

            -- Capture icon for every currency we see
            if info.currencyID and info.iconFileID then
                currencyIconMap[info.currencyID] = info.iconFileID
            end

            if info.isHeader then
                pushHeader(info.name, depth)

                -- Also ensure the header group itself is searchable
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
                    -- The path for a header entry doesn't include itself
                    -- (buildPath includes it, so remove the last element)
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
                -- This currency isn't in our static database - inject it
                local currName = info.name
                local immediateHeader = headerStack[#headerStack]
                local immediateHeaderName = immediateHeader and immediateHeader.name or "Unknown"

                -- Build steps: base + expand all parent headers + scroll to currency
                local currSteps = buildHeaderSteps()
                currSteps[#currSteps + 1] = { waitForFrame = "CharacterFrame", currencyID = info.currencyID }

                -- Generate keywords: currency name words + "header currname"
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

    -- Resolve icons for ALL currency entries (static + dynamic) using the map we just built
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

    -- Collapse back any headers we expanded during scanning
    -- Collapse from deepest first: iterate in reverse through the list
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

    -- Warband-fill pass: surface warband-transferable currencies the
    -- player has on OTHER characters (or has never touched on any
    -- character but still exist account-wide). Without this, the
    -- "All Warband Transferable" filter mode only shows currencies
    -- the current character has interacted with — defeating the point.
    -- Enumerate via the modern C_CurrencyInfo accessor when available;
    -- fall back to a bounded ID scan only if nothing else works.
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

-- Called after PLAYER_LOGIN when C_Reputation is available
-- Scans the WoW reputation list and injects factions as searchable entries
function Database:PopulateDynamicReputations()
    if not C_Reputation or not C_Reputation.GetNumFactions then return false end

    RemoveEntriesByCategory("Reputation")

    -- Expand all collapsed headers so we can see every faction
    local headersWeExpanded = {}
    for pass = 1, 50 do
        local numFactions = C_Reputation.GetNumFactions()
        local didExpand = false
        for i = 1, numFactions do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.isHeader then
                -- Check if header is collapsed using both new and old property names
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

    -- Read the full flat list and build entries
    local numFactions = C_Reputation.GetNumFactions()
    local injected = 0

    -- Base steps that every reputation inherits (open Character frame + Reputation tab)
    local baseSteps = {
        { buttonFrame = "CharacterMicroButton" },
        { waitForFrame = "CharacterFrame", tabIndex = 2 },
    }

    -- Track both expansion headers and faction-group headers (they do nest!)
    local currentExpansion = nil
    local currentFactionGroup = nil


    local function buildHeaderSteps()
        local steps = {}
        for _, s in ipairs(baseSteps) do steps[#steps + 1] = s end
        -- Navigate through the header hierarchy: first expansion, then faction group
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
        -- Build hierarchical path: Expansion -> Faction Group (if exists)
        if currentExpansion then
            path[#path + 1] = currentExpansion
        end
        if currentFactionGroup then
            path[#path + 1] = currentFactionGroup
        end
        return path
    end

    -- Localized "Alliance" / "Horde" header names from globals when available;
    -- fall back to lowercase string comparison for non-English clients that
    -- don't expose them under these IDs.
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

        -- Faction side: inferred from the parent group header. Factions
        -- under an Alliance/Horde sub-header are faction-locked; the rest
        -- are either-faction reputations.
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
                    -- Clear previous sibling faction group before processing
                    currentFactionGroup = nil
                    -- Header-factions: inject all with factionID so they're searchable.
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

    -- Collapse back any headers we expanded during scanning
    for pass = 1, 50 do
        local numFactionsPost = C_Reputation.GetNumFactions()
        local didCollapse = false
        for i = numFactionsPost, 1, -1 do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.isHeader and headersWeExpanded[factionData.name] then
                -- Check if header is expanded using both property names
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

-- Called after PLAYER_LOGIN when C_MountJournal is available
-- Scans the player's collected mounts and injects them into the search database
-- Shared prototypes for mount/toy entries via __index.
-- Eliminates 5 hash slots per entry (~320 bytes each × ~1300 entries).
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


-- Map equip location strings to user-friendly search keywords
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

-- Map item stat keys to search keywords
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

-- Slot display names for result text
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

-- Lowercased slot display names for category score boosting (query "legs" → loot first)
local lootSlotNames = {}
for _, displayName in pairs(SLOT_DISPLAY) do
    lootSlotNames[slower(displayName)] = true
end
ns.lootSlotNames = lootSlotNames

-- EJ API compatibility: some functions migrated from EJ_* globals to C_EncounterJournal.*.
-- Prefer C_EncounterJournal (current) over globals (may be stale wrappers).
-- Resolved at call time because C_EJ functions may not exist until EncounterJournal_LoadUI().
local function EJ(name)
    return (C_EncounterJournal and C_EncounterJournal[name]) or _G["EJ_" .. name]
end

local lootEntries = {}       -- track injected entries for re-population
local lootScanGeneration = 0 -- cancel stale scans when re-populating
local bossScanGeneration = 0
local lootItemCache = {}     -- itemID -> entry (persists across spec/diff toggles)
local lootSpecsScanned = {}  -- ["classID-specID"] = true
Database._lootItemCache = lootItemCache         -- exposed for DevMem diagnostics
Database._lootEntries = lootEntries             -- exposed for DevMem diagnostics
Database._lootSpecsScanned = lootSpecsScanned   -- exposed for DevMem diagnostics

-- Maps user-facing difficulty keys to EJ difficulty IDs per source type
local LOOT_DIFF_IDS = {
    lfr     = { raid = 17 },
    normal  = { dungeon = 1,  raid = 14 },
    heroic  = { dungeon = 2,  raid = 15 },
    mythic  = { dungeon = 23, raid = 16 },
}

-- Get the EJ difficulty ID for the current loot difficulty setting.
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

-- Sync the EJ's difficulty for both dungeon and raid tabs.
-- EJ_SetDifficulty requires an instance of the matching type to be selected first.
-- Saves and restores the current instance selection to avoid side effects.
function Database:SyncEJDifficulty()
    local selectInst = EJ("SelectInstance")
    local getInst = EJ("GetInstanceByIndex")
    local setDiff = EJ("SetDifficulty")
    local getInstInfo = EJ("GetInstanceInfo")
    if not selectInst or not getInst or not setDiff then return end

    -- Save current instance so we can restore it after
    -- EJ_GetInstanceInfo returns: name, description, bgImage, buttonImage1, ..., mapID, journalInstanceID
    -- journalInstanceID is at index 12
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

    -- Restore previous instance selection
    if savedInstID and savedInstID > 0 then
        selectInst(savedInstID)
    end
end

-- Sync the EJ's internal loot filter to match EasyFind's lootFilter setting.
-- Called when the user changes the filter and before loot navigation.
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

-- Rebuild uiSearchData loot entries from cache based on current spec + difficulty selection.
-- No EJ scan needed: filters cached items by spec and difficulty match.
local function RebuildLootSearchData()
    -- Remove old loot entries (filter in place to avoid O(n^2) tremove)
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

    -- Build spec lookup from current selection
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

    -- Single difficulty selection
    local wantDiff = EasyFind.db.lootDifficulty or "normal"

    -- Filter cache: include items matching selected spec AND selected difficulty
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

-- Enrich a loot entry with stat keywords from its item link.
-- Called lazily when the entry first appears in results.
-- Difficulty priority for selecting which item link to display/use.
local DIFF_PRIORITY = { "mythic", "heroic", "normal", "lfr" }

-- Returns the item link for a loot entry at the selected difficulty.
-- Falls back to highest available if the selected difficulty has no link.
-- Look up a transmog set's ID by exact name. Used to recover the setID for
-- pinned appearance sets that were saved before transmogSetID was persisted.
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
    -- Pinned/serialized entries lose their lootItemLinks table when written
    -- to SavedVariables. Fall back to the live loot cache by itemID so
    -- existing pins keep working without needing to be re-pinned.
    if not links and entry.itemID then
        local live = lootItemCache[entry.itemID]
        if live then links = live.lootItemLinks end
    end
    if not links then return nil end
    local selected = EasyFind.db.lootDifficulty or "normal"
    if links[selected] then return links[selected] end
    -- Fallback: any available link
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

-- Outfit click-to-equip uses a temporary action bar slot.
-- PreClick finds an empty slot, places the outfit, then the secure
-- handler calls UseAction to equip it. PostClick clears the slot.
-- The slot is re-discovered each click to avoid overwriting user actions.
local outfitEntries = {} -- track injected entries for re-population

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

-- Called after PLAYER_LOGIN when C_ToyBox is available
-- Scans the player's collected toys and injects them into the search database
function Database:PopulateDynamicToys()
    if not C_ToyBox then return false end

    RemoveEntriesByCategory("Toy")

    local GetToyInfo = C_ToyBox.GetToyInfo
    local GetNumFilteredToys = C_ToyBox.GetNumFilteredToys
    local GetToyFromIndex = C_ToyBox.GetToyFromIndex
    if not GetToyInfo or not GetNumFilteredToys or not GetToyFromIndex then return false end

    -- Save current filter state, set to show all collected toys only
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
                -- Tag faction/class-restricted toys so the click handler
                -- routes to ToyBox highlight instead of attempting a
                -- secure use that would silently no-op. C_ToyBox.IsToyUsable
                -- mirrors what Blizzard's own ToyBox UI uses for the Use
                -- button enable state, unlike the broader IsUsableItem
                -- which can flunk usable toys when the item info hasn't
                -- been cached yet at PLAYER_LOGIN time.
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

    -- Restore filter state
    if hasFilterAPI then C_ToyBox.SetCollectedShown(savedCollected) end
    if C_ToyBox.SetUncollectedShown then C_ToyBox.SetUncollectedShown(savedUncollected) end
    if C_ToyBox.SetFilterString then C_ToyBox.SetFilterString(savedString) end
    if C_ToyBox.ForceToyRefilter then C_ToyBox.ForceToyRefilter() end
    return true
end

-- Called after PLAYER_LOGIN when C_PetJournal is available
-- Scans the player's collected pets and injects them into the search database
function Database:PopulateDynamicPets()
    if not C_PetJournal or not C_PetJournal.GetNumPets then return false end

    RemoveEntriesByCategory("Pet")

    -- Save current filter state
    local savedCollected = C_PetJournal.IsFilterChecked and C_PetJournal.IsFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED)
    local savedNotCollected = C_PetJournal.IsFilterChecked and C_PetJournal.IsFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED)
    local savedString = C_PetJournal.GetSearchFilter and C_PetJournal.GetSearchFilter() or ""

    -- Show all collected pets
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

    -- Restore filter state
    if C_PetJournal.SetFilterChecked then
        if savedCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, savedCollected) end
        if savedNotCollected ~= nil then C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, savedNotCollected) end
    end
    if C_PetJournal.SetSearchFilter then C_PetJournal.SetSearchFilter(savedString) end
    return true
end

-- Called after PLAYER_LOGIN when C_Heirloom is available.
-- Scans the heirloom catalog and injects any owned heirloom into the
-- search database. Click handler creates the heirloom item in the
-- player's bags via C_Heirloom.CreateHeirloom.
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

-- Scan known character titles and inject as search entries. Click on a
-- title row sets it as the current title via SetCurrentTitle. Titles
-- come back from the API with a "%s" placeholder for the player's
-- name; we strip it for display so the row reads "the Insane" rather
-- than "%s the Insane".
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


-- Scan the player's saved Equipment Manager gear sets and inject as
-- search entries. Click on a row equips the set via
-- C_EquipmentSet.UseEquipmentSet (no protected-frame issues outside
-- combat). Per-set icons come from the saved iconFileID.
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

-- Called after PLAYER_LOGIN when C_TransmogOutfitInfo is available.
-- Scans the player's saved transmog outfits and injects them into the search database.
function Database:PopulateDynamicOutfits()
    if not C_TransmogOutfitInfo or not C_TransmogOutfitInfo.GetOutfitsInfo then return false end

    -- Remove previous outfit entries (handles mid-session outfit changes)
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

-- Reads the default UI's transmog set filters and updates our saved settings.
-- Called before populate and when the filter dropdown opens.
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

-- Called after PLAYER_LOGIN when C_TransmogSets is available.
-- Scans all transmog appearance sets and injects them into the search database.
-- Respects class, collected, and PvE/PvP filter settings.
function Database:PopulateDynamicTransmogSets()
    if not C_TransmogSets or not C_TransmogSets.GetAllSets then return false end

    -- Remove previous entries (handles mid-session filter changes)
    RemoveEntriesWithField("transmogSetID")
    -- Invalidate incremental search cache. Without this, a query that was
    -- typed before the repopulate (e.g. "cauldron" searched with Druid sets
    -- active) would still reuse prevCandidates on the next extension and
    -- miss the newly injected entries.
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

    -- Sync class filter to default UI. Guard against the hooksecurefunc in
    -- Core.lua re-entering Populate from our own call here.
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

    -- Sync collected/PvE/PvP filters to default UI
    -- BaseSetsFilter enum: 1=Collected, 2=Not Collected, 3=PvE, 4=PvP
    local syncFilter = C_TransmogSets.SetBaseSetsFilter or C_TransmogSets.SetSetsFilter
    if syncFilter then
        pcall(syncFilter, 1, showCollected)
        pcall(syncFilter, 2, showNotCollected)
        pcall(syncFilter, 3, showPvE)
        pcall(syncFilter, 4, showPvP)
    end

    -- Refresh the default UI's sets list and class dropdown if loaded
    local wcf = _G["WardrobeCollectionFrame"]
    local scf = wcf and wcf.SetsCollectionFrame
    if scf and scf:IsShown() then
        if scf.SetDataSource then pcall(scf.SetDataSource, scf) end
        if scf.UpdateUI then pcall(scf.UpdateUI, scf) end
        if scf.Refresh then pcall(scf.Refresh, scf) end
    end
    -- Refresh class dropdown text
    if wcf and wcf.ClassDropdown and wcf.ClassDropdown.Update then
        pcall(wcf.ClassDropdown.Update, wcf.ClassDropdown)
    end

    -- Determine class mask for filtering
    local wantMask
    if not classFilter then
        local _, _, cid = UnitClass("player")
        wantMask = cid and lshift(1, cid - 1) or 0
    elseif classFilter == "all" then
        wantMask = nil -- accept all
    elseif type(classFilter) == "table" and classFilter.classID then
        wantMask = lshift(1, classFilter.classID - 1)
    end

    local GetSetPrimaryAppearances = C_TransmogSets.GetSetPrimaryAppearances
    local GetSourceIcon = C_TransmogCollection and C_TransmogCollection.GetSourceIcon

    for i = 1, #allSets do
        local setInfo = allSets[i]
        -- Only include base sets; variants share the same visuals and
        -- aren't directly navigable in the Sets tab left list
        local isBaseSet = true
        if C_TransmogSets.GetBaseSetID then
            local bid = C_TransmogSets.GetBaseSetID(setInfo.setID)
            isBaseSet = not bid or bid == setInfo.setID
        end
        if isBaseSet and setInfo.name and setInfo.name ~= "" and not setInfo.hiddenUntilCollected then
            -- Class filter: use classMask for specific class, or accept all
            local cm = setInfo.classMask or 0
            local classOk = not wantMask or cm == 0 or cm < 0 or band(cm, wantMask) ~= 0

            -- PvE/PvP filter (check for known PvP label patterns)
            local label = setInfo.label or ""
            local labelLower = slower(label)
            local isPvP = sfind(labelLower, "pvp") or sfind(labelLower, "season")
                or sfind(labelLower, "gladiator") or sfind(labelLower, "aspirant")
                or sfind(labelLower, "combatant")
            local sourceOk = (isPvP and showPvP) or (not isPvP and showPvE)

            -- Collected filter
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

                -- Get icon from first appearance source
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
    -- Scan from high to low for an empty slot.
    -- Skip 121-168: bonus/override/vehicle/stance bars that may reject
    -- non-class-specific actions (e.g., totem slots for shamans,
    -- stance slots for druids/warriors).
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

function Database:CancelDynamicScans()
    lootScanGeneration = lootScanGeneration + 1
    bossScanGeneration = bossScanGeneration + 1
end

-- Called after PLAYER_LOGIN. Scans the Encounter Journal for current-tier loot
-- and injects searchable entries. Caches results so spec toggles only filter
-- in memory without re-scanning. Only scans specs not yet in cache.
-- Optional scanAllSpecs: when true, pre-caches every class/spec combo (for loading screen).
function Database:PopulateDynamicLoot(scanAllSpecs)
    if InCombatLockdown() then return end

    local specPairs = BuildLootSpecPairs(scanAllSpecs)
    local needScan = GetLootSpecsToScan(specPairs)

    -- All selected specs already cached: just rebuild from cache (instant)
    if #needScan == 0 then
        RebuildLootSearchData()
        return
    end

    -- EJ loot tables require the UI to be loaded first
    if not EncounterJournal then
        EncounterJournal_LoadUI()
    end

    -- Resolve EJ APIs after UI load (some live on C_EncounterJournal, not global)
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

    -- Bump generation so any in-flight staggered scan aborts
    lootScanGeneration = lootScanGeneration + 1
    local myGen = lootScanGeneration

    -- Suppress EJ UI events during scan
    local ejFrame = _G["EncounterJournal"]
    local savedOnEvent
    if ejFrame then
        savedOnEvent = ejFrame:GetScript("OnEvent")
        ejFrame:SetScript("OnEvent", nil)
    end

    local savedTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

    -- Collect all instances in the current tier
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

    -- Build list of {diffKey, diffID} pairs per source type
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

    -- Restore EJ state, mark specs cached, rebuild search data
    if savedTier and EJ_SelectTier then EJ_SelectTier(savedTier) end
    if ejFrame and savedOnEvent then ejFrame:SetScript("OnEvent", savedOnEvent) end
    for _, sp in ipairs(needScan) do
        lootSpecsScanned[sp.classID .. "-" .. sp.specID] = true
    end
    RebuildLootSearchData()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            collectgarbage("step", 200)
        end)
    else
        collectgarbage("step", 200)
    end
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

-- Macro search: scans the player's account-wide and per-character macros
-- and injects them as searchable entries. Direct click runs the macro;
-- guide mode opens MacroFrame, switches to the matching tab, and selects
-- the macro. Re-callable: clears prior Macro entries before re-injecting,
-- so calls from UPDATE_MACROS reflect renames/edits/deletes.
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
        -- Index macro body words (slash command names, target names, etc.)
        -- so /castsequence Hearthstone is reachable by typing "hearthstone".
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

-- Inject one entry per learned spell into uiSearchData. Retail Midnight
-- replaced GetSpellBookItemInfo's (slot, slotType) string-typed args
-- with (slotIndex, Enum.SpellBookSpellBank) and returns a single
-- SpellBookItemInfo table containing name, subName, actionID, iconID.
-- We use that path exclusively; pre-Midnight clients (Classic) skip
-- registration since this addon targets Midnight 12.0+.
function Database:PopulateDynamicAbilities()
    -- Strip prior pass so /reload-equivalent rebuilds don't double up.
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
                    -- Flyouts are containers (Switch Flight Style → Skyriding /
                    -- Steady Flight, etc.). The flyout itself isn't castable,
                    -- but its slot spells are — scan and inject each, and use
                    -- the flyout's own name as a keyword so "switch flight"
                    -- finds the slot spells.
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

-- Common community abbreviations for dungeons/raids whose initials
-- skip non-leading letters (e.g. "BWL" picks the W from blackWing) so
-- the standard initials/prefix scoring can't reach them. Listed as
-- per-instance keyword aliases — typing "bwl" gets the same 2-3 char
-- exact-match boost (140) that "icc" already gets via the prefix path.
-- Keys are lowercased instance names returned by EJ_GetInstanceByIndex.
-- Exposed on ns so MapSearch can inject the same aliases onto its
-- dungeon-entrance POIs and the two surfaces stay in sync.
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

-- Inject one entry per dungeon/raid boss across every expansion tier.
-- Click navigates the Encounter Journal to that boss. Icon is the
-- boss's first creature portrait (EJ_GetCreatureInfo[5]) so results
-- look like the EJ's own boss list.
function Database:PopulateDynamicBosses()
    -- Strip prior pass so re-runs don't double up.
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

    -- Suppress EJ UI events during the scan so opening the journal
    -- mid-scan can't fight us. Restore at the end.
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

    -- Restore prior tier and EJ event handler so the journal behaves
    -- normally for the user's next interaction.
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

-- Enumerate the player's class/spec talent tree(s) via C_Traits and
-- emit one search entry per selectable talent. Each entry remembers the
-- nodeID + entryID so the click handler can scroll the talents tree
-- into view, find the matching node button under PlayerSpellsFrame.
-- TalentsFrame.ButtonsParent, and highlight it.
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

        -- Allocation: choice nodes pick one of their entries via
        -- activeEntry; regular nodes report activeRank > 0 when the
        -- player has put points in. Used by the row renderer to
        -- desaturate the per-talent icon for unspecced talents.
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

-- Inject one entry per unique item carried in the player's bags. The
-- entry stores the first occupied location so guide mode can highlight
-- the right slot; drag-to-pickup uses the item ID to put the item on
-- the cursor (matching the in-game bag drag behavior).
function Database:PopulateDynamicBags()
    local CONT = C_Container
    local getNumSlots = (CONT and CONT.GetContainerNumSlots) or GetContainerNumSlots
    local getItemInfo = (CONT and CONT.GetContainerItemInfo)  or GetContainerItemInfo
    local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local isEquippableItem = (C_Item and C_Item.IsEquippableItem) or _G.IsEquippableItem
    if not getNumSlots or not getItemInfo then return false end

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
                    -- Legacy multi-return (Classic-era layout)
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
        local equipLoc
        if getItemInfoInstant then
            local _, _, _, itemEquipLoc = getItemInfoInstant(itemID)
            equipLoc = itemEquipLoc
        end
        local isEquippable = (equipLoc and equipLoc ~= "") or (isEquippableItem and isEquippableItem(itemID)) or false
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

-- TREE FLATTENER
-- Walks the tree and produces flat entries for the search/highlight engines.
-- Children inherit: buttonFrame, category, and accumulate path + steps from parents.

function Database:FlattenTree(tree, parentPath, parentSteps, parentButtonFrame, parentCategory)
    parentPath = parentPath or {}
    parentSteps = parentSteps or {}

    for _, node in ipairs(tree) do
        local myButtonFrame = node.buttonFrame or parentButtonFrame
        local myCategory = node.category or parentCategory

        -- Accumulate steps: reuse parent array when node adds nothing
        local mySteps
        if node.steps then
            mySteps = {}
            for _, s in ipairs(parentSteps) do mySteps[#mySteps + 1] = s end
            for _, s in ipairs(node.steps) do mySteps[#mySteps + 1] = s end
        else
            mySteps = parentSteps
        end

        -- Build the flat entry (path = parent names leading here, NOT including self)
        local entry = {
            name = node.name,
            keywords = node.keywords or {},
            category = myCategory,
            buttonFrame = myButtonFrame,
            path = {},
            steps = mySteps,
        }
        for i = 1, #parentPath do entry.path[i] = parentPath[i] end
        -- Copy optional fields
        if node.flashLabel then entry.flashLabel = node.flashLabel end
        if node.icon then entry.icon = node.icon end
        if node.available then entry.available = node.available end
        if node.canQueue then entry.canQueue = true end
        if node.slashCommand then entry.slashCommand = node.slashCommand end

        uiSearchData[#uiSearchData + 1] = entry

        -- Recurse into children with this node's name appended to the path
        if node.children then
            local childPath = {}
            for i = 1, #parentPath do childPath[i] = parentPath[i] end
            childPath[#childPath + 1] = node.name
            self:FlattenTree(node.children, childPath, mySteps, myButtonFrame, myCategory)
        end
    end
end

function Database:BuildUIDatabase()
    -- UI TREE
    -- Each node: { name, keywords, [category], [buttonFrame], [steps], [children] }
    --   - category: inherited from parent if omitted
    --   - buttonFrame: inherited from parent if omitted
    --   - steps: only THIS node's new steps (flattener prepends parent steps)
    --   - path: auto-built from ancestor names (never specified manually)
    local uiTree = {

        -- CHARACTER INFO
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

        -- PROFESSIONS
        {
            name = "Professions",
            keywords = {"professions", "profession", "crafting", "trade skills", "skills"},
            category = "Menu Bar",
            buttonFrame = "ProfessionMicroButton",
            steps = {{ buttonFrame = "ProfessionMicroButton" }},
        },

        -- TALENTS & SPELLBOOK
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

        -- ACHIEVEMENTS
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
                    children = {
                        -- ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
                        {
                            name = "Characters (Achievements)",
                            keywords = {"characters"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Characters" }},
                        },
                        {
                            name = "Collections (Achievements)",
                            keywords = {"collections", "collection", "transmog", "tmog"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Collections" }},
                            children = {
                                {
                                    name = "Appearances (Achievements)",
                                    keywords = {"appearances"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Appearances" }},
                                },
                                {
                                    name = "Decor (Achievements)",
                                    keywords = {"decor"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Decor" }},
                                },
                                {
                                    name = "Dragon Isle Drake Cosmetics (Achievements)",
                                    keywords = {"dragon isle drake cosmetics", "drake cosmetics"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragon Isle Drake Cosmetics" }},
                                },
                                {
                                    name = "Mounts - Collections (Achievements)",
                                    keywords = {"mounts"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Mounts" }},
                                },
                                {
                                    name = "Toy Box (Achievements)",
                                    keywords = {"toy box", "toys"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Toy Box" }},
                                },
                            },
                        },
                        {
                            name = "Delves (Achievements)",
                            keywords = {"delves"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Delves" }},
                            children = {
                                {
                                    name = "Midnight - Delves (Achievements)",
                                    keywords = {"midnight"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight" }},
                                },
                                {
                                    name = "The War Within (Achievements)",
                                    keywords = {"the war within", "tww"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The War Within" }},
                                },
                            },
                        },
                        {
                            name = "Dungeons & Raids (Achievements)",
                            keywords = {"dungeons & raids", "dungeons", "raids", "dungeon", "raid"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" }},
                            children = {
                                {
                                    name = "Battle Dungeon (Achievements)",
                                    keywords = {"battle dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" }},
                                },
                                {
                                    name = "Battle Raid (Achievements)",
                                    keywords = {"battle raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" }},
                                },
                                {
                                    name = "Cataclysm Dungeon (Achievements)",
                                    keywords = {"cataclysm dungeon", "cata dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" }},
                                },
                                {
                                    name = "Cataclysm Raid (Achievements)",
                                    keywords = {"cataclysm raid", "cata raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" }},
                                },
                                {
                                    name = "Classic - Dungeons & Raids (Achievements)",
                                    keywords = {"classic"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Classic" }},
                                },
                                {
                                    name = "Draenor Dungeon (Achievements)",
                                    keywords = {"draenor dungeon", "wod dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" }},
                                },
                                {
                                    name = "Draenor Raid (Achievements)",
                                    keywords = {"draenor raid", "wod raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" }},
                                },
                                {
                                    name = "Dragonflight Dungeon (Achievements)",
                                    keywords = {"dragonflight dungeon", "df dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" }},
                                },
                                {
                                    name = "Dragonflight Raid (Achievements)",
                                    keywords = {"dragonflight raid", "df raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" }},
                                },
                                {
                                    name = "Legion Dungeon (Achievements)",
                                    keywords = {"legion dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" }},
                                },
                                {
                                    name = "Legion Raid (Achievements)",
                                    keywords = {"legion raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" }},
                                },
                                {
                                    name = "Lich King Dungeon (Achievements)",
                                    keywords = {"lich king dungeon", "wotlk dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" }},
                                },
                                {
                                    name = "Lich King Raid (Achievements)",
                                    keywords = {"lich king raid", "wotlk raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" }},
                                },
                                {
                                    name = "Midnight Dungeon (Achievements)",
                                    keywords = {"midnight dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" }},
                                },
                                {
                                    name = "Midnight Raid (Achievements)",
                                    keywords = {"midnight raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" }},
                                },
                                {
                                    name = "Pandaria Dungeon (Achievements)",
                                    keywords = {"pandaria dungeon", "mop dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" }},
                                },
                                {
                                    name = "Pandaria Raid (Achievements)",
                                    keywords = {"pandaria raid", "mop raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" }},
                                },
                                {
                                    name = "Shadowlands Dungeon (Achievements)",
                                    keywords = {"shadowlands dungeon", "sl dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" }},
                                },
                                {
                                    name = "Shadowlands Raid (Achievements)",
                                    keywords = {"shadowlands raid", "sl raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" }},
                                },
                                {
                                    name = "The Burning Crusade - Dungeons & Raids (Achievements)",
                                    keywords = {"the burning crusade", "tbc"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" }},
                                },
                                {
                                    name = "War Within Dungeon (Achievements)",
                                    keywords = {"war within dungeon", "tww dungeon"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" }},
                                },
                                {
                                    name = "War Within Raid (Achievements)",
                                    keywords = {"war within raid", "tww raid"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" }},
                                },
                            },
                        },
                        {
                            name = "Expansion Features (Achievements)",
                            keywords = {"expansion features", "expansion"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" }},
                            children = {
                                { name = "Argent Tournament (Achievements)", keywords = {"argent tournament"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Argent Tournament" }} },
                                { name = "Covenant Sanctums (Achievements)", keywords = {"covenant sanctums", "covenant", "sanctums"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Covenant Sanctums" }} },
                                { name = "Draenor Garrison (Achievements)", keywords = {"draenor garrison", "garrison"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Garrison" }} },
                                { name = "Heart of Azeroth (Achievements)", keywords = {"heart of azeroth", "hoa"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Heart of Azeroth" }} },
                                { name = "Island Expeditions (Achievements)", keywords = {"island expeditions", "islands"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Island Expeditions" }} },
                                { name = "Legion Class Hall (Achievements)", keywords = {"legion class hall", "class hall", "order hall"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Class Hall" }} },
                                { name = "Lorewalking (Achievements)", keywords = {"lorewalking"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lorewalking" }} },
                                { name = "Pandaria Scenarios (Achievements)", keywords = {"pandaria scenarios", "scenarios"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Scenarios" }} },
                                { name = "Prey (Achievements)", keywords = {"prey"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Prey" }} },
                                { name = "Proving Grounds (Achievements)", keywords = {"proving grounds"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Proving Grounds" }} },
                                { name = "Skyriding (Achievements)", keywords = {"skyriding", "dragonriding"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Skyriding" }} },
                                { name = "Tol Barad (Achievements)", keywords = {"tol barad", "tb"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Tol Barad" }} },
                                { name = "Torghast (Achievements)", keywords = {"torghast", "tower of the damned"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Torghast" }} },
                                { name = "Visions of N'Zoth (Achievements)", keywords = {"visions of n'zoth", "visions", "nzoth"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth" }} },
                                { name = "Visions of N'Zoth Revisited (Achievements)", keywords = {"visions of n'zoth revisited", "nzoth revisited"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth Revisited" }} },
                                { name = "War Effort (Achievements)", keywords = {"war effort"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Effort" }} },
                                { name = "Warfronts (Achievements)", keywords = {"warfronts", "warfront"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Warfronts" }} },
                            },
                        },
                        {
                            name = "Exploration (Achievements)",
                            keywords = {"exploration", "explore", "explorer"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Exploration" }},
                            children = {
                                { name = "Battle for Azeroth - Exploration (Achievements)", keywords = {"battle for azeroth", "bfa"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" }} },
                                { name = "Cataclysm - Exploration (Achievements)", keywords = {"cataclysm"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" }} },
                                { name = "Draenor - Exploration (Achievements)", keywords = {"draenor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor" }} },
                                { name = "Eastern Kingdoms - Exploration (Achievements)", keywords = {"eastern kingdoms"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Eastern Kingdoms" }} },
                                { name = "Kalimdor - Exploration (Achievements)", keywords = {"kalimdor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Kalimdor" }} },
                                { name = "Legion - Exploration (Achievements)", keywords = {"legion"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion" }} },
                                { name = "Midnight - Exploration (Achievements)", keywords = {"midnight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight" }} },
                                { name = "Northrend - Exploration (Achievements)", keywords = {"northrend"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Northrend" }} },
                                { name = "Outland - Exploration (Achievements)", keywords = {"outland"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Outland" }} },
                                { name = "Pandaria - Exploration (Achievements)", keywords = {"pandaria"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" }} },
                                { name = "Shadowlands - Exploration (Achievements)", keywords = {"shadowlands"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" }} },
                                { name = "Dragon Isles (Achievements)", keywords = {"dragon isles", "dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragon Isles" }} },
                                { name = "War Within - Exploration (Achievements)", keywords = {"war within"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within" }} },
                            },
                        },
                        {
                            name = "Feats of Strength (Achievements)",
                            keywords = {"feats of strength", "feats", "feat", "fos"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" }},
                            children = {
                                { name = "Delves - Feats of Strength (Achievements)", keywords = {"delves"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Delves" }} },
                                { name = "Dungeons - Feats of Strength (Achievements)", keywords = {"dungeons", "dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" }} },
                                { name = "Events (Achievements)", keywords = {"events"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Events" }} },
                                { name = "Mounts - Feats of Strength (Achievements)", keywords = {"mounts"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Mounts" }} },
                                { name = "Player vs. Player - Feats of Strength (Achievements)", keywords = {"player vs. player", "pvp"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }} },
                                { name = "Promotions (Achievements)", keywords = {"promotions"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Promotions" }} },
                                { name = "Raids - Feats of Strength (Achievements)", keywords = {"raids", "raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Raids" }} },
                                { name = "Reputation - Feats of Strength (Achievements)", keywords = {"reputation", "rep", "factions"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Reputation" }} },
                            },
                        },
                        {
                            name = "Legacy (Achievements)",
                            keywords = {"legacy", "old", "removed"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legacy" }},
                            children = {
                                { name = "Character (Achievements)", keywords = {"character"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Character" }} },
                                { name = "Currencies (Achievements)", keywords = {"currencies", "currency"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Currencies" }} },
                                { name = "Dungeons - Legacy (Achievements)", keywords = {"dungeons", "dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" }} },
                                { name = "Expansion Features - Legacy (Achievements)", keywords = {"expansion features", "expansion"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" }} },
                                { name = "Legion Remix (Achievements)", keywords = {"legion remix", "legion", "remix"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Remix" }} },
                                { name = "Player vs. Player - Legacy (Achievements)", keywords = {"player vs. player", "pvp"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }} },
                                { name = "Professions - Legacy (Achievements)", keywords = {"professions", "profession", "crafting"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Professions" }} },
                                { name = "Quests - Legacy (Achievements)", keywords = {"quests", "quest"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Quests" }} },
                                { name = "Raids - Legacy (Achievements)", keywords = {"raids", "raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Raids" }} },
                                { name = "Remix: Mists of Pandaria (Achievements)", keywords = {"remix: mists of pandaria", "remix", "mists", "pandaria"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Remix: Mists of Pandaria" }} },
                                { name = "World Events - Legacy (Achievements)", keywords = {"world events", "holidays", "seasonal"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "World Events" }} },
                            },
                        },
                        { name = "Pet Battles (Achievements)", keywords = {"pet battles", "pets", "battle pets"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" }},
                            children = {
                                { name = "Battle (Achievements)", keywords = {"battle"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle" }} },
                                { name = "Collect (Achievements)", keywords = {"collect"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Collect" }} },
                                { name = "Level (Achievements)", keywords = {"level"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Level" }} },
                            },
                        },
                        {
                            name = "Player vs. Player (Achievements)",
                            keywords = {"player vs. player", "pvp"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }},
                            children = {
                                { name = "Alterac Valley (Achievements)", keywords = {"alterac valley", "av"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Alterac Valley" }} },
                                { name = "Arathi Basin (Achievements)", keywords = {"arathi basin", "ab"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Arathi Basin" }} },
                                { name = "Arena (Achievements)", keywords = {"arena", "arenas"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Arena" }} },
                                { name = "Ashran (Achievements)", keywords = {"ashran"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Ashran" }} },
                                { name = "Battle for Gilneas (Achievements)", keywords = {"battle for gilneas", "gilneas"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle for Gilneas" }} },
                                { name = "Deephaul Ravine (Achievements)", keywords = {"deephaul ravine", "deephaul"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Deephaul Ravine" }} },
                                { name = "Deepwind Gorge (Achievements)", keywords = {"deepwind gorge", "deepwind"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Deepwind Gorge" }} },
                                { name = "Eye of the Storm (Achievements)", keywords = {"eye of the storm", "eots"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Eye of the Storm" }} },
                                { name = "Honor (Achievements)", keywords = {"honor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Honor" }} },
                                { name = "Isle of Conquest (Achievements)", keywords = {"isle of conquest", "ioc"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Isle of Conquest" }} },
                                { name = "Rated Battleground (Achievements)", keywords = {"rated battleground", "rated"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Rated Battleground" }} },
                                { name = "Seething Shore (Achievements)", keywords = {"seething shore", "seething"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Seething Shore" }} },
                                { name = "Silvershard Mines (Achievements)", keywords = {"silvershard mines", "silvershard"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Silvershard Mines" }} },
                                { name = "Temple of Kotmogu (Achievements)", keywords = {"temple of kotmogu", "kotmogu"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Temple of Kotmogu" }} },
                                { name = "Training Grounds (Achievements)", keywords = {"training grounds", "training"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Training Grounds" }} },
                                { name = "Twin Peaks (Achievements)", keywords = {"twin peaks"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Twin Peaks" }} },
                                { name = "Warsong Gulch (Achievements)", keywords = {"warsong gulch", "wsg"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Warsong Gulch" }} },
                                { name = "Wintergrasp (Achievements)", keywords = {"wintergrasp", "wg"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Wintergrasp" }} },
                                { name = "World (Achievements)", keywords = {"world"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "World" }} },
                            },
                        },
                        {
                            name = "Professions (Achievements)",
                            keywords = {"professions", "profession", "crafting"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Professions" }},
                            children = {
                                { name = "Alchemy (Achievements)", keywords = {"alchemy"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Alchemy" }} },
                                { name = "Archaeology (Achievements)", keywords = {"archaeology"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Archaeology" }} },
                                { name = "Blacksmithing (Achievements)", keywords = {"blacksmithing"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Blacksmithing" }} },
                                { name = "Cooking (Achievements)", keywords = {"cooking"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cooking" }} },
                                { name = "Enchanting (Achievements)", keywords = {"enchanting"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Enchanting" }} },
                                { name = "Engineering (Achievements)", keywords = {"engineering"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Engineering" }} },
                                { name = "Fishing (Achievements)", keywords = {"fishing"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Fishing" }} },
                                { name = "First Aid (Achievements)", keywords = {"first aid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "First Aid" }} },
                                { name = "Herbalism (Achievements)", keywords = {"herbalism"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Herbalism" }} },
                                { name = "Inscription (Achievements)", keywords = {"inscription"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Inscription" }} },
                                { name = "Jewelcrafting (Achievements)", keywords = {"jewelcrafting"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Jewelcrafting" }} },
                                { name = "Leatherworking (Achievements)", keywords = {"leatherworking"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Leatherworking" }} },
                                { name = "Mining (Achievements)", keywords = {"mining"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Mining" }} },
                                { name = "Skinning (Achievements)", keywords = {"skinning"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Skinning" }} },
                                { name = "Tailoring (Achievements)", keywords = {"tailoring"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Tailoring" }} },
                            },
                        },
                        {
                            name = "Quests (Achievements)",
                            keywords = {"quests", "quest"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Quests" }},
                            children = {
                                { name = "Battle for Azeroth - Quests (Achievements)", keywords = {"battle for azeroth", "bfa"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" }} },
                                { name = "Cataclysm - Quests (Achievements)", keywords = {"cataclysm"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" }} },
                                { name = "Draenor - Quests (Achievements)", keywords = {"draenor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor" }} },
                                { name = "Dragonflight - Quests (Achievements)", keywords = {"dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight" }} },
                                { name = "Eastern Kingdoms - Quests (Achievements)", keywords = {"eastern kingdoms"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Eastern Kingdoms" }} },
                                { name = "Kalimdor - Quests (Achievements)", keywords = {"kalimdor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Kalimdor" }} },
                                { name = "Legion - Quests (Achievements)", keywords = {"legion"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion" }} },
                                { name = "Midnight - Quests (Achievements)", keywords = {"midnight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight" }} },
                                { name = "Northrend - Quests (Achievements)", keywords = {"northrend"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Northrend" }} },
                                { name = "Outland - Quests (Achievements)", keywords = {"outland"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Outland" }} },
                                { name = "Pandaria - Quests (Achievements)", keywords = {"pandaria"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" }} },
                                { name = "Shadowlands - Quests (Achievements)", keywords = {"shadowlands"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" }} },
                                { name = "The Dragon Isles - Quests (Achievements)", keywords = {"dragon isles", "dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Dragon Isles" }} },
                                { name = "The War Within - Quests (Achievements)", keywords = {"war within"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The War Within" }} },
                            },
                        },
                        {
                            name = "Reputation (Achievements)",
                            keywords = {"reputation", "rep", "factions"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Reputation" }},
                            children = {
                                { name = "Battle for Azeroth - Reputation (Achievements)", keywords = {"battle for azeroth", "bfa"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" }} },
                                { name = "Cataclysm - Reputation (Achievements)", keywords = {"cataclysm"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" }} },
                                { name = "Classic - Reputation (Achievements)", keywords = {"classic"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Classic" }} },
                                { name = "Draenor - Reputation (Achievements)", keywords = {"draenor"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor" }} },
                                { name = "Dragonflight - Reputation (Achievements)", keywords = {"dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight" }} },
                                { name = "Legion - Reputation (Achievements)", keywords = {"legion"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion" }} },
                                { name = "Midnight - Reputation (Achievements)", keywords = {"midnight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight" }} },
                                { name = "Northrend - Reputation (Achievements)", keywords = {"northrend"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Northrend" }} },
                                { name = "Outland - Reputation (Achievements)", keywords = {"outland"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Outland" }} },
                                { name = "Pandaria - Reputation (Achievements)", keywords = {"pandaria"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" }} },
                                { name = "Shadowlands - Reputation (Achievements)", keywords = {"shadowlands"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" }} },
                                { name = "The Burning Crusade - Reputation (Achievements)", keywords = {"the burning crusade", "tbc"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" }} },
                                { name = "The Dragon Isles - Reputation (Achievements)", keywords = {"dragon isles", "dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Dragon Isles" }} },
                                { name = "The War Within - Reputation (Achievements)", keywords = {"war within"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The War Within" }} },
                                { name = "Wrath of the Lich King (Achievements)", keywords = {"wrath of the lich king", "wrath", "wotlk"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Wrath of the Lich King" }} },
                            },
                        },
                        {
                            name = "World Events (Achievements)",
                            keywords = {"world events", "holidays", "seasonal"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "World Events" }},
                            children = {
                                { name = "Anniversary Celebration (Achievements)", keywords = {"anniversary celebration", "anniversary"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Anniversary Celebration" }} },
                                { name = "Brawler's Guild (Achievements)", keywords = {"brawler's guild", "brawler"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Brawler's Guild" }} },
                                { name = "Brewfest (Achievements)", keywords = {"brewfest"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Brewfest" }} },
                                { name = "Children's Week (Achievements)", keywords = {"children's week"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Children's Week" }} },
                                { name = "Dastardly Duos (Achievements)", keywords = {"dastardly duos", "dastardly"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dastardly Duos" }} },
                                { name = "Day of the Dead (Achievements)", keywords = {"day of the dead"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Day of the Dead" }} },
                                { name = "Darkmoon Faire (Achievements)", keywords = {"darkmoon faire", "darkmoon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Darkmoon Faire" }} },
                                { name = "Feast of Winter Veil (Achievements)", keywords = {"feast of winter veil", "winter veil", "christmas"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Feast of Winter Veil" }} },
                                { name = "Hallow's End (Achievements)", keywords = {"hallow's end", "halloween"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Hallow's End" }} },
                                { name = "Lunar Festival (Achievements)", keywords = {"lunar festival"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lunar Festival" }} },
                                { name = "Love is in the Air (Achievements)", keywords = {"love is in the air", "valentine"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Love is in the Air" }} },
                                { name = "Midsummer (Achievements)", keywords = {"midsummer", "midsummer fire festival"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midsummer" }} },
                                { name = "Noblegarden (Achievements)", keywords = {"noblegarden", "easter"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Noblegarden" }} },
                                { name = "Pilgrim's Bounty (Achievements)", keywords = {"pilgrim's bounty", "thanksgiving"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pilgrim's Bounty" }} },
                                { name = "Timewalking (Achievements)", keywords = {"timewalking"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Timewalking" }} },
                                { name = "Winter Veil (Achievements)", keywords = {"winter veil"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Winter Veil" }} },
                            },
                        },
                    },
                },

                -- GUILD ACHIEVEMENTS (Tab 2)
                {
                    name = "Guild Achievements",
                    keywords = {"guild achievements", "guild tab", "guild points"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 2 }},
                    children = {
                        -- GUILD ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
                        {
                            name = "Guild: Dungeons & Raids",
                            keywords = {"dungeons & raids", "dungeons", "raids"},
                            category = "Guild Achievements",
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" }},
                            children = {
                                { name = "Guild: Battle Dungeon", keywords = {"battle dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" }} },
                                { name = "Guild: Battle Raid", keywords = {"battle raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" }} },
                                { name = "Guild: Cataclysm Dungeon", keywords = {"cataclysm dungeon", "cata dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" }} },
                                { name = "Guild: Cataclysm Raid", keywords = {"cataclysm raid", "cata raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" }} },
                                { name = "Guild: Classic", keywords = {"classic"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Classic" }} },
                                { name = "Guild: Draenor Dungeon", keywords = {"draenor dungeon", "wod dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" }} },
                                { name = "Guild: Draenor Raid", keywords = {"draenor raid", "wod raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" }} },
                                { name = "Guild: Dragonflight Dungeon", keywords = {"dragonflight dungeon", "df dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" }} },
                                { name = "Guild: Dragonflight Raid", keywords = {"dragonflight raid", "df raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" }} },
                                { name = "Guild: Legion Dungeon", keywords = {"legion dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" }} },
                                { name = "Guild: Legion Raid", keywords = {"legion raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" }} },
                                { name = "Guild: Lich King Dungeon", keywords = {"lich king dungeon", "wotlk dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" }} },
                                { name = "Guild: Lich King Raid", keywords = {"lich king raid", "wotlk raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" }} },
                                { name = "Guild: Midnight Dungeon", keywords = {"midnight dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" }} },
                                { name = "Guild: Midnight Raid", keywords = {"midnight raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" }} },
                                { name = "Guild: Pandaria Dungeon", keywords = {"pandaria dungeon", "mop dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" }} },
                                { name = "Guild: Pandaria Raid", keywords = {"pandaria raid", "mop raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" }} },
                                { name = "Guild: Shadowlands Dungeon", keywords = {"shadowlands dungeon", "sl dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" }} },
                                { name = "Guild: Shadowlands Raid", keywords = {"shadowlands raid", "sl raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" }} },
                                { name = "Guild: The Burning Crusade", keywords = {"the burning crusade", "tbc"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" }} },
                                { name = "Guild: War Within Dungeon", keywords = {"war within dungeon", "tww dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" }} },
                                { name = "Guild: War Within Raid", keywords = {"war within raid", "tww raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" }} },
                            },
                        },
                        { name = "Guild: General", keywords = {"general"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "General" }} },
                        { name = "Guild: Guild Feats of Strength", keywords = {"guild feats of strength", "guild feats", "fos"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Guild Feats of Strength" }} },
                        { name = "Guild: Player vs. Player", keywords = {"player vs. player", "pvp", "guild pvp"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }},
                            children = {
                                { name = "Guild: Arena", keywords = {"arena"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Arena" }} },
                                { name = "Guild: Battlegrounds", keywords = {"battlegrounds", "bg"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battlegrounds" }} },
                            },
                        },
                        { name = "Guild: Professions", keywords = {"professions", "profession", "crafting"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Professions" }} },
                        { name = "Guild: Quests", keywords = {"quests", "quest"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Quests" }} },
                        { name = "Guild: Reputation", keywords = {"reputation", "rep", "factions"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Reputation" }} },
                    },
                },

                -- STATISTICS (Tab 3)
                {
                    name = "Statistics",
                    keywords = {"statistics", "stats tab", "player statistics"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 3 }},
                    children = {
                        -- STATISTICS CATEGORIES (Auto-generated by Harvester)
                        {
                            name = "Character Statistics",
                            keywords = {"character"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Character" }},
                            children = {
                                { name = "Consumables Statistics", keywords = {"consumables"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Consumables" }} },
                                { name = "Wealth Statistics", keywords = {"wealth"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Wealth" }} },
                            },
                        },
                        { name = "Kills Statistics", keywords = {"kills", "kill count"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Kills" }} },
                        { name = "Deaths Statistics", keywords = {"deaths"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Deaths" }} },
                        { name = "Quests Statistics", keywords = {"quests", "quest count"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Quests" }} },
                        { name = "Skills Statistics", keywords = {"skills"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Skills" }} },
                        { name = "Travel Statistics", keywords = {"travel", "distance", "flight paths"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Travel" }} },
                        { name = "Social Statistics", keywords = {"social", "friends", "groups"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Social" }} },
                        { name = "Delves Statistics", keywords = {"delves"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Delves" }} },
                        {
                            name = "Combat Statistics",
                            keywords = {"combat"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Combat" }},
                            children = {
                                { name = "Buffs Statistics", keywords = {"buffs"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Buffs" }} },
                                { name = "Damage Statistics", keywords = {"damage"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Damage" }} },
                                { name = "Healing Statistics", keywords = {"healing"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Healing" }} },
                            },
                        },
                        {
                            name = "Dungeons & Raids Statistics",
                            keywords = {"dungeons & raids", "dungeons", "raids"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" }},
                            children = {
                                { name = "Lich King - D&R Statistics", keywords = {"lich king", "wotlk"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Lich King" }} },
                                { name = "Cataclysm - D&R Statistics", keywords = {"cataclysm"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Cataclysm" }} },
                                { name = "Pandaria - D&R Statistics", keywords = {"pandaria"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Pandaria" }} },
                                { name = "Draenor - D&R Statistics", keywords = {"draenor"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Draenor" }} },
                                { name = "Legion - D&R Statistics", keywords = {"legion"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Legion" }} },
                                { name = "Battle for Azeroth - D&R Statistics", keywords = {"battle for azeroth", "bfa"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Battle for Azeroth" }} },
                                { name = "Shadowlands - D&R Statistics", keywords = {"shadowlands"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Shadowlands" }} },
                                { name = "Dragonflight - D&R Statistics", keywords = {"dragonflight"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Dragonflight" }} },
                                { name = "The War Within - D&R Statistics", keywords = {"war within"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "The War Within" }} },
                            },
                        },
                        {
                            name = "Player vs. Player Statistics",
                            keywords = {"player vs. player", "pvp"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" }},
                            children = {
                                { name = "Rated Arenas Statistics", keywords = {"arena", "rated arenas"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Rated Arenas" }} },
                                {
                                    name = "Battlegrounds Statistics",
                                    keywords = {"battlegrounds", "bg"},
                                    steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Battlegrounds" }},
                                    children = {
                                        { name = "Alterac Valley Statistics", keywords = {"alterac valley", "av"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Alterac Valley" }} },
                                        { name = "Arathi Basin Statistics", keywords = {"arathi basin", "ab"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Arathi Basin" }} },
                                        { name = "Eye of the Storm Statistics", keywords = {"eye of the storm", "eots"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Eye of the Storm" }} },
                                        { name = "Strand of the Ancients Statistics", keywords = {"strand of the ancients", "sota"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Strand of the Ancients" }} },
                                        { name = "Warsong Gulch Statistics", keywords = {"warsong gulch", "wsg"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Warsong Gulch" }} },
                                        { name = "Wintergrasp Statistics", keywords = {"wintergrasp", "wg"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Wintergrasp" }} },
                                    },
                                },
                                { name = "Rated Battlegrounds Statistics", keywords = {"rated battlegrounds", "rbg"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Rated Battlegrounds" }} },
                                { name = "World Statistics", keywords = {"world"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "World" }} },
                            },
                        },
                        { name = "Pet Battles Statistics", keywords = {"pet battles", "battle pets"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Pet Battles" }} },
                        { name = "Proving Grounds Statistics", keywords = {"proving grounds"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Proving Grounds" }} },
                        { name = "Legacy Statistics", keywords = {"legacy"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Legacy" }} },
                        { name = "World Events Statistics", keywords = {"world events", "holidays"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "World Events" }} },
                        -- Manual entry: Duel Statistics (specific deep navigation)
                        {
                            name = "Duel Statistics",
                            keywords = {"duel", "duels", "dueling", "1v1", "duels won", "duels lost"},
                            category = "Statistics",
                            steps = {
                                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
                                { waitForFrame = "AchievementFrame", statisticsCategory = "World" },
                            },
                        },
                    },
                },
            },
        },

        -- QUEST LOG
        {
            name = "Quest Log",
            keywords = {"quest", "quests", "objectives", "log", "journal"},
            category = "Menu Bar",
            buttonFrame = "QuestLogMicroButton",
            steps = {{ buttonFrame = "QuestLogMicroButton" }},
        },

        -- HOUSING
        {
            name = "Housing Dashboard",
            keywords = {"housing", "house", "home", "dashboard", "player housing"},
            category = "Menu Bar",
            buttonFrame = "HousingMicroButton",
            steps = {{ buttonFrame = "HousingMicroButton" }},
        },

        -- GUILD & COMMUNITIES
        {
            name = "Guild & Communities",
            keywords = {"guild", "communities", "social", "clan"},
            category = "Menu Bar",
            buttonFrame = "GuildMicroButton",
            steps = {{ buttonFrame = "GuildMicroButton" }},
        },

        -- GROUP FINDER
        {
            name = "Group Finder",
            keywords = {"lfg", "lfd", "lfr", "finder", "queue", "group finder"},
            category = "Menu Bar",
            buttonFrame = "LFDMicroButton",
            steps = {{ buttonFrame = "LFDMicroButton" }},
            children = {
                -- PVE SECTION
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

                -- PVP SECTION
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

                -- MYTHIC+ SECTION
                {
                    name = "Mythic+ Dungeons",
                    keywords = {"mythic", "mythic+", "m+", "keystone", "mythic plus", "keys"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 3 }},
                },
            },
        },

        -- WARBAND COLLECTIONS
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

        -- TRANSMOGRIFICATION
        {
            name = "Transmogrification",
            keywords = {"transmogrification", "transmog", "tmog", "mog", "wardrobe", "outfit", "outfits", "appearance", "keymog"},
            category = "Transmogrification",
            icon = { file = 6119963, coords = { 0.0183, 0.2629, 0.0131, 0.5152 } },
            steps = {{ loadTransmog = true }},
        },

        -- ADVENTURE GUIDE
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

        -- GAME MENU / HELP / SHOP
        -- buttonFrame is kept solely so GetButtonIcon can derive the
        -- "UI-HUD-MicroMenu-GameMenu-Up" atlas from MainMenuMicroButton's
        -- textureName. The actual click goes through slashCommand because
        -- the micro button's OnClick (and ToggleGameMenu) call
        -- SpellStopCasting() when a spell is targeting -- protected, and
        -- it taints when fired from a /run script context.
        {
            name = "Game Menu",
            keywords = {"menu", "settings", "options", "escape", "esc", "logout", "quit", "exit", "interface"},
            category = "Menu Bar",
            buttonFrame = "MainMenuMicroButton",
            slashCommand = "/run if GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) else ShowUIPanel(GameMenuFrame) end",
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

        -- PORTRAIT MENU OPTIONS (Auto-generated by Harvester)
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

        -- OTHER UI ELEMENTS (no tree hierarchy, standalone)
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
            slashCommand = "/run if WorldMapFrame:IsShown() then HideUIPanel(WorldMapFrame) else ShowUIPanel(WorldMapFrame) end",
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

        -- Quick action: dismiss any active companion. /dismisspet alone
        -- only handles hunter/warlock pets, so the macrotext also toggles
        -- the active battle-pet companion via SummonPetByGUID with the
        -- currently-summoned GUID (which dismisses it). Two lines so one
        -- click covers both kinds of "pet" the player might mean.
        {
            name = "Dismiss Pet",
            keywords = {"dismiss", "dismiss pet", "pet", "companion", "summon",
                        "battle pet", "critter", "minion"},
            category = "Action",
            icon = 631719,
            slashCommand = "/dismisspet\n/run local g = C_PetJournal and C_PetJournal.GetSummonedPetGUID and C_PetJournal.GetSummonedPetGUID(); if g then C_PetJournal.SummonPetByGUID(g) end",
        },
    }

    -- Flatten the tree into the flat uiSearchData array
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

    -- Tag entries with isPvP / isPvE for filter support
    local PVP_NAMES = {
        ["PvP Talents"] = true, ["War Mode"] = true, ["PvP Flag"] = true,
    }
    for _, item in ipairs(uiSearchData) do
        -- PvP: explicit category, known PvP entries, or under Player vs. Player tree
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
        -- PvE: Group Finder PvE subtree (Dungeons & Raids, Mythic+)
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

-- SEARCH SCORING HELPERS
-- Word-boundary matching, initials matching, and fuzzy/typo tolerance.

-- Pairs of words that are close in edit distance but semantically opposite.
-- Matching between these pairs is suppressed across initials and fuzzy scoring.
local FUZZY_BLOCKLIST = {
    ["pvp"] = { ["pve"] = true },
    ["pve"] = { ["pvp"] = true },
    -- "ability" / "abilities" appear as keywords on every ability entry
    -- so multi-word queries like "feral abilities" can scope to a spec.
    -- Block fuzzy hits between them and the literal stat "agility" so
    -- typing "agility" doesn't drag every ability into the results.
    ["agility"]   = { ["ability"] = true, ["abilities"] = true },
    ["ability"]   = { ["agility"] = true },
    ["abilities"] = { ["agility"] = true },
}

-- Words that real abbreviations skip without comment ("lfg" = "Looking For
-- Group", "tot" = "Throne of Thunder"). Initials Strategy 2 may step over
-- these for free; skipping any non-stopword (a content word like "atrocity"
-- in "Shurrai, Atrocity of the Undersea") breaks the chain so unrelated
-- queries don't get a misleading high score from accidental letter
-- alignment.
local INITIALS_STOPWORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["or"] = true, ["in"] = true, ["on"] = true,
    ["at"] = true, ["by"] = true, ["for"] = true, ["to"] = true,
    ["with"] = true, ["from"] = true,
}

-- A word boundary is the start of the string or right after a space/punctuation.
-- Returns true if found at a boundary, false if only found mid-word or not at all.
function Database:FindAtWordBoundary(text, query)
    -- Check at start of string. sfind avoids the per-call substring
    -- allocation that ssub(text, 1, #query) would create.
    local found = sfind(text, query, 1, true)
    if not found then return false end
    if found == 1 then return true end
    -- After word boundaries (space, dash, parenthesis, colon, slash, dot).
    -- sbyte avoids creating a 1-char string per check.
    while found do
        local prev = sbyte(text, found - 1)
        -- 32=space, 45=- 40=( 58=: 47=/ 46=.
        if prev == 32 or prev == 45 or prev == 40
           or prev == 58 or prev == 47 or prev == 46 then
            return true
        end
        found = sfind(text, query, found + 1, true)
    end
    return false
end

-- Score how well `query` matches as initials/abbreviation of words in `text`.
-- "rb" → "rated battlegrounds" = 130 (each char matches a word start)
-- "raba" → "random battleground" = 125 (prefix of words)
-- "ranb" → "random battleground" = 115 (longer prefix matching)
-- Returns 0 if no reasonable initials match found.
function Database:ScoreInitials(text, query)
    -- Use cached word split (input is already lowercase)
    local words = GetWords(text)
    if #words < 2 then return 0 end  -- initials only make sense for multi-word

    -- Blocklist: "pve" must never initials-match text containing word "pvp" (and vice versa)
    local blocked = FUZZY_BLOCKLIST[query]
    if blocked then
        for wi = 1, #words do
            if blocked[words[wi]] then return 0 end
        end
    end

    local queryLen = #query
    local numWords = #words

    -- Strategy 1: Pure initials - each query char matches the first letter of consecutive words
    -- "rb" → R(ated) B(attlegrounds)
    if queryLen <= numWords then
        local allMatch = true
        for i = 1, queryLen do
            if sbyte(query, i) ~= sbyte(words[i], 1) then
                allMatch = false
                break
            end
        end
        if allMatch then
            -- Bonus for matching ALL words' initials (not partial)
            local bonus = (queryLen == numWords) and 135 or 130
            return bonus
        end
    end

    -- Strategy 2: Prefix-of-words - each query segment matches the start
    -- of a word, walking left-to-right. "raba" → "ra(ndom) ba(ttleground)"
    -- greedily consumes query chars across consecutive words.
    -- Once the chain has started (wordsMatched > 0), encountering a
    -- non-stopword that doesn't match breaks the chain. Without this,
    -- queries like "sound" wrongly initial-match "Shurrai, Atrocity of
    -- the Undersea" via S(hurrai) o(f) und(ersea), skipping the content
    -- word "atrocity" silently. Stopwords (of/the/and/...) may still be
    -- skipped — that's what lets "tot" → "Throne of Thunder" work.
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

-- Score fuzzy/typo matching using Damerau-Levenshtein distance.
-- Only applied to individual words in `text` that are similar in length to `query`.
-- Returns a score > 0 if a close match is found, 0 otherwise.

function Database:ScoreFuzzy(text, query, queryLen)
    -- Length-scaled typo tolerance (1 edit per ~4 chars), the same
    -- shape Algolia / Elasticsearch AUTO mode use. Without this scale,
    -- a 5-char query like "skull" would fuzzy-match "spell" (2 edits)
    -- and similar 40%-different words, drowning real results.
    local maxEdits
    if queryLen >= 8 then maxEdits = 2
    elseif queryLen >= 4 then maxEdits = 1
    else return 0  -- queries under 4 chars: no fuzzy, substring covers them
    end

    local queryFirst = sbyte(query, 1)
    local bestScore = 0
    local blocked = FUZZY_BLOCKLIST[query]
    local textWords = GetWords(text)
    for wi = 1, #textWords do
        local word = textWords[wi]
        -- First-letter constraint (Algolia default). "easter" vs
        -- "master" is a 1-edit match technically, but they're
        -- semantically unrelated — typos almost never change the
        -- first character, and this rule kills the false-positive
        -- flood without dropping real typos like "achievmnts" →
        -- "achievements".
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

-- Requires first character match to avoid spurious hits like "ahn'" in "magtheridon's".
-- Uses sbyte() instead of ssub() inside the inner loop -- ssub creates a
-- fresh 1-char string per call which adds up to thousands of short-lived
-- strings per keystroke (3700 entries x queryLen iterations).
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
    -- Reject sparse matches: "inn" in "instance" matches i(1)n(2)n(6) but span 6 > 5
    return (wi - 1) - firstPos + 1 <= queryLen * 2 - 1
end

-- Damerau-Levenshtein distance (supports transpositions).
-- Capped: returns early if distance exceeds 2 (saves CPU).
function Database:DamerauLevenshtein(s1, s2, len1, len2)
    if mabs(len1 - len2) > 2 then return 3 end  -- too different, skip

    -- Reuse module-level tables (rotated each row, no allocation)
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
                prev[j] + 1,        -- deletion
                curr[j - 1] + 1,    -- insertion
                prev[j - 1] + cost  -- substitution
            )
            -- Transposition
            if i > 1 and j > 1
                and c1 == sbyte(s2, j - 1)
                and c1Prev == c2 then
                curr[j] = mmin(curr[j], prev2[j - 2] + cost)
            end
            if curr[j] < minInRow then minInRow = curr[j] end
        end
        -- Early exit if the best possible in this row already exceeds threshold
        if minInRow > 2 then return 3 end
        prev2, prev, curr = prev, curr, prev2  -- rotate rows
    end
    return prev[len2]
end

-- Fast pre-filter: every distinct character in the query must appear
-- somewhere in `text`. Order and position don't matter so fuzzy
-- matchers tolerant of transpositions (e.g., "acheivement" vs
-- "achievement") still pass through to the real scorers. Missing a
-- single query char is a definitive "cannot match" signal.
--
-- Builds a small byte-set from the text per call. For stable text
-- (POI names), the caller should cache result at a higher level; for
-- one-off scoring this remains cheap — O(|text| + |query|).
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
        if qb ~= 32 and not seen[qb] then  -- skip spaces (multi-word queries)
            return false
        end
    end
    return true
end

-- Unified name scoring: exact → starts-with → word-boundary → substring → initials → fuzzy.
-- All search features (UI, map zone, map POI) use this single function.
-- Returns a score ≥ 0. Caller decides the minimum threshold.
function Database:ScoreName(nameLower, query, queryLen, optQueryWords)
    -- Trim trailing whitespace so "windrnr " behaves like "windrnr"
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    -- Cheap pre-filter: if the query's chars don't appear in order in
    -- the name, no scoring path can match. Saves the subsequence +
    -- fuzzy DP pass on the ~90%+ of entries that obviously don't match.
    if not Database:CouldMatch(nameLower, query) then return 0 end

    local score = 0

    -- Whole-string matching (works for single and multi-word queries)
    -- sfind(plain) avoids the per-entry substring allocation that
    -- ssub(haystack, 1, n) == needle would create. With ~3700 entries
    -- scored per keystroke this is the dominant per-search alloc.
    if nameLower == query then
        score = 200
    elseif sfind(nameLower, query, 1, true) == 1 then
        score = 150
    elseif Database:FindAtWordBoundary(nameLower, query) then
        score = 120
    elseif sfind(nameLower, query, 1, true) then
        score = 30   -- mid-word substring
    end

    -- Initials matching: "rb" → "Rated Battlegrounds"
    if score < 130 then
        local initScore = Database:ScoreInitials(nameLower, query)
        if initScore > score then score = initScore end
    end

    -- Fuzzy/typo matching against whole query (queries >= 4 chars)
    if score < 100 and queryLen >= 4 then
        local fuzzyScore = Database:ScoreFuzzy(nameLower, query, queryLen)
        if fuzzyScore > score then score = fuzzyScore end
    end

    -- Subsequence matching against name words for vowel-stripped abbreviations
    -- Short queries (3-4): "qtr" → "quartermaster" (word must be 2x+ longer)
    -- Longer queries (5-7): "windrnr" → "windrunner" (must cover 60%+ of word)
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

    -- Per-word matching for multi-word queries:
    -- Split query into words and score each against name words.
    -- All query words must match for a score to be awarded.
    -- Fires even when an inferior path already returned a low score
    -- (e.g. mid-word substring 30) so a multi-word typo match like
    -- "estern kingd" → "Eastern Kingdoms" can still surface.
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
                            -- Subsequence for vowel-stripped words
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

-- Unified keyword scoring: additive score from matching against a list of keywords.
-- Returns a total score to ADD to the name score.
function Database:ScoreKeywords(keywordsLower, query, queryLen, optQueryWords)
    if not keywordsLower then return 0 end

    -- Trim trailing whitespace to match ScoreName behavior
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    -- Use pre-split query words if provided, otherwise split here
    local queryWords = optQueryWords
    if not queryWords then
        queryWords = {}
        for word in query:gmatch("%S+") do
            queryWords[#queryWords + 1] = word
        end
    end

    -- Single-word query: take the BEST keyword match only (not sum).
    -- Summing caused items with redundant keywords (e.g. "reputation" +
    -- "reputation achievements") to outscore items with a better name match.
    local numKeywords = #keywordsLower
    if #queryWords == 1 then
        local best = 0
        for ki = 1, numKeywords do
            local kw = keywordsLower[ki]
            local kwScore = 0
            if kw == query then
                -- Short abbreviations (2-3 chars) are intentional, boost above initials
                kwScore = queryLen <= 3 and 140 or 80
            elseif sfind(kw, query, 1, true) == 1 then
                kwScore = 70
            elseif Database:FindAtWordBoundary(kw, query) then
                kwScore = 55
            end
            -- Initials on keywords (skip for 1-2 char queries: penalty drops score below threshold)
            if kwScore < 60 and queryLen >= 3 then
                local initScore = Database:ScoreInitials(kw, query)
                if initScore > 0 then
                    local penalty = queryLen == 3 and 70 or 20
                    kwScore = mmax(kwScore, initScore - penalty)
                end
            end
            -- Fuzzy on keywords
            if kwScore < 40 and queryLen >= 4 then
                local kf = Database:ScoreFuzzy(kw, query, queryLen)
                if kf > 0 then kwScore = mmax(kwScore, kf) end
            end
            -- Subsequence per-word in keywords
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

    -- For multi-word queries, match each word separately and take best match per word.
    -- All query words >= 2 chars must match at least one keyword; a single
    -- unmatched word zeroes the total to prevent common words like "of" from
    -- producing false positives. Single-character words are SKIPPED (not
    -- failed) so a mid-type query like "feral a" still passes through entries
    -- that match "feral" — otherwise the prevCandidates incremental narrowing
    -- chain inherits an empty set and "feral abil" silently returns nothing.
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
                -- Initials on keywords (skip for 1-2 char queries: penalty drops score below threshold)
                if kwScore < 60 and queryWordLen >= 3 then
                    local initScore = Database:ScoreInitials(kw, queryWord)
                    if initScore > 0 then
                        local penalty = queryWordLen == 3 and 70 or 20
                        kwScore = mmax(kwScore, initScore - penalty)
                    end
                end
                -- Fuzzy on keywords
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
        -- queryWordLen < 2: skipped (mid-type), don't fail entry
    end

    return total
end

-- Incremental search state: when the user extends the previous query (e.g. "mou" → "moun"),
-- only re-score entries that matched before instead of the full dataset.
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
    -- Discount entries whose match came purely from embedded keyword
    -- text (no query word actually appeared in the entry's own name).
    -- Without this, an item whose keyword list happens to contain
    -- "Eastern Kingdoms" outranks the literal Eastern Kingdoms zone
    -- because keyword sums (90 per word) beat name-only avg-capped
    -- scoring (110 max).
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

    -- First-call build: without a ready prefix index every search falls
    -- through to a linear scan over uiSearchData. After dynamic providers
    -- populate that's ~1500+ entries per keystroke. Build once on demand
    -- so the FIRST search after reload doesn't pay the linear-scan cost
    -- on every keystroke that follows.
    if not prefixIndexReady then
        self:BuildSearchPrefixIndex()
    end

    query = slower(query)
    local queryLen = #query

    -- Pre-trim trailing whitespace once (avoids per-entry match() in scoring)
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

    -- Detect "<instance> boss" style queries. When the user mentions
    -- "boss" anywhere in the query, bosses are allowed to match by
    -- their instance keyword (e.g. "icc boss" -> all ICC bosses).
    -- Without "boss" present, bosses are restricted to name-only
    -- matches so plain "raid"/"dungeon"/"icc" don't flood with them.
    local bossQueryWord = false
    -- Same gate for achievement entries: there are ~175 of them, and
    -- nearly any common word (easter, mounts, kill, dungeon...) shows
    -- up in some achievement keyword. Gate them behind the user
    -- typing "ach"/"achievement"/etc. or a strong name match.
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

    -- Determine candidate set: incremental (previous matches) or full database
    local skipKey = skipCategories and (
        (skipCategories["Mount"] and "M" or "") ..
        (skipCategories["Toy"] and "T" or "") ..
        (skipCategories["Pet"] and "P" or "") ..
        (skipCategories["Outfit"] and "O" or "") ..
        (skipCategories["Heirloom"] and "H" or "") ..
        (skipCategories["Loot"] and "L" or "")
    ) or ""

    -- prevCandidates is missing entries the current (more permissive)
    -- scoring pass would now match. Two distinct cases trigger this:
    --
    --   1. A gating flag flipped false → true on this keystroke
    --      ("icc bos" → "icc boss" turns bossQueryWord on; "characters"
    --      → "characters ach..." turns achQueryWord on). Boss /
    --      achievement entries that previously failed the stricter
    --      gate were never scored, so prevCandidates contains zero of
    --      them.
    --
    --   2. A new word was just appended to a stat-keyword query
    --      ("haste" → "haste ring"). lootStatQueryWord stays true
    --      throughout, but loot rings are missing from the "ha"
    --      prefix bucket (their lootStatKw is populated lazily, after
    --      the index was built), so they never made it into
    --      prevCandidates. Adding "ring" pulls them in via the "ri"
    --      bucket on the multi-token path.
    --
    -- Either case bypasses extension for one keystroke and lets the
    -- prefix lookup rebuild the candidate set.
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
        -- Forward extension of the prior query: re-score the prior
        -- candidates only. (Cheapest path.)
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
                -- Loot: match by item name, slot, stats, and source keywords.
                -- Each query word scores against all keyword types and takes
                -- the best match. Words that match nothing eliminate the item.
                local totalScore = 0

                local nameWords = GetWords(nameLower)
                for qi = 1, #queryWords do
                    local qw = queryWords[qi]
                    local qwLen = #qw
                    local bestWord = 0

                    -- Score against item name words (prefix match per word).
                    -- Name match must outrank lootSourceKw (boss name)
                    -- match below; otherwise loot whose own name contains
                    -- the query gets buried under same-boss loot that
                    -- only matched via the encounter name.
                    for ni = 1, #nameWords do
                        local nw = nameWords[ni]
                        if nw == qw then
                            bestWord = mmax(bestWord, qi == 1 and 130 or 120)
                        elseif ssub(nw, 1, qwLen) == qw then
                            bestWord = mmax(bestWord, qi == 1 and 115 or 105)
                        end
                    end

                    -- Score against slot keywords
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

                    -- Score against stat keywords
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

                    -- Score against source keywords (boss/dungeon name).
                    -- Prefix match on a boss name is a strong real signal
                    -- ("nexu" -> "Nexus-Point Xenas"), so its score must
                    -- beat a 1-edit fuzzy hit (85) on an unrelated setting
                    -- name like "Next View" -- otherwise gear from the
                    -- searched encounter ranks below misspellings.
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
                -- Bosses match by name only when the query doesn't
                -- mention "boss". This prevents plain "raid"/"dungeon"
                -- /"icc" from dragging every encounter into the list.
                score = Database:ScoreName(nameLower, query, queryLen, queryWords)
            else
                local cat = data.category
                local isAchEntry = cat == "Achievements" or cat == "Guild Achievements"
                                   or cat == "Statistics"
                if isAchEntry and not achQueryWord then
                    -- Restrict achievement entries to strong name matches
                    -- only (exact / prefix / starts-with-word). Skip the
                    -- keyword score entirely so short common keyword
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
                    -- MAX, not SUM. Many entries put their lowercased name into
                    -- keywordsLower (talents, abilities, mounts, ...), so a sum
                    -- double-counts the same fuzzy hit -- "hearth" matching
                    -- "heart" once via the name and once via the keyword
                    -- silently doubles into 170, beating real 150 prefix
                    -- matches like "Hearthstone Board".
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
    -- Trim stale entries from previous search
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
    -- Clear stale data refs on pool slots above the current result
    -- count. Without this, a broad search followed by a narrow one
    -- leaves the pool holding refs from the broad search forever.
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

-- Static UI database must be built at load time (before ADDON_LOADED) so other
-- modules can reference uiSearchData during their own initialization.
-- Not routed through Core.lua SafeInit, so wrap here for error safety.
local initOk, initErr = pcall(Database.Initialize, Database)
if not initOk then
    print("|cffff4444EasyFind Database failed to initialize: " .. tostring(initErr) .. "|r")
end
