local _, ns = ...

local Database = ns.Database
local Utils = ns.Utils

if not Database then return end

local dynamicProviders = {
    { key = "currencies",  category = "Currency",             fn = "PopulateDynamicCurrencies" },
    { key = "reputations", category = "Reputation",           fn = "PopulateDynamicReputations" },
    { key = "achievements", category = "Achievement Category", fn = "PopulateDynamicAchievements" },
    { key = "statistics",  category = "Statistic",            fn = "PopulateDynamicStatistics" },
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
    { key = "loot",        category = "Loot",           fn = "PopulateDynamicLoot", asyncFn = "PopulateDynamicLootAsync" },
    { key = "bosses",      category = "Boss",           fn = "PopulateDynamicBosses", asyncFn = "PopulateDynamicBossesAsync" },
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
            EasyFind:Print("|cffff4444" .. provider.key .. " search data failed: " .. tostring(err) .. "|r")
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

local function RunDynamicProvider(database, provider, onDone)
    if provider.loaded and not provider.dirty then onDone(false); return end
    local pre = provider.pre and database[provider.pre]
    if pre then pre(database) end

    local asyncFn = provider.asyncFn and database[provider.asyncFn]
    if asyncFn then
        local ok, err = xpcall(asyncFn, Utils.ErrorHandler, database, function(changed, asyncErr)
            FinishDynamicProvider(database, provider, not asyncErr, asyncErr, changed, onDone)
        end)
        if not ok then
            FinishDynamicProvider(database, provider, false, err, false, onDone)
        end
        return
    end

    local fn = database[provider.fn]
    if not fn then onDone(false); return end

    local ok, readyOrErr = xpcall(fn, Utils.ErrorHandler, database)
    if ok and readyOrErr == false then
        provider.loaded = false
        provider.dirty = true
        onDone(false)
        return
    end
    FinishDynamicProvider(database, provider, ok, readyOrErr, true, onDone)
end

function Database:CancelDynamicWarmup()
    if self.CancelDynamicScans then self:CancelDynamicScans() end
end

function Database:MarkDynamicProviderLoaded(key)
    local provider = dynamicProviderByKey[key]
    if not provider then return end
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

function Database:RefreshDynamicCategory(key)
    local provider = dynamicProviderByKey[key]
    if not provider then return false end
    provider.dirty = true
    local changed = false
    RunDynamicProvider(self, provider, function(providerChanged)
        changed = providerChanged
    end)
    return changed
end

-- LoadCoreDynamicSearchData is now a no-op stub: every provider runs on
-- its own frame via LoadDeferredSyncProvidersStaggered after PLAYER_LOGIN.
-- Spreading the cost across ~12 frames means no single frame's added
-- work is visible as a stutter, matching the pre-refactor experience.
function Database:LoadCoreDynamicSearchData()
    return false
end

-- Run every sync (non-async) provider one per frame. Each provider runs
-- in its own frame, so no single frame stacks the cost of multiple
-- collection / spell-book / EJ scans. ~12 frames (~200ms at 60fps) for
-- all sync providers to populate after login.
function Database:LoadDeferredSyncProvidersStaggered()
    -- Batch flag suppresses per-provider ResetSearchCache (which rebuilds
    -- the prefix index over the entire uiSearchData each time). Without
    -- this each of the ~12 providers triggers a full rebuild — by the
    -- end the prefix index has been rebuilt 12 times. We rebuild once
    -- at the end of the chain instead.
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
                    if C_Timer and C_Timer.After then
                        C_Timer.After(0, step)
                    else
                        step()
                    end
                end)
                return
            end
        end
        local changed = self._dynamicBatchChanged
        self._dynamicBatchLoading = false
        self._dynamicBatchChanged = false
        if changed and self.ResetSearchCache then self:ResetSearchCache() end
        -- Pre-warm the prefix index off the loaded dataset so the very
        -- first user search doesn't pay the build cost on the keystroke.
        -- Cheap if already ready; rebuilds via ResetSearchCache otherwise.
        if self.WarmSearchHotPath then self:WarmSearchHotPath() end
    end
    step()
end

-- Synchronous heavy-data load. Used at PLAYER_LOGIN so the load
-- screen absorbs the cost. Only loot (current spec) is scanned here —
-- it's small and matches a common search ("ring", "haste ring"). Boss
-- scanning iterates ~1000+ encounters across every expansion tier and
-- adds noticeable post-login CPU; bosses lazy-load on the first "boss"
-- keyword via LoadHeavyDynamicSearchData instead.
local SYNC_HEAVY_KEYS = { loot = true }
function Database:LoadHeavyDynamicSearchDataSync()
    for i = 1, #dynamicProviders do
        local provider = dynamicProviders[i]
        if provider.asyncFn and SYNC_HEAVY_KEYS[provider.key]
           and not (provider.loaded and not provider.dirty) then
            local fn = provider.fn and self[provider.fn]
            if fn then
                local pre = provider.pre and self[provider.pre]
                if pre then pre(self) end
                -- Loot scans ONLY the current spec at login (scanAllSpecs=false).
                -- Spec toggles in the loot filter dropdown trigger a lazy scan
                -- for that spec via the async path.
                local ok, err = xpcall(fn, Utils.ErrorHandler, self)
                if ok then
                    provider.loaded = true
                    provider.dirty = false
                else
                    provider.loaded = false
                    if EasyFind and EasyFind.Print then
                        EasyFind:Print("|cffff4444" .. provider.key
                            .. " sync load failed: " .. tostring(err) .. "|r")
                    end
                end
            end
        end
    end
    if self.ResetSearchCache then self:ResetSearchCache() end
    if self.WarmSearchHotPath then self:WarmSearchHotPath() end
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
                    if C_Timer and C_Timer.After then
                        C_Timer.After(0.05, step)
                    else
                        step()
                    end
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
    self:CancelDynamicWarmup()
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
