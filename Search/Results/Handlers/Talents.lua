local _, ns = ...

local Handlers = ns.ResultHandlers
local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ClickButton = Utils.ClickButton
local select, ipairs = Utils.select, Utils.ipairs

function Handlers:OpenTalentInTalentsTab(data)
    local highlight = ns.Highlight
    local TALENTS_TAB = 2

    local function ensureFrameOnTab(attempt)
        local frame = _G["PlayerSpellsFrame"]
        if not (frame and frame:IsShown()) then
            Openers:OpenPlayerSpellsFrame(TALENTS_TAB)
            if attempt < 30 then
                Utils.SafeAfter(0.05, function() ensureFrameOnTab(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("PlayerSpellsFrame", TALENTS_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("PlayerSpellsFrame", TALENTS_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                Utils.SafeAfter(0, function() ensureFrameOnTab(attempt + 1) end)
            end
            return
        end
        -- Frame open and on Talents tab: light up the matching talent
        -- button's SearchIcon directly. Each talent button is parented
        -- to TalentsFrame.ButtonsParent (or a hero/sub-tree container)
        -- and frame-named after the talent itself, so the cleanest path
        -- is: walk children, match by GetName(), Show() the SearchIcon.
        local talentsFrame = frame.TalentsFrame
        local targetLower = (data.name or ""):lower()

        local function nameOf(btn)
            if not btn or not btn.GetName then return nil end
            local n = btn:GetName()
            return n and n:lower() or nil
        end

        -- Recursive search: choice nodes nest the actual option button
        -- one (or more) levels below ButtonsParent's direct child, so a
        -- fixed 2-level walk misses them. Cap depth so we don't spin on
        -- weird parent loops.
        local function searchTree(frame, depth)
            if not frame or depth > 5 then return nil end
            if frame.SearchIcon and nameOf(frame) == targetLower then
                return frame
            end
            if frame.GetChildren then
                for i = 1, select("#", frame:GetChildren()) do
                    local found = searchTree(select(i, frame:GetChildren()), depth + 1)
                    if found then return found end
                end
            end
            return nil
        end

        local function findMatchingButton()
            if not talentsFrame then return nil end
            local containers = {
                talentsFrame.ButtonsParent,
                talentsFrame.HeroTalentsContainer,
                talentsFrame.SubTreeContainer,
            }
            for _, parent in ipairs(containers) do
                local found = searchTree(parent, 0)
                if found then return found end
            end
            return nil
        end

        local tries = 0
        local function showSpyglass()
            tries = tries + 1
            local btn = findMatchingButton()
            if btn and btn.SearchIcon and btn.SearchIcon.Show then
                -- Bump strata above the talent button's own ARTWORK / OVERLAY
                -- siblings so the spyglass isn't occluded by the talent
                -- icon's connectors and glow textures.
                if btn.SearchIcon.SetFrameStrata then
                    btn.SearchIcon:SetFrameStrata("HIGH")
                end
                if btn.SearchIcon.SetFrameLevel and btn.GetFrameLevel then
                    btn.SearchIcon:SetFrameLevel(btn:GetFrameLevel() + 10)
                end
                btn.SearchIcon:Show()
                if ns.Highlight and ns.Highlight.RegisterTalentSearchIcon then
                    ns.Highlight:RegisterTalentSearchIcon(btn, targetLower, nameOf)
                end
                return
            end
            if tries < 20 then
                Utils.SafeAfter(0.05, showSpyglass)
            end
        end
        Utils.SafeAfter(0, showSpyglass)
    end

    ensureFrameOnTab(1)
end
