local _, ns = ...

-- A small themed popup of toggles beside a frame, in the filter menu's
-- own row conventions: checkbox rows (the shared checkbox textures on a
-- CheckButton), radio rows (the dropdown's radial bullet and tick on a
-- plain button), action rows, and separators. State never lives in the
-- popup: every row reads its value through `get` and writes through
-- `set`, so the popup shows the truth each time it opens. One popup
-- frame per `name`; check rows and plain rows are pooled separately so a
-- checkbox's textures can never bleed into a radio row.
--
--   ns.ShowTogglePopup("EasyFindSomePopup", anchorFrame, {
--       { kind = "check", label = "...", get = fn, set = fn(v) },
--       { kind = "radio", label = "...", value = v, get = fn, set = fn(v) },
--       { kind = "separator" },
--       { kind = "title", label = "..." },
--       { kind = "action", label = "...", onClick = fn },
--   }, { scale = 1, width = 180 })
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local ipairs = ipairs

local ROW_H = 22
local PAD = 6
local SEP_H = 9
local TITLE_H = 18
local CHECK_SIZE = 16

local popups = {}

local function EnsurePopup(name)
    local popup = popups[name]
    if popup then return popup end
    popup = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetFrameLevel(9500)
    popup:EnableMouse(true)
    ns.StyleMenuPanel(popup)
    popup.checkRows, popup.plainRows, popup.seps, popup.titles = {}, {}, {}, {}
    popup.live = {}
    -- Unconstrained measuring string: rows size the popup to the widest
    -- label, never to a guess.
    popup.measure = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    popup.measure:Hide()
    -- The search bar's and results' outside-click closers consult the
    -- shared guard registry; without this, a click on a row here would
    -- close the bar underneath.
    Utils.RegisterClickGuard(popup)
    popup:Hide()
    -- Escape closes the popup ahead of whatever is under it (the search
    -- bar registers earlier, so the popup is on top of the ESC stack).
    Utils.AttachEscClose(popup)
    popup:HookScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    popup:HookScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    -- Outside-click close in the menu convention: a press on the popup,
    -- on its anchor, or on a cursor menu is not "outside". The anchor's
    -- own CLICK toggles (ShowTogglePopup hides when already up for it);
    -- hiding on the anchor's press as well made the click reopen what the
    -- press had just closed, a flash. Anything that must close it for
    -- another reason (a drag starting on the anchor) calls HideTogglePopup.
    popup:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if Utils.IsFrameVisiblyMouseOver(self) then return end
        if self.anchor and Utils.IsFrameVisiblyMouseOver(self.anchor) then return end
        if Utils.IsCursorMenuMouseOver and Utils.IsCursorMenuMouseOver() then return end
        self:Hide()
    end)
    popups[name] = popup
    return popup
end

local function MakeCheckRow(popup)
    local row = CreateFrame("CheckButton", nil, popup)
    row:SetHeight(ROW_H)
    Utils.SetCheckboxTextures(row, CHECK_SIZE)
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row._label = row.label
    Utils.InstallMenuRowHighlight(row)
    row:SetScript("OnClick", function(self)
        local def = self.def
        if not def then return end
        local v = self:GetChecked() and true or false
        if def.set then def.set(v) end
        self:SetChecked(def.get and def.get() and true or false)
    end)
    return row
end

local function MakePlainRow(popup)
    local row = CreateFrame("Button", nil, popup)
    row:SetHeight(ROW_H)
    row.bullet = row:CreateTexture(nil, "ARTWORK")
    row.bullet:SetAtlas("common-dropdown-tickradial")
    row.bullet:SetSize(14, 14)
    row.bullet:SetPoint("LEFT", 4, 0)
    row.tick = row:CreateTexture(nil, "OVERLAY")
    row.tick:SetAtlas("common-dropdown-icon-radialtick-yellow")
    row.tick:SetSize(14, 14)
    row.tick:SetPoint("LEFT", 4, 0)
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row._label = row.label
    row._dimTex = { row.bullet, row.tick }
    Utils.InstallMenuRowHighlight(row)
    row:SetScript("OnClick", function(self)
        local def = self.def
        if not def then return end
        if def.kind == "radio" then
            if def.set then def.set(def.value) end
            ns.RefreshTogglePopup(popup)
        elseif def.kind == "action" then
            popup:Hide()
            if def.onClick then def.onClick() end
        end
    end)
    return row
end

-- Every open popup closes; true when one was. The search bar's own
-- Escape path asks this first while its edit box holds the key.
function ns.HideAllTogglePopups()
    local any = false
    for _, popup in pairs(popups) do
        if popup:IsShown() then
            popup:Hide()
            any = true
        end
    end
    return any
end

-- Close a named popup from outside (a drag starting on its anchor).
function ns.HideTogglePopup(name)
    local popup = popups[name]
    if popup and popup:IsShown() then popup:Hide() end
end

-- Repaint every live row from its `get`.
function ns.RefreshTogglePopup(popup)
    for _, row in ipairs(popup.live) do
        local def = row.def
        if def then
            if def.kind == "check" then
                row:SetChecked(def.get and def.get() and true or false)
            elseif def.kind == "radio" then
                row.tick:SetShown(def.get and def.get() == def.value)
            end
        end
    end
end

function ns.ShowTogglePopup(name, anchor, defs, opts)
    opts = opts or {}
    local popup = EnsurePopup(name)
    if popup:IsShown() and popup.anchor == anchor then
        popup:Hide()
        return
    end
    popup.anchor = anchor
    for _, r in ipairs(popup.checkRows) do r:Hide() end
    for _, r in ipairs(popup.plainRows) do r:Hide() end
    for _, s in ipairs(popup.seps) do s:Hide() end
    for _, t in ipairs(popup.titles) do t:Hide() end
    local live = popup.live
    for i = #live, 1, -1 do live[i] = nil end
    -- Width fits the widest label plus its check or bullet column; an
    -- opts.width is only ever a minimum.
    local widest = 0
    for _, def in ipairs(defs) do
        if def.kind ~= "separator" then
            popup.measure:SetText(def.label or "")
            widest = math.max(widest, popup.measure:GetStringWidth() or 0)
        end
    end
    local width = math.max(opts.width or 0, math.ceil(PAD * 2 + 4 + CHECK_SIZE + 6 + widest + 10))
    local y = -PAD
    local nCheck, nPlain, nSep, nTitle = 0, 0, 0, 0
    for _, def in ipairs(defs) do
        if def.kind == "separator" then
            nSep = nSep + 1
            local sep = popup.seps[nSep]
            if not sep then
                sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetHeight(1)
                sep:SetColorTexture(1, 1, 1, 0.12)
                popup.seps[nSep] = sep
            end
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 2, y - SEP_H / 2)
            sep:SetPoint("RIGHT", popup, "RIGHT", -PAD - 2, 0)
            sep:Show()
            y = y - SEP_H
        elseif def.kind == "title" then
            -- A heading over the rows below it, in the tooltip title color.
            nTitle = nTitle + 1
            local fs = popup.titles[nTitle]
            if not fs then
                fs = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
                fs:SetJustifyH("LEFT")
                fs._efOwnColor = true
                popup.titles[nTitle] = fs
            end
            fs:SetText(def.label or "")
            if ns.TooltipTextColor then fs:SetTextColor(ns.TooltipTextColor()) end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 8, y - 3)
            fs:Show()
            y = y - TITLE_H
        else
            local row
            if def.kind == "check" then
                nCheck = nCheck + 1
                row = popup.checkRows[nCheck]
                if not row then
                    row = MakeCheckRow(popup)
                    popup.checkRows[nCheck] = row
                end
                row:SetChecked(def.get and def.get() and true or false)
            else
                nPlain = nPlain + 1
                row = popup.plainRows[nPlain]
                if not row then
                    row = MakePlainRow(popup)
                    popup.plainRows[nPlain] = row
                end
                row.label:ClearAllPoints()
                row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
                if def.kind == "radio" then
                    row.bullet:Show()
                    row.tick:SetShown(def.get and def.get() == def.value)
                    row.label:SetPoint("LEFT", row.bullet, "RIGHT", 6, 0)
                else
                    row.bullet:Hide()
                    row.tick:Hide()
                    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                end
            end
            row.def = def
            row.label:SetText(def.label or "")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, y)
            row:SetPoint("RIGHT", popup, "RIGHT", -PAD, 0)
            row:Show()
            live[#live + 1] = row
            y = y - ROW_H
        end
    end
    popup:SetSize(width, -y + PAD)
    popup:SetScale(opts.scale or 1)
    Utils.RefreshMenuRowHighlights(popup, live)
    Utils.OpenFlyoutBeside(popup, anchor, 4)
    popup:Show()
    return popup
end
