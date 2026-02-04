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
                { waitForFrame = "CharacterFrame", tabIndex = 1 }
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
            keywords = {"training", "training grounds", "practice", "brawl", "pvp"},
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
        -- QUICK MATCH SPECIFICS (Arena Skirmish, Random BG)
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
                { waitForFrame = "PVEFrame", text = "Select Arena Skirmish from the dropdown menu" }
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
                { waitForFrame = "PVEFrame", text = "Select Random Battleground from the dropdown menu" }
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
                { waitForFrame = "PVEFrame", searchButtonText = "Solo Shuffle", text = "Solo Shuffle is the first option in the Rated panel" }
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
                { waitForFrame = "PVEFrame", searchButtonText = "2v2", text = "2v2 Arena is in the Rated panel" }
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
                { waitForFrame = "PVEFrame", searchButtonText = "3v3", text = "3v3 Arena is in the Rated panel" }
            }
        },
        {
            name = "Rated Battlegrounds",
            keywords = {"rbg", "rated bg", "rated battleground", "rated battlegrounds", "10v10"},
            category = "PvP",
            buttonFrame = "LFDMicroButton",
            path = {"Group Finder", "Player vs. Player", "Rated"},
            steps = {
                { buttonFrame = "LFDMicroButton" },
                { waitForFrame = "PVEFrame", tabIndex = 2 },
                { waitForFrame = "PVEFrame", pvpSideTabIndex = 2 },
                { waitForFrame = "PVEFrame", regionFrames = {"PVPQueueFrame.HonorInset.RatedPanel.RatedBGButton", "HonorFrame.BonusFrame.RatedBGButton"}, text = "Rated Battlegrounds is in the Rated panel" }
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
