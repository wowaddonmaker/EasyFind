local _, ns = ...

-- The copied-link paste swap (Utils.AttachPasteLinkSwap) is a core feature:
-- a result copied with Ctrl+C and pasted into chat becomes its live link.
-- The snippets companion used to be the only thing attaching it to the
-- chat editboxes, so with that companion disabled the swap silently died.
-- Core attaches it itself now, one frame after login so the companion's
-- own attach (which installs the same idempotent swap after its expansion
-- hook) keeps its established hook order when it is present.

local Utils = ns.Utils

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    Utils.SafeAfter(0, function()
        for i = 1, (NUM_CHAT_WINDOWS or 10) do
            local editBox = _G["ChatFrame" .. i .. "EditBox"]
            if editBox then Utils.AttachPasteLinkSwap(editBox) end
        end
    end)
end)
