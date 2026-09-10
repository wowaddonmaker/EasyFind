local _, ns = ...

local Filters = ns.Filters
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local ipairs = Utils.ipairs
local type = Utils.type

-- A sub-filter's options flyout when those options are a few plain
-- toggles on EasyFind.db keys (Snippets, Clipboard History under
-- Extensions): built from the sub-filter's `checkboxOptions` list, each
-- { dbKey, label, tooltip, onChange } with label and tooltip either a
-- string or a function (labels that carry the live snippet trigger). A
-- { header = text } entry is a dim caption over the rows that follow; a
-- { separator = true } entry is a rule between groups.
-- Returns the popup and its sync function; the dropdown attaches it
-- beside the row the way it attaches the richer per-key popups.
function Filters:BuildCheckboxOptionsPopup(sub, StylePopup, CHECK_SIZE)
    local ROW_H = 22
    local PAD = 6
    local popup = CreateFrame("Frame", "EasyFind" .. sub.key .. "OptionsPopup", UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    StylePopup(popup)
    popup:EnableMouse(true)
    popup:Hide()

    local function Resolve(v)
        if type(v) == "function" then return v() end
        return v
    end

    -- Width fits the widest label (measured unconstrained, so a pooled
    -- row can never read back clipped), never a guess.
    local measure = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    measure:Hide()
    local widest = 0
    for _, def in ipairs(sub.checkboxOptions) do
        measure:SetText(Resolve(def.label or def.header) or "")
        widest = math.max(widest, measure:GetStringWidth() or 0)
    end
    local WIDTH = math.ceil(PAD * 2 + 4 + CHECK_SIZE + 4 + widest + 10)

    local rows = {}
    local y = -PAD
    local HEADER_H, SEP_H = 18, 9
    for _, def in ipairs(sub.checkboxOptions) do
        if def.separator then
            local line = popup:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(1, 1, 1, 0.12)
            line:SetHeight(1)
            line:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 4, y - 4)
            line:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -(PAD + 4), y - 4)
            y = y - SEP_H
        elseif def.header then
            local caption = popup:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            caption:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 4, y - 4)
            caption:SetText(Resolve(def.header) or "")
            y = y - HEADER_H
        else
        local row = CreateFrame("CheckButton", nil, popup)
        row:SetSize(WIDTH - PAD * 2, ROW_H)
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, y)
        Utils.SetCheckboxTextures(row, CHECK_SIZE)
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        row._label = text
        Utils.InstallMenuRowHighlight(row)
        row.def = def
        row:SetScript("OnClick", function(self)
            local value = self:GetChecked() and true or false
            EasyFind.db[def.dbKey] = value
            if def.onChange then def.onChange(value) end
        end)
        if def.tooltip then
            Utils.AttachDelayedTooltip(row, "ANCHOR_RIGHT", function()
                return Resolve(def.label), Resolve(def.tooltip)
            end)
        end
        rows[#rows + 1] = row
        y = y - ROW_H
        end
    end
    popup:SetSize(WIDTH, -y + PAD)

    local function sync()
        for i = 1, #rows do
            local def = rows[i].def
            rows[i]._label:SetText(Resolve(def.label) or "")
            rows[i]:SetChecked(EasyFind.db[def.dbKey] ~= false)
        end
    end
    return popup, sync
end
