local _, ns = ...

local Search = ns.Search
local Tooltips = ns.ResultTooltips
local L = ns.L

local CreateFrame = CreateFrame
local BattlePetTooltip = BattlePetTooltip
local GameTooltip = GameTooltip
local UIParent = UIParent

local unearnedTooltip

-- Row tooltips (GameTooltip + the unearned message) are UIParent-level, so they
-- don't inherit the search-bar scale. Match it, remembering the base scale and
-- restoring it on hide (GameTooltip is shared, so its scale must be put back).
local function ApplySearchTooltipScale(tooltip)
    if not tooltip._efScaleHooked then
        tooltip._efScaleHooked = true
        tooltip:HookScript("OnHide", function(self)
            if self._efBaseScale then
                self:SetScale(self._efBaseScale)
                self._efBaseScale = nil
            end
        end)
    end
    local s = (EasyFind.db and EasyFind.db.uiSearchScale) or 1.0
    if s == 1.0 then return end
    if not tooltip._efBaseScale then
        tooltip._efBaseScale = tooltip:GetScale() or 1.0
    end
    tooltip:SetScale(tooltip._efBaseScale * s)
end
Tooltips.ApplySearchTooltipScale = ApplySearchTooltipScale

-- Row tooltips anchor to the search/results panel's outside edge
-- (whichever side has more screen room), never at the cursor: a
-- cursor-anchored tooltip covers the very results being scanned, and
-- gear tooltips with their item-compare frame doubled in width are
-- worst of all.
local EDGE_GAP = 8
local EDGE_FIT_MIN_SCALE = 0.55

-- Place any frame against the panel's outside edge (whichever side has
-- more screen room). Returns false when the panel isn't measurable.
function Tooltips:PlaceAtPanelEdge(frame, fallbackOwner)
    frame:ClearAllPoints()
    frame._efEdgePanel = nil

    local panel = (Search:GetResultsFrame() and Search:GetResultsFrame():IsShown()) and Search:GetResultsFrame()
                  or (Search:GetSearchFrame() and Search:GetSearchFrame():IsShown()) and Search:GetSearchFrame()
                  or fallbackOwner

    local left = panel and panel:GetLeft()
    local right = panel and panel:GetRight()
    local top = panel and panel:GetTop()
    local screenW = UIParent:GetWidth() or 0

    if left and right and top and screenW > 0 then
        -- panel:GetLeft()/GetRight() are in the panel's effective-scale space;
        -- the search UI scales its frames (uiSearchScale/uiResultsScale), so
        -- convert those edges to UIParent space before comparing to screenW.
        -- Without this the room estimate is wrong at any non-1.0 scale and the
        -- tooltip flips sides at the wrong window position (overlapping it).
        local uiScale = UIParent:GetEffectiveScale() or 1
        local ratio = uiScale > 0 and (panel:GetEffectiveScale() / uiScale) or 1
        local roomRight = screenW - right * ratio
        local roomLeft = left * ratio
        if roomRight >= roomLeft then
            frame:SetPoint("TOPLEFT", panel, "TOPRIGHT", EDGE_GAP, 0)
            frame._efEdgeSide = "right"
        else
            frame:SetPoint("TOPRIGHT", panel, "TOPLEFT", -EDGE_GAP, 0)
            frame._efEdgeSide = "left"
        end
        frame._efEdgePanel = panel
        return true
    end
    return false
end

local function EdgeRoomFor(tooltip)
    local panel = tooltip._efEdgePanel
    if not panel then return end
    -- Convert the panel edge to UIParent space (see PlaceAtPanelEdge) so the
    -- room matches FitEdgeTooltip's UIParent-space width math at any UI scale.
    local uiScale = UIParent:GetEffectiveScale() or 1
    local ratio = uiScale > 0 and (panel:GetEffectiveScale() / uiScale) or 1
    if tooltip._efEdgeSide == "right" then
        local right = panel:GetRight()
        if not right then return end
        return (UIParent:GetWidth() or 0) - right * ratio - EDGE_GAP
    end
    local left = panel:GetLeft()
    if not left then return end
    return left * ratio - EDGE_GAP
end

-- The comparison manager anchors "Currently Equipped" toward screen
-- center, which from our edge placement means directly onto the
-- results. Re-anchor the compare frames on the outward side of the
-- main tooltip and match its (possibly fit-shrunk) scale; restore
-- their scale when they hide since they're shared frames.
local function AnchorOneCompareOutward(compare, tooltip, side, scale, xOffset)
    if not (compare and compare:IsShown()) then return xOffset end
    if compare._efBaseScale == nil then
        compare._efBaseScale = compare:GetScale() or 1.0
    end
    compare:SetScale(scale)
    compare:ClearAllPoints()
    -- Both compares anchor to the MAIN tooltip, never to each other:
    -- Blizzard's comparison manager anchors ShoppingTooltip1 relative to
    -- ShoppingTooltip2 in some layouts, so a persistent 2->1 dependency
    -- from us turns their SetPoint into an anchor-cycle error.
    if side == "right" then
        compare:SetPoint("TOPLEFT", tooltip, "TOPRIGHT", 4 + xOffset, 0)
    else
        compare:SetPoint("TOPRIGHT", tooltip, "TOPLEFT", -(4 + xOffset), 0)
    end
    return xOffset + (compare:GetWidth() or 0) + 4
end

local function AnchorComparesOutward(tooltip)
    local side = tooltip._efEdgePanel and tooltip._efEdgeSide
    if not side then return end
    local scale = tooltip:GetScale() or 1.0
    local xOffset = AnchorOneCompareOutward(_G["ShoppingTooltip1"], tooltip, side, scale, 0)
    AnchorOneCompareOutward(_G["ShoppingTooltip2"], tooltip, side, scale, xOffset)
end

-- Wide tooltips (gear with attached compare frames especially) exceed
-- the side room; the screen clamp would push them back over the
-- results. Shrink instead: scale down just enough that the tooltip
-- plus any shown compare tooltips fit in the room, floored so text
-- stays readable. Only ever shrinks within one showing, so growing
-- content converges instead of oscillating; compare frames re-match
-- the main tooltip's scale after every shrink.
local function FitEdgeTooltip(tooltip)
    local base = tooltip._efEdgeBaseScale
    local room = base and EdgeRoomFor(tooltip)
    if not room or room <= 0 then return end
    local uiScale = UIParent:GetEffectiveScale()
    if not uiScale or uiScale == 0 then return end
    local total = (tooltip:GetWidth() or 0) * (tooltip:GetEffectiveScale() or 1)
    local compare1, compare2 = _G["ShoppingTooltip1"], _G["ShoppingTooltip2"]
    if compare1 and compare1:IsShown() then
        total = total + (compare1:GetWidth() or 0) * (compare1:GetEffectiveScale() or 1)
    end
    if compare2 and compare2:IsShown() then
        total = total + (compare2:GetWidth() or 0) * (compare2:GetEffectiveScale() or 1)
    end
    total = total / uiScale
    if total <= 0 then return end
    local fit = room / total
    if fit >= 1 then return end
    local target = base * fit
    if target < base * EDGE_FIT_MIN_SCALE then target = base * EDGE_FIT_MIN_SCALE end
    local current = tooltip:GetScale() or base
    if target < current - 0.01 then
        tooltip:SetScale(target)
        AnchorComparesOutward(tooltip)
    end
end

-- Blizzard's comparison manager re-anchors the shopping tooltips on its
-- own schedule (late item data, refreshes, row-to-row hovers where the
-- compare frame never hides), and whichever SetPoint runs last wins.
-- Re-assert the outward layout after ANY of their re-anchors: hook the
-- manager when present plus the frames' own SetPoint, with a reentry
-- guard so our own anchoring doesn't recurse.
local comparesReanchoring = false
local function ReassertCompareAnchors()
    if comparesReanchoring then return end
    local tooltip = GameTooltip
    if not (tooltip and tooltip._efEdgePanel and tooltip._efEdgeBaseScale) then return end
    comparesReanchoring = true
    AnchorComparesOutward(tooltip)
    FitEdgeTooltip(tooltip)
    comparesReanchoring = false
end

local compareGuardsInstalled = false
local function InstallCompareGuards()
    if compareGuardsInstalled then return end
    compareGuardsInstalled = true
    local manager = _G["TooltipComparisonManager"]
    if manager and type(manager.AnchorShoppingTooltips) == "function" then
        hooksecurefunc(manager, "AnchorShoppingTooltips", ReassertCompareAnchors)
    end
    local compare1, compare2 = _G["ShoppingTooltip1"], _G["ShoppingTooltip2"]
    if compare1 then hooksecurefunc(compare1, "SetPoint", ReassertCompareAnchors) end
    if compare2 then hooksecurefunc(compare2, "SetPoint", ReassertCompareAnchors) end
end

local function HookCompareTooltip(compare, tooltip)
    if not compare or compare._efEdgeHooked then return end
    compare._efEdgeHooked = true
    compare:HookScript("OnShow", function()
        if tooltip._efEdgeBaseScale then
            ReassertCompareAnchors()
        end
    end)
    compare:HookScript("OnHide", function(self)
        if self._efBaseScale then
            self:SetScale(self._efBaseScale)
            self._efBaseScale = nil
        end
    end)
end

function Tooltips:AnchorRowTooltip(tooltip, ownerFrame)
    tooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    ApplySearchTooltipScale(tooltip)
    if not self:PlaceAtPanelEdge(tooltip, ownerFrame) then
        -- Fallback when the panel isn't measurable.
        tooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
        return
    end
    -- The scale restore on hide is owned by ApplySearchTooltipScale's
    -- hook; seed its base so a fit-shrunk scale never leaks onto the
    -- shared GameTooltip.
    if not tooltip._efBaseScale then
        tooltip._efBaseScale = tooltip:GetScale() or 1.0
    end
    tooltip._efEdgeBaseScale = tooltip:GetScale()
    if not tooltip._efEdgeFitHooked then
        tooltip._efEdgeFitHooked = true
        tooltip:HookScript("OnSizeChanged", FitEdgeTooltip)
        tooltip:HookScript("OnShow", FitEdgeTooltip)
        tooltip:HookScript("OnHide", function(self)
            self._efEdgePanel = nil
            self._efEdgeBaseScale = nil
        end)
        HookCompareTooltip(_G["ShoppingTooltip1"], tooltip)
        HookCompareTooltip(_G["ShoppingTooltip2"], tooltip)
        InstallCompareGuards()
    end
    FitEdgeTooltip(tooltip)
end

function Tooltips:GetUnearnedTooltip()
    return unearnedTooltip
end

function Tooltips:CreateUnearnedTooltip()
    unearnedTooltip = CreateFrame("Frame", "EasyFindUnearnedTooltip", UIParent)
    unearnedTooltip:SetFrameStrata("TOOLTIP")
    unearnedTooltip:SetFrameLevel(9999)
    unearnedTooltip:SetClampedToScreen(true)

    -- Same themed container the right-click context menu uses (DRY).
    ns.StyleMenuPanel(unearnedTooltip)

    local text = unearnedTooltip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    text:SetText(L["CURRENCY_NOT_EARNED"])
    -- The restyle below owns this color (gold on dark, accent on light).
    text._efOwnColor = true
    unearnedTooltip.text = text
    -- Gold on the themed panel is unreadable on light fills; re-derived
    -- on every show (the panel refills then too).
    unearnedTooltip._efOnThemeRestyle = function(self)
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if theme and theme.lightTheme then
            local c = theme.pathColorHover or theme.leafColor
            self.text:SetTextColor(c[1], c[2], c[3], 1)
            self.text:SetShadowColor(0, 0, 0, 0)
        else
            local gold = ns.GOLD_COLOR
            self.text:SetTextColor(gold[1], gold[2], gold[3], 1)
        end
    end
    unearnedTooltip:HookScript("OnShow", unearnedTooltip._efOnThemeRestyle)
    unearnedTooltip._efOnThemeRestyle(unearnedTooltip)

    local textWidth = text:GetStringWidth()
    local textHeight = text:GetStringHeight()
    unearnedTooltip:SetSize(textWidth + 20, textHeight + 16)

    unearnedTooltip:Hide()
end

function Tooltips:ClearResultTooltips()
    if unearnedTooltip then unearnedTooltip:Hide() end
    if BattlePetTooltip then BattlePetTooltip:Hide() end
    if GameTooltip then
        local resultButtons = Search:GetResultButtons()
        for i = 1, #resultButtons do
            local row = resultButtons[i]
            if row then
                if row.toyTooltipTicker then
                    row.toyTooltipTicker:Cancel()
                    row.toyTooltipTicker = nil
                end
                if GameTooltip:IsOwned(row) then
                    GameTooltip:Hide()
                end
            end
        end
    end
    if ns.MapSearch and ns.MapSearch.ClearUIPreview then
        ns.MapSearch:ClearUIPreview()
    end
end
