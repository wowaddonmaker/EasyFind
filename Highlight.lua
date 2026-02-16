local ADDON_NAME, ns = ...

local Highlight = {}
ns.Highlight = Highlight

local Utils = ns.Utils
local GetButtonText      = Utils.GetButtonText
local IsButtonSelected   = Utils.IsButtonSelected
local SearchFrameTree    = Utils.SearchFrameTree
local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
local GetAllFrameText    = Utils.GetAllFrameText
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local mmin, mmax, mabs, mpi = Utils.mmin, Utils.mmax, Utils.mabs, Utils.mpi
local pcall = Utils.pcall

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local hooksecurefunc     = hooksecurefunc
local wipe               = wipe
local strsplit           = strsplit

local highlightFrame
local indicatorFrame
local instructionFrame
local contextTooltip
local currentGuide
local currentStepIndex
local stepTicker

function Highlight:Initialize()
    if highlightFrame then return end
    self:CreateHighlightFrame()
    self:CreateIndicatorFrame()
    self:CreateInstructionFrame()
    self:CreateContextTooltip()
end

function Highlight:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "EasyFindHighlightFrame", UIParent)
    highlightFrame:SetFrameStrata("TOOLTIP")
    highlightFrame:SetFrameLevel(500)
    highlightFrame:Hide()
    
    local borderSize = 4
    
    -- Highlight border is ALWAYS yellow
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

function Highlight:CreateIndicatorFrame()
    indicatorFrame = CreateFrame("Frame", "EasyFindIndicatorFrame", UIParent)
    local aSize = ns.ICON_SIZE or 48
    indicatorFrame:SetSize(aSize, aSize)
    indicatorFrame:SetFrameStrata("TOOLTIP")
    indicatorFrame:SetFrameLevel(501)
    indicatorFrame.isUIIndicator = true  -- flag so UpdateIndicator applies iconScale
    indicatorFrame:Hide()

    -- Use shared icon creation with UI-specific sizes (no canvas conversion needed)
    if ns.CreateIndicatorTextures then
        ns.CreateIndicatorTextures(indicatorFrame, ns.ICON_SIZE, ns.ICON_GLOW_SIZE)
    else
        -- Fallback if MapSearch hasn't loaded yet (shouldn't happen per .toc order)
        local ind = indicatorFrame:CreateTexture(nil, "ARTWORK")
        ind:SetSize(80, 80)
        ind:SetPoint("CENTER")
        ind:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
        ind:SetRotation(mpi)
        indicatorFrame.indicator = ind
    end

    local animGroup = indicatorFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local trans = animGroup:CreateAnimation("Translation")
    trans:SetOffset(0, -10)
    trans:SetDuration(0.4)
    indicatorFrame.animGroup = animGroup
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

-- Start the guide at a specific step (used by DirectOpen to skip to final highlight)
function Highlight:StartGuideAtStep(guideData, stepIndex)
    self:Cancel()
    
    if not guideData or not guideData.steps or #guideData.steps == 0 then
        return
    end
    
    if stepIndex > #guideData.steps then
        stepIndex = #guideData.steps
    end
    
    currentGuide = guideData
    currentStepIndex = stepIndex
    
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
                -- Highlight tab (even if disabled - show user where it is)
                self:HighlightFrame(tabBtn)

                -- If button is disabled and user hovers over it, clear the highlight
                local isEnabled = not tabBtn.IsEnabled or tabBtn:IsEnabled()
                if not isEnabled and tabBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
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
                -- Highlight side tab (even if disabled - show user where it is)
                self:HighlightFrame(sideBtn)

                -- If button is disabled and user hovers over it, clear the highlight
                local isEnabled = not sideBtn.IsEnabled or sideBtn:IsEnabled()
                if not isEnabled and sideBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
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
                -- Highlight PvP side tab (even if disabled - show user where it is)
                self:HighlightFrame(pvpBtn)

                -- If button is disabled and user hovers over it, clear the highlight
                local isEnabled = not pvpBtn.IsEnabled or pvpBtn:IsEnabled()
                if not isEnabled and pvpBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
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
                for i, s in ipairs(currentGuide.steps) do
                    if s.tabIndex == 3 then
                        currentStepIndex = i
                        break
                    end
                end
                self:HideHighlight()
                return
            end
            
            -- Prerequisite check: verify ALL earlier statisticsCategory steps are still
            -- expanded (children visible). A parent doesn't need to stay "selected" once
            -- we've drilled into a child — it just needs to still be expanded.
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.statisticsCategory then
                    if not self:IsCategoryExpandedOrSelected(prevStep.statisticsCategory) then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end
            end
            
            -- Check if already on correct statistics category
            if self:IsCategorySelectedByData(step.statisticsCategory) then
                if isLastStep then
                    self:Cancel()
                    return
                end
                -- Non-final: only advance if children are actually visible (parent expanded),
                -- not just selected — clicking a collapsed parent selects it without showing children
                local elementData = self:FindCategoryElementData(step.statisticsCategory)
                if not elementData or not elementData.parent or not elementData.collapsed then
                    self:AdvanceStep()
                    return
                end
                -- Selected but collapsed — fall through to highlight so user expands it
            end

            -- For non-final steps: if the category is a parent that's expanded (children visible),
            -- skip ahead — don't force the user to re-select a parent they've already drilled into
            if not isLastStep then
                local elementData = self:FindCategoryElementData(step.statisticsCategory)
                if elementData and elementData.parent and not elementData.collapsed then
                    self:AdvanceStep()
                    return
                end
            end

            -- Not selected — find the button (scrolls into view automatically)
            local categoryBtn = self:GetStatisticsCategoryButton(step.statisticsCategory)
            if categoryBtn then
                self:HighlightFrame(categoryBtn)
            else
                self:ShowInstruction(step.text or "Click '" .. step.statisticsCategory .. "' in the category list")
            end
            return
        end
        
        -- Achievement category navigation (tree-based category selection in Achievements/Guild tabs)
        if step.achievementCategory then
            -- First check: are we still on the correct tab?
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
            
            -- Prerequisite check: verify ALL earlier achievementCategory steps are still
            -- expanded (children visible). A parent doesn't need to stay "selected" once
            -- we've drilled into a child — it just needs to still be expanded.
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.achievementCategory then
                    if not self:IsCategoryExpandedOrSelected(prevStep.achievementCategory) then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end
            end
            
            -- Check if already on correct category
            if self:IsCategorySelectedByData(step.achievementCategory) then
                if isLastStep then
                    self:Cancel()
                    return
                end
                -- Non-final: only advance if children are actually visible (parent expanded),
                -- not just selected — clicking a collapsed parent selects it without showing children
                local elementData = self:FindCategoryElementData(step.achievementCategory)
                if not elementData or not elementData.parent or not elementData.collapsed then
                    self:AdvanceStep()
                    return
                end
                -- Selected but collapsed — fall through to highlight so user expands it
            end

            -- For non-final steps: if the category is a parent that's expanded (children visible),
            -- skip ahead — don't force the user to re-select a parent they've already drilled into
            if not isLastStep then
                local elementData = self:FindCategoryElementData(step.achievementCategory)
                if elementData and elementData.parent and not elementData.collapsed then
                    self:AdvanceStep()
                    return
                end
            end

            -- Not selected — find the button (scrolls into view automatically)
            local categoryBtn = self:GetAchievementCategoryButton(step.achievementCategory)
            if categoryBtn then
                self:HighlightFrame(categoryBtn)
            else
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
        
        -- Currency header expansion (expand a header section in the Currency tab)
        if step.currencyHeader then
            -- Check we're on the correct CharacterFrame tab (Currency = tab 3)
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
            
            -- Check if header is already expanded, collapsed, or not in list (parent collapsed)
            local headerState = self:IsCurrencyHeaderExpanded(step.currencyHeader)
            
            if headerState == true then
                -- Header is expanded — advance to next step
                if isLastStep then
                    self:Cancel()
                else
                    self:AdvanceStep()
                end
                return
            end
            
            if headerState == nil then
                -- Header not found — parent must be collapsed.
                -- First, try to go back to previous currencyHeader step
                for i = currentStepIndex - 1, 1, -1 do
                    local prevStep = currentGuide.steps[i]
                    if prevStep and prevStep.currencyHeader then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end

                -- No previous step found - find and highlight first collapsed header from top
                if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
                    local size = C_CurrencyInfo.GetCurrencyListSize()
                    for i = 1, size do
                        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
                        if info and info.isHeader and not info.isHeaderExpanded then
                            -- Try to find and highlight the button
                            local btn = self:GetCurrencyHeaderButton(info.name)
                            if btn then
                                self:HighlightFrame(btn)
                                return
                            else
                                -- Button not found - hide and retry
                                self:HideHighlight()
                                return
                            end
                        end
                    end
                end
                -- All headers expanded but target still not found
                self:HideHighlight()
                return
            end

            -- headerState == false: header is visible but collapsed — find and highlight the button
            local headerBtn = self:GetCurrencyHeaderButton(step.currencyHeader)
            if headerBtn then
                -- Found the button - highlight it for user to click
                self:HighlightFrame(headerBtn)
                return
            else
                -- Button not found - hide highlight and retry on next tick
                self:HideHighlight()
                return
            end
        end
        
        -- Currency row highlight (scroll to and highlight a specific currency by ID)
        if step.currencyID then
            -- Check we're on the correct CharacterFrame tab (Currency = tab 3)
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
            
            -- Check if ALL parent headers are still expanded; if any collapsed or missing, go back
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.currencyHeader then
                    local state = self:IsCurrencyHeaderExpanded(prevStep.currencyHeader)
                    if state ~= true then
                        -- Either collapsed (false) or parent not visible (nil) — go back
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                    -- Don't break — check ALL parent headers in the chain
                end
            end
            
            -- Scroll to the currency and highlight its row
            self:ScrollToCurrencyRow(step.currencyID)
            local currencyBtn = self:GetCurrencyRowButton(step.currencyID)
            if currencyBtn then
                self:HighlightFrame(currencyBtn)
                if currencyBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
            elseif isLastStep then
                local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(step.currencyID)
                local name = info and info.name or ("Currency " .. step.currencyID)
                self:ShowInstruction(step.text or "Look for '" .. name .. "' in the currency list")
            end
            return
        end

        -- Faction header expansion (expand a header section in the Reputation tab)
        if step.factionHeader then
            -- Check we're on the correct CharacterFrame tab (Reputation = tab 2)
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

            -- Check if header is already expanded, collapsed, or not in list (parent collapsed)
            local headerState = self:IsFactionHeaderExpanded(step.factionHeader)

            if headerState == true then
                -- Header is expanded — advance to next step
                if isLastStep then
                    self:Cancel()
                else
                    self:AdvanceStep()
                end
                return
            end

            if headerState == nil then
                -- Header not found — parent must be collapsed.
                -- First, try to go back to previous factionHeader step
                for i = currentStepIndex - 1, 1, -1 do
                    local prevStep = currentGuide.steps[i]
                    if prevStep and prevStep.factionHeader then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end

                -- No previous step found - find and highlight first collapsed header from top
                if C_Reputation and C_Reputation.GetNumFactions then
                    local numFactions = C_Reputation.GetNumFactions()
                    for i = 1, numFactions do
                        local factionData = C_Reputation.GetFactionDataByIndex(i)
                        if factionData and factionData.isHeader and not factionData.isHeaderExpanded then
                            -- Try to find and highlight the button
                            local btn = self:GetFactionHeaderButton(factionData.name)
                            if btn then
                                self:HighlightFrame(btn)
                                return
                            else
                                -- Button not found - hide and retry
                                self:HideHighlight()
                                return
                            end
                        end
                    end
                end

                -- No collapsed headers found — wait
                self:HideHighlight()
                return
            end

            -- headerState == false: header is visible but collapsed — find and highlight the button
            local headerBtn = self:GetFactionHeaderButton(step.factionHeader)
            if headerBtn then
                -- Found the button - highlight it for user to click
                self:HighlightFrame(headerBtn)
                return
            else
                -- Button not found - hide highlight and retry on next tick
                self:HideHighlight()
                return
            end
        end

        -- Faction row highlight (scroll to and highlight a specific faction by ID)
        if step.factionID then
            -- Check we're on the correct CharacterFrame tab (Reputation = tab 2)
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

            -- Check if ALL parent headers are still expanded; if any collapsed or missing, go back
            for i = currentStepIndex - 1, 1, -1 do
                local prevStep = currentGuide.steps[i]
                if prevStep and prevStep.factionHeader then
                    local state = self:IsFactionHeaderExpanded(prevStep.factionHeader)
                    if state ~= true then
                        -- Either collapsed (false) or parent not visible (nil) — go back
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                    -- Don't break — check ALL parent headers in the chain
                end
            end

            -- Scroll to the faction and highlight its row
            self:ScrollToFactionRow(step.factionID)
            local factionBtn = self:GetFactionRowButton(step.factionID)
            if factionBtn then
                self:HighlightFrame(factionBtn)
                if factionBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
            elseif isLastStep then
                -- Last step but button not found — show instruction without highlight
                local numFactions = C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetNumFactions()
                local factionName = "Faction " .. step.factionID
                if numFactions then
                    for i = 1, numFactions do
                        local factionData = C_Reputation.GetFactionDataByIndex(i)
                        if factionData and factionData.factionID == step.factionID then
                            factionName = factionData.name
                            break
                        end
                    end
                end
                self:ShowInstruction(step.text or "Look for '" .. factionName .. "' in the reputation list")
            end
            return
        end

        -- =====================================================================
        -- PREREQUISITE VALIDATION for final-destination steps (regionFrames,
        -- searchButtonText, text-only).  Walk backwards through the step list
        -- and make sure every earlier tab / side-tab prerequisite is still
        -- satisfied.  If the user switched away (e.g. clicked Training Grounds
        -- while we expect Premade Groups) we rewind to that step so the guide
        -- re-highlights the correct side-tab button instead of pointing at
        -- empty space.
        -- =====================================================================
        do
            for i = currentStepIndex - 1, 1, -1 do
                local prev = currentGuide.steps[i]
                if not prev then break end

                -- Validate main tab (tabIndex)
                if prev.tabIndex and prev.waitForFrame then
                    local currentTab = self:GetCurrentTabIndex(prev.waitForFrame)
                    if currentTab and currentTab ~= prev.tabIndex then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end

                -- Validate PvP side tab (pvpSideTabIndex)
                if prev.pvpSideTabIndex and prev.waitForFrame then
                    if not self:IsPvPSideTabSelected(prev.waitForFrame, prev.pvpSideTabIndex) then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end

                -- Validate PvE side tab (sideTabIndex)
                if prev.sideTabIndex and prev.waitForFrame then
                    if not self:IsSideTabSelected(prev.waitForFrame, prev.sideTabIndex) then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end

                -- Validate Character Frame sidebar tab (sidebarIndex)
                if prev.sidebarIndex then
                    if not self:IsSidebarTabSelected(prev.sidebarIndex) then
                        currentStepIndex = i
                        self:HideHighlight()
                        return
                    end
                end
            end
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
    
    -- Special dynamic lookup for unnamed frames
    if path == "FIND_PVP_TALENTS" then
        return self:FindPvPTalentsTray()
    end
    
    return Utils.GetFrameByPath(path)
end

function Highlight:FindPvPTalentsTray()
    local paths = {
        "PlayerSpellsFrame.TalentsFrame.PvPTalentSlotTray",
        "ClassTalentFrame.TalentsTab.PvPTalentSlotTray",
        "ClassTalentFrame.PvPTalentSlotTray",
    }
    
    for _, path in ipairs(paths) do
        local frame = Utils.GetFrameByPath(path)
        if frame and frame:IsShown() then
            return frame
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
    local frame = _G[frameName]
    if frame and PanelTemplates_GetSelectedTab then
        return PanelTemplates_GetSelectedTab(frame)
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
        -- First check the known panel frames for each tab
        local tab1Active = HonorFrame and HonorFrame:IsShown()
        local tab2Active = ConquestFrame and ConquestFrame:IsShown()
        local tab4Active = TrainingGroundsFrame and TrainingGroundsFrame:IsShown()
        -- Tab 3 (Premade Groups): LFGListFrame is shared, so we must explicitly
        -- rule out every other sub-panel before trusting it.
        local tab3Active = false
        if not tab1Active and not tab2Active and not tab4Active then
            if LFGListPVPStub and LFGListPVPStub:IsShown() then
                tab3Active = true
            elseif LFGListFrame and LFGListFrame.CategorySelection and LFGListFrame.CategorySelection:IsShown() and
                   PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(PVEFrame) == 2 then
                tab3Active = true
            end
        end
        
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

-- =============================================================================
-- ACHIEVEMENT/STATISTICS CATEGORY NAVIGATION HELPERS
-- All three tabs (Achievements, Guild, Statistics) share AchievementFrameCategories.ScrollBox.
-- Element data: { id = <categoryID>, selected = true/false, parent = ..., isChild = ..., ... }
-- Category names are resolved via GetCategoryInfo(elementData.id).
-- =============================================================================

-- Shared helper: find element data in the ScrollBox data provider by category name.
-- Returns (elementData, scrollBox) or (nil, nil).
function Highlight:FindCategoryElementData(categoryName)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if not categoriesFrame or not categoriesFrame.ScrollBox then return nil, nil end

    local scrollBox = categoriesFrame.ScrollBox
    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dataProvider then return nil, nil end

    local categoryNameLower = slower(categoryName)
    local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
    if not finder then return nil, nil end

    local elementData = finder(dataProvider, function(data)
        if not data then return false end
        -- Element data has an `id` field that is a numeric category ID (or "summary")
        local catID = data.id
        if not catID or type(catID) ~= "number" then return false end
        if GetCategoryInfo then
            local title = GetCategoryInfo(catID)
            if title and slower(title) == categoryNameLower then return true end
        end
        return false
    end)

    return elementData, scrollBox
end

-- Shared helper: find a visible category button by name in the ScrollBox.
-- Uses GetElementData().id → GetCategoryInfo() for reliable matching
-- (AchievementCategoryTemplate stores text on btn.Button, not btn itself).
-- Returns the button frame or nil.
function Highlight:FindVisibleCategoryButton(categoryName)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if not categoriesFrame or not categoriesFrame.ScrollBox then return nil end

    local scrollBox = categoriesFrame.ScrollBox
    local categoryNameLower = slower(categoryName)

    -- Primary: FindFrameByPredicate (cleanest ScrollBox API)
    if scrollBox.FindFrameByPredicate then
        local frame = scrollBox:FindFrameByPredicate(function(frame, elementData)
            if not elementData or not elementData.id or type(elementData.id) ~= "number" then return false end
            if GetCategoryInfo then
                local title = GetCategoryInfo(elementData.id)
                if title and slower(title) == categoryNameLower then return true end
            end
            return false
        end)
        if frame then return frame end
    end

    -- Fallback: EnumerateFrames with GetElementData
    if scrollBox.EnumerateFrames then
        for _, btn in scrollBox:EnumerateFrames() do
            if btn and btn:IsShown() and btn.GetElementData then
                local data = btn:GetElementData()
                if data and data.id and type(data.id) == "number" and GetCategoryInfo then
                    local title = GetCategoryInfo(data.id)
                    if title and slower(title) == categoryNameLower then
                        return btn
                    end
                end
            end
        end
    end

    return nil
end

-- Shared helper: check if a category is currently selected.
-- Uses elementData.selected (set by Blizzard's selection system).
function Highlight:IsCategorySelectedByData(categoryName)
    -- Primary: check the data provider for elementData.selected
    local elementData = self:FindCategoryElementData(categoryName)
    if elementData and elementData.selected then
        return true
    end

    -- Fallback: find visible button and check its elementData directly
    local btn = self:FindVisibleCategoryButton(categoryName)
    if btn and btn.GetElementData then
        local btnData = btn:GetElementData()
        if btnData and btnData.selected then return true end
    end

    return false
end

-- Shared helper: check if a category is expanded (its children visible) OR selected.
-- Used for prerequisite validation — a parent category doesn't need to be "selected"
-- once its child is selected; it only needs to still be expanded.
function Highlight:IsCategoryExpandedOrSelected(categoryName)
    local elementData = self:FindCategoryElementData(categoryName)
    if not elementData then return false end

    -- If it's directly selected, obviously satisfied
    if elementData.selected then return true end

    -- If it's a parent (has children) and is expanded (not collapsed), it's satisfied
    -- This covers the case where a child category is selected — the parent is no longer
    -- "selected" but it IS expanded, meaning the prerequisite is still met.
    if elementData.parent == true and not elementData.collapsed then
        return true
    end

    return false
end

-- Shared helper: scroll to a category and return the button frame.
-- Expands parent categories if needed via AchievementFrameCategories_ExpandToCategory.
function Highlight:ScrollToCategoryButton(categoryName)
    local elementData, scrollBox = self:FindCategoryElementData(categoryName)
    if not elementData or not scrollBox then return nil end

    -- If the category is hidden (parent collapsed), try to expand to it
    if elementData.hidden then
        local catID = elementData.id
        if catID and type(catID) == "number" and AchievementFrameCategories_ExpandToCategory then
            AchievementFrameCategories_ExpandToCategory(catID)
            -- Data provider may have changed, re-find
            if AchievementFrameCategories_UpdateDataProvider then
                AchievementFrameCategories_UpdateDataProvider()
            end
            elementData, scrollBox = self:FindCategoryElementData(categoryName)
            if not elementData or not scrollBox then return nil end
        end
    end

    -- Scroll to center the category in view
    local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
    if scrollBox.ScrollToElementData then
        scrollBox:ScrollToElementData(elementData, alignCenter)
    end

    -- Now find the visible button after scrolling
    return self:FindVisibleCategoryButton(categoryName)
end

-- =====================
-- STATISTICS CATEGORY
-- =====================

function Highlight:IsStatisticsCategorySelected(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return false
    end

    -- Primary: check elementData.selected via data provider
    if self:IsCategorySelectedByData(categoryName) then
        return true
    end

    -- For parent categories, check if child categories are now visible (parent expanded)
    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.statisticsCategory then
            local nextBtn = self:FindVisibleCategoryButton(nextStep.statisticsCategory)
            if nextBtn then
                return true
            end
        end
    end

    return false
end

function Highlight:GetStatisticsCategoryButton(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return nil
    end

    -- First: check currently visible buttons (fast, no scrolling)
    local visibleBtn = self:FindVisibleCategoryButton(categoryName)
    if visibleBtn then return visibleBtn end

    -- Not visible: scroll to it via data provider
    return self:ScrollToCategoryButton(categoryName)
end

-- =====================
-- ACHIEVEMENT/GUILD CATEGORY
-- =====================

function Highlight:IsAchievementCategorySelected(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end

    -- Primary: check elementData.selected via data provider
    if self:IsCategorySelectedByData(categoryName) then
        return true
    end

    -- For parent categories, check if child categories are now visible (parent expanded)
    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.achievementCategory then
            local nextBtn = self:FindVisibleCategoryButton(nextStep.achievementCategory)
            if nextBtn then
                return true
            end
        end
    end

    return false
end

function Highlight:GetAchievementCategoryButton(categoryName, noScroll)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end

    -- First: check currently visible buttons (fast, no scrolling)
    local visibleBtn = self:FindVisibleCategoryButton(categoryName)
    if visibleBtn then return visibleBtn end

    -- Not visible: scroll to it (unless noScroll requested by selection checks)
    if noScroll then return nil end
    return self:ScrollToCategoryButton(categoryName)
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
        local child = select(sidebarIndex, sidebarTabs:GetChildren())
        if child and child:IsShown() then
            return child
        end
    end
    
    return nil
end

function Highlight:FindRatedPvPButton(buttonText)
    -- Search the ACTIVE sub-panel for a button with matching text (Solo Shuffle, 2v2, Arenas, etc.)
    if not PVEFrame or not PVEFrame:IsShown() then
        return nil
    end
    
    local searchText = slower(buttonText)
    
    -- Determine the active sub-panel and search only within it.
    -- This prevents finding buttons on inactive sub-tabs (e.g. finding
    -- "Random Battlegrounds" on Quick Match when looking for "Arena Skirmishes"
    -- on Premade Groups).
    local searchRoots = {}
    
    -- PvP sub-panels
    if HonorFrame and HonorFrame:IsShown() then
        searchRoots[#searchRoots + 1] = HonorFrame
    end
    if ConquestFrame and ConquestFrame:IsShown() then
        searchRoots[#searchRoots + 1] = ConquestFrame
    end
    if LFGListPVPStub and LFGListPVPStub:IsShown() then
        searchRoots[#searchRoots + 1] = LFGListPVPStub
    end
    if TrainingGroundsFrame and TrainingGroundsFrame:IsShown() then
        searchRoots[#searchRoots + 1] = TrainingGroundsFrame
    end
    
    -- PvE sub-panels
    if LFDParentFrame and LFDParentFrame:IsShown() then
        searchRoots[#searchRoots + 1] = LFDParentFrame
    end
    if RaidFinderFrame and RaidFinderFrame:IsShown() then
        searchRoots[#searchRoots + 1] = RaidFinderFrame
    end
    if LFGListPVEStub and LFGListPVEStub:IsShown() then
        searchRoots[#searchRoots + 1] = LFGListPVEStub
    end
    
    -- LFGListFrame is shared between PvE and PvP premade groups
    if LFGListFrame and LFGListFrame:IsShown() then
        searchRoots[#searchRoots + 1] = LFGListFrame
    end
    
    -- Search each active sub-panel
    for _, root in ipairs(searchRoots) do
        local result = SearchFrameTreeFuzzy(root, searchText)
        if result then return result end
    end
    
    -- Fallback: search entire PVEFrame (for edge cases like Mythic+ or unknown layouts)
    return SearchFrameTreeFuzzy(PVEFrame, searchText)
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
                local count = 0
                for i = 1, select("#", frame.TabSystem:GetChildren()) do
                    local child = select(i, frame.TabSystem:GetChildren())
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
                for i = 1, select("#", container:GetChildren()) do
                    local child = select(i, container:GetChildren())
                    local name = child:GetName() or ""
                    for _, keyword in ipairs(keywords) do
                        if sfind(name, keyword) then
                            return child
                        end
                    end
                    -- Also check child text if it's a button
                    if child.GetText then
                        local text = child:GetText() or ""
                        for _, keyword in ipairs(keywords) do
                            if sfind(text, keyword) then
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
                    for i = 1, select("#", container:GetChildren()) do
                        local child = select(i, container:GetChildren())
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
    
    -- Top and bottom own the corners (full width including padding)
    highlightFrame.top:ClearAllPoints()
    highlightFrame.top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -pad, 0)
    highlightFrame.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", pad, 0)
    highlightFrame.top:SetHeight(bs)

    highlightFrame.bottom:ClearAllPoints()
    highlightFrame.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -pad, 0)
    highlightFrame.bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", pad, 0)
    highlightFrame.bottom:SetHeight(bs)

    -- Left and right fit between top and bottom (no corner overlap)
    highlightFrame.left:ClearAllPoints()
    highlightFrame.left:SetPoint("TOPLEFT", highlightFrame.top, "BOTTOMLEFT", 0, 0)
    highlightFrame.left:SetPoint("BOTTOMLEFT", highlightFrame.bottom, "TOPLEFT", 0, 0)
    highlightFrame.left:SetWidth(bs)

    highlightFrame.right:ClearAllPoints()
    highlightFrame.right:SetPoint("TOPRIGHT", highlightFrame.top, "BOTTOMRIGHT", 0, 0)
    highlightFrame.right:SetPoint("BOTTOMRIGHT", highlightFrame.bottom, "TOPRIGHT", 0, 0)
    highlightFrame.right:SetWidth(bs)
    
    highlightFrame:Show()
    if highlightFrame.animGroup and not highlightFrame.animGroup:IsPlaying() then
        highlightFrame.animGroup:Play()
    end
    
    indicatorFrame:ClearAllPoints()
    indicatorFrame:SetPoint("BOTTOM", frame, "TOP", 0, 10)
    indicatorFrame:Show()
    if indicatorFrame.animGroup and not indicatorFrame.animGroup:IsPlaying() then
        indicatorFrame.animGroup:Play()
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
    local frameHeight = mmax(90, textHeight + 60)  -- 60px for padding and button
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
    if indicatorFrame then
        indicatorFrame:Hide()
        if indicatorFrame.animGroup then indicatorFrame.animGroup:Stop() end
    end
    if instructionFrame then
        instructionFrame:Hide()
    end
    if contextTooltip then
        contextTooltip:Hide()
    end
end

function Highlight:ClearAll()
    self:HideHighlight()
    currentGuide = nil
    currentStepIndex = nil
    if stepTicker then stepTicker:Cancel(); stepTicker = nil end
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
    local optionNameLower = slower(optionName)
    
    local function getFrameText(frame)
        if not frame then return nil end
        if frame.GetText then
            local ok, t = pcall(frame.GetText, frame)
            if ok and t then return t end
        end
        local regOk, nRegions = pcall(function() return select("#", frame:GetRegions()) end)
        if regOk and nRegions then
            for j = 1, nRegions do
                local region = select(j, frame:GetRegions())
                if region and region.GetText then
                    local ok2, t2 = pcall(region.GetText, region)
                    if ok2 and t2 then return t2 end
                end
            end
        end
        return nil
    end
    
    local function searchFrame(frame, depth)
        if not frame or depth > 8 then return nil end
        
        local childOk, nChildren = pcall(function() return select("#", frame:GetChildren()) end)
        if not childOk or not nChildren then return nil end
        for i = 1, nChildren do
            local child = select(i, frame:GetChildren())
            local shownOk, shown = pcall(child.IsShown, child)
            if shownOk and shown then
                local text = getFrameText(child)
                if text and sfind(slower(text), optionNameLower, 1, true) then
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

-- =============================================================================
-- Currency navigation helpers
-- =============================================================================

-- Check if a currency header is currently expanded
-- Returns: true (expanded), false (collapsed), nil (not in list — parent collapsed)
function Highlight:IsCurrencyHeaderExpanded(headerName)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return nil end
    
    local headerNameLower = slower(headerName)
    local size = C_CurrencyInfo.GetCurrencyListSize()
    
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
            return info.isHeaderExpanded
        end
    end
    return nil -- header not visible, parent must be collapsed
end

-- Find the visible UI button for a currency header in the TokenFrame ScrollBox
function Highlight:GetCurrencyHeaderButton(headerName)
    if not TokenFrame or not TokenFrame:IsShown() then return nil end
    
    local headerNameLower = slower(headerName)
    
    if TokenFrame.ScrollBox then
        -- First try to scroll to the header's data element so it becomes visible
        if TokenFrame.ScrollBox.GetDataProvider then
            local dataProvider = TokenFrame.ScrollBox:GetDataProvider()
            if dataProvider then
                -- Find the header's flat-list index in C_CurrencyInfo
                local headerIndex = nil
                if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
                    local size = C_CurrencyInfo.GetCurrencyListSize()
                    for i = 1, size do
                        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
                        if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
                            headerIndex = i
                            break
                        end
                    end
                end
                if headerIndex then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.currencyIndex == headerIndex
                    end)
                    if scrollData then
                        TokenFrame.ScrollBox:ScrollToElementData(scrollData)
                    end
                end
            end
        end
        
        -- Find the header's currencyIndex first
        local targetIndex = nil
        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
            local size = C_CurrencyInfo.GetCurrencyListSize()
            for i = 1, size do
                local info = C_CurrencyInfo.GetCurrencyListInfo(i)
                if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
                    targetIndex = i
                    break
                end
            end
        end

        -- Now enumerate visible frames to find the button by currencyIndex
        if targetIndex and TokenFrame.ScrollBox.EnumerateFrames then
            for _, btn in TokenFrame.ScrollBox:EnumerateFrames() do
                if btn and btn:IsShown() then
                    -- Check elementData.currencyIndex
                    local elementData = btn.elementData or (btn.GetElementData and btn:GetElementData())
                    if elementData and elementData.currencyIndex == targetIndex then
                        return btn
                    end
                    -- Fallback: try text matching
                    local text = GetButtonText(btn)
                    if text and slower(text) == headerNameLower then
                        return btn
                    end
                end
            end
        end
    end

    return nil
end

-- Scroll the TokenFrame ScrollBox to show a specific currency by ID
function Highlight:ScrollToCurrencyRow(currencyID)
    if not TokenFrame or not TokenFrame:IsShown() then return end
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return end
    
    -- Find the flat-list index for this currencyID
    local size = C_CurrencyInfo.GetCurrencyListSize()
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            -- Found — scroll to it via the ScrollBox data provider
            if TokenFrame.ScrollBox then
                local dataProvider = TokenFrame.ScrollBox:GetDataProvider()
                if dataProvider then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.currencyIndex == i
                    end)
                    if scrollData then
                        TokenFrame.ScrollBox:ScrollToElementData(scrollData)
                    end
                end
            end
            return
        end
    end
end

-- Find the visible UI button/row for a specific currency by ID in the TokenFrame ScrollBox
function Highlight:GetCurrencyRowButton(currencyID)
    if not TokenFrame or not TokenFrame:IsShown() then return nil end
    
    -- Modern ScrollBox: enumerate visible frames and match by data
    if TokenFrame.ScrollBox and TokenFrame.ScrollBox.EnumerateFrames then
        for _, btn in TokenFrame.ScrollBox:EnumerateFrames() do
            if btn and btn:IsShown() then
                -- Check if the button's element data contains our currencyID
                local data = btn.GetElementData and btn:GetElementData()
                if data then
                    -- Direct currencyID match on data
                    if data.currencyID == currencyID then
                        return btn
                    end
                    -- May be stored as a currencyIndex — resolve it
                    if data.currencyIndex then
                        local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo(data.currencyIndex)
                        if info and not info.isHeader and info.currencyID == currencyID then
                            return btn
                        end
                    end
                end
                
                -- Fallback: match by currency name text
                local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(currencyID)
                if currencyInfo and currencyInfo.name then
                    local text = GetButtonText(btn)
                    if text and slower(text) == slower(currencyInfo.name) then
                        return btn
                    end
                end
            end
        end
    end
    
    return nil
end

-- =============================================================================
-- REPUTATION HELPERS
-- =============================================================================

--- Check if a faction header is expanded
--- Returns: true (expanded), false (collapsed), nil (not found/parent collapsed)
function Highlight:IsFactionHeaderExpanded(headerName)
    if not C_Reputation or not C_Reputation.GetNumFactions then return nil end

    local headerNameLower = slower(headerName)
    local numFactions = C_Reputation.GetNumFactions()

    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
            -- Check both new and old property names for compatibility
            if factionData.isHeaderExpanded ~= nil then
                return factionData.isHeaderExpanded
            elseif factionData.isCollapsed ~= nil then
                return not factionData.isCollapsed  -- isCollapsed is inverse of isHeaderExpanded
            end
            -- Fallback: assume expanded if we can see it
            return true
        end
    end
    return nil -- header not visible, parent must be collapsed
end

--- Find the visible UI button for a faction header in the ReputationFrame ScrollBox
function Highlight:GetFactionHeaderButton(headerName)
    if not ReputationFrame or not ReputationFrame:IsShown() then return nil end

    local headerNameLower = slower(headerName)

    -- Modern retail: ReputationFrame.ScrollBox
    if ReputationFrame.ScrollBox then
        -- First try to scroll to the header's data element so it becomes visible
        if ReputationFrame.ScrollBox.GetDataProvider then
            local dataProvider = ReputationFrame.ScrollBox:GetDataProvider()
            if dataProvider then
                -- Find the header's flat-list index in C_Reputation
                local headerIndex = nil
                if C_Reputation and C_Reputation.GetNumFactions then
                    local numFactions = C_Reputation.GetNumFactions()
                    for i = 1, numFactions do
                        local factionData = C_Reputation.GetFactionDataByIndex(i)
                        if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
                            headerIndex = i
                            break
                        end
                    end
                end
                if headerIndex then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.factionIndex == headerIndex
                    end)
                    if scrollData then
                        ReputationFrame.ScrollBox:ScrollToElementData(scrollData)
                    end
                end
            end
        end

        -- Find the header's factionIndex first
        local targetIndex = nil
        if C_Reputation and C_Reputation.GetNumFactions then
            local numFactions = C_Reputation.GetNumFactions()
            for i = 1, numFactions do
                local factionData = C_Reputation.GetFactionDataByIndex(i)
                if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
                    targetIndex = i
                    break
                end
            end
        end

        -- Now enumerate visible frames to find the button by factionIndex
        if targetIndex and ReputationFrame.ScrollBox.EnumerateFrames then
            for _, btn in ReputationFrame.ScrollBox:EnumerateFrames() do
                if btn and btn:IsShown() then
                    -- Check elementData.factionIndex
                    local elementData = btn.elementData or (btn.GetElementData and btn:GetElementData())
                    if elementData and elementData.factionIndex == targetIndex then
                        return btn
                    end
                    -- Fallback: try text matching
                    local text = GetButtonText(btn)
                    if text and slower(text) == headerNameLower then
                        return btn
                    end
                end
            end
        end
    end

    return nil
end

--- Scroll the ReputationFrame ScrollBox to show a specific faction by ID
function Highlight:ScrollToFactionRow(factionID)
    if not ReputationFrame or not ReputationFrame:IsShown() then return end
    if not C_Reputation or not C_Reputation.GetNumFactions then return end

    -- Find the flat-list index for this factionID
    local numFactions = C_Reputation.GetNumFactions()
    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and not factionData.isHeader and factionData.factionID == factionID then
            -- Found — scroll to it via the ScrollBox data provider
            if ReputationFrame.ScrollBox then
                local dataProvider = ReputationFrame.ScrollBox:GetDataProvider()
                if dataProvider then
                    local scrollData = dataProvider:FindByPredicate(function(data)
                        return data and data.factionIndex == i
                    end)
                    if scrollData then
                        ReputationFrame.ScrollBox:ScrollToElementData(scrollData)
                    end
                end
            end
            return
        end
    end
end

--- Find the visible UI button/row for a specific faction by ID in the ReputationFrame ScrollBox
function Highlight:GetFactionRowButton(factionID)
    if not ReputationFrame or not ReputationFrame:IsShown() then return nil end

    -- Modern ScrollBox: enumerate visible frames and match by data
    if ReputationFrame.ScrollBox and ReputationFrame.ScrollBox.EnumerateFrames then
        for _, btn in ReputationFrame.ScrollBox:EnumerateFrames() do
            if btn and btn:IsShown() then
                -- Check if the button's element data contains our factionID
                local data = btn.GetElementData and btn:GetElementData()
                if data then
                    -- Direct factionID match on data
                    if data.factionID == factionID then
                        return btn
                    end
                    -- May be stored as a factionIndex — resolve it
                    if data.factionIndex then
                        local factionData = C_Reputation and C_Reputation.GetFactionDataByIndex(data.factionIndex)
                        if factionData and not factionData.isHeader and factionData.factionID == factionID then
                            return btn
                        end
                    end
                end

                -- Fallback: match by faction name text
                local numFactions = C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetNumFactions()
                if numFactions then
                    for i = 1, numFactions do
                        local factionData = C_Reputation.GetFactionDataByIndex(i)
                        if factionData and factionData.factionID == factionID and factionData.name then
                            local text = GetButtonText(btn)
                            if text and slower(text) == slower(factionData.name) then
                                return btn
                            end
                            break
                        end
                    end
                end
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
end
