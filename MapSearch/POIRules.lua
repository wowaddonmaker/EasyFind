local _, ns = ...

local Utils = ns.Utils
local sfind = Utils.sfind
local ipairs = Utils.ipairs

local Rules = {}
ns.MapSearchPOIRules = Rules

local TEXT_CATEGORY_RULES = {
    { category = "zeppelin", name = {"zeppelin", "airship"}, scanDesc = {"zeppelin"} },
    { category = "boat", name = {"boat", "ship", "ferry"}, scanDesc = {"boat"} },
    { category = "portal", name = {"portal"}, scanDesc = {"teleport"}, scanExcludeName = {"dark portal"} },
    { category = "tram", name = {"tram"}, scanDesc = {"tram"} },
    { category = "greatvault", name = {"great vault"}, scanOnly = true },
    { category = "catalyst", name = {"catalyst"}, scanOnly = true },
    { category = "auctionhouse", name = {"auction"}, scanOnly = true },
    { category = "bank", name = {"bank"}, scanExcludeName = {"moat"}, scanOnly = true },
    { category = "innkeeper", name = {"innkeeper", "inn"}, scanOnly = true },
    { category = "flightmaster", name = {"flight master", "flight point"}, scanOnly = true },
    { category = "tradingpost", name = {"trading post"} },
    { category = "quartermaster", name = {"quartermaster"} },
    { category = "decor", name = {"decor"} },
    {
        category = "pvpvendor",
        name = {"conquest", "honor", "pvp"},
        pinName = {"pvp", "arena", "battleground", "conquest", "honor", "weekly"},
        pinDesc = {"pvp"},
    },
    { category = "chromie", name = {"chromie"} },
}
Rules.TEXT_CATEGORY_RULES = TEXT_CATEGORY_RULES

local function TextHasAny(text, terms)
    if not text or not terms then return false end
    for i = 1, #terms do
        if sfind(text, terms[i], 1, true) then
            return true
        end
    end
    return false
end

local function AreaRuleMatches(rule, nameLower, descLower)
    local nameMatches = TextHasAny(nameLower, rule.name)
        and not TextHasAny(nameLower, rule.scanExcludeName)
    return nameMatches or TextHasAny(descLower, rule.scanDesc)
end

function Rules.ResolveAreaPOICategory(nameLower, descLower)
    for _, rule in ipairs(TEXT_CATEGORY_RULES) do
        if AreaRuleMatches(rule, nameLower, descLower) then
            return rule.category
        end
    end
    return nil
end

function Rules.ResolvePinAreaPOICategory(nameLower, descLower)
    for _, rule in ipairs(TEXT_CATEGORY_RULES) do
        if not rule.scanOnly
           and (TextHasAny(nameLower, rule.pinName or rule.name) or TextHasAny(descLower, rule.pinDesc)) then
            return rule.category
        end
    end
    return nil
end
