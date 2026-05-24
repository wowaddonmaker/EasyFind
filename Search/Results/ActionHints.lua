local _, ns = ...

local Handlers = ns.ResultHandlers
local Shortcuts = ns.ResultShortcuts
local Icons = ns.ResultIcons
local Text = ns.ResultText

local IsAltKeyDown = IsAltKeyDown

function Handlers:IsSourceModifierHeld()
    return IsAltKeyDown and IsAltKeyDown() and not Shortcuts._resultShortcutActivation
end

-- Hint shown only on the currently-selected row, replacing the normal
-- subtext so the user knows what Enter / left-click will do without
-- cluttering every other row. Returns nil for entries whose action
-- isn't worth labelling (Search navigation, settings: the row name itself
-- already tells you what happens).

function Handlers:GetActionHint(data)
    if not data then return nil end
    if data.calculatorResult then return "Select: copy result" end
    if data.quickFilterDef then return "Select: filter results" end
    if data.titleID then return "Click: apply title" end
    if data.mountID then
        if Icons:IsMountSummonable(data) then
            return "Click: summon | Alt: journal | Ctrl: preview | Shift: drag"
        end
        return "Click: journal | Ctrl: preview"
    end
    if data.petID or data.speciesID then return "Click: summon | Alt: journal | Shift: drag" end
    if data.toyItemID then
        return data.isToyboxOnly and "Click: toy box" or "Click: use | Alt: toy box | Shift: drag"
    end
    if data.heirloomItemID then return "Click: add to bags" end
    if data.outfitID then return "Click: wear | Alt: transmog | Shift: drag" end
    if data.gearSetID then return "Click: equip gear set" end
    if data.transmogSetID then return "Click: wardrobe | Ctrl: try on" end
    if data.spellID and data.category == "Ability" then
        return Icons:IsSpellbookOnlyAbility(data) and "Click: spellbook" or "Click: cast | Alt: spellbook | Shift: drag"
    end
    if data.macroIndex then return "Click: run | Alt: edit | Shift: drag" end
    if data.itemID and data.category == "Bag" then
        local actionKind = Handlers:GetBagItemActionKind(data)
        if actionKind == "equip" then
            return "Click: equip | Alt: bags | Ctrl: try on | Shift: drag"
        elseif actionKind == "open" then
            return "Click: open | Alt: bags | Shift: drag"
        elseif actionKind == "use" then
            return "Click: use | Alt: bags | Shift: drag"
        end
        return "Click: bags | Shift: drag"
    end
    if data.mapSearchResult then
        if data.isZone then return "Click: open map" end
        return "Click: pin on map"
    end
    if data.encounterID and data.category == "Boss" then
        return "Click: encounter journal"
    end
    if (data.settingType == "checkbox" or data.settingType == "checkboxSlider")
       and data.settingVariable then
        return "Click: toggle | Alt: settings"
    end
    if data.settingVariable or data.bindingAction then
        return "Click: settings"
    end
    return nil
end

-- Tracks the row currently displaying an action hint so we can restore
-- its normal subtext when selection moves away.
local actionHintRow

function Handlers:ClearActionHint()
    if actionHintRow and actionHintRow.pathSubtext then
        actionHintRow.pathSubtext:SetText(Text:GetFlatSubtext(actionHintRow.data))
        actionHintRow.pathSubtext:SetTextColor(0.55, 0.55, 0.55, 1.0)
    end
    actionHintRow = nil
end

-- Apply the action hint to a row's pathSubtext if one exists for its
-- data. Restores any previously hinted row first so only one row carries
-- a hint at a time.
function Handlers:ApplyActionHint(row)
    if not row or not row.pathSubtext or not row.pathSubtext:IsShown() then return end
    local hint = Handlers:GetActionHint(row.data)
    if not hint then return end
    if actionHintRow == row then return end
    Handlers:ClearActionHint()
    row.pathSubtext:SetText(hint)
    row.pathSubtext:SetTextColor(0.85, 0.78, 0.55, 1.0)
    actionHintRow = row
end

function Handlers:IsActionHintRow(row)
    return actionHintRow == row
end
