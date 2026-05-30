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
local wipe = wipe
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local GOLD_COLOR = ns.GOLD_COLOR
local GetUIBucket = Filters.GetUIBucket

Filters.quickFilterOptions = {
    { key = "abilities",      canonical = "abilities",       label = "Abilities",       categories = { "Ability" }, aliases = { "ab", "ability", "abilities", "spell", "spells" } },
    { key = "achievements",   canonical = "achievements",    label = "Achievements",    categories = { "Achievement", "Achievements", "Achievement Category", "Guild Achievements" }, aliases = { "a", "ach", "achievement", "achievements" } },
    { key = "statistics",     canonical = "statistics",      label = "Statistics",      categories = { "Statistic", "Statistics" }, aliases = { "s", "stat", "stats", "statistic", "statistics" } },
    { key = "bags",           canonical = "bags",            label = "Bags",            categories = { "Bag" }, aliases = { "b", "bag", "bags" } },
    { key = "bosses",         canonical = "bosses",          label = "Bosses",          categories = { "Boss" }, aliases = { "bo", "boss", "bosses", "encounter", "encounters" } },
    { key = "macros",         canonical = "macros",          label = "Macros",          categories = { "Macro" }, aliases = { "ma", "macro", "macros" } },
    { key = "collections",    canonical = "collections",     label = "Collections",     categories = { "Mount", "Toy", "Pet", "Outfit", "Heirloom", "Appearance Set" }, aliases = { "co", "col", "collection", "collections" } },
    { key = "appearanceSets", canonical = "appearance-sets", label = "Appearance Sets", categories = { "Appearance Set" }, aliases = { "as", "appearance", "appearances", "appearance-set", "appearance-sets", "appset", "appsets", "transmog", "tmog", "xmog" } },
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
    if not def then return "Quick Filter" end
    if def.aliasText then return def.aliasText end
    def.aliasText = (def.label or "Quick Filter")
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
    return (bucket and def.bucketLookup[bucket]) or false
end

function Filters:SetQuickFilterPillFill(frame, r, g, b, a)
    ns.SetRoundedRectFill(frame, r, g, b, a, true)
end

function Filters:HideQuickFilterPillBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
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
    self:SetQuickFilterPillFill(pill, 0.095, 0.095, 0.108, 1)

    local text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -8, 0)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(false)
    text:SetTextColor(Utils.RGB(GOLD_COLOR, 1))
    pill.text = text

    pill:SetScript("OnClick", function()
        Filters:ClearQuickFilter(true)
        if editBox then
            editBox.blockFocus = nil
            editBox:SetFocus()
        end
    end)
    pill:SetScript("OnEnter", function(self)
        Search:SetQuickFilterPillFill(self, 0.155, 0.155, 0.172, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["QUICK_FILTER"])
        GameTooltip:AddLine(L["QUICK_FILTER_TT"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pill:SetScript("OnLeave", function(self)
        Search:SetQuickFilterPillFill(self, 0.095, 0.095, 0.108, 1)
        GameTooltip_Hide()
    end)
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
    Filters._quickFilter = def
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()

    local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
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

function Filters:ClearQuickFilter(refresh)
    if not Filters._quickFilter then return false end
    Filters._quickFilter = nil
    self:HideQuickFilterSuggestions()
    self:UpdateQuickFilterPill()
    if refresh then
        local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        self:OnSearchTextChanged(editBox and editBox:GetText() or "", true)
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

function Filters:HandleQuickFilterTextChanged(editBox)
    if self:TryAcceptQuickFilterToken(editBox, true) then return true end
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
        if editBox and editBox.HasAutocomplete and editBox:HasAutocomplete()
           and editBox.AcceptAutocomplete
           and editBox:AcceptAutocomplete("tab") then
            return self:TryAcceptQuickFilterToken(editBox, false) or true
        end
        return self:AcceptQuickFilterSuggestion()
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

