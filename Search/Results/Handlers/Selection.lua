local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local Icons = ns.ResultIcons
local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ipairs = Utils.ipairs
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local C_Item = C_Item
local C_MountJournal = C_MountJournal
local C_PetJournal = C_PetJournal
local C_TransmogSets = C_TransmogSets

function Handlers:FinishResultSelection()
    Search:SetSelectingResult(true)
    Search:GetSearchFrame().editBox:SetText("")
    Search:GetSearchFrame().editBox:ClearFocus()
    Search:GetSearchFrame().editBox.placeholder:Show()
    -- A quick filter is part of the query, so clearing the query clears it too
    -- (ESC already does this). Leaving the '@' pill behind silently narrows the
    -- next search the user types. No refresh: the bar is being dismissed.
    Search:ClearQuickFilter(false)
    Search:HideQuickFilterSuggestions()
    Search:SetSelectingResult(false)
    if EasyFind.db.autoHide then
        self:Hide()
    else
        self:HideResults()
        if EasyFind.db.smartShow then
            Search:GetSearchFrame().smartShowFadeOut()
        end
    end
end

-- OpenProfessionUIToSkillLine wants a profession's CHILD skill line -- the
-- expansion page, e.g. 2912 for Midnight Herbalism -- never the parent (182).
-- Given the child it opens a fully populated window; given the parent it shows
-- the frame with no recipe dataProvider, so the list reads "no results with
-- your current filters" and closing it throws from StoreCollapses.
--
-- Derived, never captured: GetAllProfessionTradeSkillLines lists every child
-- line newest-expansion-first, and GetProfessionInfoBySkillLineID says which
-- profession each belongs to, so the first match for this profession IS the
-- current page. (Verified against the two hand-captured values this replaces:
-- Herbalism 2912 and Enchanting 2874 both sit at the front of that list.)
-- GetProfessionChildSkillLineID looks like the obvious call but returns 0
-- until a profession window has been opened, so it cannot be used to open one.
local function ResolveChildSkillLine(parentSkillLine)
    local ts = C_TradeSkillUI
    if not (parentSkillLine and ts and ts.GetAllProfessionTradeSkillLines
            and ts.GetProfessionInfoBySkillLineID) then
        return nil
    end
    local okParent, parentInfo = pcall(ts.GetProfessionInfoBySkillLineID, parentSkillLine)
    if not (okParent and type(parentInfo) == "table" and parentInfo.profession) then
        return nil
    end
    local okAll, allLines = pcall(ts.GetAllProfessionTradeSkillLines)
    if not (okAll and type(allLines) == "table") then return nil end
    -- That list is every expansion page in the GAME, not the ones this
    -- character has. Opening a page they never leveled gives a window with no
    -- recipes to provide -- which is the blank list, and why the two captured
    -- IDs worked (they name pages that character actually has). So take the
    -- newest page this character has SKILL in, and only fall back to the
    -- newest page at all if none of them report skill.
    local firstMatch
    for i = 1, #allLines do
        local lineID = allLines[i]
        if lineID and lineID ~= parentSkillLine then
            local okInfo, info = pcall(ts.GetProfessionInfoBySkillLineID, lineID)
            if okInfo and type(info) == "table" and info.profession == parentInfo.profession then
                firstMatch = firstMatch or lineID
                if (info.skillLevel or 0) > 0 then return lineID end
            end
        end
    end
    return firstMatch
end

-- Opening a profession COLD is the whole difficulty. Blizzard_Professions
-- loads on demand, and OpenProfessionUIToSkillLine triggers that load itself,
-- so the frame can show before its recipe list has a data provider: an empty
-- list reading "no results with your current filters", and StoreCollapses
-- throwing on close. Warm, the same skill line opens correctly -- which is how
-- we know the ID is right and the timing is not.
--
-- So load the addon first, then open, then verify the list actually got its
-- provider and re-issue once if it did not. Same shape as the recipe path's
-- cold-session retry.
local function ProfessionListHasData()
    local frame = _G["ProfessionsFrame"]
    local list = frame and frame.CraftingPage and frame.CraftingPage.RecipeList
    local scrollBox = list and list.ScrollBox
    if not (scrollBox and scrollBox.GetDataProvider) then return nil end
    local ok, provider = pcall(scrollBox.GetDataProvider, scrollBox)
    if not ok then return nil end
    return provider ~= nil
end

-- Load first so an open call is never also an addon load; the load half of
-- a combined call is what races the aim (page or recipe selection) away.
local function EnsureProfessionsLoaded()
    if C_AddOns and C_AddOns.LoadAddOn and C_AddOns.IsAddOnLoaded
       and not C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_Professions")
    end
end

local function OpenProfessionPage(openID)
    local openProf = _G["OpenProfessionUIToSkillLine"]
    if not openProf then return false end
    EnsureProfessionsLoaded()
    pcall(openProf, openID)
    -- One re-issue if the list came up without data, guarded by an explicit
    -- false (nil = we could not inspect it, so leave it alone). Recipe data
    -- is a server round trip, so a next-frame check would always see the
    -- provider still missing and re-issue into the first open's own init;
    -- check only after the reply has had time to land, and never re-open a
    -- window the user already closed.
    Utils.SafeAfter(0.35, function()
        local frame = _G["ProfessionsFrame"]
        if frame and frame:IsShown() and ProfessionListHasData() == false then
            pcall(openProf, openID)
        end
    end)
    return true
end

-- The recipe the window is actually displaying, via Blizzard's own accessor
-- (ProfessionsCrafting.lua reads the same path). nil = no window / no form /
-- nothing shown.
local function DisplayedRecipeID()
    local profFrame = _G["ProfessionsFrame"]
    local form = profFrame and profFrame.CraftingPage
        and profFrame.CraftingPage.SchematicForm
    if not (form and form.GetRecipeInfo) then return nil end
    local ok, info = pcall(form.GetRecipeInfo, form)
    return ok and type(info) == "table" and info.recipeID or nil
end

local function OpenPageOrBook(openID)
    if openID and OpenProfessionPage(openID) then return end
    if _G["ToggleProfessionsBook"] then
        pcall(_G["ToggleProfessionsBook"])
    end
end

-- THE profession opener: every profession row funnels through here, one
-- verify-then-re-aim engine for every target kind. Verified fallbacks, never
-- fire-and-forget: each aim is checked after the cold-open window (addon
-- load + server recipe data) has had time to land, and re-aimed at most once.
--
-- Recipe rows: OpenRecipe opens the window AND selects the recipe -- but a
-- COLD first open also loads Blizzard_Professions and lands on the
-- character's default page, dropping a cross-page selection (a Classic
-- recipe on a character whose window defaults to a newer page). Warm, the
-- same call selects fine, so verify what the schematic form shows and
-- re-issue once.
--
-- Parent rows with a secure cast: the cast on the click's own dispatch is
-- the opener; if no profession window appeared (dud spell), fall back to the
-- insecure page open. Cast-less parent rows page-open immediately.
local function OpenProfessionTarget(data)
    local recipeID = data.professionRecipeID
    local openRecipe = C_TradeSkillUI and C_TradeSkillUI.OpenRecipe
    if recipeID and openRecipe then
        EnsureProfessionsLoaded()
        pcall(openRecipe, recipeID)
        -- Cold cross-page verify. No timer guessing: the wait target is
        -- observable -- the re-aim is safe exactly when the list has its
        -- data provider (init done, warm-equivalent), so poll fast and
        -- re-aim the moment it exists instead of after a fixed delay.
        -- One re-aim only; the remaining ticks just confirm.
        local tries, reAimed = 0, false
        local function verify()
            local profFrame = _G["ProfessionsFrame"]
            if profFrame and profFrame:IsShown() then
                if DisplayedRecipeID() == recipeID then return end
                if not reAimed and ProfessionListHasData() then
                    reAimed = true
                    pcall(openRecipe, recipeID)
                end
            end
            tries = tries + 1
            if tries < 15 then Utils.SafeAfter(0.1, verify) end
        end
        Utils.SafeAfter(0.1, verify)
        return
    end
    -- The shipped childSkillLine is whatever page the CAPTURING character
    -- had (Tailoring was captured on a Zandalari-capped alt), so the live
    -- resolver -- THIS character's newest leveled page -- outranks it and
    -- the captured value is only the no-API fallback.
    local openID = ResolveChildSkillLine(data.professionSkillLine) or data.professionOpenID
    if data.spellID then
        Utils.SafeAfter(0.8, function()
            local profFrame = _G["ProfessionsFrame"]
            if profFrame and profFrame:IsShown() then return end
            -- Archaeology's cast opens its own frame, not ProfessionsFrame.
            local archFrame = _G["ArchaeologyFrame"]
            if archFrame and archFrame:IsShown() then return end
            OpenPageOrBook(openID)
        end)
        return
    end
    OpenPageOrBook(openID)
end

function Handlers:SelectResult(data, forceGuide)
    if not data then return end
    -- The search UI is dormant in combat, so no user path reaches this;
    -- programmatic callers get a silent no-op. Even finishing a selection
    -- touches protected frames (hiding the results frame that ancestors
    -- secure rows), so nothing here is combat-safe.
    if InCombatLockdown() then return end
    local useFast = not forceGuide

    if data.quickFilterDef then
        self:ApplyQuickFilter(data.quickFilterDef, "")
        return
    end

    -- Catalog item. A mouse click or drag picks the item up onto the cursor to
    -- send its link (see Rows/Interactions); this path handles Ctrl (try it on
    -- in the dressing room) and keyboard Enter, which has no cursor pickup and
    -- so is a no-op lookup. Shift (chat link) is handled upstream in PreClick.
    -- Never navigates -- catalog rows are a lookup and keep the results open.
    if data.catalogItem then
        if IsControlKeyDown() then
            local link = C_Item and C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(data.itemID))
            if link and DressUpItemLink then DressUpItemLink(link) end
            self:FinishResultSelection()
        end
        -- A plain click dismisses too, but from the row's OnMouseUp (after the
        -- cursor pickup); hiding the row here, on the press, would cancel it.
        return
    end

    if data.searchCommand then
        -- Dismiss the bar like any other selection before running the command,
        -- so /reset etc. don't leave the (now empty) bar lingering on screen.
        -- Capture first: FinishResultSelection clears the search and can recycle
        -- this data table.
        local cmd = data.searchCommand
        self:FinishResultSelection()
        self:RunSearchBarCommand("/" .. cmd)
        return
    end

    if data.nativeRun then
        local run = data.nativeRun
        self:FinishResultSelection()
        run()
        return
    end

    -- Pinned native command: storage keeps only strings, so the run
    -- callback is re-resolved by name. Secure ones carry slashCommand and
    -- already ran via the row's macrotext attribute instead.
    if data.category == "Command" and not data.slashCommand
        and ns.SearchCommands and ns.SearchCommands.ResolveNativeRun then
        local run = ns.SearchCommands:ResolveNativeRun(data.name)
        if run then
            self:FinishResultSelection()
            run()
            return
        end
    end

    if data.calculatorLauncher then
        self:OpenCalculator("")
        return
    end

    if data.calculatorResult then
        self:ArmCalculatorResultForData(data)
        return
    end

    -- Titles are resolved BEFORE FinishResultSelection: that call clears the
    -- search and can recycle this data table (see the searchCommand branch),
    -- so titleID and the resolved achievement are captured while they are
    -- still guaranteed to belong to the row that was clicked.
    if data.titleID then
        local titleID = data.titleID
        local unearned = data.titleUnearned
        local altHeld = Handlers:IsSourceModifierHeld()
        local achID = ns.Database and ns.Database.GetTitleSourceAchievement
            and ns.Database:GetTitleSourceAchievement(titleID)
        self:FinishResultSelection()
        -- Alt opens the achievement that awards it, the same way Alt opens the
        -- owning UI everywhere else. An unearned title cannot be applied, so a
        -- plain click takes that route too rather than doing nothing.
        if achID and (altHeld or unearned) then
            self:OpenAchievementByID(achID)
        elseif not unearned and SetCurrentTitle then
            SetCurrentTitle(titleID)
        end
        -- Unearned with no source achievement (PvP ranks, quest and event
        -- titles have none): nothing to open. Deliberately NOT the Titles
        -- pane -- a title you have not earned is not listed there, so sending
        -- the player to it is a dead end. The row stays informational; the
        -- right-click Wowhead link is the way to look it up.
        return
    end

    self:FinishResultSelection()

    -- the secure macrotext attribute set when the row was rendered. The
    -- click already ran the command; nothing else for SelectResult to do.
    if data.slashCommand then return end



    -- Profession row: OpenProfessionTarget is the ONE owner of profession
    -- opening -- recipe aim, secure-cast verify, page fallback, and the
    -- cold-open re-aim engine all live there. Never open a profession
    -- surface from anywhere else; driving OpenProfessionUIToSkillLine on top
    -- of another opener double-initialized the list (StoreCollapses indexed
    -- a nil dataProvider on close).
    if data.professionSkillLine then
        OpenProfessionTarget(data)
        return
    end

    -- Transmogrification panel: load and show TransmogFrame
    if data.steps and data.steps[1] and data.steps[1].loadTransmog then
        if not TransmogFrame then
            Transmog_LoadUI()
        end
        if TransmogFrame then
            Openers:SecureShowUIPanel(TransmogFrame)
            self:ApplyTransmogBrowseMode()
        end
        return
    end

    -- Quick Keybind Mode: a plain click enters the overlay directly. Alt+click
    -- falls through to the settings-category step below, which opens Keybindings
    -- and highlights the button instead.
    if data.quickKeybindActivate and not Handlers:IsSourceModifierHeld()
       and Openers:ActivateQuickKeybindMode() then
        return
    end

    -- Blizzard Settings panel. Fast mode opens the named category
    -- directly; Guide walks the real path (Game Menu -> Options via the
    -- user's own clicks), then hands the open panel to the settings
    -- machinery for category/control navigation.
    if data.steps and data.steps[1] and data.steps[1].settingsCategory then
        if forceGuide then
            local settingsStep = data.steps[1]
            EasyFind:StartGuide({
                name = data.name,
                steps = {
                    { buttonFrame = "MainMenuMicroButton" },
                    { gameMenuText = _G["GAMEMENU_OPTIONS"] or _G["OPTIONS"] or "Options" },
                    {
                        waitForFrame = "SettingsPanel",
                        settingsCategory = settingsStep.settingsCategory,
                        settingCategoryID = settingsStep.settingCategoryID,
                        settingVariable = settingsStep.settingVariable,
                    },
                },
            })
            return
        end
        if ns.BlizzOptionsSearch then
            ns.BlizzOptionsSearch:HandleStep(data.steps[1])
        end
        return
    end

    -- Outfit: default click equips via SecureActionButton. Alt+click
    -- suppresses that secure action in PreClick and opens the outfit list.
    if data.outfitID then
        if forceGuide or Handlers:IsSourceModifierHeld() then
            self:OpenOutfitInTransmog(data)
        end
        return
    end

    -- Housing decor: open the dashboard's catalog tab filtered to the item.
    -- Gate on recordID (a plain number the snapshot persists), not the entryID
    -- table, so a shortkey routes here even when the provider isn't loaded.
    if data.housingRecordID then
        local guideData = {
            name = data.name,
            steps = {
                { buttonFrame = "HousingMicroButton" },
                { waitForFrame = "HousingDashboardFrame", housingCatalogTab = true,
                  housingCatalogSearch = data.name,
                  housingCatalogRecordID = data.housingRecordID },
            },
        }
        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Loot: Ctrl+click opens dressing room, regular click navigates EJ
    if data.itemID and data.category == "Loot" then
        local lootLink = ns.Database and ns.Database:GetLootItemLink(data)
        if Handlers:IsSourceCtrlHeld() and lootLink then
            if DressUpItemLink(lootLink) then
                return
            end
        end

        -- Sync EJ loot filter so the item is visible when we navigate there
        if ns.Database then ns.Database:SyncEJLootFilter() end

        local isRaid = data.lootSourceType == "Raid"
        local tabIndex = isRaid and 5 or 4
        local ejDiffID = ns.Database and ns.Database:GetEJDifficultyID(data.lootSourceType)
        local guideData = {
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = tabIndex },
                { waitForFrame = "EncounterJournal", ejInstance = data.lootInstanceName, ejInstanceID = data.instanceID },
                { waitForFrame = "EncounterJournal", ejBoss = data.lootSourceName, ejEncounterID = data.encounterID },
                { waitForFrame = "EncounterJournal", ejLootTab = true, ejDifficultyID = ejDiffID },
                { waitForFrame = "EncounterJournal", ejLootItem = data.itemID, ejLootItemName = data.name },
            },
        }

        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Appearance Set: Ctrl+click opens dressing room with full set, regular click navigates.
    -- For pinned entries saved before transmogSetID was persisted, recover the
    -- ID by looking up the set name in the live database.
    if data.category == "Appearance Set" and not data.transmogSetID and data.name and ns.Database then
        data.transmogSetID = ns.Database:GetTransmogSetIDByName(data.name)
    end
    if data.transmogSetID then
        if Handlers:IsSourceCtrlHeld() then
            self:DressUpAppearanceSet(data.transmogSetID)
            return
        end

        local setID = data.transmogSetID
        local GetBaseSetID = C_TransmogSets.GetBaseSetID
        local baseID = GetBaseSetID and GetBaseSetID(setID) or setID
        local guideData = {
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 5 },
                { waitForFrame = "WardrobeCollectionFrame", wardrobeSetsTab = true },
                { waitForFrame = "WardrobeCollectionFrame", transmogSetID = baseID },
            },
        }
        if baseID ~= setID then
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantDropdown = true }
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantSetID = setID }
        end
        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Appearance item: open Collections > Appearances > Items, page to the
    -- appearance's slot + page via GoToSourceID, and highlight its tile.
    if data.appearanceItemID then
        local guideData = {
            name = data.name,
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 5 },
                { waitForFrame = "WardrobeCollectionFrame", wardrobeItemsTab = true },
                { waitForFrame = "WardrobeCollectionFrame",
                  appearanceSourceID = data.appearanceItemID,
                  appearanceVisualID = data.appearanceVisualID,
                  appearanceSlot = data.appearanceSlot },
            },
        }
        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Mount: summon only when the mount is actually usable here. Alt+click
    -- opens Collections > Mounts; Ctrl+click uses Blizzard's mount preview.
    if data.mountID then
        if Handlers:IsSourceCtrlHeld() then
            if self:PreviewMountInDressUp(data) then return end
            self:OpenMountInJournal(data)
            return
        end
        if forceGuide then
            EasyFind:StartGuide(self:BuildMountJournalGuideData(data))
            return
        end
        if Handlers:IsSourceModifierHeld() or not Icons:IsMountSummonable(data) then
            self:OpenMountInJournal(data)
            return
        end
        if C_MountJournal and C_MountJournal.SummonByID then
            C_MountJournal.SummonByID(data.mountID)
        end
        return
    end

    -- Heirloom: create the item in the player's bags. Mirrors clicking
    -- a tile in the HeirloomsJournal: API hands you a fresh copy.
    if data.heirloomItemID then
        -- Alt (or guide mode): open Collections > Heirlooms instead of adding
        -- a copy to the bags.
        if forceGuide or Handlers:IsSourceModifierHeld() then
            local guideData = {
                name = data.name,
                buttonFrame = "CollectionsMicroButton",
                steps = {
                    { buttonFrame = "CollectionsMicroButton" },
                    { waitForFrame = "CollectionsJournal", tabIndex = 4 },
                },
            }
            if forceGuide then EasyFind:StartGuide(guideData) else self:DirectOpen(guideData) end
            return
        end
        if C_Heirloom and C_Heirloom.CreateHeirloom then
            C_Heirloom.CreateHeirloom(data.heirloomItemID)
        end
        return
    end

    -- Gear set: equip via Equipment Manager. Skipped in combat, the
    -- API silently fails there, so no point trying.
    if data.gearSetID then
        if InCombatLockdown() then return end
        if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
            C_EquipmentSet.UseEquipmentSet(data.gearSetID)
        end
        return
    end

    -- Toy: default click uses via the SecureActionButton type=toy
    -- attribute. Alt+click and unusable toys route to the ToyBox.
    if data.toyItemID then
        if forceGuide then
            EasyFind:StartGuide(self:BuildToyBoxGuideData(data))
        elseif data.isToyboxOnly or Handlers:IsSourceModifierHeld() then
            self:OpenToyInToyBox(data)
        end
        return
    end

    -- Talents: open Talents tab and highlight the matching node. Routed
    -- here (before the generic spellID branch) because talents share the
    -- spellID field with abilities but should never cast.
    if data.category == "Talent" and data.talentNodeID then
        -- Talent entries already carry the full step chain (micro button
        -- -> Talents tab -> node); Guide walks it, fast mode drives the
        -- panel directly.
        if forceGuide and data.steps then
            EasyFind:StartGuide(data)
        else
            self:OpenTalentInTalentsTab(data)
        end
        return
    end

    if data.spellID then
        if forceGuide or Handlers:IsSourceModifierHeld() or Icons:IsSpellbookOnlyAbility(data) then
            -- Guide never opens the panel itself: the micro button is
            -- highlighted for the user's own click, then the reveal
            -- steers inside the open spellbook.
            self:OpenAbilityInSpellbook(data, forceGuide)
        end
        return
    end

    -- Pet: normal click summons. Guide and Alt+click route to the pet
    -- in Collections > Pet Journal instead; Alt uses DirectOpen so it
    -- skips the step-by-step guide and only highlights the destination.
    if data.petID or data.speciesID then
        -- An uncollected pet has nothing to summon, so a plain click reveals it
        -- in the Pet Journal instead -- the same fall-through an uncollected
        -- mount takes (its hint says "Click: Pet Journal" to match).
        if forceGuide or Handlers:IsSourceModifierHeld()
           or not Icons:IsPetSummonable(data) then
            local guideData = self:BuildPetJournalGuideData(data)
            if useFast then
                self:DirectOpen(guideData)
            else
                EasyFind:StartGuide(guideData)
            end
            return
        end

        if C_PetJournal then
            local guid = self:ResolvePetGUID(data)
            if guid and C_PetJournal.SummonPetByGUID then
                C_PetJournal.SummonPetByGUID(guid)
                if guid ~= data.petID then data.petID = guid end
            end
        end
        return
    end

    if data.mapSearchResult then
        if ns.MapSearch and ns.MapSearch.HandleUISearchClick then
            ns.MapSearch:HandleUISearchClick(data, forceGuide)
        end
        return
    end

    -- Bag item: usable items (consumables, equippables) fire /use via the
    -- SecureActionButton on click: no bag Search needed. Non-usable items
    -- open the bag(s) containing them and highlight the slot.
    if data.itemID and data.category == "Bag" then
        if useFast then
            local actionKind = self:GetBagItemActionKind(data)
            if Handlers:IsSourceCtrlHeld() and actionKind == "equip"
               and data.bagItemLink and DressUpItemLink then
                if DressUpItemLink(data.bagItemLink) then return end
            end
            local showInBags = Handlers:IsSourceModifierHeld()
            -- Skip bag-open for anything the secure click will already act
            -- on: explicit Use spells, equippable gear, AND broad item
            -- types that "use" via right-click without a Use:tooltip line
            -- (Consumable / Container / Quest). Without the type fallback,
            -- right-click-openable containers like lockboxes still hit
            -- the bag-open path, so the bag visibly pops AND the
            -- container opens -- the user only wants the latter.
            if not showInBags and actionKind ~= "show" then
                return
            end
            self:OpenBagItemLocation(data)
            return
        end
        if not data.steps or #data.steps == 0 then return end
    end

    -- Macro: default click runs the macro (handled by the row's secure
    -- macro attribute). Alt+click opens MacroFrame for editing:
    -- PreClick clears the secure type when Alt is held so the macro
    -- guide via forceGuide=true.
    if data.macroIndex then
        if useFast then
            if Handlers:IsSourceModifierHeld() then
                Search:OpenMacroFrameAt(data.macroIndex, data.macroIsChar)
            end
            return
        end
        if data.steps then EasyFind:StartGuide(data) end
        return
    end

    if useFast and data.steps then
        -- Portrait menu can't be automated (secure frame restriction)
        local mustGuide = false
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                mustGuide = true
                break
            end
        end

        if mustGuide then
            EasyFind:StartGuide(data)
        else
            self:DirectOpen(data)
        end
    elseif data.steps then
        EasyFind:StartGuide(data)
    end
end
