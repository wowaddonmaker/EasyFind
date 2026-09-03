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

local function FindModuleValue(t, key)
    for i = 1, #modules do
        local value = rawget(modules[i], key)
        if value ~= nil then
            -- Memoize the resolution into the asking module: this linear
            -- scan over 19 tables ran on every cross-module read and cost
            -- a measured 2.9% of typing CPU. Module functions are defined
            -- once at load, so the cached ref stays valid. (Dev tools that
            -- hot-swap a function on its OWNING module should install
            -- their wrappers before first use or clear the copies.)
            rawset(t, key, value)
            return value
        end
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

-- The calculator ships as the optional EasyFind_Calc companion, which
-- populates ns.Calculator when enabled.
--
-- First: chrome that is CORE-OWNED even though it wears the calculator
-- name -- the flat themed micro-button style is shared by the companion
-- apps, so it must work with the calculator companion disabled. The
-- companion calls these too.
local Calculator = ns.Calculator
local mmin = ns.Utils.mmin

function Calculator:SetCalculatorRoundedFill(frame, r, g, b, a, br, bg, bb, ba)
    ns.SetRoundedRectFill(frame, r, g, b, a, true)
    ns.SetRoundedRectBorderColor(frame, br or 0.30, bg or 0.30, bb or 0.32, ba or 0.85, true)
end

function Calculator:HideCalculatorRoundedBorder(frame)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
end

-- Live theme fill: paints from the theme table when present, else the
-- neutral slate fallback.
function Calculator:ThemeFillCalcControl(frame, tbl, fallbackR, fallbackG, fallbackB)
    if tbl then
        self:SetCalculatorRoundedFill(frame, tbl[1], tbl[2], tbl[3], 1)
    else
        self:SetCalculatorRoundedFill(frame, fallbackR, fallbackG, fallbackB, 1)
    end
end

-- Styled buttons register weakly so the companion's theme restyle can
-- repaint resting fills after a palette flip.
Calculator._styledButtons = setmetatable({}, { __mode = "k" })

function Calculator:StyleCalculatorButton(btn, height)
    if not btn then return end
    if not btn.combinedBorder then
        ns.CreateRoundedRectBorder(btn)
    end
    ns.SetRoundedRectBarHeight(btn, mmin(height or btn:GetHeight() or 22, 10))
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    self:HideCalculatorRoundedBorder(btn)
    Calculator._styledButtons[btn] = true
    self:ThemeFillCalcControl(btn, ns.BTN_FILL_NORMAL, 0.095, 0.095, 0.108)
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            Calculator:ThemeFillCalcControl(self, ns.BTN_FILL_HOVER, 0.155, 0.155, 0.172)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then
            Calculator:ThemeFillCalcControl(self, ns.BTN_FILL_NORMAL, 0.095, 0.095, 0.108)
        end
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            Calculator:ThemeFillCalcControl(self, ns.BTN_FILL_PRESSED, 0.065, 0.065, 0.078)
        end
    end)
    btn:SetScript("OnMouseUp", function(self)
        if not self:IsEnabled() then return end
        if self:IsMouseOver() then
            Calculator:ThemeFillCalcControl(self, ns.BTN_FILL_HOVER, 0.155, 0.155, 0.172)
        else
            Calculator:ThemeFillCalcControl(self, ns.BTN_FILL_NORMAL, 0.095, 0.095, 0.108)
        end
    end)
end

-- Second: no-op fallbacks for EVERY companion-defined method that core
-- code calls (derived mechanically -- grep the companion's method names
-- against core call sites; a hand-picked subset is how ENTER-handler
-- crashes happen). The companion's real definitions overwrite these as
-- it loads.
function Calculator:ArmCalculatorPartFromRow() end
function Calculator:ArmCalculatorResultForData() end
function Calculator:ArmCalculatorResultFromRow() end
function Calculator:ArmCalculatorSelectionForKeyboard() end
function Calculator:ClearCalculatorCopyHighlight() end
function Calculator:ConfirmCalculatorCopied() end
function Calculator:EvaluateCalculatorExpression() end
function Calculator:GetCalculatorLauncherMatch() end
function Calculator:HandleCalculatorCopyConfirmKey() end
function Calculator:HandleCalculatorCopyKey() end
function Calculator:HandleCalculatorOpenShortcut() end
function Calculator:HandleCalculatorPasteIntoSearch() end
function Calculator:HoverCalculatorTarget() end
function Calculator:IsCalculatorCopyConfirmKey() end
function Calculator:IsCalculatorCopyKey() end
function Calculator:OpenCalculator() end
function Calculator:RearmActiveCalculatorCopy() end
function Calculator:ReleaseCalculatorCopyBox() end
function Calculator:RestoreCalculatorTarget() end
function Calculator:SetCalculatorCopyHighlight() end

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

-- Icon Search ships as the LoadOnDemand EasyFind_Icons companion (data,
-- grid, picker bar). This is the ONE load funnel: every entry point (the
-- apps row, the @icons quick filter, the macro-UI watcher below) routes
-- here, loads the companion on first use, and reports whether the module
-- is available. Disabled companion = one explanatory chat line per
-- session, then quiet no-ops.
local iconModuleWarned = false
function ns.RequestIconSearch()
    if ns.Results.ShowIconGrid then return true end
    if InCombatLockdown() then return false end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Icons")
    end
    if ns.Results.ShowIconGrid then return true end
    if not iconModuleWarned then
        iconModuleWarned = true
        EasyFind:Print(ns.L["ICON_MODULE_DISABLED"])
    end
    return false
end

-- The macro icon picker's search bar lives in the companion too, so the
-- game's macro UI loading is itself a use: pull the companion in (unless
-- the user turned the picker bar off) so the bar can attach.
if EventUtil and EventUtil.ContinueOnAddOnLoaded then
    EventUtil.ContinueOnAddOnLoaded("Blizzard_MacroUI", function()
        if EasyFind.db and EasyFind.db.macroPickerSearch == false then return end
        ns.RequestIconSearch()
    end)
end

-- Item catalog: same LoadOnDemand companion pattern (EasyFind_Items).
-- Triggers: bar-open warm when the General Catalog filter is on, turning
-- that filter on, or applying @gen/@items -- never a keystroke (a 7MB
-- compile mid-typing would hitch). announce=true on the explicit paths
-- so a disabled companion explains itself once per session.
local itemModuleWarned = false
function ns.RequestItemCatalog(announce)
    if ns.ItemSearch then return true end
    if InCombatLockdown() then return false end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Items")
    end
    if ns.ItemSearch then return true end
    if announce and not itemModuleWarned then
        itemModuleWarned = true
        EasyFind:Print(ns.L["ITEMS_MODULE_DISABLED"])
    end
    return false
end

-- Options panel: LoadOnDemand companion (EasyFind_Options). Triggers are
-- every options open (slash, ESC category stub, tutorial link, resets) --
-- most sessions never pay for the panel at all.
local optionsModuleWarned = false
function ns.RequestOptionsPanel()
    if ns.Options then return true end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Options")
    end
    if ns.Options then return true end
    if not optionsModuleWarned then
        optionsModuleWarned = true
        EasyFind:Print(ns.L["OPTIONS_MODULE_DISABLED"])
    end
    return false
end

-- Blizzard settings search: LoadOnDemand companion (EasyFind_Settings).
-- Triggers mirror the old populate moments exactly: the first-focus warm
-- (unless both settings filter buckets are off) and explicit settings
-- queries -- so settings rows appear from the first real query, never at
-- login. announce=true on explicit paths only.
local settingsModuleWarned = false
function ns.RequestSettingsSearch(announce)
    if ns.BlizzOptionsSearch then return true end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Settings")
    end
    if ns.BlizzOptionsSearch then return true end
    if announce and not settingsModuleWarned then
        settingsModuleWarned = true
        EasyFind:Print(ns.L["SETTINGS_MODULE_DISABLED"])
    end
    return false
end

-- Guide engine: LoadOnDemand companion (EasyFind_Guide). Every entry point
-- is a guide-flavored gesture (starting a guide, a tab hint, a revealed-
-- frame glow); teardown and probe paths keep their nil no-op guards so a
-- session that never guides never loads it. Returns the module or nil.
local guideModuleWarned = false
function ns.RequestGuide()
    if ns.Highlight then return ns.Highlight end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Guide")
    end
    if ns.Highlight then return ns.Highlight end
    if not guideModuleWarned then
        guideModuleWarned = true
        EasyFind:Print(ns.L["GUIDE_MODULE_DISABLED"])
    end
    return nil
end

-- Onboarding surface (tutorial wizard, What's New popup, feature
-- spotlight): LoadOnDemand companion (EasyFind_Onboarding). Core loads it
-- at login only while onboarding is pending; the slash paths load it
-- explicitly. ns.Wizard is the loaded marker (ns.Onboarding is a seeded
-- module table, always truthy).
local onboardingModuleWarned = false
function ns.RequestOnboarding()
    if ns.Wizard then return true end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Onboarding")
    end
    if ns.Wizard then return true end
    if not onboardingModuleWarned then
        onboardingModuleWarned = true
        EasyFind:Print(ns.L["ONBOARDING_MODULE_DISABLED"])
    end
    return false
end

-- Can a LoadOnDemand companion load (or is it already in)? Entry-point UI
-- (filter rows, quick filter suggestions, app rows, launchers) hides when
-- the companion is disabled in the AddOns list, instead of advertising a
-- feature that can only answer with an error notice.
function ns.IsCompanionLoadable(name)
    if name == "EasyFind_Items" and ns.ItemSearch then return true end
    if name == "EasyFind_Icons" and ns.Results.ShowIconGrid then return true end
    if name == "EasyFind_Options" and ns.Options then return true end
    if name == "EasyFind_Settings" and ns.BlizzOptionsSearch then return true end
    if name == "EasyFind_Guide" and ns.Highlight then return true end
    if name == "EasyFind_Onboarding" and ns.Wizard then return true end
    if name == "EasyFind_Snippets" and ns.Snippets then return true end
    if not (C_AddOns and C_AddOns.GetAddOnEnableState) then return true end
    local ok, state = pcall(C_AddOns.GetAddOnEnableState, name)
    return ok and (tonumber(state) or 0) > 0
end
