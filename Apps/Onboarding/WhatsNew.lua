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

-- The body is a stack of feature blocks parsed from the localized text:
-- a feature starts at a gold bullet line (its title) and runs to the next
-- one. A title line may carry a {showme:<id>} token; when a Show me
-- script with that id is registered (ShowMeScripts.lua) the title gets a
-- "Show me" button beside it, and the popup steps aside while it plays.
local BULLET = "|cffFFD100\226\128\162|r"
local SHOWME_TOKEN = "{showme:([%w_]+)}"
local WN_BLOCK_GAP = 10
local WN_TITLE_BODY_GAP = 4

local function ParseFeatures(text)
    local features, current = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line:sub(1, #BULLET) == BULLET then
            local showme = line:match(SHOWME_TOKEN)
            line = line:gsub("%s*{showme:[%w_]+}", "")
            current = { title = line, lines = {}, showme = showme }
            features[#features + 1] = current
        else
            if not current then
                current = { lines = {} }
                features[#features + 1] = current
            end
            current.lines[#current.lines + 1] = line
        end
    end
    return features
end

local function EnsureBlock(blocks, i)
    local b = blocks.pool[i]
    if b then return b end
    b = {}
    b.title = blocks:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.title:SetJustifyH("LEFT")
    b.title:SetTextColor(Utils.RGB(TEXT_BODY, 1))
    b.body = blocks:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.body:SetJustifyH("LEFT")
    b.body:SetJustifyV("TOP")
    b.body:SetSpacing(4)
    b.body:SetTextColor(Utils.RGB(TEXT_BODY, 1))
    b.btn = ns.CreateModernButton(blocks, L["WHATSNEW_SHOW_ME"], 60, 18)
    b.btn:SetSize(mceil(b.btn._label:GetStringWidth()) + 16, 18)
    b.btn:SetScript("OnClick", function(self)
        local id = self._showme
        local f = frame
        if not (id and ns.ShowMe and f) then return end
        -- The show needs the screen: the popup steps aside and comes
        -- back when the show ends, for any reason.
        -- A show still running (its end would bring the popup back mid-
        -- show) ends first.
        if ns.ShowMe:IsPlaying() then ns.ShowMe:Stop() end
        f._reshow = true
        f:Hide()
        ns.ShowMe:Play(id, function()
            if f._reshow then
                f._reshow = nil
                f:Show()
            end
        end)
    end)
    blocks.pool[i] = b
    return b
end

-- Lays the feature blocks out for the container's current width and
-- returns the stack's height.
local function RenderFeatures(blocks, features)
    local y = 0
    for i, feat in ipairs(features) do
        local b = EnsureBlock(blocks, i)
        local hasTitle = feat.title ~= nil
        b.title:ClearAllPoints()
        b.title:SetText(feat.title or "")
        b.title:SetShown(hasTitle)
        local offer = hasTitle and feat.showme and ns.ShowMe and ns.ShowMe:Has(feat.showme)
        b.btn._showme = offer and feat.showme or nil
        b.btn:SetShown(offer and true or false)
        if hasTitle then
            b.title:SetPoint("TOPLEFT", blocks, "TOPLEFT", 0, -y)
            b.btn:ClearAllPoints()
            b.btn:SetPoint("LEFT", b.title, "RIGHT", 10, 0)
            y = y + mceil(b.title:GetStringHeight()) + WN_TITLE_BODY_GAP
        end
        b.body:ClearAllPoints()
        b.body:SetPoint("TOPLEFT", blocks, "TOPLEFT", 0, -y)
        b.body:SetPoint("RIGHT", blocks, "RIGHT", 0, 0)
        b.body:SetText(table.concat(feat.lines, "\n"))
        b.body:SetShown(#feat.lines > 0)
        if #feat.lines > 0 then y = y + mceil(b.body:GetStringHeight()) end
        y = y + WN_BLOCK_GAP
    end
    for i = #features + 1, #blocks.pool do
        local b = blocks.pool[i]
        b.title:Hide()
        b.body:Hide()
        b.btn:Hide()
    end
    y = mmax(1, y - WN_BLOCK_GAP)
    blocks:SetHeight(y)
    return y
end

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

        local blocks = CreateFrame("Frame", nil, f)
        blocks:SetPoint("TOPLEFT", f, "TOPLEFT", WN_PAD_X, 0)
        blocks:SetPoint("TOPRIGHT", f, "TOPRIGHT", -WN_PAD_X, 0)
        blocks:SetHeight(1)
        blocks.pool = {}
        f._blocks = blocks

        -- Permanent footer: "See full changelog" is a copy target for the
        -- GitHub changelog URL (addons cannot open browsers, and only a
        -- hardware Ctrl+C reaches the clipboard): hovering shows the chord
        -- hint, Ctrl over it arms the shared row copy, a click arms it too.
        local changelogLink = CreateFrame("Button", nil, f)
        local changelogText = changelogLink:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        changelogText:SetPoint("CENTER")
        changelogText:SetText(L["WHATSNEW_CHANGELOG_LINK"])
        changelogText:SetTextColor(Utils.RGB(GOLD, 1))
        changelogLink:SetSize(changelogText:GetStringWidth() + 8, 16)
        changelogLink:SetPoint("TOP", blocks, "BOTTOM", 0, -10)
        local copyHint = changelogLink:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        copyHint:SetPoint("LEFT", changelogText, "RIGHT", 6, 0)
        copyHint:Hide()
        changelogLink._efCopyText = ns.GITHUB_CHANGELOG_URL
        changelogLink._efCopyHint = copyHint
        changelogLink:SetScript("OnEnter", function(self)
            changelogText:SetTextColor(1, 1, 1)
            copyHint:SetText("Ctrl+C")
            copyHint:SetTextColor(Utils.RGB(TEXT_DIM, 1))
            copyHint:Show()
            if ns.RowCopy then ns.RowCopy:OnRowHover(self) end
        end)
        changelogLink:SetScript("OnLeave", function()
            changelogText:SetTextColor(Utils.RGB(GOLD, 1))
            copyHint:Hide()
            if ns.RowCopy then ns.RowCopy:OnRowHover(nil) end
        end)
        changelogLink:SetScript("OnClick", function(self)
            if ns.RowCopy then ns.RowCopy:ArmFor(self) end
        end)
        if ns.RowCopy and ns.RowCopy.RegisterHoverScanner then
            ns.RowCopy:RegisterHoverScanner(function()
                if changelogLink:IsVisible() and changelogLink:IsMouseOver() then
                    return changelogLink
                end
                return nil
            end)
        end
        f:HookScript("OnHide", function()
            if ns.RowCopy then ns.RowCopy:OnRowHover(nil) end
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

    local features = ParseFeatures(BodyText())
    local blocks = frame._blocks
    RenderFeatures(blocks, features)
    local probe = { frame._title, frame._verText }
    for i = 1, #features do
        probe[#probe + 1] = blocks.pool[i].title
        probe[#probe + 1] = blocks.pool[i].body
    end
    local contentW = Utils.MaxContentWidth(probe)
    frame:SetWidth(mmax(WN_MIN_W, mmin(WN_MAX_W, mceil(contentW) + WN_PAD_X * 2)))

    local titleH = frame._title:GetStringHeight()
    local verH = frame._verText:GetStringHeight()
    local bodyTopOffset = WN_PAD_TOP + titleH + WN_TITLE_GAP + verH + WN_BODY_GAP
    blocks:ClearAllPoints()
    blocks:SetPoint("TOPLEFT", frame, "TOPLEFT", WN_PAD_X, -bodyTopOffset)
    blocks:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WN_PAD_X, -bodyTopOffset)
    local bodyH = RenderFeatures(blocks, features)
    -- 10 = body->changelog gap, 16 = link height.
    local total = bodyTopOffset + bodyH + 10 + 16
        + WN_BTN_GAP + WN_BTN_H + WN_PAD_BOTTOM
    frame:SetHeight(total)
    frame:Show()
end
