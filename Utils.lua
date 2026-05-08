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

--- Call a protected function safely, suppressing errors during combat lockdown.
--- Returns true + results on success, false on failure.
function Utils.SafeCall(func, ...)
    if InCombatLockdown() then return false end
    return pcall(func, ...)
end

--- Call a protected method safely (e.g. frame:SetPropagateKeyboardInput).
--- Usage: Utils.SafeCallMethod(frame, "SetPropagateKeyboardInput", false)
function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false end
    local fn = obj[method]
    if not fn then return false end
    return pcall(fn, obj, ...)
end

--- Protected OnUpdate wrapper. If the handler errors, it self-cancels
--- to prevent per-frame error spam that can freeze the UI.
--- Pass nil handler to clear.
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

--- Protected C_Timer.After wrapper. Catches errors in the callback
--- so a crash in a delayed call doesn't propagate unhandled.
function Utils.SafeAfter(delay, fn)
    C_Timer.After(delay, function()
        local ok, err = xpcall(fn, ErrorHandler)
        if not ok then
            Utils.DebugPrint("Timer error: " .. tostring(err))
        end
    end)
end

--- Key-repeat controller shared by UI search and MapTab nav. Holding
--- a key fires the action immediately, waits INITIAL seconds, then
--- ticks at a rate that accelerates from INITIAL toward FAST over
--- ACCEL seconds. Attach OnKeyUp to `Stop(key)` so releasing the key
--- stops the repeat — pass the key so other keys pressed concurrently
--- don't cancel each other.
---
--- Returns a table: { Start(key, action), Stop(key?), IsKey(key) }.
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
    local typedText = ""
    local programmatic = false
    local currentCandidate = nil
    local smoothExtendDone = false
    local restoreBackspaceText, restoreBackspaceCursor
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

        -- Abort if a user keystroke landed between when the search was
        -- scheduled and now: WoW defers OnTextChanged by one frame, so
        -- the in-flight char hasn't updated typedText yet but is already
        -- in the editbox. Calling SetText here would overwrite it, and
        -- the deferred OnTextChanged would then see no change vs.
        -- typedText (we'd just set it to candidate) and silently drop
        -- the keystroke.
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
            restoreBackspaceText, restoreBackspaceCursor = nil, nil
            backspaceStripActive = false
            if current ~= restoreText then
                programmatic = true
                self:SetText(restoreText)
                self:SetCursorPosition(restoreCursor)
                self:HighlightText(0, 0)
                programmatic = false
            end
            typedText = ssub(restoreText, 1, restoreCursor)
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
        -- Smooth-extend: when the user types a character that matches
        -- the next character of the current candidate, re-attach the
        -- suggestion in-place instead of clearing it and waiting for
        -- the throttled re-render. This is the "Chrome omnibox" feel:
        -- the highlighted suffix shrinks character by character without
        -- flicker. Safe because we run synchronously inside
        -- OnTextChanged (post-keystroke), not from the throttle's
        -- OnUpdate, so there's no in-flight char to clobber.
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

    -- OnChar smooth-extend hook removed: it raced with OnTextChanged
    -- when the user typed quickly, calling SetText mid-keystroke and
    -- occasionally swallowing the next character. OnTextChanged below
    -- still handles smooth extension when the typed prefix continues
    -- to match the candidate, so the suggestion still grows as you
    -- type without an extra SetText pass per character.

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
            backspaceStripActive = true
            restoreBackspaceText = typedText
            restoreBackspaceCursor = #typedText
            StripAutocomplete()
            if C_Timer then
                C_Timer.After(0, function()
                    restoreBackspaceText, restoreBackspaceCursor = nil, nil
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

--- Scroll a ScrollFrame so that the given child button is visible.
--- Uses the button's top/bottom relative to the scrollChild.
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
ns.DEFAULT_OPACITY = 0.75
ns.TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
ns.EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
ns.DARK_PANEL_BG = {0.1, 0.1, 0.1, 0.95}
ns.RESULT_ICON_SIZE = 18
ns.SEARCHBAR_HEIGHT = 30      -- base search bar frame height (before font scaling)
ns.SEARCHBAR_FILL = 0.55      -- fraction of bar height filled by text/icon
ns.SEARCHBAR_ICON_SCALE = 0.75 -- icon size relative to editBox height (font glyphs are shorter than line height)
ns.CLEAR_BTN_SIZE = 12         -- base clear button size (before font scaling)
local EasyFindSearchFont = CreateFont("EasyFindSearchFont")
local baseFont = Game15Font_Shadow or GameFontNormal
EasyFindSearchFont:CopyFontObject(baseFont)
EasyFindSearchFont:SetFont((baseFont:GetFont()), 12, select(3, baseFont:GetFont()))
ns.SEARCHBAR_FONT = "EasyFindSearchFont"

-- Custom 3-part search bar border with chamfered corners.
-- Fill (BACKGROUND) and border (ARTWORK) use identical shapes from custom TGA textures.
-- Fill is tinted black with tunable opacity; border uses Blizzard's action bar gray.
local SEARCH_TEX_FILL = "Interface\\AddOns\\EasyFind\\Textures\\SearchBarFill"
local SEARCH_TEX_BORDER = "Interface\\AddOns\\EasyFind\\Textures\\SearchBarBorder"
local CLEAR_BTN_TEX = "Interface\\AddOns\\EasyFind\\Textures\\clear-button"
-- 9-slice cap covers the leftmost / rightmost 37.5% of the texture
-- (0..0.375, 0.625..1) -- the texture itself has the curve in the
-- outer 64 tex px (a true semicircle, radius == half texture height)
-- followed by 32 tex px of flat top/bottom that buffer the cap/mid
-- 9-slice boundary. Cutting in the flat region lets the cap (rendered
-- at one horizontal scale) and the mid (rendered at another) join
-- without a visible kink at the curve's tangent point.
--
-- Display cap_w = 0.75 * h. The curve occupies the OUTER 2/3 of the
-- cap (= 0.5 * h = h/2), which is the true semicircle proportion;
-- the inner 1/3 (= 0.25 * h) is flat extension before mid begins.
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

-- ---------------------------------------------------------------------------
-- Rounded-rect 9-slice (combined search bar + results dropdown silhouette)
--
-- Used by the container frame that wraps both. Texture is 256x256 with
-- corner radius 64 (= 25% on each side), so the 9-slice cap ratio is
-- 0.25. Corner cells stay a fixed display size (cornerSize, normally
-- h_bar / 2 so it visually matches the bar's pill caps); top/bottom
-- edges stretch horizontally, left/right edges stretch vertically,
-- center fills the rest.
--
-- When the container's height equals 2 * cornerSize, the side edges
-- collapse to zero and the silhouette becomes a horizontal pill --
-- same shape the bar alone wants. When the container grows downward
-- (results open), only the side edges and center stretch; the
-- corners keep their shape. That gives us the "Google search bar
-- with dropdown" look in a single primitive.
-- ---------------------------------------------------------------------------
local COMBINED_TEX_FILL   = "Interface\\AddOns\\EasyFind\\Textures\\CombinedFill"
local COMBINED_TEX_BORDER = "Interface\\AddOns\\EasyFind\\Textures\\CombinedBorder"
local CR = 0.25  -- 9-slice corner ratio (cornerSize_tex / texSize) for the combined texture

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
    -- Corners: pinned to each frame corner with explicit size.
    n.tl:ClearAllPoints(); n.tl:SetPoint("TOPLEFT");     n.tl:SetSize(cornerSize, cornerSize)
    n.tr:ClearAllPoints(); n.tr:SetPoint("TOPRIGHT");    n.tr:SetSize(cornerSize, cornerSize)
    n.bl:ClearAllPoints(); n.bl:SetPoint("BOTTOMLEFT");  n.bl:SetSize(cornerSize, cornerSize)
    n.br:ClearAllPoints(); n.br:SetPoint("BOTTOMRIGHT"); n.br:SetSize(cornerSize, cornerSize)
    -- Top edge stretches between the two top corners; same for bottom.
    n.tm:ClearAllPoints()
    n.tm:SetPoint("TOPLEFT",  n.tl, "TOPRIGHT")
    n.tm:SetPoint("BOTTOMRIGHT", n.tr, "BOTTOMLEFT")
    n.bm:ClearAllPoints()
    n.bm:SetPoint("TOPLEFT",  n.bl, "TOPRIGHT")
    n.bm:SetPoint("BOTTOMRIGHT", n.br, "BOTTOMLEFT")
    -- Left/right edges stretch between top and bottom corners.
    n.ml:ClearAllPoints()
    n.ml:SetPoint("TOPLEFT",  n.tl, "BOTTOMLEFT")
    n.ml:SetPoint("BOTTOMRIGHT", n.bl, "TOPRIGHT")
    n.mr:ClearAllPoints()
    n.mr:SetPoint("TOPLEFT",  n.tr, "BOTTOMLEFT")
    n.mr:SetPoint("BOTTOMRIGHT", n.br, "TOPRIGHT")
    -- Center fills between the four edges.
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
    -- Keep corner cells a constant display size as the frame resizes
    -- (results open / close, theme rescale, etc). The bar height drives
    -- the corner; if a caller pins it via cbBarHeight the OnSizeChanged
    -- still re-anchors against that pinned value.
    frame:HookScript("OnSizeChanged", ApplyContainerCornerSize)
end

-- The container's corner radius tracks the BAR height, not the
-- container's own (which grows when results open). Callers must pin the
-- bar height via this setter once on creation and again whenever
-- fontSize / theme changes the bar's pixel height.
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

-- A 1-px horizontal divider that runs across the inside of the
-- container at the bottom of the bar's content area. Visible only
-- when the results dropdown is open; it doubles as the "bar's
-- bottom border" the user keeps as the search/results separator.
function ns.CreateRoundedRectDivider(frame)
    if frame.combinedDivider then return frame.combinedDivider end
    local d = frame:CreateTexture(nil, "ARTWORK")
    d:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 1)
    d:SetHeight(1)
    d:Hide()
    frame.combinedDivider = d
    return d
end

-- Position the divider at `yOffset` below the container's top, with a
-- small inset from each side so it doesn't bleed into the rounded
-- corners. yOffset should be the bar's height (= bar's bottom edge).
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

    -- Named text children (covers virtually every Blizzard button style)
    for _, key in ipairs(BUTTON_TEXT_KEYS) do
        local child = btn[key]
        if child and child.GetText then
            local t = child:GetText()
            if t then return t end
        end
    end

    -- Frame's own GetText (ButtonTemplate, etc.)
    if btn.GetText then
        local t = btn:GetText()
        if t then return t end
    end

    -- Fallback: first FontString in regions
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

-- Collects all text from a frame into a single string for fuzzy matching.
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

-- Checks multiple properties/textures to detect if a button is selected or expanded.
function Utils.IsButtonSelected(btn)
    if not btn then return false end

    -- Explicit selection properties
    if btn.isSelected then return true end
    if btn.selected  then return true end

    -- Expanded state (tree categories)
    if btn.collapsed == false then return true end
    if btn.isExpanded            then return true end
    if btn.expanded              then return true end

    -- Highlight/selection textures
    if btn.highlight       and btn.highlight:IsShown()       then return true end
    if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
    if btn.SelectedTexture and btn.SelectedTexture:IsShown() then return true end

    -- Background / selection highlight
    if btn.Selection  and btn.Selection:IsShown()  then return true end
    if btn.selection  and btn.selection:IsShown()  then return true end
    if btn.Background and btn.Background:IsShown() then return true end

    -- Element data collapsed flag
    if btn.element and btn.element.collapsed == false then return true end

    return false
end

-- Walks a frame hierarchy for a clickable child with exact text match (case-insensitive).
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

-- Walks a frame hierarchy for a clickable child whose text contains searchText.
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

-- pcall-wrapped IsShown for frames that may be forbidden.
function Utils.IsFrameShown(frame)
    if not frame then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown
end

-- Resolve a dotted path string (e.g. "PVEFrame.Tab1") to the actual frame.
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

-- Thin scrollbar using minimal-scrollbar-* atlas textures, overlaid on the right edge.
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

    -- Pill shape: rect body + masked half-circle caps top/bottom.
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

    -- Activity-driven visibility. Bar is shown but at alpha 0 by default;
    -- each interaction bumps it to full opacity, and after FADE_HOLD
    -- seconds of idle it fades back over FADE_OUT seconds.
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

    -- Route the host scrollFrame's wheel through the same eased path so
    -- wheel events on the content (not just over the thumb) feel smooth.
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

--- Scroll a ScrollBox to the first element matching matchFn.
--- Tries FindElementDataByPredicate → ScrollToElementData first.
--- Falls back to SetScrollPercentage(fallbackFraction) if the data provider
--- returns nothing (virtual providers with no stored collection).
--- @param scrollBox  ScrollBox frame
--- @param matchFn    function(elementData) -> bool
--- @param fallbackFraction  number 0-1 or nil (skip fallback)
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

--- Find the first visible frame in a ScrollBox whose element data satisfies matchFn.
--- @param scrollBox  ScrollBox frame
--- @param matchFn    function(btn) -> bool  (receives the visible frame, not raw element data)
--- @return Frame or nil
function Utils.ScrollBoxFindButton(scrollBox, matchFn)
    if not scrollBox or not scrollBox.EnumerateFrames then return nil end
    for _, btn in scrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and matchFn(btn) then
            return btn
        end
    end
    return nil
end

--- Click a button safely. Uses Click() which routes through the WoW frame
--- pipeline. Errors from protected functions (e.g. SetTab on Encounter
--- Journal tabs) are caught and suppressed.
--- @param btn        Frame with Click or OnClick
--- @param mouseButton string  default "LeftButton"
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

-- Create a grey circle-X clear button (retail quest log style).
-- Returns the button; caller must set OnClick and OnEnter scripts.
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

-- Pool of (menu, rows) tuples keyed by globalName. We never destroy
-- WoW frames (they persist for the session), but we cycle through pool
-- members so each open uses a freshly-laid-out menu rather than mutating
-- one we just hid. This avoids a class of redraw / state-leak bugs where
-- the second open of a cached menu inherits stale flags from the first
-- close (e.g. backdrop tile dropped by Hide/Show, alpha stuck after
-- click, etc.).
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

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}

    -- Hide any sibling already-shown instance under this globalName so
    -- we never have two cursor menus visible at once.
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
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            self:RegisterEvent("GLOBAL_MOUSE_UP")
        end)
        menu:SetScript("OnHide", function(self)
            self._outsideSince = nil
            self._hasEntered = false
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

    -- Auto-grow width to fit the widest row's label + icon. Use the
    -- caller-provided width as a floor so short menus stay compact.
    -- 8px LEFT pad + label + 4px gap + 14px icon (when present) + 8px
    -- right pad ≈ label + 34.
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
    -- Anchor TOPLEFT to cursor so rows extend down-right like every
    -- standard right-click menu (Windows / macOS / Blizzard's own).
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
        x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    menu:Show()
    return menu
end

function Utils.ShowPinMenu(globalName, isPinned, onPin, onGuide, onAddAlias, opts, extra)
    local rows = {}
    -- Base section: same three rows on every entry, in a fixed order
    -- (Add Alias → Pin → Guide). Each is gated by whether the
    -- underlying action is meaningful for the entry; an unsupported
    -- one is simply omitted rather than shown disabled, but the
    -- relative order of the rows that ARE shown is stable.
    if onAddAlias then
        rows[#rows + 1] = { text = "Add Alias", onClick = onAddAlias }
    end
    rows[#rows + 1] = { text = isPinned and "Unpin" or "Pin", onClick = onPin }
    if onGuide then
        rows[#rows + 1] = { text = "Guide", icon = ns.EYE_ICON_TEX, onClick = onGuide }
    end

    -- Extras section: category-specific actions. Collect into a local
    -- list first so we can decide whether to emit a separator above it.
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

-- ---------------------------------------------------------------------------
-- Addon-wide font selection.
--
-- ns.FONT_CHOICES drives the Options dropdown. Each FontString that opts
-- into user-selectable fonts goes through ns.RegisterAddonFont(fs, weight,
-- sizeOverride, flags) which:
--   1. snapshots the FontString's existing font (path/size/flags) as the
--      "Default" baseline so we can revert without remembering Friz Quadrata
--      paths,
--   2. records the requested addon weight ("regular" / "semibold" / "bold")
--      so non-Default choices know which weight file to load,
--   3. tracks the FontString in a registry,
--   4. immediately applies the current user's choice.
--
-- ns.RefreshAddonFont() re-applies the current EasyFind.db.font to every
-- registered FontString -- call it from the Options selector callback. Modules
-- that want to participate just call RegisterAddonFont after CreateFontString.
-- ---------------------------------------------------------------------------
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
