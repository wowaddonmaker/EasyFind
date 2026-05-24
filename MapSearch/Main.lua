local _, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local Utils     = ns.Utils
local pairs, ipairs, type = Utils.pairs, Utils.ipairs, Utils.type
local tinsert, tremove = Utils.tinsert, Utils.tremove
local sfind = Utils.sfind
local MapSearchData = ns.MapSearchData
local CATEGORY_ICONS = MapSearchData.CATEGORY_ICONS
local CATEGORIES = MapSearchData.CATEGORIES


local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame        = CreateFrame
local UIParent           = UIParent
local IsMouseButtonDown  = IsMouseButtonDown

local function GetMapPinKey(data)
    if data.isZone and data.zoneMapID then
        return "zone:" .. data.zoneMapID
    end
    return (data.category or "unknown") .. ":" .. (data.name or "") .. ":" .. (data.mapID or "")
end

local function CleanForStorage(data)
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        end
    end
    return clean
end

local function IsMapItemPinned(data)
    local key = GetMapPinKey(data)
    for _, pin in ipairs(EasyFind.db.pinnedMapItems) do
        if GetMapPinKey(pin) == key then return true end
    end
    return false
end

local function PinMapItem(data)
    if IsMapItemPinned(data) then return end
    local clean = CleanForStorage(data)
    clean.isPinned = true
    -- Default freshly-pinned parent to collapsed; user toggles write back
    -- to this same entry so state survives map close, /reload, and logout.
    if data.isZone and data.zoneMapID and clean.collapsed == nil then
        clean.collapsed = true
    end
    tinsert(EasyFind.db.pinnedMapItems, clean)
end

local function UnpinMapItem(data)
    local key = GetMapPinKey(data)
    local items = EasyFind.db.pinnedMapItems
    for i = #items, 1, -1 do
        if GetMapPinKey(items[i]) == key then
            tremove(items, i)
            return
        end
    end
end

MapSearch.GetMapPinKey  = function(_, data) return GetMapPinKey(data) end
MapSearch.IsMapItemPinned = function(_, data) return IsMapItemPinned(data) end
MapSearch.PinMapItem   = function(_, data) return PinMapItem(data) end
MapSearch.UnpinMapItem = function(_, data) return UnpinMapItem(data) end

local function GetCategoryIcon(category)
    return CATEGORY_ICONS[category] or CATEGORY_ICONS.unknown
end

ns.MapSearch = ns.MapSearch or MapSearch
ns.MapSearch.GetCategoryIcon = GetCategoryIcon

local function GetFilterBucket(data)
    if not data then return "other" end
    -- Dungeons/raids/delves carry isZone=true; check category first.
    local cat = data.category
    if cat == "dungeon" or cat == "raid" or cat == "delve" then return "instances" end
    if data.isZone then return "zones" end
    if not cat then return "other" end
    if cat == "flightmaster" then return "flightpath" end
    if cat == "rare" then return "rares" end
    local parent = CATEGORIES[cat] and CATEGORIES[cat].parent
    if parent == "instance" then return "instances" end
    if parent == "travel" then return "travel" end
    if parent == "service" or cat == "service" then return "services" end
    -- StaticLocations subcategories (classtrainer_*, prof_*, etc.) bucket here.
    if sfind(cat, "^classtrainer_") or sfind(cat, "^prof_") then return "services" end
    if cat == "guildbank" or cat == "guildservices" or cat == "trainingdummy" then return "services" end
    return "other"
end
ns.MapSearch.GetFilterBucket = GetFilterBucket

function MapSearch:Initialize()
    self:CreateHighlightFrame()
    self:CreateZoneHighlightFrame()
    self:HookWorldMap()
    self:BuildWorldZoneCache()
end

function MapSearch:CreateFilterDropdown(globalName, options, dbKey, toggleBtn, anchorFrame, onChanged)
    local ROW_HEIGHT = 20
    local DROPDOWN_WIDTH = 207
    local PADDING_TOP = 8
    local HEADER_HEIGHT = 19
    local PADDING_BOTTOM = 8
    local CHECK_SIZE = 16

    local dropdown = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetFrameLevel(9999)
    dropdown:Hide()
    dropdown:EnableMouse(true)
    dropdown:SetClampedToScreen(true)

    dropdown:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    local header = dropdown:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    header:SetPoint("TOPLEFT", 12, -PADDING_TOP)
    header:SetText("Show:")
    header:SetTextColor(Utils.RGB(GOLD_COLOR, 1))

    local checkRows = {}
    local checkRowsByIndex = {}
    local yStart = -(PADDING_TOP + HEADER_HEIGHT)

    for i, opt in ipairs(options) do
        local row = CreateFrame("CheckButton", nil, dropdown)
        row:SetSize(DROPDOWN_WIDTH - 16, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, yStart - (i - 1) * ROW_HEIGHT)
        row:SetHitRectInsets(0, 0, 0, 0)
        row.optKey = opt.key

        row:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        row:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetNormalTexture():ClearAllPoints()
        row:GetNormalTexture():SetPoint("LEFT", 4, 0)

        row:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        row:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        row:GetCheckedTexture():ClearAllPoints()
        row:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        label:SetText(opt.label)

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)

        local kbHighlight = row:CreateTexture(nil, "BACKGROUND")
        kbHighlight:SetAllPoints()
        kbHighlight:SetColorTexture(1, 1, 1, 0.1)
        kbHighlight:Hide()
        row.kbHighlight = kbHighlight

        row:SetChecked(true)

        row:SetScript("OnClick", function(self)
            local filters = EasyFind.db[dbKey]
            filters[opt.key] = self:GetChecked()
            if onChanged then onChanged(opt.key, self:GetChecked()) end
        end)

        checkRows[opt.key] = row
        checkRowsByIndex[i] = row
    end

    dropdown.rows = checkRowsByIndex
    dropdown.selectedRow = 0

    function dropdown:SetSelectedRow(idx)
        self.selectedRow = idx
        for ri = 1, #checkRowsByIndex do
            checkRowsByIndex[ri].kbHighlight:SetShown(ri == idx)
        end
    end

    function dropdown:ToggleSelectedRow()
        local row = checkRowsByIndex[self.selectedRow]
        if row then
            row:Click()
        end
    end

    local totalHeight = PADDING_TOP + HEADER_HEIGHT + #options * ROW_HEIGHT + PADDING_BOTTOM
    dropdown:SetSize(DROPDOWN_WIDTH, totalHeight)

    dropdown:SetScript("OnShow", function(self)
        local filters = EasyFind.db[dbKey]
        for key, row in pairs(checkRows) do
            row:SetChecked(filters[key] ~= false)
        end
        self:SetSelectedRow(self.keyboardOpen and 1 or 0)
        self.keyboardOpen = nil
    end)

    dropdown:SetScript("OnHide", function(self)
        self:SetSelectedRow(0)
        if self.restoreToolbar then
            self.restoreToolbar()
            self.restoreToolbar = nil
        end
    end)

    Utils.SafeOnUpdate(dropdown, function(self)
        if self:IsShown() and IsMouseButtonDown("LeftButton") then
            if not self:IsMouseOver() and not toggleBtn:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    toggleBtn:SetScript("OnClick", function(self)
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            local scale = anchorFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            local right = anchorFrame:GetRight() * scale
            local bottom = anchorFrame:GetBottom() * scale
            dropdown:ClearAllPoints()
            dropdown:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
            dropdown:Show()
        end
    end)

    return dropdown
end
