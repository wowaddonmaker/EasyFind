-- Tests for Apps/Icons/IconSearch.lua (the @icons grid data layer) against the
-- real generated blob.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
-- The whole module ships as the EasyFind_Icons companion, which reads
-- the parent addon's ns via the EasyFind._ns handshake.
env.EasyFind._ns = ns
H.loadModule("Apps/Icons/Data.lua", env, ns)
local IconSearch = H.loadModule("Apps/Icons/IconSearch.lua", env, ns)

local tests = {}
local scratch = {}

function tests.index_buildsFromBlob()
    local total = IconSearch:GetTotal()
    H.assertTrue(total > 30000, "index suspiciously small")
    local name, id = IconSearch:GetIcon(1)
    H.assertEq(type(name), "string")
    H.assertEq(type(id), "number")
end

function tests.filter_emptyQueryIsEverything()
    local n = IconSearch:Filter("", scratch)
    H.assertEq(n, IconSearch:GetTotal())
end

function tests.filter_findsKnownIcon()
    local n = IconSearch:Filter("inv_sword_04", scratch)
    H.assertTrue(n >= 1, "known icon must match")
    local found
    for i = 1, n do
        local name, id = IconSearch:GetIcon(scratch[i])
        if name == "inv_sword_04" then found = id end
    end
    H.assertEq(found, 135274)
end

function tests.filter_pluralSweepsSingular()
    -- GitHub #22 review: "swords" must sweep the _sword_ family even though
    -- icon file names are singular.
    local plural = IconSearch:Filter("swords", scratch)
    H.assertTrue(plural > 50, "plural query must sweep the family, got " .. plural)
    local singular = IconSearch:Filter("sword", scratch)
    H.assertTrue(singular >= plural, "singular is the wider set")
end

function tests.filter_multiWordIsAnd()
    local n = IconSearch:Filter("inv sword", scratch)
    H.assertTrue(n > 0)
    for i = 1, n do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(name:find("inv", 1, true) and name:find("sword", 1, true),
            "every match carries both words: " .. name)
    end
end

function tests.filter_garbageFindsNothing()
    H.assertEq(IconSearch:Filter("zzqxjv_no_such_icon", scratch), 0)
end

function tests.filter_minusExcludes()
    local all = IconSearch:Filter("sword", scratch)
    local kept = IconSearch:Filter("sword -inv", scratch)
    H.assertTrue(kept > 0 and kept < all, "exclusion must remove the inv_ swords")
    for i = 1, kept do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(not name:find("inv", 1, true), "excluded term leaked: " .. name)
    end
end

function tests.filter_slashAlternates()
    local swords = IconSearch:Filter("inv_sword_", scratch)
    local axes = IconSearch:Filter("inv_axe_", scratch)
    local both = IconSearch:Filter("inv_sword_/inv_axe_", scratch)
    H.assertEq(both, swords + axes)
end

function tests.filter_commaBranches()
    local swords = IconSearch:Filter("inv_sword_", scratch)
    local axes = IconSearch:Filter("inv_axe_", scratch)
    H.assertEq(IconSearch:Filter("inv_sword_, inv_axe_", scratch), swords + axes)
end

function tests.filter_wildcardWord()
    local n = IconSearch:Filter("inv_sword_*", scratch)
    H.assertTrue(n > 5, "wildcard must sweep the sword files, got " .. n)
    for i = 1, n do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(name:match("^inv_sword_") ~= nil, "wildcard miss: " .. name)
    end
    -- ? = exactly one character
    local q = IconSearch:Filter("inv_sword_0?", scratch)
    H.assertTrue(q > 0 and q <= n)
end

function tests.filter_bareNumberIsFileDataID()
    local n = IconSearch:Filter("135274", scratch)
    H.assertTrue(n >= 1)
    local name, id = IconSearch:GetIcon(scratch[1])
    H.assertEq(id, 135274)
    H.assertEq(name, "inv_sword_04")
end

function tests.filter_idPrefixNarrows()
    -- Typing digits sweeps every FileDataID starting with them, and each
    -- further digit narrows the sweep (never widens it).
    local n13 = IconSearch:Filter("#13", scratch)
    local n135 = IconSearch:Filter("#135", scratch)
    local n1352 = IconSearch:Filter("#1352", scratch)
    H.assertTrue(n13 > n135 and n135 > n1352 and n1352 >= 1,
        ("expected narrowing, got %d -> %d -> %d"):format(n13, n135, n1352))
    for i = 1, n1352 do
        local _, id = IconSearch:GetIcon(scratch[i])
        H.assertTrue(tostring(id):sub(1, 4) == "1352", "non-prefix id: " .. id)
    end
end

function tests.filter_hashExactListsFirst()
    local n = IconSearch:Filter("#135274", scratch)
    H.assertTrue(n >= 1)
    local _, id = IconSearch:GetIcon(scratch[1])
    H.assertEq(id, 135274)
    -- spell:/item:/achievement: need live APIs; absent here they degrade to 0
    H.assertEq(IconSearch:Filter("spell:133", scratch), 0)
end

local pass, fail, failures = H.runSuite("IconSearch", tests)
return { pass = pass, fail = fail, failures = failures }
