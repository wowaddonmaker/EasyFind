local _, ns = ...

local Search = ns.Search
local History = ns.SearchHistory
local Utils = ns.Utils

local tinsert, tremove = Utils.tinsert, Utils.tremove

-- Shell-style search history. Index 0 is the live buffer; positive
-- indexes walk toward older saved queries.
local historyIndex = 0
local historyDraft = ""
-- True only during the synchronous OnSearchTextChanged call inside
-- NavigateSearchHistory, so render/navigation code can keep an active
-- nav-repeat ticker alive through the history-recall re-render.
local preservingNavRepeat = false

function History:IsPreservingNavRepeat()
    return preservingNavRepeat
end

function History:ResetSearchHistory()
    historyIndex = 0
    historyDraft = ""
end

function History:IsSearchHistoryActive()
    return historyIndex > 0
end

function History:PushSearchHistory(text)
    if not EasyFind.db then return end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" then
        hist = {}
        EasyFind.db.uiSearchHistory = hist
    end
    local lower = text:lower()
    for i = #hist, 1, -1 do
        if hist[i] and hist[i]:lower() == lower then
            tremove(hist, i)
        end
    end
    tinsert(hist, 1, text)
    local limit = EasyFind.db.uiSearchHistoryLimit or 500
    while #hist > limit do tremove(hist) end
end

function History:NavigateSearchHistory(direction)
    if not EasyFind.db then return false end
    local hist = EasyFind.db.uiSearchHistory
    if type(hist) ~= "table" or #hist == 0 then return false end
    local editBox = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
    if not editBox then return false end

    -- Capture the user's in-flight buffer the first time we step away
    -- from index 0 so DOWN-back-to-0 restores it instead of clobbering
    -- their typing.
    if historyIndex == 0 and direction > 0 then
        historyDraft = editBox:GetText() or ""
    end

    local newIndex = historyIndex + direction
    if newIndex < 0 then return false end
    if newIndex > #hist then newIndex = #hist end
    if newIndex == historyIndex then return false end

    historyIndex = newIndex
    local newText = (newIndex == 0) and (historyDraft or "") or (hist[newIndex] or "")
    -- If alt-nav is locking the editbox via SetMaxLetters (see the
    -- SearchBar OnKeyDown alt+J/K branch), the limit will reject our
    -- SetText. Raise the limit, SetText, then re-lock at the new length
    -- so OS auto-repeat still can't append.
    local altNavLocked = editBox._altNavMaxLettersSaved ~= nil
    if altNavLocked then editBox:SetMaxLetters(0) end
    editBox:SetText(newText)
    if altNavLocked then editBox:SetMaxLetters(#editBox:GetText()) end
    editBox:SetCursorPosition(#editBox:GetText())
    -- Programmatic SetText fires OnTextChanged with userInput=false, which
    -- the OnTextChanged hook now ignores (so the autocomplete suffix can't
    -- feed back into the search query). History nav still wants a fresh
    -- result render for the recalled query, so kick it manually.
    local searchFrame = Search:GetSearchFrame()
    preservingNavRepeat = (searchFrame and searchFrame.IsAltNavRepeatKey
        and searchFrame.IsAltNavRepeatKey()) or false
    Search:OnSearchTextChanged(Search:GetTypedQuery(), true)
    preservingNavRepeat = false
    return true
end
