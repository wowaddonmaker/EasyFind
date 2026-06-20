local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local L = ns.L
local sformat = ns.Utils.sformat

-- Prompt the user for an alias text and bind it to `data`.
StaticPopupDialogs["EASYFIND_ADD_ALIAS"] = {
    text = L["PROMPT_ALIAS_FOR"],
    button1 = ACCEPT or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    maxLetters = 64,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    enterClicksFirstButton = true,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if eb then
            eb:SetText("")
            eb:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local eb = self.editBox or self.EditBox
        local txt = eb and eb:GetText() or ""
        if strtrim(txt) == "" then return end
        if ns.Aliases and ns.Aliases:Add(txt, data) then
            local aliasText = strtrim(txt)
            local targetName = data and data.name or L["ALIAS_THIS_ENTRY"]
            if EasyFind and EasyFind.Print and EasyFind.db and EasyFind.db.showAliasMessages ~= false then
                EasyFind:Print(sformat(L["ALIAS_ADDED_MSG"], aliasText, targetName))
            end
            local searchFrame = Search:GetSearchFrame()
            local searchEditBox = searchFrame and searchFrame.editBox
            local current = searchEditBox and searchEditBox:GetText() or ""
            if current ~= "" then Search:OnSearchTextChanged(current) end
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        if parent.button1 then parent.button1:Click() end
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
}

function Handlers:PromptForAlias(data)
    if not data then return end
    local label = data.name or L["ALIAS_THIS_ENTRY"]
    local dialog = StaticPopup_Show("EASYFIND_ADD_ALIAS", label, nil, data)
    if dialog then
        dialog:SetFrameStrata("TOOLTIP")
        dialog:SetFrameLevel(1000)
    end
end
