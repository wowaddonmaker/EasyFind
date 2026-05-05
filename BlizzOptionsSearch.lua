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
local function NormalizeOptionTable(opts)
    if type(opts) == "function" then
        local ok, o = pcall(opts)
        if not ok then return nil end
        opts = o
    end
    if type(opts) ~= "table" then return nil end
    local norm = {}
    for _, o in ipairs(opts) do
        if type(o) == "table" and o.value ~= nil then
            local lab = o.label or o.text or o.name or tostring(o.value)
            tinsert(norm, { value = o.value, label = lab })
        end
    end
    if #norm == 0 then return nil end
    return norm
end

local function GetOptionsForVariable(variable)
    if not variable then return nil end
    local cached = optionsByVariable[variable]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    if not (SettingsPanel and SettingsPanel.GetLayout
            and Settings and Settings.GetCategoryList) then
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
                            found = NormalizeOptionTable(opts)
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
    local list = Settings.GetCategoryList()
    if type(list) == "table" then
        for _, cat in ipairs(list) do scan(cat) end
    end
    optionsByVariable[variable] = found or false
    return found
end
BlizzOptionsSearch.GetOptionsForVariable = GetOptionsForVariable

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
    if Settings and Settings.GetCategoryList then
        local lok, list = pcall(Settings.GetCategoryList)
        if lok and type(list) == "table" then
            for _, cat in ipairs(list) do
                pcall(CrawlCategory, cat)
            end
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

-- Scroll the SettingsPanel's setting list to the row matching the
-- given variable name. Called after the category opens.
local function ScrollToSettingVariable(variable)
    if not SettingsPanel then return false end
    local scrollBox = SettingsPanel.Container
        and SettingsPanel.Container.SettingsList
        and SettingsPanel.Container.SettingsList.ScrollBox
    if not scrollBox then return false end
    local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dp then return false end

    local found
    if dp.FindElementDataByPredicate then
        found = dp:FindElementDataByPredicate(function(elementData)
            local inner = elementData and (elementData.data or elementData)
            local setting = inner and inner.setting
            if setting and setting.GetVariable then
                return setting:GetVariable() == variable
            end
            return false
        end)
    end
    if not found and dp.GetSize and dp.Find then
        local sz = dp:GetSize()
        for si = 1, sz do
            local sdata = dp:Find(si)
            local inner = sdata and (sdata.data or sdata)
            local setting = inner and inner.setting
            if setting and setting.GetVariable
               and setting:GetVariable() == variable then
                found = sdata
                break
            end
        end
    end
    if found then
        local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
        scrollBox:ScrollToElementData(found, alignCenter)
        return true
    end
    return false
end
BlizzOptionsSearch.ScrollToSettingVariable = ScrollToSettingVariable

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
        local catID = GetCategoryIDForVariable(var) or GetCategoryID(catName)
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

    -- Top-level + subcategory entries from the live registry. Optional:
    -- if Settings.GetCategoryList isn't ready yet, the curated entries
    -- above are still present.
    if not Settings or not Settings.GetCategoryList then return entries end
    local list = Settings.GetCategoryList()
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
                    { settingsCategory = "Keybindings" },
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

    for _, init in ipairs(inits) do
        local setting
        if init.GetSetting then
            local sok, s = pcall(init.GetSetting, init)
            if sok then setting = s end
        end
        if not setting and init.data then setting = init.data.setting end
        if not setting and init.GetData then
            local dok, d = pcall(init.GetData, init)
            if dok and d then setting = d.setting end
        end

        if setting and setting.GetVariable then
            local vok, variable = pcall(setting.GetVariable, setting)
            local nok, settingName = pcall(setting.GetName, setting)
            if vok and variable and nok and settingName and settingName ~= "" then
                -- Detect type from initializer shape and setting metadata.
                -- Slider initializers expose a SliderOptions table on
                -- init.data.options; checkbox initializers have a boolean
                -- variable type; everything else falls into "dropdown".
                local resolvedType, sMin, sMax, sStep
                local d = init.data
                local opts = (type(d) == "table") and d.options or nil
                if type(opts) == "function" then
                    local ook, o = pcall(opts)
                    if ook then opts = o end
                end
                if type(opts) == "table" and opts.minValue and opts.maxValue then
                    resolvedType = "slider"
                    sMin = opts.minValue
                    sMax = opts.maxValue
                    sStep = opts.steps or opts.stepSize or 1
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
                if resolvedType == "dropdown" and type(opts) == "table" then
                    local norm = {}
                    for _, o in ipairs(opts) do
                        if type(o) == "table" and o.value ~= nil then
                            local lab = o.label or o.text or o.name or tostring(o.value)
                            tinsert(norm, { value = o.value, label = lab })
                        end
                    end
                    if #norm > 0 then settingOptions = norm end
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
