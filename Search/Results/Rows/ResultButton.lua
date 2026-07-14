local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Utils = ns.Utils

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame = CreateFrame

local REP_BAR_WIDTH = 100

local INDENT_COLORS = {
    {0.40, 0.85, 1.00, 0.80},
    {1.00, 0.55, 0.10, 0.80},
    {0.55, 1.00, 0.35, 0.80},
    {1.00, 0.40, 0.70, 0.80},
    {0.70, 0.55, 1.00, 0.80},
    {1.00, 0.90, 0.20, 0.80},
}
local INDENT_PX  = 20
local LINE_X_OFF = 10
local LINE_W     = 2
local MAX_DEPTH  = 0

local function ResultsFrame()
    return Search:GetResultsFrame()
end

function Rows:CreateResultButton(index)
    local scrollChild = ResultsFrame().scrollChild
    local resultRow = CreateFrame("Button", "EasyFindResultButton"..index, scrollChild, "SecureActionButtonTemplate")
    resultRow:SetSize(360, 22)
    resultRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, -8 - (index - 1) * 22)

    -- Single highlight texture for both mouse hover and keyboard
    -- selection via LockHighlight, so the two paths look identical.
    -- Uses Blizzard's tapered quest-log row glow atlas.
    resultRow:SetHighlightAtlas("QuestLog-quest-glow-yellow")
    local hlTex = resultRow:GetHighlightTexture()
    if hlTex then hlTex:SetBlendMode("ADD") end
    -- The hover wash lives in InstallTooltips' OnEnter/OnLeave:
    -- those are set via SetScript AFTER creation, which would wipe any
    -- hooks added here.

    -- Thin horizontal separator line at the bottom of each row
    local separator = resultRow:CreateTexture(nil, "ARTWORK", nil, 0)
    separator:SetColorTexture(0.5, 0.45, 0.3, 0.3)
    separator:SetHeight(1)
    separator:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 4, 0)
    separator:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", -4, 0)
    separator:Hide()
    resultRow.separator = separator

    resultRow.treeVert   = {}
    resultRow.treeBranch = {}
    resultRow.treeElbow  = {}

    for d = 1, MAX_DEPTH do
        local c = INDENT_COLORS[d]
        local xCenter = (d - 1) * INDENT_PX + LINE_X_OFF

        local vert = resultRow:CreateTexture(nil, "BACKGROUND")
        vert:SetColorTexture(Utils.RGB(c, 1))
        vert:SetWidth(LINE_W)
        vert:SetPoint("TOP",    resultRow, "TOPLEFT",    xCenter, 3)
        vert:SetPoint("BOTTOM", resultRow, "BOTTOMLEFT", xCenter, -1)
        vert:Hide()
        resultRow.treeVert[d] = vert

        local elbow = resultRow:CreateTexture(nil, "BACKGROUND")
        elbow:SetColorTexture(Utils.RGB(c, 1))
        elbow:SetWidth(LINE_W)
        elbow:SetPoint("TOP", resultRow, "TOPLEFT", xCenter, 3)
        elbow:SetHeight(13)
        elbow:Hide()
        resultRow.treeElbow[d] = elbow

        local branch = resultRow:CreateTexture(nil, "BACKGROUND")
        branch:SetColorTexture(Utils.RGB(c, 1))
        branch:SetHeight(LINE_W)
        branch:SetPoint("LEFT",  resultRow, "TOPLEFT", xCenter - 1, -11)
        branch:SetPoint("RIGHT", resultRow, "TOPLEFT", xCenter + INDENT_PX - LINE_X_OFF, -11)
        branch:Hide()
        resultRow.treeBranch[d] = branch
    end

    local icon = resultRow:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 0, 0)
    resultRow.icon = icon

    -- Cooldown sweep overlay for toy icons
    local iconCooldown = CreateFrame("Cooldown", nil, resultRow, "CooldownFrameTemplate")
    iconCooldown:SetDrawEdge(true)
    iconCooldown:SetHideCountdownNumbers(true)
    iconCooldown:Hide()
    resultRow.iconCooldown = iconCooldown

    -- Pin badge: the shared bronze-diamond glyph (Utils.CreatePinGlyph).
    -- Blizzard's Waypoint chat gem is a tiny inline texture that blurs at 150%.
    local pinIcon = Utils.CreatePinGlyph(resultRow, 11)
    pinIcon:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", -4, -1)
    pinIcon:Hide()
    resultRow.pinIcon = pinIcon

    -- Pin header toggle icon (expand/collapse, right-aligned on the button itself)
    local pinToggle = resultRow:CreateTexture(nil, "ARTWORK")
    pinToggle:SetSize(14, 14)
    pinToggle:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    pinToggle:SetAtlas("QuestLog-icon-shrink")
    pinToggle:Hide()
    resultRow.pinToggle = pinToggle

    -- Pin header underline (thin golden line below the header text)
    local pinHeaderLine = resultRow:CreateTexture(nil, "ARTWORK")
    pinHeaderLine:SetHeight(1)
    pinHeaderLine:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    pinHeaderLine:SetPoint("BOTTOMLEFT", resultRow, "BOTTOMLEFT", 0, 0)
    pinHeaderLine:SetPoint("BOTTOMRIGHT", resultRow, "BOTTOMRIGHT", 0, 0)
    pinHeaderLine:Hide()
    resultRow.pinHeaderLine = pinHeaderLine

    -- Section-label visuals: centered fontstring flanked by two faint
    -- gold rules (matches MapTab's "Pinned" / "This Zone" / etc. style).
    -- Used for category headers (Mounts/Toys/...) instead of the
    -- chunkier QuestLog-tab parent header so categories take less
    -- vertical space and don't waste a parent indent.
    local sectionLabelLeft = resultRow:CreateTexture(nil, "ARTWORK")
    sectionLabelLeft:SetHeight(1)
    sectionLabelLeft:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    sectionLabelLeft:Hide()
    resultRow.sectionLabelLeft = sectionLabelLeft

    local sectionLabelRight = resultRow:CreateTexture(nil, "ARTWORK")
    sectionLabelRight:SetHeight(1)
    sectionLabelRight:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    sectionLabelRight:Hide()
    resultRow.sectionLabelRight = sectionLabelRight

    local sectionLabelText = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sectionLabelText:SetPoint("CENTER", resultRow, "CENTER", 0, 0)
    sectionLabelText:SetTextColor(Utils.RGB(GOLD_COLOR))
    sectionLabelText:Hide()
    resultRow.sectionLabelText = sectionLabelText

    -- Right-aligned currency amount label
    local amountText = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    amountText:SetPoint("RIGHT", resultRow, "RIGHT", -8, 0)
    amountText:SetJustifyH("RIGHT")
    amountText:SetTextColor(0.9, 0.82, 0.65, 1.0)
    amountText:Hide()
    resultRow.amountText = amountText

    Rows.CreateCalculatorWidgets(resultRow, index)
    Rows.CreateSettingWidgets(resultRow)
    -- Right-aligned reputation standing bar
    local repBarBackdrop = {
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 8, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }

    local repBar = CreateFrame("Frame", nil, resultRow, BackdropTemplateMixin and "BackdropTemplate")
    repBar:SetSize(REP_BAR_WIDTH, 19)
    repBar:SetPoint("RIGHT", resultRow, "RIGHT", -6, 0)
    if repBar.SetBackdrop then
        repBar:SetBackdrop(repBarBackdrop)
        repBar:SetBackdropColor(0.06, 0.06, 0.06, 1.0)
        repBar:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    repBar:Hide()
    resultRow.repBar = repBar

    local repClip = CreateFrame("Frame", nil, repBar)
    repClip:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repClip:SetPoint("BOTTOMLEFT", repBar, "BOTTOMLEFT", 0, 0)
    repClip:SetWidth(REP_BAR_WIDTH)
    repClip:SetClipsChildren(true)
    resultRow.repClip = repClip

    local repFill = CreateFrame("Frame", nil, repClip, BackdropTemplateMixin and "BackdropTemplate")
    repFill:SetPoint("TOPLEFT", repBar, "TOPLEFT", 0, 0)
    repFill:SetPoint("BOTTOMRIGHT", repBar, "BOTTOMRIGHT", 0, 0)
    if repFill.SetBackdrop then
        repFill:SetBackdrop(repBarBackdrop)
        repFill:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    resultRow.repFill = repFill

    -- Glossy bar texture (same as WoW default bars); backdrop bgColor matches fill
    -- color so the flat corners blend seamlessly with the glossy center
    local repBarTex = repFill:CreateTexture(nil, "ARTWORK")
    repBarTex:SetPoint("TOPLEFT", repFill, "TOPLEFT", 3, -3)
    repBarTex:SetPoint("BOTTOMRIGHT", repFill, "BOTTOMRIGHT", -3, 3)
    repBarTex:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    resultRow.repBarTex = repBarTex

    -- Text overlay above everything (not clipped)
    local repTextOverlay = CreateFrame("Frame", nil, repBar)
    repTextOverlay:SetAllPoints()
    repTextOverlay:SetFrameLevel(repFill:GetFrameLevel() + 3)
    local repBarText = repTextOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repBarText:SetPoint("CENTER", repBar, "CENTER", 0, 0)
    repBarText:SetTextColor(1.0, 1.0, 1.0, 1.0)
    repBarText:SetShadowOffset(1, -1)
    resultRow.repBarText = repBarText

    local text = resultRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", amountText, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    -- Single-line, no wrap. The render path uses SetClippedText below
    -- to append "..." when the name is too wide for the available
    -- horizontal space, matching how the dropdown widget truncates.
    text:SetWordWrap(false)
    text:SetNonSpaceWrap(false)
    text:SetMaxLines(1)
    resultRow.text = text

    -- Path subtext (flat-headerless mode only). Anchored under the name in the
    -- render path; hidden by default since most rendering branches don't use it.
    -- Single-line, truncated on overflow so long paths can't wrap into the next row.
    local pathSubtext = resultRow:CreateFontString(nil, "OVERLAY", ns.LEAF_FONT)
    pathSubtext:SetJustifyH("LEFT")
    pathSubtext:SetWordWrap(false)
    pathSubtext:SetNonSpaceWrap(false)
    pathSubtext:SetMaxLines(1)
    pathSubtext:Hide()
    resultRow.pathSubtext = pathSubtext

    -- Flat-mode left-side category icon. Shown for collection rows where the
    -- main icon is repositioned to the right (mounts/toys/pets/outfits/sets),
    -- so the row still has a visual left anchor next to the name+path stack.
    local flatCatIcon = resultRow:CreateTexture(nil, "ARTWORK")
    flatCatIcon:Hide()
    resultRow.flatCatIcon = flatCatIcon

    Rows.InstallInteractions(resultRow, index)

    Rows.InstallTooltips(resultRow)

    Results:ApplyResultRowFonts(resultRow)
    resultRow:Hide()
    return resultRow
end
