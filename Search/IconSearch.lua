local _, ns = ...

-- Icon search data layer (GitHub #22): parses the packed icon blob
-- (Database/IconData.lua, ~33k icons) into two parallel arrays once, on the
-- first @icons use, and filters them per keystroke for the icon grid.
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
--   135274 or #135274  a FileDataID (# forces the ID-only reading)
--   spell:133 item:6948 achievement:12   the game's own hyperlink types:
--                      the icon that spell/item/achievement uses
--                      (shift-clicking a chat link types these for you)

local IconSearch = {}
ns.IconSearch = IconSearch

local Utils = ns.Utils
local sfind, ssub = Utils.sfind, Utils.ssub
local slower = Utils.slower or string.lower
local tonumber = tonumber
local wipe = wipe

-- Parallel arrays: names[i] / ids[i]. Built lazily; ~33k entries each.
local names, ids, total
-- FileDataID -> master index. Built lazily on the first ID-form query.
local idToIndex

local function EnsureIndex()
    if names then return total end
    local blob = ns.ICON_SEARCH_BLOB
    if type(blob) ~= "string" then return 0 end
    names, ids, total = {}, {}, 0
    local blobLen = #blob
    local pos = 1
    while pos <= blobLen do
        local nl = sfind(blob, "\n", pos, true) or (blobLen + 1)
        local tab = sfind(blob, "\t", pos, true)
        if tab and tab < nl then
            local id = tonumber(ssub(blob, tab + 1, nl - 1))
            if id then
                total = total + 1
                names[total] = ssub(blob, pos, tab - 1)
                ids[total] = id
            end
        end
        pos = nl + 1
    end
    return total
end

local function IndexOfFileID(fdid)
    if not fdid then return nil end
    if not idToIndex then
        idToIndex = {}
        for i = 1, EnsureIndex() do
            idToIndex[ids[i]] = i
        end
    end
    return idToIndex[fdid]
end

function IconSearch:GetIcon(index)
    if not names then return nil end
    return names[index], ids[index]
end

function IconSearch:GetTotal()
    return EnsureIndex()
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

-- A word carrying * or ? becomes an anchored whole-name wildcard. Lua magic
-- characters are neutralized first, then the wildcards expand.
local function GlobToPattern(word)
    local pat = word:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    pat = pat:gsub("%*", ".*"):gsub("%?", ".")
    return "^" .. pat .. "$"
end

-- Parsed query scratch, module-level (this runs per keystroke). Three
-- levels flattened into parallel arrays:
--   branches (comma) OR'd -> terms (space) AND'd -> alternates (/) OR'd
-- branch b owns terms branchEnd[b-1]+1 .. branchEnd[b]; term t owns
-- alternates termEnd[t-1]+1 .. termEnd[t].
local altText, altPlural, altIsPat = {}, {}, {}
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
            altText[altN] = GlobToPattern(alt)
            altIsPat[altN] = true
            altPlural[altN] = nil
        else
            altText[altN] = alt
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

local function NameMatchesTerm(name, t, altStart)
    local hit = false
    for a = altStart, termEnd[t] do
        if altIsPat[a] then
            if sfind(name, altText[a]) then
                hit = true
                break
            end
        elseif sfind(name, altText[a], 1, true)
            or (altPlural[a] and sfind(name, altPlural[a], 1, true)) then
            hit = true
            break
        end
    end
    if termNeg[t] then return not hit end
    return hit
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

    -- #ID: explicitly a FileDataID, nothing else.
    local hashID = query:match("^#(%d+)$")
    if hashID then
        local idx = IndexOfFileID(tonumber(hashID))
        if idx then
            out[1] = idx
            return 1
        end
        return 0
    end

    local branchN = PrepareQuery(query)
    local m = 0

    -- A whole-number query is first a FileDataID lookup; any name-substring
    -- matches (icon names carry digit runs: _04, 2h, ...) follow it.
    local numericIdx
    if query:match("^%d+$") then
        numericIdx = IndexOfFileID(tonumber(query))
        if numericIdx then
            m = 1
            out[1] = numericIdx
        end
    end

    if branchN == 0 then
        if numericIdx then return m end
        for i = 1, count do out[i] = i end
        return count
    end

    for i = 1, count do
        local name = names[i]
        local matched = false
        local termStart = 1
        for b = 1, branchN do
            local allOk = true
            local altStart = termStart > 1 and (termEnd[termStart - 1] + 1) or 1
            for t = termStart, branchEnd[b] do
                if not NameMatchesTerm(name, t, altStart) then
                    allOk = false
                    break
                end
                altStart = termEnd[t] + 1
            end
            if allOk then
                matched = true
                break
            end
            termStart = branchEnd[b] + 1
        end
        if matched and i ~= numericIdx then
            m = m + 1
            out[m] = i
        end
    end
    return m
end

return IconSearch
