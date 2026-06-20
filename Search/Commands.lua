local _, ns = ...

local Search = ns.Search
local Commands = ns.SearchCommands
local Utils = ns.Utils
local L = ns.L

local pairs = Utils.pairs
local sfind, slower = Utils.sfind, Utils.slower
local wipe = wipe
local tsort = table.sort

local function GetSearchFrame()
    return Search:GetSearchFrame()
end

Commands.searchBarCommands = {
    {
        command = "reset",
        display = "/reset",
        desc = L["CMD_DESC_RESET"],
        aliases = { "reset", "resetpos", "resetposition" },
    },
    {
        command = "resize",
        display = "/resize",
        desc = L["CMD_DESC_RESIZE"],
        aliases = { "resize", "rescale" },
    },
    {
        command = "options",
        display = "/options",
        desc = L["CMD_DESC_OPTIONS"],
        aliases = { "options", "o", "config", "settings" },
    },
    {
        command = "tutorial",
        display = "/tutorial",
        desc = L["CMD_DESC_TUTORIAL"],
        aliases = { "tutorial", "wizard", "welcome" },
    },
}
for i = 1, #Commands.searchBarCommands do
    local def = Commands.searchBarCommands[i]
    def.displayToken = slower((def.display:gsub("^/", "")))
    def.displayLower = slower(def.display)
end
Commands.searchBarCommandEntries = {}
Commands.searchBarCommandData = {}

function Commands:RunSearchBarCommand(command)
    command = slower(strtrim(tostring(command or "")):gsub("^/", ""))
    if command == "" then return false end

    local canonical
    for i = 1, #self.searchBarCommands do
        local def = self.searchBarCommands[i]
        for ai = 1, #def.aliases do
            if command == def.aliases[ai] then
                canonical = def.command
                break
            end
        end
        if canonical then break end
    end
    if not canonical then return false end

    local sf = GetSearchFrame()
    local editBox = sf and sf.editBox
    if editBox then
        if editBox.ResetPendingSearch then editBox:ResetPendingSearch() end
        editBox:SetText("")
        editBox:SetCursorPosition(0)
        if editBox.placeholder then editBox.placeholder:Show() end
    end
    self:HideResults()

    if canonical == "reset" then
        StaticPopup_Show("EASYFIND_RESET_SEARCH_BAR")
    elseif canonical == "resize" then
        if ns.Rescaler and ns.Rescaler.Enter then
            ns.Rescaler:Enter("ui")
        end
    elseif canonical == "options" then
        EasyFind:OpenOptions()
    elseif canonical == "tutorial" then
        if ns.Wizard and ns.Wizard.Show then
            EasyFind.db.tutorialDone = false
            ns.Wizard:Show()
        end
    end
    return true
end

-- Subtext for native slash commands, matching the default UI's chat-type
-- labels (the chat tab menu: Say, Reply, Emote...). Keyed by the SlashCmdList
-- hash key and pulled from Blizzard globals so they translate for free.
-- Commands with no chat-type label fall back to the slash string.
local CHAT_CMD_LABELS = {
    SAY           = _G["SAY"],
    PARTY         = _G["PARTY"],
    RAID          = _G["RAID"],
    RAID_WARNING  = _G["RAID_WARNING"],
    INSTANCE_CHAT = _G["INSTANCE_CHAT"],
    GUILD         = _G["GUILD"],
    OFFICER       = _G["OFFICER"],
    YELL          = _G["YELL"],
    WHISPER       = _G["WHISPER"],
    REPLY         = _G["REPLY"],
    EMOTE         = _G["EMOTE"],
    TEXTEMOTE     = _G["EMOTE"],
    MACRO         = _G["MACRO"],
    BATTLEGROUND  = _G["BATTLEGROUND"],
    CHANNEL       = _G["CHANNEL"],
}
local EMOTE_SUBLABEL = _G["EMOTE"] or "Emote"

local COMMANDS_ICON = ns.COMMANDS_ICON_TEX

-- Shared read-only subtext paths for command rows; never mutated, so one
-- instance each avoids a per-match table allocation on every keystroke.
local SEARCH_BAR_PATH = { L["SUBTEXT_SEARCH_BAR"] }
local SLASH_COMMANDS_PATH = { L["SUBTEXT_SLASH_COMMANDS"] }
local EASYFIND_PATH = { "EasyFind" }

-- Default UI slash commands (registered handlers + emotes), built once and
-- reused so the per-keystroke suggestion path never scans the live tables.
local nativeCommandDefs
local function CollectNativeCommandDefs()
    if nativeCommandDefs then return nativeCommandDefs end
    local defs, seen = {}, {}
    -- EasyFind's own commands are listed separately (custom) and are also in
    -- SlashCmdList; seed them as seen so they aren't repeated here as native.
    local custom = Commands.searchBarCommands
    if custom then
        for i = 1, #custom do
            local d = custom[i].display
            if d then seen[slower(d)] = true end
        end
    end
    -- Common system commands the chat parser handles directly (not registered
    -- in SlashCmdList). Run them through the secure macro path (slashCommand ->
    -- macrotext) so the protected ones (/logout, /quit) execute like a real
    -- macro instead of tripping ADDON_ACTION_FORBIDDEN from an insecure
    -- Logout()/Quit() call. /reload is unprotected but goes the same route for
    -- consistency (macrotext "/reload" reloads exactly like typing it).
    local SYSTEM_COMMANDS = { "/reload", "/logout", "/camp", "/quit", "/exit" }
    for i = 1, #SYSTEM_COMMANDS do
        local slash = SYSTEM_COMMANDS[i]
        if not seen[slower(slash)] then
            seen[slower(slash)] = true
            defs[#defs + 1] = {
                display = slash,
                lower = slower((slash:gsub("^/", ""))),
                slashCommand = slash,
            }
        end
    end
    if SlashCmdList then
        for key, handler in pairs(SlashCmdList) do
            local slash = _G["SLASH_" .. key .. "1"]
            if type(slash) == "string" and slash:sub(1, 1) == "/" and not seen[slower(slash)] then
                seen[slower(slash)] = true
                local h = handler
                defs[#defs + 1] = {
                    display = slower(slash),
                    lower = slower(slash:gsub("^/", "")),
                    subLabel = CHAT_CMD_LABELS[key],
                    run = function() pcall(h, "", DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox) end,
                }
            end
        end
    end
    for i = 1, 512 do
        local cmd = _G["EMOTE" .. i .. "_CMD1"]
        local tok = _G["EMOTE" .. i .. "_TOKEN"]
        if type(cmd) == "string" and cmd:sub(1, 1) == "/" and tok and not seen[slower(cmd)] then
            seen[slower(cmd)] = true
            local t = tok
            defs[#defs + 1] = {
                display = slower(cmd),
                lower = slower((cmd:gsub("^/", ""))),
                subLabel = EMOTE_SUBLABEL,
                run = function() if DoEmote then DoEmote(t) end end,
            }
        end
    end
    tsort(defs, function(a, b) return a.display < b.display end)
    nativeCommandDefs = defs
    return defs
end

local function StampCommandEntry(entries, n, data)
    local entry = entries[n]
    if not entry then
        entry = {}
        entries[n] = entry
    end
    entry.name = data.name
    entry.depth = 0
    entry.isPathNode = false
    entry.isMatch = true
    entry.isFlat = true
    entry.flatCatKey = nil
    entry.isPinned = false
    entry.data = data
end

function Commands:GetSearchBarCommandSuggestionEntries(text)
    text = strtrim(text or "")
    local token = text:match("^/([%w]*)$")
    if token == nil then return nil end
    token = slower(token)

    local entries = self.searchBarCommandEntries
    local dataPool = self.searchBarCommandData
    local n = 0
    for i = 1, #self.searchBarCommands do
        local def = self.searchBarCommands[i]
        local matches = token == ""
        if not matches then
            matches = sfind(def.displayToken, token, 1, true) == 1
            if not matches then
                for ai = 1, #def.aliases do
                    if sfind(def.aliases[ai], token, 1, true) == 1 then
                        matches = true
                        break
                    end
                end
            end
        end
        if matches then
            n = n + 1
            local data = dataPool[n]
            if not data then
                data = {}
                dataPool[n] = data
            end
            wipe(data)
            data.name = def.display
            data.nameLower = def.displayLower
            data.category = "Command"
            data.path = SEARCH_BAR_PATH
            data.noPin = true
            data.icon = COMMANDS_ICON
            data.searchCommand = def.command
            data.searchCommandDesc = def.desc
            StampCommandEntry(entries, n, data)
        end
    end
    if EasyFind.db.commandShowNative ~= false then
        local nativeDefs = CollectNativeCommandDefs()
        for i = 1, #nativeDefs do
            local def = nativeDefs[i]
            if token == "" or sfind(def.lower, token, 1, true) == 1 then
                n = n + 1
                local data = dataPool[n]
                if not data then data = {}; dataPool[n] = data end
                wipe(data)
                data.name = def.display
                data.nameLower = def.display
                data.category = "Command"
                data.path = SLASH_COMMANDS_PATH
                data.noPin = true
                data.icon = COMMANDS_ICON
                -- Secure system commands (/logout, /quit, ...) run via the
                -- macrotext path; the rest via the insecure nativeRun callback.
                if def.slashCommand then
                    data.slashCommand = def.slashCommand
                else
                    data.nativeRun = def.run
                end
                data.searchCommandDesc = def.subLabel or def.display
                StampCommandEntry(entries, n, data)
            end
        end
    end
    for i = n + 1, #entries do entries[i] = nil end
    for i = n + 1, #dataPool do dataPool[i] = nil end
    return n > 0 and entries or nil
end

-- Stable search entries (not the per-keystroke pool) for the Commands filter
-- category, so commands are findable by name ("dance" -> /dance) and bucketed
-- under the Commands filter. The "/"-prefix suggestion path stays separate.
function Commands:BuildCommandSearchData()
    local out = {}
    for i = 1, #self.searchBarCommands do
        local def = self.searchBarCommands[i]
        out[#out + 1] = {
            name = def.display,
            nameLower = def.displayToken,
            category = "Command",
            path = EASYFIND_PATH,
            keywords = def.aliases,
            noPin = true,
            icon = COMMANDS_ICON,
            searchCommand = def.command,
            searchCommandDesc = def.desc,
            isNativeCommand = false,
        }
    end
    local nativeDefs = CollectNativeCommandDefs()
    for i = 1, #nativeDefs do
        local def = nativeDefs[i]
        out[#out + 1] = {
            name = def.display,
            nameLower = def.lower,
            category = "Command",
            path = SLASH_COMMANDS_PATH,
            keywords = { def.lower },
            noPin = true,
            icon = COMMANDS_ICON,
            nativeRun = def.run,
            slashCommand = def.slashCommand,
            searchCommandDesc = def.subLabel or def.display,
            isNativeCommand = true,
        }
    end
    return out
end
