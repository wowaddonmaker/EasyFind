local _, ns = ...

-- Candidate-generation index for the full-scan search path.
--
-- Replaces "run the scoring ladder on all N entries" with q-gram
-- inverted-index candidate generation (posting-list count filtering, the
-- method behind pg_trgm / q-gram approximate dictionary search), plus
-- class-complete auxiliary filters. The existing scorers then verify and
-- rank ONLY the candidates, so results are identical to the full scan.
--
-- For a query word w, the union of these sets provably contains every
-- entry the scoring ladder can award points to:
--
--   A  contiguous matches (exact / prefix / substring / word boundary):
--      an occurrence of w inside an indexed text contains every bigram of
--      w, so candidates are entries whose posting count equals w's bigram
--      count. A trailing-s stripped variant is unioned for the plural rule.
--   B  prefix-walk initials ("raba" -> RA(ndom) BA(ttleground)): the
--      walk's first segment is a 2+ char prefix of an indexed word, so
--      w's first bigram must START some word -> the word-prefix posting.
--      (For 2-3 char words the whole walk degenerates to a single word
--      prefix, which is a subset of A, so B only runs at 4+ chars.)
--   B2 pure initials ("rb" -> R(ated) B(attlegrounds)): w must equal the
--      first letters of a text's leading words in order, i.e. a PREFIX of
--      the text's initials string -> posting keyed by the first two
--      initials of every multi-word text.
--   C  fuzzy (Damerau <= k) and in-word subsequences: any such match needs
--      all but k of w's a-z chars present in the entry's combined text ->
--      per-entry char-mask sweep with a popcount allowance (k = 0 under
--      4 chars, 1 under 8, 2 at 8+). Runs at 3+ chars; 2-char words have
--      no fuzzy/subsequence/initials classes, so A alone is complete and
--      the sweep is skipped entirely.
--
-- Loot entries match through fields outside this index (lootSlotKw /
-- lootStatKw / lootSourceKw, some enriched lazily), so they are always
-- emitted as candidates and never filtered here. Multi-word queries
-- intersect the per-word unions, mirroring the scan's "every word of 2+
-- chars must match" contract. Statistic-scoped queries rewrite the query
-- per entry, so the caller bypasses the index for those.
--
-- Maintenance: appends index incrementally (provider loads). Postings are
-- keyed by entry REFERENCE, so removals cost one liveness flag each
-- (NoteRemoved) and never a synchronous rebuild; dead postings purge in a
-- deferred compaction that runs only while the search bar is closed.

local Database = ns.Database
local SearchIndex = {}
ns.SearchIndex = SearchIndex

local sbyte, ssub = string.byte, string.sub
local band, bor, lshift = bit.band, bit.bor, bit.lshift
local wipe = wipe
local pairs = pairs
local tsort = table.sort

-- Keep in sync with Database/Search.lua's fuzzy thresholds.
local FUZZY_EDIT1_LEN, FUZZY_EDIT2_LEN = 4, 8
local ALL_CHARS_MASK = lshift(1, 26) - 1

local dirty = true
local builtCount = 0
-- Postings are keyed by ENTRY REFERENCE, not uiSearchData position, so a
-- removal's array compaction invalidates nothing: dead entries just stop
-- being alive and filter out of candidates, and the postings purge in ONE
-- idle compaction instead of a full synchronous rebuild on the next
-- keystroke. (Position-keyed postings forced that rebuild -- ~250ms and
-- ~10MB of allocation -- every time a provider repopulated mid-typing;
-- the housing stream did it repeatedly per session.)
local gramPost = {}   -- "ab" -> array of entry refs containing bigram
local wordPost = {}   -- word-leading bigram -> array of entry refs
local initPost = {}   -- first two initials of a multi-word text -> refs
local entryMask = {}  -- entry ref -> a-z char mask over name+keywords
local lootIdx = {}    -- refs of loot entries (always candidates)
local indexedEntries = {} -- dense array of every indexed ref (fuzzy sweep)
local serials = {}    -- entry ref -> index-time serial (stable sort order)
local alive = {}      -- entry ref -> true while still in uiSearchData
local nextSerial = 0
local deadCount = 0
local compactScheduled = false

local seenGrams = {}
local counts = {}
local wordSet = {}
local resultSet = {}
local candBuf = {}
local queryGramsBuf = {}

local function maskOf(s, m)
    for i = 1, #s do
        local b = sbyte(s, i)
        if b >= 97 and b <= 122 then m = bor(m, lshift(1, b - 97)) end
    end
    return m
end

-- Word-splits text, appending each word's bigrams to gramPost and its
-- leading bigram to wordPost, deduped per entry through seenGrams (the
-- caller wipes it per entry). Query words never contain spaces, so
-- within-word bigrams are sufficient for the contiguous class.
local function IndexText(e, text)
    local wordStart = 1
    local len = #text
    local init1, init2
    for p = 1, len + 1 do
        local b = p <= len and sbyte(text, p) or 32
        if b == 32 then
            if p > wordStart then
                -- First letters of the two leading words anchor the pure-
                -- initials class (1-char words count as words there).
                if not init1 then
                    init1 = ssub(text, wordStart, wordStart)
                elseif not init2 then
                    init2 = ssub(text, wordStart, wordStart)
                end
            end
            if p - wordStart >= 2 then
                local lead = ssub(text, wordStart, wordStart + 1)
                local leadKey = "\1" .. lead
                if not seenGrams[leadKey] then
                    seenGrams[leadKey] = true
                    local post = wordPost[lead]
                    if not post then post = {}; wordPost[lead] = post end
                    post[#post + 1] = e
                end
                for g = wordStart, p - 2 do
                    local gram = ssub(text, g, g + 1)
                    if not seenGrams[gram] then
                        seenGrams[gram] = true
                        local post = gramPost[gram]
                        if not post then post = {}; gramPost[gram] = post end
                        post[#post + 1] = e
                    end
                end
            end
            wordStart = p + 1
        end
    end
    if init1 and init2 then
        local key = init1 .. init2
        local initKey = "\2" .. key
        if not seenGrams[initKey] then
            seenGrams[initKey] = true
            local post = initPost[key]
            if not post then post = {}; initPost[key] = post end
            post[#post + 1] = e
        end
    end
end

local function IndexEntry(data)
    -- Idempotent: after a removal compacts uiSearchData, already-indexed
    -- entries shift into the "new" position range; re-adding them would
    -- duplicate postings.
    if serials[data] then
        alive[data] = true
        return
    end
    nextSerial = nextSerial + 1
    serials[data] = nextSerial
    alive[data] = true
    indexedEntries[#indexedEntries + 1] = data
    if data.lootEntry then
        lootIdx[#lootIdx + 1] = data
        -- Full mask so the sweep classes never reject loot either.
        entryMask[data] = ALL_CHARS_MASK
        return
    end
    wipe(seenGrams)
    local m = 0
    local nameLower = data.nameLower
    if nameLower then
        m = maskOf(nameLower, m)
        IndexText(data, nameLower)
    end
    local kws = data.keywordsLower or data.keywords
    if kws then
        for k = 1, #kws do
            local kw = kws[k]
            if kw then
                m = maskOf(kw, m)
                IndexText(data, kw)
            end
        end
    end
    entryMask[data] = m
end

local function Rebuild()
    wipe(gramPost)
    wipe(wordPost)
    wipe(initPost)
    wipe(entryMask)
    wipe(lootIdx)
    wipe(indexedEntries)
    wipe(serials)
    wipe(alive)
    nextSerial = 0
    deadCount = 0
    local dataArr = Database.uiSearchData
    for i = 1, #dataArr do
        IndexEntry(dataArr[i])
    end
    builtCount = #dataArr
    dirty = false
end

local function Ensure()
    if dirty then
        Rebuild()
        return
    end
    local dataArr = Database.uiSearchData
    local n = #dataArr
    if builtCount < n then
        for i = builtCount + 1, n do
            IndexEntry(dataArr[i])
        end
    end
    -- Removal compactions can shrink the array; ref-keyed postings do not
    -- care (NoteRemoved handled liveness), only the append watermark moves.
    builtCount = n
end

function SearchIndex:MarkDirty()
    dirty = true
end

-- A removed entry stops being a candidate IMMEDIATELY (liveness check in
-- Candidates); its postings linger until one deferred compaction purges
-- them, instead of a full rebuild on the next keystroke.
local function TryCompact()
    compactScheduled = false
    if deadCount == 0 then return end
    -- Never compact under the user's fingers: the rebuild is the very
    -- hitch this design removed from the keystroke path. With the bar
    -- open, re-arm and wait for it to close.
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if sf and sf:IsShown() then
        compactScheduled = true
        ns.Utils.SafeAfter(5, TryCompact)
        return
    end
    dirty = true
    Ensure()
end

function SearchIndex:NoteRemoved(entry)
    if not alive[entry] then return end
    alive[entry] = nil
    deadCount = deadCount + 1
    if not compactScheduled and ns.Utils and ns.Utils.SafeAfter then
        compactScheduled = true
        ns.Utils.SafeAfter(2, TryCompact)
    end
end

local function MissingWithin(qm, tm, allowed)
    local present = band(qm, tm)
    if present == qm then return true end
    if allowed == 0 then return false end
    local missing = qm - present
    local n = 0
    while missing ~= 0 do
        missing = band(missing, missing - 1)
        n = n + 1
        if n > allowed then return false end
    end
    return true
end

-- Class A: entries containing every bigram of w (count filtering).
local function AddContiguous(w)
    local wl = #w
    if wl < 2 then return end
    wipe(seenGrams)
    local nGrams = 0
    for g = 1, wl - 1 do
        local gram = ssub(w, g, g + 1)
        if not seenGrams[gram] then
            seenGrams[gram] = true
            nGrams = nGrams + 1
            queryGramsBuf[nGrams] = gram
        end
    end
    wipe(counts)
    for gi = 1, nGrams do
        local post = gramPost[queryGramsBuf[gi]]
        if not post then return end
        for pi = 1, #post do
            local e = post[pi]
            local c = (counts[e] or 0) + 1
            counts[e] = c
            if c == nGrams then wordSet[e] = true end
        end
    end
end

-- Union of classes A/B/C for one query word into wordSet.
local function CollectWord(qw)
    wipe(wordSet)
    local L = #qw
    AddContiguous(qw)
    if L >= 3 and ssub(qw, L, L) == "s" then
        AddContiguous(ssub(qw, 1, L - 1))
    end
    -- B2 pure initials: qw must prefix a text's initials string, so its
    -- first two chars equal the text's first two initials; the mask trims
    -- texts that lack qw's remaining letters.
    do
        local post = initPost[ssub(qw, 1, 2)]
        if post then
            local qm = maskOf(qw, 0)
            for pi = 1, #post do
                local e = post[pi]
                if not wordSet[e] and band(qm, entryMask[e]) == qm then
                    wordSet[e] = true
                end
            end
        end
    end
    if L >= 4 then
        local post = wordPost[ssub(qw, 1, 2)]
        if post then
            local qm = maskOf(qw, 0)
            for pi = 1, #post do
                local e = post[pi]
                if not wordSet[e] and band(qm, entryMask[e]) == qm then
                    wordSet[e] = true
                end
            end
        end
    end
    if L >= 3 then
        local qm = maskOf(qw, 0)
        local allowed = 0
        if L >= FUZZY_EDIT2_LEN then
            allowed = 2
        elseif L >= FUZZY_EDIT1_LEN then
            allowed = 1
        end
        for i = 1, #indexedEntries do
            local e = indexedEntries[i]
            if not wordSet[e] and MissingWithin(qm, entryMask[e], allowed) then
                wordSet[e] = true
            end
        end
    end
    for li = 1, #lootIdx do
        wordSet[lootIdx[li]] = true
    end
end

-- Returns (candidateArray, count) for the query's words, or nil when the
-- index cannot serve the query (no usable word). Candidates come out in
-- ascending uiSearchData position -- the same iteration order as the full
-- scan -- so the result cap keeps the exact same tie subset the scan would.
local function SerialLess(a, b)
    return serials[a] < serials[b]
end

function SearchIndex:Candidates(queryWords)
    Ensure()
    if builtCount == 0 then return nil end
    wipe(resultSet)
    local first = true
    local usable = 0
    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        if #qw >= 2 then
            usable = usable + 1
            CollectWord(qw)
            if first then
                first = false
                for e in pairs(wordSet) do
                    resultSet[e] = true
                end
            else
                for e in pairs(resultSet) do
                    if not wordSet[e] then
                        resultSet[e] = nil
                    end
                end
            end
        end
    end
    if usable == 0 then return nil end
    local n = 0
    for e in pairs(resultSet) do
        if alive[e] then
            n = n + 1
            candBuf[n] = e
        end
    end
    for i = n + 1, #candBuf do
        candBuf[i] = nil
    end
    -- Serial order == index-time order == uiSearchData append order, so
    -- ties resolve exactly as the full scan's iteration would.
    tsort(candBuf, SerialLess)
    return candBuf, n
end
