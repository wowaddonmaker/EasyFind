local _, ns = ...

-- True clipboard copy from a hovered result row, or any frame carrying
-- _efCopyText (icon grid cells, the What's New changelog link): Ctrl+C
-- over it copies its text (a snippet's whole message, a link's display
-- name, an answer's value, an icon's FileDataID) to the OS clipboard
-- through the shared hidden clipboard box (Utils).
--
-- Arming: Ctrl-down over a copyable target fills, selects, and focuses
-- the hidden box, so the C of the same chord is the native copy,
-- confirmed by a "Copied" flash on the target. Ctrl-down is read from
-- MODIFIER_STATE_CHANGED while nothing has keyboard focus, and from the
-- search box's own key-down while it is focused: a focused EditBox
-- swallows that event entirely (copytrace). Releasing Ctrl (the hidden
-- box's key-up, for the same reason), leaving the target, or hiding the
-- results disarms and returns focus.

local Search = ns.Search
local Utils = ns.Utils
local L = ns.L

local CreateFrame = CreateFrame
local IsControlKeyDown = IsControlKeyDown

local RowCopy = {}
ns.RowCopy = RowCopy

local flashHolder, flashFade, flashText
local armedRow
-- Ctrl+Shift+C: the armed text is the row's EasyFind link instead of its
-- chat link (Raycast's Copy Deeplink chord). Shift is read when arming
-- and re-read on every Shift edge while armed, so either order works.
local armedEasy = false
local hoverTarget
-- Extra copy surfaces (icon grid cells, the What's New link) register a
-- function returning their frame under the mouse, or nil.
local hoverScanners = {}

-- Calculator rows own their richer two-part copy flow. Grid cells and
-- answer rows carry their text outright; everything else copies its send
-- payload as clipboard-safe text (the live link is kept for the chat
-- paste swap).
local function RowPayload(row, easy)
    if not row then return nil end
    if row._efCopyText then return row._efCopyText, nil end
    local data = row.data
    if not data or data.calculatorResult or data.calculatorExpression then return nil end
    if easy and ns.ResultLinks and ns.ResultLinks.BuildShareText then
        local text = ns.ResultLinks:BuildShareText(data)
        if text then return text, nil, true end
    end
    if data.copyText then return data.copyText, nil end
    local link = ns.GetResultLink and ns.GetResultLink(data)
    if not link or link == "" then return nil end
    return Utils.ClipboardSafeText(link), link
end

local function EnsureFlash()
    if flashHolder then return flashHolder end
    flashHolder = CreateFrame("Frame", nil, UIParent)
    flashHolder:SetFrameStrata("TOOLTIP")
    flashHolder:SetSize(80, 16)
    flashHolder:Hide()
    local text = flashHolder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text._efOwnColor = true
    text:SetPoint("CENTER")
    text:SetText(L["COPIED"])
    text:SetTextColor(Utils.RGB(ns.COPIED_COLOR, 1))
    flashText = text
    flashFade = flashHolder:CreateAnimationGroup()
    local alpha = flashFade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetStartDelay(0.7)
    alpha:SetDuration(0.6)
    flashFade:SetScript("OnFinished", function() flashHolder:Hide() end)
    return flashHolder
end

-- The confirmation names what was copied: the two chords differ by one
-- key, and the wording is what tells the user which one landed. Same
-- color either way; the color already means "done".
local function CopiedText()
    return armedEasy and L["COPIED_EASYFIND_LINK"] or L["COPIED"]
end

local function FlashCopied()
    if not (armedRow and armedRow:IsShown()) then return end
    -- A target wearing its own "Ctrl+C" hint text turns that into the
    -- confirmation instead of a floating flash (the hint's owner repaints
    -- it on the next hover).
    local hint = armedRow._efCopyHint
    if hint then
        hint:SetText(CopiedText())
        hint:SetTextColor(Utils.RGB(ns.COPIED_COLOR, 1))
        return
    end
    local holder = EnsureFlash()
    flashFade:Stop()
    flashText:SetText(CopiedText())
    holder:SetSize(math.max(80, math.floor(flashText:GetStringWidth() + 0.5) + 12), 16)
    holder:ClearAllPoints()
    -- Grid cells are square and small: the flash sits over the cell.
    if armedRow._efCopyText then
        holder:SetPoint("CENTER", armedRow, "CENTER", 0, 0)
    else
        holder:SetPoint("RIGHT", armedRow, "RIGHT", -6, 0)
    end
    holder:SetAlpha(1)
    holder:Show()
    flashFade:Play()
end

-- Anything ELSE stealing the hidden box's focus mid-hold loses to the
-- armed copy (the box re-asserts once), so the next Ctrl+C still lands.
-- Keys the focused box would swallow go to the nav frame while it owns
-- the keyboard, so Ctrl+Up/Down jumps keep working mid-hold.
local client = {
    OnCopied = FlashCopied,
    HoldsFocus = function() return armedRow ~= nil and IsControlKeyDown() end,
    OnDisarm = function() armedRow = nil end,
    -- The focused box swallows MODIFIER_STATE_CHANGED; the release
    -- arrives through the box's own key-up instead.
    OnCtrlUp = function() RowCopy:Disarm(true) end,
    OnShift = function(down)
        if armedRow and (down or armedEasy) then RowCopy:ArmFor(armedRow, down) end
    end,
    OnKey = function(key)
        local navFrame = Search.GetNavFrame and Search:GetNavFrame()
        if navFrame and navFrame:IsKeyboardEnabled() then
            local onKeyDown = navFrame:GetScript("OnKeyDown")
            if onKeyDown then onKeyDown(navFrame, key) end
            return
        end
        -- Armed off a focused search box and the key is not the chord:
        -- the user is typing, not copying. Give focus straight back.
        RowCopy:Disarm(true)
    end,
}

function RowCopy:Disarm(restoreFocus)
    if not armedRow then return end
    Utils.DisarmClipboardBox(restoreFocus, client)
end

function RowCopy:CanCopy(row)
    return RowPayload(row) ~= nil
end

function RowCopy:ArmFor(row, easy)
    local payload, link, isEasy = RowPayload(row, easy)
    if not payload then return false end
    -- A menu copy row or one-shot prompt owns the box until it is used
    -- or dismissed; a Ctrl-hover never hijacks it.
    local owner = Utils.ClipboardBoxClient()
    if owner and owner ~= client then return false end
    armedRow, armedEasy = row, isEasy or false
    Utils.ArmClipboardBox(payload, link, client)
    return true
end

-- Click activation of a copyable row arrives with its data, not its row
-- (Handlers:SelectResult); find the rendered row that carries it.
function RowCopy:ArmForData(data)
    local buttons = Search.GetResultButtons and Search:GetResultButtons()
    if not buttons then return false end
    for i = 1, #buttons do
        local row = buttons[i]
        if row and row:IsShown() and row.data == data then
            return self:ArmFor(row, IsShiftKeyDown())
        end
    end
    return false
end

-- Called from the canonical row OnEnter/OnLeave (Rows/Tooltips.lua) and
-- the grid cell hover.
-- CRITICAL: while Ctrl is held, hover-loss must NOT disarm or restore
-- focus. Rows re-render under a stationary cursor (a pending search, an
-- autocomplete settle) and fire OnLeave with the mouse never moving; a
-- disarm-with-refocus here restarted the whole cycle and ate 3-4 chords
-- before one landed. The payload is already captured in the hidden box,
-- so a re-render cannot hurt it; focus returns exactly once, on Ctrl-up
-- (or Escape / stray typing).
function RowCopy:OnRowHover(row)
    hoverTarget = row
    if row then
        if IsControlKeyDown() then
            self:ArmFor(row, IsShiftKeyDown())
        end
    elseif armedRow and not IsControlKeyDown() then
        self:Disarm(true)
    end
end

function RowCopy:RegisterHoverScanner(fn)
    hoverScanners[#hoverScanners + 1] = fn
end

-- The target under the mouse, by GEOMETRY. The enter/leave bookkeeping
-- goes stale exactly when it matters: rows re-render under a stationary
-- cursor (every keystroke, every autocomplete settle) and fire OnLeave
-- with no matching OnEnter, so hoverTarget was nil when Ctrl went down
-- and the first chords did nothing but strip the suffix and unfocus.
local function ResolveHovered()
    if hoverTarget and hoverTarget:IsShown() and hoverTarget:IsMouseOver() then
        return hoverTarget
    end
    local buttons = Search.GetResultButtons and Search:GetResultButtons()
    if buttons then
        for i = 1, #buttons do
            local row = buttons[i]
            if not row or not row:IsShown() then break end
            if row:IsMouseOver() and RowPayload(row) then return row end
        end
    end
    for i = 1, #hoverScanners do
        local target = hoverScanners[i]()
        if target and RowPayload(target) then return target end
    end
    return nil
end

local function ArmHovered()
    local target = ResolveHovered()
    if not target then return end
    hoverTarget = target
    RowCopy:ArmFor(target, IsShiftKeyDown())
end

function RowCopy:Initialize()
    -- Ctrl edges reach this watcher only while no EditBox has keyboard
    -- focus (nav mode, menus, popups); the focused search box is handled
    -- by its own key hook below.
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("MODIFIER_STATE_CHANGED")
    watcher:SetScript("OnEvent", function(_, _, key, state)
        if key == "LSHIFT" or key == "RSHIFT" then
            client.OnShift(state == 1)
            return
        end
        if key ~= "LCTRL" and key ~= "RCTRL" then return end
        if state == 1 then
            ArmHovered()
        else
            RowCopy:Disarm(true)
        end
    end)

    -- While the search box holds focus MODIFIER_STATE_CHANGED is never
    -- delivered (copytrace: both watchers silent while EasyFindSearchBox
    -- had focus, LCTRL arriving only as a key on the box), so Ctrl-down
    -- is read off the box's own key-down and arms before the C of the
    -- same chord lands. The Ctrl+C branch covers a chord whose Ctrl went
    -- down elsewhere. Unfocused, the box still sees keys through WoW's
    -- capture chain; those belong to whoever has focus.
    local searchFrame = Search.GetSearchFrame and Search:GetSearchFrame()
    if searchFrame and searchFrame.editBox then
        searchFrame.editBox:HookScript("OnKeyDown", function(self, key)
            if not self:HasFocus() then return end
            if key == "LCTRL" or key == "RCTRL" or (key == "C" and IsControlKeyDown()) then
                ArmHovered()
            end
        end)
    end
    local resultsFrame = Search.GetResultsFrame and Search:GetResultsFrame()
    if resultsFrame then
        resultsFrame:HookScript("OnHide", function() RowCopy:Disarm(false) end)
    end
end

return RowCopy
