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
    if data.steps and #data.steps >= 2 and ns.Highlight and ns.Highlight.StartGuideAtStep then
        data.steps[2]._efContainerSlotFound = nil
        ns.Highlight:StartGuideAtStep(data, 2)
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

function Handlers:GetBagItemActionKind(data)
    if not data or not data.itemID or data.category ~= "Bag" then return nil end

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
