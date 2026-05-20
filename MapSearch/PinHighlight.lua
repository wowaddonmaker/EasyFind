local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils

local ipairs = Utils.ipairs
local mmax = Utils.mmax
local pcall = Utils.pcall

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
    local waypointPin, highlightFrame, indicatorFrame = self:GetMapVisualFrames()
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
        self:SetActivePinState({
            mapID = WorldMapFrame:GetMapID(),
            x = x, y = y,
            icon = icon, category = category,
            isLocal = not MapSearch:IsGlobalSearchActive(),
        })
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
    self:ResizeHighlightBorders(highlightFrame)
    highlightFrame:Show()
    self:SetHighlightBordersVisible(highlightFrame, EasyFind.db.mapPinHighlight ~= false)
    indicatorFrame:Show()

    if indicatorFrame.animGroup then
        indicatorFrame.animGroup:Play()
    end
    if EasyFind.db.blinkingPins and highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
end

function MapSearch:ClearHighlight()
    local waypointPin, highlightFrame, indicatorFrame = self:GetMapVisualFrames()
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




