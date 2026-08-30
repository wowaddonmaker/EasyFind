-- Tests for Database/SearchIndex.lua: compressed posting lists, serial
-- keys, liveness on removal, incremental append. The class guarantees
-- (candidates are a SUPERSET of everything the scorers can award points
-- to) are asserted against a naive reference scan on a synthetic corpus.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- Synthetic corpus: enough entries to force several tail freezes
-- (FREEZE_AT = 64) so both the packed-string and pending-tail read paths
-- are exercised.
local corpus = {}
local WORDS = { "shadow", "bolt", "mount", "swift", "gladiator", "drake",
    "storm", "wind", "rider", "battle", "standard", "honor", "guild",
    "bank", "portal", "master", "training", "dummy", "arena", "vault" }
local function addEntry(name, keywords)
    corpus[#corpus + 1] = {
        name = name, nameLower = name:lower(),
        keywordsLower = keywords, category = "Test",
    }
end
for i = 1, #WORDS do
    for j = 1, #WORDS do
        if i ~= j then
            addEntry(WORDS[i] .. " " .. WORDS[j])
        end
    end
end
addEntry("lonely unique zephyr")
addEntry("sacrificial kumquat target")
corpus[#corpus + 1] = { name = "loot thing", nameLower = "loot thing", lootEntry = true }

ns.Database = { uiSearchData = corpus }
H.loadModule("Database/SearchIndex.lua", env, ns)
local SearchIndex = ns.SearchIndex

local tests = {}

local function candidateSet(queryWords)
    local cand, n = SearchIndex:Candidates(queryWords)
    local set = {}
    if cand then
        for i = 1, n do set[cand[i]] = true end
    end
    return set, n or 0
end

function tests.candidates_supersetOfSubstringMatches()
    for _, w in ipairs({ "shadow", "glad", "adiat", "vault" }) do
        local set = candidateSet({ w })
        for i = 1, #corpus do
            local e = corpus[i]
            if e.nameLower:find(w, 1, true) then
                H.assertTrue(set[e], "missing substring match for '" .. w .. "': " .. e.nameLower)
            end
        end
    end
end

function tests.candidates_lootAlwaysIncluded()
    local set = candidateSet({ "zephyr" })
    H.assertTrue(set[corpus[#corpus]], "loot entry must always be a candidate")
end

function tests.candidates_orderIsAppendOrder()
    local cand, n = SearchIndex:Candidates({ "shadow" })
    H.assertTrue(n > 1)
    local lastPos = 0
    local posOf = {}
    for i = 1, #corpus do posOf[corpus[i]] = i end
    for i = 1, n do
        local p = posOf[cand[i]]
        H.assertTrue(p and p > lastPos, "candidates must come out in append order")
        lastPos = p
    end
end

function tests.removal_dropsCandidateWithoutRebuild()
    -- Dedicated sacrificial entry so removal cannot perturb other tests
    -- (suite order is not guaranteed).
    local victim
    for i = 1, #corpus do
        if corpus[i].nameLower:find("kumquat", 1, true) then victim = corpus[i] break end
    end
    H.assertTrue(victim ~= nil)
    local before = candidateSet({ "kumquat" })
    H.assertTrue(before[victim], "victim must be a candidate before removal")
    SearchIndex:NoteRemoved(victim)
    local set = candidateSet({ "kumquat" })
    H.assertTrue(not set[victim], "removed entry must not be a candidate")
    -- Unrelated entries with other words are untouched.
    local swift = candidateSet({ "swift" })
    local swiftCount = 0
    for e in pairs(swift) do
        if e.nameLower and e.nameLower:find("swift", 1, true) then swiftCount = swiftCount + 1 end
    end
    H.assertTrue(swiftCount > 10, "unrelated candidates must survive a removal")
end

function tests.append_isIncremental()
    local newEntry = { name = "brand new xylophone", nameLower = "brand new xylophone", category = "Test" }
    corpus[#corpus + 1] = newEntry
    local set = candidateSet({ "xylophone" })
    H.assertTrue(set[newEntry], "appended entry must become a candidate without a rebuild")
end

function tests.postings_areCompressed()
    local peek = SearchIndex:_DebugPeek()
    local strBytes, tailSlots, buckets = 0, 0, 0
    for _, map in ipairs({ peek.gramStr, peek.wordStr, peek.initStr }) do
        for _, s in pairs(map) do
            buckets = buckets + 1
            strBytes = strBytes + #s
        end
    end
    for _, map in ipairs({ peek.gramTail, peek.wordTail, peek.initTail }) do
        for _, t in pairs(map) do tailSlots = tailSlots + #t end
    end
    H.assertTrue(strBytes > 0, "no postings froze to strings; corpus too small for the test")
    -- 3 bytes per packed posting; the equivalent Lua array slot costs ~17.
    -- The synthetic corpus is small, so tails legitimately hold a share;
    -- the claim under test is that freezing HAPPENS and carries real
    -- volume, not the production ratio.
    local packedPostings = strBytes / 3
    H.assertTrue(packedPostings > 100,
        "expected substantial packed postings, got " .. packedPostings)
    H.assertTrue(tailSlots > 0, "tail path should also be exercised")
end

local pass, fail, failures = H.runSuite("SearchIndex", tests)
return { pass = pass, fail = fail, failures = failures }
