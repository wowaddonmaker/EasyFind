local _, ns = ...

local UI = ns.UI
local Utils = ns.Utils

local GetButtonText = Utils.GetButtonText
local SearchFrameTreeFuzzy = Utils.SearchFrameTreeFuzzy
local ClickButton = Utils.ClickButton
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local slower = Utils.slower
local mfloor = Utils.mfloor

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown
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
        for _, child in ipairs({ paged:GetChildren() }) do
            local cdp = probe(child)
            if cdp then return cdp, child end
            if child and child.GetChildren then
                for _, gc in ipairs({ child:GetChildren() }) do
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

local function HideHighlightOnHover(frame)
    if not frame or frame._efHideHighlightOnHover or not frame.HookScript then return end
    frame._efHideHighlightOnHover = true
    frame:HookScript("OnEnter", function()
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end)
    if frame.IsMouseOver and frame:IsMouseOver() then
        local highlight = ns.Highlight
        if highlight and highlight.HideHighlight then
            highlight:HideHighlight()
        end
    end
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
        for _, child in ipairs({ root:GetChildren() }) do
            if child and child:IsShown() then
                local found = FindSpellbookButton(child, target, scroll, nextCandidate)
                if found then return found end
            end
        end
    end
    return nil
end

function UI:HighlightRevealedFrame(frame)
    local highlight = ns.Highlight
    if not (frame and highlight and highlight.HighlightFrame) then return false end
    highlight:HighlightFrame(frame)
    HideHighlightOnHover(frame)
    return true
end

function UI:GetMountJournalFrame()
    local collections = _G["CollectionsJournal"]
    return _G["MountJournal"]
        or (collections and collections.MountJournal)
        or (collections and collections.MountJournalFrame)
end

function UI:GetMountJournalScrollBox()
    local mountJournal = self:GetMountJournalFrame()
    if not mountJournal then return nil end
    if mountJournal.ScrollBox then return mountJournal.ScrollBox end
    if mountJournal.MountList and mountJournal.MountList.ScrollBox then return mountJournal.MountList.ScrollBox end
    if mountJournal.List and mountJournal.List.ScrollBox then return mountJournal.List.ScrollBox end
    if mountJournal.ListScrollFrame and mountJournal.ListScrollFrame.ScrollBox then return mountJournal.ListScrollFrame.ScrollBox end
    local oldScroll = _G["MountJournalListScrollFrame"]
    if oldScroll and oldScroll.ScrollBox then return oldScroll.ScrollBox end
    return nil
end

function UI:GetMountJournalDisplayFraction(mountID)
    if not mountID or not C_MountJournal then return nil end
    if C_MountJournal.GetNumDisplayedMounts and C_MountJournal.GetDisplayedMountID then
        local total = C_MountJournal.GetNumDisplayedMounts()
        for i = 1, total or 0 do
            if C_MountJournal.GetDisplayedMountID(i) == mountID then
                return (total and total > 1) and ((i - 1) / (total - 1)) or 0
            end
        end
    end
    if C_MountJournal.GetMountIDs then
        local ids = C_MountJournal.GetMountIDs()
        if type(ids) == "table" then
            for i = 1, #ids do
                if ids[i] == mountID then
                    return (#ids > 1) and ((i - 1) / (#ids - 1)) or 0
                end
            end
        end
    end
    return nil
end

function UI:MountElementMatches(edata, mountID, spellID, mountName)
    if not edata then return false end
    if type(edata) == "number" then return mountID and edata == mountID end
    if type(edata) ~= "table" then return false end
    local edataMountID = edata.mountID or edata.mountId or edata.id
    if mountID and edataMountID == mountID then return true end
    local edataSpellID = edata.spellID or edata.spellId
    if spellID and edataSpellID == spellID then return true end
    local name = edata.name or edata.mountName or edata.displayName
    return mountName and name and slower(name) == mountName
end

function UI:MountFrameMatches(frame, mountID, spellID, mountName)
    if not frame then return false end
    local ok, edata = pcall(function()
        return frame.GetElementData and frame:GetElementData()
    end)
    if ok and self:MountElementMatches(edata, mountID, spellID, mountName) then return true end
    if mountID and (frame.mountID == mountID or frame.mountId == mountID or frame.id == mountID) then
        return true
    end
    if spellID and (frame.spellID == spellID or frame.spellId == spellID) then
        return true
    end
    local text = GetButtonText(frame)
    return mountName and text and slower(text) == mountName
end

function UI:SetEditBoxTextIfPresent(editBox, text)
    if editBox and editBox.SetText then
        pcall(editBox.SetText, editBox, text or "")
    end
end

function UI:RevealMountInJournal(data)
    if not (data and data.mountID) then return nil end

    local spellID = data.spellID
    if not spellID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        local ok, _, sid = pcall(C_MountJournal.GetMountInfoByID, data.mountID)
        if ok then spellID = sid end
    end

    if C_MountJournal then
        if C_MountJournal.SetAllSourceFilters then pcall(C_MountJournal.SetAllSourceFilters, true) end
        if C_MountJournal.SetAllTypeFilters then pcall(C_MountJournal.SetAllTypeFilters, true) end
        if C_MountJournal.SetCollectedFilterSetting then
            local collectedFilter = _G["LE_MOUNT_JOURNAL_FILTER_COLLECTED"]
            local uncollectedFilter = _G["LE_MOUNT_JOURNAL_FILTER_NOT_COLLECTED"]
            if collectedFilter ~= nil then
                pcall(C_MountJournal.SetCollectedFilterSetting, collectedFilter, true)
            end
            if uncollectedFilter ~= nil then
                pcall(C_MountJournal.SetCollectedFilterSetting, uncollectedFilter, false)
            end
        end
        if C_MountJournal.SetSearch then
            pcall(C_MountJournal.SetSearch, "")
        end
    end

    local mountJournal = self:GetMountJournalFrame()
    if mountJournal then
        self:SetEditBoxTextIfPresent(mountJournal.SearchBox or mountJournal.searchBox, "")
    end

    local mountName = data.name and slower(data.name)
    local scrollBox = self:GetMountJournalScrollBox()
    if scrollBox then
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return self:MountElementMatches(edata, data.mountID, spellID, mountName)
        end, self:GetMountJournalDisplayFraction(data.mountID))
        local btn = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return self:MountFrameMatches(frame, data.mountID, spellID, mountName)
        end)
        if btn then return btn end
    end

    if mountJournal and mountName then
        return SearchFrameTreeFuzzy(mountJournal, mountName)
    end
    return nil
end

function UI:OpenMountInJournal(data)
    if not (data and data.mountID) then return end
    local highlight = ns.Highlight
    local MOUNT_TAB = 1

    local function step(attempt)
        local journal = _G["CollectionsJournal"]
        if not (journal and journal:IsShown()) then
            local micro = _G["CollectionsMicroButton"]
            if micro then ClickButton(micro) end
            if attempt < 30 then
                C_Timer.After(0.05, function() step(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("CollectionsJournal", MOUNT_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("CollectionsJournal", MOUNT_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                C_Timer.After(0, function() step(attempt + 1) end)
            end
            return
        end

        local row = self:RevealMountInJournal(data)
        if row and self:HighlightRevealedFrame(row) then return end
        if attempt < 30 then
            C_Timer.After(0.05, function() step(attempt + 1) end)
        end
    end

    step(1)
end

function UI:GetToyBoxFrame()
    local collections = _G["CollectionsJournal"]
    return _G["ToyBox"]
        or _G["ToyBoxFrame"]
        or (collections and collections.ToyBox)
        or (collections and collections.ToyBoxFrame)
end

function UI:GetToyBoxScrollBox()
    local toyBox = self:GetToyBoxFrame()
    if not toyBox then return nil end
    local iconsFrame = toyBox.iconsFrame or toyBox.IconsFrame
    if toyBox.ScrollBox then return toyBox.ScrollBox end
    if toyBox.ItemsScrollBox then return toyBox.ItemsScrollBox end
    if toyBox.List and toyBox.List.ScrollBox then return toyBox.List.ScrollBox end
    if toyBox.ScrollFrame and toyBox.ScrollFrame.ScrollBox then return toyBox.ScrollFrame.ScrollBox end
    if iconsFrame and iconsFrame.ScrollBox then return iconsFrame.ScrollBox end
    if iconsFrame and iconsFrame.scrollBox then return iconsFrame.scrollBox end
    if iconsFrame and iconsFrame.ScrollFrame and iconsFrame.ScrollFrame.ScrollBox then return iconsFrame.ScrollFrame.ScrollBox end
    if _G["ToyBoxScrollBox"] then return _G["ToyBoxScrollBox"] end
    local oldIcons = _G["ToyBoxIconsFrame"]
    if oldIcons and oldIcons.ScrollBox then return oldIcons.ScrollBox end
    return nil
end

function UI:GetToyDisplayFraction(itemID)
    if not (itemID and C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex) then
        return nil
    end
    local total = C_ToyBox.GetNumFilteredToys()
    for i = 1, total or 0 do
        if C_ToyBox.GetToyFromIndex(i) == itemID then
            return (total and total > 1) and ((i - 1) / (total - 1)) or 0
        end
    end
    return nil
end

function UI:GetToyDisplayIndex(itemID)
    if not (itemID and C_ToyBox and C_ToyBox.GetNumFilteredToys and C_ToyBox.GetToyFromIndex) then
        return nil, nil
    end
    local total = C_ToyBox.GetNumFilteredToys()
    for i = 1, total or 0 do
        if C_ToyBox.GetToyFromIndex(i) == itemID then
            return i, total
        end
    end
    return nil, total
end

function UI:GetToyBoxButtonsPerPage(toyBox)
    local iconsFrame = toyBox and (toyBox.iconsFrame or toyBox.IconsFrame)
    local buttons = (iconsFrame and (iconsFrame.buttons or iconsFrame.Buttons))
        or (toyBox and (toyBox.buttons or toyBox.Buttons))
    if type(buttons) == "table" then
        local count = 0
        for _, button in pairs(buttons) do
            if button then count = count + 1 end
        end
        if count > 0 then return count end
    end
    local perPage = _G["TOYS_PER_PAGE"]
    if type(perPage) == "number" and perPage > 0 then return perPage end
    return 18
end

function UI:SetToyBoxPageForItem(itemID)
    local index = self:GetToyDisplayIndex(itemID)
    if not index then return nil end

    local toyBox = self:GetToyBoxFrame()
    local perPage = self:GetToyBoxButtonsPerPage(toyBox)
    if not perPage or perPage <= 0 then return nil end

    local page = mfloor((index - 1) / perPage) + 1
    if toyBox then
        toyBox.page = page
        toyBox.currentPage = page
    end

    local paging = toyBox and (toyBox.PagingFrame or toyBox.pagingFrame)
    if paging and paging.SetCurrentPage then
        pcall(paging.SetCurrentPage, paging, page)
    end

    local updatePage = _G["ToyBox_UpdatePage"]
    if updatePage then
        pcall(updatePage, page)
        if toyBox then pcall(updatePage, toyBox, page) end
    end

    local updateButtons = _G["ToyBox_UpdateButtons"]
    if updateButtons then
        pcall(updateButtons)
        if toyBox then pcall(updateButtons, toyBox) end
    end

    return page
end

function UI:ToyElementMatches(edata, itemID, toyName)
    if not edata then return false end
    if type(edata) == "number" then return itemID and edata == itemID end
    if type(edata) ~= "table" then return false end
    local edataItemID = edata.itemID or edata.itemId or edata.toyItemID
        or edata.toyID or edata.toyId or edata.id
    if itemID and edataItemID == itemID then return true end
    local item = edata.item or edata.toy or edata.info
    edataItemID = item and (item.itemID or item.itemId or item.toyItemID
        or item.toyID or item.toyId or item.id)
    if itemID and edataItemID == itemID then return true end
    local name = edata.name or edata.toyName or edata.itemName or edata.displayName
        or (item and (item.name or item.toyName or item.itemName or item.displayName))
    return toyName and name and slower(name) == toyName
end

function UI:ToyFrameMatches(frame, itemID, toyName)
    if not frame then return false end
    local ok, edata = pcall(function()
        return frame.GetElementData and frame:GetElementData()
    end)
    if ok and self:ToyElementMatches(edata, itemID, toyName) then return true end
    if itemID and (frame.itemID == itemID or frame.itemId == itemID
        or frame.toyItemID == itemID or frame.toyID == itemID
        or frame.toyId == itemID or frame.id == itemID) then
        return true
    end
    local text = GetButtonText(frame)
    return toyName and text and slower(text) == toyName
end

function UI:FindToyButtonInFrame(frame, itemID, toyName, depth)
    if not frame or (depth or 0) > 7 then return nil end
    if frame.IsShown and not frame:IsShown() then return nil end

    if self:ToyFrameMatches(frame, itemID, toyName) and frame.GetLeft then
        return frame
    end

    local buttons = frame.buttons or frame.Buttons
    if type(buttons) == "table" then
        for _, button in pairs(buttons) do
            local found = self:FindToyButtonInFrame(button, itemID, toyName, (depth or 0) + 1)
            if found then return found end
        end
    end

    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            local found = self:FindToyButtonInFrame(child, itemID, toyName, (depth or 0) + 1)
            if found then return found end
        end
    end
    return nil
end

function UI:RevealToyInToyBox(data)
    if not (data and data.toyItemID) then return nil end

    if C_ToyBox then
        if C_ToyBox.SetCollectedShown then pcall(C_ToyBox.SetCollectedShown, true) end
        if C_ToyBox.SetUncollectedShown then pcall(C_ToyBox.SetUncollectedShown, false) end
        if C_ToyBox.SetAllSourceTypeFilters then pcall(C_ToyBox.SetAllSourceTypeFilters, true) end
        if C_ToyBox.SetAllExpansionTypeFilters then pcall(C_ToyBox.SetAllExpansionTypeFilters, true) end
        if C_ToyBox.SetFilterString then pcall(C_ToyBox.SetFilterString, "") end
        if C_ToyBox.ForceToyRefilter then pcall(C_ToyBox.ForceToyRefilter) end
    end

    local toyBox = self:GetToyBoxFrame()
    if toyBox then
        self:SetEditBoxTextIfPresent(toyBox.SearchBox or toyBox.searchBox, "")
    end

    local toyName = data.name and slower(data.name)
    self:SetToyBoxPageForItem(data.toyItemID)

    if toyBox then
        local visibleButton = self:FindToyButtonInFrame(toyBox, data.toyItemID, toyName, 0)
        if visibleButton then return visibleButton end
    end

    local scrollBox = self:GetToyBoxScrollBox()
    if scrollBox then
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return self:ToyElementMatches(edata, data.toyItemID, toyName)
        end, self:GetToyDisplayFraction(data.toyItemID))
        local btn = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return self:ToyFrameMatches(frame, data.toyItemID, toyName)
        end)
        if btn then return btn end
    end

    if toyBox then
        local visibleButton = self:FindToyButtonInFrame(toyBox, data.toyItemID, toyName, 0)
        if visibleButton then return visibleButton end
    end

    if toyBox and toyName then
        return SearchFrameTreeFuzzy(toyBox, toyName)
    end
    return nil
end

function UI:GetOutfitScrollBox()
    local outfitCollection = TransmogFrame and TransmogFrame.OutfitCollection
    local outfitList = outfitCollection and outfitCollection.OutfitList
    if outfitList and outfitList.ScrollBox then return outfitList.ScrollBox end
    if outfitCollection and outfitCollection.ScrollBox then return outfitCollection.ScrollBox end
    if outfitList and outfitList.ListScrollFrame and outfitList.ListScrollFrame.ScrollBox then
        return outfitList.ListScrollFrame.ScrollBox
    end
    local oldScroll = _G["TransmogOutfitListScrollFrame"]
    if oldScroll and oldScroll.ScrollBox then return oldScroll.ScrollBox end
    return nil
end

function UI:OutfitElementMatches(edata, outfitID, outfitName)
    if not edata then return false end
    if type(edata) == "number" then return outfitID and edata == outfitID end
    if type(edata) ~= "table" then return false end
    local info = edata.info or edata.outfitInfo or edata.outfit
    local edataOutfitID = edata.outfitID or edata.outfitId or edata.id
        or (info and (info.outfitID or info.outfitId or info.id))
    if outfitID and edataOutfitID == outfitID then return true end
    local name = edata.name or edata.outfitName or edata.displayName
        or (info and (info.name or info.outfitName or info.displayName))
    return outfitName and name and slower(name) == outfitName
end

function UI:OutfitButtonMatches(button, outfitID, outfitName)
    if not button then return false end
    if outfitID and (button.outfitID == outfitID or button.outfitId == outfitID or button.id == outfitID) then
        return true
    end
    local text = GetButtonText(button)
    return outfitName and text and slower(text) == outfitName
end

function UI:OutfitFrameMatches(frame, outfitID, outfitName)
    if not frame then return false end
    local ok, edata = pcall(function()
        return frame.GetElementData and frame:GetElementData()
    end)
    if ok and self:OutfitElementMatches(edata, outfitID, outfitName) then return true end
    if self:OutfitButtonMatches(frame, outfitID, outfitName) then return true end
    return self:OutfitButtonMatches(frame.OutfitButton, outfitID, outfitName)
end

function UI:RevealOutfitInTransmog(data)
    if not (data and data.outfitID and TransmogFrame) then return nil end

    local outfitName = data.name and slower(data.name)
    local scrollBox = self:GetOutfitScrollBox()
    if scrollBox then
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return self:OutfitElementMatches(edata, data.outfitID, outfitName)
        end)
        local row = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return self:OutfitFrameMatches(frame, data.outfitID, outfitName)
        end)
        if row then return row.OutfitButton or row end
    end

    local outfitCollection = TransmogFrame.OutfitCollection
    if outfitCollection and outfitName then
        return SearchFrameTreeFuzzy(outfitCollection, outfitName)
    end
    return nil
end

function UI:OpenOutfitInTransmog(data)
    if not (data and data.outfitID) then return end

    local function showTransmogFrame()
        if not TransmogFrame and Transmog_LoadUI then
            Transmog_LoadUI()
        end
        if TransmogFrame then
            UI:SecureShowUIPanel(TransmogFrame)
            self:ApplyTransmogBrowseMode()
        end
    end

    local function step(attempt)
        if not (TransmogFrame and TransmogFrame:IsShown()) then
            showTransmogFrame()
            if attempt < 30 then
                C_Timer.After(0.05, function() step(attempt + 1) end)
            end
            return
        end
        if not TransmogFrame._efBrowseMode then
            self:ApplyTransmogBrowseMode()
        end

        local row = self:RevealOutfitInTransmog(data)
        if row and self:HighlightRevealedFrame(row) then return end
        if attempt < 30 then
            C_Timer.After(0.05, function() step(attempt + 1) end)
        end
    end

    step(1)
end

-- Open the Collections > Toys tab and surface the target toy without
-- filtering the ToyBox down to one result.
function UI:OpenToyInToyBox(data)
    if not data or not data.toyItemID then return end
    local highlight = ns.Highlight
    local TOY_TAB = 3

    local function step(attempt)
        local journal = _G["CollectionsJournal"]
        if not (journal and journal:IsShown()) then
            local micro = _G["CollectionsMicroButton"]
            if micro then ClickButton(micro) end
            if attempt < 30 then
                C_Timer.After(0.05, function() step(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("CollectionsJournal", TOY_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("CollectionsJournal", TOY_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                C_Timer.After(0, function() step(attempt + 1) end)
            end
            return
        end
        local row = self:RevealToyInToyBox(data)
        if row and self:HighlightRevealedFrame(row) then return end
        if attempt < 30 then
            C_Timer.After(0.05, function() step(attempt + 1) end)
        end
    end

    step(1)
end

-- Open PlayerSpellsFrame to the Talents tab and drive Blizzard's own
-- search box at PlayerSpellsFrame.TalentsFrame.SearchBox with the
-- talent name. The game's native search highlights matching nodes
-- with the spyglass icon -- no need for our own highlight pass.
-- Cleanest path: matches the visual the player already recognizes
-- and works for hero / sub-tree talents without us walking parents.
function UI:OpenTalentInTalentsTab(data)
    local highlight = ns.Highlight
    local TALENTS_TAB = 2

    local function ensureFrameOnTab(attempt)
        local frame = _G["PlayerSpellsFrame"]
        if not (frame and frame:IsShown()) then
            UI:OpenPlayerSpellsFrame(TALENTS_TAB)
            if attempt < 30 then
                C_Timer.After(0.05, function() ensureFrameOnTab(attempt + 1) end)
            end
            return
        end
        if highlight and highlight.IsTabSelected
           and not highlight:IsTabSelected("PlayerSpellsFrame", TALENTS_TAB) then
            local tab = highlight.GetTabButton
                and highlight:GetTabButton("PlayerSpellsFrame", TALENTS_TAB)
            if tab then ClickButton(tab) end
            if attempt < 30 then
                C_Timer.After(0, function() ensureFrameOnTab(attempt + 1) end)
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
                local kids = { frame:GetChildren() }
                for i = 1, #kids do
                    local found = searchTree(kids[i], depth + 1)
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
                C_Timer.After(0.05, showSpyglass)
            end
        end
        C_Timer.After(0, showSpyglass)
    end

    ensureFrameOnTab(1)
end

function UI:OpenAbilityInSpellbook(data)
    local highlight = ns.Highlight
    local categoryClicked = false
    local rewound = false
    local triedElementScroll = false
    local targetElement
    local pagesAdvanced = 0
    local MAX_PAGES = 20

    local function openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if frame and frame:IsShown() then
            if highlight and highlight.IsTabSelected
               and not highlight:IsTabSelected("PlayerSpellsFrame", 3) then
                local tab = highlight.GetTabButton
                    and highlight:GetTabButton("PlayerSpellsFrame", 3)
                ClickButton(tab)
                return true
            end
            return false
        end

        UI:OpenPlayerSpellsFrame(3)
        return true
    end

    local function reveal(attempt)
        local needsRetry = openFrame()
        local frame = _G["PlayerSpellsFrame"]
        if needsRetry then
            if attempt < 36 then
                C_Timer.After(0.05, function() reveal(attempt + 1) end)
            end
            return
        end
        local root = frame and frame.SpellBookFrame
        if not root or not root:IsShown() then
            if attempt < 36 then
                C_Timer.After(0.05, function() reveal(attempt + 1) end)
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
                    C_Timer.After(0, function() reveal(attempt + 1) end)
                end
                return
            end
        end

        local paged = GetSpellbookPagedFrame(frame) or root

        if not triedElementScroll then
            triedElementScroll = true
            targetElement = FindSpellElementInSection(paged, data)
            if targetElement and ScrollSpellbookToElement(paged, targetElement) then
                C_Timer.After(0, function() reveal(attempt + 1) end)
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
                    HideHighlightOnHover(elementBtn)
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
                HideHighlightOnHover(btn)
            end
            return
        end

        if not rewound then
            RewindSpellbookToFirstPage(frame)
            rewound = true
            pagesAdvanced = 0
            C_Timer.After(0, function() reveal(attempt + 1) end)
            return
        end

        if pagesAdvanced < MAX_PAGES
           and ClickSpellbookPage(frame, "NextPageButton") then
            pagesAdvanced = pagesAdvanced + 1
            C_Timer.After(0, function() reveal(attempt + 1) end)
            return
        end
        if attempt < 36 then
            C_Timer.After(0.05, function() reveal(attempt + 1) end)
        end
    end

    C_Timer.After(0.05, function() reveal(1) end)
end

local function GetPetJournalFrame()
    return _G["PetJournal"]
        or (CollectionsJournal and CollectionsJournal.PetJournal)
        or (CollectionsJournal and CollectionsJournal.PetJournalFrame)
end

local function BuildPetJournalGuideData(data)
    return {
        name = data.name,
        petID = data.petID,
        speciesID = data.speciesID,
        steps = {
            { buttonFrame = "CollectionsMicroButton" },
            { waitForFrame = "CollectionsJournal", tabIndex = 2 },
            {
                waitForFrame = "CollectionsJournal",
                petID = data.petID,
                speciesID = data.speciesID,
                petName = data.name,
            },
        },
    }
end

function UI:ResolvePetGUID(data)
    if not data then return nil end
    local guid = data.petID
    if not (C_PetJournal and data.speciesID
            and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex) then
        return guid
    end

    local total = C_PetJournal.GetNumPets()
    for i = 1, total or 0 do
        local pid, sid, owned = C_PetJournal.GetPetInfoByIndex(i)
        if owned and sid == data.speciesID then
            return pid
        end
    end
    return guid
end

local function PetElementMatches(edata, petID, speciesID, petName)
    if not edata then return false end
    local pid = edata.petID or edata.petGuid or edata.petGUID or edata.guid
    if petID and pid == petID then return true end
    local sid = edata.speciesID or edata.speciesId
    if speciesID and sid == speciesID then return true end
    local name = edata.name or edata.speciesName or edata.displayName
    return petName and name and slower(name) == slower(petName)
end

local function PetFrameMatches(frame, petID, speciesID, petName)
    if not frame then return false end
    local edata = frame.GetElementData and frame:GetElementData()
    if PetElementMatches(edata, petID, speciesID, petName) then return true end
    if petID and (frame.petID == petID or frame.petGuid == petID or frame.petGUID == petID) then
        return true
    end
    if speciesID and frame.speciesID == speciesID then return true end
    local text = GetButtonText(frame)
    return petName and text and slower(text) == slower(petName)
end

local function GetPetJournalScrollBox()
    local petJournal = GetPetJournalFrame()
    if not petJournal then return nil end
    local candidates = {
        petJournal.ScrollBox,
        petJournal.PetList and petJournal.PetList.ScrollBox,
        petJournal.List and petJournal.List.ScrollBox,
        petJournal.listScroll and petJournal.listScroll.ScrollBox,
        _G["PetJournalListScrollFrame"] and _G["PetJournalListScrollFrame"].ScrollBox,
    }
    for i = 1, #candidates do
        if candidates[i] then return candidates[i] end
    end
    return nil
end

function UI:RevealPetInJournal(data)
    if not data or not C_PetJournal then return nil end
    local petName = data.petName or data.name

    if C_PetJournal.SetFilterChecked then
        local collectedFilter = _G["LE_PET_JOURNAL_FILTER_COLLECTED"]
        local uncollectedFilter = _G["LE_PET_JOURNAL_FILTER_NOT_COLLECTED"]
        if collectedFilter ~= nil then
            pcall(C_PetJournal.SetFilterChecked, collectedFilter, true)
        end
        if uncollectedFilter ~= nil then
            pcall(C_PetJournal.SetFilterChecked, uncollectedFilter, false)
        end
    end
    if C_PetJournal.SetAllPetSourcesChecked then pcall(C_PetJournal.SetAllPetSourcesChecked, true) end
    if C_PetJournal.SetAllPetTypesChecked then pcall(C_PetJournal.SetAllPetTypesChecked, true) end
    -- Do not search for the pet by name here. Guide/direct-open should
    -- leave the journal in its normal list view, scroll to the pet row,
    -- and highlight it.
    if C_PetJournal.SetSearchFilter then
        local currentSearch = ""
        if C_PetJournal.GetSearchFilter then
            local ok, value = pcall(C_PetJournal.GetSearchFilter)
            if ok and value then currentSearch = value end
        end
        if currentSearch ~= "" then
            pcall(C_PetJournal.SetSearchFilter, "")
        end
    end

    local petID = self:ResolvePetGUID(data)
    if petID and petID ~= data.petID then data.petID = petID end

    local petJournal = GetPetJournalFrame()
    local selectPet = _G["PetJournal_SelectPet"]
    if selectPet and petID then
        pcall(selectPet, petID)
        if petJournal then pcall(selectPet, petJournal, petID) end
    end
    if C_PetJournal.SetSelectedPet and petID then
        pcall(C_PetJournal.SetSelectedPet, petID)
    end

    local scrollBox = GetPetJournalScrollBox()
    if scrollBox then
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return PetElementMatches(edata, petID, data.speciesID, petName)
        end)
        local btn = Utils.ScrollBoxFindButton(scrollBox, function(frame)
            return PetFrameMatches(frame, petID, data.speciesID, petName)
        end)
        if btn then return btn end
    end

    if petJournal and petName then
        return SearchFrameTreeFuzzy(petJournal, slower(petName))
    end
    return nil
end

function UI:FinishResultSelection()
    UI:SetSelectingResult(true)
    UI:GetSearchFrame().editBox:SetText("")
    UI:GetSearchFrame().editBox:ClearFocus()
    UI:GetSearchFrame().editBox.placeholder:Show()
    UI:SetSelectingResult(false)
    if EasyFind.db.autoHide then
        self:Hide()
    else
        self:HideResults()
        if EasyFind.db.smartShow then
            UI:GetSearchFrame().smartShowFadeOut()
        end
    end
end

function UI:SelectResult(data, forceGuide)
    if not data then return end
    local useFast = not forceGuide

    if data.quickFilterDef then
        self:ApplyQuickFilter(data.quickFilterDef, "")
        return
    end

    if data.searchCommand then
        self:RunSearchBarCommand("/" .. data.searchCommand)
        return
    end

    if data.calculatorLauncher then
        self:OpenCalculator("")
        return
    end

    if data.calculatorResult then
        self:ArmCalculatorResultForData(data)
        return
    end

    self:FinishResultSelection()

    -- the secure macrotext attribute set when the row was rendered. The
    -- click already ran the command; nothing else for SelectResult to do.
    if data.slashCommand then return end



    -- Transmogrification panel: load and show TransmogFrame
    if data.steps and data.steps[1] and data.steps[1].loadTransmog then
        if not TransmogFrame then
            Transmog_LoadUI()
        end
        if TransmogFrame then
            UI:SecureShowUIPanel(TransmogFrame)
            self:ApplyTransmogBrowseMode()
        end
        return
    end

    -- Blizzard Settings panel: open the named category directly.
    -- Both fast and guide modes do the same thing here -- there's no
    -- multi-step guide to walk for an in-game settings category.
    if data.steps and data.steps[1] and data.steps[1].settingsCategory then
        if ns.BlizzOptionsSearch then
            ns.BlizzOptionsSearch:HandleStep(data.steps[1])
        end
        return
    end

    -- Outfit: default click equips via SecureActionButton. Ctrl-click
    -- suppresses that secure action in PreClick and opens the outfit list.
    if data.outfitID then
        if forceGuide or (IsControlKeyDown and IsControlKeyDown()) then
            self:OpenOutfitInTransmog(data)
        end
        return
    end

    -- Loot: Ctrl+click opens dressing room, regular click navigates EJ
    if data.itemID and data.category == "Loot" then
        local lootLink = ns.Database and ns.Database:GetLootItemLink(data)
        if IsControlKeyDown() and lootLink then
            if DressUpItemLink(lootLink) then
                return
            end
        end

        -- Sync EJ loot filter so the item is visible when we navigate there
        if ns.Database then ns.Database:SyncEJLootFilter() end

        local isRaid = data.lootSourceType == "Raid"
        local tabIndex = isRaid and 5 or 4
        local ejDiffID = ns.Database and ns.Database:GetEJDifficultyID(data.lootSourceType)
        local guideData = {
            steps = {
                { buttonFrame = "EJMicroButton" },
                { waitForFrame = "EncounterJournal", tabIndex = tabIndex },
                { waitForFrame = "EncounterJournal", ejInstance = data.lootInstanceName, ejInstanceID = data.instanceID },
                { waitForFrame = "EncounterJournal", ejBoss = data.lootSourceName, ejEncounterID = data.encounterID },
                { waitForFrame = "EncounterJournal", ejLootTab = true, ejDifficultyID = ejDiffID },
                { waitForFrame = "EncounterJournal", ejLootItem = data.itemID, ejLootItemName = data.name },
            },
        }

        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Appearance Set: Ctrl+click opens dressing room with full set, regular click navigates.
    -- For pinned entries saved before transmogSetID was persisted, recover the
    -- ID by looking up the set name in the live database.
    if data.category == "Appearance Set" and not data.transmogSetID and data.name and ns.Database then
        data.transmogSetID = ns.Database:GetTransmogSetIDByName(data.name)
    end
    if data.transmogSetID then
        if IsControlKeyDown() then
            self:DressUpAppearanceSet(data.transmogSetID)
            return
        end

        local setID = data.transmogSetID
        local GetBaseSetID = C_TransmogSets.GetBaseSetID
        local baseID = GetBaseSetID and GetBaseSetID(setID) or setID
        local guideData = {
            steps = {
                { buttonFrame = "CollectionsMicroButton" },
                { waitForFrame = "CollectionsJournal", tabIndex = 5 },
                { waitForFrame = "WardrobeCollectionFrame", wardrobeSetsTab = true },
                { waitForFrame = "WardrobeCollectionFrame", transmogSetID = baseID },
            },
        }
        if baseID ~= setID then
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantDropdown = true }
            guideData.steps[#guideData.steps + 1] = { waitForFrame = "WardrobeCollectionFrame", transmogVariantSetID = setID }
        end
        if useFast then
            self:DirectOpen(guideData)
        else
            EasyFind:StartGuide(guideData)
        end
        return
    end

    -- Mount: default click summons/dismisses. Ctrl-click opens the mount
    -- in Collections > Mounts instead.
    if data.mountID then
        if forceGuide or (IsControlKeyDown and IsControlKeyDown()) then
            self:OpenMountInJournal(data)
            return
        end
        if C_MountJournal and C_MountJournal.SummonByID then
            C_MountJournal.SummonByID(data.mountID)
        end
        return
    end

    -- Heirloom: create the item in the player's bags. Mirrors clicking
    -- a tile in the HeirloomsJournal: API hands you a fresh copy.
    if data.heirloomItemID then
        if C_Heirloom and C_Heirloom.CreateHeirloom then
            C_Heirloom.CreateHeirloom(data.heirloomItemID)
        end
        return
    end

    -- Title: set as current. SetCurrentTitle is unprotected and updates
    -- the player's nameplate immediately, no journal navigation needed.
    if data.titleID then
        if SetCurrentTitle then SetCurrentTitle(data.titleID) end
        return
    end

    -- Gear set: equip via Equipment Manager. Skipped in combat, the
    -- API silently fails there, so no point trying.
    if data.gearSetID then
        if InCombatLockdown() then return end
        if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
            C_EquipmentSet.UseEquipmentSet(data.gearSetID)
        end
        return
    end

    -- Toy: default click uses via the SecureActionButton type=toy
    -- attribute. Ctrl-click and unusable toys route to the ToyBox.
    if data.toyItemID then
        if data.isToyboxOnly or forceGuide
           or (IsControlKeyDown and IsControlKeyDown()) then
            self:OpenToyInToyBox(data)
        end
        return
    end

    -- Talents: open Talents tab and highlight the matching node. Routed
    -- here (before the generic spellID branch) because talents share the
    -- spellID field with abilities but should never cast.
    if data.category == "Talent" and data.talentNodeID then
        self:OpenTalentInTalentsTab(data)
        return
    end

    if data.spellID then
        if forceGuide or UI:IsSpellbookOnlyAbility(data) then
            self:OpenAbilityInSpellbook(data)
        end
        return
    end

    -- Pet: normal click summons. Guide and Ctrl+click route to the pet
    -- in Collections > Pet Journal instead; Ctrl uses DirectOpen so it
    -- skips the step-by-step guide and only highlights the destination.
    if data.petID or data.speciesID then
        if forceGuide or (IsControlKeyDown and IsControlKeyDown()) then
            local guideData = BuildPetJournalGuideData(data)
            if useFast then
                self:DirectOpen(guideData)
            else
                EasyFind:StartGuide(guideData)
            end
            return
        end

        if C_PetJournal then
            local guid = self:ResolvePetGUID(data)
            if guid and C_PetJournal.SummonPetByGUID then
                C_PetJournal.SummonPetByGUID(guid)
                if guid ~= data.petID then data.petID = guid end
            end
        end
        return
    end

    if data.mapSearchResult then
        if ns.MapSearch and ns.MapSearch.HandleUISearchClick then
            ns.MapSearch:HandleUISearchClick(data, forceGuide)
        end
        return
    end

    -- Bag item: usable items (consumables, equippables) fire /use via the
    -- SecureActionButton on click: no bag UI needed. Non-usable items
    -- open the bag(s) containing them and highlight the slot.
    if data.itemID and data.category == "Bag" then
        if useFast then
            local showInBags = IsControlKeyDown and IsControlKeyDown()
            -- Skip bag-open for anything the secure click will already act
            -- on: explicit Use spells, equippable gear, AND broad item
            -- types that "use" via right-click without a Use:tooltip line
            -- (Consumable / Container / Quest). Without the type fallback,
            -- right-click-openable containers like lockboxes still hit
            -- the bag-open path, so the bag visibly pops AND the
            -- container opens -- the user only wants the latter.
            if not showInBags and self:GetBagItemActionKind(data) ~= "show" then
                return
            end
            self:OpenBagItemLocation(data)
            return
        end
        if not data.steps or #data.steps == 0 then return end
    end

    -- Macro: default click runs the macro (handled by the row's secure
    -- macro attribute). Ctrl+click opens MacroFrame for editing:
    -- PreClick clears the secure type when Ctrl is held so the macro
    -- guide via forceGuide=true.
    if data.macroIndex then
        if useFast then
            if IsControlKeyDown() then
                UI:OpenMacroFrameAt(data.macroIndex, data.macroIsChar)
            end
            return
        end
        if data.steps then EasyFind:StartGuide(data) end
        return
    end

    -- Flash label if specified (e.g., for Currency searches)
    if data.flashLabel then
        self:FlashLabel(data.flashLabel)
    end

    if useFast and data.steps then
        -- Portrait menu can't be automated (secure frame restriction)
        local mustGuide = false
        for _, step in ipairs(data.steps) do
            if step.portraitMenu or step.portraitMenuOption then
                mustGuide = true
                break
            end
        end

        if mustGuide then
            EasyFind:StartGuide(data)
        else
            self:DirectOpen(data)
        end
    elseif data.steps then
        EasyFind:StartGuide(data)
    end
end

local EncounterDataMatches
EncounterDataMatches = function(value, targetID, targetName)
    if not value then return false end
    if targetID and (value.encounterID == targetID or value.journalEncounterID == targetID or value.id == targetID) then
        return true
    end
    local name = value.name or value.title or value.text
    if targetName and name and slower(name) == targetName then return true end
    local nested = value.data or value.elementData
    if nested and nested ~= value then
        return EncounterDataMatches(nested, targetID, targetName)
    end
    return false
end

local function GetEJBossesScrollBox()
    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
    return infoFrame and infoFrame.BossesScrollBox
end

local function EncounterFrameMatches(btn, targetID, targetName)
    local edata = btn.GetElementData and btn:GetElementData()
    if EncounterDataMatches(edata, targetID, targetName) then return true end
    if targetID and (btn.encounterID == targetID or btn.journalEncounterID == targetID or btn.id == targetID) then
        return true
    end
    local text = GetButtonText(btn)
    return targetName and text and slower(text) == targetName
end

local function RevealEJEncounter(step)
    local targetID = step.ejEncounterID
    local targetName = step.ejBoss and slower(step.ejBoss)
    local function reveal()
        local scrollBox = GetEJBossesScrollBox()
        if not scrollBox then return end
        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
            return EncounterDataMatches(edata, targetID, targetName)
        end)
        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
            return EncounterFrameMatches(btn, targetID, targetName)
        end)
        if bossBtn and bossBtn.GetElementData and scrollBox.ScrollToElementData then
            local edata = bossBtn:GetElementData()
            if edata then
                scrollBox:ScrollToElementData(edata, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
            end
        end
    end
    reveal()
    Utils.SafeAfter(0.05, reveal)
end

-- Direct open mode - programmatically navigates to the target as far as possible.
-- Executes ALL steps that represent clickable navigation (tabs, categories, buttons).
-- Only falls back to highlighting when the final step is a non-navigable UI region
-- that the user needs to visually locate (e.g. PvP Talents tray, War Mode button).
function UI:DirectOpen(data)
    if not data or not data.steps or #data.steps == 0 then return end

    local steps = data.steps
    local totalSteps = #steps
    local Highlight = ns.Highlight

    -- For reputation steps, pre-expand all needed headers via API.
    local needsReputationResync = false
    for _, step in ipairs(steps) do
        if step.factionHeader then
            needsReputationResync = true
            if C_Reputation and C_Reputation.GetNumFactions then
                local headerNameLower = slower(step.factionHeader)
                local numFactions = C_Reputation.GetNumFactions()
                for i = 1, numFactions do
                    local factionData = C_Reputation.GetFactionDataByIndex(i)
                    if factionData and factionData.isHeader and factionData.name and slower(factionData.name) == headerNameLower then
                        local isCollapsed = false
                        if factionData.isHeaderExpanded ~= nil then
                            isCollapsed = not factionData.isHeaderExpanded
                        elseif factionData.isCollapsed ~= nil then
                            isCollapsed = factionData.isCollapsed
                        end
                        if isCollapsed then
                            C_Reputation.ExpandFactionHeader(i)
                        end
                        break
                    end
                end
            end
        end
    end

    -- For currency steps: don't pre-expand headers, don't resync. Both
    -- ExpandCurrencyList and the tab-toggle resync write ScrollBar /
    -- ScrollBox state via Blizzard's refresh / OnShow handlers, and those
    -- writes get attributed to us (we triggered them) -- which blocks the
    -- protected RequestCurrencyFromAccountCharacter call at Confirm.
    -- HighlightCurrencyRowOrHint polls for the row to come into view once
    -- the player expands the header / scrolls themselves.
    local needsCurrencyResync = false

    -- Determine whether a step is "navigable" (can be auto-executed) vs "highlight-only"
    -- (just points at a UI region the user needs to see).
    -- A step is navigable if it has any clickable action property.
    local function isStepNavigable(step)
        if step.buttonFrame then return true end
        if step.gameMenuText then return true end
        if step.tabIndex then return true end
        if step.sideTabIndex then return true end
        if step.pvpSideTabIndex then return true end
        if step.sidebarButtonFrame or step.sidebarIndex then return true end
        if step.statisticsCategory then return true end
        if step.achievementCategory then return true end
        if step.currencyHeader then return true end
        if step.currencyID then return true end
        if step.factionHeader then return true end
        if step.factionID then return true end
        if step.searchButtonText then return true end
        if step.portraitMenuOption then return true end
        if step.ejInstance then return true end
        if step.ejBoss then return true end
        if step.ejLootTab then return true end
        if step.wardrobeSetsTab then return true end
        if step.transmogSetID then return true end
        if step.transmogVariantDropdown then return true end
        if step.transmogVariantSetID then return true end
        -- regionFrames alone (no searchButtonText) = highlight-only (e.g. PvP Talents)
        -- waitForFrame alone = just waiting for a frame to appear, not navigable
        -- text alone = instruction text, not navigable
        return false
    end

    local lastStep = steps[totalSteps]
    local finalStepNavigable = isStepNavigable(lastStep)

    -- Auto-clicking the final step taints state that blocks protected actions
    -- (JoinBattlefield, etc.).
    if data.canQueue and finalStepNavigable then
        finalStepNavigable = false
    end

    -- How many steps to execute programmatically:
    -- If final step is navigable, execute ALL steps (no highlight needed).
    -- If final step is highlight-only, execute all but the last, then highlight it.
    local executeCount = finalStepNavigable and totalSteps or (totalSteps - 1)

    -- If there's nothing to execute programmatically (single highlight-only step),
    -- just start the normal guide.
    if executeCount == 0 then
        EasyFind:StartGuide(data)
        return
    end

    -- Execute all navigable steps synchronously in one frame. WoW frame
    -- operations (ClickButton, tab selection) process immediately, so
    -- child frames are available right after their parent is shown.
    -- The only exception is currency/reputation tab resync, which toggles
    -- tabs and needs one frame for the ScrollBox to rebuild.
    local tabClickAttempts = {}
    local categoryClickAttempts = {}
    local function executeFrom(start)
        for i = start, executeCount do
            local step = steps[i]

            if step.loadTransmog then
                if not TransmogFrame then
                    Transmog_LoadUI()
                end
                if TransmogFrame then
                    UI:SecureShowUIPanel(TransmogFrame)
                    UI:ApplyTransmogBrowseMode()
                end
                return
            end

            -- Game Menu button by text: open the menu (if not already)
            -- and click the labeled child. Handles unnamed dynamic-ID
            -- buttons in modern GameMenuFrame.
            if step.gameMenuText then
                if not GameMenuFrame:IsShown() then
                    pcall(GameMenuFrame.Show, GameMenuFrame)
                end
                local btn = Highlight:FindGameMenuButton(step.gameMenuText)
                if btn then ClickButton(btn) end
            end

            if step.buttonFrame then
                -- EncounterJournal: set selectedTab BEFORE opening so Blizzard's
                -- own init calls SetTab with our value (clean call stack, no taint)
                if step.buttonFrame == "EJMicroButton" then
                    local nextStep = steps[i + 1]
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.tabIndex then
                        EncounterJournal_LoadUI()
                        EncounterJournal.selectedTab = nextStep.tabIndex
                        UI:SecureShowUIPanel(EncounterJournal)
                        -- Skip the tab step, continue from the step after it.
                        -- Defer one frame so the ScrollBox populates its items.
                        local resume = i + 2
                        C_Timer.After(0, function() executeFrom(resume) end)
                        return
                    end
                    -- Boss navigation: set tier + dungeon/raid tab before showing
                    -- so the InstanceSelect ScrollBox populates with the right
                    -- tier's instances on first paint. ShowUIPanel is a no-op
                    -- when EJ is already shown (OnShow / SetTab won't refire),
                    -- so we still need an explicit tab click to apply the new
                    -- tier when the user re-opens onto a different expansion.
                    if nextStep and nextStep.waitForFrame == "EncounterJournal" and nextStep.ejTier then
                        EncounterJournal_LoadUI()
                        if EJ_SelectTier then EJ_SelectTier(nextStep.ejTier) end
                        local tabIdx = nextStep.ejTabIsRaid and 5 or 4
                        EncounterJournal.selectedTab = tabIdx
                        UI:SecureShowUIPanel(EncounterJournal)
                        local tabBtn = Highlight:GetTabButton("EncounterJournal", tabIdx)
                        if tabBtn then ClickButton(tabBtn) end
                        local resume = i + 2
                        C_Timer.After(0, function() executeFrom(resume) end)
                        return
                    end
                end
                UI:OpenButtonFrame(step.buttonFrame, steps[i + 1])
            end

            if step.waitForFrame and step.tabIndex then

                local resync = false
                if step.waitForFrame == "CharacterFrame" then
                    if needsCurrencyResync and step.tabIndex == 3 then
                        resync = true
                        needsCurrencyResync = false
                    elseif needsReputationResync and step.tabIndex == 2 then
                        resync = true
                        needsReputationResync = false
                    end
                end
                if resync then
                    -- Toggle tabs to force ScrollBox rebuild with expanded headers.
                    -- Needs one frame to propagate; defer remaining steps.
                    UI:OpenCharacterFrame(1)
                    local tabIdx = step.tabIndex
                    local resume = i + 1
                    C_Timer.After(0.05, function()
                        UI:OpenCharacterFrame(tabIdx)
                        executeFrom(resume)
                    end)
                    return
                elseif step.waitForFrame == "CharacterFrame" then
                    UI:OpenCharacterFrame(step.tabIndex)
                elseif step.waitForFrame == "PlayerSpellsFrame"
                       and not UI:IsPlayerSpellsTabSelected(step.tabIndex) then
                    local tabBtn = Highlight:GetTabButton(step.waitForFrame, step.tabIndex)
                    if tabBtn then ClickButton(tabBtn) end
                elseif step.waitForFrame ~= "EncounterJournal"
                       and step.waitForFrame ~= "PlayerSpellsFrame" then
                    ClickButton(Highlight:GetTabButton(step.waitForFrame, step.tabIndex))
                end

                local nextStep = steps[i + 1]
                if step.waitForFrame == "AchievementFrame" and nextStep
                   and (nextStep.achievementCategory or nextStep.statisticsCategory) then
                    local tabReady = true
                    if Highlight and Highlight.IsTabSelected then
                        tabReady = Highlight:IsTabSelected("AchievementFrame", step.tabIndex)
                    end
                    if not tabReady then
                        local key = tostring(i) .. ":tab:" .. tostring(step.tabIndex)
                        tabClickAttempts[key] = (tabClickAttempts[key] or 0) + 1
                        if tabClickAttempts[key] <= 6 then
                            local resume = i
                            C_Timer.After(0.05, function() executeFrom(resume) end)
                            return
                        end
                    end

                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            if step.sideTabIndex then
                ClickButton(Highlight:GetSideTabButton(step.waitForFrame or "PVEFrame", step.sideTabIndex))
            end

            if step.pvpSideTabIndex then
                ClickButton(Highlight:GetPvPSideTabButton(step.waitForFrame or "PVEFrame", step.pvpSideTabIndex))
            end

            if step.sidebarButtonFrame or step.sidebarIndex then
                self:ClickCharacterSidebar(step.sidebarIndex)
            end

            local categoryToClick = step.statisticsCategory or step.achievementCategory
            if categoryToClick then
                local categoryID = step.statisticsCategoryID or step.achievementCategoryID
                if not self:ClickAchievementCategory(categoryToClick, categoryID) then
                    local key = tostring(i) .. ":" .. tostring(categoryID or categoryToClick)
                    categoryClickAttempts[key] = (categoryClickAttempts[key] or 0) + 1
                    if categoryClickAttempts[key] <= 6 then
                        local resume = i
                        C_Timer.After(0.05, function() executeFrom(resume) end)
                        return
                    end
                end

                local nextStep = steps[i + 1]
                if nextStep and (nextStep.achievementCategory or nextStep.statisticsCategory) then
                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            if step.achievementID then
                self:OpenAchievementByID(step.achievementID)
            end

            -- EJ tier + dungeon/raid tab (boss navigation when EJ is already
            -- open). The EJMicroButton fast path handles the cold-open case;
            -- this branch handles re-opens on a different tier.
            if step.waitForFrame == "EncounterJournal" and step.ejTier then
                if EJ_SelectTier then EJ_SelectTier(step.ejTier) end
                local tabIdx = step.ejTabIsRaid and 5 or 4
                EncounterJournal.selectedTab = tabIdx
                local tabBtn = Highlight:GetTabButton("EncounterJournal", tabIdx)
                if tabBtn then ClickButton(tabBtn) end
                -- Defer remaining steps so the InstanceSelect ScrollBox can
                -- rebuild with the new tier's instances before we look up
                -- the target instance by name.
                local resume = i + 1
                C_Timer.After(0, function() executeFrom(resume) end)
                return
            end

            -- EJ instance: prefer the EncounterJournal_DisplayInstance API
            -- (synchronous, no ScrollBox race) when we have the instanceID,
            -- otherwise fall back to scanning visible buttons by name.
            if step.ejInstance then
                local displayInstance = _G["EncounterJournal_DisplayInstance"]
                if step.ejInstanceID and displayInstance then
                    pcall(displayInstance, step.ejInstanceID)
                else
                    local scrollBox = _G["EncounterJournalInstanceSelect"] and _G["EncounterJournalInstanceSelect"].ScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejInstance)
                        local instBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local text = Utils.GetButtonText(btn)
                            return text and slower(text) == targetName
                        end)
                        if instBtn then ClickButton(instBtn) end
                    end
                end
                -- Display rebuilds the BossesScrollBox dataprovider, but
                -- buttons / overview content aren't laid out until next
                -- frame. Defer so the ejBoss/ejLootTab step that follows
                -- scans a populated list.
                local nextStep = steps[i + 1]
                if nextStep and (nextStep.ejBoss or nextStep.ejLootTab) then
                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ boss: prefer EncounterJournal_DisplayEncounter API when we
            -- have the encounterID. Falls back to ScrollBox button scan.
            if step.ejBoss then
                local displayEncounter = _G["EncounterJournal_DisplayEncounter"]
                if step.ejEncounterID and displayEncounter then
                    pcall(displayEncounter, step.ejEncounterID)
                    RevealEJEncounter(step)
                else
                    local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                    local scrollBox = infoFrame and infoFrame.BossesScrollBox
                    if scrollBox then
                        local targetName = slower(step.ejBoss)
                        Utils.ScrollBoxScrollTo(scrollBox, function(edata)
                            return EncounterDataMatches(edata, step.ejEncounterID, targetName)
                        end)
                        local bossBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            return EncounterFrameMatches(btn, step.ejEncounterID, targetName)
                        end)
                        if bossBtn then ClickButton(bossBtn) end
                    end
                    RevealEJEncounter(step)
                end
                -- ejLootTab needs a frame for the boss content to settle
                -- before we click the loot tab (otherwise Overview eats
                -- the click and the loot list never appears).
                local nextStep = steps[i + 1]
                if nextStep and nextStep.ejLootTab then
                    local resume = i + 1
                    C_Timer.After(0.05, function() executeFrom(resume) end)
                    return
                end
            end

            -- EJ loot tab: click
            if step.ejLootTab then
                if step.ejDifficultyID and ns.Database then
                    ns.Database:SetEJDifficulty(step.ejDifficultyID)
                end
                local lootTab = _G["EncounterJournalEncounterFrameInfoLootTab"]
                if lootTab then ClickButton(lootTab) end
            end

            -- EJ loot item: highlight only (last step)
            if step.ejLootItem and i == executeCount then
                local Highlight = ns.Highlight
                local infoFrame = _G["EncounterJournalEncounterFrameInfo"]
                local scrollBox = infoFrame and (
                    (infoFrame.LootContainer and infoFrame.LootContainer.ScrollBox)
                    or infoFrame.LootScrollBox or infoFrame.ScrollBox
                )
                if scrollBox then
                    local targetID = step.ejLootItem
                    local itemName = step.ejLootItemName
                    C_Timer.After(0.05, function()
                        local itemBtn = Utils.ScrollBoxFindButton(scrollBox, function(btn)
                            local edata = btn.GetElementData and btn:GetElementData()
                            if edata and edata.itemID == targetID then return true end
                            if itemName then
                                local text = Utils.GetButtonText(btn)
                                if text then
                                    local clean = slower(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                                    if clean == slower(itemName) then return true end
                                end
                            end
                            return false
                        end)
                        if itemBtn and Highlight then
                            Highlight:HighlightFrame(itemBtn)
                            local checkHover
                            checkHover = function()
                                if itemBtn:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    C_Timer.After(0.1, checkHover)
                                end
                            end
                            C_Timer.After(0.3, checkHover)
                        end
                    end)
                end
            end

            -- Wardrobe Sets tab: click the Sets tab within WardrobeCollectionFrame.
            -- Defer remaining steps so the SetsCollectionFrame ScrollBox populates.
            if step.wardrobeSetsTab then
                local wcf = _G["WardrobeCollectionFrame"]
                local setsTab = Highlight:GetTabButton("WardrobeCollectionFrame", 2)
                if setsTab then
                    ClickButton(setsTab)
                end
                if wcf then
                    local scf = wcf.SetsCollectionFrame
                    if not scf or not scf:IsShown() then
                        if wcf.SetTab then
                            pcall(wcf.SetTab, wcf, 2)
                        elseif PanelTemplates_SetTab then
                            pcall(PanelTemplates_SetTab, wcf, 2)
                        end
                    end
                end
                if i < executeCount then
                    local resume = i + 1
                    C_Timer.After(0.1, function() executeFrom(resume) end)
                    return
                end
            end

            -- Transmog set: scroll via SetScrollPercentage + select
            if step.transmogSetID and i == executeCount then
                local scf = _G["WardrobeCollectionFrame"]
                    and _G["WardrobeCollectionFrame"].SetsCollectionFrame
                if scf then
                    C_Timer.After(0.1, function()
                        local lc = scf.ListContainer
                        local scrollBox = lc and lc.ScrollBox
                        if scrollBox and scrollBox.SetScrollPercentage then
                            local dp = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
                            if dp then
                                local finder = dp.FindElementDataByPredicate or dp.FindByPredicate
                                local found = finder and finder(dp, function(ed)
                                    return ed and ed.setID == step.transmogSetID
                                end)
                                if found then
                                    local idx = dp.FindIndex and dp:FindIndex(found)
                                    local total = dp.GetSize and dp:GetSize()
                                    if idx and total and total > 1 then
                                        scrollBox:SetScrollPercentage((idx - 1) / (total - 1))
                                    end
                                end
                            end
                        end
                        if lc and lc.SelectElementDataMatchingSetID then
                            pcall(lc.SelectElementDataMatchingSetID, lc, step.transmogSetID)
                        end
                    end)
                end
            end

            -- Currency/faction headers pre-expanded via API, nothing to execute

            if step.currencyID then
                -- No auto-scroll for currencies: the ScrollBox method calls
                -- taint ScrollBar state, which blocks the protected currency
                -- transfer Confirm. The hint + polling in HighlightCurrencyRowOrHint
                -- handles the no-scroll UX (instruction text + auto-highlight
                -- once the row comes into view as the player mousewheels).
                -- Collect ALL ancestor header names in order from outermost
                -- to innermost. Nested currencies need each level expanded
                -- in order; the outermost collapsed one is what to highlight
                -- first because inner headers aren't visible until outer
                -- headers are expanded.
                local headerChain = {}
                for j = 1, i - 1 do
                    if steps[j].currencyHeader then
                        headerChain[#headerChain + 1] = steps[j].currencyHeader
                    end
                end
                if i == executeCount then
                    local cID = step.currencyID
                    local chain = headerChain
                    C_Timer.After(0.05, function()
                        Highlight:HighlightCurrencyRowOrHint(cID, chain)
                    end)
                end
            end

            -- Header-level entry (e.g. "War Within Currencies"): no currencyID,
            -- the last currencyHeader step IS the destination.
            if step.currencyHeader and i == executeCount and not step.currencyID then
                local fullChain = {}
                for j = 1, i do
                    if steps[j].currencyHeader then
                        fullChain[#fullChain + 1] = steps[j].currencyHeader
                    end
                end
                local chain = fullChain
                C_Timer.After(0.05, function()
                    Highlight:HighlightCurrencyRowOrHint(nil, chain)
                end)
            end

            if step.factionID then
                Highlight:ScrollToFactionRow(step.factionID)
                if i == executeCount then
                    local fID = step.factionID
                    C_Timer.After(0.05, function()
                        local factionRow = Highlight:GetFactionRowButton(fID)
                        if factionRow then
                            Highlight:HighlightFrame(factionRow, nil)
                            local checkHover
                            checkHover = function()
                                if factionRow:IsMouseOver() then
                                    Highlight:HideHighlight()
                                else
                                    C_Timer.After(0.1, checkHover)
                                end
                            end
                            C_Timer.After(0.3, checkHover)
                        end
                    end)
                end
            end

            if step.searchButtonText then
                local parentFrame = step.waitForFrame and _G[step.waitForFrame]
                if parentFrame then
                    ClickButton(SearchFrameTreeFuzzy(parentFrame, slower(step.searchButtonText)))
                end
            end
        end

        -- Hand off remaining steps to the guided highlight. DirectOpen
        -- is left-click "open + show me where", not the right-click
        -- guided walkthrough, so flag the data so the highlight ticker
        -- cancels (instead of rewinding to step 1 and reopening) if the
        -- user closes the parent window with the highlight still active.
        if not finalStepNavigable and Highlight then
            data.noCourseCorrect = true
            Highlight:StartGuideAtStep(data, executeCount + 1)
        end
    end

    executeFrom(1)
end

function UI:ClickCharacterSidebar(sidebarIndex)
    -- The sidebar buttons are PaperDollSidebarTab1/2/3 inside PaperDollSidebarTabs
    -- (confirmed via Frame Inspector)

    if not CharacterFrame or not CharacterFrame:IsShown() then
        return false
    end

    -- Switch to the Character tab (tab 1) first
    if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(CharacterFrame) ~= 1 then
        UI:OpenCharacterFrame(1)
    end

    -- Method 1: Try PaperDollSidebarTab buttons directly (Frame Inspector confirmed names)
    local sidebarTab = _G["PaperDollSidebarTab" .. sidebarIndex]
    if sidebarTab then
        if sidebarTab:IsShown() then
            return ClickButton(sidebarTab)
        else
            -- Tab exists but isn't shown yet - try after a brief delay
            C_Timer.After(0.2, function()
                if sidebarTab:IsShown() then ClickButton(sidebarTab) end
            end)
            return true
        end
    end

    -- Method 2: Search PaperDollSidebarTabs container children by index
    local sidebarTabs = _G["PaperDollSidebarTabs"]
    if not sidebarTabs and PaperDollFrame then
        sidebarTabs = PaperDollFrame.SidebarTabs
    end
    if sidebarTabs then
        local nTabs = select("#", sidebarTabs:GetChildren())
        if sidebarIndex <= nTabs then
            return ClickButton(select(sidebarIndex, sidebarTabs:GetChildren()))
        end
    end

    -- Method 3: Try the ToggleSidebarTab function if available
    if PaperDollFrame and PaperDollFrame.ToggleSidebarTab then
        PaperDollFrame:ToggleSidebarTab(sidebarIndex)
        return true
    end

    return false
end

function UI:ClickAchievementCategory(categoryName, categoryID)
    if not AchievementFrame or not AchievementFrame:IsShown() then
        return false
    end

    local numericCategoryID = tonumber(categoryID)
    local categoryNameLower = categoryName and slower(categoryName) or nil
    local function MatchesCategory(data)
        if not data then return false end
        local catID = data.id
        local numericCatID = tonumber(catID)
        if not numericCatID then return false end
        if numericCategoryID then return numericCatID == numericCategoryID end
        if categoryNameLower and GetCategoryInfo then
            local title = GetCategoryInfo(catID)
            if title and slower(title) == categoryNameLower then return true end
        end
        return false
    end

    local function UpdateCategories()
        if AchievementFrameCategories_UpdateDataProvider then
            AchievementFrameCategories_UpdateDataProvider()
        end
    end

    -- Primary: use the data provider to find the category and select it via Blizzard API
    local categoriesFrame = _G["AchievementFrameCategories"]
    if categoriesFrame and categoriesFrame.ScrollBox then
        local scrollBox = categoriesFrame.ScrollBox
        if numericCategoryID and AchievementFrameCategories_ExpandToCategory then
            AchievementFrameCategories_ExpandToCategory(numericCategoryID)
            UpdateCategories()
        end
        local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if dataProvider then
            local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
            if finder then
                local elementData = finder(dataProvider, MatchesCategory)
                if elementData then
                    if elementData.hidden and elementData.id and AchievementFrameCategories_ExpandToCategory then
                        AchievementFrameCategories_ExpandToCategory(tonumber(elementData.id) or elementData.id)
                        UpdateCategories()
                        dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider() or dataProvider
                        finder = dataProvider and (dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate)
                        elementData = finder and finder(dataProvider, MatchesCategory)
                        if not elementData then return false end
                    end
                    -- Try Blizzard's official selection function
                    if AchievementFrameCategories_SelectElementData then
                        if scrollBox.ScrollToElementData then
                            local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
                            pcall(scrollBox.ScrollToElementData, scrollBox, elementData, alignCenter)
                        end
                        local ok = pcall(AchievementFrameCategories_SelectElementData, elementData)
                        if ok then
                            UpdateCategories()
                            return true
                        end
                    end
                    -- Fallback: scroll to it and click the visible button
                    if scrollBox.ScrollToElementData then
                        pcall(scrollBox.ScrollToElementData, scrollBox, elementData)
                    end
                    local frame = scrollBox.FindFrame and scrollBox:FindFrame(elementData)
                    if frame and ClickButton(frame.Button or frame) then return true end
                end
            end
        end

        local frame = Utils.ScrollBoxFindButton(scrollBox, function(btn)
            local data = btn.GetElementData and btn:GetElementData()
            return MatchesCategory(data)
        end)
        if frame and ClickButton(frame.Button or frame) then return true end

    end

    return false
end

-- Achievement watch/tracking. Modern WoW (Midnight) routes achievement
-- tracking through C_ContentTracking with Enum.ContentTrackingType
-- .Achievement. Older clients exposed top-level
-- IsTrackedAchievement / AddTrackedAchievement /
-- RemoveTrackedAchievement. We try the modern API first then fall back.
local function GetAchievementContentType()
    if Enum and Enum.ContentTrackingType
       and Enum.ContentTrackingType.Achievement ~= nil then
        return Enum.ContentTrackingType.Achievement
    end
    return nil
end

function UI:IsAchievementTracked(achievementID)
    if not achievementID then return false end
    local ct = GetAchievementContentType()
    if ct ~= nil and C_ContentTracking and C_ContentTracking.IsTracking then
        local ok, tracked = pcall(C_ContentTracking.IsTracking, ct, achievementID)
        if ok then return tracked and true or false end
    end
    local fn = _G["IsTrackedAchievement"]
    if fn then
        local ok, tracked = pcall(fn, achievementID)
        if ok then return tracked and true or false end
    end
    return false
end

function UI:ToggleAchievementTracked(achievementID)
    if not achievementID then return end
    local tracked = self:IsAchievementTracked(achievementID)
    local ct = GetAchievementContentType()
    if ct ~= nil and C_ContentTracking and C_ContentTracking.StartTracking then
        if tracked then
            -- StopTracking REQUIRES a third arg (Enum.ContentTrackingStopType);
            -- omitting it causes the call to silently no-op. .User is the
            -- "user clicked to stop tracking" reason.
            local stopType = (Enum and Enum.ContentTrackingStopType
                              and Enum.ContentTrackingStopType.User) or 0
            pcall(C_ContentTracking.StopTracking, ct, achievementID, stopType)
        else
            pcall(C_ContentTracking.StartTracking, ct, achievementID)
        end
        return
    end
    if tracked then
        local stop = _G["RemoveTrackedAchievement"]
        if stop then pcall(stop, achievementID) end
    else
        local start = _G["AddTrackedAchievement"]
        if start then pcall(start, achievementID) end
    end
end

-- Pet (battle pet) right-click actions. petID here is a Blizzard pet
-- GUID string returned by GetPetInfoByIndex / similar, NOT a numeric
-- speciesID. All wrappers no-op gracefully when the pet APIs aren't
-- available.
function UI:SummonPet(petID)
    if petID and C_PetJournal and C_PetJournal.SummonPetByGUID then
        pcall(C_PetJournal.SummonPetByGUID, petID)
    end
end

local function NormalizePetFavorite(value)
    return value == true or value == 1
end

local function ReadPetFavoriteFromJournal(petID)
    if not petID or not C_PetJournal then return nil end
    if C_PetJournal.GetPetInfoByPetID then
        local ok, _, _, _, _, _, _, isFavorite = pcall(C_PetJournal.GetPetInfoByPetID, petID)
        if ok and isFavorite ~= nil then return NormalizePetFavorite(isFavorite) end
    end
    if C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
        local total = C_PetJournal.GetNumPets()
        for i = 1, total or 0 do
            local pid, _, _, _, _, isFavorite = C_PetJournal.GetPetInfoByIndex(i)
            if pid == petID then return NormalizePetFavorite(isFavorite) end
        end
    end
    return nil
end

local function ReconcilePetFavoriteOverride(petID, expected, attemptsLeft)
    if not petID or UI:GetPetFavoriteOverrides()[petID] ~= expected then return end
    local actual = ReadPetFavoriteFromJournal(petID)
    if actual == expected then
        UI:GetPetFavoriteOverrides()[petID] = nil
        if UI and UI.RefreshResults then UI:RefreshResults() end
        return
    end
    if attemptsLeft and attemptsLeft > 0 and C_Timer and C_Timer.After then
        C_Timer.After(0.15, function()
            ReconcilePetFavoriteOverride(petID, expected, attemptsLeft - 1)
        end)
    end
end

function UI:IsPetFavorite(petID)
    if not petID then return false end
    if UI:GetPetFavoriteOverrides()[petID] ~= nil then
        return UI:GetPetFavoriteOverrides()[petID]
    end
    local favorite = ReadPetFavoriteFromJournal(petID)
    return favorite == true
end

function UI:TogglePetFavorite(petID)
    if not petID or not C_PetJournal or not C_PetJournal.SetFavorite then return end
    local fav = self:IsPetFavorite(petID)
    local newFav = not fav
    local ok = pcall(C_PetJournal.SetFavorite, petID, newFav and 1 or 0)
    if ok then
        UI:GetPetFavoriteOverrides()[petID] = newFav
    end
    if self.RefreshResults and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if UI and UI.RefreshResults then UI:RefreshResults() end
        end)
        C_Timer.After(0.15, function()
            ReconcilePetFavoriteOverride(petID, newFav, 8)
        end)
    end
end

-- Returns true when the pet is cage-eligible (tradeable). Blizzard's
-- context menu shows "Put In Cage" for these and "Release" for the
-- rest; we mirror that distinction so the user gets the same affordance.
function UI:IsPetCageable(petID)
    if not petID or not C_PetJournal then return false end
    if C_PetJournal.PetIsTradable then
        local ok, val = pcall(C_PetJournal.PetIsTradable, petID)
        if ok then return val and true or false end
    end
    return false
end

function UI:CagePet(petID)
    if not petID or not C_PetJournal or not C_PetJournal.CagePetByID then return end
    pcall(C_PetJournal.CagePetByID, petID)
end

function UI:ReleasePet(petID)
    if not petID or not C_PetJournal or not C_PetJournal.ReleasePetByID then return end
    StaticPopup_Show("EASYFIND_PET_RELEASE_CONFIRM", nil, nil, petID)
end

StaticPopupDialogs["EASYFIND_PET_RELEASE_CONFIRM"] = {
    text = "Are you sure you want to permanently release this pet? This cannot be undone.",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, petID)
        if petID and C_PetJournal and C_PetJournal.ReleasePetByID then
            pcall(C_PetJournal.ReleasePetByID, petID)
        end
    end,
}

function UI:RenamePet(petID)
    if not petID then return end
    local popup = StaticPopup_Show("EASYFIND_PET_RENAME", nil, nil, petID)
    UI:LiftPopupStrata(popup or UI:FindPopupSlot("EASYFIND_PET_RENAME"))
end

StaticPopupDialogs["EASYFIND_PET_RENAME"] = {
    text = "New name for this pet:",
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 16,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    OnShow = function(self, petID)
        local eb = self.editBox or self.EditBox
        if not eb then return end
        local existing = ""
        if petID and C_PetJournal and C_PetJournal.GetPetInfoByPetID then
            local ok, _, customName, _, _, _, _, _, name = pcall(C_PetJournal.GetPetInfoByPetID, petID)
            if ok then existing = customName or name or "" end
        end
        eb:SetText(existing)
        eb:HighlightText()
        eb:SetFocus()
    end,
    OnAccept = function(self, petID)
        local eb = self.editBox or self.EditBox
        local txt = eb and eb:GetText() or ""
        if petID and C_PetJournal and C_PetJournal.SetCustomName then
            pcall(C_PetJournal.SetCustomName, petID, txt)
        end
    end,
}

-- Transmog (appearance) set favorite toggle. The favorite flag lives on
-- the BASE set (not the per-class / per-difficulty variants), so we
-- always resolve to the base ID before reading or writing. Without this
-- step, SetIsFavorite is a silent no-op when called with a variant ID.
local function ResolveTransmogBaseSetID(setID)
    if not setID or not C_TransmogSets then return setID end
    if C_TransmogSets.GetBaseSetID then
        local ok, baseID = pcall(C_TransmogSets.GetBaseSetID, setID)
        if ok and baseID and baseID ~= 0 then return baseID end
    end
    return setID
end

function UI:IsTransmogSetFavorite(setID)
    if not setID or not C_TransmogSets then return false end
    local baseID = ResolveTransmogBaseSetID(setID)
    if C_TransmogSets.GetIsFavorite then
        local ok, fav = pcall(C_TransmogSets.GetIsFavorite, baseID)
        if ok and fav then return true end
    end
    if C_TransmogSets.GetSetInfo then
        local ok, info = pcall(C_TransmogSets.GetSetInfo, baseID)
        if ok and type(info) == "table" and info.favoriteSetID then return true end
        if ok and type(info) == "table" and info.favorite then return true end
    end
    return false
end

function UI:ToggleTransmogSetFavorite(setID)
    if not setID or not C_TransmogSets then return end
    local baseID = ResolveTransmogBaseSetID(setID)
    local fav = self:IsTransmogSetFavorite(baseID)
    if C_TransmogSets.SetIsFavorite then
        pcall(C_TransmogSets.SetIsFavorite, baseID, not fav)
    elseif C_TransmogSets.MarkSetFavorite then
        pcall(C_TransmogSets.MarkSetFavorite, baseID, not fav)
    end
end

-- Backpack-tracker toggle for currencies. Mirrors what the in-game
-- "Show on backpack" checkbox in the Currency tab does.
function UI:IsCurrencyOnBackpack(currencyID)
    if not currencyID or currencyID == 0 or not C_CurrencyInfo then return false end
    -- The enumeration list is authoritative. The CurrencyInfo struct's
    -- `isShowInBackpack` flag in modern builds indicates *capability*
    -- (the currency is allowed to be tracked), not current state, so
    -- using it always read as on, the toggle always tried to add, and
    -- removal silently no-op'd.
    local getInfo = C_CurrencyInfo.GetBackpackCurrencyInfo
    if getInfo then
        local cap = (_G["MAX_WATCHED_TOKENS"]) or 3
        for i = 1, cap do
            local bok, bi = pcall(getInfo, i)
            if not bok or type(bi) ~= "table" then break end
            local id = bi.currencyTypesID or bi.currencyID
            -- Require a non-zero ID match. Some clients return a
            -- placeholder table for unused tracker slots with id=0 /
            -- name="" / nil quantity instead of returning nil; without
            -- this guard, comparing against currencyID still works but
            -- we'd false-positive if the caller ever passed 0 or nil
            -- through (defended above): keep the explicit check so a
            -- future mistake at a call site can't bite.
            if id and id ~= 0 and id == currencyID then return true end
        end
        return false
    end
    -- Fallback for builds that don't expose the enumeration: trust the
    -- inline flag from GetCurrencyInfo.
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or type(info) ~= "table" then return false end
    return info.isShowInBackpack and true or false
end

-- Force a dropdown's trigger label to re-read its IsSelected callback.
-- Modern WowDropdownMenu builds the displayed selection text inside
-- SetupMenu's generator; calling GenerateMenu rebuilds and re-evaluates.
local function RefreshDropdownLabel(dropdown)
    if not dropdown then return end
    if dropdown.GenerateMenu then pcall(dropdown.GenerateMenu, dropdown)
    elseif dropdown.RefreshMenu then pcall(dropdown.RefreshMenu, dropdown)
    elseif dropdown.SignalUpdate then pcall(dropdown.SignalUpdate, dropdown) end
end

-- Currency filter. API: C_CurrencyInfo.SetCurrencyFilter(filterType).
-- DiscoveredAndAllAccountTransferable = "warband"; DiscoveredOnly = "all".
function UI:ApplyTokenFrameFilter(mode)
    if not mode or not C_CurrencyInfo or not C_CurrencyInfo.SetCurrencyFilter then return end
    if not Enum or not Enum.CurrencyFilterType then return end
    local target = (mode == "warband")
        and Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable
        or  Enum.CurrencyFilterType.DiscoveredOnly
    local current = C_CurrencyInfo.GetCurrencyFilter and C_CurrencyInfo.GetCurrencyFilter()
    if current == target then return end
    -- Mirror Blizzard's SetFilterTypeSelected: clear in-flight selection
    -- so the popup doesn't try to render a row that no longer exists.
    if TokenFrame then
        TokenFrame.selectedToken = nil
        TokenFrame.selectedID = nil
    end
    if TokenFramePopup and TokenFramePopup.Hide then TokenFramePopup:Hide() end
    pcall(C_CurrencyInfo.SetCurrencyFilter, target)
    if TokenFrame and TokenFrame:IsShown() then
        if TokenFrame.Update then pcall(TokenFrame.Update, TokenFrame) end
        RefreshDropdownLabel(TokenFrame.filterDropdown)
    end
end

-- Reputation sort type. API: C_Reputation.SetReputationSortType(sortType).
-- None = "all"; Account = "warband"; Character = "char".
function UI:ApplyReputationFilter(mode)
    if not mode or not C_Reputation or not C_Reputation.SetReputationSortType then return end
    if not Enum or not Enum.ReputationSortType then return end
    local sortType
    if mode == "warband" then
        sortType = Enum.ReputationSortType.Account
    elseif mode == "char" then
        sortType = Enum.ReputationSortType.Character
    else
        sortType = Enum.ReputationSortType.None
    end
    local current = C_Reputation.GetReputationSortType and C_Reputation.GetReputationSortType()
    if current == sortType then return end
    pcall(C_Reputation.SetReputationSortType, sortType)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

-- Show Legacy Reputations. API: C_Reputation.SetLegacyReputationsShown(bool).
function UI:ApplyReputationShowLegacy(show)
    if not C_Reputation or not C_Reputation.SetLegacyReputationsShown then return end
    show = show and true or false
    local current = C_Reputation.AreLegacyReputationsShown and C_Reputation.AreLegacyReputationsShown()
    if current == show then return end
    pcall(C_Reputation.SetLegacyReputationsShown, show)
    if ReputationFrame and ReputationFrame:IsShown() then
        if ReputationFrame.Update then pcall(ReputationFrame.Update, ReputationFrame) end
        RefreshDropdownLabel(ReputationFrame.filterDropdown)
    end
end

-- Hide Passives. CVar-backed: spellBookHidePassives ("0" / "1").
-- Mirrors SpellBookFrameMixin:SetupSettingsDropdown's SetSelected logic.
function UI:ApplySpellBookHidePassives(hide)
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
-- in-game UI updates our flyout state. The popup syncs from DB on
-- next show, so we don't need to refresh anything live.
function UI:HookBlizzardFilterChanges()
    if C_CurrencyInfo and C_CurrencyInfo.SetCurrencyFilter and Enum and Enum.CurrencyFilterType then
        hooksecurefunc(C_CurrencyInfo, "SetCurrencyFilter", function(filterType)
            local mode = (filterType == Enum.CurrencyFilterType.DiscoveredAndAllAccountTransferable)
                and "warband" or "all"
            if EasyFind.db and EasyFind.db.currencyFilterMode ~= mode then
                EasyFind.db.currencyFilterMode = mode
            end
        end)
    end
    if C_Reputation and C_Reputation.SetReputationSortType and Enum and Enum.ReputationSortType then
        hooksecurefunc(C_Reputation, "SetReputationSortType", function(sortType)
            local mode
            if sortType == Enum.ReputationSortType.Account then mode = "warband"
            elseif sortType == Enum.ReputationSortType.Character then mode = "char"
            else mode = "all" end
            if EasyFind.db and EasyFind.db.reputationFilterMode ~= mode then
                EasyFind.db.reputationFilterMode = mode
            end
        end)
    end
    if C_Reputation and C_Reputation.SetLegacyReputationsShown then
        hooksecurefunc(C_Reputation, "SetLegacyReputationsShown", function(show)
            show = show and true or false
            if EasyFind.db and EasyFind.db.showLegacyReputations ~= show then
                EasyFind.db.showLegacyReputations = show
            end
        end)
    end
    -- Hide Passives is CVar-backed; CVAR_UPDATE fires on any change.
    local cvarFrame = CreateFrame("Frame")
    cvarFrame:RegisterEvent("CVAR_UPDATE")
    cvarFrame:SetScript("OnEvent", function(_, _, name, value)
        if not name then return end
        local n = slower(name)
        if n == "spellbookhidepassives" then
            local hide = value == "1" or value == 1 or value == true
            if EasyFind.db and EasyFind.db.abilityHidePassives ~= hide then
                EasyFind.db.abilityHidePassives = hide
            end
        end
    end)
end

function UI:ToggleCurrencyBackpack(currencyID)
    if not currencyID or not C_CurrencyInfo then return end
    local on = self:IsCurrencyOnBackpack(currencyID)
    local target = not on

    -- Backpack tracker caps at 3. When the user tries to ADD a fourth,
    -- raise the same red UIErrorsFrame message Blizzard's default UI
    -- shows instead of silently dropping the call.
    if target and C_CurrencyInfo.GetBackpackCurrencyInfo then
        local cap = (_G["MAX_WATCHED_TOKENS"]) or 3
        local count = 0
        for i = 1, cap + 1 do
            local bok, bi = pcall(C_CurrencyInfo.GetBackpackCurrencyInfo, i)
            if not bok or type(bi) ~= "table" then break end
            count = count + 1
        end
        if count >= cap then
            local msg = (_G["TOKEN_BACKPACK_FULL_MESSAGE"])
                or string.format("You may only watch %d currencies at a time", cap)
            local errFrame = _G["UIErrorsFrame"]
            if errFrame and errFrame.AddMessage then
                errFrame:AddMessage(msg, 1.0, 0.1, 0.1, 1.0)
            end
            return
        end
    end

    -- SetCurrencyBackpackByID takes a currency ID directly. The older
    -- SetCurrencyBackpack takes a *list index* (which is why it
    -- silently no-op'd / hit the wrong currency when called with an
    -- ID). Prefer the by-ID variant when available.
    if C_CurrencyInfo.SetCurrencyBackpackByID then
        pcall(C_CurrencyInfo.SetCurrencyBackpackByID, currencyID, target)
    elseif C_CurrencyInfo.SetCurrencyBackpack then
        pcall(C_CurrencyInfo.SetCurrencyBackpack, currencyID, target)
    end

    -- Force the visible backpack token strip to refresh now. The
    -- SetCurrency* call updates state but doesn't always notify the
    -- ContainerFrame's token row when the bag is already open, so the
    -- user sees stale icons until they close and reopen. Call every
    -- update entry-point we know about; whichever exists in this
    -- client wins, the rest no-op.
    local candidates = {
        _G["BackpackTokenFrame"],
        _G["BackpackTokenFrame_Update"],
    }
    for _, c in ipairs(candidates) do
        if type(c) == "function" then
            pcall(c)
        elseif type(c) == "table" then
            if c.Update then pcall(c.Update, c) end
            if c.UpdateTokens then pcall(c.UpdateTokens, c) end
        end
    end
    -- Container frames host the token row in modern bag UI. Iterate
    -- the standard ContainerFrame1..N looking for an Update method.
    for i = 1, 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf.Update then pcall(cf.Update, cf) end
        local tokenFrame = cf and cf.tokenFrame
        if tokenFrame and tokenFrame.Update then
            pcall(tokenFrame.Update, tokenFrame)
        end
    end
end

function UI:IsCurrencyTransferable(currencyID)
    return ns.Database and ns.Database.IsCurrencyAccountTransferable
       and ns.Database:IsCurrencyAccountTransferable(currencyID) or false
end

-- Open the Currency tab and walk the live transfer flow: SelectResult only
-- opens the tab and highlights the row, but the Transfer button lives in
-- TokenFramePopup, which appears only once the currency row is clicked. So
-- click the row, then its Transfer toggle, which opens CurrencyTransferMenu.
function UI:RouteCurrencyTransfer(pinData)
    if not pinData then return end
    local currencyID = pinData.currencyID
    -- Keep the currency-row highlight persistent (no hover-dismiss) because
    -- it's an intermediate step here -- the destination is the Transfer
    -- button on the popup, not the row itself.
    if ns.Highlight and ns.Highlight.SetPersistentCurrencyHighlight then
        ns.Highlight:SetPersistentCurrencyHighlight(true)
    end
    self:SelectResult(pinData)
    if not (currencyID and Utils and Utils.SafeAfter and ns.Highlight) then return end

    -- Auto-clicking the currency row taints the final transfer call, so we
    -- let the player click it; then we move the highlight to Transfer.
    local highlightDone = false
    local function watchForPopup(remaining)
        if highlightDone then return end
        local popup = _G["TokenFramePopup"]
        local btn = popup and popup.CurrencyTransferToggleButton
        if popup and popup:IsShown() and btn and btn:IsShown() then
            highlightDone = true
            ns.Highlight:StartGuide({
                steps = { { buttonFrame = "TokenFramePopup.CurrencyTransferToggleButton" } }
            })
            return
        end
        if remaining > 0 then
            Utils.SafeAfter(0.2, function() watchForPopup(remaining - 1) end)
        end
    end
    Utils.SafeAfter(0.2, function() watchForPopup(50) end)
end

-- Open the AchievementFrame to a specific achievement. Tries Blizzard's
-- modern OpenAchievementFrameToAchievement first; falls back to the
-- legacy AchievementFrame_SelectAchievement; finally just shows the
-- frame so the user can find it manually.
function UI:OpenAchievementByID(achievementID)
    if not achievementID then return end
    if _G["AchievementFrame_LoadUI"] then
        pcall(_G["AchievementFrame_LoadUI"])
    end
    local frame = _G["AchievementFrame"]
    if frame and not frame:IsShown() and ShowUIPanel then
        UI:SecureShowUIPanel(frame)
    end
    local opener = _G["OpenAchievementFrameToAchievement"]
    if opener then
        pcall(opener, achievementID)
        return
    end
    local selector = _G["AchievementFrame_SelectAchievement"]
    if selector then
        pcall(selector, achievementID)
    end
end

-- OPEN MACRO FRAME AT SLOT
-- Midnight's MacroFrame has no SelectionBehavior; the slot ScrollBox
-- holds buttons whose elementData is a plain integer (slot index within
-- the tab). Scroll the slot into view, then walk visible frames and
-- Click() the one whose elementData matches -- this fires the same
-- internal selection path the user's mouse click would.
function UI:OpenMacroFrameAt(macroIdx, isChar)
    if C_AddOns and C_AddOns.LoadAddOn then
        C_AddOns.LoadAddOn("Blizzard_MacroUI")
    elseif LoadAddOn then
        LoadAddOn("Blizzard_MacroUI")
    end
    if ShowMacroFrame then ShowMacroFrame() end
    local tabIdx = isChar and 2 or 1
    local slotInTab = isChar
        and (macroIdx - (MAX_ACCOUNT_MACROS or 120))
        or macroIdx
    local function clickSlot()
        local mf = MacroFrame
        if not mf or not mf:IsShown() then return false end
        local tabBtn = _G["MacroFrameTab" .. tabIdx]
        if tabBtn and tabBtn.Click and (mf.selectedTab or 1) ~= tabIdx then
            tabBtn:Click()
        end
        local sb = mf.MacroSelector and mf.MacroSelector.ScrollBox
        if not sb or not sb.ForEachFrame then return false end
        if sb.ScrollToElementDataIndex then
            sb:ScrollToElementDataIndex(slotInTab)
        end
        local clicked = false
        sb:ForEachFrame(function(btn)
            if clicked then return true end
            local ed = btn.GetElementData and btn:GetElementData()
            if ed == slotInTab then
                if btn.Click then btn:Click() end
                clicked = true
                return true
            end
        end)
        return clicked
    end
    if not clickSlot() then
        C_Timer.After(0, function()
            if not clickSlot() then
                C_Timer.After(0.1, function()
                    if not clickSlot() then
                        C_Timer.After(0.3, clickSlot)
                    end
                end)
            end
        end)
    end
end
