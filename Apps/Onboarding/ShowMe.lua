-- EasyFind_Onboarding companion file; see TutorialWizard.lua for the load
-- contract.
--
-- "Show me": a scripted, real-time demonstration of a feature, played on
-- the user's own screen. A fake cursor moves, clicks and drags through the
-- real UI (the search bar, the extensions menu, the buttons); the only
-- text on screen is a small "Esc to stop" hint, placed where it covers
-- nothing the demonstration uses; and when the script ends the screen is
-- exactly as it was. Scripts register here (see ShowMeScripts.lua) and
-- the What's New popup offers a "Show me" button beside any feature that
-- has one.
--
-- Rules the engine enforces:
--   * One show at a time. Escape or any real mouse click stops it, and
--     stopping always runs the script's cleanup.
--   * Everything is cancellable: timers and cursor moves carry the show's
--     generation and go dead the moment it stops.
--   * The engine never takes keyboard input. Escape reaches it through
--     the addon's own ESC override (Utils.AttachEscClose on the hint
--     frame, shown while a show plays); never UISpecialFrames, which
--     taints the game's CloseWindows for the session.
--   * Drags drive the real modules through their virtual mouse
--     (ExtensionButtons:SetVirtualMouse), never by faking events.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local ShowMe = {}
ns.ShowMe = ShowMe

local L = ns.L

local CreateFrame = CreateFrame
local UIParent = UIParent
local tinsert, tremove = table.insert, table.remove
local pcall = pcall
local geterrorhandler = _G.geterrorhandler

local function Report(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) end
end

local CURSOR_TEX = 4489300          -- the HD gauntlet, natural orientation
local CURSOR_COORDS = { 0, 0.2315, 0, 0.4104 }
local CURSOR_SIZE = 36
local HINT_NAME = "EasyFindShowMeHint"
local HINT_PAD_X, HINT_PAD_Y = 12, 7
local HINT_MARGIN = 16              -- clearance from anything the show uses
local MOVE_DEFAULT = 0.7
local END_PAUSE = 0.6
local SAY_FADE_IN, SAY_FADE_OUT = 0.15, 0.3

local scripts = {}
local state            -- nil, or the live show
local cursor, hint, tick, say

-- ==== registry ==============================================================

-- def = { steps = { { run = function(api, done) }, ... },
--         prepare = function(api) end,   -- optional, before step 1
--         cleanup = function(api) end }  -- always, on stop
function ShowMe:Register(id, def)
    if not (id and def and def.steps) then return end
    scripts[id] = def
end

function ShowMe:Has(id)
    return scripts[id] ~= nil
end

function ShowMe:IsPlaying()
    return state ~= nil
end

-- ==== frames ================================================================

local function EnsureCursor()
    if cursor then return cursor end
    cursor = CreateFrame("Frame", nil, UIParent)
    cursor:SetSize(CURSOR_SIZE, CURSOR_SIZE)
    cursor:SetFrameStrata("TOOLTIP")
    cursor:SetFrameLevel(10001)
    cursor:EnableMouse(false)
    local tex = cursor:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(CURSOR_TEX)
    tex:SetTexCoord(CURSOR_COORDS[1], CURSOR_COORDS[2], CURSOR_COORDS[3], CURSOR_COORDS[4])
    cursor:Hide()
    return cursor
end

-- A short line that rides beside the cursor during a drag ("Snaps to
-- the minimap"), in the same on-screen style, smaller: it fades in,
-- holds, fades out, and never outlives the show. A child of the cursor,
-- so it tracks for free.
local function EnsureSay()
    if say then return say end
    local c = EnsureCursor()
    local f = CreateFrame("Frame", nil, c)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(10000)
    f:EnableMouse(false)
    f:SetClampedToScreen(true)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.text:SetPoint("TOPLEFT")
    f.text:SetJustifyH("LEFT")
    f.text:SetTextColor(1, 0.82, 0, 1)
    f.text:SetShadowColor(0, 0, 0, 1)
    f.text:SetShadowOffset(1, -1)
    f.text._efOwnColor = true
    f:SetPoint("TOPLEFT", c, "BOTTOMRIGHT", 4, 2)
    f:Hide()
    say = f
    return f
end

local function HideSay()
    if not say then return end
    say:SetScript("OnUpdate", nil)
    say:Hide()
end

-- The one line of text: "Esc to stop the demo", in the game's own
-- on-screen message style (large, yellow, no panel). Not mouse-enabled,
-- so it can never sit between the cursor and anything.
local function EnsureHint()
    if hint then return hint end
    local f = CreateFrame("Frame", HINT_NAME, UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(9800)
    f:EnableMouse(false)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.text:SetPoint("CENTER")
    f.text:SetJustifyH("CENTER")
    f.text:SetTextColor(1, 0.82, 0, 1)
    f.text:SetShadowColor(0, 0, 0, 1)
    f.text:SetShadowOffset(1, -1)
    f.text._efOwnColor = true
    -- Hidden BEFORE the OnHide script goes on: a new frame is shown by
    -- default, and this first Hide must not read as the end of a show.
    f:Hide()
    -- Hidden by Escape (the addon's ESC override) or by Stop: both end
    -- the show.
    f:SetScript("OnHide", function() if state then ShowMe:Stop() end end)
    ns.Utils.AttachEscClose(f, function() ShowMe:Stop() end)
    -- Any real click ends the show: the person took over.
    f:SetScript("OnEvent", function(_, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        ShowMe:Stop()
    end)
    hint = f
    return f
end

-- Screen rectangle of a frame in UIParent coordinates, or nil.
local function RectOf(frame)
    if not (frame and frame.GetLeft and frame:IsShown()) then return nil end
    local l, b, w, h = frame:GetLeft(), frame:GetBottom(), frame:GetWidth(), frame:GetHeight()
    if not (l and b and w and h) then return nil end
    local k = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return l * k, b * k, (l + w) * k, (b + h) * k
end

local function Overlaps(al, ab, ar, at, bl, bb, br, bt, m)
    m = m or 0
    return al < br + m and ar > bl - m and ab < bt + m and at > bb - m
end

-- Where the hint may go, in order of preference: top center, bottom
-- center (above the micro menu's usual home), then the sides. The first
-- spot that overlaps nothing the show uses wins.
local SPOTS = {
    { "TOP",    0,  -14 },
    { "BOTTOM", 0,  110 },
    { "LEFT",   40,   0 },
    { "RIGHT", -40,   0 },
}

-- Everything the demonstration may put on screen or drive: the search
-- bar and its results, the remove target's band, the micro menu, the
-- minimap, and any frames a script names in `api.avoid`.
local function Obstacles()
    local list = {}
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if sf and ShowMe.BarVisible() then list[#list + 1] = sf end
    local rf = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
    if rf and rf:IsShown() then list[#list + 1] = rf end
    local trash = _G.EasyFindExtensionTrash
    if trash then list[#list + 1] = trash end
    if _G.MicroMenuContainer then list[#list + 1] = _G.MicroMenuContainer end
    if _G.Minimap then list[#list + 1] = _G.Minimap end
    if _G.EasyFindUIAppsDropdown then list[#list + 1] = _G.EasyFindUIAppsDropdown end
    local s = state
    if s and s.api and s.api.avoid then
        for i = 1, #s.api.avoid do list[#list + 1] = s.api.avoid[i] end
    end
    return list
end

-- The remove target only exists during a drag, but its band at the top
-- center is spoken for throughout: the hint must never sit where it will
-- appear.
local function TrashBand()
    local w = UIParent:GetWidth()
    local h = UIParent:GetHeight()
    return w / 2 - 60, h - 70 - 44 - 22, w / 2 + 60, h - 70 + 8
end

local function PlaceHint()
    local f = EnsureHint()
    f.text:SetText(L["SHOWME_ESC_HINT"])
    local w = math.ceil((f.text:GetStringWidth() or 0) + HINT_PAD_X * 2)
    local h = math.ceil((f.text:GetStringHeight() or 0) + HINT_PAD_Y * 2)
    f:SetSize(w, h)
    local obstacles = Obstacles()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    for i = 1, #SPOTS do
        local spot = SPOTS[i]
        -- The rectangle the hint would occupy at this spot.
        local l, b
        if spot[1] == "TOP" then
            l, b = sw / 2 - w / 2 + spot[2], sh + spot[3] - h
        elseif spot[1] == "BOTTOM" then
            l, b = sw / 2 - w / 2 + spot[2], spot[3]
        elseif spot[1] == "LEFT" then
            l, b = spot[2], sh / 2 - h / 2
        else
            l, b = sw + spot[2] - w, sh / 2 - h / 2
        end
        local r, t = l + w, b + h
        local clear = not Overlaps(l, b, r, t, TrashBand())
        if clear then
            for j = 1, #obstacles do
                local ol, ob, or_, ot = RectOf(obstacles[j])
                if ol and Overlaps(l, b, r, t, ol, ob, or_, ot, HINT_MARGIN) then
                    clear = false
                    break
                end
            end
        end
        if clear or i == #SPOTS then
            f:ClearAllPoints()
            f:SetPoint(spot[1], UIParent, spot[1], spot[2], spot[3])
            return
        end
    end
end

local function EnsureTick()
    if tick then return tick end
    tick = CreateFrame("Frame")
    tick:SetScript("OnUpdate", function(_, dt)
        local s = state
        if not s then return end
        s.time = s.time + dt
        local i = 1
        while i <= #s.timers do
            local t = s.timers[i]
            if t.at <= s.time then
                tremove(s.timers, i)
                if t.gen == s.gen then
                    local ok, err = pcall(t.fn)
                    if not ok then Report(err) end
                    i = 1
                end
            else
                i = i + 1
            end
        end
    end)
    return tick
end

-- ==== the cursor ============================================================

local function CursorXY()
    local c = EnsureCursor()
    local l, t = c:GetLeft(), c:GetTop()
    if not l then return UIParent:GetWidth() * 0.72, UIParent:GetHeight() * 0.5 end
    return l + 4, t - 4
end

local function PushVirtualMouse(x, y)
    local s = state
    if not (s and s.virtual and ns.ExtensionButtons and ns.ExtensionButtons.SetVirtualMouse) then return end
    ns.ExtensionButtons:SetVirtualMouse(x, y, s.down)
end

local function PlaceCursor(x, y)
    local c = EnsureCursor()
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x - 4, y + 4)
    PushVirtualMouse(x, y)
end

local function FrameCenterUI(frame)
    if not (frame and frame.GetCenter) then return nil end
    local cx, cy = frame:GetCenter()
    if not cx then return nil end
    local k = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return cx * k, cy * k
end

-- ==== the api handed to scripts ============================================

local function BuildApi()
    local api = {}
    api.avoid = {}   -- frames the hint must keep clear of, set by a script

    function api.After(delay, fn)
        local s = state
        if not s then return end
        tinsert(s.timers, { at = s.time + (delay or 0), fn = fn, gen = s.gen })
    end

    -- Re-places the hint (a script calls it after opening something).
    function api.PlaceHint()
        if state then PlaceHint() end
    end

    function api.CursorXY()
        return CursorXY()
    end

    -- Eased move of the fake cursor to (x, y) in UIParent coordinates.
    function api.MoveTo(x, y, duration, onArrive)
        local s = state
        if not s then return end
        local c = EnsureCursor()
        if not c:IsShown() then
            local sx, sy = CursorXY()
            PlaceCursor(sx, sy)
            c:Show()
        end
        local sx, sy = CursorXY()
        local myGen = s.gen
        local elapsed = 0
        duration = duration or MOVE_DEFAULT
        c:SetScript("OnUpdate", function(self, dt)
            if state ~= s or myGen ~= s.gen then
                self:SetScript("OnUpdate", nil)
                return
            end
            elapsed = elapsed + dt
            local t = elapsed / duration
            if t >= 1 then t = 1 end
            local e = t * t * (3 - 2 * t)
            PlaceCursor(sx + (x - sx) * e, sy + (y - sy) * e)
            if t >= 1 then
                self:SetScript("OnUpdate", nil)
                if onArrive then
                    local ok, err = pcall(onArrive)
                    if not ok then Report(err) end
                end
            end
        end)
    end

    -- Move to a frame's center (plus offsets); a missing frame arrives at
    -- once so a script never stalls on a surface that is not there.
    function api.MoveToFrame(frame, duration, onArrive, offsetX, offsetY)
        local x, y = FrameCenterUI(frame)
        if not x then
            if onArrive then onArrive() end
            return
        end
        api.MoveTo(x + (offsetX or 0), y + (offsetY or 0), duration, onArrive)
    end

    -- The click pulse: a quick shrink and back.
    function api.Click(onComplete)
        local s = state
        if not s then return end
        local c = EnsureCursor()
        local myGen = s.gen
        local elapsed, total = 0, 0.18
        c:SetScript("OnUpdate", function(self, dt)
            if state ~= s or myGen ~= s.gen then
                self:SetScript("OnUpdate", nil)
                self:SetSize(CURSOR_SIZE, CURSOR_SIZE)
                return
            end
            elapsed = elapsed + dt
            local half = total / 2
            local k = elapsed < half and (1 - 0.3 * elapsed / half) or (0.7 + 0.3 * (elapsed - half) / half)
            self:SetSize(CURSOR_SIZE * k, CURSOR_SIZE * k)
            if elapsed >= total then
                self:SetSize(CURSOR_SIZE, CURSOR_SIZE)
                self:SetScript("OnUpdate", nil)
                if onComplete then
                    local ok, err = pcall(onComplete)
                    if not ok then Report(err) end
                end
            end
        end)
    end

    -- A short line beside the cursor for `hold` seconds, fading in and out.
    function api.Say(text, hold)
        local s = state
        if not s then return end
        local f = EnsureSay()
        f.text:SetText(text or "")
        f:SetSize(math.ceil(f.text:GetStringWidth() or 0) + 2,
            math.ceil(f.text:GetStringHeight() or 0) + 2)
        f:SetAlpha(0)
        f:Show()
        local myGen = s.gen
        local t = 0
        local total = SAY_FADE_IN + (hold or 1.5) + SAY_FADE_OUT
        f:SetScript("OnUpdate", function(self, dt)
            if state ~= s or myGen ~= s.gen then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                return
            end
            t = t + dt
            local a
            if t < SAY_FADE_IN then
                a = t / SAY_FADE_IN
            elseif t < total - SAY_FADE_OUT then
                a = 1
            else
                a = math.max(0, (total - t) / SAY_FADE_OUT)
            end
            self:SetAlpha(a)
            if t >= total then
                self:SetScript("OnUpdate", nil)
                self:Hide()
            end
        end)
    end

    -- The virtual mouse for drags: Press before starting a drag, Release
    -- to drop. While on, every cursor placement is pushed to the modules
    -- that read it.
    function api.VirtualMouse(on)
        local s = state
        if not s then return end
        s.virtual = on and true or false
        if on then
            local x, y = CursorXY()
            PushVirtualMouse(x, y)
        elseif ns.ExtensionButtons and ns.ExtensionButtons.ClearVirtualMouse then
            ns.ExtensionButtons:ClearVirtualMouse()
        end
    end

    function api.Press()
        local s = state
        if not s then return end
        s.down = true
        local x, y = CursorXY()
        PushVirtualMouse(x, y)
    end

    function api.Release()
        local s = state
        if not s then return end
        s.down = false
        local x, y = CursorXY()
        PushVirtualMouse(x, y)
    end

    return api
end

-- ==== playback ==============================================================

-- The shown hint frame owns Escape (registered at creation); arming
-- only adds the click-to-stop watch.
local function ArmEscape()
    local f = EnsureHint()
    f:RegisterEvent("GLOBAL_MOUSE_DOWN")
end

local function DisarmEscape()
    if not hint then return end
    hint:UnregisterEvent("GLOBAL_MOUSE_DOWN")
end

local function RunStep(s, index)
    if state ~= s then return end
    local step = s.def.steps[index]
    if not step then
        s.api.After(END_PAUSE, function() ShowMe:Stop() end)
        return
    end
    s.stepIndex = index
    -- What is on screen changes between steps; the hint keeps clear of it.
    PlaceHint()
    local myGen = s.gen
    local finished = false
    local function done()
        if finished or state ~= s or myGen ~= s.gen then return end
        finished = true
        RunStep(s, index + 1)
    end
    local ok, err = pcall(step.run, s.api, done)
    if not ok then
        Report(err)
        ShowMe:Stop()
    end
end

-- Plays a registered script. `onStop` runs once, when the show ends for
-- any reason (finished, Escape, a real click, an error).
function ShowMe:Play(id, onStop)
    local def = scripts[id]
    if not def then return false end
    if state then self:Stop() end
    -- Every frame exists before the show is marked playing: creating one
    -- hides it, and a hide must never be mistaken for a stop.
    EnsureTick()
    EnsureCursor()
    EnsureHint()
    EnsureSay()
    local s = {
        id = id, def = def, gen = 1, time = 0, timers = {},
        virtual = false, down = false, onStop = onStop,
    }
    s.api = BuildApi()
    state = s
    -- Nothing between here and the first step may leave a half-started
    -- show behind: a failure unwinds to no show at all.
    local ok, err = pcall(function()
        local c = EnsureCursor()
        c:SetSize(CURSOR_SIZE, CURSOR_SIZE)
        c:Hide()
        if def.prepare then def.prepare(s.api) end
        PlaceHint()
        hint:Show()
        ArmEscape()
    end)
    if not ok then
        Report(err)
        state = nil
        DisarmEscape()
        if hint then hint:Hide() end
        return false
    end
    RunStep(s, 1)
    return true
end

function ShowMe:Stop()
    local s = state
    if not s then return end
    state = nil
    s.gen = s.gen + 1
    if cursor then
        cursor:SetScript("OnUpdate", nil)
        cursor:SetSize(CURSOR_SIZE, CURSOR_SIZE)
        cursor:Hide()
    end
    HideSay()
    if ns.ExtensionButtons and ns.ExtensionButtons.ClearVirtualMouse then
        ns.ExtensionButtons:ClearVirtualMouse()
    end
    if s.def.cleanup then
        local ok, err = pcall(s.def.cleanup, s.api)
        if not ok then Report(err) end
    end
    DisarmEscape()
    if hint then hint:Hide() end
    if s.onStop then
        local ok, err = pcall(s.onStop)
        if not ok then Report(err) end
    end
end

-- The localized "Show me" label, for buttons that offer a script.
function ShowMe:ButtonText()
    return L["WHATSNEW_SHOW_ME"]
end

-- For the scripts: the bar as the user sees it (Hover Show keeps the
-- frame shown at alpha 0 while faded out, which is hidden for this).
function ShowMe.BarVisible()
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if not (sf and sf:IsShown()) then return false end
    local db = EasyFind and EasyFind.db
    if db and db.smartShow and not db.autoHide and sf.smartShowVisible then
        return sf.smartShowVisible() and true or false
    end
    return (sf:GetAlpha() or 1) > 0.01
end
