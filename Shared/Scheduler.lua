local _, ns = ...

-- Minimal async job scheduler.
--
-- Use case: replace ad-hoc SafeAfter chains and per-call coalescing flags
-- for dynamic data loading, indexing, and refresh debouncing. The scheduler
-- guarantees:
--   * dependencies declared with deps={} run before dependents
--   * Enqueue is idempotent per id (coalesces duplicate calls)
--   * debounced jobs fire only after `debounce` seconds of quiet
--   * CancelGroup throws away jobs sharing the same `cancelGroup`
--   * Step(elapsed) advances the internal clock deterministically for tests
--   * the OnUpdate pump enforces a wall-clock budget per frame
--
-- Out of scope (intentional): retries, priorities, lifecycle hooks, public
-- extension surface. Add them when a specific job demands them.
--
-- Job lifecycle:
--   pending -> queued -> running -> complete
--                                \-> pending (run called done(false, err))
--
-- A `complete` job stays complete until Reset(id) or CancelGroup(group)
-- moves it back to pending. Re-Enqueueing a complete job is a no-op.

---@class SchedulerJobSpec
---@field deps string[]?      ids that must be `complete` before this runs
---@field debounce number?    seconds of quiet required before firing
---@field cancelGroup string? logical group passed to CancelGroup
---@field run fun(ctx: SchedulerCtx, done: fun(ok?: boolean, err?: string))
---@field tag string?         optional label used in error logging

---@class SchedulerCtx
---@field jobId string
---@field scheduler Scheduler

---@class SchedulerJob
---@field id string
---@field spec SchedulerJobSpec
---@field status "pending"|"queued"|"running"|"complete"
---@field debounceUntil number
---@field completed boolean

---@class Scheduler
local Scheduler = {}
Scheduler.__index = Scheduler

local osclock = os and os.clock
local function wallClock() return osclock and osclock() or 0 end

-- WoW does not expose the `debug` library, so xpcall handlers must use
-- `debugstack` (WoW global) instead of `debug.traceback`. Fall back to a
-- bare tostring when neither is available (test harness with stripped env).
local debugstack_ = rawget(_G, "debugstack")
local debugtraceback = (rawget(_G, "debug") and rawget(_G, "debug").traceback) or nil
local function errorHandler(err)
    if debugstack_ then
        return tostring(err) .. "\n" .. debugstack_(2)
    elseif debugtraceback then
        return debugtraceback(tostring(err), 2)
    end
    return tostring(err)
end

---Creates a new Scheduler instance. Most code should use the singleton at
---ns.Scheduler; tests instantiate fresh schedulers per test.
---@return Scheduler
function Scheduler.new()
    return setmetatable({
        jobs = {},
        queue = {},
        now = 0,
        budgetSeconds = 0.002,
        onError = nil,
    }, Scheduler)
end

---Registers a job under the given id. Re-registering overwrites the spec
---and resets state to pending.
---@param id string
---@param spec SchedulerJobSpec
function Scheduler:Register(id, spec)
    assert(type(id) == "string" and id ~= "", "Scheduler:Register requires a non-empty id")
    assert(type(spec) == "table" and type(spec.run) == "function",
        "Scheduler:Register requires { run = function }")
    self.jobs[id] = {
        id = id,
        spec = spec,
        status = "pending",
        debounceUntil = 0,
        completed = false,
    }
end

---Returns true if the job has reached `complete`.
---@param id string
---@return boolean
function Scheduler:IsComplete(id)
    local job = self.jobs[id]
    return job ~= nil and job.status == "complete"
end

---Returns the current status string, or nil if unregistered.
---@param id string
---@return string?
function Scheduler:Status(id)
    local job = self.jobs[id]
    return job and job.status or nil
end

local function removeFromQueue(queue, id)
    for i = #queue, 1, -1 do
        if queue[i] == id then
            table.remove(queue, i)
            return
        end
    end
end

---Enqueues a job. Idempotent for pending/queued/running jobs (bumps
---debounce if any). No-op for `complete` jobs — use Reset/CancelGroup
---first if you need to re-run.
---@param id string
---@return boolean enqueued
function Scheduler:Enqueue(id)
    local job = self.jobs[id]
    if not job then return false end
    if job.status == "complete" then return false end
    if job.status == "queued" or job.status == "running" then
        if job.spec.debounce then
            job.debounceUntil = self.now + job.spec.debounce
        end
        return true
    end
    -- Auto-enqueue unmet dependencies so a single Enqueue at the leaf
    -- pulls in the chain. Already-complete deps are skipped by the
    -- recursive call's `status == "complete"` guard.
    local deps = job.spec.deps
    if deps then
        for i = 1, #deps do
            self:Enqueue(deps[i])
        end
    end
    job.status = "queued"
    job.debounceUntil = job.spec.debounce and (self.now + job.spec.debounce) or 0
    table.insert(self.queue, id)
    return true
end

---Cancels all jobs whose cancelGroup matches. Pending/queued jobs are
---removed from the queue and reset; complete jobs are reset so a future
---Enqueue re-runs them. Running jobs are reset but the in-flight run()
---callback is responsible for actually aborting its work.
---@param group string
function Scheduler:CancelGroup(group)
    for id, job in pairs(self.jobs) do
        if job.spec.cancelGroup == group then
            removeFromQueue(self.queue, id)
            job.status = "pending"
            job.completed = false
        end
    end
end

---Resets a single job back to pending so re-Enqueue runs it again.
---@param id string
function Scheduler:Reset(id)
    local job = self.jobs[id]
    if not job then return end
    removeFromQueue(self.queue, id)
    job.status = "pending"
    job.completed = false
end

---Sets the per-frame wall-clock budget used by the OnUpdate pump.
---@param ms number
function Scheduler:SetBudgetMs(ms)
    self.budgetSeconds = math.max(0, (ms or 0) / 1000)
end

local function jobReady(scheduler, job)
    if job.status ~= "queued" then return false end
    if job.debounceUntil > scheduler.now then return false end
    local deps = job.spec.deps
    if deps then
        for i = 1, #deps do
            local depJob = scheduler.jobs[deps[i]]
            if not depJob or depJob.status ~= "complete" then
                return false
            end
        end
    end
    return true
end

local function pickReadyJob(scheduler)
    local queue = scheduler.queue
    for i = 1, #queue do
        local job = scheduler.jobs[queue[i]]
        if job and jobReady(scheduler, job) then
            return queue[i]
        end
    end
    return nil
end

local function makeDone(scheduler, job)
    return function(ok, err)
        if job.completed then return end
        job.completed = true
        if ok == false then
            job.status = "pending"
            if scheduler.onError then
                scheduler.onError(job.id, err)
            end
        else
            job.status = "complete"
        end
    end
end

local function runJob(scheduler, id)
    local job = scheduler.jobs[id]
    if not job then return end
    removeFromQueue(scheduler.queue, id)
    job.status = "running"
    job.completed = false
    local done = makeDone(scheduler, job)
    local ctx = { jobId = id, scheduler = scheduler }
    local ok, err = xpcall(job.spec.run, errorHandler, ctx, done)
    if not ok then
        done(false, err)
    end
    -- If run() didn't call done synchronously and didn't error, status
    -- stays "running" until something external (or the run's coroutine)
    -- invokes done(). Subsequent Step calls will pick up dependents once
    -- done() flips status to "complete".
end

---Advances the internal clock and runs as many ready jobs as fit within
---the optional wall-clock budget. Tests pass no budget for determinism;
---the OnUpdate pump passes self.budgetSeconds.
---@param elapsed number  seconds to advance the virtual clock
---@param budgetSeconds number? optional wall-clock cap on this Step
function Scheduler:Step(elapsed, budgetSeconds)
    self.now = self.now + (elapsed or 0)
    local startWall = budgetSeconds and wallClock() or nil
    while true do
        local id = pickReadyJob(self)
        if not id then return end
        runJob(self, id)
        if startWall and (wallClock() - startWall) > budgetSeconds then
            return
        end
    end
end

---Starts an OnUpdate-driven pump on the given frame. The frame must
---support SetScript. Each tick advances the clock by the real elapsed
---and runs jobs within `self.budgetSeconds` of wall-clock work.
---@param frame any   any WoW frame; use CreateFrame("Frame") when none on hand
function Scheduler:StartPump(frame)
    if self._pumpFrame then return end
    assert(frame and frame.SetScript, "Scheduler:StartPump requires a frame with SetScript")
    self._pumpFrame = frame
    frame:SetScript("OnUpdate", function(_, dt)
        self:Step(dt or 0, self.budgetSeconds)
    end)
end

---Stops the OnUpdate pump and detaches its handler.
function Scheduler:StopPump()
    local frame = self._pumpFrame
    if not frame then return end
    self._pumpFrame = nil
    frame:SetScript("OnUpdate", nil)
end

-- Default singleton used by addon code; tests instantiate their own.
local default = Scheduler.new()

if ns then
    ns.Scheduler = default
    ns.SchedulerType = Scheduler
end
return Scheduler
