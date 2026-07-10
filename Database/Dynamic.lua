local _, ns = ...

local Database = ns.Database
local Utils = ns.Utils
local L = ns.L

-- Wall-clock cap for run-now provider steps when a live query waits.
-- Larger than the pump's idle budget (results are being watched for), but
-- bounded PER FRAME: one keystroke can request ~10 providers, each calling
-- RunDynamicProvider, so a per-call budget still stacked 10 jobs into one
-- 300-500ms frame (bench-measured). GetTime() is constant within a frame,
-- which makes it the frame stamp for the shared spend accumulator.
local URGENT_STEP_BUDGET = 0.008
local GetTime = GetTime
local dps = rawget(_G, "debugprofilestop")
local urgentFrameStamp, urgentSpentThisFrame = -1, 0

local function UrgentBudgetLeft()
    local now = GetTime and GetTime() or 0
    if now ~= urgentFrameStamp then
        urgentFrameStamp = now
        urgentSpentThisFrame = 0
    end
    return URGENT_STEP_BUDGET - urgentSpentThisFrame
end

local function AddUrgentSpend(seconds)
    urgentSpentThisFrame = urgentSpentThisFrame + (seconds or 0)
end

if not Database then return end

-- Scheduler is loaded earlier in the .toc. ns.Scheduler is the singleton
-- used by the addon at runtime. Tests can pre-populate ns.Scheduler with
-- a per-test instance before loading this file to assert deterministic
-- behavior via scheduler:Step.
local function getScheduler()
    return ns.Scheduler
end

-- eager = true providers are small enough to load up front (on search focus)
-- so they are searchable by name without the user first typing a category
-- keyword. Heavy providers (mounts/abilities/loot/appearances/...) stay lazy:
-- loading them would bloat the full-scan set and slow every keystroke, so they
-- load on query intent (a trigger word or quick filter) instead.
-- Categories come from the shared map (Shared/CategoryMap.lua) keyed by
-- provider key, so a renamed category cannot silently detach a provider
-- from the filter menu or the query skip set.
local providerCategory = ns.CategoryMap.ProviderCategory
local dynamicProviders = {
    { key = "currencies", category = providerCategory["currencies"],             fn = "PopulateDynamicCurrencies", eager = true },
    { key = "reputations", category = providerCategory["reputations"],           fn = "PopulateDynamicReputations", eager = true },
    { key = "achievements", category = providerCategory["achievements"], fn = "PopulateDynamicAchievements" },
    { key = "statistics", category = providerCategory["statistics"],            fn = "PopulateDynamicStatistics", asyncFn = "PopulateDynamicStatisticsAsync" },
    { key = "mounts", category = providerCategory["mounts"],          fn = "PopulateDynamicMounts" },
    { key = "toys", category = providerCategory["toys"],            fn = "PopulateDynamicToys" },
    { key = "housing", category = providerCategory["housing"],      asyncFn = "PopulateDynamicHousingAsync" },
    { key = "pets", category = providerCategory["pets"],            fn = "PopulateDynamicPets" },
    { key = "outfits", category = providerCategory["outfits"],         fn = "PopulateDynamicOutfits" },
    { key = "heirlooms", category = providerCategory["heirlooms"],       fn = "PopulateDynamicHeirlooms" },
    { key = "titles", category = providerCategory["titles"],          fn = "PopulateDynamicTitles", eager = true },
    { key = "gearSets", category = providerCategory["gearSets"],       fn = "PopulateDynamicGearSets", eager = true },
    { key = "macros", category = providerCategory["macros"],          fn = "PopulateDynamicMacros", eager = true },
    { key = "abilities", category = providerCategory["abilities"],        fn = "PopulateDynamicAbilities" },
    { key = "talents", category = providerCategory["talents"],         fn = "PopulateDynamicTalents" },
    { key = "bags", category = providerCategory["bags"],            fn = "PopulateDynamicBags" },
    { key = "transmogSets", category = providerCategory["transmogSets"], fn = "PopulateDynamicTransmogSets", pre = "SyncTransmogSetFiltersFromUI" },
    { key = "appearanceItems", category = providerCategory["appearanceItems"], fn = "PopulateDynamicAppearanceItems", asyncFn = "PopulateDynamicAppearanceItemsAsync", pre = "SyncAppearanceItemFiltersFromUI" },
    { key = "loot", category = providerCategory["loot"],           fn = "PopulateDynamicLoot", asyncFn = "PopulateDynamicLootAsync" },
    { key = "bosses", category = providerCategory["bosses"],           fn = "PopulateDynamicBosses", asyncFn = "PopulateDynamicBossesAsync" },
    { key = "commands", category = providerCategory["commands"],        fn = "PopulateDynamicCommands", eager = true },
}

local dynamicProviderByKey = {}
for i = 1, #dynamicProviders do
    local provider = dynamicProviders[i]
    provider.loaded = false
    provider.dirty = true
    dynamicProviderByKey[provider.key] = provider
end

-- Consume the populate bookkeeping on EVERY completion path so a stale
-- record can never leak into the next provider's completion (a leaked
-- append-only record misroutes it into NoteAppendedEntries: duplicate rows
-- and invisible new entries in a held-open query). Returns the removed
-- flag (true = entries removed, false = append-only, nil = no populate
-- ran) and the append start index.
local function ConsumePopulateBookkeeping(database)
    local removed = database._populateRemoved
    local appendFrom = database._populateAppendFrom
    database._populateRemoved, database._populateAppendFrom = nil, nil
    return removed, appendFrom
end

local function FinishDynamicProvider(database, provider, ok, err, changed, onDone)
    if err == "cancelled" then
        provider.loaded = false
        provider.dirty = true
        local removed = ConsumePopulateBookkeeping(database)
        if removed ~= nil and database.ResetSearchCache then
            database:ResetSearchCache()
        end
        onDone(false)
        return
    end
    if not ok then
        provider.loaded = false
        provider.dirty = false
        if EasyFind and EasyFind.Print then
            EasyFind:Print("|cffff4444" .. (L["ERR_SEARCH_DATA_FAILED"]):format(provider.key, tostring(err)) .. "|r")
        end
        -- The failed populate may still have wiped or grown its category
        -- before erroring; consume the bookkeeping and reset so the live
        -- search state cannot reference a half-applied dataset.
        local removed = ConsumePopulateBookkeeping(database)
        if removed ~= nil and database.ResetSearchCache then
            database:ResetSearchCache()
        end
        onDone(false)
        return
    end

    provider.loaded = true
    provider.dirty = false
    local removed, appendFrom = ConsumePopulateBookkeeping(database)
    local appendOnly = removed == false
    if changed ~= false then
        if appendOnly and appendFrom and database.NoteAppendedEntries then
            database:NoteAppendedEntries(appendFrom)
        elseif database.ResetSearchCache then
            if database._dynamicBatchLoading then
                database._dynamicBatchChanged = true
            else
                database:ResetSearchCache()
            end
        end
    end
    onDone(changed ~= false)
end

local function NotifyProviderWaiters(provider, changed)
    local waiters = provider.waiting
    provider.waiting = nil
    if waiters then
        for i = 1, #waiters do
            waiters[i](changed)
        end
    end
end

-- Per-provider job IDs are namespaced under "dynamic:" so the scheduler
-- can group-cancel them and so they don't collide with future job names.
local function jobIdForProvider(provider)
    return "dynamic:" .. provider.key
end

-- The actual work the scheduler's run() invokes. Behavior matches the
-- old RunDynamicProvider closely: pre-fn, then sync or async dispatch,
-- with FinishDynamicProvider managing loaded/dirty flags.
local function runProviderJob(database, provider, schedDone)
    local function finishWaiters(changed)
        NotifyProviderWaiters(provider, changed)
        schedDone()
    end

    -- Stamped so the dirty-mark handlers can tell a populate's own event
    -- echo from a real external change (see WasProviderRecentlyRun).
    provider.lastRunAt = GetTime()

    local pre = provider.pre and database[provider.pre]
    if pre then pre(database) end

    local asyncFn = provider.asyncFn and database[provider.asyncFn]
    if asyncFn then
        local ok, err = xpcall(asyncFn, Utils.ErrorHandler, database, function(changed, asyncErr)
            FinishDynamicProvider(database, provider, not asyncErr, asyncErr, changed, finishWaiters)
        end)
        if not ok then
            FinishDynamicProvider(database, provider, false, err, false, finishWaiters)
        end
        return
    end

    local fn = database[provider.fn]
    if not fn then
        NotifyProviderWaiters(provider, false)
        schedDone()
        return
    end

    local ok, readyOrErr = xpcall(fn, Utils.ErrorHandler, database)
    if ok and readyOrErr == false then
        provider.loaded = false
        provider.dirty = true
        -- Backoff: a not-ready provider must not repopulate on every
        -- keystroke (a legitimately empty collection is indistinguishable
        -- from un-streamed data and would otherwise retry all session).
        -- Its dirty event clears this the moment real data arrives.
        provider.notReadyAt = GetTime()
        local removed = ConsumePopulateBookkeeping(database)
        if removed ~= nil and database.ResetSearchCache then
            database:ResetSearchCache()
        end
        NotifyProviderWaiters(provider, false)
        schedDone()
        return
    end
    provider.notReadyAt = nil
    FinishDynamicProvider(database, provider, ok, readyOrErr, true, finishWaiters)
end

-- Registers all dynamic provider jobs against the active scheduler.
-- Idempotent: re-registering the same id overwrites cleanly so reloading
-- this file in tests doesn't multi-register.
local function ensureJobsRegistered(database)
    local sched = getScheduler()
    if not sched then return nil end
    if database._dynamicJobsRegistered == sched then return sched end
    database._dynamicJobsRegistered = sched
    for i = 1, #dynamicProviders do
        local provider = dynamicProviders[i]
        sched:Register(jobIdForProvider(provider), {
            cancelGroup = "dynamic",
            run = function(_, done)
                runProviderJob(database, provider, done)
            end,
        })
    end
    return sched
end

-- The ONE gate for whether a category's data may load: is its filter unchecked
-- in the filter menu? Checked inside RunDynamicProvider, the single chokepoint
-- every provider load flows through -- so the login loaders, event-driven
-- refreshes, and the pre-warm are all covered in one place, not scattered. The
-- Engine's explicit query path passes bypassGate=true, because it has already
-- honored the filter, quick-filters, and explicit intent itself before asking.
local function IsProviderLoadDisabled(provider)
    local db = EasyFind and EasyFind.db
    local filters = db and db.uiSearchFilters
    if not filters then return false end
    local map = ns.CategoryMap
    if not (map and map.IsProviderFilterOff) then return false end
    return map.IsProviderFilterOff(filters, provider.key)
end

local function RunDynamicProvider(database, provider, onDone, runNow, bypassGate)
    if provider.loaded and not provider.dirty then onDone(false); return end
    if provider.notReadyAt and (GetTime() - provider.notReadyAt) < 3.0 then
        -- Recently reported not-ready: don't repopulate per keystroke.
        -- The category's dirty event clears the stamp when data arrives.
        onDone(false)
        return
    end
    if not bypassGate and IsProviderLoadDisabled(provider) then
        -- Unchecked category on an automatic load (login warm / event refresh):
        -- skip it -- no populate, so no entries and no index weight. Left
        -- unloaded, so an explicit request or a re-check still loads it later.
        onDone(false)
        return
    end

    -- Append to waiters before enqueueing so a synchronous run that fires
    -- waiters inside its done() picks up this caller.
    provider.waiting = provider.waiting or {}
    provider.waiting[#provider.waiting + 1] = onDone

    local sched = ensureJobsRegistered(database)
    if not sched then
        -- Scheduler unavailable (very early load); fall back to immediate
        -- inline run so functionality is preserved.
        runProviderJob(database, provider, function() end)
        return
    end
    local jobId = jobIdForProvider(provider)
    -- Only Reset complete jobs; resetting a "running" async job would let
    -- a second Enqueue start the work concurrently.
    if sched:Status(jobId) == "complete" then
        sched:Reset(jobId)
    end
    sched:Enqueue(jobId)
    if runNow ~= false then
        -- Urgent but BOUNDED per frame: a query is waiting, so spend more
        -- than the pump's idle budget, but across ALL RunDynamicProvider
        -- calls this frame combined. Whatever doesn't fit runs through the
        -- OnUpdate pump over the following frames.
        local left = UrgentBudgetLeft()
        if left > 0 then
            local t0 = dps and dps() or 0
            sched:Step(0, left)
            if dps then AddUrgentSpend((dps() - t0) / 1000) end
        end
    end
end

function Database:CancelDynamicWarmup()
    if self.CancelDynamicScans then self:CancelDynamicScans(false) end
end

function Database:MarkDynamicProviderLoaded(key)
    local provider = dynamicProviderByKey[key]
    if not provider then return end
    provider.loading = false
    provider.waiting = nil
    provider.loaded = true
    provider.dirty = false
end

function Database:MarkDynamicCategoryDirty(key)
    local provider = dynamicProviderByKey[key]
    if not provider then return end
    provider.dirty = true
    provider.notReadyAt = nil
    if provider.loaded and self.ResetSearchCache then self:ResetSearchCache() end
end

function Database:IsDynamicProviderLoaded(key)
    local provider = dynamicProviderByKey[key]
    return provider and provider.loaded and not provider.dirty or false
end

-- True while a populate for this key ran within the last windowSec. The
-- event-driven dirty-markers use this to ignore the events our own
-- populates echo (journal filter pushes, header expands): without it, any
-- low-result query cycles populate -> event -> dirty -> refresh ->
-- populate forever and pins the frame rate. Known cost: a GENUINE stream
-- completion landing inside the window after a partial populate is also
-- swallowed and only heals on that category's next event.
function Database:WasProviderRecentlyRun(key, windowSec)
    local provider = dynamicProviderByKey[key]
    if not (provider and provider.lastRunAt) then return false end
    return (GetTime() - provider.lastRunAt) < (windowSec or 2.0)
end

function Database:EnsureDynamicProviderLoaded(key, onDone)
    local provider = dynamicProviderByKey[key]
    if not provider then return false end
    RunDynamicProvider(self, provider, onDone or function() end)
    return true
end

function Database:RequestDynamicProviderLoaded(key, onDone)
    local provider = dynamicProviderByKey[key]
    if not provider then return false end
    -- Explicit query request from the Engine, which already honored the filter /
    -- quick-filters / explicit intent -- so bypass the load-gate.
    RunDynamicProvider(self, provider, onDone or function() end, false, true)
    return true
end

-- Delegation, not a copy: Search:RefreshActiveSearch is the one owner of
-- "re-run the active query". A local re-implementation of it here is how
-- the autocomplete desync survived a fix aimed at the wrong twin.
local function RefreshActiveSearch()
    local search = ns.Search
    if search and search.RefreshActiveSearch then
        search:RefreshActiveSearch()
    end
end

function Database:RefreshDynamicCategory(key, onDone)
    local provider = dynamicProviderByKey[key]
    if not provider then return false end
    provider.dirty = true
    local changed = false
    local returned = false
    RunDynamicProvider(self, provider, function(providerChanged)
        changed = providerChanged
        if onDone then onDone(providerChanged) end
        if returned and providerChanged then RefreshActiveSearch() end
    end)
    returned = true
    return changed
end

-- Load the small "eager" providers up front (called on search focus) so they
-- are searchable by name without the user first typing a category keyword. One
-- per frame to avoid a single-frame hitch; already-loaded providers are skipped
-- so repeated focus is cheap. Each load fires ResetSearchCache -> the coalesced
-- active-search refresh, so results fill in on their own.
function Database:LoadEagerDynamicProviders()
    if self._loadingEagerProviders then return end
    self._loadingEagerProviders = true
    local index = 1
    local function step()
        while index <= #dynamicProviders do
            local provider = dynamicProviders[index]
            index = index + 1
            if provider.eager and not (provider.loaded and not provider.dirty) then
                RunDynamicProvider(self, provider, function()
                    Utils.SafeAfter(0, step)
                end)
                return
            end
        end
        self._loadingEagerProviders = false
    end
    -- Deferred so the load lands after the login frame (which is kept light)
    -- and after the first few frames of API data settling.
    Utils.SafeAfter(0, step)
end

function Database:LoadDeferredSyncProvidersStaggered()
    -- Suppress per-provider ResetSearchCache; rebuild the prefix index
    -- once at the end of the staggered chain.
    self._dynamicBatchLoading = true
    self._dynamicBatchChanged = false
    local index = 1
    local function step()
        while index <= #dynamicProviders do
            local provider = dynamicProviders[index]
            index = index + 1
            if not provider.asyncFn
               and not (provider.loaded and not provider.dirty) then
                RunDynamicProvider(self, provider, function()
                    Utils.SafeAfter(0, step)
                end)
                return
            end
        end
        local changed = self._dynamicBatchChanged
        self._dynamicBatchLoading = false
        self._dynamicBatchChanged = false
        if changed and self.ResetSearchCache then self:ResetSearchCache() end
        if self.WarmSearchHotPath then self:WarmSearchHotPath() end
        -- Entries the shortkeys point at may have only just loaded; rebind now.
        if ns.Shortkeys and ns.Shortkeys.ApplyAll then ns.Shortkeys:ApplyAll() end
    end
    step()
end


function Database:LoadHeavyDynamicSearchData(onDone)
    if self._loadingHeavyDynamic then return false end
    self._loadingHeavyDynamic = true

    local index = 1
    local anyChanged = false
    local function step()
        while index <= #dynamicProviders do
            local provider = dynamicProviders[index]
            index = index + 1
            if provider.asyncFn then
                RunDynamicProvider(self, provider, function(changed)
                    if changed then anyChanged = true end
                    Utils.SafeAfter(0.05, step)
                end)
                return
            end
        end
        self._loadingHeavyDynamic = false
        if onDone then onDone(anyChanged) end
    end

    step()
    return true
end

function Database:UnloadDynamicSearchData(includeCore)
    if self.CancelDynamicScans then self:CancelDynamicScans(true) end
    for i = 1, #dynamicProviders do
        local provider = dynamicProviders[i]
        if includeCore or provider.asyncFn then
            if provider.category then self:_RemoveEntriesByCategory(provider.category) end
            provider.loaded = false
            provider.dirty = true
        end
    end
    if includeCore then
        self:_ResetDynamicProviderCaches()
    elseif self._ResetHeavyProviderCaches then
        self:_ResetHeavyProviderCaches()
    end
    if self.ResetSearchCache then self:ResetSearchCache() end
end
