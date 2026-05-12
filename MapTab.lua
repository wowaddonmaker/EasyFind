local _, ns = ...

local MapTab = {}
ns.MapTab = MapTab

local Utils = ns.Utils
local MapUtils = ns.MapUtils
local SafeAfter = Utils and Utils.SafeAfter or function(delay, fn) C_Timer.After(delay, fn) end
local tinsert = Utils and Utils.tinsert or table.insert
local tremove = table.remove

local GOLD_COLOR = ns.GOLD_COLOR or {1.0, 0.82, 0.0}

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local C_Timer = C_Timer

-- ---------------------------------------------------------------------------
-- Tab geometry
-- ---------------------------------------------------------------------------
local TAB_W, TAB_H       = 42, 55
local TAB_ICON_SIZE      = 20
local TAB_ICON_GOLD      = {1.00, 0.82, 0.00}
local TAB_ICON_DIM       = {0.55, 0.45, 0.10}
local TAB_STACK_GAP      = -3

local FormatPathPrefix = MapUtils.FormatPathPrefix
local GetTopAncestor = MapUtils.GetTopAncestor
local GetZoneUnderAncestor = MapUtils.GetZoneUnderAncestor
local GetAncestorNames = MapUtils.GetAncestorNames
local ExpandZoneAbbrev = MapUtils.ExpandZoneAbbrev
local BuildFullBreadcrumb = MapUtils.BuildBreadcrumb

-- Result row layout
local ROW_HEIGHT       = 22
local ROW_ICON_SIZE    = 17
local SECTION_HEADER_H = 22
local MAX_ROW_POOL     = 300
local ROW_POOL_RETAIN  = 80
local HEADER_POOL_RETAIN = 40
local SECTION_POOL_RETAIN = 12


MapTab.GetTopAncestor = function(_, mapID) return GetTopAncestor(mapID) end

-- Children of a map from Blizzard's world hierarchy (non-recursive).
-- Used to populate a group on-demand when the user expands a matched
-- parent zone that didn't have any query-matched children. Cached per
-- session; invalidated on the same events that clear the zone cache.
local worldChildrenCache = {}
local function GetWorldChildren(mapID)
    if not mapID or mapID == 0 then return nil end
    local cached = worldChildrenCache[mapID]
    if cached then return cached end
    local result = {}
    local GetMapChildrenInfo = C_Map and C_Map.GetMapChildrenInfo
    if not GetMapChildrenInfo then
        worldChildrenCache[mapID] = result
        return result
    end
    -- Use the generic zone icon for every child regardless of
    -- Blizzard's mapType. The API marks instanced cities (Dalaran,
    -- etc.) as Dungeon, so an mt-based dungeon glyph mis-fires on
    -- cities. Synthesized expansions of a continent never contain
    -- real dungeons anyway — those live inside zones, not directly
    -- under the continent.
    local children = GetMapChildrenInfo(mapID, nil, false)
    if children then
        for i = 1, #children do
            local child = children[i]
            local mt = child.mapType
            if child.name and mt
               and mt ~= Enum.UIMapType.Micro
               and mt ~= Enum.UIMapType.Orphan then
                result[#result + 1] = {
                    name = child.name,
                    category = "zone",
                    isZone = true,
                    zoneMapID = child.mapID,
                    zoneMapType = mt,
                    icon = 237382,
                    synthesized = true,
                }
            end
        end
    end
    -- Blizzard returns child maps in an internal order (often by mapID
    -- creation, which lines up with expansion-release order, not
    -- alphabetical). Sort by name so the displayed list scans cleanly
    -- under any expanded continent.
    table.sort(result, function(a, b) return a.name < b.name end)
    worldChildrenCache[mapID] = result
    return result
end

do
    local inv = CreateFrame("Frame")
    inv:RegisterEvent("PLAYER_ENTERING_WORLD")
    inv:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    inv:SetScript("OnEvent", function() worldChildrenCache = {} end)
end

local initialized = false
local tabFrame
-- Forward declaration: RefreshCurrentSearch is defined later but
-- captured by closures (e.g. delete button in CreateResultRow) that
-- are compiled before its definition. Without this upvalue, Lua
-- resolves the name as a global and later fails with "attempt to call
-- global 'RefreshCurrentSearch' (a nil value)".
local RefreshCurrentSearch
local ReleaseMapTabMemory
local panel
local selectedIsOurs = false
local lastSelectedWasOurs = false
local restoringBlizzardDisplayMode = false
local function IsMapSearchEnabled()
    return not (EasyFind and EasyFind.db and EasyFind.db.enableMapSearch == false)
end
function MapTab:IsEnabled()
    return IsMapSearchEnabled()
end
-- The Blizzard QuestMapFrame display mode that was active when our panel
-- took over. SetDisplayMode(nil) clears qmf.displayMode, so when the map
-- closes + reopens, Blizzard has no mode to restore and the sidebar
-- renders blank. We stash the prior mode here and put it back on hide.
local prevBlizzardDisplayMode
local rowPool = {}
local headerPool = {}
local rowPoolCursor = 1
local headerPoolCursor = 1
-- Ephemeral collapse state: scoped to the current query text. Reset
-- when the search text changes so fresh matches always default to
-- expanded (auto-expand on parent match). User clicks on +/- within
-- the same query keep their effect until the text changes.
local sessionCollapsed = {}
local sessionCollapsedQuery = nil
local lastQueryGen = 0
local pendingSearchTimer
local pendingSearchFrame
local pendingSearchText
local pendingSearchGrew
local pendingSearchEditBox
local function CancelPendingSearch()
    if pendingSearchFrame then pendingSearchFrame:Hide() end
    pendingSearchTimer = nil
    pendingSearchText = nil
    pendingSearchGrew = nil
    pendingSearchEditBox = nil
end
local function SchedulePendingSearch(editBox, typed, grew)
    if not pendingSearchFrame then
        pendingSearchFrame = CreateFrame("Frame")
        pendingSearchFrame:Hide()
        pendingSearchFrame:SetScript("OnUpdate", function(self)
            self:Hide()
            local box = pendingSearchEditBox
            local text = pendingSearchText or ""
            local shouldAutocomplete = pendingSearchGrew
            pendingSearchTimer = nil
            pendingSearchText = nil
            pendingSearchGrew = nil
            pendingSearchEditBox = nil
            MapTab:RunSearch(text)
            if shouldAutocomplete and box and box.UpdateAutocomplete then
                box:UpdateAutocomplete()
            end
        end)
    end
    pendingSearchTimer = true
    pendingSearchText = typed
    pendingSearchGrew = grew
    pendingSearchEditBox = editBox
    pendingSearchFrame:Show()
end
-- Tracks the query that produced the currently-displayed results. The
-- search box text can diverge from this (e.g. clicking a recent-search
-- row runs a search without populating the box), so result-click and
-- Enter-press paths read this instead of the editbox to push the right
-- string onto the recents list.
local currentQuery = ""
-- Text of the last rendered search. Used to decide whether a re-render
-- is a refresh (keep scroll position) or a brand-new query (reset to
-- the top). Pin toggles, filter changes, and group collapses all hit
-- the refresh path because they re-run RunSearch with unchanged text.
local lastRenderedQuery
-- Keyboard navigation state. navRowIndex 0 = nothing highlighted; 1..N =
-- index into visibleNavRows (array of frames in display order, rows and
-- group headers interleaved). Rebuilt on every RenderRows.
local navRowIndex = 0
local visibleNavRows = {}
local navFrame    -- created lazily by EnsureNavFrame()
-- Hold-to-step controller for nav keys; assigned by EnsureNavFrame.
-- Declared up here so the editbox OnKeyUp hook (defined later in
-- CreateSearchBox) can reach it. SearchBoxTemplate consumes OS-level
-- auto-repeat OnKeyDown events, so unlike UI.lua's plain EditBox we
-- can't rely on the OS to walk the list while a key is held. The
-- ticker fires the action at an accelerating cadence on its own.
local navKeyRepeat

-- ---------------------------------------------------------------------------
-- Tab select glow + icon tint helper
-- ---------------------------------------------------------------------------
local function FindAtlasTexture(frame, atlas)
    if not frame or not frame.GetRegions then return nil end
    for i = 1, frame:GetNumRegions() do
        local region = select(i, frame:GetRegions())
        if region and region.GetAtlas and region.GetObjectType and region:GetObjectType() == "Texture"
           and region:GetAtlas() == atlas then
            return region
        end
    end
    return nil
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
        setGlow(qmf.EventsTab, false)
        setGlow(tabFrame, true)
    else
        setGlow(tabFrame, false)
    end
    if tabFrame and tabFrame._efIcon then
        local c = selectedIsOurs and TAB_ICON_GOLD or TAB_ICON_DIM
        tabFrame._efIcon:SetVertexColor(c[1], c[2], c[3])
    end
end

-- ---------------------------------------------------------------------------
-- Panel show / hide: sibling content-panel behavior.
-- Clicking our tab Hide()'s the three Blizzard content panels (Quests,
-- Events, MapLegend) and Show()'s ours. Clicking a Blizzard tab: their own
-- OnMouseUp Show()'s the right panel; we just hide ours.
-- ---------------------------------------------------------------------------
local function ShowOurPanel()
    if not IsMapSearchEnabled() then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf or not panel then return end
    selectedIsOurs = true
    lastSelectedWasOurs = true
    -- Measure Blizzard's SearchBox BEFORE we hide QuestsFrame, so its
    -- GetLeft/GetRight return live values. Cache is reused for
    -- subsequent shows if Blizzard's panel isn't visible later.
    if panel.MeasureBlizzardSearch then panel.MeasureBlizzardSearch() end
    -- Call SetDisplayMode() with nil so QuestMapFrame formally leaves
    -- its current official mode. This is the pattern LibWorldMapTabs
    -- uses. Without it, clicking a Blizzard tab afterwards is a no-op
    -- (same-mode transition) and the panel stays hidden.
    if qmf.SetDisplayMode then
        prevBlizzardDisplayMode = qmf.displayMode
        local ok, err = pcall(qmf.SetDisplayMode, qmf)
        if not ok then
            if qmf.QuestsFrame then qmf.QuestsFrame:Hide() end
            if qmf.EventsFrame then qmf.EventsFrame:Hide() end
            if qmf.MapLegend   then qmf.MapLegend:Hide()   end
            if Utils and Utils.DebugPrint then
                Utils.DebugPrint("MapTab SetDisplayMode failed: " .. tostring(err))
            end
        end
    else
        if qmf.QuestsFrame then qmf.QuestsFrame:Hide() end
        if qmf.EventsFrame then qmf.EventsFrame:Hide() end
        if qmf.MapLegend   then qmf.MapLegend:Hide()   end
    end

    -- LibWorldMapTabs (used by WorldQuestTab and similar) doesn't react
    -- to a nil SetDisplayMode, so its content frames stay visible and
    -- its tabs stay checked. Hide them via the lib's public API.
    if LibStub then
        local ok, lwmt = pcall(LibStub, "LibWorldMapTabs", true)
        if ok and lwmt and lwmt.SetDisplayMode then
            pcall(lwmt.SetDisplayMode, lwmt, nil)
        end
    end
    if panel.outer then panel.outer:Show() else panel:Show() end
    if panel.AlignToBlizzardSearch then panel.AlignToBlizzardSearch() end
    RefreshSelectGlows()
    local sb = panel.searchBox
    MapTab:RunSearch(sb and (sb.GetTypedText and sb:GetTypedText() or sb:GetText()) or "")
end

local function HideOurPanel()
    if not selectedIsOurs then return end
    selectedIsOurs = false
    if panel then
        if panel.outer then panel.outer:Hide() else panel:Hide() end
        if panel.searchBox then panel.searchBox:ClearFocus() end
    end
    -- Restore Blizzard's display mode if we cleared it. If a Blizzard tab
    -- was clicked, qmf.displayMode is already non-nil (the new tab set
    -- it), so we leave that alone. Only restore when displayMode is nil,
    -- which happens when the map simply closed while our panel was
    -- active. Without this, reopening the map shows a blank sidebar.
    local qmf = _G["QuestMapFrame"]
    if qmf and qmf.SetDisplayMode and qmf.displayMode == nil then
        local restore = prevBlizzardDisplayMode or qmf.QuestsFrame
        if restore then
            restoringBlizzardDisplayMode = true
            pcall(qmf.SetDisplayMode, qmf, restore)
            restoringBlizzardDisplayMode = false
        end
    end
    prevBlizzardDisplayMode = nil
    -- Tear down any in-flight hover preview when the panel closes so the
    -- zone outline / pin / saved-state don't survive into another tab.
    -- Mirrors EndHoverPreview's full cleanup rather than just the
    -- _previewing flag flip + pin clear it used to do.
    if ns.MapSearch and ns.MapSearch._previewing then
        if ns.MapSearch.EndHoverPreview then
            ns.MapSearch:EndHoverPreview()
        else
            ns.MapSearch._previewing = nil
            if ns.MapSearch.ClearHighlight then ns.MapSearch:ClearHighlight() end
        end
    end
    if ReleaseMapTabMemory then ReleaseMapTabMemory(true) end
    RefreshSelectGlows()
end

local function PromptAlias(data)
    if ns.UI and ns.UI.PromptForAlias then
        ns.UI:PromptForAlias(data)
    end
end

local function ShowPopup(isPinned, onPin, onGuide, onAddAlias)
    Utils.ShowPinMenu("EasyFindPinPopup", isPinned, onPin, onGuide, onAddAlias, {
        strata = "TOOLTIP",
        level = 100,
        width = 96,
        rowHeight = 22,
    })
end

-- ---------------------------------------------------------------------------
-- Result rows (pooled)
-- ---------------------------------------------------------------------------
local function CreateResultRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    -- Activate on press, not release. With ButtonUp registration, WoW's
    -- internal focus-transition machinery (when the search box is
    -- focused) absorbs the mouseUp before OnClick fires, requiring a
    -- second click to actually activate the row. Down registration runs
    -- the action immediately on press so focus changes can't interfere.
    row:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    row:EnableMouse(true)
    row:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon = icon

    -- Delete (X) button for recent-search rows only. Hidden by default;
    -- shown on hover when data.isRecentSearch is true. Click removes
    -- that query from EasyFind.db.mapTabRecentSearches.
    local deleteBtn = Utils.CreateClearButton(row, nil)
    deleteBtn:ClearAllPoints()
    deleteBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    deleteBtn:Hide()
    deleteBtn:SetScript("OnClick", function(self)
        local data = row.data
        if not data or not data.isRecentSearch or not data.query then return end
        local list = EasyFind.db and EasyFind.db.mapTabRecentSearches
        if not list then return end
        local lowerQ = data.query:lower()
        for i = #list, 1, -1 do
            if type(list[i]) == "string" and list[i]:lower() == lowerQ then
                tremove(list, i)
            end
        end
        RefreshCurrentSearch()
    end)
    deleteBtn:SetScript("OnLeave", function(self)
        -- Hide only when the mouse has truly left both the row and
        -- this button. Without this, moving from button back onto the
        -- row would leave a stuck visible X (row OnEnter already fired).
        if not row:IsMouseOver() then self:Hide() end
    end)
    row.deleteBtn = deleteBtn

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", deleteBtn, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    -- Single highlight texture covers mouse hover AND keyboard
    -- selection via LockHighlight, so both paths look identical —
    -- Blizzard's tapered quest-log row glow atlas. Mouse hover shows
    -- it automatically; UpdateNavHighlight calls LockHighlight on the
    -- keyboard-selected row to pin it on.
    row:SetHighlightAtlas("QuestLog-quest-glow-yellow")
    local hl = row:GetHighlightTexture()
    if hl then
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(row)
    end

    return row
end

local function SetRowIcon(row, data)
    -- Reset size on every placement. Pooled rows carry whatever size
    -- their last occupant set (recent-search rows shrink to match text
    -- height), so without this reset a recycled row keeps the shrunken
    -- icon when it's reused for a regular result.
    row.icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
    local icon = data.icon
    -- Dungeon/raid/delve/rare entries leave data.icon nil and rely on
    -- the category icon. Resolve it here so SetRowIcon renders the
    -- same texture the MapSearch dropdown does.
    if icon == nil and data.category and ns.MapSearch and ns.MapSearch.GetCategoryIcon then
        icon = ns.MapSearch.GetCategoryIcon(data.category)
    end
    Utils.SetIconTexture(row.icon, icon)
end

-- Timestamp of the most recent keystroke in the search box. Hover
-- previews are suppressed for a short window afterwards, because every
-- keystroke re-renders the result rows and WoW fires OnEnter for any
-- row that appears under a stationary cursor — which was showing preview
-- pins and highlighting the map without the user moving their mouse.
local lastTypeTime = 0
local HOVER_PREVIEW_TYPING_GUARD = 0.3

-- fromKeyboard = true: bypass the typing guard. Keyboard navigation is
-- explicit user intent so we always preview, unlike stray OnEnter
-- events that fire when a re-rendered row lands under a stationary
-- cursor during typing.
local function HoverPreview(data, fromKeyboard)
    if not fromKeyboard and GetTime() - lastTypeTime < HOVER_PREVIEW_TYPING_GUARD then return end
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.RunHoverPreview then
        MapSearch:RunHoverPreview(data)
    end
end

local function ClearHoverPreview()
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.EndHoverPreview then
        MapSearch:EndHoverPreview()
    end
end

RefreshCurrentSearch = function()
    if not panel or not panel.searchBox then return end
    local sb = panel.searchBox
    MapTab:RunSearch(sb.GetTypedText and sb:GetTypedText() or sb:GetText() or "")
end

-- directOverride: optional bool forwarded to MapSearch:SelectResult.
-- Passed as `false` by the right-click Guide menu to force breadcrumb/
-- teaching mode regardless of the user's default left-click setting.
local function TriggerResultSelect(data, directOverride)
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.SelectResult then MapSearch:SelectResult(data, directOverride) end
    -- Intentionally do NOT re-render or hide results here. Unlike UI
    -- search, the MapTab keeps its list visible after activation so
    -- the user can click/preview adjacent results without losing the
    -- search state. The OnMapChanged hook handles the "This Zone"
    -- label refresh when navigation actually changes the map.
end

local function RowOnClick(row, button)
    local data = row.data
    if not data then return end
    local MapSearch = ns.MapSearch

    if data.isRecentSearch then
        if data.query and panel and panel.searchBox then
            -- Populate the search box exactly as if the user had typed
            -- and submitted the recent query. OnTextChanged fires from
            -- SetText and runs the search; the editbox stays unfocused
            -- so the player can keep moving with WASD. Crucially the
            -- clear button now has text to act on.
            panel.searchBox:SetText(data.query)
            panel.searchBox:ClearFocus()
        end
        return
    end

    if button == "RightButton" then
        local isPinned = MapSearch and MapSearch:IsMapItemPinned(data)
        ShowPopup(isPinned, function()
            if isPinned then MapSearch:UnpinMapItem(data) else MapSearch:PinMapItem(data) end
            RefreshCurrentSearch()
        end, function() TriggerResultSelect(data, false) end, function() PromptAlias(data) end)
        return
    end

    -- Left-click on a real result: commit the current query to recents,
    -- then navigate. Ensures recents only accumulate on intentional use
    -- (Enter key or result click), not on incidental focus loss.
    MapTab:PushRecentSearch(currentQuery)
    TriggerResultSelect(data)
end

local function RowOnEnter(row)
    if row.data then
        if row.data.isRecentSearch and row.deleteBtn then
            row.deleteBtn:Show()
        else
            HoverPreview(row.data)
            local crumb = BuildFullBreadcrumb(row.data)
            if crumb and crumb ~= "" then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(crumb, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end
    end
end
local function RowOnLeave(row)
    -- Don't hide the delete button while the cursor is actually on it
    -- (child-frame mouse capture would otherwise flicker the button).
    if row and row.deleteBtn and not row.deleteBtn:IsMouseOver() then
        row.deleteBtn:Hide()
    end
    ClearHoverPreview()
    GameTooltip:Hide()
end

local function AcquireRow(parent)
    local row = rowPool[rowPoolCursor]
    if row then
        row:SetParent(parent)
        rowPoolCursor = rowPoolCursor + 1
        return row
    end
    if #rowPool >= MAX_ROW_POOL then return nil end
    row = CreateResultRow(parent)
    row:SetScript("OnClick", RowOnClick)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)
    tinsert(rowPool, row)
    rowPoolCursor = rowPoolCursor + 1
    return row
end

local function ReleaseAllRows()
    rowPoolCursor = 1
    for i = 1, #rowPool do rowPool[i]:Hide(); rowPool[i].data = nil end
end

-- Section label (non-clickable): "In This Zone" / "Across Azeroth".
local function CreateSectionLabel(parent)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(SECTION_HEADER_H)
    local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", hdr, "CENTER", 0, 0)
    fs:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
    hdr.label = fs
    local lineLeft = hdr:CreateTexture(nil, "ARTWORK")
    lineLeft:SetHeight(1)
    lineLeft:SetPoint("LEFT", hdr, "LEFT", 6, 0)
    lineLeft:SetPoint("RIGHT", fs, "LEFT", -6, 0)
    lineLeft:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    local lineRight = hdr:CreateTexture(nil, "ARTWORK")
    lineRight:SetHeight(1)
    lineRight:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    lineRight:SetPoint("RIGHT", hdr, "RIGHT", -6, 0)
    lineRight:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    return hdr
end

local sectionLabelPool = {}
local sectionLabelPoolCursor = 1

local function AcquireSectionLabel(parent, labelText)
    local hdr = sectionLabelPool[sectionLabelPoolCursor]
    if not hdr then
        hdr = CreateSectionLabel(parent)
        tinsert(sectionLabelPool, hdr)
    else
        hdr:SetParent(parent)
    end
    sectionLabelPoolCursor = sectionLabelPoolCursor + 1
    hdr.label:SetText(labelText or "")
    return hdr
end

local function ReleaseAllSectionLabels()
    sectionLabelPoolCursor = 1
    for i = 1, #sectionLabelPool do sectionLabelPool[i]:Hide() end
end

-- Group header mirrors the UI search's quest-log tab style: QuestLog-tab
-- atlas background, hover overlay, right-side +/- toggle button. Left
-- click on the body navigates to the header's linked zone (when one
-- was attached); clicking the +/- button toggles collapse.
local GROUP_HEADER_H = 28

local function CreateGroupHeader(parent)
    local hdr = CreateFrame("Button", nil, parent)
    hdr:SetHeight(GROUP_HEADER_H)
    -- See CreateResultRow: activate on press to bypass focus-transition
    -- mouseUp absorption.
    hdr:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    hdr:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)

    local bg = hdr:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetAtlas("QuestLog-tab")
    hdr.bg = bg

    local hoverOverlay = hdr:CreateTexture(nil, "ARTWORK", nil, -1)
    hoverOverlay:SetAllPoints()
    hoverOverlay:SetAtlas("QuestLog-tab")
    hoverOverlay:SetBlendMode("ADD")
    hoverOverlay:SetAlpha(0.40)
    hoverOverlay:Hide()
    hdr.hoverOverlay = hoverOverlay

    local toggleBtn = CreateFrame("Button", nil, hdr)
    toggleBtn:SetSize(26, 25)
    toggleBtn:SetPoint("RIGHT", hdr, "RIGHT", -8, 0)
    toggleBtn:SetFrameLevel(hdr:GetFrameLevel() + 2)
    toggleBtn:RegisterForClicks("LeftButtonDown")
    toggleBtn:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)
    -- Expand hit rect so near-miss clicks still register on the toggle
    -- instead of falling through to the header body's navigate action.
    toggleBtn:SetHitRectInsets(-10, -10, -6, -6)
    local toggleBtnBg = toggleBtn:CreateTexture(nil, "ARTWORK")
    toggleBtnBg:SetAllPoints()
    toggleBtnBg:SetTexture(796424)
    toggleBtnBg:Hide()
    toggleBtn.btnBg = toggleBtnBg
    local toggleIcon = toggleBtn:CreateTexture(nil, "OVERLAY")
    toggleIcon:SetSize(18, 17)
    toggleIcon:SetPoint("CENTER")
    toggleIcon:SetAtlas("QuestLog-icon-expand")
    toggleBtn.icon = toggleIcon
    toggleBtn:SetHighlightTexture(130757)
    toggleBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        hdr.hoverOverlay:Show()
    end)
    toggleBtn:SetScript("OnLeave", function(self)
        self.btnBg:Hide()
        if not hdr:IsMouseOver() then
            hdr.hoverOverlay:Hide()
            -- Mirror the header body's OnLeave: when neither the toggle
            -- nor the header itself is hovered, the user has fully left
            -- the group row and the hover preview should clear.
            ClearHoverPreview()
        end
    end)
    hdr.toggleBtn = toggleBtn

    local fs = hdr:CreateFontString(nil, "OVERLAY", "Game15Font_Shadow")
    fs:SetPoint("LEFT", hdr, "LEFT", 10, 0)
    fs:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetMaxLines(1)
    fs:SetTextColor(0.60, 0.58, 0.55, 1.0)
    hdr.label = fs

    hdr:SetScript("OnEnter", function(self)
        self.hoverOverlay:Show()
        self.label:SetTextColor(0.90, 0.88, 0.85, 1.0)
        -- Group headers represent zone results (or pinned-zone roots) and
        -- need the same hover preview as plain rows. Without this, hovering
        -- a "Durotar" header while viewing Kalimdor produced no zone-area
        -- highlight even though hovering a leaf row did.
        if self.navigateData then HoverPreview(self.navigateData) end
    end)
    hdr:SetScript("OnLeave", function(self)
        if not self.toggleBtn:IsMouseOver() then
            self.hoverOverlay:Hide()
            self.label:SetTextColor(self._matchColor and GOLD_COLOR[1] or 0.60,
                                     self._matchColor and GOLD_COLOR[2] or 0.58,
                                     self._matchColor and GOLD_COLOR[3] or 0.55, 1.0)
            ClearHoverPreview()
        end
    end)

    return hdr
end

-- onToggle: called when the +/- button is clicked. Defaults to
-- mutating sessionCollapsed[groupKey] for query-scoped collapse state;
-- pinned-parent headers override with a callback that mutates the
-- pin's stored `collapsed` flag instead.
-- onRightClick: called when the header body is right-clicked. Used to
-- open the pin/unpin popup for the header's navigateData.
local function AcquireGroupHeader(parent, labelText, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick)
    local hdr = headerPool[headerPoolCursor]
    if not hdr then
        hdr = CreateGroupHeader(parent)
        tinsert(headerPool, hdr)
    else
        hdr:SetParent(parent)
    end
    headerPoolCursor = headerPoolCursor + 1
    hdr.label:SetText(labelText or "")
    hdr.toggleBtn.icon:SetAtlas(collapsed and "QuestLog-icon-expand" or "QuestLog-icon-shrink")
    -- Hide the toggle button entirely when there are no children to
    -- expand — clicking it would otherwise look broken.
    hdr.toggleBtn:SetShown(hasChildren and true or false)
    hdr.groupKey = groupKey
    hdr.navigateData = navigateData
    hdr._matchColor = navigateData ~= nil
    if navigateData then
        hdr.label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)
    else
        hdr.label:SetTextColor(0.60, 0.58, 0.55, 1.0)
    end
    hdr.toggleBtn:SetScript("OnClick", function(_)
        if onToggle then
            onToggle()
        elseif hdr.groupKey then
            sessionCollapsed[hdr.groupKey] = not sessionCollapsed[hdr.groupKey]
            RefreshCurrentSearch()
        end
    end)
    hdr:SetScript("OnClick", function(self, button)
        -- Body click ONLY navigates — never toggles. Skip entirely if
        -- the toggle button is under the cursor (WoW has occasionally
        -- surprising click routing with nested clickable children).
        if self.toggleBtn and self.toggleBtn:IsMouseOver() then return end
        if button == "RightButton" then
            if onRightClick then onRightClick() end
            return
        end
        if self.navigateData then
            TriggerResultSelect(self.navigateData)
        end
    end)
    return hdr
end

local function ReleaseAllHeaders()
    headerPoolCursor = 1
    for i = 1, #headerPool do headerPool[i]:Hide() end
    ReleaseAllSectionLabels()
end

local function DetachFrame(frame)
    if frame and frame.SetParent then
        pcall(frame.SetParent, frame, nil)
    end
end

local function TrimRowPool()
    for i = #rowPool, ROW_POOL_RETAIN + 1, -1 do
        local row = rowPool[i]
        if row then
            row:Hide()
            row.data = nil
            DetachFrame(row)
        end
        rowPool[i] = nil
    end
    rowPoolCursor = 1
end

local function TrimHeaderPool()
    for i = #headerPool, HEADER_POOL_RETAIN + 1, -1 do
        local hdr = headerPool[i]
        if hdr then
            hdr:Hide()
            hdr.navigateData = nil
            hdr.groupKey = nil
            DetachFrame(hdr)
        end
        headerPool[i] = nil
    end
    for i = #sectionLabelPool, SECTION_POOL_RETAIN + 1, -1 do
        local hdr = sectionLabelPool[i]
        if hdr then
            hdr:Hide()
            DetachFrame(hdr)
        end
        sectionLabelPool[i] = nil
    end
    headerPoolCursor = 1
    sectionLabelPoolCursor = 1
end

ReleaseMapTabMemory = function(trimFrames)
    if pendingSearchTimer then CancelPendingSearch() end
    ReleaseAllRows()
    ReleaseAllHeaders()
    if panel and panel.scrollChild then panel.scrollChild:SetHeight(1) end
    if panel and panel.emptyMsg then panel.emptyMsg:Hide() end
    if panel then
        panel.topResultName = nil
        panel.topResultCandidates = nil
    end
    navRowIndex = 0
    if visibleNavRows then wipe(visibleNavRows) end
    if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
    if navKeyRepeat then navKeyRepeat.Stop() end
    if trimFrames then
        TrimRowPool()
        TrimHeaderPool()
    end
    if ns.MapSearch and ns.MapSearch.ReleaseIdleSearchMemory then
        ns.MapSearch:ReleaseIdleSearchMemory()
    end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------
-- Returns the stored SavedVariables pin list directly (not a copy) so
-- mutations to fields like `collapsed` on a pinned parent persist.
local function BuildPinnedSection()
    local pins = EasyFind.db.pinnedMapItems
    if not pins or #pins == 0 then return nil end
    return pins
end

local function GroupBySharedParent(results)
    if not results or #results == 0 then return {} end
    local order, groups = {}, {}
    for i = 1, #results do
        local r = results[i]
        local rMapID = r.mapID or r.zoneMapID or r.entranceMapID or r.parentMapID
        local groupName, groupMapID = GetTopAncestor(rMapID)
        if not groupName or groupName == "" then
            order[#order + 1] = { type = "flat", data = r }
        else
            local g = groups[groupName]
            if not g then
                g = {
                    type = "group", name = groupName, items = {},
                    ancestorMapID = groupMapID, navigateData = nil,
                }
                groups[groupName] = g
                order[#order + 1] = g
            end
            if r.name == groupName then
                -- Result IS the parent zone itself: attach as the header's
                -- navigation target instead of rendering a duplicate row.
                g.navigateData = r
            else
                g.items[#g.items + 1] = r
            end
        end
    end
    -- Synthesize navigateData for groups whose parent zone wasn't itself
    -- in the result set (e.g. "Northrend" filtered from local as a
    -- Continent). The header still needs something to click-navigate to.
    for _, e in ipairs(order) do
        if e.type == "group" and not e.navigateData and e.ancestorMapID then
            e.navigateData = {
                name = e.name,
                category = "zone",
                isZone = true,
                zoneMapID = e.ancestorMapID,
                synthesized = true,
            }
        end
    end
    -- Demotion rule: a group keeps its header whenever it has a parent
    -- zone (navigateData) — even with zero children in the current
    -- result set — so a continent with children in the world hierarchy
    -- never displays as a solitary flat row. Single-child groups
    -- without a matching parent still collapse to flat so standalone
    -- leaves don't gain a useless wrapping header.
    for i = 1, #order do
        local e = order[i]
        if e.type == "group" and not e.navigateData and #e.items == 1 then
            order[i] = { type = "flat", data = e.items[1] }
        end
    end
    -- Second-level: within each continent group, sub-bucket items by the
    -- direct-child zone of the continent that contains them. A real zone
    -- result (category="zone") becomes the subgroup header; everything
    -- else (FMs, vendors, etc.) becomes children indented under it.
    -- Items whose parent chain doesn't pass through any direct child of
    -- the continent stay loose at the continent level.
    for _, e in ipairs(order) do
        if e.type == "group" and e.items and #e.items > 0 and e.ancestorMapID then
            local subgroups, subgroupOrder, looseItems = {}, {}, {}
            for _, item in ipairs(e.items) do
                local itemMapID = item.mapID or item.zoneMapID or item.entranceMapID or item.parentMapID
                local zoneName, zoneMapID = GetZoneUnderAncestor(itemMapID, e.ancestorMapID)
                if zoneName then
                    local sub = subgroups[zoneName]
                    if not sub then
                        sub = { name = zoneName, mapID = zoneMapID, items = {}, headerData = nil }
                        subgroups[zoneName] = sub
                        subgroupOrder[#subgroupOrder + 1] = sub
                    end
                    if itemMapID == zoneMapID and item.isZone and item.category == "zone" then
                        sub.headerData = item
                    else
                        sub.items[#sub.items + 1] = item
                    end
                else
                    looseItems[#looseItems + 1] = item
                end
            end
            -- Any subgroup with at least one child gets a collapsible
            -- header (synthesized if the zone itself wasn't matched).
            -- A zone match with zero children renders as a plain loose
            -- row — no point in a collapsible header for nothing.
            local keptOrder = {}
            for _, sub in ipairs(subgroupOrder) do
                if #sub.items == 0 and sub.headerData then
                    looseItems[#looseItems + 1] = sub.headerData
                elseif #sub.items >= 1 then
                    if not sub.headerData then
                        sub.headerData = {
                            name = sub.name,
                            category = "zone",
                            isZone = true,
                            zoneMapID = sub.mapID,
                            synthesized = true,
                        }
                    end
                    keptOrder[#keptOrder + 1] = sub
                end
            end
            if #keptOrder > 0 then
                e.subgroups = keptOrder
                e.looseItems = looseItems
            end
        end
    end
    return order
end

local function RenderRows(scrollChild, pinned, localEntries, globalEntries, recentList)
    ReleaseAllRows()
    ReleaseAllHeaders()
    -- Reset keyboard-nav selection on every render. The underlying row
    -- pool is recycled so a stale frame ref in visibleNavRows could
    -- silently point at a frame that's been repositioned or released.
    -- Also release navFrame's keyboard capture so we don't keep
    -- swallowing keys when there's no highlighted row.
    navRowIndex = 0
    wipe(visibleNavRows)
    if navFrame then
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
    end
    if navKeyRepeat then navKeyRepeat.Stop() end
    local y = 4
    local collapsedDb = sessionCollapsed

    local function placeRow(data, indent, groupName)
        local row = AcquireRow(scrollChild)
        if not row then return end
        local leftInset = 4 + (indent or 0)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftInset, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        row.data = data
        if row.UnlockHighlight then row:UnlockHighlight() end
        visibleNavRows[#visibleNavRows + 1] = row
        if row.deleteBtn then row.deleteBtn:Hide() end
        SetRowIcon(row, data)
        local name = data.name or ""
        row.icon:Show()
        if data.isZone then
            row.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
        else
            row.text:SetTextColor(1, 1, 1)
        end
        do
            local pathText = FormatPathPrefix(data.pathPrefix) or ""
            -- Under a group header, strip the redundant group prefix so
            -- a Dalaran row under "Northrend" shows only its immediate
            -- parent without repeating the group name.
            if groupName and pathText ~= "" then
                local prefix = groupName .. " > "
                if pathText:sub(1, #prefix) == prefix then
                    pathText = pathText:sub(#prefix + 1)
                elseif pathText == groupName then
                    pathText = ""
                end
            end
            -- Collapse to just the immediate parent name. Breadcrumb
            -- chains ("Northrend > Crystalsong Forest") become
            -- single-segment ("Crystalsong Forest") for a quieter row.
            if pathText ~= "" then
                local last = pathText:match("[^>]+$")
                if last then pathText = last:gsub("^%s+", ""):gsub("%s+$", "") end
            end
            if pathText ~= "" then
                row.text:SetText(name .. "  |cff808080" .. pathText .. "|r")
            else
                row.text:SetText(name)
            end
        end
        row:Show()
        y = y + ROW_HEIGHT
    end

    local function placeSectionLabel(text)
        local hdr = AcquireSectionLabel(scrollChild, text)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
        hdr:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        hdr:Show()
        y = y + SECTION_HEADER_H
    end

    local function placeGroupHeader(name, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick, indent)
        local hdr = AcquireGroupHeader(scrollChild, name, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick)
        hdr:ClearAllPoints()
        local leftInset = 4 + (indent or 0)
        hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftInset, -y)
        hdr:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        if hdr.hoverOverlay then hdr.hoverOverlay:Hide() end
        visibleNavRows[#visibleNavRows + 1] = hdr
        hdr:Show()
        y = y + GROUP_HEADER_H
    end

    -- Right-click handler for regular result group headers: open the
    -- pin popup bound to the header's zone (navigateData). Pinning a
    -- parent here promotes it into the Pinned section on refresh,
    -- carrying over the header's current collapsed state so the pinned
    -- copy opens the same way the user was viewing it.
    local function headerRightClick(navigateData, capturedCollapsed)
        if not navigateData then return end
        local MapSearch = ns.MapSearch
        if not MapSearch then return end
        local isPinned = MapSearch:IsMapItemPinned(navigateData)
        ShowPopup(isPinned, function()
            if isPinned then
                MapSearch:UnpinMapItem(navigateData)
            else
                navigateData.collapsed = capturedCollapsed or nil
                MapSearch:PinMapItem(navigateData)
                navigateData.collapsed = nil
            end
            RefreshCurrentSearch()
        end, function() TriggerResultSelect(navigateData, false) end, function() PromptAlias(navigateData) end)
    end

    local function renderEntries(entries, sectionKey)
        for _, e in ipairs(entries) do
            if e.type == "flat" then
                placeRow(e.data, 0, nil)
            elseif e.type == "version" then
                -- Version group: same name, multiple mapIDs (e.g. Dalaran
                -- exists in Northrend and Broken Isles). Default-collapsed
                -- so the bare name shows; expanding lists each variant —
                -- their pathPrefix already disambiguates ("Crystalsong
                -- Forest" / "Broken Isles"). Header navigates to newest.
                local groupKey = sectionKey .. ":version:" .. e.name
                local stored = collapsedDb[groupKey]
                local collapsed = stored ~= false  -- nil → default collapsed
                local capturedCollapsed = collapsed
                local onToggle = function()
                    collapsedDb[groupKey] = not capturedCollapsed and true or false
                    RefreshCurrentSearch()
                end
                local nav = e.navigateData
                local onRClick = nav and function() headerRightClick(nav, capturedCollapsed) end or nil
                placeGroupHeader(e.name, groupKey, nil, collapsed, nav, true, onToggle, onRClick)
                if not collapsed then
                    for _, item in ipairs(e.items) do
                        placeRow(item, 18, nil)
                    end
                end
            else
                local groupKey = sectionKey .. ":" .. e.name
                local collapsed = collapsedDb[groupKey] == true
                -- Two cases for what shows under a group:
                --  (1) Parent itself matches the query (real, not
                --      synthesized, navigateData): show ALL world-
                --      hierarchy children. "I asked for Eastern
                --      Kingdoms, give me the whole continent."
                --  (2) Parent didn't match — group exists only because
                --      multiple children matched (or one child + a
                --      synthesized parent header for click-to-navigate):
                --      show just the matched children. Surfacing every
                --      sibling under EK because the user typed "fp"
                --      (matching Founder's Point inside EK) was wrong.
                local items
                local usingWorldChildren = false
                local parentMatched = e.navigateData and not e.navigateData.synthesized
                local autoExpand = EasyFind.db.mapTabAutoExpand ~= false
                if parentMatched and e.ancestorMapID and autoExpand then
                    local world = GetWorldChildren(e.ancestorMapID)
                    items = world or e.items
                    usingWorldChildren = world and #world > 0
                else
                    items = e.items
                end
                local hasChildren = items and #items > 0
                local nav = e.navigateData
                local capturedCollapsed = collapsed
                local onRClick = nav and function() headerRightClick(nav, capturedCollapsed) end or nil
                placeGroupHeader(e.name, groupKey, nil, collapsed, nav, hasChildren, nil, onRClick)
                if hasChildren and not collapsed then
                    if not usingWorldChildren and e.subgroups then
                        for _, sub in ipairs(e.subgroups) do
                            local subKey = groupKey .. ":" .. sub.name
                            local subCollapsed = collapsedDb[subKey] == true
                            local subHasChildren = #sub.items > 0
                            local subNav = sub.headerData
                            local subCaptured = subCollapsed
                            local subRClick = subNav and function() headerRightClick(subNav, subCaptured) end or nil
                            placeGroupHeader(sub.name, subKey, nil, subCollapsed, subNav,
                                subHasChildren, nil, subRClick, 18)
                            if subHasChildren and not subCollapsed then
                                for _, item in ipairs(sub.items) do
                                    placeRow(item, 36, sub.name)
                                end
                            end
                        end
                        if e.looseItems then
                            for _, item in ipairs(e.looseItems) do
                                placeRow(item, 18, e.name)
                            end
                        end
                    else
                        -- Group duplicate-named children into nested
                        -- version sub-groups. Blizzard's hierarchy keeps
                        -- multiple mapIDs sharing a display name (Arathi
                        -- Highlands warfront variants, old Dalaran Crater
                        -- + revisions, etc.). Show one collapsible header
                        -- per name; expanding lists each variant tagged
                        -- by mapID so they're distinguishable. Default-
                        -- collapsed; clicking the header navigates to
                        -- the highest-mapID (newest) variant.
                        local byName, order = {}, {}
                        for _, item in ipairs(items) do
                            local n = item.name or ""
                            local list = byName[n]
                            if not list then
                                list = {}
                                byName[n] = list
                                order[#order + 1] = n
                            end
                            list[#list + 1] = item
                        end
                        for _, n in ipairs(order) do
                            local variants = byName[n]
                            if #variants == 1 then
                                placeRow(variants[1], 18, e.name)
                            else
                                table.sort(variants, function(a, b)
                                    return (a.zoneMapID or 0) > (b.zoneMapID or 0)
                                end)
                                local subKey = groupKey .. ":var:" .. n
                                local stored = collapsedDb[subKey]
                                local subCollapsed = stored ~= false
                                local subCaptured = subCollapsed
                                local subToggle = function()
                                    collapsedDb[subKey] = not subCaptured and true or false
                                    RefreshCurrentSearch()
                                end
                                local subNav = variants[1]
                                local subRClick = function() headerRightClick(subNav, subCaptured) end
                                placeGroupHeader(n, subKey, nil, subCollapsed, subNav,
                                    true, subToggle, subRClick, 18)
                                if not subCollapsed then
                                    for _, variant in ipairs(variants) do
                                        -- Clone so we don't mutate the
                                        -- per-session worldChildrenCache
                                        -- entry. pathPrefix flows through
                                        -- placeRow's gray-suffix path.
                                        placeRow({
                                            name = variant.name,
                                            category = variant.category,
                                            isZone = variant.isZone,
                                            zoneMapID = variant.zoneMapID,
                                            zoneMapType = variant.zoneMapType,
                                            icon = variant.icon,
                                            synthesized = variant.synthesized,
                                            pathPrefix = "map #" .. tostring(variant.zoneMapID),
                                        }, 36, n)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if recentList and #recentList > 0 then
        placeSectionLabel("Recent Searches")
        for _, query in ipairs(recentList) do
            local row = AcquireRow(scrollChild)
            if row then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
                row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
                if row.UnlockHighlight then row:UnlockHighlight() end
                visibleNavRows[#visibleNavRows + 1] = row
                row.data = {
                    isRecentSearch = true,
                    query = query,
                    name = query,
                    icon = "atlas:common-search-magnifyingglass",
                }
                SetRowIcon(row, row.data)
                row.icon:Show()
                if row.deleteBtn then row.deleteBtn:Hide() end
                row.text:SetTextColor(0.85, 0.85, 0.85)
                row.text:SetText(query)
                -- Match the magnifying glass to the text's rendered
                -- height so the icon's top/bottom line up with the text
                -- rather than overshooting like the result-row icons.
                local textH = row.text:GetStringHeight() or 0
                if textH < 8 then textH = 12 end
                row.icon:SetSize(textH, textH)
                row:Show()
                y = y + ROW_HEIGHT
            end
        end
    end
    if pinned and #pinned > 0 then
        placeSectionLabel("Pinned")
        for _, d in ipairs(pinned) do
            local renderAsParent = d.isZone and d.zoneMapID
            local children = renderAsParent and GetWorldChildren(d.zoneMapID) or nil
            if renderAsParent and children and #children > 0 then
                local pinRef = d
                local collapsed = pinRef.collapsed == true
                local onToggle = function()
                    pinRef.collapsed = not collapsed
                    RefreshCurrentSearch()
                end
                local onRightClick = function()
                    local MapSearch = ns.MapSearch
                    if not MapSearch then return end
                    ShowPopup(true, function()
                        MapSearch:UnpinMapItem(pinRef)
                        RefreshCurrentSearch()
                    end, function() TriggerResultSelect(pinRef, false) end, function() PromptAlias(pinRef) end)
                end
                placeGroupHeader(pinRef.name, "pinned:" .. pinRef.zoneMapID,
                    nil, collapsed, pinRef, true, onToggle, onRightClick)
                if not collapsed then
                    for _, child in ipairs(children) do
                        placeRow(child, 18, pinRef.name)
                    end
                end
            else
                placeRow(d, 0, nil)
            end
        end
    end
    if localEntries and #localEntries > 0 then
        local currentMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        local currentMapInfo = currentMapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(currentMapID)
        local sectionLabel = currentMapInfo and ("This Zone (" .. currentMapInfo.name .. ")") or "This Zone"
        placeSectionLabel(sectionLabel)
        renderEntries(localEntries, "local")
    end
    if globalEntries and #globalEntries > 0 then
        placeSectionLabel("Across the World")
        renderEntries(globalEntries, "global")
    end
    scrollChild:SetHeight(math.max(1, y + 4))
end

-- mapType values that, when a ZONE result belongs to them, should not
-- appear in the "This Zone" local section. These are too coarse to be
-- meaningfully "local" (e.g. when the user is on the Azeroth world map,
-- Northrend is technically a direct child but is its own continent).
local EXCLUDE_FROM_LOCAL_MAPTYPES = {}
if Enum and Enum.UIMapType then
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.Cosmic] = true
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.World] = true
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.Continent] = true
end

local function ResultDedupeKey(r)
    if not r then return "" end
    local name = r.name or ""
    if r.category == "flightmaster" then
        return "fm:" .. name
    end
    if r.isDungeonEntrance then
        return "instance:" .. tostring(r.entranceMapID or r.mapID or r.coordMapID or 0)
            .. ":" .. name
    end
    if r.isZone and r.zoneMapID then
        return "zone:" .. tostring(r.zoneMapID)
    end
    local mapID = r.mapID or r.coordMapID or r.entranceMapID
        or r.zoneMapID or r.parentMapID or 0
    local x = r.x or r.entranceX or 0
    local y = r.y or r.entranceY or 0
    return tostring(r.category or "location") .. ":" .. tostring(mapID)
        .. ":" .. name .. ":" .. tostring(x) .. ":" .. tostring(y)
end

local function IsMapTabAliasData(data)
    return data and (data.mapSearchResult or data.isZone or data.isDungeonEntrance
        or data.zoneMapID or data.entranceMapID
        or (data.category and (data.x or data.entranceX or data.mapID or data.coordMapID)))
end

local function ResultIsOnViewedMap(data, viewedMapID)
    if not data or not viewedMapID then return false end
    return data.mapID == viewedMapID
        or data.coordMapID == viewedMapID
        or data.entranceMapID == viewedMapID
        or data.zoneMapID == viewedMapID
        or data.parentMapID == viewedMapID
end

-- Filter by mapTabFilters (category bucket) and strip duplicates that
-- already appear in a previous list. Preserves result ordering from
-- BuildResults. When isLocal is true, also excludes continent-level and
-- broader zone results so the "This Zone" section doesn't list entire
-- continents as local content.
local function FilterAndDedupe(results, seen, isLocal)
    local MapSearch = ns.MapSearch
    local getBucket = MapSearch and MapSearch.GetFilterBucket
    local filters = EasyFind.db.mapTabFilters or {}
    local out = {}
    if not results then return out end
    for i = 1, #results do
        local r = results[i]
        if r and not r.isPinHeader then
            local excludeLocal = isLocal and r.isZone and r.zoneMapType
                and EXCLUDE_FROM_LOCAL_MAPTYPES[r.zoneMapType]
            if not excludeLocal then
                -- FMs are now scanned both locally (current map) and globally
                -- (every zone). The local scan uses the viewed map's coords
                -- while the global scan uses each home zone's own coords —
                -- so the same FM has different (x,y) in each set. Key FMs
                -- by name alone so the local pass claims it first and the
                -- global pass dedupes cleanly.
                local key = ResultDedupeKey(r)
                if not seen[key] then
                    seen[key] = true
                    local bucket = getBucket and getBucket(r) or "other"
                    if filters[bucket] ~= false then
                        out[#out + 1] = r
                    end
                end
            end
        end
    end
    return out
end

-- Does a single token match a POI via any available facet? Token must
-- already be lowercase. Checks name, keywords, category (with plural/
-- singular flex), pathPrefix, ancestor zone names, and — for ancestors —
-- falls back to expanding the token through ZONE_ABBREVIATIONS so "nr"
-- resolves against "northrend".
local function POIMatchesToken(poi, t)
    if poi.name and poi.name:lower():find(t, 1, true) then return true end
    if poi.keywords then
        for i = 1, #poi.keywords do
            if poi.keywords[i]:lower():find(t, 1, true) then return true end
        end
    end
    if poi.category then
        local c = poi.category:lower()
        if c == t or c == t .. "s" then return true end
        if #t > 1 and t:sub(-1) == "s" and c == t:sub(1, -2) then return true end
    end
    if poi.pathPrefix and poi.pathPrefix:lower():find(t, 1, true) then return true end
    local mapID = poi.mapID or poi.zoneMapID or poi.entranceMapID
    local names = GetAncestorNames(mapID)
    for i = 1, #names do
        if names[i]:find(t, 1, true) then return true end
    end
    local expanded = ExpandZoneAbbrev(t)
    if expanded then
        if poi.name and poi.name:lower():find(expanded, 1, true) then return true end
        for i = 1, #names do
            if names[i]:find(expanded, 1, true) then return true end
        end
    end
    return false
end

-- Multi-token search: for each token, call BuildResults to get a broad
-- candidate set, union them by identity, then keep only POIs where every
-- token matches some facet. Enables queries like "northrend raid",
-- "org fp", "dalaran bank" where each word narrows the result set.
local function BuildMultiTokenResults(tokens, isGlobal)
    local MapSearch = ns.MapSearch
    if not MapSearch or not MapSearch.BuildResults then return {} end
    local seenKeys = {}
    local candidates = {}
    for _, tok in ipairs(tokens) do
        local perRef = MapSearch:BuildResults(tok, isGlobal, true)
        for i = 1, #perRef do
            local r = perRef[i]
            local k = (r.mapID or 0) .. ":" .. (r.name or "")
                   .. ":" .. (r.x or 0) .. ":" .. (r.y or 0)
                   .. ":" .. (r.category or "")
            if not seenKeys[k] then
                seenKeys[k] = true
                candidates[#candidates + 1] = r
            end
        end
    end
    local tokensLower = {}
    for i, tok in ipairs(tokens) do tokensLower[i] = tok:lower() end
    local out = {}
    for _, r in ipairs(candidates) do
        local matches = true
        for i = 1, #tokensLower do
            if not POIMatchesToken(r, tokensLower[i]) then
                matches = false
                break
            end
        end
        if matches then out[#out + 1] = r end
    end
    return out
end

function MapTab:RunSearch(text)
    if not panel then return end
    text = text or ""
    currentQuery = text
    lastQueryGen = lastQueryGen + 1
    local myGen = lastQueryGen
    local scrollChild = panel.scrollChild
    local scrollFrame = panel.scrollFrame
    local MapSearch = ns.MapSearch
    local pinned = BuildPinnedSection()
    local aliasMatches
    if ns.Aliases and text ~= "" then
        aliasMatches = ns.Aliases:GetMatches(text:lower())
    end

    -- Preserve scroll when the query is unchanged (refresh path: pin
    -- toggles, group collapse, filter changes). Reset to the top on a
    -- fresh query so new result sets always start from the first row.
    local preserveScroll = scrollFrame and text == lastRenderedQuery
    local savedScroll = preserveScroll and scrollFrame:GetVerticalScroll() or 0
    lastRenderedQuery = text
    local function restoreScroll()
        if not scrollFrame then return end
        local maxScroll = math.max(0, (scrollChild:GetHeight() or 0) - (scrollFrame:GetHeight() or 0))
        scrollFrame:SetVerticalScroll(math.min(savedScroll, maxScroll))
    end

    -- Reset ephemeral collapse state when the query text changes so
    -- each new search starts with every matched parent auto-expanded.
    -- Same-text refreshes (e.g. toggle button → RefreshCurrentSearch)
    -- preserve the state.
    if text ~= sessionCollapsedQuery then
        wipe(sessionCollapsed)
        sessionCollapsedQuery = text
    end

    if #text < 2 and not aliasMatches then
        local showRecent = EasyFind.db.mapTabShowRecent
        local recentList = showRecent and EasyFind.db.mapTabRecentSearches
        local limit = MapTab.GetRecentLimit and MapTab.GetRecentLimit() or 3
        -- Respect the tunable display cap even if the saved list got
        -- larger (e.g., user shrank the cap after it was already full).
        if recentList and #recentList > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = recentList[i] end
            recentList = trimmed
        end
        local hasRecent = recentList and #recentList > 0
        if pinned or hasRecent then
            RenderRows(scrollChild, pinned, nil, nil, hasRecent and recentList or nil)
        else
            ReleaseAllRows(); ReleaseAllHeaders()
            scrollChild:SetHeight(1)
        end
        panel.emptyMsg:Hide()
        panel.topResultName = nil
        panel.topResultCandidates = nil
        restoreScroll()
        return
    end
    panel.emptyMsg:Hide()
    if not MapSearch or not MapSearch.BuildResults then
        ReleaseAllRows(); ReleaseAllHeaders(); return
    end

    -- Split query into whitespace-separated tokens; multi-token queries
    -- switch to per-token matching with ancestor awareness so "northrend
    -- raid" means "raids under Northrend" rather than a literal name
    -- match on the full string.
    local tokens = {}
    for tok in text:gmatch("%S+") do tokens[#tokens + 1] = tok end
    local multiToken = #tokens > 1

    -- BuildResults returns a reference to a reusable module-level
    -- table. The second call wipes it before refilling, so we must
    -- shallow-copy the first result set before calling again.
    local seen = {}
    local localRaw
    if multiToken then
        localRaw = BuildMultiTokenResults(tokens, false)
    else
        local localRawRef = MapSearch:BuildResults(text, false, true)
        localRaw = {}
        for i = 1, #localRawRef do localRaw[i] = localRawRef[i] end
    end
    if myGen ~= lastQueryGen then return end
    -- Local-first dedup (so a POI that's truly in the current zone
    -- wins local ownership over global). Continent-level zone
    -- results are filtered out of local via isLocal=true so they
    -- don't pollute "This Zone" on a world/continent map.
    local localFiltered = FilterAndDedupe(localRaw, seen, true)
    local localEntries
    local globalRaw
    if multiToken then
        globalRaw = BuildMultiTokenResults(tokens, true)
    else
        globalRaw = MapSearch:BuildResults(text, true, true)
    end
    if myGen ~= lastQueryGen then return end
    local globalFiltered = FilterAndDedupe(globalRaw, seen, false)

    if aliasMatches then
        local viewedMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        for i = #aliasMatches, 1, -1 do
            local data = aliasMatches[i] and aliasMatches[i].data
            if IsMapTabAliasData(data) then
                local key = ResultDedupeKey(data)
                if not seen[key] then
                    seen[key] = true
                    if ResultIsOnViewedMap(data, viewedMapID) then
                        tinsert(localFiltered, 1, data)
                    else
                        tinsert(globalFiltered, 1, data)
                    end
                end
            end
        end
    end

    localEntries = GroupBySharedParent(localFiltered)
    -- A continent/world-type zone match (e.g. "Eastern Kingdoms" while
    -- viewing EK) is dropped from local by EXCLUDE_FROM_LOCAL_MAPTYPES,
    -- so its "This Zone" group ends up with synthesized navigateData
    -- and parentMatched stays false - auto-expand never fires. Promote
    -- the synthesized header back to the real result so the renderer's
    -- parentMatched check sees it.
    for i = 1, #localRaw do
        local r = localRaw[i]
        if r and r.isZone and r.zoneMapID then
            for j = 1, #localEntries do
                local e = localEntries[j]
                if e.type == "group" and e.ancestorMapID == r.zoneMapID
                   and e.navigateData and e.navigateData.synthesized then
                    e.navigateData = r
                end
            end
        end
    end

    -- Pull duplicate-named zones out of globalFiltered into version groups.
    -- Names matching 2+ entries collapse into one header that lists every
    -- variant (highest-mapID first as a "newest" heuristic). The header
    -- starts collapsed; clicking it navigates to the newest variant.
    local versionGroups
    do
        local byName = {}
        for i = 1, #globalFiltered do
            local r = globalFiltered[i]
            if r and r.isZone and r.zoneMapID and r.name then
                local key = r.name:lower()
                local list = byName[key]
                if not list then list = {}; byName[key] = list end
                list[#list + 1] = r
            end
        end
        local removed = {}
        for _, list in pairs(byName) do
            if #list >= 2 then
                table.sort(list, function(a, b)
                    return (a.zoneMapID or 0) > (b.zoneMapID or 0)
                end)
                for j = 1, #list do removed[list[j]] = true end
                versionGroups = versionGroups or {}
                versionGroups[#versionGroups + 1] = {
                    type = "version",
                    name = list[1].name,
                    items = list,
                    navigateData = list[1],
                }
            end
        end
        if versionGroups then
            local kept = {}
            for i = 1, #globalFiltered do
                if not removed[globalFiltered[i]] then
                    kept[#kept + 1] = globalFiltered[i]
                end
            end
            globalFiltered = kept
        end
    end

    local globalEntries = GroupBySharedParent(globalFiltered)
    if versionGroups then
        for i = #versionGroups, 1, -1 do
            tinsert(globalEntries, 1, versionGroups[i])
        end
    end

    -- Drop any global group whose continent matches the currently-viewed
    -- map. The 'this zone' section already covers everything inside
    -- that continent, so surfacing it again under 'across the world' is
    -- pure redundancy. Belt-and-suspenders against any dedup miss.
    local viewedMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if viewedMapID then
        for i = #globalEntries, 1, -1 do
            local e = globalEntries[i]
            if e.type == "group" and e.ancestorMapID == viewedMapID then
                tremove(globalEntries, i)
            end
        end
    end

    -- Stash top N result names (locals first, then globals) for
    -- autocomplete. Ghost/Tab picks the first name whose lowercase
    -- prefix matches the typed text — so a fuzzy-winning non-prefix
    -- match doesn't prevent a slightly-lower-scored prefix match from
    -- being suggested. Covers cases like typing "dragon i" when the
    -- top scorer is "Dragonblight" (no space) but "Dragon Isles" is
    -- further down.
    local CANDIDATE_CAP = 12
    local candidates = {}
    if localFiltered then
        for i = 1, math.min(#localFiltered, CANDIDATE_CAP) do
            if localFiltered[i] and localFiltered[i].name then
                candidates[#candidates + 1] = localFiltered[i].name
            end
        end
    end
    for i = 1, math.min(#globalFiltered, CANDIDATE_CAP) do
        if globalFiltered[i] and globalFiltered[i].name then
            candidates[#candidates + 1] = globalFiltered[i].name
        end
    end
    panel.topResultCandidates = candidates
    panel.topResultName = candidates[1]

    RenderRows(scrollChild, pinned, localEntries, globalEntries)

    if (not pinned or #pinned == 0)
       and (not localFiltered or #localFiltered == 0) and #globalFiltered == 0 then
        panel.emptyMsg:SetText("|cff999999No matches.|r")
        panel.emptyMsg:Show()
    end
    restoreScroll()
end

-- ---------------------------------------------------------------------------
-- Keyboard navigation helpers. Wiring: the search box captures arrow /
-- Alt+J/K / Enter / Esc while focused and consumes them, falling back
-- to typing for anything else. When the user navigates down from the
-- search box, focus drops onto navFrame, which captures j/k/Enter/Esc
-- directly so the user can keep navigating without reclaiming keyboard
-- focus on the editbox. Re-typing or pressing Esc hands focus back.
-- ---------------------------------------------------------------------------

-- Forward declaration: EnsureNavFrame's OnKeyDown closure captures
-- HandleNavKey as an upvalue, but HandleNavKey is defined below because
-- it in turn references SetNavRowIndex / MoveNavSelection that are
-- declared between the two.
local HandleNavKey

local function EnsureNavFrame()
    if navFrame then return navFrame end
    if not panel then return nil end
    navFrame = CreateFrame("Frame", nil, panel)
    navFrame:EnableKeyboard(false)
    navFrame:SetPropagateKeyboardInput(true)
    navFrame:SetScript("OnKeyDown", function(self, key)
        if HandleNavKey(key, false) then
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        if navKeyRepeat and navKeyRepeat.IsKey(key) then
            navKeyRepeat.Stop(key)
        end
    end)
    navKeyRepeat = Utils.CreateKeyRepeat(navFrame)
    return navFrame
end

local function UpdateNavHighlight()
    for i = 1, #visibleNavRows do
        local f = visibleNavRows[i]
        if f then
            local selected = (i == navRowIndex)
            -- Group headers (hoverOverlay present): mirror mouse hover
            -- exactly — show the same hoverOverlay atlas and brighten
            -- the label. Same pattern UI.lua uses for its headerTab.
            if f.hoverOverlay then
                f.hoverOverlay:SetShown(selected)
                if f.label then
                    if selected then
                        f.label:SetTextColor(0.90, 0.88, 0.85, 1.0)
                    elseif not f:IsMouseOver()
                       and not (f.toggleBtn and f.toggleBtn:IsMouseOver()) then
                        local g = f._matchColor
                        f.label:SetTextColor(
                            g and GOLD_COLOR[1] or 0.60,
                            g and GOLD_COLOR[2] or 0.58,
                            g and GOLD_COLOR[3] or 0.55, 1.0)
                    end
                end
            elseif f.LockHighlight then
                -- Leaf row: reuse the button's built-in hover texture
                -- (set via SetHighlightAtlas in CreateResultRow) so
                -- keyboard and mouse share one texture.
                if selected then f:LockHighlight() else f:UnlockHighlight() end
            end
        end
    end
    if navRowIndex > 0 and panel and panel.scrollFrame then
        local f = visibleNavRows[navRowIndex]
        if f then Utils.ScrollToButton(panel.scrollFrame, f) end
    end
    -- Map preview mirrors the mouse-hover path: whichever row the
    -- user is focused on (keyboard or mouse) pops its waypoint/zone
    -- highlight on the world map. Keyboard passes fromKeyboard=true to
    -- bypass the typing-guard that suppresses spurious OnEnter events.
    if navRowIndex > 0 then
        local f = visibleNavRows[navRowIndex]
        local data = f and (f.data or f.navigateData)
        if data then
            HoverPreview(data, true)
        else
            ClearHoverPreview()
        end
    else
        ClearHoverPreview()
    end
end

local function SetNavFrameCapture(on)
    local nf = EnsureNavFrame()
    if not nf then return end
    Utils.SafeCallMethod(nf, "EnableKeyboard", on and true or false)
    -- Releasing keyboard capture defuses any in-flight hold-to-step
    -- ticker. Without this, a missed OnKeyUp (e.g. user clicked the
    -- map mid-hold so the editbox+navFrame both lost keyboard input
    -- before the release fired) would leave repeatActive on, and the
    -- ticker would resume firing the move action the next time
    -- navFrame became visible.
    if not on and navKeyRepeat then navKeyRepeat.Stop() end
end

local function SetNavRowIndex(i)
    if i < 0 then i = 0 end
    if i > #visibleNavRows then i = #visibleNavRows end
    navRowIndex = i
    UpdateNavHighlight()
end

local function MoveNavSelection(delta)
    if #visibleNavRows == 0 then return end
    local newIdx = navRowIndex + delta
    if newIdx < 1 then newIdx = 1 end
    if newIdx > #visibleNavRows then newIdx = #visibleNavRows end
    SetNavRowIndex(newIdx)
end

local function ActivateNavSelection()
    if navRowIndex == 0 then return false end
    local f = visibleNavRows[navRowIndex]
    if not f then return false end
    local handler = f:GetScript("OnClick")
    if handler then
        handler(f, "LeftButton")
        return true
    end
    return false
end

-- Handle a nav key arriving from either the editbox OnKeyDown (search
-- box focused) or the navFrame OnKeyDown (search box unfocused). Returns
-- true if the key was consumed. `keepSearchFocus` is true when the call
-- site is the editbox; false when it's the navFrame.
HandleNavKey = function(key, keepSearchFocus)
    local alt = IsAltKeyDown()
    if key == "DOWN" or (alt and key == "J") then
        if #visibleNavRows == 0 then return false end
        -- Keying into results always drops editbox focus and hands
        -- keyboard capture to navFrame, so subsequent keys move the
        -- selection without retyping in the box. Applies to both
        -- arrow and Alt+J behave identically.
        if keepSearchFocus and panel and panel.searchBox then
            panel.searchBox:ClearFocus()
        end
        SetNavFrameCapture(true)
        -- Hold-to-step via the OnUpdate ticker. SearchBoxTemplate
        -- swallows OS-level auto-repeat OnKeyDown events, so a held
        -- key would only fire once without our own ticker. The
        -- editbox path needs its own OnKeyUp to stop the repeat
        -- (paired with the OnKeyDown that started it); see the
        -- editBox:HookScript("OnKeyUp", ...) below in CreateSearchBox.
        if navKeyRepeat then
            navKeyRepeat.Start(key, function() MoveNavSelection(1) end)
        else
            MoveNavSelection(1)
        end
        return true
    elseif key == "UP" or (alt and key == "K") then
        if #visibleNavRows == 0 then return false end
        -- Up from the first row (or from no selection): exit back to
        -- the search box so the user can resume typing symmetrically
        -- with how Down enters the results from the editbox.
        if navRowIndex <= 1 then
            SetNavRowIndex(0)
            SetNavFrameCapture(false)
            if panel and panel.searchBox then panel.searchBox:SetFocus() end
            return true
        end
        if keepSearchFocus and panel and panel.searchBox then
            panel.searchBox:ClearFocus()
        end
        SetNavFrameCapture(true)
        if navKeyRepeat then
            navKeyRepeat.Start(key, function() MoveNavSelection(-1) end)
        else
            MoveNavSelection(-1)
        end
        return true
    elseif key == "SPACE" then
        -- Space inside the search box is a literal character and must
        -- not be consumed. While the navFrame is active (focus on a
        -- results row), Space toggles the highlighted group header's
        -- collapse. On a leaf row it does nothing and is still
        -- consumed so it doesn't leak through to a player keybind.
        if keepSearchFocus then return false end
        if navRowIndex > 0 then
            local f = visibleNavRows[navRowIndex]
            if f and f.toggleBtn and f.toggleBtn:IsShown() then
                -- The toggle click triggers a full RefreshCurrentSearch
                -- which wipes visibleNavRows and navRowIndex. Snapshot
                -- the header's groupKey, fire the click, then re-find
                -- the same header in the freshly-rendered set so the
                -- user can spam Space to collapse/expand repeatedly
                -- without losing their selection.
                local savedGroupKey = f.groupKey
                local handler = f.toggleBtn:GetScript("OnClick")
                if handler then handler(f.toggleBtn) end
                if savedGroupKey then
                    for i = 1, #visibleNavRows do
                        if visibleNavRows[i].groupKey == savedGroupKey then
                            SetNavRowIndex(i)
                            SetNavFrameCapture(true)
                            break
                        end
                    end
                end
            end
            return true
        end
        return false
    elseif key == "ENTER" then
        if navRowIndex > 0 then
            ActivateNavSelection()
            -- Match the mouse-click activation flow: a clicked row
            -- ends with searchBox unfocused, navRowIndex=0, and
            -- navFrame keyboard off. Without mirroring that state,
            -- the next Esc would clear editbox focus, then navFrame
            -- (still keyboard-enabled with navRowIndex > 0) would
            -- pick up the propagated key and re-focus the search
            -- bar via the Esc branch — instead of closing the map.
            SetNavRowIndex(0)
            SetNavFrameCapture(false)
            if panel and panel.searchBox then panel.searchBox:ClearFocus() end
            return true
        end
        return false
    elseif key == "ESCAPE" then
        if not keepSearchFocus then
            -- In navFrame: first Esc clears selection and refocuses
            -- search. A second Esc (with nothing highlighted) propagates
            -- to WoW so the map closes.
            if navRowIndex > 0 then
                SetNavRowIndex(0)
                SetNavFrameCapture(false)
                if panel and panel.searchBox then panel.searchBox:SetFocus() end
                return true
            end
            return false
        else
            -- In editbox: drop keyboard focus but keep text + results
            -- visible so the player can still see what they searched.
            if panel and panel.searchBox then panel.searchBox:ClearFocus() end
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Search box + filter cog (styled like QuestScrollFrame.SearchBox +
-- SettingsDropdown)
-- ---------------------------------------------------------------------------
local function CreateSearchBox(parent)
    -- Use Blizzard's SearchBoxTemplate so chrome, magnifying glass, and
    -- clear button are pixel-identical to the Quest Log search bar.
    local editBox = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    editBox:SetSize(301, 20)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(60)
    if editBox.Instructions then
        editBox.Instructions:SetText("Search for POIs, zones, instances...")
    end

    -- Reject auto-focus on creation. WoW will silently focus visible
    -- EditBoxes after creation despite SetAutoFocus(false). When the
    -- WorldMap is open during /reload this editbox auto-focuses, and
    -- its OnKeyDown handler sets SetPropagateKeyboardInput(false) for
    -- every key -- which silently eats SPACE/WASD even though the bar
    -- looks unfocused. Reject any focus that arrives within the first
    -- couple frames after creation.
    editBox._blockAutoFocus = true
    editBox:HookScript("OnEditFocusGained", function(self)
        if self._blockAutoFocus then self:ClearFocus() end
    end)
    -- Allow legitimate user clicks to focus by clearing the block on
    -- OnMouseDown (which fires before focus is gained).
    editBox:HookScript("OnMouseDown", function(self) self._blockAutoFocus = nil end)
    editBox:ClearFocus()
    C_Timer.After(0, function()
        C_Timer.After(0, function()
            if editBox then editBox._blockAutoFocus = nil; editBox:ClearFocus() end
        end)
    end)

    local function UpdateClear(self)
        if self.clearButton then
            self.clearButton:SetShown(self:HasFocus() or self:GetText() ~= "")
        end
    end

    -- SearchBoxTemplate's built-in clear button only clears the text +
    -- focus. Without this hook the result list would re-render in its
    -- "empty query" state (pinned + recent), which feels like the
    -- clear didn't take. Wipe everything visible so the results frame
    -- is truly empty after pressing X.
    if editBox.clearButton then
        editBox.clearButton:HookScript("OnClick", function()
            if ReleaseMapTabMemory then ReleaseMapTabMemory(false) end
        end)
    end

    -- Walks panel.topResultCandidates in scoring order and returns the
    -- first name whose lowercase prefix matches the query — lets
    -- autocomplete fall back past a fuzzy winner that doesn't prefix-
    -- match (e.g. "dragon i" skipping "Dragonblight" to suggest
    -- "Dragon Isles").
    local function FindPrefixCandidate(q)
        if not panel or q == "" then return nil end
        local qLower = q:lower()
        local list = panel.topResultCandidates
        if not list then return nil end
        for i = 1, #list do
            local name = list[i]
            if name and #name >= #q
               and name:sub(1, #q):lower() == qLower
               and name:lower() ~= qLower then
                return name
            end
        end
        return nil
    end
    editBox.FindPrefixCandidate = FindPrefixCandidate

    Utils.AttachAutocomplete(editBox, {
        findCandidate = FindPrefixCandidate,
        onTypedChanged = function(self, typed, _, grew)
            lastTypeTime = GetTime()
            UpdateClear(self)
            SchedulePendingSearch(self, typed, grew)
        end,
        onAccepted = function(text, source)
            if text and text ~= "" then MapTab:RunSearch(text) end
            if source ~= "right" and source ~= "alt-l" and source ~= "click" then
                MapTab:PushRecentSearch(text)
            end
        end,
    })
    editBox:HookScript("OnEditFocusGained", UpdateClear)
    editBox:HookScript("OnEditFocusLost", function(self)
        UpdateClear(self)
    end)

    -- Keyboard nav: consume arrow / Alt+J/K / Esc while the editbox
    -- is focused. WoW editboxes default to propagating every keystroke
    -- to the binding system, which fires player keybinds while the user
    -- is typing — so we unconditionally clamp propagation to false at
    -- the end. ENTER routes through HandleNavKey, which activates a
    -- highlighted row or falls through to push-to-recents below.
    editBox:HookScript("OnKeyDown", function(self, key)
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            if key == "RIGHT" or key == "ARROWRIGHT" then
                self:AcceptAutocomplete("right")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            elseif key == "L" and IsAltKeyDown() then
                self:AcceptAutocomplete("alt-l")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
        end
        -- Keep nav keys from racing a pending search render.
        if pendingSearchTimer
           and (key == "DOWN" or key == "UP"
                or (IsAltKeyDown() and (key == "J" or key == "K"))) then
            CancelPendingSearch()
        end
        HandleNavKey(key, true)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    end)
    -- Stop the hold-to-step ticker on key release. The OnKeyDown that
    -- started the repeat fires from the editbox, and WoW pairs OnKeyUp
    -- to the same frame regardless of focus changes mid-press, so the
    -- navFrame OnKeyUp handler isn't always reached. Mirror it here so
    -- a release on a key whose down event was on the editbox still
    -- stops the repeat -- otherwise it would keep ticking after the
    -- user lets go.
    editBox:HookScript("OnKeyUp", function(_, key)
        if navKeyRepeat and navKeyRepeat.IsKey(key) then
            navKeyRepeat.Stop(key)
        end
    end)

    -- Force focus on click. SearchBoxTemplate doesn't always grab focus
    -- back cleanly after the user has been clicking around in result
    -- rows or hovering pins on the map; the explicit SetFocus + nav
    -- keyboard release here makes the caret reappear every time.
    editBox:HookScript("OnMouseDown", function(self)
        self:SetFocus()
        if navFrame then
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        end
        if navKeyRepeat then navKeyRepeat.Stop() end
        navRowIndex = 0
    end)
    editBox:HookScript("OnEditFocusGained", function()
        if navFrame then
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        end
        if navKeyRepeat then navKeyRepeat.Stop() end
    end)

    editBox:HookScript("OnEnterPressed", function(self)
        -- If a row is highlighted, HandleNavKey already activated it on
        -- OnKeyDown(ENTER) and we shouldn't also commit to recents.
        if navRowIndex > 0 then return end
        local current = self:GetText() or ""
        local typed = self.GetTypedText and self:GetTypedText() or current
        local accepted = false
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            accepted = self:AcceptAutocomplete()
            current = self:GetText() or ""
        elseif current ~= "" and current ~= typed and self.AcceptAutocomplete then
            accepted = self:AcceptAutocomplete()
            current = self:GetText() or ""
        end
        if not accepted then MapTab:PushRecentSearch(current) end
        self:ClearFocus()
    end)
    return editBox
end

-- Push a query into the recent-searches list. Deduped (case-insensitive),
-- most-recent-first, capped at RECENT_MAX. Persists via SavedVariables.
local RECENT_ABSOLUTE_MAX = 20
local function GetRecentLimit()
    local n = EasyFind.db and EasyFind.db.mapTabRecentCount
    if type(n) ~= "number" or n < 1 then n = 3 end
    if n > RECENT_ABSOLUTE_MAX then n = RECENT_ABSOLUTE_MAX end
    return n
end
MapTab.GetRecentLimit = GetRecentLimit

-- Re-render the Map Tab if its panel is currently visible. Used by
-- Options callbacks that mutate settings affecting the rendered list
-- (e.g., recent-search count, show-recent toggle) so the change is
-- reflected without waiting for the next keystroke or map change.
function MapTab:RefreshIfOpen()
    if panel and panel:IsShown() and RefreshCurrentSearch then
        RefreshCurrentSearch()
    end
end

function MapTab:PushRecentSearch(text)
    if type(text) ~= "string" then return end
    text = text:match("^%s*(.-)%s*$") or ""
    if #text < 2 then return end
    local db = EasyFind.db
    if not db then return end
    db.mapTabRecentSearches = db.mapTabRecentSearches or {}
    local list = db.mapTabRecentSearches
    local lowerNew = text:lower()
    for i = #list, 1, -1 do
        if type(list[i]) == "string" and list[i]:lower() == lowerNew then
            tremove(list, i)
        end
    end
    tinsert(list, 1, text)
    local limit = GetRecentLimit()
    while #list > limit do tremove(list) end
end

local FILTER_OPTIONS = {
    { key = "zones",      label = "Zones" },
    { key = "instances",  label = "Instances" },
    { key = "flightpath", label = "Flight Paths" },
    { key = "travel",     label = "Travel" },
    { key = "services",   label = "Services" },
    { key = "rares",      label = "Rares" },
}

-- Attach the Auto-track Rares sub-row under the Rares filter. The row
-- appears only while the parent Rares filter is checked, and mirrors
-- `alwaysShowRares` in SavedVariables (shared with Options.lua).
local AUTO_TRACK_ROW_H = 18
local function AttachAutoTrackRow(dropdown)
    local raresRow
    for _, row in ipairs(dropdown.rows) do
        if row.optKey == "rares" then raresRow = row; break end
    end
    if not raresRow then return end

    local subRow = CreateFrame("CheckButton", nil, dropdown)
    subRow:SetSize(raresRow:GetWidth() - 20, AUTO_TRACK_ROW_H)
    subRow:SetPoint("TOPLEFT", raresRow, "BOTTOMLEFT", 20, 0)
    subRow:SetHitRectInsets(0, 0, 0, 0)
    subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    subRow:GetNormalTexture():SetSize(14, 14)
    subRow:GetNormalTexture():ClearAllPoints()
    subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)
    subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    subRow:GetCheckedTexture():SetSize(14, 14)
    subRow:GetCheckedTexture():ClearAllPoints()
    subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

    local label = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
    label:SetText("Auto-track")

    local hl = subRow:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)

    subRow:SetScript("OnClick", function(self)
        EasyFind.db.alwaysShowRares = self:GetChecked() and true or false
        local MapSearch = ns.MapSearch
        if MapSearch and MapSearch.UpdateRareTracking then
            MapSearch:UpdateRareTracking()
        end
        if ns.optionsFrame and ns.optionsFrame.rareTrackCheckbox then
            ns.optionsFrame.rareTrackCheckbox:SetChecked(EasyFind.db.alwaysShowRares)
        end
    end)
    subRow:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Auto-track Rares")
        GameTooltip:AddLine("Keep active rares shown on the map continuously.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    subRow:SetScript("OnLeave", GameTooltip_Hide)

    dropdown.autoTrackRow = subRow
    local baseHeight = dropdown:GetHeight()

    function dropdown:UpdateAutoTrackRow()
        local filters = EasyFind.db.mapTabFilters or {}
        local raresOn = filters.rares ~= false
        subRow:SetShown(raresOn)
        self:SetHeight(baseHeight + (raresOn and AUTO_TRACK_ROW_H or 0))
        subRow:SetChecked(EasyFind.db.alwaysShowRares and true or false)
    end

    dropdown:HookScript("OnShow", function(self) self:UpdateAutoTrackRow() end)
    dropdown:UpdateAutoTrackRow()
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
        GameTooltip:SetText("Filter Results")
        GameTooltip:AddLine("Toggle category filters.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", GameTooltip_Hide)
    return cog
end

-- ---------------------------------------------------------------------------
-- Side tab button
-- ---------------------------------------------------------------------------
local function CreateTabFrame(qmf)
    local tab = CreateFrame("Frame", "EasyFindMapSearchTab", qmf)
    -- Match the Blizzard side-tab size exactly by copying MapLegendTab.
    -- WQT achieves this by inheriting LargeSideTabButtonTemplate; we
    -- don't use the template (for control over our custom icon), so we
    -- mirror its resolved size here.
    local refW, refH = qmf.MapLegendTab:GetSize()
    if not refW or refW == 0 then refW, refH = TAB_W, TAB_H end
    tab:SetSize(refW, refH)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.MapLegendTab:GetFrameLevel())
    tab.displayMode = "EasyFindMapSearch"
    tab:EnableMouse(true)

    -- Background, select glow, and hover glow use Blizzard atlases at
    -- their native sizes (useAtlasSize=true) so they match the side
    -- tabs regardless of what hardcoded constants we might drift from.
    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("QuestLog-tab-side", true)
    bg:SetPoint("CENTER", tab, "CENTER", 0, 0)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetAtlas("common-search-magnifyingglass", false)
    icon:SetSize(TAB_ICON_SIZE, TAB_ICON_SIZE)
    icon:SetPoint("CENTER", tab, "CENTER", 0, 0)
    icon:SetVertexColor(TAB_ICON_DIM[1], TAB_ICON_DIM[2], TAB_ICON_DIM[3])
    tab._efIcon = icon

    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas("QuestLog-Tab-side-Glow-Select", true)
    selectGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)
    selectGlow:Hide()
    tab._efSelectGlow = selectGlow

    local hoverGlow = tab:CreateTexture(nil, "HIGHLIGHT")
    hoverGlow:SetAtlas("QuestLog-Tab-side-Glow-hover", true)
    hoverGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)

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

-- ---------------------------------------------------------------------------
-- Content panel: sibling of QuestsFrame / MapLegend / EventsFrame.
-- Replicates the Quests-tab chrome: paper backdrop, gold decorative
-- border, search bar + cog at top, scrollable content below.
-- ---------------------------------------------------------------------------
local function CreatePanel(qmf)
    -- Match WorldQuestTab's pattern (LibWorldMapTabs): anchor to
    -- QuestMapFrame.ContentsAnchor with top inset for the top bar and
    -- right inset so the MinimalScrollBar template sits outside the
    -- bordered content area. Paper texture fills the frame; the border
    -- comes from QuestLogBorderFrameTemplate (same one Blizzard uses).
    local anchor = qmf.ContentsAnchor or qmf.QuestsFrame or qmf

    -- Outer container spans the whole ContentsAnchor; the bordered
    -- result area (p) starts below the search bar. Matches Blizzard's
    -- layout where the SearchBox sits above the parchment.
    local outer = CreateFrame("Frame", "EasyFindMapSearchOuter", qmf)
    outer:SetAllPoints(anchor)
    outer:EnableMouse(false)

    -- p is the ListContainer equivalent. Sized like WQT_WorldQuestFrame:
    -- ContentsAnchor with insets y=-29 top, x=-22 right. This is a
    -- larger rect than QuestScrollFrame, which is why WQT's paper
    -- pattern renders at the same scale as Blizzard's — the atlas
    -- stretches over a larger area.
    local p = CreateFrame("Frame", "EasyFindMapSearchPanel", outer)
    p:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -29)
    p:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -22, 0)
    p:EnableMouse(true)
    p.outer = outer
    outer:Hide()

    -- Paper backdrop fills p exactly — matches WQT_ListContainer.Background
    -- (TOPLEFT + BOTTOMRIGHT to ListContainer). No bleed past the border.
    local paper = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    paper:SetAtlas("QuestLog-main-background", true)
    paper:SetAllPoints(p)
    p.paper = paper

    -- Gold border frame (Blizzard template used by QuestScrollFrame).
    -- The template carries its own anchors that extend the frame a few
    -- pixels outside its parent so the nineslice interior lines up with
    -- the parent's rect. Do NOT call SetAllPoints or we override those
    -- anchors and the border draws shrunken inside the parent. This is
    -- exactly how WQT's <Frame inherits="QuestLogBorderFrameTemplate"/>
    -- with no anchors works.
    local border = CreateFrame("Frame", nil, p, "QuestLogBorderFrameTemplate")
    border:SetFrameLevel(p:GetFrameLevel() + 2)
    -- The template inherits NineSlicePanel which spans the full rect with
    -- mouse enabled. Sitting two levels above the result rows it ate the
    -- first click on every row (loss of editbox focus + border absorption
    -- meant the user had to click twice). Border is decorative chrome — it
    -- never needs mouse input.
    border:EnableMouse(false)
    p.border = border

    -- Cog at fixed top-right position, matching WQT SettingsButton:
    -- TOPRIGHT relative to the list container at (19, 25), size 15x16.
    local cog = CreateFilterCog(outer)
    cog:SetSize(15, 16)
    cog:SetPoint("TOPRIGHT", p, "TOPRIGHT", 19, 25)
    p.cog = cog

    -- Search box: fallback position (used if QuestScrollFrame.SearchBox
    -- isn't measurable yet). AlignSearchBoxToBlizzard() re-anchors it to
    -- exactly mirror the Quests tab search box once the map is shown.
    local searchBox = CreateSearchBox(outer)
    searchBox:ClearAllPoints()
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", outer, "TOPLEFT", 4, -5)
    searchBox:SetPoint("RIGHT", cog, "LEFT", -6, 0)
    p.searchBox = searchBox

    if ns.MapSearch and ns.MapSearch.CreateFilterDropdown then
        local dropdown
        dropdown = ns.MapSearch:CreateFilterDropdown(
            "EasyFindMapTabFilterDropdown", FILTER_OPTIONS,
            "mapTabFilters", cog, outer,
            function(key)
                if key == "flightpath" and ns.MapSearch and ns.MapSearch.ReleaseIdleSearchMemory then
                    ns.MapSearch:ReleaseIdleSearchMemory()
                end
                RefreshCurrentSearch()
                if key == "rares" and dropdown.UpdateAutoTrackRow then
                    dropdown:UpdateAutoTrackRow()
                end
                -- The UI search bar's map results follow the same cog
                -- settings, so a toggle here should refresh that view
                -- too. Without this, a stale UI dropdown could keep
                -- showing flight masters after the user disabled them.
                local uiMod = ns.UI
                local uiSb = uiMod and uiMod.searchFrame and uiMod.searchFrame.editBox
                if uiMod and uiMod.OnSearchTextChanged
                   and uiSb and uiSb:IsShown() then
                    local txt = uiSb:GetText() or ""
                    if txt ~= "" then uiMod:OnSearchTextChanged(txt) end
                end
            end
        )
        AttachAutoTrackRow(dropdown)
        -- Replace the shared dropdown's default anchor (right edge of
        -- the outer panel) with Blizzard's convention: TOPLEFT of the
        -- menu aligned just below the cog's BOTTOMLEFT.
        cog:SetScript("OnClick", function()
            if dropdown:IsShown() then
                dropdown:Hide()
            else
                dropdown:ClearAllPoints()
                dropdown:SetPoint("TOPLEFT", cog, "BOTTOMLEFT", -2, -2)
                dropdown:Show()
            end
        end)
        p.filterDropdown = dropdown
    end

    -- Copy QuestScrollFrame.SearchBox's anchors AND explicit size onto
    -- our search box. Frame inspector confirms Blizzard uses a fixed
    -- 301x20 SetSize, so we re-apply it after ClearAllPoints to
    -- guarantee our frame matches — otherwise the last flex-anchored
    -- width lingers and we resolve to a different rect.
    p.AlignToBlizzardSearch = function()
        local qsb = _G["QuestScrollFrame"] and QuestScrollFrame.SearchBox
        if not qsb then return end
        local n = qsb:GetNumPoints() or 0
        if n == 0 then return end
        searchBox:ClearAllPoints()
        for i = 1, n do
            local point, relTo, relPoint, x, y = qsb:GetPoint(i)
            if point then
                searchBox:SetPoint(point, relTo, relPoint, x, y)
            end
        end
        local w, h = qsb:GetSize()
        if w and w > 0 and h and h > 0 then
            searchBox:SetSize(w, h)
        end
    end
    p.MeasureBlizzardSearch = p.AlignToBlizzardSearch

    -- Scroll area covers the paper region.
    local scrollFrame = CreateFrame("ScrollFrame", nil, p)
    scrollFrame:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -4)
    -- Leaves 28px at the bottom for the "Show recent searches" checkbox.
    scrollFrame:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 28)
    scrollFrame:EnableMouseWheel(true)
    p.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:HookScript("OnSizeChanged", function(_, w) scrollChild:SetWidth(w) end)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, scrollChild:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll() or 0
        local target = cur - delta * 24
        if target < 0 then target = 0 end
        if target > maxScroll then target = maxScroll end
        self:SetVerticalScroll(target)
    end)
    p.scrollChild = scrollChild

    -- MinimalScrollBar template placed outside the panel right edge,
    -- matching WQT's anchor offsets (+8 x, +2/-4 y).
    local scrollBar = CreateFrame("EventFrame", nil, p, "MinimalScrollBar")
    scrollBar:SetFrameStrata("HIGH")
    scrollBar:SetPoint("TOPLEFT", p, "TOPRIGHT", 8, 2)
    scrollBar:SetPoint("BOTTOMLEFT", p, "BOTTOMRIGHT", 8, -4)
    p.scrollBar = scrollBar

    local function SyncScrollBar()
        local contentH = scrollChild:GetHeight() or 0
        local viewH = scrollFrame:GetHeight() or 0
        if scrollBar.SetVisibleExtentPercentage then
            local extent = contentH > 0 and math.min(1, viewH / contentH) or 1
            scrollBar:SetVisibleExtentPercentage(extent)
        end
        if scrollBar.SetScrollPercentage then
            local maxScroll = math.max(1, contentH - viewH)
            scrollBar:SetScrollPercentage((scrollFrame:GetVerticalScroll() or 0) / maxScroll)
        end
    end
    if scrollBar.RegisterCallback and scrollBar.Event and scrollBar.Event.OnScroll then
        scrollBar:RegisterCallback(scrollBar.Event.OnScroll, function(_, pct)
            local maxScroll = math.max(0, (scrollChild:GetHeight() or 0) - (scrollFrame:GetHeight() or 0))
            scrollFrame:SetVerticalScroll(pct * maxScroll)
        end, p)
    end
    scrollFrame:HookScript("OnSizeChanged", SyncScrollBar)
    scrollFrame:HookScript("OnVerticalScroll", SyncScrollBar)
    hooksecurefunc(scrollChild, "SetHeight", SyncScrollBar)
    p.SyncScrollBar = SyncScrollBar

    local emptyMsg = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyMsg:SetPoint("TOP", scrollFrame, "TOP", 0, -24)
    emptyMsg:SetWidth(260)
    emptyMsg:SetJustifyH("CENTER")
    emptyMsg:SetText("|cff999999Start typing to search for POIs, zones, dungeons, and raids.|r")
    p.emptyMsg = emptyMsg

    -- "Show recent searches" checkbox pinned at the panel's bottom-left,
    -- inside the border. Persists to EasyFind.db.mapTabShowRecent.
    local recentCheck = CreateFrame("CheckButton", "EasyFindMapTabRecentCheck", p, "UICheckButtonTemplate")
    recentCheck:SetSize(20, 20)
    recentCheck:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 4)
    recentCheck:SetHitRectInsets(0, -120, 0, 0)
    local recentLabel = recentCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recentLabel:SetPoint("LEFT", recentCheck, "RIGHT", 2, 1)
    recentLabel:SetText("Show recent searches")
    recentCheck:SetScript("OnShow", function(self)
        self:SetChecked(EasyFind.db.mapTabShowRecent ~= false)
    end)
    recentCheck:SetScript("OnClick", function(self)
        EasyFind.db.mapTabShowRecent = self:GetChecked() and true or false
        RefreshCurrentSearch()
    end)
    p.recentCheck = recentCheck

    -- "Auto expand headers" checkbox to the right of the recent toggle.
    -- When on (default), a matched zone header lists every child the
    -- world hierarchy says lives under it. When off, only children
    -- whose names actually match the query show up — handy when you
    -- want a focused list instead of a continent's full roster.
    local expandCheck = CreateFrame("CheckButton", "EasyFindMapTabAutoExpandCheck", p, "UICheckButtonTemplate")
    expandCheck:SetSize(20, 20)
    expandCheck:SetPoint("LEFT", recentLabel, "RIGHT", 12, -1)
    expandCheck:SetHitRectInsets(0, -120, 0, 0)
    local expandLabel = expandCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    expandLabel:SetPoint("LEFT", expandCheck, "RIGHT", 2, 1)
    expandLabel:SetText("Auto expand headers")
    expandCheck:SetScript("OnShow", function(self)
        self:SetChecked(EasyFind.db.mapTabAutoExpand ~= false)
    end)
    expandCheck:SetScript("OnClick", function(self)
        EasyFind.db.mapTabAutoExpand = self:GetChecked() and true or false
        RefreshCurrentSearch()
    end)
    expandCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText("Auto expand headers")
        GameTooltip:AddLine(
            "When a search matches a parent zone, list every child it "
            .. "contains - even ones that don't match your query.",
            1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Example: searching |cffffd200east|r matches Eastern Kingdoms. "
            .. "With this on, every zone inside Eastern Kingdoms is listed "
            .. "under it. With it off, only zones whose names actually match "
            .. "|cffffd200east|r show up (Eastern Plaguelands, etc.).",
            0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    expandCheck:SetScript("OnLeave", GameTooltip_Hide)
    p.expandCheck = expandCheck

    return p
end

-- ---------------------------------------------------------------------------
-- Focus entry for keybind (/ef map search focus)
-- ---------------------------------------------------------------------------
function MapTab:Focus()
    if not IsMapSearchEnabled() then return false end
    if not initialized then self:Initialize() end
    -- ToggleWorldMap is a global available before Blizzard_WorldMap
    -- loads; calling it loads the addon and shows the map. After it
    -- returns, WorldMapFrame and QuestMapFrame exist so Initialize
    -- can finish wiring up our tab and panel.
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() end
        if not initialized then self:Initialize() end
    end
    -- If init still hasn't completed (rare race during first load),
    -- the ADDON_LOADED → Initialize callback at the bottom of this
    -- file consumes _pendingFocus to retry once the panel exists.
    if not panel or not tabFrame then
        MapTab._pendingFocus = true
        return false
    end
    -- Synchronous tab swap: same path the user's tab click takes.
    -- The OnMouseUp handler invokes ShowOurPanel().
    local clickHandler = tabFrame:GetScript("OnMouseUp")
    if clickHandler then clickHandler(tabFrame, "LeftButton") end
    -- Re-apply on the next frame to defend against any async tab
    -- restoration logic (Blizzard or third-party) that fires after
    -- this frame's OnShow chain settles.
    C_Timer.After(0, function()
        if not panel then return end
        if not panel:IsShown() and clickHandler then
            clickHandler(tabFrame, "LeftButton")
        end
        if panel.searchBox and panel:IsShown() then
            panel.searchBox:SetFocus()
        end
    end)
    return true
end

function MapTab:OpenWithQuery(query)
    if not IsMapSearchEnabled() then return false end
    if not initialized then self:Initialize() end
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() end
        if not initialized then self:Initialize() end
    end
    -- Init not ready (rare first-load race): stash the query so the
    -- ADDON_LOADED → Initialize callback can replay it once the panel
    -- exists. Mirrors _pendingFocus.
    if not panel or not tabFrame then
        MapTab._pendingQuery = query
        return false
    end
    -- Order matters: set the search text BEFORE invoking the tab's
    -- OnMouseUp. ShowOurPanel reads the current editbox text and runs
    -- a synchronous RunSearch on every show, so seeding the text first
    -- means the panel's first render already uses our query instead of
    -- briefly flashing an empty / recent-searches state. ClearFocus
    -- prevents the editbox from grabbing keyboard input — the user
    -- triggered this by clicking a result, so they expect to keep
    -- moving with WASD.
    if panel.searchBox then
        panel.searchBox:SetText(query or "")
        panel.searchBox:ClearFocus()
    end
    local clickHandler = tabFrame:GetScript("OnMouseUp")
    if clickHandler then clickHandler(tabFrame, "LeftButton") end
    C_Timer.After(0, function()
        if not panel then return end
        if not panel:IsShown() and clickHandler then
            clickHandler(tabFrame, "LeftButton")
        end
        if panel.searchBox and panel:IsShown() then
            -- Re-apply in case some other path (e.g. tab swap focus
            -- restoration) blanked the text on this frame.
            if panel.searchBox:GetText() ~= (query or "") then
                panel.searchBox:SetText(query or "")
            end
            panel.searchBox:ClearFocus()
        end
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Initialize (hook Blizzard tab clicks + fullscreen-hide)
-- ---------------------------------------------------------------------------
-- Find the lowest shown sibling tab on QuestMapFrame and anchor our
-- tab below it. Mirrors LibWorldMapTabs' PlaceTabs(): discovers tabs
-- dynamically by the `displayMode` field so we don't care which
-- specific Blizzard/third-party tabs exist.
local function PlaceTab()
    if not tabFrame then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf then return end
    local lowest, lowestBottom
    for _, child in ipairs({ qmf:GetChildren() }) do
        if child ~= tabFrame and child.displayMode and child.OnEnter and child:IsShown() then
            local b = child:GetBottom()
            if b and (not lowestBottom or b < lowestBottom) then
                lowest, lowestBottom = child, b
            end
        end
    end
    tabFrame:ClearAllPoints()
    if lowest then
        tabFrame:SetPoint("TOPLEFT", lowest, "BOTTOMLEFT", 0, TAB_STACK_GAP)
    elseif qmf.MapLegendTab then
        tabFrame:SetPoint("TOPLEFT", qmf.MapLegendTab, "BOTTOMLEFT", 0, TAB_STACK_GAP)
    else
        tabFrame:SetPoint("LEFT", qmf, "RIGHT", 0, 0)
    end
end

function MapTab:Initialize()
    if not IsMapSearchEnabled() then
        lastSelectedWasOurs = false
        if initialized and tabFrame then tabFrame:Hide() end
        if initialized and panel then
            if panel.outer then panel.outer:Hide() else panel:Hide() end
        end
        return
    end
    if initialized then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf or not qmf.MapLegendTab then return end
    initialized = true

    tabFrame = CreateTabFrame(qmf)
    panel = CreatePanel(qmf)
    PlaceTab()

    -- Hide our panel whenever any other tab gets selected. Blizzard
    -- tabs call qmf:SetDisplayMode(mode); LibWorldMapTabs tabs call
    -- lwmt:SetDisplayMode(mode). Hook both so we catch every switch.
    if qmf.SetDisplayMode then
        hooksecurefunc(qmf, "SetDisplayMode", function(_, displayMode)
            if displayMode then
                if not restoringBlizzardDisplayMode then
                    lastSelectedWasOurs = false
                end
                if selectedIsOurs then HideOurPanel() end
            end
        end)
    end
    if LibStub then
        local ok, lwmt = pcall(LibStub, "LibWorldMapTabs", true)
        if ok and lwmt and type(lwmt.SetDisplayMode) == "function" then
            hooksecurefunc(lwmt, "SetDisplayMode", function(_, displayMode)
                if displayMode then
                    if not restoringBlizzardDisplayMode then
                        lastSelectedWasOurs = false
                    end
                    if selectedIsOurs then HideOurPanel() end
                end
            end)
        end
    end

    -- Re-place on map show and once more on next frame so
    -- late-registering third-party tabs are picked up. Also opportunistic:
    -- measure Blizzard's SearchBox when the map opens with their panel
    -- visible, so our alignCache is populated even if the user hasn't
    -- clicked our tab yet.
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function()
            PlaceTab()
            SafeAfter(0, PlaceTab)
            SafeAfter(0, function()
                if panel and panel.MeasureBlizzardSearch then
                    panel.MeasureBlizzardSearch()
                end
            end)
            local function shouldRestoreEasyFindTab()
                return lastSelectedWasOurs
                    and not MapTab._pendingFocus
                    and MapTab._pendingQuery == nil
                    and IsMapSearchEnabled()
                    and not (WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized())
            end
            local function restoreEasyFindTab()
                if shouldRestoreEasyFindTab()
                   and panel
                   and WorldMapFrame and WorldMapFrame:IsShown() then
                    ShowOurPanel()
                end
            end
            -- If a Focus() request opened the map, switch immediately
            -- so the native tab does not flash first. The next-frame
            -- pass defends against late tab restoration from Blizzard
            -- or another map-tab addon.
            if MapTab._pendingFocus then
                MapTab._pendingFocus = nil
                if panel then
                    ShowOurPanel()
                    if panel.searchBox and panel:IsShown() then
                        panel.searchBox:SetFocus()
                    end
                end
                SafeAfter(0, function()
                    if panel then
                        ShowOurPanel()
                        if panel.searchBox and panel:IsShown() then
                            panel.searchBox:SetFocus()
                        end
                    end
                end)
            end
            -- Mirror handling for OpenWithQuery: replay the deferred
            -- query once the tab + panel exist. Cleared even if
            -- _pendingFocus was also set (focus path takes precedence).
            if MapTab._pendingQuery ~= nil and not MapTab._pendingFocus then
                local q = MapTab._pendingQuery
                MapTab._pendingQuery = nil
                if panel then
                    ShowOurPanel()
                    if panel.searchBox and panel:IsShown() then
                        panel.searchBox:SetText(q or "")
                        panel.searchBox:ClearFocus()
                    end
                end
                SafeAfter(0, function()
                    if panel then
                        ShowOurPanel()
                        if panel.searchBox and panel:IsShown() then
                            panel.searchBox:SetText(q or "")
                            panel.searchBox:ClearFocus()
                        end
                    end
                end)
            end
            if shouldRestoreEasyFindTab() then
                restoreEasyFindTab()
                SafeAfter(0, restoreEasyFindTab)
            else
                SafeAfter(0, function()
                    local q = _G["QuestMapFrame"]
                    if q and q.SetDisplayMode and q.displayMode == nil and not selectedIsOurs then
                        local restore = prevBlizzardDisplayMode or q.QuestsFrame
                        if restore then pcall(q.SetDisplayMode, q, restore) end
                    end
                end)
            end
        end)
        WorldMapFrame:HookScript("OnHide", function()
            if selectedIsOurs then
                lastSelectedWasOurs = true
                HideOurPanel()
            elseif ReleaseMapTabMemory then
                ReleaseMapTabMemory(true)
            end
        end)
    end

    -- Hide our tab in fullscreen map (matches Blizzard's tab behavior).
    if WorldMapFrame and WorldMapFrame.IsMaximized then
        local function UpdateTabVisibility()
            if not tabFrame then return end
            if not IsMapSearchEnabled() then
                HideOurPanel()
                tabFrame:Hide()
                return
            end
            if WorldMapFrame:IsMaximized() then
                HideOurPanel()
                tabFrame:Hide()
            else
                tabFrame:Show()
                PlaceTab()
            end
        end
        hooksecurefunc(WorldMapFrame, "Maximize", UpdateTabVisibility)
        hooksecurefunc(WorldMapFrame, "Minimize", UpdateTabVisibility)
        WorldMapFrame:HookScript("OnShow", UpdateTabVisibility)
        UpdateTabVisibility()
    end

    -- Re-render when the displayed map changes (e.g. the user right-
    -- clicks to zoom out to the parent zone). The "This Zone (...)"
    -- label and its contents are zone-scoped, so they need to refresh
    -- to reflect the new map.
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        if selectedIsOurs and panel and panel:IsShown() then
            RefreshCurrentSearch()
        end
    end)

    -- If a Focus() request came in before init completed (very first
    -- press of the keybind on a fresh login while Blizzard_WorldMap
    -- was still loading), consume the pending flag now that the tab
    -- and panel exist.
    if MapTab._pendingFocus then
        MapTab._pendingFocus = nil
        SafeAfter(0, function() MapTab:Focus() end)
    end
    if MapTab._pendingQuery ~= nil then
        local q = MapTab._pendingQuery
        MapTab._pendingQuery = nil
        SafeAfter(0, function() MapTab:OpenWithQuery(q) end)
    end
end

-- Blizzard_WorldMap is on-demand; hook the moment it loads.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if not IsMapSearchEnabled() then return end
    if event == "ADDON_LOADED" and addonName == "Blizzard_WorldMap" then
        SafeAfter(0, function() MapTab:Initialize() end)
    elseif event == "PLAYER_LOGIN" then
        local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
        if isLoaded then SafeAfter(0, function() MapTab:Initialize() end) end
    end
end)
