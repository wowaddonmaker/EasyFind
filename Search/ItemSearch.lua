local _, ns = ...

-- Catalog item search: scans the packed item blob (Database/ItemData.lua,
-- generated from DB2 -- ~175k items). The blob is ONE string, one record per
-- line, tab-separated: namelower \t itemID \t quality \t expansion \t ilvl.
-- Search finds the query in it at C speed and materializes only the handful of
-- matches that place, so the whole catalog costs one resident string, never a
-- table per item.
--
-- English-primary: the blob's names are enUS. Display name and icon resolve
-- live per shown result (C_Item), so the row shows the localized name.

local ItemSearch = {}
ns.ItemSearch = ItemSearch

local Utils = ns.Utils
local sfind, ssub = Utils.sfind, Utils.ssub
local slower = Utils.slower or string.lower
local tonumber = tonumber

local MIN_QUERY = 3      -- below this the catalog matches too much to be useful
local SCAN_CAP = 250     -- candidate ceiling per keystroke; sort/cap keeps the best

local blob, blobLen

local function EnsureBlob()
    if blob then return blob end
    blob = ns.ITEM_SEARCH_BLOB
    if type(blob) ~= "string" then blob = nil; return nil end
    blobLen = #blob
    return blob
end

-- The record (line) containing byte position `s`. Item names are <= ~80 chars,
-- so the line start is a bounded backward scan -- no full-string copy.
local function RecordAt(s)
    local e = sfind(blob, "\n", s, true) or (blobLen + 1)
    local from = s - 100
    if from < 1 then from = 1 end
    local lastNL, p = nil, from
    while true do
        local nl = sfind(blob, "\n", p, true)
        if not nl or nl >= s then break end
        lastNL, p = nl, nl + 1
    end
    local start = lastNL and (lastNL + 1) or (from == 1 and 1 or from)
    return start, e - 1
end

-- Returns scored candidate entries { data = <item>, score = N }, or nil.
-- `scoreName(nameLower, queryLower, qLen)` ranks each match so items interleave
-- with the rest of the results by the same relevance rule.
function ItemSearch:Search(query, scoreName)
    if not query or #query < MIN_QUERY then return nil end
    if not EnsureBlob() then return nil end
    local ql = slower(query)
    local qLen = #ql
    local out, n = {}, 0
    local pos, seen = 1, nil
    while n < SCAN_CAP do
        local s = sfind(blob, ql, pos, true)
        if not s then break end
        local rStart, rEnd = RecordAt(s)
        -- Fields: namelower \t id \t quality \t exp \t ilvl
        local t1 = sfind(blob, "\t", rStart, true)
        if t1 and t1 <= rEnd then
            local nameLower = ssub(blob, rStart, t1 - 1)
            local t2 = sfind(blob, "\t", t1 + 1, true)
            local t3 = t2 and sfind(blob, "\t", t2 + 1, true)
            local itemID = tonumber(ssub(blob, t1 + 1, (t2 or (rEnd + 1)) - 1))
            local quality = t2 and tonumber(ssub(blob, t2 + 1, (t3 or (rEnd + 1)) - 1))
            local score = scoreName and scoreName(nameLower, ql, qLen)
            if itemID and score and score > 0 then
                seen = seen or {}
                if not seen[itemID] then
                    seen[itemID] = true
                    n = n + 1
                    out[n] = {
                        score = score,
                        data = {
                            itemID = itemID,
                            catalogItem = true,
                            category = "Item",
                            name = nameLower,   -- display name resolves live at render
                            nameLower = nameLower,
                            quality = quality,
                        },
                    }
                end
            end
        end
        pos = (rEnd + 2)
    end
    return n > 0 and out or nil
end

return ItemSearch
