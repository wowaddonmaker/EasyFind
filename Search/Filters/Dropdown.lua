local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs, pairs = Utils.ipairs, Utils.pairs
local select = Utils.select
local CreateFrame = CreateFrame
local UIParent = UIParent
local wipe = wipe
local UI_FILTER_OPTIONS = Filters.UI_FILTER_OPTIONS

local SetFlyoutRowEnabled = Utils.SetFlyoutRowEnabled

function Filters:RerunActiveSearch()
    local typed = Search.GetTypedQuery and Search:GetTypedQuery() or ""
    if typed ~= "" then
        Search:OnSearchTextChanged(typed)
    end
end

-- Refresh one or more dynamic categories, then re-run the active search.
function Filters:ApplyFilterSelection(...)
    if ns.Database and ns.Database.RefreshDynamicCategory then
        for i = 1, select("#", ...) do
            ns.Database:RefreshDynamicCategory((select(i, ...)))
        end
    end
    self:RerunActiveSearch()
end

function Filters:CreateUIFilterDropdown(toggleBtn, anchorFrame, searchEditBox)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    -- Single source of truth for which side-flyout (sub-filters / radio /
    -- loot options) is currently visible. Any popup that opens hides
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
    dropdown:SetFrameStrata("DIALOG")
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
    ns.SetRoundedRectRingShown(dropdown, EasyFind.db.windowBorder ~= false)
    -- Row labels follow the theme's main text color (they were fixed
    -- white, which broke on light fills and ignored theme tinting).
    -- Runs on every open AND from RestyleShownMenuPanels when the theme
    -- flips while the menu is open.
    local ChevRestColor = Utils.ChevronRestColor
    local ChevHoverColor = Utils.ChevronHoverColor

    local function RecolorFilterRowLabels(self)
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        local leaf = theme and theme.leafColor
        if not leaf then return end
        local children = { self:GetChildren() }
        for i = 1, #children do
            local child = children[i]
            -- Covers filter rows (optKey) and the Toggle All row, which
            -- opts in via its label field.
            if child.label then
                child.label:SetShadowColor(0, 0, 0, 0)
                -- Disabled rows keep their dim gray (SetFlyoutRowEnabled
                -- owns that state); painting theme text over them made
                -- disabled and enabled read identically.
                if child._efRowEnabled ~= false then
                    child.label:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
                end
            end
            if child.flyoutChevron then
                child.flyoutChevron:SetVertexColor(ChevRestColor())
            end
        end
    end
    -- NOTE: no OnShow HookScript here; the canonical SetScript("OnShow")
    -- further down would wipe it. The refill runs inside that handler.
    dropdown._efOnThemeRestyle = RecolorFilterRowLabels

    local ICON_SIZE = 14

    local RADIO_SIZE = 14
    local RADIO_OFF_TEX = ns.RADIO_OFF_TEX
    local RADIO_ON_TEX = ns.RADIO_ON_TEX

    local function InstallMenuRowHighlight(row)
        Utils.InstallMenuRowHighlight(row)
    end

    local function StylePopup(frame)
        ns.StyleMenuPanel(frame)
        -- Filter-menu surfaces follow the window border setting; dialogs
        -- and other StyleMenuPanel users keep their ring regardless.
        ns.SetRoundedRectRingShown(frame, EasyFind.db.windowBorder ~= false)
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
    uncheckLabel:SetShadowColor(0, 0, 0, 0)
    -- The recolor loop matches rows via optKey; this special row opts in
    -- through label alone.
    uncheckRow.label = uncheckLabel
    InstallMenuRowHighlight(uncheckRow)

    local checkRows = {}
    local checkRowsByIndex = {}
    local LayoutDropdown  -- forward declaration
    local dropdownKeyboardMode = false

    -- Reusable keyboard nav for popup menus (diff popup, spec popup, class flyout).
    -- Uses a single dropdownKeyboardMode flag: when true, any popup hiding returns
    -- keyboard to the dropdown. No parent tracking needed.
    local function AddPopupKeyboardNav(popup, getRows, returnTo)
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
            elseif key == "TAB" or key == "RIGHT" then
                -- Descend into the focused row's own flyout when it has one;
                -- Tab on a plain row backs out to the parent menu (RIGHT
                -- stays put, mirroring standard menu arrows).
                local target = rows[popupFocus]
                if target and target.ShowFlyoutPopup then
                    target.ShowFlyoutPopup()
                elseif key == "TAB" then
                    self:Hide()
                end
            elseif key == "LEFT" then
                self:Hide()
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
                if returnTo then Utils.SafeCallMethod(returnTo, "EnableKeyboard", false) end
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
            if dropdownKeyboardMode then
                local ret = returnTo or dropdown
                if ret:IsShown() then
                    Utils.SafeCallMethod(ret, "EnableKeyboard", true)
                end
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

        Utils.SetCheckboxTextures(row, CHECK_SIZE)

        -- Category icon sits between the checkbox and label so the row
        -- reads left-to-right as [check][icon][name]. Supports atlas,
        -- raw fileID, or fileID + texCoords for sprite-sheet sub-icons.
        local icon
        if opt.iconAtlas or opt.iconTex then
            icon = row:CreateTexture(nil, "ARTWORK")
            ns.SizeIconAspect(icon, ICON_SIZE, opt.iconAspect)
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
            Utils.SetChevronTexture(chev)
            chev:SetSize(ICON_SIZE - 2, ICON_SIZE - 2)
            chev:SetPoint("RIGHT", -4, 0)
            row.flyoutChevron = chev
            label:SetPoint("RIGHT", chev, "LEFT", -4, 0)
            label:SetWordWrap(false)
            label:SetJustifyH("LEFT")
            row:HookScript("OnEnter", function() chev:SetVertexColor(ChevHoverColor()) end)
            row:HookScript("OnLeave", function() chev:SetVertexColor(ChevRestColor()) end)
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
            Filters.AttachOutsideClickClose(popup, { onHide = ClearActiveFlyout })

            local subRows = {}
            local nestedFlyouts = {}
            -- Collections and Map carry many sub-filters; give their flyouts
            -- the same Toggle All row the main menu has (created below).
            local toggleAllRow
            local toggleAllOffset = (opt.key == "collections" or opt.key == "map") and 1 or 0
            for si, sub in ipairs(opt.flyoutSubFilters) do
                local subRow = CreateFrame("CheckButton", nil, popup)
                subRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                subRow:SetHitRectInsets(0, 0, 0, 0)
                subRow:SetPoint("TOPLEFT", popup, "TOPLEFT", SUB_PAD, -(SUB_PAD + (si - 1 + toggleAllOffset) * SUB_ROW_H))

                Utils.SetCheckboxTextures(subRow, CHK)

                local subIcon
                if sub.iconAtlas or sub.iconTex then
                    subIcon = subRow:CreateTexture(nil, "ARTWORK")
                    ns.SizeIconAspect(subIcon, SUB_ICON, sub.iconAspect)
                    subIcon:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
                    if sub.iconAtlas then
                        subIcon:SetAtlas(sub.iconAtlas)
                    else
                        subIcon:SetTexture(sub.iconTex)
                        if sub.iconCoords then
                            subIcon:SetTexCoord(sub.iconCoords[1], sub.iconCoords[2],
                                                sub.iconCoords[3], sub.iconCoords[4])
                        end
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

                if sub.hasOptions or sub.subFilters then
                    local subChev = subRow:CreateTexture(nil, "OVERLAY")
                    Utils.SetChevronTexture(subChev)
                    subChev:SetSize(SUB_ICON - 2, SUB_ICON - 2)
                    subChev:SetPoint("RIGHT", -4, 0)
                    subLabel:SetPoint("RIGHT", subChev, "LEFT", -4, 0)
                    subLabel:SetWordWrap(false)
                    subLabel:SetJustifyH("LEFT")
                    subRow:HookScript("OnEnter", function() subChev:SetVertexColor(ChevHoverColor()) end)
                    subRow:HookScript("OnLeave", function() subChev:SetVertexColor(ChevRestColor()) end)
                    subRow._chev = subChev
                end

                InstallMenuRowHighlight(subRow)

                subRow:SetScript("OnClick", function(self)
                    local target = sub.dbTable and EasyFind.db[sub.dbTable]
                                   or EasyFind.db.uiSearchFilters
                    target[sub.key] = self:GetChecked()
                    Filters.ResyncShownOptionPopups()
                    Filters:RerunActiveSearch()
                    KeepSearchEditBoxUnfocused()
                end)

                subRows[si] = subRow
                subRows[sub.key] = subRow

                -- Appearances: Items / Sets chooser (each a checkbox toggle with
                -- its own class / slot / filter options flyout) opens to the
                -- right of this sub-row on hover.
                if sub.hasOptions and sub.key == "appearances" then
                    local optionsPopup, syncOptions, appBranchPopups = Search:BuildAppearanceOptionsPopup(
                        StylePopup, CHECK_SIZE, dropdownGuardFrames)
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
                        StylePopup, CHECK_SIZE)
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
                        StylePopup, CHECK_SIZE, dropdownGuardFrames)
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

                -- General catalog: crafting-quality-tier radio + item-type
                -- checkboxes, opening to the right of the catalog sub-row.
                if sub.hasOptions and sub.key == "catalog" then
                    local optionsPopup, syncOptions, qualityPopup = Search:BuildCatalogOptionsPopup(
                        StylePopup, CHECK_SIZE, dropdownGuardFrames)
                    optionsPopup._efSync = syncOptions
                    optionsPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
                    optionsPopup._owningRow = subRow
                    popup._catalogOptionsPopup = optionsPopup
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = optionsPopup

                    Utils.AttachHoverPopup(subRow, optionsPopup, {
                        extraGuards = { qualityPopup },
                        onShow = function()
                            syncOptions()
                            optionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
                            Utils.OpenFlyoutBeside(optionsPopup, subRow, 4)
                            optionsPopup:Show()
                        end,
                    })

                    popup:HookScript("OnHide", function() optionsPopup:Hide() end)
                    dropdown:HookScript("OnHide", function()
                        optionsPopup:Hide()
                        qualityPopup:Hide()
                    end)
                end

                -- Generic nested flyout: a sub-filter carrying its own child
                -- checkboxes (Instances -> Raids/Dungeons/Delves, Travel ->
                -- Flight Paths/Boats/Portals) opens them beside the sub-row.
                -- Children gray out while their sub-filter is unchecked.
                if sub.subFilters then
                    local nested = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
                    nested:SetFrameStrata("TOOLTIP")
                    StylePopup(nested)
                    nested:EnableMouse(true)
                    nested:Hide()
                    nested:SetFrameLevel(popup:GetFrameLevel() + 10)
                    nested._owningRow = subRow
                    dropdownGuardFrames[#dropdownGuardFrames + 1] = nested
                    dropdown.flyoutPopups[#dropdown.flyoutPopups + 1] = nested
                    Filters.AttachOutsideClickClose(nested)

                    -- Same-level Toggle All at the top (Services and the
                    -- other nested menus): flips ONLY these child keys,
                    -- never anything above or below this level.
                    local nestedToggleAll = CreateFrame("Button", nil, nested)
                    nestedToggleAll:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                    nestedToggleAll:SetPoint("TOPLEFT", nested, "TOPLEFT", SUB_PAD, -SUB_PAD)
                    local nestedToggleLabel = nestedToggleAll:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                    nestedToggleLabel:SetPoint("LEFT", nestedToggleAll, "LEFT", 8, 0)
                    nestedToggleLabel:SetText(L["FILTER_TOGGLE_ALL"])
                    nestedToggleAll._label = nestedToggleLabel
                    InstallMenuRowHighlight(nestedToggleAll)

                    local childRows = {}
                    for ci, child in ipairs(sub.subFilters) do
                        local childRow = CreateFrame("CheckButton", nil, nested)
                        childRow:SetSize(SUB_POPUP_WIDTH - SUB_PAD * 2, SUB_ROW_H)
                        childRow:SetHitRectInsets(0, 0, 0, 0)
                        childRow:SetPoint("TOPLEFT", nested, "TOPLEFT", SUB_PAD, -(SUB_PAD + SUB_ROW_H + (ci - 1) * SUB_ROW_H))
                        Utils.SetCheckboxTextures(childRow, CHK)
                        local childLabel = childRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                        childLabel:SetPoint("LEFT", childRow:GetNormalTexture(), "RIGHT", 4, 0)
                        childLabel:SetText(child.label)
                        childRow._label = childLabel
                        InstallMenuRowHighlight(childRow)
                        childRow:SetScript("OnClick", function(self)
                            local target = child.dbTable and EasyFind.db[child.dbTable]
                                           or EasyFind.db.uiSearchFilters
                            target[child.key] = self:GetChecked()
                            Filters.ResyncShownOptionPopups()
                            Filters:RerunActiveSearch()
                            KeepSearchEditBoxUnfocused()
                        end)
                        childRows[ci] = childRow
                        childRows[child.key] = childRow
                    end

                    local function SyncChildChecks()
                        local subTarget = sub.dbTable and EasyFind.db[sub.dbTable]
                                       or EasyFind.db.uiSearchFilters
                        local subOn = subTarget[sub.key] ~= false
                        SetFlyoutRowEnabled(nestedToggleAll, subOn)
                        for _, child in ipairs(sub.subFilters) do
                            local cr = childRows[child.key]
                            local childTarget = child.dbTable and EasyFind.db[child.dbTable]
                                           or EasyFind.db.uiSearchFilters
                            cr:SetChecked(childTarget[child.key] ~= false)
                            SetFlyoutRowEnabled(cr, subOn)
                        end
                    end
                    nested._efSync = SyncChildChecks

                    nestedToggleAll:SetScript("OnClick", function()
                        local allUnchecked = true
                        for _, child in ipairs(sub.subFilters) do
                            local target = child.dbTable and EasyFind.db[child.dbTable]
                                           or EasyFind.db.uiSearchFilters
                            if target[child.key] ~= false then
                                allUnchecked = false
                                break
                            end
                        end
                        for _, child in ipairs(sub.subFilters) do
                            local target = child.dbTable and EasyFind.db[child.dbTable]
                                           or EasyFind.db.uiSearchFilters
                            target[child.key] = allUnchecked
                        end
                        SyncChildChecks()
                        Filters.ResyncShownOptionPopups()
                        Filters:RerunActiveSearch()
                        KeepSearchEditBoxUnfocused()
                    end)

                    local childContentW = Utils.FlyoutRowContentWidth(nestedToggleAll, 8)
                    for ci = 1, #sub.subFilters do
                        local w = Utils.FlyoutRowContentWidth(childRows[ci], CHK + 4)
                        if w > childContentW then childContentW = w end
                    end
                    local nestedW = Utils.FlyoutWidthFor(childContentW, SUB_PAD)
                    nestedToggleAll:SetWidth(nestedW - SUB_PAD * 2)
                    for ci = 1, #sub.subFilters do childRows[ci]:SetWidth(nestedW - SUB_PAD * 2) end
                    nested:SetSize(nestedW, SUB_PAD * 2 + (#sub.subFilters + 1) * SUB_ROW_H)

                    local nestedHover = Utils.AttachHoverPopup(subRow, nested, {
                        onShow = function()
                            SyncChildChecks()
                            nested:SetScale(EasyFind.db.uiSearchScale or 1.0)
                            Utils.OpenFlyoutBeside(nested, subRow, 4)
                            nested:Show()
                        end,
                    })
                    subRow.ShowFlyoutPopup = nestedHover.Show
                    AddPopupKeyboardNav(nested, function() return childRows end, popup)

                    popup["_nestedFlyout_" .. sub.key] = nested
                    nestedFlyouts[#nestedFlyouts + 1] = nested
                    popup:HookScript("OnHide", function() nested:Hide() end)
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
            for _, sub in ipairs(opt.flyoutSubFilters) do
                if sub.subFilters then
                    HookSiblingHide("_nestedFlyout_" .. sub.key, subRows[sub.key])
                end
            end
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
                Utils.SetCheckboxTextures(hideTipRow, CHK)
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
                    Filters:RerunActiveSearch()
                    KeepSearchEditBoxUnfocused()
                end)
            end

            -- Width hugs the widest row: checkbox + optional icon + label
            -- (+ chevron reserve on option rows). All labels are static at
            -- build time, so this runs once.
            local contentW = 0
            for si = 1, #opt.flyoutSubFilters do
                local w = Utils.FlyoutRowContentWidth(subRows[si], CHK + 4, SUB_ICON, SUB_ICON - 2)
                if w > contentW then contentW = w end
            end
            local hideTipW = Utils.FlyoutRowContentWidth(hideTipRow, CHK + 4)
            if hideTipW > contentW then contentW = hideTipW end
            local toggleAllW = Utils.FlyoutRowContentWidth(toggleAllRow, 8)
            if toggleAllW > contentW then contentW = toggleAllW end
            local popupW = Utils.FlyoutWidthFor(contentW, SUB_PAD)
            for si = 1, #opt.flyoutSubFilters do subRows[si]:SetWidth(popupW - SUB_PAD * 2) end
            if hideTipRow then hideTipRow:SetWidth(popupW - SUB_PAD * 2) end
            if toggleAllRow then toggleAllRow:SetWidth(popupW - SUB_PAD * 2) end
            popup:SetSize(popupW,
                SUB_PAD * 2 + (#opt.flyoutSubFilters + extraRows + toggleAllOffset) * SUB_ROW_H)

            AddPopupKeyboardNav(popup, function()
                local navRows = {}
                if toggleAllRow then navRows[#navRows + 1] = toggleAllRow end
                for si = 1, #opt.flyoutSubFilters do navRows[#navRows + 1] = subRows[si] end
                if hideTipRow then navRows[#navRows + 1] = hideTipRow end
                return navRows
            end)

            -- Show on hover of either the parent row or the arrow.
            -- Hide when the cursor leaves both the row and the popup,
            -- with a small grace timer so brief gaps between them don't
            -- snap the menu shut.
            local function PositionPopup()
                Utils.OpenFlyoutBeside(popup, row, 4)
            end
            local hoverGuards = {
                function() return popup._appearanceSetOptionsPopup end,
                function() return popup._mountOptionsPopup end,
                function() return popup._mountSourcePopup end,
                function() return popup._heirloomOptionsPopup end,
                function() return popup._heirloomSourcePopup end,
            }
            for ni = 1, #nestedFlyouts do
                local nested = nestedFlyouts[ni]
                hoverGuards[#hoverGuards + 1] = function() return nested end
            end
            local hover = Utils.AttachHoverPopup(row, popup, {
                extraGuards = hoverGuards,
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

            Filters.AttachOutsideClickClose(popup, { onHide = ClearActiveFlyout })

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
                    Filters:RerunActiveSearch()
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
                    Filters:RerunActiveSearch()
                    KeepSearchEditBoxUnfocused()
                end)
                checkboxRows[ci] = cRow
            end

            -- Width hugs the widest row: bullet/box inset + label. 24 =
            -- radio inset (4) + bullet (14) + label gap (6); the checkbox
            -- variant (5 + 12 + 6) sits within the same reserve.
            local contentW = 0
            for ri = 1, #radioRows do
                local w = Utils.FlyoutRowContentWidth(radioRows[ri], 24)
                if w > contentW then contentW = w end
            end
            for ci = 1, #checkboxRows do
                local w = Utils.FlyoutRowContentWidth(checkboxRows[ci], 24)
                if w > contentW then contentW = w end
            end
            local popupW = Utils.FlyoutWidthFor(contentW, SUB_PAD)
            for ri = 1, #radioRows do radioRows[ri]:SetWidth(popupW - SUB_PAD * 2) end
            for ci = 1, #checkboxRows do checkboxRows[ci]:SetWidth(popupW - SUB_PAD * 2) end
            popup:SetSize(popupW,
                SUB_PAD * 2 + #options * SUB_ROW_H + SEPARATOR_H + #checkboxes * SUB_ROW_H)

            if hasSeparator then
                local sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetColorTexture(1, 1, 1, 0.12)
                popup._efThemeSeps = popup._efThemeSeps or {}
                popup._efThemeSeps[#popup._efThemeSeps + 1] = sep
                ns.RetintMenuSeparators(popup)
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

            AddPopupKeyboardNav(popup, function()
                local navRows = {}
                for ri = 1, #radioRows do navRows[#navRows + 1] = radioRows[ri] end
                for ci = 1, #checkboxRows do navRows[#navRows + 1] = checkboxRows[ci] end
                return navRows
            end)

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


        -- Loot: side popup with difficulty + spec selector + iLvl
        -- upgrades checkbox. Opens to the right of the Loot filter row.
        if opt.key == "loot" then
            Search:AttachLootOptionsFlyout(row, dropdown, {
                rowHeight = ROW_HEIGHT,
                checkSize = CHECK_SIZE,
                StylePopup = StylePopup,
                CreateRadioTexture = CreateRadioTexture,
                AddPopupKeyboardNav = AddPopupKeyboardNav,
                SetActiveFlyout = SetActiveFlyout,
                ClearActiveFlyout = ClearActiveFlyout,
                dropdownGuardFrames = dropdownGuardFrames,
            })
        end

        -- Professions: per-profession checkboxes for this character's known
        -- professions; unchecking removes that profession at the provider.
        if opt.key == "professions" then
            Filters:AttachProfessionOptionsFlyout(row, dropdown, {
                rowHeight = ROW_HEIGHT,
                checkSize = CHECK_SIZE,
                StylePopup = StylePopup,
                CreateRadioTexture = CreateRadioTexture,
                AddPopupKeyboardNav = AddPopupKeyboardNav,
                SetActiveFlyout = SetActiveFlyout,
                ClearActiveFlyout = ClearActiveFlyout,
                dropdownGuardFrames = dropdownGuardFrames,
            })
        end

        -- Housing: side popup matching Blizzard's catalog Filter menu (Sort By,
        -- Dyeable/Bonus, Collection, Placeable, and the tag groups), built
        -- dynamically from C_HousingCatalog and synced with the catalog window.
        if opt.key == "housing" then
            Search:AttachHousingOptionsFlyout(row, dropdown, {
                rowHeight = ROW_HEIGHT,
                checkSize = CHECK_SIZE,
                StylePopup = StylePopup,
                CreateRadioTexture = CreateRadioTexture,
                AddPopupKeyboardNav = AddPopupKeyboardNav,
                SetActiveFlyout = SetActiveFlyout,
                ClearActiveFlyout = ClearActiveFlyout,
                dropdownGuardFrames = dropdownGuardFrames,
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
            Filters:RerunActiveSearch()
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
            -- available(): category rows whose content cannot exist for this
            -- character (a professions row with zero professions) hide rather
            -- than advertise results that can never appear.
            if not parentVisible or (opt.available and not opt.available()) then
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
        elseif key == "TAB" or key == "RIGHT" then
            local target = dropdownNavRows[dropdownFocus]
            if target and target.ShowFlyoutPopup then
                target.ShowFlyoutPopup()
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
        -- Toggle All is LEVEL-SCOPED: only the top-level rows flip here.
        -- Flyout sub-filters keep their own states (each flyout carries
        -- its own same-level Toggle All); the container key alone gates
        -- its children at query time.
        local filters = EasyFind.db.uiSearchFilters
        local allUnchecked = true
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            if target[opt.key] ~= false then
                allUnchecked = false
                break
            end
        end
        local newState = allUnchecked
        for _, opt in ipairs(UI_FILTER_OPTIONS) do
            local target = opt.dbTable and EasyFind.db[opt.dbTable] or filters
            target[opt.key] = newState
        end
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
        Filters:RerunActiveSearch()
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
        -- Canonical OnShow owner: this SetScript WIPES the creation-time
        -- HookScripts (StyleMenuPanel's refill and the label recolor),
        -- which is why the MAIN dropdown alone stayed one theme behind
        -- while its flyout popups rethemed. All refill work must live
        -- HERE, pcall-isolated.
        pcall(ns.ApplyMenuOpacity, self)
        if Utils.RefreshMenuRowHighlights then
            pcall(Utils.RefreshMenuRowHighlights, self)
        end
        pcall(RecolorFilterRowLabels, self)
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
                Filters:RerunActiveSearch()
            end

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
        if escapedViaKeyboard and not Search:IsEscClosingMenus() then
            dropdownKeyboardMode = false
            -- Hand keys back to the nav frame only when it has a live nav
            -- context; a blind enable here is the stray that left the nav
            -- frame eating a fresh session's first keys.
            Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard",
                Search:GetSelectedIndex() > 0)
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
               and not Search:IsEscClosingMenus() then
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
