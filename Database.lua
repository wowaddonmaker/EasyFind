local ADDON_NAME, ns = ...

local Database = {}
ns.Database = Database

local uiSearchData = {}

function Database:Initialize()
    self:BuildUIDatabase()
end

function Database:BuildUIDatabase()
    local uiItems = {
        -- =====================
        -- MICRO MENU BUTTONS (Main UI bar) - Top level, no path
        -- =====================
        {
            name = "Character Info",
            keywords = {"character", "char", "stats", "gear", "equipment", "paperdoll", "attributes"},
            category = "Menu Bar",
            buttonFrame = "CharacterMicroButton",
            path = {},
            steps = {
                { buttonFrame = "CharacterMicroButton" }
            }
        },
        {
            name = "Character Stats",
            keywords = {"character stats", "character sheet", "paperdoll", "equipment", "gear stats", "item level"},
            category = "Character Info",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 1 },
                { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 1 }
            }
        },
        {
            name = "Titles",
            keywords = {"titles", "title", "character title", "name title", "prefix", "suffix"},
            category = "Character Info",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 1 },
                { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 2 }
            }
        },
        {
            name = "Equipment Manager",
            keywords = {"equipment manager", "gear sets", "equipment sets", "outfitter", "save gear", "load gear", "gear manager"},
            category = "Character Info",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 1 },
                { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 3 }
            }
        },
        {
            name = "Reputation",
            keywords = {"reputation", "rep", "faction", "factions", "standing", "renown"},
            category = "Character Info",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 2 }
            }
        },
        {
            name = "Currency",
            keywords = {"currency", "currencies", "gold", "tokens", "money", "valor", "conquest points", "honor", "honor points", "conquest", "bloody tokens", "bloody token", "timewarped", "timewarped badge", "traders tender", "trader's tender", "tender", "polished pet charm", "pet charm", "pet charms", "curious coin", "soulbound", "warbound", "dragon isles supplies", "awakened", "resonance crystals", "resonance", "flightstones", "flightstone", "valorstones", "valorstone", "weathered crests", "carved crests", "runed crests", "gilded crests", "crest", "crests"},
            category = "Character Info",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info"},
            flashLabel = "Currency",
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 }
            }
        },
        {
            name = "Professions",
            keywords = {"professions", "profession", "crafting", "trade skills", "skills"},
            category = "Menu Bar",
            buttonFrame = "ProfessionMicroButton",
            path = {},
            steps = {
                { buttonFrame = "ProfessionMicroButton" }
            }
        },
        {
            name = "Talents & Spellbook",
            keywords = {"talents", "spellbook", "abilities", "spec", "specialization", "spells"},
            category = "Menu Bar",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" }
            }
        },
        {
            name = "Achievements",
            keywords = {"achievement", "achievements", "achieve", "points"},
            category = "Menu Bar",
            buttonFrame = "AchievementMicroButton",
            path = {},
            steps = {
                { buttonFrame = "AchievementMicroButton" }
            }
        },
        {
            name = "Quest Log",
            keywords = {"quest", "quests", "objectives", "log", "journal"},
            category = "Menu Bar",
            buttonFrame = "QuestLogMicroButton",
            path = {},
            steps = {
                { buttonFrame = "QuestLogMicroButton" }
            }
        },
        {
            name = "Housing Dashboard",
            keywords = {"housing", "house", "home", "dashboard", "player housing", "delves housing"},
            category = "Menu Bar",
            buttonFrame = "HousingMicroButton",
            path = {},
            steps = {
                { buttonFrame = "HousingMicroButton" }
            }
        },
        {
            name = "Guild & Communities",
            keywords = {"guild", "communities", "social", "clan"},
            category = "Menu Bar",
            buttonFrame = "GuildMicroButton",
            path = {},
            steps = {
                { buttonFrame = "GuildMicroButton" }
            }
        },
        {
            name = "Group Finder",
            keywords = {"lfg", "lfd", "lfr", "dungeon finder", "raid finder", "finder", "queue", "group", "premade", "pvp", "pve"},
            category = "Menu Bar",
            buttonFrame = "LFDMicroButton",
            path = {},
            steps = {
                { buttonFrame = "LFDMicroButton" }
            }
        },
        {
            name = "Warband Collections",
            keywords = {"collections", "warband", "mounts", "pets", "toys", "heirlooms", "wardrobe", "campsites"},
            category = "Menu Bar",
            buttonFrame = "CollectionsMicroButton",
            path = {},
            steps = {
                { buttonFrame = "CollectionsMicroButton" }
            }
        },
        {
            name = "Adventure Guide",
            keywords = {"adventure", "guide", "dungeon journal", "encounters", "loot", "boss", "journal"},
            category = "Menu Bar",
            buttonFrame = "EJMicroButton",
            path = {},
            steps = {
                { buttonFrame = "EJMicroButton" }
            }
        },
        {
            name = "Game Menu",
            keywords = {"menu", "settings", "options", "escape", "esc", "logout", "quit", "exit", "interface"},
            category = "Menu Bar",
            buttonFrame = "MainMenuMicroButton",
            path = {},
            steps = {
                { buttonFrame = "MainMenuMicroButton" }
            }
        },
        {
            name = "Help",
            keywords = {"help", "support", "ticket", "bug", "report", "gm"},
            category = "Menu Bar",
            buttonFrame = "HelpMicroButton",
            path = {},
            steps = {
                { buttonFrame = "HelpMicroButton" }
            }
        },
        {
            name = "Shop",
            keywords = {"shop", "store", "blizzard shop", "cash shop", "buy", "purchase", "micro transaction"},
            category = "Menu Bar",
            buttonFrame = "StoreMicroButton",
            path = {},
            steps = {
                { buttonFrame = "StoreMicroButton" }
            }
        },
        {
            name = "Shop Appearances",
            keywords = {"shop appearance", "shop transmog", "store transmog", "cash shop appearance"},
            category = "Shop",
            buttonFrame = "StoreMicroButton",
            path = {"Shop"},
            steps = {
                { buttonFrame = "StoreMicroButton" },
                { waitForFrame = "StoreFrame", text = "Browse the Appearances section in the shop" }
            }
        },
        
        -- =====================
        -- TALENTS SUBMENU ITEMS
        -- =====================
        {
            name = "Specialization",
            keywords = {"specialization", "spec", "class spec", "change spec", "switch spec"},
            category = "Talents",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {"Talents & Spellbook"},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 1 }
            }
        },
        {
            name = "Talents",
            keywords = {"talent tree", "talent points", "class talents", "hero talents", "talents"},
            category = "Talents",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {"Talents & Spellbook"},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 2 }
            }
        },
        {
            name = "Spellbook",
            keywords = {"spellbook", "spells", "abilities", "skills", "spell book"},
            category = "Talents",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {"Talents & Spellbook"},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 3 }
            }
        },
        {
            name = "PvP Talents",
            keywords = {"pvp talents", "pvp abilities", "battleground talents", "pvp"},
            category = "Talents",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {"Talents & Spellbook", "Talents"},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 2 },
                { waitForFrame = "PlayerSpellsFrame", regionFrames = { "FIND_PVP_TALENTS" }, text = "PvP Talents are at the bottom right of the Talents pane" }
            }
        },
        {
            name = "War Mode",
            keywords = {"war mode", "warmode", "pvp toggle", "world pvp", "pvp on", "pvp off", "pvp"},
            category = "Talents",
            buttonFrame = "PlayerSpellsMicroButton",
            path = {"Talents & Spellbook", "Talents"},
            steps = {
                { buttonFrame = "PlayerSpellsMicroButton" },
                { waitForFrame = "PlayerSpellsFrame", tabIndex = 2 },
                { waitForFrame = "PlayerSpellsFrame", regionFrames = { "FIND_WARMODE_BUTTON" }, text = "War Mode toggle is the circular button at the bottom right of the Talents pane" }
            }
        },
        
        -- =====================
        -- ACHIEVEMENTS TABS
        -- =====================
        {
            name = "Achievements Tab",
            keywords = {"achievements", "achievement tab", "personal achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 }
            }
        },
        {
            name = "Guild Achievements",
            keywords = {"guild achievements", "guild tab", "guild points"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 }
            }
        },
        {
            name = "Statistics",
            keywords = {"statistics", "stats tab", "player statistics"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 }
            }
        },
        {
            name = "Duel Statistics",
            keywords = {"duel", "duels", "duel stats", "duel statistics", "dueling", "pvp duels", "1v1", "world pvp duels", "duels won", "duels lost"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "World" }
            }
        },

        -- =====================
        -- ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
        -- =====================
        {
            name = "Characters (Achievements)",
            keywords = {"characters", "characters achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Characters" },
            }
        },
        {
            name = "Collections (Achievements)",
            keywords = {"collections", "collection", "transmog", "collections achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
            }
        },
        {
            name = "Appearances (Achievements)",
            keywords = {"appearances", "appearances achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Collections"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Appearances" },
            }
        },
        {
            name = "Decor (Achievements)",
            keywords = {"decor", "decor achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Collections"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Decor" },
            }
        },
        {
            name = "Dragon Isle Drake Cosmetics (Achievements)",
            keywords = {"dragon isle drake cosmetics", "dragon", "isle", "drake", "cosmetics", "dragon isle drake cosmetics achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Collections"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragon Isle Drake Cosmetics" },
            }
        },
        {
            name = "Mounts - Collections (Achievements)",
            keywords = {"mounts", "mounts achievements", "collections mounts"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Collections"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Mounts" },
            }
        },
        {
            name = "Toy Box (Achievements)",
            keywords = {"toy box", "toy", "box", "toy box achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Collections"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collections" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Toy Box" },
            }
        },
        {
            name = "Delves (Achievements)",
            keywords = {"delves", "delves achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Delves" },
            }
        },
        {
            name = "Midnight - Delves (Achievements)",
            keywords = {"midnight", "midnight achievements", "delves midnight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Delves"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Delves" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight" },
            }
        },
        {
            name = "The War Within (Achievements)",
            keywords = {"the war within", "war", "within", "the war within achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Delves"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Delves" },
                { waitForFrame = "AchievementFrame", achievementCategory = "The War Within" },
            }
        },
        {
            name = "Dungeons & Raids (Achievements)",
            keywords = {"dungeons & raids", "dungeons", "raids", "dungeon", "raid", "dungeons & raids achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
            }
        },
        {
            name = "Battle Dungeon (Achievements)",
            keywords = {"battle dungeon", "battle", "dungeon", "battle dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" },
            }
        },
        {
            name = "Battle Raid (Achievements)",
            keywords = {"battle raid", "battle", "raid", "battle raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" },
            }
        },
        {
            name = "Cataclysm Dungeon (Achievements)",
            keywords = {"cataclysm dungeon", "cataclysm", "dungeon", "cataclysm dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" },
            }
        },
        {
            name = "Cataclysm Raid (Achievements)",
            keywords = {"cataclysm raid", "cataclysm", "raid", "cataclysm raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" },
            }
        },
        {
            name = "Classic - Dungeons & Raids (Achievements)",
            keywords = {"classic", "classic achievements", "dungeons & raids classic"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Classic" },
            }
        },
        {
            name = "Draenor Dungeon (Achievements)",
            keywords = {"draenor dungeon", "draenor", "dungeon", "draenor dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" },
            }
        },
        {
            name = "Draenor Raid (Achievements)",
            keywords = {"draenor raid", "draenor", "raid", "draenor raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" },
            }
        },
        {
            name = "Dragonflight Dungeon (Achievements)",
            keywords = {"dragonflight dungeon", "dragonflight", "dungeon", "dragonflight dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" },
            }
        },
        {
            name = "Dragonflight Raid (Achievements)",
            keywords = {"dragonflight raid", "dragonflight", "raid", "dragonflight raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" },
            }
        },
        {
            name = "Legion Dungeon (Achievements)",
            keywords = {"legion dungeon", "legion", "dungeon", "legion dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" },
            }
        },
        {
            name = "Legion Raid (Achievements)",
            keywords = {"legion raid", "legion", "raid", "legion raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" },
            }
        },
        {
            name = "Lich King Dungeon (Achievements)",
            keywords = {"lich king dungeon", "lich", "king", "dungeon", "lich king dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" },
            }
        },
        {
            name = "Lich King Raid (Achievements)",
            keywords = {"lich king raid", "lich", "king", "raid", "lich king raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" },
            }
        },
        {
            name = "Midnight Dungeon (Achievements)",
            keywords = {"midnight dungeon", "midnight", "dungeon", "midnight dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" },
            }
        },
        {
            name = "Midnight Raid (Achievements)",
            keywords = {"midnight raid", "midnight", "raid", "midnight raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" },
            }
        },
        {
            name = "Pandaria Dungeon (Achievements)",
            keywords = {"pandaria dungeon", "pandaria", "dungeon", "pandaria dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" },
            }
        },
        {
            name = "Pandaria Raid (Achievements)",
            keywords = {"pandaria raid", "pandaria", "raid", "pandaria raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" },
            }
        },
        {
            name = "Shadowlands Dungeon (Achievements)",
            keywords = {"shadowlands dungeon", "shadowlands", "dungeon", "shadowlands dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" },
            }
        },
        {
            name = "Shadowlands Raid (Achievements)",
            keywords = {"shadowlands raid", "shadowlands", "raid", "shadowlands raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" },
            }
        },
        {
            name = "The Burning Crusade - Dungeons & Raids (Achievements)",
            keywords = {"the burning crusade", "burning", "crusade", "the burning crusade achievements", "dungeons & raids the burning crusade"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" },
            }
        },
        {
            name = "War Within Dungeon (Achievements)",
            keywords = {"war within dungeon", "war", "within", "dungeon", "war within dungeon achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" },
            }
        },
        {
            name = "War Within Raid (Achievements)",
            keywords = {"war within raid", "war", "within", "raid", "war within raid achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" },
            }
        },
        {
            name = "Expansion Features (Achievements)",
            keywords = {"expansion features", "expansion", "features", "expansion features achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
            }
        },
        {
            name = "Argent Tournament (Achievements)",
            keywords = {"argent tournament", "argent", "tournament", "argent tournament achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Argent Tournament" },
            }
        },
        {
            name = "Covenant Sanctums (Achievements)",
            keywords = {"covenant sanctums", "covenant", "sanctums", "covenant sanctums achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Covenant Sanctums" },
            }
        },
        {
            name = "Draenor Garrison (Achievements)",
            keywords = {"draenor garrison", "draenor", "garrison", "draenor garrison achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor Garrison" },
            }
        },
        {
            name = "Heart of Azeroth (Achievements)",
            keywords = {"heart of azeroth", "heart", "azeroth", "heart of azeroth achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Heart of Azeroth" },
            }
        },
        {
            name = "Island Expeditions (Achievements)",
            keywords = {"island expeditions", "island", "expeditions", "island expeditions achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Island Expeditions" },
            }
        },
        {
            name = "Legion Class Hall (Achievements)",
            keywords = {"legion class hall", "legion", "class", "hall", "legion class hall achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Class Hall" },
            }
        },
        {
            name = "Lorewalking (Achievements)",
            keywords = {"lorewalking", "lorewalking achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lorewalking" },
            }
        },
        {
            name = "Pandaria Scenarios (Achievements)",
            keywords = {"pandaria scenarios", "pandaria", "scenarios", "pandaria scenarios achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Scenarios" },
            }
        },
        {
            name = "Prey (Achievements)",
            keywords = {"prey", "prey achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Prey" },
            }
        },
        {
            name = "Proving Grounds (Achievements)",
            keywords = {"proving grounds", "proving", "grounds", "proving grounds achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Proving Grounds" },
            }
        },
        {
            name = "Skyriding (Achievements)",
            keywords = {"skyriding", "skyriding achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Skyriding" },
            }
        },
        {
            name = "Tol Barad (Achievements)",
            keywords = {"tol barad", "tol", "barad", "tol barad achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Tol Barad" },
            }
        },
        {
            name = "Torghast (Achievements)",
            keywords = {"torghast", "torghast achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Torghast" },
            }
        },
        {
            name = "Visions of N'Zoth (Achievements)",
            keywords = {"visions of n'zoth", "visions", "n'zoth", "visions of n'zoth achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth" },
            }
        },
        {
            name = "Visions of N'Zoth Revisited (Achievements)",
            keywords = {"visions of n'zoth revisited", "visions", "n'zoth", "revisited", "visions of n'zoth revisited achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Visions of N'Zoth Revisited" },
            }
        },
        {
            name = "War Effort (Achievements)",
            keywords = {"war effort", "war", "effort", "war effort achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Expansion Features"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Effort" },
            }
        },
        {
            name = "Exploration (Achievements)",
            keywords = {"exploration", "exploration achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
            }
        },
        {
            name = "Battle for Azeroth - Exploration (Achievements)",
            keywords = {"battle for azeroth", "battle", "azeroth", "battle for azeroth achievements", "exploration battle for azeroth"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" },
            }
        },
        {
            name = "Cataclysm - Exploration (Achievements)",
            keywords = {"cataclysm", "cataclysm achievements", "exploration cataclysm"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" },
            }
        },
        {
            name = "Draenor - Exploration (Achievements)",
            keywords = {"draenor", "draenor achievements", "exploration draenor"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor" },
            }
        },
        {
            name = "Dragon Isles (Achievements)",
            keywords = {"dragon isles", "dragon", "isles", "dragon isles achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragon Isles" },
            }
        },
        {
            name = "Eastern Kingdoms - Exploration (Achievements)",
            keywords = {"eastern kingdoms", "eastern", "kingdoms", "eastern kingdoms achievements", "exploration eastern kingdoms"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Eastern Kingdoms" },
            }
        },
        {
            name = "Kalimdor - Exploration (Achievements)",
            keywords = {"kalimdor", "kalimdor achievements", "exploration kalimdor"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Kalimdor" },
            }
        },
        {
            name = "Legion - Exploration (Achievements)",
            keywords = {"legion", "legion achievements", "exploration legion"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion" },
            }
        },
        {
            name = "Midnight - Exploration (Achievements)",
            keywords = {"midnight", "midnight achievements", "exploration midnight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight" },
            }
        },
        {
            name = "Northrend - Exploration (Achievements)",
            keywords = {"northrend", "northrend achievements", "exploration northrend"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Northrend" },
            }
        },
        {
            name = "Outland - Exploration (Achievements)",
            keywords = {"outland", "outland achievements", "exploration outland"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Outland" },
            }
        },
        {
            name = "Pandaria - Exploration (Achievements)",
            keywords = {"pandaria", "pandaria achievements", "exploration pandaria"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" },
            }
        },
        {
            name = "Shadowlands - Exploration (Achievements)",
            keywords = {"shadowlands", "shadowlands achievements", "exploration shadowlands"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" },
            }
        },
        {
            name = "War Within - Exploration (Achievements)",
            keywords = {"war within", "war", "within", "war within achievements", "exploration war within"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Exploration"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Exploration" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within" },
            }
        },
        {
            name = "Feats of Strength (Achievements)",
            keywords = {"feats of strength", "feats", "strength", "feat", "fos", "feats of strength achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
            }
        },
        {
            name = "Delves - Feats of Strength (Achievements)",
            keywords = {"delves", "delves achievements", "feats of strength delves"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Delves" },
            }
        },
        {
            name = "Dungeons - Feats of Strength (Achievements)",
            keywords = {"dungeons", "dungeon", "dungeons achievements", "feats of strength dungeons"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" },
            }
        },
        {
            name = "Events (Achievements)",
            keywords = {"events", "events achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Events" },
            }
        },
        {
            name = "Mounts - Feats of Strength (Achievements)",
            keywords = {"mounts", "mounts achievements", "feats of strength mounts"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Mounts" },
            }
        },
        {
            name = "Player vs. Player - Feats of Strength (Achievements)",
            keywords = {"player vs. player", "player", "pvp", "player vs. player achievements", "feats of strength player vs. player"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
            }
        },
        {
            name = "Promotions (Achievements)",
            keywords = {"promotions", "promotions achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Promotions" },
            }
        },
        {
            name = "Raids - Feats of Strength (Achievements)",
            keywords = {"raids", "raid", "raids achievements", "feats of strength raids"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Raids" },
            }
        },
        {
            name = "Reputation - Feats of Strength (Achievements)",
            keywords = {"reputation", "rep", "factions", "reputation achievements", "feats of strength reputation"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Feats of Strength"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Feats of Strength" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
            }
        },
        {
            name = "Legacy (Achievements)",
            keywords = {"legacy", "old", "legacy achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
            }
        },
        {
            name = "Character (Achievements)",
            keywords = {"character", "character achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Character" },
            }
        },
        {
            name = "Currencies (Achievements)",
            keywords = {"currencies", "currencies achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Currencies" },
            }
        },
        {
            name = "Dungeons - Legacy (Achievements)",
            keywords = {"dungeons", "dungeon", "dungeons achievements", "legacy dungeons"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons" },
            }
        },
        {
            name = "Expansion Features - Legacy (Achievements)",
            keywords = {"expansion features", "expansion", "features", "expansion features achievements", "legacy expansion features"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Expansion Features" },
            }
        },
        {
            name = "Legion Remix (Achievements)",
            keywords = {"legion remix", "legion", "remix", "legion remix achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Remix" },
            }
        },
        {
            name = "Player vs. Player - Legacy (Achievements)",
            keywords = {"player vs. player", "player", "pvp", "player vs. player achievements", "legacy player vs. player"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
            }
        },
        {
            name = "Professions - Legacy (Achievements)",
            keywords = {"professions", "profession", "crafting", "professions achievements", "legacy professions"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
            }
        },
        {
            name = "Quests - Legacy (Achievements)",
            keywords = {"quests", "quests achievements", "legacy quests"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
            }
        },
        {
            name = "Raids - Legacy (Achievements)",
            keywords = {"raids", "raid", "raids achievements", "legacy raids"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Raids" },
            }
        },
        {
            name = "Remix: Mists of Pandaria (Achievements)",
            keywords = {"remix: mists of pandaria", "remix:", "mists", "pandaria", "remix: mists of pandaria achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Remix: Mists of Pandaria" },
            }
        },
        {
            name = "World Events - Legacy (Achievements)",
            keywords = {"world events", "world", "events", "holidays", "seasonal", "world events achievements", "legacy world events"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Legacy"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legacy" },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
            }
        },
        {
            name = "Pet Battles (Achievements)",
            keywords = {"pet battles", "pet", "battles", "pets", "battle pets", "pet battles achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" },
            }
        },
        {
            name = "Battle (Achievements)",
            keywords = {"battle", "battle achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Pet Battles"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle" },
            }
        },
        {
            name = "Collect (Achievements)",
            keywords = {"collect", "collect achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Pet Battles"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Collect" },
            }
        },
        {
            name = "Level (Achievements)",
            keywords = {"level", "level achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Pet Battles"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pet Battles" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Level" },
            }
        },
        {
            name = "Player vs. Player (Achievements)",
            keywords = {"player vs. player", "player", "pvp", "player vs. player achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
            }
        },
        {
            name = "Alterac Valley (Achievements)",
            keywords = {"alterac valley", "alterac", "valley", "alterac valley achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Alterac Valley" },
            }
        },
        {
            name = "Arathi Basin (Achievements)",
            keywords = {"arathi basin", "arathi", "basin", "arathi basin achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Arathi Basin" },
            }
        },
        {
            name = "Arena (Achievements)",
            keywords = {"arena", "arena achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Arena" },
            }
        },
        {
            name = "Ashran (Achievements)",
            keywords = {"ashran", "ashran achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Ashran" },
            }
        },
        {
            name = "Battle for Gilneas (Achievements)",
            keywords = {"battle for gilneas", "battle", "gilneas", "battle for gilneas achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle for Gilneas" },
            }
        },
        {
            name = "Deephaul Ravine (Achievements)",
            keywords = {"deephaul ravine", "deephaul", "ravine", "deephaul ravine achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Deephaul Ravine" },
            }
        },
        {
            name = "Deepwind Gorge (Achievements)",
            keywords = {"deepwind gorge", "deepwind", "gorge", "deepwind gorge achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Deepwind Gorge" },
            }
        },
        {
            name = "Eye of the Storm (Achievements)",
            keywords = {"eye of the storm", "eye", "storm", "eye of the storm achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Eye of the Storm" },
            }
        },
        {
            name = "Honor (Achievements)",
            keywords = {"honor", "honor achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Honor" },
            }
        },
        {
            name = "Isle of Conquest (Achievements)",
            keywords = {"isle of conquest", "isle", "conquest", "isle of conquest achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Isle of Conquest" },
            }
        },
        {
            name = "Rated Battleground (Achievements)",
            keywords = {"rated battleground", "rated", "battleground", "rated battleground achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Rated Battleground" },
            }
        },
        {
            name = "Seething Shore (Achievements)",
            keywords = {"seething shore", "seething", "shore", "seething shore achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Seething Shore" },
            }
        },
        {
            name = "Silvershard Mines (Achievements)",
            keywords = {"silvershard mines", "silvershard", "mines", "silvershard mines achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Silvershard Mines" },
            }
        },
        {
            name = "Temple of Kotmogu (Achievements)",
            keywords = {"temple of kotmogu", "temple", "kotmogu", "temple of kotmogu achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Temple of Kotmogu" },
            }
        },
        {
            name = "Training Grounds (Achievements)",
            keywords = {"training grounds", "training", "grounds", "training grounds achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Training Grounds" },
            }
        },
        {
            name = "Twin Peaks (Achievements)",
            keywords = {"twin peaks", "twin", "peaks", "twin peaks achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Twin Peaks" },
            }
        },
        {
            name = "Warsong Gulch (Achievements)",
            keywords = {"warsong gulch", "warsong", "gulch", "warsong gulch achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Warsong Gulch" },
            }
        },
        {
            name = "Wintergrasp (Achievements)",
            keywords = {"wintergrasp", "wintergrasp achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Wintergrasp" },
            }
        },
        {
            name = "World (Achievements)",
            keywords = {"world", "world achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "World" },
            }
        },
        {
            name = "Professions (Achievements)",
            keywords = {"professions", "profession", "crafting", "professions achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
            }
        },
        {
            name = "Alchemy (Achievements)",
            keywords = {"alchemy", "alchemy achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Alchemy" },
            }
        },
        {
            name = "Archaeology (Achievements)",
            keywords = {"archaeology", "archaeology achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Archaeology" },
            }
        },
        {
            name = "Blacksmithing (Achievements)",
            keywords = {"blacksmithing", "blacksmithing achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Blacksmithing" },
            }
        },
        {
            name = "Cooking (Achievements)",
            keywords = {"cooking", "cooking achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cooking" },
            }
        },
        {
            name = "Enchanting (Achievements)",
            keywords = {"enchanting", "enchanting achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Enchanting" },
            }
        },
        {
            name = "Engineering (Achievements)",
            keywords = {"engineering", "engineering achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Engineering" },
            }
        },
        {
            name = "Fishing (Achievements)",
            keywords = {"fishing", "fishing achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Fishing" },
            }
        },
        {
            name = "Herbalism (Achievements)",
            keywords = {"herbalism", "herbalism achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Herbalism" },
            }
        },
        {
            name = "Inscription (Achievements)",
            keywords = {"inscription", "inscription achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Inscription" },
            }
        },
        {
            name = "Jewelcrafting (Achievements)",
            keywords = {"jewelcrafting", "jewelcrafting achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Jewelcrafting" },
            }
        },
        {
            name = "Leatherworking (Achievements)",
            keywords = {"leatherworking", "leatherworking achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Leatherworking" },
            }
        },
        {
            name = "Mining (Achievements)",
            keywords = {"mining", "mining achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Mining" },
            }
        },
        {
            name = "Skinning (Achievements)",
            keywords = {"skinning", "skinning achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Skinning" },
            }
        },
        {
            name = "Tailoring (Achievements)",
            keywords = {"tailoring", "tailoring achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Professions"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Tailoring" },
            }
        },
        {
            name = "Quests (Achievements)",
            keywords = {"quests", "quests achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
            }
        },
        {
            name = "Battle for Azeroth - Quests (Achievements)",
            keywords = {"battle for azeroth", "battle", "azeroth", "battle for azeroth achievements", "quests battle for azeroth"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" },
            }
        },
        {
            name = "Cataclysm - Quests (Achievements)",
            keywords = {"cataclysm", "cataclysm achievements", "quests cataclysm"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" },
            }
        },
        {
            name = "Draenor - Quests (Achievements)",
            keywords = {"draenor", "draenor achievements", "quests draenor"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor" },
            }
        },
        {
            name = "Dragonflight - Quests (Achievements)",
            keywords = {"dragonflight", "dragonflight achievements", "quests dragonflight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight" },
            }
        },
        {
            name = "Eastern Kingdoms - Quests (Achievements)",
            keywords = {"eastern kingdoms", "eastern", "kingdoms", "eastern kingdoms achievements", "quests eastern kingdoms"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Eastern Kingdoms" },
            }
        },
        {
            name = "Kalimdor - Quests (Achievements)",
            keywords = {"kalimdor", "kalimdor achievements", "quests kalimdor"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Kalimdor" },
            }
        },
        {
            name = "Legion - Quests (Achievements)",
            keywords = {"legion", "legion achievements", "quests legion"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion" },
            }
        },
        {
            name = "Midnight - Quests (Achievements)",
            keywords = {"midnight", "midnight achievements", "quests midnight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight" },
            }
        },
        {
            name = "Northrend - Quests (Achievements)",
            keywords = {"northrend", "northrend achievements", "quests northrend"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Northrend" },
            }
        },
        {
            name = "Outland - Quests (Achievements)",
            keywords = {"outland", "outland achievements", "quests outland"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Outland" },
            }
        },
        {
            name = "Pandaria - Quests (Achievements)",
            keywords = {"pandaria", "pandaria achievements", "quests pandaria"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" },
            }
        },
        {
            name = "Shadowlands - Quests (Achievements)",
            keywords = {"shadowlands", "shadowlands achievements", "quests shadowlands"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" },
            }
        },
        {
            name = "War Within - Quests (Achievements)",
            keywords = {"war within", "war", "within", "war within achievements", "quests war within"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Quests"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within" },
            }
        },
        {
            name = "Reputation (Achievements)",
            keywords = {"reputation", "rep", "factions", "reputation achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
            }
        },
        {
            name = "Battle for Azeroth - Reputation (Achievements)",
            keywords = {"battle for azeroth", "battle", "azeroth", "battle for azeroth achievements", "reputation battle for azeroth"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle for Azeroth" },
            }
        },
        {
            name = "Cataclysm - Reputation (Achievements)",
            keywords = {"cataclysm", "cataclysm achievements", "reputation cataclysm"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm" },
            }
        },
        {
            name = "Classic - Reputation (Achievements)",
            keywords = {"classic", "classic achievements", "reputation classic"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Classic" },
            }
        },
        {
            name = "Draenor - Reputation (Achievements)",
            keywords = {"draenor", "draenor achievements", "reputation draenor"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor" },
            }
        },
        {
            name = "Dragonflight - Reputation (Achievements)",
            keywords = {"dragonflight", "dragonflight achievements", "reputation dragonflight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight" },
            }
        },
        {
            name = "Legion - Reputation (Achievements)",
            keywords = {"legion", "legion achievements", "reputation legion"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion" },
            }
        },
        {
            name = "Midnight - Reputation (Achievements)",
            keywords = {"midnight", "midnight achievements", "reputation midnight"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight" },
            }
        },
        {
            name = "Pandaria - Reputation (Achievements)",
            keywords = {"pandaria", "pandaria achievements", "reputation pandaria"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria" },
            }
        },
        {
            name = "Shadowlands - Reputation (Achievements)",
            keywords = {"shadowlands", "shadowlands achievements", "reputation shadowlands"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands" },
            }
        },
        {
            name = "The Burning Crusade - Reputation (Achievements)",
            keywords = {"the burning crusade", "burning", "crusade", "the burning crusade achievements", "reputation the burning crusade"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" },
            }
        },
        {
            name = "War Within - Reputation (Achievements)",
            keywords = {"war within", "war", "within", "war within achievements", "reputation war within"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within" },
            }
        },
        {
            name = "Wrath of the Lich King (Achievements)",
            keywords = {"wrath of the lich king", "wrath", "lich", "king", "wrath of the lich king achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Reputation"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Wrath of the Lich King" },
            }
        },
        {
            name = "World Events (Achievements)",
            keywords = {"world events", "world", "events", "holidays", "seasonal", "world events achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
            }
        },
        {
            name = "Anniversary Celebration (Achievements)",
            keywords = {"anniversary celebration", "anniversary", "celebration", "anniversary celebration achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Anniversary Celebration" },
            }
        },
        {
            name = "Brawler's Guild (Achievements)",
            keywords = {"brawler's guild", "brawler's", "guild", "brawler's guild achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Brawler's Guild" },
            }
        },
        {
            name = "Brewfest (Achievements)",
            keywords = {"brewfest", "brewfest achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Brewfest" },
            }
        },
        {
            name = "Children's Week (Achievements)",
            keywords = {"children's week", "children's", "week", "children's week achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Children's Week" },
            }
        },
        {
            name = "Darkmoon Faire (Achievements)",
            keywords = {"darkmoon faire", "darkmoon", "faire", "darkmoon faire achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Darkmoon Faire" },
            }
        },
        {
            name = "Dastardly Duos (Achievements)",
            keywords = {"dastardly duos", "dastardly", "duos", "dastardly duos achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dastardly Duos" },
            }
        },
        {
            name = "Hallow's End (Achievements)",
            keywords = {"hallow's end", "hallow's", "end", "hallow's end achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Hallow's End" },
            }
        },
        {
            name = "Love is in the Air (Achievements)",
            keywords = {"love is in the air", "love", "air", "love is in the air achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Love is in the Air" },
            }
        },
        {
            name = "Lunar Festival (Achievements)",
            keywords = {"lunar festival", "lunar", "festival", "lunar festival achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lunar Festival" },
            }
        },
        {
            name = "Midsummer (Achievements)",
            keywords = {"midsummer", "midsummer achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midsummer" },
            }
        },
        {
            name = "Noblegarden (Achievements)",
            keywords = {"noblegarden", "noblegarden achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Noblegarden" },
            }
        },
        {
            name = "Pilgrim's Bounty (Achievements)",
            keywords = {"pilgrim's bounty", "pilgrim's", "bounty", "pilgrim's bounty achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pilgrim's Bounty" },
            }
        },
        {
            name = "Timewalking (Achievements)",
            keywords = {"timewalking", "timewalking achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Timewalking" },
            }
        },
        {
            name = "Winter Veil (Achievements)",
            keywords = {"winter veil", "winter", "veil", "winter veil achievements"},
            category = "Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 1 },
                { waitForFrame = "AchievementFrame", achievementCategory = "World Events" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Winter Veil" },
            }
        },

        -- =====================
        -- GUILD ACHIEVEMENT CATEGORIES (Auto-generated by Harvester)
        -- =====================
        {
            name = "Guild: Dungeons & Raids",
            keywords = {"dungeons & raids", "dungeons", "raids", "dungeon", "raid", "guild dungeons & raids", "dungeons & raids guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
            }
        },
        {
            name = "Guild: Battle Dungeon",
            keywords = {"battle dungeon", "battle", "dungeon", "guild battle dungeon", "battle dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle Dungeon" },
            }
        },
        {
            name = "Guild: Battle Raid",
            keywords = {"battle raid", "battle", "raid", "guild battle raid", "battle raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battle Raid" },
            }
        },
        {
            name = "Guild: Cataclysm Dungeon",
            keywords = {"cataclysm dungeon", "cataclysm", "dungeon", "guild cataclysm dungeon", "cataclysm dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Dungeon" },
            }
        },
        {
            name = "Guild: Cataclysm Raid",
            keywords = {"cataclysm raid", "cataclysm", "raid", "guild cataclysm raid", "cataclysm raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Cataclysm Raid" },
            }
        },
        {
            name = "Guild: Classic",
            keywords = {"classic", "guild classic", "classic guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Classic" },
            }
        },
        {
            name = "Guild: Draenor Dungeon",
            keywords = {"draenor dungeon", "draenor", "dungeon", "guild draenor dungeon", "draenor dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor Dungeon" },
            }
        },
        {
            name = "Guild: Draenor Raid",
            keywords = {"draenor raid", "draenor", "raid", "guild draenor raid", "draenor raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Draenor Raid" },
            }
        },
        {
            name = "Guild: Dragonflight Dungeon",
            keywords = {"dragonflight dungeon", "dragonflight", "dungeon", "guild dragonflight dungeon", "dragonflight dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Dungeon" },
            }
        },
        {
            name = "Guild: Dragonflight Raid",
            keywords = {"dragonflight raid", "dragonflight", "raid", "guild dragonflight raid", "dragonflight raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dragonflight Raid" },
            }
        },
        {
            name = "Guild: Legion Dungeon",
            keywords = {"legion dungeon", "legion", "dungeon", "guild legion dungeon", "legion dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Dungeon" },
            }
        },
        {
            name = "Guild: Legion Raid",
            keywords = {"legion raid", "legion", "raid", "guild legion raid", "legion raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Legion Raid" },
            }
        },
        {
            name = "Guild: Lich King Dungeon",
            keywords = {"lich king dungeon", "lich", "king", "dungeon", "guild lich king dungeon", "lich king dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lich King Dungeon" },
            }
        },
        {
            name = "Guild: Lich King Raid",
            keywords = {"lich king raid", "lich", "king", "raid", "guild lich king raid", "lich king raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Lich King Raid" },
            }
        },
        {
            name = "Guild: Midnight Dungeon",
            keywords = {"midnight dungeon", "midnight", "dungeon", "guild midnight dungeon", "midnight dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight Dungeon" },
            }
        },
        {
            name = "Guild: Midnight Raid",
            keywords = {"midnight raid", "midnight", "raid", "guild midnight raid", "midnight raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Midnight Raid" },
            }
        },
        {
            name = "Guild: Pandaria Dungeon",
            keywords = {"pandaria dungeon", "pandaria", "dungeon", "guild pandaria dungeon", "pandaria dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Dungeon" },
            }
        },
        {
            name = "Guild: Pandaria Raid",
            keywords = {"pandaria raid", "pandaria", "raid", "guild pandaria raid", "pandaria raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Pandaria Raid" },
            }
        },
        {
            name = "Guild: Shadowlands Dungeon",
            keywords = {"shadowlands dungeon", "shadowlands", "dungeon", "guild shadowlands dungeon", "shadowlands dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Dungeon" },
            }
        },
        {
            name = "Guild: Shadowlands Raid",
            keywords = {"shadowlands raid", "shadowlands", "raid", "guild shadowlands raid", "shadowlands raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Shadowlands Raid" },
            }
        },
        {
            name = "Guild: The Burning Crusade",
            keywords = {"the burning crusade", "burning", "crusade", "guild the burning crusade", "the burning crusade guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "The Burning Crusade" },
            }
        },
        {
            name = "Guild: War Within Dungeon",
            keywords = {"war within dungeon", "war", "within", "dungeon", "guild war within dungeon", "war within dungeon guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within Dungeon" },
            }
        },
        {
            name = "Guild: War Within Raid",
            keywords = {"war within raid", "war", "within", "raid", "guild war within raid", "war within raid guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", achievementCategory = "War Within Raid" },
            }
        },
        {
            name = "Guild: General",
            keywords = {"general", "guild general", "general guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "General" },
            }
        },
        {
            name = "Guild: Guild Feats of Strength",
            keywords = {"guild feats of strength", "guild", "feats", "strength", "feat", "fos", "guild guild feats of strength", "guild feats of strength guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Guild Feats of Strength" },
            }
        },
        {
            name = "Guild: Player vs. Player",
            keywords = {"player vs. player", "player", "pvp", "guild player vs. player", "player vs. player guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
            }
        },
        {
            name = "Guild: Arena",
            keywords = {"arena", "guild arena", "arena guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Arena" },
            }
        },
        {
            name = "Guild: Battlegrounds",
            keywords = {"battlegrounds", "bg", "bgs", "guild battlegrounds", "battlegrounds guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", achievementCategory = "Battlegrounds" },
            }
        },
        {
            name = "Guild: Professions",
            keywords = {"professions", "profession", "crafting", "guild professions", "professions guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Professions" },
            }
        },
        {
            name = "Guild: Quests",
            keywords = {"quests", "guild quests", "quests guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Quests" },
            }
        },
        {
            name = "Guild: Reputation",
            keywords = {"reputation", "rep", "factions", "guild reputation", "reputation guild"},
            category = "Guild Achievements",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Guild"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 2 },
                { waitForFrame = "AchievementFrame", achievementCategory = "Reputation" },
            }
        },

        -- =====================
        -- STATISTICS CATEGORIES (Auto-generated by Harvester)
        -- =====================
        {
            name = "Character Statistics",
            keywords = {"character", "character stats", "character statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Character" },
            }
        },
        {
            name = "Consumables Statistics",
            keywords = {"consumables", "consumables stats", "consumables statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Character"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Character" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Consumables" },
            }
        },
        {
            name = "Wealth Statistics",
            keywords = {"wealth", "wealth stats", "wealth statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Character"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Character" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Wealth" },
            }
        },
        {
            name = "Deaths Statistics",
            keywords = {"deaths", "deaths stats", "deaths statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Deaths" },
            }
        },
        {
            name = "Delves Statistics",
            keywords = {"delves", "delves stats", "delves statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Delves" },
            }
        },
        {
            name = "Midnight - Delves Statistics",
            keywords = {"midnight", "midnight stats", "midnight statistics", "delves midnight"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Delves"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Delves" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Midnight" },
            }
        },
        {
            name = "The War Within - Delves Statistics",
            keywords = {"the war within", "war", "within", "the war within stats", "the war within statistics", "delves the war within"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Delves"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Delves" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "The War Within" },
            }
        },
        {
            name = "Dungeons & Raids Statistics",
            keywords = {"dungeons & raids", "dungeons", "raids", "dungeon", "raid", "dungeons & raids stats", "dungeons & raids statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
            }
        },
        {
            name = "Battle for Azeroth Statistics",
            keywords = {"battle for azeroth", "battle", "azeroth", "battle for azeroth stats", "battle for azeroth statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Battle for Azeroth" },
            }
        },
        {
            name = "Cataclysm Statistics",
            keywords = {"cataclysm", "cataclysm stats", "cataclysm statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Cataclysm" },
            }
        },
        {
            name = "Classic Statistics",
            keywords = {"classic", "classic stats", "classic statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Classic" },
            }
        },
        {
            name = "Dragonflight Statistics",
            keywords = {"dragonflight", "dragonflight stats", "dragonflight statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dragonflight" },
            }
        },
        {
            name = "Legion Statistics",
            keywords = {"legion", "legion stats", "legion statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Legion" },
            }
        },
        {
            name = "Midnight - Dungeons & Raids Statistics",
            keywords = {"midnight", "midnight stats", "midnight statistics", "dungeons & raids midnight"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Midnight" },
            }
        },
        {
            name = "Mists of Pandaria Statistics",
            keywords = {"mists of pandaria", "mists", "pandaria", "mists of pandaria stats", "mists of pandaria statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Mists of Pandaria" },
            }
        },
        {
            name = "Shadowlands Statistics",
            keywords = {"shadowlands", "shadowlands stats", "shadowlands statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Shadowlands" },
            }
        },
        {
            name = "The Burning Crusade Statistics",
            keywords = {"the burning crusade", "burning", "crusade", "the burning crusade stats", "the burning crusade statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "The Burning Crusade" },
            }
        },
        {
            name = "The War Within - Dungeons & Raids Statistics",
            keywords = {"the war within", "war", "within", "the war within stats", "the war within statistics", "dungeons & raids the war within"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "The War Within" },
            }
        },
        {
            name = "Warlords of Draenor Statistics",
            keywords = {"warlords of draenor", "warlords", "draenor", "warlords of draenor stats", "warlords of draenor statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Warlords of Draenor" },
            }
        },
        {
            name = "Wrath of the Lich King Statistics",
            keywords = {"wrath of the lich king", "wrath", "lich", "king", "wrath of the lich king stats", "wrath of the lich king statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dungeons & Raids" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Wrath of the Lich King" },
            }
        },
        {
            name = "Kills Statistics",
            keywords = {"kills", "kills stats", "kills statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Kills" },
            }
        },
        {
            name = "Creatures Statistics",
            keywords = {"creatures", "creatures stats", "creatures statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Kills"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Kills" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Creatures" },
            }
        },
        {
            name = "Honorable Kills Statistics",
            keywords = {"honorable kills", "honorable", "kills", "hk", "honor kills", "honorable kills stats", "honorable kills statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Kills"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Kills" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Honorable Kills" },
            }
        },
        {
            name = "Killing Blows Statistics",
            keywords = {"killing blows", "killing", "blows", "kb", "kills", "killing blows stats", "killing blows statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Kills"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Kills" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Killing Blows" },
            }
        },
        {
            name = "Legacy Statistics",
            keywords = {"legacy", "old", "legacy stats", "legacy statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Legacy" },
            }
        },
        {
            name = "Pet Battles Statistics",
            keywords = {"pet battles", "pet", "battles", "pets", "battle pets", "pet battles stats", "pet battles statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Pet Battles" },
            }
        },
        {
            name = "Player vs. Player Statistics",
            keywords = {"player vs. player", "player", "pvp", "player vs. player stats", "player vs. player statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
            }
        },
        {
            name = "Battlegrounds Statistics",
            keywords = {"battlegrounds", "bg", "bgs", "battlegrounds stats", "battlegrounds statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Battlegrounds" },
            }
        },
        {
            name = "Rated Arenas Statistics",
            keywords = {"rated arenas", "rated", "arenas", "arena", "rated arenas stats", "rated arenas statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Rated Arenas" },
            }
        },
        {
            name = "World Statistics",
            keywords = {"world", "world stats", "world statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Player vs. Player"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Player vs. Player" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "World" },
            }
        },
        {
            name = "Proving Grounds Statistics",
            keywords = {"proving grounds", "proving", "grounds", "proving grounds stats", "proving grounds statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Proving Grounds" },
            }
        },
        {
            name = "Quests Statistics",
            keywords = {"quests", "quests stats", "quests statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Quests" },
            }
        },
        {
            name = "Skills Statistics",
            keywords = {"skills", "skills stats", "skills statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Skills" },
            }
        },
        {
            name = "Professions Statistics",
            keywords = {"professions", "profession", "crafting", "professions stats", "professions statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Skills"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Skills" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Professions" },
            }
        },
        {
            name = "Secondary Skills Statistics",
            keywords = {"secondary skills", "secondary", "skills", "secondary skills stats", "secondary skills statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "Skills"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Skills" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Secondary Skills" },
            }
        },
        {
            name = "Social Statistics",
            keywords = {"social", "social stats", "social statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Social" },
            }
        },
        {
            name = "Travel Statistics",
            keywords = {"travel", "travel stats", "travel statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Travel" },
            }
        },
        {
            name = "World Events Statistics",
            keywords = {"world events", "world", "events", "holidays", "seasonal", "world events stats", "world events statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "World Events" },
            }
        },
        {
            name = "Dastardly Duos Statistics",
            keywords = {"dastardly duos", "dastardly", "duos", "dastardly duos stats", "dastardly duos statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "World Events" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Dastardly Duos" },
            }
        },
        {
            name = "Legion: Remix Statistics",
            keywords = {"legion: remix", "legion:", "remix", "legion: remix stats", "legion: remix statistics"},
            category = "Statistics",
            buttonFrame = "AchievementMicroButton",
            path = {"Achievements", "Statistics", "World Events"},
            steps = {
                { buttonFrame = "AchievementMicroButton" },
                { waitForFrame = "AchievementFrame", tabIndex = 3 },
                { waitForFrame = "AchievementFrame", statisticsCategory = "World Events" },
                { waitForFrame = "AchievementFrame", statisticsCategory = "Legion: Remix" },
            }
        },

        -- =====================
        -- CURRENCY ENTRIES (Auto-generated by Harvester)
        -- =====================
        {
            name = "Midnight Currencies",
            keywords = {"midnight", "midnight currencies", "midnight currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Midnight" },
            }
        },
        {
            name = "Dungeon and Raid Currencies",
            keywords = {"dungeon and raid", "dungeon", "raid", "dungeon and raid currencies", "dungeon and raid currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Dungeon and Raid" },
            }
        },
        {
            name = "Miscellaneous Currencies",
            keywords = {"miscellaneous", "miscellaneous currencies", "miscellaneous currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Miscellaneous" },
            }
        },
        {
            name = "Player vs. Player Currencies",
            keywords = {"player vs. player", "player", "pvp", "player vs. player currencies", "player vs. player currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Player vs. Player" },
            }
        },
        {
            name = "Legacy Currencies",
            keywords = {"legacy", "old", "legacy currencies", "legacy currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legacy" },
            }
        },
        {
            name = "War Within Currencies",
            keywords = {"war within", "war", "within", "war within currencies", "war within currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "War Within" },
            }
        },
        {
            name = "Season 3 Currencies",
            keywords = {"season 3", "season", "season 3 currencies", "season 3 currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
            }
        },
        {
            name = "Dragonflight Currencies",
            keywords = {"dragonflight", "dragonflight currencies", "dragonflight currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Dragonflight" },
            }
        },
        {
            name = "Shadowlands Currencies",
            keywords = {"shadowlands", "shadowlands currencies", "shadowlands currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
            }
        },
        {
            name = "Battle for Azeroth Currencies",
            keywords = {"battle for azeroth", "battle", "azeroth", "battle for azeroth currencies", "battle for azeroth currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
            }
        },
        {
            name = "Legion Currencies",
            keywords = {"legion", "legion currencies", "legion currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
            }
        },
        {
            name = "Warlords of Draenor Currencies",
            keywords = {"warlords of draenor", "warlords", "draenor", "warlords of draenor currencies", "warlords of draenor currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
            }
        },
        {
            name = "Mists of Pandaria Currencies",
            keywords = {"mists of pandaria", "mists", "pandaria", "mists of pandaria currencies", "mists of pandaria currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
            }
        },
        {
            name = "Cataclysm Currencies",
            keywords = {"cataclysm", "cataclysm currencies", "cataclysm currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Cataclysm" },
            }
        },
        {
            name = "Wrath of the Lich King Currencies",
            keywords = {"wrath of the lich king", "wrath", "lich", "king", "wrath of the lich king currencies", "wrath of the lich king currency"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Wrath of the Lich King" },
            }
        },
        {
            name = "Twilight's Blade Insignia",
            keywords = {"twilight's blade insignia", "twilight's", "blade", "insignia", "midnight twilight's blade insignia"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Midnight"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Midnight" },
                { waitForFrame = "CharacterFrame", currencyID = 3319 },
            }
        },
        {
            name = "Timewarped Badge",
            keywords = {"timewarped badge", "timewarped", "badge", "dungeon and raid timewarped badge"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Dungeon and Raid"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Dungeon and Raid" },
                { waitForFrame = "CharacterFrame", currencyID = 1166 },
            }
        },
        {
            name = "Community Coupons",
            keywords = {"community coupons", "community", "coupons", "miscellaneous community coupons"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Miscellaneous"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Miscellaneous" },
                { waitForFrame = "CharacterFrame", currencyID = 3363 },
            }
        },
        {
            name = "Darkmoon Prize Ticket",
            keywords = {"darkmoon prize ticket", "darkmoon", "prize", "ticket", "miscellaneous darkmoon prize ticket"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Miscellaneous"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Miscellaneous" },
                { waitForFrame = "CharacterFrame", currencyID = 515 },
            }
        },
        {
            name = "Trader's Tender",
            keywords = {"trader's tender", "trader's", "tender", "miscellaneous trader's tender"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Miscellaneous"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Miscellaneous" },
                { waitForFrame = "CharacterFrame", currencyID = 2032 },
            }
        },
        {
            name = "Bloody Tokens",
            keywords = {"bloody tokens", "bloody", "tokens", "player vs. player bloody tokens"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Player vs. Player"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Player vs. Player" },
                { waitForFrame = "CharacterFrame", currencyID = 2123 },
            }
        },
        {
            name = "Conquest",
            keywords = {"conquest", "player vs. player conquest"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Player vs. Player"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Player vs. Player" },
                { waitForFrame = "CharacterFrame", currencyID = 1602 },
            }
        },
        {
            name = "Honor",
            keywords = {"honor", "player vs. player honor"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Player vs. Player"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Player vs. Player" },
                { waitForFrame = "CharacterFrame", currencyID = 1792 },
            }
        },
        {
            name = "Kej",
            keywords = {"kej", "war within kej"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "War Within"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "War Within" },
                { waitForFrame = "CharacterFrame", currencyID = 3056 },
            }
        },
        {
            name = "Resonance Crystals",
            keywords = {"resonance crystals", "resonance", "crystals", "war within resonance crystals"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "War Within"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "War Within" },
                { waitForFrame = "CharacterFrame", currencyID = 2815 },
            }
        },
        {
            name = "Restored Coffer Key",
            keywords = {"restored coffer key", "restored", "coffer", "key", "season 3 restored coffer key"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3028 },
            }
        },
        {
            name = "Undercoin",
            keywords = {"undercoin", "season 3 undercoin"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 2803 },
            }
        },
        {
            name = "Valorstones",
            keywords = {"valorstones", "season 3 valorstones"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3008 },
            }
        },
        {
            name = "Weathered Ethereal Crest",
            keywords = {"weathered ethereal crest", "weathered", "ethereal", "crest", "season 3 weathered ethereal crest"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3284 },
            }
        },
        {
            name = "Carved Ethereal Crest",
            keywords = {"carved ethereal crest", "carved", "ethereal", "crest", "season 3 carved ethereal crest"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3286 },
            }
        },
        {
            name = "Runed Ethereal Crest",
            keywords = {"runed ethereal crest", "runed", "ethereal", "crest", "season 3 runed ethereal crest"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3288 },
            }
        },
        {
            name = "Gilded Ethereal Crest",
            keywords = {"gilded ethereal crest", "gilded", "ethereal", "crest", "season 3 gilded ethereal crest"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Season 3"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Season 3" },
                { waitForFrame = "CharacterFrame", currencyID = 3290 },
            }
        },
        {
            name = "Dragon Isles Supplies",
            keywords = {"dragon isles supplies", "dragon", "isles", "supplies", "dragonflight dragon isles supplies"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Dragonflight"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Dragonflight" },
                { waitForFrame = "CharacterFrame", currencyID = 2003 },
            }
        },
        {
            name = "Elemental Overflow",
            keywords = {"elemental overflow", "elemental", "overflow", "dragonflight elemental overflow"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Dragonflight"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Dragonflight" },
                { waitForFrame = "CharacterFrame", currencyID = 2118 },
            }
        },
        {
            name = "Argent Commendation",
            keywords = {"argent commendation", "argent", "commendation", "shadowlands argent commendation"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1754 },
            }
        },
        {
            name = "Cataloged Research",
            keywords = {"cataloged research", "cataloged", "research", "shadowlands cataloged research"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1931 },
            }
        },
        {
            name = "Cosmic Flux",
            keywords = {"cosmic flux", "cosmic", "flux", "shadowlands cosmic flux"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 2009 },
            }
        },
        {
            name = "Cyphers of the First Ones",
            keywords = {"cyphers of the first ones", "cyphers", "first", "ones", "shadowlands cyphers of the first ones"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1979 },
            }
        },
        {
            name = "Grateful Offering",
            keywords = {"grateful offering", "grateful", "offering", "shadowlands grateful offering"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1885 },
            }
        },
        {
            name = "Infused Ruby",
            keywords = {"infused ruby", "infused", "ruby", "shadowlands infused ruby"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1820 },
            }
        },
        {
            name = "Reservoir Anima",
            keywords = {"reservoir anima", "reservoir", "anima", "shadowlands reservoir anima"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1813 },
            }
        },
        {
            name = "Soul Ash",
            keywords = {"soul ash", "soul", "ash", "shadowlands soul ash"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1828 },
            }
        },
        {
            name = "Soul Cinders",
            keywords = {"soul cinders", "soul", "cinders", "shadowlands soul cinders"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1906 },
            }
        },
        {
            name = "Stygia",
            keywords = {"stygia", "shadowlands stygia"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Shadowlands"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Shadowlands" },
                { waitForFrame = "CharacterFrame", currencyID = 1767 },
            }
        },
        {
            name = "7th Legion Service Medal",
            keywords = {"7th legion service medal", "7th", "legion", "service", "medal", "battle for azeroth 7th legion service medal"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1717 },
            }
        },
        {
            name = "Coalescing Visions",
            keywords = {"coalescing visions", "coalescing", "visions", "battle for azeroth coalescing visions"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1755 },
            }
        },
        {
            name = "Echoes of Ny'alotha",
            keywords = {"echoes of ny'alotha", "echoes", "ny'alotha", "battle for azeroth echoes of ny'alotha"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1803 },
            }
        },
        {
            name = "Prismatic Manapearl",
            keywords = {"prismatic manapearl", "prismatic", "manapearl", "battle for azeroth prismatic manapearl"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1721 },
            }
        },
        {
            name = "Seafarer's Dubloon",
            keywords = {"seafarer's dubloon", "seafarer's", "dubloon", "battle for azeroth seafarer's dubloon"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1710 },
            }
        },
        {
            name = "War Resources",
            keywords = {"war resources", "war", "resources", "battle for azeroth war resources"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Battle for Azeroth"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Battle for Azeroth" },
                { waitForFrame = "CharacterFrame", currencyID = 1560 },
            }
        },
        {
            name = "Curious Coin",
            keywords = {"curious coin", "curious", "coin", "legion curious coin"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Legion"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
                { waitForFrame = "CharacterFrame", currencyID = 1275 },
            }
        },
        {
            name = "Nethershard",
            keywords = {"nethershard", "legion nethershard"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Legion"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
                { waitForFrame = "CharacterFrame", currencyID = 1226 },
            }
        },
        {
            name = "Order Resources",
            keywords = {"order resources", "order", "resources", "legion order resources"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Legion"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
                { waitForFrame = "CharacterFrame", currencyID = 1220 },
            }
        },
        {
            name = "Veiled Argunite",
            keywords = {"veiled argunite", "veiled", "argunite", "legion veiled argunite"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Legion"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
                { waitForFrame = "CharacterFrame", currencyID = 1508 },
            }
        },
        {
            name = "Wakening Essence",
            keywords = {"wakening essence", "wakening", "essence", "legion wakening essence"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Legion"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Legion" },
                { waitForFrame = "CharacterFrame", currencyID = 1533 },
            }
        },
        {
            name = "Apexis Crystal",
            keywords = {"apexis crystal", "apexis", "crystal", "warlords of draenor apexis crystal"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Warlords of Draenor"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
                { waitForFrame = "CharacterFrame", currencyID = 823 },
            }
        },
        {
            name = "Artifact Fragment",
            keywords = {"artifact fragment", "artifact", "fragment", "warlords of draenor artifact fragment"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Warlords of Draenor"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
                { waitForFrame = "CharacterFrame", currencyID = 944 },
            }
        },
        {
            name = "Garrison Resources",
            keywords = {"garrison resources", "garrison", "resources", "warlords of draenor garrison resources"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Warlords of Draenor"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
                { waitForFrame = "CharacterFrame", currencyID = 824 },
            }
        },
        {
            name = "Oil",
            keywords = {"oil", "warlords of draenor oil"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Warlords of Draenor"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
                { waitForFrame = "CharacterFrame", currencyID = 1101 },
            }
        },
        {
            name = "Seal of Tempered Fate",
            keywords = {"seal of tempered fate", "seal", "tempered", "fate", "warlords of draenor seal of tempered fate"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Warlords of Draenor"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Warlords of Draenor" },
                { waitForFrame = "CharacterFrame", currencyID = 994 },
            }
        },
        {
            name = "Elder Charm of Good Fortune",
            keywords = {"elder charm of good fortune", "elder", "charm", "good", "fortune", "mists of pandaria elder charm of good fortune"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Mists of Pandaria"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
                { waitForFrame = "CharacterFrame", currencyID = 697 },
            }
        },
        {
            name = "Lesser Charm of Good Fortune",
            keywords = {"lesser charm of good fortune", "lesser", "charm", "good", "fortune", "mists of pandaria lesser charm of good fortune"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Mists of Pandaria"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
                { waitForFrame = "CharacterFrame", currencyID = 738 },
            }
        },
        {
            name = "Mogu Rune of Fate",
            keywords = {"mogu rune of fate", "mogu", "rune", "fate", "mists of pandaria mogu rune of fate"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Mists of Pandaria"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
                { waitForFrame = "CharacterFrame", currencyID = 752 },
            }
        },
        {
            name = "Timeless Coin",
            keywords = {"timeless coin", "timeless", "coin", "mists of pandaria timeless coin"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Mists of Pandaria"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
                { waitForFrame = "CharacterFrame", currencyID = 777 },
            }
        },
        {
            name = "Warforged Seal",
            keywords = {"warforged seal", "warforged", "seal", "mists of pandaria warforged seal"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Mists of Pandaria"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Mists of Pandaria" },
                { waitForFrame = "CharacterFrame", currencyID = 776 },
            }
        },
        {
            name = "Mote of Darkness",
            keywords = {"mote of darkness", "mote", "darkness", "cataclysm mote of darkness"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Cataclysm"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Cataclysm" },
                { waitForFrame = "CharacterFrame", currencyID = 614 },
            }
        },
        {
            name = "Champion's Seal",
            keywords = {"champion's seal", "champion's", "seal", "wrath of the lich king champion's seal"},
            category = "Currency",
            buttonFrame = "CharacterMicroButton",
            path = {"Character Info", "Currency", "Wrath of the Lich King"},
            steps = {
                { buttonFrame = "CharacterMicroButton" },
                { waitForFrame = "CharacterFrame", tabIndex = 3 },
                { waitForFrame = "CharacterFrame", currencyHeader = "Wrath of the Lich King" },
                { waitForFrame = "CharacterFrame", currencyID = 241 },
            }
        },

        -- =====================
        -- PORTRAIT MENU OPTIONS (Auto-generated by Harvester)
        -- =====================
        {
            name = "Set Focus",
            keywords = {"set focus", "focus target", "focus frame", "focus"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Set Focus" },
            }
        },
        {
            name = "Self Highlight",
            keywords = {"self highlight", "highlight self", "outline", "self outline"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Self Highlight" },
            }
        },
        {
            name = "Target Marker Icon",
            keywords = {"target marker", "raid marker", "skull", "cross", "star", "moon", "marker icon", "raid icon", "world marker"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Target Marker Icon" },
            }
        },
        {
            name = "Loot Specialization",
            keywords = {"loot spec", "loot specialization", "loot preference"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Loot Specialization" },
            }
        },
        {
            name = "Dungeon Difficulty",
            keywords = {"dungeon difficulty", "normal dungeon", "heroic dungeon", "mythic dungeon", "instance difficulty"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Dungeon Difficulty" },
            }
        },
        {
            name = "Raid Difficulty",
            keywords = {"raid difficulty", "normal raid", "heroic raid", "mythic raid", "raid size"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Raid Difficulty" },
            }
        },
        {
            name = "Reset All Instances",
            keywords = {"reset instances", "reset all instances", "instance reset", "dungeon reset"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            available = function()
                -- Only available when the player is party leader or solo, and not in an instance
                local inInstance, instanceType = IsInInstance()
                if inInstance then return false end
                if IsInGroup() and not UnitIsGroupLeader("player") then return false end
                return true
            end,
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Reset All Instances" },
            }
        },
        {
            name = "Edit Mode",
            keywords = {"edit mode", "ui layout", "customize ui", "move frames", "hud edit", "ui editor"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Edit Mode" },
            }
        },
        {
            name = "Voice Chat",
            keywords = {"voice chat", "voice", "voip", "talk", "microphone", "mic"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "Voice Chat" },
            }
        },
        {
            name = "PvP Flag",
            keywords = {"pvp flag", "pvp toggle", "player vs player flag", "pvp enable", "war mode portrait"},
            category = "Portrait Menu",
            buttonFrame = "PlayerFrame",
            path = {"Portrait Menu"},
            steps = {
                { portraitMenu = true },
                { portraitMenuOption = "PvP Flag" },
            }
        },
        
        -- =====================
        -- GROUP FINDER - PVE SECTION
        -- =====================
        {
            name = "Dungeons & Raids",
            keywords = {"dungeons", "raids", "pve", "dungeons and raids", "dungeon tab", "raid tab"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 }
            }
        },
        {
            name = "Dungeon Finder",
            keywords = {"dungeon finder", "lfd", "random dungeon", "heroic dungeon", "normal dungeon", "dungeon queue"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 1 }
            }
        },
        {
            name = "Raid Finder",
            keywords = {"raid finder", "lfr", "looking for raid", "raid queue", "random raid"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 2 }
            }
        },
        {
            name = "Premade Groups (PvE)",
            keywords = {"premade", "premade groups", "custom group", "find group", "make group", "list group", "pve premade"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 }
            }
        },
        {
            name = "Mythic+ Dungeons",
            keywords = {"mythic", "mythic+", "m+", "keystone", "mythic plus", "keys"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 3 }
            }
        },
        
        -- =====================
        -- PREMADE GROUPS - PVE CATEGORIES
        -- =====================
        {
            name = "Questing (Premade)",
            keywords = {"questing", "quest", "quest group", "quest lfg", "find quest group", "premade questing"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Questing", text = "Select Questing from the Premade Groups list" }
            }
        },
        {
            name = "Delves (Premade)",
            keywords = {"delves", "delve group", "delve lfg", "find delve group", "premade delves", "delve"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Delves", text = "Select Delves from the Premade Groups list" }
            }
        },
        {
            name = "Dungeons (Premade)",
            keywords = {"dungeons", "dungeon group", "dungeon lfg", "find dungeon group", "premade dungeons", "m+ group", "mythic group"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Dungeons", text = "Select Dungeons from the Premade Groups list" }
            }
        },
        {
            name = "Raids - The War Within (Premade)",
            keywords = {"raids", "raids the war within", "raid group", "raid lfg", "find raid group", "premade raids", "tww raid", "war within raid", "nerub-ar", "liberation of undermine"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Raids - The War Within", text = "Select Raids - The War Within from the Premade Groups list" }
            }
        },
        {
            name = "Raids - Legacy (Premade)",
            keywords = {"raids", "raids legacy", "legacy raid", "old raid", "legacy raid group", "legacy lfg", "transmog raid", "mount run"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Raids - Legacy", text = "Select Raids - Legacy from the Premade Groups list" }
            }
        },
        {
            name = "Custom PvE Group",
            keywords = {"custom", "custom pve", "custom group", "custom lfg", "pve custom"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Dungeons & Raids", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 1 },
                { waitForFrame = "PVEFrame", sideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Custom", text = "Select Custom from the Premade Groups list" }
            }
        },
        
        -- =====================
        -- GROUP FINDER - PVP SECTION
        -- =====================
        {
            name = "Player vs. Player",
            keywords = {"pvp", "player vs player", "battleground", "arena", "bg"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 }
            }
        },
        {
            name = "Quick Match",
            keywords = {"quick match", "random bg", "random battleground", "casual pvp", "unrated", "pvp"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 1 }
            }
        },
        {
            name = "Rated",
            keywords = {"rated", "rated pvp", "conquest", "pvp"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 }
            }
        },
        {
            name = "Premade Groups (PvP)",
            keywords = {"pvp premade", "pvp groups", "bg group", "pvp"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 }
            }
        },
        {
            name = "Training Grounds",
            keywords = {"training", "training grounds", "practice", "pvp"},
            category = "Group Finder",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 4 }
            }
        },
        
        -- =====================
        -- TRAINING GROUNDS SPECIFICS
        -- =====================
        {
            name = "Random Battlegrounds (Training Grounds)",
            keywords = {"random bg", "random battleground", "random battlegrounds", "training battleground", "bonus battleground"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Training Grounds"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 4 },
                { waitForFrame = "PVEFrame", regionFrames = {"TrainingGroundsFrame.BonusTrainingGroundList.RandomTrainingGroundButton"}, searchButtonText = "Random Battlegrounds", text = "Select Random Battlegrounds in Training Grounds" }
            }
        },
        
        -- =====================
        -- QUICK MATCH SPECIFICS (Arena Skirmish, Random BG, etc.)
        -- =====================
        {
            name = "Arena Skirmish",
            keywords = {"arena skirmish", "skirmish", "unrated arena", "casual arena", "arena"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Quick Match"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 1 },
                { waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.ArenaSkirmish", "HonorFrame.ArenaSkirmish"}, searchButtonText = "Arena Skirmish", text = "Select Arena Skirmish from the list" }
            }
        },
        {
            name = "Random Battleground",
            keywords = {"random bg", "random battleground", "casual bg", "unrated bg", "battleground"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Quick Match"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 1 },
                { waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.RandomBG", "HonorFrame.RandomBG"}, searchButtonText = "Random Battlegrounds", text = "Select Random Battlegrounds from the list" }
            }
        },
        {
            name = "Random Epic Battleground",
            keywords = {"random epic bg", "random epic battleground", "epic bg", "epic battleground", "ashran", "alterac", "isle of conquest"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Quick Match"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 1 },
                { waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.RandomEpicBG", "HonorFrame.RandomEpicBG"}, searchButtonText = "Random Epic Battlegrounds", text = "Select Random Epic Battlegrounds from the list" }
            }
        },
        {
            name = "Brawl",
            keywords = {"brawl", "pvp brawl", "weekly brawl", "packed house"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Quick Match"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 1 },
                { waitForFrame = "PVEFrame", regionFrames = {"HonorFrame.SpecificFrame.Brawl", "HonorFrame.BonusFrame.BrawlButton"}, searchButtonText = "Brawl", text = "Select the Brawl option from the list" }
            }
        },
        
        -- =====================
        -- RATED PVP SPECIFICS (Solo Shuffle, 2v2, 3v3, RBG)
        -- =====================
        {
            name = "Solo Shuffle",
            keywords = {"solo shuffle", "shuffle", "solo arena", "solo rated", "arena"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena1v1", "ConquestFrame.SoloShuffle"}, searchButtonText = "Solo Arena", text = "Solo Shuffle is the first option in the Rated panel" }
            }
        },
        {
            name = "2v2 Arena",
            keywords = {"2v2", "2s", "twos", "2v2 arena", "two vs two", "arena"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena2v2"}, searchButtonText = "2v2", text = "2v2 Arena is in the Rated panel" }
            }
        },
        {
            name = "3v3 Arena",
            keywords = {"3v3", "3s", "threes", "3v3 arena", "three vs three", "arena"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.Arena3v3"}, searchButtonText = "3v3", text = "3v3 Arena is in the Rated panel" }
            }
        },
        {
            name = "Rated Battlegrounds",
            keywords = {"rbg", "rated bg", "rated battleground", "rated battlegrounds", "10v10", "ten vs ten"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.RatedBG", "PVPQueueFrame.HonorInset.RatedPanel.RatedBGButton", "HonorFrame.BonusFrame.RatedBGButton"}, text = "Rated Battlegrounds is in the Rated panel" }
            }
        },
        {
            name = "Solo Battlegrounds (Blitz)",
            keywords = {"solo bg", "solo battleground", "solo battlegrounds", "solo rated bg", "battleground", "blitz", "rated battleground blitz", "battleground blitz"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"ConquestFrame.SoloBG", "ConquestFrame.Brawl1v1"}, searchButtonText = "Solo Battlegrounds", text = "Solo Battlegrounds (Blitz) is in the Rated panel" }
            }
        },
        
        -- =====================
        -- PREMADE GROUPS - PVP CATEGORIES
        -- =====================
        {
            name = "Arenas (Premade)",
            keywords = {"arena premade", "arena group", "arena lfg", "find arena", "arena"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Arenas", text = "Select Arenas from the Premade Groups list" }
            }
        },
        {
            name = "Arena Skirmishes (Premade)",
            keywords = {"arena skirmish premade", "skirmish group", "skirmish lfg", "skirmish"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Arena Skirmishes", text = "Select Arena Skirmishes from the Premade Groups list" }
            }
        },
        {
            name = "Battlegrounds (Premade)",
            keywords = {"bg premade", "battleground group", "bg lfg", "find bg", "battleground"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Battlegrounds", text = "Select Battlegrounds from the Premade Groups list" }
            }
        },
        {
            name = "Rated Battlegrounds (Premade)",
            keywords = {"rated bg premade", "rbg premade", "rbg group", "rbg lfg", "rated battleground"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Rated Battlegrounds", text = "Select Rated Battlegrounds from the Premade Groups list" }
            }
        },
        {
            name = "Custom PvP Group",
            keywords = {"custom pvp", "custom group", "custom lfg", "pvp custom", "custom"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Premade Groups"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 3 },
                { waitForFrame = "PVEFrame", searchButtonText = "Custom", text = "Select Custom from the Premade Groups list" }
            }
        },
        
        -- =====================
        -- ADVENTURE GUIDE TABS
        -- =====================
        {
            name = "Journeys",
            keywords = {"journeys", "journey", "adventure journeys"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 1, text = "Click the Journeys tab" }
            }
        },
        {
            name = "Traveler's Log",
            keywords = {"traveler", "travelers log", "traveler log", "travel log"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 2, text = "Click the Traveler's Log tab" }
            }
        },
        {
            name = "Suggested Content",
            keywords = {"suggested", "suggested content", "recommendations"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 3, text = "Click the Suggested Content tab" }
            }
        },
        {
            name = "Dungeons (Journal)",
            keywords = {"dungeon journal", "dungeon guide", "dungeon encounters", "dungeon bosses"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 4, text = "Click the Dungeons tab" }
            }
        },
        {
            name = "Raids (Journal)",
            keywords = {"raid journal", "raid guide", "raid encounters", "raid bosses"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 5, text = "Click the Raids tab" }
            }
        },
        {
            name = "Item Sets",
            keywords = {"item sets", "tier sets", "set bonuses", "class sets"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 6, text = "Click the Item Sets tab" }
            }
        },
        {
            name = "Tutorials",
            keywords = {"tutorials", "tutorial", "help guide", "how to"},
            category = "Adventure Guide",
            buttonFrame = "EJMicroButton",
            path = {"Adventure Guide"},
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = 7, text = "Click the Tutorials tab" }
            }
        },
        
        -- =====================
        -- WARBAND COLLECTIONS TABS
        -- =====================
        {
            name = "Mounts",
            keywords = {"mounts", "mount", "riding", "mount collection", "flying"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 1 }
            }
        },
        {
            name = "Pet Journal",
            keywords = {"pets", "pet", "battle pets", "companion", "pet collection", "critter", "pet journal"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 2 }
            }
        },
        {
            name = "Toy Box",
            keywords = {"toys", "toy", "toybox", "toy box", "fun items"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 3 }
            }
        },
        {
            name = "Heirlooms",
            keywords = {"heirlooms", "heirloom", "leveling gear", "bind on account", "boa"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 4 }
            }
        },
        {
            name = "Appearances (Transmog)",
            keywords = {"transmog", "transmogrification", "appearance", "appearances", "wardrobe", "cosmetic", "looks", "mog"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 5, text = "Click the Appearances tab" }
            }
        },
        {
            name = "Campsites",
            keywords = {"campsites", "campsite", "camp", "camping", "rest area"},
            category = "Warband Collections",
            buttonFrame = "CollectionsMicroButton",
            path = {"Warband Collections"},
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 6 }
            }
        },
        
        -- =====================
        -- OTHER UI ELEMENTS
        -- =====================
        {
            name = "Bags / Inventory",
            keywords = {"bags", "bag", "inventory", "backpack", "items", "storage"},
            category = "Inventory",
            icon = 130716,
            path = {},
            steps = {
                { buttonFrame = "MainMenuBarBackpackButton" }
            }
        },
        {
            name = "Friends List",
            keywords = {"friends", "social", "bnet", "battlenet", "contacts", "whisper", "online"},
            category = "Social",
            icon = 132175,
            path = {},
            steps = {
                { buttonFrame = "QuickJoinToastButton" }
            }
        },
        {
            name = "World Map",
            keywords = {"map", "world map", "zone map", "navigation"},
            category = "Navigation",
            icon = 134269,
            path = {},
            steps = {
                { customText = "Press M to open the World Map" }
            }
        },
        {
            name = "Calendar",
            keywords = {"calendar", "events", "holidays", "schedule"},
            category = "Social",
            icon = 134939,
            path = {},
            steps = {
                { customText = "Click the clock/time display on your minimap to open the Calendar" }
            }
        },
    }
    
    for _, item in ipairs(uiItems) do
        if not item.icon and not item.buttonFrame then
            item.icon = 134400
        end
        if not item.path then
            item.path = {}
        end
        table.insert(uiSearchData, item)
    end
end

function Database:SearchUI(query)
    if not query or query == "" or #query < 2 then
        return {}
    end
    
    query = string.lower(query)
    local results = {}
    
    for _, data in ipairs(uiSearchData) do
        -- Skip entries that have an availability check that returns false
        if data.available and not data.available() then
            -- Not available in current context, skip
        else
        local score = 0
        local nameLower = string.lower(data.name)
        
        -- Exact name match
        if nameLower == query then
            score = 200
        -- Name starts with query
        elseif string.sub(nameLower, 1, #query) == query then
            score = 150
        -- Name contains query
        elseif string.find(nameLower, query, 1, true) then
            score = 100
        end
        
        -- Keyword matching
        if data.keywords then
            for _, keyword in ipairs(data.keywords) do
                local kw = string.lower(keyword)
                if kw == query then
                    score = score + 80
                elseif string.find(kw, query, 1, true) then
                    score = score + 40
                end
            end
        end
        
        if score > 0 then
            local result = {}
            for k, v in pairs(data) do
                result[k] = v
            end
            result.score = score
            table.insert(results, result)
        end
        end -- else (availability check)
    end
    
    table.sort(results, function(a, b) return a.score > b.score end)
    return results
end

-- Build a hierarchical tree from flat results for display
function Database:BuildHierarchicalResults(results)
    if not results or #results == 0 then
        return {}
    end
    
    -- Group results by their top-level path (first element)
    local byTopLevel = {}
    for _, item in ipairs(results) do
        local path = item.path or {}
        local topLevel = path[1] or "_root"
        if not byTopLevel[topLevel] then
            byTopLevel[topLevel] = {}
        end
        table.insert(byTopLevel[topLevel], item)
    end
    
    -- Sort top-level groups alphabetically
    local topLevels = {}
    for k in pairs(byTopLevel) do
        table.insert(topLevels, k)
    end
    table.sort(topLevels)
    
    -- Build the hierarchical list, processing one top-level branch at a time
    local hierarchical = {}
    local addedPaths = {}
    
    for _, topLevel in ipairs(topLevels) do
        local items = byTopLevel[topLevel]
        
        -- Sort items within this branch by full path, then name
        table.sort(items, function(a, b)
            local pathA = table.concat(a.path or {}, "/")
            local pathB = table.concat(b.path or {}, "/")
            if pathA ~= pathB then
                return pathA < pathB
            end
            return a.name < b.name
        end)
        
        -- Add each item with its path nodes
        for _, item in ipairs(items) do
            local path = item.path or {}
            
            -- Add parent path nodes if not already added
            local currentPathKey = ""
            for i, pathPart in ipairs(path) do
                currentPathKey = currentPathKey .. "/" .. pathPart
                
                if not addedPaths[currentPathKey] then
                    addedPaths[currentPathKey] = true
                    local parentData = self:FindItemByName(pathPart)
                    table.insert(hierarchical, {
                        name = pathPart,
                        depth = i - 1,
                        isPathNode = true,
                        data = parentData,
                    })
                end
            end
            
            -- Add the actual item
            table.insert(hierarchical, {
                name = item.name,
                depth = #path,
                isPathNode = false,
                data = item,
            })
        end
    end
    
    -- Remove duplicates (where a path node is also an actual result)
    local seen = {}
    local cleaned = {}
    for _, entry in ipairs(hierarchical) do
        local key = entry.name .. "_" .. entry.depth
        if not seen[key] then
            seen[key] = true
            table.insert(cleaned, entry)
        elseif not entry.isPathNode then
            -- Replace path node with actual entry
            for i, existing in ipairs(cleaned) do
                if existing.name == entry.name and existing.depth == entry.depth then
                    cleaned[i] = entry
                    break
                end
            end
        end
    end
    
    return cleaned
end

function Database:FindItemByName(name)
    for _, data in ipairs(uiSearchData) do
        if data.name == name then
            return data
        end
    end
    return nil
end

Database:Initialize()
