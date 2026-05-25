local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapSearchData = ns.MapSearchData
local SearchText = ns.SearchText

local pairs, ipairs = Utils.pairs, Utils.ipairs
local tinsert = Utils.tinsert
local sfind = Utils.sfind
-- UTF-8 aware lowercase so localized map/POI names (Eisenschmiede,
-- Élwynn-Wald, etc.) compare against the user's typed query correctly.
local slower = SearchText.Normalize

local CATEGORIES = MapSearchData.CATEGORIES

local wipe = wipe


local GetCategoryIcon = MapSearch.GetCategoryIcon
local GetFilterBucket = MapSearch.GetFilterBucket

local function GetMapPinKey(data)
    return MapSearch:GetMapPinKey(data)
end

local function MapTabFlightPathsEnabled()
    local filters = EasyFind and EasyFind.db and EasyFind.db.mapTabFilters
    return filters and filters.flightpath ~= false
end
local scratchTables = {}
local function NewScratchTable()
    local tbl = {}
    scratchTables[#scratchTables + 1] = tbl
    return tbl
end

local function WipeScratchTables()
    for i = 1, #scratchTables do
        wipe(scratchTables[i])
    end
end


local sgsub = string.gsub

-- Handles "Nexus-Point Xenas" vs "Nexus Point Xenas" for instance matching.
local function normalizeName(name)
    local n = slower(name)
    n = sgsub(n, "%-", " ")
    n = sgsub(n, "%s+", " ")
    return n
end

local function GetNameLower(entry)
    local nameLower = entry.nameLower
    if not nameLower then
        nameLower = slower(entry.name or "")
        entry.nameLower = nameLower
    end
    return nameLower
end

local function GetNameNorm(entry)
    local nameNorm = entry.nameNorm
    if not nameNorm then
        nameNorm = normalizeName(entry.name or "")
        entry.nameNorm = nameNorm
    end
    return nameNorm
end

local function PreparePOI(entry)
    if not entry then return entry end
    GetNameLower(entry)
    if entry.keywords and not entry.kwLower then
        local kwLower = {}
        for i = 1, #entry.keywords do
            kwLower[i] = slower(entry.keywords[i])
        end
        entry.kwLower = kwLower
    end
    if entry.isDungeonEntrance then
        GetNameNorm(entry)
    end
    return entry
end

local function PreparePOIList(entries)
    for i = 1, #entries do
        PreparePOI(entries[i])
    end
    return entries
end

local function EnrichZoneWithEntrance(poi, entrance)
    poi.name = entrance.name
    poi.nameLower = GetNameLower(entrance)
    poi.nameNorm = GetNameNorm(entrance)
    poi.kwLower = entrance.kwLower
    poi.entranceX = entrance.x
    poi.entranceY = entrance.y
    poi.entranceMapID = entrance.entranceMapID
    poi.entranceIcon = entrance.icon
    poi.entranceCategory = entrance.category
    poi.category = entrance.category
    poi.icon = entrance.icon
end

local reuseEntranceLookup = NewScratchTable()
local function BuildEntranceLookup(entries)
    wipe(reuseEntranceLookup)
    for _, entry in ipairs(entries) do
        if entry.isDungeonEntrance and entry.x and entry.y then
            reuseEntranceLookup[GetNameLower(entry)] = entry
        end
    end
    return reuseEntranceLookup
end

local Search = ns.MapSearchSearch or {}
ns.MapSearchSearch = Search
Search.isGlobalSearch = Search.isGlobalSearch or false

function MapSearch:IsGlobalSearchActive()
    return Search.isGlobalSearch
end
Search.rareTrackCache = Search.rareTrackCache or {}
Search.rareDeadGUIDs = Search.rareDeadGUIDs or {}
Search.rareTrackMapID = Search.rareTrackMapID
MapSearch._rareTrackCache = Search.rareTrackCache
MapSearch._rareDeadGUIDs = Search.rareDeadGUIDs

local reuseAllPOIs = NewScratchTable()
local reuseZoneNames = NewScratchTable()
local reuseExistingNames = NewScratchTable()
local reuseFilteredResults = NewScratchTable()
local reusePinnedKeys = NewScratchTable()
local reusePinned = NewScratchTable()
local reuseFiltered = NewScratchTable()
local reuseSearchResults = NewScratchTable()
local reuseSearchSeen = NewScratchTable()
local reuseSearchDuplicates = NewScratchTable()
local reuseInstanceNameNorm = NewScratchTable()
local reuseUISearchPOIs = NewScratchTable()
local reuseUISearchExistingNames = NewScratchTable()
local reuseUISearchZoneNames = NewScratchTable()
local reuseUISearchFiltered = NewScratchTable()
local reuseUISearchResults = NewScratchTable()
local reuseUISearchResultData = NewScratchTable()
local UI_MAP_RESULT_CAP = 60


function MapSearch:GetCategoryMatch(query)
    query = slower(query):match("^(.-)%s*$")
    if ns.Database and ns.Database.NormalizeSearchQuery then
        query = ns.Database:NormalizeSearchQuery(query)
    end
    local matchedCategory = nil
    local matchScore = 0
    local isExactCategoryMatch = false

    for catName, catData in pairs(CATEGORIES) do
        for _, keyword in ipairs(catData.keywords) do
            local kw = slower(keyword)
            if kw == query then
                return catName, 100, true
            elseif sfind(kw, query, 1, true) and #query >= 3 then
                local score = #query / #kw * 50
                if score > matchScore then
                    matchScore = score
                    matchedCategory = catName
                end
            end
        end
    end

    return matchedCategory, matchScore, isExactCategoryMatch
end

function MapSearch:GetRelatedCategories(category)
    local related = {category}
    local catData = CATEGORIES[category]

    -- Parent only, not siblings: "pvp" should not show "auction house".
    if catData and catData.parent then
        tinsert(related, catData.parent)
    end

    for catName, data in pairs(CATEGORIES) do
        if data.parent == category then
            tinsert(related, catName)
        end
    end

    return related
end



Search.GetCategoryIcon = GetCategoryIcon
Search.GetFilterBucket = GetFilterBucket
Search.GetMapPinKey = GetMapPinKey
Search.MapTabFlightPathsEnabled = MapTabFlightPathsEnabled
Search.NewScratchTable = NewScratchTable
Search.WipeScratchTables = WipeScratchTables
Search.NormalizeName = normalizeName
Search.GetNameLower = GetNameLower
Search.GetNameNorm = GetNameNorm
Search.PreparePOI = PreparePOI
Search.PreparePOIList = PreparePOIList
Search.EnrichZoneWithEntrance = EnrichZoneWithEntrance
Search.BuildEntranceLookup = BuildEntranceLookup
Search.reuseAllPOIs = reuseAllPOIs
Search.reuseZoneNames = reuseZoneNames
Search.reuseExistingNames = reuseExistingNames
Search.reuseFilteredResults = reuseFilteredResults
Search.reusePinnedKeys = reusePinnedKeys
Search.reusePinned = reusePinned
Search.reuseFiltered = reuseFiltered
Search.reuseSearchResults = reuseSearchResults
Search.reuseSearchSeen = reuseSearchSeen
Search.reuseSearchDuplicates = reuseSearchDuplicates
Search.reuseInstanceNameNorm = reuseInstanceNameNorm
Search.reuseUISearchPOIs = reuseUISearchPOIs
Search.reuseUISearchExistingNames = reuseUISearchExistingNames
Search.reuseUISearchZoneNames = reuseUISearchZoneNames
Search.reuseUISearchFiltered = reuseUISearchFiltered
Search.reuseUISearchResults = reuseUISearchResults
Search.reuseUISearchResultData = reuseUISearchResultData
Search.UI_MAP_RESULT_CAP = UI_MAP_RESULT_CAP


