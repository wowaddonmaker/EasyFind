-- =============================================================================
-- EasyFind Shared Utilities
-- Localized globals, shared helpers, and common patterns used across all modules.
-- =============================================================================
local ADDON_NAME, ns = ...

local Utils = {}
ns.Utils = Utils

-- =============================================================================
-- LOCALIZED GLOBALS
-- Caching frequently-used Lua and WoW globals to avoid repeated global lookups.
-- =============================================================================
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

-- =============================================================================
-- DEBUG PRINT
-- Centralised debug output — only prints when dev mode is enabled.
-- =============================================================================
function Utils.DebugPrint(...)
    if EasyFind and EasyFind.db and EasyFind.db.devMode then
        print("|cff33ff99[EasyFind]|r", ...)
    end
end

-- =============================================================================
-- FRAME TEXT EXTRACTION
-- Comprehensive helper to pull the displayed text from any WoW frame/button.
-- Previously duplicated 8+ times across Highlight.lua and UI.lua.
-- =============================================================================
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

-- =============================================================================
-- COMBINED FRAME TEXT
-- Collects ALL text from a frame (main label + subtitles + fontstring regions)
-- into a single concatenated string.  Used for fuzzy button matching.
-- =============================================================================
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

-- =============================================================================
-- BUTTON SELECTION CHECK
-- Multi-method detection of whether a button/category is selected/expanded.
-- Previously duplicated in IsStatisticsCategorySelected & IsAchievementCategorySelected.
-- =============================================================================
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

-- =============================================================================
-- RECURSIVE FRAME TREE SEARCH
-- Walks a frame hierarchy looking for a clickable child whose text matches
-- `targetText` (case-insensitive exact match).
-- `maxDepth` prevents runaway recursion (default 6).
-- =============================================================================
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

-- =============================================================================
-- FUZZY BUTTON SEARCH
-- Walks a frame hierarchy looking for a clickable, reasonably-sized child
-- whose combined text contains `searchText` (case-insensitive).
-- Used by FindRatedPvPButton and similar.
-- =============================================================================
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

-- =============================================================================
-- SAFE COPY TABLE (shallow)
-- =============================================================================
function Utils.ShallowCopy(src)
    local copy = {}
    for k, v in pairs(src) do
        copy[k] = v
    end
    return copy
end

-- =============================================================================
-- SAFE FRAME CHECK
-- pcall-wrapped IsShown for frames that may be forbidden.
-- =============================================================================
function Utils.IsFrameShown(frame)
    if not frame then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown
end

-- =============================================================================
-- FRAME PATH RESOLVER
-- Resolve a dotted frame path string (e.g. "PVEFrame.Tab1") to the actual frame.
-- =============================================================================
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

-- =============================================================================
-- MINIMAL SCROLLBAR (Retail quest-log style)
-- Builds a thin 7px scrollbar using minimal-scrollbar-* atlas textures.
-- Overlays the right edge of `parent` — does NOT shrink content width.
-- Returns the scrollbar frame. Call bar:SetShown(bool) to show/hide,
-- and bar:UpdateThumb() after resizing the scroll child.
-- =============================================================================
function Utils.CreateMinimalScrollBar(scrollFrame, parent)
    local BAR_W = 7
    local CAP_H = 7
    local ARROW_W, ARROW_H = 16, 11
    local MIN_THUMB_H = 20

    -- Container frame, anchored to right edge of parent
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(ARROW_W)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -8)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 8)
    bar:SetFrameStrata(parent:GetFrameStrata())
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)

    -- Up arrow
    local backBtn = CreateFrame("Button", nil, bar)
    backBtn:SetSize(ARROW_W, ARROW_H)
    backBtn:SetPoint("TOP", bar, "TOP", 0, 0)
    local backTex = backBtn:CreateTexture(nil, "BACKGROUND")
    backTex:SetAtlas("minimal-scrollbar-arrow-top")
    backTex:SetAllPoints()
    backBtn:SetScript("OnEnter", function() backTex:SetAtlas("minimal-scrollbar-arrow-top-over") end)
    backBtn:SetScript("OnLeave", function() backTex:SetAtlas("minimal-scrollbar-arrow-top") end)
    backBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        scrollFrame:SetVerticalScroll(mmax(0, cur - 24))
    end)

    -- Down arrow
    local fwdBtn = CreateFrame("Button", nil, bar)
    fwdBtn:SetSize(ARROW_W, ARROW_H)
    fwdBtn:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    local fwdTex = fwdBtn:CreateTexture(nil, "BACKGROUND")
    fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom")
    fwdTex:SetAllPoints()
    fwdBtn:SetScript("OnEnter", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom-over") end)
    fwdBtn:SetScript("OnLeave", function() fwdTex:SetAtlas("minimal-scrollbar-arrow-bottom") end)
    fwdBtn:SetScript("OnClick", function()
        local cur = scrollFrame:GetVerticalScroll()
        local range = scrollFrame:GetVerticalScrollRange()
        scrollFrame:SetVerticalScroll(mmin(range, cur + 24))
    end)

    -- Track (between arrows)
    local track = CreateFrame("Frame", nil, bar)
    track:SetWidth(BAR_W)
    track:SetPoint("TOP", backBtn, "BOTTOM", 0, -1)
    track:SetPoint("BOTTOM", fwdBtn, "TOP", 0, 1)

    local trackTopTex = track:CreateTexture(nil, "BACKGROUND")
    trackTopTex:SetAtlas("minimal-scrollbar-track-top")
    trackTopTex:SetSize(BAR_W, CAP_H)
    trackTopTex:SetPoint("TOP")

    local trackBotTex = track:CreateTexture(nil, "BACKGROUND")
    trackBotTex:SetAtlas("minimal-scrollbar-track-bottom")
    trackBotTex:SetSize(BAR_W, CAP_H)
    trackBotTex:SetPoint("BOTTOM")

    local trackMidTex = track:CreateTexture(nil, "BACKGROUND")
    trackMidTex:SetAtlas("!minimal-scrollbar-track-middle", true)
    trackMidTex:SetWidth(BAR_W)
    trackMidTex:SetPoint("TOP", trackTopTex, "BOTTOM")
    trackMidTex:SetPoint("BOTTOM", trackBotTex, "TOP")

    -- Thumb (draggable)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)

    local thumbTopTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top")
    thumbTopTex:SetSize(BAR_W, CAP_H)
    thumbTopTex:SetPoint("TOP")

    local thumbBotTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom")
    thumbBotTex:SetSize(BAR_W, CAP_H)
    thumbBotTex:SetPoint("BOTTOM")

    local thumbMidTex = thumb:CreateTexture(nil, "ARTWORK")
    thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle")
    thumbMidTex:SetWidth(BAR_W)
    thumbMidTex:SetPoint("TOP", thumbTopTex, "BOTTOM")
    thumbMidTex:SetPoint("BOTTOM", thumbBotTex, "TOP")

    local function SetThumbNormal()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top")
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom")
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle")
    end
    local function SetThumbOver()
        thumbTopTex:SetAtlas("minimal-scrollbar-small-thumb-top-over")
        thumbBotTex:SetAtlas("minimal-scrollbar-small-thumb-bottom-over")
        thumbMidTex:SetAtlas("minimal-scrollbar-small-thumb-middle-over")
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
        local ratio = (range > 0) and (scrollPos / range) or 0

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

    -- Defer UpdateThumb on show so track layout is resolved first
    bar:SetScript("OnShow", function(self)
        C_Timer.After(0, function()
            if self:IsShown() then self:UpdateThumb() end
        end)
    end)

    bar:Hide()
    return bar
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
