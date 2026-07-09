local _, ns = ...

local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local CALCULATOR_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\calculator-icon"

local BUTTON_ICON_REGIONS = {"Icon", "icon", "NormalTexture", "normalTexture"}
local buttonIconCache = {}
local buttonIconAtlasCache = {}

local function GetButtonIcon(frameName)
    if buttonIconCache[frameName] ~= nil then
        local cached = buttonIconCache[frameName]
        if cached == false then return nil end
        return cached, buttonIconAtlasCache[frameName]
    end

    local frame = _G[frameName]
    if not frame then return nil end

    if frame.textureName then
        local atlas = "UI-HUD-MicroMenu-" .. frame.textureName .. "-Up"
        buttonIconCache[frameName] = atlas
        buttonIconAtlasCache[frameName] = true
        return atlas, true
    end

    -- MicroButtons without textureName (e.g. CharacterMicroButton) use a portrait
    -- render texture that produces garbage when captured.
    if frame.IsMicroButton or (frameName and frameName:find("MicroButton")) then
        buttonIconCache[frameName] = false
        return nil
    end

    for i = 1, #BUTTON_ICON_REGIONS do
        local region = frame[BUTTON_ICON_REGIONS[i]]
        if region and region.GetTexture then
            local texture = region:GetTexture()
            if texture then
                buttonIconCache[frameName] = texture
                return texture
            end
        end
    end

    local regions = { frame:GetRegions() }
    for i = 1, #regions do
        local region = regions[i]
        if region and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            if texture and type(texture) == "number" then
                buttonIconCache[frameName] = texture
                return texture
            end
        end
    end

    return nil
end

local function GetFrameArtworkIcon(frameName)
    local frame = Utils.GetFrameByPath(frameName) or _G[frameName]
    if not (frame and frame.GetRegions) then return nil end

    local fallback
    local regions = { frame:GetRegions() }
    for i = 1, #regions do
        local region = regions[i]
        if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            local atlas = region.GetAtlas and region:GetAtlas()
            local layer = region.GetDrawLayer and region:GetDrawLayer()
            if texture and type(texture) == "number" and not atlas and layer == "ARTWORK" then
                local w, h = region:GetSize()
                if w and h and w >= 16 and h >= 16 and w <= 100 and h <= 100 then
                    return texture
                end
                if not fallback then fallback = texture end
            end
        end
    end
    return fallback
end

local function IsMenuBarSpecificIconData(data)
    return data and data.category == "Menu Bar" and data.buttonFrame
end

local function IsRightSideIconData(d)
    if not d then return false end
    return d.mountID or d.toyItemID or d.petID
        or d.outfitID or d.heirloomItemID or d.transmogSetID or d.appearanceItemID
        or d.category == "Currency"
        or (d.itemID and d.category == "Loot")
        or (d.spellID and d.category == "Talent")
        or (d.spellID and d.category == "Ability")
        or (d.encounterID and d.category == "Boss")
        or (d.macroIndex and d.category == "Macro")
        or (d.bagID and d.category == "Bag")
        or (d.achievementID and d.category == "Achievement")
        or d.gearSetID
        or IsMenuBarSpecificIconData(d)
        or d.specificIcon or d.specificIconFrame
        or d.mapSearchResult
end

local function SetButtonFrameIcon(resultRow, frameName, iconSize)
    if frameName == "CharacterMicroButton" then
        Icons:SetRowIcon(resultRow, "hidden", nil, iconSize)
        SetPortraitTexture(resultRow.icon, "player")
        resultRow.icon:SetTexCoord(0, 1, 0, 1)
        resultRow.icon:SetSize(iconSize, iconSize)
        resultRow.icon:Show()
        return true
    end

    local texture, isAtlas = GetButtonIcon(frameName)
    if not texture then return false end

    local kind = isAtlas and "atlas" or "file"
    Icons:SetRowIcon(resultRow, kind, texture, iconSize)
    return true
end

Icons.IsRightSideIconData = IsRightSideIconData
Icons.SetButtonFrameIcon = SetButtonFrameIcon
Icons.GetButtonIcon = GetButtonIcon
Icons.GetFrameArtworkIcon = GetFrameArtworkIcon
Icons.IsMenuBarSpecificIconData = IsMenuBarSpecificIconData

-- Result category metadata and row icon helpers moved out of SearchBar ownership.
-- LEFT-side category icons for flat mode. Collection items (mounts, toys,
-- etc.) push their item-specific icon to the right side of the row, leaving
-- the left empty; we fill it with the same icon used in the filter dropdown
-- so each row carries an at-a-glance category cue. Numeric entries are
-- texture FileDataIDs; strings are texture paths or atlas names (atlas key).
local FLAT_CATEGORY_ICONS = {
    mount         = { tex = 132261 },
    toy           = { tex = 454046 },
    pet           = { tex = 631719 },
    outfit        = { tex = 132649 },
    heirloom      = { tex = 133877 },
    appearanceSet = { tex = "Interface\\Icons\\INV_Helmet_03" },
    currency      = { tex = 136452 },  -- Same coin/AH glyph the map uses
    reputation    = { tex = 1121272, coords = { 0.3783, 0.4072, 0.9066, 0.9350 } },
    statistic     = { tex = 1121272, coords = { 0.2030, 0.2397, 0.6641, 0.6921 } },
    map           = { tex = 1121272, coords = { 0.4287, 0.4645, 0.2580, 0.2932 } },
    -- Ability / boss: matches the filter-menu icons (boss tab + overview tab
    -- glyphs from the Encounter Journal spritesheet). The row's per-entry
    -- icon (spell icon / boss portrait) is pushed to the RIGHT side.
    ability       = { tex = 522972, coords = { 0.904, 0.996, 0.707, 0.748 } },
    boss          = { tex = 522972, coords = { 0.855, 0.949, 0.524, 0.566 } },
    talent        = { atlas = "UI-HUD-MicroMenu-SpecTalents-Up" },
    achievement   = { atlas = "UI-HUD-MicroMenu-Achievements-Up" },
    macro         = { tex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    bag           = { atlas = "bag-main" },
    loot          = { tex = 522972, coords = { 0.730, 0.824, 0.618, 0.660 } },
    menuBar       = { tex = "Interface\\AddOns\\EasyFind\\Search\\Images\\menu-bar" },
    setting       = { atlas = "QuestLog-icon-setting" },
    command       = { tex = ns.COMMANDS_ICON_TEX },
    -- Addon settings get a warm tint so they're distinguishable at a
    -- glance from the silvery-grey game-settings cogwheel.
    settingAddon  = { atlas = "QuestLog-icon-setting", color = { 1.0, 0.78, 0.35 } },
    title         = { tex = 514608, coords = { 0.016, 0.531, 0.324, 0.461 } },
    calculator    = { tex = CALCULATOR_ICON_TEX },
    -- Equipment Manager sidebar tab icon (PaperDollSidebarTab3 ARTWORK
    -- region of the PaperDollSidebarTabs sheet, same sheet as `title`).
    gearSet       = { tex = 514608, coords = { 0.01562, 0.53125, 0.46875, 0.60547 } },
    housing       = { atlas = "UI-HUD-MicroMenu-Housing-Up" },
    profession    = { atlas = "UI-HUD-MicroMenu-Professions-Up" },
}

local BOSS_PORTRAIT_TEXCOORD = { 0.22, 0.78, 0, 1 }

function Icons:IsBossResultData(data)
    return data and data.encounterID and data.category == "Boss"
end

-- Reputation icon by faction side. Either-faction (nil) uses the same
-- crest as the filter button; Alliance/Horde get their faction-specific
-- crests. All cropped from the shared 1121272 sprite sheet.
local REP_FACTION_ICONS = {
    alliance = { tex = 1121272, coords = { 0.4740, 0.5055, 0.8371, 0.8706 } },
    horde    = { tex = 1121272, coords = { 0.4743, 0.5058, 0.8707, 0.9042 } },
    either   = { tex = 1121272, coords = { 0.3783, 0.4072, 0.9066, 0.9350 } },
}

function Icons:GetFlatCategoryIcon(data)
    if not data then return nil end
    if data.calculatorResult or data.calculatorLauncher then return FLAT_CATEGORY_ICONS.calculator end
    if data.searchCommand or data.nativeRun then return FLAT_CATEGORY_ICONS.command end
    if data.quickFilterDef then
        local key = data.quickFilterDef.key
        if key == "abilities" then return FLAT_CATEGORY_ICONS.ability end
        if key == "achievements" then return FLAT_CATEGORY_ICONS.achievement end
        if key == "statistics" then return FLAT_CATEGORY_ICONS.statistic end
        if key == "bags" then return FLAT_CATEGORY_ICONS.bag end
        if key == "bosses" then return FLAT_CATEGORY_ICONS.boss end
        if key == "macros" then return FLAT_CATEGORY_ICONS.macro end
        if key == "collections" then return FLAT_CATEGORY_ICONS.mount end
        if key == "appearanceSets" then return FLAT_CATEGORY_ICONS.appearanceSet end
        if key == "heirlooms" then return FLAT_CATEGORY_ICONS.heirloom end
        if key == "mounts" then return FLAT_CATEGORY_ICONS.mount end
        if key == "outfits" then return FLAT_CATEGORY_ICONS.outfit end
        if key == "pets" then return FLAT_CATEGORY_ICONS.pet end
        if key == "toys" then return FLAT_CATEGORY_ICONS.toy end
        if key == "gearSets" then return FLAT_CATEGORY_ICONS.gearSet end
        if key == "currencies" then return FLAT_CATEGORY_ICONS.currency end
        if key == "loot" then return FLAT_CATEGORY_ICONS.loot end
        if key == "housing" then return FLAT_CATEGORY_ICONS.housing end
        if key == "map" then return FLAT_CATEGORY_ICONS.map end
        if key == "reputations" then return FLAT_CATEGORY_ICONS.reputation end
        if key == "talents" then return FLAT_CATEGORY_ICONS.talent end
        if key == "titles" then return FLAT_CATEGORY_ICONS.title end
        return FLAT_CATEGORY_ICONS.setting
    end
    if data.mountID then return FLAT_CATEGORY_ICONS.mount end
    if data.toyItemID then return FLAT_CATEGORY_ICONS.toy end
    if data.petID then return FLAT_CATEGORY_ICONS.pet end
    if data.outfitID then return FLAT_CATEGORY_ICONS.outfit end
    if data.heirloomItemID then return FLAT_CATEGORY_ICONS.heirloom end
    if data.transmogSetID then return FLAT_CATEGORY_ICONS.appearanceSet end
    if data.appearanceItemID then return FLAT_CATEGORY_ICONS.appearanceSet end
    if data.spellID and data.category == "Ability" then return FLAT_CATEGORY_ICONS.ability end
    if data.category == "Talent" then return FLAT_CATEGORY_ICONS.talent end
    if data.achievementID and data.category == "Achievement" then return FLAT_CATEGORY_ICONS.achievement end
    if data.encounterID and data.category == "Boss" then return FLAT_CATEGORY_ICONS.boss end
    if data.macroIndex and data.category == "Macro" then return FLAT_CATEGORY_ICONS.macro end
    if data.bagID and data.category == "Bag" then return FLAT_CATEGORY_ICONS.bag end
    if data.itemID and data.category == "Loot" then return FLAT_CATEGORY_ICONS.loot end
    if data.category == "Game Settings" then return FLAT_CATEGORY_ICONS.setting end
    if data.category == "AddOn Settings" then return FLAT_CATEGORY_ICONS.settingAddon end
    if data.category == "Menu Bar" and data.buttonFrame then return FLAT_CATEGORY_ICONS.menuBar end
    if data.category == "Currency" then return FLAT_CATEGORY_ICONS.currency end
    if data.category == "Housing" then return FLAT_CATEGORY_ICONS.housing end
    if data.professionSkillLine then return FLAT_CATEGORY_ICONS.profession end
    if data.statisticID or data.category == "Statistic" then return FLAT_CATEGORY_ICONS.statistic end
    if data.titleID then return FLAT_CATEGORY_ICONS.title end
    if data.gearSetID then return FLAT_CATEGORY_ICONS.gearSet end
    if data.category == "Reputation" and data.factionID then
        return REP_FACTION_ICONS[data.factionSide or "either"]
    end
    if data.mapSearchResult then return FLAT_CATEGORY_ICONS.map end
    return nil
end

function Icons:GetRepFactionIcon(factionSide)
    return REP_FACTION_ICONS[factionSide or "either"]
end

function Icons:IsSpellbookOnlyAbility(data)
    return Utils.IsSpellbookOnlyAbility(data)
end

function Icons:IsMountSummonable(data)
    if not (data and data.mountID and data.isCollected) then return false end
    if data.isUsable == false or data.shouldHideOnChar then return false end
    return true
end

local function ClearRowIconLeafIDs(icon)
    icon.mountID = nil
    icon.toyItemID = nil
    icon.petID = nil
    icon.spellID = nil
    icon.outfitID = nil
    icon.heirloomItemID = nil
    icon.appearanceItemID = nil
    icon.gearSetID = nil
    icon.bagItemID = nil
    icon.achievementID = nil
    icon.lootItemID = nil
end
Icons.ClearRowIconLeafIDs = ClearRowIconLeafIDs

function Icons:SetRowIcon(btn, kind, value, iconSize)
    local sz = iconSize or 16
    btn.icon:SetTexture(nil)
    btn.icon:SetTexCoord(0, 1, 0, 1)
    btn.icon:SetVertexColor(1, 1, 1, 1)
    -- Clear mount/toy/pet tooltip data and cooldown from previous render
    ClearRowIconLeafIDs(btn.icon)
    if btn.iconCooldown then btn.iconCooldown:Hide() end
    if btn._lockOverlay then btn._lockOverlay:Hide() end
    if kind == "atlas" then
        btn.icon:SetAtlas(value)
    elseif kind == "file" or kind == "path" then
        if type(value) == "table" and value.file then
            btn.icon:SetTexture(value.file)
            if value.coords then
                btn.icon:SetTexCoord(unpack(value.coords))
            end
        else
            btn.icon:SetTexture(value)
        end
    elseif kind == "hidden" then
        btn.icon:Hide()
        return
    end
    btn.icon:SetSize(sz, sz)
    btn.icon:Show()
end

function Icons:IsSecureActionResult(data)
    if not data then return nil end
    -- Cheap field checks first; the opener classification (keyboard
    -- activation must drive the secure button instead of the tainted open,
    -- see Shared/SecureOpeners.lua) only runs for rows the chain rejects.
    return (data.outfitID or data.toyItemID
        or (data.spellID and data.category ~= "Talent"
            and not Icons:IsSpellbookOnlyAbility(data))
        or (data.mountID and Icons:IsMountSummonable(data))
        or data.macroIndex or data.slashCommand
        or (data.itemID and data.category == "Bag"
            and Handlers:GetBagItemActionKind(data) ~= "show"))
        or (ns.SecureOpeners and ns.SecureOpeners.OpenKeyForData(data)) or false
end

function Icons:GetBossPortraitTexCoord()
    return BOSS_PORTRAIT_TEXCOORD
end
