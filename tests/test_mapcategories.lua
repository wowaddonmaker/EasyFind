-- Tests for MapSearch/Categories.lua (keyword-to-category lookup)

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("MapSearch/Categories.lua", env, ns)

local tests = {}

function tests.keywordLookup_coversReportedTriggers()
    -- GitHub #21: the generic terms the reporter named must resolve so the
    -- local-category boost fires with zero setup.
    local map = ns.MapSearchData.KEYWORD_TO_CATEGORY
    H.assertEq(map["flight"], "flightmaster")
    H.assertEq(map["fm"], "flightmaster")
    H.assertEq(map["fp"], "flightmaster")
    H.assertEq(map["fly"], "flightmaster")
    H.assertEq(map["tp"], "portal")
    H.assertEq(map["portal"], "portal")
    H.assertEq(map["delve"], "delve")
    H.assertEq(map["bank"], "bank")
end

function tests.keywordLookup_excludesAmbiguousAndParents()
    -- Ambiguous words must not hijack unrelated searches ("mage" the class,
    -- "hearthstone" the toy), and parent groups have no POIs to resolve.
    local map = ns.MapSearchData.KEYWORD_TO_CATEGORY
    H.assertNil(map["mage"])
    H.assertNil(map["pet"])
    H.assertNil(map["hearthstone"])
    H.assertNil(map["mythic"])
    H.assertNil(map["travel"])
    H.assertNil(map["instance"])
    H.assertNil(map["service"])
end

local pass, fail, failures = H.runSuite("MapCategories", tests)
return { pass = pass, fail = fail, failures = failures }
