-- EasyFind_Onboarding companion file; see TutorialWizard.lua for the load
-- contract.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Onboarding = ns.Onboarding
local L = ns.L
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local mmax, mmin, mceil = math.max, math.min, math.ceil

local GOLD     = ns.GOLD_COLOR
local TEXT_BODY = ns.TEXT_BODY
local TEXT_DIM  = ns.TEXT_DIM
local PANEL_BG_ALPHA = 0.97

-- Width follows the widest content line between these bounds; no
-- hardcoded panel width that drifts from what the body actually holds.
local WN_MIN_W = 340
local WN_MAX_W = 470
local WN_PAD_X = 22
local WN_PAD_TOP = 22
local WN_PAD_BOTTOM = 18
local WN_TITLE_GAP = 6
local WN_BODY_GAP = 18
local WN_BTN_GAP = 14
local WN_BTN_MIN_W = 130
local WN_BTN_H = 22
local WN_BTN_TEXT_PAD = 24

-- The body names an item to make the drag-to-link example concrete. Read
-- the name from the API rather than writing it into each locale: this is
-- the one string in the popup the client can translate for us. 6948 is the
-- Hearthstone, which every character carries.
local HEARTHSTONE_ITEM_ID = 6948
local function BodyText()
    local name = GetItemInfo and GetItemInfo(HEARTHSTONE_ITEM_ID)
    return Utils.sformat(L["WHATSNEW_BODY"], name or "Hearthstone")
end

local frame

function Onboarding:ShowWhatsNew(version)
    if frame and frame:IsShown() then return end

    if not frame then
        local f = CreateFrame("Frame", "EasyFindWhatsNew", UIParent)
        f:SetSize(WN_MAX_W, 280)
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
        body:SetText(BodyText())
        f._body = body

        -- Permanent footer: clickable "See full changelog" opens the copy
        -- box with the GitHub changelog URL (addons cannot open browsers).
        local changelogLink = CreateFrame("Button", nil, f)
        local changelogText = changelogLink:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        changelogText:SetPoint("CENTER")
        changelogText:SetText(L["WHATSNEW_CHANGELOG_LINK"])
        changelogText:SetTextColor(Utils.RGB(GOLD, 1))
        changelogLink:SetSize(changelogText:GetStringWidth() + 8, 16)
        changelogLink:SetPoint("TOP", body, "BOTTOM", 0, -10)
        changelogLink:SetScript("OnEnter", function() changelogText:SetTextColor(1, 1, 1) end)
        changelogLink:SetScript("OnLeave", function() changelogText:SetTextColor(Utils.RGB(GOLD, 1)) end)
        changelogLink:SetScript("OnClick", function()
            ns.ShowCopyBox(ns.GITHUB_CHANGELOG_URL, L["WHATSNEW_CHANGELOG_LINK"])
        end)
        f._changelogLink = changelogLink

        local okBtn = ns.CreateModernButton(f, L["WHATSNEW_GOT_IT"], WN_BTN_MIN_W, WN_BTN_H)
        okBtn:SetPoint("TOP", changelogLink, "BOTTOM", 0, -WN_BTN_GAP)
        okBtn:SetScript("OnClick", function() f:Hide() end)
        f._okBtn = okBtn

        okBtn:SetSize(mmax(WN_BTN_MIN_W,
            mceil(okBtn._label:GetStringWidth()) + WN_BTN_TEXT_PAD), WN_BTN_H)
    end

    local versionLabel = version or ns.version or "?"
    frame._verText:SetText("v" .. versionLabel)

    frame._body:SetText(BodyText())

    local contentW = Utils.MaxContentWidth({ frame._title, frame._verText, frame._body })
    frame:SetWidth(mmax(WN_MIN_W, mmin(WN_MAX_W, mceil(contentW) + WN_PAD_X * 2)))

    local titleH = frame._title:GetStringHeight()
    local verH = frame._verText:GetStringHeight()
    local bodyTopOffset = WN_PAD_TOP + titleH + WN_TITLE_GAP + verH + WN_BODY_GAP
    frame._body:ClearAllPoints()
    frame._body:SetPoint("TOPLEFT", frame, "TOPLEFT", WN_PAD_X, -bodyTopOffset)
    frame._body:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WN_PAD_X, -bodyTopOffset)

    local bodyH = frame._body:GetStringHeight()
    -- 10 = body->changelog gap, 16 = link height.
    local total = bodyTopOffset + bodyH + 10 + 16
        + WN_BTN_GAP + WN_BTN_H + WN_PAD_BOTTOM
    frame:SetHeight(total)
    frame:Show()
end
