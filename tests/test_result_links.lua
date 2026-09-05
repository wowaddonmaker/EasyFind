-- Tests for Shared/ResultLinks.lua: which rows may be shared as an
-- EasyFind link, and the plain-text form that goes over chat.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
H.loadModule("Shared/Aliases.lua", env, ns)
local ResultLinks = H.loadModule("Shared/ResultLinks.lua", env, ns)
H.assertNotNil(ResultLinks, "Shared/ResultLinks.lua must return its table")

-- Stand-in for Utils.GetResultLink: rows with a spell or item link in chat.
ns.GetResultLink = function(data)
    if data.spellID then return "|Hspell:" .. data.spellID .. "|h[spell]|h" end
    if data.itemID then return "|Hitem:" .. data.itemID .. "|h[item]|h" end
    return nil
end

local menuRow = { name = "Options", category = "Menu Bar", path = { "Game Menu" } }
local settingRow = { name = "Auto Loot", category = "Game Settings", path = { "Gameplay" } }
local ability = { name = "Swipe", category = "Ability", spellID = 213771 }
local catalogItem = { name = "Gladiator's Hacker", category = "Appearance", catalogItem = true, itemID = 1234 }
local bagItem = { name = "Hearthstone", category = "Bag", itemID = 6948 }

local tests = {}

function tests.rowsWithoutTheirOwnChatLinkAreShareable()
    H.assertTrue(ResultLinks:CanShare(menuRow), "menu row")
    H.assertTrue(ResultLinks:CanShare(settingRow), "setting row")
    H.assertEq(ResultLinks:BuildShareText(menuRow), "[EasyFind: Options] {ef:ui:Game Menu>Options}",
        "share text carries the marker and the key when the key is not the bare name")
end

function tests.rowsThatLinkInChatAreNotShareable()
    H.assertFalse(ResultLinks:CanShare(ability), "a spell links on its own")
    H.assertFalse(ResultLinks:CanShare(catalogItem), "a catalog item links on its own")
    H.assertFalse(ResultLinks:CanShare(bagItem), "bag rows are never shared")
    H.assertNil(ResultLinks:BuildShareText(ability), "no share text for a spell")
    H.assertNil(ResultLinks:BuildSendRows(catalogItem), "no send rows for a catalog item")
end

function tests.unlinkableRowsStayShareableWhenNothingLinks()
    ns.GetResultLink = function() return nil end
    H.assertTrue(ResultLinks:CanShare(ability), "with no chat link, the row is shareable again")
end

local pass, fail, failures = H.runSuite("ResultLinks", tests)
return { pass = pass, fail = fail, failures = failures }
