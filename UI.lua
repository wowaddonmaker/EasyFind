local ADDON_NAME, ns = ...

local UI = {}
ns.UI = UI

local searchFrame
local resultsFrame
local toggleBtn
local resultButtons = {}
local MAX_RESULTS = 8
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
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:SetScript("OnEvent", function(self, event)
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

function UI:CreateResultButton(index)
    local btn = CreateFrame("Button", "EasyFindResultButton"..index, resultsFrame)
    btn:SetSize(300, 22)
    btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, -8 - (index - 1) * 22)
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
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
    local regions = {frame:GetRegions()}
    for _, region in ipairs(regions) do
        if region:GetObjectType() == "Texture" then
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
    
    local count = math.min(#hierarchical, MAX_RESULTS)
    local INDENT_SIZE = 12
    
    for i = 1, MAX_RESULTS do
        local btn = resultButtons[i]
        if i <= count then
            local entry = hierarchical[i]
            local data = entry.data
            local depth = entry.depth or 0
            
            btn.data = data
            btn.isPathNode = entry.isPathNode
            
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
        -- Direct open mode - execute the navigation directly
        self:DirectOpen(data)
    elseif data.steps then
        -- Step-by-step guide mode
        EasyFind:StartGuide(data)
    end
end

-- Direct open mode - immediately opens the target panel
function UI:DirectOpen(data)
    if not data or not data.steps then return end
    
    -- Collect all steps and their delays
    local delay = 0
    
    -- Execute each step's action directly with proper sequencing
    for stepIndex, step in ipairs(data.steps) do
        local currentDelay = delay
        
        if step.buttonFrame then
            C_Timer.After(currentDelay, function()
                local btn = _G[step.buttonFrame]
                if btn and btn.Click then
                    btn:Click()
                elseif btn and btn:GetScript("OnClick") then
                    btn:GetScript("OnClick")(btn)
                end
            end)
            delay = delay + 0.1
        end
        
        if step.waitForFrame and step.tabIndex then
            C_Timer.After(currentDelay + 0.05, function()
                local frameName = step.waitForFrame
                local tabIndex = step.tabIndex
                local frame = _G[frameName]
                if frame then
                    -- Try to click the tab
                    local tabBtn = _G[frameName .. "Tab" .. tabIndex]
                    if tabBtn and tabBtn.Click then
                        tabBtn:Click()
                    elseif PanelTemplates_SetTab then
                        PanelTemplates_SetTab(frame, tabIndex)
                    end
                end
            end)
            delay = delay + 0.15
        end
        
        -- Statistics category navigation (tree-based category selection in Statistics tab)
        if step.statisticsCategory then
            C_Timer.After(currentDelay + 0.15, function()
                self:ClickStatisticsCategory(step.statisticsCategory)
            end)
            delay = delay + 0.3
        end
        
        -- Side tab (like Dungeon Finder / Raid Finder in Group Finder)
        if step.sideTabIndex then
            C_Timer.After(currentDelay + 0.1, function()
                self:ClickSideTab(step.waitForFrame, step.sideTabIndex)
            end)
            delay = delay + 0.15
        end
        
        -- PvP side tab (Quick Match / Rated / Premade / Training in PvP tab)
        if step.pvpSideTabIndex then
            C_Timer.After(currentDelay + 0.1, function()
                self:ClickPvPSideTab(step.waitForFrame, step.pvpSideTabIndex)
            end)
            delay = delay + 0.15
        end
        
        -- Search for a button by text and click it
        if step.searchButtonText then
            C_Timer.After(currentDelay + 0.15, function()
                self:ClickButtonByText(step.searchButtonText)
            end)
            delay = delay + 0.2
        end
    end
end

-- Helper function to find and click a statistics category button
function UI:ClickStatisticsCategory(categoryName)
    if not AchievementFrame or not AchievementFrame:IsShown() then
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
        -- Check fontstrings
        local regions = {btn:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
                local text = region:GetText()
                if text then return text end
            end
        end
        return nil
    end
    
    -- Helper to click a button
    local function tryClick(btn)
        if btn.Click then
            btn:Click()
            return true
        elseif btn:GetScript("OnClick") then
            btn:GetScript("OnClick")(btn, "LeftButton")
            return true
        end
        return false
    end
    
    -- Helper to recursively search frame tree
    local function searchTree(frame, depth)
        if not frame or depth > 5 then return nil end
        
        if frame:IsShown() and frame.IsMouseEnabled and frame:IsMouseEnabled() then
            local text = getButtonText(frame)
            if text and text:lower():find(categoryNameLower) then
                return frame
            end
        end
        
        local children = {frame:GetChildren()}
        for _, child in ipairs(children) do
            local result = searchTree(child, depth + 1)
            if result then return result end
        end
        
        return nil
    end
    
    -- Method 1: Search the entire AchievementFrame tree
    if AchievementFrame then
        local btn = searchTree(AchievementFrame, 0)
        if btn and tryClick(btn) then return true end
    end
    
    -- Method 2: Try AchievementFrameCategories with ScrollBox
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame then
        if categoriesFrame.ScrollBox and categoriesFrame.ScrollBox.EnumerateFrames then
            for _, btn in categoriesFrame.ScrollBox:EnumerateFrames() do
                if btn and btn:IsShown() then
                    local btnText = getButtonText(btn)
                    if btnText and btnText:lower():find(categoryNameLower) then
                        if tryClick(btn) then return true end
                    end
                end
            end
        end
        
        local btn = searchTree(categoriesFrame, 0)
        if btn and tryClick(btn) then return true end
    end
    
    -- Method 3: Try numbered category buttons
    for i = 1, 50 do
        local btn = _G["AchievementFrameCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoriesContainerButton" .. i] or
                    _G["AchievementFrameStatsCategoryButton" .. i] or
                    _G["AchievementFrameCategoryButton" .. i]
        
        if btn and btn:IsShown() then
            local btnText = getButtonText(btn)
            if btnText and btnText:lower():find(categoryNameLower) then
                if tryClick(btn) then return true end
            end
        end
    end
    
    -- Method 4: Try API if available
    if AchievementFrame_SelectStatisticsCategoryByName then
        AchievementFrame_SelectStatisticsCategoryByName(categoryName)
        return true
    end
    
    return false
end

-- Helper function to click a side tab (PvE Group Finder tabs)
function UI:ClickSideTab(frameName, sideTabIndex)
    if frameName == "PVEFrame" then
        local sideButtons = {
            GroupFinderFrame and GroupFinderFrame.DungeonFinderButton,
            GroupFinderFrame and GroupFinderFrame.RaidFinderButton,
            GroupFinderFrame and GroupFinderFrame.LFGListButton,
        }
        local btn = sideButtons[sideTabIndex]
        if btn and btn:IsShown() then
            if btn.Click then
                btn:Click()
            elseif btn:GetScript("OnClick") then
                btn:GetScript("OnClick")(btn, "LeftButton")
            end
        end
    end
end

-- Helper function to click a PvP side tab
function UI:ClickPvPSideTab(frameName, sideTabIndex)
    if frameName == "PVEFrame" then
        if PVPQueueFrame then
            local buttonNames = {
                "HonorButton",
                "ConquestButton",
                "LFGListButton",
                "NewPlayerBrawlButton",
            }
            local btnName = buttonNames[sideTabIndex]
            if btnName then
                local btn = PVPQueueFrame[btnName]
                if btn and btn:IsShown() then
                    if btn.Click then
                        btn:Click()
                    elseif btn:GetScript("OnClick") then
                        btn:GetScript("OnClick")(btn, "LeftButton")
                    end
                    return
                end
            end
            
            -- Fallback: try CategoryButton pattern
            local btn = PVPQueueFrame["CategoryButton" .. sideTabIndex]
            if btn and btn:IsShown() then
                if btn.Click then
                    btn:Click()
                elseif btn:GetScript("OnClick") then
                    btn:GetScript("OnClick")(btn, "LeftButton")
                end
            end
        end
    end
end

-- Helper function to search for and click a button by text
function UI:ClickButtonByText(buttonText)
    if not PVEFrame or not PVEFrame:IsShown() then
        return
    end
    
    local searchText = buttonText:lower()
    
    local function getFrameText(frame)
        if not frame then return nil end
        if frame.Label and frame.Label.GetText then return frame.Label:GetText() end
        if frame.label and frame.label.GetText then return frame.label:GetText() end
        if frame.Text and frame.Text.GetText then return frame.Text:GetText() end
        if frame.text and frame.text.GetText then return frame.text:GetText() end
        if frame.GetText then return frame:GetText() end
        local regions = {frame:GetRegions()}
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
                local text = region:GetText()
                if text then return text end
            end
        end
        return nil
    end
    
    local function searchTree(frame, depth)
        if not frame or depth > 6 then return nil end
        if frame:IsShown() then
            local text = getFrameText(frame)
            if text and text:lower():find(searchText) then
                if frame.Click or (frame.IsMouseEnabled and frame:IsMouseEnabled()) then
                    return frame
                end
            end
        end
        local children = {frame:GetChildren()}
        for _, child in ipairs(children) do
            local result = searchTree(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    
    local btn = searchTree(PVEFrame, 0)
    if btn then
        if btn.Click then
            btn:Click()
        elseif btn:GetScript("OnClick") then
            btn:GetScript("OnClick")(btn, "LeftButton")
        end
    end
end

-- Helper to extract text from various button types
function UI:GetButtonText(btn)
    if not btn then return nil end
    
    -- Try common text patterns
    if btn.label and btn.label.GetText then
        return btn.label:GetText()
    elseif btn.Label and btn.Label.GetText then
        return btn.Label:GetText()
    elseif btn.text and btn.text.GetText then
        return btn.text:GetText()
    elseif btn.Text and btn.Text.GetText then
        return btn.Text:GetText()
    elseif btn.Name and btn.Name.GetText then
        return btn.Name:GetText()
    elseif btn.name and btn.name.GetText then
        return btn.name:GetText()
    elseif btn.GetText then
        return btn:GetText()
    end
    
    -- Iterate through fontstrings
    for _, region in ipairs({btn:GetRegions()}) do
        if region:GetObjectType() == "FontString" and region:GetText() then
            return region:GetText()
        end
    end
    
    return nil
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
