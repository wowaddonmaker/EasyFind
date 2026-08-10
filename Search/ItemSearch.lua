local _, ns = ...

-- Catalog item search: scans the packed item blob (Database/ItemData.lua,
-- ~175k items). The blob is ONE string, one record per
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
local pairs = Utils.pairs or pairs
local tonumber = tonumber
local CreateFrame = CreateFrame
local C_Item = C_Item
local strtrim = strtrim

local MIN_QUERY = 3      -- below this the catalog matches too much to be useful
local SCAN_CAP = 250     -- candidate ceiling per keystroke; sort/cap keeps the best

local blob, blobLen

-- Catalog type buckets -> the Item.ClassID values each covers. This is the
-- curated set the filter flyout exposes; the long tail of tiny classes
-- (keys, projectiles, tokens, pets, money, enhancements, profession) folds
-- into "misc". Keep in sync with the flyout order in CatalogOptions.lua.
local BUCKETS = {
    armor      = { 4 },
    weapon     = { 2 },
    consumable = { 0 },
    tradegoods = { 7, 5 },   -- Trade Goods + Reagent (crafting mats)
    recipe     = { 9 },
    gem        = { 3 },
    quest      = { 12 },
    housing    = { 20 },
    glyph      = { 16 },
    container  = { 1 },
    misc       = { 15, 8, 13, 6, 10, 17, 18, 19 },
}
ns.CATALOG_TYPE_BUCKETS = BUCKETS

-- Filter state, rebuilt from db on change (and lazily on first scan).
-- classDisabled[classID]=true hides that class; qualityTier>0 keeps only tiered
-- reagents of that tier (non-tiered items always pass). filtersActive gates the
-- extra per-candidate field parse so the all-on default stays on the fast path.
local classDisabled, qualityTier, filtersActive, filtersReady

function ItemSearch:RefreshFilters()
    local db = EasyFind and EasyFind.db
    local typeFilters = db and db.catalogTypeFilters
    classDisabled = {}
    local anyDisabled = false
    for key, classes in pairs(BUCKETS) do
        if typeFilters and typeFilters[key] == false then
            anyDisabled = true
            for i = 1, #classes do classDisabled[classes[i]] = true end
        end
    end
    qualityTier = (db and db.catalogQualityTier) or 0
    filtersActive = anyDisabled or qualityTier > 0
    filtersReady = true
end

-- A catalog row resolves its official name from C_Item at render; an item the
-- client has not cached yet falls back to the lowercase blob name. RowContent
-- reports those here: request the data and, once ITEM_DATA_LOAD_RESULT lands,
-- re-render the open query so the proper name replaces the fallback. Debounced
-- so a burst of loads triggers a single re-render.
local pendingLoads, attemptedLoads, loadListener, refreshTimer

local function ScheduleCatalogRefresh()
    if refreshTimer then return end
    refreshTimer = Utils.SafeAfter(0.15, function()
        refreshTimer = nil
        local Search = ns.Search
        local sf = Search and Search.GetSearchFrame and Search:GetSearchFrame()
        local eb = sf and sf.editBox
        if not eb then return end
        local full = eb:GetText() or ""
        local cursor = eb:GetCursorPosition() or #full
        local typed = strtrim(ssub(full, 1, cursor))
        if typed ~= "" then Search:OnSearchTextChanged(typed, true) end
    end)
end

-- Does this client know the item at all? GetItemInfoInstant answers from the
-- client's own item DB with no server round trip and no caching requirement, so
-- nil means the id is in our shipped blob but not in this build (removed item,
-- or otherwise unavailable here). Those rows can never resolve a name, an icon,
-- or a chat link, so they are dropped from results rather than shown as a
-- lowercase name with a question mark and a Send-link hint that does nothing.
function ItemSearch:IsResolvable(itemID)
    if not itemID then return false end
    if not (C_Item and C_Item.GetItemInfoInstant) then return true end
    return C_Item.GetItemInfoInstant(itemID) ~= nil
end

function ItemSearch:NoteUncachedItem(itemID)
    if not itemID then return end
    -- ONE request per item per session. The listener clears the pending flag on
    -- any result, so without this an item whose name never resolves is
    -- re-requested by every re-render, and every result schedules another
    -- re-render: a ~0.15s loop that re-runs the whole search forever, pinning
    -- the frame rate and snapping the results scroll back to the top.
    attemptedLoads = attemptedLoads or {}
    if attemptedLoads[itemID] then return end
    attemptedLoads[itemID] = true
    pendingLoads = pendingLoads or {}
    pendingLoads[itemID] = true
    if not loadListener then
        loadListener = CreateFrame("Frame")
        loadListener:RegisterEvent("ITEM_DATA_LOAD_RESULT")
        loadListener:SetScript("OnEvent", function(_, _, loadedID, success)
            if pendingLoads and pendingLoads[loadedID] then
                pendingLoads[loadedID] = nil
                -- A failed load cannot change what renders; refreshing on it
                -- is a re-render that shows the same fallback name again.
                if success ~= false then ScheduleCatalogRefresh() end
            end
        end)
    end
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

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
    if not filtersReady then self:RefreshFilters() end
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
            -- Type + quality-tier filters (fields 6/7), parsed only when a filter
            -- is active so the all-on default keeps the 3-field fast path.
            local passes = true
            if filtersActive and t3 then
                local t4 = sfind(blob, "\t", t3 + 1, true)
                local t5 = t4 and sfind(blob, "\t", t4 + 1, true)
                if t5 then
                    local t6 = sfind(blob, "\t", t5 + 1, true)
                    local class = tonumber(ssub(blob, t5 + 1, (t6 or (rEnd + 1)) - 1))
                    if class and classDisabled[class] then
                        passes = false
                    elseif qualityTier > 0 and t6 then
                        local qt = tonumber(ssub(blob, t6 + 1, rEnd))
                        if qt and qt > 0 and qt ~= qualityTier then passes = false end
                    end
                end
            end
            local score = passes and scoreName and scoreName(nameLower, ql, qLen)
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
                            lookupRow = true,
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
