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

function tests.catalogItemsAndBagRowsAreNotShareable()
    H.assertFalse(ResultLinks:CanShare(catalogItem), "a catalog item's EasyFind link adds nothing over its item link")
    H.assertFalse(ResultLinks:CanShare({ name = "Cowl", category = "Appearance", appearanceItemID = 77 }),
        "appearance rows are catalog items")
    H.assertFalse(ResultLinks:CanShare(bagItem), "bag rows are never shared")
    H.assertNil(ResultLinks:BuildSendRows(catalogItem), "no send rows for a catalog item")
end

function tests.rowsWithAnEasyFindActionKeepTheirLinkEvenWithAChatLink()
    H.assertTrue(ResultLinks:CanShare(ability), "a spell opens in the spellbook: worth an EasyFind link")
    H.assertTrue(ResultLinks:CanShare({ name = "Ebon Gryphon", category = "Mount", mountID = 5 }),
        "a mount opens in the journal")
    H.assertNotNil(ResultLinks:BuildShareText(ability), "share text for a spell")
end

local pass, fail, failures = H.runSuite("ResultLinks", tests)
return { pass = pass, fail = fail, failures = failures }
