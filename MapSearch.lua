local ADDON_NAME, ns = ...

local MapSearch = {}
ns.MapSearch = MapSearch

local searchFrame
local resultsFrame
local resultButtons = {}
local MAX_RESULTS = 10
local highlightFrame
local arrowFrame
local currentHighlightedPin
local waypointPin

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

-- Built-in static locations - these can be supplemented by user-recorded POIs
-- Use /recordpoi in-game to add more locations
-- Note: Coordinates are normalized 0-1 (multiply by 100 for percentage display)
local STATIC_LOCATIONS = {
    -- Add verified locations here as they are recorded in-game
    -- The CoordRecorder module will pull from FindItPOIDB (user-recorded)
    -- and these will be combined
}

function MapSearch:Initialize()
    self:CreateSearchFrame()
    self:CreateResultsFrame()
    self:CreateHighlightFrame()
    self:HookWorldMap()
    self:UpdateScale()
end

function MapSearch:CreateSearchFrame()
    searchFrame = CreateFrame("Frame", "FindItMapSearchFrame", WorldMapFrame, "BackdropTemplate")
    searchFrame:SetSize(250, 32)
    searchFrame:SetFrameStrata("DIALOG")
    searchFrame:SetFrameLevel(9999)
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetToplevel(true)
    
    -- Apply saved position or default
    if FindIt.db.mapSearchPosition then
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", FindIt.db.mapSearchPosition, 0)
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
            newX = math.max(0, math.min(newX, maxX))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", newX, 0)
            FindIt.db.mapSearchPosition = newX
        elseif self.isDragging then
            self.isDragging = false
        end
    end)
    
    local searchIcon = searchFrame:CreateTexture(nil, "ARTWORK")
    searchIcon:SetSize(14, 14)
    searchIcon:SetPoint("LEFT", 10, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    
    local editBox = CreateFrame("EditBox", "FindItMapSearchBox", searchFrame)
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
    
    -- Clear button
    local clearBtn = CreateFrame("Button", nil, searchFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 22)
    clearBtn:SetPoint("RIGHT", searchFrame, "RIGHT", -6, 0)
    clearBtn:SetText("Clear Icons")
    clearBtn:EnableMouse(true)
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        editBox.placeholder:Show()
        MapSearch:HideResults()
        MapSearch:ClearHighlight()
    end)
    clearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all map icons")
        GameTooltip:Show()
    end)
    clearBtn:SetScript("OnLeave", GameTooltip_Hide)
    searchFrame.clearBtn = clearBtn
    
    searchFrame.editBox = editBox
    searchFrame:Hide()
end

function MapSearch:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "FindItMapResultsFrame", searchFrame, "BackdropTemplate")
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
    local btn = CreateFrame("Button", "FindItMapResultButton"..index, resultsFrame)
    btn:SetSize(280, 24)
    btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, -10 - (index - 1) * 26)
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 5, 0)
    btn.icon = icon
    
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
    highlightFrame = CreateFrame("Frame", "FindItMapHighlight", WorldMapFrame.ScrollContainer.Child)
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
    
    -- Arrow pointing down to the location - VERY LARGE and visible
    arrowFrame = CreateFrame("Frame", "FindItMapArrow", highlightFrame)
    arrowFrame:SetSize(100, 100)  -- Very large arrow
    arrowFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 20)
    
    local arrow = arrowFrame:CreateTexture(nil, "ARTWORK")
    arrow:SetAllPoints()
    arrow:SetTexture("Interface\\MINIMAP\\MiniMap-QuestArrow")
    arrow:SetVertexColor(1, 1, 0, 1)
    arrow:SetRotation(math.pi)  -- Point downward
    arrowFrame.arrow = arrow
    
    -- Add glow behind arrow for visibility
    local arrowGlow = arrowFrame:CreateTexture(nil, "BACKGROUND")
    arrowGlow:SetSize(140, 140)  -- Large glow for visibility
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
    waypointPin = CreateFrame("Frame", "FindItLocationPin", WorldMapFrame.ScrollContainer.Child)
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

function MapSearch:HookWorldMap()
    WorldMapFrame:HookScript("OnShow", function()
        searchFrame:Show()
    end)
    
    WorldMapFrame:HookScript("OnHide", function()
        searchFrame:Hide()
        self:HideResults()
        self:ClearHighlight()
    end)
    
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        self:HideResults()
        self:ClearHighlight()
        searchFrame.editBox:SetText("")
        searchFrame.editBox.placeholder:Show()
    end)
end

function MapSearch:GetCategoryMatch(query)
    query = string.lower(query)
    local matchedCategory = nil
    local matchScore = 0
    local isExactCategoryMatch = false
    
    for catName, catData in pairs(CATEGORIES) do
        for _, keyword in ipairs(catData.keywords) do
            local kw = string.lower(keyword)
            if kw == query then
                return catName, 100, true
            elseif string.find(kw, query, 1, true) and #query >= 3 then
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
        table.insert(related, catData.parent)
        -- Do NOT add sibling categories - that causes "pvp" to show "auction house"
    end
    
    -- Add children of this category (if searching for a parent like "service" or "travel")
    for catName, data in pairs(CATEGORIES) do
        if data.parent == category then
            table.insert(related, catName)
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
            table.insert(results, {
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
    
    -- Also check FindItDevDB for dev/testing (raw POIs from recorder)
    if FindItDevDB and FindItDevDB.rawPOIs then
        for _, poi in ipairs(FindItDevDB.rawPOIs) do
            if poi.mapID == mapID then
                table.insert(results, {
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
    local areaPOIs = C_AreaPoiInfo.GetAreaPOIForMap(mapID)
    if areaPOIs then
        for _, poiID in ipairs(areaPOIs) do
            local poiInfo = C_AreaPoiInfo.GetAreaPOIInfo(mapID, poiID)
            if poiInfo and poiInfo.name then
                local category = "areapoi"
                local poiName = string.lower(poiInfo.name or "")
                local desc = string.lower(poiInfo.description or "")
                
                if string.find(poiName, "zeppelin") or string.find(poiName, "airship") or string.find(desc, "zeppelin") then
                    category = "zeppelin"
                elseif string.find(poiName, "boat") or string.find(poiName, "ship") or string.find(poiName, "ferry") or string.find(desc, "boat") then
                    category = "boat"
                elseif string.find(poiName, "portal") or string.find(desc, "portal") then
                    category = "portal"
                elseif string.find(poiName, "tram") or string.find(desc, "tram") then
                    category = "tram"
                elseif string.find(poiName, "great vault") or string.find(poiName, "vault") then
                    category = "greatvault"
                elseif string.find(poiName, "catalyst") then
                    category = "catalyst"
                elseif string.find(poiName, "pvp") or string.find(poiName, "arena") or string.find(poiName, "battleground") or string.find(desc, "pvp") or string.find(poiName, "conquest") or string.find(poiName, "honor") or string.find(poiName, "weekly") or string.find(desc, "weekly") then
                    category = "pvpvendor"
                end
                
                table.insert(pois, {
                    name = poiInfo.name,
                    pin = nil,  -- API-based, no pin reference
                    pinType = category,
                    category = category,
                    icon = poiInfo.textureIndex,
                    isStatic = true,
                    x = poiInfo.position.x,
                    y = poiInfo.position.y,
                })
            end
        end
    end
    
    -- Second: Scan all children of the map canvas for pins
    for _, pin in pairs({canvas:GetChildren()}) do
        if pin and pin:IsShown() then
            local info = self:GetPinInfo(pin)
            if info then
                table.insert(pois, info)
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
        
        local poiName = string.lower(name or "")
        local poiDesc = string.lower(pin.areaPoiInfo.description or "")
        if string.find(poiName, "zeppelin") or string.find(poiName, "airship") then
            category = "zeppelin"
            pinType = "zeppelin"
        elseif string.find(poiName, "boat") or string.find(poiName, "ship") or string.find(poiName, "ferry") then
            category = "boat"
            pinType = "boat"
        elseif string.find(poiName, "portal") then
            category = "portal"
            pinType = "portal"
        elseif string.find(poiName, "tram") then
            category = "tram"
            pinType = "tram"
        elseif string.find(poiName, "pvp") or string.find(poiName, "arena") or string.find(poiName, "battleground") or string.find(poiDesc, "pvp") or string.find(poiName, "conquest") or string.find(poiName, "honor") or string.find(poiName, "weekly") then
            category = "pvpvendor"
            pinType = "pvpvendor"
        else
            -- Generic area POI - keep it
            category = "areapoi"
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
        return
    end
    
    -- Get both dynamic pins and static locations for current map
    local dynamicPOIs = self:ScanMapPOIs()
    local staticLocations = self:GetStaticLocations()
    
    -- Combine them
    local allPOIs = {}
    for _, poi in ipairs(dynamicPOIs) do
        table.insert(allPOIs, poi)
    end
    for _, loc in ipairs(staticLocations) do
        table.insert(allPOIs, loc)
    end
    
    local results = self:SearchPOIs(allPOIs, text)
    self:ShowResults(results)
end

function MapSearch:SearchPOIs(pois, query)
    query = string.lower(query)
    local results = {}
    local seen = {}
    
    local matchedCategory, catScore, isExactCategoryMatch = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or {}
    
    -- First pass: name matches
    for _, poi in ipairs(pois) do
        local nameLower = string.lower(poi.name)
        local key = poi.name .. (poi.category or "")
        
        if not seen[key] then
            local score = 0
            
            if nameLower == query then
                score = 300
            elseif string.find(nameLower, query, 1, true) then
                score = 200
            end
            
            -- Also check custom keywords for static locations
            if poi.keywords and score == 0 then
                for _, kw in ipairs(poi.keywords) do
                    if string.find(string.lower(kw), query, 1, true) then
                        score = 180
                        break
                    end
                end
            end
            
            if score > 0 then
                seen[key] = true
                poi.score = score
                table.insert(results, poi)
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
                    seen[key] = true
                    poi.score = score
                    table.insert(results, poi)
                end
            end
        end
    end
    
    table.sort(results, function(a, b) return a.score > b.score end)
    return results
end

function MapSearch:ShowResults(results)
    if not results or #results == 0 then
        self:HideResults()
        return
    end
    
    local count = math.min(#results, MAX_RESULTS)
    
    for i = 1, MAX_RESULTS do
        local btn = resultButtons[i]
        if i <= count then
            local data = results[i]
            btn.data = data
            btn.text:SetText(data.name)
            
            -- Use category icon (data.icon is usually nil, so this gets category icon)
            local iconTexture = GetCategoryIcon(data.category)
            if data.icon then
                iconTexture = data.icon
            end
            btn.icon:SetTexture(iconTexture)
            btn.icon:Show()
            
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
        -- If we have coordinates, show the location pin (works for both static and API-based POIs)
        if data.x and data.y then
            self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
        elseif data.pin then
            -- Dynamic pin with no coords - highlight it directly
            self:HighlightPin(data.pin)
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
    local scaleFactor = math.max(1, math.min(canvasWidth, canvasHeight) / 600)
    
    -- Apply user's icon scale preference
    local userScale = FindIt.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local iconSize = 56 * scaleFactor
    local glowSize = 90 * scaleFactor
    local highlightSize = 70 * scaleFactor
    local arrowSize = 100 * scaleFactor
    local arrowGlowSize = 140 * scaleFactor
    
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
    local scaleFactor = math.max(1, math.min(canvasWidth, canvasHeight) / 600)
    
    -- Apply user's icon scale preference
    local userScale = FindIt.db.mapIconScale or 1.0
    scaleFactor = scaleFactor * userScale
    
    local width, height = pin:GetSize()
    width = math.max(width or 24, 36 * scaleFactor)
    height = math.max(height or 24, 36 * scaleFactor)
    
    -- Scale arrow for this map
    local arrowSize = 100 * scaleFactor
    local arrowGlowSize = 140 * scaleFactor
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
    currentHighlightedPin = nil
end

function MapSearch:UpdateScale()
    if searchFrame then
        local scale = FindIt.db.mapSearchScale or 1.0
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
        FindIt.db.mapSearchPosition = nil
    end
end

function MapSearch:UpdateIconScales()
    -- This function is called when the user changes the map icon scale setting
    -- The icons are created dynamically during search, so we just need to
    -- update the waypointPin if it's visible
    if waypointPin and waypointPin:IsShown() then
        local scale = FindIt.db.mapIconScale or 1.0
        local baseSize = 32 * scale
        waypointPin:SetSize(baseSize, baseSize)
        if waypointPin.glow then
            waypointPin.glow:SetSize(baseSize * 1.5, baseSize * 1.5)
        end
    end
end