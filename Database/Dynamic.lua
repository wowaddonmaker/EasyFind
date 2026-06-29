local _, ns = ...

local Database = ns.Database
local Utils = ns.Utils
local L = ns.L

if not Database then return end

-- Scheduler is loaded earlier in the .toc. ns.Scheduler is the singleton
-- used by the addon at runtime. Tests can pre-populate ns.Scheduler with
-- a per-test instance before loading this file to assert deterministic
-- behavior via scheduler:Step.
local function getScheduler()
    return ns.Scheduler
end

local dynamicProviders = {
    { key = "currencies",  category = "Currency",             fn = "PopulateDynamicCurrencies" },
    { key = "reputations", category = "Reputation",           fn = "PopulateDynamicReputations" },
    { key = "achievements", category = "Achievement Category", fn = "PopulateDynamicAchievements" },
    { key = "statistics",  category = "Statistic",            fn = "PopulateDynamicStatistics", asyncFn = "PopulateDynamicStatisticsAsync" },
    { key = "mounts",      category = "Mount",          fn = "PopulateDynamicMounts" },
    { key = "toys",        category = "Toy",            fn = "PopulateDynamicToys" },
    { key = "pets",        category = "Pet",            fn = "PopulateDynamicPets" },
    { key = "outfits",     category = "Outfit",         fn = "PopulateDynamicOutfits" },
    { key = "heirlooms",   category = "Heirloom",       fn = "PopulateDynamicHeirlooms" },
    { key = "titles",      category = "Title",          fn = "PopulateDynamicTitles" },
    { key = "gearSets",    category = "Gear Set",       fn = "PopulateDynamicGearSets" },
    { key = "macros",      category = "Macro",          fn = "PopulateDynamicMacros" },
    { key = "abilities",   category = "Ability",        fn = "PopulateDynamicAbilities" },
    { key = "talents",     category = "Talent",         fn = "PopulateDynamicTalents" },
    { key = "bags",        category = "Bag",            fn = "PopulateDynamicBags" },
    { key = "transmogSets", category = "Appearance Set", fn = "PopulateDynamicTransmogSets", pre = "SyncTransmogSetFiltersFromUI" },
    { key = "appearanceItems", category = "Appearance", fn = "PopulateDynamicAppearanceItems", asyncFn = "PopulateDynamicAppearanceItemsAsync", pre = "SyncAppearanceItemFiltersFromUI" },
    { key = "loot",        category = "Loot",           fn = "PopulateDynamicLoot", asyncFn = "PopulateDynamicLootAsync" },
    { key = "bosses",      category = "Boss",           fn = "PopulateDynamicBosses", asyncFn = "PopulateDynamicBossesAsync" },
    { key = "commands",    category = "Command",        fn = "PopulateDynamicCommands" },
}

local dynamicProviderByKey = {}
for i = 1, #dynamicProviders do
    local provider = dynamicProviders[i]
    provider.loaded = false
    provider.dirty = true
    dynamicProviderByKey[provider.key] = provider
end

local function FinishDynamicProvider(database, provider, ok, err, changed, onDone)
    if err == "cancelled" then
        provider.loaded = false
        provider.dirty = true
        onDone(false)
        return
    end
    if not ok then
        provider.loaded = false
        provider.dirty = false
        if EasyFind and EasyFind.Print then
            EasyFind:Print("|cffff4444" .. (L["ERR_SEARCH_DATA_FAILED"]):format(provider.key, tostring(err)) .. "|r")
        end
        onDone(false)
        return
    end

    provider.loaded = true
    provider.dirty = false
    if changed ~= false and database.ResetSearchCache then
        if database._dynamicBatchLoading then
            database._dynamicBatchChanged = true
        else
            database:ResetSearchCache()
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
        NotifyProviderWaiters(provider, false)
        schedDone()
        return
    end
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

local function RunDynamicProvider(database, provider, onDone, runNow)
    if provider.loaded and not provider.dirty then onDone(false); return end

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
        sched:Step(0)
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
    if provider.loaded and self.ResetSearchCache then self:ResetSearchCache() end
end

function Database:IsDynamicProviderLoaded(key)
    local provider = dynamicProviderByKey[key]
    return provider and provider.loaded and not provider.dirty or false
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
    RunDynamicProvider(self, provider, onDone or function() end, false)
    return true
end

local function RefreshActiveSearch()
    local search = ns.Search
    local frame = search and search.GetSearchFrame and search:GetSearchFrame()
    local editBox = frame and frame.editBox
    if editBox and frame:IsShown() and search.OnSearchTextChanged then
        search:OnSearchTextChanged(editBox:GetText() or "", true)
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

function Database:LoadCoreDynamicSearchData()
    return false
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
