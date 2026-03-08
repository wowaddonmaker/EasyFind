local ADDON_NAME, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local Utils     = ns.Utils
local DebugPrint = Utils.DebugPrint
local pairs, ipairs, type, select = Utils.pairs, Utils.ipairs, Utils.type, Utils.select
local tinsert, tsort, tconcat, tremove = Utils.tinsert, Utils.tsort, Utils.tconcat, Utils.tremove
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local mmin, mmax, mabs, mpi, mfloor, msin = Utils.mmin, Utils.mmax, Utils.mabs, Utils.mpi, Utils.mfloor, math.sin
local pcall, tostring = Utils.pcall, Utils.tostring

local CreateFrame        = CreateFrame
local C_Map              = C_Map
local C_Timer            = C_Timer
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local UIParent           = UIParent
local IsShiftKeyDown     = IsShiftKeyDown
local IsMouseButtonDown  = IsMouseButtonDown
local hooksecurefunc     = hooksecurefunc
local wipe               = wipe
local strsplit           = strsplit

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
ns.MULTI_SCALE       = 0.85

-- Zone indicator (continent maps)
ns.ZONE_ICON_SIZE      = 48
ns.ZONE_ICON_GLOW_SIZE = 68

-- Breadcrumb indicator
ns.BREADCRUMB_SIZE   = 48

--- Convert a size in UI units to canvas units so it appears the same visual
--- size as a same-valued element on UIParent.
--- WoW's map zooms by making the canvas LARGER, not by changing scale.
--- So the conversion is: canvasWidth / viewportWidth (canvas units per screen unit).
--- @param uiSize number  size in UI coordinate units
--- @return number  equivalent canvas coordinate units
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

--- Create icon + glow textures on a parent frame.
--- Returns nothing; sets parentFrame.indicator and parentFrame.glow.
--- @param parentFrame Frame  - the frame the icon sits in
--- @param iconSize number|nil  - override size (defaults to ns.ICON_SIZE)
--- @param glowSize number|nil  - override glow (defaults to ns.ICON_GLOW_SIZE; 0 = no glow)
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
        glow:SetTexture("Interface\\Cooldown\\star4")
        glow:SetVertexColor(color[1], color[2], color[3], 0.35)
        glow:SetBlendMode("ADD")
        parentFrame.glow = glow
    end

    -- Auto-update on every Show so indicators are ALWAYS in sync with settings.
    parentFrame:HookScript("OnShow", function(self)
        ns.UpdateIndicator(self)
    end)
end

--- Update an existing indicator (and optional glow) to match current settings.
--- Works on any frame that was set up with ns.CreateIndicatorTextures.
--- @param parentFrame Frame
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
    local indicatorRotation = 0
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
        parentFrame:SetScale(EasyFind.db.iconScale or 1.0)
    end
end

--- Compute the rotation for an indicator pointing in a given direction.
--- Takes the style's own rotation into account so every style works correctly.
--- @param direction string "down"|"up"|"left"|"right"
--- @return number rotation in radians
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

local searchFrame       -- Local search bar (left)
local globalSearchFrame -- Global search bar (right)
local activeSearchFrame -- Which bar is currently active
local resultsFrame
local resultButtons = {}
local MAX_RESULTS_POOL = 50  -- pre-created button pool (scroll handles overflow)
local highlightFrame
local indicatorFrame
local currentHighlightedPin
local waypointPin
local zoneHighlightFrame  -- For highlighting zones on continent maps
local isGlobalSearch = false  -- Tracks which search bar triggered the current search
local activePinState = nil    -- {mapID, x, y, icon, category} - survives map close/reopen
local superTrackGlow          -- Perimeter glow frame (far mode)
local nearTrackFrame          -- Ring + arrow frame (near mode)
local waypointController      -- Invisible controller that drives OnUpdate

-- MINIMAP WAYPOINT TRACKER - perimeter glow (far) + ring/arrow (near)

local matan2, mcos, msin, msqrt = math.atan2, math.cos, math.sin, math.sqrt
local GetPlayerFacing = GetPlayerFacing
local NEAR_RING_RADIUS = 22   -- pixels from minimap center to ring edge

-- Minimap yard radius: use C_Minimap.GetViewRadius() (available 11.x+) for
-- exact per-frame values. Falls back to HereBeDragons-style lookup tables
-- for older clients (indoor/outdoor split, zoom 0–5).
local MINIMAP_SIZE_INDOOR  = { [0]=300, [1]=240, [2]=180, [3]=120, [4]=80, [5]=50 }
local MINIMAP_SIZE_OUTDOOR = { [0]=466.67, [1]=400, [2]=333.33, [3]=266.67, [4]=200, [5]=133.33 }

local function GetMinimapYardRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        return C_Minimap.GetViewRadius()
    end
    -- Fallback for older clients
    local zoom = Minimap:GetZoom()
    local isIndoors = IsIndoors and IsIndoors()
    local tbl = isIndoors and MINIMAP_SIZE_INDOOR or MINIMAP_SIZE_OUTDOOR
    return tbl[zoom] or tbl[0]
end

-- Forward declarations (defined after CreateWaypointTracker but referenced inside its OnUpdate)
local ShowSuperTrackGlow, HideSuperTrackGlow

-- Blizzard waypoint integration - we place Blizzard's native waypoint and add
-- our perimeter glow on top.  efPlacedWaypoint tracks whether we own the pin.
local efPlacedWaypoint = false
local cachedWPMapID, cachedWPx, cachedWPy  -- cached coords to avoid per-frame allocs
local DEFAULT_ARRIVAL_DISTANCE = 10
local function GetArrivalDistance()
    return EasyFind.db.arrivalDistance or DEFAULT_ARRIVAL_DISTANCE
end

local function CreateWaypointTracker()
    -- Controller: invisible frame that runs the shared OnUpdate
    if not waypointController then
        waypointController = CreateFrame("Frame", nil, Minimap)
        waypointController:SetSize(1, 1)
        waypointController:Hide()
    end

    -- Perimeter glow (shown behind Blizzard's supertrack arrow when waypoint is far)
    if not superTrackGlow then
        local glowSize = 48
        superTrackGlow = CreateFrame("Frame", "EasyFindMinimapGlow", UIParent)
        superTrackGlow:SetSize(glowSize, glowSize)
        superTrackGlow:SetFrameStrata("HIGH")
        superTrackGlow:SetFrameLevel(100)
        superTrackGlow.glowSize = glowSize

        -- Star glow effect (same as Blizzard waypoint glow)
        local glow = superTrackGlow:CreateTexture(nil, "ARTWORK")
        glow:SetSize(glowSize * 2.2, glowSize * 2.2)
        glow:SetPoint("CENTER")
        glow:SetTexture("Interface\\Cooldown\\star4")
        glow:SetVertexColor(1, 1, 0, 0.7)
        glow:SetBlendMode("ADD")
        superTrackGlow.glow = glow

        local ag = superTrackGlow:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local alpha = ag:CreateAnimation("Alpha")
        alpha:SetFromAlpha(1)
        alpha:SetToAlpha(0.5)
        alpha:SetDuration(0.5)
        superTrackGlow.animGroup = ag
        superTrackGlow:Hide()
    end

    -- Near-track ring + directional arrow (shown when waypoint is on the minimap)
    if not nearTrackFrame then
        nearTrackFrame = CreateFrame("Frame", "EasyFindNearTrack", Minimap)
        nearTrackFrame:SetAllPoints()
        nearTrackFrame:SetFrameStrata("HIGH")
        nearTrackFrame:SetFrameLevel(100)

        local ringSize = (NEAR_RING_RADIUS * 2 + 6) * 0.8  -- 20% smaller
        local ringLayers = {}
        for i = 1, 2 do
            local layer = nearTrackFrame:CreateTexture(nil, "OVERLAY", nil, i)
            layer:SetSize(ringSize, ringSize)
            layer:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
            layer:SetTexture(131016)
            layer:SetTexCoord(0.25, 0.5, 0.875, 1.0)
            layer:SetBlendMode("ADD")
            layer:SetVertexColor(1, 1, 0.3, 1)
            ringLayers[i] = layer
        end
        nearTrackFrame.ring = ringLayers[1]
        nearTrackFrame.ringLayers = ringLayers
        nearTrackFrame.ringBaseSize = ringSize

        local ag = nearTrackFrame:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local alpha = ag:CreateAnimation("Alpha")
        alpha:SetFromAlpha(1)
        alpha:SetToAlpha(0.6)
        alpha:SetDuration(0.6)
        nearTrackFrame.animGroup = ag
        nearTrackFrame:Hide()
    end

    -- OnUpdate: calculate angle + distance, show perimeter glow when far, ring when near, auto-clear on arrival
    waypointController:SetScript("OnUpdate", function(self, elapsed)
        if not efPlacedWaypoint then
            if self.lastMode then
                self.lastMode = nil
            end
            HideSuperTrackGlow()
            return
        end

        -- If user manually cleared the Blizzard waypoint, clean up
        if not C_Map.HasUserWaypoint() then
            HideSuperTrackGlow()
            return
        end

        local wpMapID = cachedWPMapID
        local wx, wy = cachedWPx, cachedWPy
        if not wpMapID or not wx or not wy then
            HideSuperTrackGlow()
            return
        end

        local mapID = C_Map.GetBestMapForUnit("player")
        if not mapID then return end

        local playerPos = C_Map.GetPlayerMapPosition(mapID, "player")
        if not playerPos then return end

        -- World coordinates for angle (works across continents)
        local pCont, pWorld = C_Map.GetWorldPosFromMapPos(mapID, playerPos)
        if not pWorld then return end

        local wCont, wWorld = C_Map.GetWorldPosFromMapPos(wpMapID, CreateVector2D(wx, wy))
        if not wWorld then return end

        local dx = pWorld.x - wWorld.x
        local dy = pWorld.y - wWorld.y
        local angle = matan2(dy, -dx)

        -- Adjust for minimap rotation
        if GetCVar("rotateMinimap") == "1" then
            local facing = GetPlayerFacing()
            if facing then
                angle = angle - facing
            end
        end

        -- Distance in actual yards via map coordinate projection
        -- Both positions must be on the same map for a meaningful distance
        local dist
        local px, py = playerPos:GetXY()
        if mapID == wpMapID then
            local mapWidth, mapHeight = C_Map.GetMapWorldSize(mapID)
            local dxYards = (px - wx) * mapWidth
            local dyYards = (py - wy) * mapHeight
            dist = msqrt(dxYards * dxYards + dyYards * dyYards)
        else
            local wpMapPlayerPos = C_Map.GetPlayerMapPosition(wpMapID, "player")
            if wpMapPlayerPos then
                local wpPx, wpPy = wpMapPlayerPos:GetXY()
                local mapWidth, mapHeight = C_Map.GetMapWorldSize(wpMapID)
                local dxYards = (wpPx - wx) * mapWidth
                local dyYards = (wpPy - wy) * mapHeight
                dist = msqrt(dxYards * dxYards + dyYards * dyYards)
            end
        end
        local viewRadius = GetMinimapYardRadius()

        -- Auto-clear when player arrives at destination (skip if cross-map)
        if dist and dist < GetArrivalDistance() then
            MapSearch:ClearAll()
            return
        end

        if dist and dist < viewRadius then
            -- NEAR MODE: ring around player (Blizzard's pin is visible on minimap)
            if not self.lastMode or self.lastMode ~= "NEAR" then
                self.lastMode = "NEAR"
            end
            if superTrackGlow:IsShown() then
                superTrackGlow.animGroup:Stop()
                superTrackGlow:Hide()
            end
            if not nearTrackFrame:IsShown() then
                nearTrackFrame:Show()
                nearTrackFrame.animGroup:Play()
            end
            -- Rotate ring so its built-in arrowhead points toward the waypoint
            local rot = -(angle + math.pi / 4)

            -- Scale ring down as player approaches
            local minimapPxRadius = Minimap:GetWidth() / 2
            local pixelDist = (dist / viewRadius) * minimapPxRadius
            local baseSize = nearTrackFrame.ringBaseSize
            local arrowTipRadius = baseSize / 2 * 2.2
            local scale = 1
            if pixelDist < arrowTipRadius then
                scale = pixelDist / arrowTipRadius
                if scale < 0.15 then scale = 0.15 end
            end
            local sz = baseSize * scale

            for _, layer in ipairs(nearTrackFrame.ringLayers) do
                layer:SetRotation(rot)
                layer:SetSize(sz, sz)
            end
        else
            -- FAR MODE: perimeter glow
            if not self.lastMode or self.lastMode ~= "FAR" then
                self.lastMode = "FAR"
            end
            if nearTrackFrame:IsShown() then
                nearTrackFrame.animGroup:Stop()
                nearTrackFrame:Hide()
            end
            if not superTrackGlow:IsShown() then
                superTrackGlow:Show()
                superTrackGlow.animGroup:Play()
            end
            -- Position glow on minimap perimeter at the waypoint angle
            local perimeterRadius = Minimap:GetWidth() / 2
            local glowX = msin(angle) * perimeterRadius
            local glowY = mcos(angle) * perimeterRadius
            superTrackGlow:ClearAllPoints()
            superTrackGlow:SetPoint("CENTER", Minimap, "CENTER", glowX, glowY)
            superTrackGlow.glow:SetRotation(-angle)
        end
    end)
end

ShowSuperTrackGlow = function()
    CreateWaypointTracker()
    waypointController:Show()
end

HideSuperTrackGlow = function()
    efPlacedWaypoint = false
    cachedWPMapID = nil
    cachedWPx = nil
    cachedWPy = nil
    if waypointController then
        waypointController:Hide()
    end
    if superTrackGlow and superTrackGlow:IsShown() then
        superTrackGlow.animGroup:Stop()
        superTrackGlow:Hide()
    end
    if nearTrackFrame and nearTrackFrame:IsShown() then
        nearTrackFrame.animGroup:Stop()
        nearTrackFrame:Hide()
    end
end

-- Auto-clear everything after a loading screen (teleport, hearthstone, portal, etc.)
local loadingScreenFrame = CreateFrame("Frame")
loadingScreenFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loadingScreenFrame:RegisterEvent("USER_WAYPOINT_UPDATED")
loadingScreenFrame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUI)
    if event == "USER_WAYPOINT_UPDATED" then
        -- If we placed the waypoint and user cleared it externally, clean up glow
        if efPlacedWaypoint and not C_Map.HasUserWaypoint() then
            HideSuperTrackGlow()
        end
        return
    end
    -- PLAYER_ENTERING_WORLD
    if isInitialLogin or isReloadingUI then return end  -- skip login/reload

    -- Defer slightly so the map system has settled
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

-- Simple pin context popup (BOTTOMLEFT anchored at cursor so it opens above)
local pinPopup
local function ShowPinPopup(btn, isPinned, onAction)
    if not pinPopup then
        pinPopup = CreateFrame("Button", "EasyFindMapPinPopup", UIParent, "BackdropTemplate")
        pinPopup:SetSize(60, 22)
        pinPopup:SetFrameStrata("TOOLTIP")
        pinPopup:SetFrameLevel(10000)
        pinPopup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        pinPopup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        local label = pinPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        pinPopup.label = label
        pinPopup:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        pinPopup:SetScript("OnLeave", function(self) self:Hide() end)
    end
    pinPopup.label:SetText(isPinned and "Unpin" or "Pin")
    pinPopup:SetScript("OnClick", function(self)
        self:Hide()
        onAction()
    end)
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    pinPopup:ClearAllPoints()
    pinPopup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    pinPopup:Show()
end

-- Category icons mapping
local CATEGORY_ICONS = {
    flightmaster = "atlas:TaxiNode_Neutral",
    zeppelin = "Interface\\Icons\\INV_Misc_AirshipPart_Propeller",
    boat = "Interface\\Icons\\Achievement_BG_captureflag_EOS",
    portal = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
    tram = "Interface\\Icons\\INV_Misc_Gear_01",
    -- Cropped texCoords from atlas sprite sheet 1121272 - removes the built-in glow border
    -- Full atlas coords: Dungeon L=0.1982 R=0.2471 T=0.4404 B=0.4893
    --                     Raid    L=0.1982 R=0.2471 T=0.4912 B=0.5400
    --                     delves  L=0.0010 R=0.0635 T=0.3896 B=0.4521
    dungeon = { file = 1121272, coords = { 0.2056, 0.2397, 0.4478, 0.4819 } },
    raid    = { file = 1121272, coords = { 0.2056, 0.2397, 0.4986, 0.5327 } },
    delve   = { file = 1121272, coords = { 0.0104, 0.0541, 0.3990, 0.4427 } },
    bank = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
    auctionhouse = "Interface\\Icons\\INV_Misc_Coin_01",
    innkeeper = "Interface\\Icons\\Spell_Holy_GreaterHeal",
    trainer = "Interface\\Icons\\INV_Misc_Book_09",
    proftrainer = "Interface\\Icons\\INV_Misc_Book_09",
    classtrainer = { file = 131016, coords = { 0.000, 0.250, 0.375, 0.500 } },
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
    vendor = "Interface\\Icons\\INV_Misc_Bag_07",
    pvpvendor = 236396,
    pvpquest = 236396,
    battlemasters = 236396,
    mailbox = "Interface\\Icons\\INV_Letter_15",
    stablemaster = "Interface\\Icons\\Ability_Hunter_BeastCall",
    repairvendor = "Interface\\Icons\\INV_Hammer_20",
    barber = "Interface\\Icons\\INV_Misc_Comb_01",
    transmogrifier = "Interface\\Icons\\INV_Arcane_Orb",
    rare = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    treasure = "Interface\\Icons\\INV_Misc_Bag_10",
    catalyst = "Interface\\Icons\\INV_10_GearUpgrade_Catalyst_Charged",
    greatvault = "Interface\\Icons\\INV_Misc_Lockbox_1",
    upgradevendor = 463442, -- Reforge icon (FileDataID)
    guildservices = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
    voidstorage = "Interface\\Icons\\INV_Enchant_VoidCrystal",
    tradingpost = "Interface\\Icons\\tradingpostcurrency",
    chromie = "atlas:ChromieTime-32x32",
    areapoi = "Interface\\Icons\\INV_Misc_QuestionMark",
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
}

local function GetCategoryIcon(category)
    return CATEGORY_ICONS[category] or CATEGORY_ICONS.unknown
end

-- Helper: set a texture to a file path, fileDataID, atlas (prefixed "atlas:"), or
-- cropped table { file = <id>, coords = { L, R, T, B } }.
-- Resets texture state first to prevent texCoord/atlas bleed between rows.
local function SetIconTexture(textureObj, icon)
    textureObj:SetTexture(nil)
    textureObj:SetTexCoord(0, 1, 0, 1)
    if type(icon) == "table" then
        textureObj:SetTexture(icon.file)
        local c = icon.coords
        textureObj:SetTexCoord(c[1], c[2], c[3], c[4])
    elseif type(icon) == "string" and sfind(icon, "^atlas:") then
        textureObj:SetAtlas(icon:sub(7))
    else
        textureObj:SetTexture(icon)
    end
end

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
    mailbox = { keywords = {"mail", "mailbox"}, parent = "service" },
    stablemaster = { keywords = {"stable", "stable master", "pet"}, parent = "service" },
    repairvendor = { keywords = {"repair", "repairs", "anvil"}, parent = "service" },
    barber = { keywords = {"barber", "barbershop", "appearance", "haircut"}, parent = "service" },
    transmogrifier = { keywords = {"transmog", "transmogrifier", "appearance"}, parent = "service" },
    
    rare = { keywords = {"rare", "rares", "silver dragon", "elite"} },
    treasure = { keywords = {"treasure", "chest", "loot"} },
    catalyst = { keywords = {"catalyst", "tier", "tier set", "revival catalyst", "upgrade"}, parent = "service" },
    greatvault = { keywords = {"great vault", "vault", "weekly rewards", "weekly chest"}, parent = "service" },
    upgradevendor = { keywords = {"upgrade", "upgrade vendor", "flightstone", "crest"}, parent = "service" },
    tradingpost = { keywords = {"trading post", "trader's tender", "tender", "tmog", "xmog"}, parent = "service" },
}

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
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    self:CreateHighlightFrame()
    self:CreateZoneHighlightFrame()
    self:HookWorldMap()
    self:UpdateScale()
    self:UpdateOpacity()
end

-- SHARED FILTER DROPDOWN BUILDER - creates a tracking-menu-style checkbox panel
function MapSearch:CreateFilterDropdown(globalName, options, dbKey, toggleBtn, anchorFrame, searchEditBox)
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
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    -- "Show:" header (gold text, matching WoW tracking menu)
    local header = dropdown:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    header:SetPoint("TOPLEFT", 12, -PADDING_TOP)
    header:SetText("Show:")
    header:SetTextColor(1, 0.82, 0, 1)

    local checkRows = {}
    local yStart = -(PADDING_TOP + HEADER_HEIGHT)

    for i, opt in ipairs(options) do
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, yStart - (i - 1) * ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)

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

        -- Start checked
        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db[dbKey]
            filters[opt.key] = self:GetChecked()
            if searchEditBox:GetText() ~= "" then
                MapSearch:OnSearchTextChanged(searchEditBox:GetText())
            end
        end)

        checkRows[opt.key] = row
    end

    local totalHeight = PADDING_TOP + HEADER_HEIGHT + #options * ROW_HEIGHT + PADDING_BOTTOM
    dropdown:SetSize(DROPDOWN_WIDTH, totalHeight)

    -- Sync checkmarks to saved state on show
    dropdown:SetScript("OnShow", function()
        local filters = EasyFind.db[dbKey]
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
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

    -- Toggle on filter button click; position using screen coordinates
    -- so scale differences between UIParent and the search bar don't cause gaps
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

function MapSearch:CreateSearchFrame()
    -- LOCAL search bar (left side - searches current map's child zones + POIs)
    searchFrame = CreateFrame("Frame", "EasyFindMapSearchFrame", WorldMapFrame, "BackdropTemplate")
    searchFrame:SetSize(250, 32)
    searchFrame:SetFrameStrata("DIALOG")
    searchFrame:SetFrameLevel(9999)
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetToplevel(true)
    
    -- Apply saved position or default (left side)
    if EasyFind.db.mapSearchPosition then
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", EasyFind.db.mapSearchPosition, 2)
    else
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 2)
    end
    
    -- Apply theme-appropriate backdrop (border only - atlas fills the background)
    if (EasyFind.db.resultsTheme or "Classic") == "Retail" then
        searchFrame:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)
    else
        searchFrame:SetBackdrop({
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local bgTex = searchFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgTex:SetPoint("TOPLEFT", 4, -4)
    bgTex:SetPoint("BOTTOMRIGHT", -4, 4)
    bgTex:SetColorTexture(0, 0, 0, EasyFind.db.searchBarOpacity or 0.75)
    searchFrame:SetClipsChildren(true)
    searchFrame.bgTex = bgTex

    -- Draggable with Shift key (constrained to map bottom edge)
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self.isDragging = true
            self.dragStartX = select(4, self:GetPoint()) or 0
        end
    end)
    searchFrame:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)
    searchFrame:SetScript("OnUpdate", function(self)
        if self.isDragging and IsShiftKeyDown() then
            local cursorX = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            local mapLeft = WorldMapFrame.ScrollContainer:GetLeft() * scale
            local mapRight = WorldMapFrame.ScrollContainer:GetRight() * scale
            local frameWidth = self:GetWidth() * self:GetEffectiveScale()
            
            -- Calculate new X position relative to map
            local newX = (cursorX - mapLeft) / scale - (self:GetWidth() / 2)
            
            -- Constrain to map width
            local maxX = (mapRight - mapLeft) / scale - self:GetWidth()
            newX = mmax(0, mmin(newX, maxX))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", newX, 2)
            EasyFind.db.mapSearchPosition = newX
        elseif self.isDragging then
            self.isDragging = false
        end
    end)
    
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(14, 14)
    searchIcon:SetPoint("LEFT", 10, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    searchIcon:SetVertexColor(1, 0.82, 0)  -- Gold tint to match local theme
    
    local editBox = CreateFrame("EditBox", "EasyFindMapSearchBox", searchFrame)
    editBox:SetSize(150, 20)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)
    
    local placeholder = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search within this zone")
    editBox.placeholder = placeholder
    
    editBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
        -- Clear the other search bar when focusing this one
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox:ClearFocus()
            globalSearchFrame.editBox.placeholder:Show()
        end
        isGlobalSearch = false
        activeSearchFrame = searchFrame
        -- Show pinned items when focusing with empty text
        if self:GetText() == "" then
            MapSearch:ShowPinnedItems()
        end
    end)
    
    editBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
        end
    end)
    
    editBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        isGlobalSearch = false
        activeSearchFrame = searchFrame
        MapSearch:OnSearchTextChanged(self:GetText())
    end)
    
    editBox:SetScript("OnEnterPressed", function(self)
        MapSearch:SelectFirstResult()
    end)
    
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        -- Text and results stay visible; user can click back in to resume
    end)
    
    -- Filter button (inside search bar, flush right - same as global bar)
    local localFilterBtn = CreateFrame("Button", "EasyFindMapLocalFilterButton", searchFrame)
    localFilterBtn:SetSize(34, 34)
    localFilterBtn:SetPoint("RIGHT", searchFrame, "RIGHT", 1, -4)
    localFilterBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    local localArrow = localFilterBtn:CreateTexture(nil, "OVERLAY")
    localArrow:SetAllPoints()
    localArrow:SetAtlas("common-dropdown-a-button")

    local maskWrap = "CLAMPTOBLACKADDITIVE"
    local diagTexL = "Interface\\AddOns\\EasyFind\\Images\\mask-diagonal"
    local diagTexR = "Interface\\AddOns\\EasyFind\\Images\\mask-diagonal-r"

    -- Left diagonal (top crop baked into TGA)
    local mBL = localFilterBtn:CreateMaskTexture()
    mBL:SetTexture(diagTexL, maskWrap, maskWrap)
    mBL:SetPoint("TOPLEFT", localArrow, "TOPLEFT", 0, 0)
    mBL:SetPoint("BOTTOMRIGHT", localArrow, "BOTTOMRIGHT", 0, 0)
    localArrow:AddMaskTexture(mBL)

    -- Right diagonal (separate mirrored TGA)
    local mBR = localFilterBtn:CreateMaskTexture()
    mBR:SetTexture(diagTexR, maskWrap, maskWrap)
    mBR:SetPoint("TOPLEFT", localArrow, "TOPLEFT", 0, 0)
    mBR:SetPoint("BOTTOMRIGHT", localArrow, "BOTTOMRIGHT", 0, 0)
    localArrow:AddMaskTexture(mBR)

    localFilterBtn.arrow = localArrow

    local localFullBtn = localFilterBtn:CreateTexture(nil, "ARTWORK")
    localFullBtn:SetAllPoints()
    localFullBtn:SetAtlas("common-dropdown-a-button-open")
    localFullBtn:Hide()
    localFilterBtn.fullBtn = localFullBtn

    localFilterBtn:SetHighlightTexture(130757)

    localFilterBtn:SetScript("OnEnter", function(self)
        self.arrow:Hide()
        self.fullBtn:Show()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Filter Results")
        GameTooltip:AddLine("Choose which result types to show.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    localFilterBtn:SetScript("OnLeave", function(self)
        self.fullBtn:Hide()
        self.arrow:Show()
        GameTooltip_Hide()
    end)

    -- Clear button (grey circle X, matching retail quest log style)
    local clearBtn = Utils.CreateClearButton(searchFrame)
    clearBtn:ClearAllPoints()
    clearBtn:SetPoint("RIGHT", searchFrame, "RIGHT", -32, 0)
    clearBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)

    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        editBox.placeholder:Show()
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox:ClearFocus()
            globalSearchFrame.editBox.placeholder:Show()
        end
        MapSearch:HideResults()
        MapSearch:ClearAll()
        MapSearch:ClearZoneHighlight()
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all map icons and zone highlights")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", GameTooltip_Hide)
    searchFrame.clearBtn = clearBtn
    
    -- Show/hide clear button based on text
    editBox:HookScript("OnTextChanged", function(self)
        clearBtn:SetShown(self:GetText() ~= "")
    end)
    
    -- Click anywhere on the search frame to focus the editbox
    searchFrame:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            editBox:SetFocus()
        end
    end)
    
    -- Invisible button over the icon to capture hover for tooltip
    local searchIconHitbox = CreateFrame("Button", nil, searchFrame)
    searchIconHitbox:SetSize(22, 22)
    searchIconHitbox:SetPoint("CENTER", searchIcon, "CENTER", 0, 0)
    searchIconHitbox:SetFrameLevel(searchFrame:GetFrameLevel() + 2)
    searchIconHitbox:EnableMouse(true)
    searchIconHitbox:RegisterForClicks()
    searchIconHitbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFFFFD100This Zone|r Search")
        GameTooltip:AddLine("Searches for POIs and sub-zones within the map you're currently viewing.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    searchIconHitbox:SetScript("OnLeave", GameTooltip_Hide)
    searchIconHitbox:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            editBox:SetFocus()
        end
    end)

    -- Local filter dropdown
    local LOCAL_FILTER_OPTIONS = {
        { key = "instances", label = "Instances" },
        { key = "travel",    label = "Travel" },
        { key = "services",  label = "Services" },
    }

    local localFilterDropdown = MapSearch:CreateFilterDropdown(
        "EasyFindMapLocalFilterDropdown", LOCAL_FILTER_OPTIONS,
        "localSearchFilters", localFilterBtn, searchFrame, editBox
    )

    searchFrame.filterBtn = localFilterBtn
    searchFrame.filterDropdown = localFilterDropdown

    searchFrame.editBox = editBox
    searchFrame:Hide()

    -- GLOBAL search bar (right side - searches all zones in the world)
    globalSearchFrame = CreateFrame("Frame", "EasyFindMapGlobalSearchFrame", WorldMapFrame, "BackdropTemplate")
    globalSearchFrame:SetSize(250, 32)
    globalSearchFrame:SetFrameStrata("DIALOG")
    globalSearchFrame:SetFrameLevel(9999)
    globalSearchFrame:SetMovable(true)
    globalSearchFrame:EnableMouse(true)
    globalSearchFrame:SetToplevel(true)
    
    -- Position on the right side (anchored to bottom-right of the map scroll container)
    if EasyFind.db.globalSearchPosition then
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", EasyFind.db.globalSearchPosition, 2)
    else
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", 0, 2)
    end
    
    -- Apply theme-appropriate backdrop
    -- Apply theme-appropriate backdrop (border only - atlas fills the background)
    if (EasyFind.db.resultsTheme or "Classic") == "Retail" then
        globalSearchFrame:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        globalSearchFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)
    else
        globalSearchFrame:SetBackdrop({
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local bgTex = globalSearchFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgTex:SetPoint("TOPLEFT", 4, -4)
    bgTex:SetPoint("BOTTOMRIGHT", -4, 4)
    bgTex:SetColorTexture(0, 0, 0, EasyFind.db.searchBarOpacity or 0.75)
    globalSearchFrame:SetClipsChildren(true)
    globalSearchFrame.bgTex = bgTex

    -- Draggable with Shift key (constrained to map bottom edge)
    globalSearchFrame:RegisterForDrag("LeftButton")
    globalSearchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self.isDragging = true
        end
    end)
    globalSearchFrame:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)
    globalSearchFrame:SetScript("OnUpdate", function(self)
        if self.isDragging and IsShiftKeyDown() then
            local cursorX = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            local mapLeft = WorldMapFrame.ScrollContainer:GetLeft() * scale
            local mapRight = WorldMapFrame.ScrollContainer:GetRight() * scale
            
            -- Calculate new X position relative to map RIGHT edge (negative offset)
            local newX = (cursorX - mapRight) / scale + (self:GetWidth() / 2)
            
            -- Constrain
            local maxNeg = -((mapRight - mapLeft) / scale - self:GetWidth())
            newX = mmin(0, mmax(newX, maxNeg))
            
            self:ClearAllPoints()
            self:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", newX, 2)
            EasyFind.db.globalSearchPosition = newX
        elseif self.isDragging then
            self.isDragging = false
        end
    end)
    
    local globalSearchIcon = globalSearchFrame:CreateTexture(nil, "ARTWORK")
    globalSearchIcon:SetSize(14, 14)
    globalSearchIcon:SetPoint("LEFT", 10, 0)
    globalSearchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    globalSearchIcon:SetVertexColor(0.4, 0.8, 1)  -- Blue tint to match global theme
    
    local globalEditBox = CreateFrame("EditBox", "EasyFindMapGlobalSearchBox", globalSearchFrame)
    globalEditBox:SetSize(150, 20)
    globalEditBox:SetPoint("LEFT", globalSearchIcon, "RIGHT", 5, 0)
    globalEditBox:SetFontObject("ChatFontNormal")
    globalEditBox:SetAutoFocus(false)
    globalEditBox:SetMaxLetters(50)
    
    local globalPlaceholder = globalEditBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    globalPlaceholder:SetPoint("LEFT", 2, 0)
    globalPlaceholder:SetText("Search for zones & instances")
    globalEditBox.placeholder = globalPlaceholder
    
    globalEditBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
        -- Clear the other search bar when focusing this one
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox:SetText("")
            searchFrame.editBox:ClearFocus()
            searchFrame.editBox.placeholder:Show()
        end
        isGlobalSearch = true
        activeSearchFrame = globalSearchFrame
        -- Show pinned items when focusing with empty text
        if self:GetText() == "" then
            MapSearch:ShowPinnedItems()
        end
    end)
    
    globalEditBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
        end
    end)
    
    globalEditBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        isGlobalSearch = true
        activeSearchFrame = globalSearchFrame
        MapSearch:OnSearchTextChanged(self:GetText())
    end)
    
    globalEditBox:SetScript("OnEnterPressed", function(self)
        MapSearch:SelectFirstResult()
    end)
    
    globalEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        -- Text and results stay visible; user can click back in to resume
    end)
    
    -- Filter button (inside search bar, flush right)
    local filterBtn = CreateFrame("Button", "EasyFindMapFilterButton", globalSearchFrame)
    filterBtn:SetSize(34, 34)
    filterBtn:SetPoint("RIGHT", globalSearchFrame, "RIGHT", 1, -4)
    filterBtn:SetFrameLevel(globalSearchFrame:GetFrameLevel() + 10)

    local globalArrow = filterBtn:CreateTexture(nil, "OVERLAY")
    globalArrow:SetAllPoints()
    globalArrow:SetAtlas("common-dropdown-a-button")

    local gMaskTex = "Interface\\BUTTONS\\WHITE8x8"
    local gMaskWrap = "CLAMPTOBLACKADDITIVE"
    local gDiagTexL = "Interface\\AddOns\\EasyFind\\Images\\mask-diagonal"
    local gDiagTexR = "Interface\\AddOns\\EasyFind\\Images\\mask-diagonal-r"

    -- Left diagonal (top crop baked into TGA)
    local gMBL = filterBtn:CreateMaskTexture()
    gMBL:SetTexture(gDiagTexL, gMaskWrap, gMaskWrap)
    gMBL:SetPoint("TOPLEFT", globalArrow, "TOPLEFT", 0, 0)
    gMBL:SetPoint("BOTTOMRIGHT", globalArrow, "BOTTOMRIGHT", 0, 0)
    globalArrow:AddMaskTexture(gMBL)

    -- Right diagonal (mirrored TGA)
    local gMBR = filterBtn:CreateMaskTexture()
    gMBR:SetTexture(gDiagTexR, gMaskWrap, gMaskWrap)
    gMBR:SetPoint("TOPLEFT", globalArrow, "TOPLEFT", 0, 0)
    gMBR:SetPoint("BOTTOMRIGHT", globalArrow, "BOTTOMRIGHT", 0, 0)
    globalArrow:AddMaskTexture(gMBR)

    filterBtn.arrow = globalArrow

    local globalFullBtn = filterBtn:CreateTexture(nil, "ARTWORK")
    globalFullBtn:SetAllPoints()
    globalFullBtn:SetAtlas("common-dropdown-a-button-open")
    globalFullBtn:Hide()
    filterBtn.fullBtn = globalFullBtn

    filterBtn:SetHighlightTexture(130757)

    filterBtn:SetScript("OnEnter", function(self)
        self.arrow:Hide()
        self.fullBtn:Show()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Filter Results")
        GameTooltip:AddLine("Choose which result types to show.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    filterBtn:SetScript("OnLeave", function(self)
        self.fullBtn:Hide()
        self.arrow:Show()
        GameTooltip_Hide()
    end)

    -- Clear button for global search (grey circle X) - shifted left of filter button
    local globalClearBtn = Utils.CreateClearButton(globalSearchFrame)
    globalClearBtn:ClearAllPoints()
    globalClearBtn:SetPoint("RIGHT", globalSearchFrame, "RIGHT", -32, 0)
    globalClearBtn:SetFrameLevel(globalSearchFrame:GetFrameLevel() + 10)

    globalClearBtn:SetScript("OnClick", function()
        globalEditBox:SetText("")
        globalEditBox:ClearFocus()
        globalEditBox.placeholder:Show()
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox:SetText("")
            searchFrame.editBox:ClearFocus()
            searchFrame.editBox.placeholder:Show()
        end
        MapSearch:HideResults()
        MapSearch:ClearAll()
        MapSearch:ClearZoneHighlight()
    end)
    globalClearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all map icons and zone highlights")
        GameTooltip:Show()
    end)
    globalClearBtn:SetScript("OnLeave", GameTooltip_Hide)
    globalSearchFrame.clearBtn = globalClearBtn
    
    -- Show/hide clear button based on text
    globalEditBox:HookScript("OnTextChanged", function(self)
        globalClearBtn:SetShown(self:GetText() ~= "")
    end)
    
    -- Click anywhere on the search frame to focus the editbox
    globalSearchFrame:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            globalEditBox:SetFocus()
        end
    end)
    
    -- Invisible button over the icon to capture hover for tooltip
    local globalIconHitbox = CreateFrame("Button", nil, globalSearchFrame)
    globalIconHitbox:SetSize(22, 22)
    globalIconHitbox:SetPoint("CENTER", globalSearchIcon, "CENTER", 0, 0)
    globalIconHitbox:SetFrameLevel(globalSearchFrame:GetFrameLevel() + 2)
    globalIconHitbox:EnableMouse(true)
    globalIconHitbox:RegisterForClicks()
    globalIconHitbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFF66CCFFAll Zones|r Search")
        GameTooltip:AddLine("Searches every zone in the entire world \226\128\148 continents, dungeons, and more.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    globalIconHitbox:SetScript("OnLeave", GameTooltip_Hide)
    globalIconHitbox:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            globalEditBox:SetFocus()
        end
    end)

    globalSearchFrame.editBox = globalEditBox
    globalSearchFrame:Hide()

    -- Filter dropdown (styled like WoW tracking menu)
    local FILTER_OPTIONS = {
        { key = "zones",    label = "Zones" },
        { key = "dungeons", label = "Dungeons" },
        { key = "raids",    label = "Raids" },
        { key = "delves",   label = "Delves" },
    }

    local filterDropdown = MapSearch:CreateFilterDropdown(
        "EasyFindMapFilterDropdown", FILTER_OPTIONS,
        "globalSearchFilters", filterBtn, globalSearchFrame, globalEditBox
    )

    globalSearchFrame.filterBtn = filterBtn
    globalSearchFrame.filterDropdown = filterDropdown

    -- Set initial active frame
    activeSearchFrame = searchFrame
end

function MapSearch:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindMapResultsFrame", WorldMapFrame, "BackdropTemplate")
    resultsFrame:SetWidth(300)
    resultsFrame:SetFrameStrata("TOOLTIP")
    resultsFrame:SetFrameLevel(1001)
    
    -- Default anchor to local search bar; will be re-anchored dynamically
    resultsFrame:SetPoint("TOPLEFT", searchFrame, "BOTTOMLEFT", 0, -2)
    
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })

    resultsFrame:Hide()

    -- Plain ScrollFrame for clipping + mouse wheel
    local scrollFrame = CreateFrame("ScrollFrame", nil, resultsFrame)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(mmax(0, mmin(range, cur - delta * 72)))
    end)
    resultsFrame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    resultsFrame.scrollChild = scrollChild

    -- Minimal retail-style scrollbar (overlays right edge, no content squish)
    resultsFrame.scrollBar = ns.Utils.CreateMinimalScrollBar(scrollFrame, resultsFrame)

    for i = 1, MAX_RESULTS_POOL do
        local btn = self:CreateResultButton(i)
        resultButtons[i] = btn
    end
end

-- Indent line color for map search grouped results
local MAP_INDENT_COLOR = {0.40, 0.85, 1.00, 0.70}  -- cyan

function MapSearch:CreateResultButton(index)
    local scrollChild = resultsFrame.scrollChild
    local btn = CreateFrame("Button", "EasyFindMapResultButton"..index, scrollChild)
    btn:SetSize(280, 24)
    -- No fixed SetPoint here; ShowResults positions dynamically
    
    -- Vertical indent line for grouped children
    local indentLine = btn:CreateTexture(nil, "BACKGROUND")
    indentLine:SetColorTexture(MAP_INDENT_COLOR[1], MAP_INDENT_COLOR[2], MAP_INDENT_COLOR[3], MAP_INDENT_COLOR[4])
    indentLine:SetWidth(2)
    indentLine:SetPoint("TOP", btn, "TOPLEFT", 14, 2)
    indentLine:SetPoint("BOTTOM", btn, "BOTTOMLEFT", 14, -2)
    indentLine:Hide()
    btn.indentLine = indentLine

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 5, 0)
    btn.icon = icon

    -- Highlight only covers text area (right of icon) so icons stay crisp
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local hl = btn:GetHighlightTexture()
    hl:ClearAllPoints()
    hl:SetPoint("LEFT", icon, "RIGHT", 2, 0)
    hl:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
    hl:SetPoint("TOP", btn, "TOP", 0, 0)
    hl:SetPoint("BOTTOM", btn, "BOTTOM", 0, 0)
    
    -- Secondary text for path prefix (shown above/before main text in gray)
    local prefixText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    prefixText:SetTextColor(0.5, 0.5, 0.5)
    prefixText:SetJustifyH("LEFT")
    prefixText:Hide()
    btn.prefixText = prefixText
    
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
    text:SetJustifyH("LEFT")
    btn.text = text
    
    -- Pin indicator (small map pin icon, shown for pinned items)
    local pinIcon = btn:CreateTexture(nil, "OVERLAY")
    pinIcon:SetSize(10, 10)
    pinIcon:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", -4, -1)
    pinIcon:SetAtlas("Waypoint-MapPin-ChatIcon")
    pinIcon:Hide()
    btn.pinIcon = pinIcon

    -- Navigate button - shortcut: select result + auto-set waypoint in one click
    local navBtn = CreateFrame("Button", nil, btn)
    navBtn:SetSize(24, 24)
    navBtn:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
    local navTex = navBtn:CreateTexture(nil, "ARTWORK")
    navTex:SetSize(22, 22)
    navTex:SetPoint("CENTER")
    navTex:SetAtlas("Waypoint-MapPin-Untracked")
    navBtn.texture = navTex
    navBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    navBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.disabled then
            GameTooltip:SetText("Navigate", 0.5, 0.5, 0.5)
            GameTooltip:AddLine("Only available when viewing your current zone", 0.6, 0.6, 0.6)
        else
            GameTooltip:SetText("Navigate")
            GameTooltip:AddLine("Place waypoint and track on minimap", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    navBtn:SetScript("OnLeave", GameTooltip_Hide)
    navBtn:SetScript("OnClick", function(self)
        if self.disabled then return end
        local data = btn.data
        if not data then return end

        -- Flag: auto-track once the pin is placed by ShowWaypointAt
        MapSearch.autoTrackNextPin = true
        MapSearch:SelectResult(data)
    end)
    navBtn:Hide()
    btn.navBtn = navBtn

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" and self.data then
            local pinData = self.data
            local isPinned = IsMapItemPinned(pinData)
            ShowPinPopup(self, isPinned, function()
                if isPinned then
                    UnpinMapItem(pinData)
                else
                    PinMapItem(pinData)
                end
                local editBox = activeSearchFrame and activeSearchFrame.editBox
                local text = editBox and editBox:GetText() or ""
                if text == "" and editBox and editBox:HasFocus() then
                    MapSearch:ShowPinnedItems()
                else
                    MapSearch:OnSearchTextChanged(text)
                end
            end)
            return
        end
        MapSearch:SelectResult(self.data)
    end)

    -- Hover preview: show pin at result coordinates while hovering
    btn:SetScript("OnEnter", function(self)
        local data = self.data
        if not data or isGlobalSearch then return end
        -- Only preview results with coordinates on the current map
        local coords = MapSearch:GetPreviewCoords(data)
        if not coords then return end
        -- Save current pin state before previewing
        MapSearch._savedPinState = activePinState
        MapSearch._previewing = true
        if coords.instances then
            MapSearch:ShowMultipleWaypoints(coords.instances)
        else
            MapSearch:ShowWaypointAt(coords.x, coords.y, coords.icon, coords.category)
        end
        -- Mark as preview so it doesn't become the persistent state
        activePinState = MapSearch._savedPinState
    end)
    btn:SetScript("OnLeave", function(self)
        if not MapSearch._previewing then return end
        MapSearch._previewing = nil
        -- Clear the preview pin
        MapSearch:ClearHighlight()
        -- Restore the previously active pin if it was on this map
        local saved = MapSearch._savedPinState
        MapSearch._savedPinState = nil
        if saved and saved.mapID == WorldMapFrame:GetMapID() then
            if saved.instances then
                MapSearch:ShowMultipleWaypoints(saved.instances)
            else
                MapSearch:ShowWaypointAt(saved.x, saved.y, saved.icon, saved.category)
            end
        end
    end)

    btn:Hide()
    return btn
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

function MapSearch:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "EasyFindMapHighlight", WorldMapFrame.ScrollContainer.Child)
    highlightFrame:SetSize(64, 64)
    highlightFrame:SetFrameStrata("TOOLTIP")
    highlightFrame:SetFrameLevel(2000)
    highlightFrame:Hide()
    
    local top = highlightFrame:CreateTexture(nil, "OVERLAY")
    top:SetColorTexture(1, 1, 0, 1)
    highlightFrame.top = top

    local bottom = highlightFrame:CreateTexture(nil, "OVERLAY")
    bottom:SetColorTexture(1, 1, 0, 1)
    highlightFrame.bottom = bottom

    local left = highlightFrame:CreateTexture(nil, "OVERLAY")
    left:SetColorTexture(1, 1, 0, 1)
    highlightFrame.left = left

    local right = highlightFrame:CreateTexture(nil, "OVERLAY")
    right:SetColorTexture(1, 1, 0, 1)
    highlightFrame.right = right

    -- Indicator pointing down to the location
    indicatorFrame = CreateFrame("Frame", "EasyFindMapIndicator", highlightFrame)
    indicatorFrame:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    indicatorFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 2)
    ns.CreateIndicatorTextures(indicatorFrame)
    
    local animGroup = highlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0.4)
    alpha:SetDuration(0.5)
    highlightFrame.animGroup = animGroup
    
    -- Indicator bob animation
    local indAnimGroup = indicatorFrame:CreateAnimationGroup()
    indAnimGroup:SetLooping("BOUNCE")
    local indMove = indAnimGroup:CreateAnimation("Translation")
    indMove:SetOffset(0, -10)
    indMove:SetDuration(0.4)
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
            local playerMapID = C_Map.GetBestMapForUnit("player")
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
            local playerMapID = C_Map.GetBestMapForUnit("player")
            local viewingMapID = WorldMapFrame:GetMapID()
            if viewingMapID and playerMapID == viewingMapID then
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(viewingMapID, self.waypointX, self.waypointY))
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                efPlacedWaypoint = true
                cachedWPMapID = viewingMapID
                cachedWPx = self.waypointX
                cachedWPy = self.waypointY
                ShowSuperTrackGlow()
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
    glow:SetTexture("Interface\\Cooldown\\star4")
    glow:SetVertexColor(1, 1, 0, 0.8)
    glow:SetBlendMode("ADD")
    waypointPin.glow = glow
    
    -- Animation for the location pin glow
    local pinAnimGroup = waypointPin:CreateAnimationGroup()
    pinAnimGroup:SetLooping("BOUNCE")
    local pinPulse = pinAnimGroup:CreateAnimation("Alpha")
    pinPulse:SetFromAlpha(1)
    pinPulse:SetToAlpha(0.3)
    pinPulse:SetDuration(0.4)
    waypointPin.animGroup = pinAnimGroup

end

function MapSearch:CreateZoneHighlightFrame()
    -- Frame to overlay and highlight zones on continent maps
    zoneHighlightFrame = CreateFrame("Frame", "EasyFindZoneHighlight", WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:SetFrameStrata("TOOLTIP")  -- High strata to be visible
    zoneHighlightFrame:SetFrameLevel(400)
    zoneHighlightFrame:SetAllPoints(WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:Hide()
    
    -- Store references to zone highlight textures
    zoneHighlightFrame.highlights = {}
    
    -- Create a pool of highlight textures we can reuse (ALWAYS YELLOW)
    for i = 1, 10 do
        local highlight = zoneHighlightFrame:CreateTexture("EasyFindZoneHighlight"..i, "OVERLAY")
        highlight:SetColorTexture(1, 1, 0, 0.5)
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
    alpha:SetDuration(0.5)
    zoneHighlightFrame.animGroup = animGroup
    
    -- Create indicator for zone highlighting
    local zoneInd = CreateFrame("Frame", "EasyFindZoneIndicator", WorldMapFrame.ScrollContainer.Child)
    zoneInd:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    zoneInd:SetFrameStrata("TOOLTIP")
    zoneInd:SetFrameLevel(500)
    ns.CreateIndicatorTextures(zoneInd)

    local zoneIndAnimGroup = zoneInd:CreateAnimationGroup()
    zoneIndAnimGroup:SetLooping("BOUNCE")
    local zoneIndMove = zoneIndAnimGroup:CreateAnimation("Translation")
    zoneIndMove:SetOffset(0, -10)
    zoneIndMove:SetDuration(0.4)
    zoneInd.animGroup = zoneIndAnimGroup
    zoneInd.translateAnim = zoneIndMove

    zoneInd:Hide()
    zoneHighlightFrame.indicator = zoneInd
end

-- Get direct child zones only (1 level deep) for local search
function MapSearch:GetDirectChildZones(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    
    local zones = {}
    local seen = {}
    
    -- Get all direct children (not recursive)
    local children = C_Map.GetMapChildrenInfo(mapID, nil, false)  -- false = not recursive
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
        local mapInfo = C_Map.GetMapInfo(currentID)
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
    local maxDepth = 6  -- Limit recursion depth
    
    if depth > maxDepth then return allZones end
    
    local children = C_Map.GetMapChildrenInfo(startMapID, nil, false)
    if not children then return allZones end
    
    for _, child in ipairs(children) do
        if child.name then
            local parentInfo = C_Map.GetMapInfo(startMapID)
            local parentName = parentInfo and parentInfo.name or ""
            
            -- Replace "Cosmic" with "World" for display
            if parentName == "Cosmic" then
                parentName = "World"
            end
            
            -- Build the full path (copy parent path and add current parent)
            local fullPath = {}
            for _, p in ipairs(parentPath) do
                tinsert(fullPath, {mapID = p.mapID, name = p.name})
            end
            if parentName ~= "" then
                tinsert(fullPath, {mapID = startMapID, name = parentName})
            end
            
            -- Skip dungeon, micro, and orphan maps - only include navigable zones
            local mt = child.mapType
            if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                tinsert(allZones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = startMapID,
                    parentName = parentName,
                    path = fullPath,  -- Full hierarchy path
                    depth = depth
                })
                
                -- Recurse into children
                local subZones = self:GetAllWorldZones(child.mapID, depth + 1, fullPath)
                for _, subZone in ipairs(subZones) do
                    tinsert(allZones, subZone)
                end
            end
        end
    end
    
    return allZones
end

-- Parent map overrides for guided navigation
-- Some zones have incorrect parentMapID in the WoW API, causing guided navigation
-- to route through maps where the target zone isn't clickable.
-- Maps [childMapID] = correctedParentMapID
local ZONE_PARENT_OVERRIDES = {
    [2346] = 2274, -- Undermine → Khaz Algar (API incorrectly says The Ringing Deeps 2214)
}

-- Search for zones matching query
-- Common abbreviations for major cities/zones
-- Maps lowercase abbreviation → lowercase zone name
local ZONE_ABBREVIATIONS = {
    ["sw"] = "stormwind city",
    ["stormwind"] = "stormwind city",
    ["og"] = "orgrimmar",
    ["org"] = "orgrimmar",
    ["if"] = "ironforge",
    ["tb"] = "thunder bluff",
    ["uc"] = "undercity",
    ["darn"] = "darnassus",
    ["exo"] = "the exodar",
    ["smc"] = "silvermoon city",
    ["silvermoon"] = "silvermoon city",
    ["dal"] = "dalaran",
    ["bb"] = "booty bay",
    ["sh"] = "shattrath city",
    ["shatt"] = "shattrath city",
    ["shat"] = "shattrath city",
    ["daz"] = "dazar'alor",
    ["bor"] = "boralus",
    ["orib"] = "oribos",
    ["vald"] = "valdrakken",
    ["zand"] = "zandalar",
    ["kt"] = "kul tiras",
    ["ek"] = "eastern kingdoms",
    ["kali"] = "kalimdor",
    ["dk"] = "acherus: the ebon hold",
}

function MapSearch:SearchZones(query)
    if not query or query == "" then return {} end
    
    query = slower(query)
    local zones
    
    if isGlobalSearch then
        -- Global: search entire world starting from Cosmic (946)
        -- We need to include the "World" level in all paths
        local worldPath = {{mapID = 946, name = "World"}}
        
        zones = {}
        
        -- Get all children of Cosmic (946) - this includes Azeroth, Outland, Draenor, etc.
        local cosmicChildren = C_Map.GetMapChildrenInfo(946, nil, false)
        if cosmicChildren then
            for _, child in ipairs(cosmicChildren) do
                if child.name then
                    -- Include the world itself (Azeroth, Outland, Draenor, Shadowlands)
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
    else
        -- Local: only direct children of current map
        zones = self:GetDirectChildZones()
    end
    
    local matches = {}
    local abbrevTarget = ZONE_ABBREVIATIONS[query]  -- check once outside loop
    
    for _, zone in ipairs(zones) do
        local nameLower = slower(zone.name)
        local score = ns.Database:ScoreName(nameLower, query, #query)
        
        -- Check abbreviation match (e.g. "sw" → "stormwind city")
        if abbrevTarget and nameLower == abbrevTarget then
            score = mmax(score, 200)  -- Treat as exact match
        end
        
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
    
    return matches
end

-- Group zone matches by their FULL parent path for clean display
-- ONLY groups zones when multiple search results share the EXACT SAME parent path
function MapSearch:GroupZonesByParent(zones)
    -- Build a path string key for each zone's parent
    local function getPathKey(zone)
        if zone.path and #zone.path > 0 then
            local parts = {}
            for _, p in ipairs(zone.path) do
                tinsert(parts, tostring(p.mapID))
            end
            return tconcat(parts, ">")
        end
        return tostring(zone.parentMapID or 0)
    end
    
    local function getPathDisplay(zone)
        if zone.path and #zone.path > 0 then
            local parts = {}
            for _, p in ipairs(zone.path) do
                tinsert(parts, p.name)
            end
            return tconcat(parts, " > ")
        end
        return zone.parentName or ""
    end
    
    -- First pass: count how many zones share each full parent path
    local pathCounts = {}
    local pathDisplay = {}
    local pathParentMapID = {}
    
    for _, zone in ipairs(zones) do
        local pathKey = getPathKey(zone)
        pathCounts[pathKey] = (pathCounts[pathKey] or 0) + 1
        if not pathDisplay[pathKey] then
            pathDisplay[pathKey] = getPathDisplay(zone)
            -- Get the last mapID in the path for navigation
            if zone.path and #zone.path > 0 then
                pathParentMapID[pathKey] = zone.path[#zone.path].mapID
            else
                pathParentMapID[pathKey] = zone.parentMapID
            end
        end
    end
    
    -- Second pass: build result list
    local result = {}
    local processedPaths = {}
    
    for _, zone in ipairs(zones) do
        local pathKey = getPathKey(zone)
        
        if processedPaths[pathKey] then
            -- Already processed this path group, skip
        else
            processedPaths[pathKey] = true
            
            -- Collect all zones with this same parent path
            local groupZones = {}
            for _, z in ipairs(zones) do
                if getPathKey(z) == pathKey then
                    tinsert(groupZones, z)
                end
            end
            
            -- Sort zones within the group alphabetically
            tsort(groupZones, function(a, b)
                return a.name < b.name
            end)
            
            -- Only create a grouped header if there are 2+ zones with the same parent
            local isGrouped = #groupZones >= 2
            
            tinsert(result, {
                parentMapID = pathParentMapID[pathKey],
                parentPath = pathDisplay[pathKey],
                zones = groupZones,
                isGrouped = isGrouped
            })
        end
    end
    
    -- Sort groups by their parent path alphabetically so related items appear together
    tsort(result, function(a, b)
        return (a.parentPath or "") < (b.parentPath or "")
    end)
    
    return result
end

-- Walk up the parent chain to find the continent a map belongs to
local function GetContinentForMap(mapID)
    local id = mapID
    for i = 1, 10 do
        local info = C_Map.GetMapInfo(id)
        if not info then return nil end
        if info.mapType == Enum.UIMapType.Continent then return id end
        id = ZONE_PARENT_OVERRIDES[id] or info.parentMapID
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

    local ok1, tL, tR, tT, tB = pcall(C_Map.GetMapRectOnMap, mapID, c1)
    local ok2, vL, vR, vT, vB = pcall(C_Map.GetMapRectOnMap, viewMapID, c1)
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
            local info = C_Map.GetMapInfoAtPosition(viewMapID, x, y)
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
            local info = C_Map.GetMapInfoAtPosition(parentMapID, px, py)
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
    
    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo then 
        DebugPrint("[EasyFind] HighlightZone: no mapInfo for", mapID)
        return 
    end
    DebugPrint("[EasyFind] HighlightZone: zone name:", mapInfo.name, "mapType:", mapInfo.mapType)

    local parentMapID = WorldMapFrame:GetMapID()
    if not parentMapID then return end

    local isZone = mapInfo.mapType == Enum.UIMapType.Zone

    local success, left, right, top, bottom = pcall(function()
        return C_Map.GetMapRectOnMap(mapID, parentMapID)
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
            WorldMapFrame:SetMapID(mapID)
            return
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
            C_Map.GetMapHighlightInfoAtPosition(parentMapID, centerX, centerY)
    end)

    local highlight = zoneHighlightFrame.highlights[1]
    if not highlight then return end
    highlight:ClearAllPoints()

    -- Zone-type targets on continent maps may sit inside another zone
    -- (e.g. Ironforge inside Dun Morogh). If a surrounding zone appears on
    -- 2+ sides, redirect to it before even checking highlight textures.
    if isZone then
        local parentMapInfo = C_Map.GetMapInfo(parentMapID)
        if parentMapInfo and parentMapInfo.mapType == Enum.UIMapType.Continent then
            local containingZone = C_Map.GetMapInfoAtPosition(parentMapID, centerX, centerY)
            if containingZone and containingZone.mapID ~= mapID then
                self.pendingZoneHighlight = mapID
                self:HighlightZone(containingZone.mapID)
                return
            end
            local surrounding = FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, 2)
            if surrounding then
                self.pendingZoneHighlight = mapID
                self:HighlightZone(surrounding.mapID)
                return
            end
        end
    end

    local hasTexture = highlightSuccess and posX and posY and texPercentX and texPercentY
        and ((fileDataID and fileDataID > 0) or (atlasID and atlasID ~= ""))
    if hasTexture and isZone then
        local resolvedInfo = C_Map.GetMapInfoAtPosition(parentMapID, centerX, centerY)
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
                    hl:SetVertexColor(1, 1, 0, 1)
                else
                    hl:SetAtlas(atlasID, true)
                    hl:SetPoint("CENTER", canvas, "TOPLEFT", zoneCenterPxX, -zoneCenterPxY)
                    hl:SetVertexColor(1, 1, 0, 0.6)
                end
                hl:SetBlendMode("ADD")
                hl:Show()
            end
        end
    else
        if isZone then
            local parentMapInfo = C_Map.GetMapInfo(parentMapID)

            -- On continent: the strict (2+) check above missed this city
            -- (e.g. Stormwind where only 1 probe hits Elwynn). Try again
            -- accepting any single surrounding zone.
            if parentMapInfo and parentMapInfo.mapType == Enum.UIMapType.Continent then
                local surrounding = FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, 1)
                if surrounding then
                    self.pendingZoneHighlight = mapID
                    self:HighlightZone(surrounding.mapID)
                    return
                end
            end

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

        -- Final fallback - border outline + translucent fill
        local borderW = 2
        highlight:SetColorTexture(1, 1, 0, 0.15)
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
                hl:SetColorTexture(1, 1, 0, 0.8)
                hl:SetBlendMode("BLEND")
                hl:SetPoint(e[1], canvas, e[2], e[3], e[4])
                hl:SetSize(e[5], e[6])
                hl:Show()
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
        local userScale = EasyFind.db.iconScale or 1.0
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

function MapSearch:ClearZoneHighlight()
    if not zoneHighlightFrame then return end
    
    for _, highlight in ipairs(zoneHighlightFrame.highlights) do
        highlight:Hide()
    end
    
    if zoneHighlightFrame.border then
        for _, border in pairs(zoneHighlightFrame.border) do
            border:Hide()
        end
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
    
    local targetInfo = C_Map.GetMapInfo(targetMapID)
    if not targetInfo then 
        DebugPrint("[EasyFind] ERROR: No targetInfo for mapID", targetMapID)
        return 
    end
    
    DebugPrint("[EasyFind] Target zone:", targetInfo.name)
    
    local targetParentMapID = ZONE_PARENT_OVERRIDES[targetMapID] or targetInfo.parentMapID
    if not targetParentMapID then
        DebugPrint("[EasyFind] No parent, going directly to zone")
        WorldMapFrame:SetMapID(targetMapID)
        return
    end
    
    if ZONE_PARENT_OVERRIDES[targetMapID] then
        DebugPrint("[EasyFind] Using parent override for", targetMapID, "→", targetParentMapID)
    end
    
    local targetParentInfo = C_Map.GetMapInfo(targetParentMapID)
    DebugPrint("[EasyFind] Target parent:", targetParentInfo and targetParentInfo.name or "nil", "ID:", targetParentMapID)
    
    local currentMapID = WorldMapFrame:GetMapID()
    if not currentMapID then 
        DebugPrint("[EasyFind] ERROR: No currentMapID")
        return 
    end
    
    local currentInfo = C_Map.GetMapInfo(currentMapID)
    DebugPrint("[EasyFind] Current map:", currentInfo and currentInfo.name or "nil", "ID:", currentMapID)
    
    -- CASE 1: We're already on the target's parent map - just highlight the zone!
    if currentMapID == targetParentMapID then
        DebugPrint("[EasyFind] CASE 1: Already on target parent, highlighting zone")
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
                local resolved = C_Map.GetMapInfoAtPosition(currentMapID, cX, cY)
                if resolved and resolved.mapID == targetMapID then
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
    
    local dcaInfo = dcaMapID and C_Map.GetMapInfo(dcaMapID)
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
            local nextStepInfo = C_Map.GetMapInfo(nextStepMapID)
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
    local path = {}
    local currentID = mapID
    local maxDepth = 15
    
    while currentID and maxDepth > 0 do
        local info = C_Map.GetMapInfo(currentID)
        if info then
            tinsert(path, 1, {mapID = currentID, name = info.name, mapType = info.mapType})
            currentID = ZONE_PARENT_OVERRIDES[currentID] or info.parentMapID
        else
            break
        end
        maxDepth = maxDepth - 1
    end
    
    return path
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
        -- No exact breadcrumb found - try to highlight any visible breadcrumb
        -- that helps the user navigate upward (avoid auto-navigating in teaching mode)
        DebugPrint("[EasyFind] No button found, looking for any visible breadcrumb")
        local fallbackButton = nil
        local navChildren = {navBar:GetChildren()}
        for i = 1, #navChildren do
            local child = navChildren[i]
            if child and child:IsShown() and child.GetText and child:GetText() then
                fallbackButton = child
                break  -- take the leftmost (highest ancestor) visible button
            end
        end
        if fallbackButton then
            DebugPrint("[EasyFind] Using fallback breadcrumb:", fallbackButton.GetText and fallbackButton:GetText() or "?")
            self.pendingZoneHighlight = finalTargetMapID
            self:ShowBreadcrumbHighlight(fallbackButton, finalTargetMapID)
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
    
    -- Check home button (usually Azeroth or World)
    if navBar.home and navBar.home:IsShown() then
        local homeMapID = navBar.home.id
        DebugPrint("[EasyFind] Home button ID:", homeMapID)
        if homeMapID == mapID then
            return navBar.home
        end
    else
        DebugPrint("[EasyFind] No home button or not shown")
    end
    
    -- Last resort: look for WorldMapNavBarButton frames
    local buttonName = "WorldMapNavBarButton"
    for i = 1, 10 do
        local btn = _G[buttonName .. i]
        if btn and btn:IsShown() and btn.data and btn.data.id == mapID then
            DebugPrint("[EasyFind] Found via global name:", buttonName .. i)
            return btn
        end
    end

    -- Text-based fallback: match button text to the map name
    local targetName = C_Map.GetMapInfo(mapID)
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
            g:SetVertexColor(1, 0.82, 0, 1)
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
        bcMove:SetDuration(0.4)
        bcIndFrame.animGroup = bcAnimGroup

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
        hlTex:SetVertexColor(1, 0.82, 0, 1)
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
        hl.indicatorFrame:Show()
        if hl.indicatorFrame.animGroup then
            hl.indicatorFrame.animGroup:Play()
        end
    end

    self.pendingZoneHighlight = finalTargetMapID
    DebugPrint("[EasyFind] ShowBreadcrumbHighlight - SET pendingZoneHighlight to:", finalTargetMapID)
end

-- Check if current map is a continent (has zone children)
function MapSearch:IsOnContinentMap()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return false end
    
    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo then return false end
    
    -- Continent type is 2, World is 1
    return mapInfo.mapType == Enum.UIMapType.Continent or mapInfo.mapType == Enum.UIMapType.World
end

function MapSearch:HookWorldMap()
    WorldMapFrame:HookScript("OnShow", function()
        searchFrame:Show()
        globalSearchFrame:Show()
        -- Restore pins only if the player is in the pin's zone.
        -- Map opens to the player's current zone by default, so if they
        -- left the zone the pin was in, it's gone.
        if activePinState then
            local currentMapID = WorldMapFrame:GetMapID()
            local playerMapID = C_Map.GetBestMapForUnit("player")
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
    end)

    WorldMapFrame:HookScript("OnHide", function()
        searchFrame:Hide()
        globalSearchFrame:Hide()
        if searchFrame.filterDropdown then
            searchFrame.filterDropdown:Hide()
        end
        if globalSearchFrame.filterDropdown then
            globalSearchFrame.filterDropdown:Hide()
        end
        self:HideResults()
        -- Hide ALL high-strata visuals that paint through the closed map.
        -- activePinState is preserved so they restore on reopen.
        self:ClearHighlight()
        self:ClearZoneHighlight()
        self.pendingWaypoint = nil
    end)
    
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        local newMapID = WorldMapFrame:GetMapID()
        local newMapInfo = newMapID and C_Map.GetMapInfo(newMapID)
        DebugPrint("[EasyFind] OnMapChanged - new map:", newMapInfo and newMapInfo.name or "nil", "ID:", newMapID)
        DebugPrint("[EasyFind] OnMapChanged - pendingZoneHighlight:", self.pendingZoneHighlight)

        -- Snapshot pendingZoneHighlight BEFORE clearing.
        -- pendingWaypoint is NOT wiped by ClearZoneHighlight so no snapshot needed.
        local savedPendingZone = self.pendingZoneHighlight

        self:HideResults()
        self:ClearHighlight()
        self:ClearZoneHighlight()  -- Explicit clear - SetText below may not reliably fire OnTextChanged inside hooksecurefunc

        -- Clear breadcrumb highlight
        if self.breadcrumbHighlight then
            self.breadcrumbHighlight:Hide()
        end

        -- Clear both search bars on map change
        searchFrame.editBox:SetText("")
        searchFrame.editBox.placeholder:Show()
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox.placeholder:Show()
        end

        -- If we have both a pending zone AND a pending waypoint, check if the
        -- entrance is actually visible on the current map via the Encounter Journal
        -- API. This handles sub-zones (e.g. "City of Threads - Lower" inside
        -- Azj-Kahet) where the entrance pin is visible on the parent zone map
        -- but not on the continent map.
        if savedPendingZone and self.pendingWaypoint and self.pendingWaypoint.mapID then
            local wp = self.pendingWaypoint
            local currentMapID = WorldMapFrame:GetMapID()
            if wp.mapID ~= currentMapID and C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap then
                local entrances = C_EncounterJournal.GetDungeonEntrancesForMap(currentMapID)
                if entrances then
                    for _, entrance in ipairs(entrances) do
                        if entrance.name and entrance.position then
                            -- Match by proximity - entrance coords are in current map space
                            -- Use GetMapRectOnMap to project wp coords to current map for comparison
                            local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, wp.mapID, currentMapID)
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
            if newMapID == savedPendingZone then
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
        end
    end)
end

function MapSearch:GetCategoryMatch(query)
    query = slower(query)
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
        local children = C_Map.GetMapChildrenInfo(parentID, nil, false)
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
function MapSearch:ScanDungeonEntrances(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not C_EncounterJournal or not C_EncounterJournal.GetDungeonEntrancesForMap then return {} end

    local results = {}
    local seen = {}  -- dedup by entrance name
    local mapInfo = C_Map.GetMapInfo(mapID)
    local parentInfo = mapInfo and mapInfo.parentMapID and C_Map.GetMapInfo(mapInfo.parentMapID)
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
        ok, zL, zR, zT, zB = pcall(C_Map.GetMapRectOnMap, mapID, continentID)
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
        tinsert(results, {
            name = entrance.name,
            category = cat,
            icon = nil,  -- use category icon
            isStatic = true,
            isDungeonEntrance = true,
            entranceMapID = mapID,
            x = ex,
            y = ey,
            pathPrefix = parentLabel,
            keywords = {cat, "instance", "entrance", "portal"},
        })
    end

    -- Pass 1: scan the zone directly; exclude entrances owned by a different zone
    local zoneEntrances = C_EncounterJournal.GetDungeonEntrancesForMap(mapID)
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
        local contEntrances = C_EncounterJournal.GetDungeonEntrancesForMap(continentID)
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
        local children = C_Map.GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end
        for _, child in ipairs(children) do
            -- Dungeon entrances from the encounter journal
            local entrances = self:ScanDungeonEntrances(child.mapID)
            for _, e in ipairs(entrances) do
                local key = e.name .. "|" .. child.mapID
                if not seen[key] then
                    seen[key] = true
                    local nameKey = slower(e.name)
                    if not nameSeen[nameKey] then
                        nameSeen[nameKey] = true
                        tinsert(globalInstanceCache, e)
                    end
                end
            end

            -- Static locations with whitelisted categories (e.g. future delve POIs)
            local locs = STATIC_LOCATIONS[child.mapID]
            if locs then
                local mapInfo = C_Map.GetMapInfo(child.mapID)
                local mapName = mapInfo and mapInfo.name or ""
                for _, loc in ipairs(locs) do
                    if GLOBAL_SEARCH_CATEGORIES[loc.category] then
                        local skey = loc.name .. "|" .. child.mapID
                        if not seen[skey] then
                            seen[skey] = true
                            local nameKey = slower(loc.name)
                            if not nameSeen[nameKey] then
                                nameSeen[nameKey] = true
                                tinsert(globalInstanceCache, {
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
                                })
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
    local fmMapInfo = C_Map.GetMapInfo(mapID)
    local fmParentInfo = fmMapInfo and fmMapInfo.parentMapID and C_Map.GetMapInfo(fmMapInfo.parentMapID)
    local fmShouldFilter = fmParentInfo and fmParentInfo.mapType == Enum.UIMapType.Continent

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
                                        if fmShouldFilter then
                                                local posInfo = C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(mapID, x, y)
                                                fmInclude = posInfo and (posInfo.mapID == mapID or posInfo.parentMapID == mapID)
                                        end
                                        if fmInclude then
                    tinsert(results, {
                        name = node.name .. " (Flight Master)",
                        category = "flightmaster",
                        icon = "atlas:TaxiNode_Neutral",
                        isStatic = true,
                        x = x,
                        y = y,
                        keywords = {"flight", "fly", "taxi", "fp", "flight master"},
                    })
                    end
                end
            end
        end
    end
    return results
end

-- Scan flight masters across ALL zone-type maps for global search
-- Results are cached since flight point positions don't change mid-session
local cachedAllFlightMasters = nil

function MapSearch:ScanAllFlightMasters()
    if cachedAllFlightMasters then return cachedAllFlightMasters end
    if not C_TaxiMap or not C_TaxiMap.GetTaxiNodesForMap then return {} end

    local allNodes = {}
    local seen = {}

    local function collectFromMaps(parentMapID, depth)
        if depth > 6 then return end
        local children = C_Map.GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end

        for _, child in ipairs(children) do
            if child.name then
                local mt = child.mapType
                if mt == Enum.UIMapType.Zone or mt == Enum.UIMapType.Continent then
                    local nodes = self:ScanFlightMasters(child.mapID)
                    for _, node in ipairs(nodes) do
                        local key = node.name .. "|" .. child.mapID
                        if not seen[key] then
                            seen[key] = true
                            -- Add zone path prefix like dungeon entrances do
                            local mapInfo = C_Map.GetMapInfo(child.mapID)
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

    local cosmicChildren = C_Map.GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            collectFromMaps(child.mapID, 0)
        end
    end

    cachedAllFlightMasters = allNodes
    return allNodes
end

-- Scan dungeon entrances across ALL zone-type maps for global search.
-- Results are cached since instance discovery doesn't change mid-session.
local cachedAllDungeonEntrances = nil

function MapSearch:ScanAllDungeonEntrances()
    if cachedAllDungeonEntrances then return cachedAllDungeonEntrances end
    if not C_EncounterJournal or not C_EncounterJournal.GetDungeonEntrancesForMap then return {} end
    
    local allEntrances = {}
    local seen = {}  -- Deduplicate by instance name + map
    
    -- Walk the full world tree collecting zone-type maps
    local function collectZoneMaps(parentMapID, depth)
        if depth > 6 then return end
        local children = C_Map.GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end
        
        for _, child in ipairs(children) do
            if child.name then
                local mt = child.mapType
                -- Only scan Zone and Continent maps for dungeon entrances
                if mt == Enum.UIMapType.Zone or mt == Enum.UIMapType.Continent then
                    local entrances = self:ScanDungeonEntrances(child.mapID)
                    for _, e in ipairs(entrances) do
                        local key = e.name .. "|" .. child.mapID
                        if not seen[key] then
                            seen[key] = true
                            tinsert(allEntrances, e)
                        end
                    end
                end
                -- Recurse into children (skip Dungeon/Micro/Orphan)
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    collectZoneMaps(child.mapID, depth + 1)
                end
            end
        end
    end
    
    -- Start from Cosmic → all worlds
    local cosmicChildren = C_Map.GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            collectZoneMaps(child.mapID, 0)
        end
    end
    
    cachedAllDungeonEntrances = allEntrances
    return allEntrances
end

function MapSearch:GetStaticLocations()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return {} end
    
    local results = {}
    
    -- Get built-in static locations
    local locations = STATIC_LOCATIONS[mapID]
    if locations then
        for _, loc in ipairs(locations) do
            tinsert(results, {
                name = loc.name,
                category = loc.category,
                icon = loc.icon,  -- nil is fine, GetCategoryIcon will handle it
                isStatic = true,
                x = loc.x,
                y = loc.y,
                keywords = loc.keywords,
            })
        end
    end
    
    -- Also check EasyFindDevDB for dev/testing (raw POIs from recorder)
    -- Skip dev POIs whose names already exist in built-in static locations
    if EasyFindDevDB and EasyFindDevDB.rawPOIs then
        local staticNames = {}
        if locations then
            for _, loc in ipairs(locations) do
                staticNames[slower(loc.name)] = true
            end
        end
        for _, poi in ipairs(EasyFindDevDB.rawPOIs) do
            if poi.mapID == mapID and not staticNames[slower(poi.label or "")] then
                tinsert(results, {
                    name = poi.label,
                    category = poi.category or "unknown",
                    icon = nil,  -- Let category icon be used
                    isStatic = true,
                    x = poi.x,
                    y = poi.y,
                    keywords = {},
                })
            end
        end
    end
    
    return results
end

function MapSearch:ScanMapPOIs()
    local pois = {}
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return pois end
    
    local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if not canvas then return pois end
    
    -- First: Use WoW's API to get Area POIs directly (boats, zeppelins, portals, etc)
    -- Only include POIs we can categorize as useful (travel, services)
    -- Skip generic area POIs like landmarks, zone markers, events
    local areaPOIs = C_AreaPoiInfo.GetAreaPOIForMap(mapID)
    if areaPOIs then
        for _, poiID in ipairs(areaPOIs) do
            local poiInfo = C_AreaPoiInfo.GetAreaPOIInfo(mapID, poiID)
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
                elseif sfind(poiName, "conquest") or sfind(poiName, "honor") or sfind(poiName, "pvp") or sfind(poiName, "quartermaster") then
                    category = "pvpvendor"
                elseif sfind(poiName, "chromie") then
                    category = "chromie"
                end
                
                -- Only add POIs we've explicitly categorized (skips generic landmarks, zone markers, events, etc.)
                if category then
                    tinsert(pois, {
                        name = poiInfo.name,
                        pin = nil,  -- API-based, no pin reference
                        pinType = category,
                        category = category,
                        icon = nil,  -- Use category icon, not textureIndex (which is an atlas)
                        isStatic = true,
                        x = poiInfo.position.x,
                        y = poiInfo.position.y,
                    })
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
    
    return pois
end

function MapSearch:GetPinInfo(pin)
    if not pin or not pin:IsShown() then return nil end
    
    local name = nil
    local icon = nil
    local pinType = "unknown"
    local category = nil
    
    -- Flight masters - handled by ScanFlightMasters() with proper zone filtering
    if pin.taxiNodeData then
        return nil
    end
    
    -- Area POIs (boats, zeppelins, portals, etc) - but NOT quests
    if pin.areaPoiInfo then
        name = pin.areaPoiInfo.name or pin.areaPoiInfo.description
        pinType = "areapoi"
        
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
        else
            -- Generic area POI - skip it (these are usually landmarks, events, etc.)
            return nil
        end
    end
    
    -- Vignettes (rares, treasures)
    if pin.vignetteInfo then
        name = pin.vignetteInfo.name
        pinType = "vignette"
        category = "rare"
        if pin.vignetteInfo.vignetteType == 2 then
            category = "treasure"
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
    
    -- Scan pin regions for atlas-based icons (shows the real map pin icon)
    -- Also used to identify unknown pin types by their atlas name
    local skipAtlas = { ["Waypoint-MapPin-Tracked"] = true, ["Waypoint-MapPin-Untracked"] = true, ["UI-QuestPoi-OuterGlow"] = true }
    -- Atlas names that identify specific known pin types when other data fields are absent
    local atlasPinTypes = {
        ["ChromieTime-32x32"] = { name = "Chromie", category = "chromie" },
    }
    do
        for _, region in pairs({pin:GetRegions()}) do
            if region.GetAtlas then
                local atlas = region:GetAtlas()
                if atlas and atlas ~= "" and not skipAtlas[atlas] then
                    local layer = region:GetDrawLayer()
                    if layer == "ARTWORK" then
                        if not icon then
                            icon = "atlas:" .. atlas
                        end
                        if not name then
                            local known = atlasPinTypes[atlas]
                            if known then
                                name     = known.name
                                category = known.category
                                pinType  = known.category
                            end
                        end
                    end
                end
            end
        end
    end

    -- Fallback raw texture scan (only if atlas scan found nothing)
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
    
    if not name or name == "" then
        return nil
    end

    -- Filter out pins from adjacent zones (visible on map but not in focused zone)
    local mapID = WorldMapFrame:GetMapID()
    if mapID and name then
        local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
        if canvas then
            local cW, cH = canvas:GetSize()
            if cW > 0 and cH > 0 then
                local pX, pY = pin:GetCenter()
                local cX, cY = canvas:GetLeft(), canvas:GetTop()
                if pX and pY and cX and cY then
                    local normX = (pX - cX) / cW
                    local normY = (cY - pY) / cH
                    local posInfo = C_Map.GetMapInfoAtPosition and C_Map.GetMapInfoAtPosition(mapID, normX, normY)
                    -- Only reject if the API confidently returns a DIFFERENT zone.
                    -- nil means unmapped (new pin types, borders) - keep as benefit of the doubt.
                    if posInfo and posInfo.mapID ~= mapID and posInfo.parentMapID ~= mapID then
                        return nil  -- belongs to adjacent zone
                    end
                end
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
    }
end

function MapSearch:OnSearchTextChanged(text)
    if not text or text == "" or #text < 2 then
        self:ClearHighlight()
        self:ClearZoneHighlight()
        -- Show pinned items only if search bar still has focus
        local editBox = activeSearchFrame and activeSearchFrame.editBox
        if text == "" and editBox and editBox:HasFocus() then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end
    
    -- Clear any previous zone highlights and POI highlights
    self:ClearZoneHighlight()
    self:ClearHighlight()
    
    -- Search for zones (works for both local and global mode)
    local zoneMatches = {}
    if self:IsOnContinentMap() or isGlobalSearch then
        zoneMatches = self:SearchZones(text)
        -- Don't auto-highlight - only highlight when user clicks a result
    end

    local allPOIs = {}

    -- Group zone matches by parent for clean display
    local groupedZones = self:GroupZonesByParent(zoneMatches)

    -- Add zone results - simple flat list with full path
    local zoneNames = {}  -- Track zone names to avoid duplicate POI entries

    for _, group in ipairs(groupedZones) do
        local zonesInGroup = group.zones
        local parentPath = group.parentPath

        for _, zone in ipairs(zonesInGroup) do
            zoneNames[slower(zone.name)] = true
            tinsert(allPOIs, {
                name = zone.name,
                category = "zone",
                icon = 237382,
                isZone = true,
                zoneMapID = zone.mapID,
                pathPrefix = parentPath,
                score = zone.score + 200,
            })
        end
    end

    -- Global search: zones + dungeon/raid/delve entrances (skip service POIs)
    if isGlobalSearch then
        local instancePOIs = self:GetGlobalInstanceCache()
        -- Build entrance lookup so zone results that match a dungeon/raid entrance
        -- get enriched with coordinates for the final waypoint highlight
        local entranceLookup = {}
        for _, poi in ipairs(instancePOIs) do
            if poi.isDungeonEntrance and poi.x and poi.y then
                entranceLookup[slower(poi.name)] = poi
            end
            if not zoneNames[slower(poi.name)] then
                tinsert(allPOIs, poi)
            end
        end
        -- Enrich zone results with entrance data
        for _, poi in ipairs(allPOIs) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[slower(poi.name)]
                if entrance then
                    poi.entranceX = entrance.x
                    poi.entranceY = entrance.y
                    poi.entranceMapID = entrance.entranceMapID
                    poi.entranceIcon = entrance.icon
                    poi.entranceCategory = entrance.category
                end
            end
        end
    else
        -- Get both dynamic pins and static locations for current map
        local dynamicPOIs = self:ScanMapPOIs()
        local staticLocations = self:GetStaticLocations()

        -- Get dungeon/raid entrance locations for current map
        local dungeonEntrances = self:ScanDungeonEntrances()

        -- Get flight master locations for current map
        local flightMasters = self:ScanFlightMasters()

        -- Coordinate-based sources first (dungeon entrances, flight masters) so they
        -- take priority over pin-only entries from ScanMapPOIs during deduplication.
        -- Pin-only entries lack x/y and go through HighlightPin (no icon), while
        -- coordinate entries go through ShowWaypointAt (full icon + glow + arrow).
        local existingNames = {}

        -- Build entrance lookup for zone result enrichment
        local entranceLookup = {}
        for _, entrance in ipairs(dungeonEntrances) do
            if entrance.isDungeonEntrance and entrance.x and entrance.y then
                entranceLookup[slower(entrance.name)] = entrance
            end
            if not zoneNames[slower(entrance.name)] then
                tinsert(allPOIs, entrance)
                existingNames[slower(entrance.name)] = true
            end
        end
        -- Enrich zone results with entrance data
        for _, poi in ipairs(allPOIs) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[slower(poi.name)]
                if entrance then
                    poi.entranceX = entrance.x
                    poi.entranceY = entrance.y
                    poi.entranceMapID = entrance.entranceMapID
                    poi.entranceIcon = entrance.icon
                    poi.entranceCategory = entrance.category
                end
            end
        end

        for _, fm in ipairs(flightMasters) do
            if not zoneNames[slower(fm.name)] and not existingNames[slower(fm.name)] then
                tinsert(allPOIs, fm)
                existingNames[slower(fm.name)] = true
            end
        end

        -- Dynamic pins and static locations added after, skipping duplicates
        for _, poi in ipairs(dynamicPOIs) do
            if not zoneNames[slower(poi.name)] and not existingNames[slower(poi.name)] then
                tinsert(allPOIs, poi)
                existingNames[slower(poi.name)] = true
            end
        end
        for _, loc in ipairs(staticLocations) do
            if not zoneNames[slower(loc.name)] and not existingNames[slower(loc.name)] then
                tinsert(allPOIs, loc)
                existingNames[slower(loc.name)] = true
            end
        end
    end
    
    local results = self:SearchPOIs(allPOIs, text)

    -- Apply global search filters (zones / dungeons / raids / delves)
    if isGlobalSearch then
        local filters = EasyFind.db.globalSearchFilters
        local filteredResults = {}
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
        local filteredResults = {}
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
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    end

    -- Prepend pinned items (always shown at top regardless of query)
    local pins = EasyFind.db.pinnedMapItems
    if pins and #pins > 0 then
        local pinnedKeys = {}
        local pinned = {}
        for _, pin in ipairs(pins) do
            local copy = {}
            for k, v in pairs(pin) do copy[k] = v end
            copy.isPinned = true
            tinsert(pinned, copy)
            pinnedKeys[GetMapPinKey(pin)] = true
        end
        -- Remove duplicates from search results that match pinned items
        local filtered = {}
        for _, r in ipairs(results) do
            if not pinnedKeys[GetMapPinKey(r)] then
                tinsert(filtered, r)
            end
        end
        -- Combine: pins first, then search results
        for _, r in ipairs(filtered) do
            tinsert(pinned, r)
        end
        results = pinned
    end

    self:ShowResults(results)
end

function MapSearch:SearchPOIs(pois, query)
    query = slower(query)
    local results = {}
    local seen = {}
    local duplicates = {}  -- Track all instances of duplicate POIs
    
    local matchedCategory, catScore, isExactCategoryMatch = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or {}
    
    -- First pass: name matches
    for _, poi in ipairs(pois) do
        local nameLower = slower(poi.name)
        local key = poi.name .. (poi.category or "")
        
        -- Zone results already scored by SearchZones - pass through directly
        local score
        if poi.isZone and poi.score then
            score = poi.score
        else
            score = ns.Database:ScoreName(nameLower, query, #query)
            
            -- Also check custom keywords for static locations
            if poi.keywords then
                -- Build lowered keywords list for shared scorer
                local kwLower = {}
                for _, kw in ipairs(poi.keywords) do
                    kwLower[#kwLower + 1] = slower(kw)
                end
                score = score + ns.Database:ScoreKeywords(kwLower, query, #query)
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
            
            if not seen[key] and poi.category then
                local score = 0
                
                -- Direct category match
                if poi.category == matchedCategory then
                    score = 150
                end
                
                -- Related category match (e.g., search "travel" shows all travel types)
                if score == 0 then
                    for _, relCat in ipairs(relatedCategories) do
                        if poi.category == relCat then
                            score = 100
                            break
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
    
    -- Attach duplicates info to results
    for _, result in ipairs(results) do
        if result.duplicateKey and duplicates[result.duplicateKey] then
            result.allInstances = duplicates[result.duplicateKey]
        end
    end
    
    -- Sort results by score
    tsort(results, function(a, b)
        -- Zone results come before POI results at equal scores
        if a.score == b.score then
            if a.isZone and not b.isZone then return true end
            if b.isZone and not a.isZone then return false end
            return (a.name or "") < (b.name or "")
        end
        return a.score > b.score
    end)
    return results
end

function MapSearch:ShowResults(results)
    if not results or #results == 0 then
        self:HideResults()
        return
    end
    
    local count = mmin(#results, MAX_RESULTS_POOL)
    local resultsAbove = EasyFind.db.mapResultsAbove

    -- Pre-compute whether scrolling will be needed so buttons can be narrower.
    -- Must compute maxVisibleHeight (including screen-space clamping) BEFORE the
    -- button loop, otherwise willScroll can be false while hasScroll ends up true
    -- and the scrollbar overlaps full-width buttons.
    local maxVisibleRows = EasyFind.db.maxResults or 10
    local scrollBar = resultsFrame.scrollBar
    local maxVisibleHeight = maxVisibleRows * 26 + 12
    local preAnchor = activeSearchFrame or searchFrame
    if isGlobalSearch and globalSearchFrame then
        preAnchor = globalSearchFrame
    end
    local screenH = UIParent:GetHeight()
    if resultsAbove then
        local available = (preAnchor:GetTop() or (screenH / 2)) - 16
        if available > 0 and maxVisibleHeight > available then
            maxVisibleHeight = available
        end
    else
        local available = (preAnchor:GetBottom() or (screenH / 2)) - 16
        if available > 0 and maxVisibleHeight > available then
            maxVisibleHeight = available
        end
    end
    local willScroll = (count * 26 + 12) > maxVisibleHeight

    -- Check if the player is in the zone being viewed (for navBtn disabled state)
    local viewedMapID = WorldMapFrame:GetMapID()
    local playerMapID = C_Map.GetBestMapForUnit("player")
    local playerInZone = viewedMapID and playerMapID and viewedMapID == playerMapID

    local yOffset = -6  -- running vertical offset (top padding)

    for i = 1, MAX_RESULTS_POOL do
        local btn = resultButtons[i]
        if i <= count then
            local data = results[i]
            btn.data = data
            
            -- Reset button state
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("LEFT", 5, 0)
            btn.text:ClearAllPoints()
            btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
            if willScroll then
                btn.text:SetPoint("RIGHT", scrollBar, "LEFT", -4, 0)
            else
                btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
            end
            btn.icon:Show()
            btn.icon:SetVertexColor(1, 1, 1)
            btn.text:SetTextColor(1, 1, 1)
            if btn.prefixText then btn.prefixText:Hide() end
            if btn.indentLine then btn.indentLine:Hide() end
            if btn.pinIcon then btn.pinIcon:Hide() end
            if btn.navBtn then btn.navBtn:Hide() end

            -- Format based on type
            if data.isZoneParent then
                -- Parent header - no icon, just gray text with arrow
                btn.icon:Hide()
                btn.text:ClearAllPoints()
                btn.text:SetPoint("LEFT", btn, "LEFT", 8, 0)
                if willScroll then
                    btn.text:SetPoint("RIGHT", scrollBar, "LEFT", -4, 0)
                else
                    btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
                end
                btn.text:SetText("|cff666666▼ " .. data.name .. "|r")

            elseif data.isZone then
                if data.isIndented then
                    -- Indented child zone - shift icon and text right
                    btn.icon:ClearAllPoints()
                    btn.icon:SetPoint("LEFT", 25, 0)  -- Indent the icon
                    btn.text:ClearAllPoints()
                    btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
                    if willScroll then
                        btn.text:SetPoint("RIGHT", scrollBar, "LEFT", -4, 0)
                    else
                        btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
                    end
                    btn.text:SetText(data.displayName or data.name)
                    btn.text:SetTextColor(1, 0.82, 0)  -- Gold
                    btn.icon:SetTexture(237382)
                    btn.icon:SetSize(16, 16)  -- Slightly smaller for children
                    btn.icon:Show()
                    -- Show vertical indent line
                    if btn.indentLine then btn.indentLine:Show() end

                elseif data.pathPrefix and data.pathPrefix ~= "" then
                    -- Global search with path - show "Path > Zone" format
                    btn.text:SetText("|cff666666" .. data.pathPrefix .. " >|r |cffffd100" .. data.name .. "|r")
                    btn.icon:SetTexture(237382)
                    btn.icon:Show()

                else
                    -- Regular zone result
                    btn.text:SetText(data.name)
                    btn.text:SetTextColor(1, 0.82, 0)  -- Gold
                    btn.icon:SetTexture(237382)
                    btn.icon:Show()
                end

            else
                -- Regular POI result
                local displayText = data.name
                -- For dungeon entrances from global search, show zone location
                if data.isDungeonEntrance and data.pathPrefix and data.pathPrefix ~= "" then
                    displayText = data.name .. " |cff666666(" .. data.pathPrefix .. ")|r"
                end
                btn.text:SetText(displayText)
                btn.text:SetTextColor(1, 1, 1)

                local iconTexture = GetCategoryIcon(data.category)
                if data.icon then
                    iconTexture = data.icon
                end
                SetIconTexture(btn.icon, iconTexture)
                btn.icon:SetSize(18, 18)
                btn.icon:Show()
            end

            -- Show navigate button only for local search results with coordinates
            local hasCoords = not isGlobalSearch
                and ((data.x and data.y) or (data.allInstances and #data.allInstances > 1))
            if hasCoords and btn.navBtn then
                btn.navBtn.texture:SetTexture(nil)
                btn.navBtn.texture:SetTexCoord(0, 1, 0, 1)
                btn.navBtn.texture:SetAtlas("Waypoint-MapPin-Untracked")
                btn.navBtn.disabled = not playerInZone
                btn.navBtn.texture:SetDesaturated(not playerInZone)
                btn.navBtn.texture:SetAlpha(1)
                btn.navBtn:Show()
                -- Adjust text right edge to make room
                btn.text:SetPoint("RIGHT", btn.navBtn, "LEFT", -2, 0)
            end

            -- Show pin indicator for pinned items
            if data.isPinned and btn.pinIcon then
                btn.pinIcon:Show()
            end

            btn:Show()

            -- Force text width so GetStringHeight accounts for wrapping on first render
            -- Button is inset 10px in a 300px results frame; icon(18)+pad(11) = 29
            local scrollGutter = willScroll and (scrollBar:GetWidth() + 7) or 0
            local btnW = resultsFrame:GetWidth() - 10 - scrollGutter
            btn:SetWidth(btnW)
            local scrollBarW = willScroll and (scrollBar:GetWidth() + 4) or 5
            btn.text:SetWidth(btnW - 29 - scrollBarW)

            -- Measure actual text height and size button to fit
            local textHeight = btn.text:GetStringHeight() or 14
            local rowHeight = mmax(24, textHeight + 8)  -- minimum 24, pad 8

            btn:SetHeight(rowHeight)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, yOffset)
            yOffset = yOffset - rowHeight - 2
        else
            btn:Hide()
        end
    end

    -- Calculate total content height vs already-clamped maxVisibleHeight
    local totalContentHeight = -yOffset + 6
    local hasScroll = totalContentHeight > maxVisibleHeight
    local visibleHeight = hasScroll and maxVisibleHeight or totalContentHeight

    -- Size the results frame and scroll child
    -- When not scrolling, add 12px for scrollFrame internal padding (6px top + 6px bottom)
    -- so scrollChild matches viewport exactly and no unwanted scroll range is created.
    -- When scrolling, maxVisibleHeight already includes +12 for this padding.
    resultsFrame:SetHeight(visibleHeight + (hasScroll and 0 or 12))
    resultsFrame.scrollChild:SetWidth(resultsFrame:GetWidth())
    resultsFrame.scrollChild:SetHeight(totalContentHeight)

    -- Position scroll frame inside results frame
    resultsFrame.scrollFrame:ClearAllPoints()
    resultsFrame.scrollFrame:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 0, -6)
    resultsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, 6)

    -- Reset scroll position on new search
    resultsFrame.scrollFrame:SetVerticalScroll(0)

    -- Show/hide minimal scrollbar (overlays right edge)
    if resultsFrame.scrollBar then
        resultsFrame.scrollBar:SetShown(hasScroll)
        if hasScroll then
            resultsFrame.scrollBar:UpdateThumb(totalContentHeight, visibleHeight)
        end
    end

    -- Anchor results dropdown to whichever search bar is active
    resultsFrame:ClearAllPoints()
    if resultsAbove then
        resultsFrame:SetPoint("BOTTOMLEFT", preAnchor, "TOPLEFT", 0, -8)
    else
        resultsFrame:SetPoint("TOPLEFT", preAnchor, "BOTTOMLEFT", 0, 8)
    end

    resultsFrame:Show()
end

function MapSearch:HideResults()
    resultsFrame:Hide()
end

function MapSearch:ShowPinnedItems()
    local pins = EasyFind.db.pinnedMapItems
    if not pins or #pins == 0 then
        self:HideResults()
        return
    end
    -- Mark each pin so ShowResults renders the indicator
    local display = {}
    for _, pin in ipairs(pins) do
        local copy = {}
        for k, v in pairs(pin) do copy[k] = v end
        copy.isPinned = true
        tinsert(display, copy)
    end
    self:ShowResults(display)
end

function MapSearch:SelectFirstResult()
    -- Don't do anything if no results are showing
    if not resultsFrame:IsShown() then return end
    if resultButtons[1]:IsShown() and resultButtons[1].data then
        self:SelectResult(resultButtons[1].data)
    end
end

function MapSearch:SelectResult(data)
    -- Clear preview state so OnLeave doesn't undo the real selection
    self._previewing = nil
    self._savedPinState = nil
    searchFrame.editBox:ClearFocus()
    self:HideResults()

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

        -- Handle zone selection
        if data.isZone and data.zoneMapID then
            -- If this zone is also a dungeon/raid entrance, set a pending waypoint
            -- so the entrance gets highlighted after navigating to the zone
            if data.entranceX and data.entranceY and data.entranceMapID then
                DebugPrint("[EasyFind] SelectResult → ZONE+ENTRANCE branch, entranceMapID=", data.entranceMapID)
                if EasyFind.db.navigateToZonesDirectly then
                    self:ClearZoneHighlight()
                end
                self.pendingWaypoint = {
                    x = data.entranceX, y = data.entranceY,
                    icon = data.entranceIcon, category = data.entranceCategory,
                    mapID = data.entranceMapID,
                }
                if EasyFind.db.navigateToZonesDirectly then
                    WorldMapFrame:SetMapID(data.entranceMapID)
                else
                    self:HighlightZoneOnMap(data.entranceMapID, data.name)
                end
            elseif EasyFind.db.navigateToZonesDirectly then
                DebugPrint("[EasyFind] SelectResult → ZONE DIRECT branch, zoneMapID=", data.zoneMapID)
                -- Direct mode: navigate straight to the zone
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            else
                DebugPrint("[EasyFind] SelectResult → ZONE TEACHING branch, zoneMapID=", data.zoneMapID)
                -- Teaching mode: highlight the zone on current/parent map
                self:HighlightZoneOnMap(data.zoneMapID, data.name)
            end
            return
        end

        -- Dungeon/raid entrance from global search: navigate to zone, then show waypoint
        if data.isDungeonEntrance and data.entranceMapID then
            local currentMapID = WorldMapFrame:GetMapID()
            DebugPrint("[EasyFind] SelectResult → DUNGEON ENTRANCE branch, currentMap=", currentMapID, "entranceMapID=", data.entranceMapID)
            if currentMapID == data.entranceMapID then
                DebugPrint("[EasyFind] SelectResult → DUNGEON DIRECT waypoint")
                -- Already on the right map, just show the waypoint
                self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
            else
                -- The stored entranceMapID may differ from the current map even
                -- though the entrance is visible here (e.g. entrance recorded on
                -- Azj-Kahet but user is viewing City of Threads, or vice-versa).
                -- Ask the EJ API whether this entrance exists on the current map.
                DebugPrint("[EasyFind] SelectResult → DUNGEON checking EJ API for current map")
                local found = false
                if C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap then
                    local entrances = C_EncounterJournal.GetDungeonEntrancesForMap(currentMapID)
                    if entrances then
                        for _, ej in ipairs(entrances) do
                            if ej.name == data.name and ej.position then
                                self:ShowWaypointAt(ej.position.x, ej.position.y, data.icon, data.category)
                                found = true
                                break
                            end
                        end
                    end
                end
                if not found then
                    -- Navigate to the zone, then show waypoint on arrival
                    if EasyFind.db.navigateToZonesDirectly then
                        self:ClearZoneHighlight()
                    end
                    -- Set pendingWaypoint AFTER ClearZoneHighlight (which wipes it)
                    self.pendingWaypoint = {x = data.x, y = data.y, icon = data.icon, category = data.category, mapID = data.entranceMapID}
                    if EasyFind.db.navigateToZonesDirectly then
                        WorldMapFrame:SetMapID(data.entranceMapID)
                    else
                        self:HighlightZoneOnMap(data.entranceMapID, data.name)
                    end
                end
            end
            return
        end
        
        -- Check if this POI has multiple instances (duplicates)
        if data.allInstances and #data.allInstances > 1 then
            -- Show ALL instances on the map
            self:ShowMultipleWaypoints(data.allInstances)
        elseif data.x and data.y then
            -- Single POI with coordinates
            self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
        elseif data.pin then
            -- Dynamic pin with no coords - highlight it directly
            self:HighlightPin(data.pin)
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
    local userScale = EasyFind.db.iconScale or 1.0
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
    
    -- Show each instance with pin, highlight box, and indicator
    for i, instance in ipairs(instances) do
        if instance.x and instance.y then
            local pin, highlight, ind

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
                    glow:SetTexture("Interface\\Cooldown\\star4")
                    glow:SetVertexColor(1, 1, 0, 0.8)  -- Pin glow always yellow
                    glow:SetBlendMode("ADD")
                    extraPin.glow = glow
                    
                    local animGroup = extraPin:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local pulse = animGroup:CreateAnimation("Alpha")
                    pulse:SetFromAlpha(1)
                    pulse:SetToAlpha(0.3)
                    pulse:SetDuration(0.4)
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
                            local viewingMapID = WorldMapFrame:GetMapID()
                            if viewingMapID then
                                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(viewingMapID, self.waypointX, self.waypointY))
                                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
                                efPlacedWaypoint = true
                                cachedWPMapID = viewingMapID
                                cachedWPx = self.waypointX
                                cachedWPy = self.waypointY
                                ShowSuperTrackGlow()
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
                    top:SetColorTexture(1, 1, 0, 1)
                    extraHighlight.top = top

                    local bottom = extraHighlight:CreateTexture(nil, "OVERLAY")
                    bottom:SetColorTexture(1, 1, 0, 1)
                    extraHighlight.bottom = bottom

                    local left = extraHighlight:CreateTexture(nil, "OVERLAY")
                    left:SetColorTexture(1, 1, 0, 1)
                    extraHighlight.left = left

                    local right = extraHighlight:CreateTexture(nil, "OVERLAY")
                    right:SetColorTexture(1, 1, 0, 1)
                    extraHighlight.right = right
                    
                    local animGroup = extraHighlight:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local alpha = animGroup:CreateAnimation("Alpha")
                    alpha:SetFromAlpha(1)
                    alpha:SetToAlpha(0.4)
                    alpha:SetDuration(0.5)
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
                    indMove:SetDuration(0.4)
                    extraInd.animGroup = animGroup

                    self.extraIndicators[i-1] = extraInd
                end
                ind = self.extraIndicators[i-1]
            end
            
            -- Position and show the pin
            pin:SetSize(iconSize, iconSize)
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", canvas, "TOPLEFT", instance.x * canvasWidth, -instance.y * canvasHeight)
            pin.waypointX = instance.x
            pin.waypointY = instance.y
            pin.isLocalSearch = not isGlobalSearch

            local iconTexture = GetCategoryIcon(instance.category)
            if instance.icon then
                iconTexture = instance.icon
            end
            SetIconTexture(pin.icon, iconTexture)
            
            if pin.glow then
                pin.glow:SetSize(glowSize, glowSize)
            end
            
            pin:Show()
            if pin.animGroup and EasyFind.db.blinkingPins then
                pin.animGroup:Play()
            end

            -- Position and show the highlight box
            highlight:SetSize(highlightSize, highlightSize)
            highlight:ClearAllPoints()
            highlight:SetPoint("CENTER", pin, "CENTER", 0, 0)
            ResizeHighlightBorders(highlight)
            highlight:Show()
            if highlight.animGroup then
                highlight.animGroup:Play()
            end
            
            -- Position and show the indicator
            ind:SetSize(indicatorSize, indicatorSize)
            if ind.glow then
                ind.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
            end
            ind:ClearAllPoints()
            ind:SetPoint("BOTTOM", highlight, "TOP", 0, 2)
            ind:Show()
            if ind.animGroup then
                ind.animGroup:Play()
            end
        end
    end

    -- Auto-track on minimap if requested by navigate button
    if self.autoTrackNextPin then
        self.autoTrackNextPin = nil
        self:TrackActivePin()
    end
end

function MapSearch:ShowWaypointAt(x, y, icon, category)
    self:ClearHighlight()

    -- Save pin state so it can be restored after map close/reopen or map change
    activePinState = {
        mapID = WorldMapFrame:GetMapID(),
        x = x, y = y,
        icon = icon, category = category,
        isLocal = not isGlobalSearch,
    }

    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local canvasWidth, canvasHeight = canvas:GetSize()
    
    -- Convert UI-unit sizes to canvas units so they appear the same screen size
    local userScale = EasyFind.db.iconScale or 1.0
    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE)       * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE)  * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE)  * userScale
    local indicatorSize     = ns.UIToCanvas(ns.ICON_SIZE)       * userScale
    local indicatorGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE)  * userScale
    
    -- Resize the pin and glow
    waypointPin:SetSize(iconSize, iconSize)
    waypointPin.glow:SetSize(glowSize, glowSize)
    
    -- Use category icon if no specific icon provided
    local iconTexture = GetCategoryIcon(category or "unknown")
    if icon then
        iconTexture = icon
    end
    SetIconTexture(waypointPin.icon, iconTexture)
    waypointPin:ClearAllPoints()
    waypointPin:SetPoint("CENTER", canvas, "TOPLEFT", canvasWidth * x, -canvasHeight * y)
    waypointPin.waypointX = x
    waypointPin.waypointY = y
    waypointPin.isLocalSearch = not isGlobalSearch
    waypointPin:Show()

    -- Start pin animation (pulsing glow)
    if waypointPin.animGroup and EasyFind.db.blinkingPins then
        waypointPin.animGroup:Play()
    end
    
    -- Resize and position highlight
    highlightFrame:SetSize(highlightSize, highlightSize)
    highlightFrame:ClearAllPoints()
    highlightFrame:SetPoint("CENTER", waypointPin, "CENTER", 0, 0)
    ResizeHighlightBorders(highlightFrame)
    highlightFrame:Show()
    
    -- Resize indicator and its glow
    indicatorFrame:SetSize(indicatorSize, indicatorSize)
    indicatorFrame.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
    indicatorFrame:Show()
    
    if highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Play()
    end

    -- Auto-track on minimap if requested by navigate button
    if self.autoTrackNextPin then
        self.autoTrackNextPin = nil
        self:TrackActivePin()
    end
end

function MapSearch:HighlightPin(pin)
    waypointPin:Hide()
    
    if not pin or not pin:IsShown() then
        self:ClearHighlight()
        return
    end
    
    currentHighlightedPin = pin
    
    -- Convert UI-unit sizes to canvas units
    local userScale = EasyFind.db.iconScale or 1.0
    
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
    indicatorFrame:Show()

    if highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Play()
    end
end

function MapSearch:ClearHighlight()
    highlightFrame:Hide()
    highlightFrame.top:Show()
    highlightFrame.bottom:Show()
    highlightFrame.left:Show()
    highlightFrame.right:Show()

    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 2)
    indicatorFrame:Hide()
    waypointPin:Hide()
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
    
    currentHighlightedPin = nil
end

-- Resolve preview-able coordinates for a search result on the current map.
-- Returns {x, y, icon, category} or {instances} or nil if not previewable.
function MapSearch:GetPreviewCoords(data)
    local currentMapID = WorldMapFrame:GetMapID()
    -- Multi-instance POIs
    if data.allInstances and #data.allInstances > 1 then
        return { instances = data.allInstances }
    end
    -- Direct POI coordinates
    if data.x and data.y and not data.isZone then
        -- Dungeon entrance on a different map - check EJ API for current map
        if data.isDungeonEntrance and data.entranceMapID and data.entranceMapID ~= currentMapID then
            if C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap then
                local entrances = C_EncounterJournal.GetDungeonEntrancesForMap(currentMapID)
                if entrances then
                    for _, ej in ipairs(entrances) do
                        if ej.name == data.name and ej.position then
                            return { x = ej.position.x, y = ej.position.y, icon = data.icon, category = data.category }
                        end
                    end
                end
            end
            return nil  -- not visible on current map
        end
        return { x = data.x, y = data.y, icon = data.icon, category = data.category }
    end
    -- Zone with entrance on the current map
    if data.isZone and data.entranceX and data.entranceY and data.entranceMapID == currentMapID then
        return { x = data.entranceX, y = data.entranceY, icon = data.entranceIcon, category = data.entranceCategory }
    end
    return nil
end

-- Full clear: map visuals + minimap waypoint tracking
-- Called by explicit dismiss actions (right-click pin, /ef clear, clear button)
function MapSearch:ClearAll()
    activePinState = nil
    self:ClearHighlight()
    -- Only clear Blizzard waypoint if EasyFind placed it
    if efPlacedWaypoint then
        HideSuperTrackGlow()
        C_SuperTrack.SetSuperTrackedUserWaypoint(false)
        if C_Map.HasUserWaypoint() then
            C_Map.ClearUserWaypoint()
        end
    end
end

-- Auto-track the currently active pin on the minimap via Blizzard waypoint.
-- Called by the navigate button to combine select + track in one action.
function MapSearch:TrackActivePin()
    if not activePinState then return end
    local mapID = activePinState.mapID
    local x, y
    if activePinState.instances then
        local first = activePinState.instances[1]
        if first then x, y = first.x, first.y end
    else
        x, y = activePinState.x, activePinState.y
    end
    if not mapID or not x or not y then return end

    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    efPlacedWaypoint = true
    cachedWPMapID = mapID
    cachedWPx = x
    cachedWPy = y
    ShowSuperTrackGlow()
end

function MapSearch:UpdateScale()
    if searchFrame then
        local scale = EasyFind.db.mapSearchScale or 1.0
        searchFrame:SetScale(scale)
        if resultsFrame then
            resultsFrame:SetScale(scale)
        end
    end
    if globalSearchFrame then
        local scale = EasyFind.db.mapSearchScale or 1.0
        globalSearchFrame:SetScale(scale)
    end
end

function MapSearch:UpdateOpacity()
    local alpha = EasyFind.db.searchBarOpacity or 0.75
    if searchFrame and searchFrame.bgTex then
        searchFrame.bgTex:SetColorTexture(0, 0, 0, alpha)
    end
    if globalSearchFrame and globalSearchFrame.bgTex then
        globalSearchFrame.bgTex:SetColorTexture(0, 0, 0, alpha)
    end
end

function MapSearch:UpdateSearchBarTheme()
    local isRetail = (EasyFind.db.resultsTheme or "Retail") == "Retail"
    local frames = {searchFrame, globalSearchFrame}
    for _, frame in ipairs(frames) do
        if frame then
            if isRetail then
                frame:SetBackdrop({
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 16,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 }
                })
                frame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)
            else
                frame:SetBackdrop({
                    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                    edgeSize = 16,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 }
                })
                frame:SetBackdropBorderColor(1, 1, 1, 1)
            end
        end
    end
end

function MapSearch:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 2)
        EasyFind.db.mapSearchPosition = nil
    end
    if globalSearchFrame then
        globalSearchFrame:ClearAllPoints()
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", 0, 2)
        EasyFind.db.globalSearchPosition = nil
    end
end

-- Called when the user changes the icon scale setting.
function MapSearch:UpdateIconScales()
    -- Updates all visible pins, highlights, and arrows in real-time.
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local userScale = EasyFind.db.iconScale or 1.0
    
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
    ns.UpdateIndicator(_G["EasyFindMapIndicator"])

    -- Update zone indicator
    ns.UpdateIndicator(_G["EasyFindZoneIndicator"])

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
    ns.UpdateIndicator(_G["EasyFindIndicatorFrame"])
end
