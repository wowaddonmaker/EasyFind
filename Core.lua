-- =============================================================================
-- EasyFind Core
-- Entry point: namespace setup, SavedVariables, slash commands, event dispatch.
-- =============================================================================
local ADDON_NAME, ns = ...

local Utils   = ns.Utils
local sformat = Utils.sformat
local pairs   = Utils.pairs

EasyFind = {}
ns.EasyFind = EasyFind

-- Binding localization strings (used by Bindings.xml)
-- category="EasyFind" in Bindings.xml provides the header; no BINDING_HEADER_ global needed.
BINDING_NAME_EASYFIND_TOGGLE = "Toggle UI Search Bar"
BINDING_NAME_EASYFIND_FOCUS  = "Resume Typing in Search Bar"

-- Single shared event frame for the entire addon
local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

EasyFind.db = {}

-- SavedVariables defaults — new keys are auto-merged for existing users
local DB_DEFAULTS = {
    visible = true,
    iconScale = 1.0,
    uiSearchScale = 1.0,
    mapSearchScale = 1.0,
    searchBarOpacity = 1.0,
    uiSearchPosition = nil,    -- {point, relPoint, x, y}
    mapSearchPosition = nil,   -- x offset from map left edge
    globalSearchPosition = nil, -- x offset from map right edge
    directOpen = false,        -- Open panels directly instead of step-by-step
    navigateToZonesDirectly = false,  -- Clicking a zone goes directly to it
    smartShow = true,          -- Hide search bar until mouse hovers nearby
    resultsTheme = "Retail",  -- "Classic" or "Retail"
    arrowStyle = "EasyFind Arrow",  -- Arrow texture style
    arrowColor = "Yellow",  -- Arrow color preset
    maxResults = 12,           -- Maximum number of search results to display (6-24)
    showTruncationMessage = true,  -- Show "more results available" message when truncated
}

local function OnInitialize()
    if not EasyFindDB then
        EasyFindDB = { firstInstall = true }
    end
    -- Merge defaults — existing values are preserved
    for k, v in pairs(DB_DEFAULTS) do
        if EasyFindDB[k] == nil then
            EasyFindDB[k] = v
        end
    end

    EasyFind.db = EasyFindDB

    -- Primary slash command
    SLASH_EASYFIND1 = "/ef"
    SlashCmdList["EASYFIND"] = function(msg)
        msg = msg and msg:lower():trim() or ""
        if msg == "o" or msg == "options" or msg == "config" or msg == "settings" then
            EasyFind:OpenOptions()
        elseif msg == "hide" then
            if ns.UI then ns.UI:Hide() end
        elseif msg == "show" then
            if ns.UI then ns.UI:Show() end
        elseif msg == "clear" then
            if ns.Highlight then
                ns.Highlight:ClearAll()
            end
            if ns.MapSearch then
                ns.MapSearch:ClearHighlight()
                ns.MapSearch:ClearZoneHighlight()
            end
            EasyFind:Print("Active highlights cleared.")
        elseif msg:find("^test ") then
            -- /ef test Interface\\Path\\To\\Texture
            local texture = msg:match("^test%s+(.+)")
            if texture then
                EasyFind:TestArrowTexture(texture)
            else
                EasyFind:Print("Usage: /ef test <texture_path>")
                EasyFind:Print("Example: /ef test Interface\\\\MINIMAP\\\\MiniMap-QuestArrow")
            end
        else
            EasyFind:ToggleSearchUI()
        end
    end

    EasyFind:Print("EasyFind loaded! Use /ef to toggle UI search.")
end

local function OnPlayerLogin()
    C_Timer.After(0.5, function()
        if ns.UI        then ns.UI:Initialize()        end
        if ns.Highlight then ns.Highlight:Initialize() end
        if ns.MapSearch  then ns.MapSearch:Initialize()  end
        if ns.Options    then ns.Options:Initialize()    end
    end)
    -- Populate dynamic currencies and reputations after a short delay (APIs need the character loaded)
    C_Timer.After(2, function()
        if ns.Database then
            ns.Database:PopulateDynamicCurrencies()
            ns.Database:PopulateDynamicReputations()
        end
    end)
end

-- =============================================================================
-- EVENT DISPATCH — single frame, unregisters after one-time events
-- =============================================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        OnInitialize()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- =============================================================================
-- PUBLIC API
-- =============================================================================
function EasyFind:ToggleSearchUI()
    if ns.UI then ns.UI:Toggle() end
end

function EasyFind:FocusSearchUI()
    if ns.UI then ns.UI:Focus() end
end

function EasyFind:OpenOptions()
    if ns.Options then ns.Options:Toggle() end
end

function EasyFind:StartGuide(guideData)
    if ns.Highlight then
        ns.Highlight:StartGuide(guideData)
    end
end

function EasyFind:Print(msg)
    print(sformat("|cFF00FF00EasyFind:|r %s", msg))
end

function EasyFind:TestArrowTexture(texturePath)
    -- Create a test frame to preview the texture
    local testFrame = _G["EasyFindTextureTest"] or CreateFrame("Frame", "EasyFindTextureTest", UIParent, "BackdropTemplate")
    testFrame:SetSize(256, 256)
    testFrame:SetPoint("CENTER")
    testFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    testFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    testFrame:SetBackdropColor(0, 0, 0, 0.9)
    
    if not testFrame.texture then
        testFrame.texture = testFrame:CreateTexture(nil, "ARTWORK")
        testFrame.texture:SetSize(200, 200)
        testFrame.texture:SetPoint("CENTER")
    end
    
    if not testFrame.title then
        testFrame.title = testFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        testFrame.title:SetPoint("TOP", 0, -15)
    end
    
    if not testFrame.closeBtn then
        testFrame.closeBtn = CreateFrame("Button", nil, testFrame, "UIPanelCloseButton")
        testFrame.closeBtn:SetPoint("TOPRIGHT", -5, -5)
    end
    
    -- Try to load the texture
    testFrame.texture:SetTexture(texturePath)
    testFrame.texture:SetVertexColor(1, 1, 0, 1)  -- Yellow like arrows
    testFrame.title:SetText("Testing: " .. texturePath)
    testFrame:Show()
    
    EasyFind:Print("Testing texture: " .. texturePath)
    EasyFind:Print("Close the preview window to dismiss.")
end
