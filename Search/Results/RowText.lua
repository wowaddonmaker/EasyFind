local _, ns = ...

local Text = ns.ResultText
local L = ns.L
local sformat = ns.Utils.sformat

local KEY_ABBREV = {
    SHIFT = "S", CTRL = "C", ALT = "A", META = "M",
    PAGEDOWN = "PgDn", PAGEUP = "PgUp",
    HOME = "Home", END = "End",
    DELETE = "Del", INSERT = "Ins",
    BACKSPACE = "BkSp", SPACE = "Spc",
    ESCAPE = "Esc", ENTER = "Ent",
    PRINTSCREEN = "PrtSc",
    MOUSEWHEELUP = "MWU", MOUSEWHEELDOWN = "MWD",
    BUTTON3 = "MB3", BUTTON4 = "MB4", BUTTON5 = "MB5",
}
function Text:AbbrevBinding(binding)
    if not binding or binding == "" then return _G["NOT_BOUND"] or "Not Bound" end
    local out = {}
    for part in binding:gmatch("[^%-]+") do
        local up = part:upper()
        local short = KEY_ABBREV[up]
        if not short then
            -- NUMPAD0-9 -> Num0, NUMPADDIVIDE -> Num/, etc.
            local n = up:match("^NUMPAD(%d)$")
            if n then short = "Num" .. n end
        end
        out[#out + 1] = short or part
    end
    return table.concat(out, "-")
end

-- Set a FontString's text and append "..." when the rendered string
-- exceeds the FontString's anchor-bounded width. Used for result-row
-- titles and any other single-line label that must clip cleanly
-- instead of overflowing into the next row's space (WoW doesn't
-- auto-add ellipses for anchor-clipped FontStrings).
local function applyClip(fs)
    local text = fs._unclippedText
    if not text or text == "" then
        fs:SetText("")
        return
    end
    fs:SetText(text)
    -- Use anchor-derived bounds (GetLeft / GetRight) instead of
    -- GetWidth(): GetWidth() on an L+R anchored FontString can return
    -- the natural string width when the text overflows.
    local left, right = fs:GetLeft(), fs:GetRight()
    local maxW
    if left and right and right > left then
        maxW = right - left
    else
        maxW = fs:GetWidth() or 0
    end
    if not maxW or maxW <= 0 then return end
    local getW = fs.GetUnboundedStringWidth
    local strW = getW and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
    if strW <= maxW then return end
    for cut = #text - 1, 1, -1 do
        local trimmed = text:sub(1, cut) .. "..."
        fs:SetText(trimmed)
        local w = getW and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
        if w <= maxW then return end
    end
end

function Text:SetClippedText(fs, text)
    if not fs then return end
    fs._unclippedText = text or ""
    applyClip(fs)
    -- Re-clip on parent-frame size changes so a later layout pass (e.g.
    -- when the row's right-side widget shows / hides / re-anchors after
    -- the row's title was already set) doesn't leave the title clipped
    -- against the previous bound. Idempotent: re-clipping uses the
    -- stored original text, never the already-trimmed string.
    if not fs._sizeHookInstalled then
        fs._sizeHookInstalled = true
        local parent = fs:GetParent()
        if parent and parent.HookScript then
            parent:HookScript("OnSizeChanged", function()
                if fs._unclippedText then applyClip(fs) end
            end)
        end
    end
end


function Text:GetFlatSubtext(data)
    if not data then return "" end
    if data.calculatorResult then return L["SUBTEXT_EXPRESSION"] end
    if data.calculatorLauncher or data.iconSearchLauncher then return L["SUBTEXT_APP"] end
    if data.searchCommandDesc then return data.searchCommandDesc end
    if data.quickFilterAliasText then return data.quickFilterAliasText end
    if data.quickFilterDef then return data.quickFilterDef.label or L["QUICK_FILTER"] end
    if data.path and #data.path > 0 then
        return data.path[#data.path]
    end
    if data.mapSearchResult then
        local cat = data.category
        local typeLabel
        if cat == "dungeon" then typeLabel = _G["LFG_TYPE_DUNGEON"] or "Dungeon"
        elseif cat == "raid" then typeLabel = _G["RAID"] or "Raid"
        elseif cat == "delve" then typeLabel = _G["DELVE_LABEL"] or "Delve"
        end
        -- Use only the immediate parent zone, not the full continent path.
        -- pathPrefix can be "Continent > Region > Zone"; take the last segment.
        local zone = data.zoneName or data.pathPrefix
        if zone then
            local lastSep = zone:find(">[^>]*$")
            if lastSep then
                zone = zone:sub(lastSep + 1):match("^%s*(.-)%s*$")
            end
        end
        if typeLabel and zone and zone ~= "" then
            return typeLabel .. ": " .. zone
        elseif typeLabel then
            return typeLabel
        end
        return zone or _G["WORLD_MAP"] or "Map"
    end
    if data.mountID then return _G["MOUNT"] or "Mount" end
    if data.toyItemID then return _G["TOY"] or "Toy" end
    if data.petID then return _G["PET"] or "Pet" end
    if data.outfitID then return _G["TRANSMOG_OUTFIT_NAME_DEFAULT"] or "Outfit" end
    if data.heirloomItemID then return _G["ITEM_QUALITY7_DESC"] or "Heirloom" end
    if data.transmogSetID then return L["SUBTEXT_APPEARANCE_SET"] end
    if data.appearanceItemID then return L["SUBTEXT_APPEARANCE_ITEM"] end
    if data.itemID and data.category == "Loot" then
        return data.lootInstanceName or _G["LOOT"] or "Loot"
    end
    -- Naming the holders is the whole point of a stored-item result: the item
    -- is not reachable from here, so what the row answers is who has it.
    if data.storedSubtext then return data.storedSubtext end
    if data.category == "Ability" and data.treeName and data.treeName ~= "" then
        return sformat(L["SUBTEXT_TREE_ABILITY"], data.treeName)
    end
    -- Recipe rows show their PROFESSION name (e.g. "Inscription"), which
    -- disambiguates same-named recipes across professions. Parent profession
    -- rows have no professionRecipeID and keep the generic category, since
    -- their main text is already the profession name.
    if data.professionRecipeID then
        return data.professionName or data.category or ""
    end
    return data.category or ""
end
