local _, ns = ...

local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ClickButton = Utils.ClickButton


local CHARACTER_TAB_SUBFRAME = {
    [1] = "PaperDollFrame",
    [2] = "ReputationFrame",
    [3] = "TokenFrame",
}

local SecureCall = Utils.SecureCall

local InCombatLockdown = InCombatLockdown

local function SecureShowUIPanel(frame)
    if not frame or not ShowUIPanel then return false end
    -- Protected panels cannot be shown by insecure code in combat; refuse
    -- only those (capability check, not a category list) so the hard
    -- ADDON_ACTION_BLOCKED path can't fire. Unprotected panels open fine.
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        return false
    end
    return SecureCall(ShowUIPanel, frame)
end

local function IsPlayerSpellsTabSelected(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if not frame then return false end
    if frame.GetTab then
        local currentTab = frame:GetTab()
        if currentTab == tabIndex then return true end
    end
    if tabIndex == 1 and frame.SpecFrame and frame.SpecFrame:IsShown() then
        return true
    elseif tabIndex == 2 and frame.TalentsFrame and frame.TalentsFrame:IsShown() then
        return true
    elseif tabIndex == 2 and ClassTalentFrame and ClassTalentFrame:IsShown() then
        return true
    elseif tabIndex == 3 and frame.SpellBookFrame and frame.SpellBookFrame:IsShown() then
        return true
    end
    return false
end

-- Switching the PlayerSpells tab from addon execution writes the action
-- bars' drag-grid flag tainted (measured: MultiBarBottomLeft.showAllButtons
-- flips the moment the tab is clicked), so NO
-- code path may ClickButton these tabs. Row clicks steer securely on
-- their release edge (Shared/SecureOpeners.lua); when that steer did not
-- land (non-row flows, first-open gaps), highlight the tab so the user's
-- own hardware click does the switch. Returns true when the requested tab
-- is already active (or no specific tab was requested).
local function EnsurePlayerSpellsTab(tabIndex)
    if not tabIndex or IsPlayerSpellsTabSelected(tabIndex) then return true end
    local tab = ns.SecureOpeners
        and ns.SecureOpeners.GetTabButtonFor("playerSpells", tabIndex)
    local highlight = ns.RequestGuide()
    if tab and highlight and highlight.HighlightFrame then
        highlight:HighlightFrame(tab, nil, nil, true)
    end
    return false
end

local function OpenPlayerSpellsFrame(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if not frame and C_AddOns and C_AddOns.LoadAddOn then
        C_AddOns.LoadAddOn("Blizzard_PlayerSpells")
        frame = _G["PlayerSpellsFrame"]
    end
    if not frame then return ClickButton(_G["PlayerSpellsMicroButton"]) end
    if frame:IsShown() and (not tabIndex or IsPlayerSpellsTabSelected(tabIndex)) then
        return true
    end

    -- The Blizzard opener path below reaches TrySetTab -> SetShown, which is
    -- protected on this frame in combat even through securecallfunction
    -- (measured ADDON_ACTION_BLOCKED). Refuse by capability, not category.
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        return false
    end

    -- The tab is switched while the frame is HIDDEN, then the frame is
    -- shown through UIParent's own panel handler, so the spellbook renders
    -- inside the secure show and the highlight-mark globals stay secure
    -- (spellopen probe mode 8, 2026-09-05). Switching the tab on the shown
    -- frame, whether through TogglePlayerSpellsFrame(tab), SetTab or
    -- OpenToSpellBookTab, renders the items under EasyFind taint, and the
    -- next spellbook hover writes the globals from that state: every
    -- action-button hover afterwards trips ADDON_ACTION_BLOCKED (the
    -- Weapon Skills link autopsy). A frame open on another tab is hidden
    -- and reshown, one blink, on the right tab.
    if frame:IsShown() then HideUIPanel(frame) end
    if tabIndex and frame.SetTab then pcall(frame.SetTab, frame, tabIndex) end
    SecureShowUIPanel(frame)
    if frame:IsShown() then return true end
    return ClickButton(_G["PlayerSpellsMicroButton"])
end

local function IsCharacterTabSelected(tabIndex)
    if not tabIndex then return CharacterFrame and CharacterFrame:IsShown() end
    if not (CharacterFrame and CharacterFrame:IsShown()) then return false end
    if PanelTemplates_GetSelectedTab
       and PanelTemplates_GetSelectedTab(CharacterFrame) == tabIndex then
        return true
    end
    if tabIndex == 1 then
        return (PaperDollFrame and PaperDollFrame:IsShown())
            or (CharacterStatsPane and CharacterStatsPane:IsShown())
    elseif tabIndex == 2 then
        return ReputationFrame and ReputationFrame:IsShown()
    elseif tabIndex == 3 then
        return (TokenFrame and TokenFrame:IsShown())
            or (CurrencyFrame and CurrencyFrame:IsShown())
    end
    return false
end

local function OpenCharacterFrame(tabIndex)
    if IsCharacterTabSelected(tabIndex) then return true end

    local subFrame = CHARACTER_TAB_SUBFRAME[tabIndex] or "PaperDollFrame"
    if SecureCall(_G.ToggleCharacter, subFrame) then
        return true
    end

    return ClickButton(_G["CharacterMicroButton"])
end

local function OpenButtonFrame(buttonFrame, nextStep)
    if buttonFrame == "PlayerSpellsMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "PlayerSpellsFrame"
            and nextStep.tabIndex or nil
        return OpenPlayerSpellsFrame(tabIndex)
    elseif buttonFrame == "CharacterMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "CharacterFrame"
            and nextStep.tabIndex or nil
        return OpenCharacterFrame(tabIndex)
    end

    local stepFrame = Utils.GetFrameByPath(buttonFrame) or _G[buttonFrame]
    if stepFrame then return ClickButton(stepFrame) end
    return false
end


function Openers:SecureShowUIPanel(frame)
    return SecureShowUIPanel(frame)
end

-- Enter the in-game Quick Keybind overlay directly, the same as clicking the
-- button in Settings > Keybindings. Returns false (so the caller can fall back
-- to opening that settings category) when in combat or the frame isn't present.
function Openers:ActivateQuickKeybindMode()
    if InCombatLockdown() then return false end
    local frame = _G["QuickKeybindFrame"]
    if not frame then return false end
    SecureShowUIPanel(frame)
    if not frame:IsShown() then
        pcall(frame.Show, frame)
    end
    return frame:IsShown() and true or false
end

function Openers:OpenButtonFrame(buttonFrame, nextStep)
    return OpenButtonFrame(buttonFrame, nextStep)
end

function Openers:EnsurePlayerSpellsTab(tabIndex)
    return EnsurePlayerSpellsTab(tabIndex)
end

function Openers:IsPlayerSpellsTabSelected(tabIndex)
    return IsPlayerSpellsTabSelected(tabIndex)
end

function Openers:OpenPlayerSpellsFrame(tabIndex)
    return OpenPlayerSpellsFrame(tabIndex)
end

function Openers:OpenCharacterFrame(tabIndex)
    return OpenCharacterFrame(tabIndex)
end
