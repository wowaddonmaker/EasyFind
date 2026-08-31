local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Utils = ns.Utils
local Render = ns.ResultRender
local Icons = ns.ResultIcons

local select, ipairs = Utils.select, Utils.ipairs
local sfind = Utils.sfind
local InCombatLockdown = InCombatLockdown
local sgsub, supper = string.gsub, string.upper

-- The catalog blob stores names lowercase-only (the in-place scan needs a
-- lowercase corpus, and storing both cases would double 6.3MB), so the
-- uncached-item fallback used to flash raw lowercase until GetItemInfo
-- resolved. Title-case the placeholder instead: visually right for nearly
-- every item name, and the official name still replaces it on resolve.
-- Small connective words stay lowercase per item-name convention.
local TITLE_SMALL_WORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["or"] = true, ["in"] = true, ["on"] = true,
    ["to"] = true, ["for"] = true, ["with"] = true, ["from"] = true,
    ["at"] = true, ["by"] = true,
}
local titleCaseFirst
local function TitleCaseWord(word)
    if not titleCaseFirst and TITLE_SMALL_WORDS[word] then return word end
    titleCaseFirst = false
    return (sgsub(word, "^%l", supper))
end
local function TitleCaseName(lower)
    titleCaseFirst = true
    return (sgsub(lower, "%S+", TitleCaseWord))
end
local collapsedNodes = Results._collapsedNodes

-- Inline amounts (statistic values, quantities, owned counts). The warm
-- parchment tone is tuned for dark fills; light themes match the muted
-- alt-hint tone so inline numbers sit at the same weight as the hints.
local function PaintAmountText(amountText, inert)
    local theme = Results.GetActiveTheme and Results:GetActiveTheme()
    if theme and theme.lightTheme then
        local c = inert and theme.textFaint or theme.mutedGlyph
        amountText:SetTextColor(c[1], c[2], c[3], 1)
    elseif inert then
        amountText:SetTextColor(0.5, 0.5, 0.5, 1.0)
    else
        amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
    end
end
local GetButtonIcon = Icons.GetButtonIcon
local GetFrameArtworkIcon = Icons.GetFrameArtworkIcon
local IsMenuBarSpecificIconData = Icons.IsMenuBarSpecificIconData
local SetButtonFrameIcon = Icons.SetButtonFrameIcon
local BOSS_PORTRAIT_TEXCOORD = Render.BOSS_PORTRAIT_TEXCOORD

function Render.RowContent(owner, resultRow, entry, state, isInertRow)
    local data = entry.data
    local depth = entry.depth or 0
    local theme = state.theme
    local rowIconSize = state.rowIconSize
    local indPx = state.indPx
    local entryRowH = state.entryRowH
    local hasRepSideBySide = false
    local iconSet = false
    -- Clear leftover cooldown sweep from prior render. Only the
    -- toy/ability/outfit branch re-enables it; every other branch
    -- (map results, currencies, settings, etc.) leaves it alone, so
    -- without this clear a recycled row keeps the previous sweep.
    if resultRow.iconCooldown then resultRow.iconCooldown:Hide() end
    local isCurrencyItem = data and data.category == "Currency"
    local isCurrencyLeaf = isCurrencyItem and not entry.isPathNode
    local isReputationLeaf = data and data.category == "Reputation" and not entry.isPathNode

    if entry.isSectionHeader then
        -- Section dividers: no icon, no main text. The
        -- centered sectionLabelText handles the visual.
        Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        resultRow.amountText:Hide()
        if resultRow.repBar then resultRow.repBar:Hide() end
        iconSet = true

    elseif entry.isPinHeader then
        -- Pin header: no row icon (toggle is handled by pinToggle)
        Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        iconSet = true

    elseif theme.showHeaderTab and entry.isPathNode then
        Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        iconSet = true

    elseif entry.isPathNode then
        local key = entry.name .. "_" .. depth
        local nodeCollapsed = collapsedNodes[key]
        local iconPath = nodeCollapsed and theme.expandIcon or theme.collapseIcon
        Icons:SetRowIcon(resultRow, "path", iconPath, theme.pathIconSize)
        iconSet = true
    end

    -- Resolve currency icon on the fly if not cached
    if not iconSet and isCurrencyItem and data and not data.icon and data.steps then
        for si = #data.steps, 1, -1 do
            local cid = data.steps[si].currencyID
            if cid then
                local ci = Render.GetCachedCurrencyInfo(cid)
                if ci and ci.iconFileID and ci.iconFileID ~= 0 then
                    data.icon = ci.iconFileID
                end
                break
            end
        end
    end

    -- Currency leaves: icon goes right of amount, not left of name
    if isCurrencyLeaf and data and data.steps then
        local quantity, iconFileID
        for si = #data.steps, 1, -1 do
            local cid = data.steps[si].currencyID
            if cid then
                local ci = Render.GetCachedCurrencyInfo(cid)
                if ci then
                    quantity = ci.quantity
                    iconFileID = data.icon or (ci.iconFileID ~= 0 and ci.iconFileID) or nil
                end
                break
            end
        end

        if quantity then
            resultRow.amountText:SetText(tostring(quantity))
            PaintAmountText(resultRow.amountText, isInertRow)
            resultRow.amountText:Show()
        else
            resultRow.amountText:Hide()
        end

        -- Move icon to right side (right of amount text)
        if iconFileID then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetTexture(iconFileID)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
            resultRow.amountText:ClearAllPoints()
            resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
            resultRow.amountText:ClearAllPoints()
            resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        end

        -- Show unified currency category icon on the LEFT (matches map AH glyph).
        -- indentPixels matches the non-currency leaf calculation so the
        -- currency icon lines up horizontally with normal row icons.
        local indentPixels = depth * indPx
        local leftAnchor
        local catIconDef = Icons:GetFlatCategoryIcon({ category = "Currency" })
        if catIconDef and resultRow.flatCatIcon then
            local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
            if catIconDef.atlas then
                resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
            else
                resultRow.flatCatIcon:SetTexture(catIconDef.tex)
            end
            resultRow.flatCatIcon:SetDesaturated(false)
            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
            ns.SizeIconAspect(resultRow.flatCatIcon, sz, catIconDef and catIconDef.aspect)
            resultRow.flatCatIcon:ClearAllPoints()
            resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
            resultRow.flatCatIcon:Show()
            leftAnchor = resultRow.flatCatIcon
        end

        resultRow.text:ClearAllPoints()
        if leftAnchor then
            resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
        else
            resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
        end
        resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
        -- Re-clip now that amountText (and therefore text's right
        -- boundary) has its final position for this row. The earlier
        -- SetClippedText ran against the previous row's amountText
        -- width, which truncated some currencies unnecessarily.
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    -- Housing decor leaves: housing glyph on the LEFT like every other flat
    -- category, the decor's own render on the RIGHT, with the owned count
    -- beside it when more than one copy is owned.
    elseif data and data.housingEntryID and data.category == "Housing" and not entry.isPathNode then
        local owned = (data.housingNumStored or 0) + (data.housingNumPlaced or 0)
        if owned > 1 then
            resultRow.amountText:SetText(owned)
            PaintAmountText(resultRow.amountText, false)
            resultRow.amountText:Show()
        else
            resultRow.amountText:SetText("")
            resultRow.amountText:Hide()
        end

        if data.icon then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetTexture(data.icon)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
            resultRow.amountText:ClearAllPoints()
            resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
            resultRow.amountText:ClearAllPoints()
            resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        end

        local indentPixels = depth * indPx
        local leftAnchor
        local catIconDef = Icons:GetFlatCategoryIcon(data)
        if catIconDef and resultRow.flatCatIcon then
            local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
            if catIconDef.atlas then
                resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
            else
                resultRow.flatCatIcon:SetTexture(catIconDef.tex)
            end
            resultRow.flatCatIcon:SetDesaturated(false)
            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
            ns.SizeIconAspect(resultRow.flatCatIcon, sz, catIconDef and catIconDef.aspect)
            resultRow.flatCatIcon:ClearAllPoints()
            resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
            resultRow.flatCatIcon:Show()
            leftAnchor = resultRow.flatCatIcon
        end
        resultRow.text:ClearAllPoints()
        if leftAnchor then
            resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
        else
            resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
        end
        resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    -- Statistic rows: show the live stat value inline via amountText.
    -- GetStatistic returns a string ("394", "23%", "1d 4h 12m") or
    -- "--" for stats with no recorded value yet.
    elseif data and data.statisticID and not entry.isPathNode then
        local value, hasValue = ns.GetStatisticValue(data.statisticID)
        if hasValue then
            resultRow.amountText:SetText(value)
            PaintAmountText(resultRow.amountText, false)
        else
            resultRow.amountText:SetText("--")
            PaintAmountText(resultRow.amountText, true)
        end
        resultRow.amountText:ClearAllPoints()
        resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        resultRow.amountText:Show()
        Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)

        local indentPixels = depth * indPx
        local leftAnchor
        local catIconDef = Icons:GetFlatCategoryIcon({ category = "Statistic" })
        if catIconDef and resultRow.flatCatIcon then
            local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
            resultRow.flatCatIcon:SetTexture(catIconDef.tex)
            if catIconDef.coords then
                resultRow.flatCatIcon:SetTexCoord(catIconDef.coords[1], catIconDef.coords[2],
                                                  catIconDef.coords[3], catIconDef.coords[4])
            else
                resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
            end
            resultRow.flatCatIcon:SetDesaturated(false)
            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
            ns.SizeIconAspect(resultRow.flatCatIcon, sz, catIconDef and catIconDef.aspect)
            resultRow.flatCatIcon:ClearAllPoints()
            resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
            resultRow.flatCatIcon:Show()
            leftAnchor = resultRow.flatCatIcon
        end
        resultRow.text:ClearAllPoints()
        if leftAnchor then
            resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
        else
            resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
        end
        resultRow.text:SetPoint("RIGHT", resultRow.amountText, "LEFT", -4, 0)
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    elseif data and data.calculatorResult and not entry.isPathNode then
        iconSet = Render.CalculatorRow(owner, resultRow, data, state)

    -- Entry-specific leaf icons: keep the category icon on the
    -- left in flat mode, and put the specific item/spell/achievement
    -- art on the right.
    elseif not iconSet and data and (data.specificIcon or data.specificIconFrame) then
        local specificIcon = data.specificIcon or data._resolvedSpecificIcon
        if not specificIcon and data.specificIconFrame then
            specificIcon = GetFrameArtworkIcon(data.specificIconFrame)
            if specificIcon then data._resolvedSpecificIcon = specificIcon end
        end
        if specificIcon then
            Icons:SetRowIcon(resultRow, "file", specificIcon, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end
        resultRow.amountText:Hide()
        resultRow.text:ClearAllPoints()
        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
        if specificIcon then
            resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        else
            resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        end
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    elseif not iconSet and IsMenuBarSpecificIconData(data) then
        local hasSpecificIcon = SetButtonFrameIcon(resultRow, data.buttonFrame, rowIconSize)
        if hasSpecificIcon then
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end
        resultRow.amountText:Hide()
        resultRow.text:ClearAllPoints()
        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
        if hasSpecificIcon then
            resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        else
            resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        end
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    -- speciesID rides alongside petID here: an uncollected pet has no petID
    -- (that GUID exists only once owned), and without it the row fell through
    -- to the generic branch, putting the pet's own art in the category slot.
    elseif not iconSet and data and (data.mountID or data.toyItemID or data.petID or data.speciesID or data.outfitID or data.heirloomItemID or data.gearSetID or data.transmogSetID or data.appearanceItemID or (data.spellID and data.category == "Ability") or (data.spellID and data.category == "Talent") or (data.encounterID and data.category == "Boss") or (data.macroIndex and data.category == "Macro") or (data.bagID and data.category == "Bag") or data.storedHolders or (data.achievementID and data.category == "Achievement") or data.professionSkillLine) then
        local iconFileID = data.icon
        local rightOffset = -5

        -- Stored rows render from a cached name/icon, so the client may never
        -- have loaded the item itself; warm it so click-to-link can pick it up.
        -- Deliberately NOT ItemSearch:NoteUncachedItem: that one re-runs the
        -- whole search when the data lands, which is right for catalog rows
        -- (their name and icon resolve live) but here means render -> request
        -- -> arrival -> re-search -> render, a loop that lags the bar and
        -- resets the scroll position. These rows already have their name.
        if data.storedHolders and data.itemID
           and C_Item and C_Item.RequestLoadItemDataByID
           and C_Item.IsItemDataCachedByID
           and not C_Item.IsItemDataCachedByID(data.itemID) then
            C_Item.RequestLoadItemDataByID(data.itemID)
        end

        if iconFileID then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetTexture(iconFileID)
            if Render.IsBossResultData(data) then
                resultRow.icon:SetTexCoord(unpack(BOSS_PORTRAIT_TEXCOORD))
            end
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", rightOffset, 0)
            resultRow.icon:Show()
            resultRow.icon.mountID = data.mountID
            resultRow.icon.toyItemID = data.toyItemID
            resultRow.icon.petID = data.petID
            resultRow.icon.speciesID = data.speciesID
            resultRow.icon.spellID = data.spellID or data.professionRecipeID
            resultRow.icon.outfitID = data.outfitID
            resultRow.icon.heirloomItemID = data.heirloomItemID
            resultRow.icon.appearanceItemID = data.appearanceItemID
            resultRow.icon.gearSetID = data.gearSetID
            resultRow.icon.bagItemID = (data.category == "Bag" or data.category == "Bank")
                and data.itemID or nil
            resultRow.icon.lootItemID = nil
            resultRow.icon.achievementID = data.achievementID
            resultRow.icon.lootItemID = nil
            -- Red tint on mount icons when in combat (can't mount)
            if data.mountID and InCombatLockdown() then
                resultRow.icon:SetVertexColor(1, 0.3, 0.3, 1)
            elseif data.outfitID then
                local activeID = select(3, Search:GetOutfitCooldownState())
                activeID = activeID or (C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                    and C_TransmogOutfitInfo.GetActiveOutfitID())
                if activeID and activeID == data.outfitID then
                    resultRow.icon:SetVertexColor(0.3, 1, 0.3, 1)
                else
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                end
            -- Talents: desaturate the per-talent icon if not in
            -- the player's current allocation. Allocated talents
            -- (chosen choice option, or non-zero rank on regular
            -- nodes) render full color.
            elseif data.category == "Talent" then
                if data.talentIsAllocated then
                    resultRow.icon:SetVertexColor(1, 1, 1, 1)
                else
                    resultRow.icon:SetVertexColor(0.4, 0.4, 0.4, 1)
                end
            else
                resultRow.icon:SetVertexColor(1, 1, 1, 1)
            end
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end

        -- Outfit lock overlay (dashed border when locked)
        if data.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.IsLockedOutfit then
            Search:UpdateOutfitLockOverlay(resultRow, C_TransmogOutfitInfo.IsLockedOutfit(data.outfitID))
        elseif resultRow._lockOverlay then
            Search:UpdateOutfitLockOverlay(resultRow, false)
        end

        -- Gear set assigned to a spec: badge its icon like the Equipment Manager
        if data.gearSetSpecIcon or resultRow._specBadge then
            Search:UpdateGearSetSpecBadge(resultRow, data.gearSetSpecIcon)
        end

        -- Cooldown sweep overlay (toys, abilities, outfits)
        resultRow.amountText:Hide()
        if data.toyItemID and iconFileID and GetItemCooldown then
            local startTime, duration = GetItemCooldown(data.toyItemID)
            if startTime and duration and duration > 0 then
                resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                resultRow.iconCooldown:SetCooldown(startTime, duration)
                resultRow.iconCooldown:Show()
            else
                resultRow.iconCooldown:Hide()
            end
        elseif data.spellID and data.category == "Ability" and iconFileID and C_Spell and C_Spell.GetSpellCooldown then
            local cd = C_Spell.GetSpellCooldown(data.spellID)
            if cd and cd.startTime and cd.duration and cd.duration > 0 then
                resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                resultRow.iconCooldown:SetCooldown(cd.startTime, cd.duration)
                resultRow.iconCooldown:Show()
            else
                resultRow.iconCooldown:Hide()
            end
        elseif data.outfitID and Search:IsOutfitCooldownActive() then
            local outfitCdStart, outfitCdDuration = Search:GetOutfitCooldownState()
            local remaining = outfitCdDuration - (GetTime() - outfitCdStart)
            if remaining > 0 then
                resultRow.iconCooldown:SetAllPoints(resultRow.icon)
                resultRow.iconCooldown:SetCooldown(outfitCdStart, outfitCdDuration)
                resultRow.iconCooldown:Show()
            else
                resultRow.iconCooldown:Hide()
            end
        else
            resultRow.iconCooldown:Hide()
        end

        local indentPixels = depth * indPx + 4
        resultRow.text:ClearAllPoints()
        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
        resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        -- Re-clip against the new RIGHT bound (icon:LEFT) -- the
        -- path branch's earlier SetClippedText ran against
        -- amountText:LEFT from the previous row.
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    -- App launcher rows (calculator, icon search). LEFT: the apps-button
    -- waffle (set by the flat renderer via GetFlatCategoryIcon). RIGHT: the
    -- app's own glyph, desaturated and chrome-tinted like the apps menu.
    elseif not iconSet and data and (data.calculatorLauncher or data.iconSearchLauncher) then
        local appGlyph = Icons:GetAppGlyphIcon(data)
        if appGlyph then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetTexture(appGlyph.tex)
            local gc = ns.ChromeGlyphColor()
            resultRow.icon:SetDesaturated(true)
            resultRow.icon:SetVertexColor(gc[1], gc[2], gc[3], 1)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
            Icons.ClearRowIconLeafIDs(resultRow.icon)
            resultRow.amountText:ClearAllPoints()
            resultRow.amountText:SetPoint("RIGHT", resultRow.icon, "LEFT", -3, 0)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end
        iconSet = true

    -- Catalog items (the full game item DB). LEFT: the Item category glyph.
    -- RIGHT: the item's own icon. Middle: quality-colored name. Icon and name
    -- resolve live from the itemID (the shipped blob stores neither).
    elseif not iconSet and data and data.catalogItem then
        resultRow.amountText:Hide()
        resultRow.iconCooldown:Hide()
        local id = data.itemID

        -- LEFT category icon (the shared Item glyph).
        local indentPixels = depth * indPx
        local leftAnchor
        local catIconDef = Icons:GetFlatCategoryIcon(data)
        if catIconDef and resultRow.flatCatIcon then
            local sz = entry.isFlat and (entryRowH - 16) or rowIconSize
            if catIconDef.atlas then
                resultRow.flatCatIcon:SetAtlas(catIconDef.atlas)
            else
                resultRow.flatCatIcon:SetTexture(catIconDef.tex)
                if catIconDef.coords then
                    resultRow.flatCatIcon:SetTexCoord(catIconDef.coords[1], catIconDef.coords[2],
                                                      catIconDef.coords[3], catIconDef.coords[4])
                else
                    resultRow.flatCatIcon:SetTexCoord(0, 1, 0, 1)
                end
            end
            resultRow.flatCatIcon:SetDesaturated(false)
            resultRow.flatCatIcon:SetVertexColor(1, 1, 1, 1)
            ns.SizeIconAspect(resultRow.flatCatIcon, sz, catIconDef and catIconDef.aspect)
            resultRow.flatCatIcon:ClearAllPoints()
            resultRow.flatCatIcon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
            resultRow.flatCatIcon:Show()
            leftAnchor = resultRow.flatCatIcon
        end

        -- RIGHT: the item's own icon.
        local itemIcon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
        if itemIcon then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
            resultRow.icon:SetTexture(itemIcon)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
            Icons.ClearRowIconLeafIDs(resultRow.icon)
            resultRow.icon.catalogItemID = id
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end

        -- Name -- NEVER blank. GetItemInfo/GetItemNameByID return nil OR an
        -- empty string for an uncached item ("" is truthy in Lua), so guard
        -- every source against "", and fall back to the shipped blob name and
        -- finally a visible "Item #id" so a resolution failure is diagnosable,
        -- not an empty row.
        local displayName
        if GetItemInfo then displayName = GetItemInfo(id) end
        if (not displayName or displayName == "") and C_Item and C_Item.GetItemNameByID then
            displayName = C_Item.GetItemNameByID(id)
        end
        if not displayName or displayName == "" then
            -- Uncached: request the data + re-render when it lands, so this
            -- lowercase blob fallback is replaced by the official name.
            if ns.ItemSearch and ns.ItemSearch.NoteUncachedItem then
                ns.ItemSearch:NoteUncachedItem(id)
            end
            displayName = TitleCaseName(data.nameLower or entry.name or "")
        end
        if not displayName or displayName == "" then displayName = "Item #" .. tostring(id) end
        local qc = data.quality and _G["ITEM_QUALITY_COLORS"] and _G["ITEM_QUALITY_COLORS"][data.quality]
        if qc and qc.hex then displayName = qc.hex .. displayName .. "|r" end

        resultRow.text:ClearAllPoints()
        if leftAnchor then
            resultRow.text:SetPoint("LEFT", leftAnchor, "RIGHT", 4, 0)
        else
            resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels + 4, 0)
        end
        resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        resultRow.text:SetText(displayName)
        iconSet = true

    -- Loot items: icon on right with source name inline
    elseif not iconSet and data and data.itemID and data.category == "Loot" then
        local iconFileID = data.icon
        if iconFileID then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetTexture(iconFileID)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
            Icons.ClearRowIconLeafIDs(resultRow.icon)
            resultRow.icon.lootItemID = data.itemID
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end
        resultRow.amountText:Hide()
        resultRow.iconCooldown:Hide()
        if data.lootSourceName then
            resultRow.text:SetText(data.name .. "  |cff888888" .. data.lootSourceName .. "|r")
        end
        local indentPixels = depth * indPx + 4
        resultRow.text:ClearAllPoints()
        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
        resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        iconSet = true

    -- Map search results: per-POI icon (flightmaster, bank, dungeon
    -- entrance, etc.) on the RIGHT. The LEFT generic-map glyph is
    -- already handled by the flat-mode block above via GetFlatCategoryIcon
    -- (which returns FLAT_CATEGORY_ICONS.map for mapSearchResult rows).
    elseif not iconSet and data and data.mapSearchResult then
        resultRow.amountText:Hide()
        local mapIcon = data.icon
        if mapIcon then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexCoord(0, 1, 0, 1)
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
            if type(mapIcon) == "table" then
                resultRow.icon:SetTexture(mapIcon.file)
                resultRow.icon:SetTexCoord(unpack(mapIcon.coords))
            elseif type(mapIcon) == "string" and sfind(mapIcon, "^atlas:") then
                resultRow.icon:SetAtlas(mapIcon:sub(7))
            else
                resultRow.icon:SetTexture(mapIcon)
            end
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)
            resultRow.icon:Show()
        else
            Icons:SetRowIcon(resultRow, "hidden", nil, rowIconSize)
        end
        resultRow.text:ClearAllPoints()
        resultRow.text:SetPoint("LEFT", resultRow, "LEFT", depth * indPx + 4, 0)
        if mapIcon then
            resultRow.text:SetPoint("RIGHT", resultRow.icon, "LEFT", -4, 0)
        else
            resultRow.text:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        end
        Render.SetClippedText(resultRow.text, entry.name)
        iconSet = true

    -- Reputation leaves: faction-side crest on the LEFT, rep bar on
    -- the right (rendered later in the showRepBar block).
    elseif not iconSet and isReputationLeaf and data and data.factionID then
        local repIcon = Icons:GetRepFactionIcon(data.factionSide or "either")
        if repIcon then
            resultRow.icon:SetTexture(nil)
            resultRow.icon:SetTexture(repIcon.tex)
            if repIcon.coords then
                resultRow.icon:SetTexCoord(unpack(repIcon.coords))
            else
                resultRow.icon:SetTexCoord(0, 1, 0, 1)
            end
            resultRow.icon:SetVertexColor(1, 1, 1, 1)
            resultRow.icon:SetSize(rowIconSize, rowIconSize)
            resultRow.icon:ClearAllPoints()
            local indentPixels = depth * indPx + 4
            resultRow.icon:SetPoint("LEFT", resultRow, "LEFT", indentPixels, 0)
            resultRow.icon:Show()
            resultRow.text:ClearAllPoints()
            resultRow.text:SetPoint("LEFT", resultRow.icon, "RIGHT", 4, 0)
        end
        resultRow.amountText:Hide()
        resultRow.amountText:ClearAllPoints()
        resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
        iconSet = true

    else
        resultRow.amountText:Hide()
        resultRow.amountText:ClearAllPoints()
        resultRow.amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    end

    do
        local repSideBySide
        iconSet, repSideBySide = Render.ReputationBar(resultRow, entry, state, isReputationLeaf, iconSet)
        if repSideBySide then hasRepSideBySide = true end
    end

    -- Game Settings: cogwheel atlas in non-flat mode (flat mode
    -- uses flatCatIcon via GetFlatCategoryIcon).
    if not iconSet and data and data.category == "Game Settings" then
        Icons:SetRowIcon(resultRow, "atlas", "QuestLog-icon-setting", rowIconSize)
        iconSet = true
    end

    if not iconSet and data and data.iconAtlas then
        Icons:SetRowIcon(resultRow, "atlas", data.iconAtlas, rowIconSize)
        iconSet = true
    end

    if not iconSet and data and data.icon then
        Icons:SetRowIcon(resultRow, "file", data.icon, rowIconSize)
        iconSet = true
    end

    -- Portrait menu items: use the player portrait as the icon
    if not iconSet and data and data.steps then
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                SetPortraitTexture(resultRow.icon, "player")
                resultRow.icon:SetTexCoord(0, 1, 0, 1)
                resultRow.icon:SetSize(rowIconSize, rowIconSize)
                resultRow.icon:Show()
                iconSet = true
                break
            end
        end
    end

    -- Resolve sidebar tab icons at runtime (e.g. Equipment Manager, Titles)
    -- The tab textures are sprite sheets - copy the ARTWORK-layer texture
    -- along with its tex coords so only the icon portion is shown.
    if not iconSet and data and data.steps then
        for _, step in ipairs(data.steps) do
            if step.sidebarIndex then
                local tab = _G["PaperDollSidebarTab" .. step.sidebarIndex]
                if tab then
                    for ri = 1, select("#", tab:GetRegions()) do
                        local region = select(ri, tab:GetRegions())
                        if region and region:GetObjectType() == "Texture"
                           and region:GetDrawLayer() == "ARTWORK" then
                            local tex = region:GetTexture()
                            -- Skip render targets (e.g. RTPortrait1 for the player model)
                            if tex and type(tex) == "string" and tex:find("^RT") then
                                break
                            end
                            if tex then
                                local ulX, ulY, llX, llY, urX, urY, lrX, lrY = region:GetTexCoord()
                                resultRow.icon:SetTexture(tex)
                                resultRow.icon:SetTexCoord(ulX, ulY, llX, llY, urX, urY, lrX, lrY)
                                resultRow.icon:SetSize(rowIconSize, rowIconSize)
                                resultRow.icon:Show()
                                iconSet = true
                            end
                            break
                        end
                    end
                    -- Fallback for render target tabs: use player portrait
                    if not iconSet then
                        SetPortraitTexture(resultRow.icon, "player")
                        resultRow.icon:SetTexCoord(0, 1, 0, 1)
                        resultRow.icon:SetSize(rowIconSize, rowIconSize)
                        resultRow.icon:Show()
                        iconSet = true
                    end
                end
                break
            end
        end
    end

    -- Skip buttonFrame fallback for currency items - their inherited
    -- "CharacterMicroButton" produces a wrong MicroMenu atlas icon.
    if not iconSet and not isCurrencyItem and data and data.buttonFrame then
        local texture, isAtlas = GetButtonIcon(data.buttonFrame)
        if texture then
            local kind = isAtlas and "atlas" or "file"
            Icons:SetRowIcon(resultRow, kind, texture, rowIconSize)
            iconSet = true
        end
    end

    -- CharacterMicroButton draws the player's own portrait from a render
    -- texture, so GetButtonIcon deliberately refuses it (capturing it yields
    -- garbage). Rows under it that also have no sidebarIndex -- Currency,
    -- Reputation -- therefore reached the question mark. Use the portrait
    -- directly, the same fallback the sidebar-tab resolver above uses.
    if not iconSet and data and data.buttonFrame == "CharacterMicroButton"
       and SetPortraitTexture then
        SetPortraitTexture(resultRow.icon, "player")
        resultRow.icon:SetTexCoord(0, 1, 0, 1)
        resultRow.icon:SetSize(rowIconSize, rowIconSize)
        resultRow.icon:Show()
        iconSet = true
    end

    if not iconSet then
        Icons:SetRowIcon(resultRow, "file", 134400, rowIconSize)
    end

    Render.SettingsWidget(resultRow, data, entry)
    return hasRepSideBySide
end
