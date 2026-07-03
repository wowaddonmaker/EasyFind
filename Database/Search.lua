local _, ns = ...

---@class SearchResult
---@field data table the underlying entry (mount/toy/UI node/etc.)
---@field score number ranking score, higher is better
---@field isAlias boolean? true when this row was resolved from a saved alias

local Database = ns.Database
local Utils = ns.Utils
local SearchText = ns.SearchText

if not Database then return end

local tsort = Utils.tsort
local sfind, ssub = Utils.sfind, Utils.ssub
local sgsub = string.gsub
local sbyte = string.byte
local tconcat = table.concat

-- All search-side casing flows through SearchText.Normalize so non-ASCII
-- (German umlauts, French accents, etc.) lowercase correctly. WoW's
-- string.lower is ASCII-only and would leave "ÜBERMACHT" partially
-- uppercase. Normalize is ASCII-fast-path internally for the common case.
local slower = SearchText.Normalize
local stokenize = SearchText.Tokenize
local isAscii = SearchText.IsAscii
local mmin, mmax, mabs, mfloor = Utils.mmin, Utils.mmax, Utils.mabs, Utils.mfloor
local pairs = Utils.pairs
local wipe = wipe
local uiSearchData = Database.uiSearchData

local function IsLootStatSearchWord(word)
    return Database:IsLootStatSearchWord(word)
end

local BOSS_QUERY_WORDS = ns.BOSS_QUERY_WORDS
local STAT_QUERY_WORDS = ns.STAT_QUERY_WORDS

-- Unbounded string-keyed word cache. The previous FIFO-256 design
-- thrashed for scoring: a single keystroke scoring 5000+ entries
-- triggered ~25,000 GetWords calls, evicting and re-allocating most
-- tables and producing 3-5 MB of transient garbage per keystroke.
-- The working set is bounded by unique strings in the dataset
-- (~7000 names + keywords + a handful of live queries) so the cache
-- self-limits at ~700 KB and never thrashes once filled.
local wordCache = {}
Database._wordCache = wordCache
local EMPTY_WORDS = {}

-- ASCII path uses gmatch which is fast and well-tested; non-ASCII routes
-- through SearchText.Tokenize so "Übermacht" splits at the right places
-- (the %w pattern only matches ASCII alphanumerics).
local function GetWords(str)
    if not str or str == "" then return EMPTY_WORDS end
    local cached = wordCache[str]
    if cached then return cached end
    local words
    if isAscii(str) then
        words = {}
        for w in str:gmatch("[%w']+") do
            words[#words + 1] = w
        end
    else
        words = stokenize(str)
    end
    wordCache[str] = words
    return words
end

local SEARCH_WORD_SYNONYMS = {
    tmog = "transmog",
    xmog = "transmog",
}

---Rewrites recognized search-word synonyms (tmog/xmog -> transmog) so
---matching is consistent regardless of which form the user typed.
---@param query string?
---@return string?
function Database:NormalizeSearchQuery(query)
    if not query or query == "" then return query end
    return (sgsub(query, "%f[%w](%w+)%f[%W]", SEARCH_WORD_SYNONYMS))
end

local dlPrev2, dlPrev, dlCurr = {}, {}, {}

local scoreNameUsedWords = {}

local function scoreDescending(a, b) return a.score > b.score end

-- Suppresses fuzzy/initials matches between word pairs that are close in
-- edit distance but semantically opposite.
local FUZZY_BLOCKLIST = {
    ["pvp"] = { ["pve"] = true },
    ["pve"] = { ["pvp"] = true },
    -- "ability"/"abilities" are keywords on every Ability entry; without
    -- this, typing "agility" drags every ability into results.
    ["agility"]   = { ["ability"] = true, ["abilities"] = true },
    ["ability"]   = { ["agility"] = true },
    ["abilities"] = { ["agility"] = true },
}

-- Initials Strategy 2 may step over these for free ("lfg" = Looking For
-- Group, "tot" = Throne of Thunder). Hitting a non-stopword content word
-- without matching breaks the chain so accidental letter alignment doesn't
-- score (e.g. "sound" wrongly hitting "Shurrai, Atrocity of the Undersea").
local INITIALS_STOPWORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["or"] = true, ["in"] = true, ["on"] = true,
    ["at"] = true, ["by"] = true, ["for"] = true, ["to"] = true,
    ["with"] = true, ["from"] = true,
}

---True if `query` appears in `text` at the start or after a word
---separator (space, hyphen, paren, colon, slash, period).
---@param text string
---@param query string
---@return boolean
function Database:FindAtWordBoundary(text, query)
    local found = sfind(text, query, 1, true)
    if not found then return false end
    if found == 1 then return true end
    -- 32=space 45=- 40=( 58=: 47=/ 46=.
    while found do
        local prev = sbyte(text, found - 1)
        if prev == 32 or prev == 45 or prev == 40
           or prev == 58 or prev == 47 or prev == 46 then
            return true
        end
        found = sfind(text, query, found + 1, true)
    end
    return false
end

function Database:ScoreInitials(text, query)
    local words = GetWords(text)
    if #words < 2 then return 0 end

    local blocked = FUZZY_BLOCKLIST[query]
    if blocked then
        for wi = 1, #words do
            if blocked[words[wi]] then return 0 end
        end
    end

    local queryLen = #query
    local numWords = #words

    -- Strategy 1: pure initials. "rb" -> R(ated) B(attlegrounds).
    if queryLen <= numWords then
        local allMatch = true
        for i = 1, queryLen do
            if sbyte(query, i) ~= sbyte(words[i], 1) then
                allMatch = false
                break
            end
        end
        if allMatch then
            local bonus = (queryLen == numWords) and 135 or 130
            return bonus
        end
    end

    -- Strategy 2: greedy word-prefix walk. "raba" -> ra(ndom) ba(ttleground).
    -- Stopwords may be skipped (so "tot" -> Throne Of Thunder works).
    local qi = 1
    local wordsMatched = 0
    for wi = 1, numWords do
        if qi > queryLen then break end
        local w = words[wi]
        local matchLen = 0
        while qi + matchLen <= queryLen and matchLen < #w do
            if sbyte(query, qi + matchLen) == sbyte(w, matchLen + 1) then
                matchLen = matchLen + 1
            else
                break
            end
        end
        if matchLen > 0 then
            qi = qi + matchLen
            wordsMatched = wordsMatched + 1
        elseif wordsMatched > 0 and not INITIALS_STOPWORDS[w] then
            break
        end
    end
    if qi > queryLen and wordsMatched >= 2 then
        return 110 + mmin(wordsMatched * 3, 20)
    end

    return 0
end

function Database:ScoreFuzzy(text, query, queryLen)
    -- Length-scaled typo budget (1 edit per ~4 chars). Without this,
    -- "skull" fuzzy-matches "spell" and similar unrelated 40%-diff words.
    local maxEdits
    if queryLen >= 8 then maxEdits = 2
    elseif queryLen >= 4 then maxEdits = 1
    else return 0
    end

    local queryFirst = sbyte(query, 1)
    local bestScore = 0
    local blocked = FUZZY_BLOCKLIST[query]
    local textWords = GetWords(text)
    for wi = 1, #textWords do
        local word = textWords[wi]
        -- First-letter must match: typos rarely hit the first char.
        if sbyte(word, 1) == queryFirst
           and not (blocked and blocked[word]) then
            local wordLen = #word
            local lenDiff = wordLen - queryLen
            if lenDiff < 0 then lenDiff = -lenDiff end
            if lenDiff <= maxEdits then
                local dist = Database:DamerauLevenshtein(query, word, queryLen, wordLen)
                if dist == 1 and maxEdits >= 1 then
                    bestScore = mmax(bestScore, 85)
                elseif dist == 2 and maxEdits >= 2 then
                    bestScore = mmax(bestScore, 45)
                end
            end
        end
    end
    return bestScore
end

-- First-char constraint avoids spurious hits like "ahn'" in "magtheridon's".
function Database:IsSubsequence(word, query, queryLen)
    if sbyte(word, 1) ~= sbyte(query, 1) then return false end
    local wi = 1
    local wordLen = #word
    local firstPos
    for qi = 1, queryLen do
        local qc = sbyte(query, qi)
        local found = false
        while wi <= wordLen do
            if sbyte(word, wi) == qc then
                if not firstPos then firstPos = wi end
                wi = wi + 1
                found = true
                break
            end
            wi = wi + 1
        end
        if not found then return false end
    end
    -- Reject sparse matches: "inn" in "instance" hits i(1)n(2)n(6), span 6 > 5.
    return (wi - 1) - firstPos + 1 <= queryLen * 2 - 1
end

-- Damerau-Levenshtein with transpositions, capped at 2.
function Database:DamerauLevenshtein(s1, s2, len1, len2)
    if mabs(len1 - len2) > 2 then return 3 end

    local prev2, prev, curr = dlPrev2, dlPrev, dlCurr

    for j = 0, len2 do prev[j] = j end

    for i = 1, len1 do
        curr[0] = i
        local minInRow = i
        local c1 = sbyte(s1, i)
        local c1Prev = i > 1 and sbyte(s1, i - 1) or nil
        for j = 1, len2 do
            local c2 = sbyte(s2, j)
            local cost = (c1 == c2) and 0 or 1
            curr[j] = mmin(
                prev[j] + 1,
                curr[j - 1] + 1,
                prev[j - 1] + cost
            )
            if i > 1 and j > 1
                and c1 == sbyte(s2, j - 1)
                and c1Prev == c2 then
                curr[j] = mmin(curr[j], prev2[j - 2] + cost)
            end
            if curr[j] < minInRow then minInRow = curr[j] end
        end
        if minInRow > 2 then return 3 end
        prev2, prev, curr = prev, curr, prev2
    end
    return prev[len2]
end

-- Fast pre-filter: every distinct char in query must appear somewhere in text.
local reuseCouldMatchSet = {}
function Database:CouldMatch(text, query)
    local tlen, qlen = #text, #query
    if qlen == 0 then return true end
    if tlen == 0 then return false end
    local seen = reuseCouldMatchSet
    for k in pairs(seen) do seen[k] = nil end
    for i = 1, tlen do
        seen[text:byte(i)] = true
    end
    for i = 1, qlen do
        local qb = query:byte(i)
        if qb ~= 32 and not seen[qb] then
            return false
        end
    end
    return true
end

-- exact -> starts-with -> word-boundary -> substring -> initials -> fuzzy.
function Database:ScoreName(nameLower, query, queryLen, optQueryWords)
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    if not Database:CouldMatch(nameLower, query) then return 0 end

    local score = 0

    if nameLower == query then
        score = 200
    elseif sfind(nameLower, query, 1, true) == 1 then
        score = 150
    elseif Database:FindAtWordBoundary(nameLower, query) then
        score = 120
    elseif sfind(nameLower, query, 1, true) then
        score = 30
    end

    if score < 130 then
        local initScore = Database:ScoreInitials(nameLower, query)
        if initScore > score then score = initScore end
    end

    if score < 100 and queryLen >= 4 then
        local fuzzyScore = Database:ScoreFuzzy(nameLower, query, queryLen)
        if fuzzyScore > score then score = fuzzyScore end
    end

    -- Vowel-stripped abbreviations: "qtr" -> quartermaster, "windrnr" -> windrunner.
    if score < 50 and queryLen >= 3 and not sfind(query, " ", 1, true) then
        local nameWords = GetWords(nameLower)
        for wi = 1, #nameWords do
            local word = nameWords[wi]
            local wordLen = #word
            if queryLen <= 4 then
                if wordLen >= queryLen * 2 and Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 55)
                    break
                end
            elseif queryLen <= 8 and wordLen > queryLen and queryLen / wordLen >= 0.6 then
                if Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 60)
                    break
                end
            end
        end
    end

    -- Multi-word query: all words must match. Fires even after an inferior
    -- low-score path so "estern kingd" -> "Eastern Kingdoms" can still surface.
    if score < 100 and sfind(query, " ", 1, true) and optQueryWords then
        local queryWords = optQueryWords
        if #queryWords >= 2 then
            local nameWords = GetWords(nameLower)
            local allMatched = true
            local totalWordScore = 0
            wipe(scoreNameUsedWords)
            local usedNameWords = scoreNameUsedWords
            for qwi = 1, #queryWords do
                local qw = queryWords[qwi]
                local qwLen = #qw
                local bestWordScore = 0
                local bestIdx = 0
                for ni = 1, #nameWords do
                    if not usedNameWords[ni] then
                        local nw = nameWords[ni]
                        local ws = 0
                        if nw == qw then
                            ws = 100
                        elseif sfind(nw, qw, 1, true) == 1 then
                            ws = 90
                        elseif sfind(nw, qw, 1, true) then
                            ws = 50
                        elseif qwLen >= 4 and sbyte(nw, 1) == sbyte(qw, 1) then
                            local nwLen = #nw
                            local maxEdits = qwLen >= 8 and 2 or 1
                            if nwLen >= qwLen - maxEdits and nwLen <= qwLen + maxEdits then
                                local dist = Database:DamerauLevenshtein(qw, nw, qwLen, nwLen)
                                if dist == 1 then
                                    ws = 75
                                elseif dist == 2 and maxEdits >= 2 then
                                    ws = 40
                                end
                            end
                            if ws == 0 and qwLen <= 8 and nwLen > qwLen and qwLen / nwLen >= 0.6 then
                                if Database:IsSubsequence(nw, qw, qwLen) then
                                    ws = 45
                                end
                            end
                        elseif qwLen == 3 then
                            local nwLen = #nw
                            if nwLen >= qwLen * 2 and Database:IsSubsequence(nw, qw, qwLen) then
                                ws = 45
                            end
                        end
                        if ws > bestWordScore then
                            bestWordScore = ws
                            bestIdx = ni
                        end
                    end
                end
                if bestWordScore > 0 then
                    usedNameWords[bestIdx] = true
                    totalWordScore = totalWordScore + bestWordScore
                else
                    allMatched = false
                    break
                end
            end
            if allMatched then
                local avgScore = totalWordScore / #queryWords
                local wordScore = mmin(110, avgScore)
                if wordScore > score then score = wordScore end
            end
        end
    end

    return score
end

function Database:ScoreKeywords(keywordsLower, query, queryLen, optQueryWords)
    if not keywordsLower then return 0 end

    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    local queryWords = optQueryWords
    if not queryWords then return 0 end

    -- Single-word: take BEST kw match, not sum. Summing let items with
    -- redundant keywords ("reputation" + "reputation achievements") beat
    -- items with a better name match.
    local numKeywords = #keywordsLower
    if #queryWords == 1 then
        local best = 0
        for ki = 1, numKeywords do
            local kw = keywordsLower[ki]
            local kwScore = 0
            if kw == query then
                -- Short abbreviations (2-3 chars) get boosted above initials.
                kwScore = queryLen <= 3 and 140 or 80
            elseif sfind(kw, query, 1, true) == 1 then
                kwScore = 70
            elseif Database:FindAtWordBoundary(kw, query) then
                kwScore = 55
            end
            if kwScore < 60 and queryLen >= 3 then
                local initScore = Database:ScoreInitials(kw, query)
                if initScore > 0 then
                    local penalty = queryLen == 3 and 70 or 20
                    kwScore = mmax(kwScore, initScore - penalty)
                end
            end
            if kwScore < 40 and queryLen >= 4 then
                local kf = Database:ScoreFuzzy(kw, query, queryLen)
                if kf > 0 then kwScore = mmax(kwScore, kf) end
            end
            if kwScore < 50 and queryLen >= 3 then
                local kwWords = GetWords(kw)
                for kwi = 1, #kwWords do
                    local kwWord = kwWords[kwi]
                    local kwWordLen = #kwWord
                    if queryLen <= 4 and kwWordLen >= queryLen * 2 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 60)
                            break
                        end
                    elseif queryLen <= 8 and kwWordLen > queryLen and queryLen / kwWordLen >= 0.6 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 55)
                            break
                        end
                    end
                end
            end
            if kwScore > best then best = kwScore end
        end
        return best
    end

    -- Multi-word: all words >= 2 chars must match. Single-char words are
    -- SKIPPED (not failed) so mid-type queries like "feral a" don't empty
    -- prevCandidates and silently kill the next "feral abil" extension.
    local total = 0
    for qwi = 1, #queryWords do
        local queryWord = queryWords[qwi]
        local queryWordLen = #queryWord
        local bestScore = 0

        if queryWordLen >= 2 then
            for ki = 1, numKeywords do
                local kw = keywordsLower[ki]
                local kwScore = 0
                if kw == queryWord then
                    kwScore = 80
                elseif sfind(kw, queryWord, 1, true) == 1 then
                    kwScore = 70
                elseif Database:FindAtWordBoundary(kw, queryWord) then
                    kwScore = 55
                end
                if kwScore < 60 and queryWordLen >= 3 then
                    local initScore = Database:ScoreInitials(kw, queryWord)
                    if initScore > 0 then
                        local penalty = queryWordLen == 3 and 70 or 20
                        kwScore = mmax(kwScore, initScore - penalty)
                    end
                end
                if kwScore < 40 and queryWordLen >= 4 then
                    local kf = Database:ScoreFuzzy(kw, queryWord, queryWordLen)
                    if kf > 0 then kwScore = mmax(kwScore, kf) end
                end

                if kwScore > bestScore then
                    bestScore = kwScore
                end
            end
            if bestScore == 0 then
                return 0
            end
            total = total + bestScore
        end
    end

    return total
end

-- When the user extends the previous query (e.g. "mou" -> "moun"), only
-- re-score entries that matched before instead of the full dataset.
local function ScoreSingleFieldWord(fieldWord, queryWord, queryWordLen)
    if fieldWord == queryWord then return 100 end
    if sfind(fieldWord, queryWord, 1, true) == 1 then return 90 end
    if fieldWord .. "s" == queryWord or queryWord .. "s" == fieldWord then return 82 end
    if sfind(fieldWord, queryWord, 1, true) then return 50 end
    if queryWordLen >= 3 then
        local fieldLen = #fieldWord
        if fieldLen > queryWordLen and queryWordLen <= 8
           and queryWordLen / fieldLen >= 0.45
           and Database:IsSubsequence(fieldWord, queryWord, queryWordLen) then
            return 55
        end
    end
    if queryWordLen >= 4 and sbyte(fieldWord, 1) == sbyte(queryWord, 1) then
        local fieldLen = #fieldWord
        local maxEdits = queryWordLen >= 8 and 2 or 1
        if fieldLen >= queryWordLen - maxEdits and fieldLen <= queryWordLen + maxEdits then
            local dist = Database:DamerauLevenshtein(fieldWord, queryWord, fieldLen, queryWordLen)
            if dist <= maxEdits then return mmax(45, 85 - dist * 20) end
        end
    end
    return 0
end

local function ScoreFieldWords(words, queryWord, queryWordLen)
    local best = 0
    for i = 1, #words do
        local score = ScoreSingleFieldWord(words[i], queryWord, queryWordLen)
        if score > best then best = score end
    end
    return best
end

local keywordWordListsScratch = {}
function Database:ScoreEntryFields(data, queryWords)
    if not queryWords or #queryWords < 2 then return 0 end
    local total = 0
    local matched = 0
    local nameMatches = 0
    local nameWords = GetWords(data.nameLower or "")
    -- Fall back to keywords when keywordsLower is omitted (most providers
    -- skip the duplicate field when the keyword list is already lowercase).
    local keywordsLower = data.keywordsLower or data.keywords

    local keywordWordLists = keywordWordListsScratch
    local kwCount = keywordsLower and #keywordsLower or 0
    for ki = 1, kwCount do
        keywordWordLists[ki] = GetWords(keywordsLower[ki])
    end

    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        local qwLen = #qw
        if qwLen >= 2 or (qwLen == 1 and qi == #queryWords and matched > 0) then
            local nameBest = ScoreFieldWords(nameWords, qw, qwLen)
            local kwBest = 0
            for ki = 1, kwCount do
                local kw = keywordsLower[ki]
                local kwScore = ScoreSingleFieldWord(kw, qw, qwLen)
                if kwScore < 90 then
                    kwScore = mmax(kwScore, ScoreFieldWords(keywordWordLists[ki], qw, qwLen))
                end
                if kwScore > kwBest then kwBest = kwScore end
            end
            local best
            if nameBest > 0 then
                best = nameBest
                nameMatches = nameMatches + 1
            else
                best = kwBest
            end
            if best == 0 then return 0 end
            total = total + best
            matched = matched + 1
        end
    end

    if matched < 2 then return 0 end
    -- Discount pure-keyword matches: keyword sums (90/word) beat the
    -- avg-capped name-only score (110 max), so an item whose keyword list
    -- contains "Eastern Kingdoms" would outrank the actual zone.
    if nameMatches == 0 then
        total = mfloor(total * 0.45)
    end
    return total + matched * 5
end

local prevQuery = ""
local prevSkipKey = ""
local prevCandidates = {}

function Database:WarmSearchHotPath()
    if self.HydrateCachedLoot then self:HydrateCachedLoot() end
    if self.HydrateCachedStatistics then self:HydrateCachedStatistics() end
    if self.HydrateCachedBosses then self:HydrateCachedBosses() end
    -- Load the small name-searched providers (currencies, reputations, etc.)
    -- so they show up without the user typing a category keyword first.
    if self.LoadEagerDynamicProviders then self:LoadEagerDynamicProviders() end
end

-- Search scans the full dataset for a fresh query, so there is no candidate
-- index to rebuild. This stays the invalidation hook the rest of the codebase
-- calls when search data changes: it clears the incremental-narrowing cache so
-- the next keystroke re-scans from scratch, and re-runs the active search once
-- (coalesced) so a provider that finished loading in the background appears
-- without the user having to retype.
local searchRefreshPending = false
local function RunActiveSearchRefresh()
    searchRefreshPending = false
    local search = ns.Search
    if search and search.RefreshActiveSearch then
        search:RefreshActiveSearch()
    end
end

function Database:ResetSearchCache()
    if ns.Aliases and ns.Aliases.InvalidateKeyIndex then ns.Aliases:InvalidateKeyIndex() end
    if self._dynamicBatchLoading then
        self._dynamicBatchChanged = true
        return
    end
    prevQuery = ""
    prevSkipKey = ""
    wipe(prevCandidates)
    if not searchRefreshPending and Utils.SafeAfter then
        searchRefreshPending = true
        Utils.SafeAfter(0, RunActiveSearchRefresh)
    end
end

local resultsBuf = {}
local resultsQueryWords = {}
local statisticScopedQueryWords = {}
local resultEntryPool = {}

function Database:TrimSearchMemory()
    self:UnloadDynamicSearchData()
    wipe(resultsBuf)
    wipe(resultsQueryWords)
    wipe(statisticScopedQueryWords)
    wipe(resultEntryPool)
    wipe(wordCache)
    prevQuery = ""
    prevSkipKey = ""
    wipe(prevCandidates)
end

function Database:SearchUI(query, skipCategories)
    if not query or query == "" or #query < 2 then
        prevQuery = ""
        wipe(prevCandidates)
        wipe(resultsBuf)
        return resultsBuf
    end

    query = Database:NormalizeSearchQuery(slower(query))
    local queryLen = #query

    -- Pre-trim trailing whitespace so scoring doesn't match() per entry.
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        query = Database:NormalizeSearchQuery(query)
        queryLen = #query
        if queryLen == 0 then prevQuery = ""; wipe(prevCandidates); wipe(resultsBuf); return resultsBuf end
    end

    wipe(resultsQueryWords)
    local queryWords = resultsQueryWords
    for w in query:gmatch("%S+") do
        queryWords[#queryWords + 1] = w
    end

    -- Gates: without "boss" in the query, bosses match name only ("icc"
    -- alone shouldn't flood with bosses). Achievements (~175 entries with
    -- broad keywords) are gated behind "ach"/"stat" or a strong name match.
    local bossQueryWord = false
    local achQueryWord = false
    local statQueryWord = false
    local lootStatQueryWord = false
    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        if BOSS_QUERY_WORDS[qw] then
            bossQueryWord = true
        end
        local isStatQueryWord = STAT_QUERY_WORDS[qw]
        if isStatQueryWord then
            statQueryWord = true
        end
        if IsLootStatSearchWord(qw) then
            lootStatQueryWord = true
        end
        if ssub(qw, 1, 3) == "ach" or isStatQueryWord then
            achQueryWord = true
        end
    end

    local statisticScopedQuery
    local statisticScopedQueryLen = 0
    if statQueryWord and #queryWords >= 2 then
        wipe(statisticScopedQueryWords)
        for qi = 1, #queryWords do
            local qw = queryWords[qi]
            if not STAT_QUERY_WORDS[qw] then
                statisticScopedQueryWords[#statisticScopedQueryWords + 1] = qw
            end
        end
        if #statisticScopedQueryWords > 0 then
            statisticScopedQuery = tconcat(statisticScopedQueryWords, " ")
            statisticScopedQueryLen = #statisticScopedQuery
        end
    end

    -- Distinct 1-2 char code per skippable category. The incremental search
    -- reuses prevCandidates only when skipKey == prevSkipKey, so every
    -- category that Query.lua may put in skipCategories must change the key
    -- when toggled, otherwise re-enabling a filter mid-query leaves the
    -- previously-filtered items missing from the candidate set.
    local skipKey = skipCategories and (
        (skipCategories["Mount"] and "M" or "") ..
        (skipCategories["Toy"] and "T" or "") ..
        (skipCategories["Pet"] and "P" or "") ..
        (skipCategories["Outfit"] and "O" or "") ..
        (skipCategories["Heirloom"] and "H" or "") ..
        (skipCategories["Loot"] and "L" or "") ..
        (skipCategories["Statistic"] and "S" or "") ..
        (skipCategories["Bag"] and "Ba" or "") ..
        (skipCategories["Macro"] and "Mc" or "") ..
        (skipCategories["Game Settings"] and "Gs" or "") ..
        (skipCategories["AddOn Settings"] and "Ao" or "") ..
        (skipCategories["Ability"] and "Ab" or "") ..
        (skipCategories["Boss"] and "Bo" or "") ..
        (skipCategories["Title"] and "Ti" or "") ..
        (skipCategories["Gear Set"] and "Gr" or "") ..
        (skipCategories["Appearance"] and "Ap" or "") ..
        (skipCategories["Appearance Set"] and "Aps" or "") ..
        (skipCategories["Talent"] and "Tn" or "") ..
        (skipCategories["Command"] and "Cm" or "")
    ) or ""

    -- prevCandidates can miss entries the now-more-permissive pass matches:
    --   1. A gate flipped on ("icc bos" -> "icc boss"). Boss/ach entries
    --      were never scored before the flip.
    --   2. A word was appended to a stat-keyword query ("haste" ->
    --      "haste ring"): loot rings that only the appended word matches
    --      weren't in the previous match set (lootStatKw is enriched lazily).
    -- Either case bypasses extension and rebuilds via a full scan.
    local prevLootStat, prevBossWord, prevAchWord = false, false, false
    local prevWordCount = 0
    if prevQuery ~= "" then
        for prevWord in prevQuery:gmatch("%S+") do
            prevWordCount = prevWordCount + 1
            if IsLootStatSearchWord(prevWord) then prevLootStat = true end
            if BOSS_QUERY_WORDS[prevWord] then
                prevBossWord = true
            end
            if ssub(prevWord, 1, 3) == "ach" or STAT_QUERY_WORDS[prevWord] then
                prevAchWord = true
            end
        end
    end
    local addedNewWord = #queryWords > prevWordCount
    local gatingShifted =
        (lootStatQueryWord and not prevLootStat)
        or (bossQueryWord and not prevBossWord)
        or (achQueryWord and not prevAchWord)
        or (lootStatQueryWord and addedNewWord)
        or (statQueryWord and addedNewWord)

    -- Incremental narrowing (the speed path): when the query only grew, re-score
    -- the previous match set instead of the whole dataset. A longer query can
    -- only shrink prefix / substring / exact / word-boundary / keyword matches,
    -- so narrowing stays complete for them. It is NOT safe across the lengths
    -- where fuzzy-typo and abbreviation matching switch on or widen (3, 4, 8):
    -- those can reveal matches that weren't in the previous set, so rebuild from
    -- a full scan there. Every other case full-scans too. There is deliberately
    -- no "ready index" mode that scans a narrower bucket -- that split (complete
    -- full scan vs. incomplete bucket, flipped by a background timer) is exactly
    -- what made the same query return different results at different moments.
    local prevLen = #prevQuery
    local recallBoundaryCrossed =
        (prevLen < 3 and queryLen >= 3)
        or (prevLen < 4 and queryLen >= 4)
        or (prevLen < 8 and queryLen >= 8)

    local searchSet
    if prevLen > 0 and skipKey == prevSkipKey
        and queryLen > prevLen and ssub(query, 1, prevLen) == prevQuery
        and not gatingShifted and not recallBoundaryCrossed then
        searchSet = prevCandidates
    else
        searchSet = uiSearchData
    end

    wipe(resultsBuf)
    local results = resultsBuf
    local resultsN = 0
    local candidateIdx = 0

    local searchCount = #searchSet
    for i = 1, searchCount do
        local data = searchSet[i]
        if not (skipCategories and skipCategories[data.category])
           and not (data.available and not data.available()) then
            local nameLower = data.nameLower
            local score
            if data.lootEntry then
                if lootStatQueryWord and not data._statsEnriched then
                    Database:EnrichLootStats(data)
                end
                -- Each query word scores against name + slot + stats + source
                -- kws; best match wins; an unmatched word eliminates the item.
                local totalScore = 0

                local nameWords = GetWords(nameLower)
                for qi = 1, #queryWords do
                    local qw = queryWords[qi]
                    local qwLen = #qw
                    local bestWord = 0

                    -- Name match must outrank lootSourceKw (boss name) below,
                    -- else loot named for the query gets buried under same-
                    -- boss loot that only matched via the encounter name.
                    for ni = 1, #nameWords do
                        local nw = nameWords[ni]
                        if nw == qw then
                            bestWord = mmax(bestWord, qi == 1 and 130 or 120)
                        elseif ssub(nw, 1, qwLen) == qw then
                            bestWord = mmax(bestWord, qi == 1 and 115 or 105)
                        end
                    end

                    if data.lootSlotKw then
                        for ki = 1, #data.lootSlotKw do
                            local kw = data.lootSlotKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, qwLen <= 3 and 140 or 80)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    if data.lootStatKw then
                        for ki = 1, #data.lootStatKw do
                            local kw = data.lootStatKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, qwLen <= 3 and 140 or 80)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    -- Prefix on boss/dungeon name must beat 1-edit fuzzy (85)
                    -- on unrelated names, so "nexu" -> Nexus-Point Xenas gear
                    -- doesn't rank below misspellings of other entries.
                    if data.lootSourceKw then
                        for ki = 1, #data.lootSourceKw do
                            local kw = data.lootSourceKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, 110)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 100)
                            end
                        end
                    end

                    if bestWord == 0 then
                        totalScore = 0
                        break
                    end
                    totalScore = totalScore + bestWord
                end

                score = totalScore
            elseif data.category == "Boss" and not bossQueryWord then
                score = Database:ScoreName(nameLower, query, queryLen, queryWords)
            else
                local cat = data.category
                local isAchEntry = cat == "Achievement Category" or cat == "Statistic"
                if isAchEntry and not achQueryWord then
                    -- Strong name matches only (skip kw score) so short kw
                    -- aliases don't drag every achievement category in.
                    if nameLower == query then
                        score = 200
                    elseif sfind(nameLower, query, 1, true) == 1 then
                        score = 150
                    elseif Database:FindAtWordBoundary(nameLower, query) then
                        score = 120
                    else
                        score = 0
                    end
                else
                    local entryQuery = query
                    local entryQueryLen = queryLen
                    local entryQueryWords = queryWords
                    if cat == "Statistic" and statisticScopedQuery then
                        entryQuery = statisticScopedQuery
                        entryQueryLen = statisticScopedQueryLen
                        entryQueryWords = statisticScopedQueryWords
                    end
                    -- MAX, not SUM. Many entries duplicate their name into
                    -- keywordsLower; a sum double-counts the same fuzzy hit.
                    score = mmax(
                        Database:ScoreName(nameLower, entryQuery, entryQueryLen, entryQueryWords),
                        Database:ScoreKeywords(data.keywordsLower or data.keywords,
                            entryQuery, entryQueryLen, entryQueryWords)
                    )
                    if #entryQueryWords >= 2 then
                        score = mmax(score, Database:ScoreEntryFields(data, entryQueryWords))
                    end
                end
            end

            if score >= 30 then
                resultsN = resultsN + 1
                local r = resultEntryPool[resultsN]
                if not r then
                    r = {}
                    resultEntryPool[resultsN] = r
                end
                r.data = data
                r.score = score
                r.isAlias = nil
                results[resultsN] = r
                candidateIdx = candidateIdx + 1
                prevCandidates[candidateIdx] = data
            end
        end
    end
    for i = candidateIdx + 1, #prevCandidates do
        prevCandidates[i] = nil
    end
    prevQuery = query
    prevSkipKey = skipKey

    tsort(results, scoreDescending)
    local SEARCH_RESULT_CAP = 250
    if resultsN > SEARCH_RESULT_CAP then
        for i = SEARCH_RESULT_CAP + 1, resultsN do results[i] = nil end
        for i = SEARCH_RESULT_CAP + 1, #resultEntryPool do
            resultEntryPool[i] = nil
        end
        resultsN = SEARCH_RESULT_CAP
    end
    -- Drop stale data refs so a broad-then-narrow search doesn't keep
    -- the broad refs alive forever.
    for i = resultsN + 1, #resultEntryPool do
        local r = resultEntryPool[i]
        if r and r.data then
            r.data = nil
            r.score = nil
            r.isAlias = nil
        end
    end
    return results
end

return Database
