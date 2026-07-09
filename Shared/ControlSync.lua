local _, ns = ...

local Utils = ns.Utils
local pairs = Utils.pairs

-- ONE sync engine for every control that mirrors Blizzard-side state
-- (housing catalog filters, profession recipe filters, and whatever comes
-- next). Registrations declare WHAT to read/write; the engine owns, exactly
-- once, the machinery that was previously hand-wired per control and
-- re-created the same bug class each time:
--   - pending = UNDELIVERED intent only (dirty flags, never inferred from
--     state existing), persisted in the registration's db key
--   - push outranks read-back while pending (lost-update protection)
--   - a watcher armed only while pending, applying on availability
--   - login: re-arm pending, else adopt the counterpart's retained state
--   - split gates: available() for retained-state reads/writes, live() for
--     intent that only lands on a live UI (applied deferred via liveApply)
--
-- Registration fields:
--   key          engine handle
--   pendingKey   EasyFind.db boolean for undelivered intent
--   state        fn -> the control's state table
--   available    fn -> bool: counterpart accepts reads/retained writes now
--   push         fn(state): write retained state (only called when available)
--   pull         fn(state): read counterpart into state (available, not pending)
--   live         fn -> bool (optional): gate for liveApply; defaults to available
--   liveApply    fn(state) (optional): deliver live-only intent (deferred)
--   isDirty      fn(state) -> bool (optional): undelivered live-only intent
--   clearDirty   fn(state) (optional)
--   reconcile    bool (optional): at login with nothing pending, pull once

local ControlSync = {}
ns.ControlSync = ControlSync

local registrations = {}

local function LiveGate(reg)
    if reg.live then return reg.live() end
    return reg.available()
end

local function Dirty(reg, state)
    return reg.isDirty and reg.isDirty(state) or false
end

local function Arm(reg)
    if reg._armed then return end
    reg._armed = true
    local function tick()
        local db = EasyFind and EasyFind.db
        if not (db and db[reg.pendingKey]) then
            reg._armed = false
            return
        end
        if LiveGate(reg) then
            reg._armed = false
            ControlSync.Deliver(reg.key)
            return
        end
        Utils.SafeAfter(1, tick)
    end
    Utils.SafeAfter(1, tick)
end

-- Watcher delivery: ONLY the undelivered live-only intent. Re-pushing the
-- full retained snapshot here re-applied stale experiment state on window
-- open and blanked the recipe list ("no results with your current filters").
function ControlSync.Deliver(key)
    local reg = registrations[key]
    local db = EasyFind and EasyFind.db
    if not (reg and db) then return end
    if reg.liveApply and LiveGate(reg) then
        Utils.SafeAfter(0.3, function()
            if not LiveGate(reg) then return end
            reg.liveApply(reg.state())
            if reg.clearDirty then reg.clearDirty(reg.state()) end
        end)
    end
    db[reg.pendingKey] = false
end

function ControlSync.Register(reg)
    registrations[reg.key] = reg
    return reg
end

function ControlSync.MarkPending(key)
    local reg = registrations[key]
    local db = EasyFind and EasyFind.db
    if not (reg and db) then return end
    db[reg.pendingKey] = true
    Arm(reg)
end

-- Write direction: retained state whenever available; live-only intent
-- delivered deferred when the live gate passes, else left pending for the
-- watcher. Returns false only when nothing could be written.
function ControlSync.Push(key)
    local reg = registrations[key]
    local db = EasyFind and EasyFind.db
    if not (reg and db) then return false end
    local state = reg.state()
    if not reg.available() then
        db[reg.pendingKey] = true
        Arm(reg)
        return false
    end
    reg.push(state)
    if not LiveGate(reg) and Dirty(reg, state) then
        db[reg.pendingKey] = true
        Arm(reg)
        return true
    end
    db[reg.pendingKey] = false
    if reg.liveApply and LiveGate(reg) then
        Utils.SafeAfter(0.3, function()
            if not LiveGate(reg) then return end
            reg.liveApply(reg.state())
            if reg.clearDirty then reg.clearDirty(reg.state()) end
        end)
    elseif reg.clearDirty and not Dirty(reg, state) then
        reg.clearDirty(state)
    end
    return true
end

-- Read direction: pending (undelivered intent) outranks read-back.
function ControlSync.Sync(key)
    local reg = registrations[key]
    local db = EasyFind and EasyFind.db
    if not (reg and db) then return false end
    if db[reg.pendingKey] then
        return ControlSync.Push(key)
    end
    if not reg.available() then return false end
    reg.pull(reg.state())
    return true
end

-- Login: pending intent wins; otherwise controls that opt in adopt the
-- counterpart's retained state once so the two stores never start diverged.
function ControlSync.ArmAtLoginIfNeeded(key)
    local reg = registrations[key]
    local db = EasyFind and EasyFind.db
    if not (reg and db) then return end
    if db[reg.pendingKey] then
        Arm(reg)
        return
    end
    if reg.reconcile then
        Utils.SafeAfter(1, function()
            if EasyFind.db and not EasyFind.db[reg.pendingKey] and reg.available() then
                reg.pull(reg.state())
            end
        end)
    end
end

function ControlSync.ArmAllAtLogin()
    for key in pairs(registrations) do
        ControlSync.ArmAtLoginIfNeeded(key)
    end
end
