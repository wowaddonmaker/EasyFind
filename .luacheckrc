std = "lua51"
max_line_length = false

-- Suppress warnings that are standard WoW addon patterns, not real issues
ignore = {
    "431",  -- shadowing upvalue (self in nested callbacks is standard WoW pattern)
    "432",  -- shadowing upvalue argument
}

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
    "EncounterJournal",
}

-- WoW API globals (read-only)
read_globals = {
    -- WoW Lua extensions
    "debugstack", "strsplit", "strtrim", "wipe", "hooksecurefunc",
    "format", "time", "date",

    -- Core API
    "CreateFrame", "CreateFont", "CreateVector2D",
    "GetTime", "GetLocale", "GetCVar", "GetCursorPosition", "GetRealmName",
    "GetAddOnMetadata", "GetAtlasInfo", "GetMinimapShape",
    "GetBindingKey", "GetCurrentBindingSet", "SaveBindings", "SetBinding",
    "GetCategoryInfo", "GetPlayerFacing",
    "SetPortraitTexture", "ShowUIPanel", "ToggleWorldMap", "ToggleDropDownMenu",
    "InterfaceOptions_AddCategory", "InCombatLockdown",
    "IsShiftKeyDown", "IsMouseButtonDown", "IsAltKeyDown", "IsControlKeyDown",
    "IsInGroup", "IsInInstance", "IsIndoors", "UnitIsGroupLeader",
    "UnitFactionGroup", "UnitPosition",
    "StaticPopup_Show", "GameTooltip_Hide", "PlaySound", "ReloadUI",
    "GetSpellInfo", "GetItemInfo", "UseToyByItemID",
    "PanelTemplates_GetSelectedTab",

    -- Frames and UI objects
    "UIParent", "GameTooltip", "WorldMapFrame", "Minimap", "MinimapCluster",
    "CharacterFrame", "PaperDollFrame", "AchievementFrame",
    "CharacterStatsPane", "PaperDollTitlesPane", "PaperDollEquipmentManagerPane",
    "CurrencyFrame",
    "SpellBookFrame", "PlayerSpellsFrame", "CollectionsJournal", "TransmogFrame",
    "PVEFrame", "ReputationFrame", "TokenFrame",
    "GroupFinderFrame", "LFGListFrame", "HelpFrame", "ClassTalentFrame",
    "GuildMicroButton", "StoreMicroButton", "PlayerFrame", "StoreFrame",
    "LFDParentFrame", "RaidFinderFrame",
    "LFGListPVEStub", "LFGListPVPStub",
    "HonorFrame", "ConquestFrame", "TrainingGroundsFrame",
    "PVPQueueFrame",
    "AchievementFrameCategories_ExpandToCategory",
    "AchievementFrameCategories_UpdateDataProvider",
 "Transmog_LoadUI",
    "EncounterJournal_LoadUI", "PanelTemplates_SetTab",
    "Menu", "ScrollBoxConstants",

    -- C_* namespaces
    "C_AddOns", "C_AchievementInfo", "C_AreaPoiInfo", "C_CurrencyInfo",
    "C_EncounterJournal", "C_GossipInfo", "C_MajorFactions", "C_Map",
    "C_Minimap", "C_MountJournal", "C_Navigation", "C_PetJournal",
    "C_Reputation", "C_SuperTrack", "C_TaxiMap", "C_Texture", "C_Timer",
    "C_ToyBox", "C_TransmogOutfitInfo", "C_VignetteInfo",

    -- UI utility functions
    "UIFrameFadeIn", "UIFrameFadeOut", "UIFrameFadeRemoveFrame",
    "AchievementFrameCategories_SelectElementData",
    "UnitPopup_ShowMenu", "BattlePetToolTip_ShowLink",
    "GetUnitSpeed", "GetItemCooldown", "EJ_GetInstanceInfo", "UnitName",
    "GetItemInfoInstant", "GetItemStats", "GetSpecialization", "GetSpecializationInfo",
    "UnitClass", "GetLootSpecialization", "DressUpItemLink",
    "EJ_GetCurrentTier", "EJ_SelectTier", "EJ_GetInstanceByIndex",
    "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter",
    "EJ_SetDifficulty", "EJ_SetLootFilter", "EJ_SetSlotFilter",
    "EJ_GetNumLoot", "EJ_GetLootInfoByIndex",
    "HasAction", "PlaceAction", "PickupAction", "ClearCursor", "GetActionCooldown",

    -- Data types
    "UiMapPoint",

    -- Cross-addon references
    "EasyFindDevDB",

    -- Blizzard settings frames
    "SettingsPanel", "InterfaceOptionsFrame",

    -- Constants, Enums, Mixins
    "Enum", "Settings", "BackdropTemplateMixin",
    "SOUNDKIT", "UIDROPDOWNMENU_OPEN_MENU", "UISpecialFrames",
    "FACTION_BAR_COLORS",
    "LE_PET_JOURNAL_FILTER_COLLECTED", "LE_PET_JOURNAL_FILTER_NOT_COLLECTED",

    -- Font objects
    "Game15Font_Shadow", "GameFontNormal", "GameFontNormalSmall",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontDisable",
    "GameFontDisableSmall", "GameFontNormalLarge",
}

-- WoW callbacks have fixed signatures; unused args are normal
unused_args = false
self = false
