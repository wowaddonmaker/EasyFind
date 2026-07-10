local _, ns = ...

local Handlers = ns.ResultHandlers
local Openers = ns.SearchOpeners
local Utils = ns.Utils

local GetButtonText = Utils.GetButtonText
local ClickButton = Utils.ClickButton
local select, ipairs = Utils.select, Utils.ipairs
local slower = Utils.slower

local function ExtractSlot(value)
    return value.slotIndex
        or value.spellBookIndex
        or value.spellBookItemSlotIndex
        or value.spellBookItemIndex
        or value.itemIndex
        or value.slot
        or value.index
end

local function ExtractBank(value)
    return value.spellBank
        or value.spellBookBank
        or value.spellBookItemBank
        or value.bank
end

local function ExtractSpecID(value)
    local specID = value.specID
    if specID ~= nil and specID ~= 0 then return specID end
    if value.spellBookSpecID ~= nil then return value.spellBookSpecID end
    local offSpecID = value.offSpecID
    if offSpecID ~= nil and offSpecID ~= 0 then return offSpecID end
    return specID
end

local function HasSlotMismatch(value, targetSlot, targetBank)
    if not targetSlot then return false end
    local valueSlot = ExtractSlot(value)
    if not valueSlot then return false end
    if valueSlot ~= targetSlot then return true end
    if not targetBank then return false end
    local valueBank = ExtractBank(value)
    if valueBank ~= nil and valueBank ~= targetBank then return true end
    return false
end

local function HasSpecMismatch(value, targetSpecID)
    if targetSpecID == nil then return false end
    local valueSpecID = ExtractSpecID(value)
    return valueSpecID ~= nil and valueSpecID ~= targetSpecID
end

local function SpellRecordMatches(value, target, seen)
    if not value then return false end
    local vt = type(value)
    if vt == "number" then
        if target.spellBookSpecID ~= nil or target.spellBookIndex then return false end
        return value == target.spellID or value == target.spellBookSpellID
    end
    if vt ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true

    local targetSpell = target.spellBookSpellID or target.spellID
    local targetSlot = target.spellBookIndex
    local targetBank = target.spellBookBank
    local targetSpecID = target.spellBookSpecID

    if targetSpecID ~= nil then
        local specID = ExtractSpecID(value)
        if specID and specID == targetSpecID then
            local slot = ExtractSlot(value)
            if slot and targetSlot and slot == targetSlot then return true end
            if targetSpell and (value.spellID == targetSpell
                or value.actionID == targetSpell) then return true end
        end
    end

    if targetSlot then
        local bank = ExtractBank(value)
        local slot = ExtractSlot(value)
        if slot == targetSlot
            and (not targetBank or bank == nil or bank == targetBank)
            and not HasSpecMismatch(value, targetSpecID) then
            return true
        end
    end

    -- When the target carries disambiguation hints (specID or slot),
    -- spellID/name matches REQUIRE the value to carry a matching
    -- specID or slot. Without that, a sibling row with no slot/spec
    -- exposed (e.g. SpellBookItemInfo returned by a Button method)
    -- would match by spellID alone and the wrong "Wrath" wins.
    local needsDisambig = target.spellBookSpecID ~= nil
        or target.spellBookIndex ~= nil
    local function valueHasMatchingDisambig()
        local valueSpec = ExtractSpecID(value)
        if targetSpecID and valueSpec and valueSpec == targetSpecID then
            return true
        end
        local valueSlot = ExtractSlot(value)
        if targetSlot and valueSlot and valueSlot == targetSlot then
            return true
        end
        return false
    end

    if targetSpell and (value.spellID == targetSpell
        or value.spellId == targetSpell
        or value.actionID == targetSpell
        or value.actionId == targetSpell
        or value.id == targetSpell) then
        if not HasSpecMismatch(value, targetSpecID)
            and not HasSlotMismatch(value, targetSlot, targetBank)
            and (not needsDisambig or valueHasMatchingDisambig()) then
            return true
        end
    end

    local targetName = target.nameLower or (target.spellName and slower(target.spellName))
    if targetName and value.name and slower(value.name) == targetName then
        if not HasSpecMismatch(value, targetSpecID)
            and not HasSlotMismatch(value, targetSlot, targetBank)
            and (not needsDisambig or valueHasMatchingDisambig()) then
            return true
        end
    end

    if value.data and value.data ~= value and SpellRecordMatches(value.data, target, seen) then return true end
    if value.elementData and value.elementData ~= value and SpellRecordMatches(value.elementData, target, seen) then return true end
    if value.spellInfo and value.spellInfo ~= value and SpellRecordMatches(value.spellInfo, target, seen) then return true end
    if value.spellBookItemInfo and value.spellBookItemInfo ~= value and SpellRecordMatches(value.spellBookItemInfo, target, seen) then return true end
    if value.spellBookItemData and value.spellBookItemData ~= value and SpellRecordMatches(value.spellBookItemData, target, seen) then return true end
    if value.itemInfo and value.itemInfo ~= value and SpellRecordMatches(value.itemInfo, target, seen) then return true end
    return false
end

local function SpellFrameMatchesSelf(frame, target)
    if not frame then return false end

    local targetSlot = target.spellBookIndex
    local targetBank = target.spellBookBank
    if targetSlot and frame.GetItemSlotIndex then
        local sok, slot = pcall(frame.GetItemSlotIndex, frame)
        if sok and slot == targetSlot then
            if not targetBank or not frame.GetSpellBookItemBank then
                return true
            end
            local bok, bank = pcall(frame.GetSpellBookItemBank, frame)
            if not bok or bank == nil or bank == targetBank then
                return true
            end
        end
    end

    if frame.GetElementData then
        local ok, data = pcall(frame.GetElementData, frame)
        if ok and SpellRecordMatches(data, target) then return true end
    end
    if frame.GetSpellID then
        local ok, id = pcall(frame.GetSpellID, frame)
        if ok and SpellRecordMatches(id, target) then return true end
    end
    if frame.GetSpellBookItemInfo then
        local ok, info = pcall(frame.GetSpellBookItemInfo, frame)
        if ok and SpellRecordMatches(info, target) then return true end
    end
    if SpellRecordMatches(frame.data, target) then return true end
    if SpellRecordMatches(frame.elementData, target) then return true end
    if SpellRecordMatches(frame.spellInfo, target) then return true end
    if SpellRecordMatches(frame.spellBookItemInfo, target) then return true end
    if SpellRecordMatches(frame.spellBookItemData, target) then return true end
    return false
end

local function SpellFrameMatches(frame, target)
    if SpellFrameMatchesSelf(frame, target) then return true end
    if frame and frame.GetParent then
        local parent = frame:GetParent()
        if parent and SpellFrameMatchesSelf(parent, target) then return true end
        if parent and parent.GetParent then
            local gp = parent:GetParent()
            if gp and SpellFrameMatchesSelf(gp, target) then return true end
        end
    end
    return false
end

local function SpellFrameTextMatches(frame, target)
    local targetName = target and (target.nameLower or (target.spellName and slower(target.spellName)))
    if not targetName then return false end
    local text = GetButtonText(frame)
    return text and slower(text) == targetName
end

local function GetTabSkillLineName(tab)
    if not tab then return nil end
    if type(tab.tabText) == "string" and tab.tabText ~= "" then
        return tab.tabText
    end
    if tab.skillLineInfo and type(tab.skillLineInfo.name) == "string" then
        return tab.skillLineInfo.name
    end
    if type(tab.skillLine) == "table" and type(tab.skillLine.name) == "string" then
        return tab.skillLine.name
    end
    if tab.elementData and type(tab.elementData.name) == "string" then
        return tab.elementData.name
    end
    if tab.GetElementData then
        local ok, ed = pcall(tab.GetElementData, tab)
        if ok and ed and type(ed.name) == "string" then return ed.name end
    end
    if tab.tooltipText and type(tab.tooltipText) == "string" then
        return tab.tooltipText
    end
    if tab.GetText then
        local ok, txt = pcall(tab.GetText, tab)
        if ok and type(txt) == "string" and txt ~= "" then return txt end
    end
    local btnText = GetButtonText(tab)
    if btnText and btnText ~= "" then return btnText end
    return nil
end

local function FindSpellbookCategoryTab(frame, data)
    local book = frame and frame.SpellBookFrame
    local tabSystem = book and book.CategoryTabSystem
    if not tabSystem or not tabSystem.GetChildren then return nil end

    local targetName = data and data.spellBookCategoryName
    local targetLower = targetName and slower(targetName)
    local targetIsGeneral = targetLower == slower(_G.GENERAL or "general")

    local seen = {}
    local candidates = {}
    local function add(tab)
        if tab and not seen[tab] and tab.Click then
            seen[tab] = true
            candidates[#candidates + 1] = tab
        end
    end
    if tabSystem.tabs then
        for _, tab in ipairs(tabSystem.tabs) do add(tab) end
    end
    local children = { tabSystem:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child:IsShown() then add(child) end
    end

    local generalLower = slower(_G.GENERAL or "general")
    local function isGeneralTab(tab)
        local name = GetTabSkillLineName(tab)
        if name and slower(name) == generalLower then return true end
        local text = GetButtonText(tab)
        if text and slower(text) == generalLower then return true end
        return false
    end

    if targetIsGeneral then
        for i = 1, #candidates do
            if isGeneralTab(candidates[i]) then return candidates[i] end
        end
    else
        local classLower = UnitClass and slower(UnitClass("player") or "") or ""
        for i = 1, #candidates do
            local name = GetTabSkillLineName(candidates[i])
            if name and classLower ~= "" and slower(name) == classLower then
                return candidates[i]
            end
        end
        for i = 1, #candidates do
            if not isGeneralTab(candidates[i]) then return candidates[i] end
        end
    end

    return nil
end

local function GetSpellbookPagedFrame(frame)
    local book = frame and frame.SpellBookFrame
    return book and (book.PagedSpellsFrame or book) or nil
end

local function SpellbookPageButton(frame, key)
    local paged = GetSpellbookPagedFrame(frame)
    local controls = paged and paged.PagingControls
    return controls and controls[key] or nil
end

local function CanClickButton(btn)
    if not btn or not btn:IsShown() then return false end
    if btn.IsEnabled then
        local ok, enabled = pcall(btn.IsEnabled, btn)
        if ok then return enabled end
    end
    return btn.Click ~= nil
end

local function ClickSpellbookPage(frame, key)
    local btn = SpellbookPageButton(frame, key)
    if not CanClickButton(btn) then return false end
    return ClickButton(btn)
end

local function RewindSpellbookToFirstPage(frame)
    for _ = 1, 12 do
        if not ClickSpellbookPage(frame, "PrevPageButton") then break end
    end
end

local function GetSpellbookDataProvider(paged)
    if not paged then return nil, nil end
    local function probe(frame)
        if not frame then return nil end
        if frame.GetDataProvider then
            local ok, dp = pcall(frame.GetDataProvider, frame)
            if ok and dp then return dp end
        end
        return nil
    end
    local dp = probe(paged)
    if dp then return dp, paged end
    if paged.GetChildren then
        for ci = 1, select("#", paged:GetChildren()) do
            local child = select(ci, paged:GetChildren())
            local cdp = probe(child)
            if cdp then return cdp, child end
            if child and child.GetChildren then
                for gi = 1, select("#", child:GetChildren()) do
                    local gc = select(gi, child:GetChildren())
                    local gdp = probe(gc)
                    if gdp then return gdp, gc end
                end
            end
        end
    end
    return nil, nil
end

local function FindSpellElementInSection(paged, data)
    local dp = GetSpellbookDataProvider(paged)
    if not dp then return nil end

    local size = dp.GetSize and dp:GetSize() or 0
    if size == 0 and not dp.Enumerate then return nil end

    local targetSpellID = data.spellBookSpellID or data.spellID
    local targetSlot = data.spellBookIndex
    local targetBank = data.spellBookBank
    local targetSpecID = data.spellBookSpecID
    local targetNameLower = data.nameLower
        or (data.spellName and slower(data.spellName))
        or (data.name and slower(data.name))
    local targetSectionLower = data.spellBookCategoryName
        and slower(data.spellBookCategoryName)

    local currentSection
    local fallback
    local function inspect(elem)
        if elem then
            local info = elem.spellBookItemInfo or elem.spellInfo or elem.spellBookItemData
            local isSpellElement = info or elem.spellID or elem.actionID or ExtractSlot(elem)
            if not isSpellElement then
                local hdr = elem.name or elem.title or elem.text or elem.header
                if type(hdr) == "string" and hdr ~= "" then
                    currentSection = slower(hdr)
                end
            else
                info = info or elem
                local elemSlot = ExtractSlot(elem) or ExtractSlot(info)
                local elemBank = ExtractBank(elem) or ExtractBank(info)
                local elemSpecID = ExtractSpecID(elem) or ExtractSpecID(info)
                local specOK = targetSpecID == nil or elemSpecID == nil
                    or elemSpecID == targetSpecID
                local match = false
                if specOK and targetSlot and elemSlot == targetSlot
                    and (not targetBank or elemBank == nil or elemBank == targetBank) then
                    match = true
                elseif specOK and targetSpellID
                    and not HasSlotMismatch(elem, targetSlot, targetBank)
                    and not HasSlotMismatch(info, targetSlot, targetBank)
                    and (elem.spellID == targetSpellID
                        or elem.actionID == targetSpellID
                        or info.spellID == targetSpellID
                        or info.actionID == targetSpellID) then
                    match = true
                elseif specOK and targetNameLower and info.name
                    and not HasSlotMismatch(elem, targetSlot, targetBank)
                    and not HasSlotMismatch(info, targetSlot, targetBank)
                    and slower(info.name) == targetNameLower then
                    match = true
                end
                if match then
                    if targetSectionLower and currentSection == targetSectionLower then
                        return elem
                    end
                    fallback = fallback or elem
                end
            end
        end
        return nil
    end

    if dp.Enumerate then
        for a, b in dp:Enumerate() do
            local found = inspect(b or a)
            if found then return found end
        end
    else
        for i = 1, size do
            local elem = dp.Find and dp:Find(i)
            local found = inspect(elem)
            if found then return found end
        end
    end
    return fallback
end

local function ScrollSpellbookToElement(paged, elem)
    if not elem then return false end
    local _, host = GetSpellbookDataProvider(paged)
    if host and host.ScrollToElementData then
        local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
        pcall(host.ScrollToElementData, host, elem, alignCenter)
        return true
    end
    return false
end

local function FindVisibleButtonForElement(paged, elem)
    if not elem then return nil end
    local _, host = GetSpellbookDataProvider(paged)
    if host and host.EnumerateFrames then
        for _, f in host:EnumerateFrames() do
            if f and f:IsShown() and f.GetElementData then
                local ok, ed = pcall(f.GetElementData, f)
                if ok and ed == elem then return f end
            end
        end
    end
    return nil
end

local function FindSpellbookButton(root, target, scroll, candidate)
    if not root then return nil end
    local nextCandidate = candidate
    if root.Click then
        nextCandidate = root
    elseif root.GetScript then
        local ok, onClick = pcall(root.GetScript, root, "OnClick")
        if ok and onClick then nextCandidate = root end
    end
    if root.EnumerateFrames and root.GetDataProvider then
        if scroll then
            Utils.ScrollBoxScrollTo(root, function(data)
                return SpellRecordMatches(data, target)
            end)
        end
        local hasID = target and (target.spellBookSpellID or target.spellID)
        local btn = Utils.ScrollBoxFindButton(root, function(frame)
            if SpellFrameMatches(frame, target) then return true end
            if not hasID and SpellFrameTextMatches(frame, target) then return true end
            return false
        end)
        if btn then return btn end
    end
    local hasID = target and (target.spellBookSpellID or target.spellID)
    if SpellFrameMatches(root, target) then
        return nextCandidate or root
    end
    if not hasID and SpellFrameTextMatches(root, target) then
        return nextCandidate or root
    end
    if root.GetChildren then
        for i = 1, select("#", root:GetChildren()) do
            local child = select(i, root:GetChildren())
            if child and child:IsShown() then
                local found = FindSpellbookButton(child, target, scroll, nextCandidate)
                if found then return found end
            end
        end
    end
    return nil
end

function Handlers:OpenAbilityInSpellbook(data)
    local highlight = ns.Highlight
    local categoryClicked = false
    local rewound = false
    local triedElementScroll = false
    local targetElement
    local pagesAdvanced = 0
    local MAX_PAGES = 20

    local spellbookTab = ns.SecureOpeners and ns.SecureOpeners.TAB_SPELLBOOK or 3
    local function openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if frame and frame:IsShown() then
            -- Wrong tab: highlighted for a hardware click (see
            -- EnsurePlayerSpellsTab); retry until the user lands on it.
            return not Openers:EnsurePlayerSpellsTab(spellbookTab)
        end

        Openers:OpenPlayerSpellsFrame(spellbookTab)
        return true
    end

    local function reveal(attempt)
        local needsRetry = openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if needsRetry then
            if attempt < 36 then
                Utils.SafeAfter(0.05, function() reveal(attempt + 1) end)
            end
            return
        end
        local root = frame and frame.SpellBookFrame
        if not root or not root:IsShown() then
            if attempt < 36 then
                Utils.SafeAfter(0.05, function() reveal(attempt + 1) end)
            end
            return
        end

        if not categoryClicked then
            local tab = FindSpellbookCategoryTab(frame, data)
            if tab then
                categoryClicked = true
                rewound = false
                triedElementScroll = false
                targetElement = nil
                pagesAdvanced = 0
                ClickButton(tab)
                if attempt < 36 then
                    Utils.SafeAfter(0, function() reveal(attempt + 1) end)
                end
                return
            end
        end

        local paged = GetSpellbookPagedFrame(frame) or root

        if not triedElementScroll then
            triedElementScroll = true
            targetElement = FindSpellElementInSection(paged, data)
            if targetElement and ScrollSpellbookToElement(paged, targetElement) then
                Utils.SafeAfter(0, function() reveal(attempt + 1) end)
                return
            end
        end

        -- Validator passed to HighlightFrame's watcher. ScrollBox button
        -- pools repurpose the same physical button for different spells
        -- when the user pages the spellbook, so the frame stays visible
        -- but stops representing the search target. This re-checks the
        -- spell identity each tick and clears the highlight on mismatch.
        local function stillRepresentsTarget(f)
            return SpellFrameMatchesSelf(f, data)
        end

        if targetElement then
            local elementBtn = FindVisibleButtonForElement(paged, targetElement)
            if elementBtn and highlight then
                if highlight.HighlightSpellbookSpell then
                    highlight:HighlightSpellbookSpell(elementBtn, stillRepresentsTarget)
                else
                    highlight:HighlightFrame(elementBtn, nil, stillRepresentsTarget)
                    Handlers.HideHighlightOnHover(elementBtn)
                end
                return
            end
        end

        local btn = FindSpellbookButton(paged, data, false)
        if btn and highlight then
            if highlight.HighlightSpellbookSpell then
                highlight:HighlightSpellbookSpell(btn, stillRepresentsTarget)
            else
                highlight:HighlightFrame(btn, nil, stillRepresentsTarget)
                Handlers.HideHighlightOnHover(btn)
            end
            return
        end

        if not rewound then
            RewindSpellbookToFirstPage(frame)
            rewound = true
            pagesAdvanced = 0
            Utils.SafeAfter(0, function() reveal(attempt + 1) end)
            return
        end

        if pagesAdvanced < MAX_PAGES
           and ClickSpellbookPage(frame, "NextPageButton") then
            pagesAdvanced = pagesAdvanced + 1
            Utils.SafeAfter(0, function() reveal(attempt + 1) end)
            return
        end
        if attempt < 36 then
            Utils.SafeAfter(0.05, function() reveal(attempt + 1) end)
        end
    end

    Utils.SafeAfter(0.05, function() reveal(1) end)
end

function Handlers:ApplySpellBookHidePassives(hide)
    hide = hide and true or false
    if GetCVarBool and GetCVarBool("spellBookHidePassives") == hide then return end
    if SetCVar then pcall(SetCVar, "spellBookHidePassives", hide and "1" or "0") end
    local frame = PlayerSpellsFrame and PlayerSpellsFrame.SpellBookFrame
    if frame and frame:IsShown() and frame.UpdateDisplayedSpells then
        pcall(frame.UpdateDisplayedSpells, frame, true, false)
    end
end

-- Bidirectional sync from Blizzard back to our DB. Hook the same
-- C_*Info setters Blizzard's own dropdowns call so toggling the
-- in-game Search updates our flyout state. The popup syncs from DB on
-- next show, so we don't need to refresh anything live.
