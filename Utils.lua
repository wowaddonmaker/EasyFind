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

function Utils.SafeCall(func, ...)
    if InCombatLockdown() then return false end
    return pcall(func, ...)
end

function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false end
    if not obj then return false end
    local fn = obj[method]
    if not fn then return false end
    return pcall(fn, obj, ...)
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
        action()
        repeatKey = key
        repeatAction = action
        repeatHeld = 0
        repeatNext = initialDelay
        repeatActive = true
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

function Utils.AttachAutocomplete(editBox, opts)
    if not editBox or not opts or type(opts.findCandidate) ~= "function" then return end

    local findCandidate = opts.findCandidate
    local onTypedChanged = opts.onTypedChanged
    local onAccepted = opts.onAccepted
    local backspaceAutocompleteTarget = opts.backspaceAutocompleteTarget
    local onBackspaceAutocompleteRestored = opts.onBackspaceAutocompleteRestored
    local typedText = ""
    local programmatic = false
    local currentCandidate = nil
    local smoothExtendDone = false
    local restoreBackspaceText, restoreBackspaceCursor
    local restoreBackspaceNotify = false
    local mouseAcceptCandidate
    local mouseAcceptTypedLen
    local backspaceStripActive = false
    local charDispatchedTyped

    local function HasAutocomplete()
        return currentCandidate ~= nil and (editBox:GetText() or "") ~= typedText
    end

    local function NormalizeCandidate(candidate)
        if not candidate or candidate == "" or typedText == "" then return nil end
        candidate = slower(candidate)
        local typedLen = #typedText
        if typedLen >= #candidate then return nil end
        if slower(ssub(candidate, 1, typedLen)) ~= slower(typedText) then
            return nil
        end
        return candidate
    end

    local function StripAutocomplete()
        local hadAutocomplete = HasAutocomplete()
        if hadAutocomplete then
            programmatic = true
            editBox:SetText(typedText)
            editBox:SetCursorPosition(#typedText)
            editBox:HighlightText(0, 0)
            programmatic = false
        else
            editBox:HighlightText(0, 0)
        end
        currentCandidate = nil
        smoothExtendDone = false
        return hadAutocomplete
    end

    local function RenderCandidate(candidate)
        candidate = NormalizeCandidate(candidate)
        if not candidate then
            StripAutocomplete()
            return false
        end

        -- WoW defers OnTextChanged by one frame, so the in-flight char
        -- isn't in typedText yet. SetText here would overwrite it and the
        -- deferred OnTextChanged would silently drop the keystroke.
        local liveText = editBox:GetText() or ""
        local liveCursor = editBox:GetCursorPosition() or #liveText
        local hasLiveSuggestion = currentCandidate ~= nil
                                  and liveText == currentCandidate
                                  and liveCursor == #typedText
        local liveTyped = ssub(liveText, 1, liveCursor)
        if not hasLiveSuggestion and liveTyped ~= typedText then
            return false
        end

        local typedLen = #typedText
        typedText = ssub(candidate, 1, typedLen)
        currentCandidate = candidate

        programmatic = true
        if editBox:GetText() ~= candidate then
            editBox:SetText(candidate)
        end
        editBox:SetCursorPosition(typedLen)
        editBox:HighlightText(typedLen, #candidate)
        programmatic = false
        return true
    end

    local function ApplyAutocomplete()
        if programmatic or typedText == "" or not editBox:HasFocus() then
            StripAutocomplete()
            return
        end
        if smoothExtendDone then
            smoothExtendDone = false
            return
        end
        local candidate = findCandidate(typedText)
        RenderCandidate(candidate)
    end

    editBox:HookScript("OnTextChanged", function(self, userInput)
        if programmatic then return end
        local current = self:GetText() or ""
        if restoreBackspaceText then
            local restoreText = restoreBackspaceText
            local restoreCursor = restoreBackspaceCursor or #restoreText
            local notify = restoreBackspaceNotify
            restoreBackspaceText, restoreBackspaceCursor = nil, nil
            restoreBackspaceNotify = false
            backspaceStripActive = false
            if current ~= restoreText then
                programmatic = true
                self:SetText(restoreText)
                self:SetCursorPosition(restoreCursor)
                self:HighlightText(0, 0)
                programmatic = false
            end
            typedText = ssub(restoreText, 1, restoreCursor)
            currentCandidate = nil
            smoothExtendDone = false
            if notify and onBackspaceAutocompleteRestored then
                onBackspaceAutocompleteRestored(self, typedText)
            end
            return
        end
        local cursorPos = self:GetCursorPosition() or #current
        if not userInput and cursorPos == 0 and current ~= "" then
            cursorPos = #current
        end
        local typed = ssub(current, 1, cursorPos)
        if charDispatchedTyped and typed == charDispatchedTyped then
            charDispatchedTyped = nil
            return
        end
        if typed == typedText then return end
        local prevText = typedText
        local prevLen = #typedText
        typedText = typed
        local grew = #typedText > prevLen
        -- Smooth-extend the candidate in-place: safe here because we run
        -- synchronously inside OnTextChanged (post-keystroke), not from
        -- the throttle's OnUpdate, so there's no in-flight char to clobber.
        local extended = false
        if grew and currentCandidate
           and #typed < #currentCandidate
           and slower(ssub(currentCandidate, 1, #typed)) == slower(typed) then
            local typedLen = #typed
            programmatic = true
            if self:GetText() ~= currentCandidate then
                self:SetText(currentCandidate)
            end
            self:SetCursorPosition(typedLen)
            self:HighlightText(typedLen, #currentCandidate)
            programmatic = false
            extended = true
        end
        if not extended then
            currentCandidate = nil
            self:HighlightText(0, 0)
        end
        if onTypedChanged then onTypedChanged(self, typedText, prevText, grew) end
    end)

    editBox:HookScript("OnEditFocusLost", StripAutocomplete)

    local function AcceptAutocomplete(self, source, cursorPos)
        local candidate = currentCandidate
        if not candidate or candidate == "" then return false end
        if cursorPos then
            if cursorPos < 0 then cursorPos = 0 end
            if cursorPos > #candidate then cursorPos = #candidate end
        end
        if not self:HasFocus() then self:SetFocus() end
        programmatic = true
        self:SetText(candidate)
        self:SetCursorPosition(cursorPos or #candidate)
        self:HighlightText(0, 0)
        programmatic = false
        typedText = candidate
        currentCandidate = nil
        smoothExtendDone = false
        if onAccepted then onAccepted(candidate, source) end
        return true
    end

    editBox:HookScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        mouseAcceptCandidate = HasAutocomplete() and currentCandidate or nil
        mouseAcceptTypedLen = mouseAcceptCandidate and #typedText or nil
    end)

    editBox:HookScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or not mouseAcceptCandidate then return end
        local candidate = mouseAcceptCandidate
        local typedLen = mouseAcceptTypedLen or #typedText
        mouseAcceptCandidate = nil
        mouseAcceptTypedLen = nil
        if (self:GetText() or "") ~= candidate then return end
        local cursorPos = self:GetCursorPosition() or #candidate
        if cursorPos < typedLen then
            local prefix = ssub(candidate, 1, typedLen)
            programmatic = true
            self:SetText(prefix)
            self:SetCursorPosition(cursorPos)
            self:HighlightText(0, 0)
            programmatic = false
            typedText = prefix
            currentCandidate = nil
            smoothExtendDone = false
            return
        end
        typedText = candidate
        currentCandidate = nil
        smoothExtendDone = false
        self:HighlightText(0, 0)
        if onAccepted then onAccepted(candidate, "click") end
    end)

    editBox:HookScript("OnTabPressed", function(self)
        AcceptAutocomplete(self, "tab")
    end)

    editBox:HookScript("OnKeyDown", function(self, key)
        if key == "BACKSPACE" and HasAutocomplete() then
            local targetText, targetCursor
            if backspaceAutocompleteTarget then
                targetText, targetCursor = backspaceAutocompleteTarget(self, typedText, currentCandidate)
            end
            if targetText == nil then
                targetText = typedText
                targetCursor = #typedText
                restoreBackspaceNotify = false
            else
                targetText = tostring(targetText)
                if targetCursor == nil then targetCursor = #targetText end
                restoreBackspaceNotify = true
            end
            backspaceStripActive = true
            restoreBackspaceText = targetText
            restoreBackspaceCursor = targetCursor
            StripAutocomplete()
            if C_Timer then
                C_Timer.After(0, function()
                    if restoreBackspaceText and restoreBackspaceNotify then
                        local restoreText = restoreBackspaceText
                        local restoreCursor = restoreBackspaceCursor or #restoreText
                        restoreBackspaceText, restoreBackspaceCursor = nil, nil
                        restoreBackspaceNotify = false
                        backspaceStripActive = false
                        programmatic = true
                        self:SetText(restoreText)
                        self:SetCursorPosition(restoreCursor)
                        self:HighlightText(0, 0)
                        programmatic = false
                        typedText = ssub(restoreText, 1, restoreCursor)
                        currentCandidate = nil
                        smoothExtendDone = false
                        if onBackspaceAutocompleteRestored then
                            onBackspaceAutocompleteRestored(self, typedText)
                        end
                        return
                    end
                    restoreBackspaceText, restoreBackspaceCursor = nil, nil
                    restoreBackspaceNotify = false
                    backspaceStripActive = false
                end)
            end
            if Utils.SafeCallMethod then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            end
            return
        end
        local source
        if key == "RIGHT" or key == "ARROWRIGHT" then
            source = "right"
        elseif key == "L" and IsControlKeyDown() then
            source = "ctrl-l"
        end
        if source
           and AcceptAutocomplete(self, source) then
            if Utils.SafeCallMethod then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            end
        end
    end)

    editBox.UpdateAutocomplete = ApplyAutocomplete
    editBox.StripAutocomplete  = StripAutocomplete
    editBox.AcceptAutocomplete = function(self, source, cursorPos)
        return AcceptAutocomplete(self, source, cursorPos)
    end
    editBox.GetTypedText       = function() return typedText end
    editBox.HasAutocomplete    = function() return HasAutocomplete() end
    editBox.IsAutocompleteBackspaceStrip = function() return backspaceStripActive end
    editBox.IsAutocompleteProgrammatic = function() return programmatic end
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
ns.EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
ns.DARK_PANEL_BG = {0.1, 0.1, 0.1, 0.95}
ns.SEARCH_WINDOW_FILL_COLOR = {0.052, 0.052, 0.060}
ns.RESULT_ICON_SIZE = 18
ns.SEARCHBAR_HEIGHT = 30
ns.SEARCHBAR_FILL = 0.55
ns.SEARCHBAR_ICON_SCALE = 0.75
ns.CLEAR_BTN_SIZE = 12
local EasyFindSearchFont = CreateFont("EasyFindSearchFont")
local baseFont = Game15Font_Shadow or GameFontNormal
EasyFindSearchFont:CopyFontObject(baseFont)
EasyFindSearchFont:SetFont((baseFont:GetFont()), 12, select(3, baseFont:GetFont()))
ns.SEARCHBAR_FONT = "EasyFindSearchFont"

local SEARCH_TEX_FILL = "Interface\\AddOns\\EasyFind\\Textures\\SearchBarFill"
local SEARCH_TEX_BORDER = "Interface\\AddOns\\EasyFind\\Textures\\SearchBarBorder"
local CLEAR_BTN_TEX = "Interface\\AddOns\\EasyFind\\Textures\\clear-button"
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
local COMBINED_TEX_FILL   = "Interface\\AddOns\\EasyFind\\Textures\\CombinedFill"
local COMBINED_TEX_BORDER = "Interface\\AddOns\\EasyFind\\Textures\\CombinedBorder"
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

    for _, key in ipairs(BUTTON_TEXT_KEYS) do
        local child = btn[key]
        if child and child.GetText then
            local t = child:GetText()
            if t then return t end
        end
    end

    if btn.GetText then
        local t = btn:GetText()
        if t then return t end
    end

    for i = 1, select("#", btn:GetRegions()) do
        local region = select(i, btn:GetRegions())
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

function Utils.GetAllFrameText(frame)
    if not frame then return nil end
    wipe(frameTextScratch)
    local texts = frameTextScratch

    for _, key in ipairs(FRAME_TEXT_KEYS) do
        local child = frame[key]
        if child and child.GetText then
            local t = child:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if frame.GetText then
        local t = frame:GetText()
        if t then texts[#texts + 1] = t end
    end

    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
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

function Utils.ShallowCopy(src)
    local copy = {}
    for k, v in pairs(src) do
        copy[k] = v
    end
    return copy
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
        C_Timer.After(0, function()
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
        pcall(btn.Click, btn, mouseButton)
        return true
    end
    local hasScript, onClick = pcall(btn.GetScript, btn, "OnClick")
    if hasScript and onClick then
        pcall(onClick, btn, mouseButton)
        return true
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

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}

    HideOtherMenus(globalName, nil)

    local menu = FindFreeMenu(globalName)
    if not menu then
        cursorMenuCounter = cursorMenuCounter + 1
        local frameName = globalName .. "_" .. cursorMenuCounter
        menu = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
        menu:EnableMouse(true)
        menu.rows = {}
        menu:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = ns.TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        local bg = ns.DARK_PANEL_BG
        if bg then menu:SetBackdropColor(bg[1], bg[2], bg[3], bg[4]) end
        local function MenuHasMouse(self)
            if self:IsMouseOver() then return true end
            if self.rows then
                for i = 1, #self.rows do
                    local row = self.rows[i]
                    if row and row:IsShown() and row:IsMouseOver() then
                        return true
                    end
                end
            end
            return false
        end
        menu:SetScript("OnShow", function(self)
            self._showedAt = GetTime()
            self._outsideSince = nil
            self._hasEntered = false
            Utils.SafeCallMethod(self, "EnableKeyboard", true)
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            self:RegisterEvent("GLOBAL_MOUSE_UP")
        end)
        menu:SetScript("OnHide", function(self)
            self._outsideSince = nil
            self._hasEntered = false
            Utils.SafeCallMethod(self, "EnableKeyboard", false)
            self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            self:UnregisterEvent("GLOBAL_MOUSE_UP")
            if self.rows then
                for i = 1, #self.rows do
                    local row = self.rows[i]
                    if row then row:Hide() end
                end
            end
        end)
        menu:SetScript("OnUpdate", function(self)
            if MenuHasMouse(self) then
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
        end)
        menu:SetScript("OnEvent", function(self, event)
            if event ~= "GLOBAL_MOUSE_DOWN" and event ~= "GLOBAL_MOUSE_UP" then return end
            if self._showedAt and (GetTime() - self._showedAt) < (self.clickGrace or 0.05) then return end
            if not MenuHasMouse(self) then self:Hide() end
        end)
        menu:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                self:Hide()
            else
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            end
        end)
        cursorMenuPool[globalName] = cursorMenuPool[globalName] or {}
        local pool = cursorMenuPool[globalName]
        pool[#pool + 1] = menu
        if not _G[globalName] then _G[globalName] = menu end
    end

    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    menu:SetFrameLevel(opts.level or 10000)
    menu.outsideDelay = opts.outsideDelay or 0.3
    menu.clickGrace = opts.clickGrace or 0.05

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
                menu.rows[shown] = row
            end
            local isSep = def.isSeparator
            local sepH = 7
            row:SetHeight(isSep and sepH or rowH)
            if isSep then
                row.label:SetText("")
                row.icon:Hide()
                row.sep:Show()
                row:EnableMouse(false)
                local hl = row:GetHighlightTexture()
                if hl then hl:SetAlpha(0) end
                row:SetScript("OnMouseDown", nil)
                row:SetScript("OnClick", nil)
            else
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
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
        x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    menu:Show()
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
        local c = icon.coords
        if c then textureObj:SetTexCoord(c[1], c[2], c[3], c[4]) end
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
