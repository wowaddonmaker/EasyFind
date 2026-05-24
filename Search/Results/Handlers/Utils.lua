local _, ns = ...

local Handlers = ns.ResultHandlers

local function HideHighlightOnHover(frame)
    if not frame or frame._efHideHighlightOnHover or not frame.HookScript then return end
    frame._efHideHighlightOnHover = true
    frame:HookScript("OnEnter", function()
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end)
    if frame.IsMouseOver and frame:IsMouseOver() then
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end
end

function Handlers:HighlightRevealedFrame(frame)
    local highlight = ns.Highlight
    if not (frame and highlight and highlight.HighlightFrame) then return false end
    highlight:HighlightFrame(frame)
    HideHighlightOnHover(frame)
    return true
end

function Handlers:SetEditBoxTextIfPresent(editBox, text)
    if editBox and editBox.SetText then
        pcall(editBox.SetText, editBox, text or "")
    end
end
