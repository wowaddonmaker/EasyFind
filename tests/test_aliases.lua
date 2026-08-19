-- Tests for Shared/Aliases.lua

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
local Aliases = H.loadModule("Shared/Aliases.lua", env, ns)

assert(Aliases, "Aliases module returned nil")
assert(ns.Aliases == Aliases, "ns.Aliases not set to module")

-- Minimal stand-in for Database:ScoreName mirroring the real tiers AND the
-- real fuzzy gates: single-edit tolerance only at 5+ char queries, with the
-- name's length inside the edit window (FUZZY_EDIT1_LEN = 5).
local function editDistance1(a, b)
    local la, lb = #a, #b
    if la == lb then
        local diff, swap = 0, false
        for i = 1, la do
            if a:sub(i, i) ~= b:sub(i, i) then
                diff = diff + 1
                if diff == 2 and a:sub(i - 1, i) == b:sub(i, i) .. b:sub(i - 1, i - 1) then
                    swap = true
                end
            end
        end
        return diff == 1 or (diff == 2 and swap)
    end
    if lb - la ~= 1 and la - lb ~= 1 then return false end
    local long, short = a, b
    if lb > la then long, short = b, a end
    local skipped = false
    local si = 1
    for li = 1, #long do
        if long:sub(li, li) == short:sub(si, si) then
            si = si + 1
        elseif skipped then
            return false
        else
            skipped = true
        end
    end
    return true
end

ns.Database.ScoreName = function(_, nameLower, query, queryLen)
    if nameLower == query then return 1000 end
    if string.find(nameLower, query, 1, true) == 1 then return 500 end
    if string.find(nameLower, query, 1, true) then return 30 end
    local nameLen = #nameLower
    if queryLen >= 5 and nameLen >= queryLen - 1 and nameLen <= queryLen + 1
       and editDistance1(nameLower, query) then
        return 10
    end
    return 0
end

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

function tests.getMatches_typoTolerantLikeNormalSearch()
    -- Aliases score through the shared name scorer, so they inherit its
    -- real tolerance: prefixes always, single-edit typos only at 5+ char
    -- queries with the alias length inside the edit window. A short alias
    -- ("gar") gets no typo tier, exactly like a 3-letter result name.
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    Aliases:Add("vault", toyEntry)
    for _, q in ipairs({ "vault", "vaul", "vualt" }) do
        local matches = Aliases:GetMatches(q)
        H.assertNotNil(matches, "expected match for query '" .. q .. "'")
        H.assertEq(matches[1].data, toyEntry)
    end
    Aliases:Remove("vault")
    Aliases:Add("gar", toyEntry)
    H.assertNotNil(Aliases:GetMatches("gar"))
    H.assertNil(Aliases:GetMatches("garr"), "4-char query gets no typo tier on a 3-char alias")
    H.assertNil(Aliases:GetMatches("garrison"), "past scorer tolerance the alias drops")
    ns.Database.uiSearchData = nil
end

function tests.getMatches_exactAliasOutranksPartial()
    -- Aliases "gar" and "gart", query "gar": the exact alias must come
    -- first regardless of hash order or the target entries' names.
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "A Name Sorting Earlier" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    Aliases:Add("gar", toyEntry)
    Aliases:Add("gart", mountEntry)
    local matches = Aliases:GetMatches("gar")
    H.assertNotNil(matches, "expected matches")
    H.assertEq(#matches, 2)
    H.assertEq(matches[1].data, toyEntry, "exact alias must rank first")
    H.assertEq(matches[2].data, mountEntry)
    -- At "gart" only the exact alias fires: a 4-char query is below the
    -- scorer's typo threshold, so the "gar" alias scores zero, the same as
    -- a 3-letter result name would for that query.
    local matches2 = Aliases:GetMatches("gart")
    H.assertEq(#matches2, 1)
    H.assertEq(matches2[1].data, mountEntry, "exact alias must rank first at 'gart'")
    ns.Database.uiSearchData = nil
end

function tests.getMatches_gibberishAfterAliasDropsBoost()
    -- Aliases match through the shared name scorer, so junk typed past an
    -- alias scores zero and must not keep any alias pinned on top.
    env.EasyFind.db.aliases = {}
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "Grand Gryphon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    Aliases:Add("gar", toyEntry)
    Aliases:Add("gart", mountEntry)
    H.assertNil(Aliases:GetMatches("gartasdfasdfhuasdf"), "gibberish must drop all boosts")
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

function tests.categoryAlias_storesAndResolvesMarker()
    -- GitHub #21: a category alias binds a trigger to a whole map category.
    -- GetMatches resolves it to a marker (no single row exists to look up);
    -- the query pipeline expands the marker into nearby category rows.
    env.EasyFind.db.aliases = {}
    H.assertTrue(Aliases:AddCategory("fm", "flightmaster", "Flight Master (category)"))
    H.assertEq(env.EasyFind.db.aliases["fm"].key, "mapcat:flightmaster")
    local matches = Aliases:GetMatches("fm")
    H.assertNotNil(matches, "trigger must match")
    H.assertEq(matches[1].data.mapCategoryAlias, "flightmaster")
    H.assertEq(matches[1].data.name, "Flight Master (category)")
    H.assertEq(matches[1].alias.text, "fm")
    H.assertNil(Aliases:GetMatches("f"), "1-char non-exact query stays gated")
end

function tests.categoryAlias_rejectsEmpty()
    env.EasyFind.db.aliases = {}
    H.assertFalse(Aliases:AddCategory("  ", "flightmaster"), "empty trigger rejected")
    H.assertFalse(Aliases:AddCategory("fm", nil), "missing category rejected")
    H.assertNil(next(env.EasyFind.db.aliases))
end

function tests.learned_recordAndBoost()
    env.EasyFind.db.aliases = {}
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = true
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    ns.Learned:RecordPick(toyEntry, "gar")
    local rec = env.EasyFind.db.queryLearn["gar"]
    H.assertNotNil(rec, "pick was not recorded")
    H.assertEq(rec.key, "toy:110560")
    H.assertEq(ns.Learned:GetBoost("gar"), toyEntry)
    H.assertEq(ns.Learned:GetBoost("garr"), toyEntry, "typed-past query keeps the pick")
    ns.Database.uiSearchData = nil
end

function tests.learned_lastPickWins()
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = true
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "Grand Gryphon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    ns.Learned:RecordPick(toyEntry, "gar")
    ns.Learned:RecordPick(mountEntry, "gar")
    H.assertEq(ns.Learned:GetBoost("gar"), mountEntry, "last pick must win")
    ns.Database.uiSearchData = nil
end

function tests.learned_disabledOptionStopsBoth()
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = false
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    ns.Learned:RecordPick(toyEntry, "gar")
    H.assertNil(next(env.EasyFind.db.queryLearn), "must not record while disabled")
    env.EasyFind.db.queryLearn = { gar = { key = "toy:110560", n = 1, at = 1 } }
    H.assertNil(ns.Learned:GetBoost("gar"), "must not boost while disabled")
    env.EasyFind.db.learnFromPicks = true
    ns.Database.uiSearchData = nil
end

function tests.learned_capEvictsOldest()
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = true
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry }
    local store = env.EasyFind.db.queryLearn
    -- Pre-fill to the cap with picks older than "now" (the fake clock sits
    -- at 0), q1 oldest, so the new pick evicts exactly q1.
    for i = 1, 200 do
        store["q" .. i] = { key = "toy:110560", n = 1, at = i - 300 }
    end
    ns.Learned:RecordPick(toyEntry, "newest")
    local count = 0
    for _ in pairs(store) do count = count + 1 end
    H.assertEq(count, 200, "cap must hold at 200")
    H.assertNil(store["q1"], "oldest entry must be evicted")
    H.assertNotNil(store["newest"], "new pick must survive the trim")
    ns.Database.uiSearchData = nil
end

function tests.getMatches_nilQueryReturnsNil()
    H.assertNil(Aliases:GetMatches(nil))
    H.assertNil(Aliases:GetMatches(""))
end


function tests.learned_prefixFallback()
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = true
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "Grand Gryphon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    ns.Learned:RecordPick(toyEntry, "glad mount")
    H.assertEq(ns.Learned:GetBoost("glad mo"), toyEntry, "shorter typing must still surface the pick")
    H.assertEq(ns.Learned:GetBoost("glad"), toyEntry, "4 chars is enough for the fallback")
    H.assertEq(ns.Learned:GetBoost("glad mounts"), toyEntry, "typing past must still surface the pick")
    H.assertNil(ns.Learned:GetBoost("gl"), "short fragments stay natural, no habit hijack")
    H.assertNil(ns.Learned:GetBoost("gla"), "3 chars is still below the fallback floor")
    H.assertNil(ns.Learned:GetBoost("g"), "1-char queries stay exact-only")
    -- A SHORT query the user explicitly taught is a different case from the
    -- fallback: exact records are honored at any length.
    ns.Learned:RecordPick(mountEntry, "gl")
    H.assertEq(ns.Learned:GetBoost("gl"), mountEntry, "explicit 2-char pick must still learn and boost")
    H.assertEq(ns.Learned:GetBoost("gla"), mountEntry, "extending an explicit short record boosts it")
    -- Exact beats prefix: a different pick learned under the short form wins there.
    ns.Learned:RecordPick(mountEntry, "glad mo")
    H.assertEq(ns.Learned:GetBoost("glad mo"), mountEntry, "exact record must beat prefix fallback")
    H.assertEq(ns.Learned:GetBoost("glad mount"), toyEntry, "longer exact record unaffected")
    ns.Database.uiSearchData = nil
end

function tests.learned_prefixPrefersLongestQuery()
    env.EasyFind.db.queryLearn = {}
    env.EasyFind.db.learnFromPicks = true
    local toyEntry = { toyItemID = 110560, name = "Garrison Hearthstone" }
    local mountEntry = { mountID = 71, name = "Grand Gryphon" }
    Aliases:InvalidateKeyIndex()
    ns.Database.uiSearchData = { toyEntry, mountEntry }
    ns.Learned:RecordPick(mountEntry, "glad")
    ns.Learned:RecordPick(toyEntry, "glad mount")
    H.assertEq(ns.Learned:GetBoost("glad mo"), toyEntry, "longest learned query must win")
    ns.Database.uiSearchData = nil
end

local pass, fail, failures = H.runSuite("Aliases", tests)
return { pass = pass, fail = fail, failures = failures }
