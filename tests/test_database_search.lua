-- Tests for Database/Search.lua's pure-logic scoring helpers.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- Database/Search.lua expects ns.Database to be truthy and exposes
-- IsLootStatSearchWord on it. Stub the dependency before loading.
ns.Database.uiSearchData = {}
ns.Database.IsLootStatSearchWord = function() return false end

H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.assertNotNil(Database, "Database/Search.lua must return Database table")
H.assertEq(Database, ns.Database)

local tests = {}

function tests.normalize_passthroughForSimple()
    H.assertEq(Database:NormalizeSearchQuery("mount"), "mount")
end

function tests.normalize_rewritesTmogToTransmog()
    H.assertEq(Database:NormalizeSearchQuery("tmog"), "transmog")
end

function tests.normalize_rewritesXmogToTransmog()
    H.assertEq(Database:NormalizeSearchQuery("xmog"), "transmog")
end

function tests.normalize_handlesEmptyString()
    H.assertEq(Database:NormalizeSearchQuery(""), "")
end

function tests.normalize_handlesNil()
    H.assertEq(Database:NormalizeSearchQuery(nil), nil)
end

function tests.findAtWordBoundary_atStart()
    H.assertTrue(Database:FindAtWordBoundary("auction house", "auction"))
end

function tests.findAtWordBoundary_afterSpace()
    H.assertTrue(Database:FindAtWordBoundary("auction house", "house"))
end

function tests.findAtWordBoundary_afterHyphen()
    H.assertTrue(Database:FindAtWordBoundary("auction-house", "house"))
end

function tests.findAtWordBoundary_afterColon()
    H.assertTrue(Database:FindAtWordBoundary("group:bosses", "bosses"))
end

function tests.findAtWordBoundary_rejectsMidWord()
    H.assertFalse(Database:FindAtWordBoundary("aaaXbbb", "X"))
end

function tests.findAtWordBoundary_falseForMissing()
    H.assertFalse(Database:FindAtWordBoundary("hello world", "xyz"))
end

function tests.couldMatch_emptyQueryAlwaysMatches()
    H.assertTrue(Database:CouldMatch("anything", ""))
end

function tests.couldMatch_emptyTextRejectsNonEmpty()
    H.assertFalse(Database:CouldMatch("", "x"))
end

function tests.couldMatch_acceptsContainedChars()
    H.assertTrue(Database:CouldMatch("hello world", "lwh"))
end

function tests.couldMatch_rejectsMissingChars()
    H.assertFalse(Database:CouldMatch("hello", "xyz"))
end

function tests.couldMatch_spacesArePermissive()
    -- Space (byte 32) is treated as a wildcard in the prefilter
    H.assertTrue(Database:CouldMatch("hello", " "))
end

function tests.scoreInitials_pureInitialsHit()
    -- "rbg" -> "Rated BattleGround" (3-word, 3-char query). Score >= 130.
    local score = Database:ScoreInitials("rated battleground game", "rbg")
    H.assertTrue(score >= 130, "expected initials score >= 130, got " .. tostring(score))
end

function tests.scoreInitials_unrelatedReturnsZero()
    -- A query that shares no initials must score 0.
    H.assertEq(Database:ScoreInitials("hello world", "zz"), 0)
end

function tests.damerauLevenshtein_identical()
    H.assertEq(Database:DamerauLevenshtein("abc", "abc", 3, 3), 0)
end

function tests.damerauLevenshtein_oneSubstitution()
    H.assertEq(Database:DamerauLevenshtein("abc", "abd", 3, 3), 1)
end

function tests.damerauLevenshtein_oneTransposition()
    -- "ab" <-> "ba" is one transposition in Damerau-Levenshtein.
    H.assertEq(Database:DamerauLevenshtein("ab", "ba", 2, 2), 1)
end

function tests.damerauLevenshtein_capsLargeDifferences()
    -- Function caps at 3 once distance >= 3 to avoid wasted work.
    local d = Database:DamerauLevenshtein("abcdef", "zyxwvu", 6, 6)
    H.assertTrue(d >= 3, "expected capped distance, got " .. tostring(d))
end

function tests.isSubsequence_basicHit()
    -- "tr" in "transmog": consecutive, sparsity check passes.
    H.assertTrue(Database:IsSubsequence("transmog", "tr", 2))
end

function tests.isSubsequence_firstCharMustMatch()
    H.assertFalse(Database:IsSubsequence("transmog", "rm", 2))
end

function tests.isSubsequence_rejectsSparse()
    -- "inn" in "instance" hits positions 1, 2, 6 — span 6 > queryLen*2-1 = 5.
    H.assertFalse(Database:IsSubsequence("instance", "inn", 3))
end

function tests.scoreName_exactMatchScoresHighest()
    -- Assert the tier ordering, not the tuned constant: exact beats prefix.
    local exact = Database:ScoreName("mounts", "mounts", 6)
    local prefix = Database:ScoreName("mountains", "mount", 5)
    H.assertTrue(exact > prefix,
        "exact match should outscore a prefix match; got "
        .. tostring(exact) .. " vs " .. tostring(prefix))
end

function tests.scoreName_prefixScoresAbovePartial()
    local prefix = Database:ScoreName("auction house", "auction", 7)
    local partial = Database:ScoreName("auction house", "ction", 5)
    H.assertTrue(prefix > partial,
        "prefix should score higher than mid-string substring; got "
        .. tostring(prefix) .. " vs " .. tostring(partial))
end

function tests.scoreName_emptyText()
    H.assertEq(Database:ScoreName("", "anything", 8), 0)
end

function tests.scoreName_multiWordSettingNameCanSkipMiddleWord()
    local words = { "enemy", "nameplate" }
    local score = Database:ScoreName("enemy unit nameplate", "enemy nameplate", 15, words)
    H.assertTrue(score >= 100,
        "enemy nameplate should match Enemy Unit Nameplate without typing Unit; got "
        .. tostring(score))
end

function tests.warmSearchHotPath_warmsCachedAsyncProvidersThroughGate()
    -- The pre-warm now routes loot/statistics/bosses through the same load
    -- chokepoint (EnsureDynamicProviderLoaded -> RunDynamicProvider) that the
    -- filter gate lives on, instead of calling HydrateCached* directly.
    local warmed = {}
    Database.EnsureDynamicProviderLoaded = function(_, key)
        warmed[key] = (warmed[key] or 0) + 1
        return true
    end

    Database:WarmSearchHotPath()

    H.assertEq(warmed["loot"], 1, "loot cache should warm during warmup")
    H.assertEq(warmed["statistics"], 1, "statistics cache should warm during warmup")
    H.assertEq(warmed["bosses"], 1, "boss cache should warm during warmup")
end

local pass, fail, failures = H.runSuite("Database/Search", tests)
return { pass = pass, fail = fail, failures = failures }
