-- Tests for Shared/Aliases.lua

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
local Aliases = H.loadModule("Shared/Aliases.lua", env, ns)

assert(Aliases, "Aliases module returned nil")
assert(ns.Aliases == Aliases, "ns.Aliases not set to module")

local tests = {}

function tests.entryKey_forMount()
    local key = Aliases:GetEntryKey({ mountID = 123 })
    H.assertEq(key, "mount:123")
end

function tests.entryKey_forToy()
    local key = Aliases:GetEntryKey({ toyItemID = 4567 })
    H.assertEq(key, "toy:4567")
end

function tests.entryKey_forPet()
    H.assertEq(Aliases:GetEntryKey({ petID = "abc" }), "pet:abc")
end

function tests.entryKey_forOutfit()
    H.assertEq(Aliases:GetEntryKey({ outfitID = 9 }), "outfit:9")
end

function tests.entryKey_forAppearanceSet()
    H.assertEq(Aliases:GetEntryKey({ transmogSetID = 100 }), "appearanceSet:100")
end

function tests.entryKey_forMacro()
    H.assertEq(Aliases:GetEntryKey({ macroIndex = 5 }), "macro:5")
end

function tests.entryKey_forReputation()
    H.assertEq(Aliases:GetEntryKey({ factionID = 42 }), "reputation:42")
end

function tests.entryKey_forLootItem()
    H.assertEq(Aliases:GetEntryKey({ itemID = 1000, category = "Loot" }), "loot:1000")
    -- itemID without Loot category should not match the loot branch
    H.assertEq(Aliases:GetEntryKey({ itemID = 1000, category = "Gear" }), nil)
end

function tests.entryKey_forCurrency()
    local data = { category = "Currency", steps = { { currencyID = 7 } } }
    H.assertEq(Aliases:GetEntryKey(data), "currency:7")
end

function tests.entryKey_forCurrency_walksSteps()
    local data = {
        category = "Currency",
        steps = { { someOther = true }, { currencyID = 42 } },
    }
    H.assertEq(Aliases:GetEntryKey(data), "currency:42")
end

function tests.entryKey_forUIPath()
    local data = { path = { "Character", "Inventory" }, name = "Bag" }
    H.assertEq(Aliases:GetEntryKey(data), "ui:Character>Inventory>Bag")
end

function tests.entryKey_forUINameOnly()
    H.assertEq(Aliases:GetEntryKey({ name = "Auction House" }), "ui:Auction House")
end

function tests.entryKey_returnsNilForEmpty()
    H.assertEq(Aliases:GetEntryKey(nil), nil)
    H.assertEq(Aliases:GetEntryKey({}), nil)
end

function tests.add_storesAliasWithKey()
    env.EasyFind.db.aliases = {}
    Aliases:Add("mt", { mountID = 555, name = "Faerie Dragon" })
    local stored = env.EasyFind.db.aliases["mt"]
    H.assertNotNil(stored, "alias was not stored")
    H.assertEq(stored.key, "mount:555")
    H.assertEq(stored.text, "mt")
end

function tests.getMatches_resolvesAgainstUiSearchData()
    env.EasyFind.db.aliases = {}
    -- Populate uiSearchData so FindEntryByKey resolves the alias.
    local mountEntry = { mountID = 555, name = "Faerie Dragon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { mountEntry, { mountID = 999, name = "Other" } }
    Aliases:Add("mt", mountEntry)
    local matches = Aliases:GetMatches("mt")
    H.assertNotNil(matches, "expected matches for 'mt'")
    H.assertEq(#matches, 1)
    H.assertEq(matches[1].data, mountEntry)
    H.assertEq(matches[1].alias.text, "mt")
    ns.Database.uiSearchData = nil
end

function tests.getMatches_queryExtendingPastAliasStillMatches()
    -- GitHub #20: alias "gar", user keeps typing "garr...", "garrison".
    -- The query no longer fits inside the alias text but starts with it,
    -- so the boost must survive.
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    Aliases:Add("gar", toyEntry)
    for _, q in ipairs({ "gar", "garr", "garrison", "garrison hearth" }) do
        local matches = Aliases:GetMatches(q)
        H.assertNotNil(matches, "expected match for query '" .. q .. "'")
        H.assertEq(matches[1].data, toyEntry)
    end
    ns.Database.uiSearchData = nil
end

function tests.getMatches_oneCharQueryOnlyExactAlias()
    -- The contains direction honours the search's 2-char minimum: one
    -- keystroke must not surface every alias sharing that letter. A
    -- deliberate 1-char alias still fires exactly.
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "Gryphon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    Aliases:Add("gar", toyEntry)
    Aliases:Add("g", mountEntry)
    local matches = Aliases:GetMatches("g")
    H.assertNotNil(matches, "exact 1-char alias must fire")
    H.assertEq(#matches, 1)
    H.assertEq(matches[1].data, mountEntry)
    ns.Database.uiSearchData = nil
end

function tests.getMatches_aliasMidQueryDoesNotMatch()
    -- The longer-query direction is prefix-only: an alias buried in the
    -- middle of what the user typed is not "typing the alias".
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    Aliases:Add("gar", toyEntry)
    H.assertNil(Aliases:GetMatches("the gar"), "mid-query alias must not match")
    ns.Database.uiSearchData = nil
end

function tests.getMatches_returnsNilWhenAliasEntryMissing()
    env.EasyFind.db.aliases = {}
    Aliases:Add("ghost", { mountID = 12345, name = "Removed Mount" })
    -- No uiSearchData and mount snapshot is not stored; FindEntryByKey
    -- cannot resolve, so GetMatches returns nil rather than an empty list.
    local matches = Aliases:GetMatches("ghost")
    H.assertNil(matches, "expected nil when entry cannot be resolved")
end

function tests.add_normalizesAliasText()
    env.EasyFind.db.aliases = {}
    Aliases:Add("  MyAlias  ", { mountID = 1 })
    H.assertNotNil(env.EasyFind.db.aliases["myalias"], "trimmed+lowered key not found")
end

function tests.add_rejectsEmpty()
    env.EasyFind.db.aliases = {}
    H.assertFalse(Aliases:Add("   ", { mountID = 1 }), "empty alias should be rejected")
end

function tests.add_rejectsUnkeyableData()
    env.EasyFind.db.aliases = {}
    H.assertFalse(Aliases:Add("foo", {}), "data with no key should be rejected")
end

function tests.remove_clearsAlias()
    env.EasyFind.db.aliases = { foo = { text = "foo", key = "mount:1" } }
    Aliases:Remove("foo")
    H.assertNil(env.EasyFind.db.aliases["foo"], "alias should have been removed")
end

function tests.remove_normalizesArg()
    env.EasyFind.db.aliases = { foo = { text = "foo", key = "mount:1" } }
    Aliases:Remove("  FOO  ")
    H.assertNil(env.EasyFind.db.aliases["foo"], "alias should be removed despite case/whitespace")
end

function tests.clearAll_emptiesAliases()
    env.EasyFind.db.aliases = { a = { key = "x" }, b = { key = "y" } }
    Aliases:ClearAll()
    local count = 0
    for _ in pairs(env.EasyFind.db.aliases) do count = count + 1 end
    H.assertEq(count, 0, "aliases table should be empty after ClearAll")
end

function tests.forEach_visitsEachAlias()
    env.EasyFind.db.aliases = {
        ["foo"] = { text = "foo", key = "mount:1" },
        ["bar"] = { text = "bar", key = "toy:2" },
    }
    local seen = {}
    Aliases:ForEach(function(text, info)
        seen[text] = info.key
    end)
    H.assertEq(seen.foo, "mount:1")
    H.assertEq(seen.bar, "toy:2")
end

function tests.getMatches_nilQueryReturnsNil()
    H.assertNil(Aliases:GetMatches(nil))
    H.assertNil(Aliases:GetMatches(""))
end

local pass, fail, failures = H.runSuite("Aliases", tests)
return { pass = pass, fail = fail, failures = failures }
