local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs
local select = Utils.select
local tsort = Utils.tsort
local CreateFrame = CreateFrame
local UIParent = UIParent
local wipe = wipe

local HEIRLOOM_SOURCE_FALLBACK_LABELS = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "World Event",
}

local function HeirloomSourceLabel(sourceType)
    return _G["HEIRLOOM_SOURCE_" .. tostring(sourceType)]
        or _G["BATTLE_PET_SOURCE_" .. tostring(sourceType)]
        or HEIRLOOM_SOURCE_FALLBACK_LABELS[sourceType]
        or ("Source " .. tostring(sourceType))
end

local function SortHeirloomSourceDefs(a, b)
    if a.sourceType ~= b.sourceType then return a.sourceType < b.sourceType end
    return a.label < b.label
end

local cachedHeirloomSourceDefs
local function CollectHeirloomSourceDefs()
    if cachedHeirloomSourceDefs then return cachedHeirloomSourceDefs end
    local seen, defs = {}, {}
    if C_Heirloom and C_Heirloom.GetHeirloomItemIDs and C_Heirloom.GetHeirloomInfo then
        local ids = C_Heirloom.GetHeirloomItemIDs()
        if type(ids) == "table" then
            for i = 1, #ids do
                local sourceType = select(6, C_Heirloom.GetHeirloomInfo(ids[i]))
                if sourceType and not seen[sourceType] then
                    seen[sourceType] = true
                    defs[#defs + 1] = { sourceType = sourceType, label = HeirloomSourceLabel(sourceType) }
                end
            end
        end
    end
    tsort(defs, SortHeirloomSourceDefs)
    -- Don't cache an empty result: heirloom data may not be loaded on the first
    -- open, and we want a later open to pick the real source list up.
    if #defs > 0 then cachedHeirloomSourceDefs = defs end
    return defs
end

function Filters:BuildHeirloomOptionsPopup(StylePopup, CHECK_SIZE, searchEditBox, dropdownGuardFrames)
    local OPTIONS_WIDTH = 160
    local SOURCE_WIDTH = 170
    local ROW_H = 22
    local PAD = 6

    local function InstallMenuRowHighlight(row)
        Utils.InstallMenuRowHighlight(row)
    end

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("heirlooms")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindHeirloomOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    -- Class/spec selector at the top, synced to the Heirlooms Journal class
    -- dropdown (re-populate reads searchFiltered after pushing this choice).
    local CLASS_BTN_H = 27
    local CLASS_GAP = 4
    local classSel = Filters:BuildClassSpecSelector({
        parent = optionsPopup,
        x = PAD, y = -PAD,
        width = OPTIONS_WIDTH - PAD * 2,
        hasSpec = true,
        stylePopup = StylePopup,
        guardFrames = dropdownGuardFrames,
        getScale = function() return EasyFind.db.uiSearchScale or 1.0 end,
        getFilter = function() return EasyFind.db.heirloomFilter end,
        setFilter = function(v) EasyFind.db.heirloomFilter = v end,
        onChange = ApplyFilterSelection,
    })

    local sourcePopup = CreateFrame("Frame", "EasyFindHeirloomSourcePopup", UIParent, "BackdropTemplate")
    sourcePopup:SetFrameStrata("TOOLTIP")
    sourcePopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(sourcePopup)
    sourcePopup:EnableMouse(true)
    sourcePopup:Hide()

    local sourceRows = {}
    local function EnsureSourceFilters()
        EasyFind.db.heirloomSourceFilters = EasyFind.db.heirloomSourceFilters or {}
        return EasyFind.db.heirloomSourceFilters
    end

    local toggleAllRow = CreateFrame("Button", nil, sourcePopup)
    toggleAllRow:SetSize(SOURCE_WIDTH - PAD * 2, ROW_H)
    local toggleAllLabel = toggleAllRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    toggleAllLabel:SetPoint("LEFT", 14, 0)
    toggleAllLabel:SetText(L["FILTER_TOGGLE_ALL"])
    InstallMenuRowHighlight(toggleAllRow)

    local function LayoutSourcePopup()
        local defs = CollectHeirloomSourceDefs()
        local filters = EnsureSourceFilters()
        toggleAllRow:ClearAllPoints()
        toggleAllRow:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -PAD)

        for i = #sourceRows, #defs + 1, -1 do
            sourceRows[i]:Hide()
        end
        for i, def in ipairs(defs) do
            local row = sourceRows[i]
            if not row then
                row = CreateFrame("CheckButton", nil, sourcePopup)
                row:SetSize(SOURCE_WIDTH - PAD * 2, ROW_H)
                row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
                row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                row:GetNormalTexture():ClearAllPoints()
                row:GetNormalTexture():SetPoint("LEFT", 4, 0)
                row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
                row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
                row:GetCheckedTexture():ClearAllPoints()
                row:GetCheckedTexture():SetPoint("LEFT", 4, 0)
                row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                row.text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
                InstallMenuRowHighlight(row)
                row:SetScript("OnClick", function(self)
                    EnsureSourceFilters()[self.sourceType] = self:GetChecked() and nil or false
                    ApplyFilterSelection()
                end)
                sourceRows[i] = row
            end
            row.sourceType = def.sourceType
            row.text:SetText(def.label)
            row:SetChecked(filters[def.sourceType] ~= false)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -(PAD + i * ROW_H))
            row:Show()
        end
        sourcePopup:SetSize(SOURCE_WIDTH, PAD * 2 + (1 + #defs) * ROW_H)
        Utils.RefreshMenuRowHighlights(sourcePopup)
    end

    -- Toggle All: everything on if any source is currently off, else all off.
    toggleAllRow:SetScript("OnClick", function()
        local defs = CollectHeirloomSourceDefs()
        local filters = EnsureSourceFilters()
        local anyOff = false
        for _, def in ipairs(defs) do
            if filters[def.sourceType] == false then anyOff = true break end
        end
        if anyOff then
            wipe(filters)
        else
            for _, def in ipairs(defs) do filters[def.sourceType] = false end
        end
        LayoutSourcePopup()
        ApplyFilterSelection()
    end)

    local function CreateCheckRow(def, y)
        local row = CreateFrame("CheckButton", nil, optionsPopup)
        row:SetSize(OPTIONS_WIDTH - PAD * 2, ROW_H)
        row:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)
        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        text:SetText(def.label)
        InstallMenuRowHighlight(row)
        row.dbKey = def.dbKey
        row:SetScript("OnClick", function(self)
            EasyFind.db[self.dbKey] = self:GetChecked() and true or false
            ApplyFilterSelection()
        end)
        return row
    end

    local rows = {}
    local y = -PAD - CLASS_BTN_H - CLASS_GAP
    local filterDefs = {
        { dbKey = "heirloomFilterCollected",    label = _G["COLLECTED"] or "Collected" },
        { dbKey = "heirloomFilterNotCollected", label = _G["NOT_COLLECTED"] or "Not Collected" },
    }
    for _, def in ipairs(filterDefs) do
        rows[#rows + 1] = CreateCheckRow(def, y)
        y = y - ROW_H
    end

    local sourcesRow = CreateFrame("Button", nil, optionsPopup)
    sourcesRow:SetSize(OPTIONS_WIDTH - PAD * 2, ROW_H)
    sourcesRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
    local sourcesText = sourcesRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sourcesText:SetPoint("LEFT", 14, 0)
    sourcesText:SetText(_G["SOURCES"] or "Sources")
    local sourceChev = sourcesRow:CreateTexture(nil, "OVERLAY")
    sourceChev:SetAtlas("common-icon-forwardarrow")
    sourceChev:SetSize(CHECK_SIZE, CHECK_SIZE)
    sourceChev:SetPoint("RIGHT", -4, 0)
    InstallMenuRowHighlight(sourcesRow)

    optionsPopup:SetSize(OPTIONS_WIDTH, PAD * 2 + CLASS_BTN_H + CLASS_GAP + #filterDefs * ROW_H + ROW_H)

    Utils.AttachHoverPopup(sourcesRow, sourcePopup, {
        onShow = function()
            LayoutSourcePopup()
            sourcePopup:SetScale(optionsPopup:GetScale())
            sourcePopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 10)
            Utils.OpenFlyoutBeside(sourcePopup, sourcesRow, 4)
            sourcePopup:Show()
        end,
    })

    local function SyncOptions()
        if classSel then classSel.Refresh() end
        for _, row in ipairs(rows) do
            row:SetChecked(EasyFind.db[row.dbKey] ~= false)
        end
        LayoutSourcePopup()
    end

    optionsPopup:HookScript("OnHide", function()
        sourcePopup:Hide()
        if classSel.popup then classSel.popup:Hide() end
    end)
    return optionsPopup, SyncOptions, sourcePopup
end
