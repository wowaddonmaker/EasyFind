local _, ns = ...

local Onboarding = ns.Onboarding
local L = ns.L
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent

local GOLD     = ns.GOLD_COLOR
local TEXT_PRIM = ns.TEXT_PRIMARY
local TEXT_BODY = ns.TEXT_BODY
local TEXT_DIM  = ns.TEXT_DIM
local PANEL_BG_ALPHA = 0.97
local PANEL_FILL = {0.04, 0.04, 0.05, 1}
local BTN_FILL_NORMAL  = ns.BTN_FILL_NORMAL
local BTN_FILL_HOVER   = ns.BTN_FILL_HOVER

local WN_W = 470
local WN_PAD_X = 22
local WN_PAD_TOP = 22
local WN_PAD_BOTTOM = 18
local WN_TITLE_GAP = 6
local WN_BODY_GAP = 18
local WN_FOOTER_GAP = 14
local WN_BTN_GAP = 14
local WN_BTN_W = 110
local WN_BTN_H = 28

local frame

local function MakeStyledButton(parent, label)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(WN_BTN_W, WN_BTN_H)
    btn:RegisterForClicks("LeftButtonUp")

    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, WN_BTN_H)
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    ns.SetRoundedRectBorderFillColor(btn, BTN_FILL_NORMAL[1], BTN_FILL_NORMAL[2], BTN_FILL_NORMAL[3], 1)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText(label)
    fs:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    btn._label = fs

    btn:SetScript("OnEnter", function()
        ns.SetRoundedRectBorderFillColor(btn, BTN_FILL_HOVER[1], BTN_FILL_HOVER[2], BTN_FILL_HOVER[3], 1)
        fs:SetTextColor(1, 1, 1, 1)
    end)
    btn:SetScript("OnLeave", function()
        ns.SetRoundedRectBorderFillColor(btn, BTN_FILL_NORMAL[1], BTN_FILL_NORMAL[2], BTN_FILL_NORMAL[3], 1)
        fs:SetTextColor(Utils.RGB(TEXT_PRIM, 1))
    end)
    return btn
end

function Onboarding:ShowWhatsNew(version)
    if frame and frame:IsShown() then return end

    if not frame then
        local f = CreateFrame("Frame", "EasyFindWhatsNew", UIParent)
        f:SetSize(WN_W, 280)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(220)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        frame = f

        ns.CreateRoundedRectBorder(f)
        ns.SetRoundedRectBarHeight(f, 16)
        ns.SetRoundedRectBorderBgAlpha(f, PANEL_BG_ALPHA)
        ns.SetRoundedRectBorderEdgeShown(f, false)
        ns.SetRoundedRectBorderFillColor(f, PANEL_FILL[1], PANEL_FILL[2], PANEL_FILL[3], PANEL_FILL[4])

        local closeBtn = ns.CreateCloseX(f)
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", f, "TOP", 0, -WN_PAD_TOP)
        title:SetText(L["WHATSNEW_TITLE"])
        title:SetTextColor(Utils.RGB(GOLD, 1))
        f._title = title

        local verText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        verText:SetPoint("TOP", title, "BOTTOM", 0, -WN_TITLE_GAP)
        verText:SetTextColor(Utils.RGB(TEXT_DIM, 1))
        f._verText = verText

        local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        body:SetPoint("TOPLEFT", f, "TOPLEFT", WN_PAD_X, 0)
        body:SetPoint("TOPRIGHT", f, "TOPRIGHT", -WN_PAD_X, 0)
        body:SetJustifyH("LEFT")
        body:SetJustifyV("TOP")
        body:SetSpacing(4)
        body:SetTextColor(Utils.RGB(TEXT_BODY, 1))
        body:SetText(L["WHATSNEW_BODY"])
        f._body = body

        local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        footer:SetPoint("TOP", body, "BOTTOM", 0, -WN_FOOTER_GAP)
        footer:SetTextColor(Utils.RGB(TEXT_DIM, 1))
        footer:SetText(L["WHATSNEW_FULL_CHANGELOG"])
        f._footer = footer

        local okBtn = MakeStyledButton(f, L["WHATSNEW_GOT_IT"])
        okBtn:SetPoint("TOP", footer, "BOTTOM", 0, -WN_BTN_GAP)
        okBtn:SetScript("OnClick", function() f:Hide() end)
        f._okBtn = okBtn
    end

    local versionLabel = version or ns.version or "?"
    frame._verText:SetText("v" .. versionLabel)

    frame._body:SetText(L["WHATSNEW_BODY"])

    local titleH = frame._title:GetStringHeight()
    local verH = frame._verText:GetStringHeight()
    local bodyTopOffset = WN_PAD_TOP + titleH + WN_TITLE_GAP + verH + WN_BODY_GAP
    frame._body:ClearAllPoints()
    frame._body:SetPoint("TOPLEFT", frame, "TOPLEFT", WN_PAD_X, -bodyTopOffset)
    frame._body:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WN_PAD_X, -bodyTopOffset)

    local bodyH = frame._body:GetStringHeight()
    local footerH = frame._footer:GetStringHeight()
    local total = bodyTopOffset + bodyH + WN_FOOTER_GAP + footerH + WN_BTN_GAP + WN_BTN_H + WN_PAD_BOTTOM
    frame:SetHeight(total)
    frame:Show()
end

function Onboarding:HideWhatsNew()
    if frame then frame:Hide() end
end
