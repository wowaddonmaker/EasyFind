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
EasyFind._ns = ns

local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

EasyFind.db = {}

-- Increment when DB schema changes; migrations [N] run when savedVersion < N.
local DB_VERSION = 17
local REVAMPED_TUTORIAL_VERSION = "2.0.0"
ns.REVAMPED_TUTORIAL_VERSION = REVAMPED_TUTORIAL_VERSION

local DB_DEFAULTS = {
    dbVersion = DB_VERSION,
    visible = true,
    enableMapSearch = true,
    iconScale = 0.8,
    nativePinScale = 1.5,
    uiSearchScale = 1.0,
    uiSearchWidth = 1.54,
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
    uiSearchBarHeight = ns.SEARCHBAR_HEIGHT or 30,
    fontSize = 0.9,
    uiSearchPosition = nil,
    localMapDirectOpen = true,
    globalMapDirectOpen = true,
    autoHide = true,
    smartShow = false,
    lockPosition = false,
    tutorialDone = false,
    accountKeybinds = {},
    resultsTheme = "Modern",
    font = "Default",
    indicatorStyle = "EasyFind Arrow",
    indicatorColor = "Yellow",
    uiResultsHeight = 280,
    showTruncationMessage = true,
    hardResultsCap = false,
    pinnedUIItems = {},
    pinnedUIItemsPerChar = {},
    pinnedMapItems = {},
    mapPinsCollapsed = false,
    showLoginMessage = false,
    showAliasMessages = true,
    blinkingPins = false,
    mapPinHighlight = true,
    autoPinClear = true,
    autoTrackPins = true,
    uiResultsAbove = false,
    showResultShortcutHints = true,
    showMinimapButton = true,
    minimapButtonAngle = 200,
    globalSearchFilters = {
        zones = true,
        dungeons = true,
        raids = true,
        delves = true,
    },
    localSearchFilters = {
        instances = true,
        travel = true,
        services = true,
        rares = true,
    },
    mapTabFilters = {
        zones = true,
        instances = true,
        flightpath = false,
        travel = true,
        services = true,
        rares = true,
    },
    mapTabRecentSearches = {},
    mapTabShowRecent = true,
    mapTabRecentCount = 3,
    mapTabAutoExpand = true,
    alwaysShowRares = false,
    uiSearchFilters = {
        achievements   = true,
        statistics     = false,
        currencies     = true,
        reputations    = true,
        collections    = true,
        gameOptions    = true,
        addonOptions   = true,
        mounts         = true,
        toys           = true,
        pets           = true,
        outfits        = true,
        heirlooms      = true,
        loot           = true,
        appearanceSets = true,
        bags           = true,
        macros         = true,
        options        = true,
        abilities      = true,
        bosses         = true,
        gearSets       = true,
        talents        = true,
        titles         = true,
        map            = true,
    },
    lootSpecs = nil,
    lootSearchSlots = true,
    lootSearchStats = true,
    lootUpgradesOnly = false,
    lootDifficulty = "normal",
    mountFilterCollected = true,
    mountFilterNotCollected = false,
    mountFilterUnusable = false,
    mountTypeGround = true,
    mountTypeFlying = true,
    mountTypeAquatic = true,
    mountTypeRideAlong = true,
    mountSourceFilters = {},
    hideTooltips = {
        collections = false,
        loot        = false,
    },
    currencyFilterMode = "all",
    reputationFilterMode = "all",
    achievementFilterMode = "all",
    hideAchievementHeaders = true,
    hideGuildAchievements = true,
    showLegacyReputations = false,
    abilityHidePassives = false,
    appearanceSetClass = nil,
    appearanceSetCollected = true,
    appearanceSetNotCollected = true,
    appearanceSetPvE = true,
    appearanceSetPvP = true,
    uiMapSearchLocal = true,
    aliases = {},
    uiSearchHistory = {},
    uiSearchHistoryLimit = 500,
}

local function RequireRevampedTutorial(db)
    if db.revampedTutorialVersion ~= REVAMPED_TUTORIAL_VERSION then
        db.tutorialDone = false
        db.lastSeenVersion = REVAMPED_TUTORIAL_VERSION
    end
end

local function CloneDefaultValue(value)
    if type(value) ~= "table" then return value end

    local copy = {}
    for k, v in pairs(value) do
        copy[k] = CloneDefaultValue(v)
    end
    return copy
end

-- Keys preserved across the 2.0 settings reset; all others restored to defaults.
local PRESERVED_KEYS = {
    dbVersion = true,
    tutorialDone = true,
    mapTabRecentSearches = true,
    aliases = true,
    uiSearchHistory = true,
    uiSearchHistoryLimit = true,
}

local RETIRED_SETTINGS_KEYS = {
    "enableUISearch",
    "mapSearchScale",
    "mapSearchWidth",
    "mapResultsScale",
    "mapResultsWidth",
    "mapFontSize",
    "mapResultsHeight",
    "mapResultsAbove",
    "mapSearchPosition",
    "globalSearchPosition",
    "mapSearchPositionMax",
    "globalSearchPositionMax",
    "mapSearchYOffset",
    "hideSearchBarsMaximized",
    "directOpen",
    "mapSmartShow",
    "pinsCollapsed",
    "arrivalDistance",
    "minimapArrowGlow",
    "glowOnlyEasyFind",
    "minimapGuideCircle",
    "circleOnlyEasyFind",
    "guideCircleScale",
    "minimapPinGlow",
    "panelOpacity",
    "searchBarOpacity",
    "staticOpacity",
    "suggestedKeybindsApplied",
    "optionsPosition",
    "lootFilter",
}

local function ApplyFreshSettingsFor2(db)
    for key, defaultValue in pairs(DB_DEFAULTS) do
        if not PRESERVED_KEYS[key] then
            db[key] = CloneDefaultValue(defaultValue)
        end
    end

    for i = 1, #RETIRED_SETTINGS_KEYS do
        db[RETIRED_SETTINGS_KEYS[i]] = nil
    end

    RequireRevampedTutorial(db)
end

local DB_MIGRATIONS = {
    [1] = function(db)
        if db.maxResults then
            if not db.uiMaxResults then db.uiMaxResults = db.maxResults end
            if not db.mapMaxResults then db.mapMaxResults = db.maxResults end
            db.maxResults = nil
        end
        if db.uiResultsWidth == 1.0 then db.uiResultsWidth = 300 end
    end,
    [2] = function(db)
        if db.uiResultsWidth == 300 then db.uiResultsWidth = 350 end
    end,
    [3] = function(db)
        if not db.uiResultsHeight then
            db.uiResultsHeight = db.uiMaxResults and (db.uiMaxResults * 28) or 280
        end
        db.uiMaxResults = nil
        db.mapMaxResults = nil
    end,
    [4] = function(db)
        local w = db.uiSearchWidth
        if w == nil or w <= 0.88 then
            db.uiSearchWidth = 1.54
        end
    end,
    [5] = function(db)
        if db.localMapDirectOpen == false then db.localMapDirectOpen = true end
        if db.globalMapDirectOpen == false then db.globalMapDirectOpen = true end
    end,
    [6] = function(db)
        if db.mapTabFilters and db.mapTabFilters.flightpath == nil then
            db.mapTabFilters.flightpath = false
        end
    end,
    [8] = function(db)
        if db.resultsTheme == "Retail" or db.resultsTheme == "Classic" then
            db.resultsTheme = "Modern"
        end
    end,
    [9] = function(db)
        db.panelOpacity = nil
    end,
    [10] = function(db)
        if not db.uiSearchBarHeight then db.uiSearchBarHeight = ns.SEARCHBAR_HEIGHT or 30 end
    end,
    [11] = function(db)
        RequireRevampedTutorial(db)
    end,
    [12] = function(db)
        db.searchBarOpacity = nil
    end,
    [13] = function(db)
        RequireRevampedTutorial(db)
    end,
    [14] = function(db)
        db.staticOpacity = nil
        db.searchBarOpacity = nil
        db.suggestedKeybindsApplied = nil
        if db.mapTabFilters then
            db.mapTabFilters.flightpath = false
        end
    end,
    [15] = function(db)
        db.showLoginMessage = false
    end,
    [16] = function(db)
        if db.tutorialDone == true
           and db.lastSeenVersion == REVAMPED_TUTORIAL_VERSION
           and db.revampedTutorialVersion ~= REVAMPED_TUTORIAL_VERSION then
            db.revampedTutorialVersion = REVAMPED_TUTORIAL_VERSION
        end
    end,
    [17] = function(db)
        ApplyFreshSettingsFor2(db)
    end,
}

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
    local savedVersion = EasyFindDB.dbVersion or 0
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

    for v = savedVersion + 1, DB_VERSION do
        if DB_MIGRATIONS[v] then
            DB_MIGRATIONS[v](EasyFindDB)
        end
    end
    EasyFindDB.dbVersion = DB_VERSION

    for k, v in pairs(EasyFindDB) do
        local default = DB_DEFAULTS[k]
        if default ~= nil and type(v) ~= type(default) then
            EasyFindDB[k] = default
        end
    end

    EasyFind.db = EasyFindDB

    ns.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

    SLASH_EASYFIND1 = "/ef"
    SlashCmdList["EASYFIND"] = function(msg)
        msg = msg and msg:lower():trim() or ""
        if msg == "o" or msg == "options" or msg == "config" or msg == "settings" then
            EasyFind:OpenOptions()
        elseif msg == "toggle" or msg == "t" then
            EasyFind:EnsureDynamicLoaded()
            if ns.UI then ns.UI:Toggle() end
        elseif msg == "c" or msg == "clear" then
            EasyFind:ClearAll()
        elseif msg:find("^test ") then
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
        elseif msg == "r" or msg == "reset" then
            if ns.Options then
                ns.Options:Initialize()
                StaticPopup_Show("EASYFIND_RESET_ALL")
            end
        elseif msg == "bug" then
            OpenBugReport()
        elseif msg == "feature" then
            OpenFeatureRequest()
        elseif msg == "setup" or msg == "tutorial" or msg == "wizard" or msg == "welcome" then
            if ns.Wizard and ns.Wizard.Show then
                EasyFind.db.tutorialDone = false
                ns.Wizard:Show()
            end
        elseif msg == "perf" then
            ns.PERF = not ns.PERF
            EasyFind:Print("Perf logging " .. (ns.PERF and "ON" or "OFF"))
            if ns.PERF and ns.UI then
                EasyFind:Print(string.format(
                    "Render so far: %d skipped, %d ran",
                    ns.UI._renderSkips or 0, ns.UI._renderRuns or 0))
            end
        elseif msg == "test" or msg == "perftest" then
            if ns.Perf and ns.Perf.Run then
                ns.Perf:Run()
            else
                EasyFind:Print("Perf module not loaded")
            end
        elseif msg == "ejdump" then
            local info = _G["EncounterJournalEncounterFrameInfo"]
            if not info then print("No EncounterJournalEncounterFrameInfo"); return end
            print("--- EJ Loot Container Dump ---")
            local lc = info.LootContainer
            print("LootContainer: " .. tostring(lc) .. " shown:" .. tostring(lc and lc:IsShown()))
            if lc then
                local sb = lc.ScrollBox
                print("  .ScrollBox: " .. tostring(sb))
                if sb then
                    print("  .ScrollBox:IsShown(): " .. tostring(sb:IsShown()))
                    print("  has EnumerateFrames: " .. tostring(sb.EnumerateFrames ~= nil))
                    if sb.EnumerateFrames then
                        local count = 0
                        for _, btn in sb:EnumerateFrames() do
                            count = count + 1
                            local text = ns.Utils.GetButtonText(btn)
                            print("    [" .. count .. "] " .. tostring(text) .. " shown:" .. tostring(btn:IsShown()))
                        end
                        print("  total frames: " .. count)
                    end
                    local st = sb.ScrollTarget
                    print("  .ScrollTarget: " .. tostring(st))
                    if st then
                        local kids = { st:GetChildren() }
                        print("  ScrollTarget children: " .. #kids)
                        for i, kid in ipairs(kids) do
                            if i <= 5 then
                                local text = ns.Utils.GetButtonText(kid)
                                print("    [" .. i .. "] " .. tostring(text) .. " shown:" .. tostring(kid:IsShown()))
                            end
                        end
                    end
                end
            end
        elseif msg == "whatsnew" then
            if ns.version == "2.0.0" and ns.Wizard and ns.Wizard.Show then
                EasyFind.db.tutorialDone = false
                ns.Wizard:Show()
            elseif ns.UI then
                ns.UI:ShowWhatsNew(ns.version)
            end
        elseif msg == "help" or msg == "h" or msg == "?" then
            EasyFind:Print("Commands:")
            EasyFind:Print("  /ef: open options panel")
            EasyFind:Print("  /ef clear: dismiss highlights, pins, breadcrumbs")
            EasyFind:Print("  /ef reset: reset all settings")
            EasyFind:Print("  /ef bug: report a bug")
            EasyFind:Print("  /ef feature: request a feature")
        elseif msg == "" then
            EasyFind:OpenOptions()
        end
    end

    if EasyFind.db.showLoginMessage == true then
        EasyFind:Print("EasyFind loaded. Use /ef o to open options. (Disable this message in General settings.)")
    end
end

local SafeAfter = Utils.SafeAfter

local function MarkDynamicCategoryDirty(key)
    if ns.Database and ns.Database.MarkDynamicCategoryDirty then
        ns.Database:MarkDynamicCategoryDirty(key)
    end
    if ns.UI and ns.UI.RebuildOpenResults then
        ns.UI:RebuildOpenResults()
    end
end

local function InstallTransmogClassFilterHook()
    if not C_TransmogSets or not C_TransmogSets.SetTransmogSetsClassFilter
       or EasyFind._tmogClassHooked then
        return
    end
    EasyFind._tmogClassHooked = true
    hooksecurefunc(C_TransmogSets, "SetTransmogSetsClassFilter", function(classID)
        if EasyFind._tmogClassHookSuppress then return end
        if not classID then return end
        local db = EasyFind.db
        if not db then return end
        local _, _, playerClassID = UnitClass("player")
        local newVal
        if classID == playerClassID then
            newVal = nil
        else
            newVal = { classID = classID }
        end
        local oldID = type(db.appearanceSetClass) == "table"
            and db.appearanceSetClass.classID or db.appearanceSetClass
        local newID = type(newVal) == "table" and newVal.classID or newVal
        if oldID == newID then return end
        db.appearanceSetClass = newVal
        MarkDynamicCategoryDirty("transmogSets")
    end)
end

-- Lazy dynamic load pulled when the user opens the search bar. Safe to
-- call repeatedly; loaded-and-clean providers are skipped.
function EasyFind:EnsureDynamicLoaded()
    if not ns.Database then return end
    if ns.Database.LoadDeferredSyncProvidersStaggered then
        ns.Database:LoadDeferredSyncProvidersStaggered()
    end
    if not self._dynamicLoadTriggered then
        self._dynamicLoadTriggered = true
        if ns.Database.LoadHeavyDynamicSearchDataSync then
            SafeAfter(0.5, function()
                ns.Database:LoadHeavyDynamicSearchDataSync()
            end)
        end
        -- Wardrobe / Heirlooms APIs sometimes aren't ready first pass.
        SafeAfter(3.0, function()
            if ns.Database.LoadDeferredSyncProvidersStaggered then
                ns.Database:LoadDeferredSyncProvidersStaggered()
            end
        end)
    end
end

-- EasyFind's keybinds are fully addon-managed: the chosen key is stored
-- account-wide in EasyFindDB and applied as an override-click each login.
-- They are not WoW named bindings, so they never appear in Blizzard's
-- keybinding panel and work the same on every character.
local EASYFIND_BINDINGS = { "EASYFIND_TOGGLE_FOCUS", "EASYFIND_MAP_FOCUS", "EASYFIND_CLEAR" }
local EASYFIND_BINDING_LOOKUP = {}
for i = 1, #EASYFIND_BINDINGS do EASYFIND_BINDING_LOOKUP[EASYFIND_BINDINGS[i]] = true end

local bindingOverrideOwner = CreateFrame("Frame")

local KEYBIND_BUTTON = {
    EASYFIND_TOGGLE_FOCUS = "EasyFindKeybindToggleButton",
    EASYFIND_MAP_FOCUS    = "EasyFindKeybindMapButton",
    EASYFIND_CLEAR        = "EasyFindKeybindClearButton",
}
do
    local toggleBtn = CreateFrame("Button", "EasyFindKeybindToggleButton", UIParent)
    toggleBtn:Hide()
    toggleBtn:SetScript("OnClick", function() EasyFind:ToggleFocusSearchUI() end)
    local mapBtn = CreateFrame("Button", "EasyFindKeybindMapButton", UIParent)
    mapBtn:Hide()
    mapBtn:SetScript("OnClick", function() EasyFind:FocusMapSearch() end)
    local clearBtn = CreateFrame("Button", "EasyFindKeybindClearButton", UIParent)
    clearBtn:Hide()
    clearBtn:SetScript("OnClick", function() EasyFind:ClearAll() end)
end

local function ApplyAccountKeybinds()
    local store = EasyFindDB and EasyFindDB.accountKeybinds
    if not store then return end
    if InCombatLockdown() then
        bindingOverrideOwner:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    ClearOverrideBindings(bindingOverrideOwner)
    for i = 1, #EASYFIND_BINDINGS do
        local action = EASYFIND_BINDINGS[i]
        local key = store[action]
        if key and key ~= "" then
            SetOverrideBindingClick(bindingOverrideOwner, true, key, KEYBIND_BUTTON[action])
        end
    end
end

bindingOverrideOwner:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    ApplyAccountKeybinds()
end)

-- Called by EasyFind's keybind UI when the user binds (key) or clears (nil) a
-- shortcut. Stores it account-wide and re-applies the override immediately.
function EasyFind:SetAccountKeybind(action, key)
    if not (action and EASYFIND_BINDING_LOOKUP[action] and EasyFindDB) then return end
    EasyFindDB.accountKeybinds = EasyFindDB.accountKeybinds or {}
    if key == "" then key = nil end
    EasyFindDB.accountKeybinds[action] = key
    ApplyAccountKeybinds()
end

EasyFind.GetAccountKeybind = function(_, action)
    return EasyFindDB and EasyFindDB.accountKeybinds and EasyFindDB.accountKeybinds[action]
end

local function OnPlayerLogin()
    if ns.Database and ns.Database.EnsureDynamicProviderLoaded then
        ns.Database:EnsureDynamicProviderLoaded("statistics", function(changed)
            if changed and ns.Database.MarkDynamicProviderLoaded then
                ns.Database:MarkDynamicProviderLoaded("statistics")
            end
        end)
    elseif ns.Database and ns.Database.PopulateDynamicStatisticsAsync then
        ns.Database:PopulateDynamicStatisticsAsync(function(changed)
            if changed and ns.Database.MarkDynamicProviderLoaded then
                ns.Database:MarkDynamicProviderLoaded("statistics")
            end
        end)
    end

    local function SafeInit(mod, name)
        if not mod then return end
        local ok, err = xpcall(mod.Initialize, ErrorHandler, mod)
        if not ok then
            EasyFind:Print("|cffff4444" .. name .. " failed to initialize: " .. tostring(err) .. "|r")
        end
    end
    if EasyFind.db.enableMapSearch ~= false then
        SafeInit(ns.MapSearch,  "MapSearch")
    end
    SafeInit(ns.UI,        "UI")
    SafeInit(ns.Highlight, "Highlight")
    if EasyFind.db.enableMapSearch ~= false and ns.MapSearch and ns.MapSearch.WarmUISearchCaches then
        ns.MapSearch:WarmUISearchCaches()
    end
    if ns.Options and ns.Options.RegisterWithBlizzardOptions then
        local ok, err = xpcall(ns.Options.RegisterWithBlizzardOptions, ErrorHandler, ns.Options)
        if not ok then
            EasyFind:Print("|cffff4444Options registration failed: " .. tostring(err) .. "|r")
        end
    end
    InstallTransmogClassFilterHook()

    if ns.Database then
        if ns.Database.WarmSearchHotPath then
            xpcall(ns.Database.WarmSearchHotPath, ErrorHandler, ns.Database)
        end
        EasyFind:EnsureDynamicLoaded()
    end

    -- Load bosses directly (not behind the heavy chain) so single
    -- encounter names match on the first search.
    SafeAfter(1.0, function()
        if ns.Database and ns.Database.EnsureDynamicProviderLoaded then
            ns.Database:EnsureDynamicProviderLoaded("bosses", function() end)
        end
    end)

    -- Pre-warm Blizzard's achievement search index off the typing path.
    SafeAfter(2.0, function()
        if ns.UI and ns.UI.PrewarmAchievementSearch then
            xpcall(ns.UI.PrewarmAchievementSearch, ErrorHandler, ns.UI)
        end
    end)

    -- Delay so Minimap is ready.
    SafeAfter(0.6, function()
        if EasyFind.db.showMinimapButton then
            EasyFind:UpdateMinimapButton()
        end
    end)

    local currentVersion = ns.version
    local lastSeen = EasyFind.db.lastSeenVersion
    if currentVersion and currentVersion ~= lastSeen then
        if currentVersion == REVAMPED_TUTORIAL_VERSION
           and EasyFind.db.revampedTutorialVersion ~= REVAMPED_TUTORIAL_VERSION then
            EasyFind.db.tutorialDone = false
        end
        -- elseif currentVersion ~= REVAMPED_TUTORIAL_VERSION
        --        and (lastSeen ~= nil or EasyFind.db.setupComplete) then
        --     SafeAfter(1.5, function()
        --         if ns.UI then ns.UI:ShowWhatsNew(currentVersion) end
        --     end)
        EasyFind.db.lastSeenVersion = currentVersion
    end

    EasyFindDB.accountKeybinds = EasyFindDB.accountKeybinds or {}
    for i = 1, #EASYFIND_BINDINGS do
        local action = EASYFIND_BINDINGS[i]
        if not EasyFindDB.accountKeybinds[action] then
            local existing = GetBindingKey(action)
            if existing then EasyFindDB.accountKeybinds[action] = existing end
        end
    end
    ApplyAccountKeybinds()
end

local outfitRefreshTimer

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("TRANSMOG_OUTFITS_CHANGED")
eventFrame:RegisterEvent("TRANSMOG_COLLECTION_UPDATED")
eventFrame:RegisterEvent("UPDATE_MACROS")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
local bagRefreshTimer
local spellRefreshTimer
local gearSetRefreshTimer
eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        OnInitialize()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
        self.loginHandled = true
        self:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- PLAYER_LOGIN does not fire on /reload; arg2 = isReloadingUI.
        if arg2 and not self.loginHandled then
            OnPlayerLogin()
        end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    elseif event == "TRANSMOG_OUTFITS_CHANGED" then
        if outfitRefreshTimer then outfitRefreshTimer:Cancel() end
        outfitRefreshTimer = C_Timer.NewTimer(0.5, function()
            outfitRefreshTimer = nil
            MarkDynamicCategoryDirty("outfits")
            if ns.UIPins and ns.UIPins.SyncOutfits then
                ns.UIPins.SyncOutfits()
            end
        end)
    elseif event == "TRANSMOG_COLLECTION_UPDATED" then
        if ns.Database and ns.Database.SyncTransmogSetFiltersFromUI then
            ns.Database:SyncTransmogSetFiltersFromUI()
            MarkDynamicCategoryDirty("transmogSets")
            InstallTransmogClassFilterHook()
        end
    elseif event == "UPDATE_MACROS" then
        MarkDynamicCategoryDirty("macros")
    elseif event == "SPELLS_CHANGED" then
        if spellRefreshTimer then spellRefreshTimer:Cancel() end
        spellRefreshTimer = C_Timer.NewTimer(1.0, function()
            spellRefreshTimer = nil
            MarkDynamicCategoryDirty("abilities")
        end)
    elseif event == "BAG_UPDATE_DELAYED" then
        if bagRefreshTimer then bagRefreshTimer:Cancel() end
        bagRefreshTimer = C_Timer.NewTimer(0.5, function()
            bagRefreshTimer = nil
            MarkDynamicCategoryDirty("bags")
        end)
    elseif event == "EQUIPMENT_SETS_CHANGED" then
        if gearSetRefreshTimer then gearSetRefreshTimer:Cancel() end
        gearSetRefreshTimer = C_Timer.NewTimer(0.3, function()
            gearSetRefreshTimer = nil
            MarkDynamicCategoryDirty("gearSets")
        end)
    elseif event == "PLAYER_LOGOUT" then
        if EasyFindDB then
            for _, field in ipairs(RUNTIME_FIELDS) do
                EasyFindDB[field] = nil
            end
        end
    end
end)

function EasyFind:ToggleSearchUI()
    self:EnsureDynamicLoaded()
    if ns.UI then ns.UI:Toggle() end
end

function EasyFind:FocusSearchUI()
    self:EnsureDynamicLoaded()
    if ns.UI then ns.UI:Focus() end
end

function EasyFind:ToggleFocusSearchUI()
    self:EnsureDynamicLoaded()
    if EasyFind.db.enableMapSearch ~= false and WorldMapFrame and WorldMapFrame:IsShown() and ns.MapTab then
        ns.MapTab:Focus()
    elseif ns.UI then
        ns.UI:ToggleFocus()
    end
end

function EasyFind:FocusMapSearch()
    if EasyFind.db.enableMapSearch == false then return end
    self:EnsureDynamicLoaded()
    if ns.MapTab then ns.MapTab:Focus() end
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

    testFrame.texture:SetTexture(texturePath)
    testFrame.texture:SetVertexColor(ns.YELLOW_HIGHLIGHT[1], ns.YELLOW_HIGHLIGHT[2], ns.YELLOW_HIGHLIGHT[3], 1)
    testFrame.title:SetText("Testing: " .. texturePath)
    testFrame:Show()

    EasyFind:Print("Testing texture: " .. texturePath)
    EasyFind:Print("Close the preview window to dismiss.")
end

local minimapButton

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

    local q = 1
    if cx < 0 then q = q + 1 end
    if cy > 0 then q = q + 2 end

    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5

    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = minimapShapes[shape] or minimapShapes["ROUND"]

    local x, y
    if quadTable[q] then
        x, y = cx * w, cy * h
    else
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
    icon:SetSize(14, 14)
    icon:SetTexture("Interface\\AddOns\\EasyFind\\Textures\\SpyglassMinimap")
    icon:SetPoint("CENTER")

    mmBtn:SetHighlightTexture(136477)

    mmBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- autoHide fires on GLOBAL_MOUSE_DOWN before our OnClick (mouseUp).
    -- Set the flag synchronously in OnMouseDown so autoHide can skip
    -- this click, otherwise toggle re-opens what autoHide just closed.
    mmBtn:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            EasyFind._minimapClickActive = true
        end
    end)
    mmBtn:HookScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            EasyFind._minimapClickActive = nil
        end
    end)
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
    PositionMinimapButton(EasyFind.db.minimapButtonAngle or 200)
    return mmBtn
end

function EasyFind:UpdateMinimapButton()
    if EasyFind.db.showMinimapButton then
        if not minimapButton then
            CreateMinimapButton()
        end
        minimapButton:Show()
        PositionMinimapButton(EasyFind.db.minimapButtonAngle or 200)
    elseif minimapButton then
        minimapButton:Hide()
    end
end

function EasyFind_OnAddonCompartmentClick(_, button)
    if button == "LeftButton" then
        EasyFind:ToggleSearchUI()
    else
        EasyFind:OpenOptions()
    end
end
