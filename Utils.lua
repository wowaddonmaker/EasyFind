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
