-- Tests for Core/VersionCheck.lua: what the peer update notice accepts.
-- The wire itself (SendAddonMessage) is not exercised; NotePeerVersion is
-- the single gate every received version passes through.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

env.EasyFind = { db = { updateNotify = true } }
env.C_ChatInfo = {
    SendAddonMessage = function() end,
    RegisterAddonMessagePrefix = function() end,
}
env.IsInGroup = function() return false end
env.IsInRaid = function() return false end
env.IsInGuild = function() return false end
env.IsInInstance = function() return false, "none" end

ns.version = "3.1.0"
ns.GOLD_COLOR = { 1.0, 0.82, 0.0 }
ns.L = setmetatable({}, { __index = function(_, key) return key end })
ns.CompareVersion = function(a, b)
    local ai = tostring(a or ""):gmatch("%d+")
    local bi = tostring(b or ""):gmatch("%d+")
    while true do
        local av, bv = ai(), bi()
        if av == nil and bv == nil then return 0 end
        av, bv = tonumber(av) or 0, tonumber(bv) or 0
        if av ~= bv then return av < bv and -1 or 1 end
    end
end

H.loadModule("Core/VersionCheck.lua", env, ns)

local VC = ns.VersionCheck
local tests = {}

local function reset()
    VC:ResetSeen()
    env.EasyFind.db.updateNotify = true
end

function tests.accepts_newerVersionOnRosterChannel()
    reset()
    H.assertEq(VC:NotePeerVersion("3.2.0", "GUILD"), true, "newer peer version accepted")
    H.assertTrue(VC:IsUpdateAvailable(), "update flag set")
    H.assertEq(VC:GetAvailableVersion(), "3.2.0")
end

function tests.rejects_sameOrOlderVersion()
    reset()
    H.assertEq(VC:NotePeerVersion("3.1.0", "GUILD"), false, "same version is not an update")
    H.assertEq(VC:NotePeerVersion("3.0.9", "GUILD"), false, "older version is not an update")
    H.assertTrue(not VC:IsUpdateAvailable(), "flag stays clear")
end

function tests.rejects_nonRosterChannels()
    reset()
    -- A whisper is unsolicited and unverifiable: the roster channels are
    -- the only ones that imply shared context.
    H.assertEq(VC:NotePeerVersion("9.9.9", "WHISPER"), false, "whisper dropped")
    H.assertEq(VC:NotePeerVersion("9.9.9", "SAY"), false, "say dropped")
    H.assertEq(VC:NotePeerVersion("9.9.9", nil), false, "missing channel dropped")
    H.assertTrue(not VC:IsUpdateAvailable(), "flag stays clear")
end

function tests.rejects_malformedVersions()
    reset()
    local bad = { "3.2", "3.2.0.1", "v3.2.0", "3.2.0-beta", "banana", "", "999999999" }
    for i = 1, #bad do
        H.assertEq(VC:NotePeerVersion(bad[i], "GUILD"), false,
            "malformed version rejected: " .. tostring(bad[i]))
    end
    H.assertEq(VC:NotePeerVersion(nil, "GUILD"), false, "nil version rejected")
    H.assertTrue(not VC:IsUpdateAvailable(), "flag stays clear")
end

function tests.keeps_highestSeenVersion()
    reset()
    VC:NotePeerVersion("3.2.0", "GUILD")
    H.assertEq(VC:NotePeerVersion("3.1.5", "PARTY"), false, "a lower peer never lowers the notice")
    H.assertEq(VC:GetAvailableVersion(), "3.2.0")
    H.assertEq(VC:NotePeerVersion("3.10.0", "RAID"), true, "3.10.0 ranks above 3.2.0")
    H.assertEq(VC:GetAvailableVersion(), "3.10.0")
end

function tests.optOut_hidesNoticeWithoutForgetting()
    reset()
    VC:NotePeerVersion("3.2.0", "GUILD")
    env.EasyFind.db.updateNotify = false
    H.assertTrue(not VC:IsUpdateAvailable(), "opting out hides the notice")
    env.EasyFind.db.updateNotify = true
    H.assertEq(VC:GetAvailableVersion(), "3.2.0", "re-enabling restores what was heard")
end

local pass, fail, failures = H.runSuite("VersionCheck", tests)
return { pass = pass, fail = fail, failures = failures }
