-- EasyFind test harness. Sets up fake WoW globals and a fake `ns` namespace
-- so pure-logic modules can be loaded and tested from a vanilla Lua 5.4
-- interpreter outside of the WoW client.
--
-- Usage:
--   local H = require("tests.Harness")
--   local env, ns = H.newEnv(), H.newNs()
--   local Aliases = H.loadModule("Shared/Aliases.lua", env, ns)
--   H.assertEq(actual, expected, "label")

local Harness = {}

-- Lua 5.1 has global unpack, 5.4 has table.unpack; rawget keeps the 5.1
-- linter from flagging the 5.4 field.
local tunpack = rawget(table, "unpack") or unpack

-- ============================================================================
-- Path resolution
-- ============================================================================
-- Tests are invoked from the EasyFind addon root (where the .toc lives).
-- Module paths are given relative to that root.
local ADDON_ROOT
do
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    -- source may be absolute (e.g. C:/.../EasyFind/tests/Harness.lua) or
    -- relative (e.g. tests/Harness.lua). Strip the trailing
    -- "[sep]tests[sep]Harness.lua" if present; otherwise the root is "".
    local stripped = source:gsub("[/\\]?tests[/\\]Harness%.lua$", "")
    if stripped == "" or stripped == source then
        ADDON_ROOT = "."
    else
        ADDON_ROOT = stripped
    end
end
Harness.ADDON_ROOT = ADDON_ROOT

local function resolvePath(modulePath)
    if modulePath:sub(1, 1) == "/" or modulePath:match("^%a:[/\\]") then
        return modulePath
    end
    return ADDON_ROOT .. "/" .. modulePath
end

-- ============================================================================
-- Fake clock for deterministic time-based tests
-- ============================================================================
local Clock = {}
Clock.__index = Clock

function Clock.new()
    return setmetatable({ now = 0, queue = {} }, Clock)
end

function Clock:after(delay, fn)
    self.queue[#self.queue + 1] = { fireAt = self.now + (delay or 0), fn = fn }
end

function Clock:advance(seconds)
    self.now = self.now + (seconds or 0)
    -- Sort and fire anything whose deadline has passed. New entries may
    -- be appended by fired callbacks; loop until quiescent at this time.
    while true do
        local fired = false
        table.sort(self.queue, function(a, b) return a.fireAt < b.fireAt end)
        local i = 1
        while i <= #self.queue do
            if self.queue[i].fireAt <= self.now then
                local item = table.remove(self.queue, i)
                fired = true
                item.fn()
            else
                i = i + 1
            end
        end
        if not fired then break end
    end
end

function Clock:queueDepth()
    return #self.queue
end

Harness.Clock = Clock

-- ============================================================================
-- Frame stub (CreateFrame): minimal surface
-- ============================================================================
local function newFrame()
    local handlers, attributes, points = {}, {}, {}
    local shown, mouseEnabled, keyboardEnabled = true, false, false
    local frame
    frame = {
        SetScript = function(self, name, fn) handlers[name] = fn end,
        GetScript = function(self, name) return handlers[name] end,
        HookScript = function(self, name, fn)
            local prev = handlers[name]
            handlers[name] = function(...)
                if prev then prev(...) end
                fn(...)
            end
        end,
        SetAttribute = function(self, k, v) attributes[k] = v end,
        GetAttribute = function(self, k) return attributes[k] end,
        SetPoint = function(self, ...) points[#points + 1] = { ... } end,
        ClearAllPoints = function() points = {} end,
        Show = function() shown = true end,
        Hide = function() shown = false end,
        SetShown = function(_, v) shown = v end,
        IsShown = function() return shown end,
        IsVisible = function() return shown end,
        EnableMouse = function(_, v) mouseEnabled = v end,
        EnableKeyboard = function(_, v) keyboardEnabled = v end,
        IsMouseEnabled = function() return mouseEnabled end,
        IsKeyboardEnabled = function() return keyboardEnabled end,
        SetPropagateKeyboardInput = function() end,
        SetFrameLevel = function() end, GetFrameLevel = function() return 1 end,
        SetWidth = function() end, SetHeight = function() return 20 end,
        GetWidth = function() return 100 end, GetHeight = function() return 20 end,
        RegisterEvent = function() end, UnregisterEvent = function() end,
        CreateTexture = function() return newFrame() end,
        CreateFontString = function() return newFrame() end,
        SetTexture = function() end, SetAtlas = function() end,
        SetTexCoord = function() end, SetVertexColor = function() end,
        SetText = function() end, GetText = function() return "" end,
        SetFontObject = function() end,
        SetParent = function() end, GetParent = function() return nil end,
    }
    -- Allow tests to peek at internal state when needed
    frame._handlers = handlers
    frame._attributes = attributes
    return frame
end
Harness.newFrame = newFrame

-- ============================================================================
-- WoW global mocks
-- ============================================================================
local function setupWoWGlobals(env, clock)
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.strtrim = function(s)
        if not s then return "" end
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    env.strsplit = function(sep, s)
        local out = {}
        for part in (s or ""):gmatch("([^" .. sep .. "]+)") do
            out[#out + 1] = part
        end
        return tunpack(out)
    end

    env.InCombatLockdown = function() return false end
    env.IsKeyDown = function() return false end
    env.IsShiftKeyDown = function() return false end
    env.IsControlKeyDown = function() return false end
    env.IsAltKeyDown = function() return false end
    env.GetTime = function() return clock.now end
    env.time = function() return math.floor(clock.now) end

    env.C_Timer = {
        After = function(delay, fn) clock:after(delay, fn) end,
        NewTicker = function(_, fn) fn() end,
    }
    env.CreateFrame = function() return newFrame() end
    env.debugstack = function(level) return "<debugstack stub level=" .. tostring(level or 1) .. ">" end

    env.C_AddOns = {
        LoadAddOn = function() return true end,
        IsAddOnLoaded = function() return false end,
    }
    env.C_Reputation = {
        GetNumFactions = function() return 0 end,
        GetFactionDataByIndex = function() return nil end,
    }
    env.C_CurrencyInfo = {
        GetCurrencyInfo = function() return nil end,
        GetCurrencyListSize = function() return 0 end,
    }
    env.C_Map = {
        GetMapInfo = function() return nil end,
        GetBestMapForUnit = function() return nil end,
    }
    env.C_EncounterJournal = {
        GetDungeonEntranceMapInfo = function() return nil end,
    }
    env.C_Texture = {
        GetAtlasInfo = function() return nil end,
    }

    -- WoW exposes a `bit` library. Lua 5.4 has operators but no `bit`,
    -- so shim it. The semantics here match LuaJIT/WoW's `bit` lib for the
    -- handful of ops Database/Main.lua uses.
    env.bit = {
        band   = function(a, b) return a & b end,
        bor    = function(a, b) return a | b end,
        bxor   = function(a, b) return a ~ b end,
        bnot   = function(a)    return ~a end,
        lshift = function(a, n) return a << n end,
        rshift = function(a, n) return a >> n end,
    }

    env.WorldMapFrame = nil
    env.GameTooltip = setmetatable({}, {
        __index = function() return function() end end,
    })
    env.GameTooltip_Hide = function() end

    env.EasyFind = {
        db = {
            aliases = {},
            uiSearchHistory = {},
            uiSearchHistoryLimit = 500,
            hideAchievementHeaders = false,
            hideGuildAchievements = false,
        },
        Print = function() end,
    }

    -- Lua 5.4 doesn't have global `unpack` (it's table.unpack); WoW has both.
    env.unpack = tunpack
end

-- ============================================================================
-- Environment + namespace constructors
-- ============================================================================
function Harness.newEnv(opts)
    local env = setmetatable({}, { __index = _G })
    local clock = Clock.new()
    setupWoWGlobals(env, clock)
    env._clock = clock
    return env
end

-- The real Shared/Utils.lua does heavy WoW-specific work at module load
-- (CreateFont, Bindings, frame pools). Tests use a stub that mirrors the
-- pure-Lua portion of the Utils API. Add to this stub when a tested module
-- needs a missing field.
local function buildUtilsStub(clock)
    local Utils = {}
    Utils.pairs = pairs Utils.ipairs = ipairs Utils.type = type
    Utils.select = select Utils.unpack = tunpack Utils.next = next

    -- Mirrors Shared/Utils.lua ClipboardSafeText/StripMarkup (pure string
    -- code; the markup grammar lives in ClipboardSafeText once).
    function Utils.ClipboardSafeText(s)
        if not s then return s end
        s = s:gsub("|A:[^|]*|a", "")
        s = s:gsub("|T[^|]*|t", "")
        s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]*:", ""):gsub("|r", "")
        s = s:gsub("|H[^|]+|h(.-)|h", "%1")
        return s
    end
    function Utils.StripMarkup(s)
        s = Utils.ClipboardSafeText(s)
        if not s then return s end
        s = s:gsub("%s+", " ")
        s = s:match("^%s*(.-)%s*$") or s
        return s
    end

    Utils.tinsert = table.insert Utils.tsort = table.sort
    Utils.tconcat = table.concat Utils.tremove = table.remove

    Utils.sfind = string.find Utils.slower = string.lower
    Utils.ssub = string.sub Utils.sformat = string.format
    Utils.smatch = string.match

    Utils.mmin = math.min Utils.mmax = math.max Utils.mabs = math.abs
    Utils.mpi = math.pi Utils.mceil = math.ceil Utils.mfloor = math.floor

    Utils.pcall = pcall Utils.xpcall = xpcall
    Utils.tostring = tostring Utils.tonumber = tonumber

    Utils.ErrorHandler = function(err) return tostring(err) end
    Utils.DebugPrint = function() end

    Utils.RGB = function(c, alpha)
        if alpha == nil then return c[1], c[2], c[3] end
        return c[1], c[2], c[3], alpha
    end

    Utils.SafeCallMethod = function(obj, method, ...)
        if not obj then return false, "no-object" end
        local fn = obj[method]
        if not fn then return false, "no-method" end
        local ok, result = pcall(fn, obj, ...)
        return ok, result
    end

    Utils.SafeAfter = function(delay, fn)
        clock:after(delay, function()
            pcall(fn)
        end)
    end

    -- Mirrors of the real slicer API (Shared/Utils.lua): the harness has
    -- no frame pump, so sliced work runs synchronously and checkpoints
    -- are no-ops.
    Utils.SliceCheckpoint = function() end
    Utils.RunSliced = function(fn, onDone)
        local function relay(ok, ...) onDone(ok, ...) end
        relay(pcall(fn))
    end

    -- Mirror of the real Utils.AccumulateGateMasks (Shared/Utils.lua);
    -- Database/Search.lua aliases it for the scoring gate. Keep in sync.
    Utils.AccumulateGateMasks = function(s, cm, im)
        local prevAlpha = false
        for i = 1, #s do
            local b = string.byte(s, i)
            if b >= 65 and b <= 90 then b = b + 32 end
            if b >= 97 and b <= 122 then
                local bitv = 1 << (b - 97)
                cm = cm | bitv
                if not prevAlpha then im = im | bitv end
                prevAlpha = true
            else
                prevAlpha = false
            end
        end
        return cm, im
    end

    Utils.SafeOnUpdate = function(frame, handler)
        frame:SetScript("OnUpdate", handler)
    end

    Utils.NormalizeKey = function(key)
        return type(key) == "string" and key:upper() or key
    end

    local IS_KEY_DOWN_ALIASES = {
        UP = "UPARROW", DOWN = "DOWNARROW",
        LEFT = "LEFTARROW", RIGHT = "RIGHTARROW",
    }
    Utils.IsPhysicalKeyDown = function(key)
        return false  -- tests can override per-case
    end
    Utils._IS_KEY_DOWN_ALIASES = IS_KEY_DOWN_ALIASES

    Utils.IsModifierKey = function(key)
        return key == "LSHIFT" or key == "RSHIFT"
            or key == "LCTRL" or key == "RCTRL"
            or key == "LALT" or key == "RALT"
    end

    return Utils
end

function Harness.newNs(env)
    -- Mirror Search/Modules.lua's EnsureModule pattern so files that do
    -- `local X = ns.X` get a real table.
    local ns = {}
    local moduleNames = {
        "Database",
        "Search", "SearchFocus", "SearchHistory", "SearchOpeners",
        "SearchProviders", "Filters", "Calculator",
        "Results", "ResultRows", "ResultRender", "ResultHandlers",
        "ResultIcons", "ResultText", "ResultTooltips", "ResultShortcuts",
        "OptionsSurface", "Onboarding", "Guide",
        "Aliases", "MapSearch", "MapSearchCategories",
    }
    for i = 1, #moduleNames do
        ns[moduleNames[i]] = {}
    end
    -- Utils is special: built once with the env's clock so SafeAfter ties
    -- into the deterministic clock for tests.
    ns.Utils = buildUtilsStub(env and env._clock or Clock.new())
    -- Localization table: mirror Shared/Localization.lua's ultimate fallback
    -- (return the key itself) so modules that read L[...] at load time work.
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    -- Shared constants that some modules reference.
    ns.GOLD_COLOR = { 1.0, 0.82, 0.0 }
    ns.TEXT_PRIMARY = { 1.00, 0.97, 0.86 }
    return ns
end

-- ============================================================================
-- Module loading
-- ============================================================================
function Harness.loadModule(modulePath, env, ns)
    env = env or Harness.newEnv()
    ns = ns or Harness.newNs(env)
    local fullPath = resolvePath(modulePath)
    local chunk, err = loadfile(fullPath, "t", env)
    if not chunk then
        error("loadfile " .. fullPath .. ": " .. tostring(err), 2)
    end
    local result = chunk("EasyFind", ns)
    return result, ns, env
end

-- ============================================================================
-- Assertions
-- ============================================================================
local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "table" then
        local parts = {}
        for k, vv in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. fmt(vv)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end
Harness.fmt = fmt

function Harness.assertEq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            label or "assertEq", fmt(expected), fmt(actual)), 2)
    end
end

function Harness.assertTrue(cond, label)
    if not cond then
        error(string.format("%s: expected truthy, got %s",
            label or "assertTrue", fmt(cond)), 2)
    end
end

function Harness.assertFalse(cond, label)
    if cond then
        error(string.format("%s: expected falsy, got %s",
            label or "assertFalse", fmt(cond)), 2)
    end
end

function Harness.assertNil(v, label)
    if v ~= nil then
        error(string.format("%s: expected nil, got %s",
            label or "assertNil", fmt(v)), 2)
    end
end

function Harness.assertNotNil(v, label)
    if v == nil then
        error((label or "assertNotNil") .. ": expected non-nil, got nil", 2)
    end
end

function Harness.assertDeepEq(actual, expected, label)
    label = label or "assertDeepEq"
    local function deep(a, b, path)
        if type(a) ~= type(b) then
            return false, path .. ": type mismatch " .. type(a) .. " vs " .. type(b)
        end
        if type(a) ~= "table" then
            if a ~= b then return false, path .. ": " .. fmt(a) .. " ~= " .. fmt(b) end
            return true
        end
        for k, v in pairs(a) do
            local ok, why = deep(v, b[k], path .. "." .. tostring(k))
            if not ok then return false, why end
        end
        for k in pairs(b) do
            if a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing in actual" end
        end
        return true
    end
    local ok, why = deep(actual, expected, label)
    if not ok then error(why, 2) end
end

-- ============================================================================
-- Test runner helpers
-- ============================================================================
function Harness.runSuite(name, tests)
    print("== " .. name .. " ==")
    local pass, fail = 0, 0
    local failures = {}
    for testName, fn in pairs(tests) do
        local ok, err = xpcall(fn, debug.traceback)
        if ok then
            pass = pass + 1
            print("  ok   " .. testName)
        else
            fail = fail + 1
            failures[#failures + 1] = { name = testName, err = err }
            print("  FAIL " .. testName)
            print("       " .. tostring(err):gsub("\n", "\n       "))
        end
    end
    return pass, fail, failures
end

return Harness
