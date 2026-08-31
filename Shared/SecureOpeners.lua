local _, ns = ...

-- Taint-free Blizzard panel opens.
--
-- Opening a Blizzard panel from addon execution (ShowUIPanel,
-- PlayerSpellsUtil.TogglePlayerSpellsFrame, a programmatic :Click() on a
-- Blizzard button) runs Blizzard's entire open pipeline tainted, and what
-- that pipeline writes stays tainted for the session. Measured carrier:
-- opening the spellbook writes the action bars' drag-grid bookkeeping, so
-- MultiBarBottomLeft.showAllButtons ends up tainted, and in
-- combat every hover re-reads it and gets ADDON_ACTION_BLOCKED blamed on
-- EasyFind, while spellbook opens storm secret-value errors.
--
-- The one taint-free route an addon has is the secure input system: result
-- rows and shortkey buttons are SecureActionButtonTemplates, so a row whose
-- action opens PlayerSpellsFrame gets type="macro" with macrotext
-- "/click PlayerSpellsMicroButton". The macro runs inside the secure click
-- dispatch and drives Blizzard's own micro button, so the whole open
-- pipeline executes securely and nothing is left to poison.
--
-- Why the macro targets Blizzard's button directly and not an addon proxy
-- button: a synthetic /click on an addon SecureActionButton is dead on two
-- independent counts (verified against Blizzard_FrameXML/SecureTemplates.lua
-- and Blizzard_ChatFrameBase/Shared/SlashCommands.lua, 12.0.7). First,
-- /click sends a single up-edge click (down = StringToBoolean("", false))
-- with isSecureAction unset, and SecureActionButton_OnClick drops it:
-- clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown),
-- where useOnKeyDown defaults to the ActionButtonUseKeyDown CVar (default
-- 1); "typerelease" is only consulted on the press-and-hold release path
-- (pressAndHoldAction attribute), never for a plain up-click. Second, since
-- 11.0.2 macros and macrotext may not /click a button whose own action is a
-- macro, which is exactly what a proxy would be. A plain Blizzard button has
-- neither problem: Button:Click() ignores RegisterForClicks and fires its
-- OnClick handler for any edge.
--
-- Tab steering is the second, independent taint vector (measured: the flag
-- flips the moment EasyFind clicks the panel's tab, even after a fully
-- secure open). The tabs are unnamed, so no
-- macrotext can reach them, but the secure "click" action takes a raw
-- frame reference (clickbutton attribute). One hardware click carries both
-- actions through Blizzard's press-and-hold mechanism: with
-- pressAndHoldAction set, the press fires "type" (the open macro) and the
-- release fires "typerelease" ("click" delegating to the tab button), both
-- in secure execution. Rows therefore register both left edges, and their
-- navigation follow-up runs on the release dispatch, after the tab is
-- already steered, so the insecure ClickButton(tab) fallbacks never run in
-- row-driven flows.
--
-- While the panel is already shown, GetOpenMacro returns nil so the press
-- cannot toggle the panel closed (the release still steers, harmlessly and
-- securely); rows and shortkey buttons re-sync their attributes from
-- PreClick, so the armed state always matches the panel state at click
-- time.

local SecureOpeners = {}
ns.SecureOpeners = SecureOpeners

local Utils = ns.Utils
local pairs = Utils.pairs
local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local strrep = string.rep

-- PlayerSpellsFrame tab indexes, exported so steer targets and the
-- handlers that verify them can never drift apart.
SecureOpeners.TAB_TALENTS = 2
SecureOpeners.TAB_SPELLBOOK = 3

local PANELS = {
    playerSpells = {
        micro = "PlayerSpellsMicroButton",
        panel = "PlayerSpellsFrame",
        addon = "Blizzard_PlayerSpells",
        defaultTab = SecureOpeners.TAB_SPELLBOOK,
    },
}

for _, spec in pairs(PANELS) do
    spec.openMacroText = "/click " .. spec.micro
    spec.tabButtons = {}
end

-- Entries whose primary click opens a Blizzard panel we can open securely,
-- keyed by the entry's own opener frame.
local BUTTONFRAME_PANEL = {
    ["PlayerSpellsMicroButton"] = "playerSpells",
}

-- The panel key for a result whose activation opens a Blizzard panel:
-- entries that drive the micro button directly, plus Talent and
-- spellbook-only-ability entries (they carry spellID but never cast; their
-- click opens PlayerSpellsFrame and navigates within it).
function SecureOpeners.OpenKeyForData(data)
    if not data then return nil end
    local key = BUTTONFRAME_PANEL[data.buttonFrame]
    if key then return key end
    if data.spellID and (data.category == "Talent"
       or Utils.IsSpellbookOnlyAbility(data)) then
        return "playerSpells"
    end
    return nil
end

function SecureOpeners.IsPanelShown(key)
    local spec = PANELS[key]
    local panel = spec and _G[spec.panel]
    return panel ~= nil and panel:IsShown()
end

-- The macrotext a row (or shortkey button) carries to open the panel through
-- fully secure execution. Nil while the panel is shown, so the armed click
-- can never toggle it closed, and nil when the Blizzard button is missing
-- (callers keep their legacy path).
function SecureOpeners.GetOpenMacro(key)
    local spec = PANELS[key]
    if not spec or not _G[spec.micro] then return nil end
    if SecureOpeners.IsPanelShown(key) then return nil end
    return spec.openMacroText
end

-- The panel addon is load-on-demand: the tab buttons the release steer
-- delegates to only exist once it has loaded. Called from PreClick (never
-- at render time, to keep result rendering hitch-free); Blizzard-signed
-- addon files run secure regardless of who triggers the load.
function SecureOpeners.EnsureLoaded(key)
    local spec = PANELS[key]
    if not spec or _G[spec.panel] then return end
    Utils.LoadBlizzardAddOn(spec.addon)
end

local function SteerTabIndexFor(spec, data)
    -- An explicit tab step wins; otherwise fall through to the category/
    -- spellID defaults. Ability entries carry steps = {{spellID}} with no
    -- tab step, and their spell reveal needs the spellbook tab -- an early
    -- "steps but no tab step -> no steer" return here left them opening on
    -- whatever tab the panel last showed.
    local steps = data.steps
    if steps then
        for i = 1, #steps do
            local step = steps[i]
            if step.waitForFrame == spec.panel and step.tabIndex then
                return step.tabIndex
            end
        end
    end
    if data.category == "Talent" then return SecureOpeners.TAB_TALENTS end
    if data.spellID then return spec.defaultTab end
    return nil
end

-- The tab button the release edge clicks (via the secure "click" action's
-- clickbutton frame ref). Nil when the panel addon has not loaded yet or
-- the entry has no tab preference. Resolved buttons are memoized per spec:
-- TabSystem tabs are created once at panel load and frames never die
-- within a session, and caching only non-nil resolutions preserves the
-- panel-not-yet-loaded retry behavior.
function SecureOpeners.GetTabButtonFor(key, tabIndex)
    local spec = PANELS[key]
    if not (spec and tabIndex) then return nil end
    local cached = spec.tabButtons[tabIndex]
    if cached then return cached end
    if not _G[spec.panel] then return nil end
    local highlight = ns.RequestGuide and ns.RequestGuide() or nil
    if not (highlight and highlight.GetTabButton) then return nil end
    local tab = highlight:GetTabButton(spec.panel, tabIndex)
    spec.tabButtons[tabIndex] = tab
    return tab
end

function SecureOpeners.GetSteerTabButton(key, data)
    local spec = PANELS[key]
    if not (spec and data) then return nil end
    return SecureOpeners.GetTabButtonFor(key, SteerTabIndexFor(spec, data))
end

-- The spellbook-style default tab, for flows that always reveal there
-- (the alt+click "show in spellbook" swap).
function SecureOpeners.GetDefaultTabButton(key)
    local spec = PANELS[key]
    return spec and SecureOpeners.GetTabButtonFor(key, spec.defaultTab) or nil
end

-- A macro is the one secure action that can fire several clicks from a
-- single hardware click, and macrotext can "/click" any PLAIN button by
-- name. The spellbook page buttons are unnamed, so each gets a named
-- click-type proxy: a SecureActionButton whose "click" action delegates to
-- the page button via frame ref. "/click <proxy>" sends a single up-edge,
-- so the proxy pins useOnKeyDown=false to act on it. The 11.0.2 chain ban
-- only bars /click onto buttons whose own action is a MACRO; a click-type
-- proxy is legal, and the whole chain runs inside secure dispatch
-- (navtest [8]: full multi-page journey in one click, zero new tainted
-- provider fields, spell casts stay silent afterwards). Proxies are
-- per-target and created once; the frame-keyed cache can only ever hold
-- one entry per page button.
local clickProxies, clickProxyCount = {}, 0
function SecureOpeners.GetClickChainMacro(targetButton, presses)
    if not (targetButton and presses and presses > 0) then return nil end
    local proxy = clickProxies[targetButton]
    if not proxy then
        if InCombatLockdown() then return nil end
        clickProxyCount = clickProxyCount + 1
        proxy = CreateFrame("Button", "EasyFindClickProxy" .. clickProxyCount,
            UIParent, "SecureActionButtonTemplate")
        proxy:SetSize(1, 1)
        proxy:SetPoint("BOTTOMRIGHT", UIParent, "TOPLEFT", -32, 32)
        proxy:EnableMouse(false)
        Utils.SafeCallMethod(proxy, "SetAttribute", "useOnKeyDown", false)
        Utils.SafeCallMethod(proxy, "SetAttribute", "type", "click")
        Utils.SafeCallMethod(proxy, "SetAttribute", "clickbutton", targetButton)
        clickProxies[targetButton] = proxy
    end
    return strrep("/click " .. proxy:GetName() .. "\n", presses)
end

-- True when the panel is shown with this tab button's tab already selected.
-- Steering onto an already-selected tab is not harmless: the release-edge
-- re-click lands AFTER a down-edge nav macro and Blizzard's tab-set can
-- reset the spellbook back to page 1, undoing the flip.
function SecureOpeners.IsTabButtonSelected(key, tabButton)
    local spec = PANELS[key]
    local panel = spec and _G[spec.panel]
    if not (panel and panel.GetTab and tabButton and panel:IsShown()) then
        return false
    end
    local ok, selectedID = pcall(panel.GetTab, panel)
    if not ok or not selectedID then return false end
    if tabButton.GetTabID then
        local ok2, tabID = pcall(tabButton.GetTabID, tabButton)
        if ok2 and tabID then return tabID == selectedID end
    end
    return false
end
