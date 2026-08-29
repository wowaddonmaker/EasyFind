local _, ns = ...

-- Feature spotlight engine: a persistent click-through nudge for a newly
-- shipped feature (the coach-mark pattern). A spotlight names an ordered
-- chain of TARGETS; the first resolvable one wears a pulsing glow (plus
-- the standard NEW badge treatment where a label fits) until the user
-- completes the feature's entry action, which stamps it done in saved
-- variables forever. Later steps light up as the user progresses (open
-- the apps menu and the glow moves from the button to the app's row).
--
-- Registering a spotlight:
--   ns.FeatureSpotlight:Register{
--       id = "iconSearch30",             -- db.spotlightsDone key
--       steps = {                        -- LAST resolvable step wins
--           function() return <frame or nil> end,
--           ...
--       },
--   }
-- Call ns.FeatureSpotlight:Refresh() from the OnShow/OnHide of anything
-- that changes which step is visible, and
-- ns.FeatureSpotlight:Complete(id) from the feature's entry points.

local Spotlight = {}
ns.FeatureSpotlight = Spotlight

local Utils = ns.Utils
local CreateFrame = CreateFrame

local registered = {}
local pulseFrames = {}

local function IsDone(id)
    local done = EasyFind and EasyFind.db and EasyFind.db.spotlightsDone
    return done and done[id] or false
end

-- One pooled pulse per spotlight: the NEW-badge glow treatment (cyan
-- collections-newglow, ADD, alpha bounce) stretched around the target.
-- Pure visual: no mouse, so it can parent to the target safely.
local function GetPulse(id)
    local pulse = pulseFrames[id]
    if pulse then return pulse end
    pulse = CreateFrame("Frame", nil, UIParent)
    pulse:SetFrameStrata("DIALOG")
    local glow = pulse:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints()
    glow:SetAtlas("collections-newglow")
    glow:SetVertexColor(0.3, 0.85, 1.0, 0.6)
    glow:SetBlendMode("ADD")
    local anim = glow:CreateAnimationGroup()
    anim:SetLooping("BOUNCE")
    local alpha = anim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.9)
    alpha:SetToAlpha(0.15)
    alpha:SetDuration(0.9)
    pulse.anim = anim
    pulse:Hide()
    pulseFrames[id] = pulse
    return pulse
end

local function ShowPulseOn(id, target)
    local pulse = GetPulse(id)
    pulse:SetParent(target)
    pulse:SetFrameLevel((target:GetFrameLevel() or 1) + 5)
    pulse:ClearAllPoints()
    -- The glow atlas fades to transparent well inside its rect; oversize
    -- it so the visible halo hugs the target instead of hiding under it.
    pulse:SetPoint("TOPLEFT", target, "TOPLEFT", -14, 10)
    pulse:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 14, -10)
    pulse:Show()
    pulse.anim:Play()
end

local function HidePulse(id)
    local pulse = pulseFrames[id]
    if pulse then
        pulse.anim:Stop()
        pulse:Hide()
        pulse:SetParent(UIParent)
        pulse:ClearAllPoints()
    end
end

function Spotlight:Register(def)
    if not (def and def.id and def.steps) then return end
    registered[def.id] = def
end

-- Re-evaluate every spotlight: the LAST step whose target resolves to a
-- visible frame carries the pulse (deeper step = further along the click
-- path), so opening the menu moves the glow from the button to the row.
function Spotlight:Refresh()
    for id, def in pairs(registered) do
        if IsDone(id) then
            HidePulse(id)
        else
            local target
            for i = 1, #def.steps do
                local ok, frame = pcall(def.steps[i])
                if ok and frame and frame.IsVisible and frame:IsVisible() then
                    target = frame
                end
            end
            if target then
                ShowPulseOn(id, target)
            else
                HidePulse(id)
            end
        end
    end
end

function Spotlight:Complete(id)
    if not registered[id] or IsDone(id) then return end
    if EasyFind and EasyFind.db then
        EasyFind.db.spotlightsDone = EasyFind.db.spotlightsDone or {}
        EasyFind.db.spotlightsDone[id] = true
    end
    HidePulse(id)
end

function Spotlight:Initialize()
    -- 3.0.0: Icon Search. Step 1 pulses the apps button whenever the bar
    -- is up; step 2 takes over on the Icon Search row while the apps menu
    -- is open. Completed by reaching the grid through ANY entry point
    -- (menu row, launcher row, typed @icons) -- see ShowIconGrid.
    self:Register{
        id = "iconSearch30",
        steps = {
            function()
                local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
                return sf and sf.appsBtn
            end,
            function()
                local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
                local dropdown = sf and sf.appsDropdown
                if not (dropdown and dropdown:IsShown() and dropdown.rows) then return nil end
                for i = 1, #dropdown.rows do
                    local row = dropdown.rows[i]
                    if row:IsShown() and row.app and row.app.iconSearchLauncher then
                        return row
                    end
                end
            end,
        },
    }

    -- Deferred: the bar and menus are built by their own init; hook their
    -- visibility changes once everything exists.
    Utils.SafeAfter(0, function()
        local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
        if not sf then return end
        sf:HookScript("OnShow", function() Spotlight:Refresh() end)
        sf:HookScript("OnHide", function() Spotlight:Refresh() end)
        if sf.appsDropdown then
            sf.appsDropdown:HookScript("OnShow", function() Spotlight:Refresh() end)
            sf.appsDropdown:HookScript("OnHide", function() Spotlight:Refresh() end)
        end
        Spotlight:Refresh()
    end)
end

return Spotlight
