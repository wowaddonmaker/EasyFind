local H = require("Harness")

local function makeSetting(name, variableType)
    return {
        GetName = function() return name end,
        GetVariableType = function() return variableType or "boolean" end,
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
    env.SettingsPanel = nil

    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function(self)
        self.resetCount = (self.resetCount or 0) + 1
    end

    H.loadModule("Options/BlizzSearch.lua", env, ns)
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

local pass, fail, failures = H.runSuite("BlizzOptionsSearch", tests)
return { pass = pass, fail = fail, failures = failures }
