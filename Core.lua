local ADDON_NAME, ns = ...

local Utils   = ns.Utils
local sformat = Utils.sformat
local pairs   = Utils.pairs
local xpcall  = Utils.xpcall
local mmin, mmax = Utils.mmin, Utils.mmax
local mrad, mdeg, matan2, mcos, msin, msqrt = math.rad, math.deg, math.atan2, math.cos, math.sin, math.sqrt
local ErrorHandler = Utils.ErrorHandler

EasyFind = {}
ns.EasyFind = EasyFind
EasyFind._ns = ns  -- Expose namespace for dev tools (EasyFindDev)

BINDING_NAME_EASYFIND_TOGGLE       = "Toggle UI Search Bar"
BINDING_NAME_EASYFIND_FOCUS        = "Resume Typing in Search Bar"
BINDING_NAME_EASYFIND_TOGGLE_FOCUS = "Toggle + Focus Search Bar"
BINDING_NAME_EASYFIND_CLEAR        = "Clear All Highlights"

local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

EasyFind.db = {}

-- SavedVariables version. Increment when changing DB schema.
-- Each migration runs once: if saved dbVersion < DB_VERSION, run all steps in order.
local DB_VERSION = 1

-- SavedVariables defaults - new keys are auto-merged for existing users
local DB_DEFAULTS = {
    dbVersion = DB_VERSION,
    visible = true,
    enableUISearch = true,
    enableMapSearch = true,
    iconScale = 0.8,
    uiSearchScale = 1.0,
    mapSearchScale = 1.0,
    mapSearchWidth = 1.0,
    uiSearchWidth = 1.0,
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
    mapResultsScale = 1.0,
    mapResultsWidth = 1.0,
    searchBarOpacity = 0.75,  -- ns.DEFAULT_OPACITY
    fontSize = 1.0,            -- UI search font size multiplier (0.5-2.0)
    mapFontSize = 1.0,         -- Map search font size multiplier (0.5-2.0)
    uiSearchPosition = nil,    -- {point, relPoint, x, y}
    mapSearchPosition = nil,   -- x offset from map left edge
    globalSearchPosition = nil, -- x offset from map right edge
    directOpen = false,        -- Open panels directly instead of step-by-step
    navigateToZonesDirectly = false,  -- Clicking a zone goes directly to it
    smartShow = false,         -- Hide search bar until mouse hovers nearby
    resultsTheme = "Retail",  -- "Classic" or "Retail"
    indicatorStyle = "EasyFind Arrow",  -- Indicator texture style
    indicatorColor = "Yellow",  -- Indicator color preset
    uiMaxResults = 10,         -- Maximum visible UI search results (3-24)
    mapMaxResults = 6,         -- Maximum visible map search results (3-24)
    showTruncationMessage = true,  -- Show "more results available" message when truncated
    hardResultsCap = false,    -- Hard cap on results (no "more results" message)
    staticOpacity = false,     -- Keep opacity constant while moving
    pinnedUIItems = {},        -- Pinned UI search results (persist across sessions)
    pinnedMapItems = {},       -- Pinned map search results (persist across sessions)
    pinsCollapsed = false,     -- Whether the "Pinned Paths" header is collapsed
    showLoginMessage = true,   -- Show "EasyFind loaded!" message on login
    blinkingPins = false,      -- Pulse map pins and highlights in sync with indicator bob
    arrivalDistance = 10,      -- Yards - auto-clear waypoint when player is this close
    minimapArrowGlow = true,   -- Pulsing glow on minimap perimeter arrow
    minimapGuideCircle = true, -- Near-track ring + arrow around player on minimap
    guideCircleScale = 1.0,    -- Scale multiplier for guide circle ring+arrow
    minimapPinGlow = true,     -- Pulsing glow on map pin when guide circle shrinks onto it
    autoPinClear = true,       -- Auto-clear map pin when player arrives
    autoTrackPins = true,      -- Auto super-track newly placed map pins
    uiResultsAbove = false,    -- Show UI search results above the search bar
    mapResultsAbove = false,   -- Show map search results above the search bar
    panelOpacity = 0.9,        -- Options panel background opacity
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

local DB_MIGRATIONS = {
    -- [1] = Consolidate ad-hoc migrations (maxResults rename, uiResultsWidth reset)
    [1] = function(db)
        if db.maxResults then
            if not db.uiMaxResults then db.uiMaxResults = db.maxResults end
            if not db.mapMaxResults then db.mapMaxResults = db.maxResults end
            db.maxResults = nil
        end
        if db.uiResultsWidth == 1.0 then db.uiResultsWidth = 350 end
    end,
}

-- Fields that are runtime-only and must not persist in SavedVariables
local RUNTIME_FIELDS = {
    "firstInstall",
}

local GITHUB_ISSUES_URL = "https://github.com/wowaddonmaker/EasyFind/issues/new"

local function UrlEncode(str)
    return str:gsub("([^%w%-%.%_%~ ])", function(c)
        return sformat("%%%02X", c:byte())
    end):gsub(" ", "+")
end

local feedbackPopup
local function ShowFeedbackURL(url)
    if not feedbackPopup then
        local popup = CreateFrame("Frame", "EasyFindFeedbackPopup", UIParent, "BackdropTemplate")
        popup:SetSize(460, 100)
        popup:SetPoint("CENTER", 0, 200)
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        popup:SetFrameLevel(100)
        popup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        popup:SetBackdropColor(0, 0, 0, 0.95)

        local label = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOP", 0, -16)
        label:SetText("Press Ctrl+C to copy, then paste in your browser:")

        local editBox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
        editBox:SetSize(400, 20)
        editBox:SetPoint("TOP", label, "BOTTOM", 0, -8)
        editBox:SetAutoFocus(false)
        editBox:SetJustifyH("LEFT")
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); popup:Hide() end)
        popup.editBox = editBox

        local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -5, -5)

        popup:EnableMouse(true)
        feedbackPopup = popup
    end
    feedbackPopup:Show()
    feedbackPopup.editBox:SetText(url)
    feedbackPopup.editBox:SetCursorPosition(0)
    feedbackPopup.editBox:SetFocus()
    feedbackPopup.editBox:HighlightText()
end

local function OpenBugReport()
    local version = ns.version or "unknown"
    local url = GITHUB_ISSUES_URL .. "?template=bug_report.yml&version=" .. UrlEncode(version)
    ShowFeedbackURL(url)
end

local function OpenFeatureRequest()
    local url = GITHUB_ISSUES_URL .. "?template=feature_request.yml"
    ShowFeedbackURL(url)
end

function EasyFind:OpenBugReport() OpenBugReport() end
function EasyFind:OpenFeatureRequest() OpenFeatureRequest() end

local function OnInitialize()
    if not EasyFindDB then
        EasyFindDB = { firstInstall = true }
    end
    for k, v in pairs(DB_DEFAULTS) do
        if EasyFindDB[k] == nil then
            EasyFindDB[k] = v
        elseif type(v) == "table" and type(EasyFindDB[k]) == "table" then
            for sk, sv in pairs(v) do
                if EasyFindDB[k][sk] == nil then
                    EasyFindDB[k][sk] = sv
                end
            end
        end
    end

    -- Run sequential migrations
    local savedVersion = EasyFindDB.dbVersion or 0
    for v = savedVersion + 1, DB_VERSION do
        if DB_MIGRATIONS[v] then
            DB_MIGRATIONS[v](EasyFindDB)
        end
    end
    EasyFindDB.dbVersion = DB_VERSION

    -- Reset values whose type doesn't match the default
    for k, v in pairs(EasyFindDB) do
        local default = DB_DEFAULTS[k]
        if default ~= nil and type(v) ~= type(default) then
            EasyFindDB[k] = default
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
            EasyFind:ClearAll()
        elseif msg:find("^test ") then
            -- /ef test Interface\\Path\\To\\Texture
            local texture = msg:match("^test%s+(.+)")
            if texture then
                EasyFind:TestIndicatorTexture(texture)
            else
                EasyFind:Print("Usage: /ef test <texture_path>")
                EasyFind:Print("Example: /ef test Interface\\\\MINIMAP\\\\MiniMap-QuestArrow")
            end
        elseif msg == "noborder" then
            local sf = _G["EasyFindSearchFrame"]
            if sf then
                ns.SetSearchBorderShown(sf, false)
                sf:SetBackdrop(nil)
                EasyFind:Print("Border hidden - /reload to restore")
            end
        elseif msg == "reset" then
            if ns.Options then
                ns.Options:Initialize()
                StaticPopup_Show("EASYFIND_RESET_ALL")
            end
        elseif msg == "bug" then
            OpenBugReport()
        elseif msg == "feature" then
            OpenFeatureRequest()
        elseif msg == "setup" then
            if ns.UI then
                EasyFind.db.setupComplete = nil
                ns.UI:ShowFirstTimeSetup()
            end
        elseif msg == "whatsnew" then
            if ns.UI then ns.UI:ShowWhatsNew(ns.version) end
        else
            EasyFind:Print("Usage: /ef show | hide | clear | options | reset | bug | feature")
        end
    end

    if EasyFind.db.showLoginMessage ~= false then
        EasyFind:Print("EasyFind loaded. Use /ef o to open options. (Disable this message in General settings.)")
    end
end

local SafeAfter = Utils.SafeAfter

local function OnPlayerLogin()
    SafeAfter(0.5, function()
        local function SafeInit(mod, name)
            if not mod then return end
            local ok, err = xpcall(mod.Initialize, ErrorHandler, mod)
            if not ok then
                EasyFind:Print("|cffff4444" .. name .. " failed to initialize: " .. tostring(err) .. "|r")
            end
        end
        if EasyFind.db.enableUISearch ~= false then
            SafeInit(ns.UI,        "UI")
            SafeInit(ns.Highlight, "Highlight")
        end
        if EasyFind.db.enableMapSearch ~= false then
            SafeInit(ns.MapSearch,  "MapSearch")
        end
        SafeInit(ns.Options,    "Options")
    end)
    -- Populate dynamic currencies and reputations after a short delay (APIs need the character loaded)
    SafeAfter(2, function()
        if ns.Database then
            ns.Database:PopulateDynamicCurrencies()
            ns.Database:PopulateDynamicReputations()
        end
    end)

    -- Minimap button (delayed slightly so Minimap frame is ready)
    SafeAfter(0.6, function()
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
            SafeAfter(1.5, function()
                if ns.UI then ns.UI:ShowWhatsNew(currentVersion) end
            end)
        end
        EasyFind.db.lastSeenVersion = currentVersion
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
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
    elseif event == "PLAYER_LOGOUT" then
        -- Strip runtime-only fields before SavedVariables serialization
        if EasyFindDB then
            for _, field in ipairs(RUNTIME_FIELDS) do
                EasyFindDB[field] = nil
            end
        end
    end
end)

function EasyFind:ToggleSearchUI()
    if ns.UI then ns.UI:Toggle() end
end

function EasyFind:FocusSearchUI()
    if ns.UI then ns.UI:Focus() end
end

function EasyFind:ToggleFocusSearchUI()
    if WorldMapFrame and WorldMapFrame:IsShown() and ns.MapSearch then
        ns.MapSearch:FocusLocalSearch()
    elseif ns.UI then
        ns.UI:ToggleFocus()
    end
end

function EasyFind:OpenOptions()
    if ns.Options then ns.Options:Toggle() end
end

function EasyFind:ClearAll()
    if ns.Highlight then
        ns.Highlight:ClearAll()
    end
    if ns.MapSearch then
        ns.MapSearch:ClearAll()
        ns.MapSearch:ClearZoneHighlight()
        ns.MapSearch.pendingWaypoint = nil
    end
    EasyFind:Print("Active highlights cleared.")
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
    testFrame.texture:SetVertexColor(ns.YELLOW_HIGHLIGHT[1], ns.YELLOW_HIGHLIGHT[2], ns.YELLOW_HIGHLIGHT[3], 1)
    testFrame.title:SetText("Testing: " .. texturePath)
    testFrame:Show()
    
    EasyFind:Print("Testing texture: " .. texturePath)
    EasyFind:Print("Close the preview window to dismiss.")
end

local minimapButton

-- Minimap shape quadrant table for non-round minimap support
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
    local rad = mrad(angle)
    local cx, cy = mcos(rad), msin(rad)

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
        -- Rounded quadrant - place on circle
        x, y = cx * w, cy * h
    else
        -- Squared quadrant - clamp to rectangle edge
        local dw = msqrt(2 * w * w) - 10
        local dh = msqrt(2 * h * h) - 10
        x = mmax(-w, mmin(cx * dw, w))
        y = mmax(-h, mmin(cy * dh, h))
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton then return minimapButton end

    local mmBtn = CreateFrame("Button", "EasyFindMinimapButton", Minimap)
    mmBtn:SetSize(31, 31)
    mmBtn:SetFrameStrata("MEDIUM")
    mmBtn:SetFrameLevel(8)

    local border = mmBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture(136430)
    border:SetPoint("TOPLEFT")

    local background = mmBtn:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(136467)
    background:SetPoint("CENTER")

    local icon = mmBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetTexture(136460)
    icon:SetPoint("CENTER")

    mmBtn:SetHighlightTexture(136477)

    mmBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mmBtn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            EasyFind:ToggleSearchUI()
        elseif button == "RightButton" then
            EasyFind:OpenOptions()
        end
    end)

    mmBtn:RegisterForDrag("LeftButton")
    mmBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = mdeg(matan2(cy - my, cx - mx))
            EasyFind.db.minimapButtonAngle = angle
            PositionMinimapButton(angle)
        end)
    end)
    mmBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    mmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("EasyFind")
        GameTooltip:AddLine("Left-click: Toggle search bar", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Open options", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    mmBtn:SetScript("OnLeave", GameTooltip_Hide)

    minimapButton = mmBtn
    PositionMinimapButton(EasyFind.db.minimapButtonAngle or 220)
    return mmBtn
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

-- Addon compartment button (## AddonCompartmentFunc in TOC)
function EasyFind_OnAddonCompartmentClick(_, button)
    if button == "LeftButton" then
        EasyFind:ToggleSearchUI()
    else
        EasyFind:OpenOptions()
    end
end
