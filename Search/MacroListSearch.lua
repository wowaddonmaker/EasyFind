local _, ns = ...

-- A search bar in the game's own macro window, filtering the visible macro
-- grid on the CURRENT tab (general or character) to macros whose name or
-- body matches. Sits in the title strip (portrait to close button).
--
-- Mechanism, same discipline as the icon picker's bar: the macro selector
-- resolves its content through instance-level accessors
-- (getSelectionByIndex / getNumSelections, installed by
-- SetSelectionsDataProvider). While a query is active we overlay those two
-- with a filtered view of the ORIGINAL selection values and ask the
-- selector to re-render; clearing the query falls straight through to the
-- originals. Blizzard's own data provider is never touched, and because
-- the filtered view carries original selection VALUES (not slot numbers),
-- clicking a filtered button selects the right macro.

local Utils = ns.Utils
local slower, sfind = Utils.slower, Utils.sfind

local CreateFrame = CreateFrame
local GetMacroInfo = GetMacroInfo
local hooksecurefunc = hooksecurefunc
local select = select

local filtered = nil
local origByIndex, origNum
local applying = false

local function MacroMatches(frame, slot, value, query)
    -- The selection value is the macro's data index when numeric; the
    -- tab-relative fallback covers a value shape change.
    local name, _, body
    local macroIndex = type(value) == "number" and value or nil
    if macroIndex then
        name, _, body = GetMacroInfo(macroIndex)
    end
    if not name then
        name, _, body = GetMacroInfo((frame.macroBase or 0) + slot)
    end
    if not name then return false end
    if sfind(slower(name), query, 1, true) then return true end
    return body and sfind(slower(body), query, 1, true) or false
end

local function ApplyMacroSearch(frame, searchBox)
    local sel = frame.MacroSelector
    if not (sel and origByIndex and origNum) then return end
    local query = slower((searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if query == "" then
        filtered = nil
    else
        filtered = searchBox.efResults or {}
        searchBox.efResults = filtered
        wipe(filtered)
        -- The originals are plain closures taking (index) alone -- proven
        -- by a live error where a passed self arrived as the index.
        local total = origNum() or 0
        for slot = 1, total do
            local value = origByIndex(slot)
            if value ~= nil and MacroMatches(frame, slot, value, query) then
                filtered[#filtered + 1] = value
            end
        end
    end
    if applying then return end
    applying = true
    if sel.UpdateSelections then sel:UpdateSelections() end
    applying = false
end

local function InstallOverlay(sel)
    origByIndex = sel.getSelectionByIndex
    origNum = sel.getNumSelections
    if not (origByIndex and origNum) then return false end
    -- The accessors are installed per data-provider push and may be plain
    -- closures or self-taking; the index rides as the LAST argument either
    -- way, and pass-through preserves the original call shape.
    sel.getSelectionByIndex = function(...)
        if filtered then
            local idx = select(select("#", ...), ...)
            return filtered[idx]
        end
        return origByIndex(...)
    end
    sel.getNumSelections = function(...)
        if filtered then return #filtered end
        return origNum(...)
    end
    return true
end

-- A data-provider re-push (tab switch, macro create/delete) reinstalls
-- Blizzard's accessors over ours; capture the fresh originals and re-wrap.
local function ReinstallIfDisplaced(sel)
    if not sel then return end
    local mine = sel.efMacroSearchAccessors
    if mine and sel.getSelectionByIndex == mine[1] and sel.getNumSelections == mine[2] then
        return
    end
    if InstallOverlay(sel) then
        sel.efMacroSearchAccessors = { sel.getSelectionByIndex, sel.getNumSelections }
    end
end

local function AttachMacroListSearch(frame)
    if not frame or frame.efMacroListSearch then return end
    local sel = frame.MacroSelector
    -- Only the selector itself is required here: its lowercase accessors
    -- are installed by the DATA-PROVIDER push on first show, after this
    -- ADDON_LOADED attach, so they are captured lazily (ReinstallIfDisplaced
    -- on show and on every keystroke), never demanded up front -- requiring
    -- them here silently skipped the whole attach.
    if not (sel and sel.UpdateSelections) then
        return
    end
    -- Another addon's search box on the macro window wins; one bar per frame.
    for i = 1, select("#", frame:GetChildren()) do
        local child = select(i, frame:GetChildren())
        if child.GetObjectType and child:GetObjectType() == "EditBox" then
            return
        end
    end

    ReinstallIfDisplaced(sel)

    local searchBox = CreateFrame("EditBox", "EasyFindMacroListSearchBox", frame, "SearchBoxTemplate")
    searchBox:SetAutoFocus(false)
    -- The title strip: right of the portrait, left of the close button.
    -- The stock title text gives way to the bar (its meaning is obvious
    -- from the window itself).
    local title = frame.GetTitleText and frame:GetTitleText()
    if title then title:Hide() end
    -- Fully determined rect in the title strip (a TOPLEFT + a RIGHT-center
    -- pair over-constrained the vertical and stretched the box down over
    -- the tabs).
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 70, -7)
    searchBox:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -32, -27)
    searchBox:SetFrameLevel(frame:GetFrameLevel() + 10)

    searchBox:SetScript("OnTextChanged", function(self, userInput)
        if _G.SearchBoxTemplate_OnTextChanged then
            _G.SearchBoxTemplate_OnTextChanged(self)
        end
        if not userInput and (self:GetText() or "") ~= "" then return end
        ReinstallIfDisplaced(frame.MacroSelector)
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

    -- Tab switches and macro list changes re-push the provider: re-wrap the
    -- fresh accessors and re-run the active query against the new tab.
    local function Reapply()
        if applying then return end
        ReinstallIfDisplaced(frame.MacroSelector)
        if (searchBox:GetText() or "") ~= "" then
            ApplyMacroSearch(frame, searchBox)
        end
    end
    if frame.SetAccountMacros then hooksecurefunc(frame, "SetAccountMacros", Reapply) end
    if frame.SetCharacterMacros then hooksecurefunc(frame, "SetCharacterMacros", Reapply) end
    if frame.Update then hooksecurefunc(frame, "Update", Reapply) end

    frame:HookScript("OnShow", function()
        ReinstallIfDisplaced(frame.MacroSelector)
    end)
    frame:HookScript("OnHide", function()
        filtered = nil
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
