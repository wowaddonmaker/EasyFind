local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local select, ipairs = Utils.select, Utils.ipairs

function Handlers:OpenContainerBag(bag)
    if bag == nil then return false end
    if bag == 0 and OpenBackpack then
        local ok = pcall(OpenBackpack)
        if ok then return true end
    end
    local openBag = OpenBag or (C_Container and C_Container.OpenBag)
    if openBag then
        return pcall(openBag, bag)
    end
    return false
end

function Handlers:OpenContainerBagLocations(locations, fallbackBag)
    local opened = false
    if locations then
        local seen = {}
        for _, loc in ipairs(locations) do
            if loc.bag ~= nil and not seen[loc.bag] then
                seen[loc.bag] = true
                opened = self:OpenContainerBag(loc.bag) or opened
            end
        end
    elseif fallbackBag ~= nil then
        opened = self:OpenContainerBag(fallbackBag) or opened
    end
    return opened
end

function Handlers:OpenBagItemLocation(data)
    if not data then return end
    self:OpenContainerBagLocations(data.bagLocations, data.bagID)
    local highlight = data.steps and #data.steps >= 2 and ns.RequestGuide() or nil
    if highlight and highlight.StartGuideAtStep then
        data.steps[2]._efContainerSlotFound = nil
        highlight:StartGuideAtStep(data, 2)
    end
end

Search.NON_EQUIP_LOCS = ns.NON_EQUIP_LOCS
Search.EQUIP_LOCS = ns.EQUIP_LOCS

function Handlers:IsRealEquipLoc(slot)
    return Utils.IsRealEquipLoc(slot)
end

function Handlers:GetItemEquipLoc(itemID)
    return Utils.GetItemEquipLoc(itemID)
end

-- True when the row describes an item the logged-in character cannot touch:
-- sitting in the bank, or in another character's bags. Every "what does
-- clicking do" decision consults this one predicate, because each of them gets
-- it wrong differently -- the bag-open path highlights a slot that is not
-- there, and the secure path arms /use on an item this character does not have.
-- ==== repeat use ===========================================================
-- A stackable consumable with more than one in the bags keeps the window
-- open across uses, so the next click on the row is the next use (a
-- recruit's pouch, a stack of knowledge pages) instead of a trip to the
-- bags. A potion is the exception: its use starts a cooldown, and the
-- window closes as it always did. The decision is made just after the
-- use, from what the item slot reports, so no item list is needed.
local REPEAT_SETTLE = 0.3
local REPEAT_CD_MIN = 2      -- longer than the global cooldown

function Handlers:KeepOpenForRepeatUse(data)
    if not (data and data.itemID and data.category == "Bag") then return false end
    if self:IsRemoteStoredItem(data) then return false end
    if (data.bagCount or 1) <= 1 then return false end
    if Handlers:IsSourceModifierHeld() or Handlers:IsSourceCtrlHeld() then return false end
    return self:GetBagItemActionKind(data) == "use"
end

-- Called instead of the usual dismiss right after a repeat-use click.
function Handlers:AfterRepeatUse(data)
    local bag, slot = data.bagID, data.bagSlot
    Utils.SafeAfter(REPEAT_SETTLE, function()
        local start, duration = 0, 0
        if C_Container and C_Container.GetContainerItemCooldown and bag ~= nil and slot then
            start, duration = C_Container.GetContainerItemCooldown(bag, slot)
        end
        local info = C_Container and C_Container.GetContainerItemInfo and bag ~= nil and slot
            and C_Container.GetContainerItemInfo(bag, slot)
        local left = info and info.stackCount or 0
        if (start or 0) > 0 and (duration or 0) > REPEAT_CD_MIN then
            -- A cooldown started: this is not a spam item.
            Handlers:FinishResultSelection()
            return
        end
        if ns.Database and ns.Database.RefreshDynamicCategory then
            ns.Database:RefreshDynamicCategory("bags")
        end
        if left <= 0 then
            -- That was the last of the stack in this slot: the list now
            -- shows whatever is left elsewhere, or nothing.
            local any = false
            local rows = ns.Database and ns.Database.uiSearchData
            for i = 1, (rows and #rows or 0) do
                if rows[i].category == "Bag" and rows[i].itemID == data.itemID then any = true; break end
            end
            if not any then Handlers:FinishResultSelection() end
        end
    end)
end

-- No "use all": the game marks UseContainerItem protected for addons
-- (ADDON_ACTION_FORBIDDEN on the first call, 2026-09-08), so an addon
-- cannot chain uses at all. The row staying open across clicks is the
-- whole answer; each click is the hardware event the game requires.

function Handlers:IsRemoteStoredItem(data)
    return data ~= nil and data.storedRemote == true
end

-- Rows whose only action is "put the item on the cursor so it can be linked":
-- the catalog, loot, and anything stored where this character cannot reach it.
-- Stamped at populate (lookupRow), never inferred from category here -- an
-- inferred list falls behind the moment a new row kind is added, and the
-- symptom is a row that silently does nothing on click.
function Handlers:IsLookupRow(data)
    return data ~= nil and data.lookupRow == true
end

function Handlers:GetBagItemActionKind(data)
    if not data or not data.itemID or data.category ~= "Bag" then return nil end
    if self:IsRemoteStoredItem(data) then return nil end

    -- Only treat items with a real gear slot as "equippable". Empty /
    -- NON_EQUIP / AMMO / QUIVER are not gear slots.
    local slot = data.equipLoc
    if not self:IsRealEquipLoc(slot) then
        slot = self:GetItemEquipLoc(data.itemID)
    end
    if self:IsRealEquipLoc(slot) then
        return "equip"
    end

    local hasUseEffect = (C_Item and C_Item.GetItemSpell and C_Item.GetItemSpell(data.itemID))
        or (GetItemSpell and GetItemSpell(data.itemID))
    if hasUseEffect then return "use" end

    -- Compare against the numeric itemClassID rather than the localized
    -- itemType string. GetItemInfo's position-6 return is the LOCALIZED
    -- type name ("Consumable", "Konsumartikel", "Consumable" in French,
    -- etc.) so a string check breaks on non-English clients. ClassID is
    -- the stable enum: 0 = Consumable, 1 = Container, 12 = Quest item.
    if GetItemInfoInstant then
        local _, _, _, _, _, classID = GetItemInfoInstant(data.itemID)
        if classID == 0 then
            return "use"
        elseif classID == 1 or classID == 12 then
            return "open"
        end
    elseif GetItemInfo then
        local classID = select(12, GetItemInfo(data.itemID))
        if classID == 0 then
            return "use"
        elseif classID == 1 or classID == 12 then
            return "open"
        end
    end

    return "show"
end
