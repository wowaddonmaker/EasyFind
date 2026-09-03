-- Compiles every shipped Lua file (core toc plus every companion toc)
-- with loadfile: catches syntax errors AND Lua's structural limits (the
-- 200-local main-chunk cap, the 60-upvalue cap) that no other gate sees.
-- Born from a 200-local overflow in Database/Main.lua that 208 green
-- tests and clean luacheck both missed, because nothing compiled the file.

local H = require("Harness")

local ROOT = H.ADDON_ROOT

local function tocFiles(tocPath)
    local files = {}
    local fh = io.open(ROOT .. "/" .. tocPath, "r")
    if not fh then return files, false end
    for line in fh:lines() do
        line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:find("^#") and line:find("%.lua$") then
            local dir = tocPath:match("^(.*)/[^/]+$")
            files[#files + 1] = dir and (dir .. "/" .. line) or line
        end
    end
    fh:close()
    return files, true
end

local TOCS = {
    "EasyFind.toc",
    "Apps/Calc/EasyFind_Calc.toc",
    "Apps/Icons/EasyFind_Icons.toc",
    "Apps/Items/EasyFind_Items.toc",
    "Apps/Options/EasyFind_Options.toc",
    "Apps/Settings/EasyFind_Settings.toc",
    "Apps/Guide/EasyFind_Guide.toc",
    "Apps/Onboarding/EasyFind_Onboarding.toc",
    "Apps/Snippets/EasyFind_Snippets.toc",
}

local tests = {}

function tests.everyShippedFileCompiles()
    local checked = 0
    for _, toc in ipairs(TOCS) do
        local files, ok = tocFiles(toc)
        H.assertTrue(ok, "toc readable: " .. toc)
        H.assertTrue(#files > 0, "toc lists files: " .. toc)
        for _, rel in ipairs(files) do
            local chunk, err = loadfile(ROOT .. "/" .. rel)
            H.assertTrue(chunk ~= nil, "compile failed: " .. rel .. ": " .. tostring(err))
            checked = checked + 1
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, compiled " .. checked)
end

local pass, fail, failures = H.runSuite("CompileAll", tests)
return { pass = pass, fail = fail, failures = failures }
