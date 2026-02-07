local ADDON_NAME, ns = ...

local Highlight = {}
ns.Highlight = Highlight

local highlightFrame
local arrowFrame
local instructionFrame
local contextTooltip
local currentGuide
local currentStepIndex
local stepTicker

function Highlight:Initialize()
    if highlightFrame then return end
    self:CreateHighlightFrame()
    self:CreateArrowFrame()
    self:CreateInstructionFrame()
    self:CreateContextTooltip()
end

function Highlight:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "EasyFindHighlightFrame", UIParent)
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
    arrowFrame = CreateFrame("Frame", "EasyFindArrowFrame", UIParent)
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
    instructionFrame = CreateFrame("Frame", "EasyFindInstructionFrame", UIParent, "BackdropTemplate")
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

function Highlight:CreateContextTooltip()
    contextTooltip = CreateFrame("Frame", "EasyFindContextTooltip", UIParent, "BackdropTemplate")
    contextTooltip:SetFrameStrata("TOOLTIP")
    contextTooltip:SetFrameLevel(503)
    contextTooltip:Hide()
    
    contextTooltip:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    contextTooltip:SetBackdropColor(0, 0, 0, 0.9)
    contextTooltip:SetBackdropBorderColor(1, 0.82, 0, 1)
    
    local text = contextTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, 0)
    text:SetTextColor(1, 1, 0)
    text:SetJustifyH("CENTER")
    contextTooltip.text = text
end

function Highlight:ShowContextTooltip(anchorFrame, msg, anchorPoint, relPoint, xOff, yOff)
    if not contextTooltip or not anchorFrame then return end
    contextTooltip.text:SetText(msg)
    local textWidth = contextTooltip.text:GetStringWidth()
    local textHeight = contextTooltip.text:GetStringHeight()
    contextTooltip:SetSize(textWidth + 20, textHeight + 14)
    contextTooltip:ClearAllPoints()
    contextTooltip:SetPoint(
        anchorPoint or "TOP",
        anchorFrame,
        relPoint or "BOTTOM",
        xOff or 0,
        yOff or -5
    )
    contextTooltip:Show()
end

function Highlight:HideContextTooltip()
    if contextTooltip then
        contextTooltip:Hide()
    end
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
    
    -- Portrait menu step 1: highlight player portrait and tell user to right-click
    if step.portraitMenu then
        -- Check if the portrait menu is already open
        if self:IsPortraitMenuOpen() then
            -- Menu is open, advance to next step
            self:HideContextTooltip()
            self:AdvanceStep()
            return
        end
        
        -- Highlight the player frame portrait and show contextual tooltip
        local portrait = PlayerFrame
        if portrait and portrait:IsShown() then
            self:HighlightFrame(portrait)
            self:ShowContextTooltip(portrait, "Right-click", "LEFT", "RIGHT", 10, 0)
        end
        return
    end
    
    -- Portrait menu step 2: find and highlight the correct menu option
    if step.portraitMenuOption then
        -- Check if portrait menu is still open
        if not self:IsPortraitMenuOpen() then
            -- Menu was closed, go back to portrait step
            self:HideContextTooltip()
            currentStepIndex = currentStepIndex - 1
            self:HideHighlight()
            return
        end
        
        -- Find the menu option button and highlight it
        local optionBtn = self:FindPortraitMenuOption(step.portraitMenuOption)
        if optionBtn then
            self:HighlightFrame(optionBtn)
            -- Check for hover/click to dismiss
            if optionBtn:IsMouseOver() then
                self:Cancel()
                return
            end
        else
            -- Option not found in the open menu - it's not available in this context
            self:HideHighlight()
            self:ShowInstruction("'" .. step.portraitMenuOption .. "' is not available here")
            C_Timer.After(2.5, function() self:Cancel() end)
            return
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
            -- First check: are we still on the correct main tab?
            -- Look back through previous steps to find the required tabIndex
            local requiredTabIndex = nil
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.tabIndex then
                    requiredTabIndex = prevStep.tabIndex
                    break
                end
            end
            
            if requiredTabIndex then
                local currentTab = self:GetCurrentTabIndex(step.waitForFrame)
                if currentTab and currentTab ~= requiredTabIndex then
                    -- User navigated to wrong tab - go back to the tab selection step
                    for i = currentStepIndex - 1, 1, -1 do
                        local prevStep = currentGuide.steps[i]
                        if prevStep and prevStep.tabIndex == requiredTabIndex then
                            currentStepIndex = i
                            self:HideHighlight()
                            return
                        end
                    end
                end
            end
            
            -- Check if already on correct side tab
            if self:IsSideTabSelected(step.waitForFrame, step.sideTabIndex) then
                -- Correct tab, advance to next step
                self:AdvanceStep()
                return
            end
            
            -- Need to click side tab
            local sideBtn = self:GetSideTabButton(step.waitForFrame, step.sideTabIndex)
            if sideBtn and sideBtn:IsShown() then
                -- Highlight side tab, no text
                self:HighlightFrame(sideBtn)
            elseif isLastStep then
                -- Can't find side button on last step, show instruction
                self:ShowInstruction(step.text or "Click the correct option on the left")
            else
                -- Button not found/visible - might be on wrong tab, go back
                if currentStepIndex > 1 then
                    currentStepIndex = currentStepIndex - 1
                    self:HideHighlight()
                end
            end
            return
        end
        
        -- PVP Side tab (Quick Match / Rated / Premade Groups / Training Grounds in PvP tab)
        if step.pvpSideTabIndex then
            -- First check: are we still on the correct main tab (PvP tab = tab 2)?
            -- Look back through previous steps to find the required tabIndex
            local requiredTabIndex = nil
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.tabIndex then
                    requiredTabIndex = prevStep.tabIndex
                    break
                end
            end
            
            if requiredTabIndex then
                local currentTab = self:GetCurrentTabIndex(step.waitForFrame)
                if currentTab and currentTab ~= requiredTabIndex then
                    -- User navigated to wrong tab (e.g., clicked Dungeons & Raids instead of staying on PvP)
                    -- Go back to the tab selection step
                    for i = currentStepIndex - 1, 1, -1 do
                        local prevStep = currentGuide.steps[i]
                        if prevStep and prevStep.tabIndex == requiredTabIndex then
                            currentStepIndex = i
                            self:HideHighlight()
                            return
                        end
                    end
                end
            end
            
            -- Check if already on correct PvP side tab
            if self:IsPvPSideTabSelected(step.waitForFrame, step.pvpSideTabIndex) then
                -- Correct tab, advance to next step
                self:AdvanceStep()
                return
            end
            
            -- Need to click PvP side tab
            local pvpBtn = self:GetPvPSideTabButton(step.waitForFrame, step.pvpSideTabIndex)
            if pvpBtn and pvpBtn:IsShown() then
                -- Highlight PvP side tab, no text
                self:HighlightFrame(pvpBtn)
            elseif isLastStep then
                -- Can't find side button on last step, show instruction
                self:ShowInstruction(step.text or "Click the correct option on the left")
            else
                -- Button not found/visible - might be on wrong tab, go back
                if currentStepIndex > 1 then
                    currentStepIndex = currentStepIndex - 1
                    self:HideHighlight()
                end
            end
            return
        end
        
        -- Statistics category navigation (tree-based category selection)
        if step.statisticsCategory then
            -- First check: are we still on the Statistics tab?
            local currentTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame)
            if currentTab ~= 3 then
                -- User clicked away to Achievements or Guild tab - go back to step 2 (the tab selection step)
                -- Find the step that has tabIndex = 3
                for i, s in ipairs(currentGuide.steps) do
                    if s.tabIndex == 3 then
                        currentStepIndex = i
                        break
                    end
                end
                self:HideHighlight()
                return
            end
            
            -- Check if already on correct statistics category
            local isSelected = self:IsStatisticsCategorySelected(step.statisticsCategory)
            
            -- Also check if the user has clicked our highlighted button
            -- by seeing if the button we were highlighting is now being moused over or was just clicked
            if lastHighlightedCategoryButton and lastHighlightedCategoryName and 
               lastHighlightedCategoryName:lower() == step.statisticsCategory:lower() then
                -- Check if user's mouse is on the button (indicates they clicked it)
                if lastHighlightedCategoryButton:IsMouseOver() then
                    -- User is hovering/clicking the correct button - consider it selected after a brief moment
                    isSelected = true
                end
            end
            
            if isSelected then
                -- Correct category selected
                if isLastStep then
                    -- Final step and we're there - dismiss the guide
                    lastHighlightedCategoryButton = nil
                    lastHighlightedCategoryName = nil
                    self:Cancel()
                else
                    -- Advance to next step
                    lastHighlightedCategoryButton = nil
                    lastHighlightedCategoryName = nil
                    self:AdvanceStep()
                end
                return
            end
            
            -- Need to click category in tree - find and highlight the button
            local categoryBtn = self:GetStatisticsCategoryButton(step.statisticsCategory)
            if categoryBtn then
                -- Track what we're highlighting for better click detection
                lastHighlightedCategoryButton = categoryBtn
                lastHighlightedCategoryName = step.statisticsCategory
                self:HighlightFrame(categoryBtn)
            elseif isLastStep then
                -- Can't find button on last step
                -- Check if the category is visible anywhere - if not, we might need to expand parent
                local prevStepIndex = currentStepIndex - 1
                if prevStepIndex >= 1 then
                    local prevStep = currentGuide.steps[prevStepIndex]
                    if prevStep and prevStep.statisticsCategory then
                        -- Check if parent category is expanded
                        local parentBtn = self:GetStatisticsCategoryButton(prevStep.statisticsCategory)
                        if parentBtn then
                            -- Parent exists, highlight it to expand
                            lastHighlightedCategoryButton = parentBtn
                            lastHighlightedCategoryName = prevStep.statisticsCategory
                            self:HighlightFrame(parentBtn)
                            return
                        end
                    end
                end
                
                -- Last resort - show text instruction
                self:ShowInstruction(step.text or "Click '" .. step.statisticsCategory .. "' in the category list")
            end
            return
        end
        
        -- Achievement category navigation (tree-based category selection in Achievements/Guild tabs)
        if step.achievementCategory then
            -- First check: are we still on the correct tab?
            -- Look back through steps to find the required tabIndex
            local requiredTabIndex = nil
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.tabIndex then
                    requiredTabIndex = prevStep.tabIndex
                    break
                end
            end
            
            if requiredTabIndex then
                local currentTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame)
                if currentTab and currentTab ~= requiredTabIndex then
                    -- User clicked away to wrong tab - go back to the tab selection step
                    for i, s in ipairs(currentGuide.steps) do
                        if s.tabIndex == requiredTabIndex then
                            currentStepIndex = i
                            break
                        end
                    end
                    self:HideHighlight()
                    return
                end
            end
            
            -- Check if already on correct category
            local isSelected = self:IsAchievementCategorySelected(step.achievementCategory)
            
            -- Also check if the user has clicked our highlighted button
            if lastHighlightedCategoryButton and lastHighlightedCategoryName and 
               lastHighlightedCategoryName:lower() == step.achievementCategory:lower() then
                if lastHighlightedCategoryButton:IsMouseOver() then
                    isSelected = true
                end
            end
            
            if isSelected then
                if isLastStep then
                    lastHighlightedCategoryButton = nil
                    lastHighlightedCategoryName = nil
                    self:Cancel()
                else
                    lastHighlightedCategoryButton = nil
                    lastHighlightedCategoryName = nil
                    self:AdvanceStep()
                end
                return
            end
            
            -- Need to click category in tree - find and highlight the button
            local categoryBtn = self:GetAchievementCategoryButton(step.achievementCategory)
            if categoryBtn then
                lastHighlightedCategoryButton = categoryBtn
                lastHighlightedCategoryName = step.achievementCategory
                self:HighlightFrame(categoryBtn)
            elseif isLastStep then
                -- Can't find button on last step - try expanding parent
                local prevStepIndex = currentStepIndex - 1
                if prevStepIndex >= 1 then
                    local prevStep = currentGuide.steps[prevStepIndex]
                    if prevStep and prevStep.achievementCategory then
                        local parentBtn = self:GetAchievementCategoryButton(prevStep.achievementCategory)
                        if parentBtn then
                            lastHighlightedCategoryButton = parentBtn
                            lastHighlightedCategoryName = prevStep.achievementCategory
                            self:HighlightFrame(parentBtn)
                            return
                        end
                    end
                end
                self:ShowInstruction(step.text or "Click '" .. step.achievementCategory .. "' in the category list")
            end
            return
        end
        
        -- Character Frame sidebar buttons (Character Stats, Titles, Equipment Manager)
        if step.sidebarButtonFrame or step.sidebarIndex then
            -- Check we're on the correct CharacterFrame tab first
            local requiredTabIndex = nil
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.tabIndex then
                    requiredTabIndex = prevStep.tabIndex
                    break
                end
            end
            
            if requiredTabIndex then
                local currentTab = self:GetCurrentTabIndex(step.waitForFrame or "CharacterFrame")
                if currentTab and currentTab ~= requiredTabIndex then
                    for i = currentStepIndex - 1, 1, -1 do
                        local prevStep = currentGuide.steps[i]
                        if prevStep and prevStep.tabIndex == requiredTabIndex then
                            currentStepIndex = i
                            self:HideHighlight()
                            return
                        end
                    end
                end
            end
            
            -- Check if the sidebar tab is already selected
            if self:IsSidebarTabSelected(step.sidebarIndex) then
                if isLastStep then
                    self:Cancel()
                else
                    self:AdvanceStep()
                end
                return
            end
            
            -- Highlight the sidebar tab button
            local sidebarBtn = self:GetSidebarTabButton(step.sidebarIndex)
            if sidebarBtn then
                self:HighlightFrame(sidebarBtn)
                -- Check for click/hover to advance
                if sidebarBtn:IsMouseOver() then
                    if isLastStep then
                        self:Cancel()
                    else
                        self:AdvanceStep()
                    end
                end
            elseif isLastStep then
                local tabNames = {"Character Stats", "Titles", "Equipment Manager"}
                local tabName = tabNames[step.sidebarIndex] or ("Sidebar Tab " .. (step.sidebarIndex or "?"))
                self:ShowInstruction(step.text or "Click the '" .. tabName .. "' tab on the right side of the character panel")
            end
            return
        end
        
        -- Text-only final step (when we've navigated but can't highlight specific element)
        if step.text and not step.regionFrames and not step.regionFrame and not step.searchButtonText then
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
            
            -- If path-based lookup failed, try text-based search as fallback
            if not region and step.searchButtonText then
                region = self:FindRatedPvPButton(step.searchButtonText)
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

-- Get the currently selected tab index for a frame
function Highlight:GetCurrentTabIndex(frameName)
    -- PVEFrame (Group Finder tabs at bottom: Dungeons & Raids, Player vs Player, Mythic+ Dungeons)
    if frameName == "PVEFrame" then
        local frame = PVEFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame)
        end
        return nil
    end
    
    -- AchievementFrame
    if frameName == "AchievementFrame" then
        local frame = AchievementFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame)
        end
        return nil
    end
    
    -- CharacterFrame
    if frameName == "CharacterFrame" then
        local frame = CharacterFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame)
        end
        return nil
    end
    
    -- CollectionsJournal
    if frameName == "CollectionsJournal" then
        local frame = CollectionsJournal
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame)
        end
        return nil
    end
    
    -- EncounterJournal
    if frameName == "EncounterJournal" then
        local frame = EncounterJournal
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame)
        end
        return nil
    end
    
    return nil
end

function Highlight:IsSideTabSelected(frameName, sideTabIndex)
    -- PVEFrame side buttons (Dungeon Finder, Raid Finder, Premade Groups)
    if frameName == "PVEFrame" then
        if sideTabIndex == 1 then
            return LFDParentFrame and LFDParentFrame:IsShown()
        elseif sideTabIndex == 2 then
            return RaidFinderFrame and RaidFinderFrame:IsShown()
        elseif sideTabIndex == 3 then
            -- Premade Groups: check LFGListPVEStub first, then LFGListFrame (modern WoW)
            -- BUT only if Dungeon Finder and Raid Finder are NOT active (LFGListFrame is
            -- a shared frame that may report IsShown even when another panel is on top)
            if LFDParentFrame and LFDParentFrame:IsShown() then
                return false
            end
            if RaidFinderFrame and RaidFinderFrame:IsShown() then
                return false
            end
            if LFGListPVEStub and LFGListPVEStub:IsShown() then
                return true
            end
            -- Check if LFGListFrame.CategorySelection is visible (the actual premade category list)
            if LFGListFrame and LFGListFrame.CategorySelection and LFGListFrame.CategorySelection:IsShown() then
                return true
            end
            return false
        end
        return false
    end
    
    return false
end

function Highlight:IsPvPSideTabSelected(frameName, sideTabIndex)
    -- PVEFrame PvP side buttons (Quick Match, Rated, Premade Groups, Training Grounds)
    if frameName == "PVEFrame" then
        -- First check the known panel frames for tabs 1-3
        local tab1Active = HonorFrame and HonorFrame:IsShown()
        local tab2Active = ConquestFrame and ConquestFrame:IsShown()
        local tab3Active = (LFGListPVPStub and LFGListPVPStub:IsShown()) or
                           (LFGListFrame and LFGListFrame.CategorySelection and LFGListFrame.CategorySelection:IsShown() and
                            PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(PVEFrame) == 2)
        
        if sideTabIndex == 1 then
            return tab1Active and true or false
        elseif sideTabIndex == 2 then
            return tab2Active and true or false
        elseif sideTabIndex == 3 then
            return tab3Active and true or false
        elseif sideTabIndex == 4 then
            -- Training Grounds: check TrainingGroundsFrame (confirmed via DevFrame)
            if TrainingGroundsFrame and TrainingGroundsFrame:IsShown() then
                return true
            end
            -- Fallback: we're on it if we're on PvP tab but none of the other 3 panels are active
            local onPvPTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(PVEFrame) == 2
            if onPvPTab and not tab1Active and not tab2Active and not tab3Active then
                return true
            end
            return false
        end
        
        -- Fallback: check button selected state for any tab
        local pvpButtons = self:GetPvPSideTabButtons()
        if pvpButtons and pvpButtons[sideTabIndex] then
            local btn = pvpButtons[sideTabIndex]
            if btn.GetSelectedState and btn:GetSelectedState() then return true end
            if btn.IsSelected and btn:IsSelected() then return true end
            if btn.selectedTex and btn.selectedTex:IsShown() then return true end
            if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
            if btn.Selected and btn.Selected:IsShown() then return true end
            if btn.isSelected then return true end
        end
        
        return false
    end
    
    return false
end

function Highlight:GetPvPSideTabButtons()
    -- Find the PvP side tab buttons
    local buttons = {}
    
    if not PVPQueueFrame then return buttons end
    
    -- Primary: CategoryButton1-4 (confirmed via DevFrame)
    -- CategoryButton1 = Quick Match, 2 = Rated, 3 = Premade Groups, 4 = Training Grounds
    for i = 1, 4 do
        local btn = PVPQueueFrame["CategoryButton" .. i]
        if btn then
            buttons[i] = btn
        end
    end
    
    -- Fallback: try legacy named buttons if CategoryButtons not found
    if not buttons[1] then
        local legacyNames = {"HonorButton", "ConquestButton", "LFGListButton", "TrainingGroundsButton"}
        for i, name in ipairs(legacyNames) do
            if PVPQueueFrame[name] then
                buttons[i] = PVPQueueFrame[name]
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
-- Track which category button was last clicked/highlighted for better detection
local lastHighlightedCategoryButton = nil
local lastHighlightedCategoryName = nil

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
    
    -- Helper to check if a button appears selected using multiple detection methods
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
        
        -- Modern WoW uses Background visibility for selection
        if btn.Background and btn.Background:IsShown() then return true end
        
        -- Check if the button has an "isHeader" property and is expanded
        if btn.element and btn.element.collapsed == false then return true end
        
        return false
    end
    
    -- Method 1: Check if we previously highlighted this category and user clicked it
    -- This is the most reliable - if we highlighted a button and it's no longer being highlighted
    -- but we're now looking for this same category, user must have clicked it
    if lastHighlightedCategoryName and lastHighlightedCategoryName:lower() == categoryNameLower then
        if lastHighlightedCategoryButton then
            -- The button we highlighted is the one we're checking - user likely clicked it
            -- Check if the button is no longer in the highlight frame's position (user clicked it)
            if not highlightFrame:IsShown() or not arrowFrame:IsShown() then
                -- Highlights are hidden, user must have navigated
                return true
            end
        end
    end
    
    -- Method 2: Try AchievementFrameCategories with ScrollBox (modern 10.x+ UI)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        if scrollBox.EnumerateFrames then
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
    end
    
    -- Method 3: Check AchievementFrameAchievements.selectedCategory or similar
    local statsFrame = AchievementFrameAchievements
    if statsFrame then
        if statsFrame.selectedCategory then
            local selName = statsFrame.selectedCategory
            if type(selName) == "string" and selName:lower() == categoryNameLower then
                return true
            end
        end
        
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
    
    -- Method 4: Look for numbered buttons
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
    
    -- Method 5: For parent categories, check if child categories are now visible
    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.statisticsCategory then
            local nextBtn = self:GetStatisticsCategoryButton(nextStep.statisticsCategory)
            if nextBtn and nextBtn:IsShown() then
                return true
            end
        end
    end
    
    -- Method 6: Check if statistics content panel shows items related to this category
    -- This is especially useful for leaf categories like "World" which show Duel stats
    local contentFrame = _G["AchievementFrameAchievementsContainer"] or 
                         _G["AchievementFrameStatsContainer"] or
                         (AchievementFrame and AchievementFrame.Container)
    
    if contentFrame then
        -- For "World" category (duel statistics), check if "Duels won" or "Duels lost" is visible
        if categoryNameLower == "world" then
            local function searchForDuelStats(frame, depth)
                if not frame or depth > 8 then return false end
                if frame.GetText then
                    local text = frame:GetText()
                    if text then
                        local textLower = text:lower()
                        if textLower:find("duels won") or textLower:find("duels lost") then
                            return true
                        end
                    end
                end
                -- Check children
                if frame.GetChildren then
                    local children = {frame:GetChildren()}
                    for _, child in ipairs(children) do
                        if searchForDuelStats(child, depth + 1) then
                            return true
                        end
                    end
                end
                -- Check regions (FontStrings)
                if frame.GetRegions then
                    local regions = {frame:GetRegions()}
                    for _, region in ipairs(regions) do
                        if region.GetText then
                            local text = region:GetText()
                            if text then
                                local textLower = text:lower()
                                if textLower:find("duels won") or textLower:find("duels lost") then
                                    return true
                                end
                            end
                        end
                    end
                end
                return false
            end
            
            if AchievementFrame and searchForDuelStats(AchievementFrame, 0) then
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

-- Achievement category navigation helpers (works on any Achievement tab, not just Statistics)
function Highlight:IsAchievementCategorySelected(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    
    local categoryNameLower = categoryName:lower()
    
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
    
    local function isButtonSelected(btn)
        if not btn then return false end
        if btn.isSelected then return true end
        if btn.selected then return true end
        if btn.collapsed == false then return true end
        if btn.isExpanded then return true end
        if btn.expanded then return true end
        if btn.highlight and btn.highlight:IsShown() then return true end
        if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
        if btn.SelectedTexture and btn.SelectedTexture:IsShown() then return true end
        if btn.Selection and btn.Selection:IsShown() then return true end
        if btn.selection and btn.selection:IsShown() then return true end
        if btn.Background and btn.Background:IsShown() then return true end
        if btn.element and btn.element.collapsed == false then return true end
        return false
    end
    
    -- Check if we previously highlighted this category and user clicked it
    if lastHighlightedCategoryName and lastHighlightedCategoryName:lower() == categoryNameLower then
        if lastHighlightedCategoryButton then
            if not highlightFrame:IsShown() or not arrowFrame:IsShown() then
                return true
            end
        end
    end
    
    -- Try AchievementFrameCategories with ScrollBox
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        if scrollBox.EnumerateFrames then
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
    end
    
    -- Check numbered buttons
    for i = 1, 40 do
        local btn = _G["AchievementFrameCategoriesContainerButton" .. i] or
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
    
    -- Check if the next step's category is now visible (parent must be expanded)
    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.achievementCategory then
            local nextBtn = self:GetAchievementCategoryButton(nextStep.achievementCategory)
            if nextBtn and nextBtn:IsShown() then
                return true
            end
        end
    end
    
    return false
end

function Highlight:GetAchievementCategoryButton(categoryName)
    -- Find the button for an achievement category by name (works on any tab)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end
    
    local categoryNameLower = categoryName:lower()
    
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
            if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText and region:GetText() then
                return region:GetText()
            end
        end
        return nil
    end
    
    local function searchFrameTree(frame, depth)
        if not frame or depth > 6 then return nil end
        if frame:IsShown() then
            local text = getButtonText(frame)
            if text and text:lower() == categoryNameLower then
                if frame.Click or (frame.IsMouseEnabled and frame:IsMouseEnabled()) then
                    return frame
                end
            end
        end
        local children = {frame:GetChildren()}
        for _, child in ipairs(children) do
            local result = searchFrameTree(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    
    -- Method 1: Try AchievementFrameCategories with ScrollBox
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame then
        if categoriesFrame.ScrollBox and categoriesFrame.ScrollBox.EnumerateFrames then
            for _, btn in categoriesFrame.ScrollBox:EnumerateFrames() do
                if btn and btn:IsShown() then
                    local btnText = getButtonText(btn)
                    if btnText and btnText:lower() == categoryNameLower then
                        return btn
                    end
                end
            end
        end
        local result = searchFrameTree(categoriesFrame, 0)
        if result then return result end
    end
    
    -- Method 2: Search the entire AchievementFrame tree
    if AchievementFrame then
        local result = searchFrameTree(AchievementFrame, 0)
        if result then return result end
    end
    
    -- Method 3: Try numbered category buttons
    for i = 1, 50 do
        local btn = _G["AchievementFrameCategoriesContainerButton" .. i] or
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

-- Character Frame sidebar tab helpers (Character Stats, Titles, Equipment Manager)
function Highlight:IsSidebarTabSelected(sidebarIndex)
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end
    
    -- Check if the correct sidebar pane is shown
    if sidebarIndex == 1 then
        -- Character Stats - check if CharacterStatsPane or the default paperdoll stats view is shown
        if CharacterStatsPane and CharacterStatsPane:IsShown() then return true end
        -- Default view when Character tab is open and no other sidebar is active
    elseif sidebarIndex == 2 then
        -- Titles pane
        if PaperDollTitlesPane and PaperDollTitlesPane:IsShown() then return true end
    elseif sidebarIndex == 3 then
        -- Equipment Manager pane
        if PaperDollEquipmentManagerPane and PaperDollEquipmentManagerPane:IsShown() then return true end
    end
    
    -- Also check the sidebar tab's visual selected state
    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab then
        if sidebarTab.isSelected then return true end
        if sidebarTab.selected then return true end
        -- Check for checked/pressed state on buttons
        if sidebarTab.GetChecked and sidebarTab:GetChecked() then return true end
        if sidebarTab.IsChecked and sidebarTab:IsChecked() then return true end
    end
    
    return false
end

function Highlight:GetSidebarTabButton(sidebarIndex)
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return nil
    end
    
    -- Try PaperDollSidebarTab buttons directly (confirmed via Frame Inspector)
    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab and sidebarTab:IsShown() then
        return sidebarTab
    end
    
    -- Try PaperDollSidebarTabs container children
    local sidebarTabs = _G["PaperDollSidebarTabs"]
    if not sidebarTabs and PaperDollFrame then
        sidebarTabs = PaperDollFrame.SidebarTabs
    end
    if sidebarTabs then
        local children = {sidebarTabs:GetChildren()}
        if children[sidebarIndex] and children[sidebarIndex]:IsShown() then
            return children[sidebarIndex]
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
    
    -- Helper to get ALL text from a frame combined (main text + subtitles)
    local function getAllFrameText(frame)
        if not frame then return nil end
        local texts = {}
        
        -- Check named text children
        local textKeys = {"Label", "label", "Text", "text", "Name", "name"}
        for _, key in ipairs(textKeys) do
            if frame[key] and frame[key].GetText then
                local t = frame[key]:GetText()
                if t then texts[#texts + 1] = t end
            end
        end
        
        -- GetText on the frame itself
        if frame.GetText then
            local t = frame:GetText()
            if t then texts[#texts + 1] = t end
        end
        
        -- Check all fontstring regions
        local regions = {frame:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                if region.GetText then
                    local t = region:GetText()
                    if t then texts[#texts + 1] = t end
                end
            end
        end
        
        if #texts > 0 then
            return table.concat(texts, " ")
        end
        return nil
    end
    
    -- Recursively search a frame tree
    local function searchTree(frame, depth)
        if not frame or depth > 6 then return nil end
        
        -- Check if this frame is a clickable button-like frame with matching text
        if frame:IsShown() then
            -- Only consider frames of reasonable button size (not tiny icons or huge panels)
            local w, h = frame:GetSize()
            if w and h and w > 80 and h > 20 and w < 500 then
                local text = getAllFrameText(frame)
                if text and text:lower():find(searchText, 1, true) then
                    -- Check if it's interactable
                    if frame.Click or (frame.IsMouseEnabled and frame:IsMouseEnabled()) then
                        return frame
                    end
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
    if contextTooltip then
        contextTooltip:Hide()
    end
end

-- Portrait menu helpers
function Highlight:IsPortraitMenuOpen()
    -- Method 1: Check old-style DropDownList frames
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            return true
        end
    end
    
    -- Method 2: Check modern Menu system (11.0+)
    -- The Menu API creates frames managed by MenuManager
    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(function() return manager:GetOpenMenu() end)
            if openOk and openMenu then
                return true
            end
        end
    end
    
    -- Method 3: Check if UIDROPDOWNMENU is open
    if UIDROPDOWNMENU_OPEN_MENU and UIDROPDOWNMENU_OPEN_MENU ~= "" then
        return true
    end
    
    -- Method 4: Check for any visible context menu frame by common naming patterns
    local menuNames = {"PlayerFrameDropDown", "DropDownList1", "UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(function() return frame:IsShown() end)
            if ok and shown then
                return true
            end
        end
    end
    
    return false
end

-- Find the visible portrait/context menu frame
function Highlight:GetPortraitMenuFrame()
    -- Check old-style DropDownList frames
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            return dropdown
        end
    end
    
    -- Check modern Menu system
    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(function() return manager:GetOpenMenu() end)
            if openOk and openMenu then
                return openMenu
            end
        end
    end
    
    -- Fallback: check common frame names
    local menuNames = {"UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(function() return frame:IsShown() end)
            if ok and shown then
                return frame
            end
        end
    end
    
    return nil
end

function Highlight:FindPortraitMenuOption(optionName)
    local optionNameLower = optionName:lower()
    
    local function getFrameText(frame)
        if not frame then return nil end
        if frame.GetText then
            local ok, t = pcall(function() return frame:GetText() end)
            if ok and t then return t end
        end
        local regOk, regions = pcall(function() return {frame:GetRegions()} end)
        if regOk and regions then
            for _, region in ipairs(regions) do
                if region.GetText then
                    local ok2, t2 = pcall(function() return region:GetText() end)
                    if ok2 and t2 then return t2 end
                end
            end
        end
        return nil
    end
    
    local function searchFrame(frame, depth)
        if not frame or depth > 8 then return nil end
        
        local childOk, children = pcall(function() return {frame:GetChildren()} end)
        if not childOk or not children then return nil end
        for _, child in ipairs(children) do
            local shownOk, shown = pcall(function() return child:IsShown() end)
            if shownOk and shown then
                local text = getFrameText(child)
                if text and text:lower():find(optionNameLower, 1, true) then
                    -- Found matching option - return it if clickable
                    return child
                end
                
                local result = searchFrame(child, depth + 1)
                if result then return result end
            end
        end
        return nil
    end
    
    -- Search DropDownList frames (legacy)
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            local result = searchFrame(dropdown, 0)
            if result then return result end
        end
    end
    
    -- Search modern Menu system (11.0+)
    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(function() return manager:GetOpenMenu() end)
            if openOk and openMenu then
                local result = searchFrame(openMenu, 0)
                if result then return result end
            end
        end
    end
    
    -- Fallback: search common menu frame names
    local menuNames = {"UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(function() return frame:IsShown() end)
            if ok and shown then
                local result = searchFrame(frame, 0)
                if result then return result end
            end
        end
    end
    
    return nil
end

function Highlight:Cancel()
    self:HideHighlight()
    self:HideContextTooltip()
    
    if stepTicker then
        stepTicker:Cancel()
        stepTicker = nil
    end
    
    currentGuide = nil
    currentStepIndex = nil
    lastHighlightedCategoryButton = nil
    lastHighlightedCategoryName = nil
end
