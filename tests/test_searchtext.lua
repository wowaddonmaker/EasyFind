-- Tests for Shared/SearchText.lua

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local SearchText = H.loadModule("Shared/SearchText.lua", env, ns)
H.assertNotNil(SearchText, "SearchText module should be returned")
H.assertEq(ns.SearchText, SearchText)

local tests = {}

function tests.normalize_lowercasesAscii()
    H.assertEq(SearchText.Normalize("Auction House"), "auction house")
end

function tests.normalize_nilSafe()
    H.assertEq(SearchText.Normalize(nil), "")
end

function tests.normalize_passthroughNonAscii()
    -- Non-ASCII characters are not modified by ASCII-safe lower.
    H.assertEq(SearchText.Normalize("Schädel"), "sch\195\164del")
end

function tests.tokenize_splitsOnSpaces()
    H.assertDeepEq(SearchText.Tokenize("auction house"), { "auction", "house" })
end

function tests.tokenize_splitsOnPunctuation()
    H.assertDeepEq(SearchText.Tokenize("crusader's-strike, etc"),
        { "crusader's", "strike", "etc" })
end

function tests.tokenize_dropsLeadingTrailingSeparators()
    H.assertDeepEq(SearchText.Tokenize("  hello  world  "),
        { "hello", "world" })
end

function tests.tokenize_emptyInput()
    H.assertDeepEq(SearchText.Tokenize(""), {})
end

function tests.tokenize_nilInput()
    H.assertDeepEq(SearchText.Tokenize(nil), {})
end

function tests.tokenize_alphanumeric()
    H.assertDeepEq(SearchText.Tokenize("level 80 paladin"),
        { "level", "80", "paladin" })
end

function tests.normalizeAndTokenize_combines()
    H.assertDeepEq(SearchText.NormalizeAndTokenize("Crusader Strike"),
        { "crusader", "strike" })
end

function tests.isAscii_trueForAsciiOnly()
    H.assertTrue(SearchText.IsAscii("hello"))
    H.assertTrue(SearchText.IsAscii("123 ABC xyz!"))
    H.assertTrue(SearchText.IsAscii(""))
end

function tests.isAscii_falseForHighBytes()
    H.assertFalse(SearchText.IsAscii("Schädel"))
    H.assertFalse(SearchText.IsAscii("\200"))
end

function tests.findContiguous_findsSubstring()
    local r = SearchText.FindContiguous("Crusader Strike", "strike")
    H.assertNotNil(r)
    H.assertEq(r.from, 10)
    H.assertEq(r.to, 15)
end

function tests.findContiguous_caseInsensitive()
    local r = SearchText.FindContiguous("Auction House", "AUCTION")
    H.assertNotNil(r)
    H.assertEq(r.from, 1)
    H.assertEq(r.to, 7)
end

function tests.findContiguous_returnsNilForMissing()
    H.assertNil(SearchText.FindContiguous("Hello world", "xyz"))
end

function tests.findContiguous_returnsNilForEmptyQuery()
    H.assertNil(SearchText.FindContiguous("anything", ""))
    H.assertNil(SearchText.FindContiguous("anything", nil))
end

function tests.condense_preservesSingleRange()
    local out = SearchText.CondenseMatchRanges("anything", { { from = 1, to = 3 } })
    H.assertEq(#out, 1)
    H.assertEq(out[1].from, 1)
    H.assertEq(out[1].to, 3)
end

function tests.condense_emptyOrNilRanges()
    H.assertDeepEq(SearchText.CondenseMatchRanges("text", {}), {})
    H.assertDeepEq(SearchText.CondenseMatchRanges("text", nil), {})
end

function tests.condense_slidesScatteredStrikeMatch()
    -- "Crusader Strike" with the query "strike" causing scattered matches
    -- on s, t, r, i, k, e from across the string. Condensation should
    -- find the right-adjacent "strike" run and merge them.
    --
    -- Crusader Strike
    -- 12345678901234567 (1-based)
    --
    -- Positions: s=4 (Cru[s]ader), t=11 (S[t]rike), r=12 ([r]), i=13 ([i]),
    --            k=14 ([k]), e=15 ([e]). Wait, checking: "Crusader Strike"
    --            indices 1-15. Letters: C(1) r(2) u(3) s(4) a(5) d(6) e(7)
    --            r(8) ' '(9) S(10) t(11) r(12) i(13) k(14) e(15).
    --
    -- The scattered match picks the FIRST occurrence of each letter:
    --   s=4, t=11, r=2, i=13, k=14, e=7, but a real matcher walks left
    --   to right so it'd be: s=4, t=11, r=12, i=13, k=14, e=15. The
    --   condenser then slides the leading s into position 10 (S in
    --   "Strike"), merging all six into one range from=10 to=15.
    local ranges = {
        { from = 4,  to = 4 },   -- s in "Crusader"
        { from = 11, to = 11 },  -- t
        { from = 12, to = 12 },  -- r
        { from = 13, to = 13 },  -- i
        { from = 14, to = 14 },  -- k
        { from = 15, to = 15 },  -- e
    }
    local text = "Crusader Strike"
    -- Lower-case the text for the byte comparison since match ranges are
    -- usually computed against the lowered form. (The condenser does
    -- exact byte comparison, so we pass lowered text.)
    local out = SearchText.CondenseMatchRanges(text:lower(), ranges)
    H.assertEq(#out, 1, "scattered matches should condense to a single range")
    H.assertEq(out[1].from, 10)
    H.assertEq(out[1].to, 15)
end

function tests.condense_leavesNonMergeableRangesAlone()
    -- Two ranges that cannot slide (different characters between them)
    -- should both survive.
    local text = "abc xyz"
    local ranges = {
        { from = 1, to = 1 },  -- 'a'
        { from = 5, to = 5 },  -- 'x'
    }
    local out = SearchText.CondenseMatchRanges(text, ranges)
    H.assertEq(#out, 2)
    H.assertEq(out[1].from, 1)
    H.assertEq(out[2].from, 5)
end

local pass, fail, failures = H.runSuite("SearchText", tests)
return { pass = pass, fail = fail, failures = failures }
