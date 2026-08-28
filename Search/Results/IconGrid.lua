local _, ns = ...

-- The @icons grid (GitHub #22): the results dropdown becomes a fixed grid of
-- icon cells, macro-picker style, filtered live by whatever follows @icons.
-- The grid is a fixed cell matrix that RETEXTURES on scroll instead of
-- moving frames, so 33k icons cost one pooled page of buttons. Left click
-- opens the copy box with the FileDataID; right click opens a cursor menu
-- with the copy actions and "create macro with this icon".

local Search = ns.Search
local Results = ns.Results
local Render = ns.ResultRender
local Utils = ns.Utils
local IconSearch = ns.IconSearch
local L = ns.L

local mceil, mfloor, mmax = Utils.mceil, Utils.mfloor, Utils.mmax
local sformat = Utils.sformat
local wipe = wipe
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip
local hooksecurefunc = hooksecurefunc

local CELL_GAP = 4
local host, page, cells
local gridCols, gridRows = 0, 0
local rowH = 1
local filtered = {}
local filteredN = 0
local lastQuery
local rowOffset = 0
-- The cell whose cursor menu is open; its highlight is locked for the
-- menu's lifetime.
local menuCell

local function IconTooltip(cellBtn)
    if not cellBtn.iconName then return end
    GameTooltip:SetOwner(cellBtn, "ANCHOR_RIGHT")
    GameTooltip:SetText(cellBtn.iconName, 1, 1, 1)
    GameTooltip:AddLine(tostring(cellBtn.iconID), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function ShowIconCopyBox(iconID, iconName)
    ns.ShowCopyBox(tostring(iconID), L["ICON_COPY_HINT"]:format(iconName or ""))
end

local function CreateMacroWithIcon(iconID, withTooltip)
    -- CreateMacro errors in combat; the whole search UI is dormant there
    -- anyway, this is a guard for stray calls.
    if InCombatLockdown() then return end
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_MacroUI")
    end
    if not CreateMacro then return end
    -- Name stays blank, like the macro UI's own New button: only the icon
    -- is preset, the user titles it. Account tab first; a full account tab
    -- (nil return) falls back to the character tab.
    -- withTooltip presets a bare "#showtooltip" first line: the tooltip
    -- then follows the macro's first /cast or /use, resolved live on
    -- whatever character/spec runs it. Never a spell argument: a named
    -- spell pins the tooltip and breaks on characters without it. The
    -- chosen icon stays either way; only the "?" icon would go dynamic.
    local body = withTooltip and "#showtooltip\n" or ""
    local idx = CreateMacro("", iconID, body, nil)
    if not idx then
        idx = CreateMacro("", iconID, body, true)
    end
    if ns.ResultHandlers and ns.ResultHandlers.FinishResultSelection then
        ns.ResultHandlers:FinishResultSelection()
    end
    if ShowMacroFrame then
        pcall(ShowMacroFrame)
    end
    -- Best effort: land on the new macro. The picker APIs vary by client;
    -- failing silently just leaves the macro UI on its default selection.
    if idx and MacroFrame then
        if MacroFrame.SelectMacro then
            pcall(MacroFrame.SelectMacro, MacroFrame, idx)
        elseif _G["MacroFrame_SelectMacro"] then
            pcall(_G["MacroFrame_SelectMacro"], idx)
        end
    end
end

local function ShowCellMenu(cellBtn)
    local iconID, iconName = cellBtn.iconID, cellBtn.iconName
    if not iconID then return end
    local rows = {
        { text = L["CTX_COPY_ICON_ID"], onClick = function()
            ShowIconCopyBox(iconID, iconName)
        end },
        { text = L["CTX_COPY_ICON_NAME"], onClick = function()
            ns.ShowCopyBox(iconName or "", L["ICON_COPY_HINT"]:format(iconName or ""))
        end },
        { text = L["CTX_COPY_ICON_PATH"], onClick = function()
            ns.ShowCopyBox("Interface\\Icons\\" .. (iconName or ""), L["ICON_COPY_HINT"]:format(iconName or ""))
        end },
        { text = L["CTX_CREATE_MACRO_ICON"], onClick = function()
            CreateMacroWithIcon(iconID)
        end },
        { text = L["CTX_CREATE_MACRO_ICON_TT"], onClick = function()
            CreateMacroWithIcon(iconID, true)
        end },
    }
    -- The hover highlight is mouse-driven and dies the moment the cursor
    -- menu takes the mouse; lock it so the inspected icon stays marked for
    -- the life of the menu.
    menuCell = cellBtn
    cellBtn:LockHighlight()
    Utils.ShowCursorMenu("EasyFindIconCellMenu", rows, {
        scale = EasyFind.db.uiSearchScale or 1.0,
        onHide = function()
            if menuCell then
                menuCell:UnlockHighlight()
                menuCell = nil
            end
        end,
    })
end

local function Repaint()
    -- The page block sits at the first visible row's absolute position
    -- inside the full-height host, so the shared scrollFrame moves it
    -- like real content while only one page of cells ever exists.
    page:ClearAllPoints()
    page:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -rowOffset * rowH)
    local base = rowOffset * gridCols
    -- A repaint retextures cells in place (scroll, filter change): the
    -- menu's locked cell may be about to show a DIFFERENT icon. Close the
    -- menu (its onHide unlocks) rather than let it inspect the wrong one.
    if menuCell then
        local keptID = filtered[base + menuCell.efCellIndex]
        if not keptID or select(2, IconSearch:GetIcon(keptID)) ~= menuCell.iconID then
            Utils.HideCursorMenus("EasyFindIconCellMenu")
        end
    end
    for i = 1, (gridRows + 1) * gridCols do
        local cellBtn = cells[i]
        local fIdx = filtered[base + i]
        if fIdx then
            local name, id = IconSearch:GetIcon(fIdx)
            cellBtn.iconName, cellBtn.iconID = name, id
            cellBtn.tex:SetTexture(id)
            cellBtn:Show()
            if cellBtn:IsMouseOver() and GameTooltip:IsOwned(cellBtn) then
                IconTooltip(cellBtn)
            end
        else
            cellBtn.iconName, cellBtn.iconID = nil, nil
            cellBtn:Hide()
        end
    end
    if host.countText then
        host.countText:SetText(sformat("%d/%d", filteredN, IconSearch:GetTotal()))
        -- Same muted tone the renderer's inert amount text wears.
        local theme = Results.GetActiveTheme and Results:GetActiveTheme()
        if theme and theme.lightTheme and theme.textFaint then
            host.countText:SetTextColor(theme.textFaint[1], theme.textFaint[2], theme.textFaint[3], 1)
        else
            host.countText:SetTextColor(0.6, 0.6, 0.6, 0.9)
        end
    end
end

local function OnCellClick(cellBtn, button)
    if not cellBtn.iconID then return end
    if button == "RightButton" then
        ShowCellMenu(cellBtn)
    else
        ShowIconCopyBox(cellBtn.iconID, cellBtn.iconName)
    end
end

local function EnsureHost(resultsFrame)
    if host then return host end
    host = CreateFrame("Frame", "EasyFindIconGrid", resultsFrame.scrollChild)
    host:EnableMouse(true)
    -- Shift-clicking a spell/item/achievement link while the grid is open
    -- turns it into a ref query ("item:6948") so the grid jumps to that
    -- thing's icon. hooksecurefunc: non-exclusive, runs after Blizzard's
    -- own insert (and after any other addon's hook), and only while the
    -- grid is shown, so it can never fight another icon picker's capture.
    hooksecurefunc("ChatEdit_InsertLink", function(linkText)
        if not (linkText and host and host:IsShown()) then return end
        local ref = linkText:match("|H(%l+:%d+)")
        if not ref then return end
        local searchFrame = Search.GetSearchFrame and Search:GetSearchFrame()
        local editBox = searchFrame and searchFrame.editBox
        if not editBox then return end
        if editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        editBox:SetText(ref)
        editBox:SetCursorPosition(#ref)
        if editBox.placeholder then editBox.placeholder:Hide() end
        Search:OnSearchTextChanged(ref, true)
    end)
    -- No wheel handler of its own: wheel events pass through to the shared
    -- scrollFrame, so the grid rides the same eased scroll path and minimal
    -- scrollbar as every row render.
    page = CreateFrame("Frame", nil, host)
    page:SetSize(1, 1)
    -- Shown/filtered counter. On the results frame, not the scroll content:
    -- it must neither scroll away nor be clipped by the scrollFrame.
    host.countText = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    host.countText:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -10, 4)
    host.countText._efOwnColor = true
    host.countText:Hide()
    resultsFrame.scrollFrame:HookScript("OnVerticalScroll", function(_, offset)
        if not host:IsShown() then return end
        local newOffset = mmax(0, mfloor((offset or 0) / rowH))
        if newOffset ~= rowOffset then
            rowOffset = newOffset
            Repaint()
        end
    end)
    cells = {}
    return host
end

local function EnsureCells(cellSize)
    -- One row beyond the viewport: eased scrolling shows partial rows at
    -- both edges, and the spare row covers the sliver.
    local need = (gridRows + 1) * gridCols
    for i = 1, need do
        local cellBtn = cells[i]
        if not cellBtn then
            cellBtn = CreateFrame("Button", nil, page)
            cellBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            cellBtn.tex = cellBtn:CreateTexture(nil, "ARTWORK")
            cellBtn.tex:SetAllPoints()
            cellBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            cellBtn:SetScript("OnClick", OnCellClick)
            cellBtn:SetScript("OnEnter", IconTooltip)
            cellBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            cells[i] = cellBtn
        end
        local row = mfloor((i - 1) / gridCols)
        local col = (i - 1) % gridCols
        cellBtn.efCellIndex = i
        cellBtn:SetSize(cellSize, cellSize)
        cellBtn:ClearAllPoints()
        cellBtn:SetPoint("TOPLEFT", page, "TOPLEFT",
            col * (cellSize + CELL_GAP), -row * (cellSize + CELL_GAP))
    end
    for i = need + 1, #cells do
        cells[i]:Hide()
    end
end

-- The grid replaces the row list inside the same dropdown: rows and
-- separators hide, the shared layout recipe opens the frame to the grid's
-- height, and the container wraps it exactly as it wraps rows.
function Results:ShowIconGrid(query)
    local resultsFrame = Search:GetResultsFrame()
    if not resultsFrame or not IconSearch then return end
    EnsureHost(resultsFrame)

    -- The grid owns the panel now: the cached row list (typically the
    -- @-suggestion rows that led here) is stale. Left set, the frame's
    -- OnSizeChanged re-render fires 0.02s after the grid's own resize and
    -- repaints those rows over the grid (the open-then-instantly-close flash).
    Results._cachedHierarchical = nil

    query = query or ""
    local sameQuery = query == lastQuery
    if not sameQuery then
        filteredN = IconSearch:Filter(query, filtered)
        lastQuery = query
    elseif filteredN == 0 and IconSearch:GetTotal() > 0 then
        filteredN = IconSearch:Filter(query, filtered)
    end

    -- Previous row render stays painted otherwise (the grid host is
    -- transparent; the container's backdrop is the shared background).
    local buttons = Search:GetResultButtons()
    if buttons then
        for i = 1, #buttons do
            if buttons[i] then buttons[i]:Hide() end
        end
    end
    if resultsFrame.pinSeparator then resultsFrame.pinSeparator:Hide() end
    if resultsFrame.categorySeps then
        for si = 1, #resultsFrame.categorySeps do
            resultsFrame.categorySeps[si]:Hide()
        end
    end
    Search:ClearResultShortcutBindings()

    -- Same paddings the row renderer computes, so the grid sits exactly
    -- where rows would.
    local theme = Results:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local padT = mfloor((theme.resultsPadTop or 0) * fontScale + 0.5)
    if padT < (theme.resultsPadTop or 0) then padT = theme.resultsPadTop end
    local padB = mfloor((theme.resultsPadBot or 0) * fontScale + 0.5)
    if padB < (theme.resultsPadBot or 0) then padB = theme.resultsPadBot end
    if resultsFrame.quickFilterHelp then resultsFrame.quickFilterHelp:Hide() end

    -- Cell size from the user's row-height unit; columns fill the width.
    local unit = Results:GetRowUnitHeight()
    local cellSize = mmax(24, unit - CELL_GAP)
    local SIDE_PAD = 10
    local width = resultsFrame:GetWidth() - SIDE_PAD * 2
    gridCols = mmax(1, mfloor((width + CELL_GAP) / (cellSize + CELL_GAP)))
    gridRows = mmax(1, EasyFind.db.uiResultsRows or 6)
    rowH = cellSize + CELL_GAP
    EnsureCells(cellSize)

    -- The host spans the FULL virtual grid height inside the scrollChild,
    -- so the shared layout/scrollbar treat it like any tall row list; the
    -- page of cells repaints as the scroll crosses row boundaries.
    local gridH = gridRows * rowH - CELL_GAP
    local totalRows = mceil(filteredN / gridCols)
    local virtualH = mmax(1, totalRows * rowH - CELL_GAP)
    local wasShown = host:IsShown()
    host:ClearAllPoints()
    host:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", SIDE_PAD, 0)
    host:SetSize(width, virtualH)
    host:Show()
    host.countText:Show()

    -- padB grows to hold the counter under the cells. preserveScroll only
    -- for a same-query re-render (theme/scale): a fresh open or a changed
    -- query resets to the top, and a previous ROW render's leftover scroll
    -- must never carry into the grid.
    Render:ApplyResultsFrameLayout(resultsFrame, virtualH, gridH, padT, padB + 14,
        0, wasShown and sameQuery)
    rowOffset = mmax(0, mfloor(resultsFrame.scrollFrame:GetVerticalScroll() / rowH))
    Repaint()
end

function Results:HideIconGrid()
    if host and host:IsShown() then
        host:Hide()
        host.countText:Hide()
        lastQuery = nil
        rowOffset = 0
    end
end

function Results:IsIconGridShown()
    return host and host:IsShown() or false
end

-- Release the 33k-entry filter array when the grid is dismissed for a
-- while; rebuilt on the next @icons use.
function Results:ReleaseIconGridMemory()
    wipe(filtered)
    filteredN = 0
    lastQuery = nil
end

-- ONE entry point for every "open icon search" surface (the apps menu slot
-- and the searchable launcher row): show the bar, apply the @icons quick
-- filter with cleared text, and the grid opens waiting for a query.
-- Show, not Focus: with auto-hide on, FinishResultSelection already hid
-- the whole bar before this runs, and Focus early-outs on a hidden bar.
-- Bail if the bar could not be shown (combat): ApplyQuickFilter focuses
-- the editbox, and a hidden editbox must never take keyboard input.
function Results:OpenIconSearch()
    if Search and Search.Show then Search:Show(false) end
    local searchFrame = Search and Search.GetSearchFrame and Search:GetSearchFrame()
    if not (searchFrame and searchFrame:IsShown()) then return end
    local defs = ns.Filters and ns.Filters.quickFilterOptions
    if not defs then return end
    for i = 1, #defs do
        if defs[i].key == "icons" then
            ns.Filters:ApplyQuickFilter(defs[i], "")
            return
        end
    end
end

-- The searchable launcher row: typing "icons" / "icon search" (or the
-- localized app name) offers a row that just runs OpenIconSearch.
local launcherRow
function Results:GetIconSearchLauncherMatch(text)
    if not text or #text < 3 then return nil end
    local q = text:lower()
    local target = (L["ICON_SEARCH_APP"] or ""):lower()
    if not (Utils.sfind(target, q, 1, true)
            or Utils.sfind("icon search", q, 1, true)
            or Utils.sfind("icons", q, 1, true)) then
        return nil
    end
    launcherRow = launcherRow or {
        name = L["ICON_SEARCH_APP"],
        iconSearchLauncher = true,
        noPin = true,
        nativeRun = function() Results:OpenIconSearch() end,
    }
    return launcherRow
end
