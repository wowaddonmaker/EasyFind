-- Tests for the EF1! share codec in Shared/Shortkeys.lua: the four-section
-- layout, the shared-code rules (refused keys and commands, field length,
-- caps), what an export leaves out, and what an import analysis reports.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFindDB = {}
    env.EasyFind.db = env.EasyFindDB
    env.UnitName = function() return "Toon" end
    env.GetRealmName = function() return "Realm" end
    -- Identity in place of base64: the codec is what is under test.
    ns.Utils.Base64Encode = function(s) return s end
    ns.Utils.Base64Decode = function(s) return s end
    ns.SYSTEM_COMMANDS = { "/reload", "/logout", "/camp", "/quit", "/exit" }
    H.loadModule("Shared/Shortkeys.lua", env, ns)
    local S = ns.Shortkeys
    H.assertNotNil(S, "Shortkeys.lua must populate ns.Shortkeys")
    -- Stand-ins for the stores the codec reads: the same row shapes the
    -- real ExportList functions return.
    local stores = { aliases = {}, blacklist = {}, snippets = {} }
    ns.Aliases = {
        ExportList = function() return stores.aliases end,
        HasAlias = function(_, text)
            for _, r in ipairs(stores.aliases) do if r.text == text then return true end end
            return false
        end,
    }
    ns.Blacklist = {
        ExportList = function() return stores.blacklist end,
        Has = function(_, key)
            for _, r in ipairs(stores.blacklist) do if r.key == key then return true end end
            return false
        end,
    }
    ns.Snippets = {
        ExportList = function() return stores.snippets end,
        HasSnippet = function(_, name)
            for _, r in ipairs(stores.snippets) do if r.name == name then return true end end
            return false
        end,
        -- Names and keywords both clash, as the real companion decides.
        FindConflict = function(_, name, keyword)
            for _, r in ipairs(stores.snippets) do
                if (name and r.name == name) or (keyword and keyword ~= "" and r.keyword == keyword) then return r end
            end
            return nil
        end,
    }
    return env, S, stores
end

local tests = {}

function tests.roundTrip_fourSections()
    local env, S, stores = fresh()
    stores.aliases[1] = { text = "dash", key = "spell:1850", name = "Dash" }
    env.EasyFindDB.shortkeys = { ["spell:1850"] = { key = "CTRL-F", name = "Dash" } }
    stores.blacklist[1] = { key = "mount:1", name = "Old Mount", category = "mounts" }
    stores.snippets[1] = { name = "Hello", keyword = "hi", body = "hello there" }

    local both, leftOut = S:BuildExportString("both")
    H.assertEq(leftOut, 0)
    H.assertTrue(both:sub(1, 4) == "EF1!", "prefix")
    local d = S:DecodeString(both)
    H.assertEq(#d.aliases, 1)
    H.assertEq(d.aliases[1].text, "dash")
    H.assertEq(#d.shortkeys, 1)
    H.assertEq(d.shortkeys[1].b, "CTRL-F")
    H.assertFalse(d.shortkeys[1].c, "account-wide row")
    H.assertEq(#d.blacklist, 0, "both never carries the blacklist")
    H.assertEq(#d.snippets, 0, "both never carries snippets")

    local bl = S:DecodeString((S:BuildExportString("blacklist")))
    H.assertEq(#bl.blacklist, 1)
    H.assertEq(bl.blacklist[1].category, "mounts")

    local sn = S:DecodeString((S:BuildExportString("snippet")))
    H.assertEq(#sn.snippets, 1)
    H.assertEq(sn.snippets[1].keyword, "hi")
    H.assertEq(sn.snippets[1].body, "hello there")
end

function tests.decode_acceptsOlderShorterCodes()
    local _, S = fresh()
    -- A code that ends after the shortkey section (pre-blacklist clients).
    local blob = "EFSK1" .. "4:both" .. "1:1" .. "4:dash" .. "10:spell:1850" .. "4:Dash" .. "1:0"
    local d = S:DecodeString("EF1!" .. blob)
    H.assertEq(#d.aliases, 1)
    H.assertEq(#d.shortkeys, 0)
    H.assertEq(#d.blacklist, 0)
    H.assertEq(#d.snippets, 0)
    H.assertNil(S:DecodeString("EF1!nope"), "bad marker")
    H.assertNil(S:DecodeString("EFT1!theme"), "other kind")
end

function tests.refusals_keysCommandsLength()
    local _, S = fresh()
    H.assertEq(S.ShareRefusal("shortkeys", { k = "spell:1", b = "W", n = "Dash" }), "key")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "spell:1", b = "CTRL-SHIFT-ESCAPE", n = "Dash" }), "key")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "spell:1", b = "SHIFT-MOUSEWHEELUP", n = "Dash" }), "key")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "spell:1", b = "CTRL-W", n = "Dash" }), "key",
        "CTRL-W ends in W and is refused")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "cmd:1", b = "F5", n = "/reload" }), "command")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "cmd:1", b = "F5", n = "/run print(1)" }), "command")
    H.assertNil(S.ShareRefusal("shortkeys", { k = "cmd:1", b = "F5", n = "/dance" }), "/dance is fine")
    H.assertNil(S.ShareRefusal("shortkeys", { k = "cmd:1", b = "F5", n = "/dndx" }), "prefix must be a whole command")
    H.assertEq(S.ShareRefusal("shortkeys", { k = "spell:1", b = "F5", n = string.rep("x", 81) }), "length")
    H.assertNil(S.ShareRefusal("shortkeys", { k = "spell:1", b = "CTRL-F", n = "Dash" }), "a normal row travels")
    H.assertEq(S.ShareRefusal("aliases", { text = string.rep("a", 81), key = "k", name = "n" }), "length")
    H.assertNil(S.ShareRefusal("aliases", { text = "dash", key = "spell:1850", name = "Dash" }))
    H.assertEq(S.ShareRefusal("snippets", { name = "Bad", keyword = "b", body = "/script DoThing()" }), "command")
    H.assertEq(S.ShareRefusal("snippets", { name = "Bad", keyword = "b", body = " /dump x" }), "command")
    H.assertNil(S.ShareRefusal("snippets", { name = "Wave", keyword = "w", body = "/wave" }), "/wave is fine")
    H.assertEq(S.ShareRefusal("snippets", { name = "Long", keyword = "l", body = string.rep("x", 256) }), "length")
    -- Links count as their bracket text, the way the editor counts them.
    local link = "|cffa335ee|Hitem:19019::::::::70:::::|h[Thunderfury, Blessed Blade]|h|r"
    H.assertNil(S.ShareRefusal("snippets", { name = "Links", keyword = "k", body = string.rep(link, 4) }),
        "four links read as 120 characters")
    H.assertEq(S.ShareRefusal("snippets", { name = "Raw", keyword = "k", body = string.rep(link, 20) }), "length",
        "the raw text has its own cap")
    H.assertEq(S.ShareRefusal("snippets", { name = "Hidden", keyword = "h", body = "/cast x\n /run DoThing()" }),
        "command", "every line of a body counts")
    H.assertEq(S.ShareRefusal("blacklist", nil), "length", "a non-row is never carried")
end

function tests.runsCommands_flagsWhatExecutes()
    local _, S = fresh()
    H.assertTrue(S.RunsCommands("shortkeys", { k = "cmd:1", b = "F5", n = "/wave" }))
    H.assertTrue(S.RunsCommands("shortkeys", { k = "cmd:1", b = "F5", n = "  /dance" }))
    H.assertFalse(S.RunsCommands("shortkeys", { k = "spell:1", b = "F5", n = "Dash" }))
    H.assertTrue(S.RunsCommands("snippets", { name = "W", keyword = "w", body = "hello\n/wave" }))
    H.assertFalse(S.RunsCommands("snippets", { name = "H", keyword = "h", body = "hello / there" }))
    H.assertFalse(S.RunsCommands("aliases", { text = "dash", key = "spell:1", name = "/wave" }), "aliases only search")
    H.assertFalse(S.RunsCommands("snippets", nil))
end

function tests.export_leavesRefusedRowsOut()
    local env, S, stores = fresh()
    env.EasyFindDB.shortkeys = {
        ["spell:1"] = { key = "CTRL-F", name = "Dash" },
        ["spell:2"] = { key = "W", name = "Move" },
        ["cmd:1"] = { key = "F5", name = "/logout" },
    }
    stores.aliases[1] = { text = "dash", key = "spell:1", name = "Dash" }
    stores.aliases[2] = { text = string.rep("z", 90), key = "spell:1", name = "Dash" }
    local code, leftOut = S:BuildExportString("both")
    H.assertEq(leftOut, 3, "one refused key, one refused command, one long alias")
    local _, _, rows = S:BuildExportString("both")
    H.assertEq(#rows, 3)
    H.assertNotNil(rows[1].row, "the left-out row itself rides along")
    local d = S:DecodeString(code)
    H.assertEq(#d.shortkeys, 1)
    H.assertEq(d.shortkeys[1].b, "CTRL-F")
    H.assertEq(#d.aliases, 1)
end

function tests.import_capsRefuseWholeCode()
    local _, S = fresh()
    local aliases = {}
    for i = 1, 301 do aliases[i] = { text = "a" .. i, key = "k", name = "n" } end
    local over = S:CheckImportLimits({ aliases = aliases, shortkeys = {}, blacklist = {}, snippets = {} }, "both")
    H.assertNotNil(over, "over the alias cap")
    H.assertEq(over.section, "aliases")
    H.assertEq(over.count, 301)
    H.assertEq(over.cap, 300)
    H.assertNil(S:CheckImportLimits({ aliases = aliases, shortkeys = {}, blacklist = {}, snippets = {} }, "blacklist"),
        "only the sections the dialog applies count")
    local sk = {}
    for i = 1, 100 do sk[i] = { k = "k" .. i, b = "F" .. i, n = "n" } end
    H.assertNil(S:CheckImportLimits({ aliases = {}, shortkeys = sk, blacklist = {}, snippets = {} }, "shortkey"),
        "at the cap is fine")
    sk[101] = { k = "k101", b = "F1", n = "n" }
    H.assertEq(S:CheckImportLimits({ aliases = {}, shortkeys = sk, blacklist = {}, snippets = {} }, "shortkey").cap, 100)
    local sn = {}
    for i = 1, 101 do sn[i] = { name = "s" .. i, keyword = "", body = "x" } end
    H.assertEq(S:CheckImportLimits({ snippets = sn }, "snippet").section, "snippets")
end

function tests.analyze_reportsSkippedNewAndConflicts()
    local env, S, stores = fresh()
    env.EasyFindDB.shortkeys = { ["spell:1"] = { key = "CTRL-F", name = "Dash" } }
    stores.aliases[1] = { text = "dash", key = "spell:1", name = "Dash" }
    stores.snippets[1] = { name = "Hello", keyword = "hi", body = "hello" }
    local decoded = {
        aliases = {
            { text = "dash", key = "spell:1", name = "Dash" },        -- conflict
            { text = "mount", key = "mount:1", name = "Pony" },       -- new
        },
        shortkeys = {
            { k = "spell:1", b = "CTRL-G", n = "Dash" },              -- conflict: row already bound
            { k = "spell:9", b = "S", n = "Strafe" },                 -- refused key
            { k = "cmd:1", b = "F6", n = "/camp" },                   -- refused command
            { k = "spell:3", b = "F7", n = "Stampede" },              -- new
        },
        blacklist = {},
        snippets = {
            { name = "Hello", keyword = "hi", body = "hello again" }, -- conflict
            { name = "Evil", keyword = "e", body = "/run DoEvil()" }, -- refused
            { name = "Wave", keyword = "w", body = "/wave" },         -- new
        },
    }
    local a = S:AnalyzeImport(decoded, "both")
    H.assertEq(#a.newRows.aliases, 1)
    H.assertEq(#a.newRows.shortkeys, 1)
    H.assertEq(a.newRows.shortkeys[1].b, "F7")
    H.assertEq(#a.conflicts, 2, "one alias and one shortkey conflict")
    H.assertEq(#a.skipped, 2)
    H.assertEq(a.skipped[1].reason, "key")
    H.assertEq(a.skipped[2].reason, "command")
    H.assertEq(#a.disruptive, 0, "refused commands never reach the disruptive warning")
    H.assertEq(#a.newRows.snippets, 0, "snippets only under the snippet scope")

    local s = S:AnalyzeImport(decoded, "snippet")
    H.assertEq(#s.newRows.snippets, 1)
    H.assertEq(s.newRows.snippets[1].name, "Wave")
    H.assertEq(#s.conflicts, 1)
    -- A different name on an existing keyword is a conflict too.
    local byKeyword = S:AnalyzeImport({ snippets = { { name = "Greeting", keyword = "hi", body = "hey" } } }, "snippet")
    H.assertEq(#byKeyword.conflicts, 1, "keyword clash")
    H.assertEq(#byKeyword.newRows.snippets, 0)
    H.assertEq(s.conflicts[1].section, "snippets")
    H.assertEq(#s.skipped, 1)
    H.assertEq(s.skipped[1].reason, "command")
    H.assertEq(s.skipped[1].label, "e  Evil")
    H.assertEq(#s.newRows.aliases, 0)
end

local pass, fail, failures = H.runSuite("ShareCodes", tests)
return { pass = pass, fail = fail, failures = failures }
