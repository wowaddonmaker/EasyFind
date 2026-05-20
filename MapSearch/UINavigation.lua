local _, ns = ...

local MapSearch = ns.MapSearch
local C_Timer = C_Timer

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
        -- SetUserWaypoint / SetSuperTrackedUserWaypoint here: the user
        -- has to click the on-canvas pin's tracking icon to actually
        -- start tracking, matching the way clicking the small map pin
        -- works elsewhere in the addon (and Blizzard's own UI).
        local x, y = data.x, data.y
        if data.mapID and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            self:SetActivePinState({
                mapID = data.mapID,
                x = x, y = y,
                icon = data.icon, category = data.category,
                isLocal = true,
            })
            self:RefreshAllClearButtons()
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

