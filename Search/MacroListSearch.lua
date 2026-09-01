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
local C_Timer = C_Timer
local pcall = pcall

local DIM_ALPHA = 0.12

local matchSet = nil  -- [slotNumber] = true while a query is active
local ticker

local function MacroMatches(frame, slot, query)
    local name, _, body = GetMacroInfo((frame.macroBase or 0) + slot)
    if not name then return false end
    if sfind(slower(name), query, 1, true) then return true end
    return body and sfind(slower(body), query, 1, true) or false
end

local function ApplyButtonAlphas(frame)
    local sel = frame.MacroSelector
    local scroll = sel and sel.ScrollBox
    if not (scroll and scroll.EnumerateFrames) then return end
    for _, btn in scroll:EnumerateFrames() do
        local slot = btn.GetElementData and btn:GetElementData()
        if type(slot) ~= "number" then slot = btn.selectionIndex end
        if type(slot) == "number" then
            local dim = matchSet and not matchSet[slot]
            btn:SetAlpha(dim and DIM_ALPHA or 1)
        end
    end
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function StartTicker(frame)
    if ticker then return end
    ticker = C_Timer.NewTicker(0.1, function()
        local ok = pcall(function()
            if not frame:IsShown() or not matchSet then
                StopTicker()
                if not matchSet then ApplyButtonAlphas(frame) end
                return
            end
            ApplyButtonAlphas(frame)
        end)
        if not ok then StopTicker() end
    end)
end

local function ApplyMacroSearch(frame, searchBox)
    local query = slower((searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if query == "" then
        matchSet = nil
        StopTicker()
        ApplyButtonAlphas(frame)
        return
    end
    matchSet = searchBox.efMatchSet or {}
    searchBox.efMatchSet = matchSet
    wipe(matchSet)
    local total = (frame.MacroSelector and frame.MacroSelector.numMacros)
        or frame.macroMax or 0
    for slot = 1, total do
        if MacroMatches(frame, slot, query) then
            matchSet[slot] = true
        end
    end
    ApplyButtonAlphas(frame)
    StartTicker(frame)
end

local function AttachMacroListSearch(frame)
    if not frame or frame.efMacroListSearch then return end

    local searchBox = CreateFrame("EditBox", "EasyFindMacroListSearchBox", frame, "SearchBoxTemplate")
    searchBox:SetAutoFocus(false)
    -- The stock title text gives way to the bar (the window's purpose is
    -- obvious from the window itself).
    local title = frame.GetTitleText and frame:GetTitleText()
    if title then title:Hide() end
    searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 70, -7)
    searchBox:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -32, -27)
    searchBox:SetFrameLevel(frame:GetFrameLevel() + 10)

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

    -- Tab switches change macroBase: re-run the active query for the new tab.
    local function Reapply()
        if (searchBox:GetText() or "") ~= "" then
            ApplyMacroSearch(frame, searchBox)
        end
    end
    if frame.SetAccountMacros then hooksecurefunc(frame, "SetAccountMacros", Reapply) end
    if frame.SetCharacterMacros then hooksecurefunc(frame, "SetCharacterMacros", Reapply) end

    frame:HookScript("OnHide", function()
        matchSet = nil
        StopTicker()
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
