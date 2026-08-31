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
-- keyed by index-time SERIAL, so removals cost one liveness flag each
-- (NoteRemoved) and never a synchronous rebuild; dead postings purge in a
-- deferred compaction that runs only while the search bar is closed.

local Database = ns.Database
local SearchIndex = {}
ns.SearchIndex = SearchIndex

local sbyte, ssub = string.byte, string.sub
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local wipe = wipe
local pairs = pairs
local tsort = table.sort
local getmetatable, rawget = getmetatable, rawget
local SliceCheckpoint = ns.Utils.SliceCheckpoint

-- Keep in sync with Database/Search.lua's fuzzy thresholds.
local FUZZY_EDIT1_LEN, FUZZY_EDIT2_LEN = 4, 8
local ALL_CHARS_MASK = lshift(1, 26) - 1

local dirty = true
local builtCount = 0
-- Postings are keyed by index-time SERIAL, not uiSearchData position, so
-- a removal's array compaction invalidates nothing: dead entries just
-- stop being alive and filter out of candidates, and the postings purge
-- in ONE idle compaction instead of a full synchronous rebuild on the
-- next keystroke. (Position-keyed postings forced that rebuild -- ~250ms
-- and ~10MB of allocation -- every time a provider repopulated
-- mid-typing; the housing stream did it repeatedly per session.)
-- Serials are dense monotonic integers, so every hot table keeps Lua's
-- array part and the candidate sort needs no comparator (ref keys here
-- measurably LOST to the full scan: pointer hashing on every posting
-- hit). slotEntry maps a serial back to its entry at the very end.
-- Posting lists are COMPRESSED: each serial packs to 3 little-endian
-- bytes in a frozen string (vs ~17 bytes per Lua array slot), with a
-- small pending-tail array per key that freezes into the string in
-- batches. Reads decode a whole bucket into one shared scratch array,
-- so the hot counting loops stay plain array iteration. Standard
-- compressed-posting-list design, sized for the measured reality that
-- the postings were the largest resident structure in the addon.
local gramStr, gramTail = {}, {}   -- "ab" -> packed serials + pending
local wordStr, wordTail = {}, {}   -- word-leading bigram -> same
local initStr, initTail = {}, {}   -- leading-initials pair -> same
local entryMask = {}  -- serial -> a-z char mask over name+keywords
local lootIdx = {}    -- serials of loot entries (always candidates)
local slotEntry = {}  -- serial -> entry ref
local serials = {}    -- entry ref -> serial
local alive = {}      -- serial -> true while still in uiSearchData
local nextSerial = 0
local deadCount = 0
local compactScheduled = false

local FREEZE_AT = 64
local schar = string.char
local tconcat = table.concat
local postScratch = {}   -- shared decode buffer (one bucket at a time)
local freezeBuf = {}     -- shared encode buffer

-- Append serial to the bucket for key, freezing the tail into the
-- packed string once it grows past FREEZE_AT.
local function PostAppend(strMap, tailMap, key, sid)
    local tail = tailMap[key]
    if not tail then tail = {}; tailMap[key] = tail end
    tail[#tail + 1] = sid
    if #tail >= FREEZE_AT then
        local n = 0
        for i = 1, #tail do
            local v = tail[i]
            n = n + 1
            freezeBuf[n] = schar(band(v, 255), band(rshift(v, 8), 255), band(rshift(v, 16), 255))
        end
        -- Chunk LIST during build, one concat on first read: the rolling
        -- string concat this replaces was O(n^2) copying on frequent
        -- grams and produced most of the index build's garbage (a 5000-
        -- posting bucket re-copied its whole string ~78 times).
        local bucket = strMap[key]
        if type(bucket) ~= "table" then
            bucket = { bucket }
            strMap[key] = bucket
        end
        bucket[#bucket + 1] = tconcat(freezeBuf, "", 1, n)
        wipe(tail)
    end
end

-- Decode the whole bucket for key into postScratch; returns count
-- (0 = no such bucket). Callers loop postScratch 1..count.
local function DecodePostings(strMap, tailMap, key)
    local n = 0
    local str = strMap[key]
    if type(str) == "table" then
        -- Finalize the build-time chunk list into the packed string once.
        if str[1] == nil then table.remove(str, 1) end
        str = tconcat(str)
        strMap[key] = str
    end
    if str then
        local len = #str
        local p = 1
        while p + 2 <= len do
            n = n + 1
            local b1, b2, b3 = sbyte(str, p, p + 2)
            postScratch[n] = b1 + b2 * 256 + b3 * 65536
            p = p + 3
        end
    end
    local tail = tailMap[key]
    if tail then
        for i = 1, #tail do
            n = n + 1
            postScratch[n] = tail[i]
        end
    end
    return n
end

local seenGrams = {}
-- All index keys are NUMBERS, never substrings: a gram is b1*256+b2, a
-- word-lead the same for the word's first two bytes, an initials pair the
-- same for the two word-initial bytes. The old per-gram/lead/init ssub was
-- the warm's largest single allocator (measured in the warmledger). The
-- bases keep the three key classes distinct inside the shared per-entry
-- seenGrams dedupe table; the storage maps are separate and unprefixed.
local WORD_SEEN_BASE = 65536
local INIT_SEEN_BASE = 131072
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
                    init1 = sbyte(text, wordStart)
                elseif not init2 then
                    init2 = sbyte(text, wordStart)
                end
            end
            if p - wordStart >= 2 then
                local b1, b2 = sbyte(text, wordStart, wordStart + 1)
                local lead = b1 * 256 + b2
                if not seenGrams[WORD_SEEN_BASE + lead] then
                    seenGrams[WORD_SEEN_BASE + lead] = true
                    PostAppend(wordStr, wordTail, lead, e)
                end
                for g = wordStart, p - 2 do
                    local g1, g2 = sbyte(text, g, g + 1)
                    local gram = g1 * 256 + g2
                    if not seenGrams[gram] then
                        seenGrams[gram] = true
                        PostAppend(gramStr, gramTail, gram, e)
                    end
                end
            end
            wordStart = p + 1
        end
    end
    if init1 and init2 then
        local key = init1 * 256 + init2
        if not seenGrams[INIT_SEEN_BASE + key] then
            seenGrams[INIT_SEEN_BASE + key] = true
            PostAppend(initStr, initTail, key, e)
        end
    end
end

local function IndexEntry(data)
    -- Idempotent: after a removal compacts uiSearchData, already-indexed
    -- entries shift into the "new" position range; re-adding them would
    -- duplicate postings.
    local sid = serials[data]
    if sid then
        alive[sid] = true
        return
    end
    nextSerial = nextSerial + 1
    sid = nextSerial
    serials[data] = sid
    slotEntry[sid] = data
    alive[sid] = true
    if data.lootEntry then
        lootIdx[#lootIdx + 1] = sid
        -- Full mask so the sweep classes never reject loot either.
        entryMask[sid] = ALL_CHARS_MASK
        return
    end
    wipe(seenGrams)
    local m = 0
    -- Corpus stubs (metatable-tagged) index from transient decodes so the
    -- index build never hydrates them; the values are dropped after this.
    -- KeywordsOf serves per-row keywords (bosses); corpora without them
    -- fall through to the proto's shared keyword list.
    local nameLower, kws
    local mt = getmetatable(data)
    local pc = mt and rawget(mt, "__pcCorpus")
    if pc then
        local ri = rawget(data, "_ri")
        nameLower = pc:NameLowerOf(ri)
        kws = pc:KeywordsOf(ri)
    else
        nameLower = data.nameLower
    end
    if nameLower then
        m = maskOf(nameLower, m)
        IndexText(sid, nameLower)
    end
    kws = kws or data.keywordsLower or data.keywords
    if kws then
        for k = 1, #kws do
            local kw = kws[k]
            if kw then
                m = maskOf(kw, m)
                IndexText(sid, kw)
            end
        end
    end
    entryMask[sid] = m
end

local function Rebuild()
    wipe(gramStr); wipe(gramTail)
    wipe(wordStr); wipe(wordTail)
    wipe(initStr); wipe(initTail)
    wipe(entryMask)
    wipe(lootIdx)
    wipe(slotEntry)
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

-- Above this many unindexed appends, a QUERY-TIME Ensure refuses the
-- synchronous build while the warm chain is still loading: paying the
-- whole append in one keystroke frame was a 100-400ms stall. The caller
-- falls back to the full scan (the pre-index behavior) and the chain's
-- budgeted slices finish the build in the background.
local SYNC_BUILD_MAX = 800

local function Ensure()
    if dirty then
        Rebuild()
        return true
    end
    local dataArr = Database.uiSearchData
    local n = #dataArr
    if builtCount < n then
        if n - builtCount > SYNC_BUILD_MAX and Database._dynamicBatchLoading then
            return false
        end
        for i = builtCount + 1, n do
            IndexEntry(dataArr[i])
        end
    end
    -- Removal compactions can shrink the array; ref-keyed postings do not
    -- care (NoteRemoved handled liveness), only the append watermark moves.
    builtCount = n
    return true
end

-- Budgeted incremental build for the warm chain: index appended entries
-- until budgetMs is spent; returns true when caught up. The chain calls
-- this between provider loads so first queries never pay the whole build.
function SearchIndex:EnsureBudget(budgetMs)
    if dirty then
        Rebuild()
        return true
    end
    local dataArr = Database.uiSearchData
    local n = #dataArr
    if builtCount >= n then
        builtCount = n
        return true
    end
    local dps = debugprofilestop
    local start = dps and dps() or 0
    local i = builtCount + 1
    while i <= n do
        IndexEntry(dataArr[i])
        i = i + 1
        if dps and (dps() - start) >= budgetMs then break end
    end
    builtCount = i - 1
    return builtCount >= n
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
    local sid = serials[entry]
    if not sid or not alive[sid] then return end
    alive[sid] = nil
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
        local g1, g2 = sbyte(w, g, g + 1)
        local gram = g1 * 256 + g2
        if not seenGrams[gram] then
            seenGrams[gram] = true
            nGrams = nGrams + 1
            queryGramsBuf[nGrams] = gram
        end
    end
    wipe(counts)
    for gi = 1, nGrams do
        local pn = DecodePostings(gramStr, gramTail, queryGramsBuf[gi])
        if pn == 0 then return end
        for pi = 1, pn do
            local e = postScratch[pi]
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
    if L >= 3 and sbyte(qw, L) == 115 then
        AddContiguous(ssub(qw, 1, L - 1))
    end
    -- B2 pure initials: qw must prefix a text's initials string, so its
    -- first two chars equal the text's first two initials; the mask trims
    -- texts that lack qw's remaining letters.
    local qb1, qb2 = sbyte(qw, 1, 2)
    local leadKey = qb1 * 256 + qb2
    do
        local pn = DecodePostings(initStr, initTail, leadKey)
        if pn > 0 then
            local qm = maskOf(qw, 0)
            for pi = 1, pn do
                local e = postScratch[pi]
                if not wordSet[e] and band(qm, entryMask[e]) == qm then
                    wordSet[e] = true
                end
            end
        end
    end
    if L >= 4 then
        local pn = DecodePostings(wordStr, wordTail, leadKey)
        if pn > 0 then
            local qm = maskOf(qw, 0)
            for pi = 1, pn do
                local e = postScratch[pi]
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
        for sid = 1, nextSerial do
            if band(sid, 511) == 0 then SliceCheckpoint() end
            if alive[sid] and not wordSet[sid]
               and MissingWithin(qm, entryMask[sid], allowed) then
                wordSet[sid] = true
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
function SearchIndex:Candidates(queryWords)
    if not Ensure() then return nil end
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
    for sid in pairs(resultSet) do
        if alive[sid] then
            n = n + 1
            candBuf[n] = sid
        end
    end
    for i = n + 1, #candBuf do
        candBuf[i] = nil
    end
    -- Serial order == index-time order == uiSearchData append order, so
    -- ties resolve exactly as the full scan's iteration would.
    tsort(candBuf)
    for i = 1, n do
        candBuf[i] = slotEntry[candBuf[i]]
    end
    return candBuf, n
end

-- Dev-tool peek (EasyFindDev memory audit): file-local structures are
-- invisible to table walks from ns; this hands the audit the real
-- internals. Returns shared references; callers must not mutate.
function SearchIndex:_DebugPeek()
    return {
        gramStr = gramStr, gramTail = gramTail, wordStr = wordStr,
        wordTail = wordTail, initStr = initStr, initTail = initTail,
        entryMask = entryMask, lootIdx = lootIdx, slotEntry = slotEntry,
        serials = serials, alive = alive,
    }
end
