-- Tests for Database/TeleportData.lua: dungeon-teleport keyword derivation.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- ONE journal stub for the whole file (tests must never swap it: the
-- module's name cache is shared state across the randomized suite).
-- Court of Stars resolves localized; Mists counts calls for the caching
-- test; everything else fails.
local mistsCalls = 0
env.EJ_GetInstanceInfo = function(instanceID)
    if instanceID == 800 then return "Hof der Sterne" end
    if instanceID == 1184 then
        mistsCalls = mistsCalls + 1
        return "Mists of Tirna Scithe"
    end
    error("no journal data")
end

H.loadModule("Database/TeleportData.lua", env, ns)

local tests = {}

function tests.mapping_hasCourtOfStars()
    local entry = ns.DUNGEON_TELEPORT_SPELLS[393766]
    H.assertNotNil(entry, "Court of Stars teleport mapped")
    H.assertEq(entry.ej, 800)
end

local function keywordSet(spellID)
    local kw = { "path of the fallen guardian", "ability", "abilities" }
    ns.AppendDungeonTeleportKeywords(kw, spellID)
    local set = {}
    for i = 1, #kw do set[kw[i]] = true end
    return set, kw
end

function tests.keywords_localizedAndEnglishAndAbbrev()
    local set = keywordSet(393766)
    H.assertTrue(set["hof der sterne"], "localized journal name appended")
    H.assertTrue(set["court of stars"], "english fallback appended")
    H.assertTrue(set["cos"], "abbreviation appended")
    H.assertTrue(set["teleport"] and set["tp"] and set["keystone"], "shared terms appended")
end

function tests.keywords_journalFailureFallsBackToEnglish()
    -- Plaguefall: the stubbed journal errors for its ID.
    local set = keywordSet(354463)
    H.assertTrue(set["plaguefall"], "english name still appended")
    H.assertTrue(set["pf"], "abbreviation appended")
end

function tests.keywords_unmappedSpellNoOp()
    local kw = { "fireball" }
    local hit = ns.AppendDungeonTeleportKeywords(kw, 133)
    H.assertEq(#kw, 1, "unmapped spell must not grow keywords")
    H.assertEq(hit, false, "unmapped spell reports no hit")
end

function tests.append_reportsTeleportHit()
    local kw = {}
    H.assertEq(ns.AppendDungeonTeleportKeywords(kw, 354463), true,
        "mapped teleport reports hit (drives the score bonus)")
end

function tests.triggers_containDungeonWordsNotStopwords()
    local t = ns.DUNGEON_TELEPORT_TRIGGERS
    H.assertTrue(t.plaguefall and t.mots and t.boralus, "dungeon words trigger")
    H.assertTrue(t.teleport and t.keystone, "shared terms trigger")
    H.assertTrue(not t.the and not t.of, "stopwords never trigger")
    H.assertTrue(not t.nw and not t.pf, "2-char abbreviations stay off triggers")
end

function tests.keywords_journalNameCached()
    -- Own entry (Mists, 354464): the resolvedNames cache is module state
    -- shared across the randomized suite, so no other test may touch it.
    keywordSet(354464)
    keywordSet(354464)
    H.assertTrue(mistsCalls <= 1, "journal lookups are cached per entry")
end

local pass, fail, failures = H.runSuite("TeleportData", tests)
return { pass = pass, fail = fail, failures = failures }
