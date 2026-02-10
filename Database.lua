local ADDON_NAME, ns = ...

local Database = {}
ns.Database = Database

local Utils   = ns.Utils
local pairs, ipairs, type = Utils.pairs, Utils.ipairs, Utils.type
local tinsert, tsort, tconcat = Utils.tinsert, Utils.tsort, Utils.tconcat
local sfind, slower, ssub = Utils.sfind, Utils.slower, Utils.ssub
local mmin, mmax, mabs = Utils.mmin, Utils.mmax, Utils.mabs
local unpack = Utils.unpack

local uiSearchData = {}
-- Track which currencyIDs are already in the static database
local knownCurrencyIDs = {}

function Database:Initialize()
    self:BuildUIDatabase()
end

-- Called after PLAYER_LOGIN when C_CurrencyInfo is available
-- Scans the WoW currency list and injects any currencies not already in the static database
function Database:PopulateDynamicCurrencies()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return end

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

    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info then
            local depth = info.currencyListDepth or 0

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
                -- This currency isn't in our static database — inject it
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

                local entry = {
                    name = currName,
                    keywords = words,
                    category = "Currency",
                    buttonFrame = "CharacterMicroButton",
                    path = buildPath(),
                    steps = currSteps,
                    flashLabel = "Currency",
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
end

-- =============================================================================
-- TREE FLATTENER
-- Walks the tree and produces flat entries for the search/highlight engines.
-- Children inherit: buttonFrame, category, and accumulate path + steps from parents.
-- =============================================================================

function Database:FlattenTree(tree, parentPath, parentSteps, parentButtonFrame, parentCategory)
    parentPath = parentPath or {}
    parentSteps = parentSteps or {}

    for _, node in ipairs(tree) do
        local myButtonFrame = node.buttonFrame or parentButtonFrame
        local myCategory = node.category or parentCategory

        -- Accumulate steps: parent steps + this node's steps
        local mySteps = {}
        for _, s in ipairs(parentSteps) do mySteps[#mySteps + 1] = s end
        if node.steps then
            for _, s in ipairs(node.steps) do mySteps[#mySteps + 1] = s end
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
    -- =========================================================================
    -- UI TREE
    -- Each node: { name, keywords, [category], [buttonFrame], [steps], [children] }
    --   - category: inherited from parent if omitted
    --   - buttonFrame: inherited from parent if omitted
    --   - steps: only THIS node's new steps (flattener prepends parent steps)
    --   - path: auto-built from ancestor names (never specified manually)
    -- =========================================================================
    local uiTree = {

        -- =====================
        -- CHARACTER INFO
        -- =====================
        {
            name = "Character Info",
            keywords = {"character", "char", "stats", "gear", "equipment", "paperdoll", "attributes"},
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
                    keywords = {"titles", "title", "character title", "name title", "prefix", "suffix"},
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
                    children = {
                        -- =====================
                        -- CURRENCY ENTRIES (Auto-generated by Harvester)
                        -- =====================

                        -- Currency Headers (navigate to the header/section)
                        {
                            name = "Midnight Currencies",
                            keywords = {"midnight", "midnight currencies", "midnight currency"},
                            category = "Currency",
                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Midnight" }},
                            children = {
                                {
                                    name = "Twilight's Blade Insignia",
                                    keywords = {"twilight's blade insignia", "twilight's", "blade", "insignia", "midnight twilight's blade insignia"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3319 }},
                                },
                            },
                        },
                        {
                            name = "Dungeon and Raid Currencies",
                            keywords = {"dungeon and raid", "dungeon", "raid", "dungeon and raid currencies", "dungeon and raid currency"},
                            category = "Currency",
                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Dungeon and Raid" }},
                            children = {
                                {
                                    name = "Timewarped Badge",
                                    keywords = {"timewarped badge", "timewarped", "badge", "dungeon and raid timewarped badge"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 1166 }},
                                },
                            },
                        },
                        {
                            name = "Miscellaneous Currencies",
                            keywords = {"miscellaneous", "miscellaneous currencies", "miscellaneous currency"},
                            category = "Currency",
                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Miscellaneous" }},
                            children = {
                                {
                                    name = "Community Coupons",
                                    keywords = {"community coupons", "community", "coupons", "miscellaneous community coupons"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3363 }},
                                },
                                {
                                    name = "Darkmoon Prize Ticket",
                                    keywords = {"darkmoon prize ticket", "darkmoon", "prize", "ticket", "miscellaneous darkmoon prize ticket"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 515 }},
                                },
                                {
                                    name = "Trader's Tender",
                                    keywords = {"trader's tender", "trader's", "tender", "miscellaneous trader's tender"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 2032 }},
                                },
                            },
                        },
                        {
                            name = "Player vs. Player Currencies",
                            keywords = {"player vs. player", "player", "pvp", "player vs. player currencies", "player vs. player currency"},
                            category = "Currency",
                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Player vs. Player" }},
                            children = {
                                {
                                    name = "Bloody Tokens",
                                    keywords = {"bloody tokens", "bloody", "tokens", "player vs. player bloody tokens"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 2123 }},
                                },
                                {
                                    name = "Conquest",
                                    keywords = {"conquest", "player vs. player conquest"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 1602 }},
                                },
                                {
                                    name = "Honor",
                                    keywords = {"honor", "player vs. player honor"},
                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 1792 }},
                                },
                            },
                        },
                        {
                            name = "Legacy Currencies",
                            keywords = {"legacy", "old", "legacy currencies", "legacy currency"},
                            category = "Currency",
                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Legacy" }},
                            children = {
                                {
                                    name = "War Within Currencies",
                                    keywords = {"war within", "war within currencies", "war within currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "War Within" }},
                                    children = {
                                        {
                                            name = "Kej",
                                            keywords = {"kej", "war within kej"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 3056 }},
                                        },
                                        {
                                            name = "Resonance Crystals",
                                            keywords = {"resonance crystals", "resonance", "crystals", "war within resonance crystals"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 2815 }},
                                        },
                                        {
                                            name = "Season 3 Currencies",
                                            keywords = {"season 3", "season", "season 3 currencies", "season 3 currency"},
                                            category = "Currency",
                                            steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Season 3" }},
                                            children = {
                                                {
                                                    name = "Restored Coffer Key",
                                                    keywords = {"restored coffer key", "restored", "coffer", "key", "season 3 restored coffer key"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3028 }},
                                                },
                                                {
                                                    name = "Undercoin",
                                                    keywords = {"undercoin", "season 3 undercoin"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 2803 }},
                                                },
                                                {
                                                    name = "Valorstones",
                                                    keywords = {"valorstones", "season 3 valorstones"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3008 }},
                                                },
                                                {
                                                    name = "Weathered Ethereal Crest",
                                                    keywords = {"weathered ethereal crest", "weathered", "ethereal", "crest", "season 3 weathered ethereal crest"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3284 }},
                                                },
                                                {
                                                    name = "Carved Ethereal Crest",
                                                    keywords = {"carved ethereal crest", "carved", "ethereal", "crest", "season 3 carved ethereal crest"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3286 }},
                                                },
                                                {
                                                    name = "Runed Ethereal Crest",
                                                    keywords = {"runed ethereal crest", "runed", "ethereal", "crest", "season 3 runed ethereal crest"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3288 }},
                                                },
                                                {
                                                    name = "Gilded Ethereal Crest",
                                                    keywords = {"gilded ethereal crest", "gilded", "ethereal", "crest", "season 3 gilded ethereal crest"},
                                                    steps = {{ waitForFrame = "CharacterFrame", currencyID = 3290 }},
                                                },
                                            },
                                        },
                                    },
                                },
                                {
                                    name = "Dragonflight Currencies",
                                    keywords = {"dragonflight", "dragonflight currencies", "dragonflight currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Dragonflight" }},
                                    children = {
                                        {
                                            name = "Dragon Isles Supplies",
                                            keywords = {"dragon isles supplies", "dragon", "isles", "supplies", "dragonflight dragon isles supplies"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 2003 }},
                                        },
                                        {
                                            name = "Elemental Overflow",
                                            keywords = {"elemental overflow", "elemental", "overflow", "dragonflight elemental overflow"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 2118 }},
                                        },
                                    },
                                },
                                {
                                    name = "Shadowlands Currencies",
                                    keywords = {"shadowlands", "shadowlands currencies", "shadowlands currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" }},
                                    children = {
                                        {
                                            name = "Argent Commendation",
                                            keywords = {"argent commendation", "argent", "commendation", "shadowlands argent commendation"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1754 }},
                                        },
                                        {
                                            name = "Cataloged Research",
                                            keywords = {"cataloged research", "cataloged", "research", "shadowlands cataloged research"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1931 }},
                                        },
                                        {
                                            name = "Cosmic Flux",
                                            keywords = {"cosmic flux", "cosmic", "flux", "shadowlands cosmic flux"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 2009 }},
                                        },
                                        {
                                            name = "Cyphers of the First Ones",
                                            keywords = {"cyphers of the first ones", "cyphers", "shadowlands cyphers of the first ones"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1979 }},
                                        },
                                        {
                                            name = "Grateful Offering",
                                            keywords = {"grateful offering", "grateful", "offering", "shadowlands grateful offering"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1885 }},
                                        },
                                        {
                                            name = "Infused Ruby",
                                            keywords = {"infused ruby", "infused", "ruby", "shadowlands infused ruby"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1820 }},
                                        },
                                        {
                                            name = "Reservoir Anima",
                                            keywords = {"reservoir anima", "reservoir", "anima", "shadowlands reservoir anima"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1813 }},
                                        },
                                        {
                                            name = "Soul Ash",
                                            keywords = {"soul ash", "soul", "ash", "shadowlands soul ash"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1828 }},
                                        },
                                        {
                                            name = "Soul Cinders",
                                            keywords = {"soul cinders", "soul", "cinders", "shadowlands soul cinders"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1906 }},
                                        },
                                        {
                                            name = "Stygia",
                                            keywords = {"stygia", "shadowlands stygia"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1767 }},
                                        },
                                    },
                                },
                                {
                                    name = "Battle for Azeroth Currencies",
                                    keywords = {"battle for azeroth", "bfa", "battle for azeroth currencies", "battle for azeroth currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" }},
                                    children = {
                                        {
                                            name = "7th Legion Service Medal",
                                            keywords = {"7th legion service medal", "7th", "legion", "service", "medal", "battle for azeroth 7th legion service medal"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1717 }},
                                        },
                                        {
                                            name = "Coalescing Visions",
                                            keywords = {"coalescing visions", "coalescing", "visions", "battle for azeroth coalescing visions"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1755 }},
                                        },
                                        {
                                            name = "Echoes of Ny'alotha",
                                            keywords = {"echoes of ny'alotha", "echoes", "ny'alotha", "battle for azeroth echoes of ny'alotha"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1803 }},
                                        },
                                        {
                                            name = "Prismatic Manapearl",
                                            keywords = {"prismatic manapearl", "prismatic", "manapearl", "battle for azeroth prismatic manapearl"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1721 }},
                                        },
                                        {
                                            name = "Seafarer's Dubloon",
                                            keywords = {"seafarer's dubloon", "seafarer's", "dubloon", "battle for azeroth seafarer's dubloon"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1710 }},
                                        },
                                        {
                                            name = "War Resources",
                                            keywords = {"war resources", "war", "resources", "battle for azeroth war resources"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1560 }},
                                        },
                                    },
                                },
                                {
                                    name = "Legion Currencies",
                                    keywords = {"legion", "legion currencies", "legion currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Legion" }},
                                    children = {
                                        {
                                            name = "Curious Coin",
                                            keywords = {"curious coin", "curious", "coin", "legion curious coin"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1275 }},
                                        },
                                        {
                                            name = "Nethershard",
                                            keywords = {"nethershard", "legion nethershard"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1226 }},
                                        },
                                        {
                                            name = "Order Resources",
                                            keywords = {"order resources", "order", "resources", "legion order resources"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1220 }},
                                        },
                                        {
                                            name = "Veiled Argunite",
                                            keywords = {"veiled argunite", "veiled", "argunite", "legion veiled argunite"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1508 }},
                                        },
                                        {
                                            name = "Wakening Essence",
                                            keywords = {"wakening essence", "wakening", "essence", "legion wakening essence"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1533 }},
                                        },
                                    },
                                },
                                {
                                    name = "Warlords of Draenor Currencies",
                                    keywords = {"warlords of draenor", "warlords", "draenor", "warlords of draenor currencies", "warlords of draenor currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" }},
                                    children = {
                                        {
                                            name = "Apexis Crystal",
                                            keywords = {"apexis crystal", "apexis", "crystal", "warlords of draenor apexis crystal"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 823 }},
                                        },
                                        {
                                            name = "Artifact Fragment",
                                            keywords = {"artifact fragment", "artifact", "fragment", "warlords of draenor artifact fragment"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 944 }},
                                        },
                                        {
                                            name = "Garrison Resources",
                                            keywords = {"garrison resources", "garrison", "resources", "warlords of draenor garrison resources"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 824 }},
                                        },
                                        {
                                            name = "Oil",
                                            keywords = {"oil", "warlords of draenor oil"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 1101 }},
                                        },
                                        {
                                            name = "Seal of Tempered Fate",
                                            keywords = {"seal of tempered fate", "seal", "tempered", "fate", "warlords of draenor seal of tempered fate"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 994 }},
                                        },
                                    },
                                },
                                {
                                    name = "Mists of Pandaria Currencies",
                                    keywords = {"mists of pandaria", "mists", "pandaria", "mists of pandaria currencies", "mists of pandaria currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" }},
                                    children = {
                                        {
                                            name = "Elder Charm of Good Fortune",
                                            keywords = {"elder charm of good fortune", "elder", "charm", "good", "fortune", "mists of pandaria elder charm of good fortune"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 697 }},
                                        },
                                        {
                                            name = "Lesser Charm of Good Fortune",
                                            keywords = {"lesser charm of good fortune", "lesser", "charm", "good", "fortune", "mists of pandaria lesser charm of good fortune"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 738 }},
                                        },
                                        {
                                            name = "Mogu Rune of Fate",
                                            keywords = {"mogu rune of fate", "mogu", "rune", "fate", "mists of pandaria mogu rune of fate"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 752 }},
                                        },
                                        {
                                            name = "Timeless Coin",
                                            keywords = {"timeless coin", "timeless", "coin", "mists of pandaria timeless coin"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 777 }},
                                        },
                                        {
                                            name = "Warforged Seal",
                                            keywords = {"warforged seal", "warforged", "seal", "mists of pandaria warforged seal"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 776 }},
                                        },
                                    },
                                },
                                {
                                    name = "Cataclysm Currencies",
                                    keywords = {"cataclysm", "cataclysm currencies", "cataclysm currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Cataclysm" }},
                                    children = {
                                        {
                                            name = "Mote of Darkness",
                                            keywords = {"mote of darkness", "mote", "darkness", "cataclysm mote of darkness"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 614 }},
                                        },
                                    },
                                },
                                {
                                    name = "Wrath of the Lich King Currencies",
                                    keywords = {"wrath of the lich king", "wrath", "wotlk", "wrath of the lich king currencies", "wrath of the lich king currency"},
                                    category = "Currency",
                                    steps = {{ waitForFrame = "CharacterFrame", currencyHeader = "Wrath of the Lich King" }},
                                    children = {
                                        {
                                            name = "Champion's Seal",
                                            keywords = {"champion's seal", "champion's", "seal", "wrath of the lich king champion's seal"},
                                            steps = {{ waitForFrame = "CharacterFrame", currencyID = 241 }},
                                        },
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },

        -- =====================
        -- PROFESSIONS
        -- =====================
        {
            name = "Professions",
            keywords = {"professions", "profession", "crafting", "trade skills", "skills"},
            category = "Menu Bar",
            buttonFrame = "ProfessionMicroButton",
            steps = {{ buttonFrame = "ProfessionMicroButton" }},
        },

        -- =====================
        -- TALENTS & SPELLBOOK
        -- =====================
        {
            name = "Talents & Spellbook",
            keywords = {"talents", "spellbook", "abilities", "spec", "specialization", "spells"},
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

        -- =====================
        -- ACHIEVEMENTS
        -- =====================
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
                        -- =====================
                        -- ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
                        -- =====================
                        {
                            name = "Characters (Achievements)",
                            keywords = {"characters", "characters achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Characters" }},
                        },
                        {
                            name = "Collections (Achievements)",
                            keywords = {"collections", "collection", "transmog", "collections achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Collections" }},
                            children = {
                                {
                                    name = "Appearances (Achievements)",
                                    keywords = {"appearances", "appearances achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Appearances" }},
                                },
                                {
                                    name = "Decor (Achievements)",
                                    keywords = {"decor", "decor achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Decor" }},
                                },
                                {
                                    name = "Dragon Isle Drake Cosmetics (Achievements)",
                                    keywords = {"dragon isle drake cosmetics", "dragon", "isle", "drake", "cosmetics", "dragon isle drake cosmetics achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragon Isle Drake Cosmetics" }},
                                },
                                {
                                    name = "Mounts - Collections (Achievements)",
                                    keywords = {"mounts", "mounts achievements", "collections mounts"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Mounts" }},
                                },
                                {
                                    name = "Toy Box (Achievements)",
                                    keywords = {"toy box", "toy", "box", "toy box achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Toy Box" }},
                                },
                            },
                        },
                        {
                            name = "Delves (Achievements)",
                            keywords = {"delves", "delves achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Delves" }},
                            children = {
                                {
                                    name = "Midnight - Delves (Achievements)",
                                    keywords = {"midnight", "midnight achievements", "delves midnight"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight" }},
                                },
                                {
                                    name = "The War Within (Achievements)",
                                    keywords = {"the war within", "war within achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The War Within" }},
                                },
                            },
                        },
                        {
                            name = "Dungeons & Raids (Achievements)",
                            keywords = {"dungeons & raids", "dungeons", "raids", "dungeon", "raid", "dungeons & raids achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" }},
                            children = {
                                {
                                    name = "Battle Dungeon (Achievements)",
                                    keywords = {"battle dungeon", "battle dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" }},
                                },
                                {
                                    name = "Battle Raid (Achievements)",
                                    keywords = {"battle raid", "battle raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" }},
                                },
                                {
                                    name = "Cataclysm Dungeon (Achievements)",
                                    keywords = {"cataclysm dungeon", "cataclysm dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" }},
                                },
                                {
                                    name = "Cataclysm Raid (Achievements)",
                                    keywords = {"cataclysm raid", "cataclysm raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" }},
                                },
                                {
                                    name = "Classic - Dungeons & Raids (Achievements)",
                                    keywords = {"classic", "classic achievements", "dungeons & raids classic"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Classic" }},
                                },
                                {
                                    name = "Draenor Dungeon (Achievements)",
                                    keywords = {"draenor dungeon", "draenor dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" }},
                                },
                                {
                                    name = "Draenor Raid (Achievements)",
                                    keywords = {"draenor raid", "draenor raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" }},
                                },
                                {
                                    name = "Dragonflight Dungeon (Achievements)",
                                    keywords = {"dragonflight dungeon", "dragonflight dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" }},
                                },
                                {
                                    name = "Dragonflight Raid (Achievements)",
                                    keywords = {"dragonflight raid", "dragonflight raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" }},
                                },
                                {
                                    name = "Legion Dungeon (Achievements)",
                                    keywords = {"legion dungeon", "legion dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" }},
                                },
                                {
                                    name = "Legion Raid (Achievements)",
                                    keywords = {"legion raid", "legion raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" }},
                                },
                                {
                                    name = "Lich King Dungeon (Achievements)",
                                    keywords = {"lich king dungeon", "wotlk dungeon", "lich king dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" }},
                                },
                                {
                                    name = "Lich King Raid (Achievements)",
                                    keywords = {"lich king raid", "wotlk raid", "lich king raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" }},
                                },
                                {
                                    name = "Midnight Dungeon (Achievements)",
                                    keywords = {"midnight dungeon", "midnight dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" }},
                                },
                                {
                                    name = "Midnight Raid (Achievements)",
                                    keywords = {"midnight raid", "midnight raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" }},
                                },
                                {
                                    name = "Pandaria Dungeon (Achievements)",
                                    keywords = {"pandaria dungeon", "pandaria dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" }},
                                },
                                {
                                    name = "Pandaria Raid (Achievements)",
                                    keywords = {"pandaria raid", "pandaria raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" }},
                                },
                                {
                                    name = "Shadowlands Dungeon (Achievements)",
                                    keywords = {"shadowlands dungeon", "shadowlands dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" }},
                                },
                                {
                                    name = "Shadowlands Raid (Achievements)",
                                    keywords = {"shadowlands raid", "shadowlands raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" }},
                                },
                                {
                                    name = "The Burning Crusade - Dungeons & Raids (Achievements)",
                                    keywords = {"the burning crusade", "tbc", "the burning crusade achievements", "dungeons & raids the burning crusade"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" }},
                                },
                                {
                                    name = "War Within Dungeon (Achievements)",
                                    keywords = {"war within dungeon", "war within dungeon achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" }},
                                },
                                {
                                    name = "War Within Raid (Achievements)",
                                    keywords = {"war within raid", "war within raid achievements"},
                                    steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" }},
                                },
                            },
                        },
                        {
                            name = "Expansion Features (Achievements)",
                            keywords = {"expansion features", "expansion", "expansion features achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" }},
                            children = {
                                { name = "Argent Tournament (Achievements)", keywords = {"argent tournament", "argent tournament achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Argent Tournament" }} },
                                { name = "Covenant Sanctums (Achievements)", keywords = {"covenant sanctums", "covenant", "sanctums", "covenant sanctums achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Covenant Sanctums" }} },
                                { name = "Draenor Garrison (Achievements)", keywords = {"draenor garrison", "garrison", "draenor garrison achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Garrison" }} },
                                { name = "Heart of Azeroth (Achievements)", keywords = {"heart of azeroth", "heart of azeroth achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Heart of Azeroth" }} },
                                { name = "Island Expeditions (Achievements)", keywords = {"island expeditions", "island", "expeditions", "island expeditions achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Island Expeditions" }} },
                                { name = "Legion Class Hall (Achievements)", keywords = {"legion class hall", "class hall", "legion class hall achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Class Hall" }} },
                                { name = "Lorewalking (Achievements)", keywords = {"lorewalking", "lorewalking achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lorewalking" }} },
                                { name = "Pandaria Scenarios (Achievements)", keywords = {"pandaria scenarios", "scenarios", "pandaria scenarios achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Scenarios" }} },
                                { name = "Prey (Achievements)", keywords = {"prey", "prey achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Prey" }} },
                                { name = "Proving Grounds (Achievements)", keywords = {"proving grounds", "proving grounds achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Proving Grounds" }} },
                                { name = "Skyriding (Achievements)", keywords = {"skyriding", "skyriding achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Skyriding" }} },
                                { name = "Tol Barad (Achievements)", keywords = {"tol barad", "tol barad achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Tol Barad" }} },
                                { name = "Torghast (Achievements)", keywords = {"torghast", "tower", "torghast achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Torghast" }} },
                                { name = "Visions of N'Zoth (Achievements)", keywords = {"visions of n'zoth", "visions", "nzoth", "visions of n'zoth achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth" }} },
                                { name = "Visions of N'Zoth Revisited (Achievements)", keywords = {"visions of n'zoth revisited", "visions", "nzoth", "revisited", "visions of n'zoth revisited achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth Revisited" }} },
                                { name = "War Effort (Achievements)", keywords = {"war effort", "war effort achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Effort" }} },
                                { name = "Warfronts (Achievements)", keywords = {"warfronts", "warfront", "warfronts achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Warfronts" }} },
                            },
                        },
                        {
                            name = "Exploration (Achievements)",
                            keywords = {"exploration", "explore", "explorer", "exploration achievements"},
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
                            keywords = {"feats of strength", "feats", "feat", "fos", "feats of strength achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" }},
                            children = {
                                { name = "Delves - Feats of Strength (Achievements)", keywords = {"delves", "feats of strength delves"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Delves" }} },
                                { name = "Dungeons - Feats of Strength (Achievements)", keywords = {"dungeons", "dungeon", "feats of strength dungeons"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" }} },
                                { name = "Events (Achievements)", keywords = {"events"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Events" }} },
                                { name = "Mounts - Feats of Strength (Achievements)", keywords = {"mounts", "feats of strength mounts"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Mounts" }} },
                                { name = "Player vs. Player - Feats of Strength (Achievements)", keywords = {"player vs. player", "pvp"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }} },
                                { name = "Promotions (Achievements)", keywords = {"promotions"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Promotions" }} },
                                { name = "Raids - Feats of Strength (Achievements)", keywords = {"raids", "raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Raids" }} },
                                { name = "Reputation - Feats of Strength (Achievements)", keywords = {"reputation", "rep", "factions"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Reputation" }} },
                            },
                        },
                        {
                            name = "Legacy (Achievements)",
                            keywords = {"legacy", "old", "legacy achievements"},
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legacy" }},
                            children = {
                                { name = "Character (Achievements)", keywords = {"character"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Character" }} },
                                { name = "Currencies (Achievements)", keywords = {"currencies", "currency"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Currencies" }} },
                                { name = "Dungeons - Legacy (Achievements)", keywords = {"dungeons", "dungeon", "legacy dungeons"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" }} },
                                { name = "Expansion Features - Legacy (Achievements)", keywords = {"expansion features", "expansion", "legacy expansion features"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" }} },
                                { name = "Legion Remix (Achievements)", keywords = {"legion remix", "legion", "remix"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Remix" }} },
                                { name = "Player vs. Player - Legacy (Achievements)", keywords = {"player vs. player", "pvp", "legacy player vs. player"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }} },
                                { name = "Professions - Legacy (Achievements)", keywords = {"professions", "profession", "crafting", "legacy professions"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Professions" }} },
                                { name = "Quests - Legacy (Achievements)", keywords = {"quests", "quest", "legacy quests"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Quests" }} },
                                { name = "Raids - Legacy (Achievements)", keywords = {"raids", "raid", "legacy raids"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Raids" }} },
                                { name = "Remix: Mists of Pandaria (Achievements)", keywords = {"remix: mists of pandaria", "remix", "mists", "pandaria"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Remix: Mists of Pandaria" }} },
                                { name = "World Events - Legacy (Achievements)", keywords = {"world events", "holidays", "seasonal", "legacy world events"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "World Events" }} },
                            },
                        },
                        { name = "Pet Battles (Achievements)", keywords = {"pet battles", "pets", "battle pets", "pet battles achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" }},
                            children = {
                                { name = "Battle (Achievements)", keywords = {"battle", "battle achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle" }} },
                                { name = "Collect (Achievements)", keywords = {"collect", "collect achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Collect" }} },
                                { name = "Level (Achievements)", keywords = {"level", "level achievements"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Level" }} },
                            },
                        },
                        {
                            name = "Player vs. Player (Achievements)",
                            keywords = {"player vs. player", "pvp", "player vs. player achievements"},
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
                            keywords = {"professions", "profession", "crafting", "professions achievements"},
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
                            keywords = {"quests", "quest", "quest achievements"},
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
                            keywords = {"reputation", "rep", "factions", "reputation achievements"},
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
                            keywords = {"world events", "holidays", "seasonal", "world events achievements"},
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

                -- =====================
                -- GUILD ACHIEVEMENTS (Tab 2)
                -- =====================
                {
                    name = "Guild Achievements",
                    keywords = {"guild achievements", "guild tab", "guild points"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 2 }},
                    children = {
                        -- GUILD ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
                        {
                            name = "Guild: Dungeons & Raids",
                            keywords = {"dungeons & raids", "dungeons", "raids", "guild dungeons & raids"},
                            category = "Guild Achievements",
                            steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" }},
                            children = {
                                { name = "Guild: Battle Dungeon", keywords = {"battle dungeon", "guild battle dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" }} },
                                { name = "Guild: Battle Raid", keywords = {"battle raid", "guild battle raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" }} },
                                { name = "Guild: Cataclysm Dungeon", keywords = {"cataclysm dungeon", "guild cataclysm dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" }} },
                                { name = "Guild: Cataclysm Raid", keywords = {"cataclysm raid", "guild cataclysm raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" }} },
                                { name = "Guild: Classic", keywords = {"classic", "guild classic"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Classic" }} },
                                { name = "Guild: Draenor Dungeon", keywords = {"draenor dungeon", "guild draenor dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" }} },
                                { name = "Guild: Draenor Raid", keywords = {"draenor raid", "guild draenor raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" }} },
                                { name = "Guild: Dragonflight Dungeon", keywords = {"dragonflight dungeon", "guild dragonflight dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" }} },
                                { name = "Guild: Dragonflight Raid", keywords = {"dragonflight raid", "guild dragonflight raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" }} },
                                { name = "Guild: Legion Dungeon", keywords = {"legion dungeon", "guild legion dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" }} },
                                { name = "Guild: Legion Raid", keywords = {"legion raid", "guild legion raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" }} },
                                { name = "Guild: Lich King Dungeon", keywords = {"lich king dungeon", "guild lich king dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" }} },
                                { name = "Guild: Lich King Raid", keywords = {"lich king raid", "guild lich king raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" }} },
                                { name = "Guild: Midnight Dungeon", keywords = {"midnight dungeon", "guild midnight dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" }} },
                                { name = "Guild: Midnight Raid", keywords = {"midnight raid", "guild midnight raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" }} },
                                { name = "Guild: Pandaria Dungeon", keywords = {"pandaria dungeon", "guild pandaria dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" }} },
                                { name = "Guild: Pandaria Raid", keywords = {"pandaria raid", "guild pandaria raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" }} },
                                { name = "Guild: Shadowlands Dungeon", keywords = {"shadowlands dungeon", "guild shadowlands dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" }} },
                                { name = "Guild: Shadowlands Raid", keywords = {"shadowlands raid", "guild shadowlands raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" }} },
                                { name = "Guild: The Burning Crusade", keywords = {"the burning crusade", "tbc", "guild the burning crusade"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" }} },
                                { name = "Guild: War Within Dungeon", keywords = {"war within dungeon", "guild war within dungeon"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" }} },
                                { name = "Guild: War Within Raid", keywords = {"war within raid", "guild war within raid"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" }} },
                            },
                        },
                        { name = "Guild: General", keywords = {"general", "guild general"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "General" }} },
                        { name = "Guild: Guild Feats of Strength", keywords = {"guild feats of strength", "guild feats", "fos", "guild guild feats of strength"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Guild Feats of Strength" }} },
                        { name = "Guild: Player vs. Player", keywords = {"player vs. player", "pvp", "guild pvp"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" }},
                            children = {
                                { name = "Guild: Arena", keywords = {"arena", "guild arena"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Arena" }} },
                                { name = "Guild: Battlegrounds", keywords = {"battlegrounds", "bg", "guild battlegrounds"}, steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Battlegrounds" }} },
                            },
                        },
                        { name = "Guild: Professions", keywords = {"professions", "profession", "crafting", "guild professions"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Professions" }} },
                        { name = "Guild: Quests", keywords = {"quests", "quest", "guild quests"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Quests" }} },
                        { name = "Guild: Reputation", keywords = {"reputation", "rep", "factions", "guild reputation"}, category = "Guild Achievements", steps = {{ waitForFrame = "AchievementFrame", achievementCategory = "Reputation" }} },
                    },
                },

                -- =====================
                -- STATISTICS (Tab 3)
                -- =====================
                {
                    name = "Statistics",
                    keywords = {"statistics", "stats tab", "player statistics"},
                    category = "Achievements",
                    steps = {{ waitForFrame = "AchievementFrame", tabIndex = 3 }},
                    children = {
                        -- STATISTICS CATEGORIES (Auto-generated by Harvester)
                        {
                            name = "Character Statistics",
                            keywords = {"character", "character stats", "character statistics"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Character" }},
                            children = {
                                { name = "Consumables Statistics", keywords = {"consumables", "consumables stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Consumables" }} },
                                { name = "Wealth Statistics", keywords = {"wealth", "wealth stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Wealth" }} },
                            },
                        },
                        { name = "Kills Statistics", keywords = {"kills", "kills stats", "kill count"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Kills" }} },
                        { name = "Deaths Statistics", keywords = {"deaths", "deaths stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Deaths" }} },
                        { name = "Quests Statistics", keywords = {"quests", "quests stats", "quest count"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Quests" }} },
                        { name = "Skills Statistics", keywords = {"skills", "skills stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Skills" }} },
                        { name = "Travel Statistics", keywords = {"travel", "travel stats", "distance", "flight paths"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Travel" }} },
                        { name = "Social Statistics", keywords = {"social", "social stats", "friends", "groups"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Social" }} },
                        { name = "Delves Statistics", keywords = {"delves", "delves stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Delves" }} },
                        {
                            name = "Combat Statistics",
                            keywords = {"combat", "combat stats", "combat statistics"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Combat" }},
                            children = {
                                { name = "Buffs Statistics", keywords = {"buffs", "buffs stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Buffs" }} },
                                { name = "Damage Statistics", keywords = {"damage", "damage stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Damage" }} },
                                { name = "Healing Statistics", keywords = {"healing", "healing stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Healing" }} },
                            },
                        },
                        {
                            name = "Dungeons & Raids Statistics",
                            keywords = {"dungeons & raids", "dungeons", "raids", "dungeons & raids stats"},
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
                            keywords = {"player vs. player", "pvp", "pvp stats"},
                            category = "Statistics",
                            steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" }},
                            children = {
                                { name = "Arena Statistics", keywords = {"arena", "arena stats"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Arena" }} },
                                {
                                    name = "Battlegrounds Statistics",
                                    keywords = {"battlegrounds", "bg", "battlegrounds stats"},
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
                                { name = "World Statistics", keywords = {"world", "world pvp"}, steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "World" }} },
                            },
                        },
                        { name = "Pet Battles Statistics", keywords = {"pet battles", "pet battles stats", "battle pets stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Pet Battles" }} },
                        { name = "Proving Grounds Statistics", keywords = {"proving grounds", "proving grounds stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Proving Grounds" }} },
                        { name = "Legacy Statistics", keywords = {"legacy", "legacy stats"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "Legacy" }} },
                        { name = "World Events Statistics", keywords = {"world events", "world events stats", "holidays"}, category = "Statistics", steps = {{ waitForFrame = "AchievementFrame", statisticsCategory = "World Events" }} },
                        -- Manual entry: Duel Statistics (specific deep navigation)
                        {
                            name = "Duel Statistics",
                            keywords = {"duel", "duels", "duel stats", "duel statistics", "dueling", "pvp duels", "1v1", "world pvp duels", "duels won", "duels lost"},
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

        -- =====================
        -- QUEST LOG
        -- =====================
        {
            name = "Quest Log",
            keywords = {"quest", "quests", "objectives", "log", "journal"},
            category = "Menu Bar",
            buttonFrame = "QuestLogMicroButton",
            steps = {{ buttonFrame = "QuestLogMicroButton" }},
        },

        -- =====================
        -- HOUSING
        -- =====================
        {
            name = "Housing Dashboard",
            keywords = {"housing", "house", "home", "dashboard", "player housing", "delves housing"},
            category = "Menu Bar",
            buttonFrame = "HousingMicroButton",
            steps = {{ buttonFrame = "HousingMicroButton" }},
        },

        -- =====================
        -- GUILD & COMMUNITIES
        -- =====================
        {
            name = "Guild & Communities",
            keywords = {"guild", "communities", "social", "clan"},
            category = "Menu Bar",
            buttonFrame = "GuildMicroButton",
            steps = {{ buttonFrame = "GuildMicroButton" }},
        },

        -- =====================
        -- GROUP FINDER
        -- =====================
        {
            name = "Group Finder",
            keywords = {"lfg", "lfd", "lfr", "dungeon finder", "raid finder", "finder", "queue", "group", "premade", "pvp", "pve"},
            category = "Menu Bar",
            buttonFrame = "LFDMicroButton",
            steps = {{ buttonFrame = "LFDMicroButton" }},
            children = {
                -- PVE SECTION
                {
                    name = "Dungeons & Raids",
                    keywords = {"dungeons", "raids", "pve", "dungeons and raids", "dungeon tab", "raid tab"},
                    category = "Group Finder",
                    steps = {{ waitForFrame = "PVEFrame", tabIndex = 1 }},
                    children = {
                        { name = "Dungeon Finder", keywords = {"dungeon finder", "lfd", "random dungeon", "heroic dungeon", "normal dungeon", "dungeon queue"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 1 }} },
                        { name = "Raid Finder", keywords = {"raid finder", "lfr", "looking for raid", "raid queue", "random raid"}, steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 2 }} },
                        {
                            name = "Premade Groups (PvE)",
                            keywords = {"premade", "premade groups", "custom group", "find group", "make group", "list group", "pve premade"},
                            steps = {{ waitForFrame = "PVEFrame", sideTabIndex = 3 }},
                            children = {
                                { name = "Questing (Premade)", keywords = {"questing", "quest", "quest group", "quest lfg", "find quest group", "premade questing"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Questing", text = "Select Questing from the Premade Groups list" }} },
                                { name = "Delves (Premade)", keywords = {"delves", "delve group", "delve lfg", "find delve group", "premade delves", "delve"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Delves", text = "Select Delves from the Premade Groups list" }} },
                                { name = "Dungeons (Premade)", keywords = {"dungeons", "dungeon group", "dungeon lfg", "find dungeon group", "premade dungeons", "m+ group", "mythic group"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Dungeons", text = "Select Dungeons from the Premade Groups list" }} },
                                { name = "Raids - The War Within (Premade)", keywords = {"raids", "raids the war within", "raid group", "raid lfg", "find raid group", "premade raids", "tww raid", "war within raid", "nerub-ar", "liberation of undermine"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Raids - The War Within", text = "Select Raids - The War Within from the Premade Groups list" }} },
                                { name = "Raids - Legacy (Premade)", keywords = {"raids", "raids legacy", "legacy raid", "old raid", "legacy raid group", "legacy lfg", "transmog raid", "mount run"}, steps = {{ waitForFrame = "PVEFrame", searchButtonText = "Raids - Legacy", text = "Select Raids - Legacy from the Premade Groups list" }} },
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
                                { name = "Arena Skirmish", keywords = {"arena skirmish", "skirmish", "unrated arena", "casual arena", "arena"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.ArenaSkirmish", "HonorFrame.ArenaSkirmish"}, searchButtonText = "Arena Skirmish", text = "Select Arena Skirmish from the list" }} },
                                { name = "Random Battleground", keywords = {"random bg", "random battleground", "casual bg", "unrated bg", "battleground"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.RandomBG", "HonorFrame.RandomBG"}, searchButtonText = "Random Battlegrounds", text = "Select Random Battlegrounds from the list" }} },
                                { name = "Random Epic Battleground", keywords = {"random epic bg", "random epic battleground", "epic bg", "epic battleground", "ashran", "alterac", "isle of conquest"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.RandomEpicBG", "HonorFrame.RandomEpicBG"}, searchButtonText = "Random Epic Battlegrounds", text = "Select Random Epic Battlegrounds from the list" }} },
                                { name = "Brawl", keywords = {"brawl", "pvp brawl", "weekly brawl", "packed house"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.Brawl", "HonorFrame.BonusFrame.BrawlButton"}, searchButtonText = "Brawl", text = "Select the Brawl option from the list" }} },
                            },
                        },
                        {
                            name = "Rated",
                            keywords = {"rated", "rated pvp", "conquest", "pvp"},
                            steps = {{ waitForFrame = "PVEFrame", pvpSideTabIndex = 2 }},
                            children = {
                                { name = "Solo Shuffle", keywords = {"solo shuffle", "shuffle", "solo arena", "solo rated", "arena"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena1v1", "ConquestFrame.SoloShuffle"}, searchButtonText = "Solo Arena", text = "Solo Shuffle is the first option in the Rated panel" }} },
                                { name = "2v2 Arena", keywords = {"2v2", "2s", "twos", "2v2 arena", "two vs two", "arena"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena2v2"}, searchButtonText = "2v2", text = "2v2 Arena is in the Rated panel" }} },
                                { name = "3v3 Arena", keywords = {"3v3", "3s", "threes", "3v3 arena", "three vs three", "arena"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena3v3"}, searchButtonText = "3v3", text = "3v3 Arena is in the Rated panel" }} },
                                { name = "Rated Battlegrounds", keywords = {"rbg", "rated bg", "rated battleground", "rated battlegrounds", "10v10", "ten vs ten"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBG", "PVPQueueFrame.HonorInset.RatedPanel.RatedBGButton", "HonorFrame.BonusFrame.RatedBGButton"}, text = "Rated Battlegrounds is in the Rated panel" }} },
                                { name = "Solo Battlegrounds (Blitz)", keywords = {"solo bg", "solo battleground", "solo battlegrounds", "solo rated bg", "battleground", "blitz", "rated battleground blitz", "battleground blitz"}, category = "PvP", steps = {{ waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.SoloBG", "ConquestFrame.Brawl1v1"}, searchButtonText = "Solo Battlegrounds", text = "Solo Battlegrounds (Blitz) is in the Rated panel" }} },
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

        -- =====================
        -- WARBAND COLLECTIONS
        -- =====================
        {
            name = "Warband Collections",
            keywords = {"collections", "warband", "mounts", "pets", "toys", "heirlooms", "wardrobe", "campsites"},
            category = "Menu Bar",
            buttonFrame = "CollectionsMicroButton",
            steps = {{ buttonFrame = "CollectionsMicroButton" }},
            children = {
                { name = "Mounts", keywords = {"mounts", "mount", "riding", "mount collection", "flying"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 1 }} },
                { name = "Pet Journal", keywords = {"pets", "pet", "battle pets", "companion", "pet collection", "critter", "pet journal"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 2 }} },
                { name = "Toy Box", keywords = {"toys", "toy", "toybox", "toy box", "fun items"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 3 }} },
                { name = "Heirlooms", keywords = {"heirlooms", "heirloom", "leveling gear", "bind on account", "boa"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 4 }} },
                { name = "Appearances (Transmog)", keywords = {"transmog", "transmogrification", "appearance", "appearances", "wardrobe", "cosmetic", "looks", "mog"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 5, text = "Click the Appearances tab" }} },
                { name = "Campsites", keywords = {"campsites", "campsite", "camp", "camping", "rest area"}, category = "Warband Collections", steps = {{ waitForFrame = "CollectionsJournal", tabIndex = 6 }} },
            },
        },

        -- =====================
        -- ADVENTURE GUIDE
        -- =====================
        {
            name = "Adventure Guide",
            keywords = {"adventure", "guide", "dungeon journal", "encounters", "loot", "boss", "journal"},
            category = "Menu Bar",
            buttonFrame = "EJMicroButton",
            steps = {{ buttonFrame = "EJMicroButton" }},
            children = {
                { name = "Journeys", keywords = {"journeys", "journey", "adventure journeys"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 1, text = "Click the Journeys tab" }} },
                { name = "Traveler's Log", keywords = {"traveler", "travelers log", "traveler log", "travel log"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 2, text = "Click the Traveler's Log tab" }} },
                { name = "Suggested Content", keywords = {"suggested", "suggested content", "recommendations"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 3, text = "Click the Suggested Content tab" }} },
                { name = "Dungeons (Journal)", keywords = {"dungeon journal", "dungeon guide", "dungeon encounters", "dungeon bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 4, text = "Click the Dungeons tab" }} },
                { name = "Raids (Journal)", keywords = {"raid journal", "raid guide", "raid encounters", "raid bosses"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 5, text = "Click the Raids tab" }} },
                { name = "Item Sets", keywords = {"item sets", "tier sets", "set bonuses", "class sets"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 6, text = "Click the Item Sets tab" }} },
                { name = "Tutorials", keywords = {"tutorials", "tutorial", "help guide", "how to"}, category = "Adventure Guide", steps = {{ waitForFrame = "EncounterJournal", tabIndex = 7, text = "Click the Tutorials tab" }} },
            },
        },

        -- =====================
        -- GAME MENU / HELP / SHOP
        -- =====================
        {
            name = "Game Menu",
            keywords = {"menu", "settings", "options", "escape", "esc", "logout", "quit", "exit", "interface"},
            category = "Menu Bar",
            buttonFrame = "MainMenuMicroButton",
            steps = {{ buttonFrame = "MainMenuMicroButton" }},
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
                { name = "Shop Appearances", keywords = {"shop appearance", "shop transmog", "store transmog", "cash shop appearance"}, category = "Shop", steps = {{ waitForFrame = "StoreFrame", text = "Browse the Appearances section in the shop" }} },
            },
        },

        -- =====================
        -- PORTRAIT MENU OPTIONS (Auto-generated by Harvester)
        -- =====================
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
                        local inInstance, instanceType = IsInInstance()
                        if inInstance then return false end
                        if IsInGroup() and not UnitIsGroupLeader("player") then return false end
                        return true
                    end,
                    steps = {{ portraitMenuOption = "Reset All Instances" }},
                },
                { name = "Edit Mode", keywords = {"edit mode", "ui layout", "customize ui", "move frames", "hud edit", "ui editor"}, steps = {{ portraitMenuOption = "Edit Mode" }} },
                { name = "Voice Chat", keywords = {"voice chat", "voice", "voip", "talk", "microphone", "mic"}, steps = {{ portraitMenuOption = "Voice Chat" }} },
                { name = "PvP Flag", keywords = {"pvp flag", "pvp toggle", "player vs player flag", "pvp enable", "war mode portrait"}, steps = {{ portraitMenuOption = "PvP Flag" }} },
            },
        },

        -- =====================
        -- OTHER UI ELEMENTS (no tree hierarchy, standalone)
        -- =====================
        {
            name = "Bags / Inventory",
            keywords = {"bags", "bag", "inventory", "backpack", "items", "storage"},
            category = "Inventory",
            icon = 130716,
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
            name = "World Map",
            keywords = {"map", "world map", "zone map", "navigation"},
            category = "Navigation",
            icon = 134269,
            steps = {{ customText = "Press M to open the World Map" }},
        },
        {
            name = "Calendar",
            keywords = {"calendar", "events", "holidays", "schedule"},
            category = "Social",
            icon = 134939,
            steps = {{ customText = "Click the clock/time display on your minimap to open the Calendar" }},
        },
    }

    -- Flatten the tree into the flat uiSearchData array
    self:FlattenTree(uiTree)

    -- Pre-lowercase names and keywords for search performance
    -- Also track which currencyIDs are in the static database
    for _, item in ipairs(uiSearchData) do
        item.nameLower = slower(item.name)
        if item.keywords then
            item.keywordsLower = {}
            for i, kw in ipairs(item.keywords) do
                item.keywordsLower[i] = slower(kw)
            end
        end
        if not item.icon and not item.buttonFrame then
            item.icon = 134400
        end
        -- Register static currency IDs and header names so dynamic supplement skips them
        if item.steps then
            for _, step in ipairs(item.steps) do
                if step.currencyID then
                    knownCurrencyIDs[step.currencyID] = true
                end
                if step.currencyHeader then
                    knownCurrencyIDs["header_" .. slower(step.currencyHeader)] = true
                end
            end
        end
    end
end

-- =============================================================================
-- SEARCH SCORING HELPERS
-- Word-boundary matching, initials matching, and fuzzy/typo tolerance.
-- =============================================================================

--- Check if `query` appears at a word boundary in `text`.
--- A word boundary is the start of the string or right after a space/punctuation.
--- Returns true if found at a boundary, false if only found mid-word or not at all.
function Database:FindAtWordBoundary(text, query)
    -- Check at start of string
    if ssub(text, 1, #query) == query then return true end
    -- Check after word boundaries (space, dash, parenthesis, colon, slash, dot)
    local pos = 1
    while true do
        local found = sfind(text, query, pos, true)
        if not found then return false end
        if found > 1 then
            local prev = ssub(text, found - 1, found - 1)
            if prev == " " or prev == "-" or prev == "(" or prev == ":" or prev == "/" or prev == "." then
                return true
            end
        else
            return true  -- found at position 1
        end
        pos = found + 1
    end
end

--- Score how well `query` matches as initials/abbreviation of words in `text`.
--- "rb" → "rated battlegrounds" = 130 (each char matches a word start)
--- "raba" → "random battleground" = 125 (prefix of words)
--- "ranb" → "random battleground" = 115 (longer prefix matching)
--- Returns 0 if no reasonable initials match found.
function Database:ScoreInitials(text, query)
    -- Split text into words
    local words = {}
    for w in text:gmatch("[%w]+") do
        words[#words + 1] = slower(w)
    end
    if #words < 2 then return 0 end  -- initials only make sense for multi-word

    local queryLen = #query
    
    -- Strategy 1: Pure initials — each query char matches the first letter of consecutive words
    -- "rb" → R(ated) B(attlegrounds)
    if queryLen <= #words then
        local allMatch = true
        for i = 1, queryLen do
            if ssub(query, i, i) ~= ssub(words[i], 1, 1) then
                allMatch = false
                break
            end
        end
        if allMatch then
            -- Bonus for matching ALL words' initials (not partial)
            local bonus = (queryLen == #words) and 135 or 130
            return bonus
        end
    end
    
    -- Strategy 2: Prefix-of-words — each query segment matches the start of a word
    -- "raba" → "ra(ndom) ba(ttleground)" — greedily consume query chars across words
    local qi = 1  -- position in query
    local wordsMatched = 0
    for _, w in ipairs(words) do
        if qi > queryLen then break end
        -- How many chars from the start of this word match the query at position qi?
        local matchLen = 0
        while qi + matchLen <= queryLen and matchLen < #w do
            if ssub(query, qi + matchLen, qi + matchLen) == ssub(w, matchLen + 1, matchLen + 1) then
                matchLen = matchLen + 1
            else
                break
            end
        end
        if matchLen > 0 then
            qi = qi + matchLen
            wordsMatched = wordsMatched + 1
        end
    end
    -- Did we consume the entire query across multiple words?
    if qi > queryLen and wordsMatched >= 2 then
        -- Score based on how many words were matched (more = better abbreviation)
        return 110 + mmin(wordsMatched * 3, 20)
    end
    
    return 0
end

--- Score fuzzy/typo matching using Damerau-Levenshtein distance.
--- Only applied to individual words in `text` that are similar in length to `query`.
--- Returns a score > 0 if a close match is found, 0 otherwise.
function Database:ScoreFuzzy(text, query, queryLen)
    -- Check each word in the text for close matches
    local bestScore = 0
    for word in text:gmatch("[%w]+") do
        word = slower(word)
        local wordLen = #word
        -- Only compare words of similar length (within ±1) to reduce false positives
        if wordLen >= queryLen - 1 and wordLen <= queryLen + 1 then
            local dist = Database:DamerauLevenshtein(query, word, queryLen, wordLen)
            if dist == 1 then
                -- One edit away: transposition, substitution, insertion, or deletion
                bestScore = mmax(bestScore, 85)
            elseif dist == 2 and queryLen >= 6 then
                -- Two edits: only for longer queries (6+) to avoid false positives
                bestScore = mmax(bestScore, 45)
            end
        end
    end
    return bestScore
end

--- Damerau-Levenshtein distance (supports transpositions).
--- Capped: returns early if distance exceeds 2 (saves CPU).
function Database:DamerauLevenshtein(s1, s2, len1, len2)
    if mabs(len1 - len2) > 2 then return 3 end  -- too different, skip
    
    -- Use two rows instead of full matrix for memory efficiency
    local prev2 = {}  -- row i-2
    local prev  = {}  -- row i-1
    local curr  = {}  -- row i
    
    for j = 0, len2 do prev[j] = j end
    
    for i = 1, len1 do
        curr[0] = i
        local minInRow = i
        for j = 1, len2 do
            local cost = (ssub(s1, i, i) == ssub(s2, j, j)) and 0 or 1
            curr[j] = mmin(
                prev[j] + 1,        -- deletion
                curr[j - 1] + 1,    -- insertion
                prev[j - 1] + cost  -- substitution
            )
            -- Transposition
            if i > 1 and j > 1
                and ssub(s1, i, i) == ssub(s2, j - 1, j - 1)
                and ssub(s1, i - 1, i - 1) == ssub(s2, j, j) then
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

function Database:SearchUI(query)
    if not query or query == "" or #query < 2 then
        return {}
    end
    
    query = slower(query)
    local queryLen = #query
    local results = {}
    
    for _, data in ipairs(uiSearchData) do
        -- Skip entries that have an availability check that returns false
        if data.available and not data.available() then
            -- Not available in current context, skip
        else
        local score = 0
        local nameLower = data.nameLower
        
        -- Exact name match
        if nameLower == query then
            score = 200
        -- Name starts with query
        elseif ssub(nameLower, 1, queryLen) == query then
            score = 150
        -- Name contains query at a word boundary (e.g. "battle" in "rated battlegrounds")
        elseif Database:FindAtWordBoundary(nameLower, query) then
            score = 120
        -- Name contains query mid-word (e.g. "rb" in "herbalism") — low score
        elseif sfind(nameLower, query, 1, true) then
            score = 30
        end
        
        -- Initials matching: "rb" → "Rated Battlegrounds", "raba" → "RAndom BAttleground"
        if score < 130 then
            local initialScore = Database:ScoreInitials(nameLower, query)
            if initialScore > score then
                score = initialScore
            end
        end
        
        -- Fuzzy/typo matching: "rtaed" → "rated" (only for queries ≥ 4 chars)
        if score < 100 and queryLen >= 4 then
            local fuzzyScore = Database:ScoreFuzzy(nameLower, query, queryLen)
            if fuzzyScore > score then
                score = fuzzyScore
            end
        end
        
        -- Keyword matching
        if data.keywordsLower then
            for _, kw in ipairs(data.keywordsLower) do
                local kwScore = 0
                if kw == query then
                    kwScore = 80
                elseif ssub(kw, 1, queryLen) == query then
                    kwScore = 70
                elseif Database:FindAtWordBoundary(kw, query) then
                    kwScore = 55
                end
                -- Mid-word keyword substring deliberately excluded:
                -- \"rated\" in \"unrated\" is not a relevant keyword match.
                -- Initials on keywords
                if kwScore < 60 then
                    local ki = Database:ScoreInitials(kw, query)
                    if ki > 0 then kwScore = mmax(kwScore, ki - 20) end  -- slightly lower than name initials
                end
                -- Fuzzy on keywords
                if kwScore < 40 and queryLen >= 4 then
                    local kf = Database:ScoreFuzzy(kw, query, queryLen)
                    if kf > 0 then kwScore = mmax(kwScore, kf - 10) end
                end
                score = score + kwScore
            end
        end
        
        if score > 25 then
            local result = {}
            for k, v in pairs(data) do
                result[k] = v
            end
            result.score = score
            results[#results + 1] = result
        end
        end -- else (availability check)
    end
    
    tsort(results, function(a, b) return a.score > b.score end)
    return results
end

-- Build a hierarchical tree from flat results for display.
-- Uses a proper tree structure internally and DFS-flattens it, so children
-- are always adjacent to their parent regardless of alphabetical ordering.
function Database:BuildHierarchicalResults(results)
    if not results or #results == 0 then
        return {}
    end

    -- Step 1 — Build a virtual tree from all results.
    -- Each node: { name, children (name→node), childOrder (list of names),
    --              data (search result entry or nil), bestScore }
    local root = { children = {}, childOrder = {} }

    local function getOrCreateNode(pathParts)
        local node = root
        for _, part in ipairs(pathParts) do
            if not node.children[part] then
                node.children[part] = {
                    name = part,
                    children = {},
                    childOrder = {},
                    bestScore = 0,
                }
                node.childOrder[#node.childOrder + 1] = part
            end
            node = node.children[part]
        end
        return node
    end

    for _, item in ipairs(results) do
        local path = item.path or {}
        local parentNode = getOrCreateNode(path)
        local itemScore = item.score or 0

        if parentNode.children[item.name] then
            -- Node already exists (created as a path ancestor of another result).
            -- Attach the actual result data so it becomes navigable.
            local existing = parentNode.children[item.name]
            if not existing.data then existing.data = item end
            if itemScore > existing.bestScore then
                existing.bestScore = itemScore
            end
        else
            parentNode.children[item.name] = {
                name = item.name,
                children = {},
                childOrder = {},
                data = item,
                bestScore = itemScore,
            }
            parentNode.childOrder[#parentNode.childOrder + 1] = item.name
        end

        -- Propagate best score upward so ancestor branches sort correctly.
        local node = root
        for _, part in ipairs(path) do
            node = node.children[part]
            if itemScore > node.bestScore then
                node.bestScore = itemScore
            end
        end
    end

    -- Step 2 — Sort children at every level: best score desc, then name asc.
    local function sortChildren(node)
        tsort(node.childOrder, function(a, b)
            local sa = node.children[a].bestScore or 0
            local sb = node.children[b].bestScore or 0
            if sa ~= sb then return sa > sb end
            return a < b
        end)
        for _, childName in ipairs(node.childOrder) do
            sortChildren(node.children[childName])
        end
    end
    sortChildren(root)

    -- Step 3 — DFS flatten into the display list.
    local hierarchical = {}
    local function flatten(node, depth)
        for _, childName in ipairs(node.childOrder) do
            local child = node.children[childName]
            local hasChildren = #child.childOrder > 0

            hierarchical[#hierarchical + 1] = {
                name = child.name,
                depth = depth,
                isPathNode = hasChildren,
                data = child.data or self:FindItemByName(child.name),
            }

            if hasChildren then
                flatten(child, depth + 1)
            end
        end
    end
    flatten(root, 0)

    return hierarchical
end

function Database:FindItemByName(name)
    for _, data in ipairs(uiSearchData) do
        if data.name == name then
            return data
        end
    end
    return nil
end

Database:Initialize()
