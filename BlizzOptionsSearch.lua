-- Blizzard Settings panel search. Walks the live SettingsPanel
-- category tree (top-level categories AND subcategories) at register
-- time, caches each category id by name and by setting variable, then
-- registers searchable entries pointing at the cached id. Click =
-- ShowUIPanel(SettingsPanel) followed by Settings.OpenToCategory.

local _, ns = ...
local BlizzOptionsSearch = {}
ns.BlizzOptionsSearch = BlizzOptionsSearch

local Utils = ns.Utils
local tinsert = Utils.tinsert
local slower = Utils.slower
local SafeAfter = Utils.SafeAfter
local pcall = pcall

-- Modern WoW exposes the categories via SettingsPanel:GetAllCategories.
-- The legacy Settings.GetCategoryList was removed in Midnight (12.0),
-- so callers that walked it returned nil and silently failed.
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

-- Curated list of individual settings for direct search.
-- Format: { display name, CVar/variable, category name, type code, [min, max, step] }
-- type: c=checkbox, d=dropdown, s=slider
-- For sliders, min/max/step let the inline slider widget render
-- correctly. Step is the value increment per slider position.
local SETTINGS_DATA = {
    -- Controls
    {"Sticky Targeting","deselectOnClick","Controls","c"},
    {"Auto Dismount in Flight","autoDismountFlying","Controls","c"},
    {"Auto Clear AFK","autoClearAFK","Controls","c"},
    {"Interact On Left Click","interactOnLeftClick","Controls","c"},
    {"Open Loot Window at Mouse","lootUnderMouse","Controls","c"},
    {"Auto Loot","autoLootDefault","Controls","c"},
    {"Auto Loot Key","AUTOLOOTTOGGLE","Controls","d"},
    {"Enable Interact Key","PROXY_ENABLE_INTERACT","Controls","c"},
    {"Interact Key Sound Cue","softTargettingInteractKeySound","Controls","c"},
    {"Lock Cursor to Window","ClipCursor","Controls","c"},
    {"Invert Mouse","mouseInvertPitch","Controls","c"},
    {"Mouse Look Speed","PROXY_MOUSE_LOOK_SPEED","Controls","s",90,270,18},
    {"Water Collision","cameraWaterCollision","Controls","c"},
    {"Auto Follow Speed","PROXY_CAMERA_SPEED","Controls","s",90,270,18},
    {"Camera Following Style","cameraSmoothStyle","Controls","d"},
    {"Max Camera Distance","cameraDistanceMaxZoomFactor","Controls","s",1,2,0.1},
    {"Follow Terrain","cameraTerrainTilt","Controls","c"},
    {"Head Bob","cameraBobbing","Controls","c"},
    {"Smart Pivot","cameraPivot","Controls","c"},
    -- Interface
    {"My Name","UnitNameOwn","Interface","c"},
    {"NPC Names","PROXY_NPC_NAMES","Interface","d"},
    {"Critters and Companions","UnitNameNonCombatCreatureName","Interface","c"},
    {"Friendly Players","UnitNameFriendlyPlayerName","Interface","c"},
    {"Friendly Minions","UnitNameFriendlyMinionName","Interface","c"},
    {"Enemy Players","UnitNameEnemyPlayerName","Interface","c"},
    {"Enemy Minions","UnitNameEnemyMinionName","Interface","c"},
    {"Always Show Nameplates","nameplateShowAll","Interface","c"},
    {"Enemy Unit Nameplates","nameplateShowEnemies","Interface","c"},
    {"Enemy Minion Nameplates","nameplateShowEnemyMinions","Interface","c"},
    {"Minor Enemy Nameplates","nameplateShowEnemyMinus","Interface","c"},
    {"Friendly Player Nameplates","nameplateShowFriends","Interface","c"},
    {"Friendly Minion Nameplates","nameplateShowFriendlyMinions","Interface","c"},
    {"Nameplate Motion Type","nameplateMotion","Interface","d"},
    {"Nameplate Distance","nameplateMaxDistance","Interface","s",20,41,1},
    {"Nameplate Cast Bars","nameplateShowCastBars","Interface","c"},
    {"Tutorials","showTutorials","Interface","c"},
    {"Status Text","PROXY_STATUS_TEXT","Interface","d"},
    {"Chat Bubbles","PROXY_CHAT_BUBBLES","Interface","d"},
    {"Show Helm","PROXY_SHOW_HELM","Interface","c"},
    {"Show Cloak","PROXY_SHOW_CLOAK","Interface","c"},
    {"Instant Quest Text","instantQuestText","Interface","c"},
    {"Automatic Quest Tracking","autoQuestWatch","Interface","c"},
    {"Show Free Bag Space","displayFreeBagSlots","Interface","c"},
    {"Consolidate Buffs","consolidateBuffs","Interface","c"},
    {"Hide Zone Objective Tracker","hideOutdoorWorldState","Interface","c"},
    {"Show Minimap Clock","showMinimapClock","Interface","c"},
    {"Beginner Tooltips","showNewbieTips","Interface","c"},
    {"Loading Screen Tips","showLoadingScreenTips","Interface","c"},
    {"Show Enemy Cast Bar","showTargetCastbar","Interface","c"},
    {"Dynamic Buff and Debuff Size","showDynamicBuffSize","Interface","c"},
    {"Incoming Heals for Unit Frames","unitFramesDisplayIncomingHeals","Interface","c"},
    {"Classic Guild UI","useClassicGuildUI","Interface","c"},
    {"Display Power Bars","raidFramesDisplayPowerBars","Interface","c"},
    {"Display Only Healer Power Bars","raidFramesDisplayOnlyHealerPowerBars","Interface","c"},
    {"Display Class Colors","raidFramesDisplayClassColor","Interface","c"},
    {"Display Pets","raidOptionDisplayPets","Interface","c"},
    {"Display Main Tank and Assist","raidOptionDisplayMainTankAndAssist","Interface","c"},
    {"Show Debuffs","raidFramesDisplayDebuffs","Interface","c"},
    {"Display Only Dispellable Debuffs","raidFramesDisplayOnlyDispellableDebuffs","Interface","c"},
    {"Display Health Text","raidFramesHealthText","Interface","d"},
    -- Action Bars
    {"Action Bar 2","PROXY_SHOW_ACTIONBAR_2","Action Bars","c"},
    {"Action Bar 3","PROXY_SHOW_ACTIONBAR_3","Action Bars","c"},
    {"Action Bar 4","PROXY_SHOW_ACTIONBAR_4","Action Bars","c"},
    {"Action Bar 5","PROXY_SHOW_ACTIONBAR_5","Action Bars","c"},
    {"Action Bar 6","PROXY_SHOW_ACTIONBAR_6","Action Bars","c"},
    {"Action Bar 7","PROXY_SHOW_ACTIONBAR_7","Action Bars","c"},
    {"Action Bar 8","PROXY_SHOW_ACTIONBAR_8","Action Bars","c"},
    {"Show Numbers for Cooldowns","countdownForCooldowns","Action Bars","c"},
    -- Combat
    {"Raid Self Highlight","PROXY_SELF_HIGHLIGHT","Combat","d"},
    {"Target of Target","showTargetOfTarget","Combat","c"},
    {"Do Not Flash Screen at Low Health","doNotFlashLowHealthWarning","Combat","c"},
    {"Loss of Control Alerts","lossOfControl","Combat","c"},
    {"Enable Floating Combat Text","enableFloatingCombatText","Combat","c"},
    {"Combat Text Float Mode","floatingCombatTextFloatMode","Combat","d"},
    {"Low Mana & Health","floatingCombatTextLowManaHealth","Combat","c"},
    {"Auras","floatingCombatTextAuras","Combat","c"},
    {"Fading Auras","floatingCombatTextAuraFade","Combat","c"},
    {"Combat State","floatingCombatTextCombatState","Combat","c"},
    {"Dodges/Parries/Misses","floatingCombatTextDodgeParryMiss","Combat","c"},
    {"Damage Reduction","floatingCombatTextDamageReduction","Combat","c"},
    {"Reputation Changes","floatingCombatTextRepChanges","Combat","c"},
    {"Reactive Spells & Abilities","floatingCombatTextReactives","Combat","c"},
    {"Friendly Healer Names","floatingCombatTextFriendlyHealers","Combat","c"},
    {"Combo Points","floatingCombatTextComboPoints","Combat","c"},
    {"Energy Gains","floatingCombatTextEnergyGains","Combat","c"},
    {"Honor Gained","floatingCombatTextHonorGains","Combat","c"},
    {"Self Cast","PROXY_SELF_CAST","Combat","d"},
    {"Self Cast Key","SELFCAST","Combat","d"},
    {"Focus Cast Key","FOCUSCAST","Combat","d"},
    {"Enable Action Targeting","PROXY_ACTION_TARGETING","Combat","c"},
    {"Target Damage","floatingCombatTextCombatDamage","Combat","c"},
    {"Periodic Damage","floatingCombatTextCombatLogPeriodicSpells","Combat","c"},
    {"Pet Damage","floatingCombatTextPetMeleeDamage","Combat","c"},
    {"Healing","floatingCombatTextCombatHealing","Combat","c"},
    {"Auto Attack/Auto Shot","autoRangedCombat","Combat","c"},
    -- Social
    {"Disable Chat","PROXY_DISABLE_CHAT","Social","c"},
    {"Mature Language Filter","profanityFilter","Social","c"},
    {"Guild Member Alert","guildMemberNotify","Social","c"},
    {"Block Trades","blockTrades","Social","c"},
    {"Block Guild Invites","PROXY_BLOCK_GUILD_INVITES","Social","c"},
    {"Restrict Calendar Invites","restrictCalendarInvites","Social","c"},
    {"Block Chat Channel Invites","blockChannelInvites","Social","c"},
    {"Online Friends","showToastOnline","Social","c"},
    {"Offline Friends","showToastOffline","Social","c"},
    {"Broadcast Updates","showToastBroadcast","Social","c"},
    {"Real ID and BattleTag Friend Requests","showToastFriendRequest","Social","c"},
    {"Show Toast Window","showToastWindow","Social","c"},
    {"Chat Style","chatStyle","Social","d"},
    {"New Whispers","whisperMode","Social","d"},
    {"Chat Timestamps","showTimestamps","Social","d"},
    -- Keybindings
    {"Character Specific Key Bindings","PROXY_CHARACTER_SPECIFIC_BINDINGS","Keybindings","c"},
    -- General / Accessibility
    {"Show Move Pad","enableMovePad","General","c"},
    {"Minimum Character Name Size","PROXY_MINIMUM_CHARACTER_NAME_SIZE","General","s",0,64,2},
    {"Motion Sickness","PROXY_SICKNESS","General","c"},
    {"Camera Shake","PROXY_SICKNESS_SHAKE","General","d"},
    {"Cursor Size","cursorSizePreferred","General","d"},
    {"Show Target Tooltip","PROXY_TARGET_TOOLTIP","General","c"},
    {"Interact Key Icons","PROXY_INTERACT_ICONS","General","d"},
    -- Colorblind Mode
    {"Enable UI Colorblind Mode","colorblindMode","Colorblind Mode","c"},
    {"Colorblind Filter","colorblindSimulator","Colorblind Mode","d"},
    {"Colorblind Strength","colorblindWeaknessFactor","Colorblind Mode","s",0,1,0.05},
    -- Subtitles
    {"Cinematic Subtitles","movieSubtitle","Subtitles","c"},
    {"Subtitles Background","PROXY_MOVIE_SUBTITLE_BACKGROUND","Subtitles","d"},
    -- Graphics
    {"Monitor","PROXY_PRIMARY_MONITOR","Graphics","d"},
    {"Display Mode","PROXY_DISPLAY_MODE","Graphics","d"},
    {"Window Size","PROXY_RESOLUTION","Graphics","d"},
    {"Render Scale","PROXY_RESOLUTION_RENDER_SCALE","Graphics","s",0.333,2,0.05},
    {"Vertical Sync","PROXY_VERTICAL_SYNC","Graphics","d"},
    {"Low Latency Mode","LowLatencyMode","Graphics","d"},
    {"Anti-Aliasing","PROXY_ANTIALIASING","Graphics","d"},
    {"Image-Based Techniques","PROXY_FXAA","Graphics","d"},
    {"Multisample Techniques","PROXY_MSAA","Graphics","d"},
    {"Multisample Alpha-Test","PROXY_MSAA_ALPHA","Graphics","c"},
    {"Camera FOV","PROXY_CAMERA_FOV","Graphics","s"},
    {"Triple Buffering","PROXY_TRIPLE_BUFFERING","Graphics","c"},
    {"Texture Filtering","textureFilteringMode","Graphics","d"},
    {"Ray Traced Shadows","shadowrt","Graphics","d"},
    {"Resample Quality","ResampleQuality","Graphics","d"},
    {"VRS Mode","vrsValar","Graphics","d"},
    {"Graphics API","PROXY_GRAPHICS_API","Graphics","d"},
    {"Resample Sharpness","PROXY_RESAMPLE_SHARPNESS","Graphics","s"},
    {"Contrast","Contrast","Graphics","s"},
    {"Brightness","Brightness","Graphics","s"},
    {"Gamma","Gamma","Graphics","s"},
    {"Optional GPU Features","PROXY_OPT_GPU_FEATURES","Graphics","c"},
    {"Async Resource Creation","PROXY_DEVICE_MT","Graphics","c"},
    {"Multithreaded Rendering","PROXY_CMDLIST_MT","Graphics","c"},
    {"Advanced Work Submit","PROXY_ADV_WORK_SUBMIT","Graphics","c"},
    -- Audio
    {"Enable Sound","Sound_EnableAllSound","Audio","c"},
    {"Master Volume","Sound_MasterVolume","Audio","s"},
    {"Music Volume","Sound_MusicVolume","Audio","s"},
    {"Effects Volume","Sound_SFXVolume","Audio","s"},
    {"Ambience Volume","Sound_AmbienceVolume","Audio","s"},
    {"Dialog Volume","Sound_DialogVolume","Audio","s"},
    {"Enable Music","Sound_EnableMusic","Audio","c"},
    {"Loop Music","Sound_ZoneMusicNoDelay","Audio","c"},
    {"Pet Battle Music","Sound_EnablePetBattleMusic","Audio","c"},
    {"Sound Effects","Sound_EnableSFX","Audio","c"},
    {"Enable Pet Sounds","Sound_EnablePetSounds","Audio","c"},
    {"Emote Sounds","Sound_EnableEmoteSounds","Audio","c"},
    {"Enable Dialog","Sound_EnableDialog","Audio","c"},
    {"Error Speech","Sound_EnableErrorSpeech","Audio","c"},
    {"Ambient Sounds","Sound_EnableAmbience","Audio","c"},
    {"Sound in Background","Sound_EnableSoundWhenGameIsInBG","Audio","c"},
    {"Enable Reverb","Sound_EnableReverb","Audio","c"},
    {"Distance Filtering","Sound_EnablePositionalLowPassFilter","Audio","c"},
    -- Network
    {"Optimize Network for Speed","disableServerNagle","Network","c"},
    {"Enable IPv6 when available","useIPv6","Network","c"},
    {"Advanced Combat Logging","advancedCombatLogging","Network","c"},
}

local TYPE_MAP = { c = "checkbox", d = "dropdown", s = "slider" }

-- Hardcoded option lists for CVar-based dropdowns the live SettingsPanel
-- can't enumerate (these aren't registered as Setting objects, so
-- GetOptionsForVariable's layout walk returns nil). Listed in the order
-- the in-game dropdown shows them so the inline picker reads naturally.
-- Each entry: { value, label }. Hardware-specific dropdowns (monitors,
-- sound devices, GPUs, resolutions) are intentionally omitted -- their
-- options are machine-dependent and can't be hardcoded sensibly.
local CVAR_DROPDOWN_OPTIONS = {
    AUTOLOOTTOGGLE = {
        { value = "NONE",  label = "None" },
        { value = "ALT",   label = "ALT key" },
        { value = "CTRL",  label = "CTRL key" },
        { value = "SHIFT", label = "SHIFT key" },
    },
    PROXY_NPC_NAMES = {
        { value = "1", label = "Quest NPCs" },
        { value = "2", label = "Hostile NPCs" },
        { value = "3", label = "Hostile and Interactive NPCs" },
        { value = "4", label = "All NPCs" },
        { value = "5", label = "None" },
    },
    nameplateMotion = {
        { value = "0", label = "Overlapping Nameplates" },
        { value = "1", label = "Stacking Nameplates" },
    },
    PROXY_STATUS_TEXT = {
        { value = "1", label = "Numeric Value" },
        { value = "2", label = "Percentage" },
        { value = "3", label = "Both" },
        { value = "4", label = "None" },
    },
    PROXY_CHAT_BUBBLES = {
        { value = "1", label = "All" },
        { value = "2", label = "None" },
        { value = "3", label = "Exclude party chat" },
    },
    raidFramesHealthText = {
        { value = "none",       label = "None" },
        { value = "health",     label = "Health Remaining" },
        { value = "losthealth", label = "Health Lost" },
        { value = "perc",       label = "Health Percentage" },
    },
    PROXY_SELF_HIGHLIGHT = {
        { value = "0", label = "Off" },
        { value = "1", label = "Circle" },
        { value = "2", label = "Icon" },
        { value = "3", label = "Circle and Icon" },
    },
    floatingCombatTextFloatMode = {
        { value = "1", label = "Scroll Up" },
        { value = "2", label = "Scroll Down" },
        { value = "3", label = "Arc" },
    },
    PROXY_SELF_CAST = {
        { value = "1", label = "None" },
        { value = "2", label = "Auto" },
        { value = "3", label = "Key Press" },
        { value = "4", label = "Auto and Key Press" },
    },
    SELFCAST = {
        { value = "ALT",   label = "ALT key" },
        { value = "CTRL",  label = "CTRL key" },
        { value = "SHIFT", label = "SHIFT key" },
    },
    FOCUSCAST = {
        { value = "NONE",  label = "None" },
        { value = "ALT",   label = "ALT key" },
        { value = "CTRL",  label = "CTRL key" },
        { value = "SHIFT", label = "SHIFT key" },
    },
    chatStyle = {
        { value = "classic", label = "Classic Style" },
        { value = "im",      label = "IM Style" },
    },
    whisperMode = {
        { value = "inline",            label = "In-line" },
        { value = "popout",            label = "New Tab" },
        { value = "popout_and_inline", label = "Both" },
    },
    showTimestamps = {
        { value = "none",          label = "None" },
        { value = "%H:%M ",        label = "15:27" },
        { value = "%I:%M ",        label = "03:27" },
        { value = "%H:%M:%S ",     label = "15:27:32" },
        { value = "%I:%M %p ",     label = "03:27 PM" },
        { value = "%I:%M:%S ",     label = "03:27:32" },
        { value = "%I:%M:%S %p ",  label = "03:27:32 PM" },
    },
    PROXY_SICKNESS_SHAKE = {
        { value = "1", label = "None" },
        { value = "2", label = "Full" },
        { value = "3", label = "Reduced" },
    },
    cursorSizePreferred = {
        { value = "-1", label = "Default" },
        { value = "0",  label = "32x32" },
        { value = "1",  label = "48x48" },
        { value = "2",  label = "64x64" },
        { value = "3",  label = "96x96" },
        { value = "4",  label = "128x128" },
    },
    PROXY_INTERACT_ICONS = {
        { value = "1", label = "NPCs Only" },
        { value = "2", label = "Show All" },
        { value = "3", label = "Show None" },
    },
    colorblindSimulator = {
        { value = "0", label = "None" },
        { value = "1", label = "Protanopia" },
        { value = "2", label = "Deuteranopia" },
        { value = "3", label = "Tritanopia" },
    },
    PROXY_MOVIE_SUBTITLE_BACKGROUND = {
        { value = "1", label = "None" },
        { value = "2", label = "Dark" },
        { value = "3", label = "Light" },
    },
    LowLatencyMode = {
        { value = "0", label = "Disabled" },
        { value = "1", label = "Built-in" },
        { value = "2", label = "NVIDIA Reflex" },
        { value = "3", label = "NVIDIA Reflex + Boost" },
        { value = "4", label = "Intel XeLL" },
    },
    PROXY_ANTIALIASING = {
        { value = "0", label = "None" },
        { value = "1", label = "Image-Based" },
        { value = "2", label = "Multisample" },
        { value = "3", label = "Advanced" },
    },
    PROXY_FXAA = {
        { value = "0", label = "None" },
        { value = "1", label = "FXAA Low" },
        { value = "2", label = "FXAA High" },
        { value = "3", label = "CMAA" },
    },
    PROXY_MSAA = {
        { value = "0", label = "None" },
        { value = "1", label = "2x" },
        { value = "2", label = "4x" },
        { value = "3", label = "8x" },
    },
    textureFilteringMode = {
        { value = "0", label = "Bilinear" },
        { value = "1", label = "Trilinear" },
        { value = "2", label = "2x Anisotropic" },
        { value = "3", label = "4x Anisotropic" },
        { value = "4", label = "8x Anisotropic" },
        { value = "5", label = "16x Anisotropic" },
    },
    shadowrt = {
        { value = "0", label = "Disabled" },
        { value = "1", label = "Fair" },
        { value = "2", label = "Good" },
        { value = "3", label = "High" },
    },
    ResampleQuality = {
        { value = "0", label = "Point" },
        { value = "1", label = "Bilinear" },
        { value = "2", label = "Bicubic" },
        { value = "3", label = "FidelityFX Super Resolution" },
    },
    vrsValar = {
        { value = "0", label = "Disabled" },
        { value = "1", label = "Standard" },
        { value = "2", label = "Aggressive" },
    },
    cameraSmoothStyle = {
        { value = "0", label = "Never" },
        { value = "1", label = "Smart" },
        { value = "2", label = "Always" },
        { value = "4", label = "Only when moving" },
    },
    PROXY_GRAPHICS_API = {
        { value = "d3d11", label = "DirectX 11" },
        { value = "d3d12", label = "DirectX 12" },
    },
}

-- Resolved tables, populated once at register time.
-- categoryIDByName[lowercaseName] = catID
-- categoryIDByVariable[variable] = catID (variable -> owning category)
local categoryIDByName = {}
local categoryIDByVariable = {}

-- Tooltip cache per variable. Filled lazily from three sources in
-- order of preference: the live SettingsPanel initializer's tooltip,
-- the Setting object's GetTooltip(), and OPTION_TOOLTIP_* globals.
local settingTooltips = {}

-- Resolve a Blizzard OPTION_TOOLTIP_* global. Tries display name and
-- CVar name, both converted to SCREAMING_SNAKE_CASE. PROXY_ vars
-- never have tooltip globals, so skip them.
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

-- Look up cached tooltip; if nothing cached yet, try the live
-- SettingsPanel initializer for this variable. Falls back to nil
-- (caller should have its own fallback like the display name).
local function GetTooltipForVariable(variable, displayName)
    if not variable then return nil end
    local cached = settingTooltips[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    -- Try Setting:GetTooltip() first
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

    -- Try the OPTION_TOOLTIP_* global
    local fromGlobal = ResolveTooltipGlobal(displayName, variable)
    if fromGlobal then
        settingTooltips[variable] = fromGlobal
        return fromGlobal
    end

    -- Cache "no tooltip" so we don't re-walk on every hover
    settingTooltips[variable] = false
    return nil
end
BlizzOptionsSearch.GetTooltipForVariable = GetTooltipForVariable

-- Resolve dropdown options for `variable` at click time by scanning
-- live SettingsPanel layouts. Returns a normalized array of
-- { value, label } or nil if the variable isn't a dropdown / can't be
-- enumerated. Cached per variable since layouts don't change after
-- registration. False sentinel = "we looked, none available".
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

local function GetOptionsForVariable(variable)
    if not variable then return nil end
    local cached = optionsByVariable[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    -- CVar dropdowns (AUTOLOOTTOGGLE, raidFramesHealthText, etc.) aren't
    -- registered as Setting objects, so the SettingsPanel walker below
    -- never finds them. Hardcoded list catches them first.
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
                    local setting
                    if init.GetSetting then
                        local sok, s = pcall(init.GetSetting, init)
                        if sok then setting = s end
                    end
                    if not setting and init.data then setting = init.data.setting end
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

-- Pull the slider's display formatter from the live registry so curated
-- SETTINGS_DATA entries (Mouse Look Speed, Camera Distance, etc.) show
-- the same value Blizzard's panel does instead of the raw CVar number
-- (e.g., PROXY_MOUSE_LOOK_SPEED raw 180 -> displayed "5.5").
local formatterByVariable = {}
local function PickFormatter(formatters)
    if type(formatters) ~= "table" then return nil end
    -- MinimalSliderWithSteppersMixin.Label = MakeEnum("Left","Right","Top","Min","Max")
    -- Top (2) mirrors the live value above the thumb best.
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
                    local setting
                    if init.GetSetting then
                        local sok, s = pcall(init.GetSetting, init)
                        if sok then setting = s end
                    end
                    if not setting and init.data then setting = init.data.setting end
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

-- Pending-apply tracking. Settings with CommitFlag.Apply (graphics
-- options, resolution, etc.) stage their value into setting.pendingValue
-- instead of writing through, so we mirror Blizzard's bottom-bar UX:
-- accumulate pending changes and let the user Apply / Revert as a batch.
local pendingApplySettings = {}
local pendingChangeCallbacks = {}

local function PendingCount()
    -- Prune entries whose pendingValue cleared out from under us (user
    -- opened Blizzard's panel and Applied / Cancelled there directly).
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

-- Called by the inline editor right after Setting:SetValue. If the
-- setting has the Apply commit flag, the new value is staged in
-- setting.pendingValue and needs the user to commit; otherwise the
-- value is already live and we drop the entry.
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
        -- Setting reverted to original via repeat-edit: drop it.
        pendingApplySettings[settObj] = nil
        FirePendingChanged()
    end
end

-- Find the StaticPopup slot currently displaying the named popup.
-- Blizzard reuses StaticPopup1..4 across all popups; when one is busy
-- (e.g., our unapplied-changes popup), the next StaticPopup_Show lands
-- in a different slot. Walk all slots to find the one we want.
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
        if ns.UI and ns.UI.RefreshResults then ns.UI:RefreshResults() end
    end)
end

-- Apply all pending changes at once. Push them into SettingsPanel.modified
-- and run its CommitSettings(false) so Blizzard's full pipeline fires:
-- gx restart / window update / save bindings AND the
-- GAME_SETTINGS_TIMED_CONFIRMATION popup for any Revertable settings
-- in the batch (monitor, resolution, etc.).
function BlizzOptionsSearch:ApplyPendingChanges()
    if not next(pendingApplySettings) then return end
    if SettingsPanel and SettingsPanel.modified and SettingsPanel.CommitSettings then
        for setting in pairs(pendingApplySettings) do
            SettingsPanel.modified[setting] = setting
        end
        pcall(SettingsPanel.CommitSettings, SettingsPanel, false)
        LiftPopupAndRefresh(FindStaticPopupSlot("GAME_SETTINGS_TIMED_CONFIRMATION"))
    end
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

-- True when a single variable has a staged-but-not-applied change.
function BlizzOptionsSearch:HasPendingChange(variable)
    if not variable or not Settings or not Settings.GetSetting then return false end
    local sok, settObj = pcall(Settings.GetSetting, variable)
    if not sok or not settObj then return false end
    return settObj.pendingValue ~= nil
end

local function FlagsFor(setting)
    local saveBindings, gxRestart, windowUpdate
    if setting.HasCommitFlag and Settings and Settings.CommitFlag then
        local function has(flag)
            local ok, v = pcall(setting.HasCommitFlag, setting, flag)
            return ok and v
        end
        saveBindings = has(Settings.CommitFlag.SaveBindings)
        gxRestart    = has(Settings.CommitFlag.GxRestart)
        windowUpdate = has(Settings.CommitFlag.UpdateWindow)
    end
    return saveBindings, gxRestart, windowUpdate
end

-- Apply / revert one specific setting (per-row Apply/Reset buttons).
-- PROXY_ANTIALIASING is a "view" setting whose own SetValue closure
-- only zeros the OTHER mode's CVar (fxaa or msaa); it assumes the
-- chosen mode's CVar is already non-zero (Blizzard's UI relies on a
-- secondary "quality" dropdown the user fills in). For our inline
-- editor without that dropdown, default the dependent CVar to a
-- baseline so applying the parent actually turns AA on.
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

-- Settings whose own SetValue closure stages dependent Apply-flagged
-- settings (e.g., PROXY_ANTIALIASING's closure calls
-- aaSettings.fxaa:SetValue / aaSettings.msaa:SetValue). When we Apply
-- the parent, those dependents stay staged unless we also commit them.
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

    -- Settings flagged Revertable (monitor, resolution, display mode)
    -- need Blizzard's CommitSettings pipeline so the
    -- GAME_SETTINGS_TIMED_CONFIRMATION popup ("Accept new options?
    -- Reverting in 8 seconds.") fires. The popup is the user's only
    -- escape hatch when a change leaves the screen unusable. Our
    -- direct SetValue(immediate=true) path skips that, so route
    -- through Blizzard for these specifically. Push parent + any
    -- staged dependents into SettingsPanel.modified first.
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
    -- Parent's SetValue closure may have staged dependents (e.g.,
    -- AA_NONE clears both fxaa and msaa via dep:SetValue, which stages
    -- when the dep itself is Apply-flagged). Commit those too.
    CommitStagedDependents(variable)
    pendingApplySettings[settObj] = nil
    FirePendingChanged()
end

-- Mirrors Blizzard's GAME_SETTINGS_CONFIRM_DISCARD popup so closing
-- our search panel with pending Apply-flagged settings prompts the
-- same three-button choice. Defined once at file load; the StaticPopup
-- registry keeps it across reloads.
StaticPopupDialogs = StaticPopupDialogs or {}
if not StaticPopupDialogs["EASYFIND_UNAPPLIED_SETTINGS"] then
    StaticPopupDialogs["EASYFIND_UNAPPLIED_SETTINGS"] = {
        text = SETTINGS_CONFIRM_DISCARD or
            "You have settings that have not been applied.\nAre you sure you wish to exit?",
        button1 = SETTINGS_UNAPPLIED_EXIT or "Exit",
        button2 = SETTINGS_UNAPPLIED_APPLY_AND_EXIT or "Apply and Exit",
        button3 = SETTINGS_UNAPPLIED_CANCEL or "Cancel",
        OnButton1 = function()
            if BlizzOptionsSearch.RevertPendingChanges then
                BlizzOptionsSearch:RevertPendingChanges()
            end
            if ns.UI and ns.UI.HideResults then ns.UI:HideResults() end
        end,
        OnButton2 = function()
            if BlizzOptionsSearch.ApplyPendingChanges then
                BlizzOptionsSearch:ApplyPendingChanges()
            end
            if ns.UI and ns.UI.HideResults then ns.UI:HideResults() end
        end,
        OnButton3 = function() end,
        OnHide = function()
            -- Restore search bar focus when the popup dismisses, no
            -- matter the path (button click, ESC, or click-away).
            if ns.UI and ns.UI.RefocusSearchEditBox then
                ns.UI:RefocusSearchEditBox()
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
    -- Discard any dependents the parent staged.
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

-- Walk one category and its subcategories, recording id by name and
-- (where possible) by variable. SettingsPanel exposes the layout per
-- category; the layout has GetInitializers which return setting rows.
local function CrawlCategory(cat)
    if not cat or not cat.GetID or not cat.GetName then return end
    local catID = cat:GetID()
    local catName = cat:GetName()
    if catName and catName ~= "" then
        categoryIDByName[slower(catName)] = catID
    end

    -- Walk initializers to discover which variables this category owns.
    if SettingsPanel and SettingsPanel.GetLayout then
        local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
        if lok and layout and layout.GetInitializers then
            local iok, inits = pcall(layout.GetInitializers, layout)
            if iok and inits then
                for _, init in ipairs(inits) do
                    -- Try several access paths since the mixin shape varies.
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
                            -- Pull tooltip text from the initializer's
                            -- data.tooltip option (modern WoW stores
                            -- it there) if not already cached. Wrap
                            -- in pcall: data.tooltip can be a function
                            -- generator (returns string) or a string,
                            -- and data.options can be a function too,
                            -- so blind indexing raises in some clients.
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

    -- Recurse into subcategories.
    if cat.GetSubcategories then
        local sok, subs = pcall(cat.GetSubcategories, cat)
        if sok and type(subs) == "table" then
            for _, sub in ipairs(subs) do
                CrawlCategory(sub)
            end
        end
    end
end

-- One-time crawl of the live category tree. Idempotent: re-crawling
-- after addons register late just fills in any new entries. Each
-- CrawlCategory call is pcalled so a misbehaving category (third-
-- party addon's setting registration, weird initializer shape) can't
-- abort the entire crawl and starve SETTINGS_DATA of category ids.
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

-- Open the SettingsPanel (and load it lazily if needed). This is the
-- prerequisite for Settings.OpenToCategory navigation actually showing
-- the panel; on rare clients OpenToCategory alone doesn't trigger the
-- frame to be shown if the panel was never visible this session.
local function ShowSettings()
    if not SettingsPanel then return end
    if SettingsPanel:IsShown() then return end
    if SettingsPanel.Open then
        pcall(SettingsPanel.Open, SettingsPanel)
    elseif ShowUIPanel then
        pcall(ShowUIPanel, SettingsPanel)
    end
end

-- Find category id by name (case-insensitive). If we haven't crawled
-- yet, do so on demand.
local function GetCategoryID(name)
    if not name or name == "" then return nil end
    local cached = categoryIDByName[slower(name)]
    if cached then return cached end
    ResolveCategoryIDs()
    return categoryIDByName[slower(name)]
end

-- Find category id that owns a given setting variable.
local function GetCategoryIDForVariable(variable)
    if not variable then return nil end
    local cached = categoryIDByVariable[variable]
    if cached then return cached end
    ResolveCategoryIDs()
    return categoryIDByVariable[variable]
end
BlizzOptionsSearch.GetCategoryIDForVariable = GetCategoryIDForVariable

-- Open settings panel to the named category. Returns true on success.
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

-- Highlight the visible row for an elementData in the settings list, so
-- the user lands on a clearly-marked row instead of having to scan the
-- whole panel for the thing they searched.
local function HighlightFoundElement(scrollBox, elementData)
    if not scrollBox or not elementData then return end
    if not ns.Highlight or not ns.Highlight.HighlightFrame then return end
    SafeAfter(0.05, function()
        local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
        if frame then ns.Highlight:HighlightFrame(frame) end
    end)
end

local function FindSettingElement(dp, variable)
    if not dp then return nil end
    local function matches(elementData)
        local inner = elementData and (elementData.data or elementData)
        local setting = inner and inner.setting
        if setting and setting.GetVariable then
            return setting:GetVariable() == variable
        end
        return false
    end
    if dp.FindElementDataByPredicate then
        local found = dp:FindElementDataByPredicate(matches)
        if found then return found end
    end
    if dp.GetSize and dp.Find then
        for si = 1, dp:GetSize() do
            local ed = dp:Find(si)
            if matches(ed) then return ed end
        end
    end
    return nil
end

-- Scroll to and highlight the row for a setting variable.
local function ScrollToSettingVariable(variable)
    local scrollBox = GetSettingsScrollBox()
    if not scrollBox then return false end
    local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    local found = FindSettingElement(dp, variable)
    if not found then return false end
    local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
    scrollBox:ScrollToElementData(found, alignCenter)
    HighlightFoundElement(scrollBox, found)
    return true
end
BlizzOptionsSearch.ScrollToSettingVariable = ScrollToSettingVariable

-- Look up a binding's index from its action name (e.g., ACTIONBUTTON1).
local function GetBindingIndexForAction(action)
    if not action or not GetNumBindings or not GetBinding then return nil end
    for i = 1, GetNumBindings() do
        local a = GetBinding(i)
        if a == action then return i end
    end
    return nil
end

-- Walk a SettingsKeybindingSection's child binding frames for one whose
-- bindingIndex matches. KeyBindingFrameBindingTemplateMixin:Init stashes
-- the initializer on self.initializer, so binding index lives at
-- frame.initializer.data.bindingIndex.
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

-- Scroll to a keybind: find the section by header name, expand it if
-- collapsed, then highlight the binding row inside.
local function ScrollToBindingAction(action, headerName)
    if not action then return false end
    local scrollBox = GetSettingsScrollBox()
    if not scrollBox then return false end
    local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dp then return false end

    local bindingIdx = GetBindingIndexForAction(action)

    -- Locate the section element. Match by header name first; fall back
    -- to any section whose bindingsCategories contains our index.
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

    -- Expand if collapsed, wait for the section's child frames to lay
    -- out, then highlight the actual binding row. The section frame may
    -- be recycled across passes, so re-fetch it inside the deferred
    -- callback rather than capturing the first reference.
    local function expandThenHighlight()
        local sectionFrame = scrollBox.FindFrame and scrollBox:FindFrame(section)
        if not sectionFrame then return end
        if sectionData and not sectionData.expanded and sectionFrame.Button then
            sectionFrame.Button:Click()
        end
        SafeAfter(0.15, function()
            local sf = scrollBox.FindFrame and scrollBox:FindFrame(section)
            if not sf or not bindingIdx then return end
            local bindingFrame = FindBindingFrameInSection(sf, bindingIdx)
            if bindingFrame and bindingFrame:IsShown()
               and ns.Highlight and ns.Highlight.HighlightFrame then
                ns.Highlight:HighlightFrame(bindingFrame)
            end
        end)
    end
    SafeAfter(0.05, expandThenHighlight)

    return true
end
BlizzOptionsSearch.ScrollToBindingAction = ScrollToBindingAction

-- Collect name/path entries. SETTINGS_DATA always produces entries
-- regardless of whether the live Settings tree is available yet (the
-- category id resolves lazily at click time). Top-level / subcategory
-- entries from Settings.GetCategoryList are added on top when the
-- registry is reachable.
local function CollectEntries()
    local entries = {}

    -- Best-effort: resolve catIDs against the live category tree.
    -- Safe to call even if SettingsPanel hasn't been opened yet —
    -- it just leaves the lookup tables empty. HandleStep retries
    -- on demand when the user clicks an entry.
    ResolveCategoryIDs()

    -- Treat the live registry as authoritative: if at least one curated
    -- variable resolves, assume the registry is up and any unresolved
    -- variable is a phantom entry (CVar removed from the live panel in
    -- this client version). Skip those instead of injecting dead rows
    -- whose click does nothing. If nothing resolved, the registry
    -- isn't ready yet — fall back to emitting all curated entries and
    -- let the late re-pass at 3.0s prune.
    local registryReady = false
    for var in pairs(categoryIDByVariable) do
        if var then registryReady = true break end
    end

    -- Curated individual settings (Auto Loot, Sticky Targeting, etc.).
    -- These run unconditionally so they're always searchable, even on
    -- a clean install where Settings.GetCategoryList isn't ready until
    -- the user opens the panel.
    for si = 1, #SETTINGS_DATA do
        local row = SETTINGS_DATA[si]
        local name, var, catName, typeCode = row[1], row[2], row[3], row[4]
        local sMin, sMax, sStep = row[5], row[6], row[7]
        local nameLower = slower(name)
        local catLower = slower(catName)
        local resolved = TYPE_MAP[typeCode] or "other"
        local kw = { "setting", "option", "config", catLower, nameLower }
        local resolvedCatID = GetCategoryIDForVariable(var)
        if not (registryReady and not resolvedCatID) then
            local catID = resolvedCatID or GetCategoryID(catName)
            tinsert(entries, {
                name = name,
                nameLower = nameLower,
                keywords = kw,
                keywordsLower = kw,
                category = "Game Settings",
                path = { "Game Settings", catName },
                -- Icon comes from category="Game Settings" cogwheel routing in UI.lua.
                settingsCategory = catName,
                settingCategoryID = catID,
                settingVariable = var,
                settingType = resolved,
                settingMin = sMin,
                settingMax = sMax,
                settingStep = sStep,
                steps = {
                    {
                        settingsCategory = catName,
                        settingCategoryID = catID,
                        settingVariable = var,
                    },
                },
            })
        end
    end

    -- Top-level + subcategory entries from the live registry. Optional:
    -- if the categories aren't ready yet, the curated entries above are
    -- still present.
    local list = GetSettingsCategoryList()
    if type(list) ~= "table" then return entries end

    local function addCategoryEntry(cat, parentName)
        if not cat or not cat.GetName then return end
        local catName = cat:GetName()
        if not catName or catName == "" then return end
        local catID = cat.GetID and cat:GetID()
        local catNameLower = slower(catName)
        local kw = { "settings", "options", catNameLower }
        if parentName then kw[#kw + 1] = slower(parentName) end
        local entry = {
            name = catName,
            nameLower = catNameLower,
            keywords = kw,
            keywordsLower = kw,
            category = "Game Settings",
            -- Icon comes from category="Game Settings" cogwheel routing in UI.lua.
            settingsCategory = catName,
            settingCategoryID = catID,
            steps = { { settingsCategory = catName, settingCategoryID = catID } },
        }
        if parentName then entry.path = { "Game Settings", parentName } end
        tinsert(entries, entry)
    end

    for _, cat in ipairs(list) do
        addCategoryEntry(cat)
        if cat.GetSubcategories then
            local sok, subs = pcall(cat.GetSubcategories, cat)
            if sok and type(subs) == "table" then
                local parentName = cat.GetName and cat:GetName()
                for _, sub in ipairs(subs) do
                    addCategoryEntry(sub, parentName)
                end
            end
        end
    end

    return entries
end

-- Walk WoW's binding table and emit one search entry per binding.
-- WoW exposes bindings via GetNumBindings + GetBinding(index): each
-- row is either a header (skip) or a real binding (command, category,
-- key1, key2, ...). The localized display name lives in the global
-- BINDING_NAME_<command>; the localized category in BINDING_HEADER_<x>.
local function CollectKeybindings()
    local entries = {}
    if not GetNumBindings or not GetBinding then return entries end
    local n = GetNumBindings()
    if not n or n == 0 then return entries end

    local currentHeader = "Other"
    for i = 1, n do
        local action, category = GetBinding(i)
        if action and (action == "HEADER_BLANK" or action:find("^HEADER_")) then
            -- Header rows: stash the localized header text; falls back
            -- to the raw category if the global isn't populated.
            local headerKey = "BINDING_HEADER_" .. (category or action:sub(8))
            local headerLoc = _G[headerKey]
            if type(headerLoc) == "string" and headerLoc ~= "" then
                currentHeader = headerLoc
            elseif type(category) == "string" and category ~= "" then
                currentHeader = category
            end
        elseif action and action ~= "" then
            local nameKey = "BINDING_NAME_" .. action
            local displayName = _G[nameKey]
            if type(displayName) ~= "string" or displayName == "" then
                displayName = action
            end
            local nameLower = slower(displayName)
            local kw = { "keybind", "binding", "key", nameLower, slower(currentHeader) }
            tinsert(entries, {
                name = displayName,
                nameLower = nameLower,
                keywords = kw,
                keywordsLower = kw,
                category = "Game Settings",
                path = { "Game Settings", "Keybindings", currentHeader },
                settingsCategory = "Keybindings",
                settingType = "keybind",
                bindingAction = action,
                steps = {
                    {
                        settingsCategory = "Keybindings",
                        bindingAction = action,
                        bindingHeader = currentHeader,
                    },
                },
            })
        end
    end
    return entries
end
BlizzOptionsSearch.CollectKeybindings = CollectKeybindings

-- Inspect a category's initializers and emit one inline entry per
-- setting it owns. Returns inline entries for sliders / checkboxes /
-- dropdowns and a flag when the category had no inline-friendly
-- settings (so the caller still emits the category entry as a
-- fallback). The mixin shape varies between addons; everything is
-- pcalled so a malformed initializer doesn't abort the walk.
local function WalkCategorySettings(cat, catName, catID, pathPrefix)
    local out = {}
    if not (cat and SettingsPanel and SettingsPanel.GetLayout) then
        return out
    end
    local lok, layout = pcall(SettingsPanel.GetLayout, SettingsPanel, cat)
    if not lok or not layout or not layout.GetInitializers then return out end
    local iok, inits = pcall(layout.GetInitializers, layout)
    if not iok or not inits then return out end

    -- Combined initializers from CreateSettingsCheckboxSliderInitializer
    -- ("Use UI Scale" with the checkbox + companion slider in one row)
    -- bundle two settings into one initializer at init.data.cbSetting +
    -- init.data.sliderSetting. We emit a single "checkboxSlider" entry
    -- so the row mirrors Blizzard's combined widget instead of showing
    -- two separate searchable rows.
    local function inspectInit(init)
        local d = init.data
        if type(d) == "table" and d.cbSetting and d.sliderSetting then
            return { combined = true, init = init }
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
                -- Settings.CreateSliderOptions stores steps as the
                -- NUMBER OF STEPS across the range, not the per-tick
                -- delta. Convert to step size: (max - min) / steps.
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
            tinsert(out, {
                name = label,
                nameLower = nameLower,
                keywords = kw,
                keywordsLower = kw,
                category = "AddOn Settings",
                path = pathPrefix,
                settingsCategory = catName,
                settingCategoryID = catID,
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
            })
        end
      else
        local setting = info.setting
        if setting and setting.GetVariable then
            local vok, variable = pcall(setting.GetVariable, setting)
            local nok, settingName = pcall(setting.GetName, setting)
            if vok and variable and nok and settingName and settingName ~= "" then
                -- Detect type from initializer shape and setting metadata.
                -- Slider initializers expose a SliderOptions table on
                -- init.data.options; checkbox initializers have a boolean
                -- variable type; everything else falls into "dropdown".
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
                    -- Settings.CreateSliderOptions stores steps as the
                -- NUMBER OF STEPS across the range, not the per-tick
                -- delta. Convert to step size: (max - min) / steps.
                if opts.stepSize then
                    sStep = opts.stepSize
                elseif opts.steps and opts.steps > 0 and sMax > sMin then
                    sStep = (sMax - sMin) / opts.steps
                else
                    sStep = 1
                end
                    -- Slider display value goes through Blizzard's
                    -- formatter (uiScale 0.64 -> "64%", etc.). Labels
                    -- are keyed by MinimalSliderWithSteppersMixin.Label
                    -- (Left=0, Right=1, Top=2, Min=3, Max=4); Top
                    -- mirrors the live value above the thumb best.
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

                -- Capture dropdown option list so the row can cycle
                -- through values inline. Shape varies: array of
                -- { value, label } / { value, text } / Selections-style
                -- objects. We normalize to { value, label } pairs and
                -- skip if the table doesn't look enumerable.
                local settingOptions
                if resolvedType == "dropdown" then
                    settingOptions = GetInitializerOptions(init, setting)
                end

                local nameLower = slower(settingName)
                local kw = {
                    "addon", "setting", "option",
                    nameLower, slower(catName or ""),
                }
                local entry = {
                    name = settingName,
                    nameLower = nameLower,
                    keywords = kw,
                    keywordsLower = kw,
                    category = "AddOn Settings",
                    path = pathPrefix,
                    settingsCategory = catName,
                    settingCategoryID = catID,
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
                }
                tinsert(out, entry)
            end
        end
      end
    end
    return out
end

-- True iff cat belongs to the AddOns tab. Modern Settings categories
-- expose GetCategorySet() returning a Settings.CategorySet enum value;
-- if that's missing we fall back to checking a categorySet field.
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
    -- Older clients use a string or numeric tag
    return set == "AddOns" or set == 2
end

-- Walk the AddOns tab of the SettingsPanel and emit:
--   1. one navigable entry per addon category (opens the panel), and
--   2. one inline entry per individual setting inside each category
--      (so addon checkboxes / sliders are toggleable from the search
--      results just like Game Options).
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
        -- Path is rooted at "<addon> Settings" (e.g. "BugSack Settings")
        -- instead of "AddOn Settings > <addon>" — the latter wastes a
        -- whole row level on a constant string. For nested categories
        -- the subcategory name follows: "BugSack Settings > Tooltip".
        local rootName = (parentName or catName) .. " Settings"
        local pathPrefix = parentName and { rootName, catName } or { rootName }

        local kw = { "addon", "settings", "options", catNameLower }
        if parentName then kw[#kw + 1] = slower(parentName) end
        tinsert(entries, {
            name = catName,
            nameLower = catNameLower,
            keywords = kw,
            keywordsLower = kw,
            category = "AddOn Settings",
            -- Top-level addon: no path (the name itself reads as the
            -- addon). Subcategory: path is the parent's "X Settings".
            path = parentName and { rootName } or nil,
            settingsCategory = catName,
            settingCategoryID = catID,
            steps = { { settingsCategory = catName, settingCategoryID = catID } },
        })

        local inline = WalkCategorySettings(cat, catName, catID, pathPrefix)
        for _, e in ipairs(inline) do tinsert(entries, e) end
    end

    -- Try the typed accessor first (modern WoW exposes a category-set
    -- arg on GetCategoryList). Fall back to walking everything and
    -- filtering via IsAddonCategory.
    local gotTyped = false
    if Settings.CategorySet and Settings.GetCategoryList then
        local ok, list = pcall(Settings.GetCategoryList, Settings.CategorySet.AddOns)
        if ok and type(list) == "table" then
            gotTyped = true
            for _, cat in ipairs(list) do
                emit(cat, nil)
                if cat.GetSubcategories then
                    local sok, subs = pcall(cat.GetSubcategories, cat)
                    if sok and type(subs) == "table" then
                        local parentName = cat.GetName and cat:GetName()
                        for _, sub in ipairs(subs) do emit(sub, parentName) end
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
                if cat.GetSubcategories then
                    local sok, subs = pcall(cat.GetSubcategories, cat)
                    if sok and type(subs) == "table" then
                        local parentName = cat.GetName and cat:GetName()
                        for _, sub in ipairs(subs) do
                            emit(sub, parentName)
                        end
                    end
                end
            end
        end
    end

    return entries
end
BlizzOptionsSearch.CollectAddonCategories = CollectAddonCategories

-- Hardcoded option lists for graphics-quality dropdowns whose options
-- live inside SettingsAdvancedQualityControlsMixin's private closures
-- (GetShadowQualityOptions etc.). Mirror Blizzard's Graphics.lua: same
-- value sets, same localized label globals, same hardware-validity
-- filter via IsGraphicsSettingValueSupported.
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
    PROXY_VIEW_DISTANCE         = MakeQualityOpts("graphicsViewDistance", false, QUALITY_LIKE_5),
    PROXY_RAID_VIEW_DISTANCE    = MakeQualityOpts("raidGraphicsViewDistance", true, QUALITY_LIKE_5),
    PROXY_ENVIRONMENT_DETAIL    = MakeQualityOpts("graphicsEnvironmentDetail", false, QUALITY_LIKE_5),
    PROXY_RAID_ENVIRONMENT_DETAIL = MakeQualityOpts("raidGraphicsEnvironmentDetail", true, QUALITY_LIKE_5),
    PROXY_GROUND_CLUTTER        = MakeQualityOpts("graphicsGroundClutter", false, QUALITY_LIKE_5),
    PROXY_RAID_GROUND_CLUTTER   = MakeQualityOpts("raidGraphicsGroundClutter", true, QUALITY_LIKE_5),
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

-- Walk Game (non-AddOn) categories for individual settings the curated
-- SETTINGS_DATA list doesn't surface (Use UI Scale, vsync, etc.). The
-- live registry is authoritative for what's actually in the panel
-- this build, so this captures settings Blizzard added without us
-- touching the curated list. Skip variables already in SETTINGS_DATA
-- so we don't double-emit.
local function BuildCuratedVariableSet()
    local set = {}
    for i = 1, #SETTINGS_DATA do
        local v = SETTINGS_DATA[i] and SETTINGS_DATA[i][2]
        if v then set[v] = true end
    end
    return set
end

local function CollectGameSettings()
    local entries = {}
    if not Settings then return entries end
    local curated = BuildCuratedVariableSet()
    local emittedVars = {}
    for v in pairs(curated) do emittedVars[v] = true end
    local seenCatIDs = {}
    local function emit(cat, parentName)
        if not cat or not cat.GetName then return end
        if IsAddonCategory(cat) then return end
        local catID = cat.GetID and cat:GetID()
        if not catID or seenCatIDs[catID] then return end
        seenCatIDs[catID] = true
        local catName = cat:GetName()
        if not catName or catName == "" then return end
        local pathPrefix = { "Game Settings", catName }
        local inline = WalkCategorySettings(cat, catName, catID, pathPrefix)
        for _, e in ipairs(inline) do
            if not emittedVars[e.settingVariable] then
                e.category = "Game Settings"
                tinsert(entries, e)
                emittedVars[e.settingVariable] = true
            end
        end
    end
    local list = GetSettingsCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do
            emit(cat, nil)
            if cat.GetSubcategories then
                local sok, subs = pcall(cat.GetSubcategories, cat)
                if sok and type(subs) == "table" then
                    local parentName = cat.GetName and cat:GetName()
                    for _, sub in ipairs(subs) do emit(sub, parentName) end
                end
            end
        end
    end
    -- Fallback pass: SettingsPanel.settings holds every Setting object
    -- registered via Settings.RegisterCVar/Proxy/AddOn. Custom container
    -- initializers (Graphics Quality's BaseQualityControls, which bundles
    -- Shadow Quality / Liquid Detail / etc. into one frame) hide their
    -- child settings from layout:GetInitializers, so the walk above
    -- misses them. Pull them straight from the registry as basic
    -- navigation entries: click the row, panel opens to the category.
    if SettingsPanel and SettingsPanel.settings then
        for setting, cat in pairs(SettingsPanel.settings) do
            if cat and not IsAddonCategory(cat) and setting.GetVariable then
                local vok, variable = pcall(setting.GetVariable, setting)
                if vok and variable and not emittedVars[variable] then
                    local nok, settingName = pcall(setting.GetName, setting)
                    if nok and settingName and settingName ~= "" then
                        -- Base + Raid variants of each Graphics Quality
                        -- setting share the same display name with
                        -- different proxy variables (PROXY_SHADOW_QUALITY
                        -- vs the raid one). Suffix the raid version so
                        -- the search results don't show two identical
                        -- rows.
                        local displayName = settingName
                        local lowerVar = slower(variable)
                        if lowerVar:find("raid", 1, true) then
                            displayName = settingName .. " (Raid)"
                        end
                        local catName = cat.GetName and cat:GetName() or "Game Settings"
                        local catID = cat.GetID and cat:GetID()
                        local nameLower = slower(displayName)
                        local kw = { "setting", "option", "config", nameLower, slower(catName) }
                        -- Booleans render with the inline checkbox row.
                        -- Known graphics-quality dropdowns get a hardcoded
                        -- option list so the inline dropdown widget works.
                        -- Other non-boolean orphans fall back to "open the
                        -- panel on click" since we can't enumerate their
                        -- options from outside the custom mixin.
                        local resolvedType, settingOptions
                        local qspec = HARDCODED_OPTIONS[variable]
                        if qspec then
                            settingOptions = BuildQualityOptions(qspec)
                            if settingOptions then resolvedType = "dropdown" end
                        elseif setting.GetVariableType then
                            local tok, vt = pcall(setting.GetVariableType, setting)
                            if tok and vt == "boolean" then resolvedType = "checkbox" end
                        end
                        tinsert(entries, {
                            name = displayName,
                            nameLower = nameLower,
                            keywords = kw,
                            keywordsLower = kw,
                            category = "Game Settings",
                            path = { "Game Settings", catName },
                            settingsCategory = catName,
                            settingCategoryID = catID,
                            settingVariable = variable,
                            settingType = resolvedType,
                            settingOptions = settingOptions,
                            steps = {
                                { settingsCategory = catName, settingCategoryID = catID,
                                  settingVariable = variable },
                            },
                        })
                        emittedVars[variable] = true
                    end
                end
            end
        end
    end
    return entries
end
BlizzOptionsSearch.CollectGameSettings = CollectGameSettings

-- Register the collected entries into the Database. Called once
-- after PLAYER_LOGIN so Settings.* is fully populated.
function BlizzOptionsSearch:Populate()
    if not ns.Database or not ns.Database.uiSearchData then return end
    local entries = CollectEntries()
    local data = ns.Database.uiSearchData
    for i = 1, #entries do
        tinsert(data, entries[i])
    end
    local kb = CollectKeybindings()
    for i = 1, #kb do
        tinsert(data, kb[i])
    end
    local addonEntries = CollectAddonCategories()
    for i = 1, #addonEntries do
        tinsert(data, addonEntries[i])
    end
    local gameEntries = CollectGameSettings()
    for i = 1, #gameEntries do
        tinsert(data, gameEntries[i])
    end
    if ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
end

-- Step handler: open the Settings panel to the cached category id and
-- (when given) scroll to the specific setting row.
function BlizzOptionsSearch:HandleStep(step)
    if not step then return false end

    -- Prefer the cached id baked into the entry. Fall back to live
    -- lookup so old SavedVariables-pinned entries still work.
    local catID = step.settingCategoryID
    if not catID and step.settingVariable then
        catID = GetCategoryIDForVariable(step.settingVariable)
    end
    if not catID and step.settingsCategory then
        catID = GetCategoryID(step.settingsCategory)
    end

    -- Show the panel first. OpenToCategory in modern WoW is supposed
    -- to do this itself, but doing it explicitly first ensures the
    -- frame is up before navigation runs.
    ShowSettings()

    if catID and Settings and Settings.OpenToCategory then
        if step.settingVariable then
            pcall(Settings.OpenToCategory, catID, step.settingVariable)
        else
            pcall(Settings.OpenToCategory, catID)
        end
    end

    -- Belt-and-suspenders scroll: some clients accept the second arg
    -- to OpenToCategory, others ignore it. Scroll manually next frame.
    if step.settingVariable then
        SafeAfter(0, function() ScrollToSettingVariable(step.settingVariable) end)
        SafeAfter(0.1, function() ScrollToSettingVariable(step.settingVariable) end)
    elseif step.bindingAction then
        local header = step.bindingHeader
        SafeAfter(0, function() ScrollToBindingAction(step.bindingAction, header) end)
        SafeAfter(0.15, function() ScrollToBindingAction(step.bindingAction, header) end)
    end

    return catID ~= nil
end

-- Schedule registration after PLAYER_LOGIN so Settings.GetCategoryList
-- has the full tree (some addons register late). Two passes catch
-- any stragglers that register on first frame.
local registered = false
local function Register()
    if registered then return end
    registered = true
    BlizzOptionsSearch:Populate()
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    SafeAfter(0.5, Register)
    SafeAfter(3.0, function()
        -- Re-collect after a longer delay to pick up addons that
        -- register their settings categories during the first few
        -- seconds. Uses a name-based dedupe so we don't double up.
        local seen = {}
        for _, e in ipairs(ns.Database.uiSearchData or {}) do
            if e.settingsCategory and not e.settingVariable then
                seen[e.settingsCategory] = true
            end
        end
        ResolveCategoryIDs()
        local fresh = CollectEntries()
        for _, e in ipairs(fresh) do
            -- Skip individual settings: they were already injected
            -- on the first pass and CollectEntries always re-emits them.
            if not e.settingVariable and not seen[e.settingsCategory] then
                tinsert(ns.Database.uiSearchData, e)
            end
        end
        if ns.Database.ResetSearchCache then ns.Database:ResetSearchCache() end
    end)
end)
