local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local sformat = Utils.sformat
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tonumber, tostring = Utils.tonumber, Utils.tostring
local tinsert = Utils.tinsert
local IsMouseButtonDown = IsMouseButtonDown

local GOLD_COLOR = ns.GOLD_COLOR
local DEFAULT_OPACITY = ns.DEFAULT_OPACITY
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER
local DARK_PANEL_BG = ns.DARK_PANEL_BG

local optionsFrame
local isInitialized = false

-- Shared backdrop for selector buttons and flyout panels
local SELECTOR_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = TOOLTIP_BORDER,
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
    flyout:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])
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

    local FRAME_W    = 570
    local COL_LEFT   = 4      -- Left column offset within content frames
    local COL_RIGHT  = 280    -- Right column offset within content frames
    local BTN_OFFSET = 105    -- Label LEFT to button LEFT (aligns selectors/keybinds)
    local HEADER_H   = 26
    local HEADER_GAP = 4
    local TITLE_Y    = -50    -- Y where first section header starts
    local BOTTOM_PAD = 80     -- Space for separator, tips, reset buttons

    -- Create the main options frame
    optionsFrame = CreateFrame("Frame", "EasyFindOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(FRAME_W, 250)
    optionsFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)

    optionsFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    optionsFrame:SetBackdropColor(0.12, 0.10, 0.08, EasyFind.db.panelOpacity or 0.9)

    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -20)
    title:SetText("EasyFind Options")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -5, -5)

    -- Collapsible section infrastructure
    local sections = {}
    local sep, instructionText  -- forward-declared for RelayoutSections

    local function RelayoutSections()
        local y = TITLE_Y
        for _, section in ipairs(sections) do
            section.header:ClearAllPoints()
            section.header:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 16, y)
            section.header:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -16, y)
            y = y - HEADER_H
            if section.expanded then
                y = y - section.contentHeight
            end
            y = y - HEADER_GAP
        end
        -- Position bottom elements below last section
        if sep then
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 20, y - 2)
            sep:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -20, y - 2)
        end
        if instructionText then
            instructionText:ClearAllPoints()
            instructionText:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 22, y - 10)
        end
        -- Adjust frame height
        local totalH = -y + BOTTOM_PAD
        optionsFrame:SetHeight(totalH)
    end
    optionsFrame.RelayoutSections = RelayoutSections

    local function CreateSection(sectionTitle, contentHeight)
        local section = { expanded = false, contentHeight = contentHeight }

        -- Header button (full width clickable bar)
        local header = CreateFrame("Button", nil, optionsFrame)
        header:SetHeight(HEADER_H)

        -- Background using quest log tab atlas
        local bg = header:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetAtlas("QuestLog-tab")

        -- Hover highlight
        local hl = header:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetAtlas("QuestLog-tab")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.3)

        -- Section title text
        local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", header, "LEFT", 10, 0)
        text:SetText(sectionTitle)

        -- Expand/collapse icon
        local icon = header:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 17)
        icon:SetPoint("RIGHT", header, "RIGHT", -8, 0)
        icon:SetAtlas("QuestLog-icon-expand")

        section.header = header
        section.icon = icon

        -- Content frame (hidden by default)
        local content = CreateFrame("Frame", nil, optionsFrame)
        content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        content:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
        content:SetHeight(contentHeight)
        content:Hide()
        section.content = content

        -- Toggle on click
        header:SetScript("OnClick", function()
            section.expanded = not section.expanded
            icon:SetAtlas(section.expanded and "QuestLog-icon-shrink" or "QuestLog-icon-expand")
            content:SetShown(section.expanded)
            RelayoutSections()
        end)

        tinsert(sections, section)
        return content
    end
    optionsFrame.sections = sections

    -- Keybind helpers (defined early since Section 4 needs them)
    local function GetCurrentKeybindText(action)
        local key1, key2 = GetBindingKey(action)
        if key1 then return key1 end
        if key2 then return key2 end
        return "Not Bound"
    end

    local function StopCapture(keybindBtn, action)
        keybindBtn.waitingForKey = false
        keybindBtn:SetText(GetCurrentKeybindText(action))
        keybindBtn:UnlockHighlight()
        keybindBtn:EnableKeyboard(false)
        keybindBtn:SetScript("OnKeyDown", nil)
    end

    local function StartCapture(keybindBtn, action)
        if keybindBtn.waitingForKey then
            StopCapture(keybindBtn, action)
        else
            keybindBtn.waitingForKey = true
            keybindBtn:SetText("Press a key...")
            keybindBtn:LockHighlight()
            keybindBtn:EnableKeyboard(true)
            keybindBtn:SetScript("OnKeyDown", function(self, key)
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

    local function MakeKeybindTooltip(keybindBtn, titleText, line1)
        keybindBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(titleText)
            GameTooltip:AddLine(line1, 1, 1, 1)
            GameTooltip:AddLine("Right-click to clear. Escape to cancel.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        keybindBtn:SetScript("OnLeave", GameTooltip_Hide)
    end

    -- SECTION 1: General
    local sec3 = CreateSection("General", 240)

    local panelOpacitySlider = CreateSlider(sec3, "PanelOpacity", "Options Menu Opacity", 0.3, 1.0, 0.05,
        "Adjusts the opacity of the options panel background.")
    panelOpacitySlider:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_LEFT, -28)
    panelOpacitySlider:SetValue(EasyFind.db.panelOpacity or 0.9)
    panelOpacitySlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.panelOpacity = value
        optionsFrame:SetBackdropColor(0.12, 0.10, 0.08, value)
    end)
    optionsFrame.panelOpacitySlider = panelOpacitySlider

    local opacitySlider = CreateSlider(sec3, "Opacity", "Background Opacity", 0.0, 1.0, 0.05,
        "Adjusts the background opacity of all search bars. Text and icons remain fully visible.")
    opacitySlider:SetPoint("TOPLEFT", panelOpacitySlider, "BOTTOMLEFT", 0, -38)
    opacitySlider:SetValue(EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
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

    local fontSlider = CreateSlider(sec3, "FontSize", "Font Size|cffff3333*|r", 0.5, 2.0, 0.1,
        "Changing font size also affects search bar height and results window sizing.")
    fontSlider:SetPoint("TOPLEFT", opacitySlider, "BOTTOMLEFT", 0, -38)
    fontSlider:SetValue(EasyFind.db.fontSize or 1.0)
    fontSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.fontSize = value
        if ns.MapSearch and ns.MapSearch.UpdateFontSize then
            ns.MapSearch:UpdateFontSize()
        end
        if ns.UI and ns.UI.UpdateFontSize then
            ns.UI:UpdateFontSize()
        end
    end)
    optionsFrame.fontSlider = fontSlider

    local indicatorLabel = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    indicatorLabel:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 4, -24)
    indicatorLabel:SetText("Indicator Style:")

    local indicatorChoices = {"EasyFind Arrow", "Classic Quest Arrow", "Minimap Player Arrow", "Low-res Gauntlet", "HD Gauntlet"}

    local indicatorBtnFrame, indicatorBtnText = CreateFlyoutSelector(
        sec3, "EasyFindIndicator", 140, indicatorLabel, EasyFind.db.indicatorStyle or "EasyFind Arrow"
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

    local colorLabel = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLabel:SetPoint("TOPLEFT", indicatorLabel, "BOTTOMLEFT", 0, -20)
    colorLabel:SetText("Indicator Color:")

    local colorChoices = {"Yellow", "Gold", "Orange", "Red", "Green", "Blue", "Purple", "White"}
    local colorRGB = ns.INDICATOR_COLORS

    local colorBtnFrame, colorBtnText = CreateFlyoutSelector(
        sec3, "EasyFindColor", 140, colorLabel, EasyFind.db.indicatorColor or "Yellow"
    )
    colorBtnFrame:ClearAllPoints()
    colorBtnFrame:SetPoint("LEFT", colorLabel, "LEFT", BTN_OFFSET, 0)
    local currentColor = EasyFind.db.indicatorColor or "Yellow"
    local currentRGB = colorRGB[currentColor] or colorRGB.Yellow
    colorBtnText:SetTextColor(currentRGB[1], currentRGB[2], currentRGB[3])

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

    local loginMessageCheckbox = CreateCheckbox(sec3, "LoginMessage", "Show Login Message",
        "When enabled, shows a short \"EasyFind loaded!\" message in chat when you log in.\n\nDisable to keep chat cleaner.")
    loginMessageCheckbox:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_RIGHT, -14)
    loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage ~= false)
    loginMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showLoginMessage = self:GetChecked()
    end)
    optionsFrame.loginMessageCheckbox = loginMessageCheckbox

    local minimapBtnCheckbox = CreateCheckbox(sec3, "MinimapBtn", "Show Minimap Button",
        "When enabled, adds a small search icon button to the minimap edge.\n\nLeft-click the button to toggle the search bar.\nRight-click to open options.\nDrag to reposition it around the minimap.")
    minimapBtnCheckbox:SetPoint("TOPLEFT", loginMessageCheckbox, "BOTTOMLEFT", 0, -4)
    minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton or false)
    minimapBtnCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showMinimapButton = self:GetChecked()
        EasyFind:UpdateMinimapButton()
    end)
    optionsFrame.minimapBtnCheckbox = minimapBtnCheckbox

    -- SECTION 2: UI Search
    local sec1 = CreateSection("UI Search", 135)

    local resizeUIBtn = CreateFrame("Button", nil, sec1, "UIPanelButtonTemplate")
    resizeUIBtn:SetSize(160, 24)
    resizeUIBtn:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_LEFT, -10)
    resizeUIBtn:SetText("Resize UI Search")
    resizeUIBtn:SetScript("OnClick", function()
        if ns.Rescaler then ns.Rescaler:Enter("ui") end
    end)
    resizeUIBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Visually resize the UI search bar and its results dropdown.\nDrag edges for width, corners for scale.")
        GameTooltip:Show()
    end)
    resizeUIBtn:SetScript("OnLeave", GameTooltip_Hide)

    local smartShowCheckbox = CreateCheckbox(sec1, "SmartShow", "Smart Show (auto-hide)",
        "When enabled, the UI search bar hides itself until you move your mouse near its position.\n\nThe bar reappears when your mouse enters the area and fades away when you move away.")
    smartShowCheckbox:SetPoint("TOPLEFT", resizeUIBtn, "BOTTOMLEFT", 0, -8)
    smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.smartShow = self:GetChecked()
        if ns.UI and ns.UI.UpdateSmartShow then
            ns.UI:UpdateSmartShow()
        end
    end)
    optionsFrame.smartShowCheckbox = smartShowCheckbox

    local staticOpacityCheckbox = CreateCheckbox(sec1, "StaticOpacity", "Static Opacity",
        "When enabled, the search bar keeps the same opacity at all times.\n\nWhen disabled (default), opacity is reduced while your character is moving so you can see the game world better, similar to how the World Map behaves.\n\nThis only applies to the main search bar. Map search bars follow the World Map's built-in fade behavior.")
    staticOpacityCheckbox:SetPoint("TOPLEFT", smartShowCheckbox, "BOTTOMLEFT", 0, -4)
    staticOpacityCheckbox:SetChecked(EasyFind.db.staticOpacity or false)
    staticOpacityCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.staticOpacity = self:GetChecked()
        if ns.UI and ns.UI.UpdateOpacity then
            ns.UI:UpdateOpacity()
        end
    end)
    optionsFrame.staticOpacityCheckbox = staticOpacityCheckbox

    local uiResultsAboveCheckbox = CreateCheckbox(sec1, "UIResultsAbove", "UI Results Above",
        "When enabled, the UI search bar shows results above the bar instead of below.\n\nUseful if you place the search bar near the bottom of your screen.")
    uiResultsAboveCheckbox:SetPoint("TOPLEFT", staticOpacityCheckbox, "BOTTOMLEFT", 0, -4)
    uiResultsAboveCheckbox:SetChecked(EasyFind.db.uiResultsAbove or false)
    uiResultsAboveCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.uiResultsAbove = self:GetChecked()
    end)
    optionsFrame.uiResultsAboveCheckbox = uiResultsAboveCheckbox

    local directOpenCheckbox = CreateCheckbox(sec1, "DirectOpen", "Open Panels Directly",
        "When enabled, clicking a UI search result will immediately open the destination panel.\n\nWhen disabled (default), you will be guided step-by-step with highlights showing you where to click.")
    directOpenCheckbox:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_RIGHT, -10)
    directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    directOpenCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = self:GetChecked()
    end)
    optionsFrame.directOpenCheckbox = directOpenCheckbox

    local themeLabel = sec1:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", directOpenCheckbox, "BOTTOMLEFT", 4, -10)
    themeLabel:SetText("Theme:")

    local themeChoices = {"Classic", "Retail"}

    local themeBtnFrame, themeBtnText = CreateFlyoutSelector(
        sec1, "EasyFindTheme", 90, themeLabel, EasyFind.db.resultsTheme or "Retail"
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

    -- SECTION 3: Map Search
    local sec2 = CreateSection("Map Search", 135)

    local resizeMapBtn = CreateFrame("Button", nil, sec2, "UIPanelButtonTemplate")
    resizeMapBtn:SetSize(160, 24)
    resizeMapBtn:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_LEFT, -10)
    resizeMapBtn:SetText("Resize Map Search")
    resizeMapBtn:SetScript("OnClick", function()
        if ns.Rescaler then ns.Rescaler:Enter("map") end
    end)
    resizeMapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Visually resize the map search bars and results dropdown.\nDrag edges for width, corners for scale.")
        GameTooltip:Show()
    end)
    resizeMapBtn:SetScript("OnLeave", GameTooltip_Hide)

    local mapResultsAboveCheckbox = CreateCheckbox(sec2, "MapResultsAbove", "Map Results Above",
        "When enabled, map search bars show results above the bar instead of below.\n\nApplies to both local and global map search bars.")
    mapResultsAboveCheckbox:SetPoint("TOPLEFT", resizeMapBtn, "BOTTOMLEFT", 0, -8)
    mapResultsAboveCheckbox:SetChecked(EasyFind.db.mapResultsAbove or false)
    mapResultsAboveCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.mapResultsAbove = self:GetChecked()
    end)
    optionsFrame.mapResultsAboveCheckbox = mapResultsAboveCheckbox

    local zoneNavCheckbox = CreateCheckbox(sec2, "ZoneNav", "Navigate Zones Directly",
        "When enabled, clicking a zone search result will immediately open that zone's map.\n\nWhen disabled (default), the zone will be highlighted on the current map so you can see where it is.")
    zoneNavCheckbox:SetPoint("TOPLEFT", mapResultsAboveCheckbox, "BOTTOMLEFT", 0, -4)
    zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    zoneNavCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.navigateToZonesDirectly = self:GetChecked()
    end)
    optionsFrame.zoneNavCheckbox = zoneNavCheckbox

    local mapIconSlider = CreateSlider(sec2, "MapIcon", "Icon Size", 0.5, 2.0, 0.1,
        "Adjusts the size of search icons on the world map and in UI search.")
    mapIconSlider:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_RIGHT, -28)
    mapIconSlider:SetValue(EasyFind.db.iconScale or 1.0)
    mapIconSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.iconScale = value
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then
            ns.MapSearch:UpdateIconScales()
        end
        local uiInd = _G["EasyFindIndicatorFrame"]
        if uiInd then
            uiInd:SetScale(EasyFind.db.iconScale or 1.0)
        end
    end)
    optionsFrame.mapIconSlider = mapIconSlider

    local arrivalSlider = CreateSlider(sec2, "ArrivalDist", "Arrival Distance", 3, 50, 1,
        "How close (in yards) you must be to a tracked location before the waypoint auto-clears.",
        function(val) return tostring(mfloor(val + 0.5)) .. "yd" end)
    arrivalSlider:SetPoint("TOPLEFT", mapIconSlider, "BOTTOMLEFT", 0, -38)
    arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    arrivalSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.arrivalDistance = value
    end)
    optionsFrame.arrivalSlider = arrivalSlider

    local blinkingPinsCheckbox = CreateCheckbox(sec2, "BlinkingPins", "Blinking Map Pins",
        "When enabled, map search pins and highlight boxes pulse/blink to draw attention.\n\nWhen disabled (default), pins and highlights are shown with a steady glow. The indicator arrow still bobs.")
    blinkingPinsCheckbox:SetPoint("TOPLEFT", zoneNavCheckbox, "BOTTOMLEFT", 0, -4)
    blinkingPinsCheckbox:SetChecked(EasyFind.db.blinkingPins or false)
    blinkingPinsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.blinkingPins = self:GetChecked()
    end)
    optionsFrame.blinkingPinsCheckbox = blinkingPinsCheckbox

    -- SECTION 4: Keyboard Shortcuts
    local sec4 = CreateSection("Keyboard Shortcuts", 220)

    local shortcutText = sec4:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shortcutText:SetPoint("TOPLEFT", sec4, "TOPLEFT", 14, -8)
    shortcutText:SetWidth(FRAME_W - 60)
    shortcutText:SetJustifyH("LEFT")
    shortcutText:SetSpacing(2)
    shortcutText:SetText(
        "|cFFFFD100Toggle+Focus|r is the recommended keybind for fast, keyboard-driven searching. "
        .. "It opens the search bar and places the cursor in it. Press it again to close. "
        .. "When the world map is open, it focuses the local map search bar instead.\n\n"
        .. "|cFFFFD100Search bar navigation:|r\n"
        .. "|cFF00FF00Down|r  Enter search results from search box\n"
        .. "|cFF00FF00Tab / Shift+Tab|r  Cycle between search box, clear, and filter buttons\n"
        .. "|cFF00FF00Enter|r  Activate focused button or highlighted result\n"
        .. "|cFF00FF00Escape|r  Remove cursor from search bar\n\n"
        .. "|cFFFFD100While navigating results:|r\n"
        .. "|cFF00FF00Up / Down|r  Move through results one at a time\n"
        .. "|cFF00FF00Tab / Shift+Tab|r  Toggle focus between result row and nav button\n"
        .. "|cFF00FF00Page Up / Page Down|r  Jump 5 results\n"
        .. "|cFF00FF00Home / End|r  Jump to first / last result\n"
        .. "|cFF00FF00Ctrl+Up / Ctrl+Down|r  Jump to first / last result\n\n"
        .. "|cFFFFD100Map search bar switching:|r\n"
        .. "|cFF00FF00Ctrl+Tab|r  Switch between local and global search bar\n\n"
        .. "|cFFFFD100Other:|r\n"
        .. "|cFF00FF00Shift+Drag|r  Reposition search bars\n"
        .. "|cFF00FF00Right-click|r a result to pin/unpin it"
    )
    -- Keybind buttons
    local KEYBIND_TOP = -8  -- offset below shortcutText (added dynamically)
    local KEYBIND_ROW_H = 28
    local KEYBIND_BTN_W = 140

    local keybindDefs = {
        { label = "Toggle Bar",    action = "EASYFIND_TOGGLE" },
        { label = "Focus Bar",     action = "EASYFIND_FOCUS" },
        { label = "Toggle+Focus",  action = "EASYFIND_TOGGLE_FOCUS" },
        { label = "Clear All",     action = "EASYFIND_CLEAR" },
    }

    local keybindTooltips = {
        EASYFIND_TOGGLE       = { "Toggle Search Bar", "Shows or hides the main search bar." },
        EASYFIND_FOCUS        = { "Focus Search Bar", "Places the cursor in the search bar without toggling visibility." },
        EASYFIND_TOGGLE_FOCUS = { "Toggle + Focus", "Opens and focuses the search bar in one press. When the map is open, focuses the local map search bar instead." },
        EASYFIND_CLEAR        = { "Clear All", "Dismisses all active highlights, map pins, zone highlights, and pending waypoints." },
    }

    local keybindButtons = {}
    local prevKeybindRow
    for i, def in ipairs(keybindDefs) do
        local rowLabel = sec4:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        if i == 1 then
            rowLabel:SetPoint("TOPLEFT", shortcutText, "BOTTOMLEFT", 0, -12)
        else
            rowLabel:SetPoint("TOPLEFT", prevKeybindRow, "BOTTOMLEFT", 0, -6)
        end
        rowLabel:SetText(def.label .. ":")

        local keybindBtn = CreateFrame("Button", nil, sec4, "UIPanelButtonTemplate")
        keybindBtn:SetSize(KEYBIND_BTN_W, 22)
        keybindBtn:SetPoint("LEFT", rowLabel, "LEFT", 110, 0)
        keybindBtn:SetText(GetCurrentKeybindText(def.action))
        keybindBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                local old1, old2 = GetBindingKey(def.action)
                if old1 then SetBinding(old1) end
                if old2 then SetBinding(old2) end
                SaveBindings(GetCurrentBindingSet())
                self:SetText("Not Bound")
                EasyFind:Print("Keybind cleared.")
            else
                StartCapture(self, def.action)
            end
        end)
        keybindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local tip = keybindTooltips[def.action]
        if tip then
            MakeKeybindTooltip(keybindBtn, tip[1], tip[2])
        end

        keybindButtons[def.action] = keybindBtn
        prevKeybindRow = rowLabel
    end
    optionsFrame.keybindBtn = keybindButtons["EASYFIND_TOGGLE"]
    optionsFrame.focusBtn = keybindButtons["EASYFIND_FOCUS"]
    optionsFrame.toggleFocusBtn = keybindButtons["EASYFIND_TOGGLE_FOCUS"]
    optionsFrame.clearBtn = keybindButtons["EASYFIND_CLEAR"]

    -- Auto-size section to text + keybind buttons
    C_Timer.After(0, function()
        local textH = shortcutText:GetStringHeight()
        if textH and textH > 0 then
            local keybindAreaH = 12 + #keybindDefs * KEYBIND_ROW_H
            local newH = textH + keybindAreaH + 20
            sec4:SetHeight(newH)
            for _, section in ipairs(optionsFrame.sections) do
                if section.content == sec4 then
                    section.contentHeight = newH
                    break
                end
            end
        end
    end)

    -- BOTTOM - Separator, Tips, Reset buttons
    sep = optionsFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)

    instructionText = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instructionText:SetWidth(FRAME_W - 44)
    instructionText:SetJustifyH("LEFT")
    instructionText:SetText("|cFFFFFF00Tips:|r  Hold |cFF00FF00Shift|r + drag to reposition bars  |cFF888888|||r  |cFF00FF00/ef o|r options\n|cFF00FF00/ef show|r  |cFF00FF00/ef hide|r toggle bar (or click minimap button)  |cFF888888|||r  |cFF00FF00/ef clear|r dismiss highlights")

    StaticPopupDialogs["EASYFIND_RESET_ALL"] = {
        text = "Reset all EasyFind settings to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetAll() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_POSITIONS"] = {
        text = "Reset all EasyFind search bar positions to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetPositions() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    local resetAllBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(130, 22)
    resetAllBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 30, 18)
    resetAllBtn:SetText("Reset All Settings")
    resetAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_ALL")
    end)

    local resetPosBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetPosBtn:SetSize(130, 22)
    resetPosBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -30, 18)
    resetPosBtn:SetText("Reset Positions")
    resetPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_POSITIONS")
    end)

    -- Initial layout (all collapsed)
    RelayoutSections()

    optionsFrame:Hide()

    self:RegisterWithBlizzardOptions()
end

function Options:DoResetPositions()
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    if ns.UI and ns.UI.ResetPosition then ns.UI:ResetPosition() end
    if ns.MapSearch and ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
    EasyFind:Print("Search bar positions reset to defaults.")
end

function Options:DoResetAll()
    EasyFind.db.iconScale = 1.0
    EasyFind.db.uiSearchScale = 1.0
    EasyFind.db.mapSearchScale = 1.0
    EasyFind.db.mapSearchWidth = 1.0
    EasyFind.db.uiSearchWidth = 1.0
    EasyFind.db.uiResultsScale = 1.0
    EasyFind.db.uiResultsWidth = 1.0
    EasyFind.db.mapResultsScale = 1.0
    EasyFind.db.mapResultsWidth = 1.0
    EasyFind.db.searchBarOpacity = DEFAULT_OPACITY
    EasyFind.db.fontSize = 1.0
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    EasyFind.db.directOpen = false
    EasyFind.db.navigateToZonesDirectly = false
    EasyFind.db.smartShow = false
    EasyFind.db.resultsTheme = "Retail"
    EasyFind.db.maxResults = 6
    EasyFind.db.pinsCollapsed = false
    EasyFind.db.staticOpacity = false
    EasyFind.db.indicatorStyle = "EasyFind Arrow"
    EasyFind.db.indicatorColor = "Yellow"
    EasyFind.db.blinkingPins = false
    EasyFind.db.showLoginMessage = true
    EasyFind.db.uiResultsAbove = false
    EasyFind.db.mapResultsAbove = false
    EasyFind.db.showMinimapButton = true
    EasyFind.db.arrivalDistance = 10
    EasyFind.db.panelOpacity = 0.9
    EasyFind.db.visible = true

    if ns.Highlight then
        ns.Highlight:ClearAll()
    end
    if ns.MapSearch then
        ns.MapSearch:ClearHighlight()
        ns.MapSearch:ClearZoneHighlight()
    end

    local old1, old2 = GetBindingKey("EASYFIND_TOGGLE")
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end

    old1, old2 = GetBindingKey("EASYFIND_FOCUS")
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end

    old1, old2 = GetBindingKey("EASYFIND_TOGGLE_FOCUS")
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end

    old1, old2 = GetBindingKey("EASYFIND_CLEAR")
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end
    SaveBindings(GetCurrentBindingSet())

    optionsFrame.mapIconSlider:SetValue(1.0)
    optionsFrame.panelOpacitySlider:SetValue(0.9)
    optionsFrame.opacitySlider:SetValue(DEFAULT_OPACITY)
    optionsFrame.fontSlider:SetValue(1.0)
    optionsFrame.directOpenCheckbox:SetChecked(false)
    optionsFrame.zoneNavCheckbox:SetChecked(false)
    optionsFrame.smartShowCheckbox:SetChecked(false)
    optionsFrame.staticOpacityCheckbox:SetChecked(false)
    optionsFrame.blinkingPinsCheckbox:SetChecked(false)
    optionsFrame.loginMessageCheckbox:SetChecked(true)
    optionsFrame.uiResultsAboveCheckbox:SetChecked(false)
    optionsFrame.mapResultsAboveCheckbox:SetChecked(false)
    optionsFrame.minimapBtnCheckbox:SetChecked(false)
    optionsFrame.arrivalSlider:SetValue(10)
    optionsFrame.themeBtnText:SetText("Retail")
    optionsFrame.indicatorBtnText:SetText("EasyFind Arrow")
    optionsFrame.colorBtnText:SetText("Yellow")
    optionsFrame.colorBtnText:SetTextColor(1.0, 1.0, 0.0)
    optionsFrame.colorSwatch:SetColorTexture(1.0, 1.0, 0.0, 1)
    optionsFrame.keybindBtn:SetText("Not Bound")
    optionsFrame.focusBtn:SetText("Not Bound")
    optionsFrame.toggleFocusBtn:SetText("Not Bound")

    if ns.UI and ns.UI.ResetPosition then ns.UI:ResetPosition() end
    if ns.UI and ns.UI.UpdateScale then ns.UI:UpdateScale() end
    if ns.UI and ns.UI.UpdateWidth then ns.UI:UpdateWidth() end
    if ns.UI and ns.UI.UpdateOpacity then ns.UI:UpdateOpacity() end
    if ns.UI and ns.UI.UpdateSmartShow then ns.UI:UpdateSmartShow() end
    if ns.UI and ns.UI.UpdateFontSize then ns.UI:UpdateFontSize() end
    if ns.UI and ns.UI.RefreshResults then ns.UI:RefreshResults() end
    if ns.MapSearch and ns.MapSearch.UpdateSearchBarTheme then ns.MapSearch:UpdateSearchBarTheme() end
    if ns.MapSearch and ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
    if ns.MapSearch and ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
    if ns.MapSearch and ns.MapSearch.UpdateWidth then ns.MapSearch:UpdateWidth() end
    if ns.MapSearch and ns.MapSearch.UpdateFontSize then ns.MapSearch:UpdateFontSize() end
    if ns.MapSearch and ns.MapSearch.UpdateIconScales then ns.MapSearch:UpdateIconScales() end
    if ns.MapSearch and ns.MapSearch.RefreshIndicators then ns.MapSearch:RefreshIndicators() end
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then uiInd:SetScale(1.0) end
    if ns.MapSearch and ns.MapSearch.UpdateOpacity then ns.MapSearch:UpdateOpacity() end
    if ns.UI and ns.UI.Show then ns.UI:Show() end
    EasyFind:UpdateMinimapButton()

    EasyFind:Print("All settings reset to defaults.")
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

    -- Collapse all sections on open for a clean view
    for _, section in ipairs(optionsFrame.sections) do
        section.expanded = false
        section.icon:SetAtlas("QuestLog-icon-expand")
        section.content:Hide()
    end

    -- Refresh values from saved vars
    optionsFrame.panelOpacitySlider:SetValue(EasyFind.db.panelOpacity or 0.9)
    optionsFrame.opacitySlider:SetValue(EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
    optionsFrame.fontSlider:SetValue(EasyFind.db.fontSize or 1.0)
    optionsFrame.mapIconSlider:SetValue(EasyFind.db.iconScale or 1.0)
    optionsFrame.arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    optionsFrame.directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    optionsFrame.smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    optionsFrame.staticOpacityCheckbox:SetChecked(EasyFind.db.staticOpacity or false)
    optionsFrame.blinkingPinsCheckbox:SetChecked(EasyFind.db.blinkingPins or false)
    optionsFrame.loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage ~= false)
    optionsFrame.uiResultsAboveCheckbox:SetChecked(EasyFind.db.uiResultsAbove or false)
    optionsFrame.mapResultsAboveCheckbox:SetChecked(EasyFind.db.mapResultsAbove or false)
    optionsFrame.minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton or false)
    optionsFrame.themeBtnText:SetText(EasyFind.db.resultsTheme or "Retail")
    optionsFrame.indicatorBtnText:SetText(EasyFind.db.indicatorStyle or "EasyFind Arrow")
    local clr = EasyFind.db.indicatorColor or "Yellow"
    local rgb = ns.INDICATOR_COLORS[clr] or ns.INDICATOR_COLORS.Yellow
    optionsFrame.colorBtnText:SetText(clr)
    optionsFrame.colorBtnText:SetTextColor(rgb[1], rgb[2], rgb[3])
    optionsFrame.colorSwatch:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)

    local key1 = GetBindingKey("EASYFIND_TOGGLE")
    optionsFrame.keybindBtn:SetText(key1 or "Not Bound")
    local key2 = GetBindingKey("EASYFIND_FOCUS")
    optionsFrame.focusBtn:SetText(key2 or "Not Bound")
    local key3 = GetBindingKey("EASYFIND_TOGGLE_FOCUS")
    optionsFrame.toggleFocusBtn:SetText(key3 or "Not Bound")
    local key4 = GetBindingKey("EASYFIND_CLEAR")
    optionsFrame.clearBtn:SetText(key4 or "Not Bound")

    optionsFrame:SetBackdropColor(0.12, 0.10, 0.08, EasyFind.db.panelOpacity or 0.9)
    optionsFrame.RelayoutSections()
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
