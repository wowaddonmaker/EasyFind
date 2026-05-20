local _, ns = ...

local Data = ns.MapSearchData or {}
local Utils = ns.Utils or {}
local unpack = unpack
local mpi = Utils.mpi or math.pi

local STAR_GLOW_TEXTURE = Data.STAR_GLOW_TEXTURE or "Interface\\Cooldown\\star4"
local INDICATOR_STYLES = Data.INDICATOR_STYLES or {}
local INDICATOR_COLORS = Data.INDICATOR_COLORS or {}

local function GetIndicatorColor()
    local colorName = EasyFind.db.indicatorColor or "Yellow"
    return INDICATOR_COLORS[colorName] or INDICATOR_COLORS["Yellow"]
end

ns.GetIndicatorTexture = function()
    local style = EasyFind.db.indicatorStyle or "EasyFind Arrow"
    return INDICATOR_STYLES[style] or INDICATOR_STYLES["EasyFind Arrow"]
end
ns.GetIndicatorColor = GetIndicatorColor

-- All sizes in UI coordinate units; UIToCanvas converts so visual size matches.
ns.ICON_SIZE = 48
ns.ICON_GLOW_SIZE = 68
ns.PIN_SIZE = 28
ns.PIN_GLOW_SIZE = 40
ns.HIGHLIGHT_SIZE = 30

ns.MULTI_SCALE = 1.0

ns.ZONE_ICON_SIZE = 48
ns.ZONE_ICON_GLOW_SIZE = 68

ns.BREADCRUMB_SIZE = 48

-- WoW's map zooms by enlarging the canvas, not by changing scale, so the
-- conversion is canvasWidth / viewportWidth.
function ns.UIToCanvas(uiSize)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc or not sc.Child then return uiSize end
    local canvasW = sc.Child:GetWidth()
    local viewportW = sc:GetWidth()
    if not canvasW or canvasW == 0 or not viewportW or viewportW == 0 then
        return uiSize
    end
    return uiSize * (canvasW / viewportW)
end

-- Every indicator icon (map search, zone search, UI search, breadcrumb) must
-- use these two functions so they all look identical.
function ns.CreateIndicatorTextures(parentFrame, iconSize, glowSize)
    iconSize = iconSize or ns.ICON_SIZE
    glowSize = glowSize or ns.ICON_GLOW_SIZE
    local style = ns.GetIndicatorTexture()
    local color = GetIndicatorColor()
    local ox, oy = style.offsetX or 0, style.offsetY or 0

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

    if glowSize and glowSize > 0 then
        local glow = parentFrame:CreateTexture(nil, "BACKGROUND")
        glow:SetSize(glowSize, glowSize)
        glow:SetPoint("CENTER")
        glow:SetTexture(STAR_GLOW_TEXTURE)
        glow:SetVertexColor(color[1], color[2], color[3], 0.35)
        glow:SetBlendMode("ADD")
        parentFrame.glow = glow
    end

    parentFrame:HookScript("OnShow", function(self)
        ns.UpdateIndicator(self)
    end)
end

function ns.UpdateIndicator(parentFrame)
    if not parentFrame or not parentFrame.indicator then return end
    local style = ns.GetIndicatorTexture()
    local color = GetIndicatorColor()
    local tex = parentFrame.indicator
    local ox, oy = style.offsetX or 0, style.offsetY or 0

    tex:SetTexture(style.texture)
    if style.texCoord then
        tex:SetTexCoord(unpack(style.texCoord))
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
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

    -- Frames get resized at show time; the texture must match.
    local fw, fh = parentFrame:GetSize()
    if fw and fw > 0 then
        tex:SetSize(fw, fh)
    end

    if parentFrame.glow then
        parentFrame.glow:SetVertexColor(color[1], color[2], color[3], 0.35)
    end

    -- Map indicators handle scale in their own sizing code.
    if parentFrame.isUIIndicator then
        parentFrame:SetScale(EasyFind.db.iconScale or 0.8)
    end
end

function ns.GetDirectionalRotation(direction)
    local style = ns.GetIndicatorTexture()
    -- baseDown is the rotation that points the indicator downward.
    local baseDown = style.rotation or (style.preRotated and 0 or mpi)
    if direction == "down" then
        return baseDown
    elseif direction == "up" then
        return baseDown + mpi
    elseif direction == "right" then
        return baseDown - mpi / 2
    elseif direction == "left" then
        return baseDown + mpi / 2
    end
    return baseDown
end