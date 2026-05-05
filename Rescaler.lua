local _, ns = ...

local Rescaler = {}
ns.Rescaler = Rescaler

local Utils = ns.Utils
local mmax, mmin, mfloor = Utils.mmax, Utils.mmin, Utils.mfloor
local tinsert = Utils.tinsert
local SafeCallMethod = Utils.SafeCallMethod

local GOLD_COLOR = ns.GOLD_COLOR
local DARK_PANEL_BG = ns.DARK_PANEL_BG
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local MIN_WIDTH = 150
local MAX_WIDTH = 600
local HANDLE_SIZE = 10
local GLOW_OUTSET = 6
local PREVIEW_ROW_H = 26
local PREVIEW_PAD = 16
local PREVIEW_MAX_ROWS = 24
local MIN_HEIGHT = 80
local MAX_HEIGHT = 700
local MIN_FONT = 0.5
local MAX_FONT = 2.0

-- Active rescaler state
local activeMode = nil        -- "ui" or "map"
local activeSearchBar = nil   -- the search bar being rescaled
local backdrop = nil          -- full-screen dim
local barOverlay = nil        -- glow around search bar
local resultsOverlay = nil    -- glow around results
local donePanel = nil         -- instruction + Done button
local previewResults = nil    -- fake results frame for preview

local function GetResultsHeight()
    if activeMode == "ui" then return EasyFind.db.uiResultsHeight or 280 end
    return EasyFind.db.mapResultsHeight or 168
end

local function SetResultsHeight(h)
    h = mmax(MIN_HEIGHT, mmin(MAX_HEIGHT, mfloor(h + 0.5)))
    if activeMode == "ui" then EasyFind.db.uiResultsHeight = h
    else EasyFind.db.mapResultsHeight = h end
end

local function GetDefaultResultsHeight()
    if activeMode == "ui" then return 280 end
    return 168
end

local function GetFontScale()
    if activeMode == "ui" then return EasyFind.db.fontSize or 1.0 end
    return EasyFind.db.mapFontSize or 1.0
end

local function SetFontScale(val)
    if activeMode == "ui" then EasyFind.db.fontSize = val
    else EasyFind.db.mapFontSize = val end
end

local function ApplyFontUpdate()
    if activeMode == "ui" then
        if ns.UI and ns.UI.UpdateFontSize then ns.UI:UpdateFontSize() end
    else
        if ns.MapSearch and ns.MapSearch.UpdateFontSize then ns.MapSearch:UpdateFontSize() end
    end
end

-- Helpers

local function ClampWidth(v)
    return mmax(MIN_WIDTH, mmin(MAX_WIDTH, v))
end

local function GetScreenMaxHeight(anchorAbove)
    if not activeSearchBar then return MAX_HEIGHT end
    local available
    if anchorAbove then
        local screenTop = UIParent:GetTop() or UIParent:GetHeight()
        local barTop = activeSearchBar:GetTop() or (screenTop / 2)
        available = screenTop - barTop - 16
    else
        available = (activeSearchBar:GetBottom() or (UIParent:GetHeight() / 2)) - 16
    end
    if available > 0 then
        return mmax(MIN_HEIGHT, mmin(MAX_HEIGHT, mfloor(available)))
    end
    return MAX_HEIGHT
end

local function AddResetButton(editBox, onConfirm)
    local btn = CreateFrame("Button", nil, editBox:GetParent())
    btn:SetSize(editBox:GetWidth(), 16)
    btn:SetPoint("TOP", editBox, "BOTTOM", 0, -2)
    btn:SetFrameLevel(editBox:GetFrameLevel() + 1)

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    text:SetPoint("CENTER")
    text:SetText("Reset")
    text:SetTextColor(1, 1, 1, 1)

    btn:SetScript("OnEnter", function(self)
        text:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
    end)
    btn:SetScript("OnLeave", function(self)
        text:SetTextColor(1, 1, 1, 1)
    end)
    btn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EASYFIND_RESET_FIELD", nil, nil, { callback = onConfirm })
        if dialog then
            dialog:SetFrameStrata("TOOLTIP")
        end
    end)

    editBox.resetBtn = btn
    return btn
end

StaticPopupDialogs["EASYFIND_RESET_FIELD"] = {
    text = "Reset this field to its default value?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function(self, data)
        if data and data.callback then data.callback() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CreateDimLabel(parent, anchor, relPoint, xOff, yOff, prefix)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(50, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(5)
    box:SetJustifyH("CENTER")
    box:SetFontObject("GameFontHighlightSmall")

    if prefix then
        local pfx = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        pfx:SetPoint(anchor, parent, relPoint, xOff, yOff)
        pfx:SetText(prefix)
        pfx:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)
        box:SetPoint("LEFT", pfx, "RIGHT", 6, 0)
        box.prefix = pfx
    else
        box:SetPoint(anchor, parent, relPoint, xOff, yOff)
    end

    local suffix = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    suffix:SetPoint("LEFT", box, "RIGHT", 2, 0)
    suffix:SetText("px")
    suffix:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)
    box.suffix = suffix

    return box
end

-- Create a resize handle at a given edge/corner
local function CreateHandle(parent, point, xOff, yOff, cursor, isHorizontal)
    local handle = CreateFrame("Button", nil, parent)
    handle:SetFrameLevel(parent:GetFrameLevel() + 10)
    if isHorizontal then
        handle:SetSize(HANDLE_SIZE, 1)
        handle:SetPoint("TOP", parent, "TOP", 0, -GLOW_OUTSET)
        handle:SetPoint("BOTTOM", parent, "BOTTOM", 0, GLOW_OUTSET)
        if point == "LEFT" then
            handle:SetPoint("LEFT", parent, "LEFT", xOff, 0)
        else
            handle:SetPoint("RIGHT", parent, "RIGHT", xOff, 0)
        end
    else
        handle:SetHeight(HANDLE_SIZE)
        handle:SetPoint("LEFT", parent, "LEFT", GLOW_OUTSET, 0)
        handle:SetPoint("RIGHT", parent, "RIGHT", -GLOW_OUTSET, 0)
        handle:SetPoint(point, parent, point, 0, yOff)
    end
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")

    -- Visual indicator on hover
    local tex = handle:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0)
    handle.hoverTex = tex

    handle:SetScript("OnEnter", function(self)
        self.hoverTex:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.4)
    end)
    handle:SetScript("OnLeave", function(self)
        self.hoverTex:SetColorTexture(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0)
    end)

    return handle
end

local function CreateScaleHandle(parent, point, xOff, yOff, flipH, flipV)
    local handle = CreateFrame("Button", nil, parent)
    handle:SetSize(16, 16)
    handle:SetPoint(point, parent, point, xOff, yOff)
    handle:SetFrameLevel(parent:GetFrameLevel() + 10)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")

    local texLeft = flipH and 1 or 0
    local texRight = flipH and 0 or 1
    local texTop = flipV and 1 or 0
    local texBottom = flipV and 0 or 1

    handle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    handle:GetNormalTexture():SetTexCoord(texLeft, texRight, texTop, texBottom)
    handle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    handle:GetHighlightTexture():SetTexCoord(texLeft, texRight, texTop, texBottom)
    handle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    handle:GetPushedTexture():SetTexCoord(texLeft, texRight, texTop, texBottom)

    return handle
end

-- Create a golden glow overlay around a target frame
local function CreateGlowOverlay(name, parent, target)
    local glow = CreateFrame("Frame", name, parent, "BackdropTemplate")
    glow:SetFrameStrata("FULLSCREEN_DIALOG")
    glow:SetFrameLevel(200)
    glow:EnableMouse(false)

    glow:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    glow:SetBackdropColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.15)
    glow:SetBackdropBorderColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)

    return glow
end

-- Preview results (fake rows to show results area)

local function CreatePreviewResults(parent, targetFrame, width, heightPx, anchorAbove, leftAligned, flushDock)
    local fontScale = GetFontScale()
    local rowH = PREVIEW_ROW_H * fontScale
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(190)
    frame:SetWidth(width)
    frame:SetHeight(heightPx)

    local gap = flushDock and 0 or 2
    if leftAligned then
        if anchorAbove then
            frame:SetPoint("BOTTOMLEFT", targetFrame, "TOPLEFT", 0, gap)
        else
            frame:SetPoint("TOPLEFT", targetFrame, "BOTTOMLEFT", 0, -gap)
        end
    else
        if anchorAbove then
            frame:SetPoint("BOTTOM", targetFrame, "TOP", 0, gap)
        else
            frame:SetPoint("TOP", targetFrame, "BOTTOM", 0, -gap)
        end
    end

    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.85)
    frame:SetClipsChildren(true)

    local nVisible = mfloor((heightPx - PREVIEW_PAD) / rowH)
    frame.rows = {}
    for i = 1, PREVIEW_MAX_ROWS do
        local row = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        row:SetPoint("LEFT", frame, "LEFT", 12, 0)
        row:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
        local y = -8 - (i - 1) * rowH
        row:SetPoint("TOP", frame, "TOP", 0, y)
        row:SetHeight(rowH)
        row:SetJustifyH("LEFT")
        row:SetJustifyV("TOP")
        row:SetText("|cff666666Sample result " .. i .. "|r")
        if fontScale ~= 1.0 then
            local path, baseSize, flags = GameFontDisable:GetFont()
            row:SetFont(path, baseSize * fontScale, flags)
        end
        row:SetShown(i <= nVisible)
        frame.rows[i] = row
    end

    frame.SetPreviewHeight = function(self, h)
        h = mmax(MIN_HEIGHT, mmin(MAX_HEIGHT, mfloor(h + 0.5)))
        self:SetHeight(h)
        local scaledRowH = PREVIEW_ROW_H * GetFontScale()
        local nVis = mfloor((h - PREVIEW_PAD) / scaledRowH)
        for i = 1, PREVIEW_MAX_ROWS do
            self.rows[i]:SetShown(i <= nVis)
        end
    end

    frame.UpdatePreviewFont = function(self)
        local scale = GetFontScale()
        local path, baseSize, flags = GameFontDisable:GetFont()
        local scaledRowH = PREVIEW_ROW_H * scale
        local h = GetResultsHeight()
        local nVis = mfloor((h - PREVIEW_PAD) / scaledRowH)
        for i = 1, PREVIEW_MAX_ROWS do
            local row = self.rows[i]
            row:SetFont(path, baseSize * scale, flags)
            row:SetHeight(scaledRowH)
            row:ClearAllPoints()
            row:SetPoint("LEFT", self, "LEFT", 12, 0)
            row:SetPoint("RIGHT", self, "RIGHT", -12, 0)
            row:SetPoint("TOP", self, "TOP", 0, -8 - (i - 1) * scaledRowH)
            row:SetShown(i <= nVis)
        end
        self:SetHeight(h)
    end

    return frame
end

-- Dimension label wiring

local function WireDimLabel(box, getter, setter)
    box:SetText(mfloor(getter() + 0.5))
    box:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            setter(val)
            self:SetText(mfloor(getter() + 0.5))
        end
        self:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(mfloor(getter() + 0.5))
        self:ClearFocus()
    end)
end

-- Width drag handler

local function SetupWidthDrag(handle, getWidth, setWidth, widthLabel, side)
    handle:SetScript("OnDragStart", function(self)
        self.dragging = true
        local cx = GetCursorPosition()
        self.lastX = cx / UIParent:GetEffectiveScale()
    end)
    handle:SetScript("OnDragStop", function(self)
        self.dragging = false
        self.lastX = nil
    end)
    handle:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local cx = GetCursorPosition()
        cx = cx / UIParent:GetEffectiveScale()
        if self.lastX then
            local dx = cx - self.lastX
            -- Right edge: positive dx = wider. Left edge: negative dx = wider.
            if side == "LEFT" then dx = -dx end
            -- Width changes apply to both sides, so each edge moves half
            local newW = ClampWidth(getWidth() + dx * 2)
            setWidth(newW)
            if widthLabel and not widthLabel:HasFocus() then
                widthLabel:SetText(mfloor(newW + 0.5))
            end
        end
        self.lastX = cx
    end)
end

-- Corner drag handler (width + height combo)

local function SetupCornerDrag(handle, preview, getWidth, setWidth, widthLabel, heightLabel, anchorAbove)
    handle:SetScript("OnDragStart", function(self)
        self.dragging = true
        local cx, cy = GetCursorPosition()
        local es = UIParent:GetEffectiveScale()
        self.startX = cx / es
        self.startY = cy / es
        self.startWidth = getWidth()
        self.startHeight = GetResultsHeight()
        self.maxH = GetScreenMaxHeight(anchorAbove)
    end)
    handle:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)
    handle:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local cx, cy = GetCursorPosition()
        local es = UIParent:GetEffectiveScale()
        cx = cx / es
        cy = cy / es

        local dx = cx - self.startX
        local newW = ClampWidth(self.startWidth + dx * 2)
        setWidth(newW)
        if widthLabel and not widthLabel:HasFocus() then
            widthLabel:SetText(mfloor(newW + 0.5))
        end

        local dy = self.startY - cy
        if anchorAbove then dy = -dy end
        local newH = mmax(MIN_HEIGHT, mmin(self.maxH, mfloor(self.startHeight + dy + 0.5)))
        SetResultsHeight(newH)
        preview:SetPreviewHeight(newH)
        if heightLabel and not heightLabel:HasFocus() then heightLabel:SetText(newH) end
    end)
end

-- Height drag handler

local function SetupHeightDrag(handle, preview, heightBox, anchorAbove)
    handle:SetScript("OnDragStart", function(self)
        self.dragging = true
        local _, cy = GetCursorPosition()
        self.startY = cy / UIParent:GetEffectiveScale()
        self.startHeight = GetResultsHeight()
        self.maxH = GetScreenMaxHeight(anchorAbove)
    end)
    handle:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)
    handle:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local _, cy = GetCursorPosition()
        cy = cy / UIParent:GetEffectiveScale()
        local dy = self.startY - cy
        if anchorAbove then dy = -dy end
        local newH = mmax(MIN_HEIGHT, mmin(self.maxH, mfloor(self.startHeight + dy + 0.5)))
        SetResultsHeight(newH)
        preview:SetPreviewHeight(newH)
        if not heightBox:HasFocus() then heightBox:SetText(newH) end
    end)
end

-- Font size drag handler

local function SetupFontDrag(handle, fontLabel, preview)
    local PX_PER_STEP = ns.SEARCHBAR_HEIGHT * 0.1

    handle:SetScript("OnDragStart", function(self)
        self.dragging = true
        local _, cy = GetCursorPosition()
        self.startY = cy / UIParent:GetEffectiveScale()
        self.startFont = GetFontScale()
    end)
    handle:SetScript("OnDragStop", function(self)
        self.dragging = false
    end)
    handle:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local _, cy = GetCursorPosition()
        cy = cy / UIParent:GetEffectiveScale()
        -- Dragging down = bigger bar = larger font
        local dy = self.startY - cy
        local stepDelta = mfloor(dy / PX_PER_STEP + 0.5)
        local newFont = mmax(MIN_FONT, mmin(MAX_FONT, self.startFont + stepDelta * 0.1))
        newFont = mfloor(newFont * 10 + 0.5) / 10

        SetFontScale(newFont)
        ApplyFontUpdate()

        -- Update preview row fonts; height stays fixed (font size doesn't change result height)
        if preview and preview.rows then
            local path, baseSize, flags = GameFontDisable:GetFont()
            local scaledRowH = PREVIEW_ROW_H * newFont
            local h = GetResultsHeight()
            local nVis = mfloor((h - PREVIEW_PAD) / scaledRowH)
            for i = 1, PREVIEW_MAX_ROWS do
                local row = preview.rows[i]
                row:SetFont(path, baseSize * newFont, flags)
                row:SetHeight(scaledRowH)
                row:ClearAllPoints()
                row:SetPoint("LEFT", preview, "LEFT", 12, 0)
                row:SetPoint("RIGHT", preview, "RIGHT", -12, 0)
                row:SetPoint("TOP", preview, "TOP", 0, -8 - (i - 1) * scaledRowH)
                row:SetShown(i <= nVis)
            end
            preview:SetHeight(h)
        end

        if not fontLabel:HasFocus() then
            fontLabel:SetText(mfloor(newFont * 100 + 0.5))
        end

        local optPanel = _G["EasyFindOptionsFrame"]
        if optPanel then
            local slider = activeMode == "ui" and optPanel.uiFontSlider or optPanel.mapFontSlider
            if slider then slider:SetValue(newFont) end
        end
    end)
end

-- Build overlays for a target

local function BuildBarOverlay(parent, targetFrame, mode)
    local overlay = CreateGlowOverlay("EasyFindRescaleBarGlow", parent, targetFrame)
    overlay:SetPoint("TOPLEFT", targetFrame, "TOPLEFT", -GLOW_OUTSET, GLOW_OUTSET)
    overlay:SetPoint("BOTTOMRIGHT", targetFrame, "BOTTOMRIGHT", GLOW_OUTSET, -GLOW_OUTSET)

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(mode == "ui" and "UI Search Bar" or "Map Search Bar")
    label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)

    local widthBox = CreateDimLabel(overlay, "LEFT", "RIGHT", 8, 0, "Width:")
    overlay.widthBox = widthBox

    -- Width drag handles (left and right edges)
    local leftHandle = CreateHandle(overlay, "LEFT", 0, 0, nil, true)
    local rightHandle = CreateHandle(overlay, "RIGHT", 0, 0, nil, true)
    overlay.leftHandle = leftHandle
    overlay.rightHandle = rightHandle

    -- Bottom drag handle (for font size)
    local bottomHandle = CreateHandle(overlay, "BOTTOM", 0, 0, nil, false)
    overlay.bottomHandle = bottomHandle

    -- Font size field (below bottom edge)
    local fontBox = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
    fontBox:SetSize(50, 20)
    fontBox:SetAutoFocus(false)
    fontBox:SetMaxLetters(4)
    fontBox:SetJustifyH("CENTER")
    fontBox:SetFontObject("GameFontHighlightSmall")

    local fontPfx = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fontPfx:SetPoint("TOP", overlay, "BOTTOM", 0, -4)
    fontPfx:SetText("Font:")
    fontPfx:SetTextColor(0.9, 0.3, 0.3, 1.0)
    fontBox:SetPoint("LEFT", fontPfx, "RIGHT", 6, 0)

    local fontSuffix = fontBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fontSuffix:SetPoint("LEFT", fontBox, "RIGHT", 2, 0)
    fontSuffix:SetText("%")
    fontSuffix:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)

    -- Tooltip on the prefix label
    local fontTip = CreateFrame("Frame", nil, overlay)
    fontTip:SetAllPoints(fontPfx)
    fontTip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Changing font size also resizes the search bar and results window.")
        GameTooltip:Show()
    end)
    fontTip:SetScript("OnLeave", GameTooltip_Hide)

    overlay.fontBox = fontBox

    return overlay
end

local function BuildResultsOverlay(parent, targetFrame, anchorAbove)
    local overlay = CreateGlowOverlay("EasyFindRescaleResultsGlow", parent, targetFrame)
    overlay:SetPoint("TOPLEFT", targetFrame, "TOPLEFT", -GLOW_OUTSET, GLOW_OUTSET)
    overlay:SetPoint("BOTTOMRIGHT", targetFrame, "BOTTOMRIGHT", GLOW_OUTSET, -GLOW_OUTSET)

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText("Search Results")
    label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)

    local widthBox = CreateDimLabel(overlay, "LEFT", "RIGHT", 8, 0, "Width:")
    overlay.widthBox = widthBox

    -- Height drag edge and corner handle: top edge when above, bottom edge when below
    local heightEdge = anchorAbove and "TOP" or "BOTTOM"
    local cornerPoint = anchorAbove and "TOPRIGHT" or "BOTTOMRIGHT"
    local flipV = anchorAbove

    local scaleHandle = CreateScaleHandle(overlay, cornerPoint, 0, 0, false, flipV)
    overlay.scaleHandle = scaleHandle

    -- Width drag handles
    local leftHandle = CreateHandle(overlay, "LEFT", 0, 0, nil, true)
    local rightHandle = CreateHandle(overlay, "RIGHT", 0, 0, nil, true)
    overlay.leftHandle = leftHandle
    overlay.rightHandle = rightHandle

    -- Height drag handle (top or bottom edge)
    local heightHandle = CreateHandle(overlay, heightEdge, 0, 0, nil, false)
    overlay.heightHandle = heightHandle

    -- Height field (outside the resize edge)
    local heightBox = CreateFrame("EditBox", nil, overlay, "InputBoxTemplate")
    heightBox:SetSize(50, 20)
    heightBox:SetAutoFocus(false)
    heightBox:SetMaxLetters(3)
    heightBox:SetJustifyH("CENTER")
    heightBox:SetFontObject("GameFontHighlightSmall")

    local heightPfx = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    heightPfx:SetText("Height:")
    heightPfx:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)
    if anchorAbove then
        heightPfx:SetPoint("BOTTOM", overlay, "TOP", 0, 4)
    else
        heightPfx:SetPoint("TOP", overlay, "BOTTOM", 0, -4)
    end
    heightBox:SetPoint("LEFT", heightPfx, "RIGHT", 6, 0)

    local heightSuffix = heightBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    heightSuffix:SetPoint("LEFT", heightBox, "RIGHT", 2, 0)
    heightSuffix:SetText("px")
    heightSuffix:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.7)

    overlay.heightBox = heightBox
    overlay.heightPfx = heightPfx
    overlay.anchorAbove = anchorAbove

    return overlay
end

-- Done panel

local function CreateDonePanel(parent)
    local BACK_W = 110
    local DONE_W = 80
    local BTN_GAP = 2
    local BTN_H = 22
    local PANEL_PAD = 8
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetSize(BACK_W + BTN_GAP + DONE_W + PANEL_PAD * 2, BTN_H + 14)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(209)
    panel:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropColor(DARK_PANEL_BG[1], DARK_PANEL_BG[2], DARK_PANEL_BG[3], DARK_PANEL_BG[4])

    local backBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    backBtn:SetSize(BACK_W, BTN_H)
    backBtn:SetPoint("LEFT", panel, "LEFT", PANEL_PAD, 0)
    backBtn:SetText("Back to Options")
    panel.backBtn = backBtn

    local doneBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    doneBtn:SetSize(DONE_W, BTN_H)
    doneBtn:SetPoint("LEFT", backBtn, "RIGHT", BTN_GAP, 0)
    doneBtn:SetText("Done")
    panel.doneBtn = doneBtn

    return panel
end

-- Full-screen dim backdrop

local function GetOrCreateBackdrop()
    if backdrop then return backdrop end
    backdrop = CreateFrame("Frame", "EasyFindRescaleBackdrop", UIParent)
    backdrop:SetFrameStrata("FULLSCREEN")
    backdrop:SetAllPoints(UIParent)
    backdrop:EnableMouse(false)

    local tex = backdrop:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetColorTexture(0, 0, 0, 0.5)

    tinsert(UISpecialFrames, "EasyFindRescaleBackdrop")

    local SafeCallMethod = Utils.SafeCallMethod
    backdrop:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            Rescaler:Exit()
        else
            SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)


    return backdrop
end

-- Enter rescale mode

function Rescaler:Enter(mode)
    if activeMode then
        self:Exit()
    end

    activeMode = mode

    local searchBar, resultsFrame
    local getBarWidth, setBarWidth
    local getResultsWidth, setResultsWidth, getResultsScale

    if mode == "ui" then
        searchBar = _G["EasyFindSearchFrame"]
        resultsFrame = _G["EasyFindResultsFrame"]

        if not searchBar then
            activeMode = nil
            return
        end

        -- Force visible
        searchBar:Show()
        searchBar:SetAlpha(1.0)

        -- UI mode is the unified rounded-pill design: bar + results
        -- share one rounded silhouette and one width. Both setters
        -- below drive the same width so the bar overlay and results
        -- overlay handles all stay in sync.
        local function setUiWidth(w)
            w = ClampWidth(w)
            searchBar:SetWidth(w)
            EasyFind.db.uiSearchWidth = w / 250
            EasyFind.db.uiResultsWidth = w
            if resultsFrame then resultsFrame:SetWidth(w) end
        end

        getBarWidth = function() return searchBar:GetWidth() end
        setBarWidth = setUiWidth

        getResultsScale = function() return EasyFind.db.uiResultsScale or 1.0 end

        getResultsWidth = function() return searchBar:GetWidth() end
        setResultsWidth = setUiWidth

    elseif mode == "map" then
        -- Open the world map if not already visible (search bars are anchored to it)
        if not WorldMapFrame or not WorldMapFrame:IsShown() then
            ToggleWorldMap()
        end

        searchBar = _G["EasyFindMapGlobalSearchFrame"]
        resultsFrame = _G["EasyFindMapResultsFrame"]

        if not searchBar then
            activeMode = nil
            return
        end

        getBarWidth = function() return searchBar:GetWidth() end
        setBarWidth = function(w)
            w = ClampWidth(w)
            EasyFind.db.mapSearchWidth = w / 250
            searchBar:SetWidth(w)
            local localBar = _G["EasyFindMapSearchFrame"]
            if localBar then localBar:SetWidth(w) end
        end

        getResultsScale = function() return EasyFind.db.mapResultsScale or 1.0 end

        getResultsWidth = function()
            if resultsFrame then return resultsFrame:GetWidth() end
            return 300 * (EasyFind.db.mapSearchWidth or 1.0)
        end
        setResultsWidth = function(w)
            w = ClampWidth(w)
            if ns.MapSearch and ns.MapSearch.GetMaxResultsWidth then
                w = mmin(w, ns.MapSearch:GetMaxResultsWidth())
            end
            EasyFind.db.mapResultsWidth = w
            if resultsFrame then resultsFrame:SetWidth(w) end
        end
    end

    -- Hide options panel
    local optPanel = _G["EasyFindOptionsFrame"]
    if optPanel and optPanel:IsShown() then
        optPanel:Hide()
    end

    activeSearchBar = searchBar

    -- Block focus but allow shift-drag
    searchBar.setupMode = true
    if searchBar.editBox then
        searchBar.editBox:ClearFocus()
    end

    -- Dim backdrop
    local bg = GetOrCreateBackdrop()
    bg:Show()
    SafeCallMethod(bg, "EnableKeyboard", true)

    -- Preview results (fake rows so user sees the results area)
    local resultsAbove = (mode == "ui" and EasyFind.db.uiResultsAbove)
        or (mode == "map" and EasyFind.db.mapResultsAbove)
    local previewW = getResultsWidth()
    local currentH = mmin(GetResultsHeight(), GetScreenMaxHeight(resultsAbove))
    local leftAligned = (mode == "map")
    -- UI mode is the unified pill: dock the preview flush against the
    -- bar (zero gap) so width changes look continuous.
    local flushDock = (mode == "ui")
    previewResults = CreatePreviewResults(bg, searchBar, previewW, currentH, resultsAbove, leftAligned, flushDock)
    previewResults:SetScale(getResultsScale())
    previewResults:Show()

    -- Bar overlay
    barOverlay = BuildBarOverlay(bg, searchBar, mode)
    barOverlay:Show()

    -- Results overlay (around the preview)
    resultsOverlay = BuildResultsOverlay(bg, previewResults, resultsAbove)
    resultsOverlay:Show()

    -- If height label is near screen edge, flip it inside the overlay
    local resizeEdge = resultsAbove and resultsOverlay:GetTop() or resultsOverlay:GetBottom()
    local screenLimit = resultsAbove and UIParent:GetTop() or 0
    local nearEdge = resultsAbove and (resizeEdge and screenLimit and (screenLimit - resizeEdge) < 40)
        or (not resultsAbove and resizeEdge and resizeEdge < 40)
    if nearEdge then
        resultsOverlay.heightPfx:ClearAllPoints()
        if resultsAbove then
            resultsOverlay.heightPfx:SetPoint("TOPLEFT", resultsOverlay, "TOPLEFT", GLOW_OUTSET + 4, -8)
        else
            resultsOverlay.heightPfx:SetPoint("BOTTOMLEFT", resultsOverlay, "BOTTOMLEFT", GLOW_OUTSET + 4, 8)
        end
        resultsOverlay.heightInside = true
    end

    -- Wire bar width drag. In UI mode the preview is the live results
    -- area; resize it in lockstep so the unified pill stays continuous.
    local function setBarWidthAndPreview(w)
        setBarWidth(w)
        if mode == "ui" then previewResults:SetWidth(searchBar:GetWidth()) end
    end
    SetupWidthDrag(barOverlay.leftHandle, getBarWidth, setBarWidthAndPreview, barOverlay.widthBox, "LEFT")
    SetupWidthDrag(barOverlay.rightHandle, getBarWidth, setBarWidthAndPreview, barOverlay.widthBox, "RIGHT")
    WireDimLabel(barOverlay.widthBox, getBarWidth, setBarWidthAndPreview)
    AddResetButton(barOverlay.widthBox, function()
        local defW = 250 * 0.88  -- 220px (matches DB_DEFAULTS searchWidth = 0.88)
        setBarWidthAndPreview(defW)
        barOverlay.widthBox:SetText(mfloor(defW + 0.5))
    end)

    -- Wire bar bottom edge (font size)
    local currentFont = GetFontScale()
    barOverlay.fontBox:SetText(mfloor(currentFont * 100 + 0.5))
    barOverlay.fontBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = mmax(MIN_FONT * 100, mmin(MAX_FONT * 100, mfloor(val + 0.5)))
            local newFont = val / 100
            SetFontScale(newFont)
            ApplyFontUpdate()
            self:SetText(val)
            previewResults:UpdatePreviewFont()
        end
        self:ClearFocus()
    end)
    barOverlay.fontBox:SetScript("OnEscapePressed", function(self)
        self:SetText(mfloor(GetFontScale() * 100 + 0.5))
        self:ClearFocus()
    end)
    AddResetButton(barOverlay.fontBox, function()
        SetFontScale(0.9)
        ApplyFontUpdate()
        barOverlay.fontBox:SetText(90)
        previewResults:UpdatePreviewFont()
    end)
    SetupFontDrag(barOverlay.bottomHandle, barOverlay.fontBox, previewResults)

    -- Wire results width drag. UI mode locks results width to bar
    -- width (single rounded pill), so the results overlay's width
    -- handles + width box are redundant -- hide them entirely. The
    -- bar's width handles already update the preview width via
    -- setBarWidth above.
    if mode == "ui" then
        resultsOverlay.leftHandle:Hide()
        resultsOverlay.rightHandle:Hide()
        resultsOverlay.widthBox:Hide()
        if resultsOverlay.widthBox.prefix then resultsOverlay.widthBox.prefix:Hide() end
        if resultsOverlay.widthBox.suffix then resultsOverlay.widthBox.suffix:Hide() end
    else
        SetupWidthDrag(resultsOverlay.leftHandle, getResultsWidth, function(w)
            setResultsWidth(w)
            previewResults:SetWidth(w)
        end, resultsOverlay.widthBox, "LEFT")
        SetupWidthDrag(resultsOverlay.rightHandle, getResultsWidth, function(w)
            setResultsWidth(w)
            previewResults:SetWidth(w)
        end, resultsOverlay.widthBox, "RIGHT")
        WireDimLabel(resultsOverlay.widthBox, getResultsWidth, function(v)
            setResultsWidth(v)
            previewResults:SetWidth(v)
        end)
        AddResetButton(resultsOverlay.widthBox, function()
            local defW = 300
            setResultsWidth(defW)
            previewResults:SetWidth(defW)
            resultsOverlay.widthBox:SetText(mfloor(defW + 0.5))
        end)
    end

    -- Wire results corner (width + height combo)
    resultsOverlay.heightBox:SetText(currentH)
    resultsOverlay.heightBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = mmax(MIN_HEIGHT, mmin(GetScreenMaxHeight(resultsAbove), mfloor(val + 0.5)))
            SetResultsHeight(val)
            previewResults:SetPreviewHeight(val)
            self:SetText(val)
        end
        self:ClearFocus()
    end)
    resultsOverlay.heightBox:SetScript("OnEscapePressed", function(self)
        self:SetText(GetResultsHeight())
        self:ClearFocus()
    end)
    local heightReset = AddResetButton(resultsOverlay.heightBox, function()
        local def = GetDefaultResultsHeight()
        SetResultsHeight(def)
        previewResults:SetPreviewHeight(def)
        resultsOverlay.heightBox:SetText(def)
    end)
    if resultsOverlay.anchorAbove then
        heightReset:ClearAllPoints()
        heightReset:SetPoint("BOTTOM", resultsOverlay.heightBox, "TOP", 0, 2)
    end
    if resultsOverlay.heightInside then
        heightReset:ClearAllPoints()
        if resultsOverlay.anchorAbove then
            heightReset:SetPoint("TOP", resultsOverlay.heightBox, "BOTTOM", 0, -2)
        else
            heightReset:SetPoint("BOTTOM", resultsOverlay.heightBox, "TOP", 0, 2)
        end
    end
    if mode == "ui" then
        -- Width is locked to the bar in UI mode; the corner handle
        -- only changes height. Reuse the height-only handler.
        SetupHeightDrag(resultsOverlay.scaleHandle, previewResults, resultsOverlay.heightBox, resultsAbove)
    else
        SetupCornerDrag(resultsOverlay.scaleHandle, previewResults, getResultsWidth, function(w)
            setResultsWidth(w)
            previewResults:SetWidth(w)
        end, resultsOverlay.widthBox, resultsOverlay.heightBox, resultsAbove)
    end

    -- Wire results bottom edge (height)
    SetupHeightDrag(resultsOverlay.heightHandle, previewResults, resultsOverlay.heightBox, resultsAbove)

    -- Done panel
    donePanel = CreateDonePanel(bg)
    if mode == "map" then
        donePanel:SetPoint("BOTTOM", barOverlay, "TOP", 0, 0)
    else
        donePanel:SetPoint("TOP", resultsOverlay, "BOTTOM", 0, -50)
    end
    donePanel.doneBtn:SetScript("OnClick", function()
        Rescaler:Exit()
    end)
    donePanel.backBtn:SetScript("OnClick", function()
        Rescaler:Exit(true)
    end)
    donePanel:Show()
end

-- Exit rescale mode

function Rescaler:Exit(reopenOptions)
    if not activeMode then return end

    -- Clean up all overlay frames
    if barOverlay then
        barOverlay.leftHandle:SetScript("OnUpdate", nil)
        barOverlay.rightHandle:SetScript("OnUpdate", nil)
        barOverlay.bottomHandle:SetScript("OnUpdate", nil)
        barOverlay:Hide()
        barOverlay = nil
    end
    if resultsOverlay then
        resultsOverlay.leftHandle:SetScript("OnUpdate", nil)
        resultsOverlay.rightHandle:SetScript("OnUpdate", nil)
        resultsOverlay.scaleHandle:SetScript("OnUpdate", nil)
        resultsOverlay.heightHandle:SetScript("OnUpdate", nil)
        resultsOverlay:Hide()
        resultsOverlay = nil
    end
    if previewResults then
        previewResults:Hide()
        previewResults = nil
    end
    if donePanel then
        donePanel:Hide()
        donePanel = nil
    end
    if backdrop then
        SafeCallMethod(backdrop, "EnableKeyboard", false)
        backdrop:Hide()
    end

    if activeSearchBar then
        activeSearchBar.setupMode = nil
        activeSearchBar = nil
    end

    -- Apply final values
    if activeMode == "ui" then
        if ns.UI then
            if ns.UI.UpdateScale then ns.UI:UpdateScale() end
            if ns.UI.UpdateWidth then ns.UI:UpdateWidth() end
            if ns.UI.RefreshResults then ns.UI:RefreshResults() end
        end
    elseif activeMode == "map" then
        if ns.MapSearch then
            if ns.MapSearch.UpdateScale then ns.MapSearch:UpdateScale() end
            if ns.MapSearch.UpdateWidth then ns.MapSearch:UpdateWidth() end
            if ns.MapSearch.UpdateResultsWidth then ns.MapSearch:UpdateResultsWidth() end
        end
    end

    activeMode = nil

    if reopenOptions then
        local optPanel = _G["EasyFindOptionsFrame"]
        if optPanel then optPanel:Show() end
    end
end

function Rescaler:IsActive()
    return activeMode ~= nil
end
