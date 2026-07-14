local _, ns = ...

local Handlers = ns.ResultHandlers
local Shortcuts = ns.ResultShortcuts
local Icons = ns.ResultIcons
local Text = ns.ResultText
local L = ns.L

local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local select = select

function Handlers:IsSourceModifierHeld()
    return IsAltKeyDown and IsAltKeyDown() and not Shortcuts._resultShortcutActivation
end

-- Ctrl counterpart (dress-up / preview gates). Same activation flag so a keybind
-- or result-shortcut that physically holds Ctrl as part of the bind isn't read
-- as a deliberate Ctrl+click.
function Handlers:IsSourceCtrlHeld()
    return IsControlKeyDown and IsControlKeyDown() and not Shortcuts._resultShortcutActivation
end

-- Hint tokens. Each comes from the Blizzard global that already shows the word
-- (free translation) where one exists; the rest are L[] keys for phrases the
-- game has no string for. Title-cased to match the default UI vocabulary.
local V = {
    select      = _G["LFG_LIST_SELECT"] or "Select",
    summon      = _G["SUMMON"] or "Summon",
    journal     = _G["PROFESSIONS_JOURNAL_TAB_NAME"] or "Journal",
    preview     = _G["PREVIEW"] or "Preview",
    drag        = _G["DRAG_MODEL"] or "Drag",
    use         = _G["USE"] or "Use",
    equip       = _G["EQUIPSET_EQUIP"] or "Equip",
    spellbook   = _G["SPELLBOOK"] or "Spellbook",
    settings    = _G["SETTINGS"] or "Settings",
    edit        = _G["EDIT"] or "Edit",
    bags        = _G["HUD_EDIT_MODE_BAGS_LABEL"] or "Bags",
    toybox      = _G["TOY_BOX"] or "Toy Box",
    appearances = _G["WARDROBE"] or "Appearances",
    dressroom   = _G["DRESSUP_FRAME"] or "Dressing Room",
    encounter   = _G["ENCOUNTER_JOURNAL"] or "Encounter Journal",
    click        = L["HINT_CLICK"],
    wear         = L["HINT_WEAR"],
    cast         = L["HINT_CAST"],
    open         = L["HINT_OPEN"],
    run          = L["HINT_RUN"],
    toggle       = L["HINT_TOGGLE"],
    copyResult   = L["HINT_COPY_RESULT"],
    filterResults = L["HINT_FILTER_RESULTS"],
    enterMode    = L["HINT_ENTER_MODE"],
    applyTitle   = L["HINT_APPLY_TITLE"],
    addToBags    = L["HINT_ADD_TO_BAGS"],
    heirloomsTab = L["HINT_HEIRLOOMS_TAB"],
    openTransmog = L["HINT_OPEN_TRANSMOG"],
    equipGearSet = L["HINT_EQUIP_GEAR_SET"],
    openMap      = L["HINT_OPEN_MAP"],
    pinOnMap     = L["HINT_PIN_ON_MAP"],
}

-- Build "Lead: target | Alt: target | ...". The lead verb localizes; modifier
-- keys (Alt/Ctrl/Shift) are physical keys and stay literal.
local function Hint(lead, clickTarget, ...)
    local s = lead .. ": " .. clickTarget
    for i = 1, select("#", ...), 2 do
        local mod, target = select(i, ...)
        s = s .. " | " .. mod .. ": " .. target
    end
    return s
end

-- Precomputed once at load (these never change). Conditional rows pick among
-- the relevant variants in GetActionHint.
local HINTS = {
    copyResult       = Hint(V.select, V.copyResult),
    quickKeybind     = Hint(V.click, V.enterMode, "Alt", V.settings),
    filterResults    = Hint(V.select, V.filterResults),
    applyTitle       = Hint(V.click, V.applyTitle),
    mountSummon      = Hint(V.click, V.summon, "Alt", V.journal, "Ctrl", V.preview, "Shift", V.drag),
    mountStatic      = Hint(V.click, V.journal, "Ctrl", V.preview),
    pet              = Hint(V.click, V.summon, "Alt", V.journal, "Shift", V.drag),
    toyBoxOnly       = Hint(V.click, V.toybox),
    toy              = Hint(V.click, V.use, "Alt", V.toybox, "Shift", V.drag),
    heirloom         = Hint(V.click, V.addToBags, "Alt", V.heirloomsTab),
    outfit           = Hint(V.click, V.wear, "Alt", V.openTransmog, "Shift", V.drag),
    gearSet          = Hint(V.click, V.equipGearSet),
    transmogSet      = Hint(V.click, V.appearances, "Ctrl", V.dressroom),
    spellbookOnly    = Hint(V.click, V.spellbook),
    ability          = Hint(V.click, V.cast, "Alt", V.spellbook, "Shift", V.drag),
    macro            = Hint(V.click, V.run, "Alt", V.edit, "Shift", V.drag),
    bagEquip         = Hint(V.click, V.equip, "Alt", V.bags, "Ctrl", V.dressroom, "Shift", V.drag),
    bagOpen          = Hint(V.click, V.open, "Alt", V.bags, "Shift", V.drag),
    bagUse           = Hint(V.click, V.use, "Alt", V.bags, "Shift", V.drag),
    bagDefault       = Hint(V.click, V.bags, "Shift", V.drag),
    openMap          = Hint(V.click, V.openMap),
    pinOnMap         = Hint(V.click, V.pinOnMap),
    encounter        = Hint(V.click, V.encounter),
    toggle           = Hint(V.click, V.toggle, "Alt", V.settings),
    toggleOnly       = Hint(V.click, V.toggle),
    settings         = Hint(V.click, V.settings),
}

-- Hint shown only on the currently-selected row, replacing the normal
-- subtext so the user knows what Enter / left-click will do without
-- cluttering every other row. Returns nil for entries whose action
-- isn't worth labelling (Search navigation, settings: the row name itself
-- already tells you what happens).
function Handlers:GetActionHint(data)
    if not data then return nil end
    if data.calculatorResult then return HINTS.copyResult end
    if data.quickKeybindActivate then return HINTS.quickKeybind end
    if data.quickFilterDef then return HINTS.filterResults end
    if data.titleID then return HINTS.applyTitle end
    if data.mountID then
        return Icons:IsMountSummonable(data) and HINTS.mountSummon or HINTS.mountStatic
    end
    if data.petID or data.speciesID then return HINTS.pet end
    if data.toyItemID then
        return data.isToyboxOnly and HINTS.toyBoxOnly or HINTS.toy
    end
    if data.heirloomItemID then return HINTS.heirloom end
    if data.outfitID then return HINTS.outfit end
    if data.gearSetID then return HINTS.gearSet end
    if data.transmogSetID then return HINTS.transmogSet end
    if data.spellID and data.category == "Ability" then
        return Icons:IsSpellbookOnlyAbility(data) and HINTS.spellbookOnly or HINTS.ability
    end
    if data.macroIndex then return HINTS.macro end
    if data.itemID and data.category == "Bag" then
        local actionKind = Handlers:GetBagItemActionKind(data)
        if actionKind == "equip" then return HINTS.bagEquip
        elseif actionKind == "open" then return HINTS.bagOpen
        elseif actionKind == "use" then return HINTS.bagUse
        end
        return HINTS.bagDefault
    end
    if data.mapSearchResult then
        if data.isZone then return HINTS.openMap end
        return HINTS.pinOnMap
    end
    if data.encounterID and data.category == "Boss" then
        return HINTS.encounter
    end
    if (data.settingType == "checkbox" or data.settingType == "checkboxSlider")
       and data.settingVariable then
        return HINTS.toggle
    end
    if data.settingType == "keybind" and data.bindingAction
       and ns.BlizzOptionsSearch
       and ns.BlizzOptionsSearch:IsPerformableBinding(data.bindingAction) then
        return data.customToggle and HINTS.toggleOnly or HINTS.toggle
    end
    if data.settingVariable or data.bindingAction then
        return HINTS.settings
    end
    return nil
end

-- Tracks the row currently displaying an action hint so we can restore
-- its normal subtext when selection moves away.
local actionHintRow

function Handlers:ClearActionHint()
    -- Pinned while its context menu is open (mirrors the row highlight).
    if actionHintRow and actionHintRow._efContextMenuHeld then return end
    if actionHintRow and actionHintRow.pathSubtext then
        actionHintRow.pathSubtext:SetText(Text:GetFlatSubtext(actionHintRow.data))
        -- Restore the THEMED subtext color; a hardcoded gray here left
        -- once-hinted rows desynced from every non-default theme.
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if theme then
            actionHintRow.pathSubtext:SetTextColor(unpack(theme.pathColor))
        end
    end
    actionHintRow = nil
end

-- Apply the action hint to a row's pathSubtext if one exists for its
-- data. Restores any previously hinted row first so only one row carries
-- a hint at a time.
function Handlers:ApplyActionHint(row)
    -- Don't move the hint off a row whose context menu is open.
    if actionHintRow and actionHintRow._efContextMenuHeld and row ~= actionHintRow then return end
    if not row or not row.pathSubtext or not row.pathSubtext:IsShown() then return end
    local hint = Handlers:GetActionHint(row.data)
    if not hint then return end
    if actionHintRow == row then return end
    Handlers:ClearActionHint()
    row.pathSubtext:SetText(hint)
    -- Warm gold on dark themes; light themes use their hover text color
    -- (the gold is unreadable on light fills).
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme then
        row.pathSubtext:SetTextColor(unpack(theme.pathColorHover))
    else
        row.pathSubtext:SetTextColor(0.85, 0.78, 0.55, 1.0)
    end
    actionHintRow = row
end

function Handlers:IsActionHintRow(row)
    return actionHintRow == row
end
