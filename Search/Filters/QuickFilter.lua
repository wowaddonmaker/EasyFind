local _, ns = ...

---@class QuickFilterDef
---@field key string canonical bucket key (also used as table index)
---@field canonical string canonical token (lowercase, dash-separated)
---@field label string display label for the filter chip
---@field categories string[]? category names this filter accepts
---@field aliases string[]? user-visible aliases that resolve to this filter
---@field order integer set automatically from array position
---@field token string set automatically: "@" .. canonical
---@field categoryLookup table<string, boolean>
---@field bucketLookup table<string, boolean>
---@field completionTokens string[]? optional override list for tab-completion
---@field displayToken string? cached "@alias" string
---@field aliasText string? cached human-readable label
---@field nestedParent boolean? hides this option from empty-token suggestions

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local sfind, slower = Utils.sfind, Utils.slower
local tsort = Utils.tsort
local mmax = Utils.mmax
local mceil = math.ceil
local wipe = wipe
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local GetUIBucket = Filters.GetUIBucket

Filters.quickFilterOptions = {
    { key = "abilities",      canonical = "abilities",       label = _G["ABILITIES"] or "Abilities",       categories = { "Ability" }, aliases = { "ab", "ability", "abilities", "spell", "spells" } },
    { key = "achievements",   canonical = "achievements",    label = _G["ACHIEVEMENTS"] or "Achievements",    categories = { "Achievement", "Achievements", "Achievement Category", "Guild Achievements" }, aliases = { "a", "ach", "achievement", "achievements" } },
    { key = "statistics",     canonical = "statistics",      label = _G["STATISTICS"] or "Statistics",      categories = { "Statistic", "Statistics" }, aliases = { "s", "stat", "stats", "statistic", "statistics" } },
    { key = "items",          canonical = "items",           label = _G["ITEMS"] or "Items",          categories = { "Item", "Bag", "Bank", "Warband" }, aliases = { "i", "item", "items" } },
    { key = "catalog",        canonical = "gen",             label = L["FILTER_GENERAL_CATALOG"],      categories = { "Item" }, aliases = { "cat", "catalog", "general" } },
    { key = "icons",          canonical = "icons",           label = L["FILTER_ICONS"],       categories = { "Icon" }, aliases = { "ic", "icon", "icons", "texture", "textures" } },
    { key = "bags",           canonical = "bags",            label = _G["BAGS"] or "Bags",            categories = { "Bag" }, aliases = { "b", "bag", "bags" } },
    { key = "bank",           canonical = "bank",            label = _G["BANK"] or "Bank",            categories = { "Bank" }, aliases = { "bank", "banked" } },
    -- The warband bank is a separate place from a character's own bank, so it
    -- gets its own token rather than being folded into @bank.
    { key = "warband",        canonical = "warband",         label = ns.WarbandBankLabel and ns.WarbandBankLabel() or "Warband Bank", categories = { "Warband" }, aliases = { "wb", "warband", "warbank" } },
    { key = "bosses",         canonical = "bosses",          label = _G["RAID_BOSSES"] or "Bosses",          categories = { "Boss" }, aliases = { "bo", "boss", "bosses", "encounter", "encounters" } },
    { key = "macros",         canonical = "macros",          label = _G["MACROS"] or "Macros",          categories = { "Macro" }, aliases = { "ma", "macro", "macros" } },
    { key = "commands",       canonical = "commands",        label = L["FILTER_COMMANDS"],        categories = { "Command" }, aliases = { "cmd", "cmds", "command", "commands", "slash" } },
    { key = "professions",    canonical = "professions",     label = _G["TRADE_SKILLS"] or "Professions", categories = { "Profession" }, aliases = { "prof", "profs", "profession", "professions" } },
    { key = "housing",        canonical = "housing",         label = _G["HOUSING_SETTINGS_LABEL"] or _G["BINDING_HEADER_HOUSING_SYSTEM"] or "Housing", categories = { "Housing" }, aliases = { "ho", "house", "housing", "decor" } },
    { key = "collections",    canonical = "collections",     label = _G["COLLECTIONS"] or "Collections",     categories = { "Mount", "Toy", "Pet", "Outfit", "Heirloom", "Appearance Set", "Appearance" }, aliases = { "co", "col", "collection", "collections" } },
    { key = "appearanceItems", canonical = "appearance-items", label = _G["ITEMS"] or "Items", categories = { "Appearance" }, aliases = { "appearance", "appearances", "appearance-item", "appearance-items", "transmog", "tmog", "xmog" } },
    { key = "appearanceSets", canonical = "appearance-sets", label = L["FILTER_APPEARANCE_SETS"], categories = { "Appearance Set" }, aliases = { "as", "appearance-set", "appearance-sets", "appset", "appsets" } },
    { key = "heirlooms",      canonical = "heirlooms",       label = _G["HEIRLOOMS"] or "Heirlooms",       categories = { "Heirloom" }, aliases = { "h", "heirloom", "heirlooms" } },
    { key = "mounts",         canonical = "mounts",          label = _G["MOUNTS"] or "Mounts",          categories = { "Mount" }, aliases = { "m", "mount", "mounts" } },
    { key = "outfits",        canonical = "outfits",         label = L["FILTER_OUTFITS"],         categories = { "Outfit" }, aliases = { "of", "outfit", "outfits" } },
    { key = "pets",           canonical = "pets",            label = _G["PETS"] or "Pets",            categories = { "Pet" }, aliases = { "p", "pet", "pets" } },
    { key = "toys",           canonical = "toys",            label = _G["TOYS"] or "Toys",            categories = { "Toy" }, aliases = { "to", "toy", "toys" } },
    { key = "gearSets",       canonical = "gear-sets",       label = _G["EQUIPMENT_MANAGER"] or "Gear Sets",       categories = { "Gear Set" }, aliases = { "gs", "gearset", "gearsets", "gear-set", "gear-sets", "equipment-set", "equipment-sets" } },
    { key = "currencies",     canonical = "currencies",      label = _G["CURRENCY"] or "Currencies",      categories = { "Currency" }, aliases = { "c", "cur", "currency", "currencies" } },
    -- "l" for Loot. "g"/"gear" are kept only because this filter was called
    -- Gear before it was renamed, so muscle memory still works. "item"/"items"
    -- are NOT listed: they belong to the Items filter above, and because
    -- aliases resolve last-writer-wins this entry was silently stealing them --
    -- @items landed on Loot.
    { key = "loot",           canonical = "loot",            label = _G["LOOT"] or "Loot",            categories = { "Loot" }, aliases = { "l", "g", "gear", "loot" } },
    { key = "map",            canonical = "map",             label = L["FILTER_MAP_SEARCH"],      aliases = { "map", "maps", "zone", "zones", "location", "locations" } },
    { key = "options",        canonical = "options",         label = _G["OPTIONS"] or "Options",         categories = { "Game Settings", "AddOn Settings" }, aliases = { "op", "opt", "option", "options", "setting", "settings" } },
    { key = "gameOptions",    canonical = "game-options",    label = L["FILTER_GAME_OPTIONS"],    categories = { "Game Settings" }, aliases = { "go", "game", "game-option", "game-options", "game-setting", "game-settings" } },
    { key = "addonOptions",   canonical = "addon-options",   label = L["FILTER_ADDON_OPTIONS"],   categories = { "AddOn Settings" }, aliases = { "ao", "addon", "addons", "addon-option", "addon-options", "addon-setting", "addon-settings" } },
    { key = "reputations",    canonical = "reputations",     label = _G["REPUTATION"] or "Reputations",     categories = { "Reputation" }, aliases = { "r", "rep", "reps", "reputation", "reputations" } },
    { key = "talents",        canonical = "talents",         label = _G["TALENTS"] or "Talents",         categories = { "Talent" }, aliases = { "ta", "tal", "talent", "talents" } },
    { key = "titles",         canonical = "titles",          label = _G["TITLES"] or "Titles",          categories = { "Title" }, aliases = { "ti", "title", "titles" } },
}

Filters.quickFilterByAlias = {}

for i = 1, #Filters.quickFilterOptions do
    local def = Filters.quickFilterOptions[i]
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
        def.bucketLookup.appearanceItems = true
        def.bucketLookup.appearanceSets = true
    elseif def.key == "options" then
        def.bucketLookup.gameOptions = true
        def.bucketLookup.addonOptions = true
    end
    Filters.quickFilterByAlias[slower(def.canonical)] = def
    if def.aliases then
        for ai = 1, #def.aliases do
            Filters.quickFilterByAlias[slower(def.aliases[ai])] = def
        end
    end
end

Filters.quickFilterSuggestionBuf = {}
Filters.quickFilterSuggestionEntries = {}
Filters.quickFilterSuggestionData = {}

---Ranks how well a filter definition matches a partially-typed token.
---Lower scores are better. Returns nil if there is no match.
---@param def QuickFilterDef
---@param token string?
---@return integer?
function Filters:QuickFilterMatchRank(def, token)
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

---Resolves a typed token (with or without leading "@") to a filter
---definition. Returns nil for empty/unknown tokens, or when a prefix
---matches multiple filters (ambiguous).
---@param token string?
---@return QuickFilterDef?
function Filters:ResolveQuickFilterToken(token)
    if not token or token == "" then return nil end
    token = slower(token:gsub("^@", ""):gsub("_", "-"))
    local direct = Filters.quickFilterByAlias[token]
    if direct then return direct end

    local found, matches = nil, 0
    for i = 1, #Filters.quickFilterOptions do
        local def = Filters.quickFilterOptions[i]
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

function Search.QuickFilterSuggestionLess(a, b)
    if a.rank == b.rank then
        return (a.def.order or 0) < (b.def.order or 0)
    end
    return a.rank < b.rank
end

function Filters:GetQuickFilter()
    return Filters._quickFilter
end

function Filters:IsQuickFilterSuggestionsActive()
    return Filters._quickFilterSuggestionsActive and true or false
end

function Filters:GetQuickFilterCompletionToken(def, typed)
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

function Filters:GetQuickFilterDisplayToken(def)
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

function Filters:GetQuickFilterAliasText(def)
    if not def then return L["QUICK_FILTER"] end
    if def.aliasText then return def.aliasText end
    def.aliasText = (def.label or L["QUICK_FILTER"])
    return def.aliasText
end

function Filters:QuickFilterAllowsData(data, quickFilter)
    local def = quickFilter or Filters._quickFilter
    if not def then return true end
    if not data or data.calculatorResult or data.calculatorLauncher or data.searchCommand then return false end

    if def.key == "map" then return data.mapSearchResult and true or false end
    if data.mapSearchResult then return false end
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
    if def.key == "appearanceItems" then return data.appearanceItemID and true or false end
    if def.key == "appearanceSets" then return data.transmogSetID and true or false end
    if def.key == "collections" then
        return (data.mountID or data.toyItemID or data.petID or data.outfitID
            or data.heirloomItemID or data.transmogSetID or data.appearanceItemID) and true or false
    end
    if def.key == "loot" then
        return (data.itemID and data.category == "Loot") and true or false
    end

    if data.category and def.categoryLookup and def.categoryLookup[data.category] then
        return true
    end
    local bucket = GetUIBucket(data)
    return (bucket and def.bucketLookup[bucket]) or false
end

function Filters:SetQuickFilterPillFill(frame, r, g, b, a)
    ns.SetRoundedRectFill(frame, r, g, b, a, true)
end

function Filters:HideQuickFilterPillBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
end

-- Pill geometry. The X reserves NO width: it overlays the tail of the token on
-- a higher sublevel, so the pill stays hugged to its text and hovering never
-- resizes it.
local PILL_PAD_LEFT  = 7
local PILL_PAD_RIGHT = 5
local QUICK_FILTER_CLEAR_TEX = "Interface\\AddOns\\EasyFind\\textures\\clear-button"

-- Paint the pill the way the options stepper (+ / -) buttons paint themselves:
-- the theme's row wash, falling back to the flat control fill on themes that
-- have no wash. Hardcoding BTN_FILL_NORMAL made it a grey slab sitting on the
-- themed bar. Label follows the theme's leaf color for the same reason.
function Filters:PaintQuickFilterPill(pill, hovered)
    if not pill then return end
    local washR, washG, washB = ns.RowWashColor()
    if washR then
        local boost = hovered and 1.35 or 1
        ns.SetRoundedRectFill(pill, washR * boost, washG * boost, washB * boost, 1, true)
    else
        local fill = hovered and ns.BTN_FILL_HOVER or ns.BTN_FILL_NORMAL
        Search:SetQuickFilterPillFill(pill, fill[1], fill[2], fill[3], 1)
    end
    if pill.text then
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        local leaf = theme and theme.leafColor
        if leaf then
            pill.text:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
        else
            pill.text:SetTextColor(1, 1, 1, 1)
        end
    end
end

function Filters:CreateQuickFilterPill(frame, editBox, iconHolder, filterBtn)
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

    local text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", PILL_PAD_LEFT, 0)
    text:SetPoint("RIGHT", -PILL_PAD_RIGHT, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    pill.text = text

    -- Clear affordance: the whole pill has always cleared on click, but with no
    -- visual cue for it. The X draws only on hover and OVERLAYS the end of the
    -- token instead of reserving width for it. It lives in a child frame, NOT
    -- on a higher sublevel of the pill: within one draw layer a FontString
    -- always beats a texture no matter its sublevel, so an OVERLAY texture sat
    -- behind the token text. A child frame's regions draw above every region
    -- of its parent, unconditionally. Mouse stays disabled so the pill keeps
    -- owning the click.
    local xHolder = CreateFrame("Frame", nil, pill)
    xHolder:SetAllPoints(pill)
    xHolder:SetFrameLevel(pill:GetFrameLevel() + 1)
    local clearX = xHolder:CreateTexture(nil, "OVERLAY")
    clearX:SetSize(ns.CLEAR_BTN_SIZE, ns.CLEAR_BTN_SIZE)
    clearX:SetPoint("RIGHT", xHolder, "RIGHT", -PILL_PAD_RIGHT, 0)
    clearX:SetTexture(QUICK_FILTER_CLEAR_TEX)
    clearX:Hide()
    pill.clearX = clearX

    pill:SetScript("OnClick", function()
        Filters:ClearQuickFilter(true)
        if editBox then
            editBox.blockFocus = nil
            editBox:SetFocus()
        end
    end)
    pill:SetScript("OnEnter", function(self)
        Filters:PaintQuickFilterPill(self, true)
        if self.clearX then self.clearX:Show() end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["QUICK_FILTER"])
        GameTooltip:AddLine(L["QUICK_FILTER_TT"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pill:SetScript("OnLeave", function(self)
        Filters:PaintQuickFilterPill(self, false)
        if self.clearX then self.clearX:Hide() end
        GameTooltip_Hide()
    end)
    Filters:PaintQuickFilterPill(pill, false)
    pill:Hide()

    frame.quickFilterPill = pill
    frame.quickFilterEditBox = editBox
    frame.quickFilterIconHolder = iconHolder
    frame.quickFilterFilterBtn = filterBtn
end

function Filters:UpdateQuickFilterPill()
    local frame = Search:GetSearchFrame()
    if not frame or not frame.quickFilterEditBox then return end
    local editBox = frame.quickFilterEditBox
    local iconHolder = frame.quickFilterIconHolder
    local filterBtn = frame.quickFilterFilterBtn
    local pill = frame.quickFilterPill
    local active = Filters._quickFilter

    editBox:ClearAllPoints()
    if active and pill then
        pill.text:SetText(active.token)
        -- Hug the token: left pad + text + right pad, nothing else. No X
        -- reserve (it overlays) and no arbitrary minimum -- a flat 52 left
        -- short tokens like "@gen" swimming in dead space on both sides.
        local w = (pill.text:GetStringWidth() or 0) + PILL_PAD_LEFT + PILL_PAD_RIGHT
        pill:SetWidth(mceil(w))
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

function Filters:HideQuickFilterSuggestions()
    Filters._quickFilterSuggestionsActive = nil
    Filters._quickFilterFirstSuggestion = nil
end

function Filters:GetQuickFilterSuggestionEntries(token)
    local suggestions = Filters.quickFilterSuggestionBuf
    wipe(suggestions)
    local n = 0
    token = (token or ""):gsub("_", "-")
    for i = 1, #Filters.quickFilterOptions do
        local def = Filters.quickFilterOptions[i]
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
    tsort(suggestions, Search.QuickFilterSuggestionLess)

    local entries = Filters.quickFilterSuggestionEntries
    local dataPool = Filters.quickFilterSuggestionData
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

function Filters:UpdateQuickFilterSuggestions(editBox)
    if Filters._quickFilter then
        self:HideQuickFilterSuggestions()
        return false
    end
    editBox = editBox or (Search:GetSearchFrame() and Search:GetSearchFrame().editBox)
    if not editBox then return false end

    local cursor = editBox:GetCursorPosition() or #(editBox:GetText() or "")
    local typed = (editBox:GetText() or ""):sub(1, cursor)
    local token = typed:match("^%s*@([%w_%-:]*)$")
    if not token then
        self:HideQuickFilterSuggestions()
        return false
    end

    local entries, firstDef = self:GetQuickFilterSuggestionEntries(token)
    Filters._quickFilterSuggestionsActive = true
    Filters._quickFilterFirstSuggestion = firstDef
    if entries then
        self:ShowHierarchicalResults(entries)
    else
        self:HideResults()
    end
    return true
end

function Filters:GetSelectedQuickFilterSuggestion()
    if Search:GetSelectedIndex() > 0 then
        local row = Search:GetResultButtons()[Search:GetSelectedIndex()]
        local def = row and row:IsShown() and row.data and row.data.quickFilterDef
        if def then return def end
    end
    return Filters._quickFilterFirstSuggestion
end

function Filters:AcceptQuickFilterSuggestion()
    if not Filters._quickFilterSuggestionsActive then return false end
    local def = self:GetSelectedQuickFilterSuggestion()
    if not def then return false end
    return self:ApplyQuickFilter(def, "")
end

function Filters:ApplyQuickFilter(def, remainingText)
    if not def then return false end
    -- Explicitly asking for the catalog (@gen / @items) is the moment to
    -- pull in its LoadOnDemand companion; a discrete action absorbs the
    -- one-time load where a keystroke could not.
    if (def.key == "items" or def.key == "catalog") and ns.RequestItemCatalog then
        ns.RequestItemCatalog(true)
    end
    local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
    -- Kill any inline ghost BEFORE touching text: a live candidate (e.g.
    -- "@icons" ghosted over a typed "@ico") left armed here can be
    -- re-accepted by the editbox's own deferred Tab dispatch and resurrect
    -- the token as query text.
    if editBox and editBox.StripAutocomplete then editBox:StripAutocomplete() end
    remainingText = remainingText or ""
    -- One owner for one guarantee: applying a quick filter REPLACES the
    -- typed @token; it never survives as query text. Every accept path
    -- (Tab, Space, Enter, ghost accept, suggestion click, app launchers)
    -- funnels through here, so leading tokens that resolve to THIS def are
    -- stripped at the gate instead of every caller sanitizing its own
    -- composition. Tokens of a DIFFERENT def are left alone.
    while true do
        local token, rest = remainingText:match("^%s*@([%w_%-:]+)%s*(.*)$")
        if not token or self:ResolveQuickFilterToken(token) ~= def then break end
        remainingText = rest
    end
    Filters._quickFilter = def
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()

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

function Filters:ClearQuickFilter(refresh)
    if not Filters._quickFilter then return false end
    Filters._quickFilter = nil
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()
    if refresh then
        self:OnSearchTextChanged(Search:GetTypedQuery(), true)
    end
    return true
end

function Filters:TryAcceptQuickFilterToken(editBox, includeWhitespace)
    if Filters._quickFilter or not editBox then return false end
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

-- True when token is exactly one of def's aliases (or its canonical) AND not
-- a proper prefix of a longer one, i.e. typing cannot be mid-word ("ic" and
-- "icon" are prefixes of "icons", so they suggest; "icons" is complete).
local function IsCompleteToken(def, token)
    token = slower(token)
    local exact = slower(def.canonical) == token
    if not exact and def.aliases then
        for i = 1, #def.aliases do
            if slower(def.aliases[i]) == token then
                exact = true
                break
            end
        end
    end
    if not exact then return false end
    local canonical = slower(def.canonical)
    if #canonical > #token and sfind(canonical, token, 1, true) == 1 then return false end
    if def.aliases then
        for i = 1, #def.aliases do
            local alias = slower(def.aliases[i])
            if #alias > #token and sfind(alias, token, 1, true) == 1 then return false end
        end
    end
    return true
end

function Filters:HandleQuickFilterTextChanged(editBox)
    if self:TryAcceptQuickFilterToken(editBox, true) then return true end
    -- @icons opens on the bare token, no trailing space needed: whenever a
    -- complete icons token is present, the grid shows. The grid is a view,
    -- not a narrowing filter, so there is nothing to wait for. (Other
    -- filters keep the space/Tab handshake: applying them changes what a
    -- continued query means.)
    if not Filters._quickFilter and editBox then
        local text = editBox:GetText() or ""
        local bareToken = text:match("^%s*@([%w_%-:]+)%s*$")
        if bareToken then
            local def = self:ResolveQuickFilterToken(bareToken)
            if def and def.key == "icons" and IsCompleteToken(def, bareToken) then
                return self:ApplyQuickFilter(def, "")
            end
        end
    end
    if self:UpdateQuickFilterSuggestions(editBox) then
        if editBox and editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        if editBox and editBox.UpdateAutocomplete then
            local box = editBox
            Utils.SafeAfter(0, function()
                if box and box:IsVisible() and box:HasFocus()
                   and Filters._quickFilterSuggestionsActive
                   and box.UpdateAutocomplete then
                    box.UpdateAutocomplete()
                end
            end)
        end
        return true
    end
    return false
end

function Filters:HandleQuickFilterSuggestionBackspace(editBox)
    if not (Filters._quickFilterSuggestionsActive and editBox) then return false end

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

        if not Filters:UpdateQuickFilterSuggestions(editBox) then
            Search:OnSearchTextChanged(newText, true)
        end
    end

    if Utils and Utils.SafeAfter then
        Utils.SafeAfter(0, applyBackspace)
    else
        applyBackspace()
    end
    return true
end

function Filters:HandleQuickFilterKeyDown(editBox, key)
    if key == "BACKSPACE" and Filters._quickFilter and editBox
       and (editBox:GetText() or "") == "" then
        return self:ClearQuickFilter(true)
    end
    if key == "BACKSPACE" and self:HandleQuickFilterSuggestionBackspace(editBox) then
        return true
    end

    if Filters._quickFilterSuggestionsActive and key == "TAB" then
        -- Straight to the suggested def. The old path accepted the ghost
        -- text and re-parsed it back into a def, and any hiccup in that
        -- roundtrip ate the keypress with nothing applied. With suggestions
        -- on screen, Tab's intent IS the suggestion; apply the def object
        -- directly, no text roundtrip (ApplyQuickFilter owns ghost cleanup
        -- and token stripping at the gate). `or true` still consumes Tab on
        -- a dead token so focus doesn't jump to the toolbar mid-@.
        return self:AcceptQuickFilterSuggestion() or true
    end
    if Filters._quickFilterSuggestionsActive and key == "ENTER" then
        return self:AcceptQuickFilterSuggestion()
    end
    if key == "SPACE" then
        if self:TryAcceptQuickFilterToken(editBox, false) then
            self:SuppressQuickFilterLeakedText(" ")
            return true
        end
        if Filters._quickFilterSuggestionsActive then
            if self:AcceptQuickFilterSuggestion() then
                self:SuppressQuickFilterLeakedText(" ")
                return true
            end
        end
    end
    return false
end

function Filters:QuickFilterNeedsHeavyData(def)
    return def and (def.key == "loot" or def.key == "bosses")
end

return Filters

