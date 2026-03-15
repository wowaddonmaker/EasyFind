std = "lua51"
max_line_length = false

-- Globals this addon sets
globals = {
    "EasyFind",
    "EasyFindDB",
    "EasyFind_OnAddonCompartmentClick",
    "SlashCmdList",
    "StaticPopupDialogs",
    "SLASH_EASYFIND1",
    "BINDING_NAME_EASYFIND_TOGGLE",
    "BINDING_NAME_EASYFIND_FOCUS",
    "BINDING_NAME_EASYFIND_TOGGLE_FOCUS",
    "BINDING_NAME_EASYFIND_CLEAR",
}

-- WoW API globals (read-only)
read_globals = {
    -- WoW Lua extensions
    "debugstack", "strsplit", "strtrim", "wipe", "hooksecurefunc",
    "format", "time",

    -- Core API
    "CreateFrame", "CreateFont", "GetTime", "GetLocale", "GetCVar",
    "GetCursorPosition", "GetAddOnMetadata", "GetAtlasInfo",
    "GetBindingKey", "GetCurrentBindingSet", "SaveBindings", "SetBinding",
    "SetPortraitTexture", "ToggleWorldMap", "ToggleDropDownMenu",
    "InterfaceOptions_AddCategory", "InCombatLockdown",
    "IsShiftKeyDown", "IsMouseButtonDown", "IsAltKeyDown", "IsControlKeyDown",
    "IsInGroup", "IsInInstance", "UnitIsGroupLeader",
    "UnitFactionGroup", "UnitPosition",
    "StaticPopup_Show", "GameTooltip_Hide", "PlaySound", "ReloadUI",
    "GetSpellInfo", "GetItemInfo",
    "UseToyByItemID",

    -- Frames and UI objects
    "UIParent", "GameTooltip", "WorldMapFrame", "Minimap", "MinimapCluster",
    "CharacterFrame", "PaperDollFrame", "AchievementFrame",
    "SpellBookFrame", "PlayerSpellsFrame", "CollectionsJournal",
    "EncounterJournal", "PVEFrame", "ReputationFrame", "TokenFrame",
    "GroupFinderFrame", "LFGListFrame", "HelpFrame", "ClassTalentFrame",
    "GuildMicroButton", "StoreMicroButton", "PlayerFrame", "StoreFrame",

    -- C_* namespaces
    "C_AddOns", "C_AreaPoiInfo", "C_CurrencyInfo", "C_EncounterJournal",
    "C_GossipInfo", "C_MajorFactions", "C_Map", "C_Minimap",
    "C_MountJournal", "C_Navigation", "C_PetJournal", "C_Reputation",
    "C_SuperTrack", "C_TaxiMap", "C_Texture", "C_Timer", "C_ToyBox",
    "C_VignetteInfo",

    -- Constants, Enums, Mixins
    "Enum", "Settings", "BackdropTemplateMixin",
    "SOUNDKIT", "UIDROPDOWNMENU_OPEN_MENU", "UISpecialFrames",
    "LE_PET_JOURNAL_FILTER_COLLECTED", "LE_PET_JOURNAL_FILTER_NOT_COLLECTED",

    -- Font objects
    "Game15Font_Shadow", "GameFontNormal", "GameFontNormalSmall",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontDisable",
    "GameFontDisableSmall", "GameFontNormalLarge",
}

-- WoW callbacks have fixed signatures; unused args are normal
unused_args = false
self = false

-- Per-file overrides for data/generated files
files["StaticLocations.lua"] = { max_line_length = false }
files["Locales/deDE.lua"] = { max_line_length = false }
files["Database.lua"] = { max_line_length = false }
