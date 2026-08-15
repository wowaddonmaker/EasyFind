local _, ns = ...

local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local ClickButton = Utils.ClickButton
local select, pairs = Utils.select, Utils.pairs
local slower = Utils.slower
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

-- The toy box's own search EditBox (a SearchBoxTemplate). Field names have
-- moved between builds, so probe the same way as the frame/scroll box.
function Handlers:GetToyBoxSearchBox()
    local toyBox = self:GetToyBoxFrame()
    return (toyBox and (toyBox.SearchBox or toyBox.searchBox))
        or _G["ToyBoxSearchBox"]
end

-- Narrow the C-side filtered list to the one target toy so Blizzard renders
-- it alone on page one -- no paging needed. This is the whole navigation:
-- secure execution can only "click a frame", so reaching a distant page means
-- N clicks on the next-page button, and the engine caps secure actions per
-- hardware click at ~10. The toy box is 55 pages, so page-walking cannot
-- reach it (measured: a complete 53-line click chain
-- advanced only 10 pages). Collapsing the list sidesteps paging entirely.
--
-- SetFilterString is a C-side call and taint-free (Blizzard's own
-- TOYS_UPDATED handler re-renders securely, whoever set the filter), so it is
-- applied FIRST and does the actual filtering + render. The name is then
-- mirrored into the visible search box so the player can see why the list
-- narrowed and clear it themselves to browse. Setting the C-side filter first
-- means the box's own text-changed pass finds the filter already at that
-- value, so it has nothing new to render -- the taint-safest way to show it.
--
-- Nothing here is auto-undone: the search text is visible and the player owns
-- it (they clear it to browse). The collected/source/expansion filters are
-- touched ONLY when the clicked toy would otherwise be hidden: after narrowing
-- by name we check whether the target is in the filtered list, and only if it
-- is not (the player's toy box filters exclude it -- e.g. an uncollected toy
-- with "Not Collected" unchecked) do we widen every axis so the reveal can
-- show it. A toy already visible under the player's filters leaves them
-- exactly as they were.
--
-- Must run after the panel is shown: the toy box's open-init resets the
-- filter to its (empty) search box, so a filter set before the cold open is
-- clobbered.
function Handlers.ApplyToyBoxFilter(toyName, toyItemID)
    if not C_ToyBox then return end
    if C_ToyBox.SetFilterString then pcall(C_ToyBox.SetFilterString, toyName or "") end
    if C_ToyBox.ForceToyRefilter then pcall(C_ToyBox.ForceToyRefilter) end

    if toyItemID and not Handlers:IsToyInFilteredList(toyItemID) then
        if C_ToyBox.SetCollectedShown then pcall(C_ToyBox.SetCollectedShown, true) end
        if C_ToyBox.SetUncollectedShown then pcall(C_ToyBox.SetUncollectedShown, true) end
        if C_ToyBox.SetUnusableShown then pcall(C_ToyBox.SetUnusableShown, true) end
        if C_ToyBox.SetAllSourceTypeFilters then pcall(C_ToyBox.SetAllSourceTypeFilters, true) end
        if C_ToyBox.SetAllExpansionTypeFilters then pcall(C_ToyBox.SetAllExpansionTypeFilters, true) end
        if C_ToyBox.ForceToyRefilter then pcall(C_ToyBox.ForceToyRefilter) end
    end

    local searchBox = Handlers:GetToyBoxSearchBox()
    if searchBox and searchBox.SetText then
        pcall(searchBox.SetText, searchBox, toyName or "")
        if searchBox.ClearFocus then pcall(searchBox.ClearFocus, searchBox) end
    end
end

-- Is the toy in the toy box's CURRENT filtered list? Pure C-side reads.
function Handlers:IsToyInFilteredList(itemID)
    if not (itemID and C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex) then
        return false
    end
    local total = C_ToyBox.GetNumFilteredToys() or 0
    for i = 1, total do
        if C_ToyBox.GetToyFromIndex(i) == itemID then return true end
    end
    return false
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
    -- No loose button-text match: the toy name now sits in the toy box's OWN
    -- search box, whose text would match here and get highlighted instead of
    -- the tile. Real toy tiles always carry the itemID above, so identity is
    -- enough and text is never needed.
    return false
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

    local toyBox = self:GetToyBoxFrame()
    local toyName = data.name and slower(data.name)

    -- The list is narrowed to this toy, so match ONLY by itemID/name identity.
    -- No fuzzy text fallback: with the target off-screen it would return some
    -- other visible tile, which is exactly the "highlights the wrong toy" bug.
    if toyBox then
        local visibleButton = self:FindToyButtonInFrame(toyBox, data.toyItemID, toyName, 0)
        if visibleButton then return visibleButton end
    end

    -- ScrollBox-style toybox variants: read-only button lookup. Never drive
    -- the scroll from addon code (insecure render, same poison class).
    local scrollBox = self:GetToyBoxScrollBox()
    if scrollBox then
        local btn = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return self:ToyFrameMatches(frame, data.toyItemID, toyName)
        end)
        if btn then return btn end
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
    local narrowed = false

    -- Clears the glow the instant the tile stops being this toy: the player
    -- editing or clearing the toy box search re-pools the button onto another
    -- toy (or hides it), and the highlight watcher drops it on the mismatch.
    local toyNameLower = data.name and slower(data.name)
    local function stillRepresentsToy(frame)
        return self:ToyFrameMatches(frame, data.toyItemID, toyNameLower)
    end

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
        -- Panel open on the toy tab. Narrow the filtered list to this toy
        -- once it is visible, so Blizzard renders it alone on page one; done
        -- here (not at click time) because the toy box's open-init would
        -- otherwise reset the filter. Then re-scan each tick for the settled
        -- tile and highlight it.
        if not narrowed then
            narrowed = true
            self.ApplyToyBoxFilter(data.name, data.toyItemID)
        end
        local row = self:RevealToyInToyBox(data)
        if row and self:HighlightRevealedFrame(row, stillRepresentsToy) then return end
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
