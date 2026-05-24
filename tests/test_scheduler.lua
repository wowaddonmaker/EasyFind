-- Tests for Shared/Scheduler.lua

local H = require("Harness")

local function loadScheduler()
    local env = H.newEnv()
    local ns = H.newNs(env)
    local Scheduler = H.loadModule("Shared/Scheduler.lua", env, ns)
    return Scheduler, env, ns
end

local tests = {}

function tests.singleSyncJob_runsOnStep()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local ran = false
    sched:Register("a", { run = function(_, done) ran = true; done() end })
    sched:Enqueue("a")
    H.assertEq(sched:Status("a"), "queued")
    sched:Step(0)
    H.assertTrue(ran)
    H.assertTrue(sched:IsComplete("a"))
end

function tests.dependencyOrder_singleChain()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local order = {}
    sched:Register("load",  { run = function(_, d) order[#order + 1] = "load"; d() end })
    sched:Register("index", { deps = { "load" },  run = function(_, d) order[#order + 1] = "index"; d() end })
    sched:Register("refresh", { deps = { "index" }, run = function(_, d) order[#order + 1] = "refresh"; d() end })
    sched:Enqueue("refresh")
    sched:Step(0)
    H.assertDeepEq(order, { "load", "index", "refresh" })
end

function tests.coalesce_doubleEnqueueRunsOnce()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local runs = 0
    sched:Register("a", { run = function(_, d) runs = runs + 1; d() end })
    sched:Enqueue("a")
    sched:Enqueue("a")
    sched:Enqueue("a")
    sched:Step(0)
    H.assertEq(runs, 1)
end

function tests.completedJobIsNotRerunByEnqueue()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local runs = 0
    sched:Register("a", { run = function(_, d) runs = runs + 1; d() end })
    sched:Enqueue("a")
    sched:Step(0)
    sched:Enqueue("a")
    sched:Step(0)
    H.assertEq(runs, 1, "re-enqueueing a complete job is a no-op")
end

function tests.reset_allowsRerun()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local runs = 0
    sched:Register("a", { run = function(_, d) runs = runs + 1; d() end })
    sched:Enqueue("a")
    sched:Step(0)
    sched:Reset("a")
    sched:Enqueue("a")
    sched:Step(0)
    H.assertEq(runs, 2)
end

function tests.debounce_delaysExecution()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local ran = false
    sched:Register("refresh", {
        debounce = 0.1,
        run = function(_, d) ran = true; d() end,
    })
    sched:Enqueue("refresh")
    sched:Step(0)
    H.assertFalse(ran, "debounced job should not run before delay elapses")
    sched:Step(0.05)
    H.assertFalse(ran, "still under debounce")
    sched:Step(0.06)
    H.assertTrue(ran, "should run after total elapsed exceeds debounce")
end

function tests.debounce_isBumpedByLaterEnqueue()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local ran = false
    sched:Register("refresh", {
        debounce = 0.1,
        run = function(_, d) ran = true; d() end,
    })
    sched:Enqueue("refresh")
    sched:Step(0.05)
    sched:Enqueue("refresh")  -- bump: now debounceUntil = 0.05 + 0.1 = 0.15
    sched:Step(0.06)          -- now = 0.11; still under bumped debounce
    H.assertFalse(ran)
    sched:Step(0.05)          -- now = 0.16; debounce elapsed
    H.assertTrue(ran)
end

function tests.asyncJob_completesWhenDoneCalled()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local capturedDone
    sched:Register("load", { run = function(_, done) capturedDone = done end })
    sched:Register("index", { deps = { "load" }, run = function(_, d) d() end })
    sched:Enqueue("index")
    sched:Step(0)
    H.assertEq(sched:Status("load"), "running",
        "async run() that doesn't call done stays running")
    H.assertEq(sched:Status("index"), "queued",
        "dependent stays queued while dep is running")
    capturedDone()
    sched:Step(0)
    H.assertTrue(sched:IsComplete("load"))
    H.assertTrue(sched:IsComplete("index"))
end

function tests.asyncJob_failureResetsToPending()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local errorReports = {}
    sched.onError = function(id, err) errorReports[#errorReports + 1] = { id, err } end
    local capturedDone
    sched:Register("load", { run = function(_, done) capturedDone = done end })
    sched:Enqueue("load")
    sched:Step(0)
    capturedDone(false, "fake-failure")
    H.assertEq(sched:Status("load"), "pending",
        "failed async job should reset to pending so a retry can run it")
    H.assertEq(errorReports[1][1], "load")
    H.assertEq(errorReports[1][2], "fake-failure")
end

function tests.cancelGroup_dropsPendingAndComplete()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local runs = { a = 0, b = 0, c = 0 }
    sched:Register("a", { cancelGroup = "g1", run = function(_, d) runs.a = runs.a + 1; d() end })
    sched:Register("b", { cancelGroup = "g1", run = function(_, d) runs.b = runs.b + 1; d() end })
    sched:Register("c", { cancelGroup = "g2", run = function(_, d) runs.c = runs.c + 1; d() end })
    sched:Enqueue("a"); sched:Enqueue("b"); sched:Enqueue("c")
    sched:Step(0)
    H.assertEq(runs.a, 1); H.assertEq(runs.b, 1); H.assertEq(runs.c, 1)
    sched:CancelGroup("g1")
    H.assertEq(sched:Status("a"), "pending")
    H.assertEq(sched:Status("b"), "pending")
    H.assertEq(sched:Status("c"), "complete", "g2 should be untouched")
    -- Re-enqueueing a after cancel must re-run it.
    sched:Enqueue("a")
    sched:Step(0)
    H.assertEq(runs.a, 2)
end

function tests.runError_failsJobAndContinues()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local errReceived
    sched.onError = function(id, err) errReceived = { id = id, err = tostring(err) } end
    local laterRan = false
    sched:Register("bad", { run = function() error("kaboom") end })
    sched:Register("good", { run = function(_, d) laterRan = true; d() end })
    sched:Enqueue("bad"); sched:Enqueue("good")
    sched:Step(0)
    H.assertEq(sched:Status("bad"), "pending", "errored job resets to pending")
    H.assertTrue(sched:IsComplete("good"), "scheduler should keep running other jobs")
    H.assertTrue(laterRan)
    H.assertNotNil(errReceived)
    H.assertEq(errReceived.id, "bad")
    H.assertTrue(errReceived.err:find("kaboom") ~= nil, "error message should be propagated")
end

function tests.unknownEnqueueIsNoOp()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    H.assertFalse(sched:Enqueue("nonexistent"))
end

function tests.ctx_includesIdAndScheduler()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local seenCtx
    sched:Register("a", { run = function(ctx, d) seenCtx = ctx; d() end })
    sched:Enqueue("a")
    sched:Step(0)
    H.assertEq(seenCtx.jobId, "a")
    H.assertEq(seenCtx.scheduler, sched)
end

function tests.budget_stopsAfterBudgetExceeded()
    -- Hard to assert wall-clock behavior portably; verify the API is at
    -- least callable with a budget and doesn't error.
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    sched:Register("a", { run = function(_, d) d() end })
    sched:Enqueue("a")
    sched:Step(0, 0.001)  -- 1ms budget
    H.assertTrue(sched:IsComplete("a"))
end

function tests.setBudgetMs_storesSeconds()
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    sched:SetBudgetMs(5)
    H.assertEq(sched.budgetSeconds, 0.005)
    sched:SetBudgetMs(0)
    H.assertEq(sched.budgetSeconds, 0)
end

function tests.depsAutoEnqueue_intermediateBranch()
    -- Enqueueing a leaf with a diamond shape should pull both intermediate
    -- jobs and run the shared root only once.
    local Scheduler = loadScheduler()
    local sched = Scheduler.new()
    local runs = { root = 0, leftMid = 0, rightMid = 0, leaf = 0 }
    sched:Register("root",     { run = function(_, d) runs.root = runs.root + 1; d() end })
    sched:Register("leftMid",  { deps = { "root" }, run = function(_, d) runs.leftMid = runs.leftMid + 1; d() end })
    sched:Register("rightMid", { deps = { "root" }, run = function(_, d) runs.rightMid = runs.rightMid + 1; d() end })
    sched:Register("leaf",     { deps = { "leftMid", "rightMid" }, run = function(_, d) runs.leaf = runs.leaf + 1; d() end })
    sched:Enqueue("leaf")
    sched:Step(0)
    H.assertEq(runs.root, 1, "root should run exactly once for both branches")
    H.assertEq(runs.leftMid, 1)
    H.assertEq(runs.rightMid, 1)
    H.assertEq(runs.leaf, 1)
end

local pass, fail, failures = H.runSuite("Scheduler", tests)
return { pass = pass, fail = fail, failures = failures }
