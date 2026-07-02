local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs, pairs = Utils.ipairs, Utils.pairs
local CreateFrame = CreateFrame
local UIParent = UIParent
local wipe = wipe
local UI_FILTER_OPTIONS = Filters.UI_FILTER_OPTIONS
local ForEachFilterKey = Filters.ForEachFilterKey

local SetFlyoutRowEnabled = Utils.SetFlyoutRowEnabled

function Filters:CreateUIFilterDropdown(toggleBtn, anchorFrame, searchEditBox)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    -- Single source of truth for which side-flyout (sub-filters / radio /
    -- gear options) is currently visible. Any popup that opens hides
    -- whatever was active so sweeping between rows can never leave a
    -- previous flyout lingering, even rows whose popup wasn't tracked
    -- in dropdown.flyoutPopups.
    local activeFlyoutPopup
    local function SetActiveFlyout(popup)
        if activeFlyoutPopup and activeFlyoutPopup ~= popup and activeFlyoutPopup:IsShown() then
            activeFlyoutPopup:Hide()
        end
        activeFlyoutPopup = popup
    end
    local function ClearActiveFlyout(popup)
        if activeFlyoutPopup == popup then activeFlyoutPopup = nil end
    end

    local dropdown = CreateFrame("Frame", "EasyFindUIFilterDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    -- Bump everything in the filter menu uniformly: 1.5x larger fonts,
    -- icons, paddings, and row heights without rewriting the hardcoded
    -- pixel sizes scattered through the row builders.
    dropdown:SetScale(1.5)
    dropdown:Hide()
    dropdown:EnableMouse(true)
    -- Popups that should prevent the dropdown from closing on outside-click.
    -- Each sub-filter registers its popups here instead of hardcoding frame names.
    -- Stashed on the dropdown so the search bar's autoHide handler can also
    -- consult it (otherwise clicks inside a flyout dismiss the bar).
    local dropdownGuardFrames = {}
    dropdown.guardFrames = dropdownGuardFrames
    dropdown:SetClampedToScreen(true)

    local function KeepSearchEditBoxUnfocused()
        if searchEditBox and searchEditBox.ClearFocus then searchEditBox:ClearFocus() end
    end

    ns.StyleMenuPanel(dropdown)
    dropdown:HookScript("OnShow", function(self) ns.ApplyMenuOpacity(self) end)

    local ICON_SIZE = 14

    local RADIO_SIZE = 14
    local RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-off"
    local RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-on"

    local function InstallMenuRowHighlight(row)
        Utils.InstallMenuRowHighlight(row)
    end

    local function StylePopup(frame)
        ns.StyleMenuPanel(frame)
    end

    local function CreateRadioTexture(parent)
        local tex = parent:CreateTexture(nil, "ARTWORK")
        tex:SetSize(RADIO_SIZE, RADIO_SIZE)
        tex:SetTexture(RADIO_OFF_TEX)
        local function SetChecked(checked)
            tex:SetTexture(checked and RADIO_ON_TEX or RADIO_OFF_TEX)
        end
        return tex, SetChecked
    end

    local uncheckRow = CreateFrame("Button", nil, dropdown)
    uncheckRow:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
    uncheckRow:SetPoint("TOPLEFT", 8, -PADDING_TOP)
    local uncheckLabel = uncheckRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    uncheckLabel:SetPoint("LEFT", 8, 0)
    uncheckLabel:SetText(L["FILTER_TOGGLE_ALL"])
    InstallMenuRowHighlight(uncheckRow)

    local checkRows = {}
    local checkRowsByIndex = {}
    local LayoutDropdown  -- forward declaration
    local dropdownKeyboardMode = false

    -- Reusable keyboard nav for popup menus (diff popup, spec popup, class flyout).
    -- Uses a single dropdownKeyboardMode flag: when true, any popup hiding returns
    -- keyboard to the dropdown. No parent tracking needed.
    local function AddPopupKeyboardNav(popup, getRows)
        local popupFocus = 0
        local popupFocusRow

        local function SetPopupFocus(idx)
            local rows = getRows()
            if popupFocusRow and popupFocusRow.SetMenuHighlightFocused then
                popupFocusRow:SetMenuHighlightFocused(false)
            end
            popupFocus = idx
            local target = rows[idx]
            if target then
                if target.SetMenuHighlightFocused then
                    target:SetMenuHighlightFocused(true)
                end
                popupFocusRow = target
            else
                popupFocusRow = nil
            end
        end

        Utils.SafeCallMethod(popup, "EnableKeyboard", false)
        Utils.SafeCallMethod(popup, "SetPropagateKeyboardInput", false)

        popup:HookScript("OnKeyDown", function(self, key)
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            local rows = getRows()
            if key == "DOWN" then
                Search:GetSearchFrame().StartKeyRepeat(key, function()
                    local r = getRows()
                    local next = popupFocus + 1
                    if next > #r then next = 1 end
                    SetPopupFocus(next)
                end)
            elseif key == "UP" then
                Search:GetSearchFrame().StartKeyRepeat(key, function()
                    local r = getRows()
                    local prev = popupFocus - 1
                    if prev < 1 then prev = #r end
                    SetPopupFocus(prev)
                end)
            elseif key == "ENTER" then
                local target = rows[popupFocus]
                if target and target.Click then target:Click() end
            elseif key == "ESCAPE" then
                -- Route through HandleEscape: closes the parent dropdown
                -- and any sibling popups together, refocuses editbox.
                -- Bare self:Hide() only hits this popup and leaves the
                -- main dropdown / nested popups behind.
                Search:HandleEscape()
            else
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
            end
        end)
        popup:HookScript("OnKeyUp", function(_, key)
            if Search:GetSearchFrame().IsRepeatKey(key) then Search:GetSearchFrame().StopKeyRepeat() end
        end)

        popup:HookScript("OnShow", function(self)
            if dropdownKeyboardMode then
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
                local sp = _G["EasyFindSpecPopup"]
                if sp then Utils.SafeCallMethod(sp, "EnableKeyboard", false) end
                local cf = _G["EasyFindSpecFlyout"]
                if cf then Utils.SafeCallMethod(cf, "EnableKeyboard", false) end
                local dp = _G["EasyFindDiffPopup"]
                if dp then Utils.SafeCallMethod(dp, "EnableKeyboard", false) end
                Utils.SafeCallMethod(self, "EnableKeyboard", true)
                SetPopupFocus(1)
            end
        end)

        popup:HookScript("OnHide", function(self)
            popupFocus = 0
            if popupFocusRow and popupFocusRow.SetMenuHighlightFocused then
                popupFocusRow:SetMenuHighlightFocused(false)
            end
            popupFocusRow = nil
            Utils.SafeCallMethod(self, "EnableKeyboard", false)
            if dropdownKeyboardMode and dropdown:IsShown() then
                Utils.SafeCallMethod(dropdown, "EnableKeyboard", true)
            end
        end)
    end

    for i, opt in ipairs(UI_FILTER_OPTIONS) do
        -- Children of a parent filter (e.g., Collections > Mounts) render
        -- indented; their visible width shrinks by SUB_INDENT so the
        -- right-edge icon stays inside the dropdown.
        local rowWidth = DROPDOWN_WIDTH - 16
        if opt.parentKey then rowWidth = rowWidth - 24 end
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(rowWidth, ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key
        row.parentKey = opt.parentKey

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        -- Category icon sits between the checkbox and label so the row
        -- reads left-to-right as [check][icon][name]. Supports atlas,
        -- raw fileID, or fileID + texCoords for sprite-sheet sub-icons.
        local icon
        if opt.iconAtlas or opt.iconTex then
            icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
            if opt.iconAtlas then
                icon:SetAtlas(opt.iconAtlas)
            else
                icon:SetTexture(opt.iconTex)
                if opt.iconCoords then
                    icon:SetTexCoord(opt.iconCoords[1], opt.iconCoords[2],
                                     opt.iconCoords[3], opt.iconCoords[4])
                end
            end
            row.iconTex = icon
        end

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        if icon then
            label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        else
            label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        end
        label:SetText(opt.label)
        row.label = label

        -- Right-pointing chevron on rows that have a flyout, signalling
        -- the row expands to the right. Mirrors the standard submenu
        -- indicator used elsewhere in the WoW Search. flyoutSubFilters drives
        -- the auto-built sub-filter popup; hasFlyout opts in rows whose
        if opt.flyoutSubFilters or opt.flyoutRadio or opt.hasFlyout then
            local chev = row:CreateTexture(nil, "OVERLAY")
            chev:SetAtlas("common-icon-forwardarrow")
            chev:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
            chev:SetPoint("RIGHT", -4, 0)
            chev:SetVertexColor(0.85, 0.85, 0.85, 1)
            row.flyoutChevron = chev
            label:SetPoint("RIGHT", chev, "LEFT", -4, 0)
            label:SetWordWrap(false)
            label:SetJustifyH("LEFT")
            row:HookScript("OnEnter", function() chev:SetVertexColor(1, 1, 1, 1) end)
            row:HookScript("OnLeave", function() chev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
        end

        -- Flyout sub-filters (e.g. Collections > Mounts/Toys/Pets/...).
        -- Hovering the row opens a popup containing one CheckButton per
        -- sub-filter. Each sub-filter writes through to filters[subKey]
        -- like a regular top-level filter so search uses them as-is.
        if opt.flyoutSubFilters then
            local SUB_POPUP_WIDTH = 180
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local CHK = CHECK_SIZE
            local SUB_ICON = ICON_SIZE

            -- Parent to UIParent + TOOLTIP strata mirrors the loot
            -- spec/class popups; nesting under `dropdown` left clicks
            -- routed back to the dropdown's own outside-click handler
            -- and the popup felt unclickable.
            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            -- Sibling registry so each flyout's ShowPopup can hide
            -- every other flyout on entry (kills overlap on quick
            -- row-to-row hover transitions).
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            -- Outside-click: close on click outside the popup. Nested
            -- options popups (e.g. appearance set options) act as
            -- guards so clicking inside them keeps this popup open.
            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if not Filters.IsMouseInFilterChain() then self:Hide() end
            end)

            local subRows = {}
            -- Collections and Map carry many sub-filters; give their flyouts
            -- the same Toggle All row the main menu has (created below).
            local toggleAllRow
            local toggleAllOffset = (opt.key == "collections" or opt.key == "map") and 1 or 0
            for si, sub in ipairs(opt.flyoutSubFilters) do
                local subRow = CreateFrame("CheckButton", nil, popup)
                subRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                subRow:SetHitRectInsets(0, 0, 0, 0)
                subRow:SetPoint("TOPLEFT", popup, "TOPLEFT", SUB_PAD, -(SUB_PAD + (si - 1 + toggleAllOffset) * SUB_ROW_H))

                subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                subRow:GetNormalTexture():SetSize(CHK, CHK)
                subRow:GetNormalTexture():ClearAllPoints()
                subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

                subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                subRow:GetCheckedTexture():SetSize(CHK, CHK)
                subRow:GetCheckedTexture():ClearAllPoints()
                subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

                local subIcon
                if sub.iconAtlas or sub.iconTex then
                    subIcon = subRow:CreateTexture(nil, "ARTWORK")
                    subIcon:SetSize(SUB_ICON, SUB_ICON)
                    subIcon:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                    if sub.iconAtlas then
                        subIcon:SetAtlas(sub.iconAtlas)
                    else
                        subIcon:SetTexture(sub.iconTex)
                    end
                    if sub.iconColor then
                        subIcon:SetVertexColor(unpack(sub.iconColor))
                    end
                end

                local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                if subIcon then
                    subLabel:SetPoint("LEFT", subIcon, "RIGHT", 4, 0)
                else
                    subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                end
                subLabel:SetText(sub.label)
                subRow._label = subLabel
                subRow._icon = subIcon

                if sub.hasOptions then
                    local subChev = subRow:CreateTexture(nil, "OVERLAY")
                    subChev:SetAtlas("common-icon-forwardarrow")
                    subChev:SetSize(SUB_ICON - 2, SUB_ICON - 2)
                    subChev:SetPoint("RIGHT", -4, 0)
                    subChev:SetVertexColor(0.85, 0.85, 0.85, 1)
                    subLabel:SetPoint("RIGHT", subChev, "LEFT", -4, 0)
                    subLabel:SetWordWrap(false)
                    subLabel:SetJustifyH("LEFT")
                    subRow:HookScript("OnEnter", function() subChev:SetVertexColor(1, 1, 1, 1) end)
                    subRow:HookScript("OnLeave", function() subChev:SetVertexColor(0.85, 0.85, 0.85, 1) end)
                    subRow._chev = subChev
                end

                InstallMenuRowHighlight(subRow)

                subRow:SetScript("OnClick", function(self)
                    local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                   or EasyFind.db.uiSearchFilters
                    target[sub.key] = self:GetChecked()
                    Filters.ResyncShownOptionPopups()
                    if searchEditBox:GetText() ~= "" then
                        Search:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)

                subRows[si] = subRow
                subRows[sub.key] = subRow

                -- Appearances: Items / Sets chooser (each a checkbox toggle with
                -- its own class / slot / filter options flyout) opens to the
                -- right of this sub-row on hover.
                if sub.hasOptions and sub.key == "appearances" then
                    local optionsPopup, syncOptions, appBranchPopups = Search:BuildAppearanceOptionsPopup(
                        StylePopup, CHECK_SIZE, searchEditBox, dropdownGuardFrames)
                    Search._SyncAppearanceOptions = syncOptions
                    optionsPopup._efSync = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._appearanceSetOptionsPopup = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup

                    Utils.AttachHoverPopup(subRow, optionsPopup, {
                        chainGuards = appBranchPopups,
                        onShow = function()
                            syncOptions()
                            optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                            Utils.OpenFlyoutBeside(optionsPopup, subRow, 4)
                            optionsPopup:Show()
                        end,
                    })

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end

                if sub.hasOptions and sub.key == "mounts" then
                    local optionsPopup, syncOptions, sourcePopup = Search:BuildMountOptionsPopup(
                        StylePopup, CHECK_SIZE, searchEditBox)
                    Search._SyncMountOptions = syncOptions
                    optionsPopup._efSync = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._mountOptionsPopup = optionsPopup
                    popup._mountSourcePopup = sourcePopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = sourcePopup

                    Utils.AttachHoverPopup(subRow, optionsPopup, {
                        extraGuards = { sourcePopup },
                        onShow = function()
                            syncOptions()
                            optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                            Utils.OpenFlyoutBeside(optionsPopup, subRow, 4)
                            optionsPopup:Show()
                        end,
                    })

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end

                if sub.hasOptions and sub.key == "heirlooms" then
                    local optionsPopup, syncOptions, sourcePopup = Search:BuildHeirloomOptionsPopup(
                        StylePopup, CHECK_SIZE, searchEditBox, dropdownGuardFrames)
                    Search._SyncHeirloomOptions = syncOptions
                    optionsPopup._efSync = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._heirloomOptionsPopup = optionsPopup
                    popup._heirloomSourcePopup = sourcePopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = sourcePopup

                    Utils.AttachHoverPopup(subRow, optionsPopup, {
                        extraGuards = { sourcePopup },
                        onShow = function()
                            syncOptions()
                            optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                            Utils.OpenFlyoutBeside(optionsPopup, subRow, 4)
                            optionsPopup:Show()
                        end,
                    })

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function() optionsPopup:Hide() end)
                end
            end
            -- Sibling sub-rows hide an options popup so it doesn't linger when
            -- the cursor moves to a non-options row.
            local function HookSiblingHide(popupField, ownerRow)
                local optionsPopup = popup[popupField]
                if not optionsPopup then return end
                for _, srOther in ipairs(subRows) do
                    if srOther ~= ownerRow then
                        srOther:HookScript("OnEnter", function() optionsPopup:Hide() end)
                    end
                end
            end
            HookSiblingHide("_appearanceSetOptionsPopup", subRows.appearances)
            HookSiblingHide("_mountOptionsPopup", subRows.mounts)
            HookSiblingHide("_heirloomOptionsPopup", subRows.heirlooms)
            row.flyoutSubRows = subRows

            -- "Hide tooltips" checkbox at the bottom of the collections
            -- flyout. Toggles the per-group EasyFind.db.hideTooltips
            -- setting that the OnEnter handlers consult before showing
            -- mount / toy / pet / heirloom / appearance set tooltips.
            local extraRows = 0
            local hideTipRow
            if opt.key == "collections" then
                hideTipRow = CreateFrame("CheckButton", nil, popup)
                hideTipRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                hideTipRow:SetHitRectInsets(0, 0, 0, 0)
                hideTipRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + (#opt.flyoutSubFilters + toggleAllOffset) * SUB_ROW_H))
                hideTipRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                hideTipRow:GetNormalTexture():SetSize(CHK, CHK)
                hideTipRow:GetNormalTexture():ClearAllPoints()
                hideTipRow:GetNormalTexture():SetPoint("LEFT", 4, 0)
                hideTipRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                hideTipRow:GetCheckedTexture():SetSize(CHK, CHK)
                hideTipRow:GetCheckedTexture():ClearAllPoints()
                hideTipRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)
                local lbl = hideTipRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", hideTipRow:GetNormalTexture(), "RIGHT", 4, 0)
                lbl:SetText(L["FILTER_HIDE_TOOLTIPS"])
                hideTipRow._label = lbl
                InstallMenuRowHighlight(hideTipRow)
                hideTipRow:SetScript("OnClick", function(self)
                    EasyFind.db.hideTooltips = EasyFind.db.hideTooltips or {}
                    EasyFind.db.hideTooltips.collections = self:GetChecked() and true or false
                end)
                row.hideTooltipsRow = hideTipRow
                extraRows = 1
            end
            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + (#opt.flyoutSubFilters + extraRows + toggleAllOffset) * SUB_ROW_H)

            -- Sync sub-row checked state from current DB values.
            local function SyncSubChecks()
                local parentEnabled = EasyFind.db.uiSearchFilters[opt.key] ~= false
                for _, sub in ipairs(opt.flyoutSubFilters) do
                    local sr = subRows[sub.key]
                    if sr then
                        local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        sr:SetChecked(target[sub.key] ~= false)
                        SetFlyoutRowEnabled(sr, parentEnabled)
                    end
                end
                if hideTipRow then
                    local ht = EasyFind.db.hideTooltips
                    hideTipRow:SetChecked(ht and ht.collections == true)
                    SetFlyoutRowEnabled(hideTipRow, parentEnabled)
                end
                if toggleAllRow then
                    SetFlyoutRowEnabled(toggleAllRow, parentEnabled)
                end
            end
            row.SyncFlyoutSubChecks = SyncSubChecks
            popup._efSync = SyncSubChecks

            if toggleAllOffset == 1 then
                toggleAllRow = CreateFrame("Button", nil, popup)
                toggleAllRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                toggleAllRow:SetPoint("TOPLEFT", popup, "TOPLEFT", SUB_PAD, -SUB_PAD)
                local toggleAllLabel = toggleAllRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                toggleAllLabel:SetPoint("LEFT", 8, 0)
                toggleAllLabel:SetText(L["FILTER_TOGGLE_ALL"])
                toggleAllRow._label = toggleAllLabel
                InstallMenuRowHighlight(toggleAllRow)
                toggleAllRow:SetScript("OnClick", function()
                    local allUnchecked = true
                    for _, sub in ipairs(opt.flyoutSubFilters) do
                        local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        if target[sub.key] ~= false then
                            allUnchecked = false
                            break
                        end
                    end
                    for _, sub in ipairs(opt.flyoutSubFilters) do
                        local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        target[sub.key] = allUnchecked
                    end
                    SyncSubChecks()
                    Filters.ResyncShownOptionPopups()
                    if searchEditBox:GetText() ~= "" then
                        Search:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)
            end

            -- Show on hover of either the parent row or the arrow.
            -- Hide when the cursor leaves both the row and the popup,
            -- with a small grace timer so brief gaps between them don't
            -- snap the menu shut.
            local function PositionPopup()
                Utils.OpenFlyoutBeside(popup, row, 4)
            end
            local hover = Utils.AttachHoverPopup(row, popup, {
                extraGuards = {
                    function() return popup._appearanceSetOptionsPopup end,
                    function() return popup._mountOptionsPopup end,
                    function() return popup._mountSourcePopup end,
                    function() return popup._heirloomOptionsPopup end,
                    function() return popup._heirloomSourcePopup end,
                },
                onShow = function()
                    SetActiveFlyout(popup)
                    SyncSubChecks()
                    popup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                    PositionPopup()
                    popup:Show()
                end,
            })

            -- Need to call ShowPopup from row's OnEnter (set lower in
            -- the loop), so stash it on the row for the OnClick handler.
            row.ShowFlyoutPopup = hover.Show
            row.ScheduleHideFlyoutPopup = hover.ScheduleHide
            -- Close when the parent dropdown closes so the popup can't
            -- linger over other Search.
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end

        -- Radio + checkbox flyout. radio.options renders radio rows that
        -- write radio.dbKey; radio.checkboxes renders independent toggles
        -- below. Either section may be omitted (e.g. Abilities has only a
        -- "Hide Passives" checkbox; Currencies has only the radio set).
        if opt.flyoutRadio and not opt.flyoutSubFilters then
            local radio = opt.flyoutRadio
            local SUB_POPUP_WIDTH = 200
            local SUB_ROW_H = 22
            local SUB_PAD = 6
            local options = radio.options or {}
            local checkboxes = radio.checkboxes or {}
            local hasSeparator = #options > 0 and #checkboxes > 0
            local SEPARATOR_H = hasSeparator and 8 or 0

            local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            popup:SetFrameStrata("TOOLTIP")
            StylePopup(popup)
            popup:EnableMouse(true)
            popup:Hide()
            row.flyoutPopup = popup
            dropdownGuardFrames[#dropdownGuardFrames + 1] = popup
            dropdown.flyoutPopups = dropdown.flyoutPopups or {}
            dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = popup

            popup:HookScript("OnShow", function(self)
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end)
            popup:HookScript("OnHide", function(self)
                self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
                ClearActiveFlyout(self)
            end)
            popup:HookScript("OnEvent", function(self, event)
                if event ~= "GLOBAL_MOUSE_DOWN" then return end
                if not Filters.IsMouseInFilterChain() then self:Hide() end
            end)

            local radioRows = {}
            for ri, optionDef in ipairs(options) do
                local rRow = CreateFrame("Button", nil, popup)
                rRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                rRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(SUB_PAD + (ri - 1) * SUB_ROW_H))

                local bullet = rRow:CreateTexture(nil, "ARTWORK")
                bullet:SetAtlas("common-dropdown-tickradial")
                bullet:SetSize(14, 14)
                bullet:SetPoint("LEFT", 4, 0)

                local tick = rRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-radialtick-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = rRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", bullet, "RIGHT", 6, 0)
                lbl:SetText(optionDef.label)

                InstallMenuRowHighlight(rRow)

                rRow.tick = tick
                rRow.value = optionDef.value
                rRow._label = lbl
                rRow._dimTex = { bullet, tick }
                rRow:SetScript("OnClick", function(self)
                    EasyFind.db[radio.dbKey] = self.value
                    for _, otherRow in ipairs(radioRows) do
                        otherRow.tick:SetShown(otherRow.value == self.value)
                    end
                    if radio.onChange then radio.onChange(self.value) end
                    if searchEditBox:GetText() ~= "" then
                        Search:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)

                radioRows[ri] = rRow
            end

            local checkboxRows = {}
            local cbStartY = SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H
            for ci, cbDef in ipairs(checkboxes) do
                local cRow = CreateFrame("Button", nil, popup)
                cRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                cRow:SetPoint("TOPLEFT", popup, "TOPLEFT",
                    SUB_PAD, -(cbStartY + (ci - 1) * SUB_ROW_H))

                local box = cRow:CreateTexture(nil, "ARTWORK")
                box:SetAtlas("common-dropdown-ticksquare")
                box:SetSize(12, 12)
                box:SetPoint("LEFT", 5, 0)

                local tick = cRow:CreateTexture(nil, "OVERLAY")
                tick:SetAtlas("common-dropdown-icon-checkmark-yellow")
                tick:SetSize(14, 14)
                tick:SetPoint("LEFT", 4, 0)
                tick:Hide()

                local lbl = cRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                lbl:SetPoint("LEFT", box, "RIGHT", 6, 0)
                lbl:SetText(cbDef.label)

                InstallMenuRowHighlight(cRow)

                cRow.tick = tick
                cRow.dbKey = cbDef.dbKey
                cRow.onChange = cbDef.onChange
                cRow._label = lbl
                cRow._dimTex = { box, tick }
                cRow.resolveDbPath = function()
                    return ns.ResolveDbKey(cbDef.dbKey)
                end
                cRow:SetScript("OnClick", function(self)
                    local tbl, leaf = self.resolveDbPath()
                    local next = not tbl[leaf]
                    tbl[leaf] = next
                    self.tick:SetShown(next)
                    if self.onChange then self.onChange(next) end
                    if searchEditBox:GetText() ~= "" then
                        Search:OnSearchTextChanged(searchEditBox:GetText())
                    end
                    KeepSearchEditBoxUnfocused()
                end)
                checkboxRows[ci] = cRow
            end

            popup:SetSize(SUB_POPUP_WIDTH,
                SUB_PAD * 2 + #options * SUB_ROW_H + SEPARATOR_H + #checkboxes * SUB_ROW_H)

            if hasSeparator then
                local sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetColorTexture(1, 1, 1, 0.12)
                sep:SetHeight(1)
                sep:SetPoint("LEFT", popup, "LEFT", SUB_PAD, 0)
                sep:SetPoint("RIGHT", popup, "RIGHT", -SUB_PAD, 0)
                sep:SetPoint("TOP", popup, "TOP", 0,
                    -(SUB_PAD + #options * SUB_ROW_H + SEPARATOR_H * 0.5))
            end

            local function SyncRadio()
                local parentEnabled = EasyFind.db.uiSearchFilters[opt.key] ~= false
                if radio.dbKey then
                    local cur = EasyFind.db[radio.dbKey]
                    for _, rRow in ipairs(radioRows) do
                        rRow.tick:SetShown(rRow.value == cur)
                    end
                end
                for _, cRow in ipairs(checkboxRows) do
                    local tbl, leaf = cRow.resolveDbPath()
                    cRow.tick:SetShown(tbl[leaf] and true or false)
                end
                for _, rRow in ipairs(radioRows) do SetFlyoutRowEnabled(rRow, parentEnabled) end
                for _, cRow in ipairs(checkboxRows) do SetFlyoutRowEnabled(cRow, parentEnabled) end
            end
            row.SyncFlyoutSubChecks = SyncRadio
            popup._efSync = SyncRadio

            local function PositionPopup()
                Utils.OpenFlyoutBeside(popup, row, 4)
            end
            local hover = Utils.AttachHoverPopup(row, popup, {
                onShow = function()
                    SetActiveFlyout(popup)
                    SyncRadio()
                    popup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                    PositionPopup()
                    popup:Show()
                end,
            })
            row.ShowFlyoutPopup = hover.Show
            row.ScheduleHideFlyoutPopup = hover.ScheduleHide
            dropdown:HookScript("OnHide", function() popup:Hide() end)
        end


        -- Loot/Gear: side popup with difficulty + spec selector + iLvl
        -- upgrades checkbox. Opens to the right of the Gear filter row.
        if opt.key == "loot" then
            Search:AttachGearOptionsFlyout(row, dropdown, {
                rowHeight = ROW_HEIGHT,
                checkSize = CHECK_SIZE,
                StylePopup = StylePopup,
                CreateRadioTexture = CreateRadioTexture,
                AddPopupKeyboardNav = AddPopupKeyboardNav,
                SetActiveFlyout = SetActiveFlyout,
                ClearActiveFlyout = ClearActiveFlyout,
                dropdownGuardFrames = dropdownGuardFrames,
                searchEditBox = searchEditBox,
            })
        end

        InstallMenuRowHighlight(row)

        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db.uiSearchFilters
            filters[opt.key] = self:GetChecked()
            if self.SyncFlyoutSubChecks then self.SyncFlyoutSubChecks() end
            Filters.ResyncShownOptionPopups()
            if self.updateLootToggle then self.updateLootToggle() end
            LayoutDropdown()
            if searchEditBox:GetText() ~= "" then
                Search:OnSearchTextChanged(searchEditBox:GetText())
            end
            KeepSearchEditBoxUnfocused()
        end)

        checkRows[opt.key] = row
        checkRowsByIndex[i] = row
    end

    -- Layout: positions all rows including map sub-rows, adjusts dropdown height
    local SUB_INDENT = 24
    local dropdownNavRows = {}  -- ordered list of navigable rows (rebuilt on layout)
    local dropdownFocus = 0
    local dropdownFocusRow

    local function SetDropdownFocus(idx)
        if dropdownFocusRow and dropdownFocusRow.SetMenuHighlightFocused then
            dropdownFocusRow:SetMenuHighlightFocused(false)
        end
        dropdownFocus = idx
        local target = dropdownNavRows[idx]
        if target then
            if target.SetMenuHighlightFocused then
                target:SetMenuHighlightFocused(true)
            end
            dropdownFocusRow = target
        else
            dropdownFocusRow = nil
        end
    end

    local function ClearDropdownFocus()
        dropdownFocus = 0
        if dropdownFocusRow and dropdownFocusRow.SetMenuHighlightFocused then
            dropdownFocusRow:SetMenuHighlightFocused(false)
        end
        dropdownFocusRow = nil
    end

    function LayoutDropdown()
        local savedFocus = dropdownFocus
        wipe(dropdownNavRows)
        if dropdownFocusRow and dropdownFocusRow.SetMenuHighlightFocused then
            dropdownFocusRow:SetMenuHighlightFocused(false)
        end
        dropdownFocusRow = nil
        local filters = EasyFind.db.uiSearchFilters
        local y = -PADDING_TOP
        uncheckRow:ClearAllPoints()
        uncheckRow:SetPoint("TOPLEFT", 8, y)
        dropdownNavRows[#dropdownNavRows + 1] = uncheckRow
        y = y - ROW_HEIGHT
        for i, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRowsByIndex[i]
            local parentVisible = (not opt.parentKey) or (filters[opt.parentKey] ~= false)
            if not parentVisible then
                row:Hide()
            else
                local rowIndent = opt.parentKey and SUB_INDENT or 0
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 8 + rowIndent, y)
                row:Show()
                dropdownNavRows[#dropdownNavRows + 1] = row
                y = y - ROW_HEIGHT
            end
        end
        dropdown:SetSize(DROPDOWN_WIDTH, -y + PADDING_BOTTOM)
        Utils.RefreshMenuRowHighlights(dropdown, dropdownNavRows)
        if savedFocus > 0 and dropdown:IsKeyboardEnabled() then
            if savedFocus > #dropdownNavRows then savedFocus = #dropdownNavRows end
            SetDropdownFocus(savedFocus)
        end
    end

    Utils.SafeCallMethod(dropdown, "EnableKeyboard", false)
    Utils.SafeCallMethod(dropdown, "SetPropagateKeyboardInput", false)

    dropdown:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        if key == "DOWN" then
            Search:GetSearchFrame().StartKeyRepeat(key, function()
                local next = dropdownFocus + 1
                if next > #dropdownNavRows then next = 1 end
                SetDropdownFocus(next)
            end)
        elseif key == "UP" then
            if dropdownFocus <= 1 then
                self._escapedViaKeyboard = true
                self:Hide()
                return
            end
            Search:GetSearchFrame().StartKeyRepeat(key, function()
                local prev = dropdownFocus - 1
                if prev < 1 then prev = 1 end
                SetDropdownFocus(prev)
            end)
        elseif key == "ENTER" then
            local target = dropdownNavRows[dropdownFocus]
            if target and target.Click then
                target:Click()
            end
        elseif key == "ESCAPE" then
            self._escapedViaKeyboard = true
            -- Route through HandleEscape so flyouts/popups close together
            -- and the editbox refocuses, instead of just self:Hide() which
            -- only hits the main dropdown.
            Search:HandleEscape()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)
    dropdown:SetScript("OnKeyUp", function(_, key)
        if Search:GetSearchFrame().IsRepeatKey(key) then Search:GetSearchFrame().StopKeyRepeat() end
    end)

    -- (keyboard OnShow/OnHide hooks moved after SetScript calls below)

    -- Uncheck All: toggles all checkboxes off, or all back on if already all unchecked
    uncheckRow:SetScript("OnClick", function()
        local filters = EasyFind.db.uiSearchFilters
        local allUnchecked = true
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            if target[key] ~= false then allUnchecked = false end
        end)
        local newState = allUnchecked
        ForEachFilterKey(function(key, opt)
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            target[key] = newState
        end)
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            local row = checkRows[opt.key]
            if row then
                row:SetChecked(newState)
                if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
            end
        end
        local lootRow = checkRows["loot"]
        if lootRow and lootRow.updateLootToggle then lootRow.updateLootToggle() end
        Filters.ResyncShownOptionPopups()
        LayoutDropdown()
        if searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
        KeepSearchEditBoxUnfocused()
    end)

    LayoutDropdown()

    dropdown:HookScript("OnShow", function(self)
        if ns.RegisterAddonFontsIn then
            ns.RegisterAddonFontsIn(self)
            for i = 1, #dropdownGuardFrames do
                ns.RegisterAddonFontsIn(dropdownGuardFrames[i])
            end
        end
    end)
    dropdown:SetScript("OnShow", function(self)
        local filters = EasyFind.db.uiSearchFilters
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
            if row.updateLootToggle then row.updateLootToggle() end
            if row.SyncFlyoutSubChecks then row.SyncFlyoutSubChecks() end
        end
        LayoutDropdown()
    end)

    dropdown:SetScript("OnHide", function() end)

    -- Keyboard: enable when opened via Enter on filter button
    dropdown:HookScript("OnShow", function(self)
        -- Sync appearance set filters from the default Search. Only repopulate
        -- if something actually changed, so opening the dropdown is cheap.
        if ns.Database and ns.Database.SyncTransmogSetFiltersFromUI then
            local db = EasyFind.db
            local beforeClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local beforeCollected = db.appearanceSetCollected
            local beforeNotCollected = db.appearanceSetNotCollected
            local beforePvE = db.appearanceSetPvE
            local beforePvP = db.appearanceSetPvP

            ns.Database:SyncTransmogSetFiltersFromUI()

            local afterClassID = type(db.appearanceSetClass) == "table"
                and db.appearanceSetClass.classID or db.appearanceSetClass
            local changed = beforeClassID ~= afterClassID
                or beforeCollected ~= db.appearanceSetCollected
                or beforeNotCollected ~= db.appearanceSetNotCollected
                or beforePvE ~= db.appearanceSetPvE
                or beforePvP ~= db.appearanceSetPvP
            if changed and ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("transmogSets")
                if searchEditBox and searchEditBox:GetText() ~= "" then
                    Search:OnSearchTextChanged(searchEditBox:GetText())
                end
            end

            if Search._SyncAppearanceSetOptions then
                Search._SyncAppearanceSetOptions()
            end
        end
        if Search._SyncMountOptions then
            Search._SyncMountOptions()
        end
        local filterBtn = Search:GetSearchFrame().filterBtn
        dropdownKeyboardMode = filterBtn and filterBtn.keyboardFocused or false
        Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", false)
        Utils.SafeCallMethod(self, "EnableKeyboard", true)
        if dropdownKeyboardMode then
            SetDropdownFocus(1)
        else
            ClearDropdownFocus()
        end
    end)

    -- Keyboard: cleanup on hide
    dropdown:HookScript("OnHide", function(self)
        ClearDropdownFocus()
        Utils.SafeCallMethod(self, "EnableKeyboard", false)
        local escapedViaKeyboard = self._escapedViaKeyboard
        self._escapedViaKeyboard = nil
        if escapedViaKeyboard and not Search._escClosingMenus then
            dropdownKeyboardMode = false
            Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", true)
        else
            dropdownKeyboardMode = false
            if Search:GetSearchFrame().ClearToolbarFocus then Search:GetSearchFrame().ClearToolbarFocus() end
            Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", false)
            if Search:GetSearchFrame().filterBtn then
                local fb = Search:GetSearchFrame().filterBtn
                fb.keyboardFocused = nil
                -- Don't wipe the hover highlight if the cursor is still on
                -- the filter button (the common case when clicking the
                -- button to toggle the dropdown closed). Otherwise the
                -- outline disappears and OnEnter doesn't re-fire until
                -- the cursor leaves and comes back.
                if not fb:IsMouseOver() then
                    if fb.btnBg then fb.btnBg:Hide() end
                    if fb.ringDisc then fb.ringDisc:Hide() end
                    if fb.ringInner then fb.ringInner:Hide() end
                    if fb.UnlockHighlight then fb:UnlockHighlight() end
                end
            end
            -- Skip the ClearFocus when HandleEscape is driving the close,
            -- it intentionally refocuses the editbox so the user can keep
            -- typing. ClearFocus + same-frame SetFocus can lose to internal
            -- editbox state, hence the flag instead of relying on order.
            if Search:GetSearchFrame().editBox and not Search:GetSearchFrame().editBox:IsMouseOver()
               and not Search._escClosingMenus then
                Search:GetSearchFrame().editBox:ClearFocus()
            end
        end
    end)

    -- Close when clicking outside (but not when interacting with sub-filter popups).
    -- Both LeftButton AND RightButton trigger close: without the right-button
    -- check, right-clicking outside dismisses the search bar (whose handler
    -- listens for GLOBAL_MOUSE_DOWN regardless of button) but leaves the
    -- filter dropdown stuck open.
    -- One-frame grace: an in-menu selection hides its sub-popup synchronously, so
    -- without this the poll would see the guard gone + cursor over empty space and
    -- close the whole menu. Requiring "outside" for two consecutive polls keeps the
    -- menu open through that frame while a genuine outside click still closes it.
    Utils.SafeOnUpdate(dropdown, function(self)
        if not self:IsShown() then self._mouseWasInside = nil; return end
        local inside = Filters.IsMouseInFilterChain()
        if not inside and not self._mouseWasInside
           and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
            self:Hide()
        end
        self._mouseWasInside = inside
    end)

    toggleBtn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            local barScale = EasyFind.db.uiSearchScale or 1.0
            dropdown:SetScale(barScale)
            local scale = anchorFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
            local right = anchorFrame:GetRight() * scale
            dropdown:ClearAllPoints()
            if EasyFind.db.uiResultsAbove then
                -- Results grow upward, so open the filter menu upward too: pin
                -- its bottom edge to the bar's top instead of its top to the bottom.
                local top = anchorFrame:GetTop() * scale
                dropdown:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", right, top)
            else
                local bottom = anchorFrame:GetBottom() * scale
                dropdown:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
            end
            dropdown:Show()
            KeepSearchEditBoxUnfocused()
        end
    end)

    Search:GetSearchFrame().filterDropdown = dropdown
end
