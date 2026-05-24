local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapUtils = ns.MapUtils
local pcall = Utils.pcall

local GetMapInfo = C_Map.GetMapInfo
local GetMapRectOnMap = C_Map.GetMapRectOnMap
local GetMapRectViaContinent = MapUtils.GetMapRectViaContinent
local ResolveZoneForMap = MapUtils.ResolveZoneForMap

-- Resolve preview-able coordinates for a search result on the current map.
-- Returns {x, y, icon, category} or {instances} or nil if not previewable.
function MapSearch:GetPreviewCoords(data)
    local currentMapID = WorldMapFrame:GetMapID()
    if data.allInstances then
        -- Filter instances to those whose (x,y) are valid on the
        -- currently viewed map. FMs scanned at both continent and
        -- zone level merge into a single result with multiple
        -- instances; without this filter, both render, and one is
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
    -- in place of stamping an overlay. Global "Across the World"
    -- results come from a cache that doesn't carry pin refs; fall back
    -- to a by-name lookup on the live canvas so those results still
    -- get the native-pin highlight when they happen to be in view.
    if px and py and (not pMapID or pMapID == currentMapID) then
        local pin = data.pin
        if (not pin or not pin:IsShown())
           and self.FindNativePinByName and data.name then
            pin = self:FindNativePinByName(data.name)
        end
        return { x = px, y = py, icon = pIcon, category = pCat, pin = pin }
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


-- Shared hover-preview entry point. Shows the hovered pin ALONGSIDE
-- any pin the user already clicked, by reusing ShowMultipleWaypoints,
-- same mechanism that handles multi-instance results like auction
-- houses. Saves activePinState on first preview so EndHoverPreview can
-- cleanly restore to the clicked-only state when the cursor moves off.
function MapSearch:RunHoverPreview(data)
    if not data then return end

    -- Snapshot existing pin state once per hover session so EndHoverPreview
    -- can restore cleanly. PreviewZoneHighlight has no side effects, so
    -- there's no zone-navigation state to save.
    if not self._previewing then
        self._savedPinState = self:GetActivePinState()
    end
    self._previewing = true

    -- Zone-area preview: when hovering a zone result, draw a translucent
    -- rect where the zone sits on the currently-viewed map. Strictly
    -- visible-only: PreviewZoneHighlight bails when the zone isn't on
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

    -- Always restore activePinState (even to nil) so hover never
    -- persists as the "active" clicked pin. Without unconditional
    -- restoration, hovering when nothing is clicked would silently
    -- promote the previewed pin into the real active state, which
    -- downstream code (auto-track on map reopen, etc.) latches onto.
    self:SetActivePinState(self._savedPinState)
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
    local saved = self._savedPinState
    self._savedPinState = nil
    local mapID = WorldMapFrame and WorldMapFrame:GetMapID()
    -- If a click committed a new active pin state during this hover
    -- (or shortly after, once a cross-map navigation settled),
    -- activePinState now points at it. ClearHighlight + restore-saved
    -- would wipe what the click just placed, leaving the user without
    -- the highlight they explicitly triggered. Detect by comparing
    -- against the pre-hover snapshot and render the committed state
    -- instead.
    local current = self:GetActivePinState()
    local function stateOnMap(s)
        return s and s.mapID == mapID
            and (s.instances or (s.x and s.y))
    end
    local function statesDiffer(a, b)
        if not a or not b then return a ~= b end
        if a.mapID ~= b.mapID then return true end
        if a.x ~= b.x or a.y ~= b.y then return true end
        return false
    end
    if stateOnMap(current) and statesDiffer(current, saved) then
        -- Re-render the committed pin without disturbing it.
        self:ClearHighlight()
        if current.instances then
            self:ShowMultipleWaypoints(current.instances)
        else
            self:ShowWaypointAt(current.x, current.y, current.icon, current.category)
        end
        self:SetActivePinState(current)
        return
    end
    self:ClearHighlight()
    if saved and saved.mapID == mapID then
        if saved.instances then
            self:ShowMultipleWaypoints(saved.instances)
        elseif saved.x and saved.y then
            self:ShowWaypointAt(saved.x, saved.y, saved.icon, saved.category)
        end
    end
end


-- Preview a map search result from the UI search bar on the world map.
-- Only shows if WorldMapFrame is open. Returns true if preview was shown.
function MapSearch:PreviewUIResult(data)
    if not data or not WorldMapFrame or not WorldMapFrame:IsShown() then return false end
    local coords = self:GetPreviewCoords(data)
    if not coords then return false end
    self._savedPinState = self:GetActivePinState()
    self._previewing = true
    if coords.instances then
        self:ShowMultipleWaypoints(coords.instances)
    elseif coords.pin and coords.pin:IsShown() then
        self:HighlightPin(coords.pin, coords.x, coords.y, coords.icon, coords.category)
    else
        self:ShowWaypointAt(coords.x, coords.y, coords.icon, coords.category)
    end
    self:SetActivePinState(self._savedPinState)
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
