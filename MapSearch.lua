local _, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local Utils     = ns.Utils
local MapUtils  = ns.MapUtils
local DebugPrint = Utils.DebugPrint
local pairs, ipairs, type, select = Utils.pairs, Utils.ipairs, Utils.type, Utils.select
local tinsert, tsort, tconcat, tremove = Utils.tinsert, Utils.tsort, Utils.tconcat, Utils.tremove
local sfind, slower, ssub = Utils.sfind, Utils.slower, Utils.ssub
local mmin, mmax, mpi, mfloor = Utils.mmin, Utils.mmax, Utils.mpi, Utils.mfloor
local pcall, tostring = Utils.pcall, Utils.tostring
local GetMapParentID = MapUtils.GetParentMapID
local GetMapPath = MapUtils.GetMapPath
local ZONE_ABBREVIATIONS = MapUtils.ZONE_ABBREVIATIONS

local GOLD_COLOR = ns.GOLD_COLOR
local YELLOW_HIGHLIGHT = ns.YELLOW_HIGHLIGHT
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local UIParent           = UIParent
local IsMouseButtonDown  = IsMouseButtonDown
local hooksecurefunc     = hooksecurefunc
local wipe               = wipe

-- Cache C_* API functions at file scope to get unhooked copies
local GetMapInfo             = C_Map.GetMapInfo
local GetMapChildrenInfo     = C_Map.GetMapChildrenInfo
local GetBestMapForUnit      = C_Map.GetBestMapForUnit
local GetMapInfoAtPosition   = C_Map.GetMapInfoAtPosition
local SetUserWaypoint        = C_Map.SetUserWaypoint
local GetAreaPOIForMap       = C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap
local GetAreaPOIInfo         = C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo
local GetDelvesForMap        = C_AreaPoiInfo and C_AreaPoiInfo.GetDelvesForMap
local GetVignettes           = C_VignetteInfo and C_VignetteInfo.GetVignettes
local GetVignetteInfo        = C_VignetteInfo and C_VignetteInfo.GetVignetteInfo
local GetVignettePosition    = C_VignetteInfo and C_VignetteInfo.GetVignettePosition
local SetSuperTrackedVignette = C_SuperTrack and C_SuperTrack.SetSuperTrackedVignette
local GetDungeonEntrancesForMap   = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
local HasUserWaypoint        = C_Map.HasUserWaypoint
local ClearUserWaypoint      = C_Map.ClearUserWaypoint
local GetMapRectOnMap        = C_Map.GetMapRectOnMap
local GetMapHighlightInfoAtPosition = C_Map.GetMapHighlightInfoAtPosition
local GetPlayerMapPosition          = C_Map.GetPlayerMapPosition

local sgsub = string.gsub

-- Normalize a name for instance matching: lowercase, hyphens to spaces, collapse whitespace.
-- Handles cases like "Nexus-Point Xenas" vs "Nexus Point Xenas".
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

-- Build a name → entrance lookup from an array of POI entries.
-- Reuses reuseEntranceLookup to avoid allocation.
local reuseEntranceLookup = {}
local function BuildEntranceLookup(entries)
    wipe(reuseEntranceLookup)
    for _, entry in ipairs(entries) do
        if entry.isDungeonEntrance and entry.x and entry.y then
            reuseEntranceLookup[GetNameLower(entry)] = entry
        end
    end
    return reuseEntranceLookup
end

local STAR_GLOW_TEXTURE = "Interface\\Cooldown\\star4"

-- INDICATOR THEME DEFINITIONS
local INDICATOR_STYLES = {
    ["Classic Quest Arrow"] = {
        texture = "Interface\\MINIMAP\\MiniMap-QuestArrow",
        texCoord = nil,
        preRotated = false,  -- Needs mpi rotation to point down
    },
    ["EasyFind Arrow"] = {
        texture = "Interface\\AddOns\\EasyFind\\Images\\arrow-hq",
        texCoord = nil,
        preRotated = true,   -- Already points down, no rotation needed
    },
    ["Minimap Player Arrow"] = {
        texture = "Interface\\Minimap\\MinimapArrow",
        texCoord = nil,
        preRotated = false,
    },
    ["Low-res Gauntlet"] = {
        texture = "Interface\\CURSOR\\Point",
        texCoord = nil,
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,   -- Shift right to center fingertip
        offsetY = 0,  -- Shift down to center fingertip
    },
    ["HD Gauntlet"] = {
        texture = 6116532,  -- interface/cursor/crosshair/uicastcrosshair2x.blp
        texCoord = {0.000, 0.240, 0.000, 0.420},
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,
        offsetY = 0,
    },
}
-- Indicator color presets
local INDICATOR_COLORS = {
    ["Yellow"]  = {1.0, 1.0, 0.0},
    ["Gold"]    = {1.0, 0.82, 0.0},
    ["Orange"]  = {1.0, 0.5, 0.0},
    ["Red"]     = {1.0, 0.2, 0.2},
    ["Green"]   = {0.2, 1.0, 0.2},
    ["Blue"]    = {0.3, 0.6, 1.0},
    ["Purple"]  = {0.7, 0.3, 1.0},
    ["White"]   = {1.0, 1.0, 1.0},
}

local function GetIndicatorColor()
    local colorName = EasyFind.db.indicatorColor or "Yellow"
    return INDICATOR_COLORS[colorName] or INDICATOR_COLORS["Yellow"]
end

-- Store in namespace so all modules can access it
ns.GetIndicatorTexture = function()
    local style = EasyFind.db.indicatorStyle or "EasyFind Arrow"
    return INDICATOR_STYLES[style] or INDICATOR_STYLES["EasyFind Arrow"]
end
ns.GetIndicatorColor = GetIndicatorColor
ns.INDICATOR_STYLES = INDICATOR_STYLES
ns.INDICATOR_COLORS = INDICATOR_COLORS

local GetIndicatorTexture = ns.GetIndicatorTexture

-- UNIFIED SIZING - all values are in UI coordinate units (same as UIParent).
-- Map code converts to canvas units via ns.UIToCanvas() so visual size matches.
-- Changing a value here changes BOTH map and UI icons uniformly.

-- Single-pin group (the indicator icon + pin + highlight are always sized together)
ns.ICON_SIZE         = 48   -- Indicator icon (arrow/pointer/cursor)
ns.ICON_GLOW_SIZE    = 68   -- Glow behind indicator icon
ns.PIN_SIZE          = 28   -- Map pin icon (category icon, e.g. auction house)
ns.PIN_GLOW_SIZE     = 40   -- Map pin glow
ns.HIGHLIGHT_SIZE    = 30   -- Yellow highlight border box

-- Multi-pin (slightly smaller so clusters don't overlap)
ns.MULTI_SCALE       = 1.0

-- Zone indicator (continent maps)
ns.ZONE_ICON_SIZE      = 48
ns.ZONE_ICON_GLOW_SIZE = 68

-- Breadcrumb indicator
ns.BREADCRUMB_SIZE   = 48

local ANIM_DURATION = 0.5

-- Convert a size in UI units to canvas units so it appears the same visual
-- size as a same-valued element on UIParent.
-- WoW's map zooms by making the canvas LARGER, not by changing scale.
-- So the conversion is: canvasWidth / viewportWidth (canvas units per screen unit).
-- @param uiSize number  size in UI coordinate units
-- @return number  equivalent canvas coordinate units
function ns.UIToCanvas(uiSize)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc or not sc.Child then return uiSize end
    local canvasW  = sc.Child:GetWidth()
    local viewportW = sc:GetWidth()
    if not canvasW or canvasW == 0 or not viewportW or viewportW == 0 then
        return uiSize
    end
    return uiSize * (canvasW / viewportW)
end

-- SHARED ICON CREATION / UPDATE
-- Every indicator icon in the addon (map search, zone search, UI search, breadcrumb)
-- MUST use these two functions so they all look identical.

-- Create icon + glow textures on a parent frame.
-- Returns nothing; sets parentFrame.indicator and parentFrame.glow.
-- @param parentFrame Frame  - the frame the icon sits in
-- @param iconSize number|nil  - override size (defaults to ns.ICON_SIZE)
-- @param glowSize number|nil  - override glow (defaults to ns.ICON_GLOW_SIZE; 0 = no glow)
function ns.CreateIndicatorTextures(parentFrame, iconSize, glowSize)
    iconSize = iconSize or ns.ICON_SIZE
    glowSize = glowSize or ns.ICON_GLOW_SIZE
    local style = GetIndicatorTexture()
    local color = GetIndicatorColor()
    local ox, oy = style.offsetX or 0, style.offsetY or 0

    -- Icon texture
    local ind = parentFrame:CreateTexture(nil, "ARTWORK")
    ind:SetSize(iconSize, iconSize)
    ind:SetPoint("CENTER", parentFrame, "CENTER", ox, oy)
    ind:SetTexture(style.texture)
    if style.texCoord then
        ind:SetTexCoord(unpack(style.texCoord))
    end
    ind:SetVertexColor(color[1], color[2], color[3], 1)
    local indicatorRotation = 0
    if style.rotation then
        indicatorRotation = style.rotation
    elseif not style.preRotated then
        indicatorRotation = mpi
    end
    ind:SetRotation(indicatorRotation)
    parentFrame.indicator = ind

    -- Glow texture (optional)
    if glowSize and glowSize > 0 then
        local glow = parentFrame:CreateTexture(nil, "BACKGROUND")
        glow:SetSize(glowSize, glowSize)
        glow:SetPoint("CENTER")
        glow:SetTexture(STAR_GLOW_TEXTURE)
        glow:SetVertexColor(color[1], color[2], color[3], 0.35)
        glow:SetBlendMode("ADD")
        parentFrame.glow = glow
    end

    -- Auto-update on every Show so indicators are ALWAYS in sync with settings.
    parentFrame:HookScript("OnShow", function(self)
        ns.UpdateIndicator(self)
    end)
end

-- Update an existing indicator (and optional glow) to match current settings.
-- Works on any frame that was set up with ns.CreateIndicatorTextures.
-- @param parentFrame Frame
function ns.UpdateIndicator(parentFrame)
    if not parentFrame or not parentFrame.indicator then return end
    local style = GetIndicatorTexture()
    local color = GetIndicatorColor()
    local tex = parentFrame.indicator
    local ox, oy = style.offsetX or 0, style.offsetY or 0

    tex:SetTexture(style.texture)
    if style.texCoord then
        tex:SetTexCoord(unpack(style.texCoord))
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
    -- Use directional override if set, otherwise use style default
    local indicatorRotation
    if parentFrame.indicatorDirection then
        indicatorRotation = ns.GetDirectionalRotation(parentFrame.indicatorDirection)
    elseif style.rotation then
        indicatorRotation = style.rotation
    elseif style.preRotated then
        indicatorRotation = 0
    else
        indicatorRotation = mpi
    end
    tex:SetRotation(indicatorRotation)
    tex:SetVertexColor(color[1], color[2], color[3], 1)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", parentFrame, "CENTER", ox, oy)

    -- Sync texture size to frame size (frame gets resized at show time;
    -- the texture must match or it stays at its creation-time size).
    local fw, fh = parentFrame:GetSize()
    if fw and fw > 0 then
        tex:SetSize(fw, fh)
    end

    if parentFrame.glow then
        parentFrame.glow:SetVertexColor(color[1], color[2], color[3], 0.35)
    end

    -- Apply user icon scale to UI indicators (map indicators handle scale in their own sizing code)
    if parentFrame.isUIIndicator then
        parentFrame:SetScale(EasyFind.db.iconScale or 0.8)
    end
end

-- Compute the rotation for an indicator pointing in a given direction.
-- Takes the style's own rotation into account so every style works correctly.
-- @param direction string "down"|"up"|"left"|"right"
-- @return number rotation in radians
function ns.GetDirectionalRotation(direction)
    local style = GetIndicatorTexture()
    -- Base rotation is whatever points the indicator downward:
    --   preRotated indicators already point down at rotation=0
    --   non-preRotated indicators point down at rotation=mpi
    local baseDown = style.rotation or (style.preRotated and 0 or mpi)
    if direction == "down" then
        return baseDown
    elseif direction == "up" then
        return baseDown + mpi      -- flip 180°
    elseif direction == "right" then
        return baseDown - mpi / 2  -- 90° CW
    elseif direction == "left" then
        return baseDown + mpi / 2  -- 90° CCW
    end
    return baseDown
end

local highlightFrame
local indicatorFrame
local waypointPin
local zoneHighlightFrame  -- For highlighting zones on continent maps
local isGlobalSearch = false
-- Set by SelectResult when invoked in Guide mode (directOverride=false)
-- so the final waypoint placed at the end of the breadcrumb teaches
-- the user how to dismiss it (hover = clear), same as a global-style
-- result. Reset on each SelectResult call.
local pinHoverClearsOverride = nil
local activePinState = nil    -- {mapID, x, y, icon, category} - survives map close/reopen
local mapIsMaximized = false  -- Tracks WorldMapFrame maximize state for search bar repositioning
local cachedWorldZones        -- Built once per session by GetAllWorldZones
local worldZonePrefixIndex = {}
local worldZonePrefixSeen = {}
local worldZonePrefixReady = false
local emptyWorldZones = {}
local rareTrackCache = {}     -- [vignetteGUID] = rare entry, persists across scans for auto-track
local rareTrackMapID = nil    -- mapID the cache is valid for
local rareDeadGUIDs = {}      -- GUIDs confirmed dead/despawned, blocked from re-entering cache
MapSearch._rareTrackCache = rareTrackCache    -- exposed for DevMem diagnostics
MapSearch._rareDeadGUIDs = rareDeadGUIDs      -- exposed for DevMem diagnostics
local efTrackedVignetteGUID = nil  -- GUID we explicitly set via SetSuperTrackedVignette (rares only)

local reuseAllPOIs = {}
local reuseZoneNames = {}
local reuseExistingNames = {}
local reuseFilteredResults = {}
local reusePinnedKeys = {}
local reusePinned = {}
local reuseFiltered = {}
local reuseSearchResults = {}
local reuseSearchSeen = {}
local reuseSearchDuplicates = {}
local reuseInstanceNameNorm = {}
local reuseUISearchPOIs = {}
local reuseUISearchExistingNames = {}
local reuseUISearchZoneNames = {}
local reuseUISearchInstanceNameNorm = {}
local reuseUISearchFiltered = {}
local reuseUISearchResults = {}
local reuseUISearchResultData = {}
local UI_MAP_RESULT_CAP = 60
local efPlacedWaypoint = false

local loadingScreenFrame = CreateFrame("Frame")
loadingScreenFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loadingScreenFrame:RegisterEvent("USER_WAYPOINT_UPDATED")
loadingScreenFrame:RegisterEvent("SUPER_TRACKING_CHANGED")
loadingScreenFrame:RegisterEvent("NAVIGATION_DESTINATION_REACHED")
loadingScreenFrame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUI)
    if event == "NAVIGATION_DESTINATION_REACHED" then
        if EasyFind.db.autoPinClear == false then return end
        if efPlacedWaypoint then
            MapSearch:ClearAll()
        elseif HasUserWaypoint() then
            C_SuperTrack.SetSuperTrackedUserWaypoint(false)
            ClearUserWaypoint()
        end
        return
    end

    if event == "USER_WAYPOINT_UPDATED" or event == "SUPER_TRACKING_CHANGED" then
        local currentVig = C_SuperTrack.GetSuperTrackedVignette and C_SuperTrack.GetSuperTrackedVignette()
        if efTrackedVignetteGUID and currentVig ~= efTrackedVignetteGUID then
            efTrackedVignetteGUID = nil
        end
        if EasyFind.db.enableMapSearch ~= false and EasyFind.db.autoTrackPins ~= false
           and HasUserWaypoint() and not C_SuperTrack.IsSuperTrackingUserWaypoint() then
            if event == "USER_WAYPOINT_UPDATED" then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                return
            end
            local isTrackingPin = C_SuperTrack.IsSuperTrackingMapPin and C_SuperTrack.IsSuperTrackingMapPin()
            local isTrackingVignette = C_SuperTrack.GetSuperTrackedVignette and C_SuperTrack.GetSuperTrackedVignette() ~= nil
            local isTrackingQuest = C_SuperTrack.IsSuperTrackingQuest and C_SuperTrack.IsSuperTrackingQuest()
            if not isTrackingPin and not isTrackingVignette and not isTrackingQuest then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                return
            end
        end
        if not HasUserWaypoint() then
            efPlacedWaypoint = false
        end
        return
    end

    if isInitialLogin or isReloadingUI then
        return
    end

    C_Timer.After(0, function()
        if ns.MapSearch then
            ns.MapSearch:ClearAll()
            ns.MapSearch:ClearZoneHighlight()
        end
        if ns.Highlight then ns.Highlight:ClearAll() end
    end)
end)

-- PIN HELPERS

local function GetMapPinKey(data)
    if data.isZone and data.zoneMapID then
        return "zone:" .. data.zoneMapID
    end
    return (data.category or "unknown") .. ":" .. (data.name or "") .. ":" .. (data.mapID or "")
end

local function CleanForStorage(data)
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        end
    end
    -- score and pin (frame ref) intentionally excluded
    return clean
end

local function IsMapItemPinned(data)
    local key = GetMapPinKey(data)
    for _, pin in ipairs(EasyFind.db.pinnedMapItems) do
        if GetMapPinKey(pin) == key then return true end
    end
    return false
end

local function PinMapItem(data)
    if IsMapItemPinned(data) then return end
    local clean = CleanForStorage(data)
    clean.isPinned = true
    -- Default a freshly-pinned parent to collapsed. The toggle callback
    -- writes back to this same SavedVariables entry, so any user-driven
    -- expand/collapse state survives map close, /reload, and logout.
    if data.isZone and data.zoneMapID and clean.collapsed == nil then
        clean.collapsed = true
    end
    tinsert(EasyFind.db.pinnedMapItems, clean)
end

local function UnpinMapItem(data)
    local key = GetMapPinKey(data)
    local items = EasyFind.db.pinnedMapItems
    for i = #items, 1, -1 do
        if GetMapPinKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
end

-- Expose pin helpers on the module so external renderers (MapTab) can
-- toggle pins without duplicating the canonicalization logic.
MapSearch.GetMapPinKey  = function(_, data) return GetMapPinKey(data) end
MapSearch.IsMapItemPinned = function(_, data) return IsMapItemPinned(data) end
MapSearch.PinMapItem   = function(_, data) return PinMapItem(data) end
MapSearch.UnpinMapItem = function(_, data) return UnpinMapItem(data) end

-- Category icons mapping
local CATEGORY_ICONS = {
    flightmaster = "atlas:TaxiNode_Neutral",
    zeppelin = 342918,
    boat = 1126431,
    portal = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
    tram = "Interface\\Icons\\INV_Misc_Gear_01",
    -- Use the clean map-pin atlases instead of the journal sprite sheet.
    -- The 1121272 sheet's icons are wrapped in a wide soft glow that
    -- gets clipped to a square inside the row's icon slot; the pin
    -- atlases are tight, no-bleed shapes that match WoW's own dungeon /
    -- raid / delve world-map pins.
    dungeon = "atlas:Dungeon",
    raid    = "atlas:Raid",
    delve   = { file = 1121272, coords = { 0.0000, 0.0620, 0.3903, 0.4509 } },
    bank = 136453,
    guildbank = 136453,
    personalbank = 136453,
    auctionhouse = 136452,
    innkeeper = 136458,
    trainer = 136463,
    proftrainer = 136463,
    classtrainer = { file = 131016, coords = { 0.000, 0.250, 0.375, 0.500 } },
    classtrainer_deathknight = "atlas:classicon-deathknight",
    classtrainer_demonhunter = "atlas:classicon-demonhunter",
    classtrainer_druid       = "atlas:classicon-druid",
    classtrainer_evoker      = "atlas:classicon-evoker",
    classtrainer_hunter      = "atlas:classicon-hunter",
    classtrainer_mage        = "atlas:classicon-mage",
    classtrainer_monk        = "atlas:classicon-monk",
    classtrainer_paladin     = "atlas:classicon-paladin",
    classtrainer_priest      = "atlas:classicon-priest",
    classtrainer_rogue       = "atlas:classicon-rogue",
    classtrainer_shaman      = "atlas:classicon-shaman",
    classtrainer_warlock     = "atlas:classicon-warlock",
    classtrainer_warrior     = "atlas:classicon-warrior",
    prof_alchemy = "Interface\\Icons\\Trade_Alchemy",
    prof_blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    prof_cooking = "Interface\\Icons\\INV_Misc_Food_15",
    prof_enchanting = "Interface\\Icons\\Trade_Engraving",
    prof_engineering = "Interface\\Icons\\Trade_Engineering",
    prof_fishing = "Interface\\Icons\\Trade_Fishing",
    prof_herbalism = "Interface\\Icons\\Trade_Herbalism",
    prof_inscription = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    prof_jewelcrafting = "Interface\\Icons\\INV_Misc_Gem_01",
    prof_leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
    prof_mining = "Interface\\Icons\\Trade_Mining",
    prof_skinning = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    prof_tailoring = "Interface\\Icons\\Trade_Tailoring",
    prof_firstaid = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
    prof_archaeology = "Interface\\Icons\\Trade_Archaeology",
    trainingdummy = "Interface\\Icons\\Ability_Warrior_Charge",
    vendor = "Interface\\Icons\\INV_Misc_Bag_07",
    pvpvendor = 236396,
    pvpquest = 236396,
    battlemasters = 236396,
    quartermaster = { file = 1121272, coords = { 0.5090, 0.5390, 0.6070, 0.6370 } },
    mailbox = 136459,
    stablemaster = 136466,
    repairvendor = 136465,
    barber = 3852099,
    transmogrifier = 1598183,
    rare = { file = 1121272, coords = { 0.7796, 0.8381, 0.1934, 0.2531 } },
    treasure = "Interface\\Icons\\INV_Misc_Bag_10",
    catalyst = { file = 1121272, coords = { 0.5097, 0.5390, 0.4078, 0.4363 } },
    greatvault = "Interface\\Icons\\INV_Misc_Lockbox_1",
    upgradevendor = 4025144,
    guildservices = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
    voidstorage = "Interface\\Icons\\INV_Enchant_VoidCrystal",
    tradingpost = "Interface\\Icons\\tradingpostcurrency",
    decor = { file = 1121272, coords = { 0.4078, 0.4380, 0.8713, 0.9040 } },
    chromie = "atlas:ChromieTime-32x32",
    lorewalker = { file = 1121272, coords = { 0.2027, 0.2404, 0.5966, 0.6261 } },
    craftingorders = { file = 1121272, coords = { 0.8764, 0.9040, 0.5102, 0.5357 } },
    rostrum = { file = 1121272, coords = { 0.7738, 0.8033, 0.4066, 0.4394 } },
    pettrainer = "atlas:WildBattlePetCapturable",
    ridingtrainer = "atlas:StableMaster",
    areapoi = "Interface\\Icons\\INV_Misc_QuestionMark",
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
}

local function GetCategoryIcon(category)
    return CATEGORY_ICONS[category] or CATEGORY_ICONS.unknown
end

ns.MapSearch = ns.MapSearch or MapSearch
ns.MapSearch.GetCategoryIcon = GetCategoryIcon

-- GetFilterBucket lives below the CATEGORIES table so it can reference
-- it as an upvalue (Lua resolves at definition time — declaring this
-- function above CATEGORIES would silently treat the name as a global
-- and every parent-based lookup would return nil).

-- Category definitions with hierarchy
local CATEGORIES = {
    travel = { keywords = {"travel", "transport", "transportation", "getting around"} },
    instance = { keywords = {"instance", "instances", "group content"} },
    service = { keywords = {"service", "services", "npc"} },

    flightmaster = { keywords = {"flight", "fly", "flight master", "flight point", "fp", "taxi"}, parent = "travel" },
    zeppelin = { keywords = {"zeppelin", "zep", "airship", "blimp"}, parent = "travel" },
    boat = { keywords = {"boat", "ship", "ferry"}, parent = "travel" },
    portal = { keywords = {"portal", "portals", "teleport", "mage"}, parent = "travel" },
    tram = { keywords = {"tram", "deeprun"}, parent = "travel" },

    dungeon = { keywords = {"dungeon", "dungeons", "5 man", "5man", "mythic", "heroic"}, parent = "instance" },
    raid = { keywords = {"raid", "raids", "raiding"}, parent = "instance" },
    delve = { keywords = {"delve", "delves"}, parent = "instance" },

    bank = { keywords = {"bank", "vault", "storage", "guild bank", "personal bank"}, parent = "service" },
    auctionhouse = { keywords = {"auction", "ah", "auction house"}, parent = "service" },
    innkeeper = { keywords = {"inn", "innkeeper", "rest", "hearthstone"}, parent = "service" },
    trainer = { keywords = {"trainer", "training", "class trainer"}, parent = "service" },
    vendor = { keywords = {"vendor", "merchant", "shop", "buy", "sell"}, parent = "service" },
    pvpvendor = { keywords = {"pvp vendor", "honor vendor", "conquest vendor", "arena vendor", "battleground vendor", "pvp gear"}, parent = "service" },
    quartermaster = { keywords = {"quartermaster", "qtr", "gear vendor", "currency vendor"}, parent = "service" },
    mailbox = { keywords = {"mail", "mailbox"}, parent = "service" },
    stablemaster = { keywords = {"stable", "stable master", "pet"}, parent = "service" },
    repairvendor = { keywords = {"repair", "repairs", "anvil"}, parent = "service" },
    barber = { keywords = {"barber", "barbershop", "appearance", "haircut"}, parent = "service" },
    transmogrifier = { keywords = {"transmog", "transmogrifier", "appearance"}, parent = "service" },

    prof_blacksmithing = { keywords = {"blacksmithing", "bs"}, parent = "service" },
    prof_jewelcrafting = { keywords = {"jewelcrafting", "jc"}, parent = "service" },
    prof_leatherworking = { keywords = {"leatherworking", "lw"}, parent = "service" },

    rare = { keywords = {"rare", "rares", "silver dragon", "elite"} },
    treasure = { keywords = {"treasure", "chest", "loot"} },
    catalyst = { keywords = {"catalyst", "tier", "tier set", "revival catalyst", "upgrade"}, parent = "service" },
    greatvault = { keywords = {"great vault", "vault", "weekly rewards", "weekly chest"}, parent = "service" },
    upgradevendor = { keywords = {"upgrade", "upgrade vendor", "flightstone", "crest"}, parent = "service" },
    tradingpost = { keywords = {"trading post", "trader's tender", "tender", "tmog", "xmog"}, parent = "service" },
    decor = { keywords = {"decor", "decoration", "decorations", "decorator", "housing", "furniture"}, parent = "service" },
    lorewalker = { keywords = {"lorewalker", "cho", "lore walker", "pandaria lore", "flashback", "replay cinematic"}, parent = "service" },
}

local function GetFilterBucket(data)
    if not data then return "other" end
    -- Category takes priority over isZone so dungeons/raids/delves that
    -- are map-type Dungeon (and therefore carry isZone=true alongside
    -- their category) still bucket into "instances" instead of "zones".
    local cat = data.category
    if cat == "dungeon" or cat == "raid" or cat == "delve" then return "instances" end
    if data.isZone then return "zones" end
    if not cat then return "other" end
    if cat == "flightmaster" then return "flightpath" end
    if cat == "rare" then return "rares" end
    local parent = CATEGORIES[cat] and CATEGORIES[cat].parent
    if parent == "instance" then return "instances" end
    if parent == "travel" then return "travel" end
    if parent == "service" or cat == "service" then return "services" end
    -- StaticLocations carries narrower categories (classtrainer_*, prof_*,
    -- guildbank, etc.) that aren't in the CATEGORIES table. Treat them as
    -- services so the filter works on them too.
    if sfind(cat, "^classtrainer_") or sfind(cat, "^prof_") then return "services" end
    if cat == "guildbank" or cat == "guildservices" or cat == "trainingdummy" then return "services" end
    return "other"
end
ns.MapSearch.GetFilterBucket = GetFilterBucket

local function MapTabFlightPathsEnabled()
    local filters = EasyFind and EasyFind.db and EasyFind.db.mapTabFilters
    return filters and filters.flightpath ~= false
end

-- Categories allowed in global (cross-zone) search results.
-- Everything else (services, travel, etc.) is excluded to keep global results clean.
local GLOBAL_SEARCH_CATEGORIES = {
    dungeon = true,
    raid = true,
    delve = true,
}

-- Static locations are loaded from StaticLocations.lua (generated by tools/ImportPOIs.ps1)
-- To add POIs: record in-game with /devpoi, then run ImportPOIs.ps1
local STATIC_LOCATIONS = ns.STATIC_LOCATIONS or {}

function MapSearch:Initialize()
    self:CreateHighlightFrame()
    self:CreateZoneHighlightFrame()
    self:HookWorldMap()
    self:BuildWorldZoneCache()
end

function MapSearch:CreateFilterDropdown(globalName, options, dbKey, toggleBtn, anchorFrame, onChanged)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local HEADER_HEIGHT = 19
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    local dropdown = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    dropdown:Hide()
    dropdown:EnableMouse(true)
    dropdown:SetClampedToScreen(true)

    dropdown:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    -- "Show:" header (gold text, matching WoW tracking menu)
    local header = dropdown:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    header:SetPoint("TOPLEFT", 12, -PADDING_TOP)
    header:SetText("Show:")
    header:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)

    local checkRows = {}
    local checkRowsByIndex = {}
    local yStart = -(PADDING_TOP + HEADER_HEIGHT)

    for i, opt in ipairs(options) do
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, yStart - (i - 1) * ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key

        -- Rounded square checkbox (standard WoW style)
        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        -- Label
        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        label:SetText(opt.label)

        -- Highlight on hover
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)

        -- Keyboard focus highlight (separate from mouse hover)
        local kbHighlight = row:CreateTexture(nil, "BACKGROUND")
        kbHighlight:SetAllPoints()
        kbHighlight:SetColorTexture(1, 1, 1, 0.1)
        kbHighlight:Hide()
        row.kbHighlight = kbHighlight

        -- Start checked
        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db[dbKey]
            filters[opt.key] = self:GetChecked()
            if onChanged then onChanged(opt.key, self:GetChecked()) end
        end)

        checkRows[opt.key] = row
        checkRowsByIndex[i] = row
    end

    dropdown.rows = checkRowsByIndex
    dropdown.selectedRow = 0

    function dropdown:SetSelectedRow(idx)
        self.selectedRow = idx
        for ri = 1, #checkRowsByIndex do
            checkRowsByIndex[ri].kbHighlight:SetShown(ri == idx)
        end
    end

    function dropdown:ToggleSelectedRow()
        local row = checkRowsByIndex[self.selectedRow]
        if row then
            row:Click()
        end
    end

    local totalHeight = PADDING_TOP + HEADER_HEIGHT + #options * ROW_HEIGHT + PADDING_BOTTOM
    dropdown:SetSize(DROPDOWN_WIDTH, totalHeight)

    -- Sync checkmarks to saved state on show
    dropdown:SetScript("OnShow", function(self)
        local filters = EasyFind.db[dbKey]
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
        end
        self:SetSelectedRow(self.keyboardOpen and 1 or 0)
        self.keyboardOpen = nil
    end)

    dropdown:SetScript("OnHide", function(self)
        self:SetSelectedRow(0)
        if self.restoreToolbar then
            self.restoreToolbar()
            self.restoreToolbar = nil
        end
    end)

    -- Close when clicking outside
    dropdown:SetScript("OnUpdate", function(self)
        if self:IsShown() and IsMouseButtonDown("LeftButton") then
            if not self:IsMouseOver() and not toggleBtn:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    toggleBtn:SetScript("OnClick", function(self)
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            local scale = anchorFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            local right = anchorFrame:GetRight() * scale
            local bottom = anchorFrame:GetBottom() * scale
            dropdown:ClearAllPoints()
            dropdown:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
            dropdown:Show()
        end
    end)

    return dropdown
end

-- Resize highlight border textures in canvas units so they match the UI search
-- highlight thickness regardless of map zoom.  Uses the same 4px / 4px pad as
-- Highlight.lua but converted through UIToCanvas.
local function ResizeHighlightBorders(frame)
    local bs  = ns.UIToCanvas(4)
    local pad = ns.UIToCanvas(4)

    -- Top and bottom own the corners (full width including padding)
    frame.top:ClearAllPoints()
    frame.top:SetHeight(bs)
    frame.top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -pad, 0)
    frame.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", pad, 0)

    frame.bottom:ClearAllPoints()
    frame.bottom:SetHeight(bs)
    frame.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -pad, 0)
    frame.bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", pad, 0)

    -- Left and right fit between top and bottom (no corner overlap)
    frame.left:ClearAllPoints()
    frame.left:SetWidth(bs)
    frame.left:SetPoint("TOPLEFT", frame.top, "BOTTOMLEFT", 0, 0)
    frame.left:SetPoint("BOTTOMLEFT", frame.bottom, "TOPLEFT", 0, 0)

    frame.right:ClearAllPoints()
    frame.right:SetWidth(bs)
    frame.right:SetPoint("TOPRIGHT", frame.top, "BOTTOMRIGHT", 0, 0)
    frame.right:SetPoint("BOTTOMRIGHT", frame.bottom, "TOPRIGHT", 0, 0)
end

local function SetHighlightBordersVisible(frame, visible)
    frame.top:SetShown(visible)
    frame.bottom:SetShown(visible)
    frame.left:SetShown(visible)
    frame.right:SetShown(visible)
end

function MapSearch:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "EasyFindMapHighlight", WorldMapFrame.ScrollContainer.Child)
    highlightFrame:SetSize(64, 64)
    highlightFrame:SetFrameStrata("TOOLTIP")
    highlightFrame:SetFrameLevel(2000)
    -- Decoration only — never absorb clicks even if it ends up over a
    -- clickable region in some map mode (maximized canvas, etc.).
    highlightFrame:EnableMouse(false)
    highlightFrame:Hide()

    local top = highlightFrame:CreateTexture(nil, "OVERLAY")
    top:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
    highlightFrame.top = top

    local bottom = highlightFrame:CreateTexture(nil, "OVERLAY")
    bottom:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
    highlightFrame.bottom = bottom

    local left = highlightFrame:CreateTexture(nil, "OVERLAY")
    left:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
    highlightFrame.left = left

    local right = highlightFrame:CreateTexture(nil, "OVERLAY")
    right:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
    highlightFrame.right = right

    -- Indicator pointing down to the location. Parented to the canvas
    -- (sibling of waypointPin / highlightFrame) and anchored explicitly
    -- on every show — never reparented. Reparenting between hovers had
    -- inconsistent timing on some result rows where the indicator would
    -- inherit a stale Hidden state and never repaint.
    indicatorFrame = CreateFrame("Frame", "EasyFindMapIndicator", WorldMapFrame.ScrollContainer.Child)
    indicatorFrame:SetFrameStrata("TOOLTIP")
    indicatorFrame:SetFrameLevel(2000)
    indicatorFrame:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    indicatorFrame:EnableMouse(false)
    ns.CreateIndicatorTextures(indicatorFrame)

    local animGroup = highlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0.4)
    alpha:SetDuration(ANIM_DURATION)
    highlightFrame.animGroup = animGroup

    -- Indicator bob + pulse animation (independent of parent highlight alpha)
    local indAnimGroup = indicatorFrame:CreateAnimationGroup()
    indAnimGroup:SetLooping("BOUNCE")
    local indMove = indAnimGroup:CreateAnimation("Translation")
    indMove:SetOffset(0, -10)
    indMove:SetDuration(ANIM_DURATION)
    local indAlpha = indAnimGroup:CreateAnimation("Alpha")
    indAlpha:SetFromAlpha(1)
    indAlpha:SetToAlpha(0.4)
    indAlpha:SetDuration(ANIM_DURATION)
    indicatorFrame.animGroup = indAnimGroup

    -- Create static location pin - shows the icon for locations from database
    waypointPin = CreateFrame("Frame", "EasyFindLocationPin", WorldMapFrame.ScrollContainer.Child)
    waypointPin:SetSize(64, 64)  -- Large icon for visibility
    waypointPin:SetFrameStrata("HIGH")
    waypointPin:SetFrameLevel(2000)
    waypointPin:Hide()

    -- Enable mouse for hover tooltip + click-to-navigate (local search)
    -- or hover-to-dismiss (global search)
    waypointPin:EnableMouse(true)
    waypointPin:SetScript("OnEnter", function(self)
        if self.isLocalSearch then
            local playerMapID = GetBestMapForUnit("player")
            local viewingMapID = WorldMapFrame:GetMapID()
            local inZone = playerMapID and viewingMapID and playerMapID == viewingMapID
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if inZone then
                GameTooltip:AddLine("Left-click to place waypoint and track")
            else
                GameTooltip:AddLine("Navigate not available", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Only available when viewing your current zone", 0.5, 0.5, 0.5)
            end
            GameTooltip:AddLine("Right-click to dismiss", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        else
            MapSearch:ClearHighlight()
        end
    end)
    waypointPin:SetScript("OnLeave", GameTooltip_Hide)
    waypointPin:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.isLocalSearch and self.waypointX and self.waypointY then
            local x, y = self.waypointX, self.waypointY
            -- Collapse multi-pin to this one if in multi-pin state
            if activePinState and activePinState.instances then
                MapSearch:ShowWaypointAt(x, y, nil, self.waypointCategory)
            end
            local playerMapID = GetBestMapForUnit("player")
            local viewingMapID = WorldMapFrame:GetMapID()
            if viewingMapID and playerMapID == viewingMapID then
                SetUserWaypoint(UiMapPoint.CreateFromCoordinates(viewingMapID, x, y))
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                efPlacedWaypoint = true
                MapSearch:RefreshAllClearButtons()
            end
        end
        if button == "RightButton" then
            MapSearch:ClearAll()
        end
    end)

    local wpIcon = waypointPin:CreateTexture(nil, "ARTWORK")
    wpIcon:SetAllPoints()
    waypointPin.icon = wpIcon

    -- Add a pulsing glow effect around the icon (ALWAYS YELLOW - this is a pin, not an arrow)
    local glow = waypointPin:CreateTexture(nil, "BACKGROUND")
    glow:SetSize(100, 100)
    glow:SetPoint("CENTER")
    glow:SetTexture(STAR_GLOW_TEXTURE)
    glow:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.8)
    glow:SetBlendMode("ADD")
    waypointPin.glow = glow

    -- Animation for the location pin glow
    local pinAnimGroup = waypointPin:CreateAnimationGroup()
    pinAnimGroup:SetLooping("BOUNCE")
    local pinPulse = pinAnimGroup:CreateAnimation("Alpha")
    pinPulse:SetFromAlpha(1)
    pinPulse:SetToAlpha(0.3)
    pinPulse:SetDuration(ANIM_DURATION)
    waypointPin.animGroup = pinAnimGroup

end

function MapSearch:CreateZoneHighlightFrame()
    -- Frame to overlay and highlight zones on continent maps
    zoneHighlightFrame = CreateFrame("Frame", "EasyFindZoneHighlight", WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:SetFrameStrata("TOOLTIP")  -- High strata to be visible
    zoneHighlightFrame:SetFrameLevel(400)
    zoneHighlightFrame:SetAllPoints(WorldMapFrame.ScrollContainer.Child)
    -- Decorative overlay only — must never absorb clicks. At TOOLTIP
    -- strata it's the topmost frame in WorldMapFrame; if the canvas
    -- extents reach under the MapTab side panel (maximized map), a
    -- mouse-enabled overlay there would eat row clicks.
    zoneHighlightFrame:EnableMouse(false)
    zoneHighlightFrame:Hide()

    -- Store references to zone highlight textures
    zoneHighlightFrame.highlights = {}

    -- Create a pool of highlight textures we can reuse (ALWAYS YELLOW)
    for i = 1, 10 do
        local highlight = zoneHighlightFrame:CreateTexture("EasyFindZoneHighlight"..i, "OVERLAY")
        highlight:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.5)
        highlight:SetDrawLayer("OVERLAY", 7)  -- Highest sublayer
        highlight:Hide()
        zoneHighlightFrame.highlights[i] = highlight
    end

    -- Animation for pulsing effect
    local animGroup = zoneHighlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.75)
    alpha:SetToAlpha(0.5)
    alpha:SetDuration(ANIM_DURATION)
    zoneHighlightFrame.animGroup = animGroup

    -- Create indicator for zone highlighting
    local zoneInd = CreateFrame("Frame", "EasyFindZoneIndicator", WorldMapFrame.ScrollContainer.Child)
    zoneInd:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    zoneInd:SetFrameStrata("TOOLTIP")
    zoneInd:SetFrameLevel(500)
    zoneInd:EnableMouse(false)
    ns.CreateIndicatorTextures(zoneInd)

    local zoneIndAnimGroup = zoneInd:CreateAnimationGroup()
    zoneIndAnimGroup:SetLooping("BOUNCE")
    local zoneIndMove = zoneIndAnimGroup:CreateAnimation("Translation")
    zoneIndMove:SetOffset(0, -10)
    zoneIndMove:SetDuration(ANIM_DURATION)
    local zoneIndAlpha = zoneIndAnimGroup:CreateAnimation("Alpha")
    zoneIndAlpha:SetFromAlpha(1)
    zoneIndAlpha:SetToAlpha(0.4)
    zoneIndAlpha:SetDuration(ANIM_DURATION)
    zoneInd.animGroup = zoneIndAnimGroup
    zoneInd.translateAnim = zoneIndMove

    zoneInd:Hide()
    zoneHighlightFrame.indicator = zoneInd
end

-- Get direct child zones only (1 level deep) for local search
function MapSearch:GetDirectChildZones(mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
    if not mapID then return {} end

    local zones = {}
    local seen = {}

    -- Get all direct children (not recursive)
    local children = GetMapChildrenInfo(mapID, nil, false)  -- false = not recursive
    if children then
        for _, child in ipairs(children) do
            if child.name and not seen[child.mapID] then
                -- Skip dungeon, micro, and orphan maps - only include navigable zones
                local mt = child.mapType
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    seen[child.mapID] = true
                    tinsert(zones, {
                        mapID = child.mapID,
                        name = child.name,
                        mapType = child.mapType,
                        parentMapID = mapID
                    })
                end
            end
        end
    end

    return zones
end

-- Get the map hierarchy path for a zone (e.g., "Azeroth > Kalimdor > Durotar")
function MapSearch:GetMapHierarchy(mapID)
    local hierarchy = {}
    local currentID = mapID
    local maxDepth = 10  -- Safety limit

    while currentID and maxDepth > 0 do
        local mapInfo = GetMapInfo(currentID)
        if mapInfo then
            tinsert(hierarchy, 1, {
                mapID = currentID,
                name = mapInfo.name,
                mapType = mapInfo.mapType
            })
            currentID = mapInfo.parentMapID
        else
            break
        end
        maxDepth = maxDepth - 1
    end

    return hierarchy
end

-- Recursively get ALL zones in the world for global search
function MapSearch:GetAllWorldZones(startMapID, depth, parentPath)
    depth = depth or 0
    parentPath = parentPath or {}

    local allZones = {}
    local maxDepth = 6

    if depth > maxDepth then return allZones end

    local children = GetMapChildrenInfo(startMapID, nil, false)
    if not children then return allZones end

    local parentInfo = GetMapInfo(startMapID)
    local parentName = parentInfo and parentInfo.name or ""
    local parentType = parentInfo and parentInfo.mapType

    if parentName == "Cosmic" then
        parentName = "World"
    end

    for _, child in ipairs(children) do
        if child.name then
            local fullPath = {}
            for i = 1, #parentPath do
                fullPath[i] = parentPath[i]
            end
            if parentName ~= "" then
                tinsert(fullPath, {mapID = startMapID, name = parentName})
            end

            local mt = child.mapType
            local includeDungeon = false
            if mt == Enum.UIMapType.Dungeon then
                if parentType == Enum.UIMapType.Zone then
                    includeDungeon = true
                elseif parentType == Enum.UIMapType.Continent then
                    local ok, dL, dR = pcall(GetMapRectOnMap, child.mapID, startMapID)
                    includeDungeon = ok and dL and (dR - dL) > 0
                end
            end
            if mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan
               and (mt ~= Enum.UIMapType.Dungeon or includeDungeon) then
                tinsert(allZones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = startMapID,
                    parentName = parentName,
                    path = fullPath,
                    depth = depth
                })

                local subZones = self:GetAllWorldZones(child.mapID, depth + 1, fullPath)
                for _, subZone in ipairs(subZones) do
                    tinsert(allZones, subZone)
                end
            end
        end
    end

    return allZones
end

local ZONE_PARENT_OVERRIDES = MapUtils.PARENT_OVERRIDES or {

    [2346] = 2274, -- Undermine → Khaz Algar (API incorrectly says The Ringing Deeps 2214)
}

-- Per-query cache for SearchZones, keyed on mode (local vs global).
-- Stores recently-run queries so backspace hits cache (the previous
-- query's result set is still in memory) and typing extensions still
-- narrow from the most recent entry. LRU-evicts when capacity exceeds
-- SEARCH_CACHE_MAX. Invalidated alongside cachedWorldZones.
local SEARCH_CACHE_MAX = 32
local searchZonesCache = {
    local_  = { entries = {}, order = {}, lastQuery = "" },
    global_ = { entries = {}, order = {}, lastQuery = "" },
}
local function ResetSearchZonesCache()
    for _, c in pairs(searchZonesCache) do
        wipe(c.entries); wipe(c.order); c.lastQuery = ""
    end
end
ns.MapSearch.ResetSearchZonesCache = ResetSearchZonesCache

local function CachePut(cache, query, value)
    if cache.entries[query] == nil then
        cache.order[#cache.order + 1] = query
        if #cache.order > SEARCH_CACHE_MAX then
            local oldest = tremove(cache.order, 1)
            cache.entries[oldest] = nil
        end
    end
    cache.entries[query] = value
    cache.lastQuery = query
end

local function AddWorldZonePrefix(zone, prefix)
    if worldZonePrefixSeen[prefix] == zone then return end
    worldZonePrefixSeen[prefix] = zone
    local bucket = worldZonePrefixIndex[prefix]
    if not bucket then
        bucket = {}
        worldZonePrefixIndex[prefix] = bucket
    end
    bucket[#bucket + 1] = zone
end

local function IndexWorldZoneText(zone, text)
    if not text then return end
    for word in text:gmatch("%S+") do
        local len = #word
        if len >= 1 then AddWorldZonePrefix(zone, ssub(word, 1, 1)) end
        if len >= 2 then AddWorldZonePrefix(zone, ssub(word, 1, 2)) end
    end
end

local function BuildWorldZonePrefixIndex(zones)
    wipe(worldZonePrefixIndex)
    wipe(worldZonePrefixSeen)
    for i = 1, #zones do
        local zone = zones[i]
        zone.nameLower = zone.nameLower or slower(zone.name)
        IndexWorldZoneText(zone, zone.nameLower)
    end
    for abbrev, target in pairs(ZONE_ABBREVIATIONS) do
        for i = 1, #zones do
            local zone = zones[i]
            if zone.nameLower == target then
                AddWorldZonePrefix(zone, abbrev)
                break
            end
        end
    end
    wipe(worldZonePrefixSeen)
    worldZonePrefixReady = true
end

function MapSearch:BuildWorldZoneCache()
    if cachedWorldZones then return cachedWorldZones end

    local worldPath = {{mapID = 946, name = "World"}}
    local zones = {}
    local cosmicChildren = GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            if child.name then
                tinsert(zones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = 946,
                    parentName = "World",
                    path = worldPath,
                    depth = 0
                })
            end
            local worldZones = self:GetAllWorldZones(child.mapID, 0, worldPath)
            for _, z in ipairs(worldZones) do
                tinsert(zones, z)
            end
        end
    end
    cachedWorldZones = zones
    BuildWorldZonePrefixIndex(zones)
    return zones
end

function MapSearch:SearchZones(query)
    if not query or query == "" then return {} end

    query = slower(query)
    local zones
    local candidates

    if isGlobalSearch then
        zones = self:BuildWorldZoneCache()
        if not worldZonePrefixReady then BuildWorldZonePrefixIndex(zones) end
        candidates = worldZonePrefixIndex[ssub(query, 1, 2)]
            or worldZonePrefixIndex[ssub(query, 1, 1)]
            or emptyWorldZones

    else
        -- Local: only direct children of current map
        zones = self:GetDirectChildZones()
        candidates = zones
    end

    -- Query cache: exact-hit returns cached results (covers backspace
    -- and re-typing). Extension of the last query narrows from its
    -- match set. Anything else falls through to a full scan.
    local cacheKey = isGlobalSearch and "global_" or "local_"
    local cache = searchZonesCache[cacheKey]
    local cachedHit = cache.entries[query]
    if cachedHit then
        cache.lastQuery = query
        return cachedHit
    end
    if cache.lastQuery ~= ""
       and #query > #cache.lastQuery
       and query:sub(1, #cache.lastQuery) == cache.lastQuery then
        local prev = cache.entries[cache.lastQuery]
        if prev then candidates = prev end
    end

    local matches = {}
    local abbrevTarget = ZONE_ABBREVIATIONS[query]  -- check once outside loop

    for _, zone in ipairs(candidates) do
        -- Cache the lowercased name on the zone itself. cachedWorldZones
        -- persists across searches, so this pays the slower() cost once
        -- per zone instead of every keystroke (global mode = 1500 zones).
        local nameLower = zone.nameLower
        if not nameLower then
            nameLower = slower(zone.name)
            zone.nameLower = nameLower
        end
        local score = ns.Database:ScoreName(nameLower, query, #query)

        -- Check abbreviation match (e.g. "sw" → "stormwind city")
        if abbrevTarget and nameLower == abbrevTarget then
            score = mmax(score, 200)  -- Treat as exact match
        end

        -- Ancestor matching is intentionally NOT done here. If the
        -- parent zone matches the query, the renderer expands ALL of
        -- its children via GetWorldChildren — no need to inject
        -- partial children into the results, which produced the
        -- inconsistent "only some children show" behavior where
        -- whether a child surfaced depended on whether its name
        -- happened to share characters with the query.

        if score >= 50 then
            zone.score = score
            tinsert(matches, zone)
        end
    end

    -- Sort by score, then by name
    tsort(matches, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.name < b.name
    end)

    if #matches > 0 then
        CachePut(cache, query, matches)
    else
        cache.lastQuery = query
    end

    return matches
end

-- Group zone matches by their FULL parent path for clean display
-- ONLY groups zones when multiple search results share the EXACT SAME parent path
local zoneGroupPool = {}
local zoneGroupPoolN = 0
local zoneGroupByKey = {}
local zoneGroupResults = {}
local zonePathParts = {}

local function ZoneNameLess(a, b)
    return a.name < b.name
end

local function ZoneGroupLess(a, b)
    return (a.parentPath or "") < (b.parentPath or "")
end

local function EnsureZoneGroupFields(zone)
    if zone.parentPathKey then return end
    local path = zone.path
    if path and #path > 0 then
        wipe(zonePathParts)
        for i = 1, #path do zonePathParts[i] = tostring(path[i].mapID) end
        zone.parentPathKey = tconcat(zonePathParts, ">", 1, #path)
        wipe(zonePathParts)
        for i = 1, #path do zonePathParts[i] = path[i].name end
        zone.parentPathDisplay = tconcat(zonePathParts, " > ", 1, #path)
        zone.parentPathMapID = path[#path].mapID
    else
        zone.parentPathKey = tostring(zone.parentMapID or 0)
        zone.parentPathDisplay = zone.parentName or ""
        zone.parentPathMapID = zone.parentMapID
    end
end

local function GetZoneGroup()
    zoneGroupPoolN = zoneGroupPoolN + 1
    local group = zoneGroupPool[zoneGroupPoolN]
    if not group then
        group = { zones = {} }
        zoneGroupPool[zoneGroupPoolN] = group
    else
        wipe(group.zones)
    end
    group.parentMapID = nil
    group.parentPath = nil
    group.isGrouped = nil
    return group
end

function MapSearch:GroupZonesByParent(zones)
    zoneGroupPoolN = 0
    wipe(zoneGroupByKey)
    wipe(zoneGroupResults)

    for i = 1, #zones do
        local zone = zones[i]
        EnsureZoneGroupFields(zone)
        local key = zone.parentPathKey
        local group = zoneGroupByKey[key]
        if not group then
            group = GetZoneGroup()
            group.parentMapID = zone.parentPathMapID
            group.parentPath = zone.parentPathDisplay
            zoneGroupByKey[key] = group
            zoneGroupResults[#zoneGroupResults + 1] = group
        end
        group.zones[#group.zones + 1] = zone
    end

    for i = 1, #zoneGroupResults do
        local group = zoneGroupResults[i]
        local count = #group.zones
        if count > 1 then tsort(group.zones, ZoneNameLess) end
        group.isGrouped = count >= 2
    end

    tsort(zoneGroupResults, ZoneGroupLess)
    return zoneGroupResults
end

-- Walk up the parent chain to find the continent a map belongs to
local function GetContinentForMap(mapID)
    local id = mapID
    for i = 1, 10 do
        local info = GetMapInfo(id)
        if not info then return nil end
        if info.mapType == Enum.UIMapType.Continent then return id end
        id = GetMapParentID(id, info)
        if not id or id == 0 then return nil end
    end
end

-- Project mapID's rect onto viewMapID's coordinate space via their shared
-- continent. Handles zones not in a direct parent-child relationship
-- (e.g. Stormwind projected onto Elwynn Forest).
local function GetMapRectViaContinent(mapID, viewMapID)
    local c1 = GetContinentForMap(mapID)
    local c2 = GetContinentForMap(viewMapID)
    if not c1 or c1 ~= c2 then return nil end

    local ok1, tL, tR, tT, tB = pcall(GetMapRectOnMap, mapID, c1)
    local ok2, vL, vR, vT, vB = pcall(GetMapRectOnMap, viewMapID, c1)
    if not ok1 or not tL or not ok2 or not vL then return nil end

    local vW, vH = vR - vL, vB - vT
    if vW == 0 or vH == 0 then return nil end

    return (tL - vL) / vW, (tR - vL) / vW, (tT - vT) / vH, (tB - vT) / vH
end

-- Scan GetMapInfoAtPosition across a grid on viewMapID to find the actual
-- boundary where the game considers targetMapID to exist. Returns a tight
-- bounding rect, or nil if the target isn't found. Uses the continent-
-- projected rect as the search region (with padding) to limit API calls.
local function ScanZoneBoundsOnMap(targetMapID, viewMapID, projL, projR, projT, projB)
    local pad = 0.05
    local minX = mmax(0, (projL or 0) - pad)
    local maxX = mmin(1, (projR or 1) + pad)
    local minY = mmax(0, (projT or 0) - pad)
    local maxY = mmin(1, (projB or 1) + pad)

    local step = 0.01
    local foundL, foundR, foundT, foundB
    local x = minX
    while x <= maxX do
        local y = minY
        while y <= maxY do
            local info = GetMapInfoAtPosition(viewMapID, x, y)
            if info and info.mapID == targetMapID then
                if not foundL then
                    foundL, foundR, foundT, foundB = x, x, y, y
                else
                    if x < foundL then foundL = x end
                    if x > foundR then foundR = x end
                    if y < foundT then foundT = y end
                    if y > foundB then foundB = y end
                end
            end
            y = y + step
        end
        x = x + step
    end

    if not foundL then return nil end
    -- Shrink by half a step on each side for a tighter fit
    local inset = step * 0.5
    return foundL + inset, foundR - inset, foundT + inset, foundB - inset
end

-- Check if a zone has no physical presence on any ancestor map.
-- Orphan zones (e.g. Vision of Stormwind, Vision of Orgrimmar) return all
-- zeros from GetMapRectOnMap and have no continent projection. Bugged zones
-- (Uldum, Vale) return valid rects, so this won't match them.
local function IsOrphanZone(mapID)
    local info = GetMapInfo(mapID)
    if not info or not info.parentMapID then return false end
    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, mapID, info.parentMapID)
    if not ok or not left then return true end
    if left ~= 0 or right ~= 0 or top ~= 0 or bottom ~= 0 then return false end
    -- Continent projection also returns all zeros for truly orphaned zones
    local pL, pR, pT, pB = GetMapRectViaContinent(mapID, info.parentMapID)
    if not pL then return true end
    return pL == 0 and pR == 0 and pT == 0 and pB == 0
end

-- Resolve a mapID to the best match for a given view map. When a zone exists
-- under multiple mapIDs with the same name (e.g. TBC Isle of Quel'Danas 122
-- vs Midnight versions 2432/2424/2565), the original mapID may have no
-- position on the view map. This finds a same-named child of viewMapID that
-- does have a valid rect, or returns the original mapID unchanged.
local function ResolveZoneForMap(mapID, viewMapID)
    local info = GetMapInfo(mapID)
    if not info or not info.name then return mapID end

    local ok, left, right = pcall(GetMapRectOnMap, mapID, viewMapID)
    if ok and left and (right - left) > 0 then return mapID end

    local targetName = slower(info.name)
    local children = GetMapChildrenInfo(viewMapID, nil, false)
    if not children then return mapID end

    for _, child in ipairs(children) do
        if child.mapID ~= mapID and slower(child.name) == targetName then
            local ok2, cL, cR = pcall(GetMapRectOnMap, child.mapID, viewMapID)
            if ok2 and cL and (cR - cL) > 0 then
                DebugPrint("[EasyFind] ResolveZoneForMap:", mapID, "->", child.mapID, "on", viewMapID)
                return child.mapID
            end
        end
    end

    return mapID
end

-- Sample points outside a zone's rect to find surrounding zones.
-- minCount=2 → only return a zone if it appears on 2+ sides (for pre-texture
--   check: catches cities like Ironforge where Dun Morogh surrounds 3/4 sides)
-- minCount=1 → return the first valid zone found (for post-texture fallback:
--   catches cities like Stormwind where only 1-2 probes hit a named zone)
local function FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, minCount)
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local offsets = {
        { left - 0.02, centerY },
        { right + 0.02, centerY },
        { centerX, top - 0.02 },
        { centerX, bottom + 0.02 },
    }
    local counts = {}
    local zones = {}
    for i = 1, #offsets do
        local px, py = offsets[i][1], offsets[i][2]
        if px >= 0 and px <= 1 and py >= 0 and py <= 1 then
            local info = GetMapInfoAtPosition(parentMapID, px, py)
            if info and info.mapID ~= mapID and info.mapType == Enum.UIMapType.Zone then
                counts[info.mapID] = (counts[info.mapID] or 0) + 1
                zones[info.mapID] = info
            end
        end
    end
    local bestID, bestCount
    for id, count in pairs(counts) do
        if count >= minCount and (not bestCount or count > bestCount) then
            bestID, bestCount = id, count
        end
    end
    if bestID then return zones[bestID] end
end

-- Hover-safe variant of HighlightZone: draws a translucent yellow rect
-- where the zone sits on the currently-viewed map, but only if the zone
-- is actually visible there. Strict no-side-effects contract:
--   * never calls SetMapID (would trigger OnMapChanged → MapTab refresh)
--   * never touches self.pendingZoneHighlight (no nav state)
--   * bails silently when the zone isn't on the current map, when we're
--     already viewing it, or when its rect is degenerate
-- Used by RunHoverPreview so hovering a result row never moves the map
-- and never re-renders the results window.
function MapSearch:PreviewZoneHighlight(mapID)
    if not zoneHighlightFrame then return end
    if not WorldMapFrame or not WorldMapFrame.ScrollContainer then return end
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    local parentMapID = WorldMapFrame:GetMapID()
    if not parentMapID then return end

    local resolved = ResolveZoneForMap(mapID, parentMapID)
    if resolved ~= mapID then mapID = resolved end

    -- Strict direct-child gate: only preview zones whose parentMapID is
    -- the currently-viewed map. Anything else (ancestors, siblings,
    -- distant descendants) produces glitchy or misleading rects and is
    -- skipped entirely.
    local zoneInfo = GetMapInfo(mapID)
    if not zoneInfo or zoneInfo.parentMapID ~= parentMapID then return end

    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, mapID, parentMapID)
    if not ok or not left then return end

    if left == 0 and right == 0 and top == 0 and bottom == 0 then
        local pL, pR, pT, pB = GetMapRectViaContinent(mapID, parentMapID)
        if not pL then return end
        left, right, top, bottom = pL, pR, pT, pB
    end

    -- Degenerate or implausibly-large rect: ancestor escapees that the
    -- chain check above missed (different continent root, projection
    -- math overflow) tend to produce widths >> 1. Tight gates here keep
    -- the preview "this zone fits sensibly inside the visible canvas".
    if (right - left) < 0.01 or (bottom - top) < 0.01 then return end
    if (right - left) > 1.05 or (bottom - top) > 1.05 then return end
    if right < 0.02 or left > 0.98 or bottom < 0.02 or top > 0.98 then return end

    local clampedL = mmax(0, left)
    local clampedR = mmin(1, right)
    local clampedT = mmax(0, top)
    local clampedB = mmin(1, bottom)
    if (clampedR - clampedL) < 0.01 or (clampedB - clampedT) < 0.01 then return end
    -- Clamped rect covers essentially the whole canvas — it's a
    -- "this zone is the entire view" case. No useful preview.
    if (clampedR - clampedL) >= 0.95 and (clampedB - clampedT) >= 0.95 then return end

    local canvasWidth, canvasHeight = canvas:GetSize()
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local zoneCenterPxX = centerX * canvasWidth
    local zoneCenterPxY = centerY * canvasHeight

    -- Hide all pooled textures first so previous-hover residue is gone
    -- before we paint the new preview.
    for i = 1, #zoneHighlightFrame.highlights do
        local hl = zoneHighlightFrame.highlights[i]
        hl:Hide()
        hl:ClearAllPoints()
        hl:SetTexture(nil)
        hl:SetTexCoord(0, 1, 0, 1)
    end

    -- Try the API's actual zone-shape texture (matches Blizzard's hover
    -- behavior on the world map). Falls back to a translucent rect if
    -- the API returns nothing useful or the texture belongs to a
    -- different zone (cities pick up their containing zone's outline at
    -- the center sample).
    local fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY
    local highlightSuccess = pcall(function()
        fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY =
            GetMapHighlightInfoAtPosition(parentMapID, centerX, centerY)
    end)

    local hasTexture = highlightSuccess and posX and posY and texPercentX and texPercentY
        and ((fileDataID and fileDataID > 0) or (atlasID and atlasID ~= ""))

    if hasTexture then
        local resolvedInfo = GetMapInfoAtPosition(parentMapID, centerX, centerY)
        if resolvedInfo and resolvedInfo.mapID ~= mapID then
            hasTexture = false
        end
    end

    if hasTexture then
        local pixelPosX = posX * canvasWidth
        local pixelPosY = posY * canvasHeight
        local pixelWidth = texWidth * canvasWidth
        local pixelHeight = texHeight * canvasHeight
        local isAtlas = not fileDataID or fileDataID == 0

        local layers = isAtlas and 2 or 4
        for i = 1, layers do
            local hl = zoneHighlightFrame.highlights[i]
            if hl then
                hl:ClearAllPoints()
                if not isAtlas then
                    hl:SetTexture(fileDataID)
                    hl:SetTexCoord(0, texPercentX, 0, texPercentY)
                    hl:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelPosX, -pixelPosY)
                    hl:SetSize(pixelWidth, pixelHeight)
                    hl:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                else
                    hl:SetAtlas(atlasID, true)
                    hl:SetPoint("CENTER", canvas, "TOPLEFT", zoneCenterPxX, -zoneCenterPxY)
                    hl:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.6)
                end
                hl:SetBlendMode("ADD")
                hl:Show()
            end
        end
    else
        -- No zone-shape texture available: fall back to a translucent
        -- rectangle covering the zone's bounding rect. Same rect path
        -- HighlightZone uses for "bugged" zones.
        local x = clampedL * canvasWidth
        local y = clampedT * canvasHeight
        local w = (clampedR - clampedL) * canvasWidth
        local h = (clampedB - clampedT) * canvasHeight

        local highlight = zoneHighlightFrame.highlights[1]
        if highlight then
            highlight:ClearAllPoints()
            highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
            highlight:SetTexCoord(0, 1, 0, 1)
            highlight:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.20)
            highlight:SetBlendMode("BLEND")
            highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, -y)
            highlight:SetSize(w, h)
            highlight:Show()
        end
    end

    zoneHighlightFrame:Show()
end

-- Highlight a zone on the continent map using the actual zone shape texture
function MapSearch:HighlightZone(mapID)
    DebugPrint("[EasyFind] HighlightZone called for mapID:", mapID)

    if not zoneHighlightFrame then
        DebugPrint("[EasyFind] HighlightZone: no zoneHighlightFrame!")
        return
    end

    -- Save pending zone navigation before clearing (we might be highlighting an intermediate zone)
    local savedPending = self.pendingZoneHighlight
    DebugPrint("[EasyFind] HighlightZone: saved pending:", savedPending)

    -- Hide previous highlights
    self:ClearZoneHighlight()

    -- Restore pending zone navigation
    self.pendingZoneHighlight = savedPending
    DebugPrint("[EasyFind] HighlightZone: restored pending:", self.pendingZoneHighlight)

    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then
        DebugPrint("[EasyFind] HighlightZone: no canvas!")
        return
    end

    local mapInfo = GetMapInfo(mapID)
    if not mapInfo then
        DebugPrint("[EasyFind] HighlightZone: no mapInfo for", mapID)
        return
    end
    DebugPrint("[EasyFind] HighlightZone: zone name:", mapInfo.name, "mapType:", mapInfo.mapType)

    local parentMapID = WorldMapFrame:GetMapID()
    if not parentMapID then return end

    -- Resolve to a same-named child if this mapID has no position here
    local resolved = ResolveZoneForMap(mapID, parentMapID)
    if resolved ~= mapID then
        mapID = resolved
        mapInfo = GetMapInfo(mapID)
        if not mapInfo then return end
    end

    local isZone = mapInfo.mapType == Enum.UIMapType.Zone

    local success, left, right, top, bottom = pcall(function()
        return GetMapRectOnMap(mapID, parentMapID)
    end)

    if not success or not left then return end

    -- GetMapRectOnMap returned zeros - either an instanced zone with no physical
    -- position, or a zone not in a direct parent-child relationship (e.g.
    -- Stormwind on Elwynn). Try continent projection before giving up.
    if left == 0 and right == 0 and top == 0 and bottom == 0 then
        local pL, pR, pT, pB = GetMapRectViaContinent(mapID, parentMapID)
        if pL then
            left, right, top, bottom = pL, pR, pT, pB
            DebugPrint("[EasyFind] HighlightZone: used continent projection for coords")
        else
            -- Blind scan: find where the target map exists on the parent map
            -- (handles continents on the World map like Draenor, Outland, etc.)
            local minX, maxX, minY, maxY = 2, -1, 2, -1
            for sx = 0.025, 0.975, 0.05 do
                for sy = 0.025, 0.975, 0.05 do
                    local info = GetMapInfoAtPosition(parentMapID, sx, sy)
                    if info and info.mapID == mapID then
                        if sx < minX then minX = sx end
                        if sx > maxX then maxX = sx end
                        if sy < minY then minY = sy end
                        if sy > maxY then maxY = sy end
                    end
                end
            end
            if maxX > minX then
                left, right, top, bottom = minX, maxX, minY, maxY
                DebugPrint("[EasyFind] HighlightZone: found via blind scan", minX, maxX, minY, maxY)
            else
                WorldMapFrame:SetMapID(mapID)
                return
            end
        end
    end

    local canvasWidth, canvasHeight = canvas:GetSize()
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local zoneCenterPxX = centerX * canvasWidth
    local zoneCenterPxY = centerY * canvasHeight
    local width = (right - left) * canvasWidth
    local height = (bottom - top) * canvasHeight
    local zoneTopPx = top * canvasHeight
    local zoneBottomPx = bottom * canvasHeight
    local zoneLeftPx = left * canvasWidth
    local zoneRightPx = right * canvasWidth

    -- B1: Try the zone's highlight texture from the game API
    local fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY
    local highlightSuccess = pcall(function()
        fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY =
            GetMapHighlightInfoAtPosition(parentMapID, centerX, centerY)
    end)

    local highlight = zoneHighlightFrame.highlights[1]
    if not highlight then return end
    highlight:ClearAllPoints()

    local hasTexture = highlightSuccess and posX and posY and texPercentX and texPercentY
        and ((fileDataID and fileDataID > 0) or (atlasID and atlasID ~= ""))

    -- Validate the texture actually belongs to this zone. Cities on continent
    -- maps pick up their containing zone's texture at the center point.
    if hasTexture and isZone then
        local resolvedInfo = GetMapInfoAtPosition(parentMapID, centerX, centerY)
        if resolvedInfo and resolvedInfo.mapID ~= mapID then
            hasTexture = false
        end
    end

    -- Cities on continent maps have no highlight texture and sit inside
    -- another zone (e.g. Ironforge inside Dun Morogh, Orgrimmar inside
    -- Durotar). Sample interior points to find the containing zone.
    -- Bugged zones (Uldum, Vale) are detected separately: their center
    -- returns the continent itself rather than any zone.
    if not hasTexture and isZone then
        local parentMapInfo = GetMapInfo(parentMapID)
        if parentMapInfo and parentMapInfo.mapType == Enum.UIMapType.Continent then
            local cx = (left + right) * 0.5
            local cy = (top + bottom) * 0.5
            local centerInfo = GetMapInfoAtPosition(parentMapID, cx, cy)
            local isBuggedZone = not centerInfo
                or centerInfo.mapType ~= Enum.UIMapType.Zone
            if not isBuggedZone then
                -- Normal city detection: sample interior points
                local counts = {}
                for sx = 0.2, 0.8, 0.3 do
                    for sy = 0.2, 0.8, 0.3 do
                        local px = left + (right - left) * sx
                        local py = top + (bottom - top) * sy
                        if px >= 0 and px <= 1 and py >= 0 and py <= 1 then
                            local info = GetMapInfoAtPosition(parentMapID, px, py)
                            if info and info.mapID ~= mapID and info.mapType == Enum.UIMapType.Zone then
                                counts[info.mapID] = (counts[info.mapID] or 0) + 1
                            end
                        end
                    end
                end
                local bestID, bestCount
                for id, count in pairs(counts) do
                    if not bestCount or count > bestCount then
                        bestID, bestCount = id, count
                    end
                end
                if bestID then
                    self.pendingZoneHighlight = mapID
                    self:HighlightZone(bestID)
                    return
                end
                local surrounding = FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, 1)
                if surrounding then
                    self.pendingZoneHighlight = mapID
                    self:HighlightZone(surrounding.mapID)
                    return
                end
            end
        end
    end
    if hasTexture then
        local pixelPosX = posX * canvasWidth
        local pixelPosY = posY * canvasHeight
        local pixelWidth = texWidth * canvasWidth
        local pixelHeight = texHeight * canvasHeight
        local isAtlas = not fileDataID or fileDataID == 0

        local layers = isAtlas and 2 or 4
        for i = 1, layers do
            local hl = zoneHighlightFrame.highlights[i]
            if hl then
                hl:ClearAllPoints()
                if not isAtlas then
                    hl:SetTexture(fileDataID)
                    hl:SetTexCoord(0, texPercentX, 0, texPercentY)
                    hl:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelPosX, -pixelPosY)
                    hl:SetSize(pixelWidth, pixelHeight)
                    hl:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                else
                    hl:SetAtlas(atlasID, true)
                    hl:SetPoint("CENTER", canvas, "TOPLEFT", zoneCenterPxX, -zoneCenterPxY)
                    hl:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.6)
                end
                hl:SetBlendMode("ADD")
                hl:Show()
            end
        end
    else
        if isZone then
            local parentMapInfo = GetMapInfo(parentMapID)

            -- On a zone-level map: scan for actual bounds, keeping the
            -- continent projection as fallback if the scan returns a tiny
            -- sliver (some cities barely register via GetMapInfoAtPosition)
            if parentMapInfo and parentMapInfo.mapType == Enum.UIMapType.Zone then
                local sL, sR, sT, sB = ScanZoneBoundsOnMap(mapID, parentMapID, left, right, top, bottom)
                local projW, projH = right - left, bottom - top
                if sL and (sR - sL) > projW * 0.15 and (sB - sT) > projH * 0.15 then
                    left, right, top, bottom = sL, sR, sT, sB
                    DebugPrint("[EasyFind] HighlightZone: using scanned bounds")
                else
                    DebugPrint("[EasyFind] HighlightZone: scan too small, using projection")
                end
                centerX = (left + right) / 2
                centerY = (top + bottom) / 2
                width = (right - left) * canvasWidth
                height = (bottom - top) * canvasHeight
                zoneCenterPxX = centerX * canvasWidth
                zoneCenterPxY = centerY * canvasHeight
                zoneTopPx = top * canvasHeight
                zoneBottomPx = bottom * canvasHeight
                zoneLeftPx = left * canvasWidth
                zoneRightPx = right * canvasWidth
            end
        end

        -- Skip the border box when this is the final navigation target
        -- (cities, Dalaran, etc.) - arrow-only is cleaner
        local isFinalTarget = self.pendingZoneHighlight == mapID

        -- Always place a click overlay for the final navigation target.
        -- For working zones SetMapID is equivalent to a normal click.
        -- For zones broken by the WoW bug (Uldum, Vale of Eternal Blossoms)
        -- this is the only way to navigate in.
        if isFinalTarget then
            DebugPrint("[EasyFind] Final target, adding click overlay for:", mapID)
            if not zoneHighlightFrame.clickOverlay then
                zoneHighlightFrame.clickOverlay = CreateFrame("Button", nil, canvas)
                zoneHighlightFrame.clickOverlay:SetFrameStrata("DIALOG")
            end
            local overlay = zoneHighlightFrame.clickOverlay
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", canvas, "TOPLEFT", zoneLeftPx, -zoneTopPx)
            overlay:SetSize(width, height)
            overlay.targetMapID = mapID
            overlay:SetScript("OnClick", function(self)
                self:Hide()
                local ms = ns.MapSearch
                if ms then ms.pendingZoneHighlight = nil end
                WorldMapFrame:SetMapID(self.targetMapID)
            end)
            overlay:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                local info = GetMapInfo(self.targetMapID)
                GameTooltip:SetText(info and info.name or "")
                GameTooltip:Show()
            end)
            overlay:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            overlay:Show()
        end

        -- Pulsing radial glow centered on bugged zones with no highlight texture
        if isFinalTarget and not hasTexture then
            if not zoneHighlightFrame.centerGlow then
                local glow = canvas:CreateTexture(nil, "ARTWORK")
                glow:SetTexture(STAR_GLOW_TEXTURE)
                glow:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.4)
                glow:SetBlendMode("ADD")
                zoneHighlightFrame.centerGlow = glow

                local ag = glow:CreateAnimationGroup()
                ag:SetLooping("BOUNCE")
                local pulse = ag:CreateAnimation("Alpha")
                pulse:SetFromAlpha(0.25)
                pulse:SetToAlpha(0.55)
                pulse:SetDuration(0.8)
                pulse:SetSmoothing("IN_OUT")
                zoneHighlightFrame.centerGlowAnim = ag
            end
            local glow = zoneHighlightFrame.centerGlow
            local glowSize = mmin(width, height) * 1.2
            glow:ClearAllPoints()
            glow:SetPoint("CENTER", canvas, "TOPLEFT",
                zoneLeftPx + width * 0.5, -(zoneTopPx + height * 0.5))
            glow:SetSize(glowSize, glowSize)
            glow:Show()
            zoneHighlightFrame.centerGlowAnim:Play()
        end

        if not isFinalTarget then
            -- Border outline + translucent fill for regular zones
            local borderW = 2
            highlight:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.15)
            highlight:SetBlendMode("BLEND")
            highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", zoneLeftPx, -zoneTopPx)
            highlight:SetSize(width, height)
            highlight:Show()

            local edges = {
                { "TOPLEFT", "TOPLEFT", zoneLeftPx, -zoneTopPx, width, borderW },
                { "TOPLEFT", "TOPLEFT", zoneLeftPx, -(zoneTopPx + height - borderW), width, borderW },
                { "TOPLEFT", "TOPLEFT", zoneLeftPx, -zoneTopPx, borderW, height },
                { "TOPLEFT", "TOPLEFT", zoneLeftPx + width - borderW, -zoneTopPx, borderW, height },
            }
            for i = 1, 4 do
                local hl = zoneHighlightFrame.highlights[i + 1]
                if hl then
                    local e = edges[i]
                    hl:ClearAllPoints()
                    hl:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.8)
                    hl:SetBlendMode("BLEND")
                    hl:SetPoint(e[1], canvas, e[2], e[3], e[4])
                    hl:SetSize(e[5], e[6])
                    hl:Show()
                end
            end
        end
    end

    DebugPrint("[EasyFind] HighlightZone: About to show frame")
    zoneHighlightFrame:Show()
    DebugPrint("[EasyFind] HighlightZone: zoneHighlightFrame:IsShown() =", zoneHighlightFrame:IsShown())
    zoneHighlightFrame.animGroup:Play()
    DebugPrint("[EasyFind] HighlightZone: highlight and frame shown")

    -- Position indicator with smart bounds checking
    if zoneHighlightFrame.indicator then
        local zoneInd = zoneHighlightFrame.indicator
        -- Convert UI-unit sizes to canvas units so it's visible on continent maps
        local userScale = EasyFind.db.iconScale or 0.8
        local indicatorSize     = ns.UIToCanvas(ns.ZONE_ICON_SIZE)      * userScale
        local indicatorGlowSize = ns.UIToCanvas(ns.ZONE_ICON_GLOW_SIZE) * userScale
        zoneInd:SetSize(indicatorSize, indicatorSize)
        zoneInd:SetFrameStrata("TOOLTIP")
        zoneInd:SetFrameLevel(500)
        if zoneInd.glow then
            zoneInd.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
        end
        -- DO NOT override color/texture here - OnShow hook handles it via ns.UpdateIndicator
        local margin = 50

        zoneInd:ClearAllPoints()

        DebugPrint("[EasyFind] HighlightZone: indicator positioning - zoneTopPx:", zoneTopPx, "margin+indicatorSize:", margin + indicatorSize)

        -- Set direction on the frame - ns.UpdateIndicator (via OnShow hook) reads this
        local gap = 25
        if zoneTopPx > margin + indicatorSize then
            zoneInd.indicatorDirection = "down"
            zoneInd:SetPoint("BOTTOM", canvas, "TOPLEFT", zoneCenterPxX, -(zoneTopPx - gap))
            DebugPrint("[EasyFind] Indicator placed ABOVE zone")
        elseif (canvasHeight - zoneBottomPx) > margin + indicatorSize then
            zoneInd.indicatorDirection = "up"
            zoneInd:SetPoint("TOP", canvas, "TOPLEFT", zoneCenterPxX, -(zoneBottomPx + gap))
            DebugPrint("[EasyFind] Indicator placed BELOW zone")
        elseif zoneLeftPx > margin + indicatorSize then
            zoneInd.indicatorDirection = "right"
            zoneInd:SetPoint("RIGHT", canvas, "TOPLEFT", zoneLeftPx - gap, -zoneCenterPxY)
            DebugPrint("[EasyFind] Indicator placed LEFT of zone")
        else
            zoneInd.indicatorDirection = "left"
            zoneInd:SetPoint("LEFT", canvas, "TOPLEFT", zoneRightPx + gap, -zoneCenterPxY)
            DebugPrint("[EasyFind] Indicator placed RIGHT of zone")
        end

        -- Update bob direction to match indicator pointing direction
        if zoneInd.translateAnim then
            if zoneInd.indicatorDirection == "down" then
                zoneInd.translateAnim:SetOffset(0, -10)
            elseif zoneInd.indicatorDirection == "up" then
                zoneInd.translateAnim:SetOffset(0, 10)
            elseif zoneInd.indicatorDirection == "right" then
                zoneInd.translateAnim:SetOffset(10, 0)
            elseif zoneInd.indicatorDirection == "left" then
                zoneInd.translateAnim:SetOffset(-10, 0)
            end
        end

        zoneInd:Show()
        if zoneInd.animGroup then
            zoneInd.animGroup:Play()
        end
        DebugPrint("[EasyFind] Indicator shown")
    else
        DebugPrint("[EasyFind] HighlightZone: no indicator frame!")
    end

    DebugPrint("[EasyFind] HighlightZone: COMPLETE for zone:", mapInfo.name)

    return true
end

-- preserveBreadcrumb: when true, leaves the click-driven breadcrumb
-- highlight (and its pendingZoneHighlight) untouched. Used by hover-
-- preview cleanup so moving the cursor off a row doesn't wipe the
-- gold breadcrumb the user is being guided to.
function MapSearch:ClearZoneHighlight(preserveBreadcrumb)
    if not zoneHighlightFrame then return end

    for _, highlight in ipairs(zoneHighlightFrame.highlights) do
        highlight:SetTexture(nil)
        highlight:SetTexCoord(0, 1, 0, 1)
        highlight:Hide()
    end

    if zoneHighlightFrame.border then
        for _, border in pairs(zoneHighlightFrame.border) do
            border:Hide()
        end
    end

    if zoneHighlightFrame.centerGlow then
        zoneHighlightFrame.centerGlow:Hide()
        if zoneHighlightFrame.centerGlowAnim then
            zoneHighlightFrame.centerGlowAnim:Stop()
        end
    end

    if zoneHighlightFrame.clickOverlay then
        zoneHighlightFrame.clickOverlay:Hide()
    end

    if zoneHighlightFrame.indicator then
        zoneHighlightFrame.indicator:Hide()
        if zoneHighlightFrame.indicator.animGroup then
            zoneHighlightFrame.indicator.animGroup:Stop()
        end
    end

    if zoneHighlightFrame.animGroup then
        zoneHighlightFrame.animGroup:Stop()
    end

    zoneHighlightFrame:Hide()

    if preserveBreadcrumb then return end

    -- Also clear breadcrumb highlight
    if self.breadcrumbHighlight then
        if self.breadcrumbHighlight.indicatorFrame then
            self.breadcrumbHighlight.indicatorFrame:Hide()
            if self.breadcrumbHighlight.indicatorFrame.animGroup then
                self.breadcrumbHighlight.indicatorFrame.animGroup:Stop()
            end
        end
        if self.breadcrumbHighlight.glowAnim then
            self.breadcrumbHighlight.glowAnim:Stop()
        end
        self.breadcrumbHighlight:Hide()  -- OnHide unlocks the button highlight automatically
    end

    -- Clear pending zone navigation (but NOT pendingWaypoint - that's the final
    -- destination waypoint and must survive through the zone navigation chain)
    self.pendingZoneHighlight = nil
end

-- Highlight a zone with step-by-step navigation guidance (teaching mode)
function MapSearch:HighlightZoneOnMap(targetMapID, zoneName)
    DebugPrint("[EasyFind] HighlightZoneOnMap called for targetMapID:", targetMapID)

    local targetInfo = GetMapInfo(targetMapID)
    if not targetInfo then
        DebugPrint("[EasyFind] ERROR: No targetInfo for mapID", targetMapID)
        return
    end

    DebugPrint("[EasyFind] Target zone:", targetInfo.name)

    local targetParentMapID = GetMapParentID(targetMapID, targetInfo)
    if not targetParentMapID then
        DebugPrint("[EasyFind] No parent, going directly to zone")
        WorldMapFrame:SetMapID(targetMapID)
        return
    end

    if ZONE_PARENT_OVERRIDES[targetMapID] then
        DebugPrint("[EasyFind] Using parent override for", targetMapID, "→", targetParentMapID)
    end

    local targetParentInfo = GetMapInfo(targetParentMapID)
    DebugPrint("[EasyFind] Target parent:", targetParentInfo and targetParentInfo.name or "nil", "ID:", targetParentMapID)

    local currentMapID = WorldMapFrame:GetMapID()
    if not currentMapID then
        DebugPrint("[EasyFind] ERROR: No currentMapID")
        return
    end

    if currentMapID == targetMapID then
        DebugPrint("[EasyFind] Already viewing target zone, nothing to do")
        return
    end

    -- If the target is an ancestor of the current map, it's in the breadcrumb.
    -- Highlight that breadcrumb button directly instead of going through DCA
    -- logic which would overshoot to the target's parent.
    local currentParentChain = self:GetMapPath(currentMapID)
    for i = 1, #currentParentChain - 1 do
        if currentParentChain[i].mapID == targetMapID then
            DebugPrint("[EasyFind] Target is ancestor of current map, highlighting breadcrumb")
            local navBar = WorldMapFrame.NavBar
            if navBar then
                local breadcrumbBtn = self:FindBreadcrumbButton(navBar, targetMapID)
                if breadcrumbBtn and breadcrumbBtn:IsShown() then
                    self.pendingZoneHighlight = targetMapID
                    self:ShowBreadcrumbHighlight(breadcrumbBtn, targetMapID)
                    return
                end
            end
            break
        end
    end

    local currentInfo = GetMapInfo(currentMapID)
    DebugPrint("[EasyFind] Current map:", currentInfo and currentInfo.name or "nil", "ID:", currentMapID)

    -- Resolve legacy mapIDs: if the current map has a same-named child zone
    -- with a valid rect, use that instead (e.g. TBC IQD 122 -> Midnight 2432)
    local resolved = ResolveZoneForMap(targetMapID, currentMapID)
    if resolved ~= targetMapID then
        targetMapID = resolved
        targetInfo = GetMapInfo(targetMapID)
        if not targetInfo then return end
        targetParentMapID = GetMapParentID(targetMapID, targetInfo)
    end

    -- CASE 1: We're already on the target's parent map - just highlight the zone!
    if currentMapID == targetParentMapID then
        DebugPrint("[EasyFind] CASE 1: Already on target parent, highlighting zone")

        -- Cities parented directly to the continent (IF, UC, TB, Shattrath)
        -- need to route through their containing zone first. Only redirect
        -- when the candidate zone's rect fully encloses the target's rect
        -- (otherwise adjacent zones like Icecrown get falsely matched).
        -- Skip when the zone has no highlight info (WoW bug: Uldum, Vale of
        -- Eternal Blossoms) - let it fall through to direct highlight + overlay.
        if currentInfo and currentInfo.mapType == Enum.UIMapType.Continent
           and targetInfo.mapType == Enum.UIMapType.Zone then
            local ok, cL, cR, cT, cB = pcall(GetMapRectOnMap, targetMapID, currentMapID)
            if ok and cL and (cR - cL) > 0 then
                local cx, cy = (cL + cR) / 2, (cT + cB) / 2
                local targetArea = (cR - cL) * (cB - cT)
                local containing = GetMapInfoAtPosition(currentMapID, cx, cy)
                if containing and containing.mapID ~= targetMapID
                   and containing.mapType == Enum.UIMapType.Zone then
                    local ok2, sL, sR, sT, sB = pcall(GetMapRectOnMap, containing.mapID, currentMapID)
                    if ok2 and sL and cL >= sL and cR <= sR and cT >= sT and cB <= sB then
                        local containArea = (sR - sL) * (sB - sT)
                        -- Only route through containing zone if target is
                        -- city-sized (< 25% of container area). Large zones
                        -- that appear "inside" another are WoW API bugs.
                        if targetArea < containArea * 0.25 then
                            DebugPrint("[EasyFind] CASE 1: city inside", containing.name, "- routing through it")
                            self.pendingZoneHighlight = targetMapID
                            C_Timer.After(0.05, function()
                                self:HighlightZone(containing.mapID)
                            end)
                            return
                        end
                    end
                end
                -- Center returned the city itself; check surrounding points
                -- and verify spatial containment
                local surrounding = FindSurroundingZone(currentMapID, targetMapID, cL, cR, cT, cB, 1)
                if surrounding then
                    local ok2, sL, sR, sT, sB = pcall(GetMapRectOnMap, surrounding.mapID, currentMapID)
                    if ok2 and sL and cL >= sL and cR <= sR and cT >= sT and cB <= sB then
                        local surroundArea = (sR - sL) * (sB - sT)
                        if targetArea < surroundArea * 0.25 then
                            DebugPrint("[EasyFind] CASE 1: city surrounded by", surrounding.name, "- routing through it")
                            self.pendingZoneHighlight = targetMapID
                            C_Timer.After(0.05, function()
                                self:HighlightZone(surrounding.mapID)
                            end)
                            return
                        end
                    end
                end
            end
        end

        -- Keep pending so reguiding works if user clicks wrong zone.
        -- OnMapChanged checks arrival (newMapID == pending) to stop the chain.
        self.pendingZoneHighlight = targetMapID
        C_Timer.After(0.05, function()
            self:HighlightZone(targetMapID)
        end)
        return
    end

    -- CASE 1b: Current map physically contains the target even though the API
    -- parent chain doesn't link them (e.g. Stormwind inside Elwynn Forest).
    -- Verify via continent projection + GetMapInfoAtPosition.
    if currentInfo and currentInfo.mapType == Enum.UIMapType.Zone then
        local cL, cR, cT, cB = GetMapRectViaContinent(targetMapID, currentMapID)
        if cL then
            local cX, cY = (cL + cR) / 2, (cT + cB) / 2
            if cX > 0 and cX < 1 and cY > 0 and cY < 1 then
                local resolvedInfo = GetMapInfoAtPosition(currentMapID, cX, cY)
                if resolvedInfo and resolvedInfo.mapID == targetMapID then
                    DebugPrint("[EasyFind] CASE 1b: Target visible on current map (containing zone)")
                    self.pendingZoneHighlight = targetMapID
                    C_Timer.After(0.05, function()
                        self:HighlightZone(targetMapID)
                    end)
                    return
                end
            end
        end
    end

    -- Build paths from root (World) to each map
    local targetParentPath = self:GetMapPath(targetParentMapID)
    local currentPath = self:GetMapPath(currentMapID)

    DebugPrint("[EasyFind] Target parent path:")
    for i, p in ipairs(targetParentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end
    DebugPrint("[EasyFind] Current path:")
    for i, p in ipairs(currentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end

    -- Find the DEEPEST common ancestor (DCA)
    local dcaIndex = 0
    local dcaMapID = nil
    for i = 1, mmin(#targetParentPath, #currentPath) do
        if targetParentPath[i].mapID == currentPath[i].mapID then
            dcaIndex = i
            dcaMapID = targetParentPath[i].mapID
        else
            break
        end
    end

    local dcaInfo = dcaMapID and GetMapInfo(dcaMapID)
    DebugPrint("[EasyFind] DCA:", dcaInfo and dcaInfo.name or "nil", "ID:", dcaMapID, "Index:", dcaIndex)

    if not dcaMapID then
        DebugPrint("[EasyFind] ERROR: No common ancestor, falling back to direct nav")
        WorldMapFrame:SetMapID(targetParentMapID)
        C_Timer.After(0.1, function()
            self:HighlightZone(targetMapID)
        end)
        return
    end

    -- CASE 2: Current map IS the deepest common ancestor
    if currentMapID == dcaMapID then
        DebugPrint("[EasyFind] CASE 2: We're at DCA, need to go DOWN toward target")
        local nextStepIndex = dcaIndex + 1
        if nextStepIndex <= #targetParentPath then
            local nextStepMapID = targetParentPath[nextStepIndex].mapID
            local nextStepInfo = GetMapInfo(nextStepMapID)
            DebugPrint("[EasyFind] Next step: highlight", nextStepInfo and nextStepInfo.name or "nil", "ID:", nextStepMapID)
            self.pendingZoneHighlight = targetMapID
            DebugPrint("[EasyFind] Set pendingZoneHighlight to", targetMapID)
            C_Timer.After(0.05, function()
                self:HighlightZone(nextStepMapID)
            end)
        else
            DebugPrint("[EasyFind] Edge case: at target parent, highlighting target")
            C_Timer.After(0.05, function()
                self:HighlightZone(targetMapID)
            end)
        end
        return
    end

    -- CASE 2b: Current zone-level map geographically contains the target even
    -- though it's not in the API parent chain (e.g. Azuremyst Isle contains
    -- Exodar, but Exodar's API parent is Kalimdor). Try HighlightZone directly
    -- before sending the user backwards via breadcrumbs.
    if currentInfo and currentInfo.mapType == Enum.UIMapType.Zone then
        local cL, cR, cT, cB = GetMapRectViaContinent(targetMapID, currentMapID)
        if cL then
            local cX, cY = (cL + cR) / 2, (cT + cB) / 2
            if cX > -0.1 and cX < 1.1 and cY > -0.1 and cY < 1.1 then
                DebugPrint("[EasyFind] CASE 2b: Target projects onto current zone, trying HighlightZone")
                self.pendingZoneHighlight = targetMapID
                C_Timer.After(0.05, function()
                    self:HighlightZone(targetMapID)
                end)
                return
            end
        end
    end

    -- CASE 3: Current map is BELOW the deepest common ancestor
    DebugPrint("[EasyFind] CASE 3: Need to zoom OUT to DCA, highlighting breadcrumb")
    self:HighlightBreadcrumbForNavigation(dcaMapID, targetMapID, targetParentPath, dcaIndex)
end

-- Get the full path from World/root to a given map
function MapSearch:GetMapPath(mapID)
    return GetMapPath(mapID)
end

-- Highlight a breadcrumb button to guide user to zoom out toward the target
function MapSearch:HighlightBreadcrumbForNavigation(dcaMapID, finalTargetMapID, targetParentPath, dcaIndex)
    DebugPrint("[EasyFind] HighlightBreadcrumbForNavigation: DCA=", dcaMapID, "finalTarget=", finalTargetMapID)

    self:ClearZoneHighlight()

    local navBar = WorldMapFrame.NavBar
    if not navBar then
        DebugPrint("[EasyFind] No NavBar found, direct nav to DCA")
        -- CRITICAL: Set pending BEFORE SetMapID because SetMapID triggers OnMapChanged synchronously!
        self.pendingZoneHighlight = finalTargetMapID
        DebugPrint("[EasyFind] Set pendingZoneHighlight BEFORE SetMapID:", finalTargetMapID)
        WorldMapFrame:SetMapID(dcaMapID)
        return
    end

    DebugPrint("[EasyFind] Searching for breadcrumb button for DCA ID:", dcaMapID)

    -- Try to find a visible breadcrumb button for the DCA
    local buttonToHighlight = self:FindBreadcrumbButton(navBar, dcaMapID)

    -- If not found, try each ancestor going up from DCA
    if not buttonToHighlight then
        DebugPrint("[EasyFind] DCA button not found, trying ancestors...")
        for i = dcaIndex - 1, 1, -1 do
            local ancestorMapID = targetParentPath[i] and targetParentPath[i].mapID
            if ancestorMapID then
                DebugPrint("[EasyFind] Trying ancestor:", ancestorMapID)
                buttonToHighlight = self:FindBreadcrumbButton(navBar, ancestorMapID)
                if buttonToHighlight then
                    DebugPrint("[EasyFind] Found button for ancestor:", ancestorMapID)
                    break
                end
            end
        end
    else
        DebugPrint("[EasyFind] Found button for DCA directly")
    end

    if buttonToHighlight and buttonToHighlight:IsShown() then
        DebugPrint("[EasyFind] Button found and shown, highlighting it")
        self:ShowBreadcrumbHighlight(buttonToHighlight, finalTargetMapID)
    else
        -- Walk the current map's parent chain (highest first) and find
        -- the first ancestor that has a visible breadcrumb button.
        DebugPrint("[EasyFind] No button found, walking current path for fallback")
        local currentMapID = WorldMapFrame:GetMapID()
        local currentPath = self:GetMapPath(currentMapID)
        for i = 1, #currentPath - 1 do  -- skip current map itself
            local breadcrumbBtn = self:FindBreadcrumbButton(navBar, currentPath[i].mapID)
            if breadcrumbBtn and breadcrumbBtn:IsShown() then
                buttonToHighlight = breadcrumbBtn
                DebugPrint("[EasyFind] Using path fallback:", currentPath[i].name, currentPath[i].mapID)
                break
            end
        end
        if buttonToHighlight then
            self.pendingZoneHighlight = finalTargetMapID
            self:ShowBreadcrumbHighlight(buttonToHighlight, finalTargetMapID)
        else
            DebugPrint("[EasyFind] No breadcrumb at all, navigating directly to DCA")
            -- CRITICAL: Set pending BEFORE SetMapID because SetMapID triggers OnMapChanged synchronously!
            self.pendingZoneHighlight = finalTargetMapID
            DebugPrint("[EasyFind] Set pendingZoneHighlight BEFORE SetMapID:", finalTargetMapID)
            WorldMapFrame:SetMapID(dcaMapID)
        end
    end
end

-- Find a breadcrumb button for a given map ID
function MapSearch:FindBreadcrumbButton(navBar, mapID)
    DebugPrint("[EasyFind] FindBreadcrumbButton looking for mapID:", mapID)

    -- The NavBar in WoW uses a different structure - buttons are direct children
    -- Let's iterate through children to find the right button
    for i = 1, select("#", navBar:GetChildren()) do
        local child = select(i, navBar:GetChildren())
        if child.GetID and child:GetID() == mapID then
            DebugPrint("[EasyFind] Found button via GetID:", mapID)
            return child
        end
        -- Also check for navButton property or data
        if child.data and child.data.id == mapID then
            DebugPrint("[EasyFind] Found button via data.id:", mapID)
            return child
        end
    end

    -- Check the navigation list - the button might be the entry itself
    if navBar.navList then
        DebugPrint("[EasyFind] navList has", #navBar.navList, "entries")
        for i, buttonData in ipairs(navBar.navList) do
            DebugPrint("[EasyFind]   navList[" .. i .. "] id:", buttonData.id, "type:", type(buttonData))
            -- The buttonData itself might BE the button frame
            if buttonData.id == mapID then
                -- Check if buttonData is a frame with Show/IsShown
                if buttonData.IsShown and buttonData:IsShown() then
                    DebugPrint("[EasyFind] buttonData itself is the button frame!")
                    return buttonData
                end
                -- Or maybe it has a different button reference
                if buttonData.Button then
                    DebugPrint("[EasyFind] Found buttonData.Button")
                    return buttonData.Button
                end
            end
        end
    else
        DebugPrint("[EasyFind] navBar.navList is nil!")
    end

    -- Check home button (usually World/Cosmic)
    if navBar.home and navBar.home:IsShown() then
        -- Cosmic map is always the home button; API name "Cosmic" differs
        -- from the display name "World" so ID/text checks fail
        local targetInfo = GetMapInfo(mapID)
        if targetInfo and targetInfo.mapType == Enum.UIMapType.Cosmic then
            DebugPrint("[EasyFind] Cosmic map requested, returning home button")
            return navBar.home
        end
        local homeMapID = navBar.home.id or (navBar.home.data and navBar.home.data.id)
        DebugPrint("[EasyFind] Home button ID:", homeMapID)
        if homeMapID == mapID then
            return navBar.home
        end
        -- Home button might match by text instead of ID
        if not homeMapID and navBar.home.GetText then
            local homeText = navBar.home:GetText()
            if homeText and targetInfo and homeText == targetInfo.name then
                DebugPrint("[EasyFind] Found home button via text:", homeText)
                return navBar.home
            end
        end
    else
        DebugPrint("[EasyFind] No home button or not shown")
    end

    -- Last resort: look for WorldMapNavBarButton frames
    local buttonName = "WorldMapNavBarButton"
    for i = 1, 10 do
        local mapBtn = _G[buttonName .. i]
        if mapBtn and mapBtn:IsShown() and mapBtn.data and mapBtn.data.id == mapID then
            DebugPrint("[EasyFind] Found via global name:", buttonName .. i)
            return mapBtn
        end
    end

    -- Text-based fallback: match button text to the map name
    local targetName = GetMapInfo(mapID)
    targetName = targetName and targetName.name
    if targetName then
        for i = 1, select("#", navBar:GetChildren()) do
            local child = select(i, navBar:GetChildren())
            if child:IsShown() and child.GetText then
                local text = child:GetText()
                if text and text == targetName then
                    DebugPrint("[EasyFind] Found button via text match:", text)
                    return child
                end
            end
        end
    end

    return nil
end

-- Show the highlight effect on a breadcrumb button
function MapSearch:ShowBreadcrumbHighlight(button, finalTargetMapID)
    DebugPrint("[EasyFind] ShowBreadcrumbHighlight, finalTarget:", finalTargetMapID)

    if not self.breadcrumbHighlight then
        local hl = CreateFrame("Frame", "EasyFindBreadcrumbHighlight", WorldMapFrame)
        hl:SetFrameStrata("TOOLTIP")
        hl:SetFrameLevel(300)

        hl:EnableMouse(false)

        local pulseAnim = hl:CreateAnimationGroup()
        pulseAnim:SetLooping("BOUNCE")
        local pulse = pulseAnim:CreateAnimation("Alpha")
        pulse:SetFromAlpha(1)
        pulse:SetToAlpha(0.3)
        pulse:SetDuration(0.8)
        hl.pulseAnim = pulseAnim

        -- Extra gold layers to boost brightness (single LockHighlight is too dim)
        local GLOW_LAYERS = 3
        hl.glowTextures = {}
        for i = 1, GLOW_LAYERS do
            local g = hl:CreateTexture(nil, "ARTWORK", nil, i)
            g:SetAllPoints()
            g:SetBlendMode("ADD")
            g:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
            g:Hide()
            hl.glowTextures[i] = g
        end

        -- Unlock the previous button's highlight when this frame hides,
        -- regardless of which clear path triggered it.
        hl:SetScript("OnHide", function(self)
            for _, g in ipairs(self.glowTextures) do g:Hide() end
            if self.button then
                if self.button.UnlockHighlight then self.button:UnlockHighlight() end
                local hlTex = self.button.GetHighlightTexture and self.button:GetHighlightTexture()
                if hlTex then
                    hlTex:SetBlendMode("BLEND")
                    hlTex:SetVertexColor(1, 1, 1, 1)
                end
                self.button = nil
            end
        end)

        -- Indicator pointing to button - parented to UIParent so it's not clipped
        -- by WorldMapFrame when extending above the map edge
        local bcIndFrame = CreateFrame("Frame", nil, UIParent)
        bcIndFrame:SetFrameStrata("TOOLTIP")
        bcIndFrame:SetFrameLevel(301)
        bcIndFrame:SetSize(ns.BREADCRUMB_SIZE, ns.BREADCRUMB_SIZE)
        bcIndFrame:SetPoint("BOTTOM", hl, "TOP", 0, 8)
        ns.CreateIndicatorTextures(bcIndFrame, ns.BREADCRUMB_SIZE, ns.ICON_GLOW_SIZE)

        local bcAnimGroup = bcIndFrame:CreateAnimationGroup()
        bcAnimGroup:SetLooping("BOUNCE")
        local bcMove = bcAnimGroup:CreateAnimation("Translation")
        bcMove:SetOffset(0, -10)
        bcMove:SetDuration(ANIM_DURATION)
        local bcAlpha = bcAnimGroup:CreateAnimation("Alpha")
        bcAlpha:SetFromAlpha(1)
        bcAlpha:SetToAlpha(0.4)
        bcAlpha:SetDuration(ANIM_DURATION)
        bcIndFrame.animGroup = bcAnimGroup
        bcIndFrame.bounceAnim = bcMove

        hl.indicatorFrame = bcIndFrame
        hl.indicator = bcIndFrame.indicator

        self.breadcrumbHighlight = hl
    end

    local hl = self.breadcrumbHighlight

    -- Unlock previous button if we're switching to a different one
    if hl.button and hl.button ~= button then
        if hl.button.UnlockHighlight then hl.button:UnlockHighlight() end
        local prevTex = hl.button.GetHighlightTexture and hl.button:GetHighlightTexture()
        if prevTex then
            prevTex:SetBlendMode("BLEND")
            prevTex:SetVertexColor(1, 1, 1, 1)
        end
    end
    hl.button = button

    if button.LockHighlight then button:LockHighlight() end
    local hlTex = button.GetHighlightTexture and button:GetHighlightTexture()
    if hlTex then
        hlTex:SetBlendMode("ADD")
        hlTex:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
    end

    -- Copy the button's highlight texture into our stacked glow layers
    for i = 1, #hl.glowTextures do
        local g = hl.glowTextures[i]
        if hlTex then
            local atlas = hlTex:GetAtlas()
            if atlas then
                g:SetAtlas(atlas)
            else
                g:SetTexture(hlTex:GetTexture())
                g:SetTexCoord(hlTex:GetTexCoord())
            end
            g:Show()
        else
            g:Hide()
        end
    end

    hl:ClearAllPoints()
    hl:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    hl:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    hl:Show()
    if hl.pulseAnim then hl.pulseAnim:Play() end

    if hl.indicatorFrame then
        self:UpdateBreadcrumbPosition()
        hl.indicatorFrame:Show()
        if hl.indicatorFrame.animGroup then
            hl.indicatorFrame.animGroup:Play()
        end
    end

    self.pendingZoneHighlight = finalTargetMapID
    DebugPrint("[EasyFind] ShowBreadcrumbHighlight - SET pendingZoneHighlight to:", finalTargetMapID)
end

-- Reposition the breadcrumb indicator for the current map mode.
-- In maximized mode, breadcrumbs are at the screen top edge so the indicator
-- goes below the button pointing up. In windowed mode it goes above pointing down.
-- Called from ShowBreadcrumbHighlight and from RepositionForMapMode so the
-- indicator stays correct when the user toggles between maximized and windowed.
function MapSearch:UpdateBreadcrumbPosition()
    local hl = self.breadcrumbHighlight
    if not hl or not hl.indicatorFrame then return end
    local indFrame = hl.indicatorFrame
    indFrame:ClearAllPoints()
    if mapIsMaximized then
        indFrame:SetPoint("TOP", hl, "BOTTOM", 0, -8)
        if indFrame.bounceAnim then
            indFrame.bounceAnim:SetOffset(0, 10)
        end
        indFrame.indicatorDirection = "up"
    else
        indFrame:SetPoint("BOTTOM", hl, "TOP", 0, 8)
        if indFrame.bounceAnim then
            indFrame.bounceAnim:SetOffset(0, -10)
        end
        indFrame.indicatorDirection = nil
    end
    ns.UpdateIndicator(indFrame)
    if indFrame:IsShown() and indFrame.animGroup then
        indFrame.animGroup:Stop()
        indFrame.animGroup:Play()
    end
end

-- Check if current map is a continent (has zone children)
function MapSearch:IsOnContinentMap()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return false end

    local mapInfo = GetMapInfo(mapID)
    if not mapInfo then return false end

    -- Continent type is 2, World is 1
    return mapInfo.mapType == Enum.UIMapType.Continent or mapInfo.mapType == Enum.UIMapType.World
end

function MapSearch:HookWorldMap()
    WorldMapFrame:HookScript("OnShow", function()
        -- Restore pins only if the player is in the pin's zone.
        -- Map opens to the player's current zone by default, so if they
        -- left the zone the pin was in, it's gone.
        if activePinState then
            local currentMapID = WorldMapFrame:GetMapID()
            local playerMapID = GetBestMapForUnit("player")
            if currentMapID == activePinState.mapID and playerMapID == activePinState.mapID then
                C_Timer.After(0, function()
                    if activePinState and activePinState.instances then
                        self:ShowMultipleWaypoints(activePinState.instances)
                    elseif activePinState then
                        self:ShowWaypointAt(activePinState.x, activePinState.y,
                            activePinState.icon, activePinState.category)
                    end
                end)
            else
                activePinState = nil
            end
        end
        -- Show tracked rares when no search pins to restore
        if not activePinState and EasyFind.db.alwaysShowRares then
            C_Timer.After(0, function()
                self:UpdateRareTracking()
            end)
        end
    end)

    WorldMapFrame:HookScript("OnHide", function()
        -- Hide high-strata visuals that would paint through the closed map.
        -- activePinState is preserved so they restore on reopen.
        self:ClearHighlight()
        self:ClearZoneHighlight()
        self.pendingWaypoint = nil
    end)

    if WorldMapFrame.IsMaximized then
        local function OnMapModeChange()
            mapIsMaximized = WorldMapFrame:IsMaximized()
            self:UpdateBreadcrumbPosition()
        end
        hooksecurefunc(WorldMapFrame, "Maximize", OnMapModeChange)
        hooksecurefunc(WorldMapFrame, "Minimize", OnMapModeChange)
        WorldMapFrame:HookScript("OnShow", OnMapModeChange)
    end

    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        local newMapID = WorldMapFrame:GetMapID()
        local newMapInfo = newMapID and GetMapInfo(newMapID)
        DebugPrint("[EasyFind] OnMapChanged - new map:", newMapInfo and newMapInfo.name or "nil", "ID:", newMapID)
        DebugPrint("[EasyFind] OnMapChanged - pendingZoneHighlight:", self.pendingZoneHighlight)

        -- Snapshot pendingZoneHighlight BEFORE clearing.
        -- pendingWaypoint is NOT wiped by ClearZoneHighlight so no snapshot needed.
        local savedPendingZone = self.pendingZoneHighlight

        self:ClearHighlight()
        self:ClearZoneHighlight()

        -- Clear breadcrumb highlight
        if self.breadcrumbHighlight then
            self.breadcrumbHighlight:Hide()
        end

        -- If we have both a pending zone AND a pending waypoint, check if the
        -- entrance is actually visible on the current map via the Encounter Journal
        -- API. This handles sub-zones (e.g. "City of Threads - Lower" inside
        -- Azj-Kahet) where the entrance pin is visible on the parent zone map
        -- but not on the continent map.
        if savedPendingZone and self.pendingWaypoint and self.pendingWaypoint.mapID then
            local wp = self.pendingWaypoint
            local currentMapID = WorldMapFrame:GetMapID()
            if wp.mapID ~= currentMapID and GetDungeonEntrancesForMap then
                local entrances = GetDungeonEntrancesForMap(currentMapID)
                if entrances then
                    for _, entrance in ipairs(entrances) do
                        if entrance.name and entrance.position then
                            -- Match by proximity - entrance coords are in current map space
                            -- Use GetMapRectOnMap to project wp coords to current map for comparison
                            local ok, left, right, top, bottom = pcall(GetMapRectOnMap, wp.mapID, currentMapID)
                            if ok and left and (right - left) > 0 then
                                local projX = left + wp.x * (right - left)
                                local projY = top  + wp.y * (bottom - top)
                                local dx = projX - entrance.position.x
                                local dy = projY - entrance.position.y
                                if (dx * dx + dy * dy) < 0.001 then
                                    DebugPrint("[EasyFind] OnMapChanged - entrance visible on current map, skipping zone nav")
                                    self.pendingWaypoint = nil
                                    self:ClearZoneHighlight()
                                    local ex, ey = entrance.position.x, entrance.position.y
                                    C_Timer.After(0.1, function()
                                        self:ShowWaypointAt(ex, ey, wp.icon, wp.category)
                                    end)
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Check if we have a pending zone to highlight (step-by-step navigation)
        if savedPendingZone then
            -- Match by ID or by name (handles zones with multiple mapIDs
            -- like Dalaran which has different IDs per expansion)
            local pendingInfo = GetMapInfo(savedPendingZone)
            local arrivedByName = pendingInfo and newMapInfo
                and pendingInfo.name == newMapInfo.name
            if newMapID == savedPendingZone or arrivedByName then
                -- Arrived at the target zone - stop reguiding
                DebugPrint("[EasyFind] OnMapChanged - arrived at target zone:", savedPendingZone)
                if self.pendingWaypoint then
                    local wp = self.pendingWaypoint
                    self.pendingWaypoint = nil
                    C_Timer.After(0.1, function()
                        self:ClearZoneHighlight()
                        self:ShowWaypointAt(wp.x, wp.y, wp.icon, wp.category)
                    end)
                end
            else
                -- Wrong zone or intermediate step - use full path-based navigation
                -- so multi-level chains (Cosmic → Azeroth → EK → Dun Morogh)
                -- work correctly instead of trying to render directly.
                DebugPrint("[EasyFind] OnMapChanged - reguiding to:", savedPendingZone)
                C_Timer.After(0.1, function()
                    self:HighlightZoneOnMap(savedPendingZone)
                end)
            end
        elseif self.pendingWaypoint then
            -- We arrived at a zone with a pending waypoint (e.g. dungeon entrance)
            local wp = self.pendingWaypoint
            self.pendingWaypoint = nil
            DebugPrint("[EasyFind] OnMapChanged - showing pending waypoint at:", wp.x, wp.y)

            C_Timer.After(0.1, function()
                self:ClearZoneHighlight()  -- Belt-and-suspenders: nuke any lingering zone highlight
                self:ShowWaypointAt(wp.x, wp.y, wp.icon, wp.category)
            end)
        else
            DebugPrint("[EasyFind] OnMapChanged - no pending, clearing highlights")
            -- Navigated to a different map - discard any stale pin state
            if activePinState and activePinState.mapID ~= newMapID then
                activePinState = nil
            end
            self:ClearZoneHighlight()
            -- Re-scan rares for the new zone
            if EasyFind.db.alwaysShowRares then
                C_Timer.After(0, function() self:UpdateRareTracking() end)
            end
        end
    end)

    -- Live-refresh always-on rare pins when rares spawn or despawn nearby.
    local vignetteFrame = CreateFrame("Frame")
    vignetteFrame:RegisterEvent("VIGNETTES_UPDATED")
    vignetteFrame:SetScript("OnEvent", function()
        -- Don't wipe a hover preview; the refresh will happen when
        -- the preview ends or the user interacts again.
        if MapSearch._previewing then return end
        if EasyFind.db.alwaysShowRares then
            MapSearch:UpdateRareTracking()
        end
    end)
end

function MapSearch:GetCategoryMatch(query)
    query = slower(query):match("^(.-)%s*$")
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

    -- Only add parent, NOT siblings
    -- Siblings are only included when searching for the parent category itself
    if catData and catData.parent then
        tinsert(related, catData.parent)
        -- Do NOT add sibling categories - that causes "pvp" to show "auction house"
    end

    -- Add children of this category (if searching for a parent like "service" or "travel")
    for catName, data in pairs(CATEGORIES) do
        if data.parent == category then
            tinsert(related, catName)
        end
    end

    return related
end

-- Continent-wide cache: maps lowercased instance name → owner zone mapID.
-- Built once per continent by walking the map hierarchy.  Used to reject
-- adjacent-zone bleed without a strict whitelist (entrances with no owner
-- in the hierarchy are kept - benefit of the doubt).
local continentInstanceOwners = {}  -- [continentID] = { [lowerName] = ownerZoneMapID }

local function GetContinentInstanceOwners(continentID)
    if continentInstanceOwners[continentID] then
        return continentInstanceOwners[continentID]
    end
    local owners = {}
    local function scan(parentID, ownerZoneID, depth)
        if depth > 5 then return end
        local children = GetMapChildrenInfo(parentID, nil, false)
        if children then
            for _, child in ipairs(children) do
                if child.name then
                    local mt = child.mapType
                    if mt == Enum.UIMapType.Dungeon or mt == Enum.UIMapType.Raid then
                        if ownerZoneID then
                            owners[slower(child.name)] = ownerZoneID
                        end
                        -- Don't recurse into dungeon/raid sub-floors
                    else
                        -- First Zone encountered becomes the owner; sub-zones inherit it
                        local newOwner = ownerZoneID
                        if not newOwner and mt == Enum.UIMapType.Zone then
                            newOwner = child.mapID
                        end
                        scan(child.mapID, newOwner, depth + 1)
                    end
                end
            end
        end
    end
    scan(continentID, nil, 0)
    continentInstanceOwners[continentID] = owners
    return owners
end

-- Scan dungeon/raid entrances for the given map using the Encounter Journal API.
-- Returns POI-style entries with name, position, category (dungeon/raid), and the zone mapID.
--
-- For zone-level maps (parent is Continent), two scans are performed:
--   1) The zone itself - filtered by continent-wide instance ownership so entrances
--      that belong to a DIFFERENT zone are rejected (e.g. Grim Batol appearing on
--      the Wetlands map when it belongs to Twilight Highlands).  Entrances with no
--      owner in the map hierarchy are kept (benefit of the doubt).
--   2) The parent continent - to catch entrances the EJ API only returns for a
--      neighboring zone.  Continent entrances owned by the current zone are included
--      with coordinates projected to zone space.
-- Check if a named instance entrance is visible on a given map.
-- Checks both EJ dungeons/raids and delve area POIs.
-- Returns x, y or nil.
function MapSearch:FindEntranceOnMap(name, mapID)
    local nameNorm = normalizeName(name)
    if GetDungeonEntrancesForMap then
        local entrances = GetDungeonEntrancesForMap(mapID)
        if entrances then
            for _, ej in ipairs(entrances) do
                if ej.name and ej.position then
                    local ejNorm = normalizeName(ej.name)
                    if ejNorm == nameNorm or sfind(ejNorm, nameNorm, 1, true) or sfind(nameNorm, ejNorm, 1, true) then
                        return ej.position.x, ej.position.y
                    end
                end
            end
        end
    end
    if GetDelvesForMap and GetAreaPOIInfo then
        local delveIDs = GetDelvesForMap(mapID)
        if delveIDs then
            for _, poiID in ipairs(delveIDs) do
                local dInfo = GetAreaPOIInfo(mapID, poiID)
                if dInfo and dInfo.name and dInfo.position then
                    local dNorm = normalizeName(dInfo.name)
                    if dNorm == nameNorm or sfind(dNorm, nameNorm, 1, true) or sfind(nameNorm, dNorm, 1, true) then
                        return dInfo.position.x, dInfo.position.y
                    end
                end
            end
        end
    end
    return nil
end

function MapSearch:ScanDungeonEntrances(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not GetDungeonEntrancesForMap then return {} end

    local results = {}
    local seen = {}  -- dedup by entrance name
    local mapInfo = GetMapInfo(mapID)
    local parentInfo = mapInfo and mapInfo.parentMapID and GetMapInfo(mapInfo.parentMapID)
    local parentLabel = mapInfo and mapInfo.name or ""

    -- For zone-level maps (parent is Continent), use the continent-wide ownership
    -- map to filter adjacent-zone bleed.
    local useContinent = parentInfo and parentInfo.mapType == Enum.UIMapType.Continent
    local continentID = useContinent and parentInfo.mapID or nil
    local owners = continentID and GetContinentInstanceOwners(continentID) or nil

    -- Pre-compute zone ↔ continent projection rect (for pass 2 coordinate conversion)
    local canProject = false
    local zL, zR, zT, zB
    if useContinent and continentID then
        local ok
        ok, zL, zR, zT, zB = pcall(GetMapRectOnMap, mapID, continentID)
        canProject = ok and zL and (zR - zL) > 0 and (zB - zT) > 0
    end

    -- Helper: classify and append an entrance
    local function addEntrance(entrance, ex, ey)
        if seen[entrance.name] then return end
        seen[entrance.name] = true
        local cat = "dungeon"
        if entrance.journalInstanceID and EJ_GetInstanceInfo then
            local _, _, _, _, _, _, _, _, _, _, _, entIsRaid = EJ_GetInstanceInfo(entrance.journalInstanceID)
            if entIsRaid then cat = "raid" end
        end
        local kw = {cat, "instance", "entrance"}
        local abbrs = ns.INSTANCE_ABBRS and ns.INSTANCE_ABBRS[slower(entrance.name)]
        if abbrs then
            for ai = 1, #abbrs do kw[#kw + 1] = abbrs[ai] end
        end
        local entry = {
            name = entrance.name,
            category = cat,
            icon = nil,  -- use category icon
            isStatic = true,
            isDungeonEntrance = true,
            entranceMapID = mapID,
            x = ex,
            y = ey,
            pathPrefix = parentLabel,
            keywords = kw,
        }
        tinsert(results, PreparePOI(entry))
    end

    -- Pass 1: scan the zone directly; exclude entrances owned by a different zone
    local zoneEntrances = GetDungeonEntrancesForMap(mapID)
    if zoneEntrances then
        for _, entrance in ipairs(zoneEntrances) do
            if entrance.name and entrance.position then
                local include = true
                if owners then
                    local ownerZone = owners[slower(entrance.name)]
                    -- Exclude only if a DIFFERENT zone owns it; nil = no owner, keep it
                    if ownerZone and ownerZone ~= mapID then
                        include = false
                    end
                end
                if include then
                    addEntrance(entrance, entrance.position.x, entrance.position.y)
                end
            end
        end
    end

    -- Pass 2: scan the continent to pick up entrances the EJ API only returns
    -- for a neighboring zone.  Project continent coords → zone coords.
    if canProject and continentID and owners then
        local contEntrances = GetDungeonEntrancesForMap(continentID)
        if contEntrances then
            for _, entrance in ipairs(contEntrances) do
                if entrance.name and entrance.position and not seen[entrance.name] then
                    local ownerZone = owners[slower(entrance.name)]
                    if ownerZone == mapID then
                        local cx, cy = entrance.position.x, entrance.position.y
                        local zx = (cx - zL) / (zR - zL)
                        local zy = (cy - zT) / (zB - zT)
                        addEntrance(entrance, zx, zy)
                    end
                end
            end
        end
    end

    return results
end

-- Lazily-built cache of dungeon/raid/delve entrances across the entire world.
-- Built once on first global search, then reused.
local globalInstanceCache
local cachedAllFlightMasters
local ResetSearchPoisCache

-- Invalidate map caches when Blizzard signals the map/world state may
-- have become richer. Without this, a first-search call runs before
-- some lazy map APIs have finished populating and both caches end up
-- partial; later searches reuse the stale cache and miss descendant
-- zones (e.g. Northrend's children) entirely.
local localScanCache = nil
local staticLocationCache = {}
local emptyStaticLocations = {}
local emptyFlightMasters = {}
-- Cache of promoted instance POIs (zone-style entries with breadcrumb
-- paths) so BuildResults doesn't allocate ~300 new tables per keystroke.
-- Built once when globalInstanceCache + cachedWorldZones are ready,
-- invalidated alongside them.
local promotedInstancePOIs = nil

local function ReleaseGlobalMapCaches()
    globalInstanceCache = nil
    promotedInstancePOIs = nil
    cachedAllFlightMasters = nil
    MapSearch._cachedFlightMasters = nil
    if ResetSearchPoisCache then ResetSearchPoisCache() end
end

local function CollectMapGarbage()
    if collectgarbage then
        collectgarbage("step", 300)
        collectgarbage("step", 300)
    end
end

do
    local invalidator = CreateFrame("Frame")
    invalidator:RegisterEvent("PLAYER_ENTERING_WORLD")
    invalidator:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    invalidator:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
    invalidator:SetScript("OnEvent", function()
        cachedWorldZones = nil
        wipe(worldZonePrefixIndex)
        wipe(worldZonePrefixSeen)
        worldZonePrefixReady = false
        globalInstanceCache = nil
        promotedInstancePOIs = nil
        localScanCache = nil
        wipe(staticLocationCache)
        -- Use namespace lookups for reset helpers defined further down
        -- in the file; locals declared after this invalidator block
        -- aren't visible to its closure.
        if ns.MapSearch.ResetSearchZonesCache then ns.MapSearch.ResetSearchZonesCache() end
        if ns.MapSearch.ResetSearchPoisCache  then ns.MapSearch.ResetSearchPoisCache()  end
        if C_Timer and C_Timer.After then
            C_Timer.After(0.2, function()
                if ns.MapSearch.BuildWorldZoneCache then ns.MapSearch:BuildWorldZoneCache() end
            end)
        elseif ns.MapSearch.BuildWorldZoneCache then
            ns.MapSearch:BuildWorldZoneCache()
        end
    end)
end

-- Local-scope caches (SearchZones local_, SearchPOIs local_,
-- localScanCache) are tied to whichever map WorldMapFrame currently
-- shows — its direct child zones, dungeon entrances, etc. The
-- character-zone events above DON'T fire when the player navigates
-- the world map UI to another zone, so without this hook a previous
-- map's child zones would bleed into "This Zone (currentMap)" results.
do
    local function FlushLocalCaches()
        localScanCache = nil
        wipe(staticLocationCache)
        if ns.MapSearch.ResetSearchZonesCache then ns.MapSearch.ResetSearchZonesCache() end
        if ns.MapSearch.ResetSearchPoisCache  then ns.MapSearch.ResetSearchPoisCache()  end
    end
    if WorldMapFrame and type(WorldMapFrame.OnMapChanged) == "function" then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", FlushLocalCaches)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            if WorldMapFrame and type(WorldMapFrame.OnMapChanged) == "function" then
                hooksecurefunc(WorldMapFrame, "OnMapChanged", FlushLocalCaches)
            end
        end)
    end
end

-- Runs every scan needed for local-mode BuildResults in one shot and
-- caches the result keyed on mapID. Typing `delve` used to rescan the
-- current map's POIs, dungeon entrances, flight masters, and vignettes
-- on every keystroke — each scan calls Blizzard APIs repeatedly and
-- adds up to hundreds of milliseconds per search in a busy zone. A
-- 1-second TTL is long enough to coalesce a typing burst but short
-- enough that a freshly-placed pin shows up on the user's next natural
-- pause.
local function GetLocalScans(self, mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()) or 0
    local includeFlightMasters = MapTabFlightPathsEnabled()
    local cache = localScanCache
    if cache and cache.mapID == mapID and cache.includeFlightMasters == includeFlightMasters then
        return cache.dynamicPOIs, cache.dungeonEntrances,
               cache.flightMasters, cache.vignetteRares
    end
    local dynamicPOIs      = self:ScanMapPOIs(mapID)
    local dungeonEntrances = self:ScanDungeonEntrances(mapID)
    local flightMasters    = includeFlightMasters and self:ScanFlightMasters(mapID) or emptyFlightMasters
    local vignetteRares    = self:ScanVignettes(mapID)
    localScanCache = {
        mapID = mapID,
        includeFlightMasters = includeFlightMasters,
        dynamicPOIs = dynamicPOIs, dungeonEntrances = dungeonEntrances,
        flightMasters = flightMasters, vignetteRares = vignetteRares,
    }
    return dynamicPOIs, dungeonEntrances, flightMasters, vignetteRares
end

function MapSearch:GetGlobalInstanceCache()
    if globalInstanceCache then return globalInstanceCache end

    globalInstanceCache = {}
    local seen = {}      -- deduplicate exact same name+mapID pair
    local nameSeen = {}  -- one entry per instance name (shallowest zone wins)

    -- Recursively collect all mapIDs from the Cosmic map (946).
    -- The recursion visits parent zones before their children, so the first
    -- entry discovered for a given dungeon name is always the shallowest
    -- (most general) zone - e.g. Azj-Kahet before City of Threads.
    -- We keep only that first entry to avoid duplicate search results and
    -- to maximise the chance that entranceMapID == the user's current map.
    local function collectMaps(parentMapID)
        local children = GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end
        for _, child in ipairs(children) do
            -- Dungeon entrances from the encounter journal
            local entrances = self:ScanDungeonEntrances(child.mapID)
            for _, e in ipairs(entrances) do
                local key = e.name .. "|" .. child.mapID
                if not seen[key] then
                    seen[key] = true
                    local nameKey = normalizeName(e.name)
                    if not nameSeen[nameKey] then
                        nameSeen[nameKey] = true
                        tinsert(globalInstanceCache, e)
                    end
                end
            end

            -- Delve entrances via dedicated API (separate from EJ dungeons/raids)
            if GetDelvesForMap then
                local delveIDs = GetDelvesForMap(child.mapID)
                if delveIDs then
                    local childInfo
                    for _, poiID in ipairs(delveIDs) do
                        local dInfo = GetAreaPOIInfo(child.mapID, poiID)
                        if dInfo and dInfo.name and dInfo.position then
                            local dKey = dInfo.name .. "|" .. child.mapID
                            if not seen[dKey] then
                                seen[dKey] = true
                                local dNameKey = normalizeName(dInfo.name)
                                if not nameSeen[dNameKey] then
                                    nameSeen[dNameKey] = true
                                    if not childInfo then childInfo = GetMapInfo(child.mapID) end
                                    local entry = {
                                        name = dInfo.name,
                                        category = "delve",
                                        icon = nil,
                                        isStatic = true,
                                        isDungeonEntrance = true,
                                        entranceMapID = child.mapID,
                                        x = dInfo.position.x,
                                        y = dInfo.position.y,
                                        pathPrefix = childInfo and childInfo.name or "",
                                        keywords = {"delve", "delves", "instance"},
                                    }
                                    tinsert(globalInstanceCache, PreparePOI(entry))
                                end
                            end
                        end
                    end
                end
            end

            -- Static locations with whitelisted categories (e.g. future delve POIs)
            local locs = STATIC_LOCATIONS[child.mapID]
            if locs then
                local mapInfo = GetMapInfo(child.mapID)
                local mapName = mapInfo and mapInfo.name or ""
                for _, loc in ipairs(locs) do
                    if GLOBAL_SEARCH_CATEGORIES[loc.category] then
                        local skey = loc.name .. "|" .. child.mapID
                        if not seen[skey] then
                            seen[skey] = true
                            local nameKey = normalizeName(loc.name)
                            if not nameSeen[nameKey] then
                                nameSeen[nameKey] = true
                                local entry = {
                                    name = loc.name,
                                    category = loc.category,
                                    icon = loc.icon,
                                    isStatic = true,
                                    isDungeonEntrance = true,
                                    entranceMapID = child.mapID,
                                    x = loc.x,
                                    y = loc.y,
                                    pathPrefix = mapName,
                                    keywords = loc.keywords,
                                }
                                tinsert(globalInstanceCache, PreparePOI(entry))
                            end
                        end
                    end
                end
            end

            collectMaps(child.mapID)
        end
    end

    collectMaps(946)  -- Start from Cosmic
    return globalInstanceCache
end

local function BuildPromotedInstanceCache(self)
    if promotedInstancePOIs then return promotedInstancePOIs end

    local zones = self:BuildWorldZoneCache()
    local instancePOIs = self:GetGlobalInstanceCache()
    local pathForMap = {}
    local parts = {}
    for _, zone in ipairs(zones) do
        if zone.path and not pathForMap[zone.mapID] then
            wipe(parts)
            for _, p in ipairs(zone.path) do
                parts[#parts + 1] = p.name
            end
            parts[#parts + 1] = zone.name
            pathForMap[zone.mapID] = tconcat(parts, " > ")
        end
    end

    promotedInstancePOIs = {}
    for _, poi in ipairs(instancePOIs) do
        local fullPath = pathForMap[poi.entranceMapID]
        local entry = {
            name = poi.name, category = poi.category, icon = poi.icon,
            isZone = true, isStatic = poi.isStatic,
            isDungeonEntrance = poi.isDungeonEntrance,
            zoneMapID = poi.entranceMapID, entranceMapID = poi.entranceMapID,
            entranceX = poi.x, entranceY = poi.y,
            entranceIcon = poi.icon, entranceCategory = poi.category,
            pathPrefix = fullPath or poi.pathPrefix, keywords = poi.keywords,
        }
        promotedInstancePOIs[#promotedInstancePOIs + 1] = PreparePOI(entry)
    end
    return promotedInstancePOIs
end

function MapSearch:BuildGlobalSearchCaches()
    self:BuildWorldZoneCache()
    self:GetGlobalInstanceCache()
    BuildPromotedInstanceCache(self)
    local mapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())
    if mapID and WorldMapFrame then
        GetLocalScans(self, mapID)
        self:GetStaticLocations(mapID)
    end
end

function MapSearch:WarmUISearchCaches()
    self:BuildWorldZoneCache()
    local mapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())
    if mapID and WorldMapFrame then
        GetLocalScans(self, mapID)
        self:GetStaticLocations(mapID)
    end
end

-- Scan flight masters for the given map using the TaxiMap API
-- Returns POI-style entries with name, position, and flightmaster category
function MapSearch:ScanFlightMasters(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not C_TaxiMap or not C_TaxiMap.GetTaxiNodesForMap then return {} end

    local results = {}
    local nodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
    if not nodes then return results end

    local playerFaction = UnitFactionGroup("player")
    local FPFaction = Enum.FlightPathFaction

    -- Only filter adjacent-zone bleed on zone-level maps (parent is Continent).
    local fmMapInfo = GetMapInfo(mapID)
    local fmParentInfo = fmMapInfo and fmMapInfo.parentMapID and GetMapInfo(fmMapInfo.parentMapID)
    local fmShouldFilter = fmParentInfo and fmParentInfo.mapType == Enum.UIMapType.Continent
    -- Continent-level scans need per-node zone resolution so each FM
    -- gets the actual child zone it belongs to (Hillsbrad, EP, etc.)
    -- rather than the continent. MapTab uses parentMapID for zone-level
    -- sub-grouping under the continent header.
    local resolvePerNode = (fmMapInfo and fmMapInfo.mapType == Enum.UIMapType.Continent) or fmShouldFilter

    for _, node in ipairs(nodes) do
        if node.name and node.position then
            -- Skip flight paths restricted to the opposing faction
            local skip = false
            if node.faction and FPFaction then
                if (node.faction == FPFaction.Horde and playerFaction ~= "Horde")
                    or (node.faction == FPFaction.Alliance and playerFaction ~= "Alliance") then
                    skip = true
                end
            end
            if not skip then
                local x, y = node.position.x, node.position.y
                if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    local fmInclude = true
                    local nodeParentMapID = mapID
                    if resolvePerNode then
                        local posInfo = GetMapInfoAtPosition and GetMapInfoAtPosition(mapID, x, y)
                        if posInfo and posInfo.mapID then
                            nodeParentMapID = posInfo.mapID
                            if fmShouldFilter then
                                fmInclude = (posInfo.mapID == mapID or posInfo.parentMapID == mapID)
                            end
                        elseif fmShouldFilter then
                            fmInclude = false
                        end
                    end
                    if fmInclude then
                        local entry = {
                            name = node.name .. " (Flight Master)",
                            category = "flightmaster",
                            icon = "atlas:TaxiNode_Neutral",
                            isStatic = true,
                            x = x,
                            y = y,
                            parentMapID = nodeParentMapID,
                            -- (x,y) are valid on this map's coordinate system.
                            -- Used to gate hover previews so an FM scanned in
                            -- one zone doesn't render a pin in another.
                            coordMapID = mapID,
                            keywords = {"flight", "fly", "taxi", "fp", "flight master"},
                        }
                        tinsert(results, PreparePOI(entry))
                    end
                end
            end
        end
    end
    return results
end

-- Scan flight masters across ALL zone-type maps for global search
-- Results are cached since flight point positions don't change mid-session
function MapSearch:ScanAllFlightMasters()
    if cachedAllFlightMasters then return cachedAllFlightMasters end
    if not C_TaxiMap or not C_TaxiMap.GetTaxiNodesForMap then return {} end

    local allNodes = {}
    local seen = {}

    local function collectFromMaps(parentMapID, depth)
        if depth > 6 then return end
        local children = GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end

        for _, child in ipairs(children) do
            if child.name then
                local mt = child.mapType
                -- Zones only. A continent scan returns the same nodes
                -- as its child zones (just expressed in continent
                -- coordinates), and the recursion below already covers
                -- every zone — so scanning continents would just
                -- produce a duplicate of every FM with a coordMapID
                -- that's wrong for whichever map the player is viewing.
                if mt == Enum.UIMapType.Zone then
                    local nodes = self:ScanFlightMasters(child.mapID)
                    for _, node in ipairs(nodes) do
                        local key = node.name .. "|" .. child.mapID
                        if not seen[key] then
                            seen[key] = true
                            -- Add zone path prefix like dungeon entrances do
                            local mapInfo = GetMapInfo(child.mapID)
                            node.pathPrefix = mapInfo and mapInfo.name or ""
                            tinsert(allNodes, node)
                        end
                    end
                end
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    collectFromMaps(child.mapID, depth + 1)
                end
            end
        end
    end

    local cosmicChildren = GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            collectFromMaps(child.mapID, 0)
        end
    end

    cachedAllFlightMasters = allNodes
    MapSearch._cachedFlightMasters = allNodes
    return allNodes
end

-- Scan dungeon entrances across ALL zone-type maps for global search.
-- Results are cached since instance discovery doesn't change mid-session.
function MapSearch:GetStaticLocations(mapID)
    mapID = mapID or (WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
    if not mapID then return emptyStaticLocations end

    local includeDevPOIs = EasyFindDevDB and EasyFindDevDB.rawPOIs
    local cached = not includeDevPOIs and staticLocationCache[mapID]
    if cached then return cached end

    local results = {}

    -- Get built-in static locations
    local locations = STATIC_LOCATIONS[mapID]
    if locations then
        for _, loc in ipairs(locations) do
            local entry = {
                name = loc.name,
                category = loc.category,
                icon = loc.icon,  -- nil is fine, GetCategoryIcon will handle it
                isStatic = true,
                x = loc.x,
                y = loc.y,
                keywords = loc.keywords,
            }
            tinsert(results, PreparePOI(entry))
        end
    end

    -- Also check EasyFindDevDB for dev/testing (raw POIs from recorder)
    -- Skip dev POIs whose names already exist in built-in static locations
    if includeDevPOIs then
        local staticNames = {}
        if locations then
            for _, loc in ipairs(locations) do
                staticNames[slower(loc.name)] = true
            end
        end
        for _, poi in ipairs(includeDevPOIs) do
            if poi.mapID == mapID and not staticNames[slower(poi.label or "")] then
                local entry = {
                    name = poi.label,
                    category = poi.category or "unknown",
                    icon = nil,  -- Let category icon be used
                    isStatic = true,
                    x = poi.x,
                    y = poi.y,
                    keywords = {},
                }
                tinsert(results, PreparePOI(entry))
            end
        end
    end

    if not includeDevPOIs then
        staticLocationCache[mapID] = results
    end
    return results
end

function MapSearch:ScanVignettes(mapID)
    local rares = {}
    if not GetVignettes then return rares end

    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return rares end
    local playerMapID = GetBestMapForUnit("player")

    local guids = GetVignettes()
    if not guids then return rares end

    for _, guid in ipairs(guids) do
        local info = GetVignetteInfo and GetVignetteInfo(guid)
        if info and info.name and not info.isDead then
            local atlas = info.atlasName
            if atlas == "VignetteKill" or atlas == "VignetteKillElite" then
                -- Try viewed map first, fall back to player's zone (sub-zone mismatch)
                local pos = GetVignettePosition(guid, mapID)
                if not pos and playerMapID and playerMapID ~= mapID then
                    pos = GetVignettePosition(guid, playerMapID)
                end
                if pos then
                    local entry = {
                        name = info.name,
                        category = "rare",
                        icon = CATEGORY_ICONS.rare,
                        x = pos.x,
                        y = pos.y,
                        vignetteGUID = guid,
                        keywords = {"rare", "rares"},
                    }
                    rares[#rares + 1] = PreparePOI(entry)
                end
            end
        end
    end

    -- Aggregate "Rares" entry always present so the tracking toggle is accessible
    local instances = {}
    for _, rare in ipairs(rares) do
        instances[#instances + 1] = rare
    end
    local aggregate = {
        name = "Rares",
        category = "rare",
        icon = CATEGORY_ICONS.rare,
        keywords = {"rare", "rares"},
        isAggregate = true,
        allInstances = instances,
    }
    rares[#rares + 1] = PreparePOI(aggregate)

    return rares
end

function MapSearch:UpdateRareTracking()
    if not EasyFind.db.alwaysShowRares then
        self:ClearHighlight()
        return
    end
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    if activePinState or self._previewing then return end

    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return end

    -- Only show rare pins when viewing the player's zone
    local playerMapID = GetBestMapForUnit("player")
    if mapID ~= playerMapID then
        self:ClearHighlight()
        return
    end

    -- Clear caches on zone change
    if mapID ~= rareTrackMapID then
        wipe(rareTrackCache)
        wipe(rareDeadGUIDs)
        rareTrackMapID = mapID
    end

    -- Merge fresh scan into cache, skipping GUIDs confirmed dead
    local rares = self:ScanVignettes()
    local activeGUIDs = {}
    for _, rare in ipairs(rares) do
        if not rare.isAggregate and rare.vignetteGUID and not rareDeadGUIDs[rare.vignetteGUID] then
            activeGUIDs[rare.vignetteGUID] = true
            rare.inRange = true
            rareTrackCache[rare.vignetteGUID] = rare
        end
    end

    -- Prune: if a rare was in range last update but is now gone, it died/despawned.
    -- Mark as dead so it won't re-enter the cache from corpse vignettes.
    for guid, rare in pairs(rareTrackCache) do
        if not activeGUIDs[guid] then
            if rare.inRange then
                rareTrackCache[guid] = nil
                rareDeadGUIDs[guid] = true
            end
        end
    end

    -- Build display list from cache
    local individuals = {}
    for _, rare in pairs(rareTrackCache) do
        if rare.x and rare.y then
            individuals[#individuals + 1] = rare
        end
    end

    if #individuals > 0 then
        self:ShowMultipleWaypoints(individuals)
    else
        self:ClearHighlight()
    end
end

function MapSearch:ScanMapPOIs(mapID)
    local pois = {}
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return pois end

    local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if not canvas then return pois end

    -- First: Use WoW's API to get Area POIs directly (boats, zeppelins, portals, etc)
    -- Only include POIs we can categorize as useful (travel, services)
    -- Skip generic area POIs like landmarks, zone markers, events
    local areaPOIs = GetAreaPOIForMap(mapID)
    if areaPOIs then
        for _, poiID in ipairs(areaPOIs) do
            local poiInfo = GetAreaPOIInfo(mapID, poiID)
            -- Skip POIs that are shown on this map but primarily
            -- belong to an adjacent map (e.g. a boat dock near a zone
            -- border that renders on both zones' maps). Keeps each POI
            -- attributed to its home zone only.
            if poiInfo and poiInfo.isPrimaryMapForPOI == false then
                poiInfo = nil
            end
            if poiInfo and poiInfo.name then
                local category = nil  -- Start with nil, only add if we categorize it
                local poiName = slower(poiInfo.name or "")
                local desc = slower(poiInfo.description or "")

                -- Only categorize POIs we actually want to show
                if sfind(poiName, "zeppelin") or sfind(poiName, "airship") or sfind(desc, "zeppelin") then
                    category = "zeppelin"
                elseif sfind(poiName, "boat") or sfind(poiName, "ship") or sfind(poiName, "ferry") or sfind(desc, "boat") then
                    category = "boat"
                elseif sfind(poiName, "portal") and not sfind(poiName, "dark portal") or sfind(desc, "teleport") then
                    -- Include portals but not "The Dark Portal" which is a landmark
                    category = "portal"
                elseif sfind(poiName, "tram") or sfind(desc, "tram") then
                    category = "tram"
                elseif sfind(poiName, "great vault") then
                    category = "greatvault"
                elseif sfind(poiName, "catalyst") then
                    category = "catalyst"
                elseif sfind(poiName, "auction") then
                    category = "auctionhouse"
                elseif sfind(poiName, "bank") and not sfind(poiName, "moat") then
                    category = "bank"
                elseif sfind(poiName, "innkeeper") or sfind(poiName, "inn") then
                    category = "innkeeper"
                elseif sfind(poiName, "flight master") or sfind(poiName, "flight point") then
                    category = "flightmaster"
                elseif sfind(poiName, "trading post") then
                    category = "tradingpost"
                elseif sfind(poiName, "quartermaster") then
                    category = "quartermaster"
                elseif sfind(poiName, "decor") then
                    category = "decor"
                elseif sfind(poiName, "conquest") or sfind(poiName, "honor") or sfind(poiName, "pvp") then
                    category = "pvpvendor"
                elseif sfind(poiName, "chromie") then
                    category = "chromie"
                end

                -- Only add POIs we've explicitly categorized (skips generic landmarks, zone markers, events, etc.)
                if category then
                    local entry = {
                        name = poiInfo.name,
                        pin = nil,  -- API-based, no pin reference
                        pinType = category,
                        category = category,
                        icon = nil,  -- Use category icon, not textureIndex (which is an atlas)
                        isStatic = true,
                        x = poiInfo.position.x,
                        y = poiInfo.position.y,
                    }
                    tinsert(pois, PreparePOI(entry))
                end
            end
        end
    end

    -- Delve entrances via dedicated API (not returned by GetAreaPOIForMap)
    if GetDelvesForMap then
        local delveIDs = GetDelvesForMap(mapID)
        if delveIDs then
            for _, delvePoiID in ipairs(delveIDs) do
                local dInfo = GetAreaPOIInfo(mapID, delvePoiID)
                if dInfo and dInfo.name and dInfo.position then
                    local entry = {
                        name = dInfo.name,
                        category = "delve",
                        icon = nil,
                        isStatic = true,
                        isDungeonEntrance = true,
                        x = dInfo.position.x,
                        y = dInfo.position.y,
                        keywords = {"delve", "delves", "instance"},
                    }
                    tinsert(pois, PreparePOI(entry))
                end
            end
        end
    end

    -- Second: Scan all children of the map canvas for pins
    for i = 1, select("#", canvas:GetChildren()) do
        local pin = select(i, canvas:GetChildren())
        if pin and pin:IsShown() then
            local info = self:GetPinInfo(pin)
            if info then
                tinsert(pois, info)
            end
        end
    end

    -- Dedupe: when both the API path and the canvas-children scan report the
    -- same POI (same category at the same coordinates), keep the canvas-scan
    -- entry because it carries a live pin reference. SelectResult uses that
    -- reference to glow the native icon in place instead of stamping an
    -- overlay icon on top.
    local deduped = {}
    local seenByKey = {}
    for _, poi in ipairs(pois) do
        local key
        if poi.x and poi.y and poi.category then
            key = poi.category .. "|" .. mfloor(poi.x * 1000) .. "|" .. mfloor(poi.y * 1000)
        end
        if not key then
            tinsert(deduped, poi)
        else
            local existingIdx = seenByKey[key]
            if not existingIdx then
                tinsert(deduped, poi)
                seenByKey[key] = #deduped
            elseif poi.pin and not deduped[existingIdx].pin then
                deduped[existingIdx] = poi
            end
        end
    end
    return PreparePOIList(deduped)
end

-- Generic glow/waypoint atlases stacked on every native pin. Skipped when
-- looking for the pin's distinguishing icon.
local PIN_SKIP_ATLAS = {
    ["Waypoint-MapPin-Tracked"]   = true,
    ["Waypoint-MapPin-Untracked"] = true,
    ["UI-QuestPoi-OuterGlow"]     = true,
}

-- Native Blizzard pin atlases we recognize by sight. Used as a fallback when
-- the pin's other Lua metadata (areaPoiInfo, vignetteInfo) doesn't categorize
-- it - some data providers expose pins as plain Frames with only an atlas to
-- tell you what they are (e.g., trading post, quartermaster, chromie).
local PIN_ATLAS_TYPES = {
    ["ChromieTime-32x32"]         = { name = "Chromie",       category = "chromie" },
    ["trading-post-minimap-icon"] = { name = "Trading Post",  category = "tradingpost" },
    ["Quartermaster"]             = { name = "Quartermaster", category = "quartermaster" },
}

-- Inspect a pin's textures and return the first known atlas identity, plus
-- the first non-generic ARTWORK atlas as a fallback icon. atlasName /
-- atlasCategory are nil when the pin has no recognized atlas; atlasIcon may
-- still be set (any non-generic ARTWORK atlas).
local function ScanPinAtlasIdentity(pin)
    local atlasName, atlasCategory, atlasIcon
    for _, region in pairs({pin:GetRegions()}) do
        if region.GetAtlas then
            local a = region:GetAtlas()
            if a and a ~= "" and not PIN_SKIP_ATLAS[a]
               and region:GetDrawLayer() == "ARTWORK" then
                if not atlasIcon then
                    atlasIcon = "atlas:" .. a
                end
                if not atlasName then
                    local known = PIN_ATLAS_TYPES[a]
                    if known then
                        atlasName = known.name
                        atlasCategory = known.category
                    end
                end
            end
        end
    end
    return atlasName, atlasCategory, atlasIcon
end

function MapSearch:GetPinInfo(pin)
    if not pin or not pin:IsShown() then return nil end

    -- Pre-scan atlases. Used as a fallback for any code path below that
    -- would otherwise return nil due to unrecognized areaPoiInfo names or
    -- vignette types we don't normally track.
    local atlasName, atlasCategory, atlasIcon = ScanPinAtlasIdentity(pin)

    local name = nil
    local icon = atlasIcon
    local pinType = "unknown"
    local category = nil

    -- Flight masters - handled by ScanFlightMasters() with proper zone filtering
    if pin.taxiNodeData then
        return nil
    end

    -- Delve entrance pins
    if pin.pinTemplate == "DelveEntrancePinTemplate" and pin.name then
        return {
            name = pin.name,
            pin = pin,
            pinType = "delve",
            category = "delve",
            icon = nil,
            isStatic = false,
            isDungeonEntrance = true,
            x = pin.normalizedX,
            y = pin.normalizedY,
        }
    end

    -- Area POIs (boats, zeppelins, portals, etc) - but NOT quests
    if pin.areaPoiInfo then
        name = pin.areaPoiInfo.name or pin.areaPoiInfo.description

        local poiName = slower(name or "")
        local poiDesc = slower(pin.areaPoiInfo.description or "")
        if sfind(poiName, "zeppelin") or sfind(poiName, "airship") then
            category = "zeppelin"
            pinType = "zeppelin"
        elseif sfind(poiName, "boat") or sfind(poiName, "ship") or sfind(poiName, "ferry") then
            category = "boat"
            pinType = "boat"
        elseif sfind(poiName, "portal") then
            category = "portal"
            pinType = "portal"
        elseif sfind(poiName, "tram") then
            category = "tram"
            pinType = "tram"
        elseif sfind(poiName, "quartermaster") then
            category = "quartermaster"
            pinType = "quartermaster"
        elseif sfind(poiName, "decor") then
            category = "decor"
            pinType = "decor"
        elseif sfind(poiName, "pvp") or sfind(poiName, "arena") or sfind(poiName, "battleground") or sfind(poiDesc, "pvp") or sfind(poiName, "conquest") or sfind(poiName, "honor") or sfind(poiName, "weekly") then
            category = "pvpvendor"
            pinType = "pvpvendor"
        elseif sfind(poiName, "trading post") then
            category = "tradingpost"
            pinType = "tradingpost"
        elseif sfind(poiName, "chromie") then
            category = "chromie"
            pinType = "chromie"
            icon = "atlas:ChromieTime-32x32"
        elseif atlasCategory then
            -- API name doesn't match our keyword list, but the pin's atlas
            -- tells us what it is (e.g., a vendor NPC name like "Boots
            -- Murphy" on a Quartermaster atlas). Keep the API name and
            -- adopt the atlas-derived category.
            category = atlasCategory
            pinType = atlasCategory
        else
            return nil
        end
    end

    -- Vignettes: treasures get the treasure category. Other vignette types
    -- (vendors, services) are still useful if their atlas tells us what
    -- they are; otherwise rares are handled by ScanVignettes() (which
    -- provides GUID for super-tracking) so we drop them here.
    if pin.vignetteInfo then
        if pin.vignetteInfo.vignetteType == 2 then
            name = pin.vignetteInfo.name
            pinType = "vignette"
            category = "treasure"
        elseif atlasCategory then
            name = name or pin.vignetteInfo.name
            category = atlasCategory
            pinType = atlasCategory
        else
            return nil
        end
    end

    -- SKIP quests entirely - don't include them
    if pin.questID then
        return nil
    end

    -- SKIP world quests too
    if pin.worldQuest then
        return nil
    end

    -- Dungeon/Raid instances - handled by ScanDungeonEntrances() with proper zone filtering
    if pin.journalInstanceID then
        return nil
    end

    -- No areaPoiInfo / vignetteInfo categorization happened: fall back to
    -- whatever the atlas pre-scan identified. This is the path for plain
    -- Frame pins that have no Lua metadata at all (e.g., trading post,
    -- quartermaster on some maps).
    if not category and atlasCategory then
        category = atlasCategory
        pinType = atlasCategory
    end
    if not name and atlasName then
        name = atlasName
    end

    -- Final fallback raw texture scan if we still have no icon at all
    if not icon then
        if pin.Texture and pin.Texture.GetTexture then
            local tex = pin.Texture:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        elseif pin.Icon and pin.Icon.GetTexture then
            local tex = pin.Icon:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        end
    end

    if not name or name == "" or not category then
        return nil
    end

    -- Extract coordinates from pin data (more reliable than screen-position math)
    local pinX, pinY
    if pin.areaPoiInfo and pin.areaPoiInfo.position then
        pinX = pin.areaPoiInfo.position.x
        pinY = pin.areaPoiInfo.position.y
    elseif pin.vignetteInfo and pin.vignetteInfo.vignetteGUID then
        local pos = GetVignettePosition and GetVignettePosition(pin.vignetteInfo.vignetteGUID, WorldMapFrame:GetMapID())
        if pos then
            pinX = pos.x
            pinY = pos.y
        end
    end
    -- Fallback: MapCanvasPinMixin exposes GetPosition on data-provider pins
    if not pinX and pin.GetPosition then
        local ok, px, py = pcall(pin.GetPosition, pin)
        if ok and px and py and px >= 0 and px <= 1 and py >= 0 and py <= 1 then
            pinX = px
            pinY = py
        end
    end

    -- Filter out pins from adjacent zones using extracted coordinates
    if pinX and pinY then
        local mapID = WorldMapFrame:GetMapID()
        if mapID then
            local posInfo = GetMapInfoAtPosition and GetMapInfoAtPosition(mapID, pinX, pinY)
            if posInfo and posInfo.mapID ~= mapID and posInfo.parentMapID ~= mapID then
                return nil
            end
        end
    end

    return {
        name = name,
        pin = pin,
        pinType = pinType,
        category = category,
        icon = icon,
        isStatic = false,
        x = pinX,
        y = pinY,
    }
end

-- Pure result computation: takes a query and a global-mode flag, returns the
-- ranked + filtered + pin-merged result list. No rendering. Safe to call
-- from MapTab or any other renderer that wants both local and global sets.
-- Temporarily sets the module-level `isGlobalSearch` so transitively-called
-- helpers (SearchZones, GetGlobalInstanceCache, ...) see the requested mode.
function MapSearch:BuildResults(text, isGlobal, skipPins)
    local savedGlobalFlag = isGlobalSearch
    isGlobalSearch = isGlobal and true or false

    -- Search for zones (works for both local and global mode)
    local zoneMatches = {}
    if self:IsOnContinentMap() or isGlobal then
        zoneMatches = self:SearchZones(text)
    end

    wipe(reuseAllPOIs)
    wipe(reuseZoneNames)
    local allPOIs = reuseAllPOIs
    local zoneNames = reuseZoneNames

    local groupedZones = self:GroupZonesByParent(zoneMatches)

    for _, group in ipairs(groupedZones) do
        local zonesInGroup = group.zones
        local parentPath = group.parentPath

        for _, zone in ipairs(zonesInGroup) do
            zoneNames[GetNameLower(zone)] = true
            local entry = {
                name = zone.name,
                nameLower = zone.nameLower,
                nameNorm = zone.nameNorm,
                category = "zone",
                icon = 237382,
                isZone = true,
                zoneMapID = zone.mapID,
                zoneMapType = zone.mapType,
                zoneParentMapID = zone.parentMapID,
                pathPrefix = parentPath,
                score = zone.score + 200,
            }
            allPOIs[#allPOIs + 1] = entry
        end
    end

    -- Global search: zones + dungeon/raid/delve entrances (skip service POIs)
    --
    -- Instances get ONE authoritative source: the global instance cache.
    -- Dungeon-type zone results from SearchZones are suppressed when the
    -- cache covers them. Cache entries are promoted to zone-style display
    -- (with full breadcrumb paths) using a mapID-to-path lookup.
    if isGlobal then
        local instancePOIs = self:GetGlobalInstanceCache()

        -- Build set of normalized instance names for Dungeon-type zone suppression.
        -- normalizeName handles hyphens vs spaces ("Nexus-Point" == "Nexus Point").
        wipe(reuseInstanceNameNorm)
        local instanceNameNorm = reuseInstanceNameNorm
        for _, poi in ipairs(instancePOIs) do
            if poi.isDungeonEntrance then
                instanceNameNorm[GetNameNorm(poi)] = true
            end
        end

        -- Suppress Dungeon-type zones covered by cache entries.
        -- Non-instance Dungeon-type zones (covenant halls, etc.) are kept.
        -- Also remove suppressed names from zoneNames so the cache entry
        -- can be added in the promotion step below.
        for i = #allPOIs, 1, -1 do
            local poi = allPOIs[i]
            if poi.isZone and poi.zoneMapType == Enum.UIMapType.Dungeon then
                local poiNorm = GetNameNorm(poi)
                for instNorm in pairs(instanceNameNorm) do
                    if sfind(instNorm, poiNorm, 1, true) or sfind(poiNorm, instNorm, 1, true) then
                        zoneNames[GetNameLower(poi)] = nil
                        zoneNames[poiNorm] = nil
                        tremove(allPOIs, i)
                        break
                    end
                end
            end
        end

        -- Enrich non-Dungeon zone results with entrance data (exact name match)
        local entranceLookup = BuildEntranceLookup(instancePOIs)
        for _, poi in ipairs(allPOIs) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[GetNameLower(poi)]
                if entrance then
                    EnrichZoneWithEntrance(poi, entrance)
                    zoneNames[GetNameLower(entrance)] = true
                end
            end
        end

        local promoted = BuildPromotedInstanceCache(self)
        -- promotedInstancePOIs lives across queries (rebuilt only when
        -- the global instance cache invalidates). SearchPOIs mutates
        -- poi.score / duplicateKey / allInstances on every match, and
        -- the first-pass pass-through (`if poi.isZone and poi.score`)
        -- blindly trusts the score field on the next call — so a prior
        -- "raid" or "dungeon" search leaves every instance scored 150,
        -- and an unrelated query like "tol" inherits the lot. Clear
        -- before each scan to force fresh scoring and dedup.
        for i = 1, #promoted do
            local p = promoted[i]
            p.score = nil
            p.duplicateKey = nil
            p.allInstances = nil
            if not zoneNames[GetNameLower(p)] and not zoneNames[GetNameNorm(p)] then
                allPOIs[#allPOIs + 1] = p
            end
        end

        if MapTabFlightPathsEnabled() then
            local allFMs = self:ScanAllFlightMasters()
            for i = 1, #allFMs do
                local fm = allFMs[i]
                fm.score = nil
                fm.duplicateKey = nil
                fm.allInstances = nil
                if not zoneNames[GetNameLower(fm)] then
                    allPOIs[#allPOIs + 1] = fm
                end
            end
        end
    else
        -- Get both dynamic pins and static locations for current map
        local dynamicPOIs, dungeonEntrances, flightMasters, vignetteRares = GetLocalScans(self)
        local staticLocations = self:GetStaticLocations()

        -- Coordinate-based sources first (dungeon entrances, flight masters) so they
        -- take priority over pin-only entries from ScanMapPOIs during deduplication.
        -- Pin-only entries lack x/y and go through HighlightPin (no icon), while
        -- coordinate entries go through ShowWaypointAt (full icon + glow + arrow).
        wipe(reuseExistingNames)
        local existingNames = reuseExistingNames

        local entranceLookup = BuildEntranceLookup(dungeonEntrances)
        for _, entrance in ipairs(dungeonEntrances) do
            local nameLower = GetNameLower(entrance)
            if not zoneNames[nameLower] then
                tinsert(allPOIs, entrance)
                existingNames[nameLower] = true
            end
        end
        for _, poi in ipairs(allPOIs) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[GetNameLower(poi)]
                if entrance then
                    EnrichZoneWithEntrance(poi, entrance)
                end
            end
        end

        for _, fm in ipairs(flightMasters) do
            local nameLower = GetNameLower(fm)
            if not zoneNames[nameLower] and not existingNames[nameLower] then
                tinsert(allPOIs, fm)
                existingNames[nameLower] = true
            end
        end

        for _, rare in ipairs(vignetteRares) do
            if not rare.isAggregate then
                local nameLower = GetNameLower(rare)
                if not zoneNames[nameLower] and not existingNames[nameLower] then
                    tinsert(allPOIs, rare)
                    existingNames[nameLower] = true
                end
            else
                tinsert(allPOIs, rare)
            end
        end

        -- Dynamic pins and static locations added after, skipping duplicates
        for _, poi in ipairs(dynamicPOIs) do
            local nameLower = GetNameLower(poi)
            if not zoneNames[nameLower] and not existingNames[nameLower] then
                tinsert(allPOIs, poi)
                existingNames[nameLower] = true
            end
        end
        for _, loc in ipairs(staticLocations) do
            -- Don't update existingNames here: multiple static locations with the same
            -- name but different coords (e.g., two AHs in Orgrimmar) must all reach
            -- SearchPOIs so the duplicate-tracking system can group and pin them.
            local nameLower = GetNameLower(loc)
            if not zoneNames[nameLower] and not existingNames[nameLower] then
                tinsert(allPOIs, loc)
            end
        end
    end

    local results = self:SearchPOIs(allPOIs, text)

    -- Apply global search filters (zones / dungeons / raids / delves)
    if isGlobal then
        local filters = EasyFind.db.globalSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            local dominated = false
            if r.isZone and filters.zones == false then
                dominated = true
            elseif r.category == "dungeon" and filters.dungeons == false then
                dominated = true
            elseif r.category == "raid" and filters.raids == false then
                dominated = true
            elseif r.category == "delve" and filters.delves == false then
                dominated = true
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    else
        -- Apply local search filters (instances / travel / services / rares / treasures)
        local filters = EasyFind.db.localSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            local dominated = false
            local cat = r.category
            local parentCat = cat and CATEGORIES[cat] and CATEGORIES[cat].parent
            if (cat == "dungeon" or cat == "raid" or cat == "delve" or parentCat == "instance") and filters.instances == false then
                dominated = true
            elseif (cat == "flightmaster" or cat == "zeppelin" or cat == "boat" or cat == "portal" or cat == "tram" or parentCat == "travel") and filters.travel == false then
                dominated = true
            elseif (parentCat == "service" or cat == "service") and filters.services == false then
                dominated = true
            elseif cat == "rare" and filters.rares == false then
                dominated = true
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    end

    -- Prepend pinned items with header (always shown at top regardless of query).
    -- Callers that render their own pinned section (e.g. MapTab) pass skipPins.
    local pins = not skipPins and EasyFind.db.pinnedMapItems or nil
    if pins and #pins > 0 then
        wipe(reusePinnedKeys)
        wipe(reusePinned)
        local pinnedKeys = reusePinnedKeys
        local pinned = reusePinned
        -- Header row
        tinsert(pinned, { isPinHeader = true, name = "Pinned" })
        if not EasyFind.db.mapPinsCollapsed then
            for _, pin in ipairs(pins) do
                local copy = {}
                for k, v in pairs(pin) do copy[k] = v end
                copy.isPinned = true
                tinsert(pinned, copy)
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        else
            for _, pin in ipairs(pins) do
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        end
        wipe(reuseFiltered)
        local filtered = reuseFiltered
        for _, r in ipairs(results) do
            if not pinnedKeys[GetMapPinKey(r)] then
                tinsert(filtered, r)
            end
        end
        for _, r in ipairs(filtered) do
            tinsert(pinned, r)
        end
        results = pinned
    end

    isGlobalSearch = savedGlobalFlag
    return results
end

-- Per-query cache for SearchPOIs, mirrors the SearchZones cache. Keeps
-- recent queries so backspace re-hits cached results instead of doing
-- a fresh scan. Extension of the last query still narrows from its
-- match set.
local searchPoisCache = {
    local_  = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
    global_ = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
}
function ResetSearchPoisCache()
    for _, c in pairs(searchPoisCache) do
        wipe(c.entries); wipe(c.order); c.lastQuery = ""; c.lastCategory = nil
    end
end
ns.MapSearch.ResetSearchPoisCache = ResetSearchPoisCache

local function ClearMapSearchScratch()
    wipe(reuseAllPOIs)
    wipe(reuseZoneNames)
    wipe(reuseExistingNames)
    wipe(reuseFilteredResults)
    wipe(reusePinnedKeys)
    wipe(reusePinned)
    wipe(reuseFiltered)
    wipe(reuseSearchResults)
    wipe(reuseSearchSeen)
    wipe(reuseSearchDuplicates)
    wipe(reuseInstanceNameNorm)
    wipe(reuseEntranceLookup)
    wipe(reuseUISearchPOIs)
    wipe(reuseUISearchExistingNames)
    wipe(reuseUISearchZoneNames)
    wipe(reuseUISearchInstanceNameNorm)
    wipe(reuseUISearchFiltered)
    wipe(reuseUISearchResults)
    wipe(reuseUISearchResultData)
end

function MapSearch:TrimSearchMemory()
    ResetSearchZonesCache()
    ResetSearchPoisCache()
    ReleaseGlobalMapCaches()
    localScanCache = nil
    wipe(staticLocationCache)
    ClearMapSearchScratch()
    CollectMapGarbage()
end

function MapSearch:ReleaseIdleSearchMemory()
    ReleaseGlobalMapCaches()
    localScanCache = nil
    wipe(staticLocationCache)
    ClearMapSearchScratch()
    CollectMapGarbage()
end

local function POIResultLess(a, b)
    if a.score == b.score then
        if a.isZone and not b.isZone then return true end
        if b.isZone and not a.isZone then return false end
        return (a.name or "") < (b.name or "")
    end
    return a.score > b.score
end

function MapSearch:SearchPOIs(pois, query, noCache)
    query = slower(query)
    wipe(reuseSearchResults)
    wipe(reuseSearchSeen)
    wipe(reuseSearchDuplicates)
    local results = reuseSearchResults
    local seen = reuseSearchSeen
    local duplicates = reuseSearchDuplicates

    local matchedCategory = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or nil

    -- Query cache: exact hit returns cached results (handles backspace,
    -- retyping, and repeated same-query calls within one render).
    -- Extension from lastQuery narrows scoring to its cached matches.
    local cache
    local candidates = pois
    local candidatesAreCached = false
    if not noCache then
        local cacheKey = isGlobalSearch and "global_" or "local_"
        cache = searchPoisCache[cacheKey]
        local cachedHit = cache.entries[query]
        if cachedHit and cachedHit.matchedCategory == matchedCategory then
            cache.lastQuery = query
            cache.lastCategory = matchedCategory
            return cachedHit.results
        end
        if cache.lastQuery ~= ""
           and #query > #cache.lastQuery
           and query:sub(1, #cache.lastQuery) == cache.lastQuery
           and cache.lastCategory == matchedCategory then
            local prev = cache.entries[cache.lastQuery]
            if prev then
                candidates = prev.results
                candidatesAreCached = true
            end
        end
    end
    -- Cached candidates carry poi.score from the previous query's
    -- scoring run. The first-pass pass-through (`if poi.isZone and
    -- poi.score`) would treat that as the current score — so typing
    -- "to" then "tol" pulls Cape of Stranglethorn (which scored on
    -- "to" via initials) into "tol" with the old score intact. Clear
    -- per-entry score so the narrowed pass re-scores fresh.
    if candidatesAreCached then
        for i = 1, #candidates do
            candidates[i].score = nil
        end
    end

    -- First pass: name matches
    for _, poi in ipairs(candidates) do
        local nameLower = GetNameLower(poi)
        local key = poi.name .. (poi.category or "")
            .. (poi.isZone and poi.pathPrefix or "")

        -- Zone results already scored by SearchZones - pass through directly
        local score
        if poi.isZone and poi.score then
            score = poi.score
        else
            score = ns.Database:ScoreName(nameLower, query, #query)

            if poi.keywords then
                if not poi.kwLower then PreparePOI(poi) end
                score = score + ns.Database:ScoreKeywords(poi.kwLower, query, #query)
            end
            -- Instance cache entries promoted to zone-style get the same
            -- sorting boost, but only if they matched on their own merit
            if poi.isZone and score >= 50 then
                score = score + 200
            end
        end

        if score >= 50 then
            -- Track all instances in duplicates table
            if not duplicates[key] then
                duplicates[key] = {}
            end
            tinsert(duplicates[key], poi)

            -- Only add to results once (first instance)
            if not seen[key] then
                seen[key] = true
                poi.score = score
                poi.duplicateKey = key  -- Track the key for looking up duplicates
                tinsert(results, poi)
            end
        end
    end

    -- Second pass: ALWAYS include category matches when user typed a category keyword
    -- (typing "dungeon" shows ALL dungeons, not just name matches)
    if matchedCategory then
        for _, poi in ipairs(pois) do
            local key = poi.name .. (poi.category or "")
                .. (poi.isZone and poi.pathPrefix or "")

            if not seen[key] and poi.category then
                local score = 0

                -- Direct category match
                if poi.category == matchedCategory then
                    score = 150
                end

                -- Related category match (e.g., search "travel" shows all travel types)
                if score == 0 then
                    if relatedCategories then
                        for _, relCat in ipairs(relatedCategories) do
                            if poi.category == relCat then
                                score = 100
                                break
                            end
                        end
                    end
                end

                if score > 0 then
                    -- Track all instances in duplicates table
                    if not duplicates[key] then
                        duplicates[key] = {}
                    end
                    tinsert(duplicates[key], poi)

                    if not seen[key] then
                        seen[key] = true
                        poi.score = score
                        poi.duplicateKey = key
                        tinsert(results, poi)
                    end
                end
            end
        end
    end

    -- Attach duplicates info to results (skip entries with pre-populated allInstances)
    for _, result in ipairs(results) do
        if not result.allInstances and result.duplicateKey and duplicates[result.duplicateKey] then
            result.allInstances = duplicates[result.duplicateKey]
        end
    end

    -- Sort results by score
    tsort(results, POIResultLess)

    if noCache then return results end

    if #results > 0 then
        local snapshot = {}
        for i = 1, #results do snapshot[i] = results[i] end
        if cache.entries[query] == nil then
            cache.order[#cache.order + 1] = query
            if #cache.order > SEARCH_CACHE_MAX then
                local oldest = tremove(cache.order, 1)
                cache.entries[oldest] = nil
            end
        end
        cache.entries[query] = { matchedCategory = matchedCategory, results = snapshot }
    end
    cache.lastQuery = query
    cache.lastCategory = matchedCategory

    return results
end

-- Shared logic for navigating to an instance entrance.
-- If already on the target map, shows waypoint directly.
-- Otherwise checks if the entrance is visible on the current map,
-- falling back to map navigation with a pending waypoint.
function MapSearch:NavigateToEntrance(name, x, y, icon, category, targetMapID, directMode)
    local currentMapID = WorldMapFrame:GetMapID()
    if currentMapID == targetMapID then
        self:ShowWaypointAt(x, y, icon, category)
        return
    end
    local ex, ey = self:FindEntranceOnMap(name, currentMapID)
    if ex then
        self:ShowWaypointAt(ex, ey, icon, category)
        return
    end
    if IsOrphanZone(targetMapID) or directMode then
        self:ClearZoneHighlight()
        self.pendingWaypoint = {x = x, y = y, icon = icon, category = category, mapID = targetMapID}
        WorldMapFrame:SetMapID(targetMapID)
    else
        self.pendingWaypoint = {x = x, y = y, icon = icon, category = category, mapID = targetMapID}
        self:HighlightZoneOnMap(targetMapID, name)
    end
end

-- directOverride: optional. When non-nil, takes precedence over the
-- per-surface *MapDirectOpen SavedVariables. Used by the right-click
-- Guide menu to force breadcrumb/teaching mode regardless of the
-- user's default left-click setting.
function MapSearch:SelectResult(data, directOverride)
    self._previewing = nil
    self._savedPinState = nil
    self._suppressTextChanged = true
    pinHoverClearsOverride = true
    if data then
        DebugPrint("[EasyFind] SelectResult: name=", data.name,
            "isZone=", data.isZone, "zoneMapID=", data.zoneMapID,
            "isDungeonEntrance=", data.isDungeonEntrance,
            "entranceMapID=", data.entranceMapID,
            "entranceX=", data.entranceX, "entranceY=", data.entranceY,
            "x=", data.x, "y=", data.y,
            "currentMap=", WorldMapFrame:GetMapID())

        -- Handle parent zone header - always navigate to parent maps
        if data.isZoneParent and data.zoneMapID then
            DebugPrint("[EasyFind] SelectResult → ZONE PARENT branch, navigating to", data.zoneMapID)
            self:ClearZoneHighlight()
            WorldMapFrame:SetMapID(data.zoneMapID)
            return
        end

        local directMode
        if directOverride ~= nil then
            directMode = directOverride
        elseif isGlobalSearch then
            directMode = EasyFind.db.globalMapDirectOpen or false
        else
            directMode = EasyFind.db.localMapDirectOpen or false
        end

        -- Handle zone selection
        if data.isZone and data.zoneMapID then
            -- Orphan zones have no physical position on any parent map
            -- (e.g. Vision of Stormwind). Snap directly since there's nothing
            -- to highlight or guide through.
            if IsOrphanZone(data.zoneMapID) then
                DebugPrint("[EasyFind] SelectResult → ORPHAN ZONE, snapping directly to", data.zoneMapID)
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            elseif directMode then
                -- Direct (Fast) mode: every zone click zooms straight into the
                -- zone's own map. Skipping NavigateToEntrance keeps behavior
                -- uniform — without this, sub-zones with entrance coords
                -- (Vale of Eternal Blossoms, etc.) would pin on the parent
                -- and require a second click on the pin to actually enter.
                DebugPrint("[EasyFind] SelectResult → ZONE DIRECT branch, zoneMapID=", data.zoneMapID)
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            elseif data.entranceX and data.entranceY and data.entranceMapID then
                DebugPrint("[EasyFind] SelectResult → ZONE+ENTRANCE branch, entranceMapID=", data.entranceMapID)
                self:NavigateToEntrance(data.name, data.entranceX, data.entranceY, data.entranceIcon, data.entranceCategory, data.entranceMapID, directMode)
            else
                DebugPrint("[EasyFind] SelectResult → ZONE TEACHING branch, zoneMapID=", data.zoneMapID)
                self:HighlightZoneOnMap(data.zoneMapID, data.name)
            end
            return
        end

        -- Dungeon/raid entrance from global search: navigate to zone, then show waypoint
        if data.isDungeonEntrance and data.entranceMapID then
            DebugPrint("[EasyFind] SelectResult → DUNGEON ENTRANCE branch, entranceMapID=", data.entranceMapID)
            self:NavigateToEntrance(data.name, data.x, data.y, data.icon, data.category, data.entranceMapID, directMode)
            return
        end

        -- Check if this POI has multiple instances (duplicates) or aggregate
        if data.allInstances and #data.allInstances > 1 then
            -- Show ALL instances on the map
            self:ShowMultipleWaypoints(data.allInstances)
        elseif data.allInstances and #data.allInstances == 1 then
            local single = data.allInstances[1]
            if single.x and single.y then
                self:ShowWaypointAt(single.x, single.y, single.icon, single.category)
                if single.vignetteGUID and SetSuperTrackedVignette then
                    efTrackedVignetteGUID = single.vignetteGUID
                    SetSuperTrackedVignette(single.vignetteGUID)
                end
            end
        elseif data.pin and data.pin:IsShown() then
            -- Native canvas pin available: glow the existing in-game icon
            -- directly so the player still sees Blizzard's pin underneath
            -- the highlight border, instead of stamping our own overlay.
            self:HighlightPin(data.pin, data.x, data.y, data.icon, data.category)
        elseif data.x and data.y then
            -- Single POI with coordinates
            self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
            -- Activate built-in navigation arrow for rares
            if data.vignetteGUID and SetSuperTrackedVignette then
                efTrackedVignetteGUID = data.vignetteGUID
                SetSuperTrackedVignette(data.vignetteGUID)
            end
        elseif data.pin then
            -- Pin reference but currently hidden and no coords: clear.
            self:HighlightPin(data.pin)
        end

        -- Fast Mode local search auto-places a native waypoint.
        if not isGlobalSearch and directMode then
            local autoX, autoY, autoMapID
            local viewedMap = WorldMapFrame and WorldMapFrame:GetMapID()
            if data.allInstances and #data.allInstances > 1 then
                -- Multiple instances: navigate to the nearest one
                local nearest = self:GetNearestInstance(data.allInstances, viewedMap)
                if nearest then
                    autoX, autoY = nearest.x, nearest.y
                    autoMapID = nearest.mapID or viewedMap
                end
            elseif data.allInstances and #data.allInstances == 1 then
                local single = data.allInstances[1]
                autoX, autoY = single.x, single.y
                autoMapID = single.mapID or viewedMap
            elseif data.x and data.y then
                autoX, autoY = data.x, data.y
                autoMapID = data.mapID or viewedMap
            end
            if autoX and autoY and autoMapID
               and autoX >= 0 and autoX <= 1 and autoY >= 0 and autoY <= 1 then
                SetUserWaypoint(UiMapPoint.CreateFromCoordinates(autoMapID, autoX, autoY))
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                efPlacedWaypoint = true
                MapSearch:RefreshAllClearButtons()
            end
        end
    end
end

-- Show multiple waypoints for duplicate POIs (e.g., multiple auction houses)
function MapSearch:ShowMultipleWaypoints(instances)
    self:ClearHighlight()

    -- Save multi-pin state for restore after map close/reopen
    activePinState = {
        mapID = WorldMapFrame:GetMapID(),
        instances = instances,
        isLocal = not isGlobalSearch,
    }

    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    local canvasWidth, canvasHeight = canvas:GetSize()
    local userScale = EasyFind.db.iconScale or 0.8
    local ms = ns.MULTI_SCALE  -- slightly smaller for clusters

    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE      * ms) * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE * ms) * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE * ms) * userScale
    local indicatorSize     = ns.UIToCanvas(ns.ICON_SIZE     * ms) * userScale
    local indicatorGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE* ms) * userScale

    -- Create additional waypoint pins if needed
    if not self.extraPins then
        self.extraPins = {}
    end
    if not self.extraHighlights then
        self.extraHighlights = {}
    end
    if not self.extraIndicators then
        self.extraIndicators = {}
    end

    -- Sort north-to-south (ascending y) so southern pins render on top
    tsort(instances, function(a, b) return (a.y or 0) < (b.y or 0) end)

    -- Show each instance with pin, highlight box, and indicator
    for i, instance in ipairs(instances) do
        if instance.x and instance.y then
            local pin, highlight, ind
            -- Stagger frame levels so each pin group fully covers the previous one
            local baseLevel = 1998 + i * 3

            if i == 1 then
                -- Use the main frames for first instance
                pin = waypointPin
                highlight = highlightFrame
                ind = indicatorFrame
            else
                -- Create or reuse extra pins
                if not self.extraPins[i-1] then
                    local extraPin = CreateFrame("Frame", "EasyFindExtraPin"..(i-1), canvas)
                    extraPin:SetFrameStrata("HIGH")
                    extraPin:SetFrameLevel(1999)

                    local icon = extraPin:CreateTexture(nil, "ARTWORK")
                    icon:SetAllPoints()
                    extraPin.icon = icon

                    local glow = extraPin:CreateTexture(nil, "BACKGROUND")
                    glow:SetPoint("CENTER")
                    glow:SetTexture(STAR_GLOW_TEXTURE)
                    glow:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.8)  -- Pin glow always yellow
                    glow:SetBlendMode("ADD")
                    extraPin.glow = glow

                    local animGroup = extraPin:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local pulse = animGroup:CreateAnimation("Alpha")
                    pulse:SetFromAlpha(1)
                    pulse:SetToAlpha(0.3)
                    pulse:SetDuration(ANIM_DURATION)
                    extraPin.animGroup = animGroup

                    extraPin:EnableMouse(true)
                    extraPin:SetScript("OnEnter", function(self)
                        if self.isLocalSearch then
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:AddLine("Left-click to place waypoint and track")
                            GameTooltip:AddLine("Right-click to dismiss", 0.6, 0.6, 0.6)
                            GameTooltip:Show()
                        else
                            MapSearch:ClearHighlight()
                        end
                    end)
                    extraPin:SetScript("OnLeave", GameTooltip_Hide)
                    extraPin:SetScript("OnMouseUp", function(self, button)
                        if button == "LeftButton" and self.isLocalSearch and self.waypointX and self.waypointY then
                            local x, y, cat = self.waypointX, self.waypointY, self.waypointCategory
                            -- Collapse multi-pin to this one, then place waypoint
                            MapSearch:ShowWaypointAt(x, y, nil, cat)
                            local viewingMapID = WorldMapFrame:GetMapID()
                            if viewingMapID then
                                SetUserWaypoint(UiMapPoint.CreateFromCoordinates(viewingMapID, x, y))
                                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                                efPlacedWaypoint = true
                            end
                        end
                        if button == "RightButton" then
                            MapSearch:ClearAll()
                        end
                    end)

                    self.extraPins[i-1] = extraPin
                end
                pin = self.extraPins[i-1]

                -- Create or reuse extra highlight boxes
                if not self.extraHighlights[i-1] then
                    local extraHighlight = CreateFrame("Frame", "EasyFindExtraHighlight"..(i-1), canvas)
                    extraHighlight:SetFrameStrata("HIGH")
                    extraHighlight:SetFrameLevel(1998)

                    local top = extraHighlight:CreateTexture(nil, "OVERLAY")
                    top:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                    extraHighlight.top = top

                    local bottom = extraHighlight:CreateTexture(nil, "OVERLAY")
                    bottom:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                    extraHighlight.bottom = bottom

                    local left = extraHighlight:CreateTexture(nil, "OVERLAY")
                    left:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                    extraHighlight.left = left

                    local right = extraHighlight:CreateTexture(nil, "OVERLAY")
                    right:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 1)
                    extraHighlight.right = right

                    local animGroup = extraHighlight:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local alpha = animGroup:CreateAnimation("Alpha")
                    alpha:SetFromAlpha(1)
                    alpha:SetToAlpha(0.4)
                    alpha:SetDuration(ANIM_DURATION)
                    extraHighlight.animGroup = animGroup

                    self.extraHighlights[i-1] = extraHighlight
                end
                highlight = self.extraHighlights[i-1]

                -- Create or reuse extra indicators
                if not self.extraIndicators[i-1] then
                    local extraInd = CreateFrame("Frame", "EasyFindExtraIndicator"..(i-1), canvas)
                    extraInd:SetFrameStrata("HIGH")
                    extraInd:SetFrameLevel(2001)
                    ns.CreateIndicatorTextures(extraInd)

                    local animGroup = extraInd:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local indMove = animGroup:CreateAnimation("Translation")
                    indMove:SetOffset(0, -10)
                    indMove:SetDuration(ANIM_DURATION)
                    local indAlpha = animGroup:CreateAnimation("Alpha")
                    indAlpha:SetFromAlpha(1)
                    indAlpha:SetToAlpha(0.4)
                    indAlpha:SetDuration(ANIM_DURATION)
                    extraInd.animGroup = animGroup

                    self.extraIndicators[i-1] = extraInd
                end
                ind = self.extraIndicators[i-1]
            end

            -- Ensure consistent strata and staggered levels so overlapping pins stack cleanly
            highlight:SetFrameStrata("TOOLTIP")
            pin:SetFrameStrata("TOOLTIP")
            ind:SetFrameStrata("TOOLTIP")
            highlight:SetFrameLevel(baseLevel)
            pin:SetFrameLevel(baseLevel + 1)
            ind:SetFrameLevel(baseLevel + 2)

            -- Position and show the pin
            pin:SetSize(iconSize, iconSize)
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", canvas, "TOPLEFT", instance.x * canvasWidth, -instance.y * canvasHeight)
            pin.waypointX = instance.x
            pin.waypointY = instance.y
            pin.waypointCategory = instance.category
            if pinHoverClearsOverride == true then
                pin.isLocalSearch = false
            else
                pin.isLocalSearch = not isGlobalSearch
            end

            local iconTexture = GetCategoryIcon(instance.category)
            if instance.icon then
                iconTexture = instance.icon
            end
            Utils.SetIconTexture(pin.icon, iconTexture)

            if pin.glow then
                pin.glow:SetSize(glowSize, glowSize)
            end

            pin:Show()

            -- Position and show the highlight box
            highlight:SetSize(highlightSize, highlightSize)
            highlight:ClearAllPoints()
            highlight:SetPoint("CENTER", pin, "CENTER", 0, 0)
            ResizeHighlightBorders(highlight)
            highlight:Show()
            SetHighlightBordersVisible(highlight, EasyFind.db.mapPinHighlight ~= false)

            -- Position and show the indicator
            ind:SetSize(indicatorSize, indicatorSize)
            if ind.glow then
                ind.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
            end
            ind:ClearAllPoints()
            ind:SetPoint("BOTTOM", highlight, "TOP", 0, 2)
            ind:Show()

            if ind.animGroup then
                ind:SetAlpha(1)
                ind.animGroup:Play()
            end
            if EasyFind.db.blinkingPins then
                if pin.animGroup then
                    pin:SetAlpha(1)
                    pin.animGroup:Play()
                end
                if highlight.animGroup then
                    highlight:SetAlpha(1)
                    highlight.animGroup:Play()
                end
            end
        end
    end

    -- Hide leftover extra frames from previous calls with more instances
    if self.extraPins then
        for j = #instances, #self.extraPins do
            if self.extraPins[j] then self.extraPins[j]:Hide() end
            if self.extraHighlights and self.extraHighlights[j] then self.extraHighlights[j]:Hide() end
            if self.extraIndicators and self.extraIndicators[j] then self.extraIndicators[j]:Hide() end
        end
    end

    -- During hover preview, prevent pins from intercepting mouse events
    -- that belong to the results panel (pins can overlap at TOOLTIP strata)
    if self._previewing then
        waypointPin:EnableMouse(false)
        if self.extraPins then
            for _, ep in ipairs(self.extraPins) do
                if ep:IsShown() then ep:EnableMouse(false) end
            end
        end
    end

                -- Auto-track if requested by navigate button
    if self.autoTrackNextPin then
        self.autoTrackNextPin = nil
        self:TrackActivePin()
    end
end

function MapSearch:ShowWaypointAt(x, y, icon, category, arrowOnly)
    if not x or not y then return end
    self:ClearHighlight()

    -- Save pin state so it can be restored after map close/reopen or map change
    activePinState = {
        mapID = WorldMapFrame:GetMapID(),
        x = x, y = y,
        icon = icon, category = category,
        isLocal = not isGlobalSearch,
        arrowOnly = arrowOnly,
    }

    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    local canvasWidth, canvasHeight = canvas:GetSize()

    -- Convert UI-unit sizes to canvas units so they appear the same screen size
    local userScale = EasyFind.db.iconScale or 0.8
    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE)       * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE)  * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE)  * userScale
    local indicatorSize     = ns.UIToCanvas(ns.ICON_SIZE)       * userScale
    local indicatorGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE)  * userScale

    -- Arrow-only mode (zone hover preview): the zone's outline is drawn
    -- by zoneHighlightFrame, so pin chrome (icon, glow, highlight box)
    -- would clutter it. Hide pin and highlight, then anchor the
    -- indicator at the zone center on the canvas. The indicator is a
    -- permanent canvas child — no reparenting between calls.
    if arrowOnly then
        waypointPin:Hide()
        highlightFrame:Hide()
        indicatorFrame:SetSize(indicatorSize, indicatorSize)
        if indicatorFrame.glow then
            indicatorFrame.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
        end
        indicatorFrame:ClearAllPoints()
        indicatorFrame:SetPoint("BOTTOM", canvas, "TOPLEFT",
            canvasWidth * x, -canvasHeight * y + 2)
        indicatorFrame:SetAlpha(1)
        indicatorFrame:Show()
        if indicatorFrame.animGroup then
            indicatorFrame.animGroup:Stop()
            indicatorFrame.animGroup:Play()
        end
        self:RefreshAllClearButtons()
        return
    end

    -- Resize the pin and glow
    waypointPin:SetSize(iconSize, iconSize)
    waypointPin.glow:SetSize(glowSize, glowSize)

    -- Use category icon if no specific icon provided
    local iconTexture = GetCategoryIcon(category or "unknown")
    if icon then
        iconTexture = icon
    end
    Utils.SetIconTexture(waypointPin.icon, iconTexture)
    waypointPin:ClearAllPoints()
    waypointPin:SetPoint("CENTER", canvas, "TOPLEFT", canvasWidth * x, -canvasHeight * y)
    waypointPin.waypointX = x
    waypointPin.waypointY = y
    if pinHoverClearsOverride == true then
        waypointPin.isLocalSearch = false
    else
        waypointPin.isLocalSearch = not isGlobalSearch
    end
    waypointPin:Show()
    if self._previewing then
        waypointPin:EnableMouse(false)
    end

    -- Resize and position highlight
    highlightFrame:SetSize(highlightSize, highlightSize)
    highlightFrame:ClearAllPoints()
    highlightFrame:SetPoint("CENTER", waypointPin, "CENTER", 0, 0)
    ResizeHighlightBorders(highlightFrame)
    highlightFrame:Show()
    SetHighlightBordersVisible(highlightFrame, EasyFind.db.mapPinHighlight ~= false)

    -- Resize indicator and its glow, then anchor explicitly above the
    -- highlight box (indicator is a permanent canvas child; the old
    -- parent-relative anchor doesn't apply anymore).
    indicatorFrame:SetSize(indicatorSize, indicatorSize)
    indicatorFrame.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 2)
    indicatorFrame:SetAlpha(1)
    indicatorFrame:Show()

    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Stop()
        indicatorFrame.animGroup:Play()
    end
    if EasyFind.db.blinkingPins then
        if waypointPin.animGroup then waypointPin.animGroup:Play() end
        if highlightFrame.animGroup then highlightFrame.animGroup:Play() end
    end

                -- Auto-track if requested by navigate button
    if self.autoTrackNextPin then
        self.autoTrackNextPin = nil
        self:TrackActivePin()
    end

    -- Refresh the UI search bar's clear button so it appears while a
    -- pin is visible (active map navigation).
    self:RefreshAllClearButtons()
end

-- Tracks the canvas pin currently scaled up by HighlightPin so ClearHighlight
-- can restore the original scale. Module-scoped because the pin reference
-- doesn't survive a /reload.
local highlightedNativePin = nil

local function RestoreNativePinScale()
    local p = highlightedNativePin
    if not p then return end
    if p._easyfindOriginalScale and p.SetScale then
        pcall(p.SetScale, p, p._easyfindOriginalScale)
    end
    p._easyfindOriginalScale = nil
    highlightedNativePin = nil
end

function MapSearch:HighlightPin(pin, x, y, icon, category)
    waypointPin:Hide()

    -- Restore any previously scaled native pin before highlighting a new one.
    RestoreNativePinScale()

    if not pin or not pin:IsShown() then
        -- Pin gone or hidden: fall back to overlay if we know the coords,
        -- otherwise just clear.
        if x and y then
            self:ShowWaypointAt(x, y, icon, category)
            return
        end
        self:ClearHighlight()
        return
    end

    -- Save state with coords + category so close/reopen can restore via the
    -- ShowWaypointAt fallback. The live pin reference will be stale by then.
    if x and y then
        activePinState = {
            mapID = WorldMapFrame:GetMapID(),
            x = x, y = y,
            icon = icon, category = category,
            isLocal = not isGlobalSearch,
        }
    end

    -- Scale the native pin up so it visually pops while highlighted. The
    -- original scale is cached on the pin frame and restored by
    -- ClearHighlight (or the next HighlightPin call).
    local userScale = EasyFind.db.iconScale or 0.8
    local nativePinScale = (EasyFind.db.nativePinScale or 1.5) * userScale
    if pin.SetScale and pin.GetScale then
        pin._easyfindOriginalScale = pin._easyfindOriginalScale or (pin:GetScale() or 1)
        pcall(pin.SetScale, pin, pin._easyfindOriginalScale * nativePinScale)
        highlightedNativePin = pin
    end

    local width, height = pin:GetSize()
    local minPinSize = ns.UIToCanvas(36) * userScale
    width = mmax(width or 24, minPinSize)
    height = mmax(height or 24, minPinSize)

    local indicatorSize     = ns.UIToCanvas(ns.ICON_SIZE)      * userScale
    local indicatorGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE) * userScale
    indicatorFrame:SetSize(indicatorSize, indicatorSize)
    indicatorFrame.glow:SetSize(indicatorGlowSize, indicatorGlowSize)

    highlightFrame:SetSize(width, height)
    highlightFrame:ClearAllPoints()
    highlightFrame:SetPoint("CENTER", pin, "CENTER", 0, 0)
    ResizeHighlightBorders(highlightFrame)
    highlightFrame:Show()
    SetHighlightBordersVisible(highlightFrame, EasyFind.db.mapPinHighlight ~= false)
    indicatorFrame:Show()

    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Play()
    end
    if EasyFind.db.blinkingPins and highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
end

-- Shared hover-preview entry point. Shows the hovered pin ALONGSIDE
-- any pin the user already clicked, by reusing ShowMultipleWaypoints —
-- same mechanism that handles multi-instance results like auction
-- houses. Saves activePinState on first preview so EndHoverPreview can
-- cleanly restore to the clicked-only state when the cursor moves off.
function MapSearch:RunHoverPreview(data)
    if not data then return end

    -- Snapshot existing pin state once per hover session so EndHoverPreview
    -- can restore cleanly. PreviewZoneHighlight has no side effects, so
    -- there's no zone-navigation state to save.
    if not self._previewing then
        self._savedPinState = activePinState
    end
    self._previewing = true

    -- Zone-area preview: when hovering a zone result, draw a translucent
    -- rect where the zone sits on the currently-viewed map. Strictly
    -- visible-only — PreviewZoneHighlight bails when the zone isn't on
    -- this map, when we're already inside it, and never changes maps.
    self._previewingZone = nil
    if data.isZone and data.zoneMapID and self.PreviewZoneHighlight then
        self:PreviewZoneHighlight(data.zoneMapID)
        self._previewingZone = data.zoneMapID
    end

    if not self.GetPreviewCoords then return end
    local coords = self:GetPreviewCoords(data)
    if not coords then
        -- No pin coords: zone-highlight (if any) is still active, that's
        -- the whole preview. activePinState is unchanged.
        return
    end

    -- Build a composite: existing clicked pin(s) + the hovered pin.
    local composite = {}
    local saved = self._savedPinState
    if saved and saved.mapID == WorldMapFrame:GetMapID() then
        if saved.instances then
            for i = 1, #saved.instances do
                composite[#composite + 1] = saved.instances[i]
            end
        elseif saved.x and saved.y then
            composite[#composite + 1] = {
                x = saved.x, y = saved.y,
                icon = saved.icon, category = saved.category,
            }
        end
    end

    if coords.pin and coords.pin:IsShown() then
        -- Hovering a native canvas pin: show any saved pins alongside,
        -- then glow the hovered native pin in place.
        if #composite > 0 then self:ShowMultipleWaypoints(composite) end
        self:HighlightPin(coords.pin, coords.x, coords.y, coords.icon, coords.category)
    elseif coords.instances then
        for i = 1, #coords.instances do
            composite[#composite + 1] = coords.instances[i]
        end
        self:ShowMultipleWaypoints(composite)
    elseif coords.x and coords.y then
        if coords.arrowOnly then
            -- Zone preview: only the bouncing arrow + zone outline, no pin
            -- icon/glow/box. Skip composite merging so existing clicked
            -- pins from another category don't pull in their icons either.
            self:ShowWaypointAt(coords.x, coords.y, nil, nil, true)
        else
            composite[#composite + 1] = {
                x = coords.x, y = coords.y,
                icon = coords.icon, category = coords.category,
            }
            if #composite > 1 then
                self:ShowMultipleWaypoints(composite)
            else
                self:ShowWaypointAt(coords.x, coords.y, coords.icon, coords.category)
            end
        end
    end

    -- Always restore activePinState — even to nil — so hover never
    -- persists as the "active" clicked pin. Without unconditional
    -- restoration, hovering when nothing is clicked would silently
    -- promote the previewed pin into the real active state, which
    -- downstream code (auto-track on map reopen, etc.) latches onto.
    activePinState = self._savedPinState
end

function MapSearch:EndHoverPreview()
    if not self._previewing then return end
    self._previewing = nil
    if self._previewingZone then
        -- preserveBreadcrumb keeps the click-driven gold breadcrumb
        -- and pendingZoneHighlight intact while we drop the hover
        -- preview's zone outline.
        self:ClearZoneHighlight(true)
        self._previewingZone = nil
    end
    self:ClearHighlight()
    local saved = self._savedPinState
    self._savedPinState = nil
    if saved and saved.mapID == WorldMapFrame:GetMapID() then
        if saved.instances then
            self:ShowMultipleWaypoints(saved.instances)
        elseif saved.x and saved.y then
            self:ShowWaypointAt(saved.x, saved.y, saved.icon, saved.category)
        end
    end
end

function MapSearch:ClearHighlight()
    if not highlightFrame then return end

    -- Restore the native pin's original scale before tearing down highlight visuals.
    RestoreNativePinScale()

    highlightFrame:Hide()
    highlightFrame.top:Show()
    highlightFrame.bottom:Show()
    highlightFrame.left:Show()
    highlightFrame.right:Show()

    indicatorFrame:Hide()
    waypointPin:Hide()
    -- Reset strata to creation defaults so the mouse-enabled pin doesn't
    -- linger at TOOLTIP (set by ShowMultipleWaypoints) where it can
    -- overlap and steal mouse from the TOOLTIP-strata results panel.
    waypointPin:SetFrameStrata("HIGH")
    waypointPin:SetFrameLevel(2000)
    waypointPin:EnableMouse(true)

    -- Refresh the UI search bar's clear button (pin is gone, but map
    -- navigation may still be active via efPlacedWaypoint).
    self:RefreshAllClearButtons()
    waypointPin.waypointX = nil
    waypointPin.waypointY = nil
    waypointPin.isLocalSearch = nil
    if highlightFrame.animGroup then
        highlightFrame.animGroup:Stop()
    end
    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Stop()
    end
    if waypointPin.animGroup then
        waypointPin.animGroup:Stop()
    end

    -- Hide extra pins, highlights, and indicators for duplicate POIs
    if self.extraPins then
        for _, pin in ipairs(self.extraPins) do
            pin:Hide()
            pin:EnableMouse(true)
            pin.waypointX = nil
            pin.waypointY = nil
            pin.isLocalSearch = nil
            if pin.animGroup then pin.animGroup:Stop() end
        end
    end
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            hl:Hide()
            if hl.animGroup then hl.animGroup:Stop() end
        end
    end
    if self.extraIndicators then
        for _, arr in ipairs(self.extraIndicators) do
            arr:Hide()
            if arr.animGroup then arr.animGroup:Stop() end
        end
    end

end

-- Resolve preview-able coordinates for a search result on the current map.
-- Returns {x, y, icon, category} or {instances} or nil if not previewable.
function MapSearch:GetPreviewCoords(data)
    local currentMapID = WorldMapFrame:GetMapID()
    if data.allInstances then
        -- Filter instances to those whose (x,y) are valid on the
        -- currently viewed map. FMs scanned at both continent and
        -- zone level merge into a single result with multiple
        -- instances; without this filter, both render — and one is
        -- always at the wrong pixel for whichever map you're on.
        local valid = {}
        for i = 1, #data.allInstances do
            local inst = data.allInstances[i]
            local instMap = inst.entranceMapID or inst.coordMapID
            if inst.x and inst.y and (not instMap or instMap == currentMapID) then
                valid[#valid + 1] = inst
            end
        end
        if #valid > 1 then
            return { instances = valid }
        elseif #valid == 1 then
            local single = valid[1]
            return { x = single.x, y = single.y, icon = single.icon, category = single.category }
        else
            return nil
        end
    end
    -- Determine the best known coords and their associated map
    local px, py, pIcon, pCat, pMapID
    if data.isZone then
        px, py = data.entranceX, data.entranceY
        pIcon = data.entranceIcon or data.icon
        pCat = data.entranceCategory or data.category
        pMapID = data.entranceMapID
    elseif data.x and data.y then
        px, py = data.x, data.y
        pIcon = data.icon
        pCat = data.category
        -- coordMapID identifies the map the (x,y) coords are valid on
        -- (set by local scanners). Falls back to entranceMapID for
        -- legacy POI shapes that didn't carry the field.
        pMapID = data.entranceMapID or data.coordMapID
    end
    -- Coords on the current map: use directly. Forward the live pin
    -- reference (when present) so previews can glow the native icon
    -- in place of stamping an overlay.
    if px and py and (not pMapID or pMapID == currentMapID) then
        return { x = px, y = py, icon = pIcon, category = pCat, pin = data.pin }
    end
    -- Coords on a different map: check if entrance is visible here
    if data.isDungeonEntrance or data.category == "dungeon"
       or data.category == "raid" or data.category == "delve" then
        local ex, ey = self:FindEntranceOnMap(data.name, currentMapID)
        if ex then
            return { x = ex, y = ey, icon = pIcon or data.icon, category = pCat or data.category }
        end
    end
    -- Plain zone result with no entrance data: anchor the indicator at
    -- the zone's center on the currently-viewed map so the bouncing
    -- arrow points into the highlight rect drawn by PreviewZoneHighlight.
    -- arrowOnly flag tells RunHoverPreview to skip the icon / pin chrome
    -- because the zone outline already conveys "this is a zone".
    if data.isZone and data.zoneMapID then
        local zMap = data.zoneMapID
        local resolved = ResolveZoneForMap(zMap, currentMapID)
        if resolved ~= zMap then zMap = resolved end
        -- Strict direct-child gate (matches PreviewZoneHighlight): only
        -- show the bouncing arrow when the zone's parentMapID is the
        -- currently-viewed map. Anything else is suppressed.
        local zInfo = GetMapInfo(zMap)
        if zInfo and zInfo.parentMapID == currentMapID then
            local ok, left, right, top, bottom = pcall(GetMapRectOnMap, zMap, currentMapID)
            if ok and left then
                if left == 0 and right == 0 and top == 0 and bottom == 0 then
                    local pL, pR, pT, pB = GetMapRectViaContinent(zMap, currentMapID)
                    if pL then left, right, top, bottom = pL, pR, pT, pB end
                end
                if left and (right - left) > 0.005 and (bottom - top) > 0.005
                   and (right - left) < 1.05 and (bottom - top) < 1.05 then
                    local cx = (left + right) / 2
                    local cy = (top + bottom) / 2
                    return { x = cx, y = cy, arrowOnly = true }
                end
            end
        end
    end
    return nil
end

-- Full clear: map visuals + waypoint tracking
-- Called by explicit dismiss actions (right-click pin, /ef clear, clear button)
-- Returns true if EasyFind currently has any active map navigation:
-- an active pin, a SuperTrack waypoint we placed, a zone highlight,
-- or a pending waypoint/zone. Used by the UI search bar's clear button
-- to stay visible while navigation is in progress.
function MapSearch:HasActiveNavigation()
    if efPlacedWaypoint then return true end
    if activePinState then return true end
    if self.pendingWaypoint then return true end
    if self.pendingZoneHighlight then return true end
    if waypointPin and waypointPin:IsShown() then return true end
    return false
end

function MapSearch:RefreshAllClearButtons()
    local frames = {
        _G["EasyFindSearchFrame"],
    }
    for _, f in ipairs(frames) do
        if f and f.UpdateClearButtonVisibility then
            f.UpdateClearButtonVisibility()
        end
    end
end

function MapSearch:ClearAll()
    activePinState = nil
    self:ClearHighlight()
    -- Only clear Blizzard waypoint if EasyFind placed it
    if efPlacedWaypoint then
        efPlacedWaypoint = false
        C_SuperTrack.SetSuperTrackedUserWaypoint(false)
        if HasUserWaypoint() then
            ClearUserWaypoint()
        end
    end
    -- Notify the UI search bar to refresh its clear-button state.
    self:RefreshAllClearButtons()
end

function MapSearch:GetNearestInstance(instances, mapID)
    if #instances == 1 then return instances[1] end
    local pos = GetPlayerMapPosition(mapID, "player")
    if not pos then return instances[1] end
    local px, py = pos:GetXY()
    local nearest, bestDist = instances[1], math.huge
    for _, inst in ipairs(instances) do
        if inst.x and inst.y then
            local dx, dy = inst.x - px, inst.y - py
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                bestDist = dist
                nearest = inst
            end
        end
    end
    return nearest
end

function MapSearch:TrackActivePin()
    if not activePinState then return end
    local mapID = activePinState.mapID
    local x, y
    if activePinState.instances then
        local nearest = self:GetNearestInstance(activePinState.instances, mapID)
        if nearest then
            x, y = nearest.x, nearest.y
            -- Collapse multi-pin display to just this instance
            self:ShowWaypointAt(x, y, nil, nearest.category)
        end
    else
        x, y = activePinState.x, activePinState.y
    end
    if not mapID or not x or not y then return end
    if x < 0 or x > 1 or y < 0 or y > 1 then return end

    SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    efPlacedWaypoint = true
end

function MapSearch:UpdateBlinkingPins()
    local blinking = EasyFind.db.blinkingPins

    local function Toggle(frame)
        if not frame or not frame.animGroup then return end
        if blinking and frame:IsShown() then
            frame.animGroup:Play()
        else
            frame.animGroup:Stop()
            frame:SetAlpha(1)
        end
    end

    -- Pins and highlights are gated by blinkingPins
    Toggle(waypointPin)
    Toggle(highlightFrame)

    if self.extraPins then
        for _, pin in ipairs(self.extraPins) do Toggle(pin) end
    end
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do Toggle(hl) end
    end
end

function MapSearch:UpdatePinHighlight()
    local visible = EasyFind.db.mapPinHighlight ~= false
    if highlightFrame and highlightFrame:IsShown() then
        SetHighlightBordersVisible(highlightFrame, visible)
    end
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            if hl:IsShown() then
                SetHighlightBordersVisible(hl, visible)
            end
        end
    end
end

function MapSearch:UpdateIconScales()
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    local userScale = EasyFind.db.iconScale or 0.8

    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE)       * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE)  * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE)  * userScale
    local indicatorSize     = ns.UIToCanvas(ns.ICON_SIZE)       * userScale
    local indicatorGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE)  * userScale

    -- Helper: resize an indicator frame + its textures
    local function resizeIndicator(frame, aSize, gSize)
        if not frame then return end
        frame:SetSize(aSize, aSize)
        if frame.indicator then frame.indicator:SetSize(aSize, aSize) end
        if frame.glow then frame.glow:SetSize(gSize, gSize) end
    end

    -- Update main waypoint pin
    if waypointPin then
        waypointPin:SetSize(iconSize, iconSize)
        if waypointPin.glow then
            waypointPin.glow:SetSize(glowSize, glowSize)
        end
    end

    -- Update main highlight frame
    if highlightFrame and highlightFrame:IsShown() then
        highlightFrame:SetSize(highlightSize, highlightSize)
    end

    -- Update main indicator
    resizeIndicator(indicatorFrame, indicatorSize, indicatorGlowSize)

    -- Update zone indicator
    local zoneIndSize     = ns.UIToCanvas(ns.ZONE_ICON_SIZE)      * userScale
    local zoneIndGlowSize = ns.UIToCanvas(ns.ZONE_ICON_GLOW_SIZE) * userScale
    if zoneHighlightFrame and zoneHighlightFrame.indicator then
        resizeIndicator(zoneHighlightFrame.indicator, zoneIndSize, zoneIndGlowSize)
    end

    -- Update extra pins for duplicates
    local ms = ns.MULTI_SCALE
    local multiIconSize      = ns.UIToCanvas(ns.PIN_SIZE      * ms) * userScale
    local multiGlowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE * ms) * userScale
    local multiHighlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE * ms) * userScale
    local multiIndSize     = ns.UIToCanvas(ns.ICON_SIZE     * ms) * userScale
    local multiIndGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE* ms) * userScale

    if self.extraPins then
        for _, pin in ipairs(self.extraPins) do
            if pin:IsShown() then
                pin:SetSize(multiIconSize, multiIconSize)
                if pin.glow then
                    pin.glow:SetSize(multiGlowSize, multiGlowSize)
                end
            end
        end
    end

    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            if hl:IsShown() then
                hl:SetSize(multiHighlightSize, multiHighlightSize)
            end
        end
    end

    if self.extraIndicators then
        for _, arr in ipairs(self.extraIndicators) do
            resizeIndicator(arr, multiIndSize, multiIndGlowSize)
        end
    end
end

-- Refresh all indicator textures when style/color changes.
-- Uses ns.UpdateIndicator so every indicator looks identical.
-- Highlight boxes, zone overlays, and pin glows are ALWAYS yellow and never change.
function MapSearch:RefreshIndicators()
    -- Update main location indicator
    local mapInd = _G["EasyFindMapIndicator"]
    if mapInd then ns.UpdateIndicator(mapInd) end

    -- Update zone indicator
    local zoneInd = _G["EasyFindZoneIndicator"]
    if zoneInd then ns.UpdateIndicator(zoneInd) end

    -- Update breadcrumb indicator
    if self.breadcrumbHighlight and self.breadcrumbHighlight.indicatorFrame then
        ns.UpdateIndicator(self.breadcrumbHighlight.indicatorFrame)
    end

    -- Update extra indicators
    if self.extraIndicators then
        for _, ind in ipairs(self.extraIndicators) do
            ns.UpdateIndicator(ind)
        end
    end

    -- Update UI highlight indicator (Highlight.lua)
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then ns.UpdateIndicator(uiInd) end
end

-- Search for the UI search bar, mirroring the real map search pipeline.
-- Gathers the same POI sources (dynamic, static, entrances, flight masters),
-- runs SearchPOIs with the same scoring, and returns results for UI display.
function MapSearch:SearchForUI(query)
    if not query or query == "" or #query < 2 then return nil end
    if not cachedWorldZones then return nil end

    -- Use the player's current zone as the local anchor so UI-bar map
    -- results reflect what's actually around them rather than wherever
    -- the WorldMapFrame happens to be viewing.
    local searchMapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())

    -- Gather POIs from both local and global sources in a single pass
    -- so the UI bar shows results regardless of zone scope — matching
    -- how the MapTab surfaces both "This Zone" and "Across the World"
    -- content without asking the user to pick.
    wipe(reuseUISearchPOIs)
    wipe(reuseUISearchExistingNames)
    local pois = reuseUISearchPOIs
    local existingNames = reuseUISearchExistingNames

    do
        local dynamicPOIs, dungeonEntrances, flightMasters, vignetteRares = GetLocalScans(self, searchMapID)
        local staticLocations = self:GetStaticLocations(searchMapID)

        for _, entrance in ipairs(dungeonEntrances) do
            pois[#pois + 1] = entrance
            existingNames[GetNameLower(entrance)] = true
        end
        for _, fm in ipairs(flightMasters) do
            local nameLower = GetNameLower(fm)
            if not existingNames[nameLower] then
                pois[#pois + 1] = fm
                existingNames[nameLower] = true
            end
        end
        for _, rare in ipairs(vignetteRares) do
            if not rare.isAggregate then
                local nameLower = GetNameLower(rare)
                if not existingNames[nameLower] then
                    pois[#pois + 1] = rare
                    existingNames[nameLower] = true
                end
            else
                pois[#pois + 1] = rare
            end
        end
        for _, poi in ipairs(dynamicPOIs) do
            local nameLower = GetNameLower(poi)
            if not existingNames[nameLower] then
                pois[#pois + 1] = poi
                existingNames[nameLower] = true
            end
        end
        for _, loc in ipairs(staticLocations) do
            local nameLower = GetNameLower(loc)
            if not existingNames[nameLower] then
                pois[#pois + 1] = loc
                existingNames[nameLower] = true
            end
        end
    end

    -- Always also pull in global zone + instance results. Dedup against
    -- existingNames so the local sources take priority for any POI that
    -- exists in both (same ownership rule as MapTab's local-first pass).
    do
        local savedGlobalFlag = isGlobalSearch
        isGlobalSearch = true
        local zoneMatches = self:SearchZones(query)
        isGlobalSearch = savedGlobalFlag
        local groupedZones = self:GroupZonesByParent(zoneMatches)
        wipe(reuseUISearchZoneNames)
        local zoneNames = reuseUISearchZoneNames

        for _, group in ipairs(groupedZones) do
            for _, zone in ipairs(group.zones) do
                local nameLower = GetNameLower(zone)
                zoneNames[nameLower] = true
                if not existingNames[nameLower] then
                    pois[#pois + 1] = {
                        name = zone.name, category = "zone", icon = 237382,
                        nameLower = zone.nameLower, nameNorm = zone.nameNorm,
                        isZone = true, zoneMapID = zone.mapID,
                        zoneMapType = zone.mapType, zoneParentMapID = zone.parentMapID,
                        pathPrefix = group.parentPath, score = zone.score + 200,
                    }
                end
            end
        end

        if globalInstanceCache then
            local instancePOIs = self:GetGlobalInstanceCache()

            wipe(reuseUISearchInstanceNameNorm)
            local instanceNameNorm = reuseUISearchInstanceNameNorm
            for _, poi in ipairs(instancePOIs) do
                if poi.isDungeonEntrance then
                    instanceNameNorm[GetNameNorm(poi)] = true
                end
            end
            local writeIdx = 0
            for i = 1, #pois do
                local poi = pois[i]
                local keep = true
                if poi.isZone and poi.zoneMapType == Enum.UIMapType.Dungeon then
                    local poiNorm = GetNameNorm(poi)
                    for instNorm in pairs(instanceNameNorm) do
                        if sfind(instNorm, poiNorm, 1, true) or sfind(poiNorm, instNorm, 1, true) then
                            zoneNames[GetNameLower(poi)] = nil
                            zoneNames[poiNorm] = nil
                            keep = false
                            break
                        end
                    end
                end
                if keep then
                    writeIdx = writeIdx + 1
                    pois[writeIdx] = poi
                end
            end
            for i = #pois, writeIdx + 1, -1 do
                pois[i] = nil
            end

            local entranceLookup = BuildEntranceLookup(instancePOIs)
            for _, poi in ipairs(pois) do
                if poi.isZone and poi.zoneMapID then
                    local entrance = entranceLookup[GetNameLower(poi)]
                    if entrance then
                        EnrichZoneWithEntrance(poi, entrance)
                        zoneNames[GetNameLower(entrance)] = true
                    end
                end
            end

            local promoted = BuildPromotedInstanceCache(self)
            for i = 1, #promoted do
                local p = promoted[i]
                p.score = nil
                p.duplicateKey = nil
                p.allInstances = nil
                if not zoneNames[GetNameLower(p)] and not zoneNames[GetNameNorm(p)] then
                    pois[#pois + 1] = p
                end
            end
        end
    end

    if #pois == 0 then return nil end

    -- Run the same scoring pipeline as the real map search
    local scored = self:SearchPOIs(pois, query, true)
    if not scored or #scored == 0 then return nil end

    -- Apply the MapTab cog filters so the UI search bar surfaces the
    -- same buckets the user picked there. Mirrors FilterAndDedupe in
    -- MapTab.lua: any POI whose bucket is explicitly disabled
    -- (filters[bucket] == false) drops out. Buckets without a saved
    -- value default to enabled — same convention DB_DEFAULTS uses.
    do
        local mtFilters = EasyFind.db.mapTabFilters
        if mtFilters then
            wipe(reuseUISearchFiltered)
            local filtered = reuseUISearchFiltered
            for _, r in ipairs(scored) do
                local bucket = GetFilterBucket(r)
                if mtFilters[bucket] ~= false then
                    filtered[#filtered + 1] = r
                end
            end
            scored = filtered
            if #scored == 0 then return nil end
        end
    end

    local results = reuseUISearchResults
    local resultCap = mmin(#scored, UI_MAP_RESULT_CAP)
    for ri = 1, resultCap do
        local r = scored[ri]
        local cat = r.category or "location"
        local d = reuseUISearchResultData[ri]
        if not d then
            d = {}
            reuseUISearchResultData[ri] = d
        end
        d.name = r.name
        d.nameLower = GetNameLower(r)
        d.category = cat
        d.icon = r.icon or GetCategoryIcon(cat)
        d.mapSearchResult = true
        d.mapID = r.mapID or r.zoneMapID or r.entranceMapID or searchMapID
        d.zoneName = r.zoneName or r.pathPrefix
        d.pathPrefix = r.pathPrefix
        d.x = r.x or r.entranceX
        d.y = r.y or r.entranceY
        d.keywords = r.keywords
        d.query = query
        d.isZone = nil
        d.zoneMapID = nil
        d.entranceMapID = nil
        d.entranceX = nil
        d.entranceY = nil
        d.entranceIcon = nil
        d.entranceCategory = nil
        d.isDungeonEntrance = nil
        if r.isZone then
            d.isZone = true
            d.zoneMapID = r.zoneMapID
            d.entranceMapID = r.entranceMapID
            d.entranceX = r.entranceX
            d.entranceY = r.entranceY
            d.entranceIcon = r.entranceIcon
            d.entranceCategory = r.entranceCategory
        end
        if r.isDungeonEntrance then
            d.isDungeonEntrance = true
            if not d.entranceMapID then
                d.entranceMapID = r.entranceMapID
            end
        end
        local out = results[ri]
        if not out then
            out = {}
            results[ri] = out
        end
        out.score = r.score or 50
        out.data = d
    end
    for i = resultCap + 1, #results do
        results[i] = nil
    end

    return results
end

-- Handle click on a map search result from the UI search bar.
-- Local results:
--   Fast mode: place waypoint without opening map.
--   Standard mode: guide to open the world map, then show pin.
-- Global results (zones, instances):
--   Fast mode: open map directly and run SelectResult (highlight/waypoint).
--   Standard mode: guide to open map, then run SelectResult.
function MapSearch:HandleUISearchClick(data, forceGuide)
    if not data then return end

    local isGlobalResult = data.isZone or data.isDungeonEntrance

    -- Activate the MapTab + populate the search box with the originating
    -- query. Mirrors the end state the user would have if they'd typed
    -- the same query inside the MapTab and clicked the same row: tab
    -- active, results visible, search bar showing the query (unfocused
    -- so the click doesn't trap WASD). MapTab.OpenWithQuery handles
    -- ToggleWorldMap itself, so the per-branch ToggleWorldMap calls
    -- below become no-ops when the MapTab path runs.
    if ns.MapTab and ns.MapTab.OpenWithQuery and data.query then
        ns.MapTab:OpenWithQuery(data.query)
    end

    if isGlobalResult then
        -- Open the world map at the target and show a waypoint/zone.
        -- Guide/breadcrumb mode (forceGuide=true) walks parent zones via
        -- breadcrumb arrows; fast mode jumps straight to the entrance.
        if not WorldMapFrame or not WorldMapFrame:IsShown() then
            ToggleWorldMap()
        end
        if forceGuide then
            -- Reuse the MapSearch SelectResult path with directOverride=false
            -- so breadcrumb/teaching mode kicks in (HighlightBreadcrumb...).
            self:SelectResult(data, false)
        elseif data.entranceMapID and data.entranceX and data.entranceY then
            WorldMapFrame:SetMapID(data.entranceMapID)
            self:ShowWaypointAt(data.entranceX, data.entranceY,
                data.entranceIcon or data.icon, data.entranceCategory or data.category)
        elseif data.zoneMapID then
            WorldMapFrame:SetMapID(data.zoneMapID)
        end
    else
        -- Local POI: open the world map at the POI's zone and show the
        -- visual pin on the canvas. We deliberately do NOT call
        -- SetUserWaypoint / SetSuperTrackedUserWaypoint here — the user
        -- has to click the on-canvas pin's tracking icon to actually
        -- start tracking, matching the way clicking the small map pin
        -- works elsewhere in the addon (and Blizzard's own UI).
        local x, y = data.x, data.y
        if data.mapID and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            activePinState = {
                mapID = data.mapID,
                x = x, y = y,
                icon = data.icon, category = data.category,
                isLocal = true,
            }
            MapSearch:RefreshAllClearButtons()
            if not WorldMapFrame or not WorldMapFrame:IsShown() then
                ToggleWorldMap()
            end
            if WorldMapFrame and WorldMapFrame:GetMapID() ~= data.mapID then
                WorldMapFrame:SetMapID(data.mapID)
            end
            self:ShowWaypointAt(x, y, data.icon, data.category)
        end
    end
end

-- Preview a map search result from the UI search bar on the world map.
-- Only shows if WorldMapFrame is open. Returns true if preview was shown.
function MapSearch:PreviewUIResult(data)
    if not data or not WorldMapFrame or not WorldMapFrame:IsShown() then return false end
    local coords = self:GetPreviewCoords(data)
    if not coords then return false end
    self._savedPinState = activePinState
    self._previewing = true
    if coords.instances then
        self:ShowMultipleWaypoints(coords.instances)
    elseif coords.pin and coords.pin:IsShown() then
        self:HighlightPin(coords.pin, coords.x, coords.y, coords.icon, coords.category)
    else
        self:ShowWaypointAt(coords.x, coords.y, coords.icon, coords.category)
    end
    activePinState = self._savedPinState
    return true
end

-- Clear a UI result preview and restore previous pin state.
function MapSearch:ClearUIPreview()
    if not self._previewing then return end
    self._previewing = nil
    self:ClearHighlight()
    local saved = self._savedPinState
    self._savedPinState = nil
    if saved and WorldMapFrame and WorldMapFrame:IsShown()
       and saved.mapID == WorldMapFrame:GetMapID() then
        if saved.instances then
            self:ShowMultipleWaypoints(saved.instances)
        else
            self:ShowWaypointAt(saved.x, saved.y, saved.icon, saved.category)
        end
    end
end

-- Pending navigation data for standard mode: after guide finishes and map opens,
-- continue with map navigation (set zone + place waypoint).
local pendingMapNav = nil

function MapSearch:SetPendingNavigation(data)
    pendingMapNav = data
    if not data then return end
    -- Watch for WorldMapFrame to appear via a short-lived ticker
    if self._pendingNavTicker then
        self._pendingNavTicker:Cancel()
    end
    local elapsed = 0
    self._pendingNavTicker = C_Timer.NewTicker(0.1, function(ticker)
        elapsed = elapsed + 0.1
        -- Timeout after 30 seconds
        if elapsed > 30 then
            ticker:Cancel()
            self._pendingNavTicker = nil
            pendingMapNav = nil
            return
        end
        if not pendingMapNav then
            ticker:Cancel()
            self._pendingNavTicker = nil
            return
        end
        if WorldMapFrame and WorldMapFrame:IsShown() then
            ticker:Cancel()
            self._pendingNavTicker = nil
            local nav = pendingMapNav
            pendingMapNav = nil
            if ns.Highlight then ns.Highlight:Cancel() end
            -- For local POIs, pre-navigate to their map so SelectResult
            -- can place the pin. For zones/instances, SelectResult handles
            -- its own navigation (breadcrumbs, entrance highlighting, etc.)
            if nav.mapID and not nav.isZone and not nav.isDungeonEntrance then
                WorldMapFrame:SetMapID(nav.mapID)
            end
            MapSearch:SelectResult(nav)
        end
    end)
end
