local _, ns = ...

local Utils = {}
ns.Utils = Utils
local L = ns.L

local pairs, ipairs, type, select, unpack, next = pairs, ipairs, type, select, unpack, next
local tinsert, tsort, tconcat, tremove = table.insert, table.sort, table.concat, table.remove
local sfind, slower, ssub, sformat, smatch = string.find, string.lower, string.sub, string.format, string.match
local mmin, mmax, mabs, mpi, mceil, mfloor = math.min, math.max, math.abs, math.pi, math.ceil, math.floor
local pcall, xpcall, tostring, tonumber = pcall, xpcall, tostring, tonumber
local debugstack = debugstack
local CreateFrame = CreateFrame
local CreateColor = CreateColor

local function ErrorHandler(err)
    return tostring(err) .. "\n" .. debugstack(2)
end

-- Theme-change broadcast. A window registers once; every registered callback
-- fires after the active palette changes, so an open window restyles live
-- instead of only picking up the theme the next time it opens.
local themeCallbacks = {}
function ns.RegisterThemeCallback(fn)
    if type(fn) == "function" then themeCallbacks[#themeCallbacks + 1] = fn end
end
function ns.FireThemeCallbacks()
    for i = 1, #themeCallbacks do
        pcall(themeCallbacks[i])
    end
end

-- Bar controls the user configured hidden reveal on hover, like the search
-- bar's own hover-show mode: the button keeps its footprint but sits at
-- alpha 0 until the cursor crosses it, it holds keyboard focus, or its menu
-- is open. One owner for the alpha decision; callers re-run btn.RefreshReveal
-- when any input changes (setting toggled, menu opened or closed, focus moved).
function Utils.InstallBarControlReveal(btn, isConfiguredShown, isEngaged)
    local function Refresh()
        local reveal = isConfiguredShown() or btn:IsMouseOver() or btn.keyboardFocused
            or (isEngaged and isEngaged())
        btn:SetAlpha(reveal and 1 or 0)
    end
    btn.RefreshReveal = Refresh
    btn:HookScript("OnEnter", Refresh)
    btn:HookScript("OnLeave", Refresh)
    Refresh()
end

Utils.pairs   = pairs
Utils.ipairs  = ipairs
Utils.type    = type
Utils.select  = select
Utils.unpack  = unpack
Utils.next    = next

Utils.tinsert  = tinsert
Utils.tsort    = tsort
Utils.tconcat  = tconcat
Utils.tremove  = tremove

Utils.sfind    = sfind
Utils.slower   = slower
Utils.ssub     = ssub
Utils.sformat  = sformat
Utils.smatch   = smatch

Utils.mmin     = mmin
Utils.mmax     = mmax
Utils.mabs     = mabs
Utils.mpi      = mpi
Utils.mceil    = mceil
Utils.mfloor   = mfloor

Utils.pcall    = pcall
Utils.xpcall   = xpcall
Utils.tostring = tostring
Utils.tonumber = tonumber
Utils.ErrorHandler = ErrorHandler

-- Combat vetoes are not queued: callers owning combat-sensitive state must
-- arrange their own regen replay. Did-not-run paths return false plus a
-- reason ("combat", "no-object", "no-method").
function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false, "combat" end
    if not obj then return false, "no-object" end
    local fn = obj[method]
    if not fn then return false, "no-method" end
    local ok, result = xpcall(fn, ErrorHandler, obj, ...)
    if not ok then
        Utils.DebugPrint("SafeCallMethod failed: " .. tostring(result))
    end
    return ok, result
end
function Utils.FindFactionByPredicate(predicate)
    if not C_Reputation or not C_Reputation.GetNumFactions or not C_Reputation.GetFactionDataByIndex then
        return nil
    end
    local n = C_Reputation.GetNumFactions()
    for i = 1, n do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and predicate(factionData) then
            return i, factionData
        end
    end
end

function Utils.LoadBlizzardAddOn(name)
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, name)
    elseif LoadAddOn then
        pcall(LoadAddOn, name)
    end
end

function Utils.DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = Utils.DeepCopy(v) end
    return copy
end

-- Row caches persisted as tables are the single largest thing we hold at
-- login: a 5-field record rounds up to 8 hash nodes (320 B) plus a 56 B
-- header, so 5000 rows cost ~2 MB of live Lua tables that the client parses
-- before our code runs -- even for a category the player disabled and will
-- never search. The same rows as one delimited string cost ~35 B each and are
-- decoded only if something actually asks for them.
--
-- Values are self-describing (a 1-byte type tag), so decode restores the exact
-- original type. Declaring types per field would mean guessing whether e.g.
-- settingCategoryID is a number or a string, and a wrong guess corrupts the
-- cache silently.
--
-- Spec is an array of field descriptors, in order:
--   { key }                    scalar (number, string, or boolean)
--   { key, "list" }            array of scalars
--   { key, "map" }             map of scalar key -> scalar value
--   { key, "records", subSpec} array of records; subSpec is an array of keys
-- A nil field round-trips as nil; an empty list/map round-trips as nil, so
-- callers that need a table should keep their existing `or {}`.
local SEP_ROW = "\31"
local SEP_FIELD = "\30"
local SEP_ITEM = "\29"
local SEP_SUB = "\28"

local PACK_ESCAPE = {
    ["\\"] = "\\\\",
    ["\28"] = "\\a", ["\29"] = "\\b", ["\30"] = "\\c", ["\31"] = "\\d",
}
local PACK_UNESCAPE = {
    ["\\"] = "\\",
    a = "\28", b = "\29", c = "\30", d = "\31",
}

local function EncodeScalar(value)
    local valueType = type(value)
    if value == nil then return "" end
    if valueType == "number" then return "n" .. tostring(value) end
    if valueType == "boolean" then return value and "b1" or "b0" end
    return "s" .. tostring(value):gsub("[\\\28\29\30\31]", PACK_ESCAPE)
end

local function DecodeScalar(chunk)
    if chunk == "" then return nil end
    local tag = ssub(chunk, 1, 1)
    local body = ssub(chunk, 2)
    if tag == "n" then return tonumber(body) end
    if tag == "b" then return body == "1" end
    return (body:gsub("\\(.)", PACK_UNESCAPE))
end

-- Splits on sep, preserving empty fields (a bare "[^sep]*" gmatch emits
-- spurious empty matches at the separators and shifts every later field).
local function SplitPacked(str, sep)
    local out, n = {}, 0
    if str == "" then return out end
    for chunk in (str .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        n = n + 1
        out[n] = chunk
    end
    return out
end

local function EncodeField(value, kind, subSpec)
    if kind == nil then return EncodeScalar(value) end
    if type(value) ~= "table" then return "" end
    local parts, n = {}, 0
    if kind == "list" then
        for i = 1, #value do parts[i] = EncodeScalar(value[i]) end
        n = #value
    elseif kind == "map" then
        for key, item in pairs(value) do
            n = n + 1
            parts[n] = EncodeScalar(key) .. SEP_SUB .. EncodeScalar(item)
        end
    elseif kind == "records" then
        for i = 1, #value do
            local record, sub = value[i], {}
            for f = 1, #subSpec do sub[f] = EncodeScalar(record[subSpec[f]]) end
            parts[i] = tconcat(sub, SEP_SUB, 1, #subSpec)
        end
        n = #value
    end
    return tconcat(parts, SEP_ITEM, 1, n)
end

local function DecodeField(chunk, kind, subSpec)
    if kind == nil then return DecodeScalar(chunk) end
    if chunk == "" then return nil end
    local items = SplitPacked(chunk, SEP_ITEM)
    local out = {}
    if kind == "list" then
        for i = 1, #items do out[i] = DecodeScalar(items[i]) end
    elseif kind == "map" then
        for i = 1, #items do
            local pair = SplitPacked(items[i], SEP_SUB)
            local key = DecodeScalar(pair[1] or "")
            if key ~= nil then out[key] = DecodeScalar(pair[2] or "") end
        end
    elseif kind == "records" then
        for i = 1, #items do
            local fields = SplitPacked(items[i], SEP_SUB)
            local record = {}
            for f = 1, #subSpec do record[subSpec[f]] = DecodeScalar(fields[f] or "") end
            out[i] = record
        end
    end
    return out
end

-- Emits every field into one flat buffer and concatenates once, rather than
-- building a throwaway string per row: on a 5000-row cache that is 5000 fewer
-- allocations, and this garbage lands on the shared heap every addon pays to
-- collect.
function Utils.PackRows(rows, spec)
    if type(rows) ~= "table" or type(spec) ~= "table" then return "" end
    local specLen = #spec
    local parts, n = {}, 0
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if n > 0 then
                n = n + 1
                parts[n] = SEP_ROW
            end
            for f = 1, specLen do
                if f > 1 then
                    n = n + 1
                    parts[n] = SEP_FIELD
                end
                local field = spec[f]
                n = n + 1
                parts[n] = EncodeField(row[field[1]], field[2], field[3])
            end
        end
    end
    return tconcat(parts, "", 1, n)
end

-- Walks the blob by offset, slicing only the field values. The obvious
-- implementation (split into rows, split each row into fields) copies every row
-- string and every field string and allocates a scratch array per row -- on the
-- ~10k rows we hydrate at login that is megabytes of garbage for data we
-- already have in hand.
function Utils.UnpackRows(blob, spec)
    local rows = {}
    if type(blob) ~= "string" or blob == "" or type(spec) ~= "table" then return rows end
    local specLen = #spec
    local blobLen = #blob
    local pos, rowCount = 1, 0

    while pos <= blobLen + 1 do
        local rowSep = sfind(blob, SEP_ROW, pos, true)
        local rowEnd = (rowSep or (blobLen + 1)) - 1
        local row = {}
        local fieldPos = pos

        for f = 1, specLen do
            if fieldPos > rowEnd + 1 then break end
            local fieldSep = sfind(blob, SEP_FIELD, fieldPos, true)
            local fieldEnd
            if fieldSep and fieldSep <= rowEnd then
                fieldEnd = fieldSep - 1
            else
                fieldEnd = rowEnd
                fieldSep = nil
            end
            local field = spec[f]
            row[field[1]] = DecodeField(ssub(blob, fieldPos, fieldEnd), field[2], field[3])
            fieldPos = fieldSep and (fieldSep + 1) or (rowEnd + 2)
        end

        rowCount = rowCount + 1
        rows[rowCount] = row
        if not rowSep then break end
        pos = rowSep + 1
    end
    return rows
end

function Utils.SecureCall(fn, ...)
    if not fn then return false end
    if securecallfunction then
        securecallfunction(fn, ...)
    else
        local ok, err = xpcall(fn, ErrorHandler, ...)
        if not ok then
            Utils.DebugPrint("SecureCall fallback failed: " .. tostring(err))
            return false
        end
    end
    return true
end

function Utils.RGB(c, alpha)
    if alpha == nil then return c[1], c[2], c[3] end
    return c[1], c[2], c[3], alpha
end

function Utils.SafeOnUpdate(frame, handler)
    if not handler then
        frame:SetScript("OnUpdate", nil)
        return
    end
    frame:SetScript("OnUpdate", function(self, elapsed)
        local ok, err = xpcall(handler, ErrorHandler, self, elapsed)
        if not ok then
            self:SetScript("OnUpdate", nil)
            Utils.DebugPrint("OnUpdate stopped: " .. tostring(err))
        end
    end)
end

function Utils.SafeAfter(delay, fn)
    C_Timer.After(delay, function()
        local ok, err = xpcall(fn, ErrorHandler)
        if not ok then
            Utils.DebugPrint("Timer error: " .. tostring(err))
        end
    end)
end

function Utils.CreateKeyRepeat(frame, initialDelay, fastDelay, accelDuration)
    initialDelay = initialDelay or 0.30
    fastDelay = fastDelay or 0.05
    accelDuration = accelDuration or 1.5
    local repeatKey, repeatAction, repeatNext, repeatHeld
    local repeatActive = false

    local function Start(key, action)
        repeatKey = key
        repeatAction = action
        repeatHeld = 0
        repeatNext = initialDelay
        repeatActive = true
        action()
    end
    local function Stop(key)
        if not key or repeatKey == key then
            repeatActive = false
            repeatKey = nil
            repeatAction = nil
        end
    end
    local function IsKey(key) return repeatKey == key end

    frame:HookScript("OnUpdate", function(_, elapsed)
        if not repeatActive then return end
        -- Stop when the key is released. Arrow-key OnKeyUp is not reliably
        -- delivered to keyboard-enabled frames, so the OnKeyUp handlers
        -- alone let a single tap cascade. Polling the physical key state
        -- here is what Alt+J already does via its own ticker check.
        if repeatKey and not Utils.IsPhysicalKeyDown(repeatKey) then
            Stop(repeatKey)
            return
        end
        repeatHeld = repeatHeld + elapsed
        repeatNext = repeatNext - elapsed
        if repeatNext <= 0 then
            repeatAction()
            local t = repeatHeld / accelDuration
            if t > 1 then t = 1 end
            repeatNext = initialDelay + (fastDelay - initialDelay) * t
        end
    end)

    return { Start = Start, Stop = Stop, IsKey = IsKey }
end

function Utils.NormalizeKey(key)
    return type(key) == "string" and key:upper() or key
end

-- IsKeyDown uses the same names OnKeyDown reports ("UP"/"DOWN"/etc.).
-- An earlier "...ARROW" alias table was wrong: IsKeyDown("DOWNARROW")
-- returns nil, so the guard always read released and arrow repeats never
-- stopped. Verified in-game: IsKeyDown("DOWN") is true while held.
function Utils.IsPhysicalKeyDown(key)
    if not IsKeyDown or not key then return false end
    return IsKeyDown(key) and true or false
end

local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true,
    LCTRL = true, RCTRL = true,
    LALT = true, RALT = true,
}
function Utils.IsModifierKey(key)
    return MODIFIER_KEYS[key] == true
end

local RESERVED_BARE_KEYS = {
    SPACE = true, ENTER = true, RETURN = true,
    W = true, A = true, S = true, D = true,
}
function Utils.IsReservedBareKey(key)
    return RESERVED_BARE_KEYS[key] == true
end

function Utils.ModifierCombo(key)
    local combo = ""
    if IsAltKeyDown and IsAltKeyDown() then combo = combo .. "ALT-" end
    if IsControlKeyDown and IsControlKeyDown() then combo = combo .. "CTRL-" end
    if IsShiftKeyDown and IsShiftKeyDown() then combo = combo .. "SHIFT-" end
    return combo .. (key or "")
end

-- Shared key validation for keybind-capture OnKeyDown handlers. Returns nil
-- (ignore the keypress), "stop" (ESCAPE ends the capture), or the modifier
-- combo string to bind.
function Utils.CaptureKeybindCombo(key)
    if Utils.IsModifierKey(key) then return nil end
    if key == "ESCAPE" then return "stop" end
    -- Bare SPACE / ENTER / WASD silently overwriting jump, accept, or
    -- movement on a stray capture-keypress has bricked spacebar after
    -- /reload before. Only bind these when modified.
    local hasMod = (IsAltKeyDown and IsAltKeyDown())
        or (IsControlKeyDown and IsControlKeyDown())
        or (IsShiftKeyDown and IsShiftKeyDown())
    if not hasMod and Utils.IsReservedBareKey(key) then return nil end
    return Utils.ModifierCombo(key)
end

function Utils.GetVerticalNavIntent(key)
    local navKey = Utils.NormalizeKey(key)
    if navKey == "DOWN" then return 1, false, navKey end
    if navKey == "UP" then return -1, false, navKey end
    if IsAltKeyDown and IsAltKeyDown() then
        if navKey == "J" then return 1, true, navKey end
        if navKey == "K" then return -1, true, navKey end
    end
    return nil, false, navKey
end

function Utils.IsSuppressedAltNavLeak(currentText, suppress)
    if not suppress then return false end
    local key = suppress.key
    if not key or key == "" then return true end
    local restoreText = suppress.text or ""
    currentText = currentText or ""
    if currentText == restoreText then return true end

    local lowerCurrent = currentText:lower()
    local cursor = suppress.cursor or #restoreText
    if cursor < 0 then cursor = 0 end
    if cursor > #restoreText then cursor = #restoreText end
    if (restoreText:sub(1, cursor) .. key .. restoreText:sub(cursor + 1)):lower() == lowerCurrent then
        return true
    end
    if #currentText ~= #restoreText + #key then return false end
    for pos = 0, #restoreText do
        if (restoreText:sub(1, pos) .. key .. restoreText:sub(pos + 1)):lower() == lowerCurrent then
            return true
        end
    end
    return false
end

function Utils.SuppressNextAltNavChar(box, key, ttl)
    if not box then return end
    local token = (box._easyFindSuppressAltNavToken or 0) + 1
    box._easyFindSuppressAltNavToken = token
    box._easyFindSuppressAltNavChar = {
        key = key and tostring(key):lower(),
        text = box.GetText and (box:GetText() or "") or "",
        cursor = box.GetCursorPosition and (box:GetCursorPosition() or #(box:GetText() or "")) or 0,
    }
    -- TTL is a safety backstop in case the consumer never fires. It needs
    -- to outlive the ticker's initialDelay (0.30s) plus the worst-case
    -- OnTextChanged deferral, otherwise the snapshot can expire exactly
    -- when an OS auto-repeated character lands. 1.0s is conservative
    -- without being so long that stale snapshots interfere with normal
    -- typing.
    Utils.SafeAfter(ttl or 1.0, function()
        if box._easyFindSuppressAltNavToken == token then
            box._easyFindSuppressAltNavChar = nil
        end
    end)
end

function Utils.ConsumeSuppressedAltNavChar(box)
    if not box then return false end
    local suppress = box._easyFindSuppressAltNavChar
    if not suppress then return false end
    box._easyFindSuppressAltNavChar = nil
    local currentText = box.GetText and (box:GetText() or "") or ""
    if not Utils.IsSuppressedAltNavLeak(currentText, suppress) then return false end

    local restoreText = suppress.text or ""
    if box.SetText then box:SetText(restoreText) end
    if box.SetCursorPosition then box:SetCursorPosition(suppress.cursor or #restoreText) end
    if box.HighlightText then box:HighlightText(0, 0) end
    -- Re-arm the snapshot so OS-level key auto-repeat (which keeps firing
    -- char-insert events at ~20Hz while the user holds Alt+J/K) keeps
    -- getting caught. Without this, only the first leaked character is
    -- restored; subsequent auto-repeats leak through until the next ticker
    -- tick re-arms (~300ms away).
    Utils.SuppressNextAltNavChar(box, suppress.key)
    return true, restoreText
end

function Utils.AttachAltNavCharSuppressor(editBox, onRestored)
    if not editBox or editBox._easyFindAltNavSuppressHooked then return end
    editBox._easyFindAltNavSuppressHooked = true
    editBox:HookScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local restored, restoreText = Utils.ConsumeSuppressedAltNavChar(self)
        if restored and onRestored then onRestored(self, restoreText) end
    end)
end

function Utils.AfterAltNavReleased(key, callback)
    local navKey = Utils.NormalizeKey(key)
    if (IsAltKeyDown and IsAltKeyDown())
       or (navKey and Utils.IsPhysicalKeyDown(navKey)) then
        Utils.SafeAfter(0.03, function()
            Utils.AfterAltNavReleased(navKey, callback)
        end)
        return false
    end
    if callback then callback() end
    return true
end

function Utils.ScheduleAfterAltNavRelease(key, callback, delay)
    Utils.SafeAfter(delay or 0.05, function()
        Utils.AfterAltNavReleased(key, callback)
    end)
end

function Utils.StartKeyRepeatOnce(repeater, key, step)
    key = Utils.NormalizeKey(key)
    if not (repeater and repeater.Start) then
        return not step or step() ~= false
    end
    if repeater.IsKey and repeater.IsKey(key) then return true end
    repeater.Start(key, function()
        if step and step() == false then
            if repeater.Stop then repeater.Stop(key) end
        end
    end)
    return true
end

function Utils.StartAltNavRepeat(repeater, key, editBox, step, onReleased)
    key = Utils.NormalizeKey(key)
    Utils.SuppressNextAltNavChar(editBox, key)
    local function RunStep()
        local moved = not step or step() ~= false
        -- History navigation can change the editbox text during the keydown.
        -- Refresh the snapshot so a late leaked J/K restores the new text,
        -- not the text that existed before the history step.
        Utils.SuppressNextAltNavChar(editBox, key)
        return moved
    end
    if not (repeater and repeater.Start) then
        local moved = RunStep()
        if not moved and onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
        return moved
    end
    if repeater.IsKey and repeater.IsKey(key) then return true end
    repeater.Start(key, function()
        local altHeld = IsAltKeyDown and IsAltKeyDown()
        local keyHeld = Utils.IsPhysicalKeyDown(key)
        if not altHeld or not keyHeld then
            if repeater.Stop then repeater.Stop(key) end
            if onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
            return
        end
        if not RunStep() then
            if repeater.Stop then repeater.Stop(key) end
            if onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
        end
    end)
    return true
end

-- IME composition support: while a system IME composes (Chinese pinyin and
-- friends), the IME owns the editbox -- ANY programmatic write corrupts the
-- composition. SetText mid-composition leaves pinyin behind on commit, and
-- even HighlightText(0, 0) is destructive: the IME marks its composition
-- region WITH the selection, so clearing it makes the next update insert
-- instead of replace (the accumulated-pinyin garbage). While the composing
-- flag is set every autocomplete write is held. A composition does NOT end
-- by going quiet -- the user can sit in the candidate window indefinitely --
-- it ends only on commit (OnChar delivers the committed characters) or
-- cancel (a composition event with empty text). One frame after either,
-- typed text resyncs from the box and candidates evaluate again. Committed
-- CJK completes like any other prefix (offset math is byte-based and
-- committed boundaries are character boundaries), so the feature stays on
-- for every locale.

local function AutocompleteHas(state)
    return state.currentCandidate ~= nil and (state.editBox:GetText() or "") ~= state.typedText
end

local function AutocompleteNormalize(state, candidate)
    if not candidate or candidate == "" or state.typedText == "" then return nil end
    candidate = slower(candidate)
    local typedLen = #state.typedText
    if typedLen >= #candidate then return nil end
    if slower(ssub(candidate, 1, typedLen)) ~= slower(state.typedText) then
        return nil
    end
    return candidate
end

local function AutocompleteStrip(state)
    if state.imeComposing then
        -- No writes while the IME owns the box; state-only reset.
        state.currentCandidate = nil
        state.smoothExtendDone = false
        return false
    end
    local editBox = state.editBox
    local hadAutocomplete = AutocompleteHas(state)
    if hadAutocomplete then
        state.programmatic = true
        editBox:SetText(state.typedText)
        editBox:SetCursorPosition(#state.typedText)
        editBox:HighlightText(0, 0)
        state.programmatic = false
    else
        editBox:HighlightText(0, 0)
    end
    state.currentCandidate = nil
    state.smoothExtendDone = false
    return hadAutocomplete
end

local function AutocompleteRender(state, candidate)
    candidate = AutocompleteNormalize(state, candidate)
    if not candidate then
        AutocompleteStrip(state)
        return false
    end

    local editBox = state.editBox
    -- WoW defers OnTextChanged by one frame, so the in-flight char
    -- isn't in typedText yet. SetText here would overwrite it and the
    -- deferred OnTextChanged would silently drop the keystroke.
    local liveText = editBox:GetText() or ""
    local liveCursor = editBox:GetCursorPosition() or #liveText
    local hasLiveSuggestion = state.currentCandidate ~= nil
                              and liveText == state.currentCandidate
                              and liveCursor == #state.typedText
    local liveTyped = ssub(liveText, 1, liveCursor)
    if not hasLiveSuggestion and liveTyped ~= state.typedText then
        return false
    end

    local typedLen = #state.typedText
    state.typedText = ssub(candidate, 1, typedLen)
    state.currentCandidate = candidate

    state.programmatic = true
    if editBox:GetText() ~= candidate then
        editBox:SetText(candidate)
    end
    editBox:SetCursorPosition(typedLen)
    editBox:HighlightText(typedLen, #candidate)
    state.programmatic = false
    return true
end

local function AutocompleteApply(state)
    if state.imeComposing or state.candidatesDisabled then return end
    if state.enabled and not state.enabled() then return end
    local editBox = state.editBox
    if state.programmatic or state.typedText == "" or not editBox:HasFocus() then
        AutocompleteStrip(state)
        return
    end
    if state.smoothExtendDone then
        state.smoothExtendDone = false
        return
    end
    AutocompleteRender(state, state.findCandidate(state.typedText))
end

local function AutocompleteRestoreBackspace(state, box)
    if state.restoreBackspaceText and state.restoreBackspaceNotify then
        local restoreText = state.restoreBackspaceText
        local restoreCursor = state.restoreBackspaceCursor or #restoreText
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        state.programmatic = true
        box:SetText(restoreText)
        box:SetCursorPosition(restoreCursor)
        box:HighlightText(0, 0)
        state.programmatic = false
        state.typedText = ssub(restoreText, 1, restoreCursor)
        state.currentCandidate = nil
        state.smoothExtendDone = false
        if state.onBackspaceAutocompleteRestored then
            state.onBackspaceAutocompleteRestored(box, state.typedText)
        end
        return
    end
    state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
    state.restoreBackspaceNotify = false
    state.backspaceStripActive = false
end

local function AutocompleteOnTextChanged(state, box, userInput)
    if state.programmatic then return end
    if state.imeComposing then
        -- Track only: the box may hold transient composition text, and the
        -- IME must not see it move underneath. The change still forwards
        -- so search-on-type keeps running.
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        state.currentCandidate = nil
        state.smoothExtendDone = false
        local liveText = box:GetText() or ""
        local liveCursor = box:GetCursorPosition() or #liveText
        local prevText = state.typedText
        state.typedText = ssub(liveText, 1, liveCursor)
        if state.typedText ~= prevText and state.onTypedChanged then
            state.onTypedChanged(box, state.typedText, prevText, #state.typedText > #prevText)
        end
        return
    end
    local current = box:GetText() or ""
    if state.restoreBackspaceText then
        local restoreText = state.restoreBackspaceText
        local restoreCursor = state.restoreBackspaceCursor or #restoreText
        local notify = state.restoreBackspaceNotify
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        if current ~= restoreText then
            state.programmatic = true
            box:SetText(restoreText)
            box:SetCursorPosition(restoreCursor)
            box:HighlightText(0, 0)
            state.programmatic = false
        end
        state.typedText = ssub(restoreText, 1, restoreCursor)
        state.currentCandidate = nil
        state.smoothExtendDone = false
        if notify and state.onBackspaceAutocompleteRestored then
            state.onBackspaceAutocompleteRestored(box, state.typedText)
        end
        return
    end
    local cursorPos = box:GetCursorPosition() or #current
    if not userInput and cursorPos == 0 and current ~= "" then
        cursorPos = #current
    end
    local typed = ssub(current, 1, cursorPos)
    if state.charDispatchedTyped and typed == state.charDispatchedTyped then
        state.charDispatchedTyped = nil
        return
    end
    if typed == state.typedText then return end
    local prevText = state.typedText
    local prevLen = #state.typedText
    state.typedText = typed
    local grew = #state.typedText > prevLen
    -- Smooth-extend the candidate in-place: safe here because we run
    -- synchronously inside OnTextChanged (post-keystroke), not from
    -- the throttle's OnUpdate, so there's no in-flight char to clobber.
    local extended = false
    if grew and state.currentCandidate
       and #typed < #state.currentCandidate
       and slower(ssub(state.currentCandidate, 1, #typed)) == slower(typed) then
        local typedLen = #typed
        state.programmatic = true
        if box:GetText() ~= state.currentCandidate then
            box:SetText(state.currentCandidate)
        end
        box:SetCursorPosition(typedLen)
        box:HighlightText(typedLen, #state.currentCandidate)
        state.programmatic = false
        extended = true
    end
    if not extended then
        state.currentCandidate = nil
        box:HighlightText(0, 0)
    end
    if state.onTypedChanged then state.onTypedChanged(box, state.typedText, prevText, grew) end
end

local function AutocompleteAccept(state, box, source, cursorPos)
    local candidate = state.currentCandidate
    if not candidate or candidate == "" then return false end
    if cursorPos then
        if cursorPos < 0 then cursorPos = 0 end
        if cursorPos > #candidate then cursorPos = #candidate end
    end
    if not box:HasFocus() then box:SetFocus() end
    state.programmatic = true
    box:SetText(candidate)
    box:SetCursorPosition(cursorPos or #candidate)
    box:HighlightText(0, 0)
    state.programmatic = false
    state.typedText = candidate
    state.currentCandidate = nil
    state.smoothExtendDone = false
    if state.onAccepted then state.onAccepted(candidate, source) end
    return true
end

-- A press whose release moved farther than this (UI units) is a
-- drag-select, not a click, so the caret's final index must not drive the
-- accept/strip decision below.
local AUTOCOMPLETE_CLICK_SLOP = 4

local function AutocompleteOnMouseDown(state, button)
    if button ~= "LeftButton" then return end
    state.mouseAcceptCandidate = AutocompleteHas(state) and state.currentCandidate or nil
    state.mouseAcceptTypedLen = state.mouseAcceptCandidate and #state.typedText or nil
    if state.mouseAcceptCandidate then
        state.mouseDownX, state.mouseDownY = GetCursorPosition()
    end
end

local function AutocompleteOnMouseUp(state, box, button)
    if button ~= "LeftButton" or not state.mouseAcceptCandidate then return end
    local candidate = state.mouseAcceptCandidate
    local typedLen = state.mouseAcceptTypedLen or #state.typedText
    local downX, downY = state.mouseDownX, state.mouseDownY
    state.mouseAcceptCandidate = nil
    state.mouseAcceptTypedLen = nil
    state.mouseDownX, state.mouseDownY = nil, nil
    -- Drag-select (the mouse moved between down and up): leave the user's
    -- selection intact instead of stripping or accepting the suggestion.
    if downX and downY then
        local upX, upY = GetCursorPosition()
        local scale = (box.GetEffectiveScale and box:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
        if (mabs(upX - downX) + mabs(upY - downY)) / scale > AUTOCOMPLETE_CLICK_SLOP then
            return
        end
    end
    if (box:GetText() or "") ~= candidate then return end
    local cursorPos = box:GetCursorPosition() or #candidate
    if cursorPos < typedLen then
        local prefix = ssub(candidate, 1, typedLen)
        state.programmatic = true
        box:SetText(prefix)
        box:SetCursorPosition(cursorPos)
        box:HighlightText(0, 0)
        state.programmatic = false
        state.typedText = prefix
        state.currentCandidate = nil
        state.smoothExtendDone = false
        return
    end
    state.typedText = candidate
    state.currentCandidate = nil
    state.smoothExtendDone = false
    box:HighlightText(0, 0)
    if state.onAccepted then state.onAccepted(candidate, "click") end
end

local function AutocompleteOnBackspace(state, box)
    local targetText, targetCursor
    if state.backspaceAutocompleteTarget then
        targetText, targetCursor = state.backspaceAutocompleteTarget(box, state.typedText, state.currentCandidate)
    end
    if targetText == nil then
        targetText = state.typedText
        targetCursor = #state.typedText
        state.restoreBackspaceNotify = false
    else
        targetText = tostring(targetText)
        if targetCursor == nil then targetCursor = #targetText end
        state.restoreBackspaceNotify = true
    end
    state.backspaceStripActive = true
    state.restoreBackspaceText = targetText
    state.restoreBackspaceCursor = targetCursor
    AutocompleteStrip(state)
    if Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            AutocompleteRestoreBackspace(state, box)
        end)
    end
    if Utils.SafeCallMethod then
        Utils.SafeCallMethod(box, "SetPropagateKeyboardInput", false)
    end
end

local function AutocompleteOnKeyDown(state, box, key)
    if key == "BACKSPACE" and AutocompleteHas(state) then
        AutocompleteOnBackspace(state, box)
        return
    end
    local source
    if key == "RIGHT" or key == "ARROWRIGHT" then
        source = "right"
    elseif key == "L" and IsControlKeyDown() then
        source = "ctrl-l"
    end
    if source and AutocompleteAccept(state, box, source) and Utils.SafeCallMethod then
        Utils.SafeCallMethod(box, "SetPropagateKeyboardInput", false)
    end
end

function Utils.AttachAutocomplete(editBox, opts)
    if not editBox or not opts or type(opts.findCandidate) ~= "function" then return end

    local state = {
        editBox = editBox,
        findCandidate = opts.findCandidate,
        -- Optional live gate: candidates only render while it returns true
        -- (per-surface user toggles); tracking and accept plumbing stay
        -- armed so re-enabling needs no reattach.
        enabled = opts.enabled,
        onTypedChanged = opts.onTypedChanged,
        onAccepted = opts.onAccepted,
        backspaceAutocompleteTarget = opts.backspaceAutocompleteTarget,
        onBackspaceAutocompleteRestored = opts.onBackspaceAutocompleteRestored,
        typedText = "",
        programmatic = false,
        currentCandidate = nil,
        smoothExtendDone = false,
        restoreBackspaceNotify = false,
        backspaceStripActive = false,
    }

    editBox:HookScript("OnTextChanged", function(self, userInput)
        AutocompleteOnTextChanged(state, self, userInput)
    end)
    editBox:HookScript("OnEditFocusLost", function()
        AutocompleteStrip(state)
    end)
    editBox:HookScript("OnMouseDown", function(_, button)
        AutocompleteOnMouseDown(state, button)
    end)
    editBox:HookScript("OnMouseUp", function(self, button)
        AutocompleteOnMouseUp(state, self, button)
    end)
    editBox:HookScript("OnTabPressed", function(self)
        AutocompleteAccept(state, self, "tab")
    end)
    editBox:HookScript("OnKeyDown", function(self, key)
        AutocompleteOnKeyDown(state, self, key)
    end)

    -- Composition tracking: event-driven, never time-driven. Clients
    -- without the composition script fall back to disabling inline
    -- candidates on IME locales outright (zh composition text is
    -- plain-ASCII pinyin, undetectable by content) -- protected either
    -- way, and the feature stays on wherever the signal exists.
    state.imeComposing = false
    state.imeEndToken = 0
    local function ImeCompositionEnd()
        state.imeEndToken = state.imeEndToken + 1
        local token = state.imeEndToken
        -- One frame late: a multi-character commit delivers each character
        -- through OnChar in a burst, and the box must settle before the
        -- resync; a new composition starting first cancels this via the
        -- token bump in the composition hook.
        Utils.SafeAfter(0, function()
            if state.imeEndToken ~= token then return end
            state.imeComposing = false
            local liveText = editBox:GetText() or ""
            local liveCursor = editBox:GetCursorPosition() or #liveText
            state.typedText = ssub(liveText, 1, liveCursor)
            state.currentCandidate = nil
            if editBox:HasFocus() then
                AutocompleteApply(state)
            end
        end)
    end
    local imeHookOk = pcall(editBox.HookScript, editBox, "OnCharComposition", function(_, compText)
        if compText and compText ~= "" then
            state.imeComposing = true
            state.imeEndToken = state.imeEndToken + 1
        else
            -- Empty composition text = cancelled or resolved.
            ImeCompositionEnd()
        end
    end)
    if imeHookOk then
        editBox:HookScript("OnChar", function()
            -- Commit: the IME resolved the composition into real characters.
            if state.imeComposing then ImeCompositionEnd() end
        end)
    else
        local locale = GetLocale and GetLocale()
        if locale == "zhCN" or locale == "zhTW" then
            state.candidatesDisabled = true
        end
    end

    editBox.UpdateAutocomplete = function()
        return AutocompleteApply(state)
    end
    editBox.StripAutocomplete = function()
        return AutocompleteStrip(state)
    end
    editBox.AcceptAutocomplete = function(self, source, cursorPos)
        return AutocompleteAccept(state, self, source, cursorPos)
    end
    editBox.GetTypedText = function() return state.typedText end
    editBox.HasAutocomplete = function() return AutocompleteHas(state) end
    editBox.IsAutocompleteBackspaceStrip = function() return state.backspaceStripActive end
    editBox.IsAutocompleteProgrammatic = function() return state.programmatic end
end

function Utils.ScrollToButton(scrollFrame, button)
    if not scrollFrame or not button then return end
    local _, _, _, _, btnOffsetY = button:GetPoint(1)
    if not btnOffsetY then return end
    local btnTop = -btnOffsetY
    local btnBot = btnTop + button:GetHeight()
    local visH = scrollFrame:GetHeight()
    local cur = scrollFrame:GetVerticalScroll()
    if btnTop < cur then
        scrollFrame:SetVerticalScroll(btnTop)
    elseif btnBot > cur + visH then
        scrollFrame:SetVerticalScroll(btnBot - visH)
    end
end

ns.GOLD_COLOR = {1.0, 0.82, 0.0}
ns.YELLOW_HIGHLIGHT = {1, 1, 0}
-- Filter flyouts and selector popups size to their widest row, never
-- narrower than this.
ns.FLYOUT_MIN_WIDTH = 110
ns.SEARCH_WINDOW_ALPHA = 0.95
-- Initial hover delay before supplementary tooltips appear.
ns.TOOLTIP_HOVER_DELAY = 0.4

-- Standard delayed hover tooltip. resolve(frame) returns title, body and an
-- optional dim third line; returning nothing shows nothing. Hooks (never
-- sets) OnEnter/OnLeave so it composes with a control's own hover visuals.
function Utils.AttachDelayedTooltip(frame, anchor, resolve)
    frame:HookScript("OnEnter", function(self)
        local token = (self._efTipToken or 0) + 1
        self._efTipToken = token
        Utils.SafeAfter(ns.TOOLTIP_HOVER_DELAY, function()
            if self._efTipToken ~= token or not self:IsMouseOver() then return end
            local title, body, dimLine = resolve(self)
            if not title and not body then return end
            GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
            if title then GameTooltip:SetText(title) end
            if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
            if dimLine then GameTooltip:AddLine(dimLine, 0.7, 0.7, 0.7, true) end
            GameTooltip:Show()
        end)
    end)
    frame:HookScript("OnLeave", function(self)
        self._efTipToken = (self._efTipToken or 0) + 1
        GameTooltip_Hide()
    end)
end
function ns.GetSearchWindowAlpha()
    local db = EasyFind and EasyFind.db
    if db and type(db.searchWindowOpacity) == "number" then
        return db.searchWindowOpacity
    end
    return ns.SEARCH_WINDOW_ALPHA
end
-- The filter dropdown and row context menus reuse the results window's
-- rounded-rect panel object so they match it exactly (fill + border) and track
-- the opacity setting, going fully solid at 100%.
function ns.StyleMenuPanel(frame)
    if not frame.combinedBorder then
        ns.CreateRoundedRectBorder(frame)
        ns.SetRoundedRectBorderShown(frame, true)
    end
    -- Registry (weak keys) so a theme flip can restyle menus that are
    -- OPEN at that moment; their OnShow refill never refires for them.
    ns._menuPanels = ns._menuPanels or setmetatable({}, { __mode = "k" })
    ns._menuPanels[frame] = true
    -- Repainted on every style pass, not just creation, so menus follow
    -- the live theme fill (including gradients) after a theme switch.
    ns.ApplyThemeFill(frame)
    if not frame._efMenuHighlightRefreshHooked then
        frame._efMenuHighlightRefreshHooked = true
        frame:HookScript("OnShow", function(self)
            -- Re-fill on every open: menus are created once and would
            -- otherwise keep the fill of whatever theme was active at
            -- creation time. Steps are pcall-isolated: one failure must
            -- not strand the menu wearing the previous theme.
            pcall(ns.ApplyThemeFill, self)
            pcall(ns.SetRoundedRectBorderBgAlpha, self, ns.GetSearchWindowAlpha())
            if Utils.RefreshMenuRowHighlights then
                pcall(Utils.RefreshMenuRowHighlights, self)
            end
            pcall(ns.RetintMenuSeparators, self)
            pcall(ns.RetintMenuText, self)
            -- Per-panel extras (header tints and similar) ride the same
            -- refill on open as they do on live theme flips, AFTER the
            -- generic text pass so they can override it.
            if self._efOnThemeRestyle then
                pcall(self._efOnThemeRestyle, self)
            end
        end)
    end
    ns.SetRoundedRectBarHeight(frame, ns.SEARCHBAR_HEIGHT)
    ns.SetRoundedRectBorderBgAlpha(frame, ns.GetSearchWindowAlpha())
end

-- ONE owner for menu text color: every FontString inside a menu surface
-- wears the theme's main text color (shadow off), re-derived on every
-- open and live flip by the shared refill. Exceptions opt out with
-- fs._efOwnColor = true (gold context-menu labels, dialog prompts,
-- button labels on dark pills); disabled rows keep their dim subtree.
local function RetintMenuTextWalk(frame, leaf)
    if frame._efRowEnabled == false then return end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString"
               and not region._efOwnColor then
                region:SetShadowColor(0, 0, 0, 0)
                region:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
            end
        end
    end
    for i = 1, select("#", frame:GetChildren()) do
        RetintMenuTextWalk((select(i, frame:GetChildren())), leaf)
    end
end

function ns.RetintMenuText(frame)
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local leaf = theme and theme.leafColor
    if not leaf then return end
    RetintMenuTextWalk(frame, leaf)
end

-- Thin separator lines inside menu panels follow the theme's separator
-- color. Panels register their lines in frame._efThemeSeps; retinted on
-- every refill (open and live theme flip).
function ns.RetintMenuSeparators(frame)
    local seps = frame._efThemeSeps
    if not seps then return end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local sep = theme and theme.separatorColor
    if not sep then return end
    for i = 1, #seps do
        seps[i]:SetColorTexture(sep[1], sep[2], sep[3], sep[4] or 0.35)
    end
end

-- Re-derive every currently-shown menu surface from the live theme.
-- Menus normally restyle in their OnShow refill; a menu that is open
-- while the theme flips never gets that event and stays stale (the
-- recurring "menu lags one theme behind" bug). ApplyUITheme calls this.
function ns.RestyleShownMenuPanels()
    if not ns._menuPanels then return end
    for frame in pairs(ns._menuPanels) do
        if frame:IsShown() then
            pcall(ns.ApplyThemeFill, frame)
            pcall(ns.SetRoundedRectBorderBgAlpha, frame, ns.GetSearchWindowAlpha())
            if Utils.RefreshMenuRowHighlights then
                pcall(Utils.RefreshMenuRowHighlights, frame)
            end
            pcall(ns.RetintMenuSeparators, frame)
            pcall(ns.RetintMenuText, frame)
            if frame._efOnThemeRestyle then
                pcall(frame._efOnThemeRestyle, frame)
            end
        end
    end
end

function ns.ApplyMenuOpacity(frame)
    if not frame then return end
    if frame.combinedBorder then
        ns.ApplyThemeFill(frame)
        ns.SetRoundedRectBorderBgAlpha(frame, ns.GetSearchWindowAlpha())
    elseif frame.SetBackdropColor then
        local r, g, b = unpack(ns.SEARCH_WINDOW_FILL_COLOR)
        frame:SetBackdropColor(r, g, b, ns.GetSearchWindowAlpha())
    end
end
ns.TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

ns.NON_EQUIP_LOCS = {
    INVTYPE_NON_EQUIP = true,
    INVTYPE_NON_EQUIP_IGNORE = true,
    INVTYPE_AMMO = true,
    INVTYPE_QUIVER = true,
}

ns.EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_NECK = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_BODY = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_FINGER = true,
    INVTYPE_TRINKET = true,
    INVTYPE_CLOAK = true,
    INVTYPE_WEAPON = true,
    INVTYPE_SHIELD = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_HOLDABLE = true,
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
    INVTYPE_RELIC = true,
    INVTYPE_TABARD = true,
    INVTYPE_BAG = true,
    INVTYPE_PROFESSION_TOOL = true,
    INVTYPE_PROFESSION_GEAR = true,
}

function Utils.IsRealEquipLoc(slot)
    return type(slot) == "string"
        and ns.EQUIP_LOCS[slot] == true
        and not ns.NON_EQUIP_LOCS[slot]
end

function Utils.GetItemEquipLoc(itemID)
    local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getItemInfoInstant then return nil end
    local info, _, _, equipLoc = getItemInfoInstant(itemID)
    if type(info) == "table" then
        return info.itemEquipLoc or info.equipLoc or info.inventoryType
    end
    return equipLoc
end
ns.EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
ns.LINK_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\link"
ns.SEARCH_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\search-icon"
-- The glyph fills only the inner ~27/32 of search-icon; crop the transparent
-- padding so it fills the icon bounds where sized directly (the search bar
-- compensates with its own icon scale instead).
ns.SEARCH_ICON_COORDS = { 0.094, 0.938, 0.094, 0.938 }
ns.COMMANDS_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\commands-icon"
ns.RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-off"
ns.RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-on"
ns.FILTER_ARROW_TEX = "Interface\\AddOns\\EasyFind\\textures\\filter-arrow"
-- Reputation category icon: the player's own faction crest, cropped from the
-- shared UI glyph sheet (1121272). Defined once so the reputation filter row
-- and the flat category glyph stay in sync. Neutral (unchosen Pandaren) falls
-- back to the Alliance crest.
ns.REP_CATEGORY_ICON_TEX = 1121272
ns.REP_CATEGORY_ICON_COORDS = {
    Horde    = { 0.8479, 0.8744, 0.7144, 0.7415 },
    Alliance = { 0.7154, 0.7402, 0.8141, 0.8400 },
}
function ns.PlayerRepCategoryIconCoords()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return ns.REP_CATEGORY_ICON_COORDS[faction] or ns.REP_CATEGORY_ICON_COORDS.Alliance
end

-- Items category / General catalog icon, defined ONCE so the filter-menu icon
-- (Items category + General catalog sub-row) and the catalog result-row general
-- icon are always the same texture -- they can never drift apart.
-- Cropped from a NON-square source texture, so the crop's true aspect must fold
-- in the texel ratio (TEX_W/TEX_H), not just the normalized crop w/h -- WoW does
-- not report a texture's pixel size, so the dimensions are recorded here from the
-- file's BLP header (read via wago.tools). 6116514 is 512x256; the crop below is
-- ~111x107 px, i.e. nearly square, so it fills the slot undistorted. If you swap
-- the texture/coords, update TEX_W/TEX_H to that file's real dimensions.
ns.ITEMS_CATEGORY_ICON_TEX = 6116514
ns.ITEMS_CATEGORY_ICON_COORDS = { 0.0395, 0.2563, 0.0667, 0.4845 }
do
    local TEX_W, TEX_H = 512, 256
    local c = ns.ITEMS_CATEGORY_ICON_COORDS
    ns.ITEMS_CATEGORY_ICON_ASPECT = ((c[2] - c[1]) * TEX_W) / ((c[4] - c[3]) * TEX_H)
end

-- Bank glyph (the Buy crosshair cursor file, used whole -- not a sheet crop),
-- shared by the filter-menu row and the result-row category icon so the two
-- cannot drift apart.
ns.BANK_CATEGORY_ICON_TEX = 4675621
ns.BANK_CATEGORY_ICON_COORDS = { 0, 1, 0, 1 }

-- Map-search and Statistics category glyphs (12.1 moved both on the shared
-- sheet), shared by the filter-menu rows and the result-row category icons.
ns.MAP_CATEGORY_ICON_TEX = 1121272
ns.MAP_CATEGORY_ICON_COORDS = { 0.7443, 0.7840, 0.2548, 0.2961 }
ns.STAT_CATEGORY_ICON_TEX = 1121272
ns.STAT_CATEGORY_ICON_COORDS = { 0.2680, 0.3043, 0.2666, 0.2943 }

-- The key the per-character stored-item caches are filed under. ONE owner:
-- the provider writes db.bagCache.chars[key] with it and the scope picker
-- compares against it, so any divergence silently matches zero characters.
-- Deliberately not memoized -- a call before the unit exists would pin a
-- placeholder for the session.
function ns.CurrentCharacterKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- A statistic's live value, plus whether anything is recorded. Shared so the
-- row that dims a "--" and the filter that hides one cannot disagree.
function ns.GetStatisticValue(statisticID)
    if not (statisticID and GetStatistic) then return nil, false end
    local ok, value = pcall(GetStatistic, statisticID)
    if not ok then return nil, false end
    return value, (value ~= nil and value ~= "" and value ~= "--")
end

-- Account bank holdings belong to the warband, not to any character. Resolved
-- lazily: these globals exist on a live client but not at file load in tests.
local warbandBankLabel
function ns.WarbandBankLabel()
    if warbandBankLabel then return warbandBankLabel end
    warbandBankLabel = _G["ACCOUNT_BANK_PANEL_TITLE"]
        or _G["BANK_TYPE_ACCOUNT"]
        or ns.L["BANK_WARBAND"]
    return warbandBankLabel
end

-- The player-facing name of a storage location, from its category.
function ns.StoredCategoryLabel(category)
    if category == "Warband" then return ns.WarbandBankLabel() end
    if category == "Bank" then return _G["BANK"] or "Bank" end
    return _G["BAGSLOT"] or _G["BAGS"] or "Bags"
end

-- "Bank: Alt (5), Otheralt" for a stored-item row. Built once per populate,
-- never in the render loop: the result is a pure function of the holder list,
-- which does not change between populates, and the loop runs for every visible
-- row on every keystroke.
function ns.StoredHoldersText(holders, category)
    if not holders or #holders == 0 then return nil end
    local parts = {}
    for i = 1, #holders do
        local holder = holders[i]
        local who = holder.name or "?"
        if (holder.count or 1) > 1 then
            parts[i] = sformat("%s (%d)", who, holder.count)
        else
            parts[i] = who
        end
    end
    return ns.StoredCategoryLabel(category) .. ": " .. tconcat(parts, ", ")
end

-- Size an icon texture to fit within `sz` while preserving `aspect` (width/height):
-- a tall icon (aspect < 1) keeps full height and narrows; a wide one keeps full
-- width and shortens. nil/0 aspect = square (the default for every other icon).
-- Point/LEFT anchoring is preserved -- only width/height change.
function ns.SizeIconAspect(tex, sz, aspect)
    if aspect and aspect > 0 and aspect < 1 then
        tex:SetSize(sz * aspect, sz)
    elseif aspect and aspect > 1 then
        tex:SetSize(sz, sz / aspect)
    else
        tex:SetSize(sz, sz)
    end
end

-- Achievement completion-status labels, single-sourced for the tooltip status
-- line and the achievement filter dropdown. WARNING: _G["ACHIEVEMENT_FILTER_EARNED"]
-- is a NUMERIC filter-mode constant (value 3), not the word "Earned" -- using it
-- as a label printed a raw "3". Only accept a candidate that is a non-empty
-- string; fall through to the next candidate otherwise.
local function StringGlobal(key, fallback)
    local v = _G[key]
    return (type(v) == "string" and v ~= "") and v or fallback
end
ns.ACH_LABEL_EARNED = StringGlobal("EARNED",
    StringGlobal("ACHIEVEMENTFRAME_FILTER_COMPLETED", StringGlobal("COMPLETE", "Earned")))
ns.ACH_LABEL_INCOMPLETE = StringGlobal("INCOMPLETE",
    StringGlobal("ACHIEVEMENTFRAME_FILTER_INCOMPLETE", "Incomplete"))
-- Minimal scrollbar geometry, shared so surfaces that must clear the
-- scrollbar lane (row hover wash) derive from the same numbers.
ns.SCROLLBAR_THUMB_W = 3
ns.SCROLLBAR_EDGE_INSET = 4
ns.SEARCH_WINDOW_FILL_COLOR = {0.052, 0.052, 0.060}
ns.TEXT_PRIMARY = {1.00, 0.97, 0.86}
ns.TEXT_BODY = {0.78, 0.78, 0.80}
ns.TEXT_DIM = {0.55, 0.55, 0.58}
-- Cool blue-gray fills so interactive buttons read as such against the
-- neutral near-black panels (color as affordance, not brightness).
ns.BTN_FILL_NORMAL = {0.160, 0.190, 0.250}
ns.BTN_FILL_HOVER = {0.220, 0.270, 0.340}
ns.BTN_FILL_PRESSED = {0.120, 0.140, 0.190}
ns.SECTION_TABLE_FILL = {0.075, 0.075, 0.085, 0.92}
ns.BTN_FILL_DISABLED = {0.080, 0.090, 0.110}
-- Live control-accent and sidebar-nav fills, mutated in place by
-- ApplyUITheme like the BTN fills above (paint-time reads follow themes).
ns.CONTROL_ACCENT = {0.17, 0.48, 0.72}
ns.NAV_SELECTED_FILL = {0.16, 0.19, 0.25, 0.95}
ns.NAV_HOVER_FILL = {0.12, 0.14, 0.19, 0.85}
ns.PANEL_CARD_FILL = {0.05, 0.05, 0.06}
ns.EDITBOX_INSET_FILL = {0.02, 0.02, 0.03}
-- Hover wash color for rows and menu rows on every theme except Black
-- (which keeps the classic additive gold glow): the window fill nudged
-- toward the main text color, which darkens light fills and lightens
-- dark ones. Returns nil when the glow should be used instead.
-- One color rule for chrome-tinted glyphs (the calculator icon in results
-- rows, the apps menu, and the popup; the apps 3x3 dots follow the same
-- source): the theme's chrome-glyph color, gold when the theme has none.
function ns.ChromeGlyphColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    return (theme and theme.chromeGlyph) or ns.GOLD_COLOR or { 1.0, 0.82, 0.0 }
end

function ns.RowWashColor()
    local pal = ns.ACTIVE_UI_PALETTE
    if not pal or (ns.UI_THEME_PALETTES and pal == ns.UI_THEME_PALETTES.Black) then return nil end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local leaf = theme and theme.leafColor
    if not leaf then return nil end
    local windowFill = ns.SEARCH_WINDOW_FILL_COLOR
    local f = 0.24
    return windowFill[1] + (leaf[1] - windowFill[1]) * f,
        windowFill[2] + (leaf[2] - windowFill[2]) * f,
        windowFill[3] + (leaf[3] - windowFill[3]) * f
end

-- Row washes sit a step below the window itself so the hover/selection
-- highlight never reads as fully solid: even at 100% window opacity the
-- wash paints at this fraction of it, then scales down with the setting.
ns.ROW_WASH_ALPHA_SCALE = 0.80
function ns.RowWashAlpha()
    return ns.GetSearchWindowAlpha() * ns.ROW_WASH_ALPHA_SCALE
end

-- Identity map for paint-time tagging: painters that fill a control from
-- one of the live tables record WHICH table, so the theme retint walker
-- repaints from the same table instead of guessing by color (color
-- snapshots break when a control is first seen under a non-default theme).
ns.LIVE_FILL_NAMES = {
    [ns.BTN_FILL_NORMAL] = "BTN_FILL_NORMAL",
    [ns.BTN_FILL_HOVER] = "BTN_FILL_HOVER",
    [ns.BTN_FILL_PRESSED] = "BTN_FILL_PRESSED",
    [ns.BTN_FILL_DISABLED] = "BTN_FILL_DISABLED",
    [ns.SECTION_TABLE_FILL] = "SECTION_TABLE_FILL",
    [ns.CONTROL_ACCENT] = "CONTROL_ACCENT",
    [ns.NAV_SELECTED_FILL] = "NAV_SELECTED_FILL",
    [ns.NAV_HOVER_FILL] = "NAV_HOVER_FILL",
    [ns.PANEL_CARD_FILL] = "PANEL_CARD_FILL",
    [ns.EDITBOX_INSET_FILL] = "EDITBOX_INSET_FILL",
    [ns.SEARCH_WINDOW_FILL_COLOR] = "SEARCH_WINDOW_FILL_COLOR",
}
ns.LINK_COLOR = {0.44, 0.84, 1.0}
ns.LINK_HOVER = {0.72, 0.94, 1.0}
ns.LINK_GLOW_COLOR = {0.3, 0.85, 1.0, 0.7}
ns.SEARCHBAR_HEIGHT = 30
ns.RESULT_ROWS_MIN = 1
ns.RESULT_ROWS_MAX = 8
ns.SEARCHBAR_FILL = 0.55
ns.SEARCHBAR_ICON_SCALE = 0.9
ns.DEFAULT_FONT_SIZE = 0.9
ns.CLEAR_BTN_SIZE = 12
-- Blizzard's standard round-crop mask, used wherever a square icon has to
-- render as a circle (fade masks, the gear-set spec badge).
ns.PORTRAIT_ALPHA_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local EasyFindSearchFont = CreateFont("EasyFindSearchFont")
local baseFont = Game15Font_Shadow or GameFontNormal
EasyFindSearchFont:CopyFontObject(baseFont)
EasyFindSearchFont:SetFont((baseFont:GetFont()), 12, select(3, baseFont:GetFont()))
ns.SEARCHBAR_FONT = "EasyFindSearchFont"

local SEARCH_TEX_FILL = "Interface\\AddOns\\EasyFind\\textures\\SearchBarFill"
local SEARCH_TEX_BORDER = "Interface\\AddOns\\EasyFind\\textures\\SearchBarBorder"
local CLEAR_BTN_TEX = "Interface\\AddOns\\EasyFind\\textures\\clear-button"
-- 9-slice cap = outer 37.5% of texture: curve lives in outer 64 px,
-- followed by 32 px flat that buffers the cap/mid join. Cutting in the
-- flat region lets cap and mid (rendered at different scales) join
-- without a visible kink at the curve's tangent point.
local CAP_TEX_RATIO = 0.375
local CAP_DISPLAY_RATIO = 0.75
local TC_LEFT  = {0, CAP_TEX_RATIO, 0, 1}
local TC_MID   = {CAP_TEX_RATIO, 1 - CAP_TEX_RATIO, 0, 1}
local TC_RIGHT = {1 - CAP_TEX_RATIO, 1, 0, 1}
local BORDER_R, BORDER_G, BORDER_B = 0.42, 0.42, 0.42

local function CreateTexPart(frame, layer, texPath, tc, vertR, vertG, vertB, vertA)
    local tex = frame:CreateTexture(nil, layer)
    tex:SetTexture(texPath)
    tex:SetTexCoord(unpack(tc))
    tex:SetVertexColor(vertR, vertG, vertB, vertA)
    return tex
end

local function ApplyCapWidths(frame)
    if not frame.searchBorder then return end
    local h = frame:GetHeight() or 0
    if h <= 0 then return end
    local capW = h * CAP_DISPLAY_RATIO
    local sb = frame.searchBorder
    sb.fillLeft:SetWidth(capW)
    sb.fillRight:SetWidth(capW)
end

function ns.CreateSearchBorder(frame)
    local fillLeft = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_LEFT, 0, 0, 0, 1)
    fillLeft:SetPoint("TOPLEFT")
    fillLeft:SetPoint("BOTTOMLEFT")

    local fillRight = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_RIGHT, 0, 0, 0, 1)
    fillRight:SetPoint("TOPRIGHT")
    fillRight:SetPoint("BOTTOMRIGHT")

    local fillMid = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_MID, 0, 0, 0, 1)
    fillMid:SetPoint("TOPLEFT", fillLeft, "TOPRIGHT")
    fillMid:SetPoint("BOTTOMRIGHT", fillRight, "BOTTOMLEFT")

    local borderLeft = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_LEFT, BORDER_R, BORDER_G, BORDER_B, 1)
    borderLeft:SetAllPoints(fillLeft)

    local borderRight = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_RIGHT, BORDER_R, BORDER_G, BORDER_B, 1)
    borderRight:SetAllPoints(fillRight)

    local borderMid = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_MID, BORDER_R, BORDER_G, BORDER_B, 1)
    borderMid:SetAllPoints(fillMid)

    frame.searchBorder = {
        fillLeft = fillLeft, fillMid = fillMid, fillRight = fillRight,
        borderLeft = borderLeft, borderMid = borderMid, borderRight = borderRight,
    }
    frame:HookScript("OnSizeChanged", ApplyCapWidths)
    ApplyCapWidths(frame)
end

-- 9-slice rounded-rect: corners stay fixed size (= bar height / 2 so they
-- match the bar's pill caps); edges stretch. When container height equals
-- 2 * cornerSize, the silhouette collapses to a horizontal pill.
local COMBINED_TEX_FILL   = "Interface\\AddOns\\EasyFind\\textures\\CombinedFill"
local COMBINED_TEX_BORDER = "Interface\\AddOns\\EasyFind\\textures\\CombinedBorder"
local CR = 0.25

local TC9 = {
    tl = {0,        CR,     0,        CR    },
    tm = {CR,       1 - CR, 0,        CR    },
    tr = {1 - CR,   1,      0,        CR    },
    ml = {0,        CR,     CR,       1 - CR},
    mm = {CR,       1 - CR, CR,       1 - CR},
    mr = {1 - CR,   1,      CR,       1 - CR},
    bl = {0,        CR,     1 - CR,   1     },
    bm = {CR,       1 - CR, 1 - CR,   1     },
    br = {1 - CR,   1,      1 - CR,   1     },
}

local function CreateNineSlice(frame, layer, texPath, vertR, vertG, vertB, vertA)
    local nine = {}
    local function P(name)
        local t = frame:CreateTexture(nil, layer)
        t:SetTexture(texPath)
        t:SetTexCoord(unpack(TC9[name]))
        t:SetVertexColor(vertR, vertG, vertB, vertA)
        return t
    end
    nine.tl, nine.tm, nine.tr = P("tl"), P("tm"), P("tr")
    nine.ml, nine.mm, nine.mr = P("ml"), P("mm"), P("mr")
    nine.bl, nine.bm, nine.br = P("bl"), P("bm"), P("br")
    return nine
end

local function AnchorNineSlice(frame, n, cornerSize)
    n.tl:ClearAllPoints(); n.tl:SetPoint("TOPLEFT");     n.tl:SetSize(cornerSize, cornerSize)
    n.tr:ClearAllPoints(); n.tr:SetPoint("TOPRIGHT");    n.tr:SetSize(cornerSize, cornerSize)
    n.bl:ClearAllPoints(); n.bl:SetPoint("BOTTOMLEFT");  n.bl:SetSize(cornerSize, cornerSize)
    n.br:ClearAllPoints(); n.br:SetPoint("BOTTOMRIGHT"); n.br:SetSize(cornerSize, cornerSize)
    n.tm:ClearAllPoints()
    n.tm:SetPoint("TOPLEFT",  n.tl, "TOPRIGHT")
    n.tm:SetPoint("BOTTOMRIGHT", n.tr, "BOTTOMLEFT")
    n.bm:ClearAllPoints()
    n.bm:SetPoint("TOPLEFT",  n.bl, "TOPRIGHT")
    n.bm:SetPoint("BOTTOMRIGHT", n.br, "BOTTOMLEFT")
    n.ml:ClearAllPoints()
    n.ml:SetPoint("TOPLEFT",  n.tl, "BOTTOMLEFT")
    n.ml:SetPoint("BOTTOMRIGHT", n.bl, "TOPRIGHT")
    n.mr:ClearAllPoints()
    n.mr:SetPoint("TOPLEFT",  n.tr, "BOTTOMLEFT")
    n.mr:SetPoint("BOTTOMRIGHT", n.br, "TOPRIGHT")
    n.mm:ClearAllPoints()
    n.mm:SetPoint("TOPLEFT",  n.tl, "BOTTOMRIGHT")
    n.mm:SetPoint("BOTTOMRIGHT", n.br, "TOPLEFT")
end

local function ApplyContainerCornerSize(frame)
    if not frame.combinedBorder then return end
    local h = frame.cbBarHeight or frame:GetHeight() or 0
    if h <= 0 then return end
    local cornerSize = h / 2
    AnchorNineSlice(frame, frame.combinedBorder.fill,   cornerSize)
    AnchorNineSlice(frame, frame.combinedBorder.border, cornerSize)
    if frame._efArtCells then
        AnchorNineSlice(frame, frame._efArtCells, cornerSize)
        if frame._efArtMasks then
            local d = cornerSize * 2
            for _, mask in pairs(frame._efArtMasks) do
                mask:SetSize(d, d)
            end
        end
        ns.UpdateThemeArtCrop(frame)
    end
    if ns.UpdateThemeFillGradient then
        ns.UpdateThemeFillGradient(frame)
    end
end

function ns.CreateRoundedRectBorder(frame)
    local fill   = CreateNineSlice(frame, "BACKGROUND", COMBINED_TEX_FILL,   0, 0, 0, 1)
    local border = CreateNineSlice(frame, "ARTWORK",    COMBINED_TEX_BORDER, BORDER_R, BORDER_G, BORDER_B, 1)
    frame.combinedBorder = { fill = fill, border = border }
    ApplyContainerCornerSize(frame)
    frame:HookScript("OnSizeChanged", ApplyContainerCornerSize)
end

-- Corner radius tracks BAR height, not container height (which grows
-- when results open). Callers must pin it via this setter on creation
-- and again whenever fontSize / theme changes the bar's pixel height.
function ns.SetRoundedRectBarHeight(frame, h)
    frame.cbBarHeight = h
    ApplyContainerCornerSize(frame)
end

function ns.SetRoundedRectBorderShown(frame, shown)
    if not frame.combinedBorder then return end
    for _, t in pairs(frame.combinedBorder.fill)   do t:SetShown(shown) end
    for _, t in pairs(frame.combinedBorder.border) do t:SetShown(shown) end
end

-- Border RING only. SetRoundedRectBorderShown toggles fill AND ring, which
-- is panel on/off -- using it for "borderless" removed the background too.
function ns.SetRoundedRectRingShown(frame, shown)
    if not (frame.combinedBorder and frame.combinedBorder.border) then return end
    for _, t in pairs(frame.combinedBorder.border) do t:SetShown(shown) end
end

function ns.SetRoundedRectBorderBgAlpha(frame, alpha)
    if not frame.combinedBorder then return end
    frame._efBgAlpha = alpha
    for _, t in pairs(frame.combinedBorder.fill) do t:SetAlpha(alpha) end
    if frame._efArtCells then
        for _, t in pairs(frame._efArtCells) do t:SetAlpha(alpha) end
    end
    -- Gradient fills carry their alpha inside the gradient colors
    -- (texture-level SetAlpha does not reach SetGradient vertex colors),
    -- so a gradient surface must re-derive its ramp with the new alpha.
    if frame._efThemeFillTarget and ns.UpdateThemeFillGradient then
        ns.UpdateThemeFillGradient(frame)
    end
end

function ns.SetRoundedRectBorderFillColor(frame, r, g, b, a)
    if not frame.combinedBorder then return end
    for _, t in pairs(frame.combinedBorder.fill) do
        t:SetVertexColor(r, g, b, a or 1)
    end
end

-- Search bar visibility mode, ONE owner for the autoHide/smartShow pair.
-- Exactly one of the pair is true for the two legacy modes; both false is
-- Always Show (the legacy pre-mode encoding, so no migration is needed
-- and old consumers already fall through to a plain persistent Show).
-- Consumers must never write the pair directly.
ns.VISIBILITY_AUTO   = 0
ns.VISIBILITY_SMART  = 1
ns.VISIBILITY_ALWAYS = 2

function ns.GetVisibilityMode()
    local db = EasyFind and EasyFind.db
    if not db or db.autoHide then return ns.VISIBILITY_AUTO end
    if db.smartShow then return ns.VISIBILITY_SMART end
    return ns.VISIBILITY_ALWAYS
end

function ns.SetVisibilityMode(mode)
    local db = EasyFind and EasyFind.db
    if not db then return end
    db.autoHide  = mode == ns.VISIBILITY_AUTO
    db.smartShow = mode == ns.VISIBILITY_SMART
end

local function DisablePixelSnap(t)
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

-- Paint fill color AND alpha, plus optionally disable pixel snapping so
-- the texture renders at sub-pixel positions cleanly (used by buttons
-- and cards that get color-animated, where snap can cause shimmering).
function ns.SetRoundedRectFill(frame, r, g, b, a, snapOff)
    if not (frame and frame.combinedBorder and frame.combinedBorder.fill) then return end
    a = a or 1
    for _, t in pairs(frame.combinedBorder.fill) do
        t:SetVertexColor(r, g, b, a)
        t:SetAlpha(a)
        if snapOff then DisablePixelSnap(t) end
    end
end

-- Panel text retint for light themes: fontstrings sitting DIRECTLY on
-- a wizard-glossed panel (titles, labels, hints) go dark; fontstrings
-- inside rounded-fill controls (button pills, table cards) keep their
-- authored light colors, since those fills stay dark on light themes.
-- Originals are snapshotted on first touch and restored on dark themes.
local function HasRoundedAncestor(region)
    local parent = region:GetParent()
    for _ = 1, 5 do
        if not parent then return false end
        if parent.combinedBorder then return true end
        parent = parent:GetParent()
    end
    return false
end

local function RetintFontString(fs, theme, shadowOnly)
    if not fs._efOrigTextColor then
        local r, g, b, a = fs:GetTextColor()
        fs._efOrigTextColor = { r, g, b, a }
        local sr, sg, sb, sa = fs:GetShadowColor()
        fs._efOrigShadow = { sr, sg, sb, sa }
    end
    -- Text inside rounded controls keeps its owned colors (the control
    -- painters manage them), but the font-object drop shadow still smears
    -- on light fills, so shadow treatment applies everywhere.
    -- _efOwnColor text likewise has a dedicated painter (row RefreshVisual,
    -- ApplyRowLabelColor): classification here would freeze whatever theme
    -- was active when the color snapshot was taken.
    if shadowOnly or fs._efOwnColor then
        if theme.lightTheme then
            fs:SetShadowColor(0, 0, 0, 0)
        else
            local sh = fs._efOrigShadow
            fs:SetShadowColor(sh[1], sh[2], sh[3], sh[4])
        end
        return
    end
    local orig = fs._efOrigTextColor
    -- Tagged link text follows the live link table on BOTH polarities;
    -- its build-time color is whatever theme was active then, so neither
    -- restore-to-original nor color classification can handle it.
    if fs._efLinkText then
        if theme.lightTheme then
            fs:SetShadowColor(0, 0, 0, 0)
        else
            local sh = fs._efOrigShadow
            fs:SetShadowColor(sh[1], sh[2], sh[3], sh[4])
        end
        local link = ns.LINK_COLOR
        fs:SetTextColor(link[1], link[2], link[3], orig[4])
        return
    end
    if not theme.lightTheme then
        local sh = fs._efOrigShadow
        fs:SetShadowColor(sh[1], sh[2], sh[3], sh[4])
        fs:SetTextColor(orig[1], orig[2], orig[3], orig[4])
        return
    end
    -- Dark shadows under dark text read as a smeared backdrop.
    fs:SetShadowColor(0, 0, 0, 0)
    local r, g, b = orig[1], orig[2], orig[3]
    local lum = 0.3 * r + 0.5 * g + 0.2 * b
    if r >= 0.85 and b <= 0.45 then
        -- gold headings
        local c = theme.pathColorHover
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    elseif lum >= 0.7 then
        local c = theme.leafColor
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    elseif lum >= 0.35 then
        local c = theme.textFaint
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    else
        fs:SetTextColor(r, g, b, orig[4])
    end
end

-- Control fills painted once at creation (button pills, table cards,
-- search shells). The live ns.BTN_FILL_* / ns.SECTION_TABLE_FILL tables
-- are mutated per theme, which keeps every hover closure in sync, but
-- resting fills need this repaint. Frames whose snapshot matches one of
-- the canonical control colors follow that table; everything else
-- (gloss panels, custom fills) is left alone.
local CONTROL_FILL_CANON = {
    { canon = {0.160, 0.190, 0.250}, live = "BTN_FILL_NORMAL" },
    { canon = {0.120, 0.140, 0.190}, live = "BTN_FILL_PRESSED" },
    { canon = {0.075, 0.075, 0.085}, live = "SECTION_TABLE_FILL" },
}

local function RetintControlFill(frame)
    -- State-driven fills (sidebar nav pills) opt out: their resting colors
    -- collide with the canonical button fills, so classification would
    -- stamp button colors onto whatever state they held at first walk.
    if frame._efNoAutoRetint then return end
    if not (frame.combinedBorder and frame.combinedBorder.fill and frame.combinedBorder.fill.mm) then return end
    if frame._efControlFillKind == nil then
        local r, g, b = frame.combinedBorder.fill.mm:GetVertexColor()
        frame._efControlFillKind = false
        for i = 1, #CONTROL_FILL_CANON do
            local c = CONTROL_FILL_CANON[i].canon
            if math.abs(r - c[1]) < 0.03 and math.abs(g - c[2]) < 0.03 and math.abs(b - c[3]) < 0.03 then
                frame._efControlFillKind = CONTROL_FILL_CANON[i].live
                break
            end
        end
    end
    local kind = frame._efControlFillKind
    if not kind then return end
    local live = ns[kind]
    ns.SetRoundedRectFill(frame, live[1], live[2], live[3],
        frame._efControlFillAlpha or live[4] or 1, true)
end

-- Every per-frame step is pcall-isolated: one frame throwing must never
-- abort the sweep and leave everything after it in the walk order stale
-- (which shows up as an arbitrary-looking subset of controls not
-- retheming).
local function RetintWalk(frame, theme)
    pcall(RetintControlFill, frame)
    -- Controls that own a state painter repaint themselves from the live
    -- tables; classification heuristics can't know their current state.
    if frame.RefreshVisual then
        pcall(frame.RefreshVisual, frame)
    end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                pcall(RetintFontString, region, theme, HasRoundedAncestor(region))
            end
        end
    end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            RetintWalk((select(i, frame:GetChildren())), theme)
        end
    end
end

function ns.RetintPanelText(root)
    if not root then return end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if not theme then return end
    RetintWalk(root, theme)
end

-- Theme art overlay: the window is a VIEWPORT onto a big square image.
-- Nine art cells share the fill nine-slice geometry, but their texcoords
-- are computed from each cell's real pixel rect, so the image is cropped
-- to the frame (1:1, never stretched): the bar alone shows the top slice
-- and opening results reveals more of the same picture. Only the four
-- corner cells carry a mask (one each, under the per-texture mask cap)
-- to round the silhouette; edge and center cells are plain crops.
local ART_TEXTURE_SIZE = 1024

function ns.UpdateThemeArtCrop(frame)
    local cells = frame._efArtCells
    if not cells then return end
    local w = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0
    local barH = frame.cbBarHeight or fh
    if w <= 0 or fh <= 0 then return end
    local c = barH / 2
    local S = 1 / ART_TEXTURE_SIZE
    local x1, x2 = c * S, (w - c) * S
    local y1, y2 = c * S, (fh - c) * S
    local xe, ye = w * S, fh * S
    if xe > 1 then xe = 1 end
    if ye > 1 then ye = 1 end
    if x1 > xe then x1 = xe end
    if x2 > xe then x2 = xe end
    if y1 > ye then y1 = ye end
    if y2 > ye then y2 = ye end
    cells.tl:SetTexCoord(0, x1, 0, y1)
    cells.tm:SetTexCoord(x1, x2, 0, y1)
    cells.tr:SetTexCoord(x2, xe, 0, y1)
    cells.ml:SetTexCoord(0, x1, y1, y2)
    cells.mm:SetTexCoord(x1, x2, y1, y2)
    cells.mr:SetTexCoord(x2, xe, y1, y2)
    cells.bl:SetTexCoord(0, x1, y2, ye)
    cells.bm:SetTexCoord(x1, x2, y2, ye)
    cells.br:SetTexCoord(x2, xe, y2, ye)
end

-- Corner rounding for the art cells: masks cannot subset their texture
-- via texcoords, so each corner cell gets a QUADRANT of a full circle
-- mask (the proven FilterButtonCircle disc) sized 2x the corner cell and
-- anchored so the right quarter covers the cell. The quarter radius then
-- equals the corner size exactly, matching the fill's silhouette.
local ART_MASK_ANCHORS = {
    tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT",
}
local ART_CORNER_MASK_TEX = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"

local function EnsureThemeArtOverlay(frame)
    if frame._efArtCells then return frame._efArtCells end
    local cells = {}
    local masks = {}
    for name in pairs(TC9) do
        local cell = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
        local anchor = ART_MASK_ANCHORS[name]
        if anchor then
            local mask = frame:CreateMaskTexture()
            mask:SetTexture(ART_CORNER_MASK_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetPoint(anchor, cell, anchor)
            cell:AddMaskTexture(mask)
            masks[name] = mask
        end
        cells[name] = cell
    end
    frame._efArtCells = cells
    frame._efArtMasks = masks
    ApplyContainerCornerSize(frame)
    return cells
end

-- Position-aware theme gradient: each nine-slice cell gets the segment
-- of the bottom->top ramp matching its own y-range in the frame, so a
-- bar-only pill (all corner rows) still shows a smooth ramp instead of
-- two flat halves with a seam. Re-run on size changes (corner-size pass)
-- because the ranges move. Applies to the art cells when a grain/art
-- texture is showing (the ramp rides the texture as vertex gradient),
-- else to the plain fill cells.
local function ThemeRampColor(bottom, top, yFromTop, height)
    local t = 1 - (yFromTop / height)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return bottom[1] + (top[1] - bottom[1]) * t,
           bottom[2] + (top[2] - bottom[2]) * t,
           bottom[3] + (top[3] - bottom[3]) * t
end

function ns.UpdateThemeFillGradient(frame)
    if not (frame and frame.combinedBorder) then return end
    -- Only frames that ApplyThemeFill manages (search window, menus) wear
    -- the window gradient. This runs from ApplyContainerCornerSize, which
    -- fires for EVERY rounded frame on any bar-height recalculation; on a
    -- gradient palette an unguarded run whitewashes ordinary controls
    -- (buttons, toggle tracks) with the window ramp: the long-standing
    -- "wrong color until hovered" bug on gradient themes.
    if not frame._efThemeFillTarget then return end
    local palette = ns.ACTIVE_UI_PALETTE
    local bottom = palette and palette.windowFillBottom
    local top = palette and palette.windowFillTop
    if not (bottom and top and CreateColor) then return end
    local h = frame:GetHeight() or 0
    if h <= 0 then return end
    local corner = (frame.cbBarHeight or h) / 2
    if corner > h / 2 then corner = h / 2 end
    -- Art themes render as authored (white vertex): only palettes that
    -- opt in via tintArt (the near-white grain textures) take the ramp
    -- as a vertex tint. Tinting real art by default crushed it to the
    -- fallback-gradient colors (looked like the theme got reverted).
    local artShown = frame._efArtCells and frame._efArtCells.mm:IsShown()
    local cells
    if artShown then
        if not (palette and palette.tintArt) then return end
        cells = frame._efArtCells
    else
        cells = frame.combinedBorder.fill
    end
    local cellAlpha = frame._efBgAlpha or 1
    local function rampCell(cell, y0, y1)
        if not cell then return end
        local r1, g1, b1 = ThemeRampColor(bottom, top, y0, h)
        local r2, g2, b2 = ThemeRampColor(bottom, top, y1, h)
        cell:SetVertexColor(1, 1, 1, 1)
        cell:SetGradient("VERTICAL", CreateColor(r2, g2, b2, cellAlpha), CreateColor(r1, g1, b1, cellAlpha))
    end
    rampCell(cells.tl, 0, corner)
    rampCell(cells.tm, 0, corner)
    rampCell(cells.tr, 0, corner)
    rampCell(cells.ml, corner, h - corner)
    rampCell(cells.mm, corner, h - corner)
    rampCell(cells.mr, corner, h - corner)
    rampCell(cells.bl, h - corner, h)
    rampCell(cells.bm, h - corner, h)
    rampCell(cells.br, h - corner, h)
end

-- Theme-aware window fill shared by the search container, results panel,
-- and every StyleMenuPanel surface. Flat themes paint the live window
-- fill color; a palette with fillTexture shows the cropped art overlay;
-- windowFillBottom/Top give a vertical two-stop gradient (also the
-- pre-relaunch fallback while a new art file is not yet in the client's
-- addon manifest).
function ns.ApplyThemeFill(frame)
    if not (frame and frame.combinedBorder and frame.combinedBorder.fill) then return end
    -- Marks this frame as a window-fill surface: UpdateThemeFillGradient
    -- refuses to ramp anything without this flag.
    frame._efThemeFillTarget = true
    local fill = frame.combinedBorder.fill
    local palette = ns.ACTIVE_UI_PALETTE
    local cWhite = CreateColor and CreateColor(1, 1, 1, 1)

    local artPath = palette and palette.fillTexture
    if artPath then
        local cells = EnsureThemeArtOverlay(frame)
        if cells.mm:SetTexture(artPath) then
            for name, cell in pairs(cells) do
                cell:SetTexture(artPath)
                cell:SetVertexColor(1, 1, 1, 1)
                cell:Show()
            end
            ns.UpdateThemeArtCrop(frame)
            if palette.tintArt then
                ns.UpdateThemeFillGradient(frame)
            end
            -- Base fill goes flat under the (opaque) art so nothing of a
            -- previous theme shows through the corners' antialiased rim.
            local flatBase = palette.windowFill or ns.SEARCH_WINDOW_FILL_COLOR
            for _, cell in pairs(fill) do
                if cWhite and cell.SetGradient then
                    cell:SetGradient("VERTICAL", cWhite, cWhite)
                end
                cell:SetVertexColor(flatBase[1], flatBase[2], flatBase[3], 1)
            end
            return
        end
    end
    if frame._efArtCells then
        for _, cell in pairs(frame._efArtCells) do cell:Hide() end
    end

    local bottom = palette and palette.windowFillBottom
    local top = palette and palette.windowFillTop
    if bottom and top and CreateColor then
        ns.UpdateThemeFillGradient(frame)
        return
    end
    local flat = ns.SEARCH_WINDOW_FILL_COLOR
    for _, cell in pairs(fill) do
        if cWhite and cell.SetGradient then
            cell:SetGradient("VERTICAL", cWhite, cWhite)
        end
        cell:SetVertexColor(flat[1], flat[2], flat[3], 1)
    end
end

function ns.SetRoundedRectBorderColor(frame, r, g, b, a, snapOff)
    if not (frame and frame.combinedBorder and frame.combinedBorder.border) then return end
    for _, t in pairs(frame.combinedBorder.border) do
        t:SetVertexColor(r, g, b, a or 1)
        if snapOff then DisablePixelSnap(t) end
    end
end

function ns.SetRoundedRectBorderEdgeShown(frame, shown)
    if not (frame and frame.combinedBorder and frame.combinedBorder.border) then return end
    for _, t in pairs(frame.combinedBorder.border) do t:SetShown(shown) end
end

-- Wizard-style panel gloss shared by the tutorial wizard, options panel, and
-- What's New popup. A single vertical gradient is mapped across the 9-slice
-- fill; each cell's gradient stops are sampled from its vertical position in
-- the frame. The brightness ramp is packed into the bottom 10% so 8-bit
-- banding collapses into a couple-pixel transition, with smoothstep so the
-- slope varies and bands cannot space evenly.
local GLOSS_DARK_FRAC = 0.90

local function GlossSmoothstep(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    return t * t * (3 - 2 * t)
end

local function GlossLerp(a, b, t) return a + (b - a) * t end

local function GlossColorAt(y, height)
    local t = y / height
    if t < GLOSS_DARK_FRAC then
        t = 0
    else
        t = GlossSmoothstep((t - GLOSS_DARK_FRAC) / (1 - GLOSS_DARK_FRAC))
    end
    -- Ramp endpoints derive from the live theme fill so wizard-style
    -- panels (options, tutorial, What's New) match the selected theme.
    -- Factors are tuned so the Black default reproduces the original
    -- fixed ramp (0.022 -> ~0.21). Light fills get a subtle inverse
    -- gloss (slightly darker body, slightly brighter lip).
    local base = ns.SEARCH_WINDOW_FILL_COLOR
    local br, bg, bb = base[1], base[2], base[3]
    local lum = 0.3 * br + 0.5 * bg + 0.2 * bb
    local mmin = math.min
    if lum > 0.5 then
        return GlossLerp(br * 0.92, mmin(1, br * 1.06 + 0.02), t),
               GlossLerp(bg * 0.92, mmin(1, bg * 1.06 + 0.02), t),
               GlossLerp(bb * 0.92, mmin(1, bb * 1.06 + 0.02), t)
    end
    return GlossLerp(br * 0.45, mmin(1, br * 2.8 + 0.06), t),
           GlossLerp(bg * 0.45, mmin(1, bg * 2.8 + 0.06), t),
           GlossLerp(bb * 0.45, mmin(1, bb * 2.8 + 0.06), t)
end

local function GlossRamp(cell, yTop, yBot, height)
    if not cell then return end
    local r1, g1, b1 = GlossColorAt(yTop, height)
    local r2, g2, b2 = GlossColorAt(yBot, height)
    -- VERTICAL: first color is bottom, second is top.
    cell:SetGradient("VERTICAL", CreateColor(r2, g2, b2, 1), CreateColor(r1, g1, b1, 1))
end

function ns.ApplyWizardPanelGloss(frame)
    local fill = frame.combinedBorder and frame.combinedBorder.fill
    if not fill then return end
    local height = frame:GetHeight()
    if not height or height <= 0 then return end
    local corner = (frame.cbBarHeight or 32) / 2
    GlossRamp(fill.tl, 0, corner, height)
    GlossRamp(fill.tm, 0, corner, height)
    GlossRamp(fill.tr, 0, corner, height)
    GlossRamp(fill.ml, corner, height - corner, height)
    GlossRamp(fill.mm, corner, height - corner, height)
    GlossRamp(fill.mr, corner, height - corner, height)
    GlossRamp(fill.bl, height - corner, height, height)
    GlossRamp(fill.bm, height - corner, height, height)
    GlossRamp(fill.br, height - corner, height, height)
end

-- One-call background for wizard-style panels: near-black rounded fill with
-- relaxed pixel snapping, gloss gradient, border ring hidden (its corner
-- cells band against the gradient fill). The alpha lands on the fill cells;
-- callers that dim the whole frame instead pass 1.
function ns.StyleWizardPanel(frame, alpha)
    if not frame.combinedBorder then
        ns.CreateRoundedRectBorder(frame)
    end
    frame._efWizardAlpha = alpha or 1
    ns.SetRoundedRectBarHeight(frame, 16)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
    local base = ns.SEARCH_WINDOW_FILL_COLOR
    ns.SetRoundedRectFill(frame, base[1] * 0.8, base[2] * 0.8, base[3] * 0.8, 1, true)
    ns.SetRoundedRectBorderBgAlpha(frame, frame._efWizardAlpha)
    ns.ApplyWizardPanelGloss(frame)
    if not frame._efWizardGlossHooked then
        frame._efWizardGlossHooked = true
        frame:HookScript("OnSizeChanged", ns.ApplyWizardPanelGloss)
        -- Re-style on every open so a theme switched while the panel was
        -- closed lands on the next show.
        frame:HookScript("OnShow", function(self)
            ns.StyleWizardPanel(self, self._efWizardAlpha)
        end)
    end
end

local MENU_ROW_HIGHLIGHT_TEX = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- ONE rounded hover pill for every row surface: search result rows and menu
-- rows share this (menus used to cut positional corner masks; now every row
-- wears the same rounded fill the result rows do). wants toggles it; layout
-- (optional) anchors the pill at creation, defaulting to the row's own rect.
-- washColor (optional {r, g, b, a}) overrides the theme's row wash. Callers
-- whose selection carries its own meaning -- the task view's rows tint with
-- the zone-preview accent so row and on-screen preview read as one -- pass it
-- and stay visible on themes that have no wash color of their own.
function Utils.UpdateRoundedRowWash(row, wants, layout, washColor)
    local washR, washG, washB, washA
    if washColor then
        washR, washG, washB, washA = washColor[1], washColor[2], washColor[3], washColor[4]
    else
        washR, washG, washB = ns.RowWashColor()
        washA = ns.RowWashAlpha()
    end
    if not (wants and washR) then
        if row.hoverWash then row.hoverWash:Hide() end
        return
    end
    local hl = row.hoverWash
    if not hl then
        -- The pill must sit BETWEEN its container's fill and the row's text:
        -- strictly ABOVE the container's level and strictly BELOW the row's.
        -- Rows within one level of their container leave no band for it (a
        -- pill at the container's own level z-fights the fill and vanishes --
        -- HARDFOUGHT_BATTLES: equal level = the parent wins), so lift such
        -- rows to container+2 first; their regions ride along.
        local container = row:GetParent()
        if container and container.GetFrameLevel
           and row:GetFrameLevel() <= container:GetFrameLevel() + 1 then
            row:SetFrameLevel(container:GetFrameLevel() + 2)
        end
        hl = CreateFrame("Frame", nil, row)
        if layout then
            layout(hl, row)
        else
            hl:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        end
        hl:SetFrameLevel(row:GetFrameLevel() > 0 and row:GetFrameLevel() - 1 or 0)
        ns.CreateRoundedRectBorder(hl)
        -- Panel ON first (fill cells are born hidden), then ring off: the
        -- documented ordering for fill-only rounded frames.
        ns.SetRoundedRectBorderShown(hl, true)
        ns.SetRoundedRectRingShown(hl, false)
        row.hoverWash = hl
    end
    -- Corner curvature between the window's full curve and a subtle card
    -- round, clamped to the row height so short rows don't overlap corners.
    local rowH = row:GetHeight() or 0
    local barH = 22
    if rowH > 0 and rowH < barH then barH = rowH end
    if hl._efBarH ~= barH then
        hl._efBarH = barH
        ns.SetRoundedRectBarHeight(hl, barH)
    end
    ns.SetRoundedRectFill(hl, washR, washG, washB, washA, true)
    hl:Show()
end

-- Hover/focus wash for menu rows on non-Black themes. This CANNOT be the
-- Button highlight texture: a highlight texture auto-shows on hover only
-- while it lives in the HIGHLIGHT layer, and that layer draws above the
-- row text (fine for the additive glow, opaque paint hides the label).
-- So the wash is a plain BACKGROUND texture whose visibility mirrors the
-- highlight state through the hooks below.
local function UpdateMenuRowWash(row)
    Utils.UpdateRoundedRowWash(row,
        row._efWashActive and (row._efWashHover or row._efWashFocused))
end

local function EnsureMenuRowWash(row)
    -- Legacy flat wash band: superseded by the shared rounded pill.
    if row._efWashTex then
        row._efWashTex:Hide()
        row._efWashTex = nil
        row._efWashHooked = true   -- the old path installed the hover hooks
    end
    if not row._efWashHooked then
        row._efWashHooked = true
        row:HookScript("OnEnter", function(self)
            self._efWashHover = true
            UpdateMenuRowWash(self)
        end)
        row:HookScript("OnLeave", function(self)
            self._efWashHover = nil
            UpdateMenuRowWash(self)
        end)
    end
end

-- Widest natural width across regions: FontStrings measure unwrapped, other
-- regions by their frame width. The panel-shaped companion to
-- MaxRowLabelWidth below; both exist so popups size to their content
-- instead of hardcoding widths that drift from what they hold.
function Utils.MaxContentWidth(regions)
    local maxW = 0
    for i = 1, #regions do
        local region = regions[i]
        if region then
            local w
            if region.GetUnboundedStringWidth then
                w = region:GetUnboundedStringWidth()
            elseif region.GetStringWidth then
                w = region:GetStringWidth()
            elseif region.GetWidth then
                w = region:GetWidth()
            end
            if w and w > maxW then maxW = w end
        end
    end
    return maxW
end

-- Natural width of one flyout row: leading inset (checkbox + gap, or a
-- plain text inset) + optional ._icon texture + label + optional ._chev
-- reserve. Labels measure unwrapped so anchor-clipped rows don't feed
-- their own clipped width back in.
function Utils.FlyoutRowContentWidth(row, leading, iconSize, chevSize)
    local label = row and row._label
    if not label then return 0 end
    local getter = label.GetUnboundedStringWidth or label.GetStringWidth
    local w = leading + getter(label)
    if row._icon and iconSize then w = w + iconSize + 4 end
    if row._chev and chevSize then w = w + 4 + chevSize + 4 end
    return w
end

-- Popup width for a flyout whose widest content line is contentW: side
-- padding both sides plus a small right margin so text never touches the
-- border, floored at FLYOUT_MIN_WIDTH. Every flyout builder sizes through
-- this so widths track content instead of hardcoded constants.
function Utils.FlyoutWidthFor(contentW, pad)
    return mmax(ns.FLYOUT_MIN_WIDTH, mceil(contentW) + pad * 2 + 8)
end

-- The class/spec selector BUTTON is 130 wide everywhere it appears
-- (gear, heirlooms, the appearances chooser); host panels content-fit
-- around it, treating it as fixed-width content.
ns.CLASS_SELECTOR_BTN_W = 130

-- Widest label across popup rows (rows carry ._label or .text). Callers add
-- their own row insets and margins, then clamp to ns.FLYOUT_MIN_WIDTH so
-- flyouts hug their contents.
function Utils.MaxRowLabelWidth(rows, count)
    local maxW = 0
    for i = 1, count or #rows do
        local row = rows[i]
        local label = row and (row._label or row.text)
        if label and label.GetStringWidth then
            local w = label:GetStringWidth() or 0
            if w > maxW then maxW = w end
        end
    end
    return maxW
end

function Utils.RefreshMenuRowHighlights(parent, orderedRows)
    if not parent then return end
    local rows = {}
    if orderedRows then
        for i = 1, #orderedRows do
            local row = orderedRows[i]
            if row and row._efMenuRowHighlightInstalled and row:IsShown() and not row.isSeparator then
                rows[#rows + 1] = row
            end
        end
    else
        for _, row in ipairs({ parent:GetChildren() }) do
            if row and row._efMenuRowHighlightInstalled and row:IsShown() and not row.isSeparator then
                rows[#rows + 1] = row
            end
        end
    end

    -- Hover tint follows the main-row behavior: the theme wash on every
    -- theme except Black, which keeps the classic additive glow. In wash
    -- mode the real highlight texture stays in its HIGHLIGHT layer but
    -- goes transparent (it still drives hover/lock state); the visible
    -- hover is the SAME rounded pill the search result rows wear
    -- (Utils.UpdateRoundedRowWash) -- uniform on every row, no positional
    -- corner masks.
    local washR, washG, washB = ns.RowWashColor()
    for i = 1, #rows do
        local row = rows[i]
        row._efWashActive = washR and true or nil
        local hlTex = row:GetHighlightTexture()
        if washR then
            if hlTex then hlTex:SetAlpha(0) end
            EnsureMenuRowWash(row)
        elseif hlTex then
            hlTex:SetAlpha(1)
            hlTex:SetBlendMode("ADD")
            hlTex:SetVertexColor(1, 1, 1, 1)
        end
        local kb = row.keyboardOverlay
        if kb then
            if washR then
                kb:SetDrawLayer("BACKGROUND", 2)
                kb:SetBlendMode("BLEND")
                kb:SetVertexColor(washR, washG, washB, 1)
            else
                kb:SetDrawLayer("OVERLAY", 0)
                kb:SetBlendMode("ADD")
                kb:SetVertexColor(1, 1, 1, 1)
            end
        end
        UpdateMenuRowWash(row)
    end
end

-- Rows whose highlight is locked because their flyout is open. A hold lives
-- for the popup's whole shown lifetime; `held` tracks whether the lock is
-- currently applied. Hovering a SIBLING row releases the lock immediately
-- (the highlight transfers while the flyout lingers through its hide grace),
-- and re-entering the owner, its popup, or any row inside the popup restores
-- it. The popup's OnHide remains the final release.
local flyoutHighlightHolds = {}
-- Dev-tool peek: the holds are otherwise invisible
-- to external diagnosis.
Utils._flyoutHighlightHolds = flyoutHighlightHolds

local function FindFlyoutHighlightHold(owner, popup)
    for i = 1, #flyoutHighlightHolds do
        local hold = flyoutHighlightHolds[i]
        if hold.owner == owner and hold.popup == popup then return i, hold end
    end
    return nil
end

-- A hold's visual goes through the single-owner highlight API when the row
-- has it: SetMenuHighlightFocused drives BOTH the Black-theme texture lock
-- AND the wash-theme pill. Raw LockHighlight only locks the built-in texture,
-- which wash themes run at alpha 0 -- the hold engaged and nothing showed.
local function SetHoldVisual(owner, held)
    if owner.SetMenuHighlightFocused then
        owner:SetMenuHighlightFocused(held)
    elseif held then
        if owner.LockHighlight then owner:LockHighlight() end
    elseif owner.UnlockHighlight then
        owner:UnlockHighlight()
    end
end

local function MenuRowEnterAdjustsHolds(row)
    if #flyoutHighlightHolds == 0 then return end
    local rowParent = row:GetParent()
    for i = #flyoutHighlightHolds, 1, -1 do
        local hold = flyoutHighlightHolds[i]
        if not hold.popup:IsShown() then
            tremove(flyoutHighlightHolds, i)
        elseif hold.owner == row or rowParent == hold.popup then
            if not hold.held then
                hold.held = true
                SetHoldVisual(hold.owner, true)
            end
        elseif hold.held and hold.owner:GetParent() == rowParent then
            hold.held = false
            SetHoldVisual(hold.owner, false)
        end
    end
end

-- Gray out and disable a flyout/popup option row when the filter above it
-- is unchecked, mirroring the default UI (effectiveEnabled = parent and own).
-- Rows opt into extra dimming via _label/_icon/_chev/_dimTex fields.
-- Theme preview color: gradient themes sample the midpoint of their two
-- stops (the base windowFill is the darkest end and reads near-black);
-- flat themes use their single fill. Shared by the tutorial swatches
-- and the options theme dropdown.
function ns.ThemeSwatchColor(palette)
    local top, bottom = palette.windowFillTop, palette.windowFillBottom
    if top and bottom then
        return (top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2
    end
    return palette.windowFill[1], palette.windowFill[2], palette.windowFill[3]
end

-- Settings-group cards (the big rounded panels on the options tabs, the
-- alias/blacklist tables). Dark themes carry the theme's window fill
-- (gradient/art) at the section alpha, which is what gives the panels
-- their color ramp; light themes keep the flat dark section fill so the
-- fixed light text on them stays readable. Registered weakly so a theme
-- flip restyles every card.
local themeCards = setmetatable({}, { __mode = "k" })

function ns.ApplyCardFill(frame)
    if not (frame and frame.combinedBorder) then return end
    themeCards[frame] = true
    frame._efNoAutoRetint = true
    local sectionAlpha = ns.SECTION_TABLE_FILL[4] or 0.92
    local pal = ns.ACTIVE_UI_PALETTE
    if pal and pal.light then
        frame._efThemeFillTarget = nil
        if frame._efArtCells then
            for _, cell in pairs(frame._efArtCells) do cell:Hide() end
        end
        ns.SetRoundedRectFill(frame, ns.SECTION_TABLE_FILL[1], ns.SECTION_TABLE_FILL[2], ns.SECTION_TABLE_FILL[3], 1, true)
    else
        ns.ApplyThemeFill(frame)
    end
    ns.SetRoundedRectBorderBgAlpha(frame, sectionAlpha)
end

function ns.RestyleCardFills()
    for frame in pairs(themeCards) do
        ns.ApplyCardFill(frame)
    end
end

-- Flyout/submenu chevrons. The Blizzard forward-arrow atlas is gold as
-- authored, so theme tints multiply into mud (blue over gold reads
-- green). Every chevron instead renders the flat white filter arrow
-- rotated to point right; the vertex color is then the color on screen.
-- Chevrons register weakly so a theme flip repaints all of them, shown
-- or not. Two tint schemes on purpose: right-pointing chevrons stay
-- gold on dark themes, dropdown-selector down arrows stay gray.
local themeChevrons = setmetatable({}, { __mode = "k" })
local CHEVRON_POINT_RIGHT = math.pi / 2

function Utils.ChevronRestColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme and theme.chromeGlyph then
        return theme.chromeGlyph[1], theme.chromeGlyph[2], theme.chromeGlyph[3]
    end
    return ns.GOLD_COLOR[1] * 0.9, ns.GOLD_COLOR[2] * 0.9, ns.GOLD_COLOR[3] * 0.9
end

function Utils.ChevronHoverColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme and theme.pathColorHover then
        return theme.pathColorHover[1], theme.pathColorHover[2], theme.pathColorHover[3]
    end
    return ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3]
end

function Utils.SetChevronTexture(tex)
    tex:SetTexture(ns.FILTER_ARROW_TEX)
    tex:SetRotation(CHEVRON_POINT_RIGHT)
    tex:SetVertexColor(Utils.ChevronRestColor())
    themeChevrons[tex] = true
end

function Utils.RetintChevrons()
    for tex in pairs(themeChevrons) do
        tex:SetVertexColor(Utils.ChevronRestColor())
    end
end

function Utils.SetFlyoutRowEnabled(row, enabled)
    if row._efRowEnabled == enabled then return end
    row._efRowEnabled = enabled
    row:SetEnabled(enabled)
    local a = enabled and 1 or 0.35
    if row._label then
        row._label:SetShadowColor(0, 0, 0, 0)
        if not enabled then
            row._label:SetTextColor(0.4, 0.4, 0.4)
        elseif row._label._efOwnColor then
            -- Labels on the always-dark dropdown pills (Blizzard
            -- textholder art) stay white on every theme; leaf text
            -- would sit dark-on-dark there.
            row._label:SetTextColor(1, 1, 1)
        else
            local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
            local leaf = theme and theme.leafColor
            if leaf then
                row._label:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
            else
                row._label:SetTextColor(1, 1, 1)
            end
        end
    end
    local nt = row.GetNormalTexture and row:GetNormalTexture()
    if nt then nt:SetDesaturated(not enabled); nt:SetAlpha(a) end
    local ct = row.GetCheckedTexture and row:GetCheckedTexture()
    if ct then ct:SetDesaturated(not enabled); ct:SetAlpha(a) end
    if row._dimTex then
        for i = 1, #row._dimTex do
            row._dimTex[i]:SetDesaturated(not enabled)
            row._dimTex[i]:SetAlpha(a)
        end
    end
    if row._icon then row._icon:SetDesaturated(not enabled); row._icon:SetAlpha(a) end
    if row._chev then row._chev:SetAlpha(a) end
end

function Utils.InstallMenuRowHighlight(row)
    if not row then return nil end
    if not row._efMenuRowHighlightInstalled then
        row._efMenuRowHighlightInstalled = true
        row:SetHighlightTexture(MENU_ROW_HIGHLIGHT_TEX, "ADD")
        local hl = row:GetHighlightTexture()
        if hl then
            hl:ClearAllPoints()
            hl:SetAllPoints(row)
            hl:SetBlendMode("ADD")
        end
        row:HookScript("OnEnter", MenuRowEnterAdjustsHolds)
    end
    row.SetMenuHighlightFocused = function(self, focused)
        self._efWashFocused = focused and true or nil
        if focused then
            if self.LockHighlight then self:LockHighlight() end
        else
            if self.UnlockHighlight then self:UnlockHighlight() end
        end
        UpdateMenuRowWash(self)
    end
    row.ClearMenuHighlightState = function(self)
        self._efWashFocused = nil
        self._efWashHover = nil
        if self.UnlockHighlight then self:UnlockHighlight() end
        if self.keyboardOverlay then self.keyboardOverlay:Hide() end
        UpdateMenuRowWash(self)
    end
    return row.SetMenuHighlightFocused
end

-- Background-fill button style (keybind captures): rests on the window
-- color with the theme's main text color, hovers with the row wash.
-- RefreshVisual keeps both current across theme flips (the retint walker
-- calls it; the fill is also tagged for the fill sweep).
function ns.StyleBgFillButton(btn)
    btn._efBgFill = true
    btn._efLeafLabel = true
    btn.RefreshVisual = function(self)
        if self:IsEnabled() then
            if self._efPaintState then self._efPaintState(self, ns.BTN_FILL_NORMAL) end
            local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
            if self._label then
                if theme and theme.leafColor then
                    self._label:SetTextColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3], 1)
                else
                    self._label:SetTextColor(1, 1, 1, 1)
                end
            end
        end
    end
    btn:RefreshVisual()
end

-- Nav-pill styled buttons (alias/shortkey table cells): rest on the
-- selected-tab fill (a window-fill pill on light themes, slate on dark)
-- with the tab's inverted label, so they read as a selected tab instead of
-- vanishing into the table card. RefreshVisual keeps fill and label current
-- across theme flips (the retint walker calls it; the fill is also tagged
-- for the fill sweep).
function ns.StyleNavPillButton(btn)
    btn._efNavFill = true
    btn.RefreshVisual = function(self)
        if not self:IsEnabled() then return end
        if self._efPaintState then self._efPaintState(self, ns.BTN_FILL_NORMAL) end
        if not self._label then return end
        -- The window-fill pill wants the card color as its label (the same
        -- inversion the selected tab uses); dark themes keep light text on
        -- the slate pill.
        local pal = ns.ACTIVE_UI_PALETTE
        if pal and pal.light then
            local card = ns.SECTION_TABLE_FILL
            self._label:SetTextColor(card[1], card[2], card[3], 1)
        else
            local prim = ns.TEXT_PRIMARY
            self._label:SetTextColor(prim[1], prim[2], prim[3], 1)
        end
    end
    btn:RefreshVisual()
end

function Utils.SetCheckboxTextures(check, size)
    check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    check:GetNormalTexture():SetSize(size, size)
    check:GetNormalTexture():ClearAllPoints()
    check:GetNormalTexture():SetPoint("LEFT", 4, 0)
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:GetCheckedTexture():SetSize(size, size)
    check:GetCheckedTexture():ClearAllPoints()
    check:GetCheckedTexture():SetPoint("LEFT", 4, 0)
end

function ns.CreateModernButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent)
    local rawSetSize = btn.SetSize
    rawSetSize(btn, width or 120, height or 22)

    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, mmin(height or 22, 10))
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    ns.SetRoundedRectBorderFillColor(btn, unpack(ns.BTN_FILL_NORMAL))
    btn._efControlFillKind = "BTN_FILL_NORMAL"

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text or "")
    label:SetTextColor(1, 1, 1, 1)
    -- Flat button design: the font object's baked drop shadow reads as
    -- smear on the pill fills. The label owns its color (light text on
    -- the dark pill on every theme); the menu text pass must not touch it.
    label:SetShadowColor(0, 0, 0, 0)
    label._efOwnColor = true
    btn._label = label

    -- Inset reserved for the text inside the button. Leaves a small margin
    -- around the rounded corners without eating the entire available width
    -- on narrow buttons (preset rows, +/- spinners, etc).
    local TEXT_INSET = 4

    local function fitLabelEllipsis(self)
        local label = self._label
        if not label then return end
        local full = self._fullText or ""
        if full == "" then
            label:SetText("")
            self._isTruncated = false
            return
        end
        local avail = (self:GetWidth() or 0) - TEXT_INSET * 2
        if avail <= 0 then
            label:SetText(full)
            self._isTruncated = false
            return
        end
        label:SetText(full)
        if label:GetStringWidth() <= avail then
            self._isTruncated = false
            return
        end
        -- Binary search for the longest prefix that fits with an ellipsis.
        local ELLIPSIS = "..."
        local lo, hi = 1, #full
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            label:SetText(full:sub(1, mid) .. ELLIPSIS)
            if label:GetStringWidth() <= avail then
                lo = mid
            else
                hi = mid - 1
            end
        end
        label:SetText(full:sub(1, lo) .. ELLIPSIS)
        self._isTruncated = true
    end
    btn._fitLabel = fitLabelEllipsis

    btn.SetText = function(self, value)
        self._fullText = value or ""
        fitLabelEllipsis(self)
    end
    btn.GetText = function(self)
        return self._fullText or (self._label and self._label:GetText()) or ""
    end
    btn.SetSize = function(self, w, h)
        rawSetSize(self, w, h)
        ns.SetRoundedRectBarHeight(self, mmin(h or self:GetHeight() or 22, 10))
        fitLabelEllipsis(self)
    end

    -- Tooltip-on-truncate. If the button's text was clipped to ellipsis,
    -- hovering for 0.5s pops the full label. Skipped silently when another
    -- handler has already claimed GameTooltip for this button (e.g. a real
    -- explanatory tooltip) so this never fights an intentional one.
    btn:HookScript("OnEnter", function(self)
        if not self._isTruncated then return end
        if self._ellipsisTimer then self._ellipsisTimer:Cancel(); self._ellipsisTimer = nil end
        self._ellipsisTimer = C_Timer.NewTimer(0.5, function()
            self._ellipsisTimer = nil
            if not self:IsMouseOver() then return end
            if GameTooltip:GetOwner() == self and GameTooltip:IsShown() then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self._fullText or "", 1, 1, 1)
            GameTooltip:Show()
            self._showedEllipsisTooltip = true
        end)
    end)
    btn:HookScript("OnLeave", function(self)
        if self._ellipsisTimer then self._ellipsisTimer:Cancel(); self._ellipsisTimer = nil end
        if self._showedEllipsisTooltip then
            self._showedEllipsisTooltip = nil
            GameTooltip:Hide()
        end
    end)

    local rawSetNormalFont = btn.SetNormalFontObject
    btn.SetNormalFontObject = function(self, fontObject)
        if rawSetNormalFont then rawSetNormalFont(self, fontObject) end
        if self._label then self._label:SetFontObject(fontObject) end
    end
    local rawSetHighlightFont = btn.SetHighlightFontObject
    btn.SetHighlightFontObject = function(self, fontObject)
        if rawSetHighlightFont then rawSetHighlightFont(self, fontObject) end
    end

    local function PaintState(self, fillTable)
        -- Window-fill styled buttons (stepper +/-) rest on the row-wash
        -- tint (a step off the window color; the plain fill blended into
        -- the panel on flat themes); hover/pressed keep the shared states.
        if self._efWindowFill and fillTable == ns.BTN_FILL_NORMAL then
            local washR, washG, washB = ns.RowWashColor()
            if washR then
                ns.SetRoundedRectBorderFillColor(self, washR, washG, washB, 1)
                self._efControlFillKind = false
                return
            end
        end
        -- Background-fill buttons (keybind captures) rest on the window
        -- color itself and hover with the wash.
        if self._efBgFill then
            if fillTable == ns.BTN_FILL_NORMAL then
                fillTable = ns.SEARCH_WINDOW_FILL_COLOR
            elseif fillTable == ns.BTN_FILL_HOVER then
                local washR, washG, washB = ns.RowWashColor()
                if washR then
                    ns.SetRoundedRectBorderFillColor(self, washR, washG, washB, 1)
                    self._efControlFillKind = false
                    return
                end
            end
        end
        -- Nav-pill buttons (alias/shortkey cells) rest on the selected-tab
        -- fill and hover a step lighter, so they read as a selected tab
        -- instead of blending into the table card (on light themes the plain
        -- button fill and the card fill are the same dark mix).
        if self._efNavFill then
            if fillTable == ns.BTN_FILL_NORMAL then
                fillTable = ns.NAV_SELECTED_FILL
            elseif fillTable == ns.BTN_FILL_HOVER then
                fillTable = ns.NAV_HOVER_FILL
            end
        end
        ns.SetRoundedRectBorderFillColor(self, unpack(fillTable))
        self._efControlFillKind = ns.LIVE_FILL_NAMES[fillTable]
    end
    btn._efPaintState = PaintState
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_HOVER) end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_NORMAL) end
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_PRESSED) end
    end)
    btn:SetScript("OnMouseUp", function(self)
        if not self:IsEnabled() then return end
        PaintState(self, self:IsMouseOver() and ns.BTN_FILL_HOVER or ns.BTN_FILL_NORMAL)
    end)
    btn:SetScript("OnDisable", function(self)
        PaintState(self, ns.BTN_FILL_DISABLED)
        -- A touch lighter than TEXT_DIM: disabled labels on the dark
        -- disabled pill were near-unreadable.
        if self._label then self._label:SetTextColor(0.72, 0.72, 0.72, 1) end
    end)
    btn:SetScript("OnEnable", function(self)
        PaintState(self, ns.BTN_FILL_NORMAL)
        if self._label then
            local theme = self._efLeafLabel and ns.Results and ns.Results.GetActiveTheme
                and ns.Results:GetActiveTheme()
            if theme and theme.leafColor then
                self._label:SetTextColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3], 1)
            else
                self._label:SetTextColor(1, 1, 1, 1)
            end
        end
    end)

    if text then btn:SetText(text) end
    return btn
end

-- Thin two-stroke "X" close button (dim by default, white on hover), matching
-- the tutorial / what's-new windows. Two rotated 1px lines stay sharp at any
-- UI scale. Caller sets the OnClick handler.
local X_DEFAULT_HOVER = {1, 1, 1}
-- Resolve a close-X stroke color: an explicit SetXColors value wins,
-- otherwise the active theme's faint text at rest and readable text on
-- hover, so the stroke always dims-to-brightens. leaf/pathColorHover both
-- read near-white on the gradient dark themes (rest looked identical to
-- hover) and a plain white hover vanished on the light ones; faint->leaf
-- keeps a real contrast step on every theme. Neutral fallbacks pre-theme.
local function ResolveXColor(explicit, field, fallback)
    if explicit then return explicit end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    return (theme and theme[field]) or fallback
end
function ns.CreateCloseX(parent, size)
    size = size or 18
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    local function MakeStroke()
        local t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetSize(size - 2, 1.5)
        t:SetPoint("CENTER")
        return t
    end
    local stroke1 = MakeStroke(); stroke1:SetRotation(math.pi / 4)
    local stroke2 = MakeStroke(); stroke2:SetRotation(-math.pi / 4)
    local function setX(r, g, b)
        stroke1:SetVertexColor(r, g, b, 1)
        stroke2:SetVertexColor(r, g, b, 1)
    end
    -- _xRest/_xHover stay nil by default so the stroke follows the active
    -- theme (faint at rest, readable on hover); SetXColors lets a panel pin
    -- explicit colors. Read live at paint time, so a flip repaints on the
    -- next hover, and a themed panel's own repaint can force it sooner.
    local function paintRest() setX(Utils.RGB(ResolveXColor(btn._xRest, "textFaint", ns.TEXT_DIM))) end
    local function paintHover() setX(Utils.RGB(ResolveXColor(btn._xHover, "leafColor", X_DEFAULT_HOVER))) end
    paintRest()
    btn:SetScript("OnEnter", paintHover)
    btn:SetScript("OnLeave", paintRest)
    btn.SetXColors = function(_, rest, hover)
        btn._xRest = rest
        btn._xHover = hover
        if btn:IsMouseOver() then paintHover() else paintRest() end
    end
    return btn
end

-- A small, addon-styled popup with a single read-only field whose text is
-- pre-selected so the user can immediately Ctrl-C it. Shared by the Wowhead
-- link option and the bug-report / feature-request feedback URLs. WoW addons
-- cannot write the clipboard, so a copy field is the correct approach.
local copyBox
-- Read-only feel for copy-to-share editboxes (Wowhead links, export
-- codes): user keystrokes revert to the canonical text and reselect it,
-- so the Ctrl-C content can't be mangled by an accidental keypress.
-- Pass nil to make the box editable again (import flows reuse the box).
function Utils.SetEditBoxReadOnlyText(editBox, text)
    if not editBox._efReadOnlyHooked then
        editBox._efReadOnlyHooked = true
        editBox:HookScript("OnTextChanged", function(self, userInput)
            local canonical = self._efReadOnlyText
            if userInput and canonical and self:GetText() ~= canonical then
                self:SetText(canonical)
                self:HighlightText()
            end
        end)
        -- A read-only box always copies its full text, so the selection
        -- must always SHOW that: clicking inside would normally drop the
        -- highlight to place a cursor; restore it immediately.
        editBox:HookScript("OnMouseUp", function(self)
            if self._efReadOnlyText then self:HighlightText() end
        end)
    end
    editBox._efReadOnlyText = text
    if text then editBox:SetText(text) end
end

-- ESC-close WITHOUT UISpecialFrames. Inserting an addon frame's name into
-- UISpecialFrames poisons Blizzard's CloseWindows for the whole session:
-- the secure walker reads the addon-created global by name and its
-- execution turns tainted from that point (taint.log: "Execution tainted
-- by EasyFind while reading global EasyFindEscCatcher"), which then
-- spreads through panel and action-bar bookkeeping and detonates in
-- combat as ADDON_ACTION_BLOCKED and secret-value errors. Instead, while
-- any registered EasyFind frame is shown, hold a transient ESCAPE
-- override bind onto a hidden dispatch button that closes the top-most
-- (most recently shown) one. LIFO matches how stacked popups should eat
-- ESC. A focused EditBox still consumes ESC first (focus outranks
-- bindings), so focused-ESC behavior is untouched. Override bindings can
-- only change out of combat: PLAYER_REGEN_DISABLED's grace window drops
-- the bind for the fight and REGEN_ENABLED re-arms it.
local escStack = {}
local escOwner, escDispatch
-- Whether the ESCAPE override is currently bound. Binding writes are
-- dedup'd against it: redundant writes near the combat boundary put
-- Blizzard's key re-attach pass on EasyFind's execution and detonate
-- protected bar updates (PetActionBar:SetShownBase autopsy).
local escArmed = false
local InCombatLockdown = InCombatLockdown
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings

local function EscArm()
    if not escOwner or InCombatLockdown() then return end
    -- An entry only wants ESC while its shouldEat predicate (if any)
    -- passes. Always Show registers the search bar with a predicate that
    -- is false when nothing is dismissable, so the override is not bound
    -- at all and a bare ESC reaches the game (zero keyboard capture
    -- outside explicit UI state).
    local wantArmed = false
    for i = #escStack, 1, -1 do
        local entry = escStack[i]
        -- pcall fail-open: a broken predicate must never leave ESC bound
        -- (captured input is worse than a missed close).
        local wants = true
        if entry.shouldEat then
            local ok, eat = pcall(entry.shouldEat)
            wants = ok and eat and true or false
        end
        if wants then
            wantArmed = true
            break
        end
    end
    if wantArmed == escArmed then return end
    if wantArmed then
        -- escOwner only ever holds this one binding, so the rebind
        -- overwrites in place; no clear-first needed.
        SetOverrideBindingClick(escOwner, true, "ESCAPE", "EasyFindEscDispatch")
    else
        ClearOverrideBindings(escOwner)
    end
    escArmed = wantArmed
end

-- Release the ESCAPE override immediately. Used when a dispatch turns out to
-- have nothing to close: holding a binding that does nothing swallows the key
-- forever (measured: six presses in a row reported "our
-- override owned the key" with zero state change, and ESC stayed ours even
-- with a Blizzard panel open). A missed close is recoverable; a dead ESC is
-- not, so we always hand the key back and let EscArm re-take it when real
-- dismissable state reappears.
local function EscDisarm()
    if not escOwner or not escArmed or InCombatLockdown() then return end
    ClearOverrideBindings(escOwner)
    escArmed = false
end

-- Re-evaluate the ESC override after a shouldEat input changes while the
-- owning frame stays shown (menus or results opening and closing).
function Utils.RefreshEscArm()
    EscArm()
end

-- Dev probe surface: who owns ESCAPE right now.
-- Read-only; returns the armed flag plus one record per stack entry.
function ns.GetEscOverrideState()
    local entries = {}
    for i = 1, #escStack do
        local e = escStack[i]
        local wants, err = true, nil
        if e.shouldEat then
            local ok, eat = pcall(e.shouldEat)
            wants = ok and eat and true or false
            if not ok then err = tostring(eat) end
        end
        entries[i] = {
            name = (e.frame and e.frame.GetName and e.frame:GetName())
                or tostring(e.frame),
            shown = e.frame and e.frame:IsShown() or false,
            wants = wants,
            err = err,
        }
    end
    return escArmed, entries
end

local function EscRemove(frame)
    for i = #escStack, 1, -1 do
        if escStack[i].frame == frame then tremove(escStack, i) end
    end
end

local function EnsureEscDispatch()
    if escOwner then return end
    escOwner = CreateFrame("Frame", nil, UIParent)
    -- Kept shown (1px offscreen corner) like the shortkey pool: the
    -- binding must always have a clickable target.
    escDispatch = CreateFrame("Button", "EasyFindEscDispatch", UIParent)
    escDispatch:SetSize(1, 1)
    escDispatch:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    escDispatch:SetScript("OnClick", function()
        -- Top-most entry that currently wants ESC; entries whose
        -- predicate is false (or errors, pcall fail-open) never block a
        -- lower one.
        for i = #escStack, 1, -1 do
            local entry = escStack[i]
            local wants = true
            if entry.shouldEat then
                local ok, eat = pcall(entry.shouldEat)
                wants = ok and eat and true or false
            end
            if wants then
                -- close() reports whether it actually dismissed anything. A
                -- predicate that keeps claiming ESC while its close is a
                -- no-op would eat every press forever, so a false (or an
                -- erroring) close hands the key straight back.
                local ok, handled = pcall(entry.close)
                if not ok or handled == false then EscDisarm() end
                return
            end
        end
        -- Nothing wanted it: we should not have held the binding at all.
        EscDisarm()
    end)
    escOwner:RegisterEvent("PLAYER_REGEN_DISABLED")
    escOwner:RegisterEvent("PLAYER_REGEN_ENABLED")
    escOwner:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if escArmed then
                ClearOverrideBindings(escOwner)
                escArmed = false
            end
        else
            EscArm()
        end
    end)
end

-- Register frame so ESC closes it (via close()) while it is shown.
-- close defaults to hiding the frame. shouldEat (optional) is consulted
-- at arm time and at dispatch: false means this entry neither binds nor
-- consumes ESC right now. Callers whose predicate inputs change while
-- the frame stays shown must call Utils.RefreshEscArm() on those changes.
function Utils.AttachEscClose(frame, close, shouldEat)
    EnsureEscDispatch()
    close = close or function() frame:Hide() end
    frame:HookScript("OnShow", function()
        EscRemove(frame)
        escStack[#escStack + 1] = { frame = frame, close = close, shouldEat = shouldEat }
        EscArm()
    end)
    frame:HookScript("OnHide", function()
        EscRemove(frame)
        EscArm()
    end)
    if frame:IsShown() then
        escStack[#escStack + 1] = { frame = frame, close = close, shouldEat = shouldEat }
        EscArm()
    end
end
ns.AttachEscClose = function(frame, close, shouldEat) return Utils.AttachEscClose(frame, close, shouldEat) end

local function EnsureCopyBox()
    if not copyBox then
        local f = CreateFrame("Frame", "EasyFindCopyBox", UIParent, "BackdropTemplate")
        f:SetSize(470, 104)
        f:SetPoint("CENTER", 0, 180)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        ns.StyleMenuPanel(f)

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title._efOwnColor = true
        f.title:SetPoint("TOP", f, "TOP", 0, -14)
        -- Centered so the item name on its own line sits under the
        -- middle of the hint. Wrap stays on for the explicit newline;
        -- the width fit below always sizes the frame to the widest
        -- line, so no automatic wrapping occurs.
        f.title:SetJustifyH("CENTER")
        f.title:SetWordWrap(true)
        f.title:SetSpacing(2)

        -- Hidden twin of the editbox font, used to size the frame to the
        -- copied text (an editbox cannot report its rendered width).
        f.measure = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.measure:Hide()

        local field = CreateFrame("Frame", nil, f)
        field:SetPoint("TOP", f.title, "BOTTOM", 0, -10)
        field:SetPoint("LEFT", f, "LEFT", 14, 0)
        field:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        field:SetHeight(26)
        local bg = field:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.45)

        local editBox = CreateFrame("EditBox", nil, field)
        editBox:SetPoint("LEFT", 8, 0)
        editBox:SetPoint("RIGHT", -8, 0)
        editBox:SetHeight(20)
        editBox:SetFontObject("GameFontHighlight")
        editBox:SetAutoFocus(false)
        editBox:SetJustifyH("LEFT")
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
        editBox:SetScript("OnEnterPressed", function(self) self:HighlightText() end)
        editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        f.editBox = editBox

        -- Ctrl-C confirmation. Addons cannot read the clipboard, but while the
        -- field is focused the editbox fires OnKeyDown for the copy chord, so a
        -- detected Ctrl+C flashes "Copied" (title color) and fades it out.
        local copiedHolder = CreateFrame("Frame", nil, f)
        copiedHolder:SetPoint("TOP", field, "BOTTOM", 0, -6)
        copiedHolder:SetSize(140, 16)
        copiedHolder:Hide()
        local copied = copiedHolder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        copied._efOwnColor = true
        copied:SetPoint("CENTER")
        copied:SetText(L["COPIED"])
        local copiedFade = copiedHolder:CreateAnimationGroup()
        local fadeAnim = copiedFade:CreateAnimation("Alpha")
        fadeAnim:SetFromAlpha(1)
        fadeAnim:SetToAlpha(0)
        fadeAnim:SetStartDelay(0.8)
        fadeAnim:SetDuration(0.8)
        copiedFade:SetScript("OnFinished", function() copiedHolder:Hide() end)
        editBox:SetScript("OnKeyDown", function(_, key)
            if key ~= "C" or not IsControlKeyDown() then return end
            copiedFade:Stop()
            copiedHolder:SetAlpha(1)
            copiedHolder:Show()
            copiedFade:Play()
        end)

        -- Rendered-link mode: shows the real hyperlink (colored, hoverable)
        -- instead of a Ctrl-C field; clicking it inserts the link into the
        -- active chat editbox, like shift-clicking an item in a bag.
        local linkHolder = CreateFrame("Frame", nil, f)
        linkHolder:SetPoint("TOP", f.title, "BOTTOM", 0, -10)
        linkHolder:SetPoint("LEFT", f, "LEFT", 14, 0)
        linkHolder:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        linkHolder:SetHeight(26)
        linkHolder:SetHyperlinksEnabled(true)
        local linkFS = linkHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        linkFS:SetPoint("CENTER")
        linkHolder:SetScript("OnHyperlinkClick", function()
            if f._link then ChatEdit_InsertLink(f._link) end
        end)
        linkHolder:SetScript("OnHyperlinkEnter", function(self, linkData)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if not pcall(GameTooltip.SetHyperlink, GameTooltip, linkData) then
                GameTooltip:Hide()
            end
        end)
        linkHolder:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
        linkHolder:Hide()
        f.linkHolder = linkHolder
        f.linkFS = linkFS
        f.field = field

        local close = ns.CreateCloseX(f, 14)
        close:SetPoint("TOPRIGHT", -8, -8)
        close:SetScript("OnClick", function() f:Hide() end)

        -- ESC closes the box even when the editbox lost focus, via the
        -- taint-free override-bind path (never UISpecialFrames).
        Utils.AttachEscClose(f)

        f:Hide()
        copyBox = f
    end
    return copyBox
end

function ns.ShowCopyBox(text, labelText)
    text = text or ""
    EnsureCopyBox()
    copyBox._text = text
    copyBox._link = nil
    copyBox.linkHolder:Hide()
    copyBox.field:Show()
    copyBox.title:SetText(labelText or "")
    -- Gold heading is unreadable on the light palettes; there the title
    -- wears the theme's main text color instead.
    local copyTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if copyTheme and copyTheme.lightTheme then
        copyBox.title:SetTextColor(unpack(copyTheme.leafColor))
    else
        copyBox.title:SetTextColor(1.0, 0.82, 0)
    end
    -- Width tracks the widest of the title and the copied text (+ field
    -- padding), so short links show whole; very long text still clips at
    -- the cap (full text stays selected for Ctrl-C). Height follows the
    -- title, which is two lines when the hint carries the item name.
    copyBox.measure:SetText(text)
    local textW = math.floor(copyBox.measure:GetStringWidth() + 0.5)
    copyBox:SetWidth(math.max(200,
        math.floor(copyBox.title:GetStringWidth() + 0.5) + 44,
        math.min(textW + 52, 460)))
    copyBox:SetHeight(88 + math.floor(copyBox.title:GetStringHeight() + 0.5))
    copyBox:Show()
    local eb = copyBox.editBox
    Utils.SetEditBoxReadOnlyText(eb, text)
    eb:SetCursorPosition(0)
    eb:SetFocus()
    eb:HighlightText()
    -- Re-assert next frame; SetFocus during layout can drop the selection.
    Utils.SafeAfter(0, function()
        if copyBox:IsShown() then
            eb:SetFocus()
            eb:HighlightText()
        end
    end)
end

-- Rendered-link variant of the copy box: no Ctrl-C field, the popup shows
-- the real hyperlink (colored, tooltip on hover) and clicking it inserts
-- the link into the active chat editbox.
function ns.ShowChatLinkBox(link, labelText)
    if not link or link == "" then return end
    EnsureCopyBox()
    copyBox._text = nil
    copyBox._link = link
    copyBox.field:Hide()
    copyBox.linkHolder:Show()
    copyBox.linkFS:SetText(link)
    copyBox.title:SetText(labelText or "")
    -- Gold heading is unreadable on the light palettes; there the title
    -- wears the theme's main text color instead.
    local copyTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if copyTheme and copyTheme.lightTheme then
        copyBox.title:SetTextColor(unpack(copyTheme.leafColor))
    else
        copyBox.title:SetTextColor(1.0, 0.82, 0)
    end
    local w = math.max(
        math.floor(copyBox.title:GetStringWidth() + 0.5),
        math.floor(copyBox.linkFS:GetStringWidth() + 0.5))
    copyBox:SetWidth(math.max(200, w + 44))
    copyBox:SetHeight(88 + math.floor(copyBox.title:GetStringHeight() + 0.5))
    copyBox:Show()
end

-- Themed replacement for Blizzard StaticPopup confirm/input dialogs, styled
-- like the rest of EasyFind (StyleMenuPanel + CreateModernButton). One pooled
-- frame. opts: { text, acceptText, cancelText, hasEditBox, editBoxDefault,
-- maxLetters, onAccept(value) }.
local themedDialog

function ns.ShowThemedDialog(opts)
    opts = opts or {}
    local f = themedDialog
    if not f then
        f = CreateFrame("Frame", "EasyFindThemedDialog", UIParent, "BackdropTemplate")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:SetFrameLevel(800)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:SetPoint("CENTER", 0, 120)
        ns.StyleMenuPanel(f)

        f.message = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.message:SetJustifyH("CENTER")
        f.message:SetSpacing(2)
        f.message:SetTextColor(unpack(ns.TEXT_PRIMARY))
        -- ShowThemedDialog owns this color per prompt type.
        f.message._efOwnColor = true

        local field = CreateFrame("Frame", nil, f)
        field:SetHeight(26)
        local bg = field:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.45)
        local eb = CreateFrame("EditBox", nil, field)
        eb:SetPoint("LEFT", 8, 0)
        eb:SetPoint("RIGHT", -8, 0)
        eb:SetHeight(20)
        eb:SetFontObject("GameFontHighlight")
        eb:SetAutoFocus(false)
        eb:SetJustifyH("LEFT")
        f.field = field
        f.editBox = eb

        f.accept = ns.CreateModernButton(f, "", 120, 22)
        f.third = ns.CreateModernButton(f, "", 120, 22)
        f.cancel = ns.CreateModernButton(f, "", 120, 22)

        -- Optional "apply to all" checkbox for Windows-style batch confirms.
        -- Its state is passed to onAccept/onThird so a single prompt can decide
        -- the whole remaining set.
        f.check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        f.check:SetSize(22, 22)
        Utils.SetCheckboxTextures(f.check, 22)
        f.check.text = f.check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.check.text:SetPoint("LEFT", f.check, "RIGHT", 2, 0)
        f.check.text:SetTextColor(unpack(ns.TEXT_PRIMARY))

        local function checkedState()
            return f.check:IsShown() and f.check:GetChecked() and true or false
        end
        local function accept()
            local val = f._hasEditBox and f.editBox:GetText() or nil
            local all = checkedState()
            f:Hide()
            if f._onAccept then f._onAccept(val, all) end
        end
        local function third()
            local all = checkedState()
            f:Hide()
            if f._onThird then f._onThird(all) end
        end
        local function cancel()
            f:Hide()
        end
        f.accept:SetScript("OnClick", accept)
        f.third:SetScript("OnClick", third)
        f.cancel:SetScript("OnClick", cancel)
        eb:SetScript("OnEnterPressed", accept)
        eb:SetScript("OnEscapePressed", cancel)
        -- ESC closes via the taint-free override-bind path (never
        -- UISpecialFrames); cancel is a bare hide, so this is the
        -- complete cancel path.
        Utils.AttachEscClose(f, cancel)

        themedDialog = f
    end

    f._onAccept = opts.onAccept
    f._onThird = opts.onThird
    f._hasEditBox = opts.hasEditBox and true or false

    f.message:SetText(opts.text or "")
    -- Title-style prompts (alias/shortkey/Wowhead family) go gold;
    -- plain confirmations keep the primary text color. On light themes
    -- gold is unreadable, so it wears the theme's hue-dark accent.
    local msgColor = opts.messageColor or ns.TEXT_PRIMARY
    if msgColor == ns.GOLD_COLOR then
        local dlgTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if dlgTheme and dlgTheme.lightTheme then
            msgColor = dlgTheme.pathColorHover or dlgTheme.leafColor
        end
    end
    f.message:SetTextColor(msgColor[1], msgColor[2], msgColor[3], 1)

    local width = 380
    f:SetWidth(width)
    f.message:SetWidth(width - 32)

    local used = 14
    f.message:ClearAllPoints()
    f.message:SetPoint("TOPLEFT", 16, -used)
    f.message:SetPoint("TOPRIGHT", -16, -used)
    used = used + f.message:GetStringHeight() + 14

    if f._hasEditBox then
        f.field:ClearAllPoints()
        f.field:SetPoint("TOPLEFT", 16, -used)
        f.field:SetPoint("TOPRIGHT", -16, -used)
        f.field:Show()
        f.editBox:SetMaxLetters(opts.maxLetters or 128)
        f.editBox:SetText(opts.editBoxDefault or "")
        used = used + 26 + 14
    else
        f.field:Hide()
    end

    if opts.checkText then
        f.check.text:SetText(opts.checkText)
        f.check:SetChecked(opts.checkDefault and true or false)
        f.check:ClearAllPoints()
        f.check:SetPoint("TOPLEFT", 16, -used)
        f.check:Show()
        used = used + 22 + 10
    else
        f.check:Hide()
    end

    f.accept:SetText(opts.acceptText or _G["OKAY"] or _G["ACCEPT"] or "OK")
    f.cancel:SetText(opts.cancelText or _G["CANCEL"] or "Cancel")
    f.accept:ClearAllPoints()
    f.third:ClearAllPoints()
    f.cancel:ClearAllPoints()
    if opts.thirdText then
        -- Three across (e.g. Replace / Skip / Cancel), narrower to fit.
        f.third:SetText(opts.thirdText)
        f.third:Show()
        f.accept:SetWidth(108)
        f.third:SetWidth(108)
        f.cancel:SetWidth(108)
        f.accept:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -used)
        f.third:SetPoint("TOP", f, "TOP", 0, -used)
        f.cancel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -used)
    else
        -- Accept on the left, Cancel on the right (standard button order).
        f.third:Hide()
        f.accept:SetWidth(120)
        f.cancel:SetWidth(120)
        f.accept:SetPoint("TOPRIGHT", f, "TOP", -6, -used)
        f.cancel:SetPoint("TOPLEFT", f, "TOP", 6, -used)
    end
    used = used + 22 + 14
    f:SetHeight(used)

    f:Show()
    if f._hasEditBox then
        f.editBox:SetFocus()
        f.editBox:HighlightText()
    end
    return f
end

local WOWHEAD_LOCALE_SUB = {
    deDE = "de", esES = "es", esMX = "es", frFR = "fr", itIT = "it",
    ptBR = "pt", ruRU = "ru", koKR = "ko", zhCN = "cn", zhTW = "cn",
}

-- Percent-encode a string for use in a Wowhead search query.
local function WowheadSearchEncode(s)
    return (s:gsub("[^%w]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build a wowhead.com URL for a search result from the id fields it carries.
-- Returns nil for results with no meaningful Wowhead page (settings, macros,
-- gear sets, ...), so the menu option only appears where it's useful.
function ns.GetWowheadLink(data)
    if not data then return nil end
    local kind, id, query, listing

    if data.appearanceItemID and C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
        local info = C_TransmogCollection.GetSourceInfo(data.appearanceItemID)
        if info and info.itemID then kind, id = "item", info.itemID end
    elseif data.heirloomItemID then
        kind, id = "item", data.heirloomItemID
    elseif data.toyItemID then
        kind, id = "item", data.toyItemID
    elseif data.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        local spellID = select(2, C_MountJournal.GetMountInfoByID(data.mountID))
        if spellID then kind, id = "spell", spellID end
    elseif (data.speciesID or data.petID) and C_PetJournal then
        local species = data.speciesID
        if not species and type(data.petID) == "number" then species = data.petID end
        local npcID
        if species and C_PetJournal.GetPetInfoBySpeciesID then
            npcID = select(4, C_PetJournal.GetPetInfoBySpeciesID(species))
        elseif type(data.petID) == "string" and C_PetJournal.GetPetInfoByPetID then
            npcID = select(11, C_PetJournal.GetPetInfoByPetID(data.petID))
        end
        if npcID then kind, id = "npc", npcID end
    elseif data.transmogSetID then
        -- Wowhead's transmog-set IDs are internal and do not match WoW's setID
        -- (that number 404s). The item that teaches a set is named
        -- "Ensemble: <set>", so search that -- it lands on the set's gear.
        if data.name then query = L["WOWHEAD_SET_PREFIX"] .. " " .. data.name end
    elseif data.encounterID and data.category == "Boss" then
        -- EJ_GetCreatureInfo returns a journal-internal creature id that does
        -- not match Wowhead's world NPC entries (e.g. LK's journal id 3927 is
        -- an unrelated NPC on Wowhead), so search the boss name -- it lands on
        -- the boss's page.
        if data.name then query = data.name end
    elseif data.achievementID and data.category == "Achievement" then
        kind, id = "achievement", data.achievementID
    elseif data.currencyID then
        kind, id = "currency", data.currencyID
    elseif data.factionID then
        kind, id = "faction", data.factionID
    elseif data.titleID then
        -- WoW's titleID is an index into the client's own title list and bears
        -- no relation to Wowhead's title ids, so linking it landed on an
        -- unrelated page. Link the achievement that awards the title instead:
        -- it is exact, and it is the page that actually explains how to earn
        -- it. Titles from quests, PvP ranks and events have no achievement, so
        -- those fall back to a name search rather than a wrong id.
        -- Verified: Wowhead's title ids are a different space from the
        -- client's (Wowhead title=47 is "Conqueror"; GetTitleName(47) is "the
        -- Explorer"), and its title pages need that numeric id -- the slug
        -- alone 404s. So there is no way to build the exact page from client
        -- data. Prefer the achievement that awards it, which IS exact and
        -- explains how to earn it; otherwise fall back to Wowhead's TITLES
        -- listing filtered by name, which beats a site-wide search.
        local achID = ns.Database and ns.Database.GetTitleSourceAchievement
            and ns.Database:GetTitleSourceAchievement(data.titleID)
        if achID then
            kind, id = "achievement", achID
        elseif data.name then
            query, listing = data.name, "titles"
        end
    elseif data.spellID and (data.category == "Ability" or data.category == "Talent") then
        kind, id = "spell", data.spellID
    elseif data.housingRecordID or data.housingEntryID then
        -- No verified mapping from the client's decor record ids to
        -- Wowhead's decor page ids, so search the name -- it lands on the
        -- decor entry.
        if data.name then query = data.name end
    elseif data.itemID then
        -- Loot, bag items, and anything else carrying a real item id.
        kind, id = "item", data.itemID
    elseif data.isZone or data.isDungeonEntrance then
        -- Wowhead's zone pages key on AreaTable ids, which have no client
        -- mapping from uiMapID, so search the localized name -- it lands on
        -- the zone or instance page. Generic POIs (flight masters, banks)
        -- carry neither flag and stay linkless.
        if data.name then query = data.name end
    end

    if not query and (not kind or not id) then return nil end
    -- Subdomain: an explicit player choice wins; "auto" (default) follows the
    -- client locale. ns.WOWHEAD_LOCALES drives the options dropdown.
    local pref = EasyFind and EasyFind.db and EasyFind.db.wowheadLocale
    local sub
    if pref and pref ~= "auto" then
        sub = pref
    else
        sub = WOWHEAD_LOCALE_SUB[GetLocale and GetLocale()] or "www"
    end
    if listing then
        -- A type-filtered listing (titles): far closer than a site-wide search,
        -- which buries the title among items and quests.
        return "https://" .. sub .. ".wowhead.com/" .. listing
            .. "/name:" .. WowheadSearchEncode(query)
    end
    if query then
        return "https://" .. sub .. ".wowhead.com/search?q=" .. WowheadSearchEncode(query)
    end
    return "https://" .. sub .. ".wowhead.com/" .. kind .. "=" .. id
end

local function ResultItemLink(itemID)
    if not itemID then return nil end
    local link = select(2, C_Item.GetItemInfo(itemID))
    if link then return link end
    -- Not in the client cache yet; ask for it so a re-open resolves.
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return nil
end

local function ResultSpellLink(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellLink then return C_Spell.GetSpellLink(spellID) end
    if GetSpellLink then return GetSpellLink(spellID) end
    return nil
end

-- Battle pet chat link. Prefers an owned pet's real stats (petID GUID); falls
-- back to a species reference (null pet GUID) for search results that aren't
-- collected. Quality index = rarity - 1 (0 poor .. 3 rare), matching the item
-- quality colors WoW tints battlepet links with.
local function ResultBattlePetLink(data)
    if not C_PetJournal then return nil end
    local speciesID = data.speciesID
    local petID = type(data.petID) == "string" and data.petID or nil
    -- Owned pet: the client builds the canonical link itself; a hand-built
    -- one risks drifting from the current format and being rejected.
    if petID and C_PetJournal.GetBattlePetLink then
        local ok, apiLink = pcall(C_PetJournal.GetBattlePetLink, petID)
        if ok and type(apiLink) == "string" and apiLink:find("|H", 1, true) then
            return apiLink
        end
    end
    local level, quality, maxHealth, power, speed, name = 1, 0, 0, 0, 0, nil
    if petID and C_PetJournal.GetPetInfoByPetID then
        local sID, _, lvl, _, _, _, _, petName = C_PetJournal.GetPetInfoByPetID(petID)
        speciesID = speciesID or sID
        level, name = lvl or 1, petName
        if C_PetJournal.GetPetStats then
            local _, mh, pw, sp, rarity = C_PetJournal.GetPetStats(petID)
            maxHealth, power, speed = mh or 0, pw or 0, sp or 0
            quality = (rarity or 1) - 1
        end
    end
    if not speciesID then return nil end
    if not name and C_PetJournal.GetPetInfoBySpeciesID then
        name = C_PetJournal.GetPetInfoBySpeciesID(speciesID)
    end
    if not name then return nil end
    -- Quality color markup: .hex carried the full "|cff..." historically;
    -- newer builds expose only the color object. A missing prefix makes
    -- the whole link parse as plain text, so verify and rebuild.
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = qc and qc.hex
    if (not hex or hex:sub(1, 2) ~= "|c") and qc and qc.color
        and qc.color.GenerateHexColorMarkup then
        hex = qc.color:GenerateHexColorMarkup()
    end
    if not hex or hex:sub(1, 2) ~= "|c" then hex = "|cffffffff" end
    return format("%s|Hbattlepet:%d:%d:%d:%d:%d:%d:0000000000000000|h[%s]|h|r",
        hex, speciesID, level, quality, maxHealth, power, speed, name)
end

-- Build a chat hyperlink (|H...|h) for a search result, or nil for results
-- with no linkable game object (settings, zones, POIs, titles, reputations,
-- gear sets, bosses). Mirrors the type dispatch of ns.GetWowheadLink; only the
-- kinds WoW exposes as chat links produce a string, so the Send-link menu
-- option appears only where there is something real to send.
function ns.GetResultLink(data)
    if not data then return nil end
    if data.appearanceItemID and C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
        local info = C_TransmogCollection.GetSourceInfo(data.appearanceItemID)
        return info and ResultItemLink(info.itemID) or nil
    elseif data.heirloomItemID then
        return ResultItemLink(data.heirloomItemID)
    elseif data.toyItemID then
        return ResultItemLink(data.toyItemID)
    elseif data.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        return ResultSpellLink(select(2, C_MountJournal.GetMountInfoByID(data.mountID)))
    elseif data.speciesID or type(data.petID) == "string" then
        return ResultBattlePetLink(data)
    elseif data.achievementID and data.category == "Achievement" and GetAchievementLink then
        return GetAchievementLink(data.achievementID)
    elseif data.statisticID and data.category == "Statistic" and GetStatistic then
        -- Statistics have no chat hyperlink, so synthesize shareable plain text
        -- "Name: Value" from the already-localized stat value. Not clickable,
        -- but WoW otherwise gives players no way to link a statistic at all.
        local value = GetStatistic(data.statisticID)
        if value and value ~= "" and value ~= "--" then
            return format("%s: %s", data.name or "", value)
        end
        return nil
    elseif data.currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyLink then
        return C_CurrencyInfo.GetCurrencyLink(data.currencyID, 0)
    elseif data.encounterID and data.category == "Boss" then
        -- Adventure Guide (journal) link: type 1 = encounter. Difficulty is
        -- cosmetic for sharing; recipients land on the encounter regardless.
        return format("|cff66bbff|Hjournal:1:%d:%d|h[%s]|h|r",
            data.encounterID, data.difficultyID or 14, data.name or "")
    elseif data.spellID and (data.category == "Ability" or data.category == "Talent") then
        return ResultSpellLink(data.spellID)
    elseif data.housingRecordID and C_HousingDecor and C_HousingDecor.GetDecorHyperlink then
        local ok, link = pcall(C_HousingDecor.GetDecorHyperlink, data.housingRecordID)
        if ok and link and link ~= "" then return link end
        return nil
    elseif data.itemID and data.category == "Loot" then
        -- The journal carries a link per difficulty; prefer the one matching
        -- the selected difficulty over the generic item link, so the shared
        -- link says the same item level the row does.
        local lootLink = ns.Database and ns.Database.GetLootItemLink
            and ns.Database:GetLootItemLink(data)
        return lootLink or ResultItemLink(data.itemID)
    elseif data.itemID then
        return ResultItemLink(data.itemID)
    end
    return nil
end

-- Game-native shift-click linking: with a chat editbox active and Shift
-- held, clicking a result inserts its real hyperlink into the editbox,
-- exactly like shift-clicking an item anywhere else in the game. One owner
-- for every linkable result kind (rides ns.GetResultLink); callers skip
-- their own click action when this returns true.
function ns.TryInsertResultChatLink(data)
    if not data or not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
    if not (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) then return false end
    local link = ns.GetResultLink(data)
    if not link or link == "" then return false end
    return (ChatEdit_InsertLink and ChatEdit_InsertLink(link)) and true or false
end

-- Map pin chat icon: the atlas WoW shows in shared waypoint links.
local MAP_PIN_CHAT_ICON = "|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a"

-- Chat-linkable world map pin at a result's location. WoW encodes worldmap
-- hyperlink coords as the normalized position times 10000, and the recipient
-- clicks the link to open the map there. Built by hand from the result's own
-- coordinates so no real user waypoint is placed on the sender's map. Coords are
-- paired with the map they belong to (POI vs dungeon-entrance fields).
function ns.GetMapPinLink(data)
    if not data then return nil end
    local mapID, x, y
    if data.x and data.y and (data.mapID or data.coordMapID) then
        mapID, x, y = data.mapID or data.coordMapID, data.x, data.y
    elseif data.entranceX and data.entranceY and data.entranceMapID then
        mapID, x, y = data.entranceMapID, data.entranceX, data.entranceY
    end
    if not mapID or not x or not y then return nil end
    local label = data.name or _G["MAP_PIN_HYPERLINK"] or "Map Pin Location"
    return format("|cffffff00|Hworldmap:%d:%d:%d|h[%s %s]|h|r",
        mapID, mfloor(x * 10000 + 0.5), mfloor(y * 10000 + 0.5), MAP_PIN_CHAT_ICON, label)
end

-- Wowhead-supported subdomains for the options dropdown. "auto" follows the
-- client locale; the rest force a specific site. Native labels are universal.
-- Language entries use native endonyms (shown the same on every client); the
-- "auto" entry's display label is localized via L["WOWHEAD_LOCALE_AUTO"].
ns.WOWHEAD_LOCALES = {
    { value = "auto", label = "Auto" },
    { value = "www",  label = "English" },
    { value = "de",   label = "Deutsch" },
    { value = "es",   label = "Español" },
    { value = "fr",   label = "Français" },
    { value = "it",   label = "Italiano" },
    { value = "pt",   label = "Português" },
    { value = "ru",   label = "Русский" },
    { value = "ko",   label = "한국어" },
    { value = "cn",   label = "中文" },
}

-- Resolve a "parent.leaf" dotted db key into its container table (created on
-- demand) and the leaf name; a plain key returns EasyFind.db and the key.
function ns.ResolveDbKey(dbKey)
    local parent, leaf = dbKey:match("^(.-)%.([^%.]+)$")
    if parent then
        EasyFind.db[parent] = EasyFind.db[parent] or {}
        return EasyFind.db[parent], leaf
    end
    return EasyFind.db, dbKey
end

-- Markup parser shared by OptionsPanel home and TutorialWizard slide body.
-- Recognises {L:id}text{/L} for click-link chips and {C:rrggbb}text{/C} for
-- colored spans. Everything outside markers is plain text.
local function HexRGB(hex)
    if not hex or #hex < 6 then return 1, 1, 1 end
    return tonumber(hex:sub(1, 2), 16) / 255,
           tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

function ns.ParseFlowSegments(str)
    -- Pre-pass: convert WoW's native color codes (|cAARRGGBB...|r) into our
    -- {C:RRGGBB}...{/C} markup so the parser handles both formats. Older
    -- locale translations still use |c|r and are common enough that
    -- supporting both forms saves a translator pass per language.
    str = str:gsub("|c%x%x(%x%x%x%x%x%x)(.-)|r", "{C:%1}%2{/C}")

    local segs, i, n = {}, 1, #str
    while i <= n do
        local s, e, body = str:find("{(.-)}", i)
        if not s then
            segs[#segs + 1] = { kind = "text", text = str:sub(i) }
            break
        end
        if s > i then
            segs[#segs + 1] = { kind = "text", text = str:sub(i, s - 1) }
        end
        local tag, arg = body:match("^(%a+):?(.*)$")
        if tag == "L" then
            local cs, ce = str:find("{/L}", e + 1, true)
            segs[#segs + 1] = { kind = "link", text = str:sub(e + 1, (cs or e + 1) - 1), id = arg }
            i = (ce or e) + 1
        elseif tag == "C" then
            local cs, ce = str:find("{/C}", e + 1, true)
            local r, g, b = HexRGB(arg)
            segs[#segs + 1] = { kind = "text", text = str:sub(e + 1, (cs or e + 1) - 1), color = { r, g, b } }
            i = (ce or e) + 1
        else
            segs[#segs + 1] = { kind = "text", text = str:sub(s, e) }
            i = e + 1
        end
    end
    return segs
end

-- Lay out a marked-up string into a width-bound flow of word atoms + link
-- chips. The container's height is computed from the final line count.
-- opts = { width, font, linkDispatch = {[id] = onClickFn}, textColor }
function ns.BuildFlowText(parent, str, opts)
    opts = opts or {}
    local width = opts.width or 400
    local font = opts.font or "GameFontHighlightSmall"
    local linkDispatch = opts.linkDispatch or {}

    local interWeight = opts.interWeight
    local interSize = opts.interSize
    local interFlags = opts.interFlags
    local function styleFS(fs)
        if interWeight and ns.RegisterAddonFont then
            ns.RegisterAddonFont(fs, interWeight, interSize, interFlags)
        end
        -- Flow text is flat body copy; never carry the font object's shadow.
        fs:SetShadowColor(0, 0, 0, 0)
    end

    local container = CreateFrame("Frame", nil, parent)
    container:SetWidth(width)

    local measure = container:CreateFontString(nil, "OVERLAY", font)
    styleFS(measure)
    measure:Hide()
    local _, fontH = measure:GetFont()
    fontH = fontH or 12
    local function widthOf(text)
        measure:SetText(text)
        return measure:GetStringWidth()
    end
    local spaceW = widthOf(" ")
    if spaceW <= 0 then spaceW = 3 end

    local lineH = math.floor(fontH + 5)

    local atoms = {}
    local pendingSpace = false
    local function addText(text, color)
        if text:sub(1, 1) == " " then pendingSpace = true end
        for word in text:gmatch("%S+") do
            atoms[#atoms + 1] = { kind = "word", text = word, w = widthOf(word), spaceBefore = pendingSpace, color = color }
            pendingSpace = true
        end
        pendingSpace = (text:sub(-1) == " ")
    end
    for _, seg in ipairs(ns.ParseFlowSegments(str)) do
        if seg.kind == "text" then
            addText(seg.text, seg.color)
        else
            atoms[#atoms + 1] = { kind = "link", text = seg.text, id = seg.id,
                w = widthOf(seg.text), spaceBefore = pendingSpace }
            pendingSpace = false
        end
    end

    local defaultColor = opts.textColor or ns.TEXT_BODY

    local x, lineTop = 0, 0
    for _, atom in ipairs(atoms) do
        local gap = (atom.spaceBefore and x > 0) and spaceW or 0
        if x > 0 and (x + gap + atom.w) > width then
            lineTop = lineTop - lineH
            x, gap = 0, 0
        end
        local cx = x + gap
        local cy = lineTop - lineH / 2
        if atom.kind == "word" then
            local fs = container:CreateFontString(nil, "OVERLAY", font)
            styleFS(fs)
            fs:SetPoint("LEFT", container, "TOPLEFT", cx, cy)
            fs:SetText(atom.text)
            if atom.color then
                fs:SetTextColor(atom.color[1], atom.color[2], atom.color[3])
            elseif defaultColor then
                fs:SetTextColor(defaultColor[1], defaultColor[2], defaultColor[3])
            end
        elseif atom.kind == "link" then
            local slot = CreateFrame("Frame", nil, container)
            slot:SetSize(atom.w, lineH)
            slot:SetPoint("LEFT", container, "TOPLEFT", cx, cy)
            local chip = CreateFrame("Button", nil, slot)
            chip:SetSize(atom.w, fontH + 4)
            chip:SetPoint("CENTER", slot, "CENTER", 0, 0)
            local glow = chip:CreateTexture(nil, "BACKGROUND")
            glow:SetPoint("CENTER", chip, "CENTER", 0, 0)
            glow:SetSize(atom.w + 20, fontH + 16)
            glow:SetAtlas("collections-newglow")
            if ns.LINK_GLOW_COLOR then
                glow:SetVertexColor(ns.LINK_GLOW_COLOR[1], ns.LINK_GLOW_COLOR[2],
                                    ns.LINK_GLOW_COLOR[3], ns.LINK_GLOW_COLOR[4] or 1)
            end
            glow:SetBlendMode("ADD")
            glow:Hide()
            local glowPulse = ns.CreateBouncePulse(glow, 1.0, 0.5, 0.9)
            local fs = chip:CreateFontString(nil, "OVERLAY", font)
            styleFS(fs)
            fs:SetAllPoints(chip)
            fs:SetJustifyH("CENTER")
            fs:SetText(atom.text)
            -- Marker for the retint walker: link text repaints from the
            -- live link table on every theme flip (the resting color set
            -- here is only the build-time value).
            fs._efLinkText = true
            local LC = ns.LINK_COLOR or { 0.44, 0.84, 1.0 }
            local LH = ns.LINK_HOVER or { 1, 1, 1 }
            fs:SetTextColor(LC[1], LC[2], LC[3])
            chip:SetScript("OnEnter", function()
                glow:Show()
                glowPulse:Play()
                fs:SetTextColor(LH[1], LH[2], LH[3])
            end)
            chip:SetScript("OnLeave", function()
                glowPulse:Stop()
                glow:Hide()
                fs:SetTextColor(LC[1], LC[2], LC[3])
            end)
            local action = linkDispatch[atom.id]
            if type(action) == "table" then
                -- Hover span: styled like a link but not clickable; fires
                -- enter/leave callbacks (e.g. spotlight a spot on an image).
                if action.onEnter then chip:HookScript("OnEnter", action.onEnter) end
                if action.onLeave then chip:HookScript("OnLeave", action.onLeave) end
            elseif action then
                chip:SetScript("OnClick", action)
            end
        end
        x = cx + atom.w
    end

    container:SetHeight(-lineTop + lineH)
    return container
end

-- Single source of truth for "label that auto-fits with ellipsis + tooltip".
--
--   ns.MakeEllipsisLabel(fs, text, opts?)
--   ns.MakeEllipsisLabel:setText(fs, newText)   via fs:SetEllipsisText(...)
--
-- Configures a FontString so it:
--   1. Stays on one line (SetWordWrap/SetNonSpaceWrap/SetMaxLines).
--   2. Auto-truncates with "..." when its text exceeds the available width.
--   3. Re-fits whenever the parent frame is resized.
--   4. Shows a delayed (0.5s) tooltip with the FULL text on hover, only
--      when the label was actually truncated.
--
-- Width is derived from the FontString's anchors (GetLeft/GetRight) so no
-- caller needs to hand-code a maxWidth: set L/R anchors and forget. Pass
-- opts.maxWidth to override explicitly when anchors aren't bounded.
--
-- opts (all optional):
--   maxWidth       number   Override the anchor-derived width.
--   tooltip        bool     Set false to skip the hover tooltip. Default true.
--   tooltipAnchor  string   GameTooltip anchor (default "ANCHOR_TOP").
--   hoverParent    Frame    Parent for the mouse-host overlay (default fs's parent).
--
-- After setup:
--   fs:SetEllipsisText(t)   set the full text and re-fit.
--   fs._fullText            the original (un-truncated) text.
--   fs._isTruncated         true when the label is currently clipped.
local function SetTruncated(fs, truncated)
    fs._isTruncated = truncated
    if fs._hoverHost then fs._hoverHost:EnableMouse(truncated) end
end

function ns.MakeEllipsisLabel(fs, text, opts)
    if not fs then return fs end
    opts = opts or {}
    fs:SetWordWrap(false)
    fs:SetNonSpaceWrap(false)
    fs:SetMaxLines(1)
    fs._fullText = text or ""

    local ANCHOR_X = {
        LEFT = 0, TOPLEFT = 0, BOTTOMLEFT = 0,
        CENTER = 0.5, TOP = 0.5, BOTTOM = 0.5,
        RIGHT = 1, TOPRIGHT = 1, BOTTOMRIGHT = 1,
    }
    local function utf8CharCount(s)
        local count, i, n = 0, 1, #s
        while i <= n do
            count = count + 1
            local b = s:byte(i) or 0
            if b < 0x80 then i = i + 1
            elseif b < 0xE0 then i = i + 2
            elseif b < 0xF0 then i = i + 3
            elseif b < 0xF8 then i = i + 4
            else i = i + 1 end
        end
        return count
    end
    local function utf8SubChars(s, chars)
        if chars <= 0 then return "" end
        local count, i, n = 0, 1, #s
        while i <= n do
            count = count + 1
            local b = s:byte(i) or 0
            local step
            if b < 0x80 then step = 1
            elseif b < 0xE0 then step = 2
            elseif b < 0xF0 then step = 3
            elseif b < 0xF8 then step = 4
            else step = 1 end
            local nextI = i + step
            if count == chars then return s:sub(1, mmin(nextI - 1, n)) end
            i = nextI
        end
        return s
    end
    local function pointUses(point, side)
        return point == side or (point and point:find(side, 1, true) ~= nil)
    end
    local function pointX(relativeTo, relativePoint, x)
        local w = relativeTo and relativeTo.GetWidth and relativeTo:GetWidth()
        local anchor = ANCHOR_X[relativePoint or ""]
        if not w or w <= 0 or not anchor then return nil end
        return w * anchor + (x or 0)
    end
    local function measureFromPoints()
        if not fs.GetNumPoints or not fs.GetPoint then return nil end
        local leftX, rightX, relFrame
        for i = 1, fs:GetNumPoints() do
            local point, relativeTo, relativePoint, x = fs:GetPoint(i)
            relativeTo = relativeTo or fs:GetParent()
            if relativeTo then
                if relFrame and relFrame ~= relativeTo then return nil end
                relFrame = relativeTo
            end
            local xPos = pointX(relativeTo, relativePoint or point, x)
            if xPos then
                if pointUses(point, "LEFT") then
                    leftX = xPos
                elseif pointUses(point, "RIGHT") then
                    rightX = xPos
                end
            end
        end
        if leftX and rightX and rightX > leftX then return rightX - leftX end
        return nil
    end
    local function measureMax()
        if opts.maxWidth then return opts.maxWidth end
        local pointW = measureFromPoints()
        if pointW and pointW > 0 then return pointW end
        local left, right = fs:GetLeft(), fs:GetRight()
        if left and right and right > left then return right - left end
        return fs:GetWidth() or 0
    end
    local function widthOf()
        return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
            or (fs.GetStringWidth and fs:GetStringWidth())
            or 0
    end

    local fit, scheduleFit
    scheduleFit = function()
        if fs._ellipsisFitPending then return end
        if not (C_Timer and C_Timer.After) then return end
        fs._ellipsisFitPending = true
        C_Timer.After(0, function()
            fs._ellipsisFitPending = nil
            if fit then fit(true) end
        end)
    end
    fit = function(fromDeferred)
        local full = fs._fullText or ""
        if full == "" then fs:SetText(""); SetTruncated(fs, false); return end
        local maxW = measureMax()
        if maxW <= 0 then
            -- Layout hasn't computed L/R yet (FontString just created, parent
            -- not shown). Show full text now and try once after layout settles;
            -- OnShow/OnSizeChanged hooks below handle later hidden-tab reveals.
            fs:SetText(full)
            SetTruncated(fs, false)
            if not fromDeferred then scheduleFit() end
            return
        end
        fs:SetText(full)
        if widthOf() <= maxW then SetTruncated(fs, false); return end
        local ELLIPSIS = "..."
        local lo, hi = 0, utf8CharCount(full)
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            fs:SetText(utf8SubChars(full, mid) .. ELLIPSIS)
            if widthOf() <= maxW then lo = mid else hi = mid - 1 end
        end
        fs:SetText(utf8SubChars(full, lo) .. ELLIPSIS)
        SetTruncated(fs, true)
    end
    fit()
    fs._fit = fit
    fs.SetEllipsisText = function(self, newText)
        self._fullText = newText or ""
        fit()
    end

    -- Re-fit when the parent's size changes (covers first-layout-after-show
    -- and any later panel resize). FontStrings don't fire OnSizeChanged
    -- themselves, so the parent is where we listen.
    local parent = opts.hoverParent or fs:GetParent()
    if parent and not fs._sizeHook then
        parent:HookScript("OnSizeChanged", fit)
        parent:HookScript("OnShow", fit)
        fs._sizeHook = true
    end

    if opts.tooltip ~= false and parent and not fs._hoverHost then
        local host = CreateFrame("Frame", nil, parent)
        host:SetAllPoints(fs)
        -- Mouse-enabled only while the text is actually truncated: an
        -- always-on host swallows clicks meant for the control under it.
        host:EnableMouse(fs._isTruncated or false)
        fs._hoverHost = host
        local anchor = opts.tooltipAnchor or "ANCHOR_TOP"
        host:SetScript("OnEnter", function(self)
            if not fs._isTruncated then return end
            if self._timer then self._timer:Cancel() end
            self._timer = C_Timer.NewTimer(0.5, function()
                self._timer = nil
                if not self:IsMouseOver() then return end
                GameTooltip:SetOwner(self, anchor)
                GameTooltip:SetText(fs._fullText or "", 1, 1, 1)
                GameTooltip:Show()
                self._shown = true
            end)
        end)
        host:SetScript("OnLeave", function(self)
            if self._timer then self._timer:Cancel(); self._timer = nil end
            if self._shown then GameTooltip:Hide(); self._shown = nil end
        end)
    end
    return fs
end

-- Back-compat shim: existing callers used the explicit-maxWidth signature.
-- Routes to the unified helper so there's a single implementation to fix.
function ns.AttachEllipsisToFontString(fs, fullText, maxWidth)
    return ns.MakeEllipsisLabel(fs, fullText, { maxWidth = maxWidth })
end

function ns.CreateBouncePulse(region, fromAlpha, toAlpha, duration, smoothing)
    local animGroup = region:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(fromAlpha or 1)
    alpha:SetToAlpha(toAlpha or 0.4)
    alpha:SetDuration(duration or 0.5)
    if smoothing then alpha:SetSmoothing(smoothing) end
    return animGroup, alpha
end

function ns.CreateBounceFloat(region, offsetX, offsetY, duration)
    local animGroup = region:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local trans = animGroup:CreateAnimation("Translation")
    trans:SetOffset(offsetX or 0, offsetY or 0)
    trans:SetDuration(duration or 0.4)
    return animGroup, trans
end

function ns.CreateRoundedRectDivider(frame)
    if frame.combinedDivider then return frame.combinedDivider end
    local d = frame:CreateTexture(nil, "ARTWORK")
    d:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 1)
    d:SetHeight(1)
    d:Hide()
    frame.combinedDivider = d
    return d
end

function ns.SetRoundedRectDivider(frame, yOffset, shown)
    local d = frame.combinedDivider
    if not d then return end
    local cornerSize = (frame.cbBarHeight or frame:GetHeight() or 0) / 2
    d:ClearAllPoints()
    d:SetPoint("TOPLEFT",  frame, "TOPLEFT",  cornerSize * 0.5, -yOffset)
    d:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -cornerSize * 0.5, -yOffset)
    d:SetShown(shown and true or false)
end

function ns.SetSearchBorderShown(frame, shown)
    if not frame.searchBorder then return end
    local sb = frame.searchBorder
    sb.fillLeft:SetShown(shown)
    sb.fillMid:SetShown(shown)
    sb.fillRight:SetShown(shown)
    sb.borderLeft:SetShown(shown)
    sb.borderMid:SetShown(shown)
    sb.borderRight:SetShown(shown)
end

local EasyFindLeafFont = CreateFont("EasyFindLeafFont")
EasyFindLeafFont:CopyFontObject(baseFont)
EasyFindLeafFont:SetFont((baseFont:GetFont()), 10, select(3, baseFont:GetFont()))
ns.LEAF_FONT = "EasyFindLeafFont"

function Utils.DebugPrint(...)
    if EasyFind and EasyFind.db and EasyFind.db.devMode then
        print("|cff33ff99[EasyFind]|r", ...)
    end
end

local BUTTON_TEXT_KEYS = {"label", "Label", "text", "Text", "Name", "name"}
local FRAME_TEXT_KEYS = {"Label", "label", "Text", "text", "Name", "name"}
local frameTextScratch = {}

function Utils.GetButtonText(btn)
    if not btn then return nil end

    for i = 1, #BUTTON_TEXT_KEYS do
        local child = btn[BUTTON_TEXT_KEYS[i]]
        if child and child.GetText then
            local t = child:GetText()
            if t then return t end
        end
    end

    if btn.GetText then
        local t = btn:GetText()
        if t then return t end
    end

    local n = select("#", btn:GetRegions())
    local regions = { btn:GetRegions() }
    for i = 1, n do
        local region = regions[i]
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then return t end
        end
    end

    return nil
end

function Utils.IsFrameOrChildMouseOver(frame)
    if not frame or not frame:IsShown() then return false end
    if frame:IsMouseOver() then return true end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            if child and Utils.IsFrameOrChildMouseOver(child) then
                return true
            end
        end
    end
    return false
end

function Utils.IsFrameVisiblyMouseOver(frame)
    if type(frame) ~= "table" or not frame.IsMouseOver then return false end
    if frame.IsShown and not frame:IsShown() then return false end
    return frame:IsMouseOver()
end

-- Position a cascading flyout to the right of its anchor, flipping to the left
-- when it would run off the right screen edge (standard menu behaviour), and
-- clamping so a deep/tall chain can't end up partly off-screen. Width and scale
-- must already be set on the popup before this is called.
-- Position a cascading flyout beside its anchor and keep it fully on-screen on
-- all four edges. Prefers the right side, flips to the left when the right would
-- overflow, then clamps horizontally and vertically. Works for deeply nested
-- chains by positioning each flyout absolutely against the screen rather than
-- letting a cascade run off the edge. Width/height/scale must be set first.
function Utils.OpenFlyoutBeside(popup, anchorFrame, gap)
    gap = gap or 4
    popup:ClearAllPoints()
    local ui = UIParent
    local s = popup:GetEffectiveScale()
    if not s or s == 0 then s = 1 end
    local screenW = (ui:GetWidth() or 0) * (ui:GetEffectiveScale() or 1)
    local screenH = (ui:GetHeight() or 0) * (ui:GetEffectiveScale() or 1)
    local aScale = anchorFrame:GetEffectiveScale() or 1
    local aLeft = (anchorFrame:GetLeft() or 0) * aScale
    local aRight = (anchorFrame:GetRight() or 0) * aScale
    local aTop = (anchorFrame:GetTop() or 0) * aScale
    local pW = (popup:GetWidth() or 0) * s
    local pH = (popup:GetHeight() or 0) * s
    local gapPx = gap * s

    -- Horizontal: right if it fits, else left if it fits, else the roomier side.
    local x
    if (screenW - aRight) >= (pW + gapPx) then
        x = aRight + gapPx
    elseif (aLeft - gapPx - pW) >= 0 then
        x = aLeft - gapPx - pW
    elseif (screenW - aRight) >= aLeft then
        x = aRight + gapPx
    else
        x = aLeft - gapPx - pW
    end
    if x + pW > screenW then x = screenW - pW end
    if x < 0 then x = 0 end

    -- Vertical: top-align with the anchor, then keep both edges on-screen.
    local top = aTop
    if top - pH < 0 then top = pH end
    if top > screenH then top = screenH end

    popup:SetPoint("TOPLEFT", ui, "BOTTOMLEFT", x / s, top / s)
    if popup.SetClampedToScreen then popup:SetClampedToScreen(true) end
end

-- Position a dropdown list directly below its button, kept fully on-screen:
-- left-aligned with the button (clamped horizontally), dropping down, and
-- flipping above the button if it would run off the bottom. Size/scale first.
function Utils.OpenDropdownBelow(popup, button, gap)
    gap = gap or 2
    popup:ClearAllPoints()
    local ui = UIParent
    local s = popup:GetEffectiveScale()
    if not s or s == 0 then s = 1 end
    local screenW = (ui:GetWidth() or 0) * (ui:GetEffectiveScale() or 1)
    local screenH = (ui:GetHeight() or 0) * (ui:GetEffectiveScale() or 1)
    local bScale = button:GetEffectiveScale() or 1
    local bLeft = (button:GetLeft() or 0) * bScale
    local bTop = (button:GetTop() or 0) * bScale
    local bBottom = (button:GetBottom() or 0) * bScale
    local pW = (popup:GetWidth() or 0) * s
    local pH = (popup:GetHeight() or 0) * s
    local gapPx = gap * s

    local x = bLeft
    if x + pW > screenW then x = screenW - pW end
    if x < 0 then x = 0 end

    -- Drop below; flip above when it would overflow the bottom.
    local top = bBottom - gapPx
    if top - pH < 0 then top = bTop + gapPx + pH end
    if top > screenH then top = screenH end
    if top - pH < 0 then top = pH end

    popup:SetPoint("TOPLEFT", ui, "BOTTOMLEFT", x / s, top / s)
    if popup.SetClampedToScreen then popup:SetClampedToScreen(true) end
end

-- Shared "dropdown button" used by every filter selector: a styled button
-- (background + right arrow + left-aligned label) that toggles a popup list
-- below it (clamped on-screen) and dismisses on outside-click. Eliminates the
-- per-selector duplication of this exact widget.
--   opts: parent, x, y, width, height(27), popup, layout(fn before show),
--         getScale(fn), guardFrames(list), extraGuards(frames kept open)
-- returns button, SetLabelText(text)
function Utils.CreateDropdownButton(opts)
    local btn = CreateFrame("Button", nil, opts.parent)
    btn:SetSize(opts.width, opts.height or 27)
    if opts.x then btn:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", opts.x, opts.y or 0) end
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    Utils.StyleDropdownBg(bg)
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("common-dropdown-a-button-hover")
    arrow:SetSize(22, 22)
    arrow:SetPoint("RIGHT", -10, -1)
    -- The textholder pill art stays dark on every theme, so the arrow
    -- and label keep the light-on-dark scheme; theme tints here read
    -- as dark-on-dark. _efOwnColor opts the label out of the menu text
    -- walk and flips SetFlyoutRowEnabled's enabled color to white.
    arrow:SetVertexColor(0.7, 0.7, 0.7)
    local label = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", 14, 0)
    label:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label._efOwnColor = true
    btn:SetScript("OnEnter", function() arrow:SetVertexColor(1, 1, 1) end)
    btn:SetScript("OnLeave", function() arrow:SetVertexColor(0.7, 0.7, 0.7) end)
    btn._label = label
    btn._chev = arrow

    local popup = opts.popup
    if popup then
        local getScale = opts.getScale or function() return 1.0 end
        btn:SetScript("OnClick", function()
            if popup:IsShown() then popup:Hide(); return end
            if opts.layout then opts.layout() end
            popup:SetScale(getScale())
            Utils.OpenDropdownBelow(popup, btn, 2)
            popup:Show()
        end)
        popup:HookScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        popup:HookScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        popup:HookScript("OnEvent", function(self, event)
            if event ~= "GLOBAL_MOUSE_DOWN" then return end
            if self:IsMouseOver() or btn:IsMouseOver() then return end
            local guards = opts.extraGuards
            if guards then
                for i = 1, #guards do
                    if Utils.IsFrameVisiblyMouseOver(guards[i]) then return end
                end
            end
            self:Hide()
        end)
        if opts.guardFrames then opts.guardFrames[#opts.guardFrames + 1] = popup end
    end

    return btn, function(text) label:SetText(text) end
end

function Utils.AttachHoverPopup(owner, popup, opts)
    if not owner or not popup then return nil end
    opts = opts or {}

    local delay = opts.delay or 0.3
    local extraGuards = opts.extraGuards or {}
    local chainGuards = opts.chainGuards
    local hideTimer

    local function CancelHide()
        if hideTimer then
            hideTimer:Cancel()
            hideTimer = nil
        end
    end

    local function GuardIsMouseOver(guard)
        if type(guard) == "function" then
            return Utils.IsFrameVisiblyMouseOver(guard())
        end
        return Utils.IsFrameVisiblyMouseOver(guard)
    end

    local function ShouldStayOpen()
        if owner.IsMouseOver and owner:IsMouseOver() then return true end
        if popup.IsMouseOver and popup:IsMouseOver() then return true end
        for i = 1, #extraGuards do
            if GuardIsMouseOver(extraGuards[i]) then return true end
        end
        -- Keep the whole open menu chain alive: don't close while the mouse is
        -- over any currently-shown popup in the same menu. This lets the user
        -- move diagonally to a flyout that opened on the opposite side (crossing
        -- the parent menu in between) without it auto-closing.
        if chainGuards then
            local frames = type(chainGuards) == "function" and chainGuards() or chainGuards
            if frames then
                for i = 1, #frames do
                    if Utils.IsFrameVisiblyMouseOver(frames[i]) then return true end
                end
            end
        end
        return opts.keepOpen and opts.keepOpen(owner, popup) or false
    end

    local function HideNow()
        if ShouldStayOpen() then return end
        popup:Hide()
    end

    local function ScheduleHide()
        CancelHide()
        hideTimer = C_Timer.NewTimer(delay, function()
            hideTimer = nil
            HideNow()
        end)
    end

    local function Show()
        CancelHide()
        if opts.onShow then
            opts.onShow(owner, popup)
        else
            popup:Show()
        end
    end

    owner:HookScript("OnEnter", Show)
    owner:HookScript("OnLeave", ScheduleHide)
    popup:HookScript("OnEnter", CancelHide)
    popup:HookScript("OnLeave", ScheduleHide)

    -- Keep the owning menu row highlighted while its flyout is open, so it
    -- stays clear which row opened the submenu even while the cursor is on
    -- the flyout. Registered as a hold so hovering a sibling row transfers
    -- the highlight immediately instead of waiting out the hide grace.
    if owner.LockHighlight then
        local function HoldHighlight()
            owner:LockHighlight()
            local _, hold = FindFlyoutHighlightHold(owner, popup)
            if hold then
                hold.held = true
            else
                tinsert(flyoutHighlightHolds, { owner = owner, popup = popup, held = true })
            end
        end
        popup:HookScript("OnShow", HoldHighlight)
        popup:HookScript("OnEnter", HoldHighlight)
        owner:HookScript("OnEnter", function()
            if popup:IsShown() then HoldHighlight() end
        end)
        popup:HookScript("OnHide", function()
            owner:UnlockHighlight()
            local i = FindFlyoutHighlightHold(owner, popup)
            if i then tremove(flyoutHighlightHolds, i) end
        end)
    end

    return {
        CancelHide = CancelHide,
        HideNow = HideNow,
        ScheduleHide = ScheduleHide,
        Show = Show,
    }
end

function Utils.GetAllFrameText(frame)
    if not frame then return nil end
    wipe(frameTextScratch)
    local texts = frameTextScratch

    for i = 1, #FRAME_TEXT_KEYS do
        local child = frame[FRAME_TEXT_KEYS[i]]
        if child and child.GetText then
            local t = child:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if frame.GetText then
        local t = frame:GetText()
        if t then texts[#texts + 1] = t end
    end

    local n = select("#", frame:GetRegions())
    local regions = { frame:GetRegions() }
    for i = 1, n do
        local region = regions[i]
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if #texts > 0 then
        return tconcat(texts, " ")
    end
    return nil
end

function Utils.SearchFrameTreeFuzzy(frame, searchTextLower, maxDepth)
    maxDepth = maxDepth or 6
    local function search(f, depth)
        if not f or depth > maxDepth then return nil end
        if f:IsShown() then
            local w, h = f:GetSize()
            if w and h and w > 80 and h > 20 and w < 500 then
                local text = Utils.GetAllFrameText(f)
                if text and sfind(slower(text), searchTextLower, 1, true) then
                    if f.Click or (f.IsMouseEnabled and f:IsMouseEnabled()) then
                        return f
                    end
                end
            end
        end
        for i = 1, select("#", f:GetChildren()) do
            local child = select(i, f:GetChildren())
            local result = search(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    return search(frame, 0)
end

function Utils.GetFrameByPath(path)
    if not path then return nil end
    local parts = { strsplit(".", path) }
    local current = _G[parts[1]]
    for i = 2, #parts do
        if current then
            current = current[parts[i]]
        else
            return nil
        end
    end
    return current
end

function Utils.CreateMinimalScrollBar(scrollFrame, parent)
    local THUMB_W = ns.SCROLLBAR_THUMB_W
    local EDGE_INSET = ns.SCROLLBAR_EDGE_INSET
    local VERT_PAD = 4
    local MIN_THUMB_H = 14
    local FADE_HOLD = 0.6
    local FADE_OUT = 0.25
    local WHEEL_STEP = 90
    local SCROLL_LERP = 0.30
    local SCROLL_EPS = 0.5

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(THUMB_W)
    bar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -EDGE_INSET, -VERT_PAD)
    bar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", -EDGE_INSET, VERT_PAD)
    bar:SetFrameStrata(parent:GetFrameStrata())
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)
    bar:EnableMouse(true)

    bar.UpdateBarHeight = function() end

    local track = CreateFrame("Frame", nil, bar)
    track:SetAllPoints(bar)

    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(THUMB_W)
    thumb:EnableMouse(true)

    local capH = THUMB_W * 0.5

    local thumbBody = thumb:CreateTexture(nil, "ARTWORK")
    thumbBody:SetColorTexture(1, 1, 1, 1)
    thumbBody:SetPoint("TOPLEFT", thumb, "TOPLEFT", 0, -capH)
    thumbBody:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", 0, capH)

    local thumbTop = thumb:CreateTexture(nil, "ARTWORK")
    thumbTop:SetColorTexture(1, 1, 1, 1)
    thumbTop:SetSize(THUMB_W, capH)
    thumbTop:SetPoint("TOP", thumb, "TOP", 0, 0)

    local topMask = thumb:CreateMaskTexture()
    topMask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    topMask:SetSize(THUMB_W, THUMB_W)
    topMask:SetPoint("TOP", thumb, "TOP", 0, 0)
    thumbTop:AddMaskTexture(topMask)

    local thumbBot = thumb:CreateTexture(nil, "ARTWORK")
    thumbBot:SetColorTexture(1, 1, 1, 1)
    thumbBot:SetSize(THUMB_W, capH)
    thumbBot:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)

    local botMask = thumb:CreateMaskTexture()
    botMask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    botMask:SetSize(THUMB_W, THUMB_W)
    botMask:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)
    thumbBot:AddMaskTexture(botMask)

    local function SetThumbAlpha(a)
        thumbBody:SetAlpha(a)
        thumbTop:SetAlpha(a)
        thumbBot:SetAlpha(a)
    end
    local function SetThumbNormal() SetThumbAlpha(0.55) end
    local function SetThumbOver()  SetThumbAlpha(0.85) end
    SetThumbNormal()

    thumb:SetScript("OnEnter", SetThumbOver)
    thumb:SetScript("OnLeave", function()
        if not bar.isDragging then SetThumbNormal() end
    end)

    bar:SetAlpha(0)
    bar._lastActivity = 0
    bar._fadingOut = false
    bar._scrollTarget = nil
    bar.isDragging = false
    bar.dragOffset = 0

    function bar:NudgeVisible()
        self._lastActivity = GetTime()
        self._fadingOut = false
        if self:IsShown() then self:SetAlpha(1) end
    end

    local function ScrollByDelta(delta)
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end
        local current = bar._scrollTarget or scrollFrame:GetVerticalScroll()
        bar._scrollTarget = mmax(0, mmin(range, current - delta * WHEEL_STEP))
        bar:NudgeVisible()
    end
    bar.ScrollByDelta = function(_, delta) ScrollByDelta(delta) end

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = true
        bar._scrollTarget = nil
        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        bar.dragOffset = cursorY / scale - self:GetTop()
        SetThumbOver()
        bar:NudgeVisible()
    end)

    thumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = false
        if not self:IsMouseOver() then SetThumbNormal() end
        bar:NudgeVisible()
    end)

    Utils.SafeOnUpdate(bar, function(self)
        if self.isDragging then
            if not IsMouseButtonDown("LeftButton") then
                self.isDragging = false
                if not thumb:IsMouseOver() then SetThumbNormal() end
            else
                local range = scrollFrame:GetVerticalScrollRange()
                if range > 0 then
                    local _, cursorY = GetCursorPosition()
                    local scale = track:GetEffectiveScale()
                    cursorY = cursorY / scale
                    local trackT = track:GetTop()
                    local thumbH = thumb:GetHeight()
                    local travel = track:GetHeight() - thumbH
                    if travel > 0 then
                        local pos = trackT - (cursorY - self.dragOffset)
                        local ratio = mmax(0, mmin(1, pos / travel))
                        scrollFrame:SetVerticalScroll(ratio * range)
                    end
                end
            end
            self:NudgeVisible()
            return
        end

        if self._scrollTarget then
            local cur = scrollFrame:GetVerticalScroll()
            local diff = self._scrollTarget - cur
            if mabs(diff) < SCROLL_EPS then
                scrollFrame:SetVerticalScroll(self._scrollTarget)
                self._scrollTarget = nil
            else
                scrollFrame:SetVerticalScroll(cur + diff * SCROLL_LERP)
            end
            self:NudgeVisible()
        end

        if self:GetAlpha() <= 0 then return end
        local idle = GetTime() - self._lastActivity
        if idle < FADE_HOLD then return end
        if not self._fadingOut then
            self._fadingOut = true
            self._fadeStart = GetTime()
        end
        local t = (GetTime() - self._fadeStart) / FADE_OUT
        if t >= 1 then
            self:SetAlpha(0)
            self._fadingOut = false
        else
            self:SetAlpha(1 - t)
        end
    end)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end

        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        cursorY = cursorY / scale

        local trackT = self:GetTop()
        local trackH = self:GetHeight()
        if trackH <= 0 then return end

        local ratio = (trackT - cursorY) / trackH
        bar._scrollTarget = mmax(0, mmin(range, ratio * range))
        bar:NudgeVisible()
    end)

    bar._contentH = nil
    bar._viewH = nil

    function bar:UpdateThumb(contentH, viewH)
        if contentH then self._contentH = contentH end
        if viewH then self._viewH = viewH end
        contentH = contentH or self._contentH
        viewH = viewH or self._viewH or scrollFrame:GetHeight()
        local range = contentH and (contentH - viewH) or scrollFrame:GetVerticalScrollRange()
        if not range or range <= 0 then
            thumb:Hide()
            return
        end

        local trackH = track:GetHeight()
        if trackH <= 0 then
            thumb:Hide()
            return
        end

        contentH = contentH or (viewH + range)
        local thumbH = mmax(MIN_THUMB_H, trackH * (viewH / contentH))
        thumb:SetHeight(thumbH)

        local travel = trackH - thumbH
        local scrollPos = scrollFrame:GetVerticalScroll()
        local ratio = mmax(0, mmin(1, (range > 0) and (scrollPos / range) or 0))

        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(ratio * travel))
        thumb:Show()
    end

    scrollFrame:SetScript("OnVerticalScroll", function()
        bar:UpdateThumb()
        bar:NudgeVisible()
    end)

    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)

    bar:SetScript("OnShow", function(self)
        self:SetAlpha(0)
        self._lastActivity = 0
        self._fadingOut = false
        self._scrollTarget = nil
        Utils.SafeAfter(0, function()
            if self:IsShown() then self:UpdateThumb() end
        end)
    end)

    bar:Hide()
    return bar
end

function Utils.ScrollBoxScrollTo(scrollBox, matchFn, fallbackFraction)
    if not scrollBox then return end

    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if dataProvider then
        local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
        if finder then
            local scrollData = finder(dataProvider, matchFn)
            if scrollData then
                local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
                scrollBox:ScrollToElementData(scrollData, alignCenter)
                return
            end
        end
    end

    if fallbackFraction and scrollBox.SetScrollPercentage then
        scrollBox:SetScrollPercentage(fallbackFraction)
    end
end

function Utils.ScrollBoxFindButton(scrollBox, matchFn)
    if not scrollBox or not scrollBox.EnumerateFrames then return nil end
    for _, btn in scrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and matchFn(btn) then
            return btn
        end
    end
    return nil
end

-- Pure data predicate for abilities that live only in the spellbook
-- (passives, unlearned ranks): they never cast, their activation opens
-- the spellbook. Owned here so Shared-layer classification (SecureOpeners)
-- does not reach into Search-layer modules; Icons:IsSpellbookOnlyAbility
-- delegates to this.
function Utils.IsSpellbookOnlyAbility(data)
    return data and data.category == "Ability" and data.spellID and data.isSpellbookOnly
end

-- True when a guide cannot start in combat: its first clickable step
-- targets a PROTECTED frame. Capability check via IsProtected, never a
-- category list; guides whose targets are unprotected run in combat like
-- anything else. Deliberately SILENT: blocked-in-combat actions do
-- nothing, no chat notice.
function Utils.GuideBlockedInCombat(guideData)
    if not InCombatLockdown() then return false end
    local steps = guideData and guideData.steps
    local first = steps and steps[1]
    local target = first and first.buttonFrame
    if not target then return false end
    local frame = (Utils.GetFrameByPath and Utils.GetFrameByPath(target)) or _G[target]
    if frame and frame.IsProtected and frame:IsProtected() then
        return true
    end
    return false
end

function Utils.ClickButton(btn, mouseButton)
    if not btn then return false end
    -- Combat capability check, not category guesses: clicking a PROTECTED
    -- button from insecure code in combat is an ADDON_ACTION_BLOCKED error,
    -- so refuse only those; everything unprotected proceeds normally.
    if InCombatLockdown() and btn.IsProtected and btn:IsProtected() then
        Utils.DebugPrint("ClickButton refused: protected button in combat")
        return false
    end
    mouseButton = mouseButton or "LeftButton"
    if btn.Click then
        local ok, err = xpcall(btn.Click, ErrorHandler, btn, mouseButton)
        if ok then return true end
        Utils.DebugPrint("Button click failed: " .. tostring(err))
        return false
    end
    local hasScript, onClick = pcall(btn.GetScript, btn, "OnClick")
    if hasScript and onClick then
        -- Fallback skips PreClick/PostClick and the secure click path.
        local ok, err = xpcall(onClick, ErrorHandler, btn, mouseButton, false)
        if ok then return true end
        Utils.DebugPrint("Button OnClick failed: " .. tostring(err))
    end
    return false
end

function Utils.CreateClearButton(parent, globalName)
    local btn = CreateFrame("Button", globalName, parent)
    btn:SetSize(ns.CLEAR_BTN_SIZE, ns.CLEAR_BTN_SIZE)
    btn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    btn:EnableMouse(true)
    btn:Hide()

    local normal = btn:CreateTexture(nil, "ARTWORK")
    normal:SetAllPoints()
    normal:SetTexture(CLEAR_BTN_TEX)
    btn:SetNormalTexture(normal)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture(CLEAR_BTN_TEX)
    highlight:SetVertexColor(1.3, 1.3, 1.3, 1)
    highlight:SetBlendMode("ADD")
    btn:SetHighlightTexture(highlight)

    return btn
end

-- Pool cycles through members so each open uses a freshly-laid-out menu.
-- Avoids state-leak bugs where the second open of a cached menu inherits
-- stale flags from the first close (backdrop tile, alpha after click, etc).
local cursorMenuPool = {}
local cursorMenuCounter = 0

local function FindFreeMenu(globalName)
    local pool = cursorMenuPool[globalName]
    if not pool then return nil end
    for i = 1, #pool do
        local menu = pool[i]
        if menu and not menu:IsShown() then return menu end
    end
    return nil
end

local function HideOtherMenus(globalName, except)
    local pool = cursorMenuPool[globalName]
    if not pool then return end
    for i = 1, #pool do
        local menu = pool[i]
        if menu and menu ~= except and menu:IsShown() then menu:Hide() end
    end
end

function Utils.HideCursorMenus(globalName)
    local closedAny = false
    local function hidePool(pool)
        if not pool then return end
        for i = 1, #pool do
            local menu = pool[i]
            if menu and menu:IsShown() then
                menu:Hide()
                closedAny = true
            end
        end
    end
    if globalName then
        hidePool(cursorMenuPool[globalName])
    else
        for _, pool in pairs(cursorMenuPool) do
            hidePool(pool)
        end
    end
    return closedAny
end

-- Ground truth for "is the cursor on this menu": the focus stack that actually
-- receives clicks, walked up so a row (a descendant) counts as the menu. More
-- reliable than IsMouseOver rectangle math for a just-shown flyout.
local function MouseFocusOwnedBy(target)
    local foci = GetMouseFoci and GetMouseFoci()
    if foci then
        for i = 1, #foci do
            local f = foci[i]
            while f do
                if f == target then return true end
                f = f.GetParent and f:GetParent()
            end
        end
    elseif GetMouseFocus then
        local f = GetMouseFocus()
        while f do
            if f == target then return true end
            f = f.GetParent and f:GetParent()
        end
    end
    return false
end

local function CursorMenuHasMouse(self)
    if self:IsMouseOver() then return true end
    if self.rows then
        for i = 1, #self.rows do
            if Utils.IsFrameVisiblyMouseOver(self.rows[i]) then
                return true
            end
        end
    end
    if MouseFocusOwnedBy(self) then return true end
    return false
end

-- True if the cursor is over any active cursor menu or its open flyout chain.
-- The results window's outside-click closer consults this: a context-menu
-- submenu is a separate pooled frame (parented to UIParent, not a child of the
-- pin popup), so a click on it must not be misread as a click outside the panel.
function Utils.IsCursorMenuMouseOver()
    for _, pool in pairs(cursorMenuPool) do
        for i = 1, #pool do
            local menu = pool[i]
            if menu and menu:IsShown() and CursorMenuHasMouse(menu) then
                return true
            end
        end
    end
    return false
end

local SUBMENU_GLOBAL = "EasyFindCursorSubmenu"

-- True if the mouse is over any menu in this cascade: the root plus every open
-- descendant flyout. Walked from the root so a parent never closes while its
-- submenu is hovered, and a submenu never closes while its owning row (up in the
-- parent) is hovered. Both directions resolve to the same chain.
local function CursorMenuChainHasMouse(menu)
    local root = menu
    while root._parentMenu do root = root._parentMenu end
    local node = root
    while node do
        if node:IsShown() and CursorMenuHasMouse(node) then return true end
        node = node._openSubmenu
    end
    return false
end

local function CursorMenuCloseSubmenu(menu)
    local child = menu._openSubmenu
    -- Result-row pattern: the owning row was explicitly LOCKED when its child
    -- opened; unlock it here, the one place submenus close from.
    if menu._openSubmenuRow and menu._openSubmenuRow.SetMenuHighlightFocused then
        menu._openSubmenuRow:SetMenuHighlightFocused(false)
    end
    menu._openSubmenu = nil
    menu._openSubmenuRow = nil
    if child then child:Hide() end
end

-- Reaching a row (by hover or keyboard): a row carrying its own submenu opens it
-- beside itself; reaching any other row closes whatever submenu was open. This
-- is the same hover-cascade every other flyout in the addon uses, via
-- OpenFlyoutBeside for placement.
local function CursorMenuRowEntered(menu, row)
    if menu._openSubmenuRow and menu._openSubmenuRow ~= row then
        CursorMenuCloseSubmenu(menu)
    end
    if not row._submenuRows or row.disabled then return end
    if menu._openSubmenu and menu._openSubmenu:IsShown() and menu._openSubmenuRow == row then return end
    -- A function-typed submenu spec is a live rows provider: called on every
    -- open AND stored so keepOpen toggles can reshow with fresh check marks.
    local spec = row._submenuRows
    local provider
    if type(spec) == "function" then
        provider = spec
        spec = spec()
    end
    -- Pool per DEPTH: ShowCursorMenu opens by hiding other menus of the
    -- same name, so one shared submenu name meant a third-level flyout hid
    -- its own parent and got the parent's freed frame back as itself
    -- (circular anchor). A depth suffix displaces only same-level siblings.
    local depth = (menu._submenuDepth or 0) + 1
    local child = Utils.ShowCursorMenu(SUBMENU_GLOBAL .. depth, spec, {
        scale = menu:GetScale(),
        strata = menu:GetFrameStrata(),
        level = menu:GetFrameLevel() + 20,
        anchorBeside = row,
        parentMenu = menu,
        labelFontObject = menu._labelFontObject,
        iconSide = menu._iconSide,
        rowsProvider = provider,
    })
    child._submenuDepth = depth
    menu._openSubmenu = child
    menu._openSubmenuRow = row
    -- Result-row pattern: LOCK the owning row for the child's whole lifetime
    -- (explicit lock at open, explicit unlock at close -- never derived
    -- per-frame from mutable cascade links).
    if row.SetMenuHighlightFocused then row:SetMenuHighlightFocused(true) end
    -- Sit above any sibling at this strata so the flyout's rows, not an
    -- overlapping frame, receive the click.
    if child and child.Raise then child:Raise() end
end

local function CursorMenuIsSelectableRow(row)
    return row and row:IsShown() and not row.isSeparator and not row.disabled
end

local function CursorMenuPaintKeyboardSelection(self)
    if not self.rows then return end
    for i = 1, #self.rows do
        local row = self.rows[i]
        if row and row.UnlockHighlight then row:UnlockHighlight() end
        if row and row.keyboardOverlay then
            row.keyboardOverlay:SetShown(self.keyboardIndex == i)
        end
    end
    local row = self.rows[self.keyboardIndex or 0]
    if row and row.LockHighlight then row:LockHighlight() end
end

local function CursorMenuSetKeyboardIndex(self, index)
    if not self.rows then return false end
    if not index then
        self.keyboardIndex = nil
        CursorMenuPaintKeyboardSelection(self)
        return false
    end
    if index < 1 then index = #self.rows end
    if index > #self.rows then index = 1 end
    local start = index
    repeat
        local row = self.rows[index]
        if CursorMenuIsSelectableRow(row) then
            self.keyboardIndex = index
            CursorMenuPaintKeyboardSelection(self)
            return true
        end
        index = index + 1
        if index > #self.rows then index = 1 end
    until index == start
    self.keyboardIndex = nil
    CursorMenuPaintKeyboardSelection(self)
    return false
end

local function CursorMenuMoveKeyboardIndex(self, delta)
    if not self.rows then return false end
    local index = (self.keyboardIndex or (delta > 0 and 0 or #self.rows + 1)) + delta
    if index < 1 then index = #self.rows end
    if index > #self.rows then index = 1 end
    return CursorMenuSetKeyboardIndex(self, index)
end

local function CursorMenuActivateKeyboardIndex(self)
    local row = self.rows and self.rows[self.keyboardIndex or 0]
    if not CursorMenuIsSelectableRow(row) then return false end
    if row._submenuRows then
        CursorMenuRowEntered(self, row)
        if self._openSubmenu and self._openSubmenu.FocusKeyboard then
            self._openSubmenu:FocusKeyboard(1)
        end
        return true
    end
    local onClick = row.onClick
    local root = self
    while root._parentMenu do root = root._parentMenu end
    if self._parentMenu then
        if onClick then onClick() end
        root:Hide()
    else
        root:Hide()
        if onClick then onClick() end
    end
    return true
end

local function CursorMenuFocusKeyboard(self, index)
    self.keyboardMode = true
    Utils.SafeCallMethod(self, "EnableKeyboard", true)
    Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    if self.Raise then self:Raise() end
    CursorMenuSetKeyboardIndex(self, index or 1)
end

local function CursorMenuOnShow(self)
    ns.ApplyMenuOpacity(self)
    self._showedAt = GetTime()
    self._outsideSince = nil
    self._hasEntered = false
    Utils.SafeCallMethod(self, "EnableKeyboard", true)
    Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    -- Only the root of a cascade watches for click-outside. If a submenu also
    -- registered GLOBAL_MOUSE_DOWN, the two menus raced to close on the same
    -- mouse-down and hid the clicked submenu row before its handler could run,
    -- so the action never fired. One owner, like the single-menu case.
    if not self._parentMenu then
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        self:RegisterEvent("GLOBAL_MOUSE_UP")
    end
    if self.keyboardMode then
        CursorMenuFocusKeyboard(self, self.keyboardIndex or 1)
    else
        CursorMenuSetKeyboardIndex(self, nil)
    end
end

local function CursorMenuOnHide(self)
    self._outsideSince = nil
    self._hasEntered = false
    CursorMenuSetKeyboardIndex(self, nil)
    Utils.SafeCallMethod(self, "EnableKeyboard", false)
    self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    self:UnregisterEvent("GLOBAL_MOUSE_UP")
    if self.rows then
        for i = 1, #self.rows do
            local row = self.rows[i]
            if row then row:Hide() end
        end
    end
    if self._openSubmenu then
        local child = self._openSubmenu
        self._openSubmenu = nil
        self._openSubmenuRow = nil
        child:Hide()
    end
    if self._parentMenu then
        if self._parentMenu._openSubmenu == self then
            local ownerRow = self._parentMenu._openSubmenuRow
            if ownerRow and ownerRow.SetMenuHighlightFocused then
                ownerRow:SetMenuHighlightFocused(false)
            end
            self._parentMenu._openSubmenu = nil
            self._parentMenu._openSubmenuRow = nil
        end
        self._parentMenu = nil
    end
    local onHide = self.onHide
    self.onHide = nil
    if onHide then onHide(self) end
end

-- Row highlight state is DRIVEN, not event-hooked: every frame the root walks
-- its cascade and lights each row that has the mouse OR owns the open submenu
-- (the parent row stays engaged while its child is open). Driving from one
-- place survives anything that stomps per-row script hooks and needs no
-- enter/leave bookkeeping.
local function CursorMenuDriveRowHighlights(menu)
    local rows = menu.rows
    if not rows then return end
    for i = 1, #rows do
        local row = rows[i]
        if row and row:IsShown() and row._efMenuRowHighlightInstalled and not row.isSeparator then
            -- The explicit lock (_efWashFocused, result-row pattern: set at
            -- child open, cleared at child close) is authoritative; hover and
            -- the cascade link are additional signals, never overrides.
            local engaged = row._efWashFocused or row:IsMouseOver() or menu._openSubmenuRow == row
            if row._efWashActive then
                Utils.UpdateRoundedRowWash(row, engaged)
            else
                -- Black theme keeps the ADD glow: hover shows it natively, the
                -- cascade-owner state needs an explicit lock.
                local holds = row._efWashFocused or menu._openSubmenuRow == row
                if holds and not row._efCascadeLocked then
                    if row.LockHighlight then row:LockHighlight() end
                elseif not holds and row._efCascadeLocked then
                    if row.UnlockHighlight then row:UnlockHighlight() end
                end
                row._efCascadeLocked = holds or nil
            end
        end
    end
end

local function CursorMenuOnUpdate(self)
    -- Submenus never drive anything; the root owns the whole cascade, so
    -- there is exactly one owner of the hover/close decisions.
    if self._parentMenu then return end
    local node = self
    while node do
        if node:IsShown() then CursorMenuDriveRowHighlights(node) end
        node = node._openSubmenu
    end
    -- stayOpen menus close only on click-outside (handled in OnEvent), never on
    -- mouse-leave, matching the search bar's filter menu.
    if self.stayOpen then return end
    if CursorMenuChainHasMouse(self) then
        self._outsideSince = nil
        self._hasEntered = true
        return
    end
    if not self._hasEntered then return end
    local now = GetTime()
    if not self._outsideSince then
        self._outsideSince = now
        return
    end
    if now - self._outsideSince > (self.outsideDelay or 0.3) then
        self:Hide()
    end
end

local function CursorMenuOnEvent(self, event)
    if event ~= "GLOBAL_MOUSE_DOWN" and event ~= "GLOBAL_MOUSE_UP" then return end
    if self._showedAt and (GetTime() - self._showedAt) < (self.clickGrace or 0.05) then return end
    -- Clicks on the owning toggle button are its OnClick's to handle:
    -- hiding here on mouse-down would make the mouse-up click instantly
    -- reopen the menu it just closed.
    if self.toggleOwner and Utils.IsFrameVisiblyMouseOver(self.toggleOwner) then return end
    if not CursorMenuChainHasMouse(self) then self:Hide() end
end

local function CursorMenuOnKeyDown(self, key)
    local navKey = key and key:upper() or key
    if navKey == "ESCAPE" then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        self:Hide()
    elseif navKey == "DOWN" or (IsAltKeyDown and IsAltKeyDown() and navKey == "J") then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        CursorMenuMoveKeyboardIndex(self, 1)
    elseif navKey == "UP" or (IsAltKeyDown and IsAltKeyDown() and navKey == "K") then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        CursorMenuMoveKeyboardIndex(self, -1)
    elseif navKey == "ENTER" then
        -- SPACE is never an activation key in EasyFind; it always
        -- propagates (jumping must work with a menu open). ENTER
        -- activates the keyboard-selected row and otherwise propagates
        -- (mouse-opened menus have no selection).
        if CursorMenuIsSelectableRow(self.rows and self.rows[self.keyboardIndex or 0]) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            CursorMenuActivateKeyboardIndex(self)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    elseif navKey == "TAB" then
        -- Tab descends into the focused row's submenu (Send link etc.);
        -- on rows without one it steps the selection like DOWN (Shift+Tab
        -- steps back), so the whole menu is walkable from the keyboard.
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        local row = self.rows and self.rows[self.keyboardIndex or 0]
        if CursorMenuIsSelectableRow(row) and row._submenuRows then
            CursorMenuActivateKeyboardIndex(self)
        else
            CursorMenuMoveKeyboardIndex(self, (IsShiftKeyDown and IsShiftKeyDown()) and -1 or 1)
        end
    elseif navKey == "RIGHT" then
        -- RIGHT descends like Tab but only on submenu rows; anywhere else
        -- it propagates so movement keys keep working with a menu open.
        local row = self.rows and self.rows[self.keyboardIndex or 0]
        if CursorMenuIsSelectableRow(row) and row._submenuRows then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            CursorMenuActivateKeyboardIndex(self)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    elseif navKey == "LEFT" then
        -- LEFT backs out of a submenu to its parent; the root menu lets
        -- the key through.
        if self._parentMenu then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            self:Hide()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    else
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
    end
end

local function CreateCursorMenu(globalName)
    cursorMenuCounter = cursorMenuCounter + 1
    local frameName = globalName .. "_" .. cursorMenuCounter
    local menu = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    menu:EnableMouse(true)
    menu:SetClampedToScreen(true)
    menu.rows = {}
    ns.StyleMenuPanel(menu)

    menu.SetKeyboardIndex = CursorMenuSetKeyboardIndex
    menu.MoveKeyboardIndex = CursorMenuMoveKeyboardIndex
    menu.ActivateKeyboardIndex = CursorMenuActivateKeyboardIndex
    menu.FocusKeyboard = CursorMenuFocusKeyboard
    menu.RefreshMenuRowHighlights = function(self)
        Utils.RefreshMenuRowHighlights(self, self.rows)
    end
    menu:SetScript("OnShow", CursorMenuOnShow)
    menu:SetScript("OnHide", CursorMenuOnHide)
    Utils.SafeOnUpdate(menu, CursorMenuOnUpdate)
    menu:SetScript("OnEvent", CursorMenuOnEvent)
    menu:SetScript("OnKeyDown", CursorMenuOnKeyDown)

    cursorMenuPool[globalName] = cursorMenuPool[globalName] or {}
    local pool = cursorMenuPool[globalName]
    pool[#pool + 1] = menu
    if not _G[globalName] then _G[globalName] = menu end
    return menu
end

-- Cursor-menu rows sit this far in from the menu on each side. The
-- fit-to-content width measures labels in ROW space, so it has to add this
-- back to reach menu space -- they must stay in step.
local MENU_ROW_INSET = 4

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}

    -- A keepOpen reshow replaces the pooled child frame: HideOtherMenus fires
    -- the old child's OnHide, which wipes the parent's _openSubmenuRow -- and
    -- with it the parent row's stays-lit-while-child-open state. Capture the
    -- row link BEFORE the teardown so it can be restored onto the new frame.
    local priorSubmenuRow = opts.parentMenu and opts.parentMenu._openSubmenuRow

    HideOtherMenus(globalName, nil)

    local menu = FindFreeMenu(globalName) or CreateCursorMenu(globalName)

    local menuScale = opts.scale or 1
    menu:SetScale(menuScale)
    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    -- NEVER the 10000 ceiling: children spawn at parent+1 and the engine CLAMPS
    -- levels to 10000, so a ceiling menu's rows collapse onto the menu's own
    -- level -- and at equal level the parent wins hover focus, deadening every
    -- row (hover-driven submenu rows worst of all). Keep headroom for rows (+1)
    -- and cascade flyouts (+20).
    local menuLevel = math.min(opts.level or 9000, 9900)
    menu:SetFrameLevel(menuLevel)
    -- Grazing the menu edge shouldn't dismiss it; shares the tooltip
    -- hover delay so all hover timing feels like one system.
    menu.outsideDelay = opts.outsideDelay or ns.TOOLTIP_HOVER_DELAY
    menu.clickGrace = opts.clickGrace or 0.05
    menu.stayOpen = opts.stayOpen and true or false
    menu.keyboardMode = opts.keyboardMode and true or false
    menu.keyboardIndex = nil
    menu.onHide = opts.onHide
    menu.toggleOwner = opts.toggleOwner
    menu._parentMenu = opts.parentMenu
    -- Menus wear their CONTEXT's font: search menus track the results leaf
    -- font (default), other hosts (notes) pass their chrome font object so
    -- menu text matches the text around it instead of the search setting.
    menu._labelFontObject = opts.labelFontObject
    -- Filter-style menus put their check marks on the LEFT like the main
    -- filter dropdown; context menus keep glyphs on the right.
    menu._iconSide = opts.iconSide or "right"
    menu._rowsProvider = opts.rowsProvider
    menu._lastName, menu._lastOpts = globalName, opts
    -- A reshow (keepOpen refresh) can hand this cascade slot to a different
    -- pooled frame; the parent's links must follow it or the chain-hover test
    -- loses the child (auto-close) and the parent row loses its engaged state.
    if opts.parentMenu then
        opts.parentMenu._openSubmenu = menu
        if priorSubmenuRow and not opts.parentMenu._openSubmenuRow then
            opts.parentMenu._openSubmenuRow = priorSubmenuRow
            -- The old child's OnHide unlocked this row; re-lock it -- its
            -- child is still open, just on a replacement frame.
            if priorSubmenuRow.SetMenuHighlightFocused then
                priorSubmenuRow:SetMenuHighlightFocused(true)
            end
        end
    end

    local rowH = opts.rowHeight or 22
    local width = opts.width or 96
    local shown = 0
    local lastRow
    -- The left check column only exists when this menu actually HAS check
    -- marks; menus of plain rows (e.g. submenu headers) keep the normal
    -- text inset instead of an empty reserved column.
    local leftIcons = false
    if menu._iconSide == "left" then
        for i = 1, #rows do
            local d = rows[i]
            if d and d.icon then leftIcons = true break end
        end
    end
    for i = 1, #rows do
        local def = rows[i]
        if def then
            shown = shown + 1
            local row = menu.rows[shown]
            if not row then
                row = CreateFrame("Button", nil, menu)
                row:EnableMouse(true)
                row:SetHeight(rowH)
                Utils.InstallMenuRowHighlight(row)
                -- Hovering a row opens its submenu beside it (or closes a
                -- sibling's); the current row's spec lives in row._submenuRows.
                row:HookScript("OnEnter", function(self) CursorMenuRowEntered(menu, self) end)
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                -- Populate owns this color (gold family per theme).
                row.label._efOwnColor = true
                row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.icon = row:CreateTexture(nil, "OVERLAY")
                row.icon:SetSize(14, 14)
                row.icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.sep = row:CreateTexture(nil, "ARTWORK")
                local sepTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                local sepColor = sepTheme and sepTheme.separatorColor
                if sepColor then
                    row.sep:SetColorTexture(sepColor[1], sepColor[2], sepColor[3], sepColor[4] or 0.35)
                else
                    row.sep:SetColorTexture(1, 1, 1, 0.18)
                end
                row.sep:SetHeight(1)
                row.sep:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.sep:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                row.sep:Hide()
                row.keyboardOverlay = row:CreateTexture(nil, "OVERLAY")
                row.keyboardOverlay:SetAllPoints()
                row.keyboardOverlay:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                row.keyboardOverlay:SetBlendMode("ADD")
                row.keyboardOverlay:SetAlpha(0.85)
                row.keyboardOverlay:Hide()
                menu.rows[shown] = row
            end
            local isSep = def.isSeparator
            local sepH = 7
            -- Pooled rows shed any stale cascade lock on repopulate; a fresh
            -- open has no child yet (RowEntered re-locks when one opens).
            if row._efWashFocused and row.SetMenuHighlightFocused then
                row:SetMenuHighlightFocused(false)
            end
            -- Rows sit TWO above the menu body (re-asserted every open; pooled
            -- rows keep stale levels otherwise): the hover pill lives at row-1
            -- and needs its own level BETWEEN menu fill and row content --
            -- at the menu's own level it z-fights the fill and vanishes
            -- (HARDFOUGHT_BATTLES: equal level = the parent wins).
            row:SetFrameLevel(menuLevel + 2)
            row:SetHeight(isSep and sepH or rowH)
            if isSep then
                if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                row.isSeparator = true
                row.disabled = nil
                row.onClick = nil
                row._submenuRows = nil
                row.label:SetText("")
                row.icon:Hide()
                if row.iconOverlay then row.iconOverlay:Hide() end
                if row.chevron then row.chevron:Hide() end
                row.sep:Show()
                row:EnableMouse(false)
                local hl = row:GetHighlightTexture()
                if hl then hl:SetAlpha(0) end
                row:SetScript("OnMouseDown", nil)
                row:SetScript("OnClick", nil)
            else
                row.isSeparator = nil
                row.disabled = def.disabled and true or nil
                -- Menus wear the same scaled leaf font as result rows
                -- (honors the Font setting; plain GameFontNormal read as
                -- a different typeface next to the results) -- unless the
                -- host passed its own font object for context consistency.
                if menu._labelFontObject then
                    -- Apply the host font ABSOLUTELY (object + raw path/size):
                    -- parent and submenu share one object, so their text can
                    -- never differ in size from each other or the host UI.
                    row.label:SetFontObject(menu._labelFontObject)
                    local ff, fs, ffl = menu._labelFontObject:GetFont()
                    if ff then row.label:SetFont(ff, fs, ffl or "") end
                    row.label._efSFBase = nil
                elseif ns.Results and ns.Results.SetScaledFont then
                    -- Menus wear the same font as result-row TITLES (pathFont),
                    -- not the smaller leaf style -- menu text must never read
                    -- smaller than the rows it acts on.
                    local pathTheme = ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                    ns.Results:SetScaledFont(row.label,
                        (pathTheme and pathTheme.pathFont) or ns.LEAF_FONT)
                end
                row.label:SetText(def.text or "")
                -- Menu rows repopulate on every open, so the gold label
                -- can resolve per theme here (hue-dark accent on light
                -- fills); submenus share this same builder.
                local menuTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                -- Menu labels match the theme's body/leaf text (the same family as
                -- the row icons), not the old gold; light themes take the darker
                -- path-hover so text stays legible on the light fill.
                local labelColor
                if row.disabled then
                    labelColor = ns.TEXT_DIM
                elseif menuTheme and menuTheme.lightTheme then
                    labelColor = menuTheme.pathColorHover or menuTheme.leafColor
                else
                    labelColor = (menuTheme and menuTheme.leafColor) or ns.GOLD_COLOR
                end
                row.label:SetTextColor(Utils.RGB(labelColor, 1))
                -- Own the shadow here too: these _efOwnColor labels are
                -- skipped by RetintMenuText, and pooled rows skip
                -- SetScaledFont's shadow re-apply when font/size are
                -- unchanged, so a row first built on a dark theme keeps its
                -- shadow after a switch to light unless it's set per open.
                row.label:SetShadowColor(0, 0, 0, (menuTheme and menuTheme.lightTheme) and 0 or 1)
                -- Anchoring follows the menu's icon side; pooled rows serve
                -- menus of either style, so re-anchor per open. The label is
                -- ALWAYS right-constrained: an unconstrained label renders
                -- over the icon slot when the menu is narrow.
                -- Submenu rows wear the shared flyout chevron on the right,
                -- exactly like the filter dropdown's cascade rows -- one
                -- arrow style across every menu surface.
                if def.submenu and not row.chevron then
                    row.chevron = row:CreateTexture(nil, "OVERLAY")
                    row.chevron:SetSize(12, 12)
                    row.chevron:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                end
                if row.chevron then
                    if def.submenu then
                        Utils.SetChevronTexture(row.chevron)
                        row.chevron:Show()
                    else
                        row.chevron:Hide()
                    end
                end
                row.label:ClearAllPoints()
                row.icon:ClearAllPoints()
                local rightInset = def.submenu and -22 or -8
                if leftIcons then
                    row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
                    row.label:SetPoint("LEFT", row, "LEFT", 28, 0)
                    row.label:SetPoint("RIGHT", row, "RIGHT", rightInset, 0)
                else
                    -- The chevron owns the right edge on submenu rows; a
                    -- right-side icon steps inward beside it.
                    row.icon:SetPoint("RIGHT", row, "RIGHT", def.submenu and -26 or -8, 0)
                    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                    local labelRight = rightInset
                    if def.icon then labelRight = def.submenu and -44 or -26 end
                    row.label:SetPoint("RIGHT", row, "RIGHT", labelRight, 0)
                end
                row.label:SetJustifyH("LEFT")
                row.label:SetWordWrap(false)
                if def.icon then
                    -- SetIconTexture handles plain paths, atlas: strings,
                    -- and {file, coords} tables (cropped square icons).
                    Utils.SetIconTexture(row.icon, def.icon)
                    row.icon:SetRotation(def.iconRotation or 0)
                    -- Monochrome chrome glyphs (Guide eye, Wowhead link)
                    -- flip polarity with the theme; content icons never
                    -- tint. Rows are pooled, so the reset matters.
                    local glyph = def.chromeIcon and menuTheme and menuTheme.lightTheme
                        and menuTheme.chromeGlyph
                    if glyph then
                        row.icon:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
                    else
                        row.icon:SetVertexColor(1, 1, 1, 1)
                    end
                    row.icon:SetDesaturated(row.disabled and true or false)
                    row.icon:SetAlpha(row.disabled and 0.5 or 1)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                -- The pin rows show the same composite glyph the pinned
                -- result rows wear (Utils.CreatePinGlyph), in the icon slot.
                if def.pinGlyph then
                    if not row.pinGlyph then
                        row.pinGlyph = Utils.CreatePinGlyph(row, 12)
                        row.pinGlyph:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                    end
                    row.pinGlyph:SetAlpha(row.disabled and 0.5 or 1)
                    row.pinGlyph:Show()
                elseif row.pinGlyph then
                    row.pinGlyph:Hide()
                end
                if def.iconOverlay then
                    if not row.iconOverlay then
                        -- Corner badge, not a full cover: the base glyph
                        -- must stay identifiable underneath.
                        row.iconOverlay = row:CreateTexture(nil, "OVERLAY", nil, 3)
                        row.iconOverlay:SetSize(9, 9)
                    end
                    row.iconOverlay:ClearAllPoints()
                    row.iconOverlay:SetPoint("BOTTOMRIGHT",
                        def.pinGlyph and row.pinGlyph or row.icon, "BOTTOMRIGHT", 3, -3)
                    row.iconOverlay:SetTexture(def.iconOverlay)
                    row.iconOverlay:SetAlpha(row.disabled and 0.5 or 1)
                    row.iconOverlay:Show()
                elseif row.iconOverlay then
                    row.iconOverlay:Hide()
                end
                row.sep:Hide()
                row._submenuRows = def.submenu
                if row.disabled then
                    if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                    row:EnableMouse(false)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(0) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", nil)
                elseif def.submenu then
                    -- A submenu row opens its flyout (it also opens on hover);
                    -- it never closes the menu or fires a leaf action.
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", function(self, button)
                        if button ~= "LeftButton" then return end
                        CursorMenuRowEntered(menu, self)
                    end)
                else
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    local onClick = def.onClick
                    local keepOpen = def.keepOpen
                    row.onClick = onClick
                    row:SetScript("OnMouseDown", function(_, button)
                        if button ~= "LeftButton" then return end
                        -- Toggle rows (keepOpen) NEVER close the menu -- the
                        -- user is mid-multi-select; instead the menu reshows
                        -- with fresh rows so its check marks track the state.
                        if keepOpen then
                            if onClick then onClick() end
                            local fresh = menu._rowsProvider and menu._rowsProvider()
                            if fresh then
                                Utils.ShowCursorMenu(menu._lastName, fresh, menu._lastOpts)
                            end
                            return
                        end
                        local root = menu
                        while root._parentMenu do root = root._parentMenu end
                        -- In a submenu, fire the action BEFORE tearing down: the
                        -- root's hide-cascade hides this row's own menu, and
                        -- hiding the frame whose handler is mid-run swallowed the
                        -- click so the action never ran. Top-level menus keep the
                        -- long-standing hide-then-act order (no cascade hides the
                        -- running row there).
                        if menu._parentMenu then
                            if onClick then onClick() end
                            root:Hide()
                        else
                            root:Hide()
                            if onClick then onClick() end
                        end
                    end)
                end
                row:SetScript("OnClick", nil)
            end
            row:ClearAllPoints()
            if shown == 1 then
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", MENU_ROW_INSET, -4)
                row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -MENU_ROW_INSET, -4)
            else
                row:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", lastRow, "BOTTOMRIGHT", 0, 0)
            end
            row:Show()
            lastRow = row
        end
    end
    for i = shown + 1, #menu.rows do
        local row = menu.rows[i]
        if row then
            row:Hide()
            row.isSeparator = nil
            row.disabled = nil
            row.onClick = nil
            row._submenuRows = nil
            if row.keyboardOverlay then row.keyboardOverlay:Hide() end
            row:SetScript("OnClick", nil)
            row:SetScript("OnMouseDown", nil)
        end
    end

    -- Fit-to-content width. Labels are measured through a hidden, never-
    -- constrained FontString: a pooled row's own label is already right-
    -- anchored into the menu's PREVIOUS width, so on clients where
    -- GetUnboundedStringWidth is unavailable its width reads back clipped
    -- and a long row stays ellipsized forever.
    if not menu.measure then
        menu.measure = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        menu.measure:Hide()
    end
    local needed = width
    local totalH = 0
    for i = 1, shown do
        local row = menu.rows[i]
        if row then
            totalH = totalH + (row:GetHeight() or rowH)
            if row.label and not row.isSeparator then
                local lblW
                if row.label.GetUnboundedStringWidth then
                    lblW = row.label:GetUnboundedStringWidth() or 0
                else
                    local ff, fs, ffl = row.label:GetFont()
                    if ff then menu.measure:SetFont(ff, fs, ffl or "") end
                    menu.measure:SetText(row.label:GetText() or "")
                    lblW = menu.measure:GetStringWidth() or 0
                end
                local leftPad = leftIcons and 28 or 8
                local rightPad = 8
                if row.chevron and row.chevron:IsShown() then
                    rightPad = (row.icon:IsShown() and not leftIcons) and 44 or 22
                elseif row.icon:IsShown() and not leftIcons then
                    rightPad = 26
                end
                -- Rows are inset MENU_ROW_INSET on BOTH sides of the menu, so
                -- a width measured in row space is that much short in menu
                -- space. Without it the widest row -- the one that sets the
                -- width -- always ellipsized by exactly the inset.
                local rowW = leftPad + lblW + rightPad + MENU_ROW_INSET * 2
                if rowW > needed then needed = rowW end
            end
        end
    end
    menu:SetSize(needed, totalH + 8)
    menu:ClearAllPoints()
    if opts.anchorBeside then
        -- Cascade flyout: sit beside the owning row, flipping/clamping on-screen,
        -- exactly like the filter sub-flyouts.
        Utils.OpenFlyoutBeside(menu, opts.anchorBeside, 4)
    elseif opts.anchorFrame then
        menu:SetPoint(opts.point or "TOPLEFT", opts.anchorFrame, opts.relativePoint or "TOPRIGHT",
            opts.offsetX or 4, opts.offsetY or 0)
    else
        local scale = UIParent:GetEffectiveScale() * menuScale
        local x, y = GetCursorPosition()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    end
    menu:Show()
    -- Uniform per-row pills carry no geometry dependency, so this can run
    -- synchronously again (the old positional corner masks needed resolved
    -- rects and got a deferred pass; that whole system is gone).
    if menu.RefreshMenuRowHighlights then menu:RefreshMenuRowHighlights() end
    if menu.keyboardMode and menu.FocusKeyboard then
        menu:FocusKeyboard(1)
        local focusMenu = menu
        Utils.SafeAfter(0, function()
            if focusMenu and focusMenu:IsShown() and focusMenu.keyboardMode and focusMenu.FocusKeyboard then
                focusMenu:FocusKeyboard(1)
            end
        end)
    end
    return menu
end

local function MenuRowLess(a, b)
    return slower(a.text or "") < slower(b.text or "")
end

function Utils.ShowPinMenu(globalName, isPinned, onPin, onGuide, onAddAlias, opts, extra)
    local rows = {}
    if onAddAlias then
        rows[#rows + 1] = { text = L["CTX_ADD_ALIAS"], onClick = onAddAlias }
    end
    if extra and extra.onAddShortkey then
        rows[#rows + 1] = {
            text = extra.hasShortkey and L["CTX_EDIT_SHORTKEY"] or L["CTX_ADD_SHORTKEY"],
            onClick = extra.onAddShortkey,
        }
    end
    -- The exact glyph the pinned result rows wear (Utils.CreatePinGlyph),
    -- so the menu action and the row marker read as one concept; Unpin
    -- adds the red X corner badge.
    rows[#rows + 1] = {
        text = isPinned and (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_UNPIN"] or "Unpin") or (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_PIN"] or "Pin"),
        pinGlyph = true,
        iconOverlay = isPinned and "Interface\\RaidFrame\\ReadyCheck-NotReady" or nil,
        onClick = onPin,
    }
    if onGuide then
        rows[#rows + 1] = { text = L["CTX_GUIDE"], icon = ns.EYE_ICON_TEX, chromeIcon = true, onClick = onGuide }
    end
    if extra and extra.onWowhead then
        -- Our own chain-link glyph (textures/link.tga), the same custom
        -- treatment as Guide's eye and Pin's diamond.
        rows[#rows + 1] = { text = L["CTX_WOWHEAD"], icon = ns.LINK_ICON_TEX, chromeIcon = true, onClick = extra.onWowhead }
    end
    if extra and extra.sendLink then
        -- Hover-cascade flyout of chat channels, opened beside the row like
        -- every other flyout; the arrow glyph marks it as a submenu.
        local sendRows = ns.BuildSendLinkRows(extra.sendLink.link, extra.sendLink.name)
        if sendRows then
            -- No bespoke arrow: rows with a submenu get the shared chevron
            -- from the menu module; adding one here doubled the arrows.
            rows[#rows + 1] = {
                text = L["CTX_SEND_LINK"],
                submenu = sendRows,
            }
        end
    end
    if extra and extra.addNoteRows then
        rows[#rows + 1] = {
            text = L["CTX_ADD_NOTE"],
            submenu = extra.addNoteRows,
        }
    end
    if extra and extra.onBlacklist then
        rows[#rows + 1] = { text = L["CTX_BLACKLIST"], onClick = extra.onBlacklist }
    end

    local extras = {}
    if extra and extra.onTrack then
        extras[#extras + 1] = {
            text = extra.isTracked and L["CTX_UNTRACK"] or L["CTX_TRACK"],
            onClick = extra.onTrack,
        }
    end
    if extra and extra.onToggleBackpack then
        extras[#extras + 1] = {
            text = extra.isOnBackpack and L["CTX_REMOVE_FROM_BACKPACK"] or L["CTX_SHOW_ON_BACKPACK"],
            onClick = extra.onToggleBackpack,
        }
    end
    if extra and extra.onTransfer then
        extras[#extras + 1] = { text = _G["TRANSFER"] or "Transfer", onClick = extra.onTransfer }
    end
    if extra and extra.onToggleWatchedFaction then
        extras[#extras + 1] = {
            text = extra.isWatchedFaction and L["CTX_HIDE_XP_BAR"] or L["CTX_SHOW_XP_BAR"],
            onClick = extra.onToggleWatchedFaction,
        }
    end
    if extra and extra.onSummon then
        extras[#extras + 1] = { text = _G["SUMMON"] or "Summon", onClick = extra.onSummon }
    end
    if extra and extra.onRename then
        extras[#extras + 1] = { text = _G["PET_RENAME"] or "Rename", onClick = extra.onRename }
    end
    if extra and extra.onToggleFavorite then
        extras[#extras + 1] = {
            text = extra.isFavorite and (_G["BATTLE_PET_UNFAVORITE"] or "Remove Favorite") or (_G["BATTLE_PET_FAVORITE"] or "Set Favorite"),
            onClick = extra.onToggleFavorite,
        }
    end
    if extra and extra.onCageOrRelease then
        extras[#extras + 1] = {
            text = extra.isCageable and (_G["BATTLE_PET_PUT_IN_CAGE"] or "Put In Cage") or (_G["BATTLE_PET_RELEASE"] or "Release"),
            onClick = extra.onCageOrRelease,
        }
    end
    if extra and extra.onDestroyItem then
        extras[#extras + 1] = { text = L["CTX_DESTROY_ITEM"], onClick = extra.onDestroyItem }
    end
    -- Alphabetical within each section (per-locale, since labels are
    -- localized); the separator keeps standard and extra actions apart.
    tsort(rows, MenuRowLess)
    tsort(extras, MenuRowLess)
    if #extras > 0 then
        rows[#rows + 1] = { isSeparator = true }
        for i = 1, #extras do rows[#rows + 1] = extras[i] end
    end

    if extra and extra.disabled then
        for i = 1, #rows do
            if not rows[i].isSeparator then rows[i].disabled = true end
        end
    end

    return Utils.ShowCursorMenu(globalName, rows, opts)
end

-- Chat channels the "Send link" flyout offers, in display order. `enabled`
-- gates a channel to when it can actually be used (in a party/instance group,
-- raid, or guild); ungated channels are always available. The label is the
-- localized Blizzard global for the channel name.
local SEND_LINK_CHANNELS = {
    { chan = "SAY" },
    { chan = "YELL" },
    { chan = "PARTY",         enabled = function() return IsInGroup() end },
    { chan = "INSTANCE_CHAT", enabled = function() return IsInGroup(LE_PARTY_CATEGORY_INSTANCE or 2) end },
    { chan = "RAID",          enabled = function() return IsInRaid() end },
    { chan = "GUILD",         enabled = function() return IsInGuild() end },
}

-- Whisper target for the current unit target, realm-qualified when cross-realm;
-- nil unless a player is targeted.
local function SendLinkTargetName()
    if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
    local name, realm = UnitName("target")
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Build the "Send link" flyout rows for a result's chat link: public/group
-- channels, a whisper to the current target, a whisper by typed name, and a
-- copy box. WoW has no silent set-clipboard API, so the copy box is the
-- standard Ctrl+C path. Returned as a submenu spec for the context menu.
function ns.BuildSendLinkRows(link, name)
    if not link then return nil end
    local rows = {}
    for i = 1, #SEND_LINK_CHANNELS do
        local c = SEND_LINK_CHANNELS[i]
        local on = (not c.enabled) or c.enabled()
        local chan = c.chan
        rows[#rows + 1] = {
            text = _G[chan] or chan,
            disabled = (not on) or nil,
            onClick = on and function() SendChatMessage(link, chan) end or nil,
        }
    end
    local targetName = SendLinkTargetName()
    rows[#rows + 1] = {
        text = _G["TARGET"] or "Target",
        disabled = (not targetName) or nil,
        onClick = targetName and function() SendChatMessage(link, "WHISPER", nil, targetName) end or nil,
    }
    rows[#rows + 1] = {
        text = L["CTX_SEND_LINK_NAME"],
        onClick = function()
            ns.ShowThemedDialog({
                text = L["CTX_SEND_LINK_NAME_PROMPT"],
                messageColor = ns.GOLD_COLOR,
                hasEditBox = true,
                maxLetters = 48,
                acceptText = _G["SEND_LABEL"] or _G["OKAY"],
                onAccept = function(val)
                    val = val and strtrim(val) or ""
                    if val ~= "" then SendChatMessage(link, "WHISPER", nil, val) end
                end,
            })
        end,
    }
    rows[#rows + 1] = { isSeparator = true }
    rows[#rows + 1] = {
        text = L["CTX_SEND_LINK_CLIPBOARD"],
        onClick = function()
            if link:find("|H", 1, true) then
                -- Real hyperlink: the OS clipboard can't carry it (the
                -- client strips |H escapes from pasted chat by design), so
                -- show the rendered link to shift-click into a chat message.
                ns.ShowChatLinkBox(link, L["CTX_SEND_LINK_SHIFTCLICK_HINT"]:format(name or ""))
            else
                -- Plain-text payloads (statistics) keep the Ctrl-C box.
                ns.ShowCopyBox(link, L["CTX_SEND_LINK_CLIPBOARD_HINT"]:format(name or ""))
            end
        end,
    }
    return rows
end

-- Build the "Add to Note" flyout rows: a New Note action plus each existing
-- note (most-recent first) the link appends to. Needs the optional EasyNotes
-- plugin (loaded on demand); returns nil when it is absent so the menu row is
-- hidden. Both actions open the editor to the note as confirmation.
function ns.BuildAddNoteRows(link, name)
    if not link then return nil end
    local Notes = ns.Notes
    if not (Notes and Notes.CreateNote) and C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Notes")
        Notes = ns.Notes
    end
    if not (Notes and Notes.CreateNote and Notes.ListNotes and Notes.AppendToNote) then
        return nil
    end
    local rows = {}
    rows[#rows + 1] = {
        text = L["CTX_NEW_NOTE"],
        onClick = function()
            local id = Notes.CreateNote({ title = name, body = link })
            if id and Notes.OpenNote then Notes.OpenNote(id) end
        end,
    }
    local notes = Notes.ListNotes()
    if notes and #notes > 0 then
        rows[#rows + 1] = { isSeparator = true }
        for i = 1, math.min(#notes, 20) do
            local noteID = notes[i].id
            rows[#rows + 1] = {
                text = notes[i].title,
                onClick = function()
                    Notes.AppendToNote(noteID, link)
                    if Notes.OpenNote then Notes.OpenNote(noteID) end
                end,
            }
        end
    end
    return rows
end

-- The pin marker: bronze diamond with an additive gold core, composited
-- from a high-res (64px) diamond source so it stays crisp at any scale.
-- ONE construction, used by the pinned result rows and the context menu
-- pin row, so the glyph reads identically everywhere.
function Utils.CreatePinGlyph(parent, size)
    local DIAMOND_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3"
    local glyph = CreateFrame("Frame", nil, parent)
    glyph:SetSize(size, size)
    local outer = glyph:CreateTexture(nil, "OVERLAY", nil, 1)
    outer:SetTexture(DIAMOND_TEX)
    outer:SetDesaturated(true)
    outer:SetVertexColor(0.78, 0.50, 0.22)  -- bronze
    outer:SetAllPoints(glyph)
    local core = glyph:CreateTexture(nil, "OVERLAY", nil, 2)
    core:SetTexture(DIAMOND_TEX)
    core:SetDesaturated(true)
    core:SetVertexColor(ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3], 0.9)
    core:SetBlendMode("ADD")
    core:SetPoint("CENTER")
    core:SetSize(size * 0.5, size * 0.5)
    return glyph
end

function Utils.SetIconTexture(textureObj, icon, fallback)
    if not textureObj then return end
    textureObj:SetTexture(nil)
    if textureObj.SetAtlas then textureObj:SetAtlas(nil) end
    textureObj:SetTexCoord(0, 1, 0, 1)
    if type(icon) == "table" and icon.file then
        textureObj:SetTexture(icon.file)
        if icon.coords then textureObj:SetTexCoord(unpack(icon.coords)) end
    elseif type(icon) == "string" and ssub(icon, 1, 6) == "atlas:" then
        textureObj:SetAtlas(ssub(icon, 7), false)
    elseif icon then
        textureObj:SetTexture(icon)
    else
        textureObj:SetTexture(fallback or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

-- Apply the Blizzard dropdown-button background to a texture. The atlas has a
-- fixed vertical structure (top bevel + center + bottom bevel); stretching it
-- to an arbitrary button height squashes the bevels and reads as "too short".
-- Pin it to its native height and stretch only horizontally, matching the
-- in-game dropdown buttons (e.g. the Encounter Journal loot filter).
function Utils.StyleDropdownBg(bg)
    if not bg then return end
    bg:SetAtlas("common-dropdown-textholder")
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-dropdown-textholder")
    local height = (info and info.height) or 41
    bg:ClearAllPoints()
    bg:SetPoint("LEFT", 0, 0)
    bg:SetPoint("RIGHT", 0, 0)
    bg:SetHeight(height)
end

local INTER_REGULAR  = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Regular.ttf"
local INTER_SEMIBOLD = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-SemiBold.ttf"
local INTER_BOLD     = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Bold.ttf"

-- "Default" = the client's own UI font (varies by locale); the rest map to
-- font files below. Arial Narrow ships inside the WoW client, so it costs
-- nothing to offer.
ns.FONT_CHOICES = { "Default", "Inter", "Lato", "Poppins", "Arial Narrow" }

local ADDON_FONTS_DIR = "Interface\\AddOns\\EasyFind\\Fonts\\"
local ADDON_FONT_FILES = {
    ["Inter"] = {
        regular  = INTER_REGULAR,
        semibold = INTER_SEMIBOLD,
        bold     = INTER_BOLD,
    },
    ["Lato"] = {
        regular  = ADDON_FONTS_DIR .. "Lato-Regular.ttf",
        semibold = ADDON_FONTS_DIR .. "Lato-Bold.ttf",
        bold     = ADDON_FONTS_DIR .. "Lato-Bold.ttf",
    },
    ["Poppins"] = {
        regular  = ADDON_FONTS_DIR .. "Poppins-Regular.ttf",
        semibold = ADDON_FONTS_DIR .. "Poppins-SemiBold.ttf",
        bold     = ADDON_FONTS_DIR .. "Poppins-Bold.ttf",
    },
    ["Arial Narrow"] = {
        regular = "Fonts\\ARIALN.TTF",
    },
}

local fontRegistry = {}

local function GetFontChoice()
    return (EasyFind and EasyFind.db and EasyFind.db.font) or "Default"
end

local function ApplyFontTo(fs)
    if not fs or not fs.SetFont then return end
    local baseline = fs._addonFontBaseline
    if not baseline then return end
    local size  = fs._addonFontSizeOverride or baseline.size or 12
    local flags = fs._addonFontFlags or baseline.flags or ""
    local files = ADDON_FONT_FILES[GetFontChoice()]
    if files then
        local w = fs._addonFontWeight
        if fs:SetFont(files[w] or files.regular, size, flags) then return end
        -- Font file not loadable (e.g. added after the client launched, which
        -- only scans addon files at startup): keep the baseline font rather
        -- than leaving the text blank.
    end
    fs:SetFont(baseline.path, baseline.size, baseline.flags or "")
end

-- Pre-rasterize every bundled font once at login. A FontString whose
-- font file has not been rasterized this session renders NOTHING until
-- something re-sets its text; the multi-MB families are slow enough to
-- rasterize that the font dropdown's self-previewing rows intermittently
-- came up blank. The warm frame sits offscreen at alpha 0 (hidden
-- FontStrings do not rasterize).
local fontWarmFrame
function ns.WarmAddonFonts()
    if fontWarmFrame then return end
    fontWarmFrame = CreateFrame("Frame", nil, UIParent)
    fontWarmFrame:SetSize(1, 1)
    fontWarmFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -80, -80)
    fontWarmFrame:SetAlpha(0)
    local warmed = {}
    for _, files in pairs(ADDON_FONT_FILES) do
        for _, path in pairs(files) do
            if not warmed[path] then
                warmed[path] = true
                local fs = fontWarmFrame:CreateFontString(nil, "ARTWORK")
                fs:SetPoint("BOTTOMLEFT")
                fs:SetFont(path, 12, "")
                fs:SetText("Ag")
            end
        end
    end
end

-- Resolve the font path a piece of UI text should use: the chosen font's
-- file for the weight, else the caller's own (Blizzard) path. Lets
-- per-render font sizing (ScaleFont) honor the font choice without joining
-- the FontString registry.
function ns.GetAddonFontPath(weight, fallback)
    local files = ADDON_FONT_FILES[GetFontChoice()]
    if not files then return fallback end
    return files[weight] or files.regular
end

-- The file a named choice would use (regardless of the current choice),
-- for previewing dropdown rows in their own font. nil for "Default".
function ns.GetFontChoicePath(name)
    local files = ADDON_FONT_FILES[name]
    return files and files.regular or nil
end

-- Recursively register every FontString under a frame with the addon font
-- system, so the Inter choice applies to whole surfaces (options panel,
-- search chrome, menus). Idempotent per FontString.
function ns.RegisterAddonFontsIn(frame)
    if not frame then return end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                ns.RegisterAddonFont(region)
            end
        end
    end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            ns.RegisterAddonFontsIn((select(i, frame:GetChildren())))
        end
    end
end

function ns.RegisterAddonFont(fs, weight, sizeOverride, flags)
    if not fs or not fs.GetFont or not fs.SetFont then return end
    -- Font-preview rows each render in their OWN font on purpose; they must
    -- never be driven by the current global choice, or selecting a font would
    -- overwrite (and blank) the other choices' preview text.
    if fs._efFontPreview then return end
    if not fs._addonFontBaseline then
        local p, sz, fl = fs:GetFont()
        fs._addonFontBaseline = { path = p, size = sz, flags = fl }
        fontRegistry[#fontRegistry + 1] = fs
    end
    fs._addonFontWeight       = weight
    fs._addonFontSizeOverride = sizeOverride
    fs._addonFontFlags        = flags
    ApplyFontTo(fs)
end

function ns.RefreshAddonFont()
    for i = 1, #fontRegistry do
        ApplyFontTo(fontRegistry[i])
    end
end
