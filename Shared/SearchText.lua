local _, ns = ...

-- Pure-Lua text normalization and tokenization used by search/highlight.
-- Locale-aware variants (combining diacritics, CJK segmentation, etc.) will
-- land here as part of the localization plan. For now this provides ASCII
-- normalization and whitespace/punctuation tokenization.

---@class SearchText
local SearchText = {}

local slower = string.lower

---Lowercases the input. ASCII-safe; non-ASCII bytes pass through unchanged.
---@param s string|nil
---@return string
function SearchText.Normalize(s)
    if not s then return "" end
    return slower(s)
end

local function isAlphaNum(b)
    -- 0-9, A-Z, a-z
    return (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
end

---Splits the input into word tokens. Tokens are runs of ASCII alphanumeric
---characters; everything else acts as a separator.
---@param s string|nil
---@return string[]
function SearchText.Tokenize(s)
    local tokens = {}
    if not s or s == "" then return tokens end
    local n = #s
    local i = 1
    while i <= n do
        local b = s:byte(i)
        if isAlphaNum(b) then
            local j = i + 1
            while j <= n and isAlphaNum(s:byte(j)) do
                j = j + 1
            end
            tokens[#tokens + 1] = s:sub(i, j - 1)
            i = j
        else
            i = i + 1
        end
    end
    return tokens
end

---Convenience: normalize then tokenize.
---@param s string|nil
---@return string[]
function SearchText.NormalizeAndTokenize(s)
    return SearchText.Tokenize(SearchText.Normalize(s))
end

---Returns true if `s` contains only ASCII bytes (<= 127).
---@param s string|nil
---@return boolean
function SearchText.IsAscii(s)
    if not s then return true end
    for i = 1, #s do
        if s:byte(i) > 127 then return false end
    end
    return true
end

---@class MatchRange
---@field from integer 1-based byte offset where the run starts
---@field to integer 1-based byte offset where the run ends (inclusive)

local function rangeLen(r) return r.to - r.from + 1 end

local function bytesEqual(text, aStart, bStart, len)
    for i = 0, len - 1 do
        if text:byte(aStart + i) ~= text:byte(bStart + i) then
            return false
        end
    end
    return true
end

---Condenses scattered fuzzy match ranges into fewer, more natural ranges
---when a left-adjacent slide would produce identical text. Searching
---"Strike" in "Crusader Strike" typically returns per-letter ranges
---scattered across "Crusader" + "Strike"; this rewrites them to a single
---contiguous "Strike" range when possible.
---
---ASCII byte semantics. UTF-8-aware condensation will land alongside
---the localization plan's `SearchText` work.
---
---@param text string         the original text the ranges index into
---@param matchRanges MatchRange[] sorted left-to-right
---@return MatchRange[]
function SearchText.CondenseMatchRanges(text, matchRanges)
    if not matchRanges or #matchRanges < 2 then return matchRanges or {} end
    local stack = {}
    for i = #matchRanges, 1, -1 do
        stack[#stack + 1] = matchRanges[i]
    end
    local out = {}
    while #stack > 1 do
        local current = stack[#stack]
        stack[#stack] = nil
        local nextRange = stack[#stack]
        local currentLen = rangeLen(current)
        local slideStart = nextRange.from - currentLen
        local slideEnd = nextRange.from - 1
        local canSlide = slideStart >= 1 and slideEnd >= slideStart
        if canSlide and currentLen == (slideEnd - slideStart + 1) then
            if bytesEqual(text, current.from, slideStart, currentLen) then
                stack[#stack] = { from = slideStart, to = nextRange.to }
            else
                out[#out + 1] = current
            end
        else
            out[#out + 1] = current
        end
    end
    out[#out + 1] = stack[1]
    return out
end

---Returns a single contiguous range covering the first case-insensitive
---occurrence of `query` in `text`, or nil if there is no contiguous
---occurrence. Useful as a fast-path before falling back to fuzzy/scattered
---match logic.
---@param text string?
---@param query string?
---@return MatchRange?
function SearchText.FindContiguous(text, query)
    if not text or not query or query == "" then return nil end
    local pos = text:lower():find(query:lower(), 1, true)
    if not pos then return nil end
    return { from = pos, to = pos + #query - 1 }
end

if ns then ns.SearchText = SearchText end
return SearchText
