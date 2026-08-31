-- Tests for the PackedCorpus lazy-stub store (Shared/Utils.lua): stubs must
-- serve proto fields and gate masks WITHOUT touching the blob, hydrate
-- correct field values on demand, shed back to bare, and index through
-- SearchIndex's transient corpus path without hydrating. Loads the REAL
-- Shared/Utils.lua (widget calls stubbed) so the shipped decode is under test.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFont = fakeWidget
env.CreateFrame = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })

H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

local SPEC = {
    { "name" }, { "icon" }, { "mountID" }, { "spellID" },
    { "isCollected" }, { "tags", "list" },
}
local PROTO = {
    keywords      = { "mount", "ride" },
    keywordsLower = { "mount", "ride" },
    category      = "Mount",
    path          = {},
    steps         = {},
}

local ROWS = {
    { name = "Swift Gladiator Drake", icon = 12345, mountID = 1, spellID = 100,
      isCollected = true, tags = { "pvp", "flying" } },
    { name = "Back\\slash \31weird\30 name", icon = 22, mountID = 2, spellID = 200,
      isCollected = false },
    { name = "Zephyr", icon = 33, mountID = 3, spellID = 300, isCollected = true },
    { name = "ALL CAPS CHARGER", icon = 44, mountID = 4, spellID = 400,
      isCollected = false },
}

local packed = Utils.PackRows(ROWS, SPEC)

local function newCorpus(opts)
    return Utils.NewPackedCorpus(packed, SPEC, PROTO, opts)
end

-- The scorer's own mask semantics, applied to the decoded values: what
-- FillEntryGateMask (Database/Search.lua) would compute for a hydrated entry.
local function referenceMasks(row)
    local cm, im = Utils.AccumulateGateMasks(row.name:lower(), 0, 0)
    for _, kw in ipairs(PROTO.keywordsLower) do
        cm, im = Utils.AccumulateGateMasks(kw, cm, im)
    end
    return cm, im
end

local tests = {}

function tests.rowCount_andDecodeIdentity()
    local corpus = newCorpus()
    H.assertEq(corpus.count, #ROWS, "row count")
    local reference = Utils.UnpackRows(packed, SPEC)
    local seen = 0
    corpus:EachRow(function(ri, row)
        seen = seen + 1
        local ref = reference[ri]
        for _, field in ipairs(SPEC) do
            local key = field[1]
            if key == "tags" then
                local a, b = row.tags, ref.tags
                H.assertEq(not b, not a, "tags presence row " .. ri)
                if a then
                    H.assertEq(#a, #b, "tags length row " .. ri)
                    for i = 1, #b do H.assertEq(a[i], b[i], "tag " .. i) end
                end
            else
                H.assertEq(row[key], ref[key], key .. " row " .. ri)
            end
        end
    end)
    H.assertEq(seen, #ROWS, "EachRow visits every row")
end

function tests.protoAndMasks_serveWithoutHydration()
    local corpus = newCorpus()
    local stub = corpus:StubAt(1)
    H.assertEq(stub.category, "Mount", "proto category")
    H.assertEq(stub.keywordsLower, PROTO.keywordsLower, "proto keywords by reference")
    H.assertEq(type(stub._efGateMask), "number", "gate mask served")
    H.assertEq(type(stub._efGateInit), "number", "gate init served")
    H.assertEq(stub.lootEntry, nil, "unknown key reads nil")
    H.assertEq(rawget(stub, "name"), nil, "no hydration from proto/mask/unknown reads")
    H.assertEq(rawget(stub, "nameLower"), nil, "no nameLower either")
end

function tests.gateMasks_matchScorerSemantics()
    local corpus = newCorpus()
    for ri = 1, #ROWS do
        local cm, im = referenceMasks(ROWS[ri])
        H.assertEq(corpus.gateMasks[ri], cm, "cm row " .. ri)
        H.assertEq(corpus.gateInits[ri], im, "im row " .. ri)
    end
end

function tests.nameTier_thenPerFieldHydration()
    local corpus = newCorpus()
    local stub = corpus:StubAt(2)
    H.assertEq(stub.nameLower, "back\\slash \31weird\30 name", "escaped nameLower")
    H.assertEq(rawget(stub, "name"), "Back\\slash \31weird\30 name", "name memoized")
    H.assertEq(rawget(stub, "icon"), nil, "name tier leaves the rest cold")
    H.assertEq(stub.icon, 22, "spec field decodes on read")
    H.assertEq(rawget(stub, "icon"), 22, "and memoizes")
    H.assertEq(rawget(stub, "spellID"), nil, "OTHER fields stay cold (per-field, not full-row)")
    H.assertEq(stub.spellID, 200, "each field decodes independently")
    H.assertEq(stub.isCollected, false, "boolean false round-trips")
    H.assertEq(stub.tags, nil, "nil list field stays nil")
end

function tests.caseFolding_inNameAndMask()
    local corpus = newCorpus()
    local stub = corpus:StubAt(4)
    H.assertEq(stub.nameLower, "all caps charger", "lowercased")
    local cm = referenceMasks(ROWS[4])
    H.assertEq(stub._efGateMask, cm, "mask from folded caps")
end

function tests.shed_restoresBareStub_keepsIdentityAndForeignWrites()
    local corpus = newCorpus()
    local stub = corpus:StubAt(1)
    H.assertEq(stub.nameLower, "swift gladiator drake", "hydrate first")
    H.assertEq(stub.icon, 12345, "full hydrate")
    stub.runtimeFlag = "kept"
    corpus:Shed()
    H.assertEq(rawget(stub, "name"), nil, "name shed")
    H.assertEq(rawget(stub, "nameLower"), nil, "nameLower shed")
    H.assertEq(rawget(stub, "icon"), nil, "spec field shed")
    H.assertEq(rawget(stub, "runtimeFlag"), "kept", "foreign write survives")
    H.assertEq(rawget(stub, "_ri"), 1, "row index survives")
    H.assertEq(corpus:StubAt(1), stub, "identity stable")
    H.assertEq(stub.nameLower, "swift gladiator drake", "re-hydration works")
end

function tests.computedField_lazyAndShed()
    local calls = 0
    local corpus = newCorpus({ computed = {
        mountTypeID = function(stub)
            calls = calls + 1
            return stub.mountID * 10
        end,
    } })
    local stub = corpus:StubAt(3)
    H.assertEq(stub.mountTypeID, 30, "computed from hydrated field")
    H.assertEq(stub.mountTypeID, 30, "memoized")
    H.assertEq(calls, 1, "computed once")
    corpus:Shed()
    H.assertEq(rawget(stub, "mountTypeID"), nil, "computed shed")
    H.assertEq(stub.mountTypeID, 30, "recomputed after shed")
end

function tests.nameLowerOf_isTransient()
    local corpus = newCorpus()
    H.assertEq(corpus:NameLowerOf(3), "zephyr", "transient decode")
    H.assertEq(rawget(corpus:StubAt(3), "nameLower"), nil, "no memoization")
end

function tests.registry_replaceAndShedAll()
    local corpus = newCorpus()
    Utils.RegisterCorpus("test", corpus)
    H.assertEq(Utils.GetCorpus("test"), corpus, "registry lookup")
    local stub = corpus:StubAt(1)
    local _ = stub.nameLower
    Utils.ShedCorpora()
    H.assertEq(rawget(stub, "nameLower"), nil, "ShedCorpora sheds registered corpora")
    Utils.RegisterCorpus("test", nil)
end

function tests.searchIndex_indexesStubsWithoutHydrating()
    local corpus = newCorpus()
    local data = {}
    for ri = 1, corpus.count do data[ri] = corpus:StubAt(ri) end
    local idxNs = H.newNs(env)
    idxNs.Database = { uiSearchData = data }
    H.loadModule("Database/SearchIndex.lua", env, idxNs)
    local SearchIndex = idxNs.SearchIndex

    local hits, n = SearchIndex:Candidates({ "gladiator" })
    H.assertTrue(type(hits) == "table", "candidates returned")
    local found = false
    for i = 1, n do
        if hits[i] == data[1] then found = true end
    end
    H.assertTrue(found, "gladiator stub is a candidate")

    local _, kn = SearchIndex:Candidates({ "mount" })
    H.assertTrue(kn >= corpus.count, "proto keyword indexes every stub")

    for ri = 1, corpus.count do
        H.assertEq(rawget(data[ri], "name"), nil, "indexing hydrated stub " .. ri)
    end
end

function tests.ungatedCorpus_servesFalseMasks()
    local corpus = Utils.NewPackedCorpus(packed, SPEC, PROTO, { ungated = true })
    local stub = corpus:StubAt(1)
    H.assertEq(stub._efGateMask, false, "ungated mask is false")
    H.assertEq(stub._efGateInit, false, "ungated init is false")
    H.assertEq(corpus.gateMasks, nil, "no mask arrays built")
    H.assertEq(rawget(stub, "name"), nil, "mask reads never hydrate")
end

function tests.noShedCorpus_keepsMutations()
    local corpus = Utils.NewPackedCorpus(packed, SPEC, PROTO, { noShed = true })
    local stub = corpus:StubAt(1)
    H.assertEq(stub.icon, 12345, "hydrate")
    stub.isCollected = false
    corpus:Shed()
    H.assertEq(rawget(stub, "icon"), 12345, "noShed keeps hydrated fields")
    H.assertEq(rawget(stub, "isCollected"), false, "noShed keeps mutations")
end

function tests.keywordsFor_feedsMasksAndIndexText()
    local buf = {}
    local corpus = Utils.NewPackedCorpus(packed, SPEC, PROTO, {
        keywordsFor = function(row)
            buf[1] = "zzz"
            buf[2] = row.tags and row.tags[1] or "fallback"
            for i = #buf, 3, -1 do buf[i] = nil end
            return buf
        end,
    })
    -- Row 1 has tags {pvp, flying}: mask must contain z (from zzz) and
    -- p/v (from pvp) beyond the name and proto letters.
    local cm, im = referenceMasks(ROWS[1])
    cm, im = Utils.AccumulateGateMasks("zzz", cm, im)
    cm, im = Utils.AccumulateGateMasks("pvp", cm, im)
    H.assertEq(corpus.gateMasks[1], cm, "row keywords accumulated into mask")
    H.assertEq(corpus.gateInits[1], im, "row keyword initials accumulated too")
    local kws = corpus:KeywordsOf(1)
    H.assertEq(kws[1], "zzz", "KeywordsOf serves the buffer")
    H.assertEq(kws[2], "pvp", "KeywordsOf decodes row fields")
    H.assertEq(rawget(corpus:StubAt(1), "name"), nil, "no hydration from either")
end

function tests.liteFields_serveWithoutHydration()
    local corpus = Utils.NewPackedCorpus(packed, SPEC, PROTO, { liteFields = { "icon" } })
    local stub = corpus:StubAt(2)
    H.assertEq(stub.icon, 22, "lite field served")
    H.assertEq(rawget(stub, "name"), nil, "no hydration from lite read")
    H.assertEq(rawget(stub, "icon"), nil, "lite value not memoized onto stub")
    H.assertEq(stub.mountID, 2, "full hydration still works")
    H.assertEq(stub.icon, 22, "hydrated value matches lite value")
end

function tests.computed_firesOnlyWhenBlobEmpty()
    local corpus = Utils.NewPackedCorpus(packed, SPEC, PROTO, {
        computed = { tags = function() return "DEFAULTED" end },
    })
    local withTags = corpus:StubAt(1)
    H.assertEq(withTags.tags[1], "pvp", "blob value wins over computed")
    local without = corpus:StubAt(3)
    H.assertEq(without.tags, "DEFAULTED", "computed fills the nil field")
end

local pass, fail, failures = H.runSuite("PackedCorpus", tests)
return { pass = pass, fail = fail, failures = failures }
