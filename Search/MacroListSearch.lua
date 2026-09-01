local _, ns = ...

-- A search bar in the game's own macro window, filtering the visible macro
-- grid on the CURRENT tab (general or character) to macros whose name or
-- body matches. Sits in the title strip (portrait to close button).
--
-- Mechanism: visual filtering only. The macro selector's identity lives in
-- each button's positional elementData (probe-verified: elementData is the
-- slot number; the accessor payload is a display string), so any accessor
-- or data overlay reorders payloads over fixed identities and breaks both
-- icons and click targets. Instead, non-matching buttons DIM while a query
-- is active; matches stay full strength and every button keeps its true
-- macro. A light ticker (only while the window is shown AND a query is
-- typed) re-applies after scrolls and Blizzard redraws, and self-cancels
-- per the hot-path handler rules.

local Utils = ns.Utils
local slower, sfind = Utils.slower, Utils.sfind

local CreateFrame = CreateFrame
local GetMacroInfo = GetMacroInfo
local pcall = pcall

local filterActive = false
local applying = false

local function MacroMatches(frame, slot, query)
    local name, _, body = GetMacroInfo((frame.macroBase or 0) + slot)
    if not name then return false end
    if sfind(slower(name), query, 1, true) then return true end
    return body and sfind(slower(body), query, 1, true) or false
end

local function ApplyMacroSearch(frame, searchBox)
    local sel = frame.MacroSelector
    if not (sel and sel.SetSelectionsArray) then return end
    local query = slower((searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if query == "" then
        if filterActive then
            filterActive = false
            -- Blizzard's own update re-pushes its data provider: the one
            -- restore path that cannot drift from the stock window.
            applying = true
            if frame.Update then pcall(frame.Update, frame) end
            applying = false
        end
        return
    end
    local slots = searchBox.efSlots or {}
    searchBox.efSlots = slots
    wipe(slots)
    local total = sel.numMacros or frame.macroMax or 0
    for slot = 1, total do
        if MacroMatches(frame, slot, query) then
            slots[#slots + 1] = slot
        end
    end
    filterActive = true
    applying = true
    -- True filtering with identity intact: SetSelectionsArray drives the
    -- provider and accessors together, and element identity IS the array
    -- value -- each shown button carries its real slot number, so icons
    -- and clicks resolve to the right macro by construction.
    pcall(sel.SetSelectionsArray, sel, slots)
    applying = false
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
    searchBox:SetHeight(20)
    searchBox:SetWidth(frame:GetWidth() - 70 - 40)
    if frame.CloseButton then
        searchBox:SetPoint("RIGHT", frame.CloseButton, "LEFT", -4, 0)
    else
        searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -32, -6)
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

    -- Tab switches and Blizzard updates re-push the stock provider over an
    -- active filter: re-run the query so the filtered view wins.
    local function Reapply()
        if applying then return end
        if (searchBox:GetText() or "") ~= "" then
            ApplyMacroSearch(frame, searchBox)
        end
    end
    if frame.SetAccountMacros then hooksecurefunc(frame, "SetAccountMacros", Reapply) end
    if frame.SetCharacterMacros then hooksecurefunc(frame, "SetCharacterMacros", Reapply) end
    if frame.Update then hooksecurefunc(frame, "Update", Reapply) end

    frame:HookScript("OnHide", function()
        filterActive = false
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
