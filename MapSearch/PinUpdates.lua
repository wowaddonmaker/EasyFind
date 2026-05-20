local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils

local ipairs = Utils.ipairs
local GetPlayerMapPosition = C_Map.GetPlayerMapPosition
local SetUserWaypoint = C_Map.SetUserWaypoint

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
    local activePinState = self:GetActivePinState()
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
    self:SetEasyFindWaypointPlaced(true)
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

    local waypointPin, highlightFrame = self:GetMapVisualFrames()

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
    local _, highlightFrame = self:GetMapVisualFrames()
    if highlightFrame and highlightFrame:IsShown() then
        self:SetHighlightBordersVisible(highlightFrame, visible)
    end
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            if hl:IsShown() then
                self:SetHighlightBordersVisible(hl, visible)
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

    local waypointPin, highlightFrame, indicatorFrame = self:GetMapVisualFrames()

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
    local zoneHighlightFrame = self.GetZoneHighlightFrame and self:GetZoneHighlightFrame()
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

    -- Update UI highlight indicator (UI/Highlight.lua)
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then ns.UpdateIndicator(uiInd) end
end



