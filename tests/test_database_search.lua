-- Tests for Database/Search.lua's pure-logic scoring helpers.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- Database/Search.lua expects ns.Database to be truthy and exposes
-- IsLootStatSearchWord on it. Stub the dependency before loading.
ns.Database.uiSearchData = {}
ns.Database.IsLootStatSearchWord = function() return false end
ns.Database.IsLootSlotSearchWord = function() return false end

H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.assertNotNil(Database, "Database/Search.lua must return Database table")
H.assertEq(Database, ns.Database)

local tests = {}

function tests.keywordTiers_beatTypoNameMatches()
    local kws = { "brackenhide", "bh" }
    local words = { "brackenhide" }
    H.assertEq(Database:ScoreKeywords(kws, "brackenhide", 11, words), 100, "exact long keyword")
    H.assertEq(Database:ScoreKeywords(kws, "brack", 5, { "brack" }), 90, "five-letter prefix")
    H.assertEq(Database:ScoreKeywords(kws, "bra", 3, { "bra" }), 70, "short prefix")
    H.assertEq(Database:ScoreKeywords(kws, "bh", 2, { "bh" }), 140, "short exact abbreviation")
    -- A one-typo name match scores 85: below the exact and long-prefix tiers.
    H.assertEq(Database:ScoreFuzzy("black rat", "brack", 5), 85, "typo name match")
end

function tests.queryAsksFor_exactAndPrefixWords()
    local ask = { "teleport", "tp", "portal", "dungeon" }
    H.assertTrue(Database.QueryAsksFor({ "kara", "teleport" }, ask), "exact word")
    H.assertTrue(Database.QueryAsksFor({ "tp", "bran" }, ask), "two-letter exact")
    H.assertTrue(Database.QueryAsksFor({ "tele", "kara" }, ask), "prefix of teleport")
    H.assertFalse(Database.QueryAsksFor({ "kara" }, ask), "bare nickname")
    H.assertFalse(Database.QueryAsksFor({ "te" }, ask), "two letters do not prefix")
    H.assertFalse(Database.QueryAsksFor(nil, ask), "nil words")
end

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
    -- "inn" in "instance" hits positions 1, 2, 6; span 6 > queryLen*2-1 = 5.
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

-- SearchUI gating for Statistic / Achievement Category entries: without an
-- "ach"/"stat" query word only strong name matches surface -- exact, prefix,
-- whole-query word boundary, or every query word exact/prefix on a distinct
-- name word. Keyword, fuzzy, and contains matches stay gated.
local statEntry = {
    name = "Average gold earned per day",
    nameLower = "average gold earned per day",
    category = "Statistic",
    keywordsLower = { "economy" },
}

local function withEntries(entries, fn)
    local data = Database.uiSearchData
    for i = 1, #entries do data[i] = entries[i] end
    Database:ResetSearchCache()
    fn()
    for i = #data, 1, -1 do data[i] = nil end
    Database:ResetSearchCache()
end

local function findsEntry(results, entry)
    for i = 1, #results do
        if results[i].data == entry then return true end
    end
    return false
end

function tests.scoreName_multiWordAnyOrderMatchesStatName()
    local score = Database:ScoreName("average gold earned per day",
        "gold per day", #"gold per day", { "gold", "per", "day" })
    H.assertTrue(score >= 90, "all-words name match should score >= 90, got " .. score)
end

function tests.searchUI_gatedStatMatchesMultiWordName()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold per day"), statEntry),
            "multi-word all-name match should pass the ach gate")
    end)
end

function tests.searchUI_gatedStatMatchesWordBoundary()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold"), statEntry),
            "word-boundary match should pass the ach gate")
    end)
end

function tests.searchUI_gatedStatSurvivesIncrementalTyping()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold"), statEntry), "step: gold")
        H.assertTrue(findsEntry(Database:SearchUI("gold p"), statEntry), "step: gold p")
        H.assertTrue(findsEntry(Database:SearchUI("gold per"), statEntry), "step: gold per")
        H.assertTrue(findsEntry(Database:SearchUI("gold per day"), statEntry), "step: gold per day")
    end)
end

function tests.searchUI_gatedKeywordsStayGated()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("economy"), statEntry),
            "keyword match must not pass the ach gate")
    end)
end

function tests.searchUI_statWordStillUnlocksKeywords()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("stat economy"), statEntry),
            "a typed stat word should unlock keyword scoring")
    end)
end

function tests.searchUI_gatedRejectsTypoWord()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("golf per day"), statEntry),
            "a typo'd word must not pass the gate even among exact words")
    end)
end

function tests.searchUI_gatedRejectsContainsOnlyWord()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("old per day"), statEntry),
            "a mid-word substring must not pass the gate")
    end)
end

-- Query words are cut like name words: punctuation in the typed text must
-- not turn a word into one no name has. Loot rows match word by word and
-- were vanishing at the colon of "pattern:"; a typo in one word of a
-- bracketed name found nothing.
local lootPattern = {
    name = "Pattern: Sunfire Sash", nameLower = "pattern: sunfire sash",
    category = "Loot", lootEntry = true,
}
local bracketed = {
    name = "Raids (Journal)", nameLower = "raids (journal)",
    category = "Adventure Guide", keywordsLower = { "journal" },
}

function tests.searchUI_lootRowSurvivesPunctuationInQuery()
    withEntries({ lootPattern }, function()
        for _, q in ipairs({ "pattern", "pattern:", "pattern: s", "pattern: sunfire" }) do
            Database:ResetSearchCache()
            H.assertTrue(findsEntry(Database:SearchUI(q), lootPattern), "loot row must match: " .. q)
        end
    end)
end

function tests.searchUI_typoInOneWordOfBracketedName()
    withEntries({ bracketed }, function()
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("radis (journal)"), bracketed),
            "one transposition in the first word must still find the bracketed name")
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("raids (jour"), bracketed),
            "a bracketed prefix must match")
    end)
end

local pass, fail, failures = H.runSuite("Database/Search", tests)
return { pass = pass, fail = fail, failures = failures }
