local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local L = ns.L
local sformat = ns.Utils.sformat

-- Prompt the user for an alias text and bind it to `data`.
function Handlers:PromptForAlias(data)
    if not data then return end
    local label = data.name or L["ALIAS_THIS_ENTRY"]
    ns.ShowThemedDialog({
        text = (L["PROMPT_ALIAS_FOR"]):format(label),
        hasEditBox = true,
        maxLetters = 64,
        onAccept = function(txt)
            txt = strtrim(txt or "")
            if txt == "" then return end
            if ns.Aliases and ns.Aliases:Add(txt, data) then
                local targetName = data.name or L["ALIAS_THIS_ENTRY"]
                if EasyFind and EasyFind.Print and EasyFind.db
                   and EasyFind.db.showAliasMessages ~= false then
                    EasyFind:Print(sformat(L["ALIAS_ADDED_MSG"], txt, targetName))
                end
                local searchFrame = Search:GetSearchFrame()
                local searchEditBox = searchFrame and searchFrame.editBox
                local current = searchEditBox and searchEditBox:GetText() or ""
                if current ~= "" then Search:OnSearchTextChanged(current) end
            end
        end,
    })
end
