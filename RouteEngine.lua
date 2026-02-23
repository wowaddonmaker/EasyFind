-- =============================================================================
-- EasyFind Route Engine
-- GPS route state machine: computes routes via TransportGraph, manages step
-- advancement on zone changes, drives the minimap waypoint, and outputs route
-- instructions to a dedicated "GPS" chat tab.
-- =============================================================================
local ADDON_NAME, ns = ...

local RouteEngine = {}
ns.RouteEngine = RouteEngine

local Utils    = ns.Utils
local sformat  = Utils.sformat
local tinsert  = Utils.tinsert
local ipairs   = Utils.ipairs
local tostring = Utils.tostring

local C_Map   = C_Map
local C_Timer = C_Timer

-- =============================================================================
-- GPS CHAT TAB
-- Creates (or finds) a dedicated "GPS" chat tab for route messages.
-- =============================================================================
local gpsFrame = nil

local function GetOrCreateGPSTab()
    if gpsFrame then return gpsFrame end

    -- Check if a GPS tab already exists (e.g. from a previous route this session)
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == "GPS" then
            gpsFrame = _G["ChatFrame" .. i]
            if gpsFrame then return gpsFrame end
        end
    end

    -- Create new tab
    local frame = FCF_OpenNewWindow("GPS")
    if frame then
        -- Remove all message types so only our messages show
        ChatFrame_RemoveAllMessageGroups(frame)
        ChatFrame_RemoveAllChannels(frame)
        gpsFrame = frame
    end

    return gpsFrame
end

local function GPSPrint(msg)
    local frame = GetOrCreateGPSTab()
    if frame then
        frame:AddMessage(msg)
    end
    -- Also echo to main chat with a prefix
    print(sformat("|cFF00CCFF[GPS]|r %s", msg))
end

local function GPSHeader(msg)
    GPSPrint("|cFF00CCFF— " .. msg .. " —|r")
end

-- =============================================================================
-- ROUTE STATE
-- =============================================================================
local activeRoute = nil
-- {
--     steps = { {from, to, x, y, label, type, cost}, ... },
--     currentStep = 1,
--     destinationName = "The Stonevault",
--     destinationMapID = 2339,
--     finalCoords = {x, y, icon, category},  -- dungeon entrance last-mile (nil for zone-only)
-- }

-- =============================================================================
-- TYPE ICONS for chat output
-- =============================================================================
local TYPE_ICONS = {
    portal   = "|TInterface\\MINIMAP\\TRACKING\\Auctioneer:0|t",  -- placeholder
    boat     = "|TInterface\\MINIMAP\\TRACKING\\StableMaster:0|t",
    zeppelin = "|TInterface\\MINIMAP\\TRACKING\\StableMaster:0|t",
    tram     = "|TInterface\\MINIMAP\\TRACKING\\Repair:0|t",
    flight   = "|TInterface\\MINIMAP\\TRACKING\\FlightMaster:0|t",
    walk     = "|TInterface\\MINIMAP\\TRACKING\\Innkeeper:0|t",
}

local function StepIcon(stepType)
    return TYPE_ICONS[stepType] or ""
end

local function FormatStep(index, step, total)
    local graph = ns.TransportGraph
    local fromName = graph:GetNodeName(step.from)
    local toName   = graph:GetNodeName(step.to)
    local icon = StepIcon(step.type)
    return sformat("  %s |cFFFFFFFF%d/%d|r %s |cFFFFD100%s|r → |cFF00FF00%s|r",
        icon, index, total, step.label, fromName, toName)
end

-- =============================================================================
-- CORE METHODS
-- =============================================================================

function RouteEngine:IsRouteActive()
    return activeRoute ~= nil
end

function RouteEngine:GetRouteStatus()
    if not activeRoute then return nil end
    return {
        destination = activeRoute.destinationName,
        currentStep = activeRoute.currentStep,
        totalSteps  = #activeRoute.steps,
        step        = activeRoute.steps[activeRoute.currentStep],
    }
end

--- Start GPS routing to a destination.
--- @param destMapID number The destination zone mapID
--- @param destName string Display name of the destination
--- @param finalCoords table|nil {x, y, icon, category} for last-mile waypoint at entrance
--- @return boolean true if route was started
function RouteEngine:StartRoute(destMapID, destName, finalCoords)
    -- Always clear GPS chat on any new navigation attempt
    if gpsFrame then
        gpsFrame:Clear()
    end

    local graph = ns.TransportGraph
    if not graph then
        GPSPrint("|cFFFF0000Error:|r TransportGraph not loaded.")
        return false
    end

    -- Resolve origin
    local playerMapID = C_Map.GetBestMapForUnit("player")
    if not playerMapID then
        GPSPrint("|cFFFF0000Error:|r Cannot determine your current location.")
        return false
    end

    local fromNode = graph:ResolveNode(playerMapID)
    local toNode, needsLastMile = graph:ResolveDestination(destMapID)

    -- Already at destination?
    if fromNode and toNode and fromNode == toNode then
        GPSPrint(sformat("|cFF00FF00You're already in %s!|r", destName))
        -- If there's a last-mile entrance, set that waypoint directly
        if finalCoords and ns.SetInternalWaypoint then
            ns.SetInternalWaypoint(destMapID, finalCoords.x, finalCoords.y)
            GPSPrint(sformat("Pinning entrance: |cFFFFD100%s|r", destName))
        end
        return false
    end

    -- Same continent with no graph nodes? Direct navigation
    if not fromNode and not toNode and graph:SameContinent(playerMapID, destMapID) then
        GPSPrint(sformat("No transport route needed — |cFFFFD100%s|r is on the same continent. Fly there!", destName))
        if finalCoords and ns.SetInternalWaypoint then
            ns.SetInternalWaypoint(destMapID, finalCoords.x, finalCoords.y)
        end
        return false
    end

    if not fromNode then
        GPSPrint(sformat("|cFFFF6600No route:|r Can't find a transport hub near your current location."))
        return false
    end
    if not toNode then
        GPSPrint(sformat("|cFFFF6600No route:|r Can't find a transport hub near |cFFFFD100%s|r.", destName))
        return false
    end

    -- Compute route
    local steps = graph:FindRoute(fromNode, toNode)
    if not steps or #steps == 0 then
        -- Same continent fallback — just fly there
        if graph:SameContinent(playerMapID, destMapID) then
            GPSPrint(sformat("|cFFFFD100%s|r is on the same continent. Fly directly!", destName))
            if finalCoords and ns.SetInternalWaypoint then
                ns.SetInternalWaypoint(destMapID, finalCoords.x, finalCoords.y)
            end
            return false
        end
        GPSPrint(sformat("|cFFFF0000No route found|r to |cFFFFD100%s|r.", destName))
        return false
    end

    -- Cancel any existing route
    if activeRoute then
        self:CancelRoute("Starting new route")
    end

    -- Store route
    activeRoute = {
        steps = steps,
        currentStep = 1,
        destinationName = destName,
        destinationMapID = destMapID,
        finalCoords = finalCoords,
    }

    -- Print route to GPS tab
    GPSHeader(sformat("Route to %s (%d step%s)", destName, #steps, #steps > 1 and "s" or ""))
    for i, step in ipairs(steps) do
        GPSPrint(FormatStep(i, step, #steps))
    end
    GPSPrint("")

    -- Set waypoint for first step
    self:SetWaypointForCurrentStep()

    return true
end

--- Advance to the next step or complete the route.
--- Called from PLAYER_ENTERING_WORLD when zone changes.
--- @return boolean true if the route engine consumed this zone change
function RouteEngine:OnZoneChanged()
    if not activeRoute then return false end

    -- Give the map system a moment to settle
    local route = activeRoute
    local step = route.steps[route.currentStep]
    if not step then
        self:CancelRoute("Invalid step")
        return true
    end

    -- Where is the player now?
    local playerMapID = C_Map.GetBestMapForUnit("player")
    if not playerMapID then return false end

    local graph = ns.TransportGraph
    local playerNode = graph:ResolveNode(playerMapID)
    local expectedDest = step.to

    -- Did we arrive at the expected destination?
    if playerNode == expectedDest or playerMapID == expectedDest then
        GPSPrint(sformat("|cFF00FF00✓|r Arrived at |cFFFFD100%s|r",
            graph:GetNodeName(expectedDest)))

        route.currentStep = route.currentStep + 1

        if route.currentStep > #route.steps then
            -- Route complete!
            self:CompleteRoute()
        else
            -- More steps — set next waypoint
            GPSPrint("")
            self:SetWaypointForCurrentStep()
        end
        return true
    end

    -- Player went somewhere unexpected — try re-routing
    local toNode = graph:ResolveNode(route.destinationMapID)
    if not toNode then
        self:CancelRoute("Can't re-route: destination unreachable")
        return true
    end

    local fromNode = graph:ResolveNode(playerMapID)
    if not fromNode then
        -- Player is in an unresolvable zone — clear stale waypoint, keep route alive
        if ns.ClearInternalWaypoint then ns.ClearInternalWaypoint() end
        if ns.MapSearch then ns.MapSearch:HideGPSPin() end
        GPSPrint("|cFFFF6600Off-path:|r Get to a major city to resume routing.")
        return true
    end

    if fromNode == toNode then
        -- Arrived at destination hub via unexpected path
        self:CompleteRoute()
        return true
    end

    -- Re-route — clear stale waypoint first
    if ns.ClearInternalWaypoint then ns.ClearInternalWaypoint() end
    if ns.MapSearch then ns.MapSearch:HideGPSPin() end

    local newSteps = graph:FindRoute(fromNode, toNode)
    if newSteps and #newSteps > 0 then
        GPSPrint("|cFFFF6600Re-routing...|r")
        route.steps = newSteps
        route.currentStep = 1
        GPSHeader(sformat("New route to %s (%d step%s)",
            route.destinationName, #newSteps, #newSteps > 1 and "s" or ""))
        for i, s in ipairs(newSteps) do
            GPSPrint(FormatStep(i, s, #newSteps))
        end
        GPSPrint("")
        self:SetWaypointForCurrentStep()
    else
        self:CancelRoute("No route found from new location")
    end

    return true
end

--- Set the minimap waypoint for the current route step.
function RouteEngine:SetWaypointForCurrentStep()
    if not activeRoute then return end
    local step = activeRoute.steps[activeRoute.currentStep]
    if not step then return end

    local stepNum = activeRoute.currentStep
    local total = #activeRoute.steps

    GPSPrint(sformat("|cFF00CCFF►|r Step %d/%d: Go to |cFFFFD100%s|r in |cFFFFD100%s|r",
        stepNum, total, step.label,
        ns.TransportGraph:GetNodeName(step.from)))

    -- Set internal waypoint at the departure point (the transport the player needs to reach)
    if ns.SetInternalWaypoint then
        ns.SetInternalWaypoint(step.from, step.x, step.y)
    end

    -- Show GPS pin on world map
    if ns.MapSearch then
        ns.MapSearch:ShowGPSPin(step.from, step.x, step.y, step.label)
    end
end

--- Route completed — print success, optionally set last-mile waypoint.
function RouteEngine:CompleteRoute()
    if not activeRoute then return end

    local route = activeRoute
    GPSPrint("")
    GPSHeader(sformat("Arrived at %s!", route.destinationName))

    -- Clear GPS map pin
    if ns.MapSearch then ns.MapSearch:HideGPSPin() end

    -- Last mile: if destination has entrance coords, pin them
    if route.finalCoords and ns.SetInternalWaypoint then
        local fc = route.finalCoords
        GPSPrint(sformat("Pinning entrance: |cFFFFD100%s|r", route.destinationName))
        -- Use the destination mapID for the entrance pin
        ns.SetInternalWaypoint(route.destinationMapID, fc.x, fc.y)
    else
        -- Clear waypoint since route is done
        if ns.ClearInternalWaypoint then
            ns.ClearInternalWaypoint()
        end
    end

    activeRoute = nil
end

--- Cancel the active route.
--- @param reason string|nil Optional reason to display
function RouteEngine:CancelRoute(reason)
    if not activeRoute then return end

    local msg = "Route cancelled"
    if reason then msg = msg .. ": " .. reason end
    GPSPrint("|cFFFF6600" .. msg .. "|r")

    activeRoute = nil

    if ns.ClearInternalWaypoint then
        ns.ClearInternalWaypoint()
    end
    if ns.MapSearch then ns.MapSearch:HideGPSPin() end
end

--- Print current route status.
function RouteEngine:PrintStatus()
    if not activeRoute then
        GPSPrint("No active route.")
        return
    end

    local route = activeRoute
    local step = route.steps[route.currentStep]
    GPSPrint(sformat("Navigating to |cFFFFD100%s|r — step %d/%d",
        route.destinationName, route.currentStep, #route.steps))
    if step then
        GPSPrint(FormatStep(route.currentStep, step, #route.steps))
    end
end
