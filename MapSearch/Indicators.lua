local _, ns = ...

local Utils = ns.Utils
local unpack = unpack
local mpi = Utils.mpi or math.pi

local STAR_GLOW_TEXTURE = "Interface\\Cooldown\\star4"
ns.MAP_SEARCH_STAR_GLOW_TEXTURE = STAR_GLOW_TEXTURE
local INDICATOR_STYLES = {
    ["Classic Quest Arrow"] = {
        texture = "Interface\\MINIMAP\\MiniMap-QuestArrow",
        texCoord = nil,
        preRotated = false,
    },
    ["EasyFind Arrow"] = {
        texture = "Interface\\AddOns\\EasyFind\\MapSearch\\Images\\arrow-hq",
        texCoord = nil,
        preRotated = true,
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
        offsetX = 0,
        offsetY = 0,
    },
    ["HD Gauntlet"] = {
        texture = 6116532,
        texCoord = {0.000, 0.240, 0.000, 0.420},
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,
        offsetY = 0,
    },
}

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

ns.INDICATOR_COLORS = INDICATOR_COLORS

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
    ind:SetVertexColor(Utils.RGB(color, 1))
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
        glow:SetVertexColor(Utils.RGB(color, 0.35))
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
    tex:SetVertexColor(Utils.RGB(color, 1))
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", parentFrame, "CENTER", ox, oy)

    -- Frames get resized at show time; the texture must match.
    local fw, fh = parentFrame:GetSize()
    if fw and fw > 0 then
        tex:SetSize(fw, fh)
    end

    if parentFrame.glow then
        parentFrame.glow:SetVertexColor(Utils.RGB(color, 0.35))
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
