local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapUtils = ns.MapUtils
local DebugPrint = Utils.DebugPrint

local ipairs = Utils.ipairs
local mmin = Utils.mmin
local pcall = Utils.pcall

local ZONE_PARENT_OVERRIDES = MapUtils.PARENT_OVERRIDES or {}
local C_Timer = C_Timer
local GetMapInfo = C_Map.GetMapInfo
local GetMapInfoAtPosition = C_Map.GetMapInfoAtPosition
local GetMapParentID = MapUtils.GetParentMapID
local GetMapPath = MapUtils.GetMapPath
local GetMapRectOnMap = C_Map.GetMapRectOnMap
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
        DebugPrint("[EasyFind] Using parent override for", targetMapID, "->", targetParentMapID)
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

    -- Ancestor target: highlight breadcrumb directly, else DCA overshoots.
    local currentParentChain = GetMapPath(currentMapID)
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

    local resolved = self:ResolveZoneForMap(targetMapID, currentMapID)
    if resolved ~= targetMapID then
        targetMapID = resolved
        targetInfo = GetMapInfo(targetMapID)
        if not targetInfo then return end
        targetParentMapID = GetMapParentID(targetMapID, targetInfo)
    end

    -- CASE 1: already on target's parent map.
    if currentMapID == targetParentMapID then
        DebugPrint("[EasyFind] CASE 1: Already on target parent, highlighting zone")

        -- Continent-parented cities (IF, UC, TB, Shattrath) route through
        -- their containing zone. Require full rect enclosure to avoid
        -- adjacent-zone false matches; skip for WoW-bugged Uldum/Vale.
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
                        -- < 25% gates city-sized targets; larger ratios are API bugs.
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
                -- Center returned the city itself; check surrounding zones.
                local surrounding = self:FindSurroundingZone(currentMapID, targetMapID, cL, cR, cT, cB, 1)
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

        -- Keep pending so OnMapChanged can stop the chain on arrival.
        self.pendingZoneHighlight = targetMapID
        C_Timer.After(0.05, function()
            self:HighlightZone(targetMapID)
        end)
        return
    end

    -- CASE 1b: current map contains target but API chain doesn't link them
    -- (e.g. Stormwind inside Elwynn Forest).
    if currentInfo and currentInfo.mapType == Enum.UIMapType.Zone then
        local cL, cR, cT, cB = self:GetMapRectViaContinent(targetMapID, currentMapID)
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

    local targetParentPath = GetMapPath(targetParentMapID)
    local currentPath = GetMapPath(currentMapID)

    DebugPrint("[EasyFind] Target parent path:")
    for i, p in ipairs(targetParentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end
    DebugPrint("[EasyFind] Current path:")
    for i, p in ipairs(currentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end

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

    -- CASE 2b: zone-level current contains target geographically though not
    -- via API chain (e.g. Azuremyst contains Exodar, parented to Kalimdor).
    if currentInfo and currentInfo.mapType == Enum.UIMapType.Zone then
        local cL, cR, cT, cB = self:GetMapRectViaContinent(targetMapID, currentMapID)
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

    -- CASE 3: below DCA, zoom out.
    DebugPrint("[EasyFind] CASE 3: Need to zoom OUT to DCA, highlighting breadcrumb")
    self:HighlightBreadcrumbForNavigation(dcaMapID, targetMapID, targetParentPath, dcaIndex)
end
