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

local function AutocompleteOnMouseDown(state, button)
    if button ~= "LeftButton" then return end
    state.mouseAcceptCandidate = AutocompleteHas(state) and state.currentCandidate or nil
    state.mouseAcceptTypedLen = state.mouseAcceptCandidate and #state.typedText or nil
end

local function AutocompleteOnMouseUp(state, box, button)
    if button ~= "LeftButton" or not state.mouseAcceptCandidate then return end
    local candidate = state.mouseAcceptCandidate
    local typedLen = state.mouseAcceptTypedLen or #state.typedText
    state.mouseAcceptCandidate = nil
    state.mouseAcceptTypedLen = nil
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
        ns.SetRoundedRectFill(frame, unpack(ns.SEARCH_WINDOW_FILL_COLOR))
    end
    if not frame._efMenuHighlightRefreshHooked then
        frame._efMenuHighlightRefreshHooked = true
        frame:HookScript("OnShow", function(self)
            if Utils.RefreshMenuRowHighlights then
                Utils.RefreshMenuRowHighlights(self)
            end
        end)
    end
    ns.SetRoundedRectBarHeight(frame, ns.SEARCHBAR_HEIGHT)
    ns.SetRoundedRectBorderBgAlpha(frame, ns.GetSearchWindowAlpha())
end

function ns.ApplyMenuOpacity(frame)
    if not frame then return end
    if frame.combinedBorder then
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
ns.COMMANDS_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\commands-icon"
ns.RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-off"
ns.RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-on"
ns.FLYOUT_ARROW_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\flyout-arrow"
ns.SEARCH_WINDOW_FILL_COLOR = {0.052, 0.052, 0.060}
ns.TEXT_PRIMARY = {1.00, 0.97, 0.86}
ns.TEXT_BODY = {0.78, 0.78, 0.80}
ns.TEXT_DIM = {0.55, 0.55, 0.58}
-- Cool blue-gray fills so interactive buttons read as such against the
-- neutral near-black panels (color as affordance, not brightness).
ns.BTN_FILL_NORMAL = {0.160, 0.190, 0.250}
ns.BTN_FILL_HOVER = {0.220, 0.270, 0.340}
ns.BTN_FILL_PRESSED = {0.120, 0.140, 0.190}
ns.BTN_FILL_DISABLED = {0.080, 0.090, 0.110}
ns.LINK_COLOR = {0.44, 0.84, 1.0}
ns.LINK_HOVER = {0.72, 0.94, 1.0}
ns.LINK_GLOW_COLOR = {0.3, 0.85, 1.0, 0.7}
ns.SEARCHBAR_HEIGHT = 30
ns.SEARCHBAR_FILL = 0.55
ns.SEARCHBAR_ICON_SCALE = 0.9
ns.DEFAULT_FONT_SIZE = 0.9
ns.CLEAR_BTN_SIZE = 12
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

function ns.SetRoundedRectBorderBgAlpha(frame, alpha)
    if not frame.combinedBorder then return end
    for _, t in pairs(frame.combinedBorder.fill) do t:SetAlpha(alpha) end
end

function ns.SetRoundedRectBorderFillColor(frame, r, g, b, a)
    if not frame.combinedBorder then return end
    for _, t in pairs(frame.combinedBorder.fill) do
        t:SetVertexColor(r, g, b, a or 1)
    end
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
    return GlossLerp(0.022, 0.20, t), GlossLerp(0.022, 0.20, t), GlossLerp(0.030, 0.22, t)
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
    ns.SetRoundedRectBarHeight(frame, 16)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
    ns.SetRoundedRectFill(frame, 0.04, 0.04, 0.05, 1, true)
    ns.SetRoundedRectBorderBgAlpha(frame, alpha or 1)
    ns.ApplyWizardPanelGloss(frame)
    if not frame._efWizardGlossHooked then
        frame._efWizardGlossHooked = true
        frame:HookScript("OnSizeChanged", ns.ApplyWizardPanelGloss)
    end
end

local MENU_ROW_HIGHLIGHT_TEX = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local MENU_ROW_EDGE_TOLERANCE = 16
local MENU_ROW_MASK_TEX = {
    middle = "Interface\\AddOns\\EasyFind\\textures\\MenuHighlightMaskFull",
    top = "Interface\\AddOns\\EasyFind\\textures\\MenuHighlightMaskTop",
    bottom = "Interface\\AddOns\\EasyFind\\textures\\MenuHighlightMaskBottom",
    single = "Interface\\AddOns\\EasyFind\\textures\\MenuHighlightMaskSingle",
}

local function ApplyMenuHighlightMask(row, tex, role)
    if not (row and tex and row.CreateMaskTexture and tex.AddMaskTexture) then return end
    local maskKey = tex == row.keyboardOverlay and "_efMenuKeyboardHighlightMask" or "_efMenuHighlightMask"
    local mask = row[maskKey]
    if not mask then
        mask = row:CreateMaskTexture()
        row[maskKey] = mask
        tex:AddMaskTexture(mask)
    end
    mask:ClearAllPoints()
    mask:SetAllPoints(tex)
    mask:SetTexture(MENU_ROW_MASK_TEX[role] or MENU_ROW_MASK_TEX.middle,
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
end

function Utils.SetMenuRowHighlightPosition(row, position)
    if not (row and row._efMenuRowHighlightInstalled) then return end
    row._efMenuHighlightPosition = position or "middle"
    ApplyMenuHighlightMask(row, row:GetHighlightTexture(), row._efMenuHighlightPosition)
    if row.keyboardOverlay then
        ApplyMenuHighlightMask(row, row.keyboardOverlay, row._efMenuHighlightPosition)
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
        tsort(rows, function(a, b)
            local at, bt = a:GetTop() or 0, b:GetTop() or 0
            if at ~= bt then return at > bt end
            return (a:GetLeft() or 0) < (b:GetLeft() or 0)
        end)
    end

    local parentTop, parentBottom = parent:GetTop(), parent:GetBottom()
    for i = 1, #rows do
        local row = rows[i]
        local topEdge = i == 1
        local bottomEdge = i == #rows
        local rowTop, rowBottom = row:GetTop(), row:GetBottom()
        if parentTop and rowTop then
            topEdge = topEdge and ((parentTop - rowTop) <= MENU_ROW_EDGE_TOLERANCE)
        end
        if parentBottom and rowBottom then
            bottomEdge = bottomEdge and ((rowBottom - parentBottom) <= MENU_ROW_EDGE_TOLERANCE)
        end

        local role = "middle"
        if topEdge and bottomEdge then
            role = "single"
        elseif topEdge then
            role = "top"
        elseif bottomEdge then
            role = "bottom"
        end
        Utils.SetMenuRowHighlightPosition(row, role)
    end
end

-- Rows whose highlight is locked because their flyout is open. A hold lives
-- for the popup's whole shown lifetime; `held` tracks whether the lock is
-- currently applied. Hovering a SIBLING row releases the lock immediately
-- (the highlight transfers while the flyout lingers through its hide grace),
-- and re-entering the owner, its popup, or any row inside the popup restores
-- it. The popup's OnHide remains the final release.
local flyoutHighlightHolds = {}

local function FindFlyoutHighlightHold(owner, popup)
    for i = 1, #flyoutHighlightHolds do
        local hold = flyoutHighlightHolds[i]
        if hold.owner == owner and hold.popup == popup then return i, hold end
    end
    return nil
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
                if hold.owner.LockHighlight then hold.owner:LockHighlight() end
            end
        elseif hold.held and hold.owner:GetParent() == rowParent then
            hold.held = false
            if hold.owner.UnlockHighlight then hold.owner:UnlockHighlight() end
        end
    end
end

-- Gray out and disable a flyout/popup option row when the filter above it
-- is unchecked, mirroring the default UI (effectiveEnabled = parent and own).
-- Rows opt into extra dimming via _label/_icon/_chev/_dimTex fields.
function Utils.SetFlyoutRowEnabled(row, enabled)
    if row._efRowEnabled == enabled then return end
    row._efRowEnabled = enabled
    row:SetEnabled(enabled)
    local a = enabled and 1 or 0.35
    local c = enabled and 1 or 0.4
    if row._label then row._label:SetTextColor(c, c, c) end
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
            ApplyMenuHighlightMask(row, hl, row._efMenuHighlightPosition or "middle")
        end
        row:HookScript("OnEnter", MenuRowEnterAdjustsHolds)
    end
    row.SetMenuHighlightFocused = function(self, focused)
        if focused then
            if self.LockHighlight then self:LockHighlight() end
        else
            if self.UnlockHighlight then self:UnlockHighlight() end
        end
    end
    row.ClearMenuHighlightState = function(self)
        if self.UnlockHighlight then self:UnlockHighlight() end
        if self.keyboardOverlay then self.keyboardOverlay:Hide() end
    end
    return row.SetMenuHighlightFocused
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

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text or "")
    label:SetTextColor(1, 1, 1, 1)
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

    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_HOVER)) end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_NORMAL)) end
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_PRESSED)) end
    end)
    btn:SetScript("OnMouseUp", function(self)
        if not self:IsEnabled() then return end
        if self:IsMouseOver() then
            ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_HOVER))
        else
            ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_NORMAL))
        end
    end)
    btn:SetScript("OnDisable", function(self)
        ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_DISABLED))
        if self._label then self._label:SetTextColor(ns.TEXT_DIM[1], ns.TEXT_DIM[2], ns.TEXT_DIM[3], 1) end
    end)
    btn:SetScript("OnEnable", function(self)
        ns.SetRoundedRectBorderFillColor(self, unpack(ns.BTN_FILL_NORMAL))
        if self._label then self._label:SetTextColor(1, 1, 1, 1) end
    end)

    if text then btn:SetText(text) end
    return btn
end

-- Thin two-stroke "X" close button (dim by default, white on hover), matching
-- the tutorial / what's-new windows. Two rotated 1px lines stay sharp at any
-- UI scale. Caller sets the OnClick handler.
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
    setX(Utils.RGB(ns.TEXT_DIM))
    btn:SetScript("OnEnter", function() setX(1, 1, 1) end)
    btn:SetScript("OnLeave", function() setX(Utils.RGB(ns.TEXT_DIM)) end)
    return btn
end

-- A small, addon-styled popup with a single read-only field whose text is
-- pre-selected so the user can immediately Ctrl-C it. Shared by the Wowhead
-- link option and the bug-report / feature-request feedback URLs. WoW addons
-- cannot write the clipboard, so a copy field is the correct approach.
local copyBox
function ns.ShowCopyBox(text, labelText)
    text = text or ""
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
        f.title:SetPoint("TOPLEFT", 14, -14)
        f.title:SetJustifyH("LEFT")
        f.title:SetWordWrap(false)

        local field = CreateFrame("Frame", nil, f)
        field:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -10)
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
        -- Read-only feel: revert and re-select if the user types over it.
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput and self:GetText() ~= f._text then
                self:SetText(f._text or "")
                self:HighlightText()
            end
        end)
        f.editBox = editBox

        -- Ctrl-C confirmation. Addons cannot read the clipboard, but while the
        -- field is focused the editbox fires OnKeyDown for the copy chord, so a
        -- detected Ctrl+C flashes "Copied" (title color) and fades it out.
        local copiedHolder = CreateFrame("Frame", nil, f)
        copiedHolder:SetPoint("TOP", field, "BOTTOM", 0, -6)
        copiedHolder:SetSize(140, 16)
        copiedHolder:Hide()
        local copied = copiedHolder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
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

        local close = ns.CreateCloseX(f, 14)
        close:SetPoint("TOPRIGHT", -8, -8)
        close:SetScript("OnClick", function() f:Hide() end)

        f:Hide()
        copyBox = f
    end
    copyBox._text = text
    copyBox.title:SetText(labelText or "")
    -- Width tracks the message (+ buffer for the close X). The link field spans
    -- it and clips a longer URL; the full text is still selected for Ctrl-C.
    copyBox:SetWidth(math.max(200, math.floor(copyBox.title:GetStringWidth() + 0.5) + 44))
    copyBox:Show()
    local eb = copyBox.editBox
    eb:SetText(text)
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
        f.cancel = ns.CreateModernButton(f, "", 120, 22)

        local function accept()
            local val = f._hasEditBox and f.editBox:GetText() or nil
            f:Hide()
            if f._onAccept then f._onAccept(val) end
        end
        local function cancel()
            f:Hide()
        end
        f.accept:SetScript("OnClick", accept)
        f.cancel:SetScript("OnClick", cancel)
        eb:SetScript("OnEnterPressed", accept)
        eb:SetScript("OnEscapePressed", cancel)
        -- ESC closes without protected calls via UISpecialFrames; cancel is a
        -- bare hide, so this is the complete cancel path.
        tinsert(UISpecialFrames, "EasyFindThemedDialog")

        themedDialog = f
    end

    f._onAccept = opts.onAccept
    f._hasEditBox = opts.hasEditBox and true or false

    f.message:SetText(opts.text or "")

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

    f.accept:SetText(opts.acceptText or _G["OKAY"] or _G["ACCEPT"] or "OK")
    f.cancel:SetText(opts.cancelText or _G["CANCEL"] or "Cancel")
    f.accept:ClearAllPoints()
    f.cancel:ClearAllPoints()
    -- Accept on the left, Cancel on the right (standard button order).
    f.accept:SetPoint("TOPRIGHT", f, "TOP", -6, -used)
    f.cancel:SetPoint("TOPLEFT", f, "TOP", 6, -used)
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
-- bags, gear sets, ...), so the menu option only appears where it's useful.
function ns.GetWowheadLink(data)
    if not data then return nil end
    local kind, id, query

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
        kind, id = "title", data.titleID
    elseif data.spellID and (data.category == "Ability" or data.category == "Talent") then
        kind, id = "spell", data.spellID
    elseif data.itemID and data.category == "Loot" then
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
    if query then
        return "https://" .. sub .. ".wowhead.com/search?q=" .. WowheadSearchEncode(query)
    end
    return "https://" .. sub .. ".wowhead.com/" .. kind .. "=" .. id
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
-- caller needs to hand-code a maxWidth — set L/R anchors and forget. Pass
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
    arrow:SetVertexColor(0.7, 0.7, 0.7)
    local label = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", 14, 0)
    label:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
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
    local THUMB_W = 3
    local EDGE_INSET = 4
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
    topMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    topMask:SetSize(THUMB_W, THUMB_W)
    topMask:SetPoint("TOP", thumb, "TOP", 0, 0)
    thumbTop:AddMaskTexture(topMask)

    local thumbBot = thumb:CreateTexture(nil, "ARTWORK")
    thumbBot:SetColorTexture(1, 1, 1, 1)
    thumbBot:SetSize(THUMB_W, capH)
    thumbBot:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)

    local botMask = thumb:CreateMaskTexture()
    botMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
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

function Utils.ClickButton(btn, mouseButton)
    if not btn then return false end
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

local function CursorMenuHasMouse(self)
    if self:IsMouseOver() then return true end
    if self.rows then
        for i = 1, #self.rows do
            if Utils.IsFrameVisiblyMouseOver(self.rows[i]) then
                return true
            end
        end
    end
    return false
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
    local onClick = row.onClick
    self:Hide()
    if onClick then onClick() end
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
    self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    self:RegisterEvent("GLOBAL_MOUSE_UP")
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
    local onHide = self.onHide
    self.onHide = nil
    if onHide then onHide(self) end
end

local function CursorMenuOnUpdate(self)
    -- stayOpen menus close only on click-outside (handled in OnEvent), never on
    -- mouse-leave, matching the search bar's filter menu.
    if self.stayOpen then return end
    if CursorMenuHasMouse(self) then
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
    if not CursorMenuHasMouse(self) then self:Hide() end
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
    elseif navKey == "ENTER" or navKey == "SPACE" then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        CursorMenuActivateKeyboardIndex(self)
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

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}

    HideOtherMenus(globalName, nil)

    local menu = FindFreeMenu(globalName) or CreateCursorMenu(globalName)

    local menuScale = opts.scale or 1
    menu:SetScale(menuScale)
    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    menu:SetFrameLevel(opts.level or 10000)
    menu.outsideDelay = opts.outsideDelay or 0.3
    menu.clickGrace = opts.clickGrace or 0.05
    menu.stayOpen = opts.stayOpen and true or false
    menu.keyboardMode = opts.keyboardMode and true or false
    menu.keyboardIndex = nil
    menu.onHide = opts.onHide
    menu.toggleOwner = opts.toggleOwner

    local rowH = opts.rowHeight or 22
    local width = opts.width or 96
    local shown = 0
    local lastRow
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
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.icon = row:CreateTexture(nil, "OVERLAY")
                row.icon:SetSize(14, 14)
                row.icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.sep = row:CreateTexture(nil, "ARTWORK")
                row.sep:SetColorTexture(1, 1, 1, 0.18)
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
            row:SetHeight(isSep and sepH or rowH)
            if isSep then
                if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                row.isSeparator = true
                row.disabled = nil
                row.onClick = nil
                row.label:SetText("")
                row.icon:Hide()
                row.sep:Show()
                row:EnableMouse(false)
                local hl = row:GetHighlightTexture()
                if hl then hl:SetAlpha(0) end
                row:SetScript("OnMouseDown", nil)
                row:SetScript("OnClick", nil)
            else
                row.isSeparator = nil
                row.disabled = def.disabled and true or nil
                row.label:SetText(def.text or "")
                row.label:SetTextColor(Utils.RGB(row.disabled and ns.TEXT_DIM or ns.GOLD_COLOR, 1))
                if def.icon then
                    row.icon:SetTexture(def.icon)
                    row.icon:SetDesaturated(row.disabled and true or false)
                    row.icon:SetAlpha(row.disabled and 0.5 or 1)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                row.sep:Hide()
                if row.disabled then
                    if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                    row:EnableMouse(false)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(0) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", nil)
                else
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    local onClick = def.onClick
                    row.onClick = onClick
                    row:SetScript("OnMouseDown", function(_, button)
                        if button ~= "LeftButton" then return end
                        menu:Hide()
                        if onClick then onClick() end
                    end)
                end
                row:SetScript("OnClick", nil)
            end
            row:ClearAllPoints()
            if shown == 1 then
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4)
                row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -4)
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
            if row.keyboardOverlay then row.keyboardOverlay:Hide() end
            row:SetScript("OnClick", nil)
            row:SetScript("OnMouseDown", nil)
        end
    end

    local needed = width
    local totalH = 0
    for i = 1, shown do
        local row = menu.rows[i]
        if row then
            totalH = totalH + (row:GetHeight() or rowH)
            if row.label and row.label:IsShown() then
                local getter = row.label.GetUnboundedStringWidth or row.label.GetStringWidth
                local lblW = getter and getter(row.label) or 0
                local hasIcon = row.icon and row.icon:IsShown()
                local rowW = lblW + (hasIcon and 34 or 24)
                if rowW > needed then needed = rowW end
            end
        end
    end
    menu:SetSize(needed, totalH + 8)
    menu:ClearAllPoints()
    if opts.anchorFrame then
        menu:SetPoint(opts.point or "TOPLEFT", opts.anchorFrame, opts.relativePoint or "TOPRIGHT",
            opts.offsetX or 4, opts.offsetY or 0)
    else
        local scale = UIParent:GetEffectiveScale() * menuScale
        local x, y = GetCursorPosition()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    end
    menu:Show()
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
    rows[#rows + 1] = { text = isPinned and (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_UNPIN"] or "Unpin") or (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_PIN"] or "Pin"), onClick = onPin }
    if onGuide then
        rows[#rows + 1] = { text = L["CTX_GUIDE"], icon = ns.EYE_ICON_TEX, onClick = onGuide }
    end
    if extra and extra.onWowhead then
        rows[#rows + 1] = { text = L["CTX_WOWHEAD"], onClick = extra.onWowhead }
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
        fs:SetFont(files[w] or files.regular, size, flags)
    else
        fs:SetFont(baseline.path, baseline.size, baseline.flags or "")
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
