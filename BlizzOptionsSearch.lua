-- Blizzard Settings panel search. Walks Settings.GetCategoryList()
-- after the system frames have loaded and registers each category /
-- sub-category as a searchable Database entry. Selecting a hit opens
-- the Settings panel to that category via Settings.OpenToCategory.
--
-- Retail (10.0.2+) replaced the old InterfaceOptions tree with a flat
-- registry under Settings.*, so this file targets that API only.
-- Classic builds will simply skip registration when Settings is nil.

local _, ns = ...
local BlizzOptionsSearch = {}
ns.BlizzOptionsSearch = BlizzOptionsSearch

local Utils = ns.Utils
local tinsert = Utils.tinsert
local slower = Utils.slower
local SafeAfter = Utils.SafeAfter

-- Stable category-name -> id table built when the search runs. Used
-- by step handlers to translate the entry's stashed name back into
-- the live category ID (which can change between sessions).
local function GetCategoryID(name)
    if not Settings or not Settings.GetCategoryList then return nil end
    local list = Settings.GetCategoryList()
    if type(list) ~= "table" then return nil end
    for _, cat in ipairs(list) do
        if cat and cat.GetName and cat:GetName() == name then
            if cat.GetID then return cat:GetID() end
        end
    end
    return nil
end

-- Open the Settings panel to a given category by name.
local function OpenSettingsByName(name)
    local id = GetCategoryID(name)
    if not id then return false end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(id)
        return true
    end
    return false
end
BlizzOptionsSearch.OpenSettingsByName = OpenSettingsByName

-- Collect name/path entries from the live Settings registry. Each
-- entry stores the category and sub-category names so we can resolve
-- the live category ID at click time.
local function CollectEntries()
    local entries = {}
    if not Settings or not Settings.GetCategoryList then return entries end
    local list = Settings.GetCategoryList()
    if type(list) ~= "table" then return entries end

    for _, cat in ipairs(list) do
        if cat and cat.GetName then
            local catName = cat:GetName()
            if catName and catName ~= "" then
                local catNameLower = slower(catName)
                local catKw = { "settings", "options", catNameLower }
                tinsert(entries, {
                    name = catName,
                    nameLower = catNameLower,
                    keywords = catKw,
                    keywordsLower = catKw,
                    category = "Game Settings",
                    icon = 134399,  -- Interface\\Icons\\Trade_Engineering (gear-ish)
                    settingsCategory = catName,
                    -- A no-op steps[] keeps the entry in the
                    -- "guideable" code path; the real work happens
                    -- in the click handler that calls OpenSettingsByName.
                    steps = { { settingsCategory = catName } },
                })

                -- Sub-categories show as their own entries with the
                -- parent name in the path so search results read like
                -- "Combat > Self Highlight" instead of just "Self
                -- Highlight" with no context.
                if cat.GetSubcategories then
                    local subs = cat:GetSubcategories()
                    if type(subs) == "table" then
                        for _, sub in ipairs(subs) do
                            if sub and sub.GetName then
                                local subName = sub:GetName()
                                if subName and subName ~= "" then
                                    local subNameLower = slower(subName)
                                    local subKw = { "settings", "options", subNameLower, catNameLower }
                                    tinsert(entries, {
                                        name = subName,
                                        nameLower = subNameLower,
                                        keywords = subKw,
                                        keywordsLower = subKw,
                                        category = "Game Settings",
                                        path = { "Game Settings", catName },
                                        icon = 134399,
                                        settingsCategory = subName,
                                        steps = { { settingsCategory = subName } },
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return entries
end

-- Register the collected entries into the Database. Called once
-- after PLAYER_LOGIN so Settings.* is fully populated.
function BlizzOptionsSearch:Populate()
    if not ns.Database or not ns.Database.uiSearchData then return end
    local entries = CollectEntries()
    local data = ns.Database.uiSearchData
    for i = 1, #entries do
        tinsert(data, entries[i])
    end
end

-- Step handler: open the Settings panel to a category by name. The
-- Highlight engine looks for a `settingsCategory` field on a step and
-- routes here when found.
function BlizzOptionsSearch:HandleStep(step)
    if not step or not step.settingsCategory then return false end
    return OpenSettingsByName(step.settingsCategory)
end

-- Schedule registration after PLAYER_LOGIN so Settings.GetCategoryList
-- has the full tree (some addons register late). Two passes catch
-- any stragglers that register on first frame.
local registered = false
local function Register()
    if registered then return end
    registered = true
    BlizzOptionsSearch:Populate()
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    SafeAfter(0.5, Register)
    SafeAfter(3.0, function()
        -- Re-collect after a longer delay to pick up addons that
        -- register their settings categories during the first few
        -- seconds. Uses a name-based dedupe so we don't double up.
        local seen = {}
        for _, e in ipairs(ns.Database.uiSearchData or {}) do
            if e.settingsCategory then seen[e.settingsCategory] = true end
        end
        local fresh = CollectEntries()
        for _, e in ipairs(fresh) do
            if not seen[e.settingsCategory] then
                tinsert(ns.Database.uiSearchData, e)
            end
        end
    end)
end)
