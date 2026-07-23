-- Loot options flyout (all internals say loot). The file keeps its original
-- name on purpose: renaming a shipped addon file breaks clients that update
-- mid-session, whose launch-time manifest still loads the old name and
-- cannot see a new one.
local _, ns = ...

local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs
local SetFlyoutRowEnabled = Utils.SetFlyoutRowEnabled
local CreateFrame = CreateFrame
local UIParent = UIParent

function Filters:AttachLootOptionsFlyout(row, dropdown, ctx)
    local ROW_HEIGHT = ctx.rowHeight
    local CHECK_SIZE = ctx.checkSize
    local StylePopup = ctx.StylePopup
    local AddPopupKeyboardNav = ctx.AddPopupKeyboardNav
    local SetActiveFlyout = ctx.SetActiveFlyout
    local ClearActiveFlyout = ctx.ClearActiveFlyout
    local dropdownGuardFrames = ctx.dropdownGuardFrames
    local LOOT_POPUP_WIDTH = 184
    local LOOT_POPUP_PAD = 8

    local function InstallMenuRowHighlight(target)
        Utils.InstallMenuRowHighlight(target)
    end

    local lootOptionsPopup = CreateFrame("Frame", "EasyFindLootOptionsPopup", UIParent, "BackdropTemplate")
    lootOptionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(lootOptionsPopup)
    lootOptionsPopup:EnableMouse(true)
    lootOptionsPopup:Hide()
    row.lootOptionsPopup = lootOptionsPopup
    dropdownGuardFrames[#dropdownGuardFrames + 1] = lootOptionsPopup

    local lootSubDefs = {
        { dbKey = "lootUpgradesOnly", label = L["FILTER_ILVL_UPGRADES_ONLY"] },
        { dbKey = "hideTooltips.loot", label = L["FILTER_HIDE_TOOLTIPS"] },
    }
    local lootSubRows = {}
    for si, sub in ipairs(lootSubDefs) do
        local subRow = CreateFrame("CheckButton", nil, lootOptionsPopup)
        subRow:SetSize(LOOT_POPUP_WIDTH - LOOT_POPUP_PAD * 2, ROW_HEIGHT)
        subRow:SetHitRectInsets(0, 0, 0, 0)

        Utils.SetCheckboxTextures(subRow, CHECK_SIZE)

        local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        subLabel:SetShadowColor(0, 0, 0, 0)
        subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
        subLabel:SetText(sub.label)
        subRow._label = subLabel

        InstallMenuRowHighlight(subRow)

        subRow.dbKey = sub.dbKey
        lootSubRows[si] = subRow

        local function resolveDbPath()
            return ns.ResolveDbKey(sub.dbKey)
        end

        subRow:SetScript("OnClick", function(self)
            local tbl, leaf = resolveDbPath()
            tbl[leaf] = self:GetChecked() and true or false
            Filters:RerunActiveSearch()
        end)
        subRow.resolveDbPath = resolveDbPath
    end

    -- Separator line between iLvl Upgrades checkbox and the
    -- difficulty/spec selectors.
    local lootSep = lootOptionsPopup:CreateTexture(nil, "ARTWORK")
    lootSep:SetHeight(1)
    lootSep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
    row.lootSep = lootSep

    -- Difficulty dropdown bar via the shared single-select template, so it is
    -- pixel- and width-identical to the class/spec selector below it and to the
    -- catalog quality bar.
    local DIFF_OPTIONS = {
        { value = "lfr",    label = _G["RAID_FINDER"] or "Raid Finder" },
        { value = "normal", label = _G["PLAYER_DIFFICULTY1"] or "Normal" },
        { value = "heroic", label = _G["PLAYER_DIFFICULTY2"] or "Heroic" },
        { value = "mythic", label = _G["PLAYER_DIFFICULTY6"] or "Mythic" },
    }

    local diffSel = Filters:BuildSelectDropdown({
        parent = lootOptionsPopup,
        name = "EasyFindDiffPopup",
        width = LOOT_POPUP_WIDTH - LOOT_POPUP_PAD * 2,
        options = DIFF_OPTIONS,
        getValue = function() return EasyFind.db.lootDifficulty or "normal" end,
        setValue = function(v) EasyFind.db.lootDifficulty = v end,
        formatLabel = function(_, optLabel) return optLabel or (_G["PLAYER_DIFFICULTY1"] or "Normal") end,
        onChange = function() Filters:ApplyFilterSelection("loot") end,
        stylePopup = StylePopup,
        guardFrames = dropdownGuardFrames,
        keyboardNav = AddPopupKeyboardNav,
    })
    local diffBtn = diffSel.button
    local diffPopup = diffSel.popup
    local diffPopupRows = diffSel.rows
    row.diffBtn = diffBtn
    row.diffPopup = diffPopup
    row.UpdateDiffButtons = diffSel.Refresh

    -- Not Filters:ApplyFilterSelection("loot"): SyncEJLootFilter must run
    -- between the category refresh and the re-search.
    local function ApplyFilterSelection()
        if ns.Database then
            if ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("loot")
            end
            ns.Database:SyncEJLootFilter()
        end
        Filters:RerunActiveSearch()
    end

    -- Global popup names: results navigation, the search bar's autoHide,
    -- and the filter dropdown's keyboard handling resolve them by name.
    local classSel = Filters:BuildClassSpecSelector({
        parent = lootOptionsPopup,
        width = ns.CLASS_SELECTOR_BTN_W,
        popupWidth = 180,
        flyoutWidth = 160,
        popupName = "EasyFindSpecPopup",
        flyoutName = "EasyFindSpecFlyout",
        hasSpec = true,
        stylePopup = StylePopup,
        guardFrames = dropdownGuardFrames,
        keyboardNav = AddPopupKeyboardNav,
        getScale = function() return EasyFind.db.uiSearchScale or 1.0 end,
        getFilter = function() return EasyFind.db.lootFilter end,
        setFilter = function(v) EasyFind.db.lootFilter = v end,
        onChange = ApplyFilterSelection,
    })
    local specSelectRow = classSel.button

    row.specSelectRow = specSelectRow
    row.specSelectLabel = specSelectRow._label
    row.lootSubRows = lootSubRows

    dropdown:HookScript("OnHide", function()
        classSel.flyout:Hide()
        classSel.popup:Hide()
    end)

    local gy = -LOOT_POPUP_PAD
    diffBtn:ClearAllPoints()
    diffBtn:SetPoint("TOPLEFT", lootOptionsPopup, "TOPLEFT", LOOT_POPUP_PAD, gy)
    gy = gy - 27 - 4
    specSelectRow:ClearAllPoints()
    specSelectRow:SetPoint("TOPLEFT", lootOptionsPopup, "TOPLEFT", LOOT_POPUP_PAD, gy)
    gy = gy - 27 - 6
    lootSep:ClearAllPoints()
    lootSep:SetPoint("LEFT", lootOptionsPopup, "LEFT", LOOT_POPUP_PAD, 0)
    lootSep:SetPoint("RIGHT", lootOptionsPopup, "RIGHT", -LOOT_POPUP_PAD, 0)
    lootSep:SetPoint("TOP", 0, gy)
    gy = gy - 6
    for _, sr in ipairs(lootSubRows) do
        sr:ClearAllPoints()
        sr:SetPoint("TOPLEFT", lootOptionsPopup, "TOPLEFT", LOOT_POPUP_PAD, gy)
        gy = gy - ROW_HEIGHT
    end
    local contentW = 0
    for i = 1, #lootSubRows do
        local w = Utils.FlyoutRowContentWidth(lootSubRows[i], CHECK_SIZE + 4)
        if w > contentW then contentW = w end
    end
    -- The difficulty button must fit its widest possible selection:
    -- left text inset + widest difficulty name + gap + arrow + inset.
    local diffBtnW = 14 + Utils.MaxRowLabelWidth(diffPopupRows) + 2 + 22 + 10
    if diffBtnW > contentW then contentW = diffBtnW end
    -- The class/spec selector shares the bar width, so its designed width is a
    -- floor. Both bars then get popupW - pad, so they render identically wide
    -- (the old code pinned the selector to CLASS_SELECTOR_BTN_W and let the
    -- difficulty button stretch, so the two never matched).
    if ns.CLASS_SELECTOR_BTN_W > contentW then contentW = ns.CLASS_SELECTOR_BTN_W end
    local popupW = Utils.FlyoutWidthFor(contentW, LOOT_POPUP_PAD)
    for i = 1, #lootSubRows do lootSubRows[i]:SetWidth(popupW - LOOT_POPUP_PAD * 2) end
    diffBtn:SetWidth(popupW - LOOT_POPUP_PAD * 2)
    specSelectRow:SetWidth(popupW - LOOT_POPUP_PAD * 2)
    lootOptionsPopup:SetSize(popupW, -gy + LOOT_POPUP_PAD)

    -- Hover-to-show wiring on the Loot filter row, mirroring the
    -- Collections sub-flyout pattern (with grace timer).
    local lootHover = Utils.AttachHoverPopup(row, lootOptionsPopup, {
        extraGuards = {
            diffPopup,
            classSel.popup,
            classSel.flyout,
        },
        onShow = function()
            SetActiveFlyout(lootOptionsPopup)
            if row.updateLootToggle then row.updateLootToggle() end
            lootOptionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenFlyoutBeside(lootOptionsPopup, row, 4)
            lootOptionsPopup:Show()
        end,
    })
    row.ShowLootOptionsPopup = lootHover.Show
    -- Outside-click: nested diff/spec/class popups act as guards
    -- so clicks inside them don't dismiss the loot options.
    Filters.AttachOutsideClickClose(lootOptionsPopup, {
        onHide = function(self)
            diffPopup:Hide()
            classSel.popup:Hide()
            classSel.flyout:Hide()
            ClearActiveFlyout(self)
        end,
    })
    dropdown:HookScript("OnHide", function() lootOptionsPopup:Hide() end)

    row.updateLootToggle = function()
        local chainEnabled = EasyFind.db.uiSearchFilters.loot ~= false
        for _, sr in ipairs(lootSubRows) do
            if sr.SetChecked and sr.resolveDbPath then
                local tbl, leaf = sr.resolveDbPath()
                sr:SetChecked(tbl[leaf] == true)
            end
            SetFlyoutRowEnabled(sr, chainEnabled)
        end
        SetFlyoutRowEnabled(diffBtn, chainEnabled)
        SetFlyoutRowEnabled(specSelectRow, chainEnabled)
        classSel.Refresh()
        if row.UpdateDiffButtons then row.UpdateDiffButtons() end
    end
    lootOptionsPopup._efSync = row.updateLootToggle
end
