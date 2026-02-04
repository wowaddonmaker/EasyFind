local ADDON_NAME, ns = ...

local Highlight = {}
ns.Highlight = Highlight

local highlightFrame
local arrowFrame
local instructionFrame
local currentGuide
local currentStepIndex
local stepTicker

function Highlight:Initialize()
    if highlightFrame then return end
    self:CreateHighlightFrame()
    self:CreateArrowFrame()
    self:CreateInstructionFrame()
end

function Highlight:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "FindItHighlightFrame", UIParent)
    highlightFrame:SetFrameStrata("TOOLTIP")
    highlightFrame:SetFrameLevel(500)
    highlightFrame:Hide()
    
    local borderSize = 4
    
    local top = highlightFrame:CreateTexture(nil, "OVERLAY")
    top:SetColorTexture(1, 1, 0, 1)
    highlightFrame.top = top
    
    local bottom = highlightFrame:CreateTexture(nil, "OVERLAY")
    bottom:SetColorTexture(1, 1, 0, 1)
    highlightFrame.bottom = bottom
    
    local left = highlightFrame:CreateTexture(nil, "OVERLAY")
    left:SetColorTexture(1, 1, 0, 1)
    highlightFrame.left = left
    
    local right = highlightFrame:CreateTexture(nil, "OVERLAY")
    right:SetColorTexture(1, 1, 0, 1)
    highlightFrame.right = right
    
    highlightFrame.borderSize = borderSize
    
    local animGroup = highlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0.3)
    alpha:SetDuration(0.5)
    highlightFrame.animGroup = animGroup
end

function Highlight:CreateArrowFrame()
    arrowFrame = CreateFrame("Frame", "FindItArrowFrame", UIParent)
    arrowFrame:SetSize(80, 80)  -- Large arrow for visibility
    arrowFrame:SetFrameStrata("TOOLTIP")
    arrowFrame:SetFrameLevel(501)
    arrowFrame:Hide()
    
    local arrow = arrowFrame:CreateTexture(nil, "ARTWORK")
    arrow:SetAllPoints()
    arrow:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
    arrow:SetVertexColor(1, 1, 0, 1)
    arrow:SetRotation(math.pi)
    arrowFrame.arrow = arrow
    
    -- Add glow behind arrow
    local glow = arrowFrame:CreateTexture(nil, "BACKGROUND")
    glow:SetSize(100, 100)
    glow:SetPoint("CENTER")
    glow:SetTexture("Interface\\Cooldown\\star4")
    glow:SetVertexColor(1, 1, 0, 0.6)
    glow:SetBlendMode("ADD")
    arrowFrame.glow = glow
    
    local animGroup = arrowFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local trans = animGroup:CreateAnimation("Translation")
    trans:SetOffset(0, -10)
    trans:SetDuration(0.4)
    arrowFrame.animGroup = animGroup
end

function Highlight:CreateInstructionFrame()
    instructionFrame = CreateFrame("Frame", "FindItInstructionFrame", UIParent, "BackdropTemplate")
    instructionFrame:SetSize(400, 90)
    instructionFrame:SetFrameStrata("TOOLTIP")
    instructionFrame:SetFrameLevel(502)
    instructionFrame:Hide()
    
    instructionFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    instructionFrame:SetBackdropColor(0, 0, 0, 0.95)  -- Very dark background
    
    local text = instructionFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("TOPLEFT", 15, -15)
    text:SetPoint("TOPRIGHT", -15, -15)
    text:SetTextColor(1, 1, 0)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)  -- Enable word wrap
    text:SetNonSpaceWrap(true)
    instructionFrame.text = text
    
    -- Dismiss button
    local dismissBtn = CreateFrame("Button", nil, instructionFrame, "UIPanelButtonTemplate")
    dismissBtn:SetSize(80, 22)
    dismissBtn:SetPoint("BOTTOM", 0, 8)
    dismissBtn:SetText("Got it!")
    dismissBtn:SetScript("OnClick", function()
        Highlight:Cancel()
    end)
    instructionFrame.dismissBtn = dismissBtn
    
    local closeBtn = CreateFrame("Button", nil, instructionFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", 5, 5)
    closeBtn:SetSize(20, 20)
    closeBtn:SetScript("OnClick", function()
        Highlight:Cancel()
    end)
end

function Highlight:StartGuide(guideData)
    self:Cancel()
    
    if not guideData or not guideData.steps or #guideData.steps == 0 then
        if guideData and guideData.steps and guideData.steps[1] and guideData.steps[1].customText then
            self:ShowInstruction(guideData.steps[1].customText)
            C_Timer.After(5, function() self:Cancel() end)
        end
        return
    end
    
    currentGuide = guideData
    currentStepIndex = 1
    
    -- Use a ticker to continuously check step conditions
    stepTicker = C_Timer.NewTicker(0.1, function()
        self:UpdateGuide()
    end)
end

function Highlight:UpdateGuide()
    if not currentGuide or not currentStepIndex then
        self:Cancel()
        return
    end
    
    local step = currentGuide.steps[currentStepIndex]
    if not step then
        self:Cancel()
        return
    end
    
    -- Custom text only
    if step.customText then
        self:ShowInstruction(step.customText)
        C_Timer.After(5, function() self:Cancel() end)
        return
    end
    
    local isLastStep = (currentStepIndex == #currentGuide.steps)
    
    -- Step 1 type: Highlight a button directly (like micro menu buttons)
    if step.buttonFrame then
        local btn = _G[step.buttonFrame]
        if btn and btn:IsShown() then
            -- Check if user clicked it (frame that button opens is now visible)
            local nextStep = currentGuide.steps[currentStepIndex + 1]
            if nextStep and nextStep.waitForFrame then
                local waitFrame = self:GetFrameByPath(nextStep.waitForFrame)
                if waitFrame and waitFrame:IsShown() then
                    -- User clicked button, frame is open, advance
                    self:AdvanceStep()
                    return
                end
            elseif not nextStep then
                -- Single step guide - dismiss on hover
                if btn:IsMouseOver() then
                    self:Cancel()
                    return
                end
            end
            
            -- Still need to click button - highlight only, no text
            self:HighlightFrame(btn)
        end
        return
    end
    
    -- Step 2+ type: Wait for frame, then highlight tab or region
    if step.waitForFrame then
        local frame = self:GetFrameByPath(step.waitForFrame)
        
        if not frame or not frame:IsShown() then
            -- Frame closed, go back to step 1
            currentStepIndex = 1
            self:HideHighlight()
            return
        end
        
        -- Frame is open
        if step.tabIndex then
            -- Check if already on correct tab
            if self:IsTabSelected(step.waitForFrame, step.tabIndex) then
                -- Correct tab, advance to next step
                self:AdvanceStep()
                return
            end
            
            -- Need to click tab
            local tabBtn = self:GetTabButton(step.waitForFrame, step.tabIndex)
            if tabBtn then
                -- Highlight tab, no text unless it's the last step and we can't find button
                self:HighlightFrame(tabBtn)
            elseif isLastStep then
                -- Can't find tab button on last step, show instruction
                self:ShowInstruction(step.text or "Click the correct tab")
            end
            return
        end
        
        -- Side tab (like Dungeon Finder / Raid Finder / Premade Groups in Group Finder)
        if step.sideTabIndex then
            -- Check if already on correct side tab
            if self:IsSideTabSelected(step.waitForFrame, step.sideTabIndex) then
                -- Correct tab, advance to next step
                self:AdvanceStep()
                return
            end
            
            -- Need to click side tab
            local sideBtn = self:GetSideTabButton(step.waitForFrame, step.sideTabIndex)
            if sideBtn then
                -- Highlight side tab, no text
                self:HighlightFrame(sideBtn)
            elseif isLastStep then
                -- Can't find side button on last step, show instruction
                self:ShowInstruction(step.text or "Click the correct option on the left")
            end
            return
        end
        
        -- PVP Side tab (Quick Match / Rated / Premade Groups / Training Grounds in PvP tab)
        if step.pvpSideTabIndex then
            -- Check if already on correct PvP side tab
            if self:IsPvPSideTabSelected(step.waitForFrame, step.pvpSideTabIndex) then
                -- Correct tab, advance to next step
                self:AdvanceStep()
                return
            end
            
            -- Need to click PvP side tab
            local pvpBtn = self:GetPvPSideTabButton(step.waitForFrame, step.pvpSideTabIndex)
            if pvpBtn then
                -- Highlight PvP side tab, no text
                self:HighlightFrame(pvpBtn)
            elseif isLastStep then
                -- Can't find side button on last step, show instruction
                self:ShowInstruction(step.text or "Click the correct option on the left")
            end
            return
        end
        
        -- Statistics category navigation (tree-based category selection)
        if step.statisticsCategory then
            -- Check if already on correct statistics category
            if self:IsStatisticsCategorySelected(step.statisticsCategory) then
                -- Correct category selected
                if isLastStep then
                    -- Final step and we're there - dismiss the guide
                    self:Cancel()
                else
                    -- Advance to next step
                    self:AdvanceStep()
                end
                return
            end
            
            -- Need to click category in tree - find and highlight the button
            local categoryBtn = self:GetStatisticsCategoryButton(step.statisticsCategory)
            if categoryBtn then
                self:HighlightFrame(categoryBtn)
            elseif isLastStep then
                self:ShowInstruction(step.text or "Click the category in the list on the left")
            end
            return
        end
        
        -- Text-only final step (when we've navigated but can't highlight specific element)
        if step.text and not step.regionFrames and not step.regionFrame then
            self:ShowInstruction(step.text)
            return
        end
        
        -- Highlight a region (like PvP talents area) - these are final destinations
        if step.regionFrames or step.regionFrame then
            local framePaths = step.regionFrames or { step.regionFrame }
            local region = nil
            
            -- Try each possible frame path
            for _, path in ipairs(framePaths) do
                local testFrame = self:GetFrameByPath(path)
                if testFrame and testFrame:IsShown() then
                    region = testFrame
                    break
                end
            end
            
            if region then
                -- Found the region, highlight it (no text needed)
                self:HighlightFrame(region)
                -- Check for hover to dismiss
                if region:IsMouseOver() then
                    self:Cancel()
                    return
                end
            else
                -- Can't find region frame, show instruction text since this is final step
                self:ShowInstruction(step.text or "Look for this area in the current window")
            end
            return
        end
        
        -- Search for a button by text (for PvP rated queue buttons like Solo Shuffle, 2v2, 3v3)
        if step.searchButtonText then
            local btn = self:FindRatedPvPButton(step.searchButtonText)
            if btn then
                self:HighlightFrame(btn)
                if btn:IsMouseOver() then
                    self:Cancel()
                    return
                end
            elseif isLastStep then
                self:ShowInstruction(step.text or ("Look for '" .. step.searchButtonText .. "' in the current window"))
            end
            return
        end
    end
end

function Highlight:AdvanceStep()
    self:HideHighlight()
    currentStepIndex = currentStepIndex + 1
    
    if currentStepIndex > #currentGuide.steps then
        self:Cancel()
    end
end

function Highlight:GetFrameByPath(path)
    if not path then return nil end
    
    -- Special dynamic lookups for unnamed frames
    if path == "FIND_WARMODE_BUTTON" then
        return self:FindWarModeButton()
    end
    if path == "FIND_PVP_TALENTS" then
        return self:FindPvPTalentsTray()
    end
    
    local parts = {strsplit(".", path)}
    local current = _G[parts[1]]
    for i = 2, #parts do
        if current then
            current = current[parts[i]]
        else
            return nil
        end
    end
    return current
end

function Highlight:FindWarModeButton()
    -- Search for the War Mode button in the talents frame
    local searchParents = {
        PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame,
        ClassTalentFrame and ClassTalentFrame.TalentsTab,
        ClassTalentFrame,
        PlayerSpellsFrame,
    }
    
    for _, parent in ipairs(searchParents) do
        if parent then
            local btn = self:FindChildByTexture(parent, "Interface\\PVPFrame\\PVP%-Banner%-Emblem%-")
            if btn then return btn end
            
            -- Also try finding by checking for WarMode in scripts or by being a toggle button
            btn = self:FindChildByName(parent, "WarMode")
            if btn then return btn end
        end
    end
    
    -- Try looking for PvPTalentSlotTray and then find war mode near it
    local tray = self:FindPvPTalentsTray()
    if tray then
        local parent = tray:GetParent()
        if parent then
            for i = 1, select("#", parent:GetChildren()) do
                local child = select(i, parent:GetChildren())
                if child and child ~= tray and child:IsShown() then
                    -- War mode button is typically a circular button near the PvP talents
                    local w, h = child:GetSize()
                    if w and h and math.abs(w - h) < 5 and w > 30 and w < 80 then
                        return child
                    end
                end
            end
        end
    end
    
    return nil
end

function Highlight:FindPvPTalentsTray()
    local paths = {
        "PlayerSpellsFrame.TalentsFrame.PvPTalentSlotTray",
        "ClassTalentFrame.TalentsTab.PvPTalentSlotTray",
        "ClassTalentFrame.PvPTalentSlotTray",
    }
    
    for _, path in ipairs(paths) do
        local frame = self:GetFrameByPathDirect(path)
        if frame and frame:IsShown() then
            return frame
        end
    end
    
    return nil
end

function Highlight:GetFrameByPathDirect(path)
    if not path then return nil end
    local parts = {strsplit(".", path)}
    local current = _G[parts[1]]
    for i = 2, #parts do
        if current then
            current = current[parts[i]]
        else
            return nil
        end
    end
    return current
end

function Highlight:FindChildByTexture(parent, texturePattern)
    if not parent then return nil end
    for i = 1, select("#", parent:GetChildren()) do
        local child = select(i, parent:GetChildren())
        if child and child:IsShown() then
            -- Check textures on this frame
            local regions = {child:GetRegions()}
            for _, region in ipairs(regions) do
                if region.GetTexture then
                    local tex = region:GetTexture()
                    if tex and string.find(tex, texturePattern) then
                        return child
                    end
                end
            end
            -- Recurse
            local found = self:FindChildByTexture(child, texturePattern)
            if found then return found end
        end
    end
    return nil
end

function Highlight:FindChildByName(parent, namePattern)
    if not parent then return nil end
    for i = 1, select("#", parent:GetChildren()) do
        local child = select(i, parent:GetChildren())
        if child then
            local name = child:GetName()
            if name and string.find(name, namePattern) then
                return child
            end
            -- Recurse
            local found = self:FindChildByName(child, namePattern)
            if found then return found end
        end
    end
    return nil
end

function Highlight:IsTabSelected(frameName, tabIndex)
    -- PlayerSpellsFrame (Talents & Spellbook)
    if frameName == "PlayerSpellsFrame" then
        local frame = PlayerSpellsFrame
        if frame then
            -- Try multiple methods to detect current tab
            if frame.GetTab then
                local currentTab = frame:GetTab()
                return currentTab == tabIndex
            end
            -- Check which tab content is visible
            -- Tab 1 = Specialization, Tab 2 = Talents, Tab 3 = Spellbook
            if tabIndex == 1 and frame.SpecFrame and frame.SpecFrame:IsShown() then
                return true
            elseif tabIndex == 2 and frame.TalentsFrame and frame.TalentsFrame:IsShown() then
                return true
            elseif tabIndex == 2 and ClassTalentFrame and ClassTalentFrame:IsShown() then
                return true
            elseif tabIndex == 3 and frame.SpellBookFrame and frame.SpellBookFrame:IsShown() then
                return true
            end
        end
        return false
    end
    
    -- CollectionsJournal
    if frameName == "CollectionsJournal" then
        local frame = CollectionsJournal
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end
    
    -- CharacterFrame (Character Info tabs: Character, Reputation, Currency)
    if frameName == "CharacterFrame" then
        local frame = CharacterFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        -- Fallback: check by content visibility
        if tabIndex == 1 then
            -- Character tab (paperdoll)
            if PaperDollFrame and PaperDollFrame:IsShown() then return true end
            if CharacterStatsPane and CharacterStatsPane:IsShown() then return true end
        elseif tabIndex == 2 then
            -- Reputation tab
            if ReputationFrame and ReputationFrame:IsShown() then return true end
        elseif tabIndex == 3 then
            -- Currency tab  
            if TokenFrame and TokenFrame:IsShown() then return true end
            if CurrencyFrame and CurrencyFrame:IsShown() then return true end
        end
        return false
    end
    
    -- PVEFrame (Group Finder tabs at bottom)
    if frameName == "PVEFrame" then
        local frame = PVEFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end
    
    -- AchievementFrame
    if frameName == "AchievementFrame" then
        local frame = AchievementFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end
    
    -- EncounterJournal (Adventure Guide)
    if frameName == "EncounterJournal" then
        local frame = EncounterJournal
        if frame then
            -- Modern Adventure Guide tabs (7 total in modern WoW):
            -- Tab 1 = Journeys, Tab 2 = Traveler's Log, Tab 3 = Suggested Content
            -- Tab 4 = Dungeons, Tab 5 = Raids, Tab 6 = Item Sets (Loot), Tab 7 = Tutorials
            
            -- Check by specific frame visibility
            local tabContentChecks = {
                -- Tab 1: Journeys
                function() 
                    if frame.JourneysFrame and frame.JourneysFrame:IsShown() then return true end
                    return false
                end,
                -- Tab 2: Traveler's Log
                function()
                    if frame.TravelersLogFrame and frame.TravelersLogFrame:IsShown() then return true end
                    return false
                end,
                -- Tab 3: Suggested Content
                function()
                    if frame.suggestFrame and frame.suggestFrame:IsShown() then return true end
                    if frame.SuggestFrame and frame.SuggestFrame:IsShown() then return true end
                    return false
                end,
                -- Tab 4: Dungeons
                function()
                    if frame.instanceSelect and frame.instanceSelect:IsShown() then
                        -- Check if we're filtering to dungeons
                        if frame.instanceSelect.tabsEnabled then
                            return frame.instanceSelect.tabsEnabled[1] == true
                        end
                    end
                    return false
                end,
                -- Tab 5: Raids  
                function()
                    if frame.instanceSelect and frame.instanceSelect:IsShown() then
                        -- Check if we're filtering to raids
                        if frame.instanceSelect.tabsEnabled then
                            return frame.instanceSelect.tabsEnabled[2] == true
                        end
                    end
                    return false
                end,
                -- Tab 6: Item Sets / Loot
                function()
                    if frame.LootJournal and frame.LootJournal:IsShown() then return true end
                    if frame.LootJournalFrame and frame.LootJournalFrame:IsShown() then return true end
                    return false
                end,
                -- Tab 7: Tutorials
                function()
                    if frame.TutorialFrame and frame.TutorialFrame:IsShown() then return true end
                    return false
                end,
            }
            
            local checkFn = tabContentChecks[tabIndex]
            if checkFn and checkFn() then
                return true
            end
            
            -- Try PanelTemplates as fallback
            if PanelTemplates_GetSelectedTab then
                local selectedTab = PanelTemplates_GetSelectedTab(frame)
                if selectedTab == tabIndex then return true end
            end
        end
        return false
    end
    
    return false
end

function Highlight:IsSideTabSelected(frameName, sideTabIndex)
    -- PVEFrame side buttons (Dungeon Finder, Raid Finder, Premade Groups)
    if frameName == "PVEFrame" then
        local sideFrames = {
            LFDParentFrame,  -- Tab 1: Dungeon Finder
            RaidFinderFrame, -- Tab 2: Raid Finder
            LFGListPVEStub,  -- Tab 3: Premade Groups
        }
        local targetFrame = sideFrames[sideTabIndex]
        if targetFrame and targetFrame:IsShown() then
            return true
        end
        return false
    end
    
    return false
end

function Highlight:IsPvPSideTabSelected(frameName, sideTabIndex)
    -- PVEFrame PvP side buttons (Quick Match, Rated, Premade Groups, Training Grounds)
    if frameName == "PVEFrame" then
        -- These are the frames shown when each PvP side tab is selected
        local pvpSideFrames = {
            HonorFrame,          -- Tab 1: Quick Match (Random BG, Arena Skirmish)
            ConquestFrame,       -- Tab 2: Rated (Solo Shuffle, 2v2, 3v3, RBG)
            LFGListPVPStub,      -- Tab 3: Premade Groups (PvP)
            PVPQueueFrame and PVPQueueFrame.NewPlayerBrawlFrame, -- Tab 4: Training Grounds (Brawl frame)
        }
        local targetFrame = pvpSideFrames[sideTabIndex]
        if targetFrame and targetFrame:IsShown() then
            return true
        end
        
        -- Fallback check for PvP UI buttons selected state
        local pvpButtons = self:GetPvPSideTabButtons()
        if pvpButtons and pvpButtons[sideTabIndex] then
            local btn = pvpButtons[sideTabIndex]
            -- Check multiple selection indicators
            if btn.GetSelectedState and btn:GetSelectedState() then
                return true
            end
            if btn.IsSelected and btn:IsSelected() then
                return true
            end
            if btn.selectedTex and btn.selectedTex:IsShown() then
                return true
            end
            if btn.selectedTexture and btn.selectedTexture:IsShown() then
                return true
            end
            -- Check for modern selected state visual
            if btn.Selected and btn.Selected:IsShown() then
                return true
            end
            -- Check if button is highlighted/active via texture atlas
            if btn.isSelected then
                return true
            end
        end
        
        return false
    end
    
    return false
end

function Highlight:GetPvPSideTabButtons()
    -- Find the PvP side tab buttons
    local buttons = {}
    
    -- Modern PvP UI
    if PVPQueueFrame then
        local buttonNames = {
            "HonorButton",           -- Quick Match
            "ConquestButton",        -- Rated
            "LFGListButton",         -- Premade Groups  
            "NewPlayerBrawlButton",  -- Training Grounds (modern name)
        }
        for i, name in ipairs(buttonNames) do
            if PVPQueueFrame[name] then
                buttons[i] = PVPQueueFrame[name]
            end
        end
        
        -- Fallback: try alternate names
        if not buttons[4] then
            local trainingNames = {"TrainingButton", "BrawlButton", "TrainingGroundsButton"}
            for _, name in ipairs(trainingNames) do
                if PVPQueueFrame[name] then
                    buttons[4] = PVPQueueFrame[name]
                    break
                end
            end
        end
        
        -- Fallback: iterate children
        if #buttons == 0 and PVPQueueFrame.CategoryButton1 then
            for i = 1, 4 do
                local btn = PVPQueueFrame["CategoryButton" .. i]
                if btn then
                    buttons[i] = btn
                end
            end
        end
    end
    
    return buttons
end

function Highlight:GetPvPSideTabButton(frameName, sideTabIndex)
    if frameName == "PVEFrame" then
        local buttons = self:GetPvPSideTabButtons()
        local btn = buttons[sideTabIndex]
        if btn and btn:IsShown() then
            return btn
        end
        
        -- Fallback: Try to find generic category buttons
        local fallbackNames = {
            "PVPQueueFrameCategoryButton1",
            "PVPQueueFrameCategoryButton2",
            "PVPQueueFrameCategoryButton3",
            "PVPQueueFrameCategoryButton4",
        }
        return _G[fallbackNames[sideTabIndex]]
    end
    
    return nil
end

-- Statistics category navigation helpers
function Highlight:IsStatisticsCategorySelected(categoryName)
    -- Check if the specified statistics category is currently selected/expanded
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    
    -- Check if we're on the Statistics tab first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return false
    end
    
    local categoryNameLower = categoryName:lower()
    
    -- Helper to get text from a button
    local function getButtonText(btn)
        if not btn then return nil end
        if btn.label and btn.label.GetText then return btn.label:GetText() end
        if btn.Label and btn.Label.GetText then return btn.Label:GetText() end
        if btn.text and btn.text.GetText then return btn.text:GetText() end
        if btn.Text and btn.Text.GetText then return btn.Text:GetText() end
        if btn.Name and btn.Name.GetText then return btn.Name:GetText() end
        if btn.name and btn.name.GetText then return btn.name:GetText() end
        if btn.GetText then return btn:GetText() end
        local regions = {btn:GetRegions()}
        for _, region in ipairs(regions) do
            if region:GetObjectType() == "FontString" and region:GetText() then
                return region:GetText()
            end
        end
        return nil
    end
    
    -- Helper to check if a button appears selected
    local function isButtonSelected(btn)
        if not btn then return false end
        -- Check explicit selection properties
        if btn.isSelected then return true end
        if btn.selected then return true end
        -- Check expanded state (for tree categories)
        if btn.collapsed == false then return true end
        if btn.isExpanded then return true end
        if btn.expanded then return true end
        -- Check for highlight/selection texture being shown
        if btn.highlight and btn.highlight:IsShown() then return true end
        if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
        if btn.SelectedTexture and btn.SelectedTexture:IsShown() then return true end
        -- Check background/selection highlight
        if btn.Selection and btn.Selection:IsShown() then return true end
        if btn.selection and btn.selection:IsShown() then return true end
        return false
    end
    
    -- Method 1: Try AchievementFrameCategories with ScrollBox (modern 10.x+ UI)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        for _, btn in scrollBox:EnumerateFrames() do
            if btn and btn:IsShown() then
                local btnText = getButtonText(btn)
                if btnText and btnText:lower() == categoryNameLower then
                    if isButtonSelected(btn) then
                        return true
                    end
                end
            end
        end
    end
    
    -- Method 2: Check AchievementFrameAchievements.selectedCategory or similar
    local statsFrame = AchievementFrameAchievements
    if statsFrame then
        -- Some versions store the selected category
        if statsFrame.selectedCategory then
            local selName = statsFrame.selectedCategory
            if type(selName) == "string" and selName:lower() == categoryNameLower then
                return true
            end
        end
        
        -- Check categories array
        if statsFrame.categories then
            for _, btn in ipairs(statsFrame.categories) do
                if btn and btn:IsShown() then
                    local btnText = getButtonText(btn)
                    if btnText and btnText:lower() == categoryNameLower then
                        if isButtonSelected(btn) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- Method 3: Look for numbered buttons
    for i = 1, 40 do
        local btn = _G["AchievementFrameCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoryButton" .. i] or
                    _G["AchievementFrameCategoryButton" .. i]
        
        if btn and btn:IsShown() then
            local btnText = getButtonText(btn)
            if btnText and btnText:lower() == categoryNameLower then
                if isButtonSelected(btn) then
                    return true
                end
            end
        end
    end
    
    -- Method 4: Check the stats list header
    local statsHeader = _G["AchievementFrameStatsHeader"]
    if statsHeader and statsHeader.GetText then
        local headerText = statsHeader:GetText()
        if headerText and headerText:lower():find(categoryNameLower) then
            return true
        end
    end
    
    -- Method 5: For parent categories, check if category is "open" by seeing if child categories are now visible
    -- This handles the case where clicking "Player vs. Player" expands to show "World" but doesn't set selected flags
    -- We consider a category "selected" if we're on the Statistics tab and we can see content related to it
    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.statisticsCategory then
            -- Check if the NEXT category we're looking for is now visible
            -- If it is, then THIS category must be selected/expanded
            local nextBtn = self:GetStatisticsCategoryButton(nextStep.statisticsCategory)
            if nextBtn and nextBtn:IsShown() then
                return true
            end
        end
    end
    
    return false
end

function Highlight:GetStatisticsCategoryButton(categoryName)
    -- Find the button for a statistics category by name
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end
    
    -- CRITICAL: Only search for categories if we're on the Statistics tab (tab 3)
    -- This prevents highlighting wrong categories in Achievements/Guild tabs
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return nil
    end
    
    local categoryNameLower = categoryName:lower()
    
    -- Helper to get text from a button - comprehensive search
    local function getButtonText(btn)
        if not btn then return nil end
        if btn.label and btn.label.GetText then return btn.label:GetText() end
        if btn.Label and btn.Label.GetText then return btn.Label:GetText() end
        if btn.text and btn.text.GetText then return btn.text:GetText() end
        if btn.Text and btn.Text.GetText then return btn.Text:GetText() end
        if btn.Name and btn.Name.GetText then return btn.Name:GetText() end
        if btn.name and btn.name.GetText then return btn.name:GetText() end
        if btn.GetText then return btn:GetText() end
        -- Check fontstrings in regions
        local regions = {btn:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText and region:GetText() then
                return region:GetText()
            end
        end
        return nil
    end
    
    -- Helper to recursively search a frame and its children for buttons
    local function searchFrameTree(frame, depth)
        if not frame or depth > 6 then return nil end
        
        -- Check this frame itself
        if frame:IsShown() then
            local text = getButtonText(frame)
            if text and text:lower() == categoryNameLower then
                -- Found exact matching text - check if it's clickable
                if frame.Click or (frame.IsMouseEnabled and frame:IsMouseEnabled()) then
                    return frame
                end
            end
        end
        
        -- Search children recursively
        local children = {frame:GetChildren()}
        for _, child in ipairs(children) do
            local result = searchFrameTree(child, depth + 1)
            if result then return result end
        end
        
        return nil
    end
    
    -- Method 1: Search the main AchievementFrame and all its descendants
    if AchievementFrame then
        local result = searchFrameTree(AchievementFrame, 0)
        if result then return result end
    end
    
    -- Method 2: Try AchievementFrameCategories with ScrollBox (modern 10.x+ UI)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame then
        if categoriesFrame.ScrollBox then
            local scrollBox = categoriesFrame.ScrollBox
            -- Try EnumerateFrames if available
            if scrollBox.EnumerateFrames then
                for _, btn in scrollBox:EnumerateFrames() do
                    if btn and btn:IsShown() then
                        local btnText = getButtonText(btn)
                        if btnText and btnText:lower() == categoryNameLower then
                            return btn
                        end
                    end
                end
            end
        end
        
        -- Search the categories frame tree
        local result = searchFrameTree(categoriesFrame, 0)
        if result then return result end
    end
    
    -- Method 3: Try AchievementFrameAchievements categories (used in Statistics view)
    local statsFrame = AchievementFrameAchievements
    if statsFrame then
        if statsFrame.categories then
            for _, btn in ipairs(statsFrame.categories) do
                if btn and btn:IsShown() then
                    local btnText = getButtonText(btn)
                    if btnText and btnText:lower() == categoryNameLower then
                        return btn
                    end
                end
            end
        end
        
        -- Search this frame's tree
        local result = searchFrameTree(statsFrame, 0)
        if result then return result end
    end
    
    -- Method 4: Look through numbered buttons (legacy and some modern patterns)
    for i = 1, 50 do
        local btn = _G["AchievementFrameCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoryButton" .. i] or
                    _G["AchievementFrameCategoryButton" .. i]
        
        if btn and btn:IsShown() then
            local btnText = getButtonText(btn)
            if btnText and btnText:lower() == categoryNameLower then
                return btn
            end
        end
    end
    
    return nil
end

function Highlight:FindRatedPvPButton(buttonText)
    -- Search the PVEFrame for a button with matching text (for Solo Shuffle, 2v2, 3v3, etc.)
    if not PVEFrame or not PVEFrame:IsShown() then
        return nil
    end
    
    local searchText = buttonText:lower()
    
    -- Helper to get text from a frame
    local function getFrameText(frame)
        if not frame then return nil end
        if frame.Label and frame.Label.GetText then return frame.Label:GetText() end
        if frame.label and frame.label.GetText then return frame.label:GetText() end
        if frame.Text and frame.Text.GetText then return frame.Text:GetText() end
        if frame.text and frame.text.GetText then return frame.text:GetText() end
        if frame.Name and frame.Name.GetText then return frame.Name:GetText() end
        if frame.GetText then return frame:GetText() end
        
        -- Check all fontstring regions
        local regions = {frame:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                if region.GetText then
                    local text = region:GetText()
                    if text then return text end
                end
            end
        end
        return nil
    end
    
    -- Recursively search a frame tree
    local function searchTree(frame, depth)
        if not frame or depth > 6 then return nil end
        
        -- Check if this frame is a clickable button-like frame with matching text
        if frame:IsShown() then
            local text = getFrameText(frame)
            if text and text:lower():find(searchText) then
                -- Check if it's interactable
                if frame.Click or (frame.IsMouseEnabled and frame:IsMouseEnabled()) then
                    return frame
                end
            end
        end
        
        -- Search children
        local children = {frame:GetChildren()}
        for _, child in ipairs(children) do
            local result = searchTree(child, depth + 1)
            if result then return result end
        end
        
        return nil
    end
    
    -- Start search from PVEFrame
    return searchTree(PVEFrame, 0)
end

function Highlight:GetTabButton(frameName, tabIndex)
    -- PlayerSpellsFrame tabs
    if frameName == "PlayerSpellsFrame" then
        local frame = PlayerSpellsFrame
        if frame and frame.TabSystem and frame.TabSystem.tabs then
            return frame.TabSystem.tabs[tabIndex]
        end
        -- Fallback to global tab buttons
        local tabBtn = _G["PlayerSpellsFrameTab" .. tabIndex]
        if tabBtn then return tabBtn end
        
        -- Try the tab system directly
        if frame then
            -- Modern tab system might use TabSystem
            if frame.TabSystem then
                local tabs = frame.TabSystem:GetChildren()
                local count = 0
                for _, child in ipairs({frame.TabSystem:GetChildren()}) do
                    count = count + 1
                    if count == tabIndex then
                        return child
                    end
                end
            end
        end
    end
    
    -- CollectionsJournal tabs
    if frameName == "CollectionsJournal" then
        return _G["CollectionsJournalTab" .. tabIndex]
    end
    
    -- CharacterFrame tabs (Character, Reputation, Currency)
    if frameName == "CharacterFrame" then
        return _G["CharacterFrameTab" .. tabIndex]
    end
    
    -- PVEFrame tabs (at bottom: Dungeons & Raids, Player vs. Player, Mythic+)
    if frameName == "PVEFrame" then
        return _G["PVEFrameTab" .. tabIndex]
    end
    
    -- AchievementFrame tabs (Achievements, Guild, Statistics)
    if frameName == "AchievementFrame" then
        return _G["AchievementFrameTab" .. tabIndex]
    end
    
    -- EncounterJournal tabs (Adventure Guide)
    if frameName == "EncounterJournal" then
        local frame = EncounterJournal
        if frame then
            -- Modern Adventure Guide tabs (7 total in modern WoW):
            -- Tab 1 = Journeys, Tab 2 = Traveler's Log, Tab 3 = Suggested Content
            -- Tab 4 = Dungeons, Tab 5 = Raids, Tab 6 = Item Sets (Loot), Tab 7 = Tutorials
            
            -- Tab keywords to search for in button names
            local tabKeywords = {
                {"Journey", "Journeys"},                    -- Tab 1
                {"Traveler", "Travel", "Log"},              -- Tab 2
                {"Suggest"},                                -- Tab 3
                {"Dungeon"},                                -- Tab 4
                {"Raid"},                                   -- Tab 5
                {"Loot", "ItemSet", "Set"},                 -- Tab 6
                {"Tutorial", "HelpFrame"},                  -- Tab 7
            }
            
            -- Helper function to search a container for tab buttons
            local function findTabInContainer(container, keywords)
                if not container then return nil end
                for _, child in ipairs({container:GetChildren()}) do
                    local name = child:GetName() or ""
                    for _, keyword in ipairs(keywords) do
                        if name:find(keyword) then
                            return child
                        end
                    end
                    -- Also check child text if it's a button
                    if child.GetText then
                        local text = child:GetText() or ""
                        for _, keyword in ipairs(keywords) do
                            if text:find(keyword) then
                                return child
                            end
                        end
                    end
                end
                return nil
            end
            
            local keywords = tabKeywords[tabIndex]
            if keywords then
                -- Try direct frame properties first
                local directNames = {
                    {"journeysTab", "JourneysTab"},
                    {"travelersLogTab", "TravelersLogTab"},
                    {"suggestTab", "SuggestTab"},
                    {"dungeonsTab", "DungeonsTab"},
                    {"raidsTab", "RaidsTab"},
                    {"lootJournalTab", "LootJournalTab", "LootTab"},
                    {"tutorialTab", "TutorialTab", "HelpTab"},
                }
                for _, btnName in ipairs(directNames[tabIndex] or {}) do
                    local btn = frame[btnName]
                    if btn then return btn end
                end
                
                -- Search in TopNavBar (where modern tabs often live)
                local btn = findTabInContainer(frame.TopNavBar, keywords)
                if btn then return btn end
                
                -- Search in TabBar
                btn = findTabInContainer(frame.TabBar, keywords)
                if btn then return btn end
                
                -- Search in TabSystem
                btn = findTabInContainer(frame.TabSystem, keywords)
                if btn then return btn end
                
                -- Search frame's direct children
                btn = findTabInContainer(frame, keywords)
                if btn then return btn end
            end
            
            -- Try TabSystem.tabs array by index
            if frame.TabSystem and frame.TabSystem.tabs then
                return frame.TabSystem.tabs[tabIndex]
            end
            
            -- Try iterating children of various containers by index
            local containers = {frame.TopNavBar, frame.TabBar, frame.TabSystem, frame}
            for _, container in ipairs(containers) do
                if container then
                    local count = 0
                    for _, child in ipairs({container:GetChildren()}) do
                        -- Only count button-like children
                        if child.GetText or child.Click then
                            count = count + 1
                            if count == tabIndex then
                                return child
                            end
                        end
                    end
                end
            end
            
            -- Last resort: try global names
            local tab = _G["EncounterJournalTab" .. tabIndex]
            if tab then return tab end
            
            local bottomTab = _G["EncounterJournalBottomTab" .. tabIndex]
            if bottomTab then return bottomTab end
        end
    end
    
    return nil
end

function Highlight:GetSideTabButton(frameName, sideTabIndex)
    -- PVEFrame side buttons (Dungeon Finder, Raid Finder, Premade Groups)
    if frameName == "PVEFrame" then
        local sideButtons = {
            GroupFinderFrame and GroupFinderFrame.DungeonFinderButton,  -- 1
            GroupFinderFrame and GroupFinderFrame.RaidFinderButton,     -- 2
            GroupFinderFrame and GroupFinderFrame.LFGListButton,        -- 3
        }
        local btn = sideButtons[sideTabIndex]
        if btn and btn:IsShown() then
            return btn
        end
        
        -- Fallback: look for buttons by name
        local buttonNames = {
            "GroupFinderFrameGroupButton1",
            "GroupFinderFrameGroupButton2", 
            "GroupFinderFrameGroupButton3",
        }
        return _G[buttonNames[sideTabIndex]]
    end
    
    return nil
end

function Highlight:HighlightFrame(frame, instructionText)
    if not frame or not frame:IsShown() then
        self:HideHighlight()
        return
    end
    
    local bs = highlightFrame.borderSize
    local pad = 4
    
    highlightFrame:ClearAllPoints()
    highlightFrame:SetAllPoints(frame)
    
    highlightFrame.top:ClearAllPoints()
    highlightFrame.top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -pad, 0)
    highlightFrame.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", pad, 0)
    highlightFrame.top:SetHeight(bs)
    
    highlightFrame.bottom:ClearAllPoints()
    highlightFrame.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -pad, 0)
    highlightFrame.bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", pad, 0)
    highlightFrame.bottom:SetHeight(bs)
    
    highlightFrame.left:ClearAllPoints()
    highlightFrame.left:SetPoint("TOPRIGHT", frame, "TOPLEFT", 0, pad)
    highlightFrame.left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 0, -pad)
    highlightFrame.left:SetWidth(bs)
    
    highlightFrame.right:ClearAllPoints()
    highlightFrame.right:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, pad)
    highlightFrame.right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 0, -pad)
    highlightFrame.right:SetWidth(bs)
    
    highlightFrame:Show()
    if highlightFrame.animGroup and not highlightFrame.animGroup:IsPlaying() then
        highlightFrame.animGroup:Play()
    end
    
    arrowFrame:ClearAllPoints()
    arrowFrame:SetPoint("BOTTOM", frame, "TOP", 0, 10)
    arrowFrame:Show()
    if arrowFrame.animGroup and not arrowFrame.animGroup:IsPlaying() then
        arrowFrame.animGroup:Play()
    end
    
    if instructionText then
        self:ShowInstruction(instructionText)
    end
end

function Highlight:ShowInstruction(text)
    instructionFrame.text:SetText(text)
    
    -- Calculate proper width and height with word wrap
    local maxWidth = 450
    instructionFrame:SetWidth(maxWidth)
    
    -- Get actual text height after word wrap
    local textHeight = instructionFrame.text:GetStringHeight()
    local frameHeight = math.max(90, textHeight + 60)  -- 60px for padding and button
    instructionFrame:SetHeight(frameHeight)
    
    instructionFrame:ClearAllPoints()
    instructionFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    instructionFrame:Show()
end

function Highlight:HideHighlight()
    if highlightFrame then
        highlightFrame:Hide()
        if highlightFrame.animGroup then highlightFrame.animGroup:Stop() end
    end
    if arrowFrame then
        arrowFrame:Hide()
        if arrowFrame.animGroup then arrowFrame.animGroup:Stop() end
    end
    if instructionFrame then
        instructionFrame:Hide()
    end
end

function Highlight:Cancel()
    self:HideHighlight()
    
    if stepTicker then
        stepTicker:Cancel()
        stepTicker = nil
    end
    
    currentGuide = nil
    currentStepIndex = nil
end
