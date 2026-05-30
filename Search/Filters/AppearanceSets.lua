local _, ns = ...

local Search = ns.Search
local Filters = ns.Filters
local Utils = ns.Utils

local ipairs = Utils.ipairs
local CreateFrame = CreateFrame
local UIParent = UIParent

-- Builds the Appearance Sets options popup: a class selector button +
-- four checkboxes (Collected, Not Collected, PvE, PvP). Returns the
-- popup frame and a sync function that re-reads EasyFind.db state.
-- Caller positions/shows the popup and decides when to call sync.
function Filters:BuildAppearanceSetOptionsPopup(StylePopup, CreateRadioTexture,
        ROW_HIGHLIGHT_COLOR, CHECK_SIZE, searchEditBox)
    local FLYOUT_ROW_H = 20
    local CLASSPOPUP_WIDTH = 160
    local OPTIONS_WIDTH = 160
    local CB_ROW_H = 22
    local CLASS_BTN_H = 27
    local PAD = 6

    local CLASS_COLORS = RAID_CLASS_COLORS
    local classes = {}
    for classIdx = 1, GetNumClasses() do
        local className, classFile, classID = GetClassInfo(classIdx)
        if className and classFile then
            classes[#classes + 1] = {
                classID = classID, className = className, classFile = classFile,
            }
        end
    end

    local function ClassColorString(classFile)
        local c = CLASS_COLORS[classFile]
        return c and string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) or ""
    end

    local function ApplyFilterSelection()
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("transmogSets")
        end
        if searchEditBox and searchEditBox:GetText() ~= "" then
            Search:OnSearchTextChanged(searchEditBox:GetText())
        end
    end

    local optionsPopup = CreateFrame("Frame", "EasyFindAsOptionsPopup", UIParent, "BackdropTemplate")
    optionsPopup:SetFrameStrata("TOOLTIP")
    StylePopup(optionsPopup)
    optionsPopup:EnableMouse(true)
    optionsPopup:Hide()

    local classBtn = CreateFrame("Button", nil, optionsPopup)
    classBtn:SetSize(OPTIONS_WIDTH - PAD * 2, CLASS_BTN_H)
    classBtn:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, -PAD)
    local cbBg = classBtn:CreateTexture(nil, "BACKGROUND")
    cbBg:SetAtlas("common-dropdown-textholder")
    cbBg:SetAllPoints()
    local cbArrow = classBtn:CreateTexture(nil, "OVERLAY")
    cbArrow:SetAtlas("common-dropdown-a-button-hover")
    cbArrow:SetSize(20, 20)
    cbArrow:SetPoint("RIGHT", -2, -1)
    cbArrow:SetVertexColor(0.7, 0.7, 0.7)
    local cbLabel = classBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    cbLabel:SetPoint("LEFT", 8, 0)
    cbLabel:SetPoint("RIGHT", cbArrow, "LEFT", -2, 0)
    cbLabel:SetJustifyH("LEFT")
    cbLabel:SetWordWrap(false)
    classBtn:SetScript("OnEnter", function() cbArrow:SetVertexColor(1, 1, 1) end)
    classBtn:SetScript("OnLeave", function() cbArrow:SetVertexColor(0.7, 0.7, 0.7) end)

    local function UpdateClassLabel()
        local cf = EasyFind.db.appearanceSetClass
        if not cf then
            local _, _, cid = UnitClass("player")
            for _, cls in ipairs(classes) do
                if cls.classID == cid then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        elseif cf == "all" then
            cbLabel:SetText(_G["ALL_CLASSES"] or "All Classes")
            return
        elseif type(cf) == "table" and cf.classID then
            for _, cls in ipairs(classes) do
                if cls.classID == cf.classID then
                    cbLabel:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
                    return
                end
            end
        end
        cbLabel:SetText(_G["ALL_CLASSES"] or "All Classes")
    end
    UpdateClassLabel()

    -- Class popup (opens to the right of the class button)
    local classPopup = CreateFrame("Frame", "EasyFindAsClassPopup", UIParent, "BackdropTemplate")
    classPopup:SetFrameStrata("TOOLTIP")
    classPopup:SetFrameLevel(optionsPopup:GetFrameLevel() + 20)
    StylePopup(classPopup)
    classPopup:EnableMouse(true)
    classPopup:Hide()
    classPopup:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    classPopup:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() and not classBtn:IsMouseOver()
                and not optionsPopup:IsMouseOver() then
                self:Hide()
            end
        end
    end)

    local classRows = {}
    local allRow = CreateFrame("Button", nil, classPopup)
    allRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
    allRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
    local allRadio, allSetRadio = CreateRadioTexture(allRow)
    allRadio:SetPoint("LEFT", 4, 0)
    local allLbl = allRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    allLbl:SetPoint("LEFT", allRadio, "RIGHT", 4, 0)
    allLbl:SetText(_G["ALL_CLASSES"] or "All Classes")
    local allHL = allRow:CreateTexture(nil, "HIGHLIGHT")
    allHL:SetAllPoints()
    allHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
    allRow._setRadioChecked = allSetRadio
    allRow._classID = nil
    allRow:SetScript("OnClick", function()
        EasyFind.db.appearanceSetClass = "all"
        UpdateClassLabel()
        classPopup:Hide()
        ApplyFilterSelection()
    end)
    classRows[#classRows + 1] = allRow

    for _, cls in ipairs(classes) do
        local clsRow = CreateFrame("Button", nil, classPopup)
        clsRow:SetSize(CLASSPOPUP_WIDTH - 16, FLYOUT_ROW_H)
        clsRow:SetFrameLevel(classPopup:GetFrameLevel() + 10)
        local cRadio, cSetRadio = CreateRadioTexture(clsRow)
        cRadio:SetPoint("LEFT", 4, 0)
        local cLbl = clsRow:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        cLbl:SetPoint("LEFT", cRadio, "RIGHT", 4, 0)
        cLbl:SetText(ClassColorString(cls.classFile) .. cls.className .. "|r")
        local cHL = clsRow:CreateTexture(nil, "HIGHLIGHT")
        cHL:SetAllPoints()
        cHL:SetColorTexture(unpack(ROW_HIGHLIGHT_COLOR))
        clsRow._setRadioChecked = cSetRadio
        clsRow._classID = cls.classID
        clsRow:SetScript("OnClick", function()
            EasyFind.db.appearanceSetClass = { classID = cls.classID }
            UpdateClassLabel()
            classPopup:Hide()
            ApplyFilterSelection()
        end)
        classRows[#classRows + 1] = clsRow
    end

    local function LayoutClassPopup()
        local py = -6
        local cf = EasyFind.db.appearanceSetClass
        for _, r in ipairs(classRows) do
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", classPopup, "TOPLEFT", 8, py)
            r:Show()
            if r._setRadioChecked then
                local match = false
                if not r._classID then
                    match = cf == "all"
                else
                    if type(cf) == "table" and cf.classID == r._classID then
                        match = true
                    elseif not cf then
                        local _, _, cid = UnitClass("player")
                        match = r._classID == cid
                    end
                end
                r._setRadioChecked(match)
            end
            py = py - FLYOUT_ROW_H
        end
        classPopup:SetSize(CLASSPOPUP_WIDTH, -py + 6)
    end

    classBtn:SetScript("OnClick", function(self)
        if classPopup:IsShown() then
            classPopup:Hide()
            return
        end
        LayoutClassPopup()
        classPopup:SetScale(optionsPopup:GetScale())
        classPopup:ClearAllPoints()
        classPopup:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
        classPopup:Show()
    end)

    local filterDefs = {
        { dbKey = "appearanceSetCollected",     label = "Collected" },
        { dbKey = "appearanceSetNotCollected",  label = "Not Collected" },
        { dbKey = "appearanceSetPvE",           label = "PvE" },
        { dbKey = "appearanceSetPvP",           label = "PvP" },
    }

    local cbRows = {}
    local cy = -(PAD + CLASS_BTN_H + 6)
    for si, def in ipairs(filterDefs) do
        local cbRow = CreateFrame("CheckButton", nil, optionsPopup)
        cbRow:SetSize(OPTIONS_WIDTH - PAD * 2, CB_ROW_H)
        cbRow:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD, cy)

        cbRow:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cbRow:GetNormalTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetNormalTexture():ClearAllPoints()
        cbRow:GetNormalTexture():SetPoint("LEFT", 4, 0)

        cbRow:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cbRow:GetCheckedTexture():SetSize(CHECK_SIZE, CHECK_SIZE)
        cbRow:GetCheckedTexture():ClearAllPoints()
        cbRow:GetCheckedTexture():SetPoint("LEFT", 4, 0)

        local cbText = cbRow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        cbText:SetPoint("LEFT", cbRow:GetNormalTexture(), "RIGHT", 4, 0)
        cbText:SetText(def.label)

        local cbHL = cbRow:CreateTexture(nil, "HIGHLIGHT")
        cbHL:SetAllPoints()
        cbHL:SetColorTexture(1, 1, 1, 0.1)

        local val = EasyFind.db[def.dbKey]
        if val == nil then val = true end
        cbRow:SetChecked(val)
        cbRow.dbKey = def.dbKey

        cbRow:SetScript("OnClick", function(self)
            EasyFind.db[def.dbKey] = self:GetChecked()
            ApplyFilterSelection()
        end)

        cbRows[si] = cbRow
        cy = cy - CB_ROW_H
        if si == 2 then
            local sep = optionsPopup:CreateTexture(nil, "ARTWORK")
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", optionsPopup, "TOPLEFT", PAD + 4, cy + 2)
            sep:SetPoint("TOPRIGHT", optionsPopup, "TOPRIGHT", -(PAD + 4), cy + 2)
            sep:SetColorTexture(0.5, 0.5, 0.5, 0.4)
            cy = cy - 6
        end
    end
    optionsPopup:SetSize(OPTIONS_WIDTH, -cy + PAD)

    optionsPopup:HookScript("OnHide", function() classPopup:Hide() end)

    -- Outside-click: close immediately when the user clicks anywhere
    -- that isn't this popup or its nested class popup. The owning
    -- sub-row hover handler is responsible for re-showing on rehover.
    optionsPopup:HookScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    optionsPopup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self._owningRow and self._owningRow:IsMouseOver() then return end
        if Utils.IsFrameVisiblyMouseOver(classPopup) then return end
        self:Hide()
    end)

    local function SyncFromDB()
        for _, sr in ipairs(cbRows) do
            if sr.dbKey then
                sr:SetChecked(EasyFind.db[sr.dbKey] ~= false)
            end
        end
        UpdateClassLabel()
    end

    return optionsPopup, SyncFromDB
end
