-- Tests for the copied-link paste swap (Shared/Utils.lua): the OS clipboard
-- carries the flattened name, the live link is stashed, and a chat editbox
-- that receives EXACTLY that name as one inserted chunk gets the link back
-- in place. Typing the same name, pasting over a selection, or pasting when
-- nothing is stashed must leave the box alone. Loads the REAL Shared/Utils.lua.

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
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })

H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

local LINK = "|cffff8000|Hitem:19019::::::::80:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
local PLAIN = "[Thunderfury, Blessed Blade of the Windseeker]"

-- Minimal editbox: SetText re-fires the hooked OnTextChanged with
-- userInput=false, exactly like the client.
local function newEditBox(text, maxLetters)
    local box = { text = text or "", caret = #(text or ""), maxLetters = maxLetters or 0, hooks = {} }
    function box:GetText() return self.text end
    function box:SetText(t)
        self.text = t
        self.caret = #t
        for _, fn in ipairs(self.hooks.OnTextChanged or {}) do fn(self, false) end
    end
    function box:GetCursorPosition() return self.caret end
    function box:SetCursorPosition(pos) self.caret = pos end
    function box:GetMaxLetters() return self.maxLetters end
    function box:HookScript(name, fn)
        self.hooks[name] = self.hooks[name] or {}
        table.insert(self.hooks[name], fn)
    end
    -- User edit: the client applies the change, then fires OnTextChanged
    -- with userInput=true.
    function box:UserInsert(chunk, at)
        at = at or #self.text
        self.text = self.text:sub(1, at) .. chunk .. self.text:sub(at + 1)
        self.caret = at + #chunk
        for _, fn in ipairs(self.hooks.OnTextChanged or {}) do fn(self, true) end
    end
    function box:UserReplace(startPos, endPos, chunk)
        self.text = self.text:sub(1, startPos - 1) .. chunk .. self.text:sub(endPos + 1)
        self.caret = startPos - 1 + #chunk
        for _, fn in ipairs(self.hooks.OnTextChanged or {}) do fn(self, true) end
    end
    return box
end

local tests = {}

tests["paste into an empty box becomes the link"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(PLAIN)
    H.assertEq(box.text, LINK, "text swapped to link")
    H.assertEq(box.caret, #LINK, "caret after the link")
end

tests["paste mid-text keeps prefix and suffix"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("look at  now")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(PLAIN, 8)
    H.assertEq(box.text, "look at " .. LINK .. " now", "link spliced at the caret")
    H.assertEq(box.caret, 8 + #LINK, "caret after the link")
end

tests["typing the name character by character never swaps"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    for i = 1, #PLAIN do
        box:UserInsert(PLAIN:sub(i, i))
    end
    H.assertEq(box.text, PLAIN, "typed text untouched")
end

tests["paste over a selection is not a bare insert"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("sell WTS please")
    Utils.AttachPasteLinkSwap(box)
    box:UserReplace(6, 8, PLAIN)
    H.assertEq(box.text, "sell " .. PLAIN .. " please", "replacement left as readable name")
end

tests["nothing stashed leaves the paste alone"] = function()
    Utils.StashClipboardLink(nil, nil)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(PLAIN)
    H.assertEq(box.text, PLAIN, "no stash, no swap")
end

tests["a plain payload with no markup stashes nothing"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    Utils.StashClipboardLink("Kills: 12", "Kills: 12")
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(PLAIN)
    H.assertEq(box.text, PLAIN, "plain copy cleared the earlier stash")
end

tests["a different chunk does not match"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert("[Thunderfury]")
    H.assertEq(box.text, "[Thunderfury]", "shorter name untouched")
    box:UserInsert("x" .. PLAIN)
    H.assertEq(box.text, "[Thunderfury]x" .. PLAIN, "chunk with extra lead byte untouched")
end

tests["swap respects the box letter cap"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("", #PLAIN + 10)
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(PLAIN)
    H.assertEq(box.text, PLAIN, "link would overflow, readable name kept")
end

tests["addon SetText keeps the previous-text tracking in step"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:SetText("prefix ")
    box:UserInsert(PLAIN)
    H.assertEq(box.text, "prefix " .. LINK, "swap after an addon rewrite")
    box:UserInsert(" and again ")
    box:UserInsert(PLAIN)
    H.assertEq(box.text, "prefix " .. LINK .. " and again " .. LINK, "second paste swaps too")
end

tests["snippet text with embedded links restores them"] = function()
    local body = "WTS " .. LINK .. " pst"
    local plain = Utils.ClipboardSafeText(body)
    H.assertEq(plain, "WTS " .. PLAIN .. " pst", "flattened body")
    Utils.StashClipboardLink(plain, body)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    box:UserInsert(plain)
    H.assertEq(box.text, body, "embedded link restored")
end

tests["attach is idempotent"] = function()
    Utils.StashClipboardLink(PLAIN, LINK)
    local box = newEditBox("")
    Utils.AttachPasteLinkSwap(box)
    Utils.AttachPasteLinkSwap(box)
    H.assertEq(#box.hooks.OnTextChanged, 1, "one hook")
end

local pass, fail, failures = H.runSuite("PasteLinkSwap", tests)
return { pass = pass, fail = fail, failures = failures }
