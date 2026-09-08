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
-- Activation is a click on the row: setting rows toggle, navigation rows
-- open or guide, panel openers (talents, spellbook-only abilities) open
-- their panel, and rows with a secure action do it (the ability casts,
-- the mount summons, the toy is used, the outfit worn). Those last two
-- kinds run from a hardware click on the link pad (below), never from the
-- chat handler. A macro is the one exception: its key is an index into
-- the receiver's own macro list, not the sender's macro, so the link
-- opens it for reading. The search bar itself never opens from a link.

local ResultLinks = {}
ns.ResultLinks = ResultLinks

local Utils = ns.Utils
local L = ns.L

local sformat, sgsub, smatch, ssub, sbyte, schar = string.format, string.gsub, string.match, string.sub, string.byte, string.char
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown
local GetCursorPosition, GetTime = GetCursorPosition, GetTime
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown
local IsModifiedClick = _G["IsModifiedClick"]
local ChatEdit_InsertLink = _G["ChatEdit_InsertLink"]
local ChatEdit_GetActiveWindow = _G["ChatEdit_GetActiveWindow"]
local ChatFrame_OpenChat = _G["ChatFrame_OpenChat"]
local AddMessageEventFilter = _G["ChatFrame_AddMessageEventFilter"]

local LINK_PREFIX = "easyfind:row:"
local MARKER = "EasyFind"
local MAX_NAME = 60
local MAX_MESSAGE = 255

-- Categories and row kinds that have no meaning on another character.
local UNSHAREABLE_CATEGORY = { Snippet = true, Command = true }

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

-- An item that can be used or worn travels as its item id, whichever
-- row it came from (a bag row, or the catalog): the receiver resolves it
-- against their OWN bags, and the click uses or equips their copy exactly
-- as the sender's bag row would, or shows the item when they have none.
local function IsUsableItem(itemID)
    if not itemID then return false end
    local Handlers = ns.ResultHandlers
    if Handlers and Handlers.GetItemEquipLoc and Handlers.IsRealEquipLoc
       and Handlers:IsRealEquipLoc(Handlers:GetItemEquipLoc(itemID)) then
        return true
    end
    local spell = C_Item and C_Item.GetItemSpell and C_Item.GetItemSpell(itemID)
    return spell ~= nil
end

local function IsItemRow(data)
    return data and data.itemID and (data.category == "Bag" or data.catalogItem) or false
end

local function EntryKey(data)
    if IsItemRow(data) then return "item:" .. data.itemID end
    return ns.Aliases and ns.Aliases:GetEntryKey(data) or nil
end

-- The receiver's own bag row for an item key, if they carry the item.
-- The search database is built on first use, so a click with no hover
-- before it (the window was not focused) can arrive before any bag row
-- exists; the bags themselves are read then, and a row with what the
-- secure item action and the follow-up need is built on the spot.
local function ContainerRowFor(itemID)
    local CC = C_Container
    if not (CC and CC.GetContainerNumSlots and CC.GetContainerItemID) then return nil end
    local lastBag = (NUM_BAG_SLOTS or 4) + 1 -- the reagent bag; an absent bag has no slots
    for bag = 0, lastBag do
        for slot = 1, (CC.GetContainerNumSlots(bag) or 0) do
            if CC.GetContainerItemID(bag, slot) == itemID then
                local info = CC.GetContainerItemInfo and CC.GetContainerItemInfo(bag, slot)
                local name = (info and info.itemName)
                    or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID))
                if not name then return nil end
                return {
                    category = "Bag", itemID = itemID, name = name, nameLower = name:lower(),
                    bagID = bag, bagSlot = slot, bagItemLink = info and info.hyperlink,
                    icon = info and info.iconFileID,
                }
            end
        end
    end
    return nil
end

local function ResolveItemKey(key)
    local itemID = tonumber(smatch(key, "^item:(%d+)$"))
    if not itemID then return nil end
    local rows = ns.Database and ns.Database.uiSearchData
    for i = 1, (rows and #rows or 0) do
        local d = rows[i]
        if d.category == "Bag" and d.itemID == itemID then return d end
    end
    return ContainerRowFor(itemID)
end
if ns.Aliases and ns.Aliases.RegisterKeyResolver then
    ns.Aliases:RegisterKeyResolver("item", ResolveItemKey)
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
    -- An item's EasyFind link means "use or wear yours": only items with a
    -- use effect or a gear slot get one. Anything else from the catalog
    -- is shared through the item link alone, which already shows it.
    if data.appearanceItemID then return false end
    if IsItemRow(data) and not IsUsableItem(data.itemID) then return false end
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
    -- The clipboard row names the EasyFind-link chord, not Send's Ctrl+C.
    -- The text comes back too, so the flyout's parent row can copy it.
    return ns.BuildSendLinkRows(text, "Ctrl+Shift+C", L["EFLINK_ROW_TT_NOTE"]), text
end

-- ==== receiving ============================================================

local function BlueLink(key, name)
    local LC = ns.LINK_COLOR or { 0.44, 0.84, 1.0 }
    return sformat("|cff%02x%02x%02x|H%s%s|h[%s: %s]|h|r",
        LC[1] * 255, LC[2] * 255, LC[3] * 255, LINK_PREFIX, EncodeKey(key), MARKER, name)
end

-- A link's row must exist before the click: the pad arms on hover, and a
-- row still unresolved then costs the user a second click. So the row is
-- warmed the moment its link arrives in chat (assigned below, once the
-- resolvers exist), long before anyone reaches for it.
local Prewarm

-- Rewrite every marker in an incoming message into a clickable link. The
-- keyed form is matched first so its "(ef:...)" tail is consumed with it.
local function Linkify(msg)
    if not msg or not smatch(msg, "%[" .. MARKER .. ": ") then return msg end
    msg = sgsub(msg, "%[" .. MARKER .. ": ([^%]]-)%]%s?{ef:([^}]+)}", function(name, key)
        if Prewarm then Prewarm(key) end
        return BlueLink(key, name)
    end)
    msg = sgsub(msg, "%[" .. MARKER .. ": ([^%]]-)%]", function(name)
        if Prewarm then Prewarm("ui:" .. name) end
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

-- Rows whose click must be a HARDWARE click on a secure button: panel
-- openers (talents, the spellbook, spellbook-only abilities) and rows with
-- a secure action (cast, summon, use, wear, macro). Shown from addon code,
-- the spellbook taints the action bars' grid state (its OnShow writes it
-- through MultiActionBar_ShowAllGrids, and every action-button hover reads
-- it back), and a chat click IS addon code: the chat frame's hyperlink
-- handler. These rows open from the link pad below, exactly as a result
-- row or a shortkey opens them; everything else activates straight from
-- the hyperlink handler.
local function NeedsPad(data)
    if ns.SecureOpeners and ns.SecureOpeners.OpenKeyForData
       and ns.SecureOpeners.OpenKeyForData(data) then
        return true
    end
    return ns.ResultIcons and ns.ResultIcons.IsSecureActionResult
        and ns.ResultIcons:IsSecureActionResult(data) or false
end

-- Plain rows (setting toggles, navigation, guides): the same call a
-- shortkey press makes.
local function Activate(data)
    local Handlers = ns.ResultHandlers
    if ns.ResultRows and ns.ResultRows.ActivateSettingResult
       and ns.ResultRows:ActivateSettingResult(data) then
        return
    end
    if Handlers and Handlers.SelectResult then Handlers:SelectResult(data) end
end

local resolvedCache = {}
local function Resolve(key)
    local hit = resolvedCache[key]
    if hit then return hit end
    local data = ns.Aliases and ns.Aliases:FindEntryByKey(key) or nil
    if data then resolvedCache[key] = data end
    return data
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

-- Shift+click on an EasyFind link puts it back in the chat edit box to
-- send onward, exactly as shift+click relinks any chat hyperlink. The
-- text is the same marker the sender typed, so it re-links for readers
-- with the addon; the receiver never needs the row resolved to relay it.
local function RelinkText(key, name)
    if not (key and name and name ~= "") then return nil end
    local text = sformat("[%s: %s]", MARKER, name)
    if key ~= "ui:" .. name then text = text .. sformat(" {ef:%s}", key) end
    if #text > MAX_MESSAGE then return nil end
    return text
end

local function InsertRelink(key, name)
    local text = RelinkText(key, name)
    if not text then return false end
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
        if ChatEdit_InsertLink and ChatEdit_InsertLink(text) then return true end
    end
    if ChatFrame_OpenChat then ChatFrame_OpenChat(text); return true end
    return false
end

-- ==== the link pad ==========================================================
--
-- An invisible SecureActionButton that sits over an EasyFind link while
-- the cursor rests on it, armed with that row's secure attributes (the
-- same Apply the result rows and shortkeys use), so the click lands on it
-- instead of the chat frame: the same press and release dispatch a result
-- row gets, the same PostClick, nothing to see. It covers the link's own
-- rectangle when the hyperlink-enter script reports one (text region plus
-- offsets), and sits at the cursor otherwise. Leaving it hides it one
-- frame later unless a hyperlink re-enter came first, so sliding along
-- the link never drops a click into a gap. It hides ahead of combat
-- lockdown (PLAYER_REGEN_DISABLED fires before it); in combat the chat
-- handler answers with the after-combat notice.
local PAD_SIZE = 24
-- How long the pad stays after the mouse last proved it was on the link
-- or the pad. A hover refreshes it; so does the cursor resting on the
-- pad. Long enough that a click right after the hover still lands on the
-- pad, short enough that the pad is gone soon after the cursor leaves.
local PAD_ALIVE = 0.3
-- The pad covers a few pixels past the link text each side, so a hover at
-- the very edge still counts as being over it.
local PAD_MARGIN = 4
local pad, padKey
-- Key of the link whose tip is up, so the tip's life is the hover and
-- nothing else: it goes the moment the cursor is off the link, like a real
-- tooltip, while the pad keeps its own short grace for the click. The
-- link's box and a watcher frame give a link WITHOUT a pad the same
-- cursor-based lifetime (the chat's leave event alone left tips standing).
local tipKey, tipRect, tipWatch
local EnsureTipWatch

-- The game's own tooltip on hover, as every other chat link: chat is
-- Blizzard's surface, so the result's real tooltip (the spell, the item,
-- the mount) with what a click does appended as a dim line, the way
-- Blizzard appends its own click hints. A result with no tooltip of its
-- own (a setting, a panel, a zone) gets its name as the title. Shown for
-- every EasyFind link, pad-backed or not; ANCHOR_CURSOR so it sits by the
-- pointer wherever the link is.
local function ShowLinkTip(key, data, rect)
    if not (data and GameTooltip) then return end
    tipRect = rect
    GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    local Tooltips = ns.ResultTooltips
    local own = Tooltips and Tooltips.SetGameTooltipForResult
        and Tooltips:SetGameTooltipForResult(GameTooltip, data)
    if not own then
        GameTooltip:SetText(PlainName(data) or data.name or "", 1, 1, 1)
    end
    local Handlers = ns.ResultHandlers
    local hint = Handlers and Handlers.GetLinkHint and Handlers:GetLinkHint(data)
    if hint then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(hint, 0.5, 0.5, 0.5, true)
    end
    GameTooltip:Show()
    tipKey = key
    if EnsureTipWatch then EnsureTipWatch():Show() end
end

local function HideLinkTip()
    if tipKey == nil then return end
    tipKey, tipRect = nil, nil
    if tipWatch then tipWatch:Hide() end
    -- Only a tooltip we own; a late leave must never hide someone else's.
    if GameTooltip and GameTooltip:IsOwned(UIParent) then GameTooltip:Hide() end
end

local function PadHide()
    if not pad then return end
    if tipKey ~= nil and tipKey == padKey then HideLinkTip() end
    pad._aliveUntil = 0
    pad._link = nil
    pad.data = nil
    padKey = nil
    if InCombatLockdown() then return end
    if ns.ResultSecureAttributes then ns.ResultSecureAttributes.Clear(pad) end
    pad:Hide()
end

-- The link rectangle in UIParent coordinates, from the region the
-- hyperlink-enter script reports plus its offsets, or nil when a bare
-- click placed the pad (no hover). Stored, not used as the anchor: a
-- protected frame cannot anchor to a font string, and the reported box
-- also sits a few pixels below where the cursor rests on the link
-- (measured: a hover click missed a pad anchored to it). The pad sits on
-- the CURSOR and follows it while the cursor stays in this box; the box
-- only decides when the cursor has left the link.
local function LinkRect(region, left, bottom, width, height)
    if not (region and region.GetLeft and type(left) == "number"
            and type(bottom) == "number" and type(width) == "number"
            and type(height) == "number" and width > 0 and height > 0) then
        return nil
    end
    local rl, rb = region:GetLeft(), region:GetBottom()
    if not (rl and rb) then return nil end
    local k = region:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return { l = (rl + left) * k, b = (rb + bottom) * k, w = width * k, h = height * k }
end

local function CursorUI()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    return x / s, y / s
end

-- Place the pad centered on the cursor, wide enough to span the link (or
-- a default) and at least tall enough to catch a click near the line.
local function PadPlace()
    local r = pad._link
    local w = (r and r.w and r.w > 0) and r.w or PAD_SIZE
    local h = (r and r.h and r.h > 0) and r.h or PAD_SIZE
    if h < 18 then h = 18 end
    local cx, cy = CursorUI()
    pad:SetSize(w + 2 * PAD_MARGIN, h + 2 * PAD_MARGIN)
    pad:ClearAllPoints()
    pad:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
end

-- The cursor is within the link box, grown a little, more vertically
-- (the reported box is shorter than the clickable line).
local function CursorIn(r)
    if not r then return false end
    local cx, cy = CursorUI()
    return cx >= r.l - PAD_MARGIN and cx <= r.l + r.w + PAD_MARGIN
       and cy >= r.b - 8 and cy <= r.b + r.h + 8
end

local function CursorOnLink()
    return CursorIn(pad._link)
end

-- The tip's watcher: while a tip is up for a link the pad is not covering,
-- it goes the frame the cursor leaves the link's box. A pad-backed link's
-- tip is the pad's to manage (its OnUpdate above hides and re-shows it).
EnsureTipWatch = function()
    if tipWatch then return tipWatch end
    tipWatch = CreateFrame("Frame")
    tipWatch:SetScript("OnUpdate", function(self)
        if tipKey == nil then self:Hide(); return end
        if pad and pad:IsShown() and padKey == tipKey then return end
        if tipRect and not CursorIn(tipRect) then HideLinkTip() end
    end)
    tipWatch:Hide()
    return tipWatch
end

-- The press: arm exactly as a result row's PreClick arms a plain click.
-- The row's primary action fires from the secure attributes (cast,
-- summon, use, wear, panel open). Ctrl+click is the row's Alt+click,
-- show it where it lives: a castable ability swaps its cast for the
-- spellbook open, the rest drop their action and open from PostClick. A
-- macro row always takes that route: the index is the receiver's own
-- list, so the link opens the macro instead of running it.
local function PadPreClick(self, mouseButton, down)
    if mouseButton ~= "LeftButton" or not down then return end
    if InCombatLockdown() then return end
    local d, SA = self.data, ns.ResultSecureAttributes
    if not (d and SA) then return end
    -- Shift: relink into the edit box, not fire the row. Clear the secure
    -- action first so nothing casts on this press.
    if IsShiftKeyDown and IsShiftKeyDown() then
        SA.Clear(self)
        self._efRelink = true
        return
    end
    SA.ApplyAtClick(self, d)
    self._efShowWhereItLives = d.macroIndex or (IsControlKeyDown and IsControlKeyDown()) or nil
    if not self._efShowWhereItLives then return end
    if ns.SecureOpeners and ns.SecureOpeners.OpenKeyForData(d) then return end
    if d.spellID and d.category == "Ability"
       and ns.ResultIcons and not ns.ResultIcons:IsSpellbookOnlyAbility(d) then
        SA.SwapToPanelOpen(self)
    else
        SA.Clear(self)
    end
end

-- The follow-up a result row runs after its secure dispatch: panel
-- openers on the release edge (after the open and the tab steer), the
-- rest on the press. Plain, as a click with no modifier; Ctrl+click and
-- macros take the Alt route (IsSourceModifierHeld reads the flag).
local function PadPostClick(self, mouseButton, down)
    if mouseButton ~= "LeftButton" then return end
    local d, SA = self.data, ns.ResultSecureAttributes
    if not d then return end
    if self._efRelink then
        self._efRelink = nil
        if not down then return end
        InsertRelink(EntryKey(d), PlainName(d))
        PadHide()
        return
    end
    if SA and SA.ActsOnRelease(self, d) then
        if down then return end
    elseif not down then
        return
    end
    PadHide()
    local Handlers = ns.ResultHandlers
    if not (Handlers and Handlers.SelectResult) then return end
    if self._efShowWhereItLives then Handlers._openInPlace = true end
    self._efShowWhereItLives = nil
    local handler = _G["geterrorhandler"] and _G["geterrorhandler"]() or print
    xpcall(Handlers.SelectResult, handler, Handlers, d)
    Handlers._openInPlace = nil
end

local function EnsurePad()
    if pad then return pad end
    pad = CreateFrame("Button", "EasyFindLinkPad", UIParent, "SecureActionButtonTemplate")
    pad:SetSize(PAD_SIZE, PAD_SIZE)
    pad:SetFrameStrata("TOOLTIP")
    pad:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    -- Right and middle clicks belong to the chat frame beneath.
    Utils.SafeCallMethod(pad, "SetPassThroughButtons", "RightButton", "MiddleButton")
    pad:SetScript("PreClick", PadPreClick)
    pad:SetScript("PostClick", PadPostClick)
    -- HookScript: the template's own OnMouseUp dispatches the release.
    pad:HookScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and not InCombatLockdown() and ns.ResultSecureAttributes then
            ns.ResultSecureAttributes.ArmSteerLate(self)
        end
    end)
    pad:SetScript("OnUpdate", function(self)
        -- While the cursor is on the link the pad follows it exactly, so
        -- a click lands on the pad wherever on the link it happens (the
        -- link box sits a little below the cursor, so anchoring to it
        -- missed). Once the cursor leaves the box the pad lives out a
        -- short grace and hides. Without a box (a bare click placed it)
        -- the mouse being over the pad holds it briefly.
        local hovering
        if self._link then
            hovering = CursorOnLink()
            if hovering then
                self._aliveUntil = GetTime() + PAD_ALIVE
                local cx, cy = CursorUI()
                self:ClearAllPoints()
                self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
            end
        else
            hovering = self:IsMouseOver()
            if hovering then self._aliveUntil = GetTime() + PAD_ALIVE end
        end
        -- The tip tracks the hover, not the pad's grace: off the link it
        -- hides at once, back on the link (within the grace, when the
        -- chat fires no fresh enter) it returns.
        if hovering then
            if tipKey ~= padKey and self.data then ShowLinkTip(padKey, self.data, self._link) end
        elseif tipKey ~= nil and tipKey == padKey then
            HideLinkTip()
        end
        if GetTime() > (self._aliveUntil or 0) then PadHide() end
    end)
    pad:RegisterEvent("PLAYER_REGEN_DISABLED")
    pad:SetScript("OnEvent", function() PadHide() end)
    pad:Hide()
    return pad
end

local function ArmPad(key, data, region, left, bottom, width, height)
    if InCombatLockdown() then return end
    EnsurePad()
    if padKey ~= key then
        if ns.ResultSecureAttributes then ns.ResultSecureAttributes.Clear(pad) end
        pad.data = data
        padKey = key
    end
    pad._link = LinkRect(region, left, bottom, width, height)
    pad._aliveUntil = GetTime() + PAD_ALIVE
    PadPlace()
    pad:Show()
end

local function IsOurLink(link)
    return type(link) == "string" and ssub(link, 1, #LINK_PREFIX) == LINK_PREFIX
end

-- Hyperlink enter, and every re-enter: the pad goes over the link when
-- the row needs one. An unresolved row warms its provider so the next
-- hover, or the click's own retry, finds it.
local function OnLinkEnter(_, link, _, region, left, bottom, width, height)
    if not IsOurLink(link) or InCombatLockdown() then return end
    local key = DecodeKey(ssub(link, #LINK_PREFIX + 1))
    -- Already armed for this link and still up: only refresh the box and
    -- the keep-alive. The chat re-fires this every frame or two while the
    -- pad sits over the link, and Resolve for an item key scans the whole
    -- bag; doing that per frame cost frames.
    local rect = LinkRect(region, left, bottom, width, height)
    if padKey == key and pad and pad:IsShown() then
        pad._link = rect or pad._link
        pad._aliveUntil = GetTime() + PAD_ALIVE
        return
    end
    -- A link without a pad re-fires this the same way: its tip is already
    -- up, so only the box is refreshed. Rebuilding the tooltip per frame
    -- is churn, and it is how a tip outlived the hover.
    if tipKey == key and GameTooltip and GameTooltip:IsShown() and GameTooltip:IsOwned(UIParent) then
        tipRect = rect or tipRect
        return
    end
    local data = Resolve(key)
    if not data then
        RequestFor(key)
        return
    end
    ShowLinkTip(key, data, rect)
    if NeedsPad(data) then
        ArmPad(key, data, region, left, bottom, width, height)
    end
end

local warmed = {}
Prewarm = function(key)
    if warmed[key] then return end
    warmed[key] = true
    if not Resolve(key) then RequestFor(key) end
end

-- An item the receiver does not carry: show it, as a click on the item's
-- own chat link would.
local function ShowItemInstead(key)
    local itemID = smatch(key, "^item:(%d+)$")
    if not itemID then return false end
    if _G["SetItemRef"] then _G["SetItemRef"]("item:" .. itemID, "[item]", "LeftButton") end
    return true
end

local function OpenKey(key, attempt)
    attempt = attempt or 0
    local data = Resolve(key)
    if data then
        -- A pad row reached the chat handler: the click missed the pad (a
        -- cold session whose row resolved only now, or a click between two
        -- re-enters). Opening from here would taint the action bars, so
        -- the pad waits under the cursor for the next click instead.
        if NeedsPad(data) then
            ArmPad(key, data)
            return
        end
        Activate(data)
        return
    end
    -- An item key resolves against the bags themselves, so nothing to
    -- wait for: the receiver does not carry it.
    if ShowItemInstead(key) then return end
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
        hooksecurefunc("SetItemRef", function(link, text, button)
            if not IsOurLink(link) then return end
            local key = DecodeKey(ssub(link, #LINK_PREFIX + 1))
            -- Shift (the chat-link modifier): relink, like any hyperlink.
            -- The pad handles this for secure rows; this covers the rest.
            if (IsModifiedClick and IsModifiedClick("CHATLINK"))
               or (IsShiftKeyDown and IsShiftKeyDown()) then
                local name = text and smatch(text, "%[" .. MARKER .. ": ([^%]]-)%]")
                InsertRelink(key, name)
                return
            end
            if InCombatLockdown() then
                if EasyFind and EasyFind.Print then EasyFind:Print(L["EFLINK_IN_COMBAT"]) end
                return
            end
            OpenKey(key)
        end)
    end
    -- Hover on every chat window arms the pad, and for an EasyFind link
    -- the default hyperlink handler is skipped: it has no idea what an
    -- "easyfind:" link is and spent hundreds of ms per hover trying to
    -- build a tooltip for it (measured: a 342 ms frame whose only work
    -- was the hover). A post-hook cannot prevent that, so the enter
    -- script is wrapped: our links get only our logic, every other link
    -- falls through to whatever was there before.
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf and not cf._efLinkHover then
            cf._efLinkHover = true
            local prev = cf:GetScript("OnHyperlinkEnter")
            cf:SetScript("OnHyperlinkEnter", function(self, link, ...)
                if IsOurLink(link) then
                    OnLinkEnter(self, link, ...)
                    return
                end
                if prev then return prev(self, link, ...) end
            end)
            local prevLeave = cf:GetScript("OnHyperlinkLeave")
            cf:SetScript("OnHyperlinkLeave", function(self, link, ...)
                if IsOurLink(link) then
                    -- A pad-backed link's tip belongs to the pad's OnUpdate:
                    -- this fires the moment the pad appears under the
                    -- cursor, while the link is still hovered. Any other
                    -- link's tip goes now.
                    local key = DecodeKey(ssub(link, #LINK_PREFIX + 1))
                    if not (pad and pad:IsShown() and padKey == key) then
                        HideLinkTip()
                    end
                    return
                end
                if prevLeave then return prevLeave(self, link, ...) end
            end)
        end
    end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    ResultLinks:Install()
end)

return ResultLinks
