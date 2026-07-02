local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs
local select = Utils.select
local tsort = Utils.tsort
local SetFlyoutRowEnabled = Utils.SetFlyoutRowEnabled
local CreateFrame = CreateFrame
local UIParent = UIParent
local wipe = wipe

local MOUNT_SOURCE_FALLBACK_LABELS = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "Profession",
    [5] = "Achievement",
    [6] = "World Event",
    [7] = "Promotion",
    [8] = "Trading Post",
    [9] = "Discovery",
}

local function MountSourceLabel(sourceType)
    return _G["MOUNT_JOURNAL_FILTER_SOURCE_" .. tostring(sourceType)]
        or _G["MOUNT_JOURNAL_FILTER_" .. tostring(sourceType)]
        or _G["BATTLE_PET_SOURCE_" .. tostring(sourceType)]
        or MOUNT_SOURCE_FALLBACK_LABELS[sourceType]
        or ("Source " .. tostring(sourceType))
end

local function SortMountSourceDefs(a, b)
    if a.sourceType ~= b.sourceType then return a.sourceType < b.sourceType end
    return a.label < b.label
end

local cachedMountSourceDefs
local function CollectMountSourceDefs()
    if cachedMountSourceDefs then return cachedMountSourceDefs end
    local seen = {}
    local defs = {}
    if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
        local mountIDs = C_MountJournal.GetMountIDs()
        if mountIDs then
            for i = 1, #mountIDs do
                local sourceType = select(6, C_MountJournal.GetMountInfoByID(mountIDs[i]))
                if sourceType and sourceType > 0 and not seen[sourceType] then
                    seen[sourceType] = true
                    defs[#defs + 1] = { sourceType = sourceType, label = MountSourceLabel(sourceType) }
                end
            end
        end
    end
    tsort(defs, SortMountSourceDefs)
    cachedMountSourceDefs = defs
    return defs
end

local mountSourceInvalidator
local function EnsureMountSourceInvalidator()
    if mountSourceInvalidator then return end
    mountSourceInvalidator = CreateFrame("Frame")
    mountSourceInvalidator:RegisterEvent("NEW_MOUNT_ADDED")
    mountSourceInvalidator:SetScript("OnEvent", function()
        cachedMountSourceDefs = nil
    end)
end

function Filters:BuildMountOptionsPopup(StylePopup, CHECK_SIZE, searchEditBox)
    local OPTIONS_WIDTH = 160
    local SOURCE_WIDTH = 170
    local ROW_H = 22
    local PAD = 6
    local HEADER_H = 20

    local function InstallMenuRowHighlight(row)
        Utils.InstallMenuRowHighlight(row)
    end

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("mounts")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local function ChainEnabled()
        local uiFilters = EasyFind.db.uiSearchFilters
        return uiFilters.collections ~= false and uiFilters.mounts ~= false
    end

    EnsureMountSourceInvalidator()

    local optionsPopup = CreateFrame("Frame", "EasyFindMountOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    local sourcePopup = CreateFrame("Frame", "EasyFindMountSourcePopup", UIParent, "BackdropTemplate")
    sourcePopup:SetFrameStrata("TOOLTIP")
    sourcePopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(sourcePopup)
    sourcePopup:EnableMouse(true)
    sourcePopup:Hide()

    local sourceRows = {}
    local function EnsureSourceFilters()
        EasyFind.db.mountSourceFilters = EasyFind.db.mountSourceFilters or {}
        return EasyFind.db.mountSourceFilters
    end

    local function CreatePlainRow(parent, text)
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(SOURCE_WIDTH - PAD * 2, ROW_H)
        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", 14, 0)
        label:SetText(text)
        row._label = label
        InstallMenuRowHighlight(row)
        return row
    end

    local toggleAllRow = CreatePlainRow(sourcePopup, L["FILTER_TOGGLE_ALL"])

    local function LayoutSourcePopup()
        local defs = CollectMountSourceDefs()
        local filters = EnsureSourceFilters()
        local chainEnabled = ChainEnabled()
        toggleAllRow:ClearAllPoints()
        toggleAllRow:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -PAD)
        SetFlyoutRowEnabled(toggleAllRow, chainEnabled)

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
                row._label = row.text
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
            SetFlyoutRowEnabled(row, chainEnabled)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sourcePopup, "TOPLEFT", PAD, -(PAD + i * ROW_H))
            row:Show()
        end
        sourcePopup:SetSize(SOURCE_WIDTH, PAD * 2 + (1 + #defs) * ROW_H)
        Utils.RefreshMenuRowHighlights(sourcePopup)
    end

    toggleAllRow:SetScript("OnClick", function()
        local filters = EnsureSourceFilters()
        local defs = CollectMountSourceDefs()
        local allUnchecked = true
        for _, def in ipairs(defs) do
            if filters[def.sourceType] ~= false then
                allUnchecked = false
                break
            end
        end
        if allUnchecked then
            wipe(filters)
        else
            for _, def in ipairs(defs) do
                filters[def.sourceType] = false
            end
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
        row._label = text
        InstallMenuRowHighlight(row)
        row.dbKey = def.dbKey
        row:SetScript("OnClick", function(self)
            EasyFind.db[self.dbKey] = self:GetChecked() and true or false
            ApplyFilterSelection()
        end)
        return row
    end

    local rows = {}
    local y = -PAD
    local filterDefs = {
        { dbKey = "mountFilterCollected",    label = _G["COLLECTED"] or "Collected" },
        { dbKey = "mountFilterNotCollected", label = _G["NOT_COLLECTED"] or "Not Collected" },
        { dbKey = "mountFilterUnusable",     label = _G["UNUSABLE"] or "Unusable" },
    }
    for _, def in ipairs(filterDefs) do
        rows[#rows + 1] = CreateCheckRow(def, y)
        y = y - ROW_H
    end

    local typeHeader = optionsPopup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    typeHeader:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 8, y - 2)
    typeHeader:SetText(_G["TYPE"] or "Type")
    y = y - HEADER_H

    local typeDefs = {
        { dbKey = "mountTypeGround",    label = _G["GROUND"] or "Ground" },
        { dbKey = "mountTypeFlying",    label = _G["FLYING"] or "Flying" },
        { dbKey = "mountTypeAquatic",   label = _G["AQUATIC"] or "Aquatic" },
        { dbKey = "mountTypeRideAlong", label = _G["RIDE_ALONG"] or "Ride Along" },
    }
    for _, def in ipairs(typeDefs) do
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
    sourcesRow._label = sourcesText
    sourcesRow._chev = sourceChev
    InstallMenuRowHighlight(sourcesRow)

    optionsPopup:SetSize(OPTIONS_WIDTH, PAD * 2 + #filterDefs * ROW_H + HEADER_H + #typeDefs * ROW_H + ROW_H)

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
        local chainEnabled = ChainEnabled()
        for _, row in ipairs(rows) do
            row:SetChecked(EasyFind.db[row.dbKey] ~= false)
            SetFlyoutRowEnabled(row, chainEnabled)
        end
        SetFlyoutRowEnabled(sourcesRow, chainEnabled)
        LayoutSourcePopup()
    end

    optionsPopup:HookScript("OnHide", function() sourcePopup:Hide() end)
    return optionsPopup, SyncOptions, sourcePopup
end
