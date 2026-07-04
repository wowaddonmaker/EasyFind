local _, ns = ...

local Onboarding = ns.Onboarding
local L = ns.L
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local mmax, mceil = math.max, math.ceil

local GOLD     = ns.GOLD_COLOR
local TEXT_BODY = ns.TEXT_BODY
local TEXT_DIM  = ns.TEXT_DIM
local PANEL_BG_ALPHA = 0.97

-- CurseForge only shows changelogs per-file (Files tab -> version ->
-- Changelog), so link the rendered CHANGELOG.md instead: every release,
-- one page, no app.
local CHANGELOG_URL = "https://github.com/wowaddonmaker/EasyFind/blob/main/CHANGELOG.md"

local WN_W = 470
local WN_PAD_X = 22
local WN_PAD_TOP = 22
local WN_PAD_BOTTOM = 18
local WN_TITLE_GAP = 6
local WN_BODY_GAP = 18
local WN_BTN_GAP = 14
local WN_BTN_MIN_W = 130
local WN_BTN_H = 22
local WN_BTN_TEXT_PAD = 24

local frame

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

        ns.StyleWizardPanel(f, PANEL_BG_ALPHA)

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

        -- Changelog left, dismiss right (the themed-dialog button order).
        -- Anchored to the body fontstring so they follow the relayout below.
        local changelogBtn = ns.CreateModernButton(f, L["WHATSNEW_CHANGELOG_BTN"], WN_BTN_MIN_W, WN_BTN_H)
        changelogBtn:SetPoint("TOPRIGHT", body, "BOTTOM", -(WN_BTN_GAP / 2), -WN_BTN_GAP)
        changelogBtn:SetScript("OnClick", function()
            ns.ShowCopyBox(CHANGELOG_URL, L["WHATSNEW_COPY_HINT"])
        end)
        f._changelogBtn = changelogBtn

        local okBtn = ns.CreateModernButton(f, L["WHATSNEW_GOT_IT"], WN_BTN_MIN_W, WN_BTN_H)
        okBtn:SetPoint("TOPLEFT", body, "BOTTOM", WN_BTN_GAP / 2, -WN_BTN_GAP)
        okBtn:SetScript("OnClick", function() f:Hide() end)
        f._okBtn = okBtn

        local btnW = mmax(WN_BTN_MIN_W,
            mceil(changelogBtn._label:GetStringWidth()) + WN_BTN_TEXT_PAD,
            mceil(okBtn._label:GetStringWidth()) + WN_BTN_TEXT_PAD)
        changelogBtn:SetSize(btnW, WN_BTN_H)
        okBtn:SetSize(btnW, WN_BTN_H)
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
    local total = bodyTopOffset + bodyH + WN_BTN_GAP + WN_BTN_H + WN_PAD_BOTTOM
    frame:SetHeight(total)
    frame:Show()
end
