local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local sformat = Utils.sformat

local optionsFrame
local isInitialized = false

-- Helper to create a slider
local function CreateSlider(parent, name, label, minVal, maxVal, step, yOffset, tooltipText)
    local slider = CreateFrame("Slider", "EasyFindOptions" .. name .. "Slider", parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yOffset)
    slider:SetWidth(200)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    
    slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    slider.Text:SetPoint("BOTTOM", slider, "TOP", 0, 5)
    slider.Text:SetText(label)
    
    slider.Low:SetText(sformat("%.0f%%", minVal * 100))
    slider.High:SetText(sformat("%.0f%%", maxVal * 100))
    
    slider.valueText = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    slider.valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    
    slider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(sformat("%.0f%%", value * 100))
    end)
    
    if tooltipText then
        slider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        slider:SetScript("OnLeave", GameTooltip_Hide)
    end
    
    return slider
end

-- Helper to create a checkbox
local function CreateCheckbox(parent, name, label, yOffset, tooltipText)
    local checkbox = CreateFrame("CheckButton", "EasyFindOptions" .. name .. "Checkbox", parent, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    checkbox.Text:SetText(label)
    
    if tooltipText then
        checkbox:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tooltipText, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        checkbox:SetScript("OnLeave", GameTooltip_Hide)
    end
    
    return checkbox
end

function Options:Initialize()
    if isInitialized then return end
    isInitialized = true
    
    -- Create the main options frame
    optionsFrame = CreateFrame("Frame", "EasyFindOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(350, 530)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    
    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -20)
    title:SetText("EasyFind Options")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -5, -5)
    
    -- Map Icon Scale slider
    local mapIconSlider = CreateSlider(optionsFrame, "MapIcon", "Map Search Icon Size", 0.5, 2.0, 0.1, -70,
        "Adjusts the size of icons shown on the world map when searching for locations.")
    mapIconSlider:SetValue(EasyFind.db.mapIconScale or 1.0)
    mapIconSlider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(sformat("%.0f%%", value * 100))
        EasyFind.db.mapIconScale = value
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then
            ns.MapSearch:UpdateIconScales()
        end
    end)
    optionsFrame.mapIconSlider = mapIconSlider
    
    -- UI Search Bar Scale slider
    local uiSearchSlider = CreateSlider(optionsFrame, "UISearch", "UI Search Bar Size", 0.5, 1.5, 0.1, -140,
        "Adjusts the size of the UI search bar. Hold Shift and drag to move it.")
    uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    uiSearchSlider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(sformat("%.0f%%", value * 100))
        EasyFind.db.uiSearchScale = value
        if ns.UI and ns.UI.UpdateScale then
            ns.UI:UpdateScale()
        end
    end)
    optionsFrame.uiSearchSlider = uiSearchSlider
    
    -- Map Search Bar Scale slider
    local mapSearchSlider = CreateSlider(optionsFrame, "MapSearch", "Map Search Bar Size", 0.5, 1.5, 0.1, -210,
        "Adjusts the size of the map search bar. Hold Shift and drag to move it along the map edge.")
    mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    mapSearchSlider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(sformat("%.0f%%", value * 100))
        EasyFind.db.mapSearchScale = value
        if ns.MapSearch and ns.MapSearch.UpdateScale then
            ns.MapSearch:UpdateScale()
        end
    end)
    optionsFrame.mapSearchSlider = mapSearchSlider
    
    -- Search Bar Opacity slider
    local opacitySlider = CreateSlider(optionsFrame, "Opacity", "Search Bar Opacity", 0.2, 1.0, 0.05, -280,
        "Adjusts the opacity (transparency) of both the UI search bar and the map search bars.")
    opacitySlider:SetValue(EasyFind.db.searchBarOpacity or 1.0)
    opacitySlider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(sformat("%.0f%%", value * 100))
        EasyFind.db.searchBarOpacity = value
        if ns.UI and ns.UI.UpdateOpacity then
            ns.UI:UpdateOpacity()
        end
        if ns.MapSearch and ns.MapSearch.UpdateOpacity then
            ns.MapSearch:UpdateOpacity()
        end
    end)
    optionsFrame.opacitySlider = opacitySlider
    
    -- Direct Open checkbox (UI Search)
    local directOpenCheckbox = CreateCheckbox(optionsFrame, "DirectOpen", "Open Panels Directly", -320,
        "When enabled, clicking a UI search result will immediately open the destination panel.\n\nWhen disabled (default), you will be guided step-by-step with highlights showing you where to click. This helps you learn where things are located in the UI.")
    directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    directOpenCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = self:GetChecked()
    end)
    optionsFrame.directOpenCheckbox = directOpenCheckbox
    
    -- Navigate to Zones Directly checkbox (Map Search)
    local zoneNavCheckbox = CreateCheckbox(optionsFrame, "ZoneNav", "Navigate to Zones Directly", -345,
        "When enabled, clicking a zone search result will immediately open that zone's map.\n\nWhen disabled (default), the zone will be highlighted on the current map so you can see where it is. This helps you learn the world's geography.")
    zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    zoneNavCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.navigateToZonesDirectly = self:GetChecked()
    end)
    optionsFrame.zoneNavCheckbox = zoneNavCheckbox
    
    -- Smart Show checkbox (UI Search)
    local smartShowCheckbox = CreateCheckbox(optionsFrame, "SmartShow", "Smart Show (auto-hide search bar)", -370,
        "When enabled, the UI search bar hides itself until you move your mouse near its position. This keeps your screen uncluttered until you need to search.\n\nThe bar reappears when your mouse enters the area and fades away when you move away.")
    smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.smartShow = self:GetChecked()
        if ns.UI and ns.UI.UpdateSmartShow then
            ns.UI:UpdateSmartShow()
        end
    end)
    optionsFrame.smartShowCheckbox = smartShowCheckbox
    
    -- Dev Mode checkbox
    local devModeCheckbox = CreateCheckbox(optionsFrame, "DevMode", "Dev Mode (show debug output)", -395,
        "When enabled, debug messages will be printed to chat. Useful for addon developers and troubleshooting.")
    devModeCheckbox:SetChecked(EasyFind.db.devMode or false)
    devModeCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.devMode = self:GetChecked()
        if self:GetChecked() then
            EasyFind:Print("Dev mode enabled - debug messages will appear in chat.")
        else
            EasyFind:Print("Dev mode disabled.")
        end
    end)
    optionsFrame.devModeCheckbox = devModeCheckbox
    
    -- ----------------------------------------------------------------
    -- Keybind capture widget
    -- ----------------------------------------------------------------
    local keybindLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keybindLabel:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 20, -425)
    keybindLabel:SetText("Toggle Search Bar Keybind:")
    
    local keybindBtn = CreateFrame("Button", "EasyFindKeybindButton", optionsFrame, "UIPanelButtonTemplate")
    keybindBtn:SetSize(140, 24)
    keybindBtn:SetPoint("LEFT", keybindLabel, "RIGHT", 8, 0)
    keybindBtn.waitingForKey = false
    
    local function GetCurrentKeybindText()
        local key1, key2 = GetBindingKey("EASYFIND_TOGGLE")
        if key1 then return key1 end
        if key2 then return key2 end
        return "Not Bound"
    end
    keybindBtn:SetText(GetCurrentKeybindText())
    
    local function StopCapture()
        keybindBtn.waitingForKey = false
        keybindBtn:SetText(GetCurrentKeybindText())
        keybindBtn:UnlockHighlight()
        keybindBtn:EnableKeyboard(false)
        keybindBtn:SetScript("OnKeyDown", nil)
    end
    
    keybindBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            -- Right-click to unbind
            local key1, key2 = GetBindingKey("EASYFIND_TOGGLE")
            if key1 then SetBinding(key1) end
            if key2 then SetBinding(key2) end
            SaveBindings(GetCurrentBindingSet())
            StopCapture()
            EasyFind:Print("Keybind cleared.")
            return
        end
        if self.waitingForKey then
            StopCapture()
        else
            self.waitingForKey = true
            self:SetText("Press a key...")
            self:LockHighlight()
            self:EnableKeyboard(true)
            self:SetScript("OnKeyDown", function(self, key)
                -- Ignore modifier-only keys
                if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
                   or key == "LALT" or key == "RALT" then
                    return
                end
                if key == "ESCAPE" then
                    StopCapture()
                    return
                end
                -- Build the full combo string
                local combo = ""
                if IsAltKeyDown()   then combo = combo .. "ALT-"   end
                if IsControlKeyDown() then combo = combo .. "CTRL-"  end
                if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
                combo = combo .. key
                -- Clear any previous binding for this action
                local old1, old2 = GetBindingKey("EASYFIND_TOGGLE")
                if old1 then SetBinding(old1) end
                if old2 then SetBinding(old2) end
                -- Set the new binding
                SetBinding(combo, "EASYFIND_TOGGLE")
                SaveBindings(GetCurrentBindingSet())
                StopCapture()
                EasyFind:Print("Keybind set to: " .. combo)
            end)
        end
    end)
    keybindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    keybindBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Toggle Search Bar Keybind")
        GameTooltip:AddLine("Click to set a new keybind.", 1, 1, 1)
        GameTooltip:AddLine("Right-click to clear the keybind.", 1, 1, 1)
        GameTooltip:AddLine("Press Escape to cancel.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    keybindBtn:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
    end)
    keybindBtn:SetScript("OnHide", StopCapture)
    optionsFrame.keybindBtn = keybindBtn
    
    -- Instructions text
    local instructionText = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instructionText:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 20, 50)
    instructionText:SetWidth(310)
    instructionText:SetJustifyH("LEFT")
    instructionText:SetText("|cFFFFFF00Tips:|r\n• Hold |cFF00FF00Shift|r and drag to reposition search bars\n• Type |cFF00FF00/ef o|r to open options")
    
    -- Reset Position button
    local resetPosBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetPosBtn:SetSize(120, 22)
    resetPosBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOM", 10, 20)
    resetPosBtn:SetText("Reset Positions")
    resetPosBtn:SetScript("OnClick", function()
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.mapSearchPosition = nil
        if ns.UI and ns.UI.ResetPosition then
            ns.UI:ResetPosition()
        end
        if ns.MapSearch and ns.MapSearch.ResetPosition then
            ns.MapSearch:ResetPosition()
        end
        EasyFind:Print("Search bar positions reset to defaults.")
    end)
    
    -- Reset All Settings button
    local resetAllBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(120, 22)
    resetAllBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOM", -10, 20)
    resetAllBtn:SetText("Reset All Settings")
    resetAllBtn:SetScript("OnClick", function()
        -- Reset all settings to defaults
        EasyFind.db.mapIconScale = 1.0
        EasyFind.db.uiSearchScale = 1.0
        EasyFind.db.mapSearchScale = 1.0
        EasyFind.db.searchBarOpacity = 1.0
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.mapSearchPosition = nil
        EasyFind.db.globalSearchPosition = nil
        EasyFind.db.directOpen = false
        EasyFind.db.navigateToZonesDirectly = false
        EasyFind.db.smartShow = false
        
        -- Update UI to reflect changes
        optionsFrame.mapIconSlider:SetValue(1.0)
        optionsFrame.uiSearchSlider:SetValue(1.0)
        optionsFrame.mapSearchSlider:SetValue(1.0)
        optionsFrame.opacitySlider:SetValue(1.0)
        optionsFrame.directOpenCheckbox:SetChecked(false)
        optionsFrame.zoneNavCheckbox:SetChecked(false)
        optionsFrame.smartShowCheckbox:SetChecked(false)
        
        -- Apply the resets
        if ns.UI and ns.UI.ResetPosition then
            ns.UI:ResetPosition()
        end
        if ns.UI and ns.UI.UpdateScale then
            ns.UI:UpdateScale()
        end
        if ns.MapSearch and ns.MapSearch.ResetPosition then
            ns.MapSearch:ResetPosition()
        end
        if ns.MapSearch and ns.MapSearch.UpdateScale then
            ns.MapSearch:UpdateScale()
        end
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then
            ns.MapSearch:UpdateIconScales()
        end
        if ns.UI and ns.UI.UpdateOpacity then
            ns.UI:UpdateOpacity()
        end
        if ns.UI and ns.UI.UpdateSmartShow then
            ns.UI:UpdateSmartShow()
        end
        if ns.MapSearch and ns.MapSearch.UpdateOpacity then
            ns.MapSearch:UpdateOpacity()
        end
        
        EasyFind:Print("All settings reset to defaults.")
    end)
    
    optionsFrame:Hide()
    
    -- Register with addon options
    self:RegisterWithBlizzardOptions()
end

function Options:RegisterWithBlizzardOptions()
    -- Create a panel for the Interface Options
    local panel = CreateFrame("Frame")
    panel.name = "EasyFind"
    
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("EasyFind")
    
    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(550)
    desc:SetJustifyH("LEFT")
    desc:SetText("EasyFind helps you find UI elements and map locations.\n\nUse /ef to search, or /ef o to open options.")
    
    local openOptionsBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openOptionsBtn:SetSize(150, 30)
    openOptionsBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    openOptionsBtn:SetText("Open EasyFind Options")
    openOptionsBtn:SetScript("OnClick", function()
        Options:Show()
    end)
    
    -- Register with the new Settings API if available, otherwise use old method
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    else
        InterfaceOptions_AddCategory(panel)
    end
end

function Options:Show()
    if not isInitialized then
        self:Initialize()
    end
    
    -- Refresh values from saved vars
    optionsFrame.mapIconSlider:SetValue(EasyFind.db.mapIconScale or 1.0)
    optionsFrame.uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    optionsFrame.mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    optionsFrame.opacitySlider:SetValue(EasyFind.db.searchBarOpacity or 1.0)
    optionsFrame.directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    optionsFrame.smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    if optionsFrame.keybindBtn then
        local key1 = GetBindingKey("EASYFIND_TOGGLE")
        optionsFrame.keybindBtn:SetText(key1 or "Not Bound")
    end
    
    optionsFrame:Show()
end

function Options:Hide()
    if optionsFrame then
        optionsFrame:Hide()
    end
end

function Options:Toggle()
    if not isInitialized then
        self:Initialize()
    end
    
    if optionsFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- Options:Initialize() is called from Core.lua OnPlayerLogin
