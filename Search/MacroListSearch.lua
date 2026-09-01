local _, ns = ...

-- A search bar in the game's own macro window, filtering the visible macro
-- grid on the CURRENT tab (general or character) to macros whose name or
-- body matches. Sits in the title strip (portrait to close button).
--
-- Mechanism (from the Blizzard_MacroUI source, not inference): the
-- selector's data provider is MacroFrameGetMacroInfo, whose accessor
-- returns (name, texture, body) for a POSITION, buttons render purely
-- from those returns via the setup callback, and every click funnels
-- through MacroFrame:GetMacroDataIndex(position) to reach the real
-- macro. True filtering is therefore two position remaps kept in sync:
-- the accessor overlay forwards ALL provider returns for the mapped
-- slot (an earlier build forwarded one value and rendered garbage),
-- and the GetMacroDataIndex overlay maps a clicked position to its
-- true slot. Clearing the query falls straight through to the
-- originals.

local Utils = ns.Utils
local slower, sfind = Utils.slower, Utils.sfind

local CreateFrame = CreateFrame
local GetMacroInfo = GetMacroInfo
local hooksecurefunc = hooksecurefunc
local select = select
local pcall = pcall

local filterSlots = nil  -- [shownPosition] = true slot, while a query is active
local origByIndex, origNum

local function MacroMatches(frame, slot, query)
    local name, _, body = GetMacroInfo((frame.macroBase or 0) + slot)
    if not name then return false end
    if sfind(slower(name), query, 1, true) then return true end
    return body and sfind(slower(body), query, 1, true) or false
end

local function InstallOverlay(frame, sel)
    origByIndex = sel.getSelectionByIndex
    origNum = sel.getNumSelections
    if not (origByIndex and origNum) then return false end
    -- Plain (index) closures, index as the last argument either way.
    sel.getSelectionByIndex = function(...)
        local idx = select(select("#", ...), ...)
        if filterSlots then
            local slot = filterSlots[idx]
            if not slot then return nil end
            return origByIndex(slot)
        end
        return origByIndex(idx)
    end
    sel.getNumSelections = function(...)
        if filterSlots then return #filterSlots end
        return origNum(...)
    end
    if not frame.efMacroDataIndexWrapped and frame.GetMacroDataIndex then
        frame.efMacroDataIndexWrapped = true
        local origDataIndex = frame.GetMacroDataIndex
        frame.GetMacroDataIndex = function(self, index)
            if filterSlots and filterSlots[index] then
                return origDataIndex(self, filterSlots[index])
            end
            return origDataIndex(self, index)
        end
    end
    return true
end

-- Tab switches and updates re-push the provider, reinstalling Blizzard's
-- accessors over ours: capture the fresh originals and re-wrap.
local function ReinstallIfDisplaced(frame)
    local sel = frame.MacroSelector
    if not sel then return end
    local mine = sel.efMacroSearchAccessors
    if mine and sel.getSelectionByIndex == mine[1] and sel.getNumSelections == mine[2] then
        return
    end
    if InstallOverlay(frame, sel) then
        sel.efMacroSearchAccessors = { sel.getSelectionByIndex, sel.getNumSelections }
    end
end

local reapplying = false

local function ApplyMacroSearch(frame, searchBox)
    local sel = frame.MacroSelector
    if not (sel and sel.UpdateSelections) then return end
    ReinstallIfDisplaced(frame)
    -- The TRUE slot currently selected, resolved through the outgoing map,
    -- so the selection (and the editor pane below) can follow the filter.
    local prevPos = sel.GetSelectedIndex and sel:GetSelectedIndex()
    local prevTrue = prevPos and (filterSlots and filterSlots[prevPos] or prevPos)
    local query = slower((searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if query == "" then
        filterSlots = nil
    else
        filterSlots = searchBox.efSlots or {}
        searchBox.efSlots = filterSlots
        wipe(filterSlots)
        local total = origNum and origNum() or 0
        for slot = 1, total do
            if MacroMatches(frame, slot, query) then
                filterSlots[#filterSlots + 1] = slot
            end
        end
    end
    pcall(sel.UpdateSelections, sel)
    -- Sync the selection to the new view: keep the same macro when it
    -- still matches, else take the first match -- otherwise the editor
    -- pane keeps showing whatever was selected before the filter.
    if frame.SelectMacro then
        local target
        if filterSlots then
            for i = 1, #filterSlots do
                if filterSlots[i] == prevTrue then target = i break end
            end
            if not target and #filterSlots > 0 then target = 1 end
        else
            target = prevTrue
        end
        if target then
            reapplying = true
            pcall(frame.SelectMacro, frame, target)
            reapplying = false
        end
    end
end

local function AttachMacroListSearch(frame)
    if not frame or frame.efMacroListSearch then return end

    local searchBox = CreateFrame("EditBox", "EasyFindMacroListSearchBox", frame, "SearchBoxTemplate")
    searchBox:SetAutoFocus(false)
    -- The stock title text gives way to the bar (the window's purpose is
    -- obvious from the window itself).
    local title = frame.GetTitleText and frame:GetTitleText()
    if title then title:Hide() end
    -- Vertically centered ON the close button by construction (corner
    -- anchoring kept landing the bar below the X's line); width spans from
    -- right of the portrait to left of the X.
    searchBox:SetHeight(16)
    searchBox:SetWidth(frame:GetWidth() - 70 - 48)
    if frame.CloseButton then
        searchBox:SetPoint("RIGHT", frame.CloseButton, "LEFT", -12, 0)
    else
        searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -40, -8)
    end
    -- Above every header chrome frame: the NineSlice border band and the
    -- portrait/title containers are CHILD FRAMES whose levels sit above the
    -- root's, so a root-relative +10 still rendered the box underneath the
    -- title bar art.
    local topLevel = frame:GetFrameLevel()
    for _, chrome in next, { frame.NineSlice, frame.TitleContainer, frame.PortraitContainer } do
        if chrome and chrome.GetFrameLevel then
            local lvl = chrome:GetFrameLevel()
            if lvl > topLevel then topLevel = lvl end
        end
    end
    searchBox:SetFrameLevel(topLevel + 5)

    searchBox:SetScript("OnTextChanged", function(self, userInput)
        if _G.SearchBoxTemplate_OnTextChanged then
            _G.SearchBoxTemplate_OnTextChanged(self)
        end
        if not userInput and (self:GetText() or "") ~= "" then return end
        ApplyMacroSearch(frame, self)
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then
            self:SetText("")
        else
            self:ClearFocus()
        end
    end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Tab switches, Blizzard updates, AND the click path (SelectMacro can
    -- re-push the stock provider, which un-filtered the grid mid-click)
    -- re-assert the filtered view. reapplying guards our own SelectMacro
    -- sync from recursing back in here.
    local function Reapply()
        if reapplying then return end
        ReinstallIfDisplaced(frame)
        if (searchBox:GetText() or "") ~= "" then
            reapplying = true
            ApplyMacroSearch(frame, searchBox)
            reapplying = false
        end
    end
    if frame.SetAccountMacros then hooksecurefunc(frame, "SetAccountMacros", Reapply) end
    if frame.SetCharacterMacros then hooksecurefunc(frame, "SetCharacterMacros", Reapply) end
    if frame.Update then hooksecurefunc(frame, "Update", Reapply) end
    if frame.SelectMacro then hooksecurefunc(frame, "SelectMacro", Reapply) end

    frame:HookScript("OnShow", function()
        ReinstallIfDisplaced(frame)
    end)
    frame:HookScript("OnHide", function()
        filterSlots = nil
        searchBox:SetText("")
    end)

    frame.efMacroListSearch = searchBox
end

local function WatchForMacroUI()
    local function OnMacroUILoaded()
        AttachMacroListSearch(_G.MacroFrame)
    end
    local EventUtil = _G.EventUtil
    if EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_MacroUI", OnMacroUILoaded)
        return
    end
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("ADDON_LOADED")
    watcher:SetScript("OnEvent", function(self, _, addonName)
        if addonName == "Blizzard_MacroUI" then
            self:UnregisterEvent("ADDON_LOADED")
            OnMacroUILoaded()
        end
    end)
end

WatchForMacroUI()
