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
-- Left/right inset of the grid inside the results frame; the corner hint
-- shares it so its text aligns with the first icon column.
local SIDE_PAD = 10
-- Extra bottom reserve past the theme's own padB for the hint/counter
-- strip; the texts center vertically in padB + this.
local TEXT_STRIP_EXTRA = 14
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
-- Keyboard focus: absolute position in `filtered` (0 = keyboard nav off).
-- The grid plugs into the bar's ONE nav system (navFrame): MoveSelection,
-- ActivateSelected, the Tab/ESC branches and the vim aliases all route
-- here while the grid owns the panel, so every mouse-free convention the
-- row list has works identically on cells.
local navIndex = 0

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
    -- withTooltip presets a bare "#showtooltip" first line: the tooltip
    -- then follows the macro's first /cast or /use, resolved live on
    -- whatever character/spec runs it. Never a spell argument: a named
    -- spell pins the tooltip and breaks on characters without it. The
    -- chosen icon stays either way; only the "?" icon would go dynamic.
    local body = withTooltip and "#showtooltip\n" or ""
    -- The client REFUSES an empty macro name ("CreateMacro() failed, no
    -- name specified" -- a hard error, hence the pcalls). A lone space is
    -- the closest legal thing to the blank title the user renames anyway;
    -- if a client build rejects that too, fall back to the localized word
    -- for Macro. Account tab first; a full tab (nil) tries the character
    -- tab.
    local function TryCreateMacro(name)
        local ok, idx = pcall(CreateMacro, name, iconID, body, nil)
        if ok and idx then return idx end
        ok, idx = pcall(CreateMacro, name, iconID, body, true)
        if ok and idx then return idx end
        return nil
    end
    local idx = TryCreateMacro(" ") or TryCreateMacro(_G["MACRO"] or "Macro")
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

local function ShowCellMenu(cellBtn, keyboardMode)
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
    -- Keyboard-opened (Tab on the focused cell): anchor beside the CELL
    -- instead of the cursor, and hand the menu keyboard focus, exactly like
    -- a row's Tab context menu.
    Utils.ShowCursorMenu("EasyFindIconCellMenu", rows, {
        scale = EasyFind.db.uiSearchScale or 1.0,
        anchorFrame = keyboardMode and cellBtn or nil,
        keyboardMode = keyboardMode or nil,
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
        -- The keyboard-focused cell wears the locked highlight (same light
        -- the mouse hover shows); the menu's cell keeps its own lock.
        if cellBtn ~= menuCell then
            if navIndex > 0 and base + i == navIndex then
                cellBtn:LockHighlight()
            else
                cellBtn:UnlockHighlight()
            end
        end
    end
    if host.countText then
        host.countText:SetText(sformat("%d/%d", filteredN, IconSearch:GetTotal()))
        -- With no matches there is nothing to right-click; the hint slot
        -- carries the no-results message instead (Blizzard's own string).
        if filteredN == 0 then
            host.hintText:SetText(_G["BROWSE_NO_RESULTS"] or "No results found.")
        else
            host.hintText:SetText(L["ICON_GRID_RCLICK_HINT"])
        end
        -- Same muted tone the renderer's inert amount text wears.
        local theme = Results.GetActiveTheme and Results:GetActiveTheme()
        if theme and theme.lightTheme and theme.textFaint then
            host.countText:SetTextColor(theme.textFaint[1], theme.textFaint[2], theme.textFaint[3], 1)
            host.hintText:SetTextColor(theme.textFaint[1], theme.textFaint[2], theme.textFaint[3], 1)
        else
            host.countText:SetTextColor(0.6, 0.6, 0.6, 0.9)
            host.hintText:SetTextColor(0.6, 0.6, 0.6, 0.9)
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
    -- Anchors are set per ShowIconGrid: their vertical center sits at half
    -- the bottom text strip, whose height varies with theme and font scale.
    host.countText = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    host.countText._efOwnColor = true
    host.countText:Hide()
    -- Right-click hint, bottom-left twin of the counter (swaps to the
    -- no-results message when the filter matches nothing).
    host.hintText = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    host.hintText._efOwnColor = true
    host.hintText:Hide()
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
    host.hintText:Show()

    -- The bottom strip holds the hint and counter: padB plus the extra
    -- text reserve. Anchoring the texts' vertical CENTER at half the strip
    -- keeps them perfectly centered between the last icon row and the
    -- window bottom at every theme padding and font scale.
    local stripH = padB + TEXT_STRIP_EXTRA
    -- The columns rarely fill the width exactly (integer column count), so
    -- the counter aligns to the LAST COLUMN's right edge, not the frame's:
    -- the hint tracks the first column, the count the last, and the strip
    -- reads as part of the grid.
    local gridRight = SIDE_PAD + gridCols * (cellSize + CELL_GAP) - CELL_GAP
    host.hintText:ClearAllPoints()
    host.hintText:SetPoint("LEFT", resultsFrame, "BOTTOMLEFT", SIDE_PAD, stripH / 2)
    host.countText:ClearAllPoints()
    host.countText:SetPoint("RIGHT", resultsFrame, "BOTTOMLEFT", gridRight, stripH / 2)

    -- padB grows to hold the text strip under the cells. preserveScroll
    -- only for a same-query re-render (theme/scale): a fresh open or a
    -- changed query resets to the top, and a previous ROW render's
    -- leftover scroll must never carry into the grid.
    Render:ApplyResultsFrameLayout(resultsFrame, virtualH, gridH, padT, stripH,
        0, wasShown and sameQuery)
    rowOffset = mmax(0, mfloor(resultsFrame.scrollFrame:GetVerticalScroll() / rowH))
    Repaint()
end

function Results:HideIconGrid()
    if host and host:IsShown() then
        host:Hide()
        host.countText:Hide()
        host.hintText:Hide()
        lastQuery = nil
        rowOffset = 0
        navIndex = 0
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

-- ==== Keyboard navigation (the bar's nav system routes here) ============

function Results:IsIconGridNavActive()
    return navIndex > 0 and host ~= nil and host:IsShown()
end

local function GridNavShow()
    -- Keep the focused cell's row on screen: scrolling retextures the page
    -- (the OnVerticalScroll hook repaints), then the lock lands on the new
    -- cell because focus is an absolute index.
    local focusRow = mfloor((navIndex - 1) / gridCols)
    local scrollFrame = Search:GetResultsFrame().scrollFrame
    if focusRow < rowOffset then
        scrollFrame:SetVerticalScroll(focusRow * rowH)
    elseif focusRow > rowOffset + gridRows - 1 then
        scrollFrame:SetVerticalScroll((focusRow - gridRows + 1) * rowH)
    end
    Repaint()
end

function Results:ExitIconGridNav(refocus)
    if navIndex == 0 then return end
    navIndex = 0
    if host and host:IsShown() then Repaint() end
    Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", false)
    if refocus then
        local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        if editBox and not editBox:HasFocus() then
            editBox.blockFocus = nil
            editBox:SetFocus()
        end
    end
end

-- dCol/dRow move the focus; entering (nav off) lands on the first visible
-- cell. Moving up past the top row exits back to the editbox, mirroring
-- the row list's boundary behavior. Returns true when focus moved.
function Results:MoveIconGridFocus(dCol, dRow)
    if filteredN == 0 then return false end
    if navIndex == 0 then
        -- Set BEFORE ClearFocus: the editbox focus-lost handler treats an
        -- active nav (like selectedIndex > 0) as "not a click-outside".
        navIndex = rowOffset * gridCols + 1
        if navIndex > filteredN then navIndex = filteredN end
        local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        if editBox and editBox:HasFocus() then editBox:ClearFocus() end
        Utils.SafeCallMethod(Search:GetNavFrame(), "EnableKeyboard", true)
        GridNavShow()
        return true
    end
    local target = navIndex + dCol + dRow * gridCols
    if dRow < 0 and target < 1 then
        self:ExitIconGridNav(true)
        return true
    end
    if target < 1 then target = 1 end
    if target > filteredN then target = filteredN end
    if target == navIndex then return false end
    navIndex = target
    GridNavShow()
    return true
end

function Results:JumpIconGridFocus(toEnd)
    if filteredN == 0 then return end
    navIndex = toEnd and filteredN or 1
    GridNavShow()
end

function Results:ActivateIconGridFocus()
    if not self:IsIconGridNavActive() then return false end
    local fIdx = filtered[navIndex]
    if not fIdx then return false end
    local name, id = IconSearch:GetIcon(fIdx)
    if id then ShowIconCopyBox(id, name) end
    return true
end

function Results:OpenIconGridFocusMenu()
    if not self:IsIconGridNavActive() then return false end
    local base = rowOffset * gridCols
    local cellBtn = cells and cells[navIndex - base]
    if not (cellBtn and cellBtn.iconID) then return false end
    ShowCellMenu(cellBtn, true)
    return true
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
