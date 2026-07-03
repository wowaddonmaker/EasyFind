local _, ns = ...

local Filters = ns.Filters
local Utils = ns.Utils
local L = ns.L

local ipairs = Utils.ipairs
local SetFlyoutRowEnabled = Utils.SetFlyoutRowEnabled
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent

function Filters:AttachGearOptionsFlyout(row, dropdown, ctx)
    local ROW_HEIGHT = ctx.rowHeight
    local CHECK_SIZE = ctx.checkSize
    local StylePopup = ctx.StylePopup
    local CreateRadioTexture = ctx.CreateRadioTexture
    local AddPopupKeyboardNav = ctx.AddPopupKeyboardNav
    local SetActiveFlyout = ctx.SetActiveFlyout
    local ClearActiveFlyout = ctx.ClearActiveFlyout
    local dropdownGuardFrames = ctx.dropdownGuardFrames
    local GEAR_POPUP_WIDTH = 184
    local GEAR_POPUP_PAD = 8

    local function InstallMenuRowHighlight(target)
        Utils.InstallMenuRowHighlight(target)
    end

    local gearOptionsPopup = CreateFrame("Frame", "EasyFindGearOptionsPopup", UIParent, "BackdropTemplate")
    gearOptionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(gearOptionsPopup)
    gearOptionsPopup:EnableMouse(true)
    gearOptionsPopup:Hide()
    row.gearOptionsPopup = gearOptionsPopup
    dropdownGuardFrames[#dropdownGuardFrames + 1] = gearOptionsPopup

    local lootSubDefs = {
        { dbKey = "lootUpgradesOnly", label = L["FILTER_ILVL_UPGRADES_ONLY"] },
        { dbKey = "hideTooltips.loot", label = L["FILTER_HIDE_TOOLTIPS"] },
    }
    local lootSubRows = {}
    for si, sub in ipairs(lootSubDefs) do
        local subRow = CreateFrame("CheckButton", nil, gearOptionsPopup)
        subRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, ROW_HEIGHT)
        subRow:SetHitRectInsets(0, 0, 0, 0)

        Utils.SetCheckboxTextures(subRow, CHECK_SIZE)

        local subLabel = subRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        subLabel:SetPoint("LEFT", subRow:GetNormalTexture(), "RIGHT", 4, 0)
        subLabel:SetText(sub.label)
        subRow._label = subLabel

        InstallMenuRowHighlight(subRow)

        subRow.dbKey = sub.dbKey
        lootSubRows[si] = subRow

        local function resolveDbPath()
            return ns.ResolveDbKey(sub.dbKey)
        end

        subRow:SetScript("OnClick", function(self)
            local tbl, leaf = resolveDbPath()
            tbl[leaf] = self:GetChecked() and true or false
            Filters:RerunActiveSearch()
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
        { key = "lfr",    label = _G["RAID_FINDER"] or "Raid Finder" },
        { key = "normal", label = _G["PLAYER_DIFFICULTY1"] or "Normal" },
        { key = "heroic", label = _G["PLAYER_DIFFICULTY2"] or "Heroic" },
        { key = "mythic", label = _G["PLAYER_DIFFICULTY6"] or "Mythic" },
    }
    local DIFF_LABELS = {
        lfr = _G["RAID_FINDER"] or "Raid Finder",
        normal = _G["PLAYER_DIFFICULTY1"] or "Normal",
        heroic = _G["PLAYER_DIFFICULTY2"] or "Heroic",
        mythic = _G["PLAYER_DIFFICULTY6"] or "Mythic",
    }

    local diffBtn = CreateFrame("Button", nil, gearOptionsPopup)
    diffBtn:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
    local diffBg = diffBtn:CreateTexture(nil, "BACKGROUND")
    ns.Utils.StyleDropdownBg(diffBg)
    local diffArrow = diffBtn:CreateTexture(nil, "OVERLAY")
    diffArrow:SetAtlas("common-dropdown-a-button-hover")
    diffArrow:SetSize(22, 22)
    diffArrow:SetPoint("RIGHT", -10, -1)
    diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    local diffText = diffBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    diffText:SetPoint("LEFT", 14, 0)
    diffText:SetPoint("RIGHT", diffArrow, "LEFT", -2, 0)
    diffText:SetJustifyH("LEFT")
    diffText:SetWordWrap(false)
    diffBtn:SetScript("OnEnter", function()
        diffArrow:SetVertexColor(1, 1, 1)
    end)
    diffBtn:SetScript("OnLeave", function()
        diffArrow:SetVertexColor(0.7, 0.7, 0.7)
    end)
    diffBtn._label = diffText
    diffBtn._chev = diffArrow

    local function UpdateDiffLabel()
        local key = EasyFind.db.lootDifficulty or "normal"
        diffText:SetText(DIFF_LABELS[key] or _G["PLAYER_DIFFICULTY1"] or "Normal")
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
        InstallMenuRowHighlight(dRow)
        dRow._diffKey = def.key
        dRow._setRadioChecked = setRadioChecked
        dRow:SetScript("OnClick", function()
            EasyFind.db.lootDifficulty = def.key
            UpdateDiffLabel()
            diffPopup:Hide()
            Filters:ApplyFilterSelection("loot")
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
            Utils.OpenDropdownBelow(diffPopup, diffBtn, 2)
            diffPopup:Show()
        end
    end)
    Filters.AttachOutsideClickClose(diffPopup)

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

    -- Not Filters:ApplyFilterSelection("loot"): SyncEJLootFilter must run
    -- between the category refresh and the re-search.
    local function ApplyFilterSelection()
        if ns.Database then
            if ns.Database.RefreshDynamicCategory then
                ns.Database:RefreshDynamicCategory("loot")
            end
            ns.Database:SyncEJLootFilter()
        end
        Filters:RerunActiveSearch()
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
                lbl:SetText(colorStr .. (className or L["FILTER_CURRENT_SPEC"]) .. "|r")
            end
        elseif lf == "all" then
            lbl:SetText(_G["ALL_CLASSES"] or "All Classes")
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
        InstallMenuRowHighlight(btn)
        btn._setRadioChecked = setChecked
        btn._filterVal = filterVal
        return btn
    end

    local classFlyoutRows = {}
    local allClassRow = CreateRadioRow(classFlyout, _G["ALL_CLASSES"] or "All Classes", "all", CLASSFLYOUT_WIDTH)
    allClassRow:SetScript("OnClick", function()
        EasyFind.db.lootFilter = "all"
        UpdateSpecLabel()
        classFlyout:Hide()
        specPopup:Hide()
        ApplyFilterSelection()
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
            -- Mouse: keep the spec list open and re-layout for the new class.
            -- Keyboard: close it so focus cleanly returns to the dropdown.
            local viaKeyboard = classFlyout:IsKeyboardEnabled()
            classFlyout:Hide()
            if viaKeyboard then specPopup:Hide() end
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
        Utils.RefreshMenuRowHighlights(classFlyout, classFlyoutRows)
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
    csLabel:SetText(_G["CLASS"] or "Class")
    local csArrow = classSelectBtn:CreateTexture(nil, "ARTWORK")
    csArrow:SetSize(16, 16)
    csArrow:SetPoint("RIGHT", -4, 0)
    csArrow:SetTexture(ns.FLYOUT_ARROW_TEX)
    InstallMenuRowHighlight(classSelectBtn)
    local function OpenClassFlyout()
        LayoutClassFlyout()
        classFlyout:SetScale(EasyFind.db.uiSearchScale or 1.0)
        Utils.OpenFlyoutBeside(classFlyout, classSelectBtn, 2)
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
                                child:SetText(_G["ALL_SPECS"] or "All Specializations")
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
        Utils.RefreshMenuRowHighlights(specPopup)
    end

    local specSelectRow = CreateFrame("Button", nil, gearOptionsPopup)
    specSelectRow:SetSize(GEAR_POPUP_WIDTH - GEAR_POPUP_PAD * 2, 27)
    local specBg = specSelectRow:CreateTexture(nil, "BACKGROUND")
    ns.Utils.StyleDropdownBg(specBg)
    local specSelectArrow = specSelectRow:CreateTexture(nil, "OVERLAY")
    specSelectArrow:SetAtlas("common-dropdown-a-button-hover")
    specSelectArrow:SetSize(22, 22)
    specSelectArrow:SetPoint("RIGHT", -10, -1)
    specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
    local specSelectLabel = specSelectRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    specSelectLabel:SetPoint("LEFT", 14, 0)
    specSelectLabel:SetPoint("RIGHT", specSelectArrow, "LEFT", -2, 0)
    specSelectLabel:SetJustifyH("LEFT")
    specSelectLabel:SetWordWrap(false)

    specSelectRow:SetScript("OnEnter", function()
        specSelectArrow:SetVertexColor(1, 1, 1)
    end)
    specSelectRow:SetScript("OnLeave", function()
        specSelectArrow:SetVertexColor(0.7, 0.7, 0.7)
    end)
    specSelectRow._label = specSelectLabel
    specSelectRow._chev = specSelectArrow
    specSelectRow:SetScript("OnClick", function()
        if specPopup:IsShown() then
            specPopup:Hide()
        else
            LayoutSpecPopup()
            specPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenDropdownBelow(specPopup, specSelectRow, 2)
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

    Filters.AttachOutsideClickClose(specPopup, {
        onHide = function() classFlyout:Hide() end,
    })

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
            Utils.OpenFlyoutBeside(gearOptionsPopup, row, 4)
            gearOptionsPopup:Show()
        end,
    })
    row.ShowGearOptionsPopup = gearHover.Show
    -- Outside-click: nested diff/spec/class popups act as guards
    -- so clicks inside them don't dismiss the gear options.
    Filters.AttachOutsideClickClose(gearOptionsPopup, {
        onHide = function(self)
            if row.diffPopup then row.diffPopup:Hide() end
            local sp = _G["EasyFindSpecPopup"]
            if sp then sp:Hide() end
            classFlyout:Hide()
            ClearActiveFlyout(self)
        end,
    })
    dropdown:HookScript("OnHide", function() gearOptionsPopup:Hide() end)

    row.updateLootToggle = function()
        local chainEnabled = EasyFind.db.uiSearchFilters.loot ~= false
        for _, sr in ipairs(lootSubRows) do
            if sr.SetChecked and sr.resolveDbPath then
                local tbl, leaf = sr.resolveDbPath()
                sr:SetChecked(tbl[leaf] == true)
            end
            SetFlyoutRowEnabled(sr, chainEnabled)
        end
        SetFlyoutRowEnabled(diffBtn, chainEnabled)
        SetFlyoutRowEnabled(specSelectRow, chainEnabled)
        UpdateSpecLabel()
        if row.UpdateDiffButtons then row.UpdateDiffButtons() end
    end
    gearOptionsPopup._efSync = row.updateLootToggle
end
