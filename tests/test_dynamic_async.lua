-- Locks in current Database/Dynamic.lua async provider behavior before the
-- scheduler migration. These tests must keep passing after migration.

local H = require("Harness")

local function setupDatabase()
    local env = H.newEnv()
    local ns = H.newNs(env)
    -- Scheduler must be loaded before Dynamic.lua so Dynamic's
    -- ensureJobsRegistered can find ns.Scheduler.
    H.loadModule("Shared/Scheduler.lua", env, ns)
    -- Dynamic derives provider categories from the shared category map.
    H.loadModule("Shared/CategoryMap.lua", env, ns)
    ns.Database.uiSearchData = {}
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.ResetSearchCache = function() end
    ns.Database.WarmSearchHotPath = function() end
    ns.Database.CancelDynamicScans = function() end

    -- Dynamic.lua iterates a hardcoded provider list; each provider names a
    -- method on Database (`fn`/`asyncFn`/`pre`). Tests stub the ones they
    -- exercise; unused stubs return false so providers stay marked dirty
    -- and don't pollute side effects.
    local stubLog = {}
    for _, key in ipairs({
        "PopulateDynamicCurrencies", "PopulateDynamicReputations",
        "PopulateDynamicAchievements", "PopulateDynamicStatistics",
        "PopulateDynamicStatisticsAsync",
        "PopulateDynamicMounts", "PopulateDynamicToys", "PopulateDynamicPets",
        "PopulateDynamicOutfits", "PopulateDynamicHeirlooms",
        "PopulateDynamicTitles", "PopulateDynamicGearSets",
        "PopulateDynamicMacros", "PopulateDynamicAbilities",
        "PopulateDynamicTalents", "PopulateDynamicBags", "PopulateDynamicBank",
        "PopulateDynamicTransmogSets", "SyncTransmogSetFiltersFromUI",
        "PopulateDynamicLoot", "PopulateDynamicLootAsync",
        "PopulateDynamicBosses", "PopulateDynamicBossesAsync",
    }) do
        ns.Database[key] = function()
            stubLog[#stubLog + 1] = key
            return true
        end
    end
    ns.Database._stubLog = stubLog

    H.loadModule("Database/Dynamic.lua", env, ns)
    return env, ns, ns.Database
end

local tests = {}

function tests.ensureLoaded_runsProviderAndCallsOnDone()
    local _, _, Database = setupDatabase()
    local ran, changed = false, nil
    Database.PopulateDynamicMounts = function() ran = true; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertTrue(ran, "provider fn should have been called")
    H.assertEq(changed, true, "onDone should be called with changed=true")
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.ensureLoaded_secondCallSkipsRerun()
    local _, _, Database = setupDatabase()
    local runs = 0
    Database.PopulateDynamicMounts = function() runs = runs + 1; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertEq(runs, 1, "provider should not be re-run once loaded+clean")
end

function tests.ensureLoaded_unknownKeyReturnsFalse()
    local _, _, Database = setupDatabase()
    H.assertFalse(Database:EnsureDynamicProviderLoaded("nonexistent", function() end))
end

function tests.providerReturningFalse_marksDirtyAndCallsOnDoneFalse()
    local _, _, Database = setupDatabase()
    local changed = "uninit"
    Database.PopulateDynamicMounts = function() return false end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertEq(changed, false, "onDone should be false when provider returns false")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.providerErrors_marksNotLoadedAndCallsOnDoneFalse()
    local _, _, Database = setupDatabase()
    local changed = "uninit"
    Database.PopulateDynamicMounts = function() error("boom") end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertEq(changed, false, "onDone should be false when provider errors")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.preFnRunsBeforeMainFn()
    local _, _, Database = setupDatabase()
    local order = {}
    Database.SyncTransmogSetFiltersFromUI = function() order[#order + 1] = "pre" end
    Database.PopulateDynamicTransmogSets = function()
        order[#order + 1] = "main"
        return true
    end
    Database:EnsureDynamicProviderLoaded("transmogSets", function() end)
    H.assertEq(order[1], "pre", "pre fn should run first")
    H.assertEq(order[2], "main", "main fn should run after pre")
end

function tests.refreshDynamicCategory_marksDirtyAndReruns()
    local _, _, Database = setupDatabase()
    local runs = 0
    Database.PopulateDynamicMounts = function() runs = runs + 1; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertEq(runs, 1)
    Database:RefreshDynamicCategory("mounts")
    H.assertEq(runs, 2, "RefreshDynamicCategory should rerun the provider")
end

function tests.markDynamicCategoryDirty_clearsCleanFlag()
    local _, _, Database = setupDatabase()
    Database.PopulateDynamicMounts = function() return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"))
    Database:MarkDynamicCategoryDirty("mounts")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"),
        "MarkDynamicCategoryDirty must make the provider report not-loaded")
end

function tests.markDynamicProviderLoaded_forcesLoadedState()
    local _, _, Database = setupDatabase()
    Database:MarkDynamicProviderLoaded("mounts")
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"),
        "MarkDynamicProviderLoaded should flag the key as loaded+clean")
end

function tests.asyncProvider_callsAllWaitersOnCompletion()
    local _, _, Database = setupDatabase()
    -- Capture the completion callback so we can fire it manually, simulating
    -- async work that completes later.
    local completion
    Database.PopulateDynamicStatisticsAsync = function(_, onDone)
        completion = onDone
        return nil  -- signals async start; runner doesn't auto-finish
    end
    local waiter1, waiter2 = "uninit", "uninit"
    Database:EnsureDynamicProviderLoaded("statistics", function(c) waiter1 = c end)
    -- A second EnsureLoaded while the first is in flight enqueues as a waiter.
    Database:EnsureDynamicProviderLoaded("statistics", function(c) waiter2 = c end)
    H.assertEq(waiter1, "uninit", "first waiter must not fire before async completes")
    H.assertEq(waiter2, "uninit", "second waiter must not fire before async completes")
    -- Fire the async completion. Both waiters get notified with the changed
    -- value the populator passed in.
    H.assertNotNil(completion, "async populator should have received completion callback")
    completion(true, nil)
    H.assertEq(waiter1, true, "first waiter should receive changed=true")
    H.assertEq(waiter2, true, "second waiter should receive changed=true")
    H.assertTrue(Database:IsDynamicProviderLoaded("statistics"))
end

function tests.asyncProvider_errorPathNotifiesAllWaitersWithFalse()
    local _, _, Database = setupDatabase()
    local completion
    Database.PopulateDynamicStatisticsAsync = function(_, onDone)
        completion = onDone
        return nil
    end
    local got = {}
    Database:EnsureDynamicProviderLoaded("statistics", function(c) got[#got + 1] = c end)
    Database:EnsureDynamicProviderLoaded("statistics", function(c) got[#got + 1] = c end)
    completion(false, "fake-error")
    H.assertEq(got[1], false)
    H.assertEq(got[2], false)
    H.assertFalse(Database:IsDynamicProviderLoaded("statistics"))
end

local pass, fail, failures = H.runSuite("Database/Dynamic", tests)
return { pass = pass, fail = fail, failures = failures }
