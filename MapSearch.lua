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

local CreateFrame        = CreateFrame
local C_Map              = C_Map
local C_Timer            = C_Timer
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local UIParent           = UIParent
local IsShiftKeyDown     = IsShiftKeyDown
local IsMouseButtonDown  = IsMouseButtonDown
local hooksecurefunc     = hooksecurefunc
local wipe               = wipe
local strsplit           = strsplit

-- =============================================================================
-- ARROW THEME DEFINITIONS
-- =============================================================================
local ARROW_STYLES = {
    ["Classic Quest Arrow"] = {
        texture = "Interface\\MINIMAP\\MiniMap-QuestArrow",
        texCoord = nil,
        preRotated = false,  -- Needs mpi rotation to point down
    },
    ["EasyFind Arrow"] = {
        texture = "Interface\\AddOns\\EasyFind\\Images\\arrow-hq",
        texCoord = nil,
        preRotated = true,   -- Already points down, no rotation needed
    },
    ["Minimap Player Arrow"] = {
        texture = "Interface\\Minimap\\MinimapArrow",
        texCoord = nil,
        preRotated = false,
    },
    ["Cursor Point"] = {
        texture = "Interface\\CURSOR\\Point",
        texCoord = nil,
        preRotated = true,
        rotation = 2.356,
        offsetX = 0,   -- Shift right to center fingertip
        offsetY = 0,  -- Shift down to center fingertip
    },
}

-- Arrow color presets
local ARROW_COLORS = {
    ["Yellow"]  = {1.0, 1.0, 0.0},
    ["Gold"]    = {1.0, 0.82, 0.0},
    ["Orange"]  = {1.0, 0.5, 0.0},
    ["Red"]     = {1.0, 0.2, 0.2},
    ["Green"]   = {0.2, 1.0, 0.2},
    ["Blue"]    = {0.3, 0.6, 1.0},
    ["Purple"]  = {0.7, 0.3, 1.0},
    ["White"]   = {1.0, 1.0, 1.0},
}

local function GetArrowColor()
    local colorName = EasyFind.db.arrowColor or "Yellow"
    return ARROW_COLORS[colorName] or ARROW_COLORS["Yellow"]
end

-- Store in namespace so all modules can access it
ns.GetArrowTexture = function()
    local style = EasyFind.db.arrowStyle or "EasyFind Arrow"
    return ARROW_STYLES[style] or ARROW_STYLES["EasyFind Arrow"]
end
ns.GetArrowColor = GetArrowColor
ns.ARROW_STYLES = ARROW_STYLES
ns.ARROW_COLORS = ARROW_COLORS

local GetArrowTexture = ns.GetArrowTexture

-- =============================================================================
-- UNIFIED SIZING — all values are in UI coordinate units (same as UIParent).
-- Map code converts to canvas units via ns.UIToCanvas() so visual size matches.
-- Changing a value here changes BOTH map and UI icons uniformly.
-- =============================================================================

-- Single-pin group (the indicator icon + pin + highlight are always sized together)
ns.ICON_SIZE         = 48   -- Indicator icon (arrow/pointer/cursor)
ns.ICON_GLOW_SIZE    = 68   -- Glow behind indicator icon
ns.PIN_SIZE          = 56   -- Map pin icon (category icon, e.g. auction house)
ns.PIN_GLOW_SIZE     = 80   -- Map pin glow
ns.HIGHLIGHT_SIZE    = 60   -- Yellow highlight border box

-- Multi-pin (slightly smaller so clusters don't overlap)
ns.MULTI_SCALE       = 0.85

-- Zone indicator (continent maps)
ns.ZONE_ICON_SIZE      = 48
ns.ZONE_ICON_GLOW_SIZE = 68

-- Breadcrumb indicator
ns.BREADCRUMB_SIZE   = 48

--- Convert a size in UI units to canvas units so it appears the same visual
--- size as a same-valued element on UIParent.
--- WoW's map zooms by making the canvas LARGER, not by changing scale.
--- So the conversion is: canvasWidth / viewportWidth (canvas units per screen unit).
--- @param uiSize number  size in UI coordinate units
--- @return number  equivalent canvas coordinate units
function ns.UIToCanvas(uiSize)
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not sc or not sc.Child then return uiSize end
    local canvasW  = sc.Child:GetWidth()
    local viewportW = sc:GetWidth()
    if not canvasW or canvasW == 0 or not viewportW or viewportW == 0 then
        return uiSize
    end
    return uiSize * (canvasW / viewportW)
end

-- =============================================================================
-- SHARED ICON CREATION / UPDATE
-- Every indicator icon in the addon (map search, zone search, UI search, breadcrumb)
-- MUST use these two functions so they all look identical.
-- =============================================================================

--- Create icon + glow textures on a parent frame.
--- Returns nothing; sets parentFrame.arrow and parentFrame.glow.
--- @param parentFrame Frame  - the frame the icon sits in
--- @param iconSize number|nil  - override size (defaults to ns.ICON_SIZE)
--- @param glowSize number|nil  - override glow (defaults to ns.ICON_GLOW_SIZE; 0 = no glow)
function ns.CreateArrowTextures(parentFrame, iconSize, glowSize)
    iconSize = iconSize or ns.ICON_SIZE
    glowSize = glowSize or ns.ICON_GLOW_SIZE
    local style = GetArrowTexture()
    local color = GetArrowColor()
    local ox, oy = style.offsetX or 0, style.offsetY or 0

    -- Icon texture
    local arrow = parentFrame:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(iconSize, iconSize)
    arrow:SetPoint("CENTER", parentFrame, "CENTER", ox, oy)
    arrow:SetTexture(style.texture)
    if style.texCoord then
        arrow:SetTexCoord(unpack(style.texCoord))
    end
    arrow:SetVertexColor(color[1], color[2], color[3], 1)
    if style.rotation then
        arrow:SetRotation(style.rotation)
    elseif not style.preRotated then
        arrow:SetRotation(mpi)
    end
    parentFrame.arrow = arrow

    -- Glow texture (optional)
    if glowSize and glowSize > 0 then
        local glow = parentFrame:CreateTexture(nil, "BACKGROUND")
        glow:SetSize(glowSize, glowSize)
        glow:SetPoint("CENTER")
        glow:SetTexture("Interface\\Cooldown\\star4")
        glow:SetVertexColor(color[1], color[2], color[3], 0.7)
        glow:SetBlendMode("ADD")
        parentFrame.glow = glow
    end

    -- Auto-update on every Show so arrows are ALWAYS in sync with settings.
    parentFrame:HookScript("OnShow", function(self)
        ns.UpdateArrow(self)
    end)
end

--- Update an existing arrow (and optional glow) to match current settings.
--- Works on any frame that was set up with ns.CreateArrowTextures.
--- @param parentFrame Frame
function ns.UpdateArrow(parentFrame)
    if not parentFrame or not parentFrame.arrow then return end
    local style = GetArrowTexture()
    local color = GetArrowColor()
    local tex = parentFrame.arrow
    local ox, oy = style.offsetX or 0, style.offsetY or 0

    tex:SetTexture(style.texture)
    if style.texCoord then
        tex:SetTexCoord(unpack(style.texCoord))
    else
        tex:SetTexCoord(0, 1, 0, 1)
    end
    -- Use directional override if set, otherwise use style default
    if parentFrame.arrowDirection then
        tex:SetRotation(ns.GetDirectionalRotation(parentFrame.arrowDirection))
    elseif style.rotation then
        tex:SetRotation(style.rotation)
    elseif style.preRotated then
        tex:SetRotation(0)
    else
        tex:SetRotation(mpi)
    end
    tex:SetVertexColor(color[1], color[2], color[3], 1)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", parentFrame, "CENTER", ox, oy)

    -- Sync texture size to frame size (frame gets resized at show time;
    -- the texture must match or it stays at its creation-time size).
    local fw, fh = parentFrame:GetSize()
    if fw and fw > 0 then
        tex:SetSize(fw, fh)
    end

    if parentFrame.glow then
        parentFrame.glow:SetVertexColor(color[1], color[2], color[3], 0.7)
    end

    -- Apply user icon scale to UI arrows (map arrows handle scale in their own sizing code)
    if parentFrame.isUIArrow then
        parentFrame:SetScale(EasyFind.db.iconScale or 1.0)
    end
end

--- Compute the rotation for an arrow pointing in a given direction.
--- Takes the style's own rotation into account so every style works correctly.
--- @param direction string "down"|"up"|"left"|"right"
--- @return number rotation in radians
function ns.GetDirectionalRotation(direction)
    local style = GetArrowTexture()
    -- Base rotation is whatever points the arrow downward:
    --   preRotated arrows already point down at rotation=0
    --   non-preRotated arrows point down at rotation=mpi
    local baseDown = style.rotation or (style.preRotated and 0 or mpi)
    if direction == "down" then
        return baseDown
    elseif direction == "up" then
        return baseDown + mpi      -- flip 180°
    elseif direction == "right" then
        return baseDown - mpi / 2  -- 90° CW
    elseif direction == "left" then
        return baseDown + mpi / 2  -- 90° CCW
    end
    return baseDown
end

local searchFrame       -- Local search bar (left)
local globalSearchFrame -- Global search bar (right)
local activeSearchFrame -- Which bar is currently active
local resultsFrame
local resultButtons = {}
local MAX_RESULTS = 12
local highlightFrame
local arrowFrame
local currentHighlightedPin
local waypointPin
local zoneHighlightFrame  -- For highlighting zones on continent maps
local isGlobalSearch = false  -- Tracks which search bar triggered the current search

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
    self:UpdateOpacity()
end

function MapSearch:CreateSearchFrame()
    -- =====================================================================
    -- LOCAL search bar (left side — searches current map's child zones + POIs)
    -- =====================================================================
    searchFrame = CreateFrame("Frame", "EasyFindMapSearchFrame", WorldMapFrame, "BackdropTemplate")
    searchFrame:SetSize(250, 32)
    searchFrame:SetFrameStrata("DIALOG")
    searchFrame:SetFrameLevel(9999)
    searchFrame:SetMovable(true)
    searchFrame:EnableMouse(true)
    searchFrame:SetToplevel(true)
    
    -- Apply saved position or default (left side)
    if EasyFind.db.mapSearchPosition then
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", EasyFind.db.mapSearchPosition, 0)
    else
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 0)
    end
    
    -- Apply theme-appropriate backdrop
    if (EasyFind.db.resultsTheme or "Classic") == "Retail" then
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        searchFrame:SetBackdropColor(0.45, 0.45, 0.45, 0.95)
        searchFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    else
        searchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end
    
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
    searchIcon:SetVertexColor(1, 0.82, 0)  -- Gold tint to match local theme
    
    local editBox = CreateFrame("EditBox", "EasyFindMapSearchBox", searchFrame)
    editBox:SetSize(150, 20)
    editBox:SetPoint("LEFT", searchIcon, "RIGHT", 5, 0)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(50)
    
    local placeholder = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search this zone")
    editBox.placeholder = placeholder
    
    editBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
        -- Clear the other search bar when focusing this one
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox:ClearFocus()
            globalSearchFrame.editBox.placeholder:Show()
        end
        isGlobalSearch = false
        activeSearchFrame = searchFrame
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
        isGlobalSearch = false
        activeSearchFrame = searchFrame
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
    
    -- Clear button (grey circle X, matching retail quest log style)
    local clearBtn = Utils.CreateClearButton(searchFrame)
    
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
        editBox.placeholder:Show()
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox:ClearFocus()
            globalSearchFrame.editBox.placeholder:Show()
        end
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
    
    -- Show/hide clear button based on text
    editBox:HookScript("OnTextChanged", function(self)
        clearBtn:SetShown(self:GetText() ~= "")
    end)
    
    -- Click anywhere on the search frame to focus the editbox
    searchFrame:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            editBox:SetFocus()
        end
    end)
    
    -- Invisible button over the icon to capture hover for tooltip
    local searchIconHitbox = CreateFrame("Button", nil, searchFrame)
    searchIconHitbox:SetSize(22, 22)
    searchIconHitbox:SetPoint("CENTER", searchIcon, "CENTER", 0, 0)
    searchIconHitbox:SetFrameLevel(searchFrame:GetFrameLevel() + 2)
    searchIconHitbox:EnableMouse(true)
    searchIconHitbox:RegisterForClicks()
    searchIconHitbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFFFFD100This Zone|r Search")
        GameTooltip:AddLine("Searches for POIs and sub-zones within the map you're currently viewing.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    searchIconHitbox:SetScript("OnLeave", GameTooltip_Hide)
    searchIconHitbox:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            editBox:SetFocus()
        end
    end)

    searchFrame.editBox = editBox
    searchFrame:Hide()
    
    -- =====================================================================
    -- GLOBAL search bar (right side — searches all zones in the world)
    -- =====================================================================
    globalSearchFrame = CreateFrame("Frame", "EasyFindMapGlobalSearchFrame", WorldMapFrame, "BackdropTemplate")
    globalSearchFrame:SetSize(250, 32)
    globalSearchFrame:SetFrameStrata("DIALOG")
    globalSearchFrame:SetFrameLevel(9999)
    globalSearchFrame:SetMovable(true)
    globalSearchFrame:EnableMouse(true)
    globalSearchFrame:SetToplevel(true)
    
    -- Position on the right side (anchored to bottom-right of the map scroll container)
    if EasyFind.db.globalSearchPosition then
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", EasyFind.db.globalSearchPosition, 0)
    else
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", 0, 0)
    end
    
    -- Apply theme-appropriate backdrop
    if (EasyFind.db.resultsTheme or "Classic") == "Retail" then
        globalSearchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        globalSearchFrame:SetBackdropColor(0.45, 0.45, 0.45, 0.95)
        globalSearchFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    else
        globalSearchFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end
    
    -- Draggable with Shift key (constrained to map bottom edge)
    globalSearchFrame:RegisterForDrag("LeftButton")
    globalSearchFrame:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self.isDragging = true
        end
    end)
    globalSearchFrame:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)
    globalSearchFrame:SetScript("OnUpdate", function(self)
        if self.isDragging and IsShiftKeyDown() then
            local cursorX = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            local mapLeft = WorldMapFrame.ScrollContainer:GetLeft() * scale
            local mapRight = WorldMapFrame.ScrollContainer:GetRight() * scale
            
            -- Calculate new X position relative to map RIGHT edge (negative offset)
            local newX = (cursorX - mapRight) / scale + (self:GetWidth() / 2)
            
            -- Constrain
            local maxNeg = -((mapRight - mapLeft) / scale - self:GetWidth())
            newX = mmin(0, mmax(newX, maxNeg))
            
            self:ClearAllPoints()
            self:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", newX, 0)
            EasyFind.db.globalSearchPosition = newX
        elseif self.isDragging then
            self.isDragging = false
        end
    end)
    
    local globalSearchIcon = globalSearchFrame:CreateTexture(nil, "ARTWORK")
    globalSearchIcon:SetSize(14, 14)
    globalSearchIcon:SetPoint("LEFT", 10, 0)
    globalSearchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    globalSearchIcon:SetVertexColor(0.4, 0.8, 1)  -- Blue tint to match global theme
    
    local globalEditBox = CreateFrame("EditBox", "EasyFindMapGlobalSearchBox", globalSearchFrame)
    globalEditBox:SetSize(150, 20)
    globalEditBox:SetPoint("LEFT", globalSearchIcon, "RIGHT", 5, 0)
    globalEditBox:SetFontObject("ChatFontNormal")
    globalEditBox:SetAutoFocus(false)
    globalEditBox:SetMaxLetters(50)
    
    local globalPlaceholder = globalEditBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    globalPlaceholder:SetPoint("LEFT", 2, 0)
    globalPlaceholder:SetText("Search all zones")
    globalEditBox.placeholder = globalPlaceholder
    
    globalEditBox:SetScript("OnEditFocusGained", function(self)
        self.placeholder:Hide()
        -- Clear the other search bar when focusing this one
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox:SetText("")
            searchFrame.editBox:ClearFocus()
            searchFrame.editBox.placeholder:Show()
        end
        isGlobalSearch = true
        activeSearchFrame = globalSearchFrame
    end)
    
    globalEditBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then
            self.placeholder:Show()
        end
    end)
    
    globalEditBox:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then
            self.placeholder:Hide()
        end
        isGlobalSearch = true
        activeSearchFrame = globalSearchFrame
        MapSearch:OnSearchTextChanged(self:GetText())
    end)
    
    globalEditBox:SetScript("OnEnterPressed", function(self)
        MapSearch:SelectFirstResult()
    end)
    
    globalEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText("")
        self.placeholder:Show()
        MapSearch:HideResults()
        MapSearch:ClearHighlight()
        MapSearch:ClearZoneHighlight()
    end)
    
    -- Clear button for global search (grey circle X)
    local globalClearBtn = Utils.CreateClearButton(globalSearchFrame)
    
    globalClearBtn:SetScript("OnClick", function()
        globalEditBox:SetText("")
        globalEditBox:ClearFocus()
        globalEditBox.placeholder:Show()
        if searchFrame and searchFrame.editBox then
            searchFrame.editBox:SetText("")
            searchFrame.editBox:ClearFocus()
            searchFrame.editBox.placeholder:Show()
        end
        MapSearch:HideResults()
        MapSearch:ClearHighlight()
        MapSearch:ClearZoneHighlight()
    end)
    globalClearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Clear all map icons and zone highlights")
        GameTooltip:Show()
    end)
    globalClearBtn:SetScript("OnLeave", GameTooltip_Hide)
    globalSearchFrame.clearBtn = globalClearBtn
    
    -- Show/hide clear button based on text
    globalEditBox:HookScript("OnTextChanged", function(self)
        globalClearBtn:SetShown(self:GetText() ~= "")
    end)
    
    -- Click anywhere on the search frame to focus the editbox
    globalSearchFrame:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            globalEditBox:SetFocus()
        end
    end)
    
    -- Invisible button over the icon to capture hover for tooltip
    local globalIconHitbox = CreateFrame("Button", nil, globalSearchFrame)
    globalIconHitbox:SetSize(22, 22)
    globalIconHitbox:SetPoint("CENTER", globalSearchIcon, "CENTER", 0, 0)
    globalIconHitbox:SetFrameLevel(globalSearchFrame:GetFrameLevel() + 2)
    globalIconHitbox:EnableMouse(true)
    globalIconHitbox:RegisterForClicks()
    globalIconHitbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cFF66CCFFAll Zones|r Search")
        GameTooltip:AddLine("Searches every zone in the entire world \226\128\148 continents, dungeons, and more.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    globalIconHitbox:SetScript("OnLeave", GameTooltip_Hide)
    globalIconHitbox:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not IsShiftKeyDown() then
            globalEditBox:SetFocus()
        end
    end)

    globalSearchFrame.editBox = globalEditBox
    globalSearchFrame:Hide()
    
    -- Set initial active frame
    activeSearchFrame = searchFrame
end

function MapSearch:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindMapResultsFrame", WorldMapFrame, "BackdropTemplate")
    resultsFrame:SetWidth(300)
    resultsFrame:SetFrameStrata("TOOLTIP")
    resultsFrame:SetFrameLevel(1001)
    
    -- Default anchor to local search bar; will be re-anchored dynamically
    resultsFrame:SetPoint("BOTTOMLEFT", searchFrame, "TOPLEFT", 0, 2)
    
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

-- Indent line color for map search grouped results
local MAP_INDENT_COLOR = {0.40, 0.85, 1.00, 0.70}  -- cyan

function MapSearch:CreateResultButton(index)
    local btn = CreateFrame("Button", "EasyFindMapResultButton"..index, resultsFrame)
    btn:SetSize(280, 24)
    -- No fixed SetPoint here; ShowResults positions dynamically
    
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    
    -- Vertical indent line for grouped children
    local indentLine = btn:CreateTexture(nil, "BACKGROUND")
    indentLine:SetColorTexture(MAP_INDENT_COLOR[1], MAP_INDENT_COLOR[2], MAP_INDENT_COLOR[3], MAP_INDENT_COLOR[4])
    indentLine:SetWidth(2)
    indentLine:SetPoint("TOP", btn, "TOPLEFT", 14, 2)
    indentLine:SetPoint("BOTTOM", btn, "BOTTOMLEFT", 14, -2)
    indentLine:Hide()
    btn.indentLine = indentLine
    
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
    
    -- Arrow pointing down to the location
    arrowFrame = CreateFrame("Frame", "EasyFindMapArrow", highlightFrame)
    arrowFrame:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    arrowFrame:SetPoint("BOTTOM", highlightFrame, "TOP", 0, 2)
    ns.CreateArrowTextures(arrowFrame)
    
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
    
    -- Enable mouse so hovering over the final-location pin dismisses the highlight
    waypointPin:EnableMouse(true)
    waypointPin:SetScript("OnEnter", function()
        MapSearch:ClearHighlight()
    end)
    
    local wpIcon = waypointPin:CreateTexture(nil, "ARTWORK")
    wpIcon:SetAllPoints()
    waypointPin.icon = wpIcon
    
    -- Add a pulsing glow effect around the icon (ALWAYS YELLOW - this is a pin, not an arrow)
    local glow = waypointPin:CreateTexture(nil, "BACKGROUND")
    glow:SetSize(100, 100)
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
    
    -- Create a pool of highlight textures we can reuse (ALWAYS YELLOW)
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
    alpha:SetFromAlpha(0.75)
    alpha:SetToAlpha(0.5)
    alpha:SetDuration(0.5)
    zoneHighlightFrame.animGroup = animGroup
    
    -- Create arrow for zone highlighting
    local zoneArrow = CreateFrame("Frame", "EasyFindZoneArrow", WorldMapFrame.ScrollContainer.Child)
    zoneArrow:SetSize(ns.ICON_SIZE, ns.ICON_SIZE)
    zoneArrow:SetFrameStrata("TOOLTIP")
    zoneArrow:SetFrameLevel(500)
    ns.CreateArrowTextures(zoneArrow)
    
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
                -- Skip dungeon, micro, and orphan maps — only include navigable zones
                local mt = child.mapType
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
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
            
            -- Skip dungeon, micro, and orphan maps — only include navigable zones
            local mt = child.mapType
            if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
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
    end
    
    return allZones
end

-- Parent map overrides for guided navigation
-- Some zones have incorrect parentMapID in the WoW API, causing guided navigation
-- to route through maps where the target zone isn't clickable.
-- Maps [childMapID] = correctedParentMapID
local ZONE_PARENT_OVERRIDES = {
    [2346] = 2274, -- Undermine → Khaz Algar (API incorrectly says The Ringing Deeps 2214)
}

-- Search for zones matching query
-- Common abbreviations for major cities/zones
-- Maps lowercase abbreviation → lowercase zone name
local ZONE_ABBREVIATIONS = {
    ["sw"] = "stormwind city",
    ["stormwind"] = "stormwind city",
    ["og"] = "orgrimmar",
    ["org"] = "orgrimmar",
    ["if"] = "ironforge",
    ["tb"] = "thunder bluff",
    ["uc"] = "undercity",
    ["darn"] = "darnassus",
    ["exo"] = "the exodar",
    ["smc"] = "silvermoon city",
    ["silvermoon"] = "silvermoon city",
    ["dal"] = "dalaran",
    ["bb"] = "booty bay",
    ["sh"] = "shattrath city",
    ["shatt"] = "shattrath city",
    ["shat"] = "shattrath city",
    ["daz"] = "dazar'alor",
    ["bor"] = "boralus",
    ["orib"] = "oribos",
    ["vald"] = "valdrakken",
    ["zand"] = "zandalar",
    ["kt"] = "kul tiras",
    ["ek"] = "eastern kingdoms",
    ["kali"] = "kalimdor",
    ["dk"] = "acherus: the ebon hold",
}

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
    local abbrevTarget = ZONE_ABBREVIATIONS[query]  -- check once outside loop
    
    for _, zone in ipairs(zones) do
        local nameLower = slower(zone.name)
        local score = ns.Database:ScoreName(nameLower, query, #query)
        
        -- Check abbreviation match (e.g. "sw" → "stormwind city")
        if abbrevTarget and nameLower == abbrevTarget then
            score = mmax(score, 200)  -- Treat as exact match
        end
        
        if score >= 50 then
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
    local savedWaypoint = self.pendingWaypoint
    DebugPrint("[EasyFind] HighlightZone: saved pending:", savedPending)
    
    -- Hide previous highlights
    self:ClearZoneHighlight()
    
    -- Restore pending navigation
    self.pendingZoneHighlight = savedPending
    self.pendingWaypoint = savedWaypoint
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
    
    if highlightSuccess and fileDataID and fileDataID > 0 and posX and posY and texPercentX and texPercentY then
        DebugPrint("[EasyFind] HighlightZone: Using actual zone texture")
        -- Use the actual zone shape texture with correct positioning!
        -- IMPORTANT: posX, posY, texWidth, texHeight are NORMALIZED (0-1), must convert to pixels!
        local pixelPosX = posX * canvasWidth
        local pixelPosY = posY * canvasHeight
        local pixelWidth = texWidth * canvasWidth
        local pixelHeight = texHeight * canvasHeight
        
        -- Stack multiple layers of the zone texture for a stronger highlight effect.
        -- ADD blending is subtle on the light map, so layering 3x makes it really pop.
        local layers = 4
        for i = 1, layers do
            local hl = zoneHighlightFrame.highlights[i]
            if hl then
                hl:ClearAllPoints()
                hl:SetTexture(fileDataID)
                hl:SetTexCoord(0, texPercentX, 0, texPercentY)
                hl:SetVertexColor(1, 1, 0, 1)  -- Full bright yellow
                hl:SetBlendMode("ADD")
                hl:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelPosX, -pixelPosY)
                hl:SetSize(pixelWidth, pixelHeight)
                hl:Show()
            end
        end
        DebugPrint("[EasyFind] HighlightZone: stacked", layers, "layers at", pixelPosX, pixelPosY, "size", pixelWidth, pixelHeight)
    else
        DebugPrint("[EasyFind] HighlightZone: Using fallback colored overlay")
        -- Fallback: use a simple colored overlay on the zone bounds
        -- Make it VERY visible - bright yellow, high opacity (ALWAYS YELLOW)
        highlight:SetColorTexture(1, 1, 0, 0.75)
        highlight:SetBlendMode("BLEND")
        highlight:SetPoint("TOPLEFT", canvas, "TOPLEFT", zoneLeftPx, -zoneTopPx)
        highlight:SetSize(width, height)
        highlight:Show()
        DebugPrint("[EasyFind] HighlightZone: fallback at", zoneLeftPx, zoneTopPx, "size", width, height)
    end
    
    DebugPrint("[EasyFind] HighlightZone: About to show frame")
    zoneHighlightFrame:Show()
    DebugPrint("[EasyFind] HighlightZone: zoneHighlightFrame:IsShown() =", zoneHighlightFrame:IsShown())
    zoneHighlightFrame.animGroup:Play()
    DebugPrint("[EasyFind] HighlightZone: highlight and frame shown")
    
    -- Position arrow with smart bounds checking
    if zoneHighlightFrame.arrow then
        local arrow = zoneHighlightFrame.arrow
        -- Convert UI-unit sizes to canvas units so it's visible on continent maps
        local userScale = EasyFind.db.iconScale or 1.0
        local arrowSize     = ns.UIToCanvas(ns.ZONE_ICON_SIZE)      * userScale
        local arrowGlowSize = ns.UIToCanvas(ns.ZONE_ICON_GLOW_SIZE) * userScale
        arrow:SetSize(arrowSize, arrowSize)
        arrow:SetFrameStrata("TOOLTIP")
        arrow:SetFrameLevel(500)
        if arrow.glow then
            arrow.glow:SetSize(arrowGlowSize, arrowGlowSize)
        end
        -- DO NOT override color/texture here — OnShow hook handles it via ns.UpdateArrow
        local margin = 50
        
        arrow:ClearAllPoints()
        
        DebugPrint("[EasyFind] HighlightZone: arrow positioning - zoneTopPx:", zoneTopPx, "margin+arrowSize:", margin + arrowSize)
        
        -- Set direction on the frame — ns.UpdateArrow (via OnShow hook) reads this
        if zoneTopPx > margin + arrowSize then
            arrow.arrowDirection = "down"
            arrow:SetPoint("BOTTOM", canvas, "TOPLEFT", zoneCenterPxX, -(zoneTopPx - 10))
            DebugPrint("[EasyFind] Arrow placed ABOVE zone")
        elseif (canvasHeight - zoneBottomPx) > margin + arrowSize then
            arrow.arrowDirection = "up"
            arrow:SetPoint("TOP", canvas, "TOPLEFT", zoneCenterPxX, -(zoneBottomPx + 10))
            DebugPrint("[EasyFind] Arrow placed BELOW zone")
        elseif zoneLeftPx > margin + arrowSize then
            arrow.arrowDirection = "right"
            arrow:SetPoint("RIGHT", canvas, "TOPLEFT", zoneLeftPx - 10, -zoneCenterPxY)
            DebugPrint("[EasyFind] Arrow placed LEFT of zone")
        else
            arrow.arrowDirection = "left"
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
    
    DebugPrint("[EasyFind] HighlightZone: COMPLETE for zone:", mapInfo.name)
    
    return true
end

function MapSearch:ClearZoneHighlight()
    if not zoneHighlightFrame then return end
    
    for _, highlight in ipairs(zoneHighlightFrame.highlights) do
        highlight:Hide()
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
    self.pendingWaypoint = nil
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
    
    local targetParentMapID = ZONE_PARENT_OVERRIDES[targetMapID] or targetInfo.parentMapID
    if not targetParentMapID then
        DebugPrint("[EasyFind] No parent, going directly to zone")
        WorldMapFrame:SetMapID(targetMapID)
        return
    end
    
    if ZONE_PARENT_OVERRIDES[targetMapID] then
        DebugPrint("[EasyFind] Using parent override for", targetMapID, "→", targetParentMapID)
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
        -- Clear pendingZoneHighlight — this is the final zone-level step.
        -- When the user clicks into the zone, OnMapChanged should fall through
        -- to pendingWaypoint (if any) instead of re-triggering zone navigation.
        self.pendingZoneHighlight = nil
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
            currentID = ZONE_PARENT_OVERRIDES[currentID] or info.parentMapID
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
    local savedWaypoint = self.pendingWaypoint
    self:ClearZoneHighlight()
    
    local navBar = WorldMapFrame.NavBar
    if not navBar then 
        DebugPrint("[EasyFind] No NavBar found, direct nav to DCA")
        WorldMapFrame:SetMapID(dcaMapID)
        self.pendingZoneHighlight = savedPending
        self.pendingWaypoint = savedWaypoint
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
        self.pendingWaypoint = savedWaypoint
        self:ShowBreadcrumbHighlight(buttonToHighlight, savedPending)
    else
        DebugPrint("[EasyFind] No button found or not shown, navigating directly to DCA")
        -- CRITICAL: Set pending BEFORE SetMapID because SetMapID triggers OnMapChanged synchronously!
        self.pendingZoneHighlight = savedPending
        self.pendingWaypoint = savedWaypoint
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
        
        -- Arrow pointing to button - uses a wrapper frame so shared helper works
        local bcArrowFrame = CreateFrame("Frame", nil, hl)
        bcArrowFrame:SetSize(ns.BREADCRUMB_SIZE, ns.BREADCRUMB_SIZE)
        bcArrowFrame:SetPoint("BOTTOM", hl, "TOP", 0, 8)
        ns.CreateArrowTextures(bcArrowFrame, ns.BREADCRUMB_SIZE, 0)
        hl.arrowFrame = bcArrowFrame
        -- Keep .arrow reference for compat
        hl.arrow = bcArrowFrame.arrow
        
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
        globalSearchFrame:Show()
    end)
    
    WorldMapFrame:HookScript("OnHide", function()
        searchFrame:Hide()
        globalSearchFrame:Hide()
        self:HideResults()
        self:ClearHighlight()
        self:ClearZoneHighlight()
    end)
    
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        local newMapID = WorldMapFrame:GetMapID()
        local newMapInfo = newMapID and C_Map.GetMapInfo(newMapID)
        DebugPrint("[EasyFind] OnMapChanged - new map:", newMapInfo and newMapInfo.name or "nil", "ID:", newMapID)
        DebugPrint("[EasyFind] OnMapChanged - pendingZoneHighlight:", self.pendingZoneHighlight)
        
        -- Snapshot pending values BEFORE clearing anything.
        -- SetText("") below fires OnTextChanged → OnSearchTextChanged("") → ClearZoneHighlight(),
        -- which would wipe these if we didn't save them first.
        local savedPendingZone = self.pendingZoneHighlight
        local savedPendingWaypoint = self.pendingWaypoint
        
        self:HideResults()
        self:ClearHighlight()
        
        -- Clear breadcrumb highlight
        if self.breadcrumbHighlight then
            self.breadcrumbHighlight:Hide()
        end
        
        -- Clear both search bars on map change
        searchFrame.editBox:SetText("")
        searchFrame.editBox.placeholder:Show()
        if globalSearchFrame and globalSearchFrame.editBox then
            globalSearchFrame.editBox:SetText("")
            globalSearchFrame.editBox.placeholder:Show()
        end
        
        -- Check if we have a pending zone to highlight (step-by-step navigation)
        if savedPendingZone then
            DebugPrint("[EasyFind] OnMapChanged - continuing navigation to:", savedPendingZone)
            
            -- Restore waypoint so it survives through the rest of the navigation chain
            self.pendingWaypoint = savedPendingWaypoint
            
            -- Continue the step-by-step navigation
            C_Timer.After(0.1, function()
                self:HighlightZoneOnMap(savedPendingZone)
            end)
        elseif savedPendingWaypoint then
            -- We arrived at a zone with a pending waypoint (e.g. dungeon entrance)
            DebugPrint("[EasyFind] OnMapChanged - showing pending waypoint at:", savedPendingWaypoint.x, savedPendingWaypoint.y)
            
            C_Timer.After(0.1, function()
                self:ShowWaypointAt(savedPendingWaypoint.x, savedPendingWaypoint.y, savedPendingWaypoint.icon, savedPendingWaypoint.category)
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

-- Scan dungeon/raid entrances for the given map using the Encounter Journal API
-- Returns POI-style entries with name, position, category (dungeon/raid), and the zone mapID
function MapSearch:ScanDungeonEntrances(mapID)
    mapID = mapID or WorldMapFrame:GetMapID()
    if not mapID then return {} end
    if not C_EncounterJournal or not C_EncounterJournal.GetDungeonEntrancesForMap then return {} end
    
    local results = {}
    local entrances = C_EncounterJournal.GetDungeonEntrancesForMap(mapID)
    if not entrances then return results end
    
    for _, entrance in ipairs(entrances) do
        if entrance.name and entrance.position then
            -- Determine dungeon vs raid
            local cat = "dungeon"
            if entrance.journalInstanceID and EJ_GetInstanceInfo then
                local _, _, _, _, _, _, _, _, _, _, entIsRaid = EJ_GetInstanceInfo(entrance.journalInstanceID)
                if entIsRaid then
                    cat = "raid"
                end
            end
            
            -- Build a parent zone label from the map this entrance is on
            local mapInfo = C_Map.GetMapInfo(mapID)
            local parentLabel = mapInfo and mapInfo.name or ""
            
            tinsert(results, {
                name = entrance.name,
                category = cat,
                icon = nil,  -- use category icon
                isStatic = true,
                isDungeonEntrance = true,
                entranceMapID = mapID,
                x = entrance.position.x,
                y = entrance.position.y,
                pathPrefix = parentLabel,
                keywords = {cat, "instance", "entrance", "portal"},
            })
        end
    end
    
    return results
end

-- Scan dungeon entrances across ALL zone-type maps for global search
-- This collects every dungeon/raid portal location in the game
-- Results are cached since instance discovery doesn't change mid-session
local cachedAllDungeonEntrances = nil

function MapSearch:ScanAllDungeonEntrances()
    if cachedAllDungeonEntrances then return cachedAllDungeonEntrances end
    if not C_EncounterJournal or not C_EncounterJournal.GetDungeonEntrancesForMap then return {} end
    
    local allEntrances = {}
    local seen = {}  -- Deduplicate by instance name + map
    
    -- Walk the full world tree collecting zone-type maps
    local function collectZoneMaps(parentMapID, depth)
        if depth > 6 then return end
        local children = C_Map.GetMapChildrenInfo(parentMapID, nil, false)
        if not children then return end
        
        for _, child in ipairs(children) do
            if child.name then
                local mt = child.mapType
                -- Only scan Zone and Continent maps for dungeon entrances
                if mt == Enum.UIMapType.Zone or mt == Enum.UIMapType.Continent then
                    local entrances = self:ScanDungeonEntrances(child.mapID)
                    for _, e in ipairs(entrances) do
                        local key = e.name .. "|" .. child.mapID
                        if not seen[key] then
                            seen[key] = true
                            tinsert(allEntrances, e)
                        end
                    end
                end
                -- Recurse into children (skip Dungeon/Micro/Orphan)
                if mt ~= Enum.UIMapType.Dungeon and mt ~= Enum.UIMapType.Micro and mt ~= Enum.UIMapType.Orphan then
                    collectZoneMaps(child.mapID, depth + 1)
                end
            end
        end
    end
    
    -- Start from Cosmic → all worlds
    local cosmicChildren = C_Map.GetMapChildrenInfo(946, nil, false)
    if cosmicChildren then
        for _, child in ipairs(cosmicChildren) do
            collectZoneMaps(child.mapID, 0)
        end
    end
    
    cachedAllDungeonEntrances = allEntrances
    return allEntrances
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
    
    -- Clear any previous zone highlights and POI highlights
    self:ClearZoneHighlight()
    self:ClearHighlight()
    
    -- Search for zones (works for both local and global mode)
    local zoneMatches = {}
    if self:IsOnContinentMap() or isGlobalSearch then
        zoneMatches = self:SearchZones(text)
        -- Don't auto-highlight - only highlight when user clicks a result
    end
    
    -- Get both dynamic pins and static locations for current map
    local dynamicPOIs = self:ScanMapPOIs()
    local staticLocations = self:GetStaticLocations()
    
    -- Get dungeon/raid entrance locations
    local dungeonEntrances = {}
    if isGlobalSearch then
        dungeonEntrances = self:ScanAllDungeonEntrances()
    else
        dungeonEntrances = self:ScanDungeonEntrances()
    end
    
    -- Combine them
    local allPOIs = {}
    
    -- Group zone matches by parent for clean display
    local groupedZones = self:GroupZonesByParent(zoneMatches)
    
    -- Add zone results - simple flat list with full path
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
            })
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
    
    -- Add dungeon/raid entrance locations (skip if already found by pin scanning)
    local existingNames = {}
    for _, poi in ipairs(allPOIs) do
        existingNames[slower(poi.name)] = true
    end
    for _, entrance in ipairs(dungeonEntrances) do
        if not existingNames[slower(entrance.name)] then
            tinsert(allPOIs, entrance)
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
        
        -- Zone results already scored by SearchZones — pass through directly
        local score
        if poi.isZone and poi.score then
            score = poi.score
        else
            score = ns.Database:ScoreName(nameLower, query, #query)
            
            -- Also check custom keywords for static locations
            if poi.keywords then
                -- Build lowered keywords list for shared scorer
                local kwLower = {}
                for _, kw in ipairs(poi.keywords) do
                    kwLower[#kwLower + 1] = slower(kw)
                end
                score = score + ns.Database:ScoreKeywords(kwLower, query, #query)
            end
        end
        
        if score >= 50 then
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
    
    -- Sort results by score
    tsort(results, function(a, b)
        -- Zone results come before POI results at equal scores
        if a.score == b.score then
            if a.isZone and not b.isZone then return true end
            if b.isZone and not a.isZone then return false end
            return (a.name or "") < (b.name or "")
        end
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
    local yOffset = -10  -- running vertical offset
    
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
            if btn.indentLine then btn.indentLine:Hide() end
            
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
                    -- Show vertical indent line
                    if btn.indentLine then btn.indentLine:Show() end
                    
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
                local displayText = data.name
                -- For dungeon entrances from global search, show zone location
                if data.isDungeonEntrance and data.pathPrefix and data.pathPrefix ~= "" then
                    displayText = data.name .. " |cff666666(" .. data.pathPrefix .. ")|r"
                end
                btn.text:SetText(displayText)
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
            
            -- Measure actual text height and size button to fit
            local textHeight = btn.text:GetStringHeight() or 14
            local rowHeight = mmax(24, textHeight + 8)  -- minimum 24, pad 8
            btn:SetHeight(rowHeight)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 10, yOffset)
            yOffset = yOffset - rowHeight - 2
        else
            btn:Hide()
        end
    end
    
    resultsFrame:SetHeight(-yOffset + 10)
    
    -- Anchor results dropdown to whichever search bar is active
    resultsFrame:ClearAllPoints()
    local anchor = activeSearchFrame or searchFrame
    if isGlobalSearch and globalSearchFrame then
        anchor = globalSearchFrame
    end
    resultsFrame:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    
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
        
        -- Dungeon/raid entrance from global search: navigate to zone, then show waypoint
        if data.isDungeonEntrance and data.entranceMapID then
            local currentMapID = WorldMapFrame:GetMapID()
            if currentMapID == data.entranceMapID then
                -- Already on the right map, just show the waypoint
                self:ShowWaypointAt(data.x, data.y, data.icon, data.category)
            else
                -- Store waypoint to show after we arrive at the zone
                self.pendingWaypoint = {x = data.x, y = data.y, icon = data.icon, category = data.category}
                if EasyFind.db.navigateToZonesDirectly then
                    self:ClearZoneHighlight()
                    WorldMapFrame:SetMapID(data.entranceMapID)
                else
                    self:HighlightZoneOnMap(data.entranceMapID, data.name)
                end
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
    local userScale = EasyFind.db.iconScale or 1.0
    local ms = ns.MULTI_SCALE  -- slightly smaller for clusters
    
    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE      * ms) * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE * ms) * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE * ms) * userScale
    local arrowSize     = ns.UIToCanvas(ns.ICON_SIZE     * ms) * userScale
    local arrowGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE* ms) * userScale
    
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
                    glow:SetVertexColor(1, 1, 0, 0.8)  -- Pin glow always yellow
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
                    ns.CreateArrowTextures(extraArrow)
                    
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
    
    -- Convert UI-unit sizes to canvas units so they appear the same screen size
    local userScale = EasyFind.db.iconScale or 1.0
    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE)       * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE)  * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE)  * userScale
    local arrowSize     = ns.UIToCanvas(ns.ICON_SIZE)       * userScale
    local arrowGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE)  * userScale
    
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
    
    -- Convert UI-unit sizes to canvas units
    local userScale = EasyFind.db.iconScale or 1.0
    
    local width, height = pin:GetSize()
    local minPinSize = ns.UIToCanvas(36) * userScale
    width = mmax(width or 24, minPinSize)
    height = mmax(height or 24, minPinSize)
    
    local arrowSize     = ns.UIToCanvas(ns.ICON_SIZE)      * userScale
    local arrowGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE) * userScale
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
    if globalSearchFrame then
        local scale = EasyFind.db.mapSearchScale or 1.0
        globalSearchFrame:SetScale(scale)
    end
end

function MapSearch:UpdateOpacity()
    if searchFrame then
        local alpha = EasyFind.db.searchBarOpacity or 1.0
        searchFrame:SetAlpha(alpha)
    end
    if globalSearchFrame then
        local alpha = EasyFind.db.searchBarOpacity or 1.0
        globalSearchFrame:SetAlpha(alpha)
    end
end

function MapSearch:UpdateSearchBarTheme()
    local isRetail = (EasyFind.db.resultsTheme or "Retail") == "Retail"
    local frames = {searchFrame, globalSearchFrame}
    for _, frame in ipairs(frames) do
        if frame then
            if isRetail then
                frame:SetBackdrop({
                    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 32, edgeSize = 16,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 }
                })
                frame:SetBackdropColor(0.45, 0.45, 0.45, 0.95)
                frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            else
                frame:SetBackdrop({
                    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                    tile = true, tileSize = 32, edgeSize = 16,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 }
                })
                frame:SetBackdropColor(1, 1, 1, 1)
                frame:SetBackdropBorderColor(1, 1, 1, 1)
            end
        end
    end
end

function MapSearch:ResetPosition()
    if searchFrame then
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "BOTTOMLEFT", 0, 0)
        EasyFind.db.mapSearchPosition = nil
    end
    if globalSearchFrame then
        globalSearchFrame:ClearAllPoints()
        globalSearchFrame:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", 0, 0)
        EasyFind.db.globalSearchPosition = nil
    end
end

function MapSearch:UpdateIconScales()
    -- This function is called when the user changes the icon scale setting
    -- Update all visible pins, highlights, and arrows in real-time
    
    local canvas = WorldMapFrame.ScrollContainer.Child
    if not canvas then return end
    
    local userScale = EasyFind.db.iconScale or 1.0
    
    local iconSize      = ns.UIToCanvas(ns.PIN_SIZE)       * userScale
    local glowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE)  * userScale
    local highlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE)  * userScale
    local arrowSize     = ns.UIToCanvas(ns.ICON_SIZE)       * userScale
    local arrowGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE)  * userScale
    
    -- Helper: resize an arrow frame + its textures
    local function resizeArrow(frame, aSize, gSize)
        if not frame then return end
        frame:SetSize(aSize, aSize)
        if frame.arrow then frame.arrow:SetSize(aSize, aSize) end
        if frame.glow then frame.glow:SetSize(gSize, gSize) end
    end
    
    -- Update main waypoint pin
    if waypointPin then
        waypointPin:SetSize(iconSize, iconSize)
        if waypointPin.glow then
            waypointPin.glow:SetSize(glowSize, glowSize)
        end
    end
    
    -- Update main highlight frame
    if highlightFrame and highlightFrame:IsShown() then
        highlightFrame:SetSize(highlightSize, highlightSize)
    end
    
    -- Update main arrow
    resizeArrow(arrowFrame, arrowSize, arrowGlowSize)
    
    -- Update zone arrow
    local zoneArrowSize     = ns.UIToCanvas(ns.ZONE_ICON_SIZE)      * userScale
    local zoneArrowGlowSize = ns.UIToCanvas(ns.ZONE_ICON_GLOW_SIZE) * userScale
    if zoneHighlightFrame and zoneHighlightFrame.arrow then
        resizeArrow(zoneHighlightFrame.arrow, zoneArrowSize, zoneArrowGlowSize)
    end
    
    -- Update extra pins for duplicates
    local ms = ns.MULTI_SCALE
    local multiIconSize      = ns.UIToCanvas(ns.PIN_SIZE      * ms) * userScale
    local multiGlowSize      = ns.UIToCanvas(ns.PIN_GLOW_SIZE * ms) * userScale
    local multiHighlightSize = ns.UIToCanvas(ns.HIGHLIGHT_SIZE * ms) * userScale
    local multiArrowSize     = ns.UIToCanvas(ns.ICON_SIZE     * ms) * userScale
    local multiArrowGlowSize = ns.UIToCanvas(ns.ICON_GLOW_SIZE* ms) * userScale
    
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
            resizeArrow(arr, multiArrowSize, multiArrowGlowSize)
        end
    end
end

-- Refresh all arrow textures when style/color changes.
-- Uses ns.UpdateArrow so every arrow looks identical.
-- Highlight boxes, zone overlays, and pin glows are ALWAYS yellow and never change.
function MapSearch:RefreshArrows()
    -- Update main location arrow
    ns.UpdateArrow(_G["EasyFindMapArrow"])
    
    -- Update zone arrow
    ns.UpdateArrow(_G["EasyFindZoneArrow"])
    
    -- Update breadcrumb arrow (uses a wrapper frame now)
    if self.breadcrumbHighlight and self.breadcrumbHighlight.arrowFrame then
        ns.UpdateArrow(self.breadcrumbHighlight.arrowFrame)
    end
    
    -- Update extra arrows
    if self.extraArrows then
        for _, arr in ipairs(self.extraArrows) do
            ns.UpdateArrow(arr)
        end
    end
    
    -- Update UI highlight arrow (Highlight.lua)
    ns.UpdateArrow(_G["EasyFindArrowFrame"])
end
