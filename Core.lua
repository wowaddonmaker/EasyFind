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

-- Single shared event frame for the entire addon
local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

EasyFind.db = {}

-- SavedVariables defaults — new keys are auto-merged for existing users
local DB_DEFAULTS = {
    visible = true,
    mapIconScale = 1.0,
    uiSearchScale = 1.0,
    mapSearchScale = 1.0,
    searchBarOpacity = 1.0,
    uiSearchPosition = nil,    -- {point, relPoint, x, y}
    mapSearchPosition = nil,   -- x offset from map left edge
    globalSearchPosition = nil, -- x offset from map right edge
    directOpen = false,        -- Open panels directly instead of step-by-step
    navigateToZonesDirectly = false,  -- Clicking a zone goes directly to it
    smartShow = false,         -- Hide search bar until mouse hovers nearby
}

local function OnInitialize()
    if not EasyFindDB then
        EasyFindDB = {}
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
    -- Populate dynamic currencies after a short delay (C_CurrencyInfo needs the character loaded)
    C_Timer.After(2, function()
        if ns.Database then ns.Database:PopulateDynamicCurrencies() end
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
