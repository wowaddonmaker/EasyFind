local _, ns = ...

local SecureAttributes = {}
ns.ResultSecureAttributes = SecureAttributes

local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils
local SecureOpeners = ns.SecureOpeners

local InCombatLockdown = InCombatLockdown
local GetMacroInfo = GetMacroInfo
local GetMacroIndexByName = GetMacroIndexByName

-- The alt+click swap always targets the spellbook panel; the flag carries
-- the key so ArmSteerLate learns its target from the swap itself.
local SPELLBOOK_PANEL = "playerSpells"

-- The release-edge tab steer: pressAndHoldAction makes the up edge resolve
-- "typerelease", whose "click" action delegates to the tab button frame
-- ref (see Shared/SecureOpeners.lua).
local function SetSteer(resultRow, steerTab)
    if resultRow._efSteerTab == steerTab then return end
    -- "*" prefix: the release lookup uses the PHYSICALLY held modifier as
    -- its attribute prefix and never falls back to the bare-suffix form,
    -- so "typerelease1" is unreachable while alt/ctrl/shift is down. The
    -- any-modifier wildcard resolves for every modifier state; the "1"
    -- suffix still keeps right-button edges away from the steer.
    Utils.SafeCallMethod(resultRow, "SetAttribute", "pressAndHoldAction", steerTab and true or nil)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "*typerelease1", steerTab and "click" or nil)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "*clickbutton1", steerTab)
    resultRow._efSteerTab = steerTab
end

-- Every disarm must go through here: wiping an attribute without also
-- invalidating the dedup cache lets a later Apply with an identical action
-- triple early-return and leave the button disarmed (opener rows then
-- silently fall through to the tainted legacy open).
local function DisarmAction(resultRow)
    if resultRow._lastAttrKey then
        Utils.SafeCallMethod(resultRow, "SetAttribute", resultRow._lastAttrKey, nil)
    end
    Utils.SafeCallMethod(resultRow, "SetAttribute", "type", nil)
    resultRow._lastAttrType = nil
    resultRow._lastAttrKey = nil
    resultRow._lastAttrVal = nil
end

function SecureAttributes.Apply(resultRow, data)
    if InCombatLockdown() then return end

    -- Addon-originated clicks (hardware clicks on our rows, override-binding
    -- clicks, /click) reach SecureActionButton_OnClick without isSecureAction
    -- set, so the edge that fires is decided by the useOnKeyDown attribute,
    -- falling back to the user's ActionButtonUseKeyDown CVar. These buttons
    -- register LeftButtonDown; pin the attribute so a CVar of 0 cannot
    -- silently drop every down-edge action (and cannot fire the unsuffixed
    -- type/macrotext on right-button up-clicks).
    if not resultRow._efUseOnKeyDown then
        Utils.SafeCallMethod(resultRow, "SetAttribute", "useOnKeyDown", true)
        resultRow._efUseOnKeyDown = true
    end

    resultRow._efSwappedToOpen = nil

    -- Panel-opener rows (spellbook/talents entries, Talent and
    -- spellbook-only-ability rows) open PlayerSpellsFrame through the
    -- secure macro and steer the tab on the release edge; rationale and
    -- taint measurements live in Shared/SecureOpeners.lua.
    local openKey = data and SecureOpeners and SecureOpeners.OpenKeyForData(data)

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
    elseif data and data.macroIndex and data.category == "Macro" then
        local body = data.macroBody
        if (not body or body == "") and GetMacroInfo then
            -- Pinned macros persist only name and index (bodies would go
            -- stale in storage); re-resolve by name first since indexes
            -- shift when macros are added or deleted.
            local idx = GetMacroIndexByName and data.name
                and GetMacroIndexByName(data.name) or 0
            if not idx or idx == 0 then idx = data.macroIndex end
            local _, _, liveBody = GetMacroInfo(idx)
            body = liveBody
        end
        if body and body ~= "" then
            newType, newKey, newVal = "macro", "macrotext", body
        end
    elseif data and data.slashCommand then
        newType, newKey, newVal = "macro", "macrotext", data.slashCommand
    elseif openKey then
        -- Nil while the panel is shown, so the click only steers tabs
        -- instead of toggling it closed.
        local openMacro = SecureOpeners.GetOpenMacro(openKey)
        if openMacro then
            newType, newKey, newVal = "macro", "macrotext", openMacro
        end
    end

    -- No alt-suffixed attributes here: secure dispatch resolves them by the
    -- PHYSICAL alt key, so ALT-chord bindings (ALT-n shortcuts, ALT
    -- shortkeys) would hijack the row's primary action. The deliberate
    -- alt+click "show in spellbook" route swaps the plain attributes at
    -- click time instead (Interactions.lua PreClick).

    SetSteer(resultRow, openKey and SecureOpeners.GetSteerTabButton(openKey, data) or nil)

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

-- Click-time arming (rows and shortkey buttons): the panel addon must be
-- loaded before Apply can resolve the release steer's tab frame ref, and
-- the load is deliberately excluded from render-time Apply calls.
function SecureAttributes.ApplyAtClick(resultRow, data)
    if SecureOpeners then
        SecureOpeners.EnsureLoaded(SecureOpeners.OpenKeyForData(data))
    end
    SecureAttributes.Apply(resultRow, data)
end

-- The ONLY sanctioned way to disarm a button's secure action.
function SecureAttributes.Clear(resultRow)
    DisarmAction(resultRow)
    resultRow._efSwappedToOpen = nil
    SetSteer(resultRow, nil)
end

-- One owner for the dispatch-edge decision: panel-opener activations
-- navigate on the release dispatch (after the secure open and tab steer
-- both fired), everything else on the press.
function SecureAttributes.ActsOnRelease(button, data)
    return button._efSwappedToOpen
        or (data and SecureOpeners and SecureOpeners.OpenKeyForData(data))
        or nil
end

-- Deliberate alt+click on a castable ability row means "show it in the
-- spellbook": swap the plain attributes to the secure open macro plus the
-- spellbook-tab release steer for this click only (the next Apply restores
-- the cast). Plain attributes so the swap is invisible to ALT-chord
-- bindings, which never reach here: the shortcut/shortkey activation paths
-- suppress the source modifier.
function SecureAttributes.SwapToPanelOpen(resultRow)
    DisarmAction(resultRow)
    if not SecureOpeners then return end
    SecureOpeners.EnsureLoaded(SPELLBOOK_PANEL)
    SetSteer(resultRow, SecureOpeners.GetDefaultTabButton(SPELLBOOK_PANEL))
    local openMacro = SecureOpeners.GetOpenMacro(SPELLBOOK_PANEL)
    if openMacro then
        Utils.SafeCallMethod(resultRow, "SetAttribute", "type", "macro")
        Utils.SafeCallMethod(resultRow, "SetAttribute", "macrotext", openMacro)
        resultRow._lastAttrType = "macro"
        resultRow._lastAttrKey = "macrotext"
        resultRow._lastAttrVal = openMacro
    end
    -- openMacro is nil while the panel is already shown: nothing to open,
    -- the release edge steers.
    resultRow._efSwappedToOpen = SPELLBOOK_PANEL
end

-- Late arming for the first-ever open: if the panel (and so its tab
-- buttons) did not exist when PreClick armed the row, OnMouseUp runs after
-- the press opened it and before the release dispatch resolves the steer.
function SecureAttributes.ArmSteerLate(resultRow)
    if resultRow._efSteerTab then return end
    local data = resultRow.data
    if not (SecureOpeners and data) then return end
    local steerTab
    local openKey = SecureOpeners.OpenKeyForData(data)
    if openKey then
        steerTab = SecureOpeners.GetSteerTabButton(openKey, data)
    elseif resultRow._efSwappedToOpen then
        steerTab = SecureOpeners.GetDefaultTabButton(resultRow._efSwappedToOpen)
    end
    if steerTab then
        SetSteer(resultRow, steerTab)
    end
end
