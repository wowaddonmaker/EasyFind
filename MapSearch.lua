local ADDON_NAME, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local Utils     = ns.Utils
local DebugPrint = Utils.DebugPrint
local pairs, ipairs, type, select = Utils.pairs, Utils.ipairs, Utils.type, Utils.select
local tinsert, tsort, tconcat = Utils.tinsert, Utils.tsort, Utils.tconcat
local sfind, slower, sformat = Utils.sfind, Utils.slower, Utils.sformat
local mmin, mmax, mabs, mpi = Utils.mmin, Utils.mmax, Utils.mabs, Utils.mpi
local pcall, tostring = Utils.pcall, Utils.tostring

local searchFrame
local resultsFrame
local resultButtons = {}
local MAX_RESULTS = 20  -- Increased for grouped results
local highlightFrame
local arrowFrame
local currentHighlightedPin
local waypointPin
local zoneHighlightFrame  -- For highlighting zones on continent maps
local isGlobalSearch = false  -- Toggle for local vs global zone search

-- Category icons mapping
local CATEGORY_ICONS = {
    flightmaster = "Interface\\Icons\\Ability_Mount_GryphonRiding",
    zeppelin = "Interface\\Icons\\INV_Misc_AirshipPart_Propeller",
    boat = "Interface\\Icons\\Achievement_BG_captureflag_EOS",
    portal = "Interface\\Icons\\Spell_Arcane_PortalDalaran",
    tram = "Interface\\Icons\\INV_Misc_Gear_01",
    dungeon = "Interface\\Icons\\INV_Misc_Head_Dragon_Bronze",
    raid = "Interface\\Icons\\Achievement_Dungeon_ClassicDungeonMaster",
    bank = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
    auctionhouse = "Interface\\Icons\\INV_Misc_Coin_01",
    innkeeper = "Interface\\Icons\\Spell_Holy_GreaterHeal",
    trainer = "Interface\\Icons\\INV_Misc_Book_09",
    vendor = "Interface\\Icons\\INV_Misc_Bag_07",
    pvpvendor = "Interface\\Icons\\INV_BannerPVP_01",
    mailbox = "Interface\\Icons\\INV_Letter_15",
    stablemaster = "Interface\\Icons\\Ability_Hunter_BeastCall",
    repairvendor = "Interface\\Icons\\INV_Hammer_20",
    barber = "Interface\\Icons\\INV_Misc_Comb_01",
    transmogrifier = "Interface\\Icons\\INV_Arcane_Orb",
    rare = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    treasure = "Interface\\Icons\\INV_Misc_Bag_10",
    catalyst = "Interface\\Icons\\INV_10_GearUpgrade_Catalyst_Charged",
    greatvault = "Interface\\Icons\\INV_Misc_Lockbox_1",
    upgradevendor = "Interface\\Icons\\INV_10_GearUpgrade_Flightstone",
    voidstorage = "Interface\\Icons\\INV_Enchant_VoidCrystal",
    areapoi = "Interface\\Icons\\INV_Misc_QuestionMark",
    unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
}

local function GetCategoryIcon(category)
    return CATEGORY_ICONS[category] or CATEGORY_ICONS.unknown
end

-- Category definitions with hierarchy
local CATEGORIES = {
    travel = { keywords = {"travel", "transport", "transportation", "getting around"} },
    instance = { keywords = {"instance", "instances", "group content"} },
    service = { keywords = {"service", "services", "npc", "vendor"} },
    
    flightmaster = { keywords = {"flight", "fly", "flight master", "flight point", "fp", "taxi"}, parent = "travel" },
    zeppelin = { keywords = {"zeppelin", "zep", "airship", "blimp"}, parent = "travel" },
    boat = { keywords = {"boat", "ship", "ferry"}, parent = "travel" },
    portal = { keywords = {"portal", "portals", "teleport", "mage"}, parent = "travel" },
    tram = { keywords = {"tram", "deeprun"}, parent = "travel" },
    
    dungeon = { keywords = {"dungeon", "dungeons", "5 man", "5man", "mythic", "heroic"}, parent = "instance" },
    raid = { keywords = {"raid", "raids", "raiding"}, parent = "instance" },
    
    bank = { keywords = {"bank", "vault", "storage", "guild bank", "personal bank"}, parent = "service" },
    auctionhouse = { keywords = {"auction", "ah", "auction house"}, parent = "service" },
    innkeeper = { keywords = {"inn", "innkeeper", "rest", "hearthstone"}, parent = "service" },
    trainer = { keywords = {"trainer", "training", "class trainer"}, parent = "service" },
    vendor = { keywords = {"vendor", "merchant", "shop", "buy", "sell"}, parent = "service" },
    pvpvendor = { keywords = {"pvp vendor", "honor vendor", "conquest vendor", "arena vendor", "battleground vendor", "pvp gear"}, parent = "service" },
    mailbox = { keywords = {"mail", "mailbox", "post"}, parent = "service" },
    stablemaster = { keywords = {"stable", "stable master", "pet"}, parent = "service" },
    repairvendor = { keywords = {"repair", "repairs", "anvil"}, parent = "service" },
    barber = { keywords = {"barber", "barbershop", "appearance", "haircut"}, parent = "service" },
    transmogrifier = { keywords = {"transmog", "transmogrifier", "appearance"}, parent = "service" },
    
    rare = { keywords = {"rare", "rares", "silver dragon", "elite"} },
    treasure = { keywords = {"treasure", "chest", "loot"} },
    catalyst = { keywords = {"catalyst", "tier", "tier set", "revival catalyst", "upgrade"}, parent = "service" },
    greatvault = { keywords = {"great vault", "vault", "weekly rewards", "weekly chest"}, parent = "service" },
    upgradevendor = { keywords = {"upgrade", "upgrade vendor", "flightstone", "crest"}, parent = "service" },
}

-- Static locations are loaded from StaticLocations.lua (generated by tools/ImportPOIs.ps1)
-- To add POIs: record in-game with /devpoi, then run ImportPOIs.ps1
local STATIC_LOCATIONS = ns.STATIC_LOCATIONS or {}

function MapSearch:Initialize()
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    self:CreateHighlightFrame()
    self:CreateZoneHighlightFrame()
    self:HookWorldMap()
    self:UpdateScale()
end

function MapSearch:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "EasyFindMapSearchFrame", WorldMapFrame, "BackdropTemplate")
    searchFrame:SetSize(250, 32)
    searchFrame:SetFrameStrata("DIALOG")
    searchFrame:SetFrameLevel(9999)
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetToplevel(true)
    
    -- Apply saved position or default
    if EasyFind.db.mapSearchPosition then
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", EasyFind.db.mapSearchPosition, 0)
    else
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 0)
    end
    
    searchFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    
    -- Draggable with Shift key (constrained to map bottom edge)
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self.isDragging = true
            self.dragStartX = select(4, self:GetPoint()) or 0
        end
    end)
    searchFrame:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)
    searchFrame:SetScript("OnUpdate", function(self)
        if self.isDragging and IsShiftKeyDown() then
            local cursorX = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            local mapLeft = WorldMapFrame.ScrollContainer:GetLeft() * scale
            local mapRight = WorldMapFrame.ScrollContainer:GetRight() * scale
            local frameWidth = self:GetWidth() * self:GetEffectiveScale()
            
            -- Calculate new X position relative to map
            local newX = (cursorX - mapLeft) / scale - (self:GetWidth() / 2)
            
            -- Constrain to map width
            local maxX = (mapRight - mapLeft) / scale - self:GetWidth()
            newX = mmax(0, mmin(newX, maxX))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", newX, 0)
            EasyFind.db.mapSearchPosition = newX
        elseif self.isDragging then
            self.isDragging = false
        end
    end)
    
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(14, 14)
    searchIcon:SetPoint("LEFT", 10, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    
    local editBox = CreateFrame("EditBox", "EasyFindMapSearchBox", searchFrame)
    editBox:SetSize(150, 20)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)
    
    local placeholder = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search map locations...")
    editBox.placeholder = placeholder
    
    editBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
    end)
    
    editBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
        end
    end)
    
    editBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        MapSearch:OnSearchTextChanged(self:GetText())
    end)
    
    editBox:SetScript("OnEnterPressed", function(self)
        MapSearch:SelectFirstResult()
    end)
    
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
        self.placeholder:Show()
        MapSearch:HideResults()
        MapSearch:ClearHighlight()
    end)
    
    -- Global/Local toggle button - positioned to the RIGHT of the search frame
    local toggleBtn = CreateFrame("Button", nil, searchFrame)
    toggleBtn:SetSize(24, 24)
    toggleBtn:SetPoint("LEFT", searchFrame, "RIGHT", 4, 0)
    toggleBtn:EnableMouse(true)
    
    local toggleIcon = toggleBtn:CreateTexture(nil, "ARTWORK")
    toggleIcon:SetAllPoints()
    toggleIcon:SetTexture("Interface\\Icons\\INV_Misc_Map02")  -- Local map icon
    toggleBtn.icon = toggleIcon
    
    -- Highlight on hover
    local toggleHighlight = toggleBtn:CreateTexture(nil, "HIGHLIGHT")
    toggleHighlight:SetAllPoints()
    toggleHighlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    toggleHighlight:SetBlendMode("ADD")
    
    local function UpdateToggleButton()
        if isGlobalSearch then
            toggleBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")  -- World map icon
            toggleBtn.icon:SetVertexColor(0.4, 0.8, 1)  -- Blue tint for global
        else
            toggleBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Map02")  -- Local map icon
            toggleBtn.icon:SetVertexColor(1, 0.82, 0)  -- Gold tint for local
        end
    end
    
    toggleBtn:SetScript("OnClick", function()
        isGlobalSearch = not isGlobalSearch
        UpdateToggleButton()
        -- Re-run search with current text
        local text = editBox:GetText()
        if text and text ~= "" then
            MapSearch:OnSearchTextChanged(text)
        end
    end)
    
    toggleBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if isGlobalSearch then
            GameTooltip:SetText("Global Search (click to switch to Local)")
            GameTooltip:AddLine("Searches ALL zones in the world", 1, 1, 1)
        else
            GameTooltip:SetText("Local Search (click to switch to Global)")
            GameTooltip:AddLine("Searches only zones within current map ", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    toggleBtn:SetScript("OnLeave", GameTooltip_Hide)
    
    UpdateToggleButton()
    searchFrame.toggleBtn = toggleBtn
    
    -- Clear button (inside the search frame on the right)
    local clearBtn = CreateFrame("Button", nil, searchFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 22)
    clearBtn:SetPoint("RIGHT", searchFrame, "RIGHT", -6, 0)
    clearBtn:SetText("Clear")
    clearBtn:EnableMouse(true)
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        editBox.placeholder:Show()
        MapSearch:HideResults()
        MapSearch:ClearHighlight()
        MapSearch:ClearZoneHighlight()
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all map icons and zone highlights")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", GameTooltip_Hide)
    searchFrame.clearBtn = clearBtn
    
    searchFrame.editBox = editBox
    searchFrame:Hide()
end

function MapSearch:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindMapResultsFrame", searchFrame, "BackdropTemplate")
    resultsFrame:SetWidth(300)
    resultsFrame:SetPoint("BOTTOMLEFT", searchFrame, "TOPLEFT", 0, 2)
    resultsFrame:SetFrameStrata("TOOLTIP")
    resultsFrame:SetFrameLevel(1001)
    
    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    
    resultsFrame:Hide()
    
    for i = 1, MAX_RESULTS do
        local btn = self:CreateResultButton(i)
        resultButtons[i] = btn
    end
end

function MapSearch:CreateResultButton(index)
    local btn = CreateFrame("Button", "EasyFindMapResultButton"..index, resultsFrame)
    btn:SetSize(280, 24)
    btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, -10 - (index - 1) * 26)
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 5, 0)
    btn.icon = icon
    
    -- Secondary text for path prefix (shown above/before main text in gray)
    local prefixText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    prefixText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    prefixText:SetTextColor(0.5, 0.5, 0.5)
    prefixText:SetJustifyH("LEFT")
    prefixText:Hide()
    btn.prefixText = prefixText
    
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
    text:SetJustifyH("LEFT")
    btn.text = text
    
    btn:SetScript("OnClick", function(self)
        MapSearch:SelectResult(self.data)
    end)
    
    btn:Hide()
    return btn
end

function MapSearch:CreateHighlightFrame()
    highlightFrame = CreateFrame("Frame", "EasyFindMapHighlight", WorldMapFrame.ScrollContainer.Child)
    highlightFrame:SetSize(64, 64)
    highlightFrame:SetFrameStrata("TOOLTIP")
    highlightFrame:SetFrameLevel(2000)
    highlightFrame:Hide()
    
    local borderSize = 3
    
    local top = highlightFrame:CreateTexture(nil, "OVERLAY")
    top:SetColorTexture(1, 1, 0, 1)
    top:SetHeight(borderSize)
    top:SetPoint("BOTTOMLEFT", highlightFrame, "TOPLEFT", -5, 0)
    top:SetPoint("BOTTOMRIGHT", highlightFrame, "TOPRIGHT", 5, 0)
    highlightFrame.top = top
    
    local bottom = highlightFrame:CreateTexture(nil, "OVERLAY")
    bottom:SetColorTexture(1, 1, 0, 1)
    bottom:SetHeight(borderSize)
    bottom:SetPoint("TOPLEFT", highlightFrame, "BOTTOMLEFT", -5, 0)
    bottom:SetPoint("TOPRIGHT", highlightFrame, "BOTTOMRIGHT", 5, 0)
    highlightFrame.bottom = bottom
    
    local left = highlightFrame:CreateTexture(nil, "OVERLAY")
    left:SetColorTexture(1, 1, 0, 1)
    left:SetWidth(borderSize)
    left:SetPoint("TOPRIGHT", highlightFrame, "TOPLEFT", 0, 5)
    left:SetPoint("BOTTOMRIGHT", highlightFrame, "BOTTOMLEFT", 0, -5)
    highlightFrame.left = left
    
    local right = highlightFrame:CreateTexture(nil, "OVERLAY")
    right:SetColorTexture(1, 1, 0, 1)
    right:SetWidth(borderSize)
    right:SetPoint("TOPLEFT", highlightFrame, "TOPRIGHT", 0, 5)
    right:SetPoint("BOTTOMLEFT", highlightFrame, "BOTTOMRIGHT", 0, -5)
    highlightFrame.right = right
    
    -- Arrow pointing down to the location - FIXED LARGE SIZE
    arrowFrame = CreateFrame("Frame", "EasyFindMapArrow", highlightFrame)
    arrowFrame:SetSize(128, 128)  -- FIXED 128x128 arrow - same everywhere
    arrowFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 2)
    
    local arrow = arrowFrame:CreateTexture(nil, "ARTWORK")
    arrow:SetAllPoints()
    arrow:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
    arrow:SetVertexColor(1, 1, 0, 1)
    arrow:SetRotation(mpi)  -- Point downward
    arrowFrame.arrow = arrow
    
    -- Add glow behind arrow for visibility
    local arrowGlow = arrowFrame:CreateTexture(nil, "BACKGROUND")
    arrowGlow:SetSize(180, 180)  -- FIXED 180x180 glow - same everywhere
    arrowGlow:SetPoint("CENTER")
    arrowGlow:SetTexture("Interface\\Cooldown\\star4")
    arrowGlow:SetVertexColor(1, 1, 0, 0.7)
    arrowGlow:SetBlendMode("ADD")
    arrowFrame.glow = arrowGlow
    
    local animGroup = highlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0.4)
    alpha:SetDuration(0.5)
    highlightFrame.animGroup = animGroup
    
    -- Arrow bob animation
    local arrowAnimGroup = arrowFrame:CreateAnimationGroup()
    arrowAnimGroup:SetLooping("BOUNCE")
    local arrowMove = arrowAnimGroup:CreateAnimation("Translation")
    arrowMove:SetOffset(0, 8)
    arrowMove:SetDuration(0.4)
    arrowFrame.animGroup = arrowAnimGroup
    
    -- Create static location pin - shows the icon for locations from database
    waypointPin = CreateFrame("Frame", "EasyFindLocationPin", WorldMapFrame.ScrollContainer.Child)
    waypointPin:SetSize(64, 64)  -- Large icon for visibility
    waypointPin:SetFrameStrata("HIGH")
    waypointPin:SetFrameLevel(2000)
    waypointPin:Hide()
    
    local wpIcon = waypointPin:CreateTexture(nil, "ARTWORK")
    wpIcon:SetAllPoints()
    waypointPin.icon = wpIcon
    
    -- Add a pulsing glow effect around the icon
    local glow = waypointPin:CreateTexture(nil, "BACKGROUND")
    glow:SetSize(100, 100)  -- Larger glow
    glow:SetPoint("CENTER")
    glow:SetTexture("Interface\\Cooldown\\star4")
    glow:SetVertexColor(1, 1, 0, 0.8)
    glow:SetBlendMode("ADD")
    waypointPin.glow = glow
    
    -- Animation for the location pin glow
    local pinAnimGroup = waypointPin:CreateAnimationGroup()
    pinAnimGroup:SetLooping("BOUNCE")
    local pinPulse = pinAnimGroup:CreateAnimation("Alpha")
    pinPulse:SetFromAlpha(1)
    pinPulse:SetToAlpha(0.3)
    pinPulse:SetDuration(0.4)
    waypointPin.animGroup = pinAnimGroup
end

function MapSearch:CreateZoneHighlightFrame()
    -- Frame to overlay and highlight zones on continent maps
    zoneHighlightFrame = CreateFrame("Frame", "EasyFindZoneHighlight", WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:SetFrameStrata("TOOLTIP")  -- High strata to be visible
    zoneHighlightFrame:SetFrameLevel(400)
    zoneHighlightFrame:SetAllPoints(WorldMapFrame.ScrollContainer.Child)
    zoneHighlightFrame:Hide()
    
    -- Store references to zone highlight textures
    zoneHighlightFrame.highlights = {}
    
    -- Create a pool of highlight textures we can reuse
    for i = 1, 10 do
        local highlight = zoneHighlightFrame:CreateTexture("EasyFindZoneHighlight"..i, "OVERLAY")
        highlight:SetColorTexture(1, 1, 0, 0.5)
        highlight:SetDrawLayer("OVERLAY", 7)  -- Highest sublayer
        highlight:Hide()
        zoneHighlightFrame.highlights[i] = highlight
    end
    
    -- Animation for pulsing effect
    local animGroup = zoneHighlightFrame:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.6)
    alpha:SetToAlpha(0.3)
    alpha:SetDuration(0.5)
    zoneHighlightFrame.animGroup = animGroup
    
    -- Create arrow for zone highlighting - FIXED size, does not scale
    local zoneArrow = CreateFrame("Frame", "EasyFindZoneArrow", WorldMapFrame.ScrollContainer.Child)
    zoneArrow:SetSize(128, 128)  -- Fixed LARGE arrow
    zoneArrow:SetFrameStrata("TOOLTIP")
    zoneArrow:SetFrameLevel(500)  -- Very high to ensure visibility
    
    local arrowTex = zoneArrow:CreateTexture(nil, "OVERLAY")
    arrowTex:SetAllPoints()
    arrowTex:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")  -- Proper arrow texture
    arrowTex:SetVertexColor(1, 1, 0, 1)
    arrowTex:SetRotation(mpi)  -- Point downward by default
    zoneArrow.arrow = arrowTex
    
    local arrowGlow = zoneArrow:CreateTexture(nil, "BACKGROUND")
    arrowGlow:SetSize(180, 180)  -- Big glow
    arrowGlow:SetPoint("CENTER")
    arrowGlow:SetTexture("Interface\\Cooldown\\star4")
    arrowGlow:SetVertexColor(1, 1, 0, 1)  -- Full opacity glow
    arrowGlow:SetBlendMode("ADD")
    zoneArrow.glow = arrowGlow
    
    local arrowAnimGroup = zoneArrow:CreateAnimationGroup()
    arrowAnimGroup:SetLooping("BOUNCE")
    local arrowMove = arrowAnimGroup:CreateAnimation("Translation")
    arrowMove:SetOffset(0, 10)
    arrowMove:SetDuration(0.35)
    zoneArrow.animGroup = arrowAnimGroup
    zoneArrow.defaultOffset = {0, 10}  -- Store default animation offset
    
    zoneArrow:Hide()
    zoneHighlightFrame.arrow = zoneArrow
end

-- Get direct child zones only (1 level deep) for local search
function MapSearch:GetDirectChildZones(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    
    local zones = {}
    local seen = {}
    
    -- Get all direct children (not recursive)
    local children = C_Map.GetMapChildrenInfo(mapID, nil, false)  -- false = not recursive
    if children then
        for _, child in ipairs(children) do
            if child.name and not seen[child.mapID] then
                seen[child.mapID] = true
                tinsert(zones, {
                    mapID = child.mapID,
                    name = child.name,
                    mapType = child.mapType,
                    parentMapID = mapID
                })
            end
        end
    end
    
    return zones
end

-- Get the map hierarchy path for a zone (e.g., "Azeroth > Kalimdor > Durotar")
function MapSearch:GetMapHierarchy(mapID)
    local hierarchy = {}
    local currentID = mapID
    local maxDepth = 10  -- Safety limit
    
    while currentID and maxDepth > 0 do
        local mapInfo = C_Map.GetMapInfo(currentID)
        if mapInfo then
            tinsert(hierarchy, 1, {
                mapID = currentID,
                name = mapInfo.name,
                mapType = mapInfo.mapType
            })
            currentID = mapInfo.parentMapID
        else
            break
        end
        maxDepth = maxDepth - 1
    end
    
    return hierarchy
end

-- Recursively get ALL zones in the world for global search
function MapSearch:GetAllWorldZones(startMapID, depth, parentPath)
    depth = depth or 0
    parentPath = parentPath or {}
    
    local allZones = {}
    local maxDepth = 6  -- Limit recursion depth
    
    if depth > maxDepth then return allZones end
    
    local children = C_Map.GetMapChildrenInfo(startMapID, nil, false)
    if not children then return allZones end
    
    for _, child in ipairs(children) do
        if child.name then
            local parentInfo = C_Map.GetMapInfo(startMapID)
            local parentName = parentInfo and parentInfo.name or ""
            
            -- Replace "Cosmic" with "World" for display
            if parentName == "Cosmic" then
                parentName = "World"
            end
            
            -- Build the full path (copy parent path and add current parent)
            local fullPath = {}
            for _, p in ipairs(parentPath) do
                tinsert(fullPath, {mapID = p.mapID, name = p.name})
            end
            if parentName ~= "" then
                tinsert(fullPath, {mapID = startMapID, name = parentName})
            end
            
            tinsert(allZones, {
                mapID = child.mapID,
                name = child.name,
                mapType = child.mapType,
                parentMapID = startMapID,
                parentName = parentName,
                path = fullPath,  -- Full hierarchy path
                depth = depth
            })
            
            -- Recurse into children
            local subZones = self:GetAllWorldZones(child.mapID, depth + 1, fullPath)
            for _, subZone in ipairs(subZones) do
                tinsert(allZones, subZone)
            end
        end
    end
    
    return allZones
end

-- Search for zones matching query
function MapSearch:SearchZones(query)
    if not query or query == "" then return {} end
    
    query = slower(query)
    local zones
    
    if isGlobalSearch then
        -- Global: search entire world starting from Cosmic (946)
        -- We need to include the "World" level in all paths
        local worldPath = {{mapID = 946, name = "World"}}
        
        zones = {}
        
        -- Get all children of Cosmic (946) - this includes Azeroth, Outland, Draenor, etc.
        local cosmicChildren = C_Map.GetMapChildrenInfo(946, nil, false)
        if cosmicChildren then
            for _, child in ipairs(cosmicChildren) do
                -- Get zones from each major world (Azeroth, Outland, Draenor, etc.)
                local worldZones = self:GetAllWorldZones(child.mapID, 0, worldPath)
                for _, z in ipairs(worldZones) do
                    tinsert(zones, z)
                end
            end
        end
    else
        -- Local: only direct children of current map
        zones = self:GetDirectChildZones()
    end
    
    local matches = {}
    
    for _, zone in ipairs(zones) do
        local nameLower = slower(zone.name)
        local score = 0
        
        if nameLower == query then
            score = 100  -- Exact match
        elseif sfind(nameLower, "^" .. query) then
            score = 80   -- Starts with
        elseif sfind(nameLower, query, 1, true) then
            score = 60   -- Contains
        end
        
        if score > 0 then
            zone.score = score
            tinsert(matches, zone)
        end
    end
    
    -- Sort by score, then by name
    tsort(matches, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.name < b.name
    end)
    
    return matches
end

-- Group zone matches by their FULL parent path for clean display
-- ONLY groups zones when multiple search results share the EXACT SAME parent path
function MapSearch:GroupZonesByParent(zones)
    -- Build a path string key for each zone's parent
    local function getPathKey(zone)
        if zone.path and #zone.path > 0 then
            local parts = {}
            for _, p in ipairs(zone.path) do
                tinsert(parts, tostring(p.mapID))
            end
            return tconcat(parts, ">")
        end
        return tostring(zone.parentMapID or 0)
    end
    
    local function getPathDisplay(zone)
        if zone.path and #zone.path > 0 then
            local parts = {}
            for _, p in ipairs(zone.path) do
                tinsert(parts, p.name)
            end
            return tconcat(parts, " > ")
        end
        return zone.parentName or ""
    end
    
    -- First pass: count how many zones share each full parent path
    local pathCounts = {}
    local pathDisplay = {}
    local pathParentMapID = {}
    
    for _, zone in ipairs(zones) do
        local pathKey = getPathKey(zone)
        pathCounts[pathKey] = (pathCounts[pathKey] or 0) + 1
        if not pathDisplay[pathKey] then
            pathDisplay[pathKey] = getPathDisplay(zone)
            -- Get the last mapID in the path for navigation
            if zone.path and #zone.path > 0 then
                pathParentMapID[pathKey] = zone.path[#zone.path].mapID
            else
                pathParentMapID[pathKey] = zone.parentMapID
            end
        end
    end
    
    -- Second pass: build result list
    local result = {}
    local processedPaths = {}
    
    for _, zone in ipairs(zones) do
        local pathKey = getPathKey(zone)
        
        if processedPaths[pathKey] then
            -- Already processed this path group, skip
        else
            processedPaths[pathKey] = true
            
            -- Collect all zones with this same parent path
            local groupZones = {}
            for _, z in ipairs(zones) do
                if getPathKey(z) == pathKey then
                    tinsert(groupZones, z)
                end
            end
            
            -- Sort zones within the group alphabetically
            tsort(groupZones, function(a, b)
                return a.name < b.name
            end)
            
            -- Only create a grouped header if there are 2+ zones with the same parent
            local isGrouped = #groupZones >= 2
            
            tinsert(result, {
                parentMapID = pathParentMapID[pathKey],
                parentPath = pathDisplay[pathKey],
                zones = groupZones,
                isGrouped = isGrouped
            })
        end
    end
    
    -- Sort groups by their parent path alphabetically so related items appear together
    tsort(result, function(a, b)
        return (a.parentPath or "") < (b.parentPath or "")
    end)
    
    return result
end

-- Highlight a zone on the continent map using the actual zone shape texture
function MapSearch:HighlightZone(mapID)
    DebugPrint("[EasyFind] HighlightZone called for mapID:", mapID)
    
    if not zoneHighlightFrame then 
        DebugPrint("[EasyFind] HighlightZone: no zoneHighlightFrame!")
        return 
    end
    
    -- Save pending navigation before clearing (we might be highlighting an intermediate zone)
    local savedPending = self.pendingZoneHighlight
    DebugPrint("[EasyFind] HighlightZone: saved pending:", savedPending)
    
    -- Hide previous highlights
    self:ClearZoneHighlight()
    
    -- Restore pending navigation
    self.pendingZoneHighlight = savedPending
    DebugPrint("[EasyFind] HighlightZone: restored pending:", self.pendingZoneHighlight)
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then 
        DebugPrint("[EasyFind] HighlightZone: no canvas!")
        return 
    end
    
    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo then 
        DebugPrint("[EasyFind] HighlightZone: no mapInfo for", mapID)
        return 
    end
    DebugPrint("[EasyFind] HighlightZone: zone name:", mapInfo.name)
    
    local parentMapID = WorldMapFrame:GetMapID()
    if not parentMapID then 
        DebugPrint("[EasyFind] HighlightZone: no parentMapID!")
        return 
    end
    DebugPrint("[EasyFind] HighlightZone: parent map ID:", parentMapID)
    
    -- Get the bounds of the zone on the parent map
    local success, left, right, top, bottom = pcall(function()
        return C_Map.GetMapRectOnMap(mapID, parentMapID)
    end)
    
    DebugPrint("[EasyFind] HighlightZone: GetMapRectOnMap success:", success, "left:", left)
    
    if not success or not left then 
        DebugPrint("[EasyFind] HighlightZone: GetMapRectOnMap failed!")
        return 
    end
    
    DebugPrint("[EasyFind] HighlightZone: bounds L/R/T/B:", left, right, top, bottom)
    
    local canvasWidth, canvasHeight = canvas:GetSize()
    DebugPrint("[EasyFind] HighlightZone: canvas size:", canvasWidth, canvasHeight)
    
    -- Calculate zone center and size in pixels
    local centerX = (left + right) / 2
    local centerY = (top + bottom) / 2
    local zoneCenterPxX = centerX * canvasWidth
    local zoneCenterPxY = centerY * canvasHeight
    local width = (right - left) * canvasWidth
    local height = (bottom - top) * canvasHeight
    local zoneTopPx = top * canvasHeight
    local zoneBottomPx = bottom * canvasHeight
    local zoneLeftPx = left * canvasWidth
    local zoneRightPx = right * canvasWidth
    
    -- Try to get the actual zone highlight texture using the game's API
    local fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY
    local highlightSuccess = pcall(function()
        fileDataID, atlasID, texPercentX, texPercentY, texWidth, texHeight, posX, posY = 
            C_Map.GetMapHighlightInfoAtPosition(parentMapID, centerX, centerY)
    end)
    
    DebugPrint("[EasyFind] HighlightZone: GetMapHighlightInfoAtPosition success:", highlightSuccess)
    DebugPrint("[EasyFind] HighlightZone: fileDataID:", fileDataID, "posX:", posX, "posY:", posY)
    
    local highlight = zoneHighlightFrame.highlights[1]
    if not highlight then
        DebugPrint("[EasyFind] HighlightZone: ERROR - no highlight texture!")
        return
    end
    
    highlight:ClearAllPoints()
    
    DebugPrint("[EasyFind] HighlightZone: texPercentX:", texPercentX, "texPercentY:", texPercentY, "texWidth:", texWidth, "texHeight:", texHeight)
    
    -- TEMPORARILY force fallback to test if highlighting works at all
    local useFallback = true  -- SET TO false TO USE ZONE TEXTURES
    
    if not useFallback and highlightSuccess and fileDataID and fileDataID > 0 and posX and posY and texPercentX and texPercentY then
        DebugPrint("[EasyFind] HighlightZone: Using actual zone texture")
        -- Use the actual zone shape texture with correct positioning!
        -- IMPORTANT: posX, posY, texWidth, texHeight are NORMALIZED (0-1), must convert to pixels!
        local pixelPosX = posX * canvasWidth
        local pixelPosY = posY * canvasHeight
        local pixelWidth = texWidth * canvasWidth
        local pixelHeight = texHeight * canvasHeight
        
        highlight:SetTexture(fileDataID)
        highlight:SetTexCoord(0, texPercentX, 0, texPercentY)
        highlight:SetVertexColor(1, 1, 0, 1)  -- Full bright yellow, full opacity
        highlight:SetBlendMode("ADD")
        highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelPosX, -pixelPosY)
        highlight:SetSize(pixelWidth, pixelHeight)
        DebugPrint("[EasyFind] HighlightZone: texture set at", pixelPosX, pixelPosY, "size", pixelWidth, pixelHeight)
    else
        DebugPrint("[EasyFind] HighlightZone: Using fallback colored overlay")
        -- Fallback: use a simple colored overlay on the zone bounds
        -- Make it VERY visible - bright yellow, high opacity
        highlight:SetColorTexture(1, 1, 0, 0.6)  -- Bright yellow semi-transparent
        highlight:SetBlendMode("BLEND")
        highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", zoneLeftPx, -zoneTopPx)
        highlight:SetSize(width, height)
        DebugPrint("[EasyFind] HighlightZone: fallback at", zoneLeftPx, zoneTopPx, "size", width, height)
    end
    
    DebugPrint("[EasyFind] HighlightZone: About to show highlight")
    highlight:Show()
    DebugPrint("[EasyFind] HighlightZone: highlight:IsShown() =", highlight:IsShown())
    zoneHighlightFrame:Show()
    DebugPrint("[EasyFind] HighlightZone: zoneHighlightFrame:IsShown() =", zoneHighlightFrame:IsShown())
    zoneHighlightFrame.animGroup:Play()
    DebugPrint("[EasyFind] HighlightZone: highlight and frame shown")
    
    -- Position arrow with smart bounds checking
    if zoneHighlightFrame.arrow then
        local arrow = zoneHighlightFrame.arrow
        -- FORCE arrow to 128x128 every time - never trust cached size
        arrow:SetSize(128, 128)
        arrow:SetFrameStrata("TOOLTIP")
        arrow:SetFrameLevel(500)
        if arrow.glow then
            arrow.glow:SetSize(180, 180)
        end
        if arrow.arrow then
            arrow.arrow:SetVertexColor(1, 1, 0, 1)  -- Ensure full brightness
        end
        local arrowSize = 128  -- Fixed LARGE arrow size
        local margin = 50  -- Space needed above zone for arrow
        
        arrow:ClearAllPoints()
        
        DebugPrint("[EasyFind] HighlightZone: arrow positioning - zoneTopPx:", zoneTopPx, "margin+arrowSize:", margin + arrowSize)
        
        -- Check if there's room above the zone
        if zoneTopPx > margin + arrowSize then
            -- Place arrow above, pointing down
            arrow.arrow:SetRotation(mpi)  -- Point down
            arrow:SetPoint("BOTTOM", canvas, "TOPLEFT", zoneCenterPxX, -(zoneTopPx - 10))
            DebugPrint("[EasyFind] Arrow placed ABOVE zone")
        -- Check if there's room below the zone
        elseif (canvasHeight - zoneBottomPx) > margin + arrowSize then
            -- Place arrow below, pointing up
            arrow.arrow:SetRotation(0)  -- Point up
            arrow:SetPoint("TOP", canvas, "TOPLEFT", zoneCenterPxX, -(zoneBottomPx + 10))
            DebugPrint("[EasyFind] Arrow placed BELOW zone")
        -- Check if there's room to the left
        elseif zoneLeftPx > margin + arrowSize then
            -- Place arrow to the left, pointing right
            arrow.arrow:SetRotation(-mpi/2)  -- Point right
            arrow:SetPoint("RIGHT", canvas, "TOPLEFT", zoneLeftPx - 10, -zoneCenterPxY)
            DebugPrint("[EasyFind] Arrow placed LEFT of zone")
        -- Place arrow to the right
        else
            -- Place arrow to the right, pointing left
            arrow.arrow:SetRotation(mpi/2)  -- Point left
            arrow:SetPoint("LEFT", canvas, "TOPLEFT", zoneRightPx + 10, -zoneCenterPxY)
            DebugPrint("[EasyFind] Arrow placed RIGHT of zone")
        end
        
        arrow:Show()
        if arrow.animGroup then
            arrow.animGroup:Play()
        end
        DebugPrint("[EasyFind] Arrow shown")
    else
        DebugPrint("[EasyFind] HighlightZone: no arrow frame!")
    end
    
    -- Show zone name label
    if not zoneHighlightFrame.label then
        local label = zoneHighlightFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetTextColor(1, 1, 0, 1)
        zoneHighlightFrame.label = label
    end
    
    zoneHighlightFrame.label:SetText(mapInfo.name)
    zoneHighlightFrame.label:ClearAllPoints()
    zoneHighlightFrame.label:SetPoint("CENTER", canvas, "TOPLEFT", zoneCenterPxX, -zoneCenterPxY)
    zoneHighlightFrame.label:Show()
    
    DebugPrint("[EasyFind] HighlightZone: COMPLETE - label showing:", mapInfo.name)
    
    return true
end

function MapSearch:ClearZoneHighlight()
    if not zoneHighlightFrame then return end
    
    for _, highlight in ipairs(zoneHighlightFrame.highlights) do
        highlight:Hide()
    end
    
    if zoneHighlightFrame.label then
        zoneHighlightFrame.label:Hide()
    end
    
    if zoneHighlightFrame.border then
        for _, border in pairs(zoneHighlightFrame.border) do
            border:Hide()
        end
    end
    
    if zoneHighlightFrame.arrow then
        zoneHighlightFrame.arrow:Hide()
        if zoneHighlightFrame.arrow.animGroup then
            zoneHighlightFrame.arrow.animGroup:Stop()
        end
    end
    
    if zoneHighlightFrame.animGroup then
        zoneHighlightFrame.animGroup:Stop()
    end
    
    zoneHighlightFrame:Hide()
    
    -- Also clear breadcrumb highlight
    if self.breadcrumbHighlight then
        self.breadcrumbHighlight:Hide()
        if self.breadcrumbHighlight.animGroup then
            self.breadcrumbHighlight.animGroup:Stop()
        end
    end
    
    -- Clear any pending navigation
    self.pendingZoneHighlight = nil
end

-- Highlight a zone with step-by-step navigation guidance (teaching mode)
-- This guides the user through breadcrumbs and map clicks to reach the target
function MapSearch:HighlightZoneOnMap(targetMapID, zoneName)
    DebugPrint("[EasyFind] HighlightZoneOnMap called for targetMapID:", targetMapID)
    
    local targetInfo = C_Map.GetMapInfo(targetMapID)
    if not targetInfo then 
        DebugPrint("[EasyFind] ERROR: No targetInfo for mapID", targetMapID)
        return 
    end
    
    DebugPrint("[EasyFind] Target zone:", targetInfo.name)
    
    local targetParentMapID = targetInfo.parentMapID
    if not targetParentMapID then
        DebugPrint("[EasyFind] No parent, going directly to zone")
        WorldMapFrame:SetMapID(targetMapID)
        return
    end
    
    local targetParentInfo = C_Map.GetMapInfo(targetParentMapID)
    DebugPrint("[EasyFind] Target parent:", targetParentInfo and targetParentInfo.name or "nil", "ID:", targetParentMapID)
    
    local currentMapID = WorldMapFrame:GetMapID()
    if not currentMapID then 
        DebugPrint("[EasyFind] ERROR: No currentMapID")
        return 
    end
    
    local currentInfo = C_Map.GetMapInfo(currentMapID)
    DebugPrint("[EasyFind] Current map:", currentInfo and currentInfo.name or "nil", "ID:", currentMapID)
    
    -- CASE 1: We're already on the target's parent map - just highlight the zone!
    if currentMapID == targetParentMapID then
        DebugPrint("[EasyFind] CASE 1: Already on target parent, highlighting zone")
        C_Timer.After(0.05, function()
            self:HighlightZone(targetMapID)
        end)
        return
    end
    
    -- Build paths from root (World) to each map
    local targetParentPath = self:GetMapPath(targetParentMapID)
    local currentPath = self:GetMapPath(currentMapID)
    
    DebugPrint("[EasyFind] Target parent path:")
    for i, p in ipairs(targetParentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end
    DebugPrint("[EasyFind] Current path:")
    for i, p in ipairs(currentPath) do
        DebugPrint("  ", i, p.name, "ID:", p.mapID)
    end
    
    -- Find the DEEPEST common ancestor (DCA)
    local dcaIndex = 0
    local dcaMapID = nil
    for i = 1, mmin(#targetParentPath, #currentPath) do
        if targetParentPath[i].mapID == currentPath[i].mapID then
            dcaIndex = i
            dcaMapID = targetParentPath[i].mapID
        else
            break
        end
    end
    
    local dcaInfo = dcaMapID and C_Map.GetMapInfo(dcaMapID)
    DebugPrint("[EasyFind] DCA:", dcaInfo and dcaInfo.name or "nil", "ID:", dcaMapID, "Index:", dcaIndex)
    
    if not dcaMapID then
        DebugPrint("[EasyFind] ERROR: No common ancestor, falling back to direct nav")
        WorldMapFrame:SetMapID(targetParentMapID)
        C_Timer.After(0.1, function()
            self:HighlightZone(targetMapID)
        end)
        return
    end
    
    -- CASE 2: Current map IS the deepest common ancestor
    if currentMapID == dcaMapID then
        DebugPrint("[EasyFind] CASE 2: We're at DCA, need to go DOWN toward target")
        local nextStepIndex = dcaIndex + 1
        if nextStepIndex <= #targetParentPath then
            local nextStepMapID = targetParentPath[nextStepIndex].mapID
            local nextStepInfo = C_Map.GetMapInfo(nextStepMapID)
            DebugPrint("[EasyFind] Next step: highlight", nextStepInfo and nextStepInfo.name or "nil", "ID:", nextStepMapID)
            self.pendingZoneHighlight = targetMapID
            DebugPrint("[EasyFind] Set pendingZoneHighlight to", targetMapID)
            C_Timer.After(0.05, function()
                self:HighlightZone(nextStepMapID)
            end)
        else
            DebugPrint("[EasyFind] Edge case: at target parent, highlighting target")
            C_Timer.After(0.05, function()
                self:HighlightZone(targetMapID)
            end)
        end
        return
    end
    
    -- CASE 3: Current map is BELOW the deepest common ancestor
    DebugPrint("[EasyFind] CASE 3: Need to zoom OUT to DCA, highlighting breadcrumb")
    self:HighlightBreadcrumbForNavigation(dcaMapID, targetMapID, targetParentPath, dcaIndex)
end

-- Get the full path from World/root to a given map
function MapSearch:GetMapPath(mapID)
    local path = {}
    local currentID = mapID
    local maxDepth = 15
    
    while currentID and maxDepth > 0 do
        local info = C_Map.GetMapInfo(currentID)
        if info then
            tinsert(path, 1, {mapID = currentID, name = info.name, mapType = info.mapType})
            currentID = info.parentMapID
        else
            break
        end
        maxDepth = maxDepth - 1
    end
    
    return path
end

-- Highlight a breadcrumb button to guide user to zoom out toward the target
function MapSearch:HighlightBreadcrumbForNavigation(dcaMapID, finalTargetMapID, targetParentPath, dcaIndex)
    DebugPrint("[EasyFind] HighlightBreadcrumbForNavigation: DCA=", dcaMapID, "finalTarget=", finalTargetMapID)
    
    -- Save pending before clear
    local savedPending = finalTargetMapID
    self:ClearZoneHighlight()
    
    local navBar = WorldMapFrame.NavBar
    if not navBar then 
        DebugPrint("[EasyFind] No NavBar found, direct nav to DCA")
        WorldMapFrame:SetMapID(dcaMapID)
        self.pendingZoneHighlight = savedPending
        return
    end
    
    DebugPrint("[EasyFind] Searching for breadcrumb button for DCA ID:", dcaMapID)
    
    -- Try to find a visible breadcrumb button for the DCA
    local buttonToHighlight = self:FindBreadcrumbButton(navBar, dcaMapID)
    
    -- If not found, try each ancestor going up from DCA
    if not buttonToHighlight then
        DebugPrint("[EasyFind] DCA button not found, trying ancestors...")
        for i = dcaIndex - 1, 1, -1 do
            local ancestorMapID = targetParentPath[i] and targetParentPath[i].mapID
            if ancestorMapID then
                DebugPrint("[EasyFind] Trying ancestor:", ancestorMapID)
                buttonToHighlight = self:FindBreadcrumbButton(navBar, ancestorMapID)
                if buttonToHighlight then
                    DebugPrint("[EasyFind] Found button for ancestor:", ancestorMapID)
                    break
                end
            end
        end
    else
        DebugPrint("[EasyFind] Found button for DCA directly")
    end
    
    if buttonToHighlight and buttonToHighlight:IsShown() then
        DebugPrint("[EasyFind] Button found and shown, highlighting it")
        self:ShowBreadcrumbHighlight(buttonToHighlight, savedPending)
    else
        DebugPrint("[EasyFind] No button found or not shown, navigating directly to DCA")
        -- CRITICAL: Set pending BEFORE SetMapID because SetMapID triggers OnMapChanged synchronously!
        self.pendingZoneHighlight = savedPending
        DebugPrint("[EasyFind] Set pendingZoneHighlight BEFORE SetMapID:", savedPending)
        WorldMapFrame:SetMapID(dcaMapID)
    end
end

-- Find a breadcrumb button for a given map ID
function MapSearch:FindBreadcrumbButton(navBar, mapID)
    DebugPrint("[EasyFind] FindBreadcrumbButton looking for mapID:", mapID)
    
    -- The NavBar in WoW uses a different structure - buttons are direct children
    -- Let's iterate through children to find the right button
    for i = 1, select("#", navBar:GetChildren()) do
        local child = select(i, navBar:GetChildren())
        if child.GetID and child:GetID() == mapID then
            DebugPrint("[EasyFind] Found button via GetID:", mapID)
            return child
        end
        -- Also check for navButton property or data
        if child.data and child.data.id == mapID then
            DebugPrint("[EasyFind] Found button via data.id:", mapID)
            return child
        end
    end
    
    -- Check the navigation list - the button might be the entry itself
    if navBar.navList then
        DebugPrint("[EasyFind] navList has", #navBar.navList, "entries")
        for i, buttonData in ipairs(navBar.navList) do
            DebugPrint("[EasyFind]   navList[" .. i .. "] id:", buttonData.id, "type:", type(buttonData))
            -- The buttonData itself might BE the button frame
            if buttonData.id == mapID then
                -- Check if buttonData is a frame with Show/IsShown
                if buttonData.IsShown and buttonData:IsShown() then
                    DebugPrint("[EasyFind] buttonData itself is the button frame!")
                    return buttonData
                end
                -- Or maybe it has a different button reference
                if buttonData.Button then
                    DebugPrint("[EasyFind] Found buttonData.Button")
                    return buttonData.Button
                end
            end
        end
    else
        DebugPrint("[EasyFind] navBar.navList is nil!")
    end
    
    -- Check home button (usually Azeroth or World)
    if navBar.home and navBar.home:IsShown() then
        local homeMapID = navBar.home.id
        DebugPrint("[EasyFind] Home button ID:", homeMapID)
        if homeMapID == mapID then
            return navBar.home
        end
    else
        DebugPrint("[EasyFind] No home button or not shown")
    end
    
    -- Last resort: look for WorldMapNavBarButton frames
    local buttonName = "WorldMapNavBarButton" 
    for i = 1, 10 do
        local btn = _G[buttonName .. i]
        if btn and btn:IsShown() and btn.data and btn.data.id == mapID then
            DebugPrint("[EasyFind] Found via global name:", buttonName .. i)
            return btn
        end
    end
    
    return nil
end

-- Show the highlight effect on a breadcrumb button
function MapSearch:ShowBreadcrumbHighlight(button, finalTargetMapID)
    DebugPrint("[EasyFind] ShowBreadcrumbHighlight, finalTarget:", finalTargetMapID)
    
    if not self.breadcrumbHighlight then
        local hl = CreateFrame("Frame", "EasyFindBreadcrumbHighlight", WorldMapFrame)
        hl:SetFrameStrata("TOOLTIP")
        hl:SetFrameLevel(300)
        
        local border = hl:CreateTexture(nil, "OVERLAY")
        border:SetAllPoints()
        border:SetColorTexture(1, 1, 0, 0.5)
        border:SetBlendMode("ADD")
        hl.border = border
        
        local animGroup = hl:CreateAnimationGroup()
        animGroup:SetLooping("BOUNCE")
        local alpha = animGroup:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0.7)
        alpha:SetToAlpha(0.3)
        alpha:SetDuration(0.4)
        hl.animGroup = animGroup
        
        -- Arrow pointing to button - smaller for UI elements but still visible
        local arrow = hl:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(48, 48)  -- Good size for breadcrumb buttons
        arrow:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
        arrow:SetVertexColor(1, 1, 0, 1)
        arrow:SetRotation(mpi)  -- Point down
        arrow:SetPoint("BOTTOM", hl, "TOP", 0, 8)
        hl.arrow = arrow
        
        self.breadcrumbHighlight = hl
    end
    
    local hl = self.breadcrumbHighlight
    hl:ClearAllPoints()
    hl:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
    hl:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
    hl:Show()
    hl.animGroup:Play()
    
    -- Store the final destination for when user clicks the breadcrumb
    self.pendingZoneHighlight = finalTargetMapID
    DebugPrint("[EasyFind] ShowBreadcrumbHighlight - SET pendingZoneHighlight to:", finalTargetMapID)
end

-- Check if current map is a continent (has zone children)
function MapSearch:IsOnContinentMap()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return false end
    
    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo then return false end
    
    -- Continent type is 2, World is 1
    return mapInfo.mapType == Enum.UIMapType.Continent or mapInfo.mapType == Enum.UIMapType.World
end

function MapSearch:HookWorldMap()
    WorldMapFrame:HookScript("OnShow", function()
        searchFrame:Show()
    end)
    
    WorldMapFrame:HookScript("OnHide", function()
        searchFrame:Hide()
        self:HideResults()
        self:ClearHighlight()
        self:ClearZoneHighlight()
    end)
    
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        local newMapID = WorldMapFrame:GetMapID()
        local newMapInfo = newMapID and C_Map.GetMapInfo(newMapID)
        DebugPrint("[EasyFind] OnMapChanged - new map:", newMapInfo and newMapInfo.name or "nil", "ID:", newMapID)
        DebugPrint("[EasyFind] OnMapChanged - pendingZoneHighlight:", self.pendingZoneHighlight)
        
        self:HideResults()
        self:ClearHighlight()
        
        -- Clear breadcrumb highlight
        if self.breadcrumbHighlight then
            self.breadcrumbHighlight:Hide()
        end
        
        searchFrame.editBox:SetText("")
        searchFrame.editBox.placeholder:Show()
        
        -- Check if we have a pending zone to highlight (step-by-step navigation)
        if self.pendingZoneHighlight then
            local targetMapID = self.pendingZoneHighlight
            self.pendingZoneHighlight = nil
            
            DebugPrint("[EasyFind] OnMapChanged - continuing navigation to:", targetMapID)
            
            -- Continue the step-by-step navigation
            C_Timer.After(0.1, function()
                self:HighlightZoneOnMap(targetMapID)
            end)
        else
            DebugPrint("[EasyFind] OnMapChanged - no pending, clearing highlights")
            self:ClearZoneHighlight()
        end
    end)
end

function MapSearch:GetCategoryMatch(query)
    query = slower(query)
    local matchedCategory = nil
    local matchScore = 0
    local isExactCategoryMatch = false
    
    for catName, catData in pairs(CATEGORIES) do
        for _, keyword in ipairs(catData.keywords) do
            local kw = slower(keyword)
            if kw == query then
                return catName, 100, true
            elseif sfind(kw, query, 1, true) and #query >= 3 then
                local score = #query / #kw * 50
                if score > matchScore then
                    matchScore = score
                    matchedCategory = catName
                end
            end
        end
    end
    
    return matchedCategory, matchScore, isExactCategoryMatch
end

function MapSearch:GetRelatedCategories(category)
    local related = {category}
    local catData = CATEGORIES[category]
    
    -- Only add parent, NOT siblings
    -- Siblings are only included when searching for the parent category itself
    if catData and catData.parent then
        tinsert(related, catData.parent)
        -- Do NOT add sibling categories - that causes "pvp" to show "auction house"
    end
    
    -- Add children of this category (if searching for a parent like "service" or "travel")
    for catName, data in pairs(CATEGORIES) do
        if data.parent == category then
            tinsert(related, catName)
        end
    end
    
    return related
end

function MapSearch:GetStaticLocations()
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return {} end
    
    local results = {}
    
    -- Get built-in static locations
    local locations = STATIC_LOCATIONS[mapID]
    if locations then
        for _, loc in ipairs(locations) do
            tinsert(results, {
                name = loc.name,
                category = loc.category,
                icon = loc.icon,  -- nil is fine, GetCategoryIcon will handle it
                isStatic = true,
                x = loc.x,
                y = loc.y,
                keywords = loc.keywords,
            })
        end
    end
    
    -- Also check EasyFindDevDB for dev/testing (raw POIs from recorder)
    if EasyFindDevDB and EasyFindDevDB.rawPOIs then
        for _, poi in ipairs(EasyFindDevDB.rawPOIs) do
            if poi.mapID == mapID then
                tinsert(results, {
                    name = poi.label,
                    category = poi.category or "unknown",
                    icon = nil,  -- Let category icon be used
                    isStatic = true,
                    x = poi.x,
                    y = poi.y,
                    keywords = {},
                })
            end
        end
    end
    
    return results
end

function MapSearch:ScanMapPOIs()
    local pois = {}
    local mapID = WorldMapFrame:GetMapID()
    if not mapID then return pois end
    
    local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if not canvas then return pois end
    
    -- First: Use WoW's API to get Area POIs directly (boats, zeppelins, portals, etc)
    -- Only include POIs we can categorize as useful (travel, services)
    -- Skip generic area POIs like landmarks, zone markers, events
    local areaPOIs = C_AreaPoiInfo.GetAreaPOIForMap(mapID)
    if areaPOIs then
        for _, poiID in ipairs(areaPOIs) do
            local poiInfo = C_AreaPoiInfo.GetAreaPOIInfo(mapID, poiID)
            if poiInfo and poiInfo.name then
                local category = nil  -- Start with nil, only add if we categorize it
                local poiName = slower(poiInfo.name or "")
                local desc = slower(poiInfo.description or "")
                
                -- Only categorize POIs we actually want to show
                if sfind(poiName, "zeppelin") or sfind(poiName, "airship") or sfind(desc, "zeppelin") then
                    category = "zeppelin"
                elseif sfind(poiName, "boat") or sfind(poiName, "ship") or sfind(poiName, "ferry") or sfind(desc, "boat") then
                    category = "boat"
                elseif sfind(poiName, "portal") and not sfind(poiName, "dark portal") or sfind(desc, "teleport") then
                    -- Include portals but not "The Dark Portal" which is a landmark
                    category = "portal"
                elseif sfind(poiName, "tram") or sfind(desc, "tram") then
                    category = "tram"
                elseif sfind(poiName, "great vault") then
                    category = "greatvault"
                elseif sfind(poiName, "catalyst") then
                    category = "catalyst"
                elseif sfind(poiName, "auction") then
                    category = "auctionhouse"
                elseif sfind(poiName, "bank") and not sfind(poiName, "moat") then
                    category = "bank"
                elseif sfind(poiName, "innkeeper") or sfind(poiName, "inn") then
                    category = "innkeeper"
                elseif sfind(poiName, "flight master") or sfind(poiName, "flight point") then
                    category = "flightmaster"
                end
                
                -- Only add POIs we've explicitly categorized
                -- This filters out generic landmarks, zone markers, events, etc.
                if category then
                    tinsert(pois, {
                        name = poiInfo.name,
                        pin = nil,  -- API-based, no pin reference
                        pinType = category,
                        category = category,
                        icon = nil,  -- Use category icon, not textureIndex (which is an atlas)
                        isStatic = true,
                        x = poiInfo.position.x,
                        y = poiInfo.position.y,
                    })
                end
            end
        end
    end
    
    -- Second: Scan all children of the map canvas for pins
    for i = 1, select("#", canvas:GetChildren()) do
        local pin = select(i, canvas:GetChildren())
        if pin and pin:IsShown() then
            local info = self:GetPinInfo(pin)
            if info then
                tinsert(pois, info)
            end
        end
    end
    
    return pois
end

function MapSearch:GetPinInfo(pin)
    if not pin or not pin:IsShown() then return nil end
    
    local name = nil
    local icon = nil
    local pinType = "unknown"
    local category = nil
    
    -- Flight masters
    if pin.taxiNodeData then
        name = pin.taxiNodeData.name
        pinType = "flightmaster"
        category = "flightmaster"
        icon = 135770
    end
    
    -- Area POIs (boats, zeppelins, portals, etc) - but NOT quests
    if pin.areaPoiInfo then
        name = pin.areaPoiInfo.name or pin.areaPoiInfo.description
        pinType = "areapoi"
        
        local poiName = slower(name or "")
        local poiDesc = slower(pin.areaPoiInfo.description or "")
        if sfind(poiName, "zeppelin") or sfind(poiName, "airship") then
            category = "zeppelin"
            pinType = "zeppelin"
        elseif sfind(poiName, "boat") or sfind(poiName, "ship") or sfind(poiName, "ferry") then
            category = "boat"
            pinType = "boat"
        elseif sfind(poiName, "portal") then
            category = "portal"
            pinType = "portal"
        elseif sfind(poiName, "tram") then
            category = "tram"
            pinType = "tram"
        elseif sfind(poiName, "pvp") or sfind(poiName, "arena") or sfind(poiName, "battleground") or sfind(poiDesc, "pvp") or sfind(poiName, "conquest") or sfind(poiName, "honor") or sfind(poiName, "weekly") then
            category = "pvpvendor"
            pinType = "pvpvendor"
        else
            -- Generic area POI - skip it (these are usually landmarks, events, etc.)
            return nil
        end
    end
    
    -- Vignettes (rares, treasures)
    if pin.vignetteInfo then
        name = pin.vignetteInfo.name
        pinType = "vignette"
        category = "rare"
        if pin.vignetteInfo.vignetteType == 2 then
            category = "treasure"
        end
    end
    
    -- SKIP quests entirely - don't include them
    if pin.questID then
        return nil
    end
    
    -- SKIP world quests too
    if pin.worldQuest then
        return nil
    end
    
    -- Dungeon/Raid instances
    if pin.journalInstanceID and EJ_GetInstanceInfo then
        local instanceName, _, _, _, _, _, _, _, _, _, isRaid = EJ_GetInstanceInfo(pin.journalInstanceID)
        if instanceName then
            name = instanceName
            pinType = isRaid and "raid" or "dungeon"
            category = isRaid and "raid" or "dungeon"
        end
    end
    
    -- Get icon from pin if we don't have one
    if not icon then
        if pin.Texture and pin.Texture.GetTexture then
            local tex = pin.Texture:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        elseif pin.Icon and pin.Icon.GetTexture then
            local tex = pin.Icon:GetTexture()
            if tex and type(tex) == "number" then
                icon = tex
            end
        end
    end
    
    if not name or name == "" then 
        return nil 
    end
    
    return {
        name = name,
        pin = pin,
        pinType = pinType,
        category = category,
        icon = icon or 134400,
        isStatic = false,
    }
end

function MapSearch:OnSearchTextChanged(text)
    if not text or text == "" or #text < 2 then
        self:HideResults()
        self:ClearHighlight()
        self:ClearZoneHighlight()
        return
    end
    
    -- Clear any previous zone highlights
    self:ClearZoneHighlight()
    
    -- Search for zones (works for both local and global mode)
    local zoneMatches = {}
    if self:IsOnContinentMap() or isGlobalSearch then
        zoneMatches = self:SearchZones(text)
        -- Don't auto-highlight - only highlight when user clicks a result
    end
    
    -- Get both dynamic pins and static locations for current map
    local dynamicPOIs = self:ScanMapPOIs()
    local staticLocations = self:GetStaticLocations()
    
    -- Combine them
    local allPOIs = {}
    
    -- Group zone matches by parent for clean display
    local groupedZones = self:GroupZonesByParent(zoneMatches)
    
    -- Add zone results - simple flat list with full path
    local groupOrder = 1
    local zoneNames = {}  -- Track zone names to avoid duplicate POI entries
    
    for _, group in ipairs(groupedZones) do
        local zonesInGroup = group.zones
        local parentPath = group.parentPath
        
        for _, zone in ipairs(zonesInGroup) do
            zoneNames[slower(zone.name)] = true
            tinsert(allPOIs, {
                name = zone.name,
                category = "zone",
                icon = 237382,
                isZone = true,
                zoneMapID = zone.mapID,
                pathPrefix = parentPath,
                score = zone.score + 200,
                groupOrder = groupOrder
            })
            groupOrder = groupOrder + 1
        end
    end
    
    -- Add POIs but skip any that match zone names (avoid duplicates)
    for _, poi in ipairs(dynamicPOIs) do
        if not zoneNames[slower(poi.name)] then
            tinsert(allPOIs, poi)
        end
    end
    for _, loc in ipairs(staticLocations) do
        if not zoneNames[slower(loc.name)] then
            tinsert(allPOIs, loc)
        end
    end
    
    local results = self:SearchPOIs(allPOIs, text)
    self:ShowResults(results)
end

function MapSearch:SearchPOIs(pois, query)
    query = slower(query)
    local results = {}
    local seen = {}
    local duplicates = {}  -- Track all instances of duplicate POIs
    
    local matchedCategory, catScore, isExactCategoryMatch = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or {}
    
    -- First pass: name matches
    for _, poi in ipairs(pois) do
        local nameLower = slower(poi.name)
        local key = poi.name .. (poi.category or "")
        
        local score = 0
        
        if nameLower == query then
            score = 300
        elseif sfind(nameLower, query, 1, true) then
            score = 200
        end
        
        -- Also check custom keywords for static locations
        if poi.keywords and score == 0 then
            for _, kw in ipairs(poi.keywords) do
                if sfind(slower(kw), query, 1, true) then
                    score = 180
                    break
                end
            end
        end
        
        if score > 0 then
            -- Track all instances in duplicates table
            if not duplicates[key] then
                duplicates[key] = {}
            end
            tinsert(duplicates[key], poi)
            
            -- Only add to results once (first instance)
            if not seen[key] then
                seen[key] = true
                poi.score = score
                poi.duplicateKey = key  -- Track the key for looking up duplicates
                tinsert(results, poi)
            end
        end
    end
    
    -- Second pass: ALWAYS include category matches when user typed a category keyword
    -- This ensures typing "dungeon" shows ALL dungeons, not just name matches
    if matchedCategory then
        for _, poi in ipairs(pois) do
            local key = poi.name .. (poi.category or "")
            
            if not seen[key] and poi.category then
                local score = 0
                
                -- Direct category match
                if poi.category == matchedCategory then
                    score = 150
                end
                
                -- Related category match (e.g., search "travel" shows all travel types)
                if score == 0 then
                    for _, relCat in ipairs(relatedCategories) do
                        if poi.category == relCat then
                            score = 100
                            break
                        end
                    end
                end
                
                if score > 0 then
                    -- Track all instances in duplicates table
                    if not duplicates[key] then
                        duplicates[key] = {}
                    end
                    tinsert(duplicates[key], poi)
                    
                    if not seen[key] then
                        seen[key] = true
                        poi.score = score
                        poi.duplicateKey = key
                        tinsert(results, poi)
                    end
                end
            end
        end
    end
    
    -- Attach duplicates info to results
    for _, result in ipairs(results) do
        if result.duplicateKey and duplicates[result.duplicateKey] then
            result.allInstances = duplicates[result.duplicateKey]
        end
    end
    
    -- Sort results by score, BUT keep zone groups intact
    -- Zone items have a groupOrder field that should be respected
    tsort(results, function(a, b)
        -- If both have groupOrder, sort by that first (keeps headers with their children)
        if a.groupOrder and b.groupOrder then
            return a.groupOrder < b.groupOrder
        end
        -- Items with groupOrder come before items without (zones before POIs)
        if a.groupOrder and not b.groupOrder then
            return true
        end
        if b.groupOrder and not a.groupOrder then
            return false
        end
        -- Otherwise sort by score
        return a.score > b.score
    end)
    return results
end

function MapSearch:ShowResults(results)
    if not results or #results == 0 then
        self:HideResults()
        return
    end
    
    local count = mmin(#results, MAX_RESULTS)
    
    for i = 1, MAX_RESULTS do
        local btn = resultButtons[i]
        if i <= count then
            local data = results[i]
            btn.data = data
            
            -- Reset button state
            btn.icon:ClearAllPoints()
            btn.icon:SetPoint("LEFT", 5, 0)
            btn.text:ClearAllPoints()
            btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
            btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
            btn.icon:Show()
            btn.icon:SetVertexColor(1, 1, 1)
            btn.text:SetTextColor(1, 1, 1)
            if btn.prefixText then btn.prefixText:Hide() end
            
            -- Format based on type
            if data.isZoneParent then
                -- Parent header - no icon, just gray text with arrow
                btn.icon:Hide()
                btn.text:ClearAllPoints()
                btn.text:SetPoint("LEFT", btn, "LEFT", 8, 0)
                btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
                btn.text:SetText("|cff666666▼ " .. data.name .. "|r")
                btn:SetScript("OnClick", function(self)
                    MapSearch:SelectResult(self.data)  -- Can still click to navigate
                end)
                
            elseif data.isZone then
                if data.isIndented then
                    -- Indented child zone - shift icon and text right
                    btn.icon:ClearAllPoints()
                    btn.icon:SetPoint("LEFT", 25, 0)  -- Indent the icon
                    btn.text:ClearAllPoints()
                    btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
                    btn.text:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
                    btn.text:SetText(data.displayName or data.name)
                    btn.text:SetTextColor(1, 0.82, 0)  -- Gold
                    btn.icon:SetTexture(237382)
                    btn.icon:SetSize(16, 16)  -- Slightly smaller for children
                    btn.icon:Show()
                    
                elseif data.pathPrefix and data.pathPrefix ~= "" then
                    -- Global search with path - show "Path > Zone" format
                    btn.text:SetText("|cff666666" .. data.pathPrefix .. " >|r |cffffd100" .. data.name .. "|r")
                    btn.icon:SetTexture(237382)
                    btn.icon:Show()
                    
                else
                    -- Regular zone result
                    btn.text:SetText(data.name)
                    btn.text:SetTextColor(1, 0.82, 0)  -- Gold
                    btn.icon:SetTexture(237382)
                    btn.icon:Show()
                end
                
                btn:SetScript("OnClick", function(self)
                    MapSearch:SelectResult(self.data)
                end)
                
            else
                -- Regular POI result
                btn.text:SetText(data.name)
                btn.text:SetTextColor(1, 1, 1)
                
                local iconTexture = GetCategoryIcon(data.category)
                if data.icon then
                    iconTexture = data.icon
                end
                btn.icon:SetTexture(iconTexture)
                btn.icon:SetSize(18, 18)
                btn.icon:Show()
                
                btn:SetScript("OnClick", function(self)
                    MapSearch:SelectResult(self.data)
                end)
            end
            
            btn:Show()
        else
            btn:Hide()
        end
    end
    
    resultsFrame:SetHeight(20 + count * 26)
    resultsFrame:Show()
end

function MapSearch:HideResults()
    resultsFrame:Hide()
end

function MapSearch:SelectFirstResult()
    -- Don't do anything if no results are showing
    if not resultsFrame:IsShown() then return end
    if resultButtons[1]:IsShown() and resultButtons[1].data then
        self:SelectResult(resultButtons[1].data)
    end
end

function MapSearch:SelectResult(data)
    searchFrame.editBox:ClearFocus()
    self:HideResults()
    
    if data then
        -- Handle parent zone header - always navigate to parent maps
        if data.isZoneParent and data.zoneMapID then
            self:ClearZoneHighlight()
            WorldMapFrame:SetMapID(data.zoneMapID)
            return
        end
        
        -- Handle zone selection
        if data.isZone and data.zoneMapID then
            if EasyFind.db.navigateToZonesDirectly then
                -- Direct mode: navigate straight to the zone
                self:ClearZoneHighlight()
                WorldMapFrame:SetMapID(data.zoneMapID)
            else
                -- Teaching mode: highlight the zone on current/parent map
                self:HighlightZoneOnMap(data.zoneMapID, data.name)
            end
            return
        end
        
        -- Check if this POI has multiple instances (duplicates)
        if data.allInstances and #data.allInstances > 1 then
            -- Show ALL instances on the map
            self:ShowMultipleWaypoints(data.allInstances)
        elseif data.x and data.y then
            -- Single POI with coordinates
            self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
        elseif data.pin then
            -- Dynamic pin with no coords - highlight it directly
            self:HighlightPin(data.pin)
        end
    end
end

-- Show multiple waypoints for duplicate POIs (e.g., multiple auction houses)
function MapSearch:ShowMultipleWaypoints(instances)
    self:ClearHighlight()
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local canvasWidth, canvasHeight = canvas:GetSize()
    local scaleFactor = mmax(1, mmin(canvasWidth, canvasHeight) / 600)
    local userScale = EasyFind.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local iconSize = 48 * scaleFactor
    local glowSize = 72 * scaleFactor
    local highlightSize = 60 * scaleFactor
    -- ARROWS ARE FIXED SIZE - do not scale with map!
    local arrowSize = 128  -- FIXED
    local arrowGlowSize = 180  -- FIXED
    
    -- Create additional waypoint pins if needed
    if not self.extraPins then
        self.extraPins = {}
    end
    if not self.extraHighlights then
        self.extraHighlights = {}
    end
    if not self.extraArrows then
        self.extraArrows = {}
    end
    
    -- Show each instance with pin, highlight box, and arrow
    for i, instance in ipairs(instances) do
        if instance.x and instance.y then
            local pin, highlight, arrow
            
            if i == 1 then
                -- Use the main frames for first instance
                pin = waypointPin
                highlight = highlightFrame
                arrow = arrowFrame
            else
                -- Create or reuse extra pins
                if not self.extraPins[i-1] then
                    local extraPin = CreateFrame("Frame", "EasyFindExtraPin"..(i-1), canvas)
                    extraPin:SetFrameStrata("HIGH")
                    extraPin:SetFrameLevel(1999)
                    
                    local icon = extraPin:CreateTexture(nil, "ARTWORK")
                    icon:SetAllPoints()
                    extraPin.icon = icon
                    
                    local glow = extraPin:CreateTexture(nil, "BACKGROUND")
                    glow:SetPoint("CENTER")
                    glow:SetTexture("Interface\\Cooldown\\star4")
                    glow:SetVertexColor(1, 1, 0, 0.8)
                    glow:SetBlendMode("ADD")
                    extraPin.glow = glow
                    
                    local animGroup = extraPin:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local pulse = animGroup:CreateAnimation("Alpha")
                    pulse:SetFromAlpha(1)
                    pulse:SetToAlpha(0.3)
                    pulse:SetDuration(0.4)
                    extraPin.animGroup = animGroup
                    
                    self.extraPins[i-1] = extraPin
                end
                pin = self.extraPins[i-1]
                
                -- Create or reuse extra highlight boxes
                if not self.extraHighlights[i-1] then
                    local extraHighlight = CreateFrame("Frame", "EasyFindExtraHighlight"..(i-1), canvas)
                    extraHighlight:SetFrameStrata("HIGH")
                    extraHighlight:SetFrameLevel(1998)
                    
                    local borderSize = 3
                    local top = extraHighlight:CreateTexture(nil, "OVERLAY")
                    top:SetColorTexture(1, 1, 0, 1)
                    top:SetHeight(borderSize)
                    top:SetPoint("BOTTOMLEFT", extraHighlight, "TOPLEFT", -5, 0)
                    top:SetPoint("BOTTOMRIGHT", extraHighlight, "TOPRIGHT", 5, 0)
                    extraHighlight.top = top
                    
                    local bottom = extraHighlight:CreateTexture(nil, "OVERLAY")
                    bottom:SetColorTexture(1, 1, 0, 1)
                    bottom:SetHeight(borderSize)
                    bottom:SetPoint("TOPLEFT", extraHighlight, "BOTTOMLEFT", -5, 0)
                    bottom:SetPoint("TOPRIGHT", extraHighlight, "BOTTOMRIGHT", 5, 0)
                    extraHighlight.bottom = bottom
                    
                    local left = extraHighlight:CreateTexture(nil, "OVERLAY")
                    left:SetColorTexture(1, 1, 0, 1)
                    left:SetWidth(borderSize)
                    left:SetPoint("TOPRIGHT", extraHighlight, "TOPLEFT", 0, 5)
                    left:SetPoint("BOTTOMRIGHT", extraHighlight, "BOTTOMLEFT", 0, -5)
                    extraHighlight.left = left
                    
                    local right = extraHighlight:CreateTexture(nil, "OVERLAY")
                    right:SetColorTexture(1, 1, 0, 1)
                    right:SetWidth(borderSize)
                    right:SetPoint("TOPLEFT", extraHighlight, "TOPRIGHT", 0, 5)
                    right:SetPoint("BOTTOMLEFT", extraHighlight, "BOTTOMRIGHT", 0, -5)
                    extraHighlight.right = right
                    
                    local animGroup = extraHighlight:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local alpha = animGroup:CreateAnimation("Alpha")
                    alpha:SetFromAlpha(1)
                    alpha:SetToAlpha(0.4)
                    alpha:SetDuration(0.5)
                    extraHighlight.animGroup = animGroup
                    
                    self.extraHighlights[i-1] = extraHighlight
                end
                highlight = self.extraHighlights[i-1]
                
                -- Create or reuse extra arrows
                if not self.extraArrows[i-1] then
                    local extraArrow = CreateFrame("Frame", "EasyFindExtraArrow"..(i-1), canvas)
                    extraArrow:SetFrameStrata("HIGH")
                    extraArrow:SetFrameLevel(2001)
                    
                    local arrowTex = extraArrow:CreateTexture(nil, "ARTWORK")
                    arrowTex:SetAllPoints()
                    arrowTex:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
                    arrowTex:SetVertexColor(1, 1, 0, 1)
                    arrowTex:SetRotation(mpi)
                    extraArrow.arrow = arrowTex
                    
                    local arrowGlow = extraArrow:CreateTexture(nil, "BACKGROUND")
                    arrowGlow:SetPoint("CENTER")
                    arrowGlow:SetTexture("Interface\\Cooldown\\star4")
                    arrowGlow:SetVertexColor(1, 1, 0, 0.7)
                    arrowGlow:SetBlendMode("ADD")
                    extraArrow.glow = arrowGlow
                    
                    local animGroup = extraArrow:CreateAnimationGroup()
                    animGroup:SetLooping("BOUNCE")
                    local arrowMove = animGroup:CreateAnimation("Translation")
                    arrowMove:SetOffset(0, 8)
                    arrowMove:SetDuration(0.4)
                    extraArrow.animGroup = animGroup
                    
                    self.extraArrows[i-1] = extraArrow
                end
                arrow = self.extraArrows[i-1]
            end
            
            -- Position and show the pin
            pin:SetSize(iconSize, iconSize)
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", canvas, "TOPLEFT", instance.x * canvasWidth, -instance.y * canvasHeight)
            
            local iconTexture = GetCategoryIcon(instance.category)
            if instance.icon then
                iconTexture = instance.icon
            end
            pin.icon:SetTexture(iconTexture)
            
            if pin.glow then
                pin.glow:SetSize(glowSize, glowSize)
            end
            
            pin:Show()
            if pin.animGroup then
                pin.animGroup:Play()
            end
            
            -- Position and show the highlight box
            highlight:SetSize(highlightSize, highlightSize)
            highlight:ClearAllPoints()
            highlight:SetPoint("CENTER", pin, "CENTER", 0, 0)
            highlight:Show()
            if highlight.animGroup then
                highlight.animGroup:Play()
            end
            
            -- Position and show the arrow
            arrow:SetSize(arrowSize, arrowSize)
            if arrow.glow then
                arrow.glow:SetSize(arrowGlowSize, arrowGlowSize)
            end
            arrow:ClearAllPoints()
            arrow:SetPoint("BOTTOM", highlight, "TOP", 0, 2)
            arrow:Show()
            if arrow.animGroup then
                arrow.animGroup:Play()
            end
        end
    end
end

function MapSearch:ShowWaypointAt(x, y, icon, category)
    self:ClearHighlight()
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local canvasWidth, canvasHeight = canvas:GetSize()
    
    -- Scale elements based on canvas size - larger maps need bigger icons
    -- Base size assumes ~600px canvas, scale up for larger maps
    local scaleFactor = mmax(1, mmin(canvasWidth, canvasHeight) / 600)
    
    -- Apply user's icon scale preference
    local userScale = EasyFind.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local iconSize = 56 * scaleFactor
    local glowSize = 90 * scaleFactor
    local highlightSize = 70 * scaleFactor
    -- ARROWS ARE FIXED SIZE - do not scale with map!
    local arrowSize = 128  -- FIXED
    local arrowGlowSize = 180  -- FIXED
    
    -- Resize the pin and glow
    waypointPin:SetSize(iconSize, iconSize)
    waypointPin.glow:SetSize(glowSize, glowSize)
    
    -- Use category icon if no specific icon provided
    local iconTexture = GetCategoryIcon(category or "unknown")
    if icon then
        iconTexture = icon
    end
    waypointPin.icon:SetTexture(iconTexture)
    waypointPin:ClearAllPoints()
    waypointPin:SetPoint("CENTER", canvas, "TOPLEFT", canvasWidth * x, -canvasHeight * y)
    waypointPin:Show()
    
    -- Start pin animation (pulsing glow)
    if waypointPin.animGroup then
        waypointPin.animGroup:Play()
    end
    
    -- Resize and position highlight
    highlightFrame:SetSize(highlightSize, highlightSize)
    highlightFrame:ClearAllPoints()
    highlightFrame:SetPoint("CENTER", waypointPin, "CENTER", 0, 0)
    highlightFrame:Show()
    
    -- Resize arrow and its glow
    arrowFrame:SetSize(arrowSize, arrowSize)
    arrowFrame.glow:SetSize(arrowGlowSize, arrowGlowSize)
    arrowFrame:Show()
    
    if highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
    if arrowFrame.animGroup then
        arrowFrame.animGroup:Play()
    end
end

function MapSearch:HighlightPin(pin)
    waypointPin:Hide()
    
    if not pin or not pin:IsShown() then
        self:ClearHighlight()
        return
    end
    
    currentHighlightedPin = pin
    
    -- Get canvas size for scaling
    local canvas = WorldMapFrame.ScrollContainer.Child
    local canvasWidth, canvasHeight = 700, 700
    if canvas then
        canvasWidth, canvasHeight = canvas:GetSize()
    end
    local scaleFactor = mmax(1, mmin(canvasWidth, canvasHeight) / 600)
    
    -- Apply user's icon scale preference
    local userScale = EasyFind.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local width, height = pin:GetSize()
    width = mmax(width or 24, 36 * scaleFactor)
    height = mmax(height or 24, 36 * scaleFactor)
    
    -- ARROWS ARE FIXED SIZE - do not scale with map!
    local arrowSize = 128  -- FIXED
    local arrowGlowSize = 180  -- FIXED
    arrowFrame:SetSize(arrowSize, arrowSize)
    arrowFrame.glow:SetSize(arrowGlowSize, arrowGlowSize)
    
    highlightFrame:SetSize(width, height)
    highlightFrame:ClearAllPoints()
    highlightFrame:SetPoint("CENTER", pin, "CENTER", 0, 0)
    highlightFrame:Show()
    arrowFrame:Show()
    
    if highlightFrame.animGroup then
        highlightFrame.animGroup:Play()
    end
    if arrowFrame.animGroup then
        arrowFrame.animGroup:Play()
    end
end

function MapSearch:ClearHighlight()
    highlightFrame:Hide()
    arrowFrame:Hide()
    waypointPin:Hide()
    if highlightFrame.animGroup then
        highlightFrame.animGroup:Stop()
    end
    if arrowFrame.animGroup then
        arrowFrame.animGroup:Stop()
    end
    if waypointPin.animGroup then
        waypointPin.animGroup:Stop()
    end
    
    -- Hide extra pins, highlights, and arrows for duplicate POIs
    if self.extraPins then
        for _, pin in ipairs(self.extraPins) do
            pin:Hide()
            if pin.animGroup then pin.animGroup:Stop() end
        end
    end
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            hl:Hide()
            if hl.animGroup then hl.animGroup:Stop() end
        end
    end
    if self.extraArrows then
        for _, arr in ipairs(self.extraArrows) do
            arr:Hide()
            if arr.animGroup then arr.animGroup:Stop() end
        end
    end
    
    currentHighlightedPin = nil
end

function MapSearch:UpdateScale()
    if searchFrame then
        local scale = EasyFind.db.mapSearchScale or 1.0
        searchFrame:SetScale(scale)
        if resultsFrame then
            resultsFrame:SetScale(scale)
        end
    end
end

function MapSearch:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 0)
        EasyFind.db.mapSearchPosition = nil
    end
end

function MapSearch:UpdateIconScales()
    -- This function is called when the user changes the map icon scale setting
    -- Update all visible pins, highlights, and arrows in real-time
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local canvasWidth, canvasHeight = canvas:GetSize()
    local scaleFactor = mmax(1, mmin(canvasWidth, canvasHeight) / 600)
    local userScale = EasyFind.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local iconSize = 56 * scaleFactor
    local glowSize = 90 * scaleFactor
    local highlightSize = 70 * scaleFactor
    -- ARROWS ARE FIXED SIZE - do not scale with map!
    local arrowSize = 128  -- FIXED
    local arrowGlowSize = 180  -- FIXED
    
    -- Update main waypoint pin if visible
    if waypointPin and waypointPin:IsShown() then
        waypointPin:SetSize(iconSize, iconSize)
        if waypointPin.glow then
            waypointPin.glow:SetSize(glowSize, glowSize)
        end
    end
    
    -- Update main highlight frame if visible
    if highlightFrame and highlightFrame:IsShown() then
        highlightFrame:SetSize(highlightSize, highlightSize)
    end
    
    -- Update main arrow frame if visible
    if arrowFrame and arrowFrame:IsShown() then
        arrowFrame:SetSize(arrowSize, arrowSize)
        if arrowFrame.glow then
            arrowFrame.glow:SetSize(arrowGlowSize, arrowGlowSize)
        end
    end
    
    -- Update extra pins for duplicates
    local multiIconSize = 48 * scaleFactor
    local multiGlowSize = 72 * scaleFactor
    local multiHighlightSize = 60 * scaleFactor
    -- ARROWS ARE FIXED SIZE - do not scale with map!
    local multiArrowSize = 128  -- FIXED
    local multiArrowGlowSize = 180  -- FIXED
    
    if self.extraPins then
        for _, pin in ipairs(self.extraPins) do
            if pin:IsShown() then
                pin:SetSize(multiIconSize, multiIconSize)
                if pin.glow then
                    pin.glow:SetSize(multiGlowSize, multiGlowSize)
                end
            end
        end
    end
    
    if self.extraHighlights then
        for _, hl in ipairs(self.extraHighlights) do
            if hl:IsShown() then
                hl:SetSize(multiHighlightSize, multiHighlightSize)
            end
        end
    end
    
    if self.extraArrows then
        for _, arr in ipairs(self.extraArrows) do
            if arr:IsShown() then
                arr:SetSize(multiArrowSize, multiArrowSize)
                if arr.glow then
                    arr.glow:SetSize(multiArrowGlowSize, multiArrowGlowSize)
                end
            end
        end
    end
end
