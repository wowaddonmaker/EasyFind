local _, ns = ...

local Demo = {}
ns.Demo = Demo

local Utils = ns.Utils
local sfind, slower         = Utils.sfind, Utils.slower
local select, ipairs, pairs = Utils.select, Utils.ipairs, Utils.pairs
local tinsert, tconcat, tremove, tsort = Utils.tinsert, Utils.tconcat, Utils.tremove, Utils.tsort
local mmin, mmax = Utils.mmin, Utils.mmax

local GOLD_COLOR = ns.GOLD_COLOR
local TOOLTIP_BORDER = ns.TOOLTIP_BORDER
local DEFAULT_OPACITY = ns.DEFAULT_OPACITY
local DARK_PANEL_BG = ns.DARK_PANEL_BG

local CreateFrame        = CreateFrame
local C_Timer            = C_Timer
local UIParent           = UIParent
local GameTooltip        = GameTooltip
local GameTooltip_Hide   = GameTooltip_Hide
local IsShiftKeyDown     = IsShiftKeyDown
local GetCursorPosition  = GetCursorPosition
local InCombatLockdown   = InCombatLockdown
local HideUIPanel        = HideUIPanel
local wipe               = wipe

-- Find the "Spellbook" tab entry in the search database. The demo
-- bypasses fuzzy search ranking by passing this entry straight to
-- SelectResult, so we know exactly what gets opened regardless of
-- what ranks first for "sp".
local function FindSpellbookEntry()
    if not (ns.Database and ns.Database.uiSearchData) then return nil end
    for _, entry in ipairs(ns.Database.uiSearchData) do
        if entry.name == "Spellbook" and entry.category == "Talents" then
            return entry
        end
    end
    return nil
end

-- Run the EasyFind setup demo. ctx fields:
--   searchFrame, resultsFrame, resultButtons - main UI references
--   finishSetup - callback that closes the setup tutorial UI
function Demo.Start(ctx)
    local searchFrame  = ctx.searchFrame
    local resultsFrame = ctx.resultsFrame
    local resultButtons = ctx.resultButtons
    local FinishSetup  = ctx.finishSetup
    local UI           = ns.UI

        -- Combat-safe abort: opening Collections and animating around the
        -- screen can taint or fail under combat lockdown.
        if InCombatLockdown() then
            FinishSetup()
            return
        end

        local spellbookEntry = FindSpellbookEntry()
        if not spellbookEntry then
            FinishSetup()
            return
        end

        -- Lock the search bar dragging during the demo
        searchFrame:SetScript("OnDragStart", nil)

        -- Force-load Blizzard_PlayerSpells so PlayerSpellsFrame and its
        -- tabs exist as targets for the mock cursor and Highlight system.
        if C_AddOns and C_AddOns.LoadAddOn then
            pcall(C_AddOns.LoadAddOn, "Blizzard_PlayerSpells")
        end

        -- Demo registry. Each entry has:
        --   title       - shown at the top of the demo panel
        --   sections    - list of { header, section, firstStep, lastStep }
        --   stepDefs    - list of { text, section } describing each step row
        --   run         - list of function(done) that animates each step
        --   setupAfter  - list of function() that snaps the game state to
        --                 the end of step i without animation (used by
        --                 Prev/Next/jumpToStep)
        -- run and setupAfter for the default UI Search demo are populated
        -- further down, after the helper functions they reference exist.
        -- Other demos start empty and get filled in as we build them.
        local DEMOS = {
            uiSearch = {
                title    = "UI Search",
                sections = {
                    { header = "Search and open a panel", section = 1, firstStep = 1, lastStep = 2 },
                },
                stepDefs = {
                    { text = 'Start typing "Spellbook"',   section = 1 },  -- 1
                    { text = "Click the Spellbook result", section = 1 },  -- 2
                },
                lockFrames = { "PlayerSpellsFrame" },
                run = {},
                setupAfter = {},
            },
            guide = {
                title    = "Guide Mode",
                sections = {
                    { header = "Right-click a result to get a guided walkthrough", section = 1, firstStep = 1, lastStep = 4 },
                },
                stepDefs = {
                    { text = 'Start typing "Valorstones"',      section = 1 },  -- 1
                    { text = "Right-click the Valorstones row", section = 1 },  -- 2
                    { text = "Click Guide in the menu",         section = 1 },  -- 3
                    { text = "Follow the step-by-step guide",   section = 1 },  -- 4
                },
                lockFrames = { "CharacterFrame" },
                run = {},
                setupAfter = {},
            },
            mapSearchZone = {
                title = "Zone/Instance Map Search",
                sections = {},
                stepDefs = {},
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
            },
            mapSearchCurrent = {
                title = "Current Zone Map Search",
                sections = {},
                stepDefs = {},
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
            },
            mapSearchUI = {
                title = "Map search through UI bar",
                sections = {
                    { header = "Local Map POI search: Flight Master", section = 1, firstStep = 1, lastStep = 5 },
                    { header = "Global zone search: Eastern Plaguelands", section = 2, firstStep = 6, lastStep = 9 },
                },
                stepDefs = {
                    { text = "Open the filter menu",                 section = 1 },  -- 1
                    { text = "Enable Map Search filter",             section = 1 },  -- 2
                    { text = 'Confirm "Local" is selected',          section = 1 },  -- 3
                    { text = 'Start typing "Flight Master"',         section = 1 },  -- 4
                    { text = "Click the Flight Master result",       section = 1 },  -- 5
                    { text = "Open the filter menu",                 section = 2 },  -- 6
                    { text = 'Switch to "Global"',                   section = 2 },  -- 7
                    { text = 'Start typing "Eastern Plaguelands"',   section = 2 },  -- 8
                    { text = "Click the Eastern Plaguelands result", section = 2 },  -- 9
                },
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
            },
            outfits          = { title = "Outfits",                  sections = {}, stepDefs = {}, lockFrames = {}, run = {}, setupAfter = {} },
            appearanceSets   = { title = "Appearance Sets",          sections = {}, stepDefs = {}, lockFrames = {}, run = {}, setupAfter = {} },
            loot             = { title = "Loot",                     sections = {}, stepDefs = {}, lockFrames = {}, run = {}, setupAfter = {} },
            mounts           = { title = "Mounts",                   sections = {}, stepDefs = {}, lockFrames = {}, run = {}, setupAfter = {} },
        }
        -- Working refs reassigned by loadDemo. Existing state-machine code
        -- captures these as upvalues, so swapping them here propagates.
        local currentDemo = DEMOS.uiSearch
        local currentDemoKey = "uiSearch"
        local DEMO_STEPS = currentDemo.stepDefs
        local DEMO_SECTIONS = currentDemo.sections
        local demoSteps      -- assigned after the run table is populated
        local setupAfterStep -- assigned after the setupAfter table is populated
        local loadDemo            -- forward decl; defined after setupAfter is populated
        local refreshDemoMenuActive  -- forward decl; defined where the menu items are built
        local active              -- forward decl; assigned later as the demo "is open" flag

        -- Playback speed multiplier set by the speed flyout. Declared
        -- early so the scroll animation OnUpdate (defined a few lines
        -- below with the demo frame) can capture it as an upvalue.
        -- tickFrame's OnUpdate and cursor handlers also close over
        -- this so the whole demo runs at the chosen rate.
        local playbackSpeed = 1.0

        demoFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        -- Fixed height: the step list scrolls inside a ScrollFrame
        -- anchored below the title separator. Demos that are longer
        -- than the visible area scroll the active step into view; the
        -- rest of the list stays clipped above/below like a crawl.
        demoFrame:SetSize(280, 290)
        -- Shift down from center so the panel doesn't cover the minimap.
        -- User can still drag it anywhere they want.
        demoFrame:SetPoint("RIGHT", UIParent, "RIGHT", -32, -60)
        demoFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        demoFrame:SetIgnoreParentAlpha(true)
        -- Make the panel draggable so the user can move it out of the
        -- way when it covers the minimap or the demo target window.
        demoFrame:SetMovable(true)
        demoFrame:EnableMouse(true)
        demoFrame:RegisterForDrag("LeftButton")
        demoFrame:SetScript("OnDragStart", demoFrame.StartMoving)
        demoFrame:SetScript("OnDragStop", demoFrame.StopMovingOrSizing)
        demoFrame:SetBackdrop({
            edgeFile = TOOLTIP_BORDER,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        demoFrame:SetBackdropBorderColor(0.50, 0.48, 0.45, 1.0)

        local demoBgTex = demoFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
        demoBgTex:SetPoint("TOPLEFT", 4, -4)
        demoBgTex:SetPoint("BOTTOMRIGHT", -4, 4)
        demoBgTex:SetAtlas("QuestLog-main-background", false)
        demoBgTex:SetAlpha(1.0)

        local title = demoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetJustifyH("CENTER")
        title:SetSpacing(2)
        title:SetText("|cffFFD100" .. currentDemo.title .. "|r")

        local titleSep = demoFrame:CreateTexture(nil, "ARTWORK")
        titleSep:SetHeight(1)
        titleSep:SetPoint("TOPLEFT", 16, -60)
        titleSep:SetPoint("TOPRIGHT", -16, -60)
        titleSep:SetColorTexture(0.4, 0.4, 0.4, 0.7)

        -- Scroll container for the step list. Sits directly below the
        -- title separator and above the transport-button row. Rows are
        -- anchored to stepScrollChild, so when the active step changes
        -- we simply SetVerticalScroll() on stepScrollFrame and the rows
        -- slide up "under" the title line (clipping is automatic).
        -- Mouse wheel lets the user peek back at earlier steps.
        local stepScrollFrame = CreateFrame("ScrollFrame", nil, demoFrame)
        stepScrollFrame:SetPoint("TOPLEFT", demoFrame, "TOPLEFT", 8, -64)
        stepScrollFrame:SetPoint("TOPRIGHT", demoFrame, "TOPRIGHT", -8, -64)
        stepScrollFrame:SetPoint("BOTTOM", demoFrame, "BOTTOM", 0, 88)
        stepScrollFrame:EnableMouseWheel(true)
        local stepScrollChild = CreateFrame("Frame", nil, stepScrollFrame)
        stepScrollChild:SetSize(1, 1)  -- width follows scrollFrame, height grows
        stepScrollFrame:SetScrollChild(stepScrollChild)
        -- ScrollFrame + ScrollChild default width behavior: child width
        -- can be less than parent. Force the child to match the
        -- scroll frame's width so anchoring to TOPLEFT/TOPRIGHT works.
        stepScrollFrame:HookScript("OnSizeChanged", function(self, w)
            stepScrollChild:SetWidth(w)
        end)
        stepScrollChild:SetWidth(stepScrollFrame:GetWidth())

        -- Smooth scroll animation: callers set scrollTarget, an
        -- OnUpdate tween eases scrollCurrent toward it. Avoids the
        -- jumpy SetVerticalScroll-every-step feel.
        local stepScrollMax = 0
        local scrollCurrent = 0
        local scrollTarget = 0
        local scrollAnimFrame = CreateFrame("Frame")
        scrollAnimFrame:Hide()
        scrollAnimFrame:SetScript("OnUpdate", function(self, dt)
            local diff = scrollTarget - scrollCurrent
            if math.abs(diff) < 0.3 then
                scrollCurrent = scrollTarget
                stepScrollFrame:SetVerticalScroll(scrollCurrent)
                self:Hide()
                return
            end
            -- Exponential ease scaled by playbackSpeed so the scroll
            -- tween finishes faster at higher speeds (matching cursor
            -- moves and safeAfter-based pauses).
            local step = diff * mmin(dt * 8 * playbackSpeed, 1)
            scrollCurrent = scrollCurrent + step
            stepScrollFrame:SetVerticalScroll(scrollCurrent)
        end)

        local function setScrollTarget(target)
            if target < 0 then target = 0 end
            if target > stepScrollMax then target = stepScrollMax end
            scrollTarget = target
            scrollAnimFrame:Show()
        end

        stepScrollFrame:SetScript("OnMouseWheel", function(_, delta)
            setScrollTarget(scrollTarget - delta * 20)
        end)

        -- Step row builder. Pools row buttons and section header buttons
        -- so loadDemo can swap demos without leaking frames. Each step row
        -- is a Button whose OnClick jumps to that step. Each section
        -- header is also a Button whose OnClick jumps to the state right
        -- BEFORE that section's first step (so the next Play / Next plays
        -- the section from the very beginning, not the end of step 1).
        -- jumpToStep / jumpToBeforeStep are forward-declared here and
        -- assigned later, after setupAfterStep exists.
        local jumpToStep
        local jumpToBeforeStep
        local highlightOverride  -- forward decl; set by step-row clicks
        local pendingSectionHighlight  -- forward decl; set by step funcs to pre-highlight a section header during transition text
        -- Cursor position snapshots: cursorEndPos[i] = { x, y } is the
        -- cursor location at the moment step i's done() fired. Used
        -- when the user clicks a step row to jump to that step, so
        -- the cursor appears exactly where it would be mid-playback
        -- instead of resetting to the default starting spot.
        local cursorEndPos = {}
        local refreshStepList    -- forward decl; defined after rebuildStepRows
        local stepFS = {}        -- indexed by DEMO_STEPS index, used by refreshStepList
        local headerFS = {}      -- indexed by section number, used by refreshStepList
        local stepRowPool = {}   -- pool of { btn, fs } reused across demos
        local headerPool = {}    -- pool of { btn, fs } reused across demos

        local emptyMsg = demoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyMsg:SetPoint("TOP", 0, -100)
        emptyMsg:SetTextColor(0.6, 0.6, 0.6, 1)
        emptyMsg:SetText("Coming soon...")
        emptyMsg:Hide()

        -- Tracks per-step Y offset inside the scroll child so
        -- scrollToStep can slide the active step into view.
        local stepYOffset = {}  -- [stepIdx] = positive pixels from top of scrollChild
        local headerYOffset = {}  -- [sectionNum] = positive pixels from top of scrollChild

        local function rebuildStepRows()
            for _, hd in ipairs(headerPool) do hd.btn:Hide() end
            for _, row in ipairs(stepRowPool) do row.btn:Hide() end
            wipe(headerFS)
            wipe(stepFS)
            wipe(stepYOffset)
            wipe(headerYOffset)
            if not DEMO_SECTIONS or #DEMO_SECTIONS == 0 then
                emptyMsg:Show()
                stepScrollChild:SetHeight(1)
                stepScrollMax = 0
                scrollCurrent = 0
                scrollTarget = 0
                stepScrollFrame:SetVerticalScroll(0)
                return
            end
            emptyMsg:Hide()
            local headerIdx, rowIdx = 0, 0
            local y = 4  -- positive offset from top of scrollChild
            for sIdx, sect in ipairs(DEMO_SECTIONS) do
                -- Visual gap between sections (skip before the first one)
                if sIdx > 1 then y = y + 12 end
                local hasHeader = sect.header and sect.header ~= ""
                if hasHeader then
                    headerIdx = headerIdx + 1
                    local hd = headerPool[headerIdx]
                    if not hd then
                        local hbtn = CreateFrame("Button", nil, stepScrollChild)
                        hbtn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
                        local hhl = hbtn:GetHighlightTexture()
                        hhl:SetVertexColor(1, 0.82, 0, 0.12)
                        hhl:SetPoint("TOPLEFT", hbtn, "TOPLEFT", -2, 0)
                        hhl:SetPoint("BOTTOMRIGHT", hbtn, "BOTTOMRIGHT", 2, 0)
                        local hfs = hbtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        hfs:SetPoint("LEFT", hbtn, "LEFT", 0, 0)
                        hd = { btn = hbtn, fs = hfs }
                        headerPool[headerIdx] = hd
                    else
                        hd.btn:SetParent(stepScrollChild)
                    end
                    hd.btn:ClearAllPoints()
                    hd.btn:SetPoint("TOPLEFT", stepScrollChild, "TOPLEFT", 8, -y)
                    hd.btn:SetPoint("TOPRIGHT", stepScrollChild, "TOPRIGHT", -4, -y)
                    hd.btn:SetHeight(20)
                    hd.btn:Show()
                    hd.fs:SetText(sect.header)
                    local firstStep = sect.firstStep
                    hd.btn:SetScript("OnClick", function()
                        if jumpToBeforeStep then jumpToBeforeStep(firstStep) end
                    end)
                    headerFS[sect.section] = hd.fs
                    headerYOffset[sect.section] = y
                    y = y + 24
                end
                for i = sect.firstStep, sect.lastStep do
                    local step = DEMO_STEPS[i]
                    rowIdx = rowIdx + 1
                    local row = stepRowPool[rowIdx]
                    if not row then
                        local btn = CreateFrame("Button", nil, stepScrollChild)
                        btn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
                        local hl = btn:GetHighlightTexture()
                        hl:SetVertexColor(1, 0.82, 0, 0.12)
                        hl:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 0)
                        hl:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, 0)
                        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                        row = { btn = btn, fs = fs }
                        stepRowPool[rowIdx] = row
                    else
                        row.btn:SetParent(stepScrollChild)
                    end
                    row.btn:ClearAllPoints()
                    row.btn:SetPoint("TOPLEFT", stepScrollChild, "TOPLEFT", 20, -(y + 2))
                    row.btn:SetPoint("TOPRIGHT", stepScrollChild, "TOPRIGHT", -4, -(y + 2))
                    row.btn:SetHeight(18)
                    row.btn:Show()
                    row.fs:SetText(step.text)
                    stepYOffset[i] = y
                    local stepIdx = i
                    row.btn:SetScript("OnClick", function()
                        if jumpToBeforeStep then
                            jumpToBeforeStep(stepIdx)
                            highlightOverride = stepIdx
                            refreshStepList()
                        end
                    end)
                    stepFS[i] = row.fs
                    y = y + 20
                end
            end
            local contentHeight = y + 4
            stepScrollChild:SetHeight(contentHeight)
            -- Only allow scrolling when the content actually
            -- overflows the viewport. Short demos whose whole step
            -- list fits inside stepScrollFrame get stepScrollMax = 0,
            -- so setScrollTarget clamps every request back to 0 and
            -- the list sits still — no pointless crawl when there's
            -- nothing hidden.
            local viewportHeight = stepScrollFrame:GetHeight() or 0
            stepScrollMax = contentHeight - viewportHeight
            if stepScrollMax < 0 then stepScrollMax = 0 end
            scrollCurrent = 0
            scrollTarget = 0
            stepScrollFrame:SetVerticalScroll(0)
        end
        rebuildStepRows()

        -- Transport controls: [◀ Prev] [Play/Pause] [Next ▶]
        -- The arrow buttons use the existing flyout-arrow.tga rotated,
        -- and play/pause uses custom TGAs (demo-play.tga, demo-pause.tga)
        -- so the glyphs render reliably regardless of font support.
        local playBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        playBtn:SetSize(35, 27)
        playBtn:SetPoint("BOTTOM", demoFrame, "BOTTOM", 0, 44)
        playBtn:SetText("")
        local playIcon = playBtn:CreateTexture(nil, "OVERLAY")
        playIcon:SetSize(11, 11)
        playIcon:SetPoint("CENTER")
        playIcon:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
        playBtn.icon = playIcon

        local prevBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        prevBtn:SetSize(27, 27)
        prevBtn:SetPoint("RIGHT", playBtn, "LEFT", -3, 0)
        prevBtn:SetText("")
        local prevIcon = prevBtn:CreateTexture(nil, "OVERLAY")
        prevIcon:SetSize(10, 10)
        prevIcon:SetPoint("CENTER")
        prevIcon:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
        prevIcon:SetTexCoord(1, 0, 0, 1)  -- horizontal flip for left-pointing arrow

        local nextBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        nextBtn:SetSize(27, 27)
        nextBtn:SetPoint("LEFT", playBtn, "RIGHT", 3, 0)
        nextBtn:SetText("")
        local nextIcon = nextBtn:CreateTexture(nil, "OVERLAY")
        nextIcon:SetSize(10, 10)
        nextIcon:SetPoint("CENTER")
        nextIcon:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")

        -- Section skip buttons (<<, >>) sit on the far ends of the
        -- transport row. Each renders the flyout-arrow texture twice so
        -- the icon reads as a "double arrow". Click jumps to the previous
        -- / next section header (or very start / end of the demo).
        local sectPrevBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        sectPrevBtn:SetSize(27, 27)
        sectPrevBtn:SetPoint("RIGHT", prevBtn, "LEFT", -3, 0)
        sectPrevBtn:SetText("")
        local sectPrevIcon1 = sectPrevBtn:CreateTexture(nil, "OVERLAY")
        sectPrevIcon1:SetSize(8, 8)
        sectPrevIcon1:SetPoint("CENTER", -4, 0)
        sectPrevIcon1:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
        sectPrevIcon1:SetTexCoord(1, 0, 0, 1)
        local sectPrevIcon2 = sectPrevBtn:CreateTexture(nil, "OVERLAY")
        sectPrevIcon2:SetSize(8, 8)
        sectPrevIcon2:SetPoint("CENTER", 4, 0)
        sectPrevIcon2:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
        sectPrevIcon2:SetTexCoord(1, 0, 0, 1)

        local sectNextBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        sectNextBtn:SetSize(27, 27)
        sectNextBtn:SetPoint("LEFT", nextBtn, "RIGHT", 3, 0)
        sectNextBtn:SetText("")
        local sectNextIcon1 = sectNextBtn:CreateTexture(nil, "OVERLAY")
        sectNextIcon1:SetSize(8, 8)
        sectNextIcon1:SetPoint("CENTER", -4, 0)
        sectNextIcon1:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
        local sectNextIcon2 = sectNextBtn:CreateTexture(nil, "OVERLAY")
        sectNextIcon2:SetSize(8, 8)
        sectNextIcon2:SetPoint("CENTER", 4, 0)
        sectNextIcon2:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")

        -- Tooltip hints so the arrow-only buttons are still discoverable
        local function attachTooltip(btn, text)
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(text)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", GameTooltip_Hide)
        end
        -- Replay button: appears when the demo reaches its final step,
        -- replacing the Play button. Clicking it resets the demo to its
        -- initial state so the player can choose Play or Next again.
        local replayBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        replayBtn:SetSize(35, 27)
        replayBtn:SetPoint("CENTER", playBtn, "CENTER", 0, 0)
        replayBtn:SetText("")
        local replayIcon = replayBtn:CreateTexture(nil, "OVERLAY")
        replayIcon:SetSize(14, 14)
        replayIcon:SetPoint("CENTER")
        replayIcon:SetTexture("Interface\\AddOns\\EasyFind\\demo-replay")
        replayBtn:Hide()

        -- Stop button: hard-resets the demo to its initial state, as if
        -- the demo window had just been opened. Sits at the very far
        -- left of the transport row.
        local stopBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        stopBtn:SetSize(27, 27)
        stopBtn:SetPoint("RIGHT", sectPrevBtn, "LEFT", -3, 0)
        stopBtn:SetText("")
        local stopIcon = stopBtn:CreateTexture(nil, "OVERLAY")
        stopIcon:SetSize(9, 9)
        stopIcon:SetPoint("CENTER")
        stopIcon:SetTexture("Interface\\Buttons\\WHITE8x8")
        stopIcon:SetVertexColor(0.95, 0.85, 0.2, 1)

        -- Speed button: opens a flyout with playback-speed multipliers.
        -- Sits at the very far right of the transport row. Uses the
        -- gold cogwheel TGA generated by gen_cog_icon.py.
        local speedBtn = CreateFrame("Button", nil, demoFrame, "UIPanelButtonTemplate")
        speedBtn:SetSize(27, 27)
        speedBtn:SetPoint("LEFT", sectNextBtn, "RIGHT", 3, 0)
        speedBtn:SetText("")
        local speedIcon = speedBtn:CreateTexture(nil, "OVERLAY")
        speedIcon:SetSize(16, 16)
        speedIcon:SetPoint("CENTER")
        speedIcon:SetTexture("Interface\\AddOns\\EasyFind\\demo-cog")

        attachTooltip(stopBtn, "Stop / Reset Demo")
        attachTooltip(sectPrevBtn, "Previous Section")
        attachTooltip(prevBtn, "Previous Step")
        attachTooltip(nextBtn, "Next Step")
        attachTooltip(sectNextBtn, "Next Section")
        attachTooltip(speedBtn, "Playback Speed")
        attachTooltip(playBtn, "Play / Pause")
        attachTooltip(replayBtn, "Replay Demo")

        -- Top-right close button (matches the Options panel). Replaces
        -- the old "Got it" bottom button so the bottom of the panel can
        -- pull tighter against the dropdown row.
        local closeDemoBtn = CreateFrame("Button", nil, demoFrame, "UIPanelCloseButton")
        closeDemoBtn:SetPoint("TOPRIGHT", demoFrame, "TOPRIGHT", -5, -5)

        -- "See more demos" dropdown. Same visual style as the multi-select
        -- dropdowns in the EasyFind options panel (Search Bars, EF Map
        -- Icons, Minimap, Map Pins): WoW common-dropdown atlas background
        -- with a chevron arrow on the right. Sits between the transport
        -- row and the Got it button. Opens upward over the step list so
        -- it doesn't spill below the demo panel.
        local DEMO_LIST = {
            { name = "UI Search",                key = "uiSearch" },
            { name = "Guide Mode",               key = "guide" },
            { name = "Outfits",                  key = "outfits" },
            { name = "Appearance sets",          key = "appearanceSets" },
            { name = "Loot",                     key = "loot" },
            { name = "Mounts",                   key = "mounts" },
        }

        local moreBtn = CreateFrame("Button", nil, demoFrame)
        moreBtn:SetSize(200, 26)
        moreBtn:SetPoint("BOTTOM", demoFrame, "BOTTOM", 0, 12)
        local moreBg = moreBtn:CreateTexture(nil, "BACKGROUND")
        moreBg:SetAllPoints()
        moreBg:SetAtlas("common-dropdown-b-button-hover")
        local moreBtnText = moreBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        moreBtnText:SetPoint("LEFT", 4, 0)
        moreBtnText:SetPoint("RIGHT", -18, 0)
        moreBtnText:SetJustifyH("CENTER")
        moreBtnText:SetText("See more demos")
        local moreArrow = moreBtn:CreateTexture(nil, "OVERLAY")
        moreArrow:SetSize(18, 18)
        moreArrow:SetPoint("RIGHT", -2, 0)
        moreArrow:SetAtlas("common-dropdown-b-arrow-closed")

        local MORE_ROW_H = 24
        local moreFlyout = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        moreFlyout:SetSize(200, #DEMO_LIST * MORE_ROW_H + 8)
        moreFlyout:SetFrameStrata("FULLSCREEN_DIALOG")
        moreFlyout:SetFrameLevel(900)
        moreFlyout:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        moreFlyout:SetBackdropColor(0.08, 0.08, 0.08, 1)
        moreFlyout:Hide()

        moreBtn:SetScript("OnClick", function()
            moreFlyout:ClearAllPoints()
            -- Open upward so the menu hangs over the step list instead
            -- of spilling below the demo panel.
            moreFlyout:SetPoint("BOTTOM", moreBtn, "TOP", 0, 2)
            local opening = not moreFlyout:IsShown()
            moreFlyout:SetShown(opening)
            moreArrow:SetAtlas(opening and "common-dropdown-b-arrow-open" or "common-dropdown-b-arrow-closed")
        end)
        moreFlyout:SetScript("OnShow", function(self)
            self:SetScript("OnUpdate", function(s)
                if not s:IsMouseOver() and not moreBtn:IsMouseOver() then
                    if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                        s:Hide()
                    end
                end
            end)
        end)
        moreFlyout:SetScript("OnHide", function(self)
            self:SetScript("OnUpdate", nil)
            moreArrow:SetAtlas("common-dropdown-b-arrow-closed")
        end)

        local moreItems = {}
        for i, entry in ipairs(DEMO_LIST) do
            local item = CreateFrame("Button", nil, moreFlyout)
            item:SetSize(192, 22)
            item:SetPoint("TOPLEFT", moreFlyout, "TOPLEFT", 4, -4 - (i - 1) * MORE_ROW_H)
            item:SetNormalFontObject("GameFontNormal")
            item:SetHighlightFontObject("GameFontHighlight")
            item:SetText(entry.name)
            local itemHL = item:CreateTexture(nil, "BACKGROUND")
            itemHL:SetAllPoints()
            itemHL:SetColorTexture(1, 0.82, 0, 0.12)
            itemHL:Hide()
            item:SetScript("OnEnter", function() itemHL:Show() end)
            item:SetScript("OnLeave", function() itemHL:Hide() end)
            local entryKey = entry.key
            item:SetScript("OnClick", function()
                moreFlyout:Hide()
                if loadDemo then loadDemo(entryKey) end
            end)
            moreItems[i] = { btn = item, key = entry.key, name = entry.name }
        end

        -- Color the active demo's row gold so the player can see which
        -- demo is currently loaded. Inactive rows render in white.
        refreshDemoMenuActive = function()
            for _, mi in ipairs(moreItems) do
                if mi.key == currentDemoKey then
                    mi.btn:SetText("|cffFFD100" .. mi.name .. "|r")
                else
                    mi.btn:SetText("|cffFFFFFF" .. mi.name .. "|r")
                end
            end
        end
        refreshDemoMenuActive()

        -- Playback-speed flyout. Opens above the speed cog button at
        -- the far-right of the transport row. Active speed is gold.
        local SPEED_OPTIONS = { 0.5, 0.75, 1.0, 1.25, 1.5 }
        local SPEED_ROW_H = 22
        local speedFlyout = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        speedFlyout:SetSize(80, #SPEED_OPTIONS * SPEED_ROW_H + 8)
        speedFlyout:SetFrameStrata("FULLSCREEN_DIALOG")
        speedFlyout:SetFrameLevel(900)
        speedFlyout:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = TOOLTIP_BORDER,
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        speedFlyout:SetBackdropColor(0.08, 0.08, 0.08, 1)
        speedFlyout:Hide()

        speedBtn:SetScript("OnClick", function()
            speedFlyout:ClearAllPoints()
            speedFlyout:SetPoint("BOTTOM", speedBtn, "TOP", 0, 4)
            speedFlyout:SetShown(not speedFlyout:IsShown())
        end)
        speedFlyout:SetScript("OnShow", function(self)
            self:SetScript("OnUpdate", function(s)
                if not s:IsMouseOver() and not speedBtn:IsMouseOver() then
                    if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
                        s:Hide()
                    end
                end
            end)
        end)
        speedFlyout:SetScript("OnHide", function(self)
            self:SetScript("OnUpdate", nil)
        end)

        local speedItems = {}
        local function refreshSpeedMenu()
            for _, mi in ipairs(speedItems) do
                if mi.value == playbackSpeed then
                    mi.btn:SetText("|cffFFD100" .. mi.label .. "|r")
                else
                    mi.btn:SetText("|cffFFFFFF" .. mi.label .. "|r")
                end
            end
        end
        for i, mult in ipairs(SPEED_OPTIONS) do
            local item = CreateFrame("Button", nil, speedFlyout)
            item:SetSize(72, 20)
            item:SetPoint("TOPLEFT", speedFlyout, "TOPLEFT", 4, -4 - (i - 1) * SPEED_ROW_H)
            item:SetNormalFontObject("GameFontNormal")
            item:SetHighlightFontObject("GameFontHighlight")
            local label = (mult == math.floor(mult)) and (tostring(math.floor(mult)) .. "x") or (tostring(mult) .. "x")
            item:SetText(label)
            local itemHL = item:CreateTexture(nil, "BACKGROUND")
            itemHL:SetAllPoints()
            itemHL:SetColorTexture(1, 0.82, 0, 0.12)
            itemHL:Hide()
            item:SetScript("OnEnter", function() itemHL:Show() end)
            item:SetScript("OnLeave", function() itemHL:Hide() end)
            local mySpeed = mult
            item:SetScript("OnClick", function()
                playbackSpeed = mySpeed
                speedFlyout:Hide()
                refreshSpeedMenu()
            end)
            speedItems[i] = { btn = item, value = mult, label = label }
        end
        refreshSpeedMenu()

        -- State vars used by both setActiveStep() and the state machine.
        -- completedUpTo: highest step index that's already run (0 = none)
        -- animatingIdx:  step currently running (0 = none)
        local completedUpTo = 0
        local animatingIdx = 0

        -- Re-render the step list. Only ONE element is bright gold at a
        -- time: a step when animating or mid-section, the section HEADER
        -- when idle at a section boundary (e.g., demo just opened or
        -- just finished the previous section). The active section's
        -- header is white; all non-active headers and non-active steps
        -- are gray.
        -- Scroll the active step into view inside stepScrollFrame. The
        -- target Y offset is chosen so the step sits a little below the
        -- top edge (so it looks like it just "crawled up" past the
        -- title separator). Routes through setScrollTarget so the
        -- scroll animates smoothly instead of snapping.
        local function scrollToStep(stepIdx)
            if not stepIdx or not stepYOffset[stepIdx] then return end
            setScrollTarget(stepYOffset[stepIdx] - 6)
        end

        local function scrollToHeader(sectionNum)
            if not sectionNum or not headerYOffset[sectionNum] then return end
            setScrollTarget(headerYOffset[sectionNum] - 6)
        end

        -- Called by a step function to pre-highlight a later section's
        -- header while the step is still technically running (e.g.
        -- while the "Now let's..." transition text is on screen). The
        -- header lights up and scrolls into view immediately. Stays
        -- highlighted until the next runStep clears the flag or a
        -- cancelInFlight wipes demo state.
        local function beginSectionTransition(sectionNum)
            pendingSectionHighlight = sectionNum
            refreshStepList()
        end

        refreshStepList = function()
            if not DEMO_STEPS or #DEMO_STEPS == 0 then return end
            local activeStep, activeHeader
            if pendingSectionHighlight then
                -- A step's action has explicitly requested the next
                -- section's header be highlighted (e.g. during the
                -- "Now let's see what that looks like..." transition
                -- text). The header stays gold, no step is active.
                activeHeader = pendingSectionHighlight
            elseif highlightOverride then
                activeStep = highlightOverride
            elseif animatingIdx > 0 then
                activeStep = animatingIdx
            else
                local nextIdx = completedUpTo + 1
                if nextIdx <= #DEMO_STEPS then
                    -- At a section boundary? Highlight the header instead
                    -- of the first step (the step lights up once Play is
                    -- hit, not before).
                    local atBoundary = false
                    for _, sect in ipairs(DEMO_SECTIONS) do
                        if nextIdx == sect.firstStep then
                            atBoundary = true
                            activeHeader = sect.section
                            break
                        end
                    end
                    if not atBoundary then
                        activeStep = nextIdx
                    end
                end
            end
            local focusSection
            if activeStep then
                focusSection = DEMO_STEPS[activeStep] and DEMO_STEPS[activeStep].section
            elseif activeHeader then
                focusSection = activeHeader
            end

            for _, sect in ipairs(DEMO_SECTIONS) do
                local hfs = headerFS[sect.section]
                if hfs then
                    if sect.section == activeHeader then
                        hfs:SetTextColor(1.0, 0.82, 0.0, 1.0)    -- gold (highlighted)
                    elseif sect.section == focusSection then
                        hfs:SetTextColor(1.0, 1.0, 1.0, 1.0)     -- white (active section)
                    else
                        hfs:SetTextColor(0.5, 0.5, 0.5, 0.85)    -- gray
                    end
                end
            end

            for j, fs in ipairs(stepFS) do
                if j == activeStep then
                    fs:SetTextColor(1.0, 0.82, 0.0, 1.0)         -- gold (current step)
                else
                    fs:SetTextColor(0.5, 0.5, 0.5, 0.85)         -- gray
                end
            end

            -- Slide the active step (or active header at a section
            -- boundary) into the visible window. Earlier rows scroll
            -- "under" the title separator (clipped by the scroll
            -- frame), later rows remain below it until their turn.
            if activeStep then
                scrollToStep(activeStep)
            elseif activeHeader then
                scrollToHeader(activeHeader)
            end
        end
        refreshStepList()

        -- Everything below lives inside _runDemo so its locals don't
        -- count toward startDemo's MAXVARS=200 budget AND so they
        -- aren't upvalues for _runDemo's inner closures (avoids
        -- MAXUPVAL=60). _runDemo runs immediately at the bottom of
        -- startDemo.
        local function _runDemo()

        -- Save originals so the lock toggling system can restore them
        -- when the demo isn't actively running. The search bar drag
        -- handler and the editbox keyboard state are both temporarily
        -- replaced/disabled while a step is animating, then restored
        -- whenever the demo is paused, idle, or stopped.
        local savedDragStart = searchFrame:GetScript("OnDragStart")
        -- Also snapshot the UI bar's Map Search filter toggle and
        -- local/global sub-option. The map-search-through-UI-bar demo
        -- flips both and must restore the user's actual pre-demo
        -- preference on stop/close, otherwise the bar would behave
        -- differently after running the demo.
        local savedUiMapFilter
        if EasyFind.db.uiSearchFilters then
            savedUiMapFilter = EasyFind.db.uiSearchFilters.map
        end
        local savedUiMapSearchLocal = EasyFind.db.uiMapSearchLocal

        -- Snapshot WMF's current mapID so demos that navigate WMF (the
        -- zone/instance demo calls SelectResult, which SetMapIDs to the
        -- instance entrance) don't leak that state into later demos.
        -- WMF may not be loaded yet at this point; openWorldMap will
        -- lazy-capture the real pre-demo mapID right after it loads the
        -- addon. restoreWmfMapID reverts WMF on every demo switch and
        -- on panel close.
        local savedWmfMapID
        if WorldMapFrame and WorldMapFrame.GetMapID then
            savedWmfMapID = WorldMapFrame:GetMapID()
        end
        local function restoreWmfMapID()
            if not savedWmfMapID then return end
            if InCombatLockdown() then return end
            if not (WorldMapFrame and WorldMapFrame.SetMapID) then return end
            if WorldMapFrame:GetMapID() == savedWmfMapID then return end
            pcall(WorldMapFrame.SetMapID, WorldMapFrame, savedWmfMapID)
        end

        -- The UI filter dropdown has an OnUpdate handler that auto-hides
        -- when the user's mouse button is down outside the dropdown. The
        -- demo's click blockers eat real clicks but the button-down
        -- state still reads true, which causes spurious auto-close
        -- during demo playback. Swap in a no-op OnUpdate for the demo's
        -- lifetime so the dropdown stays open when the demo wants it
        -- open. Suspend/resume is tied to applyRunningLocks/releaseRunningLocks
        -- so the dropdown works normally when the demo is idle.

        -- Temporarily force-disable movement fade (staticOpacity = true)
        -- so the search bar stays at full alpha even if the player walks
        -- around mid-demo. Restored on endDemo.
        local savedStaticOpacity = EasyFind.db.staticOpacity
        EasyFind.db.staticOpacity = true
        searchFrame:SetAlpha(1.0)

        -- Mock cursor that animates between targets. Parented to UIParent
        -- so we can position it in any coordinate space via raw pixel
        -- offsets and so it floats above the rest of the UI.
        local cursor = CreateFrame("Frame", nil, UIParent)
        cursor:SetSize(36, 36)
        cursor:SetFrameStrata("TOOLTIP")
        cursor:SetFrameLevel(10001)
        cursor:EnableMouse(false)
        local cursorTex = cursor:CreateTexture(nil, "OVERLAY")
        cursorTex:SetAllPoints()
        -- HD Gauntlet texture in its natural orientation.
        cursorTex:SetTexture(4489300)
        cursorTex:SetTexCoord(0.0000, 0.2315, 0.0000, 0.4104)
        cursor:Hide()

        local rightClickIcon = cursor:CreateTexture(nil, "OVERLAY")
        rightClickIcon:SetAtlas("newplayertutorial-icon-mouse-rightbutton")
        rightClickIcon:SetSize(48, 48)
        rightClickIcon:SetPoint("LEFT", cursor, "RIGHT", 2, 0)
        rightClickIcon:Hide()

        active = true
        -- stepGen is bumped whenever an in-flight animation is cancelled so
        -- Prev/Next can interrupt at any time. Every async helper captures
        -- the gen at call time and aborts if it no longer matches.
        local stepGen = 0
        -- True-pause support: virtualTime only advances when not paused, and
        -- safeAfter timers fire based on virtualTime via tickFrame's
        -- OnUpdate. Cursor OnUpdate handlers also early-return when paused
        -- so cursor moves and click animations freeze in place.
        local paused = false
        local virtualTime = 0
        local pendingTimers = {}
        local stopBlinkCursor    -- forward decl; defined below next to typeText
        local updateLockState    -- forward decl; defined where the locks are built
        local locksSuppressed    -- forward decl; defined where the locks are built
        local applyRunningLocks  -- forward decl; defined where the locks are built
        local releaseRunningLocks -- forward decl; defined where the locks are built
        local setHoveredRow      -- forward decl; defined with result-row hover
        local clearButtonHover   -- forward decl; defined before moveCursorTo
        local resetMapSearchState  -- forward decl; defined with map search demo
        local closeWorldMap        -- forward decl; defined with map search demo
        local hideMapCaret         -- forward decl; defined with map search demo

        local tickFrame = CreateFrame("Frame")
        tickFrame:SetScript("OnUpdate", function(_, dt)
            if not active or paused then return end
            virtualTime = virtualTime + dt * playbackSpeed
            local i = 1
            while i <= #pendingTimers do
                local t = pendingTimers[i]
                if t.fireAt <= virtualTime then
                    tremove(pendingTimers, i)
                    if t.gen == stepGen then
                        pcall(t.fn)
                        -- t.fn may have queued more timers (or wiped the
                        -- queue via cancelInFlight); restart the scan to
                        -- handle index shifts safely.
                        i = 1
                    end
                else
                    i = i + 1
                end
            end
        end)

        local function safeAfter(delay, fn)
            if not active then return end
            tinsert(pendingTimers, {
                fireAt = virtualTime + delay,
                fn = fn,
                gen = stepGen,
            })
        end

        -- Restore the user's pre-demo filter state.
        local function restoreUserSettings()
            -- staticOpacity stays forced true while the demo is open;
            -- it's restored in endDemo, not here, so loadDemo doesn't
            -- re-enable movement fade between demo switches.
            EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
            EasyFind.db.uiSearchFilters.map = savedUiMapFilter
            EasyFind.db.uiMapSearchLocal = savedUiMapSearchLocal
            -- Refresh the filter dropdown's visual state to match the
            -- restored saved values (map checkbox + local/global sub).
            local dd = searchFrame.filterDropdown
            if dd and dd.checkRows and dd.checkRows.map then
                local mr = dd.checkRows.map
                if mr.SetChecked then mr:SetChecked(savedUiMapFilter ~= false) end
                if mr.updateMapToggle then mr.updateMapToggle() end
            end
        end

        -- Transition banner shown at the end of Fast Mode, hidden when
        -- Guide Mode begins. Anchored near the top-center of the screen
        -- on the TOOLTIP strata so it floats above every menu and frame.
        -- A fade-in/out animation group softens the transition.
        local transitionFrame = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        transitionFrame:SetPoint("TOP", UIParent, "TOP", 0, -160)
        transitionFrame:SetSize(460, 80)
        local transitionFS = transitionFrame.fs
        transitionFS:SetText("Now let's take a look at what that process looks like in Guide Mode.")

        transitionFrame:Hide()

        -- Shim so existing Show/Hide callsites targeting transitionText
        -- still work even though the actual visible object is the frame.
        local transitionText = {}
        function transitionText:Show() transitionFrame:Show() end
        function transitionText:Hide() transitionFrame:Hide() end

        -- Minimap callout: tutorial-style hint box anchored to the
        -- minimap, used to draw attention to minimap changes (e.g.
        -- "your target is now tracked"). Box sits to the LEFT of the
        -- minimap with its vertical center aligned to the minimap's
        -- vertical center, with a 65 px gap on the right for the
        -- chevron pointer's full visible sweep (see AttachPointer below).
        local minimapCalloutFrame = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        minimapCalloutFrame:SetSize(220, 60)
        if _G["Minimap"] then
            minimapCalloutFrame:SetPoint("RIGHT", _G["Minimap"], "LEFT", -65, 0)
        else
            minimapCalloutFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -240, -80)
        end
        local minimapCalloutFS = minimapCalloutFrame.fs
        minimapCalloutFS:SetText("Note how your target is now tracked!")
        minimapCalloutFrame:Hide()

        local minimapCallout = {}
        function minimapCallout:SetText(text)
            minimapCalloutFS:SetText(text or "")
            -- Narrower cap than the map-search callout (which has ~300 px
            -- of horizontal room to the right of the results frame).
            -- Over the minimap area there's less room and the phrases
            -- here are short, so 220 keeps the box compact without
            -- triggering awkward 3+ line wraps.
            minimapCalloutFrame:SetAutoSized(220)
        end
        function minimapCallout:Show() minimapCalloutFrame:Show() end
        function minimapCallout:Hide() minimapCalloutFrame:Hide() end

        -- Floating narration anchored next to the local map search frame.
        -- Used by mapSearchCurrent's "browse what's around" step. Has an
        -- attached left-pointing arrow that is only shown via
        -- :ShowWithArrow() for the hover-preview step; other callers use
        -- plain :Show() and get the box without the arrow.
        local mapSearchCallout = {}
        mapSearchCallout.frame = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        mapSearchCallout.frame:SetSize(280, 60)
        mapSearchCallout.frame:Hide()
        mapSearchCallout.fs = mapSearchCallout.frame.fs
        -- Persistent left-pointing chevron. Travel = gap between the box's
        -- left edge and the right edge of the results frame, so the apex
        -- lands right on the results. Parented to the tutorial box, so it
        -- inherits strata/visibility and hides automatically when the box
        -- hides. Created once and toggled via the arrow driver's own
        -- Show/Hide (preserving the animation's elapsed state).
        -- Cadence copied from modePointer (UI.lua) — the canonical
        -- tutorial-arrow recipe. Only `direction` and `travel` should
        -- vary per caller; the rest stay as-is across every chevron.
        mapSearchCallout.arrow = ns.TutorialBox.AttachPointer(mapSearchCallout.frame, {
            direction   = "left",
            travel      = 36,
            duration    = 1.25,
            count       = 2,
            easing      = 0.5,
            fadeStart   = 0.75,
            startOffset = -10,
            glow        = 0.7,
        })
        mapSearchCallout.arrow.frame:Hide()
        function mapSearchCallout:SetText(text)
            self.fs:SetText(text or "")
            self.frame:SetAutoSized(340)
        end
        function mapSearchCallout:Show()
            -- Anchor once per show-session to the results frame (so the
            -- gap is right for current scrollbar / mapSearchWidth state),
            -- then freeze the position by re-anchoring to UIParent with
            -- the absolute coords. Within a session the results frame
            -- resizes as the user types different prefixes; without the
            -- freeze the callout would jump around with each resize.
            -- Hide() resets anchorLocked so the next show recomputes.
            if not self.anchorLocked then
                local rf = _G["EasyFindMapResultsFrame"]
                local lsf = _G["EasyFindMapSearchFrame"]
                self.frame:ClearAllPoints()
                if rf and rf:IsShown() then
                    -- 65 px leaves room for the chevron's full ~63 px
                    -- visible sweep (texSize 64 minus 2 * apexInset of
                    -- 18.58 = 26.84 visible shape, plus 36 travel) so
                    -- the apex lands just past the results edge at peak
                    -- travel without cutting into the result rows.
                    self.frame:SetPoint("TOPLEFT", rf, "TOPRIGHT", 65, -4)
                elseif lsf then
                    -- Fallback for callsites that run before results open.
                    self.frame:SetPoint("LEFT", lsf, "RIGHT", 120, -40)
                end
                -- Show before reading GetLeft/GetTop so the layout pass
                -- resolves the anchor to actual screen coords.
                self.frame:Show()
                local l, t = self.frame:GetLeft(), self.frame:GetTop()
                if l and t then
                    self.frame:ClearAllPoints()
                    self.frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
                    self.anchorLocked = true
                end
            end
            self.arrow.frame:Hide()
            self.frame:Show()
        end
        function mapSearchCallout:ShowWithArrow()
            self:Show()
            self.arrow.frame:Show()
        end
        -- Cross-fade the old text up and out while the new text rises up
        -- from below to take its place. Box size, anchor, and arrow all
        -- stay put. Falls through to a plain Show when the callout isn't
        -- already visible (no "old text" to scroll away). Same ease/timing
        -- family as setScrollTarget's OnUpdate tween, just applied per
        -- fontstring.
        mapSearchCallout.textAnim = CreateFrame("Frame")
        mapSearchCallout.textAnim:Hide()
        function mapSearchCallout:SetTextScrolling(newText)
            local isShown = self.frame:IsShown()
            local oldText = self.fs:GetText() or ""
            if not isShown or oldText == "" then
                self:SetText(newText)
                self:ShowWithArrow()
                return
            end
            if oldText == newText then return end
            -- Lazy-create the secondary fontstring the first time we swap.
            -- Shares fs's current color/shadow/justify so the transition
            -- reads as the same text just changing words.
            if not self.fs2 then
                local fs2 = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                fs2:SetJustifyH("CENTER")
                fs2:SetJustifyV("MIDDLE")
                fs2:SetTextColor(self.fs:GetTextColor())
                fs2:SetShadowColor(0, 0, 0, 1)
                fs2:SetShadowOffset(1, -1)
                self.fs2 = fs2
            end
            -- fs2 carries the OLD text (scrolls up and out). fs takes the
            -- NEW text and scrolls up from below into center.
            self.fs2:SetWidth(self.fs:GetWidth())
            self.fs2:SetText(oldText)
            self.fs2:ClearAllPoints()
            self.fs2:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
            self.fs2:SetAlpha(1)
            self.fs:SetText(newText)
            self.fs:ClearAllPoints()
            self.fs:SetPoint("CENTER", self.frame, "CENTER", 0, -20)
            self.fs:SetAlpha(0)
            local duration = 0.35
            local elapsed = 0
            self.textAnim:SetScript("OnUpdate", function(_, dt)
                elapsed = elapsed + dt
                local t = elapsed / duration
                if t > 1 then t = 1 end
                local eased = t * t * (3 - 2 * t)
                self.fs2:ClearAllPoints()
                self.fs2:SetPoint("CENTER", self.frame, "CENTER", 0, 20 * eased)
                self.fs2:SetAlpha(1 - eased)
                self.fs:ClearAllPoints()
                self.fs:SetPoint("CENTER", self.frame, "CENTER", 0, -20 * (1 - eased))
                self.fs:SetAlpha(eased)
                if t >= 1 then
                    self.textAnim:SetScript("OnUpdate", nil)
                    self.textAnim:Hide()
                    self.fs:ClearAllPoints()
                    self.fs:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
                    self.fs:SetAlpha(1)
                    self.fs2:SetAlpha(0)
                    self.fs2:SetText("")
                end
            end)
            self.textAnim:Show()
        end
        function mapSearchCallout:Hide()
            -- Cancel any in-flight scroll so a later Show() starts fresh.
            if self.textAnim then
                self.textAnim:SetScript("OnUpdate", nil)
                self.textAnim:Hide()
            end
            if self.moveAnim then
                self.moveAnim:SetScript("OnUpdate", nil)
                self.moveAnim:Hide()
            end
            if self.fs2 then
                self.fs2:SetAlpha(0)
                self.fs2:SetText("")
            end
            -- Drop the locked absolute anchor so the next Show()
            -- re-computes against whatever state the results frame is
            -- in at that point (scrollbar present/absent, different
            -- mapSearchWidth, etc.).
            self.anchorLocked = nil
            self.fs:ClearAllPoints()
            self.fs:SetPoint("CENTER", self.frame, "CENTER", 0, 0)
            self.fs:SetAlpha(1)
            self.arrow.frame:Hide()
            self.frame:Hide()
        end

        -- Emitter frames for the two clear-button chevrons. Each emitter
        -- sits ~63 px to the LEFT of its clear button at show time; the
        -- attached chevron emerges through its right border and its
        -- phase-1 apex lands at the button's left edge. Emitters are 1
        -- px so they don't render anything themselves. Cadence copied
        -- from modePointer (the canonical tutorial-arrow recipe).
        local function makeClearChevron()
            local emitter = CreateFrame("Frame", nil, UIParent)
            emitter:SetSize(1, 1)
            emitter:SetFrameStrata("TOOLTIP")
            emitter:Hide()
            local chev = ns.TutorialBox.AttachPointer(emitter, {
                direction   = "right",
                travel      = 36,
                duration    = 1.25,
                count       = 2,
                easing      = 0.5,
                fadeStart   = 0.75,
                startOffset = -10,
                glow        = 0.7,
            })
            chev.frame:Hide()
            return { emitter = emitter, chev = chev }
        end
        local localClearPointer  = makeClearChevron()
        local globalClearPointer = makeClearChevron()

        -- Forward decl so endDemo / cancelInFlight / resetDemoGameState
        -- can call minimapArrow:Hide() via upvalue. The methods are
        -- attached later, once the arrow frame is built alongside the
        -- map search demo helpers.
        local minimapArrow = {}
        function minimapArrow:Show() end
        function minimapArrow:Hide() end

        -- Ticker used by the end-of-demo tracking-state narration to
        -- poll EasyFindNearTrack:IsShown() until the player crosses
        -- into the other mode. Held at this scope so endDemo /
        -- cancelInFlight can cancel it if the demo is aborted.
        local trackingStateTicker

        local function endDemo()
            active = false
            paused = false
            if searchFrame.filterDropdown then
                searchFrame.filterDropdown._demoSuspend = nil
            end
            wipe(pendingTimers)
            tickFrame:SetScript("OnUpdate", nil)
            cursor:SetScript("OnUpdate", nil)
            cursor:Hide()
            stopBlinkCursor()
            setHoveredRow(nil)
            clearButtonHover()
            transitionText:Hide()
            mapSearchCallout:Hide()
            localClearPointer.chev.frame:Hide()
            localClearPointer.emitter:Hide()
            globalClearPointer.chev.frame:Hide()
            globalClearPointer.emitter:Hide()
            if trackingStateTicker then trackingStateTicker:Cancel(); trackingStateTicker = nil end
            minimapCallout:Hide()
            minimapArrow:Hide()
            hideMapCaret()
            if ns.MapSearch then ns.MapSearch._demoHoverLock = nil end
            -- Wipe any demo-modified search bar state so the bar returns
            -- to its clean default (placeholder visible, no stale text).
            searchFrame.editBox:SetText("")
            UI:OnSearchTextChanged("")
            searchFrame.editBox:ClearFocus()
            if searchFrame.editBox.placeholder then
                searchFrame.editBox.placeholder:Show()
            end
            if searchFrame.filterDropdown then
                if searchFrame.filterDropdown:IsShown() then
                    searchFrame.filterDropdown:Hide()
                end
                searchFrame.filterDropdown._demoSuspend = nil
            end
            if ns.Highlight and ns.Highlight.ClearAll then
                pcall(ns.Highlight.ClearAll, ns.Highlight)
            end
            -- Clean up map search state if a map demo was running.
            if resetMapSearchState then pcall(resetMapSearchState) end
            -- Revert WMF mapID so the user's map returns to whatever
            -- they had open before starting the demo, not wherever a
            -- demo step navigated to (e.g. the instance entrance the
            -- zone/instance demo jumps to).
            restoreWmfMapID()
            if closeWorldMap then pcall(closeWorldMap) end
            -- Release every blocker, restore drag handler and editbox.
            if updateLockState then updateLockState() end
            demoFrame:Hide()
            restoreUserSettings()
            EasyFind.db.staticOpacity = savedStaticOpacity
            if not InCombatLockdown() then
                local psf = _G["PlayerSpellsFrame"]
                if psf and psf.IsShown and psf:IsShown() then
                    pcall(HideUIPanel, psf)
                end
            end
            FinishSetup()
        end

        closeDemoBtn:SetScript("OnClick", endDemo)

        -- Escape closes the demo, but only if the editbox doesn't have
        -- focus. If the editbox is focused, the first Esc unfocuses it
        -- (WoW's default behavior); the second Esc closes the demo.
        demoFrame:EnableKeyboard(true)
        demoFrame:SetPropagateKeyboardInput(true)
        demoFrame:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                if searchFrame.editBox:HasFocus() then
                    searchFrame.editBox:ClearFocus()
                    self:SetPropagateKeyboardInput(false)
                else
                    self:SetPropagateKeyboardInput(false)
                    endDemo()
                end
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)

        -- Compute a frame's center in UIParent's coordinate space, taking
        -- effective scale into account so the cursor lines up with the
        -- target regardless of where the target lives in the frame tree.
        local function centerInUIParent(frame)
            if not frame or not frame.GetCenter or not frame:IsShown() then return nil end
            local cx, cy = frame:GetCenter()
            if not cx then return nil end
            local fs = frame:GetEffectiveScale()
            local us = UIParent:GetEffectiveScale()
            return cx * fs / us, cy * fs / us
        end

        -- Simulate hover highlights on result rows as the cursor passes
        -- over them. A single texture is re-anchored to the hovered row
        -- each frame, bypassing the WoW highlight system (which won't
        -- fire because click blockers eat real mouse events).
        local rowHoverTex = resultsFrame.scrollChild:CreateTexture(nil, "OVERLAY")
        rowHoverTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        rowHoverTex:SetBlendMode("ADD")
        rowHoverTex:SetVertexColor(1, 1, 1, 0.6)
        rowHoverTex:Hide()
        local hoveredResultRow
        -- Separate hover overlay for the filter dropdown (its CheckButton
        -- rows don't have a highlight texture set).
        local dropdownHoverTex
        local function getDropdownHoverTex()
            if not dropdownHoverTex then
                local dd = searchFrame.filterDropdown
                if not dd then return nil end
                dropdownHoverTex = dd:CreateTexture(nil, "OVERLAY")
                dropdownHoverTex:SetColorTexture(1, 1, 1, 0.1)
                dropdownHoverTex:Hide()
            end
            return dropdownHoverTex
        end

        setHoveredRow = function(row)
            if row == hoveredResultRow then return end
            -- Fire OnLeave on the departing map result row so the map
            -- preview clears at the exact same frame as the highlight.
            local prev = hoveredResultRow
            if prev then
                if prev.UnlockHighlight then
                    prev:UnlockHighlight()
                end
                if prev._demoMapHover then
                    prev._demoMapHover = nil
                    if ns.MapSearch then ns.MapSearch._demoHoverLock = nil end
                    local onLeave = prev:GetScript("OnLeave")
                    if onLeave then pcall(onLeave, prev) end
                end
            end
            hoveredResultRow = row
            rowHoverTex:Hide()
            local ddTex = getDropdownHoverTex()
            if ddTex then ddTex:Hide() end
            if row then
                if row.GetHighlightTexture and row:GetHighlightTexture() then
                    row:LockHighlight()
                elseif row._isDropdownRow then
                    if ddTex then
                        ddTex:ClearAllPoints()
                        ddTex:SetAllPoints(row)
                        ddTex:Show()
                    end
                else
                    rowHoverTex:ClearAllPoints()
                    rowHoverTex:SetAllPoints(row)
                    rowHoverTex:Show()
                end
                -- Fire OnEnter on map result rows so the map preview
                -- appears at the exact same frame as the highlight.
                if row._demoMapHover then
                    if ns.MapSearch then ns.MapSearch._demoHoverLock = true end
                    local onEnter = row:GetScript("OnEnter")
                    if onEnter then pcall(onEnter, row) end
                end
            end
        end

        -- Check if cursor is over any result row (UI search OR map search).
        local function updateResultRowHover()
            if not cursor:IsShown() then
                setHoveredRow(nil)
                return
            end
            local cl = cursor:GetLeft()
            local ct = cursor:GetTop()
            if not cl then setHoveredRow(nil); return end
            local cx, cy = cl + 4, ct - 4
            -- Pin popup
            local pinPop = _G["EasyFindPinPopup"]
            if pinPop and pinPop:IsShown() then
                local rl, rr, rt, rb = pinPop:GetLeft(), pinPop:GetRight(), pinPop:GetTop(), pinPop:GetBottom()
                if rl and cx >= rl and cx <= rr and cy <= rt and cy >= rb then
                    setHoveredRow(pinPop)
                    return
                end
            end
            -- UI search results
            if resultsFrame:IsShown() then
                for i = 1, #resultButtons do
                    local row = resultButtons[i]
                    if row and row:IsShown() then
                        local rl, rr, rt, rb = row:GetLeft(), row:GetRight(), row:GetTop(), row:GetBottom()
                        if rl and cx >= rl and cx <= rr and cy <= rt and cy >= rb then
                            setHoveredRow(row)
                            return
                        end
                    end
                end
            end
            -- Filter dropdown rows (dropdown has custom scaling, so
            -- convert the cursor tip to the dropdown's coordinate space)
            local dd = searchFrame.filterDropdown
            if dd and dd:IsShown() and dd.checkRows then
                local ds = dd:GetEffectiveScale()
                local cs = cursor:GetEffectiveScale()
                local dcx = cx * cs / ds
                local dcy = cy * cs / ds
                for _, row in pairs(dd.checkRows) do
                    if row and row:IsShown() then
                        local rl, rr, rt, rb = row:GetLeft(), row:GetRight(), row:GetTop(), row:GetBottom()
                        if rl and dcx >= rl and dcx <= rr and dcy <= rt and dcy >= rb then
                            row._isDropdownRow = true
                            setHoveredRow(row)
                            return
                        end
                    end
                end
            end
            -- Map search results
            local mapResults = _G["EasyFindMapResultsFrame"]
            if mapResults and mapResults:IsShown() then
                for i = 1, 20 do
                    local row = _G["EasyFindMapResultButton" .. i]
                    if row and row:IsShown() and row.data then
                        local rl, rr, rt, rb = row:GetLeft(), row:GetRight(), row:GetTop(), row:GetBottom()
                        if rl and cx >= rl and cx <= rr and cy <= rt and cy >= rb then
                            setHoveredRow(row)
                            return
                        end
                    end
                end
            end
            setHoveredRow(nil)
        end

        local function placeCursorAt(x, y)
            cursor:ClearAllPoints()
            cursor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x - 4, y + 4)
            updateResultRowHover()
        end

        clearButtonHover = function()
            GameTooltip_Hide()
        end

        local function moveCursorTo(targetFrame, duration, onArrive, offsetX, offsetY)
            -- Previous target's hover state (tooltip, button outline,
            -- highlight) is cleared below once the cursor has visibly
            -- moved off it, not at the start. Clearing at the start
            -- would make the tooltip dismiss while the cursor is still
            -- sitting on the button it's about to leave.
            local isTutorialBox = targetFrame and targetFrame._isTutorialBox
            local tx, ty = centerInUIParent(targetFrame)
            if not tx then
                if onArrive then onArrive() end
                return
            end
            -- Default landing placements (skipped if caller passed explicit
            -- offsets). Two cases:
            --   * Tutorial boxes: tip at the bottom-border center, sprite
            --     extends below the frame so it never covers the text.
            --   * Small icon buttons (<=50x50 Button): tip in the lower-
            --     right quadrant so the icon below stays visible.
            if not offsetX and not offsetY then
                if isTutorialBox then
                    local bottom = targetFrame:GetBottom()
                    if bottom then
                        ty = bottom - 4
                    end
                elseif targetFrame.IsObjectType and targetFrame:IsObjectType("Button") then
                    local w = targetFrame:GetWidth() or 0
                    local h = targetFrame:GetHeight() or 0
                    if w > 0 and h > 0 and w <= 50 and h <= 50 then
                        offsetX = w * 0.3
                        offsetY = -h * 0.3
                    end
                end
            end
            if offsetX then tx = tx + offsetX end
            if offsetY then ty = ty + offsetY end
            -- If the cursor isn't visible yet, start it at the middle
            -- right of the screen so the first move comes in from a
            -- natural resting position.
            if not cursor:IsShown() then
                local sx = UIParent:GetWidth() * 0.72
                local sy = UIParent:GetHeight() * 0.5
                placeCursorAt(sx, sy)
                cursor:Show()
            end
            local sx = cursor:GetLeft() + 4
            local sy = cursor:GetTop() - 4
            local elapsed = 0
            local myGen = stepGen
            local hoverCleared = false
            cursor:SetScript("OnUpdate", function(self, dt)
                if not active or myGen ~= stepGen then
                    self:SetScript("OnUpdate", nil)
                    return
                end
                if paused then return end
                elapsed = elapsed + dt * playbackSpeed
                local t = elapsed / duration
                if t >= 1 then t = 1 end
                local eased = t * t * (3 - 2 * t)  -- smoothstep
                local nx = sx + (tx - sx) * eased
                local ny = sy + (ty - sy) * eased
                -- Release the previous target's tooltip/highlight once
                -- the cursor has traveled ~20 px from the start — far
                -- enough to be clearly off a small icon button. This
                -- lets the tooltip linger while the cursor is still
                -- visibly on the button it just left.
                if not hoverCleared then
                    local dx, dy = nx - sx, ny - sy
                    if dx * dx + dy * dy >= 400 then
                        hoverCleared = true
                        clearButtonHover()
                    end
                end
                placeCursorAt(nx, ny)
                if t >= 1 then
                    self:SetScript("OnUpdate", nil)
                    -- For a tutorial box, re-anchor the cursor's TOPLEFT
                    -- to the frame's BOTTOM so it follows if the box
                    -- resizes later (e.g. SetText grows the height for
                    -- a longer message). The -4/0 offset puts the tip
                    -- at bottom-center with no overlap into the frame.
                    if isTutorialBox and not offsetX and not offsetY then
                        cursor:ClearAllPoints()
                        cursor:SetPoint("TOPLEFT", targetFrame, "BOTTOM", -4, 0)
                    end
                    if onArrive then pcall(onArrive) end
                end
            end)
        end

        local function clickAnim(onComplete)
            -- Quick scale pulse: shrink ~30% then back. ~0.18s total.
            local startSize = cursor:GetWidth() or 36
            local minSize = startSize * 0.7
            local elapsed = 0
            local myGen = stepGen
            cursor:SetScript("OnUpdate", function(self, dt)
                if not active or myGen ~= stepGen then
                    self:SetScript("OnUpdate", nil)
                    self:SetSize(36, 36)
                    return
                end
                if paused then return end
                elapsed = elapsed + dt * playbackSpeed
                local total = 0.18
                local half = total / 2
                local sz
                if elapsed < half then
                    sz = startSize + (minSize - startSize) * (elapsed / half)
                else
                    sz = minSize + (startSize - minSize) * ((elapsed - half) / half)
                end
                self:SetSize(sz, sz)
                if elapsed >= total then
                    self:SetSize(startSize, startSize)
                    self:SetScript("OnUpdate", nil)
                    if onComplete then
                        local ok, err = pcall(onComplete)
                        if not ok and err then
                            local handler = geterrorhandler()
                            if handler then handler(err) end
                        end
                    end
                end
            end)
        end

        -- Fake blinking cursor: mimics the "just focused the editbox"
        -- visual (placeholder hidden + blinking vertical bar) without
        -- actually giving the real editbox keyboard focus.
        local blinkCursor = searchFrame.editBox:CreateTexture(nil, "OVERLAY")
        blinkCursor:SetTexture("Interface\\Buttons\\WHITE8x8")
        blinkCursor:SetVertexColor(1, 1, 1, 1)
        blinkCursor:SetWidth(1)
        blinkCursor:SetPoint("LEFT", searchFrame.editBox, "LEFT", 2, 0)
        blinkCursor:SetPoint("TOP", searchFrame.editBox, "TOP", 0, -3)
        blinkCursor:SetPoint("BOTTOM", searchFrame.editBox, "BOTTOM", 0, 3)
        blinkCursor:Hide()
        local blinkTicker
        local function startBlinkCursor()
            searchFrame.editBox.placeholder:Hide()
            blinkCursor:Show()
            blinkCursor:SetAlpha(1)
            local visible = true
            if blinkTicker then blinkTicker:Cancel() end
            blinkTicker = C_Timer.NewTicker(0.5, function()
                visible = not visible
                blinkCursor:SetAlpha(visible and 1 or 0)
            end)
        end
        -- Assign (don't 'local') so the forward-declared stopBlinkCursor
        -- captured by endDemo() resolves to this function.
        stopBlinkCursor = function()
            if blinkTicker then blinkTicker:Cancel(); blinkTicker = nil end
            blinkCursor:Hide()
        end

        local function typeText(text, charDelay, onComplete)
            -- Set text programmatically via SetText (no SetFocus call) so
            -- the editbox visually shows the typed characters and the
            -- search runs via OnTextChanged, but the player can't actually
            -- type into it mid-demo.
            stopBlinkCursor()  -- typed text replaces the blink cursor
            local editBox = searchFrame.editBox
            editBox:SetText("")
            local i = 0
            local myGen = stepGen
            local function nextChar()
                if not active or myGen ~= stepGen then return end
                i = i + 1
                if i > #text then
                    if onComplete then onComplete() end
                    return
                end
                editBox:SetText(text:sub(1, i))
                UI:OnSearchTextChanged(editBox:GetText())
                safeAfter(charDelay, nextChar)
            end
            nextChar()
        end

        -- Find a specific result row by entry name (e.g. "Spellbook") so
        -- the demo clicks the right one instead of whatever fuzzy search
        -- put at the top.
        local function findResultRowByName(name)
            for i = 1, #resultButtons do
                local row = resultButtons[i]
                if row and row:IsShown() and row.data and row.data.name == name then
                    return row
                end
            end
            return nil
        end

        local function findFirstResultRow()
            for i = 1, #resultButtons do
                local row = resultButtons[i]
                if row and row:IsShown() and row.data
                   and not row.data.isPinHeader and not row.data.isHeader then
                    return row
                end
            end
            return nil
        end

        -- Find the first visible result that's a map-search result
        -- (mapSearchResult = true). Used by the Map-search-through-UI-bar
        -- demo where the target is a flight master POI whose name is
        -- "<NPC> (Flight Master)" so findResultRowByName can't match
        -- exactly.
        local function findFirstMapSearchResult()
            for i = 1, #resultButtons do
                local row = resultButtons[i]
                if row and row:IsShown() and row.data and row.data.mapSearchResult
                   and not row.data.isPinHeader and not row.data.isHeader then
                    return row
                end
            end
            return nil
        end

        --------------------------------------------------------------------
        -- Step array: each step is a function(done) that runs its
        -- animation and calls done() when finished. The state machine
        -- below chains them either automatically (Play All) or waits for
        -- the player to click Next Step between each one.
        --------------------------------------------------------------------
        local CURSOR_MOVE         = 0.8    -- cursor travel time per move
        local TYPE_DELAY          = 0.3    -- per character (human-paced)
        local STEP_PAUSE          = 0.2    -- tiny pause at the end of "filler" steps
        local SETTLE_PAUSE        = 0.8    -- post-click "see what happened" pause for action steps
        -- Gaps framing every autoplay step.
        --   PRE_ACT_GAP: after a step highlights (and scrolls into
        --     view), wait this long before firing the action. This is
        --     the "reading time" so the user can absorb the step label
        --     before the cursor starts moving.
        --   POST_ACT_GAP: after a step's action finishes, keep the
        --     step highlighted this long so the result sinks in
        --     before the highlight advances.
        --   Section-boundary header beats also use POST_ACT_GAP.
        local PRE_ACT_GAP         = 0.7
        local POST_ACT_GAP        = 0.4

        -- Reset PlayerSpellsFrame to its default tab (Specialization) so
        -- the demo always starts from a clean state.
        local function resetPlayerSpellsFrame()
            local frame = _G["PlayerSpellsFrame"]
            if not frame then return end
            if frame.TabSystem and frame.TabSystem.tabs and frame.TabSystem.tabs[1] then
                local tab = frame.TabSystem.tabs[1]
                if tab.Click then pcall(tab.Click, tab) end
            else
                local fallback = _G["PlayerSpellsFrameTab1"]
                if fallback and fallback.Click then pcall(fallback.Click, fallback) end
            end
            if not InCombatLockdown() and frame.IsShown and frame:IsShown() then
                pcall(HideUIPanel, frame)
            end
        end

        -- Focuses the UI search bar with cursor animation + blink
        -- cursor, then types the query. Owns the full "search for X"
        -- action so there's no standalone focus step.
        local function uis_stepFocusAndType(query, done)
            moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    startBlinkCursor()
                    safeAfter(STEP_PAUSE, function()
                        typeText(query, TYPE_DELAY, function()
                            safeAfter(STEP_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        DEMOS.uiSearch.run = {
            -- 1: Start typing "sp" (cursor flies to the bar, focuses
            -- it, then types — all in this single step).
            function(done)
                uis_stepFocusAndType("sp", done)
            end,
            -- 2: Click the Spellbook result, let PlayerSpellsFrame
            -- open, then clean up.
            function(done)
                local target = findResultRowByName("Spellbook") or findFirstResultRow() or searchFrame.editBox
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        UI:SelectResult(spellbookEntry)
                        safeAfter(1.5, function()
                            local psf = _G["PlayerSpellsFrame"]
                            local closeBtn = psf and (psf.ClosePanelButton or psf.CloseButton)
                            local function cleanup()
                                setHoveredRow(nil)
                                stopBlinkCursor()
                                searchFrame.editBox:SetText("")
                                UI:OnSearchTextChanged("")
                                if ns.Highlight and ns.Highlight.ClearAll then
                                    pcall(ns.Highlight.ClearAll, ns.Highlight)
                                end
                                resetPlayerSpellsFrame()
                                safeAfter(0.5, function()
                                    cursor:Hide()
                                    done()
                                end)
                            end
                            if closeBtn and closeBtn:IsShown() then
                                moveCursorTo(closeBtn, CURSOR_MOVE, function()
                                    clickAnim(cleanup)
                                end)
                            else
                                cleanup()
                            end
                        end)
                    end)
                end)
            end,
        }
        demoSteps = DEMOS.uiSearch.run

        --------------------------------------------------------------------
        -- Guide Mode demo: right-click a result, pick Guide from the
        -- popup, and let the step-by-step highlight guide play.
        --------------------------------------------------------------------
        local function guide_cleanup(done)
            setHoveredRow(nil)
            stopBlinkCursor()
            searchFrame.editBox:SetText("")
            UI:OnSearchTextChanged("")
            if searchFrame.editBox.placeholder then
                searchFrame.editBox.placeholder:Show()
            end
            if ns.Highlight and ns.Highlight.ClearAll then
                pcall(ns.Highlight.ClearAll, ns.Highlight)
            end
            if not InCombatLockdown() then
                local cf = _G["CharacterFrame"]
                if cf and cf.IsShown and cf:IsShown() then
                    pcall(HideUIPanel, cf)
                end
                local tf = _G["TokenFrame"]
                if tf and tf.IsShown and tf:IsShown() then
                    pcall(HideUIPanel, tf)
                end
            end
            safeAfter(0.4, function()
                cursor:Hide()
                rightClickIcon:Hide()
                done()
            end)
        end

        DEMOS.guide.run = {
            -- 1: Type "Valorstones"
            function(done)
                uis_stepFocusAndType("Valorstones", done)
            end,
            -- 2: Move to the Valorstones result row and right-click,
            -- which triggers ShowPinPopup with the Guide row.
            function(done)
                local target = findResultRowByName("Valorstones") or findFirstResultRow()
                if not target then
                    guide_cleanup(done)
                    return
                end
                moveCursorTo(target, CURSOR_MOVE, function()
                    rightClickIcon:Show()
                    safeAfter(0.5, function()
                        clickAnim(function()
                            rightClickIcon:Hide()
                            local onClick = target:GetScript("OnClick")
                            if onClick then
                                pcall(onClick, target, "RightButton", true)
                            end
                            safeAfter(SETTLE_PAUSE, done)
                        end)
                    end)
                end)
            end,
            -- 3: Click the Guide row in the pin popup. SelectResult
            -- with forceGuide=true routes a currency entry through
            -- EasyFind:StartGuide.
            function(done)
                local popup = _G["EasyFindPinPopup"]
                local guideRow = popup and popup.guideRow
                if not (popup and popup:IsShown() and guideRow and guideRow:IsShown()) then
                    local target = findResultRowByName("Valorstones") or findFirstResultRow()
                    if target and target.data then
                        UI:SelectResult(target.data, true)
                    end
                    safeAfter(SETTLE_PAUSE, done)
                    return
                end
                moveCursorTo(guideRow, CURSOR_MOVE, function()
                    clickAnim(function()
                        local onClick = guideRow:GetScript("OnClick")
                        if onClick then
                            pcall(onClick, guideRow)
                        end
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end,
            -- 4: Let the highlight ticker run so the user sees the
            -- step-by-step guide, then clean up.
            function(done)
                safeAfter(4.0, function()
                    guide_cleanup(done)
                end)
            end,
        }
        DEMOS.guide.setupAfter = {
            function() end,
            function() end,
            function() end,
            function()
                if ns.Highlight and ns.Highlight.ClearAll then
                    pcall(ns.Highlight.ClearAll, ns.Highlight)
                end
            end,
        }

        --------------------------------------------------------------------
        -- Zone/Instance Map Search demo
        --------------------------------------------------------------------

        -- Blinking text caret for map search editboxes. A hidden
        -- FontString mirrors the editbox font to measure text width.
        local mapCaret = CreateFrame("Frame", nil, UIParent)
        mapCaret:SetFrameStrata("TOOLTIP")
        mapCaret:SetFrameLevel(10002)
        mapCaret:SetSize(1, 1)
        mapCaret:Hide()
        local mapCaretTex = mapCaret:CreateTexture(nil, "OVERLAY")
        mapCaretTex:SetTexture("Interface\\Buttons\\WHITE8x8")
        mapCaretTex:SetVertexColor(1, 1, 1, 1)
        mapCaretTex:SetWidth(1)
        mapCaretTex:SetAllPoints()
        local mapCaretMeasure = mapCaret:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        mapCaretMeasure:Hide()
        local mapCaretTicker
        local mapCaretLastEditBox

        local function positionMapCaret(editBox)
            mapCaret:ClearAllPoints()
            local text = editBox:GetText() or ""
            local inL = editBox:GetTextInsets()
            local xOff = inL or 2
            if #text > 0 then
                if editBox ~= mapCaretLastEditBox then
                    local ok, fontPath, fontSize, fontFlags = pcall(editBox.GetFont, editBox)
                    if ok and fontPath and fontSize and fontSize > 0 then
                        pcall(mapCaretMeasure.SetFont, mapCaretMeasure, fontPath, fontSize, fontFlags)
                    end
                    mapCaretLastEditBox = editBox
                end
                mapCaretMeasure:SetText(text)
                xOff = xOff + (mapCaretMeasure:GetStringWidth() or 0)
            end
            mapCaret:SetPoint("LEFT", editBox, "LEFT", xOff, 0)
            mapCaret:SetPoint("TOP", editBox, "TOP", 0, -2)
            mapCaret:SetPoint("BOTTOM", editBox, "BOTTOM", 0, 2)
        end

        local function showMapCaret(editBox)
            positionMapCaret(editBox)
            mapCaret:Show()
            mapCaretTex:SetAlpha(1)
            if mapCaretTicker then mapCaretTicker:Cancel() end
            local vis = true
            mapCaretTicker = C_Timer.NewTicker(0.5, function()
                vis = not vis
                mapCaretTex:SetAlpha(vis and 1 or 0)
            end)
        end
        hideMapCaret = function()
            if mapCaretTicker then mapCaretTicker:Cancel(); mapCaretTicker = nil end
            mapCaret:Hide()
        end
        local function repositionMapCaret(editBox)
            positionMapCaret(editBox)
            mapCaretTex:SetAlpha(1)
        end

        -- Simulate refocusing then backspacing the current editbox text
        -- one character at a time. Shows a blinking caret at the end of
        -- the text for a beat, then deletes character by character.
        local function backspaceMapText(editBox, charDelay, onComplete)
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local isGlobal = gsf and gsf.editBox == editBox
            local runFn
            if isGlobal and ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                runFn = function(t) ns.MapSearch:RunGlobalSearch(t) end
            elseif ns.MapSearch and ns.MapSearch.RunLocalSearch then
                runFn = function(t) ns.MapSearch:RunLocalSearch(t) end
            else
                runFn = function(t) editBox:SetText(t) end
            end
            local cur = editBox:GetText() or ""
            local len = #cur
            if len == 0 then
                if onComplete then onComplete() end
                return
            end
            showMapCaret(editBox)
            safeAfter(0.6, function()
                local myGen = stepGen
                local function nextDel()
                    if not active or myGen ~= stepGen then return end
                    len = len - 1
                    if len <= 0 then
                        runFn("")
                        repositionMapCaret(editBox)
                        safeAfter(0.4, function()
                            hideMapCaret()
                            if onComplete then onComplete() end
                        end)
                        return
                    end
                    runFn(cur:sub(1, len))
                    repositionMapCaret(editBox)
                    safeAfter(charDelay, nextDel)
                end
                nextDel()
            end)
        end

        -- Variant that leaves the caret visible after the last deletion
        -- so the caret persists across backspace→type transitions (matching
        -- real editbox behavior where focus isn't lost between edits).
        local function backspaceMapTextKeepCaret(editBox, charDelay, onComplete)
            local cur = editBox:GetText() or ""
            if #cur == 0 then
                showMapCaret(editBox)
                if onComplete then onComplete() end
                return
            end
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local isGlobal = gsf and gsf.editBox == editBox
            local runFn
            if isGlobal and ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                runFn = function(t) ns.MapSearch:RunGlobalSearch(t) end
            elseif ns.MapSearch and ns.MapSearch.RunLocalSearch then
                runFn = function(t) ns.MapSearch:RunLocalSearch(t) end
            else
                runFn = function(t) editBox:SetText(t) end
            end
            local len = #cur
            showMapCaret(editBox)
            safeAfter(0.6, function()
                local myGen = stepGen
                local function nextDel()
                    if not active or myGen ~= stepGen then return end
                    len = len - 1
                    if len <= 0 then
                        runFn("")
                        repositionMapCaret(editBox)
                        safeAfter(0.4, function()
                            if onComplete then onComplete() end
                        end)
                        return
                    end
                    runFn(cur:sub(1, len))
                    repositionMapCaret(editBox)
                    safeAfter(charDelay, nextDel)
                end
                nextDel()
            end)
        end

        local function typeMapText(editBox, text, charDelay, onComplete)
            -- NEVER focus the real editbox: if it had keyboard focus,
            -- the real user could type into it alongside the demo.
            -- Instead, drive the MapSearch engine directly so results
            -- appear and update as if typed. Detect which bar the
            -- caller passed so we route to the right scope.
            editBox:ClearFocus()
            if editBox.placeholder then editBox.placeholder:Hide() end
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local isGlobal = gsf and gsf.editBox == editBox
            local runFn
            if isGlobal and ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                runFn = function(t) ns.MapSearch:RunGlobalSearch(t) end
            elseif ns.MapSearch and ns.MapSearch.RunLocalSearch then
                runFn = function(t) ns.MapSearch:RunLocalSearch(t) end
            else
                runFn = function(t) editBox:SetText(t) end
            end
            runFn("")
            showMapCaret(editBox)
            local i = 0
            local myGen = stepGen
            local function nextChar()
                if not active or myGen ~= stepGen then return end
                i = i + 1
                if i > #text then
                    hideMapCaret()
                    if onComplete then onComplete() end
                    return
                end
                runFn(text:sub(1, i))
                repositionMapCaret(editBox)
                safeAfter(charDelay, nextChar)
            end
            nextChar()
        end

        -- Variant that re-shows the caret after typing finishes, matching
        -- real editbox behavior where the caret persists until the user
        -- clicks away. Used in browse flows where backspace→type cycles
        -- repeat without defocusing.
        local function typeMapTextKeepCaret(editBox, text, charDelay, onComplete)
            typeMapText(editBox, text, charDelay, function()
                showMapCaret(editBox)
                if onComplete then onComplete() end
            end)
        end

        -- Find a map search result button by partial name match.
        local function findMapResultByName(pattern)
            for i = 1, 20 do
                local btn = _G["EasyFindMapResultButton" .. i]
                if btn and btn:IsShown() and btn.data and btn.data.name then
                    if sfind(slower(btn.data.name), slower(pattern)) then
                        return btn
                    end
                end
            end
            return nil
        end

        -- Find the first visible map result (skipping any header rows).
        local function findFirstVisibleMapResult()
            for i = 1, 20 do
                local btn = _G["EasyFindMapResultButton" .. i]
                if btn and btn:IsShown() and btn.data and btn.data.name
                   and not btn.data.isHeader then
                    return btn
                end
            end
            return nil
        end

        -- Open the world map, loading the addon if needed.
        local function openWorldMap()
            if C_AddOns and C_AddOns.LoadAddOn then
                pcall(C_AddOns.LoadAddOn, "Blizzard_WorldMap")
            end
            -- Lazy-capture the pre-demo WMF mapID: if WMF wasn't loaded
            -- at Demo.Start, this is the first moment it exists with a
            -- valid mapID, and we need that value to restore on demo
            -- switch / panel close. Capture BEFORE ToggleWorldMap since
            -- opening the map may trigger a SetMapID of its own.
            if savedWmfMapID == nil and WorldMapFrame and WorldMapFrame.GetMapID then
                savedWmfMapID = WorldMapFrame:GetMapID()
            end
            if not WorldMapFrame or not WorldMapFrame:IsShown() then
                pcall(ToggleWorldMap)
            end
        end

        closeWorldMap = function()
            if not InCombatLockdown() and WorldMapFrame and WorldMapFrame:IsShown() then
                pcall(HideUIPanel, WorldMapFrame)
            end
        end

        local function getMapCloseBtn()
            local wmf = WorldMapFrame
            if not wmf then return nil end
            return wmf.CloseButton
                or (wmf.BorderFrame and wmf.BorderFrame.CloseButton)
                or nil
        end

        -- Helper: clean up map search state (clear editboxes, focus,
        -- results, pins, zone highlight, activePinState, waypoint).
        -- Both local and global search bars so nothing bleeds across
        -- demos or rewinds. Uses MapSearch:ClearAll which nulls out
        -- activePinState (otherwise WorldMapFrame's OnShow hook would
        -- restore a stale pin the next time the map opens).
        resetMapSearchState = function()
            hideMapCaret()
            local lsf = _G["EasyFindMapSearchFrame"]
            if lsf and lsf.editBox then
                lsf.editBox:SetText("")
                lsf.editBox:ClearFocus()
                if lsf.editBox.placeholder then lsf.editBox.placeholder:Show() end
            end
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            if gsf and gsf.editBox then
                gsf.editBox:SetText("")
                gsf.editBox:ClearFocus()
                if gsf.editBox.placeholder then gsf.editBox.placeholder:Show() end
            end
            if ns.MapSearch then
                if ns.MapSearch.HideResults then pcall(ns.MapSearch.HideResults, ns.MapSearch) end
                if ns.MapSearch.ClearAll then pcall(ns.MapSearch.ClearAll, ns.MapSearch) end
                if ns.MapSearch.ClearZoneHighlight then pcall(ns.MapSearch.ClearZoneHighlight, ns.MapSearch) end
            end
        end

        -- Hover over the waypoint pin to show "found it". When the
        -- cursor arrives, call ClearHighlight (same as real OnEnter for
        -- global search pins) which hides the pin, glow, and indicator
        -- arrow — exactly matching what happens when a real user hovers.
        local function hoverWaypointPin(afterHover)
            local pin = _G["EasyFindLocationPin"]
            if pin and pin:IsShown() then
                moveCursorTo(pin, CURSOR_MOVE, function()
                    if ns.MapSearch and ns.MapSearch.ClearHighlight then
                        pcall(ns.MapSearch.ClearHighlight, ns.MapSearch)
                    end
                    safeAfter(SETTLE_PAUSE + 1.0, afterHover)
                end)
            else
                safeAfter(SETTLE_PAUSE, afterHover)
            end
        end

        -- Click-animates the cursor onto the global map search bar,
        -- then types the query via typeMapText. Owns the full "start
        -- typing" action so there's no standalone focus step.
        -- All Zone/Instance map search step helpers live on a single
        -- table so they only consume one local in this huge function.
        local msz = {}

        function msz.stepFocusAndType(query, done)
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local editBox = gsf and gsf.editBox
            if not editBox then done(); return end
            moveCursorTo(editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    safeAfter(STEP_PAUSE, function()
                        typeMapText(editBox, query, TYPE_DELAY, function()
                            safeAfter(SETTLE_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        function msz.openMap(done)
            if InCombatLockdown() then done(); return end
            openWorldMap()
            safeAfter(0.8, done)
        end

        function msz.clickNexus(done)
            local target = findMapResultByName("The Nexus")
                or _G["EasyFindMapResultButton1"]
            if not target or not target:IsShown() then done(); return end
            moveCursorTo(target, CURSOR_MOVE, function()
                hideMapCaret()
                clickAnim(function()
                    if target.data and ns.MapSearch then
                        pcall(ns.MapSearch.SelectResult, ns.MapSearch, target.data)
                    end
                    safeAfter(SETTLE_PAUSE, done)
                end)
            end)
        end

        function msz.finish(done)
            hoverWaypointPin(function()
                local closeBtn = getMapCloseBtn()
                if closeBtn and closeBtn:IsShown() then
                    moveCursorTo(closeBtn, CURSOR_MOVE, function()
                        clickAnim(function()
                            resetMapSearchState()
                            closeWorldMap()
                            safeAfter(0.5, function()
                                cursor:Hide()
                                done()
                            end)
                        end)
                    end)
                else
                    resetMapSearchState()
                    closeWorldMap()
                    safeAfter(0.5, function()
                        cursor:Hide()
                        done()
                    end)
                end
            end)
        end

        DEMOS.mapSearchZone.rebuild = function(def)
            def.stepDefs = {
                { text = "Open the world map",            section = 1 },
                { text = 'Start typing "The Nexus"',      section = 1 },
                { text = "Click The Nexus result",        section = 1 },
                { text = "Hover over to clear highlight", section = 1 },
            }
            def.sections = {
                { header = "", section = 1, firstStep = 1, lastStep = 4 },
            }
            def.run = {
                msz.openMap,
                function(done) msz.stepFocusAndType("nex", done) end,
                msz.clickNexus,
                msz.finish,
            }
            def.setupAfter = {
                function() openWorldMap() end,
                function()
                    openWorldMap()
                    if ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                        pcall(ns.MapSearch.RunGlobalSearch, ns.MapSearch, "nex")
                    end
                end,
                function() openWorldMap() end,
                function() resetMapSearchState(); closeWorldMap() end,
            }
        end

        --------------------------------------------------------------------
        -- Current Zone Map Search demo
        --------------------------------------------------------------------

        -- Open the map and set it to the player's current zone. If the
        -- player's zone is unsuitable (cosmic map, dungeon, raid, nil),
        -- returns false so the caller can bail out gracefully.
        local function openWorldMapToPlayerZone()
            openWorldMap()
            local getBest = _G["GetBestMapForUnit"]
            local playerMapID = getBest and getBest("player")
            if not playerMapID then return false end
            if WorldMapFrame then
                pcall(WorldMapFrame.SetMapID, WorldMapFrame, playerMapID)
            end
            return true
        end

        -- Click the waypoint pin to place a SuperTrack user waypoint.
        -- This triggers the real minimap glow / guide-circle behavior.
        -- Uses MapSearch helpers that resolve the pin location whether
        -- it was rendered via the overlay (ShowWaypointAt) or by scaling
        -- up a native Blizzard pin (HighlightPin).
        local function clickPinAndTrack(afterTrack)
            local targetFrame = ns.MapSearch and ns.MapSearch.GetActivePinFrame
                and ns.MapSearch:GetActivePinFrame()
            if not targetFrame then
                safeAfter(SETTLE_PAUSE, afterTrack)
                return
            end
            moveCursorTo(targetFrame, CURSOR_MOVE, function()
                clickAnim(function()
                    if ns.MapSearch and ns.MapSearch.TrackActiveLocation then
                        pcall(ns.MapSearch.TrackActiveLocation, ns.MapSearch)
                    end
                    -- Short settle so the glow renders before the
                    -- caller's minimap-hint cursor walk kicks in.
                    safeAfter(SETTLE_PAUSE, afterTrack)
                end)
            end)
        end

        -- Clear any waypoint the demo placed, so it doesn't linger.
        local function clearDemoWaypoint()
            if C_Map and C_Map.ClearUserWaypoint then
                pcall(C_Map.ClearUserWaypoint)
            end
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
            end
        end

        -- Tutorial chevron pointer attached to the minimap callout box,
        -- animating rightward into the minimap. Gap between the box's
        -- right edge and the minimap's left edge (set on the callout's
        -- SetPoint above) is sized so the chevron's full visible sweep
        -- (~27 px shape + 36 px travel) lands the apex just shy of the
        -- minimap edge at peak travel, without intruding.
        -- Cadence copied from modePointer (canonical recipe).
        local minimapChevron = ns.TutorialBox.AttachPointer(minimapCalloutFrame, {
            direction   = "right",
            travel      = 36,
            duration    = 1.25,
            count       = 2,
            easing      = 0.5,
            fadeStart   = 0.75,
            startOffset = -10,
            glow        = 0.7,
        })
        minimapChevron.frame:Hide()

        -- Attach real methods to the forward-declared minimapArrow table
        -- so upvalues in endDemo / cancelInFlight / resetDemoGameState
        -- see the live implementation. The old bouncing indicator
        -- texture was replaced with chevrons attached to the callout
        -- box, so Show/Hide now just toggle the chevron driver frame's
        -- visibility (OnUpdate pauses automatically while hidden).
        function minimapArrow:Show()
            minimapChevron.frame:Show()
        end
        function minimapArrow:Hide()
            minimapChevron.frame:Hide()
        end
        function minimapArrow:SetPaused(_)
            -- No-op: chevron OnUpdate is bound to parent visibility, and
            -- the callout itself stays shown during a pause, so the
            -- chevron keeps cycling. Acceptable tradeoff for how rarely
            -- users pause mid-callout.
        end

        -- Show the minimap callout text and a bouncing arrow pointing
        -- at the minimap. No cursor movement: the arrow does the
        -- pointing so the user knows where to look.
        local function showMinimapHint(onDone)
            minimapCallout:Show()
            minimapArrow:Show()
            safeAfter(3.0, function()
                if onDone then onDone() end
            end)
        end

        ----------------------------------------------------------------
        -- Current Zone Map Search: browse POIs around the player.
        -- All helpers live on a single table so this huge parent
        -- function only consumes one local for the whole bundle.
        ----------------------------------------------------------------
        local msc = {}

        function msc.openMap(done)
            if InCombatLockdown() then done(); return end
            local ok = openWorldMapToPlayerZone()
            if not ok then
                safeAfter(0.5, done)
                return
            end
            safeAfter(0.8, done)
        end

        function msc.retypeLastBrowse(done)
            local lsf = _G["EasyFindMapSearchFrame"]
            local editBox = lsf and lsf.editBox
            if not editBox then done(); return end
            local lastPOI = msc.lastBrowsePOI
            local query = lastPOI and slower(lastPOI.name):sub(1, 3) or "ban"
            moveCursorTo(editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    backspaceMapTextKeepCaret(editBox, TYPE_DELAY, function()
                        typeMapTextKeepCaret(editBox, query, TYPE_DELAY, function()
                            safeAfter(SETTLE_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        local function closeMapAndFinish(done)
            local closeBtn = getMapCloseBtn()
            if closeBtn and closeBtn:IsShown() then
                moveCursorTo(closeBtn, CURSOR_MOVE, function()
                    clickAnim(function()
                        clearDemoWaypoint()
                        resetMapSearchState()
                        closeWorldMap()
                        safeAfter(0.5, function()
                            cursor:Hide()
                            done()
                        end)
                    end)
                end)
            else
                clearDemoWaypoint()
                resetMapSearchState()
                closeWorldMap()
                safeAfter(0.5, function()
                    cursor:Hide()
                    done()
                end)
            end
        end

        function msc.finishHintAndClose(done)
            showMinimapHint(function()
                minimapCallout:Hide()
                minimapArrow:Hide()
                closeMapAndFinish(done)
            end)
        end

        -- Inline hint shown right after a result is clicked and the
        -- highlights activate: scroll mapSearchCallout's text from the
        -- "Now let's click this result" narration to a short sentence
        -- calling out the clear buttons, point a chevron at each, and
        -- fire the local button's real tooltip so the user sees what
        -- they do. No separate step in the demo list; runs between the
        -- click-animation settle and the minimap callout.
        function msc.clearBtnHint(done)
            local lsf = _G["EasyFindMapSearchFrame"]
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local localBtn  = lsf and lsf.clearBtn
            local globalBtn = gsf and gsf.clearBtn
            local haveLocal  = localBtn  and localBtn:IsShown()
            local haveGlobal = globalBtn and globalBtn:IsShown()
            if not haveLocal and not haveGlobal then
                done(); return
            end
            -- Hide the callout's own left-pointing chevron: the two
            -- clear-button chevrons below already point at their real
            -- targets, so a third arrow from the callout is noise.
            mapSearchCallout.arrow.frame:Hide()
            -- Two sequential messages. The first sets context; the
            -- second is the call-to-action that the chevrons + cursor
            -- tooltip will reinforce. Pre-measure the box size required
            -- for each, take the max, then tween the box to that size
            -- alongside the slide below. Staying at one size across
            -- both scrolls avoids a second resize mid-sequence.
            local hintContext = "Clear icons will be visible anytime a highlight is active."
            local hintAction  = "Click any to clear all highlights."
            local startW = mapSearchCallout.frame:GetWidth()
            local startH = mapSearchCallout.frame:GetHeight()
            local savedText = mapSearchCallout.fs:GetText() or ""
            mapSearchCallout.fs:SetText(hintContext)
            mapSearchCallout.frame:SetAutoSized(340)
            local wCtx = mapSearchCallout.frame:GetWidth()
            local hCtx = mapSearchCallout.frame:GetHeight()
            mapSearchCallout.fs:SetText(hintAction)
            mapSearchCallout.frame:SetAutoSized(340)
            local wAct = mapSearchCallout.frame:GetWidth()
            local hAct = mapSearchCallout.frame:GetHeight()
            local targetW = wCtx > wAct and wCtx or wAct
            local targetH = hCtx > hAct and hCtx or hAct
            mapSearchCallout.fs:SetText(savedText)
            mapSearchCallout.frame:SetSize(startW, startH)
            mapSearchCallout:SetTextScrolling(hintContext)
            -- Slide the callout from its anchored spot next to the
            -- results frame down and to the left, so it lands centered
            -- below the two map search bars. Tween position and size
            -- together so the box grows to fit the two-line text in
            -- sync with the slide.
            local startL = mapSearchCallout.frame:GetLeft()
            local startT = mapSearchCallout.frame:GetTop()
            local leftEdge  = lsf and lsf:GetLeft()
            local rightEdge = gsf and gsf:GetRight()
            local lsfBot = lsf and lsf:GetBottom()
            local gsfBot = gsf and gsf:GetBottom()
            if startL and startT and leftEdge and rightEdge and lsfBot and gsfBot then
                local targetL = (leftEdge + rightEdge) * 0.5 - targetW * 0.5
                local targetT = (lsfBot < gsfBot and lsfBot or gsfBot) - 28
                if not mapSearchCallout.moveAnim then
                    mapSearchCallout.moveAnim = CreateFrame("Frame")
                    mapSearchCallout.moveAnim:Hide()
                end
                local moveAnim = mapSearchCallout.moveAnim
                moveAnim:SetScript("OnUpdate", nil)
                local dur = 0.5
                local el = 0
                moveAnim:SetScript("OnUpdate", function(_, dt)
                    el = el + dt
                    local t = el / dur
                    if t > 1 then t = 1 end
                    local eased = t * t * (3 - 2 * t)
                    local nl = startL + (targetL - startL) * eased
                    local nt = startT + (targetT - startT) * eased
                    local nw = startW + (targetW - startW) * eased
                    local nh = startH + (targetH - startH) * eased
                    mapSearchCallout.frame:SetSize(nw, nh)
                    mapSearchCallout.frame:ClearAllPoints()
                    mapSearchCallout.frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", nl, nt)
                    if t >= 1 then
                        moveAnim:SetScript("OnUpdate", nil)
                        moveAnim:Hide()
                    end
                end)
                moveAnim:Show()
            end
            -- Chevron phase-1 apex lands ~63 px right of emitter.RIGHT
            -- (visible 27 + travel 36). Anchoring emitter.RIGHT to the
            -- button's LEFT with a -63 offset puts the apex right at
            -- the button's left edge at peak travel.
            local function showChevronAt(pointer, btn)
                if not btn then return end
                pointer.emitter:ClearAllPoints()
                pointer.emitter:SetPoint("RIGHT", btn, "LEFT", -63, 0)
                pointer.emitter:Show()
                pointer.chev.frame:Show()
            end
            local hoverBtn = haveLocal and localBtn or globalBtn
            -- Fires once the cursor has travelled to the clear button.
            -- Triggers the real OnEnter tooltip, waits, then runs the
            -- "Let's try it." -> click -> retype -> reclick sequence
            -- before handing off to done() for the minimap callout.
            local function clearHintOnArrive()
                local onEnter = hoverBtn:GetScript("OnEnter")
                if onEnter then pcall(onEnter, hoverBtn) end
                safeAfter(2.8, function()
                    GameTooltip_Hide()
                    localClearPointer.chev.frame:Hide()
                    localClearPointer.emitter:Hide()
                    globalClearPointer.chev.frame:Hide()
                    globalClearPointer.emitter:Hide()
                    mapSearchCallout:SetTextScrolling("Let's try it.")
                    safeAfter(2.0, function()
                        clickAnim(function()
                            local onClick = hoverBtn:GetScript("OnClick")
                            if onClick then
                                pcall(onClick, hoverBtn, "LeftButton", true)
                            end
                            safeAfter(0.9, function()
                                mapSearchCallout:SetTextScrolling("Now let's quickly get tracking again.")
                                safeAfter(1.8, function()
                                    -- Keep the callout visible through
                                    -- retype + cursor travel so the user
                                    -- reads the narration the whole way;
                                    -- hide it right at the click.
                                    msc.retypeLastBrowse(function()
                                        local lastPOI = msc.lastBrowsePOI
                                        local target = (lastPOI and findMapResultByName(lastPOI.name))
                                            or findFirstVisibleMapResult()
                                        if not target then
                                            mapSearchCallout:Hide()
                                            done(); return
                                        end
                                        moveCursorTo(target, CURSOR_MOVE, function()
                                            hideMapCaret()
                                            clickAnim(function()
                                                if target._demoMapHover then target._demoMapHover = nil end
                                                setHoveredRow(nil)
                                                mapSearchCallout:Hide()
                                                if target.data and ns.MapSearch then
                                                    pcall(ns.MapSearch.SelectResult, ns.MapSearch, target.data)
                                                end
                                                safeAfter(SETTLE_PAUSE, done)
                                            end)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end
            -- Chevrons show immediately so the callout text and the
            -- buttons it refers to are pointed at from the first
            -- word. Cursor travel + tooltip wait until the text rolls
            -- to the action sentence so the visual call-to-action
            -- aligns with the imperative.
            if haveLocal  then showChevronAt(localClearPointer,  localBtn)  end
            if haveGlobal then showChevronAt(globalClearPointer, globalBtn) end
            safeAfter(2.2, function()
                mapSearchCallout:SetTextScrolling(hintAction)
                moveCursorTo(hoverBtn, CURSOR_MOVE, clearHintOnArrive)
            end)
        end

        -- After the "point is now being tracked" callout, detect
        -- whether the player is currently in NEAR mode (circle+arrow
        -- visible) or FAR mode (perimeter glow). Then narrate a
        -- "move to see it flip" flow tailored to their starting
        -- state. EasyFindNearTrack is the frame that only appears
        -- when the POI is within 75% of the minimap's radar radius
        -- (see MapSearch.lua:769), so its visibility is the mode
        -- test.
        function msc.trackingStateNarration(done)
            local nearTrack = _G["EasyFindNearTrack"]
            local glow = _G["EasyFindMinimapGlow"]
            local function inNearMode()
                return nearTrack and nearTrack:IsShown()
            end
            local function trackingActive()
                local nearShown = nearTrack and nearTrack:IsShown()
                local glowShown = glow and glow:IsShown()
                return nearShown or glowShown
            end
            local function cancelTicker()
                if trackingStateTicker then
                    trackingStateTicker:Cancel()
                    trackingStateTicker = nil
                end
            end
            local function pollUntil(predicate, onArrive)
                cancelTicker()
                trackingStateTicker = C_Timer.NewTicker(0.25, function()
                    if predicate() then
                        cancelTicker()
                        onArrive()
                    end
                end)
            end
            -- Final wait: don't end the demo until the player has
            -- actually reached the POI and super-tracking has cleared
            -- (both the near-track frame and the perimeter glow are
            -- hidden). The user asked for this explicitly; no timeout.
            local function waitForArrival(onArrive)
                pollUntil(function() return not trackingActive() end, onArrive)
            end
            if inNearMode() then
                minimapCallout:SetText("Try moving further to see the perimeter arrow glow.\n(Glow can be turned off in settings.)")
                pollUntil(function() return not inNearMode() end, function()
                    minimapCallout:SetText("Venture all the way to the point to see the circle shrink.")
                    pollUntil(inNearMode, function()
                        waitForArrival(done)
                    end)
                end)
            else
                minimapCallout:SetText("Try moving closer to place the guiding circle around you.\n(Glow can be turned off in settings.)")
                pollUntil(inNearMode, function()
                    minimapCallout:SetText("Venture all the way to the point to see the circle shrink.")
                    waitForArrival(done)
                end)
            end
        end

        function msc.clickResult(done)
            local lastPOI = msc.lastBrowsePOI
            local target = (lastPOI and findMapResultByName(lastPOI.name))
                or findFirstVisibleMapResult()
            if not target then
                safeAfter(0.5, done)
                return
            end
            -- Announce the next action. Scroll-transition the text so
            -- the callout (already showing "Hovering over a result..."
            -- at the end of browseWhatsAround) stays put and its text
            -- ticker-rolls to the new narration instead of popping out
            -- and back. Falls back to Show if the callout wasn't already
            -- open (e.g. the browse step was skipped).
            mapSearchCallout:SetTextScrolling("Now let's click this result.")
            -- Extra beat before the click so the user has time to read
            -- the freshly-scrolled narration (CURSOR_MOVE below adds
            -- another 0.8s of reading while the cursor travels to the
            -- row).
            safeAfter(2.8, function()
                moveCursorTo(target, CURSOR_MOVE, function()
                    hideMapCaret()
                    clickAnim(function()
                        -- Clear the hover tag so setHoveredRow fires OnLeave
                        -- when SelectResult hides the results frame.
                        if target._demoMapHover then target._demoMapHover = nil end
                        setHoveredRow(nil)
                        if target.data and ns.MapSearch then
                            pcall(ns.MapSearch.SelectResult, ns.MapSearch, target.data)
                        end
                        safeAfter(SETTLE_PAUSE, function()
                            -- Scroll the callout's text from "Now let's
                            -- click this result." to the clear-button
                            -- hint, point chevrons at both clear
                            -- buttons, fire the local one's tooltip.
                            -- Then hand off to the minimap tracking
                            -- callout.
                            msc.clearBtnHint(function()
                                mapSearchCallout:Hide()
                                minimapCallout:SetText("The point is now being tracked.")
                                minimapCallout:Show()
                                minimapArrow:Show()
                                moveCursorTo(minimapCalloutFrame, CURSOR_MOVE, function()
                                    safeAfter(2.5, function()
                                        msc.trackingStateNarration(function()
                                            minimapCallout:Hide()
                                            minimapArrow:Hide()
                                            closeMapAndFinish(done)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end

        function msc.clickPinTrackContinue(done)
            -- Scroll-transition from the previous step's "Now let's click
            -- this result." callout so the box doesn't pop out and back.
            -- Falls through to a normal Show if the callout is hidden.
            mapSearchCallout:SetTextScrolling("Click the pin to place a waypoint and start tracking.")
            clickPinAndTrack(function()
                safeAfter(1.5, function()
                    mapSearchCallout:Hide()
                    minimapCallout:SetText("Tracked. There's an even easier way...")
                    minimapCallout:Show()
                    minimapArrow:Show()
                    moveCursorTo(minimapCalloutFrame, CURSOR_MOVE, function()
                        safeAfter(2.5, function()
                            minimapCallout:Hide()
                            minimapArrow:Hide()
                            -- Move cursor to the map search clear button and click it
                            -- so the user sees how to dismiss the pin, rather than
                            -- having it magically disappear.
                            local lsf = _G["EasyFindMapSearchFrame"]
                            local clearBtn = lsf and lsf.clearBtn
                            if clearBtn and clearBtn:IsShown() then
                                moveCursorTo(clearBtn, CURSOR_MOVE, function()
                                    clickAnim(function()
                                        local handler = clearBtn:GetScript("OnClick")
                                        if handler then pcall(handler, clearBtn) end
                                        clearDemoWaypoint()
                                        safeAfter(0.4, done)
                                    end)
                                end)
                            else
                                clearDemoWaypoint()
                                resetMapSearchState()
                                if lsf and lsf.editBox then lsf.editBox:SetText("") end
                                safeAfter(0.4, done)
                            end
                        end)
                    end)
                end)
            end)
        end

        function msc.clickNavBtnAutoTrack(done)
            local lastPOI = msc.lastBrowsePOI
            local row = (lastPOI and findMapResultByName(lastPOI.name))
                or findFirstVisibleMapResult()
            if not row or not row.navBtn or not row.navBtn:IsShown() then
                safeAfter(0.5, done)
                return
            end
            moveCursorTo(row.navBtn, CURSOR_MOVE, function()
                hideMapCaret()
                -- Briefly show the nav button tooltip before clicking
                local onEnter = row.navBtn:GetScript("OnEnter")
                if onEnter then pcall(onEnter, row.navBtn) end
                safeAfter(1.0, function()
                    GameTooltip_Hide()
                    clickAnim(function()
                        if row.data and ns.MapSearch then
                            ns.MapSearch.autoTrackNextPin = true
                            pcall(ns.MapSearch.SelectResult, ns.MapSearch, row.data)
                        end
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end)
        end

        function msc.minimapHintAndClose(done)
            minimapCallout:SetText("And just like that, your target is tracked on the minimap!")
            msc.finishHintAndClose(done)
        end

        function msc.pickDiversePOIs()
            if not (ns.MapSearch and ns.MapSearch.GetStaticLocations) then return {} end
            -- This demo is about what's around the player right now, so
            -- prefer the player's actual zone. WMF's mapID is only a
            -- fallback because the zone/instance demo navigates WMF to
            -- an instance entrance map (no POIs) via SelectResult and
            -- stays there after the demo closes. Using WMF as the
            -- primary source would incorrectly disable this demo on the
            -- very next switch. GetBestMapForUnit can return nil
            -- transiently (loading screens, very early init), so cache
            -- a last-good mapID as a final fallback. Same priority as
            -- MapSearch:SearchForUI's local search.
            local getBest = _G["GetBestMapForUnit"]
            local playerMapID = getBest and getBest("player")
            local wmfMapID = WorldMapFrame and WorldMapFrame:GetMapID()
            local pois = playerMapID and ns.MapSearch:GetStaticLocations(playerMapID)
            if pois and #pois > 0 then
                msc.lastGoodMapID = playerMapID
            else
                pois = wmfMapID and ns.MapSearch:GetStaticLocations(wmfMapID)
                if pois and #pois > 0 then
                    msc.lastGoodMapID = wmfMapID
                elseif msc.lastGoodMapID then
                    pois = ns.MapSearch:GetStaticLocations(msc.lastGoodMapID)
                end
            end
            if not pois or #pois == 0 then return {} end
            local picks, seenCat = {}, {}
            for _, poi in ipairs(pois) do
                local cat = poi.category or "unknown"
                if cat ~= "flightmaster" and not seenCat[cat] and poi.name and poi.name ~= "" then
                    seenCat[cat] = true
                    picks[#picks + 1] = poi
                    if #picks >= 3 then break end
                end
            end
            return picks
        end

        -- Max rows to hover per typed prefix. Capped so a prefix that
        -- yields many results (e.g. a very common first 3 chars) doesn't
        -- stretch the browse step into a long slog.
        local MAX_BROWSE_HOVERS = 3
        -- Pause on each row when hovering multiple; a full narration pause
        -- when there's only one row so the single preview has time to land.
        local BROWSE_MULTI_HOVER_PAUSE = 1.0
        local BROWSE_SINGLE_HOVER_PAUSE = 2.2

        -- Type `query` into the local map search bar, then walk the cursor
        -- through each visible result row (up to MAX_BROWSE_HOVERS),
        -- pausing at each so the map preview can update. Each row is
        -- tagged with _demoMapHover so setHoveredRow fires real
        -- OnEnter/OnLeave as the cursor crosses rows, making the preview
        -- track the cursor in real time.
        function msc.hoverRowsForPrefix(query, isFirstVisit, done)
            local lsf = _G["EasyFindMapSearchFrame"]
            local editBox = lsf and lsf.editBox
            if not editBox then done(); return end
            local function hoverAllRows()
                local rows = {}
                for i = 1, 20 do
                    local btn = _G["EasyFindMapResultButton" .. i]
                    if btn and btn:IsShown() and btn.data and btn.data.name
                       and not btn.data.isHeader then
                        rows[#rows + 1] = btn
                        if #rows >= MAX_BROWSE_HOVERS then break end
                    end
                end
                if #rows == 0 then done(); return end
                -- Tag every row up front so the preview fires even on rows
                -- the cursor passes through between deliberate stops.
                for i = 1, #rows do rows[i]._demoMapHover = true end
                local pause = (#rows > 1) and BROWSE_MULTI_HOVER_PAUSE or BROWSE_SINGLE_HOVER_PAUSE
                local idx = 0
                local function nextRow()
                    idx = idx + 1
                    if idx > #rows then
                        -- Remember the last visible row so later steps
                        -- (clickResult, retypeLastBrowse) re-target it.
                        local lastRow = rows[#rows]
                        if lastRow and lastRow.data and lastRow.data.name then
                            msc.lastBrowsePOI = { name = lastRow.data.name }
                        end
                        -- Untag the rows we already visited so when the
                        -- cursor travels back to the editbox for the next
                        -- prefix it doesn't re-trigger previews on each
                        -- row it passes over. The last row stays tagged
                        -- so its preview clears via OnLeave when the
                        -- cursor finally departs.
                        for i = 1, #rows - 1 do
                            rows[i]._demoMapHover = nil
                        end
                        done()
                        return
                    end
                    local row = rows[idx]
                    moveCursorTo(row, CURSOR_MOVE, function()
                        safeAfter(pause, nextRow)
                    end)
                end
                nextRow()
            end
            local function afterFocus()
                backspaceMapTextKeepCaret(editBox, TYPE_DELAY, function()
                    typeMapTextKeepCaret(editBox, query, TYPE_DELAY, function()
                        -- Show the narration as soon as typing finishes
                        -- (only on the first prefix; later prefixes reuse
                        -- the callout that's already up). Raising it here
                        -- instead of waiting for cursor arrival at the
                        -- first row lets the user read the instruction
                        -- while the cursor is still travelling.
                        if isFirstVisit then
                            mapSearchCallout:SetText("Hovering over a result shows it on the map.")
                            mapSearchCallout:ShowWithArrow()
                        end
                        safeAfter(SETTLE_PAUSE, hoverAllRows)
                    end)
                end)
            end
            if isFirstVisit then
                moveCursorTo(editBox, CURSOR_MOVE, function()
                    clickAnim(afterFocus)
                end)
            else
                moveCursorTo(editBox, CURSOR_MOVE, afterFocus)
            end
        end

        msc.lastBrowsePOI = nil
        function msc.browseWhatsAround(done)
            local picks = msc.pickDiversePOIs()
            if #picks == 0 then done(); return end
            local idx = 0
            local function nextPick()
                idx = idx + 1
                if idx > #picks then
                    -- Leave the callout visible so clickResult can
                    -- scroll its text from "Hovering over a result..."
                    -- to "Now let's click this result." without the box
                    -- popping out and back.
                    done()
                    return
                end
                local poi = picks[idx]
                -- Per-category overrides: typing "ah" or "fp" reads as
                -- the natural in-game shorthand and avoids spelling out
                -- "auc"/"fli" which look awkward in the demo.
                local cat = poi.category
                local query
                if cat == "auctionhouse" then
                    query = "ah"
                elseif cat == "flightmaster" then
                    query = "fp"
                else
                    query = slower(poi.name):sub(1, 3)
                end
                msc.hoverRowsForPrefix(query, idx == 1, nextPick)
            end
            nextPick()
        end

        DEMOS.mapSearchCurrent.rebuild = function(def)
            msc.lastBrowsePOI = nil
            -- Fully wipe the demo payload each rebuild. Both the
            -- disabled state and the step list live on the shared `def`
            -- table across rebuilds.
            def.disabled = false
            def.disabledMessage = nil
            def.stepDefs = nil
            def.sections = nil
            def.run = nil
            def.setupAfter = nil
            local hasBrowse = #msc.pickDiversePOIs() > 0
            if not hasBrowse then
                def.disabled = true
                def.disabledMessage = "No searchable POIs in this zone."
                return
            end
            local openSnap = function()
                openWorldMapToPlayerZone()
            end
            -- Snap to end-of-browse: map open with the last POI query
            -- typed and results visible, ready for "Click a result".
            local browseSnap = function()
                openWorldMapToPlayerZone()
                local picks = msc.pickDiversePOIs()
                if #picks > 0 then
                    local lastPick = picks[#picks]
                    msc.lastBrowsePOI = { name = lastPick.name }
                    local query = slower(lastPick.name):sub(1, 3)
                    if ns.MapSearch and ns.MapSearch.RunLocalSearch then
                        ns.MapSearch:RunLocalSearch(query)
                    end
                    local lastName
                    local seen = 0
                    for i = 1, 20 do
                        local btn = _G["EasyFindMapResultButton" .. i]
                        if btn and btn:IsShown() and btn.data and btn.data.name
                           and not btn.data.isHeader then
                            lastName = btn.data.name
                            seen = seen + 1
                            if seen >= MAX_BROWSE_HOVERS then break end
                        end
                    end
                    if lastName then
                        msc.lastBrowsePOI = { name = lastName }
                    end
                end
            end
            local doneSnap = function()
                clearDemoWaypoint(); resetMapSearchState(); closeWorldMap()
            end
            def.stepDefs = {
                { text = "Open the world map",   section = 1 },
                { text = "Browse what's around", section = 1 },
                { text = "Click a result",       section = 1 },
            }
            def.sections = { { header = "", section = 1, firstStep = 1, lastStep = 3 } }
            def.run = {
                msc.openMap,
                msc.browseWhatsAround,
                msc.clickResult,
            }
            def.setupAfter = { openSnap, browseSnap, doneSnap }
        end

        ----------------------------------------------------------------
        -- Map search through UI bar: demonstrates searching for map
        -- POIs from the main UI search bar and how Fast/Guide mode
        -- affect the result click. Fast Mode places a waypoint
        -- directly without opening the map. Guide Mode starts a guide
        -- to open the map, then shows a pin the user must click.
        ----------------------------------------------------------------
        -- Helpers for the Map-search-through-UI-bar demo. All msui.*
        -- helpers live on a single table so they only consume one local
        -- in this huge function. The demo verifies Fast Mode + the UI
        -- search bar's Map Search filter (Local sub-option), then
        -- drives the actual search and click.
        local msui = {}

        function msui.openFilterDropdown()
            local dd = searchFrame.filterDropdown
            if dd and not dd:IsShown() then
                local anchorFrame = searchFrame
                local barScale = (EasyFind.db.uiSearchScale or 1.0) * (EasyFind.db.fontSize or 1.0)
                dd:SetScale(barScale)
                local scale = anchorFrame:GetEffectiveScale() / (UIParent:GetEffectiveScale() * barScale)
                local right = anchorFrame:GetRight() * scale
                local bottom = anchorFrame:GetBottom() * scale
                dd:ClearAllPoints()
                dd:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, bottom)
                dd:Show()
            end
        end

        function msui.closeFilterDropdown()
            local dd = searchFrame.filterDropdown
            if dd and dd:IsShown() then dd:Hide() end
        end

        -- Fire the full OnClick handler for a filter-dropdown row. The
        -- row's OnClick runs the LayoutDropdown closure which isn't
        -- exposed externally — but calling the script directly triggers
        -- it and correctly repositions sub-rows.
        function msui.fireCheckRowClick(row)
            if not row then return end
            local handler = row:GetScript("OnClick")
            if handler then pcall(handler, row) end
        end

        function msui.ensureMapFilterEnabled()
            EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
            local dd = searchFrame.filterDropdown
            if not (dd and dd.checkRows and dd.checkRows.map) then
                EasyFind.db.uiSearchFilters.map = true
                return
            end
            local row = dd.checkRows.map
            -- If the row isn't checked, flip the checkbox and fire the
            -- real OnClick so LayoutDropdown runs and the Local/Global
            -- sub-rows become visible in the dropdown.
            if not row:GetChecked() then
                row:SetChecked(true)
                msui.fireCheckRowClick(row)
            end
            EasyFind.db.uiSearchFilters.map = true
            if row.updateMapToggle then row.updateMapToggle() end
        end

        -- Returns the map row's Local or Global sub-row. isLocal = true
        -- for Local, false for Global.
        function msui.getMapSubRow(isLocal)
            local dd = searchFrame.filterDropdown
            local mr = dd and dd.checkRows and dd.checkRows.map
            if not mr or not mr.mapSubRows then return nil end
            for _, sr in ipairs(mr.mapSubRows) do
                if sr.isLocalKey == isLocal then return sr end
            end
            return nil
        end

        function msui.setMapSubLocal(isLocal)
            EasyFind.db.uiMapSearchLocal = isLocal
            local dd = searchFrame.filterDropdown
            local mr = dd and dd.checkRows and dd.checkRows.map
            if mr and mr.mapSubRows then
                for _, sr in ipairs(mr.mapSubRows) do
                    sr:SetChecked(sr.isLocalKey == isLocal)
                end
            end
        end

        -- Reusable helpers for the mapSearchUI run steps.
        function msui.stepFilterBtnClick(done)
            local fb = searchFrame.filterBtn
            if not fb then done(); return end
            moveCursorTo(fb, CURSOR_MOVE, function()
                clickAnim(function() safeAfter(STEP_PAUSE, done) end)
            end)
        end

        -- Merged "focus the search bar + start typing" step. Closes the
        -- filter dropdown (simulating auto-close on focus), moves the
        -- cursor to the search bar, clicks, shows the blink cursor,
        -- then types the given text. Used by both Local and Global
        -- search sections so focus + typing live in a single user-
        -- meaningful step instead of three awkward ones.
        function msui.stepFocusAndType(text, done)
            msui.closeFilterDropdown()
            moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    if searchFrame.editBox.placeholder then
                        searchFrame.editBox.placeholder:Hide()
                    end
                    startBlinkCursor()
                    safeAfter(STEP_PAUSE, function()
                        typeText(text, TYPE_DELAY, function()
                            safeAfter(SETTLE_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        -- Find a visible UI search result whose name contains the given
        -- substring (case-insensitive). Falls back to the first visible
        -- non-header row if no match (so the demo still has something
        -- to click in zones missing the expected POI type).
        function msui.findResultRowByPartialName(substring)
            local lowSub = substring and substring ~= "" and slower(substring) or nil
            local first
            for i = 1, #resultButtons do
                local row = resultButtons[i]
                if row and row:IsShown() and row.data and row.data.name
                   and not row.data.isPinHeader and not row.data.isHeader then
                    if lowSub and sfind(slower(row.data.name), lowSub) then
                        return row
                    end
                    if not first then first = row end
                end
            end
            return first
        end

        -- Helper: fire the click handler for the flight master or
        -- Eastern Plaguelands result row, then settle.
        local function msui_clickPartial(substring, afterClick)
            local target = msui.findResultRowByPartialName(substring)
            if not target then
                safeAfter(0.5, afterClick)
                return
            end
            moveCursorTo(target, CURSOR_MOVE, function()
                clickAnim(function()
                    stopBlinkCursor()
                    if target.data and ns.MapSearch and ns.MapSearch.HandleUISearchClick then
                        pcall(ns.MapSearch.HandleUISearchClick, ns.MapSearch, target.data)
                    end
                    afterClick()
                end)
            end)
        end

        local mapSearchUI_run = {
            ----------------------------------------------------------------
            -- SECTION 1: Local Map POI search (flight master)
            ----------------------------------------------------------------
            -- 1: Open filter menu
            function(done) msui.stepFilterBtnClick(function() msui.openFilterDropdown(); safeAfter(STEP_PAUSE, done) end) end,
            -- 2: Enable Map Search filter
            function(done)
                msui.ensureMapFilterEnabled()
                safeAfter(STEP_PAUSE, done)
            end,
            -- 3: Confirm Local is selected
            function(done)
                local localRow = msui.getMapSubRow(true)
                if localRow then
                    moveCursorTo(localRow, CURSOR_MOVE, function()
                        if EasyFind.db.uiMapSearchLocal == false then
                            clickAnim(function()
                                msui.setMapSubLocal(true)
                                safeAfter(STEP_PAUSE, done)
                            end)
                        else
                            safeAfter(0.6, done)
                        end
                    end)
                else
                    msui.setMapSubLocal(true)
                    safeAfter(0.5, done)
                end
            end,
            -- 4: Type "fli"
            function(done) msui.stepFocusAndType("fli", done) end,
            -- 5: Click the Flight Master result.
            function(done)
                msui_clickPartial("flight master", function()
                    minimapCallout:SetText("The point is now being tracked.")
                    safeAfter(SETTLE_PAUSE, function()
                        showMinimapHint(function()
                            minimapCallout:Hide()
                            minimapArrow:Hide()
                            clearDemoWaypoint()
                            searchFrame.editBox:SetText("")
                            UI:OnSearchTextChanged("")
                            if searchFrame.editBox.placeholder then
                                searchFrame.editBox.placeholder:Show()
                            end
                            safeAfter(1.0, function()
                                transitionFS:SetText("Now let's try a global zone search to find Eastern Plaguelands.")
                                transitionText:Show()
                                beginSectionTransition(2)
                                safeAfter(3.5, done)
                            end)
                        end)
                    end)
                end)
            end,
            ----------------------------------------------------------------
            -- SECTION 2: Global zone search (Eastern Plaguelands)
            ----------------------------------------------------------------
            -- 6: Open filter menu
            function(done)
                transitionText:Hide()
                msui.stepFilterBtnClick(function() msui.openFilterDropdown(); safeAfter(STEP_PAUSE, done) end)
            end,
            -- 7: Switch to Global
            function(done)
                msui.ensureMapFilterEnabled()
                local globalRow = msui.getMapSubRow(false)
                if globalRow then
                    moveCursorTo(globalRow, CURSOR_MOVE, function()
                        clickAnim(function()
                            msui.setMapSubLocal(false)
                            safeAfter(STEP_PAUSE, done)
                        end)
                    end)
                else
                    msui.setMapSubLocal(false)
                    safeAfter(0.5, done)
                end
            end,
            -- 8: Type "eas"
            function(done) msui.stepFocusAndType("eas", done) end,
            -- 9: Click the Eastern Plaguelands result.
            function(done)
                msui_clickPartial("eastern plaguelands", function()
                    safeAfter(SETTLE_PAUSE + 1.5, function()
                        searchFrame.editBox:SetText("")
                        UI:OnSearchTextChanged("")
                        if searchFrame.editBox.placeholder then
                            searchFrame.editBox.placeholder:Show()
                        end
                        local closeBtn = getMapCloseBtn()
                        local function finish()
                            resetMapSearchState()
                            closeWorldMap()
                            safeAfter(0.5, function()
                                cursor:Hide()
                                done()
                            end)
                        end
                        if closeBtn and closeBtn:IsShown() then
                            moveCursorTo(closeBtn, CURSOR_MOVE, function()
                                clickAnim(finish)
                            end)
                        else
                            finish()
                        end
                    end)
                end)
            end,
        }

        -- Baseline every setupAfter builds on: filter enabled + local/global sub.
        function msui.baseline(isLocal)
            msui.ensureMapFilterEnabled()
            msui.setMapSubLocal(isLocal)
        end

        local mapSearchUI_setupAfter = {
            -- 1: Filter menu opened
            function() msui.baseline(true); msui.openFilterDropdown() end,
            -- 2: Map filter enabled
            function() msui.baseline(true); msui.openFilterDropdown() end,
            -- 3: Local confirmed
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 4: "fli" typed
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("fli")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                UI:OnSearchTextChanged("fli")
                startBlinkCursor()
            end,
            -- 5: Flight master clicked
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                clearDemoWaypoint()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
            end,
            -- 6: Filter menu opened for section 2
            function() msui.baseline(false); msui.openFilterDropdown() end,
            -- 7: Global filter enabled
            function() msui.baseline(false); msui.closeFilterDropdown() end,
            -- 8: "eas" typed
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("eas")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                UI:OnSearchTextChanged("eas")
                startBlinkCursor()
            end,
            -- 9: Eastern Plaguelands clicked, map closed
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                clearDemoWaypoint()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
                resetMapSearchState(); closeWorldMap()
            end,
        }

        DEMOS.mapSearchUI.rebuild = function(def)
            def.run        = mapSearchUI_run
            def.setupAfter = mapSearchUI_setupAfter
        end

        --------------------------------------------------------------------
        -- Disabled-demo overlay: shown over the step list when a demo
        -- can't run (e.g. no saved outfits). Created once, toggled by
        -- loadDemo based on def.disabled / def.disabledMessage.
        --------------------------------------------------------------------
        local disabledOverlay = CreateFrame("Frame", nil, stepScrollFrame)
        disabledOverlay:SetAllPoints()
        disabledOverlay:SetFrameLevel(stepScrollFrame:GetFrameLevel() + 10)
        local disabledText = disabledOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        disabledText:SetPoint("CENTER", 0, 10)
        disabledText:SetWidth(180)
        disabledText:SetTextColor(0.7, 0.7, 0.7)
        disabledOverlay:Hide()

        --------------------------------------------------------------------
        -- Outfits demo
        --------------------------------------------------------------------
        local od = {}

        function od.findOutfitEntry()
            if not ns.Database or not ns.Database.uiSearchData then return nil end
            local activeID = C_TransmogOutfitInfo and C_TransmogOutfitInfo.GetActiveOutfitID
                and C_TransmogOutfitInfo.GetActiveOutfitID()
            for _, e in ipairs(ns.Database.uiSearchData) do
                if e.outfitID and e.outfitID ~= activeID then return e end
            end
            return nil
        end

        od.entry = nil

        function od.enableFilter(done)
            local dd = searchFrame.filterDropdown
            local outfitRow = dd and dd.checkRows and dd.checkRows.outfits
            msui.stepFilterBtnClick(function()
                msui.openFilterDropdown()
                safeAfter(STEP_PAUSE, function()
                    if not outfitRow then
                        EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                        EasyFind.db.uiSearchFilters.outfits = true
                        safeAfter(0.3, done)
                        return
                    end
                    moveCursorTo(outfitRow, CURSOR_MOVE, function()
                        if not outfitRow:GetChecked() then
                            clickAnim(function()
                                outfitRow:SetChecked(true)
                                EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                                EasyFind.db.uiSearchFilters.outfits = true
                                local h = outfitRow:GetScript("OnClick")
                                if h then pcall(h, outfitRow) end
                                safeAfter(STEP_PAUSE, done)
                            end)
                        else
                            safeAfter(0.8, done)
                        end
                    end)
                end)
            end)
        end

        function od.typeQuery(query, done)
            moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    msui.closeFilterDropdown()
                    startBlinkCursor()
                    safeAfter(STEP_PAUSE, function()
                        typeText(query, TYPE_DELAY, function()
                            safeAfter(STEP_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        -- Bouncing red arrow (same style as the tutorial mode-toggle arrow)
        -- that sits outside the results window pointing at a target row.
        local OD_ARROW_SIZE = 28
        local odArrowFrame = CreateFrame("Frame", nil, UIParent)
        odArrowFrame:SetFrameStrata("TOOLTIP")
        odArrowFrame:SetFrameLevel(1002)
        odArrowFrame:SetSize(OD_ARROW_SIZE, OD_ARROW_SIZE)
        odArrowFrame:SetIgnoreParentAlpha(true)
        local odArrowTex = odArrowFrame:CreateTexture(nil, "ARTWORK")
        odArrowTex:SetSize(OD_ARROW_SIZE, OD_ARROW_SIZE)
        odArrowTex:SetPoint("CENTER")
        odArrowTex:SetTexture(1121272)
        odArrowTex:SetTexCoord(0.6078, 0.6402, 0.9381, 0.9688)
        odArrowTex:SetRotation(math.pi / 2) -- point left (toward results)
        local odArrowBox = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        odArrowBox:SetPoint("LEFT", odArrowFrame, "RIGHT", 4, 0)
        odArrowBox:Hide()
        odArrowFrame:Hide()

        local odPokeElapsed = 0
        local OD_POKE_AMOUNT = 8
        local OD_POKE_PERIOD = 1.4
        odArrowFrame:SetScript("OnUpdate", function(_, dt)
            if not odArrowFrame:IsShown() then return end
            odPokeElapsed = odPokeElapsed + dt
            local offset = math.sin(odPokeElapsed / OD_POKE_PERIOD * math.pi * 2) * OD_POKE_AMOUNT
            odArrowTex:SetPoint("CENTER", odArrowFrame, "CENTER", -offset, 0)
        end)

        local function odShowArrow(target, labelText)
            odArrowFrame:ClearAllPoints()
            odArrowFrame:SetPoint("LEFT", target, "RIGHT", 4, 0)
            odArrowBox.fs:SetText(labelText or "")
            odArrowBox:SetAutoSized(360)
            odPokeElapsed = 0
            odArrowFrame:Show()
            odArrowBox:Show()
        end

        local function odHideArrow()
            odArrowFrame:Hide()
            odArrowBox:Hide()
        end

        -- Wait for the user to actually equip the target outfit
        function od.waitForEquip(targetOutfitID, done)
            local row = findResultRowByName(od.entry and od.entry.name) or findFirstResultRow()
            if not row then done(); return end
            stopBlinkCursor()
            cursor:Hide()
            odShowArrow(row, "Click here to equip outfit")
            -- Suppress the lock system and release locks so the user's
            -- hardware click reaches the SecureActionButton.
            locksSuppressed = true
            releaseRunningLocks()
            -- Keep the editbox locked so the user can't type during the wait
            searchFrame.editBox:EnableMouse(false)
            searchFrame.editBox:ClearFocus()
            local ticker
            ticker = C_Timer.NewTicker(0.2, function()
                local activeID = C_TransmogOutfitInfo
                    and C_TransmogOutfitInfo.GetActiveOutfitID
                    and C_TransmogOutfitInfo.GetActiveOutfitID()
                if activeID == targetOutfitID then
                    ticker:Cancel()
                    locksSuppressed = false
                    applyRunningLocks()
                    odHideArrow()
                    od.clearSearch()
                    transitionFS:SetText("You now have the outfit equipped.")
                    transitionText:Show()
                    safeAfter(2.5, function()
                        transitionFS:SetText("Now let's see how we can pin this for quick access later.")
                        beginSectionTransition(2)
                        safeAfter(3.5, function()
                            transitionText:Hide()
                            done()
                        end)
                    end)
                end
            end)
            od.equipTicker = ticker
        end

        function od.pinOutfit(done)
            local e = od.entry
            if not e then done(); return end
            od.typeQuery(slower(e.name):sub(1, 4), function()
                local row = findResultRowByName(e.name) or findFirstResultRow()
                if not row then done(); return end
                moveCursorTo(row, CURSOR_MOVE, function()
                    mapSearchCallout:SetText("Right-click to pin for quick access.")
                    mapSearchCallout.frame:ClearAllPoints()
                    mapSearchCallout.frame:SetPoint("TOP", resultsFrame, "BOTTOM", 0, -8)
                    mapSearchCallout.frame:Show()
                    -- Show the right-click mouse indicator next to the cursor
                    rightClickIcon:Show()
                    safeAfter(1.0, function()
                        -- Right-click animation
                        clickAnim(function()
                            -- Trigger the real right-click handler to show pin popup
                            local postClick = row:GetScript("PostClick")
                            if postClick then postClick(row, "RightButton") end
                            local popup = _G["EasyFindPinPopup"]
                            if not popup or not popup:IsShown() then
                                rightClickIcon:Hide()
                                if row.data then
                                    UI.PinUIItem(row.data)
                                    od.pinnedByDemo = true
                                end
                                safeAfter(1.5, function()
                                    mapSearchCallout:Hide()
                                    od.clearSearch()
                                    safeAfter(0.5, done)
                                end)
                                return
                            end
                            -- Anchor popup near the row (ShowPinPopup used
                            -- the real cursor position which is wrong here)
                            popup:ClearAllPoints()
                            popup:SetPoint("LEFT", row, "RIGHT", 4, 0)
                            -- Let the user see the popup for a moment
                            safeAfter(1.2, function()
                                rightClickIcon:Hide()
                                moveCursorTo(popup, CURSOR_MOVE * 0.6, function()
                                    clickAnim(function()
                                        if popup.pinRow and popup.pinRow.Click then
                                            popup.pinRow:Click()
                                        elseif popup.Hide then
                                            popup:Hide()
                                        end
                                        od.pinnedByDemo = true
                                        safeAfter(1.5, function()
                                            mapSearchCallout:Hide()
                                            safeAfter(0.5, done)
                                        end)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end

        function od.showPinnedAccess(done)
            local clearBtn = searchFrame.clearTextBtn
            if not clearBtn or not clearBtn:IsShown() then
                -- No text to clear, just focus the bar
                moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                    clickAnim(function()
                        if searchFrame.editBox then
                            searchFrame.editBox:SetText("")
                        end
                        if UI.ShowPinnedItems then
                            pcall(UI.ShowPinnedItems, UI)
                        end
                        safeAfter(1.5, function()
                            transitionFS:SetText("Now you can easily get to it again later without typing.")
                            transitionText:Show()
                            safeAfter(3.0, function()
                                transitionText:Hide()
                                od.clearSearch()
                                cursor:Hide()
                                safeAfter(0.3, done)
                            end)
                        end)
                    end)
                end)
                return
            end
            -- Move to the clear (X) button and click it
            moveCursorTo(clearBtn, CURSOR_MOVE, function()
                clickAnim(function()
                    local onClick = clearBtn:GetScript("OnClick")
                    if onClick then pcall(onClick, clearBtn) end
                    safeAfter(0.6, function()
                        -- Now focus the empty search bar to show pinned items
                        moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                            clickAnim(function()
                                if UI.ShowPinnedItems then
                                    pcall(UI.ShowPinnedItems, UI)
                                end
                                safeAfter(1.5, function()
                                    transitionFS:SetText("Now you can easily get to it again later without typing.")
                                    transitionText:Show()
                                    safeAfter(3.0, function()
                                        transitionText:Hide()
                                        od.clearSearch()
                                        cursor:Hide()
                                        safeAfter(0.3, done)
                                    end)
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end

        function od.clearSearch()
            if searchFrame and searchFrame.editBox then
                searchFrame.editBox:SetText("")
                searchFrame.editBox:ClearFocus()
                if UI.OnSearchTextChanged then
                    pcall(UI.OnSearchTextChanged, UI, "")
                end
            end
            setHoveredRow(nil)
            stopBlinkCursor()
        end

        function od.cleanup()
            odHideArrow()
            rightClickIcon:Hide()
            mapSearchCallout:Hide()
            transitionText:Hide()
            if od.equipTicker then od.equipTicker:Cancel(); od.equipTicker = nil end
            locksSuppressed = false
            if od.pinnedByDemo and od.entry then
                pcall(UI.UnpinUIItem, od.entry)
                od.pinnedByDemo = false
            end
            od.clearSearch()
        end


        DEMOS.outfits.rebuild = function(def)
            local outfitEntry = od.findOutfitEntry()

            if not outfitEntry then
                def.disabled = true
                def.disabledMessage = "Please save an outfit before trying this demo."
                def.sections = {}
                def.stepDefs = {}
                def.run = {}
                def.setupAfter = {}
                return
            end

            def.disabled = false

            od.entry = outfitEntry
            od.pinnedByDemo = false
            local savedFilters = EasyFind.db.uiSearchFilters
                and EasyFind.db.uiSearchFilters.outfits

            def.sections = {
                { header = "Equip a saved outfit", section = 1, firstStep = 1, lastStep = 3 },
                { header = "Pin for quick access",  section = 2, firstStep = 4, lastStep = 5 },
            }
            def.stepDefs = {
                { text = "Enable Outfits search filter",     section = 1 },
                { text = "Start typing an outfit name",      section = 1 },
                { text = "Click the outfit to equip it",     section = 1 },
                { text = "Right-click to pin it",            section = 2 },
                { text = "Focus the search bar to see pins", section = 2 },
            }

            def.run = {
                -- 1: Enable filter
                function(done)
                    od.enableFilter(function()
                        od.entry = od.findOutfitEntry()
                        done()
                    end)
                end,
                -- 2: Type outfit name
                function(done)
                    local e = od.entry
                    if not e then done(); return end
                    od.typeQuery(slower(e.name):sub(1, 4), done)
                end,
                -- 3: Show arrow, wait for user to equip
                function(done)
                    local e = od.entry
                    if not e then done(); return end
                    od.waitForEquip(e.outfitID, done)
                end,
                -- 4: Re-search + right-click to pin
                function(done)
                    transitionText:Hide()
                    od.pinOutfit(done)
                end,
                -- 5: Focus bar to show pinned items
                function(done)
                    od.showPinnedAccess(done)
                end,
            }

            local function snap()
                od.cleanup()
                EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                EasyFind.db.uiSearchFilters.outfits = true
            end
            def.setupAfter = {
                function() snap() end,
                function() snap() end,
                function() snap() end,
                function() snap() end,
                function()
                    od.cleanup()
                    if EasyFind.db.uiSearchFilters then
                        EasyFind.db.uiSearchFilters.outfits = savedFilters
                    end
                    if od.entry then pcall(UI.UnpinUIItem, od.entry) end
                    cursor:Hide()
                end,
            }
        end

        --------------------------------------------------------------------
        -- Appearance Sets demo
        --------------------------------------------------------------------
        local asd = {}

        local CLASS_ARMOR = {
            [1]=4,[2]=4,[6]=4,           -- Plate
            [3]=3,[7]=3,[13]=3,          -- Mail
            [4]=2,[10]=2,[11]=2,[12]=2,  -- Leather
            [5]=1,[8]=1,[9]=1,           -- Cloth
        }

        function asd.findSetEntry()
            if not ns.Database or not ns.Database.uiSearchData then return nil end
            local GetBaseSetID = C_TransmogSets and C_TransmogSets.GetBaseSetID
            local GetSetInfo = C_TransmogSets and C_TransmogSets.GetSetInfo
            for _, e in ipairs(ns.Database.uiSearchData) do
                if e.transmogSetID then
                    -- Only pick base PvE sets; variants can't be scrolled
                    -- to, and PvP sets have faction/navigation issues
                    if not GetBaseSetID or GetBaseSetID(e.transmogSetID) == e.transmogSetID then
                        local info = GetSetInfo and GetSetInfo(e.transmogSetID)
                        local label = info and info.label and slower(info.label) or ""
                        local isPvP = sfind(label, "pvp") or sfind(label, "season")
                            or sfind(label, "gladiator") or sfind(label, "aspirant")
                            or sfind(label, "combatant")
                        if not isPvP then
                            return e
                        end
                    end
                end
            end
            return nil
        end

        -- Cached entries so every step in the same section clicks
        -- the exact same set instead of re-querying the database
        -- (which may return a different entry after filter changes).
        asd.playerSetEntry = nil
        asd.altSetEntry = nil

        -- "+ Ctrl" label that floats to the right of the cursor during
        -- Ctrl+Click steps. Same gold font as the floating callout text
        -- so it reads as part of the demo narration, not a UI element.
        local ctrlBadge = CreateFrame("Frame", nil, UIParent)
        ctrlBadge:SetSize(80, 20)
        ctrlBadge:SetFrameStrata("TOOLTIP")
        ctrlBadge:SetFrameLevel(10000)
        local ctrlBadgeFS = ctrlBadge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ctrlBadgeFS:SetPoint("LEFT")
        ctrlBadgeFS:SetText("+ Ctrl")
        ctrlBadgeFS:SetTextColor(1.0, 0.82, 0.0)
        ctrlBadgeFS:SetShadowColor(0, 0, 0, 1)
        ctrlBadgeFS:SetShadowOffset(2, -2)
        ctrlBadge:Hide()

        function asd.showCtrlBadge()
            ctrlBadge:ClearAllPoints()
            ctrlBadge:SetPoint("LEFT", cursor, "RIGHT", 4, 0)
            ctrlBadge:Show()
        end

        function asd.enableFilter(done)
            local dd = searchFrame.filterDropdown
            local asRow = dd and dd.checkRows and dd.checkRows.appearanceSets
            msui.stepFilterBtnClick(function()
                msui.openFilterDropdown()
                safeAfter(STEP_PAUSE, function()
                    if not asRow then
                        EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                        EasyFind.db.uiSearchFilters.appearanceSets = true
                        safeAfter(0.3, done)
                        return
                    end
                    moveCursorTo(asRow, CURSOR_MOVE, function()
                        if not asRow:GetChecked() then
                            clickAnim(function()
                                asRow:SetChecked(true)
                                EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                                EasyFind.db.uiSearchFilters.appearanceSets = true
                                local h = asRow:GetScript("OnClick")
                                if h then pcall(h, asRow) end
                                safeAfter(STEP_PAUSE, done)
                            end)
                        else
                            safeAfter(0.8, done)
                        end
                    end)
                end)
            end)
        end

        function asd.typeQuery(query, done)
            moveCursorTo(searchFrame.editBox, CURSOR_MOVE, function()
                clickAnim(function()
                    msui.closeFilterDropdown()
                    if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                    startBlinkCursor()
                    safeAfter(STEP_PAUSE, function()
                        typeText(query, TYPE_DELAY, function()
                            safeAfter(SETTLE_PAUSE, done)
                        end)
                    end)
                end)
            end)
        end

        -- Animate cursor to a frame's close button and click it.
        local function closeFrameAnimated(frame, afterClose)
            if not frame or not frame:IsShown() then
                if afterClose then afterClose() end
                return
            end
            local closeBtn = frame.CloseButton
                or (frame.BorderFrame and frame.BorderFrame.CloseButton)
            if closeBtn and closeBtn:IsShown() then
                moveCursorTo(closeBtn, CURSOR_MOVE, function()
                    clickAnim(function()
                        pcall(HideUIPanel, frame)
                        safeAfter(0.4, afterClose)
                    end)
                end)
            else
                pcall(HideUIPanel, frame)
                safeAfter(0.4, afterClose)
            end
        end

        function asd.ctrlClickSet(calloutText, done)
            local row = findResultRowByName(nil) or findFirstResultRow()
            if not row or not row.data or not row.data.transmogSetID then done(); return end
            asd.showCtrlBadge()
            moveCursorTo(row, CURSOR_MOVE, function()
                clickAnim(function()
                    stopBlinkCursor()
                    mapSearchCallout:SetText(calloutText)
                    mapSearchCallout:Show()
                    if UI.DressUpAppearanceSet then
                        pcall(UI.DressUpAppearanceSet, UI, row.data.transmogSetID)
                    end
                    safeAfter(2.5, function()
                        ctrlBadge:Hide()
                        mapSearchCallout:Hide()
                        closeFrameAnimated(_G["DressUpFrame"], function()
                            asd.clearSearch()
                            safeAfter(0.3, done)
                        end)
                    end)
                end)
            end)
        end

        function asd.regularClickSet(calloutText, useFast, done)
            local row = findResultRowByName(nil) or findFirstResultRow()
            if not row or not row.data or not row.data.transmogSetID then done(); return end
            local clickedData = row.data
            moveCursorTo(row, CURSOR_MOVE, function()
                clickAnim(function()
                    stopBlinkCursor()
                    mapSearchCallout:SetText(calloutText)
                    mapSearchCallout:Show()
                    local guideData = {
                        name = clickedData.name,
                        steps = {
                            { buttonFrame = "CollectionsMicroButton" },
                            { waitForFrame = "CollectionsJournal", tabIndex = 5 },
                            { waitForFrame = "WardrobeCollectionFrame", wardrobeSetsTab = true },
                            { waitForFrame = "WardrobeCollectionFrame",
                              transmogSetID = clickedData.transmogSetID,
                              transmogSetName = clickedData.name },
                        },
                    }
                    if useFast then
                        UI:DirectOpen(guideData)
                    else
                        EasyFind:StartGuide(guideData)
                    end
                    safeAfter(3.0, function()
                        mapSearchCallout:Hide()
                        if ns.Highlight and ns.Highlight.ClearAll then
                            pcall(ns.Highlight.ClearAll, ns.Highlight)
                        end
                        closeFrameAnimated(_G["CollectionsJournal"], function()
                            asd.clearSearch()
                            safeAfter(0.3, done)
                        end)
                    end)
                end)
            end)
        end

        function asd.switchClassFilter(targetClassID, done)
            msui.stepFilterBtnClick(function()
                msui.openFilterDropdown()
                safeAfter(STEP_PAUSE, function()
                    local dd = searchFrame.filterDropdown
                    local asRow = dd and dd.checkRows and dd.checkRows.appearanceSets
                    local csRow = asRow and asRow.asClassSelectRow
                    if not csRow then
                        EasyFind.db.appearanceSetClass = { classID = targetClassID }
                        if ns.Database and ns.Database.PopulateDynamicTransmogSets then
                            ns.Database:PopulateDynamicTransmogSets()
                        end
                        msui.closeFilterDropdown()
                        done()
                        return
                    end
                    moveCursorTo(csRow, CURSOR_MOVE, function()
                        clickAnim(function()
                            -- Fire the row's real OnClick which calls
                            -- LayoutClassPopup + positions + shows the popup.
                            local handler = csRow:GetScript("OnClick")
                            if handler then pcall(handler, csRow) end
                            local popup = _G["EasyFindAsClassPopup"]
                            safeAfter(0.5, function()
                                local found
                                if popup then
                                    for _, child in ipairs({popup:GetChildren()}) do
                                        if child._classID == targetClassID then
                                            found = child; break
                                        end
                                    end
                                end
                                if found then
                                    moveCursorTo(found, CURSOR_MOVE, function()
                                        clickAnim(function()
                                            local h = found:GetScript("OnClick")
                                            if h then pcall(h, found) end
                                            safeAfter(0.8, function()
                                                msui.closeFilterDropdown()
                                                done()
                                            end)
                                        end)
                                    end)
                                else
                                    EasyFind.db.appearanceSetClass = { classID = targetClassID }
                                    if ns.Database and ns.Database.PopulateDynamicTransmogSets then
                                        ns.Database:PopulateDynamicTransmogSets()
                                    end
                                    if popup then popup:Hide() end
                                    msui.closeFilterDropdown()
                                    done()
                                end
                            end)
                        end)
                    end)
                end)
            end)
        end

        function asd.clearSearch()
            searchFrame.editBox:SetText("")
            UI:OnSearchTextChanged("")
            if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
        end

        function asd.cleanupAll()
            ctrlBadge:Hide()
            mapSearchCallout:Hide()
            local duf = _G["DressUpFrame"]
            if duf and duf:IsShown() then pcall(HideUIPanel, duf) end
            local cj = _G["CollectionsJournal"]
            if cj and cj:IsShown() then pcall(HideUIPanel, cj) end
            if ns.Highlight and ns.Highlight.ClearAll then
                pcall(ns.Highlight.ClearAll, ns.Highlight)
            end
            asd.clearSearch()
        end

        DEMOS.appearanceSets.rebuild = function(def)
            local _, _, playerClassID = UnitClass("player")
            local myArmor = CLASS_ARMOR[playerClassID]
            local altClassID
            for cid, armor in pairs(CLASS_ARMOR) do
                if armor ~= myArmor then altClassID = cid; break end
            end
            local altClassName = altClassID and (GetClassInfo(altClassID)) or "another class"

            def.sections = {
                { header = "Preview on your character",          section = 1, firstStep = 1, lastStep = 3 },
                { header = "Open in Collections",                section = 2, firstStep = 4, lastStep = 5 },
                { header = "Try " .. altClassName .. "'s armor", section = 3, firstStep = 6, lastStep = 8 },
            }
            def.stepDefs = {
                { text = "Enable Appearance Sets search",                       section = 1 },
                { text = "Start typing an appearance set name",                 section = 1 },
                { text = "Ctrl+Click to preview on your character",             section = 1 },
                { text = "Search the same set again",                           section = 2 },
                { text = "Click to open it in Collections",                     section = 2 },
                { text = "Switch class filter to " .. altClassName,             section = 3 },
                { text = "Search a " .. altClassName .. " appearance set",      section = 3 },
                { text = "Ctrl+Click to preview on your character",             section = 3 },
            }
            local savedAsClass = EasyFind.db.appearanceSetClass
            local savedAsFilters = {}
            for _, k in ipairs({"appearanceSetCollected", "appearanceSetNotCollected", "appearanceSetPvE", "appearanceSetPvP"}) do
                savedAsFilters[k] = EasyFind.db[k]
            end

            def.run = {
                -- 1: Enable filter + cache player's set
                function(done)
                    asd.enableFilter(function()
                        asd.playerSetEntry = asd.findSetEntry()
                        done()
                    end)
                end,
                -- 2: Type set name
                function(done)
                    local e = asd.playerSetEntry
                    if not e then done(); return end
                    asd.typeQuery(slower(e.name):sub(1, 4), done)
                end,
                -- 3: Ctrl+Click → DressUp (opens, shows callout, closes)
                function(done)
                    asd.ctrlClickSet(
                        "Ctrl+Click previews the set on your character.", done)
                end,
                -- 4: Type same set again
                function(done)
                    local e = asd.playerSetEntry
                    if not e then done(); return end
                    asd.typeQuery(slower(e.name):sub(1, 4), done)
                end,
                -- 5: Regular click → Collections (opens, shows callout, closes)
                function(done)
                    asd.regularClickSet(
                        "A regular click opens the set in Collections.",
                        true, done)
                end,
                -- 6: Switch class filter + cache alt set
                function(done)
                    if not altClassID then done(); return end
                    asd.switchClassFilter(altClassID, function()
                        asd.altSetEntry = asd.findSetEntry()
                        done()
                    end)
                end,
                -- 7: Type different class set
                function(done)
                    local e = asd.altSetEntry
                    if not e then done(); return end
                    asd.typeQuery(slower(e.name):sub(1, 4), done)
                end,
                -- 8: Ctrl+Click → DressUp (different armor, then restore)
                function(done)
                    asd.ctrlClickSet(
                        "You can preview any class's armor on your character.",
                        function()
                            EasyFind.db.appearanceSetClass = savedAsClass
                            for k, v in pairs(savedAsFilters) do EasyFind.db[k] = v end
                            if ns.Database and ns.Database.PopulateDynamicTransmogSets then
                                ns.Database:PopulateDynamicTransmogSets()
                            end
                            cursor:Hide()
                            done()
                        end)
                end,
            }

            local function snap(classOverride)
                asd.cleanupAll()
                EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
                EasyFind.db.uiSearchFilters.appearanceSets = true
                if classOverride then
                    EasyFind.db.appearanceSetClass = classOverride
                else
                    EasyFind.db.appearanceSetClass = savedAsClass
                end
                if ns.Database and ns.Database.PopulateDynamicTransmogSets then
                    ns.Database:PopulateDynamicTransmogSets()
                end
            end
            def.setupAfter = {
                function() snap() end,                                               -- 1
                function() snap() end,                                               -- 2
                function() snap() end,                                               -- 3
                function() snap() end,                                               -- 4
                function() snap() end,                                               -- 5
                function() snap(altClassID and { classID = altClassID } or nil) end,  -- 6
                function() snap(altClassID and { classID = altClassID } or nil) end,  -- 7
                function()                                                            -- 8
                    snap()
                    EasyFind.db.appearanceSetClass = savedAsClass
                    for k, v in pairs(savedAsFilters) do EasyFind.db[k] = v end
                    if ns.Database and ns.Database.PopulateDynamicTransmogSets then
                        ns.Database:PopulateDynamicTransmogSets()
                    end
                end,
            }
        end

        --------------------------------------------------------------------
        -- Demo state machine. Transport controls: Prev / Play-Pause / Next.
        -- State vars completedUpTo and animatingIdx are already declared
        -- above next to refreshStepList.
        --------------------------------------------------------------------
        local autoPlay = false

        --------------------------------------------------------------------
        -- Click-blocker lock system. While the demo is actively running
        -- (animatingIdx > 0 or autoPlay && !paused), every interactive
        -- frame the demo touches gets a transparent click-blocker child
        -- frame on top that eats real mouse events. Programmatic clicks
        -- (tab:Click(), UI:SelectResult(), etc.) bypass the blocker so
        -- the demo can still drive the UI internally. The drag handler
        -- and editbox keyboard are also disabled during run.
        --
        -- The moment the demo is paused, idle (between manual steps),
        -- or stopped, every blocker is released and the player gets
        -- full access back, exactly as the user requested.
        --------------------------------------------------------------------
        local clickBlockers = {}
        local function lockFrame(f, topPad)
            if not f or clickBlockers[f] then return end
            topPad = topPad or 8
            local blocker = CreateFrame("Frame", nil, f)
            blocker:SetPoint("TOPLEFT", f, "TOPLEFT", -8, topPad)
            blocker:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
            blocker:SetFrameStrata(f:GetFrameStrata())
            blocker:SetFrameLevel(1000)
            blocker:EnableMouse(true)
            -- Also eat scroll wheel events so the player can't scroll
            -- the underlying frame's contents while a step is running.
            -- Mouse wheel needs both EnableMouseWheel and an explicit
            -- OnMouseWheel handler; without the handler the event
            -- propagates to the parent.
            blocker:EnableMouseWheel(true)
            blocker:SetScript("OnMouseWheel", function() end)
            blocker:Show()
            clickBlockers[f] = blocker
        end
        local function unlockAllFrames()
            for f, blocker in pairs(clickBlockers) do
                blocker:EnableMouse(false)
                blocker:EnableMouseWheel(false)
                blocker:SetScript("OnMouseWheel", nil)
                blocker:Hide()
                blocker:SetParent(nil)
                clickBlockers[f] = nil
            end
        end
        -- Lock the map search bars (local + global) while the demo is
        -- running so the real user can't click/focus them or type into
        -- them. Clicks are eaten by the lockFrame blocker, EnableMouse
        -- on the editbox is a belt-and-suspenders, and ClearFocus makes
        -- sure the editbox doesn't hold pre-existing keyboard focus.
        local function lockMapSearchEditBoxes()
            for _, frameName in ipairs({ "EasyFindMapSearchFrame", "EasyFindMapGlobalSearchFrame" }) do
                local lsf = _G[frameName]
                local eb = lsf and lsf.editBox
                if eb then
                    lockFrame(lsf)
                    eb:EnableMouse(false)
                    eb:ClearFocus()
                end
            end
        end
        local function unlockMapSearchEditBoxes()
            for _, frameName in ipairs({ "EasyFindMapSearchFrame", "EasyFindMapGlobalSearchFrame" }) do
                local lsf = _G[frameName]
                local eb = lsf and lsf.editBox
                if eb then
                    eb:EnableMouse(true)
                end
            end
        end

        applyRunningLocks = function()
            lockFrame(searchFrame)
            lockFrame(resultsFrame)
            -- Demo-specific frames (PlayerSpellsFrame, WorldMapFrame,
            -- etc.) need a bigger top pad because frame tabs anchor
            -- just outside the parent's bounds.
            local def = DEMOS[currentDemoKey]
            if def and def.lockFrames then
                for _, name in ipairs(def.lockFrames) do
                    lockFrame(_G[name], 32)
                end
            end
            searchFrame:SetScript("OnDragStart", nil)
            searchFrame.setupMode = true
            searchFrame.editBox:EnableMouse(false)
            if searchFrame.filterDropdown then
                searchFrame.filterDropdown._demoSuspend = true
            end
            lockMapSearchEditBoxes()
        end
        releaseRunningLocks = function()
            unlockAllFrames()
            searchFrame:SetScript("OnDragStart", savedDragStart)
            searchFrame.setupMode = nil
            searchFrame.editBox:EnableMouse(true)
            if searchFrame.filterDropdown then
                searchFrame.filterDropdown._demoSuspend = nil
            end
            unlockMapSearchEditBoxes()
        end
        locksSuppressed = false
        updateLockState = function()
            if not active then releaseRunningLocks(); return end
            if locksSuppressed then return end
            local isRunning = (not paused) and (animatingIdx > 0 or autoPlay)
            if isRunning then
                applyRunningLocks()
            else
                releaseRunningLocks()
            end
            minimapArrow:SetPaused(not isRunning)
        end

        local function updateButtons()
            -- Empty demo (no animation steps yet): disable all transport
            -- buttons and show the play icon in its idle state.
            if not demoSteps or #demoSteps == 0 then
                prevBtn:Disable()
                nextBtn:Disable()
                sectPrevBtn:Disable()
                sectNextBtn:Disable()
                playBtn:Show()
                playBtn:Disable()
                playBtn.icon:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
                playBtn.icon:SetTexCoord(0, 1, 0, 1)
                playBtn.icon:SetSize(11, 11)
                replayBtn:Hide()
                updateLockState()
                return
            end
            local animating = animatingIdx > 0
            local atEnd = completedUpTo >= #demoSteps and not animating
            -- Prev: disabled only at the very start (no step has run yet
            -- and nothing is animating). Otherwise always clickable, so the
            -- player can skip backward even mid-animation.
            if completedUpTo < 1 and not animating then
                prevBtn:Disable()
                sectPrevBtn:Disable()
            else
                prevBtn:Enable()
                sectPrevBtn:Enable()
            end
            -- Next: disabled only when there's no further step to run and
            -- nothing is currently animating.
            if atEnd then
                nextBtn:Disable()
                sectNextBtn:Disable()
            else
                nextBtn:Enable()
                sectNextBtn:Enable()
            end
            -- At the end of the demo, swap the Play button out for the
            -- Replay button (in the same middle position). Otherwise the
            -- Play button is visible with its play/pause icon.
            playBtn:SetShown(not atEnd)
            playBtn:Enable()
            replayBtn:SetShown(atEnd)
            if animating or autoPlay then
                replayBtn:Disable()
            else
                replayBtn:Enable()
            end
            -- The play icon shows "pause" only while actively running (the
            -- next click will pause). When idle, paused, or stepping
            -- manually it shows "play" (the next click will resume/start).
            if autoPlay and not paused then
                playBtn.icon:SetTexture("Interface\\AddOns\\EasyFind\\demo-pause")
                playBtn.icon:SetTexCoord(0, 1, 0, 1)
                playBtn.icon:SetSize(11, 11)
            else
                playBtn.icon:SetTexture("Interface\\AddOns\\EasyFind\\flyout-arrow")
                playBtn.icon:SetTexCoord(0, 1, 0, 1)
                playBtn.icon:SetSize(11, 11)
            end
            updateLockState()
        end

        local runStep             -- forward decl
        local resetDemoGameState  -- forward decl, defined below cancelInFlight
        runStep = function(i)
            if not active then return end
            highlightOverride = nil
            if i > #demoSteps then
                -- Demo finished: stop autoplay, clean up the cursor +
                -- any frames the demo opened, and revert the user's
                -- pre-demo settings (Fast/Guide mode, fade, etc.)
                -- so the demo doesn't leave their preferences mutated.
                autoPlay = false
                cursor:Hide()
                transitionText:Hide()
                if resetDemoGameState then resetDemoGameState() end
                restoreUserSettings()
                updateButtons()
                return
            end
            if i < 1 then i = 1 end
            -- Starting a real step clears any section-transition
            -- highlight left over from the previous step's action so
            -- the new step can take focus.
            pendingSectionHighlight = nil
            animatingIdx = i
            refreshStepList()
            updateButtons()
            local myGen = stepGen
            -- PRE-ACT pause: highlight just moved to step i (and the
            -- list scrolled). Wait long enough for the user to read
            -- the step label before the cursor starts moving.
            safeAfter(PRE_ACT_GAP, function()
                if not active or myGen ~= stepGen then return end
                demoSteps[i](function()
                    if not active or myGen ~= stepGen then return end
                    -- Snapshot the cursor's final position for this
                    -- step so later jumpToStep/jumpToBeforeStep calls
                    -- can restore it to the exact same spot instead
                    -- of letting moveCursorTo fall back to its
                    -- default middle-right starting position.
                    if cursor:IsShown() and cursor:GetLeft() then
                        cursorEndPos[i] = {
                            x = cursor:GetLeft() + 4,
                            y = cursor:GetTop() - 4,
                            shown = true,
                        }
                    else
                        cursorEndPos[i] = { shown = false }
                    end
                    -- Snapshot whether the step's action already
                    -- pre-highlighted a section header (via
                    -- beginSectionTransition during its transition
                    -- text). If so, the boundary beat below is
                    -- redundant since the header has been on screen
                    -- throughout the transition.
                    local transitionedMidStep = pendingSectionHighlight ~= nil
                    -- POST-ACT pause: keep animatingIdx = i so the
                    -- step stays highlighted while the user sees the
                    -- result of the action. Only after this pause does
                    -- the highlight advance to the next step.
                    safeAfter(POST_ACT_GAP, function()
                        if not active or myGen ~= stepGen then return end
                        animatingIdx = 0
                        if i > completedUpTo then
                            completedUpTo = i
                        end
                        refreshStepList()
                        -- Final step finished (manual path): settle,
                        -- clean up, restore user settings.
                        if completedUpTo >= #demoSteps and not autoPlay then
                            safeAfter(0.6, function()
                                if not active then return end
                                cursor:Hide()
                                if resetDemoGameState then resetDemoGameState() end
                                restoreUserSettings()
                                updateButtons()
                            end)
                        end
                        if autoPlay and active then
                            updateButtons()
                            -- Section transition was pre-announced by
                            -- the step's own action (header shown
                            -- during transition text). Skip the
                            -- boundary beat and chain straight to the
                            -- next step, whose PRE-ACT pause will
                            -- display the first step of the new
                            -- section before it acts.
                            if transitionedMidStep then
                                runStep(i + 1)
                            else
                                -- Normal section boundary: the
                                -- refreshStepList above highlighted
                                -- the header via the atBoundary logic
                                -- (not pendingSectionHighlight). Give
                                -- the header its own beat before the
                                -- next step takes over.
                                local nextIdx = i + 1
                                local atBoundary = false
                                if nextIdx <= #demoSteps and DEMO_SECTIONS then
                                    for _, sect in ipairs(DEMO_SECTIONS) do
                                        if nextIdx == sect.firstStep and sect.header and sect.header ~= "" then
                                            atBoundary = true
                                            break
                                        end
                                    end
                                end
                                if atBoundary then
                                    safeAfter(POST_ACT_GAP, function()
                                        if not autoPlay or not active or myGen ~= stepGen then
                                            updateButtons()
                                            return
                                        end
                                        runStep(i + 1)
                                    end)
                                else
                                    runStep(i + 1)
                                end
                            end
                        else
                            updateButtons()
                        end
                    end)
                end)
            end)
        end

        -- Reset the game state to a clean slate (nothing typed, no frames
        -- open, no highlights showing). Used by Previous to rewind from
        -- whatever the current state is before applying a step's "after"
        -- state. Does NOT touch the demo panel itself or the mock cursor.
        -- Forward-declared above so runStep's done callback can call it.
        resetDemoGameState = function()
            stopBlinkCursor()
            searchFrame.editBox:SetText("")
            UI:OnSearchTextChanged("")
            if searchFrame.editBox.placeholder then
                searchFrame.editBox.placeholder:Show()
            end
            if searchFrame.filterDropdown and searchFrame.filterDropdown:IsShown() then
                searchFrame.filterDropdown:Hide()
            end
            if ns.Highlight and ns.Highlight.ClearAll then
                pcall(ns.Highlight.ClearAll, ns.Highlight)
            end
            -- Wipe every demo-modified map state so switching demos
            -- doesn't leave a prior demo's pin/waypoint/search text
            -- bleeding into the next one. Hide the callout and arrow.
            if minimapCallout then minimapCallout:Hide() end
            if minimapArrow then minimapArrow:Hide() end
            if mapSearchCallout then mapSearchCallout:Hide() end
            if localClearPointer then
                localClearPointer.chev.frame:Hide()
                localClearPointer.emitter:Hide()
            end
            if globalClearPointer then
                globalClearPointer.chev.frame:Hide()
                globalClearPointer.emitter:Hide()
            end
            -- Outfit demo cleanup (arrow, ticker, right-click icon, pin)
            if od then pcall(od.cleanup) end
            if clearDemoWaypoint then pcall(clearDemoWaypoint) end
            if resetMapSearchState then pcall(resetMapSearchState) end
            -- Revert any WMF mapID change before closing so the next
            -- demo's rebuild (e.g. mapSearchCurrent's pickDiversePOIs)
            -- sees the player's real pre-demo WMF state instead of
            -- wherever the previous demo navigated to.
            restoreWmfMapID()
            if closeWorldMap then pcall(closeWorldMap) end
            if not InCombatLockdown() then
                local psf = _G["PlayerSpellsFrame"]
                if psf and psf.IsShown and psf:IsShown() then
                    pcall(HideUIPanel, psf)
                end
            end
            resetPlayerSpellsFrame()
        end

        -- Cancel any in-flight step animation. Bumps the generation counter
        -- so every async callback captured before this point aborts on its
        -- next check, stops the current timer / cursor OnUpdate / blink
        -- cursor, and clears any stray tooltip / hover state.
        local function cancelInFlight()
            stepGen = stepGen + 1
            wipe(pendingTimers)
            paused = false
            highlightOverride = nil
            pendingSectionHighlight = nil
            cursor:SetScript("OnUpdate", nil)
            cursor:SetSize(36, 36)
            -- Hide the fake cursor. The next runStep will re-show it
            -- at moveCursorTo's default starting position (mid-right
            -- of the screen), so jumping to any step via the step
            -- list starts the cursor from a clean spot instead of
            -- wherever the previous animation left it.
            cursor:Hide()
            stopBlinkCursor()
            setHoveredRow(nil)
            clearButtonHover()
            if transitionText then transitionText:Hide() end
            if trackingStateTicker then trackingStateTicker:Cancel(); trackingStateTicker = nil end
            if minimapCallout then minimapCallout:Hide() end
            if minimapArrow then minimapArrow:Hide() end
            if mapSearchCallout then mapSearchCallout:Hide() end
            if localClearPointer then
                localClearPointer.chev.frame:Hide()
                localClearPointer.emitter:Hide()
            end
            if globalClearPointer then
                globalClearPointer.chev.frame:Hide()
                globalClearPointer.emitter:Hide()
            end
            animatingIdx = 0
        end

        -- setupAfterStep[i] puts the game in the end-state of step i, no
        -- animation. These are used by Previous to rewind: reset to clean
        -- slate, then call setupAfterStep[target] for the new position.
        DEMOS.uiSearch.setupAfter = {
            -- 1: "sp" typed + results showing
            function()
                searchFrame.editBox:SetText("sp")
                UI:OnSearchTextChanged("sp")
                startBlinkCursor()
            end,
            -- 2: Spellbook opened then cleaned up (the run function
            -- closes its window and clears the search before calling
            -- done), so the end state is idle.
            function() end,
        }
        setupAfterStep = DEMOS.uiSearch.setupAfter

        -- Swap the active demo. Cancels any in-flight animation, restores
        -- game state, retargets the working refs to the new demo's
        -- tables, rewires the title, and rebuilds the step rows.
        loadDemo = function(key)
            local def = DEMOS[key]
            if not def or not active then return end
            cancelInFlight()
            autoPlay = false
            resetDemoGameState()
            cursor:Hide()
            -- Cursor-end snapshots are per-demo: wipe so the new
            -- demo's step indices don't pick up stale positions from
            -- the previous demo.
            wipe(cursorEndPos)
            -- Dynamic demos rebuild their step lists based on current
            -- user settings (e.g. mapSearchCurrent adapts to the user's
            -- Fast/Guide mode). Run rebuild BEFORE restoreUserSettings
            -- so it can resync saved mode values to the live ones,
            -- preserving any toggle the user made between demo loads.
            if def.rebuild then def.rebuild(def) end
            restoreUserSettings()
            currentDemoKey = key
            DEMO_STEPS = def.stepDefs
            DEMO_SECTIONS = def.sections
            demoSteps = def.run
            setupAfterStep = def.setupAfter
            title:SetText("|cffFFD100" .. def.title .. "|r")
            completedUpTo = 0
            animatingIdx = 0
            rebuildStepRows()
            refreshStepList()
            updateButtons()
            -- Disabled demo overlay
            if def.disabled then
                disabledText:SetText(def.disabledMessage or "This demo is not available.")
                disabledOverlay:Show()
            else
                disabledOverlay:Hide()
            end
            if refreshDemoMenuActive then refreshDemoMenuActive() end
        end

        -- Restore the fake cursor to its saved end-of-step position
        -- (captured during a previous playthrough). If there's no
        -- recorded position for that step, leaves the cursor hidden
        -- so the next runStep places it at moveCursorTo's default
        -- starting spot.
        local function restoreCursorForStep(stepIdx)
            local pos = cursorEndPos[stepIdx]
            if pos and pos.shown and pos.x and pos.y then
                placeCursorAt(pos.x, pos.y)
                cursor:Show()
            else
                cursor:Hide()
            end
        end

        -- Jump directly to step N's end state. Used by clicking a row in
        -- the step list. No animation: cancel anything in flight, wipe the
        -- game state, then apply setupAfterStep[N].
        jumpToStep = function(target)
            if not active then return end
            if target < 1 or target > #demoSteps then return end
            cancelInFlight()
            autoPlay = false
            resetDemoGameState()
            if setupAfterStep[target] then
                setupAfterStep[target]()
            end
            completedUpTo = target
            refreshStepList()
            -- Cursor belongs at the end of step `target`.
            restoreCursorForStep(target)
            updateButtons()
        end

        -- Jump to the state right BEFORE step N (i.e., end state of N-1),
        -- so the next Play / Next runs step N from the beginning. Used
        -- when clicking a section header to start that section fresh.
        jumpToBeforeStep = function(target)
            if not active then return end
            if target < 1 or target > #demoSteps then return end
            cancelInFlight()
            autoPlay = false
            resetDemoGameState()
            if target > 1 and setupAfterStep[target - 1] then
                setupAfterStep[target - 1]()
            end
            completedUpTo = target - 1
            refreshStepList()
            -- Cursor belongs at the end of step `target-1`, which is
            -- the exact spot where step `target` would start naturally
            -- during a linear playthrough.
            if target > 1 then
                restoreCursorForStep(target - 1)
            else
                cursor:Hide()
            end
            updateButtons()
        end

        -- Prev/Next jump to the beginning of the adjacent step without
        -- playing any animation. Only Play triggers animations.
        -- The target step gets highlightOverride so it's always a step
        -- that lights up (never a section header).
        local function isAtBoundary()
            local nextIdx = completedUpTo + 1
            if nextIdx > #demoSteps then return false end
            for _, sect in ipairs(DEMO_SECTIONS) do
                if nextIdx == sect.firstStep then return true end
            end
            return false
        end

        prevBtn:SetScript("OnClick", function()
            if not active then return end
            if animatingIdx > 0 then cancelInFlight(); autoPlay = false end
            local target
            if highlightOverride then
                target = highlightOverride - 1
            else
                target = completedUpTo
            end
            if target < 1 then return end
            jumpToBeforeStep(target)
            highlightOverride = target
            refreshStepList()
        end)

        nextBtn:SetScript("OnClick", function()
            if not active then return end
            if animatingIdx > 0 then cancelInFlight(); autoPlay = false end
            local target
            if highlightOverride then
                target = highlightOverride + 1
            elseif isAtBoundary() then
                target = completedUpTo + 1
            else
                target = completedUpTo + 2
            end
            if target > #demoSteps then return end
            jumpToBeforeStep(target)
            highlightOverride = target
            refreshStepList()
        end)

        -- Find the section that the current position belongs to. A
        -- section is "current" while completedUpTo < lastStep, which
        -- treats end-of-section-N as "at section N+1's header" for
        -- non-last sections, and "in the last section" for the final.
        local function findCurrentSectionIdx()
            if not DEMO_SECTIONS then return nil end
            for idx, sect in ipairs(DEMO_SECTIONS) do
                if completedUpTo < sect.lastStep then
                    return idx
                end
            end
            return nil
        end

        sectPrevBtn:SetScript("OnClick", function()
            if not active then return end
            local idx = findCurrentSectionIdx()
            if not idx then
                -- Past all sections (very end): jump to the last section's
                -- header so the player can replay that section.
                local last = DEMO_SECTIONS[#DEMO_SECTIONS]
                if last and jumpToBeforeStep then
                    jumpToBeforeStep(last.firstStep)
                end
                return
            end
            local sect = DEMO_SECTIONS[idx]
            if completedUpTo == sect.firstStep - 1 then
                -- Already at the current section's header: go to the
                -- previous section's header (or no-op if first).
                if idx > 1 and jumpToBeforeStep then
                    jumpToBeforeStep(DEMO_SECTIONS[idx - 1].firstStep)
                end
            else
                -- Mid section: go to the start of the current section.
                if jumpToBeforeStep then
                    jumpToBeforeStep(sect.firstStep)
                end
            end
        end)

        sectNextBtn:SetScript("OnClick", function()
            if not active then return end
            local idx = findCurrentSectionIdx()
            if not idx then
                -- Already past all sections: nothing to do.
                return
            end
            if idx < #DEMO_SECTIONS then
                -- Not the last section: jump to the next section's header.
                if jumpToBeforeStep then
                    jumpToBeforeStep(DEMO_SECTIONS[idx + 1].firstStep)
                end
            else
                -- Last section: jump to the very end of the demo.
                if jumpToStep then
                    jumpToStep(#demoSteps)
                end
            end
        end)

        local function startAutoPlay()
            autoPlay = true
            updateButtons()
            if animatingIdx == 0 then
                runStep(completedUpTo + 1)
            end
        end

        playBtn:SetScript("OnClick", function()
            if not active then return end
            if paused then
                paused = false
                updateButtons()
            elseif autoPlay then
                paused = true
                updateButtons()
            else
                startAutoPlay()
            end
        end)

        replayBtn:SetScript("OnClick", function()
            if not active then return end
            -- Reset to the state shown when the demo window first opened.
            -- User can then click Play to auto-run or Next to step through.
            cancelInFlight()
            autoPlay = false
            resetDemoGameState()
            completedUpTo = 0
            refreshStepList()
            updateButtons()
        end)

        -- Stop = full reset to as-if-just-opened state for the current
        -- demo. Equivalent to switching to the same demo via the dropdown.
        stopBtn:SetScript("OnClick", function()
            if not active then return end
            if loadDemo then loadDemo(currentDemoKey) end
        end)

        updateButtons()
        end  -- _runDemo
        _runDemo()
    end
