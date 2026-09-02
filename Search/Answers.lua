local _, ns = ...

-- Inline query answers: typing "gold", "ilvl", "keystone", "durability",
-- "bags", "rating", or "speed" pins a live answer row above the normal
-- results (which keep flowing beneath it, same contract as the clock
-- commands). Values re-derive on every keystroke; clicking the row copies
-- the raw value. No data is stored anywhere -- every answer is a live API
-- read.

local Answers = {}
ns.Answers = Answers

local Utils = ns.Utils
local L = ns.L

local slower = Utils.slower
local sformat = Utils.sformat
local mfloor = Utils.mfloor
local strtrim = strtrim
local GetMoney = GetMoney
local GetCoinTextureString = GetCoinTextureString
local GetAverageItemLevel = GetAverageItemLevel
local GetInventoryItemDurability = GetInventoryItemDurability
local GetUnitSpeed = GetUnitSpeed
local C_Container = C_Container
local C_MythicPlus = C_MythicPlus
local C_ChallengeMode = C_ChallengeMode

local BASE_RUN_SPEED = 7

-- Per-character gold ledger for the account-wide figure. Only characters
-- logged in since the addon was installed can be known; each records its
-- gold on login, on every money change, and at logout.
local function GoldLedger()
    if type(EasyFindDB) ~= "table" then return nil end
    if type(EasyFindDB.charGold) ~= "table" then EasyFindDB.charGold = {} end
    return EasyFindDB.charGold
end

local function CharKey()
    local name, realm = UnitFullName("player")
    if not name then return nil end
    if not realm or realm == "" then
        realm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
    end
    return name .. "-" .. realm
end

local function RecordGold()
    local ledger = GoldLedger()
    local key = CharKey()
    if ledger and key and GetMoney then
        ledger[key] = GetMoney()
    end
end

local goldWatcher = CreateFrame("Frame")
goldWatcher:RegisterEvent("PLAYER_LOGIN")
goldWatcher:RegisterEvent("PLAYER_MONEY")
goldWatcher:RegisterEvent("PLAYER_LOGOUT")
goldWatcher:SetScript("OnEvent", RecordGold)

local function CoinText(amount)
    if GetCoinTextureString then return GetCoinTextureString(amount) end
    return tostring(amount)
end

-- The row shows coin TEXTURES, which cannot survive a copy: paste the
-- displayed string anywhere outside the game and the icons are gone,
-- leaving bare numbers with nothing to say which is gold and which is
-- silver. The copied form spells the denominations out with the client's
-- own coin letters instead.
local COIN_SYMBOLS = {
    _G["GOLD_AMOUNT_SYMBOL"] or "g",
    _G["SILVER_AMOUNT_SYMBOL"] or "s",
    _G["COPPER_AMOUNT_SYMBOL"] or "c",
}

local function PlainCoinText(amount)
    amount = amount or 0
    local perSilver = COPPER_PER_SILVER or 100
    local perGold = COPPER_PER_GOLD or 10000
    local parts = {
        mfloor(amount / perGold),
        mfloor((amount % perGold) / perSilver),
        amount % perSilver,
    }
    local text = ""
    for i = 1, 3 do
        -- Leading zero denominations are noise ("0g 0s 7c"), but once a
        -- larger one is present the smaller ones must show even at zero or
        -- "5g 0s 20c" would paste as the very different "5g 20c".
        if parts[i] > 0 or text ~= "" then
            if text ~= "" then text = text .. " " end
            text = text .. parts[i] .. COIN_SYMBOLS[i]
        end
    end
    if text == "" then text = 0 .. COIN_SYMBOLS[3] end
    return text
end

local function GoldText(FormatCoin)
    local money = GetMoney and GetMoney()
    if not money then return nil end
    local total = money
    local ledger = GoldLedger()
    local key = CharKey()
    if ledger then
        for charKey, amount in pairs(ledger) do
            if charKey ~= key and type(amount) == "number" then
                total = total + amount
            end
        end
    end
    if total == money then return FormatCoin(money) end
    return sformat(L["ANSWER_GOLD_FMT"], FormatCoin(money), FormatCoin(total))
end

local function GoldValue()
    return GoldText(CoinText)
end

local function GoldCopyValue()
    return GoldText(PlainCoinText)
end

local function ItemLevelValue()
    if not GetAverageItemLevel then return nil end
    local ok, overall, equipped, pvp = pcall(GetAverageItemLevel)
    if not ok or not overall then return nil end
    return sformat("%s %.1f / %s %.1f", _G["PVE"] or "PvE", equipped or overall,
        _G["PVP"] or "PvP", pvp or overall)
end

local function KeystoneValue()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID) then return nil end
    local ok, mapID = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
    if not ok or not mapID then return _G["NONE"] or "None" end
    local level
    if C_MythicPlus.GetOwnedKeystoneLevel then
        local okL, lvl = pcall(C_MythicPlus.GetOwnedKeystoneLevel)
        if okL then level = lvl end
    end
    local mapName
    if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
        local okM, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
        if okM then mapName = name end
    end
    if mapName and level then return sformat("%s +%d", mapName, level) end
    return mapName or (_G["NONE"] or "None")
end

local function RatingValue()
    if not (C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore) then return nil end
    local ok, score = pcall(C_ChallengeMode.GetOverallDungeonScore)
    if not ok or not score then return nil end
    return tostring(score)
end

local function DurabilityValue()
    if not GetInventoryItemDurability then return nil end
    local worst
    for slot = 1, 17 do
        local current, maximum = GetInventoryItemDurability(slot)
        if current and maximum and maximum > 0 then
            local pct = current / maximum
            if not worst or pct < worst then worst = pct end
        end
    end
    if not worst then return nil end
    return sformat("%d%%", mfloor(worst * 100 + 0.5))
end

local function BagSpaceValue()
    if not (C_Container and C_Container.GetContainerNumFreeSlots
            and C_Container.GetContainerNumSlots) then
        return nil
    end
    local free, total = 0, 0
    for bag = 0, ns.MaxCarriedBagIndex() do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        if slots > 0 then
            total = total + slots
            free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
        end
    end
    if total == 0 then return nil end
    return sformat("%d / %d", free, total)
end

local function SpeedValue()
    if not GetUnitSpeed then return nil end
    local speed = GetUnitSpeed("player")
    if not speed then return nil end
    return sformat("%d%%", mfloor(speed / BASE_RUN_SPEED * 100 + 0.5))
end

-- One definition per answer: exact-match trigger words (the whole query),
-- a Blizzard-localized label wherever a certain global exists, and the
-- live value reader.
local ANSWERS = {
    { keys = { "gold", "money", "cash" },
      label = _G["MONEY"] or "Money", value = GoldValue, copyValue = GoldCopyValue },
    { keys = { "ilvl", "item level", "itemlevel", "gearscore" },
      label = _G["STAT_AVERAGE_ITEM_LEVEL"] or "Item Level", value = ItemLevelValue },
    { keys = { "keystone", "my key", "mythic key" },
      labelKey = "ANSWER_KEYSTONE", value = KeystoneValue },
    { keys = { "rating", "io", "mythic rating", "m+ rating" },
      label = _G["DUNGEON_SCORE"] or "Mythic+ Rating", value = RatingValue },
    { keys = { "durability", "repair" },
      label = _G["DURABILITY"] or "Durability", value = DurabilityValue },
    { keys = { "bag space", "bags free", "free slots", "bagspace" },
      labelKey = "ANSWER_BAG_SPACE", value = BagSpaceValue },
    { keys = { "speed", "movement speed", "move speed" },
      label = _G["SPEED"] or "Speed", value = SpeedValue },
}

local answerByKey = {}
for i = 1, #ANSWERS do
    local def = ANSWERS[i]
    for k = 1, #def.keys do
        answerByKey[def.keys[k]] = def
    end
end

-- What a copy should produce, which is not always what the row shows: an
-- answer whose display carries textures supplies a plain-text form instead.
local lastAnswerCopyValue

local function CopyAnswer()
    if lastAnswerCopyValue and ns.CopyToClipboard then
        ns.CopyToClipboard(lastAnswerCopyValue)
    end
end

-- Statistics, not commands: these are facts about the character. The
-- category also supplies the proper left icon through the normal renderer.
local answerEntry = {
    category = "Statistic",
    noPin = true,
    -- Per-query computed fact on a REUSED table: learning it would bind
    -- the query to whatever this table holds later.
    noLearn = true,
    nativeRun = CopyAnswer,
}

-- The whole (trimmed, lowered) query must equal a trigger word: answers are
-- deliberate lookups, not fuzzy matches, and the normal results underneath
-- cover everything else.
function Answers:GetAnswerEntry(text)
    if not text then return nil end
    local query = slower(strtrim(text))
    local def = answerByKey[query]
    if not def then return nil end
    local value = def.value()
    if not value then return nil end
    lastAnswerCopyValue = def.copyValue and def.copyValue() or value
    answerEntry.name = def.labelKey and L[def.labelKey] or def.label
    answerEntry.nameLower = query
    answerEntry.searchCommandDesc = value
    return answerEntry
end

return Answers
