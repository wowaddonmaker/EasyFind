local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs

local ACHIEVEMENT_FILTER_LABELS = {
    all = _G["ALL"] or "All",
    earned = _G["ACHIEVEMENT_FILTER_EARNED"] or _G["EARNED"] or "Earned",
    incomplete = _G["ACHIEVEMENT_FILTER_INCOMPLETE"] or _G["INCOMPLETE"] or "Incomplete",
}

local UI_FILTER_OPTIONS = {
    -- Abilities: boss-skull icon from the Encounter Journal boss tab
    -- spritesheet (texture 522972).
    { key = "abilities",   label = _G["ABILITIES"] or "Abilities",   iconTex = 522972,
      iconCoords = { 0.904, 0.996, 0.707, 0.748 },
      flyoutRadio = {
          checkboxes = {
              { dbKey = "abilityHidePassives", label = L["FILTER_HIDE_PASSIVES"],
                onChange = function(v) if Search.ApplySpellBookHidePassives then Search:ApplySpellBookHidePassives(v) end end },
              { dbKey = "hideTooltips.abilities", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    { key = "achievements", label = _G["ACHIEVEMENTS"] or "Achievements", iconAtlas = "UI-HUD-MicroMenu-Achievements-Up",
      flyoutRadio = {
          dbKey = "achievementFilterMode",
          options = {
              { value = "all",        label = ACHIEVEMENT_FILTER_LABELS.all },
              { value = "earned",     label = ACHIEVEMENT_FILTER_LABELS.earned },
              { value = "incomplete", label = ACHIEVEMENT_FILTER_LABELS.incomplete },
          },
          checkboxes = {
              { dbKey = "hideAchievementHeaders", label = L["FILTER_HIDE_ACHIEVEMENT_HEADERS"] },
              { dbKey = "hideGuildAchievements", label = L["FILTER_HIDE_GUILD_ACHIEVEMENTS"] },
          },
      } },
    { key = "statistics",  label = _G["STATISTICS"] or "Statistics",  iconTex = 1121272,
      iconCoords = { 0.2030, 0.2397, 0.6641, 0.6921 } },
    { key = "bags",        label = _G["BAGSLOT"] or _G["BAGS"] or "Bags",        iconAtlas = "bag-main",
      flyoutRadio = {
          checkboxes = {
              { dbKey = "bagHideJunk", label = L["FILTER_EXCLUDE_JUNK"] },
              { dbKey = "hideTooltips.bags", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    -- Bosses: EJ overview tab icon from texture 522972.
    { key = "bosses",      label = _G["RAID_BOSSES"] or "Bosses",      iconTex = 522972,
      iconCoords = { 0.855, 0.949, 0.524, 0.566 },
      flyoutRadio = {
          checkboxes = {
              { dbKey = "bossFilterDungeon", label = _G["LFG_TYPE_DUNGEON"] or "Dungeon" },
              { dbKey = "bossFilterRaid", label = _G["RAID"] or "Raid" },
          },
      } },
    { key = "macros",      label = _G["MACROS"] or "Macros",      iconTex = "Interface\\MacroFrame\\MacroFrame-Icon",
      flyoutRadio = {
          checkboxes = {
              { dbKey = "macroFilterGeneral", label = _G["GENERAL"] or "General" },
              { dbKey = "macroFilterChar", label = _G["CHARACTER"] or "Character" },
              { dbKey = "hideTooltips.macros", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    { key = "collections",  label = _G["COLLECTIONS"] or "Collections",  iconAtlas = "UI-HUD-MicroMenu-Collections-Up",
      flyoutSubFilters = {
          { key = "appearances", label = _G["WARDROBE"] or "Appearances", iconTex = "Interface\\Icons\\INV_Helmet_03", hasOptions = true },
          { key = "heirlooms",      label = _G["HEIRLOOMS"] or "Heirlooms",       iconTex = 133877, hasOptions = true },
          { key = "mounts",         label = _G["MOUNTS"] or "Mounts",          iconTex = 132261, hasOptions = true },
          { key = "outfits",        label = L["FILTER_OUTFITS"],         iconTex = 132649 },
          { key = "pets",           label = _G["PETS"] or "Pets",            iconTex = 631719 },
          { key = "toys",           label = _G["TOYS"] or _G["TOY_BOX"] or "Toys",            iconTex = 454046 },
      } },
    { key = "gearSets",    label = _G["EQUIPMENT_MANAGER"] or "Gear Sets",   iconAtlas = "equipmentmanager-spec-border" },
    { key = "currencies",  label = _G["CURRENCY"] or "Currencies",  iconTex = 136452,
      flyoutRadio = {
          dbKey = "currencyFilterMode",
          options = {
              { value = "warband", label = CURRENCY_FILTER_TYPE_TRANSFERABLE or "All Warband Transferable" },
              { value = "all",     label = (CURRENCY_FILTER_TYPE_CHARACTER and UnitName and UnitName("player")
                                           and CURRENCY_FILTER_TYPE_CHARACTER:format(UnitName("player")))
                                          or ((UnitName and UnitName("player") or "This Character") .. " Only") },
          },
          onChange = function(v) if Search.ApplyTokenFrameFilter then Search:ApplyTokenFrameFilter(v) end end,
      } },
    -- Gear: treasure-chest icon from the Encounter Journal loot tab
    -- spritesheet (texture 522972) for visual consistency with the
    -- in-game loot Search. hasFlyout flags the row to draw the chevron --
    -- the actual flyout (difficulty, spec, iLvl) is built inline below
    -- via gearOptionsPopup, not via flyoutSubFilters.
    { key = "loot",        label = L["FILTER_GEAR"],        iconTex = 522972,
      iconCoords = { 0.730, 0.824, 0.618, 0.660 }, hasFlyout = true },
    { key = "map",         label = L["FILTER_MAP_SEARCH"],  iconTex = 1121272,
      iconCoords = { 0.4287, 0.4645, 0.2580, 0.2932 },
      flyoutSubFilters = {
          { key = "zones",      label = _G["ZONES"] or "Zones",        dbTable = "mapTabFilters" },
          { key = "instances",  label = L["FILTER_INSTANCES"],    dbTable = "mapTabFilters" },
          { key = "flightpath", label = _G["FLIGHT_PATHS_TAB"] or "Flight Paths", dbTable = "mapTabFilters" },
          { key = "travel",     label = L["FILTER_TRAVEL"],       dbTable = "mapTabFilters" },
          { key = "services",   label = L["FILTER_SERVICES"],     dbTable = "mapTabFilters" },
          { key = "rares",      label = L["FILTER_RARES"],        dbTable = "mapTabFilters" },
      } },
    { key = "options",     label = _G["OPTIONS"] or "Options",     iconTex = 1121272,
      iconCoords = { 0.4454, 0.4720, 0.8749, 0.9010 },
      flyoutSubFilters = {
          { key = "gameOptions",  label = L["FILTER_GAME_OPTIONS"],  iconAtlas = "QuestLog-icon-setting" },
          { key = "addonOptions", label = L["FILTER_ADDON_OPTIONS"], iconAtlas = "QuestLog-icon-setting", iconColor = { 1.0, 0.78, 0.35 } },
      } },
    { key = "reputations", label = _G["REPUTATION"] or "Reputations", iconTex = 1121272,
      iconCoords = { 0.3783, 0.4072, 0.9066, 0.9350 },
      flyoutRadio = {
          dbKey = "reputationFilterMode",
          options = {
              { value = "all",     label = _G["ALL"] or "All" },
              { value = "warband", label = _G["WARBAND"] or "Warband" },
              { value = "char",    label = (UnitName and UnitName("player")) or "This Character" },
          },
          onChange = function(v) if Search.ApplyReputationFilter then Search:ApplyReputationFilter(v) end end,
          checkboxes = {
              { dbKey = "showLegacyReputations", label = L["FILTER_SHOW_LEGACY_REPUTATIONS"],
                onChange = function(v) if Search.ApplyReputationShowLegacy then Search:ApplyReputationShowLegacy(v) end end },
          },
      } },
    -- Talents: leaf icon from the talents atlas spritesheet (4556093),
    -- visually consistent with the in-game talent tree.
    { key = "talents",     label = _G["TALENTS"] or "Talents",     iconAtlas = "UI-HUD-MicroMenu-SpecTalents-Up",
      flyoutRadio = {
          checkboxes = {
              { dbKey = "hideTooltips.talents", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    -- Title icon from PaperDollSidebarTab2 (Titles tab) spritesheet 514608.
    { key = "titles",      label = _G["TITLES"] or _G["PAPERDOLL_SIDEBAR_TITLES"] or "Titles",      iconTex = 514608,
      iconCoords = { 0.016, 0.531, 0.324, 0.461 } },
    { key = "commands",    label = L["FILTER_COMMANDS"], iconTex = ns.COMMANDS_ICON_TEX,
      flyoutRadio = {
          checkboxes = {
              { dbKey = "commandShowNative", label = _G["DEFAULT"] or "Default" },
              { dbKey = "commandShowCustom", label = L["FILTER_EXTRA"] },
          },
      } },
}

-- Top-level filter categories list alphabetically by their (localized) label.
-- Sub-filters inside each flyout keep their authored order.
table.sort(UI_FILTER_OPTIONS, function(a, b)
    return (a.label or ""):lower() < (b.label or ""):lower()
end)

-- All filter keys (top-level + sub-filters in flyouts). Used by Toggle
-- All / OnShow sync so flyout-hosted filters update too.
local function ForEachFilterKey(callback)
    for _, opt in ipairs(UI_FILTER_OPTIONS) do
        callback(opt.key, opt)
        if opt.flyoutSubFilters then
            for _, sub in ipairs(opt.flyoutSubFilters) do
                callback(sub.key, sub)
            end
        end
    end
end

-- Module-level helpers for bucketing Search search results into optional
-- filter categories. Entries with no bucket are base Search search results
-- and are always searchable.
local UI_BUCKET_BY_CATEGORY = {
    ["Ability"]            = "abilities",
    ["Boss"]               = "bosses",
    ["Achievement"]          = "achievements",
    ["Achievements"]         = "achievements",
    ["Achievement Category"] = "achievements",
    ["Guild Achievements"]   = "achievements",
    ["Statistics"]           = "statistics",
    ["Statistic"]            = "statistics",
    ["Currency"]           = "currencies",
    ["Reputation"]         = "reputations",
    ["Bag"]                = "bags",
    ["Macro"]              = "macros",
    ["Talent"]             = "talents",
    ["Title"]              = "titles",
    ["Gear Set"]           = "gearSets",
    ["Game Settings"]      = "gameOptions",
    ["AddOn Settings"]     = "addonOptions",
    ["Command"]            = "commands",
}

local function GetUIBucket(d)
    -- Returns one of the bucket keys for filtered non-collection /
    -- non-map Search entries, or nil for base entries / entries handled by
    -- a separate dedicated filter.
    if not d then return nil end
    if d.mountID or d.toyItemID or d.petID or d.outfitID or d.heirloomItemID
       or d.transmogSetID
       or (d.itemID and d.category == "Loot") or d.mapSearchResult then
        return nil
    end
    return UI_BUCKET_BY_CATEGORY[d.category]
end

function Filters:GetUIBucket(data)
    return GetUIBucket(data)
end

function Filters:IsGuildAchievementData(data)
    return data and data.isGuildAchievement == true
end

Filters.UI_FILTER_OPTIONS = UI_FILTER_OPTIONS
Filters.ForEachFilterKey = ForEachFilterKey
Filters.GetUIBucket = GetUIBucket
