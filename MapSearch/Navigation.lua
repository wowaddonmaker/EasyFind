local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapFrames = ns.MapSearchFrames
local DebugPrint = Utils.DebugPrint

local ipairs = Utils.ipairs
local tsort = Utils.tsort
local pcall = Utils.pcall

local YELLOW_HIGHLIGHT = ns.YELLOW_HIGHLIGHT
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local hooksecurefunc = hooksecurefunc

local GetMapInfo = C_Map.GetMapInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetMapRectOnMap = C_Map.GetMapRectOnMap
local SetUserWaypoint = C_Map.SetUserWaypoint
local HasUserWaypoint = C_Map.HasUserWaypoint
local ClearUserWaypoint = C_Map.ClearUserWaypoint
local GetDungeonEntrancesForMap = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
local SetSuperTrackedVignette = C_SuperTrack and C_SuperTrack.SetSuperTrackedVignette

local function PinYAsc(a, b)
    return (a.y or 0) < (b.y or 0)
end

local GetCategoryIcon = MapSearch.GetCategoryIcon

local highlightFrame
local indicatorFrame
local waypointPin
local pinHoverClearsOverride = nil
local activePinState = nil
local efTrackedVignetteGUID = nil
local efPlacedWaypoint = false

function MapSearch:HasActivePinState()
    return activePinState ~= nil
end

function MapSearch:SetActivePinState(state)
    activePinState = state
end

function MapSearch:GetActivePinState()
    return activePinState
end
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


-- Canvas-unit borders so thickness matches UI search regardless of zoom.
local function ResizeHighlightBorders(frame)
    local bs  = ns.UIToCanvas(4)
    local pad = ns.UIToCanvas(4)

    -- Top/bottom own the corners (full width including padding).
    frame.top:ClearAllPoints()
    frame.top:SetHeight(bs)
    frame.top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -pad, 0)
    frame.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", pad, 0)

    frame.bottom:ClearAllPoints()
    frame.bottom:SetHeight(bs)
    frame.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -pad, 0)
    frame.bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", pad, 0)

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

function MapSearch:ResizeHighlightBorders(frame)
    ResizeHighlightBorders(frame)
end

function MapSearch:SetHighlightBordersVisible(frame, visible)
    SetHighlightBordersVisible(frame, visible)
end

function MapSearch:GetMapVisualFrames()
    return waypointPin, highlightFrame, indicatorFrame
end

function MapSearch:SetEasyFindWaypointPlaced(placed)
    efPlacedWaypoint = placed and true or false
end

function MapSearch:CreateHighlightFrame()
    highlightFrame = MapFrames.CreateHighlightBox("EasyFindMapHighlight", WorldMapFrame.ScrollContainer.Child, {
        strata = "TOOLTIP",
        level = 2000,
        size = 64,
        mouse = false,
        hidden = true,
        color = YELLOW_HIGHLIGHT,
        anim = { fromAlpha = 1, toAlpha = 0.4 },
    })

    -- Anchored explicitly each show; reparenting caused stale Hidden state.
    indicatorFrame = MapFrames.CreateIndicatorFrame("EasyFindMapIndicator", WorldMapFrame.ScrollContainer.Child, {
        strata = "TOOLTIP",
        level = 2000,
        size = ns.ICON_SIZE,
    })

    waypointPin = CreateFrame("Frame", "EasyFindLocationPin", WorldMapFrame.ScrollContainer.Child)
    waypointPin:SetSize(64, 64)
    waypointPin:SetFrameStrata("HIGH")
    waypointPin:SetFrameLevel(2000)
    waypointPin:Hide()

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

    MapFrames.AddWaypointPinVisuals(waypointPin, {
        color = YELLOW_HIGHLIGHT,
        glowSize = 100,
        glowAlpha = 0.8,
        anim = { fromAlpha = 1, toAlpha = 0.3 },
    })

end

local function RestoreActivePinsOnMapShow(self)
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

    if not activePinState and EasyFind.db.alwaysShowRares then
        C_Timer.After(0, function()
            self:UpdateRareTracking()
        end)
    end
end

local function ClearTransientMapState(self)
    self:ClearHighlight()
    self:ClearZoneHighlight()
    self.pendingWaypoint = nil
end

local function ShowPendingWaypoint(self, waypoint)
    C_Timer.After(0.1, function()
        self:ClearZoneHighlight()
        self:ShowWaypointAt(waypoint.x, waypoint.y, waypoint.icon, waypoint.category)
    end)
end

local function TryShowVisiblePendingEntrance(self, savedPendingZone)
    if not (savedPendingZone and self.pendingWaypoint and self.pendingWaypoint.mapID
            and GetDungeonEntrancesForMap) then
        return false
    end

    local waypoint = self.pendingWaypoint
    local currentMapID = WorldMapFrame:GetMapID()
    if waypoint.mapID == currentMapID then return false end

    local entrances = GetDungeonEntrancesForMap(currentMapID)
    if not entrances then return false end

    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, waypoint.mapID, currentMapID)
    if not (ok and left and right and top and bottom
            and (right - left) > 0 and (bottom - top) > 0) then
        return false
    end

    local projX = left + waypoint.x * (right - left)
    local projY = top + waypoint.y * (bottom - top)
    for _, entrance in ipairs(entrances) do
        if entrance.name and entrance.position then
            local dx = projX - entrance.position.x
            local dy = projY - entrance.position.y
            if (dx * dx + dy * dy) < 0.001 then
                DebugPrint("[EasyFind] OnMapChanged - entrance visible on current map, skipping zone nav")
                self.pendingWaypoint = nil
                self:ClearZoneHighlight()
                ShowPendingWaypoint(self, {
                    x = entrance.position.x,
                    y = entrance.position.y,
                    icon = waypoint.icon,
                    category = waypoint.category,
                })
                return true
            end
        end
    end

    return false
end

local function HandlePendingZoneMapChange(self, savedPendingZone, newMapID, newMapInfo)
    if not savedPendingZone then return false end

    local pendingInfo = GetMapInfo(savedPendingZone)
    local arrivedByName = pendingInfo and newMapInfo and pendingInfo.name == newMapInfo.name
    if newMapID == savedPendingZone or arrivedByName then
        DebugPrint("[EasyFind] OnMapChanged - arrived at target zone:", savedPendingZone)
        if self.pendingWaypoint then
            local waypoint = self.pendingWaypoint
            self.pendingWaypoint = nil
            ShowPendingWaypoint(self, waypoint)
        end
    else
        DebugPrint("[EasyFind] OnMapChanged - reguiding to:", savedPendingZone)
        C_Timer.After(0.1, function()
            self:HighlightZoneOnMap(savedPendingZone)
        end)
    end

    return true
end

local function HandlePendingWaypointMapChange(self)
    if not self.pendingWaypoint then return false end

    local waypoint = self.pendingWaypoint
    self.pendingWaypoint = nil
    DebugPrint("[EasyFind] OnMapChanged - showing pending waypoint at:", waypoint.x, waypoint.y)
    ShowPendingWaypoint(self, waypoint)
    return true
end

local function HandleIdleMapChange(self, newMapID)
    DebugPrint("[EasyFind] OnMapChanged - no pending, clearing highlights")
    if activePinState and activePinState.mapID ~= newMapID then
        activePinState = nil
    end
    self:ClearZoneHighlight()
    if EasyFind.db.alwaysShowRares then
        C_Timer.After(0, function() self:UpdateRareTracking() end)
    end
end

local function HookMapModeChanges(self)
    if not WorldMapFrame.IsMaximized then return end

    local function OnMapModeChange()
        self:UpdateBreadcrumbPosition()
    end
    hooksecurefunc(WorldMapFrame, "Maximize", OnMapModeChange)
    hooksecurefunc(WorldMapFrame, "Minimize", OnMapModeChange)
    WorldMapFrame:HookScript("OnShow", OnMapModeChange)
end

local function RegisterVignetteRefresh()
    local vignetteFrame = CreateFrame("Frame")
    vignetteFrame:RegisterEvent("VIGNETTES_UPDATED")
    vignetteFrame:SetScript("OnEvent", function()
        if MapSearch._previewing then return end
        if EasyFind.db.alwaysShowRares then
            MapSearch:UpdateRareTracking()
        end
    end)
end

function MapSearch:HookWorldMap()
    WorldMapFrame:HookScript("OnShow", function()
        RestoreActivePinsOnMapShow(self)
    end)

    WorldMapFrame:HookScript("OnHide", function()
        ClearTransientMapState(self)
    end)

    HookMapModeChanges(self)

    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        local newMapID = WorldMapFrame:GetMapID()
        local newMapInfo = newMapID and GetMapInfo(newMapID)
        DebugPrint("[EasyFind] OnMapChanged - new map:", newMapInfo and newMapInfo.name or "nil", "ID:", newMapID)
        DebugPrint("[EasyFind] OnMapChanged - pendingZoneHighlight:", self.pendingZoneHighlight)

        local savedPendingZone = self.pendingZoneHighlight

        self:ClearHighlight()
        self:ClearZoneHighlight()

        if self.breadcrumbHighlight then self.breadcrumbHighlight:Hide() end

        if TryShowVisiblePendingEntrance(self, savedPendingZone) then return end
        if HandlePendingZoneMapChange(self, savedPendingZone, newMapID, newMapInfo) then return end
        if HandlePendingWaypointMapChange(self) then return end
        HandleIdleMapChange(self, newMapID)
    end)

    RegisterVignetteRefresh()
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
    if self:IsOrphanZone(targetMapID) or directMode then
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
            DebugPrint("[EasyFind] SelectResult -> ZONE PARENT branch, navigating to", data.zoneMapID)
            self:ClearZoneHighlight()
            WorldMapFrame:SetMapID(data.zoneMapID)
            return
        end

        local directMode
        if directOverride ~= nil then
            directMode = directOverride
        elseif self:IsGlobalSearchActive() then
            directMode = EasyFind.db.globalMapDirectOpen or false
        else
            directMode = EasyFind.db.localMapDirectOpen or false
        end

        -- Handle zone selection
        if data.isZone and data.zoneMapID then
            -- Orphan zones have no physical position on any parent map
            -- (e.g. Vision of Stormwind). Snap directly since there's nothing
            -- to highlight or guide through.
            if self:IsOrphanZone(data.zoneMapID) then
                DebugPrint("[EasyFind] SelectResult -> ORPHAN ZONE, snapping directly to", data.zoneMapID)
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            elseif directMode then
                -- Direct (Fast) mode: every zone click zooms straight into the
                -- zone's own map. Skipping NavigateToEntrance keeps behavior
                -- uniform: without this, sub-zones with entrance coords
                -- (Vale of Eternal Blossoms, etc.) would pin on the parent
                -- and require a second click on the pin to actually enter.
                DebugPrint("[EasyFind] SelectResult -> ZONE DIRECT branch, zoneMapID=", data.zoneMapID)
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            elseif data.entranceX and data.entranceY and data.entranceMapID then
                DebugPrint("[EasyFind] SelectResult -> ZONE+ENTRANCE branch, entranceMapID=", data.entranceMapID)
                self:NavigateToEntrance(data.name, data.entranceX, data.entranceY, data.entranceIcon, data.entranceCategory, data.entranceMapID, directMode)
            else
                DebugPrint("[EasyFind] SelectResult -> ZONE TEACHING branch, zoneMapID=", data.zoneMapID)
                self:HighlightZoneOnMap(data.zoneMapID, data.name)
            end
            return
        end

        -- Dungeon/raid entrance from global search: navigate to zone, then show waypoint
        if data.isDungeonEntrance and data.entranceMapID then
            DebugPrint("[EasyFind] SelectResult -> DUNGEON ENTRANCE branch, entranceMapID=", data.entranceMapID)
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
        if not self:IsGlobalSearchActive() and directMode then
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
        isLocal = not MapSearch:IsGlobalSearchActive(),
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
    tsort(instances, PinYAsc)

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
                    MapFrames.AddWaypointPinVisuals(extraPin, {
                        color = YELLOW_HIGHLIGHT,
                        glowAlpha = 0.8,
                        anim = { fromAlpha = 1, toAlpha = 0.3 },
                    })

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
                    local extraHighlight = MapFrames.CreateHighlightBox("EasyFindExtraHighlight"..(i-1), canvas, {
                        strata = "HIGH",
                        level = 1998,
                        color = YELLOW_HIGHLIGHT,
                        anim = { fromAlpha = 1, toAlpha = 0.4 },
                    })

                    self.extraHighlights[i-1] = extraHighlight
                end
                highlight = self.extraHighlights[i-1]

                -- Create or reuse extra indicators
                if not self.extraIndicators[i-1] then
                    local extraInd = MapFrames.CreateIndicatorFrame("EasyFindExtraIndicator"..(i-1), canvas, {
                        strata = "HIGH",
                        level = 2001,
                        size = ns.ICON_SIZE,
                    })

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
                pin.isLocalSearch = not MapSearch:IsGlobalSearchActive()
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
        isLocal = not MapSearch:IsGlobalSearchActive(),
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
    -- permanent canvas child, no reparenting between calls.
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
        waypointPin.isLocalSearch = not MapSearch:IsGlobalSearchActive()
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

-- Returns true if EasyFind currently has any active map navigation.
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




