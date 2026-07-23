local _, ns = ...

local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs
local sformat = Utils.sformat
local CreateFrame = CreateFrame
local UIParent = UIParent
local GetItemClassInfo = GetItemClassInfo
local CreateAtlasMarkup = CreateAtlasMarkup
local C_Texture = C_Texture

-- Curated type buckets, in display order. `class` is the ClassID used for the
-- localized label (GetItemClassInfo); the full ClassID->bucket coverage lives in
-- ns.CATALOG_TYPE_BUCKETS (ItemSearch.lua), which the scan filters against.
local TYPE_BUCKETS = {
    { key = "armor",      class = 4,  fallback = "Armor" },
    { key = "weapon",     class = 2,  fallback = "Weapons" },
    { key = "consumable", class = 0,  fallback = "Consumable" },
    { key = "tradegoods", class = 7,  fallback = "Trade Goods" },
    { key = "recipe",     class = 9,  fallback = "Recipe" },
    { key = "gem",        class = 3,  fallback = "Gem" },
    { key = "quest",      class = 12, fallback = "Quest" },
    { key = "housing",    class = 20, fallback = "Housing" },
    { key = "glyph",      class = 16, fallback = "Glyph" },
    { key = "container",  class = 1,  fallback = "Container" },
    { key = "misc",       class = 15, fallback = "Miscellaneous" },
}

local function ClassName(classID, fallback)
    local n = GetItemClassInfo and GetItemClassInfo(classID)
    return (type(n) == "string" and n ~= "") and n or fallback
end

-- Crafting quality star for a tier, falling back to the bare tier number (which
-- is locale-neutral) when the atlas is unavailable.
local function QualityLabel(tier)
    if tier == 0 then return _G["ALL"] or "All" end
    local atlas = "Professions-Icon-Quality-Tier" .. tier .. "-Small"
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        return CreateAtlasMarkup(atlas, 20, 20)
    end
    return tostring(tier)
end

function Filters:BuildCatalogOptionsPopup(StylePopup, CHECK_SIZE, dropdownGuardFrames)
    local ROW_H = 22
    local PAD = 6
    local HEADER_H = 20
    local BTN_H = 27

    local function ChainEnabled()
        local uiFilters = EasyFind.db.uiSearchFilters
        return uiFilters.items ~= false and uiFilters.catalog ~= false
    end

    local function EnsureTypeFilters()
        EasyFind.db.catalogTypeFilters = EasyFind.db.catalogTypeFilters or {}
        return EasyFind.db.catalogTypeFilters
    end

    local function ApplyCatalog()
        if ns.ItemSearch and ns.ItemSearch.RefreshFilters then
            ns.ItemSearch:RefreshFilters()
        end
        Filters:RerunActiveSearch()
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindCatalogOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    -- Quality dropdown bar (shared single-select template): "Quality: All",
    -- or "Quality: <star>" once a specific tier is chosen.
    local QUALITY_FMT = L["FILTER_QUALITY_FORMAT"]
    local qualityDrop = Filters:BuildSelectDropdown({
        parent = optionsPopup,
        name = "EasyFindCatalogQualityPopup",
        width = 140,
        options = {
            { value = 0, label = _G["ALL"] or "All" },
            { value = 1, label = QualityLabel(1) },
            { value = 2, label = QualityLabel(2) },
            { value = 3, label = QualityLabel(3) },
        },
        getValue = function() return EasyFind.db.catalogQualityTier or 0 end,
        setValue = function(v) EasyFind.db.catalogQualityTier = v end,
        formatLabel = function(_, optLabel) return sformat(QUALITY_FMT, optLabel or (_G["ALL"] or "All")) end,
        onChange = ApplyCatalog,
        stylePopup = StylePopup,
        guardFrames = dropdownGuardFrames,
    })
    local qualityBtn = qualityDrop.button

    local function CreateCheckRow(bucketKey, label, y)
        local row = CreateFrame("CheckButton", nil, optionsPopup)
        row:SetSize(100, ROW_H)
        row:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
        Utils.SetCheckboxTextures(row, CHECK_SIZE)
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        text:SetText(label)
        row._label = text
        row._bucket = bucketKey
        Utils.InstallMenuRowHighlight(row)
        row:SetScript("OnClick", function(self)
            EnsureTypeFilters()[bucketKey] = self:GetChecked() and true or false
            ApplyCatalog()
        end)
        return row
    end

    -- Layout: quality bar, then Type header + one checkbox per bucket.
    local y = -PAD
    qualityBtn:ClearAllPoints()
    qualityBtn:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, y)
    y = y - BTN_H - 4

    local typeHeader = optionsPopup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    typeHeader:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 8, y - 2)
    typeHeader:SetText(_G["TYPE"] or "Type")
    typeHeader:SetShadowColor(0, 0, 0, 0)
    -- GameFontNormal's gold base only suits dark fills; recolor for light themes
    -- on every open and live theme flip (matches MountOptions).
    optionsPopup._efOnThemeRestyle = function()
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if theme and theme.lightTheme then
            local c = theme.pathColorHover or theme.leafColor
            typeHeader:SetTextColor(c[1], c[2], c[3], 1)
        else
            typeHeader:SetTextColor(ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3], 1)
        end
    end
    optionsPopup._efOnThemeRestyle()
    y = y - HEADER_H

    local typeRows = {}
    for _, bucket in ipairs(TYPE_BUCKETS) do
        typeRows[#typeRows + 1] = CreateCheckRow(bucket.key, ClassName(bucket.class, bucket.fallback), y)
        y = y - ROW_H
    end

    -- Width: fit the widest checkbox, the Type header, and the quality bar's
    -- widest possible label (left inset + label + gap + arrow + inset).
    local contentW = 0
    for i = 1, #typeRows do
        local w = Utils.FlyoutRowContentWidth(typeRows[i], CHECK_SIZE + 4)
        if w > contentW then contentW = w end
    end
    local headerW = 8 + typeHeader:GetStringWidth()
    if headerW > contentW then contentW = headerW end
    qualityDrop.setLabel(sformat(QUALITY_FMT, QualityLabel(3)))
    local qBtnW = 14 + qualityBtn._label:GetStringWidth() + 2 + 22 + 10
    if qBtnW > contentW then contentW = qBtnW end
    qualityDrop.Refresh()

    local popupW = Utils.FlyoutWidthFor(contentW, PAD)
    qualityBtn:SetWidth(popupW - PAD * 2)
    for i = 1, #typeRows do typeRows[i]:SetWidth(popupW - PAD * 2) end
    optionsPopup:SetSize(popupW, -y + PAD)

    local function SyncOptions()
        local chainEnabled = ChainEnabled()
        qualityDrop.Refresh()
        Utils.SetFlyoutRowEnabled(qualityBtn, chainEnabled)
        local tf = EasyFind.db.catalogTypeFilters or {}
        for _, row in ipairs(typeRows) do
            row:SetChecked(tf[row._bucket] ~= false)
            Utils.SetFlyoutRowEnabled(row, chainEnabled)
        end
    end

    optionsPopup:HookScript("OnHide", function() qualityDrop.popup:Hide() end)
    return optionsPopup, SyncOptions, qualityDrop.popup
end
