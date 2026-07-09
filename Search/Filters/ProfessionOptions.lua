local _, ns = ...

local Filters = ns.Filters
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local GetProfessions = GetProfessions
local GetProfessionInfo = GetProfessionInfo

-- Known professions as {skillLine, name, icon}, rebuilt per open so the
-- flyout tracks learning/unlearning without a reload.
local function KnownProfessions()
    local out = {}
    if not (GetProfessions and GetProfessionInfo) then return out end
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    local profIndexes = { prof1, prof2, archaeology, fishing, cooking }
    for i = 1, 5 do
        local profIndex = profIndexes[i]
        if profIndex then
            local profName, profIcon, _, _, _, _, skillLine = GetProfessionInfo(profIndex)
            if profName and profName ~= "" and skillLine then
                out[#out + 1] = { skillLine = skillLine, name = profName, icon = profIcon }
            end
        end
    end
    return out
end

-- Side flyout on the Professions filter row: one checkbox per known
-- profession. Unchecking removes that profession's entries at the provider
-- (db.professionFilters[skillLine] = false; missing = on).
function Filters:AttachProfessionOptionsFlyout(row, dropdown, ctx)
    local ROW_H = ctx.rowHeight
    local CHECK = ctx.checkSize
    local PAD = 8

    local root = CreateFrame("Frame", "EasyFindProfessionOptionsPopup", UIParent, "BackdropTemplate")
    root:SetFrameStrata("TOOLTIP")
    ctx.StylePopup(root)
    root:EnableMouse(true)
    root:Hide()
    ctx.dropdownGuardFrames[#ctx.dropdownGuardFrames + 1] = root

    local pool = {}
    local function GetRow(i)
        local r = pool[i]
        if not r then
            r = CreateFrame("CheckButton", nil, root)
            r:SetSize(150, ROW_H)
            r:SetHitRectInsets(0, 0, 0, 0)
            Utils.SetCheckboxTextures(r, CHECK)
            local icon = r:CreateTexture(nil, "ARTWORK")
            icon:SetSize(CHECK, CHECK)
            icon:SetPoint("LEFT", r:GetNormalTexture(), "RIGHT", 4, 0)
            r._icon = icon
            local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            fs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
            r._label = fs
            Utils.InstallMenuRowHighlight(r)
            r:SetScript("OnClick", function(self)
                local t = EasyFind.db.professionFilters
                if not t then t = {}; EasyFind.db.professionFilters = t end
                t[self._skillLine] = self:GetChecked() and nil or false
                if ns.Database and ns.Database.RefreshDynamicCategory then
                    ns.Database:RefreshDynamicCategory("professions")
                end
                Filters:ApplyFilterSelection("professions")
            end)
            pool[i] = r
        end
        return r
    end

    local function Layout()
        local profs = KnownProfessions()
        local y, contentW = -PAD, 0
        for i = 1, #profs do
            local prof = profs[i]
            local r = GetRow(i)
            r._skillLine = prof.skillLine
            r._label:SetText(prof.name)
            r._icon:SetTexture(prof.icon)
            local t = EasyFind.db.professionFilters
            r:SetChecked(not (t and t[prof.skillLine] == false))
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", PAD, y)
            r:Show()
            y = y - ROW_H
            local w = Utils.FlyoutRowContentWidth(r, CHECK * 2 + 8)
            if w > contentW then contentW = w end
        end
        for i = #profs + 1, #pool do pool[i]:Hide() end
        local w = Utils.FlyoutWidthFor(contentW, PAD)
        for i = 1, #profs do pool[i]:SetWidth(w - PAD * 2) end
        root:SetSize(w, -y + PAD)
    end
    root._efSync = Layout

    local hover = Utils.AttachHoverPopup(row, root, {
        onShow = function()
            ctx.SetActiveFlyout(root)
            Layout()
            root:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenFlyoutBeside(root, row, 4)
            root:Show()
        end,
    })
    row.ShowFlyoutPopup = hover.Show

    ctx.AddPopupKeyboardNav(root, function()
        local rows = {}
        for i = 1, #pool do if pool[i]:IsShown() then rows[#rows + 1] = pool[i] end end
        return rows
    end)
    Filters.AttachOutsideClickClose(root, {
        onHide = function(self) ctx.ClearActiveFlyout(self) end,
    })
    dropdown:HookScript("OnHide", function() root:Hide() end)
end
