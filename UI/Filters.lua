local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils

local ipairs, pairs = Utils.ipairs, Utils.pairs
local sfind, slower = Utils.sfind, Utils.slower
local tsort = Utils.tsort
local mmax = Utils.mmax

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local wipe = wipe

local ACHIEVEMENT_FILTER_LABELS = {
    all = _G["ALL"] or "All",
    earned = _G["ACHIEVEMENT_FILTER_EARNED"] or _G["EARNED"] or "Earned",
    incomplete = _G["ACHIEVEMENT_FILTER_INCOMPLETE"] or _G["INCOMPLETE"] or "Incomplete",
}

local UI_FILTER_OPTIONS = {
    -- Abilities: boss-skull icon from the Encounter Journal boss tab
    -- spritesheet (texture 522972).
    { key = "abilities",   label = "Abilities",   iconTex = 522972,
      iconCoords = { 0.904, 0.996, 0.707, 0.748 },
      flyoutRadio = {
          checkboxes = {
              { dbKey = "abilityHidePassives", label = "Hide Passives",
                onChange = function(v) if UI.ApplySpellBookHidePassives then UI:ApplySpellBookHidePassives(v) end end },
          },
      } },
    { key = "achievements", label = "Achievements", iconAtlas = "UI-HUD-MicroMenu-Achievements-Up",
      flyoutRadio = {
          dbKey = "achievementFilterMode",
          options = {
              { value = "all",        label = ACHIEVEMENT_FILTER_LABELS.all },
              { value = "earned",     label = ACHIEVEMENT_FILTER_LABELS.earned },
              { value = "incomplete", label = ACHIEVEMENT_FILTER_LABELS.incomplete },
          },
          checkboxes = {
              { dbKey = "hideAchievementHeaders", label = "Hide achievement headers" },
              { dbKey = "hideGuildAchievements", label = "Hide guild achievements" },
          },
      } },
    { key = "statistics",  label = "Statistics",  iconTex = 1121272,
      iconCoords = { 0.1997, 0.2437, 0.5933, 0.6266 } },
    { key = "bags",        label = "Bags",        iconAtlas = "bag-main" },
    -- Bosses: EJ overview tab icon from texture 522972.
    { key = "bosses",      label = "Bosses",      iconTex = 522972,
      iconCoords = { 0.855, 0.949, 0.524, 0.566 } },
    { key = "macros",      label = "Macros",      iconTex = "Interface\\MacroFrame\\MacroFrame-Icon" },
    { key = "collections",  label = "Collections",  iconAtlas = "UI-HUD-MicroMenu-Collections-Up",
      flyoutSubFilters = {
          { key = "appearanceSets", label = "Appearance Sets", iconTex = "Interface\\Icons\\INV_Helmet_03", hasOptions = true },
          { key = "heirlooms",      label = "Heirlooms",       iconTex = 133877 },
          { key = "mounts",         label = "Mounts",          iconTex = 132261, hasOptions = true },
          { key = "outfits",        label = "Outfits",         iconTex = 132649 },
          { key = "pets",           label = "Pets",            iconTex = 631719 },
          { key = "toys",           label = "Toys",            iconTex = 454046 },
      } },
    { key = "gearSets",    label = "Gear Sets",   iconAtlas = "equipmentmanager-spec-border" },
    { key = "currencies",  label = "Currencies",  iconTex = 136452,
      flyoutRadio = {
          dbKey = "currencyFilterMode",
          options = {
              { value = "warband", label = CURRENCY_FILTER_TYPE_TRANSFERABLE or "All Warband Transferable" },
              { value = "all",     label = (CURRENCY_FILTER_TYPE_CHARACTER and UnitName and UnitName("player")
                                           and CURRENCY_FILTER_TYPE_CHARACTER:format(UnitName("player")))
                                          or ((UnitName and UnitName("player") or "This Character") .. " Only") },
          },
          onChange = function(v) if UI.ApplyTokenFrameFilter then UI:ApplyTokenFrameFilter(v) end end,
      } },
    -- Gear: treasure-chest icon from the Encounter Journal loot tab
    -- spritesheet (texture 522972) for visual consistency with the
    -- in-game loot UI. hasFlyout flags the row to draw the chevron --
    -- the actual flyout (difficulty, spec, iLvl) is built inline below
    -- via gearOptionsPopup, not via flyoutSubFilters.
    { key = "loot",        label = "Gear",        iconTex = 522972,
      iconCoords = { 0.730, 0.824, 0.618, 0.660 }, hasFlyout = true },
    { key = "map",         label = "Map Search",  iconTex = 1121272,
      iconCoords = { 0.3457, 0.3856, 0.2549, 0.2951 },
      flyoutSubFilters = {
          { key = "zones",      label = "Zones",        dbTable = "mapTabFilters" },
          { key = "instances",  label = "Instances",    dbTable = "mapTabFilters" },
          { key = "flightpath", label = "Flight Paths", dbTable = "mapTabFilters" },
          { key = "travel",     label = "Travel",       dbTable = "mapTabFilters" },
          { key = "services",   label = "Services",     dbTable = "mapTabFilters" },
          { key = "rares",      label = "Rares",        dbTable = "mapTabFilters" },
      } },
    { key = "options",     label = "Options",     iconTex = 1121272,
      iconCoords = { 0.4451, 0.4705, 0.8079, 0.8344 },
      flyoutSubFilters = {
          { key = "gameOptions",  label = "Game Options",  iconAtlas = "QuestLog-icon-setting" },
          { key = "addonOptions", label = "AddOn Options", iconAtlas = "QuestLog-icon-setting", iconColor = { 1.0, 0.78, 0.35 } },
      } },
    { key = "reputations", label = "Reputations", iconTex = 1121272,
      iconCoords = { 0.3783, 0.4072, 0.9066, 0.9350 },
      flyoutRadio = {
          dbKey = "reputationFilterMode",
          options = {
              { value = "all",     label = "All" },
              { value = "warband", label = "Warband" },
              { value = "char",    label = (UnitName and UnitName("player")) or "This Character" },
          },
          onChange = function(v) if UI.ApplyReputationFilter then UI:ApplyReputationFilter(v) end end,
          checkboxes = {
              { dbKey = "showLegacyReputations", label = "Show Legacy Reputations",
                onChange = function(v) if UI.ApplyReputationShowLegacy then UI:ApplyReputationShowLegacy(v) end end },
          },
      } },
    -- Talents: leaf icon from the talents atlas spritesheet (4556093),
    -- visually consistent with the in-game talent tree.
    { key = "talents",     label = "Talents",     iconAtlas = "UI-HUD-MicroMenu-SpecTalents-Up" },
    -- Title icon from PaperDollSidebarTab2 (Titles tab) spritesheet 514608.
    { key = "titles",      label = "Titles",      iconTex = 514608,
      iconCoords = { 0.016, 0.531, 0.324, 0.461 } },
}

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

-- Module-level helpers for bucketing UI search results into optional
-- filter categories. Entries with no bucket are base UI search results
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
}

local function GetUIBucket(d)
    -- Returns one of the bucket keys for filtered non-collection /
    -- non-map UI entries, or nil for base entries / entries handled by
    -- a separate dedicated filter.
    if not d then return nil end
    if d.mountID or d.toyItemID or d.petID or d.outfitID or d.heirloomItemID
       or d.transmogSetID
       or (d.itemID and d.category == "Loot") or d.mapSearchResult then
        return nil
    end
    return UI_BUCKET_BY_CATEGORY[d.category]
end

function UI:GetUIBucket(data)
    return GetUIBucket(data)
end

function UI:IsGuildAchievementData(data)
    return data and data.isGuildAchievement == true
end

UI.quickFilterOptions = {
    { key = "abilities",      canonical = "abilities",       label = "Abilities",       categories = { "Ability" }, aliases = { "ab", "ability", "abilities", "spell", "spells" } },
    { key = "achievements",   canonical = "achievements",    label = "Achievements",    categories = { "Achievement", "Achievements", "Achievement Category", "Guild Achievements" }, aliases = { "a", "ach", "achievement", "achievements" } },
    { key = "statistics",     canonical = "statistics",      label = "Statistics",      categories = { "Statistic", "Statistics" }, aliases = { "s", "stat", "stats", "statistic", "statistics" } },
    { key = "bags",           canonical = "bags",            label = "Bags",            categories = { "Bag" }, aliases = { "b", "bag", "bags" } },
    { key = "bosses",         canonical = "bosses",          label = "Bosses",          categories = { "Boss" }, aliases = { "bo", "boss", "bosses", "encounter", "encounters" } },
    { key = "macros",         canonical = "macros",          label = "Macros",          categories = { "Macro" }, aliases = { "ma", "macro", "macros" } },
    { key = "collections",    canonical = "collections",     label = "Collections",     categories = { "Mount", "Toy", "Pet", "Outfit", "Heirloom", "Appearance Set" }, aliases = { "co", "col", "collection", "collections" } },
    { key = "appearanceSets", canonical = "appearance-sets", label = "Appearance Sets", categories = { "Appearance Set" }, aliases = { "as", "appearance", "appearances", "appearance-set", "appearance-sets", "appset", "appsets", "transmog" } },
    { key = "heirlooms",      canonical = "heirlooms",       label = "Heirlooms",       categories = { "Heirloom" }, aliases = { "h", "heirloom", "heirlooms" } },
    { key = "mounts",         canonical = "mounts",          label = "Mounts",          categories = { "Mount" }, aliases = { "m", "mount", "mounts" } },
    { key = "outfits",        canonical = "outfits",         label = "Outfits",         categories = { "Outfit" }, aliases = { "of", "outfit", "outfits" } },
    { key = "pets",           canonical = "pets",            label = "Pets",            categories = { "Pet" }, aliases = { "p", "pet", "pets" } },
    { key = "toys",           canonical = "toys",            label = "Toys",            categories = { "Toy" }, aliases = { "to", "toy", "toys" } },
    { key = "gearSets",       canonical = "gear-sets",       label = "Gear Sets",       categories = { "Gear Set" }, aliases = { "gs", "gearset", "gearsets", "gear-set", "gear-sets", "equipment-set", "equipment-sets" } },
    { key = "currencies",     canonical = "currencies",      label = "Currencies",      categories = { "Currency" }, aliases = { "c", "cur", "currency", "currencies" } },
    { key = "loot",           canonical = "gear",            label = "Gear",            categories = { "Loot" }, aliases = { "g", "gear", "loot", "item", "items" } },
    { key = "map",            canonical = "map",             label = "Map Search",      aliases = { "map", "maps", "zone", "zones", "location", "locations" } },
    { key = "options",        canonical = "options",         label = "Options",         categories = { "Game Settings", "AddOn Settings" }, aliases = { "op", "opt", "option", "options", "setting", "settings" } },
    { key = "gameOptions",    canonical = "game-options",    label = "Game Options",    categories = { "Game Settings" }, aliases = { "go", "game", "game-option", "game-options", "game-setting", "game-settings" } },
    { key = "addonOptions",   canonical = "addon-options",   label = "AddOn Options",   categories = { "AddOn Settings" }, aliases = { "ao", "addon", "addons", "addon-option", "addon-options", "addon-setting", "addon-settings" } },
    { key = "reputations",    canonical = "reputations",     label = "Reputations",     categories = { "Reputation" }, aliases = { "r", "rep", "reps", "reputation", "reputations" } },
    { key = "talents",        canonical = "talents",         label = "Talents",         categories = { "Talent" }, aliases = { "ta", "tal", "talent", "talents" } },
    { key = "titles",         canonical = "titles",          label = "Titles",          categories = { "Title" }, aliases = { "ti", "title", "titles" } },
}

UI.quickFilterByAlias = {}

for i = 1, #UI.quickFilterOptions do
    local def = UI.quickFilterOptions[i]
    def.order = i
    def.token = "@" .. def.canonical
    def.categoryLookup = {}
    if def.categories then
        for ci = 1, #def.categories do
            def.categoryLookup[def.categories[ci]] = true
        end
    end
    def.bucketLookup = { [def.key] = true }
    if def.key == "collections" then
        def.bucketLookup.mounts = true
        def.bucketLookup.toys = true
        def.bucketLookup.pets = true
        def.bucketLookup.outfits = true
        def.bucketLookup.heirlooms = true
        def.bucketLookup.appearanceSets = true
    elseif def.key == "options" then
        def.bucketLookup.gameOptions = true
        def.bucketLookup.addonOptions = true
    end
    UI.quickFilterByAlias[slower(def.canonical)] = def
    if def.aliases then
        for ai = 1, #def.aliases do
            UI.quickFilterByAlias[slower(def.aliases[ai])] = def
        end
    end
end

UI.quickFilterSuggestionBuf = {}
UI.quickFilterSuggestionEntries = {}
UI.quickFilterSuggestionData = {}

function UI:QuickFilterMatchRank(def, token)
    token = slower(token or "")
    if token == "" then
        if def.nestedParent then return nil end
        return 100 + (def.order or 0)
    end
    if slower(def.canonical) == token then return 0 end
    if def.aliases then
        for i = 1, #def.aliases do
            if slower(def.aliases[i]) == token then return 1 end
        end
    end
    if sfind(slower(def.canonical), token, 1, true) == 1 then return 10 + (def.order or 0) end
    if def.aliases then
        for i = 1, #def.aliases do
            if sfind(slower(def.aliases[i]), token, 1, true) == 1 then return 20 + (def.order or 0) end
        end
    end
    return nil
end

function UI:ResolveQuickFilterToken(token)
    if not token or token == "" then return nil end
    token = slower(token:gsub("^@", ""):gsub("_", "-"))
    local direct = UI.quickFilterByAlias[token]
    if direct then return direct end

    local found, matches = nil, 0
    for i = 1, #UI.quickFilterOptions do
        local def = UI.quickFilterOptions[i]
        local matched = sfind(slower(def.canonical), token, 1, true) == 1
        if not matched and def.aliases then
            for ai = 1, #def.aliases do
                if sfind(slower(def.aliases[ai]), token, 1, true) == 1 then
                    matched = true
                    break
                end
            end
        end
        if matched then
            found = def
            matches = matches + 1
            if matches > 1 then return nil end
        end
    end
    return found
end

function UI.QuickFilterSuggestionLess(a, b)
    if a.rank == b.rank then
        return (a.def.order or 0) < (b.def.order or 0)
    end
    return a.rank < b.rank
end

function UI:GetQuickFilter()
    return self._quickFilter
end

function UI:GetQuickFilterCompletionToken(def, typed)
    if not def then return nil end
    typed = slower(typed or "")
    local tokens = def.completionTokens
    if tokens then
        for i = 1, #tokens do
            local token = tokens[i]
            if token and #token >= #typed
               and slower(token:sub(1, #typed)) == typed
               and slower(token) ~= typed then
                return token
            end
        end
    end
    local token = def.token
    if token and #token >= #typed
       and slower(token:sub(1, #typed)) == typed
       and slower(token) ~= typed then
        return token
    end
    return nil
end

function UI:GetQuickFilterDisplayToken(def)
    if not def then return "" end
    if def.displayToken then return def.displayToken end

    local alias = def.canonical
    local aliasLen = #(alias or "")
    if def.aliases then
        for i = 1, #def.aliases do
            local candidate = def.aliases[i]
            if candidate and #candidate < aliasLen then
                alias = candidate
                aliasLen = #candidate
            end
        end
    end
    def.displayToken = "@" .. (alias or def.canonical)
    return def.displayToken
end

function UI:GetQuickFilterAliasText(def)
    if not def then return "Quick Filter" end
    if def.aliasText then return def.aliasText end
    def.aliasText = (def.label or "Quick Filter")
    return def.aliasText
end

function UI:QuickFilterAllowsData(data, quickFilter)
    local def = quickFilter or self._quickFilter
    if not def then return true end
    if not data or data.calculatorResult or data.calculatorLauncher or data.searchCommand then return false end

    if data.mapSearchResult then return def.key == "map" end
    if def.key == "map" then return false end
    if EasyFind.db.hideAchievementHeaders and data.category == "Achievement Category" then return false end
    if EasyFind.db.hideGuildAchievements and self:IsGuildAchievementData(data) then return false end
    if data.mountID and ns.Database and ns.Database.MountPassesSearchFilters
       and not ns.Database:MountPassesSearchFilters(data) then
        return false
    end

    if def.key == "mounts" then return data.mountID and true or false end
    if def.key == "toys" then return data.toyItemID and true or false end
    if def.key == "pets" then return data.petID and true or false end
    if def.key == "outfits" then return data.outfitID and true or false end
    if def.key == "heirlooms" then return data.heirloomItemID and true or false end
    if def.key == "appearanceSets" then return data.transmogSetID and true or false end
    if def.key == "collections" then
        return (data.mountID or data.toyItemID or data.petID or data.outfitID
            or data.heirloomItemID or data.transmogSetID) and true or false
    end
    if def.key == "loot" then
        return (data.itemID and data.category == "Loot") and true or false
    end

    if data.category and def.categoryLookup and def.categoryLookup[data.category] then
        return true
    end
    local bucket = GetUIBucket(data)
    return bucket and def.bucketLookup and def.bucketLookup[bucket] or false
end

function UI:SetQuickFilterPillFill(frame, r, g, b, a)
    ns.SetRoundedRectFill(frame, r, g, b, a, true)
end

function UI:HideQuickFilterPillBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
end

function UI:CreateQuickFilterPill(frame, editBox, iconHolder, filterBtn)
    if not frame or frame.quickFilterPill then return end
    local pill = CreateFrame("Button", "EasyFindQuickFilterPill", frame)
    pill:SetFrameLevel(frame:GetFrameLevel() + 35)
    pill:SetHeight(mmax(18, (editBox and editBox:GetHeight() or 20) - 3))
    pill:SetPoint("LEFT", iconHolder, "RIGHT", 2, 0)
    pill:EnableMouse(true)
    ns.CreateRoundedRectBorder(pill)
    ns.SetRoundedRectBarHeight(pill, 10)
    ns.SetRoundedRectBorderBgAlpha(pill, 1)
    self:HideQuickFilterPillBorder(pill)
    self:SetQuickFilterPillFill(pill, 0.095, 0.095, 0.108, 1)

    local text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -8, 0)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(false)
    text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
    pill.text = text

    pill:SetScript("OnClick", function()
        UI:ClearQuickFilter(true)
        if editBox then
            editBox.blockFocus = nil
            editBox:SetFocus()
        end
    end)
    pill:SetScript("OnEnter", function(self)
        UI:SetQuickFilterPillFill(self, 0.155, 0.155, 0.172, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Quick Filter")
        GameTooltip:AddLine("Click or press Backspace on an empty search to clear.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pill:SetScript("OnLeave", function(self)
        UI:SetQuickFilterPillFill(self, 0.095, 0.095, 0.108, 1)
        GameTooltip_Hide()
    end)
    pill:Hide()

    frame.quickFilterPill = pill
    frame.quickFilterEditBox = editBox
    frame.quickFilterIconHolder = iconHolder
    frame.quickFilterFilterBtn = filterBtn
end

function UI:UpdateQuickFilterPill()
    local frame = UI:GetSearchFrame()
    if not frame or not frame.quickFilterEditBox then return end
    local editBox = frame.quickFilterEditBox
    local iconHolder = frame.quickFilterIconHolder
    local filterBtn = frame.quickFilterFilterBtn
    local pill = frame.quickFilterPill
    local active = self._quickFilter

    editBox:ClearAllPoints()
    if active and pill then
        pill.text:SetText(active.token)
        local w = (pill.text:GetStringWidth() or 0) + 18
        pill:SetWidth(mmax(52, w))
        pill:Show()
        editBox:SetPoint("LEFT", pill, "RIGHT", 5, 0)
    else
        if pill then pill:Hide() end
        editBox:SetPoint("LEFT", iconHolder, "RIGHT", 0, 0)
    end
    if filterBtn then
        editBox:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
    else
        editBox:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    end
end

function UI:HideQuickFilterSuggestions()
    self._quickFilterSuggestionsActive = nil
    self._quickFilterFirstSuggestion = nil
end

function UI:GetQuickFilterSuggestionEntries(token)
    local suggestions = self.quickFilterSuggestionBuf
    wipe(suggestions)
    local n = 0
    token = (token or ""):gsub("_", "-")
    for i = 1, #self.quickFilterOptions do
        local def = self.quickFilterOptions[i]
        local rank = self:QuickFilterMatchRank(def, token)
        if rank then
            n = n + 1
            local item = suggestions[n] or {}
            item.def = def
            item.rank = rank
            suggestions[n] = item
        end
    end
    for i = n + 1, #suggestions do suggestions[i] = nil end
    if n == 0 then return nil end
    tsort(suggestions, UI.QuickFilterSuggestionLess)

    local entries = self.quickFilterSuggestionEntries
    local dataPool = self.quickFilterSuggestionData
    for i = 1, n do
        local def = suggestions[i].def
        local data = dataPool[i]
        if not data then
            data = {}
            dataPool[i] = data
        end
        wipe(data)
        data.name = self:GetQuickFilterDisplayToken(def)
        data.nameLower = slower(data.name)
        data.category = "Quick Filter"
        data.noPin = true
        data.quickFilterDef = def
        data.quickFilterAliasText = self:GetQuickFilterAliasText(def)

        local entry = entries[i]
        if not entry then
            entry = {}
            entries[i] = entry
        end
        entry.name = data.name
        entry.depth = 0
        entry.isPathNode = false
        entry.isMatch = true
        entry.isFlat = true
        entry.flatCatKey = nil
        entry.isPinned = false
        entry.data = data
    end
    for i = n + 1, #entries do entries[i] = nil end
    for i = n + 1, #dataPool do dataPool[i] = nil end
    return entries, suggestions[1].def
end

function UI:UpdateQuickFilterSuggestions(editBox)
    if self._quickFilter then
        self:HideQuickFilterSuggestions()
        return false
    end
    editBox = editBox or (UI:GetSearchFrame() and UI:GetSearchFrame().editBox)
    if not editBox then return false end

    local cursor = editBox:GetCursorPosition() or #(editBox:GetText() or "")
    local typed = (editBox:GetText() or ""):sub(1, cursor)
    local token = typed:match("^%s*@([%w_%-:]*)$")
    if not token then
        self:HideQuickFilterSuggestions()
        return false
    end

    local entries, firstDef = self:GetQuickFilterSuggestionEntries(token)
    self._quickFilterSuggestionsActive = true
    self._quickFilterFirstSuggestion = firstDef
    if entries then
        self:ShowHierarchicalResults(entries)
    else
        self:HideResults()
    end
    return true
end

function UI:GetSelectedQuickFilterSuggestion()
    if UI:GetSelectedIndex() > 0 then
        local row = UI:GetResultButtons()[UI:GetSelectedIndex()]
        local def = row and row:IsShown() and row.data and row.data.quickFilterDef
        if def then return def end
    end
    return self._quickFilterFirstSuggestion
end

function UI:AcceptQuickFilterSuggestion()
    if not self._quickFilterSuggestionsActive then return false end
    local def = self:GetSelectedQuickFilterSuggestion()
    if not def then return false end
    return self:ApplyQuickFilter(def, "")
end

function UI:ApplyQuickFilter(def, remainingText)
    if not def then return false end
    self._quickFilter = def
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()

    local editBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
    remainingText = remainingText or ""
    if editBox then
        if editBox and editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        editBox:SetText(remainingText)
        editBox:SetCursorPosition(#remainingText)
        if editBox.placeholder then editBox.placeholder:SetShown(remainingText == "") end
        editBox.blockFocus = nil
        editBox:SetFocus()
    end
    self:OnSearchTextChanged(remainingText, true)
    return true
end

function UI:ClearQuickFilter(refresh)
    if not self._quickFilter then return false end
    self._quickFilter = nil
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()
    if refresh then
        local editBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
        self:OnSearchTextChanged(editBox and editBox:GetText() or "", true)
    end
    return true
end

function UI:TryAcceptQuickFilterToken(editBox, includeWhitespace)
    if self._quickFilter or not editBox then return false end
    local text = editBox:GetText() or ""
    local hasAutocomplete = editBox.HasAutocomplete and editBox:HasAutocomplete()
    local cursor = editBox:GetCursorPosition() or #text
    local before = text:sub(1, cursor)
    local token, after
    if includeWhitespace then
        token, after = before:match("^%s*@([%w_%-:]+)%s+(.*)$")
    else
        token = before:match("^%s*@([%w_%-:]+)$")
    end
    if not token then return false end

    local def = self:ResolveQuickFilterToken(token)
    if not def then return false end
    local remaining
    if includeWhitespace then
        remaining = (after or "") .. text:sub(cursor + 1)
    elseif hasAutocomplete then
        remaining = ""
    else
        remaining = text:sub(cursor + 1)
    end
    remaining = remaining:gsub("^%s+", "")
    return self:ApplyQuickFilter(def, remaining)
end

function UI:HandleQuickFilterTextChanged(editBox)
    if self:TryAcceptQuickFilterToken(editBox, true) then return true end
    if self:UpdateQuickFilterSuggestions(editBox) then
        if editBox and editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        if editBox and editBox.UpdateAutocomplete then
            local box = editBox
            Utils.SafeAfter(0, function()
                if box and box:IsVisible() and box:HasFocus()
                   and UI._quickFilterSuggestionsActive
                   and box.UpdateAutocomplete then
                    box.UpdateAutocomplete()
                end
            end)
        end
        return true
    end
    return false
end

function UI:HandleQuickFilterSuggestionBackspace(editBox)
    if not (self._quickFilterSuggestionsActive and editBox) then return false end

    if editBox.StripAutocomplete then
        editBox:StripAutocomplete()
    end

    local text = editBox:GetText() or ""
    local cursor = editBox:GetCursorPosition() or #text
    if cursor <= 0 then return false end

    local before = text:sub(1, cursor)
    if not before:match("^%s*@[%w_%-:]*$") then return false end

    local newBefore = before:sub(1, -2)
    local newText = newBefore .. text:sub(cursor + 1)
    local function applyBackspace()
        if not editBox then return end
        if editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        editBox:SetText(newText)
        editBox:SetCursorPosition(#newBefore)
        editBox:HighlightText(0, 0)
        if editBox.placeholder then
            editBox.placeholder:SetShown(newText == "")
        end

        if not UI:UpdateQuickFilterSuggestions(editBox) then
            UI:OnSearchTextChanged(newText, true)
        end
    end

    if Utils and Utils.SafeAfter then
        Utils.SafeAfter(0, applyBackspace)
    else
        applyBackspace()
    end
    return true
end

function UI:HandleQuickFilterKeyDown(editBox, key)
    if key == "BACKSPACE" and self._quickFilter and editBox
       and (editBox:GetText() or "") == "" then
        return self:ClearQuickFilter(true)
    end
    if key == "BACKSPACE" and self:HandleQuickFilterSuggestionBackspace(editBox) then
        return true
    end

    if self._quickFilterSuggestionsActive and key == "TAB" then
        if editBox and editBox.HasAutocomplete and editBox:HasAutocomplete()
           and editBox.AcceptAutocomplete
           and editBox:AcceptAutocomplete("tab") then
            return self:TryAcceptQuickFilterToken(editBox, false) or true
        end
        return self:AcceptQuickFilterSuggestion()
    end
    if self._quickFilterSuggestionsActive and key == "ENTER" then
        return self:AcceptQuickFilterSuggestion()
    end
    if key == "SPACE" then
        if self:TryAcceptQuickFilterToken(editBox, false) then
            self:SuppressQuickFilterLeakedText(" ")
            return true
        end
        if self._quickFilterSuggestionsActive then
            if self:AcceptQuickFilterSuggestion() then
                self:SuppressQuickFilterLeakedText(" ")
                return true
            end
        end
    end
    return false
end

function UI:QuickFilterNeedsHeavyData(def)
    return def and (def.key == "loot" or def.key == "bosses")
end

local MOUNT_SOURCE_FALLBACK_LABELS = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "Profession",
    [5] = "Achievement",
    [6] = "World Event",
    [7] = "Promotion",
    [8] = "Trading Post",
    [9] = "Discovery",
}

local function MountSourceLabel(sourceType)
    return _G["MOUNT_JOURNAL_FILTER_SOURCE_" .. tostring(sourceType)]
        or _G["MOUNT_JOURNAL_FILTER_" .. tostring(sourceType)]
        or _G["BATTLE_PET_SOURCE_" .. tostring(sourceType)]
        or MOUNT_SOURCE_FALLBACK_LABELS[sourceType]
        or ("Source " .. tostring(sourceType))
end

local function SortMountSourceDefs(a, b)
    if a.sourceType ~= b.sourceType then return a.sourceType < b.sourceType end
    return a.label < b.label
end

local cachedMountSourceDefs
local function CollectMountSourceDefs()
    if cachedMountSourceDefs then return cachedMountSourceDefs end
    local seen = {}
    local defs = {}
    if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
        local mountIDs = C_MountJournal.GetMountIDs()
        if mountIDs then
            for i = 1, #mountIDs do
                local sourceType = select(6, C_MountJournal.GetMountInfoByID(mountIDs[i]))
                if sourceType and not seen[sourceType] then
                    seen[sourceType] = true
                    defs[#defs + 1] = { sourceType = sourceType, label = MountSourceLabel(sourceType) }
                end
            end
        end
    end
    tsort(defs, SortMountSourceDefs)
    cachedMountSourceDefs = defs
    return defs
end

local mountSourceInvalidator
local function EnsureMountSourceInvalidator()
    if mountSourceInvalidator then return end
    mountSourceInvalidator = CreateFrame("Frame")
    mountSourceInvalidator:RegisterEvent("NEW_MOUNT_ADDED")
    mountSourceInvalidator:SetScript("OnEvent", function()
        cachedMountSourceDefs = nil
    end)
end

function UI:BuildMountOptionsPopup(StylePopup, ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox)
    local OPTIONS_WIDTH = 160
    local SOURCE_WIDTH = 170
    local ROW_H = 22
    local PAD = 6
    local HEADER_H = 20

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("mounts")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            UI:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    EnsureMountSourceInvalidator()

    local optionsPopup = CreateFrame("Frame", "EasyFindMountOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    local sourcePopup = CreateFrame("Frame", "EasyFindMountSourcePopup", UIParent, "BackdropTemplate")
    sourcePopup:SetFrameStrata("TOOLTIP")
    sourcePopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(sourcePopup)
    sourcePopup:EnableMouse(true)
    sourcePopup:Hide()

    local sourceRows = {}
    local function EnsureSourceFilters()
        EasyFind.db.mountSourceFilters = EasyFind.db.mountSourceFilters or {}
        return EasyFind.db.mountSourceFilters
    end

    local function CreatePlainRow(parent, text)
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(SOURCE_WIDTH - PAD * 2, ROW_H)
        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", 14, 0)
        label:SetText(text)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        return row
    end

    local checkAllRow = CreatePlainRow(sourcePopup, _G["CHECK_ALL"] or "Check All")
    local uncheckAllRow = CreatePlainRow(sourcePopup, _G["UNCHECK_ALL"] or "Uncheck All")

    local function LayoutSourcePopup()
        local defs = CollectMountSourceDefs()
        local filters = EnsureSourceFilters()
        checkAllRow:ClearAllPoints()
        checkAllRow:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -PAD)
        uncheckAllRow:ClearAllPoints()
        uncheckAllRow:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -(PAD + ROW_H))

        for i = #sourceRows, #defs + 1, -1 do
            sourceRows[i]:Hide()
        end
        for i, def in ipairs(defs) do
            local row = sourceRows[i]
            if not row then
                row = CreateFrame("CheckButton", nil, sourcePopup)
                row:SetSize(SOURCE_WIDTH - PAD * 2, ROW_H)
                row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                row:GetNormalTexture():ClearAllPoints()
                row:GetNormalTexture():SetPoint("LEFT", 4, 0)
                row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                row:GetCheckedTexture():ClearAllPoints()
                row:GetCheckedTexture():SetPoint("LEFT", 4, 0)
                row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                row.text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
                local hl = row:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                row:SetScript("OnClick", function(self)
                    EnsureSourceFilters()[self.sourceType] = self:GetChecked() and nil or false
                    ApplyFilterSelection()
                end)
                sourceRows[i] = row
            end
            row.sourceType = def.sourceType
            row.text:SetText(def.label)
            row:SetChecked(filters[def.sourceType] ~= false)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -(PAD + (i + 1) * ROW_H))
            row:Show()
        end
        sourcePopup:SetSize(SOURCE_WIDTH, PAD * 2 + (2 + #defs) * ROW_H)
    end

    checkAllRow:SetScript("OnClick", function()
        wipe(EnsureSourceFilters())
        LayoutSourcePopup()
        ApplyFilterSelection()
    end)
    uncheckAllRow:SetScript("OnClick", function()
        local filters = EnsureSourceFilters()
        for _, def in ipairs(CollectMountSourceDefs()) do
            filters[def.sourceType] = false
        end
        LayoutSourcePopup()
        ApplyFilterSelection()
    end)

    local function CreateCheckRow(def, y)
        local row = CreateFrame("CheckButton", nil, optionsPopup)
        row:SetSize(OPTIONS_WIDTH - PAD * 2, ROW_H)
        row:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)
        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        text:SetText(def.label)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        row.dbKey = def.dbKey
        row:SetScript("OnClick", function(self)
            EasyFind.db[self.dbKey] = self:GetChecked() and true or false
            ApplyFilterSelection()
        end)
        return row
    end

    local rows = {}
    local y = -PAD
    local filterDefs = {
        { dbKey = "mountFilterCollected",    label = _G["COLLECTED"] or "Collected" },
        { dbKey = "mountFilterNotCollected", label = _G["NOT_COLLECTED"] or "Not Collected" },
        { dbKey = "mountFilterUnusable",     label = _G["UNUSABLE"] or "Unusable" },
    }
    for _, def in ipairs(filterDefs) do
        rows[#rows + 1] = CreateCheckRow(def, y)
        y = y - ROW_H
    end

    local typeHeader = optionsPopup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    typeHeader:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 8, y - 2)
    typeHeader:SetText(_G["TYPE"] or "Type")
    y = y - HEADER_H

    local typeDefs = {
        { dbKey = "mountTypeGround",    label = _G["GROUND"] or "Ground" },
        { dbKey = "mountTypeFlying",    label = _G["FLYING"] or "Flying" },
        { dbKey = "mountTypeAquatic",   label = _G["AQUATIC"] or "Aquatic" },
        { dbKey = "mountTypeRideAlong", label = _G["RIDE_ALONG"] or "Ride Along" },
    }
    for _, def in ipairs(typeDefs) do
        rows[#rows + 1] = CreateCheckRow(def, y)
        y = y - ROW_H
    end

    local sourcesRow = CreateFrame("Button", nil, optionsPopup)
    sourcesRow:SetSize(OPTIONS_WIDTH - PAD * 2, ROW_H)
    sourcesRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
    local sourcesText = sourcesRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sourcesText:SetPoint("LEFT", 14, 0)
    sourcesText:SetText(_G["SOURCES"] or "Sources")
    local sourceChev = sourcesRow:CreateTexture(nil, "OVERLAY")
    sourceChev:SetAtlas("common-icon-forwardarrow")
    sourceChev:SetSize(CHECK_SIZE, CHECK_SIZE)
    sourceChev:SetPoint("RIGHT", -4, 0)
    local sourceHL = sourcesRow:CreateTexture(nil, "HIGHLIGHT")
    sourceHL:SetAllPoints()
    sourceHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

    optionsPopup:SetSize(OPTIONS_WIDTH, PAD * 2 + #filterDefs * ROW_H + HEADER_H + #typeDefs * ROW_H + ROW_H)

    local sourceHideTimer
    local function HideSourceNow()
        if sourcePopup:IsMouseOver() or sourcesRow:IsMouseOver() then return end
        sourcePopup:Hide()
    end
    local function ScheduleHideSource()
        if sourceHideTimer then sourceHideTimer:Cancel() end
        sourceHideTimer = C_Timer.NewTimer(0.15, function()
            sourceHideTimer = nil
            HideSourceNow()
        end)
    end
    local function ShowSourcePopup()
        if sourceHideTimer then sourceHideTimer:Cancel(); sourceHideTimer = nil end
        LayoutSourcePopup()
        sourcePopup:SetScale(optionsPopup:GetScale())
        sourcePopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 10)
        sourcePopup:ClearAllPoints()
        sourcePopup:SetPoint("TOPLEFT", sourcesRow, "TOPRIGHT", 4, 0)
        sourcePopup:Show()
    end
    sourcesRow:SetScript("OnEnter", ShowSourcePopup)
    sourcesRow:SetScript("OnLeave", ScheduleHideSource)
    sourcePopup:HookScript("OnEnter", function()
        if sourceHideTimer then sourceHideTimer:Cancel(); sourceHideTimer = nil end
    end)
    sourcePopup:HookScript("OnLeave", ScheduleHideSource)

    local function SyncOptions()
        for _, row in ipairs(rows) do
            row:SetChecked(EasyFind.db[row.dbKey] ~= false)
        end
        LayoutSourcePopup()
    end

    optionsPopup:HookScript("OnHide", function() sourcePopup:Hide() end)
    return optionsPopup, SyncOptions, sourcePopup
end

-- Builds the Appearance Sets options popup: a class selector button +
-- four checkboxes (Collected, Not Collected, PvE, PvP). Returns the
-- popup frame and a sync function that re-reads EasyFind.db state.
-- Caller positions/shows the popup and decides when to call sync.
function UI:BuildAppearanceSetOptionsPopup(StylePopup, CreateRadioTexture,
        ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox)
    local FLYOUT_ROW_H = 20
    local CLASSPOPUP_WIDTH = 160
    local OPTIONS_WIDTH = 160
    local CB_ROW_H = 22
    local CLASS_BTN_H = 27
    local PAD = 6

    local CLASS_COLORS = RAID_CLASS_COLORS
    local classes = {}
    for classIdx = 1, GetNumClasses() do
        local className, classFile, classID = GetClassInfo(classIdx)
        if className and classFile then
            classes[#classes + 1] = {
                classID = classID, className = className, classFile = classFile,
            }
        end
    end

    local function ClassColorString(classFile)
        local c = CLASS_COLORS[classFile]
        return c and string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) or ""
    end

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("transmogSets")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            UI:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindAsOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    local classBtn = CreateFrame("Button", nil, optionsPopup)
    classBtn:SetSize(OPTIONS_WIDTH - PAD * 2, CLASS_BTN_H)
    classBtn:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, -PAD)
    local cbBg = classBtn:CreateTexture(nil, "BACKGROUND")
    cbBg:SetAtlas("common-dropdown-textholder")
    cbBg:SetAllPoints()
    local cbArrow = classBtn:CreateTexture(nil, "OVERLAY")
    cbArrow:SetAtlas("common-dropdown-a-button-hover")
    cbArrow:SetSize(20, 20)
    cbArrow:SetPoint("RIGHT", -2, -1)
    cbArrow:SetVertexColor(0.7, 0.7, 0.7)
    local cbLabel = classBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    cbLabel:SetPoint("LEFT", 8, 0)
    cbLabel:SetPoint("RIGHT", cbArrow, "LEFT", -2, 0)
    cbLabel:SetJustifyH("LEFT")
    cbLabel:SetWordWrap(false)
    classBtn:SetScript("OnEnter", function() cbArrow:SetVertexColor(1, 1, 1) end)
    classBtn:SetScript("OnLeave", function() cbArrow:SetVertexColor(0.7, 0.7, 0.7) end)

    local function UpdateClassLabel()
        local cf = EasyFind.db.appearanceSetClass
        if not cf then
            local _, _, cid = UnitClass("player")
            for _, cls in ipairs(classes) do
                if cls.classID == cid then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        elseif cf == "all" then
            cbLabel:SetText("All Classes")
            return
        elseif type(cf) == "table" and cf.classID then
            for _, cls in ipairs(classes) do
                if cls.classID == cf.classID then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        end
        cbLabel:SetText("All Classes")
    end
    UpdateClassLabel()

    -- Class popup (opens to the right of the class button)
    local classPopup = CreateFrame("Frame", "EasyFindAsClassPopup", UIParent, "BackdropTemplate")
    classPopup:SetFrameStrata("TOOLTIP")
    classPopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(classPopup)
    classPopup:EnableMouse(true)
    classPopup:Hide()
    classPopup:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() and not classBtn:IsMouseOver()
                and not optionsPopup:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    local classRows = {}
    local allRow = CreateFrame("Button", nil, classPopup)
    allRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
    allRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
    local allRadio, allSetRadio = CreateRadioTexture(allRow)
    allRadio:SetPoint("LEFT", 4, 0)
    local allLbl = allRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    allLbl:SetPoint("LEFT", allRadio, "RIGHT", 4, 0)
    allLbl:SetText("All Classes")
    local allHL = allRow:CreateTexture(nil, "HIGHLIGHT")
    allHL:SetAllPoints()
    allHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
    allRow._setRadioChecked = allSetRadio
    allRow._classID = nil
    allRow:SetScript("OnClick", function()
        EasyFind.db.appearanceSetClass = "all"
        UpdateClassLabel()
        classPopup:Hide()
        ApplyFilterSelection()
    end)
    classRows[#classRows + 1] = allRow

    for _, cls in ipairs(classes) do
        local clsRow = CreateFrame("Button", nil, classPopup)
        clsRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
        clsRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
        local cRadio, cSetRadio = CreateRadioTexture(clsRow)
        cRadio:SetPoint("LEFT", 4, 0)
        local cLbl = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        cLbl:SetPoint("LEFT", cRadio, "RIGHT", 4, 0)
        cLbl:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
        local cHL = clsRow:CreateTexture(nil, "HIGHLIGHT")
        cHL:SetAllPoints()
        cHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        clsRow._setRadioChecked = cSetRadio
        clsRow._classID = cls.classID
        clsRow:SetScript("OnClick", function()
            EasyFind.db.appearanceSetClass = { classID = cls.classID }
            UpdateClassLabel()
            classPopup:Hide()
            ApplyFilterSelection()
        end)
        classRows[#classRows + 1] = clsRow
    end

    local function LayoutClassPopup()
        local py = -6
        local cf = EasyFind.db.appearanceSetClass
        for _, r in ipairs(classRows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", classPopup, "TOPLEFT", 8, py)
            r:Show()
            if r._setRadioChecked then
                local match = false
                if not r._classID then
                    match = cf == "all"
                else
                    if type(cf) == "table" and cf.classID == r._classID then
                        match = true
                    elseif not cf then
                        local _, _, cid = UnitClass("player")
                        match = r._classID == cid
                    end
                end
                r._setRadioChecked(match)
            end
            py = py - FLYOUT_ROW_H
        end
        classPopup:SetSize(CLASSPOPUP_WIDTH, -py + 6)
    end

    classBtn:SetScript("OnClick", function(self)
        if classPopup:IsShown() then
            classPopup:Hide()
            return
        end
        LayoutClassPopup()
        classPopup:SetScale(optionsPopup:GetScale())
        classPopup:ClearAllPoints()
        classPopup:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
        classPopup:Show()
    end)

    local filterDefs = {
        { dbKey = "appearanceSetCollected",     label = "Collected" },
        { dbKey = "appearanceSetNotCollected",  label = "Not Collected" },
        { dbKey = "appearanceSetPvE",           label = "PvE" },
        { dbKey = "appearanceSetPvP",           label = "PvP" },
    }

    local cbRows = {}
    local cy = -(PAD + CLASS_BTN_H + 6)
    for si, def in ipairs(filterDefs) do
        local cbRow = CreateFrame("CheckButton", nil, optionsPopup)
        cbRow:SetSize(OPTIONS_WIDTH - PAD * 2, CB_ROW_H)
        cbRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, cy)

        cbRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cbRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetNormalTexture():ClearAllPoints()
        cbRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

        cbRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cbRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetCheckedTexture():ClearAllPoints()
        cbRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local cbText = cbRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        cbText:SetPoint("LEFT", cbRow:GetNormalTexture(), "RIGHT", 4, 0)
        cbText:SetText(def.label)

        local cbHL = cbRow:CreateTexture(nil, "HIGHLIGHT")
        cbHL:SetAllPoints()
        cbHL:SetColorTexture(1, 1, 1, 0.1)

        local val = EasyFind.db[def.dbKey]
        if val == nil then val = true end
        cbRow:SetChecked(val)
        cbRow.dbKey = def.dbKey

        cbRow:SetScript("OnClick", function(self)
            EasyFind.db[def.dbKey] = self:GetChecked()
            ApplyFilterSelection()
        end)

        cbRows[si] = cbRow
        cy = cy - CB_ROW_H
        if si == 2 then
            local sep = optionsPopup:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 4, cy + 2)
            sep:SetPoint("TOPRIGHT", optionsPopup, "TOPRIGHT", -(PAD + 4), cy + 2)
            sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            cy = cy - 6
        end
    end
    optionsPopup:SetSize(OPTIONS_WIDTH, -cy + PAD)

    optionsPopup:HookScript("OnHide", function() classPopup:Hide() end)

    -- Outside-click: close immediately when the user clicks anywhere
    -- that isn't this popup or its nested class popup. The owning
    -- sub-row hover handler is responsible for re-showing on rehover.
    optionsPopup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self._owningRow and self._owningRow:IsMouseOver() then return end
        if classPopup:IsShown() and classPopup:IsMouseOver() then return end
        self:Hide()
    end)

    local function SyncFromDB()
        for _, sr in ipairs(cbRows) do
            if sr.dbKey then
                sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
            end
        end
        UpdateClassLabel()
    end

    return optionsPopup, SyncFromDB
end

function UI:CreateUIFilterDropdown(toggleBtn, anchorFrame, searchEditBox)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    -- Single source of truth for which side-flyout (sub-filters / radio /
    -- gear options) is currently visible. Any popup that opens hides
    -- whatever was active so sweeping between rows can never leave a
    -- previous flyout lingering, even rows whose popup wasn't tracked
    -- in dropdown.flyoutPopups.
    local activeFlyoutPopup
    local function SetActiveFlyout(popup)
        if activeFlyoutPopup and activeFlyoutPopup ~= popup and activeFlyoutPopup:IsShown() then
            activeFlyoutPopup:Hide()
        end
        activeFlyoutPopup = popup
    end
    local function ClearActiveFlyout(popup)
        if activeFlyoutPopup == popup then activeFlyoutPopup = nil end
    end

    local dropdown = CreateFrame("Frame", "EasyFindUIFilterDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    -- Bump everything in the filter menu uniformly: 1.5x larger fonts,
    -- icons, paddings, and row heights without rewriting the hardcoded
    -- pixel sizes scattered through the row builders.
    dropdown:SetScale(1.5)
    dropdown:Hide()
    dropdown:EnableMouse(true)
    -- Popups that should prevent the dropdown from closing on outside-click.
    -- Each sub-filter registers its popups here instead of hardcoding frame names.
    -- Stashed on the dropdown so the search bar's autoHide handler can also
    -- consult it (otherwise clicks inside a flyout dismiss the bar).
    local dropdownGuardFrames = {}
    dropdown.guardFrames = dropdownGuardFrames
    dropdown:SetClampedToScreen(true)

    local function KeepSearchEditBoxUnfocused()
        if searchEditBox and searchEditBox.ClearFocus then searchEditBox:ClearFocus() end
    end

    dropdown:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local ICON_SIZE = 14

    local RADIO_SIZE = 14
    local RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\Images\\radio-off"
    local RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\Images\\radio-on"
    local POPUP_BG_COLOR = { 0.05, 0.05, 0.05, 0.95 }
    local POPUP_BORDER_COLOR = { 0.6, 0.6, 0.6, 1 }
    local POPUP_BACKDROP = {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }
    local ROW_HIGHLIGHT_COLOR = { 1, 1, 1, 0.1 }

    local function StylePopup(frame)
        frame:SetBackdrop(POPUP_BACKDROP)
        frame:SetBackdropColor(unpack(POPUP_BG_COLOR))
        frame:SetBackdropBorderColor(unpack(POPUP_BORDER_COLOR))
    end

    local function CreateRadioTexture(parent)
        local tex = parent:CreateTexture(nil, "ARTWORK")
        tex:SetSize(RADIO_SIZE, RADIO_SIZE)
        tex:SetTexture(RADIO_OFF_TEX)
        local function SetChecked(checked)
            tex:SetTexture(checked and RADIO_ON_TEX or RADIO_OFF_TEX)
        end
        return tex, SetChecked
    end

    local uncheckRow = CreateFrame("Button", nil, dropdown)
    uncheckRow:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
    uncheckRow:SetPoint("TOPLEFT", 8, -PADDING_TOP)
    local uncheckLabel = uncheckRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    uncheckLabel:SetPoint("LEFT", 8, 0)
    uncheckLabel:SetText("Toggle All")
    local uncheckHL = uncheckRow:CreateTexture(nil, "HIGHLIGHT")
    uncheckHL:SetAllPoints()
    uncheckHL:SetColorTexture(1, 1, 1, 0.1)

    local checkRows = {}
    local checkRowsByIndex = {}
    local LayoutDropdown  -- forward declaration
    local dropdownKeyboardMode = false

    -- Reusable keyboard nav for popup menus (diff popup, spec popup, class flyout).
    -- Uses a single dropdownKeyboardMode flag: when true, any popup hiding returns
    -- keyboard to the dropdown. No parent tracking needed.
    local function AddPopupKeyboardNav(popup, getRows)
        local popupFocus = 0
        local popupHL = popup:CreateTexture(nil, "BACKGROUND")
        popupHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        popupHL:Hide()

        local function SetPopupFocus(idx)
            local rows = getRows()
            popupFocus = idx
            local target = rows[idx]
            if target then
                popupHL:SetParent(target)
                popupHL:ClearAllPoints()
                popupHL:SetAllPoints(target)
                popupHL:Show()
            else
                popupHL:Hide()
            end
        end

        Utils.SafeCallMethod(popup, "EnableKeyboard", false)
        Utils.SafeCallMethod(popup, "SetPropagateKeyboardInput", false)

        popup:HookScript("OnKeyDown", function(self, key)
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            local rows = getRows()
            if key == "DOWN" then
                UI:GetSearchFrame().StartKeyRepeat(key, function()
                    local r = getRows()
                    local next = popupFocus + 1
                    if next > #r then next = 1 end
                    SetPopupFocus(next)
                end)
            elseif key == "UP" then
                UI:GetSearchFrame().StartKeyRepeat(key, function()
                    local r = getRows()
                    local prev = popupFocus - 1
                    if prev < 1 then prev = #r end
                    SetPopupFocus(prev)
                end)
            elseif key == "ENTER" then
                local target = rows[popupFocus]
                if target and target.Click then target:Click() end
            elseif key == "ESCAPE" then
                -- Route through HandleEscape: closes the parent dropdown
                -- and any sibling popups together, refocuses editbox.
                -- Bare self:Hide() only hits this popup and leaves the
                -- main dropdown / nested popups behind.
                UI:HandleEscape()
            else
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            end
        end)
        popup:HookScript("OnKeyUp", function(_, key)
            if UI:GetSearchFrame().IsRepeatKey(key) then UI:GetSearchFrame().StopKeyRepeat() end
        end)

        popup:HookScript("OnShow", function(self)
            if dropdownKeyboardMode then
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
                local sp = _G["EasyFindSpecPopup"]
                if sp then Utils.SafeCallMethod(sp, "EnableKeyboard", false) end
                local cf = _G["EasyFindSpecFlyout"]
                if cf then Utils.SafeCallMethod(cf, "EnableKeyboard", false) end
                local dp = _G["EasyFindDiffPopup"]
                if dp then Utils.SafeCallMethod(dp, "EnableKeyboard", false) end
                Utils.SafeCallMethod(self, "EnableKeyboard", true)
                SetPopupFocus(1)
            end
        end)

        popup:HookScript("OnHide", function(self)
            popupFocus = 0
            popupHL:Hide()
            Utils.SafeCallMethod(self, "EnableKeyboard", false)
            if dropdownKeyboardMode and dropdown:IsShown() then
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", true)
            end
        end)
    end

    for i, opt in ipairs(UI_FILTER_OPTIONS) do
        -- Children of a parent filter (e.g., Collections > Mounts) render
        -- indented; their visible width shrinks by SUB_INDENT so the
        -- right-edge icon stays inside the dropdown.
        local rowWidth = DROPDOWN_WIDTH - 16
        if opt.parentKey then rowWidth = rowWidth - 24 end
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(rowWidth, ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key
        row.parentKey = opt.parentKey

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        -- Category icon sits between the checkbox and label so the row
        -- reads left-to-right as [check][icon][name]. Supports atlas,
        -- raw fileID, or fileID + texCoords for sprite-sheet sub-icons.
        local icon
        if opt.iconAtlas or opt.iconTex then
            icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
            -- Gear sets pulls its icon from PaperDollSidebarTab3 so the
            -- filter row matches whatever sprite Blizzard ships, instead
            -- of the spec-border placeholder. Resolve once, then prefer
            -- the cached tex/coords over the static iconAtlas fallback.
            if opt.key == "gearSets" then
                local resolved = UI:GetFlatCategoryIcon({ gearSetID = true })
                if resolved and resolved._resolved and resolved.tex then
                    icon:SetTexture(resolved.tex)
                    if resolved.coords then
                        icon:SetTexCoord(resolved.coords[1], resolved.coords[2],
                                         resolved.coords[3], resolved.coords[4])
                    end
                else
                    icon:SetAtlas(opt.iconAtlas)
                end
            elseif opt.iconAtlas then
                icon:SetAtlas(opt.iconAtlas)
            else
                icon:SetTexture(opt.iconTex)
                if opt.iconCoords then
                    icon:SetTexCoord(opt.iconCoords[1], opt.iconCoords[2],
                                     opt.iconCoords[3], opt.iconCoords[4])
                end
            end
            row.iconTex = icon
        end

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        if icon then
            label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        else
            label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        end
        label:SetText(opt.label)
        row.label = label

        -- Right-pointing chevron on rows that have a flyout, signalling
        -- the row expands to the right. Mirrors the standard submenu
        -- indicator used elsewhere in the WoW UI. flyoutSubFilters drives
        -- the auto-built sub-filter popup; hasFlyout opts in rows whose
        if opt.flyoutSubFilters or opt.flyoutRadio or opt.hasFlyout then
            local chev = row:CreateTexture(nil, "OVERLAY")
            chev:SetAtlas("common-icon-forwardarrow")
            chev:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
            chev:SetPoint("RIGHT", -4, 0)
            chev:SetVertexColor(0.85, 0.85, 0.85, 1)
            row.flyoutChevron = chev
            label:SetPoint("RIGHT", chev, "LEFT", -4, 0)
            label:SetWordWrap(false)
            label:SetJustifyH("LEFT")
            row:HookScript("OnEnter", function() chev:SetVertexColor(1, 1, 1, 1) end)
            row:HookScript("OnLeave", function() chev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
        end

        -- Flyout sub-filters (e.g. Collections > Mounts/Toys/Pets/...).
        -- Hovering the row opens a popup containing one CheckButton per
        -- sub-filter. Each sub-filter writes through to filters[subKey]
        -- like a regular top-level filter so search uses them as-is.
        if opt.flyoutSubFilters then
            local SUB_POPUP_WIDTH = 180
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local CHK = CHECK_SIZE
            local SUB_ICON = ICON_SIZE

            -- Parent to UIParent + TOOLTIP strata mirrors the loot
            -- spec/class popups; nesting under `dropdown` left clicks
            -- routed back to the dropdown's own outside-click handler
            -- and the popup felt unclickable.
            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            -- Sibling registry so each flyout's ShowPopup can hide
            -- every other flyout on entry (kills overlap on quick
            -- row-to-row hover transitions).
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            -- Outside-click: close on click outside the popup. Nested
            -- options popups (e.g. appearance set options) act as
            -- guards so clicking inside them keeps this popup open.
            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                local opts = self._appearanceSetOptionsPopup
                if opts and opts:IsShown() and opts:IsMouseOver() then return end
                opts = self._mountOptionsPopup
                if opts and opts:IsShown() and opts:IsMouseOver() then return end
                opts = self._mountSourcePopup
                if opts and opts:IsShown() and opts:IsMouseOver() then return end
                self:Hide()
            end)

            local subRows = {}
            for si, sub in ipairs(opt.flyoutSubFilters) do
                local subRow = CreateFrame("CheckButton", nil, popup)
                subRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                subRow:SetHitRectInsets(0, 0, 0, 0)
                subRow:SetPoint("TOPLEFT", popup, "TOPLEFT", SUB_PAD, -(SUB_PAD + (si - 1) * SUB_ROW_H))

                subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                subRow:GetNormalTexture():SetSize(CHK, CHK)
                subRow:GetNormalTexture():ClearAllPoints()
                subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

                subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                subRow:GetCheckedTexture():SetSize(CHK, CHK)
                subRow:GetCheckedTexture():ClearAllPoints()
                subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

                local subIcon
                if sub.iconAtlas or sub.iconTex then
                    subIcon = subRow:CreateTexture(nil, "ARTWORK")
                    subIcon:SetSize(SUB_ICON, SUB_ICON)
                    subIcon:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                    if sub.iconAtlas then
                        subIcon:SetAtlas(sub.iconAtlas)
                    else
                        subIcon:SetTexture(sub.iconTex)
                    end
                    if sub.iconColor then
                        subIcon:SetVertexColor(unpack(sub.iconColor))
                    end
                end

                local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                if subIcon then
                    subLabel:SetPoint("LEFT", subIcon, "RIGHT", 4, 0)
                else
                    subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                end
                subLabel:SetText(sub.label)

                if sub.hasOptions then
                    local subChev = subRow:CreateTexture(nil, "OVERLAY")
                    subChev:SetAtlas("common-icon-forwardarrow")
                    subChev:SetSize(SUB_ICON - 2, SUB_ICON - 2)
                    subChev:SetPoint("RIGHT", -4, 0)
                    subChev:SetVertexColor(0.85, 0.85, 0.85, 1)
                    subLabel:SetPoint("RIGHT", subChev, "LEFT", -4, 0)
                    subLabel:SetWordWrap(false)
                    subLabel:SetJustifyH("LEFT")
                    subRow:HookScript("OnEnter", function() subChev:SetVertexColor(1, 1, 1, 1) end)
                    subRow:HookScript("OnLeave", function() subChev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
                end

                local subHL = subRow:CreateTexture(nil, "HIGHLIGHT")
                subHL:SetAllPoints()
                subHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                subRow:SetScript("OnClick", function(self)
                    local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                   or EasyFind.db.uiSearchFilters
                    target[sub.key] = self:GetChecked()
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)

                subRows[si] = subRow
                subRows[sub.key] = subRow

                -- Appearance Sets has its own nested options popup (class
                -- selector + Collected/Not Collected/PvE/PvP filters)
                -- that opens to the right of this sub-row on hover.
                if sub.hasOptions and sub.key == "appearanceSets" then
                    local optionsPopup, syncOptions = UI:BuildAppearanceSetOptionsPopup(
                        StylePopup, CreateRadioTexture, ROW_HIGHLIGHT_COLOR, CHECK_SIZE,
                        searchEditBox)
                    UI._SyncAppearanceSetOptions = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._appearanceSetOptionsPopup = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup

                    local optHideTimer
                    local function HideOptionsNow()
                        if optionsPopup:IsMouseOver() or subRow:IsMouseOver() then return end
                        optionsPopup:Hide()
                    end
                    local function ScheduleHideOptions()
                        if optHideTimer then optHideTimer:Cancel() end
                        optHideTimer = C_Timer.NewTimer(0.15, function()
                            optHideTimer = nil
                            HideOptionsNow()
                        end)
                    end

                    subRow:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                        syncOptions()
                        optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                        optionsPopup:ClearAllPoints()
                        optionsPopup:SetPoint("TOPLEFT", subRow, "TOPRIGHT", 4, 0)
                        optionsPopup:Show()
                    end)
                    subRow:HookScript("OnLeave", ScheduleHideOptions)
                    optionsPopup:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                    end)
                    optionsPopup:HookScript("OnLeave", ScheduleHideOptions)

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end

                if sub.hasOptions and sub.key == "mounts" then
                    local optionsPopup, syncOptions, sourcePopup = UI:BuildMountOptionsPopup(
                        StylePopup, ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox)
                    UI._SyncMountOptions = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._mountOptionsPopup = optionsPopup
                    popup._mountSourcePopup = sourcePopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = sourcePopup

                    local optHideTimer
                    local function HideOptionsNow()
                        if optionsPopup:IsMouseOver() or sourcePopup:IsMouseOver()
                           or subRow:IsMouseOver() then
                            return
                        end
                        optionsPopup:Hide()
                    end
                    local function ScheduleHideOptions()
                        if optHideTimer then optHideTimer:Cancel() end
                        optHideTimer = C_Timer.NewTimer(0.15, function()
                            optHideTimer = nil
                            HideOptionsNow()
                        end)
                    end

                    subRow:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                        syncOptions()
                        optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                        optionsPopup:ClearAllPoints()
                        optionsPopup:SetPoint("TOPLEFT", subRow, "TOPRIGHT", 4, 0)
                        optionsPopup:Show()
                    end)
                    subRow:HookScript("OnLeave", ScheduleHideOptions)
                    optionsPopup:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                    end)
                    optionsPopup:HookScript("OnLeave", ScheduleHideOptions)
                    sourcePopup:HookScript("OnEnter", function()
                        if optHideTimer then optHideTimer:Cancel(); optHideTimer = nil end
                    end)
                    sourcePopup:HookScript("OnLeave", ScheduleHideOptions)

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end
            end
            -- Sibling sub-rows hide the appearance set options popup so it
            -- doesn't linger when the cursor moves to a non-options row.
            if popup._appearanceSetOptionsPopup then
                local optionsPopup = popup._appearanceSetOptionsPopup
                for _, srOther in ipairs(subRows) do
                    if srOther ~= subRows.appearanceSets then
                        srOther:HookScript("OnEnter", function()
                            optionsPopup:Hide()
                        end)
                    end
                end
            end
            if popup._mountOptionsPopup then
                local optionsPopup = popup._mountOptionsPopup
                for _, srOther in ipairs(subRows) do
                    if srOther ~= subRows.mounts then
                        srOther:HookScript("OnEnter", function()
                            optionsPopup:Hide()
                        end)
                    end
                end
            end
            row.flyoutSubRows = subRows

            -- "Hide tooltips" checkbox at the bottom of the collections
            -- flyout. Toggles the per-group EasyFind.db.hideTooltips
            -- setting that the OnEnter handlers consult before showing
            -- mount / toy / pet / heirloom / appearance set tooltips.
            local extraRows = 0
            local hideTipRow
            if opt.key == "collections" then
                hideTipRow = CreateFrame("CheckButton", nil, popup)
                hideTipRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                hideTipRow:SetHitRectInsets(0, 0, 0, 0)
                hideTipRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + #opt.flyoutSubFilters * SUB_ROW_H))
                hideTipRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                hideTipRow:GetNormalTexture():SetSize(CHK, CHK)
                hideTipRow:GetNormalTexture():ClearAllPoints()
                hideTipRow:GetNormalTexture():SetPoint("LEFT", 4, 0)
                hideTipRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                hideTipRow:GetCheckedTexture():SetSize(CHK, CHK)
                hideTipRow:GetCheckedTexture():ClearAllPoints()
                hideTipRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)
                local lbl = hideTipRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", hideTipRow:GetNormalTexture(), "RIGHT", 4, 0)
                lbl:SetText("Hide tooltips")
                local hl = hideTipRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                hideTipRow:SetScript("OnClick", function(self)
                    EasyFind.db.hideTooltips = EasyFind.db.hideTooltips or {}
                    EasyFind.db.hideTooltips.collections = self:GetChecked() and true or false
                end)
                row.hideTooltipsRow = hideTipRow
                extraRows = 1
            end
            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + (#opt.flyoutSubFilters + extraRows) * SUB_ROW_H)

            -- Sync sub-row checked state from current DB values.
            local function SyncSubChecks()
                for _, sub in ipairs(opt.flyoutSubFilters) do
                    local sr = subRows[sub.key]
                    if sr then
                        local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        sr:SetChecked(target[sub.key] ~= false)
                    end
                end
                if hideTipRow then
                    local ht = EasyFind.db.hideTooltips
                    hideTipRow:SetChecked(ht and ht.collections == true)
                end
            end
            row.SyncFlyoutSubChecks = SyncSubChecks

            -- Show on hover of either the parent row or the arrow.
            -- Hide when the cursor leaves both the row and the popup,
            -- with a small grace timer so brief gaps between them don't
            -- snap the menu shut.
            local function PositionPopup()
                popup:ClearAllPoints()
                popup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
            end
            local hideTimer
            local function ShowPopup()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
                SetActiveFlyout(popup)
                SyncSubChecks()
                popup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                PositionPopup()
                popup:Show()
            end
            local function MaybeHide()
                if popup:IsMouseOver() or row:IsMouseOver() then return end
                if popup._appearanceSetOptionsPopup
                    and popup._appearanceSetOptionsPopup:IsShown()
                    and popup._appearanceSetOptionsPopup:IsMouseOver() then
                    return
                end
                if popup._mountOptionsPopup
                    and popup._mountOptionsPopup:IsShown()
                    and popup._mountOptionsPopup:IsMouseOver() then
                    return
                end
                if popup._mountSourcePopup
                    and popup._mountSourcePopup:IsShown()
                    and popup._mountSourcePopup:IsMouseOver() then
                    return
                end
                popup:Hide()
            end
            local function ScheduleHide()
                if hideTimer then hideTimer:Cancel() end
                hideTimer = C_Timer.NewTimer(0.15, function()
                    hideTimer = nil
                    MaybeHide()
                end)
            end

            -- Need to call ShowPopup from row's OnEnter (set lower in
            -- the loop), so stash it on the row for the OnClick handler.
            row.ShowFlyoutPopup = ShowPopup
            row.ScheduleHideFlyoutPopup = ScheduleHide

            popup:HookScript("OnLeave", ScheduleHide)
            popup:HookScript("OnEnter", function()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
            end)
            row:HookScript("OnEnter", ShowPopup)
            row:HookScript("OnLeave", ScheduleHide)
            -- Close when the parent dropdown closes so the popup can't
            -- linger over other UI.
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end

        -- Radio + checkbox flyout. radio.options renders radio rows that
        -- write radio.dbKey; radio.checkboxes renders independent toggles
        -- below. Either section may be omitted (e.g. Abilities has only a
        -- "Hide Passives" checkbox; Currencies has only the radio set).
        if opt.flyoutRadio and not opt.flyoutSubFilters then
            local radio = opt.flyoutRadio
            local SUB_POPUP_WIDTH = 200
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local options = radio.options or {}
            local checkboxes = radio.checkboxes or {}
            local hasSeparator = #options > 0 and #checkboxes > 0
            local SEPARATOR_H = hasSeparator and 8 or 0

            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                self:Hide()
            end)

            local radioRows = {}
            for ri, optionDef in ipairs(options) do
                local rRow = CreateFrame("Button", nil, popup)
                rRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                rRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + (ri - 1) * SUB_ROW_H))

                local bullet = rRow:CreateTexture(nil, "ARTWORK")
                bullet:SetAtlas("common-dropdown-tickradial")
                bullet:SetSize(14, 14)
                bullet:SetPoint("LEFT", 4, 0)

                local tick = rRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-radialtick-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = rRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", bullet, "RIGHT", 6, 0)
                lbl:SetText(optionDef.label)

                local hl = rRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                rRow.tick = tick
                rRow.value = optionDef.value
                rRow:SetScript("OnClick", function(self)
                    EasyFind.db[radio.dbKey] = self.value
                    for _, otherRow in ipairs(radioRows) do
                        otherRow.tick:SetShown(otherRow.value == self.value)
                    end
                    if radio.onChange then radio.onChange(self.value) end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)

                radioRows[ri] = rRow
            end

            local checkboxRows = {}
            local cbStartY = SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H
            for ci, cbDef in ipairs(checkboxes) do
                local cRow = CreateFrame("Button", nil, popup)
                cRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                cRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(cbStartY + (ci - 1) * SUB_ROW_H))

                local box = cRow:CreateTexture(nil, "ARTWORK")
                box:SetAtlas("common-dropdown-ticksquare")
                box:SetSize(12, 12)
                box:SetPoint("LEFT", 5, 0)

                local tick = cRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-checkmark-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = cRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", box, "RIGHT", 6, 0)
                lbl:SetText(cbDef.label)

                local hl = cRow:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))

                cRow.tick = tick
                cRow.dbKey = cbDef.dbKey
                cRow.onChange = cbDef.onChange
                cRow:SetScript("OnClick", function(self)
                    local cur = EasyFind.db[self.dbKey]
                    local next = not cur
                    EasyFind.db[self.dbKey] = next
                    self.tick:SetShown(next)
                    if self.onChange then self.onChange(next) end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)
                checkboxRows[ci] = cRow
            end

            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + #options * SUB_ROW_H + SEPARATOR_H + #checkboxes * SUB_ROW_H)

            if hasSeparator then
                local sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetColorTexture(1, 1, 1, 0.12)
                sep:SetHeight(1)
                sep:SetPoint("LEFT", popup, "LEFT", SUB_PAD, 0)
                sep:SetPoint("RIGHT", popup, "RIGHT", -SUB_PAD, 0)
                sep:SetPoint("TOP", popup, "TOP", 0,
                    -(SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H * 0.5))
            end

            local function SyncRadio()
                if radio.dbKey then
                    local cur = EasyFind.db[radio.dbKey]
                    for _, rRow in ipairs(radioRows) do
                        rRow.tick:SetShown(rRow.value == cur)
                    end
                end
                for _, cRow in ipairs(checkboxRows) do
                    cRow.tick:SetShown(EasyFind.db[cRow.dbKey] and true or false)
                end
            end
            row.SyncFlyoutSubChecks = SyncRadio

            local function PositionPopup()
                popup:ClearAllPoints()
                popup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
            end
            local hideTimer
            local function ShowPopup()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
                SetActiveFlyout(popup)
                SyncRadio()
                popup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                PositionPopup()
                popup:Show()
            end
            local function MaybeHide()
                if popup:IsMouseOver() or row:IsMouseOver() then return end
                popup:Hide()
            end
            local function ScheduleHide()
                if hideTimer then hideTimer:Cancel() end
                hideTimer = C_Timer.NewTimer(0.15, function()
                    hideTimer = nil
                    MaybeHide()
                end)
            end
            row.ShowFlyoutPopup = ShowPopup
            row.ScheduleHideFlyoutPopup = ScheduleHide
            popup:HookScript("OnLeave", ScheduleHide)
            popup:HookScript("OnEnter", function()
                if hideTimer then hideTimer:Cancel(); hideTimer = nil end
            end)
            row:HookScript("OnEnter", ShowPopup)
            row:HookScript("OnLeave", ScheduleHide)
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end


        -- Loot/Gear: side popup with difficulty + spec selector + iLvl
        -- upgrades checkbox. Opens to the right of the Gear filter row
        -- on hover, like the Collections sub-flyout.
        if opt.key == "loot" then
            local GEAR_POPUP_WIDTH = 200
            local GEAR_POPUP_PAD = 8

            local gearOptionsPopup = CreateFrame("Frame", "EasyFindGearOptionsPopup", UIParent, "BackdropTemplate")
            gearOptionsPopup:SetFrameStrata("TOOLTIP")
            StylePopup(gearOptionsPopup)
            gearOptionsPopup:EnableMouse(true)
            gearOptionsPopup:Hide()
            row.gearOptionsPopup = gearOptionsPopup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = gearOptionsPopup

            local lootSubDefs = {
                { dbKey = "lootUpgradesOnly", label = "iLvl Upgrades Only" },
                { dbKey = "hideTooltips.loot", label = "Hide tooltips" },
            }
            local lootSubRows = {}
            for si, sub in ipairs(lootSubDefs) do
                local subRow = CreateFrame("CheckButton", nil, gearOptionsPopup)
                subRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, ROW_HEIGHT)
                subRow:SetHitRectInsets(0, 0, 0, 0)

                subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                subRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                subRow:GetNormalTexture():ClearAllPoints()
                subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

                subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                subRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                subRow:GetCheckedTexture():ClearAllPoints()
                subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

                local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                subLabel:SetText(sub.label)

                local subHL = subRow:CreateTexture(nil, "HIGHLIGHT")
                subHL:SetAllPoints()
                subHL:SetColorTexture(1, 1, 1, 0.1)

                subRow.dbKey = sub.dbKey
                lootSubRows[si] = subRow

                -- Resolve "a.b" dotted keys into a getter/setter so the
                -- nested hideTooltips.loot toggle lives alongside the
                -- flat lootUpgradesOnly checkbox without duplicating
                -- this whole subRow setup.
                local function resolveDbPath()
                    local parent, leaf = sub.dbKey:match("^(.-)%.([^%.]+)$")
                    if parent then
                        EasyFind.db[parent] = EasyFind.db[parent] or {}
                        return EasyFind.db[parent], leaf
                    end
                    return EasyFind.db, sub.dbKey
                end

                subRow:SetScript("OnClick", function(self)
                    local tbl, leaf = resolveDbPath()
                    tbl[leaf] = self:GetChecked() and true or false
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
                subRow.resolveDbPath = resolveDbPath
            end

            -- Separator line between iLvl Upgrades checkbox and the
            -- difficulty/spec selectors.
            local lootSep = gearOptionsPopup:CreateTexture(nil, "ARTWORK")
            lootSep:SetHeight(1)
            lootSep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            row.lootSep = lootSep

            -- Difficulty dropdown (single-select, matches EJ style)
            local DIFF_OPTIONS = {
                { key = "lfr",    label = "Raid Finder" },
                { key = "normal", label = "Normal" },
                { key = "heroic", label = "Heroic" },
                { key = "mythic", label = "Mythic" },
            }
            local DIFF_LABELS = { lfr = "Raid Finder", normal = "Normal", heroic = "Heroic", mythic = "Mythic" }

            local diffBtn = CreateFrame("Button", nil, gearOptionsPopup)
            diffBtn:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
            local diffBg = diffBtn:CreateTexture(nil, "BACKGROUND")
            diffBg:SetAtlas("common-dropdown-textholder")
            diffBg:SetAllPoints()
            local diffArrow = diffBtn:CreateTexture(nil, "OVERLAY")
            diffArrow:SetAtlas("common-dropdown-a-button-hover")
            diffArrow:SetSize(20, 20)
            diffArrow:SetPoint("RIGHT", -2, -1)
            diffArrow:SetVertexColor(0.7, 0.7, 0.7)
            local diffText = diffBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            diffText:SetPoint("LEFT", 8, 0)
            diffText:SetPoint("RIGHT", diffArrow, "LEFT", -2, 0)
            diffText:SetJustifyH("LEFT")
            diffText:SetWordWrap(false)
            diffBtn:SetScript("OnEnter", function()
                diffArrow:SetVertexColor(1, 1, 1)
            end)
            diffBtn:SetScript("OnLeave", function()
                diffArrow:SetVertexColor(0.7, 0.7, 0.7)
            end)

            local function UpdateDiffLabel()
                local key = EasyFind.db.lootDifficulty or "normal"
                diffText:SetText(DIFF_LABELS[key] or "Normal")
            end

            -- Difficulty popup menu
            local diffPopup = CreateFrame("Frame", "EasyFindDiffPopup", UIParent, "BackdropTemplate")
            diffPopup:SetFrameStrata("TOOLTIP")
            diffPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
            StylePopup(diffPopup)
            diffPopup:EnableMouse(true)
            diffPopup:Hide()

            local diffPopupRows = {}
            local py = -6
            for _, def in ipairs(DIFF_OPTIONS) do
                local dRow = CreateFrame("Button", nil, diffPopup)
                dRow:SetSize(130, 20)
                dRow:SetPoint("TOPLEFT", 8, py)
                local radio, setRadioChecked = CreateRadioTexture(dRow)
                radio:SetPoint("LEFT", 0, 0)
                local dLabel = dRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                dLabel:SetPoint("LEFT", radio, "RIGHT", 4, 0)
                dLabel:SetText(def.label)
                local dHL = dRow:CreateTexture(nil, "HIGHLIGHT")
                dHL:SetAllPoints()
                dHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                dRow._diffKey = def.key
                dRow._setRadioChecked = setRadioChecked
                dRow:SetScript("OnClick", function()
                    EasyFind.db.lootDifficulty = def.key
                    UpdateDiffLabel()
                    diffPopup:Hide()
                    if ns.Database and ns.Database.RefreshDynamicCategory then
                        ns.Database:RefreshDynamicCategory("loot")
                    end
                    if searchEditBox:GetText() ~= "" then
                        UI:OnSearchTextChanged(searchEditBox:GetText())
                    end
                end)
                diffPopupRows[#diffPopupRows + 1] = dRow
                py = py - 20
            end
            diffPopup:SetSize(146, -py + 6)

            local function SyncDiffRadios()
                local key = EasyFind.db.lootDifficulty or "normal"
                for _, dr in ipairs(diffPopupRows) do
                    dr._setRadioChecked(dr._diffKey == key)
                end
            end

            diffBtn:SetScript("OnClick", function()
                if diffPopup:IsShown() then
                    diffPopup:Hide()
                else
                    SyncDiffRadios()
                    diffPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                    diffPopup:ClearAllPoints()
                    diffPopup:SetPoint("TOPLEFT", diffBtn, "BOTTOMLEFT", 0, 2)
                    diffPopup:Show()
                end
            end)
            diffPopup:SetScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            diffPopup:SetScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            diffPopup:SetScript("OnEvent", function(self, event)
                if event == "GLOBAL_MOUSE_DOWN" then
                    if not self:IsMouseOver() and not diffBtn:IsMouseOver() then
                        self:Hide()
                    end
                end
            end)

            AddPopupKeyboardNav(diffPopup, function() return diffPopupRows end)
            dropdownGuardFrames[#dropdownGuardFrames + 1] = diffPopup

            row.diffBtn = diffBtn
            row.diffPopup = diffPopup
            row.UpdateDiffButtons = function()
                UpdateDiffLabel()
            end


            local CLASS_COLORS = RAID_CLASS_COLORS
            local allClassSpecs = {}
            for classIdx = 1, GetNumClasses() do
                local className, classFile, classID = GetClassInfo(classIdx)
                if className then
                    local specs = {}
                    for specIdx = 1, GetNumSpecializationsForClassID(classID) do
                        local sid, sname, _, sicon = GetSpecializationInfoForClassID(classID, specIdx)
                        if sid then
                            specs[#specs + 1] = { specID = sid, specName = sname, specIcon = sicon }
                        end
                    end
                    if #specs > 0 then
                        allClassSpecs[#allClassSpecs + 1] = {
                            classID = classID, className = className,
                            classFile = classFile, specs = specs,
                        }
                    end
                end
            end


            local FLYOUT_ROW_H = 20
            local POPUP_WIDTH = 180
            local CLASSFLYOUT_WIDTH = 160
            -- Determine which class to display in the spec popup.
            -- Always returns a class (falls back to player's class for "all" or nil).
            local function GetSelectedClass()
                local lf = EasyFind.db.lootFilter
                if type(lf) == "table" and lf.classID then
                    for _, cls in ipairs(allClassSpecs) do
                        if cls.classID == lf.classID then return cls end
                    end
                end
                -- Default: player's class
                local _, _, playerClassID = UnitClass("player")
                for _, cls in ipairs(allClassSpecs) do
                    if cls.classID == playerClassID then return cls end
                end
                return allClassSpecs[1]
            end

            local function ApplyFilterSelection()
                if ns.Database then
                    if ns.Database.RefreshDynamicCategory then
                        ns.Database:RefreshDynamicCategory("loot")
                    end
                    ns.Database:SyncEJLootFilter()
                end
                if searchEditBox:GetText() ~= "" then
                    UI:OnSearchTextChanged(searchEditBox:GetText())
                end
            end

            -- Update the spec selector label from lootFilter
            local function UpdateSpecLabel()
                local lbl = row.specSelectLabel
                if not lbl then return end
                local lf = EasyFind.db.lootFilter
                if not lf then
                    -- Default: player's class + current spec, matching EJ format
                    local si = GetSpecialization and GetSpecialization()
                    local _, sname
                    if si then _, sname = GetSpecializationInfo(si) end
                    local className, classFile = UnitClass("player")
                    local cc = classFile and CLASS_COLORS[classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    if sname and className then
                        lbl:SetText(colorStr .. className .. " (" .. sname .. ")|r")
                    else
                        lbl:SetText(colorStr .. (className or "Current Spec") .. "|r")
                    end
                elseif lf == "all" then
                    lbl:SetText("All Classes")
                elseif lf.classID then
                    local cls
                    for _, c in ipairs(allClassSpecs) do
                        if c.classID == lf.classID then cls = c; break end
                    end
                    if not cls then lbl:SetText("?"); return end
                    local cc = CLASS_COLORS[cls.classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    if lf.specID then
                        local sname
                        for _, s in ipairs(cls.specs) do
                            if s.specID == lf.specID then sname = s.specName; break end
                        end
                        lbl:SetText(colorStr .. cls.className .. " (" .. (sname or "?") .. ")|r")
                    else
                        lbl:SetText(colorStr .. cls.className .. "|r")
                    end
                end
            end

            -- Check if a filter value matches the current lootFilter
            local function IsFilterMatch(filterVal)
                local lf = EasyFind.db.lootFilter
                -- nil lootFilter = current spec; resolve to player class+spec for comparison
                if not lf then
                    if filterVal == nil then return true end
                    if type(filterVal) == "table" and filterVal.specID then
                        local _, _, cid = UnitClass("player")
                        local si = GetSpecialization and GetSpecialization()
                        local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
                        return filterVal.classID == cid and filterVal.specID == sid
                    end
                    return false
                end
                if filterVal == "all" and lf == "all" then return true end
                if type(filterVal) == "table" and type(lf) == "table" then
                    if filterVal.classID == lf.classID then
                        if filterVal.specID == nil and lf.specID == nil then return true end
                        if filterVal.specID == lf.specID then return true end
                    end
                end
                return false
            end

            -------------------------------------------------------------------
            -- Main spec popup (opens BELOW the bar)
            -- Layout: "Class >" row, then class header, then specs, then "All Specializations"
            -------------------------------------------------------------------
            local specPopup = CreateFrame("Frame", "EasyFindSpecPopup", UIParent, "BackdropTemplate")
            specPopup:SetFrameStrata("TOOLTIP")
            specPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
            StylePopup(specPopup)
            specPopup:EnableMouse(true)
            specPopup:Hide()

            -------------------------------------------------------------------
            -- Class flyout (opens to the RIGHT of the "Class" row)
            -------------------------------------------------------------------
            local classFlyout = CreateFrame("Frame", "EasyFindSpecFlyout", UIParent, "BackdropTemplate")
            classFlyout:SetFrameStrata("TOOLTIP")
            classFlyout:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 30)
            StylePopup(classFlyout)
            classFlyout:EnableMouse(true)
            classFlyout:Hide()

            local LayoutSpecPopup  -- forward declaration for closures below

            -- Helper: create a radio-style row
            local function CreateRadioRow(parent, label, filterVal, width)
                local btn = CreateFrame("Button", nil, parent)
                btn:SetSize(width - 16, FLYOUT_ROW_H)
                btn:SetFrameLevel(parent:GetFrameLevel() + 10)
                local radio, setChecked = CreateRadioTexture(btn)
                radio:SetPoint("LEFT", 4, 0)
                local lbl = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", radio, "RIGHT", 4, 0)
                lbl:SetText(label)
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
                btn._setRadioChecked = setChecked
                btn._filterVal = filterVal
                return btn
            end

            local classFlyoutRows = {}
            local allClassRow = CreateRadioRow(classFlyout, "All Classes", "all", CLASSFLYOUT_WIDTH)
            allClassRow:SetScript("OnClick", function()
                EasyFind.db.lootFilter = "all"
                UpdateSpecLabel()
                classFlyout:Hide()
                if not classFlyout._keyboardParent then specPopup:Hide() end
                ApplyFilterSelection()
                if specPopup:IsShown() then LayoutSpecPopup() end
            end)
            classFlyoutRows[#classFlyoutRows + 1] = allClassRow
            for _, cls in ipairs(allClassSpecs) do
                local clsRow = CreateRadioRow(classFlyout, "", { classID = cls.classID }, CLASSFLYOUT_WIDTH)
                -- Override label with class-colored text
                local ccl = CLASS_COLORS[cls.classFile]
                local csStr = ccl and string.format("|cff%02x%02x%02x", ccl.r * 255, ccl.g * 255, ccl.b * 255) or ""
                local clsLabel = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                clsLabel:SetPoint("LEFT", 22, 0)
                clsLabel:SetText(csStr .. cls.className .. "|r")
                clsRow:SetScript("OnClick", function()
                    EasyFind.db.lootFilter = { classID = cls.classID }
                    UpdateSpecLabel()
                    classFlyout:Hide()
                    if not classFlyout._keyboardParent then specPopup:Hide() end
                    ApplyFilterSelection()
                    if specPopup:IsShown() then LayoutSpecPopup() end
                end)
                classFlyoutRows[#classFlyoutRows + 1] = clsRow
            end

            local function LayoutClassFlyout()
                local fy = -6
                local lvl = classFlyout:GetFrameLevel() + 10
                for _, r in ipairs(classFlyoutRows) do
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", classFlyout, "TOPLEFT", 8, fy)
                    r:SetFrameLevel(lvl)
                    r:Show()
                    if r._setRadioChecked then
                        local lf = EasyFind.db.lootFilter
                        local match = false
                        if r._filterVal == "all" and lf == "all" then
                            match = true
                        elseif type(r._filterVal) == "table" then
                            if type(lf) == "table" and r._filterVal.classID == lf.classID then
                                match = true
                            elseif not lf then
                                -- nil = current spec; dot the player's class
                                local _, _, cid = UnitClass("player")
                                match = r._filterVal.classID == cid
                            end
                        end
                        r._setRadioChecked(match)
                    end
                    fy = fy - FLYOUT_ROW_H
                end
                classFlyout:SetSize(CLASSFLYOUT_WIDTH, -fy + 6)
            end

            -------------------------------------------------------------------
            -- Build spec popup rows (main dropdown below bar)
            -------------------------------------------------------------------
            -- Row 1: "Class" with arrow (opens class flyout to the right)
            local classSelectBtn = CreateFrame("Button", nil, specPopup)
            classSelectBtn:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
            classSelectBtn:SetFrameLevel(specPopup:GetFrameLevel() + 10)
            local csLabel = classSelectBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            csLabel:SetPoint("LEFT", 8, 0)
            csLabel:SetText("Class")
            local csArrow = classSelectBtn:CreateTexture(nil, "ARTWORK")
            csArrow:SetSize(16, 16)
            csArrow:SetPoint("RIGHT", -4, 0)
            csArrow:SetTexture("Interface\\AddOns\\EasyFind\\Images\\flyout-arrow")
            local csHL = classSelectBtn:CreateTexture(nil, "HIGHLIGHT")
            csHL:SetAllPoints()
            csHL:SetColorTexture(1, 1, 1, 0.1)
            local function OpenClassFlyout()
                LayoutClassFlyout()
                classFlyout:SetScale(EasyFind.db.uiSearchScale or 1.0)
                classFlyout:ClearAllPoints()
                classFlyout:SetPoint("TOPLEFT", classSelectBtn, "TOPRIGHT", 2, 6)
                classFlyout:Show()
            end
            classSelectBtn:SetScript("OnEnter", function() OpenClassFlyout() end)
            classSelectBtn:SetScript("OnClick", function() OpenClassFlyout() end)

            -- Spec rows (rebuilt each time popup opens based on selected class)
            local specRadioRows = {}
            local MAX_SPECS = 5 -- druid has 4 + "All Specializations" = 5
            for si = 1, MAX_SPECS do
                local sRow = CreateRadioRow(specPopup, "", nil, POPUP_WIDTH)
                sRow:Hide()
                specRadioRows[si] = sRow
            end

            -- Class header (non-clickable, shows selected class name)
            local classHeader = CreateFrame("Frame", nil, specPopup)
            classHeader:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
            classHeader:SetFrameLevel(specPopup:GetFrameLevel() + 10)
            local classHeaderLabel = classHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            classHeaderLabel:SetPoint("LEFT", 8, 0)

            LayoutSpecPopup = function()
                local selCls = GetSelectedClass()
                local py = -6
                local lvl = specPopup:GetFrameLevel() + 10

                -- Row 1: "Class >"
                classSelectBtn:ClearAllPoints()
                classSelectBtn:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                classSelectBtn:SetFrameLevel(lvl)
                classSelectBtn:Show()
                py = py - FLYOUT_ROW_H

                if selCls then
                    local cc = CLASS_COLORS[selCls.classFile]
                    local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
                    classHeaderLabel:SetText(colorStr .. selCls.className .. "|r")
                    classHeader:ClearAllPoints()
                    classHeader:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                    classHeader:SetFrameLevel(lvl)
                    classHeader:Show()
                    py = py - FLYOUT_ROW_H

                    local ri = 1
                    for _, spec in ipairs(selCls.specs) do
                        local sRow = specRadioRows[ri]
                        if sRow then
                            local children = { sRow:GetRegions() }
                            for _, child in ipairs(children) do
                                if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                                    if child:GetPoint() then
                                        local _, rel = child:GetPoint()
                                        if rel and rel:GetObjectType() == "Texture" then
                                            child:SetText(spec.specName)
                                        end
                                    end
                                end
                            end
                            sRow._filterVal = { classID = selCls.classID, specID = spec.specID }
                            sRow._setRadioChecked(IsFilterMatch(sRow._filterVal))
                            sRow:SetScript("OnClick", function()
                                EasyFind.db.lootFilter = { classID = selCls.classID, specID = spec.specID }
                                UpdateSpecLabel()
                                classFlyout:Hide()
                                specPopup:Hide()
                                ApplyFilterSelection()
                            end)
                            sRow:SetScript("OnEnter", function()
                                classFlyout:Hide()
                            end)
                            sRow:ClearAllPoints()
                            sRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                            sRow:SetFrameLevel(lvl)
                            sRow:Show()
                            py = py - FLYOUT_ROW_H
                            ri = ri + 1
                        end
                    end

                    local allRow = specRadioRows[ri]
                    if allRow then
                        local children = { allRow:GetRegions() }
                        for _, child in ipairs(children) do
                            if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                                if child:GetPoint() then
                                    local _, rel = child:GetPoint()
                                    if rel and rel:GetObjectType() == "Texture" then
                                        child:SetText("All Specializations")
                                    end
                                end
                            end
                        end
                        allRow._filterVal = { classID = selCls.classID }
                        allRow._setRadioChecked(IsFilterMatch(allRow._filterVal))
                        allRow:SetScript("OnClick", function()
                            EasyFind.db.lootFilter = { classID = selCls.classID }
                            UpdateSpecLabel()
                            classFlyout:Hide()
                            specPopup:Hide()
                            ApplyFilterSelection()
                        end)
                        allRow:SetScript("OnEnter", function()
                            classFlyout:Hide()
                        end)
                        allRow:ClearAllPoints()
                        allRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                        allRow:SetFrameLevel(lvl)
                        allRow:Show()
                        py = py - FLYOUT_ROW_H
                        ri = ri + 1
                    end

                    for hi = ri, MAX_SPECS do
                        specRadioRows[hi]:Hide()
                    end
                else
                    classHeader:Hide()
                    for _, sr in ipairs(specRadioRows) do sr:Hide() end
                end

                specPopup:SetSize(POPUP_WIDTH, -py + 6)
            end

            local specSelectRow = CreateFrame("Button", nil, gearOptionsPopup)
            specSelectRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
            local specBg = specSelectRow:CreateTexture(nil, "BACKGROUND")
            specBg:SetAtlas("common-dropdown-textholder")
            specBg:SetAllPoints()
            local specSelectArrow = specSelectRow:CreateTexture(nil, "OVERLAY")
            specSelectArrow:SetAtlas("common-dropdown-a-button-hover")
            specSelectArrow:SetSize(20, 20)
            specSelectArrow:SetPoint("RIGHT", -2, -1)
            specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
            local specSelectLabel = specSelectRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            specSelectLabel:SetPoint("LEFT", 8, 0)
            specSelectLabel:SetPoint("RIGHT", specSelectArrow, "LEFT", -2, 0)
            specSelectLabel:SetJustifyH("LEFT")
            specSelectLabel:SetWordWrap(false)

            specSelectRow:SetScript("OnEnter", function()
                specSelectArrow:SetVertexColor(1, 1, 1)
            end)
            specSelectRow:SetScript("OnLeave", function()
                specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
            end)
            specSelectRow:SetScript("OnClick", function()
                if specPopup:IsShown() then
                    specPopup:Hide()
                else
                    LayoutSpecPopup()
                    specPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                    specPopup:ClearAllPoints()
                    specPopup:SetPoint("TOPLEFT", specSelectRow, "BOTTOMLEFT", 0, 2)
                    specPopup:Show()
                end
            end)

            row.specSelectRow = specSelectRow
            row.specSelectLabel = specSelectLabel

            local function GetSpecPopupNavRows()
                local rows = { classSelectBtn }
                for _, sr in ipairs(specRadioRows) do
                    if sr:IsShown() then rows[#rows + 1] = sr end
                end
                return rows
            end

            specPopup:SetScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            specPopup:SetScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                classFlyout:Hide()
            end)
            specPopup:SetScript("OnEvent", function(self, event)
                if event == "GLOBAL_MOUSE_DOWN" then
                    if not self:IsMouseOver()
                        and not classFlyout:IsMouseOver()
                        and not specSelectRow:IsMouseOver() then
                        self:Hide()
                    end
                end
            end)

            Utils.SafeOnUpdate(classFlyout, function(self)
                if self:IsKeyboardEnabled() then return end
                if not self:IsMouseOver() and not specPopup:IsMouseOver() then
                    if not self._leaveTimer then
                        self._leaveTimer = C_Timer.NewTimer(0.2, function()
                            self._leaveTimer = nil
                            if not self:IsMouseOver() and not classSelectBtn:IsMouseOver() then
                                self:Hide()
                            end
                        end)
                    end
                else
                    if self._leaveTimer then
                        self._leaveTimer:Cancel()
                        self._leaveTimer = nil
                    end
                end
            end)

            dropdownGuardFrames[#dropdownGuardFrames + 1] = specPopup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = classFlyout

            dropdown:HookScript("OnHide", function()
                classFlyout:Hide()
                specPopup:Hide()
            end)

            -- Keyboard nav MUST be added AFTER SetScript calls above
            AddPopupKeyboardNav(specPopup, GetSpecPopupNavRows)
            AddPopupKeyboardNav(classFlyout, function() return classFlyoutRows end)

            -- Keep EasyFindSpecFlyout/EasyFindSpecSubFlyout names for dropdown close guard
            local specFlyout = classFlyout
            row.specFlyout = specFlyout
            row.allClassSpecs = allClassSpecs
            row.lootSubRows = lootSubRows

            local gy = -GEAR_POPUP_PAD
            diffBtn:ClearAllPoints()
            diffBtn:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
            gy = gy - 27 - 4
            specSelectRow:ClearAllPoints()
            specSelectRow:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
            gy = gy - 27 - 6
            lootSep:ClearAllPoints()
            lootSep:SetPoint("LEFT", gearOptionsPopup, "LEFT", GEAR_POPUP_PAD, 0)
            lootSep:SetPoint("RIGHT", gearOptionsPopup, "RIGHT", -GEAR_POPUP_PAD, 0)
            lootSep:SetPoint("TOP", 0, gy)
            gy = gy - 6
            for _, sr in ipairs(lootSubRows) do
                sr:ClearAllPoints()
                sr:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
                gy = gy - ROW_HEIGHT
            end
            gearOptionsPopup:SetSize(GEAR_POPUP_WIDTH, -gy + GEAR_POPUP_PAD)

            -- Hover-to-show wiring on the Gear filter row, mirroring the
            -- Collections sub-flyout pattern (with grace timer).
            local gearHideTimer
            local function MaybeHideGear()
                if gearOptionsPopup:IsMouseOver() or row:IsMouseOver() then return end
                local sp = _G["EasyFindSpecPopup"]
                if sp and sp:IsShown() and sp:IsMouseOver() then return end
                if classFlyout:IsShown() and classFlyout:IsMouseOver() then return end
                if row.diffPopup and row.diffPopup:IsShown() and row.diffPopup:IsMouseOver() then return end
                gearOptionsPopup:Hide()
            end
            local function ScheduleHideGear()
                if gearHideTimer then gearHideTimer:Cancel() end
                gearHideTimer = C_Timer.NewTimer(0.15, function()
                    gearHideTimer = nil
                    MaybeHideGear()
                end)
            end
            local function ShowGear()
                if gearHideTimer then gearHideTimer:Cancel(); gearHideTimer = nil end
                SetActiveFlyout(gearOptionsPopup)
                if row.UpdateDiffButtons then row.UpdateDiffButtons() end
                UpdateSpecLabel()
                for _, sr in ipairs(lootSubRows) do
                    if sr.dbKey and sr.SetChecked then
                        sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
                    end
                end
                gearOptionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                gearOptionsPopup:ClearAllPoints()
                gearOptionsPopup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
                gearOptionsPopup:Show()
            end
            row.ShowGearOptionsPopup = ShowGear
            row:HookScript("OnEnter", ShowGear)
            row:HookScript("OnLeave", ScheduleHideGear)
            gearOptionsPopup:HookScript("OnEnter", function()
                if gearHideTimer then gearHideTimer:Cancel(); gearHideTimer = nil end
            end)
            gearOptionsPopup:HookScript("OnLeave", ScheduleHideGear)
            gearOptionsPopup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            gearOptionsPopup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                if row.diffPopup then row.diffPopup:Hide() end
                local sp = _G["EasyFindSpecPopup"]
                if sp then sp:Hide() end
                classFlyout:Hide()
                ClearActiveFlyout(self)
            end)
            -- Outside-click: nested diff/spec/class popups act as guards
            -- so clicks inside them don't dismiss the gear options.
            gearOptionsPopup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if self:IsMouseOver() or row:IsMouseOver() then return end
                if row.diffPopup and row.diffPopup:IsShown() and row.diffPopup:IsMouseOver() then return end
                local sp = _G["EasyFindSpecPopup"]
                if sp and sp:IsShown() and sp:IsMouseOver() then return end
                if classFlyout:IsShown() and classFlyout:IsMouseOver() then return end
                self:Hide()
            end)
            dropdown:HookScript("OnHide", function() gearOptionsPopup:Hide() end)

            row.updateLootToggle = function()
                for _, sr in ipairs(lootSubRows) do
                    if sr.SetChecked and sr.resolveDbPath then
                        local tbl, leaf = sr.resolveDbPath()
                        sr:SetChecked(tbl[leaf] == true)
                    end
                end
                UpdateSpecLabel()
                if row.UpdateDiffButtons then row.UpdateDiffButtons() end
            end
        end

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)

        local kbHighlight = row:CreateTexture(nil, "BACKGROUND")
        kbHighlight:SetAllPoints()
        kbHighlight:SetColorTexture(1, 1, 1, 0.1)
        kbHighlight:Hide()
        row.kbHighlight = kbHighlight

        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db.uiSearchFilters
            filters[opt.key] = self:GetChecked()
            if self.updateLootToggle then self.updateLootToggle() end
            LayoutDropdown()
            if searchEditBox:GetText() ~= "" then
                UI:OnSearchTextChanged(searchEditBox:GetText())
            end
            KeepSearchEditBoxUnfocused()
        end)

        checkRows[opt.key] = row
        checkRowsByIndex[i] = row
    end

    -- Layout: positions all rows including map sub-rows, adjusts dropdown height
    local SUB_INDENT = 24
    local dropdownNavRows = {}  -- ordered list of navigable rows (rebuilt on layout)
    local dropdownFocus = 0
    local dropdownKbHighlight = dropdown:CreateTexture(nil, "BACKGROUND")
    dropdownKbHighlight:SetColorTexture(1, 1, 1, 0.1)
    dropdownKbHighlight:Hide()

    local function SetDropdownFocus(idx)
        dropdownFocus = idx
        local target = dropdownNavRows[idx]
        if target then
            dropdownKbHighlight:SetParent(target)
            dropdownKbHighlight:ClearAllPoints()
            dropdownKbHighlight:SetAllPoints(target)
            dropdownKbHighlight:Show()
        else
            dropdownKbHighlight:Hide()
        end
    end

    local function ClearDropdownFocus()
        dropdownFocus = 0
        dropdownKbHighlight:Hide()
    end

    function LayoutDropdown()
        local savedFocus = dropdownFocus
        wipe(dropdownNavRows)
        dropdownKbHighlight:Hide()
        local filters = EasyFind.db.uiSearchFilters
        local y = -PADDING_TOP
        uncheckRow:ClearAllPoints()
        uncheckRow:SetPoint("TOPLEFT", 8, y)
        dropdownNavRows[#dropdownNavRows + 1] = uncheckRow
        y = y - ROW_HEIGHT
        for i, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRowsByIndex[i]
            local parentVisible = (not opt.parentKey) or (filters[opt.parentKey] ~= false)
            if not parentVisible then
                row:Hide()
            else
                local rowIndent = opt.parentKey and SUB_INDENT or 0
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 8 + rowIndent, y)
                row:Show()
                dropdownNavRows[#dropdownNavRows + 1] = row
                y = y - ROW_HEIGHT
            end
        end
        dropdown:SetSize(DROPDOWN_WIDTH, -y + PADDING_BOTTOM)
        if savedFocus > 0 and dropdown:IsKeyboardEnabled() then
            if savedFocus > #dropdownNavRows then savedFocus = #dropdownNavRows end
            SetDropdownFocus(savedFocus)
        end
    end

    Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
    Utils.SafeCallMethod(dropdown, "SetPropagateKeyboardInput", false)

    dropdown:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        if key == "DOWN" then
            UI:GetSearchFrame().StartKeyRepeat(key, function()
                local next = dropdownFocus + 1
                if next > #dropdownNavRows then next = 1 end
                SetDropdownFocus(next)
            end)
        elseif key == "UP" then
            if dropdownFocus <= 1 then
                self._escapedViaKeyboard = true
                self:Hide()
                return
            end
            UI:GetSearchFrame().StartKeyRepeat(key, function()
                local prev = dropdownFocus - 1
                if prev < 1 then prev = 1 end
                SetDropdownFocus(prev)
            end)
        elseif key == "ENTER" then
            local target = dropdownNavRows[dropdownFocus]
            if target and target.Click then
                target:Click()
            end
        elseif key == "ESCAPE" then
            self._escapedViaKeyboard = true
            -- Route through HandleEscape so flyouts/popups close together
            -- and the editbox refocuses, instead of just self:Hide() which
            -- only hits the main dropdown.
            UI:HandleEscape()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    dropdown:SetScript("OnKeyUp", function(_, key)
        if UI:GetSearchFrame().IsRepeatKey(key) then UI:GetSearchFrame().StopKeyRepeat() end
    end)

    -- (keyboard OnShow/OnHide hooks moved after SetScript calls below)

    -- Uncheck All: toggles all checkboxes off, or all back on if already all unchecked
    uncheckRow:SetScript("OnClick", function()
        local filters = EasyFind.db.uiSearchFilters
        local allUnchecked = true
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            if target[key] ~= false then allUnchecked = false end
        end)
        local newState = allUnchecked
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            target[key] = newState
        end)
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRows[opt.key]
            if row then
                row:SetChecked(newState)
                if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
            end
        end
        local lootRow = checkRows["loot"]
        if lootRow and lootRow.updateLootToggle then lootRow.updateLootToggle() end
        LayoutDropdown()
        if searchEditBox:GetText() ~= "" then
            UI:OnSearchTextChanged(searchEditBox:GetText())
        end
        KeepSearchEditBoxUnfocused()
    end)

    LayoutDropdown()

    dropdown:SetScript("OnShow", function(self)
        local filters = EasyFind.db.uiSearchFilters
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
            if row.updateLootToggle then row.updateLootToggle() end
            if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
        end
        LayoutDropdown()
    end)

    dropdown:SetScript("OnHide", function() end)

    -- Keyboard: enable when opened via Enter on filter button
    dropdown:HookScript("OnShow", function(self)
        -- Sync appearance set filters from the default UI. Only repopulate
        -- if something actually changed, so opening the dropdown is cheap.
        if ns.Database and ns.Database.SyncTransmogSetFiltersFromUI then
            local db = EasyFind.db
            local beforeClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local beforeCollected = db.appearanceSetCollected
            local beforeNotCollected = db.appearanceSetNotCollected
            local beforePvE = db.appearanceSetPvE
            local beforePvP = db.appearanceSetPvP

            ns.Database:SyncTransmogSetFiltersFromUI()

            local afterClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local changed = beforeClassID ~= afterClassID
                or beforeCollected ~= db.appearanceSetCollected
                or beforeNotCollected ~= db.appearanceSetNotCollected
                or beforePvE ~= db.appearanceSetPvE
                or beforePvP ~= db.appearanceSetPvP
            if changed and ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("transmogSets")
                if searchEditBox and searchEditBox:GetText() ~= "" then
                    UI:OnSearchTextChanged(searchEditBox:GetText())
                end
            end

            if UI._SyncAppearanceSetOptions then
                UI._SyncAppearanceSetOptions()
            end
        end
        if UI._SyncMountOptions then
            UI._SyncMountOptions()
        end
        local filterBtn = UI:GetSearchFrame().filterBtn
        dropdownKeyboardMode = filterBtn and filterBtn.keyboardFocused or false
        Utils.SafeCallMethod(UI:GetNavFrame(), "EnableKeyboard", false)
        Utils.SafeCallMethod(self, "EnableKeyboard", true)
        if dropdownKeyboardMode then
            SetDropdownFocus(1)
        else
            ClearDropdownFocus()
        end
    end)

    -- Keyboard: cleanup on hide
    dropdown:HookScript("OnHide", function(self)
        ClearDropdownFocus()
        Utils.SafeCallMethod(self, "EnableKeyboard", false)
        local escapedViaKeyboard = self._escapedViaKeyboard
        self._escapedViaKeyboard = nil
        if escapedViaKeyboard and not UI._escClosingMenus then
            dropdownKeyboardMode = false
            Utils.SafeCallMethod(UI:GetNavFrame(), "EnableKeyboard", true)
        else
            dropdownKeyboardMode = false
            if UI:GetSearchFrame().ClearToolbarFocus then UI:GetSearchFrame().ClearToolbarFocus() end
            Utils.SafeCallMethod(UI:GetNavFrame(), "EnableKeyboard", false)
            if UI:GetSearchFrame().filterBtn then
                local fb = UI:GetSearchFrame().filterBtn
                fb.keyboardFocused = nil
                -- Don't wipe the hover highlight if the cursor is still on
                -- the filter button (the common case when clicking the
                -- button to toggle the dropdown closed). Otherwise the
                -- outline disappears and OnEnter doesn't re-fire until
                -- the cursor leaves and comes back.
                if not fb:IsMouseOver() then
                    if fb.btnBg then fb.btnBg:Hide() end
                    if fb.ringDisc then fb.ringDisc:Hide() end
                    if fb.ringInner then fb.ringInner:Hide() end
                    if fb.UnlockHighlight then fb:UnlockHighlight() end
                end
            end
            -- Skip the ClearFocus when HandleEscape is driving the close,
            -- it intentionally refocuses the editbox so the user can keep
            -- typing. ClearFocus + same-frame SetFocus can lose to internal
            -- editbox state, hence the flag instead of relying on order.
            if UI:GetSearchFrame().editBox and not UI:GetSearchFrame().editBox:IsMouseOver()
               and not UI._escClosingMenus then
                UI:GetSearchFrame().editBox:ClearFocus()
            end
        end
    end)

    -- Close when clicking outside (but not when interacting with sub-filter popups).
    -- Both LeftButton AND RightButton trigger close: without the right-button
    -- check, right-clicking outside dismisses the search bar (whose handler
    -- listens for GLOBAL_MOUSE_DOWN regardless of button) but leaves the
    -- filter dropdown stuck open.
    Utils.SafeOnUpdate(dropdown, function(self)
        if self:IsShown()
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            if not self:IsMouseOver() and not toggleBtn:IsMouseOver() then
                for _, guard in ipairs(dropdownGuardFrames) do
                    if guard:IsShown() and guard:IsMouseOver() then return end
                end
                self:Hide()
            end
        end
    end)

    toggleBtn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            local barScale = EasyFind.db.uiSearchScale or 1.0
            dropdown:SetScale(barScale)
            local scale = anchorFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
            local right = anchorFrame:GetRight() * scale
            local bottom = anchorFrame:GetBottom() * scale
            dropdown:ClearAllPoints()
            dropdown:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
            dropdown:Show()
            KeepSearchEditBoxUnfocused()
        end
    end)

    UI:GetSearchFrame().filterDropdown = dropdown
end
