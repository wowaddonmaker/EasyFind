local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local sformat = Utils.sformat
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tonumber, tostring = Utils.tonumber, Utils.tostring
local tinsert = Utils.tinsert
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

    -- =====================================================================
    -- Collapsible section infrastructure
    -- =====================================================================
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

    -- =====================================================================
    -- Keybind helpers (defined early since Section 4 needs them)
    -- =====================================================================
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

    local function MakeKeybindTooltip(btn, titleText, line1)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(titleText)
            GameTooltip:AddLine(line1, 1, 1, 1)
            GameTooltip:AddLine("Right-click to clear. Escape to cancel.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end

    -- =====================================================================
    -- SECTION 1: Search Bars
    -- =====================================================================
    local sec1 = CreateSection("Search Bars", 200)

    -- Left column: sliders
    local uiSearchSlider = CreateSlider(sec1, "UISearch", "UI Search Bar Size", 0.5, 1.5, 0.1,
        "Adjusts the size of the UI search bar. Hold Shift and drag to move it.")
    uiSearchSlider:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_LEFT, -28)
    uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    uiSearchSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.uiSearchScale = value
        if ns.UI and ns.UI.UpdateScale then
            ns.UI:UpdateScale()
        end
    end)
    optionsFrame.uiSearchSlider = uiSearchSlider

    local mapSearchSlider = CreateSlider(sec1, "MapSearch", "Map Search Bar Size", 0.5, 1.5, 0.1,
        "Adjusts the size of the map search bar. Hold Shift and drag to move it along the map edge.")
    mapSearchSlider:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_LEFT, -93)
    mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    mapSearchSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.mapSearchScale = value
        if ns.MapSearch and ns.MapSearch.UpdateScale then
            ns.MapSearch:UpdateScale()
        end
    end)
    optionsFrame.mapSearchSlider = mapSearchSlider

    local opacitySlider = CreateSlider(sec1, "Opacity", "Search Bar Opacity", 0.2, 1.0, 0.05,
        "Adjusts the opacity (transparency) of both the UI search bar and the map search bars.")
    opacitySlider:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_LEFT, -158)
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

    -- Right column: checkboxes
    local smartShowCheckbox = CreateCheckbox(sec1, "SmartShow", "Smart Show (auto-hide)",
        "When enabled, the UI search bar hides itself until you move your mouse near its position.\n\nThe bar reappears when your mouse enters the area and fades away when you move away.")
    smartShowCheckbox:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_RIGHT, -8)
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

    local mapResultsAboveCheckbox = CreateCheckbox(sec1, "MapResultsAbove", "Map Results Above",
        "When enabled, map search bars show results above the bar instead of below.\n\nApplies to both local and global map search bars.")
    mapResultsAboveCheckbox:SetPoint("TOPLEFT", uiResultsAboveCheckbox, "BOTTOMLEFT", 0, -4)
    mapResultsAboveCheckbox:SetChecked(EasyFind.db.mapResultsAbove or false)
    mapResultsAboveCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.mapResultsAbove = self:GetChecked()
    end)
    optionsFrame.mapResultsAboveCheckbox = mapResultsAboveCheckbox

    -- =====================================================================
    -- SECTION 2: Search Results
    -- =====================================================================
    local sec2 = CreateSection("Search Results", 140)

    -- Left column: slider + theme
    local maxResultsSlider = CreateSlider(sec2, "MaxResults", "Max Search Results", 3, 24, 1,
        "Maximum number of search results to display in the dropdown (3-24).",
        function(val) return tostring(mfloor(val + 0.5)) end)
    maxResultsSlider:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_LEFT, -28)
    maxResultsSlider:SetValue(EasyFind.db.maxResults or 10)
    maxResultsSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.maxResults = value
        if ns.UI and ns.UI.RefreshResults then
            ns.UI:RefreshResults()
        end
    end)
    optionsFrame.maxResultsSlider = maxResultsSlider

    -- Theme selector (below slider on the left)
    local themeLabel = sec2:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_LEFT + 4, -88)
    themeLabel:SetText("Theme:")

    local themeChoices = {"Classic", "Retail"}

    local themeBtnFrame, themeBtnText = CreateFlyoutSelector(
        sec2, "EasyFindTheme", 90, themeLabel, EasyFind.db.resultsTheme or "Retail"
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

    -- Right column: checkboxes
    local directOpenCheckbox = CreateCheckbox(sec2, "DirectOpen", "Open Panels Directly",
        "When enabled, clicking a UI search result will immediately open the destination panel.\n\nWhen disabled (default), you will be guided step-by-step with highlights showing you where to click.")
    directOpenCheckbox:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_RIGHT, -8)
    directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    directOpenCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = self:GetChecked()
    end)
    optionsFrame.directOpenCheckbox = directOpenCheckbox

    local zoneNavCheckbox = CreateCheckbox(sec2, "ZoneNav", "Navigate to Zones Directly",
        "When enabled, clicking a zone search result will immediately open that zone's map.\n\nWhen disabled (default), the zone will be highlighted on the current map so you can see where it is.")
    zoneNavCheckbox:SetPoint("TOPLEFT", directOpenCheckbox, "BOTTOMLEFT", 0, -4)
    zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    zoneNavCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.navigateToZonesDirectly = self:GetChecked()
    end)
    optionsFrame.zoneNavCheckbox = zoneNavCheckbox

    local truncMessageCheckbox = CreateCheckbox(sec2, "TruncMessage", "Show \"More Results\" Message",
        "When enabled, shows a message at the bottom of search results when more items exist than can be displayed.\n\nIncrease the max results slider on the left to see more items.")
    truncMessageCheckbox:SetPoint("TOPLEFT", zoneNavCheckbox, "BOTTOMLEFT", 0, -4)
    truncMessageCheckbox:SetChecked(EasyFind.db.showTruncationMessage ~= false)
    truncMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showTruncationMessage = self:GetChecked()
        if ns.UI and ns.UI.RefreshResults then
            ns.UI:RefreshResults()
        end
    end)
    optionsFrame.truncMessageCheckbox = truncMessageCheckbox

    local hardCapCheckbox = CreateCheckbox(sec2, "HardCap", "Hard Results Cap",
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

    -- =====================================================================
    -- SECTION 3: Map & Navigation
    -- =====================================================================
    local sec3 = CreateSection("Map & Navigation", 200)

    -- Left column: sliders
    local mapIconSlider = CreateSlider(sec3, "MapIcon", "Icon Size", 0.5, 2.0, 0.1,
        "Adjusts the size of search icons on the world map and in UI search.")
    mapIconSlider:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_LEFT, -28)
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

    local minimapMarkerSlider = CreateSlider(sec3, "MinimapMarker", "Minimap Marker Size", 12, 36, 1,
        "Adjusts the size of the destination marker shown on the minimap when tracking a location.",
        function(val) return tostring(mfloor(val + 0.5)) .. "px" end)
    minimapMarkerSlider:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_LEFT, -93)
    minimapMarkerSlider:SetValue(EasyFind.db.minimapMarkerSize or 25)
    minimapMarkerSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.minimapMarkerSize = value
        if ns.MapSearch and ns.MapSearch.UpdateMinimapMarkerSize then
            ns.MapSearch:UpdateMinimapMarkerSize()
        end
    end)
    optionsFrame.minimapMarkerSlider = minimapMarkerSlider

    local arrivalSlider = CreateSlider(sec3, "ArrivalDist", "Arrival Distance", 3, 20, 1,
        "How close (in yards) you must be to a tracked location before the waypoint auto-clears.",
        function(val) return tostring(mfloor(val + 0.5)) .. "yd" end)
    arrivalSlider:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_LEFT, -158)
    arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    arrivalSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.arrivalDistance = value
    end)
    optionsFrame.arrivalSlider = arrivalSlider

    -- Right column: indicator selectors + checkbox
    local indicatorLabel = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    indicatorLabel:SetPoint("TOPLEFT", sec3, "TOPLEFT", COL_RIGHT + 4, -14)
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

    -- Indicator Color selector
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

    -- Blinking pins checkbox
    local blinkingPinsCheckbox = CreateCheckbox(sec3, "BlinkingPins", "Blinking Map Pins",
        "When enabled, map search pins and highlight boxes pulse/blink to draw attention.\n\nWhen disabled (default), pins and highlights are shown with a steady glow. The indicator arrow still bobs.")
    blinkingPinsCheckbox:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", -4, -14)
    blinkingPinsCheckbox:SetChecked(EasyFind.db.blinkingPins or false)
    blinkingPinsCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.blinkingPins = self:GetChecked()
    end)
    optionsFrame.blinkingPinsCheckbox = blinkingPinsCheckbox

    -- =====================================================================
    -- SECTION 4: Keybinds & General
    -- =====================================================================
    local sec4 = CreateSection("Keybinds & General", 110)

    -- Toggle Search Bar keybind
    local toggleLabel = sec4:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toggleLabel:SetPoint("TOPLEFT", sec4, "TOPLEFT", COL_LEFT + 4, -14)
    toggleLabel:SetText("Toggle Bar:")

    local keybindBtn = CreateFrame("Button", "EasyFindKeybindButton", sec4, "UIPanelButtonTemplate")
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
    local focusLabel = sec4:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    focusLabel:SetPoint("TOPLEFT", toggleLabel, "BOTTOMLEFT", 0, -10)
    focusLabel:SetText("Focus Bar:")

    local focusBtn = CreateFrame("Button", "EasyFindFocusKeybindButton", sec4, "UIPanelButtonTemplate")
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

    -- Login message checkbox (right column)
    local loginMessageCheckbox = CreateCheckbox(sec4, "LoginMessage", "Show Login Message",
        "When enabled, shows a short \"EasyFind loaded!\" message in chat when you log in.\n\nDisable to keep chat cleaner.")
    loginMessageCheckbox:SetPoint("TOPLEFT", sec4, "TOPLEFT", COL_RIGHT, -12)
    loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage ~= false)
    loginMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showLoginMessage = self:GetChecked()
    end)
    optionsFrame.loginMessageCheckbox = loginMessageCheckbox

    local minimapBtnCheckbox = CreateCheckbox(sec4, "MinimapBtn", "Show Minimap Button",
        "When enabled, adds a small search icon button to the minimap edge.\n\nLeft-click the button to toggle the search bar.\nRight-click to open options.\nDrag to reposition it around the minimap.")
    minimapBtnCheckbox:SetPoint("TOPLEFT", loginMessageCheckbox, "BOTTOMLEFT", 0, -4)
    minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton or false)
    minimapBtnCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showMinimapButton = self:GetChecked()
        EasyFind:UpdateMinimapButton()
    end)
    optionsFrame.minimapBtnCheckbox = minimapBtnCheckbox

    -- =====================================================================
    -- BOTTOM — Separator, Tips, Reset buttons
    -- =====================================================================
    sep = optionsFrame:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)

    instructionText = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instructionText:SetWidth(FRAME_W - 44)
    instructionText:SetJustifyH("LEFT")
    instructionText:SetText("|cFFFFFF00Tips:|r  Hold |cFF00FF00Shift|r + drag to reposition bars  |cFF888888|||r  |cFF00FF00/ef o|r options\n|cFF00FF00/ef show|r  |cFF00FF00/ef hide|r toggle bar  |cFF888888|||r  |cFF00FF00/ef clear|r dismiss highlights")

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
        EasyFind.db.smartShow = false
        EasyFind.db.resultsTheme = "Retail"
        EasyFind.db.maxResults = 10
        EasyFind.db.showTruncationMessage = true
        EasyFind.db.hardResultsCap = false
        EasyFind.db.pinsCollapsed = false
        EasyFind.db.staticOpacity = false
        EasyFind.db.indicatorStyle = "EasyFind Arrow"
        EasyFind.db.indicatorColor = "Yellow"
        EasyFind.db.blinkingPins = false
        EasyFind.db.showLoginMessage = true
        EasyFind.db.uiResultsAbove = false
        EasyFind.db.mapResultsAbove = false
        EasyFind.db.showMinimapButton = true
        EasyFind.db.minimapMarkerSize = 25
        EasyFind.db.arrivalDistance = 10
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
        optionsFrame.blinkingPinsCheckbox:SetChecked(false)
        optionsFrame.loginMessageCheckbox:SetChecked(true)
        optionsFrame.uiResultsAboveCheckbox:SetChecked(false)
        optionsFrame.mapResultsAboveCheckbox:SetChecked(false)
        optionsFrame.minimapBtnCheckbox:SetChecked(false)
        optionsFrame.maxResultsSlider:SetValue(10)
        optionsFrame.minimapMarkerSlider:SetValue(25)
        optionsFrame.arrivalSlider:SetValue(10)
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
        local uiInd = _G["EasyFindIndicatorFrame"]
        if uiInd then uiInd:SetScale(1.0) end
        if ns.MapSearch and ns.MapSearch.UpdateOpacity then ns.MapSearch:UpdateOpacity() end
        if ns.UI and ns.UI.Show then ns.UI:Show() end
        EasyFind:UpdateMinimapButton()

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

    -- Initial layout (all collapsed)
    RelayoutSections()

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

    -- Collapse all sections on open for a clean view
    for _, section in ipairs(optionsFrame.sections) do
        section.expanded = false
        section.icon:SetAtlas("QuestLog-icon-expand")
        section.content:Hide()
    end

    -- Refresh values from saved vars
    optionsFrame.mapIconSlider:SetValue(EasyFind.db.iconScale or 1.0)
    optionsFrame.uiSearchSlider:SetValue(EasyFind.db.uiSearchScale or 1.0)
    optionsFrame.mapSearchSlider:SetValue(EasyFind.db.mapSearchScale or 1.0)
    optionsFrame.opacitySlider:SetValue(EasyFind.db.searchBarOpacity or 1.0)
    optionsFrame.maxResultsSlider:SetValue(EasyFind.db.maxResults or 10)
    optionsFrame.minimapMarkerSlider:SetValue(EasyFind.db.minimapMarkerSize or 25)
    optionsFrame.arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    optionsFrame.directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    optionsFrame.smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    optionsFrame.truncMessageCheckbox:SetChecked(EasyFind.db.showTruncationMessage ~= false)
    optionsFrame.hardCapCheckbox:SetChecked(EasyFind.db.hardResultsCap or false)
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
