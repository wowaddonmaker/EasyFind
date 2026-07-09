local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local Icons = ns.ResultIcons
local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ipairs = Utils.ipairs
local InCombatLockdown = InCombatLockdown
local C_MountJournal = C_MountJournal
local C_PetJournal = C_PetJournal
local C_TransmogSets = C_TransmogSets

function Handlers:FinishResultSelection()
    Search:SetSelectingResult(true)
    Search:GetSearchFrame().editBox:SetText("")
    Search:GetSearchFrame().editBox:ClearFocus()
    Search:GetSearchFrame().editBox.placeholder:Show()
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

    self:FinishResultSelection()

    -- the secure macrotext attribute set when the row was rendered. The
    -- click already ran the command; nothing else for SelectResult to do.
    if data.slashCommand then return end



    -- Profession row: ONE canonical opener, like every other panel.
    -- OpenRecipe loads/opens the window AND selects the recipe in one call;
    -- driving OpenProfessionUIToSkillLine first double-initialized the list
    -- (StoreCollapses indexed a nil dataProvider on close). The child-page
    -- open stands alone for profession rows; the book is the last fallback.
    if data.professionSkillLine then
        local recipeID = data.professionRecipeID
        local openRecipe = C_TradeSkillUI and C_TradeSkillUI.OpenRecipe
        if recipeID and openRecipe then
            pcall(openRecipe, recipeID)
            return
        end
        local openProf = _G["OpenProfessionUIToSkillLine"]
        if openProf and data.professionOpenID then
            pcall(openProf, data.professionOpenID)
            if recipeID then
                -- Cold session: OpenRecipe materializes once the window's
                -- addon loads; select the recipe as soon as it exists.
                local tries = 0
                local function selectRecipe()
                    local fn = C_TradeSkillUI and C_TradeSkillUI.OpenRecipe
                    if fn then
                        pcall(fn, recipeID)
                        return
                    end
                    tries = tries + 1
                    if tries < 20 then Utils.SafeAfter(0.2, selectRecipe) end
                end
                Utils.SafeAfter(0.2, selectRecipe)
            end
        elseif _G["ToggleProfessionsBook"] then
            pcall(_G["ToggleProfessionsBook"])
        end
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

    -- Title: set as current. SetCurrentTitle is unprotected and updates
    -- the player's nameplate immediately, no journal navigation needed.
    if data.titleID then
        if SetCurrentTitle then SetCurrentTitle(data.titleID) end
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
        if forceGuide or Handlers:IsSourceModifierHeld() then
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
