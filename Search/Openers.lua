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

local function SecureShowUIPanel(frame)
    if not frame or not ShowUIPanel then return false end
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

local function OpenPlayerSpellsFrame(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if frame and frame:IsShown() then
        return true
    end

    -- Opening PlayerSpellsFrame through the microbutton taints Blizzard's
    -- ShowUIPanel/UIParent path. Call Blizzard's opener through
    -- securecallfunction so later protected panel work, including
    -- CharacterFrame status bars, does not inherit EasyFind taint.
    local util = _G.PlayerSpellsUtil
    if util and SecureCall(util.TogglePlayerSpellsFrame, tabIndex) then
        return true
    end

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

function Openers:OpenButtonFrame(buttonFrame, nextStep)
    return OpenButtonFrame(buttonFrame, nextStep)
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
