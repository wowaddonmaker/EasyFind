-- Tests for Search/Snippets.lua: flattening, placeholders, search rows, and
-- the chat keyword expansion hook.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

env.date = os.date
env.EasyFindDB = { snippets = {} }
env.EasyFind = { db = { snippetChatExpansion = true } }

local Snippets = H.loadModule("Search/Snippets.lua", env, ns)
H.assertNotNil(Snippets, "Search/Snippets.lua must return the module")
H.assertEq(Snippets, ns.Snippets)

local tests = {}

local function setSnippets(list)
    env.EasyFindDB.snippets = list
    Snippets.RebuildKeywordLookup()
end

local function fakeChatBox(initialText)
    local eb = H.newFrame()
    local text = initialText or ""
    local cursor = 0
    eb.GetText = function() return text end
    eb.SetText = function(_, t)
        text = t
        local handler = eb._handlers.OnTextChanged
        if handler then handler(eb, false) end
    end
    eb.SetCursorPosition = function(_, p) cursor = p end
    -- nil caret makes the handler fall back to end-of-text, matching a chat
    -- line; tests set _caret to simulate a mid-buffer cursor.
    eb.GetCursorPosition = function() return eb._caret end
    eb._peek = function() return text, cursor end
    Snippets.AttachExpansion(eb)
    return eb
end

local function typeText(eb, t)
    -- Simulate the user finishing a keystroke: text already updated, then
    -- the OnTextChanged script fires with userInput = true.
    eb.SetText(eb, t)
    eb._handlers.OnTextChanged(eb, true)
end

function tests.flatten_stripsMarkdownTokens()
    H.assertEq(Snippets.Flatten("**bold** and *ital* and __und__ and ~~str~~"),
        "bold and ital and und and str")
end

function tests.flatten_collapsesNewlines()
    H.assertEq(Snippets.Flatten("line one\nline two\n\nline three"),
        "line one line two line three")
end

function tests.placeholders_resolveKnownTokens()
    local out = Snippets.ResolvePlaceholders("today is {date}")
    H.assertTrue(out ~= "today is {date}", "date placeholder should resolve")
    H.assertTrue(out:find("^today is %d%d%d%d%-") ~= nil, "date should be YYYY-MM-DD")
end

function tests.placeholders_unknownTokenLeftAlone()
    H.assertEq(Snippets.ResolvePlaceholders("keep {unknowntoken} as is"),
        "keep {unknowntoken} as is")
end

local function hasValue(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

function tests.buildSearchData_createRowPlusSnippets()
    setSnippets({
        { name = "Greeting", keyword = "HI", body = "**Hello** there" },
        { name = "Farewell", body = "bye" },
    })
    local rows = Snippets:BuildSearchData()
    H.assertEq(#rows, 3, "create row + 2 snippets")
    H.assertTrue(rows[1].snippetCreate == true, "first row is the create row")
    H.assertEq(rows[2].name, "Greeting")
    H.assertEq(rows[2].category, "Snippet")
    H.assertTrue(hasValue(rows[2].keywordsLower, "hi"), "keyword searchable, lowered")
    H.assertTrue(hasValue(rows[2].keywordsLower, "hello there"),
        "flattened body content searchable")
    H.assertTrue(hasValue(rows[3].keywordsLower, "bye"), "body-only snippet content searchable")
    H.assertEq(rows[2].snippetIndex, 1)
    H.assertEq(rows[3].snippetIndex, 2)
end

function tests.expansion_bareKeywordDoesNotExpand()
    -- A bare keyword is too often a real word: only "\keyword " fires.
    setSnippets({ { name = "BRB", keyword = "brb", body = "**be right back**" } })
    local eb = fakeChatBox()
    typeText(eb, "hey brb ")
    H.assertEq((eb._peek()), "hey brb ")
end

function tests.expansion_midBufferCaretExpands()
    -- The trigger word ends at the CARET, not the buffer end: editing the
    -- middle of a line (or a multiline macro) must still expand.
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    eb._caret = 5
    typeText(eb, "\\brb  keep this")
    local text, cursor = eb._peek()
    H.assertEq(text, "be right back  keep this")
    H.assertEq(cursor, 14, "caret lands after the expansion and its space")
end

function tests.expansion_macroMultilineExpands()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    eb._caret = 18
    typeText(eb, "#showtooltip\n\\brb \nmore")
    H.assertEq((eb._peek()), "#showtooltip\nbe right back \nmore")
end

function tests.expansion_backslashMidSentenceExpands()
    setSnippets({ { name = "BRB", keyword = "brb", body = "**be right back**" } })
    local eb = fakeChatBox()
    typeText(eb, "hey \\brb ")
    H.assertEq((eb._peek()), "hey be right back ")
end

function tests.expansion_keywordCaseInsensitive()
    setSnippets({ { name = "BRB", keyword = "BRB", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "\\Brb ")
    H.assertEq((eb._peek()), "be right back ")
end

function tests.expansion_backslashKeywordExpands()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "\\brb ")
    H.assertEq((eb._peek()), "be right back ")
end

function tests.params_bodyParamsSkipBuiltinsAndDedup()
    local params = Snippets.BodyParams("/cast {help}; /cast {harm}; {help} {date} {rt1}")
    H.assertEq(#params, 3, "help, harm, rt1; help deduped, date is builtin")
    H.assertEq(params[1], "help")
    H.assertEq(params[2], "harm")
    H.assertEq(params[3], "rt1")
end

function tests.params_parseCallArgsPositionalNamedMixed()
    local params = { "help", "harm" }
    local a = Snippets.ParseCallArgs("Regrowth, Rip", params)
    H.assertEq(a.help, "Regrowth")
    H.assertEq(a.harm, "Rip")
    local b = Snippets.ParseCallArgs("harm=Rip, HELP=Regrowth", params)
    H.assertEq(b.help, "Regrowth", "names are case-insensitive")
    H.assertEq(b.harm, "Rip")
    local c = Snippets.ParseCallArgs("Regrowth, harm=Rip", params)
    H.assertEq(c.help, "Regrowth", "mixed: positional fills first param")
    H.assertEq(c.harm, "Rip")
end

function tests.params_resolveWithArgsAndBuiltinOverride()
    local out = Snippets.ResolvePlaceholders("/cast {help}; hi {target}",
        { help = "Regrowth", target = "Bob" })
    H.assertEq(out, "/cast Regrowth; hi Bob", "named arg overrides the builtin")
    local bare = Snippets.ResolvePlaceholders("/cast {help}")
    H.assertEq(bare, "/cast {help}", "unfilled slots stay visible")
end

function tests.params_nonAsciiBlankNamesWork()
    local params = Snippets.BodyParams("/cast {\209\129\208\178\208\190\208\185}; /cast {\230\149\140\230\150\185}")
    H.assertEq(#params, 2, "Cyrillic and CJK blank names are parameters")
    local a = Snippets.ParseCallArgs("X, \230\149\140\230\150\185=Y", params)
    H.assertEq(a[params[1]], "X")
    H.assertEq(a[params[2]], "Y", "non-ASCII named arg lands by name")
    local out = Snippets.ResolvePlaceholders("/cast {\230\149\140\230\150\185}", a)
    H.assertEq(out, "/cast Y")
end

function tests.expansion_shiftInMacroBoxHandsOff()
    setSnippets({ { name = "Macro", keyword = "mac",
        body = "#showtooltip\n/cast {ability1}" } })
    local eb = fakeChatBox()
    eb.IsMultiLine = function() return true end
    eb._efSnippetMacroBox = true
    env.IsShiftKeyDown = function() return true end
    local handedText, handedName
    local orig = Snippets.ShowMacroHandoff
    Snippets.ShowMacroHandoff = function(text, name)
        handedText, handedName = text, name
    end
    typeText(eb, "\\mac(Regrowth) ")
    Snippets.ShowMacroHandoff = orig
    env.IsShiftKeyDown = nil
    H.assertEq((eb._peek()), "\\mac(Regrowth) ",
        "Shift-expansion never writes the macro box")
    H.assertEq(handedText, "#showtooltip\n/cast Regrowth")
    H.assertEq(handedName, "Macro")
end

function tests.expansion_plainInMacroBoxStaysInline()
    setSnippets({ { name = "Macro", keyword = "mac",
        body = "#showtooltip\n/cast {ability1}" } })
    local eb = fakeChatBox()
    eb.IsMultiLine = function() return true end
    eb._efSnippetMacroBox = true
    typeText(eb, "\\mac(Regrowth) ")
    H.assertEq((eb._peek()), "#showtooltip\n/cast Regrowth ",
        "without Shift the macro box expands inline as before")
end

function tests.expansion_multilineTargetKeepsNewlines()
    setSnippets({ { name = "Macro", keyword = "mac",
        body = "#showtooltip\n/cast {ability1}\n/cast {ability2}" } })
    local eb = fakeChatBox()
    eb.IsMultiLine = function() return true end
    typeText(eb, "\\mac(Regrowth, Rip) ")
    H.assertEq((eb._peek()),
        "#showtooltip\n/cast Regrowth\n/cast Rip ",
        "macro editor expansion keeps the template's line structure")
end

function tests.expansion_chatTargetCollapsesNewlines()
    setSnippets({ { name = "Macro", keyword = "mac",
        body = "line one\nline two" } })
    local eb = fakeChatBox()
    typeText(eb, "\\mac ")
    H.assertEq((eb._peek()), "line one line two ",
        "single-line chat still collapses newlines to spaces")
end

function tests.expansion_callFormFillsSlots()
    setSnippets({ { name = "HH", keyword = "hh",
        body = "/cast [help] {help}; /cast [harm] {harm}" } })
    local eb = fakeChatBox()
    typeText(eb, "\\hh(Regrowth, harm=Rip) ")
    H.assertEq((eb._peek()), "/cast [help] Regrowth; /cast [harm] Rip ",
        "call args survive spaces inside the parens")
end

function tests.expansion_bareCallLeavesSlotsVisible()
    setSnippets({ { name = "HH", keyword = "hh",
        body = "/cast {help}" } })
    local eb = fakeChatBox()
    typeText(eb, "\\hh ")
    H.assertEq((eb._peek()), "/cast {help} ", "bare form degrades to a template")
end

function tests.expansion_slashKeywordDoesNotExpand()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "/brb ")
    H.assertEq((eb._peek()), "/brb ", "slash prefix belongs to commands, not snippets")
end

function tests.expansion_backslashAloneDoesNotExpand()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "\\ ")
    H.assertEq((eb._peek()), "\\ ")
end

function tests.expansion_prefersFlatCopyWhenPresent()
    -- Rich bodies carry notes glyph codepoints; the flat copy derived at
    -- save time is what chat must receive.
    setSnippets({ { name = "Rich", keyword = "rich",
        body = "GLYPHS-HERE", flat = "plain chat text" } })
    local eb = fakeChatBox()
    typeText(eb, "\\rich ")
    H.assertEq((eb._peek()), "plain chat text ")
end

function tests.expansion_flatNewlinesCollapse()
    setSnippets({ { name = "Multi", keyword = "ml",
        body = "x", flat = "line one\nline two" } })
    local eb = fakeChatBox()
    typeText(eb, "\\ml ")
    H.assertEq((eb._peek()), "line one line two ")
end

function tests.expansion_ignoresMidWordMatch()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "hey \\embrb ")
    H.assertEq((eb._peek()), "hey \\embrb ", "keyword inside a longer word must not expand")
end

function tests.expansion_requiresTrailingSpace()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    local eb = fakeChatBox()
    typeText(eb, "hey \\brb")
    H.assertEq((eb._peek()), "hey \\brb", "no expansion until the space lands")
end

function tests.expansion_disabledByOption()
    setSnippets({ { name = "BRB", keyword = "brb", body = "be right back" } })
    env.EasyFind.db.snippetChatExpansion = false
    local eb = fakeChatBox()
    typeText(eb, "\\brb ")
    H.assertEq((eb._peek()), "\\brb ")
    env.EasyFind.db.snippetChatExpansion = true
end

function tests.expansion_resolvesPlaceholdersAndFlattens()
    setSnippets({ { name = "Loc", keyword = "loc", body = "**at** {unknowntoken}\nnow" } })
    local eb = fakeChatBox()
    typeText(eb, "\\loc ")
    H.assertEq((eb._peek()), "at {unknowntoken} now ")
end

local pass, fail, failures = H.runSuite("Snippets", tests)
return { pass = pass, fail = fail, failures = failures }
