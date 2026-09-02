local _, ns = ...

-- True clipboard copy from a hovered result row: Ctrl+C over a row copies
-- its text (a snippet's whole message, a link's display name) to the OS
-- clipboard. WoW has no set-clipboard API; the trick is the calculator's
-- shipped one -- a hidden focused editbox with the payload pre-selected
-- receives the user's HARDWARE Ctrl+C and the client copies natively.
--
-- Arming: holding Ctrl while hovering a copyable row (or pressing Ctrl+C
-- while the search box is focused and a row is hovered) fills, selects,
-- and focuses the hidden box; the next (or same-held) Ctrl+C is the native
-- copy, confirmed by a "Copied" flash on the row. Releasing Ctrl, leaving
-- the row, or hiding the results disarms and returns focus.

local Results = ns.Results
local Utils = ns.Utils
local L = ns.L

local CreateFrame = CreateFrame
local IsControlKeyDown = IsControlKeyDown
local GetCurrentKeyBoardFocus = GetCurrentKeyBoardFocus

local RowCopy = {}
ns.RowCopy = RowCopy

local copyBox, flashHolder, flashFade
local armedRow, armedLink, prevFocus

-- Calculator rows own their richer two-part copy flow; everything else
-- copies its send payload as clipboard-safe text (the live link is kept
-- for the chat paste swap).
local function RowPayload(row)
    local data = row and row.data
    if not data or data.calculatorResult or data.calculatorExpression then return nil end
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
    flashFade = flashHolder:CreateAnimationGroup()
    local alpha = flashFade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetStartDelay(0.7)
    alpha:SetDuration(0.6)
    flashFade:SetScript("OnFinished", function() flashHolder:Hide() end)
    return flashHolder
end

local function FlashCopied()
    if not (armedRow and armedRow:IsShown()) then return end
    local holder = EnsureFlash()
    flashFade:Stop()
    holder:ClearAllPoints()
    holder:SetPoint("RIGHT", armedRow, "RIGHT", -6, 0)
    holder:SetAlpha(1)
    holder:Show()
    flashFade:Play()
end

function RowCopy:Disarm(restoreFocus)
    if not armedRow then return end
    armedRow = nil
    if copyBox then copyBox:ClearFocus() end
    if restoreFocus and prevFocus and prevFocus.SetFocus and prevFocus:IsVisible() then
        prevFocus:SetFocus()
    end
    prevFocus = nil
end

local function EnsureBox()
    if copyBox then return copyBox end
    copyBox = CreateFrame("EditBox", "EasyFindRowCopyBox", UIParent)
    copyBox:SetAutoFocus(false)
    copyBox:SetSize(1, 1)
    copyBox:SetPoint("TOP", UIParent, "TOP", 0, 30)
    copyBox:SetAlpha(0)
    copyBox:EnableMouse(false)
    copyBox:SetScript("OnKeyDown", function(self, key)
        if (key == "C" or key == "c") and IsControlKeyDown() then
            -- This hardware chord IS the native copy: confirm it and pair
            -- the copied text with its live link for the chat paste swap.
            Utils.StashClipboardLink(self:GetText(), armedLink)
            FlashCopied()
        end
    end)
    -- Stray typing means the user wanted their previous editbox: hand
    -- focus straight back rather than eating input.
    copyBox:SetScript("OnChar", function() RowCopy:Disarm(true) end)
    copyBox:SetScript("OnEscapePressed", function() RowCopy:Disarm(true) end)
    copyBox:SetScript("OnEditFocusLost", function()
        -- Deliberate teardowns (Ctrl-up, Escape, stray typing) cleared
        -- armedRow before moving focus. Anything ELSE stealing focus
        -- mid-hold loses to the armed copy: re-assert once so the next
        -- Ctrl+C still lands.
        if armedRow and IsControlKeyDown() then
            local row = armedRow
            Utils.SafeAfter(0, function()
                if armedRow == row and copyBox and IsControlKeyDown() then
                    copyBox:SetFocus()
                    copyBox:HighlightText(0, -1)
                end
            end)
        else
            armedRow = nil
        end
    end)
    return copyBox
end

function RowCopy:ArmFor(row)
    local payload, link = RowPayload(row)
    if not payload then return false end
    local box = EnsureBox()
    if not armedRow then
        local current = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if current and current ~= box then prevFocus = current end
    end
    armedRow, armedLink = row, link
    box:SetText(payload)
    box:SetCursorPosition(0)
    box:HighlightText(0, -1)
    box:SetFocus()
    -- The deferred re-select mirrors the calculator: focus changes settle
    -- one frame late and can drop the selection.
    Utils.SafeAfter(0, function()
        if armedRow ~= row or not copyBox then return end
        if copyBox:GetText() ~= payload then return end
        copyBox:SetFocus()
        copyBox:HighlightText(0, -1)
    end)
    return true
end

-- Called from the canonical row OnEnter/OnLeave (Rows/Tooltips.lua).
-- CRITICAL: while Ctrl is held, hover-loss must NOT disarm or restore
-- focus. Arming steals focus from the search box, whose autocomplete
-- strip re-runs the search and re-renders the rows -- which fires OnLeave
-- with the mouse never moving. Disarm-with-refocus here re-applied the
-- ghost and restarted the cycle, eating 3-4 Ctrl+C presses before one
-- landed. The payload is already captured in the hidden box, so a
-- re-render cannot hurt it; focus returns exactly once, on Ctrl-up (or
-- Escape / stray typing).
function RowCopy:OnRowHover(row)
    if row then
        if IsControlKeyDown() then
            self:ArmFor(row)
        end
    elseif armedRow and not IsControlKeyDown() then
        self:Disarm(true)
    end
end

function RowCopy:Initialize()
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("MODIFIER_STATE_CHANGED")
    watcher:SetScript("OnEvent", function(_, _, key, state)
        if key ~= "LCTRL" and key ~= "RCTRL" then return end
        if state == 1 then
            local hovered = Results and Results._hoverRow
            if hovered and hovered:IsShown() then
                RowCopy:ArmFor(hovered)
            end
        else
            RowCopy:Disarm(true)
        end
    end)

    -- While the search box holds focus, the first Ctrl+C over a hovered
    -- row arms; the next chord (Ctrl still held) is the native copy.
    local searchFrame = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if searchFrame and searchFrame.editBox then
        searchFrame.editBox:HookScript("OnKeyDown", function(_, key)
            if (key == "C" or key == "c") and IsControlKeyDown() then
                local hovered = Results and Results._hoverRow
                if hovered and hovered:IsShown() then
                    RowCopy:ArmFor(hovered)
                end
            end
        end)
    end
    local resultsFrame = ns.Search and ns.Search.GetResultsFrame and ns.Search:GetResultsFrame()
    if resultsFrame then
        resultsFrame:HookScript("OnHide", function() RowCopy:Disarm(false) end)
    end
end

return RowCopy
