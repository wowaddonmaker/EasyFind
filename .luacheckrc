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
    "SLASH_EASYFINDCLEARCHAT1",
    "BINDING_NAME_EASYFIND_TOGGLE_FOCUS",
    "BINDING_NAME_EASYFIND_CLEAR",
    "BINDING_NAME_EASYFIND_MAP_FOCUS",
    "EncounterJournal",
    "TransmogFrame",
    "SettingsPanel",
    "TokenFrame",
    "QuickKeybindFrame",
    "SetItemRef",
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
    "DEFAULT_CHAT_FRAME", "DoEmote", "GetScreenWidth", "GetScreenHeight",
    "CreateFrame", "CreateFont", "CreateVector2D", "CreateColor",
    "GetTime", "GetLocale", "GetCVar", "SetCVar", "GetCursorPosition", "GetRealmName",
    "GetAddOnMetadata", "GetAtlasInfo", "GetMinimapShape",
    "GetBindingKey", "GetBindingAction", "GetCurrentBindingSet", "SaveBindings", "SetBinding",
    "GetNumBindings", "GetBinding",
    "BattlefieldMapFrame", "MinimapCluster",
    "ToggleBag", "ToggleBackpack", "ToggleAllBags", "ToggleSheath",
    "ToggleCharacter", "ToggleAchievementFrame", "ToggleQuestLog", "ToggleFriendsFrame",
    "ToggleCollectionsJournal", "ToggleEncounterJournal", "ToggleGuildFrame",
    "TogglePVPUI", "PVEFrame_ToggleFrame", "C_VoiceChat",
    "GetBuildInfo",
    "ToggleMinimap", "ToggleBattlefieldMap", "Sound_ToggleMusic", "Sound_ToggleSound",
    "ToggleChannelFrame", "ToggleQuickJoinPanel", "ToggleRaidFrame", "HousingFramesUtil",
    "VoiceChat_ToggleMutedFromUserAction", "VoiceChat_ToggleDeafenedFromUserAction",
    "GetCategoryInfo", "GetPlayerFacing",
    "SetPortraitTexture", "ShowUIPanel", "HideUIPanel", "ToggleWorldMap", "ToggleDropDownMenu",
    "InterfaceOptions_AddCategory", "InCombatLockdown",
    "IsShiftKeyDown", "IsMouseButtonDown", "IsAltKeyDown", "IsControlKeyDown",
    "IsInGroup", "IsInInstance", "IsIndoors", "UnitIsGroupLeader",
    "IsInRaid", "IsInGuild", "UnitExists", "UnitIsPlayer", "SendChatMessage",
    "ChatEdit_GetActiveWindow", "ChatEdit_InsertLink", "ChatEdit_ChooseBoxForSend",
    "ChatEdit_UpdateHeader", "ChatEdit_ActivateChat", "NUM_CHAT_WINDOWS",
    "SELECTED_CHAT_FRAME", "COMBATLOG", "CombatLogClearEntries",
    "ChatFrame_OpenChat", "DEFAULT_CHAT_FRAME",
    "UnitFactionGroup", "UnitPosition",
    "StaticPopup_Show", "GameTooltip_Hide", "PlaySound", "ReloadUI",
    "GetSpellInfo", "GetItemInfo", "UseToyByItemID", "GetItemClassInfo", "CreateAtlasMarkup",
    "GetSpellLink", "GetAchievementLink",
    "GetMacroSpell", "GetMacroItem",
    "PanelTemplates_GetSelectedTab",

    -- Frames and UI objects
    "UIParent", "GameTooltip", "WorldMapFrame", "WorldFrame", "Minimap", "MinimapCluster",
    "CharacterFrame", "PaperDollFrame", "AchievementFrame",
    "CharacterStatsPane", "PaperDollTitlesPane", "PaperDollEquipmentManagerPane",
    "CurrencyFrame",
    "SpellBookFrame", "PlayerSpellsFrame", "CollectionsJournal",
    "PVEFrame", "ReputationFrame", "TokenFramePopup",
    "GroupFinderFrame", "LFGListFrame", "HelpFrame", "ClassTalentFrame",
    "GameMenuFrame", "MacroFrame",
    "GuildMicroButton", "StoreMicroButton", "PlayerFrame", "StoreFrame",
    "LFDParentFrame", "RaidFinderFrame",
    "LFGListPVEStub", "LFGListPVPStub",
    "HonorFrame", "ConquestFrame", "TrainingGroundsFrame",
    "PVPQueueFrame",
    "AchievementFrameCategories_ExpandToCategory",
    "AchievementFrameCategories_UpdateDataProvider",
    "AchievementFrame_LoadUI", "AchievementFrame_SelectAchievement",
    "OpenAchievementFrameToAchievement",
    "AchievementFrame", "GetCategoryList", "GetCategoryNumAchievements",
    "GetStatisticsCategoryList", "GetStatistic",
    "GetAchievementInfo", "GetAchievementNumCriteria", "GetAchievementCriteriaInfo",
    "GetPreviousAchievement",
    "SetAchievementSearchString", "GetNumFilteredAchievements",
    "GetFilteredAchievementID",
    "AddTrackedAchievement", "RemoveTrackedAchievement",
    "IsTrackedAchievement", "AchievementFrame_ToggleTracking",
    "C_ContentTracking",
 "Transmog_LoadUI",
    "EncounterJournal_LoadUI", "EncounterJournal_DisplayInstance",
    "EncounterJournal_DisplayEncounter", "PanelTemplates_SetTab",
    "Menu", "ScrollBoxConstants",

    -- C_* namespaces
    "C_AddOns", "EventUtil", "C_AchievementInfo", "C_AreaPoiInfo", "C_ClassTalents",
    "C_CurrencyInfo", "C_EquipmentSet", "C_Item",
    "C_EncounterJournal", "C_GossipInfo", "C_Heirloom", "C_HousingCatalog", "C_HousingDecor", "C_LFGList", "C_MajorFactions", "C_Map",
    "C_Minimap", "C_MountJournal", "C_Navigation", "C_PetJournal",
    "C_Reputation", "C_SuperTrack", "C_TaxiMap", "C_Texture", "C_Timer",
    "C_ToyBox", "C_Traits", "C_TransmogCollection", "C_TransmogOutfitInfo",
    "C_TransmogSets", "C_VignetteInfo",

    -- UI utility functions
    "UIFrameFadeIn", "UIFrameFadeOut", "UIFrameFadeRemoveFrame",
    "AchievementFrameCategories_SelectElementData",
    "UnitPopup_ShowMenu", "BattlePetToolTip_ShowLink", "BattlePetTooltip",
    "GetUnitSpeed", "GetItemCooldown", "EJ_GetInstanceInfo", "UnitName",
    "GetItemInfoInstant", "GetItemStats", "GetSpecialization", "GetSpecializationInfo",
    "C_SpecializationInfo", "SetSpecialization",
    "GetNumSpecializations",
    "GetNumTitles", "GetTitleName", "IsTitleKnown", "GetCurrentTitle", "SetCurrentTitle",
    "UnitClass", "UnitGUID", "GetLootSpecialization", "DressUpItemLink", "DressUpTransmogSet",
    "GetNumClasses", "GetClassInfo", "GetNumSpecializationsForClassID",
    "GetSpecializationInfoForClassID", "RAID_CLASS_COLORS", "GetNumExpansions",
    -- Inline answers (Search/Answers.lua): gold, item level, durability,
    -- keystone, rating.
    "GetMoney", "GetCoinTextureString", "GetAverageItemLevel",
    "COPPER_PER_SILVER", "COPPER_PER_GOLD",
    "GetInventoryItemDurability", "C_MythicPlus", "C_ChallengeMode",
    "UnitFullName", "GetNormalizedRealmName",
    "GetProfessions", "GetProfessionInfo", "C_TradeSkillUI", "EnumerateFrames",
    "IsPlayerSpell",
    "EJ_GetCurrentTier", "EJ_SelectTier", "EJ_GetInstanceByIndex",
    "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter",
    "EJ_SetDifficulty", "EJ_SetLootFilter", "EJ_SetSlotFilter",
    "EJ_GetNumLoot", "EJ_GetLootInfoByIndex",
    "HasAction", "PlaceAction", "PickupAction", "ClearCursor", "GetActionCooldown",
    "CursorHasItem", "DeleteCursorItem",
    "PickupSpell", "PickupItem", "PickupMacro", "C_Spell",
    "GetCursorInfo", "GetMouseFoci", "GetMouseFocus",
    "SetCursor", "ResetCursor",
    "ACCEPT", "CANCEL", "StaticPopup_Show",
    "C_SpellBook", "C_Container", "C_Bank", "GetNumSpellTabs", "GetSpellTabInfo",
    "GetSpellBookItemInfo", "GetSpellBookItemName", "GetSpellBookItemTexture",
    "GetFlyoutInfo", "GetFlyoutSlotInfo",
    "GetContainerNumSlots", "GetContainerItemInfo", "PickupContainerItem",
    "NUM_BAG_SLOTS", "NUM_TOTAL_EQUIPPED_BAG_SLOTS",
    "GetNumMacros", "GetMacroInfo", "GetMacroIndexByName", "MAX_ACCOUNT_MACROS",
    "ShowMacroFrame", "MacroFrame", "MacroFrame_SelectMacro", "MacroFrame_Update",
    "MacroFrame_OnTabChanged", "PanelTemplates_SetTab", "C_AddOns", "LoadAddOn",
    "CreateMacro",
    "SetOverrideBindingClick", "ClearOverrideBindings",

    -- Data types
    "UiMapPoint",

    -- Blizzard settings frames
    "InterfaceOptionsFrame",

    -- Constants, Enums, Mixins
    "Enum", "Settings", "BackdropTemplateMixin",
    "SOUNDKIT", "UIDROPDOWNMENU_OPEN_MENU", "UISpecialFrames",
    "FACTION_BAR_COLORS", "ITEM_QUALITY_COLORS",
    "LE_PET_JOURNAL_FILTER_COLLECTED", "LE_PET_JOURNAL_FILTER_NOT_COLLECTED",
    "LE_PARTY_CATEGORY_INSTANCE",

    -- Font objects
    "Game15Font_Shadow", "GameFontNormal", "GameFontNormalSmall",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontHighlightLarge",
    "GameFontDisable", "GameFontDisableSmall", "GameFontNormalLarge",

    -- Misc WoW API
    "securecallfunction", "GetCVarBool", "GetCurrentKeyBoardFocus",
    "IsKeyDown", "OpenBackpack", "OpenBag", "GetItemSpell",
    "StaticPopup_Visible", "IsGraphicsSettingValueSupported",
    "QuestScrollFrame", "LibStub",

    -- Localization / faction strings
    "FACTION_ALLIANCE", "FACTION_HORDE",
    "SETTINGS_CONFIRM_DISCARD", "SETTINGS_UNAPPLIED_EXIT",
    "SETTINGS_UNAPPLIED_APPLY_AND_EXIT", "SETTINGS_UNAPPLIED_CANCEL",

    -- Currency filter enums
    "CURRENCY_FILTER_TYPE_TRANSFERABLE", "CURRENCY_FILTER_TYPE_CHARACTER",
}

-- WoW callbacks have fixed signatures; unused args are normal
unused_args = false
self = false

exclude_files = {
    "dev/tests/vendor/*",
}
