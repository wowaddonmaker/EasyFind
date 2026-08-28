local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Utils = ns.Utils
local Render = ns.ResultRender
local History = ns.SearchHistory
local Icons = ns.ResultIcons
local SecureAttributes = ns.ResultSecureAttributes
local Shortcuts = ns.ResultShortcuts
local Tooltips = ns.ResultTooltips
local Database = ns.Database

local mmin, mfloor = Utils.mmin, Utils.mfloor
local wipe = wipe

local collapsedNodes = Results._collapsedNodes
local SCRATCH = Results._SCRATCH
local ApplySecureResultAttributes = SecureAttributes.Apply
local RestoreResultShortcutGutter = Shortcuts.RestoreResultShortcutGutter
local ApplyResultShortcutGutter = Shortcuts.ApplyResultShortcutGutter
local MAX_BUTTON_POOL = Render.MAX_BUTTON_POOL
local MAX_SEARCH_RESULT_ROWS = Render.MAX_SEARCH_RESULT_ROWS
local MAX_DEPTH = Render.MAX_DEPTH
local deferredRepRefreshPending = false

-- Single owner of the per-row viewport math: one visible row is the themed
-- row height plus the flat-mode extra, both font-scaled. Returns the unit
-- plus its two parts; the Rescaler snaps its height drag to unit multiples.
function Results:GetRowUnitHeight()
    local theme = Results:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local rowH = mfloor(theme.rowHeight * fontScale + 0.5)
    if rowH < theme.rowHeight then rowH = theme.rowHeight end
    local flatExtraH = mfloor(16 * fontScale + 0.5)
    if flatExtraH < 16 then flatExtraH = 16 end
    return rowH + flatExtraH, rowH, flatExtraH
end

-- A re-render (settings toggle, or an async heavy-load re-search that fires
-- while the cursor is parked on a row) tears down the row the mouse is over,
-- so its tooltip vanishes and only comes back when the cursor moves. Re-fire
-- OnEnter for the hovered row, but only when its tooltip was actually lost, so
-- ordinary renders don't rebuild a tooltip that's already up.
function Render:RestoreHoveredRow()
    local buttons = Search:GetResultButtons()
    if not buttons then return end
    for i = 1, #buttons do
        local row = buttons[i]
        if row and row:IsShown() and Utils.IsFrameVisiblyMouseOver(row) then
            if not (GameTooltip:IsOwned(row) and GameTooltip:IsShown()) then
                local onEnter = row:GetScript("OnEnter")
                if onEnter then onEnter(row) end
            end
            return
        end
    end
end

-- Open the dropdown to fit `totalContentHeight` of content (viewport capped
-- at maxVisibleHeight), wire the scroll machinery, and wrap the rounded
-- container around bar + dropdown in either orientation. ONE owner for the
-- open-the-dropdown geometry: the row renderer and the icon grid both end
-- their layout here, so the silhouette cannot drift between them.
function Render:ApplyResultsFrameLayout(resultsFrame, totalContentHeight,
        maxVisibleHeight, padT, padB, scrollInset, preserveScroll)
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
    local roundedTheme = Results:GetActiveTheme().searchBarRounded
    resultsFrame:ClearAllPoints()
    if belowMode then
        resultsFrame:SetPoint("TOP", Search:GetSearchFrame(), "BOTTOM", 0, 0)
    else
        resultsFrame:SetPoint("BOTTOM", Search:GetSearchFrame(), "TOP", 0, 0)
    end

    -- In rounded mode the resultsFrame backdrop is owned by the
    -- container; clear its own and hide any bg atlas so the unified
    -- silhouette reads as one shape.
    if roundedTheme then
        resultsFrame:SetBackdrop(nil)
        if resultsFrame.bgAtlasTex then resultsFrame.bgAtlasTex:Hide() end
        if Search:GetContainerFrame() then
            Search:GetContainerFrame():ClearAllPoints()
            if belowMode then
                Search:GetContainerFrame():SetPoint("TOPLEFT",     Search:GetSearchFrame(),  "TOPLEFT",     0, 0)
                Search:GetContainerFrame():SetPoint("TOPRIGHT",    Search:GetSearchFrame(),  "TOPRIGHT",    0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMLEFT",  resultsFrame, "BOTTOMLEFT",  0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(Search:GetContainerFrame(), Search:GetSearchFrame():GetHeight(), true)
            else
                Search:GetContainerFrame():SetPoint("TOPLEFT",     resultsFrame, "TOPLEFT",     0, 0)
                Search:GetContainerFrame():SetPoint("TOPRIGHT",    resultsFrame, "TOPRIGHT",    0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMLEFT",  Search:GetSearchFrame(),  "BOTTOMLEFT",  0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMRIGHT", Search:GetSearchFrame(),  "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(Search:GetContainerFrame(), resultsFrame:GetHeight(), true)
            end
        end
    end

    resultsFrame:Show()
end

function Render:ShowHierarchicalResults(hierarchical, preserveScroll)
    if not hierarchical or #hierarchical == 0 then
        self:HideResults()
        return
    end
    local resultsFrame = Search:GetResultsFrame()
    if not resultsFrame then return end

    -- Leaving the @icons grid: it hid the row pool, so the render-skip
    -- signature must be busted or an "identical" list would early-return
    -- with every row still hidden under a now-hidden grid.
    if Results.IsIconGridShown and Results:IsIconGridShown() then
        Results:HideIconGrid()
        self._lastRenderSig = nil
    end

    -- Rows hidden or repurposed by a re-render never fire OnLeave (a
    -- frame hidden under the cursor doesn't), which strands the unearned
    -- tooltip on screen; every render starts it hidden and the next
    -- hover re-shows it.
    local unearned = Tooltips:GetUnearnedTooltip()
    if unearned then unearned:Hide() end

    Results._cachedHierarchical = hierarchical

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
        local searchW = Search:GetSearchFrame() and Search:GetSearchFrame():GetWidth() or 0
        local customResultsW = EasyFind.db.uiResultsWidth or 0
        local maxResultsH = EasyFind.db.uiResultsRows or 6
        -- The screen-fit clamp depends on where the dropdown sits, so a moved
        -- bar must invalidate the signature.
        local frameEdge = mfloor((EasyFind.db.uiResultsAbove
            and (resultsFrame:GetBottom() or 0)
            or (resultsFrame:GetTop() or 0)) + 0.5)
        local quickFilterHelp = self:IsQuickFilterSuggestionsActive() and 1 or 0
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
            and last.frameEdge == frameEdge
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
        if same then return end
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
        last.frameEdge = frameEdge
        for hi = 1, n do
            local e = hierarchical[hi]
            local stride = (hi - 1) * 3
            last[stride + 1] = e.data
            last[stride + 2] = e.depth or 0
            last[stride + 3] = e.isPinned and 1 or 0
        end
        for i = n * 3 + 1, #last do last[i] = nil end
    end

    Tooltips:ClearResultTooltips()

    local theme = Results:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local _, rowH, flatExtraH = Results:GetRowUnitHeight()
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
        if self:IsQuickFilterSuggestionsActive() then
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
    if roundedDocked and Search:GetSearchFrame() then
        resultsFrame:SetWidth(Search:GetSearchFrame():GetWidth())
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
    wipe(SCRATCH.currencyInfoCache)
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
    local bypassSearchRowCap = self:IsQuickFilterSuggestionsActive()
    if not bypassSearchRowCap and pinSlots < visibleN then
        count = mmin(count, pinSlots + MAX_SEARCH_RESULT_ROWS)
    end

    -- Viewport height from the user's row count (rows scale with the theme
    -- row height and font size).
    local maxVisibleHeight = (EasyFind.db.uiResultsRows or 6) * (rowH + flatExtraH)
    -- Screen fit: if the configured height would push the dropdown off the
    -- screen edge it grows toward, shrink to as many whole rows as fit.
    -- GetTop/GetBottom are in the frame's own units, so no scale conversion
    -- is needed below the bar; above-mode converts the screen top once.
    do
        local SCREEN_MARGIN = 16
        local availableLocal
        if EasyFind.db.uiResultsAbove then
            local frameBottom = resultsFrame:GetBottom()
            local effScale = resultsFrame:GetEffectiveScale()
            if frameBottom and effScale and effScale > 0 then
                local screenTopLocal = UIParent:GetHeight() * UIParent:GetEffectiveScale() / effScale
                availableLocal = screenTopLocal - frameBottom - SCREEN_MARGIN
            end
        else
            local frameTop = resultsFrame:GetTop()
            if frameTop then availableLocal = frameTop - SCREEN_MARGIN end
        end
        if availableLocal and availableLocal > 0
           and (maxVisibleHeight + padT + padB) > availableLocal then
            local fitRows = mfloor((availableLocal - padT - padB) / (rowH + flatExtraH))
            if fitRows < 1 then fitRows = 1 end
            maxVisibleHeight = fitRows * (rowH + flatExtraH)
        end
    end
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
    local showShortcutHints = Render.ShouldShowShortcutHints()
    wipe(SCRATCH.catSepYPositions)
    local catSepYPositions = SCRATCH.catSepYPositions
    local hasSideBySideRepBar = false
    local renderState = SCRATCH.renderState
    wipe(renderState)
    renderState.theme = theme
    renderState.fontScale = fontScale
    renderState.rowH = rowH
    renderState.stackGap = stackGap
    renderState.stackHalfGap = stackHalfGap
    renderState.indPx = indPx
    renderState.rowIconSize = rowIconSize
    renderState.visible = visible
    renderState.count = count
    renderState.isLastChild = isLastChild
    renderState.hasSideBySideRepBar = false
    for i = 1, MAX_BUTTON_POOL do
        local resultRow = i <= count and Results:EnsureResultButton(i) or Search:GetResultButtons()[i]
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
                -- Sized to fit the math card itself; the old 86 was sized
                -- for card + launcher action bar combined, which is now a
                -- separate row.
                local calcRowH = mfloor(56 * fontScale + 0.5)
                if calcRowH < 50 then calcRowH = 50 end
                if entryRowH < calcRowH then entryRowH = calcRowH end
            end
            local rowContentTop = yOffset
            resultRow:SetSize(resultsFrame:GetWidth() - padL * 2 - scrollInset, entryRowH)
            resultRow:ClearAllPoints()
            resultRow:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", padL, -yOffset)
            renderState.rowIndex = i
            renderState.entryRowH = entryRowH

            -- Selection visual is now carried by the row's built-in
            -- HighlightTexture (atlas set in CreateResultRow), shared
            -- with mouse hover; no separate selectionHighlight texture.
            if resultRow.UnlockHighlight and not resultRow._efContextMenuHeld then
                Results:SetRowHighlightLocked(resultRow, false)
            end

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

            resultRow.data = data
            -- Recycled rows can leak icon.mountID etc. into the OnEnter
            -- tooltip; clear before the per-category branch sets fields.
            if resultRow.icon then
                Icons.ClearRowIconLeafIDs(resultRow.icon)
            end
            ApplySecureResultAttributes(resultRow, data)
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

            Render.TreeLines(resultRow, renderState, i, depth)

            Render.ResultHeader(resultRow, entry, renderState, depth)

            local isUnearnedCurrency = Render.IsUnearnedCurrencyEntry(entry, renderState)
            resultRow.isUnearnedCurrency = isUnearnedCurrency
            resultRow.isPathNode = entry.isPathNode  -- Store for tooltip text
            local lockedReason
            if not isUnearnedCurrency and data then
                lockedReason = Database:GetEntryLockedReason(data)
            end
            resultRow.lockedReason = lockedReason
            -- An unearned title dims like any unavailable row, but is NOT
            -- locked: its click still opens the achievement that awards it,
            -- which is the whole point of listing it. lockedReason would have
            -- suppressed that click, so the two are kept separate here.
            local isInertRow = isUnearnedCurrency or lockedReason ~= nil
                or (data and data.titleUnearned) or false

            Render.BaseRowText(resultRow, entry, renderState)

            local repSideBySide = Render.RowContent(self, resultRow, entry, renderState, isInertRow)
            if repSideBySide then hasSideBySideRepBar = true end

            if resultRow._efDesat ~= isInertRow then
                resultRow._efDesat = isInertRow
                resultRow.icon:SetDesaturated(isInertRow)
                if resultRow.flatCatIcon then
                    resultRow.flatCatIcon:SetDesaturated(isInertRow)
                end
            end
            if isInertRow then
                resultRow.icon:SetVertexColor(0.55, 0.55, 0.55, 1.0)
                if resultRow.flatCatIcon then
                    resultRow.flatCatIcon:SetVertexColor(0.55, 0.55, 0.55, 1.0)
                end
            end

            Render.ApplyFlatResultSizing(resultRow, entry, renderState)
            Render.ApplyIconVisibility(resultRow, entry)

            -- Flat-mode positioning fixup: category-specific blocks above
            -- (currency, mount/toy/pet, loot, map, repBar) re-anchor text using
            -- LEFT (vertical center) which collapses the name+path stack.
            -- Re-apply flat anchoring last so layout is consistent across
            -- all categories and the path subtext is bounded by the rep bar
            -- when one is shown (so it stays out of the bar's horizontal area).
            Render.ApplyFlatResultAnchoring(resultRow, entry, renderState)

            Render.ApplyPinnedResultPrefix(resultRow, entry)

            -- Per-row Apply / Reset extension for settings that staged
            -- a pendingValue (CommitFlag.Apply -- graphics, resolution).
            -- The extension sits BELOW the row as a separate visual
            -- element so the row's own contents (icon, name, inline
            -- editors) don't shift; only the y-cursor below advances to
            -- make room.
            local hasPendingApply = Render.GetResultPendingApply(data)
            if resultRow.settingApplyExt then
                resultRow.settingApplyExt:SetShown(hasPendingApply)
            end

            local actualH = Render.MeasureResultRowHeight(resultRow, entry, renderState)

            Render.ApplyOffSpecResultStyle(resultRow, data)

            -- Reserve y-cursor space for the apply extension (sits below
            -- the row at -2 offset). Row's own bounds are unchanged.
            if hasPendingApply and resultRow.settingApplyExtH then
                actualH = actualH + resultRow.settingApplyExtH + 2
            end
            resultRow._efContentBottom = rowContentTop + actualH
            if showShortcutHints and resultRow.data and not resultRow.isPinHeader
               and not resultRow.isSectionHeader then
                ApplyResultShortcutGutter(resultRow)
            end
            yOffset = yOffset + actualH
            resultRow:Show()
        elseif resultRow then
            Render.HideUnusedResultRow(resultRow)
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

    -- Show/hide category separator lines (between Search, Mount, Toy groups)
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

    Render:ApplyResultsFrameLayout(resultsFrame, yOffset, maxVisibleHeight,
        padT, padB, scrollInset, preserveScroll)
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

    Search:SetSelectedIndex(0)
    Search:SetToggleFocused(false)
    self:UpdateSelectionHighlight(nil, History:IsPreservingNavRepeat())
    self:RestoreHoveredRow()
end
