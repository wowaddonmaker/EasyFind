local _, ns = ...

-- Text normalization, tokenization, and matching used by search/highlight.
-- Handles UTF-8 byte streams for non-English clients: Latin-1 Supplement
-- and Latin Extended-A casing (German, French, Spanish, Portuguese, etc.),
-- so "frostbolt" matches "Frostbolt".
--
-- WoW runs Lua 5.1 with no native utf8 library, so this module walks the
-- byte stream by hand. Hot paths cache results on the source entry.
--
-- CJK and combining-diacritics support are not implemented yet; CJK
-- queries will tokenize per ideograph (each codepoint becomes a token),
-- which is acceptable for substring matching but not for word-aware
-- scoring. Revisit when CJK locales are prioritized.

---@class SearchText
local SearchText = {}

local sbyte, schar = string.byte, string.char
local sfind = string.find
local sslower = string.lower

-- UTF-8 decoder. Reads a codepoint starting at byte index `i` in `s`,
-- returns (codepoint, next_index). Invalid sequences yield the raw byte.
local function utf8At(s, i)
    local b = sbyte(s, i)
    if not b then return nil, i end
    if b < 0x80 then return b, i + 1 end
    if b < 0xC0 then return b, i + 1 end -- invalid lead, pass through
    local cp, len
    if b < 0xE0 then
        cp = b - 0xC0
        len = 2
    elseif b < 0xF0 then
        cp = b - 0xE0
        len = 3
    else
        cp = b - 0xF0
        len = 4
    end
    for j = 1, len - 1 do
        local cb = sbyte(s, i + j)
        if not cb or cb < 0x80 or cb >= 0xC0 then
            return b, i + 1 -- malformed; bail
        end
        cp = cp * 64 + (cb - 0x80)
    end
    return cp, i + len
end

local mfloor = math.floor
local function utf8Encode(cp)
    if cp < 0x80 then return schar(cp) end
    if cp < 0x800 then
        return schar(0xC0 + mfloor(cp / 64), 0x80 + (cp % 64))
    end
    if cp < 0x10000 then
        return schar(
            0xE0 + mfloor(cp / 4096),
            0x80 + mfloor(cp / 64) % 64,
            0x80 + (cp % 64)
        )
    end
    return schar(
        0xF0 + mfloor(cp / 262144),
        0x80 + mfloor(cp / 4096) % 64,
        0x80 + mfloor(cp / 64) % 64,
        0x80 + (cp % 64)
    )
end

-- Codepoint -> lowercase codepoint. Covers ASCII, Latin-1 Supplement
-- (À-Þ), and Latin Extended-A (Ā-ſ). Anything else returns its input.
-- Generated from Unicode Case_Folding (simple folds only).
local function lowerCP(cp)
    if cp < 0x80 then
        if cp >= 0x41 and cp <= 0x5A then return cp + 32 end
        return cp
    end
    -- Latin-1 Supplement uppercase: À (0xC0) .. Þ (0xDE), excluding × (0xD7)
    if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 then
        return cp + 32
    end
    -- Latin Extended-A: pairs are typically (even=upper, odd=lower) from
    -- 0x0100 to 0x017F. Handle the common patterns; exceptions follow.
    if cp >= 0x0100 and cp <= 0x0137 then
        if cp % 2 == 0 then return cp + 1 end
        return cp
    end
    if cp >= 0x0139 and cp <= 0x0148 then
        if cp % 2 == 1 then return cp + 1 end
        return cp
    end
    if cp >= 0x014A and cp <= 0x0177 then
        if cp % 2 == 0 then return cp + 1 end
        return cp
    end
    -- 0x0178 (Ÿ) -> 0x00FF (ÿ): the one Latin-1 cap with a non-adjacent
    -- lowercase due to history.
    if cp == 0x0178 then return 0x00FF end
    if cp >= 0x0179 and cp <= 0x017E then
        if cp % 2 == 1 then return cp + 1 end
        return cp
    end
    return cp
end

---Lowercases the input. UTF-8 aware for Latin-1 Supplement and Latin
---Extended-A; CJK/Cyrillic/other scripts pass through unchanged because
---their casing rules aren't useful for search-style matching.
---@param s string|nil
---@return string
function SearchText.Normalize(s)
    if not s or s == "" then return "" end
    -- ASCII fast path
    if not sfind(s, "[\128-\255]") then return sslower(s) end
    -- Walk codepoints, lowercase each.
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local cp, ni = utf8At(s, i)
        out[#out + 1] = utf8Encode(lowerCP(cp))
        i = ni
    end
    return table.concat(out)
end

-- Codepoint -> is this a word-character (letter/digit)?
-- ASCII 0-9, A-Z, a-z, _ are word characters; Latin-1 Supplement letters
-- (À-ÿ except multiplication × and division ÷) are too; Latin Extended-A
-- range likewise. Other scripts default to word-character so non-Latin
-- search ("어둠" / "Тёмный") tokenizes as the user expects.
local function isWordCP(cp)
    if cp < 0x80 then
        return (cp >= 0x30 and cp <= 0x39)  -- 0-9
            or (cp >= 0x41 and cp <= 0x5A)  -- A-Z
            or (cp >= 0x61 and cp <= 0x7A)  -- a-z
            or cp == 0x27                    -- '
            or cp == 0x5F                    -- _
    end
    -- Skip standard punctuation in higher planes
    if cp == 0xD7 or cp == 0xF7 then return false end -- × ÷
    if cp >= 0x2000 and cp <= 0x206F then return false end -- general punctuation
    if cp >= 0x3000 and cp <= 0x303F then return false end -- CJK symbols/punct
    return true
end

---Splits the input into word tokens. Word characters include ASCII
---alphanumerics, apostrophes, Latin-1 Supplement letters, and any non-ASCII
---codepoint outside known punctuation blocks (so CJK ideographs tokenize as words).
---@param s string|nil
---@return string[]
function SearchText.Tokenize(s)
    local tokens = {}
    if not s or s == "" then return tokens end
    local n = #s
    local i = 1
    while i <= n do
        local cp, ni = utf8At(s, i)
        if cp and isWordCP(cp) then
            local start = i
            i = ni
            while i <= n do
                local cp2, ni2 = utf8At(s, i)
                if not cp2 or not isWordCP(cp2) then break end
                i = ni2
            end
            tokens[#tokens + 1] = s:sub(start, i - 1)
        else
            i = ni
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
    return sfind(s, "[\128-\255]") == nil
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
---
---The returned range indexes into the NORMALIZED text, not the original.
---For ASCII inputs the byte offsets coincide; for UTF-8 inputs they may
---differ if the original had uppercase non-ASCII (lowercase doesn't change
---byte count for Latin-1 Supplement / Extended-A, so this is usually
---safe). Callers needing original-byte ranges should normalize first.
---@param text string?
---@param query string?
---@return MatchRange?
function SearchText.FindContiguous(text, query)
    if not text or not query or query == "" then return nil end
    local normText = SearchText.Normalize(text)
    local normQuery = SearchText.Normalize(query)
    local pos = normText:find(normQuery, 1, true)
    if not pos then return nil end
    return { from = pos, to = pos + #normQuery - 1 }
end

if ns then ns.SearchText = SearchText end
return SearchText
