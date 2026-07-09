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

-- Recipe-filter state. Blizzard's window filters are GLOBAL C_TradeSkillUI
-- state (one setter each, no skillLine argument), so ours is one shared table:
-- learned/unlearned/skillUp/materials plus the source-type mask. Expansion
-- page selection is per profession (expansion[skillLine] = child professionID).
local function RecipeFilterState()
    local db = EasyFind.db
    local state = db.professionRecipeFilters
    if not state or state.learned == nil then
        state = {
            learned = true, unlearned = true,
            skillUp = false, materials = false,
            sourceMask = 65535,
            expansion = {},
        }
        db.professionRecipeFilters = state
    end
    if not state.expansion then state.expansion = {} end
    return state
end

-- Two different gates: the C-side filter state is RETAINED after the window
-- closes (getters answer and setters persist any time they exist), so reads
-- and state writes only need the functions. Only the expansion page switch
-- (a menu-row click) needs the window actually live.
local function SettersExist()
    return C_TradeSkillUI ~= nil and C_TradeSkillUI.SetShowLearned ~= nil
end

local function ProfessionWindowLive()
    local pf = _G["ProfessionsFrame"]
    local live = pf and pf:IsShown() and pf.professionInfo
    return type(live) == "table" and live.professionID ~= nil and live.professionID ~= 0
end

-- Push our state onto the live window. The setters are load-on-demand: a
-- write with no window loaded is silently dropped, so it persists as a
-- pending push that outranks read-back and lands the moment the API exists
-- (the housing lost-update pattern; see easyfind-filter-menus skill).
local profPushArmed = false
local PushRecipeFilters
local ScanAndClickMenuRow, ClickWindowMenuRow

local function ArmProfessionPendingPush()
    if profPushArmed then return end
    profPushArmed = true
    local function tick()
        local db = EasyFind and EasyFind.db
        if not (db and db.professionFiltersPendingPush) then
            profPushArmed = false
            return
        end
        if ProfessionWindowLive() then
            profPushArmed = false
            PushRecipeFilters(RecipeFilterState())
            return
        end
        Utils.SafeAfter(1, tick)
    end
    Utils.SafeAfter(1, tick)
end

PushRecipeFilters = function(state)
    local db = EasyFind.db
    if not SettersExist() then
        db.professionFiltersPendingPush = true
        ArmProfessionPendingPush()
        return false
    end
    local ts = C_TradeSkillUI
    pcall(ts.SetShowLearned, state.learned ~= false)
    if ts.SetShowUnlearned then pcall(ts.SetShowUnlearned, state.unlearned ~= false) end
    if ts.SetOnlyShowSkillUpRecipes then pcall(ts.SetOnlyShowSkillUpRecipes, state.skillUp == true) end
    if ts.SetOnlyShowMakeableRecipes then pcall(ts.SetOnlyShowMakeableRecipes, state.materials == true) end
    if ts.SetSourceTypeFilter then pcall(ts.SetSourceTypeFilter, state.sourceMask or 65535) end
    if not ProfessionWindowLive() and next(state.expansion or {}) then
        -- State writes persisted, but an expansion page choice can only land
        -- on a live window; stay pending so the watcher applies it on open.
        db.professionFiltersPendingPush = true
        ArmProfessionPendingPush()
        return true
    end
    db.professionFiltersPendingPush = false
    -- Expansion page choice made while no window existed: apply it now via
    -- the window's own menu row (delayed so the freshly opened frame has its
    -- professionInfo and menu built).
    Utils.SafeAfter(0.3, function()
        local pf = _G["ProfessionsFrame"]
        local live = pf and pf:IsShown() and pf.professionInfo
        if type(live) ~= "table" or not live.parentProfessionID then return end
        local wanted = state.expansion and state.expansion[live.parentProfessionID]
        if not wanted or wanted == live.professionID then return end
        local profData = ns.PROFESSION_RECIPES and ns.PROFESSION_RECIPES[live.parentProfessionID]
        local children = profData and profData.children
        if not children then return end
        for i = 1, #children do
            if children[i].professionID == wanted then
                local page = pf.CraftingPage
                local expBtn = page and page.RankBar and page.RankBar.ExpansionDropdownButton
                if expBtn then ClickWindowMenuRow(expBtn, children[i].name) end
                return
            end
        end
    end)
    return true
end

local function PullRecipeFilters(state)
    local db = EasyFind.db
    if db.professionFiltersPendingPush then
        -- An unpushed menu change is the newest intent; push it instead of
        -- reading Blizzard's stale state back over it.
        PushRecipeFilters(state)
        return
    end
    if not (C_TradeSkillUI and C_TradeSkillUI.GetShowLearned) then return end
    local ts = C_TradeSkillUI
    local getters = {
        { fn = ts.GetShowLearned, key = "learned" },
        { fn = ts.GetShowUnlearned, key = "unlearned" },
        { fn = ts.GetOnlyShowSkillUpRecipes, key = "skillUp" },
        { fn = ts.GetOnlyShowMakeableRecipes, key = "materials" },
    }
    for i = 1, #getters do
        local getter = getters[i]
        if getter.fn then
            local ok, v = pcall(getter.fn)
            if ok and v ~= nil then state[getter.key] = v and true or false end
        end
    end
    if ts.GetSourceTypeFilter then
        local ok, v = pcall(ts.GetSourceTypeFilter)
        if ok and type(v) == "number" then state.sourceMask = v end
    end
end

-- Cross-session arming: a pending push saved last session must land even if
-- the user opens a profession window before ever touching EasyFind.
function Filters:ArmProfessionPendingPushIfNeeded()
    local db = EasyFind and EasyFind.db
    if not db then return end
    if db.professionFiltersPendingPush then
        ArmProfessionPendingPush()
        return
    end
    -- Login reconciliation: our saved state and Blizzard's retained filter
    -- state are separate persistent stores and can diverge across sessions.
    -- With no unlanded intent of ours, Blizzard's is what the window will
    -- show, so adopt it once and both start identical.
    Utils.SafeAfter(1, function()
        if EasyFind.db and not EasyFind.db.professionFiltersPendingPush then
            PullRecipeFilters(RecipeFilterState())
        end
    end)
end

-- Click a row inside a window dropdown's own menu by its text: OpenMenu,
-- find the hex-strata menu row (plain insecure Button), Click() -- Blizzard's
-- handler end to end. The API switchers are dead (OpenTradeSkill returns
-- false; the info getters return empty structs), so the real menu row is the
-- verified write path for the expansion page.
ScanAndClickMenuRow = function(wantText)
    local clicked = false
    local frame = EnumerateFrames()
    while frame and not clicked do
        local okV, vis = pcall(frame.IsVisible, frame)
        if okV and vis then
            local okS, strata = pcall(frame.GetFrameStrata, frame)
            if okS and strata == "FULLSCREEN_DIALOG" then
                local okK, kids = pcall(function() return { frame:GetChildren() } end)
                if okK then
                    for i = 1, #kids do
                        local kid = kids[i]
                        local okB, isBtn = pcall(function() return kid:GetObjectType() == "Button" end)
                        if okB and isBtn then
                            local okR, regs = pcall(function() return { kid:GetRegions() } end)
                            if okR then
                                for r = 1, #regs do
                                    local reg = regs[r]
                                    local okT, txt = pcall(function()
                                        return reg:GetObjectType() == "FontString" and reg:GetText()
                                    end)
                                    if okT and txt == wantText then
                                        pcall(kid.Click, kid)
                                        clicked = true
                                        break
                                    end
                                end
                            end
                        end
                        if clicked then break end
                    end
                end
            end
        end
        frame = EnumerateFrames(frame)
    end
    return clicked
end

-- OpenMenu's rows may not exist until the next frame; scan deferred, retry
-- once, and only close the menu when the click never landed (a landed radio
-- click closes it itself).
ClickWindowMenuRow = function(dropdownBtn, wantText)
    if not (dropdownBtn and type(dropdownBtn.OpenMenu) == "function") then return end
    pcall(dropdownBtn.OpenMenu, dropdownBtn)
    Utils.SafeAfter(0.05, function()
        if ScanAndClickMenuRow(wantText) then return end
        Utils.SafeAfter(0.15, function()
            if not ScanAndClickMenuRow(wantText)
               and type(dropdownBtn.CloseMenu) == "function" then
                pcall(dropdownBtn.CloseMenu, dropdownBtn)
            end
        end)
    end)
end

local attachCtx
local childPopups = {}
local function HideOtherSubmenus(except)
    for i = 1, #childPopups do
        local child = childPopups[i]
        if child ~= except and child._efParentPopup ~= except then child:Hide() end
    end
end
local function AttachRecipeFilterFlyout(row)
    local ctx = attachCtx
    if not ctx then return end
    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetFrameLevel(row:GetFrameLevel() + 10)
    ctx.StylePopup(popup)
    popup:EnableMouse(true)
    popup:Hide()
    ctx.dropdownGuardFrames[#ctx.dropdownGuardFrames + 1] = popup
    childPopups[#childPopups + 1] = popup
    Filters.AttachOutsideClickClose(popup)
    row._submenuPopup = popup

    local ROW_H = ctx.rowHeight
    local CHECK = ctx.checkSize
    local PAD = 8
    local defs = {
        { key = "learned" },
        { key = "unlearned" },
        { key = "skillUp" },
        { key = "materials" },
    }
    local checkRows = {}
    local y = -PAD
    for i = 1, #defs do
        local cr = CreateFrame("CheckButton", nil, popup)
        cr:SetSize(150, ROW_H)
        cr:SetHitRectInsets(0, 0, 0, 0)
        Utils.SetCheckboxTextures(cr, CHECK)
        local fs = cr:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetPoint("LEFT", cr:GetNormalTexture(), "RIGHT", 4, 0)
        cr._label = fs
        cr:SetPoint("TOPLEFT", PAD, y)
        Utils.InstallMenuRowHighlight(cr)
        cr._key = defs[i].key
        cr:SetScript("OnClick", function(self)
            local state = RecipeFilterState()
            state[self._key] = self:GetChecked() and true or false
            PushRecipeFilters(state)
        end)
        checkRows[i] = cr
        y = y - ROW_H
    end

    local sep = popup:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.12)
    sep:SetHeight(1)

    -- Sources: its own nested flyout of expansion-page radios (third level),
    -- mirroring the window menu's Sources submenu.
    local sourcesPopup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    sourcesPopup:SetFrameStrata("TOOLTIP")
    sourcesPopup:SetFrameLevel(popup:GetFrameLevel() + 10)
    ctx.StylePopup(sourcesPopup)
    sourcesPopup:EnableMouse(true)
    sourcesPopup:Hide()
    ctx.dropdownGuardFrames[#ctx.dropdownGuardFrames + 1] = sourcesPopup
    childPopups[#childPopups + 1] = sourcesPopup
    Filters.AttachOutsideClickClose(sourcesPopup)
    sourcesPopup._efParentPopup = popup
    popup:HookScript("OnHide", function() sourcesPopup:Hide() end)

    local sourcesOpener = CreateFrame("Button", nil, popup)
    sourcesOpener:SetSize(150, ROW_H)
    sourcesOpener:SetHitRectInsets(0, 0, 0, 0)
    local soLabel = sourcesOpener:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    soLabel:SetPoint("LEFT", 6, 0)
    sourcesOpener._label = soLabel
    local soChev = sourcesOpener:CreateTexture(nil, "OVERLAY")
    soChev:SetAtlas("common-icon-forwardarrow")
    soChev:SetSize(CHECK - 2, CHECK - 2)
    soChev:SetPoint("RIGHT", -4, 0)
    soChev:SetVertexColor(0.85, 0.85, 0.85, 1)
    Utils.InstallMenuRowHighlight(sourcesOpener)

    -- Source types (the Sources submenu): checkboxes over the
    -- GetSourceTypeFilter bitmask (65535 = all on, crawl-verified baseline).
    -- Bit order pending the one-toggle verification; labels use the standard
    -- source GlobalStrings with English fallbacks.
    -- Bits measured live: single toggles gave Drop=1, Quest=2; Blizzard's
    -- Uncheck All left mask 64500 (65535-1035), so the visible rows are
    -- bits 1, 2, 8, 1024 in menu order -- bit 4 (and the other gaps) belong
    -- to hidden source types this menu does not show, and must never be
    -- touched by our Check All/Uncheck All.
    local SOURCE_ROWS = {
        { bit = 1,    label = function() return _G["BATTLE_PET_SOURCE_1"] or "Drop" end },
        { bit = 2,    label = function() return _G["BATTLE_PET_SOURCE_2"] or "Quest" end },
        { bit = 8,    label = function() return _G["BATTLE_PET_SOURCE_4"] or "Profession" end },
        { bit = 1024, label = function() return _G["DISCOVERY"] or "Discovery" end },
    }
    local VISIBLE_SOURCE_MASK = 0
    for i = 1, #SOURCE_ROWS do
        VISIBLE_SOURCE_MASK = VISIBLE_SOURCE_MASK + SOURCE_ROWS[i].bit
    end
    local band = bit.band
    local bor = bit.bor
    local function GetSourceMask()
        local state = RecipeFilterState()
        if SettersExist() and not EasyFind.db.professionFiltersPendingPush then
            local ok, v = pcall(C_TradeSkillUI.GetSourceTypeFilter)
            if ok and type(v) == "number" then
                state.sourceMask = v
                return v
            end
        end
        return state.sourceMask or 65535
    end
    local function SetSourceMask(mask)
        local state = RecipeFilterState()
        state.sourceMask = mask
        PushRecipeFilters(state)
    end

    local sourceChecks = {}
    local sourceActions = {}
    local function GetSourceAction(i)
        local r = sourceActions[i]
        if not r then
            r = CreateFrame("Button", nil, sourcesPopup)
            r:SetSize(150, ROW_H)
            r:SetHitRectInsets(0, 0, 0, 0)
            local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            fs:SetPoint("LEFT", 6, 0)
            r._label = fs
            Utils.InstallMenuRowHighlight(r)
            sourceActions[i] = r
        end
        return r
    end
    local function GetSourceCheck(i)
        local r = sourceChecks[i]
        if not r then
            r = CreateFrame("CheckButton", nil, sourcesPopup)
            r:SetSize(150, ROW_H)
            r:SetHitRectInsets(0, 0, 0, 0)
            Utils.SetCheckboxTextures(r, CHECK)
            local fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            fs:SetPoint("LEFT", r:GetNormalTexture(), "RIGHT", 4, 0)
            r._label = fs
            Utils.InstallMenuRowHighlight(r)
            r:SetScript("OnClick", function(self)
                local mask = GetSourceMask()
                if self:GetChecked() then
                    mask = bor(mask, self._bit)
                else
                    mask = mask - band(mask, self._bit)
                end
                SetSourceMask(mask)
            end)
            sourceChecks[i] = r
        end
        return r
    end

    local function LayoutSources()
        local y, contentW = -PAD, 0
        local actions = {
            { label = _G["CHECK_ALL"] or "Check All",
              run = function() SetSourceMask(bor(GetSourceMask(), VISIBLE_SOURCE_MASK)) end },
            { label = _G["UNCHECK_ALL"] or "Uncheck All",
              run = function()
                  local mask = GetSourceMask()
                  SetSourceMask(mask - band(mask, VISIBLE_SOURCE_MASK))
              end },
        }
        for i = 1, #actions do
            local r = GetSourceAction(i)
            r._label:SetText(actions[i].label)
            r:SetScript("OnClick", function()
                actions[i].run()
                local mask = GetSourceMask()
                for ci = 1, #SOURCE_ROWS do
                    if sourceChecks[ci] then
                        sourceChecks[ci]:SetChecked(band(mask, SOURCE_ROWS[ci].bit) ~= 0)
                    end
                end
            end)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", PAD, y)
            r:Show()
            y = y - ROW_H
            local w = Utils.FlyoutRowContentWidth(r, 8)
            if w > contentW then contentW = w end
        end
        local mask = GetSourceMask()
        for i = 1, #SOURCE_ROWS do
            local def = SOURCE_ROWS[i]
            local r = GetSourceCheck(i)
            r._bit = def.bit
            r._label:SetText(def.label())
            r:SetChecked(band(mask, def.bit) ~= 0)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", PAD, y)
            r:Show()
            y = y - ROW_H
            local w = Utils.FlyoutRowContentWidth(r, CHECK + 4)
            if w > contentW then contentW = w end
        end
        local w = Utils.FlyoutWidthFor(contentW, PAD)
        for i = 1, #sourceActions do sourceActions[i]:SetWidth(w - PAD * 2) end
        for i = 1, #SOURCE_ROWS do sourceChecks[i]:SetWidth(w - PAD * 2) end
        sourcesPopup:SetSize(w, -y + PAD)
    end

    local sourcesHover = Utils.AttachHoverPopup(sourcesOpener, sourcesPopup, {
        onShow = function()
            LayoutSources()
            sourcesPopup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenFlyoutBeside(sourcesPopup, sourcesOpener, 4)
            sourcesPopup:Show()
        end,
    })
    sourcesOpener.ShowFlyoutPopup = sourcesHover.Show
    ctx.AddPopupKeyboardNav(sourcesPopup, function()
        local rows = {}
        for i = 1, #sourceActions do if sourceActions[i]:IsShown() then rows[#rows + 1] = sourceActions[i] end end
        for i = 1, #sourceChecks do if sourceChecks[i]:IsShown() then rows[#rows + 1] = sourceChecks[i] end end
        return rows
    end, popup)

    local radioRows = {}
    local function GetRadioRow(i)
        local rr = radioRows[i]
        if not rr then
            rr = CreateFrame("Button", nil, popup)
            rr:SetSize(150, ROW_H)
            rr:SetHitRectInsets(0, 0, 0, 0)
            local tex, setChecked = ctx.CreateRadioTexture(rr)
            tex:SetPoint("LEFT", 2, 0)
            rr._setChecked = setChecked
            local fs = rr:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            fs:SetPoint("LEFT", tex, "RIGHT", 6, 0)
            rr._label = fs
            Utils.InstallMenuRowHighlight(rr)
            rr:SetScript("OnClick", function(self)
                local state = RecipeFilterState()
                state.expansion[row._skillLine] = self._professionID
                local pf = _G["ProfessionsFrame"]
                local page = pf and pf.CraftingPage
                local expBtn = page and page.RankBar and page.RankBar.ExpansionDropdownButton
                if pf and pf:IsShown() and expBtn then
                    ClickWindowMenuRow(expBtn, self._label:GetText())
                else
                    EasyFind.db.professionFiltersPendingPush = true
                    ArmProfessionPendingPush()
                end
                for ri = 1, #radioRows do
                    radioRows[ri]._setChecked(radioRows[ri]._professionID == self._professionID)
                end
            end)
            radioRows[i] = rr
        end
        return rr
    end

    local SEP_H = 8
    local function Layout()
        -- Label keys pending the /efd locale pass; English fallbacks match the
        -- window's own captured menu rows.
        checkRows[1]._label:SetText(_G["PROFESSIONS_FILTER_LEARNED"] or "Show Learned")
        checkRows[2]._label:SetText(_G["PROFESSIONS_FILTER_UNLEARNED"] or "Show Unlearned")
        checkRows[3]._label:SetText(_G["PROFESSIONS_FILTER_HAS_SKILL_UP"] or "Has skill up")
        checkRows[4]._label:SetText(_G["PROFESSIONS_FILTER_HAS_MATERIALS"] or "Have Materials")
        local state = RecipeFilterState()
        PullRecipeFilters(state)
        checkRows[1]:SetChecked(state.learned ~= false)
        checkRows[2]:SetChecked(state.unlearned ~= false)
        checkRows[3]:SetChecked(state.skillUp == true)
        checkRows[4]:SetChecked(state.materials == true)
        local contentW = 0
        for i = 1, #checkRows do
            local w = Utils.FlyoutRowContentWidth(checkRows[i], CHECK + 4)
            if w > contentW then contentW = w end
        end
        local profData = ns.PROFESSION_RECIPES and ns.PROFESSION_RECIPES[row._skillLine]
        local hasChildren = profData and profData.children and #profData.children > 0
        local y = -PAD - ROW_H * #checkRows
        if hasChildren then
            sep:ClearAllPoints()
            sep:SetPoint("LEFT", popup, "LEFT", PAD, 0)
            sep:SetPoint("RIGHT", popup, "RIGHT", -PAD, 0)
            sep:SetPoint("TOP", popup, "TOP", 0, y - SEP_H * 0.5)
            sep:Show()
            y = y - SEP_H
            soLabel:SetText(_G["SOURCES"] or "Sources")
            sourcesOpener:ClearAllPoints()
            sourcesOpener:SetPoint("TOPLEFT", PAD, y)
            sourcesOpener:Show()
            y = y - ROW_H
            local w2 = Utils.FlyoutRowContentWidth(sourcesOpener, 8, nil, CHECK - 2)
            if w2 > contentW then contentW = w2 end
            -- Expansion pages: inline radios below Sources (Blizzard's layout).
            local children = profData.children
            local state2 = RecipeFilterState()
            local current = state2.expansion[row._skillLine]
            -- The no-arg GetChildProfessionInfo returns an empty struct even
            -- with the window open (live-verified: professionID 0); the real
            -- current page lives on ProfessionsFrame.professionInfo.
            local pf = _G["ProfessionsFrame"]
            local live = pf and pf.professionInfo
            if type(live) == "table" and live.professionID and live.professionID ~= 0
               and live.parentProfessionID == row._skillLine then
                current = live.professionID
            end
            current = current or children[1].professionID
            for i = 1, #children do
                local child = children[i]
                local rr = GetRadioRow(i)
                rr._professionID = child.professionID
                rr._label:SetText(child.name)
                rr._setChecked(child.professionID == current)
                rr:ClearAllPoints()
                rr:SetPoint("TOPLEFT", PAD, y)
                rr:Show()
                y = y - ROW_H
                local w3 = Utils.FlyoutRowContentWidth(rr, 22)
                if w3 > contentW then contentW = w3 end
            end
            for i = #children + 1, #radioRows do radioRows[i]:Hide() end
        else
            sep:Hide()
            sourcesOpener:Hide()
            for i = 1, #radioRows do radioRows[i]:Hide() end
        end
        local w = Utils.FlyoutWidthFor(contentW, PAD)
        for i = 1, #checkRows do checkRows[i]:SetWidth(w - PAD * 2) end
        if hasChildren then
            sourcesOpener:SetWidth(w - PAD * 2)
            for i = 1, #radioRows do
                if radioRows[i]:IsShown() then radioRows[i]:SetWidth(w - PAD * 2) end
            end
        end
        popup:SetSize(w, -y + PAD)
    end

    local hover = Utils.AttachHoverPopup(row, popup, {
        extraGuards = { sourcesPopup },
        onShow = function()
            HideOtherSubmenus(popup)
            Layout()
            popup:SetScale(EasyFind.db.uiSearchScale or 1.0)
            Utils.OpenFlyoutBeside(popup, row, 4)
            popup:Show()
        end,
    })
    row.ShowFlyoutPopup = hover.Show
    row:HookScript("OnEnter", function(self) HideOtherSubmenus(self._submenuPopup) end)
    ctx.AddPopupKeyboardNav(popup, function()
        local rows = {}
        for i = 1, #checkRows do rows[#rows + 1] = checkRows[i] end
        if sourcesOpener:IsShown() then rows[#rows + 1] = sourcesOpener end
        for i = 1, #radioRows do if radioRows[i]:IsShown() then rows[#rows + 1] = radioRows[i] end end
        return rows
    end, row:GetParent())
end

-- Side flyout on the Professions filter row: one checkbox per known
-- profession. Unchecking removes that profession's entries at the provider
-- (db.professionFilters[skillLine] = false; missing = on).
function Filters:AttachProfessionOptionsFlyout(row, dropdown, ctx)
    attachCtx = ctx
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
            local chev = r:CreateTexture(nil, "OVERLAY")
            chev:SetAtlas("common-icon-forwardarrow")
            chev:SetSize(CHECK - 2, CHECK - 2)
            chev:SetPoint("RIGHT", -4, 0)
            chev:SetVertexColor(0.85, 0.85, 0.85, 1)
            r._chev = chev
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
            AttachRecipeFilterFlyout(r)
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
            r._chev:SetShown(ns.PROFESSION_RECIPES and ns.PROFESSION_RECIPES[prof.skillLine] ~= nil)
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
        extraGuards = childPopups,
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
    root:HookScript("OnHide", function() HideOtherSubmenus(nil) end)
    Filters.AttachOutsideClickClose(root, {
        onHide = function(self)
            HideOtherSubmenus(nil)
            ctx.ClearActiveFlyout(self)
        end,
    })
    dropdown:HookScript("OnHide", function() root:Hide() end)
end
