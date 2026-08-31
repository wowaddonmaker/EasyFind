-- Part of the EasyFind_Icons LoadOnDemand companion: loaded on first
-- icon-search use via ns.RequestIconSearch(), never at login.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

-- Icon search data layer (GitHub #22): scans the packed icon blob IN
-- PLACE (the ItemSearch model). The blob stays resident as ONE string;
-- the only built structures are two integer arrays (record name-start
-- and tab positions), so the whole 33k-icon index costs ~1.7MB instead
-- of the ~4MB the old parsed name/id/idString arrays held. Names and
-- IDs decode on demand for the handful of records actually displayed.
--
-- Matching is word-wise so file-name vocabulary meets human vocabulary:
-- every query word must appear in the icon name, and each word also tries
-- its singular form ("swords" sweeps the _sword_ family). The blob name is
-- both the display name and the texture name macro authors copy.
--
-- Query syntax:
--   word word          every word must match (AND)
--   sword/axe          a word with alternatives: either matches
--   axe, mace 2h       comma splits whole alternative queries
--   -word              the word must NOT match
--   inv_sword_*        * and ? make the word a whole-name wildcard match
--   135274 or #135274  FileDataIDs by prefix, narrowing per digit; the
--                      full ID lists first (# = IDs only, no name hits)
--   spell:133 item:6948 achievement:12   the game's own hyperlink types:
--                      the icon that spell/item/achievement uses
--                      (shift-clicking a chat link types these for you)

local IconSearch = {}
ns.IconSearch = IconSearch

local Utils = ns.Utils
local sfind, ssub = Utils.sfind, Utils.ssub
local slower = Utils.slower or string.lower
local mfloor = Utils.mfloor
local tonumber = tonumber
local wipe = wipe

-- The resident corpus: the blob string plus two parallel int arrays.
-- offsets[i] = byte position of record i's name; tabs[i] = its tab.
-- Every record ends with "\n" (generator guarantee).
local blob, blobLen
local offsets, tabs = {}, {}
local total = 0

local function EnsureIndex()
    if total > 0 then return total end
    if not blob then
        local b = ns.ICON_SEARCH_BLOB
        if type(b) ~= "string" then return 0 end
        blob = b
        blobLen = #b
        -- The blob is retained (it IS the database); the field ref clears
        -- so nothing double-roots it.
        ns.ICON_SEARCH_BLOB = nil
    end
    local pos = 1
    while pos <= blobLen do
        local nl = sfind(blob, "\n", pos, true) or (blobLen + 1)
        local tab = sfind(blob, "\t", pos, true)
        if tab and tab < nl then
            total = total + 1
            offsets[total] = pos
            tabs[total] = tab
        end
        pos = nl + 1
    end
    return total
end

function IconSearch:GetIcon(index)
    if not blob or not offsets[index] then return nil end
    local name = ssub(blob, offsets[index], tabs[index] - 1)
    local recEnd = (offsets[index + 1] or (blobLen + 2)) - 2
    local id = tonumber(ssub(blob, tabs[index] + 1, recEnd))
    return name, id
end

function IconSearch:GetTotal()
    return EnsureIndex()
end

-- Record containing byte position p (binary search; ascending scans use
-- moving pointers instead).
local function RecordOf(p)
    local lo, hi = 1, total
    while lo < hi do
        local mid = mfloor((lo + hi + 1) / 2)
        if offsets[mid] <= p then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- FileDataID -> record index, via the blob itself ("\t<id>\n" is unique).
local function IndexOfFileID(fdid)
    if not fdid or not blob then return nil end
    local p = sfind(blob, "\t" .. fdid .. "\n", 1, true)
    if not p then return nil end
    return RecordOf(p)
end

-- spell:/item:/achievement: -> the FileDataID that thing renders with.
-- The kinds are WoW's own hyperlink types (|Hspell:133|...), which is what
-- the grid's shift-click link capture inserts. In-game APIs; every step
-- nil-guarded so the test harness (and any API churn) degrades to "no
-- match", never an error.
local function ResolveRefID(kind, refID)
    if kind == "spell" then
        local GetSpellInfo = C_Spell and C_Spell.GetSpellInfo
        local info = GetSpellInfo and GetSpellInfo(refID)
        return info and info.iconID
    end
    if kind == "item" then
        local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant
        if not GetItemInfoInstant then return nil end
        local _, _, _, _, iconID = GetItemInfoInstant(refID)
        return iconID
    end
    if kind == "achievement" then
        local GetAchievementInfo = _G.GetAchievementInfo
        if not GetAchievementInfo then return nil end
        local ok, _, _, _, _, _, _, _, _, _, iconID = pcall(GetAchievementInfo, refID)
        return ok and iconID or nil
    end
    return nil
end

-- A word carrying * or ? becomes an anchored whole-name wildcard. Blob
-- form: the name sits between "\n" (or blob start) and "\t", so the
-- anchors become those delimiters and the wildcards exclude them.
local function GlobToBlobPattern(word)
    local body = word:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    body = body:gsub("%*", "[^\t\n]*"):gsub("%?", "[^\t\n]")
    return "\n" .. body .. "\t", "^" .. body .. "\t"
end

-- Indices already emitted by the numeric prefix pass this Filter call, so
-- the name loop doesn't list them twice.
local numericSeen = {}

-- Fill `out` with every icon whose FileDataID STARTS with the typed
-- digits ("12" -> 125..., 129...; each further digit narrows). An exact
-- full-ID match lists first. Deliberately prefix-only: digits have an
-- order, unlike fuzzy text. Works straight off the blob: an ID starts
-- right after its record's tab, so "\t<digits>" enumerates prefixes.
local function CollectIDPrefix(digits, out, seen)
    EnsureIndex()
    if not blob then return 0 end
    local m = 0
    local exactIdx = IndexOfFileID(tonumber(digits))
    if exactIdx then
        m = 1
        out[1] = exactIdx
        if seen then seen[exactIdx] = true end
    end
    local needle = "\t" .. digits
    local rec = 1
    local p = sfind(blob, needle, 1, true)
    while p do
        while rec < total and offsets[rec + 1] <= p do rec = rec + 1 end
        if rec ~= exactIdx then
            m = m + 1
            out[m] = rec
            if seen then seen[rec] = true end
        end
        p = sfind(blob, needle, p + 1, true)
    end
    return m
end

-- Parsed query scratch, module-level (this runs per keystroke). Three
-- levels flattened into parallel arrays:
--   branches (comma) OR'd -> terms (space) AND'd -> alternates (/) OR'd
-- branch b owns terms branchEnd[b-1]+1 .. branchEnd[b]; term t owns
-- alternates termEnd[t-1]+1 .. termEnd[t].
local altText, altPlural, altPat1 = {}, {}, {}
local altIsPat = {}
local termEnd, termNeg = {}, {}
local branchEnd = {}

local function AddTerm(termN, altN, word)
    local neg = false
    while ssub(word, 1, 1) == "-" do
        neg = not neg
        word = ssub(word, 2)
    end
    local before = altN
    for alt in word:gmatch("[^/]+") do
        altN = altN + 1
        if sfind(alt, "[%*%?]") then
            local pat, pat1 = GlobToBlobPattern(alt)
            altText[altN] = pat
            altPat1[altN] = pat1
            altIsPat[altN] = true
            altPlural[altN] = nil
        else
            altText[altN] = alt
            altPat1[altN] = nil
            altIsPat[altN] = false
            -- "swords" -> "sword"; positive plain alternates only, and only
            -- when the singular is still a word.
            if not neg and #alt > 3
               and ssub(alt, -1) == "s" and ssub(alt, -2) ~= "ss" then
                altPlural[altN] = ssub(alt, 1, -2)
            else
                altPlural[altN] = nil
            end
        end
    end
    if altN == before then return termN, altN end
    termN = termN + 1
    termEnd[termN] = altN
    termNeg[termN] = neg
    return termN, altN
end

local function PrepareQuery(query)
    wipe(termEnd)
    wipe(branchEnd)
    local termN, altN, branchN = 0, 0, 0
    for branch in query:gmatch("[^,]+") do
        local before = termN
        for word in branch:gmatch("[^%s]+") do
            termN, altN = AddTerm(termN, altN, word)
        end
        if termN > before then
            branchN = branchN + 1
            branchEnd[branchN] = termN
        end
    end
    return branchN
end

-- Per-keystroke evaluation scratch: generation-stamped so nothing wipes.
-- mark[rec] == markBase + t  means rec passed terms 1..t of the branch
-- under evaluation; hitStamp[rec] == hitGen dedupes within one term;
-- matched[rec] == matchGen marks a completed branch.
local mark, hitStamp, matched = {}, {}, {}
local markBase, hitGen, matchGen = 0, 0, 0

-- Close-boundary release: the offset/tab index (two 33k-slot arrays) and
-- the match scratch (three hashes that grow to one entry per record and
-- keep that capacity) together dwarf the blob. Fresh tables drop the
-- capacity -- wipe() would keep it -- and EnsureIndex rebuilds the index
-- from the retained blob in one pass on the next use.
function IconSearch:ReleaseMemory()
    offsets, tabs = {}, {}
    total = 0
    mark, hitStamp, matched = {}, {}, {}
    markBase, hitGen, matchGen = 0, 0, 0
end

-- Scan the blob for one PLAIN alternate. Ascending occurrences drive a
-- moving record pointer; a settled record skips ahead to the next, so
-- the loop is bounded by the record count, not the occurrence count.
-- An occurrence inside the id digits fails the tab guard and is skipped.
-- presenceOnly (negated terms): just stamp hits, no mark advance.
local function StampWord(word, t, firstTerm, presenceOnly)
    local wl = #word
    local rec = 1
    local p = sfind(blob, word, 1, true)
    while p do
        while rec < total and offsets[rec + 1] <= p do rec = rec + 1 end
        local nextInit = p + 1
        if p + wl - 1 < tabs[rec] then
            if presenceOnly then
                hitStamp[rec] = hitGen
            elseif hitStamp[rec] ~= hitGen
               and (firstTerm or mark[rec] == markBase + (t - 1)) then
                hitStamp[rec] = hitGen
                mark[rec] = markBase + t
            end
            nextInit = (offsets[rec + 1] or (blobLen + 1))
        end
        if nextInit > blobLen then break end
        p = sfind(blob, word, nextInit, true)
    end
end

-- Same for a wildcard alternate: anchored blob patterns ("\n<pat>\t",
-- plus a "^" form for record 1).
local function StampPattern(pat, pat1, t, firstTerm, presenceOnly)
    if blob:find(pat1) then
        if presenceOnly then
            hitStamp[1] = hitGen
        elseif hitStamp[1] ~= hitGen and (firstTerm or mark[1] == markBase + (t - 1)) then
            hitStamp[1] = hitGen
            mark[1] = markBase + t
        end
    end
    local rec = 1
    local p = blob:find(pat)
    while p do
        -- p sits on the "\n" BEFORE the record; the record starts at p+1.
        while rec < total and offsets[rec + 1] <= p + 1 do rec = rec + 1 end
        if presenceOnly then
            hitStamp[rec] = hitGen
        elseif hitStamp[rec] ~= hitGen and (firstTerm or mark[rec] == markBase + (t - 1)) then
            hitStamp[rec] = hitGen
            mark[rec] = markBase + t
        end
        local nextInit = (offsets[rec + 1] or (blobLen + 2)) - 1
        if nextInit <= p then nextInit = p + 1 end
        p = blob:find(pat, nextInit)
    end
end

-- Fills `out` (wiped) with master indices of icons matching the query.
-- Empty query = every icon. Returns the match count.
function IconSearch:Filter(query, out)
    wipe(out)
    local count = EnsureIndex()
    if count == 0 then return 0 end
    query = slower(query or ""):gsub("^%s+", ""):gsub("%s+$", "")

    -- spell:/item:/achievement: reference -> exactly that icon.
    local kind, refID = query:match("^(%a+):(%d+)$")
    if kind then
        local fdid = ResolveRefID(kind, tonumber(refID))
        local idx = fdid and IndexOfFileID(fdid)
        if idx then
            out[1] = idx
            return 1
        end
        return 0
    end

    -- #ID: FileDataIDs only, narrowing by prefix as digits are typed.
    local hashID = query:match("^#(%d+)$")
    if hashID then
        return CollectIDPrefix(hashID, out, nil)
    end

    local branchN = PrepareQuery(query)
    local m = 0

    -- A whole-number query filters FileDataIDs by prefix (exact match
    -- first), then any name-substring matches (icon names carry digit
    -- runs: _04, 2h, ...) follow.
    wipe(numericSeen)
    if query:match("^%d+$") then
        m = CollectIDPrefix(query, out, numericSeen)
    end

    if branchN == 0 then
        if m > 0 then return m end
        for i = 1, count do out[i] = i end
        return count
    end

    -- Term-by-term blob scans stamp records forward through each branch;
    -- a record completing every term of any branch gets the match stamp.
    matchGen = matchGen + 1
    local termStart = 1
    for b = 1, branchN do
        local nTerms = branchEnd[b] - termStart + 1
        markBase = markBase + nTerms + 1
        local altStart = termStart > 1 and (termEnd[termStart - 1] + 1) or 1
        for t = 1, nTerms do
            local termIdx = termStart + t - 1
            hitGen = hitGen + 1
            if termNeg[termIdx] then
                -- Stamp raw hits, then advance every UN-hit record.
                for a = altStart, termEnd[termIdx] do
                    if altIsPat[a] then
                        StampPattern(altText[a], altPat1[a], t, false, true)
                    else
                        StampWord(altText[a], t, false, true)
                    end
                end
                for rec = 1, count do
                    if hitStamp[rec] ~= hitGen
                       and (t == 1 or mark[rec] == markBase + (t - 1)) then
                        mark[rec] = markBase + t
                    end
                end
            else
                for a = altStart, termEnd[termIdx] do
                    if altIsPat[a] then
                        StampPattern(altText[a], altPat1[a], t, t == 1, false)
                    else
                        StampWord(altText[a], t, t == 1, false)
                        if altPlural[a] then
                            StampWord(altPlural[a], t, t == 1, false)
                        end
                    end
                end
            end
            altStart = termEnd[termIdx] + 1
        end
        for rec = 1, count do
            if mark[rec] == markBase + nTerms then
                matched[rec] = matchGen
            end
        end
        termStart = branchEnd[b] + 1
    end

    for rec = 1, count do
        if matched[rec] == matchGen and not numericSeen[rec] then
            m = m + 1
            out[m] = rec
        end
    end
    return m
end

-- Debug peek: file-locals invisible to ns walks, exposed for external
-- diagnostics. Shared references; do not mutate.
function IconSearch:_DebugPeek()
    return { blob = blob, offsets = offsets, tabs = tabs }
end

return IconSearch
