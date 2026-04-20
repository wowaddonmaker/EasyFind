local _, ns = ...

local MapTab = {}
ns.MapTab = MapTab

local Utils = ns.Utils
local SafeAfter = Utils and Utils.SafeAfter or function(delay, fn) C_Timer.After(delay, fn) end

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local select = select

-- QuestMapFrame side tabs: 42x55 Frames at strata HIGH/3 stacked on the
-- right edge of the map. We clone the existing visual structure and add
-- a 3rd tab below QuestMapFrame.MapLegendTab.
local TAB_W, TAB_H       = 42, 55
local TAB_BG_W, TAB_BG_H = 51, 59
local TAB_ICON_SIZE      = 28

local initialized = false
local tabFrame
local panel
local selectedIsOurs = false

-- Find a texture by its atlas name on a frame. Blizzard's tab frames
-- don't expose their Select / Hover glows as named members, so we
-- scan the region list for the one with the right atlas.
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

    -- When our panel is up, only our tab is "selected".
    if selectedIsOurs then
        setGlow(qmf.QuestsTab, false)
        setGlow(qmf.MapLegendTab, false)
        setGlow(tabFrame, true)
    else
        setGlow(tabFrame, false)
        -- Let Blizzard's own logic drive the Quests / Legend glow.
    end
end

local function ShowOurPanel()
    local qmf = _G["QuestMapFrame"]
    if not qmf or not panel then return end
    selectedIsOurs = true
    HideBlizzPanels(qmf)
    panel:Show()
    RefreshSelectGlows()
end

local function HideOurPanel()
    if not selectedIsOurs then return end
    selectedIsOurs = false
    if panel then panel:Hide() end
    RefreshSelectGlows()
end

-- Styled EditBox matching Blizzard's QuestScrollFrame.SearchBox
-- (common-search-border-* atlases + magnifier overlay).
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
    end)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    return editBox
end

-- Settings cog matching QuestScrollFrame.SettingsDropdown
-- (QuestLog-icon-setting atlas). Dropdown population is a TODO.
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
        GameTooltip:AddLine("(not yet wired)", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", GameTooltip_Hide)
    return cog
end

local function CreateTabFrame(qmf)
    local tab = CreateFrame("Frame", "EasyFindMapSearchTab", qmf)
    tab:SetSize(TAB_W, TAB_H)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.MapLegendTab:GetFrameLevel())
    -- Stack below MapLegendTab, same left offset relative to QuestMapFrame.
    tab:SetPoint("TOPLEFT", qmf.MapLegendTab, "BOTTOMLEFT", 0, 2)
    tab:EnableMouse(true)

    -- Side-piece background (same atlas as Quests / MapLegend tabs)
    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("QuestLog-tab-side", false)
    bg:SetSize(TAB_BG_W, TAB_BG_H)
    bg:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)

    -- Icon: magnifying glass. Offset slightly left to match how the
    -- quest / legend icons sit inside the leather tab frame.
    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetAtlas("common-search-magnifyingglass", false)
    icon:SetSize(TAB_ICON_SIZE, TAB_ICON_SIZE)
    icon:SetPoint("CENTER", tab, "CENTER", -4, 0)

    -- Active-state glow (hidden until our tab is selected)
    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas("QuestLog-Tab-side-Glow-Select", false)
    selectGlow:SetSize(TAB_BG_W, TAB_BG_H)
    selectGlow:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    selectGlow:Hide()
    tab._efSelectGlow = selectGlow

    -- Hover glow (managed by WoW's HIGHLIGHT layer automatically)
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

local function CreatePanel(qmf)
    local host = qmf.QuestsFrame or qmf
    local p = CreateFrame("Frame", "EasyFindMapSearchPanel", qmf)
    p:SetFrameStrata(qmf:GetFrameStrata())
    p:SetFrameLevel(qmf:GetFrameLevel() + 5)
    -- Match the region the Blizzard quest list occupies so our search
    -- panel slots cleanly into the same rect.
    p:SetAllPoints(host)
    p:EnableMouse(true)
    p:Hide()

    local searchBox = CreateSearchBox(p)
    searchBox:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -8)
    p.searchBox = searchBox

    local cog = CreateFilterCog(p)
    cog:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
    p.cog = cog

    -- Results container (scrolling list + local/global sections TBD)
    local results = CreateFrame("Frame", nil, p)
    results:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -12)
    results:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -6, 8)
    p.results = results

    local placeholderFS = results:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    placeholderFS:SetPoint("TOP", results, "TOP", 0, -32)
    placeholderFS:SetJustifyH("CENTER")
    placeholderFS:SetWidth(260)
    placeholderFS:SetText("|cff999999Local results above, global below, separator between. Search engine wiring pending.|r")

    return p
end

function MapTab:Initialize()
    if initialized then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf or not qmf.MapLegendTab then return end
    initialized = true

    tabFrame = CreateTabFrame(qmf)
    panel = CreatePanel(qmf)

    -- When Blizzard switches to Quests or MapLegend, drop our panel.
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
