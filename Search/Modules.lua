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

local Search = EnsureModule("Search")
local modules = {
    Search,
    EnsureModule("SearchFocus"),
    EnsureModule("SearchHistory"),
    EnsureModule("SearchOpeners"),
    EnsureModule("SearchProviders"),
    EnsureModule("Filters"),
    EnsureModule("Calculator"),
    EnsureModule("Results"),
    EnsureModule("ResultRows"),
    EnsureModule("ResultRender"),
    EnsureModule("ResultHandlers"),
    EnsureModule("ResultIcons"),
    EnsureModule("ResultText"),
    EnsureModule("ResultTooltips"),
    EnsureModule("ResultShortcuts"),
    EnsureModule("OptionsSurface"),
    EnsureModule("Onboarding"),
    EnsureModule("Guide"),
}

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
