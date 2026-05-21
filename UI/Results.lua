local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils
local UIPins = ns.UIPins
local ClickButton = Utils.ClickButton

local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local sfind, slower = Utils.sfind, Utils.slower
local sformat = Utils.sformat
local tinsert, tconcat, tremove, tsort = Utils.tinsert, Utils.tconcat, Utils.tremove, Utils.tsort
local mmin, mmax, mfloor = Utils.mmin, Utils.mmax, Utils.mfloor

local GOLD_COLOR = ns.GOLD_COLOR

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown
local wipe = wipe

local MAX_BUTTON_POOL = 100
local RESULT_SHORTCUT = UI.RESULT_SHORTCUT
local MAX_SEARCH_RESULT_ROWS = 15
local REP_BAR_WIDTH = 100
local deferredRepRefreshPending = false
local resultShortcutFrame
local IsUIItemPinned = UIPins.IsPinned
local resultsFrame

local BOSS_PORTRAIT_TEXCOORD = UI:GetBossPortraitTexCoord()

local function IsBossResultData(data)
    return UI:IsBossResultData(data)
end

local function AbbrevBinding(binding)
    return UI:AbbrevBinding(binding)
end

local function SetClippedText(fontString, text)
    return UI:SetClippedText(fontString, text)
end


local function ShouldShowResultShortcutHints()
    return UI:ShouldShowResultShortcutHints()
end

function UI:EnsureResultButton(index)
    local row = UI:GetResultButtons()[index]
    if not row then
        row = UI:CreateResultButton(index)
        UI:GetResultButtons()[index] = row
    end
    return row
end

local function ReplaceRightPointToShortcut(row, frame)
    local shortcut = row and row.shortcutGroup
    if not shortcut or not frame or not frame.GetNumPoints then return false end
    local count = frame:GetNumPoints()
    if count == 0 then return false end

    local points = {}
    local changed = false
    for i = 1, count do
        local point, relTo, relPoint, xOfs, yOfs = frame:GetPoint(i)
        if point == "RIGHT" and relTo == row and relPoint == "RIGHT" then
            points[i] = { point, shortcut, "LEFT", -RESULT_SHORTCUT.gap, yOfs or 0 }
            changed = true
        else
            points[i] = { point, relTo, relPoint, xOfs or 0, yOfs or 0 }
        end
    end
    if not changed then return false end

    frame:ClearAllPoints()
    for i = 1, #points do
        local p = points[i]
        if p[2] then
            frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
        else
            frame:SetPoint(p[1], p[4], p[5])
        end
    end
    return true
end

local function RestoreRightPointFromShortcut(row, frame, xOfs)
    local shortcut = row and row.shortcutGroup
    if not shortcut or not frame or not frame.GetNumPoints then return false end
    local count = frame:GetNumPoints()
    if count == 0 then return false end

    local points = {}
    local changed = false
    for i = 1, count do
        local point, relTo, relPoint, oldX, yOfs = frame:GetPoint(i)
        if point == "RIGHT" and relTo == shortcut and relPoint == "LEFT" then
            points[i] = { point, row, "RIGHT", xOfs or -8, yOfs or 0 }
            changed = true
        else
            points[i] = { point, relTo, relPoint, oldX or 0, yOfs or 0 }
        end
    end
    if not changed then return false end

    frame:ClearAllPoints()
    for i = 1, #points do
        local p = points[i]
        if p[2] then
            frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
        else
            frame:SetPoint(p[1], p[4], p[5])
        end
    end
    return true
end

local function RestoreResultShortcutGutter(row)
    if not row or not row.shortcutGroup then return end
    RestoreRightPointFromShortcut(row, row.icon, -5)
    RestoreRightPointFromShortcut(row, row.amountText, -8)
    RestoreRightPointFromShortcut(row, row.settingState, -8)
    RestoreRightPointFromShortcut(row, row.settingSliderGroup, -6)
    RestoreRightPointFromShortcut(row, row.settingKeybindGroup, -6)
    RestoreRightPointFromShortcut(row, row.settingDropdownGroup, -6)
    RestoreRightPointFromShortcut(row, row.repBar, -6)
    RestoreRightPointFromShortcut(row, row.pinToggle, -8)
    RestoreRightPointFromShortcut(row, row.text, -8)
    RestoreRightPointFromShortcut(row, row.pathSubtext, -8)
end

local function ApplyResultShortcutGutter(row)
    if not row or not row.shortcutGroup then return end
    if UI.LayoutResultShortcut then
        UI:LayoutResultShortcut(row)
    end

    ReplaceRightPointToShortcut(row, row.icon)
    ReplaceRightPointToShortcut(row, row.amountText)
    ReplaceRightPointToShortcut(row, row.settingState)
    ReplaceRightPointToShortcut(row, row.settingSliderGroup)
    ReplaceRightPointToShortcut(row, row.settingKeybindGroup)
    ReplaceRightPointToShortcut(row, row.settingDropdownGroup)
    ReplaceRightPointToShortcut(row, row.repBar)
    ReplaceRightPointToShortcut(row, row.pinToggle)
    ReplaceRightPointToShortcut(row, row.text)
    ReplaceRightPointToShortcut(row, row.pathSubtext)
end

local function IsShortcutEligibleRow(row)
    return row and row:IsShown() and row.data
        and not row.isPinHeader and not row.isSectionHeader
        and not row.isUnearnedCurrency
        and not row.data.calculatorResult
        and not row.data.calculatorLauncher
end
local function ClearResultShortcutBindings()
    if resultShortcutFrame and not InCombatLockdown() then
        ClearOverrideBindings(resultShortcutFrame)
    end
end

function UI:ClearResultShortcutBindings()
    return ClearResultShortcutBindings()
end
function UI:UpdateVisibleResultShortcuts()
    ClearResultShortcutBindings()
    local showShortcutHints = ShouldShowResultShortcutHints()

    for i = 1, MAX_BUTTON_POOL do
        local row = UI:GetResultButtons()[i]
        if not row then break end
        row._efShortcutIndex = nil
        row._efShortcutBindingReady = nil
        if row.shortcutNumberText then row.shortcutNumberText:SetText("") end
        if row.shortcutGroup then
            row.shortcutGroup:Hide()
        end
    end

    if not (resultsFrame and resultsFrame:IsShown()
            and resultsFrame.scrollFrame and resultShortcutFrame) then
        return
    end

    local scrollTop = resultsFrame.scrollFrame:GetVerticalScroll() or 0
    local viewH = resultsFrame.scrollFrame:GetHeight() or 0
    if viewH <= 0 then viewH = resultsFrame:GetHeight() or 0 end
    local scrollBottom = scrollTop + viewH
    local assigned = 0

    for i = 1, MAX_BUTTON_POOL do
        local row = UI:GetResultButtons()[i]
        if not row then break end
        if IsShortcutEligibleRow(row) then
            local rowTop = row._efContentTop or 0
            local rowBottom = row._efContentBottom or (rowTop + (row:GetHeight() or 0))
            if rowBottom > scrollTop + 0.5 and rowTop < scrollBottom - 0.5 then
                assigned = assigned + 1
                if assigned <= RESULT_SHORTCUT.max then
                    row._efShortcutIndex = assigned
                    if showShortcutHints and row.shortcutNumberText then
                        row.shortcutNumberText:SetText(tostring(assigned))
                    end
                    if row.shortcutGroup then
                        row.shortcutGroup:SetShown(showShortcutHints)
                    end
                    if not InCombatLockdown() then
                        local targetName
                        if UI:IsSecureActionResult(row.data) then
                            targetName = row:GetName()
                            row._efShortcutBindingReady = true
                        else
                            local proxy = resultShortcutFrame.shortcutButtons
                                and resultShortcutFrame.shortcutButtons[assigned]
                            if proxy then
                                proxy._shortcutIndex = assigned
                                targetName = proxy:GetName()
                            end
                        end
                        if targetName then
                            SetOverrideBindingClick(resultShortcutFrame, true, "ALT-" .. assigned, targetName, "LeftButton")
                            SetOverrideBindingClick(resultShortcutFrame, true, "ALT-NUMPAD" .. assigned, targetName, "LeftButton")
                        end
                    end
                end
            end
        end
    end
end

function UI:SuppressQuickFilterLeakedText(leakedText)
    local editBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
    if not (editBox and C_Timer and C_Timer.After) then return end
    leakedText = tostring(leakedText or "")
    if leakedText == "" then return end

    local function clearLeakedText()
        if not (UI:GetSearchFrame() and UI:GetSearchFrame():IsShown() and editBox:IsVisible()) then return end
        if not self._quickFilter then return end
        if (editBox:GetText() or "") ~= leakedText then return end
        if editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        editBox:SetText("")
        editBox:SetCursorPosition(0)
        editBox.blockFocus = nil
        editBox:SetFocus()
        self:OnSearchTextChanged("", true)
    end

    C_Timer.After(0, clearLeakedText)
    C_Timer.After(0.03, clearLeakedText)
end

function UI:ActivateVisibleResultShortcut(shortcutIndex)
    if not shortcutIndex then return nil end
    for i = 1, MAX_BUTTON_POOL do
        local row = UI:GetResultButtons()[i]
        if not row then break end
        if row._efShortcutIndex == shortcutIndex and IsShortcutEligibleRow(row) then
            if UI:IsSecureActionResult(row.data) then
                if row._efShortcutBindingReady then return "binding" end
                if not InCombatLockdown() and ClickButton(row) then
                    return "handled"
                end
                return "binding"
            end
            UI:SetSelectedIndex(i)
            UI:SetToggleFocused(false)
            self:UpdateSelectionHighlight(true)
            if row.data and row.data.quickFilterDef then
                self:ApplyQuickFilter(row.data.quickFilterDef, "")
                self:SuppressQuickFilterLeakedText(shortcutIndex)
                return "quickFilter"
            end
            self:ActivateResultRow(row, "key")
            return "handled"
        end
    end
    return nil
end

function UI:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", UI:GetSearchFrame(), "BackdropTemplate")
    UI:SetResultsFrame(resultsFrame)
    resultsFrame:SetWidth(380)  -- Wide to accommodate tree indentation
    resultsFrame:SetPoint("TOP", UI:GetSearchFrame(), "BOTTOM", 0, 2)
    resultsFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    resultsFrame:SetFrameLevel(UI:GetSearchFrame():GetFrameLevel() + 1)

    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })

    local theme = UI:GetActiveTheme()
    local bgAtlasTex = resultsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgAtlasTex:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 4, -4)
    bgAtlasTex:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -4, 4)
    if theme.resultsBgAtlas then
        bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
    end
    bgAtlasTex:Hide()
    resultsFrame.bgAtlasTex = bgAtlasTex

    resultsFrame:Hide()

    -- Click-outside-to-close: hides the results frame on any click that
    -- isn't on the search bar, results frame, or one of its associated
    -- popups (filter dropdown, pin/right-click menu, gear/collections
    -- option popups). Hover-out doesn't close: that's too sensitive.
    resultsFrame:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    resultsFrame:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    resultsFrame:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if UI:GetSearchFrame() and UI:GetSearchFrame():IsMouseOver() then return end
        if UI:IsOptionsSurfaceMouseOver() then return end
        local guards = {
            _G["EasyFindUIFilterDropdown"],
            _G["EasyFindPinPopup"],
            _G["EasyFindAsOptionsPopup"],
            _G["EasyFindAsClassPopup"],
            _G["EasyFindGearOptionsPopup"],
            _G["EasyFindDiffPopup"],
            _G["EasyFindSpecPopup"],
            _G["EasyFindSpecFlyout"],
            _G["EasyFindCalculatorFrame"],
            -- Blizzard's StaticPopup slots: clicks on our unapplied-
            -- settings popup buttons (Apply / Exit / Cancel) must not
            -- register as "outside" or they'd trigger an extra
            -- RequestHideResults that closes the panel.
            _G["StaticPopup1"], _G["StaticPopup2"],
            _G["StaticPopup3"], _G["StaticPopup4"],
        }
        for _, g in ipairs(guards) do
            if Utils.IsFrameOrChildMouseOver(g) then return end
        end
        UI:RequestHideResults()
    end)

    local resizeTimer
    resultsFrame:SetScript("OnSizeChanged", function()
        if not resultsFrame:IsShown() or not UI._cachedHierarchical then return end  -- luacheck: ignore 113
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.02, function()
            resizeTimer = nil
            UI:ShowHierarchicalResults(UI._cachedHierarchical, true)  -- luacheck: ignore 113
        end)
    end)

    -- Plain ScrollFrame for clipping. Wheel handler is wired up by
    -- CreateMinimalScrollBar so wheel events route through the eased path.
    local scrollFrame = CreateFrame("ScrollFrame", nil, resultsFrame)
    resultsFrame.scrollFrame = scrollFrame

    local quickFilterHelp = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickFilterHelp:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 12, -8)
    quickFilterHelp:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -12, -8)
    quickFilterHelp:SetJustifyH("LEFT")
    quickFilterHelp:SetTextColor(0.78, 0.78, 0.80, 1)
    quickFilterHelp:SetText("|cffffd100Quick filters:|r @m, @s, @g. Tab/Space selects a category.")
    quickFilterHelp:Hide()
    resultsFrame.quickFilterHelp = quickFilterHelp

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    resultsFrame.scrollChild = scrollChild

    -- Minimal retail-style scrollbar (overlays right edge, no content squish)
    resultsFrame.scrollBar = ns.Utils.CreateMinimalScrollBar(scrollFrame, resultsFrame)
    scrollFrame:HookScript("OnVerticalScroll", function()
        UI:UpdateVisibleResultShortcuts()
    end)

    resultShortcutFrame = CreateFrame("Frame", nil, UI:GetSearchFrame())
    resultShortcutFrame.shortcutButtons = {}
    for i = 1, RESULT_SHORTCUT.max do
        local proxy = CreateFrame("Button", "EasyFindResultShortcutButton" .. i, resultShortcutFrame)
        proxy._shortcutIndex = i
        proxy:SetScript("OnClick", function(self)
            UI:ActivateVisibleResultShortcut(self._shortcutIndex)
        end)
        resultShortcutFrame.shortcutButtons[i] = proxy
    end

    local pinSeparator = scrollChild:CreateTexture(nil, "ARTWORK")
    pinSeparator:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    pinSeparator:SetHeight(1)
    pinSeparator:Hide()
    resultsFrame.pinSeparator = pinSeparator

    -- Category separator lines (between result category groups)
    local categorySeps = {}
    for sepIdx = 1, 6 do
        local sep = scrollChild:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.3)
        sep:SetHeight(1.5)
        sep:Hide()
        categorySeps[sepIdx] = sep
    end
    resultsFrame.categorySeps = categorySeps
end

-- Per-depth indent line colors. Used as a fallback when a theme's
-- indentColors array doesn't define a color for the requested depth.
local INDENT_COLORS = {
    {0.40, 0.85, 1.00, 0.80},
    {1.00, 0.55, 0.10, 0.80},
    {0.55, 1.00, 0.35, 0.80},
    {1.00, 0.40, 0.70, 0.80},
    {0.70, 0.55, 1.00, 0.80},
    {1.00, 0.90, 0.20, 0.80},
}

local INDENT_PX  = 20  -- pixels per depth level (icon 16 + 4 gap)
local LINE_X_OFF = 10  -- horizontal offset within each depth column (clears tab rounded corner)
local MAX_DEPTH  = 0

-- Session-only collapse state for path nodes (cleared on every new search)
local collapsedNodes = {}   -- key = "name_depth", value = true
UI._cachedHierarchical = UI._cachedHierarchical    -- last full hierarchical list for re-rendering after toggle

local flatEntries = {}
local flatCombined = {}
local pinnedSearchEntries = {}
local pinnedSearchPinEntries = {}

-- Inline achievement search: drive Blizzard's own indexed achievement
-- search system (the one that powers the AchievementFrame's search box)
-- in the background. SetAchievementSearchString builds an internal
-- index on first call and emits ACHIEVEMENT_SEARCH_UPDATED when results
-- are ready; GetFilteredAchievementID(i) reads them out. We pre-warm
-- the index once after login so per-keystroke searches are instant,
-- and we synthesize result rows on the fly without pre-loading any of
-- the ~25k achievement entries into our own search index.
local ACHIEVEMENT_PROTO = {
    keywords      = {},
    keywordsLower = {},
    category      = "Achievement",
    buttonFrame   = "AchievementMicroButton",
    path          = { "Achievements" },
}
local ACHIEVEMENT_MT = { __index = ACHIEVEMENT_PROTO }
local achievementEntryByID = {}
local achSearchCache = {}
local achSearchStatsVersion
local achSearchPending = nil
local achSearchCurrentQuery = nil
local achSearchListener
local achSearchPrewarmed = false
local ACH_MAX_RESULTS = 8

local function GetAchievementFilterMode()
    local mode = EasyFind and EasyFind.db and EasyFind.db.achievementFilterMode or "all"
    if mode == "earned" or mode == "incomplete" then return mode end
    return "all"
end

local function AchievementSearchCacheKey(query, mode)
    return (mode or "all") .. "\31" .. (query or "")
end

local function AchievementPassesFilter(completed, mode)
    if mode == "earned" then return completed == true end
    if mode == "incomplete" then return completed ~= true end
    return true
end

local function SyncAchievementSearchStatsVersion()
    local version = ns.Database and ns.Database.statisticsVersion or 0
    if achSearchStatsVersion == version then return end
    wipe(achSearchCache)
    wipe(achievementEntryByID)
    achSearchPending = nil
    achSearchCurrentQuery = nil
    achSearchStatsVersion = version
end

-- Walk the achievement's category chain root-down so the guide
-- breadcrumbs through each parent before highlighting the achievement
-- row. GetAchievementCategory + GetCategoryInfo (parentID) walks up
-- toward -1 (root sentinel).
local function BuildAchievementSteps(achievementID)
    local steps = {
        { buttonFrame = "AchievementMicroButton" },
        { waitForFrame = "AchievementFrame", tabIndex = 1 },
    }
    local getCat   = _G["GetAchievementCategory"]
    local getInfo  = _G["GetCategoryInfo"]
    if not getCat or not getInfo then
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementID = achievementID,
        }
        return steps
    end
    local catID = getCat(achievementID)
    if not catID or catID < 0 then
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementID = achievementID,
        }
        return steps
    end
    local chain = {}
    local seen = {}
    local current = catID
    while current and current > 0 and not seen[current] do
        seen[current] = true
        local title, parentID = getInfo(current)
        if not title then break end
        chain[#chain + 1] = { id = current, name = title }
        current = parentID
    end
    -- Reverse so root-most appears first.
    for i = #chain, 1, -1 do
        local cat = chain[i]
        steps[#steps + 1] = {
            waitForFrame = "AchievementFrame",
            achievementCategory = cat.name,
            achievementCategoryID = cat.id,
        }
    end
    -- Final step targets the achievement itself.
    steps[#steps + 1] = {
        waitForFrame = "AchievementFrame",
        achievementID = achievementID,
    }
    return steps
end

local function GetOrCreateAchievementEntry(id, name, icon)
    local entry = achievementEntryByID[id]
    if entry then
        if name and entry.name ~= name then
            entry.name = name
            entry.nameLower = slower(name)
        end
        if icon and entry.icon ~= icon then entry.icon = icon end
        entry.steps = BuildAchievementSteps(id)
        return entry
    end
    entry = setmetatable({
        name = name,
        nameLower = slower(name or ""),
        achievementID = id,
        icon = icon,
        steps = BuildAchievementSteps(id),
    }, ACHIEVEMENT_MT)
    achievementEntryByID[id] = entry
    return entry
end

local function CollectAchievementSearchResults(query, mode)
    SyncAchievementSearchStatsVersion()
    mode = mode or GetAchievementFilterMode()

    local getNum = _G["GetNumFilteredAchievements"]
    local getID  = _G["GetFilteredAchievementID"]
    local getInfo = _G["GetAchievementInfo"]
    if not getNum or not getID or not getInfo then return nil end
    local count = getNum() or 0
    if count == 0 then return {} end
    local results = {}
    local isStat = ns.Database and ns.Database.IsStatisticAchievement
        and function(id) return ns.Database:IsStatisticAchievement(id) end
    for i = 1, count do
        if #results >= ACH_MAX_RESULTS then break end
        local id = getID(i)
        if id and not (isStat and isStat(id)) then
            local _, name, _, completed, _, _, _, _, _, icon = getInfo(id)
            if name and name ~= "" and AchievementPassesFilter(completed, mode) then
                results[#results + 1] = GetOrCreateAchievementEntry(id, name, icon)
            end
        end
    end
    return results
end

local function EnsureAchievementSearchListener()
    if achSearchListener then return end
    achSearchListener = CreateFrame("Frame")
    achSearchListener:RegisterEvent("ACHIEVEMENT_SEARCH_UPDATED")
    achSearchListener:RegisterEvent("ACHIEVEMENT_EARNED")
    achSearchListener:SetScript("OnEvent", function(_, event)
        if event == "ACHIEVEMENT_EARNED" then
            wipe(achSearchCache)
            return
        end
        local pending = achSearchPending
        if not pending then return end
        achSearchPending = nil
        achSearchCurrentQuery = pending.query
        local results = CollectAchievementSearchResults(pending.query, pending.mode)
        if results then achSearchCache[pending.key] = results end
        local eb = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
        if eb then
            -- Compare against the typed prefix (cursor-position cut),
            -- not the full editbox text. The autocomplete suffix is
            -- selected past the cursor and would make full text != pending.
            local full = eb:GetText() or ""
            local cursor = eb:GetCursorPosition() or #full
            local typedPrefix = strtrim(full:sub(1, cursor))
            if typedPrefix == pending.query then
                UI:OnSearchTextChanged(typedPrefix, true)
            end
        end
    end)
end

function UI:RequestAchievementSearch(query)
    if not query or #query < 2 then return nil end
    SyncAchievementSearchStatsVersion()

    local mode = GetAchievementFilterMode()
    local cacheKey = AchievementSearchCacheKey(query, mode)
    local cached = achSearchCache[cacheKey]
    if cached then return cached end
    if achSearchCurrentQuery == query then
        local results = CollectAchievementSearchResults(query, mode)
        if results then
            achSearchCache[cacheKey] = results
            return results
        end
    end
    local setSearch = _G["SetAchievementSearchString"]
    if not setSearch then return nil end
    EnsureAchievementSearchListener()
    achSearchPending = { query = query, mode = mode, key = cacheKey }
    pcall(setSearch, query)
    return nil
end

function UI:PrewarmAchievementSearch()
    if achSearchPrewarmed then return end
    achSearchPrewarmed = true
    local loadUI = _G["AchievementFrame_LoadUI"]
    if loadUI then pcall(loadUI) end
    EnsureAchievementSearchListener()
    local setSearch = _G["SetAchievementSearchString"]
    if not setSearch then return end
    -- Trigger the one-time index build off the player's typing path.
    -- A nonsensical query that won't match anything keeps the search
    -- box visually empty if the user opens AchievementFrame later.
    pcall(setSearch, "\1")
    if Utils and Utils.SafeAfter then
        Utils.SafeAfter(0.5, function() pcall(setSearch, "") end)
    end
end

local SCRATCH = {
    visible = {},
    isLastChild = {},
    catSepYPositions = {},
    aliasSeen = {},
    calculatorResults = {},
    filteredResults = {},
    quickFilterResults = {},
    skipCategories = {},
}

UI._flatEntries = flatEntries
UI._flatCombined = flatCombined
UI._pinnedSearchEntries = pinnedSearchEntries
UI._pinnedSearchPinEntries = pinnedSearchPinEntries
UI._collapsedNodes = collapsedNodes
UI._SCRATCH = SCRATCH
UI._resultButtons = UI:GetResultButtons()

local heavySearchLoading = false

local function FlatNameLess(ra, rb)
    local sa, sb = ra.score or 0, rb.score or 0
    if sa ~= sb then return sa > sb end
    return (ra.data.name or "") < (rb.data.name or "")
end
local function QueryLooksBossRelated(text)
    if not text then return false end
    for word in slower(text):gmatch("%S+") do
        word = word:gsub("^%p+", ""):gsub("%p+$", "")
        if word == "boss" or word == "bosses"
           or word == "dungeon" or word == "dungeons"
           or word == "raid" or word == "raids" then
            return true
        end
    end
    return false
end

local function RefreshSearchAfterHeavyLoad(anyChanged)
    if not anyChanged then return end
    local currentText = UI:GetSearchFrame() and UI:GetSearchFrame().editBox and UI:GetSearchFrame().editBox:GetText()
    if UI:GetSearchFrame() and UI:GetSearchFrame().editBox and UI:GetSearchFrame().editBox:HasFocus()
       and currentText and currentText ~= "" then
        UI:OnSearchTextChanged(currentText, true)
    end
end

local function MaybeLoadHeavySearchData(text, needsHeavy)
    if not ns.Database then return end
    if QueryLooksBossRelated(text) and ns.Database.EnsureDynamicProviderLoaded then
        ns.Database:EnsureDynamicProviderLoaded("bosses", RefreshSearchAfterHeavyLoad)
    end
    if heavySearchLoading or not ns.Database.LoadHeavyDynamicSearchData then return end
    if not needsHeavy then return end
    heavySearchLoading = true
    local started = ns.Database:LoadHeavyDynamicSearchData(function(anyChanged)
        heavySearchLoading = false
        -- Only re-run search when a provider actually loaded fresh data.
        -- Without this gate, every keystroke after providers are loaded
        -- result re-rendering and SearchUI's per-iteration scratch.
        RefreshSearchAfterHeavyLoad(anyChanged)
    end)
    if not started then heavySearchLoading = false end
end

function UI:PushSearchHistory(text)
    if not EasyFind.db then return end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" then
        hist = {}
        EasyFind.db.uiSearchHistory = hist
    end
    local lower = text:lower()
    for i = #hist, 1, -1 do
        if hist[i] and hist[i]:lower() == lower then
            tremove(hist, i)
        end
    end
    tinsert(hist, 1, text)
    local limit = EasyFind.db.uiSearchHistoryLimit or 500
    while #hist > limit do tremove(hist) end
end

-- Prompt the user for an alias text and bind it to `data`. Uses a
-- StaticPopup with a single edit box so we don't need to hand-build a
-- dialog frame. Pre-fills with the current search text so saving an
-- alias for whatever just matched is one keystroke.
StaticPopupDialogs["EASYFIND_ADD_ALIAS"] = {
    text = "Alias for %s:",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 64,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    OnShow = function(self, data)
        local eb = self.editBox or self.EditBox
        if eb then
            eb:SetText("")
            eb:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local eb = self.editBox or self.EditBox
        local txt = eb and eb:GetText() or ""
        if strtrim(txt) == "" then return end
        if ns.Aliases and ns.Aliases:Add(txt, data) then
            local aliasText = strtrim(txt)
            local targetName = data and data.name or "this entry"
            if EasyFind and EasyFind.Print and EasyFind.db and EasyFind.db.showAliasMessages ~= false then
                EasyFind:Print("New alias: " .. aliasText .. " -> " .. targetName .. ". View this and any other existing aliases in the Aliases tab of the options menu.")
            end
            local searchEditBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
            local current = searchEditBox and searchEditBox:GetText() or ""
            if current ~= "" then UI:OnSearchTextChanged(current) end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        if parent.button1 then parent.button1:Click() end
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
}

StaticPopupDialogs["EASYFIND_RESET_SEARCH_BAR"] = {
    text = "Reset the search bar to its default position and size?",
    button1 = "Reset",
    button2 = CANCEL or "Cancel",
    OnShow = function(self)
        self:SetFrameStrata("TOOLTIP")
        self:SetFrameLevel(1000)
    end,
    OnAccept = function()
        if ns.UI and ns.UI.ResetPositionAndSize then
            ns.UI:ResetPositionAndSize()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UI:PromptForAlias(data)
    if not data then return end
    local label = data.name or "this entry"
    local dialog = StaticPopup_Show("EASYFIND_ADD_ALIAS", label, nil, data)
    if dialog then
        dialog:SetFrameStrata("TOOLTIP")
        dialog:SetFrameLevel(1000)
    end
end

-- Step through search history from the editbox. Direction +1 = older,
-- -1 = newer. Returns true if the editbox was updated, false if the
-- caller should fall through to its default key behavior (e.g. DOWN
-- past the newest entry should drop into result navigation).
function UI:NavigateSearchHistory(direction)
    if not EasyFind.db then return false end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" or #hist == 0 then return false end
    local editBox = UI:GetSearchFrame() and UI:GetSearchFrame().editBox
    if not editBox then return false end

    -- Capture the user's in-flight buffer the first time we step away
    -- from index 0 so DOWN-back-to-0 restores it instead of clobbering
    -- their typing.
    if UI:GetSearchHistoryIndex() == 0 and direction > 0 then
        UI:SetSearchHistoryDraft(editBox:GetText() or "")
    end

    local newIndex = UI:GetSearchHistoryIndex() + direction
    if newIndex < 0 then return false end
    if newIndex > #hist then newIndex = #hist end
    if newIndex == UI:GetSearchHistoryIndex() then return false end

    UI:SetSearchHistoryIndex(newIndex)
    if newIndex == 0 then
        editBox:SetText(UI:GetSearchHistoryDraft() or "")
    else
        editBox:SetText(hist[newIndex] or "")
    end
    editBox:SetCursorPosition(#editBox:GetText())
    -- Programmatic SetText fires OnTextChanged with userInput=false, which
    -- the OnTextChanged hook now ignores (so the autocomplete suffix can't
    -- feed back into the search query). History nav still wants a fresh
    -- result render for the recalled query, so kick it manually.
    local searchFrame = UI:GetSearchFrame()
    local preserveRepeat = searchFrame and searchFrame.IsAltNavRepeatKey
        and searchFrame.IsAltNavRepeatKey()
    UI._preserveSearchNavRepeat = preserveRepeat or nil
    UI:OnSearchTextChanged(editBox:GetText() or "", true)
    UI._preserveSearchNavRepeat = nil
    return true
end

function UI:OnSearchTextChanged(text, force)
    -- Suppress re-renders while SelectResult is clearing text/focus
    if UI:IsSelectingResult() then return end
    -- A pending OnTextChanged timer can fire after focus has shifted
    -- away from the editbox (user clicked outside, OR clicked an
    -- inline child widget like a slider that StripAutocomplete then
    -- triggers a SetText on via the focus-loss hook). Just bail:
    -- don't re-render, but also don't hide. The outside-click paths
    -- (GLOBAL_MOUSE_DOWN, OnEditFocusLost) decide whether to actually
    -- hide based on cursor position. Calling HideResults here also
    -- tore down the panel during slider drags, which is exactly what
    -- we want to avoid.
    -- `force` lets internal callers (pin/unpin from the right-click
    -- menu) re-render after the pin popup briefly stole focus.
    if not force and UI:GetSearchFrame() and UI:GetSearchFrame().editBox
        and not UI:GetSearchFrame().editBox:HasFocus() then
        return
    end
    -- Treat whitespace-only as empty (pins show on focus, not on blank spaces)
    if text then text = strtrim(text) end
    UI:ClearResultTooltips()
    local quickFilter = self:GetQuickFilter()
    if not text or text == "" then
        if ns.Database and ns.Database.CancelDynamicWarmup then
            ns.Database:CancelDynamicWarmup()
        end
        -- Normally only show pins when focused. Forced refreshes (ESC clear,
        -- pin-menu actions) also rebuild pins so stale typed results disappear.
        if force or (UI:GetSearchFrame() and UI:GetSearchFrame().editBox and UI:GetSearchFrame().editBox:HasFocus()) then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    local commandEntries = (not quickFilter) and self:GetSearchBarCommandSuggestionEntries(text)
    if commandEntries then
        self:ShowHierarchicalResults(commandEntries)
        return
    end

    wipe(collapsedNodes)
    local calculatorData = (not quickFilter) and self:EvaluateCalculatorExpression(text) or nil
    local calculatorLauncher = (not quickFilter and not calculatorData)
        and self:GetCalculatorLauncherMatch(text) or nil
    local needsHeavy = not calculatorData and not calculatorLauncher and (
        (ns.Database and ns.Database.QueryNeedsHeavySearchData
            and ns.Database:QueryNeedsHeavySearchData(text))
        or self:QuickFilterNeedsHeavyData(quickFilter)
    )
    if not force and not needsHeavy and ns.Database and ns.Database.CancelDynamicWarmup then
        ns.Database:CancelDynamicWarmup()
    end
    MaybeLoadHeavySearchData(text, needsHeavy)

    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Collection items (mounts/toys/pets/outfits/appearance sets) are
    -- skipped when their own filter is off OR the parent Collections
    -- toggle is off. Loot is independent.
    local filters = quickFilter and nil or EasyFind.db.uiSearchFilters
    local collectionsOff = filters and filters.collections == false
    local optionsOff = filters and filters.options == false
    local skipCategories
    if filters then
        local mountsOff = collectionsOff or filters.mounts == false
        local toysOff   = collectionsOff or filters.toys == false
        local petsOff   = collectionsOff or filters.pets == false
        local outfitsOff = collectionsOff or filters.outfits == false
        local heirloomsOff = collectionsOff or filters.heirlooms == false
        local appsetsOff = collectionsOff or filters.appearanceSets == false
        local lootOff    = filters.loot == false
        local bagsOff    = filters.bags == false
        local macrosOff  = filters.macros == false
        local gameOptOff  = optionsOff or filters.gameOptions == false
        local addonOptOff = optionsOff or filters.addonOptions == false
        local abilitiesOff = filters.abilities == false
        local bossesOff = filters.bosses == false
        local titlesOff = filters.titles == false
        local gearSetsOff = filters.gearSets == false
        if mountsOff or toysOff or petsOff or outfitsOff or lootOff
           or appsetsOff or bagsOff or macrosOff or gameOptOff or addonOptOff
           or abilitiesOff or bossesOff or heirloomsOff or titlesOff or gearSetsOff then
            skipCategories = SCRATCH.skipCategories
            wipe(skipCategories)
            if mountsOff    then skipCategories["Mount"] = true end
            if toysOff      then skipCategories["Toy"] = true end
            if petsOff      then skipCategories["Pet"] = true end
            if outfitsOff   then skipCategories["Outfit"] = true end
            if heirloomsOff then skipCategories["Heirloom"] = true end
            if lootOff      then skipCategories["Loot"] = true end
            if appsetsOff   then skipCategories["Appearance Set"] = true end
            if bagsOff      then skipCategories["Bag"] = true end
            if macrosOff    then skipCategories["Macro"] = true end
            if gameOptOff   then skipCategories["Game Settings"] = true end
            if addonOptOff  then skipCategories["AddOn Settings"] = true end
            if abilitiesOff then skipCategories["Ability"] = true end
            if bossesOff    then skipCategories["Boss"] = true end
            if titlesOff    then skipCategories["Title"] = true end
            if gearSetsOff  then skipCategories["Gear Set"] = true end
        end
    end
    local _perfT0 = ns.PERF and debugprofilestop() or 0
    local results
    if calculatorData or calculatorLauncher then
        results = SCRATCH.calculatorResults
        wipe(results)
    else
        results = ns.Database:SearchUI(text, skipCategories)
    end
    local _perfTSearch = ns.PERF and debugprofilestop() or 0

    -- Inject user-defined alias hits at the front. Aliases bypass
    -- bucket filters so a saved shortcut is always reachable, even if
    -- the user has the underlying category turned off in the filter
    -- menu. Dedupe against already-present results by data identity.
    if ns.Aliases then
        local aliasMatches = ns.Aliases:GetMatches(text:lower())
        if aliasMatches then
            wipe(SCRATCH.aliasSeen)
            local seen = SCRATCH.aliasSeen
            for _, r in ipairs(results) do seen[r.data] = true end
            for i = #aliasMatches, 1, -1 do
                local hit = aliasMatches[i]
                if not seen[hit.data] then
                    local data = hit.data
                    if data and data.mapSearchResult then
                        local wrapped = {}
                        for k, v in pairs(data) do wrapped[k] = v end
                        wrapped.query = (hit.alias and hit.alias.text) or text
                        data = wrapped
                    end
                    tinsert(results, 1, { data = data, score = math.huge, isAlias = true })
                    seen[hit.data] = true
                end
            end
            wipe(seen)
        end
    end

    if quickFilter then
        wipe(SCRATCH.quickFilterResults)
        local filtered = SCRATCH.quickFilterResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r and self:QuickFilterAllowsData(r.data, quickFilter) then
                fi = fi + 1
                filtered[fi] = r
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Bucket-aware UI filter: drop UI entries whose bucket
    -- (abilities / achievements / currencies / reputations / bags /
    -- options) is unchecked. Base UI entries have no bucket and are
    -- always searchable. Options is a parent toggle: when off, both
    -- gameOptions and addonOptions buckets are treated as off.
    -- abilityHidePassives also drops isPassive ability rows here so
    -- the filter applies regardless of which bucket is on.
    local hidePassives = EasyFind.db.abilityHidePassives
    local hideAchievementHeaders = EasyFind.db.hideAchievementHeaders
    if filters and (filters.abilities == false or filters.bosses == false
                    or filters.achievements == false or filters.statistics == false
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false
                    or filters.titles == false or filters.gearSets == false
                    or filters.talents == false
                    or hidePassives or hideAchievementHeaders) then
        wipe(SCRATCH.filteredResults)
        local filtered = SCRATCH.filteredResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r.isAlias then
                fi = fi + 1
                filtered[fi] = r
            else
                local d = r.data
                local bucket = UI:GetUIBucket(d)
                local bucketOff = bucket and filters[bucket] == false
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                local passiveOff = hidePassives and d and d.category == "Ability" and d.isPassive
                local headerOff = hideAchievementHeaders and d
                    and d.category == "Achievement Category"
                if not passiveOff and not headerOff
                   and (not bucket or (not bucketOff and not parentOff)) then
                    fi = fi + 1
                    filtered[fi] = r
                end
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Currency filter mode: kept in DB so it can drive bidirectional
    -- sync with the in-game CurrencyFrame's filter dropdown later, but
    -- we deliberately don't prune our own search results here. The
    -- in-game tab shows every currency the character has discovered
    -- (zero-quantity warband-transferable ones included), and an
    -- earlier per-cache `isAccountTransferable` check was hiding some
    -- of those because the flag's truthiness varied across builds.
    -- Showing everything keeps search at least as inclusive as the
    -- in-game tab regardless of what mode is selected.

    local mapResults
    if not calculatorData and not calculatorLauncher and ns.MapSearch and ns.MapSearch.SearchForUI
       and ((quickFilter and quickFilter.key == "map")
            or (not quickFilter and filters and filters.map ~= false)) then
        mapResults = ns.MapSearch:SearchForUI(text)
    end

    wipe(flatCombined)
    local combined = flatCombined
    if calculatorData then
        combined[#combined + 1] = { data = calculatorData, score = math.huge }
    elseif calculatorLauncher then
        combined[#combined + 1] = { data = calculatorLauncher, score = math.huge }
    end
    for ri = 1, #results do combined[#combined + 1] = results[ri] end
    if mapResults then
        for ri = 1, #mapResults do combined[#combined + 1] = mapResults[ri] end
    end
    if #combined > 1 then tsort(combined, FlatNameLess) end

    -- Hard cap on visible results. The scoring step already ranks by
    -- relevance; everything past the cap is noise the user has to scroll
    -- through. Pinned items aren't in this set (they only show on empty
    -- query), so the cap is a clean top-N over the actual search match
    -- list. 15 matches the original uiMaxResults default.
    local TOP_N = 15
    if #combined > TOP_N then
        for ri = #combined, TOP_N + 1, -1 do combined[ri] = nil end
    end

    -- Inline achievement results: drive Blizzard's indexed achievement
    -- search and surface its results directly in our dropdown. First
    -- call for a given query kicks off the (already-built) index lookup
    -- and returns nothing; ACHIEVEMENT_SEARCH_UPDATED fires next frame
    -- and we re-render with the cached results. Score each one through
    -- ScoreName so they interleave naturally with mount / toy / setting
    -- hits ranked off the same query, instead of clumping at a fixed
    -- band.
    if not calculatorData and not calculatorLauncher and text ~= ""
       and ((quickFilter and quickFilter.key == "achievements")
            or (not quickFilter and (not filters or filters.achievements ~= false))) then
        local achHits = self:RequestAchievementSearch(text)
        if achHits and ns.Database and ns.Database.ScoreName then
            local lowerQ = slower(text)
            local qLen = #lowerQ
            -- Blizzard's index returns matches across name + description
            -- + criteria; we only want name matches here. Base UI entries
            -- still cover direct navigation to achievement categories, so
            -- drop anything ScoreName can't rank against the achievement
            -- name itself.
            for ai = 1, #achHits do
                local entry = achHits[ai]
                local score = ns.Database:ScoreName(entry.nameLower, lowerQ, qLen)
                if score and score > 0 then
                    combined[#combined + 1] = { data = entry, score = score }
                end
            end
        end
    end

    local n = 0
    for ri = 1, #combined do
        local d = combined[ri] and combined[ri].data
        if d then
            n = n + 1
            local e = flatEntries[n]
            if not e then
                e = {}
                flatEntries[n] = e
            end
            e.name = d.name
            e.depth = 0
            e.isPathNode = false
            e.isMatch = true
            e.isFlat = true
            e.flatCatKey = nil
            e.isPinned = (not d.noPin and IsUIItemPinned(d)) and true or false
            e.data = d
        end
    end
    for i = n + 1, #flatEntries do
        flatEntries[i] = nil
    end

    -- Stable partition: pinned matches float to the top, non-pinned
    -- follow. Each group keeps its score-sorted order. Pinned items
    -- the user has stuck stay at the head of every relevant search.
    if n > 1 then
        local pinnedBuf = SCRATCH.pinnedFlat or {}
        SCRATCH.pinnedFlat = pinnedBuf
        local otherBuf = SCRATCH.otherFlat or {}
        SCRATCH.otherFlat = otherBuf
        wipe(pinnedBuf)
        wipe(otherBuf)
        for i = 1, n do
            local e = flatEntries[i]
            if e.isPinned then
                pinnedBuf[#pinnedBuf + 1] = e
            else
                otherBuf[#otherBuf + 1] = e
            end
        end
        if #pinnedBuf > 0 and #pinnedBuf < n then
            local out = 0
            for i = 1, #pinnedBuf do
                out = out + 1
                flatEntries[out] = pinnedBuf[i]
            end
            for i = 1, #otherBuf do
                out = out + 1
                flatEntries[out] = otherBuf[i]
            end
        end
    end

    local hierarchical = flatEntries
    wipe(pinnedSearchEntries)
    local _perfTBuild = ns.PERF and debugprofilestop() or 0
    self:ShowHierarchicalResults(hierarchical)
    if ns.PERF then
        local now = debugprofilestop()
        EasyFind:Print(string.format(
            "perf: q=%q  search=%.2fms  build=%.2fms  render=%.2fms  total=%.2fms  rows=%d",
            text or "",
            _perfTSearch - _perfT0,
            _perfTBuild  - _perfTSearch,
            now          - _perfTBuild,
            now          - _perfT0,
            #hierarchical))
    end
end

local function GetButtonIcon(frameName)
    local frame = _G[frameName]
    if not frame then return nil end

    -- For MicroButtons - use the textureName property to build atlas
    -- Atlas format: "UI-HUD-MicroMenu-<textureName>-Up"
    if frame.textureName then
        local atlas = "UI-HUD-MicroMenu-" .. frame.textureName .. "-Up"
        return atlas, true -- true means it's an atlas
    end

    -- MicroButtons without textureName (e.g. CharacterMicroButton) use a portrait
    -- render texture that produces garbage when captured. Skip region scanning for these.
    if frame.IsMicroButton or (frameName and frameName:find("MicroButton")) then
        return nil
    end

    local iconRegions = {"Icon", "icon", "NormalTexture", "normalTexture"}
    for _, regionName in ipairs(iconRegions) do
        local region = frame[regionName]
        if region and region.GetTexture then
            local texture = region:GetTexture()
            if texture then
                return texture
            end
        end
    end

    -- Fallback: iterate through regions
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            if texture and type(texture) == "number" then
                return texture
            end
        end
    end

    return nil
end

local function GetFrameArtworkIcon(frameName)
    local frame = Utils.GetFrameByPath(frameName) or _G[frameName]
    if not (frame and frame.GetRegions) then return nil end

    local fallback
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            local atlas = region.GetAtlas and region:GetAtlas()
            local layer = region.GetDrawLayer and region:GetDrawLayer()
            if texture and type(texture) == "number" and not atlas and layer == "ARTWORK" then
                local w, h = region:GetSize()
                if w and h and w >= 16 and h >= 16 and w <= 100 and h <= 100 then
                    return texture
                end
                if not fallback then fallback = texture end
            end
        end
    end
    return fallback
end

local function IsMenuBarSpecificIconData(data)
    return data and data.category == "Menu Bar" and data.buttonFrame
end

local function SetButtonFrameIcon(resultRow, frameName, iconSize)
    if frameName == "CharacterMicroButton" then
        UI:SetRowIcon(resultRow, "hidden", nil, iconSize)
        SetPortraitTexture(resultRow.icon, "player")
        resultRow.icon:SetTexCoord(0, 1, 0, 1)
        resultRow.icon:SetSize(iconSize, iconSize)
        resultRow.icon:Show()
        return true
    end

    local texture, isAtlas = GetButtonIcon(frameName)
    if not texture then return false end

    local kind = isAtlas and "atlas" or "file"
    UI:SetRowIcon(resultRow, kind, texture, iconSize)
    return true
end

function UI:ShowHierarchicalResults(hierarchical, preserveScroll)
    if not hierarchical or #hierarchical == 0 then
        self:HideResults()
        return
    end
    if not resultsFrame then return end

    UI._cachedHierarchical = hierarchical

    -- Render-skip: if the input list is identical (same length, same
    -- data refs and same depth at every index) AND the relevant view
    -- state (theme, collapse state, results-above) hasn't
    -- changed since the last render, the visible output would be byte-
    -- for-byte identical. Skip the entire per-row layout pass: this is
    -- the typical case during typing once the top results stabilize.
    do
        -- collapsedNodes is wiped to a fresh empty table on every
        -- search, so identity comparison would always miss during
        -- typing. Snapshot a single key (or nil if empty): a click on
        -- a collapse toggle adds or removes a key, which we'll see.
        local theme = EasyFind.db.resultsTheme
        local above = EasyFind.db.uiResultsAbove
        local collapsedKey = next(collapsedNodes)
        local fontScale = EasyFind.db.fontSize or 1.0
        local searchW = UI:GetSearchFrame() and UI:GetSearchFrame():GetWidth() or 0
        local customResultsW = EasyFind.db.uiResultsWidth or 0
        local maxResultsH = EasyFind.db.uiResultsHeight or 280
        local quickFilterHelp = self._quickFilterSuggestionsActive and 1 or 0
        local n = #hierarchical
        local last = self._lastRenderSig
        local same = last and last.n == n
            and last.theme == theme
            and last.above == above
            and last.collapsedKey == collapsedKey
            and last.fontScale == fontScale
            and last.searchW == searchW
            and last.customResultsW == customResultsW
            and last.maxResultsH == maxResultsH
            and last.quickFilterHelp == quickFilterHelp
            and resultsFrame:IsShown()
        if same then
            for hi = 1, n do
                local e = hierarchical[hi]
                local stride = (hi - 1) * 3
                if last[stride + 1] ~= e.data
                   or last[stride + 2] ~= (e.depth or 0)
                   or last[stride + 3] ~= (e.isPinned and 1 or 0) then
                    same = false
                    break
                end
            end
        end
        if same then
            self._renderSkips = (self._renderSkips or 0) + 1
            return
        end
        self._renderRuns = (self._renderRuns or 0) + 1
        if not last then last = {}; self._lastRenderSig = last end
        last.n = n
        last.theme = theme
        last.above = above
        last.collapsedKey = collapsedKey
        last.fontScale = fontScale
        last.searchW = searchW
        last.customResultsW = customResultsW
        last.maxResultsH = maxResultsH
        last.quickFilterHelp = quickFilterHelp
        for hi = 1, n do
            local e = hierarchical[hi]
            local stride = (hi - 1) * 3
            last[stride + 1] = e.data
            last[stride + 2] = e.depth or 0
            last[stride + 3] = e.isPinned and 1 or 0
        end
        for i = n * 3 + 1, #last do last[i] = nil end
    end

    UI:ClearResultTooltips()

    local theme = UI:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local rowH  = mfloor(theme.rowHeight * fontScale + 0.5)
    if rowH < theme.rowHeight then rowH = theme.rowHeight end
    local flatExtraH = mfloor(16 * fontScale + 0.5)
    if flatExtraH < 16 then flatExtraH = 16 end
    local stackGap = mfloor(2 * fontScale + 0.5)
    if stackGap < 2 then stackGap = 2 end
    local stackHalfGap = stackGap * 0.5
    local indPx = theme.indentPx
    local padT  = mfloor((theme.resultsPadTop or 0) * fontScale + 0.5)
    if padT < theme.resultsPadTop then padT = theme.resultsPadTop end
    local padB = mfloor((theme.resultsPadBot or 0) * fontScale + 0.5)
    if padB < theme.resultsPadBot then padB = theme.resultsPadBot end
    local quickFilterHelpH = 0
    if resultsFrame.quickFilterHelp then
        if self._quickFilterSuggestionsActive then
            quickFilterHelpH = 22
            resultsFrame.quickFilterHelp:SetShown(true)
        else
            resultsFrame.quickFilterHelp:Hide()
        end
    end
    padT = padT + quickFilterHelpH

    -- Scale row icons to match leaf font height so icon top/bottom
    -- align with text top/bottom instead of overflowing the cap line.
    local iconScale = 1.12
    local leafFontObj = _G[theme.leafFont]
    local leafFontPx = 10
    if leafFontObj and leafFontObj.GetFont then
        local _, sz = leafFontObj:GetFont()
        if sz and sz > 0 then leafFontPx = sz end
    end
    local rowIconSize = math.floor(leafFontPx * fontScale * iconScale + 0.5)
    if rowIconSize < 12 then rowIconSize = 12 end
    local maxIconSize = math.floor((theme.iconSize or 16) * fontScale + 0.5)
    if maxIconSize < (theme.iconSize or 16) then maxIconSize = theme.iconSize or 16 end
    if rowIconSize > maxIconSize then rowIconSize = maxIconSize end

    resultsFrame:SetBackdrop(theme.resultsBackdrop)
    if theme.resultsBackdropColor then
        resultsFrame:SetBackdropColor(unpack(theme.resultsBackdropColor))
    end
    if theme.resultsBackdropBorderColor then
        resultsFrame:SetBackdropBorderColor(unpack(theme.resultsBackdropBorderColor))
    end
    -- Rounded search/results use one shared silhouette whether results
    -- open above or below, so the dropdown must match the bar width.
    local roundedDocked = theme.searchBarRounded
    if roundedDocked and UI:GetSearchFrame() then
        resultsFrame:SetWidth(UI:GetSearchFrame():GetWidth())
    else
        local customW = EasyFind.db.uiResultsWidth
        resultsFrame:SetWidth((customW and customW > 1) and customW or theme.resultsWidth)
    end

    if theme.resultsBgAtlas then
        resultsFrame.bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
        resultsFrame.bgAtlasTex:Show()
        resultsFrame:SetClipsChildren(true)
    else
        resultsFrame.bgAtlasTex:Hide()
        resultsFrame:SetClipsChildren(false)
    end

    wipe(SCRATCH.visible)
    local visible = SCRATCH.visible
    local visibleN = 0
    local skipBelowDepth = nil
    local skipPins = false

    for hi = 1, #hierarchical do
        local entry = hierarchical[hi]
        local d = entry.depth or 0

        if skipBelowDepth then
            if d <= skipBelowDepth then
                skipBelowDepth = nil
            end
        end

        if not (skipPins and entry.isPinned) and not skipBelowDepth then
            if skipPins and not entry.isPinned then
                skipPins = false
            end
            visibleN = visibleN + 1
            visible[visibleN] = entry

            if entry.isPathNode then
                local key = entry.name .. "_" .. d
                if collapsedNodes[key] then
                    skipBelowDepth = d
                end
            end
        end
    end

    local pinSlots = 0
    for vi = 1, visibleN do
        local entry = visible[vi]
        if entry.isPinHeader or entry.isPinned then
            pinSlots = pinSlots + 1
        end
    end

    local count = mmin(visibleN, MAX_BUTTON_POOL)
    local bypassSearchRowCap = self._quickFilterSuggestionsActive
    if not bypassSearchRowCap and pinSlots < visibleN then
        count = mmin(count, pinSlots + MAX_SEARCH_RESULT_ROWS)
    end

    local maxVisibleHeight = EasyFind.db.uiResultsHeight or 280
    local scrollInset = 0

    wipe(SCRATCH.isLastChild)
    local isLastChild = SCRATCH.isLastChild
    for i = 1, count do
        local d = visible[i].depth or 0
        if d > 0 then
            local foundSibling = false
            for j = i + 1, count do
                local dj = visible[j].depth or 0
                if dj < d then break end
                if dj == d then foundSibling = true; break end
            end
            isLastChild[i] = not foundSibling
        end
    end

    -- Determine pin separator placement
    local PIN_SEP_HEIGHT = 9  -- 4px gap + 1px line + 4px gap
    local lastPinIndex = 0
    local hasResultsAfterPins = false
    for i = 1, count do
        if visible[i].isPinHeader or visible[i].isPinned then
            lastPinIndex = i
        end
    end
    if lastPinIndex > 0 and lastPinIndex < count then
        hasResultsAfterPins = true
    end

    local yOffset = 0
    local pinEndYOffset = 0
    local showShortcutHints = ShouldShowResultShortcutHints()
    wipe(SCRATCH.catSepYPositions)
    local catSepYPositions = SCRATCH.catSepYPositions
    local hasSideBySideRepBar = false
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = i <= count and UI:EnsureResultButton(i) or UI:GetResultButtons()[i]
        if resultRow and i <= count then
            local entry = visible[i]
            local data = entry.data
            local depth = entry.depth or 0

            -- Pin separator gap: add once at the transition row
            if hasResultsAfterPins and i == lastPinIndex + 1 then
                pinEndYOffset = yOffset
                yOffset = yOffset + PIN_SEP_HEIGHT
            end

            -- Small gap between pinned items (not after pin header)
            if entry.isPinned and i > 1 and visible[i - 1] and not visible[i - 1].isPinHeader then
                yOffset = yOffset + 4
            end

            -- Reposition for theme row height. Flat-list entries are taller
            -- to fit the name + path subtext stack with breathing room above
            -- the name and below the path so neither bleeds into the rep bar.
            local padL = theme.resultsPadLeft or 10
            local entryRowH = entry.isFlat and (rowH + flatExtraH) or rowH
            if data and data.calculatorResult and not entry.isPathNode then
                local calcRowH = mfloor(86 * fontScale + 0.5)
                if calcRowH < 76 then calcRowH = 76 end
                if entryRowH < calcRowH then entryRowH = calcRowH end
            elseif data and data.calculatorLauncher and not entry.isPathNode then
                local actionRowH = mfloor(30 * fontScale + 0.5)
                if actionRowH < 28 then actionRowH = 28 end
                if entryRowH < actionRowH then entryRowH = actionRowH end
            end
            local rowContentTop = yOffset
            resultRow:SetSize(resultsFrame:GetWidth() - padL * 2 - scrollInset, entryRowH)
            resultRow:ClearAllPoints()
            resultRow:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", padL, -yOffset)

            -- Selection visual is now carried by the row's built-in
            -- HighlightTexture (atlas set in CreateResultRow), shared
            -- with mouse hover; no separate selectionHighlight texture.
            if resultRow.UnlockHighlight then resultRow:UnlockHighlight() end

            -- Always hide section-label visuals up front. The section-
            -- header branch below re-shows them when applicable; rows
            -- recycled from a previous section-header role would
            -- otherwise leak the gold rules across normal rows.
            if resultRow.sectionLabelText then
                resultRow.sectionLabelText:Hide()
                resultRow.sectionLabelLeft:Hide()
                resultRow.sectionLabelRight:Hide()
            end
            if resultRow.calcCard then resultRow.calcCard:Hide() end
            if resultRow.calcDivider then resultRow.calcDivider:Hide() end
            if resultRow.calcDividerTop then resultRow.calcDividerTop:Hide() end
            if resultRow.calcDividerBottom then resultRow.calcDividerBottom:Hide() end
            if resultRow.calcArrowText then resultRow.calcArrowText:Hide() end
            if resultRow.calcExpressionHighlight then resultRow.calcExpressionHighlight:Hide() end
            if resultRow.calcResultHighlight then resultRow.calcResultHighlight:Hide() end
            if resultRow.calcExpressionFlash then resultRow.calcExpressionFlash:Hide() end
            if resultRow.calcResultFlash then resultRow.calcResultFlash:Hide() end
            if resultRow.calcExpressionHint then resultRow.calcExpressionHint:Hide() end
            if resultRow.calcResultHint then resultRow.calcResultHint:Hide() end
            if resultRow.calcExpressionButton then resultRow.calcExpressionButton:Hide() end
            if resultRow.calcResultButton then resultRow.calcResultButton:Hide() end
            if resultRow.calcActionBar then resultRow.calcActionBar:Hide() end

            resultRow.data = data
            -- Reset every icon.* tooltip-identifier the OnEnter handler
            -- looks at. Without this, rows recycled from a previous
            -- render leak their old category's tooltip, e.g. a row
            -- that was "Felfire Hawk" (mount) becoming "Bronze Bullion"
            -- (currency) keeps icon.mountID set, so OnEnter shows the
            -- mount tooltip instead. Only the mount/toy/.../bag branch
            -- below resets these per-field; categories like currency,
            -- reputation, achievement, settings never enter that branch
            -- and used to inherit stale state.
            if resultRow.icon then
                resultRow.icon.mountID = nil
                resultRow.icon.toyItemID = nil
                resultRow.icon.petID = nil
                resultRow.icon.spellID = nil
                resultRow.icon.outfitID = nil
                resultRow.icon.heirloomItemID = nil
                resultRow.icon.gearSetID = nil
                resultRow.icon.bagItemID = nil
                resultRow.icon.achievementID = nil
                resultRow.icon.lootItemID = nil
            end
            -- Secure action attributes. Cache the (type, value) we last
            -- applied to this row so we only re-issue SetAttribute when
            -- the row's data actually changed. SetAttribute on a secure
            -- button is the single most expensive thing we do per row,
            -- and incremental narrowing keeps the same row.data on most
            -- rows from one keystroke to the next, so most renders end
            -- up no-ops here.
            if not InCombatLockdown() then
                local newType, newKey, newVal
                if data and data.toyItemID and not data.isToyboxOnly then
                    -- Unusable toys (faction-restricted etc.) skip the
                    -- secure use type so PostClick can route them to the
                    -- ToyBox instead of silently no-op'ing on click.
                    newType, newKey, newVal = "toy", "toy", data.toyItemID
                elseif data and data.mountID then
                    newType, newKey, newVal = "macro", "macrotext", "/cancelform [form]"
                elseif data and data.outfitID then
                    newType, newKey, newVal = "action", "action", 0
                elseif data and data.spellID and data.category ~= "Talent"
                       and not UI:IsSpellbookOnlyAbility(data) then
                    -- Talents share the spellID field but should never cast
                    -- on click -- the click navigates to the talents tree
                    -- and highlights the node. Skip the secure cast type so
                    -- only PostClick / SelectResult handle the talent path.
                    newType, newKey, newVal = "spell", "spell", data.spellName or data.spellID
                elseif data and data.itemID and data.category == "Bag"
                       and UI:GetBagItemActionKind(data) ~= "show" then
                    newType, newKey, newVal = "item", "item", data.name
                elseif data and data.macroIndex and data.category == "Macro"
                       and data.macroBody and data.macroBody ~= "" then
                    newType, newKey, newVal = "macro", "macrotext", data.macroBody
                elseif data and data.slashCommand then
                    newType, newKey, newVal = "macro", "macrotext", data.slashCommand
                end
                if resultRow._lastAttrType ~= newType
                   or resultRow._lastAttrKey ~= newKey
                   or resultRow._lastAttrVal ~= newVal then
                    -- Strip the previously-set value (if any) before
                    -- applying the new one so stale attributes from the
                    -- prior data don't leak through.
                    if resultRow._lastAttrKey then
                        resultRow:SetAttribute(resultRow._lastAttrKey, nil)
                    end
                    resultRow:SetAttribute("type", newType)
                    if newKey then
                        resultRow:SetAttribute(newKey, newVal)
                    end
                    resultRow._lastAttrType = newType
                    resultRow._lastAttrKey  = newKey
                    resultRow._lastAttrVal  = newVal
                end
            end
            resultRow.isPathNode = entry.isPathNode
            resultRow.isSectionHeader = entry.isSectionHeader or false
            resultRow.isPinHeader = entry.isPinHeader or false
            resultRow.isPinned = entry.isPinned or false
            resultRow.pathNodeName = entry.isPathNode and entry.name or nil
            resultRow.pathNodeDepth = entry.isPathNode and depth or nil
            if resultRow.pinIcon then resultRow.pinIcon:Hide() end
            if resultRow.pinToggle then resultRow.pinToggle:Hide() end
            if resultRow.pinHeaderLine then resultRow.pinHeaderLine:Hide() end
            resultRow._efShortcutIndex = nil
            resultRow._efShortcutBindingReady = nil
            resultRow._efContentTop = rowContentTop
            resultRow._efContentBottom = rowContentTop + entryRowH
            if resultRow.shortcutNumberText then resultRow.shortcutNumberText:SetText("") end
            if resultRow.shortcutGroup then resultRow.shortcutGroup:Hide() end
            RestoreResultShortcutGutter(resultRow)

            for d = 1, MAX_DEPTH do
                resultRow.treeVert[d]:Hide()
                resultRow.treeElbow[d]:Hide()
                resultRow.treeBranch[d]:Hide()
            end

            if theme.showTreeLines and depth > 0 then
                local halfRow = rowH * 0.5
                local lineColor = theme.indentColors[depth] or theme.indentColors[1] or INDENT_COLORS[depth]
                local xCenter = (depth - 1) * INDENT_PX + LINE_X_OFF

                resultRow.treeElbow[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                resultRow.treeElbow[depth]:ClearAllPoints()
                resultRow.treeElbow[depth]:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
                resultRow.treeElbow[depth]:SetHeight(halfRow + 2)
                resultRow.treeElbow[depth]:Show()

                resultRow.treeBranch[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                resultRow.treeBranch[depth]:ClearAllPoints()
                resultRow.treeBranch[depth]:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -halfRow)
                resultRow.treeBranch[depth]:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -halfRow)
                resultRow.treeBranch[depth]:Show()

                if not isLastChild[i] then
                    resultRow.treeVert[depth]:SetColorTexture(lineColor[1], lineColor[2], lineColor[3], 1)
                    resultRow.treeVert[depth]:ClearAllPoints()
                    resultRow.treeVert[depth]:SetPoint("TOP",    resultRow, "TOPLEFT",    xCenter, 3)
                    resultRow.treeVert[depth]:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", xCenter, -1)
                    resultRow.treeVert[depth]:Show()
                end

                for d = 1, depth - 1 do
                    local stillActive = false
                    for j = i + 1, count do
                        local siblingDepth = visible[j].depth or 0
                        if siblingDepth < d then break end
                        if siblingDepth == d then stillActive = true; break end
                    end
                    if stillActive then
                        local ancestorColor = theme.indentColors[d] or theme.indentColors[1] or INDENT_COLORS[d]
                        local ancestorX = (d - 1) * INDENT_PX + LINE_X_OFF
                        resultRow.treeVert[d]:SetColorTexture(ancestorColor[1], ancestorColor[2], ancestorColor[3], 1)
                        resultRow.treeVert[d]:ClearAllPoints()
                        resultRow.treeVert[d]:SetPoint("TOP",    resultRow, "TOPLEFT",    ancestorX, 3)
                        resultRow.treeVert[d]:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", ancestorX, -1)
                        resultRow.treeVert[d]:Show()
                    end
                end
            end

            resultRow._isMatch = entry.isMatch and entry.isPathNode
            if entry.isPinHeader then
                -- Pin header: plain text + toggle icon + underline (no tab/gradient)
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                resultRow.pinToggle:SetAtlas(collapseAtlas)
                resultRow.pinToggle:Show()
                resultRow.pinHeaderLine:Show()
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", 2, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.pinToggle, "LEFT", -4, 0)
                UI:SetScaledFont(resultRow.text, theme.pathFont)
                resultRow.text:SetTextColor(0.7, 0.7, 0.7, 1.0)
                SetClippedText(resultRow.text, entry.name)
            elseif entry.isSectionHeader then
                -- Lightweight inline section label: centered text
                -- between two faint horizontal rules. Used for
                -- category dividers (UI / Mounts / Toys / Map / ...)
                -- so they cost less vertical space than a full
                -- parent-tab header and don't waste a parent indent.
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
                resultRow.text:SetText("")
                resultRow.sectionLabelText:SetText(entry.name)
                resultRow.sectionLabelText:Show()
                resultRow.sectionLabelLeft:ClearAllPoints()
                resultRow.sectionLabelLeft:SetPoint("LEFT", resultRow, "LEFT", 6, 0)
                resultRow.sectionLabelLeft:SetPoint("RIGHT", resultRow.sectionLabelText, "LEFT", -6, 0)
                resultRow.sectionLabelLeft:Show()
                resultRow.sectionLabelRight:ClearAllPoints()
                resultRow.sectionLabelRight:SetPoint("LEFT", resultRow.sectionLabelText, "RIGHT", 6, 0)
                resultRow.sectionLabelRight:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                resultRow.sectionLabelRight:Show()
            elseif theme.showHeaderTab and entry.isPathNode and resultRow.headerTab then
                local tabInset = depth * indPx
                resultRow.headerTab:ClearAllPoints()
                resultRow.headerTab:SetPoint("TOPLEFT", resultRow, "TOPLEFT", tabInset, 0)
                resultRow.headerTab:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", 0, 0)
                resultRow.headerTab:Show()
                -- Set +/- atlas and header name on the tab
                local key = entry.name .. "_" .. depth
                local isCollapsed = collapsedNodes[key]
                local expandAtlas = theme.expandAtlas or "QuestLog-icon-expand"
                local collapseAtlas = theme.collapseAtlas or "QuestLog-icon-shrink"
                local toggleAtlas = isCollapsed and expandAtlas or collapseAtlas
                resultRow.toggleIcon:SetAtlas(toggleAtlas)
                resultRow.tabText:ClearAllPoints()
                resultRow.tabText:SetPoint("LEFT", resultRow.headerTab, "LEFT", 10, 0)
                resultRow.tabText:SetPoint("RIGHT", resultRow.toggleBtn, "LEFT", -4, 0)
                resultRow.tabText:SetText(entry.name)
                -- Matched path nodes get gold text; non-matches stay muted gray
                if resultRow._isMatch then
                    resultRow.tabText:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)   -- gold
                else
                    resultRow.tabText:SetTextColor(0.60, 0.58, 0.55, 1.0) -- muted gray
                end
                -- Normal icon/text hidden - UI:SetRowIcon("hidden") handles icon below
                resultRow.text:SetText("")
                if resultRow.headerGrad then resultRow.headerGrad:Hide() end
            else
                if resultRow.headerTab then resultRow.headerTab:Hide() end
                -- Gradient header (Classic fallback)
                local showGrad = theme.showHeaderBar and entry.isPathNode
                if showGrad and resultRow.headerGrad then
                    resultRow.headerGrad:SetAllPoints()
                    local gradAlpha = mmax(0.25, 0.6 - depth * 0.1)
                    resultRow.headerGrad:SetVertexColor(0.35, 0.27, 0.08, gradAlpha)
                end
                if resultRow.headerGrad then resultRow.headerGrad:SetShown(showGrad) end
            end

            -- Separator line between rows (skip for pin header which has its own underline)
            -- Separator is anchored at BOTTOM of the row (line below this row).
            if not entry.isPinHeader and theme.showSeparators then
                local sc = theme.separatorColor
                resultRow.separator:SetColorTexture(sc[1], sc[2], sc[3], sc[4])
                resultRow.separator:Show()
            else
                resultRow.separator:Hide()
            end

            -- Check if this is a currency that hasn't been discovered yet
            -- (not just quantity == 0, but truly never earned/discovered)
            -- Runs for ALL currency nodes regardless of theme
            local isUnearnedCurrency = false
            if data and data.category == "Currency" then
                if entry.isPathNode then
                    -- For parent currency nodes, check if ALL children are unearned
                    -- Look ahead in the visible list to find children
                    local hasAnyEarnedChild = false
                    local hasAnyChild = false
                    for j = i + 1, count do
                        local childEntry = visible[j]
                        local childDepth = childEntry.depth or 0
                        -- Stop when we leave this parent's subtree
                        if childDepth <= depth then
                            break
                        end
                        -- Only check immediate children at depth + 1
                        if childDepth == depth + 1 and childEntry.data and childEntry.data.steps then
                            hasAnyChild = true
                            for _, step in ipairs(childEntry.data.steps) do
                                if step.currencyID then
                                    local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(step.currencyID)
                                    if currencyInfo and (currencyInfo.quantity > 0 or
                                        (currencyInfo.totalEarned and currencyInfo.totalEarned > 0) or
                                        currencyInfo.useTotalEarnedForMaxQty or
                                        currencyInfo.discovered == true) then
                                        hasAnyEarnedChild = true
                                        break
                                    end
                                end
                            end
                            if hasAnyEarnedChild then break end
                        end
                    end
                    -- If we found children but NONE are earned, mark parent as unearned
                    if hasAnyChild and not hasAnyEarnedChild then
                        isUnearnedCurrency = true
                    end
                elseif data.steps then
                    -- For leaf currency nodes, check the currency itself
                    for _, step in ipairs(data.steps) do
                        if step.currencyID then
                            local currencyInfo = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(step.currencyID)
                            if currencyInfo and currencyInfo.quantity == 0 then
                                -- Only mark as unearned if it's never been discovered
                                local isDiscovered = (currencyInfo.totalEarned and currencyInfo.totalEarned > 0) or
                                                     (currencyInfo.useTotalEarnedForMaxQty) or
                                                     (currencyInfo.discovered == true)
                                if not isDiscovered then
                                    isUnearnedCurrency = true
                                end
                            end
                            break
                        end
                    end
                end
            end
            resultRow.isUnearnedCurrency = isUnearnedCurrency
            resultRow.isPathNode = entry.isPathNode  -- Store for tooltip text

            if not entry.isPinHeader and not entry.isSectionHeader and not (theme.showHeaderTab and entry.isPathNode) then
                local indentPixels = depth * indPx
                resultRow.icon:ClearAllPoints()

                if entry.isFlat then
                    -- Flat-list layout (Alfred-style):
                    --   icon left (vertically centered), name + path stack to its right.
                    -- pathSubtext has SetWordWrap(false) so long paths truncate
                    -- horizontally rather than wrapping into the next row.
                    -- For collection rows (mounts/toys/etc.) the main icon is
                    -- pushed to the RIGHT later in the loop to display the
                    -- mount/toy/pet/etc. portrait. We show flatCatIcon (the
                    -- filter-menu category icon) on the LEFT so the row still
                    -- has a visual anchor next to the name+path stack.
                    local catIconDef = UI:GetFlatCategoryIcon(data)
                    local leftAnchor
                    if not catIconDef and data and (data.specificIcon or data.specificIconFrame)
                       and data.buttonFrame then
                        catIconDef = { buttonFrame = data.buttonFrame }
                    end
                    if catIconDef then
                        local sz = entryRowH - 16
                        if catIconDef.buttonFrame then
                            local texture, isAtlas = GetButtonIcon(catIconDef.buttonFrame)
                            if isAtlas then
                                resultRow.flatCatIcon:SetAtlas(texture)
                                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                            elseif texture then
                                resultRow.flatCatIcon:SetTexture(texture)
                                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                            else
                                resultRow.flatCatIcon:SetTexture(134400)
                                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                            end
                        elseif catIconDef.atlas then
                            resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
                            resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                        else
                            resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                            if catIconDef.coords then
                                resultRow.flatCatIcon:SetTexCoord(unpack(catIconDef.coords))
                            else
                                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                            end
                        end
                        if catIconDef.color then
                            resultRow.flatCatIcon:SetVertexColor(unpack(catIconDef.color))
                        else
                            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
                        end
                        resultRow.flatCatIcon:SetSize(sz, sz)
                        resultRow.flatCatIcon:ClearAllPoints()
                        resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels + 2, 0)
                        resultRow.flatCatIcon:Show()
                        leftAnchor = resultRow.flatCatIcon
                    else
                        resultRow.flatCatIcon:Hide()
                        resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels + 2, 0)
                        leftAnchor = resultRow.icon
                    end

                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("BOTTOMLEFT", leftAnchor, "RIGHT", 6, stackHalfGap)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    UI:SetScaledFont(resultRow.text, theme.pathFont)
                    if isUnearnedCurrency then
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        resultRow.text:SetTextColor(1.0, 1.0, 1.0, 1.0)
                    end
                    SetClippedText(resultRow.text, entry.name)

                    resultRow.pathSubtext:ClearAllPoints()
                    resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -stackGap)
                    resultRow.pathSubtext:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                    resultRow.pathSubtext:SetText(UI:GetFlatSubtext(data))
                    UI:SetScaledFont(resultRow.pathSubtext, theme.leafFont)
                    resultRow.pathSubtext:SetTextColor(0.55, 0.55, 0.55, 1.0)
                    resultRow.pathSubtext:Show()
                else
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end

                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                    resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)

                    if resultRow.pathSubtext then
                        resultRow.pathSubtext:Hide()
                    end

                    -- Style: path nodes vs leaf results, themed
                    if entry.isPathNode then
                        UI:SetScaledFont(resultRow.text, theme.pathFont)
                        if entry.isMatch then
                            resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                        else
                            resultRow.text:SetTextColor(unpack(theme.pathColor))
                        end
                    elseif isUnearnedCurrency then
                        -- Gray out unearned currencies
                        UI:SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    elseif entry.isMatch then
                        UI:SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0) -- gold for matches
                    else
                        UI:SetScaledFont(resultRow.text, theme.leafFont)
                        resultRow.text:SetTextColor(unpack(theme.leafColor))
                    end
                    SetClippedText(resultRow.text, entry.name)
                end
            else
                if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
                if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
            end

            local iconSet = false
            -- Clear leftover cooldown sweep from prior render. Only the
            -- toy/ability/outfit branch re-enables it; every other branch
            -- (map results, currencies, settings, etc.) leaves it alone, so
            -- without this clear a recycled row keeps the previous sweep.
            if resultRow.iconCooldown then resultRow.iconCooldown:Hide() end
            local isCurrencyItem = data and data.category == "Currency"
            local isCurrencyLeaf = isCurrencyItem and not entry.isPathNode
            local isReputationLeaf = data and data.category == "Reputation" and not entry.isPathNode

            if entry.isSectionHeader then
                -- Section dividers: no icon, no main text. The
                -- centered sectionLabelText handles the visual.
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                resultRow.amountText:Hide()
                if resultRow.repBar then resultRow.repBar:Hide() end
                iconSet = true

            elseif entry.isPinHeader then
                -- Pin header: no row icon (toggle is handled by pinToggle)
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                iconSet = true

            elseif theme.showHeaderTab and entry.isPathNode then
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                iconSet = true

            elseif entry.isPathNode then
                local key = entry.name .. "_" .. depth
                local nodeCollapsed = collapsedNodes[key]
                local iconPath = nodeCollapsed and theme.expandIcon or theme.collapseIcon
                UI:SetRowIcon(resultRow, "path", iconPath, theme.pathIconSize)
                iconSet = true
            end

            -- Resolve currency icon on the fly if not cached
            if not iconSet and isCurrencyItem and data and not data.icon and data.steps then
                for si = #data.steps, 1, -1 do
                    local cid = data.steps[si].currencyID
                    if cid then
                        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                            local ok, ci = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
                            if ok and ci and ci.iconFileID and ci.iconFileID ~= 0 then
                                data.icon = ci.iconFileID
                            end
                        end
                        break
                    end
                end
            end

            -- Currency leaves: icon goes right of amount, not left of name
            if isCurrencyLeaf and data and data.steps then
                local quantity, iconFileID
                for si = #data.steps, 1, -1 do
                    local cid = data.steps[si].currencyID
                    if cid and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                        local ok, ci = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
                        if ok and ci then
                            quantity = ci.quantity
                            iconFileID = data.icon or (ci.iconFileID ~= 0 and ci.iconFileID) or nil
                        end
                        break
                    end
                end

                if quantity then
                    resultRow.amountText:SetText(tostring(quantity))
                    if isUnearnedCurrency then
                        resultRow.amountText:SetTextColor(0.5, 0.5, 0.5, 1.0)
                    else
                        resultRow.amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
                    end
                    resultRow.amountText:Show()
                else
                    resultRow.amountText:Hide()
                end

                -- Move icon to right side (right of amount text)
                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                    resultRow.amountText:ClearAllPoints()
                    resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end

                -- Show unified currency category icon on the LEFT (matches map AH glyph).
                -- indentPixels matches the non-currency leaf calculation so the
                -- currency icon lines up horizontally with normal row icons.
                local indentPixels = depth * indPx
                local leftAnchor
                local catIconDef = UI:GetFlatCategoryIcon({ category = "Currency" })
                if catIconDef and resultRow.flatCatIcon then
                    local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
                    if catIconDef.atlas then
                        resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
                    else
                        resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                    end
                    resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
                    resultRow.flatCatIcon:SetSize(sz, sz)
                    resultRow.flatCatIcon:ClearAllPoints()
                    resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.flatCatIcon:Show()
                    leftAnchor = resultRow.flatCatIcon
                end

                resultRow.text:ClearAllPoints()
                if leftAnchor then
                    resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
                else
                    resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                end
                resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                -- Re-clip now that amountText (and therefore text's right
                -- boundary) has its final position for this row. The earlier
                -- SetClippedText ran against the previous row's amountText
                -- width, which truncated some currencies unnecessarily.
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            -- Statistic rows: show the live stat value inline via amountText.
            -- GetStatistic returns a string ("394", "23%", "1d 4h 12m") or
            -- "--" for stats with no recorded value yet.
            elseif data and data.statisticID and not entry.isPathNode then
                local value
                if GetStatistic then
                    local ok, v = pcall(GetStatistic, data.statisticID)
                    if ok then value = v end
                end
                if value and value ~= "" and value ~= "--" then
                    resultRow.amountText:SetText(value)
                    resultRow.amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
                else
                    resultRow.amountText:SetText("--")
                    resultRow.amountText:SetTextColor(0.5, 0.5, 0.5, 1.0)
                end
                resultRow.amountText:ClearAllPoints()
                resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                resultRow.amountText:Show()
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)

                local indentPixels = depth * indPx
                local leftAnchor
                local catIconDef = UI:GetFlatCategoryIcon({ category = "Statistic" })
                if catIconDef and resultRow.flatCatIcon then
                    local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
                    resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                    if catIconDef.coords then
                        resultRow.flatCatIcon:SetTexCoord(catIconDef.coords[1], catIconDef.coords[2],
                                                          catIconDef.coords[3], catIconDef.coords[4])
                    else
                        resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                    end
                    resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
                    resultRow.flatCatIcon:SetSize(sz, sz)
                    resultRow.flatCatIcon:ClearAllPoints()
                    resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.flatCatIcon:Show()
                    leftAnchor = resultRow.flatCatIcon
                end
                resultRow.text:ClearAllPoints()
                if leftAnchor then
                    resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
                else
                    resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                end
                resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            -- Calculator rows use a Raycast-style result card instead of the
            -- normal two-line flat row.
            elseif data and data.calculatorResult and not entry.isPathNode then
                resultRow.text:SetText("")
                resultRow.amountText:Hide()
                if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
                if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)

                local actionH = mmax(20, mfloor(22 * fontScale + 0.5))
                resultRow.calcActionBar:ClearAllPoints()
                resultRow.calcActionBar:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 4, 3)
                resultRow.calcActionBar:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 3)
                resultRow.calcActionBar:SetHeight(actionH)
                resultRow.calcActionBar:Show()

                resultRow.calcCard:ClearAllPoints()
                resultRow.calcCard:SetPoint("TOPLEFT", resultRow, "TOPLEFT", 4, -3)
                resultRow.calcCard:SetPoint("BOTTOMRIGHT", resultRow.calcActionBar, "TOPRIGHT", 0, 4)
                resultRow.calcCard:Show()

                resultRow.calcDivider:ClearAllPoints()
                resultRow.calcDivider:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
                resultRow.calcDivider:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
                resultRow.calcDivider:Show()

                resultRow.calcArrowText:ClearAllPoints()
                resultRow.calcArrowText:SetPoint("CENTER", resultRow.calcCard, "CENTER", 0, 0)
                resultRow.calcArrowText:Show()

                resultRow.calcDividerTop:ClearAllPoints()
                resultRow.calcDividerTop:SetPoint("TOP", resultRow.calcCard, "TOP", 0, -1)
                resultRow.calcDividerTop:SetPoint("BOTTOM", resultRow.calcArrowText, "TOP", 0, 3)
                resultRow.calcDividerTop:Show()

                resultRow.calcDividerBottom:ClearAllPoints()
                resultRow.calcDividerBottom:SetPoint("TOP", resultRow.calcArrowText, "BOTTOM", 0, -3)
                resultRow.calcDividerBottom:SetPoint("BOTTOM", resultRow.calcCard, "BOTTOM", 0, 1)
                resultRow.calcDividerBottom:Show()

                resultRow.calcExpressionText:ClearAllPoints()
                resultRow.calcExpressionText:SetPoint("LEFT", resultRow.calcCard, "LEFT", 12, 0)
                resultRow.calcExpressionText:SetPoint("RIGHT", resultRow.calcDivider, "LEFT", -22, 0)
                SetClippedText(resultRow.calcExpressionText, data.calculatorExpression or data.name or "")
                resultRow.calcExpressionHighlight:ClearAllPoints()
                resultRow.calcExpressionHighlight:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
                resultRow.calcExpressionHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
                resultRow.calcExpressionFlash:ClearAllPoints()
                resultRow.calcExpressionFlash:SetPoint("TOPLEFT", resultRow.calcExpressionHighlight, "TOPLEFT")
                resultRow.calcExpressionFlash:SetPoint("BOTTOMRIGHT", resultRow.calcExpressionHighlight, "BOTTOMRIGHT")

                resultRow.calcResultText:ClearAllPoints()
                resultRow.calcResultText:SetPoint("LEFT", resultRow.calcDivider, "RIGHT", 22, 0)
                resultRow.calcResultText:SetPoint("RIGHT", resultRow.calcCard, "RIGHT", -12, 0)
                SetClippedText(resultRow.calcResultText, data.calculatorResult)
                resultRow.calcResultHighlight:ClearAllPoints()
                resultRow.calcResultHighlight:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
                resultRow.calcResultHighlight:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
                resultRow.calcResultFlash:ClearAllPoints()
                resultRow.calcResultFlash:SetPoint("TOPLEFT", resultRow.calcResultHighlight, "TOPLEFT")
                resultRow.calcResultFlash:SetPoint("BOTTOMRIGHT", resultRow.calcResultHighlight, "BOTTOMRIGHT")
                resultRow.calcExpressionButton:ClearAllPoints()
                resultRow.calcExpressionButton:SetPoint("TOPLEFT", resultRow.calcCard, "TOPLEFT", 1, 0)
                resultRow.calcExpressionButton:SetPoint("BOTTOMRIGHT", resultRow.calcDivider, "BOTTOMLEFT", -1, 1)
                resultRow.calcExpressionButton:Show()

                resultRow.calcResultButton:ClearAllPoints()
                resultRow.calcResultButton:SetPoint("TOPLEFT", resultRow.calcDivider, "TOPRIGHT", 1, 0)
                resultRow.calcResultButton:SetPoint("BOTTOMRIGHT", resultRow.calcCard, "BOTTOMRIGHT", -1, 1)
                resultRow.calcResultButton:Show()

                self:SetCalculatorCopyHighlight(resultRow, UI._calculator.activeData == data and UI._calculator.activePart or nil)

                iconSet = true

            elseif data and data.calculatorLauncher and not entry.isPathNode then
                resultRow.text:SetText("")
                resultRow.amountText:Hide()
                if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
                if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
                UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)

                resultRow.calcActionBar:ClearAllPoints()
                resultRow.calcActionBar:SetPoint("TOPLEFT", resultRow, "TOPLEFT", 4, -3)
                resultRow.calcActionBar:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 3)
                resultRow.calcActionBar:Show()

                iconSet = true

            -- Entry-specific leaf icons: keep the category icon on the
            -- left in flat mode, and put the specific item/spell/achievement
            -- art on the right.
            elseif not iconSet and data and (data.specificIcon or data.specificIconFrame) then
                local specificIcon = data.specificIcon
                if not specificIcon and data.specificIconFrame then
                    specificIcon = GetFrameArtworkIcon(data.specificIconFrame)
                end
                if specificIcon then
                    UI:SetRowIcon(resultRow, "file", specificIcon, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.amountText:Hide()
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
                if specificIcon then
                    resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                else
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            elseif not iconSet and IsMenuBarSpecificIconData(data) then
                local hasSpecificIcon = SetButtonFrameIcon(resultRow, data.buttonFrame, rowIconSize)
                if hasSpecificIcon then
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.amountText:Hide()
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
                if hasSpecificIcon then
                    resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                else
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            elseif not iconSet and data and (data.mountID or data.toyItemID or data.petID or data.outfitID or data.heirloomItemID or data.gearSetID or data.transmogSetID or (data.spellID and data.category == "Ability") or (data.spellID and data.category == "Talent") or (data.encounterID and data.category == "Boss") or (data.macroIndex and data.category == "Macro") or (data.bagID and data.category == "Bag") or (data.achievementID and data.category == "Achievement")) then
                local iconFileID = data.icon
                local rightOffset = -5

                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    if IsBossResultData(data) then
                        resultRow.icon:SetTexCoord(unpack(BOSS_PORTRAIT_TEXCOORD))
                    end
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                    resultRow.icon:Show()
                    resultRow.icon.mountID = data.mountID
                    resultRow.icon.toyItemID = data.toyItemID
                    resultRow.icon.petID = data.petID
                    resultRow.icon.spellID = data.spellID
                    resultRow.icon.outfitID = data.outfitID
                    resultRow.icon.heirloomItemID = data.heirloomItemID
                    resultRow.icon.gearSetID = data.gearSetID
                    resultRow.icon.bagItemID = (data.category == "Bag") and data.itemID or nil
                    resultRow.icon.achievementID = data.achievementID
                    resultRow.icon.lootItemID = nil
                    -- Red tint on mount icons when in combat (can't mount)
                    if data.mountID and InCombatLockdown() then
                        resultRow.icon:SetVertexColor(1, 0.3, 0.3, 1)
                    elseif data.outfitID then
                        local activeID = select(3, UI:GetOutfitCooldownState())
                        activeID = activeID or (C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                            and C_TransmogOutfitInfo.GetActiveOutfitID())
                        if activeID and activeID == data.outfitID then
                            resultRow.icon:SetVertexColor(0.3, 1, 0.3, 1)
                        else
                            resultRow.icon:SetVertexColor(1, 1, 1, 1)
                        end
                    -- Talents: desaturate the per-talent icon if not in
                    -- the player's current allocation. Allocated talents
                    -- (chosen choice option, or non-zero rank on regular
                    -- nodes) render full color.
                    elseif data.category == "Talent" then
                        if data.talentIsAllocated then
                            resultRow.icon:SetVertexColor(1, 1, 1, 1)
                        else
                            resultRow.icon:SetVertexColor(0.4, 0.4, 0.4, 1)
                        end
                    else
                        resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    end
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end

                -- Outfit lock overlay (dashed border when locked)
                if data.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
                    UI:UpdateOutfitLockOverlay(resultRow, C_TransmogOutfitInfo.IsLockedOutfit(data.outfitID))
                elseif resultRow._lockOverlay then
                    resultRow._lockOverlay:Hide()
                end

                -- Cooldown sweep overlay (toys, abilities, outfits)
                resultRow.amountText:Hide()
                if data.toyItemID and iconFileID and GetItemCooldown then
                    local startTime, duration = GetItemCooldown(data.toyItemID)
                    if startTime and duration and duration > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(startTime, duration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                elseif data.spellID and data.category == "Ability" and iconFileID and C_Spell and C_Spell.GetSpellCooldown then
                    local cd = C_Spell.GetSpellCooldown(data.spellID)
                    if cd and cd.startTime and cd.duration and cd.duration > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(cd.startTime, cd.duration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                elseif data.outfitID and UI:IsOutfitCooldownActive() then
                    local outfitCdStart, outfitCdDuration = UI:GetOutfitCooldownState()
                    local remaining = outfitCdDuration - (GetTime() - outfitCdStart)
                    if remaining > 0 then
                        resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                        resultRow.iconCooldown:SetCooldown(outfitCdStart, outfitCdDuration)
                        resultRow.iconCooldown:Show()
                    else
                        resultRow.iconCooldown:Hide()
                    end
                else
                    resultRow.iconCooldown:Hide()
                end

                local indentPixels = depth * indPx + 4
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                -- Re-clip against the new RIGHT bound (icon:LEFT) -- the
                -- path branch's earlier SetClippedText ran against
                -- amountText:LEFT from the previous row.
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            -- Loot items: icon on right with source name inline
            elseif not iconSet and data and data.itemID and data.category == "Loot" then
                local iconFileID = data.icon
                if iconFileID then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetTexture(iconFileID)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                    resultRow.icon.lootItemID = data.itemID
                    resultRow.icon.mountID = nil
                    resultRow.icon.toyItemID = nil
                    resultRow.icon.petID = nil
                    resultRow.icon.spellID = nil
                    resultRow.icon.outfitID = nil
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.amountText:Hide()
                resultRow.iconCooldown:Hide()
                if data.lootSourceName then
                    resultRow.text:SetText(data.name .. "  |cff888888" .. data.lootSourceName .. "|r")
                end
                local indentPixels = depth * indPx + 4
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                iconSet = true

            -- Map search results: per-POI icon (flightmaster, bank, dungeon
            -- entrance, etc.) on the RIGHT. The LEFT generic-map glyph is
            -- already handled by the flat-mode block above via GetFlatCategoryIcon
            -- (which returns FLAT_CATEGORY_ICONS.map for mapSearchResult rows).
            elseif not iconSet and data and data.mapSearchResult then
                resultRow.amountText:Hide()
                local mapIcon = data.icon
                if mapIcon then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    if type(mapIcon) == "table" then
                        resultRow.icon:SetTexture(mapIcon.file)
                        local c = mapIcon.coords
                        resultRow.icon:SetTexCoord(c[1], c[2], c[3], c[4])
                    elseif type(mapIcon) == "string" and sfind(mapIcon, "^atlas:") then
                        resultRow.icon:SetAtlas(mapIcon:sub(7))
                    else
                        resultRow.icon:SetTexture(mapIcon)
                    end
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
                    resultRow.icon:Show()
                else
                    UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                end
                resultRow.text:ClearAllPoints()
                resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
                if mapIcon then
                    resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
                else
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                end
                SetClippedText(resultRow.text, entry.name)
                iconSet = true

            -- Reputation leaves: faction-side crest on the LEFT, rep bar on
            -- the right (rendered later in the showRepBar block).
            elseif not iconSet and isReputationLeaf and data and data.factionID then
                local repIcon = UI:GetRepFactionIcon(data.factionSide or "either")
                if repIcon then
                    resultRow.icon:SetTexture(nil)
                    resultRow.icon:SetTexture(repIcon.tex)
                    if repIcon.coords then
                        local c = repIcon.coords
                        resultRow.icon:SetTexCoord(c[1], c[2], c[3], c[4])
                    else
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                    end
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                    resultRow.icon:SetSize(rowIconSize, rowIconSize)
                    resultRow.icon:ClearAllPoints()
                    local indentPixels = depth * indPx + 4
                    resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                    resultRow.icon:Show()
                    resultRow.text:ClearAllPoints()
                    resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                end
                resultRow.amountText:Hide()
                resultRow.amountText:ClearAllPoints()
                resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                iconSet = true

            else
                resultRow.amountText:Hide()
                resultRow.amountText:ClearAllPoints()
                resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
            end

            -- Reputation bar: show on leaves and on path nodes with actual rep bars
            -- (hasRepBar is false for pure grouping headers like Horde, Alliance)
            local showRepBar = data and data.factionID and
                (isReputationLeaf or (entry.isPathNode and data.category == "Reputation" and data.hasRepBar ~= false))
            if showRepBar then
                local fill, standingText, barR, barG, barB
                local fid = data.factionID

                -- Priority 1: Renown factions (TWW, Dragonflight, Shadowlands)
                if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                    local ok, md = pcall(C_MajorFactions.GetMajorFactionData, fid)
                    if ok and md and md.renownLevel then
                        local level = md.renownLevel or 0
                        standingText = "Renown " .. level
                        local atMax = C_MajorFactions.HasMaximumRenown
                            and C_MajorFactions.HasMaximumRenown(fid)
                        if atMax then
                            fill = 1.0
                        else
                            local earned = md.renownReputationEarned or 0
                            local threshold = md.renownLevelThreshold or 1
                            fill = (threshold > 0) and (earned / threshold) or 1.0
                        end
                        barR, barG, barB = 0.0, 0.55, 0.78
                    end
                end

                -- Priority 2: Friendship factions (Sabellian, Wrathion, etc.)
                if not standingText and C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
                    local ok, fd = pcall(C_GossipInfo.GetFriendshipReputation, fid)
                    if ok and fd and fd.friendshipFactionID and fd.friendshipFactionID > 0 then
                        standingText = fd.reaction or ""
                        local cur = fd.standing or 0
                        local minR = fd.reactionThreshold or 0
                        local maxR = fd.nextThreshold or 0
                        if maxR > minR then
                            fill = (cur - minR) / (maxR - minR)
                        elseif cur > 0 then
                            fill = 1.0
                        else
                            fill = 0.0
                        end
                        barR, barG, barB = 0.0, 0.60, 0.0
                    end
                end

                -- Priority 3: Traditional factions (Friendly, Honored, etc.)
                if not standingText and C_Reputation and C_Reputation.GetFactionDataByID then
                    local ok, rd = pcall(C_Reputation.GetFactionDataByID, fid)
                    if ok and rd and rd.reaction then
                        local standing = rd.reaction
                        standingText = _G["FACTION_STANDING_LABEL" .. standing] or ""
                        local cur  = rd.currentStanding or 0
                        local minR = rd.currentReactionThreshold or 0
                        local maxR = rd.nextReactionThreshold or 0
                        if maxR > minR then
                            fill = (cur - minR) / (maxR - minR)
                        else
                            fill = 1.0
                        end
                        local barColor = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing]
                        if barColor then
                            barR, barG, barB = barColor.r, barColor.g, barColor.b
                        else
                            barR, barG, barB = 0.5, 0.5, 0.5
                        end
                    end
                end

                if standingText then
                    if fill < 0 then fill = 0 end
                    if fill > 1 then fill = 1 end
                    resultRow.repBarTex:SetVertexColor(barR, barG, barB, 1.0)
                    if resultRow.repFill.SetBackdropColor then
                        resultRow.repFill:SetBackdropColor(barR, barG, barB, 1.0)
                    end
                    resultRow.repClip:SetWidth(mmax(fill * REP_BAR_WIDTH, 0.1))
                    resultRow.repBarText:SetText(standingText)

                    if entry.isPathNode and theme.showHeaderTab then
                        -- Tab theme: place rep bar left of the toggle icon
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow.toggleBtn, "LEFT", -4, 0)
                        resultRow.tabText:ClearAllPoints()
                        resultRow.tabText:SetPoint("LEFT", resultRow.headerTab, "LEFT", 10, 0)
                        resultRow.tabText:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                    elseif entry.isPathNode then
                        -- Side-by-side by default; IsTruncated() reflects the previous frame's
                        -- layout, which is accurate for stable results. A deferred re-render
                        -- corrects it after first render or scale/width changes.
                        local indentPixels = depth * indPx + 4
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                        resultRow.text:ClearAllPoints()
                        resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
                        resultRow.text:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                        if resultRow.text:IsTruncated() then
                            resultRow.text:ClearAllPoints()
                            resultRow.text:SetPoint("TOPLEFT", resultRow, "TOPLEFT", indentPixels, -3)
                            resultRow.text:SetPoint("TOPRIGHT", resultRow, "TOPRIGHT", -6, -3)
                            resultRow.repBar:ClearAllPoints()
                            resultRow.repBar:SetPoint("BOTTOM", resultRow, "BOTTOM", 0, 5)
                            resultRow:SetHeight(rowH + 25)
                        else
                            hasSideBySideRepBar = true
                        end
                    else
                        -- Leaf: side-by-side by default, stack only if text truncates
                        UI:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
                        local indentPixels = depth * indPx + 4
                        resultRow.repBar:ClearAllPoints()
                        resultRow.repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                        resultRow.text:ClearAllPoints()
                        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
                        resultRow.text:SetPoint("RIGHT", resultRow.repBar, "LEFT", -4, 0)
                        if resultRow.text:IsTruncated() then
                            resultRow.text:ClearAllPoints()
                            resultRow.text:SetPoint("TOPLEFT", resultRow, "TOPLEFT", indentPixels, -3)
                            resultRow.text:SetPoint("TOPRIGHT", resultRow, "TOPRIGHT", -6, -3)
                            resultRow.repBar:ClearAllPoints()
                            resultRow.repBar:SetPoint("BOTTOM", resultRow, "BOTTOM", 0, 5)
                            resultRow:SetHeight(rowH + 25)
                        else
                            hasSideBySideRepBar = true
                        end
                        iconSet = true
                    end
                    resultRow.repBar:Show()
                else
                    resultRow.repBar:Hide()
                end

                if not entry.isPathNode then iconSet = true end
            else
                resultRow.repBar:Hide()
            end

            -- Game Settings: cogwheel atlas in non-flat mode (flat mode
            -- uses flatCatIcon via GetFlatCategoryIcon).
            if not iconSet and data and data.category == "Game Settings" then
                UI:SetRowIcon(resultRow, "atlas", "QuestLog-icon-setting", rowIconSize)
                iconSet = true
            end

            if not iconSet and data and data.iconAtlas then
                UI:SetRowIcon(resultRow, "atlas", data.iconAtlas, rowIconSize)
                iconSet = true
            end

            if not iconSet and data and data.icon then
                UI:SetRowIcon(resultRow, "file", data.icon, rowIconSize)
                iconSet = true
            end

            -- Portrait menu items: use the player portrait as the icon
            if not iconSet and data and data.steps then
                for _, step in ipairs(data.steps) do
                    if step.portraitMenu or step.portraitMenuOption then
                        SetPortraitTexture(resultRow.icon, "player")
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                        resultRow.icon:SetSize(rowIconSize, rowIconSize)
                        resultRow.icon:Show()
                        iconSet = true
                        break
                    end
                end
            end

            -- Resolve sidebar tab icons at runtime (e.g. Equipment Manager, Titles)
            -- The tab textures are sprite sheets - copy the ARTWORK-layer texture
            -- along with its tex coords so only the icon portion is shown.
            if not iconSet and data and data.steps then
                for _, step in ipairs(data.steps) do
                    if step.sidebarIndex then
                        local tab = _G["PaperDollSidebarTab" .. step.sidebarIndex]
                        if tab then
                            for ri = 1, select("#", tab:GetRegions()) do
                                local region = select(ri, tab:GetRegions())
                                if region and region:GetObjectType() == "Texture"
                                   and region:GetDrawLayer() == "ARTWORK" then
                                    local tex = region:GetTexture()
                                    -- Skip render targets (e.g. RTPortrait1 for the player model)
                                    if tex and type(tex) == "string" and tex:find("^RT") then
                                        break
                                    end
                                    if tex then
                                        local ulX, ulY, llX, llY, urX, urY, lrX, lrY = region:GetTexCoord()
                                        resultRow.icon:SetTexture(tex)
                                        resultRow.icon:SetTexCoord(ulX, ulY, llX, llY, urX, urY, lrX, lrY)
                                        resultRow.icon:SetSize(rowIconSize, rowIconSize)
                                        resultRow.icon:Show()
                                        iconSet = true
                                    end
                                    break
                                end
                            end
                            -- Fallback for render target tabs: use player portrait
                            if not iconSet then
                                SetPortraitTexture(resultRow.icon, "player")
                                resultRow.icon:SetTexCoord(0, 1, 0, 1)
                                resultRow.icon:SetSize(rowIconSize, rowIconSize)
                                resultRow.icon:Show()
                                iconSet = true
                            end
                        end
                        break
                    end
                end
            end

            -- Skip buttonFrame fallback for currency items - their inherited
            -- "CharacterMicroButton" produces a wrong MicroMenu atlas icon.
            if not iconSet and not isCurrencyItem and data and data.buttonFrame then
                local texture, isAtlas = GetButtonIcon(data.buttonFrame)
                if texture then
                    local kind = isAtlas and "atlas" or "file"
                    UI:SetRowIcon(resultRow, kind, texture, rowIconSize)
                    iconSet = true
                end
            end

            if not iconSet then
                UI:SetRowIcon(resultRow, "file", 134400, rowIconSize)
            end

            -- Setting state visualization. Checkbox: check/uncheck atlas
            -- (toggle inline via PostClick). Slider: actual draggable
            -- slider widget with value label. Dropdown/other: current
            -- value as muted text (click opens panel to edit).
            local isKeybindEntry = data and data.settingType == "keybind" and data.bindingAction
            if isKeybindEntry and not entry.isPathNode then
                -- Keybinding row: two inline buttons showing current
                -- primary/alternate keys. Refresh function lets the
                -- buttons re-read GetBindingKey after a capture/clear.
                local action = data.bindingAction
                local kb1 = resultRow.settingKeybind1
                local kb2 = resultRow.settingKeybind2
                local function refresh()
                    local k1, k2 = GetBindingKey(action)
                    kb1:SetText(AbbrevBinding(k1))
                    kb2:SetText(AbbrevBinding(k2))
                end
                kb1._bindingAction = action
                kb1._refresh = refresh
                kb2._bindingAction = action
                kb2._refresh = refresh
                refresh()
                resultRow.settingKeybindGroup:Show()
                if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                resultRow.settingState:Hide()
                resultRow.settingCheck:Hide()
                resultRow.amountText:Hide()
                resultRow.text:SetPoint("RIGHT", resultRow.settingKeybindGroup, "LEFT", -4, 0)
            elseif data and data.settingVariable and not entry.isPathNode then
                if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
                local settingType = data.settingType
                if settingType == "checkboxSlider" and data.cbVariable and data.sliderVariable then
                    -- Combined widget: checkbox state + slider in one row
                    -- (mirrors Blizzard's CreateSettingsCheckboxSliderInitializer
                    -- visual e.g. "Use UI Scale" with the % slider).
                    local isOn = false
                    if Settings and Settings.GetSetting then
                        local sok, cbObj = pcall(Settings.GetSetting, data.cbVariable)
                        if sok and cbObj and cbObj.GetValue then
                            local vok, v = pcall(cbObj.GetValue, cbObj)
                            if vok then isOn = (v == true or v == "1" or v == 1) end
                        end
                    end
                    resultRow.settingState:Show()
                    resultRow.settingCheck:SetShown(isOn)
                    resultRow.amountText:Hide()
                    if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end

                    local sliderVar = data.sliderVariable
                    local rawVal
                    if Settings and Settings.GetSetting then
                        local sok, sObj = pcall(Settings.GetSetting, sliderVar)
                        if sok and sObj and sObj.GetValue then
                            local vok, v = pcall(sObj.GetValue, sObj)
                            if vok then rawVal = v end
                        end
                    end
                    if rawVal == nil and GetCVar then rawVal = GetCVar(sliderVar) end
                    local numVal = tonumber(rawVal) or data.settingMin or 0
                    local sMin = data.settingMin or 0
                    local sMax = data.settingMax or 1
                    local stepVal = data.settingStep or 1
                    if sMax <= sMin then sMax = sMin + 1 end
                    local slider = resultRow.settingSlider
                    slider._settingVar = sliderVar
                    slider._settingFormatter = data.settingFormatter
                    slider._updating = true
                    slider:SetMinMaxValues(sMin, sMax)
                    slider:SetValueStep(stepVal)
                    slider:SetValue(numVal)
                    slider._updating = false

                    if not data.settingFormatter
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                        local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(sliderVar)
                        if fmt then data.settingFormatter = fmt end
                    end
                    local displayVal
                    if data.settingFormatter then
                        local fok, formatted = pcall(data.settingFormatter, numVal)
                        if fok and formatted ~= nil then
                            local ft = type(formatted)
                            if ft == "string" and formatted ~= "" then displayVal = formatted
                            elseif ft == "number" then
                                displayVal = (formatted == mfloor(formatted))
                                    and tostring(mfloor(formatted))
                                    or sformat("%.2f", formatted)
                            end
                        end
                    end
                    if not displayVal then
                        displayVal = (numVal == mfloor(numVal))
                            and tostring(mfloor(numVal))
                            or sformat("%.2f", numVal)
                    end
                    resultRow.settingSliderValue:SetText(displayVal)

                    -- Slider group sits to the LEFT of the checkbox
                    -- so both fit on the right side of the row.
                    resultRow.settingSliderGroup:ClearAllPoints()
                    resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow.settingState, "LEFT", -6, 0)
                    resultRow.settingSliderGroup:Show()

                    resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
                elseif settingType == "checkbox" then
                    local isOn = false
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, v = pcall(settObj.GetValue, settObj)
                            if vok then
                                isOn = (v == true or v == "1" or v == 1)
                            end
                        end
                    end
                    if not isOn and GetCVar then
                        local val = GetCVar(data.settingVariable)
                        isOn = (val == "1")
                    end
                    resultRow.settingState:Show()
                    resultRow.settingCheck:SetShown(isOn)
                    resultRow.amountText:Hide()
                    if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                    if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    -- Re-anchor text RIGHT to settingState so the row name
                    -- truncates at the checkbox instead of overlapping it.
                    resultRow.text:SetPoint("RIGHT", resultRow.settingState, "LEFT", -4, 0)
                elseif settingType == "slider" and data.settingMin and data.settingMax then
                    local rawVal
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, v = pcall(settObj.GetValue, settObj)
                            if vok then rawVal = v end
                        end
                    end
                    if rawVal == nil and GetCVar then
                        rawVal = GetCVar(data.settingVariable)
                    end
                    local numVal = tonumber(rawVal) or data.settingMin

                    local sMin, sMax = data.settingMin, data.settingMax
                    local stepVal = data.settingStep or 1
                    if sMax <= sMin then sMax = sMin + 1 end
                    local slider = resultRow.settingSlider
                    slider._settingVar = data.settingVariable
                    slider._settingFormatter = data.settingFormatter
                    slider._updating = true
                    slider:SetMinMaxValues(sMin, sMax)
                    slider:SetValueStep(stepVal)
                    slider:SetValue(numVal)
                    slider._updating = false
                    resultRow.settingSliderGroup:ClearAllPoints()
                    resultRow.settingSliderGroup:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
                    resultRow.settingSliderGroup:Show()

                    -- Curated SETTINGS_DATA rows don't ship with a
                    -- formatter; pull from the live registry on demand
                    -- so the inline value matches Blizzard's panel
                    -- (Mouse Look Speed raw 180 -> displayed "5.5").
                    if not data.settingFormatter
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                        local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(data.settingVariable)
                        if fmt then data.settingFormatter = fmt end
                    end
                    local displayVal
                    if data.settingFormatter then
                        local fok, formatted = pcall(data.settingFormatter, numVal)
                        if fok and formatted ~= nil then
                            local ft = type(formatted)
                            if ft == "string" and formatted ~= "" then
                                displayVal = formatted
                            elseif ft == "number" then
                                displayVal = (formatted == mfloor(formatted))
                                    and tostring(mfloor(formatted))
                                    or sformat("%.2f", formatted)
                            end
                        end
                    end
                    if not displayVal then
                        if numVal == mfloor(numVal) then
                            displayVal = tostring(mfloor(numVal))
                        else
                            displayVal = sformat("%.2f", numVal)
                        end
                    end
                    resultRow.settingSliderValue:SetText(displayVal)

                    resultRow.settingState:Hide()
                    resultRow.settingCheck:Hide()
                    resultRow.amountText:Hide()
                    if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    resultRow.text:SetPoint("RIGHT", resultRow.settingSliderGroup, "LEFT", -4, 0)
                else
                    -- Dropdown / other: show current value as text
                    local val, rawVal
                    if Settings and Settings.GetSetting then
                        local sok, settObj = pcall(Settings.GetSetting, data.settingVariable)
                        if sok and settObj and settObj.GetValue then
                            local vok, raw = pcall(settObj.GetValue, settObj)
                            if vok and raw ~= nil then
                                rawVal = raw
                                val = tostring(raw)
                            end
                        end
                    end
                    if (not val or val == "") and GetCVar then
                        rawVal = GetCVar(data.settingVariable)
                        val = rawVal
                    end
                    -- Lazily cache the option list so subsequent renders
                    -- can translate raw values (often opaque ints) into
                    -- the localized label the dropdown actually shows.
                    if data.settingType == "dropdown" and not data.settingOptions
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetOptionsForVariable then
                        local opts = ns.BlizzOptionsSearch.GetOptionsForVariable(data.settingVariable)
                        if opts then data.settingOptions = opts end
                    end
                    local optList = (data.settingType == "dropdown" and type(data.settingOptions) == "table")
                        and data.settingOptions or nil
                    if optList and rawVal ~= nil then
                        for oi = 1, #optList do
                            local o = optList[oi]
                            if o.value == rawVal or tostring(o.value) == tostring(rawVal) then
                                val = o.label or val
                                break
                            end
                        end
                    end
                    if optList and #optList > 0 then
                        -- Inline dropdown widget: paddle arrows + center
                        -- button styled like the in-game Settings dropdown.
                        if resultRow.SetSettingDropdownText then
                            resultRow:SetSettingDropdownText(val or "")
                        else
                            resultRow.settingDropdownLabel:SetText(val or "")
                        end
                        resultRow.settingDropdownGroup:Show()
                        resultRow.amountText:Hide()
                        resultRow.text:SetPoint("RIGHT", resultRow.settingDropdownGroup, "LEFT", -4, 0)
                    else
                        -- No enumerable options: muted text fallback. Click
                        -- opens the panel via OpenSettingNoClose.
                        if val and val ~= "" then
                            resultRow.amountText:SetText("|cFFAAAAaa" .. val .. "|r")
                            resultRow.amountText:ClearAllPoints()
                            resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
                            resultRow.amountText:Show()
                        end
                        if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
                    end
                    resultRow.settingState:Hide()
                    resultRow.settingCheck:Hide()
                    if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                end
            else
                resultRow.settingState:Hide()
                resultRow.settingCheck:Hide()
                if resultRow.settingSlider then resultRow.settingSliderGroup:Hide() end
                if resultRow.settingKeybindGroup then resultRow.settingKeybindGroup:Hide() end
                if resultRow.settingDropdownGroup then resultRow.settingDropdownGroup:Hide() end
            end

            -- Flat-list icon sizing. The LEFT icon (UI/map/pin or flatCatIcon)
            -- is large since it's the row's visual anchor. The RIGHT icon
            -- (currency, mount, toy, pet, outfit, appearance set, loot)
            -- gets a mid-sized treatment so it's recognizable without
            -- dominating the row.
            if entry.isFlat and resultRow.icon and resultRow.icon:IsShown() then
                local d = entry.data
                local rightSideIcon = d and (d.mountID or d.toyItemID or d.petID
                    or d.outfitID or d.heirloomItemID or d.transmogSetID
                    or d.category == "Currency"
                    or (d.itemID and d.category == "Loot")
                    or (d.spellID and d.category == "Talent")
                    or (d.spellID and d.category == "Ability")
                    or (d.encounterID and d.category == "Boss")
                    or (d.macroIndex and d.category == "Macro")
                    or (d.bagID and d.category == "Bag")
                    or (d.achievementID and d.category == "Achievement")
                    or d.gearSetID
                    or IsMenuBarSpecificIconData(d)
                    or d.specificIcon or d.specificIconFrame
                    or d.mapSearchResult)
                if rightSideIcon then
                    local rightSize = entryRowH - 18
                    if rightSize < (theme.iconSize or 16) then
                        rightSize = theme.iconSize or 16
                    end
                    if IsMenuBarSpecificIconData(d) then
                        rightSize = entryRowH - 8
                    elseif IsBossResultData(d) then
                        rightSize = entryRowH - 14
                        if rightSize < (theme.iconSize or 16) then
                            rightSize = theme.iconSize or 16
                        end
                    end
                    resultRow.icon:SetSize(rightSize, rightSize)
                else
                    local flatIconSize = entryRowH - 16
                    resultRow.icon:SetSize(flatIconSize, flatIconSize)
                end
            end

            -- Flat-mode positioning fixup: category-specific blocks above
            -- (currency, mount/toy/pet, loot, map, repBar) re-anchor text using
            -- LEFT (vertical center) which collapses the name+path stack.
            -- Re-apply flat anchoring last so layout is consistent across
            -- all categories and the path subtext is bounded by the rep bar
            -- when one is shown (so it stays out of the bar's horizontal area).
            if entry.isFlat and not (data and (data.calculatorResult or data.calculatorLauncher)) then
                local catShown = resultRow.flatCatIcon and resultRow.flatCatIcon:IsShown()
                local d = data
                local mainIconOnRight = d and (d.mountID or d.toyItemID or d.petID
                    or d.outfitID or d.heirloomItemID or d.transmogSetID
                    or d.category == "Currency"
                    or (d.itemID and d.category == "Loot")
                    or (d.spellID and d.category == "Talent")
                    or (d.spellID and d.category == "Ability")
                    or (d.encounterID and d.category == "Boss")
                    or (d.macroIndex and d.category == "Macro")
                    or (d.bagID and d.category == "Bag")
                    or (d.achievementID and d.category == "Achievement")
                    or d.gearSetID
                    or IsMenuBarSpecificIconData(d)
                    or d.specificIcon or d.specificIconFrame
                    or d.mapSearchResult)

                local leftAnchor
                if catShown then
                    leftAnchor = resultRow.flatCatIcon
                elseif not mainIconOnRight and resultRow.icon:IsShown() then
                    leftAnchor = resultRow.icon
                end

                local rightAnchor, rightOffset
                if resultRow.repBar and resultRow.repBar:IsShown() then
                    rightAnchor = resultRow.repBar
                    rightOffset = -4
                elseif mainIconOnRight and resultRow.icon:IsShown() then
                    rightAnchor = resultRow.icon
                    rightOffset = -4
                elseif resultRow.settingSliderGroup and resultRow.settingSliderGroup:IsShown() then
                    rightAnchor = resultRow.settingSliderGroup
                    rightOffset = -4
                elseif resultRow.settingKeybindGroup and resultRow.settingKeybindGroup:IsShown() then
                    rightAnchor = resultRow.settingKeybindGroup
                    rightOffset = -4
                elseif resultRow.settingState and resultRow.settingState:IsShown() then
                    rightAnchor = resultRow.settingState
                    rightOffset = -4
                elseif resultRow.amountText and resultRow.amountText:IsShown() then
                    rightAnchor = resultRow.amountText
                    rightOffset = -4
                else
                    rightAnchor = resultRow
                    rightOffset = -8
                end

                resultRow.text:ClearAllPoints()
                if leftAnchor then
                    resultRow.text:SetPoint("BOTTOMLEFT", leftAnchor, "RIGHT", 6, stackHalfGap)
                else
                    local flatIndent = depth * indPx + 4
                    resultRow.text:SetPoint("BOTTOMLEFT", resultRow, "LEFT", flatIndent, stackHalfGap)
                end
                if rightAnchor == resultRow then
                    resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                else
                    resultRow.text:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
                end

                resultRow.pathSubtext:ClearAllPoints()
                resultRow.pathSubtext:SetPoint("TOPLEFT", resultRow.text, "BOTTOMLEFT", 0, -stackGap)
                if rightAnchor == resultRow then
                    resultRow.pathSubtext:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
                else
                    resultRow.pathSubtext:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
                end
                resultRow.pathSubtext:Show()
            end

            -- Show pin indicator for pinned entries
            if entry.isPinned and resultRow.pinIcon then
                resultRow.pinIcon:ClearAllPoints()
                resultRow.pinIcon:SetPoint("RIGHT", resultRow.text, "LEFT", 0, 0)
                resultRow.pinIcon:Show()
                -- Pinned entries during search: show path prefix in name
                -- (skipped in flat mode, where the path already shows as subtext)
                if not entry.isFlat and data and data.path and #data.path > 0 then
                    local prefix = tconcat(data.path, " > ")
                    resultRow.text:SetText("|cff888888" .. prefix .. " >|r " .. (data.name or ""))
                end
            end

            -- Per-row Apply / Reset extension for settings that staged
            -- a pendingValue (CommitFlag.Apply -- graphics, resolution).
            -- The extension sits BELOW the row as a separate visual
            -- element so the row's own contents (icon, name, inline
            -- editors) don't shift; only the y-cursor below advances to
            -- make room.
            local hasPendingApply = false
            if data and data.settingVariable and ns.BlizzOptionsSearch
               and ns.BlizzOptionsSearch.HasPendingChange then
                hasPendingApply = ns.BlizzOptionsSearch:HasPendingChange(data.settingVariable)
                if not hasPendingApply and data.sliderVariable
                   and data.sliderVariable ~= data.settingVariable then
                    hasPendingApply = ns.BlizzOptionsSearch:HasPendingChange(data.sliderVariable)
                end
            end
            if resultRow.settingApplyExt then
                resultRow.settingApplyExt:SetShown(hasPendingApply)
            end

            -- Measure text height and expand row if text wraps
            -- Skip header tabs: they have SetMaxLines(1) and can't wrap.
            local actualH = resultRow:GetHeight()
            local textObj
            if theme.showHeaderTab and entry.isPathNode and resultRow.headerTab and resultRow.headerTab:IsShown() then
                textObj = nil
            elseif not entry.isPinHeader then
                textObj = resultRow.text
            end
            if textObj then
                local textHeight = textObj:GetStringHeight()
                local minH = textHeight / ns.SEARCHBAR_FILL
                if minH > actualH then
                    actualH = minH
                    resultRow:SetHeight(actualH)
                    if resultRow.headerTab and resultRow.headerTab:IsShown() then
                        resultRow.headerTab:SetHeight(actualH)
                    end
                    if theme.showTreeLines and depth > 0 then
                        local halfRow = actualH * 0.5
                        local xCenter = (depth - 1) * INDENT_PX + LINE_X_OFF
                        resultRow.treeElbow[depth]:ClearAllPoints()
                        resultRow.treeElbow[depth]:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
                        resultRow.treeElbow[depth]:SetHeight(halfRow + 2)
                        resultRow.treeBranch[depth]:ClearAllPoints()
                        resultRow.treeBranch[depth]:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -halfRow)
                        resultRow.treeBranch[depth]:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -halfRow)
                    end
                end
            end

            -- Off-spec abilities: desaturate the icon and dim the text
            -- to match the spellbook's greyed-out treatment for spells
            -- that belong to a non-active spec line. Active passives
            -- (current-spec, not castable but the player has them) stay
            -- full-color -- they're still "yours". Click for both still
            -- routes to the spellbook page since neither can be cast.
            if data.isOffSpec then
                if resultRow.icon then
                    resultRow.icon:SetVertexColor(0.4, 0.4, 0.4, 1.0)
                end
                if resultRow.text then
                    resultRow.text:SetTextColor(0.5, 0.5, 0.5, 1.0)
                end
                if resultRow.pathSubtext then
                    resultRow.pathSubtext:SetTextColor(0.4, 0.4, 0.4, 1.0)
                end
            end

            -- Reserve y-cursor space for the apply extension (sits below
            -- the row at -2 offset). Row's own bounds are unchanged.
            if hasPendingApply and resultRow.settingApplyExtH then
                actualH = actualH + resultRow.settingApplyExtH + 2
            end
            resultRow._efContentBottom = rowContentTop + actualH
            if showShortcutHints and resultRow.data and not resultRow.isPinHeader
               and not resultRow.isSectionHeader and not resultRow.isUnearnedCurrency then
                ApplyResultShortcutGutter(resultRow)
            end
            yOffset = yOffset + actualH
            resultRow:Show()
        elseif resultRow then
            resultRow:Hide()
            resultRow.isPinHeader = false
            resultRow._efShortcutIndex = nil
            resultRow._efShortcutBindingReady = nil
            resultRow._efContentTop = nil
            resultRow._efContentBottom = nil
            if not InCombatLockdown() then
                resultRow:SetAttribute("type", nil)
                resultRow:SetAttribute("toy", nil)
                resultRow:SetAttribute("action", nil)
                resultRow:SetAttribute("spell", nil)
                resultRow:SetAttribute("macro", nil)
                resultRow:SetAttribute("macrotext", nil)
            end
            if resultRow.headerGrad then resultRow.headerGrad:Hide() end
            if resultRow.headerTab then resultRow.headerTab:Hide() end
            resultRow.separator:Hide()
            resultRow.repBar:Hide()
            if resultRow.flatCatIcon then resultRow.flatCatIcon:Hide() end
            if resultRow.pathSubtext then resultRow.pathSubtext:Hide() end
            if resultRow.calcCard then resultRow.calcCard:Hide() end
            if resultRow.calcDivider then resultRow.calcDivider:Hide() end
            if resultRow.calcDividerTop then resultRow.calcDividerTop:Hide() end
            if resultRow.calcDividerBottom then resultRow.calcDividerBottom:Hide() end
            if resultRow.calcArrowText then resultRow.calcArrowText:Hide() end
            if resultRow.calcExpressionHighlight then resultRow.calcExpressionHighlight:Hide() end
            if resultRow.calcResultHighlight then resultRow.calcResultHighlight:Hide() end
            if resultRow.calcExpressionFlash then resultRow.calcExpressionFlash:Hide() end
            if resultRow.calcResultFlash then resultRow.calcResultFlash:Hide() end
            if resultRow.calcExpressionHint then resultRow.calcExpressionHint:Hide() end
            if resultRow.calcResultHint then resultRow.calcResultHint:Hide() end
            if resultRow.calcExpressionButton then resultRow.calcExpressionButton:Hide() end
            if resultRow.calcResultButton then resultRow.calcResultButton:Hide() end
            if resultRow.calcActionBar then resultRow.calcActionBar:Hide() end
            if resultRow.shortcutGroup then resultRow.shortcutGroup:Hide() end
            for d = 1, MAX_DEPTH do
                resultRow.treeVert[d]:Hide()
                resultRow.treeElbow[d]:Hide()
                resultRow.treeBranch[d]:Hide()
            end
        end
    end

    -- Show/hide pin separator between pinned items and search results
    if resultsFrame.pinSeparator then
        if hasResultsAfterPins then
            resultsFrame.pinSeparator:ClearAllPoints()
            resultsFrame.pinSeparator:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, -pinEndYOffset - 4)
            resultsFrame.pinSeparator:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, -pinEndYOffset - 4)
            resultsFrame.pinSeparator:Show()
        else
            resultsFrame.pinSeparator:Hide()
        end
    end

    -- Show/hide category separator lines (between UI, Mount, Toy groups)
    if resultsFrame.categorySeps then
        for si = 1, #resultsFrame.categorySeps do
            local sep = resultsFrame.categorySeps[si]
            if catSepYPositions[si] then
                sep:ClearAllPoints()
                sep:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, -catSepYPositions[si] - 4)
                sep:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, -catSepYPositions[si] - 4)
                sep:Show()
            else
                sep:Hide()
            end
        end
    end

    local totalContentHeight = yOffset
    local hasScroll = totalContentHeight > maxVisibleHeight
    local visibleHeight = hasScroll and maxVisibleHeight or totalContentHeight

    resultsFrame:SetHeight(padT + padB + visibleHeight)
    resultsFrame.scrollChild:SetWidth(resultsFrame:GetWidth() - scrollInset)
    resultsFrame.scrollChild:SetHeight(totalContentHeight)

    resultsFrame.scrollFrame:ClearAllPoints()
    resultsFrame.scrollFrame:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 0, -padT)
    resultsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, padB)

    if not preserveScroll then
        resultsFrame.scrollFrame:SetVerticalScroll(0)
    end

    if resultsFrame.scrollBar then
        resultsFrame.scrollBar:SetShown(hasScroll)
        if hasScroll then
            resultsFrame.scrollBar:UpdateThumb(totalContentHeight, visibleHeight)
        end
    end

    -- Anchor results above or below based on setting. The rounded
    -- container wraps the bar and dropdown in either orientation.
    local belowMode = not EasyFind.db.uiResultsAbove
    local roundedTheme = UI:GetActiveTheme().searchBarRounded
    resultsFrame:ClearAllPoints()
    if belowMode then
        resultsFrame:SetPoint("TOP", UI:GetSearchFrame(), "BOTTOM", 0, 0)
    else
        resultsFrame:SetPoint("BOTTOM", UI:GetSearchFrame(), "TOP", 0, 0)
    end

    -- In rounded mode the resultsFrame backdrop is owned by the
    -- container; clear its own and hide any bg atlas so the unified
    -- silhouette reads as one shape.
    if roundedTheme then
        resultsFrame:SetBackdrop(nil)
        if resultsFrame.bgAtlasTex then resultsFrame.bgAtlasTex:Hide() end
        if UI:GetContainerFrame() then
            UI:GetContainerFrame():ClearAllPoints()
            if belowMode then
                UI:GetContainerFrame():SetPoint("TOPLEFT",     UI:GetSearchFrame(),  "TOPLEFT",     0, 0)
                UI:GetContainerFrame():SetPoint("TOPRIGHT",    UI:GetSearchFrame(),  "TOPRIGHT",    0, 0)
                UI:GetContainerFrame():SetPoint("BOTTOMLEFT",  resultsFrame, "BOTTOMLEFT",  0, 0)
                UI:GetContainerFrame():SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(UI:GetContainerFrame(), UI:GetSearchFrame():GetHeight(), true)
            else
                UI:GetContainerFrame():SetPoint("TOPLEFT",     resultsFrame, "TOPLEFT",     0, 0)
                UI:GetContainerFrame():SetPoint("TOPRIGHT",    resultsFrame, "TOPRIGHT",    0, 0)
                UI:GetContainerFrame():SetPoint("BOTTOMLEFT",  UI:GetSearchFrame(),  "BOTTOMLEFT",  0, 0)
                UI:GetContainerFrame():SetPoint("BOTTOMRIGHT", UI:GetSearchFrame(),  "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(UI:GetContainerFrame(), resultsFrame:GetHeight(), true)
            end
        end
    end

    resultsFrame:Show()
    self:UpdateVisibleResultShortcuts()

    -- If any rep bar row is in side-by-side mode, schedule one deferred re-render so
    -- IsTruncated() can reflect the layout we just set (it reads the previous frame's state).
    if hasSideBySideRepBar and not deferredRepRefreshPending then
        deferredRepRefreshPending = true
        local selfRef = self
        ns.Utils.SafeAfter(0, function()
            deferredRepRefreshPending = false
            selfRef:RefreshResults()
        end)
    end

    UI:SetSelectedIndex(0)
    UI:SetToggleFocused(false)
    self:UpdateSelectionHighlight(nil, UI._preserveSearchNavRepeat)
end
