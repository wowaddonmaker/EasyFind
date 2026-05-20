local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local MapUtils = ns.MapUtils
local MapFrames = ns.MapSearchFrames
local DebugPrint = Utils.DebugPrint

local pairs, ipairs = Utils.pairs, Utils.ipairs
local slower = Utils.slower
local mmin, mmax = Utils.mmin, Utils.mmax
local pcall = Utils.pcall

local YELLOW_HIGHLIGHT = ns.YELLOW_HIGHLIGHT
local STAR_GLOW_TEXTURE = (ns.MapSearchData and ns.MapSearchData.STAR_GLOW_TEXTURE) or "Interface\\Cooldown\\star4"

local CreateFrame = CreateFrame
local GetMapInfo = C_Map.GetMapInfo
local GetMapChildrenInfo = C_Map.GetMapChildrenInfo
local GetMapInfoAtPosition = C_Map.GetMapInfoAtPosition
local GetMapParentID = MapUtils.GetParentMapID
local GetMapRectOnMap = C_Map.GetMapRectOnMap
local GetMapHighlightInfoAtPosition = C_Map.GetMapHighlightInfoAtPosition

local zoneHighlightFrame
function MapSearch:CreateZoneHighlightFrame()
    zoneHighlightFrame = CreateFrame("Frame", "EasyFindZoneHighlight", WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:SetFrameStrata("TOOLTIP")
    zoneHighlightFrame:SetFrameLevel(400)
    zoneHighlightFrame:SetAllPoints(WorldMapFrame.ScrollContainer.Child)
    -- Must not absorb clicks: at TOOLTIP strata, if the canvas extends
    -- under the MapTab side panel (maximized map), it would eat row clicks.
    zoneHighlightFrame:EnableMouse(false)
    zoneHighlightFrame:Hide()

    zoneHighlightFrame.highlights = {}

    for i = 1, 10 do
        local highlight = zoneHighlightFrame:CreateTexture("EasyFindZoneHighlight"..i, "OVERLAY")
        highlight:SetColorTexture(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.5)
        highlight:SetDrawLayer("OVERLAY", 7)
        highlight:Hide()
        zoneHighlightFrame.highlights[i] = highlight
    end

    MapFrames.AttachBounceAnimation(zoneHighlightFrame, { fromAlpha = 0.75, toAlpha = 0.5 })

    local zoneInd = MapFrames.CreateIndicatorFrame("EasyFindZoneIndicator", WorldMapFrame.ScrollContainer.Child, {
        strata = "TOOLTIP",
        level = 500,
        size = ns.ICON_SIZE,
        moveKey = "translateAnim",
    })

    zoneInd:Hide()
    zoneHighlightFrame.indicator = zoneInd
end

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

-- Handles zones not in a direct parent-child relationship (e.g. Stormwind
-- projected onto Elwynn Forest) via their shared continent.
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

-- Scan GetMapInfoAtPosition on viewMapID for targetMapID's tight bounds.
-- Uses the continent-projected rect (with padding) to limit API calls.
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
    local inset = step * 0.5
    return foundL + inset, foundR - inset, foundT + inset, foundB - inset
end

-- Orphan zones (Vision of Stormwind, etc.) return all zeros from
-- GetMapRectOnMap and have no continent projection. Bugged zones (Uldum,
-- Vale) return valid rects, so this won't match them.
local function IsOrphanZone(mapID)
    local info = GetMapInfo(mapID)
    if not info or not info.parentMapID then return false end
    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, mapID, info.parentMapID)
    if not ok or not left then return true end
    if left ~= 0 or right ~= 0 or top ~= 0 or bottom ~= 0 then return false end
    local pL, pR, pT, pB = GetMapRectViaContinent(mapID, info.parentMapID)
    if not pL then return true end
    return pL == 0 and pR == 0 and pT == 0 and pB == 0
end

-- A zone may exist under multiple mapIDs (TBC IQD 122 vs Midnight versions).
-- Find a same-named child of viewMapID that has a valid rect, else return
-- the original mapID unchanged.
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

-- minCount=2 finds a zone on 2+ sides (catches cities like Ironforge where
-- Dun Morogh surrounds 3/4 sides); minCount=1 finds the first hit (catches
-- Stormwind where only 1-2 probes hit a named zone).
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

-- Hover-only HighlightZone variant. Never calls SetMapID, never touches
-- pendingZoneHighlight; bails when the zone isn't on the current map or
-- when we're already viewing it.
function MapSearch:PreviewZoneHighlight(mapID)
    if not zoneHighlightFrame then return end
    if not WorldMapFrame or not WorldMapFrame.ScrollContainer then return end
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end

    local parentMapID = WorldMapFrame:GetMapID()
    if not parentMapID then return end

    local resolved = ResolveZoneForMap(mapID, parentMapID)
    if resolved ~= mapID then mapID = resolved end

    -- Direct-child only: ancestors/siblings/descendants produce glitchy rects.
    local zoneInfo = GetMapInfo(mapID)
    if not zoneInfo or zoneInfo.parentMapID ~= parentMapID then return end

    local ok, left, right, top, bottom = pcall(GetMapRectOnMap, mapID, parentMapID)
    if not ok or not left then return end

    if left == 0 and right == 0 and top == 0 and bottom == 0 then
        local pL, pR, pT, pB = GetMapRectViaContinent(mapID, parentMapID)
        if not pL then return end
        left, right, top, bottom = pL, pR, pT, pB
    end

    -- Reject degenerate or implausibly-large rects (ancestor escapees).
    if (right - left) < 0.01 or (bottom - top) < 0.01 then return end
    if (right - left) > 1.05 or (bottom - top) > 1.05 then return end
    if right < 0.02 or left > 0.98 or bottom < 0.02 or top > 0.98 then return end

    local clampedL = mmax(0, left)
    local clampedR = mmin(1, right)
    local clampedT = mmax(0, top)
    local clampedB = mmin(1, bottom)
    if (clampedR - clampedL) < 0.01 or (clampedB - clampedT) < 0.01 then return end
    -- Whole-canvas rect = "this zone is the entire view": no useful preview.
    if (clampedR - clampedL) >= 0.95 and (clampedB - clampedT) >= 0.95 then return end

    local canvasWidth, canvasHeight = canvas:GetSize()
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local zoneCenterPxX = centerX * canvasWidth
    local zoneCenterPxY = centerY * canvasHeight

    -- Hide pooled textures so prior-hover residue doesn't bleed through.
    for i = 1, #zoneHighlightFrame.highlights do
        local hl = zoneHighlightFrame.highlights[i]
        hl:Hide()
        hl:ClearAllPoints()
        hl:SetTexture(nil)
        hl:SetTexCoord(0, 1, 0, 1)
    end

    -- Falls back to a translucent rect when the texture belongs to a
    -- different zone (cities pick up the containing zone's outline).
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
        -- Fall back to a translucent rect (same path bugged zones use).
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

function MapSearch:HighlightZone(mapID)
    DebugPrint("[EasyFind] HighlightZone called for mapID:", mapID)

    if not zoneHighlightFrame then
        DebugPrint("[EasyFind] HighlightZone: no zoneHighlightFrame!")
        return
    end

    -- Save pending so we can still navigate after highlighting an intermediate.
    local savedPending = self.pendingZoneHighlight
    DebugPrint("[EasyFind] HighlightZone: saved pending:", savedPending)

    self:ClearZoneHighlight()

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

    -- Zeros = instanced or non-direct-parent zone; try continent projection.
    if left == 0 and right == 0 and top == 0 and bottom == 0 then
        local pL, pR, pT, pB = GetMapRectViaContinent(mapID, parentMapID)
        if pL then
            left, right, top, bottom = pL, pR, pT, pB
            DebugPrint("[EasyFind] HighlightZone: used continent projection for coords")
        else
            -- Blind scan handles continents on World (Draenor, Outland, etc.).
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

    -- Cities on continent maps pick up the containing zone's texture.
    if hasTexture and isZone then
        local resolvedInfo = GetMapInfoAtPosition(parentMapID, centerX, centerY)
        if resolvedInfo and resolvedInfo.mapID ~= mapID then
            hasTexture = false
        end
    end

    -- Cities have no highlight texture and sit inside another zone (IF/Dun
    -- Morogh, Org/Durotar); find the containing zone by sampling. Bugged
    -- zones (Uldum, Vale) are detected by their center returning a continent.
    if not hasTexture and isZone then
        local parentMapInfo = GetMapInfo(parentMapID)
        if parentMapInfo and parentMapInfo.mapType == Enum.UIMapType.Continent then
            local cx = (left + right) * 0.5
            local cy = (top + bottom) * 0.5
            local centerInfo = GetMapInfoAtPosition(parentMapID, cx, cy)
            local isBuggedZone = not centerInfo
                or centerInfo.mapType ~= Enum.UIMapType.Zone
            if not isBuggedZone then
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

            -- Some cities barely register via GetMapInfoAtPosition, so
            -- keep the projection as fallback when the scan is too small.
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

        -- Skip the border box on final targets (cities, etc.): arrow-only.
        local isFinalTarget = self.pendingZoneHighlight == mapID

        -- Click overlay is the only way into WoW-bugged zones (Uldum, Vale).
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

        if isFinalTarget and not hasTexture then
            if not zoneHighlightFrame.centerGlow then
                local glow = canvas:CreateTexture(nil, "ARTWORK")
                glow:SetTexture(STAR_GLOW_TEXTURE)
                glow:SetVertexColor(YELLOW_HIGHLIGHT[1], YELLOW_HIGHLIGHT[2], YELLOW_HIGHLIGHT[3], 0.4)
                glow:SetBlendMode("ADD")
                zoneHighlightFrame.centerGlow = glow
                zoneHighlightFrame.centerGlowAnim = MapFrames.AttachBounceAnimation(glow, {
                    fromAlpha = 0.25,
                    toAlpha = 0.55,
                    duration = 0.8,
                    smoothing = "IN_OUT",
                })
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

    if zoneHighlightFrame.indicator then
        local zoneInd = zoneHighlightFrame.indicator
        local userScale = EasyFind.db.iconScale or 0.8
        local indicatorSize     = ns.UIToCanvas(ns.ZONE_ICON_SIZE)      * userScale
        local indicatorGlowSize = ns.UIToCanvas(ns.ZONE_ICON_GLOW_SIZE) * userScale
        zoneInd:SetSize(indicatorSize, indicatorSize)
        zoneInd:SetFrameStrata("TOOLTIP")
        zoneInd:SetFrameLevel(500)
        if zoneInd.glow then
            zoneInd.glow:SetSize(indicatorGlowSize, indicatorGlowSize)
        end
        -- Don't override color/texture: ns.UpdateIndicator handles it via OnShow.
        local margin = 50

        zoneInd:ClearAllPoints()

        DebugPrint("[EasyFind] HighlightZone: indicator positioning - zoneTopPx:", zoneTopPx, "margin+indicatorSize:", margin + indicatorSize)

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

-- preserveBreadcrumb=true keeps the click-driven breadcrumb so a hover
-- exit doesn't wipe the gold guide the user is following.
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
        self.breadcrumbHighlight:Hide()
    end

    -- pendingWaypoint must survive: it's the final destination through the chain.
    self.pendingZoneHighlight = nil
end

function MapSearch:IsOnContinentMap()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return false end

    local mapInfo = GetMapInfo(mapID)
    if not mapInfo then return false end

    return mapInfo.mapType == Enum.UIMapType.Continent or mapInfo.mapType == Enum.UIMapType.World
end


function MapSearch:GetZoneHighlightFrame()
    return zoneHighlightFrame
end

MapSearch.GetContinentForMap = function(_, mapID) return GetContinentForMap(mapID) end
MapSearch.GetMapRectViaContinent = function(_, mapID, viewMapID) return GetMapRectViaContinent(mapID, viewMapID) end
MapSearch.IsOrphanZone = function(_, mapID) return IsOrphanZone(mapID) end
MapSearch.ResolveZoneForMap = function(_, mapID, viewMapID) return ResolveZoneForMap(mapID, viewMapID) end
MapSearch.FindSurroundingZone = function(_, parentMapID, mapID, left, right, top, bottom, minCount)
    return FindSurroundingZone(parentMapID, mapID, left, right, top, bottom, minCount)
end
