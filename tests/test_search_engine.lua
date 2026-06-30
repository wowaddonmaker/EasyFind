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

local pass, fail, failures = H.runSuite("SearchEngine", tests)
return { pass = pass, fail = fail, failures = failures }
