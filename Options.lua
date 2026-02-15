local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local sformat = Utils.sformat
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tonumber, tostring = Utils.tonumber, Utils.tostring
local IsMouseButtonDown = IsMouseButtonDown

local optionsFrame
local isInitialized = false

-- Shared backdrop for selector buttons and flyout panels
local SELECTOR_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
}

-- Helper to create a flyout selector (button + dropdown panel + toggle + click-away)
-- Returns: btnFrame, btnText, flyout
local function CreateFlyoutSelector(parent, globalPrefix, width, anchor, initialText)
    local btnFrame = CreateFrame("Button", globalPrefix .. "Button", parent, "BackdropTemplate")
    btnFrame:SetSize(width, 22)
    btnFrame:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    btnFrame:SetBackdrop(SELECTOR_BACKDROP)
    btnFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    btnFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)

    local btnText = btnFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnText:SetPoint("CENTER")
    btnText:SetText(initialText)

    return btnFrame, btnText
end

-- Create the flyout panel for a selector, with toggle and click-away behavior
-- Returns: flyout frame
local function CreateFlyoutPanel(btnFrame, globalPrefix, width, numChoices)
    local flyout = CreateFrame("Frame", globalPrefix .. "Flyout", btnFrame, "BackdropTemplate")
    flyout:SetSize(width, numChoices * 20 + 6)
    flyout:SetPoint("TOP", btnFrame, "BOTTOM", 0, -2)
    flyout:SetFrameStrata("FULLSCREEN_DIALOG")
    flyout:SetBackdrop(SELECTOR_BACKDROP)
    flyout:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    flyout:Hide()

    btnFrame:SetScript("OnClick", function()
        flyout:SetShown(not flyout:IsShown())
    end)

    flyout:SetScript("OnShow", function(self)
        self:SetScript("OnUpdate", function(self)
            if not self:IsMouseOver() and not btnFrame:IsMouseOver() then
                if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                    self:Hide()
                end
            end
        end)
    end)
    flyout:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    return flyout
end

-- Add simple text options to a flyout panel
local function AddFlyoutOptions(flyout, choices, itemWidth, onSelect)
    for i, name in ipairs(choices) do
        local opt = CreateFrame("Button", nil, flyout)
        opt:SetSize(itemWidth, 18)
        opt:SetPoint("TOPLEFT", flyout, "TOPLEFT", 3, -3 - (i - 1) * 20)
        opt:SetNormalFontObject("GameFontHighlightSmall")
        opt:SetHighlightFontObject("GameFontNormalSmall")
        opt:SetText(name)
        opt:SetScript("OnClick", function()
            onSelect(name)
            flyout:Hide()
        end)
    end
end

-- Helper to create a slider (anchored manually by caller)
local function CreateSlider(parent, name, label, minVal, maxVal, step, tooltipText, formatFunc)
    local slider = CreateFrame("Slider", "EasyFindOptions" .. name .. "Slider", parent, "OptionsSliderTemplate")
    slider:SetWidth(200)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    slider.Text:SetPoint("BOTTOM", slider, "TOP", 0, 5)
    slider.Text:SetText(label)

    -- Use custom format function or default to percentage
    local isPercentage = not formatFunc  -- Track if using percentage format
    local defaultFormat = function(val) return sformat("%.0f%%", val * 100) end
    formatFunc = formatFunc or defaultFormat

    slider.Low:SetText(formatFunc(minVal))
    slider.High:SetText(formatFunc(maxVal))

    slider.valueText = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    slider.valueText:SetPoint("TOP", slider, "BOTTOM", 0, -2)

    -- Input box for precise value entry (shows just the number, no %)
    local inputBox = CreateFrame("EditBox", nil, slider, "InputBoxTemplate")
    inputBox:SetSize(30, 20)  -- Sized to fit 3 digits comfortably
    inputBox:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(3)
    inputBox:SetTextInsets(3, 3, 0, 0)  -- Equal padding for centering
    inputBox:SetJustifyH("CENTER")
    -- Also set the font string justification directly
    if inputBox.GetFontString then
        local fs = inputBox:GetFontString()
        if fs then fs:SetJustifyH("CENTER") end
    end

    -- Add % label next to input box for percentage sliders
    local percentLabel
    if isPercentage then
        percentLabel = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        percentLabel:SetPoint("LEFT", inputBox, "RIGHT", 2, 0)
        percentLabel:SetText("%")
    end

    -- Helper to get display value (for percentage: multiply by 100)
    local function getDisplayValue(sliderValue)
        if isPercentage then
            return mfloor(sliderValue * 100 + 0.5)
        else
            return mfloor(sliderValue + 0.5)
        end
    end

    -- Helper to convert display value to slider value
    local function getSliderValue(displayValue)
        if isPercentage then
            return displayValue / 100
        else
            return displayValue
        end
    end

    inputBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            -- Valid number: clamp to bounds and update slider
            local sliderVal = getSliderValue(val)
            sliderVal = mmax(minVal, mmin(maxVal, sliderVal))
            slider:SetValue(sliderVal)
            -- Update input box to show the actual clamped value
            self:SetText(tostring(getDisplayValue(sliderVal)))
        else
            -- Invalid input: revert to current slider value
            self:SetText(tostring(getDisplayValue(slider:GetValue())))
        end
        self:ClearFocus()
    end)

    inputBox:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(getDisplayValue(slider:GetValue())))
        self:ClearFocus()
    end)

    -- Update both valueText and input box when slider changes
    slider:SetScript("OnValueChanged", function(self, value)
        self.valueText:SetText(formatFunc(value))
        if not inputBox:HasFocus() then
            inputBox:SetText(tostring(getDisplayValue(value)))
        end
    end)

    -- Set initial value
    inputBox:SetText(tostring(getDisplayValue(slider:GetValue())))

    slider.inputBox = inputBox

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

-- Helper to create a checkbox (anchored manually by caller)
local function CreateCheckbox(parent, name, label, tooltipText)
    local checkbox = CreateFrame("CheckButton", "EasyFindOptions" .. name .. "Checkbox", parent, "InterfaceOptionsCheckButtonTemplate")
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
    
    local FRAME_W = 570
    local BASE_H  = 480  -- Increased to accommodate all elements without overlap
    local ADV_H   = 30   -- extra height when Advanced Options expanded
    local COL_LEFT  = 20
    local COL_RIGHT = 300
    local BTN_OFFSET = 105  -- fixed offset from label LEFT to button LEFT (aligns all right-col buttons)
    
    -- Create the main options frame
    optionsFrame = CreateFrame("Frame", "EasyFindOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(FRAME_W, BASE_H)
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
    optionsFrame.BASE_H = BASE_H
    optionsFrame.ADV_H  = ADV_H
    
    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -20)
    title:SetText("EasyFind Options")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -5, -5)
    
    -- =====================================================================
    -- LEFT COLUMN — Sliders
    -- =====================================================================
    local mapIconSlider = CreateSlider(optionsFrame, "MapIcon", "Icon Size", 0.5, 2.0, 0.1,
        "Adjusts the size of search icons on the world map and in UI search.")
    mapIconSlider:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_LEFT, -70)
    mapIconSlider:SetValue(EasyFind.db.iconScale or 1.0)
    mapIconSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.iconScale = value
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then
            ns.MapSearch:UpdateIconScales()
        end
        -- Also update UI search indicator
        local uiInd = _G["EasyFindIndicatorFrame"]
        if uiInd then
            local s = EasyFind.db.iconScale or 1.0
            uiInd:SetScale(s)
        end
    end)
    optionsFrame.mapIconSlider = mapIconSlider

    local uiSearchSlider = CreateSlider(optionsFrame, "UISearch", "UI Search Bar Size", 0.5, 1.5, 0.1,
        "Adjusts the size of the UI search bar. Hold Shift and drag to move it.")
    uiSearchSlider:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_LEFT, -140)
    uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    uiSearchSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.uiSearchScale = value
        if ns.UI and ns.UI.UpdateScale then
            ns.UI:UpdateScale()
        end
    end)
    optionsFrame.uiSearchSlider = uiSearchSlider

    local mapSearchSlider = CreateSlider(optionsFrame, "MapSearch", "Map Search Bar Size", 0.5, 1.5, 0.1,
        "Adjusts the size of the map search bar. Hold Shift and drag to move it along the map edge.")
    mapSearchSlider:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_LEFT, -210)
    mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    mapSearchSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.mapSearchScale = value
        if ns.MapSearch and ns.MapSearch.UpdateScale then
            ns.MapSearch:UpdateScale()
        end
    end)
    optionsFrame.mapSearchSlider = mapSearchSlider

    local opacitySlider = CreateSlider(optionsFrame, "Opacity", "Search Bar Opacity", 0.2, 1.0, 0.05,
        "Adjusts the opacity (transparency) of both the UI search bar and the map search bars.")
    opacitySlider:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_LEFT, -280)
    opacitySlider:SetValue(EasyFind.db.searchBarOpacity or 1.0)
    opacitySlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.searchBarOpacity = value
        if ns.UI and ns.UI.UpdateOpacity then
            ns.UI:UpdateOpacity()
        end
        if ns.MapSearch and ns.MapSearch.UpdateOpacity then
            ns.MapSearch:UpdateOpacity()
        end
    end)
    optionsFrame.opacitySlider = opacitySlider

    local maxResultsSlider = CreateSlider(optionsFrame, "MaxResults", "Max Search Results", 6, 24, 1,
        "Maximum number of search results to display in the dropdown (6-24).",
        function(val) return tostring(mfloor(val + 0.5)) end)  -- Show as integer, not percentage
    maxResultsSlider:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_LEFT, -350)
    maxResultsSlider:SetValue(EasyFind.db.maxResults or 12)
    maxResultsSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)  -- Round to nearest integer
        EasyFind.db.maxResults = value
        -- Refresh the results display if currently showing
        if ns.UI and ns.UI.RefreshResults then
            ns.UI:RefreshResults()
        end
    end)
    optionsFrame.maxResultsSlider = maxResultsSlider

    -- =====================================================================
    -- RIGHT COLUMN — Checkboxes, Theme, Keybinds
    -- =====================================================================
    local directOpenCheckbox = CreateCheckbox(optionsFrame, "DirectOpen", "Open Panels Directly",
        "When enabled, clicking a UI search result will immediately open the destination panel.\n\nWhen disabled (default), you will be guided step-by-step with highlights showing you where to click.")
    directOpenCheckbox:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", COL_RIGHT, -55)
    directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    directOpenCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = self:GetChecked()
    end)
    optionsFrame.directOpenCheckbox = directOpenCheckbox
    
    local zoneNavCheckbox = CreateCheckbox(optionsFrame, "ZoneNav", "Navigate to Zones Directly",
        "When enabled, clicking a zone search result will immediately open that zone's map.\n\nWhen disabled (default), the zone will be highlighted on the current map so you can see where it is.")
    zoneNavCheckbox:SetPoint("TOPLEFT", directOpenCheckbox, "BOTTOMLEFT", 0, -4)
    zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    zoneNavCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.navigateToZonesDirectly = self:GetChecked()
    end)
    optionsFrame.zoneNavCheckbox = zoneNavCheckbox
    
    local smartShowCheckbox = CreateCheckbox(optionsFrame, "SmartShow", "Smart Show (auto-hide)",
        "When enabled, the UI search bar hides itself until you move your mouse near its position.\n\nThe bar reappears when your mouse enters the area and fades away when you move away.")
    smartShowCheckbox:SetPoint("TOPLEFT", zoneNavCheckbox, "BOTTOMLEFT", 0, -4)
    smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.smartShow = self:GetChecked()
        if ns.UI and ns.UI.UpdateSmartShow then
            ns.UI:UpdateSmartShow()
        end
    end)
    optionsFrame.smartShowCheckbox = smartShowCheckbox

    local truncMessageCheckbox = CreateCheckbox(optionsFrame, "TruncMessage", "Show \"More Results\" Message",
        "When enabled, shows a message at the bottom of search results when more items exist than can be displayed.\n\nIncrease the max results slider on the left to see more items.")
    truncMessageCheckbox:SetPoint("TOPLEFT", smartShowCheckbox, "BOTTOMLEFT", 0, -4)
    truncMessageCheckbox:SetChecked(EasyFind.db.showTruncationMessage ~= false)
    truncMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showTruncationMessage = self:GetChecked()
        if ns.UI and ns.UI.RefreshResults then
            ns.UI:RefreshResults()
        end
    end)
    optionsFrame.truncMessageCheckbox = truncMessageCheckbox

    local hardCapCheckbox = CreateCheckbox(optionsFrame, "HardCap", "Hard Results Cap",
        "When enabled, search results are strictly cut off at the max results limit, even if the last visible item is a group header with no results shown beneath it. Pinned paths also count toward the limit when this is enabled.\n\nWhen disabled (default), the list extends slightly past the cap to ensure every group header shows the results inside it. Pinned paths do not count toward the result limit.")
    hardCapCheckbox:SetPoint("TOPLEFT", truncMessageCheckbox, "BOTTOMLEFT", 0, -4)
    hardCapCheckbox:SetChecked(EasyFind.db.hardResultsCap or false)
    hardCapCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.hardResultsCap = self:GetChecked()
        if ns.UI and ns.UI.RefreshResults then
            ns.UI:RefreshResults()
        end
    end)
    optionsFrame.hardCapCheckbox = hardCapCheckbox

    local staticOpacityCheckbox = CreateCheckbox(optionsFrame, "StaticOpacity", "Static Opacity",
        "When enabled, the search bar keeps the same opacity at all times.\n\nWhen disabled (default), opacity is reduced while your character is moving so you can see the game world better, similar to how the World Map behaves.\n\nThis only applies to the main search bar. Map search bars follow the World Map's built-in fade behavior.")
    staticOpacityCheckbox:SetPoint("TOPLEFT", hardCapCheckbox, "BOTTOMLEFT", 0, -4)
    staticOpacityCheckbox:SetChecked(EasyFind.db.staticOpacity or false)
    staticOpacityCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.staticOpacity = self:GetChecked()
        if ns.UI and ns.UI.UpdateOpacity then
            ns.UI:UpdateOpacity()
        end
    end)
    optionsFrame.staticOpacityCheckbox = staticOpacityCheckbox

    -- Results Theme selector (custom, avoids UIDropDownMenu global state bugs)
    local themeLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", staticOpacityCheckbox, "BOTTOMLEFT", 4, -12)
    themeLabel:SetText("Theme:")
    
    local themeChoices = {"Classic", "Retail"}
    
    local themeBtnFrame, themeBtnText = CreateFlyoutSelector(
        optionsFrame, "EasyFindTheme", 90, themeLabel, EasyFind.db.resultsTheme or "Retail"
    )
    themeBtnFrame:ClearAllPoints()
    themeBtnFrame:SetPoint("LEFT", themeLabel, "LEFT", BTN_OFFSET, 0)
    local themeFlyout = CreateFlyoutPanel(themeBtnFrame, "EasyFindTheme", 90, #themeChoices)
    AddFlyoutOptions(themeFlyout, themeChoices, 84, function(name)
        EasyFind.db.resultsTheme = name
        themeBtnText:SetText(name)
        if ns.UI and ns.UI.RefreshResults then ns.UI:RefreshResults() end
        if ns.MapSearch and ns.MapSearch.UpdateSearchBarTheme then ns.MapSearch:UpdateSearchBarTheme() end
    end)
    optionsFrame.themeBtnText = themeBtnText
    optionsFrame.themeFlyout = themeFlyout
    
    -- =====================================================================
    -- Indicator Style selector (same style as Theme selector)
    -- =====================================================================
    local indicatorLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    indicatorLabel:SetPoint("TOPLEFT", themeLabel, "BOTTOMLEFT", 0, -32)
    indicatorLabel:SetText("Indicator Style:")

    local indicatorChoices = {"EasyFind Arrow", "Classic Quest Arrow", "Minimap Player Arrow", "Low-res Gauntlet", "HD Gauntlet"}

    local indicatorBtnFrame, indicatorBtnText = CreateFlyoutSelector(
        optionsFrame, "EasyFindIndicator", 140, indicatorLabel, EasyFind.db.indicatorStyle or "EasyFind Arrow"
    )
    indicatorBtnFrame:ClearAllPoints()
    indicatorBtnFrame:SetPoint("LEFT", indicatorLabel, "LEFT", BTN_OFFSET, 0)
    local indicatorFlyout = CreateFlyoutPanel(indicatorBtnFrame, "EasyFindIndicator", 140, #indicatorChoices)
    AddFlyoutOptions(indicatorFlyout, indicatorChoices, 134, function(name)
        EasyFind.db.indicatorStyle = name
        indicatorBtnText:SetText(name)
        if ns.MapSearch then
            ns.MapSearch:RefreshIndicators()
        end
    end)
    optionsFrame.indicatorBtnText = indicatorBtnText
    optionsFrame.indicatorFlyout = indicatorFlyout

    -- =====================================================================
    -- Indicator Color selector
    -- =====================================================================
    local colorLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", indicatorLabel, "BOTTOMLEFT", 0, -10)
    colorLabel:SetText("Indicator Color:")
    
    local colorChoices = {"Yellow", "Gold", "Orange", "Red", "Green", "Blue", "Purple", "White"}
    local colorRGB = ns.INDICATOR_COLORS  -- Shared with MapSearch.lua
    
    local colorBtnFrame, colorBtnText = CreateFlyoutSelector(
        optionsFrame, "EasyFindColor", 140, colorLabel, EasyFind.db.indicatorColor or "Yellow"
    )
    colorBtnFrame:ClearAllPoints()
    colorBtnFrame:SetPoint("LEFT", colorLabel, "LEFT", BTN_OFFSET, 0)
    local currentColor = EasyFind.db.indicatorColor or "Yellow"
    local currentRGB = colorRGB[currentColor] or colorRGB.Yellow
    colorBtnText:SetTextColor(currentRGB[1], currentRGB[2], currentRGB[3])
    
    -- Color swatch next to text
    local colorSwatch = colorBtnFrame:CreateTexture(nil, "ARTWORK")
    colorSwatch:SetSize(14, 14)
    colorSwatch:SetPoint("LEFT", colorBtnFrame, "LEFT", 6, 0)
    colorSwatch:SetColorTexture(currentRGB[1], currentRGB[2], currentRGB[3], 1)
    
    local colorFlyout = CreateFlyoutPanel(colorBtnFrame, "EasyFindColor", 140, #colorChoices)

    for i, name in ipairs(colorChoices) do
        local rgb = colorRGB[name]
        local opt = CreateFrame("Button", nil, colorFlyout)
        opt:SetSize(134, 18)
        opt:SetPoint("TOPLEFT", colorFlyout, "TOPLEFT", 3, -3 - (i - 1) * 20)
        
        -- Color swatch in each option
        local swatch = opt:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(12, 12)
        swatch:SetPoint("LEFT", 2, 0)
        swatch:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
        
        local label = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
        label:SetText(name)
        label:SetTextColor(rgb[1], rgb[2], rgb[3])
        
        opt:SetScript("OnEnter", function(self)
            label:SetTextColor(1, 1, 1)
        end)
        opt:SetScript("OnLeave", function(self)
            label:SetTextColor(rgb[1], rgb[2], rgb[3])
        end)
        opt:SetScript("OnClick", function()
            EasyFind.db.indicatorColor = name
            colorBtnText:SetText(name)
            colorBtnText:SetTextColor(rgb[1], rgb[2], rgb[3])
            colorSwatch:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)
            colorFlyout:Hide()
            if ns.MapSearch then
                ns.MapSearch:RefreshIndicators()
            end
        end)
    end
    
    optionsFrame.colorBtnText = colorBtnText
    optionsFrame.colorSwatch = colorSwatch
    optionsFrame.colorFlyout = colorFlyout
    
    -- ----------------------------------------------------------------
    -- Keybind helpers (shared)
    -- ----------------------------------------------------------------
    local function GetCurrentKeybindText(action)
        local key1, key2 = GetBindingKey(action)
        if key1 then return key1 end
        if key2 then return key2 end
        return "Not Bound"
    end
    
    local function StopCapture(btn, action)
        btn.waitingForKey = false
        btn:SetText(GetCurrentKeybindText(action))
        btn:UnlockHighlight()
        btn:EnableKeyboard(false)
        btn:SetScript("OnKeyDown", nil)
    end
    
    local function StartCapture(btn, action)
        if btn.waitingForKey then
            StopCapture(btn, action)
        else
            btn.waitingForKey = true
            btn:SetText("Press a key...")
            btn:LockHighlight()
            btn:EnableKeyboard(true)
            btn:SetScript("OnKeyDown", function(self, key)
                if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
                   or key == "LALT" or key == "RALT" then
                    return
                end
                if key == "ESCAPE" then
                    StopCapture(self, action)
                    return
                end
                local combo = ""
                if IsAltKeyDown()   then combo = combo .. "ALT-"   end
                if IsControlKeyDown() then combo = combo .. "CTRL-"  end
                if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
                combo = combo .. key
                local old1, old2 = GetBindingKey(action)
                if old1 then SetBinding(old1) end
                if old2 then SetBinding(old2) end
                SetBinding(combo, action)
                SaveBindings(GetCurrentBindingSet())
                StopCapture(self, action)
                EasyFind:Print("Keybind set to: " .. combo)
            end)
        end
    end
    
    local function MakeKeybindTooltip(btn, titleText, line1, line2)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(titleText)
            GameTooltip:AddLine(line1, 1, 1, 1)
            GameTooltip:AddLine("Right-click to clear. Escape to cancel.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end
    
    -- Toggle Search Bar keybind
    local toggleLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toggleLabel:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -18)
    toggleLabel:SetText("Toggle Bar:")
    
    local keybindBtn = CreateFrame("Button", "EasyFindKeybindButton", optionsFrame, "UIPanelButtonTemplate")
    keybindBtn:SetSize(110, 22)
    keybindBtn:SetPoint("LEFT", toggleLabel, "LEFT", BTN_OFFSET, 0)
    keybindBtn.waitingForKey = false
    keybindBtn:SetText(GetCurrentKeybindText("EASYFIND_TOGGLE"))
    
    keybindBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local key1, key2 = GetBindingKey("EASYFIND_TOGGLE")
            if key1 then SetBinding(key1) end
            if key2 then SetBinding(key2) end
            SaveBindings(GetCurrentBindingSet())
            StopCapture(self, "EASYFIND_TOGGLE")
            EasyFind:Print("Keybind cleared.")
            return
        end
        StartCapture(self, "EASYFIND_TOGGLE")
    end)
    keybindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    MakeKeybindTooltip(keybindBtn, "Toggle Search Bar", "Click to set a keybind. Shows/hides the search bar.")
    keybindBtn:SetScript("OnHide", function(self) StopCapture(self, "EASYFIND_TOGGLE") end)
    optionsFrame.keybindBtn = keybindBtn
    
    -- Focus Search Bar keybind
    local focusLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    focusLabel:SetPoint("TOPLEFT", toggleLabel, "BOTTOMLEFT", 0, -10)
    focusLabel:SetText("Focus Bar:")
    
    local focusBtn = CreateFrame("Button", "EasyFindFocusKeybindButton", optionsFrame, "UIPanelButtonTemplate")
    focusBtn:SetSize(110, 22)
    focusBtn:SetPoint("LEFT", focusLabel, "LEFT", BTN_OFFSET, 0)
    focusBtn.waitingForKey = false
    focusBtn:SetText(GetCurrentKeybindText("EASYFIND_FOCUS"))
    
    focusBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local key1, key2 = GetBindingKey("EASYFIND_FOCUS")
            if key1 then SetBinding(key1) end
            if key2 then SetBinding(key2) end
            SaveBindings(GetCurrentBindingSet())
            StopCapture(self, "EASYFIND_FOCUS")
            EasyFind:Print("Focus keybind cleared.")
            return
        end
        StartCapture(self, "EASYFIND_FOCUS")
    end)
    focusBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    MakeKeybindTooltip(focusBtn, "Focus Search Bar", "Click to set a keybind. Puts cursor in/out of the search box.")
    focusBtn:SetScript("OnHide", function(self) StopCapture(self, "EASYFIND_FOCUS") end)
    optionsFrame.focusBtn = focusBtn
    
    -- =====================================================================
    -- BOTTOM — full-width: Tips, Advanced, Resets
    -- =====================================================================
    
    -- Separator line (moved down to avoid overlap with sliders)
    local sep = optionsFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
    sep:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 20, -385)
    sep:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -20, -385)

    -- Tips
    local instructionText = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instructionText:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 22, -393)
    instructionText:SetWidth(FRAME_W - 44)
    instructionText:SetJustifyH("LEFT")
    instructionText:SetText("|cFFFFFF00Tips:|r  Hold |cFF00FF00Shift|r + drag to reposition bars  |cFF888888|||r  |cFF00FF00/ef o|r options\n|cFF00FF00/ef show|r  |cFF00FF00/ef hide|r toggle bar  |cFF888888|||r  |cFF00FF00/ef clear|r dismiss highlights")

    -- Advanced Options toggle
    local advancedToggle = CreateFrame("Button", nil, optionsFrame)
    advancedToggle:SetSize(200, 18)
    advancedToggle:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 20, -415)
    advancedToggle:SetNormalFontObject("GameFontNormalSmall")
    advancedToggle:SetHighlightFontObject("GameFontHighlightSmall")
    advancedToggle:SetText("|cFF888888> Advanced Options|r")
    advancedToggle:GetFontString():SetJustifyH("LEFT")
    advancedToggle.expanded = false
    
    -- Dev Mode checkbox (hidden by default)
    local devModeCheckbox = CreateCheckbox(optionsFrame, "DevMode", "Dev Mode (show debug output)",
        "When enabled, debug messages will be printed to chat. Useful for addon developers and troubleshooting.")
    devModeCheckbox:SetPoint("TOPLEFT", advancedToggle, "BOTTOMLEFT", -2, -4)
    devModeCheckbox:SetChecked(EasyFind.db.devMode or false)
    devModeCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.devMode = self:GetChecked()
        if self:GetChecked() then
            EasyFind:Print("Dev mode enabled - debug messages will appear in chat.")
        else
            EasyFind:Print("Dev mode disabled.")
        end
    end)
    devModeCheckbox:Hide()
    optionsFrame.devModeCheckbox = devModeCheckbox
    
    advancedToggle:SetScript("OnClick", function(self)
        self.expanded = not self.expanded
        if self.expanded then
            self:SetText("|cFFCCCCCCv Advanced Options|r")
            devModeCheckbox:Show()
            optionsFrame:SetHeight(BASE_H + ADV_H)
        else
            self:SetText("|cFF888888> Advanced Options|r")
            devModeCheckbox:Hide()
            optionsFrame:SetHeight(BASE_H)
        end
    end)
    optionsFrame.advancedToggle = advancedToggle
    
    -- Reset buttons (anchored to bottom)
    local resetAllBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(130, 22)
    resetAllBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 30, 18)
    resetAllBtn:SetText("Reset All Settings")
    resetAllBtn:SetScript("OnClick", function()
        -- Reset all settings to defaults
        EasyFind.db.iconScale = 1.0
        EasyFind.db.uiSearchScale = 1.0
        EasyFind.db.mapSearchScale = 1.0
        EasyFind.db.searchBarOpacity = 1.0
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.mapSearchPosition = nil
        EasyFind.db.globalSearchPosition = nil
        EasyFind.db.directOpen = false
        EasyFind.db.navigateToZonesDirectly = false
        EasyFind.db.smartShow = true
        EasyFind.db.resultsTheme = "Retail"
        EasyFind.db.devMode = false
        EasyFind.db.maxResults = 12
        EasyFind.db.showTruncationMessage = true
        EasyFind.db.hardResultsCap = false
        EasyFind.db.pinsCollapsed = false
        EasyFind.db.staticOpacity = false
        EasyFind.db.indicatorStyle = "EasyFind Arrow"
        EasyFind.db.indicatorColor = "Yellow"
        EasyFind.db.visible = true

        -- Clear all active highlights
        if ns.Highlight then
            ns.Highlight:ClearAll()
        end
        if ns.MapSearch then
            ns.MapSearch:ClearHighlight()
            ns.MapSearch:ClearZoneHighlight()
        end

        -- Clear keybinds (unbind)
        local old1, old2 = GetBindingKey("EASYFIND_TOGGLE")
        if old1 then SetBinding(old1) end
        if old2 then SetBinding(old2) end

        old1, old2 = GetBindingKey("EASYFIND_FOCUS")
        if old1 then SetBinding(old1) end
        if old2 then SetBinding(old2) end
        SaveBindings(GetCurrentBindingSet())
        
        -- Update UI to reflect changes
        optionsFrame.mapIconSlider:SetValue(1.0)
        optionsFrame.uiSearchSlider:SetValue(1.0)
        optionsFrame.mapSearchSlider:SetValue(1.0)
        optionsFrame.opacitySlider:SetValue(1.0)
        optionsFrame.directOpenCheckbox:SetChecked(false)
        optionsFrame.zoneNavCheckbox:SetChecked(false)
        optionsFrame.smartShowCheckbox:SetChecked(true)
        optionsFrame.truncMessageCheckbox:SetChecked(true)
        optionsFrame.hardCapCheckbox:SetChecked(false)
        optionsFrame.staticOpacityCheckbox:SetChecked(false)
        optionsFrame.devModeCheckbox:SetChecked(false)
        optionsFrame.maxResultsSlider:SetValue(12)
        optionsFrame.themeBtnText:SetText("Retail")
        optionsFrame.indicatorBtnText:SetText("EasyFind Arrow")
        optionsFrame.colorBtnText:SetText("Yellow")
        optionsFrame.colorBtnText:SetTextColor(1.0, 1.0, 0.0)
        optionsFrame.colorSwatch:SetColorTexture(1.0, 1.0, 0.0, 1)
        optionsFrame.keybindBtn:SetText("Not Bound")
        optionsFrame.focusBtn:SetText("Not Bound")
        
        -- Apply the resets
        if ns.UI and ns.UI.ResetPosition then ns.UI:ResetPosition() end
        if ns.UI and ns.UI.UpdateScale then ns.UI:UpdateScale() end
        if ns.UI and ns.UI.UpdateOpacity then ns.UI:UpdateOpacity() end
        if ns.UI and ns.UI.UpdateSmartShow then ns.UI:UpdateSmartShow() end
        if ns.UI and ns.UI.RefreshResults then ns.UI:RefreshResults() end
        if ns.MapSearch and ns.MapSearch.UpdateSearchBarTheme then ns.MapSearch:UpdateSearchBarTheme() end
        if ns.MapSearch and ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
        if ns.MapSearch and ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then ns.MapSearch:UpdateIconScales() end
        if ns.MapSearch and ns.MapSearch.RefreshIndicators then ns.MapSearch:RefreshIndicators() end
        -- Reset UI indicator scale too
        local uiInd = _G["EasyFindIndicatorFrame"]
        if uiInd then uiInd:SetScale(1.0) end
        if ns.MapSearch and ns.MapSearch.UpdateOpacity then ns.MapSearch:UpdateOpacity() end
        -- Show the search bar
        if ns.UI and ns.UI.Show then ns.UI:Show() end
        
        EasyFind:Print("All settings reset to defaults.")
    end)
    
    local resetPosBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetPosBtn:SetSize(130, 22)
    resetPosBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -30, 18)
    resetPosBtn:SetText("Reset Positions")
    resetPosBtn:SetScript("OnClick", function()
        EasyFind.db.uiSearchPosition = nil
        EasyFind.db.mapSearchPosition = nil
        if ns.UI and ns.UI.ResetPosition then ns.UI:ResetPosition() end
        if ns.MapSearch and ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
        EasyFind:Print("Search bar positions reset to defaults.")
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
    optionsFrame.mapIconSlider:SetValue(EasyFind.db.iconScale or 1.0)
    optionsFrame.uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    optionsFrame.mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    optionsFrame.opacitySlider:SetValue(EasyFind.db.searchBarOpacity or 1.0)
    optionsFrame.directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    optionsFrame.smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    optionsFrame.devModeCheckbox:SetChecked(EasyFind.db.devMode or false)
    optionsFrame.themeBtnText:SetText(EasyFind.db.resultsTheme or "Retail")
    
    local key1 = GetBindingKey("EASYFIND_TOGGLE")
    optionsFrame.keybindBtn:SetText(key1 or "Not Bound")
    local key2 = GetBindingKey("EASYFIND_FOCUS")
    optionsFrame.focusBtn:SetText(key2 or "Not Bound")
    
    -- Collapse advanced options on open
    optionsFrame.advancedToggle.expanded = false
    optionsFrame.advancedToggle:SetText("|cFF888888> Advanced Options|r")
    optionsFrame.devModeCheckbox:Hide()
    optionsFrame:SetHeight(optionsFrame.BASE_H)
    
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
