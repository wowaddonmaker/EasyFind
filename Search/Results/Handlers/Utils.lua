local _, ns = ...

local Handlers = ns.ResultHandlers

-- Hover-dismiss is handled by the highlight's own watcher, which polls
-- _hoverDismissFrame with a read-only IsMouseOver(). It must NEVER be done by
-- hooking the revealed frame: HookScript (and even the bookkeeping field that
-- guarded it) writes EasyFind taint onto a Blizzard button, so the player's
-- next click on it dies in the protected action -- UseToy() on a toy tile,
-- ADDON_ACTION_FORBIDDEN, user-verified. Same poison class as the spellbook
-- render taint in dev/HARDFOUGHT_BATTLES.md.
-- validator (optional): re-checked every highlight tick. Pooled tiles get
-- reused for a different entry when the underlying list changes (the player
-- clears/edits the toy box search), so a validator that confirms the frame
-- still represents the target clears the glow the moment it no longer does.
function Handlers:HighlightRevealedFrame(frame, validator)
    local highlight = frame and ns.RequestGuide() or nil
    if not (frame and highlight and highlight.HighlightFrame) then return false end
    highlight:HighlightFrame(frame, nil, validator)
    return true
end

function Handlers:SetEditBoxTextIfPresent(editBox, text)
    if editBox and editBox.SetText then
        pcall(editBox.SetText, editBox, text or "")
    end
end
