local _, ns = ...

local TutorialBox = {}
ns.TutorialBox = TutorialBox

local BORDER_R, BORDER_G, BORDER_B = 1.0, 0.98, 0.45
local TEXT_R,   TEXT_G,   TEXT_B   = 1.0, 0.96, 0.15
local TEX_CORNER = "Interface\\AddOns\\EasyFind\\textures\\glow-corner"
local TEX_EDGE_H = "Interface\\AddOns\\EasyFind\\textures\\glow-edge-h"
local TEX_EDGE_V = "Interface\\AddOns\\EasyFind\\textures\\glow-edge-v"
local CORNER_SZ  = 16
local HALF       = 8

local mmin = math.min

function TutorialBox.ApplyStyle(target, opts)
    opts = opts or {}
    target:SetIgnoreParentAlpha(true)

    local interior = target:CreateTexture(nil, "BACKGROUND", nil, 2)
    interior:SetAllPoints(target)
    interior:SetColorTexture(1, 1, 1, 1)
    interior:SetGradient("VERTICAL",
        CreateColor(0.32, 0.26, 0.02, 0.94),
        CreateColor(0.00, 0.00, 0.00, 0.96))

    local glow = CreateFrame("Frame", nil, target)
    glow:SetAllPoints(target)

    local function addCorner(anchor, dx, dy, texL, texR, texT, texB)
        local t = glow:CreateTexture(nil, "BORDER")
        t:SetTexture(TEX_CORNER)
        t:SetTexCoord(texL, texR, texT, texB)
        t:SetVertexColor(BORDER_R, BORDER_G, BORDER_B)
        t:SetSize(CORNER_SZ, CORNER_SZ)
        t:SetPoint(anchor, target, anchor, dx, dy)
    end
    addCorner("TOPLEFT",     -HALF,  HALF, 0, 1, 0, 1)
    addCorner("TOPRIGHT",     HALF,  HALF, 1, 0, 0, 1)
    addCorner("BOTTOMLEFT",  -HALF, -HALF, 0, 1, 1, 0)
    addCorner("BOTTOMRIGHT",  HALF, -HALF, 1, 0, 1, 0)

    local function addHEdge(anchorL, anchorR, flipY)
        local t = glow:CreateTexture(nil, "BORDER")
        t:SetTexture(TEX_EDGE_H)
        if flipY then t:SetTexCoord(0, 1, 1, 0) else t:SetTexCoord(0, 1, 0, 1) end
        t:SetVertexColor(BORDER_R, BORDER_G, BORDER_B)
        t:SetPoint("TOPLEFT",     target, anchorL,  HALF,  HALF)
        t:SetPoint("BOTTOMRIGHT", target, anchorR, -HALF, -HALF)
    end
    addHEdge("TOPLEFT",    "TOPRIGHT",    false)
    addHEdge("BOTTOMLEFT", "BOTTOMRIGHT", true)

    local function addVEdge(anchorT, anchorB, flipX)
        local t = glow:CreateTexture(nil, "BORDER")
        t:SetTexture(TEX_EDGE_V)
        if flipX then t:SetTexCoord(1, 0, 0, 1) else t:SetTexCoord(0, 1, 0, 1) end
        t:SetVertexColor(BORDER_R, BORDER_G, BORDER_B)
        t:SetPoint("TOPLEFT",     target, anchorT, -HALF, -HALF)
        t:SetPoint("BOTTOMRIGHT", target, anchorB,  HALF,  HALF)
    end
    addVEdge("TOPLEFT",  "BOTTOMLEFT",  false)
    addVEdge("TOPRIGHT", "BOTTOMRIGHT", true)

    if not opts.noPulse then
        local pulseAG = glow:CreateAnimationGroup()
        pulseAG:SetLooping("BOUNCE")
        local pulseAnim = pulseAG:CreateAnimation("Alpha")
        pulseAnim:SetFromAlpha(0.65)
        pulseAnim:SetToAlpha(1.0)
        pulseAnim:SetDuration(0.9)
        pulseAnim:SetSmoothing("IN_OUT")
        pulseAG:Play()
        target:HookScript("OnShow", function() pulseAG:Restart() end)
    end

    return glow
end

local CHEVRON_TEXTURE          = "Interface\\AddOns\\EasyFind\\textures\\chevron"
local CHEVRON_GLOW_TEXTURE     = "Interface\\AddOns\\EasyFind\\textures\\chevron-glow"
local DEFAULT_POINTER_TRAVEL   = 32
local DEFAULT_POINTER_DURATION = 1.5
local DEFAULT_GLOW_ALPHA       = 0.35
-- Slightly more orange than GOLD_COLOR so the halo reads as a warm
-- ember behind the gold core instead of the same hue twice.
local DEFAULT_GLOW_COLOR       = { 1.0, 0.60, 0.10 }

-- Per-direction geometry for AttachPointer:
--   rotation : SetRotation angle so the TGA's downward apex faces `direction`
--   texEdge  : which side of the texture rect sits flush with the box border
--              (the "back" edge, opposite the apex direction)
--   boxEdge  : the box edge the chevron anchors to (target-side)
--   axisX/Y  : signed unit vector of the travel direction (WoW y is +up)
local DIRECTION_DATA = {
    right = { rotation =  math.pi / 2, texEdge = "LEFT",   boxEdge = "RIGHT",  axisX =  1, axisY =  0 },
    left  = { rotation = -math.pi / 2, texEdge = "RIGHT",  boxEdge = "LEFT",   axisX = -1, axisY =  0 },
    up    = { rotation =  math.pi,     texEdge = "BOTTOM", boxEdge = "TOP",    axisX =  0, axisY =  1 },
    down  = { rotation =  0,           texEdge = "TOP",    boxEdge = "BOTTOM", axisX =  0, axisY = -1 },
}

-- Attach an animated chevron pointer to `box`, pointing in `opts.direction`
-- ("right" | "left" | "up" | "down"). At phase 0 a chevron group's
-- trail-back sits flush with the box's direction-side border, so the
-- origin is invariant to box size and to chevron-size tuning in the
-- TGA. Over each cycle a group translates `opts.travel` pixels toward
-- the target, reaching the final position after `opts.duration` seconds,
-- with alpha fading from 1 to 0.
--
-- opts.count (default 1) spawns multiple chevron groups evenly
-- phase-staggered by 1/count of a cycle, so a fresh one is born every
-- duration/count seconds while the previous one is still fading out.
-- Creates the appearance of an infinite cascade instead of a single
-- bouncing group.
--
-- opts.fadeStart (default 0) is the phase [0, 1) at which alpha begins
-- dropping from 1 toward 0; alpha is held at 1 before that. End-of-cycle
-- is always fully transparent regardless of fadeStart. 0.75 means the
-- group stays bright for the first 75% of its travel and fades over the
-- final 25%.
--
-- opts.startOffset (default 0) shifts the origin (phase-0 trail-back
-- position) by that many pixels in the travel direction. Positive
-- pushes the starting point further toward the target; negative pulls
-- it back into the box. The end point is held fixed: the effective
-- per-cycle slide becomes (travel - startOffset), so the apex still
-- ends where it would with startOffset = 0.
--
-- opts.easing (default 1) is the exponent applied to phase when mapping
-- to slide distance (slide = travel * phase^easing). 1 = linear (constant
-- speed). >1 accelerates: the group moves slowly at first, then faster
-- toward the end. <1 decelerates. The alpha fade curve stays on the
-- unmapped phase, so fade timing is unaffected.
--
-- opts.glow controls an optional additive halo built from the pre-
-- rendered chevron-glow.tga (trail-apex position, trail angle, legs
-- trimmed to end just past the lead's leg-ends via GLOW_OVERHANG, and
-- softened with a box blur). Pass `true` for the default alpha, a
-- number in (0, 1] to set alpha directly, or false/nil to disable.
-- opts.glowColor (default warm orange) tints the halo.
--
-- opts.onPhase(phase) is called each tick with the base cycle phase
-- [0, 1), so callers can sync other animations (e.g. a pulsing glow).
-- A fresh group is born whenever (phase * count) crosses an integer.
--
-- The chevron renders above the tutorial box's own strata, so it stays
-- visible if `travel` pushes it partially over the box's border.
--
-- Returns { frame, textures, texture = textures[1], Stop(), Show() }.
function TutorialBox.AttachPointer(box, opts)
    opts = opts or {}
    local dir = DIRECTION_DATA[opts.direction or "right"]
    if not dir then
        error("TutorialBox.AttachPointer: direction must be 'right', 'left', 'up', or 'down'", 2)
    end

    local travel      = opts.travel      or DEFAULT_POINTER_TRAVEL
    local duration    = opts.duration    or DEFAULT_POINTER_DURATION
    local count       = opts.count       or 1
    local fadeStart   = opts.fadeStart   or 0
    local startOffset = opts.startOffset or 0
    local easing      = opts.easing      or 1
    local color       = opts.color       or ns.GOLD_COLOR or { 1.0, 0.82, 0.0 }
    local fadeRange   = 1 - fadeStart

    local glowAlpha
    if opts.glow == true then
        glowAlpha = DEFAULT_GLOW_ALPHA
    elseif type(opts.glow) == "number" then
        glowAlpha = opts.glow
    end
    local glowColor = opts.glowColor or DEFAULT_GLOW_COLOR

    local texSize   = ns.CHEVRON_TEX_SIZE   or 64
    local apexInset = ns.CHEVRON_APEX_INSET or 0

    local driver = CreateFrame("Frame", nil, box)
    driver:SetSize(1, 1)
    driver:SetPoint("CENTER", box, "CENTER", 0, 0)
    driver:SetIgnoreParentAlpha(true)
    driver:SetFrameStrata(box:GetFrameStrata())
    driver:SetFrameLevel(box:GetFrameLevel() + 5)

    local groups   = {}
    local chevrons = {}
    for i = 1, count do
        local group = {}

        local core = driver:CreateTexture(nil, "OVERLAY", nil, 0)
        core:SetSize(texSize, texSize)
        core:SetTexture(CHEVRON_TEXTURE)
        core:SetVertexColor(color[1], color[2], color[3])
        core:SetRotation(dir.rotation)
        -- Additive blend so the core reads as luminous (adds light to
        -- whatever sits beneath it) instead of a solid painted-on shape.
        -- Matches the glow's blend mode, keeping the whole chevron in
        -- the same "warm ember" visual family.
        core:SetBlendMode("ADD")
        group.core = core
        chevrons[i] = core

        if glowAlpha then
            local glow = driver:CreateTexture(nil, "OVERLAY", nil, -1)
            glow:SetSize(texSize, texSize)
            glow:SetTexture(CHEVRON_GLOW_TEXTURE)
            glow:SetVertexColor(glowColor[1], glowColor[2], glowColor[3])
            glow:SetRotation(dir.rotation)
            glow:SetBlendMode("ADD")
            group.glow = glow
        end

        groups[i] = group
    end

    -- At phase 0 the trail-back sits `apexInset` pixels inside the
    -- texture's back edge, so we offset that edge by -apexInset toward
    -- the target to make the trail-back flush with the box border.
    -- Adding `travel * phase` slides the group further in-direction.
    -- Group i runs at phase = (basePhase + (i-1)/count) % 1.
    local onPhase = opts.onPhase
    local elapsed = 0
    driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        local basePhase = (elapsed / duration) % 1
        local slideRange = travel - startOffset
        for i = 1, count do
            local phase = (basePhase + (i - 1) / count) % 1
            local slide = startOffset + slideRange * phase ^ easing
            local offsetX = dir.axisX * (-apexInset + slide)
            local offsetY = dir.axisY * (-apexInset + slide)
            local alpha = 1
            if fadeRange > 0 and phase > fadeStart then
                alpha = (1 - phase) / fadeRange
            end

            local group = groups[i]
            group.core:ClearAllPoints()
            group.core:SetPoint(dir.texEdge, box, dir.boxEdge, offsetX, offsetY)
            group.core:SetAlpha(alpha)

            if group.glow then
                -- Glow TGA has the trail apex at the same pixel coord as
                -- the core TGA, so the same anchor offset places it
                -- correctly; the glow's longer legs simply extend past
                -- the core's silhouette on either side.
                group.glow:ClearAllPoints()
                group.glow:SetPoint(dir.texEdge, box, dir.boxEdge, offsetX, offsetY)
                group.glow:SetAlpha(alpha * glowAlpha)
            end
        end
        if onPhase then onPhase(basePhase) end
    end)

    local pointer = { frame = driver, textures = chevrons, texture = chevrons[1] }
    function pointer:Stop()
        driver:SetScript("OnUpdate", nil)
        driver:Hide()
    end
    function pointer:Show()
        driver:Show()
    end
    return pointer
end

function TutorialBox.Create(parent, textFont)
    local f = CreateFrame("Frame", nil, parent or UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(1000)

    TutorialBox.ApplyStyle(f)

    f.fs = f:CreateFontString(nil, "OVERLAY", textFont or "GameFontNormalLarge")
    f.fs:SetPoint("TOPLEFT",     f, "TOPLEFT",     16, -12)
    f.fs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16,  12)
    f.fs:SetJustifyH("CENTER")
    f.fs:SetJustifyV("MIDDLE")
    f.fs:SetTextColor(TEXT_R, TEXT_G, TEXT_B, 1.0)
    f.fs:SetShadowColor(0, 0, 0, 1)
    f.fs:SetShadowOffset(1, -1)

    f.SetAutoSized = function(self, maxWidth)
        maxWidth = maxWidth or 380
        self.fs:ClearAllPoints()
        self.fs:SetPoint("CENTER", self, "CENTER", 0, 0)
        self.fs:SetWidth(maxWidth - 32)
        local w = mmin(self.fs:GetStringWidth() + 32, maxWidth)
        local h = self.fs:GetStringHeight() + 24
        self:SetSize(w, h)
    end

    -- Marker so cursor-hover helpers can detect tutorial boxes and
    -- anchor the cursor sprite outside the frame (tip at the bottom
    -- border, body below) instead of covering text in the middle.
    f._isTutorialBox = true

    return f
end
