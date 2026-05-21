local _, ns = ...

local Perf = {}
ns.Perf = Perf

local Utils = ns.Utils
local SafeAfter = Utils.SafeAfter
local CreateFrame = CreateFrame
local mfloor      = math.floor
local mhuge       = math.huge

local function EstimateSize(val, visited)
    if val == nil then return 0 end
    if not visited then visited = {} end
    local t = type(val)
    if t == "string" then return 40 + #val
    elseif t == "number" then return 8
    elseif t == "boolean" then return 4
    elseif t == "function" then return 128
    elseif t == "table" then
        if visited[val] then return 0 end
        visited[val] = true
        local bytes = 56
        for k, v in pairs(val) do
            bytes = bytes + EstimateSize(k, visited) + EstimateSize(v, visited)
        end
        local mt = getmetatable(val)
        if mt and type(mt.__index) == "table" then
            bytes = bytes + EstimateSize(mt.__index, visited)
        end
        return bytes
    elseif t == "userdata" then return 64 end
    return 0
end

local function CountItems(t)
    if not t then return 0 end
    local arr = #t
    if arr > 0 then return arr end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local SNAP_FIELDS = {
    { "uiSearchData",    "Database.uiSearchData",    function() return ns.Database and ns.Database.uiSearchData end },
    { "wordCache",       "Database.wordCache",       function() return ns.Database and ns.Database._wordCache end },
    { "lootItemCache",   "Database.lootItemCache",   function() return ns.Database and ns.Database._lootItemCache end },
    { "lootEntries",     "Database.lootEntries",     function() return ns.Database and ns.Database._lootEntries end },
    { "resultEntryPool", "Database.resultEntryPool", function() return ns.Database and ns.Database._resultEntryPool end },
    { "resultsBuf",      "Database.resultsBuf",      function() return ns.Database and ns.Database._resultsBuf end },
    { "flatEntries",     "UI.flatEntries",           function() return ns.UI and ns.UI._flatEntries end },
    { "flatCombined",    "UI.flatCombined",          function() return ns.UI and ns.UI._flatCombined end },
    { "SCRATCH",         "UI.SCRATCH",               function() return ns.UI and ns.UI._SCRATCH end },
    { "resultButtons",   "UI.resultButtons",         function() return ns.UI and ns.UI._resultButtons end },
    { "rareTrackCache",  "MapSearch.rareTrackCache", function() return ns.MapSearch and ns.MapSearch._rareTrackCache end },
}

local function TakeSnapshot()
    local snap = { heapKB = collectgarbage("count") }
    for i = 1, #SNAP_FIELDS do
        local def = SNAP_FIELDS[i]
        local key, getter = def[1], def[3]
        local t = getter()
        snap[key .. "_bytes"] = EstimateSize(t, {})
        snap[key .. "_count"] = CountItems(t)
    end
    return snap
end

local function PrintSnapshotDiff(before, after)
    EasyFind:Print(string.format(
        "  Lua heap (total)        %.1fMB -> %.1fMB  (%+.1fKB)",
        before.heapKB / 1024,
        after.heapKB / 1024,
        after.heapKB - before.heapKB))
    for i = 1, #SNAP_FIELDS do
        local def = SNAP_FIELDS[i]
        local key, label = def[1], def[2]
        local b = before[key .. "_bytes"] or 0
        local a = after[key .. "_bytes"] or 0
        local bC = before[key .. "_count"] or 0
        local aC = after[key .. "_count"] or 0
        local d = a - b
        if a > 0 or b > 0 or d ~= 0 then
            local color
            if d >= 100 * 1024 then color = "|cffff5555"
            elseif d >= 10 * 1024 then color = "|cffffaa00"
            elseif d <= -10 * 1024 then color = "|cff44ffff"
            else color = "|cffaaaaaa" end
            EasyFind:Print(string.format(
                "  %s%-26s|r  count %d->%d  size %.1fKB->%.1fKB  (%s%+.1fKB|r)",
                color, label, bC, aC, b / 1024, a / 1024, color, d / 1024))
        end
    end
end

local recording   = false
local sampleCount = 0
local sampleSum   = 0
local sampleMin   = mhuge
local sampleMax   = 0
local stutterCount = 0
local STUTTER_THRESHOLD = 1 / 50

local heapStartKB  = 0
local heapMinKB    = mhuge
local heapMaxKB    = 0
local heapLastKB   = 0
local collectgarbageRef = collectgarbage

local agg = {
    scenarios = 0,
    sumAvg    = 0,
    sumWorst  = 0,
    worst     = 0,
    worstLabel = nil,
    totalStutters = 0,
    totalSamples  = 0,
    heapMaxKB     = 0,
    heapMaxLabel  = nil,
    heapWorstChurn = 0,
    heapWorstChurnLabel = nil,
    heapNetDeltaKB = 0,
}

local watchFrame = CreateFrame("Frame")
watchFrame:Hide()
watchFrame:SetScript("OnUpdate", function(_, elapsed)
    if not recording then return end
    sampleCount  = sampleCount + 1
    sampleSum    = sampleSum + elapsed
    if elapsed < sampleMin then sampleMin = elapsed end
    if elapsed > sampleMax then sampleMax = elapsed end
    if elapsed > STUTTER_THRESHOLD then stutterCount = stutterCount + 1 end

    local heapKB = collectgarbageRef("count")
    heapLastKB = heapKB
    if heapKB < heapMinKB then heapMinKB = heapKB end
    if heapKB > heapMaxKB then heapMaxKB = heapKB end
end)

local function startRecording()
    sampleCount  = 0
    sampleSum    = 0
    sampleMin    = mhuge
    sampleMax    = 0
    stutterCount = 0
    heapStartKB  = collectgarbageRef("count")
    heapMinKB    = heapStartKB
    heapMaxKB    = heapStartKB
    heapLastKB   = heapStartKB
    recording    = true
    watchFrame:Show()
end

local function stopAndReport(label)
    recording = false
    watchFrame:Hide()
    if sampleCount == 0 then
        EasyFind:Print("|cffaaaaaa" .. label .. ": no frames|r")
        return
    end
    local avg = sampleSum / sampleCount
    local avgFps   = 1 / avg
    local worstFps = 1 / sampleMax
    local stutterPct = stutterCount / sampleCount * 100
    local color = "|cff66ff66"
    if worstFps < 30 or stutterPct > 5 then
        color = "|cffff5555"
    elseif worstFps < 50 or stutterPct > 1 then
        color = "|cffffaa00"
    end

    local heapPeakDelta = heapMaxKB - heapStartKB
    local heapEndDelta  = heapLastKB - heapStartKB
    local heapColor = "|cff66ff66"
    if heapPeakDelta > 5000 then heapColor = "|cffff5555"
    elseif heapPeakDelta > 1000 then heapColor = "|cffffaa00" end

    EasyFind:Print(string.format(
        "%s%s|r  avg %dfps  worst %.1fms/%dfps  stutters %d/%d (%.1f%%)  %sheap +%.0fKB peak / %+.0fKB end|r",
        color, label,
        mfloor(avgFps + 0.5),
        sampleMax * 1000, mfloor(worstFps + 0.5),
        stutterCount, sampleCount, stutterPct,
        heapColor, heapPeakDelta, heapEndDelta))

    agg.scenarios = agg.scenarios + 1
    agg.sumAvg = agg.sumAvg + avg
    agg.sumWorst = agg.sumWorst + sampleMax
    agg.totalStutters = agg.totalStutters + stutterCount
    agg.totalSamples  = agg.totalSamples + sampleCount
    if sampleMax > agg.worst then
        agg.worst = sampleMax
        agg.worstLabel = label
    end
    if heapMaxKB > agg.heapMaxKB then
        agg.heapMaxKB = heapMaxKB
        agg.heapMaxLabel = label
    end
    if heapPeakDelta > agg.heapWorstChurn then
        agg.heapWorstChurn = heapPeakDelta
        agg.heapWorstChurnLabel = label
    end
    agg.heapNetDeltaKB = agg.heapNetDeltaKB + heapEndDelta
end

-- Bypasses the 50ms editbox debounce so each simulated keystroke runs
-- on the frame it was scheduled.
local function fireSearch(text)
    if not ns.UI or not ns.UI.OnSearchTextChanged then return end
    if ns.UI.searchFrame and ns.UI.searchFrame.editBox then
        local eb = ns.UI.searchFrame.editBox
        if eb:GetText() ~= text then eb:SetText(text) end
    end
    ns.UI:OnSearchTextChanged(text)
end

local function yieldNextFrame(fn) SafeAfter(0, fn) end

-- keyDelay <= 0 yields one frame (~16ms), simulating a held key.
local function runSequence(seq, keyDelay, onDone)
    local i = 0
    local function step()
        i = i + 1
        if i > #seq then
            SafeAfter(0.20, onDone)
            return
        end
        fireSearch(seq[i])
        if keyDelay <= 0 then
            yieldNextFrame(step)
        else
            SafeAfter(keyDelay, step)
        end
    end
    step()
end

local function seqType(text)
    local s = {}
    for i = 1, #text do s[i] = text:sub(1, i) end
    return s
end

local function seqErase(startText)
    local s = {}
    s[1] = startText
    for i = 1, #startText do s[i + 1] = startText:sub(1, #startText - i) end
    return s
end

local function seqTypeThenErase(text)
    local s = seqType(text)
    local n = #s
    local e = seqErase(text)
    for i = 2, #e do s[n + i - 1] = e[i] end
    return s
end

local function seqTypeBackspaceType(pre, n, suf)
    local s = seqType(pre)
    local cur = pre
    for i = 1, n do
        cur = cur:sub(1, #cur - 1)
        s[#s + 1] = cur
    end
    for i = 1, #suf do
        cur = cur .. suf:sub(i, i)
        s[#s + 1] = cur
    end
    return s
end

local function seqOscillate(word, repeats)
    local s = {}
    for r = 1, repeats do
        for i = 1, #word do s[#s + 1] = word:sub(1, i) end
        for i = 1, #word do s[#s + 1] = word:sub(1, #word - i) end
    end
    return s
end

local function seqWordChain(words)
    local s = {}
    local cur = ""
    for w = 1, #words do
        if w > 1 then
            cur = cur .. " "
            s[#s + 1] = cur
        end
        for i = 1, #words[w] do
            cur = cur .. words[w]:sub(i, i)
            s[#s + 1] = cur
        end
    end
    return s
end

local function chain(scenarios, onDone)
    local i = 0
    local function next()
        i = i + 1
        local s = scenarios[i]
        if not s then onDone() return end
        startRecording()
        s.run(function()
            stopAndReport(s.label)
            SafeAfter(0.20, next)
        end)
    end
    next()
end

local GIBBERISH_SHORT = "asdfghjkl"
local GIBBERISH_LONG  = "asdhfoasdhpjfsadhpjufsdhopjsdhpjofddf"
local LONG_WORD       = "transmogrification"

function Perf:Run()
    if recording then
        EasyFind:Print("Perf test already running")
        return
    end

    agg.scenarios     = 0
    agg.sumAvg        = 0
    agg.sumWorst      = 0
    agg.worst         = 0
    agg.worstLabel    = nil
    agg.totalStutters = 0
    agg.totalSamples  = 0
    agg.heapMaxKB     = 0
    agg.heapMaxLabel  = nil
    agg.heapWorstChurn = 0
    agg.heapWorstChurnLabel = nil
    agg.heapNetDeltaKB = 0

    collectgarbageRef("collect")
    local runStartHeapKB = collectgarbageRef("count")
    local snapBefore = TakeSnapshot()

    EasyFind:Print("|cffFFD100Perf test starting...|r (this takes ~60s)")
    EasyFind:Print(string.format("|cff888888Heap baseline: %.1f MB|r",
        runStartHeapKB / 1024))

    if ns.UI and ns.UI.Show then ns.UI:Show(true) end

    local scenarios = {
        { label = "type 'mountain' slow (150ms)",
          run = function(d) runSequence(seqType("mountain"), 0.15, d) end },
        { label = "type 'mountain' fast (60ms)",
          run = function(d) runSequence(seqType("mountain"), 0.06, d) end },
        { label = "type 'mountain' burst (30ms)",
          run = function(d) runSequence(seqType("mountain"), 0.03, d) end },
        { label = "type long word '" .. LONG_WORD .. "' (60ms)",
          run = function(d) runSequence(seqType(LONG_WORD), 0.06, d) end },
        { label = "type gibberish '" .. GIBBERISH_SHORT .. "' (60ms)",
          run = function(d) runSequence(seqType(GIBBERISH_SHORT), 0.06, d) end },
        { label = "type LONG gibberish (37 chars, 60ms)",
          run = function(d) runSequence(seqType(GIBBERISH_LONG), 0.06, d) end },
        { label = "type 'achievement' (60ms, common prefix)",
          run = function(d) runSequence(seqType("achievement"), 0.06, d) end },
        { label = "type 'zzzqqq' (60ms, no matches)",
          run = function(d) runSequence(seqType("zzzqqq"), 0.06, d) end },

        -- Erase paths cannot use the prefix-extend incremental cache;
        -- each backspace re-scans the full dataset.
        { label = "erase 'mountain' slow (150ms)",
          run = function(d) runSequence(seqErase("mountain"), 0.15, d) end },
        { label = "erase 'mountain' fast (60ms)",
          run = function(d) runSequence(seqErase("mountain"), 0.06, d) end },
        { label = "erase 'mountain' HOLD (16ms)",
          run = function(d) runSequence(seqErase("mountain"), 0, d) end },
        { label = "erase '" .. LONG_WORD .. "' HOLD",
          run = function(d) runSequence(seqErase(LONG_WORD), 0, d) end },
        { label = "erase 37-char gibberish HOLD",
          run = function(d) runSequence(seqErase(GIBBERISH_LONG), 0, d) end },

        { label = "type 'mountin' -> back 2 -> 'ain'  (typo fix)",
          run = function(d) runSequence(seqTypeBackspaceType("mountin", 2, "ain"), 0.06, d) end },
        { label = "type 'rai' -> back 1 -> 'ider'  (typo fix)",
          run = function(d) runSequence(seqTypeBackspaceType("rai", 1, "ider"), 0.06, d) end },
        { label = "type+erase oscillate 'moun' x4",
          run = function(d) runSequence(seqOscillate("moun", 4), 0.06, d) end },
        { label = "type+erase oscillate 'mountain' x3",
          run = function(d) runSequence(seqOscillate("mountain", 3), 0.06, d) end },
        { label = "type 'mountain' then HOLD-backspace to empty",
          run = function(d) runSequence(seqTypeThenErase("mountain"), 0, d) end },
        { label = "type 37-char gibberish then HOLD-backspace to empty",
          run = function(d) runSequence(seqTypeThenErase(GIBBERISH_LONG), 0, d) end },

        { label = "chain 'icc boss' (60ms)",
          run = function(d) runSequence(seqWordChain({"icc","boss"}), 0.06, d) end },
        { label = "chain 'mount tank dungeon' (60ms)",
          run = function(d) runSequence(seqWordChain({"mount","tank","dungeon"}), 0.06, d) end },
        { label = "chain 5 words 'icc boss tank rare elite' (60ms)",
          run = function(d) runSequence(seqWordChain({"icc","boss","tank","rare","elite"}), 0.06, d) end },

        { label = "5x random word swap stress",
          run = function(d)
              local words = {"mount","mage","heal","raid","tank"}
              local i = 0
              local function loop()
                  i = i + 1
                  if i > #words then SafeAfter(0.20, d) return end
                  runSequence(seqType(words[i]), 0.05, function()
                      runSequence(seqErase(words[i]), 0, loop)
                  end)
              end
              loop()
          end },
    }

    chain(scenarios, function()
        fireSearch("")
        if agg.scenarios > 0 then
            local avgAvg   = agg.sumAvg / agg.scenarios
            local avgWorst = agg.sumWorst / agg.scenarios
            local stutterPct = agg.totalSamples > 0
                and (agg.totalStutters / agg.totalSamples * 100) or 0
            EasyFind:Print(string.format(
                "|cffFFD100SUMMARY|r  scenarios=%d  avg-avg %dfps  avg-worst %dfps  total stutters %d/%d (%.1f%%)",
                agg.scenarios,
                mfloor(1 / avgAvg + 0.5),
                mfloor(1 / avgWorst + 0.5),
                agg.totalStutters, agg.totalSamples, stutterPct))
            EasyFind:Print(string.format(
                "|cffFFD100WORST FRAME|r  %.1fms (%dfps)  in: %s",
                agg.worst * 1000, mfloor(1 / agg.worst + 0.5),
                agg.worstLabel or "?"))

            local runEndHeapKB = collectgarbageRef("count")
            local netRunDeltaKB = runEndHeapKB - runStartHeapKB
            local netColor = "|cff66ff66"
            if netRunDeltaKB > 1000 then netColor = "|cffff5555"
            elseif netRunDeltaKB > 200 then netColor = "|cffffaa00" end
            EasyFind:Print(string.format(
                "|cffFFD100HEAP PEAK|r  %.1f MB  in: %s",
                agg.heapMaxKB / 1024, agg.heapMaxLabel or "?"))
            EasyFind:Print(string.format(
                "|cffFFD100WORST CHURN|r  +%.0f KB  in: %s",
                agg.heapWorstChurn, agg.heapWorstChurnLabel or "?"))
            EasyFind:Print(string.format(
                "%sHEAP NET|r  %+.0f KB across %d scenarios (%.1f MB -> %.1f MB)",
                netColor,
                netRunDeltaKB, agg.scenarios,
                runStartHeapKB / 1024, runEndHeapKB / 1024))

            collectgarbageRef("collect")
            local snapAfter = TakeSnapshot()
            EasyFind:Print(" ")
            EasyFind:Print("|cffFFD100--- Per-table delta (post-GC) ---|r")
            PrintSnapshotDiff(snapBefore, snapAfter)
        end
        EasyFind:Print("|cff888888Stutter = single frame slower than 1/50s. Color: green ok / amber bad / red unshippable.|r")
    end)
end
