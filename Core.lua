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
EasyFind._ns = ns  -- Expose namespace for dev tools (EasyFindDev)

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
    smartShow = false,         -- Hide search bar until mouse hovers nearby
    resultsTheme = "Retail",  -- "Classic" or "Retail"
    indicatorStyle = "EasyFind Arrow",  -- Indicator texture style
    indicatorColor = "Yellow",  -- Indicator color preset
    maxResults = 10,           -- Maximum number of search results to display (3-24)
    showTruncationMessage = true,  -- Show "more results available" message when truncated
    hardResultsCap = false,    -- Hard cap on results (no "more results" message)
    staticOpacity = false,     -- Keep opacity constant while moving
    pinnedUIItems = {},        -- Pinned UI search results (persist across sessions)
    pinnedMapItems = {},       -- Pinned map search results (persist across sessions)
    pinsCollapsed = false,     -- Whether the "Pinned Paths" header is collapsed
    showLoginMessage = true,   -- Show "EasyFind loaded!" message on login
    blinkingPins = false,      -- Animate (blink/pulse) map pins and highlights
    arrivalDistance = 10,      -- Yards — auto-clear waypoint when player is this close
    uiResultsAbove = false,    -- Show UI search results above the search bar
    mapResultsAbove = false,   -- Show map search results above the search bar
    showMinimapButton = true,  -- Show toggle button on minimap
    minimapButtonAngle = 220,  -- Position angle (degrees) around minimap edge
    globalSearchFilters = {    -- Global search category filters (all enabled by default)
        zones = true,
        dungeons = true,
        raids = true,
        delves = true,
    },
    localSearchFilters = {     -- Local (zone) search category filters (all enabled by default)
        instances = true,
        travel = true,
        services = true,
    },
}

local function OnInitialize()
    if not EasyFindDB then
        EasyFindDB = { firstInstall = true }
    end
    -- Merge defaults — existing values are preserved
    for k, v in pairs(DB_DEFAULTS) do
        if EasyFindDB[k] == nil then
            EasyFindDB[k] = v
        elseif type(v) == "table" and type(EasyFindDB[k]) == "table" then
            -- Sub-merge nested tables so new keys are added to existing tables
            for sk, sv in pairs(v) do
                if EasyFindDB[k][sk] == nil then
                    EasyFindDB[k][sk] = sv
                end
            end
        end
    end

    EasyFind.db = EasyFindDB

    -- Read version from TOC for What's New detection
    ns.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

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
                ns.MapSearch:ClearAll()
                ns.MapSearch:ClearZoneHighlight()
                ns.MapSearch.pendingWaypoint = nil
            end
            EasyFind:Print("Active highlights cleared.")
        elseif msg:find("^test ") then
            -- /ef test Interface\\Path\\To\\Texture
            local texture = msg:match("^test%s+(.+)")
            if texture then
                EasyFind:TestIndicatorTexture(texture)
            else
                EasyFind:Print("Usage: /ef test <texture_path>")
                EasyFind:Print("Example: /ef test Interface\\\\MINIMAP\\\\MiniMap-QuestArrow")
            end
        elseif msg == "setup" then
            if ns.UI then
                EasyFind.db.setupComplete = nil
                ns.UI:ShowFirstTimeSetup()
            end
        elseif msg == "whatsnew" then
            if ns.UI then ns.UI:ShowWhatsNew(ns.version) end
        else
            EasyFind:Print("Usage: /ef show | /ef hide | /ef clear | /ef options")
        end
    end

    if EasyFind.db.showLoginMessage ~= false then
        EasyFind:Print("EasyFind loaded! Use /ef o to open options.")
    end
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

    -- Minimap button (delayed slightly so Minimap frame is ready)
    C_Timer.After(0.6, function()
        if EasyFind.db.showMinimapButton then
            EasyFind:UpdateMinimapButton()
        end
    end)

    -- What's New popup: show once per version for returning users
    local currentVersion = ns.version
    local lastSeen = EasyFind.db.lastSeenVersion
    if currentVersion and currentVersion ~= lastSeen then
        -- Skip for brand-new installs (they get the first-time setup instead)
        if lastSeen ~= nil or EasyFind.db.setupComplete then
            C_Timer.After(1.5, function()
                if ns.UI then ns.UI:ShowWhatsNew(currentVersion) end
            end)
        end
        EasyFind.db.lastSeenVersion = currentVersion
    end
end

-- =============================================================================
-- EVENT DISPATCH — single frame, unregisters after one-time events
-- =============================================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        OnInitialize()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
        self.loginHandled = true
        self:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- arg1 = isInitialLogin, arg2 = isReloadingUI
        -- PLAYER_LOGIN does not fire on UI reloads, so use PLAYER_ENTERING_WORLD
        -- as a fallback to ensure modules initialize after /reload.
        if arg2 and not self.loginHandled then
            OnPlayerLogin()
        end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
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

function EasyFind:TestIndicatorTexture(texturePath)
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
    testFrame.texture:SetVertexColor(1, 1, 0, 1)  -- Yellow like indicators
    testFrame.title:SetText("Testing: " .. texturePath)
    testFrame:Show()
    
    EasyFind:Print("Testing texture: " .. texturePath)
    EasyFind:Print("Close the preview window to dismiss.")
end

-- =============================================================================
-- MINIMAP BUTTON
-- =============================================================================
local minimapButton

-- Minimap shape quadrant table (matches LibDBIcon standard)
local minimapShapes = {
    ["ROUND"]                 = {true, true, true, true},
    ["SQUARE"]                = {false, false, false, false},
    ["CORNER-TOPLEFT"]        = {false, false, false, true},
    ["CORNER-TOPRIGHT"]       = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"]     = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"]    = {true, false, false, false},
    ["SIDE-LEFT"]             = {false, true, false, true},
    ["SIDE-RIGHT"]            = {true, false, true, false},
    ["SIDE-TOP"]              = {false, false, true, true},
    ["SIDE-BOTTOM"]           = {true, true, false, false},
    ["TRICORNER-TOPLEFT"]     = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"]    = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"]  = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function PositionMinimapButton(angle)
    if not minimapButton then return end
    local rad = math.rad(angle)
    local cx, cy = math.cos(rad), math.sin(rad)

    -- Determine quadrant (1-4)
    local q = 1
    if cx < 0 then q = q + 1 end
    if cy > 0 then q = q + 2 end

    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5

    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = minimapShapes[shape] or minimapShapes["ROUND"]

    local x, y
    if quadTable[q] then
        -- Rounded quadrant — place on circle
        x, y = cx * w, cy * h
    else
        -- Squared quadrant — clamp to rectangle edge
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(cx * dw, w))
        y = math.max(-h, math.min(cy * dh, h))
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton then return minimapButton end

    local btn = CreateFrame("Button", "EasyFindMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)

    -- Border overlay (matches LibDBIcon exactly)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture(136430)  -- MiniMap-TrackingBorder
    border:SetPoint("TOPLEFT")

    -- Dark circular background disc
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetTexture(136467)  -- UI-Minimap-Background
    bg:SetPoint("CENTER")

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(136460)  -- INV_Misc_Spyglass_02
    icon:SetPoint("CENTER")

    -- Highlight
    btn:SetHighlightTexture(136477)  -- UI-Minimap-ZoomButton-Highlight

    -- Click behavior
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            EasyFind:ToggleSearchUI()
        elseif button == "RightButton" then
            EasyFind:OpenOptions()
        end
    end)

    -- Drag to reposition around minimap
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.deg(math.atan2(cy - my, cx - mx))
            EasyFind.db.minimapButtonAngle = angle
            PositionMinimapButton(angle)
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("EasyFind")
        GameTooltip:AddLine("Left-click: Toggle search bar", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Open options", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)

    minimapButton = btn
    PositionMinimapButton(EasyFind.db.minimapButtonAngle or 220)
    return btn
end

function EasyFind:UpdateMinimapButton()
    if EasyFind.db.showMinimapButton then
        if not minimapButton then
            CreateMinimapButton()
        end
        minimapButton:Show()
    elseif minimapButton then
        minimapButton:Hide()
    end
end
