local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils

local ipairs = Utils.ipairs
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent

function Filters:AttachGearOptionsFlyout(row, dropdown, ctx)
    local ROW_HEIGHT = ctx.rowHeight
    local CHECK_SIZE = ctx.checkSize
    local ROW_HIGHLIGHT_COLOR = ctx.rowHighlightColor
    local StylePopup = ctx.StylePopup
    local CreateRadioTexture = ctx.CreateRadioTexture
    local AddPopupKeyboardNav = ctx.AddPopupKeyboardNav
    local SetActiveFlyout = ctx.SetActiveFlyout
    local ClearActiveFlyout = ctx.ClearActiveFlyout
    local dropdownGuardFrames = ctx.dropdownGuardFrames
    local searchEditBox = ctx.searchEditBox
    local GEAR_POPUP_WIDTH = 200
    local GEAR_POPUP_PAD = 8

    local gearOptionsPopup = CreateFrame("Frame", "EasyFindGearOptionsPopup", UIParent, "BackdropTemplate")
    gearOptionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(gearOptionsPopup)
    gearOptionsPopup:EnableMouse(true)
    gearOptionsPopup:Hide()
    row.gearOptionsPopup = gearOptionsPopup
    dropdownGuardFrames[#dropdownGuardFrames + 1] = gearOptionsPopup

    local lootSubDefs = {
        { dbKey = "lootUpgradesOnly", label = "iLvl Upgrades Only" },
        { dbKey = "hideTooltips.loot", label = "Hide tooltips" },
    }
    local lootSubRows = {}
    for si, sub in ipairs(lootSubDefs) do
        local subRow = CreateFrame("CheckButton", nil, gearOptionsPopup)
        subRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, ROW_HEIGHT)
        subRow:SetHitRectInsets(0, 0, 0, 0)

        subRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        subRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        subRow:GetNormalTexture():ClearAllPoints()
        subRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

        subRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        subRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        subRow:GetCheckedTexture():ClearAllPoints()
        subRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
        subLabel:SetText(sub.label)

        local subHL = subRow:CreateTexture(nil, "HIGHLIGHT")
        subHL:SetAllPoints()
        subHL:SetColorTexture(1, 1, 1, 0.1)

        subRow.dbKey = sub.dbKey
        lootSubRows[si] = subRow

        -- Resolve "a.b" dotted keys into a getter/setter so the
        -- nested hideTooltips.loot toggle lives alongside the
        -- flat lootUpgradesOnly checkbox without duplicating
        -- this whole subRow setup.
        local function resolveDbPath()
            local parent, leaf = sub.dbKey:match("^(.-)%.([^%.]+)$")
            if parent then
                EasyFind.db[parent] = EasyFind.db[parent] or {}
                return EasyFind.db[parent], leaf
            end
            return EasyFind.db, sub.dbKey
        end

        subRow:SetScript("OnClick", function(self)
            local tbl, leaf = resolveDbPath()
            tbl[leaf] = self:GetChecked() and true or false
            if searchEditBox:GetText() ~= "" then
                Search:OnSearchTextChanged(searchEditBox:GetText())
            end
        end)
        subRow.resolveDbPath = resolveDbPath
    end

    -- Separator line between iLvl Upgrades checkbox and the
    -- difficulty/spec selectors.
    local lootSep = gearOptionsPopup:CreateTexture(nil, "ARTWORK")
    lootSep:SetHeight(1)
    lootSep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
    row.lootSep = lootSep

    -- Difficulty dropdown (single-select, matches EJ style)
    local DIFF_OPTIONS = {
        { key = "lfr",    label = "Raid Finder" },
        { key = "normal", label = "Normal" },
        { key = "heroic", label = "Heroic" },
        { key = "mythic", label = "Mythic" },
    }
    local DIFF_LABELS = { lfr = "Raid Finder", normal = "Normal", heroic = "Heroic", mythic = "Mythic" }

    local diffBtn = CreateFrame("Button", nil, gearOptionsPopup)
    diffBtn:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
    local diffBg = diffBtn:CreateTexture(nil, "BACKGROUND")
    diffBg:SetAtlas("common-dropdown-textholder")
    diffBg:SetAllPoints()
    local diffArrow = diffBtn:CreateTexture(nil, "OVERLAY")
    diffArrow:SetAtlas("common-dropdown-a-button-hover")
    diffArrow:SetSize(20, 20)
    diffArrow:SetPoint("RIGHT", -2, -1)
    diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    local diffText = diffBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    diffText:SetPoint("LEFT", 8, 0)
    diffText:SetPoint("RIGHT", diffArrow, "LEFT", -2, 0)
    diffText:SetJustifyH("LEFT")
    diffText:SetWordWrap(false)
    diffBtn:SetScript("OnEnter", function()
        diffArrow:SetVertexColor(1, 1, 1)
    end)
    diffBtn:SetScript("OnLeave", function()
        diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    end)

    local function UpdateDiffLabel()
        local key = EasyFind.db.lootDifficulty or "normal"
        diffText:SetText(DIFF_LABELS[key] or "Normal")
    end

    -- Difficulty popup menu
    local diffPopup = CreateFrame("Frame", "EasyFindDiffPopup", UIParent, "BackdropTemplate")
    diffPopup:SetFrameStrata("TOOLTIP")
    diffPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
    StylePopup(diffPopup)
    diffPopup:EnableMouse(true)
    diffPopup:Hide()

    local diffPopupRows = {}
    local py = -6
    for _, def in ipairs(DIFF_OPTIONS) do
        local dRow = CreateFrame("Button", nil, diffPopup)
        dRow:SetSize(130, 20)
        dRow:SetPoint("TOPLEFT", 8, py)
        local radio, setRadioChecked = CreateRadioTexture(dRow)
        radio:SetPoint("LEFT", 0, 0)
        local dLabel = dRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        dLabel:SetPoint("LEFT", radio, "RIGHT", 4, 0)
        dLabel:SetText(def.label)
        local dHL = dRow:CreateTexture(nil, "HIGHLIGHT")
        dHL:SetAllPoints()
        dHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        dRow._diffKey = def.key
        dRow._setRadioChecked = setRadioChecked
        dRow:SetScript("OnClick", function()
            EasyFind.db.lootDifficulty = def.key
            UpdateDiffLabel()
            diffPopup:Hide()
            if ns.Database and ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("loot")
            end
            if searchEditBox:GetText() ~= "" then
                Search:OnSearchTextChanged(searchEditBox:GetText())
            end
        end)
        diffPopupRows[#diffPopupRows + 1] = dRow
        py = py - 20
    end
    diffPopup:SetSize(146, -py + 6)

    local function SyncDiffRadios()
        local key = EasyFind.db.lootDifficulty or "normal"
        for _, dr in ipairs(diffPopupRows) do
            dr._setRadioChecked(dr._diffKey == key)
        end
    end

    diffBtn:SetScript("OnClick", function()
        if diffPopup:IsShown() then
            diffPopup:Hide()
        else
            SyncDiffRadios()
            diffPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            diffPopup:ClearAllPoints()
            diffPopup:SetPoint("TOPLEFT", diffBtn, "BOTTOMLEFT", 0, 2)
            diffPopup:Show()
        end
    end)
    diffPopup:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    diffPopup:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    diffPopup:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() and not diffBtn:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    AddPopupKeyboardNav(diffPopup, function() return diffPopupRows end)
    dropdownGuardFrames[#dropdownGuardFrames + 1] = diffPopup

    row.diffBtn = diffBtn
    row.diffPopup = diffPopup
    row.UpdateDiffButtons = function()
        UpdateDiffLabel()
    end


    local CLASS_COLORS = RAID_CLASS_COLORS
    local allClassSpecs = {}
    for classIdx = 1, GetNumClasses() do
        local className, classFile, classID = GetClassInfo(classIdx)
        if className then
            local specs = {}
            for specIdx = 1, GetNumSpecializationsForClassID(classID) do
                local sid, sname, _, sicon = GetSpecializationInfoForClassID(classID, specIdx)
                if sid then
                    specs[#specs + 1] = { specID = sid, specName = sname, specIcon = sicon }
                end
            end
            if #specs > 0 then
                allClassSpecs[#allClassSpecs + 1] = {
                    classID = classID, className = className,
                    classFile = classFile, specs = specs,
                }
            end
        end
    end


    local FLYOUT_ROW_H = 20
    local POPUP_WIDTH = 180
    local CLASSFLYOUT_WIDTH = 160
    -- Determine which class to display in the spec popup.
    -- Always returns a class (falls back to player's class for "all" or nil).
    local function GetSelectedClass()
        local lf = EasyFind.db.lootFilter
        if type(lf) == "table" and lf.classID then
            for _, cls in ipairs(allClassSpecs) do
                if cls.classID == lf.classID then return cls end
            end
        end
        -- Default: player's class
        local _, _, playerClassID = UnitClass("player")
        for _, cls in ipairs(allClassSpecs) do
            if cls.classID == playerClassID then return cls end
        end
        return allClassSpecs[1]
    end

    local function ApplyFilterSelection()
        if ns.Database then
            if ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("loot")
            end
            ns.Database:SyncEJLootFilter()
        end
        if searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    -- Update the spec selector label from lootFilter
    local function UpdateSpecLabel()
        local lbl = row.specSelectLabel
        if not lbl then return end
        local lf = EasyFind.db.lootFilter
        if not lf then
            -- Default: player's class + current spec, matching EJ format
            local si = GetSpecialization and GetSpecialization()
            local _, sname
            if si then _, sname = GetSpecializationInfo(si) end
            local className, classFile = UnitClass("player")
            local cc = classFile and CLASS_COLORS[classFile]
            local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
            if sname and className then
                lbl:SetText(colorStr .. className .. " (" .. sname .. ")|r")
            else
                lbl:SetText(colorStr .. (className or "Current Spec") .. "|r")
            end
        elseif lf == "all" then
            lbl:SetText("All Classes")
        elseif lf.classID then
            local cls
            for _, c in ipairs(allClassSpecs) do
                if c.classID == lf.classID then cls = c; break end
            end
            if not cls then lbl:SetText("?"); return end
            local cc = CLASS_COLORS[cls.classFile]
            local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
            if lf.specID then
                local sname
                for _, s in ipairs(cls.specs) do
                    if s.specID == lf.specID then sname = s.specName; break end
                end
                lbl:SetText(colorStr .. cls.className .. " (" .. (sname or "?") .. ")|r")
            else
                lbl:SetText(colorStr .. cls.className .. "|r")
            end
        end
    end

    local function IsFilterMatch(filterVal)
        local lf = EasyFind.db.lootFilter
        -- nil lootFilter = current spec; resolve to player class+spec for comparison
        if not lf then
            if filterVal == nil then return true end
            if type(filterVal) == "table" and filterVal.specID then
                local _, _, cid = UnitClass("player")
                local si = GetSpecialization and GetSpecialization()
                local sid = si and GetSpecializationInfo and GetSpecializationInfo(si)
                return filterVal.classID == cid and filterVal.specID == sid
            end
            return false
        end
        if filterVal == "all" and lf == "all" then return true end
        if type(filterVal) == "table" and type(lf) == "table" then
            if filterVal.classID == lf.classID then
                if filterVal.specID == nil and lf.specID == nil then return true end
                if filterVal.specID == lf.specID then return true end
            end
        end
        return false
    end

    -------------------------------------------------------------------
    -- Main spec popup (opens BELOW the bar)
    -- Layout: "Class >" row, then class header, then specs, then "All Specializations"
    -------------------------------------------------------------------
    local specPopup = CreateFrame("Frame", "EasyFindSpecPopup", UIParent, "BackdropTemplate")
    specPopup:SetFrameStrata("TOOLTIP")
    specPopup:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 20)
    StylePopup(specPopup)
    specPopup:EnableMouse(true)
    specPopup:Hide()

    -------------------------------------------------------------------
    -- Class flyout (opens to the RIGHT of the "Class" row)
    -------------------------------------------------------------------
    local classFlyout = CreateFrame("Frame", "EasyFindSpecFlyout", UIParent, "BackdropTemplate")
    classFlyout:SetFrameStrata("TOOLTIP")
    classFlyout:SetFrameLevel(gearOptionsPopup:GetFrameLevel() + 30)
    StylePopup(classFlyout)
    classFlyout:EnableMouse(true)
    classFlyout:Hide()

    local LayoutSpecPopup  -- forward declaration for closures below

    -- Helper: create a radio-style row
    local function CreateRadioRow(parent, label, filterVal, width)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(width - 16, FLYOUT_ROW_H)
        btn:SetFrameLevel(parent:GetFrameLevel() + 10)
        local radio, setChecked = CreateRadioTexture(btn)
        radio:SetPoint("LEFT", 4, 0)
        local lbl = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", radio, "RIGHT", 4, 0)
        lbl:SetText(label)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        btn._setRadioChecked = setChecked
        btn._filterVal = filterVal
        return btn
    end

    local classFlyoutRows = {}
    local allClassRow = CreateRadioRow(classFlyout, "All Classes", "all", CLASSFLYOUT_WIDTH)
    allClassRow:SetScript("OnClick", function()
        EasyFind.db.lootFilter = "all"
        UpdateSpecLabel()
        classFlyout:Hide()
        if not classFlyout._keyboardParent then specPopup:Hide() end
        ApplyFilterSelection()
        if specPopup:IsShown() then LayoutSpecPopup() end
    end)
    classFlyoutRows[#classFlyoutRows + 1] = allClassRow
    for _, cls in ipairs(allClassSpecs) do
        local clsRow = CreateRadioRow(classFlyout, "", { classID = cls.classID }, CLASSFLYOUT_WIDTH)
        -- Override label with class-colored text
        local ccl = CLASS_COLORS[cls.classFile]
        local csStr = ccl and string.format("|cff%02x%02x%02x", ccl.r * 255, ccl.g * 255, ccl.b * 255) or ""
        local clsLabel = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        clsLabel:SetPoint("LEFT", 22, 0)
        clsLabel:SetText(csStr .. cls.className .. "|r")
        clsRow:SetScript("OnClick", function()
            EasyFind.db.lootFilter = { classID = cls.classID }
            UpdateSpecLabel()
            classFlyout:Hide()
            if not classFlyout._keyboardParent then specPopup:Hide() end
            ApplyFilterSelection()
            if specPopup:IsShown() then LayoutSpecPopup() end
        end)
        classFlyoutRows[#classFlyoutRows + 1] = clsRow
    end

    local function LayoutClassFlyout()
        local fy = -6
        local lvl = classFlyout:GetFrameLevel() + 10
        for _, r in ipairs(classFlyoutRows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", classFlyout, "TOPLEFT", 8, fy)
            r:SetFrameLevel(lvl)
            r:Show()
            if r._setRadioChecked then
                local lf = EasyFind.db.lootFilter
                local match = false
                if r._filterVal == "all" and lf == "all" then
                    match = true
                elseif type(r._filterVal) == "table" then
                    if type(lf) == "table" and r._filterVal.classID == lf.classID then
                        match = true
                    elseif not lf then
                        -- nil = current spec; dot the player's class
                        local _, _, cid = UnitClass("player")
                        match = r._filterVal.classID == cid
                    end
                end
                r._setRadioChecked(match)
            end
            fy = fy - FLYOUT_ROW_H
        end
        classFlyout:SetSize(CLASSFLYOUT_WIDTH, -fy + 6)
    end

    -------------------------------------------------------------------
    -- Build spec popup rows (main dropdown below bar)
    -------------------------------------------------------------------
    -- Row 1: "Class" with arrow (opens class flyout to the right)
    local classSelectBtn = CreateFrame("Button", nil, specPopup)
    classSelectBtn:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
    classSelectBtn:SetFrameLevel(specPopup:GetFrameLevel() + 10)
    local csLabel = classSelectBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    csLabel:SetPoint("LEFT", 8, 0)
    csLabel:SetText("Class")
    local csArrow = classSelectBtn:CreateTexture(nil, "ARTWORK")
    csArrow:SetSize(16, 16)
    csArrow:SetPoint("RIGHT", -4, 0)
    csArrow:SetTexture("Interface\\AddOns\\EasyFind\\Search\\Images\\flyout-arrow")
    local csHL = classSelectBtn:CreateTexture(nil, "HIGHLIGHT")
    csHL:SetAllPoints()
    csHL:SetColorTexture(1, 1, 1, 0.1)
    local function OpenClassFlyout()
        LayoutClassFlyout()
        classFlyout:SetScale(EasyFind.db.uiSearchScale or 1.0)
        classFlyout:ClearAllPoints()
        classFlyout:SetPoint("TOPLEFT", classSelectBtn, "TOPRIGHT", 2, 6)
        classFlyout:Show()
    end
    classSelectBtn:SetScript("OnEnter", function() OpenClassFlyout() end)
    classSelectBtn:SetScript("OnClick", function() OpenClassFlyout() end)

    -- Spec rows (rebuilt each time popup opens based on selected class)
    local specRadioRows = {}
    local MAX_SPECS = 5 -- druid has 4 + "All Specializations" = 5
    for si = 1, MAX_SPECS do
        local sRow = CreateRadioRow(specPopup, "", nil, POPUP_WIDTH)
        sRow:Hide()
        specRadioRows[si] = sRow
    end

    -- Class header (non-clickable, shows selected class name)
    local classHeader = CreateFrame("Frame", nil, specPopup)
    classHeader:SetSize(POPUP_WIDTH - 16, FLYOUT_ROW_H)
    classHeader:SetFrameLevel(specPopup:GetFrameLevel() + 10)
    local classHeaderLabel = classHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    classHeaderLabel:SetPoint("LEFT", 8, 0)

    LayoutSpecPopup = function()
        local selCls = GetSelectedClass()
        local py = -6
        local lvl = specPopup:GetFrameLevel() + 10

        -- Row 1: "Class >"
        classSelectBtn:ClearAllPoints()
        classSelectBtn:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
        classSelectBtn:SetFrameLevel(lvl)
        classSelectBtn:Show()
        py = py - FLYOUT_ROW_H

        if selCls then
            local cc = CLASS_COLORS[selCls.classFile]
            local colorStr = cc and string.format("|cff%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255) or ""
            classHeaderLabel:SetText(colorStr .. selCls.className .. "|r")
            classHeader:ClearAllPoints()
            classHeader:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
            classHeader:SetFrameLevel(lvl)
            classHeader:Show()
            py = py - FLYOUT_ROW_H

            local ri = 1
            for _, spec in ipairs(selCls.specs) do
                local sRow = specRadioRows[ri]
                if sRow then
                    local children = { sRow:GetRegions() }
                    for _, child in ipairs(children) do
                        if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                            if child:GetPoint() then
                                local _, rel = child:GetPoint()
                                if rel and rel:GetObjectType() == "Texture" then
                                    child:SetText(spec.specName)
                                end
                            end
                        end
                    end
                    sRow._filterVal = { classID = selCls.classID, specID = spec.specID }
                    sRow._setRadioChecked(IsFilterMatch(sRow._filterVal))
                    sRow:SetScript("OnClick", function()
                        EasyFind.db.lootFilter = { classID = selCls.classID, specID = spec.specID }
                        UpdateSpecLabel()
                        classFlyout:Hide()
                        specPopup:Hide()
                        ApplyFilterSelection()
                    end)
                    sRow:SetScript("OnEnter", function()
                        classFlyout:Hide()
                    end)
                    sRow:ClearAllPoints()
                    sRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                    sRow:SetFrameLevel(lvl)
                    sRow:Show()
                    py = py - FLYOUT_ROW_H
                    ri = ri + 1
                end
            end

            local allRow = specRadioRows[ri]
            if allRow then
                local children = { allRow:GetRegions() }
                for _, child in ipairs(children) do
                    if child:GetObjectType() == "FontString" and child:GetText() ~= "" then
                        if child:GetPoint() then
                            local _, rel = child:GetPoint()
                            if rel and rel:GetObjectType() == "Texture" then
                                child:SetText("All Specializations")
                            end
                        end
                    end
                end
                allRow._filterVal = { classID = selCls.classID }
                allRow._setRadioChecked(IsFilterMatch(allRow._filterVal))
                allRow:SetScript("OnClick", function()
                    EasyFind.db.lootFilter = { classID = selCls.classID }
                    UpdateSpecLabel()
                    classFlyout:Hide()
                    specPopup:Hide()
                    ApplyFilterSelection()
                end)
                allRow:SetScript("OnEnter", function()
                    classFlyout:Hide()
                end)
                allRow:ClearAllPoints()
                allRow:SetPoint("TOPLEFT", specPopup, "TOPLEFT", 8, py)
                allRow:SetFrameLevel(lvl)
                allRow:Show()
                py = py - FLYOUT_ROW_H
                ri = ri + 1
            end

            for hi = ri, MAX_SPECS do
                specRadioRows[hi]:Hide()
            end
        else
            classHeader:Hide()
            for _, sr in ipairs(specRadioRows) do sr:Hide() end
        end

        specPopup:SetSize(POPUP_WIDTH, -py + 6)
    end

    local specSelectRow = CreateFrame("Button", nil, gearOptionsPopup)
    specSelectRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
    local specBg = specSelectRow:CreateTexture(nil, "BACKGROUND")
    specBg:SetAtlas("common-dropdown-textholder")
    specBg:SetAllPoints()
    local specSelectArrow = specSelectRow:CreateTexture(nil, "OVERLAY")
    specSelectArrow:SetAtlas("common-dropdown-a-button-hover")
    specSelectArrow:SetSize(20, 20)
    specSelectArrow:SetPoint("RIGHT", -2, -1)
    specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
    local specSelectLabel = specSelectRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    specSelectLabel:SetPoint("LEFT", 8, 0)
    specSelectLabel:SetPoint("RIGHT", specSelectArrow, "LEFT", -2, 0)
    specSelectLabel:SetJustifyH("LEFT")
    specSelectLabel:SetWordWrap(false)

    specSelectRow:SetScript("OnEnter", function()
        specSelectArrow:SetVertexColor(1, 1, 1)
    end)
    specSelectRow:SetScript("OnLeave", function()
        specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
    end)
    specSelectRow:SetScript("OnClick", function()
        if specPopup:IsShown() then
            specPopup:Hide()
        else
            LayoutSpecPopup()
            specPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            specPopup:ClearAllPoints()
            specPopup:SetPoint("TOPLEFT", specSelectRow, "BOTTOMLEFT", 0, 2)
            specPopup:Show()
        end
    end)

    row.specSelectRow = specSelectRow
    row.specSelectLabel = specSelectLabel

    local function GetSpecPopupNavRows()
        local rows = { classSelectBtn }
        for _, sr in ipairs(specRadioRows) do
            if sr:IsShown() then rows[#rows + 1] = sr end
        end
        return rows
    end

    specPopup:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    specPopup:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        classFlyout:Hide()
    end)
    specPopup:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver()
                and not classFlyout:IsMouseOver()
                and not specSelectRow:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    Utils.SafeOnUpdate(classFlyout, function(self)
        if self:IsKeyboardEnabled() then return end
        if not self:IsMouseOver() and not specPopup:IsMouseOver() then
            if not self._leaveTimer then
                self._leaveTimer = C_Timer.NewTimer(0.2, function()
                    self._leaveTimer = nil
                    if not self:IsMouseOver() and not classSelectBtn:IsMouseOver() then
                        self:Hide()
                    end
                end)
            end
        else
            if self._leaveTimer then
                self._leaveTimer:Cancel()
                self._leaveTimer = nil
            end
        end
    end)

    dropdownGuardFrames[#dropdownGuardFrames + 1] = specPopup
    dropdownGuardFrames[#dropdownGuardFrames + 1] = classFlyout

    dropdown:HookScript("OnHide", function()
        classFlyout:Hide()
        specPopup:Hide()
    end)

    -- Keyboard nav MUST be added AFTER SetScript calls above
    AddPopupKeyboardNav(specPopup, GetSpecPopupNavRows)
    AddPopupKeyboardNav(classFlyout, function() return classFlyoutRows end)

    -- Keep EasyFindSpecFlyout/EasyFindSpecSubFlyout names for dropdown close guard
    local specFlyout = classFlyout
    row.specFlyout = specFlyout
    row.allClassSpecs = allClassSpecs
    row.lootSubRows = lootSubRows

    local gy = -GEAR_POPUP_PAD
    diffBtn:ClearAllPoints()
    diffBtn:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
    gy = gy - 27 - 4
    specSelectRow:ClearAllPoints()
    specSelectRow:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
    gy = gy - 27 - 6
    lootSep:ClearAllPoints()
    lootSep:SetPoint("LEFT", gearOptionsPopup, "LEFT", GEAR_POPUP_PAD, 0)
    lootSep:SetPoint("RIGHT", gearOptionsPopup, "RIGHT", -GEAR_POPUP_PAD, 0)
    lootSep:SetPoint("TOP", 0, gy)
    gy = gy - 6
    for _, sr in ipairs(lootSubRows) do
        sr:ClearAllPoints()
        sr:SetPoint("TOPLEFT", gearOptionsPopup, "TOPLEFT", GEAR_POPUP_PAD, gy)
        gy = gy - ROW_HEIGHT
    end
    gearOptionsPopup:SetSize(GEAR_POPUP_WIDTH, -gy + GEAR_POPUP_PAD)

    -- Hover-to-show wiring on the Gear filter row, mirroring the
    -- Collections sub-flyout pattern (with grace timer).
    local gearHover = Utils.AttachHoverPopup(row, gearOptionsPopup, {
        extraGuards = {
            function() return row.diffPopup end,
            function() return _G["EasyFindSpecPopup"] end,
            classFlyout,
        },
        onShow = function()
            SetActiveFlyout(gearOptionsPopup)
            if row.updateLootToggle then row.updateLootToggle() end
            gearOptionsPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            gearOptionsPopup:ClearAllPoints()
            gearOptionsPopup:SetPoint("TOPLEFT", row, "TOPRIGHT", 4, 0)
            gearOptionsPopup:Show()
        end,
    })
    row.ShowGearOptionsPopup = gearHover.Show
    gearOptionsPopup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    gearOptionsPopup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if row.diffPopup then row.diffPopup:Hide() end
        local sp = _G["EasyFindSpecPopup"]
        if sp then sp:Hide() end
        classFlyout:Hide()
        ClearActiveFlyout(self)
    end)
    -- Outside-click: nested diff/spec/class popups act as guards
    -- so clicks inside them don't dismiss the gear options.
    gearOptionsPopup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() or row:IsMouseOver() then return end
        if Utils.IsFrameVisiblyMouseOver(row.diffPopup) then return end
        if Utils.IsFrameVisiblyMouseOver(_G["EasyFindSpecPopup"]) then return end
        if Utils.IsFrameVisiblyMouseOver(classFlyout) then return end
        self:Hide()
    end)
    dropdown:HookScript("OnHide", function() gearOptionsPopup:Hide() end)

    row.updateLootToggle = function()
        for _, sr in ipairs(lootSubRows) do
            if sr.SetChecked and sr.resolveDbPath then
                local tbl, leaf = sr.resolveDbPath()
                sr:SetChecked(tbl[leaf] == true)
            end
        end
        UpdateSpecLabel()
        if row.UpdateDiffButtons then row.UpdateDiffButtons() end
    end
end
