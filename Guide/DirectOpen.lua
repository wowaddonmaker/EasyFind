local _, ns = ...

local Guide = ns.Guide
local Openers = ns.SearchOpeners
local Results = ns.Results
local Utils = ns.Utils

local GetButtonText = Utils.GetButtonText
local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
local ClickButton = Utils.ClickButton
local ipairs = Utils.ipairs
local slower = Utils.slower
local C_Reputation = C_Reputation

local EncounterDataMatches
EncounterDataMatches = function(value, targetID, targetName)
    if not value then return false end
    if targetID and (value.encounterID == targetID or value.journalEncounterID == targetID or value.id == targetID) then
        return true
    end
    local name = value.name or value.title or value.text
    if targetName and name and slower(name) == targetName then return true end
    local nested = value.data or value.elementData
    if nested and nested ~= value then
        return EncounterDataMatches(nested, targetID, targetName)
    end
    return false
end

local function GetEJBossesScrollBox()
    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
    return infoFrame and infoFrame.BossesScrollBox
end

local function EncounterFrameMatches(btn, targetID, targetName)
    local edata = btn.GetElementData and btn:GetElementData()
    if EncounterDataMatches(edata, targetID, targetName) then return true end
    if targetID and (btn.encounterID == targetID or btn.journalEncounterID == targetID or btn.id == targetID) then
        return true
    end
    local text = GetButtonText(btn)
    return targetName and text and slower(text) == targetName
end

local function RevealEJEncounter(step)
    local targetID = step.ejEncounterID
    local targetName = step.ejBoss and slower(step.ejBoss)
    local function reveal()
        local scrollBox = GetEJBossesScrollBox()
        if not scrollBox then return end
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return EncounterDataMatches(edata, targetID, targetName)
        end)
        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
            return EncounterFrameMatches(btn, targetID, targetName)
        end)
        if bossBtn and bossBtn.GetElementData and scrollBox.ScrollToElementData then
            local edata = bossBtn:GetElementData()
            if edata then
                scrollBox:ScrollToElementData(edata, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
            end
        end
    end
    reveal()
    Utils.SafeAfter(0.05, reveal)
end

-- Direct open mode - programmatically navigates to the target as far as possible.
-- Executes ALL steps that represent clickable navigation (tabs, categories, buttons).
-- Falls back to highlighting when the final step is a non-navigable Search region the
-- user needs to locate (e.g. PvP Talents tray, War Mode button), OR when a navigable
-- target button is present but disabled (a feature locked at the current level, like
-- the Rated PvP tab below max level). There's nothing to click, so it points the
-- user at where navigation stopped instead of stalling silently.
function Guide:DirectOpen(data)
    if not data or not data.steps or #data.steps == 0 then return end
    if Utils.GuideBlockedInCombat and Utils.GuideBlockedInCombat(data) then return end

    local steps = data.steps
    local totalSteps = #steps
    local Highlight = ns.Highlight

    -- For reputation steps, pre-expand all needed headers via API.
    local needsReputationResync = false
    for _, step in ipairs(steps) do
        if step.factionHeader then
            needsReputationResync = true
            if C_Reputation and C_Reputation.GetNumFactions then
                local headerNameLower = slower(step.factionHeader)
                local numFactions = C_Reputation.GetNumFactions()
                for i = 1, numFactions do
                    local factionData = C_Reputation.GetFactionDataByIndex(i)
                    if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
                        local isCollapsed = false
                        if factionData.isHeaderExpanded ~= nil then
                            isCollapsed = not factionData.isHeaderExpanded
                        elseif factionData.isCollapsed ~= nil then
                            isCollapsed = factionData.isCollapsed
                        end
                        if isCollapsed then
                            C_Reputation.ExpandFactionHeader(i)
                        end
                        break
                    end
                end
            end
        end
    end

    -- For currency steps: don't pre-expand headers, don't resync. Both
    -- ExpandCurrencyList and the tab-toggle resync write ScrollBar /
    -- ScrollBox state via Blizzard's refresh / OnShow handlers, and those
    -- writes get attributed to us (we triggered them) -- which blocks the
    -- protected RequestCurrencyFromAccountCharacter call at Confirm.
    -- HighlightCurrencyRowOrHint polls for the row to come into view once
    -- the player expands the header / scrolls themselves.
    local needsCurrencyResync = false

    -- Determine whether a step is "navigable" (can be auto-executed) vs "highlight-only"
    -- (just points at a Search region the user needs to see).
    -- A step is navigable if it has any clickable action property.
    local function isStepNavigable(step)
        if step.buttonFrame then return true end
        if step.gameMenuText then return true end
        if step.tabIndex then return true end
        if step.sideTabIndex then return true end
        if step.pvpSideTabIndex then return true end
        if step.sidebarButtonFrame or step.sidebarIndex then return true end
        if step.statisticsCategory then return true end
        if step.achievementCategory then return true end
        if step.currencyHeader then return true end
        if step.currencyID then return true end
        if step.factionHeader then return true end
        if step.factionID then return true end
        if step.searchButtonText then return true end
        if step.portraitMenuOption then return true end
        if step.ejInstance then return true end
        if step.ejBoss then return true end
        if step.ejLootTab then return true end
        if step.wardrobeSetsTab then return true end
        if step.wardrobeItemsTab then return true end
        if step.housingCatalogTab then return true end
        if step.appearanceSourceID then return true end
        if step.transmogSetID then return true end
        if step.transmogVariantDropdown then return true end
        if step.transmogVariantSetID then return true end
        -- regionFrames alone (no searchButtonText) = highlight-only (e.g. PvP Talents)
        -- waitForFrame alone = just waiting for a frame to appear, not navigable
        -- text alone = instruction text, not navigable
        return false
    end

    local lastStep = steps[totalSteps]
    local finalStepNavigable = isStepNavigable(lastStep)

    -- Auto-clicking the final step taints state that blocks protected actions
    -- (JoinBattlefield, etc.).
    if data.canQueue and finalStepNavigable then
        finalStepNavigable = false
    end

    -- How many steps to execute programmatically:
    -- If final step is navigable, execute ALL steps (no highlight needed).
    -- If final step is highlight-only, execute all but the last, then highlight it.
    local executeCount = finalStepNavigable and totalSteps or (totalSteps - 1)

    -- If there's nothing to execute programmatically (single highlight-only step),
    -- just start the normal guide.
    if executeCount == 0 then
        EasyFind:StartGuide(data)
        return
    end

    -- Execute all navigable steps synchronously in one frame. WoW frame
    -- operations (ClickButton, tab selection) process immediately, so
    -- child frames are available right after their parent is shown.
    -- The only exception is currency/reputation tab resync, which toggles
    -- tabs and needs one frame for the ScrollBox to rebuild.
    local tabClickAttempts = {}
    local categoryClickAttempts = {}

    -- Click a navigable target button. A present-but-disabled button (a feature
    -- locked at the current level) has nothing to click, so hand that step to the
    -- guide highlight, which points the user at where navigation stopped. Returns
    -- true when it handed off, so the caller stops executing remaining steps.
    local function clickOrHandoff(btn, stepIdx)
        if btn and btn.IsEnabled and not btn:IsEnabled() and Highlight then
            data.noCourseCorrect = true
            Highlight:StartGuideAtStep(data, stepIdx)
            return true
        end
        ClickButton(btn)
        return false
    end

    local function executeFrom(start)
        for i = start, executeCount do
            local step = steps[i]

            if step.loadTransmog then
                if not TransmogFrame then
                    Transmog_LoadUI()
                end
                if TransmogFrame then
                    Openers:SecureShowUIPanel(TransmogFrame)
                    Results:ApplyTransmogBrowseMode()
                end
                return
            end

            -- Game Menu button by text: open the menu (if not already)
            -- and click the labeled child. Handles unnamed dynamic-ID
            -- buttons in modern GameMenuFrame.
            if step.gameMenuText then
                if not GameMenuFrame:IsShown() then
                    pcall(GameMenuFrame.Show, GameMenuFrame)
                end
                local btn = Highlight:FindGameMenuButton(step.gameMenuText)
                if btn then ClickButton(btn) end
            end

            if step.buttonFrame then
                -- EncounterJournal: set selectedTab BEFORE opening so Blizzard's
                -- own init calls SetTab with our value (clean call stack, no taint)
                if step.buttonFrame == "EJMicroButton" then
                    local nextStep = steps[i + 1]
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.tabIndex then
                        EncounterJournal_LoadUI()
                        EncounterJournal.selectedTab = nextStep.tabIndex
                        Openers:SecureShowUIPanel(EncounterJournal)
                        -- Skip the tab step, continue from the step after it.
                        -- Defer one frame so the ScrollBox populates its items.
                        local resume = i + 2
                        Utils.SafeAfter(0, function() executeFrom(resume) end)
                        return
                    end
                    -- Boss navigation: set tier + dungeon/raid tab before showing
                    -- so the InstanceSelect ScrollBox populates with the right
                    -- tier's instances on first paint. ShowUIPanel is a no-op
                    -- when EJ is already shown (OnShow / SetTab won't refire),
                    -- so we still need an explicit tab click to apply the new
                    -- tier when the user re-opens onto a different expansion.
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.ejTier then
                        EncounterJournal_LoadUI()
                        if EJ_SelectTier then EJ_SelectTier(nextStep.ejTier) end
                        local tabIdx = nextStep.ejTabIsRaid and 5 or 4
                        -- No programmatic tab click: EJ_ContentTab_OnClick
                        -- reaches a protected SetTab, which is FORBIDDEN
                        -- from addon execution even through
                        -- securecallfunction (break-test measured, both
                        -- ways). OnShow applies selectedTab cleanly, so
                        -- the warm case cycles Hide -> Show to refire it.
                        EncounterJournal.selectedTab = tabIdx
                        if EncounterJournal:IsShown() and HideUIPanel then
                            HideUIPanel(EncounterJournal)
                        end
                        Openers:SecureShowUIPanel(EncounterJournal)
                        local resume = i + 2
                        Utils.SafeAfter(0, function() executeFrom(resume) end)
                        return
                    end
                end
                Openers:OpenButtonFrame(step.buttonFrame, steps[i + 1])
            end

            if step.waitForFrame and step.tabIndex then

                local resync = false
                if step.waitForFrame == "CharacterFrame" then
                    if needsCurrencyResync and step.tabIndex == 3 then
                        resync = true
                        needsCurrencyResync = false
                    elseif needsReputationResync and step.tabIndex == 2 then
                        resync = true
                        needsReputationResync = false
                    end
                end
                if resync then
                    -- Toggle tabs to force ScrollBox rebuild with expanded headers.
                    -- Needs one frame to propagate; defer remaining steps.
                    Openers:OpenCharacterFrame(1)
                    local tabIdx = step.tabIndex
                    local resume = i + 1
                    Utils.SafeAfter(0.05, function()
                        Openers:OpenCharacterFrame(tabIdx)
                        executeFrom(resume)
                    end)
                    return
                elseif step.waitForFrame == "CharacterFrame" then
                    Openers:OpenCharacterFrame(step.tabIndex)
                elseif step.waitForFrame == "PlayerSpellsFrame" then
                    -- Secure release steer normally landed already;
                    -- otherwise highlights the tab (see EnsurePlayerSpellsTab).
                    Openers:EnsurePlayerSpellsTab(step.tabIndex)
                elseif step.waitForFrame ~= "EncounterJournal" then
                    ClickButton(Highlight:GetTabButton(step.waitForFrame, step.tabIndex))
                end

                local nextStep = steps[i + 1]
                if step.waitForFrame == "AchievementFrame" and nextStep
                   and (nextStep.achievementCategory or nextStep.statisticsCategory) then
                    local tabReady = true
                    if Highlight and Highlight.IsTabSelected then
                        tabReady = Highlight:IsTabSelected("AchievementFrame", step.tabIndex)
                    end
                    if not tabReady then
                        local key = tostring(i) .. ":tab:" .. tostring(step.tabIndex)
                        tabClickAttempts[key] = (tabClickAttempts[key] or 0) + 1
                        if tabClickAttempts[key] <= 6 then
                            local resume = i
                            Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                            return
                        end
                    end

                    local resume = i + 1
                    Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            if step.sideTabIndex then
                if clickOrHandoff(Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex), i) then return end
            end

            if step.pvpSideTabIndex then
                if clickOrHandoff(Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex), i) then return end
            end

            if step.sidebarButtonFrame or step.sidebarIndex then
                self:ClickCharacterSidebar(step.sidebarIndex)
            end

            local categoryToClick = step.statisticsCategory or step.achievementCategory
            if categoryToClick then
                local categoryID = step.statisticsCategoryID or step.achievementCategoryID
                if not self:ClickAchievementCategory(categoryToClick, categoryID) then
                    local key = tostring(i) .. ":" .. tostring(categoryID or categoryToClick)
                    categoryClickAttempts[key] = (categoryClickAttempts[key] or 0) + 1
                    if categoryClickAttempts[key] <= 6 then
                        local resume = i
                        Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                        return
                    end
                end

                local nextStep = steps[i + 1]
                if nextStep and (nextStep.achievementCategory or nextStep.statisticsCategory) then
                    local resume = i + 1
                    Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            if step.achievementID then
                self:OpenAchievementByID(step.achievementID)
            end

            -- EJ tier + dungeon/raid tab (boss navigation when EJ is already
            -- open). The EJMicroButton fast path handles the cold-open case;
            -- this branch handles re-opens on a different tier.
            if step.waitForFrame == "EncounterJournal" and step.ejTier then
                if EJ_SelectTier then EJ_SelectTier(step.ejTier) end
                local tabIdx = step.ejTabIsRaid and 5 or 4
                EncounterJournal.selectedTab = tabIdx
                local tabBtn = Highlight:GetTabButton("EncounterJournal", tabIdx)
                if tabBtn then ClickButton(tabBtn) end
                -- Defer remaining steps so the InstanceSelect ScrollBox can
                -- rebuild with the new tier's instances before we look up
                -- the target instance by name.
                local resume = i + 1
                Utils.SafeAfter(0, function() executeFrom(resume) end)
                return
            end

            -- EJ instance: prefer the EncounterJournal_DisplayInstance API
            -- (synchronous, no ScrollBox race) when we have the instanceID,
            -- otherwise fall back to scanning visible buttons by name.
            if step.ejInstance then
                local displayInstance = _G["EncounterJournal_DisplayInstance"]
                if step.ejInstanceID and displayInstance then
                    pcall(displayInstance, step.ejInstanceID)
                else
                    local scrollBox = _G["EncounterJournalInstanceSelect"] and _G["EncounterJournalInstanceSelect"].ScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejInstance)
                        local instBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local text = Utils.GetButtonText(btn)
                            return text and slower(text) == targetName
                        end)
                        if instBtn then ClickButton(instBtn) end
                    end
                end
                -- Display rebuilds the BossesScrollBox dataprovider, but
                -- buttons / overview content aren't laid out until next
                -- frame. Defer so the ejBoss/ejLootTab step that follows
                -- scans a populated list.
                local nextStep = steps[i + 1]
                if nextStep and (nextStep.ejBoss or nextStep.ejLootTab) then
                    local resume = i + 1
                    Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ boss: prefer EncounterJournal_DisplayEncounter API when we
            -- have the encounterID. Falls back to ScrollBox button scan.
            if step.ejBoss then
                local displayEncounter = _G["EncounterJournal_DisplayEncounter"]
                if step.ejEncounterID and displayEncounter then
                    pcall(displayEncounter, step.ejEncounterID)
                    RevealEJEncounter(step)
                else
                    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                    local scrollBox = infoFrame and infoFrame.BossesScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejBoss)
                        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
                            return EncounterDataMatches(edata, step.ejEncounterID, targetName)
                        end)
                        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            return EncounterFrameMatches(btn, step.ejEncounterID, targetName)
                        end)
                        if bossBtn then ClickButton(bossBtn) end
                    end
                    RevealEJEncounter(step)
                end
                -- ejLootTab needs a frame for the boss content to settle
                -- before we click the loot tab (otherwise Overview eats
                -- the click and the loot list never appears).
                local nextStep = steps[i + 1]
                if nextStep and nextStep.ejLootTab then
                    local resume = i + 1
                    Utils.SafeAfter(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ loot tab: click
            if step.ejLootTab then
                if step.ejDifficultyID and ns.Database then
                    ns.Database:SetEJDifficulty(step.ejDifficultyID)
                end
                local lootTab = _G["EncounterJournalEncounterFrameInfoLootTab"]
                if lootTab then ClickButton(lootTab) end
            end

            -- EJ loot item: highlight only (last step)
            if step.ejLootItem and i == executeCount then
                local Highlight = ns.Highlight
                local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                local scrollBox = infoFrame and (
                    (infoFrame.LootContainer and infoFrame.LootContainer.ScrollBox)
                    or infoFrame.LootScrollBox or infoFrame.ScrollBox
                )
                if scrollBox then
                    local targetID = step.ejLootItem
                    local itemName = step.ejLootItemName
                    Utils.SafeAfter(0.05, function()
                        local itemBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local edata = btn.GetElementData and btn:GetElementData()
                            if edata and edata.itemID == targetID then return true end
                            if itemName then
                                local text = Utils.GetButtonText(btn)
                                if text then
                                    local clean = slower(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                                    if clean == slower(itemName) then return true end
                                end
                            end
                            return false
                        end)
                        if itemBtn and Highlight then
                            Highlight:HighlightFrame(itemBtn)
                            local checkHover
                            checkHover = function()
                                if itemBtn:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    Utils.SafeAfter(0.1, checkHover)
                                end
                            end
                            Utils.SafeAfter(0.3, checkHover)
                        end
                    end)
                end
            end

            -- Housing catalog tab: the dashboard is a named-tab owner whose
            -- SetTab takes the tab object (dash.catalogTab), not an index.
            -- Switch, then fill the catalog search box once CatalogContent
            -- is up (the switch can land a frame later).
            if step.housingCatalogTab then
                local dash = _G["HousingDashboardFrame"]
                if dash then
                    local function fillCatalogSearch()
                        local content = dash.CatalogContent
                        if not (content and content:IsShown()) then return false end
                        if step.housingCatalogSearch then
                            local searchBox = content.Filters and content.Filters.SearchBox
                            if searchBox and searchBox.SetText then
                                pcall(searchBox.SetText, searchBox, step.housingCatalogSearch)
                            end
                        end
                        return true
                    end
                    -- Once the search is in, scroll the grid to the entry and
                    -- highlight its tile; results land asynchronously, so
                    -- retry a few times before settling for the filtered view.
                    local Highlight = ns.Highlight
                    local tries = 0
                    local function tryHighlightEntry()
                        if not Highlight or not Highlight.ScrollToHousingCatalogEntry then return end
                        local tile = Highlight:ScrollToHousingCatalogEntry(step.housingCatalogRecordID)
                        if tile then
                            Highlight:HighlightFrame(tile)
                            local checkHover
                            checkHover = function()
                                if tile:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    Utils.SafeAfter(0.1, checkHover)
                                end
                            end
                            Utils.SafeAfter(0.3, checkHover)
                            return
                        end
                        tries = tries + 1
                        if tries < 10 then
                            Utils.SafeAfter(0.25, tryHighlightEntry)
                        end
                    end
                    if fillCatalogSearch() then
                        tryHighlightEntry()
                    else
                        if dash.SetTab and dash.catalogTab then
                            pcall(dash.SetTab, dash, dash.catalogTab)
                        end
                        Utils.SafeAfter(0.15, function()
                            if fillCatalogSearch() then tryHighlightEntry() end
                        end)
                    end
                end
            end

            -- Wardrobe Sets tab: click the Sets tab within WardrobeCollectionFrame.
            -- Defer remaining steps so the SetsCollectionFrame ScrollBox populates.
            if step.wardrobeSetsTab then
                local wcf = _G["WardrobeCollectionFrame"]
                local setsTab = Highlight:GetTabButton("WardrobeCollectionFrame", 2)
                if setsTab then
                    ClickButton(setsTab)
                end
                if wcf then
                    local scf = wcf.SetsCollectionFrame
                    if not scf or not scf:IsShown() then
                        if wcf.SetTab then
                            pcall(wcf.SetTab, wcf, 2)
                        elseif PanelTemplates_SetTab then
                            pcall(PanelTemplates_SetTab, wcf, 2)
                        end
                    end
                end
                if i < executeCount then
                    local resume = i + 1
                    Utils.SafeAfter(0.1, function() executeFrom(resume) end)
                    return
                end
            end

            -- Wardrobe Items tab: click the Items tab within WardrobeCollectionFrame.
            if step.wardrobeItemsTab then
                local wcf = _G["WardrobeCollectionFrame"]
                local itemsTab = Highlight:GetTabButton("WardrobeCollectionFrame", 1)
                if itemsTab then
                    ClickButton(itemsTab)
                end
                if wcf then
                    local icf = wcf.ItemsCollectionFrame
                    if not icf or not icf:IsShown() then
                        if wcf.SetTab then
                            pcall(wcf.SetTab, wcf, 1)
                        elseif PanelTemplates_SetTab then
                            pcall(PanelTemplates_SetTab, wcf, 1)
                        end
                    end
                end
            end

            -- Appearance item: page to its slot + page. Deferred so the Items
            -- tab's visuals list has populated before GoToSourceID runs.
            if step.appearanceSourceID then
                local icf = _G["WardrobeCollectionFrame"]
                    and _G["WardrobeCollectionFrame"].ItemsCollectionFrame
                if icf and icf.GoToSourceID and icf.GetTransmogLocation then
                    local sourceID = step.appearanceSourceID
                    Utils.SafeAfter(0.1, function()
                        local ok, loc = pcall(icf.GetTransmogLocation, icf)
                        if ok and loc then
                            pcall(icf.GoToSourceID, icf, sourceID, loc)
                        end
                    end)
                end
            end

            -- Transmog set: scroll via SetScrollPercentage + select
            if step.transmogSetID and i == executeCount then
                local scf = _G["WardrobeCollectionFrame"]
                    and _G["WardrobeCollectionFrame"].SetsCollectionFrame
                if scf then
                    Utils.SafeAfter(0.1, function()
                        local lc = scf.ListContainer
                        local scrollBox = lc and lc.ScrollBox
                        if scrollBox and scrollBox.SetScrollPercentage then
                            local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
                            if dp then
                                local finder = dp.FindElementDataByPredicate or dp.FindByPredicate
                                local found = finder and finder(dp, function(ed)
                                    return ed and ed.setID == step.transmogSetID
                                end)
                                if found then
                                    local idx = dp.FindIndex and dp:FindIndex(found)
                                    local total = dp.GetSize and dp:GetSize()
                                    if idx and total and total > 1 then
                                        scrollBox:SetScrollPercentage((idx - 1) / (total - 1))
                                    end
                                end
                            end
                        end
                        if lc and lc.SelectElementDataMatchingSetID then
                            pcall(lc.SelectElementDataMatchingSetID, lc, step.transmogSetID)
                        end
                    end)
                end
            end

            -- Currency/faction headers pre-expanded via API, nothing to execute

            if step.currencyID then
                -- No auto-scroll for currencies: the ScrollBox method calls
                -- taint ScrollBar state, which blocks the protected currency
                -- transfer Confirm. The hint + polling in HighlightCurrencyRowOrHint
                -- handles the no-scroll UX (instruction text + auto-highlight
                -- once the row comes into view as the player mousewheels).
                -- Collect ALL ancestor header names in order from outermost
                -- to innermost. Nested currencies need each level expanded
                -- in order; the outermost collapsed one is what to highlight
                -- first because inner headers aren't visible until outer
                -- headers are expanded.
                local headerChain = {}
                for j = 1, i - 1 do
                    if steps[j].currencyHeader then
                        headerChain[#headerChain + 1] = steps[j].currencyHeader
                    end
                end
                if i == executeCount then
                    local cID = step.currencyID
                    local chain = headerChain
                    Utils.SafeAfter(0.05, function()
                        Highlight:HighlightCurrencyRowOrHint(cID, chain)
                    end)
                end
            end

            -- Header-level entry (e.g. "War Within Currencies"): no currencyID,
            -- the last currencyHeader step IS the destination.
            if step.currencyHeader and i == executeCount and not step.currencyID then
                local fullChain = {}
                for j = 1, i do
                    if steps[j].currencyHeader then
                        fullChain[#fullChain + 1] = steps[j].currencyHeader
                    end
                end
                local chain = fullChain
                Utils.SafeAfter(0.05, function()
                    Highlight:HighlightCurrencyRowOrHint(nil, chain)
                end)
            end

            if step.factionID then
                Highlight:ScrollToFactionRow(step.factionID)
                if i == executeCount then
                    local fID = step.factionID
                    Utils.SafeAfter(0.05, function()
                        local factionRow = Highlight:GetFactionRowButton(fID)
                        if factionRow then
                            Highlight:HighlightFrame(factionRow, nil)
                            local checkHover
                            checkHover = function()
                                if factionRow:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    Utils.SafeAfter(0.1, checkHover)
                                end
                            end
                            Utils.SafeAfter(0.3, checkHover)
                        end
                    end)
                end
            end

            if step.lfgCategoryID then
                if clickOrHandoff(Highlight:FindLfgCategoryButton(step.lfgCategoryID, step.lfgFilters), i) then return end
            elseif step.searchButtonText then
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    if clickOrHandoff(SearchFrameTreeFuzzy(parentFrame, slower(step.searchButtonText)), i) then return end
                end
            end
        end

        -- Hand off remaining steps to the guided highlight. DirectOpen
        -- is left-click "open + show me where", not the right-click
        -- guided walkthrough, so flag the data so the highlight ticker
        -- cancels (instead of rewinding to step 1 and reopening) if the
        -- user closes the parent window with the highlight still active.
        if not finalStepNavigable and Highlight then
            data.noCourseCorrect = true
            Highlight:StartGuideAtStep(data, executeCount + 1)
        end
    end

    executeFrom(1)
end

