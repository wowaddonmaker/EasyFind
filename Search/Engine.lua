local _, ns = ...

local Engine = {}
ns.SearchEngine = Engine

local Utils = ns.Utils
local SearchText = ns.SearchText
local Database = ns.Database

local slower = SearchText.Normalize
local ssub = Utils.ssub

local OPTION_WORDS = {
    accessibility = true, audio = true, camera = true, chat = true, combat = true,
    control = true, controls = true, display = true, graphics = true, interface = true,
    keybind = true, keybinds = true, keybinding = true, keybindings = true,
    nameplate = true, nameplates = true, sound = true, video = true,
    addon = true, addons = true, bind = true, binding = true, bindings = true,
    config = true, cvar = true, option = true, options = true, setting = true,
    settings = true,
    ambience = true, antialiasing = true, brightness = true, clutter = true,
    colorblind = true, contrast = true, cursor = true, density = true,
    detail = true, dialog = true, distance = true, environment = true,
    filtering = true, fxaa = true, gamma = true, latency = true,
    liquid = true, monitor = true, mouse = true, msaa = true, music = true,
    particle = true, quality = true, render = true, resolution = true,
    scale = true, shadow = true, sfx = true, subtitle = true, sync = true,
    texture = true, tooltip = true, ui = true, vertical = true, view = true,
    volume = true,
}

local STATISTICS_WORD_LIST = { "stat", "stats", "statistic", "statistics" }
local STATISTICS_WORDS = {
    stat = true, stats = true, statistic = true, statistics = true,
}
local BOSS_WORD_LIST = { "boss", "bosses", "dungeon", "dungeons", "encounter", "encounters", "raid", "raids" }
local BOSS_WORDS = {
    boss = true, bosses = true, dungeon = true, dungeons = true,
    encounter = true, encounters = true, raid = true, raids = true,
}

local COLLECTION_PARENT = {
    appearanceItems = true, appearanceSets = true, heirlooms = true,
    mounts = true, outfits = true, pets = true, toys = true,
}

local OPTION_PARENT = {
    addonOptions = true, gameOptions = true,
}

local EXPLICIT_FILTER_OVERRIDE = {
    bosses = true,
    statistics = true,
}

local PROVIDERS = {
    { key = "abilities", words = { "ability", "abilities", "spell", "spells" }, loadOnLowResults = true },
    { key = "talents", words = { "talent", "talents", "spec", "specialization" }, loadOnLowResults = true },
    { key = "macros", words = { "macro", "macros" }, loadOnLowResults = true },
    { key = "currencies", words = { "currency", "currencies", "cur" }, loadOnLowResults = true },
    { key = "reputations", words = { "rep", "reps", "reputation", "reputations", "faction" }, loadOnLowResults = true },
    { key = "achievements", words = { "ach", "achievement", "achievements" }, loadOnLowResults = true },
    { key = "statistics", words = STATISTICS_WORD_LIST, loadWhenEnabled = true },
    { key = "mounts", words = { "mount", "mounts" }, loadOnLowResults = true },
    { key = "toys", words = { "toy", "toys" }, loadOnLowResults = true },
    { key = "pets", words = { "pet", "pets", "battlepet", "battlepets" }, loadOnLowResults = true },
    { key = "outfits", words = { "outfit", "outfits" }, loadOnLowResults = true },
    { key = "heirlooms", words = { "heirloom", "heirlooms" }, loadOnLowResults = true },
    { key = "titles", words = { "title", "titles" }, loadOnLowResults = true },
    { key = "gearSets", words = { "gearset", "gearsets", "equipment", "equipmentset" }, loadOnLowResults = true },
    { key = "bags", words = { "bag", "bags", "inventory" }, loadOnLowResults = true },
    { key = "transmogSets", words = { "appearance", "appearances", "appset", "appsets", "set", "sets", "tmog", "transmog", "xmog" }, loadOnLowResults = true },
    { key = "appearanceItems", words = { "appearance", "appearances", "item", "items", "tmog", "transmog", "xmog" }, explicitOnly = true },
    { key = "loot", words = { "gear", "item", "items", "loot" }, heavyQuery = true },
    { key = "bosses", words = BOSS_WORD_LIST, loadWhenEnabled = true },
}

local pendingDynamic = {}
local LOW_RESULT_PROVIDER_THRESHOLD = 3

local function makeLookup(words)
    local lookup = {}
    for i = 1, #words do
        lookup[words[i]] = true
    end
    return lookup
end

for i = 1, #PROVIDERS do
    PROVIDERS[i].lookup = makeLookup(PROVIDERS[i].words)
end

local function cleanWord(word)
    return word and word:gsub("^%p+", ""):gsub("%p+$", "") or ""
end

function Engine:BuildContext(text, quickFilter, filters)
    local query = slower(text or "")
    if Database and Database.NormalizeSearchQuery then
        query = Database:NormalizeSearchQuery(query)
    end
    local words = {}
    for word in query:gmatch("%S+") do
        local cleaned = cleanWord(word)
        if cleaned ~= "" then words[#words + 1] = cleaned end
    end
    return {
        text = text or "",
        query = query,
        words = words,
        quickFilter = quickFilter,
        filters = filters,
    }
end

function Engine:LooksLikeStatistics(ctx)
    return self:QuickFilterIncludes(ctx, "statistics")
        or self:HasAnyWord(ctx, STATISTICS_WORDS)
end

function Engine:LooksLikeBosses(ctx)
    return self:QuickFilterIncludes(ctx, "bosses")
        or self:HasAnyWord(ctx, BOSS_WORDS)
end

function Engine:FilterAllows(ctx, key, explicit)
    local filters = ctx and ctx.filters
    if not filters then return true end
    if explicit and EXPLICIT_FILTER_OVERRIDE[key] then
        if COLLECTION_PARENT[key] and filters.collections == false then return false end
        if OPTION_PARENT[key] and filters.options == false then return false end
        return true
    end
    if filters[key] == false then return false end
    if COLLECTION_PARENT[key] and filters.collections == false then return false end
    if OPTION_PARENT[key] and filters.options == false then return false end
    return true
end

function Engine:QuickFilterIncludes(ctx, key)
    local def = ctx and ctx.quickFilter
    if not def then return false end
    if def.key == key then return true end
    if key == "appearanceItems" and def.key == "collections" then return false end
    return def.bucketLookup and def.bucketLookup[key] or false
end

function Engine:HasAnyWord(ctx, lookup)
    local words = ctx and ctx.words
    if not words then return false end
    for i = 1, #words do
        local word = words[i]
        if lookup[word] then return true end
        if #word >= 4 then
            for candidate in pairs(lookup) do
                if #candidate >= #word and ssub(candidate, 1, #word) == word then
                    return true
                end
            end
        end
    end
    return false
end

function Engine:LooksLikeOptions(ctx)
    if self:QuickFilterIncludes(ctx, "gameOptions")
       or self:QuickFilterIncludes(ctx, "addonOptions")
       or self:QuickFilterIncludes(ctx, "options") then
        return true
    end
    return self:HasAnyWord(ctx, OPTION_WORDS)
end

function Engine:RequestDynamicProvider(key, onChanged)
    if pendingDynamic[key] then return false end
    if not (Database and Database.RequestDynamicProviderLoaded) then return false end
    if Database.IsDynamicProviderLoaded and Database:IsDynamicProviderLoaded(key) then return false end

    pendingDynamic[key] = true
    local started = Database:RequestDynamicProviderLoaded(key, function(changed)
        pendingDynamic[key] = nil
        if changed and onChanged then onChanged(true) end
    end)
    if not started then pendingDynamic[key] = nil end
    return started
end

function Engine:RequestOptions(ctx, onChanged, resultCount)
    local gameAllowed = self:FilterAllows(ctx, "gameOptions")
    local addonAllowed = self:FilterAllows(ctx, "addonOptions")
    if not gameAllowed and not addonAllowed then
        return false
    end
    local options = ns.BlizzOptionsSearch
    if not options then return false end

    local explicit = self:LooksLikeOptions(ctx)
    local queryLen = #(ctx.query or "")
    local wordCount = #(ctx.words or {})
    local lowResultFallback = resultCount
        and queryLen >= 5
        and wordCount >= 1
        and resultCount == 0
    if not explicit and not lowResultFallback then return false end
    local needsMoreOptions = lowResultFallback or explicit
    if not needsMoreOptions then return false end

    local addonOnlyQuickFilter = self:QuickFilterIncludes(ctx, "addonOptions")
        and not self:QuickFilterIncludes(ctx, "gameOptions")
        and not self:QuickFilterIncludes(ctx, "options")
    local requested = false
    if options.EnsurePopulatedAsync then
        requested = options:EnsurePopulatedAsync(onChanged) or requested
    elseif options.EnsurePopulated then
        options:EnsurePopulated()
        requested = true
    end
    if gameAllowed and explicit and not addonOnlyQuickFilter and options.EnsureLivePopulatedAsync then
        requested = options:EnsureLivePopulatedAsync(onChanged) or requested
    end
    return requested
end

function Engine:ShouldLoadForLowResults(ctx, spec, resultCount)
    if not spec.loadOnLowResults then return false end
    if ctx.quickFilter then return false end
    if not resultCount or resultCount > LOW_RESULT_PROVIDER_THRESHOLD then return false end
    if #(ctx.query or "") < 4 then return false end
    return true
end

function Engine:RequestProviders(ctx, onChanged, resultCount)
    if not ctx or #(ctx.query or "") < 2 then return false end

    local requested = self:RequestOptions(ctx, onChanged, resultCount)

    for i = 1, #PROVIDERS do
        local spec = PROVIDERS[i]
        local key = spec.key
        local explicit = self:QuickFilterIncludes(ctx, key)
            or self:HasAnyWord(ctx, spec.lookup)
        if self:FilterAllows(ctx, key, explicit) then
            local shouldRequest = explicit
                or (spec.loadWhenEnabled and ctx.filters and ctx.filters[key] == true)
                or self:ShouldLoadForLowResults(ctx, spec, resultCount)
            if spec.heavyQuery and Database and Database.QueryNeedsHeavySearchData then
                shouldRequest = shouldRequest or Database:QueryNeedsHeavySearchData(ctx.text)
            end
            if shouldRequest then
                requested = self:RequestDynamicProvider(key, onChanged) or requested
            end
        end
    end

    return requested
end

return Engine
