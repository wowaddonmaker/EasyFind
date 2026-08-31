local _, ns = ...

local Search = ns.Search
local Providers = ns.SearchProviders
local Utils = ns.Utils

local slower = Utils.slower
local sfind = Utils.sfind
local tconcat = Utils.tconcat
local mfloor = Utils.mfloor
local CreateFrame = CreateFrame
local wipe = wipe
local band = bit.band

local ACHIEVEMENT_PROTO = {
    keywords      = {},
    keywordsLower = {},
    category      = "Achievement",
    buttonFrame   = "AchievementMicroButton",
    path          = { _G["ACHIEVEMENTS"] or "Achievements" },
}
local ACHIEVEMENT_MT = { __index = ACHIEVEMENT_PROTO }
local achievementEntryByID = {}
local achSearchCache = {}
local achSearchStatsVersion
local achSearchPending = nil
local achSearchCurrentQuery = nil
local achSearchListener
local ACH_MAX_RESULTS = 8
local ACHIEVEMENT_CATEGORY_FLAG_GUILD = 0x00000001

local function GetAchievementFilterMode()
    local mode = EasyFind and EasyFind.db and EasyFind.db.achievementFilterMode or "all"
    if mode == "earned" or mode == "incomplete" then return mode end
    return "all"
end

local function AchievementSearchCacheKey(query, mode)
    return (mode or "all") .. "\31" .. (query or "")
end

local function AchievementPassesFilter(completed, mode)
    if mode == "earned" then return completed == true end
    if mode == "incomplete" then return completed ~= true end
    return true
end

local function SyncAchievementSearchStatsVersion()
    local version = ns.Database and ns.Database.statisticsVersion or 0
    if achSearchStatsVersion == version then return end
    wipe(achSearchCache)
    wipe(achievementEntryByID)
    achSearchPending = nil
    achSearchCurrentQuery = nil
    achSearchStatsVersion = version
end

-- Walk the achievement's category chain root-down so the guide
-- breadcrumbs through each parent before highlighting the achievement
-- row. GetAchievementCategory + GetCategoryInfo (parentID) walks up
-- toward -1 (root sentinel).
local function BuildAchievementSteps(achievementID, knownGuildAchievement)
    local isGuildAchievement = knownGuildAchievement and true or false
    local steps = {
        { buttonFrame = "AchievementMicroButton" },
        { waitForFrame = "AchievementFrame", tabIndex = isGuildAchievement and 2 or 1 },
    }
    local getCat   = _G["GetAchievementCategory"]
    local getInfo  = _G["GetCategoryInfo"]
    if not getCat or not getInfo then
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementID = achievementID,
        }
        return steps, isGuildAchievement
    end
    local catID = getCat(achievementID)
    if not catID or catID < 0 then
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementID = achievementID,
        }
        return steps, isGuildAchievement
    end
    local chain = {}
    local seen = {}
    local current = catID
    while current and current > 0 and not seen[current] do
        seen[current] = true
        local title, parentID, flags = getInfo(current)
        if not title then break end
        if flags and band(flags, ACHIEVEMENT_CATEGORY_FLAG_GUILD) == ACHIEVEMENT_CATEGORY_FLAG_GUILD then
            isGuildAchievement = true
        end
        chain[#chain + 1] = { id = current, name = title }
        current = parentID
    end
    steps[2].tabIndex = isGuildAchievement and 2 or 1
    -- Reverse so root-most appears first.
    for i = #chain, 1, -1 do
        local cat = chain[i]
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementCategory = cat.name,
            achievementCategoryID = cat.id,
        }
    end
    -- Final step targets the achievement itself.
    steps[#steps + 1] = {
        waitForFrame = "AchievementFrame",
        achievementID = achievementID,
    }
    return steps, isGuildAchievement
end

local function GetOrCreateAchievementEntry(id, name, icon, knownGuildAchievement)
    local entry = achievementEntryByID[id]
    local steps, isGuildAchievement = BuildAchievementSteps(id, knownGuildAchievement)
    if entry then
        if name and entry.name ~= name then
            entry.name = name
            entry.nameLower = slower(name)
        end
        if icon and entry.icon ~= icon then entry.icon = icon end
        entry.steps = steps
        entry.isGuildAchievement = isGuildAchievement or nil
        return entry
    end
    entry = setmetatable({
        name = name,
        nameLower = slower(name or ""),
        achievementID = id,
        icon = icon,
        steps = steps,
        isGuildAchievement = isGuildAchievement or nil,
    }, ACHIEVEMENT_MT)
    achievementEntryByID[id] = entry
    return entry
end

-- Fallback for a broken client search registry. Achievements and
-- statistics share one C-side search index; opening the Statistics view
-- and then /reloading leaves that index returning zero filtered results
-- for the rest of the client session (client bug, heals only on full
-- client restart; SetAchievementSearchString("") does not revive it).
-- Direct category enumeration keeps working in that state, so when
-- Blizzard's search returns nothing while achievements provably exist,
-- we build our own name index once (staggered) and serve from it.
-- Armed form of the fallback: the packed blob stays the store (a corpus
-- hydrates rows only for hits), and matching runs over ONE lowercase
-- names string with a position->row map -- hydrating ~5k row tables just
-- to substring-scan them was a 4MB allocation the warmledger convicted.
local fallbackScan
local fallbackBuilding = false

-- The index persists in SavedVariables keyed to the client build:
-- healthy sessions enumerate fast and pay the build once per patch;
-- broken sessions (where enumeration itself runs ~1ms per call) hydrate
-- from disk instantly instead of trickling for many seconds.
-- 2: rows packed into one string instead of ~5000 five-field tables. As tables
-- the index cost ~2 MB of live Lua the client parsed at login even for players
-- who never search achievements; packed it is a single string that is only
-- decoded if the fallback actually arms.
local ACH_INDEX_VER = 2

local ACH_ROW_SPEC = {
    { "id" }, { "name" }, { "icon" }, { "isGuild" }, { "completed" },
}

local function ClientBuildKey()
    local version, build = GetBuildInfo()
    return tostring(version) .. "-" .. tostring(build)
end

local function PersistFallbackIndex(rows)
    local db = EasyFind and EasyFind.db
    if not db then return end
    db.achievementIndex = {
        version = ACH_INDEX_VER,
        build = ClientBuildKey(),
        packed = Utils.PackRows(rows, ACH_ROW_SPEC),
    }
end

local ACH_NAME_ONLY = { name = true }

local function ArmFallbackScan(packed)
    -- ungated: these stubs never enter the main scoring gate, so skip the
    -- mask build. noShed: completed flips in place on ACHIEVEMENT_EARNED.
    local corpus = Utils.NewPackedCorpus(packed, ACH_ROW_SPEC, nil,
        { ungated = true, noShed = true })
    if corpus.count == 0 then return false end
    local parts, riAt = {}, {}
    local pos = 1
    corpus:EachRow(function(ri, row)
        local nm = type(row.name) == "string" and slower(row.name) or ""
        parts[ri] = nm
        riAt[ri] = pos
        pos = pos + #nm + 1
    end, ACH_NAME_ONLY)
    fallbackScan = {
        corpus = corpus,
        names = tconcat(parts, "\n"),
        riAt = riAt,
    }
    Utils.RegisterCorpus("achievementsFallback", corpus)
    return true
end

local function TryHydrateFallbackIndex()
    if fallbackScan then return true end
    local db = EasyFind and EasyFind.db
    local saved = db and db.achievementIndex
    if type(saved) ~= "table" or saved.version ~= ACH_INDEX_VER
       or saved.build ~= ClientBuildKey() or type(saved.packed) ~= "string"
       or saved.packed == "" then
        return false
    end
    return ArmFallbackScan(saved.packed)
end

local function ClientHasAchievements()
    local getList = _G["GetCategoryList"]
    local getNum = _G["GetCategoryNumAchievements"]
    if not getList or not getNum then return false end
    local cats = getList()
    if not cats then return false end
    for i = 1, #cats do
        local total = getNum(cats[i])
        if total and total > 0 then return true end
    end
    return false
end

local function RefreshOpenQuery(expectedQuery)
    local eb = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
    if not eb then return end
    -- Compare against the typed prefix (cursor-position cut), not the
    -- full editbox text: the autocomplete suffix is selected past the
    -- cursor and would make the full text mismatch.
    local full = eb:GetText() or ""
    local cursor = eb:GetCursorPosition() or #full
    local typedPrefix = strtrim(full:sub(1, cursor))
    if not expectedQuery or typedPrefix == expectedQuery then
        Search:OnSearchTextChanged(typedPrefix, true)
    end
end

local function BuildFallbackIndex()
    if fallbackScan or fallbackBuilding then return end
    local getList = _G["GetCategoryList"]
    local getNum = _G["GetCategoryNumAchievements"]
    local getInfo = _G["GetAchievementInfo"]
    if not getList or not getNum or not getInfo then return end
    local cats = getList()
    if not cats then return end
    fallbackBuilding = true
    local database = ns.Database
    local rows = {}
    local catIdx, achIdx = 1, 1
    -- Hard time budget per frame, not a row count: in the broken client
    -- state the enumeration calls themselves can be pathologically slow,
    -- and a fixed batch size would turn "cheap batch" into a sub-2fps
    -- lockup. Same pattern as the boss scanner.
    local budgetMs = 4
    local function step()
        local start = debugprofilestop and debugprofilestop() or 0
        local processed = 0
        while catIdx <= #cats do
            local catID = cats[catIdx]
            local total = getNum(catID) or 0
            while achIdx <= total do
                local ok, id, name, _, completed, _, _, _, _, _, icon, _, isGuild =
                    pcall(getInfo, catID, achIdx)
                if ok and id and name and name ~= ""
                   and not (database and database.IsStatisticAchievement
                            and database:IsStatisticAchievement(id)) then
                    rows[#rows + 1] = {
                        id = id, name = name, nameLower = slower(name),
                        icon = icon, isGuild = isGuild, completed = completed,
                    }
                end
                achIdx = achIdx + 1
                processed = processed + 1
                if (debugprofilestop and (debugprofilestop() - start) >= budgetMs)
                   or (not debugprofilestop and processed >= 50) then
                    Utils.SafeAfter(0, step)
                    return
                end
            end
            catIdx = catIdx + 1
            achIdx = 1
        end
        fallbackBuilding = false
        PersistFallbackIndex(rows)
        local db = EasyFind and EasyFind.db
        local saved = db and db.achievementIndex
        if saved and type(saved.packed) == "string" and saved.packed ~= "" then
            ArmFallbackScan(saved.packed)
        end
        RefreshOpenQuery(nil)
    end
    Utils.SafeAfter(0, step)
end

local function CollectFallbackResults(query, mode)
    local results = {}
    local queryLower = slower(query or "")
    if queryLower == "" or not fallbackScan then return results end
    local names = fallbackScan.names
    local riAt = fallbackScan.riAt
    local corpus = fallbackScan.corpus
    local total = corpus.count
    local namesLen = #names
    local init = 1
    while #results < ACH_MAX_RESULTS and init <= namesLen do
        local at = sfind(names, queryLower, init, true)
        if not at then break end
        local lo, hi = 1, total
        while lo < hi do
            local mid = mfloor((lo + hi + 1) / 2)
            if riAt[mid] <= at then lo = mid else hi = mid - 1 end
        end
        local stub = corpus:StubAt(lo)
        if stub.id and stub.name and AchievementPassesFilter(stub.completed, mode) then
            results[#results + 1] = GetOrCreateAchievementEntry(stub.id, stub.name, stub.icon, stub.isGuild)
        end
        init = riAt[lo + 1] or (namesLen + 1)
    end
    return results
end

-- Empty Blizzard results are only trusted once the fallback can vouch
-- for them: a stuck index returns zero for every query, so the first
-- empty answer hydrates or builds our own index instead of writing the
-- cache, and later empties are re-checked against it.
local function ResolveEmptySearchResults(query, mode)
    if fallbackScan or TryHydrateFallbackIndex() then
        return CollectFallbackResults(query, mode)
    end
    if not fallbackBuilding and ClientHasAchievements() then
        BuildFallbackIndex()
    end
    return nil
end

local function CollectAchievementSearchResults(query, mode)
    SyncAchievementSearchStatsVersion()
    mode = mode or GetAchievementFilterMode()

    local getNum = _G["GetNumFilteredAchievements"]
    local getID  = _G["GetFilteredAchievementID"]
    local getInfo = _G["GetAchievementInfo"]
    if not getNum or not getID or not getInfo then return nil end
    local count = getNum() or 0
    if count == 0 then return {} end
    local results = {}
    local database = ns.Database
    local canCheckStat = database and database.IsStatisticAchievement
    for i = 1, count do
        if #results >= ACH_MAX_RESULTS then break end
        local id = getID(i)
        if id and not (canCheckStat and database:IsStatisticAchievement(id)) then
            local _, name, _, completed, _, _, _, _, _, icon, _, isGuild = getInfo(id)
            if name and name ~= "" and AchievementPassesFilter(completed, mode) then
                results[#results + 1] = GetOrCreateAchievementEntry(id, name, icon, isGuild)
            end
        end
    end
    return results
end

local function EnsureAchievementSearchListener()
    if achSearchListener then return end
    achSearchListener = CreateFrame("Frame")
    achSearchListener:RegisterEvent("ACHIEVEMENT_SEARCH_UPDATED")
    achSearchListener:RegisterEvent("ACHIEVEMENT_EARNED")
    achSearchListener:SetScript("OnEvent", function(_, event, earnedID)
        if event == "ACHIEVEMENT_EARNED" then
            wipe(achSearchCache)
            -- Update in place: dropping the index would force a full
            -- rebuild, which trickles for many seconds when the client's
            -- enumeration path is in its broken state.
            if fallbackScan and earnedID then
                -- Locate the row by its packed id field (field 1, "n<id>")
                -- and flip completed on the stub; noShed keeps the flip.
                local corpus = fallbackScan.corpus
                local packed = corpus.packed
                local rowStart
                local at = sfind(packed, "\31n" .. earnedID .. "\30", 1, true)
                if at then
                    rowStart = at + 1
                elseif sfind(packed, "n" .. earnedID .. "\30", 1, true) == 1 then
                    rowStart = 1
                end
                if rowStart then
                    local offsets = corpus.offsets
                    local lo, hi = 1, corpus.count
                    while lo < hi do
                        local mid = mfloor((lo + hi + 1) / 2)
                        if offsets[mid] <= rowStart then lo = mid else hi = mid - 1 end
                    end
                    if offsets[lo] == rowStart then
                        local stub = corpus:StubAt(lo)
                        if stub.id == earnedID then stub.completed = true end
                    end
                end
            end
            return
        end
        local pending = achSearchPending
        if not pending then return end
        achSearchPending = nil
        achSearchCurrentQuery = pending.query
        local results = CollectAchievementSearchResults(pending.query, pending.mode)
        if results and #results == 0 then
            results = ResolveEmptySearchResults(pending.query, pending.mode)
        end
        -- Only refresh when there is something new to render. A nil here
        -- means the empty answer was distrusted and the fallback index is
        -- still building; refreshing anyway would re-run the search, which
        -- re-arms SetAchievementSearchString, which fires this event again:
        -- a full search pass per frame until the build lands. The build's
        -- completion callback does the one refresh that matters.
        if results then
            achSearchCache[pending.key] = results
            RefreshOpenQuery(pending.query)
        end
    end)
end

function Providers:RequestAchievementSearch(query)
    if not query or #query < 2 then return nil end
    SyncAchievementSearchStatsVersion()

    -- Arm the fallback proactively: hydrate the persisted index, or in a
    -- session with no valid cache start the background build now, while
    -- enumeration is (usually) healthy and cheap. Users then carry a
    -- ready index into any future broken session.
    if not fallbackScan and not fallbackBuilding and not TryHydrateFallbackIndex() then
        BuildFallbackIndex()
    end

    local mode = GetAchievementFilterMode()
    local cacheKey = AchievementSearchCacheKey(query, mode)
    local cached = achSearchCache[cacheKey]
    if cached then return cached end
    if achSearchCurrentQuery == query then
        local results = CollectAchievementSearchResults(query, mode)
        if results and #results == 0 then
            results = ResolveEmptySearchResults(query, mode)
        end
        if results then
            achSearchCache[cacheKey] = results
            return results
        end
    end
    local setSearch = _G["SetAchievementSearchString"]
    if not setSearch then return nil end
    EnsureAchievementSearchListener()
    achSearchPending = { query = query, mode = mode, key = cacheKey }
    pcall(setSearch, query)
    return nil
end

-- Dev-tool peek (EasyFindDev /efd achsearch): exercises the fallback path
-- directly -- arm state, build state, and the blob-scan hits for a query.
function Providers:_DebugFallbackSearch(query)
    local armed = fallbackScan ~= nil or TryHydrateFallbackIndex()
    local results
    if armed then
        results = CollectFallbackResults(query, GetAchievementFilterMode())
    end
    return armed, fallbackBuilding, results
end
