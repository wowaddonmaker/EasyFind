local _, ns = ...

local Data = {}
ns.MapSearchData = Data

Data.STAR_GLOW_TEXTURE = "Interface\\Cooldown\\star4"
Data.ANIM_DURATION = 0.5

Data.INDICATOR_STYLES = {
    ["Classic Quest Arrow"] = {
        texture = "Interface\\MINIMAP\\MiniMap-QuestArrow",
        texCoord = nil,
        preRotated = false,
    },
    ["EasyFind Arrow"] = {
        texture = "Interface\\AddOns\\EasyFind\\Images\\arrow-hq",
        texCoord = nil,
        preRotated = true,
    },
    ["Minimap Player Arrow"] = {
        texture = "Interface\\Minimap\\MinimapArrow",
        texCoord = nil,
        preRotated = false,
    },
    ["Low-res Gauntlet"] = {
        texture = "Interface\\CURSOR\\Point",
        texCoord = nil,
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,
        offsetY = 0,
    },
    ["HD Gauntlet"] = {
        texture = 6116532,
        texCoord = {0.000, 0.240, 0.000, 0.420},
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,
        offsetY = 0,
    },
}
Data.INDICATOR_COLORS = {
    ["Yellow"]  = {1.0, 1.0, 0.0},
    ["Gold"]    = {1.0, 0.82, 0.0},
    ["Orange"]  = {1.0, 0.5, 0.0},
    ["Red"]     = {1.0, 0.2, 0.2},
    ["Green"]   = {0.2, 1.0, 0.2},
    ["Blue"]    = {0.3, 0.6, 1.0},
    ["Purple"]  = {0.7, 0.3, 1.0},
    ["White"]   = {1.0, 1.0, 1.0},
}

Data.CATEGORY_ICONS = {
    flightmaster = "atlas:TaxiNode_Neutral",
    zeppelin = 342918,
    boat = 1126431,
    portal = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
    tram = "Interface\\Icons\\INV_Misc_Gear_01",
    -- The 1121272 sheet's icons are wrapped in a wide soft glow that gets
    -- clipped inside the row's icon slot; these atlases are tight, no-bleed.
    dungeon = "atlas:Dungeon",
    raid    = "atlas:Raid",
    delve   = { file = 1121272, coords = { 0.0000, 0.0620, 0.3903, 0.4509 } },
    bank = 136453,
    guildbank = 136453,
    personalbank = 136453,
    auctionhouse = 136452,
    innkeeper = 136458,
    trainer = 136463,
    proftrainer = 136463,
    classtrainer = { file = 131016, coords = { 0.000, 0.250, 0.375, 0.500 } },
    classtrainer_deathknight = "atlas:classicon-deathknight",
    classtrainer_demonhunter = "atlas:classicon-demonhunter",
    classtrainer_druid       = "atlas:classicon-druid",
    classtrainer_evoker      = "atlas:classicon-evoker",
    classtrainer_hunter      = "atlas:classicon-hunter",
    classtrainer_mage        = "atlas:classicon-mage",
    classtrainer_monk        = "atlas:classicon-monk",
    classtrainer_paladin     = "atlas:classicon-paladin",
    classtrainer_priest      = "atlas:classicon-priest",
    classtrainer_rogue       = "atlas:classicon-rogue",
    classtrainer_shaman      = "atlas:classicon-shaman",
    classtrainer_warlock     = "atlas:classicon-warlock",
    classtrainer_warrior     = "atlas:classicon-warrior",
    prof_alchemy = "Interface\\Icons\\Trade_Alchemy",
    prof_blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    prof_cooking = "Interface\\Icons\\INV_Misc_Food_15",
    prof_enchanting = "Interface\\Icons\\Trade_Engraving",
    prof_engineering = "Interface\\Icons\\Trade_Engineering",
    prof_fishing = "Interface\\Icons\\Trade_Fishing",
    prof_herbalism = "Interface\\Icons\\Trade_Herbalism",
    prof_inscription = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    prof_jewelcrafting = "Interface\\Icons\\INV_Misc_Gem_01",
    prof_leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
    prof_mining = "Interface\\Icons\\Trade_Mining",
    prof_skinning = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    prof_tailoring = "Interface\\Icons\\Trade_Tailoring",
    prof_firstaid = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
    prof_archaeology = "Interface\\Icons\\Trade_Archaeology",
    trainingdummy = "Interface\\Icons\\Ability_Warrior_Charge",
    vendor = "Interface\\Icons\\INV_Misc_Bag_07",
    pvpvendor = 236396,
    pvpquest = 236396,
    battlemasters = 236396,
    quartermaster = { file = 1121272, coords = { 0.5090, 0.5390, 0.6070, 0.6370 } },
    mailbox = 136459,
    stablemaster = 136466,
    repairvendor = 136465,
    barber = 3852099,
    transmogrifier = 1598183,
    rare = { file = 1121272, coords = { 0.7796, 0.8381, 0.1934, 0.2531 } },
    treasure = "Interface\\Icons\\INV_Misc_Bag_10",
    catalyst = { file = 1121272, coords = { 0.5097, 0.5390, 0.4078, 0.4363 } },
    greatvault = "Interface\\Icons\\INV_Misc_Lockbox_1",
    upgradevendor = 4025144,
    guildservices = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
    voidstorage = "Interface\\Icons\\INV_Enchant_VoidCrystal",
    tradingpost = "Interface\\Icons\\tradingpostcurrency",
    decor = { file = 1121272, coords = { 0.4078, 0.4380, 0.8713, 0.9040 } },
    chromie = "atlas:ChromieTime-32x32",
    lorewalker = { file = 1121272, coords = { 0.2027, 0.2404, 0.5966, 0.6261 } },
    craftingorders = { file = 1121272, coords = { 0.8764, 0.9040, 0.5102, 0.5357 } },
    rostrum = { file = 1121272, coords = { 0.7738, 0.8033, 0.4066, 0.4394 } },
    pettrainer = "atlas:WildBattlePetCapturable",
    ridingtrainer = "atlas:StableMaster",
    areapoi = "Interface\\Icons\\INV_Misc_QuestionMark",
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
}

Data.CATEGORIES = {
    travel = { keywords = {"travel", "transport", "transportation", "getting around"} },
    instance = { keywords = {"instance", "instances", "group content"} },
    service = { keywords = {"service", "services", "npc"} },

    flightmaster = { keywords = {"flight", "fly", "flight master", "flight point", "fp", "taxi"}, parent = "travel" },
    zeppelin = { keywords = {"zeppelin", "zep", "airship", "blimp"}, parent = "travel" },
    boat = { keywords = {"boat", "ship", "ferry"}, parent = "travel" },
    portal = { keywords = {"portal", "portals", "teleport", "mage"}, parent = "travel" },
    tram = { keywords = {"tram", "deeprun"}, parent = "travel" },

    dungeon = { keywords = {"dungeon", "dungeons", "5 man", "5man", "mythic", "heroic"}, parent = "instance" },
    raid = { keywords = {"raid", "raids", "raiding"}, parent = "instance" },
    delve = { keywords = {"delve", "delves"}, parent = "instance" },

    bank = { keywords = {"bank", "vault", "storage", "guild bank", "personal bank"}, parent = "service" },
    auctionhouse = { keywords = {"auction", "ah", "auction house"}, parent = "service" },
    innkeeper = { keywords = {"inn", "innkeeper", "rest", "hearthstone"}, parent = "service" },
    trainer = { keywords = {"trainer", "training", "class trainer"}, parent = "service" },
    vendor = { keywords = {"vendor", "merchant", "shop", "buy", "sell"}, parent = "service" },
    pvpvendor = { keywords = {"pvp vendor", "honor vendor", "conquest vendor", "arena vendor", "battleground vendor", "pvp gear"}, parent = "service" },
    quartermaster = { keywords = {"quartermaster", "qtr", "gear vendor", "currency vendor"}, parent = "service" },
    mailbox = { keywords = {"mail", "mailbox"}, parent = "service" },
    stablemaster = { keywords = {"stable", "stable master", "pet"}, parent = "service" },
    repairvendor = { keywords = {"repair", "repairs", "anvil"}, parent = "service" },
    barber = { keywords = {"barber", "barbershop", "appearance", "haircut"}, parent = "service" },
    transmogrifier = { keywords = {"transmog", "transmogrifier", "appearance"}, parent = "service" },

    prof_blacksmithing = { keywords = {"blacksmithing", "bs"}, parent = "service" },
    prof_jewelcrafting = { keywords = {"jewelcrafting", "jc"}, parent = "service" },
    prof_leatherworking = { keywords = {"leatherworking", "lw"}, parent = "service" },

    rare = { keywords = {"rare", "rares", "silver dragon", "elite"} },
    treasure = { keywords = {"treasure", "chest", "loot"} },
    catalyst = { keywords = {"catalyst", "tier", "tier set", "revival catalyst", "upgrade"}, parent = "service" },
    greatvault = { keywords = {"great vault", "vault", "weekly rewards", "weekly chest"}, parent = "service" },
    upgradevendor = { keywords = {"upgrade", "upgrade vendor", "flightstone", "crest"}, parent = "service" },
    tradingpost = { keywords = {"trading post", "trader's tender", "tender", "tmog", "xmog"}, parent = "service" },
    decor = { keywords = {"decor", "decoration", "decorations", "decorator", "housing", "furniture"}, parent = "service" },
    lorewalker = { keywords = {"lorewalker", "cho", "lore walker", "pandaria lore", "flashback", "replay cinematic"}, parent = "service" },
}

Data.GLOBAL_SEARCH_CATEGORIES = {
    dungeon = true,
    raid = true,
    delve = true,
}



ns.INDICATOR_STYLES = Data.INDICATOR_STYLES
ns.INDICATOR_COLORS = Data.INDICATOR_COLORS
