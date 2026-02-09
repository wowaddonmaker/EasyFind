local ADDON_NAME, ns = ...

local UI = {}
ns.UI = UI

local Utils = ns.Utils
local GetButtonText    = Utils.GetButtonText
local SearchFrameTree  = Utils.SearchFrameTree
local DebugPrint       = Utils.DebugPrint
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local tinsert, tsort, tconcat = Utils.tinsert, Utils.tsort, Utils.tconcat
local mmin, mmax = Utils.mmin, Utils.mmax

local searchFrame
local resultsFrame
local toggleBtn
local resultButtons = {}
local MAX_RESULTS = 12
local inCombat = false

function UI:Initialize()
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    self:CreateToggleButton()
    self:RegisterCombatEvents()
    
    if EasyFind.db.visible ~= false then
        searchFrame:Show()
        toggleBtn:Hide()
    else
        searchFrame:Hide()
        toggleBtn:Show()
    end
    
    -- Check if already in combat
    inCombat = InCombatLockdown()
    if inCombat then
        searchFrame:Hide()
        toggleBtn:Hide()
    end
end

function UI:RegisterCombatEvents()
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    ns.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    ns.eventFrame:HookScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            inCombat = true
            searchFrame:Hide()
            toggleBtn:Hide()
            UI:HideResults()
            searchFrame.editBox:ClearFocus()
        elseif event == "PLAYER_REGEN_ENABLED" then
            inCombat = false
            if EasyFind.db.visible ~= false then
                searchFrame:Show()
                toggleBtn:Hide()
            else
                toggleBtn:Show()
            end
        end
    end)
end

function UI:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "EasyFindSearchFrame", UIParent, "BackdropTemplate")
    searchFrame:SetSize(280, 36)
    searchFrame:SetFrameStrata("HIGH")
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetClampedToScreen(true)
    
    -- Apply saved position or default
    if EasyFind.db.uiSearchPosition then
        local pos = EasyFind.db.uiSearchPosition
        searchFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -5)
    end
    
    searchFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    
    -- Search icon
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(16, 16)
    searchIcon:SetPoint("LEFT", searchFrame, "LEFT", 12, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    
    -- Editbox
    local editBox = CreateFrame("EditBox", "EasyFindSearchBox", searchFrame)
    editBox:SetSize(175, 20)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)
    
    local placeholder = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search your UI here...")
    editBox.placeholder = placeholder
    
    editBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
    end)
    
    editBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
        end
    end)
    
    editBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        UI:OnSearchTextChanged(self:GetText())
    end)
    
    editBox:SetScript("OnEnterPressed", function(self)
        UI:SelectFirstResult()
    end)
    
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
        UI:HideResults()
    end)
    
    -- Hide button
    local hideBtn = CreateFrame("Button", nil, searchFrame, "UIPanelButtonTemplate")
    hideBtn:SetSize(40, 20)
    hideBtn:SetPoint("RIGHT", searchFrame, "RIGHT", -8, 0)
    hideBtn:SetText("Hide")
    hideBtn:SetScript("OnClick", function()
        UI:Hide()
    end)
    
    -- Clear highlights button (red X)
    local clearBtn = CreateFrame("Button", "EasyFindClearButton", searchFrame)
    clearBtn:SetSize(20, 20)
    clearBtn:SetPoint("RIGHT", hideBtn, "LEFT", -2, 0)
    clearBtn:EnableMouse(true)
    clearBtn:SetFrameLevel(searchFrame:GetFrameLevel() + 10)
    
    -- Use a simple red X texture
    local normalTex = clearBtn:CreateTexture(nil, "ARTWORK")
    normalTex:SetAllPoints()
    normalTex:SetTexture("Interface\\Buttons\\UI-StopButton")
    normalTex:SetVertexColor(1, 0.3, 0.3, 1)
    clearBtn:SetNormalTexture(normalTex)
    
    local highlightTex = clearBtn:CreateTexture(nil, "HIGHLIGHT")
    highlightTex:SetAllPoints()
    highlightTex:SetTexture("Interface\\Buttons\\UI-StopButton")
    highlightTex:SetVertexColor(1, 0.5, 0.5, 1)
    highlightTex:SetBlendMode("ADD")
    clearBtn:SetHighlightTexture(highlightTex)
    
    clearBtn:SetScript("OnClick", function()
        if ns.Highlight then
            ns.Highlight:Cancel()
            print("|cFF00FF00EasyFind:|r Highlights cleared.")
        end
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Clear all active highlights", 1, 1, 1)
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", GameTooltip_Hide)
    
    searchFrame.editBox = editBox
    searchFrame.clearBtn = clearBtn
    
    -- Draggable with Shift key
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self:StartMoving()
        end
    end)
    searchFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, relPoint, x, y = self:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
    end)
    
    -- Apply saved scale
    self:UpdateScale()
    self:UpdateOpacity()
end

function UI:CreateToggleButton()
    toggleBtn = CreateFrame("Button", "EasyFindToggleButton", UIParent, "BackdropTemplate")
    toggleBtn:SetSize(28, 28)
    toggleBtn:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -5)
    toggleBtn:SetFrameStrata("HIGH")
    
    toggleBtn:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    
    local icon = toggleBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    
    toggleBtn:SetScript("OnClick", function()
        UI:Show()
    end)
    
    toggleBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("EasyFind - UI Search")
        GameTooltip:AddLine("Click to search for UI elements", 1, 1, 1)
        GameTooltip:Show()
    end)
    
    toggleBtn:SetScript("OnLeave", GameTooltip_Hide)
    toggleBtn:Hide()
end

function UI:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", searchFrame, "BackdropTemplate")
    resultsFrame:SetWidth(320)  -- Wider to accommodate indentation
    resultsFrame:SetPoint("TOP", searchFrame, "BOTTOM", 0, -2)
    resultsFrame:SetFrameStrata("HIGH")
    resultsFrame:SetFrameLevel(searchFrame:GetFrameLevel() + 1)
    
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    
    resultsFrame:Hide()
    
    for i = 1, MAX_RESULTS do
        local btn = self:CreateResultButton(i)
        resultButtons[i] = btn
    end
end

-- Vibrant indent line colors for each depth level
local INDENT_COLORS = {
    {0.40, 0.85, 1.00, 0.80},   -- cyan
    {1.00, 0.55, 0.10, 0.80},   -- orange
    {0.55, 1.00, 0.35, 0.80},   -- lime green
    {1.00, 0.40, 0.70, 0.80},   -- pink
    {0.70, 0.55, 1.00, 0.80},   -- lavender
    {1.00, 0.90, 0.20, 0.80},   -- yellow
}

function UI:CreateResultButton(index)
    local btn = CreateFrame("Button", "EasyFindResultButton"..index, resultsFrame)
    btn:SetSize(300, 22)
    btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, -8 - (index - 1) * 22)
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    -- Create indent line textures (one per possible depth level)
    btn.indentLines = {}
    for d = 1, #INDENT_COLORS do
        local line = btn:CreateTexture(nil, "BACKGROUND")
        line:SetColorTexture(INDENT_COLORS[d][1], INDENT_COLORS[d][2], INDENT_COLORS[d][3], INDENT_COLORS[d][4])
        line:SetWidth(2)
        line:SetPoint("TOP", btn, "TOPLEFT", (d - 1) * 12 + 5, 2)
        line:SetPoint("BOTTOM", btn, "BOTTOMLEFT", (d - 1) * 12 + 5, -2)
        line:Hide()
        btn.indentLines[d] = line
    end
    
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 0, 0)
    btn.icon = icon
    
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
    text:SetJustifyH("LEFT")
    btn.text = text
    
    btn:SetScript("OnClick", function(self)
        if self.data and not self.isPathNode then
            UI:SelectResult(self.data)
        end
    end)
    
    btn:Hide()
    return btn
end

function UI:OnSearchTextChanged(text)
    local results = ns.Database:SearchUI(text)
    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    self:ShowHierarchicalResults(hierarchical)
end

-- Helper function to get icon from a button frame
local function GetButtonIcon(frameName)
    local frame = _G[frameName]
    if not frame then return nil end
    
    -- For MicroButtons - use the textureName property to build atlas
    -- Atlas format: "UI-HUD-MicroMenu-<textureName>-Up"
    if frame.textureName then
        local atlas = "UI-HUD-MicroMenu-" .. frame.textureName .. "-Up"
        return atlas, true -- true means it's an atlas
    end
    
    -- Try common icon region names
    local iconRegions = {"Icon", "icon", "NormalTexture", "normalTexture"}
    for _, regionName in ipairs(iconRegions) do
        local region = frame[regionName]
        if region and region.GetTexture then
            local texture = region:GetTexture()
            if texture then
                return texture
            end
        end
    end
    
    -- Fallback: iterate through regions
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            if texture and type(texture) == "number" then
                return texture
            end
        end
    end
    
    return nil
end

function UI:ShowHierarchicalResults(hierarchical)
    if not hierarchical or #hierarchical == 0 then
        self:HideResults()
        return
    end
    
    local count = mmin(#hierarchical, MAX_RESULTS)
    local INDENT_SIZE = 12
    
    for i = 1, MAX_RESULTS do
        local btn = resultButtons[i]
        if i <= count then
            local entry = hierarchical[i]
            local data = entry.data
            local depth = entry.depth or 0
            
            btn.data = data
            btn.isPathNode = entry.isPathNode
            
            -- Show/hide vertical indent lines for each depth level
            for d = 1, #INDENT_COLORS do
                if d <= depth then
                    btn.indentLines[d]:Show()
                else
                    btn.indentLines[d]:Hide()
                end
            end
            
            -- Move icon based on depth (indent icon with the text)
            local indentPixels = depth * 12
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("LEFT", btn, "LEFT", indentPixels, 0)
            
            btn.text:SetText(entry.name)
            
            -- Style: gray for path nodes, gold for actual results
            if entry.isPathNode then
                btn.text:SetTextColor(0.5, 0.5, 0.5)
            else
                btn.text:SetTextColor(1, 0.82, 0)
            end
            
            -- Set icon
            local iconSet = false
            if data and data.buttonFrame then
                local texture, isAtlas = GetButtonIcon(data.buttonFrame)
                if texture then
                    if isAtlas then
                        btn.icon:SetAtlas(texture)
                    else
                        btn.icon:SetTexture(texture)
                    end
                    btn.icon:Show()
                    iconSet = true
                end
            end
            
            if not iconSet and data and data.icon then
                btn.icon:SetTexture(data.icon)
                btn.icon:Show()
                iconSet = true
            end
            
            if not iconSet then
                if entry.isPathNode then
                    btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Folder_01") -- Folder icon
                else
                    btn.icon:SetTexture(134400)
                end
                btn.icon:Show()
            end
            
            btn:Show()
        else
            btn:Hide()
            -- Hide all indent lines on hidden buttons
            if btn.indentLines then
                for d = 1, #INDENT_COLORS do
                    btn.indentLines[d]:Hide()
                end
            end
        end
    end
    
    resultsFrame:SetHeight(16 + count * 22)
    resultsFrame:Show()
end

function UI:ShowResults(results)
    -- Legacy function, redirects to hierarchical
    local hierarchical = ns.Database:BuildHierarchicalResults(results)
    self:ShowHierarchicalResults(hierarchical)
end

function UI:HideResults()
    resultsFrame:Hide()
end

function UI:SelectFirstResult()
    -- Only select if results are visible and there's actual data
    if resultsFrame:IsShown() and resultButtons[1]:IsShown() and resultButtons[1].data then
        self:SelectResult(resultButtons[1].data)
    end
end

function UI:SelectResult(data)
    searchFrame.editBox:SetText("")
    searchFrame.editBox:ClearFocus()
    self:HideResults()
    
    if not data then return end
    
    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end
    
    -- Check if direct open is enabled
    if EasyFind.db.directOpen and data.steps then
        -- Portrait menu entries can't be automated (secure frame restriction) - always use guide mode
        local hasPortraitMenu = false
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                hasPortraitMenu = true
                break
            end
        end
        
        if hasPortraitMenu then
            EasyFind:StartGuide(data)
        else
            -- Direct open mode - execute the navigation directly
            self:DirectOpen(data)
        end
    elseif data.steps then
        -- Step-by-step guide mode
        EasyFind:StartGuide(data)
    end
end

-- Direct open mode - programmatically navigates to the target as far as possible.
-- Executes ALL steps that represent clickable navigation (tabs, categories, buttons).
-- Only falls back to highlighting when the final step is a non-navigable UI region
-- that the user needs to visually locate (e.g. PvP Talents tray, War Mode button).
function UI:DirectOpen(data)
    if not data or not data.steps or #data.steps == 0 then return end

    local steps = data.steps
    local totalSteps = #steps
    local Highlight = ns.Highlight

    -- Determine whether a step is "navigable" (can be auto-executed) vs "highlight-only"
    -- (just points at a UI region the user needs to see).
    -- A step is navigable if it has any clickable action property.
    local function isStepNavigable(step)
        if step.buttonFrame then return true end
        if step.tabIndex then return true end
        if step.sideTabIndex then return true end
        if step.pvpSideTabIndex then return true end
        if step.sidebarButtonFrame or step.sidebarIndex then return true end
        if step.statisticsCategory then return true end
        if step.achievementCategory then return true end
        if step.currencyHeader then return true end
        if step.currencyID then return true end
        if step.searchButtonText then return true end
        if step.portraitMenuOption then return true end
        -- regionFrames alone (no searchButtonText) = highlight-only (e.g. PvP Talents)
        -- waitForFrame alone = just waiting for a frame to appear, not navigable
        -- text alone = instruction text, not navigable
        return false
    end

    local lastStep = steps[totalSteps]
    local finalStepNavigable = isStepNavigable(lastStep)

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

    local function executeStep(stepIndex)
        -- Done executing — either finished completely or hand off to highlight
        if stepIndex > executeCount then
            if not finalStepNavigable then
                -- Final step is highlight-only — show it to the user
                C_Timer.After(0.15, function()
                    if Highlight then
                        Highlight:StartGuideAtStep(data, totalSteps)
                    end
                end)
            end
            -- If final step was navigable, we already executed it — nothing more to do
            return
        end

        local step = steps[stepIndex]
        local nextDelay = 0.1

        -- Click a micro menu button (like LFDMicroButton, CharacterMicroButton, etc.)
        if step.buttonFrame then
            local btn = _G[step.buttonFrame]
            if btn then
                if btn.Click then
                    btn:Click()
                elseif btn:GetScript("OnClick") then
                    btn:GetScript("OnClick")(btn)
                end
            end
            nextDelay = 0.15
        end

        -- Click a main tab (Dungeons & Raids / Player vs. Player / etc.)
        if step.waitForFrame and step.tabIndex then
            local tabBtn = Highlight:GetTabButton(step.waitForFrame, step.tabIndex)
            if tabBtn and tabBtn.Click then
                tabBtn:Click()
            elseif tabBtn and tabBtn:GetScript("OnClick") then
                tabBtn:GetScript("OnClick")(tabBtn, "LeftButton")
            end
            nextDelay = 0.15
        end

        -- Click a PvE side tab (Dungeon Finder / Raid Finder / Premade Groups)
        if step.sideTabIndex then
            C_Timer.After(0.05, function()
                local sideBtn = Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex)
                if sideBtn then
                    if sideBtn.Click then
                        sideBtn:Click()
                    elseif sideBtn:GetScript("OnClick") then
                        sideBtn:GetScript("OnClick")(sideBtn, "LeftButton")
                    end
                end
            end)
            nextDelay = 0.2
        end

        -- Click a PvP side tab (Quick Match / Rated / Premade Groups / Training Grounds)
        if step.pvpSideTabIndex then
            C_Timer.After(0.05, function()
                local pvpBtn = Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex)
                if pvpBtn then
                    if pvpBtn.Click then
                        pvpBtn:Click()
                    elseif pvpBtn:GetScript("OnClick") then
                        pvpBtn:GetScript("OnClick")(pvpBtn, "LeftButton")
                    end
                end
            end)
            nextDelay = 0.2
        end

        -- Click a Character Frame sidebar tab
        if step.sidebarButtonFrame or step.sidebarIndex then
            self:ClickCharacterSidebar(step.sidebarIndex)
            nextDelay = 0.15
        end

        -- Click a statistics category
        if step.statisticsCategory then
            self:ClickStatisticsCategory(step.statisticsCategory)
            nextDelay = 0.3
        end

        -- Click an achievement category
        if step.achievementCategory then
            self:ClickAchievementCategory(step.achievementCategory)
            nextDelay = 0.3
        end

        -- Expand a currency header
        if step.currencyHeader then
            self:ExpandCurrencyHeader(step.currencyHeader)
            nextDelay = 0.2
        end

        -- Scroll to a currency
        if step.currencyID then
            self:ScrollToCurrency(step.currencyID)
            nextDelay = 0.2
        end

        -- Click a button found by text search (Premade Groups categories, PvP queue buttons, etc.)
        if step.searchButtonText then
            C_Timer.After(0.05, function()
                local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
                local searchText = slower(step.searchButtonText)
                -- Search within the relevant parent frame
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    local btn = SearchFrameTreeFuzzy(parentFrame, searchText)
                    if btn then
                        if btn.Click then
                            btn:Click()
                        elseif btn.GetScript and btn:GetScript("OnClick") then
                            btn:GetScript("OnClick")(btn, "LeftButton")
                        end
                    end
                end
            end)
            nextDelay = 0.3
        end

        -- Chain to the next step after a delay
        C_Timer.After(nextDelay, function()
            executeStep(stepIndex + 1)
        end)
    end

    -- Start executing from step 1
    executeStep(1)
end

-- Helper function to click Character Frame sidebar buttons
function UI:ClickCharacterSidebar(sidebarIndex)
    -- The sidebar buttons are PaperDollSidebarTab1/2/3 inside PaperDollSidebarTabs
    -- (confirmed via Frame Inspector)
    
    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end
    
    -- Ensure we're on the Character tab (tab 1) first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(CharacterFrame) ~= 1 then
        local tabBtn = _G["CharacterFrameTab1"]
        if tabBtn and tabBtn.Click then
            tabBtn:Click()
        end
    end
    
    -- Method 1: Try PaperDollSidebarTab buttons directly (Frame Inspector confirmed names)
    local sidebarTabName = "PaperDollSidebarTab" .. sidebarIndex
    local sidebarTab = _G[sidebarTabName]
    if sidebarTab then
        if sidebarTab:IsShown() then
            if sidebarTab.Click then
                sidebarTab:Click()
                return true
            elseif sidebarTab:GetScript("OnClick") then
                sidebarTab:GetScript("OnClick")(sidebarTab, "LeftButton")
                return true
            end
        else
            -- Tab exists but isn't shown yet - try after a brief delay
            C_Timer.After(0.2, function()
                if sidebarTab:IsShown() then
                    if sidebarTab.Click then
                        sidebarTab:Click()
                    elseif sidebarTab:GetScript("OnClick") then
                        sidebarTab:GetScript("OnClick")(sidebarTab, "LeftButton")
                    end
                end
            end)
            return true
        end
    end
    
    -- Method 2: Search PaperDollSidebarTabs container children by index
    local sidebarTabs = _G["PaperDollSidebarTabs"]
    if not sidebarTabs and PaperDollFrame then
        sidebarTabs = PaperDollFrame.SidebarTabs
    end
    if sidebarTabs then
        local nTabs = select("#", sidebarTabs:GetChildren())
        if sidebarIndex <= nTabs then
            local tab = select(sidebarIndex, sidebarTabs:GetChildren())
            if tab then
                if tab.Click then
                    tab:Click()
                    return true
                elseif tab:GetScript("OnClick") then
                    tab:GetScript("OnClick")(tab, "LeftButton")
                    return true
                end
            end
        end
    end
    
    -- Method 3: Try the ToggleSidebarTab function if available
    if PaperDollFrame and PaperDollFrame.ToggleSidebarTab then
        PaperDollFrame:ToggleSidebarTab(sidebarIndex)
        return true
    end
    
    return false
end

-- Helper function to find and click a statistics category button
function UI:ClickStatisticsCategory(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    
    local categoryNameLower = slower(categoryName)
    
    -- Helper to click a button
    local function tryClick(btn)
        if btn.Click then
            btn:Click()
            return true
        elseif btn.GetScript and btn:GetScript("OnClick") then
            btn:GetScript("OnClick")(btn, "LeftButton")
            return true
        end
        return false
    end
    
    -- Primary: use the data provider to find the category and select it via Blizzard API
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if dataProvider then
            local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
            if finder then
                local elementData = finder(dataProvider, function(data)
                    if not data then return false end
                    local catID = data.id
                    if not catID or type(catID) ~= "number" then return false end
                    if GetCategoryInfo then
                        local title = GetCategoryInfo(catID)
                        if title and slower(title) == categoryNameLower then return true end
                    end
                    return false
                end)
                if elementData then
                    -- Try Blizzard's official selection function
                    if AchievementFrameCategories_SelectElementData then
                        AchievementFrameCategories_SelectElementData(elementData)
                        return true
                    end
                    -- Fallback: scroll to it and click the visible button
                    scrollBox:ScrollToElementData(elementData)
                    local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
                    if frame and tryClick(frame) then return true end
                end
            end
        end
        
    end
    
    return false
end

-- Helper function to click an achievement category button (works on any Achievement tab)
function UI:ClickAchievementCategory(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end
    
    local categoryNameLower = slower(categoryName)
    
    -- Helper to click a button
    local function tryClick(btn)
        if btn.Click then
            btn:Click()
            return true
        elseif btn.GetScript and btn:GetScript("OnClick") then
            btn:GetScript("OnClick")(btn, "LeftButton")
            return true
        end
        return false
    end
    
    -- Primary: use the data provider to find the category and select it via Blizzard API
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if dataProvider then
            local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
            if finder then
                local elementData = finder(dataProvider, function(data)
                    if not data then return false end
                    local catID = data.id
                    if not catID or type(catID) ~= "number" then return false end
                    if GetCategoryInfo then
                        local title = GetCategoryInfo(catID)
                        if title and slower(title) == categoryNameLower then return true end
                    end
                    return false
                end)
                if elementData then
                    -- Expand parent if hidden
                    if elementData.hidden and elementData.id and AchievementFrameCategories_ExpandToCategory then
                        AchievementFrameCategories_ExpandToCategory(elementData.id)
                        if AchievementFrameCategories_UpdateDataProvider then
                            AchievementFrameCategories_UpdateDataProvider()
                        end
                        -- Re-find after expanding
                        elementData = finder(dataProvider, function(data)
                            if not data then return false end
                            local catID = data.id
                            if not catID or type(catID) ~= "number" then return false end
                            if GetCategoryInfo then
                                local title = GetCategoryInfo(catID)
                                if title and slower(title) == categoryNameLower then return true end
                            end
                            return false
                        end)
                        if not elementData then return false end
                    end
                    -- Try Blizzard's official selection function
                    if AchievementFrameCategories_SelectElementData then
                        AchievementFrameCategories_SelectElementData(elementData)
                        return true
                    end
                    -- Fallback: scroll to it and click the visible button
                    scrollBox:ScrollToElementData(elementData)
                    local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
                    if frame and tryClick(frame) then return true end
                end
            end
        end
        
    end
    
    return false
end

-- Helper function to click a side tab (PvE Group Finder tabs)
-- Helper to extract text from various button types
function UI:GetButtonText(frame)
    return GetButtonText(frame)
end

function UI:Show()
    if inCombat then return end
    searchFrame:Show()
    toggleBtn:Hide()
    searchFrame.editBox:SetFocus()
    EasyFind.db.visible = true
end

function UI:Hide()
    searchFrame:Hide()
    if not inCombat then
        toggleBtn:Show()
    end
    self:HideResults()
    searchFrame.editBox:ClearFocus()
    EasyFind.db.visible = false
end

-- Helper function to expand a currency header by name
function UI:ExpandCurrencyHeader(headerName)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end
    
    local headerNameLower = slower(headerName)
    local size = C_CurrencyInfo.GetCurrencyListSize()
    
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and info.isHeader and info.name and slower(info.name) == headerNameLower then
            if not info.isHeaderExpanded then
                C_CurrencyInfo.ExpandCurrencyList(i, true)
            end
            return true
        end
    end
    return false
end

-- Helper function to scroll to a specific currency by ID
function UI:ScrollToCurrency(currencyID)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return false end
    
    -- The currency list is a flat list; find the index of our target
    local size = C_CurrencyInfo.GetCurrencyListSize()
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and info.currencyID == currencyID then
            -- Found it - try to scroll the TokenFrame to this index
            if TokenFrame and TokenFrame.ScrollBox then
                -- Modern ScrollBox API
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
            return true
        end
    end
    return false
end

-- Helper function to open the player portrait right-click menu
function UI:OpenPortraitMenu()
    if not PlayerFrame then return end
    
    -- Method 1: Modern WoW - PlayerFrame has a dropdown system via PlayerFrameDropDown
    local dropDown = _G["PlayerFrameDropDown"]
    if dropDown then
        if ToggleDropDownMenu then
            ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
            return
        end
    end
    
    -- Method 2: Try the OnClick handler directly (simulates right-click)
    local handler = PlayerFrame:GetScript("OnClick")
    if handler then
        handler(PlayerFrame, "RightButton")
        return
    end
    
    -- Method 3: Try UnitPopup API
    if UnitPopup_ShowMenu then
        UnitPopup_ShowMenu(PlayerFrame, "SELF", "player")
        return
    end
    
    -- Method 4: Modern Menu system
    if PlayerFrame.unit and Menu and Menu.ModifyMenu then
        -- Try to invoke the right-click behavior via secure handler
        if PlayerFrame.ToggleMenu then
            PlayerFrame:ToggleMenu()
        end
    end
end

-- Helper function to click a portrait menu option by name
function UI:ClickPortraitMenuOption(optionName)
    local optionNameLower = slower(optionName)
    
    -- Search through open dropdown frames for the matching button
    -- Modern WoW uses the Menu system
    local function searchFrame(frame, depth)
        if not frame or depth > 5 then return false end
        
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            if child and child:IsShown() then
                -- Check for text on this frame
                local text = nil
                if child.GetText then text = child:GetText() end
                if not text then
                    for j = 1, select("#", child:GetRegions()) do
                        local region = select(j, child:GetRegions())
                        if region and region.GetText then
                            local t = region:GetText()
                            if t then text = t; break end
                        end
                    end
                end
                
                if text and sfind(slower(text), optionNameLower) then
                    if child.Click then
                        child:Click()
                        return true
                    elseif child:GetScript("OnClick") then
                        child:GetScript("OnClick")(child, "LeftButton")
                        return true
                    end
                end
                
                if searchFrame(child, depth + 1) then return true end
            end
        end
        return false
    end
    
    -- Search common dropdown/menu frames
    for i = 1, 5 do
        local dropdown = _G["DropDownList" .. i]
        if dropdown and dropdown:IsShown() then
            if searchFrame(dropdown, 0) then return true end
        end
    end
    
    -- Also check UIParent children for modern menu frames
    for i = 1, select("#", UIParent:GetChildren()) do
        local child = select(i, UIParent:GetChildren())
        if child and child:IsShown() then
            local strata = child:GetFrameStrata()
            if strata == "FULLSCREEN_DIALOG" or strata == "DIALOG" then
                if searchFrame(child, 0) then return true end
            end
        end
    end
    
    return false
end

function UI:Toggle()
    if searchFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function UI:UpdateScale()
    if searchFrame then
        local scale = EasyFind.db.uiSearchScale or 1.0
        searchFrame:SetScale(scale)
        if resultsFrame then
            resultsFrame:SetScale(scale)
        end
    end
end

function UI:UpdateOpacity()
    if searchFrame then
        local alpha = EasyFind.db.searchBarOpacity or 1.0
        searchFrame:SetAlpha(alpha)
    end
end

function UI:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOP", UIParent, "TOP", 0, -5)
        EasyFind.db.uiSearchPosition = nil
    end
end

-- Flash a label on the search frame (used for Currency hint)
function UI:FlashLabel(labelText)
    if not searchFrame or not searchFrame.label then return end
    
    local label = searchFrame.label
    local originalText = label:GetText()
    local originalR, originalG, originalB = label:GetTextColor()
    
    -- Set to the hint text
    label:SetText(labelText)
    label:SetTextColor(1, 0.82, 0)  -- Gold color
    
    -- Create flash animation
    local flashCount = 0
    local ticker
    ticker = C_Timer.NewTicker(0.3, function()
        flashCount = flashCount + 1
        if flashCount % 2 == 0 then
            label:SetTextColor(1, 0.82, 0)
        else
            label:SetTextColor(1, 1, 1)
        end
        
        if flashCount >= 6 then
            -- Restore original
            label:SetText(originalText)
            label:SetTextColor(originalR, originalG, originalB)
            ticker:Cancel()
        end
    end)
end
