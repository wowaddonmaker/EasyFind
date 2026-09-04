local H = require("Harness")

local function makeSetting(name, variableType)
    return {
        GetName = function() return name end,
        GetVariableType = function() return variableType or "boolean" end,
    }
end

local function makeLiveSetting(name, variable, variableType)
    return {
        GetName = function() return name end,
        GetVariable = function() return variable end,
        GetVariableType = function() return variableType or "boolean" end,
    }
end

local function makeCategory(name, id)
    return {
        GetName = function() return name end,
        GetID = function() return id or 1 end,
    }
end

local function loadOptionsSearch(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    env.GetCVar = function(variable)
        return opts.cvars and opts.cvars[variable] or nil
    end
    env.Settings = {
        GetSetting = function(variable)
            return opts.settings and opts.settings[variable] or nil
        end,
    }
    env.SettingsPanel = opts.settingsPanel

    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function(self)
        self.resetCount = (self.resetCount or 0) + 1
    end

    -- The module ships as the EasyFind_Settings companion, which reads the
    -- parent addon's ns via the EasyFind._ns handshake.
    env.EasyFind._ns = ns
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns
end

local function findByVariable(data, variable)
    for i = 1, #data do
        if data[i].settingVariable == variable then
            return data[i]
        end
    end
    return nil
end

local function hasKeyword(entry, keyword)
    if not entry or not entry.keywords then return false end
    for i = 1, #entry.keywords do
        if entry.keywords[i] == keyword then return true end
    end
    return false
end

local tests = {}

function tests.fastGameOptionsSkipUnregisteredHumanizedProxy()
    local ns = loadOptionsSearch({
        settings = {
            autoLootDefault = makeSetting("Auto Loot"),
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "PROXY_SHOW_HELM"),
        "unregistered proxy variables should not be humanized into results")
    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "autoLootDefault"),
        "registered settings should still be available in the fast pass")
end

function tests.fastFallbackNamesRequireLiveBacking()
    local ns = loadOptionsSearch()

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateMotion"),
        "fallback CVar labels should not emit without a live CVar")
    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "PROXY_VIEW_DISTANCE"),
        "explicitly supported SettingsPanel proxy rows should still emit")
end

function tests.fastFallbackNamesAllowLiveCVars()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateMotion = "0",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNotNil(findByVariable(ns.Database.uiSearchData, "nameplateMotion"),
        "fallback CVar labels should emit when the CVar exists")
end

function tests.fastGameOptionsDoNotHumanizeRawLiveCVars()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateShowEnemyMinions = "1",
            nameplateShowEnemyMinus = "1",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateShowEnemyMinions"),
        "raw live CVars should not be humanized into fake Settings rows")
    H.assertNil(findByVariable(ns.Database.uiSearchData, "nameplateShowEnemyMinus"),
        "raw live CVars should not be humanized into fake Settings rows")
end

function tests.fastNameplateFallbackUsesVisibleSettingsLabel()
    local ns = loadOptionsSearch({
        cvars = {
            nameplateShowEnemies = "1",
        },
    })

    ns.BlizzOptionsSearch:EnsureFastGameOptions()

    local entry = findByVariable(ns.Database.uiSearchData, "nameplateShowEnemies")
    H.assertNotNil(entry, "enemy unit nameplate should be available in the fast pass")
    H.assertEq(entry.name, "Enemy Unit Nameplate")
    H.assertTrue(hasKeyword(entry, "enemy nameplate"),
        "common reordered query should be an explicit keyword")
end

function tests.liveDropdownOptionLabelsBecomeSearchKeywords()
    local cat = makeCategory("Interface", 1)
    local setting = makeLiveSetting("Nameplate Aura Display", "testNameplateAuraDisplay", "number")
    local init = {
        data = {
            setting = setting,
            options = {
                { value = 1, label = "Mob Buffs, Personal Debuffs, Shared CC" },
            },
        },
    }
    local ns = loadOptionsSearch({
        settingsPanel = {
            GetAllCategories = function() return { cat } end,
            GetLayout = function(_, category)
                if category ~= cat then return nil end
                return {
                    GetInitializers = function() return { init } end,
                }
            end,
        },
    })

    local entries = ns.BlizzOptionsSearch.CollectGameSettings()
    local entry = findByVariable(entries, "testNameplateAuraDisplay")

    H.assertNotNil(entry, "live SettingsPanel dropdown rows should be collected")
    H.assertTrue(hasKeyword(entry, "mob buffs, personal debuffs, shared cc"),
        "dropdown option labels should be searchable on the owning setting row")
end

function tests.liveSettingsCanFillCuratedVariablesMissingFromFastPass()
    local cat = makeCategory("Interface", 1)
    local setting = makeLiveSetting("Enemy Player Names", "UnitNameEnemyPlayerName", "boolean")
    local init = {
        data = {
            setting = setting,
        },
    }
    local ns = loadOptionsSearch({
        settingsPanel = {
            GetAllCategories = function() return { cat } end,
            GetLayout = function(_, category)
                if category ~= cat then return nil end
                return {
                    GetInitializers = function() return { init } end,
                }
            end,
        },
    })

    local entries = ns.BlizzOptionsSearch.CollectGameSettings()
    local entry = findByVariable(entries, "UnitNameEnemyPlayerName")

    H.assertNotNil(entry,
        "live SettingsPanel rows should not be suppressed just because the variable is curated")
    H.assertEq(entry.name, "Enemy Player Names")
end

function tests.searchLowerStripsMarkupInsideNames()
    local ns = loadOptionsSearch()
    local lower = ns.BlizzOptionsSearch.SearchLower
    H.assertEq(lower("Better|cff00c0ffBlizz|rFrames |A:gmchat-icon-blizz:16:16|a"), "betterblizzframes",
        "color codes and texture escapes must not survive into the searchable name")
    H.assertEq(lower("Auto Loot"), "auto loot", "plain names are only lowered")
    H.assertEq(lower("|cff00ff00|r"), "|cff00ff00|r", "a name that is only markup keeps its raw form")
end

local pass, fail, failures = H.runSuite("BlizzOptionsSearch", tests)
return { pass = pass, fail = fail, failures = failures }
