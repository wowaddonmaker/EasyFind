local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils

local ipairs = Utils.ipairs
local CreateFrame = CreateFrame
local UIParent = UIParent

-- Builds the Appearance Sets options popup: a class selector (shared with the
-- gear/heirloom filters) plus Collected / Not Collected / PvE / PvP checkboxes.
-- Returns the popup frame and a sync function that re-reads EasyFind.db state.
function Filters:BuildAppearanceSetOptionsPopup(StylePopup, ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox, dropdownGuardFrames, branchPopups)
    local OPTIONS_WIDTH = 160
    local CB_ROW_H = 22
    local CLASS_BTN_H = 27
    local PAD = 6

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("transmogSets")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindAsOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    local classSel = Filters:BuildClassSpecSelector({
        parent = optionsPopup,
        x = PAD, y = -PAD,
        width = OPTIONS_WIDTH - PAD * 2,
        hasSpec = false,
        rowHighlight = ROW_HIGHLIGHT_COLOR,
        stylePopup = StylePopup,
        guardFrames = dropdownGuardFrames,
        getScale = function() return EasyFind.db.uiSearchScale or 1.0 end,
        getFilter = function() return EasyFind.db.appearanceSetClass end,
        setFilter = function(v) EasyFind.db.appearanceSetClass = v end,
        onChange = ApplyFilterSelection,
    })

    if branchPopups then
        branchPopups[#branchPopups + 1] = optionsPopup
        if classSel.popup then branchPopups[#branchPopups + 1] = classSel.popup end
    end

    local filterDefs = {
        { dbKey = "appearanceSetCollected",     label = _G["COLLECTED"] or "Collected" },
        { dbKey = "appearanceSetNotCollected",  label = _G["NOT_COLLECTED"] or "Not Collected" },
        { dbKey = "appearanceSetPvE",           label = _G["TRANSMOG_SET_PVE"] or "PvE" },
        { dbKey = "appearanceSetPvP",           label = _G["PVP"] or "PvP" },
    }

    local cbRows = {}
    local cy = -(PAD + CLASS_BTN_H + 6)
    for si, def in ipairs(filterDefs) do
        local cbRow = CreateFrame("CheckButton", nil, optionsPopup)
        cbRow:SetSize(OPTIONS_WIDTH - PAD * 2, CB_ROW_H)
        cbRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, cy)

        cbRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cbRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetNormalTexture():ClearAllPoints()
        cbRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

        cbRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cbRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetCheckedTexture():ClearAllPoints()
        cbRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local cbText = cbRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        cbText:SetPoint("LEFT", cbRow:GetNormalTexture(), "RIGHT", 4, 0)
        cbText:SetText(def.label)

        local cbHL = cbRow:CreateTexture(nil, "HIGHLIGHT")
        cbHL:SetAllPoints()
        cbHL:SetColorTexture(1, 1, 1, 0.1)

        local val = EasyFind.db[def.dbKey]
        if val == nil then val = true end
        cbRow:SetChecked(val)
        cbRow.dbKey = def.dbKey

        cbRow:SetScript("OnClick", function(self)
            EasyFind.db[def.dbKey] = self:GetChecked()
            ApplyFilterSelection()
        end)

        cbRows[si] = cbRow
        cy = cy - CB_ROW_H
        if si == 2 then
            local sep = optionsPopup:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 4, cy + 2)
            sep:SetPoint("TOPRIGHT", optionsPopup, "TOPRIGHT", -(PAD + 4), cy + 2)
            sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            cy = cy - 6
        end
    end
    optionsPopup:SetSize(OPTIONS_WIDTH, -cy + PAD)

    -- Outside-click: close when the user clicks off this popup and the class
    -- selector's own popup.
    optionsPopup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if classSel.popup then classSel.popup:Hide() end
    end)
    optionsPopup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self._owningRow and self._owningRow:IsMouseOver() then return end
        if classSel.popup and Utils.IsFrameVisiblyMouseOver(classSel.popup) then return end
        self:Hide()
    end)

    local function SyncFromDB()
        classSel.Refresh()
        for _, sr in ipairs(cbRows) do
            if sr.dbKey then
                sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
            end
        end
    end

    return optionsPopup, SyncFromDB
end
