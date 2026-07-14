local _, ns = ...

local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local GetButtonText = Utils.GetButtonText
local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
local ClickButton = Utils.ClickButton
local select, pairs = Utils.select, Utils.pairs
local slower = Utils.slower
local mfloor = Utils.mfloor
local C_ToyBox = C_ToyBox

function Handlers:GetToyBoxFrame()
    local collections = _G["CollectionsJournal"]
    return _G["ToyBox"]
        or _G["ToyBoxFrame"]
        or (collections and collections.ToyBox)
        or (collections and collections.ToyBoxFrame)
end

function Handlers:GetToyBoxScrollBox()
    local toyBox = self:GetToyBoxFrame()
    if not toyBox then return nil end
    local iconsFrame = toyBox.iconsFrame or toyBox.IconsFrame
    if toyBox.ScrollBox then return toyBox.ScrollBox end
    if toyBox.ItemsScrollBox then return toyBox.ItemsScrollBox end
    if toyBox.List and toyBox.List.ScrollBox then return toyBox.List.ScrollBox end
    if toyBox.ScrollFrame and toyBox.ScrollFrame.ScrollBox then return toyBox.ScrollFrame.ScrollBox end
    if iconsFrame and iconsFrame.ScrollBox then return iconsFrame.ScrollBox end
    if iconsFrame and iconsFrame.scrollBox then return iconsFrame.scrollBox end
    if iconsFrame and iconsFrame.ScrollFrame and iconsFrame.ScrollFrame.ScrollBox then return iconsFrame.ScrollFrame.ScrollBox end
    if _G["ToyBoxScrollBox"] then return _G["ToyBoxScrollBox"] end
    local oldIcons = _G["ToyBoxIconsFrame"]
    if oldIcons and oldIcons.ScrollBox then return oldIcons.ScrollBox end
    return nil
end

function Handlers:GetToyDisplayFraction(itemID)
    if not (itemID and C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex) then
        return nil
    end
    local total = C_ToyBox.GetNumFilteredToys()
    for i = 1, total or 0 do
        if C_ToyBox.GetToyFromIndex(i) == itemID then
            return (total and total > 1) and ((i - 1) / (total - 1)) or 0
        end
    end
    return nil
end

function Handlers:GetToyDisplayIndex(itemID)
    if not (itemID and C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex) then
        return nil, nil
    end
    local total = C_ToyBox.GetNumFilteredToys()
    for i = 1, total or 0 do
        if C_ToyBox.GetToyFromIndex(i) == itemID then
            return i, total
        end
    end
    return nil, total
end

function Handlers:GetToyBoxButtonsPerPage(toyBox)
    local iconsFrame = toyBox and (toyBox.iconsFrame or toyBox.IconsFrame)
    local buttons = (iconsFrame and (iconsFrame.buttons or iconsFrame.Buttons))
        or (toyBox and (toyBox.buttons or toyBox.Buttons))
    if type(buttons) == "table" then
        local count = 0
        for _, button in pairs(buttons) do
            if button then count = count + 1 end
        end
        if count > 0 then return count end
    end
    local perPage = _G["TOYS_PER_PAGE"]
    if type(perPage) == "number" and perPage > 0 then return perPage end
    return 18
end

function Handlers:SetToyBoxPageForItem(itemID)
    local index = self:GetToyDisplayIndex(itemID)
    if not index then return nil end

    local toyBox = self:GetToyBoxFrame()
    local perPage = self:GetToyBoxButtonsPerPage(toyBox)
    if not perPage or perPage <= 0 then return nil end

    local page = mfloor((index - 1) / perPage) + 1
    if toyBox then
        toyBox.page = page
        toyBox.currentPage = page
    end

    local paging = toyBox and (toyBox.PagingFrame or toyBox.pagingFrame)
    if paging and paging.SetCurrentPage then
        pcall(paging.SetCurrentPage, paging, page)
    end

    local updatePage = _G["ToyBox_UpdatePage"]
    if updatePage then
        pcall(updatePage, page)
        if toyBox then pcall(updatePage, toyBox, page) end
    end

    local updateButtons = _G["ToyBox_UpdateButtons"]
    if updateButtons then
        pcall(updateButtons)
        if toyBox then pcall(updateButtons, toyBox) end
    end

    return page
end

function Handlers:ToyElementMatches(edata, itemID, toyName)
    if not edata then return false end
    if type(edata) == "number" then return itemID and edata == itemID end
    if type(edata) ~= "table" then return false end
    local edataItemID = edata.itemID or edata.itemId or edata.toyItemID
        or edata.toyID or edata.toyId or edata.id
    if itemID and edataItemID == itemID then return true end
    local item = edata.item or edata.toy or edata.info
    edataItemID = item and (item.itemID or item.itemId or item.toyItemID
        or item.toyID or item.toyId or item.id)
    if itemID and edataItemID == itemID then return true end
    local name = edata.name or edata.toyName or edata.itemName or edata.displayName
        or (item and (item.name or item.toyName or item.itemName or item.displayName))
    return toyName and name and slower(name) == toyName
end

function Handlers:ToyFrameMatches(frame, itemID, toyName)
    if not frame then return false end
    local ok, edata = pcall(function()
        return frame.GetElementData and frame:GetElementData()
    end)
    if ok and self:ToyElementMatches(edata, itemID, toyName) then return true end
    if itemID and (frame.itemID == itemID or frame.itemId == itemID
        or frame.toyItemID == itemID or frame.toyID == itemID
        or frame.toyId == itemID or frame.id == itemID) then
        return true
    end
    local text = GetButtonText(frame)
    return toyName and text and slower(text) == toyName
end

function Handlers:FindToyButtonInFrame(frame, itemID, toyName, depth)
    if not frame or (depth or 0) > 7 then return nil end
    if frame.IsShown and not frame:IsShown() then return nil end

    if self:ToyFrameMatches(frame, itemID, toyName) and frame.GetLeft then
        return frame
    end

    local buttons = frame.buttons or frame.Buttons
    if type(buttons) == "table" then
        for _, button in pairs(buttons) do
            local found = self:FindToyButtonInFrame(button, itemID, toyName, (depth or 0) + 1)
            if found then return found end
        end
    end

    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            local found = self:FindToyButtonInFrame(child, itemID, toyName, (depth or 0) + 1)
            if found then return found end
        end
    end
    return nil
end

function Handlers:RevealToyInToyBox(data)
    if not (data and data.toyItemID) then return nil end

    if C_ToyBox then
        if C_ToyBox.SetCollectedShown then pcall(C_ToyBox.SetCollectedShown, true) end
        if C_ToyBox.SetUncollectedShown then pcall(C_ToyBox.SetUncollectedShown, false) end
        if C_ToyBox.SetAllSourceTypeFilters then pcall(C_ToyBox.SetAllSourceTypeFilters, true) end
        if C_ToyBox.SetAllExpansionTypeFilters then pcall(C_ToyBox.SetAllExpansionTypeFilters, true) end
        if C_ToyBox.SetFilterString then pcall(C_ToyBox.SetFilterString, "") end
        if C_ToyBox.ForceToyRefilter then pcall(C_ToyBox.ForceToyRefilter) end
    end

    local toyBox = self:GetToyBoxFrame()
    if toyBox then
        self:SetEditBoxTextIfPresent(toyBox.SearchBox or toyBox.searchBox, "")
    end

    local toyName = data.name and slower(data.name)
    self:SetToyBoxPageForItem(data.toyItemID)

    if toyBox then
        local visibleButton = self:FindToyButtonInFrame(toyBox, data.toyItemID, toyName, 0)
        if visibleButton then return visibleButton end
    end

    local scrollBox = self:GetToyBoxScrollBox()
    if scrollBox then
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return self:ToyElementMatches(edata, data.toyItemID, toyName)
        end, self:GetToyDisplayFraction(data.toyItemID))
        local btn = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return self:ToyFrameMatches(frame, data.toyItemID, toyName)
        end)
        if btn then return btn end
    end

    if toyBox then
        local visibleButton = self:FindToyButtonInFrame(toyBox, data.toyItemID, toyName, 0)
        if visibleButton then return visibleButton end
    end

    if toyBox and toyName then
        return SearchFrameTreeFuzzy(toyBox, toyName)
    end
    return nil
end

-- Step-by-step guide to the toy (Guide option): micro button and tab via
-- the user's own clicks, then the reveal highlights the tile. Mirrors
-- BuildPetJournalGuideData.
function Handlers:BuildToyBoxGuideData(data)
    return {
        name = data.name,
        steps = {
            { buttonFrame = "CollectionsMicroButton" },
            { waitForFrame = "CollectionsJournal", tabIndex = 3 },
            {
                waitForFrame = "CollectionsJournal",
                toyItemID = data.toyItemID,
                name = data.name,
            },
        },
    }
end

function Handlers:OpenToyInToyBox(data)
    if not data or not data.toyItemID then return end
    local highlight = ns.Highlight
    local TOY_TAB = 3

    local function step(attempt)
        local journal = _G["CollectionsJournal"]
        if not (journal and journal:IsShown()) then
            local micro = _G["CollectionsMicroButton"]
            if micro then ClickButton(micro) end
            if attempt < 30 then
                Utils.SafeAfter(0.05, function() step(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("CollectionsJournal", TOY_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("CollectionsJournal", TOY_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                Utils.SafeAfter(0, function() step(attempt + 1) end)
            end
            return
        end
        local row = self:RevealToyInToyBox(data)
        if row and self:HighlightRevealedFrame(row) then return end
        if attempt < 30 then
            Utils.SafeAfter(0.05, function() step(attempt + 1) end)
        end
    end

    step(1)
end

-- Open PlayerSpellsFrame to the Talents tab and drive Blizzard's own
-- search box at PlayerSpellsFrame.TalentsFrame.SearchBox with the
-- talent name. The game's native search highlights matching nodes
-- with the spyglass icon -- no need for our own highlight pass.
-- Cleanest path: matches the visual the player already recognizes
