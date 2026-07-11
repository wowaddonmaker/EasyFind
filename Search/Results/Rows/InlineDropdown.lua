local _, ns = ...

local Rows = ns.ResultRows


local CreateFrame = CreateFrame
local UIParent = UIParent

-- Custom popup for inline setting dropdowns. Replaces MenuUtil.CreateContextMenu
-- because MenuUtil's option buttons can have a click target that's narrower than
-- the visible label for very long strings, which silently swallows selection.
-- This popup auto-sizes to the longest label so every row's clickable area
-- matches its visible text exactly.
local inlineDropdownPopup
local inlineDropdownRows = {}

local function GetInlineDropdownPopup()
    if inlineDropdownPopup then return inlineDropdownPopup end
    local p = CreateFrame("Frame", "EasyFindInlineDropdownPopup", UIParent, "BackdropTemplate")
    -- DIALOG matches the results stack's active strata so the popup
    -- renders ABOVE the rows. Other popups (filter dropdown sub-menus,
    -- spec/class flyouts) already use TOOLTIP which sits above this.
    p:SetFrameStrata("DIALOG")
    p:SetFrameLevel(200)
    p:Hide()
    p:EnableMouse(true)
    p:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    p:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    p:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if self.owner and self.owner:IsMouseOver() then return end
        self:Hide()
    end)
    p:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        EasyFind._inlineDropdownMenuOpen = true
    end)
    p:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        EasyFind._inlineDropdownMenuOpen = false
    end)
    inlineDropdownPopup = p
    return p
end

local function GetInlineDropdownRow(popup, index)
    local row = inlineDropdownRows[index]
    if row then return row end
    row = CreateFrame("Button", nil, popup)
    row:SetHeight(20)
    local radio = row:CreateTexture(nil, "ARTWORK")
    radio:SetSize(14, 14)
    radio:SetTexture(ns.RADIO_OFF_TEX)
    radio:SetPoint("LEFT", 6, 0)
    row.radio = radio
    local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lbl:SetPoint("LEFT", radio, "RIGHT", 6, 0)
    lbl:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetMaxLines(1)
    row.lbl = lbl
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.1)
    inlineDropdownRows[index] = row
    return row
end

local function ShowInlineSettingDropdown(owner, opts, getCurrent, onSelect)
    local popup = GetInlineDropdownPopup()
    popup.owner = owner
    for i = 1, #inlineDropdownRows do
        inlineDropdownRows[i]:Hide()
        inlineDropdownRows[i]:SetScript("OnClick", nil)
    end
    -- Measure longest label so the popup auto-sizes.
    local maxTextW = 0
    local probe = popup._probeFS
    if not probe then
        probe = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        probe:Hide()
        popup._probeFS = probe
    end
    for i = 1, #opts do
        local label = opts[i].label or tostring(opts[i].value)
        probe:SetText(label)
        local w = (probe.GetUnboundedStringWidth and probe:GetUnboundedStringWidth())
            or (probe.GetStringWidth and probe:GetStringWidth())
            or 0
        if w > maxTextW then maxTextW = w end
    end
    local PAD_LR = 6 + 14 + 6 + 6     -- left pad + radio + gap + right pad
    local PAD_TOP = 8
    local PAD_BOT = 8
    local ROW_H = 20
    local popupW = math.max(140, math.ceil(maxTextW) + PAD_LR + 12)
    local popupH = PAD_TOP + (#opts * ROW_H) + PAD_BOT
    popup:SetSize(popupW, popupH)
    popup:ClearAllPoints()
    popup:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
    local cur = getCurrent and getCurrent() or nil
    for i = 1, #opts do
        local opt = opts[i]
        local row = GetInlineDropdownRow(popup, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 6, -PAD_TOP - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", popup, "RIGHT", -6, 0)
        row.lbl:SetText(opt.label or tostring(opt.value))
        local checked = cur == opt.value or tostring(cur) == tostring(opt.value)
        row.radio:SetTexture(checked and ns.RADIO_ON_TEX or ns.RADIO_OFF_TEX)
        local optValue = opt.value
        row:SetScript("OnClick", function()
            if onSelect then onSelect(optValue) end
            EasyFind._popupGraceUntil = GetTime() + 0.2
            popup:Hide()
        end)
        row:Show()
    end
    popup:Show()
    popup:Raise()
end

function Rows.ToggleInlineSettingDropdown(owner, opts, getCurrent, onSelect)
    if inlineDropdownPopup and inlineDropdownPopup:IsShown()
       and inlineDropdownPopup.owner == owner then
        inlineDropdownPopup:Hide()
        return
    end
    ShowInlineSettingDropdown(owner, opts, getCurrent, onSelect)
end
