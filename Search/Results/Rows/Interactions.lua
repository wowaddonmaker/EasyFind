local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Render = ns.ResultRender
local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown

local function CollapsedNodes()
    return Results._collapsedNodes
end

function Rows.InstallInteractions(resultRow, index)
    -- LeftButtonDown for the secure cast: type=spell silently no-ops
    -- on LeftButtonUp for many spells (this was confirmed in the TBC
    -- version where Down works perfectly). RegisterForDrag would
    -- defer the Down click and break that, so we route drag-to-bar
    -- through Shift+click instead (handled in PreClick below).
    resultRow:RegisterForClicks("LeftButtonDown", "RightButtonUp")

    -- Shift+drag on a row picks the action up onto the cursor (for
    -- placing on action bars, banks, etc.) instead of casting. We
    -- can't use RegisterForDrag here because it defers the Down
    -- click and silently breaks type=spell casts. So we do it
    -- manually: PreClick detects Shift and clears the secure type
    -- so the cast doesn't fire, OnMouseDown records the press
    -- position, OnUpdate watches for movement, and the actual
    -- Pickup* call happens once the cursor has moved past the
    -- 5px drag threshold. Plain shift+click without movement
    -- does nothing, matches Blizzard's action-bar drag feel.
    -- C_Spell.PickupSpell is preferred over the legacy global since
    -- Midnight phased PickupSpell out for some spells.
    local function PickupSpellCompat(spellID)
        if C_Spell and C_Spell.PickupSpell then
            C_Spell.PickupSpell(spellID)
        elseif PickupSpell then
            PickupSpell(spellID)
        end
    end
    local function CanPickupRowAction(d)
        if not d then return false end
        if d.mountID then return Icons:IsMountSummonable(d) end
        if d.toyItemID then return not d.isToyboxOnly end
        if d.petID then return true end
        if d.outfitID or d.macroIndex then return true end
        if d.spellID then
            return d.category == "Ability" and not Icons:IsSpellbookOnlyAbility(d)
        end
        return (d.bagID and d.bagSlot) or d.itemID
    end
    local function PickupRowAction(d)
        if not CanPickupRowAction(d) then return end
        if InCombatLockdown() then return end
        ClearCursor()
        if d.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
            local _, spellID = C_MountJournal.GetMountInfoByID(d.mountID)
            if spellID then PickupSpellCompat(spellID) end
        elseif d.petID and C_PetJournal and C_PetJournal.PickupPet then
            C_PetJournal.PickupPet(d.petID)
        elseif d.toyItemID and C_ToyBox and C_ToyBox.PickupToyBoxItem then
            C_ToyBox.PickupToyBoxItem(d.toyItemID)
        elseif d.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
            C_TransmogOutfitInfo.PickupOutfit(d.outfitID)
        elseif d.macroIndex and PickupMacro then
            PickupMacro(d.macroIndex)
        elseif d.spellID then
            PickupSpellCompat(d.spellID)
        elseif d.bagID and d.bagSlot then
            local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
            if pickup then
                pickup(d.bagID, d.bagSlot)
            elseif d.itemID and PickupItem then
                PickupItem(d.itemID)
            end
        elseif d.itemID and PickupItem then
            PickupItem(d.itemID)
        end
    end
    local function ClearSecureClick(row)
        if row._lastAttrKey then
            Utils.SafeCallMethod(row, "SetAttribute", row._lastAttrKey, nil)
        end
        Utils.SafeCallMethod(row, "SetAttribute", "type", nil)
        row._lastAttrType = nil
        row._lastAttrKey = nil
        row._lastAttrVal = nil
    end
    local function SetSecureOutfit(row, outfitIndex)
        if row._lastAttrKey and row._lastAttrKey ~= "outfit-index" then
            Utils.SafeCallMethod(row, "SetAttribute", row._lastAttrKey, nil)
        end
        Utils.SafeCallMethod(row, "SetAttribute", "type", "outfit")
        Utils.SafeCallMethod(row, "SetAttribute", "outfit-index", outfitIndex)
        Utils.SafeCallMethod(row, "SetAttribute", "action", nil)
        row._lastAttrType = "outfit"
        row._lastAttrKey = "outfit-index"
        row._lastAttrVal = outfitIndex
    end
    local DRAG_PX = 5
    -- HookScript not SetScript: SecureActionButtonTemplate uses the
    -- native OnMouseDown / OnMouseUp handlers internally to dispatch
    -- the secure click. SetScript would replace them and break casts.
    resultRow:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if not IsShiftKeyDown() then return end
        if not CanPickupRowAction(self.data) then return end
        local x, y = GetCursorPosition()
        self._dragOriginX, self._dragOriginY = x, y
    end)
    resultRow:HookScript("OnUpdate", function(self)
        if not self._dragOriginX then return end
        local x, y = GetCursorPosition()
        local dx, dy = x - self._dragOriginX, y - self._dragOriginY
        if dx * dx + dy * dy < DRAG_PX * DRAG_PX then return end
        self._dragOriginX, self._dragOriginY = nil, nil
        self._pickedUp = true
        if self.data then PickupRowAction(self.data) end
    end)
    resultRow:HookScript("OnMouseUp", function(self)
        self._dragOriginX, self._dragOriginY = nil, nil
        -- If we picked up this cycle and the user released over an
        -- action bar slot, place it (emulates native drag-drop, which
        -- we can't get via RegisterForDrag because it'd defer the Down
        -- click and break casts).
        if not self._pickedUp then return end
        if InCombatLockdown() then return end
        local cursorType = GetCursorInfo and GetCursorInfo()
        if not cursorType then return end
        local foci
        if GetMouseFoci then
            foci = GetMouseFoci()
        elseif GetMouseFocus then
            foci = { GetMouseFocus() }
        end
        if not foci then return end
        for i = 1, #foci do
            local f = foci[i]
            local slot = f and (f.action or (f.GetAttribute and f:GetAttribute("action")))
            if slot then
                if PlaceAction then PlaceAction(slot) end
                ClearCursor()
                break
            end
        end
    end)
    resultRow:SetScript("PreClick", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        self._outfitSecureClicked = nil
        if InCombatLockdown() then return end

        local d = self.data

        -- Shift held: kill the cast for this click. The pickup (if any)
        -- happens via the OnMouseDown / OnUpdate drag detection above:
        -- this branch only ensures the secure handler is a no-op so
        -- nothing fires when the user hasn't moved yet. Setting the
        -- skip-navigation flag here (not waiting for OnUpdate) is what
        -- prevents PostClick from closing the window before OnUpdate
        -- has had a chance to detect movement and pick up the action.
        if d and IsShiftKeyDown() and CanPickupRowAction(d) then
            ClearSecureClick(self)
            self._pickedUp = true
            return
        end

        -- Alt+click is the "show owning Search" modifier. Ctrl remains for
        -- Blizzard-style previews such as mounts and equippable bag items.
        local sourceModifierHeld = Handlers:IsSourceModifierHeld()
        local ctrlHeld = IsControlKeyDown and IsControlKeyDown()
        local bagItemKind = (d and d.itemID and d.category == "Bag")
            and Handlers:GetBagItemActionKind(d)
        local suppressSecureClick = d and (
            (sourceModifierHeld and (d.macroIndex or d.mountID or d.toyItemID
                or d.outfitID or (d.spellID and d.category == "Ability")
                or (d.itemID and d.category == "Bag")))
            or (d.mountID and (ctrlHeld or not Icons:IsMountSummonable(d)))
            or (ctrlHeld and bagItemKind == "equip")
        )
        if suppressSecureClick then
            ClearSecureClick(self)
            return
        end

        if not (d and d.outfitID) then return end
        if Rows:IsOutfitCooldownActive() then
            ClearSecureClick(self)
            return
        end

        local outfitIndex = Handlers:GetOutfitSecureIndex(d)
        if not outfitIndex then
            ClearSecureClick(self)
            return
        end
        SetSecureOutfit(self, outfitIndex)
        self._outfitSecureClicked = d.outfitID
    end)
    resultRow:SetScript("PostClick", function(self, mouseButton, down)
        -- Shift+click pickup: cursor is holding the action for the
        -- user to drop on a bar. Don't navigate away or close.
        if self._pickedUp then
            self._pickedUp = nil
            return
        end
        -- Block result selection if outfit equip is on cooldown (keep results open).
        -- Toys are deliberately NOT checked here: GetItemCooldown returns the
        -- cast-time of a freshly-started channel as a "cooldown", which would
        -- keep the window open every time you click a cast-toy (Hearthstone,
        -- garrison hearthstone, etc.). Outfit cooldown is a real swap-lockout
        -- we manage ourselves, so it's safe to gate on.
        if self.data and mouseButton == "LeftButton" and self.data.outfitID
           and not Handlers:IsSourceModifierHeld()
           and Rows.outfitCdStart > 0
           and Rows.outfitCdDuration - (GetTime() - Rows.outfitCdStart) > 0 then
            if Search:GetSearchFrame() and Search:GetSearchFrame().editBox and not Search:GetNavFrame():IsKeyboardEnabled() then
                Search:GetSearchFrame().editBox.blockFocus = nil
                Search:GetSearchFrame().editBox:SetFocus()
            end
            return
        end

        if self._outfitSecureClicked then
            Rows.lastEquippedOutfitID = self._outfitSecureClicked
            Rows.outfitCdStart = GetTime()
            Rows.outfitCdDuration = 4
            self._outfitSecureClicked = nil
        end
        -- Right-click: show pin/unpin popup (plus Guide row if entry has a guide path)
        if mouseButton == "RightButton" and self.data then
            Rows:ShowResultContextMenu(self, false)
            return
        end

        -- Unearned currencies and level-locked results are inert
        if self.isUnearnedCurrency or self.lockedReason then
            return
        end

        -- Setting click. Checkbox: toggle inline (Alt+click opens the
        -- panel). Everything else (slider / keybind / dropdown): open
        -- the panel so the user lands on the setting they searched for.
        -- Inline editors (slider drag, kb1/kb2 capture, dropdown
        -- paddles) sit on top of the row and consume their own clicks,
        -- so reaching this handler means the user clicked the label.
        if Rows:ActivateSettingResult(self.data, Handlers:IsSourceModifierHeld()) then return end

        if self.isPinHeader then
            return
        end

        if self.isPathNode then
            -- Retail theme: headerTab and toggleBtn handle clicks directly
            local isRetailHeader = self.headerTab and self.headerTab:IsShown()
            if isRetailHeader then
                if self.data then
                    Handlers:SelectResult(self.data)
                end
            else
                local cursorX = GetCursorPosition()
                local scale = self:GetEffectiveScale()
                local btnLeft = self:GetLeft() * scale
                local depth = self.pathNodeDepth or 0
                local iconLeft = btnLeft + depth * 20 * scale  -- INDENT_PX = 20
                local isToggleClick = cursorX <= (iconLeft + 35 * scale)

                if isToggleClick then
                    local key = (self.pathNodeName or "") .. "_" .. (self.pathNodeDepth or 0)
                    CollapsedNodes()[key] = not CollapsedNodes()[key]
                    if Results._cachedHierarchical then
                        Render:ShowHierarchicalResults(Results._cachedHierarchical, true)
                    end
                elseif self.data then
                    Handlers:SelectResult(self.data)
                end
            end
        elseif self.data then
            Handlers:SelectResult(self.data)
        end
    end)
end
