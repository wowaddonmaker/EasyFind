local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs

local ACHIEVEMENT_FILTER_LABELS = {
    all = _G["ALL"] or "All",
    -- *_FILTER_EARNED/_INCOMPLETE are numeric filter-mode constants, not labels;
    -- ns.ACH_LABEL_* are the string-guarded display strings (see Utils).
    earned = ns.ACH_LABEL_EARNED,
    incomplete = ns.ACH_LABEL_INCOMPLETE,
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
    -- Statistics show a live value, or "--" when the character has none. Most
    -- are unrecorded on any given character, so a name search buries the few
    -- with data under a wall of "--". Defaults to All: this is a reference list
    -- people look things up in, and silently hiding rows from it is worse than
    -- a long list.
    { key = "statistics",  label = _G["STATISTICS"] or "Statistics",  iconTex = ns.STAT_CATEGORY_ICON_TEX,
      iconCoords = ns.STAT_CATEGORY_ICON_COORDS,
      flyoutRadio = {
          dbKey = "statisticFilterMode",
          options = {
              { value = "all",        label = _G["ALL"] or "All" },
              { value = "recorded",   label = L["FILTER_STAT_RECORDED"] },
              { value = "unrecorded", label = L["FILTER_STAT_UNRECORDED"] },
          },
          -- Filtered at query time (Search/Query.lua), so the results just
          -- need re-running; no provider repopulate.
          onChange = function() Filters:RerunActiveSearch() end,
      } },
    -- Items: the full game item catalog is the default ("everything else").
    -- Bags and Bank are owned-item overlays nested under it -- turning Items
    -- off hides all three; turning a child off drops just that overlay while
    -- the catalog still shows.
    { key = "items",       label = _G["ITEMS"] or "Items",
      iconTex = ns.ITEMS_CATEGORY_ICON_TEX, iconCoords = ns.ITEMS_CATEGORY_ICON_COORDS,
      iconAspect = ns.ITEMS_CATEGORY_ICON_ASPECT,
      flyoutSubFilters = {
          { key = "catalog", label = L["FILTER_GENERAL_CATALOG"], iconTex = ns.ITEMS_CATEGORY_ICON_TEX, iconCoords = ns.ITEMS_CATEGORY_ICON_COORDS, iconAspect = ns.ITEMS_CATEGORY_ICON_ASPECT, hasOptions = true },
          { key = "bags", label = _G["BAGSLOT"] or _G["BAGS"] or "Bags", iconAtlas = "bag-main", hasOptions = true },
          { key = "bank", label = _G["BANK"] or "Bank", iconTex = ns.BANK_CATEGORY_ICON_TEX, iconCoords = ns.BANK_CATEGORY_ICON_COORDS, hasOptions = true },
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
          { key = "pets",           label = _G["PETS"] or "Pets",            iconTex = 631719, hasOptions = true },
          { key = "toys",           label = _G["TOYS"] or _G["TOY_BOX"] or "Toys",            iconTex = 454046, hasOptions = true },
      } },
    -- The Equipment Manager lets a set be assigned to one of the character's
    -- specializations, so the flyout mirrors that: Any, or one row per spec.
    -- Options build lazily (a function, not a literal) because spec info is
    -- not readable when this file loads. Values are spec INDEXes, matching
    -- what C_EquipmentSet.GetEquipmentSetAssignedSpec returns.
    { key = "gearSets",    label = _G["EQUIPMENT_MANAGER"] or "Gear Sets",   iconTex = 514608,
      iconCoords = { 0.01562, 0.53125, 0.46875, 0.60547 },
      flyoutRadio = {
          dbKey = "gearSetSpecFilter",
          options = function()
              local opts = { { value = "all", label = _G["ALL_SPECS"] or "All Specializations" } }
              local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
              for i = 1, numSpecs do
                  local _, specName = GetSpecializationInfo(i)
                  if specName then
                      opts[#opts + 1] = { value = i, label = specName }
                  end
              end
              return opts
          end,
          -- Sets are filtered where they are built, so the provider has to
          -- repopulate before the search re-runs.
          onChange = function() Filters:ApplyFilterSelection("gearSets") end,
      } },
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
          checkboxes = {
              { dbKey = "hideTooltips.currencies", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    -- Loot: treasure-chest icon from the Encounter Journal loot tab
    -- spritesheet (texture 522972) for visual consistency with the
    -- in-game loot Search. hasFlyout flags the row to draw the chevron --
    -- the actual flyout (difficulty, spec, iLvl) is built inline below
    -- via lootOptionsPopup, not via flyoutSubFilters.
    { key = "loot",        label = _G["LOOT"] or "Loot",        iconTex = 522972,
      iconCoords = { 0.730, 0.824, 0.618, 0.660 }, hasFlyout = true },
    { key = "map",         label = L["FILTER_MAP_SEARCH"],  iconTex = ns.MAP_CATEGORY_ICON_TEX,
      iconCoords = ns.MAP_CATEGORY_ICON_COORDS,
      flyoutSubFilters = {
          { key = "zones",      label = _G["ZONES"] or "Zones",        dbTable = "uiMapFilters" },
          { key = "instances",  label = L["FILTER_INSTANCES"],    dbTable = "uiMapFilters",
            subFilters = {
                { key = "raid",    label = _G["RAIDS"] or "Raids",         dbTable = "uiMapFilters" },
                { key = "dungeon", label = _G["DUNGEONS"] or "Dungeons",   dbTable = "uiMapFilters" },
                { key = "delve",   label = _G["DELVES_LABEL"] or "Delves", dbTable = "uiMapFilters" },
            } },
          { key = "travel",     label = L["FILTER_TRAVEL"],       dbTable = "uiMapFilters",
            subFilters = {
                { key = "flights", label = _G["FLIGHT_PATHS_TAB"] or "Flight Paths", dbTable = "uiMapFilters" },
                { key = "boats",   label = L["MAP_FILTER_BOATS"],   dbTable = "uiMapFilters" },
                { key = "portals", label = L["MAP_FILTER_PORTALS"], dbTable = "uiMapFilters" },
            } },
          { key = "services",   label = L["FILTER_SERVICES"],     dbTable = "uiMapFilters",
            subFilters = {
                { key = "banks",      label = L["MAP_FILTER_BANKS"],      dbTable = "uiMapFilters" },
                { key = "auction",    label = L["MAP_FILTER_AUCTION"],    dbTable = "uiMapFilters" },
                { key = "inns",       label = L["MAP_FILTER_INNS"],       dbTable = "uiMapFilters" },
                { key = "mail",       label = L["MAP_FILTER_MAIL"],       dbTable = "uiMapFilters" },
                { key = "trainers",   label = L["MAP_FILTER_TRAINERS"],   dbTable = "uiMapFilters" },
                { key = "vendors",    label = L["MAP_FILTER_VENDORS"],    dbTable = "uiMapFilters" },
                { key = "appearance", label = L["MAP_FILTER_APPEARANCE"], dbTable = "uiMapFilters" },
                { key = "otherservices", label = L["MAP_FILTER_OTHER_SERVICES"], dbTable = "uiMapFilters" },
            } },
          { key = "rares",      label = L["FILTER_RARES"],        dbTable = "uiMapFilters" },
      } },
    { key = "housing",     label = _G["HOUSING_SETTINGS_LABEL"] or _G["BINDING_HEADER_HOUSING_SYSTEM"] or "Housing",
      iconAtlas = "UI-HUD-MicroMenu-Housing-Up", hasFlyout = true },
    -- Interact crosshair cursor file, used whole (not a sheet crop).
    { key = "options",     label = _G["OPTIONS"] or "Options",     iconTex = 4675635,
      flyoutSubFilters = {
          { key = "gameOptions",  label = L["FILTER_GAME_OPTIONS"],  iconAtlas = "QuestLog-icon-setting" },
          { key = "addonOptions", label = L["FILTER_ADDON_OPTIONS"], iconAtlas = "QuestLog-icon-setting", iconColor = { 1.0, 0.78, 0.35 } },
      } },
    { key = "professions", label = _G["TRADE_SKILLS"] or "Professions",
      iconAtlas = "UI-HUD-MicroMenu-Professions-Up", hasFlyout = true,
      available = function()
          if not GetProfessions then return false end
          local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
          return (prof1 or prof2 or archaeology or fishing or cooking) ~= nil
      end },
    { key = "reputations", label = _G["REPUTATION"] or "Reputations", iconTex = ns.REP_CATEGORY_ICON_TEX,
      iconCoords = ns.PlayerRepCategoryIconCoords(),
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
              { dbKey = "talentShowSpecs", label = _G["SPECIALIZATION"] or "Specialization" },
              { dbKey = "talentShowLoadouts", label = L["FILTER_LOADOUTS"] },
              { dbKey = "hideTooltips.talents", label = L["FILTER_HIDE_TOOLTIPS"] },
          },
      } },
    -- Title icon from PaperDollSidebarTab2 (Titles tab) spritesheet 514608.
    -- Titles you have not earned are opt-in: they outnumber earned ones many
    -- times over, so the default stays Earned and the other modes are a
    -- deliberate "show me what I am missing". Same three-way shape, and the
    -- same localized labels, as the achievements filter.
    { key = "titles",      label = _G["TITLES"] or _G["PAPERDOLL_SIDEBAR_TITLES"] or "Titles",      iconTex = 514608,
      iconCoords = { 0.016, 0.531, 0.324, 0.461 },
      flyoutRadio = {
          dbKey = "titleFilterMode",
          options = {
              { value = "earned",     label = ACHIEVEMENT_FILTER_LABELS.earned },
              { value = "incomplete", label = ACHIEVEMENT_FILTER_LABELS.incomplete },
              { value = "all",        label = ACHIEVEMENT_FILTER_LABELS.all },
          },
          onChange = function() Filters:ApplyFilterSelection("titles") end,
      } },
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
                if sub.subFilters then
                    for _, child in ipairs(sub.subFilters) do
                        callback(child.key, child)
                    end
                end
            end
        end
    end
end

-- Module-level helpers for bucketing Search search results into optional
-- filter categories. Entries with no bucket are base Search search results
-- and are always searchable.
-- Derived from the shared category map (see Shared/CategoryMap.lua) so the
-- bucket lookup can never drift from the query skip set or the providers.
local UI_BUCKET_BY_CATEGORY = ns.CategoryMap.BucketByCategory

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

-- Single source of truth for "is the cursor inside the filter menu". Returns
-- true when the mouse is over the main dropdown, its toggle button, or any
-- registered guard popup. Every flyout/popup stashes itself in
-- dropdown.guardFrames, so this one union covers the whole chain. Each popup's
-- GLOBAL_MOUSE_DOWN handler consults this instead of hardcoding its own subset
-- of related frames, so clicking a row inside one flyout (e.g. picking a class)
-- can never look "outside" to a sibling or ancestor and close it.
function Filters.IsMouseInFilterChain()
    local searchFrame = Search.GetSearchFrame and Search:GetSearchFrame()
    local dropdown = searchFrame and searchFrame.filterDropdown
    if not dropdown then return false end
    if Utils.IsFrameVisiblyMouseOver(dropdown) then return true end
    if Utils.IsFrameVisiblyMouseOver(searchFrame.filterBtn) then return true end
    local guards = dropdown.guardFrames
    if guards then
        for i = 1, #guards do
            if Utils.IsFrameVisiblyMouseOver(guards[i]) then return true end
        end
    end
    return false
end

-- Shared outside-click closer for filter popups: register GLOBAL_MOUSE_DOWN
-- on show, unregister on hide, hide when a click lands outside the filter
-- chain. Installed via HookScript, never SetScript: several of these popups
-- already carry OnShow/OnHide hooks (e.g. from Utils.AttachHoverPopup) that
-- SetScript would silently wipe. opts.onHide runs extra cleanup (hiding
-- nested flyouts, clearing the active-flyout tracker) after the unregister.
function Filters.AttachOutsideClickClose(popup, opts)
    local onHide = opts and opts.onHide
    popup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    popup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if onHide then onHide(self) end
    end)
    popup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if not Filters.IsMouseInFilterChain() then self:Hide() end
    end)
end

-- Re-run the checked/graying sync of every option popup currently visible.
-- Popups sync themselves when they open; this covers a filter toggle being
-- clicked while a deeper popup is already on screen, so its rows re-gray
-- immediately instead of waiting for the next hover-open.
function Filters.ResyncShownOptionPopups()
    local searchFrame = Search.GetSearchFrame and Search:GetSearchFrame()
    local dropdown = searchFrame and searchFrame.filterDropdown
    local guards = dropdown and dropdown.guardFrames
    if not guards then return end
    for i = 1, #guards do
        local guard = guards[i]
        if guard._efSync and guard:IsShown() then guard._efSync() end
    end
end

Filters.UI_FILTER_OPTIONS = UI_FILTER_OPTIONS
Filters.ForEachFilterKey = ForEachFilterKey
Filters.GetUIBucket = GetUIBucket
