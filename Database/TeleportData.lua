local _, ns = ...

-- Mythic+ dungeon teleports ("Path of ..." spellbook spells) are only
-- findable by their flavor names; searching the DUNGEON name found nothing
-- (CurseForge request: "kar" / "karazhan" should surface Path of the
-- Fallen Guardian). Each known teleport spell maps to its dungeon so the
-- abilities provider can append dungeon-derived keywords: the LOCALIZED
-- instance name from the Encounter Journal (free translation), the English
-- name as a fallback keyword, the community abbreviation, and the shared
-- teleport terms. A wrong or removed spellID is harmless: the spellbook
-- walk never enumerates it, so nothing attaches. Audit the table in-game
-- with the external teleport probe, which resolves both name columns
-- without needing to own any of the spells.
--
-- ej = journal instance ID (EJ_GetInstanceInfo); en = English dungeon
-- name (keyword fallback when the journal cannot resolve); kw = extra
-- community abbreviations.
ns.DUNGEON_TELEPORT_SPELLS = {
    -- Every destination below is client-proven: the spell's own tooltip
    -- description names it ("Teleport to the entrance ..."), captured via
    -- the external teleport scanner. ej values are audited in-game.
    -- Mists of Pandaria
    [131204] = { ej = 313,  en = "Temple of the Jade Serpent", kw = { "tjs", "jade" } },
    [131205] = { ej = 302,  en = "Stormstout Brewery", kw = { "brewery", "stormstout" } },
    [131206] = { ej = 312,  en = "Shado-Pan Monastery", kw = { "spm", "shadopan" } },
    [131222] = { ej = 321,  en = "Mogu'shan Palace", kw = { "msp", "mogushan" } },
    [131225] = { ej = 303,  en = "Gate of the Setting Sun", kw = { "gss" } },
    [131228] = { ej = 324,  en = "Siege of Niuzao Temple", kw = { "niuzao", "siege" } },
    [131229] = { ej = 316,  en = "Scarlet Monastery", kw = { "sm", "scarlet" } },
    [131231] = { ej = 311,  en = "Scarlet Halls", kw = { "sh", "scarlet" } },
    [131232] = { ej = 246,  en = "Scholomance", kw = { "scholo" } },
    -- Warlords of Draenor
    [159895] = { ej = 385,  en = "Bloodmaul Slag Mines", kw = { "bsm", "bloodmaul" } },
    [159896] = { ej = 558,  en = "Iron Docks", kw = { "docks" } },
    [159897] = { ej = 547,  en = "Auchindoun", kw = { "auch" } },
    [159898] = { ej = 476,  en = "Skyreach", kw = { "sr", "skyreach" } },
    [159899] = { ej = 537,  en = "Shadowmoon Burial Grounds", kw = { "sbg", "shadowmoon" } },
    [159900] = { ej = 536,  en = "Grimrail Depot", kw = { "grimrail" } },
    [159901] = { ej = 556,  en = "The Everbloom", kw = { "eb", "everbloom" } },
    [159902] = { ej = 559,  en = "Upper Blackrock Spire", kw = { "ubrs", "blackrock" } },
    -- Legion
    [393764] = { ej = 721,  en = "Halls of Valor", kw = { "hov", "valor" } },
    [393766] = { ej = 800,  en = "Court of Stars", kw = { "cos" } },
    [424153] = { ej = 740,  en = "Black Rook Hold", kw = { "brh" } },
    [424163] = { ej = 762,  en = "Darkheart Thicket", kw = { "dht", "darkheart" } },
    -- Battle for Azeroth
    [410071] = { ej = 1001, en = "Freehold", kw = { "fh" } },
    [410074] = { ej = 1022, en = "The Underrot", kw = { "ur", "underrot" } },
    [424167] = { ej = 1021, en = "Waycrest Manor", kw = { "wm", "waycrest" } },
    [424187] = { ej = 968,  en = "Atal'Dazar", kw = { "ad", "atal" } },
    [445418] = { ej = 1023, en = "Siege of Boralus", kw = { "sob", "boralus", "siege" } },
    [464256] = { ej = 1023, en = "Siege of Boralus", kw = { "sob", "boralus", "siege" } },
    [467553] = { ej = 1012, en = "The MOTHERLODE!!", kw = { "ml", "motherlode" } },
    [467555] = { ej = 1012, en = "The MOTHERLODE!!", kw = { "ml", "motherlode" } },
    [1286828] = { en = "Temple of Sethraliss", kw = { "tos", "sethraliss" } },
    [1286831] = { en = "Kings' Rest", kw = { "kr", "kings rest" } },
    -- Cataclysm
    [410078] = { ej = 767,  en = "Neltharion's Lair", kw = { "nl" } },
    [410080] = { ej = 68,   en = "The Vortex Pinnacle", kw = { "vp", "vortex" } },
    [424142] = { ej = 65,   en = "Throne of the Tides", kw = { "tott", "throne" } },
    [445424] = { ej = 71,   en = "Grim Batol", kw = { "gb", "grim", "batol" } },
    -- Wrath of the Lich King
    [1254555] = { en = "Pit of Saron", kw = { "pos", "saron" } },
    -- Burning Crusade
    [1254572] = { en = "Magisters' Terrace", kw = { "mgt", "magisters", "terrace" } },
    -- Shadowlands
    [354462] = { ej = 1182, en = "The Necrotic Wake", kw = { "nw" } },
    [354463] = { ej = 1183, en = "Plaguefall", kw = { "pf" } },
    [354464] = { ej = 1184, en = "Mists of Tirna Scithe", kw = { "mots", "mists" } },
    [354465] = { ej = 1185, en = "Halls of Atonement", kw = { "hoa" } },
    [354466] = { ej = 1186, en = "Spires of Ascension", kw = { "soa", "spires" } },
    [354467] = { ej = 1187, en = "Theater of Pain", kw = { "top" } },
    [354468] = { ej = 1188, en = "De Other Side", kw = { "dos" } },
    [354469] = { ej = 1189, en = "Sanguine Depths", kw = { "sd" } },
    [367416] = { ej = 1194, en = "Tazavesh, the Veiled Market", kw = { "taz", "tazavesh" } },
    [1254551] = { en = "Seat of the Triumvirate", kw = { "sot", "triumvirate" } },
    -- Dragonflight
    [393222] = { ej = 1197, en = "Uldaman: Legacy of Tyr", kw = { "uld", "uldaman" } },
    [393256] = { ej = 1202, en = "Ruby Life Pools", kw = { "rlp" } },
    [393262] = { ej = 1198, en = "The Nokhud Offensive", kw = { "nokhud" } },
    [393267] = { ej = 1196, en = "Brackenhide Hollow", kw = { "bh", "brackenhide" } },
    [393273] = { ej = 1201, en = "Algeth'ar Academy", kw = { "aa", "academy" } },
    [393276] = { ej = 1199, en = "Neltharus", kw = { "nel" } },
    [393279] = { ej = 1203, en = "The Azure Vault", kw = { "av", "azure" } },
    [393283] = { ej = 1204, en = "Halls of Infusion", kw = { "hoi" } },
    [424197] = { ej = 1209, en = "Dawn of the Infinite", kw = { "doti", "infinite" } },
    -- The War Within
    [445269] = { ej = 1269, en = "The Stonevault", kw = { "sv", "stonevault" } },
    [445414] = { ej = 1270, en = "The Dawnbreaker", kw = { "db", "dawnbreaker" } },
    [445416] = { ej = 1274, en = "City of Threads", kw = { "cot", "threads" } },
    [445417] = { ej = 1271, en = "Ara-Kara, City of Echoes", kw = { "ak", "arakara", "ara" } },
    [445440] = { ej = 1272, en = "Cinderbrew Meadery", kw = { "cm", "cinderbrew", "brew" } },
    [467546] = { ej = 1272, en = "Cinderbrew Meadery", kw = { "cm", "cinderbrew", "brew" } },
    [445441] = { ej = 1210, en = "Darkflame Cleft", kw = { "dfc", "darkflame" } },
    [445443] = { ej = 1268, en = "The Rookery", kw = { "rook", "rookery" } },
    [445444] = { ej = 1267, en = "Priory of the Sacred Flame", kw = { "psf", "priory" } },
    [1216786] = { en = "Operation: Floodgate", kw = { "floodgate" } },
    [1226482] = { en = "Liberation of Undermine", kw = { "undermine", "liberation" } },
    [1237215] = { en = "Eco-Dome Al'dani", kw = { "ecodome", "aldani" } },
    [1239155] = { en = "Manaforge Omega", kw = { "manaforge", "omega" } },
    -- Midnight
    [1254400] = { en = "Windrunner Spire", kw = { "windrunner", "spire" } },
    [1254557] = { ej = 476, en = "Skyreach", kw = { "sr", "skyreach" } },
    [1254559] = { en = "Maisara Caverns", kw = { "maisara" } },
    [1254563] = { en = "Nexus-Point Xenas", kw = { "nexus", "xenas" } },
    [1286801] = { en = "The Blinding Vale", kw = { "blinding", "vale" } },
    [1286804] = { en = "Voidscar Arena", kw = { "voidscar" } },
    [1286807] = { en = "Den of Nalorakk", kw = { "nalorakk" } },
    [1286809] = { en = "Murder Row", kw = { "murder row" } },
    [1286812] = { en = "Altar of Fangs", kw = { "fangs" } },
}

-- Trigger words for the search engine: the abilities provider is LAZY and
-- loads on its own trigger words or a low-result fallback -- a dungeon-name
-- query like "karazhan" trips neither (the catalog alone yields plenty of
-- results), so without these the teleport rows silently cannot exist in
-- the search until something else loads abilities. Static words come from
-- the table at load; localized dungeon-name words join as the journal
-- resolves them. Two-character abbreviations stay out (they ride the
-- low-result fallback instead); stopwords never trigger.
local TRIGGER_STOPWORDS = { ["the"] = true, ["of"] = true, ["de"] = true, ["la"] = true }
local triggers = { teleport = true, portal = true, dungeon = true, keystone = true, mythic = true }
ns.DUNGEON_TELEPORT_TRIGGERS = triggers

local function AddTriggerWords(text)
    for word in text:gmatch("[^%s:,!']+") do
        if #word >= 3 and not TRIGGER_STOPWORDS[word] then
            triggers[word] = true
        end
    end
end

-- Shared terms every teleport row answers to. (A localized "teleport"
-- keyword would need a probe-verified Blizzard GlobalString key; the
-- localized DUNGEON name below is the piece that matters per locale.)
local sharedTeleportKw

local slower = string.lower
local resolvedNames = {}

for _, entry in pairs(ns.DUNGEON_TELEPORT_SPELLS) do
    AddTriggerWords(slower(entry.en))
    local extra = entry.kw
    if extra then
        for i = 1, #extra do
            AddTriggerWords(extra[i])
        end
    end
end

local function InstanceNameOf(mapEntry)
    local cached = resolvedNames[mapEntry]
    if cached ~= nil then return cached or nil end
    local name
    if mapEntry.ej and EJ_GetInstanceInfo then
        local ok, ejName = pcall(EJ_GetInstanceInfo, mapEntry.ej)
        if ok and type(ejName) == "string" and ejName ~= "" then
            name = ejName
            AddTriggerWords(slower(ejName))
        end
    end
    resolvedNames[mapEntry] = name or false
    return name
end

-- Appends this teleport's dungeon keywords to an ability row's keyword
-- list: localized dungeon name (whole, plus per-word for word-overlap
-- scoring), English fallback name, abbreviations, shared teleport terms.
-- Returns true when spellID is a mapped teleport (keywords appended).
function ns.AppendDungeonTeleportKeywords(kw, spellID)
    local map = ns.DUNGEON_TELEPORT_SPELLS
    local entry = map and map[spellID]
    if not entry then return false end
    if not sharedTeleportKw then
        sharedTeleportKw = { "teleport", "tp", "portal", "dungeon", "keystone", "mythic" }
    end
    local localized = InstanceNameOf(entry)
    if localized then
        kw[#kw + 1] = slower(localized)
    end
    local en = slower(entry.en)
    if not localized or slower(localized) ~= en then
        kw[#kw + 1] = en
    end
    local extra = entry.kw
    if extra then
        for i = 1, #extra do
            kw[#kw + 1] = extra[i]
        end
    end
    for i = 1, #sharedTeleportKw do
        kw[#kw + 1] = sharedTeleportKw[i]
    end
    return true
end
