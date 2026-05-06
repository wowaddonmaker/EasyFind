local _, ns = ...

local Database = ns.Database
local Utils = ns.Utils

if not Database then return end

local dynamicProviders = {
    { key = "currencies",  category = "Currency",       fn = "PopulateDynamicCurrencies" },
    { key = "reputations", category = "Reputation",     fn = "PopulateDynamicReputations" },
    { key = "mounts",      category = "Mount",          fn = "PopulateDynamicMounts" },
    { key = "toys",        category = "Toy",            fn = "PopulateDynamicToys" },
    { key = "pets",        category = "Pet",            fn = "PopulateDynamicPets" },
    { key = "outfits",     category = "Outfit",         fn = "PopulateDynamicOutfits" },
    { key = "heirlooms",   category = "Heirloom",       fn = "PopulateDynamicHeirlooms" },
    { key = "titles",      category = "Title",          fn = "PopulateDynamicTitles" },
    { key = "gearSets",    category = "Gear Set",       fn = "PopulateDynamicGearSets" },
    { key = "macros",      category = "Macro",          fn = "PopulateDynamicMacros" },
    { key = "abilities",   category = "Ability",        fn = "PopulateDynamicAbilities" },
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

    local ok, err = xpcall(fn, Utils.ErrorHandler, database)
    FinishDynamicProvider(database, provider, ok, err, true, onDone)
end

function Database:CancelDynamicWarmup()
    if self.CancelDynamicScans then self:CancelDynamicScans() end
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

function Database:LoadCoreDynamicSearchData()
    if self._loadingCoreDynamic then return false end
    self._loadingCoreDynamic = true
    self._dynamicBatchLoading = true
    self._dynamicBatchChanged = false

    for i = 1, #dynamicProviders do
        local provider = dynamicProviders[i]
        if not provider.asyncFn then
            RunDynamicProvider(self, provider, function() end)
        end
    end

    local changed = self._dynamicBatchChanged
    self._dynamicBatchLoading = false
    self._dynamicBatchChanged = false
    self._loadingCoreDynamic = false

    if changed and self.ResetSearchCache then self:ResetSearchCache() end
    return changed
end

function Database:LoadHeavyDynamicSearchData(onDone)
    if self._loadingHeavyDynamic then return false end
    self._loadingHeavyDynamic = true

    local index = 1
    local function step()
        while index <= #dynamicProviders do
            local provider = dynamicProviders[index]
            index = index + 1
            if provider.asyncFn then
                RunDynamicProvider(self, provider, function()
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
        if onDone then onDone() end
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
