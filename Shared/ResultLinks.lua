local _, ns = ...

-- EasyFind links: share a search result with another EasyFind user so a
-- click on their side acts like a click on the row in their own results.
--
-- The server strips unknown |H link types from outgoing chat, so the link
-- travels as plain text: "[EasyFind: Talents]" for a UI row, with the
-- row's canonical key appended when the name alone does not identify it
-- ("[EasyFind: Swift Spectral Tiger] {ef:mount:123}"). Readers without
-- the addon see exactly that text. Readers with it see a blue clickable
-- link: a chat message filter rewrites the marker into a real
-- |Heasyfind:row:...|h link on arrival, and the SetItemRef hook resolves
-- the key back to live row data (Aliases:FindEntryByKey, the same
-- identity aliases and shortkeys use) and activates it.
--
-- Activation mirrors a shortkey press: setting rows toggle, navigation
-- rows open or guide, panel openers (talents, spellbook-only abilities)
-- open their panel. Rows whose action is secure (cast, use, summon, macro)
-- cannot fire from a chat click, so those activate as an Alt+click would:
-- the ability opens in the spellbook, the mount in the journal, the toy in
-- the toy box, the outfit in the transmog list, the macro in its window.
-- The search bar itself never opens from a link.

local ResultLinks = {}
ns.ResultLinks = ResultLinks

local Utils = ns.Utils
local L = ns.L

local sformat, sgsub, smatch, ssub, sbyte, schar = string.format, string.gsub, string.match, string.sub, string.byte, string.char
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown
local AddMessageEventFilter = _G["ChatFrame_AddMessageEventFilter"]

local LINK_PREFIX = "easyfind:row:"
local MARKER = "EasyFind"
local MAX_NAME = 60
local MAX_MESSAGE = 255

-- Categories and row kinds that have no meaning on another character.
local UNSHAREABLE_CATEGORY = { Snippet = true, Bag = true, Command = true }

local CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
}

-- Link data must stay free of "|" and is safest as a plain token: every
-- byte outside [%w:._-] travels as ~XX.
local function EncodeKey(key)
    return (sgsub(key, "[^%w:._%-]", function(c)
        return sformat("~%02X", sbyte(c))
    end))
end

local function DecodeKey(blob)
    return (sgsub(blob, "~(%x%x)", function(hex)
        return schar(tonumber(hex, 16))
    end))
end

local function EntryKey(data)
    return ns.Aliases and ns.Aliases:GetEntryKey(data) or nil
end

local function PlainName(data)
    local name = Utils.StripMarkup and Utils.StripMarkup(data.name) or data.name
    name = name and Utils.ClipboardSafeText and Utils.ClipboardSafeText(name) or name
    if not name or name == "" then return nil end
    -- Brackets and braces are the marker's own syntax.
    name = sgsub(name, "[%[%]{}]", "")
    if #name > MAX_NAME then name = ssub(name, 1, MAX_NAME) end
    return name
end

function ResultLinks:CanShare(data)
    if not data or data.noPin then return false end
    if UNSHAREABLE_CATEGORY[data.category] then return false end
    if data.calculatorResult or data.calculatorExpression or data.calculatorLauncher
       or data.quickFilterDef or data.searchCommand or data.nativeRun
       or data.copyText or data.snippetCreate or data.snippetsLauncher then
        return false
    end
    -- A catalog item's EasyFind link would open nothing the item link does
    -- not already show, so it is shared through the item link alone. Rows
    -- whose click does something a chat link cannot (a spell opens the
    -- spellbook, a mount the journal, a talent the talent window) keep
    -- theirs.
    if data.catalogItem or data.appearanceItemID then return false end
    return EntryKey(data) ~= nil and PlainName(data) ~= nil
end

-- The plain-text form that goes over chat, or nil when the row cannot be
-- shared (or would not fit a chat message).
function ResultLinks:BuildShareText(data)
    if not self:CanShare(data) then return nil end
    local key = EntryKey(data)
    local name = PlainName(data)
    local text = sformat("[%s: %s]", MARKER, name)
    if key ~= "ui:" .. name then
        -- Braces, not parentheses: UI path keys carry ">" and may carry
        -- parentheses of their own, and a key with a brace is unheard of.
        text = text .. sformat(" {ef:%s}", key)
    end
    if #text > MAX_MESSAGE then return nil end
    return text
end

-- Send-menu rows (channels, whisper, clipboard) for the share text.
function ResultLinks:BuildSendRows(data)
    local text = self:BuildShareText(data)
    if not text or not ns.BuildSendLinkRows then return nil end
    return ns.BuildSendLinkRows(text)
end

-- ==== receiving ============================================================

local function BlueLink(key, name)
    local LC = ns.LINK_COLOR or { 0.44, 0.84, 1.0 }
    return sformat("|cff%02x%02x%02x|H%s%s|h[%s: %s]|h|r",
        LC[1] * 255, LC[2] * 255, LC[3] * 255, LINK_PREFIX, EncodeKey(key), MARKER, name)
end

-- Rewrite every marker in an incoming message into a clickable link. The
-- keyed form is matched first so its "(ef:...)" tail is consumed with it.
local function Linkify(msg)
    if not msg or not smatch(msg, "%[" .. MARKER .. ": ") then return msg end
    msg = sgsub(msg, "%[" .. MARKER .. ": ([^%]]-)%]%s?{ef:([^}]+)}", function(name, key)
        return BlueLink(key, name)
    end)
    msg = sgsub(msg, "%[" .. MARKER .. ": ([^%]]-)%]", function(name)
        return BlueLink("ui:" .. name, name)
    end)
    return msg
end

local function ChatFilter(_, _, msg, ...)
    local out = Linkify(msg)
    if out == msg then return false end
    return false, out, ...
end

-- ==== activation ===========================================================

-- Rows that open the spellbook or talents (panel openers, and spells,
-- which open where they live rather than cast) can only do so inside the
-- user's own click on a secure button, which is what a result row is.
-- Running that open from a chat-link click, insecure code
-- even inside a hardware event, drove the spellbook under EasyFind taint
-- and planted the highlight-mark globals; every action-button hover
-- afterwards tripped ADDON_ACTION_BLOCKED (the [BREAK] autopsy, Weapon
-- Skills link, 2026-09-04). The link now hands the click to the user's
-- own results (Search:ShowLinkedResult).
local function NeedsHardwareClick(data)
    if ns.SecureOpeners and ns.SecureOpeners.OpenKeyForData
       and ns.SecureOpeners.OpenKeyForData(data) then
        return true
    end
    return data.spellID ~= nil and data.category == "Ability"
end

-- Mounts, toys, macros, outfits: no secure action from the link either;
-- they open where they live, the Alt+click route the rows take, which
-- touches none of the protected panels.
local function OpensInPlace(data)
    return ns.ResultIcons and ns.ResultIcons.IsSecureActionResult
        and ns.ResultIcons:IsSecureActionResult(data) or false
end

local function SelectInPlace(data)
    local Handlers = ns.ResultHandlers
    if not (Handlers and Handlers.SelectResult) then return end
    Handlers._openInPlace = true
    local handler = _G["geterrorhandler"] and _G["geterrorhandler"]() or print
    xpcall(Handlers.SelectResult, handler, Handlers, data)
    Handlers._openInPlace = nil
end

local function Activate(data)
    local Handlers = ns.ResultHandlers
    if ns.ResultRows and ns.ResultRows.ActivateSettingResult
       and ns.ResultRows:ActivateSettingResult(data) then
        return
    end
    if NeedsHardwareClick(data) then
        -- The receiver's own results, landed on this row: their click on it
        -- is the ordinary result-row click, with no second copy of that
        -- logic anywhere (Search:ShowLinkedResult).
        if InCombatLockdown() then
            if EasyFind and EasyFind.Print then EasyFind:Print(L["EFLINK_IN_COMBAT"]) end
        elseif ns.Search and ns.Search.ShowLinkedResult then
            ns.Search:ShowLinkedResult(data)
        end
        return
    end
    if OpensInPlace(data) then
        SelectInPlace(data)
        return
    end
    if Handlers and Handlers.SelectResult then Handlers:SelectResult(data) end
end

local function Resolve(key)
    return ns.Aliases and ns.Aliases:FindEntryByKey(key) or nil
end

-- The searchable database builds on first search-bar focus and providers
-- load on demand, so a click in a fresh session warms what the key needs
-- and retries a few times before giving up.
local RETRY_DELAYS = { 0.5, 1.5, 3 }

local function RequestFor(key)
    local db = ns.Database
    if db then
        if db.LoadDeferredSyncProvidersStaggered then
            db:LoadDeferredSyncProvidersStaggered()
        elseif db.WarmSearchHotPath then
            db:WarmSearchHotPath()
        end
    end
    if ns.Shortkeys and ns.Shortkeys.RequestProviderForRowKey then
        ns.Shortkeys.RequestProviderForRowKey(key)
    end
end

local function OpenKey(key, attempt)
    attempt = attempt or 0
    local data = Resolve(key)
    if data then
        Activate(data)
        return
    end
    if attempt == 0 then RequestFor(key) end
    local delay = RETRY_DELAYS[attempt + 1]
    if not delay then
        if EasyFind and EasyFind.Print then EasyFind:Print(L["EFLINK_NOT_FOUND"]) end
        return
    end
    Utils.SafeAfter(delay, function() OpenKey(key, attempt + 1) end)
end

local installed = false
function ResultLinks:Install()
    if installed then return end
    installed = true
    if AddMessageEventFilter then
        for i = 1, #CHAT_EVENTS do
            AddMessageEventFilter(CHAT_EVENTS[i], ChatFilter)
        end
    end
    -- hooksecurefunc, never a replacement: secure code reads SetItemRef and
    -- a replaced global taints every reader (see Core/Main.lua).
    if hooksecurefunc then
        hooksecurefunc("SetItemRef", function(link)
            if type(link) ~= "string" or ssub(link, 1, #LINK_PREFIX) ~= LINK_PREFIX then return end
            if InCombatLockdown() then return end
            OpenKey(DecodeKey(ssub(link, #LINK_PREFIX + 1)))
        end)
    end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    ResultLinks:Install()
end)

return ResultLinks
