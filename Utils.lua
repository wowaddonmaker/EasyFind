-- EasyFind Shared Utilities
-- Localized globals, shared helpers, and common patterns used across all modules.
local ADDON_NAME, ns = ...

local Utils = {}
ns.Utils = Utils

-- LOCALIZED GLOBALS
-- Caching frequently-used Lua and WoW globals to avoid repeated global lookups.
local pairs, ipairs, type, select, unpack, next = pairs, ipairs, type, select, unpack, next
local tinsert, tsort, tconcat, tremove = table.insert, table.sort, table.concat, table.remove
local sfind, slower, ssub, sformat, smatch = string.find, string.lower, string.sub, string.format, string.match
local mmin, mmax, mabs, mpi, mceil, mfloor = math.min, math.max, math.abs, math.pi, math.ceil, math.floor
local pcall, tostring, tonumber = pcall, tostring, tonumber
local GetTime, CreateFrame = GetTime, CreateFrame

-- Export localized references for other modules to import
Utils.pairs   = pairs
Utils.ipairs  = ipairs
Utils.type    = type
Utils.select  = select
Utils.unpack  = unpack
Utils.next    = next

Utils.tinsert  = tinsert
Utils.tsort    = tsort
Utils.tconcat  = tconcat
Utils.tremove  = tremove

Utils.sfind    = sfind
Utils.slower   = slower
Utils.ssub     = ssub
Utils.sformat  = sformat
Utils.smatch   = smatch

Utils.mmin     = mmin
Utils.mmax     = mmax
Utils.mabs     = mabs
Utils.mpi      = mpi
Utils.mceil    = mceil
Utils.mfloor   = mfloor

Utils.pcall    = pcall
Utils.tostring = tostring
Utils.tonumber = tonumber

--- Call a protected function safely, suppressing errors during combat lockdown.
--- Returns true + results on success, false on failure.
function Utils.SafeCall(func, ...)
    if InCombatLockdown() then return false end
    return pcall(func, ...)
end

--- Call a protected method safely (e.g. frame:SetPropagateKeyboardInput).
--- Usage: Utils.SafeCallMethod(frame, "SetPropagateKeyboardInput", false)
function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false end
    local fn = obj[method]
    if not fn then return false end
    return pcall(fn, obj, ...)
end

--- Scroll a ScrollFrame so that the given child button is visible.
--- Uses the button's top/bottom relative to the scrollChild.
function Utils.ScrollToButton(scrollFrame, button)
    if not scrollFrame or not button then return end
    local _, _, _, _, btnOffsetY = button:GetPoint(1)
    if not btnOffsetY then return end
    local btnTop = -btnOffsetY
    local btnBot = btnTop + button:GetHeight()
    local visH = scrollFrame:GetHeight()
    local cur = scrollFrame:GetVerticalScroll()
    if btnTop < cur then
        scrollFrame:SetVerticalScroll(btnTop)
    elseif btnBot > cur + visH then
        scrollFrame:SetVerticalScroll(btnBot - visH)
    end
end

-- Shared constants
ns.GOLD_COLOR = {1.0, 0.82, 0.0}
ns.YELLOW_HIGHLIGHT = {1, 1, 0}
ns.DEFAULT_OPACITY = 0.75
ns.TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
ns.DARK_PANEL_BG = {0.1, 0.1, 0.1, 0.95}
ns.RESULT_ICON_SIZE = 18
ns.SEARCHBAR_HEIGHT = 30      -- base search bar frame height (before font scaling)
ns.SEARCHBAR_FILL = 0.55      -- fraction of bar height filled by text/icon
ns.SEARCHBAR_ICON_SCALE = 0.75 -- icon size relative to editBox height (font glyphs are shorter than line height)
local EasyFindSearchFont = CreateFont("EasyFindSearchFont")
local baseFont = Game15Font_Shadow or GameFontNormal
EasyFindSearchFont:CopyFontObject(baseFont)
EasyFindSearchFont:SetFont((baseFont:GetFont()), 12, select(3, baseFont:GetFont()))
ns.SEARCHBAR_FONT = "EasyFindSearchFont"

local EasyFindLeafFont = CreateFont("EasyFindLeafFont")
EasyFindLeafFont:CopyFontObject(baseFont)
EasyFindLeafFont:SetFont((baseFont:GetFont()), 10, select(3, baseFont:GetFont()))
ns.LEAF_FONT = "EasyFindLeafFont"

-- DEBUG PRINT
-- Centralised debug output - only prints when dev mode is enabled.
function Utils.DebugPrint(...)
    if EasyFind and EasyFind.db and EasyFind.db.devMode then
        print("|cff33ff99[EasyFind]|r", ...)
    end
end

-- FRAME TEXT EXTRACTION
-- Pulls the displayed text from any WoW frame/button.
-- Previously duplicated 8+ times across Highlight.lua and UI.lua.
function Utils.GetButtonText(btn)
    if not btn then return nil end

    -- Named text children (covers virtually every Blizzard button style)
    local keys = {"label", "Label", "text", "Text", "Name", "name"}
    for _, key in ipairs(keys) do
        local child = btn[key]
        if child and child.GetText then
            local t = child:GetText()
            if t then return t end
        end
    end

    -- Frame's own GetText (ButtonTemplate, etc.)
    if btn.GetText then
        local t = btn:GetText()
        if t then return t end
    end

    -- Fallback: first FontString in regions
    for i = 1, select("#", btn:GetRegions()) do
        local region = select(i, btn:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then return t end
        end
    end

    return nil
end

-- COMBINED FRAME TEXT
-- Collects ALL text from a frame (main label + subtitles + fontstring regions)
-- into a single concatenated string.  Used for fuzzy button matching.
function Utils.GetAllFrameText(frame)
    if not frame then return nil end
    local texts = {}

    local keys = {"Label", "label", "Text", "text", "Name", "name"}
    for _, key in ipairs(keys) do
        local child = frame[key]
        if child and child.GetText then
            local t = child:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if frame.GetText then
        local t = frame:GetText()
        if t then texts[#texts + 1] = t end
    end

    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if #texts > 0 then
        return tconcat(texts, " ")
    end
    return nil
end

-- BUTTON SELECTION CHECK
-- Multi-method detection of whether a button/category is selected/expanded.
-- Previously duplicated in IsStatisticsCategorySelected & IsAchievementCategorySelected.
function Utils.IsButtonSelected(btn)
    if not btn then return false end

    -- Explicit selection properties
    if btn.isSelected then return true end
    if btn.selected  then return true end

    -- Expanded state (tree categories)
    if btn.collapsed == false then return true end
    if btn.isExpanded            then return true end
    if btn.expanded              then return true end

    -- Highlight/selection textures
    if btn.highlight       and btn.highlight:IsShown()       then return true end
    if btn.selectedTexture and btn.selectedTexture:IsShown() then return true end
    if btn.SelectedTexture and btn.SelectedTexture:IsShown() then return true end

    -- Background / selection highlight
    if btn.Selection  and btn.Selection:IsShown()  then return true end
    if btn.selection  and btn.selection:IsShown()  then return true end
    if btn.Background and btn.Background:IsShown() then return true end

    -- Element data collapsed flag
    if btn.element and btn.element.collapsed == false then return true end

    return false
end

-- RECURSIVE FRAME TREE SEARCH
-- Walks a frame hierarchy looking for a clickable child whose text matches
-- `targetText` (case-insensitive exact match).
-- `maxDepth` prevents runaway recursion (default 6).
function Utils.SearchFrameTree(frame, targetTextLower, maxDepth)
    maxDepth = maxDepth or 6
    local function search(f, depth)
        if not f or depth > maxDepth then return nil end
        if f:IsShown() then
            local text = Utils.GetButtonText(f)
            if text and slower(text) == targetTextLower then
                if f.Click or (f.IsMouseEnabled and f:IsMouseEnabled()) then
                    return f
                end
            end
        end
        for i = 1, select("#", f:GetChildren()) do
            local child = select(i, f:GetChildren())
            local result = search(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    return search(frame, 0)
end

-- FUZZY BUTTON SEARCH
-- Walks a frame hierarchy looking for a clickable, reasonably-sized child
-- whose combined text contains `searchText` (case-insensitive).
-- Used by FindRatedPvPButton and similar.
function Utils.SearchFrameTreeFuzzy(frame, searchTextLower, maxDepth)
    maxDepth = maxDepth or 6
    local function search(f, depth)
        if not f or depth > maxDepth then return nil end
        if f:IsShown() then
            local w, h = f:GetSize()
            if w and h and w > 80 and h > 20 and w < 500 then
                local text = Utils.GetAllFrameText(f)
                if text and sfind(slower(text), searchTextLower, 1, true) then
                    if f.Click or (f.IsMouseEnabled and f:IsMouseEnabled()) then
                        return f
                    end
                end
            end
        end
        for i = 1, select("#", f:GetChildren()) do
            local child = select(i, f:GetChildren())
            local result = search(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    return search(frame, 0)
end

-- SAFE COPY TABLE (shallow)
function Utils.ShallowCopy(src)
    local copy = {}
    for k, v in pairs(src) do
        copy[k] = v
    end
    return copy
end

-- SAFE FRAME CHECK
-- pcall-wrapped IsShown for frames that may be forbidden.
function Utils.IsFrameShown(frame)
    if not frame then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown
end

-- FRAME PATH RESOLVER
-- Resolve a dotted frame path string (e.g. "PVEFrame.Tab1") to the actual frame.
function Utils.GetFrameByPath(path)
    if not path then return nil end
    local parts = { strsplit(".", path) }
    local current = _G[parts[1]]
    for i = 2, #parts do
        if current then
            current = current[parts[i]]
        else
            return nil
        end
    end
    return current
end

-- MINIMAL SCROLLBAR (Retail quest-log style)
-- Builds a thin 7px scrollbar using minimal-scrollbar-* atlas textures.
-- Overlays the right edge of `parent` - does NOT shrink content width.
-- Returns the scrollbar frame. Call bar:SetShown(bool) to show/hide,
-- and bar:UpdateThumb() after resizing the scroll child.
function Utils.CreateMinimalScrollBar(scrollFrame, parent)
    local MIN_THUMB_H = 20
    local TRACK_PAD = 2
    local VERT_PAD  = 4

    -- Query native atlas sizes so we never hardcode sprite dimensions
    local arrowInfo = C_Texture.GetAtlasInfo("minimal-scrollbar-arrow-top")
    local trackCapInfo = C_Texture.GetAtlasInfo("minimal-scrollbar-track-top")
    local ARROW_W = arrowInfo and arrowInfo.width or 17
    local ARROW_H = arrowInfo and arrowInfo.height or 11
    local BAR_W = trackCapInfo and trackCapInfo.width or 6

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(ARROW_W)
    bar:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)
    bar:SetFrameStrata(parent:GetFrameStrata())
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)

    local function UpdateBarHeight()
        bar:SetHeight(scrollFrame:GetHeight() - VERT_PAD * 2)
    end
    bar.UpdateBarHeight = UpdateBarHeight
    UpdateBarHeight()

    -- Up arrow
    local backBtn = CreateFrame("Button", nil, bar)
    backBtn:SetSize(ARROW_W, ARROW_H)
    backBtn:SetPoint("TOP", bar, "TOP", 0, 0)
    local backTex = backBtn:CreateTexture(nil, "BACKGROUND")
    backTex:SetAtlas("minimal-scrollbar-arrow-top", true)
    backTex:SetPoint("CENTER")
    backBtn:SetScript("OnEnter", function() backTex:SetAtlas("minimal-scrollbar-arrow-top-over", true) end)
    backBtn:SetScript("OnLeave", function() backTex:SetAtlas("minimal-scrollbar-arrow-top", true) end)
    backBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        scrollFrame:SetVerticalScroll(mmax(0, cur - 24))
    end)

    -- Down arrow
    local fwdBtn = CreateFrame("Button", nil, bar)
    fwdBtn:SetSize(ARROW_W, ARROW_H)
    fwdBtn:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    local fwdTex = fwdBtn:CreateTexture(nil, "BACKGROUND")
    fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom", true)
    fwdTex:SetPoint("CENTER")
    fwdBtn:SetScript("OnEnter", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom-over", true) end)
    fwdBtn:SetScript("OnLeave", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom", true) end)
    fwdBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        local range = scrollFrame:GetVerticalScrollRange()
        scrollFrame:SetVerticalScroll(mmin(range, cur + 24))
    end)

    -- Track fills the bar width so track center = arrow center
    local track = CreateFrame("Frame", nil, bar)
    track:SetPoint("TOPLEFT", backBtn, "BOTTOMLEFT", 0, -TRACK_PAD)
    track:SetPoint("BOTTOMRIGHT", fwdBtn, "TOPRIGHT", 0, TRACK_PAD)

    local trackTopTex = track:CreateTexture(nil, "BACKGROUND")
    trackTopTex:SetAtlas("minimal-scrollbar-track-top", true)
    trackTopTex:SetPoint("TOP")

    local trackBotTex = track:CreateTexture(nil, "BACKGROUND")
    trackBotTex:SetAtlas("minimal-scrollbar-track-bottom", true)
    trackBotTex:SetPoint("BOTTOM")

    local trackMidTex = track:CreateTexture(nil, "BACKGROUND")
    trackMidTex:SetAtlas("!minimal-scrollbar-track-middle", true)
    trackMidTex:SetPoint("TOP", trackTopTex, "BOTTOM")
    trackMidTex:SetPoint("BOTTOM", trackBotTex, "TOP")

    -- Thumb (draggable, same width as track)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)

    local thumbTopTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top", true)
    thumbTopTex:SetPoint("TOP")

    local thumbBotTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom", true)
    thumbBotTex:SetPoint("BOTTOM")

    local thumbMidTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle", true)
    thumbMidTex:SetPoint("TOP", thumbTopTex, "BOTTOM")
    thumbMidTex:SetPoint("BOTTOM", thumbBotTex, "TOP")

    local function SetThumbNormal()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top", true)
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom", true)
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle", true)
    end
    local function SetThumbOver()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top-over", true)
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom-over", true)
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle-over", true)
    end

    thumb:SetScript("OnEnter", SetThumbOver)
    thumb:SetScript("OnLeave", function()
        if not bar.isDragging then SetThumbNormal() end
    end)

    -- Thumb dragging
    bar.isDragging = false
    bar.dragOffset = 0

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = true
        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        bar.dragOffset = cursorY / scale - self:GetTop()
        SetThumbOver()
    end)

    thumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = false
        if not self:IsMouseOver() then SetThumbNormal() end
    end)

    bar:SetScript("OnUpdate", function(self)
        if not self.isDragging then return end
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end

        local _, cursorY = GetCursorPosition()
        local scale = track:GetEffectiveScale()
        cursorY = cursorY / scale

        local trackT = track:GetTop()
        local thumbH = thumb:GetHeight()
        local travel = track:GetHeight() - thumbH
        if travel <= 0 then return end

        local pos = trackT - (cursorY - self.dragOffset)
        local ratio = mmax(0, mmin(1, pos / travel))
        scrollFrame:SetVerticalScroll(ratio * range)
    end)

    -- Click track to jump
    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end

        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        cursorY = cursorY / scale

        local trackT = self:GetTop()
        local trackH = self:GetHeight()
        if trackH <= 0 then return end

        local ratio = (trackT - cursorY) / trackH
        scrollFrame:SetVerticalScroll(mmax(0, mmin(range, ratio * range)))
    end)

    -- Update thumb position and size from current scroll state.
    -- Optional explicit contentH/viewH avoid layout-timing issues on first render.
    -- Values are cached so deferred calls (OnShow) can reuse them.
    bar._contentH = nil
    bar._viewH = nil

    function bar:UpdateThumb(contentH, viewH)
        self:UpdateBarHeight()
        if contentH then self._contentH = contentH end
        if viewH then self._viewH = viewH end
        contentH = contentH or self._contentH
        viewH = viewH or self._viewH or scrollFrame:GetHeight()
        local range = contentH and (contentH - viewH) or scrollFrame:GetVerticalScrollRange()
        if not range or range <= 0 then
            thumb:Hide()
            return
        end

        local trackH = track:GetHeight()
        if trackH <= 0 then
            thumb:Hide()
            return
        end

        contentH = contentH or (viewH + range)
        local thumbH = mmax(MIN_THUMB_H, trackH * (viewH / contentH))
        thumb:SetHeight(thumbH)

        local travel = trackH - thumbH
        local scrollPos = scrollFrame:GetVerticalScroll()
        local ratio = mmax(0, mmin(1, (range > 0) and (scrollPos / range) or 0))

        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(ratio * travel))
        thumb:Show()
    end

    -- Sync thumb when scroll position changes
    scrollFrame:SetScript("OnVerticalScroll", function()
        bar:UpdateThumb()
    end)

    -- Mouse wheel on the scrollbar itself
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta)
        local range = scrollFrame:GetVerticalScrollRange()
        local cur = scrollFrame:GetVerticalScroll()
        scrollFrame:SetVerticalScroll(mmax(0, mmin(range, cur - delta * 72)))
    end)

    -- Recompute bar height and thumb on show so layout matches current frame size
    bar:SetScript("OnShow", function(self)
        self:UpdateBarHeight()
        C_Timer.After(0, function()
            if self:IsShown() then self:UpdateThumb() end
        end)
    end)

    bar:Hide()
    return bar
end

-- SCROLLBOX HELPERS
-- Shared patterns for WoW modern ScrollBox frames (virtual scroll lists).
-- Used by currency, reputation, and achievement panels, all of which use
-- the same ScrollBox API but different underlying data models.

--- Scroll a ScrollBox to the first element matching matchFn.
--- Tries FindElementDataByPredicate → ScrollToElementData first.
--- Falls back to SetScrollPercentage(fallbackFraction) if the data provider
--- returns nothing (virtual providers with no stored collection).
--- @param scrollBox  ScrollBox frame
--- @param matchFn    function(elementData) -> bool
--- @param fallbackFraction  number 0-1 or nil (skip fallback)
function Utils.ScrollBoxScrollTo(scrollBox, matchFn, fallbackFraction)
    if not scrollBox then return end

    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if dataProvider then
        local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
        if finder then
            local scrollData = finder(dataProvider, matchFn)
            if scrollData then
                local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
                scrollBox:ScrollToElementData(scrollData, alignCenter)
                return
            end
        end
    end

    if fallbackFraction and scrollBox.SetScrollPercentage then
        scrollBox:SetScrollPercentage(fallbackFraction)
    end
end

--- Find the first visible frame in a ScrollBox whose element data satisfies matchFn.
--- @param scrollBox  ScrollBox frame
--- @param matchFn    function(btn) -> bool  (receives the visible frame, not raw element data)
--- @return Frame or nil
function Utils.ScrollBoxFindButton(scrollBox, matchFn)
    if not scrollBox or not scrollBox.EnumerateFrames then return nil end
    for _, btn in scrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and matchFn(btn) then
            return btn
        end
    end
    return nil
end

--- Click a button using the safest available method.
--- Prefers calling the Lua OnClick handler directly (avoids secure-template
--- restrictions that cause ADDON_ACTION_FORBIDDEN on some protected frames).
--- @param btn        Frame with Click or OnClick
--- @param mouseButton string  default "LeftButton"
function Utils.ClickButton(btn, mouseButton)
    if not btn then return false end
    mouseButton = mouseButton or "LeftButton"
    local hasScript, onClick = pcall(btn.GetScript, btn, "OnClick")
    if hasScript and onClick then
        onClick(btn, mouseButton)
        return true
    elseif btn.Click then
        local ok = Utils.SafeCallMethod(btn, "Click")
        return ok ~= false
    end
    return false
end

-- Create a grey circle-X clear button (retail quest log style).
-- Returns the button; caller must set OnClick and OnEnter scripts.
function Utils.CreateClearButton(parent, globalName)
    local btn = CreateFrame("Button", globalName, parent)
    btn:SetSize(18, 18)
    btn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    btn:EnableMouse(true)
    btn:Hide()

    local normal = btn:CreateTexture(nil, "ARTWORK")
    normal:SetAllPoints()
    normal:SetTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
    btn:SetNormalTexture(normal)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
    highlight:SetVertexColor(1.2, 1.2, 1.2, 1)
    highlight:SetBlendMode("ADD")
    btn:SetHighlightTexture(highlight)

    return btn
end
