local _, ns = ...

local Highlight = {}
ns.Highlight = Highlight

local Utils = ns.Utils
local ResultHandlers = ns.ResultHandlers
local GetButtonText        = Utils.GetButtonText
local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
local ScrollBoxScrollTo    = Utils.ScrollBoxScrollTo
local ScrollBoxFindButton  = Utils.ScrollBoxFindButton
local select, ipairs       = Utils.select, Utils.ipairs
local sfind, slower        = Utils.sfind, Utils.slower
local mmax, mpi            = Utils.mmax, Utils.mpi
local pcall = Utils.pcall
local xpcall = Utils.xpcall
local ErrorHandler = Utils.ErrorHandler

local GOLD_COLOR         = ns.GOLD_COLOR
local YELLOW_HIGHLIGHT   = ns.YELLOW_HIGHLIGHT
local TOOLTIP_BORDER     = ns.TOOLTIP_BORDER

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local C_Reputation       = C_Reputation
local C_CurrencyInfo     = C_CurrencyInfo
local GetCurrentEncounter = C_EncounterJournal and C_EncounterJournal.GetCurrentEncounter
local EJ_GetCurrentEncounter = _G["EJ_GetCurrentEncounter"]
local GetTime            = GetTime
local UIParent           = UIParent

local HOVER_MIN_DISPLAY  = 0.3

local highlightFrame
local indicatorFrame
local instructionFrame
local contextTooltip
local scrollHintFrame
local currentGuide
local currentStepIndex
local stepTicker
local highlightShownAt
local RepairAchievementCategoryGuideSteps
local InsertMissingAchievementCategoryParentStep

-- Hover-to-dismiss fires only on the final step (or a single-highlight
-- with no guide). Intermediate steps must persist or hover would
-- short-circuit the breadcrumb.
local function canHoverDismiss()
    if currentGuide and currentGuide.steps then
        local total = #currentGuide.steps
        if currentStepIndex and currentStepIndex < total then return false end
    end
    return not highlightShownAt or (GetTime() - highlightShownAt) >= HOVER_MIN_DISPLAY
end

local function isTerminalHighlight()
    if not currentGuide or not currentGuide.steps then return true end
    return currentStepIndex and currentStepIndex >= #currentGuide.steps
end

local function clearTerminalHighlight()
    -- Cancel (not HideHighlight) so a guide ticker can't recreate the
    -- final highlight after hover / scroll / panel close.
    Highlight:Cancel()
end

local function TalentButtonNameLower(btn)
    if not btn or not btn.GetName then return nil end
    local n = btn:GetName()
    return n and n:lower() or nil
end

-- Choice-node options nest one level below ButtonsParent's
-- direct children, so a fixed 2-level walk misses them.
local function SearchTalentTree(frame, depth, targetLower)
    if not frame or depth > 5 then return nil end
    if frame.SearchIcon and TalentButtonNameLower(frame) == targetLower then
        return frame
    end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            local found = SearchTalentTree(select(i, frame:GetChildren()), depth + 1, targetLower)
            if found then return found end
        end
    end
    return nil
end

local function GetContainerButtonLocation(button)
    if not button then return nil end

    local bag, slot
    if button.GetBagID then
        local ok, value = pcall(button.GetBagID, button)
        if ok then bag = value end
    end
    if button.GetID then
        local ok, value = pcall(button.GetID, button)
        if ok then slot = value end
    end
    if button.GetItemLocation then
        local ok, itemLocation = pcall(button.GetItemLocation, button)
        if ok and itemLocation and itemLocation.GetBagAndSlot then
            local okLoc, locBag, locSlot = pcall(itemLocation.GetBagAndSlot, itemLocation)
            if okLoc then
                bag = bag or locBag
                slot = slot or locSlot
            end
        end
    end
    if bag == nil and button.GetParent then
        local parent = button:GetParent()
        if parent and parent.GetID then
            local ok, value = pcall(parent.GetID, parent)
            if ok then bag = value end
        end
    end

    return bag, slot
end

local function IsContainerButtonLocation(button, bag, slot)
    local buttonBag, buttonSlot = GetContainerButtonLocation(button)
    return buttonBag == bag and buttonSlot == slot
end

function Highlight:FindContainerSlotButtonInFrame(frame, bag, slot)
    if not frame or not frame:IsVisible() then return nil end

    if frame.EnumerateValidItems then
        for _, itemButton in frame:EnumerateValidItems() do
            if itemButton and itemButton:IsVisible()
               and IsContainerButtonLocation(itemButton, bag, slot) then
                return itemButton
            end
        end
    end

    local frameName = frame.GetName and frame:GetName()
    if frameName then
        for i = 1, 200 do
            local itemButton = _G[frameName .. "Item" .. i]
            if itemButton and itemButton:IsVisible()
               and IsContainerButtonLocation(itemButton, bag, slot) then
                return itemButton
            end
        end
    end

    return nil
end

function Highlight:FindContainerSlotButton(bag, slot)
    local button = self:FindContainerSlotButtonInFrame(_G.ContainerFrameCombinedBags, bag, slot)
    if button then return button end

    for i = 1, 13 do
        button = self:FindContainerSlotButtonInFrame(_G["ContainerFrame" .. i], bag, slot)
        if button then return button end
    end

    -- Old container buttons are indexed in reverse slot order.
    local CONT = C_Container
    local getSlots = (CONT and CONT.GetContainerNumSlots) or GetContainerNumSlots
    for i = 1, 13 do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsVisible() and frame:GetID() == bag then
            local ok, n = true, nil
            if getSlots then ok, n = pcall(getSlots, bag) end
            local numSlots = (ok and n) or 0
            if numSlots == 0 then
                for c = 1, 40 do
                    if not _G["ContainerFrame" .. i .. "Item" .. c] then
                        numSlots = c - 1
                        break
                    end
                end
            end
            local btnIdx = numSlots - slot + 1
            return btnIdx >= 1 and _G["ContainerFrame" .. i .. "Item" .. btnIdx] or nil
        end
    end

    return nil
end

function Highlight:HighlightContainerSlotStep(step)
    local locations = step.allLocations or {{ bag = step.containerBag, slot = step.containerSlot }}

    local found = false
    for _, loc in ipairs(locations) do
        local itemBtn = self:FindContainerSlotButton(loc.bag, loc.slot)
        if itemBtn and itemBtn:IsVisible() then
            if not found then
                local bag, slot = loc.bag, loc.slot
                step._efContainerSlotFound = true
                self:HighlightFrame(itemBtn, nil, function(frame)
                    return frame and frame:IsVisible()
                        and IsContainerButtonLocation(frame, bag, slot)
                end)
                if canHoverDismiss() and itemBtn:IsMouseOver() then
                    self:Cancel()
                    return
                end
                found = true
            else
                local name = itemBtn:GetName()
                local glow = name and _G[name .. "SearchOverlay"]
                if glow then
                    glow:SetVertexColor(1, 1, 0, 0.5)
                    glow:Show()
                end
            end
        end
    end

    if not found then
        if step._efContainerSlotFound then
            self:Cancel()
            return
        end
        self:HideHighlight()
    end
end

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

    local top = highlightFrame:CreateTexture(nil, "OVERLAY")
    top:SetColorTexture(Utils.RGB(YELLOW_HIGHLIGHT, 1))
    highlightFrame.top = top

    local bottom = highlightFrame:CreateTexture(nil, "OVERLAY")
    bottom:SetColorTexture(Utils.RGB(YELLOW_HIGHLIGHT, 1))
    highlightFrame.bottom = bottom

    local left = highlightFrame:CreateTexture(nil, "OVERLAY")
    left:SetColorTexture(Utils.RGB(YELLOW_HIGHLIGHT, 1))
    highlightFrame.left = left

    local right = highlightFrame:CreateTexture(nil, "OVERLAY")
    right:SetColorTexture(Utils.RGB(YELLOW_HIGHLIGHT, 1))
    highlightFrame.right = right

    highlightFrame.borderSize = borderSize

    highlightFrame.animGroup = ns.CreateBouncePulse(highlightFrame, 1, 0.3, 0.5)

    -- Throttled visibility + identity watcher. IsVisible (unlike IsShown)
    -- reflects parent-chain visibility, so cascade-hides trigger a clear.
    -- _targetValidator catches when the target is still visible but no
    -- longer represents the original (ScrollBox button repurposed for a
    -- different spell, etc.). Clears only on terminal highlights so the
    -- per-step UpdateGuide owns intermediate breadcrumb behavior.
    local watchAccum = 0
    highlightFrame:HookScript("OnUpdate", function(self, elapsed)
        watchAccum = watchAccum + elapsed
        if watchAccum < 0.1 then return end
        watchAccum = 0
        local hoverFrame = self._hoverDismissFrame
        if hoverFrame and canHoverDismiss()
           and hoverFrame.IsMouseOver and hoverFrame:IsMouseOver() then
            clearTerminalHighlight()
            return
        end
        local target = self._targetFrame
        local terminal = isTerminalHighlight()
        if terminal and self._clearWhenTargetHidden and target
           and target.IsVisible and not target:IsVisible() then
            clearTerminalHighlight()
            return
        end
        local validator = self._targetValidator
        if validator and not validator(target) then
            if terminal then
                clearTerminalHighlight()
            else
                Highlight:HideHighlight()
            end
            return
        end
    end)
end

function Highlight:CreateIndicatorFrame()
    indicatorFrame = CreateFrame("Frame", "EasyFindIndicatorFrame", UIParent)
    local aSize = ns.ICON_SIZE or 48
    indicatorFrame:SetSize(aSize, aSize)
    indicatorFrame:SetFrameStrata("TOOLTIP")
    indicatorFrame:SetFrameLevel(501)
    indicatorFrame.isUIIndicator = true
    indicatorFrame:Hide()

    if ns.CreateIndicatorTextures then
        ns.CreateIndicatorTextures(indicatorFrame, ns.ICON_SIZE, ns.ICON_GLOW_SIZE)
    else
        local ind = indicatorFrame:CreateTexture(nil, "ARTWORK")
        ind:SetSize(80, 80)
        ind:SetPoint("CENTER")
        ind:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
        ind:SetRotation(mpi)
        indicatorFrame.indicator = ind
    end

    indicatorFrame.animGroup = ns.CreateBounceFloat(indicatorFrame, 0, -10, 0.4)
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
    instructionFrame:SetBackdropColor(0, 0, 0, 0.95)

    local text = instructionFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("TOPLEFT", 15, -15)
    text:SetPoint("TOPRIGHT", -15, -15)
    text:SetTextColor(Utils.RGB(YELLOW_HIGHLIGHT))
    text:SetJustifyH("CENTER")
    text:SetWordWrap(true)
    text:SetNonSpaceWrap(true)
    instructionFrame.text = text

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
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    contextTooltip:SetBackdropColor(0, 0, 0, 0.9)
    contextTooltip:SetBackdropBorderColor(Utils.RGB(GOLD_COLOR, 1))

    local text = contextTooltip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, 0)
    text:SetTextColor(Utils.RGB(YELLOW_HIGHLIGHT))
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
            Utils.SafeAfter(5, function() self:Cancel() end)
        end
        return
    end

    if RepairAchievementCategoryGuideSteps then
        RepairAchievementCategoryGuideSteps(guideData)
    end

    -- Currency guides cancel on close instead of rewinding to step 1 --
    -- player closing the window is "abandon", not "go back to the start".
    if not guideData.noCourseCorrect then
        for _, s in ipairs(guideData.steps) do
            if s.currencyHeader or s.currencyID then
                guideData.noCourseCorrect = true
                break
            end
        end
    end

    currentGuide = guideData
    currentStepIndex = 1

    self:FastForwardSteps()
    if not currentGuide then return end

    stepTicker = C_Timer.NewTicker(0.1, function()
        local ok, err = xpcall(self.UpdateGuide, ErrorHandler, self)
        if not ok then
            if stepTicker then stepTicker:Cancel(); stepTicker = nil end
            Utils.DebugPrint("Guide error: " .. tostring(err))
        end
    end)

    self:NotifyClearButton()
end

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

    self:FastForwardSteps()
    if not currentGuide then return end

    stepTicker = C_Timer.NewTicker(0.1, function()
        local ok, err = xpcall(self.UpdateGuide, ErrorHandler, self)
        if not ok then
            if stepTicker then stepTicker:Cancel(); stepTicker = nil end
            Utils.DebugPrint("Guide error: " .. tostring(err))
        end
    end)

    self:NotifyClearButton()
end

function Highlight:FastForwardSteps()
    local prevIdx
    repeat
        prevIdx = currentStepIndex
        local ok, err = xpcall(self.UpdateGuide, ErrorHandler, self)
        if not ok then
            Utils.DebugPrint("Guide error: " .. tostring(err))
            self:Cancel()
            return
        end
    until not currentGuide or currentStepIndex == prevIdx
end

local function FindPreviousStepIndex(predicate)
    for i = currentStepIndex - 1, 1, -1 do
        local step = currentGuide.steps[i]
        if step and predicate(step) then return i, step end
    end
end

local function FindRequiredTabIndex()
    local _, step = FindPreviousStepIndex(function(prevStep)
        return prevStep.tabIndex ~= nil
    end)
    return step and step.tabIndex
end

local function RewindToPreviousStep(self, predicate)
    local index = FindPreviousStepIndex(predicate)
    if index then
        currentStepIndex = index
        self:HideHighlight()
        return true
    end
    return false
end

local function RewindToTabStep(self, tabIndex, searchFromStart)
    if searchFromStart then
        for i, step in ipairs(currentGuide.steps) do
            if step.tabIndex == tabIndex then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end
        return false
    end
    return RewindToPreviousStep(self, function(prevStep)
        return prevStep.tabIndex == tabIndex
    end)
end

local function EnforceRequiredTab(self, frameName, tabIndex, searchFromStart)
    if not tabIndex then return false end
    local currentTab = self:GetCurrentTabIndex(frameName)
    if currentTab and currentTab ~= tabIndex then
        return RewindToTabStep(self, tabIndex, searchFromStart)
    end
    return false
end

local function EnforceAchievementTab(self, tabIndex)
    if not tabIndex then return false end
    local currentTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame)
    if currentTab and currentTab ~= tabIndex then
        return RewindToTabStep(self, tabIndex, true)
    end
    return false
end

local function RewindIfPriorCategoryCollapsed(self, categoryKey, categoryIDKey)
    return RewindToPreviousStep(self, function(prevStep)
        local category = prevStep[categoryKey]
        return category
            and not self:IsCategoryExpandedOrSelected(category, prevStep[categoryIDKey])
    end)
end

local function ValidateDestinationPrereqs(self)
    for i = currentStepIndex - 1, 1, -1 do
        local prev = currentGuide.steps[i]
        if not prev then break end

        if prev.tabIndex and prev.waitForFrame then
            local currentTab = self:GetCurrentTabIndex(prev.waitForFrame)
            if currentTab and currentTab ~= prev.tabIndex then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end

        if prev.pvpSideTabIndex and prev.waitForFrame then
            if not self:IsPvPSideTabSelected(prev.waitForFrame, prev.pvpSideTabIndex) then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end

        if prev.sideTabIndex and prev.waitForFrame then
            if not self:IsSideTabSelected(prev.waitForFrame, prev.sideTabIndex) then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end

        if prev.sidebarIndex then
            if not self:IsSidebarTabSelected(prev.sidebarIndex) then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end

        if prev.ejTier then
            local liveTier = EJ_GetCurrentTier and EJ_GetCurrentTier()
            if liveTier and liveTier ~= prev.ejTier then
                currentStepIndex = i
                prev._tierApplied = nil
                self:HideHighlight()
                return true
            end
        end

        if prev.ejEncounterID then
            local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
            local ej = _G["EncounterJournal"]
            local currentEnc = (infoFrame and infoFrame.encounterID)
                or (ej and ej.encounterID)
            if not currentEnc then
                local getEnc = GetCurrentEncounter or EJ_GetCurrentEncounter
                if getEnc then currentEnc = getEnc() end
            end
            if currentEnc and currentEnc ~= prev.ejEncounterID then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end

        if prev.ejLootTab then
            local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
            local lootContainer = infoFrame and infoFrame.LootContainer
            if lootContainer and not lootContainer:IsShown() then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end
    end
    return false
end

local function HandleGuideCustomText(self, step)
    self:ShowInstruction(step.customText)
    Utils.SafeAfter(5, function() self:Cancel() end)
    return true
end

local function HandleGuideButtonFrame(self, step)
    local targetFrame = Utils.GetFrameByPath(step.buttonFrame) or _G[step.buttonFrame]
    if targetFrame and targetFrame:IsShown() then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.waitForFrame then
            local waitFrame = self:GetFrameByPath(nextStep.waitForFrame)
            if waitFrame and waitFrame:IsShown() then
                self:AdvanceStep()
                return true
            end
        elseif not nextStep then
            if canHoverDismiss() and targetFrame:IsMouseOver() then
                self:Cancel()
                return true
            end
        end

        self:HighlightFrame(targetFrame)
    end
    return true
end

local function HandleGuidePortraitMenu(self)
    if self:IsPortraitMenuOpen() then
        self:HideContextTooltip()
        self:AdvanceStep()
        return true
    end

    local portrait = PlayerFrame
    if portrait and portrait:IsShown() then
        self:HighlightFrame(portrait)
        self:ShowContextTooltip(portrait, "Right-click", "LEFT", "RIGHT", 10, 0)
    end
    return true
end

local function HandleGuideGameMenuText(self, step)
    if not GameMenuFrame or not GameMenuFrame:IsShown() then
        if currentGuide and currentGuide.noCourseCorrect then
            self:Cancel()
        else
            currentStepIndex = 1
            self:HideHighlight()
        end
        return true
    end

    local btn = self:FindGameMenuButton(step.gameMenuText)
    if btn then
        self:HighlightFrame(btn)
        if canHoverDismiss() and btn:IsMouseOver() then
            self:Cancel()
        end
    else
        self:HideHighlight()
        self:ShowInstruction("'" .. step.gameMenuText .. "' is not in the Game Menu")
        Utils.SafeAfter(2.5, function() self:Cancel() end)
    end
    return true
end

local function HandleGuidePortraitMenuOption(self, step)
    if not self:IsPortraitMenuOpen() then
        self:HideContextTooltip()
        if currentGuide and currentGuide.noCourseCorrect then
            self:Cancel()
        else
            currentStepIndex = currentStepIndex - 1
            self:HideHighlight()
        end
        return true
    end

    local optionBtn = self:FindPortraitMenuOption(step.portraitMenuOption)
    if optionBtn then
        self:HighlightFrame(optionBtn)
        if canHoverDismiss() and optionBtn:IsMouseOver() then
            self:Cancel()
        end
    else
        self:HideHighlight()
        self:ShowInstruction("'" .. step.portraitMenuOption .. "' is not available here")
        Utils.SafeAfter(2.5, function() self:Cancel() end)
    end
    return true
end

local function HandleGuideContainerSlot(self, step)
    self:HighlightContainerSlotStep(step)
    return true
end

local GUIDE_STEP_HANDLERS = {
    customText = HandleGuideCustomText,
    buttonFrame = HandleGuideButtonFrame,
    portraitMenu = HandleGuidePortraitMenu,
    gameMenuText = HandleGuideGameMenuText,
    portraitMenuOption = HandleGuidePortraitMenuOption,
}

local GUIDE_STEP_HANDLER_ORDER = {
    "customText",
    "buttonFrame",
    "portraitMenu",
    "gameMenuText",
    "portraitMenuOption",
}

local function HandleStandaloneGuideStep(self, step)
    for _, key in ipairs(GUIDE_STEP_HANDLER_ORDER) do
        if step[key] and GUIDE_STEP_HANDLERS[key](self, step) then
            return true
        end
    end

    if step.containerBag ~= nil and step.containerSlot then
        return HandleGuideContainerSlot(self, step)
    end
    return false
end

local function HandleWaitTabIndex(self, step, isLastStep)
    if self:IsTabSelected(step.waitForFrame, step.tabIndex) then
        self:AdvanceStep()
        return true
    end

    local tabBtn = self:GetTabButton(step.waitForFrame, step.tabIndex)
    if tabBtn then
        self:HighlightFrame(tabBtn)
        local isEnabled = not tabBtn.IsEnabled or tabBtn:IsEnabled()
        if canHoverDismiss() and not isEnabled and tabBtn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or "Click the correct tab")
    end
    return true
end

local function HandleWaitPetJournal(self, step, isLastStep)
    local row = ResultHandlers and ResultHandlers.RevealPetInJournal
        and ResultHandlers:RevealPetInJournal(step)
    if row then
        self:HighlightFrame(row)
        if canHoverDismiss() and row:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or "Find the pet in the Pet Journal")
    end
    return true
end

local function HandleWaitEncounterJournalTier(self, step)
    local tabIdx = step.ejTabIsRaid and 5 or 4
    if not step._tierApplied then
        step._tierApplied = true
        if EJ_SelectTier then EJ_SelectTier(step.ejTier) end
    end
    if self:IsTabSelected("EncounterJournal", tabIdx) then
        local instSelect = _G["EncounterJournalInstanceSelect"]
        if instSelect and instSelect:IsShown() then
            self:AdvanceStep()
            return true
        end
    end
    local tabBtn = self:GetTabButton("EncounterJournal", tabIdx)
    if tabBtn then self:HighlightFrame(tabBtn) end
    return true
end

local function HandleWaitSideTab(self, step, isLastStep)
    if EnforceRequiredTab(self, step.waitForFrame, FindRequiredTabIndex()) then return true end

    if self:IsSideTabSelected(step.waitForFrame, step.sideTabIndex) then
        self:AdvanceStep()
        return true
    end

    local sideBtn = self:GetSideTabButton(step.waitForFrame, step.sideTabIndex)
    if sideBtn and sideBtn:IsShown() then
        self:HighlightFrame(sideBtn)
        local isEnabled = not sideBtn.IsEnabled or sideBtn:IsEnabled()
        if canHoverDismiss() and not isEnabled and sideBtn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or "Click the correct option on the left")
    elseif currentStepIndex > 1 then
        currentStepIndex = currentStepIndex - 1
        self:HideHighlight()
    end
    return true
end

local function HandleWaitPvPSideTab(self, step, isLastStep)
    if EnforceRequiredTab(self, step.waitForFrame, FindRequiredTabIndex()) then return true end

    if self:IsPvPSideTabSelected(step.waitForFrame, step.pvpSideTabIndex) then
        self:AdvanceStep()
        return true
    end

    local pvpBtn = self:GetPvPSideTabButton(step.waitForFrame, step.pvpSideTabIndex)
    if pvpBtn and pvpBtn:IsShown() then
        self:HighlightFrame(pvpBtn)
        local isEnabled = not pvpBtn.IsEnabled or pvpBtn:IsEnabled()
        if canHoverDismiss() and not isEnabled and pvpBtn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or "Click the correct option on the left")
    elseif currentStepIndex > 1 then
        currentStepIndex = currentStepIndex - 1
        self:HideHighlight()
    end
    return true
end

local function HandleWaitStatisticsCategory(self, step, isLastStep)
    local currentTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame)
    if currentTab ~= 3 then
        RewindToTabStep(self, 3, true)
        return true
    end

    if RewindIfPriorCategoryCollapsed(self, "statisticsCategory", "statisticsCategoryID") then return true end

    if self:IsCategorySelectedByData(step.statisticsCategory, step.statisticsCategoryID) then
        if isLastStep then
            self:Cancel()
            return true
        end
        local elementData = self:FindCategoryElementData(step.statisticsCategory, step.statisticsCategoryID)
        if not elementData or not elementData.parent or not elementData.collapsed then
            self:AdvanceStep()
            return true
        end
    end

    if not isLastStep then
        local elementData = self:FindCategoryElementData(step.statisticsCategory, step.statisticsCategoryID)
        if elementData and elementData.parent and not elementData.collapsed then
            self:AdvanceStep()
            return true
        end
    end

    local categoryBtn = self:GetStatisticsCategoryButton(step.statisticsCategory, step.statisticsCategoryID)
    if categoryBtn then
        self:HighlightFrame(categoryBtn)
    else
        self:ShowInstruction(step.text or "Click '" .. step.statisticsCategory .. "' in the category list")
    end
    return true
end

local function HandleWaitStatisticID(self, step, isLastStep)
    if not (AchievementFrame and AchievementFrame:IsShown()) then
        self:Cancel()
        return true
    end
    local stats = _G["AchievementFrameStats"]
    local box = stats and stats.ScrollBox
    if not box then return true end

    local function matches(data)
        return type(data) == "table" and data.id == step.statisticID
    end

    local align = ScrollBoxConstants and ScrollBoxConstants.AlignCenter or 0.5
    if box.ScrollToElementDataByPredicate then
        pcall(box.ScrollToElementDataByPredicate, box, matches, align)
    end

    local btn = ScrollBoxFindButton(box, function(b)
        local data = b.GetElementData and b:GetElementData()
        return matches(data)
    end)
    if btn then
        self:HighlightFrame(btn)
        if isLastStep and canHoverDismiss() and btn:IsMouseOver() then
            self:Cancel()
        end
    end
    return true
end

local function HandleWaitAchievementID(self, step, isLastStep)
    if not (AchievementFrame and AchievementFrame:IsShown()) then
        self:Cancel()
        return true
    end
    local opener = _G["OpenAchievementFrameToAchievement"]
    if opener then pcall(opener, step.achievementID) end
    local btn
    local list = _G["AchievementFrameAchievements"]
    if list and list.ScrollBox then
        local getSelected = _G["AchievementFrameAchievements_GetSelectedElementData"]
        local elementData = getSelected and getSelected()
        if elementData and elementData.id == step.achievementID
           and list.ScrollBox.FindFrame then
            local ok, found = pcall(list.ScrollBox.FindFrame, list.ScrollBox, elementData)
            if ok and found and found:IsShown() then btn = found end
        end
    end
    if btn then
        self:HighlightFrame(btn)
        if isLastStep and canHoverDismiss() and btn:IsMouseOver() then
            self:Cancel()
        end
    end
    return true
end

local function HandleWaitAchievementCategory(self, step, isLastStep)
    if not (AchievementFrame and AchievementFrame:IsShown()) then
        self:Cancel()
        return true
    end
    if InsertMissingAchievementCategoryParentStep(step) then
        self:HideHighlight()
        return true
    end
    if EnforceAchievementTab(self, FindRequiredTabIndex()) then return true end
    if RewindIfPriorCategoryCollapsed(self, "achievementCategory", "achievementCategoryID") then return true end

    if self:IsCategorySelectedByData(step.achievementCategory, step.achievementCategoryID) then
        if isLastStep then
            self:Cancel()
            return true
        end
        local elementData = self:FindCategoryElementData(step.achievementCategory, step.achievementCategoryID)
        if not elementData or not elementData.parent or not elementData.collapsed then
            self:AdvanceStep()
            return true
        end
    end

    local categoryBtn = self:GetAchievementCategoryButton(step.achievementCategory, step.achievementCategoryID)
    if categoryBtn then
        self:HighlightFrame(categoryBtn)
    else
        self:ShowInstruction(step.text or "Click '" .. step.achievementCategory .. "' in the category list")
    end
    return true
end

local function HandleWaitSidebar(self, step, isLastStep)
    if EnforceRequiredTab(self, step.waitForFrame or "CharacterFrame", FindRequiredTabIndex()) then return true end

    if self:IsSidebarTabSelected(step.sidebarIndex) then
        if isLastStep then
            self:Cancel()
        else
            self:AdvanceStep()
        end
        return true
    end

    local sidebarBtn = self:GetSidebarTabButton(step.sidebarIndex)
    if sidebarBtn then
        self:HighlightFrame(sidebarBtn)
        if isLastStep and canHoverDismiss() and sidebarBtn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        local tabNames = {"Character Stats", "Titles", "Equipment Manager"}
        local tabName = tabNames[step.sidebarIndex] or ("Sidebar Tab " .. (step.sidebarIndex or "?"))
        self:ShowInstruction(step.text or "Click the '" .. tabName .. "' tab on the right side of the character panel")
    end
    return true
end

local function HandleWaitCurrency(self)
    local headerChain = {}
    for j = 1, #currentGuide.steps do
        local s = currentGuide.steps[j]
        if s and s.currencyHeader then
            headerChain[#headerChain + 1] = s.currencyHeader
        end
    end
    local lastStep = currentGuide.steps[#currentGuide.steps]
    local cID = lastStep and lastStep.currencyID
    self:Cancel()
    self:HighlightCurrencyRowOrHint(cID, headerChain)
    return true
end

local function HandleWaitFactionHeader(self, step, isLastStep)
    if EnforceRequiredTab(self, step.waitForFrame or "CharacterFrame", FindRequiredTabIndex()) then return true end

    local headerState = self:IsFactionHeaderExpanded(step.factionHeader)
    if headerState == true then
        if isLastStep then
            self:Cancel()
        else
            self:AdvanceStep()
        end
        return true
    end

    if headerState == nil then
        if RewindToPreviousStep(self, function(prevStep) return prevStep.factionHeader end) then return true end

        if C_Reputation and C_Reputation.GetNumFactions then
            local numFactions = C_Reputation.GetNumFactions()
            for i = 1, numFactions do
                local factionData = C_Reputation.GetFactionDataByIndex(i)
                if factionData and factionData.isHeader and not factionData.isHeaderExpanded then
                    local headerBtn = self:GetFactionHeaderButton(factionData.name)
                    if headerBtn then
                        self:HighlightFrame(headerBtn)
                    else
                        self:HideHighlight()
                    end
                    return true
                end
            end
        end

        self:HideHighlight()
        return true
    end

    local headerBtn = self:GetFactionHeaderButton(step.factionHeader)
    if headerBtn then
        self:HighlightFrame(headerBtn)
    else
        self:HideHighlight()
    end
    return true
end

local function HandleWaitFactionID(self, step)
    if EnforceRequiredTab(self, step.waitForFrame or "CharacterFrame", FindRequiredTabIndex()) then return true end

    for i = currentStepIndex - 1, 1, -1 do
        local prevStep = currentGuide.steps[i]
        if prevStep and prevStep.factionHeader then
            local state = self:IsFactionHeaderExpanded(prevStep.factionHeader)
            if state ~= true then
                currentStepIndex = i
                self:HideHighlight()
                return true
            end
        end
    end

    self:ScrollToFactionRow(step.factionID)
    local factionBtn = self:GetFactionRowButton(step.factionID)
    if factionBtn then
        self:HighlightFrame(factionBtn)
        if canHoverDismiss() and factionBtn:IsMouseOver() then
            self:Cancel()
        end
    end
    return true
end

local function HandleWaitDestinationPrereqs(self)
    if ValidateDestinationPrereqs(self) then return true end
    return false
end

local function HandleWaitEJInstance(self, step)
    local instSelect = _G["EncounterJournalInstanceSelect"]
    if instSelect and not instSelect:IsShown() then
        self:AdvanceStep()
        return true
    end
    local scrollBox = _G["EncounterJournalInstanceSelect"] and _G["EncounterJournalInstanceSelect"].ScrollBox
    if scrollBox then
        local targetName = slower(step.ejInstance)
        local instBtn = ScrollBoxFindButton(scrollBox, function(btn)
            local text = GetButtonText(btn)
            return text and slower(text) == targetName
        end)
        if instBtn then
            self:HighlightFrame(instBtn)
        end
    end
    return true
end

local function HandleWaitEJBoss(self, step)
    if step.ejEncounterID then
        local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
        local ej = _G["EncounterJournal"]
        local currentEnc = (infoFrame and infoFrame.encounterID)
            or (ej and ej.encounterID)
        if not currentEnc then
            local getEnc = GetCurrentEncounter or EJ_GetCurrentEncounter
            if getEnc then currentEnc = getEnc() end
        end
        if not currentEnc then
            local scrollBox = infoFrame and infoFrame.BossesScrollBox
            if scrollBox then
                local targetName = slower(step.ejBoss)
                local bossBtn = ScrollBoxFindButton(scrollBox, function(btn)
                    local text = GetButtonText(btn)
                    return text and slower(text) == targetName
                end)
                if bossBtn then
                    local sel = bossBtn.selectedTexture or bossBtn.SelectedTexture
                    if sel and sel:IsShown() then currentEnc = step.ejEncounterID end
                end
            end
        end
        if currentEnc == step.ejEncounterID then
            self:AdvanceStep()
            return true
        end
    end
    local scrollBox = _G["EncounterJournalEncounterFrameInfo"] and _G["EncounterJournalEncounterFrameInfo"].BossesScrollBox
    if scrollBox then
        local targetName = slower(step.ejBoss)
        local bossBtn = ScrollBoxFindButton(scrollBox, function(btn)
            local text = GetButtonText(btn)
            return text and slower(text) == targetName
        end)
        if bossBtn then
            self:HighlightFrame(bossBtn)
        end
    end
    return true
end

local function HandleWaitEJLootTab(self, step)
    if step.ejDifficultyID and not step._diffSet then
        step._diffSet = true
        if ns.Database then ns.Database:SetEJDifficulty(step.ejDifficultyID) end
    end
    local lootTab = _G["EncounterJournalEncounterFrameInfoLootTab"]
    if not lootTab or not lootTab:IsShown() then return true end
    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
    local lootVisible = infoFrame and (
        (infoFrame.LootContainer and infoFrame.LootContainer:IsShown())
        or (infoFrame.LootScrollBox and infoFrame.LootScrollBox:IsShown())
    )
    if not lootVisible then
        local selectedTab = infoFrame and PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(infoFrame)
        if selectedTab == 2 then lootVisible = true end
        if lootTab.isSelected then lootVisible = true end
        if lootTab.GetSelectedState and lootTab:GetSelectedState() then lootVisible = true end
    end
    if lootVisible then
        self:AdvanceStep()
        return true
    end
    self:HighlightFrame(lootTab)
    return true
end

local function HandleWaitEJLootItem(self, step)
    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
    if not infoFrame then return true end
    local lootContainer = infoFrame.LootContainer
    local scrollBox = (lootContainer and lootContainer:IsShown() and lootContainer.ScrollBox)
        or infoFrame.LootScrollBox
    if not scrollBox then return true end
    local targetID = step.ejLootItem
    local targetName = step.ejLootItemName and slower(step.ejLootItemName)

    local itemBtn = ScrollBoxFindButton(scrollBox, function(btn)
        local edata = btn.GetElementData and btn:GetElementData()
        if edata then
            if edata.itemID == targetID then return true end
            if edata.link then
                local id = edata.link:match("item:(%d+)")
                if id and tonumber(id) == targetID then return true end
            end
        end
        if targetName then
            local text = GetButtonText(btn)
            if text then
                local clean = slower(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                if clean == targetName then return true end
            end
        end
        return false
    end)
    if itemBtn then
        self:HighlightFrame(itemBtn)
        if canHoverDismiss() and itemBtn:IsMouseOver() then
            self:Cancel()
        end
    end
    return true
end

local function HandleWaitWardrobeSetsTab(self)
    local wcf = _G["WardrobeCollectionFrame"]
    if wcf and wcf.SetsCollectionFrame and wcf.SetsCollectionFrame:IsShown() then
        self:AdvanceStep()
        return true
    end
    local setsTab = self:GetTabButton("WardrobeCollectionFrame", 2)
    if setsTab then
        self:HighlightFrame(setsTab)
    end
    return true
end

local function HandleWaitTransmogSet(self, step)
    local wcf = _G["WardrobeCollectionFrame"]
    local scf = wcf and wcf.SetsCollectionFrame
    if not scf then return true end

    local lc = scf.ListContainer
    local scrollBox = lc and lc.ScrollBox
    if scrollBox and scrollBox.SetScrollPercentage then
        local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if dp then
            local matchFn = function(ed)
                return ed and ed.setID == step.transmogSetID
            end
            local finder = dp.FindElementDataByPredicate or dp.FindByPredicate
            local found = finder and finder(dp, matchFn)
            if found then
                local idx = dp.FindIndex and dp:FindIndex(found)
                local total = dp.GetSize and dp:GetSize()
                if idx and total and total > 1 then
                    scrollBox:SetScrollPercentage((idx - 1) / (total - 1))
                end
            end
        end
    end

    if scrollBox then
        local setBtn = ScrollBoxFindButton(scrollBox, function(btn)
            local edata = btn.GetElementData and btn:GetElementData()
            return edata and edata.setID == step.transmogSetID
        end)
        if setBtn then
            self:HighlightFrame(setBtn)
            if canHoverDismiss() and setBtn:IsMouseOver() then
                self:Cancel()
            end
        end
    end
    return true
end

local function HandleWaitTransmogVariantDropdown(self)
    local wcf = _G["WardrobeCollectionFrame"]
    local scf = wcf and wcf.SetsCollectionFrame
    local dd = scf and scf.DetailsFrame
        and scf.DetailsFrame.VariantSetsDropdown
    if dd and dd:IsShown() then
        self:HighlightFrame(dd)
    end
    return true
end

local function HandleWaitTransmogVariantSet(self, step)
    local wcf = _G["WardrobeCollectionFrame"]
    local scf = wcf and wcf.SetsCollectionFrame
    if scf and scf.SelectSet then
        pcall(scf.SelectSet, scf, step.transmogVariantSetID)
    end
    self:AdvanceStep()
    return true
end

local function HandleWaitTalentNode(self, step)
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talentsFrame then return true end
    local targetLower = (currentGuide.name or ""):lower()

    local match
    local containers = {
        talentsFrame.ButtonsParent,
        talentsFrame.HeroTalentsContainer,
        talentsFrame.SubTreeContainer,
    }
    for _, parent in ipairs(containers) do
        match = SearchTalentTree(parent, 0, targetLower)
        if match then break end
    end

    if match then
        if match.SearchIcon and match.SearchIcon.Show then
            match.SearchIcon:Show()
        end
        self:RegisterTalentSearchIcon(match, targetLower, TalentButtonNameLower)
        if canHoverDismiss() and match:IsMouseOver() then
            self:Cancel()
        end
    else
        self:ShowInstruction(step.text or "Look for this talent in the talents tree")
    end
    return true
end

local function HandleWaitTextInstruction(self, step)
    self:ShowInstruction(step.text)
    return true
end

local function HandleWaitRegion(self, step)
    local framePaths = step.regionFrames or { step.regionFrame }
    local region

    for _, path in ipairs(framePaths) do
        local testFrame = self:GetFrameByPath(path)
        if testFrame and testFrame:IsShown() then
            region = testFrame
            break
        end
    end

    if not region and step.searchButtonText then
        region = self:FindRatedPvPButton(step.searchButtonText)
    end

    if region then
        self:HighlightFrame(region)
        if canHoverDismiss() and region:IsMouseOver() then
            self:Cancel()
        end
    else
        self:ShowInstruction(step.text or "Look for this area in the current window")
    end
    return true
end

local function HandleWaitSearchButtonText(self, step, isLastStep)
    local pvpBtn = self:FindRatedPvPButton(step.searchButtonText)
    if pvpBtn then
        self:HighlightFrame(pvpBtn)
        if canHoverDismiss() and pvpBtn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or ("Look for '" .. step.searchButtonText .. "' in the current window"))
    end
    return true
end

local function HandleWaitLfgCategoryID(self, step, isLastStep)
    local btn = self:FindLfgCategoryButton(step.lfgCategoryID, step.lfgFilters)
    if btn then
        self:HighlightFrame(btn)
        if canHoverDismiss() and btn:IsMouseOver() then
            self:Cancel()
        end
    elseif isLastStep then
        self:ShowInstruction(step.text or "Pick the matching category in the Premade Groups list")
    end
    return true
end

local WAIT_STEP_HANDLERS = {
    { key = "tabIndex", fn = HandleWaitTabIndex },
    { condition = function(step) return step.petID or step.speciesID end, fn = HandleWaitPetJournal },
    { condition = function(step) return step.waitForFrame == "EncounterJournal" and step.ejTier end, fn = HandleWaitEncounterJournalTier },
    { key = "sideTabIndex", fn = HandleWaitSideTab },
    { key = "pvpSideTabIndex", fn = HandleWaitPvPSideTab },
    { key = "statisticsCategory", fn = HandleWaitStatisticsCategory },
    { key = "statisticID", fn = HandleWaitStatisticID },
    { key = "achievementID", fn = HandleWaitAchievementID },
    { key = "achievementCategory", fn = HandleWaitAchievementCategory },
    { condition = function(step) return step.sidebarButtonFrame or step.sidebarIndex end, fn = HandleWaitSidebar },
    { condition = function(step) return step.currencyHeader or step.currencyID end, fn = HandleWaitCurrency },
    { key = "factionHeader", fn = HandleWaitFactionHeader },
    { key = "factionID", fn = HandleWaitFactionID },
    { condition = function() return true end, fn = HandleWaitDestinationPrereqs, continueOnFalse = true },
    { key = "ejInstance", fn = HandleWaitEJInstance },
    { key = "ejBoss", fn = HandleWaitEJBoss },
    { key = "ejLootTab", fn = HandleWaitEJLootTab },
    { key = "ejLootItem", fn = HandleWaitEJLootItem },
    { key = "wardrobeSetsTab", fn = HandleWaitWardrobeSetsTab },
    { key = "transmogSetID", fn = HandleWaitTransmogSet },
    { key = "transmogVariantDropdown", fn = HandleWaitTransmogVariantDropdown },
    { key = "transmogVariantSetID", fn = HandleWaitTransmogVariantSet },
    { key = "talentNodeID", fn = HandleWaitTalentNode },
    {
        condition = function(step)
            return step.text and not step.regionFrames and not step.regionFrame and not step.searchButtonText and not step.lfgCategoryID
        end,
        fn = HandleWaitTextInstruction,
    },
    { condition = function(step) return step.regionFrames or step.regionFrame end, fn = HandleWaitRegion },
    { key = "lfgCategoryID", fn = HandleWaitLfgCategoryID },
    { key = "searchButtonText", fn = HandleWaitSearchButtonText },
}

local function HandleWaitForFrameStep(self, step, isLastStep)
    local frame = self:GetFrameByPath(step.waitForFrame)
    if not frame or not frame:IsShown() then
        if currentGuide and currentGuide.noCourseCorrect then
            self:Cancel()
        else
            currentStepIndex = 1
            self:HideHighlight()
        end
        return true
    end

    for i = 1, #WAIT_STEP_HANDLERS do
        local handler = WAIT_STEP_HANDLERS[i]
        local matches = (handler.key and step[handler.key]) or (handler.condition and handler.condition(step))
        if matches then
            local handled = handler.fn(self, step, isLastStep, frame)
            if handled or not handler.continueOnFalse then
                return true
            end
        end
    end
    return true
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

    local isLastStep = (currentStepIndex == #currentGuide.steps)

    if HandleStandaloneGuideStep(self, step) then return end

    if step.waitForFrame then
        HandleWaitForFrameStep(self, step, isLastStep)
        return
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
    if frameName == "PlayerSpellsFrame" then
        local frame = PlayerSpellsFrame
        if frame then
            if frame.GetTab then
                local currentTab = frame:GetTab()
                return currentTab == tabIndex
            end
            -- Tab 1=Spec, 2=Talents, 3=Spellbook
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

    if frameName == "CollectionsJournal" then
        local frame = CollectionsJournal
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end

    if frameName == "CharacterFrame" then
        local frame = CharacterFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        if tabIndex == 1 then
            if PaperDollFrame and PaperDollFrame:IsShown() then return true end
            if CharacterStatsPane and CharacterStatsPane:IsShown() then return true end
        elseif tabIndex == 2 then
            if ReputationFrame and ReputationFrame:IsShown() then return true end
        elseif tabIndex == 3 then
            if TokenFrame and TokenFrame:IsShown() then return true end
            if CurrencyFrame and CurrencyFrame:IsShown() then return true end
        end
        return false
    end

    if frameName == "PVEFrame" then
        local frame = PVEFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end

    if frameName == "AchievementFrame" then
        local frame = AchievementFrame
        if frame and PanelTemplates_GetSelectedTab then
            return PanelTemplates_GetSelectedTab(frame) == tabIndex
        end
        return false
    end

    if frameName == "EncounterJournal" then
        local frame = EncounterJournal
        if frame then
            -- 1=Journeys 2=TravelersLog 3=Suggested 4=Dungeons 5=Raids
            -- 6=ItemSets/Loot 7=Tutorials
            local tabContentChecks = {
                function()
                    if frame.JourneysFrame and frame.JourneysFrame:IsShown() then return true end
                    return false
                end,
                function()
                    if frame.TravelersLogFrame and frame.TravelersLogFrame:IsShown() then return true end
                    return false
                end,
                function()
                    if frame.suggestFrame and frame.suggestFrame:IsShown() then return true end
                    if frame.SuggestFrame and frame.SuggestFrame:IsShown() then return true end
                    return false
                end,
                function()
                    if frame.instanceSelect and frame.instanceSelect:IsShown() then
                        if frame.instanceSelect.tabsEnabled then
                            return frame.instanceSelect.tabsEnabled[1] == true
                        end
                    end
                    return false
                end,
                function()
                    if frame.instanceSelect and frame.instanceSelect:IsShown() then
                        if frame.instanceSelect.tabsEnabled then
                            return frame.instanceSelect.tabsEnabled[2] == true
                        end
                    end
                    return false
                end,
                function()
                    if frame.LootJournal and frame.LootJournal:IsShown() then return true end
                    if frame.LootJournalFrame and frame.LootJournalFrame:IsShown() then return true end
                    return false
                end,
                function()
                    if frame.TutorialFrame and frame.TutorialFrame:IsShown() then return true end
                    return false
                end,
            }

            local checkFn = tabContentChecks[tabIndex]
            if checkFn and checkFn() then
                return true
            end

            if PanelTemplates_GetSelectedTab then
                local selectedTab = PanelTemplates_GetSelectedTab(frame)
                if selectedTab == tabIndex then return true end
            end
        end
        return false
    end

    return false
end

function Highlight:GetCurrentTabIndex(frameName)
    local frame = _G[frameName]
    if frame and PanelTemplates_GetSelectedTab then
        return PanelTemplates_GetSelectedTab(frame)
    end
    return nil
end

function Highlight:IsSideTabSelected(frameName, sideTabIndex)
    if frameName == "PVEFrame" then
        if sideTabIndex == 1 then
            return LFDParentFrame and LFDParentFrame:IsShown()
        elseif sideTabIndex == 2 then
            return RaidFinderFrame and RaidFinderFrame:IsShown()
        elseif sideTabIndex == 3 then
            -- LFGListFrame is shared across sub-panels and may report
            -- IsShown even when another panel is on top, so explicitly
            -- rule them out first.
            if LFDParentFrame and LFDParentFrame:IsShown() then
                return false
            end
            if RaidFinderFrame and RaidFinderFrame:IsShown() then
                return false
            end
            if LFGListPVEStub and LFGListPVEStub:IsShown() then
                return true
            end
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
    if frameName == "PVEFrame" then
        local tab1Active = HonorFrame and HonorFrame:IsShown()
        local tab2Active = ConquestFrame and ConquestFrame:IsShown()
        local tab4Active = TrainingGroundsFrame and TrainingGroundsFrame:IsShown()
        -- LFGListFrame is shared, so rule out every other sub-panel
        -- before trusting it.
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
            return tab1Active
        elseif sideTabIndex == 2 then
            return tab2Active
        elseif sideTabIndex == 3 then
            return tab3Active
        elseif sideTabIndex == 4 then
            if TrainingGroundsFrame and TrainingGroundsFrame:IsShown() then
                return true
            end
            local onPvPTab = PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(PVEFrame) == 2
            if onPvPTab and not tab1Active and not tab2Active and not tab3Active then
                return true
            end
            return false
        end

        local pvpButtons = self:GetPvPSideTabButtons()
        if pvpButtons and pvpButtons[sideTabIndex] then
            local sideTab = pvpButtons[sideTabIndex]
            if sideTab.GetSelectedState and sideTab:GetSelectedState() then return true end
            if sideTab.IsSelected and sideTab:IsSelected() then return true end
            if sideTab.selectedTex and sideTab.selectedTex:IsShown() then return true end
            if sideTab.selectedTexture and sideTab.selectedTexture:IsShown() then return true end
            if sideTab.Selected and sideTab.Selected:IsShown() then return true end
            if sideTab.isSelected then return true end
        end

        return false
    end

    return false
end

function Highlight:GetPvPSideTabButtons()
    local buttons = {}

    if not PVPQueueFrame then return buttons end

    -- CategoryButton1=Quick Match, 2=Rated, 3=Premade, 4=Training Grounds
    for i = 1, 4 do
        local btn = PVPQueueFrame["CategoryButton" .. i]
        if btn then
            buttons[i] = btn
        end
    end

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

-- All three tabs (Achievements, Guild, Statistics) share
-- AchievementFrameCategories.ScrollBox. Element data shape:
-- { id, selected, parent, isChild, ... }. Names resolve via
-- GetCategoryInfo(elementData.id).
local function CategoryDataMatches(data, categoryName, categoryID)
    if not data then return false end
    local catID = tonumber(data.id)
    if not catID then return false end

    local numericCategoryID = tonumber(categoryID)
    if numericCategoryID then return catID == numericCategoryID end

    if categoryName and GetCategoryInfo then
        local title = GetCategoryInfo(catID)
        if title and slower(title) == slower(categoryName) then return true end
    end
    return false
end

local function CurrentGuideHasPriorAchievementCategoryID(categoryID)
    local numericCategoryID = tonumber(categoryID)
    if not numericCategoryID or not currentGuide or not currentGuide.steps or not currentStepIndex then
        return false
    end
    for i = currentStepIndex - 1, 1, -1 do
        local step = currentGuide.steps[i]
        if step and tonumber(step.achievementCategoryID) == numericCategoryID then
            return true
        end
    end
    return false
end

local function GetAchievementCategoryInfo(categoryID)
    local numericCategoryID = tonumber(categoryID)
    if not numericCategoryID or not GetCategoryInfo then return nil end
    local name, parentID = GetCategoryInfo(numericCategoryID)
    if not name or name == "" then return nil end
    return {
        id = numericCategoryID,
        name = name,
        parentID = tonumber(parentID),
    }
end

local function BuildAchievementCategoryChain(categoryID)
    if not GetCategoryInfo then return nil end
    local chain = {}
    local seen = {}
    local current = tonumber(categoryID)

    while current and current > 0 and not seen[current] do
        seen[current] = true
        local info = GetAchievementCategoryInfo(current)
        if not info then break end
        chain[#chain + 1] = info
        current = info.parentID
    end

    if #chain == 0 then return nil end
    local rootDown = {}
    for i = #chain, 1, -1 do
        rootDown[#rootDown + 1] = chain[i]
    end
    return rootDown
end

local function StepHasAchievementCategoryID(step, categoryID)
    local numericCategoryID = tonumber(categoryID)
    return step and numericCategoryID
        and tonumber(step.achievementCategoryID) == numericCategoryID
end

local function StepListHasAchievementCategoryID(steps, categoryID)
    if not steps then return false end
    for i = 1, #steps do
        if StepHasAchievementCategoryID(steps[i], categoryID) then return true end
    end
    return false
end

local function BuildAchievementCategoryStep(sourceStep, category)
    return {
        waitForFrame = sourceStep.waitForFrame or "AchievementFrame",
        achievementCategory = category.name,
        achievementCategoryID = category.id,
    }
end

RepairAchievementCategoryGuideSteps = function(guideData)
    local steps = guideData and guideData.steps
    if not steps or #steps == 0 or not GetCategoryInfo then return end

    local repaired = {}
    local changed = false
    for i = 1, #steps do
        local step = steps[i]
        if step and step.achievementCategory and step.achievementCategoryID then
            local chain = BuildAchievementCategoryChain(step.achievementCategoryID)
            if chain then
                local leaf = chain[#chain]
                if leaf and leaf.name and step.achievementCategory ~= leaf.name then
                    step.achievementCategory = leaf.name
                    changed = true
                end
            end
            if chain and #chain > 1 then
                for c = 1, #chain - 1 do
                    local category = chain[c]
                    if not StepListHasAchievementCategoryID(repaired, category.id) then
                        repaired[#repaired + 1] = BuildAchievementCategoryStep(step, category)
                        changed = true
                    end
                end
            end
        end

        repaired[#repaired + 1] = step
    end

    if changed then
        guideData.steps = repaired
    end
end

InsertMissingAchievementCategoryParentStep = function(step)
    local categoryID = step and tonumber(step.achievementCategoryID)
    if not categoryID or CurrentGuideHasPriorAchievementCategoryID(categoryID) then return false end

    local chain = BuildAchievementCategoryChain(categoryID)
    if not chain or #chain < 2 then return false end

    local missingParent
    for i = #chain - 1, 1, -1 do
        local category = chain[i]
        if not CurrentGuideHasPriorAchievementCategoryID(category.id) then
            missingParent = category
            break
        end
    end
    if not missingParent then return false end

    local steps = currentGuide and currentGuide.steps
    if not steps or not currentStepIndex then return false end
    for i = #steps, currentStepIndex, -1 do
        steps[i + 1] = steps[i]
    end
    steps[currentStepIndex] = {
        waitForFrame = "AchievementFrame",
        achievementCategory = missingParent.name,
        achievementCategoryID = missingParent.id,
    }
    return true
end

function Highlight:FindCategoryElementData(categoryName, categoryID)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if not categoriesFrame or not categoriesFrame.ScrollBox then return nil, nil end

    local scrollBox = categoriesFrame.ScrollBox
    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if not dataProvider then return nil, nil end

    local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
    if not finder then return nil, nil end

    local elementData = finder(dataProvider, function(data)
        return CategoryDataMatches(data, categoryName, categoryID)
    end)

    return elementData, scrollBox
end

-- AchievementCategoryTemplate stores text on btn.Button, so use
-- GetElementData().id -> GetCategoryInfo() instead of GetText() on btn.
function Highlight:FindVisibleCategoryButton(categoryName, categoryID)
    local categoriesFrame = _G["AchievementFrameCategories"]
    if not categoriesFrame or not categoriesFrame.ScrollBox then return nil end

    local scrollBox = categoriesFrame.ScrollBox

    if scrollBox.FindFrameByPredicate then
        local frame = scrollBox:FindFrameByPredicate(function(frame, elementData)
            local data = elementData
                or (frame and frame.GetElementData and frame:GetElementData())
                or frame
            return CategoryDataMatches(data, categoryName, categoryID)
        end)
        if frame then return frame end
    end

    if scrollBox.EnumerateFrames then
        for _, btn in scrollBox:EnumerateFrames() do
            if btn and btn:IsShown() and btn.GetElementData then
                local data = btn:GetElementData()
                if CategoryDataMatches(data, categoryName, categoryID) then
                    return btn
                end
            end
        end
    end

    return nil
end

function Highlight:IsCategorySelectedByData(categoryName, categoryID)
    local elementData = self:FindCategoryElementData(categoryName, categoryID)
    if elementData and elementData.selected then
        return true
    end

    local btn = self:FindVisibleCategoryButton(categoryName, categoryID)
    if btn and btn.GetElementData then
        local btnData = btn:GetElementData()
        if btnData and btnData.selected then return true end
    end

    return false
end

-- A parent doesn't need to stay selected once a child is - just expanded.
function Highlight:IsCategoryExpandedOrSelected(categoryName, categoryID)
    local elementData = self:FindCategoryElementData(categoryName, categoryID)
    if not elementData then return false end

    if elementData.selected then return true end

    if elementData.parent == true and not elementData.collapsed then
        return true
    end

    return false
end

function Highlight:ScrollToCategoryButton(categoryName, categoryID)
    local elementData, scrollBox = self:FindCategoryElementData(categoryName, categoryID)
    if not elementData or not scrollBox then return nil end

    if elementData.hidden then
        local catID = tonumber(elementData.id)
        if catID and AchievementFrameCategories_ExpandToCategory then
            AchievementFrameCategories_ExpandToCategory(catID)
            if AchievementFrameCategories_UpdateDataProvider then
                AchievementFrameCategories_UpdateDataProvider()
            end
            elementData, scrollBox = self:FindCategoryElementData(categoryName, categoryID)
            if not elementData or not scrollBox then return nil end
        end
    end

    local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
    if scrollBox.ScrollToElementData then
        pcall(scrollBox.ScrollToElementData, scrollBox, elementData, alignCenter)
    end

    return self:FindVisibleCategoryButton(categoryName, categoryID)
end

function Highlight:IsStatisticsCategorySelected(categoryName, categoryID)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return false
    end

    if self:IsCategorySelectedByData(categoryName, categoryID) then
        return true
    end

    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.statisticsCategory then
            local nextBtn = self:FindVisibleCategoryButton(nextStep.statisticsCategory, nextStep.statisticsCategoryID)
            if nextBtn then
                return true
            end
        end
    end

    return false
end

function Highlight:GetStatisticsCategoryButton(categoryName, categoryID)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(AchievementFrame) ~= 3 then
        return nil
    end

    local visibleBtn = self:FindVisibleCategoryButton(categoryName, categoryID)
    if visibleBtn then return visibleBtn end

    return self:ScrollToCategoryButton(categoryName, categoryID)
end

function Highlight:IsAchievementCategorySelected(categoryName, categoryID)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end

    if self:IsCategorySelectedByData(categoryName, categoryID) then
        return true
    end

    if currentGuide and currentStepIndex then
        local nextStep = currentGuide.steps[currentStepIndex + 1]
        if nextStep and nextStep.achievementCategory then
            local nextBtn = self:FindVisibleCategoryButton(nextStep.achievementCategory, nextStep.achievementCategoryID)
            if nextBtn then
                return true
            end
        end
    end

    return false
end

function Highlight:GetAchievementCategoryButton(categoryName, categoryID, noScroll)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return nil
    end

    local visibleBtn = self:FindVisibleCategoryButton(categoryName, categoryID)
    if visibleBtn then return visibleBtn end

    if noScroll then return nil end
    return self:ScrollToCategoryButton(categoryName, categoryID)
end

function Highlight:IsSidebarTabSelected(sidebarIndex)
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end

    if sidebarIndex == 1 then
        if CharacterStatsPane and CharacterStatsPane:IsShown() then return true end
    elseif sidebarIndex == 2 then
        if PaperDollTitlesPane and PaperDollTitlesPane:IsShown() then return true end
    elseif sidebarIndex == 3 then
        if PaperDollEquipmentManagerPane and PaperDollEquipmentManagerPane:IsShown() then return true end
    end

    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab then
        if sidebarTab.isSelected then return true end
        if sidebarTab.selected then return true end
        if sidebarTab.GetChecked and sidebarTab:GetChecked() then return true end
        if sidebarTab.IsChecked and sidebarTab:IsChecked() then return true end
    end

    return false
end

function Highlight:GetSidebarTabButton(sidebarIndex)
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return nil
    end

    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab and sidebarTab:IsShown() then
        return sidebarTab
    end

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

-- Find a Premade Groups category button by Blizzard's stable categoryID
-- (locale-independent, unlike text-matching button labels). When two
-- buttons share a categoryID (e.g. "Raids - The War Within" vs
-- "Raids - Legacy" are both categoryID 3 split by recommended-vs-not
-- filter flags), filters narrows the match -- pass the expected
-- Enum.LFGListFilter combination. The Group Finder must be open to the
-- Premade Groups tab for the buttons to be present; the prior
-- pvpSideTabIndex/sideTabIndex step handles that.
function Highlight:FindLfgCategoryButton(categoryID, filters)
    if not categoryID or not LFGListFrame then return nil end
    local cs = LFGListFrame.CategorySelection
    if not cs or not cs.CategoryButtons then return nil end
    for i = 1, #cs.CategoryButtons do
        local btn = cs.CategoryButtons[i]
        if btn and btn.categoryID == categoryID and btn:IsShown() then
            if not filters or btn.filters == filters then
                return btn
            end
        end
    end
    return nil
end

function Highlight:FindRatedPvPButton(buttonText)
    if not PVEFrame or not PVEFrame:IsShown() then
        return nil
    end

    local searchText = slower(buttonText)

    -- Search only the active sub-panel: otherwise we'd find "Random
    -- Battlegrounds" on Quick Match when looking for an Arena Skirmishes
    -- button on Premade Groups.
    local searchRoots = {}

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

    if LFDParentFrame and LFDParentFrame:IsShown() then
        searchRoots[#searchRoots + 1] = LFDParentFrame
    end
    if RaidFinderFrame and RaidFinderFrame:IsShown() then
        searchRoots[#searchRoots + 1] = RaidFinderFrame
    end
    if LFGListPVEStub and LFGListPVEStub:IsShown() then
        searchRoots[#searchRoots + 1] = LFGListPVEStub
    end

    -- LFGListFrame is shared between PvE and PvP premade groups.
    if LFGListFrame and LFGListFrame:IsShown() then
        searchRoots[#searchRoots + 1] = LFGListFrame
    end

    for _, root in ipairs(searchRoots) do
        local result = SearchFrameTreeFuzzy(root, searchText)
        if result then return result end
    end

    return SearchFrameTreeFuzzy(PVEFrame, searchText)
end

function Highlight:GetTabButton(frameName, tabIndex)
    if frameName == "PlayerSpellsFrame" then
        local frame = PlayerSpellsFrame
        if frame and frame.TabSystem and frame.TabSystem.tabs then
            return frame.TabSystem.tabs[tabIndex]
        end
        local tabBtn = _G["PlayerSpellsFrameTab" .. tabIndex]
        if tabBtn then return tabBtn end

        if frame then
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

    if frameName == "CollectionsJournal" then
        return _G["CollectionsJournalTab" .. tabIndex]
    end

    if frameName == "CharacterFrame" then
        return _G["CharacterFrameTab" .. tabIndex]
    end

    if frameName == "PVEFrame" then
        return _G["PVEFrameTab" .. tabIndex]
    end

    if frameName == "AchievementFrame" then
        return _G["AchievementFrameTab" .. tabIndex]
    end

    if frameName == "WardrobeCollectionFrame" then
        local tabBtn = _G["WardrobeCollectionFrameTab" .. tabIndex]
        if tabBtn then return tabBtn end
        local frame = _G["WardrobeCollectionFrame"]
        if frame then
            if frame.Tabs and frame.Tabs[tabIndex] then return frame.Tabs[tabIndex] end
            if frame.TabSystem and frame.TabSystem.tabs then
                local tab = frame.TabSystem.tabs[tabIndex]
                if tab then return tab end
            end
            if tabIndex == 2 and frame.SetsTab then return frame.SetsTab end
            if tabIndex == 1 and frame.ItemsTab then return frame.ItemsTab end
            -- Only button-type children: SetsCollectionFrame also matches
            -- "Sets" but it's a content frame, not a tab.
            local tabKeywords = { {"Items", "Item", "Tab1"}, {"Sets", "Set", "Tab2"} }
            local keywords = tabKeywords[tabIndex]
            if keywords then
                for i = 1, select("#", frame:GetChildren()) do
                    local child = select(i, frame:GetChildren())
                    local objType = child.GetObjectType and child:GetObjectType()
                    if objType == "Button" or objType == "CheckButton" then
                        local cname = child:GetName() or ""
                        local debugName = child.GetDebugName and child:GetDebugName() or ""
                        for _, kw in ipairs(keywords) do
                            if sfind(cname, kw) or sfind(debugName, kw) then return child end
                        end
                    end
                end
            end
        end
    end

    if frameName == "EncounterJournal" then
        local frame = EncounterJournal
        if frame then
            -- 1=Journeys 2=TravelersLog 3=Suggested 4=Dungeons 5=Raids
            -- 6=ItemSets/Loot 7=Tutorials
            local tabKeywords = {
                {"Journey", "Journeys"},
                {"Traveler", "Travel", "Log"},
                {"Suggest"},
                {"Dungeon"},
                {"Raid"},
                {"Loot", "ItemSet", "Set"},
                {"Tutorial", "HelpFrame"},
            }

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

                local btn = findTabInContainer(frame.TopNavBar, keywords)
                if btn then return btn end

                btn = findTabInContainer(frame.TabBar, keywords)
                if btn then return btn end

                btn = findTabInContainer(frame.TabSystem, keywords)
                if btn then return btn end

                btn = findTabInContainer(frame, keywords)
                if btn then return btn end
            end

            if frame.TabSystem and frame.TabSystem.tabs then
                return frame.TabSystem.tabs[tabIndex]
            end

            local containers = {frame.TopNavBar, frame.TabBar, frame.TabSystem, frame}
            for _, container in ipairs(containers) do
                if container then
                    local count = 0
                    for i = 1, select("#", container:GetChildren()) do
                        local child = select(i, container:GetChildren())
                        if child.GetText or child.Click then
                            count = count + 1
                            if count == tabIndex then
                                return child
                            end
                        end
                    end
                end
            end

            local tab = _G["EncounterJournalTab" .. tabIndex]
            if tab then return tab end

            local bottomTab = _G["EncounterJournalBottomTab" .. tabIndex]
            if bottomTab then return bottomTab end
        end
    end

    return nil
end

function Highlight:GetSideTabButton(frameName, sideTabIndex)
    if frameName == "PVEFrame" then
        local sideButtons = {
            GroupFinderFrame and GroupFinderFrame.DungeonFinderButton,
            GroupFinderFrame and GroupFinderFrame.RaidFinderButton,
            GroupFinderFrame and GroupFinderFrame.LFGListButton,
        }
        local btn = sideButtons[sideTabIndex]
        if btn and btn:IsShown() then
            return btn
        end

        local buttonNames = {
            "GroupFinderFrameGroupButton1",
            "GroupFinderFrameGroupButton2",
            "GroupFinderFrameGroupButton3",
        }
        return _G[buttonNames[sideTabIndex]]
    end

    return nil
end

function Highlight:HighlightFrame(frame, instructionText, validator, noHoverDismiss)
    if not frame or not frame:IsShown() then
        self:HideHighlight()
        return
    end

    highlightFrame._targetFrame = frame
    highlightFrame._targetValidator = validator
    highlightFrame._hoverDismissFrame = (not noHoverDismiss) and frame or nil
    highlightFrame._clearWhenTargetHidden = true

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
    highlightFrame.left:SetPoint("TOPLEFT", highlightFrame.top, "BOTTOMLEFT", 0, 0)
    highlightFrame.left:SetPoint("BOTTOMLEFT", highlightFrame.bottom, "TOPLEFT", 0, 0)
    highlightFrame.left:SetWidth(bs)

    highlightFrame.right:ClearAllPoints()
    highlightFrame.right:SetPoint("TOPRIGHT", highlightFrame.top, "BOTTOMRIGHT", 0, 0)
    highlightFrame.right:SetPoint("BOTTOMRIGHT", highlightFrame.bottom, "TOPRIGHT", 0, 0)
    highlightFrame.right:SetWidth(bs)

    if not highlightFrame:IsShown() then
        highlightShownAt = GetTime()
    end
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
    elseif instructionFrame then
        instructionFrame:Hide()
    end
end

function Highlight:ShowInstruction(text)
    instructionFrame.text:SetText(text)

    local maxWidth = 450
    instructionFrame:SetWidth(maxWidth)

    local textHeight = instructionFrame.text:GetStringHeight()
    local frameHeight = mmax(90, textHeight + 60)
    instructionFrame:SetHeight(frameHeight)

    instructionFrame:ClearAllPoints()
    instructionFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    instructionFrame:Show()
end

-- Hooks Blizzard's native SearchIcon spyglass into the visibility
-- watcher so it clears on cascade-hide / repurpose / hover-dismiss
-- without drawing our own yellow border on top. validator may be nil
-- for "always valid until the button hides".
function Highlight:RegisterSearchIconWatch(button, validator)
    if not button then return end
    if highlightFrame._talentSearchBtn
       and highlightFrame._talentSearchBtn ~= button
       and highlightFrame._talentSearchBtn.SearchIcon then
        highlightFrame._talentSearchBtn.SearchIcon:Hide()
    end
    highlightFrame._talentSearchBtn = button
    highlightFrame._targetFrame = button
    highlightFrame._targetValidator = validator
    highlightFrame._hoverDismissFrame = button
    highlightFrame._clearWhenTargetHidden = true
    -- Hide our yellow border so the watcher ticks without drawing on
    -- top of the native spyglass.
    if highlightFrame.top    then highlightFrame.top:Hide() end
    if highlightFrame.bottom then highlightFrame.bottom:Hide() end
    if highlightFrame.left   then highlightFrame.left:Hide() end
    if highlightFrame.right  then highlightFrame.right:Hide() end
    if not highlightFrame:IsShown() then
        highlightShownAt = GetTime()
    end
    highlightFrame:Show()
    if highlightFrame.animGroup then highlightFrame.animGroup:Stop() end
end

function Highlight:RegisterTalentSearchIcon(button, targetNameLower, nameOf)
    self:RegisterSearchIconWatch(button, function(f)
        return nameOf and nameOf(f) == targetNameLower
    end)
end

-- Matches the spellbook-item-unassigned-glow visual via our own texture
-- (not the real glow, which signals "spell not on an action bar").
function Highlight:HighlightSpellbookSpell(row, validator)
    if not row or not row:IsShown() then
        self:HideHighlight()
        return
    end
    self:HideHighlight()

    -- Glow only the icon: row.Button (~40x39) holds the icon; the row
    -- itself also contains label and artwork we don't want lit up.
    local iconBtn = (row.Button and row.Button.IsShown and row.Button:IsShown() and row.Button) or row

    local glow = iconBtn._efSearchGlow
    if not glow then
        local w, h = iconBtn:GetSize()
        if not w or w < 1 then w = 40 end
        if not h or h < 1 then h = 39 end
        glow = iconBtn:CreateTexture(nil, "OVERLAY", nil, 1)
        glow:SetAtlas("spellbook-item-unassigned-glow")
        glow:SetPoint("CENTER", iconBtn, "CENTER", 0, 0)
        glow:SetSize(w * 1.4, h * 1.4)
        glow:SetBlendMode("ADD")
        glow._efPulse = ns.CreateBouncePulse(glow, 0.85, 1.6, 0.7)
        iconBtn._efSearchGlow = glow
    end
    glow:SetAlpha(1.6)
    glow:Show()
    if glow._efPulse and not glow._efPulse:IsPlaying() then
        glow._efPulse:Play()
    end

    highlightFrame._spellbookGlowBtn = iconBtn
    highlightFrame._targetFrame = row
    highlightFrame._targetValidator = validator
    highlightFrame._hoverDismissFrame = row
    highlightFrame._clearWhenTargetHidden = true
    if highlightFrame.top    then highlightFrame.top:Hide() end
    if highlightFrame.bottom then highlightFrame.bottom:Hide() end
    if highlightFrame.left   then highlightFrame.left:Hide() end
    if highlightFrame.right  then highlightFrame.right:Hide() end
    if not highlightFrame:IsShown() then
        highlightShownAt = GetTime()
    end
    highlightFrame:Show()
    if highlightFrame.animGroup then highlightFrame.animGroup:Stop() end
end

function Highlight:HideHighlight()
    highlightShownAt = nil
    if highlightFrame then
        if highlightFrame._talentSearchBtn
           and highlightFrame._talentSearchBtn.SearchIcon then
            highlightFrame._talentSearchBtn.SearchIcon:Hide()
        end
        if highlightFrame._spellbookGlowBtn
           and highlightFrame._spellbookGlowBtn._efSearchGlow then
            local g = highlightFrame._spellbookGlowBtn._efSearchGlow
            if g._efPulse then g._efPulse:Stop() end
            g:Hide()
        end
        highlightFrame._talentSearchBtn = nil
        highlightFrame._spellbookGlowBtn = nil
        highlightFrame._targetFrame = nil
        highlightFrame._targetValidator = nil
        highlightFrame._hoverDismissFrame = nil
        highlightFrame._clearWhenTargetHidden = nil
        highlightFrame:Hide()
        if highlightFrame.animGroup then highlightFrame.animGroup:Stop() end
        if highlightFrame.top    then highlightFrame.top:Show() end
        if highlightFrame.bottom then highlightFrame.bottom:Show() end
        if highlightFrame.left   then highlightFrame.left:Show() end
        if highlightFrame.right  then highlightFrame.right:Show() end
    end
    if indicatorFrame then
        indicatorFrame:Hide()
        if indicatorFrame.animGroup then indicatorFrame.animGroup:Stop() end
    end
    if scrollHintFrame then
        scrollHintFrame:Hide()
        if scrollHintFrame.animGroup then scrollHintFrame.animGroup:Stop() end
    end
    if instructionFrame then
        instructionFrame:Hide()
    end
    if contextTooltip then
        contextTooltip:Hide()
    end
end

function Highlight:IsActive()
    return currentGuide ~= nil
end

function Highlight:NotifyClearButton()
    if ns.Search and ns.Search.searchFrame and ns.Search.searchFrame.UpdateClearButtonVisibility then
        ns.Search.searchFrame.UpdateClearButtonVisibility()
    end
end

function Highlight:ClearAll()
    self:HideHighlight()
    currentGuide = nil
    currentStepIndex = nil
    if stepTicker then stepTicker:Cancel(); stepTicker = nil end
    self:NotifyClearButton()
end

function Highlight:IsPortraitMenuOpen()
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            return true
        end
    end

    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(manager.GetOpenMenu, manager)
            if openOk and openMenu then
                return true
            end
        end
    end

    if UIDROPDOWNMENU_OPEN_MENU and UIDROPDOWNMENU_OPEN_MENU ~= "" then
        return true
    end

    local menuNames = {"PlayerFrameDropDown", "DropDownList1", "UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(frame.IsShown, frame)
            if ok and shown then
                return true
            end
        end
    end

    return false
end

function Highlight:GetPortraitMenuFrame()
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            return dropdown
        end
    end

    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(manager.GetOpenMenu, manager)
            if openOk and openMenu then
                return openMenu
            end
        end
    end

    local menuNames = {"UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(frame.IsShown, frame)
            if ok and shown then
                return frame
            end
        end
    end

    return nil
end

-- Modern GameMenuFrame buttons have dynamic hex names that change each
-- session; iterate visible children and match GetText().
function Highlight:FindGameMenuButton(label)
    if not GameMenuFrame or not label then return nil end
    local target = slower(label)
    local ok, nChildren = pcall(GameMenuFrame.GetNumChildren, GameMenuFrame)
    if not ok or not nChildren then return nil end
    for i = 1, nChildren do
        local child = select(i, GameMenuFrame:GetChildren())
        if child then
            local sok, shown = pcall(child.IsShown, child)
            if sok and shown and child.GetText then
                local tok, text = pcall(child.GetText, child)
                if tok and text and slower(text) == target then
                    return child
                end
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
        local regOk, nRegions = pcall(frame.GetNumRegions, frame)
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

        local childOk, nChildren = pcall(frame.GetNumChildren, frame)
        if not childOk or not nChildren then return nil end
        for i = 1, nChildren do
            local child = select(i, frame:GetChildren())
            local shownOk, shown = pcall(child.IsShown, child)
            if shownOk and shown then
                local text = getFrameText(child)
                if text and sfind(slower(text), optionNameLower, 1, true) then
                    return child
                end

                local result = searchFrame(child, depth + 1)
                if result then return result end
            end
        end
        return nil
    end

    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            local result = searchFrame(dropdown, 0)
            if result then return result end
        end
    end

    if Menu and Menu.GetManager then
        local ok, manager = pcall(Menu.GetManager)
        if ok and manager then
            local openOk, openMenu = pcall(manager.GetOpenMenu, manager)
            if openOk and openMenu then
                local result = searchFrame(openMenu, 0)
                if result then return result end
            end
        end
    end

    local menuNames = {"UnitPopupWindow"}
    for _, name in ipairs(menuNames) do
        local frame = _G[name]
        if frame then
            local ok, shown = pcall(frame.IsShown, frame)
            if ok and shown then
                local result = searchFrame(frame, 0)
                if result then return result end
            end
        end
    end

    return nil
end

-- Returns true (expanded), false (collapsed), nil (parent collapsed).
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
    return nil
end

function Highlight:GetCurrencyHeaderButton(headerName)
    if not TokenFrame or not TokenFrame:IsShown() then return nil end

    local headerNameLower = slower(headerName)

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
    if not targetIndex then return nil end

    if TokenFrame.ScrollBox then
        ScrollBoxScrollTo(TokenFrame.ScrollBox, function(data)
            return data and data.currencyIndex == targetIndex
        end)
        return ScrollBoxFindButton(TokenFrame.ScrollBox, function(btn)
            local elementData = btn.elementData or (btn.GetElementData and btn:GetElementData())
            if elementData and elementData.currencyIndex == targetIndex then return true end
            local text = GetButtonText(btn)
            return text and slower(text) == headerNameLower
        end)
    end

    return nil
end

function Highlight:ScrollToCurrencyRow(currencyID)
    if not TokenFrame or not TokenFrame:IsShown() then return end
    if not TokenFrame.ScrollBox then return end
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return end

    local size = C_CurrencyInfo.GetCurrencyListSize()
    local targetIndex = nil
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            targetIndex = i
            break
        end
    end
    if not targetIndex then return end

    local fraction = (targetIndex - 1) / mmax(1, size - 1)
    ScrollBoxScrollTo(TokenFrame.ScrollBox, function(data)
        if not data then return false end
        if data.currencyID == currencyID then return true end
        if data.currencyIndex == targetIndex then return true end
        return false
    end, fraction)
end

-- Tutorial-style "scroll up" / "scroll down" arrow anchored to the top or
-- bottom of the TokenFrame's ScrollBox, with a label next to it. Used when
-- we can't auto-scroll (taint would block the protected transfer Confirm)
-- but want to nudge the player toward where the row actually is.
function Highlight:CreateScrollHintFrame()
    if scrollHintFrame then return end
    scrollHintFrame = CreateFrame("Frame", "EasyFindScrollHintFrame", UIParent)
    scrollHintFrame:SetFrameStrata("TOOLTIP")
    scrollHintFrame:SetFrameLevel(500)
    scrollHintFrame:Hide()

    local iconSize = ns.ICON_SIZE or 48
    scrollHintFrame:SetSize(iconSize, iconSize)

    if ns.CreateIndicatorTextures then
        ns.CreateIndicatorTextures(scrollHintFrame, iconSize, ns.ICON_GLOW_SIZE)
    end

    local animGroup, trans = ns.CreateBounceFloat(scrollHintFrame, 0, 0, 0.4)
    scrollHintFrame.animGroup = animGroup
    scrollHintFrame.animTranslation = trans

    local text = scrollHintFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("LEFT", scrollHintFrame, "RIGHT", 8, 0)
    scrollHintFrame.text = text
end

function Highlight:ShowScrollHint(direction)
    self:CreateScrollHintFrame()
    if not scrollHintFrame then return end
    local sb = TokenFrame and TokenFrame.ScrollBox
    if not sb then return end

    scrollHintFrame.indicatorDirection = direction
    if ns.UpdateIndicator then ns.UpdateIndicator(scrollHintFrame) end
    if scrollHintFrame.text then
        scrollHintFrame.text:SetText(direction == "up" and "Scroll up" or "Scroll down")
    end

    scrollHintFrame:ClearAllPoints()
    local trans = scrollHintFrame.animTranslation
    if direction == "up" then
        -- Anchor inside ScrollBox so the arrow's tip sits at the top edge.
        scrollHintFrame:SetPoint("TOP", sb, "TOP", -40, 0)
        if trans then trans:SetOffset(0, 6) end
    else
        scrollHintFrame:SetPoint("BOTTOM", sb, "BOTTOM", -40, 0)
        if trans then trans:SetOffset(0, -6) end
    end

    scrollHintFrame:Show()
    if scrollHintFrame.animGroup and not scrollHintFrame.animGroup:IsPlaying() then
        scrollHintFrame.animGroup:Play()
    end
end

function Highlight:HideScrollHint()
    if not scrollHintFrame then return end
    scrollHintFrame:Hide()
    if scrollHintFrame.animGroup then scrollHintFrame.animGroup:Stop() end
end

-- Walks the currency list to find the header containing the given currency
-- and returns its info table (has .name, .isHeaderExpanded). Used to detect
-- "row is hidden because its header is collapsed" so we can prompt the
-- player to click the header instead of scrolling pointlessly.
function Highlight:GetCurrencyHeaderForCurrency(currencyID)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return nil end
    local size = C_CurrencyInfo.GetCurrencyListSize()
    local targetIndex, targetDepth
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            targetIndex = i
            targetDepth = info.currencyListDepth or 0
            break
        end
    end
    if not targetIndex then return nil end
    for i = targetIndex - 1, 1, -1 do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.isHeader and (info.currencyListDepth or 0) < targetDepth then
            return info
        end
    end
    return nil
end

-- True only when the button's full vertical extent is inside the ScrollBox
-- viewport (not clipped at top or bottom). Partial visibility shouldn't
-- count as "in view" for header highlighting -- the player needs to be
-- able to click it cleanly.
local function isButtonFullyVisible(btn)
    if not (TokenFrame and TokenFrame.ScrollBox and btn) then return false end
    local boxTop = TokenFrame.ScrollBox.GetTop and TokenFrame.ScrollBox:GetTop()
    local boxBottom = TokenFrame.ScrollBox.GetBottom and TokenFrame.ScrollBox:GetBottom()
    if not (boxTop and boxBottom) then return false end
    local bt = btn.GetTop and btn:GetTop()
    local bb = btn.GetBottom and btn:GetBottom()
    if not (bt and bb) then return false end
    return bt <= boxTop and bb >= boxBottom
end

-- Finds a currency header button currently rendered by the ScrollBox.
-- Read-only (no scroll), so doesn't taint. Matches first by the header's
-- currencyIndex in C_CurrencyInfo's list (Blizzard's own GetCurrencyHeaderButton
-- uses this approach), then falls back to visible button text.
function Highlight:FindVisibleCurrencyHeaderButton(headerName)
    if not TokenFrame or not TokenFrame.ScrollBox then return nil end
    if not TokenFrame.ScrollBox.EnumerateFrames then return nil end
    local lower = slower(headerName)

    local targetIndex
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
        local size = C_CurrencyInfo.GetCurrencyListSize()
        for i = 1, size do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and info.isHeader and info.name and slower(info.name) == lower then
                targetIndex = i
                break
            end
        end
    end

    for _, btn in TokenFrame.ScrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and isButtonFullyVisible(btn) then
            local data = btn.elementData or (btn.GetElementData and btn:GetElementData())
            if data and targetIndex and data.currencyIndex == targetIndex then
                return btn
            end
            local text = GetButtonText(btn)
            if text and slower(text) == lower then return btn end
        end
    end
    return nil
end

-- Looks up the target currency's index in the list and the indices currently
-- rendered by the ScrollBox, then returns "up" or "down" indicating which
-- way the player needs to scroll to bring the target into view. Returns nil
-- if the row is already in view or the data isn't available.
function Highlight:GetCurrencyScrollDirection(currencyID)
    if not TokenFrame or not TokenFrame:IsShown() or not TokenFrame.ScrollBox then return nil end
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return nil end

    local size = C_CurrencyInfo.GetCurrencyListSize()
    local targetIndex
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            targetIndex = i
            break
        end
    end
    if not targetIndex then return nil end

    local minVisible, maxVisible
    if TokenFrame.ScrollBox.EnumerateFrames then
        for _, btn in TokenFrame.ScrollBox:EnumerateFrames() do
            if btn and btn:IsShown() then
                local d = btn.GetElementData and btn:GetElementData()
                if d and d.currencyIndex then
                    if not minVisible or d.currencyIndex < minVisible then minVisible = d.currencyIndex end
                    if not maxVisible or d.currencyIndex > maxVisible then maxVisible = d.currencyIndex end
                end
            end
        end
    end
    if minVisible and targetIndex < minVisible then return "up" end
    if maxVisible and targetIndex > maxVisible then return "down" end
    return nil
end

-- Highlights the currency's row if it's visible right now, otherwise shows a
-- "scroll up/down to find <name>" hint and polls for the row to come into
-- view (when the player mousewheels to it). No ScrollBox method calls --
-- those would taint state and block the protected transfer Confirm call.
-- Looks up a header by name in C_CurrencyInfo's list and returns its info
-- table and index (or nil if not found). Works even when the header is
-- collapsed -- headers are in the iteration; only their sub-items aren't.
local function lookupHeaderInfo(headerName)
    if not headerName or not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return nil end
    local size = C_CurrencyInfo.GetCurrencyListSize()
    local lower = slower(headerName)
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.isHeader and info.name and slower(info.name) == lower then
            return info, i
        end
    end
    return nil
end

-- Direction to scroll to bring a given currencyIndex fully into view.
-- Uses only fully-visible buttons to compute min/max so partially-clipped
-- targets correctly return "up"/"down" instead of nil.
local function directionToIndex(targetIndex)
    if not targetIndex then return nil end
    if not (TokenFrame and TokenFrame.ScrollBox and TokenFrame.ScrollBox.EnumerateFrames) then return nil end
    local minVisible, maxVisible
    for _, btn in TokenFrame.ScrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and isButtonFullyVisible(btn) then
            local d = btn.GetElementData and btn:GetElementData()
            if d and d.currencyIndex then
                if not minVisible or d.currencyIndex < minVisible then minVisible = d.currencyIndex end
                if not maxVisible or d.currencyIndex > maxVisible then maxVisible = d.currencyIndex end
            end
        end
    end
    if minVisible and targetIndex < minVisible then return "up" end
    if maxVisible and targetIndex > maxVisible then return "down" end
    return nil
end

-- Setter consumed by the next call to HighlightCurrencyRowOrHint; used by
-- the right-click "Transfer" flow to keep the currency-row highlight
-- persistent (no hover-dismiss) because clicking the row is just an
-- intermediate step toward the Transfer button on the popup.
function Highlight:SetPersistentCurrencyHighlight(persistent)
    self._persistentCurrencyHighlight = persistent and true or nil
end

function Highlight:HighlightCurrencyRowOrHint(currencyID, expectedHeaderChain)
    if not TokenFrame or not TokenFrame:IsVisible() then return end

    local persistent = self._persistentCurrencyHighlight
    self._persistentCurrencyHighlight = nil

    local function watchForHover(frame)
        local attempts = 0
        local function checkHover()
            if not frame:IsShown() then return end
            if frame:IsMouseOver() then
                self:HideHighlight()
                return
            end
            attempts = attempts + 1
            if attempts < 100 then
                Utils.SafeAfter(0.1, checkHover)
            end
        end
        Utils.SafeAfter(0.3, checkHover)
    end

    -- Header-target mode: no currencyID, so the LAST header in the chain
    -- is the destination, and the parents to walk for blockers are the
    -- preceding entries. Row-target mode: the entire chain is parents.
    local targetHeaderName
    local parentChain = expectedHeaderChain
    if not currencyID and expectedHeaderChain and #expectedHeaderChain > 0 then
        targetHeaderName = expectedHeaderChain[#expectedHeaderChain]
        parentChain = {}
        for i = 1, #expectedHeaderChain - 1 do
            parentChain[i] = expectedHeaderChain[i]
        end
    end

    local lastKind, lastTarget
    local function applyState()
        if currencyID then
            local row = self:GetCurrencyRowButton(currencyID)
            if row then
                if lastKind ~= "target" or lastTarget ~= row then
                    self:HideScrollHint()
                    self:HighlightFrame(row, nil, nil, persistent)
                    if not persistent then watchForHover(row) end
                    lastKind, lastTarget = "target", row
                end
                return "done"
            end
        elseif targetHeaderName then
            local btn = self:FindVisibleCurrencyHeaderButton(targetHeaderName)
            if btn then
                if lastKind ~= "target" or lastTarget ~= btn then
                    self:HideScrollHint()
                    self:HighlightFrame(btn, nil, nil, persistent)
                    if not persistent then watchForHover(btn) end
                    lastKind, lastTarget = "target", btn
                end
                return "done"
            end
        end

        local blocker
        if parentChain then
            for _, name in ipairs(parentChain) do
                local info = lookupHeaderInfo(name)
                if info and not info.isHeaderExpanded then
                    blocker = info
                    break
                end
            end
        end
        if not blocker and currencyID then
            local fallback = self:GetCurrencyHeaderForCurrency(currencyID)
            if fallback and not fallback.isHeaderExpanded then
                blocker = fallback
            end
        end

        if blocker then
            local btn = self:FindVisibleCurrencyHeaderButton(blocker.name)
            if btn then
                if lastKind ~= "header" or lastTarget ~= btn then
                    self:HideScrollHint()
                    self:HighlightFrame(btn, nil, nil, true)
                    lastKind, lastTarget = "header", btn
                end
                return "wait"
            end
            local _, blockerIndex = lookupHeaderInfo(blocker.name)
            local direction = directionToIndex(blockerIndex) or "down"
            if lastKind ~= "scroll" or lastTarget ~= direction then
                self:HideHighlight()
                self:ShowScrollHint(direction)
                lastKind, lastTarget = "scroll", direction
            end
            return "wait"
        end

        local direction
        if currencyID then
            direction = self:GetCurrencyScrollDirection(currencyID) or "down"
        elseif targetHeaderName then
            local _, idx = lookupHeaderInfo(targetHeaderName)
            direction = directionToIndex(idx) or "down"
        else
            direction = "down"
        end
        if lastKind ~= "scroll" or lastTarget ~= direction then
            self:HideHighlight()
            self:ShowScrollHint(direction)
            lastKind, lastTarget = "scroll", direction
        end
        return "wait"
    end

    if applyState() == "done" then return end

    local ticks = 0
    local pollTicker
    pollTicker = C_Timer.NewTicker(0.2, function()
        local ok = xpcall(function()
            ticks = ticks + 1
            if ticks > 150 then
                if pollTicker then pollTicker:Cancel(); pollTicker = nil end
                self:HideScrollHint()
                self:HideHighlight()
                return
            end
            if not (TokenFrame and TokenFrame:IsVisible()) then
                if pollTicker then pollTicker:Cancel(); pollTicker = nil end
                self:HideScrollHint()
                self:HideHighlight()
                return
            end
            if applyState() == "done" then
                if pollTicker then pollTicker:Cancel(); pollTicker = nil end
            end
        end, ErrorHandler)
        if not ok then
            if pollTicker then pollTicker:Cancel(); pollTicker = nil end
            self:HideScrollHint()
            self:HideHighlight()
        end
    end)
end

function Highlight:GetCurrencyRowButton(currencyID)
    if not TokenFrame or not TokenFrame:IsShown() then return nil end
    if not TokenFrame.ScrollBox then return nil end

    local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(currencyID)
    return ScrollBoxFindButton(TokenFrame.ScrollBox, function(btn)
        local data = btn.GetElementData and btn:GetElementData()
        if data then
            if data.currencyID == currencyID then return true end
            if data.currencyIndex then
                local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo(data.currencyIndex)
                if info and not info.isHeader and info.currencyID == currencyID then return true end
            end
        end
        if currencyInfo and currencyInfo.name then
            local text = GetButtonText(btn)
            if text and slower(text) == slower(currencyInfo.name) then return true end
        end
        return false
    end)
end

-- Returns true (expanded), false (collapsed), nil (parent collapsed).
function Highlight:IsFactionHeaderExpanded(headerName)
    if not C_Reputation or not C_Reputation.GetNumFactions then return nil end

    local headerNameLower = slower(headerName)
    local numFactions = C_Reputation.GetNumFactions()

    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
            if factionData.isHeaderExpanded ~= nil then
                return factionData.isHeaderExpanded
            elseif factionData.isCollapsed ~= nil then
                return not factionData.isCollapsed
            end
            return true
        end
    end
    return nil
end

function Highlight:GetFactionHeaderButton(headerName)
    if not ReputationFrame or not ReputationFrame:IsShown() then return nil end

    local headerNameLower = slower(headerName)

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
    if not targetIndex then return nil end

    if ReputationFrame.ScrollBox then
        ScrollBoxScrollTo(ReputationFrame.ScrollBox, function(data)
            return data and data.factionIndex == targetIndex
        end)
        return ScrollBoxFindButton(ReputationFrame.ScrollBox, function(btn)
            local elementData = btn.elementData or (btn.GetElementData and btn:GetElementData())
            if elementData and elementData.factionIndex == targetIndex then return true end
            local text = GetButtonText(btn)
            return text and slower(text) == headerNameLower
        end)
    end

    return nil
end

function Highlight:ScrollToFactionRow(factionID)
    if not ReputationFrame or not ReputationFrame:IsShown() then return end
    if not ReputationFrame.ScrollBox then return end
    if not C_Reputation or not C_Reputation.GetNumFactions then return end

    local numFactions = C_Reputation.GetNumFactions()
    local targetIndex = nil
    for i = 1, numFactions do
        local factionData = C_Reputation.GetFactionDataByIndex(i)
        if factionData and factionData.factionID == factionID then
            targetIndex = i
            break
        end
    end
    if not targetIndex then return end

    local fraction = (targetIndex - 1) / mmax(1, numFactions - 1)
    ScrollBoxScrollTo(ReputationFrame.ScrollBox, function(data)
        if not data then return false end
        if data.factionID == factionID then return true end
        if data.factionIndex == targetIndex then return true end
        return false
    end, fraction)
end

function Highlight:GetFactionRowButton(factionID)
    if not ReputationFrame or not ReputationFrame:IsShown() then return nil end
    if not ReputationFrame.ScrollBox then return nil end

    local factionNameLower = nil
    if C_Reputation and C_Reputation.GetNumFactions then
        local numFactions = C_Reputation.GetNumFactions()
        for i = 1, numFactions do
            local factionData = C_Reputation.GetFactionDataByIndex(i)
            if factionData and factionData.factionID == factionID and factionData.name then
                factionNameLower = slower(factionData.name)
                break
            end
        end
    end

    return ScrollBoxFindButton(ReputationFrame.ScrollBox, function(btn)
        local data = btn.GetElementData and btn:GetElementData()
        if data then
            if data.factionID == factionID then return true end
            if data.factionIndex then
                local indexFaction = C_Reputation and C_Reputation.GetFactionDataByIndex(data.factionIndex)
                if indexFaction and indexFaction.factionID == factionID then return true end
            end
        end
        if factionNameLower then
            local text = GetButtonText(btn)
            if text and slower(text) == factionNameLower then return true end
        end
        return false
    end)
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

    self:NotifyClearButton()
end
