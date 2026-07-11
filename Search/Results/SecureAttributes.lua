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
    -- The dedup must never early-return past a release-macro arm: that arm
    -- rewrote *typerelease1/macrotext behind the cache, so the trio must be
    -- force-rewritten once to restore steer semantics.
    if resultRow._efSteerTab == steerTab and not resultRow._efReleaseMacro then return end
    -- "*" prefix: the release lookup uses the PHYSICALLY held modifier as
    -- its attribute prefix and never falls back to the bare-suffix form,
    -- so "typerelease1" is unreachable while alt/ctrl/shift is down. The
    -- any-modifier wildcard resolves for every modifier state; the "1"
    -- suffix still keeps right-button edges away from the steer.
    Utils.SafeCallMethod(resultRow, "SetAttribute", "pressAndHoldAction", steerTab and true or nil)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "*typerelease1", steerTab and "click" or nil)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "*clickbutton1", steerTab)
    resultRow._efSteerTab = steerTab
    resultRow._efReleaseMacro = nil
end

-- Cold-open page landing (navtest [9]): between the down edge (which just
-- ran the open macro) and the release dispatch, OnMouseUp re-aims the
-- release at the full page journey. typerelease="macro" re-reads
-- macrotext, which by then carries one secure "/click <proxy>" line per
-- page. Sharing macrotext with the already-spent down edge is deliberate;
-- the dedup cache is synced to the attribute's true value, and the
-- _efReleaseMacro flag makes the next SetSteer force-rewrite the release
-- trio instead of trusting its cache.
local function SetReleaseMacro(resultRow, macrotext)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "pressAndHoldAction", true)
    Utils.SafeCallMethod(resultRow, "SetAttribute", "*typerelease1", "macro")
    Utils.SafeCallMethod(resultRow, "SetAttribute", "macrotext", macrotext)
    if resultRow._lastAttrKey == "macrotext" then
        resultRow._lastAttrVal = macrotext
    end
    resultRow._efReleaseMacro = true
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
            -- Cold open. A VIRGIN panel opens on its own default tab
            -- (spec/last-remembered), not the spellbook: the old
            -- release-edge tab steer then consumed the click's only free
            -- edge selecting the spellbook, so pages never flipped until a
            -- second click. The tab select therefore rides the SAME
            -- down-edge macro through a click proxy (the tab is unnamed),
            -- the book renders during the press, and the release stays
            -- free for the page chain ArmSteerLate arms at mouse-up: one
            -- click even on a first-ever open. Re-clicking an
            -- already-selected tab just resets to page 1, which is where
            -- the page math starts anyway.
            local steerTab = SecureOpeners.GetSteerTabButton(openKey, data)
            local tabClick = steerTab
                and SecureOpeners.GetClickChainMacro(steerTab, 1)
            if tabClick then
                openMacro = openMacro .. "\n" .. tabClick
            end
            newType, newKey, newVal = "macro", "macrotext", openMacro
        elseif Handlers.GetSpellbookNavPlan then
            -- Panel already shown: the down edge carries the WHOLE journey
            -- as one secure macro -- panel tab, category tab, or page
            -- flips, one "/click <proxy>" line each (navtest [8]: any
            -- distance in one click, zero tainted provider fields, casts
            -- stay silent). Whatever the down edge renders, mouse-up reads
            -- it and puts any remaining pages on the release edge.
            local plan, planReason = Handlers.GetSpellbookNavPlan(data)
            if plan and plan.step == "page" then
                newVal = SecureOpeners.GetClickChainMacro(plan.button, plan.presses)
            elseif plan and plan.step == "category" then
                newVal = SecureOpeners.GetClickChainMacro(plan.button, 1)
            elseif planReason == "spellbook not shown" then
                -- Panel up on another tab: select the spellbook tab on the
                -- down edge; the release gets the pages at mouse-up.
                local steerTab = SecureOpeners.GetSteerTabButton(openKey, data)
                newVal = steerTab
                    and SecureOpeners.GetClickChainMacro(steerTab, 1) or nil
            end
            if newVal then
                newType, newKey = "macro", "macrotext"
            end
        end
    end

    -- No alt-suffixed attributes here: secure dispatch resolves them by the
    -- PHYSICAL alt key, so ALT-chord bindings (ALT-n shortcuts, ALT
    -- shortkeys) would hijack the row's primary action. The deliberate
    -- alt+click "show in spellbook" route swaps the plain attributes at
    -- click time instead (Interactions.lua PreClick).

    do
        local steerTab = openKey and SecureOpeners.GetSteerTabButton(openKey, data) or nil
        -- Already-selected tab: never steer onto it, or the release-edge
        -- re-click resets the spellbook page right after the down edge
        -- flipped it.
        if steerTab and SecureOpeners.IsTabButtonSelected(openKey, steerTab) then
            steerTab = nil
        end
        SetSteer(resultRow, steerTab)
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
    local defaultTab = SecureOpeners.GetDefaultTabButton(SPELLBOOK_PANEL)
    local steerTab = defaultTab
    if steerTab and SecureOpeners.IsTabButtonSelected(SPELLBOOK_PANEL, steerTab) then
        steerTab = nil
    end
    SetSteer(resultRow, steerTab)
    local openMacro = SecureOpeners.GetOpenMacro(SPELLBOOK_PANEL)
    if openMacro then
        -- Same virgin-panel rule as Apply: the spellbook tab select rides
        -- the down-edge macro so the release stays free for the page chain.
        local tabClick = defaultTab
            and SecureOpeners.GetClickChainMacro(defaultTab, 1)
        if tabClick then
            openMacro = openMacro .. "\n" .. tabClick
        end
        Utils.SafeCallMethod(resultRow, "SetAttribute", "type", "macro")
        Utils.SafeCallMethod(resultRow, "SetAttribute", "macrotext", openMacro)
        resultRow._lastAttrType = "macro"
        resultRow._lastAttrKey = "macrotext"
        resultRow._lastAttrVal = openMacro
    elseif Handlers.GetSpellbookNavPlan then
        -- Panel already shown: same arming as Apply -- the down edge
        -- carries the whole page journey as one secure macro chain, and a
        -- wrong category steers its tab on the release edge.
        local navPlan = Handlers.GetSpellbookNavPlan(resultRow.data)
        if navPlan and navPlan.step == "page" then
            local chain = SecureOpeners.GetClickChainMacro(navPlan.button, navPlan.presses)
            if chain then
                Utils.SafeCallMethod(resultRow, "SetAttribute", "type", "macro")
                Utils.SafeCallMethod(resultRow, "SetAttribute", "macrotext", chain)
                resultRow._lastAttrType = "macro"
                resultRow._lastAttrKey = "macrotext"
                resultRow._lastAttrVal = chain
                resultRow._efSwappedToOpen = SPELLBOOK_PANEL
                return
            end
        elseif navPlan and navPlan.step == "category" then
            SetSteer(resultRow, navPlan.button)
            resultRow._efSwappedToOpen = SPELLBOOK_PANEL
            return
        end
    end
    -- With the panel already shown and the spell on the current page there
    -- is nothing to open or flip; the release edge steers.
    resultRow._efSwappedToOpen = SPELLBOOK_PANEL
end

-- Late release-edge arming, run from OnMouseUp: after the press dispatch
-- (which may have just opened the panel) and before the release dispatch.
-- The PLAN decides first, because it reads the DISPLAYED view data: on a
-- first-ever open the selection bookkeeping (category selectedTabID,
-- panel GetTab) lags the display, and trusting it wasted the release edge
-- on a tab re-click while the page chain was computable all along.
-- step=page: spend the free release edge on the FULL page journey
-- (navtest [9]) -- a cold open lands on the spell in a single click.
-- step=category: the release clicks the category tab. No plan at all
-- (wrong panel tab, talents rows, first-ever panel load): fall back to
-- the top-level tab steer, and never leave the release on an
-- already-selected tab -- that re-click resets the page.
function SecureAttributes.ArmSteerLate(resultRow)
    local data = resultRow.data
    if not (SecureOpeners and data) then return end
    local openKey = SecureOpeners.OpenKeyForData(data) or resultRow._efSwappedToOpen
    if not openKey then return end

    if Handlers.GetSpellbookNavPlan then
        local plan = Handlers.GetSpellbookNavPlan(data)
        if plan and plan.step == "page" then
            local chain = SecureOpeners.GetClickChainMacro(plan.button, plan.presses)
            if chain then
                SetReleaseMacro(resultRow, chain)
                return
            end
        elseif plan and plan.step == "category" then
            SetSteer(resultRow, plan.button)
            return
        end
    end

    local steerTab = resultRow._efSteerTab
    if steerTab then
        if SecureOpeners.IsTabButtonSelected(openKey, steerTab) then
            SetSteer(resultRow, nil)
        end
        return
    end
    steerTab = resultRow._efSwappedToOpen
        and SecureOpeners.GetDefaultTabButton(openKey)
        or SecureOpeners.GetSteerTabButton(openKey, data)
    if steerTab and not SecureOpeners.IsTabButtonSelected(openKey, steerTab) then
        SetSteer(resultRow, steerTab)
    end
end
