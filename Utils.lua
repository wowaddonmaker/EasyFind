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
        if #typedText > prevLen
           and currentCandidate and typedText ~= ""
           and #typedText < #currentCandidate
           and slower(typedText) == slower(ssub(currentCandidate, 1, #typedText)) then
            smoothExtendDone = RenderCandidate(currentCandidate)
        else
            currentCandidate = nil
            self:HighlightText(0, 0)
        end
        if onTypedChanged then onTypedChanged(self, typedText, prevText, grew) end
    end)

    editBox:HookScript("OnChar", function(self, char)
        if not currentCandidate or not char or char == "" then return end
        local current = self:GetText() or ""
        if current == currentCandidate then return end
        local cursorPos = self:GetCursorPosition() or #current
        local typed = ssub(current, 1, cursorPos)
        if #typed <= #typedText then return end
        local candidatePrefix = ssub(currentCandidate, 1, #typed)
        if slower(typed) ~= slower(candidatePrefix) then
            currentCandidate = nil
            self:HighlightText(0, 0)
            return
        end

        local prevText = typedText
        typedText = candidatePrefix
        if not RenderCandidate(currentCandidate) then return end
        smoothExtendDone = true
        if onTypedChanged then
            charDispatchedTyped = typedText
            if C_Timer then
                C_Timer.After(0, function()
                    charDispatchedTyped = nil
                end)
            end
            onTypedChanged(self, typedText, prevText, true)
        end
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
    local MIN_THUMB_H = 20
    local TRACK_PAD = 2
    local VERT_PAD  = 4

    -- Query native atlas sizes so we never hardcode sprite dimensions
    local arrowInfo = C_Texture.GetAtlasInfo("minimal-scrollbar-arrow-top")
    local trackCapInfo = C_Texture.GetAtlasInfo("minimal-scrollbar-track-top")
    local ARROW_W = arrowInfo and arrowInfo.width or 17
    local ARROW_H = arrowInfo and arrowInfo.height or 11
    local BAR_W = trackCapInfo and trackCapInfo.width or 6

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(ARROW_W)
    bar:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)
    bar:SetFrameStrata(parent:GetFrameStrata())
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)

    local function UpdateBarHeight()
        bar:SetHeight(scrollFrame:GetHeight() - VERT_PAD * 2)
    end
    bar.UpdateBarHeight = UpdateBarHeight
    UpdateBarHeight()

    -- Up arrow
    local backBtn = CreateFrame("Button", nil, bar)
    backBtn:SetSize(ARROW_W, ARROW_H)
    backBtn:SetPoint("TOP", bar, "TOP", 0, 0)
    local backTex = backBtn:CreateTexture(nil, "BACKGROUND")
    backTex:SetAtlas("minimal-scrollbar-arrow-top", true)
    backTex:SetPoint("CENTER")
    backBtn:SetScript("OnEnter", function() backTex:SetAtlas("minimal-scrollbar-arrow-top-over", true) end)
    backBtn:SetScript("OnLeave", function() backTex:SetAtlas("minimal-scrollbar-arrow-top", true) end)
    backBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        scrollFrame:SetVerticalScroll(mmax(0, cur - 24))
    end)

    -- Down arrow
    local fwdBtn = CreateFrame("Button", nil, bar)
    fwdBtn:SetSize(ARROW_W, ARROW_H)
    fwdBtn:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    local fwdTex = fwdBtn:CreateTexture(nil, "BACKGROUND")
    fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom", true)
    fwdTex:SetPoint("CENTER")
    fwdBtn:SetScript("OnEnter", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom-over", true) end)
    fwdBtn:SetScript("OnLeave", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom", true) end)
    fwdBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        local range = scrollFrame:GetVerticalScrollRange()
        scrollFrame:SetVerticalScroll(mmin(range, cur + 24))
    end)

    -- Track fills the bar width so track center = arrow center
    local track = CreateFrame("Frame", nil, bar)
    track:SetPoint("TOPLEFT", backBtn, "BOTTOMLEFT", 0, -TRACK_PAD)
    track:SetPoint("BOTTOMRIGHT", fwdBtn, "TOPRIGHT", 0, TRACK_PAD)

    local trackTopTex = track:CreateTexture(nil, "BACKGROUND")
    trackTopTex:SetAtlas("minimal-scrollbar-track-top", true)
    trackTopTex:SetPoint("TOP")

    local trackBotTex = track:CreateTexture(nil, "BACKGROUND")
    trackBotTex:SetAtlas("minimal-scrollbar-track-bottom", true)
    trackBotTex:SetPoint("BOTTOM")

    local trackMidTex = track:CreateTexture(nil, "BACKGROUND")
    trackMidTex:SetAtlas("!minimal-scrollbar-track-middle", true)
    trackMidTex:SetPoint("TOP", trackTopTex, "BOTTOM")
    trackMidTex:SetPoint("BOTTOM", trackBotTex, "TOP")

    -- Thumb (draggable, same width as track)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)

    local thumbTopTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top", true)
    thumbTopTex:SetPoint("TOP")

    local thumbBotTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom", true)
    thumbBotTex:SetPoint("BOTTOM")

    local thumbMidTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle", true)
    thumbMidTex:SetPoint("TOP", thumbTopTex, "BOTTOM")
    thumbMidTex:SetPoint("BOTTOM", thumbBotTex, "TOP")

    local function SetThumbNormal()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top", true)
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom", true)
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle", true)
    end
    local function SetThumbOver()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top-over", true)
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom-over", true)
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle-over", true)
    end

    thumb:SetScript("OnEnter", SetThumbOver)
    thumb:SetScript("OnLeave", function()
        if not bar.isDragging then SetThumbNormal() end
    end)

    -- Thumb dragging
    bar.isDragging = false
    bar.dragOffset = 0

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = true
        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        bar.dragOffset = cursorY / scale - self:GetTop()
        SetThumbOver()
    end)

    thumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = false
        if not self:IsMouseOver() then SetThumbNormal() end
    end)

    bar:SetScript("OnUpdate", function(self)
        if not self.isDragging then return end
        -- Mouse-up can fire outside the thumb (drag off the edge, release
        -- on another frame). The thumb's OnMouseUp doesn't fire then, so
        -- detect button release here and end the drag.
        if not IsMouseButtonDown("LeftButton") then
            self.isDragging = false
            if not thumb:IsMouseOver() then SetThumbNormal() end
            return
        end
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end

        local _, cursorY = GetCursorPosition()
        local scale = track:GetEffectiveScale()
        cursorY = cursorY / scale

        local trackT = track:GetTop()
        local thumbH = thumb:GetHeight()
        local travel = track:GetHeight() - thumbH
        if travel <= 0 then return end

        local pos = trackT - (cursorY - self.dragOffset)
        local ratio = mmax(0, mmin(1, pos / travel))
        scrollFrame:SetVerticalScroll(ratio * range)
    end)

    -- Click track to jump
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
        scrollFrame:SetVerticalScroll(mmax(0, mmin(range, ratio * range)))
    end)

    -- Update thumb position and size from current scroll state.
    -- Optional explicit contentH/viewH avoid layout-timing issues on first render.
    -- Values are cached so deferred calls (OnShow) can reuse them.
    bar._contentH = nil
    bar._viewH = nil

    function bar:UpdateThumb(contentH, viewH)
        self:UpdateBarHeight()
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

    -- Sync thumb when scroll position changes
    scrollFrame:SetScript("OnVerticalScroll", function()
        bar:UpdateThumb()
    end)

    -- Mouse wheel on the scrollbar itself
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta)
        local range = scrollFrame:GetVerticalScrollRange()
        local cur = scrollFrame:GetVerticalScroll()
        scrollFrame:SetVerticalScroll(mmax(0, mmin(range, cur - delta * 72)))
    end)

    -- Recompute bar height and thumb on show so layout matches current frame size
    bar:SetScript("OnShow", function(self)
        self:UpdateBarHeight()
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

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}
    local menu = _G[globalName]
    if not menu then
        menu = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
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
                    self.rows[i]:Hide()
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
    end

    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    menu:SetFrameLevel(opts.level or 10000)
    menu:SetToplevel(opts.toplevel ~= false)
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
                row = CreateFrame("Button", nil, UIParent)
                row:EnableMouse(true)
                row:SetHeight(rowH)
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.icon = row:CreateTexture(nil, "OVERLAY")
                row.icon:SetSize(14, 14)
                row.icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                menu.rows[shown] = row
            end
            row:SetParent(UIParent)
            row:SetFrameStrata(menu:GetFrameStrata())
            row:SetHeight(rowH)
            row:SetFrameLevel(menu:GetFrameLevel() + 20 + shown)
            row.label:SetText(def.text or "")
            if def.icon then
                row.icon:SetTexture(def.icon)
                row.icon:Show()
            else
                row.icon:Hide()
            end
            local onClick = def.onClick
            row:SetScript("OnMouseDown", function(_, button)
                if button ~= "LeftButton" then return end
                menu:Hide()
                if onClick then onClick() end
            end)
            row:SetScript("OnClick", nil)
            row:ClearAllPoints()
            if shown == 1 then
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4)
                row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -4)
            else
                row:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, 0)
                row:SetPoint("TOPRIGHT", lastRow, "BOTTOMRIGHT", 0, 0)
            end
            row:Show()
            if row.Raise then row:Raise() end
            lastRow = row
        end
    end
    for i = shown + 1, #menu.rows do
        menu.rows[i]:Hide()
        menu.rows[i]:SetScript("OnClick", nil)
        menu.rows[i]:SetScript("OnMouseDown", nil)
    end

    menu:SetSize(width, rowH * shown + 8)
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    menu:ClearAllPoints()
    menu:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    menu:Show()
    return menu
end

function Utils.ShowPinMenu(globalName, isPinned, onPin, onGuide, onAddAlias, opts)
    local rows = {}
    if onGuide then
        rows[#rows + 1] = { text = "Guide", icon = ns.EYE_ICON_TEX, onClick = onGuide }
    end
    rows[#rows + 1] = { text = isPinned and "Unpin" or "Pin", onClick = onPin }
    if onAddAlias then
        rows[#rows + 1] = { text = "Add Alias", onClick = onAddAlias }
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
