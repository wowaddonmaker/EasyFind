local _, ns = ...

local MapTab = {}
ns.MapTab = MapTab

local Utils = ns.Utils
local SafeAfter = Utils and Utils.SafeAfter or function(delay, fn) C_Timer.After(delay, fn) end
local sfind = Utils and Utils.sfind or string.find
local slower = Utils and Utils.slower or string.lower
local tinsert = Utils and Utils.tinsert or table.insert
local tremove = table.remove

local GOLD_COLOR = ns.GOLD_COLOR or {1.0, 0.82, 0.0}
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER
local DARK_PANEL_BG = ns.DARK_PANEL_BG

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local C_Timer = C_Timer
local GetCursorPosition = GetCursorPosition
local UIParent = UIParent

-- ---------------------------------------------------------------------------
-- Tab geometry
-- ---------------------------------------------------------------------------
local TAB_W, TAB_H       = 42, 55
local TAB_BG_W, TAB_BG_H = 51, 59
local TAB_ICON_SIZE      = 20
local TAB_ICON_GOLD      = {1.00, 0.82, 0.00}
local TAB_ICON_DIM       = {0.55, 0.45, 0.10}
local TAB_STACK_GAP      = -3

-- Pin / Guide popup geometry (mirrors UI.lua)
local EYE_ICON_TEX     = "Interface\\AddOns\\EasyFind\\textures\\eye"
local PIN_MENU_ROW_H   = 22
local PIN_MENU_WIDTH   = 96

-- Result row layout
local ROW_HEIGHT       = 24
local ROW_ICON_SIZE    = 18
local SECTION_HEADER_H = 22
-- Pool grows as needed and is reused across queries; the cap exists
-- only to prevent unbounded growth on pathological inputs. Global
-- searches that match a category (e.g. "fp" → every flight master)
-- can easily produce 200+ rows, so the cap needs headroom well past
-- the worst real query.
local MAX_ROW_POOL     = 1000

-- Roots stripped from pathPrefix display. Every zone in WoW descends
-- from "World", and the vast majority descend from "Azeroth", so those
-- segments add no disambiguation — strip them in display order only.
-- Other continents ("Outland", "Draenor", etc.) are kept because they
-- genuinely distinguish a zone's origin.
-- Top-level virtual roots that should NOT surface as group headers.
-- "Cosmic" (mapID 946) sits above Azeroth, Outland, Draenor, and
-- Shadowlands; without it here, raids and dungeons from those
-- expansions all group under "Cosmic" instead of their actual
-- continent name.
local PATH_STRIP_ROOTS = { "World", "Azeroth", "Cosmic" }

local function FormatPathPrefix(pathStr)
    if type(pathStr) ~= "string" or pathStr == "" then return pathStr end
    for i = 1, #PATH_STRIP_ROOTS do
        local root = PATH_STRIP_ROOTS[i] .. " > "
        if pathStr:sub(1, #root) == root then
            pathStr = pathStr:sub(#root + 1)
        else
            break  -- stop on first non-matching root so order is preserved
        end
    end
    -- Exact match (pathStr == a stripped root with nothing after): drop it.
    for i = 1, #PATH_STRIP_ROOTS do
        if pathStr == PATH_STRIP_ROOTS[i] then return "" end
    end
    return pathStr
end

-- Top non-stripped ancestor name for a mapID. Walks the parentMapID
-- chain until the next step would be a stripped root ("World"/"Azeroth")
-- or root is reached. Used as the grouping key so deeply-nested zones
-- (Dalaran inside Crystalsong Forest inside Northrend) group with
-- siblings at the same continent-level header.
local topAncestorCache = {}
local function IsStripped(name)
    if not name then return false end
    for i = 1, #PATH_STRIP_ROOTS do
        if PATH_STRIP_ROOTS[i] == name then return true end
    end
    return false
end
local function GetTopAncestor(mapID)
    if not mapID or mapID == 0 then return nil end
    local cached = topAncestorCache[mapID]
    if cached ~= nil then
        if cached == false then return nil end
        return cached.name, cached.mapID
    end
    local current = mapID
    local resultName, resultID
    for _ = 1, 20 do
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not info then break end
        local parentID = info.parentMapID
        local parentInfo = parentID and parentID ~= 0 and C_Map.GetMapInfo(parentID) or nil
        local parentName = parentInfo and parentInfo.name
        if not parentInfo or not parentName or IsStripped(parentName) or parentID == 0 then
            resultName = info.name
            resultID = current
            break
        end
        current = parentID
    end
    if resultName then
        topAncestorCache[mapID] = { name = resultName, mapID = resultID }
    else
        topAncestorCache[mapID] = false
    end
    return resultName, resultID
end

-- Exposed so UI search and other callers can group map results by the
-- same continent label the MapTab uses.
MapTab.GetTopAncestor = function(_, mapID) return GetTopAncestor(mapID) end

-- Walk mapID's parent chain and return the first ancestor whose
-- parentMapID is ancestorMapID — i.e. the direct child of `ancestorMapID`
-- that contains `mapID`. Used for second-level zone grouping inside a
-- continent group: an FM in Hillsbrad → Hillsbrad; a zone result for
-- Eastern Plaguelands → itself.
local zoneUnderAncestorCache = {}
local function GetZoneUnderAncestor(mapID, ancestorMapID)
    if not mapID or not ancestorMapID then return nil end
    if mapID == ancestorMapID then return nil end
    local cacheKey = mapID .. "_" .. ancestorMapID
    local cached = zoneUnderAncestorCache[cacheKey]
    if cached ~= nil then
        if cached == false then return nil end
        return cached.name, cached.mapID
    end
    local current = mapID
    for _ = 1, 20 do
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not info then break end
        if info.parentMapID == ancestorMapID then
            zoneUnderAncestorCache[cacheKey] = { name = info.name, mapID = current }
            return info.name, current
        end
        if not info.parentMapID or info.parentMapID == 0 then break end
        current = info.parentMapID
    end
    zoneUnderAncestorCache[cacheKey] = false
    return nil
end

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
local panel
local selectedIsOurs = false
local rowPool = {}
local headerPool = {}
-- Ephemeral collapse state: scoped to the current query text. Reset
-- when the search text changes so fresh matches always default to
-- expanded (auto-expand on parent match). User clicks on +/- within
-- the same query keep their effect until the text changes.
local sessionCollapsed = {}
local sessionCollapsedQuery = nil
local lastQueryGen = 0
local pendingSearchTimer
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
    local qmf = _G["QuestMapFrame"]
    if not qmf or not panel then return end
    selectedIsOurs = true
    -- Measure Blizzard's SearchBox BEFORE we hide QuestsFrame, so its
    -- GetLeft/GetRight return live values. Cache is reused for
    -- subsequent shows if Blizzard's panel isn't visible later.
    if panel.MeasureBlizzardSearch then panel.MeasureBlizzardSearch() end
    -- Call SetDisplayMode() with nil so QuestMapFrame formally leaves
    -- its current official mode. This is the pattern LibWorldMapTabs
    -- uses. Without it, clicking a Blizzard tab afterwards is a no-op
    -- (same-mode transition) and the panel stays hidden.
    if qmf.SetDisplayMode then
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
    if ns.MapSearch and ns.MapSearch.ClearHighlight and ns.MapSearch._previewing then
        ns.MapSearch._previewing = nil
        ns.MapSearch:ClearHighlight()
    end
    RefreshSelectGlows()
end

-- ---------------------------------------------------------------------------
-- Pin / Guide right-click popup (mirrors UI.lua)
-- ---------------------------------------------------------------------------
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
        -- Dismiss on outside click (any button). Same pattern used by
        -- the MapSearch filter dropdown.
        pinPopup:SetScript("OnUpdate", function(self)
            if not self:IsShown() then return end
            if (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton"))
               and not self:IsMouseOver() then
                self:Hide()
            end
        end)
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
    row:RegisterForClicks("LeftButtonDown", "RightButtonDown")
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
        local isGlobal = data.isZone or data.isDungeonEntrance
        local onGuide = isGlobal and function() TriggerResultSelect(data, false) end or nil
        ShowPopup(isPinned, function()
            if isPinned then MapSearch:UnpinMapItem(data) else MapSearch:PinMapItem(data) end
            RefreshCurrentSearch()
        end, onGuide)
        return
    end

    -- Left-click on a real result: commit the current query to recents,
    -- then navigate. Ensures recents only accumulate on intentional use
    -- (Enter key or result click), not on incidental focus loss.
    MapTab:PushRecentSearch(currentQuery)
    TriggerResultSelect(data)
end

-- Walk a result's parent-map chain and return a full breadcrumb string
-- "<name> > <zone> > <continent> > <world>". Skips a leading ancestor
-- whose name matches the POI itself (zone results' own mapID resolves
-- to the same name, so we'd otherwise render "Tol Barad > Tol Barad").
local function BuildFullBreadcrumb(data)
    local mapID = data.mapID or data.zoneMapID or data.entranceMapID or data.parentMapID
    if not mapID or not C_Map or not C_Map.GetMapInfo then return data.name end
    local parts = {}
    local current = mapID
    local leafName = data.name and data.name:lower() or ""
    for _ = 1, 20 do
        local info = C_Map.GetMapInfo(current)
        if not info then break end
        if not info.name or info.name:lower() ~= leafName then
            parts[#parts + 1] = info.name
        end
        if not info.parentMapID or info.parentMapID == 0 then break end
        current = info.parentMapID
    end
    if #parts == 0 then return data.name end
    return data.name .. "  >  " .. table.concat(parts, "  >  ")
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
    for i = 1, #rowPool do
        local row = rowPool[i]
        if not row:IsShown() then row:SetParent(parent); return row end
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

local function AcquireSectionLabel(parent, labelText)
    local hdr
    for i = 1, #sectionLabelPool do
        local h = sectionLabelPool[i]
        if not h:IsShown() then hdr = h; h:SetParent(parent); break end
    end
    if not hdr then
        hdr = CreateSectionLabel(parent)
        tinsert(sectionLabelPool, hdr)
    end
    hdr.label:SetText(labelText or "")
    return hdr
end

local function ReleaseAllSectionLabels()
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
    hdr:RegisterForClicks("LeftButtonDown", "RightButtonDown")
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
        if not hdr:IsMouseOver() then hdr.hoverOverlay:Hide() end
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
    local hdr
    for i = 1, #headerPool do
        local h = headerPool[i]
        if not h:IsShown() then hdr = h; h:SetParent(parent); break end
    end
    if not hdr then
        hdr = CreateGroupHeader(parent)
        tinsert(headerPool, hdr)
    end
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
    for i = 1, #headerPool do headerPool[i]:Hide() end
    ReleaseAllSectionLabels()
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

-- Group a result list by pathPrefix (immediate parent zone name).
-- Groups with <2 members render flat (pathPrefix stays inline); groups
-- with 2+ members promote to a collapsible parent header with indented
-- children (pathPrefix suppressed on the children).
-- Returns an ordered array: { {type="flat", data=r} | {type="group", name=p, items={...}} }
local GROUP_THRESHOLD = 2

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
        end, function() TriggerResultSelect(navigateData, false) end)
    end

    local function renderEntries(entries, sectionKey)
        for _, e in ipairs(entries) do
            if e.type == "flat" then
                placeRow(e.data, 0, nil)
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
                if parentMatched and e.ancestorMapID then
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
                        for _, item in ipairs(items) do
                            placeRow(item, 18, e.name)
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
                    end, function() TriggerResultSelect(pinRef, false) end)
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
                local key
                if r.category == "flightmaster" then
                    key = "fm:" .. (r.name or "")
                else
                    key = (r.mapID or 0) .. ":" .. (r.name or "") .. ":" .. (r.x or 0) .. ":" .. (r.y or 0)
                end
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

-- Walk the parent chain of mapID and return an array of the names at
-- every level (lowercased). Used to let a token like "northrend" match
-- any POI whose ancestor chain includes Northrend, so "northrend raid"
-- picks out raids scoped to that continent.
local ancestorNamesCache = {}
local function GetAncestorNames(mapID)
    if not mapID or mapID == 0 then return {} end
    local cached = ancestorNamesCache[mapID]
    if cached then return cached end
    local names = {}
    local current = mapID
    for _ = 1, 20 do
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(current)
        if not info then break end
        if info.name and info.name ~= "" then
            names[#names + 1] = info.name:lower()
        end
        local parentID = info.parentMapID
        if not parentID or parentID == 0 then break end
        current = parentID
    end
    ancestorNamesCache[mapID] = names
    return names
end

-- Expand a token through the shared zone-abbreviation table so shortcut
-- queries like "nr" resolve to "northrend" during multi-token matching.
-- Returns the expansion string (lowercase) or nil if no abbreviation
-- exists. Cached lookup — the table is a plain dict.
local function ExpandZoneAbbrev(t)
    local tbl = ns.MapSearch and ns.MapSearch.ZONE_ABBREVIATIONS
    if not tbl then return nil end
    return tbl[t]
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

    if #text < 2 then
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
    local localEntries = GroupBySharedParent(localFiltered)
    local globalRaw
    if multiToken then
        globalRaw = BuildMultiTokenResults(tokens, true)
    else
        globalRaw = MapSearch:BuildResults(text, true, true)
    end
    if myGen ~= lastQueryGen then return end
    local globalFiltered = FilterAndDedupe(globalRaw, seen, false)
    local globalEntries = GroupBySharedParent(globalFiltered)

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
-- Ctrl+J/K / Enter / Esc while focused and consumes them, falling back
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
    local ctrl = IsControlKeyDown()
    if key == "DOWN" or (ctrl and key == "J") then
        if #visibleNavRows == 0 then return false end
        -- Keying into results always drops editbox focus and hands
        -- keyboard capture to navFrame, so subsequent keys move the
        -- selection without retyping in the box. Applies to both
        -- arrow and Ctrl+J — they behave identically.
        if keepSearchFocus and panel and panel.searchBox then
            panel.searchBox:ClearFocus()
        end
        SetNavFrameCapture(true)
        -- Single-step: each OnKeyDown moves one row. WoW delivers
        -- repeated OnKeyDown events at the OS auto-repeat cadence
        -- while the key is held, so a held arrow / Ctrl+J still walks
        -- the list; we just don't run our own repeat ticker. Owning
        -- the repeat ourselves bit us in two ways: the press that
        -- fires from the editbox doesn't have a paired OnKeyUp on
        -- navFrame to stop the timer, so repeatActive could get
        -- stuck and auto-scroll on the next panel show; and the OS
        -- repeat firing through navFrame's OnKeyDown would also call
        -- Start, racing the ticker.
        MoveNavSelection(1)
        return true
    elseif key == "UP" or (ctrl and key == "K") then
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
        MoveNavSelection(-1)
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
            if pendingSearchTimer then
                pendingSearchTimer:Cancel(); pendingSearchTimer = nil
            end
            ReleaseAllRows()
            ReleaseAllHeaders()
            if panel and panel.scrollChild then panel.scrollChild:SetHeight(1) end
            if panel and panel.emptyMsg then panel.emptyMsg:Hide() end
            navRowIndex = 0
            if visibleNavRows then wipe(visibleNavRows) end
            if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
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

    -- Inline autocomplete using SetText + HighlightText (Chrome-style).
    -- The displayed text is the full suggestion, the cursor sits at the
    -- end of the user's typed prefix, and the trailing suggestion is
    -- selected. WoW's native caret renders at the cursor position with
    -- nothing layered over it, so the caret is always visible at the
    -- end of what the user typed. Tab confirms; typing replaces the
    -- selection (advancing through the suggestion); backspace deletes
    -- the selection without re-applying autocomplete.
    --
    -- typedText: the user's actual typed prefix (search query)
    -- programmatic: re-entrancy guard for our own SetText calls
    -- lastWasAddition: true if the last text change extended the typed
    --                  prefix; gates whether we re-apply autocomplete
    --                  after the next RunSearch settles
    local typedText = ""
    local programmatic = false
    local lastWasAddition = false

    local function StripAutocomplete()
        local current = editBox:GetText() or ""
        if current == typedText then return end
        programmatic = true
        editBox:SetText(typedText)
        editBox:SetCursorPosition(#typedText)
        editBox:HighlightText(0, 0)
        programmatic = false
    end

    local function ApplyAutocomplete()
        if programmatic or typedText == "" or not editBox:HasFocus() then
            return
        end
        local candidate = FindPrefixCandidate(typedText)
        if not candidate or candidate:lower() == typedText:lower() then
            StripAutocomplete()
            return
        end
        local suffix = candidate:sub(#typedText + 1):lower()
        if suffix == "" then StripAutocomplete(); return end
        local fullText = typedText .. suffix
        if editBox:GetText() == fullText then
            -- Already showing this suggestion. Just reassert the highlight
            -- in case focus loss / regain dropped it.
            editBox:SetCursorPosition(#typedText)
            editBox:HighlightText(#typedText, #fullText)
            return
        end
        programmatic = true
        editBox:SetText(fullText)
        editBox:SetCursorPosition(#typedText)
        editBox:HighlightText(#typedText, #fullText)
        programmatic = false
    end
    editBox.UpdateAutocomplete = ApplyAutocomplete
    editBox.GetTypedText = function() return typedText end

    editBox:HookScript("OnTextChanged", function(self)
        if programmatic then return end
        -- Hover-preview suppression: re-rendering rows under a stationary
        -- cursor would otherwise fire spurious OnEnter events as the user
        -- types.
        lastTypeTime = GetTime()
        UpdateClear(self)

        local current = self:GetText() or ""
        local cursorPos = self:GetCursorPosition()
        -- The "typed" prefix is everything up to the cursor; anything
        -- after is autocomplete suffix the user hasn't accepted.
        local typed = current:sub(1, cursorPos)
        -- Pressing an arrow key while the autocomplete suffix is
        -- highlighted collapses (or deletes) the selection without
        -- changing the user's typed prefix. WoW fires OnTextChanged
        -- on that selection edit, and if we let it reschedule a
        -- search, RunSearch fires on the next frame, RenderRows
        -- resets navRowIndex to 0, and the row we just navigated to
        -- with HandleNavKey loses its highlight. Bail when the prefix
        -- is unchanged: there's nothing new to search.
        if typed == typedText then return end
        lastWasAddition = #typed > #typedText
        typedText = typed

        if pendingSearchTimer then pendingSearchTimer:Cancel(); pendingSearchTimer = nil end
        local snapshot = typed
        pendingSearchTimer = C_Timer.NewTimer(0, function()
            pendingSearchTimer = nil
            MapTab:RunSearch(snapshot)
            -- Re-apply autocomplete only when the user added characters.
            -- For deletions / no-ops, leave the text alone so backspace
            -- actually removes the suggestion instead of re-conjuring it.
            if lastWasAddition then ApplyAutocomplete() end
            lastWasAddition = false
        end)
    end)
    editBox:HookScript("OnEditFocusGained", UpdateClear)
    editBox:HookScript("OnEditFocusLost", function(self)
        UpdateClear(self)
        -- Strip any pending autocomplete suffix so the editbox shows the
        -- user's actual typed text when unfocused.
        StripAutocomplete()
    end)

    -- Keyboard nav: consume arrow / Ctrl+J/K / Esc while the editbox
    -- is focused. WoW editboxes default to propagating every keystroke
    -- to the binding system, which fires player keybinds while the user
    -- is typing — so we unconditionally clamp propagation to false at
    -- the end. ENTER routes through HandleNavKey, which activates a
    -- highlighted row or falls through to push-to-recents below.
    editBox:HookScript("OnKeyDown", function(self, key)
        -- An active autocomplete suffix is rendered as highlighted
        -- text. WoW's default arrow-key handling on a highlighted
        -- selection fires OnTextChanged synchronously, which schedules
        -- a C_Timer.NewTimer(0) to RunSearch on the next frame —
        -- RenderRows resets navRowIndex to 0 and drops the move we're
        -- about to make. Cancel that timer for nav keys before
        -- HandleNavKey runs so the navigation actually sticks.
        if pendingSearchTimer
           and (key == "DOWN" or key == "UP"
                or (IsControlKeyDown() and (key == "J" or key == "K"))) then
            pendingSearchTimer:Cancel()
            pendingSearchTimer = nil
        end
        HandleNavKey(key, true)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
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
        navRowIndex = 0
    end)
    editBox:HookScript("OnEditFocusGained", function()
        if navFrame then
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        end
    end)

    editBox:HookScript("OnEnterPressed", function(self)
        -- If a row is highlighted, HandleNavKey already activated it on
        -- OnKeyDown(ENTER) and we shouldn't also commit to recents.
        if navRowIndex > 0 then return end
        -- Enter accepts any active autocomplete suggestion the same way
        -- Tab does, then commits the full text.
        local current = self:GetText() or ""
        if current ~= "" and current ~= typedText then
            programmatic = true
            self:SetCursorPosition(#current)
            self:HighlightText(0, 0)
            programmatic = false
            typedText = current
        end
        MapTab:PushRecentSearch(current)
        self:ClearFocus()
    end)
    -- Tab confirms the highlighted autocomplete: cursor jumps to the end
    -- of the full text and the highlight is cleared, locking in the
    -- suggestion. The typed prefix is updated to match the now-accepted
    -- text so subsequent typing extends it cleanly.
    editBox:HookScript("OnTabPressed", function(self)
        local current = self:GetText() or ""
        if current == "" or current == typedText then return end
        programmatic = true
        self:SetCursorPosition(#current)
        self:HighlightText(0, 0)
        programmatic = false
        typedText = current
        MapTab:PushRecentSearch(current)
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

    -- Filter dropdown anchored to the cog. Skip the legacy MapSearch
    -- refresh path (searchEditBox=nil) since we're not using the
    -- deprecated floating dropdown; our onChanged callback handles it.
    if ns.MapSearch and ns.MapSearch.CreateFilterDropdown then
        local dropdown
        dropdown = ns.MapSearch:CreateFilterDropdown(
            "EasyFindMapTabFilterDropdown", FILTER_OPTIONS,
            "mapTabFilters", cog, outer, nil,
            function(key)
                RefreshCurrentSearch()
                if key == "rares" and dropdown.UpdateAutoTrackRow then
                    dropdown:UpdateAutoTrackRow()
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

    return p
end

-- ---------------------------------------------------------------------------
-- Focus entry for keybind (/ef map search focus)
-- ---------------------------------------------------------------------------
function MapTab:Focus()
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
        return
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
            if displayMode and selectedIsOurs then HideOurPanel() end
        end)
    end
    if LibStub then
        local ok, lwmt = pcall(LibStub, "LibWorldMapTabs", true)
        if ok and lwmt and type(lwmt.SetDisplayMode) == "function" then
            hooksecurefunc(lwmt, "SetDisplayMode", function(_, displayMode)
                if displayMode and selectedIsOurs then HideOurPanel() end
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
            -- If a Focus() request opened the map, switch to our tab
            -- after Blizzard's OnShow handlers (which restore the last
            -- tab) have all run. SafeAfter(0) puts us at the end of
            -- this frame's pending callbacks, AFTER Blizzard's restore.
            if MapTab._pendingFocus then
                MapTab._pendingFocus = nil
                SafeAfter(0, function()
                    if panel then
                        ShowOurPanel()
                        if panel.searchBox and panel:IsShown() then
                            panel.searchBox:SetFocus()
                        end
                    end
                end)
            end
        end)
    end

    -- Hide our tab in fullscreen map (matches Blizzard's tab behavior).
    if WorldMapFrame and WorldMapFrame.IsMaximized then
        local function UpdateTabVisibility()
            if not tabFrame then return end
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
end

-- Blizzard_WorldMap is on-demand; hook the moment it loads.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == "Blizzard_WorldMap" then
        SafeAfter(0, function() MapTab:Initialize() end)
    elseif event == "PLAYER_LOGIN" then
        local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
        if isLoaded then SafeAfter(0, function() MapTab:Initialize() end) end
    end
end)
