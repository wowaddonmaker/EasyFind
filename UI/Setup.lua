local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils
local mmin, mmax = Utils.mmin, Utils.mmax
local xpcall = Utils.xpcall
local ErrorHandler = Utils.ErrorHandler

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local UIParent = UIParent
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local GetCursorPosition = GetCursorPosition
-- WHAT'S NEW POPUP
-- Shown once per version update for returning users.
function UI:ShowWhatsNew(version)
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

    -- Footer - anchored below body so it can't overlap
    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("TOP", body, "BOTTOM", 0, -12)
    footer:SetText("Full changelog on CurseForge and GitHub")

    -- "Got it" button - anchored below footer
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

-- FIRST-TIME SETUP OVERLAY
-- Shown once on fresh install to let the user position & scale the search bar
-- and learn about Fast vs Guide mode. Persisted account-wide via
-- EasyFind.db.setupComplete.
function UI:ShowFirstTimeSetup()
    local searchFrame = UI:GetSearchFrame()
    if not searchFrame then return end
    if EasyFind.db.setupComplete then return end

    -- Force search bar visible during setup (override SmartShow / hidden state)
    EasyFind.db.visible = true
    searchFrame:Show()
    searchFrame:SetAlpha(1.0)
    -- Dim just the search bar backdrop (not child frames like the overlay)
    searchFrame:SetBackdropColor(0.2, 0.2, 0.2, 0.4)
    searchFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.4)
    if searchFrame.hoverZone then searchFrame.hoverZone:Hide() end
    searchFrame.setSmartShowVisible(true)

    searchFrame.setupMode = true
    searchFrame.editBox:EnableMouse(false)

    -- Golden glow overlay (port of the v1.5.0 setup glow). 6px outset
    -- from the search bar, pulsing fill, gold border, "Drag to move"
    -- label centered on top.
    local glow = CreateFrame("Frame", "EasyFindSetupGlow", searchFrame, "BackdropTemplate")
    glow:SetPoint("TOPLEFT", searchFrame, "TOPLEFT", -6, 6)
    glow:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", 6, -6)
    glow:SetFrameStrata("DIALOG")
    glow:SetFrameLevel(100)
    glow:EnableMouse(false)  -- clicks pass through to search bar
    glow:SetIgnoreParentAlpha(true)  -- stay opaque when search bar fades

    glow:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    glow:SetBackdropColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.20)
    glow:SetBackdropBorderColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1.0)

    -- Gentle pulse on the gold fill
    local pulseUp = true
    local pulseAlpha = 0.20
    Utils.SafeOnUpdate(glow, function(self, elapsed)
        if pulseUp then
            pulseAlpha = pulseAlpha + elapsed * 0.12
            if pulseAlpha >= 0.35 then pulseAlpha = 0.35; pulseUp = false end
        else
            pulseAlpha = pulseAlpha - elapsed * 0.12
            if pulseAlpha <= 0.12 then pulseAlpha = 0.12; pulseUp = true end
        end
        self:SetBackdropColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], pulseAlpha)
    end)

    -- Centered label overlaid on the glow (like edit-mode frame labels).
    local setupLabel = glow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setupLabel:SetPoint("CENTER", glow, "CENTER", 0, 0)
    setupLabel:SetText("Drag to move")
    setupLabel:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 0.9)

    -- Resize handle (bottom-left corner of the search bar). Parents to
    -- searchFrame so it fades in sync when Smart Show hides the bar.
    local resizer = CreateFrame("Button", nil, searchFrame)
    resizer:SetFrameStrata("DIALOG")
    resizer:SetFrameLevel(searchFrame:GetFrameLevel() + 20)
    resizer:SetSize(16, 16)
    resizer:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", 0, 0)
    resizer:EnableMouse(true)

    -- Bright gold grabber: additive blend mode over a solid-gold vertex
    -- color makes the lines read well on any background. The Blizzard
    -- grabber texture is already oriented for bottom-right, so no flip.
    local function styleResizerTex(tex)
        tex:SetVertexColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], 1)
        tex:SetBlendMode("ADD")
    end
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    styleResizerTex(resizer:GetNormalTexture())
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    styleResizerTex(resizer:GetHighlightTexture())
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    styleResizerTex(resizer:GetPushedTexture())

    resizer:SetScript("OnEnter", function(self)
        if self.dragging then return end  -- don't show tooltip mid-drag
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    resizer:SetScript("OnLeave", GameTooltip_Hide)

    local function scaleResizerVisual()
        resizer:SetSize(16, 16)
    end

    -- Dragging the bottom-left corner adjusts the search bar preview in two axes:
    --   horizontal  -> uiSearchWidth (symmetric growth around a locked top-center)
    --   vertical    -> uiSearchBarHeight
    --
    -- Uses OnMouseDown (not RegisterForDrag) so there's no 4-pixel drag
    -- threshold: the bar starts resizing the instant the cursor moves.
    -- Delta-from-start math keeps the cursor locked to wherever on the
    -- resizer the user originally clicked - if they clicked the middle
    -- of the hitbox, the middle of the hitbox follows the cursor.
    resizer.dragging = false
    resizer:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        GameTooltip_Hide()  -- hide the hover tooltip while dragging
        self.dragging = true
        searchFrame.resizing = true

        -- Snapshot the current top-center as a stationary anchor for
        -- symmetric horizontal growth and top-down vertical growth.
        local left, right, top = searchFrame:GetLeft(), searchFrame:GetRight(), searchFrame:GetTop()
        if not (left and right and top) then
            self.dragging = false
            searchFrame.resizing = nil
            return
        end
        self.anchorCenterX = (left + right) / 2
        self.anchorTopY = top
        searchFrame:ClearAllPoints()
        searchFrame:SetPoint("TOP", UIParent, "BOTTOMLEFT", self.anchorCenterX, self.anchorTopY)

        -- Snapshot starting cursor position and starting db values so the
        -- per-frame math can compute deltas absolutely without drift and
        -- without snapping the corner to the cursor at drag start.
        self.startCx, self.startCy = GetCursorPosition()
        self.startWidth = EasyFind.db.uiSearchWidth or 1.0
        self.startBarHeight = UI:GetSearchBarHeight()
    end)

    local function stopResize(self)
        if not self.dragging then return end
        self.dragging = false
        searchFrame.resizing = nil
        self.anchorCenterX = nil
        self.anchorTopY = nil
        self.startCx = nil
        self.startCy = nil
        self.startWidth = nil
        self.startBarHeight = nil

        -- Persist the new TOP-anchored position so the bar sticks after drag.
        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}
    end

    resizer:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        stopResize(self)
    end)

    Utils.SafeOnUpdate(resizer, function(self)
        if not self.dragging then return end
        -- If the user released the button outside the hitbox, OnMouseUp
        -- won't fire - bail out when we detect the button is no longer down.
        if not IsMouseButtonDown("LeftButton") then
            stopResize(self)
            return
        end
        if not (self.startCx and self.startCy and self.startWidth and self.startBarHeight) then return end

        local cx, cy = GetCursorPosition()
        local effScale = searchFrame:GetEffectiveScale() or 1.0
        if effScale <= 0 then return end

        -- Delta from the cursor's starting position (in raw screen pixels).
        local dxScreen = cx - self.startCx
        local dyScreen = cy - self.startCy

        -- Bottom-right corner: cursor moving RIGHT should grow the bar
        -- symmetrically, cursor moving DOWN should grow the bar strip.
        --   d(uiSearchWidth) =  dxScreen / (effScale * 125)
        --   d(barHeight)     = -dyScreen / effScale
        local newWidth = self.startWidth + dxScreen / (effScale * 125)
        local newBarH  = self.startBarHeight - dyScreen / effScale

        newWidth = mmax(0.5, mmin(2.5, newWidth))
        newBarH = mmax(24, mmin(56, newBarH))

        EasyFind.db.uiSearchWidth = newWidth
        EasyFind.db.uiSearchBarHeight = newBarH
        UI:UpdateWidth()
        UI:UpdateSearchBarHeight()
        scaleResizerVisual()
    end)

    -- Set the initial resizer size.
    scaleResizerVisual()

    -- Fixed panel width: comfortably holds the keybind rows and
    -- two-button bottom strip without wrapping.
    local panelWidth = 290

    -- Instruction panel (anchored below the search bar)
    local panel = CreateFrame("Frame", nil, searchFrame, "BackdropTemplate")
    panel:SetSize(panelWidth, 245)
    panel:SetPoint("TOP", searchFrame, "BOTTOM", 0, -6)
    panel:SetIgnoreParentAlpha(true)  -- survive Smart Show fade
    panel:SetFrameStrata("DIALOG")
    panel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = TOOLTIP_BORDER,
        edgeSize = 14,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    panel:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.7)

    -- "Setup" header (centered, just under the panel top).
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOP", panel, "TOP", 0, -10)
    header:SetText("Setup")

    -- Horizontal separator immediately under the header.
    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("LEFT", panel, "LEFT", 12, 0)
    sep:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
    sep:SetPoint("TOP", header, "BOTTOM", 0, -8)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Smart Show checkbox aligned to the panel's left margin (sep is
    -- already anchored at panel.left + 12 so 0 keeps the checkbox box
    -- flush with the separator without further indentation).
    local smartShowCheckbox = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    smartShowCheckbox:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -6)
    smartShowCheckbox.Text:SetText("|cffFFD100Smart Show|r |cff999999(Recommended)|r")
    smartShowCheckbox:SetChecked(false)
    smartShowCheckbox:SetScript("OnClick", function(self)
        -- Apply live so the player can see the hover behavior immediately,
        -- same as the matching toggle in /ef options. The tutorial panel
        -- has SetIgnoreParentAlpha(true) so it stays visible even when the
        -- search bar fades out.
        EasyFind.db.smartShow = self:GetChecked()
        UI:UpdateSmartShow()
    end)

    -- Smart Show description - uses same font as checkbox text for consistency
    local smartDesc = smartShowCheckbox:CreateFontString(nil, "OVERLAY")
    smartDesc:SetFontObject(smartShowCheckbox.Text:GetFontObject())
    smartDesc:SetPoint("TOPLEFT", smartShowCheckbox.Text, "BOTTOMLEFT", 0, -2)
    smartDesc:SetWidth(panelWidth - 60)
    smartDesc:SetJustifyH("LEFT")
    smartDesc:SetText("|cff999999Bar hides when your mouse moves away and reappears when you hover near it.|r")

    -- Keybind rows. Each row = [label] [keybind button] [recommended hint].
    -- Click the button to capture a key, right-click to clear, Esc to cancel,
    -- mirrors the keybind UI in /ef Options > Shortcuts.
    local function GetKeybindLabel(action)
        local k1 = GetBindingKey(action) or EasyFind:GetAccountKeybind(action)
        return k1 or "Not Bound"
    end

    local function StopKeybindCapture(btn, action)
        btn.waitingForKey = false
        btn:SetText(GetKeybindLabel(action))
        btn:UnlockHighlight()
        Utils.SafeCallMethod(btn, "EnableKeyboard", false)
        btn:SetScript("OnKeyDown", nil)
    end

    -- Two-column symmetric layout. Row 1 = labels, row 2 = buttons.
    -- Each column is centered in half the panel; the label and button
    -- inside a column share an x-center, so the button sits directly
    -- under its label.
    local KEYBIND_BTN_W = 110
    local LEFT_COL_X    = panelWidth / 4   -- center of the left half
    local RIGHT_COL_X   = panelWidth * 3/4 -- center of the right half

    -- Section header for the keybind row, with a thin divider underneath
    -- so it reads as a labeled subsection rather than two loose buttons.
    local keybindHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keybindHeader:SetText("Keybindings")
    keybindHeader:SetPoint("TOP", smartDesc, "BOTTOM", 0, -16)

    local keybindDivider = panel:CreateTexture(nil, "ARTWORK")
    keybindDivider:SetColorTexture(1, 1, 1, 0.18)
    keybindDivider:SetHeight(1)
    keybindDivider:SetPoint("LEFT", panel, "LEFT", 24, 0)
    keybindDivider:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
    keybindDivider:SetPoint("TOP", keybindHeader, "BOTTOM", 0, -4)

    -- Invisible row anchor: y is locked to the divider so the labels
    -- below sit a fixed gap under it. Width spans the panel so label
    -- x = row.left + colCenterX places each label center on its column.
    -- Using a single-anchor TOP on each label avoids the over-constrained
    -- x that two SetPoints would create.
    local keybindRow = CreateFrame("Frame", nil, panel)
    keybindRow:SetHeight(1)
    keybindRow:SetPoint("LEFT",  panel, "LEFT")
    keybindRow:SetPoint("RIGHT", panel, "RIGHT")
    keybindRow:SetPoint("TOP",   keybindDivider, "BOTTOM", 0, -10)

    local function CreateKeybindLabel(text, colCenterX)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetText(text)
        lbl:SetPoint("TOP", keybindRow, "TOPLEFT", colCenterX, 0)
        return lbl
    end

    local function CreateKeybindButton(label, anchorLabel, action, recommended)
        local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        btn:SetSize(KEYBIND_BTN_W, 22)
        btn:SetPoint("TOP", anchorLabel, "BOTTOM", 0, -4)
        btn:SetText(GetKeybindLabel(action))
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" then
                EasyFind:SetAccountKeybind(action, nil)
                self:SetText("Not Bound")
                return
            end
            if self.waitingForKey then
                StopKeybindCapture(self, action)
                return
            end
            self.waitingForKey = true
            self:SetText("Press a key...")
            self:LockHighlight()
            Utils.SafeCallMethod(self, "EnableKeyboard", true)
            self:SetScript("OnKeyDown", function(s, key)
                if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
                   or key == "LALT" or key == "RALT" then return end
                if key == "ESCAPE" then
                    StopKeybindCapture(s, action)
                    return
                end
                -- Reject bare SPACE/ENTER/movement keys -- they're vital
                -- defaults (jump, accept, WASD) and silently overwriting
                -- them on a stray keypress during capture has bricked
                -- spacebar after a /reload more than once. Only bind
                -- these when modified.
                local hasMod = IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown()
                if not hasMod and (key == "SPACE" or key == "ENTER"
                    or key == "W" or key == "A" or key == "S" or key == "D") then
                    return
                end
                local combo = ""
                if IsAltKeyDown() then combo = combo .. "ALT-" end
                if IsControlKeyDown() then combo = combo .. "CTRL-" end
                if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
                combo = combo .. key
                EasyFind:SetAccountKeybind(action, combo)
                StopKeybindCapture(s, action)
            end)
        end)
        btn:HookScript("OnEnter", function(self)
            UI:AnchorTooltipAtCursor(GameTooltip, self)
            GameTooltip:AddLine("Recommended: " .. recommended, 1, 1, 1, true)
            GameTooltip:AddLine("Click to bind. Right-click to clear.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        btn:HookScript("OnLeave", GameTooltip_Hide)
        return btn
    end

    local toggleLabel = CreateKeybindLabel("Toggle bar", LEFT_COL_X)
    local mapLabel    = CreateKeybindLabel("Open map search", RIGHT_COL_X)
    CreateKeybindButton("toggle", toggleLabel, "EASYFIND_TOGGLE_FOCUS", "Ctrl+Space")
    CreateKeybindButton("map",    mapLabel,    "EASYFIND_MAP_FOCUS",    "Ctrl+M")

    local gotItBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    gotItBtn:SetSize(100, 22)
    gotItBtn:SetPoint("TOP", panel, "BOTTOM", 0, -8)
    gotItBtn:SetText("Got it")

    -- During setup: allow drag without holding Shift
    searchFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    local function FinishSetup()
        EasyFind.db.setupComplete = true

        local point, _, relPoint, x, y = searchFrame:GetPoint()
        EasyFind.db.uiSearchPosition = {point, relPoint, x, y}

        searchFrame.setupMode = nil
        searchFrame.editBox:EnableMouse(true)
        UI:UpdateSearchBarTheme()  -- restore proper backdrop colors
        glow:SetScript("OnUpdate", nil)
        glow:Hide()
        resizer:SetScript("OnUpdate", nil)
        resizer:Hide()
        panel:Hide()

        searchFrame:SetScript("OnDragStart", function(self)
            if IsShiftKeyDown() then
                self:StartMoving()
            end
        end)

        EasyFind.db.smartShow = smartShowCheckbox:GetChecked()
        UI:UpdateSmartShow()

        -- Record current version so What's New won't fire on next login
        -- (brand-new users don't need to see it - all features are new for them)
        EasyFind.db.lastSeenVersion = ns.version
    end

    gotItBtn:SetScript("OnClick", FinishSetup)

    -- Escape closes the whole tutorial from the positioning panel.
    Utils.SafeCallMethod(panel, "EnableKeyboard", true)
    Utils.SafeCallMethod(panel, "SetPropagateKeyboardInput", true)
    panel:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            FinishSetup()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    end)

end

-- Flash a label on the search frame (used for Currency hint)
function UI:FlashLabel(labelText)
    local searchFrame = UI:GetSearchFrame()
    if not searchFrame or not searchFrame.label then return end

    local label = searchFrame.label
    local originalText = label:GetText()
    local originalR, originalG, originalB = label:GetTextColor()

    label:SetText(labelText)
    label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])

    local flashCount = 0
    local ticker
    ticker = C_Timer.NewTicker(0.3, function()
        local ok = xpcall(function()
            flashCount = flashCount + 1
            if flashCount % 2 == 0 then
                label:SetTextColor(GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3])
            else
                label:SetTextColor(1, 1, 1)
            end
            if flashCount >= 6 then
                label:SetText(originalText)
                label:SetTextColor(originalR, originalG, originalB)
                ticker:Cancel()
            end
        end, ErrorHandler)
        if not ok then
            ticker:Cancel()
        end
    end)
end
