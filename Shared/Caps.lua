-- Shared/Caps.lua
-- What this client has. EasyFind ships one zip for retail and WoW Forever,
-- and Forever runs the same UI codebase with whole systems switched off:
-- no pets, no toys, no currencies, no encounter journal, no housing, no
-- class specializations. Each answer is read once here, from the game's
-- own rules where it states them and from the API otherwise, and every
-- provider, filter row, quick filter, and options page asks this table
-- instead of probing on its own.
local _, ns = ...

local Caps = {}
ns.Caps = Caps

local function rule(name)
    -- True when the game rule of that name is active. Unknown names and
    -- clients without game rules answer nil, never an error.
    if not (C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule) then return nil end
    local id = Enum.GameRule[name]
    if not id then return nil end
    local ok, active = pcall(C_GameRules.IsGameRuleActive, id)
    if ok then return active and true or false end
    return nil
end
Caps.Rule = rule

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

-- A Blizzard panel is there when its addon loads. The addon info call
-- says "loadable" for panels Forever then refuses with WRONG_GAME_TYPE,
-- so on the classic-rules client the load itself is the test, once per
-- panel and cached; retail, where every panel loads, is never asked.
local panelKnown = {}
local forever = (tonumber((select(4, GetBuildInfo()))) or 0) < 20000
function Caps.PanelEnabled(addonName)
    if not forever then return true end
    local known = panelKnown[addonName]
    if known ~= nil then return known end
    local ok, _, _, _, _, reason = pcall(C_AddOns.GetAddOnInfo, addonName)
    if ok and reason == "MISSING" then panelKnown[addonName] = true return true end  -- baked in, not an addon here
    if ok and (reason == "DISABLED" or reason == "INCOMPATIBLE") then panelKnown[addonName] = false return false end
    local okL, loaded, why = pcall(C_AddOns.LoadAddOn, addonName)
    local enabled = (okL and loaded) and true or (why ~= "WRONG_GAME_TYPE" and why ~= "DISABLED" and why ~= "INCOMPATIBLE")
    panelKnown[addonName] = enabled and true or false
    return panelKnown[addonName]
end

-- A toggle binding exists only for a feature the client has: Forever
-- defines no TOGGLEACHIEVEMENT, and its achievement panel is a shell.
-- Read on first use, since the binding list is empty while files load.
local bindingSet
function Caps.HasBinding(name)
    if not bindingSet or next(bindingSet) == nil then
        bindingSet = {}
        local n = GetNumBindings and GetNumBindings() or 0
        for i = 1, n do
            local cmd = GetBinding(i)
            if type(cmd) == "string" then bindingSet[cmd] = true end
        end
        if n == 0 then return true end  -- not readable yet: fail open
    end
    return bindingSet[name] == true
end

-- The client itself.
local version, build, _, toc = GetBuildInfo()
Caps.version = version
Caps.build = tonumber(build)
Caps.interface = tonumber(toc) or 0
-- Forever: the 1.x game on the mainline codebase (interface 16001).
Caps.forever = Caps.interface < 20000
Caps.retail = not Caps.forever

-- Systems. Each is a plain boolean, decided once at load.
Caps.specs = type(GetNumSpecializationsForClassID) == "function"
    and type(GetSpecializationInfoForClassID) == "function"
Caps.journal = rule("EncounterJournalDisabled") ~= true
    and type(EncounterJournal_LoadUI) == "function"
    and Caps.PanelEnabled("Blizzard_EncounterJournal")
Caps.housing = rule("HousingDashboardDisabled") ~= true
    and rule("HousingEnabled") ~= false
    and Caps.PanelEnabled("Blizzard_HousingDashboard")
    and C_Housing ~= nil
    and not Caps.forever
Caps.achievements = rule("AchievementsPanelDisabled") ~= true
    and type(GetCategoryList) == "function"
    and Caps.PanelEnabled("Blizzard_AchievementUI")
    and not Caps.forever   -- the panel loads and is a shell; no toggle binding exists
-- Forever draws the Appearances tab over a wardrobe that holds nothing,
-- and asking it for a category does not fail, it takes the client down:
-- GetCategoryAppearances aborts on BC_ASSERT(m_has_value), a C++ assert
-- that pcall cannot catch (measured 2026-09-18, crash 1FC77402, and the
-- same assert behind a player report). Nothing here may touch the
-- wardrobe on that client, so the whole system is off.
Caps.transmog = rule("TransmogEnabled") ~= false
    and C_TransmogCollection ~= nil
    and not Caps.forever
-- Forever's collections journal hides the mount, pet, toy and heirloom
-- tabs (only Appearances shows), so the journal rows have nowhere to go.
Caps.mounts = C_MountJournal ~= nil and C_MountJournal.GetMountIDs ~= nil and not Caps.forever
-- Pets, toys, heirlooms, currencies: the API stays even when the game has
-- none, so the count of everything the game knows is the answer.
do
    local total = C_PetJournal and C_PetJournal.GetNumPets and select(2, call(C_PetJournal.GetNumPets))
    Caps.pets = rule("PetBattlesDisabled") ~= true and C_PetJournal ~= nil and not Caps.forever
    Caps.petCountKnown = total
end
Caps.toys = C_ToyBox ~= nil and not Caps.forever
Caps.heirlooms = C_Heirloom ~= nil and not Caps.forever
Caps.currencies = C_CurrencyInfo ~= nil and not Caps.forever
Caps.warbandBank = C_Bank ~= nil and C_Bank.FetchPurchasedBankTabData ~= nil and not Caps.forever
Caps.classTalents = C_ClassTalents ~= nil and C_Traits ~= nil
Caps.oldTalents = type(GetTalentInfo) == "function" and type(GetNumTalentTabs) == "function"
Caps.talents = rule("TalentsPanelDisabled") ~= true and (Caps.classTalents or Caps.oldTalents)
Caps.delves = C_DelvesUI ~= nil and not Caps.forever
Caps.mythicPlus = C_MythicPlus ~= nil and not Caps.forever
Caps.perks = C_PerksProgram ~= nil and not Caps.forever
Caps.editMode = rule("EditModeDisabled") ~= true and C_EditMode ~= nil
Caps.macros = rule("MacrosDisabled") ~= true
Caps.professions = rule("ProfessionsPanelDisabled") ~= true
Caps.gearSets = C_EquipmentSet ~= nil
Caps.outfits = Caps.transmog
Caps.ammo = rule("EnableAmmoSystem") == true
Caps.campsites = C_WarbandScene ~= nil and not Caps.forever
-- Warband-wide reputations and legacy reputation headers: retail's
-- account-wide reputation system, absent on Forever.
Caps.warbandRep = C_Reputation ~= nil and C_Reputation.IsAccountWideReputation ~= nil and not Caps.forever
Caps.pvpUI = Caps.PanelEnabled("Blizzard_PVPUI")
Caps.groupFinder = Caps.PanelEnabled("Blizzard_GroupFinder")
Caps.collectionsUI = Caps.PanelEnabled("Blizzard_Collections")

-- Which panel a UI entry's steps open, by the frame they wait for, and
-- which micro button stands for which binding: a UI entry is offered only
-- when both are there.
Caps.FRAME_PANEL = {
    PVEFrame = "Blizzard_GroupFinder", GroupFinderFrame = "Blizzard_GroupFinder", PVPQueueFrame = "Blizzard_PVPUI",
    EncounterJournal = "Blizzard_EncounterJournal", AchievementFrame = "Blizzard_AchievementUI",
    CollectionsJournal = "Blizzard_Collections", PlayerSpellsFrame = "Blizzard_PlayerSpells",
    MacroFrame = "Blizzard_MacroUI", ProfessionsFrame = "Blizzard_Professions", HousingDashboardFrame = "Blizzard_HousingDashboard",
    CommunitiesFrame = "Blizzard_Communities", CalendarFrame = "Blizzard_Calendar",
}
Caps.BUTTON_BINDING = {
    AchievementMicroButton = "TOGGLEACHIEVEMENT", EJMicroButton = "TOGGLEENCOUNTERJOURNAL",
    CollectionsMicroButton = "TOGGLECOLLECTIONS", LFDMicroButton = "TOGGLEGROUPFINDER",
    GuildMicroButton = "TOGGLEGUILDTAB", TalentMicroButton = "TOGGLETALENTS", QuestLogMicroButton = "TOGGLEQUESTLOG",
}

-- Why a UI entry (micro button plus steps) cannot be reached on this
-- client, or nil when it can. Cheap: table lookups and one cached
-- binding scan.
function Caps.UIEntryBlocked(entry)
    -- A node may name the system it needs outright (caps = "pets").
    if entry.caps and Caps[entry.caps] == false then return "no " .. entry.caps end
    -- PvP entries (queues, PvP talents, war mode) need the PvP window.
    if entry.isPvP and not Caps.pvpUI then return "Blizzard_PVPUI disabled" end
    local bf = entry.buttonFrame
    if bf then
        local binding = Caps.BUTTON_BINDING[bf]
        if binding and not Caps.HasBinding(binding) then return "no " .. binding end
        local b = _G[bf]
        if not b then return "no " .. bf end
        -- A hidden micro button counts only on the classic-rules client;
        -- retail hides Help too and its entry has always worked.
        if Caps.forever and b.IsShown and not b:IsShown() then return bf .. " hidden" end
    end
    local steps = entry.steps
    if steps then
        for i = 1, #steps do
            local s = steps[i]
            local panel = s.waitForFrame and Caps.FRAME_PANEL[s.waitForFrame]
            if panel and not Caps.PanelEnabled(panel) then return panel .. " disabled" end
            if s.waitForFrame == "CharacterFrame" and CharacterFrame and (s.tabIndex or s.tabFrame)
                and not Caps.CharacterTab(s.tabFrame or s.tabIndex) then
                return "no character tab " .. tostring(s.tabFrame or s.tabIndex)
            end
            if s.sidebarIndex and not Caps.CharacterSidebarSlot(s.sidebarIndex) then
                return "no character sidebar " .. s.sidebarIndex
            end
            if s.buttonFrame then
                local binding = Caps.BUTTON_BINDING[s.buttonFrame]
                if binding and not Caps.HasBinding(binding) then return "no " .. binding end
            end
        end
    end
    return nil
end

-- The character panel, by what each control opens rather than by its
-- number. Entries carry retail's numbers: tab 1 Character, 2 Reputation,
-- 3 Currency; sidebar 1 Stats, 2 Titles, 3 Equipment Manager. Forever
-- draws mode tabs that name their frame (CharacterFrameModeTab<n> with a
-- frameName field) and a sidebar with no Titles, so the number is looked
-- up here and nil means "not on this client".
local CHARACTER_TAB_FRAME = { [1] = "PaperDollFrame", [2] = "ReputationFrame", [3] = "TokenFrame" }
local SIDEBAR_FRAME = { [1] = "CharacterStatsPane", [2] = "PaperDollTitlesPane", [3] = "PaperDollEquipmentManagerPane" }
-- Forever's sidebar list carries names, not frames: the same global
-- strings on both clients.
local SIDEBAR_NAME = { [1] = "PAPERDOLL_SIDEBAR_STATS", [2] = "PAPERDOLL_SIDEBAR_TITLES", [3] = "PAPERDOLL_SIDEBAR_EQUIPMENT" }

-- The live tab control for a retail tab number or a subframe name
-- ("SkillsFrame"), or nil.
function Caps.CharacterTab(tabIndex)
    local want = type(tabIndex) == "string" and tabIndex or CHARACTER_TAB_FRAME[tabIndex]
    if type(tabIndex) == "string" then
        -- Retail numbers its tabs; the name maps back to one there.
        for i, f in pairs(CHARACTER_TAB_FRAME) do if f == tabIndex then tabIndex = i end end
    end
    local tabs = _G["CharacterFrameModeTabs"]
    if tabs and want then
        for i = 1, select("#", tabs:GetChildren()) do
            local tab = select(i, tabs:GetChildren())
            if tab and tab.frameName == want then return tab end
        end
        return nil
    end
    if type(tabIndex) ~= "number" then return nil end
    local tab = _G["CharacterFrameTab" .. tabIndex]
    if not tab and CharacterFrame and CharacterFrame.Tabs then tab = CharacterFrame.Tabs[tabIndex] end
    return tab
end

-- The live sidebar slot for a retail sidebar number, or nil. Blizzard
-- lists the sidebars in PAPERDOLL_SIDEBARS with the pane each opens.
function Caps.CharacterSidebarSlot(sidebarIndex)
    local want = SIDEBAR_FRAME[sidebarIndex]
    local wantName = SIDEBAR_NAME[sidebarIndex] and _G[SIDEBAR_NAME[sidebarIndex]]
    local list = _G["PAPERDOLL_SIDEBARS"]
    if type(list) == "table" and want then
        for i = 1, #list do
            local s = list[i]
            if type(s) == "table" and (s.frame == want or (wantName and s.name == wantName)) then return i end
        end
        -- Only the classic-rules client drops a sidebar; retail keeps its
        -- numbers whatever the list looks like.
        return Caps.forever and nil or sidebarIndex
    end
    return sidebarIndex
end

-- Spell ranks: Forever has them; retail's spells carry no rank text.
Caps.spellRanks = Caps.forever and C_Spell ~= nil and C_Spell.GetSpellSubtext ~= nil

-- Dynamic providers and filter keys that need a system this client lacks.
-- A key listed here is dropped from the provider table, the filter tree,
-- and the quick filters at load, so nothing advertises a dead feature.
local NEEDS = {
    pets = "pets", toys = "toys", heirlooms = "heirlooms", currencies = "currencies",
    housing = "housing", loot = "journal", bosses = "journal", delves = "delves",
    warband = "warbandBank", achievements = "achievements", statistics = "achievements",
    talents = "talents", outfits = "outfits", appearances = "transmog",
    transmogSets = "transmog", appearanceItems = "transmog", mounts = "mounts",
    perks = "perks", macros = "macros", professions = "professions", gearSets = "gearSets",
}
Caps.NEEDS = NEEDS

-- True when the feature behind a provider or filter key exists here. Keys
-- with no entry are always available.
function Caps.Has(key)
    local need = NEEDS[key]
    if not need then return true end
    return Caps[need] and true or false
end

-- Prune a list of { key = ... } rows in place, and any flyoutSubFilters
-- under them, to what this client has.
function Caps.PruneRows(rows)
    if type(rows) ~= "table" then return rows end
    for i = #rows, 1, -1 do
        local row = rows[i]
        if type(row) == "table" and row.key and not Caps.Has(row.key) then
            table.remove(rows, i)
        elseif type(row) == "table" then
            if row.flyoutSubFilters then Caps.PruneRows(row.flyoutSubFilters) end
            -- Choices inside a flyout may name a system too (caps = "warbandRep").
            local radio = row.flyoutRadio
            if radio then
                for _, list in ipairs({ radio.options, radio.checkboxes }) do
                    if type(list) == "table" then
                        for j = #list, 1, -1 do
                            local opt = list[j]
                            if type(opt) == "table" and opt.caps and Caps[opt.caps] == false then table.remove(list, j) end
                        end
                    end
                end
            end
        end
    end
    return rows
end

-- One line for /dump or a dev tool.
function Caps.Summary()
    local on, off = {}, {}
    for k, v in pairs(Caps) do
        if type(v) == "boolean" then
            if v then on[#on + 1] = k else off[#off + 1] = k end
        end
    end
    table.sort(on) table.sort(off)
    return string.format("%s (%s) on: %s | off: %s", tostring(version), tostring(toc), table.concat(on, " "), table.concat(off, " "))
end
