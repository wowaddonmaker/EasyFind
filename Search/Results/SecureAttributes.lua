local _, ns = ...

local SecureAttributes = {}
ns.ResultSecureAttributes = SecureAttributes

local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local InCombatLockdown = InCombatLockdown

function SecureAttributes.Apply(resultRow, data)
    if InCombatLockdown() then return end

    local newType, newKey, newVal
    if data and data.toyItemID and not data.isToyboxOnly then
        -- Unusable toys (faction-restricted etc.) skip the secure
        -- use type so PostClick can route them to the ToyBox instead
        -- of silently no-op'ing on click.
        newType, newKey, newVal = "toy", "toy", data.toyItemID
    elseif data and data.mountID and Icons:IsMountSummonable(data) then
        newType, newKey, newVal = "macro", "macrotext", "/cancelform [form]"
    elseif data and data.outfitID then
        -- Newer path: secure "outfit" type keyed by the player-facing index.
        -- No "action": the default click on the button wears the outfit.
        local outfitIndex = Handlers:GetOutfitSecureIndex(data)
        if outfitIndex then
            newType, newKey, newVal = "outfit", "outfit-index", outfitIndex
        end
    elseif data and data.spellID and data.category ~= "Talent"
           and not Icons:IsSpellbookOnlyAbility(data) then
        -- Talents share the spellID field but should never cast on
        -- click. The click navigates to the talents tree and
        -- highlights the node.
        newType, newKey, newVal = "spell", "spell", data.spellName or data.spellID
    elseif data and data.itemID and data.category == "Bag"
           and Handlers:GetBagItemActionKind(data) ~= "show" then
        newType, newKey, newVal = "item", "item", data.name
    elseif data and data.macroIndex and data.category == "Macro"
           and data.macroBody and data.macroBody ~= "" then
        newType, newKey, newVal = "macro", "macrotext", data.macroBody
    elseif data and data.slashCommand then
        newType, newKey, newVal = "macro", "macrotext", data.slashCommand
    end

    if resultRow._lastAttrType == newType
       and resultRow._lastAttrKey == newKey
       and resultRow._lastAttrVal == newVal then
        return
    end

    if resultRow._lastAttrKey then
        Utils.SafeCallMethod(resultRow, "SetAttribute", resultRow._lastAttrKey, nil)
    end
    Utils.SafeCallMethod(resultRow, "SetAttribute", "type", newType)
    if newKey then
        Utils.SafeCallMethod(resultRow, "SetAttribute", newKey, newVal)
    end
    resultRow._lastAttrType = newType
    resultRow._lastAttrKey  = newKey
    resultRow._lastAttrVal  = newVal
end
