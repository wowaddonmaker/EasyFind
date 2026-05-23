local _, ns = ...

local Utils = {}
ns.Utils = Utils

local pairs, ipairs, type, select, unpack, next = pairs, ipairs, type, select, unpack, next
local tinsert, tsort, tconcat, tremove = table.insert, table.sort, table.concat, table.remove
local sfind, slower, ssub, sformat, smatch = string.find, string.lower, string.sub, string.format, string.match
local mmin, mmax, mabs, mpi, mceil, mfloor = math.min, math.max, math.abs, math.pi, math.ceil, math.floor
local pcall, xpcall, tostring, tonumber = pcall, xpcall, tostring, tonumber
local debugstack = debugstack
local CreateFrame = CreateFrame

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

function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false end
    if not obj then return false end
    local fn = obj[method]
    if not fn then return false end
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

-- WoW's OnKeyDown reports arrow keys as "UP"/"DOWN"/"LEFT"/"RIGHT" but
-- IsKeyDown() requires "UPARROW"/"DOWNARROW"/"LEFTARROW"/"RIGHTARROW".
-- This wraps the inconsistency so callers can pass the OnKeyDown-style
-- name and still get the right answer for held arrow keys.
local IS_KEY_DOWN_ALIASES = {
    UP = "UPARROW", DOWN = "DOWNARROW",
    LEFT = "LEFTARROW", RIGHT = "RIGHTARROW",
}
function Utils.IsPhysicalKeyDown(key)
    if not IsKeyDown or not key then return false end
    return IsKeyDown(IS_KEY_DOWN_ALIASES[key] or key) and true or false
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
ns.SEARCH_WINDOW_ALPHA = 0.95
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
ns.DARK_PANEL_BG = {0.1, 0.1, 0.1, 0.95}
ns.SEARCH_WINDOW_FILL_COLOR = {0.052, 0.052, 0.060}
ns.RESULT_ICON_SIZE = 18
ns.TEXT_PRIMARY = {1.00, 0.97, 0.86}
ns.TEXT_BODY = {0.78, 0.78, 0.80}
ns.TEXT_DIM = {0.55, 0.55, 0.58}
ns.BTN_FILL_NORMAL = {0.095, 0.095, 0.108}
ns.BTN_FILL_HOVER = {0.155, 0.155, 0.172}
ns.BTN_FILL_PRESSED = {0.065, 0.065, 0.078}
ns.BTN_FILL_DISABLED = {0.070, 0.070, 0.080}
ns.SEARCHBAR_HEIGHT = 30
ns.SEARCHBAR_FILL = 0.55
ns.SEARCHBAR_ICON_SCALE = 0.75
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

    btn.SetText = function(self, value)
        if self._label then self._label:SetText(value or "") end
    end
    btn.GetText = function(self)
        return self._label and self._label:GetText() or ""
    end
    btn.SetSize = function(self, w, h)
        rawSetSize(self, w, h)
        ns.SetRoundedRectBarHeight(self, mmin(h or self:GetHeight() or 22, 10))
    end

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

function ns.SetSearchBorderBgAlpha(frame, alpha)
    if not frame.searchBorder then return end
    local sb = frame.searchBorder
    sb.fillLeft:SetAlpha(alpha)
    sb.fillMid:SetAlpha(alpha)
    sb.fillRight:SetAlpha(alpha)
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

function Utils.AttachHoverPopup(owner, popup, opts)
    if not owner or not popup then return nil end
    opts = opts or {}

    local delay = opts.delay or 0.15
    local extraGuards = opts.extraGuards or {}
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

function Utils.IsButtonSelected(btn)
    if not btn then return false end

    if btn.isSelected then return true end
    if btn.selected  then return true end

    if btn.collapsed == false then return true end
    if btn.isExpanded            then return true end
    if btn.expanded              then return true end

    if btn.highlight       and btn.highlight:IsShown()       then return true end
    if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
    if btn.SelectedTexture and btn.SelectedTexture:IsShown() then return true end

    if btn.Selection  and btn.Selection:IsShown()  then return true end
    if btn.selection  and btn.selection:IsShown()  then return true end
    if btn.Background and btn.Background:IsShown() then return true end

    if btn.element and btn.element.collapsed == false then return true end

    return false
end

function Utils.SearchFrameTree(frame, targetTextLower, maxDepth)
    maxDepth = maxDepth or 6
    local function search(f, depth)
        if not f or depth > maxDepth then return nil end
        if f:IsShown() then
            local text = Utils.GetButtonText(f)
            if text and slower(text) == targetTextLower then
                if f.Click or (f.IsMouseEnabled and f:IsMouseEnabled()) then
                    return f
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

function Utils.IsFrameShown(frame)
    if not frame then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown
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

    bar:SetScript("OnUpdate", function(self)
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
        local ok, err = xpcall(onClick, ErrorHandler, btn, mouseButton)
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
    return row and row:IsShown() and not row.isSeparator
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
    menu.rows = {}
    menu:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = ns.TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    if ns.DARK_PANEL_BG then menu:SetBackdropColor(unpack(ns.DARK_PANEL_BG)) end

    menu.SetKeyboardIndex = CursorMenuSetKeyboardIndex
    menu.MoveKeyboardIndex = CursorMenuMoveKeyboardIndex
    menu.ActivateKeyboardIndex = CursorMenuActivateKeyboardIndex
    menu.FocusKeyboard = CursorMenuFocusKeyboard
    menu:SetScript("OnShow", CursorMenuOnShow)
    menu:SetScript("OnHide", CursorMenuOnHide)
    menu:SetScript("OnUpdate", CursorMenuOnUpdate)
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

    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    menu:SetFrameLevel(opts.level or 10000)
    menu.outsideDelay = opts.outsideDelay or 0.3
    menu.clickGrace = opts.clickGrace or 0.05
    menu.keyboardMode = opts.keyboardMode and true or false
    menu.keyboardIndex = nil
    menu.onHide = opts.onHide

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
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
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
                row.isSeparator = true
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
                row.label:SetText(def.text or "")
                if def.icon then
                    row.icon:SetTexture(def.icon)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                row.sep:Hide()
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
        local scale = UIParent:GetEffectiveScale()
        local x, y = GetCursorPosition()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    end
    menu:Show()
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
        rows[#rows + 1] = { text = "Add Alias", onClick = onAddAlias }
    end
    rows[#rows + 1] = { text = isPinned and "Unpin" or "Pin", onClick = onPin }
    if onGuide then
        rows[#rows + 1] = { text = "Guide", icon = ns.EYE_ICON_TEX, onClick = onGuide }
    end

    local extras = {}
    if extra and extra.onTrack then
        extras[#extras + 1] = {
            text = extra.isTracked and "Untrack" or "Track",
            onClick = extra.onTrack,
        }
    end
    if extra and extra.onToggleBackpack then
        extras[#extras + 1] = {
            text = extra.isOnBackpack and "Remove from backpack" or "Show on backpack",
            onClick = extra.onToggleBackpack,
        }
    end
    if extra and extra.onTransfer then
        extras[#extras + 1] = { text = "Transfer", onClick = extra.onTransfer }
    end
    if extra and extra.onToggleWatchedFaction then
        extras[#extras + 1] = {
            text = extra.isWatchedFaction and "Hide XP bar" or "Show as XP bar",
            onClick = extra.onToggleWatchedFaction,
        }
    end
    if extra and extra.onSummon then
        extras[#extras + 1] = { text = "Summon", onClick = extra.onSummon }
    end
    if extra and extra.onRename then
        extras[#extras + 1] = { text = "Rename", onClick = extra.onRename }
    end
    if extra and extra.onToggleFavorite then
        extras[#extras + 1] = {
            text = extra.isFavorite and "Remove favorite" or "Set favorite",
            onClick = extra.onToggleFavorite,
        }
    end
    if extra and extra.onCageOrRelease then
        extras[#extras + 1] = {
            text = extra.isCageable and "Put in cage" or "Release",
            onClick = extra.onCageOrRelease,
        }
    end
    if #extras > 0 then
        rows[#rows + 1] = { isSeparator = true }
        for i = 1, #extras do rows[#rows + 1] = extras[i] end
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

local INTER_REGULAR  = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Regular.ttf"
local INTER_SEMIBOLD = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-SemiBold.ttf"
local INTER_BOLD     = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Bold.ttf"

ns.FONT_CHOICES = { "Default", "Inter" }

local fontRegistry = {}
ns._fontRegistry = fontRegistry

local function GetFontChoice()
    return (EasyFind and EasyFind.db and EasyFind.db.font) or "Default"
end

local function ApplyFontTo(fs)
    if not fs or not fs.SetFont then return end
    local baseline = fs._addonFontBaseline
    if not baseline then return end
    local size  = fs._addonFontSizeOverride or baseline.size or 12
    local flags = fs._addonFontFlags or baseline.flags or ""
    local choice = GetFontChoice()
    if choice == "Inter" then
        local w = fs._addonFontWeight
        local path = INTER_REGULAR
        if     w == "bold"     then path = INTER_BOLD
        elseif w == "semibold" then path = INTER_SEMIBOLD end
        fs:SetFont(path, size, flags)
    else
        fs:SetFont(baseline.path, baseline.size, baseline.flags or "")
    end
end

function ns.RegisterAddonFont(fs, weight, sizeOverride, flags)
    if not fs or not fs.GetFont or not fs.SetFont then return end
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
