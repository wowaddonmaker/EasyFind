local _, ns = ...

local MapTab = {}
ns.MapTab = MapTab

local Utils = ns.Utils
local SafeAfter = Utils and Utils.SafeAfter or function(delay, fn) C_Timer.After(delay, fn) end
local sfind = Utils and Utils.sfind or string.find
local slower = Utils and Utils.slower or string.lower
local tinsert = Utils and Utils.tinsert or table.insert
local wipe = wipe

local GOLD_COLOR = ns.GOLD_COLOR or {1.0, 0.82, 0.0}
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER
local DARK_PANEL_BG = ns.DARK_PANEL_BG

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local C_Timer = C_Timer
local GetCursorPosition = GetCursorPosition
local UIParent = UIParent
local select = select

-- Side-tab geometry and shared atlas textures from the Blizzard map.
local TAB_W, TAB_H       = 42, 55
local TAB_BG_W, TAB_BG_H = 51, 59
local TAB_ICON_SIZE      = 28

-- Popup menu geometry (matches UI.lua's pin/guide popup)
local EYE_ICON_TEX     = "Interface\\AddOns\\EasyFind\\textures\\eye"
local PIN_MENU_ROW_H   = 22
local PIN_MENU_WIDTH   = 96

-- Result row layout
local ROW_HEIGHT       = 24
local ROW_ICON_SIZE    = 18
local SECTION_HEADER_H = 22
local MAX_ROW_POOL     = 60

local initialized = false
local tabFrame
local panel
local selectedIsOurs = false
local rowPool = {}
local lastQueryGen = 0   -- bumped per search to invalidate in-flight rebuilds
local pendingSearchTimer

-- ===================================================================
-- Helpers
-- ===================================================================

local function FindAtlasTexture(frame, atlas)
    if not frame or not frame.GetRegions then return nil end
    for i = 1, frame:GetNumRegions() do
        local region = select(i, frame:GetRegions())
        if region and region.GetAtlas and region.GetObjectType and region:GetObjectType() == "Texture" then
            if region:GetAtlas() == atlas then return region end
        end
    end
    return nil
end

local function HideBlizzPanels(qmf)
    if qmf.QuestsFrame then qmf.QuestsFrame:Hide() end
    if qmf.DetailsFrame then qmf.DetailsFrame:Hide() end
    if qmf.MapLegendFrame then qmf.MapLegendFrame:Hide() end
end

local function RefreshSelectGlows()
    local qmf = _G["QuestMapFrame"]
    if not qmf then return end
    local function setGlow(tab, shown)
        if not tab then return end
        local glow = tab._efSelectGlow or FindAtlasTexture(tab, "QuestLog-Tab-side-Glow-Select")
        if glow then
            tab._efSelectGlow = glow
            glow:SetShown(shown)
        end
    end
    if selectedIsOurs then
        setGlow(qmf.QuestsTab, false)
        setGlow(qmf.MapLegendTab, false)
        setGlow(tabFrame, true)
    else
        setGlow(tabFrame, false)
    end
end

local function ShallowCopyList(list)
    if not list then return {} end
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    return copy
end

-- ===================================================================
-- Pin/Guide context menu (mirrors UI.lua's popup pattern)
-- ===================================================================

local pinPopup

local function CreateMenuRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(PIN_MENU_ROW_H)
    row:RegisterForClicks("LeftButtonUp")
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.label = label
    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    icon:Hide()
    row.icon = icon
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    return row
end

local function MenuRowOnLeave()
    if pinPopup and not pinPopup:IsMouseOver() then pinPopup:Hide() end
end

local function ShowPopup(isPinned, onPin, onGuide)
    if not pinPopup then
        pinPopup = CreateFrame("Frame", "EasyFindMapTabPopup", UIParent, "BackdropTemplate")
        pinPopup:SetFrameStrata("TOOLTIP")
        pinPopup:SetFrameLevel(10000)
        pinPopup:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        if DARK_PANEL_BG then
            pinPopup:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])
        end
        pinPopup.guideRow = CreateMenuRow(pinPopup)
        pinPopup.guideRow.label:SetText("Guide")
        pinPopup.guideRow.icon:SetTexture(EYE_ICON_TEX)
        pinPopup.guideRow.icon:Show()
        pinPopup.pinRow = CreateMenuRow(pinPopup)
        pinPopup.pinRow:SetScript("OnLeave", MenuRowOnLeave)
        pinPopup.guideRow:SetScript("OnLeave", MenuRowOnLeave)
    end

    pinPopup.pinRow:Show()
    pinPopup.pinRow.label:SetText(isPinned and "Unpin" or "Pin")
    pinPopup.pinRow:SetScript("OnClick", function()
        pinPopup:Hide()
        if onPin then onPin() end
    end)
    pinPopup.pinRow:ClearAllPoints()

    if onGuide then
        pinPopup.guideRow:ClearAllPoints()
        pinPopup.guideRow:SetPoint("TOPLEFT", pinPopup, "TOPLEFT", 4, -4)
        pinPopup.guideRow:SetPoint("TOPRIGHT", pinPopup, "TOPRIGHT", -4, -4)
        pinPopup.guideRow:Show()
        pinPopup.guideRow:SetScript("OnClick", function()
            pinPopup:Hide()
            onGuide()
        end)
        pinPopup.pinRow:SetPoint("TOPLEFT", pinPopup.guideRow, "BOTTOMLEFT", 0, 0)
        pinPopup.pinRow:SetPoint("TOPRIGHT", pinPopup.guideRow, "BOTTOMRIGHT", 0, 0)
        pinPopup:SetSize(PIN_MENU_WIDTH, PIN_MENU_ROW_H * 2 + 8)
    else
        pinPopup.guideRow:Hide()
        pinPopup.guideRow:SetScript("OnClick", nil)
        pinPopup.pinRow:SetPoint("TOPLEFT", pinPopup, "TOPLEFT", 4, -4)
        pinPopup.pinRow:SetPoint("TOPRIGHT", pinPopup, "TOPRIGHT", -4, -4)
        pinPopup:SetSize(PIN_MENU_WIDTH, PIN_MENU_ROW_H + 8)
    end

    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    pinPopup:ClearAllPoints()
    pinPopup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    pinPopup:Show()
end

-- ===================================================================
-- Result rows
-- ===================================================================

local function CreateResultRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:EnableMouse(true)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon = icon

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    local path = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    path:SetJustifyH("LEFT")
    path:SetTextColor(0.55, 0.55, 0.55)
    path:Hide()
    row.path = path

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local hl = row:GetHighlightTexture()
    hl:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.25)

    return row
end

local function SetRowIcon(row, data)
    local icon = data.icon
    row.icon:SetTexCoord(0, 1, 0, 1)
    if type(icon) == "string" and icon:sub(1, 6) == "atlas:" then
        row.icon:SetTexture(nil)
        row.icon:SetAtlas(icon:sub(7), false)
    elseif type(icon) == "number" then
        row.icon:SetAtlas(nil)
        row.icon:SetTexture(icon)
    elseif type(icon) == "string" then
        row.icon:SetAtlas(nil)
        row.icon:SetTexture(icon)
    elseif type(icon) == "table" and icon.file then
        row.icon:SetAtlas(nil)
        row.icon:SetTexture(icon.file)
        if icon.coords then
            row.icon:SetTexCoord(icon.coords[1], icon.coords[2], icon.coords[3], icon.coords[4])
        end
    else
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

local function HoverPreview(data)
    local MapSearch = ns.MapSearch
    if not MapSearch or not MapSearch.GetPreviewCoords then return end
    local coords = MapSearch:GetPreviewCoords(data)
    if not coords then return end
    MapSearch._savedPinState = MapSearch._savedPinState
    MapSearch._previewing = true
    if coords.instances then
        MapSearch:ShowMultipleWaypoints(coords.instances)
    elseif coords.pin and coords.pin:IsShown() then
        MapSearch:HighlightPin(coords.pin, coords.x, coords.y, coords.icon, coords.category)
    else
        MapSearch:ShowWaypointAt(coords.x, coords.y, coords.icon, coords.category)
    end
end

local function ClearHoverPreview()
    local MapSearch = ns.MapSearch
    if not MapSearch then return end
    if MapSearch._previewing then
        MapSearch._previewing = nil
        if MapSearch.ClearHighlight then MapSearch:ClearHighlight() end
    end
end

-- Refresh the current search without stealing focus. Called after pin toggle.
local function RefreshCurrentSearch()
    if not panel or not panel.searchBox then return end
    MapTab:RunSearch(panel.searchBox:GetText() or "")
end

local function RowOnClick(row, button)
    local data = row.data
    if not data then return end
    local MapSearch = ns.MapSearch

    if data.isPinHeader then
        EasyFind.db.mapPinsCollapsed = not EasyFind.db.mapPinsCollapsed
        RefreshCurrentSearch()
        return
    end

    if button == "RightButton" then
        local isPinned = MapSearch and MapSearch:IsMapItemPinned(data)
        local isGlobal = data.isZone or data.isDungeonEntrance
        local onGuide = isGlobal and function()
            if MapSearch and MapSearch.SelectResult then
                MapSearch:SelectResult(data)
            end
        end or nil
        ShowPopup(isPinned, function()
            if isPinned then
                MapSearch:UnpinMapItem(data)
            else
                MapSearch:PinMapItem(data)
            end
            RefreshCurrentSearch()
        end, onGuide)
        return
    end

    if MapSearch and MapSearch.SelectResult then
        MapSearch:SelectResult(data)
    end
end

local function RowOnEnter(row)
    if row.data then HoverPreview(row.data) end
end

local function RowOnLeave()
    ClearHoverPreview()
end

local function AcquireRow(parent)
    for i = 1, #rowPool do
        local row = rowPool[i]
        if not row:IsShown() then
            row:SetParent(parent)
            return row
        end
    end
    if #rowPool >= MAX_ROW_POOL then return nil end
    local row = CreateResultRow(parent)
    row:SetScript("OnClick", RowOnClick)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    tinsert(rowPool, row)
    return row
end

local function ReleaseAllRows()
    for i = 1, #rowPool do
        rowPool[i]:Hide()
        rowPool[i].data = nil
    end
end

-- ===================================================================
-- Section header (between Pinned / Local / Global)
-- ===================================================================

local function CreateSectionHeader(parent, labelText)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(SECTION_HEADER_H)
    local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", hdr, "LEFT", 6, 0)
    fs:SetText(labelText or "")
    fs:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
    hdr.label = fs
    local line = hdr:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", hdr, "RIGHT", -6, 0)
    line:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    return hdr
end

-- Section header pool (pinned / local / global)
local headerPool = {}
local function AcquireHeader(parent, labelText)
    for i = 1, #headerPool do
        local h = headerPool[i]
        if not h:IsShown() then
            h:SetParent(parent)
            h.label:SetText(labelText or "")
            return h
        end
    end
    local h = CreateSectionHeader(parent, labelText)
    tinsert(headerPool, h)
    return h
end

local function ReleaseAllHeaders()
    for i = 1, #headerPool do headerPool[i]:Hide() end
end

-- ===================================================================
-- Render pipeline
-- ===================================================================

local function BuildPinnedSection()
    local pins = EasyFind.db.pinnedMapItems
    if not pins or #pins == 0 then return nil end
    local list = { { isPinHeader = true, name = "Pinned" } }
    if not EasyFind.db.mapPinsCollapsed then
        for _, pin in ipairs(pins) do
            local copy = {}
            for k, v in pairs(pin) do copy[k] = v end
            copy.isPinned = true
            list[#list + 1] = copy
        end
    end
    return list
end

local function RenderRows(scrollChild, pinned, localResults, globalResults)
    ReleaseAllRows()
    ReleaseAllHeaders()

    local y = 4

    local function placeRow(data)
        local row = AcquireRow(scrollChild)
        if not row then return end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        row.data = data
        SetRowIcon(row, data)
        local name = data.name or ""
        if data.isPinHeader then
            row.text:SetTextColor(0.7, 0.7, 0.7)
            row.text:SetText((EasyFind.db.mapPinsCollapsed and "> " or "v ") .. name)
            row.icon:Hide()
        else
            row.icon:Show()
            if data.isZone then
                row.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
            else
                row.text:SetTextColor(1, 1, 1)
            end
            if data.pathPrefix and data.pathPrefix ~= "" then
                row.text:SetText(name .. "  |cff808080" .. data.pathPrefix .. "|r")
            else
                row.text:SetText(name)
            end
        end
        row:Show()
        y = y + ROW_HEIGHT
    end

    local function placeHeader(labelText)
        local hdr = AcquireHeader(scrollChild, labelText)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
        hdr:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        hdr:Show()
        y = y + SECTION_HEADER_H
    end

    if pinned and #pinned > 0 then
        for _, data in ipairs(pinned) do placeRow(data) end
    end

    if localResults and #localResults > 0 then
        placeHeader("In This Zone")
        for _, data in ipairs(localResults) do placeRow(data) end
    end

    if globalResults and #globalResults > 0 then
        placeHeader("Across Azeroth")
        for _, data in ipairs(globalResults) do placeRow(data) end
    end

    scrollChild:SetHeight(math.max(1, y + 4))
end

-- ===================================================================
-- Search runner
-- ===================================================================

function MapTab:RunSearch(text)
    if not panel then return end
    lastQueryGen = lastQueryGen + 1
    local myGen = lastQueryGen

    local scrollChild = panel.scrollChild
    local MapSearch = ns.MapSearch
    local pinned = BuildPinnedSection()

    if not text or #text < 2 then
        -- No query: show pinned section only (if any)
        if pinned then
            RenderRows(scrollChild, pinned, nil, nil)
            panel.emptyMsg:Hide()
        else
            ReleaseAllRows()
            ReleaseAllHeaders()
            scrollChild:SetHeight(1)
            panel.emptyMsg:SetText("|cff999999Start typing to search for POIs, zones, dungeons, and raids.|r")
            panel.emptyMsg:Show()
        end
        return
    end

    panel.emptyMsg:Hide()

    if not MapSearch or not MapSearch.BuildResults then
        ReleaseAllRows()
        ReleaseAllHeaders()
        return
    end

    -- Run both local and global searches. Shallow-copy each list because
    -- BuildResults uses module-level scratch tables that are wiped on the
    -- next call.
    local localResults = ShallowCopyList(MapSearch:BuildResults(text, false, true))
    if myGen ~= lastQueryGen then return end
    local globalResults = ShallowCopyList(MapSearch:BuildResults(text, true, true))
    if myGen ~= lastQueryGen then return end

    RenderRows(scrollChild, pinned, localResults, globalResults)

    if (not pinned or #pinned == 0)
       and (not localResults or #localResults == 0)
       and (not globalResults or #globalResults == 0) then
        panel.emptyMsg:SetText("|cff999999No matches.|r")
        panel.emptyMsg:Show()
    end
end

-- ===================================================================
-- Panel state
-- ===================================================================

local function ShowOurPanel()
    local qmf = _G["QuestMapFrame"]
    if not qmf or not panel then return end
    selectedIsOurs = true
    HideBlizzPanels(qmf)
    panel:Show()
    RefreshSelectGlows()
    if panel.searchBox then panel.searchBox:SetFocus() end
    MapTab:RunSearch(panel.searchBox and panel.searchBox:GetText() or "")
end

local function HideOurPanel()
    if not selectedIsOurs then return end
    selectedIsOurs = false
    if panel then
        panel:Hide()
        if panel.searchBox then panel.searchBox:ClearFocus() end
    end
    ClearHoverPreview()
    RefreshSelectGlows()
end

-- ===================================================================
-- Search box / filter cog
-- ===================================================================

local function CreateSearchBox(parent)
    local editBox = CreateFrame("EditBox", nil, parent)
    editBox:SetSize(301, 20)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(60)
    editBox:SetTextInsets(22, 8, 2, 2)

    local left = editBox:CreateTexture(nil, "BACKGROUND")
    left:SetAtlas("common-search-border-left", false)
    left:SetSize(8, 20)
    left:SetPoint("LEFT")

    local right = editBox:CreateTexture(nil, "BACKGROUND")
    right:SetAtlas("common-search-border-right", false)
    right:SetSize(7, 20)
    right:SetPoint("RIGHT")

    local mid = editBox:CreateTexture(nil, "BACKGROUND")
    mid:SetAtlas("common-search-border-middle", false)
    mid:SetPoint("LEFT", left, "RIGHT")
    mid:SetPoint("RIGHT", right, "LEFT")
    mid:SetHeight(20)

    local icon = editBox:CreateTexture(nil, "OVERLAY")
    icon:SetAtlas("common-search-magnifyingglass", false)
    icon:SetSize(10, 10)
    icon:SetPoint("LEFT", editBox, "LEFT", 8, 0)
    icon:SetVertexColor(0.6, 0.6, 0.6, 1)

    local placeholder = editBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    placeholder:SetPoint("RIGHT", editBox, "RIGHT", -4, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetText("Search for POIs, zones, instances...")
    editBox.placeholder = placeholder

    editBox:HookScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "")
        if pendingSearchTimer then pendingSearchTimer:Cancel() end
        -- Debounce so we don't rebuild per keystroke
        local snapshot = self:GetText() or ""
        pendingSearchTimer = C_Timer.NewTimer(0.08, function()
            MapTab:RunSearch(snapshot)
        end)
    end)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    return editBox
end

local function CreateFilterCog(parent)
    local cog = CreateFrame("Button", nil, parent)
    cog:SetSize(14, 16)
    local iconTex = cog:CreateTexture(nil, "ARTWORK")
    iconTex:SetAtlas("QuestLog-icon-setting", false)
    iconTex:SetAllPoints()
    local hoverTex = cog:CreateTexture(nil, "HIGHLIGHT")
    hoverTex:SetAtlas("QuestLog-icon-setting", false)
    hoverTex:SetAllPoints()
    hoverTex:SetAlpha(0.4)
    cog:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Filter options")
        GameTooltip:AddLine("Category filters coming soon.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", GameTooltip_Hide)
    return cog
end

-- ===================================================================
-- Tab creation
-- ===================================================================

local function CreateTabFrame(qmf)
    local tab = CreateFrame("Frame", "EasyFindMapSearchTab", qmf)
    tab:SetSize(TAB_W, TAB_H)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.MapLegendTab:GetFrameLevel())
    tab:SetPoint("TOPLEFT", qmf.MapLegendTab, "BOTTOMLEFT", 0, 2)
    tab:EnableMouse(true)

    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("QuestLog-tab-side", false)
    bg:SetSize(TAB_BG_W, TAB_BG_H)
    bg:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetAtlas("common-search-magnifyingglass", false)
    icon:SetSize(TAB_ICON_SIZE, TAB_ICON_SIZE)
    icon:SetPoint("CENTER", tab, "CENTER", -4, 0)

    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas("QuestLog-Tab-side-Glow-Select", false)
    selectGlow:SetSize(TAB_BG_W, TAB_BG_H)
    selectGlow:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    selectGlow:Hide()
    tab._efSelectGlow = selectGlow

    local hoverGlow = tab:CreateTexture(nil, "HIGHLIGHT")
    hoverGlow:SetAtlas("QuestLog-Tab-side-Glow-hover", false)
    hoverGlow:SetSize(TAB_BG_W, TAB_BG_H)
    hoverGlow:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)

    tab:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ShowOurPanel() end
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("EasyFind Map Search")
        GameTooltip:AddLine("Search POIs, flight masters, zones, dungeons, raids, and more.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)

    return tab
end

-- ===================================================================
-- Panel creation
-- ===================================================================

local function CreatePanel(qmf)
    local host = qmf.QuestsFrame or qmf
    local p = CreateFrame("Frame", "EasyFindMapSearchPanel", qmf)
    p:SetFrameStrata(qmf:GetFrameStrata())
    p:SetFrameLevel(qmf:GetFrameLevel() + 5)
    p:SetAllPoints(host)
    p:EnableMouse(true)
    p:Hide()

    local searchBox = CreateSearchBox(p)
    searchBox:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -8)
    p.searchBox = searchBox

    local cog = CreateFilterCog(p)
    cog:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
    p.cog = cog

    local scrollFrame = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -12)
    scrollFrame:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -24, 8)
    p.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:HookScript("OnSizeChanged", function(_, w) scrollChild:SetWidth(w) end)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    p.scrollChild = scrollChild

    local emptyMsg = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyMsg:SetPoint("TOP", scrollFrame, "TOP", 0, -24)
    emptyMsg:SetWidth(260)
    emptyMsg:SetJustifyH("CENTER")
    emptyMsg:SetText("|cff999999Start typing to search for POIs, zones, dungeons, and raids.|r")
    p.emptyMsg = emptyMsg

    return p
end

-- ===================================================================
-- Initialize
-- ===================================================================

function MapTab:Initialize()
    if initialized then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf or not qmf.MapLegendTab then return end
    initialized = true

    tabFrame = CreateTabFrame(qmf)
    panel = CreatePanel(qmf)

    if qmf.QuestsTab then
        qmf.QuestsTab:HookScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then HideOurPanel() end
        end)
    end
    if qmf.MapLegendTab then
        qmf.MapLegendTab:HookScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then HideOurPanel() end
        end)
    end
    if qmf.QuestsFrame then
        qmf.QuestsFrame:HookScript("OnShow", HideOurPanel)
    end
    if qmf.MapLegendFrame then
        qmf.MapLegendFrame:HookScript("OnShow", HideOurPanel)
    end
end

-- Blizzard_WorldMap is on-demand loaded. Hook the moment it loads, plus
-- defend against race conditions where it's already loaded at our init.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == "Blizzard_WorldMap" then
        SafeAfter(0, function() MapTab:Initialize() end)
    elseif event == "PLAYER_LOGIN" then
        local isLoaded
        if C_AddOns and C_AddOns.IsAddOnLoaded then
            isLoaded = C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
        end
        if isLoaded then
            SafeAfter(0, function() MapTab:Initialize() end)
        end
    end
end)
