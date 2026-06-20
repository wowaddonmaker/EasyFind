local _, ns = ...

local Utils = ns.Utils
local Render = ns.ResultRender
local Calculator = ns.Calculator
local Icons = ns.ResultIcons

local sformat = Utils.sformat
local mfloor = Utils.mfloor
local AbbrevBinding = Render.AbbrevBinding
local SetClippedText = Render.SetClippedText

function Render.SettingsWidget(resultRow, data, entry)
    -- Setting state visualization. Checkbox: check/uncheck atlas
    -- (toggle inline via PostClick). Slider: actual draggable
    -- slider widget with value label. Dropdown/other: current
    -- value as muted text (click opens panel to edit).
    local isKeybindEntry = data and data.settingType == "keybind" and data.bindingAction
    if isKeybindEntry and not entry.isPathNode then
        -- Keybinding row: two inline buttons showing current
        -- primary/alternate keys. Refresh function lets the
        -- buttons re-read GetBindingKey after a capture/clear.
        local action = data.bindingAction
        local kb1 = resultRow.settingKeybind1
        local kb2 = resultRow.settingKeybind2
        local function refresh()
            local k1, k2 = GetBindingKey(action)
            kb1:SetText(AbbrevBinding(k1))
            kb2:SetText(AbbrevBinding(k2))
        end
        kb1._bindingAction = action
        kb1._refresh = refresh
        kb2._bindingAction = action
        kb2._refresh = refresh
        refresh()
        resultRow.settingKeybindGroup:Show()
        if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
        resultRow.settingState:Hide()
        resultRow.settingCheck:Hide()
        resultRow.amountText:Hide()
        resultRow.text:SetPoint("RIGHT", resultRow.settingKeybindGroup, "LEFT", -4, 0)
    elseif data and data.settingVariable and not entry.isPathNode then
        if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
        local settingType = data.settingType
        if settingType == "checkboxSlider" and data.cbVariable and data.sliderVariable then
            -- Combined widget: checkbox state + slider in one row
            -- (mirrors Blizzard's CreateSettingsCheckboxSliderInitializer
            -- visual e.g. "Use Search Scale" with the % slider).
            local isOn = false
            if Settings and Settings.GetSetting then
                local sok, cbObj = pcall(Settings.GetSetting, data.cbVariable)
                if sok and cbObj and cbObj.GetValue then
                    local vok, v = pcall(cbObj.GetValue, cbObj)
                    if vok then isOn = (v == true or v == "1" or v == 1) end
                end
            end
            resultRow.settingState:Show()
            resultRow.settingCheck:SetShown(isOn)
            resultRow.amountText:Hide()
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end

            local sliderVar = data.sliderVariable
            local rawVal
            if Settings and Settings.GetSetting then
                local sok, sObj = pcall(Settings.GetSetting, sliderVar)
                if sok and sObj and sObj.GetValue then
                    local vok, v = pcall(sObj.GetValue, sObj)
                    if vok then rawVal = v end
                end
            end
            if rawVal == nil and GetCVar then rawVal = GetCVar(sliderVar) end
            local numVal = tonumber(rawVal) or data.settingMin or 0
            local sMin = data.settingMin or 0
            local sMax = data.settingMax or 1
            local stepVal = data.settingStep or 1
            if sMax <= sMin then sMax = sMin + 1 end
            local slider = resultRow.settingSlider
            slider._settingVar = sliderVar
            slider._settingFormatter = data.settingFormatter
            slider._updating = true
            slider:SetMinMaxValues(sMin, sMax)
            slider:SetValueStep(stepVal)
            slider:SetValue(numVal)
            slider._updating = false

            if not data.settingFormatter
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(sliderVar)
                if fmt then data.settingFormatter = fmt end
            end
            local displayVal
            if data.settingFormatter then
                local fok, formatted = pcall(data.settingFormatter, numVal)
                if fok and formatted ~= nil then
                    local ft = type(formatted)
                    if ft == "string" and formatted ~= "" then displayVal = formatted
                    elseif ft == "number" then
                        displayVal = (formatted == mfloor(formatted))
                            and tostring(mfloor(formatted))
                            or sformat("%.2f", formatted)
                    end
                end
            end
            if not displayVal then
                displayVal = (numVal == mfloor(numVal))
                    and tostring(mfloor(numVal))
                    or sformat("%.2f", numVal)
            end
            resultRow.settingSliderValue:SetText(displayVal)

            -- Slider group sits to the LEFT of the checkbox
            -- so both fit on the right side of the row.
            resultRow.settingSliderGroup:ClearAllPoints()
            resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow.settingState, "LEFT", -6, 0)
            resultRow.settingSliderGroup:Show()

            resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
        elseif settingType == "checkbox" then
            local isOn = false
            local optimistic = ns.Results and ns.Results._settingOptimistic
            if optimistic and optimistic.var == data.settingVariable then
                -- Just-toggled value, shown before GetValue catches up.
                isOn = optimistic.isOn
            else
                -- Trust the Settings object's logical value when it resolves; only
                -- read the raw CVar for variables with no registered setting. An
                -- inverted setting (e.g. Sticky Targeting / deselectOnClick) reports
                -- false when its raw CVar is "1", so OR-ing in the raw CVar would
                -- wrongly keep the box checked.
                local resolved = false
                if Settings and Settings.GetSetting then
                    local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                    if sok and settObj and settObj.GetValue then
                        local vok, v = pcall(settObj.GetValue, settObj)
                        if vok then
                            isOn = (v == true or v == "1" or v == 1)
                            resolved = true
                        end
                    end
                end
                if not resolved and GetCVar then
                    local val = GetCVar(data.settingVariable)
                    isOn = (val == "1")
                end
            end
            resultRow.settingState:Show()
            resultRow.settingCheck:SetShown(isOn)
            resultRow.amountText:Hide()
            if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            -- Re-anchor text RIGHT to settingState so the row name
            -- truncates at the checkbox instead of overlapping it.
            resultRow.text:SetPoint("RIGHT", resultRow.settingState, "LEFT", -4, 0)
        elseif settingType == "slider" and data.settingMin and data.settingMax then
            local rawVal
            if Settings and Settings.GetSetting then
                local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                if sok and settObj and settObj.GetValue then
                    local vok, v = pcall(settObj.GetValue, settObj)
                    if vok then rawVal = v end
                end
            end
            if rawVal == nil and GetCVar then
                rawVal = GetCVar(data.settingVariable)
            end
            local numVal = tonumber(rawVal) or data.settingMin

            local sMin, sMax = data.settingMin, data.settingMax
            local stepVal = data.settingStep or 1
            if sMax <= sMin then sMax = sMin + 1 end
            local slider = resultRow.settingSlider
            slider._settingVar = data.settingVariable
            slider._settingFormatter = data.settingFormatter
            slider._updating = true
            slider:SetMinMaxValues(sMin, sMax)
            slider:SetValueStep(stepVal)
            slider:SetValue(numVal)
            slider._updating = false
            resultRow.settingSliderGroup:ClearAllPoints()
            resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
            resultRow.settingSliderGroup:Show()

            -- Curated SETTINGS_DATA rows don't ship with a
            -- formatter; pull from the live registry on demand
            -- so the inline value matches Blizzard's panel
            -- (Mouse Look Speed raw 180 -> displayed "5.5").
            if not data.settingFormatter
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(data.settingVariable)
                if fmt then data.settingFormatter = fmt end
            end
            local displayVal
            if data.settingFormatter then
                local fok, formatted = pcall(data.settingFormatter, numVal)
                if fok and formatted ~= nil then
                    local ft = type(formatted)
                    if ft == "string" and formatted ~= "" then
                        displayVal = formatted
                    elseif ft == "number" then
                        displayVal = (formatted == mfloor(formatted))
                            and tostring(mfloor(formatted))
                            or sformat("%.2f", formatted)
                    end
                end
            end
            if not displayVal then
                if numVal == mfloor(numVal) then
                    displayVal = tostring(mfloor(numVal))
                else
                    displayVal = sformat("%.2f", numVal)
                end
            end
            resultRow.settingSliderValue:SetText(displayVal)

            resultRow.settingState:Hide()
            resultRow.settingCheck:Hide()
            resultRow.amountText:Hide()
            if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
        else
            -- Dropdown / other: show current value as text
            local val, rawVal
            if Settings and Settings.GetSetting then
                local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                if sok and settObj and settObj.GetValue then
                    local vok, raw = pcall(settObj.GetValue, settObj)
                    if vok and raw ~= nil then
                        rawVal = raw
                        val = tostring(raw)
                    end
                end
            end
            if (not val or val == "") and GetCVar then
                rawVal = GetCVar(data.settingVariable)
                val = rawVal
            end
            -- Lazily cache the option list so subsequent renders
            -- can translate raw values (often opaque ints) into
            -- the localized label the dropdown actually shows.
            if data.settingType == "dropdown" and not data.settingOptions
               and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                local opts = ns.BlizzOptionsSearch.GetOptionsForVariable(data.settingVariable)
                if opts then data.settingOptions = opts end
            end
            local optList = (data.settingType == "dropdown" and type(data.settingOptions) == "table")
                and data.settingOptions or nil
            if optList and rawVal ~= nil then
                for oi = 1, #optList do
                    local o = optList[oi]
                    if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                        val = o.label or val
                        break
                    end
                end
            end
            if optList and #optList > 0 then
                -- Inline dropdown widget: paddle arrows + center
                -- button styled like the in-game Settings dropdown.
                if resultRow.SetSettingDropdownText then
                    resultRow:SetSettingDropdownText(val or "")
                else
                    resultRow.settingDropdownLabel:SetText(val or "")
                end
                resultRow.settingDropdownGroup:Show()
                resultRow.amountText:Hide()
                resultRow.text:SetPoint("RIGHT", resultRow.settingDropdownGroup, "LEFT", -4, 0)
            else
                -- No enumerable options: muted text fallback. Click
                -- opens the panel via OpenSettingNoClose.
                if val and val ~= "" then
                    resultRow.amountText:SetText("|cFFAAAAaa" .. val .. "|r")
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                    resultRow.amountText:Show()
                end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            end
            resultRow.settingState:Hide()
            resultRow.settingCheck:Hide()
            if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        end
    else
        resultRow.settingState:Hide()
        resultRow.settingCheck:Hide()
        if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
        if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
    end


end

function Render.CalculatorRow(self, resultRow, data, state)
    resultRow.text:SetText("")
    resultRow.amountText:Hide()
    if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
    if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
    Icons:SetRowIcon(resultRow, "hidden", nil, state.rowIconSize)

    if data.calculatorResult then
        resultRow.calcCard:ClearAllPoints()
        resultRow.calcCard:SetPoint("TOPLEFT", resultRow, "TOPLEFT", 4, -3)
        resultRow.calcCard:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 3)
        resultRow.calcCard:Show()

        resultRow.calcDivider:ClearAllPoints()
        resultRow.calcDivider:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
        resultRow.calcDivider:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
        resultRow.calcDivider:Show()

        resultRow.calcArrowText:ClearAllPoints()
        resultRow.calcArrowText:SetPoint("CENTER", resultRow.calcCard, "CENTER", 0, 0)
        resultRow.calcArrowText:Show()

        resultRow.calcDividerTop:ClearAllPoints()
        resultRow.calcDividerTop:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
        resultRow.calcDividerTop:SetPoint("BOTTOM", resultRow.calcArrowText, "TOP", 0, 3)
        resultRow.calcDividerTop:Show()

        resultRow.calcDividerBottom:ClearAllPoints()
        resultRow.calcDividerBottom:SetPoint("TOP", resultRow.calcArrowText, "BOTTOM", 0, -3)
        resultRow.calcDividerBottom:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
        resultRow.calcDividerBottom:Show()

        resultRow.calcExpressionText:ClearAllPoints()
        resultRow.calcExpressionText:SetPoint("LEFT", resultRow.calcCard, "LEFT", 12, 0)
        resultRow.calcExpressionText:SetPoint("RIGHT", resultRow.calcDivider, "LEFT", -22, 0)
        SetClippedText(resultRow.calcExpressionText, data.calculatorExpression or data.name or "")
        resultRow.calcExpressionHighlight:ClearAllPoints()
        resultRow.calcExpressionHighlight:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
        resultRow.calcExpressionHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
        resultRow.calcExpressionFlash:ClearAllPoints()
        resultRow.calcExpressionFlash:SetPoint("TOPLEFT", resultRow.calcExpressionHighlight, "TOPLEFT")
        resultRow.calcExpressionFlash:SetPoint("BOTTOMRIGHT", resultRow.calcExpressionHighlight, "BOTTOMRIGHT")

        resultRow.calcResultText:ClearAllPoints()
        resultRow.calcResultText:SetPoint("LEFT", resultRow.calcDivider, "RIGHT", 22, 0)
        resultRow.calcResultText:SetPoint("RIGHT", resultRow.calcCard, "RIGHT", -12, 0)
        SetClippedText(resultRow.calcResultText, data.calculatorResult)
        resultRow.calcResultHighlight:ClearAllPoints()
        resultRow.calcResultHighlight:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
        resultRow.calcResultHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
        resultRow.calcResultFlash:ClearAllPoints()
        resultRow.calcResultFlash:SetPoint("TOPLEFT", resultRow.calcResultHighlight, "TOPLEFT")
        resultRow.calcResultFlash:SetPoint("BOTTOMRIGHT", resultRow.calcResultHighlight, "BOTTOMRIGHT")
        resultRow.calcExpressionButton:ClearAllPoints()
        resultRow.calcExpressionButton:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
        resultRow.calcExpressionButton:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
        resultRow.calcExpressionButton:Show()

        resultRow.calcResultButton:ClearAllPoints()
        resultRow.calcResultButton:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
        resultRow.calcResultButton:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
        resultRow.calcResultButton:Show()

        self:SetCalculatorCopyHighlight(resultRow, Calculator._calculator.activeData == data and Calculator._calculator.activePart or nil)
        return true
    end

    return true
end
