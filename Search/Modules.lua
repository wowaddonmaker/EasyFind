-- Search module roots.
--
-- Ownership table. When adding code, place it in the module that owns the
-- responsibility. The current convention:
--
--   Responsibility                               Owner
--   ------------------------------------------   -----------------------------
--   Fetch raw game/addon data (mounts, toys,    ns.SearchProviders / Database
--     achievements, etc.)                        provider tables
--   Build searchable strings + metadata          ns.Database (uiSearchData)
--   Normalize/tokenize query text                ns.SearchText
--   Score and rank matches                       ns.Database (Search.lua)
--   Filter visible categories                    ns.Filters
--   Manage quick-filter state                    ns.Filters (private fields;
--                                                  read via :GetQuickFilter)
--   Decide row layout / pixel positions          ns.ResultRender
--   Decide row text / icon content               ns.ResultText / ResultIcons
--   Activate (open, click, equip) a result       ns.ResultHandlers
--   Input handling / focus / keybinds            ns.Search / ns.SearchFocus
--   Result navigation / selection state          ns.Results
--   Render the dropdown frame                    ns.Results / ResultsFrame
--
-- What this means in practice:
--   * Render modules MUST NOT decide whether an entry is searchable. That
--     lives on providers / Database / Filters.
--   * Handlers MUST NOT rebuild the search index. That lives on Database
--     and providers. Handlers only act on the entry they were given.
--   * Providers MUST NOT know about row pixel layout. They produce data
--     tables; rendering interprets them.
--   * Quick-filter internal state is owned by ns.Filters. Other modules
--     consume it via Filters:GetQuickFilter() / :IsQuickFilterSuggestionsActive(),
--     not by reading private fields directly.
--
-- New code that wants to cross a boundary should add a public accessor on
-- the owning module instead of reaching into a private field.

local _, ns = ...

local function EnsureModule(name)
    local module = ns[name]
    if not module then
        module = {}
        ns[name] = module
    end
    return module
end

local MODULE_NAMES = {
    "Search",
    "SearchFocus",
    "SearchHistory",
    "SearchOpeners",
    "SearchProviders",
    "Filters",
    "Calculator",
    "SearchCommands",
    "Results",
    "ResultRows",
    "ResultRender",
    "ResultHandlers",
    "ResultIcons",
    "ResultText",
    "ResultTooltips",
    "ResultShortcuts",
    "OptionsSurface",
    "Onboarding",
    "Guide",
}

local modules = {}
for i = 1, #MODULE_NAMES do
    modules[i] = EnsureModule(MODULE_NAMES[i])
end
local Search = modules[1]

local function FindModuleValue(_, key)
    for i = 1, #modules do
        local value = rawget(modules[i], key)
        if value ~= nil then return value end
    end
    return nil
end

for i = 1, #modules do
    if modules[i] ~= Search and not getmetatable(modules[i]) then
        setmetatable(modules[i], { __index = FindModuleValue })
    end
end

if not getmetatable(Search) then
    setmetatable(Search, { __index = FindModuleValue })
end

-- FindModuleValue resolves a key defined on two modules by array order,
-- silently shadowing the other definition. Surface duplicates in dev mode,
-- deferred to PLAYER_LOGIN so every Search file has loaded and defined its
-- methods. Render/Shared.lua's dot-style delegation wrappers intentionally
-- duplicate their ResultIcons / ResultText owners and are allowlisted.
local INTENTIONAL_DUPLICATE_KEYS = {
    IsBossResultData = true,
    AbbrevBinding = true,
    SetClippedText = true,
}

local duplicateKeyChecker = CreateFrame("Frame")
duplicateKeyChecker:RegisterEvent("PLAYER_LOGIN")
duplicateKeyChecker:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if not (EasyFind and EasyFind.db and EasyFind.db.devMode) then return end
    if not (ns.Utils and ns.Utils.DebugPrint) then return end
    local firstOwner = {}
    for i = 1, #modules do
        for key in pairs(modules[i]) do
            if not INTENTIONAL_DUPLICATE_KEYS[key] then
                if firstOwner[key] then
                    ns.Utils.DebugPrint("Duplicate Search module key '" .. tostring(key)
                        .. "' on " .. firstOwner[key] .. " and " .. MODULE_NAMES[i])
                else
                    firstOwner[key] = MODULE_NAMES[i]
                end
            end
        end
    end
end)
