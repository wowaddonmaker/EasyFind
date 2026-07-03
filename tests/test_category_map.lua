local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/CategoryMap.lua", env, ns)
local CategoryMap = ns.CategoryMap

local tests = {}

function tests.everyCategoryBelongsToExactlyOneFilter()
    local ownerByCategory = {}
    for _, e in ipairs(CategoryMap.entries) do
        for _, cat in ipairs(e.categories) do
            H.assertEq(ownerByCategory[cat], nil,
                "category '" .. cat .. "' claimed by two filters")
            ownerByCategory[cat] = e.key
        end
    end
end

function tests.providerCategoriesResolve()
    H.assertEq(CategoryMap.ProviderCategory.mounts, "Mount")
    H.assertEq(CategoryMap.ProviderCategory.transmogSets, "Appearance Set",
        "the appearanceSets filter maps to the transmogSets provider")
    H.assertEq(CategoryMap.ProviderCategory.achievements, "Achievement Category",
        "the provider category must come first in the entry's list")
    H.assertEq(CategoryMap.ProviderCategory.gameOptions, nil,
        "options entries have no dynamic provider")
end

function tests.bucketsExcludeDedicatedFilterEntries()
    H.assertEq(CategoryMap.BucketByCategory["Ability"], "abilities")
    H.assertEq(CategoryMap.BucketByCategory["Game Settings"], "gameOptions")
    H.assertEq(CategoryMap.BucketByCategory["Mount"], nil,
        "collection entries are handled by their dedicated filters")
    H.assertEq(CategoryMap.BucketByCategory["Appearance Set"], nil)
    H.assertEq(CategoryMap.BucketByCategory["Loot"], nil)
end

function tests.parentCascadeSkipsDescendants()
    local out = {}
    local any = CategoryMap.BuildSkipCategories({ collections = false }, out)
    H.assertEq(any, true)
    H.assertEq(out["Mount"], true)
    H.assertEq(out["Appearance Set"], true,
        "appearances chains to collections, so its children skip too")
    H.assertEq(out["Bag"], nil, "unrelated filters stay visible")
end

function tests.midChainParentSkipsOnlyItsSubtree()
    local out = {}
    CategoryMap.BuildSkipCategories({ appearances = false }, out)
    H.assertEq(out["Appearance"], true)
    H.assertEq(out["Appearance Set"], true)
    H.assertEq(out["Mount"], nil)
end

function tests.explicitIntentSuppressesSkip()
    local out = {}
    local any = CategoryMap.BuildSkipCategories({ statistics = false }, out, true, false)
    H.assertEq(out["Statistic"], nil,
        "an explicit statistics query overrides the unchecked filter")
    H.assertEq(any, false)
    CategoryMap.BuildSkipCategories({ statistics = false }, out, false, false)
    H.assertEq(out["Statistic"], true)
    H.assertEq(out["Statistics"], true)
end

function tests.noFiltersOffMeansNothingSkipped()
    local out = { Stale = true }
    local any = CategoryMap.BuildSkipCategories({}, out)
    H.assertEq(any, false)
    H.assertEq(next(out), nil, "the out table is wiped even when nothing skips")
end

local pass, fail, failures = H.runSuite("CategoryMap", tests)
return { pass = pass, fail = fail, failures = failures }
