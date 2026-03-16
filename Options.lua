local _, ns = ...

local Options = {}
ns.Options = Options

local Utils   = ns.Utils
local sformat = Utils.sformat
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local tonumber, tostring = Utils.tonumber, Utils.tostring
local tinsert, tconcat = Utils.tinsert, Utils.tconcat
local IsMouseButtonDown = IsMouseButtonDown

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
        local flyoutBtn = CreateFrame("Button", nil, flyout)
        flyoutBtn:SetSize(itemWidth, 18)
        flyoutBtn:SetPoint("TOPLEFT", flyout, "TOPLEFT", 3, -3 - (i - 1) * 20)
        flyoutBtn:SetNormalFontObject("GameFontHighlightSmall")
        flyoutBtn:SetHighlightFontObject("GameFontNormalSmall")
        flyoutBtn:SetText(name)
        flyoutBtn:SetScript("OnClick", function()
            onSelect(name)
            flyout:Hide()
        end)
    end
end

-- Helper to create a slider (anchored manually by caller)
local function CreateSlider(parent, name, label, minVal, maxVal, step, tooltipText, formatFunc, defaultValue, unitSuffix)
    local slider = CreateFrame("Slider", "EasyFindOptions" .. name .. "Slider", parent, "OptionsSliderTemplate")
    slider:SetWidth(160)
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

    local suffixText = isPercentage and "%" or unitSuffix
    if suffixText then
        local suffixLabel = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        suffixLabel:SetPoint("LEFT", inputBox, "RIGHT", 2, 0)
        suffixLabel:SetText(suffixText)
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

    if defaultValue then
        local resetBtn = CreateFrame("Button", nil, slider)
        resetBtn:SetSize(30, 12)
        resetBtn:SetPoint("TOP", inputBox, "BOTTOM", 0, -1)
        local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        resetText:SetPoint("CENTER")
        resetText:SetText("Reset")
        resetBtn:SetScript("OnEnter", function()
            resetText:SetTextColor(1, 1, 1)
        end)
        resetBtn:SetScript("OnLeave", function()
            resetText:SetTextColor(0.5, 0.5, 0.5)
        end)
        resetBtn:SetScript("OnClick", function()
            slider:SetValue(defaultValue)
        end)
        slider.resetBtn = resetBtn
    end

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

-- Multi-select dropdown: a label + button that opens a flyout with checkboxes.
-- optionDefs: array of { label, dbKey, default, tooltip, callback }
-- Returns a wrapper frame with :UpdateVisuals(), :SetGroupEnabled(bool),
-- :AddSlider(...), and .flyout / .checkRows / .sliders fields.
local function CreateMultiSelectDropdown(parent, groupLabel, optionDefs, btnWidth, flyoutWidth)
    btnWidth = btnWidth or 160
    flyoutWidth = flyoutWidth or btnWidth

    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetHeight(22)

    local label = wrapper:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 4, 0)
    label:SetText(groupLabel .. ":")
    wrapper.label = label

    -- Summary text: comma-separated short names of active options
    local function GetSummaryText()
        local parts = {}
        for _, def in ipairs(optionDefs) do
            local val = EasyFind.db[def.dbKey]
            if val == nil then val = def.default end
            if val then tinsert(parts, def.shortLabel or def.label) end
        end
        if #parts == 0 then return "None" end
        return tconcat(parts, ", ")
    end

    local btnFrame = CreateFrame("Button", nil, wrapper, "BackdropTemplate")
    btnFrame:SetSize(btnWidth, 22)
    btnFrame:SetBackdrop(SELECTOR_BACKDROP)
    btnFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    btnFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
    wrapper.button = btnFrame

    local btnText = btnFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btnText:SetPoint("CENTER")
    btnText:SetText(GetSummaryText())
    wrapper.btnText = btnText

    -- Flyout panel with checkboxes (and optional sliders via AddSlider).
    -- Parented to UIParent so it isn't clipped by the options frame.
    local ROW_H = 22
    local flyout = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    flyout:SetSize(flyoutWidth, #optionDefs * ROW_H + 8)
    flyout:SetFrameStrata("FULLSCREEN_DIALOG")
    flyout:SetFrameLevel(900)
    flyout:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    flyout:SetBackdropColor(0.08, 0.08, 0.08, 1)
    flyout:Hide()
    wrapper.flyout = flyout

    -- Track vertical cursor for adding content (checkboxes, then sliders)
    local contentH = #optionDefs * ROW_H + 4

    btnFrame:SetScript("OnClick", function()
        -- Re-anchor each time since the button may have moved
        flyout:ClearAllPoints()
        flyout:SetPoint("TOP", btnFrame, "BOTTOM", 0, -2)
        flyout:SetShown(not flyout:IsShown())
    end)

    -- Click-away to close
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

    wrapper.checkRows = {}
    for i, def in ipairs(optionDefs) do
        local row = CreateFrame("CheckButton", nil, flyout, "InterfaceOptionsCheckButtonTemplate")
        row:SetPoint("TOPLEFT", flyout, "TOPLEFT", 4, -4 - (i - 1) * ROW_H)
        row.Text:SetText(def.label)
        row.Text:SetFontObject("GameFontHighlightSmall")

        local val = EasyFind.db[def.dbKey]
        if val == nil then val = def.default end
        row:SetChecked(val)

        row:SetScript("OnClick", function(self)
            EasyFind.db[def.dbKey] = self:GetChecked()
            btnText:SetText(GetSummaryText())
            if def.callback then def.callback() end
        end)

        if def.tooltip then
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(def.label)
                GameTooltip:AddLine(def.tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", GameTooltip_Hide)
        end

        row.dbKey = def.dbKey
        row.defaultVal = def.default
        tinsert(wrapper.checkRows, row)
    end

    -- Add a slider inside the flyout, below existing content.
    -- Returns the slider frame. Uses the same API as CreateSlider.
    wrapper.sliders = {}
    function wrapper:AddSlider(name, sliderLabel, minVal, maxVal, step, tooltipText, formatFunc, defaultValue, unitSuffix)
        contentH = contentH + 18
        local slider = CreateSlider(flyout, name, sliderLabel, minVal, maxVal, step, tooltipText, formatFunc, defaultValue, unitSuffix)
        slider:SetWidth(flyoutWidth - 110)
        slider:SetPoint("TOPLEFT", flyout, "TOPLEFT", 14, -contentH)
        contentH = contentH + 36
        flyout:SetHeight(contentH + 4)
        tinsert(self.sliders, slider)
        return slider
    end

    function wrapper:UpdateVisuals()
        for _, row in ipairs(self.checkRows) do
            local val = EasyFind.db[row.dbKey]
            if val == nil then val = row.defaultVal end
            row:SetChecked(val)
        end
        btnText:SetText(GetSummaryText())
    end

    function wrapper:SetGroupEnabled(enabled)
        if enabled then btnFrame:Enable() else btnFrame:Disable() end
        self:SetAlpha(enabled and 1.0 or 0.35)
        if not enabled and flyout:IsShown() then flyout:Hide() end
    end

    return wrapper
end

local DISABLED_TEXT = { 0.5, 0.5, 0.5 }
local NORMAL_TEXT = { 1.0, 0.82, 0.0 }  -- GameFontNormal yellow

local function SetControlsEnabled(controls, enabled)
    for _, ctrl in ipairs(controls) do
        local objType = ctrl.GetObjectType and ctrl:GetObjectType()
        if objType == "CheckButton" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
            if ctrl.Text then
                local r, g, b = enabled and 1.0 or DISABLED_TEXT[1], enabled and 1.0 or DISABLED_TEXT[2], enabled and 1.0 or DISABLED_TEXT[3]
                ctrl.Text:SetTextColor(r, g, b)
            end
        elseif objType == "Slider" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
            if ctrl.Text then
                ctrl.Text:SetTextColor(enabled and NORMAL_TEXT[1] or DISABLED_TEXT[1], enabled and NORMAL_TEXT[2] or DISABLED_TEXT[2], enabled and NORMAL_TEXT[3] or DISABLED_TEXT[3])
            end
            if ctrl.Low then ctrl.Low:SetTextColor(enabled and 0.7 or 0.4, enabled and 0.7 or 0.4, enabled and 0.7 or 0.4) end
            if ctrl.High then ctrl.High:SetTextColor(enabled and 0.7 or 0.4, enabled and 0.7 or 0.4, enabled and 0.7 or 0.4) end
            if ctrl.valueText then ctrl.valueText:SetTextColor(enabled and 1.0 or 0.4, enabled and 1.0 or 0.4, enabled and 1.0 or 0.4) end
            if ctrl.inputBox then
                if enabled then ctrl.inputBox:Enable() else ctrl.inputBox:Disable() end
            end
            if ctrl.resetBtn then
                if enabled then ctrl.resetBtn:Enable() else ctrl.resetBtn:Disable() end
            end
        elseif objType == "Button" then
            if enabled then ctrl:Enable() else ctrl:Disable() end
        elseif objType == "Frame" then
            if ctrl.SetGroupEnabled then
                ctrl:SetGroupEnabled(enabled)
            else
                ctrl:SetAlpha(enabled and 1.0 or 0.35)
            end
        end
    end
end

function Options:Initialize()
    if isInitialized then return end
    isInitialized = true

    local FRAME_W    = 380
    local FRAME_H    = 380
    local COL_LEFT   = 4      -- Left column offset within content frames
    local BTN_OFFSET = 105    -- Label LEFT to button LEFT (aligns selectors/keybinds)
    local TAB_Y      = -42    -- Y where tab buttons start
    local CONTENT_Y  = -68    -- Y where tab content starts (below tab bar)
    local CONTENT_H  = 294    -- Fixed content area height

    -- Create the main options frame (fixed size)
    optionsFrame = CreateFrame("Frame", "EasyFindOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(FRAME_W, FRAME_H)
    if EasyFind.db.optionsPosition then
        local pos = EasyFind.db.optionsPosition
        optionsFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        optionsFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    end
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        EasyFind.db.optionsPosition = {point, relPoint, x, y}
    end)

    optionsFrame:SetBackdrop({
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    optionsFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)

    local bgTex = optionsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgTex:SetPoint("TOPLEFT", 4, -4)
    bgTex:SetPoint("BOTTOMRIGHT", -4, 4)
    bgTex:SetAtlas("QuestLog-main-background", false)
    bgTex:SetAlpha(EasyFind.db.panelOpacity or 0.9)
    optionsFrame.bgTex = bgTex

    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", optionsFrame, "TOP", 0, -16)
    title:SetText("EasyFind Options")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -5, -5)

    -- Content border (all tabs render inside this)
    local contentBorder = CreateFrame("Frame", nil, optionsFrame, "BackdropTemplate")
    contentBorder:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 12, CONTENT_Y)
    contentBorder:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -12, CONTENT_Y)
    contentBorder:SetHeight(CONTENT_H)
    contentBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    contentBorder:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.6)

    -- Tab system using WoW standard tab atlases (flipped for top attachment)
    local tabFrames = {}
    local tabButtons = {}
    local activeTabIndex

    -- Flip a texture vertically for top-attached tabs
    local function FlipV(tex)
        tex:SetTexCoord(0, 1, 1, 0)
    end

    local function SetTabActive(btn, active)
        if active then
            btn.leftActive:Show(); btn.midActive:Show(); btn.rightActive:Show()
            btn.leftInactive:Hide(); btn.midInactive:Hide(); btn.rightInactive:Hide()
            btn.leftHl:Hide(); btn.midHl:Hide(); btn.rightHl:Hide()
            btn:SetHeight(32)
            btn:GetFontString():SetTextColor(1.0, 0.82, 0.0)
        else
            btn.leftActive:Hide(); btn.midActive:Hide(); btn.rightActive:Hide()
            btn.leftInactive:Show(); btn.midInactive:Show(); btn.rightInactive:Show()
            btn.leftHl:Show(); btn.midHl:Show(); btn.rightHl:Show()
            btn:SetHeight(28)
            btn:GetFontString():SetTextColor(0.8, 0.8, 0.8)
        end
    end

    local function SwitchToTab(index)
        for i, tf in ipairs(tabFrames) do
            tf:SetShown(i == index)
            SetTabActive(tabButtons[i], i == index)
        end
        activeTabIndex = index
    end
    optionsFrame.SwitchToTab = SwitchToTab

    local function CreateTab(tabName)
        local index = #tabFrames + 1

        local btn = CreateFrame("Button", nil, optionsFrame)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetText(tabName)

        local textW = btn:GetFontString():GetStringWidth()
        local tabW = mmax(textW + 28, 48)
        btn:SetSize(tabW, 28)

        -- Force center text within tab
        local fs = btn:GetFontString()
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", btn, "CENTER", -2, 0)
        fs:SetJustifyH("CENTER")

        -- Active state textures (flipped vertically for top attachment)
        local la = btn:CreateTexture(nil, "BACKGROUND")
        la:SetAtlas("uiframe-activetab-left"); la:SetSize(35, 32)
        la:SetPoint("BOTTOMLEFT", 0, 0); FlipV(la); la:Hide()
        btn.leftActive = la

        local ma = btn:CreateTexture(nil, "BACKGROUND")
        ma:SetAtlas("_uiframe-activetab-center")
        ma:SetPoint("BOTTOMLEFT", la, "BOTTOMRIGHT", 0, 0)
        ma:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -35, 0)
        ma:SetHeight(32); FlipV(ma); ma:Hide()
        btn.midActive = ma

        local ra = btn:CreateTexture(nil, "BACKGROUND")
        ra:SetAtlas("uiframe-activetab-right"); ra:SetSize(37, 32)
        ra:SetPoint("BOTTOMRIGHT", 0, 0); FlipV(ra); ra:Hide()
        btn.rightActive = ra

        -- Inactive state textures (flipped)
        local li = btn:CreateTexture(nil, "BACKGROUND")
        li:SetAtlas("uiframe-tab-left"); li:SetSize(35, 28)
        li:SetPoint("BOTTOMLEFT", 0, 0); FlipV(li)
        btn.leftInactive = li

        local mi = btn:CreateTexture(nil, "BACKGROUND")
        mi:SetAtlas("_uiframe-tab-center")
        mi:SetPoint("BOTTOMLEFT", li, "BOTTOMRIGHT", 0, 0)
        mi:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -35, 0)
        mi:SetHeight(28); FlipV(mi)
        btn.midInactive = mi

        local ri = btn:CreateTexture(nil, "BACKGROUND")
        ri:SetAtlas("uiframe-tab-right"); ri:SetSize(37, 28)
        ri:SetPoint("BOTTOMRIGHT", 0, 0); FlipV(ri)
        btn.rightInactive = ri

        -- Highlight textures (flipped, shown over inactive only)
        local lh = btn:CreateTexture(nil, "HIGHLIGHT")
        lh:SetAtlas("uiframe-tab-left"); lh:SetSize(35, 28)
        lh:SetPoint("BOTTOMLEFT", 0, 0); FlipV(lh); lh:SetAlpha(0.4)
        btn.leftHl = lh

        local mh = btn:CreateTexture(nil, "HIGHLIGHT")
        mh:SetAtlas("_uiframe-tab-center")
        mh:SetPoint("BOTTOMLEFT", lh, "BOTTOMRIGHT", 0, 0)
        mh:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -35, 0)
        mh:SetHeight(28); FlipV(mh); mh:SetAlpha(0.4)
        btn.midHl = mh

        local rh = btn:CreateTexture(nil, "HIGHLIGHT")
        rh:SetAtlas("uiframe-tab-right"); rh:SetSize(37, 28)
        rh:SetPoint("BOTTOMRIGHT", 0, 0); FlipV(rh); rh:SetAlpha(0.4)
        btn.rightHl = rh

        -- Position: tabs sit above the content border, bottom edges touching it
        if index == 1 then
            btn:SetPoint("BOTTOMLEFT", contentBorder, "TOPLEFT", 5, -2)
        else
            btn:SetPoint("BOTTOMLEFT", tabButtons[index - 1], "BOTTOMRIGHT", -8, 0)
        end
        btn:SetScript("OnClick", function() SwitchToTab(index) end)
        tinsert(tabButtons, btn)

        -- Content frame inside the border
        local content = CreateFrame("Frame", nil, contentBorder)
        content:SetPoint("TOPLEFT", 6, -6)
        content:SetPoint("BOTTOMRIGHT", -6, 6)
        content:Hide()
        tinsert(tabFrames, content)

        return content
    end

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

            end)
        end
    end

    local function MakeKeybindTooltip(keybindBtn, titleText, line1)
        keybindBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(titleText)
            GameTooltip:AddLine(line1, 1, 1, 1, true)
            GameTooltip:AddLine("Right-click to clear. Escape to cancel.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        keybindBtn:SetScript("OnLeave", GameTooltip_Hide)
    end

    -- SECTION 1: General
    -- HOME TAB
    local homeTab = CreateTab("Home")
    local homeIcon = homeTab:CreateTexture(nil, "ARTWORK")
    homeIcon:SetSize(48, 48)
    homeIcon:SetPoint("TOPLEFT", homeTab, "TOPLEFT", 12, -16)
    homeIcon:SetTexture("Interface\\MINIMAP\\Tracking\\None")

    local homeTitle = homeTab:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    homeTitle:SetPoint("LEFT", homeIcon, "RIGHT", 12, 6)
    homeTitle:SetText("EasyFind")

    local homeVersion = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    homeVersion:SetPoint("LEFT", homeTitle, "RIGHT", 6, 0)
    local tocVersion = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("EasyFind", "Version")
    homeVersion:SetText("|cFF888888v" .. (tocVersion or "") .. "|r")

    local homeDesc = homeTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    homeDesc:SetPoint("TOPLEFT", homeIcon, "BOTTOMLEFT", 0, -12)
    homeDesc:SetPoint("RIGHT", homeTab, "RIGHT", -12, 0)
    homeDesc:SetJustifyH("LEFT")
    homeDesc:SetSpacing(3)
    homeDesc:SetText(
        "|cFFFFD100Quick start:|r  Type in the search bar to find UI panels, map locations, "
        .. "and more. Click a result to navigate there.\n\n"
        .. "Use the |cFFFFD100filter button|r on the search bar to add mounts, toys, pets, and "
        .. "map results to your searches. The world map also has its own search bars "
        .. "for finding zones, dungeons, and points of interest directly on the map.\n\n"
        .. "|cFFFFD100Slash commands:|r\n"
        .. "  |cFF00FF00/ef o|r  Open this options panel\n"
        .. "  |cFF00FF00/ef c|r  Dismiss all highlights and pins\n\n"
        .. "For a full walkthrough, see the CurseForge page:"
    )

    local thankYou = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    thankYou:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -16, 6)
    thankYou:SetText("Thanks for trying EasyFind!")

    local function CreateURLBox(parent, url, anchor, yOff)
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetSize(FRAME_W - 60, 18)
        box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
        box:SetAutoFocus(false)
        box:SetFontObject("GameFontHighlightSmall")
        box:SetText(url)
        box:SetCursorPosition(0)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnTextChanged", function(self) self:SetText(url); self:SetCursorPosition(0) end)
        box:SetScript("OnMouseUp", function(self)
            if not self:IsMouseOver() then self:ClearFocus() end
        end)
        return box
    end

    local cfBox = CreateURLBox(homeTab, "https://www.curseforge.com/wow/addons/easyfind", homeDesc, -6)

    local sec3 = CreateTab("General")

    -- General tab layout (no inner border, content fills the tab)

    local loginMessageCheckbox = CreateCheckbox(sec3, "LoginMessage", "Show Login Message",
        "When enabled, shows a short \"EasyFind loaded!\" message in chat when you log in.\n\nDisable to keep chat cleaner.")
    loginMessageCheckbox:SetPoint("TOPLEFT", sec3, "TOPLEFT", 8, -8)
    loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage ~= false)
    loginMessageCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showLoginMessage = self:GetChecked()
    end)
    optionsFrame.loginMessageCheckbox = loginMessageCheckbox

    local minimapBtnCheckbox = CreateCheckbox(sec3, "MinimapBtn", "Show Minimap Button",
        "When enabled, adds a small search icon button to the minimap edge.\n\nLeft-click the button to toggle the search bar.\nRight-click to open options.\nDrag to reposition it around the minimap.")
    minimapBtnCheckbox:SetPoint("LEFT", loginMessageCheckbox, "RIGHT", 120, 0)
    minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton ~= false)
    minimapBtnCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.showMinimapButton = self:GetChecked()
        EasyFind:UpdateMinimapButton()
    end)
    optionsFrame.minimapBtnCheckbox = minimapBtnCheckbox

    local indicatorLabel = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    indicatorLabel:SetPoint("TOPLEFT", loginMessageCheckbox, "BOTTOMLEFT", 4, -10)
    indicatorLabel:SetText("Indicator Style:")

    local indicatorChoices = {"EasyFind Arrow", "Classic Quest Arrow", "Minimap Player Arrow", "Low-res Gauntlet", "HD Gauntlet"}

    local indicatorBtnFrame, indicatorBtnText = CreateFlyoutSelector(
        sec3, "EasyFindIndicator", 120, indicatorLabel, EasyFind.db.indicatorStyle or "EasyFind Arrow"
    )
    indicatorBtnFrame:ClearAllPoints()
    indicatorBtnFrame:SetPoint("LEFT", indicatorLabel, "LEFT", BTN_OFFSET, 0)
    local indicatorFlyout = CreateFlyoutPanel(indicatorBtnFrame, "EasyFindIndicator", 120, #indicatorChoices)
    AddFlyoutOptions(indicatorFlyout, indicatorChoices, 114, function(name)
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
        sec3, "EasyFindColor", 120, colorLabel, EasyFind.db.indicatorColor or "Yellow"
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

    local colorFlyout = CreateFlyoutPanel(colorBtnFrame, "EasyFindColor", 120, #colorChoices)

    for i, name in ipairs(colorChoices) do
        local rgb = colorRGB[name]
        local colorBtn = CreateFrame("Button", nil, colorFlyout)
        colorBtn:SetSize(114, 18)
        colorBtn:SetPoint("TOPLEFT", colorFlyout, "TOPLEFT", 3, -3 - (i - 1) * 20)

        local swatch = colorBtn:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(12, 12)
        swatch:SetPoint("LEFT", 2, 0)
        swatch:SetColorTexture(rgb[1], rgb[2], rgb[3], 1)

        local label = colorBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
        label:SetText(name)
        label:SetTextColor(rgb[1], rgb[2], rgb[3])

        colorBtn:SetScript("OnEnter", function(self)
            label:SetTextColor(1, 1, 1)
        end)
        colorBtn:SetScript("OnLeave", function(self)
            label:SetTextColor(rgb[1], rgb[2], rgb[3])
        end)
        colorBtn:SetScript("OnClick", function()
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

    local themeLabel = sec3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -20)
    themeLabel:SetText("Theme:")

    local themeChoices = {"Classic", "Retail"}

    local themeBtnFrame, themeBtnText = CreateFlyoutSelector(
        sec3, "EasyFindTheme", 120, themeLabel, EasyFind.db.resultsTheme or "Retail"
    )
    themeBtnFrame:ClearAllPoints()
    themeBtnFrame:SetPoint("LEFT", themeLabel, "LEFT", BTN_OFFSET, 0)
    local themeFlyout = CreateFlyoutPanel(themeBtnFrame, "EasyFindTheme", 120, #themeChoices)
    AddFlyoutOptions(themeFlyout, themeChoices, 114, function(name)
        EasyFind.db.resultsTheme = name
        themeBtnText:SetText(name)
        if ns.UI and ns.UI.RefreshResults then ns.UI:RefreshResults() end
        if ns.MapSearch and ns.MapSearch.UpdateSearchBarTheme then ns.MapSearch:UpdateSearchBarTheme() end
    end)
    optionsFrame.themeBtnText = themeBtnText
    optionsFrame.themeFlyout = themeFlyout

    local panelOpacitySlider = CreateSlider(sec3, "PanelOpacity", "Options Menu Opacity", 0.3, 1.0, 0.05,
        "Adjusts the opacity of the options panel background.", nil, 0.9)
    panelOpacitySlider:SetPoint("TOPLEFT", themeLabel, "BOTTOMLEFT", 0, -30)
    panelOpacitySlider:SetValue(EasyFind.db.panelOpacity or 0.9)
    panelOpacitySlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.panelOpacity = value
        if optionsFrame.bgTex then
            optionsFrame.bgTex:SetAlpha(value)
        end
    end)
    optionsFrame.panelOpacitySlider = panelOpacitySlider

    local opacitySlider = CreateSlider(sec3, "Opacity", "Background Opacity", 0.0, 1.0, 0.05,
        "Adjusts the background opacity of all search bars. Text and icons remain fully visible.", nil, DEFAULT_OPACITY)
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

    local RESET_BTN_W = 120

    -- SECTION 2: UI Search
    local sec1 = CreateTab("UI")

    local uiEnableCheckbox = CreateCheckbox(sec1, "EnableUI", "Enable UI Search Module",
        "Uncheck to disable the main UI search bar.\n\nRequires a UI reload to take effect.")
    uiEnableCheckbox:SetPoint("TOPLEFT", sec1, "TOPLEFT", COL_LEFT, -6)
    uiEnableCheckbox:SetChecked(EasyFind.db.enableUISearch ~= false)

    local uiControls = {}
    local function UpdateUIToggleVisual()
        local enabled = EasyFind.db.enableUISearch ~= false
        uiEnableCheckbox:SetChecked(enabled)
        SetControlsEnabled(uiControls, enabled)
    end
    optionsFrame.UpdateUIToggleVisual = UpdateUIToggleVisual

    uiEnableCheckbox:SetScript("OnClick", function(self)
        if self:GetChecked() then
            EasyFind.db.enableUISearch = true
            UpdateUIToggleVisual()
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        else
            StaticPopup_Show("EASYFIND_DISABLE_UI_SEARCH")
            self:SetChecked(true)
        end
    end)

    -- Gold separator under enable checkbox
    local uiSep = sec1:CreateTexture(nil, "ARTWORK")
    uiSep:SetPoint("TOPLEFT", sec1, "TOPLEFT", 6, -30)
    uiSep:SetPoint("RIGHT", sec1, "RIGHT", -6, 0)
    uiSep:SetHeight(1)
    uiSep:SetColorTexture(0.8, 0.65, 0.0, 0.6)

    local uiSpeedBox = CreateFrame("Frame", nil, sec1, "BackdropTemplate")
    uiSpeedBox:SetPoint("TOPLEFT", sec1, "TOPLEFT", 8, -38)
    uiSpeedBox:SetSize(210, 36)
    uiSpeedBox:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    uiSpeedBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.6)
    local uiSpeedLabel = uiSpeedBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    uiSpeedLabel:SetPoint("BOTTOM", uiSpeedBox, "TOP", 0, -8)
    uiSpeedLabel:SetText("Speed")

    local directOpenCheckbox = CreateCheckbox(sec1, "DirectOpen", "Open Panels Directly",
        "When enabled, clicking a UI search result will immediately open the destination panel.\n\nWhen disabled (default), you will be guided step-by-step with highlights showing you where to click.")
    directOpenCheckbox:SetPoint("TOPLEFT", uiSpeedBox, "TOPLEFT", 8, -4)
    directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    directOpenCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.directOpen = self:GetChecked()
        local filters = EasyFind.db.uiSearchFilters
        if filters and filters.map ~= false then
            EasyFind.db.navigateToZonesDirectly = EasyFind.db.directOpen
            if optionsFrame.zoneNavCheckbox then
                optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly)
            end
        end
        ns.Highlight:ClearAll()
        local sf = _G["EasyFindSearchFrame"]
        if sf and sf.modeBtn and ns.UpdateModeButtonVisual then
            ns.UpdateModeButtonVisual(sf.modeBtn)
        end
    end)
    optionsFrame.directOpenCheckbox = directOpenCheckbox

    local resizeUIBtn = CreateFrame("Button", nil, sec1, "UIPanelButtonTemplate")
    resizeUIBtn:SetSize(160, 22)
    resizeUIBtn:SetPoint("BOTTOMLEFT", sec1, "BOTTOMLEFT", 8, 32)
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

    local smartShowCheckbox = CreateCheckbox(sec1, "SmartShow", "Smart Show |cFF888888(Recommended)|r",
        "When enabled, the UI search bar hides itself until you move your mouse near its position.\n\nThe bar reappears when your mouse enters the area and fades away when you move away.\n\nA separate Smart Show toggle for map search bars is available in the Map Search section.")
    smartShowCheckbox:SetPoint("TOPLEFT", uiSpeedBox, "BOTTOMLEFT", 8, -6)
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
    staticOpacityCheckbox:SetPoint("TOPLEFT", smartShowCheckbox, "BOTTOMLEFT", 0, -2)
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
    uiResultsAboveCheckbox:SetPoint("TOPLEFT", staticOpacityCheckbox, "BOTTOMLEFT", 0, -2)
    uiResultsAboveCheckbox:SetChecked(EasyFind.db.uiResultsAbove or false)
    uiResultsAboveCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.uiResultsAbove = self:GetChecked()
    end)
    optionsFrame.uiResultsAboveCheckbox = uiResultsAboveCheckbox

    local uiFontSlider = CreateSlider(sec1, "UIFontSize", "Font Size|cffff3333*|r", 0.5, 2.0, 0.1,
        "Changing font size also affects search bar height and results window sizing.", nil, 1.0)
    uiFontSlider:SetPoint("TOPLEFT", uiResultsAboveCheckbox, "BOTTOMLEFT", 4, -20)
    uiFontSlider:SetValue(EasyFind.db.fontSize or 1.0)
    uiFontSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.fontSize = value
        if ns.UI and ns.UI.UpdateFontSize then
            ns.UI:UpdateFontSize()
        end
    end)
    optionsFrame.uiFontSlider = uiFontSlider

    local resetUIBtn = CreateFrame("Button", nil, sec1, "UIPanelButtonTemplate")
    resetUIBtn:SetSize(RESET_BTN_W, 20)
    resetUIBtn:SetPoint("BOTTOMLEFT", sec1, "BOTTOMLEFT", 8, 8)
    resetUIBtn:SetText("Reset Settings")
    resetUIBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_UI")
    end)

    local resetUIPosBtn = CreateFrame("Button", nil, sec1, "UIPanelButtonTemplate")
    resetUIPosBtn:SetSize(RESET_BTN_W, 20)
    resetUIPosBtn:SetPoint("LEFT", resetUIBtn, "RIGHT", 8, 0)
    resetUIPosBtn:SetText("Reset Positions")
    resetUIPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_UI_POS")
    end)

    uiControls = { resizeUIBtn, resetUIBtn, resetUIPosBtn, uiFontSlider, directOpenCheckbox, smartShowCheckbox, staticOpacityCheckbox, uiResultsAboveCheckbox }
    UpdateUIToggleVisual()

    -- SECTION 3: Map Search
    local sec2 = CreateTab("Map")

    local mapEnableCheckbox = CreateCheckbox(sec2, "EnableMap", "Enable Map Search Module",
        "Uncheck to disable map search bars, pins, and all map overlay features.\n\nRequires a UI reload to take effect.")
    mapEnableCheckbox:SetPoint("TOPLEFT", sec2, "TOPLEFT", COL_LEFT, -6)
    mapEnableCheckbox:SetChecked(EasyFind.db.enableMapSearch ~= false)

    local mapControls = {}
    local function UpdateMapToggleVisual()
        local enabled = EasyFind.db.enableMapSearch ~= false
        mapEnableCheckbox:SetChecked(enabled)
        SetControlsEnabled(mapControls, enabled)
    end
    optionsFrame.UpdateMapToggleVisual = UpdateMapToggleVisual

    mapEnableCheckbox:SetScript("OnClick", function(self)
        if self:GetChecked() then
            EasyFind.db.enableMapSearch = true
            UpdateMapToggleVisual()
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        else
            StaticPopup_Show("EASYFIND_DISABLE_MAP_SEARCH")
            self:SetChecked(true)
        end
    end)

    -- Gold separator under enable checkbox
    local mapSep = sec2:CreateTexture(nil, "ARTWORK")
    mapSep:SetPoint("TOPLEFT", sec2, "TOPLEFT", 6, -30)
    mapSep:SetPoint("RIGHT", sec2, "RIGHT", -6, 0)
    mapSep:SetHeight(1)
    mapSep:SetColorTexture(0.8, 0.65, 0.0, 0.6)

    local mapSpeedBox = CreateFrame("Frame", nil, sec2, "BackdropTemplate")
    mapSpeedBox:SetPoint("TOPLEFT", sec2, "TOPLEFT", 8, -38)
    mapSpeedBox:SetSize(210, 36)
    mapSpeedBox:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    mapSpeedBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.6)
    local mapSpeedLabel = mapSpeedBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapSpeedLabel:SetPoint("BOTTOM", mapSpeedBox, "TOP", 0, -8)
    mapSpeedLabel:SetText("Speed")

    local zoneNavCheckbox = CreateCheckbox(sec2, "ZoneNav", "Navigate Zones Directly",
        "When enabled, clicking a zone search result will immediately open that zone's map.\n\nWhen disabled (default), you will be guided step by step through the map hierarchy so you can learn how to navigate there yourself.")
    zoneNavCheckbox:SetPoint("TOPLEFT", mapSpeedBox, "TOPLEFT", 8, -4)
    zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    zoneNavCheckbox:SetScript("OnClick", function(self)
        EasyFind.db.navigateToZonesDirectly = self:GetChecked()
    end)
    optionsFrame.zoneNavCheckbox = zoneNavCheckbox

    local resizeMapBtn = CreateFrame("Button", nil, sec2, "UIPanelButtonTemplate")
    resizeMapBtn:SetSize(160, 22)
    resizeMapBtn:SetPoint("BOTTOMLEFT", sec2, "BOTTOMLEFT", 8, 32)
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

    local FLYOUT_W = 260

    local searchBarGroup = CreateMultiSelectDropdown(sec2, "Search Bars", {
        { label = "Smart Show |cFF888888(Recommended)|r", shortLabel = "Smart", dbKey = "mapSmartShow", default = false,
          tooltip = "Map search bars hide until you move your mouse near them.\nBars reappear on hover and fade when you move away.\nText in search bars or an open results list prevents fading.",
          callback = function() if ns.MapSearch and ns.MapSearch.UpdateMapSmartShow then ns.MapSearch:UpdateMapSmartShow() end end },
        { label = "Hide Fullscreen", shortLabel = "No Full", dbKey = "hideSearchBarsMaximized", default = false,
          tooltip = "Both map search bars are hidden when the world map is maximized (full screen).\nThey reappear when you return to the windowed map.",
          callback = function() if ns.MapSearch and ns.MapSearch.UpdateHideMaximized then ns.MapSearch:UpdateHideMaximized() end end },
        { label = "Results Above", shortLabel = "Above", dbKey = "mapResultsAbove", default = false,
          tooltip = "Map search results appear above the bar instead of below.\nApplies to both local and global map search bars.",
          callback = function() if ns.MapSearch and ns.MapSearch.RefreshResultsAnchor then ns.MapSearch:RefreshResultsAnchor() end end },
    }, nil, FLYOUT_W)
    searchBarGroup:SetPoint("TOPLEFT", mapSpeedBox, "BOTTOMLEFT", 0, -8)
    searchBarGroup:SetPoint("RIGHT", sec2, "RIGHT", -8, 0)
    searchBarGroup.label:SetWidth(85)
    searchBarGroup.label:SetJustifyH("LEFT")
    searchBarGroup.button:SetPoint("LEFT", searchBarGroup.label, "RIGHT", 6, 0)
    optionsFrame.searchBarGroup = searchBarGroup

    local mapFontSlider = searchBarGroup:AddSlider("MapFontSize", "Font Size|cffff3333*|r", 0.5, 2.0, 0.1,
        "Changing font size also affects search bar height and results window sizing.", nil, 1.0)
    mapFontSlider:SetValue(EasyFind.db.mapFontSize or 1.0)
    mapFontSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.mapFontSize = value
        if ns.MapSearch and ns.MapSearch.UpdateFontSize then
            ns.MapSearch:UpdateFontSize()
        end
    end)
    optionsFrame.mapFontSlider = mapFontSlider

    local mapYOffsetSlider = searchBarGroup:AddSlider("MapYOffset", "Bar Y Offset", -20, 20, 1,
        "Vertical offset for the map search bars relative to the map bottom edge.\nPositive moves up, negative moves down.",
        function(val) return tostring(mfloor(val + 0.5)) .. "px" end, 0, "px")
    mapYOffsetSlider:SetValue(EasyFind.db.mapSearchYOffset or 0)
    mapYOffsetSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.mapSearchYOffset = value
        if ns.MapSearch and ns.MapSearch.UpdateYOffset then
            ns.MapSearch:UpdateYOffset()
        end
    end)
    optionsFrame.mapYOffsetSlider = mapYOffsetSlider

    local mapPinGroup = CreateMultiSelectDropdown(sec2, "Map Pins", {
        { label = "Highlight Box", shortLabel = "Highlight", dbKey = "mapPinHighlight", default = true,
          tooltip = "A yellow highlight box is drawn around map search pins.\nDisable to show only the pin icon and indicator arrow.",
          callback = function() if ns.MapSearch and ns.MapSearch.UpdatePinHighlight then ns.MapSearch:UpdatePinHighlight() end end },
        { label = "Blinking", shortLabel = "Blink", dbKey = "blinkingPins", default = false,
          tooltip = "Map search pins and highlight boxes pulse in sync with the indicator arrow.\nWhen disabled, pins and highlights are steady. The indicator arrow always bobs.",
          callback = function() if ns.MapSearch and ns.MapSearch.UpdateBlinkingPins then ns.MapSearch:UpdateBlinkingPins() end end },
    }, nil, FLYOUT_W)
    mapPinGroup:SetPoint("TOPLEFT", searchBarGroup, "BOTTOMLEFT", 0, -6)
    mapPinGroup:SetPoint("RIGHT", sec2, "RIGHT", -8, 0)
    mapPinGroup.label:SetWidth(85)
    mapPinGroup.label:SetJustifyH("LEFT")
    mapPinGroup.button:SetPoint("LEFT", mapPinGroup.label, "RIGHT", 6, 0)
    optionsFrame.mapPinGroup = mapPinGroup

    local mapIconSlider = mapPinGroup:AddSlider("MapIcon", "Icon Size", 0.5, 2.0, 0.1,
        "Adjusts the size of map search result icons on the world map.", nil, 0.8)
    mapIconSlider:SetValue(EasyFind.db.iconScale or 0.8)
    mapIconSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.iconScale = value
        if ns.MapSearch and ns.MapSearch.UpdateIconScales then
            ns.MapSearch:UpdateIconScales()
        end
        local uiInd = _G["EasyFindIndicatorFrame"]
        if uiInd then
            uiInd:SetScale(EasyFind.db.iconScale or 0.8)
        end
    end)
    optionsFrame.mapIconSlider = mapIconSlider

    local minimapGroup = CreateMultiSelectDropdown(sec2, "Minimap", {
        { label = "Arrow Glow", shortLabel = "Arrow", dbKey = "minimapArrowGlow", default = true,
          tooltip = "A pulsing glow highlights the minimap perimeter arrow that points toward your active map pin.\nDisable if you find the glow distracting." },
        { label = "Guide Circle", shortLabel = "Circle", dbKey = "minimapGuideCircle", default = true,
          tooltip = "A directional ring and arrow appears around your character on the minimap when a map pin is nearby, pointing toward the destination.\nDisable if you prefer only the default minimap pin." },
        { label = "Pin Glow", shortLabel = "Glow", dbKey = "minimapPinGlow", default = true,
          tooltip = "A pulsing glow appears on the minimap pin when the guide circle shrinks onto it.\nDisable if you find the glow distracting." },
    }, nil, FLYOUT_W)
    minimapGroup:SetPoint("TOPLEFT", mapPinGroup, "BOTTOMLEFT", 0, -6)
    minimapGroup:SetPoint("RIGHT", sec2, "RIGHT", -8, 0)
    minimapGroup.label:SetWidth(85)
    minimapGroup.label:SetJustifyH("LEFT")
    minimapGroup.button:SetPoint("LEFT", minimapGroup.label, "RIGHT", 6, 0)
    optionsFrame.minimapGroup = minimapGroup

    local circleScaleSlider = minimapGroup:AddSlider("CircleScale", "Guide Circle Size", 0.5, 2.0, 0.1,
        "Adjusts the size of the minimap guide circle and arrow that appears when tracking a map pin.",
        nil, 1.0)
    circleScaleSlider:SetValue(EasyFind.db.guideCircleScale or 1.0)
    circleScaleSlider:HookScript("OnValueChanged", function(self, value)
        EasyFind.db.guideCircleScale = value
    end)
    optionsFrame.circleScaleSlider = circleScaleSlider

    local automationGroup = CreateMultiSelectDropdown(sec2, "Automation", {
        { label = "Auto Track", shortLabel = "Track", dbKey = "autoTrackPins", default = true,
          tooltip = "Placing a map pin (Ctrl+Click) automatically starts tracking it on the minimap.\nWhen disabled, you must click the pin to start tracking." },
        { label = "Auto Clear", shortLabel = "Clear", dbKey = "autoPinClear", default = true,
          tooltip = "Your map pin is automatically cleared when you arrive at the destination.\nDisable if you prefer to clear pins manually." },
    }, nil, FLYOUT_W)
    automationGroup:SetPoint("TOPLEFT", minimapGroup, "BOTTOMLEFT", 0, -6)
    automationGroup:SetPoint("RIGHT", sec2, "RIGHT", -8, 0)
    automationGroup.label:SetWidth(85)
    automationGroup.label:SetJustifyH("LEFT")
    automationGroup.button:SetPoint("LEFT", automationGroup.label, "RIGHT", 6, 0)
    optionsFrame.automationGroup = automationGroup

    local arrivalSlider = automationGroup:AddSlider("ArrivalDist", "Arrival Distance", 3, 50, 1,
        "How close (in yards) you must be to a tracked location before the waypoint auto-clears.",
        function(val) return tostring(mfloor(val + 0.5)) .. "yd" end, 10, "yd")
    arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    arrivalSlider:HookScript("OnValueChanged", function(self, value)
        value = mfloor(value + 0.5)
        EasyFind.db.arrivalDistance = value
    end)
    optionsFrame.arrivalSlider = arrivalSlider

    -- Border around Auto Clear + Arrival Distance to show they're linked
    local clearGroup = CreateFrame("Frame", nil, automationGroup.flyout, "BackdropTemplate")
    local autoClearRow = automationGroup.checkRows[2]  -- Auto Clear is second
    clearGroup:SetPoint("TOPLEFT", autoClearRow, "TOPLEFT", -4, 4)
    clearGroup:SetPoint("RIGHT", automationGroup.flyout, "RIGHT", -4, 0)
    clearGroup:SetPoint("BOTTOM", automationGroup.flyout, "BOTTOM", 0, 3)
    clearGroup:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    clearGroup:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)

    -- Gray out Arrival Distance slider when Auto Clear is unchecked
    local function UpdateArrivalSliderState()
        SetControlsEnabled({arrivalSlider}, EasyFind.db.autoPinClear ~= false)
    end
    UpdateArrivalSliderState()
    autoClearRow:HookScript("OnClick", UpdateArrivalSliderState)

    local resetMapBtn = CreateFrame("Button", nil, sec2, "UIPanelButtonTemplate")
    resetMapBtn:SetSize(RESET_BTN_W, 20)
    resetMapBtn:SetPoint("BOTTOMLEFT", sec2, "BOTTOMLEFT", 8, 8)
    resetMapBtn:SetText("Reset Settings")
    resetMapBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_MAP")
    end)

    local resetMapPosBtn = CreateFrame("Button", nil, sec2, "UIPanelButtonTemplate")
    resetMapPosBtn:SetSize(RESET_BTN_W, 20)
    resetMapPosBtn:SetPoint("LEFT", resetMapBtn, "RIGHT", 8, 0)
    resetMapPosBtn:SetText("Reset Positions")
    resetMapPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_MAP_POS")
    end)

    mapControls = {
        resizeMapBtn, resetMapBtn, resetMapPosBtn, zoneNavCheckbox,
        searchBarGroup, mapPinGroup, minimapGroup, automationGroup
    }
    UpdateMapToggleVisual()

    -- SECTION 4: Keyboard Shortcuts
    local sec4 = CreateTab("Shortcuts")

    -- Shortcuts tab layout (no inner border)

    local shortcutText = sec4:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shortcutText:SetPoint("TOPLEFT", sec4, "TOPLEFT", 8, -8)
    shortcutText:SetWidth(FRAME_W - 60)
    shortcutText:SetJustifyH("LEFT")
    shortcutText:SetSpacing(2)
    shortcutText:SetText(
        "|cFFFFD100Search box:|r\n"
        .. "|cFF00FF00Down|r  Enter results list\n"
        .. "|cFF00FF00Tab / Shift+Tab|r  Cycle between search/clear/filter buttons\n"
        .. "|cFF00FF00Enter|r  Activate focused button or highlighted result\n"
        .. "|cFF00FF00Escape|r  Remove cursor from search bar\n\n"
        .. "|cFFFFD100Results list:|r\n"
        .. "|cFF00FF00Up / Down|r  Move through results\n"
        .. "|cFF00FF00Tab / Shift+Tab|r  Toggle focus between result/nav button\n"
        .. "|cFF00FF00Page Up / Page Down|r  Jump 5 results\n"
        .. "|cFF00FF00Home / End|r  Jump to first / last result\n"
        .. "|cFF00FF00Shift+Up / Shift+Down|r  Jump between sections\n"
        .. "|cFF00FF00Ctrl+Tab|r  Switch local / global map search bar\n\n"
        .. "|cFFFFD100Other:|r\n"
        .. "|cFF00FF00Shift+Drag|r  Reposition search bars\n"
        .. "|cFF00FF00Right-click|r a result to pin/unpin it\n"
        .. "|cFF00FF00/ef show|r  |cFF00FF00/ef hide|r  Toggle the search bar\n"
    )
    -- Keybind buttons
    local KEYBIND_ROW_H = 18
    local KEYBIND_BTN_W = 80

    local keybindDefs = {
        { label = "Toggle Bar",    action = "EASYFIND_TOGGLE" },
        { label = "Focus Bar",     action = "EASYFIND_FOCUS" },
        { label = "Clear All",     action = "EASYFIND_CLEAR" },
        { label = "Toggle+Foc",    action = "EASYFIND_TOGGLE_FOCUS" },
    }

    local keybindTooltips = {
        EASYFIND_TOGGLE       = { "Toggle Search Bar", "Shows or hides the main search bar." },
        EASYFIND_FOCUS        = { "Focus Search Bar", "Places the cursor in the search bar without toggling visibility." },
        EASYFIND_TOGGLE_FOCUS = { "Toggle + Focus", "Opens and focuses the search bar in one press. Press again to close. When the map is open, focuses the local map search bar instead." },
        EASYFIND_CLEAR        = { "Clear All", "Dismisses all active highlights, map pins, zone highlights, and pending waypoints." },
    }

    local keybindButtons = {}
    local KEYBIND_LABEL_W = 70
    local COL2_X = 160
    for i, def in ipairs(keybindDefs) do
        local row = (i - 1) % 2        -- 0 or 1
        local col = (i <= 2) and 0 or 1 -- left or right column

        local rowLabel = sec4:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if row == 0 then
            rowLabel:SetPoint("TOPLEFT", shortcutText, "BOTTOMLEFT", col * COL2_X, -12)
        else
            rowLabel:SetPoint("TOPLEFT", shortcutText, "BOTTOMLEFT", col * COL2_X, -12 - KEYBIND_ROW_H)
        end
        rowLabel:SetText(def.label .. ":")

        local keybindBtn = CreateFrame("Button", nil, sec4, "UIPanelButtonTemplate")
        keybindBtn:SetNormalFontObject("GameFontHighlightSmall")
        keybindBtn:SetHighlightFontObject("GameFontHighlightSmall")
        keybindBtn:SetSize(KEYBIND_BTN_W, 18)
        keybindBtn:SetPoint("LEFT", rowLabel, "LEFT", KEYBIND_LABEL_W, 0)
        keybindBtn:SetText(GetCurrentKeybindText(def.action))
        keybindBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                local old1, old2 = GetBindingKey(def.action)
                if old1 then SetBinding(old1) end
                if old2 then SetBinding(old2) end
                SaveBindings(GetCurrentBindingSet())
                self:SetText("Not Bound")

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
    end
    optionsFrame.keybindBtn = keybindButtons["EASYFIND_TOGGLE"]
    optionsFrame.focusBtn = keybindButtons["EASYFIND_FOCUS"]
    optionsFrame.toggleFocusBtn = keybindButtons["EASYFIND_TOGGLE_FOCUS"]
    optionsFrame.clearBtn = keybindButtons["EASYFIND_CLEAR"]


    -- BOTTOM - Reset buttons (tips moved to Home tab)

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
        text = "Reset all EasyFind positions to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetPositions() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_DISABLE_UI_SEARCH"] = {
        text = "Disable UI Search?\n\nThis will remove the main search bar. You can re-enable it later from options.",
        button1 = "Disable",
        button2 = "Cancel",
        OnAccept = function()
            EasyFind.db.enableUISearch = false
            UpdateUIToggleVisual()
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_DISABLE_MAP_SEARCH"] = {
        text = "Disable Map Search?\n\nThis will remove map search bars, pins, and all map overlay features. You can re-enable it later from options.",
        button1 = "Disable",
        button2 = "Cancel",
        OnAccept = function()
            EasyFind.db.enableMapSearch = false
            UpdateMapToggleVisual()
            if ns.MapSearch then
                pcall(ns.MapSearch.ClearAll, ns.MapSearch)
                pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch)
                if ns.MapSearch.HideSuperTrackGlow then
                    pcall(ns.MapSearch.HideSuperTrackGlow)
                end
            end
            StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RELOAD_PROMPT"] = {
        text = "Reload UI to apply changes?",
        button1 = "Reload Now",
        button2 = "Later",
        OnAccept = function() ReloadUI() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_UI"] = {
        text = "Reset UI Search settings to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetUI() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_MAP"] = {
        text = "Reset Map Search settings to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetMap() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_UI_POS"] = {
        text = "Reset UI Search positions to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetUIPositions() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopupDialogs["EASYFIND_RESET_MAP_POS"] = {
        text = "Reset Map Search positions to defaults?",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function() Options:DoResetMapPositions() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    -- Reset buttons inside General tab (below last slider)
    local resetAllBtn = CreateFrame("Button", nil, sec3, "UIPanelButtonTemplate")
    resetAllBtn:SetSize(RESET_BTN_W, 20)
    resetAllBtn:SetPoint("BOTTOMLEFT", sec3, "BOTTOMLEFT", 8, 8)
    resetAllBtn:SetText("Reset All Settings")
    resetAllBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_ALL")
    end)

    local resetPosBtn = CreateFrame("Button", nil, sec3, "UIPanelButtonTemplate")
    resetPosBtn:SetSize(RESET_BTN_W, 20)
    resetPosBtn:SetPoint("LEFT", resetAllBtn, "RIGHT", 8, 0)
    resetPosBtn:SetText("Reset All Positions")
    resetPosBtn:SetScript("OnClick", function()
        StaticPopup_Show("EASYFIND_RESET_POSITIONS")
    end)

    -- FEEDBACK TAB
    local feedbackTab = CreateTab("Feedback")

    local feedbackDesc = feedbackTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    feedbackDesc:SetPoint("TOPLEFT", feedbackTab, "TOPLEFT", 12, -16)
    feedbackDesc:SetPoint("RIGHT", feedbackTab, "RIGHT", -12, 0)
    feedbackDesc:SetJustifyH("LEFT")
    feedbackDesc:SetSpacing(3)
    feedbackDesc:SetText(
        "Found a bug or have an idea for a new feature? Clicking either button "
        .. "below will give you a link to submit your feedback.\n\n"
        .. "When reporting a bug, please include what you were doing when it happened "
        .. "and any error messages you saw. Screenshots are great!"
    )

    local bugBtn = CreateFrame("Button", nil, feedbackTab, "UIPanelButtonTemplate")
    bugBtn:SetSize(RESET_BTN_W, 20)
    bugBtn:SetPoint("TOPLEFT", feedbackDesc, "BOTTOMLEFT", 0, -12)
    bugBtn:SetText("Report Bug")
    bugBtn:SetScript("OnClick", function()
        EasyFind:OpenBugReport()
    end)

    local featureBtn = CreateFrame("Button", nil, feedbackTab, "UIPanelButtonTemplate")
    featureBtn:SetSize(RESET_BTN_W, 20)
    featureBtn:SetPoint("LEFT", bugBtn, "RIGHT", 12, 0)
    featureBtn:SetText("Request Feature")
    featureBtn:SetScript("OnClick", function()
        EasyFind:OpenFeatureRequest()
    end)

    local enjoyDesc = feedbackTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    enjoyDesc:SetPoint("TOPLEFT", bugBtn, "BOTTOMLEFT", 0, -18)
    enjoyDesc:SetPoint("RIGHT", feedbackTab, "RIGHT", -12, 0)
    enjoyDesc:SetJustifyH("LEFT")
    enjoyDesc:SetSpacing(3)
    enjoyDesc:SetText(
        "If you're enjoying EasyFind, spreading the word or leaving a friendly "
        .. "comment on the CurseForge page is always appreciated. "
        .. "Copy the link below to share with friends:"
    )

    local shareBox = CreateURLBox(feedbackTab, "https://www.curseforge.com/wow/addons/easyfind", enjoyDesc, -6)

    -- Show Home tab by default
    SwitchToTab(1)

    optionsFrame:Hide()

    self:RegisterWithBlizzardOptions()
end

function Options:DoResetPositions()
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    EasyFind.db.mapSearchPositionMax = nil
    EasyFind.db.globalSearchPositionMax = nil
    EasyFind.db.optionsPosition = nil
    if ns.UI and ns.UI.ResetPosition then ns.UI:ResetPosition() end
    if ns.MapSearch and ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
    if optionsFrame then
        optionsFrame:ClearAllPoints()
        optionsFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    end
end

function Options:DoResetAll()
    local needsReload = (EasyFind.db.enableUISearch == false) or (EasyFind.db.enableMapSearch == false)
    EasyFind.db.iconScale = 0.8
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
    EasyFind.db.mapFontSize = 1.0
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    EasyFind.db.mapSearchPositionMax = nil
    EasyFind.db.globalSearchPositionMax = nil
    EasyFind.db.mapSearchYOffset = 0
    EasyFind.db.directOpen = false
    EasyFind.db.navigateToZonesDirectly = false
    EasyFind.db.smartShow = false
    EasyFind.db.resultsTheme = "Retail"
    EasyFind.db.uiMaxResults = 10
    EasyFind.db.mapMaxResults = 6
    EasyFind.db.pinsCollapsed = false
    EasyFind.db.staticOpacity = false
    EasyFind.db.indicatorStyle = "EasyFind Arrow"
    EasyFind.db.indicatorColor = "Yellow"
    EasyFind.db.blinkingPins = false
    EasyFind.db.mapPinHighlight = true
    EasyFind.db.showLoginMessage = true
    EasyFind.db.uiResultsAbove = false
    EasyFind.db.mapResultsAbove = false
    EasyFind.db.showMinimapButton = true
    EasyFind.db.arrivalDistance = 10
    EasyFind.db.panelOpacity = 0.9
    EasyFind.db.minimapArrowGlow = true
    EasyFind.db.minimapGuideCircle = true
    EasyFind.db.autoPinClear = true
    EasyFind.db.autoTrackPins = true
    EasyFind.db.minimapPinGlow = true
    EasyFind.db.guideCircleScale = 1.0
    EasyFind.db.mapSmartShow = false
    EasyFind.db.hideSearchBarsMaximized = false
    EasyFind.db.visible = true
    EasyFind.db.enableUISearch = true
    EasyFind.db.enableMapSearch = true
    EasyFind.db.globalSearchFilters = { zones = true, dungeons = true, raids = true, delves = true }
    EasyFind.db.localSearchFilters = { instances = true, travel = true, services = true }
    EasyFind.db.uiSearchFilters = { ui = true, mounts = false, toys = false, pets = false, map = false }
    EasyFind.db.uiMapSearchLocal = true
    EasyFind.db.optionsPosition = nil

    if optionsFrame then
        optionsFrame:ClearAllPoints()
        optionsFrame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    end

    if ns.Highlight and ns.Highlight.ClearAll then
        pcall(ns.Highlight.ClearAll, ns.Highlight)
    end
    if ns.MapSearch then
        if ns.MapSearch.HideSuperTrackGlow then
            pcall(ns.MapSearch.HideSuperTrackGlow)
        end
        if _G["EasyFindMapSearchFrame"] then
            pcall(ns.MapSearch.ClearAll, ns.MapSearch)
            pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch)
        end
        ns.MapSearch.pendingWaypoint = nil
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

    optionsFrame.mapIconSlider:SetValue(0.8)
    optionsFrame.mapYOffsetSlider:SetValue(0)
    optionsFrame.panelOpacitySlider:SetValue(0.9)
    optionsFrame.opacitySlider:SetValue(DEFAULT_OPACITY)
    optionsFrame.uiFontSlider:SetValue(1.0)
    optionsFrame.mapFontSlider:SetValue(1.0)
    optionsFrame.directOpenCheckbox:SetChecked(false)
    local sf = _G["EasyFindSearchFrame"]
    if sf and sf.modeBtn and ns.UpdateModeButtonVisual then
        ns.UpdateModeButtonVisual(sf.modeBtn)
    end
    optionsFrame.zoneNavCheckbox:SetChecked(false)
    optionsFrame.smartShowCheckbox:SetChecked(false)
    optionsFrame.staticOpacityCheckbox:SetChecked(false)
    optionsFrame.loginMessageCheckbox:SetChecked(true)
    optionsFrame.uiResultsAboveCheckbox:SetChecked(false)
    optionsFrame.minimapBtnCheckbox:SetChecked(true)
    optionsFrame.searchBarGroup:UpdateVisuals()
    optionsFrame.mapPinGroup:UpdateVisuals()
    optionsFrame.minimapGroup:UpdateVisuals()
    optionsFrame.automationGroup:UpdateVisuals()
    if optionsFrame.UpdateUIToggleVisual then optionsFrame.UpdateUIToggleVisual() end
    if optionsFrame.UpdateMapToggleVisual then optionsFrame.UpdateMapToggleVisual() end
    optionsFrame.arrivalSlider:SetValue(10)
    optionsFrame.circleScaleSlider:SetValue(1.0)
    optionsFrame.themeBtnText:SetText("Retail")
    optionsFrame.indicatorBtnText:SetText("EasyFind Arrow")
    optionsFrame.colorBtnText:SetText("Yellow")
    local defaultRGB = ns.INDICATOR_COLORS["Yellow"]
    optionsFrame.colorBtnText:SetTextColor(defaultRGB[1], defaultRGB[2], defaultRGB[3])
    optionsFrame.colorSwatch:SetColorTexture(defaultRGB[1], defaultRGB[2], defaultRGB[3], 1)
    optionsFrame.keybindBtn:SetText("Not Bound")
    optionsFrame.focusBtn:SetText("Not Bound")
    optionsFrame.toggleFocusBtn:SetText("Not Bound")

    if _G["EasyFindSearchFrame"] and ns.UI then
        if ns.UI.ResetPosition then ns.UI:ResetPosition() end
        if ns.UI.UpdateScale then ns.UI:UpdateScale() end
        if ns.UI.UpdateWidth then ns.UI:UpdateWidth() end
        if ns.UI.UpdateOpacity then ns.UI:UpdateOpacity() end
        if ns.UI.UpdateSmartShow then ns.UI:UpdateSmartShow() end
        if ns.UI.UpdateFontSize then ns.UI:UpdateFontSize() end
        if ns.UI.RefreshResults then ns.UI:RefreshResults() end
    end
    if _G["EasyFindMapSearchFrame"] and ns.MapSearch then
        if ns.MapSearch.UpdateSearchBarTheme then ns.MapSearch:UpdateSearchBarTheme() end
        if ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
        if ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
        if ns.MapSearch.UpdateWidth then ns.MapSearch:UpdateWidth() end
        if ns.MapSearch.UpdateFontSize then ns.MapSearch:UpdateFontSize() end
        if ns.MapSearch.UpdateIconScales then ns.MapSearch:UpdateIconScales() end
        if ns.MapSearch.RefreshIndicators then ns.MapSearch:RefreshIndicators() end
        if ns.MapSearch.UpdateOpacity then ns.MapSearch:UpdateOpacity() end
        if ns.MapSearch.UpdateMapSmartShow then ns.MapSearch:UpdateMapSmartShow() end
    end
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then uiInd:SetScale(1.0) end
    if _G["EasyFindSearchFrame"] and ns.UI and ns.UI.Show then ns.UI:Show() end
    EasyFind:UpdateMinimapButton()

    if needsReload then
        StaticPopup_Show("EASYFIND_RELOAD_PROMPT")
    end
end

function Options:DoResetUI()
    EasyFind.db.directOpen = false
    EasyFind.db.smartShow = false
    EasyFind.db.staticOpacity = false
    EasyFind.db.uiResultsAbove = false
    EasyFind.db.fontSize = 1.0
    EasyFind.db.uiSearchScale = 1.0
    EasyFind.db.uiSearchWidth = 1.0
    EasyFind.db.uiResultsScale = 1.0
    EasyFind.db.uiResultsWidth = 1.0
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.uiMaxResults = 10
    EasyFind.db.uiSearchFilters = { ui = true, mounts = false, toys = false, pets = false, map = false }
    EasyFind.db.uiMapSearchLocal = true

    optionsFrame.directOpenCheckbox:SetChecked(false)
    optionsFrame.smartShowCheckbox:SetChecked(false)
    optionsFrame.staticOpacityCheckbox:SetChecked(false)
    optionsFrame.uiResultsAboveCheckbox:SetChecked(false)
    optionsFrame.uiFontSlider:SetValue(1.0)
    local sf = _G["EasyFindSearchFrame"]
    if sf and sf.modeBtn and ns.UpdateModeButtonVisual then
        ns.UpdateModeButtonVisual(sf.modeBtn)
    end

    ns.Highlight:ClearAll()
    if _G["EasyFindSearchFrame"] and ns.UI then
        if ns.UI.ResetPosition then ns.UI:ResetPosition() end
        if ns.UI.UpdateScale then ns.UI:UpdateScale() end
        if ns.UI.UpdateWidth then ns.UI:UpdateWidth() end
        if ns.UI.UpdateSmartShow then ns.UI:UpdateSmartShow() end
        if ns.UI.UpdateFontSize then ns.UI:UpdateFontSize() end
        if ns.UI.RefreshResults then ns.UI:RefreshResults() end
    end
end

function Options:DoResetMap()
    EasyFind.db.navigateToZonesDirectly = false
    EasyFind.db.mapSmartShow = false
    EasyFind.db.hideSearchBarsMaximized = false
    EasyFind.db.mapResultsAbove = false
    EasyFind.db.mapFontSize = 1.0
    EasyFind.db.mapSearchYOffset = 0
    EasyFind.db.iconScale = 0.8
    EasyFind.db.mapSearchScale = 1.0
    EasyFind.db.mapSearchWidth = 1.0
    EasyFind.db.mapResultsScale = 1.0
    EasyFind.db.mapResultsWidth = 1.0
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    EasyFind.db.mapSearchPositionMax = nil
    EasyFind.db.globalSearchPositionMax = nil
    EasyFind.db.mapMaxResults = 6
    EasyFind.db.mapPinHighlight = true
    EasyFind.db.blinkingPins = false
    EasyFind.db.minimapArrowGlow = true
    EasyFind.db.minimapGuideCircle = true
    EasyFind.db.minimapPinGlow = true
    EasyFind.db.guideCircleScale = 1.0
    EasyFind.db.autoPinClear = true
    EasyFind.db.autoTrackPins = true
    EasyFind.db.arrivalDistance = 10
    EasyFind.db.pinsCollapsed = false
    EasyFind.db.globalSearchFilters = { zones = true, dungeons = true, raids = true, delves = true }
    EasyFind.db.localSearchFilters = { instances = true, travel = true, services = true }

    optionsFrame.zoneNavCheckbox:SetChecked(false)
    optionsFrame.searchBarGroup:UpdateVisuals()
    optionsFrame.mapPinGroup:UpdateVisuals()
    optionsFrame.minimapGroup:UpdateVisuals()
    optionsFrame.automationGroup:UpdateVisuals()
    optionsFrame.mapFontSlider:SetValue(1.0)
    optionsFrame.mapYOffsetSlider:SetValue(0)
    optionsFrame.mapIconSlider:SetValue(0.8)
    optionsFrame.arrivalSlider:SetValue(10)
    optionsFrame.circleScaleSlider:SetValue(1.0)

    if ns.MapSearch then
        if ns.MapSearch.HideSuperTrackGlow then pcall(ns.MapSearch.HideSuperTrackGlow) end
        if _G["EasyFindMapSearchFrame"] then
            pcall(ns.MapSearch.ClearAll, ns.MapSearch)
            pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch)
        end
        ns.MapSearch.pendingWaypoint = nil
    end
    if _G["EasyFindMapSearchFrame"] and ns.MapSearch then
        if ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
        if ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
        if ns.MapSearch.UpdateWidth then ns.MapSearch:UpdateWidth() end
        if ns.MapSearch.UpdateFontSize then ns.MapSearch:UpdateFontSize() end
        if ns.MapSearch.UpdateIconScales then ns.MapSearch:UpdateIconScales() end
        if ns.MapSearch.RefreshIndicators then ns.MapSearch:RefreshIndicators() end
        if ns.MapSearch.UpdateMapSmartShow then ns.MapSearch:UpdateMapSmartShow() end
    end
    local uiInd = _G["EasyFindIndicatorFrame"]
    if uiInd then uiInd:SetScale(0.8) end
end

function Options:DoResetUIPositions()
    EasyFind.db.uiSearchPosition = nil
    EasyFind.db.uiSearchScale = 1.0
    EasyFind.db.uiSearchWidth = 1.0
    EasyFind.db.uiResultsScale = 1.0
    EasyFind.db.uiResultsWidth = 1.0
    if _G["EasyFindSearchFrame"] and ns.UI then
        if ns.UI.ResetPosition then ns.UI:ResetPosition() end
        if ns.UI.UpdateScale then ns.UI:UpdateScale() end
        if ns.UI.UpdateWidth then ns.UI:UpdateWidth() end
    end
end

function Options:DoResetMapPositions()
    EasyFind.db.mapSearchPosition = nil
    EasyFind.db.globalSearchPosition = nil
    EasyFind.db.mapSearchPositionMax = nil
    EasyFind.db.globalSearchPositionMax = nil
    EasyFind.db.mapSearchScale = 1.0
    EasyFind.db.mapSearchWidth = 1.0
    EasyFind.db.mapResultsScale = 1.0
    EasyFind.db.mapResultsWidth = 1.0
    EasyFind.db.mapSearchYOffset = 0
    optionsFrame.mapYOffsetSlider:SetValue(0)
    if _G["EasyFindMapSearchFrame"] and ns.MapSearch then
        if ns.MapSearch.ResetPosition then ns.MapSearch:ResetPosition() end
        if ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
        if ns.MapSearch.UpdateWidth then ns.MapSearch:UpdateWidth() end
    end
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
    optionsFrame.panelOpacitySlider:SetValue(EasyFind.db.panelOpacity or 0.9)
    optionsFrame.opacitySlider:SetValue(EasyFind.db.searchBarOpacity or DEFAULT_OPACITY)
    optionsFrame.uiFontSlider:SetValue(EasyFind.db.fontSize or 1.0)
    optionsFrame.mapFontSlider:SetValue(EasyFind.db.mapFontSize or 1.0)
    optionsFrame.mapIconSlider:SetValue(EasyFind.db.iconScale or 0.8)
    optionsFrame.mapYOffsetSlider:SetValue(EasyFind.db.mapSearchYOffset or 0)
    optionsFrame.arrivalSlider:SetValue(EasyFind.db.arrivalDistance or 10)
    optionsFrame.directOpenCheckbox:SetChecked(EasyFind.db.directOpen or false)
    optionsFrame.zoneNavCheckbox:SetChecked(EasyFind.db.navigateToZonesDirectly or false)
    optionsFrame.smartShowCheckbox:SetChecked(EasyFind.db.smartShow or false)
    optionsFrame.staticOpacityCheckbox:SetChecked(EasyFind.db.staticOpacity or false)
    optionsFrame.loginMessageCheckbox:SetChecked(EasyFind.db.showLoginMessage ~= false)
    optionsFrame.uiResultsAboveCheckbox:SetChecked(EasyFind.db.uiResultsAbove or false)
    optionsFrame.minimapBtnCheckbox:SetChecked(EasyFind.db.showMinimapButton or false)
    optionsFrame.searchBarGroup:UpdateVisuals()
    optionsFrame.mapPinGroup:UpdateVisuals()
    optionsFrame.minimapGroup:UpdateVisuals()
    optionsFrame.automationGroup:UpdateVisuals()
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

    if optionsFrame.bgTex then
        optionsFrame.bgTex:SetAlpha(EasyFind.db.panelOpacity or 0.9)
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
