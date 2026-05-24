local _, ns = ...

local Onboarding = ns.Onboarding

local CreateFrame = CreateFrame
local UIParent = UIParent

-- WHAT'S NEW POPUP
-- Shown once per version update for returning users.
function Onboarding:ShowWhatsNew(version)
    if _G["EasyFindWhatsNew"] then return end

    local f = CreateFrame("Frame", "EasyFindWhatsNew", UIParent, "BackdropTemplate")
    f:SetSize(470, 265)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cffFFD100EasyFind|r - New Features")

    local verText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verText:SetPoint("TOP", title, "BOTTOM", 0, -4)
    verText:SetText("|cff999999v" .. (version or "?") .. "|r")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -58)
    body:SetWidth(f:GetWidth() - 32)
    body:SetJustifyH("LEFT")
    body:SetSpacing(4)
    body:SetText(
        "|cffFFD100\226\128\162|r |cffffffffLoot Search|r\n" ..
        "        Search dungeon and raid loot by name, slot, stats, or source\n" ..
        "        Filter by class, spec, and difficulty\n" ..
        "        Click to navigate directly to the item in the Encounter Journal\n" ..
        "|cffFFD100\226\128\162|r |cffffffffTransmog Outfits|r\n" ..
        "        Saved outfits appear in search results, click to equip\n" ..
        "        Browse the transmog window without a vendor (search \"tmog\")\n" ..
        "\n|cff999999Enable Loot and Outfits in the filter dropdown (arrow button\n" ..
        "inside the search bar) to see these results.|r"
    )

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("TOP", body, "BOTTOM", 0, -12)
    footer:SetText("Full changelog on CurseForge and GitHub")

    local okBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    okBtn:SetSize(90, 24)
    okBtn:SetPoint("TOP", footer, "BOTTOM", 0, -8)
    okBtn:SetText("Got it")
    okBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    f:SetHeight(58 + body:GetStringHeight() + 12 + footer:GetStringHeight() + 8 + okBtn:GetHeight() + 16)
    f:Show()
end
