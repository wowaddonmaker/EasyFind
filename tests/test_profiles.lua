-- Tests for Shared/Profiles.lua: the serializer, switching (sections move,
-- state stays), per-character picks and suggestions, spec profiles,
-- export/import, reset, delete and rename.
local H = require("Harness")

local function fresh(db)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFindDB = db or {}
    env.EasyFind.db = env.EasyFindDB
    env.UnitName = function() return "Toon" end
    env.GetRealmName = function() return "Realm" end
    env.UnitClass = function() return "Druid", "DRUID" end
    env.GetSpecialization = function() return 1 end
    env.GetNumSpecializations = function() return 2 end
    local specs = { { 102, "Balance" }, { 103, "Feral" } }
    env.GetSpecializationInfo = function(i) return specs[i][1], specs[i][2] end
    ns.Utils.Base64Encode = function(s) return s end
    ns.Utils.Base64Decode = function(s) return s end
    ns.DB_DEFAULTS = { fontSize = 12, uiTheme = "dark", aliases = {}, shortkeys = {}, snippets = {}, accountKeybinds = {} }
    ns.ApplyDBDefaults = function(t)
        for k, v in pairs(ns.DB_DEFAULTS) do
            if t[k] == nil then t[k] = type(v) == "table" and {} or v end
        end
    end
    -- The shared-code rules live in Shortkeys.lua; profile codes obey them.
    -- Its bind application builds frames, which the harness has no use for.
    H.loadModule("Shared/Shortkeys.lua", env, ns)
    ns.Shortkeys.ApplyAll = function() end
    H.loadModule("Shared/Profiles.lua", env, ns)
    H.assertNotNil(ns.Profiles, "Profiles.lua must populate ns.Profiles")
    return env, ns.Profiles
end

local function sampleDB()
    return {
        fontSize = 20, uiTheme = "light", uiSearchPosition = { x = 1, y = 2 },
        aliases = { dash = { key = "spell:1850" } },
        shortkeys = { { key = "a" } },
        shortkeysPerChar = { ["Toon-Realm"] = { { key = "b" } } },
        snippets = { { name = "hi", body = "hello" } },
        queryLearn = { q = { key = "x" } },
        clipboard = { entries = {} },
        lootStatCache = { big = true },
        charGold = { ["Toon-Realm"] = 5 },
        tutorialDone = true,
        profileScope = "spec", profileAssign = { spec = {} },
    }
end

local tests = {}

function tests.serialize_roundTrip()
    local _, P = fresh()
    local t = {
        s = "a:b{c}\n\"d\"", n = 42, f = 1.5, neg = -3, big = 2 ^ 40,
        yes = true, no = false,
        list = { "x", "y", { deep = { deeper = 7 } } },
        [10] = "ten", [2.5] = "two and a half",
        empty = {},
    }
    local out = P.Deserialize(P.Serialize(t))
    H.assertDeepEq(out, t, "round trip")
end

function tests.deserialize_rejectsGarbage()
    local _, P = fresh()
    for _, bad in ipairs({ "", "x", "{", "s5:ab", "n1", "{s1:a}", "{s1:at}}" }) do
        local ok = pcall(P.Deserialize, bad)
        H.assertFalse(ok, "must reject " .. bad)
    end
    H.assertNil(P:Decode("EF1!notaprofile"), "wrong prefix")
    H.assertNil(P:Decode("EFP1!{s1:vn2;}"), "wrong version")
end

function tests.initialize_setsUpContainers()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    H.assertEq(P:Active(), "Default")
    H.assertTrue(db.profiles.Default.live, "active slot is the live marker")
    H.assertDeepEq(P:Names(), { "Default" })
    H.assertEq(db.profileKeys["Toon-Realm"], "Default", "this character remembers Default")
    H.assertNil(db.profileScope, "the old scope key is cleaned up")
    H.assertNil(db.profileAssign, "the old assignment table is cleaned up")
    H.assertFalse(P:SpecProfilesEnabled(), "spec profiles start off")
end

-- Upgrading from a version without profiles: every customization stays
-- on the live table, on every character, and nothing is moved or reset.
function tests.upgrade_keepsEveryCustomizationLive()
    local env, P = fresh(sampleDB())
    local db = env.EasyFindDB
    local aliases, snippets, keybinds = db.aliases, db.snippets, db.shortkeysPerChar
    P:OnInitialize()
    P:OnLogin()
    H.assertEq(db.fontSize, 20)
    H.assertEq(db.uiTheme, "light")
    H.assertTrue(db.aliases == aliases, "aliases table untouched")
    H.assertTrue(db.snippets == snippets, "snippets table untouched")
    H.assertTrue(db.shortkeysPerChar == keybinds, "per-character shortkeys untouched")
    H.assertEq(db.aliases.dash.key, "spell:1850")
    -- A second character on the same account, no pick of its own.
    env.UnitName = function() return "Alt" end
    P:OnInitialize()
    P:OnLogin()
    H.assertEq(P:Active(), "Default")
    H.assertTrue(db.aliases == aliases, "the alt sees the same live customizations")
    H.assertEq(db.fontSize, 20)
end

-- A saved file whose active name went stale still names the live slot by
-- its marker: the name follows the marker, and the live data survives.
function tests.staleActiveName_followsLiveMarker()
    local db = sampleDB()
    db.profiles = { Default = { settings = { fontSize = 11 }, aliases = {} }, Tank = { live = true } }
    db.profileActive = "Default"
    db.profileKeys = { ["Toon-Realm"] = "Tank" }
    local env, P = fresh(db)
    P:OnInitialize()
    H.assertEq(P:Active(), "Tank", "the name follows the marker")
    H.assertEq(env.EasyFindDB.fontSize, 20, "live customizations untouched")
    H.assertEq(env.EasyFindDB.aliases.dash.key, "spell:1850")
    H.assertEq(env.EasyFindDB.profiles.Default.settings.fontSize, 11, "the stored profile is intact")
    -- Switching to a slot that already carries the marker never wipes.
    db.profiles.Tank = { live = true }
    db.profileActive = "Default"
    H.assertFalse(P:Switch("Tank"), "adopting the marker is not a switch")
    H.assertEq(env.EasyFindDB.fontSize, 20)
    H.assertEq(P:Active(), "Tank")
end

function tests.switch_movesSectionsAndKeepsState()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    local clipboard, cache = db.clipboard, db.lootStatCache
    H.assertTrue(P:Create("Tank", "Default"), "create as a copy of the live profile")
    H.assertTrue(P:Pick("Tank"), "pick")
    H.assertEq(P:Active(), "Tank")
    H.assertEq(db.profileKeys["Toon-Realm"], "Tank", "the character remembers the pick")
    -- A copy: same values, different tables.
    H.assertEq(db.fontSize, 20)
    H.assertEq(db.aliases.dash.key, "spell:1850")
    db.fontSize = 30
    db.aliases.mount = { key = "mount:1" }
    db.snippets[2] = { name = "bye", body = "goodbye" }
    P:Pick("Default")
    H.assertEq(P:Active(), "Default")
    H.assertEq(db.fontSize, 20, "Default's own font size is back")
    H.assertNil(db.aliases.mount, "Tank's alias did not leak")
    H.assertEq(db.aliases.dash.key, "spell:1850")
    H.assertEq(#db.snippets, 1)
    H.assertEq(db.profiles.Tank.settings.fontSize, 30, "Tank kept its change")
    H.assertEq(db.profiles.Tank.aliases.mount.key, "mount:1")
    H.assertEq(#db.profiles.Tank.snippets, 2)
    H.assertTrue(db.clipboard == clipboard, "clipboard is state, never moved")
    H.assertTrue(db.lootStatCache == cache, "caches are state, never moved")
    H.assertEq(db.charGold["Toon-Realm"], 5)
    H.assertTrue(db.tutorialDone, "tutorial progress is state")
end

function tests.create_fromDefaults()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    H.assertTrue(P:Create("Fresh"), "create")
    P:Pick("Fresh")
    H.assertEq(db.fontSize, 12, "default font size")
    H.assertEq(db.uiTheme, "dark")
    H.assertNil(db.uiSearchPosition, "nil-default keys come up nil")
    H.assertNil(next(db.aliases), "no aliases")
    H.assertNil(next(db.snippets), "no snippets")
    H.assertFalse(P:Create("Fresh"), "no duplicates")
    H.assertFalse(P:Create(""), "no empty names")
end

function tests.suggestions_createCopiesOnPick()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    H.assertDeepEq(P:Suggestions(), { "Toon - Realm", "Druid" })
    H.assertTrue(P:Pick("Druid"), "pick a suggestion")
    H.assertEq(P:Active(), "Druid")
    H.assertEq(db.fontSize, 20, "a copy of the profile that was live")
    H.assertEq(db.aliases.dash.key, "spell:1850")
    H.assertDeepEq(P:Suggestions(), { "Toon - Realm" }, "an existing name is no longer suggested")
    H.assertDeepEq(P:Names(), { "Default", "Druid" })
end

function tests.characters_rememberTheirOwnPick()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    P:Create("Alt")
    P:Pick("Alt")
    H.assertEq(db.profileKeys["Toon-Realm"], "Alt")
    env.UnitName = function() return "Other" end
    H.assertEq(P:Resolve(), "Default", "a character with no pick uses Default")
    P:ApplyResolved("silent")
    H.assertEq(P:Active(), "Default")
    H.assertEq(db.profileKeys["Other-Realm"], "Default")
    env.UnitName = function() return "Toon" end
    H.assertEq(P:Resolve(), "Alt", "the first character still has its pick")
    P:ApplyResolved("silent")
    H.assertEq(P:Active(), "Alt")
end

function tests.specProfiles_perCharacterOptIn()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    P:Create("Caster")
    P:Create("Cat")
    H.assertDeepEq(P:ClassSpecs(), { { id = 102, name = "Balance" }, { id = 103, name = "Feral" } })
    H.assertEq(P:CurrentSpecID(), 102)
    P:SetSpecProfile(103, "Cat")
    H.assertEq(P:Active(), "Default", "spec picks do nothing while spec profiles are off")
    H.assertTrue(P:SetSpecProfilesEnabled(true), "enable")
    H.assertTrue(P:SpecProfilesEnabled())
    H.assertEq(P:Active(), "Default", "enabling changes nothing by itself")
    H.assertEq(P:SpecProfile(102), "Default", "an unset spec reads as the character's pick")
    H.assertEq(P:SpecProfile(103), "Cat")
    env.GetSpecialization = function() return 2 end
    H.assertEq(P:Resolve(), "Cat")
    P:ApplyResolved()
    H.assertEq(P:Active(), "Cat")
    H.assertEq(db.profileKeys["Toon-Realm"], "Cat", "the switch is the character's pick too")
    P:SetSpecProfile(103, "Caster")
    H.assertEq(P:Active(), "Caster", "changing the current spec's pick switches at once")
    env.GetSpecialization = function() return 1 end
    H.assertEq(P:Resolve(), "Caster", "Balance has no pick, so it keeps whatever was live")
    P:Pick("Default")
    H.assertEq(db.profileSpecs["Toon-Realm"][102], "Default", "a manual pick belongs to the current spec")
    H.assertEq(db.profileSpecs["Toon-Realm"][103], "Caster", "the other spec keeps its own")
    P:SetSpecProfilesEnabled(false)
    env.GetSpecialization = function() return 2 end
    H.assertEq(P:Resolve(), "Default", "off: the spec picks are ignored")
    env.UnitName = function() return "Other" end
    H.assertFalse(P:SpecProfilesEnabled(), "spec profiles are per character")
end

function tests.resetActive_clearsEverySection()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    P:Create("Keep", "Default")
    H.assertTrue(P:ResetActive(), "reset")
    H.assertEq(P:Active(), "Default")
    H.assertEq(db.fontSize, 12)
    H.assertNil(next(db.aliases))
    H.assertNil(next(db.snippets))
    H.assertNil(db.queryLearn)
    H.assertEq(db.profiles.Keep.settings.fontSize, 20, "other profiles untouched")
    H.assertTrue(db.tutorialDone, "state untouched")
end

function tests.copyFrom_replacesActive()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    P:Create("Other")
    db.profiles.Other.settings = { fontSize = 99 }
    db.profiles.Other.aliases = { z = { key = "k" } }
    H.assertTrue(P:CopyFrom("Other"), "copy")
    H.assertEq(P:Active(), "Default")
    H.assertEq(db.fontSize, 99)
    H.assertEq(db.aliases.z.key, "k")
    H.assertNil(db.aliases.dash, "old aliases gone")
    db.aliases.z.key = "changed"
    H.assertEq(db.profiles.Other.aliases.z.key, "k", "a copy, not a shared table")
end

function tests.export_defaultsAndPerCharStripped()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    H.assertTrue(P:ExportIncluded("settings"), "settings on")
    H.assertFalse(P:ExportIncluded("snippets"), "snippets off by default")
    H.assertFalse(P:ExportIncluded("learned"), "learned picks off by default")
    local payload = P:Decode(P:Export())
    H.assertNotNil(payload, "decodes")
    H.assertEq(payload.name, "Default")
    H.assertEq(payload.sections.settings.fontSize, 20)
    H.assertNil(payload.sections.settings.tutorialDone, "state is not a setting")
    H.assertNil(payload.sections.settings.clipboard, "the clipboard history never leaves the account")
    H.assertNil(payload.sections.snippets, "snippets left out")
    H.assertNil(payload.sections.learned, "learned left out")
    H.assertEq(payload.sections.shortkeys.shortkeys[1].key, "a")
    H.assertNil(payload.sections.shortkeys.shortkeysPerChar, "per-character shortkeys never exported")
    P:SetExportIncluded("snippets", true)
    H.assertTrue(env.EasyFindDB.profileExportIncl.snippets, "persisted")
    payload = P:Decode(P:Export())
    H.assertEq(payload.sections.snippets.snippets[1].name, "hi")
    H.assertNil(P:Export({}), "nothing included gives nothing")
end

function tests.import_makesUniqueProfile()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    local code = P:Export({ settings = true, aliases = true, shortkeys = true })
    local name = P:Import(code)
    H.assertEq(name, "Default (2)", "named after the code, made unique")
    H.assertEq(P:Import(code), "Default (3)")
    local slot = db.profiles[name]
    H.assertEq(slot.settings.fontSize, 20)
    H.assertEq(slot.aliases.dash.key, "spell:1850")
    H.assertNil(slot.snippets, "sections the code lacks stay absent")
    P:Pick(name)
    H.assertEq(P:Active(), name)
    H.assertNil(next(db.snippets), "absent section came up as defaults")
    H.assertNil(P:Import("garbage"), "bad code")
    local tampered = P:Export({ settings = true })
    -- A wrongly typed setting is dropped on import.
    local payload = P:Decode(tampered)
    payload.sections.settings.fontSize = "twelve"
    local reencoded = P.CODE_PREFIX .. P.Serialize(payload)
    local imported = P:Import(reencoded)
    H.assertNil(db.profiles[imported].settings.fontSize, "wrong type dropped")
end

function tests.delete_and_rename()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    P:Create("Tank")
    P:Create("Heal")
    P:Pick("Tank")
    H.assertFalse(P:CanDelete("Default"), "Default stays")
    H.assertFalse(P:CanDelete("Tank"), "the active profile stays")
    H.assertDeepEq(P:Deletable(), { "Heal" })
    H.assertTrue(P:Rename("Tank", "Guardian"), "rename active")
    H.assertEq(P:Active(), "Guardian")
    H.assertEq(db.profileKeys["Toon-Realm"], "Guardian", "the character's pick follows the rename")
    H.assertFalse(P:Rename("Default", "Main"), "Default cannot be renamed")
    H.assertFalse(P:Rename("Heal", "Guardian"), "no name collisions")
    db.profileKeys["Alt-Realm"] = "Heal"
    db.profileSpecs["Alt-Realm"] = { enabled = true, [103] = "Heal" }
    H.assertTrue(P:Delete("Heal"), "delete")
    H.assertNil(db.profiles.Heal)
    H.assertNil(db.profileKeys["Alt-Realm"], "a pick of a deleted profile clears")
    H.assertNil(db.profileSpecs["Alt-Realm"][103], "a spec pick of a deleted profile clears")
    H.assertTrue(db.profileSpecs["Alt-Realm"].enabled, "the enable flag is not a name")
    H.assertDeepEq(P:Names(), { "Default", "Guardian" })
end

function tests.import_obeysShareRulesAndFlagsCommands()
    local env, P = fresh(sampleDB())
    P:OnInitialize()
    local db = env.EasyFindDB
    db.shortkeys = {
        ["spell:1"] = { key = "CTRL-F", name = "Dash" },
        ["spell:2"] = { key = "W", name = "Move" },
        ["cmd:1"] = { key = "F5", name = "/wave" },
        ["cmd:2"] = { key = "F6", name = "/reload" },
    }
    db.snippets = {
        { name = "Hi", body = "hello" },
        { name = "Wave", body = "/wave" },
        { name = "Evil", body = "/cast x\n/run DoEvil()" },
    }
    local code = P:Export({ settings = true, shortkeys = true, snippets = true })
    local inspect = P:InspectImport(P:Decode(code))
    local counts = {}
    for _, entry in ipairs(inspect.sections) do counts[entry.id] = entry.count end
    H.assertEq(counts.shortkeys, 2, "W and /reload left out")
    H.assertEq(counts.snippets, 2, "the /run body left out")
    H.assertEq(inspect.leftOut, 3)
    H.assertEq(inspect.risky, 2, "/wave key and /wave snippet run commands")
    local name, leftOut = P:Import(code)
    H.assertEq(leftOut, 3)
    local slot = db.profiles[name]
    H.assertNil(slot.shortkeys["spell:2"], "refused key dropped")
    H.assertNil(slot.shortkeys["cmd:2"], "refused command dropped")
    H.assertEq(slot.shortkeys["cmd:1"].name, "/wave", "an ordinary command travels")
    H.assertEq(#slot.snippets, 2)
    H.assertEq(slot.snippets[2].name, "Wave")
end

local pass, fail, failures = H.runSuite("Profiles", tests)
return { pass = pass, fail = fail, failures = failures }
