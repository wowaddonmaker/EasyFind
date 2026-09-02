local _, ns = ...

-- Reusable text snippets. Stored in EasyFindDB.snippets so they work with no
-- companion loaded: search rows insert into chat, a keyword followed by a
-- space expands inline in chat editboxes, and the notes companion (when
-- present) receives the raw body so its formatting survives there. Bodies use
-- the notes markdown tokens (**bold**, *italic*, __underline__, ~~strike~~);
-- chat always receives the flattened plain text.

local Snippets = {}
ns.Snippets = Snippets

local Utils = ns.Utils
local L = ns.L

local slower = Utils.slower
local sformat = Utils.sformat
local ssub = Utils.ssub
local mceil = Utils.mceil
local hooksecurefunc = hooksecurefunc
local sbyte = string.byte
local sgsub = string.gsub
local sgmatch = string.gmatch
local smatch = Utils.smatch
local sfind = Utils.sfind
local tconcat = Utils.tconcat
local tremove = Utils.tremove
local type = Utils.type
local wipe = wipe
local strtrim = strtrim
local date = date
local UnitName = UnitName
local CreateFrame = CreateFrame
local C_Map = C_Map
local GameTooltip = GameTooltip
local EditMacro = EditMacro
local GetMacroInfo = GetMacroInfo
local InCombatLockdown = InCombatLockdown

local function SnippetList()
    if type(EasyFindDB) ~= "table" then return nil end
    if type(EasyFindDB.snippets) ~= "table" then EasyFindDB.snippets = {} end
    return EasyFindDB.snippets
end

-- keyword (lowered) -> snippet. Rebuilt on save/delete/login instead of per
-- chat keystroke; the expansion hook only does a table lookup.
local keywordLookup = {}
Snippets._keywordLookup = keywordLookup

-- Declared early: RefreshTriggerTexts below repaints its hint on trigger
-- change; the frame itself is built lazily much further down.
local editorFrame

-- The activation character ("\" by default, user-selectable). Everything
-- that recognizes a trigger reads these module fields; the patterns are
-- rebuilt ONCE per change, never per keystroke. The curated set avoids
-- collisions the user cannot foresee: "/" (commands), "%" (chat
-- substitutions), "|" (escapes), and anything a word can start with.
local TRIGGER_CHOICES = { "\\", "!", "#", "~", "&", "+", "=" }
Snippets.TRIGGER_CHOICES = TRIGGER_CHOICES
local triggerChar, triggerByte = "\\", 92
local expandCallPattern, callContextPattern, helpPattern

function Snippets.TriggerChar()
    return triggerChar
end

function Snippets.RefreshTrigger()
    local c = EasyFind and EasyFind.db and EasyFind.db.snippetTriggerChar
    local valid = false
    for i = 1, #TRIGGER_CHOICES do
        if TRIGGER_CHOICES[i] == c then valid = true break end
    end
    if not valid then c = "\\" end
    triggerChar = c
    triggerByte = sbyte(c)
    local esc = "%" .. c
    expandCallPattern = "(" .. esc .. "[^%s" .. esc .. "%(]+)(%b())%s$"
    callContextPattern = esc .. "([^%s" .. esc .. "%(%)%?]+)(%([^%)]*)$"
    helpPattern = esc .. "([^%s" .. esc .. "%(%)%?]+)%?$"
end
Snippets.RefreshTrigger()

local function FormattedKeywordHint()
    return sformat(L["SNIPPET_KEYWORD_HINT"], triggerChar)
end
Snippets.FormattedKeywordHint = FormattedKeywordHint

-- Live text that carries the trigger character, re-painted on change.
function Snippets.RefreshTriggerTexts()
    if editorFrame and editorFrame.hint then
        editorFrame.hint:SetText(FormattedKeywordHint())
    end
end

-- One owner for the trigger-character picker; both cogs (the options
-- tab's create button and the editor's corner) are its click handler, so
-- a second click closes it. Single-select rows close on click, per the
-- menu conventions.
function Snippets.ToggleTriggerMenu(cogBtn)
    local keywordWord = slower(L["SNIPPET_KEYWORD"] or "keyword")
    local rows = {}
    for i = 1, #TRIGGER_CHOICES do
        local choice = TRIGGER_CHOICES[i]
        rows[#rows + 1] = {
            text = choice .. keywordWord,
            icon = (choice == triggerChar) and "Interface\\Buttons\\UI-CheckBox-Check" or nil,
            onClick = function()
                if EasyFind and EasyFind.db then
                    EasyFind.db.snippetTriggerChar = choice
                end
                Snippets.RefreshTrigger()
                Snippets.RefreshTriggerTexts()
            end,
        }
    end
    return Utils.ToggleCursorMenu("EasyFindSnippetTriggerMenu", rows, {
        anchorFrame = cogBtn,
        toggleOwner = cogBtn,
        point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT", offsetY = -2,
    })
end

function Snippets.RebuildKeywordLookup()
    wipe(keywordLookup)
    local list = SnippetList()
    if not list then return end
    for i = 1, #list do
        local snippet = list[i]
        local keyword = type(snippet) == "table" and snippet.keyword
        if type(keyword) == "string" and keyword ~= "" then
            keywordLookup[slower(keyword)] = snippet
        end
    end
end

-- Collapse newlines into spaces: what a single-line chat editbox can carry.
local function CollapseLines(text)
    return strtrim(sgsub(text or "", "%s*\n%s*", " "))
end

-- Markdown token strip WITHOUT touching line structure, so multi-line
-- targets (the macro editor) keep their template shape.
local function StripTokens(body)
    body = sgsub(body or "", "%*%*", "")
    body = sgsub(body, "__", "")
    body = sgsub(body, "~~", "")
    body = sgsub(body, "%*", "")
    return body
end

-- Legacy markdown flatten, for snippets saved before the notes-model editor
-- (no `flat` copy): strip the tokens and collapse newlines.
function Snippets.Flatten(body)
    return CollapseLines(StripTokens(body))
end

-- The plain text of a snippet: the notes-derived flat copy when present,
-- else the legacy markdown strip of the body. Newlines collapse by default
-- (chat editboxes are single-line); keepLines preserves them for
-- multi-line targets like the macro editor, where the line structure IS
-- the template.
local function PlainText(snippet, keepLines)
    local flat = snippet.flat
    local text = type(flat) == "string" and flat or StripTokens(snippet.body)
    if keepLines then return strtrim(text) end
    return CollapseLines(text)
end

local function ZoneName()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then return "" end
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    return info and info.name or ""
end

-- Placeholder tokens are syntax, not prose: they stay literal English in
-- every locale (documented by SNIPPET_FORMAT_NOTE), like physical key names.
local PLACEHOLDERS = {
    date = function() return date("%Y-%m-%d") end,
    time = function() return date("%H:%M") end,
    player = function() return UnitName and UnitName("player") or "" end,
    target = function() return UnitName and UnitName("target") or "" end,
    zone = ZoneName,
}

-- Module-level so the gsub callback stays a plain function (no closure per
-- expansion); set for the duration of one ResolvePlaceholders call.
local expansionArgs

-- Call arguments win over builtins, so \greet(target=Bob) fills {target}
-- with Bob instead of the current target. Numeric tokens ({1}) are ordinary
-- parameter names. Unknown tokens pass through untouched, which also keeps
-- Blizzard's {rt1}/{skull} chat markers working inside snippet bodies.
local function ReplacePlaceholder(token)
    local key = slower(token)
    if expansionArgs and expansionArgs[key] ~= nil then return expansionArgs[key] end
    local fill = PLACEHOLDERS[key]
    return fill and fill() or nil
end

function Snippets.ResolvePlaceholders(text, args)
    expansionArgs = args
    -- Any spaceless word, NOT %w: %w is ASCII-only in Lua, and localized
    -- clients name their blanks in their own script ({враг}, {友方}).
    local resolved = (sgsub(text or "", "{([^{}%s]+)}", ReplacePlaceholder))
    expansionArgs = nil
    return resolved
end

-- The body is the signature: every brace token that is not a builtin is a
-- parameter, in order of first appearance. Nothing is declared anywhere
-- else.
function Snippets.BodyParams(text)
    local params, seen = {}, {}
    for token in sgmatch(text or "", "{([^{}%s]+)}") do
        local key = slower(token)
        if not PLACEHOLDERS[key] and not seen[key] then
            seen[key] = true
            params[#params + 1] = key
        end
    end
    return params
end

-- "Regrowth, harm=Rip" -> args map. Positional values fill parameters in
-- body order; name=value pairs land by (case-insensitive) name and may
-- name a builtin to override it. No quoting or nesting: spell names carry
-- neither commas nor equals signs, so plain splitting covers reality.
function Snippets.ParseCallArgs(argText, params)
    local args, pos = {}, 0
    for part in sgmatch(argText or "", "[^,]+") do
        part = strtrim(part)
        if part ~= "" then
            local name, value = smatch(part, "^([^=%s]+)%s*=%s*(.-)%s*$")
            if name then
                args[slower(name)] = value
            else
                pos = pos + 1
                local param = params[pos]
                if param then args[param] = part end
            end
        end
    end
    return args
end

-- What chat receives; notes receive the rich document directly.
local function ChatText(snippet, args, keepLines)
    return Snippets.ResolvePlaceholders(PlainText(snippet, keepLines), args)
end

-- Open-call context at the caret: "...\kw(argsSoFar" with the paren still
-- unclosed. Returns the keyword and the arg text typed so far, or nil.
function Snippets.CallContext(slice)
    local keyword, open = smatch(slice, callContextPattern)
    if not keyword then return nil end
    return keyword, ssub(open, 2)
end

-- The ghost remainder for the arg NAME being typed inside a call: params
-- already consumed (named or positional, mirroring ParseCallArgs) are out;
-- the current fragment prefix-matches the rest, empty fragment suggests
-- the first unused. Returns the remainder to append (with the "=" that
-- makes it a named arg), or nil (also nil while a VALUE is being typed).
function Snippets.SuggestArgRemainder(params, argBefore)
    if #params == 0 then return nil end
    local done, fragment = smatch(argBefore or "", "^(.*),([^,]*)$")
    if not done then
        done, fragment = "", argBefore or ""
    end
    if sfind(fragment, "=", 1, true) then return nil end
    local used, pos = {}, 0
    for part in sgmatch(done, "[^,]+") do
        part = strtrim(part)
        if part ~= "" then
            local name = smatch(part, "^([^=%s]+)%s*=")
            if name then
                used[slower(name)] = true
            else
                pos = pos + 1
                if params[pos] then used[params[pos]] = true end
            end
        end
    end
    fragment = smatch(fragment, "^%s*(.-)%s*$") or fragment
    local fragLower = slower(fragment)
    local fragLen = #fragLower
    for i = 1, #params do
        local param = params[i]
        if not used[param] then
            if fragLen == 0 then
                return param .. "="
            elseif #param > fragLen and ssub(param, 1, fragLen) == fragLower then
                return ssub(param, fragLen + 1) .. "="
            elseif param == fragLower then
                return "="
            end
        end
    end
    return nil
end

-- findCandidate for the shared autocomplete engine: full-text candidate
-- (typed .. remainder) when the caret sits inside an open snippet call.
local function SnippetArgCandidate(typed)
    if EasyFind and EasyFind.db and EasyFind.db.snippetChatExpansion == false then return nil end
    local from = #typed > 80 and #typed - 80 or 1
    if not sfind(typed, triggerChar, from, true) then return nil end
    local keyword, argBefore = Snippets.CallContext(typed)
    if not keyword then return nil end
    local snippet = keywordLookup[slower(keyword)]
    if not snippet then return nil end
    local remainder = Snippets.SuggestArgRemainder(
        Snippets.BodyParams(PlainText(snippet)), argBefore)
    if not remainder or remainder == "" then return nil end
    return typed .. remainder
end

-- "\kw?" help: a tooltip with the call signature and the snippet text, so
-- the args never have to be remembered. Shown while the "?" sits at the
-- caret; any other keystroke context hides it.
local function TrimToCharBoundary(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 1 and sbyte(s, cut + 1) and sbyte(s, cut + 1) >= 128 and sbyte(s, cut + 1) < 192 do
        cut = cut - 1
    end
    return ssub(s, 1, cut) .. "..."
end

local function HideSnippetHelp(editBox)
    if not editBox._efSnipHelp then return end
    editBox._efSnipHelp = nil
    if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(editBox) then
        GameTooltip:Hide()
    end
end

local function UpdateSnippetHelp(editBox, text, caret)
    if not GameTooltip then return end
    local slice = ssub(text, 1, caret)
    local keyword = smatch(slice, helpPattern)
    local snippet = keyword and keywordLookup[slower(keyword)]
    if not snippet then
        HideSnippetHelp(editBox)
        return
    end
    local params = Snippets.BodyParams(PlainText(snippet))
    local signature = triggerChar .. slower(keyword)
    if #params > 0 then
        signature = signature .. "(" .. tconcat(params, ", ") .. ")"
    end
    GameTooltip:SetOwner(editBox, "ANCHOR_TOP")
    GameTooltip:AddLine(signature, ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3])
    -- Line structure survives: ClipboardSafeText strips markup WITHOUT
    -- collapsing newlines (StripMarkup is the one-line normalizer).
    GameTooltip:AddLine(TrimToCharBoundary(Utils.ClipboardSafeText(PlainText(snippet, true)) or "", 220),
        1, 1, 1, true)
    GameTooltip:Show()
    editBox._efSnipHelp = true
end

local function FindByName(name)
    local list = SnippetList()
    if not (list and name) then return nil end
    local nameLower = slower(name)
    for i = 1, #list do
        local snippet = list[i]
        if type(snippet) == "table" and snippet.name
           and slower(snippet.name) == nameLower then
            return snippet, i
        end
    end
    return nil
end

-- Chat-first insertion: the active chat editbox when one is open, else open
-- one pre-filled; the copy box is the no-chat-API fallback.
function Snippets:RunByName(name)
    local snippet = FindByName(name)
    if not snippet then return end
    local text = ChatText(snippet)
    if text == "" then return end
    local active = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if active then
        active:Insert(text)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(text)
    elseif ns.ShowCopyBox then
        -- Copy-box fallback goes through the OS clipboard, where live
        -- escapes cannot survive the paste.
        ns.ShowCopyBox(Utils.ClipboardSafeText(text))
    end
end

-- The send-link menu's payload for a snippet row: the same resolved chat
-- text the keyword expansion produces.
function Snippets:GetChatTextByName(name)
    local snippet = FindByName(name)
    if not snippet then return nil end
    local text = ChatText(snippet)
    return text ~= "" and text or nil
end

function Snippets:EditByName(name)
    local _, index = FindByName(name)
    if index then
        self:OpenEditor(index)
    end
end

-- The notes editor lives in the separate EasyFind_Notes addon; load it on
-- demand and detect its exported handle. (The WIP's ns.Companions loader
-- never landed on this line; this is the funnel-style equivalent.)
local function LoadNotesAddon()
    if ns.Notes then return true end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Notes")
    end
    return ns.Notes ~= nil
end

function Snippets:InsertIntoNote(name)
    local snippet = FindByName(name)
    if not snippet then return end
    if not LoadNotesAddon() then return end
    local notes = ns.Notes
    if not notes then return end
    if (snippet.flat or snippet.decorations) and notes.InsertDocumentAtCursor then
        -- Rich document: inserted natively (placeholder tokens stay literal;
        -- resolving them would shift the decoration byte ranges).
        notes.InsertDocumentAtCursor({
            body = snippet.body,
            decorations = snippet.decorations,
        })
    elseif notes.InsertAtCursor then
        notes.InsertAtCursor(self.ResolvePlaceholders(snippet.body))
    end
end

-- Chat expansion: a keyword followed by the just-typed space becomes the
-- snippet text. userInput gates recursion (our SetText re-fires with false).
local function OnChatTextChanged(editBox, userInput)
    if not userInput then return end
    if EasyFind and EasyFind.db and EasyFind.db.snippetChatExpansion == false then return end
    local text = editBox:GetText()
    local textLen = text and #text or 0
    if textLen < 2 then return end
    -- The trigger is the word ending AT THE CARET, not at the buffer end:
    -- in a multiline box (macro editor) or when editing mid-line, the typed
    -- space is never the last byte of the whole text.
    local caret = editBox:GetCursorPosition() or textLen
    if caret < 2 or caret > textLen then
        HideSnippetHelp(editBox)
        return
    end
    if sbyte(text, caret) ~= 32 then
        -- Non-expanding keystroke: maintain the "\kw?" help tooltip (the
        -- arg-name ghost rides the shared autocomplete hook instead).
        UpdateSnippetHelp(editBox, text, caret)
        return
    end
    HideSnippetHelp(editBox)
    local slice = ssub(text, 1, caret)
    -- Call form first: "\kw(Regrowth, harm=Rip) ". %b() tolerates the
    -- spaces inside the parens that the bare-word matcher below cannot.
    local token, argText
    local callWord, parens = smatch(slice, expandCallPattern)
    if callWord then
        token = callWord .. parens
        argText = ssub(parens, 2, -2)
    else
        token = smatch(slice, "(%S+)%s$")
    end
    if not token then return end
    -- ONLY the explicit "\keyword " form expands (with "\" being the
    -- user-selectable trigger character). A bare keyword is too often a
    -- real word, and a silent mid-sentence replacement is a worse
    -- experience than requiring the escape. The curated choices exclude
    -- "/" so the trigger can never collide with slash commands.
    if sbyte(token, 1) ~= triggerByte then return end
    local keyword = callWord and ssub(callWord, 2) or ssub(token, 2)
    local snippet = keywordLookup[slower(keyword)]
    if not snippet then return end
    local args
    if argText and argText ~= "" then
        args = Snippets.ParseCallArgs(argText, Snippets.BodyParams(PlainText(snippet)))
    end
    -- Multi-line targets (macro editor) keep the snippet's line structure;
    -- single-line chat editboxes get newlines collapsed to spaces.
    local keepLines = editBox.IsMultiLine and editBox:IsMultiLine() or false
    local expanded = ChatText(snippet, args, keepLines)
    if expanded == "" then return end
    local wordStart = caret - #token - 1
    local newText = ssub(text, 1, wordStart) .. expanded .. " " .. ssub(text, caret + 1)
    -- Macro BODY editor: an addon-written pending value is session-tainted,
    -- and Blizzard's dirty-gated SaveMacro (tab change, OnShow's
    -- ChangeTab(1), the combat auto-commit) would later feed it to the
    -- protected EditMacro and blame EasyFind. So the expansion COMMITS
    -- ITSELF through EditMacro in this same hardware keystroke (macro
    -- writes are hardware-event-gated, and this runs inside one), then
    -- clears the dirty flag: Blizzard never has our pending text to save.
    -- Self-verifying: the macro is read back, and if the commit did not
    -- land (combat lockdown, or a rules change under a future patch), the
    -- box is left untouched and the copy dialog takes over.
    if editBox._efSnippetMacroBox then
        local macroFrame = _G["MacroFrame"]
        local body = editBox == _G["MacroFrameText"]
            and macroFrame and macroFrame.GetSelectedIndex and macroFrame.GetMacroDataIndex
        if not body then
            -- Not the body box (the create-popup's name field): inline is
            -- safe, nothing feeds these values to a protected API's
            -- pending-save path.
            editBox:SetText(newText)
            editBox:SetCursorPosition(wordStart + #expanded + 1)
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            Snippets.ShowMacroHandoff(expanded, snippet.name)
            return
        end
        local selectedIndex = macroFrame:GetSelectedIndex()
        local actualIndex = selectedIndex and macroFrame:GetMacroDataIndex(selectedIndex)
        if actualIndex and EditMacro then
            -- Committed text == box text EXACTLY, so saved and shown never
            -- differ (the trailing expansion space is harmless in a body).
            pcall(EditMacro, actualIndex, nil, nil, newText)
        end
        local savedBody
        if actualIndex and GetMacroInfo then
            local _, _, saved = GetMacroInfo(actualIndex)
            savedBody = saved
        end
        if savedBody ~= newText then
            Snippets.ShowMacroHandoff(expanded, snippet.name)
            return
        end
        editBox:SetText(newText)
        editBox:SetCursorPosition(wordStart + #expanded + 1)
        macroFrame.textChanged = nil
        -- OnTextChanged lands one frame late and re-dirties the frame; as
        -- long as the box still holds exactly what was committed, the
        -- pending state stays cleared (a same-frame user keystroke keeps
        -- its dirty flag, correctly).
        Utils.SafeAfter(0, function()
            if editBox:GetText() == newText then
                macroFrame.textChanged = nil
            end
        end)
        return
    end
    editBox:SetText(newText)
    editBox:SetCursorPosition(wordStart + #expanded + 1)
end

-- Public: companions (EasyChat) attach their own message editboxes.
function Snippets.AttachExpansion(editBox)
    if not editBox or editBox._efSnippetHooked then return end
    editBox._efSnippetHooked = true
    editBox:HookScript("OnTextChanged", OnChatTextChanged)
    editBox:HookScript("OnEditFocusLost", HideSnippetHelp)
    -- Arg-name ghost inside "\kw(": the same engine as the search bar's
    -- autocomplete, end-of-text only (rendering rebuilds the box text).
    -- Never on macro-owned boxes: the ghost renders via SetText, which
    -- would taint the macro text the same way inline expansion did.
    if Utils.AttachAutocomplete and not editBox._efSnippetMacroBox then
        Utils.AttachAutocomplete(editBox, {
            endOfTextOnly = true,
            applyOnType = true,
            findCandidate = SnippetArgCandidate,
        })
    end
end

-- The modern macro window keys its editbox off the frame tree, not the old
-- MacroFrameText global, so find editboxes by walking MacroFrame. Cold path
-- (addon load / window show); AttachExpansion is idempotent per editbox.
local function AttachEditBoxesIn(frame, depth)
    if not frame or depth > 6 then return end
    if frame.GetObjectType and frame:GetObjectType() == "EditBox" then
        -- Macro-owned boxes are marked: expansion routes to the taint-free
        -- copy handoff and the arg ghost stays off (see OnChatTextChanged).
        frame._efSnippetMacroBox = true
        Snippets.AttachExpansion(frame)
        return
    end
    if not frame.GetChildren then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        AttachEditBoxesIn(children[i], depth + 1)
    end
end

local function AttachMacroExpansion()
    local legacyBox = _G["MacroFrameText"]
    if legacyBox then legacyBox._efSnippetMacroBox = true end
    Snippets.AttachExpansion(legacyBox)
    local macroFrame = _G["MacroFrame"]
    if not macroFrame then return end
    AttachEditBoxesIn(macroFrame, 1)
    if not macroFrame._efSnippetShowHook then
        macroFrame._efSnippetShowHook = true
        -- Lazily built children (selector popouts, rebuilt editors) only
        -- exist once shown; re-scan on every show.
        macroFrame:HookScript("OnShow", function(self)
            Snippets.AttachExpansion(_G["MacroFrameText"])
            AttachEditBoxesIn(self, 1)
        end)
    end
end

local function InstallChatExpansion()
    -- Preferred: one function hook covering every chat editbox and immune
    -- to frame-script wipes. 12.0 removed the ChatEdit_OnTextChanged global
    -- (probe-verified), so live clients take the per-frame fallback below;
    -- the guarded attempt stays in case a later build restores the funnel.
    if ChatEdit_OnTextChanged and hooksecurefunc then
        hooksecurefunc("ChatEdit_OnTextChanged", OnChatTextChanged)
        Snippets._expansionMode = "global-hook"
        return
    end
    local windowCount = NUM_CHAT_WINDOWS or 10
    for i = 1, windowCount do
        Snippets.AttachExpansion(_G["ChatFrame" .. i .. "EditBox"])
    end
    Snippets._expansionMode = "per-frame"
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:RegisterEvent("ADDON_LOADED")
loginFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        -- The default macro window is LoadOnDemand; its editboxes are plain
        -- ones (no ChatEdit funnel), so they get the per-editbox attach.
        if addonName == "Blizzard_MacroUI" then
            self:UnregisterEvent("ADDON_LOADED")
            AttachMacroExpansion()
        end
        return
    end
    self:UnregisterEvent("PLAYER_LOGIN")
    -- The saved trigger character is only readable once the db exists.
    Snippets.RefreshTrigger()
    Snippets.RebuildKeywordLookup()
    InstallChatExpansion()
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then
        self:UnregisterEvent("ADDON_LOADED")
        AttachMacroExpansion()
    end
end)

-- Search data ------------------------------------------------------------

local SNIPPET_KEYWORDS = { "snippet", "snippets" }
local PREVIEW_MAX = 60

local function SnippetSubtext(snippet, flatBody)
    -- Links and color codes flatten to their display text BEFORE the byte
    -- truncation: cutting inside an escape renders the preview as nothing
    -- but the ellipsis.
    local preview = Utils.StripMarkup(flatBody) or ""
    if #preview > PREVIEW_MAX then
        preview = ssub(preview, 1, PREVIEW_MAX - 3) .. "..."
    end
    local keyword = snippet.keyword
    if type(keyword) == "string" and keyword ~= "" then
        if preview == "" then return keyword end
        return keyword .. " - " .. preview
    end
    return preview
end

local function OpenEditorNew()
    Snippets:OpenEditor(nil)
end

function Snippets:BuildSearchData()
    local entries = {}
    -- The app row: plain "Snippets", opening the management tab -- the
    -- same searchable front door Calculator and Icon Search have. The
    -- options panel is a LoadOnDemand companion; request it first.
    entries[1] = {
        name = L["FILTER_SNIPPETS"],
        nameLower = slower(L["FILTER_SNIPPETS"]),
        category = "Snippet",
        keywords = SNIPPET_KEYWORDS,
        nativeRun = function()
            if ns.RequestOptionsPanel and ns.RequestOptionsPanel()
               and ns.Options and ns.Options.OpenAtSnippets then
                ns.Options:OpenAtSnippets()
            end
        end,
        noPin = true,
        snippetsLauncher = true,
    }
    entries[2] = {
        name = L["SNIPPET_CREATE"],
        nameLower = slower(L["SNIPPET_CREATE"]),
        category = "Snippet",
        keywords = SNIPPET_KEYWORDS,
        searchCommandDesc = L["SNIPPET_CREATE_SUB"],
        nativeRun = OpenEditorNew,
        noPin = true,
        snippetCreate = true,
    }
    local list = SnippetList()
    if list then
        for i = 1, #list do
            local snippet = list[i]
            if type(snippet) == "table" and type(snippet.name) == "string"
               and snippet.name ~= "" then
                local keyword = snippet.keyword
                local flatBody = PlainText(snippet)
                -- Searchable by name (scored as usual), keyword, and body
                -- content: the flattened body rides along as a keyword so
                -- the standard scorer and index cover content matches.
                local keywordsLower = { "snippet", "snippets" }
                if type(keyword) == "string" and keyword ~= "" then
                    keywordsLower[#keywordsLower + 1] = slower(keyword)
                end
                if flatBody ~= "" then
                    keywordsLower[#keywordsLower + 1] = slower(flatBody)
                end
                entries[#entries + 1] = {
                    name = snippet.name,
                    nameLower = slower(snippet.name),
                    category = "Snippet",
                    keywordsLower = keywordsLower,
                    searchCommandDesc = SnippetSubtext(snippet, flatBody),
                    snippetIndex = i,
                    -- Scored with the name tiers (Database/Search.lua): the
                    -- trigger keyword is effectively the snippet's second
                    -- name, so typing it exactly must rank like an exact hit.
                    snippetKeywordLower = (type(keyword) == "string" and keyword ~= "")
                        and slower(keyword) or nil,
                }
            end
        end
    end
    return entries
end

local function RefreshSnippetRows()
    Snippets.RebuildKeywordLookup()
    -- Repopulate NOW (and refresh the open search): a bare dirty-mark waits
    -- for a provider request that eager categories never receive again after
    -- their first load, so a freshly saved snippet would stay invisible.
    if ns.Database and ns.Database.RefreshDynamicCategory then
        ns.Database:RefreshDynamicCategory("snippets")
    end
    if ns.Options and ns.Options.RefreshSnippetsList then
        ns.Options.RefreshSnippetsList()
    end
end

-- Editor dialog ----------------------------------------------------------

local DIALOG_W = 440
local DIALOG_PAD = 14
local FIELD_H = 26
local BODY_H = 120
-- Bodies cap at the chat message limit so an expansion can never overflow
-- what a single chat line carries.
local CHAT_MAX = ns.CHAT_MESSAGE_MAX_CHARS or 255

local function UpdateCharCounter(f)
    f.charCounter:SetText(f.bodyBox:GetNumLetters() .. "/" .. CHAT_MAX)
end

local function LabeledField(parent, labelText, y, height, multiLine)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", DIALOG_PAD, y)
    label:SetText(labelText)

    local field = CreateFrame("Frame", nil, parent)
    field:SetPoint("TOPLEFT", DIALOG_PAD, y - 14)
    field:SetPoint("RIGHT", -DIALOG_PAD, 0)
    field:SetHeight(height)
    local bg = field:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.45)

    local editBox
    if multiLine then
        local scroll = CreateFrame("ScrollFrame", nil, field)
        scroll:SetPoint("TOPLEFT", 8, -5)
        scroll:SetPoint("BOTTOMRIGHT", -8, 5)
        editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetWidth(DIALOG_W - DIALOG_PAD * 2 - 16)
        editBox:SetFontObject("GameFontHighlight")
        editBox:SetAutoFocus(false)
        editBox:SetTextInsets(0, 0, 0, 0)
        scroll:SetScrollChild(editBox)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local maxScroll = (editBox:GetHeight() or 0) - self:GetHeight()
            if maxScroll < 0 then maxScroll = 0 end
            local target = self:GetVerticalScroll() - delta * 20
            if target < 0 then target = 0 elseif target > maxScroll then target = maxScroll end
            self:SetVerticalScroll(target)
        end)
        editBox:SetScript("OnCursorChanged", function(self, _, cursorY, _, cursorH)
            local offset = scroll:GetVerticalScroll()
            local top = -cursorY
            local viewH = scroll:GetHeight()
            if top < offset then
                scroll:SetVerticalScroll(top)
            elseif top + cursorH > offset + viewH then
                scroll:SetVerticalScroll(top + cursorH - viewH)
            end
        end)
        -- Clicking anywhere in the body area focuses the editbox, not just
        -- the exact glyph column the pooled editbox happens to cover.
        field:EnableMouse(true)
        field:SetScript("OnMouseDown", function() editBox:SetFocus() end)
    else
        editBox = CreateFrame("EditBox", nil, field)
        editBox:SetPoint("LEFT", 8, 0)
        editBox:SetPoint("RIGHT", -8, 0)
        editBox:SetHeight(20)
        editBox:SetFontObject("GameFontHighlight")
        editBox:SetAutoFocus(false)
        editBox:SetJustifyH("LEFT")
    end
    return editBox, y - 14 - height, label
end

local function CloseEditor()
    if editorFrame then editorFrame:Hide() end
end


local function UnfocusBox(self)
    self:ClearFocus()
end

local function SaveEditor()
    local f = editorFrame
    if not f then return end
    local list = SnippetList()
    if not list then return end
    local name = strtrim(f.nameBox:GetText() or "")
    if name == "" then
        f.nameBox:SetFocus()
        return
    end
    local keyword = sgsub(strtrim(f.keywordBox:GetText() or ""), "%s+", "")
    local snippet = f._editIndex and list[f._editIndex]
    if not snippet then
        snippet = {}
        list[#list + 1] = snippet
    end
    snippet.name = name
    snippet.keyword = keyword ~= "" and keyword or nil
    if f._notesHost then
        -- Rich body (notes model: glyph bold/italic, decoration ranges) plus
        -- a plain copy derived by the notes engine: everything outside notes
        -- (chat, macros, search previews) consumes the plain copy directly.
        local doc = f._notesHost:GetDocument()
        snippet.body = doc.body or ""
        snippet.decorations = doc.decorations and #doc.decorations > 0
            and doc.decorations or nil
        snippet.flat = ns.Notes and ns.Notes.FlattenDocument
            and ns.Notes.FlattenDocument(doc) or snippet.body
    else
        snippet.body = f.bodyBox:GetText() or ""
        snippet.decorations = nil
        snippet.flat = nil
    end
    f:Hide()
    RefreshSnippetRows()
end

-- Shared by the editor's Delete button and the result row context menu.
function Snippets:DeleteWithConfirm(index)
    local list = SnippetList()
    local snippet = list and list[index]
    if not snippet then return end
    ns.ShowThemedDialog({
        text = sformat(L["SNIPPET_DELETE_CONFIRM"], snippet.name or ""),
        acceptText = _G["DELETE"] or "Delete",
        onAccept = function()
            local liveList = SnippetList()
            if liveList and liveList[index] then
                tremove(liveList, index)
            end
            if editorFrame and editorFrame:IsShown() and editorFrame._editIndex == index then
                editorFrame:Hide()
            end
            RefreshSnippetRows()
        end,
    })
end

local function DeleteFromEditor()
    local f = editorFrame
    if f and f._editIndex then
        Snippets:DeleteWithConfirm(f._editIndex)
    end
end

local function AnnotationHeight(fs)
    local h = fs:GetStringHeight() or 12
    if h < 12 then h = 12 end
    return mceil(h)
end

-- Macro handoff (Shift-expansion): the expanded template in a multi-line
-- copy dialog. A hardware Ctrl+V is a secure write, so a macro filled this
-- way carries no addon taint and Blizzard's combat-time auto-commit stays
-- silent for it.
local handoffFrame

local function EnsureMacroHandoff()
    if handoffFrame then return handoffFrame end
    local f = CreateFrame("Frame", "EasyFindSnippetMacroHandoff", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetFrameLevel(1005)
    f:SetWidth(DIALOG_W)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetPoint("CENTER", 0, 160)
    ns.StyleMenuPanel(f)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOPLEFT", DIALOG_PAD, -12)

    local y = -30
    f.copyBox = LabeledField(f, "", y, BODY_H, true)
    y = y - 14 - BODY_H

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("TOPLEFT", DIALOG_PAD, y - 8)
    f.hint:SetWidth(DIALOG_W - DIALOG_PAD * 2)
    f.hint:SetJustifyH("LEFT")
    f.hint:SetWordWrap(true)
    f.hint:SetText(L["SNIPPET_MACRO_COPY_HINT"])

    local flashGap = 6
    local flash = Utils.AttachCopiedFlash(f.copyBox, f, f.hint, -flashGap)
    f:SetHeight(-(y - 8) + AnnotationHeight(f.hint) + flashGap + flash:GetHeight() + DIALOG_PAD)

    local function CloseHandoff() f:Hide() end
    f.copyBox:SetScript("OnEscapePressed", CloseHandoff)
    Utils.AttachEscClose(f, CloseHandoff)
    -- Outside-click close, same pattern as the menu dropdowns: a popup
    -- that will not go away when you click past it is worse than none.
    f:SetScript("OnUpdate", function(self)
        local inside = Utils.IsFrameVisiblyMouseOver(self)
        if not inside and not self._mouseWasInside
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            self:Hide()
        end
        self._mouseWasInside = inside
    end)
    -- Re-select on focus so a click back into the box keeps Ctrl+C easy.
    f.copyBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    f:Hide()
    handoffFrame = f
    return f
end

function Snippets.ShowMacroHandoff(text, name)
    local f = EnsureMacroHandoff()
    f.title:SetText(name or L["FILTER_SNIPPETS"])
    local r, g, b = ns.TooltipTextColor()
    f.title:SetTextColor(r, g, b)
    f.hint:SetTextColor(r, g, b)
    -- The box exists to be Ctrl+C'd: live escapes cannot survive the
    -- clipboard (the client escapes pipes on paste), so links flatten to
    -- their [Name] text here rather than pasting as |H garbage.
    f.copyBox:SetText(Utils.ClipboardSafeText(text) or "")
    f:Show()
    f.copyBox:SetFocus()
    f.copyBox:HighlightText()
end

local function EnsureEditor()
    if editorFrame then return editorFrame end
    local f = CreateFrame("Frame", "EasyFindSnippetEditor", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    -- Above the companion windows; the themed dialog (1010) still layers
    -- over this so the delete confirm reads on top.
    f:SetFrameLevel(1000)
    f:SetWidth(DIALOG_W)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetPoint("CENTER", 0, 120)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ns.StyleMenuPanel(f)

    f._chromeTexts = {}
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOPLEFT", DIALOG_PAD, -12)
    f._chromeTexts[#f._chromeTexts + 1] = f.title

    local y = -34
    local nameLabel, keywordLabel, bodyLabel
    f.nameBox, y, nameLabel = LabeledField(f, L["SNIPPET_NAME"], y, FIELD_H)
    y = y - 10
    f.keywordBox, y, keywordLabel = LabeledField(f, L["SNIPPET_KEYWORD"], y, FIELD_H)

    -- TOPLEFT + explicit width, never a RIGHT point: pairing TOPLEFT with a
    -- RIGHT point also pins the vertical center, which constrains the height
    -- to one line and ellipsizes instead of wrapping.
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("TOPLEFT", DIALOG_PAD, y - 6)
    f.hint:SetWidth(DIALOG_W - DIALOG_PAD * 2)
    f.hint:SetJustifyH("LEFT")
    f.hint:SetWordWrap(true)
    f.hint:SetText(FormattedKeywordHint())
    y = y - 6 - AnnotationHeight(f.hint) - 10

    -- Trigger-character cog, top right: the same picker as the options
    -- tab's cog. The choice is GLOBAL; the tooltip says so.
    local trigBtn = ns.CreateCogButton(f)
    trigBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -DIALOG_PAD + 4, -9)
    trigBtn:SetScript("OnClick", Snippets.ToggleTriggerMenu)
    Utils.AttachDelayedTooltip(trigBtn, "ANCHOR_RIGHT", function()
        return sformat(L["SNIPPET_TRIGGER"], Snippets.TriggerChar()), L["SNIPPET_TRIGGER_NOTE"]
    end)
    f.trigBtn = trigBtn

    -- Body: the notes companion's own editor when installed -- the exact
    -- notes experience (WYSIWYG bold/italic, underline/strike/color
    -- decorations, lists, the full toolbar with active states). Without the
    -- companion, a plain editbox: chat receives plain text anyway, so the
    -- fallback loses nothing chat-visible.
    if LoadNotesAddon() and ns.Notes.AttachSnippetBodyEditor then
        bodyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bodyLabel:SetPoint("TOPLEFT", DIALOG_PAD, y)
        bodyLabel:SetText(L["SNIPPET_TEXT"])
        local host = ns.Notes.AttachSnippetBodyEditor(f, {
            width = DIALOG_W - DIALOG_PAD * 2,
            height = BODY_H,
            maxLetters = CHAT_MAX,
            onTextChanged = function() UpdateCharCounter(f) end,
        })
        f._notesHost = host
        host.container:ClearAllPoints()
        host.container:SetPoint("TOPLEFT", DIALOG_PAD, y - 14)
        f.bodyBox = host.editor
        y = y - 14 - (host.container:GetHeight() or (BODY_H + 28))
    else
        f.bodyBox, y, bodyLabel = LabeledField(f, L["SNIPPET_TEXT"], y, BODY_H, true)
        f.bodyBox:SetMaxLetters(CHAT_MAX)
        f.bodyBox:HookScript("OnTextChanged", function() UpdateCharCounter(f) end)
    end

    -- Char counter INSIDE the text box, bottom center, floating above the
    -- text area. Both modes share the editor -> scroll -> field frame chain.
    local bodyField = f.bodyBox:GetParent():GetParent()
    local counterHolder = CreateFrame("Frame", nil, f)
    counterHolder:SetSize(1, 1)
    counterHolder:SetPoint("BOTTOM", bodyField, "BOTTOM", 0, 4)
    counterHolder:SetFrameLevel((f.bodyBox:GetFrameLevel() or 1) + 2)
    f.charCounter = counterHolder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.charCounter:SetPoint("BOTTOM", counterHolder, "BOTTOM", 0, 0)
    f.charCounter:SetTextColor(0.48, 0.48, 0.52, 1)


    f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.note:SetPoint("TOPLEFT", DIALOG_PAD, y - 8)
    f.note:SetWidth(DIALOG_W - DIALOG_PAD * 2)
    f.note:SetJustifyH("LEFT")
    f.note:SetWordWrap(true)
    f.note:SetText(L["SNIPPET_FORMAT_NOTE"])
    y = y - 8 - AnnotationHeight(f.note) - 8

    -- Advanced functionality lives behind a click: a user who just wants
    -- plain text snippets never has to read about fill-in slots.
    f.advToggle = CreateFrame("Button", nil, f)
    f.advToggle:SetSize(DIALOG_W - DIALOG_PAD * 2, 16)
    f.advToggle:SetPoint("TOPLEFT", DIALOG_PAD, y)
    f.advLabel = f.advToggle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.advLabel:SetPoint("LEFT")
    f.advToggle:SetScript("OnEnter", function() f.advLabel:SetAlpha(1) end)
    f.advToggle:SetScript("OnLeave", function() f.advLabel:SetAlpha(0.75) end)
    f.advLabel:SetAlpha(0.75)
    y = y - 16 - 6

    f.advBody = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.advBody:SetPoint("TOPLEFT", f.advToggle, "BOTTOMLEFT", 0, -2)
    f.advBody:SetWidth(DIALOG_W - DIALOG_PAD * 2)
    f.advBody:SetJustifyH("LEFT")
    f.advBody:SetWordWrap(true)
    f.advBody:SetText(L["SNIPPET_ADVANCED_BODY"])
    f.advBody:Hide()

    f._chromeTexts[#f._chromeTexts + 1] = nameLabel
    f._chromeTexts[#f._chromeTexts + 1] = keywordLabel
    f._chromeTexts[#f._chromeTexts + 1] = bodyLabel
    f._chromeTexts[#f._chromeTexts + 1] = f.hint
    f._chromeTexts[#f._chromeTexts + 1] = f.note
    f._chromeTexts[#f._chromeTexts + 1] = f.advLabel
    f._chromeTexts[#f._chromeTexts + 1] = f.advBody

    f.saveBtn = ns.CreateModernButton(f, _G["SAVE"] or "Save", 100, 22)
    f.cancelBtn = ns.CreateModernButton(f, _G["CANCEL"] or "Cancel", 100, 22)
    f.cancelBtn:SetPoint("RIGHT", f.saveBtn, "LEFT", -8, 0)
    f.deleteBtn = ns.CreateModernButton(f, _G["DELETE"] or "Delete", 100, 22)

    -- Buttons and dialog height re-derive from the expanded state; the
    -- toggle label is the collapse indicator (arrow-free by design).
    local baseButtonsY = y
    local baseHeight = -(y - 22) + DIALOG_PAD
    local function RelayoutAdvanced()
        local expanded = f.advBody:IsShown()
        f.advLabel:SetText(expanded
            and L["SNIPPET_ADVANCED"] .. " -"
            or L["SNIPPET_ADVANCED"] .. " +")
        local extra = expanded and (AnnotationHeight(f.advBody) + 8) or 0
        f.saveBtn:ClearAllPoints()
        f.saveBtn:SetPoint("TOPRIGHT", -DIALOG_PAD, baseButtonsY - extra)
        f.deleteBtn:ClearAllPoints()
        f.deleteBtn:SetPoint("TOPLEFT", DIALOG_PAD, baseButtonsY - extra)
        f:SetHeight(baseHeight + extra)
    end
    f._relayoutAdvanced = RelayoutAdvanced
    f.advToggle:SetScript("OnClick", function()
        f.advBody:SetShown(not f.advBody:IsShown())
        RelayoutAdvanced()
    end)
    RelayoutAdvanced()

    f.saveBtn:SetScript("OnClick", SaveEditor)
    f.cancelBtn:SetScript("OnClick", CloseEditor)
    f.deleteBtn:SetScript("OnClick", DeleteFromEditor)

    f.nameBox:SetScript("OnEnterPressed", function() f.keywordBox:SetFocus() end)
    f.keywordBox:SetScript("OnEnterPressed", function() f.bodyBox:SetFocus() end)
    f.nameBox:SetScript("OnTabPressed", function() f.keywordBox:SetFocus() end)
    f.keywordBox:SetScript("OnTabPressed", function() f.bodyBox:SetFocus() end)
    f.bodyBox:SetScript("OnTabPressed", function() f.nameBox:SetFocus() end)
    -- ESC layering: a focused editbox consumes ESC to unfocus itself; only
    -- an ESC with nothing focused reaches AttachEscClose and closes the
    -- window (override binds never fire while an editbox holds the keyboard).
    f.nameBox:SetScript("OnEscapePressed", UnfocusBox)
    f.keywordBox:SetScript("OnEscapePressed", UnfocusBox)
    f.bodyBox:SetScript("OnEscapePressed", UnfocusBox)
    Utils.AttachEscClose(f, CloseEditor)

    -- Shift-clicking an item/spell/achievement inserts the raw link into the
    -- body, exactly like a chat editbox. The escape string survives
    -- flattening and placeholders, so the expanded chat text keeps a fully
    -- usable link.
    --
    -- 12.1 routes these clicks through ChatFrameUtil.InsertLink; the legacy
    -- ChatEdit_InsertLink global still exists but no longer sees the call
    -- (probed in-game), so hook the namespaced path first. The click itself
    -- drops editbox focus before the insert call lands, so the gate is
    -- "editor open and chat did not consume it", not HasFocus: an active
    -- chat editbox already took the link, and inserting here too would
    -- double-paste.
    Utils.HookInsertLink(function(link)
        if not (link and link ~= "" and f:IsShown()) then return end
        local getActive = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow)
            or ChatEdit_GetActiveWindow
        if getActive and getActive() then return end
        f.bodyBox:Insert(link)
    end)

    f:Hide()
    editorFrame = f
    return f
end

function Snippets:OpenEditor(index)
    local f = EnsureEditor()
    -- Every open starts collapsed: the advanced section is reference
    -- material, not state worth remembering across edits.
    if f.advBody and f.advBody:IsShown() then
        f.advBody:Hide()
        if f._relayoutAdvanced then f._relayoutAdvanced() end
    end
    f._editIndex = index
    local list = SnippetList()
    local snippet = index and list and list[index]
    f.title:SetText(snippet and L["SNIPPET_EDIT_TITLE"] or L["SNIPPET_CREATE"])
    -- Chrome text follows the active theme; retinted per open like the
    -- other themed dialogs.
    local r, g, b = ns.TooltipTextColor()
    for i = 1, #f._chromeTexts do
        f._chromeTexts[i]:SetTextColor(r, g, b)
    end
    f.nameBox:SetText(snippet and snippet.name or "")
    f.keywordBox:SetText(snippet and snippet.keyword or "")
    if f._notesHost then
        local doc
        if snippet and (snippet.flat or snippet.decorations) then
            doc = { body = snippet.body or "", decorations = snippet.decorations }
        elseif snippet and snippet.body and snippet.body ~= ""
           and ns.Notes and ns.Notes.DocumentFromMarkdown then
            -- Snippet saved before the notes-model editor: convert its
            -- markdown once on open.
            doc = ns.Notes.DocumentFromMarkdown(snippet.body)
        else
            doc = { body = snippet and snippet.body or "", decorations = {} }
        end
        f._notesHost:SetDocument(doc)
    else
        f.bodyBox:SetText(snippet and snippet.body or "")
    end
    UpdateCharCounter(f)
    f.deleteBtn:SetShown(snippet ~= nil)
    f:Show()
    f.nameBox:SetFocus()
end

return Snippets
