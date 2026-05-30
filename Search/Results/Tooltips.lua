local _, ns = ...

local Search = ns.Search
local Tooltips = ns.ResultTooltips
local L = ns.L

local CreateFrame = CreateFrame
local BattlePetTooltip = BattlePetTooltip
local GameTooltip = GameTooltip
local UIParent = UIParent
local GetCursorPosition = GetCursorPosition
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER

local unearnedTooltip

-- Default tooltip placement for non-gear results. The default Search sets
-- the tooltip's bottom-right corner just up-and-left of the cursor
-- (with a small diagonal buffer so the tooltip doesn't sit literally
-- under the cursor arrow). ANCHOR_CURSOR puts it bottom-center at the
-- cursor instead, so we anchor manually. We also hook OnUpdate to
-- track cursor motion while the tooltip is owned by the row, mirroring
-- how default ANCHOR_CURSOR follows the mouse.
local TOOLTIP_CURSOR_OFFSET_X = -8
local TOOLTIP_CURSOR_OFFSET_Y = 16

local function PlaceTooltipBottomRightAtCursor(tooltip)
    tooltip:ClearAllPoints()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    if scale == 0 then scale = 1 end
    tooltip:SetPoint(
        "BOTTOMRIGHT", UIParent, "BOTTOMLEFT",
        (cx / scale) + TOOLTIP_CURSOR_OFFSET_X,
        (cy / scale) + TOOLTIP_CURSOR_OFFSET_Y
    )
end

function Tooltips:AnchorTooltipAtCursor(tooltip, ownerFrame)
    tooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    PlaceTooltipBottomRightAtCursor(tooltip)
    tooltip._easyFindCursorFollow = ownerFrame
    if not tooltip._easyFindCursorHooked then
        tooltip._easyFindCursorHooked = true
        tooltip:HookScript("OnUpdate", function(self)
            if self._easyFindCursorFollow and self:IsOwned(self._easyFindCursorFollow) then
                PlaceTooltipBottomRightAtCursor(self)
            end
        end)
        tooltip:HookScript("OnHide", function(self)
            self._easyFindCursorFollow = nil
        end)
    end
end

-- Special placement for GEAR tooltips: items render with an attached
-- item-compare frame doubled in width, so cursor-anchored tooltips
-- end up covering the result row that spawned them. Anchor to the
-- search/results panel's outside edge (whichever side has more screen
-- room) so the cursor and our own Search both stay clear.
function Tooltips:AnchorGearTooltip(tooltip, ownerFrame)
    tooltip:SetOwner(ownerFrame, "ANCHOR_NONE")
    tooltip:ClearAllPoints()

    local panel = (Search:GetResultsFrame() and Search:GetResultsFrame():IsShown()) and Search:GetResultsFrame()
                  or (Search:GetSearchFrame() and Search:GetSearchFrame():IsShown()) and Search:GetSearchFrame()
                  or ownerFrame

    local left = panel and panel:GetLeft()
    local right = panel and panel:GetRight()
    local top = panel and panel:GetTop()
    local screenW = UIParent:GetWidth() or 0

    if left and right and top and screenW > 0 then
        local roomRight = screenW - right
        local roomLeft = left
        local gap = 8
        if roomRight >= roomLeft then
            tooltip:SetPoint("TOPLEFT", panel, "TOPRIGHT", gap, 0)
        else
            tooltip:SetPoint("TOPRIGHT", panel, "TOPLEFT", -gap, 0)
        end
        return
    end

    -- Fallback when the panel isn't measurable.
    tooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
end

function Tooltips:GetUnearnedTooltip()
    return unearnedTooltip
end

function Tooltips:CreateUnearnedTooltip()
    unearnedTooltip = CreateFrame("Frame", "EasyFindUnearnedTooltip", UIParent, "BackdropTemplate")
    unearnedTooltip:SetFrameStrata("TOOLTIP")
    unearnedTooltip:SetFrameLevel(9999)
    unearnedTooltip:SetClampedToScreen(true)

    unearnedTooltip:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = TOOLTIP_BORDER,
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    unearnedTooltip:SetBackdropColor(0, 0, 0, 0.95)
    unearnedTooltip:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local text = unearnedTooltip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    text:SetText(L["CURRENCY_NOT_EARNED"])
    text:SetTextColor(1, 1, 1, 1)
    unearnedTooltip.text = text

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
