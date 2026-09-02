local _, ns = ...

-- True clipboard copy from a hovered result row: Ctrl+C over a row copies
-- its text (a snippet's whole message, a link's display name) to the OS
-- clipboard through the shared hidden clipboard box (Utils).
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

local RowCopy = {}
ns.RowCopy = RowCopy

local flashHolder, flashFade
local armedRow

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

-- Anything ELSE stealing the hidden box's focus mid-hold loses to the
-- armed copy (the box re-asserts once), so the next Ctrl+C still lands.
local client = {
    OnCopied = FlashCopied,
    HoldsFocus = function() return armedRow ~= nil and IsControlKeyDown() end,
    OnDisarm = function() armedRow = nil end,
}

function RowCopy:Disarm(restoreFocus)
    if not armedRow then return end
    Utils.DisarmClipboardBox(restoreFocus, client)
end

function RowCopy:ArmFor(row)
    local payload, link = RowPayload(row)
    if not payload then return false end
    -- A one-shot copy prompt (Send > Clipboard, Wowhead) owns the box
    -- until it is used or dismissed; a Ctrl-hover never hijacks it.
    local owner = Utils.ClipboardBoxClient()
    if owner and owner ~= client then return false end
    armedRow = row
    Utils.ArmClipboardBox(payload, link, client)
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
