local ADDON_NAME, ns = ...

local Utils   = ns.Utils
local L       = ns.L
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
    uiSearchBarHeight = ns.SEARCHBAR_HEIGHT,
    fontSize = ns.DEFAULT_FONT_SIZE,
    searchWindowOpacity = ns.SEARCH_WINDOW_ALPHA,
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
    uiResultsRows = 6,
    pinnedUIItems = {},
    pinnedUIItemsPerChar = {},
    pinnedMapItems = {},
    lootStatCache = {},
    lootStatCacheVer = 0,
    lootItemCache = {},
    lootItemCacheVer = 0,
    bossCache = {},
    bossCacheVer = 0,
    statisticCache = {},
    statisticCacheVer = 0,
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
        appearances    = true,
        appearanceItems = true,
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
    heirloomFilterCollected = true,
    heirloomFilterNotCollected = false,
    heirloomSourceFilters = {},
    hideTooltips = {
        collections = false,
        loot        = false,
        abilities   = false,
        talents     = false,
        macros      = false,
        bags        = false,
        currencies  = false,
    },
    currencyFilterMode = "all",
    reputationFilterMode = "all",
    achievementFilterMode = "all",
    hideAchievementHeaders = true,
    hideGuildAchievements = true,
    showLegacyReputations = false,
    abilityHidePassives = false,
    macroFilterGeneral = true,
    macroFilterChar = true,
    bossFilterDungeon = true,
    bossFilterRaid = true,
    bagHideJunk = false,
    wowheadLocale = "auto",
    shortkeyConflictPrompt = true,
    commandShowNative = true,
    commandShowCustom = true,
    appearanceSetClass = nil,
    appearanceSetCollected = true,
    appearanceSetNotCollected = true,
    appearanceSetPvE = true,
    appearanceSetPvP = true,
    uiMapSearchLocal = true,
    aliases = {},
    shortkeys = {},
    shortkeysPerChar = {},
    uiSearchHistory = {},
    uiSearchHistoryLimit = 500,
}

local function RequireRevampedTutorial(db)
    if db.revampedTutorialVersion ~= REVAMPED_TUTORIAL_VERSION then
        db.tutorialDone = false
        db.lastSeenVersion = REVAMPED_TUTORIAL_VERSION
    end
end

local CloneDefaultValue = ns.Utils.DeepCopy

-- Keys preserved across the 2.0 settings reset; all others restored to defaults.
local PRESERVED_KEYS = {
    dbVersion = true,
    tutorialDone = true,
    mapTabRecentSearches = true,
    aliases = true,
    shortkeys = true,
    shortkeysPerChar = true,
    uiSearchHistory = true,
    uiSearchHistoryLimit = true,
    accountKeybinds = true,
}

local RETIRED_SETTINGS_KEYS = {
    enableUISearch = true,
    mapSearchScale = true,
    mapSearchWidth = true,
    mapResultsScale = true,
    mapResultsWidth = true,
    mapFontSize = true,
    mapResultsHeight = true,
    mapResultsAbove = true,
    mapSearchPosition = true,
    globalSearchPosition = true,
    mapSearchPositionMax = true,
    globalSearchPositionMax = true,
    mapSearchYOffset = true,
    hideSearchBarsMaximized = true,
    directOpen = true,
    mapSmartShow = true,
    pinsCollapsed = true,
    arrivalDistance = true,
    minimapArrowGlow = true,
    glowOnlyEasyFind = true,
    minimapGuideCircle = true,
    circleOnlyEasyFind = true,
    guideCircleScale = true,
    minimapPinGlow = true,
    panelOpacity = true,
    searchBarOpacity = true,
    staticOpacity = true,
    suggestedKeybindsApplied = true,
    optionsPosition = true,
    lootFilter = true,
    showTruncationMessage = true,
    hardResultsCap = true,
}

local function ApplyFreshSettingsFor2(db)
    for key, defaultValue in pairs(DB_DEFAULTS) do
        if not PRESERVED_KEYS[key] then
            db[key] = CloneDefaultValue(defaultValue)
        end
    end

    for key in pairs(RETIRED_SETTINGS_KEYS) do
        db[key] = nil
    end

    RequireRevampedTutorial(db)
end

-- User data and history kept when the player hits "Reset all settings"; every
-- other DB_DEFAULTS key is restored. Keeps everything the 2.0 migration
-- preserves, plus pins and the loot-stat cache. Inheriting PRESERVED_KEYS means
-- a new user-data key added there is honored here automatically.
local INTERACTIVE_RESET_PRESERVE = {
    pinnedUIItems = true,
    pinnedUIItemsPerChar = true,
    pinnedMapItems = true,
    lootStatCache = true,
    lootStatCacheVer = true,
    lootItemCache = true,
    lootItemCacheVer = true,
    bossCache = true,
    bossCacheVer = true,
    statisticCache = true,
    statisticCacheVer = true,
}
for key in pairs(PRESERVED_KEYS) do
    INTERACTIVE_RESET_PRESERVE[key] = true
end

-- DB_DEFAULTS table-literal keys whose default is nil drop out of the table, so
-- pairs() never visits them; clear them explicitly on reset.
local NIL_DEFAULT_KEYS = { "uiSearchPosition", "lootSpecs", "appearanceSetClass", "heirloomFilter" }

function EasyFind:ResetSettingsToDefaults()
    local db = self.db
    if not db then return end
    for key, defaultValue in pairs(DB_DEFAULTS) do
        if not INTERACTIVE_RESET_PRESERVE[key] then
            db[key] = CloneDefaultValue(defaultValue)
        end
    end
    for i = 1, #NIL_DEFAULT_KEYS do
        db[NIL_DEFAULT_KEYS[i]] = nil
    end
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
        if not db.uiSearchBarHeight then db.uiSearchBarHeight = ns.SEARCHBAR_HEIGHT end
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

local function ShowFeedbackURL(url)
    ns.ShowCopyBox(url, L["URL_COPY_HINT"])
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

-- Account-wide binds a brand-new install starts with; seeded once at login.
local SUGGESTED_KEYBINDS = {
    EASYFIND_TOGGLE_FOCUS = "CTRL-SPACE",
    EASYFIND_MAP_FOCUS = "CTRL-M",
}

-- Chat-hello hyperlink. Clicking the link in the welcome message opens the
-- restyled What's New popup. SetItemRef receives any |H...|h chat link, so
-- our custom prefix is detected before falling through to Blizzard's handler.
local WHATSNEW_LINK_PREFIX = "easyfind:whatsnew:"
local whatsNewHookInstalled = false

local function InstallWhatsNewHyperlinkHook()
    if whatsNewHookInstalled then return end
    whatsNewHookInstalled = true
    local origSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame)
        if link and link:sub(1, #WHATSNEW_LINK_PREFIX) == WHATSNEW_LINK_PREFIX then
            local version = link:sub(#WHATSNEW_LINK_PREFIX + 1)
            if ns.Onboarding and ns.Onboarding.ShowWhatsNew then
                xpcall(ns.Onboarding.ShowWhatsNew, ErrorHandler, ns.Onboarding, version)
            end
            return
        end
        return origSetItemRef(link, text, button, chatFrame)
    end
end

local function ShowWhatsNewChatMessage(version)
    local v = version or "?"
    local link = sformat("|cff70d4ff|H%s%s|h%s|h|r",
        WHATSNEW_LINK_PREFIX, v, L["WHATSNEW_CHAT_HERE"])
    EasyFind:Print(sformat(L["WHATSNEW_CHAT_HELLO"], v, link))
end

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
            if ns.Search then ns.Search:Toggle() end
        elseif msg == "c" or msg == "clear" then
            EasyFind:ClearAll()
        elseif msg == "r" or msg == "reset" then
            if ns.Options then
                ns.Options:Initialize()
                ns.ShowThemedDialog({
                    text = L["POPUP_RESET_ALL_SETTINGS"],
                    acceptText = _G["RESET"] or "Reset",
                    onAccept = function() ns.Options:DoResetAll() end,
                })
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
        elseif msg == "whatsnew" then
            if ns.version == "2.0.0" and ns.Wizard and ns.Wizard.Show then
                EasyFind.db.tutorialDone = false
                ns.Wizard:Show()
            elseif ns.Onboarding and ns.Onboarding.ShowWhatsNew then
                ns.Onboarding:ShowWhatsNew(ns.version)
            end
        elseif msg == "help" or msg == "h" or msg == "?" then
            EasyFind:Print(L["CMD_HEADER"])
            EasyFind:Print(L["CMD_OPTIONS"])
            EasyFind:Print(L["CMD_CLEAR"])
            EasyFind:Print(L["CMD_RESET"])
            EasyFind:Print(L["CMD_BUG"])
            EasyFind:Print(L["CMD_FEATURE"])
        elseif msg == "" then
            EasyFind:OpenOptions()
        end
    end

    InstallWhatsNewHyperlinkHook()

    if EasyFind.db.showLoginMessage == true then
        EasyFind:Print(L["MSG_LOGIN"])
    end
end

local SafeAfter = Utils.SafeAfter

local function MarkDynamicCategoryDirty(key)
    if ns.Database and ns.Database.MarkDynamicCategoryDirty then
        ns.Database:MarkDynamicCategoryDirty(key)
    end
    if ns.Search and ns.Search.RebuildOpenResults then
        ns.Search:RebuildOpenResults()
    end
end

-- One forward hook per class/spec filter: when the player changes a Blizzard
-- panel's class/spec dropdown, mirror it into our db so our list follows. These
-- were near-identical hand-rolled hooks, so they share one installer driven by a
-- descriptor. hasSpec selects the class-only vs class+spec mapping; suppress is
-- the flag our own db->game push raises so the hook ignores our writes.
local function ClassFilterFromGame(hasSpec, classID, specID)
    if not classID or classID <= 0 then return "all" end
    local _, _, playerClassID = UnitClass("player")
    if not hasSpec then
        if classID == playerClassID then return nil end
        return { classID = classID }
    end
    if not specID or specID == 0 then return { classID = classID } end
    local si = GetSpecialization and GetSpecialization()
    local playerSpecID = si and GetSpecializationInfo and GetSpecializationInfo(si)
    if classID == playerClassID and specID == playerSpecID then return nil end
    return { classID = classID, specID = specID }
end

local function SameClassFilter(a, b)
    local aID = type(a) == "table" and a.classID or a
    local bID = type(b) == "table" and b.classID or b
    if aID ~= bID then return false end
    local aSpec = type(a) == "table" and a.specID or nil
    local bSpec = type(b) == "table" and b.specID or nil
    return aSpec == bSpec
end

local CLASS_FILTER_HOOKS = {
    { dbKey = "appearanceSetClass",  provider = "transmogSets",
      tbl = C_TransmogSets,       method = "SetTransmogSetsClassFilter",
      suppress = "_tmogClassHookSuppress",    installed = "_tmogClassHooked" },
    { dbKey = "appearanceItemClass", provider = "appearanceItems",
      tbl = C_TransmogCollection,  method = "SetClassFilter",
      suppress = "_appItemClassHookSuppress", installed = "_tmogItemClassHooked" },
    { dbKey = "heirloomFilter",      provider = "heirlooms", hasSpec = true,
      tbl = C_Heirloom,            method = "SetClassAndSpecFilters",
      suppress = "_heirloomHookSuppress",     installed = "_heirloomClassHooked" },
    { dbKey = "lootFilter",          provider = "loot", hasSpec = true,
      tbl = C_EncounterJournal,    method = "SetLootFilter", globalFn = "EJ_SetLootFilter",
      suppress = "_lootFilterHookSuppress",   installed = "_lootClassHooked" },
}

local function InstallClassFilterHook(desc)
    if EasyFind[desc.installed] then return end
    local function onChange(classID, specID)
        if EasyFind[desc.suppress] then return end
        local db = EasyFind.db
        if not db then return end
        local newVal = ClassFilterFromGame(desc.hasSpec, classID, specID)
        if SameClassFilter(db[desc.dbKey], newVal) then return end
        db[desc.dbKey] = newVal
        MarkDynamicCategoryDirty(desc.provider)
    end
    local tbl = desc.tbl
    if tbl and tbl[desc.method] then
        EasyFind[desc.installed] = true
        hooksecurefunc(tbl, desc.method, onChange)
    elseif desc.globalFn and _G[desc.globalFn] then
        EasyFind[desc.installed] = true
        hooksecurefunc(desc.globalFn, onChange)
    end
end

local function InstallClassFilterHooks()
    for i = 1, #CLASS_FILTER_HOOKS do
        InstallClassFilterHook(CLASS_FILTER_HOOKS[i])
    end
end

-- Deprecated compatibility hook retained for external callers.
function EasyFind:EnsureDynamicLoaded()
    -- Legacy public hook. Dynamic data is now requested by SearchEngine from
    -- the active query instead of speculatively loading every provider.
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
    -- Start the async scheduler's OnUpdate pump with a 2ms per-frame budget.
    -- Dynamic provider coalescing and any future debounced/dep-aware jobs
    -- run on this pump.
    if ns.Scheduler and not ns.Scheduler._pumpFrame then
        ns.Scheduler:SetBudgetMs(2)
        ns.Scheduler:StartPump(CreateFrame("Frame"))
    end

    local function SafeInit(mod, name)
        if not mod then return end
        local ok, err = xpcall(mod.Initialize, ErrorHandler, mod)
        if not ok then
            EasyFind:Print("|cffff4444" .. (L["ERR_MODULE_INIT_FAILED"]):format(name, tostring(err)) .. "|r")
        end
    end
    if EasyFind.db.enableMapSearch ~= false then
        SafeInit(ns.MapSearch,  "MapSearch")
    end
    SafeInit(ns.Search,        "UI")
    SafeInit(ns.Highlight, "Highlight")
    if ns.Options and ns.Options.RegisterWithBlizzardOptions then
        local ok, err = xpcall(ns.Options.RegisterWithBlizzardOptions, ErrorHandler, ns.Options)
        if not ok then
            EasyFind:Print("|cffff4444" .. (L["ERR_OPTIONS_REGISTER_FAILED"]):format(tostring(err)) .. "|r")
        end
    end
    InstallClassFilterHooks()

    -- Keep PLAYER_LOGIN light. Search data is loaded by query intent.

    -- Drop the persisted loot-stat cache if the stat keyword map changed since it
    -- was built. The cache makes gear/stat search instant on later logins. Loot
    -- itself hydrates from its SavedVariables cache or scans lazily on gear intent.
    if EasyFind.db.lootStatCacheVer ~= ns.LOOT_STAT_CACHE_VER then
        EasyFind.db.lootStatCache = {}
        EasyFind.db.lootStatCacheVer = ns.LOOT_STAT_CACHE_VER
    end
    if EasyFind.db.lootItemCacheVer ~= ns.LOOT_ITEM_CACHE_VER then
        EasyFind.db.lootItemCache = {}
        EasyFind.db.lootItemCacheVer = ns.LOOT_ITEM_CACHE_VER
    end
    if EasyFind.db.bossCacheVer ~= ns.BOSS_CACHE_VER then
        EasyFind.db.bossCache = {}
        EasyFind.db.bossCacheVer = ns.BOSS_CACHE_VER
    end
    if EasyFind.db.statisticCacheVer ~= ns.STATISTIC_CACHE_VER then
        EasyFind.db.statisticCache = {}
        EasyFind.db.statisticCacheVer = ns.STATISTIC_CACHE_VER
    end

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
        elseif EasyFind.db.tutorialDone
           and EasyFind.db.revampedTutorialVersion == REVAMPED_TUTORIAL_VERSION
           and lastSeen ~= nil then
            SafeAfter(2.0, function()
                ShowWhatsNewChatMessage(currentVersion)
            end)
        end
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

    -- Seed the suggested defaults once, and only when nothing is bound (the loop
    -- above already pulled in any pre-existing native binds). This never replaces
    -- a key the player set, and the flag stops it re-adding one they cleared.
    if not EasyFindDB.suggestedKeybindsSeeded then
        EasyFindDB.suggestedKeybindsSeeded = true
        if next(EasyFindDB.accountKeybinds) == nil then
            for action, key in pairs(SUGGESTED_KEYBINDS) do
                EasyFindDB.accountKeybinds[action] = key
            end
        end
    end

    ApplyAccountKeybinds()
    if ns.Shortkeys and ns.Shortkeys.ApplyAll then ns.Shortkeys:ApplyAll() end
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
local appearanceItemRefreshTimer
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
            if ns.SearchPins and ns.SearchPins.SyncOutfits then
                ns.SearchPins.SyncOutfits()
            end
        end)
    elseif event == "TRANSMOG_COLLECTION_UPDATED" then
        if ns.Database and ns.Database.SyncTransmogSetFiltersFromUI then
            ns.Database:SyncTransmogSetFiltersFromUI()
            MarkDynamicCategoryDirty("transmogSets")
            InstallClassFilterHooks()
        end
        -- Appearance data streams in over several events after login; a single
        -- early populate can catch a partial list. Re-run (debounced) so the
        -- Items list fills out once it settles, and refresh an open search.
        if appearanceItemRefreshTimer then appearanceItemRefreshTimer:Cancel() end
        appearanceItemRefreshTimer = C_Timer.NewTimer(0.5, function()
            appearanceItemRefreshTimer = nil
            if ns.Database and ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("appearanceItems")
            end
            local frame = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
            local editBox = frame and frame.editBox
            if editBox and frame:IsShown() and ns.Search.OnSearchTextChanged then
                ns.Search:OnSearchTextChanged(editBox:GetText() or "", true)
            end
        end)
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
    if ns.Search then ns.Search:Toggle() end
end

function EasyFind:FocusSearchUI()
    if ns.Search then ns.Search:Focus() end
end

function EasyFind:ToggleFocusSearchUI()
    if EasyFind.db.enableMapSearch ~= false and WorldMapFrame and WorldMapFrame:IsShown() and ns.MapTab then
        ns.MapTab:Focus()
    elseif ns.Search then
        ns.Search:ToggleFocus()
    end
end

function EasyFind:FocusMapSearch()
    if EasyFind.db.enableMapSearch == false then return end
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
    icon:SetTexture("Interface\\AddOns\\EasyFind\\textures\\SpyglassMinimap")
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
    local DRAG_TICK = 0.03
    local function MinimapDragTick(self, elapsed)
        self._dragAccum = (self._dragAccum or 0) + elapsed
        if self._dragAccum < DRAG_TICK then return end
        self._dragAccum = 0
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        local angle = mdeg(matan2(cy - my, cx - mx))
        EasyFind.db.minimapButtonAngle = angle
        PositionMinimapButton(angle)
    end
    mmBtn:SetScript("OnDragStart", function(self)
        self._dragAccum = 0
        self:SetScript("OnUpdate", MinimapDragTick)
    end)
    mmBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    mmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("EasyFind")
        GameTooltip:AddLine(L["MINIMAP_TT_LEFT_CLICK"], 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_TT_RIGHT_CLICK"], 1, 1, 1)
        GameTooltip:AddLine(L["MINIMAP_TT_DRAG"], 0.7, 0.7, 0.7)
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
