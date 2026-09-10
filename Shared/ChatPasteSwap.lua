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
        -- The game's own copy dialogs (Copy Character Name, and every
        -- other "press Ctrl+C" prompt) are static popups with an edit
        -- box: copies made there count too. Copy only, no paste swap:
        -- these boxes also take names and amounts.
        for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
            local editBox = _G["StaticPopup" .. i .. "EditBox"]
            if editBox then Utils.AttachCopyWatch(editBox) end
        end
    end)
    -- Any other edit box (another addon's copy window, a Blizzard field
    -- made on demand) gets the copy watch the moment it takes keyboard
    -- focus: no way to know every box up front, and a copy needs focus
    -- first. EasyFind's own boxes are excluded (the search box hands
    -- Ctrl+C to the row copy; the hidden clipboard box reports itself).
    local watch = CreateFrame("Frame")
    local lastFocus, elapsed = nil, 0
    watch:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.1 then return end
        elapsed = 0
        local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if focus == lastFocus then return end
        lastFocus = focus
        if not focus or focus._efCopyWatch or focus._efPasteSwap then return end
        if focus.GetObjectType and focus:GetObjectType() ~= "EditBox" then return end
        local name = focus.GetName and focus:GetName()
        if name and name:sub(1, 8) == "EasyFind" then return end
        Utils.AttachCopyWatch(focus)
    end)
end)
