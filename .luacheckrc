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
    "BINDING_NAME_EASYFIND_TOGGLE_FOCUS",
    "BINDING_NAME_EASYFIND_CLEAR",
    "BINDING_NAME_EASYFIND_MAP_FOCUS",
    "EncounterJournal",
    "TransmogFrame",
}

-- WoW API globals (read-only)
read_globals = {
    -- WoW Lua extensions
    "bit",
    "debugstack", "debugprofilestart", "debugprofilestop", "strsplit", "strtrim", "wipe", "hooksecurefunc",
    "format", "time", "date",

    -- Menus
    "MenuUtil",

    -- Core API
    "CreateFrame", "CreateFont", "CreateVector2D", "CreateColor",
    "GetTime", "GetLocale", "GetCVar", "SetCVar", "GetCursorPosition", "GetRealmName",
    "GetAddOnMetadata", "GetAtlasInfo", "GetMinimapShape",
    "GetBindingKey", "GetBindingAction", "GetCurrentBindingSet", "SaveBindings", "SetBinding",
    "GetNumBindings", "GetBinding",
    "GetCategoryInfo", "GetPlayerFacing",
    "SetPortraitTexture", "ShowUIPanel", "HideUIPanel", "ToggleWorldMap", "ToggleDropDownMenu",
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
    "SpellBookFrame", "PlayerSpellsFrame", "CollectionsJournal",
    "PVEFrame", "ReputationFrame", "TokenFrame",
    "GroupFinderFrame", "LFGListFrame", "HelpFrame", "ClassTalentFrame",
    "GameMenuFrame", "MacroFrame",
    "GuildMicroButton", "StoreMicroButton", "PlayerFrame", "StoreFrame",
    "LFDParentFrame", "RaidFinderFrame",
    "LFGListPVEStub", "LFGListPVPStub",
    "HonorFrame", "ConquestFrame", "TrainingGroundsFrame",
    "PVPQueueFrame",
    "AchievementFrameCategories_ExpandToCategory",
    "AchievementFrameCategories_UpdateDataProvider",
 "Transmog_LoadUI",
    "EncounterJournal_LoadUI", "EncounterJournal_DisplayInstance",
    "EncounterJournal_DisplayEncounter", "PanelTemplates_SetTab",
    "Menu", "ScrollBoxConstants",

    -- C_* namespaces
    "C_AddOns", "C_AchievementInfo", "C_AreaPoiInfo", "C_CurrencyInfo", "C_EquipmentSet", "C_Item",
    "C_EncounterJournal", "C_GossipInfo", "C_Heirloom", "C_MajorFactions", "C_Map",
    "C_Minimap", "C_MountJournal", "C_Navigation", "C_PetJournal",
    "C_Reputation", "C_SuperTrack", "C_TaxiMap", "C_Texture", "C_Timer",
    "C_ToyBox", "C_TransmogCollection", "C_TransmogOutfitInfo", "C_TransmogSets", "C_VignetteInfo",

    -- UI utility functions
    "UIFrameFadeIn", "UIFrameFadeOut", "UIFrameFadeRemoveFrame",
    "AchievementFrameCategories_SelectElementData",
    "UnitPopup_ShowMenu", "BattlePetToolTip_ShowLink", "BattlePetTooltip",
    "GetUnitSpeed", "GetItemCooldown", "EJ_GetInstanceInfo", "UnitName",
    "GetItemInfoInstant", "GetItemStats", "GetSpecialization", "GetSpecializationInfo",
    "GetNumTitles", "GetTitleName", "IsTitleKnown", "GetCurrentTitle", "SetCurrentTitle",
    "UnitClass", "GetLootSpecialization", "DressUpItemLink", "DressUpTransmogSet",
    "GetNumClasses", "GetClassInfo", "GetNumSpecializationsForClassID",
    "GetSpecializationInfoForClassID", "RAID_CLASS_COLORS",
    "EJ_GetCurrentTier", "EJ_SelectTier", "EJ_GetInstanceByIndex",
    "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter",
    "EJ_SetDifficulty", "EJ_SetLootFilter", "EJ_SetSlotFilter",
    "EJ_GetNumLoot", "EJ_GetLootInfoByIndex",
    "HasAction", "PlaceAction", "PickupAction", "ClearCursor", "GetActionCooldown",
    "PickupSpell", "PickupItem", "PickupMacro", "C_Spell",
    "GetCursorInfo", "GetMouseFoci", "GetMouseFocus",
    "SetCursor", "ResetCursor",
    "ACCEPT", "CANCEL", "StaticPopup_Show",
    "C_SpellBook", "C_Container", "GetNumSpellTabs", "GetSpellTabInfo",
    "GetSpellBookItemInfo", "GetSpellBookItemName", "GetSpellBookItemTexture",
    "GetFlyoutInfo", "GetFlyoutSlotInfo",
    "GetContainerNumSlots", "GetContainerItemInfo", "PickupContainerItem",
    "NUM_BAG_SLOTS", "GetNumMacros", "GetMacroInfo", "MAX_ACCOUNT_MACROS",
    "ShowMacroFrame", "MacroFrame", "MacroFrame_SelectMacro", "MacroFrame_Update",
    "MacroFrame_OnTabChanged", "PanelTemplates_SetTab", "C_AddOns", "LoadAddOn",
    "CreateMacro",
    "SetOverrideBindingClick", "ClearOverrideBindings",

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
