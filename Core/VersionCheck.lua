local _, ns = ...

-- Peer-broadcast update notice. A WoW addon has no internet access, so the
-- only way this client can learn that a newer EasyFind exists is to hear it
-- from another player who already updated: we broadcast our own version over
-- the hidden addon-message channel, peers reply with theirs, and a version
-- above ours flips a session flag that decorates the search bar placeholder.
--
-- Deliberately silent: no chat line, no popup. The notice lives where the
-- user already looks (the search bar placeholder and the options version
-- label) and never interrupts.
--
-- State is session-only, never saved. A spoofed version can therefore do
-- nothing worse than decorate one session's placeholder, and the next login
-- heals it -- which is why there is no corroboration threshold here.
--
-- Wire protocol (locale-neutral, sortable):
--   Prefix  : EasyFindVer
--   Hello   : "1\tH"
--   Version : "1\tV\t<version>"

local Utils = ns.Utils
local SafeAfter = Utils.SafeAfter

local EasyFind = EasyFind
local C_ChatInfo = C_ChatInfo
local CreateFrame = CreateFrame
local IsInGroup, IsInRaid, IsInGuild = IsInGroup, IsInRaid, IsInGuild
local IsInInstance = IsInInstance
local smatch = string.match
local strsplit = strsplit
local random = math.random
local pcall = pcall

local VersionCheck = {}
ns.VersionCheck = VersionCheck

local PREFIX = "EasyFindVer"
local PROTOCOL = "1"
local CMD_HELLO = "H"
local CMD_VERSION = "V"
local VERSION_PATTERN = "^%d+%.%d+%.%d+$"
-- A fixed delay makes every guild member answer in the same instant, a burst
-- that scales with guild size. Spread the replies out instead.
local REPLY_DELAY_MIN, REPLY_DELAY_MAX = 2, 5

-- Channels that carry a real roster. A version arriving any other way
-- (whisper above all) is dropped: those are unsolicited and unverifiable.
local ROSTER_CHANNELS = {
    GUILD = true,
    PARTY = true,
    RAID = true,
    INSTANCE_CHAT = true,
}

local newestSeen = nil
local replyScheduled = {}
local guildHelloSent = false
local wasInGroup = false

local function IsValidVersion(value)
    return type(value) == "string" and smatch(value, VERSION_PATTERN) ~= nil
end

function VersionCheck:GetAvailableVersion()
    if EasyFind.db and EasyFind.db.updateNotify == false then return nil end
    return newestSeen
end

function VersionCheck:IsUpdateAvailable()
    return self:GetAvailableVersion() ~= nil
end

local function Send(channel, payload)
    if not (channel and C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, payload, channel)
end

local function SendHello(channel)
    Send(channel, PROTOCOL .. "\t" .. CMD_HELLO)
end

local function SendVersion(channel)
    if not IsValidVersion(ns.version) then return end
    Send(channel, PROTOCOL .. "\t" .. CMD_VERSION .. "\t" .. ns.version)
end

local function GroupChannel()
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType ~= "none" then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- The one place a peer version enters the module; callable directly to
-- exercise the flag without a second player.
function VersionCheck:NotePeerVersion(peerVersion, channel)
    if not ROSTER_CHANNELS[channel] then return false end
    if not IsValidVersion(peerVersion) then return false end
    if not IsValidVersion(ns.version) then return false end
    if ns.CompareVersion(peerVersion, ns.version) <= 0 then return false end
    if newestSeen and ns.CompareVersion(peerVersion, newestSeen) <= 0 then return false end
    newestSeen = peerVersion
    self:RefreshSurfaces()
    return true
end

-- Repaint everywhere the notice shows. Both surfaces are optional: the
-- search bar may not be built yet, and the options panel is a companion
-- that usually is not loaded at all.
function VersionCheck:RefreshSurfaces()
    if ns.Search and ns.Search.RefreshUpdateNotice then
        pcall(ns.Search.RefreshUpdateNotice, ns.Search)
    end
    if ns.Options and ns.Options.RefreshVersionLabel then
        pcall(ns.Options.RefreshVersionLabel, ns.Options)
    end
end

local function OnHello(channel)
    if not ROSTER_CHANNELS[channel] then return end
    if replyScheduled[channel] then return end
    replyScheduled[channel] = true
    SafeAfter(REPLY_DELAY_MIN + random() * (REPLY_DELAY_MAX - REPLY_DELAY_MIN), function()
        replyScheduled[channel] = nil
        SendVersion(channel)
    end)
end

local function OnRosterUpdate()
    local nowInGroup = IsInGroup() or IsInRaid()
    if nowInGroup and not wasInGroup then
        SendHello(GroupChannel())
    end
    wasInGroup = nowInGroup
end

function VersionCheck:Initialize()
    if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end

    local frame = CreateFrame("Frame")
    -- PLAYER_ENTERING_WORLD, not PLAYER_LOGIN: this Initialize runs from
    -- Core's own PLAYER_LOGIN handler, and a frame that registers an event
    -- while that event is mid-dispatch never receives that firing. The hello
    -- would silently never send.
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_ENTERING_WORLD" then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
            -- Seed the transition state so a reload inside a group does not
            -- re-announce on the next roster update.
            wasInGroup = IsInGroup() or IsInRaid()
            -- Guild info can read empty on a cold login, so the flag is set
            -- only once the guild actually answers; later loading screens
            -- retry instead of skipping the hello for the whole session.
            if not guildHelloSent and IsInGuild() then
                guildHelloSent = true
                SendHello("GUILD")
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            OnRosterUpdate()
        elseif event == "CHAT_MSG_ADDON" then
            local prefix, message, channel = ...
            if prefix ~= PREFIX or type(message) ~= "string" then return end
            local proto, command, value = strsplit("\t", message)
            if proto ~= PROTOCOL then return end
            if command == CMD_HELLO then
                OnHello(channel)
            elseif command == CMD_VERSION then
                VersionCheck:NotePeerVersion(value, channel)
            end
        end
    end)
end

-- Diagnostic snapshot of the module's state.
function VersionCheck:GetDiagnostics()
    return {
        prefix = PREFIX,
        ownVersion = ns.version,
        newestSeen = newestSeen,
        notifyEnabled = not (EasyFind.db and EasyFind.db.updateNotify == false),
        guildHelloSent = guildHelloSent,
        inGuild = IsInGuild() and true or false,
        groupChannel = GroupChannel(),
    }
end

function VersionCheck:ResetSeen()
    newestSeen = nil
    self:RefreshSurfaces()
end

function VersionCheck:SendHelloTo(channel)
    SendHello(channel)
end

function VersionCheck:BroadcastVersion(channel, spoofVersion)
    if spoofVersion then
        Send(channel, PROTOCOL .. "\t" .. CMD_VERSION .. "\t" .. spoofVersion)
        return
    end
    SendVersion(channel)
end
