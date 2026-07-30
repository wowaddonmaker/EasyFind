local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Rows = ns.ResultRows
local Render = ns.ResultRender
local Icons = ns.ResultIcons
local Handlers = ns.ResultHandlers
local Utils = ns.Utils

local GetCursorPosition = GetCursorPosition
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown

-- Drag a linkable result onto a chat channel / whisper hyperlink to drop its
-- link into that channel's editbox (inserted, never auto-sent -- the user
-- reviews and presses Enter). The channel labels in the chat scroll ([Guild],
-- [2. Trade], a player name) are real |Hchannel:...|h / |Hplayer:...|h
-- hyperlinks, so we track which one the cursor is over and route the drop.
local hoveredChatLink, hoveredChatText, hoveredChatFrame
local chatTrackingInstalled = false
local function EnsureChatHyperlinkTracking()
    if chatTrackingInstalled then return end
    chatTrackingInstalled = true
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame.HookScript then
            chatFrame:HookScript("OnHyperlinkEnter", function(self, link, text)
                hoveredChatLink, hoveredChatText, hoveredChatFrame = link, text, self
            end)
            chatFrame:HookScript("OnHyperlinkLeave", function()
                hoveredChatLink, hoveredChatText, hoveredChatFrame = nil, nil, nil
            end)
        end
    end
end

-- Insert the result's link into the editbox the channel/whisper open just
-- activated. targetBox is the box we expect it to be -- the hovered frame's own
-- editbox for a channel (where chat-replacement addons like Prat keep their
-- box, and where ChatEdit_GetActiveWindow / ChatEdit_InsertLink do NOT look),
-- or the box we activated for a whisper -- with the active window then
-- ChatEdit_InsertLink as fallbacks. The user reviews and presses Enter.
local function InsertLinkIntoChatEditBox(targetBox, link)
    if targetBox and targetBox.IsShown and targetBox:IsShown() then
        targetBox:Insert(link)
        return
    end
    local active = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if active and active:IsShown() then
        active:Insert(link)
        return
    end
    if ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
end

-- Cursor over a chat channel / whisper hyperlink at drop time: open the editbox
-- to that target with the result's link inserted. Channels REUSE the chat
-- frame's own OnHyperlinkClick handler, so the editbox is set up exactly as a
-- real click on that label would set it. Hand-building the channel state from
-- the link number broke on numbered channels and on the stale channel links
-- that chat-history addons (Prat etc.) restore after a reload -- yet clicking
-- those same lines works, because the frame's handler (which those addons hook)
-- resolves them. A player link is whispered directly, since a real click on a
-- name opens a menu, not a whisper editbox. Returns true when it handled it.
-- hoverLink/hoverText/hoverFrame default to the live hover tracking, but a
-- caller that captured the hover at press time passes its own snapshot. They
-- are parameters, never writes back into the tracking upvalues: overwriting
-- those leaves a stale "cursor is over a chat link" forever, so every later
-- drop routes to a channel the cursor left long ago.
local function RouteLinkToHoveredChat(link, hoverLink, hoverText, hoverFrame)
    hoverLink = hoverLink or hoveredChatLink
    hoverText = hoverText or hoveredChatText
    hoverFrame = hoverFrame or hoveredChatFrame
    if not (link and link ~= "" and hoverLink and hoverFrame) then return false end
    local isChannel = hoverLink:match("^channel:") ~= nil
    local whisperTarget = hoverLink:match("^player:([^:]+)")
    -- Battle.net friends are BNplayer links, not player links. Blizzard's own
    -- click already opens the BN whisper, so we do not rebuild that state --
    -- we only need to land the link in whichever editbox it activates. Without
    -- this the match failed outright and the whisper opened empty.
    local isBNPlayer = hoverLink:match("^BNplayer:") ~= nil
    if not (isChannel or whisperTarget or isBNPlayer) then return false end
    local frame, chatLink, chatText = hoverFrame, hoverLink, hoverText
    return pcall(function()
        local targetBox
        if isChannel or isBNPlayer then
            -- Both reuse the frame's own click handler so the box is set up
            -- exactly as a real click would set it (and chat-replacement
            -- addons that hook it keep working). A channel's box lives on the
            -- frame; a BN whisper activates its own, so that one is looked up
            -- at insert time instead.
            local onHyperlinkClick = frame:GetScript("OnHyperlinkClick")
            if onHyperlinkClick then
                onHyperlinkClick(frame, chatLink, chatText, "LeftButton")
            end
            if isChannel then targetBox = frame.editBox end
        else
            local editBox = (ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend())
                or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
                or _G["ChatFrame1EditBox"]
            if editBox then
                Utils.SafeCallMethod(editBox, "SetAttribute", "chatType", "WHISPER")
                Utils.SafeCallMethod(editBox, "SetAttribute", "tellTarget", whisperTarget)
                if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(editBox) end
                if ChatEdit_ActivateChat then ChatEdit_ActivateChat(editBox) end
            end
            targetBox = editBox
        end
        -- Opening the channel/whisper activates the editbox (and a chat
        -- replacement can finish setting its box up) a frame late, so insert
        -- on the next frame.
        Utils.SafeAfter(0, function()
            InsertLinkIntoChatEditBox(targetBox, link)
        end)
    end)
end

-- The link of whatever result is currently carried on the cursor (picked up by
-- a click or drag) -- a bag item, a catalog item, a mount, all the same. WoW's
-- cursor model carries a pickup until the NEXT click, and that drop click
-- lands wherever the player aimed, not on our row, so a row mouse-up cannot
-- see it. The global watcher below routes the drop:
--   a chat channel / whisper label -> link into that channel
--   anywhere else on a chat window -> /say
--   empty world                    -> cancel, exactly like Escape
--   anything else (bag slot, bar)  -> left to the engine
local carriedItemLink
-- True when a REAL item sits on the cursor behind the link. Lookup rows (the
-- catalog, and anything stored on another character or in the bank) arm the
-- link even when nothing lands on the cursor, because PickupItem cannot pick up
-- an item this character does not own -- and the link text, not the cursor, is
-- what gets inserted into chat. The cursor checks below are the phantom guard
-- for genuinely-carried items; applying them to a link that never had a cursor
-- item wipes it before the drop, which reads as an empty chat box.
local carriedLinkCursorBacked = false

-- ESC must be able to put the carried item down. EasyFind holds an ESCAPE
-- override binding while the bar has dismissable state, so the engine's own
-- "ESC clears the cursor" never runs -- the item would stay stuck on the
-- cursor through every ESC press, and the next click anywhere would fire the
-- drop (popping the chat editbox open). Search:HandleEscape consumes this
-- first, so one ESC always puts the item down.
function ns.HasCarriedItemLink()
    return carriedItemLink ~= nil
end

function ns.ClearCarriedItemLink()
    if not carriedItemLink then return false end
    carriedItemLink = nil
    carriedLinkCursorBacked = false
    if ClearCursor then ClearCursor() end
    if Utils.RefreshEscArm then Utils.RefreshEscArm() end
    return true
end

-- Open the chat editbox to /say with the link, WITHOUT sending it (the user
-- reviews and presses Enter). ChatFrame_OpenChat is the standard "start typing"
-- entry point; ChatEdit_ActivateChat submits the box on some setups.
local function DropLinkToSay(link)
    if not link or link == "" then return false end
    return pcall(function()
        local chatFrame = DEFAULT_CHAT_FRAME or _G["ChatFrame1"]
        if ChatFrame_OpenChat then ChatFrame_OpenChat("", chatFrame) end
        local editBox = (chatFrame and chatFrame.editBox)
            or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
            or _G["ChatFrame1EditBox"]
        if not editBox then return end
        Utils.SafeCallMethod(editBox, "SetAttribute", "chatType", "SAY")
        if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(editBox) end
        -- Insert on the NEXT frame, exactly like the channel path: ChatFrame_
        -- OpenChat finishes activating the editbox (and sets its text) a frame
        -- late, so a synchronous Insert here is wiped -- /say opened with no
        -- link in it.
        Utils.SafeAfter(0, function()
            InsertLinkIntoChatEditBox(editBox, link)
        end)
    end)
end

-- Was the click over empty world (free space), not any interactive UI frame?
local function ClickedFreeSpace()
    if not GetMouseFoci then return true end
    local foci = GetMouseFoci()
    if not foci or #foci == 0 then return true end
    for i = 1, #foci do
        if foci[i] ~= WorldFrame then return false end
    end
    return true
end

-- Is the cursor inside frame's rectangle? Geometric, NOT GetMouseFoci: that
-- only reports mouse-ENABLED frames, and a chat window's message area is
-- click-through, so a drop onto chat reads as empty world and would cancel
-- instead of going to /say.
local function CursorInsideFrame(frame)
    if not (frame and frame.IsVisible and frame:IsVisible() and frame.GetLeft) then
        return false
    end
    local left, right = frame:GetLeft(), frame:GetRight()
    local bottom, top = frame:GetBottom(), frame:GetTop()
    if not (left and right and bottom and top) then return false end
    local scale = frame:GetEffectiveScale()
    local x, y = GetCursorPosition()
    return x >= left * scale and x <= right * scale
       and y >= bottom * scale and y <= top * scale
end

-- Was the drop over a chat window (its message area or its edit box) but NOT
-- on a channel/whisper label? That is the "/say" target: the player aimed at
-- chat without naming a channel.
local function ClickedChatBox()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local chatFrame = _G["ChatFrame" .. i]
        if CursorInsideFrame(chatFrame) then return true end
        if chatFrame and CursorInsideFrame(chatFrame.editBox) then return true end
    end
    return false
end

-- Global watcher for a carried result: routes the drop by what is under the
-- cursor (see the carriedItemLink comment above). CURSOR_CHANGED forgets the
-- link once the cursor empties, whether we cleared it or the engine did.
local worldDropInstalled = false
local function EnsureItemDropRouting()
    if worldDropInstalled then return end
    worldDropInstalled = true
    -- The drop is decided on mouse-DOWN (that is when the cursor still holds
    -- the item and the hovered chat link is still tracked) but PERFORMED on
    -- mouse-UP. Doing the insert on the down edge put it one frame later --
    -- still well before the button came up -- and then Blizzard's own
    -- hyperlink click, which fires on the UP edge, re-opened the channel
    -- editbox and wiped it: the link appeared and vanished as if backspaced.
    local pendingDrop
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
    watcher:RegisterEvent("GLOBAL_MOUSE_UP")
    watcher:RegisterEvent("CURSOR_CHANGED")
    watcher:SetScript("OnEvent", function(_, event, button)
        if event == "CURSOR_CHANGED" then
            if carriedLinkCursorBacked and carriedItemLink
               and not (GetCursorInfo and GetCursorInfo()) then
                carriedItemLink = nil
                carriedLinkCursorBacked = false
                if Utils.RefreshEscArm then Utils.RefreshEscArm() end
            end
            return
        end
        if button ~= "LeftButton" or InCombatLockdown() then return end

        if event == "GLOBAL_MOUSE_UP" then
            local drop = pendingDrop
            pendingDrop = nil
            if not drop then return end
            -- Pass the hover context captured at press time (the cursor may
            -- have drifted off the label between the edges) as ARGUMENTS --
            -- assigning it back into the tracking upvalues would strand a
            -- stale "over a chat link" that hijacks every later drop.
            local routed = RouteLinkToHoveredChat(drop.link, drop.hoveredLink,
                drop.hoveredText, drop.hoveredFrame)
            -- Aimed at chat but not at a named channel: /say. Free space is
            -- NOT a /say target -- it cancels (handled on the down edge).
            if not routed and drop.chatBox then
                DropLinkToSay(drop.link)
            end
            if Utils.RefreshEscArm then Utils.RefreshEscArm() end
            return
        end

        if not carriedItemLink then return end
        -- The link is only live while the item is REALLY on the cursor. Without
        -- this the armed link outlives the pickup (ESC or any other cursor
        -- clear that does not fire CURSOR_CHANGED first), and the next stray
        -- left-click anywhere pops the chat editbox open with the link in it --
        -- which then eats the player's ESC and reads as "ESC is broken".
        if carriedLinkCursorBacked and not (GetCursorInfo and GetCursorInfo()) then
            carriedItemLink = nil
            carriedLinkCursorBacked = false
            return
        end
        local overChat = hoveredChatLink and hoveredChatFrame
        local chatBox = not overChat and ClickedChatBox()
        -- Chat is tested FIRST: its message area is click-through, so it also
        -- satisfies the free-space test, and checking free space first would
        -- cancel every drop aimed at chat.
        if not overChat and not chatBox and ClickedFreeSpace() then
            -- Free space cancels, exactly like Escape. It deliberately does
            -- NOT go to /say: for a real bag item that drop is the destroy-item
            -- prompt, so putting it down is both the safe and the expected
            -- outcome of "I changed my mind".
            carriedItemLink = nil
            carriedLinkCursorBacked = false
            ClearCursor()
            if Utils.RefreshEscArm then Utils.RefreshEscArm() end
            return
        end
        -- Anything else (a bag slot, an action bar, another addon's frame) is
        -- left to the engine: the item is genuinely being dropped there.
        if not (overChat or chatBox) then return end
        pendingDrop = {
            link = carriedItemLink,
            hoveredLink = hoveredChatLink,
            hoveredText = hoveredChatText,
            hoveredFrame = hoveredChatFrame,
            chatBox = chatBox,
        }
        carriedItemLink = nil
        carriedLinkCursorBacked = false
        ClearCursor()
        if Utils.RefreshEscArm then Utils.RefreshEscArm() end
    end)
end

local function CollapsedNodes()
    return Results._collapsedNodes
end

function Rows.InstallInteractions(resultRow, index)
    EnsureChatHyperlinkTracking()
    EnsureItemDropRouting()
    -- LeftButtonDown for the secure cast: type=spell silently no-ops
    -- on LeftButtonUp for many spells (this was confirmed in the TBC
    -- version where Down works perfectly). RegisterForDrag would
    -- defer the Down click and break that, so we route drag-to-bar
    -- through Shift+click instead (handled in PreClick below).
    -- LeftButtonUp is registered too: panel-opener rows fire their
    -- secure tab steer on the release edge (typerelease, see
    -- Shared/SecureOpeners.lua); PreClick/PostClick gate on the edge so
    -- every other behavior still runs exactly once, on the press.
    resultRow:RegisterForClicks("LeftButtonDown", "LeftButtonUp", "RightButtonUp")

    -- Shift+drag on a row picks the action up onto the cursor (for
    -- placing on action bars, banks, etc.) instead of casting. We
    -- can't use RegisterForDrag here because it defers the Down
    -- click and silently breaks type=spell casts. So we do it
    -- manually: PreClick detects Shift and clears the secure type
    -- so the cast doesn't fire, OnMouseDown records the press
    -- position, OnUpdate watches for movement, and the actual
    -- Pickup* call happens once the cursor has moved past the
    -- 5px drag threshold. Plain shift+click without movement
    -- does nothing, matches Blizzard's action-bar drag feel.
    -- C_Spell.PickupSpell is preferred over the legacy global since
    -- Midnight phased PickupSpell out for some spells.
    local function PickupSpellCompat(spellID)
        if C_Spell and C_Spell.PickupSpell then
            C_Spell.PickupSpell(spellID)
        elseif PickupSpell then
            PickupSpell(spellID)
        end
    end
    local function CanPickupRowAction(d)
        if not d then return false end
        if d.mountID then return Icons:IsMountSummonable(d) end
        if d.toyItemID then return not d.isToyboxOnly end
        if d.petID then return true end
        if d.outfitID or d.macroIndex then return true end
        if d.spellID then
            return d.category == "Ability" and not Icons:IsSpellbookOnlyAbility(d)
        end
        return (d.bagID and d.bagSlot) or d.itemID
    end
    -- Rows whose only action is "put the item on the cursor so it can be
    -- linked": the catalog, plus anything stored where this character cannot
    -- reach it. They share one click/drag behaviour so the player never has to
    -- learn which kind of item row they are looking at.
    local function PickupRowAction(d)
        if not CanPickupRowAction(d) then return end
        if InCombatLockdown() then return end
        ClearCursor()
        if d.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
            local _, spellID = C_MountJournal.GetMountInfoByID(d.mountID)
            if spellID then PickupSpellCompat(spellID) end
        elseif d.petID and C_PetJournal and C_PetJournal.PickupPet then
            C_PetJournal.PickupPet(d.petID)
        elseif d.toyItemID and C_ToyBox and C_ToyBox.PickupToyBoxItem then
            C_ToyBox.PickupToyBoxItem(d.toyItemID)
        elseif d.outfitID and C_TransmogOutfitInfo and C_TransmogOutfitInfo.PickupOutfit then
            C_TransmogOutfitInfo.PickupOutfit(d.outfitID)
        elseif d.macroIndex and PickupMacro then
            PickupMacro(d.macroIndex)
        elseif d.spellID then
            PickupSpellCompat(d.spellID)
        elseif d.bagID and d.bagSlot then
            local pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
            if pickup then
                pickup(d.bagID, d.bagSlot)
            elseif d.itemID and PickupItem then
                PickupItem(d.itemID)
            end
        elseif d.itemID and PickupItem then
            PickupItem(d.itemID)
        end
        -- Any row carrying a real item link qualifies, not just catalog rows:
        -- a bag item dragged to chat should link exactly like a catalog item.
        -- The two used to behave differently for no reason the player could see.
        carriedItemLink = nil
        carriedLinkCursorBacked = false
        local onCursor = GetCursorInfo and GetCursorInfo() ~= nil
        -- A lookup row's whole purpose is the link, and an unowned item never
        -- reaches the cursor, so those arm either way. Everything else keeps
        -- the cursor requirement: an armed link with no pickup behind it is a
        -- phantom that fires on some later unrelated click.
        if ns.GetResultLink and (onCursor or Handlers:IsLookupRow(d)) then
            carriedItemLink = ns.GetResultLink(d)
            carriedLinkCursorBacked = onCursor and carriedItemLink ~= nil
        end
        -- Carrying an item is dismissable state: re-arm ESC so the very next
        -- press puts it down instead of being swallowed by a stale predicate.
        if Utils.RefreshEscArm then Utils.RefreshEscArm() end
    end
    local function SetSecureOutfit(row, outfitIndex)
        if row._lastAttrKey and row._lastAttrKey ~= "outfit-index" then
            Utils.SafeCallMethod(row, "SetAttribute", row._lastAttrKey, nil)
        end
        Utils.SafeCallMethod(row, "SetAttribute", "type", "outfit")
        Utils.SafeCallMethod(row, "SetAttribute", "outfit-index", outfitIndex)
        Utils.SafeCallMethod(row, "SetAttribute", "action", nil)
        row._lastAttrType = "outfit"
        row._lastAttrKey = "outfit-index"
        row._lastAttrVal = outfitIndex
    end
    local DRAG_PX = 5
    -- HookScript not SetScript: SecureActionButtonTemplate uses the
    -- native OnMouseDown / OnMouseUp handlers internally to dispatch
    -- the secure click. SetScript would replace them and break casts.
    resultRow:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._pickedUp = nil
        local d = self.data
        -- Catalog: a plain (no Shift/Ctrl) left click or drag picks the item
        -- onto the cursor to send its link (drop on a chat channel, or empty
        -- world -> /say). This only arms the drag threshold; the pickup itself
        -- happens on the release in OnMouseUp. Shift is chat-link, Ctrl is
        -- dressing room.
        if Handlers:IsLookupRow(d) then
            -- Every modifier already means something on these rows (Shift chat
            -- insert, Ctrl dressing room, Alt owning UI), so none may also arm
            -- a pickup: the item would land on the cursor on top of that
            -- action and surface later as if from nowhere.
            if IsShiftKeyDown() or (IsControlKeyDown and IsControlKeyDown())
               or Handlers:IsSourceModifierHeld() then
                return
            end
            local x, y = GetCursorPosition()
            self._dragOriginX, self._dragOriginY = x, y
            return
        end
        -- Other rows: Shift+drag picks the action up (movement in OnUpdate);
        -- plain clicks fall through to the cast / navigation.
        if not IsShiftKeyDown() then return end
        if not CanPickupRowAction(d) then return end
        local x, y = GetCursorPosition()
        self._dragOriginX, self._dragOriginY = x, y
    end)
    resultRow:HookScript("OnUpdate", function(self)
        if not self._dragOriginX then return end
        local x, y = GetCursorPosition()
        local dx, dy = x - self._dragOriginX, y - self._dragOriginY
        if dx * dx + dy * dy < DRAG_PX * DRAG_PX then return end
        self._dragOriginX, self._dragOriginY = nil, nil
        self._pickedUp = true
        if self.data then PickupRowAction(self.data) end
    end)
    resultRow:HookScript("OnMouseUp", function(self, button)
        if not InCombatLockdown() and ns.ResultSecureAttributes then
            ns.ResultSecureAttributes.ArmSteerLate(self)
        end
        self._dragOriginX, self._dragOriginY = nil, nil
        -- Catalog rows: a plain LEFT click picks the item onto the cursor, same
        -- as a drag, so the next click drops its link into a chat channel (or
        -- onto empty world -> /say). The pickup happens on the RELEASE, never
        -- the press: an item picked up on mouse-down is dropped again by the
        -- engine when the button comes up, which is why this used to need a
        -- drag. Right-click never comes here -- it belongs to the context menu.
        local clicked = self.data
        if button == "LeftButton" and Handlers:IsLookupRow(clicked)
           and not self._pickedUp
           and not InCombatLockdown()
           and not IsShiftKeyDown()
           and not (IsControlKeyDown and IsControlKeyDown())
           and not Handlers:IsSourceModifierHeld() then
            PickupRowAction(clicked)
            -- Dismiss like every other activated row. Done AFTER the pickup
            -- (SelectResult runs on the press, this is the release) so hiding
            -- the row cannot cancel the pickup, and it leaves no results panel
            -- or stale query behind -- which is what kept the ESC override
            -- armed with nothing left to close.
            Handlers:FinishResultSelection()
            return
        end
        -- Only a completed drag (OnUpdate set _pickedUp) acts past here.
        if not self._pickedUp then return end
        if InCombatLockdown() then return end
        -- Capture BEFORE dismissing: rows are pooled, so FinishResultSelection
        -- can recycle this row's data out from under the routing below.
        local draggedLink = ns.GetResultLink and ns.GetResultLink(self.data)
        -- A finished drag activated the row exactly as a click does, so it
        -- dismisses the same way. Without this the query, results and quick
        -- filters stayed behind after a drag but not after a click.
        -- Safe during a drag: this clears the search, never the cursor.
        Handlers:FinishResultSelection()
        -- Released over a chat channel/whisper hyperlink: route the link there.
        if RouteLinkToHoveredChat(draggedLink) then
            ClearCursor()
            return
        end
        local cursorType = GetCursorInfo and GetCursorInfo()
        if cursorType then
            local foci
            if GetMouseFoci then
                foci = GetMouseFoci()
            elseif GetMouseFocus then
                foci = { GetMouseFocus() }
            end
            if foci then
                for i = 1, #foci do
                    local f = foci[i]
                    local slot = f and (f.action or (f.GetAttribute and f:GetAttribute("action")))
                    if slot then
                        if PlaceAction then PlaceAction(slot) end
                        ClearCursor()
                        return
                    end
                end
            end
        end
    end)
    resultRow:SetScript("PreClick", function(self, mouseButton, down)
        if mouseButton ~= "LeftButton" then return end
        -- The release dispatch exists only for the secure tab steer;
        -- attributes were armed at press time.
        if not down then return end
        self._outfitSecureClicked = nil
        if InCombatLockdown() then return end

        local d = self.data

        -- Click-time re-sync: render-time armed state can be stale (panel
        -- toggled since); PreClick attribute writes apply to this click.
        ns.ResultSecureAttributes.ApplyAtClick(self, d)

        -- Shift+click with a chat editbox active inserts the row's real
        -- hyperlink, like shift-clicking an item anywhere in the game.
        -- Takes priority over pickup (matching native behavior), kills
        -- the secure action, and cancels any pending drag detection.
        if d and ns.TryInsertResultChatLink and ns.TryInsertResultChatLink(d) then
            ns.ResultSecureAttributes.Clear(self)
            self._dragOriginX, self._dragOriginY = nil, nil
            self._chatLinkInserted = true
            return
        end

        -- Shift held: kill the cast for this click. The pickup (if any)
        -- happens via the OnMouseDown / OnUpdate drag detection above:
        -- this branch only ensures the secure handler is a no-op so
        -- nothing fires when the user hasn't moved yet. Setting the
        -- skip-navigation flag here (not waiting for OnUpdate) is what
        -- prevents PostClick from closing the window before OnUpdate
        -- has had a chance to detect movement and pick up the action.
        if d and IsShiftKeyDown() and CanPickupRowAction(d) then
            ns.ResultSecureAttributes.Clear(self)
            self._pickedUp = true
            return
        end

        -- Alt+click is the "show owning Search" modifier. Ctrl remains for
        -- Blizzard-style previews such as mounts and equippable bag items.
        local sourceModifierHeld = Handlers:IsSourceModifierHeld()
        local ctrlHeld = IsControlKeyDown and IsControlKeyDown()
        local bagItemKind = (d and d.itemID and d.category == "Bag")
            and Handlers:GetBagItemActionKind(d)

        -- Alt+click on an ability row means "show it in the spellbook":
        -- castable rows swap their cast for the secure open macro this
        -- click (PostClick's reveal then finds the panel securely open);
        -- spellbook-only rows already carry the open macro as their
        -- primary action and keep it. IsSourceModifierHeld is false during
        -- shortcut/shortkey activations, so ALT-chord bindings never land
        -- here and the plain cast fires for them.
        if sourceModifierHeld and d and d.spellID and d.category == "Ability" then
            if not Icons:IsSpellbookOnlyAbility(d) then
                ns.ResultSecureAttributes.SwapToPanelOpen(self)
            end
            return
        end

        local suppressSecureClick = d and (
            (sourceModifierHeld and (d.macroIndex or d.mountID or d.toyItemID
                or d.outfitID or (d.itemID and d.category == "Bag")))
            or (d.mountID and (ctrlHeld or not Icons:IsMountSummonable(d)))
            or (ctrlHeld and bagItemKind == "equip")
        )
        if suppressSecureClick then
            ns.ResultSecureAttributes.Clear(self)
            return
        end

        if not (d and d.outfitID) then return end
        if Rows:IsOutfitCooldownActive() then
            ns.ResultSecureAttributes.Clear(self)
            return
        end

        local outfitIndex = Handlers:GetOutfitSecureIndex(d)
        if not outfitIndex then
            ns.ResultSecureAttributes.Clear(self)
            return
        end
        SetSecureOutfit(self, outfitIndex)
        self._outfitSecureClicked = d.outfitID
    end)
    resultRow:SetScript("PostClick", function(self, mouseButton, down)
        -- Panel-opener clicks act on the RELEASE dispatch, after the
        -- secure tab steer has run, so the navigation follow-up finds the
        -- right tab already selected and never falls back to the tainted
        -- ClickButton(tab). Everything else acts on the press dispatch,
        -- exactly as before both left edges were registered.
        if mouseButton == "LeftButton" then
            if ns.ResultSecureAttributes.ActsOnRelease(self, self.data) then
                if down then return end
            elseif not down then
                return
            end
        end

        -- Shift+click chat insert: the link went into the editbox; keep
        -- the results open and don't navigate.
        if self._chatLinkInserted then
            self._chatLinkInserted = nil
            return
        end
        -- Shift+click pickup: cursor is holding the action for the
        -- user to drop on a bar. Don't navigate away or close.
        if self._pickedUp then
            self._pickedUp = nil
            return
        end
        -- Catalog plain click picks the item up in OnMouseUp (reliable raw
        -- event); PostClick only needs to route Ctrl (dressing room) through
        -- SelectResult below.
        -- Block result selection if outfit equip is on cooldown (keep results open).
        -- Toys are deliberately NOT checked here: GetItemCooldown returns the
        -- cast-time of a freshly-started channel as a "cooldown", which would
        -- keep the window open every time you click a cast-toy (Hearthstone,
        -- garrison hearthstone, etc.). Outfit cooldown is a real swap-lockout
        -- we manage ourselves, so it's safe to gate on.
        if self.data and mouseButton == "LeftButton" and self.data.outfitID
           and not Handlers:IsSourceModifierHeld()
           and Rows.outfitCdStart > 0
           and Rows.outfitCdDuration - (GetTime() - Rows.outfitCdStart) > 0 then
            if Search:GetSearchFrame() and Search:GetSearchFrame().editBox and not Search:GetNavFrame():IsKeyboardEnabled() then
                Search:GetSearchFrame().editBox.blockFocus = nil
                Search:GetSearchFrame().editBox:SetFocus()
            end
            return
        end

        if self._outfitSecureClicked then
            Rows.lastEquippedOutfitID = self._outfitSecureClicked
            Rows.outfitCdStart = GetTime()
            Rows.outfitCdDuration = 4
            self._outfitSecureClicked = nil
        end
        -- Right-click: show pin/unpin popup (plus Guide row if entry has a guide path)
        if mouseButton == "RightButton" and self.data then
            Rows:ShowResultContextMenu(self, false)
            return
        end

        -- Unearned currencies and level-locked results are inert
        if self.isUnearnedCurrency or self.lockedReason then
            return
        end

        -- Setting click. Checkbox: toggle inline (Alt+click opens the
        -- panel). Everything else (slider / keybind / dropdown): open
        -- the panel so the user lands on the setting they searched for.
        -- Inline editors (slider drag, kb1/kb2 capture, dropdown
        -- paddles) sit on top of the row and consume their own clicks,
        -- so reaching this handler means the user clicked the label.
        if Rows:ActivateSettingResult(self.data, Handlers:IsSourceModifierHeld()) then return end

        if self.isPinHeader then
            return
        end

        if self.isPathNode then
            -- Retail theme: headerTab and toggleBtn handle clicks directly
            local isRetailHeader = self.headerTab and self.headerTab:IsShown()
            if isRetailHeader then
                if self.data then
                    Handlers:SelectResult(self.data)
                end
            else
                local cursorX = GetCursorPosition()
                local scale = self:GetEffectiveScale()
                local btnLeft = self:GetLeft() * scale
                local depth = self.pathNodeDepth or 0
                local iconLeft = btnLeft + depth * 20 * scale  -- INDENT_PX = 20
                local isToggleClick = cursorX <= (iconLeft + 35 * scale)

                if isToggleClick then
                    local key = (self.pathNodeName or "") .. "_" .. (self.pathNodeDepth or 0)
                    CollapsedNodes()[key] = not CollapsedNodes()[key]
                    if Results._cachedHierarchical then
                        Render:ShowHierarchicalResults(Results._cachedHierarchical, true)
                    end
                elseif self.data then
                    Handlers:SelectResult(self.data)
                end
            end
        elseif self.data then
            Handlers:SelectResult(self.data)
        end
    end)
end
