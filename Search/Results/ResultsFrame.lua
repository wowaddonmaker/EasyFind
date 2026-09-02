local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Render = ns.ResultRender
local Shortcuts = ns.ResultShortcuts
local OptionsSurface = ns.OptionsSurface
local Utils = ns.Utils
local L = ns.L

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local mfloor = Utils.mfloor

local GOLD_COLOR = ns.GOLD_COLOR
local RESULT_SHORTCUT = Shortcuts.RESULT_SHORTCUT
local resultsFrame
local resultShortcutFrame

function Results:EnsureResultButton(index)
    local row = Search:GetResultButtons()[index]
    if not row then
        row = Rows:CreateResultButton(index)
        Search:GetResultButtons()[index] = row
    end
    return row
end

-- Re-render the cached result list into the open results panel. Returns true
-- when a render happened (panel shown with cached results), false otherwise.
-- bypassRenderCache defeats the render-skip signature so layout-only changes
-- (checkbox toggles, slider writes) repaint instead of being skipped.
function Results:RefreshShownResults(bypassRenderCache)
    local frame = Search:GetResultsFrame()
    if not (Results._cachedHierarchical and frame and frame:IsShown()) then return false end
    if bypassRenderCache then
        -- false, not nil: removing the key would let the shared module
        -- __index resolve the read against another module's still-matching
        -- signature and skip the repaint anyway.
        self._lastRenderSig = false
    end
    self:ShowHierarchicalResults(Results._cachedHierarchical, true)
    return true
end

function Results:CreateResultsFrame()
    resultsFrame = CreateFrame("Frame", "EasyFindResultsFrame", Search:GetSearchFrame(), "BackdropTemplate")
    Search:SetResultsFrame(resultsFrame)
    resultsFrame:SetWidth(380)  -- Wide to accommodate tree indentation
    resultsFrame:SetPoint("TOP", Search:GetSearchFrame(), "BOTTOM", 0, 2)
    resultsFrame:SetFrameStrata("LOW")
    resultsFrame:SetFrameLevel(Search:GetSearchFrame():GetFrameLevel() + 1)
    -- NOTE: stack-strata updates live inside the SetScript("OnShow"/
    -- "OnHide") handlers below; HookScripts added here would be wiped by
    -- those SetScript calls (the silent hook-eater class).

    resultsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 20,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })

    local theme = Results:GetActiveTheme()
    local bgAtlasTex = resultsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
    bgAtlasTex:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 4, -4)
    bgAtlasTex:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -4, 4)
    if theme.resultsBgAtlas then
        bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
    end
    bgAtlasTex:Hide()
    resultsFrame.bgAtlasTex = bgAtlasTex

    -- The peer-heard update notice: one line along the bottom of the results
    -- window, which grows by exactly this row when the notice is up.
    local updateFooter = resultsFrame:CreateFontString(nil, "OVERLAY", ns.SEARCHBAR_FONT)
    updateFooter:SetJustifyH("LEFT")
    updateFooter:SetWordWrap(false)
    updateFooter:Hide()
    resultsFrame.updateFooter = updateFooter

    -- Hover region over the notice. There is deliberately NO inline off
    -- switch: a one-click permanent opt-out beside the line it silences
    -- costs future reminders, so the only switch is in Options and the
    -- tooltip says where. Living INSIDE the results frame, the region is
    -- covered by the outside-click closer's own IsMouseOver check.
    local footerHover = CreateFrame("Frame", nil, resultsFrame)
    footerHover:EnableMouse(true)
    footerHover:Hide()
    footerHover:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- A narrow window or long translation truncates the footer line;
        -- the full message stays reachable here.
        if updateFooter.efTruncated then
            GameTooltip:AddLine(updateFooter:GetText() or "", GOLD_COLOR[1], GOLD_COLOR[2], GOLD_COLOR[3], true)
        end
        GameTooltip:AddLine(L["UPDATE_NOTIFY_FOOTER_TT"]:format(L["OPT_TAB_GENERAL_BINDS"]),
            nil, nil, nil, true)
        GameTooltip:Show()
    end)
    footerHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    resultsFrame.updateFooterHover = footerHover

    resultsFrame:Hide()

    -- Click-outside-to-close: hides the results frame on any click that
    -- isn't on the search bar, results frame, or one of its associated
    -- popups (filter dropdown, pin/right-click menu, gear/collections
    -- option popups). Hover-out doesn't close: that's too sensitive.
    resultsFrame:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        Search:UpdateStackStrata()
    end)
    resultsFrame:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        Search:UpdateStackStrata()
        -- Closing the list while an unearned row is hovered fires no
        -- OnLeave on that row, stranding its tooltip.
        local unearned = ns.ResultTooltips and ns.ResultTooltips:GetUnearnedTooltip()
        if unearned then unearned:Hide() end
    end)
    resultsFrame:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if self:IsMouseOver() then return end
        if Search:GetSearchFrame() and Search:GetSearchFrame():IsMouseOver() then return end
        if OptionsSurface:IsOptionsSurfaceMouseOver() then return end
        -- Any active cursor menu and its flyout cascade (pin/right-click menu,
        -- the Send-link channel submenu) count as inside: those submenus are
        -- separate pooled frames, not children of the pin popup.
        if Utils.IsCursorMenuMouseOver() then return end
        -- Every floating EasyFind window (copy box, pin popup, calculator,
        -- StaticPopup slots, ...) lives in the shared click-guard registry.
        if Utils.IsClickGuardMouseOver() then return end
        -- The filter dropdown and every popup it spawns; IsMouseInFilterChain
        -- owns that union via dropdown.guardFrames.
        if ns.Filters and ns.Filters.IsMouseInFilterChain() then return end
        Results:RequestHideResults()
    end)

    local resizeTimer
    resultsFrame:SetScript("OnSizeChanged", function()
        if not resultsFrame:IsShown() or not Results._cachedHierarchical then return end  -- luacheck: ignore 113
        -- The icon grid owns the panel; re-rendering cached rows here would
        -- tear it down 0.02s after it opened.
        if Results.IsIconGridShown and Results:IsIconGridShown() then return end
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.02, function()
            resizeTimer = nil
            Render:ShowHierarchicalResults(Results._cachedHierarchical, true)  -- luacheck: ignore 113
        end)
    end)

    -- Plain ScrollFrame for clipping. Wheel handler is wired up by
    -- CreateMinimalScrollBar so wheel events route through the eased path.
    local scrollFrame = CreateFrame("ScrollFrame", nil, resultsFrame)
    resultsFrame.scrollFrame = scrollFrame

    local quickFilterHelp = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickFilterHelp:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 12, -8)
    quickFilterHelp:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -12, -8)
    quickFilterHelp:SetJustifyH("LEFT")
    quickFilterHelp:SetTextColor(0.78, 0.78, 0.80, 1)
    quickFilterHelp:SetText(L["QUICK_FILTER_HELP"])
    quickFilterHelp:Hide()
    resultsFrame.quickFilterHelp = quickFilterHelp

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    resultsFrame.scrollChild = scrollChild

    -- Minimal retail-style scrollbar (overlays right edge, no content squish)
    resultsFrame.scrollBar = ns.Utils.CreateMinimalScrollBar(scrollFrame, resultsFrame)
    -- Shortcut badges change only when the visible ROW SET changes, but the
    -- eased scroll fires OnVerticalScroll every frame at sub-pixel steps;
    -- recomputing per fire was most of the scroll-spam CPU. 12px buckets:
    -- comfortably under the shortest row height, so no boundary crossing
    -- can be missed, while a lerp frame moves nothing.
    local lastShortcutBucket
    scrollFrame:HookScript("OnVerticalScroll", function(_, offset)
        local bucket = mfloor((offset or 0) / 12)
        if bucket ~= lastShortcutBucket then
            lastShortcutBucket = bucket
            Shortcuts:UpdateVisibleResultShortcuts()
        end
    end)

    -- Is the results list mid-scroll (eased glide in flight, or wheel/drag
    -- activity in the last quarter second)? Deferred repaints (the item
    -- catalog's name-refresh) hold off while this is true so they never
    -- rebuild the list under an active scroll.
    function Results:IsResultsScrollBusy()
        local bar = resultsFrame and resultsFrame.scrollBar
        if not bar then return false end
        if bar._scrollTarget then return true end
        return (GetTime() - (bar._lastActivity or 0)) < 0.25
    end

    -- Override-binding owners are SECURE show/hide handlers parented to the
    -- results frame: the _onhide snippet clears their bindings in secure
    -- execution no matter what hid the dropdown (user close, the combat-
    -- entry hide), so the binding system's LAST write at any hide boundary
    -- is never EasyFind-tainted. Insecure clears at combat entry left the
    -- binding state tainted and detonated protected pet-bar updates
    -- (PetActionBar:SetShownBase autopsy, 2026-07-10).
    local shortcutBindOwner = CreateFrame("Frame", nil, resultsFrame, "SecureHandlerShowHideTemplate")
    shortcutBindOwner:SetAttribute("_onhide", "self:ClearBindings()")
    shortcutBindOwner:HookScript("OnHide", function()
        Shortcuts:NoteShortcutBindingsCleared()
    end)
    Shortcuts._shortcutBindOwner = shortcutBindOwner

    local navBindOwner = CreateFrame("Frame", nil, resultsFrame, "SecureHandlerShowHideTemplate")
    navBindOwner:SetAttribute("_onhide", "self:ClearBindings()")
    navBindOwner:HookScript("OnHide", function()
        if Results.NoteNavBindingCleared then Results:NoteNavBindingCleared() end
    end)
    Results._navBindOwner = navBindOwner

    resultShortcutFrame = CreateFrame("Frame", nil, Search:GetSearchFrame())
    Shortcuts._resultShortcutFrame = resultShortcutFrame
    resultShortcutFrame.shortcutButtons = {}
    for i = 1, RESULT_SHORTCUT.max do
        local proxy = CreateFrame("Button", "EasyFindResultShortcutButton" .. i, resultShortcutFrame)
        proxy._shortcutIndex = i
        proxy:SetScript("OnClick", function(self)
            Shortcuts:ActivateVisibleResultShortcut(self._shortcutIndex)
        end)
        resultShortcutFrame.shortcutButtons[i] = proxy
    end

    local pinSeparator = scrollChild:CreateTexture(nil, "ARTWORK")
    pinSeparator:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    pinSeparator:SetHeight(1)
    pinSeparator:Hide()
    resultsFrame.pinSeparator = pinSeparator

    -- Category separator lines (between result category groups)
    local categorySeps = {}
    for sepIdx = 1, 6 do
        local sep = scrollChild:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.3))
        sep:SetHeight(1.5)
        sep:Hide()
        categorySeps[sepIdx] = sep
    end
    resultsFrame.categorySeps = categorySeps
end
