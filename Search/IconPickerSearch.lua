local _, ns = ...

-- A search bar inside the game's own macro icon picker (GitHub #22): the
-- @icons grid covers finding an icon first, this covers the player already
-- inside the macro UI with the picker open. Same data layer, same query
-- syntax (IconSearch.lua).
--
-- Mechanism: the picker template resolves its icons through popup-level
-- accessors (GetIconByIndex / GetNumIcons / GetIndexOfIcon). While a query
-- is active we overlay those on the MacroPopupFrame INSTANCE with a
-- filtered FileDataID list and ask the selector to re-render; clearing the
-- query falls straight through to the original accessors. The popup's own
-- icon data provider is never touched, so the stock picker (and anything
-- else driving it) keeps working exactly as shipped.

local IconSearch = ns.IconSearch

local CreateFrame = CreateFrame
local C_AddOns = C_AddOns
local pcall = pcall
local wipe = wipe

local filtered = nil        -- active filtered fdid array, nil = no search
local filterScratch = {}    -- master-index scratch for IconSearch:Filter

local function ApplyPickerSearch(popup, searchBox)
    local query = (searchBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then
        filtered = nil
    else
        local n = IconSearch:Filter(query, filterScratch)
        filtered = searchBox.efResults or {}
        searchBox.efResults = filtered
        wipe(filtered)
        for i = 1, n do
            local _, fdid = IconSearch:GetIcon(filterScratch[i])
            filtered[i] = fdid
        end
    end

    local selectedIcon = popup.BorderBox
        and popup.BorderBox.SelectedIconArea
        and popup.BorderBox.SelectedIconArea.SelectedIconButton
        and popup.BorderBox.SelectedIconArea.SelectedIconButton:GetIconTexture()
    popup.IconSelector:UpdateSelections()
    local index = selectedIcon and popup:GetIndexOfIcon(selectedIcon)
    popup.IconSelector:SetSelectedIndex(index)
    if index then
        pcall(popup.IconSelector.ScrollToSelectedIndex, popup.IconSelector)
    end
    pcall(popup.SetSelectedIconText, popup)
end

local function InstallAccessorOverlay(popup)
    local origGetByIndex = popup.GetIconByIndex
    local origGetNum = popup.GetNumIcons
    local origIndexOf = popup.GetIndexOfIcon
    function popup:GetIconByIndex(index)
        if filtered then return filtered[index] end
        return origGetByIndex(self, index)
    end
    function popup:GetNumIcons()
        if filtered then return #filtered end
        return origGetNum(self)
    end
    function popup:GetIndexOfIcon(icon)
        if not filtered then return origIndexOf(self, icon) end
        for i = 1, #filtered do
            if filtered[i] == icon then return i end
        end
        return nil
    end
    -- Remembered so the per-open audit can tell when another addon has
    -- overwritten these instance methods after us.
    popup.efInstalledAccessors = {
        popup.GetIconByIndex, popup.GetNumIcons, popup.GetIndexOfIcon,
    }
end

-- One search bar per picker, and ours is the one that yields. Run at every
-- popup open, because another addon can attach its bar or replace the icon
-- accessors at any later point (load-on-demand addons, first-show lazies):
--   a. our accessor overlay was displaced -> our filter can no longer reach
--      the selector, so the box would be dead weight; stand down.
--   b. a foreign EditBox sits directly on the popup (the stock editboxes
--      live inside BorderBox, so any direct EditBox child that is not ours
--      is another addon's search bar); stand down while it exists.
-- Symmetric: if the foreign bar disappears (its addon's feature toggled
-- off), ours comes back on the next open.
local function AuditCoexistence(popup)
    local searchBox = popup.efSearchBox
    if not searchBox then return end
    if EasyFind.db and EasyFind.db.macroPickerSearch == false then
        filtered = nil
        searchBox:SetText("")
        searchBox:Hide()
        return
    end
    local mine = popup.efInstalledAccessors
    local displaced = not mine
        or popup.GetIconByIndex ~= mine[1]
        or popup.GetNumIcons ~= mine[2]
        or popup.GetIndexOfIcon ~= mine[3]
    local foreignBar = false
    if not displaced then
        for i = 1, select("#", popup:GetChildren()) do
            local child = select(i, popup:GetChildren())
            if child ~= searchBox and child.GetObjectType
               and child:GetObjectType() == "EditBox" and child:IsShown() then
                foreignBar = true
                break
            end
        end
    end
    if displaced or foreignBar then
        filtered = nil
        searchBox:SetText("")
        searchBox:Hide()
    else
        searchBox:Show()
    end
end

local function AttachPickerSearch(popup)
    if not (popup and popup.IconSelector and popup.BorderBox) then return end
    if popup.efSearchBox then return end
    -- Another addon already put a search box on this picker: one box per
    -- popup. Theirs wins; ours stays on the @icons grid.
    if popup.SearchBox then return end
    if not (popup.GetIconByIndex and popup.GetNumIcons and popup.GetIndexOfIcon) then return end

    InstallAccessorOverlay(popup)

    local searchBox = CreateFrame("EditBox", "EasyFindPickerSearchBox", popup, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetHeight(18)
    searchBox:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 68, 15)
    searchBox:SetPoint("RIGHT", popup.BorderBox.OkayButton, "LEFT", -8, 0)
    searchBox:SetFrameLevel(popup.BorderBox:GetFrameLevel() + 1)

    local label = searchBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("RIGHT", searchBox, "LEFT", -6, 0)
    label:SetText((_G["SEARCH"] or "Search") .. ":")

    searchBox:SetScript("OnTextChanged", function(self, userInput)
        if not userInput and (self:GetText() or "") ~= "" then return end
        ApplyPickerSearch(popup, self)
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then
            self:SetText("")
        else
            self:ClearFocus()
        end
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    popup:HookScript("OnHide", function()
        filtered = nil
        searchBox:SetText("")
    end)
    popup:HookScript("OnShow", function(self)
        AuditCoexistence(self)
    end)

    popup.efSearchBox = searchBox
end

-- Attach when the macro UI actually loads. EventUtil ships in the base UI;
-- the ADDON_LOADED fallback keeps this safe if it ever moves.
local function WatchForMacroUI()
    -- The established picker-search addon hooks this same popup with its
    -- own box and provider handling; ours would double up, so it defers.
    local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
    if IsAddOnLoaded and IsAddOnLoaded("LargerMacroIconSelection") then return end

    local function OnMacroUILoaded()
        AttachPickerSearch(_G.MacroPopupFrame)
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

local IconPickerSearch = {}
ns.IconPickerSearch = IconPickerSearch

function IconPickerSearch:Initialize()
    WatchForMacroUI()
end

-- Re-run the coexistence/setting audit now (the options toggle flips the
-- setting while the picker may be open; the OnShow audit alone would not
-- apply until the next open).
function IconPickerSearch:Refresh()
    local popup = _G.MacroPopupFrame
    if popup and popup.efSearchBox and popup:IsShown() then
        AuditCoexistence(popup)
        popup.IconSelector:UpdateSelections()
    end
end

return IconPickerSearch
