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
    local CreateRadioTexture = ctx.CreateRadioTexture
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

    -- Difficulty dropdown (single-select, matches EJ style)
    local DIFF_OPTIONS = {
        { key = "lfr",    label = _G["RAID_FINDER"] or "Raid Finder" },
        { key = "normal", label = _G["PLAYER_DIFFICULTY1"] or "Normal" },
        { key = "heroic", label = _G["PLAYER_DIFFICULTY2"] or "Heroic" },
        { key = "mythic", label = _G["PLAYER_DIFFICULTY6"] or "Mythic" },
    }
    local DIFF_LABELS = {
        lfr = _G["RAID_FINDER"] or "Raid Finder",
        normal = _G["PLAYER_DIFFICULTY1"] or "Normal",
        heroic = _G["PLAYER_DIFFICULTY2"] or "Heroic",
        mythic = _G["PLAYER_DIFFICULTY6"] or "Mythic",
    }

    local diffBtn = CreateFrame("Button", nil, lootOptionsPopup)
    diffBtn:SetSize(LOOT_POPUP_WIDTH - LOOT_POPUP_PAD * 2, 27)
    local diffBg = diffBtn:CreateTexture(nil, "BACKGROUND")
    ns.Utils.StyleDropdownBg(diffBg)
    local diffArrow = diffBtn:CreateTexture(nil, "OVERLAY")
    diffArrow:SetAtlas("common-dropdown-a-button-hover")
    diffArrow:SetSize(22, 22)
    diffArrow:SetPoint("RIGHT", -10, -1)
    -- Dark textholder pill on every theme: light-on-dark scheme, no
    -- theme tints (see Utils.CreateDropdownButton).
    diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    local diffText = diffBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    diffText:SetShadowColor(0, 0, 0, 0)
    diffText:SetPoint("LEFT", 14, 0)
    diffText:SetPoint("RIGHT", diffArrow, "LEFT", -2, 0)
    diffText:SetJustifyH("LEFT")
    diffText:SetWordWrap(false)
    diffText._efOwnColor = true
    diffText:SetTextColor(1, 1, 1)
    diffBtn:SetScript("OnEnter", function()
        diffArrow:SetVertexColor(1, 1, 1)
    end)
    diffBtn:SetScript("OnLeave", function()
        diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    end)
    diffBtn._label = diffText
    diffBtn._chev = diffArrow

    local function UpdateDiffLabel()
        local key = EasyFind.db.lootDifficulty or "normal"
        diffText:SetText(DIFF_LABELS[key] or _G["PLAYER_DIFFICULTY1"] or "Normal")
    end

    -- Difficulty popup menu
    local diffPopup = CreateFrame("Frame", "EasyFindDiffPopup", UIParent, "BackdropTemplate")
    diffPopup:SetFrameStrata("TOOLTIP")
    diffPopup:SetFrameLevel(lootOptionsPopup:GetFrameLevel() + 20)
    StylePopup(diffPopup)
    diffPopup:EnableMouse(true)
    diffPopup:Hide()

    local diffPopupRows = {}
    local diffRowLead
    local py = -6
    for _, def in ipairs(DIFF_OPTIONS) do
        local dRow = CreateFrame("Button", nil, diffPopup)
        dRow:SetSize(130, 20)
        dRow:SetPoint("TOPLEFT", 8, py)
        local radio, setRadioChecked = CreateRadioTexture(dRow)
        radio:SetPoint("LEFT", 0, 0)
        diffRowLead = diffRowLead or (radio:GetWidth() + 4)
        local dLabel = dRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        dLabel:SetShadowColor(0, 0, 0, 0)
        dLabel:SetPoint("LEFT", radio, "RIGHT", 4, 0)
        dLabel:SetText(def.label)
        dRow._label = dLabel
        InstallMenuRowHighlight(dRow)
        dRow._diffKey = def.key
        dRow._setRadioChecked = setRadioChecked
        dRow:SetScript("OnClick", function()
            EasyFind.db.lootDifficulty = def.key
            UpdateDiffLabel()
            diffPopup:Hide()
            Filters:ApplyFilterSelection("loot")
        end)
        diffPopupRows[#diffPopupRows + 1] = dRow
        py = py - 20
    end
    local diffContentW = 0
    for i = 1, #diffPopupRows do
        local w = Utils.FlyoutRowContentWidth(diffPopupRows[i], diffRowLead or 18)
        if w > diffContentW then diffContentW = w end
    end
    local diffPopupW = Utils.FlyoutWidthFor(diffContentW, 8)
    for i = 1, #diffPopupRows do diffPopupRows[i]:SetWidth(diffPopupW - 16) end
    diffPopup:SetSize(diffPopupW, -py + 6)

    local function SyncDiffRadios()
        local key = EasyFind.db.lootDifficulty or "normal"
        for _, dr in ipairs(diffPopupRows) do
            dr._setRadioChecked(dr._diffKey == key)
        end
    end

    diffBtn:SetScript("OnClick", function()
        if diffPopup:IsShown() then
            diffPopup:Hide()
        else
            SyncDiffRadios()
            diffPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenDropdownBelow(diffPopup, diffBtn, 2)
            diffPopup:Show()
        end
    end)
    Filters.AttachOutsideClickClose(diffPopup)

    AddPopupKeyboardNav(diffPopup, function() return diffPopupRows end)
    dropdownGuardFrames[#dropdownGuardFrames + 1] = diffPopup

    row.diffBtn = diffBtn
    row.diffPopup = diffPopup
    row.UpdateDiffButtons = function()
        UpdateDiffLabel()
    end

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
    local popupW = Utils.FlyoutWidthFor(contentW, LOOT_POPUP_PAD)
    for i = 1, #lootSubRows do lootSubRows[i]:SetWidth(popupW - LOOT_POPUP_PAD * 2) end
    diffBtn:SetWidth(popupW - LOOT_POPUP_PAD * 2)
    specSelectRow:SetWidth(ns.CLASS_SELECTOR_BTN_W)
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
