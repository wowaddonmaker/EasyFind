-- EasyFind_Onboarding companion file; see TutorialWizard.lua for the load
-- contract.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

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
--       id = "snippets31",               -- db.spotlightsDone key
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
local wipe = wipe

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

-- The "NEW" tag: white text, cyan shadow, pulsing cyan glow behind it
-- (only the glow animates). One per spotlight, repositioned per step by
-- the step's tagPlace. Non-interactive on purpose: both targets carry
-- their own hover behavior, and the tag must never steal it.
local tagFrames = {}

local function GetTag(id)
    local tag = tagFrames[id]
    if tag then return tag end
    tag = CreateFrame("Frame", nil, UIParent)
    tag:SetFrameStrata("TOOLTIP")
    tag:EnableMouse(false)
    local text = tag:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER")
    text:SetText(_G["NEW"] or "New")
    text:SetTextColor(1, 1, 1)
    text:SetShadowColor(0.3, 0.9, 1.0, 1)
    text:SetShadowOffset(1, -1)
    tag:SetSize(text:GetStringWidth() + 4, 14)
    local glow = tag:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(text:GetStringWidth() + 28, 24)
    glow:SetAtlas("collections-newglow")
    glow:SetVertexColor(0.3, 0.85, 1.0, 0.5)
    glow:SetBlendMode("ADD")
    local anim = glow:CreateAnimationGroup()
    anim:SetLooping("BOUNCE")
    local alpha = anim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.8)
    alpha:SetToAlpha(0.1)
    alpha:SetDuration(1.5)
    tag.anim = anim
    tag:Hide()
    tagFrames[id] = tag
    return tag
end

local function HideTag(id)
    local tag = tagFrames[id]
    if tag then
        tag.anim:Stop()
        tag:Hide()
        tag:SetParent(UIParent)
        tag:ClearAllPoints()
    end
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

local function ShowTagOn(id, target, place)
    if not place then HideTag(id) return end
    local tag = GetTag(id)
    tag:SetParent(target)
    tag:SetFrameLevel((target:GetFrameLevel() or 1) + 6)
    tag:ClearAllPoints()
    place(tag, target)
    tag:Show()
    tag.anim:Play()
end

local function HidePulse(id)
    local pulse = pulseFrames[id]
    if pulse then
        pulse.anim:Stop()
        pulse:Hide()
        pulse:SetParent(UIParent)
        pulse:ClearAllPoints()
    end
    HideTag(id)
end

function Spotlight:Register(def)
    if not (def and def.id and def.steps) then return end
    registered[def.id] = def
end

-- Re-evaluate every spotlight: the LAST step whose target resolves to a
-- visible frame carries the pulse (deeper step = further along the click
-- path), so opening the menu moves the glow from the button to the row.
-- Two pending spotlights can share an early step's target (the apps
-- button); only the first claimant draws there, so glows and tags never
-- stack on one frame. Their deeper steps are distinct rows, where each
-- gets its own pulse.
local claimedTargets = {}

function Spotlight:Refresh()
    wipe(claimedTargets)
    for id, def in pairs(registered) do
        if IsDone(id) then
            HidePulse(id)
        else
            local target, place
            for i = 1, #def.steps do
                local ok, frame = pcall(def.steps[i])
                if ok and frame and frame.IsVisible and frame:IsVisible() then
                    target = frame
                    place = def.tagPlace and def.tagPlace[i] or nil
                end
            end
            if target and not claimedTargets[target] then
                claimedTargets[target] = true
                ShowPulseOn(id, target)
                ShowTagOn(id, target, place)
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
    -- Spotlights announce features to UPDATING users only. A fresh install
    -- meets the current feature set in the tutorial itself (the Apps deck
    -- covers Snippets), so a pending tutorial marks every current
    -- spotlight done up front instead of pulsing at a brand-new user.
    if EasyFind and EasyFind.db and not EasyFind.db.tutorialDone then
        EasyFind.db.spotlightsDone = EasyFind.db.spotlightsDone or {}
        EasyFind.db.spotlightsDone.snippets31 = true
    end
    -- ONE spotlight per release: 3.1.0 retires the Icon Search pointer
    -- (its registration is gone; the Complete call in ShowIconGrid no-ops
    -- on the unregistered id) so the New tag always means the CURRENT
    -- release's feature.

    -- 3.1.0: Snippets. Two-step path: the apps button
    -- pulses, then the Snippets row takes over while the menu is open.
    -- Completed by reaching the snippets tab through any front door
    -- (Options:OpenAtSnippets is the single funnel).
    self:Register{
        id = "snippets31",
        steps = {
            function()
                -- The snippets tab lives in the options companion; never
                -- point at a feature whose companion can't load.
                if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Options") then
                    return nil
                end
                local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
                return sf and sf.appsBtn
            end,
            function()
                local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
                local dropdown = sf and sf.appsDropdown
                if not (dropdown and dropdown:IsShown() and dropdown.rows) then return nil end
                for i = 1, #dropdown.rows do
                    local row = dropdown.rows[i]
                    if row:IsShown() and row.app and row.app.snippetsLauncher then
                        return row
                    end
                end
            end,
        },
        tagPlace = {
            function(tag, target)
                tag:SetPoint("BOTTOM", target, "TOP", 0, -3)
            end,
            function(tag, target)
                local label = target.label
                if label then
                    tag:SetPoint("LEFT", label, "LEFT", label:GetStringWidth() + 4, 0)
                else
                    tag:SetPoint("RIGHT", target, "RIGHT", -4, 0)
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

-- Self-init: the companion loads on demand (pending onboarding at login,
-- or /ef setup), so the pcall wrapper Core gives login-time Initialize
-- calls is applied here instead.
local initOk, initErr = pcall(function() Spotlight:Initialize() end)
if not initOk then
    ns.Utils.DebugPrint("FeatureSpotlight init failed: " .. tostring(initErr))
end

return Spotlight
