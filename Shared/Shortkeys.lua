local _, ns = ...

-- Per-row keybinds ("shortkeys"). A shortkey binds a key to a search row's
-- action so pressing it executes that row even with the search bar closed.
-- Rows are identified by the same stable key as aliases (Aliases:GetEntryKey),
-- so a row's alias and shortkey line up in the combined management table.
--
-- Execution reuses the result-row machinery: a hidden pool of secure buttons
-- gets each row's secure attributes (cast / use / equip / run), and the bound
-- key is routed to the matching button via SetOverrideBindingClick, which takes
-- precedence over game binds. Navigation rows (open a panel, show a guide) have
-- no secure action, so their button runs SelectResult on press instead.

local Shortkeys = {}
ns.Shortkeys = Shortkeys

local Utils = ns.Utils
local InCombatLockdown = InCombatLockdown
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings
local GetBindingAction = GetBindingAction
local pairs = pairs
local wipe = wipe

local function CharKey()
    local name = UnitName and UnitName("player")
    local realm = GetRealmName and GetRealmName()
    return (name or "?") .. "-" .. (realm or "?")
end

-- Class/spec-specific rows must not carry across characters; everything else
-- (collections, commands, panels, account macros) is account-wide.
function Shortkeys:IsCharacterSpecific(data)
    if not data then return false end
    local cat = data.category
    if cat == "Ability" or cat == "Talent" then return true end
    if data.macroIndex and data.macroIsChar then return true end
    return false
end

local function AccountStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.shortkeys = EasyFind.db.shortkeys or {}
    return EasyFind.db.shortkeys
end

local function CharStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.shortkeysPerChar = EasyFind.db.shortkeysPerChar or {}
    local ck = CharKey()
    EasyFind.db.shortkeysPerChar[ck] = EasyFind.db.shortkeysPerChar[ck] or {}
    return EasyFind.db.shortkeysPerChar[ck]
end

function Shortkeys:GetEntryKey(data)
    return ns.Aliases and ns.Aliases:GetEntryKey(data) or nil
end

-- Returns (info, isCharSpecific) for the shortkey on a given row key, if any.
function Shortkeys:Get(rowKey)
    if not rowKey then return nil end
    local acct = AccountStore()
    if acct and acct[rowKey] then return acct[rowKey], false end
    local perChar = CharStore()
    if perChar and perChar[rowKey] then return perChar[rowKey], true end
    return nil
end

-- Iterate every shortkey active for this character: account-wide plus this
-- character's own. cb(rowKey, info, isCharSpecific).
function Shortkeys:ForEach(cb)
    local acct = AccountStore()
    if acct then for k, info in pairs(acct) do cb(k, info, false) end end
    local perChar = CharStore()
    if perChar then for k, info in pairs(perChar) do cb(k, info, true) end end
end

-- Drop whatever row currently owns this bind, in both stores (one key -> one
-- row, like a normal keybind).
function Shortkeys:RemoveBind(bindKey)
    if not bindKey then return end
    local acct = AccountStore()
    if acct then
        for k, info in pairs(acct) do
            if info.key == bindKey then acct[k] = nil end
        end
    end
    local perChar = CharStore()
    if perChar then
        for k, info in pairs(perChar) do
            if info.key == bindKey then perChar[k] = nil end
        end
    end
end

function Shortkeys:Remove(rowKey)
    if not rowKey then return false end
    local removed = false
    local acct = AccountStore()
    if acct and acct[rowKey] then acct[rowKey] = nil; removed = true end
    local perChar = CharStore()
    if perChar and perChar[rowKey] then perChar[rowKey] = nil; removed = true end
    if removed then self:ApplyAll() end
    return removed
end

-- Clears every shortkey (account-wide + current character) and drops their
-- override bindings via ApplyAll. Mirrors Aliases:ClearAll for the combined
-- management table's "Clear all".
function Shortkeys:ClearAll()
    if not (EasyFind and EasyFind.db) then return end
    local acct = AccountStore()
    if acct then wipe(acct) end
    local pc = CharStore()
    if pc then wipe(pc) end
    self:ApplyAll()
end

-- Bind bindKey (e.g. "CTRL-1") to a row identified by its stable key. Reassigns
-- the key off any other row first, then routes the row to the right store. Used
-- directly by the options table, where live row data may not be present.
function Shortkeys:SetByKey(rowKey, name, charSpecific, bindKey)
    if not (EasyFind and EasyFind.db and rowKey) then return false end
    if not bindKey or bindKey == "" then return false end
    self:RemoveBind(bindKey)
    local acct = AccountStore()
    if acct then acct[rowKey] = nil end
    local pc = CharStore()
    if pc then pc[rowKey] = nil end
    local store = charSpecific and CharStore() or AccountStore()
    if not store then return false end
    store[rowKey] = { key = bindKey, name = name, charSpecific = charSpecific or nil }
    self:ApplyAll()
    return true
end

-- Execution engine: hidden owner frame + secure button pool + override binds.
local owner
local pool = {}
local POOL_PREFIX = "EasyFindShortkeyButton"

local function ResolveData(rowKey)
    return ns.Aliases and ns.Aliases:FindEntryByKey(rowKey) or nil
end

local function OnShortkeyButtonClick(self)
    -- Shortkey navigation is silently inert in combat: the paths it drives
    -- (panel opens, guides, hiding the search frame) are protected, and a
    -- chat notice per press was spam. The capture popup and the tutorial
    -- carry the "shortkeys do not work in combat" note instead. Secure cast
    -- rows are unaffected; their action fires from the secure attributes.
    if InCombatLockdown() then return end
    -- Secure rows already fired their action from the secure attributes; this
    -- insecure handler only drives navigation rows (open panel / guide / pin),
    -- resolved live so they never go stale.
    local rowKey = self._rowKey
    local data = rowKey and ResolveData(rowKey)
    if not data then return end
    if ns.ResultIcons and ns.ResultIcons:IsSecureActionResult(data) then return end
    -- Call directly (not deferred): this runs in the key press's hardware-event
    -- context, which ShowUIPanel needs to open protected panels.
    if ns.ResultHandlers and ns.ResultHandlers.SelectResult then
        -- The shortkey's own modifier (e.g. ALT-1 / CTRL-X) is physically held as
        -- this fires. Flag the activation -- exactly like the in-bar result
        -- shortcut -- so the source-modifier checks don't read the bind's
        -- modifier as a deliberate Alt/Ctrl click and take the wrong branch
        -- (e.g. open-the-journal instead of the default hover-dismiss highlight).
        local shortcuts = ns.ResultShortcuts
        if shortcuts then shortcuts._resultShortcutActivation = true end
        ns.ResultHandlers:SelectResult(data)
        if shortcuts then shortcuts._resultShortcutActivation = nil end
    end
end

local function EnsureOwner()
    if owner then return owner end
    owner = CreateFrame("Frame", "EasyFindShortkeyOwner", UIParent)
    owner:SetSize(1, 1)
    owner:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    owner:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            -- Fires before combat lockdown engages, so clearing is legal:
            -- strip every shortkey override for the whole fight. Combat
            -- keypresses fall through to the player's own binds, and
            -- nothing of ours can run or taint. Shortkeys are documented
            -- as not working in combat; this makes that literal.
            ClearOverrideBindings(self)
            return
        end
        Shortkeys:ApplyAll()
    end)
    -- Refresh secure attributes when the things they encode can change. The
    -- only ones that drift are reordered outfits (player-facing index) and
    -- edited macro bodies; ApplyAll defers to PLAYER_REGEN_ENABLED if in
    -- combat. REGEN events stay registered permanently: DISABLED strips the
    -- binds for combat, ENABLED reapplies them after.
    owner:RegisterEvent("PLAYER_REGEN_DISABLED")
    owner:RegisterEvent("PLAYER_REGEN_ENABLED")
    owner:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    owner:RegisterEvent("PLAYER_ENTERING_WORLD")
    owner:RegisterEvent("TRANSMOG_OUTFITS_CHANGED")
    owner:RegisterEvent("UPDATE_MACROS")
    return owner
end

local function GetButton(i)
    if pool[i] then return pool[i] end
    EnsureOwner()
    local b = CreateFrame("Button", POOL_PREFIX .. i, owner, "SecureActionButtonTemplate")
    -- Must stay SHOWN: a hidden secure button won't dispatch its protected
    -- action when triggered by a keybind. Keep it 1px in the corner.
    b:SetSize(1, 1)
    b:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", 0, 0)
    -- Match EasyFind's result rows exactly: register "LeftButtonDown" and drive
    -- our navigation handler from PostClick. SecureActionButtonTemplate
    -- dispatches the protected action through its own OnClick, so we must NOT
    -- replace OnClick; doing so was why the secure action never fired.
    b:RegisterForClicks("LeftButtonDown")
    b:SetScript("PostClick", OnShortkeyButtonClick)
    pool[i] = b
    return b
end

function Shortkeys:ApplyAll()
    if not (EasyFind and EasyFind.db) then return end
    EnsureOwner()
    if InCombatLockdown() then
        owner:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    ClearOverrideBindings(owner)

    local list = {}
    self:ForEach(function(rowKey, info)
        list[#list + 1] = { rowKey = rowKey, key = info.key }
    end)

    for i = 1, #list do
        local rowKey = list[i].rowKey
        local bindKey = list[i].key
        local data = ResolveData(rowKey)
        if data and bindKey and bindKey ~= "" then
            local b = GetButton(i)
            b._rowKey = rowKey
            if ns.ResultIcons and ns.ResultIcons:IsSecureActionResult(data) then
                if ns.ResultSecureAttributes and ns.ResultSecureAttributes.Apply then
                    ns.ResultSecureAttributes.Apply(b, data)
                end
            else
                -- Navigation row: no secure action, OnClick handles it. Wipe any
                -- secure type left from a previous binding of this pool button.
                Utils.SafeCallMethod(b, "SetAttribute", "type", nil)
            end
            local btnName = b:GetName()
            if btnName then
                SetOverrideBindingClick(owner, true, bindKey, btnName, "LeftButton")
            end
        end
    end
end

-- Capture popup: shown from the row's "Add shortkey" menu option.
local L = ns.L
local capturePopup

-- Conflict detection: returns ("shortkey", otherRowName) if combo already
-- belongs to a different EasyFind shortkey, or ("bind", combo) if combo is a
-- live game/addon keybinding, or nil if free. The shortkey case wins because
-- silently overwriting the player's own shortkey is the more destructive one.
local function DetectBindConflict(rowKey, combo)
    local otherName
    Shortkeys:ForEach(function(k, info)
        if not otherName and k ~= rowKey and info.key == combo then
            otherName = info.name or "?"
        end
    end)
    if otherName then return "shortkey", otherName end
    local action = GetBindingAction and GetBindingAction(combo)
    if action and action ~= "" then return "bind", combo end
    return nil
end

local function CommitShortkey(rowKey, name, charSpecific, combo)
    if not Shortkeys:SetByKey(rowKey, name, charSpecific, combo) then return end
    if EasyFind and EasyFind.Print then
        EasyFind:Print((L["SHORTKEY_SAVED"]):format(combo, name or "?"))
    end
    local sf = ns.Search and ns.Search:GetSearchFrame()
    local eb = sf and sf.editBox
    local typedQuery = ns.Search.GetTypedQuery and ns.Search:GetTypedQuery() or (eb and eb:GetText()) or ""
    if typedQuery ~= "" then ns.Search:OnSearchTextChanged(typedQuery) end
    if ns.RefreshShortkeyTable then ns.RefreshShortkeyTable() end
end

-- "Continue anyway?" confirmation with a "Don't ask me again" checkbox that
-- writes EasyFind.db.shortkeyConflictPrompt = false to suppress all future
-- conflict warnings.
local conflictPopup
local function BuildConflictPopup()
    local f = CreateFrame("Frame", "EasyFindShortkeyConflict", UIParent, "BackdropTemplate")
    f:SetSize(340, 150)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ns.StyleMenuPanel(f)

    f.message = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.message:SetPoint("TOPLEFT", 16, -18)
    f.message:SetPoint("TOPRIGHT", -16, -18)
    f.message:SetJustifyH("CENTER")
    f.message:SetWordWrap(true)

    local cb = CreateFrame("CheckButton", nil, f)
    cb:SetSize(20, 20)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    f.dontAsk = cb
    local cbLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cbLabel:SetText(L["SHORTKEY_CONFLICT_DONT_ASK"])
    -- Center the [checkbox][gap][label] group on the popup's horizontal center:
    -- group width = 20 (box) + 4 (gap) + label, so the box's left edge sits half
    -- the group width left of center.
    local groupHalf = math.floor((20 + 4 + cbLabel:GetStringWidth()) / 2)
    cb:SetPoint("BOTTOMLEFT", f, "BOTTOM", -groupHalf, 46)

    local continueBtn = ns.CreateModernButton(f, _G["CONTINUE"] or "Continue", 110, 24)
    continueBtn:SetPoint("BOTTOM", f, "BOTTOM", -58, 14)
    continueBtn:SetScript("OnClick", function()
        if f.dontAsk:GetChecked() then EasyFind.db.shortkeyConflictPrompt = false end
        local onAccept = f.onAccept
        f:Hide()
        if onAccept then onAccept() end
    end)

    local cancelBtn = ns.CreateModernButton(f, _G["CANCEL"] or "Cancel", 110, 24)
    cancelBtn:SetPoint("BOTTOM", f, "BOTTOM", 58, 14)
    cancelBtn:SetScript("OnClick", function()
        if f.dontAsk:GetChecked() then EasyFind.db.shortkeyConflictPrompt = false end
        f:Hide()
    end)

    local close = ns.CreateCloseX(f, 14)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self) self.onAccept = nil end)
    f:Hide()
    return f
end

local function ShowConflictPopup(message, onAccept)
    if not conflictPopup then conflictPopup = BuildConflictPopup() end
    conflictPopup.onAccept = onAccept
    conflictPopup.dontAsk:SetChecked(false)
    conflictPopup.message:SetText(message)
    conflictPopup:SetHeight(conflictPopup.message:GetStringHeight() + 98)
    conflictPopup:Show()
end

local function StopCapture(popup)
    popup.capturing = false
    Utils.SafeCallMethod(popup, "EnableKeyboard", false)
    popup:SetScript("OnKeyDown", nil)
    if popup.bindBtn then
        local existing = popup.rowKey and Shortkeys:Get(popup.rowKey)
        popup.bindBtn:SetText((existing and existing.key) or L["SHORTKEY_CLICK_TO_BIND"])
    end
end

local function StartCapture(popup)
    popup.capturing = true
    popup.bindBtn:SetText(L["OPT_KB_PRESS_KEY"])
    Utils.SafeCallMethod(popup, "EnableKeyboard", true)
    popup:SetScript("OnKeyDown", function(self, key)
        local combo = Utils.CaptureKeybindCombo(key)
        if not combo then return end
        if combo == "stop" then StopCapture(self); return end
        local rowKey, name, cs = self.rowKey, self.skName, self.charSpecific
        StopCapture(self)
        self:Hide()
        if not rowKey then return end
        local kind, label = DetectBindConflict(rowKey, combo)
        if kind and EasyFind and EasyFind.db and EasyFind.db.shortkeyConflictPrompt ~= false then
            local msg = (kind == "shortkey"
                and L["SHORTKEY_CONFLICT_SHORTKEY"]
                or L["SHORTKEY_CONFLICT_BIND"]):format(label)
            ShowConflictPopup(msg, function() CommitShortkey(rowKey, name, cs, combo) end)
        else
            CommitShortkey(rowKey, name, cs, combo)
        end
    end)
end

local function BuildCapturePopup()
    local f = CreateFrame("Frame", "EasyFindShortkeyCapture", UIParent, "BackdropTemplate")
    f:SetSize(300, 116)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- Match the addon's search-window styling (rounded border + translucent fill).
    ns.StyleMenuPanel(f)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -13)
    f.title:SetPoint("TOPRIGHT", -12, -13)
    f.title:SetJustifyH("CENTER")
    f.title:SetWordWrap(true)

    -- Same rounded fill button as the options keybind rows.
    local bindBtn = ns.CreateModernButton(f, L["SHORTKEY_CLICK_TO_BIND"], 190, 24)
    bindBtn:SetNormalFontObject("GameFontHighlightSmall")
    bindBtn:SetHighlightFontObject("GameFontHighlightSmall")
    bindBtn:SetPoint("TOP", f.title, "BOTTOM", 0, -14)
    bindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    bindBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if f.rowKey then Shortkeys:Remove(f.rowKey) end
            StopCapture(f)
            if ns.RefreshShortkeyTable then ns.RefreshShortkeyTable() end
            return
        end
        if f.capturing then StopCapture(f) else StartCapture(f) end
    end)
    f.bindBtn = bindBtn

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOP", bindBtn, "BOTTOM", 0, -8)
    f.hint:SetText(L["OPT_KB_CLEAR_HINT"])

    -- Gold like the title (GameFontNormalSmall is natively that color),
    -- dropped slightly below the gray hint without growing the window.
    f.combatNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.combatNote:SetPoint("TOP", f.hint, "BOTTOM", 0, -6)
    f.combatNote:SetText(L["SHORTKEY_COMBAT_NOTE"])

    local close = ns.CreateCloseX(f, 14)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self)
        StopCapture(self)
        self.rowKey = nil
        self.skName = nil
        self.charSpecific = nil
    end)
    f:Hide()
    return f
end

function Shortkeys:PromptForKeyByKey(rowKey, name, charSpecific)
    if not rowKey then return end
    if not capturePopup then capturePopup = BuildCapturePopup() end
    capturePopup.rowKey = rowKey
    capturePopup.skName = name
    capturePopup.charSpecific = charSpecific
    capturePopup.title:SetText((L["SHORTKEY_FOR"]):format(name or "?"))
    local existing = self:Get(rowKey)
    capturePopup.bindBtn:SetText((existing and existing.key) or L["SHORTKEY_CLICK_TO_BIND"])
    capturePopup:Show()
end

function Shortkeys:PromptForKey(data)
    if not data then return end
    local rowKey = self:GetEntryKey(data)
    if not rowKey then return end
    self:PromptForKeyByKey(rowKey, data.name, self:IsCharacterSpecific(data))
end

-- Import / export. Aliases and/or shortkeys serialize to a length-prefixed
-- blob (no delimiter escaping needed) wrapped in base64 so it copy-pastes as a
-- single shareable code: "EF1!<base64>".

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local schar, sbyte = string.char, string.byte

local function base64enc(data)
    return ((data:gsub(".", function(x)
        local r, b = "", sbyte(x)
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function base64dec(data)
    data = data:gsub("[^" .. B64 .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return schar(c)
    end))
end

-- length-prefixed field: "<len>:<bytes>"
local function encS(s)
    s = tostring(s or "")
    return #s .. ":" .. s
end

local function decS(blob, pos)
    local colon = blob:find(":", pos, true)
    if not colon then return nil, pos end
    local len = tonumber(blob:sub(pos, colon - 1))
    if not len then return nil, pos end
    local val = blob:sub(colon + 1, colon + len)
    return val, colon + 1 + len
end

function Shortkeys:ExportList()
    local out = {}
    self:ForEach(function(rowKey, info, isChar)
        out[#out + 1] = { k = rowKey, b = info.key, n = info.name, c = isChar }
    end)
    return out
end

function Shortkeys:ImportList(list)
    if type(list) ~= "table" then return 0 end
    local n = 0
    for i = 1, #list do
        local r = list[i]
        if r and r.k and r.b and r.b ~= "" then
            if self:SetByKey(r.k, r.n, r.c, r.b) then n = n + 1 end
        end
    end
    return n
end

function Shortkeys:BuildExportString(which)
    which = which or "both"
    local parts = { "EFSK1", encS(which) }

    local aliasList = {}
    if (which == "alias" or which == "both") and ns.Aliases and ns.Aliases.ExportList then
        aliasList = ns.Aliases:ExportList()
    end
    parts[#parts + 1] = encS(#aliasList)
    for i = 1, #aliasList do
        local r = aliasList[i]
        parts[#parts + 1] = encS(r.text)
        parts[#parts + 1] = encS(r.key)
        parts[#parts + 1] = encS(r.name)
    end

    local skList = {}
    if which == "shortkey" or which == "both" then
        skList = self:ExportList()
    end
    parts[#parts + 1] = encS(#skList)
    for i = 1, #skList do
        local r = skList[i]
        parts[#parts + 1] = encS(r.k)
        parts[#parts + 1] = encS(r.b)
        parts[#parts + 1] = encS(r.n)
        parts[#parts + 1] = encS(r.c and "1" or "0")
    end

    return "EF1!" .. base64enc(table.concat(parts))
end

function Shortkeys:DecodeString(str)
    if type(str) ~= "string" then return nil end
    local b64 = strtrim(str):match("^EF1!(.+)$")
    if not b64 then return nil end
    local ok, blob = pcall(base64dec, b64)
    if not ok or type(blob) ~= "string" or blob:sub(1, 5) ~= "EFSK1" then return nil end

    local pos = 6
    local _, aliasCountStr, skCountStr
    _, pos = decS(blob, pos) -- which marker (unused on import; caller picks)
    aliasCountStr, pos = decS(blob, pos)
    local aliasCount = tonumber(aliasCountStr) or 0
    local aliases = {}
    for _ = 1, aliasCount do
        local text, key, name
        text, pos = decS(blob, pos)
        key, pos = decS(blob, pos)
        name, pos = decS(blob, pos)
        if text and key then aliases[#aliases + 1] = { text = text, key = key, name = name } end
    end

    skCountStr, pos = decS(blob, pos)
    local skCount = tonumber(skCountStr) or 0
    local shortkeys = {}
    for _ = 1, skCount do
        local k, b, n, c
        k, pos = decS(blob, pos)
        b, pos = decS(blob, pos)
        n, pos = decS(blob, pos)
        c, pos = decS(blob, pos)
        if k and b then shortkeys[#shortkeys + 1] = { k = k, b = b, n = n, c = (c == "1") } end
    end

    return { aliases = aliases, shortkeys = shortkeys }
end

-- Returns aliasCount, shortkeyCount applied, or nil on a bad string.
function Shortkeys:ApplyImportString(str, which)
    which = which or "both"
    local decoded = self:DecodeString(str)
    if not decoded then return nil end
    local na, nk = 0, 0
    if (which == "alias" or which == "both") and ns.Aliases and ns.Aliases.ImportList then
        na = ns.Aliases:ImportList(decoded.aliases)
    end
    if which == "shortkey" or which == "both" then
        nk = self:ImportList(decoded.shortkeys)
    end
    if ns.RefreshShortkeyTable then ns.RefreshShortkeyTable() end
    return na, nk
end
