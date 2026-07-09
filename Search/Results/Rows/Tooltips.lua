local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Tooltips = ns.ResultTooltips
local Handlers = ns.ResultHandlers
local Utils = ns.Utils
local L = ns.L

local select = Utils.select
local sformat = Utils.sformat
local mfloor = Utils.mfloor

local C_Timer = C_Timer
local GameTooltip = GameTooltip
local UIParent = UIParent
local GetCursorPosition = GetCursorPosition

local function AnchorRowTooltip(tooltip, ownerFrame)
    return Tooltips:AnchorRowTooltip(tooltip, ownerFrame)
end

local function GetUnearnedTooltip()
    return Tooltips:GetUnearnedTooltip()
end

function Rows.InstallTooltips(resultRow)
    -- Tooltip for unearned currencies, mounts, and toys.
    -- This SetScript is the row's canonical OnEnter owner (it replaces any
    -- earlier hooks), so the light-theme hover wash rides here too.
    resultRow:SetScript("OnEnter", function(self)
        -- Single-owner hover wash. WoW's built-in highlight (used before the
        -- themed wash) can never leave two rows lit; the manual wash can when
        -- a hovered row is hidden/recycled by a re-render and its OnLeave
        -- never fires. Clearing the prior hovered row here restores that
        -- one-row-at-a-time guarantee regardless of missed OnLeaves.
        local prevHover = Results._hoverRow
        if prevHover and prevHover ~= self then
            prevHover._efHlHover = nil
            Results:UpdateRowWash(prevHover)
        end
        Results._hoverRow = self
        self._efHlHover = true
        Results:UpdateRowWash(self)
        -- Hover-based action hint (mirrors keyboard selection hint).
        Handlers:ApplyActionHint(self)
        -- Housing decor: quality-colored name, owned/placed/stored counts
        -- (Blizzard's own format string), and the acquisition source.
        if self.data and self.data.housingEntryID and self.data.category == "Housing" then
            AnchorRowTooltip(GameTooltip, self)
            local quality = self.data.housingQuality
            local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            GameTooltip:SetText(self.data.name or "", qc and qc.r or 1, qc and qc.g or 1, qc and qc.b or 1)
            local ownedFormat = _G["HOUSING_DECOR_OWNED_COUNT_FORMAT"]
            local stored = self.data.housingNumStored or 0
            local placed = self.data.housingNumPlaced or 0
            if ownedFormat then
                GameTooltip:AddLine(sformat(ownedFormat, stored + placed, placed, stored), 1, 1, 1, true)
            end
            if self.data.housingSourceText and self.data.housingSourceText ~= "" then
                GameTooltip:AddLine(self.data.housingSourceText, 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
            return
        end
        -- Macro rows: resolve the #showtooltip / first cast/use line to a
        -- spell or item via the macro APIs and surface that tooltip. Falls
        -- back to displaying the macro body when neither resolves.
        if self.data and self.data.macroIndex and self.data.category == "Macro" then
            local ht = EasyFind.db.hideTooltips
            if ht and ht.macros then return end
            local idx = self.data.macroIndex
            local spellID
            if GetMacroSpell then
                local _, _, sid = GetMacroSpell(idx)
                spellID = sid
            end
            local itemName, itemLink
            if not spellID and GetMacroItem then
                itemName, itemLink = GetMacroItem(idx)
            end
            AnchorRowTooltip(GameTooltip, self)
            if spellID and GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(spellID)
            elseif itemLink and GameTooltip.SetHyperlink then
                GameTooltip:SetHyperlink(itemLink)
            elseif itemName and GameTooltip.SetItemByID and select(2, GetItemInfo(itemName)) then
                GameTooltip:SetHyperlink(select(2, GetItemInfo(itemName)))
            else
                GameTooltip:SetText(self.data.name or (_G["MACRO"] or "Macro"), 1, 1, 1)
                if self.data.macroBody and self.data.macroBody ~= "" then
                    GameTooltip:AddLine(self.data.macroBody, 0.7, 0.7, 0.7, true)
                end
            end
            GameTooltip:Show()
            return
        end
        -- Talent / Ability rows: show the spell tooltip (talents share the
        -- spell tooltip surface). Mirrors the icon-OnEnter path so the row
        -- itself produces a tooltip even when the cursor is on the name.
        if self.data and self.data.spellID
           and (self.data.category == "Talent" or self.data.category == "Ability") then
            local ht = EasyFind.db.hideTooltips
            if ht and ((self.data.category == "Ability" and ht.abilities)
                       or (self.data.category == "Talent" and ht.talents)) then
                return
            end
            AnchorRowTooltip(GameTooltip, self)
            if GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(self.data.spellID)
            else
                GameTooltip:SetHyperlink("spell:" .. self.data.spellID)
            end
            GameTooltip:Show()
            return
        end
        -- Profession recipe row: recipeIDs are spellIDs, so the recipe's
        -- own spell tooltip is the specific surface (crafted output, reagents).
        if self.data and self.data.professionRecipeID then
            AnchorRowTooltip(GameTooltip, self)
            if GameTooltip.SetSpellByID then
                GameTooltip:SetSpellByID(self.data.professionRecipeID)
            else
                GameTooltip:SetHyperlink("spell:" .. self.data.professionRecipeID)
            end
            GameTooltip:Show()
            return
        end
        -- Currency row: show the currency tooltip (icon + description +
        -- amount). Routed early so it doesn't fall through to the
        -- generic icon-tooltip block, which only checks mount / toy /
        -- pet / etc. fields and would otherwise miss currencies.
        if self.data and self.data.category == "Currency" and self.data.currencyID then
            local ht = EasyFind.db.hideTooltips
            if ht and ht.currencies then return end
            local cid = self.data.currencyID
            AnchorRowTooltip(GameTooltip, self)
            if GameTooltip.SetCurrencyByID then
                GameTooltip:SetCurrencyByID(cid)
            elseif C_CurrencyInfo and C_CurrencyInfo.GetCurrencyLink then
                local lok, link = pcall(C_CurrencyInfo.GetCurrencyLink, cid)
                if lok and link and GameTooltip.SetHyperlink then
                    GameTooltip:SetHyperlink(link)
                end
            end
            GameTooltip:Show()
            return
        end
        -- Keybinding row: show the action name plus current bindings.
        if self.data and self.data.settingType == "keybind" and self.data.bindingAction then
            local action = self.data.bindingAction
            AnchorRowTooltip(GameTooltip, self)
            GameTooltip:SetText(self.data.name or action, 1, 1, 1)
            local k1, k2 = GetBindingKey(action)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(sformat(L["KB_PRIMARY"], k1 or (_G["NOT_BOUND"] or "Not Bound")), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(sformat(L["KB_ALTERNATE"], k2 or (_G["NOT_BOUND"] or "Not Bound")), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["KB_CAPTURE_HINT"], 0.5, 0.5, 0.5, true)
            GameTooltip:Show()
            return
        end
        -- Game Settings: show the setting's tooltip text plus current
        -- value. Resolved via BlizzOptionsSearch's tooltip cache (live
        -- SettingsPanel + OPTION_TOOLTIP_* globals).
        if self.data and self.data.settingVariable then
            local var = self.data.settingVariable
            local tipText
            if ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetTooltipForVariable then
                tipText = ns.BlizzOptionsSearch.GetTooltipForVariable(var, self.data.name)
            end
            AnchorRowTooltip(GameTooltip, self)
            GameTooltip:SetText(self.data.name or var, 1, 1, 1)
            if tipText then
                GameTooltip:AddLine(tipText, 1, 0.82, 0, true)
            end
            -- Slider: append current value + range
            if self.data.settingType == "slider" and self.data.settingMin and self.data.settingMax then
                local cur
                if Settings and Settings.GetSetting then
                    local sok, settObj = pcall(Settings.GetSetting, var)
                    if sok and settObj and settObj.GetValue then
                        local vok, v = pcall(settObj.GetValue, settObj)
                        if vok then cur = v end
                    end
                end
                if cur == nil and GetCVar then cur = GetCVar(var) end
                local n = tonumber(cur)
                if n then
                    GameTooltip:AddLine(" ")
                    if not self.data.settingFormatter
                       and ns.BlizzOptionsSearch and ns.BlizzOptionsSearch.GetFormatterForVariable then
                        local fmt = ns.BlizzOptionsSearch.GetFormatterForVariable(var)
                        if fmt then self.data.settingFormatter = fmt end
                    end
                    local valStr
                    if self.data.settingFormatter then
                        local fok, f = pcall(self.data.settingFormatter, n)
                        if fok and f ~= nil then
                            local ft = type(f)
                            if ft == "string" and f ~= "" then
                                valStr = f
                            elseif ft == "number" then
                                valStr = (f == mfloor(f)) and tostring(mfloor(f)) or sformat("%.2f", f)
                            end
                        end
                    end
                    if not valStr then
                        valStr = (n == mfloor(n)) and tostring(mfloor(n)) or sformat("%.2f", n)
                    end
                    GameTooltip:AddLine(sformat(L["SETTING_CURRENT_RANGE"],
                        valStr,
                        tostring(self.data.settingMin),
                        tostring(self.data.settingMax)), 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
            return
        end

        if self.isUnearnedCurrency or self.lockedReason then
            if GetUnearnedTooltip() then
                local tooltipText = self.lockedReason
                    or (self.isPathNode and L["TAB_NOT_ON_CHARACTER"] or L["CURRENCY_NOT_EARNED"])
                local unearned = GetUnearnedTooltip()
                unearned.text:SetText(tooltipText)
                unearned:SetSize(unearned.text:GetStringWidth() + 20, unearned.text:GetStringHeight() + 16)
                -- UIParent-level frame, so match the search scale like the
                -- GameTooltip path in AnchorRowTooltip does.
                Tooltips.ApplySearchTooltipScale(unearned)
                if not Tooltips:PlaceAtPanelEdge(unearned, self) then
                    local scale = UIParent:GetEffectiveScale()
                    local x, y = GetCursorPosition()
                    unearned:ClearAllPoints()
                    unearned:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 10, y / scale + 10)
                end
                unearned:Show()
            end
        elseif self.data and self.data.mapSearchResult then
            -- Map result: preview pin on world map if it happens to be open
            if ns.MapSearch and ns.MapSearch.PreviewUIResult then
                ns.MapSearch:PreviewUIResult(self.data)
            end
        elseif self.data and self.icon and self.icon:IsShown() then
            -- Per-flyout tooltip suppression. Collections covers the
            -- mount / toy / pet / outfit / heirloom / appearance set
            -- group; loot (the gear flyout's "Hide tooltips") covers
            -- itemized gear results AND any bag item that's actual
            -- gear. The entry being a "Bag" by category is incidental
            -- to where it lives, the user-facing class of thing is
            -- "gear" either way.
            local ht = EasyFind.db.hideTooltips
            local ic = self.icon
            if ht and ht.collections and (ic.mountID or ic.toyItemID or ic.petID
                or ic.outfitID or ic.heirloomItemID or ic.transmogSetID or ic.appearanceItemID) then
                return
            end
            if ht and ht.loot then
                if ic.lootItemID then return end
                if ic.bagItemID and self.data and self.data.equipLoc then
                    local slot = self.data.equipLoc
                    if slot ~= "" and slot ~= "INVTYPE_NON_EQUIP"
                       and slot ~= "INVTYPE_AMMO" and slot ~= "INVTYPE_QUIVER" then
                        return
                    end
                end
            end
            -- Bags "Hide tooltips" suppresses every bag item, gear or not.
            if ht and ht.bags and self.data.category == "Bag" then return end
            -- Mount tooltip (show on icon hover)
            if self.icon.mountID and self.icon.spellID then
                AnchorRowTooltip(GameTooltip, self)
                GameTooltip:SetMountBySpellID(self.icon.spellID)
                GameTooltip:Show()
            elseif self.icon.toyItemID then
                local toyItemID = self.icon.toyItemID
                AnchorRowTooltip(GameTooltip, self)
                GameTooltip:SetToyByItemID(toyItemID)
                GameTooltip:Show()
                if self.toyTooltipTicker then self.toyTooltipTicker:Cancel() end
                self.toyTooltipTicker = C_Timer.NewTicker(1, function(ticker)
                    local ok = Utils.xpcall(function()
                        if GameTooltip:IsOwned(self) then
                            GameTooltip:SetToyByItemID(toyItemID)
                        end
                    end, Utils.ErrorHandler)
                    if not ok then
                        ticker:Cancel()
                        if self.toyTooltipTicker == ticker then
                            self.toyTooltipTicker = nil
                        end
                    end
                end)
            -- Pet tooltip (use BattlePetToolTip via the link, since GameTooltip
            -- only renders battle pet links as raw escape codes)
            elseif self.icon.petID then
                local link = C_PetJournal and C_PetJournal.GetBattlePetLink
                    and C_PetJournal.GetBattlePetLink(self.icon.petID)
                if link and BattlePetToolTip_ShowLink then
                    AnchorRowTooltip(GameTooltip, self)
                    BattlePetToolTip_ShowLink(link)
                elseif link then
                    AnchorRowTooltip(GameTooltip, self)
                    GameTooltip:SetHyperlink(link)
                    GameTooltip:Show()
                end
            elseif self.icon.outfitID then
                AnchorRowTooltip(GameTooltip, self)
                GameTooltip:SetText(self.data and self.data.name or _G["TRANSMOG_OUTFIT_NAME_DEFAULT"] or "Outfit")
                GameTooltip:AddLine(_G["SPELL_CAST_TIME_INSTANT"] or "Instant", 1, 1, 1)
                GameTooltip:AddLine(L["TMOG_DESC"], 0, 1, 0)
                local activeID = Rows.lastEquippedOutfitID
                    or (C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                        and C_TransmogOutfitInfo.GetActiveOutfitID())
                if activeID and activeID == self.icon.outfitID then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(_G["CURRENTLY_EQUIPPED"] or "Currently equipped", 0.3, 1, 0.3)
                else
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(L["TMOG_CLICK_EQUIP"], 1, 0.82, 0)
                end
                if C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(L["TMOG_LOCK_LABEL"], 1, 1, 1)
                    GameTooltip:AddLine(L["TMOG_LOCK_DESC"], 1, 0.82, 0)
                    if C_TransmogOutfitInfo.IsLockedOutfit(self.icon.outfitID) then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine(L["TMOG_LOCKED"], 0.3, 1, 0.3)
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(L["TMOG_LOCK_TOGGLE_HINT"], 0.5, 0.5, 0.5)
                end
                GameTooltip:Show()
            elseif self.icon.lootItemID then
                AnchorRowTooltip(GameTooltip, self)
                local itemLink = self.data and ns.Database and ns.Database:GetLootItemLink(self.data)
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(self.icon.lootItemID)
                end
                GameTooltip:Show()
            elseif self.icon.heirloomItemID then
                AnchorRowTooltip(GameTooltip, self)
                GameTooltip:SetItemByID(self.icon.heirloomItemID)
                GameTooltip:Show()
            elseif self.icon.appearanceItemID then
                AnchorRowTooltip(GameTooltip, self)
                local srcInfo = C_TransmogCollection and C_TransmogCollection.GetSourceInfo
                    and C_TransmogCollection.GetSourceInfo(self.icon.appearanceItemID)
                if srcInfo and srcInfo.itemID then
                    GameTooltip:SetItemByID(srcInfo.itemID)
                else
                    GameTooltip:SetText(self.data and self.data.name or "")
                end
                GameTooltip:Show()
            -- Gear sets intentionally show no tooltip: the row already says
            -- "Click to equip" and a set has nothing else worth surfacing.
            -- Ability tooltip (must come after mount, since mount entries
            -- carry both mountID and spellID and use the mount tooltip).
            elseif self.icon.spellID then
                AnchorRowTooltip(GameTooltip, self)
                if GameTooltip.SetSpellByID then
                    GameTooltip:SetSpellByID(self.icon.spellID)
                else
                    GameTooltip:SetHyperlink("spell:" .. self.icon.spellID)
                end
                GameTooltip:Show()
            -- Bag item tooltip. Real gear (helm/chest/weapon/etc.) gets
            -- the panel-edge buffer because of the compare frame; bag
            -- consumables / containers are normal-sized so they follow
            -- the cursor like everything else.
            elseif self.icon.bagItemID then
                local slot = self.data and self.data.equipLoc
                local isGear = slot and slot ~= "" and slot ~= "INVTYPE_NON_EQUIP"
                              and slot ~= "INVTYPE_AMMO" and slot ~= "INVTYPE_QUIVER"
                if isGear then
                    AnchorRowTooltip(GameTooltip, self)
                else
                    AnchorRowTooltip(GameTooltip, self)
                end
                local link = self.data and self.data.bagItemLink
                if link then
                    GameTooltip:SetHyperlink(link)
                else
                    GameTooltip:SetItemByID(self.icon.bagItemID)
                end
                GameTooltip:Show()
            end
        end
    end)

    resultRow:SetScript("OnLeave", function(self)
        self._efHlHover = nil
        if Results._hoverRow == self then Results._hoverRow = nil end
        Results:UpdateRowWash(self)
        if GetUnearnedTooltip() then
            GetUnearnedTooltip():Hide()
        end
        if self.toyTooltipTicker then
            self.toyTooltipTicker:Cancel()
            self.toyTooltipTicker = nil
        end
        if GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
        -- BattlePetTooltip is a separate frame; hide it on row leave so
        -- the pet card doesn't linger after the cursor moves away.
        if self.data and self.data.petID and BattlePetTooltip then
            BattlePetTooltip:Hide()
        end
        if self.data and self.data.mapSearchResult and ns.MapSearch and ns.MapSearch.ClearUIPreview then
            ns.MapSearch:ClearUIPreview()
        end
        if Handlers:IsActionHintRow(self) then
            Handlers:ClearActionHint()
            local selRow = Search:GetSelectedIndex() > 0 and Search:GetResultButtons()[Search:GetSelectedIndex()] or nil
            if selRow and selRow ~= self and not Search:GetToggleFocused() then
                Handlers:ApplyActionHint(selRow)
            end
        end
    end)
end
