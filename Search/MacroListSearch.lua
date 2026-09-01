local _, ns = ...

-- A search bar in the game's own macro window, filtering the visible macro
-- grid on the CURRENT tab (general or character) to macros whose name or
-- body matches. Sits in the title strip, centered on the close button.
--
-- Identity model: while a query is active, the selector gets OUR data
-- provider, returning one filtered entry table per shown position, and OUR
-- setup callback stamps each rendered button with the entry's TRUE macro
-- index (SetSelectionIndex + GetElementData). Every downstream consumer
-- (click, SaveMacro, SelectMacro, the editor pane, selection highlight)
-- then operates on true indices with no remapping anywhere. MacroFrame's
-- Update is parked on a no-op for the duration (restored on clear) so
-- saves, UPDATE_MACROS, and tab plumbing cannot shove the stock provider
-- back underneath the filter; tab switches and macro changes re-run the
-- search instead.

local Utils = ns.Utils
local slower, sfind = Utils.slower, Utils.sfind

local CreateFrame = CreateFrame
local GetMacroInfo = GetMacroInfo
local GetNumMacros = GetNumMacros
local pcall = pcall
local type = type

local BUILD = "identity-remap-v10"

local filtered = {}      -- reused entry tables: {index, name, texture}
local filteredCount = 0
local searching = false
local origUpdate = nil

local function NoOpUpdate() end

local function FilteredGetMacroInfo(selectionIndex)
    if selectionIndex > filteredCount then return nil end
    return filtered[selectionIndex]
end

local function FilteredGetNumMacros()
    return filteredCount
end

local function CollectMatches(frame, query)
    local base = frame.macroBase or 0
    local numAccount, numCharacter = GetNumMacros()
    local total = base == 0 and (numAccount or 0) or (numCharacter or 0)
    filteredCount = 0
    for slot = 1, total do
        local name, texture, body = GetMacroInfo(base + slot)
        if name and (sfind(slower(name), query, 1, true)
                or (body and sfind(slower(body), query, 1, true))) then
            filteredCount = filteredCount + 1
            local entry = filtered[filteredCount]
            if not entry then
                entry = {}
                filtered[filteredCount] = entry
            end
            entry.index, entry.name, entry.texture = slot, name, texture
        end
    end
    for i = filteredCount + 1, #filtered do
        filtered[i] = nil
    end
end

-- Replaces the stock setup callback for the life of the frame. The stock
-- payload is the GetMacroInfo multi-return (name string first); our
-- filtered provider hands over the entry table instead, and that branch
-- stamps the button with the entry's true index.
local function InitMacroButton(macroButton, _, name, texture)
    if type(name) == "table" then
        local entry = name
        macroButton.efTrueIndex = entry.index
        if not macroButton.efGetTrueIndex then
            -- GetElementData is an instance closure the scroll view installs
            -- per frame (not a mixin method): keep the original to restore,
            -- and NEVER nil the field -- the view's Release path calls it.
            macroButton.efOrigGetElementData = macroButton.GetElementData
            macroButton.efGetTrueIndex = function() return macroButton.efTrueIndex end
        end
        macroButton.GetElementData = macroButton.efGetTrueIndex
        if macroButton.SetSelectionIndex then
            macroButton:SetSelectionIndex(entry.index)
        end
        macroButton:SetIconTexture(entry.texture)
        macroButton.Name:SetText(entry.name)
        macroButton:Enable()
        return
    end
    if macroButton.efOrigGetElementData then
        macroButton.GetElementData = macroButton.efOrigGetElementData
    end
    if name then
        macroButton:SetIconTexture(texture)
        macroButton.Name:SetText(name)
        macroButton:Enable()
    else
        macroButton:SetIconTexture("")
        macroButton.Name:SetText("")
        macroButton:Disable()
    end
end

local function ResetMacroSearch(frame)
    if not searching then return end
    searching = false
    filteredCount = 0
    frame.Update = origUpdate
    origUpdate = nil
    if frame.Update then pcall(frame.Update, frame) end
end

local function ApplyMacroSearch(frame, searchBox)
    local sel = frame.MacroSelector
    if not (sel and sel.SetSelectionsDataProvider) then return end
    local query = slower((searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if query == "" then
        ResetMacroSearch(frame)
        return
    end
    if not searching then
        searching = true
        origUpdate = frame.Update
        frame.Update = NoOpUpdate
    end
    CollectMatches(frame, query)
    pcall(sel.SetSelectionsDataProvider, sel, FilteredGetMacroInfo, FilteredGetNumMacros)
    if frame.UpdateButtons then pcall(frame.UpdateButtons, frame) end
    -- Selection (and the editor pane a click would SAVE into) follows the
    -- filter: kept when the selected macro still matches, else the first
    -- match. Selected indices are true indices in both modes.
    if filteredCount > 0 and frame.SelectMacro then
        local current = sel.GetSelectedIndex and sel:GetSelectedIndex()
        for i = 1, filteredCount do
            if filtered[i].index == current then return end
        end
        pcall(frame.SelectMacro, frame, filtered[1].index, true)
    end
end

local function AttachMacroListSearch(frame)
    if not frame or frame.efMacroListSearch then return end
    local sel = frame.MacroSelector
    if not (sel and sel.SetSetupCallback) then return end

    sel:SetSetupCallback(InitMacroButton)

    local searchBox = CreateFrame("EditBox", "EasyFindMacroListSearchBox", frame, "SearchBoxTemplate")
    searchBox:SetAutoFocus(false)
    -- The stock title text gives way to the bar (the window's purpose is
    -- obvious from the window itself).
    local title = frame.GetTitleText and frame:GetTitleText()
    if title then title:Hide() end
    -- Vertically centered ON the close button by construction; width spans
    -- from right of the portrait to left of the X. The template's border
    -- art is fixed-size textures, so SetHeight cannot shrink it visually:
    -- scale the whole box and divide the on-screen width and gap by the
    -- scale to compensate.
    local scale = 0.75
    searchBox:SetScale(scale)
    searchBox:SetHeight(20)
    searchBox:SetWidth((frame:GetWidth() - 70 - 48) / scale)
    if frame.CloseButton then
        searchBox:SetPoint("RIGHT", frame.CloseButton, "LEFT", -26 / scale, 0)
    else
        searchBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -40 / scale, -8 / scale)
    end
    -- Above the header chrome: NineSlice and the title/portrait containers
    -- are child frames whose levels sit above the root's.
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

    -- Tab switches change macroBase under a parked Update; macro edits,
    -- creates, and deletes fire UPDATE_MACROS. Both re-run the live search.
    local function ResearchIfActive()
        if searching then
            ApplyMacroSearch(frame, searchBox)
        end
    end
    local tab1, tab2 = _G.MacroFrameTab1, _G.MacroFrameTab2
    if tab1 then tab1:HookScript("OnClick", ResearchIfActive) end
    if tab2 then tab2:HookScript("OnClick", ResearchIfActive) end

    searchBox:RegisterEvent("UPDATE_MACROS")
    searchBox:RegisterEvent("PLAYER_REGEN_DISABLED")
    searchBox:RegisterEvent("PLAYER_REGEN_ENABLED")
    searchBox:SetScript("OnEvent", function(self, event)
        if event == "UPDATE_MACROS" then
            ResearchIfActive()
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Macro writes are blocked in combat; a click while filtered
            -- would try to SaveMacro. Park the whole feature until regen.
            self:SetText("")
            self:ClearFocus()
            self:Disable()
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:Enable()
        end
    end)

    frame:HookScript("OnHide", function()
        searchBox:SetText("")
        ResetMacroSearch(frame)
    end)

    searchBox.efBuild = BUILD
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
