local _, ns = ...
local BlizzOptionsSearch = {}
ns.BlizzOptionsSearch = BlizzOptionsSearch

local Utils = ns.Utils
local Loc = ns.L
local SearchFocus = ns.SearchFocus
local tinsert = Utils.tinsert
local slower = Utils.slower
local SafeAfter = Utils.SafeAfter
local pcall = pcall
local coroutine = coroutine
local setmetatable = setmetatable
local tconcat = table.concat

local liveSettingsYield
local function MaybeYieldLiveSettings()
    if liveSettingsYield then liveSettingsYield() end
end

local SecureCall = Utils.SecureCall

-- Per-category proto cache. Entries with the same (category, catName,
-- pathArr) share `category`/`path`/`settingsCategory`/`settingCategoryID`
-- via __index, so each entry only stores its unique fields. With ~15-20
-- unique catNames driving 599 game-settings entries the win is huge.
-- Keyed on a string concat so identical paths reuse one MT regardless
-- of which builder created them.
local settingsCatMTCache = {}
local function GetSettingsCatMT(category, catName, catID, pathArr)
    local pathKey = pathArr and tconcat(pathArr, "\31") or ""
    local key = category .. "\31" .. (catName or "") .. "\31" .. pathKey
    local cached = settingsCatMTCache[key]
    if cached then return cached end
    local proto = {
        category          = category,
        path              = pathArr,
        settingsCategory  = catName,
        settingCategoryID = catID,
    }
    local mt = { __index = proto }
    settingsCatMTCache[key] = mt
    return mt
end


-- Settings.GetCategoryList was removed in Midnight (12.0); the modern
-- entry point is SettingsPanel:GetAllCategories.
local function GetSettingsCategoryList()
    if SettingsPanel and SettingsPanel.GetAllCategories then
        local ok, list = pcall(SettingsPanel.GetAllCategories, SettingsPanel)
        if ok and type(list) == "table" then return list end
    end
    if Settings and Settings.GetCategoryList then
        local ok, list = pcall(Settings.GetCategoryList)
        if ok and type(list) == "table" then return list end
    end
    return nil
end
local function HasSettingsCategoryAccess()
    return (SettingsPanel and SettingsPanel.GetAllCategories) ~= nil
        or (Settings and Settings.GetCategoryList) ~= nil
end

-- Graphics settings that Blizzard renders as SliderWithSteppers inside the
-- BaseQualityControls container, with the slider's live min/max/step.
-- The init.data.settings TABLE KEYS use the CVar name (graphicsViewDistance)
-- but the Setting object's GetVariable() returns the PROXY_* name. We key
-- on what GetVariable() actually returns. Values verified via /devqs on
-- Midnight 12.0.
-- Blizzard's internal range is 0-9 but the in-game slider displays 1-10
-- (their formatter adds 1). Mirror that with `plusOne` so our inline
-- slider label matches what the player sees in the Settings panel.
local function PlusOneFormatter(v) return tostring((tonumber(v) or 0) + 1) end
local QUALITY_SLIDER_OVERRIDES = {
    PROXY_GRAPHICS_QUALITY        = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_RAID_GRAPHICS_QUALITY   = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_VIEW_DISTANCE           = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_RAID_VIEW_DISTANCE      = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_ENVIRONMENT_DETAIL      = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_RAID_ENVIRONMENT_DETAIL = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_GROUND_CLUTTER          = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
    PROXY_RAID_GROUND_CLUTTER     = { min = 0, max = 9, step = 1, formatter = PlusOneFormatter },
}
local BASE_QUALITY_SETTINGS = {
    PROXY_SHADOW_QUALITY          = true,
    PROXY_RAID_SHADOW_QUALITY     = true,
    PROXY_LIQUID_DETAIL           = true,
    PROXY_RAID_LIQUID_DETAIL      = true,
    PROXY_PARTICLE_DENSITY        = true,
    PROXY_RAID_PARTICLE_DENSITY   = true,
    PROXY_SSAO                    = true,
    PROXY_RAID_SSAO               = true,
    PROXY_DEPTH_EFFECTS           = true,
    PROXY_RAID_DEPTH_EFFECTS      = true,
    PROXY_COMPUTE_EFFECTS         = true,
    PROXY_RAID_COMPUTE_EFFECTS    = true,
    PROXY_OUTLINE_MODE            = true,
    PROXY_RAID_OUTLINE_MODE       = true,
    PROXY_TEXTURE_RESOLUTION      = true,
    PROXY_RAID_TEXTURE_RESOLUTION = true,
    PROXY_SPELL_DENSITY           = true,
    PROXY_RAID_SPELL_DENSITY      = true,
    PROXY_PROJECTED_TEXTURES      = true,
    PROXY_RAID_PROJECTED_TEXTURES = true,
}
for variable in pairs(QUALITY_SLIDER_OVERRIDES) do
    BASE_QUALITY_SETTINGS[variable] = true
end

-- { CVar/variable, category name, type code, [min, max, step, name suffix] }
-- type: c=checkbox, d=dropdown, s=slider, o=open panel / read-only value
-- Display names come from Blizzard's Settings API at scan time (see
-- GetSettingDisplayName below). Variables Blizzard doesn't register
-- need an English entry in SETTING_NAME_FALLBACK; rows that resolve
-- neither way drop out of search rather than show untranslated text.
local SETTINGS_DATA = {
    -- Controls
    {"deselectOnClick","Controls","c"},
    {"autoDismountFlying","Controls","c"},
    {"autoClearAFK","Controls","c"},
    {"interactOnLeftClick","Controls","c"},
    {"lootUnderMouse","Controls","c"},
    {"autoLootDefault","Controls","c"},
    {"AUTOLOOTTOGGLE","Controls","d"},
    {"PROXY_ENABLE_INTERACT","Controls","c"},
    {"softTargettingInteractKeySound","Controls","c"},
    {"ClipCursor","Controls","c"},
    {"mouseInvertPitch","Controls","c"},
    {"PROXY_MOUSE_LOOK_SPEED","Controls","s",90,270,18},
    {"cameraWaterCollision","Controls","c"},
    {"PROXY_CAMERA_SPEED","Controls","s",90,270,18},
    {"cameraSmoothStyle","Controls","d"},
    {"cameraDistanceMaxZoomFactor","Controls","s",1,2,0.1},
    {"cameraTerrainTilt","Controls","c"},
    {"cameraBobbing","Controls","c"},
    {"cameraPivot","Controls","c"},
    -- Interface
    {"UnitNameOwn","Interface","c"},
    {"PROXY_NPC_NAMES","Interface","d"},
    {"UnitNameNonCombatCreatureName","Interface","c"},
    {"UnitNameFriendlyPlayerName","Interface","c"},
    {"UnitNameFriendlyMinionName","Interface","c"},
    {"UnitNameEnemyPlayerName","Interface","c"},
    {"UnitNameEnemyMinionName","Interface","c"},
    {"nameplateShowAll","Interface","c"},
    {"nameplateShowEnemies","Interface","c"},
    {"nameplateShowEnemyMinions","Interface","c"},
    {"nameplateShowEnemyMinus","Interface","c"},
    {"nameplateShowFriends","Interface","c"},
    {"nameplateShowFriendlyMinions","Interface","c"},
    {"nameplateMotion","Interface","d"},
    {"nameplateMaxDistance","Interface","s",20,41,1},
    {"nameplateShowCastBars","Interface","c"},
    {"showTutorials","Interface","c"},
    {"PROXY_STATUS_TEXT","Interface","d"},
    {"PROXY_CHAT_BUBBLES","Interface","d"},
    {"PROXY_SHOW_HELM","Interface","c"},
    {"PROXY_SHOW_CLOAK","Interface","c"},
    {"instantQuestText","Interface","c"},
    {"autoQuestWatch","Interface","c"},
    {"displayFreeBagSlots","Interface","c"},
    {"consolidateBuffs","Interface","c"},
    {"hideOutdoorWorldState","Interface","c"},
    {"showMinimapClock","Interface","c"},
    {"showNewbieTips","Interface","c"},
    {"showLoadingScreenTips","Interface","c"},
    {"showTargetCastbar","Interface","c"},
    {"showDynamicBuffSize","Interface","c"},
    {"unitFramesDisplayIncomingHeals","Interface","c"},
    {"useClassicGuildUI","Interface","c"},
    {"raidFramesDisplayPowerBars","Interface","c"},
    {"raidFramesDisplayOnlyHealerPowerBars","Interface","c"},
    {"raidFramesDisplayClassColor","Interface","c"},
    {"raidOptionDisplayPets","Interface","c"},
    {"raidOptionDisplayMainTankAndAssist","Interface","c"},
    {"raidFramesDisplayDebuffs","Interface","c"},
    {"raidFramesDisplayOnlyDispellableDebuffs","Interface","c"},
    {"raidFramesHealthText","Interface","d"},
    -- Action Bars
    {"PROXY_SHOW_ACTIONBAR_2","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_3","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_4","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_5","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_6","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_7","Action Bars","c"},
    {"PROXY_SHOW_ACTIONBAR_8","Action Bars","c"},
    {"countdownForCooldowns","Action Bars","c"},
    -- Combat
    {"PROXY_SELF_HIGHLIGHT","Combat","d"},
    {"showTargetOfTarget","Combat","c"},
    {"doNotFlashLowHealthWarning","Combat","c"},
    {"lossOfControl","Combat","c"},
    {"enableFloatingCombatText","Combat","c"},
    {"floatingCombatTextFloatMode","Combat","d"},
    {"floatingCombatTextLowManaHealth","Combat","c"},
    {"floatingCombatTextAuras","Combat","c"},
    {"floatingCombatTextAuraFade","Combat","c"},
    {"floatingCombatTextCombatState","Combat","c"},
    {"floatingCombatTextDodgeParryMiss","Combat","c"},
    {"floatingCombatTextDamageReduction","Combat","c"},
    {"floatingCombatTextRepChanges","Combat","c"},
    {"floatingCombatTextReactives","Combat","c"},
    {"floatingCombatTextFriendlyHealers","Combat","c"},
    {"floatingCombatTextComboPoints","Combat","c"},
    {"floatingCombatTextEnergyGains","Combat","c"},
    {"floatingCombatTextHonorGains","Combat","c"},
    {"PROXY_SELF_CAST","Combat","d"},
    {"SELFCAST","Combat","d"},
    {"FOCUSCAST","Combat","d"},
    {"PROXY_ACTION_TARGETING","Combat","c"},
    {"floatingCombatTextCombatDamage","Combat","c"},
    {"floatingCombatTextCombatLogPeriodicSpells","Combat","c"},
    {"floatingCombatTextPetMeleeDamage","Combat","c"},
    {"floatingCombatTextCombatHealing","Combat","c"},
    {"autoRangedCombat","Combat","c"},
    -- Social
    {"PROXY_DISABLE_CHAT","Social","c"},
    {"profanityFilter","Social","c"},
    {"guildMemberNotify","Social","c"},
    {"blockTrades","Social","c"},
    {"PROXY_BLOCK_GUILD_INVITES","Social","c"},
    {"restrictCalendarInvites","Social","c"},
    {"blockChannelInvites","Social","c"},
    {"showToastOnline","Social","c"},
    {"showToastOffline","Social","c"},
    {"showToastBroadcast","Social","c"},
    {"showToastFriendRequest","Social","c"},
    {"showToastWindow","Social","c"},
    {"chatStyle","Social","d"},
    {"whisperMode","Social","d"},
    {"showTimestamps","Social","d"},
    -- Keybindings
    {"PROXY_CHARACTER_SPECIFIC_BINDINGS","Keybindings","c"},
    -- General / Accessibility
    {"enableMovePad","General","c"},
    {"PROXY_MINIMUM_CHARACTER_NAME_SIZE","General","s",0,64,2},
    {"PROXY_SICKNESS","General","c"},
    {"PROXY_SICKNESS_SHAKE","General","d"},
    {"cursorSizePreferred","General","d"},
    {"PROXY_TARGET_TOOLTIP","General","c"},
    {"PROXY_INTERACT_ICONS","General","d"},
    -- Colorblind Mode
    {"colorblindMode","Colorblind Mode","c"},
    {"colorblindSimulator","Colorblind Mode","d"},
    {"colorblindWeaknessFactor","Colorblind Mode","s",0,1,0.05},
    -- Subtitles
    {"movieSubtitle","Subtitles","c"},
    {"PROXY_MOVIE_SUBTITLE_BACKGROUND","Subtitles","d"},
    -- Graphics
    {"PROXY_PRIMARY_MONITOR","Graphics","d"},
    {"PROXY_DISPLAY_MODE","Graphics","d"},
    {"PROXY_RESOLUTION","Graphics","d"},
    {"PROXY_RESOLUTION_RENDER_SCALE","Graphics","s",0.333,2,0.05},
    {"PROXY_GRAPHICS_QUALITY","Graphics","s",0,9,1},
    {"PROXY_RAID_GRAPHICS_QUALITY","Graphics","s",0,9,1," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_VIEW_DISTANCE","Graphics","s",0,9,1},
    {"PROXY_RAID_VIEW_DISTANCE","Graphics","s",0,9,1," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_ENVIRONMENT_DETAIL","Graphics","s",0,9,1},
    {"PROXY_RAID_ENVIRONMENT_DETAIL","Graphics","s",0,9,1," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_GROUND_CLUTTER","Graphics","s",0,9,1},
    {"PROXY_RAID_GROUND_CLUTTER","Graphics","s",0,9,1," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_SHADOW_QUALITY","Graphics","o"},
    {"PROXY_RAID_SHADOW_QUALITY","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_LIQUID_DETAIL","Graphics","o"},
    {"PROXY_RAID_LIQUID_DETAIL","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_PARTICLE_DENSITY","Graphics","o"},
    {"PROXY_RAID_PARTICLE_DENSITY","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_SSAO","Graphics","o"},
    {"PROXY_RAID_SSAO","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_DEPTH_EFFECTS","Graphics","o"},
    {"PROXY_RAID_DEPTH_EFFECTS","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_COMPUTE_EFFECTS","Graphics","o"},
    {"PROXY_RAID_COMPUTE_EFFECTS","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_OUTLINE_MODE","Graphics","o"},
    {"PROXY_RAID_OUTLINE_MODE","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_TEXTURE_RESOLUTION","Graphics","o"},
    {"PROXY_RAID_TEXTURE_RESOLUTION","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_SPELL_DENSITY","Graphics","o"},
    {"PROXY_RAID_SPELL_DENSITY","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_PROJECTED_TEXTURES","Graphics","o"},
    {"PROXY_RAID_PROJECTED_TEXTURES","Graphics","o",nil,nil,nil," (" .. (_G["RAID"] or "Raid") .. ")"},
    {"PROXY_VERTICAL_SYNC","Graphics","d"},
    {"LowLatencyMode","Graphics","d"},
    {"PROXY_ANTIALIASING","Graphics","d"},
    {"PROXY_FXAA","Graphics","d"},
    {"PROXY_MSAA","Graphics","d"},
    {"PROXY_MSAA_ALPHA","Graphics","c"},
    {"PROXY_CAMERA_FOV","Graphics","s"},
    {"PROXY_TRIPLE_BUFFERING","Graphics","c"},
    {"textureFilteringMode","Graphics","d"},
    {"shadowrt","Graphics","d"},
    {"ResampleQuality","Graphics","d"},
    {"vrsValar","Graphics","d"},
    {"PROXY_GRAPHICS_API","Graphics","d"},
    {"PROXY_RESAMPLE_SHARPNESS","Graphics","s"},
    {"Contrast","Graphics","s"},
    {"Brightness","Graphics","s"},
    {"Gamma","Graphics","s"},
    {"PROXY_OPT_GPU_FEATURES","Graphics","c"},
    {"PROXY_DEVICE_MT","Graphics","c"},
    {"PROXY_CMDLIST_MT","Graphics","c"},
    {"PROXY_ADV_WORK_SUBMIT","Graphics","c"},
    -- Audio
    {"Sound_EnableAllSound","Audio","c"},
    {"Sound_MasterVolume","Audio","s"},
    {"Sound_MusicVolume","Audio","s"},
    {"Sound_SFXVolume","Audio","s"},
    {"Sound_AmbienceVolume","Audio","s"},
    {"Sound_DialogVolume","Audio","s"},
    {"Sound_EnableMusic","Audio","c"},
    {"Sound_ZoneMusicNoDelay","Audio","c"},
    {"Sound_EnablePetBattleMusic","Audio","c"},
    {"Sound_EnableSFX","Audio","c"},
    {"Sound_EnablePetSounds","Audio","c"},
    {"Sound_EnableEmoteSounds","Audio","c"},
    {"Sound_EnableDialog","Audio","c"},
    {"Sound_EnableErrorSpeech","Audio","c"},
    {"Sound_EnableAmbience","Audio","c"},
    {"Sound_EnableSoundWhenGameIsInBG","Audio","c"},
    {"Sound_EnableReverb","Audio","c"},
    {"Sound_EnablePositionalLowPassFilter","Audio","c"},
    -- Network
    {"disableServerNagle","Network","c"},
    {"useIPv6","Network","c"},
    {"advancedCombatLogging","Network","c"},
}

local TYPE_MAP = { c = "checkbox", d = "dropdown", s = "slider" }

-- Hardcoded option lists for CVar dropdowns SettingsPanel cannot
-- enumerate (not registered as Setting objects). Each entry:
-- { value, label }. Hardware-dependent dropdowns are omitted.
local NONE_LABEL = _G["NONE"] or "None"
local ALT_KEY_LABEL = _G["ALT_KEY"] or "ALT key"
local CTRL_KEY_LABEL = _G["CTRL_KEY"] or "CTRL key"
local SHIFT_KEY_LABEL = _G["SHIFT_KEY"] or "SHIFT key"
local ALL_LABEL = _G["ALL"] or "All"
local CVAR_DROPDOWN_OPTIONS = {
    AUTOLOOTTOGGLE = {
        { value = "NONE",  label = NONE_LABEL },
        { value = "ALT",   label = ALT_KEY_LABEL },
        { value = "CTRL",  label = CTRL_KEY_LABEL },
        { value = "SHIFT", label = SHIFT_KEY_LABEL },
    },
    PROXY_NPC_NAMES = {
        { value = "1", label = _G["NPC_NAMES_DROPDOWN_TRACKED"] or "Quest NPCs" },
        { value = "2", label = _G["NPC_NAMES_DROPDOWN_HOSTILE"] or "Hostile and Quest NPCs" },
        { value = "3", label = _G["NPC_NAMES_DROPDOWN_INTERACTIVE"] or "Hostile, Quest, and Interactive NPCs" },
        { value = "4", label = _G["NPC_NAMES_DROPDOWN_ALL"] or "All NPCs" },
        { value = "5", label = _G["NPC_NAMES_DROPDOWN_NONE"] or NONE_LABEL },
    },
    nameplateMotion = {
        { value = "0", label = _G["UNIT_NAMEPLATES_TYPE_1"] or "Overlapping Nameplates" },
        { value = "1", label = _G["UNIT_NAMEPLATES_TYPE_2"] or "Stacking Nameplates" },
    },
    PROXY_STATUS_TEXT = {
        { value = "1", label = _G["STATUS_TEXT_VALUE"] or "Numeric Value" },
        { value = "2", label = _G["STATUS_TEXT_PERCENT"] or "Percentage" },
        { value = "3", label = _G["STATUS_TEXT_BOTH"] or "Both" },
        { value = "4", label = NONE_LABEL },
    },
    PROXY_CHAT_BUBBLES = {
        { value = "1", label = ALL_LABEL },
        { value = "2", label = NONE_LABEL },
        { value = "3", label = _G["CHAT_BUBBLES_EXCLUDE_PARTY_CHAT"] or "Exclude party chat" },
    },
    raidFramesHealthText = {
        { value = "none",       label = NONE_LABEL },
        { value = "health",     label = _G["RAID_HEALTH_TEXT_HEALTH"] or "Health Remaining" },
        { value = "losthealth", label = _G["RAID_HEALTH_TEXT_LOSTHEALTH"] or "Health Lost" },
        { value = "perc",       label = _G["RAID_HEALTH_TEXT_PERC"] or "Health Percentage" },
    },
    PROXY_SELF_HIGHLIGHT = {
        { value = "0", label = _G["OFF"] or "Off" },
        { value = "1", label = _G["SELF_HIGHLIGHT_MODE_CIRCLE"] or "Circle" },
        { value = "2", label = _G["SELF_HIGHLIGHT_MODE_ICON"] or "Icon" },
        { value = "3", label = _G["SELF_HIGHLIGHT_MODE_CIRCLE_AND_ICON"] or "Circle and Icon" },
    },
    floatingCombatTextFloatMode = {
        { value = "1", label = _G["COMBAT_TEXT_SCROLL_UP"] or "Scroll Up" },
        { value = "2", label = _G["COMBAT_TEXT_SCROLL_DOWN"] or "Scroll Down" },
        { value = "3", label = _G["COMBAT_TEXT_SCROLL_ARC"] or "Arc" },
    },
    PROXY_SELF_CAST = {
        { value = "1", label = NONE_LABEL },
        { value = "2", label = _G["SELF_CAST_AUTO"] or "Auto" },
        { value = "3", label = _G["SELF_CAST_KEY_PRESS"] or "Key Press" },
        { value = "4", label = _G["SELF_CAST_AUTO_AND_KEY_PRESS"] or "Auto and Key Press" },
    },
    SELFCAST = {
        { value = "ALT",   label = ALT_KEY_LABEL },
        { value = "CTRL",  label = CTRL_KEY_LABEL },
        { value = "SHIFT", label = SHIFT_KEY_LABEL },
    },
    FOCUSCAST = {
        { value = "NONE",  label = NONE_LABEL },
        { value = "ALT",   label = ALT_KEY_LABEL },
        { value = "CTRL",  label = CTRL_KEY_LABEL },
        { value = "SHIFT", label = SHIFT_KEY_LABEL },
    },
    chatStyle = {
        { value = "classic", label = _G["CLASSIC_STYLE"] or "Classic Style" },
        { value = "im",      label = _G["IM_STYLE"] or "IM Style" },
    },
    whisperMode = {
        { value = "inline",            label = _G["CONVERSATION_MODE_INLINE"] or "In-line" },
        { value = "popout",            label = _G["CONVERSATION_MODE_POPOUT"] or "New Tab" },
        { value = "popout_and_inline", label = _G["CONVERSATION_MODE_POPOUT_AND_INLINE"] or "Both" },
    },
    showTimestamps = {
        { value = "none",          label = NONE_LABEL },
        { value = "%H:%M ",        label = "15:27" },
        { value = "%I:%M ",        label = "03:27" },
        { value = "%H:%M:%S ",     label = "15:27:32" },
        { value = "%I:%M %p ",     label = "03:27 PM" },
        { value = "%I:%M:%S ",     label = "03:27:32" },
        { value = "%I:%M:%S %p ",  label = "03:27:32 PM" },
    },
    PROXY_SICKNESS_SHAKE = {
        { value = "1", label = NONE_LABEL },
        { value = "2", label = _G["SHAKE_INTENSITY_FULL"] or "Full" },
        { value = "3", label = _G["SHAKE_INTENSITY_REDUCED"] or "Reduced" },
    },
    cursorSizePreferred = {
        { value = "-1", label = _G["CURSOR_SIZE_DEFAULT"] or "Default" },
        { value = "0",  label = "32x32" },
        { value = "1",  label = "48x48" },
        { value = "2",  label = "64x64" },
        { value = "3",  label = "96x96" },
        { value = "4",  label = "128x128" },
    },
    PROXY_INTERACT_ICONS = {
        { value = "1", label = _G["INTERACT_ICONS_DEFAULT"] or "NPCs Only (Default)" },
        { value = "2", label = _G["INTERACT_ICONS_SHOW_ALL"] or "Show All" },
        { value = "3", label = _G["INTERACT_ICONS_SHOW_NONE"] or "Show None" },
    },
    colorblindSimulator = {
        { value = "0", label = NONE_LABEL },
        { value = "1", label = _G["COLORBLIND_OPTION_PROTANOPIA"] or "Protanopia" },
        { value = "2", label = _G["COLORBLIND_OPTION_DEUTERANOPIA"] or "Deuteranopia" },
        { value = "3", label = _G["COLORBLIND_OPTION_TRITANOPIA"] or "Tritanopia" },
    },
    PROXY_MOVIE_SUBTITLE_BACKGROUND = {
        { value = "1", label = NONE_LABEL },
        { value = "2", label = _G["CINEMATIC_SUBTITLES_BACKGROUND_OPTION_DARK"] or "Dark" },
        { value = "3", label = _G["CINEMATIC_SUBTITLES_BACKGROUND_OPTION_LIGHT"] or "Light" },
    },
    LowLatencyMode = {
        { value = "0", label = _G["VIDEO_OPTIONS_DISABLED"] or "Disabled" },
        { value = "1", label = _G["VIDEO_OPTIONS_BUILTIN"] or "Built-in" },
        { value = "2", label = _G["VIDEO_OPTIONS_NVIDIA_REFLEX"] or "NVIDIA Reflex" },
        { value = "3", label = _G["VIDEO_OPTIONS_NVIDIA_REFLEX_BOOST"] or "NVIDIA Reflex + Boost" },
        { value = "4", label = _G["VIDEO_OPTIONS_INTEL_XELL"] or "Intel XeLL" },
    },
    PROXY_ANTIALIASING = {
        { value = "0", label = NONE_LABEL },
        { value = "1", label = Loc["OPT_AA_IMAGE_BASED"] },
        { value = "2", label = Loc["OPT_AA_MULTISAMPLE"] },
        { value = "3", label = _G["ADVANCED_LABEL"] or "Advanced" },
    },
    PROXY_FXAA = {
        { value = "0", label = NONE_LABEL },
        { value = "1", label = _G["ANTIALIASING_FXAA_LOW"] or "FXAA Low" },
        { value = "2", label = _G["ANTIALIASING_FXAA_HIGH"] or "FXAA High" },
        { value = "3", label = _G["ANTIALIASING_CMAA"] or "CMAA" },
    },
    PROXY_MSAA = {
        { value = "0", label = NONE_LABEL },
        { value = "1", label = "2x" },
        { value = "2", label = "4x" },
        { value = "3", label = "8x" },
    },
    textureFilteringMode = {
        { value = "0", label = _G["VIDEO_OPTIONS_BILINEAR"] or "Bilinear" },
        { value = "1", label = _G["VIDEO_OPTIONS_TRILINEAR"] or "Trilinear" },
        { value = "2", label = "2x " .. Loc["OPT_ANISOTROPIC"] },
        { value = "3", label = "4x " .. Loc["OPT_ANISOTROPIC"] },
        { value = "4", label = "8x " .. Loc["OPT_ANISOTROPIC"] },
        { value = "5", label = "16x " .. Loc["OPT_ANISOTROPIC"] },
    },
    shadowrt = {
        { value = "0", label = _G["VIDEO_OPTIONS_DISABLED"] or "Disabled" },
        { value = "1", label = _G["VIDEO_QUALITY_LABEL2"] or "Fair" },
        { value = "2", label = _G["VIDEO_QUALITY_LABEL3"] or "Good" },
        { value = "3", label = _G["VIDEO_QUALITY_LABEL4"] or "High" },
    },
    ResampleQuality = {
        { value = "0", label = _G["RESAMPLE_QUALITY_POINT"] or "Point" },
        { value = "1", label = _G["RESAMPLE_QUALITY_BILINEAR"] or "Bilinear" },
        { value = "2", label = _G["RESAMPLE_QUALITY_BICUBIC"] or "Bicubic" },
        { value = "3", label = _G["RESAMPLE_QUALITY_FSR"] or "FidelityFX Super Resolution" },
    },
    vrsValar = {
        { value = "0", label = _G["VIDEO_OPTIONS_DISABLED"] or "Disabled" },
        { value = "1", label = _G["VIDEO_OPTIONS_STANDARD"] or "Standard" },
        { value = "2", label = _G["VIDEO_OPTIONS_AGGRESSIVE"] or "Aggressive" },
    },
    cameraSmoothStyle = {
        { value = "0", label = _G["CAMERA_NEVER"] or "Never adjust camera" },
        { value = "1", label = _G["CAMERA_SMART"] or "Only horizontal when moving" },
        { value = "2", label = _G["CAMERA_ALWAYS"] or "Always adjust camera" },
        { value = "4", label = _G["CAMERA_SMARTER"] or "Only when moving" },
    },
    PROXY_GRAPHICS_API = {
        { value = "d3d11", label = _G["GXAPI_D3D11"] or "DirectX 11" },
        { value = "d3d12", label = _G["GXAPI_D3D12"] or "DirectX 12" },
    },
}

local categoryIDByName = {}
local categoryIDByVariable = {}
-- category ID -> the localized display name (cat:GetName()), captured during
-- the crawl so curated settings can show a translated breadcrumb category.
local localizedNameByCategoryID = {}

local settingTooltips = {}

-- Tries OPTION_TOOLTIP_<NAME> and OPTION_TOOLTIP_<CVAR>. PROXY_ vars
-- never have tooltip globals.
local function ResolveTooltipGlobal(displayName, cvar)
    if displayName then
        local fromName = "OPTION_TOOLTIP_" .. displayName:upper():gsub("[%s%-]+", "_"):gsub("[^A-Z0-9_]", "")
        local tip = _G[fromName]
        if type(tip) == "string" and tip ~= "" then return tip end
    end
    if cvar and not cvar:find("^PROXY_") then
        local fromCVar = "OPTION_TOOLTIP_" .. cvar:gsub("(%l)(%u)", "%1_%2"):upper()
        local tip = _G[fromCVar]
        if type(tip) == "string" and tip ~= "" then return tip end
    end
end

local function GetTooltipForVariable(variable, displayName)
    if not variable then return nil end
    local cached = settingTooltips[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    if Settings and Settings.GetSetting then
        local sok, settObj = pcall(Settings.GetSetting, variable)
        if sok and settObj and settObj.GetTooltip then
            local tok, t = pcall(settObj.GetTooltip, settObj)
            if tok and type(t) == "string" and t ~= "" then
                settingTooltips[variable] = t
                return t
            end
        end
    end

    local fromGlobal = ResolveTooltipGlobal(displayName, variable)
    if fromGlobal then
        settingTooltips[variable] = fromGlobal
        return fromGlobal
    end

    settingTooltips[variable] = false
    return nil
end
BlizzOptionsSearch.GetTooltipForVariable = GetTooltipForVariable

local function AddKeyword(kw, text)
    if type(text) == "string" and text ~= "" then
        kw[#kw + 1] = slower(text)
    end
end

local function AddOptionLabelKeywords(kw, options)
    if type(options) ~= "table" then return end
    for i = 1, #options do
        local opt = options[i]
        if type(opt) == "table" then
            AddKeyword(kw, opt.label or opt.text or opt.name)
        end
    end
end

-- Returns { value, label } array or nil. Cached per variable; false
-- sentinel means "looked, none available".
local optionsByVariable = {}
local function NormalizeOptionTable(opts, setting)
    if type(opts) == "function" then
        local ok, o = pcall(opts, setting)
        if not ok then
            ok, o = pcall(opts)
        end
        if not ok then return nil end
        opts = o
    end
    if type(opts) ~= "table" then return nil end
    local norm = {}
    for _, o in ipairs(opts) do
        if type(o) == "table" then
            local value = o.value
            if value == nil then value = o.cvarValue end
            if value == nil and type(o.data) == "table" then
                value = o.data.value
                if value == nil then value = o.data.cvarValue end
                if value == nil then value = o.data.id end
            elseif value == nil then
                value = o.data
            end
            if value == nil and o.GetValue then
                local ok, v = pcall(o.GetValue, o)
                if ok then value = v end
            end
            if value ~= nil then
                local label = o.label or o.text or o.name
                if not label and type(o.data) == "table" then
                    label = o.data.label or o.data.text or o.data.name
                end
                if not label and o.GetText then
                    local ok, text = pcall(o.GetText, o)
                    if ok then label = text end
                end
                if not label and o.GetName then
                    local ok, name = pcall(o.GetName, o)
                    if ok then label = name end
                end
                tinsert(norm, { value = value, label = label or tostring(value) })
            end
        elseif o ~= nil then
            tinsert(norm, { value = o, label = tostring(o) })
        end
    end
    if #norm == 0 then
        for value, label in pairs(opts) do
            if type(label) ~= "table" then
                tinsert(norm, { value = value, label = tostring(label) })
            end
        end
    end
    if #norm == 0 then return nil end
    return norm
end

local function GetInitializerOptions(init, setting)
    local d = init and init.data
    local found
    if type(d) == "table" then
        found = NormalizeOptionTable(d.options, setting)
            or NormalizeOptionTable(d.dropdownOptions, setting)
            or NormalizeOptionTable(d.values, setting)
            or NormalizeOptionTable(d.valueOptions, setting)
    end
    if not found and init and init.GetOptions then
        local ok, opts = pcall(init.GetOptions, init)
        if ok then found = NormalizeOptionTable(opts, setting) end
    end
    if not found and setting and setting.GetOptions then
        local ok, opts = pcall(setting.GetOptions, setting)
        if ok then found = NormalizeOptionTable(opts, setting) end
    end
    return found
end

local function SettingMatchesVariable(setting, variable)
    if not setting or not setting.GetVariable then return false end
    if variable == nil then return true end
    local ok, v = pcall(setting.GetVariable, setting)
    return ok and v == variable
end

local function FindSettingInValue(value, variable, depth, seen)
    if type(value) ~= "table" or depth > 4 then return nil end
    if SettingMatchesVariable(value, variable) then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local preferred = { "setting", "cbSetting", "sliderSetting" }
    for i = 1, #preferred do
        local child = value[preferred[i]]
        local hit = FindSettingInValue(child, variable, depth + 1, seen)
        if hit then return hit end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local hit = FindSettingInValue(child, variable, depth + 1, seen)
            if hit then return hit end
        end
    end
    return nil
end

local function GetInitializerSetting(init, variable)
    local setting
    if init and init.GetSetting then
        local sok, s = pcall(init.GetSetting, init)
        if sok then setting = s end
    end
    local d = init and init.data
    if setting and SettingMatchesVariable(setting, variable) then return setting end
    if d and d.setting and SettingMatchesVariable(d.setting, variable) then
        return d.setting
    end
    if init and init.GetData then
        local dok, dd = pcall(init.GetData, init)
        if dok and dd and SettingMatchesVariable(dd.setting, variable) then
            return dd.setting
        end
        local hit = dok and FindSettingInValue(dd, variable, 0, nil)
        if hit then return hit end
    end
    return FindSettingInValue(d, variable, 0, nil)
end

local function GetOptionsForVariable(variable)
    if not variable then return nil end
    local cached = optionsByVariable[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    -- CVar dropdowns aren't registered as Setting objects; the
    -- SettingsPanel walk can't find them. Hardcoded list first.
    local hardcoded = CVAR_DROPDOWN_OPTIONS[variable]
    if hardcoded then
        optionsByVariable[variable] = hardcoded
        return hardcoded
    end
    if not (SettingsPanel and SettingsPanel.GetLayout and HasSettingsCategoryAccess()) then
        return nil
    end
    local found
    local function scan(cat)
        if found or not cat then return end
        local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
        if lok and layout and layout.GetInitializers then
            local iok, inits = pcall(layout.GetInitializers, layout)
            if iok and inits then
                for _, init in ipairs(inits) do
                    local setting = GetInitializerSetting(init, variable)
                    if setting and setting.GetVariable then
                        local vok, v = pcall(setting.GetVariable, setting)
                        if vok and v == variable then
                            found = GetInitializerOptions(init, setting)
                            return
                        end
                    end
                end
            end
        end
        if cat.GetSubcategories then
            local sok, subs = pcall(cat.GetSubcategories, cat)
            if sok and type(subs) == "table" then
                for _, sub in ipairs(subs) do scan(sub) end
            end
        end
    end
    local list = GetSettingsCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do scan(cat) end
    end
    if found then optionsByVariable[variable] = found end
    return found
end
BlizzOptionsSearch.GetOptionsForVariable = GetOptionsForVariable

-- Slider display formatter from the live registry so curated entries
-- render the same value Blizzard's panel does (e.g., raw 180 -> "5.5").
local formatterByVariable = {}
local function PickFormatter(formatters)
    if type(formatters) ~= "table" then return nil end
    -- MinimalSliderWithSteppersMixin.Label enum: Top (2) mirrors the
    -- live value above the thumb best.
    local f = formatters[2] or formatters[1] or formatters[0]
        or formatters.Top or formatters.Right
    if type(f) == "function" then return f end
    for _, fn in pairs(formatters) do
        if type(fn) == "function" then return fn end
    end
    return nil
end
local function GetFormatterForVariable(variable)
    if not variable then return nil end
    local cached = formatterByVariable[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    if not (SettingsPanel and SettingsPanel.GetLayout and HasSettingsCategoryAccess()) then
        return nil
    end
    local found
    local function scan(cat)
        if found or not cat then return end
        local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
        if lok and layout and layout.GetInitializers then
            local iok, inits = pcall(layout.GetInitializers, layout)
            if iok and inits then
                for _, init in ipairs(inits) do
                    local setting = GetInitializerSetting(init, variable)
                    if setting and setting.GetVariable then
                        local vok, v = pcall(setting.GetVariable, setting)
                        if vok and v == variable then
                            local d = init.data
                            local opts = (type(d) == "table") and d.options or nil
                            if type(opts) == "function" then
                                local ook, o = pcall(opts, setting)
                                if not ook then ook, o = pcall(opts) end
                                if ook then opts = o end
                            end
                            if type(opts) == "table" then
                                found = PickFormatter(opts.formatters)
                            end
                            return
                        end
                    end
                end
            end
        end
        if cat.GetSubcategories then
            local sok, subs = pcall(cat.GetSubcategories, cat)
            if sok and type(subs) == "table" then
                for _, sub in ipairs(subs) do scan(sub) end
            end
        end
    end
    local list = GetSettingsCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do scan(cat) end
    end
    formatterByVariable[variable] = found or false
    return found
end
BlizzOptionsSearch.GetFormatterForVariable = GetFormatterForVariable

-- Apply-flagged settings (graphics, resolution, etc.) stage into
-- setting.pendingValue. Mirror Blizzard's bottom-bar batch UX.
local pendingApplySettings = {}
local pendingChangeCallbacks = {}

local function PendingCount()
    -- Prune entries whose pendingValue cleared from under us when the
    -- user Applied / Cancelled in Blizzard's panel directly.
    local n = 0
    for setting in pairs(pendingApplySettings) do
        if setting.pendingValue ~= nil then
            n = n + 1
        else
            pendingApplySettings[setting] = nil
        end
    end
    return n
end

local function FirePendingChanged()
    local n = PendingCount()
    for i = 1, #pendingChangeCallbacks do
        pcall(pendingChangeCallbacks[i], n)
    end
end

function BlizzOptionsSearch:RegisterPendingChangedCallback(fn)
    if type(fn) ~= "function" then return end
    pendingChangeCallbacks[#pendingChangeCallbacks + 1] = fn
end

function BlizzOptionsSearch:GetPendingApplyCount()
    return PendingCount()
end

function BlizzOptionsSearch:NotePendingApply(variable)
    if not variable or not Settings or not Settings.GetSetting then return end
    local sok, settObj = pcall(Settings.GetSetting, variable)
    if not sok or not settObj then return end
    local hasApply
    if settObj.HasCommitFlag and Settings.CommitFlag and Settings.CommitFlag.Apply then
        local hok, has = pcall(settObj.HasCommitFlag, settObj, Settings.CommitFlag.Apply)
        hasApply = hok and has
    end
    if hasApply and settObj.pendingValue ~= nil then
        pendingApplySettings[settObj] = settObj
        FirePendingChanged()
    elseif pendingApplySettings[settObj] then
        pendingApplySettings[settObj] = nil
        FirePendingChanged()
    end
end

-- Blizzard reuses StaticPopup1..4 slots; walk them to find one matching name.
local function FindStaticPopupSlot(popupName)
    for i = 1, 4 do
        local p = _G["StaticPopup" .. i]
        if p and p:IsShown() and p.which == popupName then return p end
    end
    return nil
end

local function LiftPopupAndRefresh(popup)
    if not popup or popup._easyFindStrataLifted then return end
    popup._easyFindStrataLifted = true
    popup._easyFindOriginalStrata = popup:GetFrameStrata()
    popup:SetFrameStrata("TOOLTIP")
    popup:HookScript("OnHide", function(self)
        if self._easyFindStrataLifted then
            if self._easyFindOriginalStrata then
                self:SetFrameStrata(self._easyFindOriginalStrata)
            end
            self._easyFindStrataLifted = nil
            self._easyFindOriginalStrata = nil
        end
        if ns.Search and ns.Search.RefreshResults then ns.Search:RefreshResults() end
    end)
end

function BlizzOptionsSearch:ApplyPendingChanges()
    if not next(pendingApplySettings) then return end
    -- Route every pending setting through ApplyVariable (the proven
    -- path). Snapshot the variable list first so wiping the table
    -- mid-iteration doesn't break the loop.
    local vars = {}
    for setting in pairs(pendingApplySettings) do
        if setting.GetVariable then
            local ok, v = pcall(setting.GetVariable, setting)
            if ok and v then vars[#vars + 1] = v end
        end
    end
    for i = 1, #vars do self:ApplyVariable(vars[i]) end
    wipe(pendingApplySettings)
    FirePendingChanged()
end

function BlizzOptionsSearch:RevertPendingChanges()
    if not next(pendingApplySettings) then return end
    for setting in pairs(pendingApplySettings) do
        if setting.Revert then pcall(setting.Revert, setting) end
    end
    wipe(pendingApplySettings)
    FirePendingChanged()
end

function BlizzOptionsSearch:HasPendingChange(variable)
    if not variable or not Settings or not Settings.GetSetting then return false end
    local sok, settObj = pcall(Settings.GetSetting, variable)
    if not sok or not settObj then return false end
    return settObj.pendingValue ~= nil
end

-- PROXY_ANTIALIASING's SetValue zeros the OTHER mode's CVar and
-- assumes the chosen mode's CVar is already non-zero. Without
-- Blizzard's quality dropdown to pre-fill, default the dependent CVar
-- to a baseline so applying the parent actually turns AA on.
local PROXY_DEPENDENT_DEFAULTS = {
    PROXY_ANTIALIASING = function(value)
        if value == 1 and GetCVar and tonumber(GetCVar("ffxAntiAliasingMode")) == 0 then
            if SetCVar then pcall(SetCVar, "ffxAntiAliasingMode", "1") end
        elseif value == 2 and GetCVar and tonumber(GetCVar("MSAAQuality")) == 0 then
            if SetCVar then pcall(SetCVar, "MSAAQuality", "2") end
        elseif value == 3 then
            if GetCVar and tonumber(GetCVar("ffxAntiAliasingMode")) == 0
               and SetCVar then pcall(SetCVar, "ffxAntiAliasingMode", "1") end
            if GetCVar and tonumber(GetCVar("MSAAQuality")) == 0
               and SetCVar then pcall(SetCVar, "MSAAQuality", "2") end
        end
    end,
}

-- Parents whose SetValue closure stages Apply-flagged dependents; we
-- must commit the dependents along with the parent.
local PROXY_DEPENDENTS = {
    PROXY_ANTIALIASING = { "PROXY_FXAA", "PROXY_MSAA", "PROXY_MSAA_ALPHA" },
}

local function CommitStagedDependents(parentVar)
    local deps = PROXY_DEPENDENTS[parentVar]
    if not deps or not Settings or not Settings.GetSetting then return end
    for i = 1, #deps do
        local depVar = deps[i]
        local ok, depObj = pcall(Settings.GetSetting, depVar)
        if ok and depObj and depObj.pendingValue ~= nil and depObj.SetValue then
            pcall(depObj.SetValue, depObj, depObj.pendingValue, true)
            pendingApplySettings[depObj] = nil
        end
    end
end

local function HasFlag(settObj, flag)
    if not settObj.HasCommitFlag or not Settings or not Settings.CommitFlag or not flag then
        return false
    end
    local ok, has = pcall(settObj.HasCommitFlag, settObj, flag)
    return ok and has
end

function BlizzOptionsSearch:ApplyVariable(variable)
    if not variable or not Settings or not Settings.GetSetting then return end
    local sok, settObj = pcall(Settings.GetSetting, variable)
    if not sok or not settObj or settObj.pendingValue == nil then return end
    local pending = settObj.pendingValue
    local depsFn = PROXY_DEPENDENT_DEFAULTS[variable]
    if depsFn then pcall(depsFn, pending) end

    -- Revertable settings (monitor, resolution, display mode) need
    -- Blizzard's CommitSettings pipeline so GAME_SETTINGS_TIMED_CONFIRMATION
    -- fires; without it the user has no escape if the change breaks the
    -- screen. SetValue(immediate=true) skips that popup.
    local revertable = HasFlag(settObj, Settings.CommitFlag.Revertable)
    if revertable and SettingsPanel and SettingsPanel.CommitSettings
       and SettingsPanel.modified then
        SettingsPanel.modified[settObj] = settObj
        local deps = PROXY_DEPENDENTS[variable]
        if deps then
            for i = 1, #deps do
                local _, depObj = pcall(Settings.GetSetting, deps[i])
                if depObj and depObj.pendingValue ~= nil then
                    SettingsPanel.modified[depObj] = depObj
                end
            end
        end
        pcall(SettingsPanel.CommitSettings, SettingsPanel, false)
        LiftPopupAndRefresh(FindStaticPopupSlot("GAME_SETTINGS_TIMED_CONFIRMATION"))
        pendingApplySettings[settObj] = nil
        if deps then
            for i = 1, #deps do
                local _, depObj = pcall(Settings.GetSetting, deps[i])
                if depObj then pendingApplySettings[depObj] = nil end
            end
        end
        FirePendingChanged()
        return
    end

    if settObj.SetValue then
        pcall(settObj.SetValue, settObj, pending, true)
    end
    CommitStagedDependents(variable)
    pendingApplySettings[settObj] = nil
    FirePendingChanged()
end

-- Mirror Blizzard's GAME_SETTINGS_CONFIRM_DISCARD popup.
-- DO NOT write `StaticPopupDialogs = StaticPopupDialogs or {}`: any
-- assignment to that global slot taints it (even preserving identity)
-- and the taint propagates into ShowUIPanel / UIParentPanelManager.
if StaticPopupDialogs and not StaticPopupDialogs["EASYFIND_UNAPPLIED_SETTINGS"] then
    StaticPopupDialogs["EASYFIND_UNAPPLIED_SETTINGS"] = {
        text = SETTINGS_CONFIRM_DISCARD or ns.L["POPUP_UNAPPLIED_SETTINGS"],
        button1 = SETTINGS_UNAPPLIED_EXIT or ns.L["POPUP_UNAPPLIED_EXIT"],
        button2 = SETTINGS_UNAPPLIED_APPLY_AND_EXIT or ns.L["POPUP_UNAPPLIED_APPLY"],
        button3 = SETTINGS_UNAPPLIED_CANCEL or ns.L["POPUP_UNAPPLIED_CANCEL"],
        OnButton1 = function()
            if BlizzOptionsSearch.RevertPendingChanges then
                BlizzOptionsSearch:RevertPendingChanges()
            end
            if ns.Search and ns.Search.Hide then ns.Search:Hide() end
        end,
        OnButton2 = function()
            if BlizzOptionsSearch.ApplyPendingChanges then
                BlizzOptionsSearch:ApplyPendingChanges()
            end
            if ns.Search and ns.Search.Hide then ns.Search:Hide() end
        end,
        OnButton3 = function() end,
        OnHide = function()
            if ns.Search and ns.Search.RefocusSearchEditBox then
                SearchFocus:RefocusSearchEditBox()
            end
        end,
        selectCallbackByIndex = true,
        hideOnEscape = 1,
        whileDead = 1,
        fullScreenCover = true,
    }
end

function BlizzOptionsSearch:RevertVariable(variable)
    if not variable or not Settings or not Settings.GetSetting then return end
    local sok, settObj = pcall(Settings.GetSetting, variable)
    if not sok or not settObj or settObj.pendingValue == nil then return end
    if settObj.Revert then pcall(settObj.Revert, settObj) end
    pendingApplySettings[settObj] = nil
    local deps = PROXY_DEPENDENTS[variable]
    if deps then
        for i = 1, #deps do
            local _, depObj = pcall(Settings.GetSetting, deps[i])
            if depObj and depObj.pendingValue ~= nil and depObj.Revert then
                pcall(depObj.Revert, depObj)
                pendingApplySettings[depObj] = nil
            end
        end
    end
    FirePendingChanged()
end

local function CrawlCategory(cat)
    if not cat or not cat.GetID or not cat.GetName then return end
    local catID = cat:GetID()
    local catName = cat:GetName()
    if catName and catName ~= "" then
        categoryIDByName[slower(catName)] = catID
        localizedNameByCategoryID[catID] = catName
    end

    if SettingsPanel and SettingsPanel.GetLayout then
        local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
        if lok and layout and layout.GetInitializers then
            local iok, inits = pcall(layout.GetInitializers, layout)
            if iok and inits then
                for _, init in ipairs(inits) do
                    local setting
                    if init.GetSetting then
                        local sok, s = pcall(init.GetSetting, init)
                        if sok then setting = s end
                    end
                    if not setting and init.data then
                        setting = init.data.setting
                    end
                    if not setting and init.GetData then
                        local dok, d = pcall(init.GetData, init)
                        if dok and d then setting = d.setting end
                    end
                    if setting and setting.GetVariable then
                        local vok, v = pcall(setting.GetVariable, setting)
                        if vok and v then
                            if not categoryIDByVariable[v] then
                                categoryIDByVariable[v] = catID
                            end
                            -- data.tooltip / data.options can be string or
                            -- function; blind indexing raises in some clients.
                            if settingTooltips[v] == nil then
                                local tip
                                pcall(function()
                                    local d = init.data
                                    if type(d) ~= "table" then return end
                                    if type(d.tooltip) == "string" then
                                        tip = d.tooltip
                                        return
                                    end
                                    if type(d.tooltip) == "function" then
                                        local tt = d.tooltip()
                                        if type(tt) == "string" then tip = tt end
                                        return
                                    end
                                    local opts = d.options
                                    if type(opts) == "table" and type(opts.tooltip) == "string" then
                                        tip = opts.tooltip
                                    end
                                end)
                                if not tip and setting.GetTooltip then
                                    local tok, t = pcall(setting.GetTooltip, setting)
                                    if tok and type(t) == "string" and t ~= "" then
                                        tip = t
                                    end
                                end
                                if tip and tip ~= "" then
                                    settingTooltips[v] = tip
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if cat.GetSubcategories then
        local sok, subs = pcall(cat.GetSubcategories, cat)
        if sok and type(subs) == "table" then
            for _, sub in ipairs(subs) do
                CrawlCategory(sub)
            end
        end
    end
end

-- Idempotent: re-crawl after late addon registrations fills in new entries.
local function ResolveCategoryIDs()
    local list = GetSettingsCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do
            pcall(CrawlCategory, cat)
        end
    end
    if SettingsPanel and SettingsPanel.GetAllCategories then
        local ok, all = pcall(SettingsPanel.GetAllCategories, SettingsPanel)
        if ok and type(all) == "table" then
            for _, cat in ipairs(all) do
                pcall(CrawlCategory, cat)
            end
        end
    end
end

-- Open SettingsPanel first; on some clients OpenToCategory alone
-- doesn't show the frame if the panel hasn't been visible this session.
local function ShowSettings()
    if not SettingsPanel then return end
    if SettingsPanel:IsShown() then return end
    if SettingsPanel.Open then
        SecureCall(SettingsPanel.Open, SettingsPanel)
    elseif ShowUIPanel then
        SecureCall(ShowUIPanel, SettingsPanel)
    end
end

local function GetCategoryID(name)
    if not name or name == "" then return nil end
    local cached = categoryIDByName[slower(name)]
    if cached then return cached end
    ResolveCategoryIDs()
    return categoryIDByName[slower(name)]
end

local function GetCategoryIDForVariable(variable)
    if not variable then return nil end
    local cached = categoryIDByVariable[variable]
    if cached then return cached end
    ResolveCategoryIDs()
    return categoryIDByVariable[variable]
end
BlizzOptionsSearch.GetCategoryIDForVariable = GetCategoryIDForVariable

local function OpenSettingsByName(name)
    local id = GetCategoryID(name)
    if not id then return false end
    ShowSettings()
    if Settings and Settings.OpenToCategory then
        pcall(Settings.OpenToCategory, id)
        return true
    end
    return false
end
BlizzOptionsSearch.OpenSettingsByName = OpenSettingsByName

local function GetSettingsScrollBox()
    if not SettingsPanel then return nil end
    return SettingsPanel.Container
        and SettingsPanel.Container.SettingsList
        and SettingsPanel.Container.SettingsList.ScrollBox
end

local function HighlightFoundElement(scrollBox, elementData)
    if not scrollBox or not elementData then return end
    if not ns.Highlight or not ns.Highlight.HighlightFrame then return end
    SafeAfter(0.05, function()
        local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
        if frame then
            ns.Highlight:HighlightFrame(frame, nil, function(target)
                if not target or not target:IsVisible() then return false end
                if not scrollBox.FindFrame then return true end
                return scrollBox:FindFrame(elementData) == target
            end)
        end
    end)
end

local function SettingMatches(setting, variable)
    if not setting or not setting.GetVariable then return false end
    local ok, v = pcall(setting.GetVariable, setting)
    return ok and v == variable
end

-- Returns (elementData, matchKind) where matchKind is "direct" for a
-- standard single-setting initializer or "container" for an initializer
-- that bundles many child settings (BaseQualityControls etc.). Container
-- matches need a different scroll alignment because the data-provider
-- element is ONE row but the rendered frame is a tall block, so centering
-- the top of the block leaves the target child off-screen.
local function FindSettingElement(dp, variable)
    if not dp then return nil end
    local function classify(elementData)
        local inner = elementData and (elementData.data or elementData)
        if not inner then return false end
        if SettingMatches(inner.setting, variable) then return "direct" end
        if SettingMatches(inner.cbSetting, variable) then return "direct" end
        if SettingMatches(inner.sliderSetting, variable) then return "direct" end
        if type(inner.settings) == "table" then
            for _, child in pairs(inner.settings) do
                if SettingMatches(child, variable) then return "container" end
            end
        end
        if type(inner.raidSettings) == "table" then
            for _, child in pairs(inner.raidSettings) do
                if SettingMatches(child, variable) then return "container" end
            end
        end
        return false
    end
    -- Prefer direct matches over container matches: if a standalone row
    -- and a container both reference the same Setting object, scroll to
    -- the standalone row.
    local containerHit, containerKind
    if dp.FindElementDataByPredicate then
        local direct = dp:FindElementDataByPredicate(function(ed)
            return classify(ed) == "direct"
        end)
        if direct then return direct, "direct" end
        containerHit = dp:FindElementDataByPredicate(function(ed)
            return classify(ed) == "container"
        end)
        if containerHit then return containerHit, "container" end
    end
    if dp.GetSize and dp.Find then
        for si = 1, dp:GetSize() do
            local ed = dp:Find(si)
            local kind = classify(ed)
            if kind == "direct" then return ed, "direct" end
            if kind == "container" and not containerHit then
                containerHit, containerKind = ed, "container"
            end
        end
        if containerHit then return containerHit, containerKind end
    end
    return nil
end

-- Walk a container row's rendered frame to find the child sub-frame that
-- corresponds to the target variable. BaseQualityControls names its
-- per-setting child rows by the row's section name (ViewDistance,
-- ShadowQuality, etc.), with the variable they wrap exposed via
-- child.Initializer.data.setting / .cbSetting / .sliderSetting. Without
-- this lookup, scrolling lands on the container's top and leaves a
-- later child below the fold.
-- BaseQualityControls creates its per-setting child rows from C++ without
-- attaching an `initializer` to each, so the standard "walk and match by
-- setting" lookup finds nothing. Map each PROXY_* variable to the
-- well-known frame-name suffix (matches Blizzard's hardcoded child names
-- in SharedXML/Settings/Blizzard_BaseQualityControlsTemplate.xml).
local CONTAINER_CHILD_FRAME_SUFFIX = {
    PROXY_GRAPHICS_QUALITY        = "GraphicsQuality",
    PROXY_RAID_GRAPHICS_QUALITY   = "GraphicsQuality",
    PROXY_VIEW_DISTANCE           = "ViewDistance",
    PROXY_RAID_VIEW_DISTANCE      = "ViewDistance",
    PROXY_ENVIRONMENT_DETAIL      = "EnvironmentDetail",
    PROXY_RAID_ENVIRONMENT_DETAIL = "EnvironmentDetail",
    PROXY_GROUND_CLUTTER          = "GroundClutter",
    PROXY_RAID_GROUND_CLUTTER     = "GroundClutter",
    PROXY_SHADOW_QUALITY          = "ShadowQuality",
    PROXY_RAID_SHADOW_QUALITY     = "ShadowQuality",
    PROXY_LIQUID_DETAIL           = "LiquidDetail",
    PROXY_RAID_LIQUID_DETAIL      = "LiquidDetail",
    PROXY_PARTICLE_DENSITY        = "ParticleDensity",
    PROXY_RAID_PARTICLE_DENSITY   = "ParticleDensity",
    PROXY_SSAO                    = "SSAO",
    PROXY_RAID_SSAO               = "SSAO",
    PROXY_DEPTH_EFFECTS           = "DepthEffects",
    PROXY_RAID_DEPTH_EFFECTS      = "DepthEffects",
    PROXY_COMPUTE_EFFECTS         = "ComputeEffects",
    PROXY_RAID_COMPUTE_EFFECTS    = "ComputeEffects",
    PROXY_OUTLINE_MODE            = "OutlineMode",
    PROXY_RAID_OUTLINE_MODE       = "OutlineMode",
    PROXY_TEXTURE_RESOLUTION      = "TextureResolution",
    PROXY_RAID_TEXTURE_RESOLUTION = "TextureResolution",
    PROXY_SPELL_DENSITY           = "SpellDensity",
    PROXY_RAID_SPELL_DENSITY      = "SpellDensity",
    PROXY_PROJECTED_TEXTURES      = "ProjectedTextures",
    PROXY_RAID_PROJECTED_TEXTURES = "ProjectedTextures",
}

local function FindChildFrameForVariable(containerFrame, variable)
    if not containerFrame or not containerFrame.GetChildren then return nil end
    -- 1) Try the initializer-based lookup first for normal row frames
    --    (combined checkbox+slider rows, plain setting rows).
    local function check(frame, depth)
        if not frame or depth > 6 then return nil end
        local init = frame.initializer or frame.Initializer
        local data = (init and init.data) or frame.data
        if data then
            if SettingMatches(data.setting, variable) then return frame end
            if SettingMatches(data.cbSetting, variable) then return frame end
            if SettingMatches(data.sliderSetting, variable) then return frame end
        end
        if frame.GetChildren then
            local kids = { frame:GetChildren() }
            for i = 1, #kids do
                local hit = check(kids[i], depth + 1)
                if hit then return hit end
            end
        end
        return nil
    end
    local hit = check(containerFrame, 0)
    if hit then return hit end

    -- 2) Fall back to frame-name matching for BaseQualityControls-style
    --    children that have no per-row initializer. Prefer visible
    --    frames so a hidden Base-tab row doesn't shadow the live Raid-
    --    tab row (or vice versa) when both share the same suffix.
    local suffix = CONTAINER_CHILD_FRAME_SUFFIX[variable]
    if suffix then
        local visibleHit, hiddenHit
        local function findByName(frame, depth)
            if not frame or depth > 6 then return end
            if frame.GetDebugName then
                local ok, name = pcall(frame.GetDebugName, frame)
                if ok and name and name:sub(-(#suffix + 1)) == "." .. suffix then
                    if frame.IsVisible and frame:IsVisible() then
                        visibleHit = frame
                    elseif not hiddenHit then
                        hiddenHit = frame
                    end
                end
            end
            if visibleHit then return end
            if frame.GetChildren then
                local kids = { frame:GetChildren() }
                for i = 1, #kids do
                    findByName(kids[i], depth + 1)
                    if visibleHit then return end
                end
            end
        end
        findByName(containerFrame, 0)
        return visibleHit or hiddenHit
    end
    return nil
end

-- Returns true if the variable belongs to the Raid and Battleground tab
-- inside BaseQualityControls. Identified by the canonical PROXY_RAID_*
-- naming Blizzard uses for the raid variants.
local function IsRaidQualityVariable(variable)
    return type(variable) == "string" and variable:find("^PROXY_RAID_") ~= nil
end

-- Walks the container's children to find a tab button by name suffix and
-- clicks it. Used to flip BaseQualityControls into the Raid tab when the
-- target variable is one of the raid variants.
local function ClickTabBySuffix(containerFrame, suffix)
    if not containerFrame or not containerFrame.GetChildren then return false end
    local function find(frame, depth)
        if not frame or depth > 4 then return nil end
        if frame.GetDebugName then
            local ok, name = pcall(frame.GetDebugName, frame)
            if ok and name and name:sub(-(#suffix + 1)) == "." .. suffix then
                return frame
            end
        end
        if frame.GetChildren then
            local kids = { frame:GetChildren() }
            for i = 1, #kids do
                local h = find(kids[i], depth + 1)
                if h then return h end
            end
        end
        return nil
    end
    local tab = find(containerFrame, 0)
    if tab and tab.Click then
        pcall(tab.Click, tab)
        return true
    end
    return false
end

-- Given an outer container frame and a target child frame, return the
-- vertical pixel offset of the child relative to the container's top.
-- Used to convert a container-row scroll into a child-aware scroll.
local function ChildTopOffset(container, child)
    if not container or not child or not child.GetTop or not container.GetTop then
        return 0
    end
    local cTop = container:GetTop()
    local childTop = child:GetTop()
    if not cTop or not childTop then return 0 end
    return cTop - childTop
end

local function ScrollToSettingVariable(variable)
    local scrollBox = GetSettingsScrollBox()
    if not scrollBox then return false end
    local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    local found, kind = FindSettingElement(dp, variable)
    if not found then return false end

    local alignBegin = ScrollBoxConstants and ScrollBoxConstants.AlignBegin
    local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
    -- Direct rows: center via Blizzard's built-in alignment. Container
    -- rows: scroll to begin first (so the container's children render
    -- below the fold predictably), then nudge to center the actual
    -- target child below.
    if kind == "container" then
        scrollBox:ScrollToElementData(found, alignBegin or alignCenter)
        SafeAfter(0, function()
            local outer = scrollBox.FindFrame and scrollBox:FindFrame(found)
            if not outer then return end
            -- For Raid* variables, click the "Raid and Battleground" tab
            -- inside the container first so the raid version of the
            -- row becomes the visible/selected one. Without this, the
            -- panel is left on the Base tab and the user doesn't see
            -- the actual setting they searched for. Defer the child
            -- lookup one frame so the tab swap has settled before we
            -- grab the row reference — otherwise we end up holding a
            -- Base-tab frame that goes hidden the next frame and the
            -- highlight watchdog clears it immediately.
            local tabSwapped
            if IsRaidQualityVariable(variable) then
                tabSwapped = ClickTabBySuffix(outer, "RaidTab")
            else
                tabSwapped = ClickTabBySuffix(outer, "BaseTab")
            end
            local function continueAfterSwap()
                local child = FindChildFrameForVariable(outer, variable)
                if not child then
                    -- Couldn't find the specific child row; fall back
                    -- to highlighting the container so something pulses.
                    HighlightFoundElement(scrollBox, found)
                    return
                end
                local offset = ChildTopOffset(outer, child)
                if offset > 0
                   and scrollBox.SetScrollPercentage and scrollBox.GetScrollPercentage
                   and scrollBox.GetDerivedScrollRange and scrollBox.GetHeight then
                    local range = scrollBox:GetDerivedScrollRange()
                    if range and range > 0 then
                        local curScroll = (scrollBox:GetScrollPercentage() or 0) * range
                        local vH = scrollBox:GetHeight() or 0
                        local cH = (child.GetHeight and child:GetHeight()) or 24
                        local desiredScroll = curScroll + offset + cH / 2 - vH / 2
                        local newPercent = math.max(0, math.min(1, desiredScroll / range))
                        scrollBox:SetScrollPercentage(newPercent)
                    end
                end
                -- Highlight the specific row, not the entire container.
                -- Defer one more frame so a freshly-swapped Raid-tab row
                -- has its final visible state before the highlight
                -- watchdog evaluates target:IsVisible().
                SafeAfter(0, function()
                    local refetched = FindChildFrameForVariable(
                        scrollBox.FindFrame and scrollBox:FindFrame(found), variable)
                    local target = refetched or child
                    if target and target:IsShown()
                       and ns.Highlight and ns.Highlight.HighlightFrame then
                        ns.Highlight:HighlightFrame(target, nil, function(t)
                            return t and t:IsVisible()
                        end)
                    end
                end)
            end
            -- Tab click swaps which child rows are visible/realized.
            -- Defer one frame after the click so the swap finishes
            -- before we measure or grab references; otherwise we hold
            -- a stale frame that goes hidden and the watchdog clears
            -- the highlight immediately.
            if tabSwapped then
                SafeAfter(0, continueAfterSwap)
            else
                continueAfterSwap()
            end
        end)
    else
        scrollBox:ScrollToElementData(found, alignCenter or alignBegin)
        HighlightFoundElement(scrollBox, found)
    end

    return true
end
BlizzOptionsSearch.ScrollToSettingVariable = ScrollToSettingVariable

local function GetBindingIndexForAction(action)
    if not action or not GetNumBindings or not GetBinding then return nil end
    for i = 1, GetNumBindings() do
        local a = GetBinding(i)
        if a == action then return i end
    end
    return nil
end

-- Binding index lives at frame.initializer.data.bindingIndex.
local function FindBindingFrameInSection(sectionFrame, bindingIndex)
    if not sectionFrame or not sectionFrame.Controls then return nil end
    for _, frame in ipairs(sectionFrame.Controls) do
        local idx
        if frame.initializer and frame.initializer.data then
            idx = frame.initializer.data.bindingIndex
        end
        if not idx and frame.data and frame.data.bindingIndex then
            idx = frame.data.bindingIndex
        end
        if idx == bindingIndex then return frame end
    end
    return nil
end

local function ScrollToBindingAction(action, headerName)
    if not action then return false end
    local scrollBox = GetSettingsScrollBox()
    if not scrollBox then return false end
    local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dp then return false end

    local bindingIdx = GetBindingIndexForAction(action)

    -- Match by header name first; fall back to bindingsCategories.
    local headerLower = headerName and slower(headerName) or nil
    local function matchSection(elementData)
        local inner = elementData and (elementData.data or elementData)
        if not inner then return false end
        if headerLower and inner.name and slower(inner.name) == headerLower then
            return true
        end
        if bindingIdx and inner.bindingsCategories then
            for _, entry in ipairs(inner.bindingsCategories) do
                if type(entry) == "table" and entry[1] == bindingIdx then return true end
            end
        end
        return false
    end

    local section
    if dp.FindElementDataByPredicate then
        section = dp:FindElementDataByPredicate(matchSection)
    end
    if not section and dp.GetSize and dp.Find then
        for si = 1, dp:GetSize() do
            local ed = dp:Find(si)
            if matchSection(ed) then section = ed; break end
        end
    end
    if not section then return false end

    local sectionData = section.data or section
    local alignBegin = ScrollBoxConstants and ScrollBoxConstants.AlignBegin
    scrollBox:ScrollToElementData(section, alignBegin)

    -- The section header is ONE data-provider element but renders many
    -- binding child rows underneath. ScrollToElementData puts the header
    -- at the top of the viewport, so a binding ten rows down is still
    -- off-screen. Re-fetch the section frame after layout, find the
    -- specific binding sub-frame, and center it in the viewport when
    -- possible (clamps to the edges near the start/end of the list).
    local function ScrollSectionToChild(child)
        if not child or not child.GetTop then return end
        if not (scrollBox.GetTop and scrollBox.SetScrollPercentage and scrollBox.GetScrollPercentage
                and scrollBox.GetDerivedScrollRange and scrollBox.GetHeight) then return end
        local vpTop, cTop = scrollBox:GetTop(), child:GetTop()
        if not vpTop or not cTop then return end
        local range = scrollBox:GetDerivedScrollRange()
        if not range or range <= 0 then return end
        -- The child's offset down the scrollable content = current scroll plus
        -- how far the child sits below the VIEWPORT top. Measuring from the
        -- viewport (not the section frame) stays correct when the section is
        -- clamped at the list's end and its header is scrolled above the
        -- viewport (e.g. AddOns). The old section-relative math scrolled the
        -- row right back out of view in that case.
        local curScroll = (scrollBox:GetScrollPercentage() or 0) * range
        local vH = scrollBox:GetHeight() or 0
        local cH = (child.GetHeight and child:GetHeight()) or 24
        local childOffset = curScroll + (vpTop - cTop)
        local desiredScroll = childOffset - (vH - cH) / 2
        local newPercent = math.max(0, math.min(1, desiredScroll / range))
        scrollBox:SetScrollPercentage(newPercent)
    end

    local function rowInView(row)
        local vpTop, vpBottom = scrollBox:GetTop(), scrollBox:GetBottom()
        local rTop, rBottom = row:GetTop(), row:GetBottom()
        if not (vpTop and vpBottom and rTop and rBottom) then return true end
        return rTop <= vpTop + 1 and rBottom >= vpBottom - 1
    end

    local function highlightRow(row)
        if row and row.IsShown and row:IsShown()
           and ns.Highlight and ns.Highlight.HighlightFrame then
            ns.Highlight:HighlightFrame(row, nil, function(t)
                return t and t:IsVisible()
            end)
        end
    end

    -- Jumping to a section near the end of the list (e.g. AddOns) scrolls a long
    -- way; the section frame and its row controls take several frames to render,
    -- and ScrollToElementData clamps the last section so the row can still sit
    -- above the viewport. Poll until the section and row exist, then keep nudging
    -- the scroll until the row is genuinely inside the viewport before
    -- highlighting. One shot at the centering math isn't reliable through the
    -- scroll's own animation.
    local function highlightWhenReady(attemptsLeft)
        local sf = scrollBox.FindFrame and scrollBox:FindFrame(section)
        if not sf then
            if attemptsLeft > 0 then
                scrollBox:ScrollToElementData(section, alignBegin)
                SafeAfter(0.1, function() highlightWhenReady(attemptsLeft - 1) end)
            end
            return
        end
        if sectionData and not sectionData.expanded and sf.Button then
            sf.Button:Click()
        end
        local row = bindingIdx and FindBindingFrameInSection(sf, bindingIdx)
        if not row then
            if attemptsLeft > 0 then
                SafeAfter(0.1, function() highlightWhenReady(attemptsLeft - 1) end)
            end
            return
        end
        if not rowInView(row) and attemptsLeft > 0 then
            ScrollSectionToChild(row)
            SafeAfter(0.05, function() highlightWhenReady(attemptsLeft - 1) end)
            return
        end
        highlightRow(row)
    end
    SafeAfter(0.05, function() highlightWhenReady(16) end)

    return true
end
BlizzOptionsSearch.ScrollToBindingAction = ScrollToBindingAction

-- Extra search keywords for settings whose common name differs from the label.
local SETTING_EXTRA_KEYWORDS = {
    nameplateShowEnemies = {
        "enemy nameplate", "enemy nameplates", "enemy unit nameplate",
        "enemy unit nameplates", "hostile nameplate", "hostile nameplates",
    },
    nameplateShowFriends = {
        "friendly nameplate", "friendly nameplates", "friendly unit nameplate",
        "friendly unit nameplates",
    },
    nameplateShowAll = {
        "all nameplates", "always show nameplates",
    },
    PROXY_VERTICAL_SYNC = { "vsync" },
    PROXY_SSAO = { "ambient occlusion" },
    PROXY_RAID_SSAO = { "ambient occlusion", "raid ambient occlusion" },
    PROXY_PROJECTED_TEXTURES = { "projected texture" },
    PROXY_RAID_PROJECTED_TEXTURES = { "projected texture", "raid projected texture" },
}

-- English fallback names for the few variables Blizzard hasn't
-- registered as Setting objects, so Settings.GetSetting returns nil.
-- Audited against Midnight 12.0 in-game; everything else listed in
-- SETTINGS_DATA resolves via the API and picks up the localized name
-- automatically. Non-English clients see the English string for the
-- entries below (Blizzard exposes no localized one for them).
--
-- If a new SETTINGS_DATA row goes missing from search, run
-- `/run local s=Settings.GetSetting("yourVar"); print(s and s:GetName())`
-- in-game. If it prints a string, no entry needed here. If nil, add it.
local SETTING_NAME_FALLBACK = {
    nameplateMotion             = _G["UNIT_NAMEPLATES_TYPES"] or "Nameplate Motion Type",
    floatingCombatTextFloatMode = _G["COMBAT_TEXT_FLOAT_MODE_LABEL"] or "Combat Text Float Mode",
    nameplateShowAll           = "Always Show Nameplates",
    nameplateShowEnemies       = "Enemy Unit Nameplate",
    nameplateShowFriends       = "Friendly Unit Nameplate",
    nameplateMaxDistance       = "Nameplate Maximum Distance",
    nameplateShowCastBars      = "Nameplate Cast Bars",
    PROXY_GRAPHICS_QUALITY      = "Graphics Quality",
    PROXY_RAID_GRAPHICS_QUALITY = "Graphics Quality",
    PROXY_VIEW_DISTANCE         = "View Distance",
    PROXY_RAID_VIEW_DISTANCE    = "View Distance",
    PROXY_ENVIRONMENT_DETAIL    = "Environment Detail",
    PROXY_RAID_ENVIRONMENT_DETAIL = "Environment Detail",
    PROXY_GROUND_CLUTTER        = "Ground Clutter",
    PROXY_RAID_GROUND_CLUTTER   = "Ground Clutter",
    PROXY_SHADOW_QUALITY        = "Shadow Quality",
    PROXY_RAID_SHADOW_QUALITY   = "Shadow Quality",
    PROXY_LIQUID_DETAIL         = "Liquid Detail",
    PROXY_RAID_LIQUID_DETAIL    = "Liquid Detail",
    PROXY_PARTICLE_DENSITY      = "Particle Density",
    PROXY_RAID_PARTICLE_DENSITY = "Particle Density",
    PROXY_SSAO                  = "SSAO",
    PROXY_RAID_SSAO             = "SSAO",
    PROXY_DEPTH_EFFECTS         = "Depth Effects",
    PROXY_RAID_DEPTH_EFFECTS    = "Depth Effects",
    PROXY_COMPUTE_EFFECTS       = "Compute Effects",
    PROXY_RAID_COMPUTE_EFFECTS  = "Compute Effects",
    PROXY_OUTLINE_MODE          = "Outline Mode",
    PROXY_RAID_OUTLINE_MODE     = "Outline Mode",
    PROXY_TEXTURE_RESOLUTION    = "Texture Resolution",
    PROXY_RAID_TEXTURE_RESOLUTION = "Texture Resolution",
    PROXY_SPELL_DENSITY         = "Spell Density",
    PROXY_RAID_SPELL_DENSITY    = "Spell Density",
    PROXY_PROJECTED_TEXTURES    = "Projected Textures",
    PROXY_RAID_PROJECTED_TEXTURES = "Projected Textures",
}

local function GetRegisteredSetting(variable)
    if Settings and Settings.GetSetting then
        local ok, setting = pcall(Settings.GetSetting, variable)
        if ok and setting then return setting end
    end
    return nil
end

local function IsLiveCVar(variable)
    if not (variable and GetCVar) then return false end
    local ok, value = pcall(GetCVar, variable)
    return ok and value ~= nil
end

local function IsCuratedFallbackSupported(variable)
    -- These are SettingsPanel proxy rows backed by BaseQualityControls
    -- containers, not raw CVars. They are validated by the explicit
    -- supported-proxy catalog above rather than GetCVar.
    if BASE_QUALITY_SETTINGS[variable] then return true end
    return IsLiveCVar(variable)
end

-- Resolve a setting's display name through Blizzard's Settings API. Each
-- registered variable has a Setting object with :GetName() returning the
-- LOCALIZED display string. Falling back to the hardcoded English in
-- SETTINGS_DATA only when the variable isn't registered (some PROXY_*
-- shims or settings removed in newer patches). This gives non-English
-- clients free translations for the ~130 game settings the user can
-- search, without us maintaining locale tables for Blizzard's own labels.
local function GetSettingDisplayName(variable, fallback)
    local setting = GetRegisteredSetting(variable)
    if setting and setting.GetName then
        local nameOk, name = pcall(setting.GetName, setting)
        if nameOk and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return fallback
end

local function CollectCuratedGameEntries(resolveCategoryIDs, useApiNames)
    local entries = {}
    if resolveCategoryIDs then ResolveCategoryIDs() end

    -- If any curated variable resolves, treat the registry as ready
    -- and skip unresolved variables (phantom CVars removed from this
    -- client). If nothing resolved, emit all curated entries; the
    -- 3.0s late re-pass will prune.
    local registryReady = false
    if resolveCategoryIDs then
        for var in pairs(categoryIDByVariable) do
            if var then registryReady = true break end
        end
    end

    for si = 1, #SETTINGS_DATA do
        local row = SETTINGS_DATA[si]
        local var, catName, typeCode = row[1], row[2], row[3]
        local sMin, sMax, sStep = row[4], row[5], row[6]
        local nameSuffix = row[7]
        -- Settings API is the source of truth for display names. The
        -- SETTING_NAME_FALLBACK table only covers the handful of CVar
        -- dropdowns Blizzard hasn't registered as Setting objects; for
        -- those, the English label shows on every locale (Blizzard
        -- doesn't expose a localized one). Variables resolved by the API
        -- pick up the localized name automatically.
        local apiName = useApiNames ~= false and GetSettingDisplayName(var, nil) or nil
        local fallbackName = SETTING_NAME_FALLBACK[var]
        local fallbackSupported = fallbackName and (apiName or IsCuratedFallbackSupported(var))
        local name = apiName or (fallbackSupported and fallbackName)
        if name and name ~= "" then
        if nameSuffix and nameSuffix ~= "" and name:sub(-#nameSuffix) ~= nameSuffix then
            name = name .. nameSuffix
        end
        local nameLower = slower(name)
        local catLower = slower(catName)
        local resolved = TYPE_MAP[typeCode] or "other"
        local sliderInfo = resolved == "slider" and QUALITY_SLIDER_OVERRIDES[var] or nil
        local settingFormatter
        if sliderInfo then
            sMin = sliderInfo.min or sMin
            sMax = sliderInfo.max or sMax
            sStep = sliderInfo.step or sStep
            settingFormatter = sliderInfo.formatter
        end
        local settingOptions = resolved == "dropdown" and CVAR_DROPDOWN_OPTIONS[var] or nil
        local kw = { "setting", "option", "config", catLower, nameLower }
        local extraKw = SETTING_EXTRA_KEYWORDS[var]
        if extraKw then
            for ei = 1, #extraKw do kw[#kw + 1] = extraKw[ei] end
        end
        AddOptionLabelKeywords(kw, settingOptions)
        local resolvedCatID = resolveCategoryIDs and GetCategoryIDForVariable(var) or nil
        if not (registryReady and not resolvedCatID and not BASE_QUALITY_SETTINGS[var]) then
            local catID = resolvedCatID or (resolveCategoryIDs and GetCategoryID(catName)) or nil
            -- Breadcrumb shows the localized category name (resolved from the
            -- category ID); catName stays English as the stable nav key. Add
            -- the localized name as a keyword so it stays searchable too.
            local displayCat = (catID and localizedNameByCategoryID[catID]) or catName
            if displayCat ~= catName then kw[#kw + 1] = slower(displayCat) end
            local mt = GetSettingsCatMT("Game Settings", catName, catID,
                { "Game Settings", displayCat })
            tinsert(entries, setmetatable({
                name = name,
                nameLower = nameLower,
                keywords = kw,
                settingVariable = var,
                settingType = resolved,
                settingMin = sMin,
                settingMax = sMax,
                settingStep = sStep,
                settingFormatter = settingFormatter,
                settingOptions = settingOptions,
                steps = {
                    {
                        settingsCategory = catName,
                        settingCategoryID = catID,
                        settingVariable = var,
                    },
                },
            }, mt))
        end
        end
        MaybeYieldLiveSettings()
    end

    return entries
end

local function AppendEntries(dst, src)
    for i = 1, #src do dst[#dst + 1] = src[i] end
end

local function CollectEntries(includeCurated)
    local entries = {}

    if includeCurated ~= false then
        AppendEntries(entries, CollectCuratedGameEntries(true))
    end

    local list = GetSettingsCategoryList()
    if type(list) ~= "table" then return entries end

    local function addCategoryEntry(cat, parentName)
        if not cat or not cat.GetName then return end
        local catName = cat:GetName()
        local catID = cat.GetID and cat:GetID()
        if not catName or catName == "" then return end
        local catNameLower = slower(catName)
        local kw = { "settings", "options", catNameLower }
        AddKeyword(kw, parentName)
        local pathArr = parentName and { "Game Settings", parentName } or nil
        local mt = GetSettingsCatMT("Game Settings", catName, catID, pathArr)
        tinsert(entries, setmetatable({
            name = catName,
            nameLower = catNameLower,
            keywords = kw,
            steps = { { settingsCategory = catName, settingCategoryID = catID } },
        }, mt))
    end

    for _, cat in ipairs(list) do
        addCategoryEntry(cat)
        MaybeYieldLiveSettings()
        if cat.GetSubcategories then
            local sok, subs = pcall(cat.GetSubcategories, cat)
            if sok and type(subs) == "table" then
                local parentName = cat.GetName and cat:GetName()
                for _, sub in ipairs(subs) do
                    addCategoryEntry(sub, parentName)
                    MaybeYieldLiveSettings()
                end
            end
        end
    end

    return entries
end

-- Per-button action bar keybindings (Action Bar N Button M, Action Button N)
-- are excluded from search: the default UI's hover-to-bind handles those, and
-- they otherwise flood results. The "Action Bar N" toggles are a separate list.
local function IsActionBarButtonBinding(action)
    return action:find("^ACTIONBUTTON%d+$") ~= nil
        or action:find("^MULTIACTIONBAR%d+BUTTON%d+$") ~= nil
        or action:find("^BONUSACTIONBUTTON%d+$") ~= nil
end

-- Localized name lives at _G["BINDING_NAME_"..action]; category at
-- _G["BINDING_HEADER_"..category]. Some clients return the localization key
-- directly (e.g. "BINDING_HEADER_INTERFACE"); others return the bare token
-- ("INTERFACE", "ADDONS") and expect the BINDING_HEADER_ prefix. Try both, and
-- for HEADER_ rows derive the token from the action when no category is given.
local function ResolveBindingHeader(category, action)
    if type(category) == "string" and category ~= "" then
        local v = _G[category]
        if type(v) == "string" and v ~= "" then return v end
        v = _G["BINDING_HEADER_" .. category]
        if type(v) == "string" and v ~= "" then return v end
    end
    if type(action) == "string" and action:find("^HEADER_") then
        local v = _G["BINDING_HEADER_" .. action:sub(8)]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

local function CollectKeybindings()
    local entries = {}

    -- Quick Keybind Mode: a plain click enters the overlay directly. Alt+click
    -- opens Settings > Keybindings and highlights the button (it lives in a
    -- virtualized ScrollBox, so it can't be clicked by frame name).
    do
        local qkbName = _G["QUICK_KEYBIND_MODE"] or "Quick Keybind Mode"
        tinsert(entries, setmetatable({
            name = qkbName,
            nameLower = slower(qkbName),
            keywords = { "quick keybind mode", "quick", "keybind", "binding", "hover bind" },
            quickKeybindActivate = true,
            steps = { { settingsCategory = "Keybindings" } },
        }, GetSettingsCatMT("Game Settings", "Keybindings", nil, { "Game Settings", "Keybindings" })))
    end

    if not GetNumBindings or not GetBinding then return entries end
    local n = GetNumBindings()
    if not n or n == 0 then return entries end

    local currentHeader = "Other"
    for i = 1, n do
        MaybeYieldLiveSettings()
        local action, category = GetBinding(i)
        if action and (action == "HEADER_BLANK" or action:find("^HEADER_")) then
            local resolved = ResolveBindingHeader(category, action)
            if resolved then
                currentHeader = resolved
            elseif type(category) == "string" and category ~= "" then
                currentHeader = category
            end
        elseif action and action ~= "" and not IsActionBarButtonBinding(action) then
            -- Prefer the binding's own category over the positional header.
            -- Addon bindings (and others listed out of header order) trail an
            -- unrelated header in the raw list, so positional tracking would
            -- mis-file them (e.g. a "Yell" addon bind whose category is
            -- ADDONS landing under the preceding Housing header).
            local header = ResolveBindingHeader(category, action) or currentHeader
            local nameKey = "BINDING_NAME_" .. action
            local displayName = _G[nameKey]
            if type(displayName) ~= "string" or displayName == "" then
                displayName = action
            end
            local nameLower = slower(displayName)
            local kw = { "keybind", "binding", "key", nameLower, slower(header) }
            local mt = GetSettingsCatMT("Game Settings", "Keybindings", nil,
                { "Game Settings", "Keybindings", header })
            tinsert(entries, setmetatable({
                name = displayName,
                nameLower = nameLower,
                keywords = kw,
                settingType = "keybind",
                bindingAction = action,
                steps = {
                    {
                        settingsCategory = "Keybindings",
                        bindingAction = action,
                        bindingHeader = header,
                    },
                },
            }, mt))
        end
    end
    return entries
end
BlizzOptionsSearch.CollectKeybindings = CollectKeybindings

local function WalkCategorySettings(cat, catName, catID, pathPrefix, entryCategory)
    entryCategory = entryCategory or "AddOn Settings"
    local catMT = GetSettingsCatMT(entryCategory, catName, catID, pathPrefix)
    local out = {}
    if not (cat and SettingsPanel and SettingsPanel.GetLayout) then
        return out
    end
    local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
    if not lok or not layout or not layout.GetInitializers then return out end
    local iok, inits = pcall(layout.GetInitializers, layout)
    if not iok or not inits then return out end

    -- Combined checkbox+slider initializers (e.g. "Use UI Scale")
    -- bundle two settings under init.data.cbSetting/sliderSetting.
    -- Container initializers (e.g. BaseQualityControls) bundle many
    -- child settings under init.data.settings (and raidSettings) without
    -- exposing per-setting initializers on the layout. The slider/dropdown
    -- choice is baked into the C++ template, not the data, so we tag a
    -- container case and let the caller decide what to emit.
    local function inspectInit(init)
        local d = init.data
        if type(d) == "table" and d.cbSetting and d.sliderSetting then
            return { combined = true, init = init }
        end
        if type(d) == "table" and (d.settings or d.raidSettings) then
            return { container = true, init = init }
        end
        local setting
        if init.GetSetting then
            local sok, s = pcall(init.GetSetting, init)
            if sok then setting = s end
        end
        if not setting and d then setting = d.setting end
        if not setting and init.GetData then
            local dok, dd = pcall(init.GetData, init)
            if dok and dd then setting = dd.setting end
        end
        return { setting = setting, init = init }
    end

    for _, init in ipairs(inits) do
      MaybeYieldLiveSettings()
      local info = inspectInit(init)
      if info.combined then
        local d = init.data
        local cb, sl = d.cbSetting, d.sliderSetting
        local cvok, cvar = pcall(cb.GetVariable, cb)
        local svok, svar = pcall(sl.GetVariable, sl)
        local label = d.cbLabel or d.sliderLabel
        if cvok and svok and cvar and svar and label and label ~= "" then
            local opts = d.sliderOptions
            if type(opts) == "function" then
                local ook, o = pcall(opts, sl)
                if ook then opts = o end
            end
            local sMin, sMax, sStep, sFmt
            if type(opts) == "table" then
                sMin = opts.minValue
                sMax = opts.maxValue
                -- opts.steps = number of steps, not per-tick delta.
                if opts.stepSize then
                    sStep = opts.stepSize
                elseif opts.steps and opts.steps > 0 and sMax > sMin then
                    sStep = (sMax - sMin) / opts.steps
                else
                    sStep = 1
                end
                if type(opts.formatters) == "table" then
                    sFmt = opts.formatters[2] or opts.formatters[1]
                        or opts.formatters[0] or opts.formatters.Top
                        or opts.formatters.Right
                    if type(sFmt) ~= "function" then
                        sFmt = nil
                        for _, fn in pairs(opts.formatters) do
                            if type(fn) == "function" then sFmt = fn; break end
                        end
                    end
                end
            end
            local nameLower = slower(label)
            local kw = { "addon", "setting", "option", nameLower, slower(catName or "") }
            tinsert(out, setmetatable({
                name = label,
                nameLower = nameLower,
                keywords = kw,
                settingVariable = cvar,
                cbVariable = cvar,
                sliderVariable = svar,
                settingType = "checkboxSlider",
                settingMin = sMin,
                settingMax = sMax,
                settingStep = sStep,
                settingFormatter = sFmt,
                steps = {
                    { settingsCategory = catName, settingCategoryID = catID,
                      settingVariable = cvar },
                },
            }, catMT))
        end
      elseif info.container then
        -- Container initializer (BaseQualityControls): the C++ template
        -- decides slider vs dropdown per setting using rules we don't have
        -- access to from Lua. Emit only the variables we know are sliders
        -- (per the QUALITY_SLIDER_OVERRIDES list, verified via /devqs).
        -- The remaining children are dropdowns whose options live in the
        -- C++ template; surfacing them inline would require a separate
        -- per-variable widget catalog. For now leave them to the PROXY_*
        -- dropdown path in CollectGameSettings.
        local d = init.data
        local function emitContainerSlider(setting, isRaid)
            if not (setting and setting.GetVariable and setting.GetName) then return end
            local vok, variable = pcall(setting.GetVariable, setting)
            if not (vok and variable) then return end
            local sliderInfo = QUALITY_SLIDER_OVERRIDES[variable]
            if not sliderInfo then return end
            local nok, settingName = pcall(setting.GetName, setting)
            if not (nok and settingName and settingName ~= "") then return end
            local displayName = settingName
            if isRaid then displayName = settingName .. " (" .. (_G["RAID"] or "Raid") .. ")" end
            local nameLower = slower(displayName)
            local kw = { "setting", "option", "config", nameLower, slower(catName or "") }
            tinsert(out, setmetatable({
                name = displayName,
                nameLower = nameLower,
                keywords = kw,
                settingVariable = variable,
                settingType = "slider",
                settingMin = sliderInfo.min,
                settingMax = sliderInfo.max,
                settingStep = sliderInfo.step,
                settingFormatter = sliderInfo.formatter,
                steps = {
                    { settingsCategory = catName, settingCategoryID = catID,
                      settingVariable = variable },
                },
            }, catMT))
        end
        if d.settings then
            for _, setting in pairs(d.settings) do
                emitContainerSlider(setting, false)
                MaybeYieldLiveSettings()
            end
        end
        if d.raidSettings then
            for _, setting in pairs(d.raidSettings) do
                emitContainerSlider(setting, true)
                MaybeYieldLiveSettings()
            end
        end
      else
        local setting = info.setting
        if setting and setting.GetVariable then
            local vok, variable = pcall(setting.GetVariable, setting)
            local nok, settingName = pcall(setting.GetName, setting)
            if vok and variable and nok and settingName and settingName ~= "" then
                local resolvedType, sMin, sMax, sStep, sFmt
                local d = init.data
                local opts = (type(d) == "table") and d.options or nil
                if type(opts) == "function" then
                    local ook, o = pcall(opts, setting)
                    if not ook then
                        ook, o = pcall(opts)
                    end
                    if ook then opts = o end
                end
                if type(opts) == "table" and opts.minValue and opts.maxValue then
                    resolvedType = "slider"
                    sMin = opts.minValue
                    sMax = opts.maxValue
                    -- opts.steps = number of steps, not per-tick delta.
                if opts.stepSize then
                    sStep = opts.stepSize
                elseif opts.steps and opts.steps > 0 and sMax > sMin then
                    sStep = (sMax - sMin) / opts.steps
                else
                    sStep = 1
                end
                    -- Formatter label keys: Left=0, Right=1, Top=2,
                    -- Min=3, Max=4. Top mirrors the live value best.
                    if type(opts.formatters) == "table" then
                        sFmt = opts.formatters[2] or opts.formatters[1]
                            or opts.formatters[0] or opts.formatters.Top
                            or opts.formatters.Right
                        if type(sFmt) ~= "function" then
                            sFmt = nil
                            for _, fn in pairs(opts.formatters) do
                                if type(fn) == "function" then sFmt = fn; break end
                            end
                        end
                    end
                elseif setting.GetVariableType then
                    local tok, vtype = pcall(setting.GetVariableType, setting)
                    if tok and vtype == "boolean" then
                        resolvedType = "checkbox"
                    end
                end
                if not resolvedType then resolvedType = "dropdown" end

                local settingOptions
                if resolvedType == "dropdown" then
                    settingOptions = GetInitializerOptions(init, setting)
                end

                local nameLower = slower(settingName)
                local kw = {
                    "addon", "setting", "option",
                    nameLower, slower(catName or ""),
                }
                AddOptionLabelKeywords(kw, settingOptions)
                tinsert(out, setmetatable({
                    name = settingName,
                    nameLower = nameLower,
                    keywords = kw,
                    settingVariable = variable,
                    settingType = resolvedType,
                    settingMin = sMin,
                    settingMax = sMax,
                    settingStep = sStep,
                    settingFormatter = sFmt,
                    settingOptions = settingOptions,
                    steps = {
                        {
                            settingsCategory = catName,
                            settingCategoryID = catID,
                            settingVariable = variable,
                        },
                    },
                }, catMT))
            end
        end
      end
    end
    return out
end

local function IsAddonCategory(cat)
    if not cat then return false end
    local addonSet = Settings and Settings.CategorySet and Settings.CategorySet.AddOns
    local set
    if cat.GetCategorySet then
        local ok, s = pcall(cat.GetCategorySet, cat)
        if ok then set = s end
    end
    if set == nil then set = cat.categorySet end
    if set == nil then return false end
    if addonSet ~= nil then return set == addonSet end
    return set == "AddOns" or set == 2
end

local function CollectAddonCategories()
    local entries = {}
    if not Settings then return entries end

    local seenCatIDs = {}
    local function emit(cat, parentName)
        if not cat or not cat.GetName then return end
        if not IsAddonCategory(cat) then return end
        local catID = cat.GetID and cat:GetID()
        if not catID or seenCatIDs[catID] then return end
        seenCatIDs[catID] = true
        local catName = cat:GetName()
        if not catName or catName == "" then return end
        local catNameLower = slower(catName)
        local rootName = (parentName or catName) .. " " .. (_G["SETTINGS"] or "Settings")
        local pathPrefix = parentName and { rootName, catName } or { rootName }

        local kw = { "addon", "settings", "options", catNameLower }
        AddKeyword(kw, parentName)
        local mt = GetSettingsCatMT("AddOn Settings", catName, catID,
            parentName and { rootName } or nil)
        tinsert(entries, setmetatable({
            name = catName,
            nameLower = catNameLower,
            keywords = kw,
            steps = { { settingsCategory = catName, settingCategoryID = catID } },
        }, mt))

        local inline = WalkCategorySettings(cat, catName, catID, pathPrefix, "AddOn Settings")
        for _, e in ipairs(inline) do tinsert(entries, e) end
    end

    local gotTyped = false
    if Settings.CategorySet and Settings.GetCategoryList then
        local ok, list = pcall(Settings.GetCategoryList, Settings.CategorySet.AddOns)
        if ok and type(list) == "table" then
            gotTyped = true
            for _, cat in ipairs(list) do
                emit(cat, nil)
                MaybeYieldLiveSettings()
                if cat.GetSubcategories then
                    local sok, subs = pcall(cat.GetSubcategories, cat)
                    if sok and type(subs) == "table" then
                        local parentName = cat.GetName and cat:GetName()
                        for _, sub in ipairs(subs) do
                            emit(sub, parentName)
                            MaybeYieldLiveSettings()
                        end
                    end
                end
            end
        end
    end

    if not gotTyped and SettingsPanel and SettingsPanel.GetAllCategories then
        local ok, all = pcall(SettingsPanel.GetAllCategories, SettingsPanel)
        if ok and type(all) == "table" then
            for _, cat in ipairs(all) do
                emit(cat, nil)
                MaybeYieldLiveSettings()
                if cat.GetSubcategories then
                    local sok, subs = pcall(cat.GetSubcategories, cat)
                    if sok and type(subs) == "table" then
                        local parentName = cat.GetName and cat:GetName()
                        for _, sub in ipairs(subs) do
                            emit(sub, parentName)
                            MaybeYieldLiveSettings()
                        end
                    end
                end
            end
        end
    end

    return entries
end
BlizzOptionsSearch.CollectAddonCategories = CollectAddonCategories

-- Graphics-quality dropdown options live in private closures
-- (GetShadowQualityOptions etc.). Mirror Blizzard's Graphics.lua.
local function MakeQualityOpts(cvar, raid, optionDefs)
    return { cvar = cvar, raid = raid, optionDefs = optionDefs }
end
local function L(name, fallback)
    local v = _G[name]
    if type(v) == "string" and v ~= "" then return v end
    return fallback
end
local QUALITY_LIKE_5 = {
    { 0, "VIDEO_OPTIONS_LOW", "Low" },
    { 1, "VIDEO_OPTIONS_FAIR", "Fair" },
    { 2, "VIDEO_OPTIONS_MEDIUM", "Medium" },
    { 3, "VIDEO_OPTIONS_HIGH", "High" },
    { 4, "VIDEO_OPTIONS_ULTRA", "Ultra" },
    { 5, "VIDEO_OPTIONS_ULTRA_HIGH", "Ultra High" },
}
local QUALITY_LIKE_4 = {
    { 0, "VIDEO_OPTIONS_LOW", "Low" },
    { 1, "VIDEO_OPTIONS_FAIR", "Fair" },
    { 2, "VIDEO_OPTIONS_MEDIUM", "Medium" },
    { 3, "VIDEO_OPTIONS_HIGH", "High" },
}
local HARDCODED_OPTIONS = {
    PROXY_SHADOW_QUALITY        = MakeQualityOpts("graphicsShadowQuality", false, QUALITY_LIKE_5),
    PROXY_RAID_SHADOW_QUALITY   = MakeQualityOpts("raidGraphicsShadowQuality", true, QUALITY_LIKE_5),
    PROXY_LIQUID_DETAIL         = MakeQualityOpts("graphicsLiquidDetail", false, QUALITY_LIKE_4),
    PROXY_RAID_LIQUID_DETAIL    = MakeQualityOpts("raidGraphicsLiquidDetail", true, QUALITY_LIKE_4),
    PROXY_PARTICLE_DENSITY      = MakeQualityOpts("graphicsParticleDensity", false, QUALITY_LIKE_5),
    PROXY_RAID_PARTICLE_DENSITY = MakeQualityOpts("raidGraphicsParticleDensity", true, QUALITY_LIKE_5),
}

local function BuildQualityOptions(spec)
    if not spec then return nil end
    local out = {}
    for _, def in ipairs(spec.optionDefs) do
        local value, labelGlobal, fallback = def[1], def[2], def[3]
        local supported = true
        if IsGraphicsSettingValueSupported and spec.cvar then
            local ok, err = pcall(IsGraphicsSettingValueSupported, spec.cvar, value, spec.raid)
            if ok then supported = (err == nil or err == 0) end
        end
        if supported then
            tinsert(out, { value = value, label = L(labelGlobal, fallback) })
        end
    end
    if #out == 0 then return nil end
    return out
end

local function CollectGameSettings()
    local entries = {}
    if not Settings then return entries end
    local emittedVars = {}
    if ns.Database and ns.Database.uiSearchData then
        for i = 1, #ns.Database.uiSearchData do
            local e = ns.Database.uiSearchData[i]
            if e and e.settingVariable then
                emittedVars[e.settingVariable] = true
            end
        end
    end
    local seenCatIDs = {}
    -- Track (category, displayName) so a proxy variable iterated later in
    -- the orphan loop doesn't double-emit a row that the container dive
    -- already covered (View Distance slider vs. PROXY_VIEW_DISTANCE).
    local emittedNameKeys = {}
    local function nameKey(catName, displayName)
        return (catName or "") .. "\31" .. (displayName or "")
    end
    -- Pre-populate emittedNameKeys with the API-resolved names for every
    -- curated variable. Otherwise: when a curated entry gets skipped by
    -- the emittedVars check, its NAME never lands in emittedNameKeys, and
    -- a second variable that happens to share that localized display name
    -- (e.g. cameraSmoothStyle vs cameraSmoothTrackingStyle — both resolve
    -- to "Camera Following Style") slips through and duplicates the row.
    for i = 1, #SETTINGS_DATA do
        local row = SETTINGS_DATA[i]
        local var, catName = row[1], row[2]
        if var and catName then
            local apiName = GetSettingDisplayName(var, nil)
                or SETTING_NAME_FALLBACK[var]
            if apiName then
                emittedNameKeys[nameKey(catName, apiName)] = true
            end
        end
        MaybeYieldLiveSettings()
    end
    local function emit(cat, parentName)
        if not cat or not cat.GetName then return end
        if IsAddonCategory(cat) then return end
        local catID = cat.GetID and cat:GetID()
        if not catID or seenCatIDs[catID] then return end
        seenCatIDs[catID] = true
        local catName = cat:GetName()
        if not catName or catName == "" then return end
        local pathPrefix = { "Game Settings", catName }
        local inline = WalkCategorySettings(cat, catName, catID, pathPrefix, "Game Settings")
        for _, e in ipairs(inline) do
            if not emittedVars[e.settingVariable]
               and not emittedNameKeys[nameKey(catName, e.name)] then
                tinsert(entries, e)
                emittedVars[e.settingVariable] = true
                emittedNameKeys[nameKey(catName, e.name)] = true
            end
        end
    end
    local list = GetSettingsCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do
            emit(cat, nil)
            MaybeYieldLiveSettings()
            if cat.GetSubcategories then
                local sok, subs = pcall(cat.GetSubcategories, cat)
                if sok and type(subs) == "table" then
                    local parentName = cat.GetName and cat:GetName()
                    for _, sub in ipairs(subs) do
                        emit(sub, parentName)
                        MaybeYieldLiveSettings()
                    end
                end
            end
        end
    end
    -- Custom container initializers (e.g. BaseQualityControls) hide
    -- their child settings from layout:GetInitializers. Pull them
    -- straight from SettingsPanel.settings as navigation entries.
    if SettingsPanel and SettingsPanel.settings then
        for setting, cat in pairs(SettingsPanel.settings) do
            MaybeYieldLiveSettings()
            if cat and not IsAddonCategory(cat) and setting.GetVariable then
                local vok, variable = pcall(setting.GetVariable, setting)
                if vok and variable and not emittedVars[variable] then
                    local nok, settingName = pcall(setting.GetName, setting)
                    if nok and settingName and settingName ~= "" then
                        -- Base + Raid graphics quality settings share the
                        -- same display name; suffix the raid version.
                        local displayName = settingName
                        local lowerVar = slower(variable)
                        if lowerVar:find("raid", 1, true) then
                            displayName = settingName .. " (" .. (_G["RAID"] or "Raid") .. ")"
                        end
                        local catName = cat.GetName and cat:GetName() or "Game Settings"
                        -- Container dive emitted "View Distance" etc. as
                        -- sliders. Skip the proxy/legacy variant so we don't
                        -- double-list with a broken number widget.
                        if emittedNameKeys[nameKey(catName, displayName)] then
                            emittedVars[variable] = true
                        else
                        local catID = cat.GetID and cat:GetID()
                        local nameLower = slower(displayName)
                        local kw = { "setting", "option", "config", nameLower, slower(catName) }
                        -- Resolve render type: slider override first (graphics
                        -- quality sliders inside BaseQualityControls), then
                        -- hardcoded dropdown, then boolean checkbox, else
                        -- "open the panel on click" fallback.
                        local resolvedType, settingOptions
                        local sMin, sMax, sStep, sFmt
                        local slider = QUALITY_SLIDER_OVERRIDES[variable]
                        if slider then
                            resolvedType = "slider"
                            sMin, sMax, sStep = slider.min, slider.max, slider.step
                            sFmt = slider.formatter
                        else
                            local qspec = HARDCODED_OPTIONS[variable]
                            if qspec then
                                settingOptions = BuildQualityOptions(qspec)
                                if settingOptions then resolvedType = "dropdown" end
                            elseif setting.GetVariableType then
                                local tok, vt = pcall(setting.GetVariableType, setting)
                                if tok and vt == "boolean" then resolvedType = "checkbox" end
                            end
                        end
                        if resolvedType == "dropdown" and not settingOptions then
                            settingOptions = GetOptionsForVariable(variable)
                        end
                        AddOptionLabelKeywords(kw, settingOptions)
                        local mt = GetSettingsCatMT("Game Settings", catName, catID,
                            { "Game Settings", catName })
                        tinsert(entries, setmetatable({
                            name = displayName,
                            nameLower = nameLower,
                            keywords = kw,
                            settingVariable = variable,
                            settingType = resolvedType,
                            settingOptions = settingOptions,
                            settingMin = sMin,
                            settingMax = sMax,
                            settingStep = sStep,
                            settingFormatter = sFmt,
                            steps = {
                                { settingsCategory = catName, settingCategoryID = catID,
                                  settingVariable = variable },
                            },
                        }, mt))
                        emittedVars[variable] = true
                        emittedNameKeys[nameKey(catName, displayName)] = true
                        end
                    end
                end
            end
        end
    end
    return entries
end
BlizzOptionsSearch.CollectGameSettings = CollectGameSettings

local OPTIONS_POPULATE_BUDGET_MS = 1.5
local function RunBudgetedOptionsWork(worker, done)
    if not (SafeAfter and coroutine and coroutine.create and coroutine.resume
            and coroutine.status and coroutine.yield and debugprofilestop) then
        local ok, resultOrErr = xpcall(worker, Utils.ErrorHandler)
        if ok then
            done(resultOrErr)
        else
            done(nil, resultOrErr)
        end
        return
    end

    local co = coroutine.create(worker)
    local finished = false

    local function scheduleStep()
        SafeAfter(0, function()
            if finished then return end
            local ok, err = xpcall(function()
                local startMs = debugprofilestop()
                liveSettingsYield = function()
                    if (debugprofilestop() - startMs) >= OPTIONS_POPULATE_BUDGET_MS then
                        coroutine.yield()
                    end
                end
                local resumeOk, resultOrErr = coroutine.resume(co)
                liveSettingsYield = nil
                if not resumeOk then
                    finished = true
                    done(nil, resultOrErr)
                    return
                end
                if coroutine.status(co) == "dead" then
                    finished = true
                    done(resultOrErr)
                    return
                end
                scheduleStep()
            end, Utils.ErrorHandler)
            liveSettingsYield = nil
            if not ok then
                finished = true
                done(nil, err)
            end
        end)
    end

    scheduleStep()
end

local function CollectGameSettingsAsync(done)
    RunBudgetedOptionsWork(CollectGameSettings, done)
end
BlizzOptionsSearch.CollectGameSettingsAsync = CollectGameSettingsAsync

local registered = false
local fastGameRegistered = false
local coreGameRegistered = false
local liveRegistered = false
local populatePending = false
local livePopulatePending = false
local populateWaiters = {}
local livePopulateWaiters = {}

local function DedupeKey(e)
    return (e.name or "") .. "\31" .. (e.settingsCategory or "")
end

local function NotifyWaiters(waiters, changed)
    for i = 1, #waiters do
        waiters[i](changed)
        waiters[i] = nil
    end
end

local function AddWaiter(waiters, fn)
    if fn then waiters[#waiters + 1] = fn end
end

local function PushOptionEntries(data, entries, kb, addonEntries, gameEntries)
    -- Post-pass dedupe: any Game Settings entry that collides with an
    -- AddOn Settings entry by (name + settingsCategory) is dropped.
    local addonKeys = {}
    local existingVars = {}
    for i = 1, #data do
        local e = data[i]
        if e and e.settingVariable then
            existingVars[e.settingVariable] = i
        end
        if e and e.category == "AddOn Settings" then
            addonKeys[DedupeKey(e)] = true
        end
    end
    for i = 1, #addonEntries do
        local e = addonEntries[i]
        if e.category == "AddOn Settings" then
            addonKeys[DedupeKey(e)] = true
        end
    end
    local changed = false
    local function pushOne(e)
        if e.category == "Game Settings" and addonKeys[DedupeKey(e)] then return end
        local variable = e.settingVariable
        if variable then
            local existingIndex = existingVars[variable]
            if existingIndex then
                data[existingIndex] = e
                changed = true
                return
            end
            existingVars[variable] = #data + 1
        end
        tinsert(data, e)
        changed = true
    end
    local function pushFiltered(src)
        for i = 1, #src do
            pushOne(src[i])
        end
    end

    -- Order matches what search ranking expects: curated -> keybinds ->
    -- addons -> dynamic game.
    pushFiltered(entries)
    pushFiltered(kb)
    for i = 1, #addonEntries do
        tinsert(data, addonEntries[i])
        changed = true
    end
    if gameEntries then pushFiltered(gameEntries) end
    return changed
end

local function PushLiveGameEntries(data, gameEntries)
    local addonKeys = {}
    local seenVars = {}
    local seenNames = {}
    for i = 1, #data do
        local e = data[i]
        if e.category == "AddOn Settings" then
            addonKeys[DedupeKey(e)] = true
        elseif e.category == "Game Settings" then
            if e.settingVariable then seenVars[e.settingVariable] = true end
            seenNames[DedupeKey(e)] = true
        end
    end

    local changed = false
    for i = 1, #gameEntries do
        local e = gameEntries[i]
        local duplicate = (e.settingVariable and seenVars[e.settingVariable])
            or seenNames[DedupeKey(e)]
            or addonKeys[DedupeKey(e)]
        if not duplicate then
            tinsert(data, e)
            if e.settingVariable then seenVars[e.settingVariable] = true end
            seenNames[DedupeKey(e)] = true
            changed = true
        end
    end
    return changed
end

function BlizzOptionsSearch:Populate(includeLiveGameSettings)
    if not ns.Database or not ns.Database.uiSearchData then return end
    local data = ns.Database.uiSearchData

    local entries = CollectEntries(not coreGameRegistered)
    local kb = CollectKeybindings()
    local addonEntries = CollectAddonCategories()
    local gameEntries = includeLiveGameSettings and CollectGameSettings() or nil

    local changed = PushOptionEntries(data, entries, kb, addonEntries, gameEntries)

    if changed and ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
end

function BlizzOptionsSearch:PopulateLight()
    self:Populate(false)
end

function BlizzOptionsSearch:EnsureFastGameOptions()
    if fastGameRegistered then return false end
    if registered then return false end
    if not (ns.Database and ns.Database.uiSearchData) then return false end
    local ok, entries = xpcall(CollectCuratedGameEntries, Utils.ErrorHandler, false, true)
    if not ok or type(entries) ~= "table" or #entries == 0 then return false end
    fastGameRegistered = true
    local changed = PushOptionEntries(ns.Database.uiSearchData, entries, {}, {}, nil)
    if changed and ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
    return changed
end

function BlizzOptionsSearch:HandleStep(step)
    if not step then return false end

    -- Prefer the cached id; live lookup is fallback for old saves.
    local catID = step.settingCategoryID
    if not catID and step.settingVariable then
        catID = GetCategoryIDForVariable(step.settingVariable)
    end
    if not catID and step.settingsCategory then
        catID = GetCategoryID(step.settingsCategory)
    end

    ShowSettings()

    if catID and Settings and Settings.OpenToCategory then
        if step.settingVariable then
            pcall(Settings.OpenToCategory, catID, step.settingVariable)
        else
            pcall(Settings.OpenToCategory, catID)
        end
    end

    -- Settings.OpenToCategory ignores the second arg in many builds, and
    -- even when it doesn't, the SettingsList's ScrollBox data provider
    -- isn't repopulated for the new category until a frame or two later.
    -- A single SafeAfter(0) retry hits the OLD category's data provider
    -- and finds nothing. Retry across a few frames so the scroll fires as
    -- soon as the new data provider lands (mirrors how
    -- ClickAchievementCategory explicitly refreshes its data provider
    -- before searching, except here we have no public refresh hook so we
    -- poll instead).
    -- Retry chain stops as soon as one attempt succeeds. Without the
    -- shared `done` flag, every retry re-scrolls a freshly-populated
    -- data provider, fighting itself and producing a visible spazz
    -- before settling.
    if step.settingVariable then
        local variable = step.settingVariable
        local done = false
        local function tryScroll()
            if done then return end
            if ScrollToSettingVariable(variable) then done = true end
        end
        for _, delay in ipairs({ 0, 0.05, 0.15, 0.3, 0.6 }) do
            SafeAfter(delay, tryScroll)
        end
    elseif step.bindingAction then
        local action, header = step.bindingAction, step.bindingHeader
        local done = false
        local function tryBinding()
            if done then return end
            if ScrollToBindingAction(action, header) then done = true end
        end
        for _, delay in ipairs({ 0, 0.05, 0.15, 0.3, 0.6 }) do
            SafeAfter(delay, tryBinding)
        end
    end

    return catID ~= nil
end

local lateRefreshScheduled = false
local function RefreshLateAddonCategories()
    if not (ns.Database and ns.Database.uiSearchData) then return end
    -- Re-collect to pick up addons that register categories late.
    local seen = {}
    for _, e in ipairs(ns.Database.uiSearchData or {}) do
        if e.settingsCategory and not e.settingVariable then
            seen[e.settingsCategory] = true
        end
    end
    ResolveCategoryIDs()
    local fresh = CollectEntries(false)
    for _, e in ipairs(fresh) do
        -- Skip per-variable entries already injected in pass 1.
        if not e.settingVariable and not seen[e.settingsCategory] then
            tinsert(ns.Database.uiSearchData, e)
        end
    end
    if ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
end

local function ScheduleLateRefresh()
    if lateRefreshScheduled then return end
    lateRefreshScheduled = true
    SafeAfter(3.0, RefreshLateAddonCategories)
end

local function Register()
    if registered then return end
    if not (ns.Database and ns.Database.uiSearchData) then return end
    BlizzOptionsSearch:PopulateLight()
    registered = true
    ScheduleLateRefresh()
end

function BlizzOptionsSearch:EnsureCoreGameOptions()
    if coreGameRegistered or registered then return false end
    if not (ns.Database and ns.Database.uiSearchData) then return false end
    local changed = self:EnsureFastGameOptions()
    coreGameRegistered = true
    return changed
end

function BlizzOptionsSearch:EnsurePopulated()
    Register()
end

function BlizzOptionsSearch:EnsurePopulatedAsync(onDone)
    if registered then
        if onDone then onDone(false) end
        return false
    end
    AddWaiter(populateWaiters, onDone)
    if populatePending then return true end
    populatePending = true

    local function finish(ok)
        populatePending = false
        if ok then
            registered = true
            ScheduleLateRefresh()
        end
        NotifyWaiters(populateWaiters, ok and registered)
    end

    local function run()
        if not (ns.Database and ns.Database.uiSearchData) then
            finish(false)
            return
        end
        RunBudgetedOptionsWork(function()
            BlizzOptionsSearch:PopulateLight()
            return true
        end, finish)
    end

    if SafeAfter then
        SafeAfter(0, run)
    else
        run()
    end
    return true
end

function BlizzOptionsSearch:EnsureLivePopulatedAsync(onDone)
    if liveRegistered then
        if onDone then onDone(false) end
        return false
    end
    AddWaiter(livePopulateWaiters, onDone)
    if livePopulatePending then return true end
    livePopulatePending = true

    local function finish(ok, changed)
        livePopulatePending = false
        NotifyWaiters(livePopulateWaiters, ok and changed)
    end

    local function startLivePopulate()
        local ok = xpcall(function()
            if not registered then Register() end
        end, Utils.ErrorHandler)
        if not ok then
            finish(false, false)
            return
        end
        if not (ns.Database and ns.Database.uiSearchData) then
            finish(false, false)
            return
        end

        CollectGameSettingsAsync(function(gameEntries)
            if not gameEntries then
                finish(false, false)
                return
            end
            local okPush, changed = xpcall(function()
                return PushLiveGameEntries(ns.Database.uiSearchData, gameEntries)
            end, Utils.ErrorHandler)
            if not okPush then
                finish(false, false)
                return
            end
            liveRegistered = true
            if changed and ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
            finish(true, changed)
        end)
    end

    local function run()
        if populatePending and not registered then
            AddWaiter(populateWaiters, function()
                if registered then
                    startLivePopulate()
                else
                    finish(false, false)
                end
            end)
            return
        end
        startLivePopulate()
    end

    if SafeAfter then
        SafeAfter(0, run)
    else
        run()
    end
    return true
end
