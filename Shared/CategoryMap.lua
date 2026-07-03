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
    { key = "bags",            categories = { "Bag" } },
    { key = "titles",          categories = { "Title" } },
    { key = "gearSets",        categories = { "Gear Set" } },
    { key = "commands",        categories = { "Command" } },
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

for i = 1, #ENTRIES do
    local e = ENTRIES[i]
    ProviderCategory[e.providerKey or e.key] = e.categories[1]
    if e.key ~= "loot" and (e.parent == nil or e.parent == "options") then
        for j = 1, #e.categories do
            BucketByCategory[e.categories[j]] = e.key
        end
    end
end
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
