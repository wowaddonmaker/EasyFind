local _, ns = ...

-- One source of truth linking each filter key to its parent filter, its
-- dynamic-provider key, and the search-category names its entries carry.
-- The query skip set (Search/Query.lua), the filter menu's bucket lookup
-- (Search/Filters/Config.lua), and the provider-to-category wiring
-- (Database/Dynamic.lua) all derive from this table; before it existed they
-- were four hand-maintained copies that had drifted.
--
-- Entry fields:
--   key          filter key in EasyFind.db.uiSearchFilters
--   parent       parent filter key whose unchecked state cascades down
--   categories   category names on this entry's search data; when the
--                filter has a dynamic provider, the provider's own category
--                comes FIRST (ProviderCategory reads it)
--   providerKey  dynamic-provider key when it differs from `key`
--   explicitFlag skip is suppressed when the query explicitly targets this
--                filter (statistics/bosses word triggers)
local ENTRIES = {
    { key = "abilities",       categories = { "Ability" } },
    { key = "talents",         categories = { "Talent", "Talents" } },
    { key = "macros",          categories = { "Macro" } },
    { key = "currencies",      categories = { "Currency" } },
    { key = "reputations",     categories = { "Reputation" } },
    { key = "achievements",    categories = { "Achievement Category", "Achievement",
                                              "Achievements", "Guild Achievements" } },
    { key = "statistics",      categories = { "Statistic", "Statistics" },
                               explicitFlag = "statistics" },
    { key = "bosses",          categories = { "Boss" }, explicitFlag = "bosses" },
    -- items is the umbrella gate; its children carry the real categories.
    { key = "items",           categories = {} },
    { key = "catalog",         parent = "items", categories = { "Item" } },
    { key = "bags",            parent = "items", categories = { "Bag" } },
    { key = "bank",            parent = "items", categories = { "Bank", "Warband" } },
    { key = "titles",          categories = { "Title" } },
    { key = "gearSets",        categories = { "Gear Set" } },
    { key = "commands",        categories = { "Command" } },
    { key = "professions",     categories = { "Profession" } },
    { key = "gameOptions",     parent = "options", categories = { "Game Settings" } },
    { key = "addonOptions",    parent = "options", categories = { "AddOn Settings" } },
    { key = "mounts",          parent = "collections", categories = { "Mount" } },
    { key = "toys",            parent = "collections", categories = { "Toy" } },
    { key = "pets",            parent = "collections", categories = { "Pet" } },
    { key = "outfits",         parent = "collections", categories = { "Outfit" } },
    { key = "heirlooms",       parent = "collections", categories = { "Heirloom" } },
    { key = "appearanceSets",  parent = "appearances", providerKey = "transmogSets",
                               categories = { "Appearance Set" } },
    { key = "appearanceItems", parent = "appearances",
                               categories = { "Appearance" } },
    { key = "loot",            categories = { "Loot" } },
    { key = "housing",         categories = { "Housing" } },
}

-- Intermediate filter keys that are themselves children of another filter.
local INTERMEDIATE_PARENT = { appearances = "collections" }

local CategoryMap = { entries = ENTRIES }
ns.CategoryMap = CategoryMap

-- providerKey -> the category name that provider's entries carry.
local ProviderCategory = {}
-- category name -> bucket filter key, for the non-collection, non-loot
-- entries the filter menu's bucket post-filter covers (collection and loot
-- entries are handled by their dedicated filters and return nil).
local BucketByCategory = {}
-- Ordered, deduplicated list of every category BuildSkipCategories can emit.
-- Search.lua derives its result-cache/narrowing key from this so the key
-- changes whenever ANY filter toggles. A hand-maintained subset silently
-- drifted (Currency, Reputation, Achievement Category, Statistics, Talents were
-- missing), so toggling those filters left the key unchanged and served a
-- stale, filtered-out result set that never restored when re-enabled.
local SkipKeyOrder = {}
local skipSeen = {}

for i = 1, #ENTRIES do
    local e = ENTRIES[i]
    ProviderCategory[e.providerKey or e.key] = e.categories[1]
    for j = 1, #e.categories do
        local cat = e.categories[j]
        if not skipSeen[cat] then
            skipSeen[cat] = true
            SkipKeyOrder[#SkipKeyOrder + 1] = cat
        end
    end
    if e.key ~= "loot" and (e.parent == nil or e.parent == "options") then
        for j = 1, #e.categories do
            BucketByCategory[e.categories[j]] = e.key
        end
    end
end
CategoryMap.SkipKeyOrder = SkipKeyOrder
-- Options entries have no dynamic provider.
ProviderCategory.gameOptions = nil
ProviderCategory.addonOptions = nil

CategoryMap.ProviderCategory = ProviderCategory
CategoryMap.BucketByCategory = BucketByCategory

local function EntryOff(filters, e)
    if filters[e.key] == false then return true end
    local parent = e.parent
    while parent do
        if filters[parent] == false then return true end
        parent = INTERMEDIATE_PARENT[parent]
    end
    return false
end

-- provider key -> its ENTRIES row, so the load-gate can resolve a provider to
-- its filter (honoring the same parent cascade EntryOff walks).
local ProviderEntry = {}
for i = 1, #ENTRIES do
    ProviderEntry[ENTRIES[i].providerKey or ENTRIES[i].key] = ENTRIES[i]
end

-- True when the provider's filter (or an ancestor filter) is unchecked in the
-- filter menu (EasyFind.db.uiSearchFilters). Database/Dynamic.lua's load-gate
-- reads this so an unchecked category never loads or indexes -- the SAME menu
-- state that hides its results live also skips its load on reload, instead of
-- the display filter only hiding results the provider already built and indexed.
function CategoryMap.IsProviderFilterOff(filters, providerKey)
    if not filters then return false end
    local e = ProviderEntry[providerKey]
    if not e then return false end
    return EntryOff(filters, e)
end

-- Fills `out` with the category names whose filters (or ancestors) are
-- unchecked; returns true when anything was skipped. Explicit query intent
-- (statistics/bosses trigger words) suppresses the matching entry's skip.
function CategoryMap.BuildSkipCategories(filters, out, explicitStatistics, explicitBosses)
    wipe(out)
    local any = false
    for i = 1, #ENTRIES do
        local e = ENTRIES[i]
        local explicit = (e.explicitFlag == "statistics" and explicitStatistics)
            or (e.explicitFlag == "bosses" and explicitBosses)
        if not explicit and EntryOff(filters, e) then
            local categories = e.categories
            for j = 1, #categories do
                out[categories[j]] = true
            end
            any = true
        end
    end
    return any
end
