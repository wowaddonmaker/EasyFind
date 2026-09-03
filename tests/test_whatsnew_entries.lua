-- Tests for the per-release What's New entries (Shared/Utils.lua):
-- WHATSNEW_BODY_<x>_<y>_<z> locale keys become a newest-first list, filtered
-- to what a user upgrading from `since` has not seen, with numeric (not
-- string) version ordering. Loads the REAL Shared/Utils.lua.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFont = fakeWidget
env.CreateFrame = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GetCursorPosition = function() return 0, 0 end
env.IsControlKeyDown = function() return false end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })

H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

local function versions(entries)
    local out = {}
    for i = 1, #entries do out[i] = entries[i].version end
    return out
end

-- Suite order is not guaranteed, so the fixture lives at file scope.
ns.L["WHATSNEW_BODY_3_1_0"] = "one"
ns.L["WHATSNEW_BODY_3_10_0"] = "ten"
ns.L["WHATSNEW_BODY_3_2_0"] = "two"
ns.L["WHATSNEW_BODY"] = "legacy, ignored"

local tests = {}

tests["compare is numeric per segment"] = function()
    H.assertEq(Utils.CompareVersion("2.0.10", "2.0.2"), 1, "10 > 2")
    H.assertEq(Utils.CompareVersion("2.0", "2.0.0"), 0, "missing segment is 0")
    H.assertEq(Utils.CompareVersion("3.1.1", "3.2.0"), -1, "minor wins")
    H.assertEq(Utils.CompareVersion(nil, "1.0.0"), -1, "nil sorts oldest")
end

tests["entries sort newest first, numerically"] = function()
    H.assertDeepEq(versions(ns.WhatsNewEntries(nil)), { "3.10.0", "3.2.0", "3.1.0" }, "order")
    H.assertEq(ns.WhatsNewLatestVersion(), "3.10.0", "latest")
    H.assertEq(ns.WhatsNewEntries(nil)[1].body, "ten", "body carried")
end

tests["since filters to what the user missed"] = function()
    H.assertDeepEq(versions(ns.WhatsNewEntries("3.1.0")), { "3.10.0", "3.2.0" }, "from 3.1.0")
    H.assertDeepEq(versions(ns.WhatsNewEntries("3.2.0")), { "3.10.0" }, "from 3.2.0")
    H.assertDeepEq(versions(ns.WhatsNewEntries("3.10.0")), {}, "up to date")
    H.assertDeepEq(versions(ns.WhatsNewEntries("2.4.5")), { "3.10.0", "3.2.0", "3.1.0" }, "from far back")
end

local pass, fail, failures = H.runSuite("WhatsNewEntries", tests)
return { pass = pass, fail = fail, failures = failures }
