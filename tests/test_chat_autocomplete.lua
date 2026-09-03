-- Tests for Utils.AttachAutocomplete on a SHARED editbox (a chat box, as the
-- snippet argument hints attach it): the helper must never touch a
-- selection it did not paint. WoW's own "/w Nam" name completion fills the
-- rest of the name and keeps it selected for Tab; 3.1.0 cleared that
-- selection on every keystroke, which committed the name unasked. The
-- search-bar behavior (strip clears a stray selection) is kept.
-- Loads the REAL Shared/Utils.lua.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFont = fakeWidget
env.CreateFrame = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GetCursorPosition = function() return 0, 0 end
env.IsControlKeyDown = function() return false end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })

H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

-- Minimal editbox with selection tracking. SetText re-fires the hooked
-- OnTextChanged with userInput=false, exactly like the client.
local function newEditBox(text)
    local box = { text = text or "", caret = #(text or ""), hl = { 0, 0 }, hooks = {}, focus = true }
    function box:GetText() return self.text end
    function box:SetText(t)
        self.text = t
        self.caret = #t
        for _, fn in ipairs(self.hooks.OnTextChanged or {}) do fn(self, false) end
    end
    function box:GetCursorPosition() return self.caret end
    function box:SetCursorPosition(pos) self.caret = pos end
    function box:HighlightText(s, e) self.hl = { s or 0, e or 0 } end
    function box:HasFocus() return self.focus end
    function box:GetMaxLetters() return 0 end
    function box:HookScript(name, fn)
        self.hooks[name] = self.hooks[name] or {}
        table.insert(self.hooks[name], fn)
    end
    function box:Fire(name, ...)
        for _, fn in ipairs(self.hooks[name] or {}) do fn(self, ...) end
    end
    -- A user keystroke: the client applies it, then fires OnTextChanged
    -- with userInput=true.
    function box:UserType(ch)
        self.text = self.text:sub(1, self.caret) .. ch .. self.text:sub(self.caret + 1)
        self.caret = self.caret + #ch
        self:Fire("OnTextChanged", true)
    end
    return box
end

local function attachChat(box)
    Utils.AttachAutocomplete(box, {
        endOfTextOnly = true,
        applyOnType = true,
        findCandidate = function() return nil end,
    })
end

local tests = {}

tests["chat: client name completion keeps its selection through a keystroke"] = function()
    local box = newEditBox("")
    attachChat(box)
    box:UserType("/w Br")
    -- The client's completion for the next keystroke: the user typed "y",
    -- Blizzard's handler (which runs first) filled "an" and selected it,
    -- then our hook sees the box in that state.
    box.text = "/w Bryan"
    box.caret = 6
    box.hl = { 6, 8 }
    box:Fire("OnTextChanged", true)
    H.assertDeepEq(box.hl, { 6, 8 }, "selection untouched")
    H.assertEq(box.text, "/w Bryan", "text untouched")
    H.assertEq(box.caret, 6, "caret untouched")
end

tests["chat: strip with no ghost leaves the selection alone"] = function()
    local box = newEditBox("/w Bryan")
    attachChat(box)
    box.caret = 6
    box.hl = { 6, 8 }
    box.StripAutocomplete()
    H.assertDeepEq(box.hl, { 6, 8 }, "selection untouched by strip")
end

tests["chat: the helper's own ghost is still cleared"] = function()
    local box = newEditBox("")
    Utils.AttachAutocomplete(box, {
        endOfTextOnly = true,
        applyOnType = true,
        findCandidate = function(typed)
            if typed == "\\greet(" then return "\\greet(name" end
            return nil
        end,
    })
    box:UserType("\\greet(")
    H.assertEq(box.text, "\\greet(name", "ghost rendered")
    H.assertDeepEq(box.hl, { 7, 11 }, "ghost selected")
    box.StripAutocomplete()
    H.assertEq(box.text, "\\greet(", "ghost stripped")
    H.assertDeepEq(box.hl, { 0, 0 }, "ghost selection cleared")
end

tests["search bar: strip with no ghost clears a stray selection"] = function()
    local box = newEditBox("talents")
    Utils.AttachAutocomplete(box, { findCandidate = function() return nil end })
    box.hl = { 0, 7 }
    box.StripAutocomplete()
    H.assertDeepEq(box.hl, { 0, 0 }, "stray selection cleared for Enter")
end

local pass, fail, failures = H.runSuite("ChatAutocomplete", tests)
return { pass = pass, fail = fail, failures = failures }
