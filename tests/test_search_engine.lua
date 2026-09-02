local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
local Engine = H.loadModule("Search/Engine.lua", env, ns)

local tests = {}

local function withProviderCapture(loaded)
    local requested = {}
    ns.Database.IsDynamicProviderLoaded = function(_, key)
        return loaded and loaded[key] or false
    end
    ns.Database.RequestDynamicProviderLoaded = function(_, key, onDone)
        requested[#requested + 1] = key
        if onDone then onDone(true) end
        return true
    end
    ns.Database.NormalizeSearchQuery = function(_, query) return query end
    return requested
end

function tests.lowNonzeroResultsStillRequestAbilities()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 1)

    H.assertEq(requested[1], "abilities",
        "low-result generic ability names should request abilities first")
end

function tests.richGenericResultsDoNotPreloadLowResultProviders()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 4)

    H.assertEq(#requested, 0,
        "generic queries with enough results should not fan out provider loads")
end

function tests.explicitAbilityWordRequestsAbilitiesRegardlessOfResultCount()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("ability dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 10)

    H.assertEq(requested[1], "abilities",
        "explicit ability query should request abilities even with existing results")
end

function tests.explicitOptionsQueryRequestsOptionsDespiteExistingResults()
    withProviderCapture()
    local populateRequests = 0
    local liveRequests = 0
    ns.BlizzOptionsSearch = {
        EnsurePopulatedAsync = function(_, onDone)
            populateRequests = populateRequests + 1
            if onDone then onDone(true) end
            return true
        end,
        EnsureLivePopulatedAsync = function(_, onDone)
            liveRequests = liveRequests + 1
            if onDone then onDone(true) end
            return true
        end,
    }
    local ctx = Engine:BuildContext("enemy nameplate", nil, {
        options = true,
        gameOptions = true,
        addonOptions = true,
    })

    Engine:RequestProviders(ctx, function() end, 2)

    H.assertEq(populateRequests, 1,
        "explicit settings queries should request options even when partial results exist")
    H.assertEq(liveRequests, 1,
        "explicit game-settings queries should request live SettingsPanel rows")
    ns.BlizzOptionsSearch = nil
end

function tests.bareQuickFilterRequestsItsProvider()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "outfits" }, nil)

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "outfits",
        "a bare quick filter (empty query) must load its category's provider")
end

function tests.quickFilterOverridesDisabledFilterMenu()
    -- Regression: `quickFilter and nil or activeFilters` leaked the filter
    -- menu into the engine and FilterAllows blocked the pill's provider.
    -- Even if filters leak again, the pill must win.
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "outfits" },
        { outfits = false, collections = true })

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "outfits",
        "an explicit quick filter must override the filter menu state")
end

function tests.typedSnippetsWordDemandLoadsSnippetsProvider()
    -- Regression: the snippets port shipped without a PROVIDERS row, so
    -- typing "snippets" after a reload could not demand-load the provider
    -- and waited ~2s for the eager chain to reach it (second-to-last).
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("snippets", nil, { snippets = true })

    Engine:RequestProviders(ctx, function() end, 10)

    H.assertEq(requested[1], "snippets",
        "typing snippets must demand-load the provider, not wait for the eager chain")
end

function tests.snipQuickFilterLoadsSnippetsProvider()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "snippets" }, nil)

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "snippets",
        "the @snip pill must load the snippets provider on an empty query")
end

local pass, fail, failures = H.runSuite("SearchEngine", tests)
return { pass = pass, fail = fail, failures = failures }
