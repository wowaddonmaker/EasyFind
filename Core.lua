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

BINDING_NAME_EASYFIND_TOGGLE_FOCUS = "Toggle Search Bar"
BINDING_NAME_EASYFIND_CLEAR        = "Clear All Highlights"
BINDING_NAME_EASYFIND_MAP_FOCUS    = "Open Map Search"

local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

EasyFind.db = {}

-- SavedVariables version. Increment when changing DB schema.
-- Each migration runs once: if saved dbVersion < DB_VERSION, run all steps in order.
local DB_VERSION = 8

-- SavedVariables defaults - new keys are auto-merged for existing users
local DB_DEFAULTS = {
    dbVersion = DB_VERSION,
    visible = true,
    enableUISearch = true,
    enableMapSearch = true,
    iconScale = 0.8,
    nativePinScale = 1.5,      -- Multiplier applied to a Blizzard map pin while EasyFind is glowing it
    uiSearchScale = 1.0,
    uiSearchWidth = 1.54,  -- 0.88 * 1.75: results dropdown matches bar width now
    uiResultsScale = 1.0,
    uiResultsWidth = 350,
    searchBarOpacity = 0.75,  -- ns.DEFAULT_OPACITY
    fontSize = 0.9,            -- UI search font size multiplier (0.5-2.0)
    uiSearchPosition = nil,    -- {point, relPoint, x, y}
    localMapDirectOpen = true,
    globalMapDirectOpen = true,
    autoHide = true,           -- Raycast-style: bar starts hidden; bind opens, click-out hides
    smartShow = false,         -- Hide search bar until mouse hovers nearby (legacy alternate to autoHide)
    lockPosition = false,      -- Disable drag-to-move on the search bar
    tutorialDone = false,      -- True once the user has finished the onboarding wizard
    resultsTheme = "Modern",  -- legacy; only "Modern" ships right now
    font = "Default",          -- "Default" (Friz Quadrata) or "Inter"
    indicatorStyle = "EasyFind Arrow",  -- Indicator texture style
    indicatorColor = "Yellow",  -- Indicator color preset
    uiResultsHeight = 280,     -- Visible height of UI search results panel in pixels
    showTruncationMessage = true,  -- Show "more results available" message when truncated
    hardResultsCap = false,    -- Hard cap on results (no "more results" message)
    staticOpacity = true,      -- Keep opacity constant while moving (default-on with toggle/autoHide UX)
    pinnedUIItems = {},        -- Pinned UI search results (persist across sessions, account-wide)
    pinnedUIItemsPerChar = {}, -- Character-specific pins (mounts, toys, pets, outfits) keyed by "Name-Realm"
    pinnedMapItems = {},       -- Pinned map search results (persist across sessions)
    mapPinsCollapsed = false,  -- Whether the map search "Pinned" header is collapsed
    showLoginMessage = true,   -- Show "EasyFind loaded!" message on login
    blinkingPins = false,      -- Pulse map pins and highlights in sync with indicator bob
    mapPinHighlight = true,    -- Show yellow highlight box around map pins
    autoPinClear = true,       -- Auto-clear map pin when player arrives
    autoTrackPins = true,      -- Auto super-track newly placed map pins
    uiResultsAbove = false,    -- Show UI search results above the search bar
    panelOpacity = 0.9,        -- Options panel background opacity
    showMinimapButton = true,  -- Show toggle button on minimap
    minimapButtonAngle = 200,  -- Position angle (degrees) around minimap edge
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
        rares = true,
    },
    mapTabFilters = {
        zones = true,
        instances = true,
        flightpath = false,    -- Off by default: zone maps are dense with flight masters
        travel = true,         -- Portals, ships, zeppelins, trams (separate from flight paths)
        services = true,
        rares = true,
    },
    mapTabRecentSearches = {},  -- Most-recent-first list of past map search queries
    mapTabShowRecent = true,    -- Toggle for showing recent searches when idle
    mapTabRecentCount = 3,      -- Number of recent searches to keep / display (1-20)
    mapTabAutoExpand = true,    -- Auto-expand a matched parent header to show all its world-hierarchy children
    alwaysShowRares = false,  -- Persistent rare tracking: show active rares on map without searching
    uiSearchFilters = {        -- UI search category filters (all enabled by default)
        ui             = true,
        achievements   = true,
        currencies     = true,
        reputations    = true,
        collections    = true,
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
        map            = true,
    },
    lootSpecs = nil,           -- Loot search: nil = current spec only, table of {classID, specID} pairs when customized
    lootSearchSlots = true,    -- Loot search: match by slot keywords (ring, helm, etc.)
    lootSearchStats = true,    -- Loot search: match by stat keywords (haste, crit, etc.)
    lootUpgradesOnly = false,  -- Loot search: only show items above equipped ilvl
    lootDifficulty = "normal",
    -- Per-flyout "Hide tooltips" toggles. Keys mirror filter top-level
    -- groups; when true, OnEnter on rows in that group skips the
    -- gear/item tooltip entirely.
    hideTooltips = {
        collections = false,    -- mounts/toys/pets/outfits/heirlooms/appearance sets
        loot        = false,    -- gear search results
    },
    -- Currencies filter mode (mirrors the in-game CurrencyFrame
    -- dropdown). "all" = show every currency the character has;
    -- "warband" = only surface warband-transferable currencies.
    currencyFilterMode = "all",
    -- Reputation filter mode (mirrors ReputationFrame's dropdown).
    -- "all" / "warband" / "char". Persisted independently from
    -- showLegacyReputations because Blizzard treats them as separate
    -- filter axes.
    reputationFilterMode = "all",
    showLegacyReputations = false,
    -- Spellbook ability filter: when true, hides passive abilities in
    -- both EasyFind's results and Blizzard's spellbook page.
    abilityHidePassives = false,
    appearanceSetClass = nil,         -- nil = player class, "all" = all, {classID=N} = specific
    appearanceSetCollected = true,    -- Show collected sets
    appearanceSetNotCollected = true, -- Show uncollected sets
    appearanceSetPvE = true,          -- Show PvE sets (Dungeon/Raid)
    appearanceSetPvP = true,          -- Show PvP sets
    uiMapSearchLocal = true,   -- Map search in UI bar: true = local zone only, false = global
    aliases = {},              -- User-defined search aliases: { [aliasText] = { kind, id, name } }
    uiSearchHistory = {},      -- Shell-style search history (most recent at index 1, capped at uiSearchHistoryLimit)
    uiSearchHistoryLimit = 500, -- Bash HISTSIZE default
}

local DB_MIGRATIONS = {
    -- [1] = Consolidate ad-hoc migrations (maxResults rename, uiResultsWidth reset)
    [1] = function(db)
        if db.maxResults then
            if not db.uiMaxResults then db.uiMaxResults = db.maxResults end
            if not db.mapMaxResults then db.mapMaxResults = db.maxResults end
            db.maxResults = nil
        end
        if db.uiResultsWidth == 1.0 then db.uiResultsWidth = 300 end
    end,
    -- [2] = Widen default UI results panel from 300 to 350
    [2] = function(db)
        if db.uiResultsWidth == 300 then db.uiResultsWidth = 350 end
    end,
    -- [3] = Replace row-count settings with pixel height
    [3] = function(db)
        if not db.uiResultsHeight then
            db.uiResultsHeight = db.uiMaxResults and (db.uiMaxResults * 28) or 280
        end
        db.uiMaxResults = nil
        db.mapMaxResults = nil
    end,
    -- [4] = Combined search bar + results dropdown silhouette. The
    -- results panel now matches the bar's width directly, so the
    -- old 0.88 default would render the bar (and therefore the
    -- dropdown) too narrow. Bump uiSearchWidth ~1.75x for everyone
    -- whose width is at or below the old default; users who have
    -- explicitly widened it past the old default keep their value.
    [4] = function(db)
        local w = db.uiSearchWidth
        if w == nil or w <= 0.88 then
            db.uiSearchWidth = 1.54
        end
    end,
    -- [5] = Restore direct map navigation defaults.
    [5] = function(db)
        if db.localMapDirectOpen == false then db.localMapDirectOpen = true end
        if db.globalMapDirectOpen == false then db.globalMapDirectOpen = true end
    end,
    -- [6] = Default flightpath filter to off in MapTab. Pre-existing
    -- mapTabFilters tables won't have the key (added when we split
    -- flight masters out of the Travel bucket), so they default to nil
    -- = enabled. Force false unless the user explicitly turned it on.
    [6] = function(db)
        if db.mapTabFilters and db.mapTabFilters.flightpath == nil then
            db.mapTabFilters.flightpath = false
        end
    end,
    -- [8] = Theme rename: "Classic" and "Retail" renamed to
    -- "Modern" (the new default), and "Retail" reused for the parchment
    -- variant. Existing saves on the old "Retail" or "Classic" values
    -- get pointed at "Modern" so nothing changes for them visually until
    -- they pick the new "Retail" themselves.
    [8] = function(db)
        if db.resultsTheme == "Retail" or db.resultsTheme == "Classic" then
            db.resultsTheme = "Modern"
        end
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
        elseif msg == "toggle" or msg == "t" then
            EasyFind:EnsureDynamicLoaded()
            if ns.UI then ns.UI:Toggle() end
        elseif msg == "c" or msg == "clear" then
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
            if ns.UI then ns.UI:ShowWhatsNew(ns.version) end
        elseif msg == "help" or msg == "h" or msg == "?" then
            EasyFind:Print("Commands:")
            EasyFind:Print("  /ef: open options panel")
            EasyFind:Print("  /ef toggle: show/hide search bar")
            EasyFind:Print("  /ef clear: dismiss highlights, pins, breadcrumbs")
            EasyFind:Print("  /ef reset: reset all settings")
            EasyFind:Print("  /ef bug: report a bug")
            EasyFind:Print("  /ef feature: request a feature")
        elseif msg == "" then
            EasyFind:OpenOptions()
        else
            print("|cFFFFFF00Type '/ef help' for a list of commands.|r")
        end
    end

    if EasyFind.db.showLoginMessage ~= false then
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

-- Lazy dynamic load: pulled the moment the user opens the search bar (or any
-- entry point that surfaces dynamic results). Other search-style addons follow
-- the same shape: nothing is scanned at PLAYER_LOGIN, so the player never sees
-- a post-load-screen stutter from us.
-- Calling repeatedly is safe: LoadDeferredSyncProvidersStaggered skips
-- providers that are loaded-and-clean, so re-entry only refreshes dirty ones.
function EasyFind:EnsureDynamicLoaded()
    if not ns.Database then return end
    if EasyFind.db.enableUISearch == false then return end
    if ns.Database.LoadDeferredSyncProvidersStaggered then
        ns.Database:LoadDeferredSyncProvidersStaggered()
    end
    if not self._dynamicLoadTriggered then
        self._dynamicLoadTriggered = true
        if ns.Database.LoadHeavyDynamicSearchDataSync then
            SafeAfter(0.5, function()
                if EasyFind.db.enableUISearch == false then return end
                ns.Database:LoadHeavyDynamicSearchDataSync()
            end)
        end
        -- Late-arriving APIs (Wardrobe, Heirlooms) sometimes aren't ready in
        -- the first pass. Re-trigger after they've had time to populate.
        SafeAfter(3.0, function()
            if EasyFind.db.enableUISearch == false then return end
            if ns.Database.LoadDeferredSyncProvidersStaggered then
                ns.Database:LoadDeferredSyncProvidersStaggered()
            end
        end)
    end
end

local function OnPlayerLogin()
    -- Kick off the time-sliced statistics enumeration immediately
    -- (2ms-per-tick budget, no load-screen block). Run it through the
    -- provider manager so later heavy-load requests don't restart it.
    if ns.Database and ns.Database.EnsureDynamicProviderLoaded
       and EasyFind.db.enableUISearch ~= false then
        ns.Database:EnsureDynamicProviderLoaded("statistics", function(changed)
            if changed and ns.Database.MarkDynamicProviderLoaded then
                ns.Database:MarkDynamicProviderLoaded("statistics")
            end
        end)
    elseif ns.Database and ns.Database.PopulateDynamicStatisticsAsync
       and EasyFind.db.enableUISearch ~= false then
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
    if EasyFind.db.enableUISearch ~= false then
        SafeInit(ns.UI,        "UI")
        SafeInit(ns.Highlight, "Highlight")
    end
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

    -- Pre-warm the search hot path eagerly: build the prefix index over
    -- the static dataset immediately, then kick off the deferred dynamic
    -- providers in the background so by the time the user opens the
    -- search bar (post-login UI fade-in, minimap button click, etc.) the
    -- index is ready and no first-keystroke build cost remains.
    if ns.Database then
        if ns.Database.WarmSearchHotPath then
            xpcall(ns.Database.WarmSearchHotPath, ErrorHandler, ns.Database)
        end
        EasyFind:EnsureDynamicLoaded()
    end

    -- Background-load boss entries directly shortly after
    -- login so individual encounter names ("Professor Putricide") match
    -- on the first search. Do not route this through the generic heavy
    -- chain; boss results should not sit behind Statistics/Loot.
    SafeAfter(1.0, function()
        if EasyFind.db.enableUISearch == false then return end
        if ns.Database and ns.Database.EnsureDynamicProviderLoaded then
            ns.Database:EnsureDynamicProviderLoaded("bosses", function() end)
        end
    end)

    -- Pre-warm Blizzard's achievement search index off the user's typing
    -- path. The index build is the lag source we used to hit on the
    -- first achievement-related search; doing it once in the background
    -- here makes per-keystroke achievement results instant later.
    SafeAfter(2.0, function()
        if ns.UI and ns.UI.PrewarmAchievementSearch then
            xpcall(ns.UI.PrewarmAchievementSearch, ErrorHandler, ns.UI)
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
        -- arg1 = isInitialLogin, arg2 = isReloadingUI
        -- PLAYER_LOGIN does not fire on UI reloads, so use PLAYER_ENTERING_WORLD
        -- as a fallback to ensure modules initialize after /reload.
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
        -- Strip runtime-only fields before SavedVariables serialization
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
    if WorldMapFrame and WorldMapFrame:IsShown() and ns.MapTab then
        ns.MapTab:Focus()
    elseif ns.UI then
        ns.UI:ToggleFocus()
    end
end

function EasyFind:FocusMapSearch()
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
    icon:SetSize(14, 14)
    icon:SetTexture("Interface\\AddOns\\EasyFind\\Textures\\SpyglassMinimap")
    icon:SetPoint("CENTER")

    mmBtn:SetHighlightTexture(136477)

    mmBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- The search bar's autoHide handler fires on GLOBAL_MOUSE_DOWN before
    -- our OnClick (which runs on mouseUp). Without these flags it would
    -- close the bar first, then OnClick's toggle would see a hidden bar
    -- and re-open it -- net effect: the click does nothing. Setting the
    -- flag synchronously in OnMouseDown lets autoHide skip this click.
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

-- Addon compartment button (## AddonCompartmentFunc in TOC)
function EasyFind_OnAddonCompartmentClick(_, button)
    if button == "LeftButton" then
        EasyFind:ToggleSearchUI()
    else
        EasyFind:OpenOptions()
    end
end
