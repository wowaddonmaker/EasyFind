local _, ns = ...

local Search = ns.Search
local Handlers = ns.ResultHandlers
local L = ns.L
local sformat = ns.Utils.sformat

-- Prompt the user for an alias text and bind it to `data`. Map rows whose
-- category the map search knows can widen the binding to the WHOLE category
-- via the dialog checkbox ("fm" -> nearest flight masters), the same way a
-- launcher alias can point at a scoped search instead of one item.
function Handlers:PromptForAlias(data)
    if not data then return end
    local label = data.name or L["ALIAS_THIS_ENTRY"]
    local canCategory = data.mapSearchResult and data.category
        and ns.MapSearchData and ns.MapSearchData.CATEGORIES
        and ns.MapSearchData.CATEGORIES[data.category] and true or false
    -- Name the category on the checkbox and in the stored alias, so the
    -- user knows the binding covers "Flight Paths", not just this one spot.
    local catLabel = canCategory and ns.Filters and ns.Filters.MapCategoryFilterLabel
        and ns.Filters.MapCategoryFilterLabel(data.category)
    local checkText
    if canCategory then
        checkText = catLabel and sformat(L["ALIAS_WHOLE_CATEGORY_CHECK"], catLabel)
            or L["ALIAS_WHOLE_CATEGORY_GENERIC"]
    end
    ns.ShowThemedDialog({
        text = (L["PROMPT_ALIAS_FOR"]):format(label),
        -- With the category checkbox ticked, the header must name the
        -- category, not the row that opened the dialog -- the alias no
        -- longer targets that one spot.
        textChecked = canCategory
            and (L["PROMPT_ALIAS_FOR_CATEGORY"]):format(catLabel or data.category) or nil,
        messageColor = ns.GOLD_COLOR,
        hasEditBox = true,
        maxLetters = 64,
        checkText = checkText,
        onAccept = function(txt, wholeCategory)
            txt = strtrim(txt or "")
            if txt == "" then return end
            local added, targetName
            if canCategory and wholeCategory then
                targetName = sformat(L["ALIAS_CATEGORY_LABEL"], catLabel or data.name or data.category)
                added = ns.Aliases and ns.Aliases:AddCategory(txt, data.category, targetName)
            else
                targetName = label
                added = ns.Aliases and ns.Aliases:Add(txt, data)
            end
            if added then
                if EasyFind and EasyFind.Print and EasyFind.db
                   and EasyFind.db.showAliasMessages ~= false then
                    EasyFind:Print(sformat(L["ALIAS_ADDED_MSG"], txt, targetName))
                end
                local searchFrame = Search:GetSearchFrame()
                local searchEditBox = searchFrame and searchFrame.editBox
                local current = searchEditBox and searchEditBox:GetText() or ""
                if current ~= "" then Search:OnSearchTextChanged(current) end
                if ns.RefreshBindTables then ns.RefreshBindTables() end
            end
        end,
    })
end
