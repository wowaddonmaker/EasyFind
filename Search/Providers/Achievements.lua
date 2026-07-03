local _, ns = ...

local Search = ns.Search
local Providers = ns.SearchProviders
local Utils = ns.Utils

local slower = Utils.slower
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
    achSearchListener:SetScript("OnEvent", function(_, event)
        if event == "ACHIEVEMENT_EARNED" then
            wipe(achSearchCache)
            return
        end
        local pending = achSearchPending
        if not pending then return end
        achSearchPending = nil
        achSearchCurrentQuery = pending.query
        local results = CollectAchievementSearchResults(pending.query, pending.mode)
        if results then achSearchCache[pending.key] = results end
        local eb = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        if eb then
            -- Compare against the typed prefix (cursor-position cut),
            -- not the full editbox text. The autocomplete suffix is
            -- selected past the cursor and would make full text != pending.
            local full = eb:GetText() or ""
            local cursor = eb:GetCursorPosition() or #full
            local typedPrefix = strtrim(full:sub(1, cursor))
            if typedPrefix == pending.query then
                Search:OnSearchTextChanged(typedPrefix, true)
            end
        end
    end)
end

function Providers:RequestAchievementSearch(query)
    if not query or #query < 2 then return nil end
    SyncAchievementSearchStatsVersion()

    local mode = GetAchievementFilterMode()
    local cacheKey = AchievementSearchCacheKey(query, mode)
    local cached = achSearchCache[cacheKey]
    if cached then return cached end
    if achSearchCurrentQuery == query then
        local results = CollectAchievementSearchResults(query, mode)
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
