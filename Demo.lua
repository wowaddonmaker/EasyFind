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
local LIGHTNING_BOLT_TEX = "Interface\\AddOns\\EasyFind\\textures\\lightning-bolt"

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

        -- Step list: ONLY real (executable) steps. Section headers are
        -- display-only entries in DEMO_SECTIONS below and aren't navigable
        -- stops in the state machine - the player shouldn't have to click
        -- Per-demo Fast/Guide flag for demos that opt in via
        -- supportsModeToggle. Defaults to fast (true). Independent of
        -- the user's saved EasyFind.db.directOpen / *MapDirectOpen
        -- settings, which the demo restores after each run.
        local demoModeFast = {}

        -- Next to get past a header that does nothing.
        -- Demo registry. Each entry has:
        --   title       - shown at the top of the demo panel
        --   sections    - list of { header, section, firstStep, lastStep }
        --   stepDefs    - list of { text, section } describing each step row
        --   run         - list of function(done) that animates each step
        --   setupAfter  - list of function() that snaps the game state to
        --                 the end of step i without animation (used by
        --                 Prev/Next/jumpToStep)
        --   supportsModeToggle - true to show the Fast/Guide toggle button
        --                 on the demo panel; the demo's `rebuild` reads
        --                 demoModeFast[key] to pick which step set to build
        -- run and setupAfter for the default UI Search demo are populated
        -- further down, after the helper functions they reference exist.
        -- Other demos start empty and get filled in as we build them.
        local DEMOS = {
            uiSearch = {
                title    = "UI Search",
                sections = {
                    { header = "|TInterface\\AddOns\\EasyFind\\textures\\lightning-bolt:14:14|t Fast Mode (for convenience)", section = 1, firstStep = 1, lastStep = 3 },
                    { header = "|A:common-search-magnifyingglass:14:14|a Guide Mode (for learning)",                          section = 2, firstStep = 4, lastStep = 8 },
                },
                stepDefs = {
                    { text = "Make sure Fast Mode is enabled",   section = 1 },  -- 1
                    { text = 'Start typing "Spellbook"',         section = 1 },  -- 2
                    { text = "Click the Spellbook result",       section = 1 },  -- 3
                    { text = "Switch to Guide Mode",             section = 2 },  -- 4
                    { text = 'Start typing "Spellbook"',         section = 2 },  -- 5
                    { text = "Click the Spellbook result",       section = 2 },  -- 6
                    { text = "Click Talents & Spellbook button", section = 2 },  -- 7
                    { text = "Click the Spellbook tab",          section = 2 },  -- 8
                },
                lockFrames = { "PlayerSpellsFrame" },
                run = {},
                setupAfter = {},
            },
            mapSearchZone = {
                title = "Zone/Instance Map Search",
                -- sections / stepDefs / run / setupAfter are populated by
                -- the `rebuild` function based on demoModeFast["mapSearchZone"].
                sections = {},
                stepDefs = {},
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
                supportsModeToggle = true,
            },
            mapSearchCurrent = {
                title = "Current Zone Map Search",
                -- sections / stepDefs / run / setupAfter are populated by
                -- the `rebuild` function based on demoModeFast["mapSearchCurrent"].
                sections = {},
                stepDefs = {},
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
                supportsModeToggle = true,
            },
            mapSearchUI = {
                title = "Map search through UI bar",
                sections = {
                    { header = "Local Map POI search: Flight Master", section = 1, firstStep = 1, lastStep = 6 },
                    { header = "Global zone search: Eastern Plaguelands", section = 2, firstStep = 7, lastStep = 10 },
                },
                stepDefs = {
                    { text = "Make sure Fast Mode is enabled",       section = 1 },  -- 1
                    { text = "Open the filter menu",                 section = 1 },  -- 2
                    { text = "Enable Map Search filter",             section = 1 },  -- 3
                    { text = 'Confirm "Local" is selected',          section = 1 },  -- 4
                    { text = 'Start typing "Flight Master"',         section = 1 },  -- 5
                    { text = "Click the Flight Master result",       section = 1 },  -- 6
                    { text = "Open the filter menu",                 section = 2 },  -- 7
                    { text = 'Switch to "Global"',                   section = 2 },  -- 8
                    { text = 'Start typing "Eastern Plaguelands"',   section = 2 },  -- 9
                    { text = "Click the Eastern Plaguelands result", section = 2 },  -- 10
                },
                lockFrames = { "WorldMapFrame" },
                run = {},
                setupAfter = {},
                supportsModeToggle = true,
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
        demoFrame:SetPoint("RIGHT", UIParent, "RIGHT", -32, -120)
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

        -- Fast/Guide toggle row. Only shown for demos that opt in via
        -- def.supportsModeToggle. The "Mode:" prefix sits outside the
        -- button so the button itself just displays the icon + the
        -- current mode name. All sub-elements live on the modeUI table
        -- so they only consume one local in this large function.
        local modeUI = {}
        modeUI.row = CreateFrame("Frame", nil, demoFrame)
        modeUI.row:SetSize(108, 16)
        modeUI.row:SetPoint("TOP", title, "BOTTOM", 0, -4)
        modeUI.row:Hide()

        modeUI.prefix = modeUI.row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        modeUI.prefix:SetPoint("LEFT", modeUI.row, "LEFT", 0, 0)
        modeUI.prefix:SetText("Mode:")
        modeUI.prefix:SetTextColor(0.85, 0.85, 0.85)

        modeUI.btn = CreateFrame("Button", nil, modeUI.row)
        modeUI.btn:SetSize(64, 16)
        modeUI.btn:SetPoint("LEFT", modeUI.prefix, "RIGHT", 4, 0)
        local _modeTex = modeUI.btn:CreateTexture(nil, "BACKGROUND")
        _modeTex:SetAllPoints()
        _modeTex:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        _modeTex = modeUI.btn:CreateTexture(nil, "ARTWORK")
        _modeTex:SetPoint("TOPLEFT", 1, -1)
        _modeTex:SetPoint("BOTTOMRIGHT", -1, 1)
        _modeTex:SetColorTexture(0.12, 0.12, 0.12, 0.95)
        modeUI.icon = modeUI.btn:CreateTexture(nil, "OVERLAY")
        modeUI.icon:SetSize(11, 11)
        modeUI.icon:SetPoint("LEFT", modeUI.btn, "LEFT", 4, 0)
        modeUI.label = modeUI.btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        modeUI.label:SetPoint("LEFT", modeUI.icon, "RIGHT", 3, 0)
        modeUI.label:SetPoint("RIGHT", modeUI.btn, "RIGHT", -3, 0)
        modeUI.label:SetJustifyH("LEFT")
        modeUI.btn:SetHighlightTexture(130757, "ADD")

        local function refreshModeToggle()
            local def = DEMOS[currentDemoKey]
            if not def or not def.supportsModeToggle then
                modeUI.row:Hide()
                return
            end
            local isFast = demoModeFast[currentDemoKey] ~= false
            if isFast then
                modeUI.icon:SetAtlas(nil)
                modeUI.icon:SetTexture(LIGHTNING_BOLT_TEX)
                modeUI.label:SetText("Fast")
                modeUI.label:SetTextColor(1.0, 0.82, 0.0)
            else
                modeUI.icon:SetTexture(nil)
                modeUI.icon:SetAtlas("common-search-magnifyingglass")
                modeUI.label:SetText("Guide")
                modeUI.label:SetTextColor(0.6, 0.85, 1.0)
            end
            modeUI.row:Show()
        end

        modeUI.btn:SetScript("OnClick", function()
            if not active or not currentDemoKey then return end
            demoModeFast[currentDemoKey] = (demoModeFast[currentDemoKey] == false)
            if loadDemo then loadDemo(currentDemoKey) end
        end)

        modeUI.btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            if demoModeFast[currentDemoKey] ~= false then
                GameTooltip:SetText("Fast Mode")
                GameTooltip:AddLine("Click to switch this demo to Guide Mode.", 1, 1, 1, true)
            else
                GameTooltip:SetText("Guide Mode")
                GameTooltip:AddLine("Click to switch this demo to Fast Mode.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        modeUI.btn:SetScript("OnLeave", GameTooltip_Hide)

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
            { name = "Zone/instance map search", key = "mapSearchZone" },
            { name = "Current zone map search",  key = "mapSearchCurrent" },
            { name = "Map search through UI bar",key = "mapSearchUI" },
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
        -- startDemo. The forward-declared `active` upvalue is still
        -- shared with the modeUI button handlers above.
        local function _runDemo()

        -- Save originals so the lock toggling system can restore them
        -- when the demo isn't actively running. The search bar drag
        -- handler and the editbox keyboard state are both temporarily
        -- replaced/disabled while a step is animating, then restored
        -- whenever the demo is paused, idle, or stopped.
        local savedDragStart = searchFrame:GetScript("OnDragStart")
        local savedDirectOpen = EasyFind.db.directOpen
        local savedGlobalMapDirectOpen = EasyFind.db.globalMapDirectOpen
        local savedLocalMapDirectOpen = EasyFind.db.localMapDirectOpen
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

        -- Restore the user's pre-demo settings AND refresh the mode
        -- button visual (the icon doesn't auto-update when directOpen
        -- changes, so without this call it stays stuck on whatever the
        -- last demo step left it as).
        local function restoreUserSettings()
            -- staticOpacity stays forced true while the demo is open;
            -- it's restored in endDemo, not here, so loadDemo doesn't
            -- re-enable movement fade between demo switches.
            EasyFind.db.directOpen = savedDirectOpen
            EasyFind.db.globalMapDirectOpen = savedGlobalMapDirectOpen
            EasyFind.db.localMapDirectOpen = savedLocalMapDirectOpen
            EasyFind.db.uiSearchFilters = EasyFind.db.uiSearchFilters or {}
            EasyFind.db.uiSearchFilters.map = savedUiMapFilter
            EasyFind.db.uiMapSearchLocal = savedUiMapSearchLocal
            if ns.UpdateModeButtonVisual then
                pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
            end
            if ns.MapSearch and ns.MapSearch.UpdateMapModeBtns then
                pcall(ns.MapSearch.UpdateMapModeBtns, ns.MapSearch)
            end
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
        -- "your target is now tracked").
        local minimapCalloutFrame = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        minimapCalloutFrame:SetSize(320, 68)
        if _G["Minimap"] then
            minimapCalloutFrame:SetPoint("RIGHT", _G["Minimap"], "LEFT", -20, 40)
        else
            minimapCalloutFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -240, -80)
        end
        local minimapCalloutFS = minimapCalloutFrame.fs
        minimapCalloutFS:SetText("Note how your target is now tracked!")
        minimapCalloutFrame:Hide()

        local minimapCallout = {}
        function minimapCallout:SetText(text)
            minimapCalloutFS:SetText(text or "")
            minimapCalloutFrame:SetAutoSized(360)
        end
        function minimapCallout:Show() minimapCalloutFrame:Show() end
        function minimapCallout:Hide() minimapCalloutFrame:Hide() end

        -- Floating narration anchored next to the local map search frame.
        -- Used by mapSearchCurrent's "browse what's around" step.
        local mapSearchCallout = {}
        mapSearchCallout.frame = ns.TutorialBox.Create(UIParent, "GameFontNormalLarge")
        mapSearchCallout.frame:SetSize(280, 60)
        mapSearchCallout.frame:Hide()
        mapSearchCallout.fs = mapSearchCallout.frame.fs
        function mapSearchCallout:SetText(text)
            self.fs:SetText(text or "")
            self.frame:SetAutoSized(340)
        end
        function mapSearchCallout:Show()
            local lsf = _G["EasyFindMapSearchFrame"]
            if lsf then
                self.frame:ClearAllPoints()
                self.frame:SetPoint("LEFT", lsf, "RIGHT", 56, 0)
            end
            self.frame:Show()
        end
        function mapSearchCallout:Hide() self.frame:Hide() end

        -- Forward decl so endDemo / cancelInFlight / resetDemoGameState
        -- can call minimapArrow:Hide() via upvalue. The methods are
        -- attached later, once the arrow frame is built alongside the
        -- map search demo helpers.
        local minimapArrow = {}
        function minimapArrow:Show() end
        function minimapArrow:Hide() end

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
            -- UI search mode button
            local mb = searchFrame.modeBtn
            if mb then
                if mb.btnBg then mb.btnBg:Hide() end
                if mb.UnlockHighlight then mb:UnlockHighlight() end
            end
            -- Map search mode buttons
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            if gsf and gsf.modeBtn then
                if gsf.modeBtn.btnBg then gsf.modeBtn.btnBg:Hide() end
                if gsf.modeBtn.UnlockHighlight then gsf.modeBtn:UnlockHighlight() end
            end
            local lsf = _G["EasyFindMapSearchFrame"]
            if lsf and lsf.modeBtn then
                if lsf.modeBtn.btnBg then lsf.modeBtn.btnBg:Hide() end
                if lsf.modeBtn.UnlockHighlight then lsf.modeBtn:UnlockHighlight() end
            end
        end

        local function moveCursorTo(targetFrame, duration, onArrive, offsetX, offsetY)
            -- Clear any lingering hover state from the previous target
            -- (tooltip, button outline, highlight) so it doesn't persist
            -- while the cursor is in transit to a new frame.
            clearButtonHover()
            local tx, ty = centerInUIParent(targetFrame)
            if not tx then
                if onArrive then onArrive() end
                return
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
                placeCursorAt(nx, ny)
                if t >= 1 then
                    self:SetScript("OnUpdate", nil)
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

        -- Defensive precondition helper. Each step calls ensureMode at
        -- the start with the directOpen value it expects, so if the user
        -- toggled the mode while paused or between steps it gets snapped
        -- back to the default the step assumes.
        local function ensureMode(wantFast)
            if EasyFind.db.directOpen ~= wantFast then
                EasyFind.db.directOpen = wantFast
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
            end
        end

        -- Reset PlayerSpellsFrame to its default tab (Specialization) so
        -- the guide mode demo shows the full navigation steps instead
        -- of opening directly on the tab we left it on during fast mode.
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

        -- Hover the mode button to show what it does. If the player has
        -- it set to Guide Mode, this also performs an animated click
        -- to flip it back to Fast Mode (since the demo assumes Fast).
        -- The toggle happens INSIDE the click animation so the visual
        -- and the state change land at the same moment.
        -- Offset the cursor toward the bottom-right of the toggle button
        -- so the icon (lightning bolt / magnifying glass) stays visible
        -- during the hover and click animations.
        local MODE_BTN_OFFSET_X = 9
        local MODE_BTN_OFFSET_Y = -9

        local function hoverModeButton(done)
            local mb = searchFrame.modeBtn
            moveCursorTo(mb, CURSOR_MOVE, function()
                if mb.btnBg then mb.btnBg:Show() end
                if mb.LockHighlight then mb:LockHighlight() end
                GameTooltip:SetOwner(mb, "ANCHOR_BOTTOM")
                local function showFastTooltip()
                    GameTooltip:SetText("Fast Mode")
                    GameTooltip:AddLine("Click to switch to step-by-step Guide Mode.", 1, 1, 1, true)
                    GameTooltip:Show()
                end
                if not EasyFind.db.directOpen then
                    GameTooltip:SetText("Guide Mode")
                    GameTooltip:AddLine("Click to enable Fast Mode (opens panels directly).", 1, 1, 1, true)
                    GameTooltip:Show()
                    safeAfter(1.0, function()
                        clickAnim(function()
                            EasyFind.db.directOpen = true
                            if ns.UpdateModeButtonVisual then
                                pcall(ns.UpdateModeButtonVisual, mb)
                            end
                            showFastTooltip()
                            safeAfter(1.0, done)
                        end)
                    end)
                else
                    showFastTooltip()
                    safeAfter(1.2, done)
                end
            end, MODE_BTN_OFFSET_X, MODE_BTN_OFFSET_Y)
        end

        -- Mirror of hoverModeButton that switches to Guide Mode instead.
        -- Used by mapSearchUI's guide variant in step 1.
        local function hoverModeButtonToGuide(done)
            local mb = searchFrame.modeBtn
            moveCursorTo(mb, CURSOR_MOVE, function()
                if mb.btnBg then mb.btnBg:Show() end
                if mb.LockHighlight then mb:LockHighlight() end
                GameTooltip:SetOwner(mb, "ANCHOR_BOTTOM")
                local function showGuideTooltip()
                    GameTooltip:SetText("Guide Mode")
                    GameTooltip:AddLine("Click to enable Fast Mode (opens panels directly).", 1, 1, 1, true)
                    GameTooltip:Show()
                end
                if EasyFind.db.directOpen then
                    GameTooltip:SetText("Fast Mode")
                    GameTooltip:AddLine("Click to switch to step-by-step Guide Mode.", 1, 1, 1, true)
                    GameTooltip:Show()
                    safeAfter(1.0, function()
                        clickAnim(function()
                            EasyFind.db.directOpen = false
                            if ns.UpdateModeButtonVisual then
                                pcall(ns.UpdateModeButtonVisual, mb)
                            end
                            showGuideTooltip()
                            safeAfter(1.0, done)
                        end)
                    end)
                else
                    showGuideTooltip()
                    safeAfter(1.2, done)
                end
            end, MODE_BTN_OFFSET_X, MODE_BTN_OFFSET_Y)
        end

        -- Focuses the UI search bar with cursor animation + blink
        -- cursor, then types the query. Owns the full "search for X"
        -- action so there's no standalone focus step. `wantFast`
        -- defaults to true; pass false for the Guide Mode sections.
        local function uis_stepFocusAndType(query, wantFast, done)
            ensureMode(wantFast)
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
            -- 1: Make sure Fast Mode is enabled. If the player is in
            -- Standard Mode, hoverModeButton click-animates the toggle
            -- and flips directOpen during the click visualization.
            function(done)
                hoverModeButton(done)
            end,
            -- 2: Start typing "sp" (cursor flies to the bar, focuses
            -- it, then types — all in this single step).
            function(done)
                uis_stepFocusAndType("sp", true, done)
            end,
            -- 3: Click the Spellbook result (not just the first one).
            -- Final step of Fast Mode. After the result fires and the
            -- user sees the panel open, sequence:
            --   1. Settle (see the Spellbook tab open)
            --   2. Clean up: hide cursor, close opened windows, clear
            --      search text so the screen is clean
            --   3. Show transition banner
            --   4. Pause so the user can read it
            --   5. Done → step 5 picks up
            function(done)
                ensureMode(true)
                local target = findResultRowByName("Spellbook") or findFirstResultRow() or searchFrame.editBox
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        UI:SelectResult(spellbookEntry)
                        safeAfter(1.5, function()
                            -- Move cursor to the close button on PlayerSpellsFrame
                            -- and fake-click it, then close the window.
                            local psf = _G["PlayerSpellsFrame"]
                            local closeBtn = psf and (psf.ClosePanelButton or psf.CloseButton)
                            if closeBtn and closeBtn:IsShown() then
                                moveCursorTo(closeBtn, CURSOR_MOVE, function()
                                    clickAnim(function()
                                        setHoveredRow(nil)
                                        stopBlinkCursor()
                                        searchFrame.editBox:SetText("")
                                        UI:OnSearchTextChanged("")
                                        if ns.Highlight and ns.Highlight.ClearAll then
                                            pcall(ns.Highlight.ClearAll, ns.Highlight)
                                        end
                                        resetPlayerSpellsFrame()
                                        safeAfter(1.0, function()
                                            transitionText:Show()
                                            beginSectionTransition(2)
                                            safeAfter(3.5, done)
                                        end)
                                    end)
                                end)
                            else
                                setHoveredRow(nil)
                                stopBlinkCursor()
                                searchFrame.editBox:SetText("")
                                UI:OnSearchTextChanged("")
                                if ns.Highlight and ns.Highlight.ClearAll then
                                    pcall(ns.Highlight.ClearAll, ns.Highlight)
                                end
                                resetPlayerSpellsFrame()
                                safeAfter(1.0, function()
                                    transitionText:Show()
                                    beginSectionTransition(2)
                                    safeAfter(2.0, done)
                                end)
                            end
                        end)
                    end)
                end)
            end,
            -- 4: Switch to Guide Mode (hover with tooltip + highlight,
            -- click, show updated tooltip so the user sees the change).
            -- Tooltip/highlight persist until the cursor moves to the
            -- next target (clearButtonHover runs at the start of
            -- moveCursorTo).
            function(done)
                transitionText:Hide()
                ensureMode(true)
                local mb = searchFrame.modeBtn
                moveCursorTo(mb, CURSOR_MOVE, function()
                    if mb.btnBg then mb.btnBg:Show() end
                    if mb.LockHighlight then mb:LockHighlight() end
                    GameTooltip:SetOwner(mb, "ANCHOR_BOTTOM")
                    GameTooltip:SetText("Fast Mode")
                    GameTooltip:AddLine("Click to switch to step-by-step Guide Mode.", 1, 1, 1, true)
                    GameTooltip:Show()
                    safeAfter(1.0, function()
                        clickAnim(function()
                            EasyFind.db.directOpen = false
                            if ns.UpdateModeButtonVisual then
                                pcall(ns.UpdateModeButtonVisual, mb)
                            end
                            GameTooltip:SetText("Guide Mode")
                            GameTooltip:AddLine("Click to enable Fast Mode (opens panels directly).", 1, 1, 1, true)
                            GameTooltip:Show()
                            safeAfter(0.8, done)
                        end)
                    end)
                end, MODE_BTN_OFFSET_X, MODE_BTN_OFFSET_Y)
            end,
            -- 5: Start typing "sp" in Guide Mode
            function(done)
                uis_stepFocusAndType("sp", false, done)
            end,
            -- 6: Click the Spellbook result (fires real Highlight)
            function(done)
                ensureMode(false)
                local target = findResultRowByName("Spellbook") or findFirstResultRow() or searchFrame.editBox
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        UI:SelectResult(spellbookEntry)
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end,
            -- 7: Click the Player Spells micro button (real Highlight arrow showing)
            function(done)
                ensureMode(false)
                local microBtn = _G["PlayerSpellsMicroButton"]
                if not microBtn then done(); return end
                moveCursorTo(microBtn, CURSOR_MOVE, function()
                    clickAnim(function()
                        if not InCombatLockdown() then
                            pcall(ShowUIPanel, _G["PlayerSpellsFrame"])
                        end
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end,
            -- 8: Click the Spellbook tab (tab 3), then after a settle
            -- move the cursor to the close button, click it, close the
            -- window, and hide the cursor to end the demo cleanly.
            function(done)
                ensureMode(false)
                local tab
                local psf = _G["PlayerSpellsFrame"]
                if psf and psf.TabSystem and psf.TabSystem.tabs then
                    tab = psf.TabSystem.tabs[3]
                end
                if not tab then tab = _G["PlayerSpellsFrameTab3"] end
                if not tab then done(); return end
                moveCursorTo(tab, CURSOR_MOVE, function()
                    clickAnim(function()
                        if tab.Click then pcall(tab.Click, tab) end
                        safeAfter(SETTLE_PAUSE + 1.0, function()
                            local closeBtn = psf and (psf.ClosePanelButton or psf.CloseButton)
                            if closeBtn and closeBtn:IsShown() then
                                moveCursorTo(closeBtn, CURSOR_MOVE, function()
                                    clickAnim(function()
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
                                    end)
                                end)
                            else
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
                        end)
                    end)
                end)
            end,
        }
        demoSteps = DEMOS.uiSearch.run

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

        -- Helper: ensure the global map search mode toggle is in the
        -- expected state and update its visual.
        local function ensureGlobalMapMode(wantFast)
            if EasyFind.db.globalMapDirectOpen ~= wantFast then
                EasyFind.db.globalMapDirectOpen = wantFast
                if ns.MapSearch and ns.MapSearch.UpdateMapModeBtns then
                    pcall(ns.MapSearch.UpdateMapModeBtns, ns.MapSearch)
                end
            end
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

        -- Recursive navigation clicker for Guide Mode: checks if the
        -- waypoint pin is visible (meaning we arrived at the final
        -- destination). If not, looks for either a breadcrumb button in
        -- the nav bar OR a zone indicator on the map canvas, clicks it,
        -- and recurses. Caps at 10 iterations to prevent infinite loops.
        local function clickBreadcrumbsUntilArrived(done, depth)
            depth = (depth or 0) + 1
            if depth > 10 then done(); return end
            safeAfter(0.6, function()
                -- Have we arrived? Waypoint pin visible = destination.
                local pin = _G["EasyFindLocationPin"]
                if pin and pin:IsShown() then
                    done()
                    return
                end
                -- Priority 1: breadcrumb highlight in the nav bar.
                local bcHL = _G["EasyFindBreadcrumbHighlight"]
                if bcHL and bcHL:IsShown() then
                    moveCursorTo(bcHL, CURSOR_MOVE, function()
                        clickAnim(function()
                            local _, relTo = bcHL:GetPoint(1)
                            if relTo and relTo.Click then
                                pcall(relTo.Click, relTo)
                            end
                            clickBreadcrumbsUntilArrived(done, depth)
                        end)
                    end)
                    return
                end
                -- Priority 2: zone indicator arrow on the map canvas.
                -- This appears when the target zone is highlighted on the
                -- current map and the user needs to click it to zoom in.
                -- The arrow is anchored next to the zone in one of four
                -- directions (down/up/right/left) — read indicatorDirection
                -- to push the cursor PAST the arrow into the zone itself,
                -- not onto the arrow's tip.
                local zoneInd = _G["EasyFindZoneIndicator"]
                if zoneInd and zoneInd:IsShown() then
                    local dx, dy = 0, -75  -- default: arrow above zone, cursor goes down
                    local dir = zoneInd.indicatorDirection
                    if dir == "up" then
                        dx, dy = 0, 75
                    elseif dir == "right" then
                        dx, dy = 75, 0
                    elseif dir == "left" then
                        dx, dy = -75, 0
                    end
                    moveCursorTo(zoneInd, CURSOR_MOVE, function()
                        clickAnim(function()
                            if ns.MapSearch and ns.MapSearch.pendingZoneHighlight then
                                pcall(WorldMapFrame.SetMapID, WorldMapFrame,
                                    ns.MapSearch.pendingZoneHighlight)
                            end
                            clickBreadcrumbsUntilArrived(done, depth)
                        end)
                    end, dx, dy)
                    return
                end
                -- Neither visible yet, wait and retry.
                clickBreadcrumbsUntilArrived(done, depth)
            end)
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

        function msz.openMap(fast, done)
            if InCombatLockdown() then done(); return end
            ensureGlobalMapMode(fast)
            openWorldMap()
            safeAfter(0.8, done)
        end

        function msz.clickNexus(fast, done)
            ensureGlobalMapMode(fast)
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

        function msz.switchToGuide(done)
            ensureGlobalMapMode(true)
            local gsf = _G["EasyFindMapGlobalSearchFrame"]
            local mb = gsf and gsf.modeBtn
            if not mb then done(); return end
            moveCursorTo(mb, CURSOR_MOVE, function()
                if mb.btnBg then mb.btnBg:Show() end
                if mb.LockHighlight then mb:LockHighlight() end
                GameTooltip:SetOwner(mb, "ANCHOR_TOP")
                GameTooltip:SetText("Fast Mode")
                GameTooltip:AddLine("Click to switch to Guide mode.", 1, 1, 1, true)
                GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
                GameTooltip:Show()
                safeAfter(1.0, function()
                    clickAnim(function()
                        EasyFind.db.globalMapDirectOpen = false
                        if ns.MapSearch and ns.MapSearch.UpdateMapModeBtns then
                            pcall(ns.MapSearch.UpdateMapModeBtns, ns.MapSearch)
                        end
                        GameTooltip:SetText("Guide Mode")
                        GameTooltip:AddLine("Click to switch to Fast mode.", 1, 1, 1, true)
                        GameTooltip:AddLine("Hold |cFF00FF00Shift|r and drag to reposition.", 0.7, 0.7, 0.7)
                        GameTooltip:Show()
                        safeAfter(0.8, done)
                    end)
                end)
            end, MODE_BTN_OFFSET_X, MODE_BTN_OFFSET_Y)
        end

        DEMOS.mapSearchZone.rebuild = function(def)
            -- Capture the user's saved global mode so restoreUserSettings
            -- reverts any flips the run/setupAfter make to the saved value.
            savedGlobalMapDirectOpen = EasyFind.db.globalMapDirectOpen
            local isFast = demoModeFast["mapSearchZone"] ~= false
            if isFast then
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
                    function(done) msz.openMap(true, done) end,
                    function(done) ensureGlobalMapMode(true); msz.stepFocusAndType("nex", done) end,
                    function(done) msz.clickNexus(true, done) end,
                    msz.finish,
                }
                def.setupAfter = {
                    function() ensureGlobalMapMode(true); openWorldMap() end,
                    function()
                        ensureGlobalMapMode(true); openWorldMap()
                        if ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                            pcall(ns.MapSearch.RunGlobalSearch, ns.MapSearch, "nex")
                        end
                    end,
                    function() ensureGlobalMapMode(true); openWorldMap() end,
                    function() resetMapSearchState(); closeWorldMap() end,
                }
            else
                def.stepDefs = {
                    { text = "Open the world map",            section = 1 },
                    { text = "Switch to Guide Mode",          section = 1 },
                    { text = 'Start typing "The Nexus"',      section = 1 },
                    { text = "Click The Nexus result",        section = 1 },
                    { text = "Follow the breadcrumbs",        section = 1 },
                    { text = "Hover over to clear highlight", section = 1 },
                }
                def.sections = {
                    { header = "", section = 1, firstStep = 1, lastStep = 6 },
                }
                def.run = {
                    function(done) msz.openMap(true, done) end,
                    msz.switchToGuide,
                    function(done) ensureGlobalMapMode(false); msz.stepFocusAndType("nex", done) end,
                    function(done) msz.clickNexus(false, done) end,
                    function(done) clickBreadcrumbsUntilArrived(done) end,
                    msz.finish,
                }
                def.setupAfter = {
                    function() ensureGlobalMapMode(true); openWorldMap() end,
                    function() ensureGlobalMapMode(false); openWorldMap() end,
                    function()
                        ensureGlobalMapMode(false); openWorldMap()
                        if ns.MapSearch and ns.MapSearch.RunGlobalSearch then
                            pcall(ns.MapSearch.RunGlobalSearch, ns.MapSearch, "nex")
                        end
                    end,
                    function() ensureGlobalMapMode(false); openWorldMap() end,
                    function() ensureGlobalMapMode(false); openWorldMap() end,
                    function() resetMapSearchState(); closeWorldMap() end,
                }
            end
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

        local function ensureLocalMapMode(wantFast)
            if EasyFind.db.localMapDirectOpen ~= wantFast then
                EasyFind.db.localMapDirectOpen = wantFast
                if ns.MapSearch and ns.MapSearch.UpdateMapModeBtns then
                    pcall(ns.MapSearch.UpdateMapModeBtns, ns.MapSearch)
                end
            end
        end

        -- Hover the local map search mode button, show tooltip, click
        -- to toggle if needed. Mirrors hoverModeButton for the UI bar.
        local function hoverLocalMapModeBtn(wantFast, done)
            local lsf = _G["EasyFindMapSearchFrame"]
            local mb = lsf and lsf.modeBtn
            if not mb then ensureLocalMapMode(wantFast); done(); return end
            moveCursorTo(mb, CURSOR_MOVE, function()
                if mb.btnBg then mb.btnBg:Show() end
                if mb.LockHighlight then mb:LockHighlight() end
                GameTooltip:SetOwner(mb, "ANCHOR_BOTTOM")
                local currentFast = EasyFind.db.localMapDirectOpen
                local function showTargetTooltip()
                    if wantFast then
                        GameTooltip:SetText("Fast Mode")
                        GameTooltip:AddLine("Clicking a result auto-tracks on the minimap.", 1, 1, 1, true)
                    else
                        GameTooltip:SetText("Guide Mode")
                        GameTooltip:AddLine("Clicking a result shows a pin you can click to track.", 1, 1, 1, true)
                    end
                    GameTooltip:Show()
                end
                if currentFast ~= wantFast then
                    -- Wrong mode: show current, pause, click to toggle
                    if currentFast then
                        GameTooltip:SetText("Fast Mode")
                    else
                        GameTooltip:SetText("Guide Mode")
                    end
                    GameTooltip:Show()
                    safeAfter(1.0, function()
                        clickAnim(function()
                            ensureLocalMapMode(wantFast)
                            showTargetTooltip()
                            safeAfter(1.0, done)
                        end)
                    end)
                else
                    showTargetTooltip()
                    safeAfter(1.2, done)
                end
            end)
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

        -- Bouncing tutorial-style arrow anchored under the callout text,
        -- pointing up at the text so the user notices it. Uses the same
        -- indicator texture as the tutorial Highlight engine, following
        -- the user's selected style and color.
        local minimapArrowFrame = CreateFrame("Frame", nil, UIParent)
        minimapArrowFrame:SetFrameStrata("TOOLTIP")
        minimapArrowFrame:SetFrameLevel(1001)
        local ARROW_SIZE = ns.ICON_SIZE or 48
        minimapArrowFrame:SetSize(ARROW_SIZE, ARROW_SIZE)
        minimapArrowFrame:SetIgnoreParentAlpha(true)
        -- Sits directly below the callout text.
        -- Sit directly against the minimap's left edge, just below the
        -- callout text vertically, so the arrow is visibly next to what
        -- it's pointing at. Falls back to the callout anchor if the
        -- minimap isn't available.
        if _G["Minimap"] then
            minimapArrowFrame:SetPoint("RIGHT", _G["Minimap"], "LEFT", -4, -20)
        else
            minimapArrowFrame:SetPoint("TOP", minimapCalloutFrame, "BOTTOM", 0, -4)
        end

        local minimapArrowTex = minimapArrowFrame:CreateTexture(nil, "ARTWORK")
        minimapArrowTex:SetAllPoints()

        -- Apply current indicator style/color on show, and rotate so
        -- the arrow points RIGHT toward the minimap (the minimap is to
        -- the right of the callout text, and this arrow sits under the
        -- text). CreateIndicatorTextures' `style.rotation` field (or
        -- the preRotated vs not-preRotated default) is the rotation
        -- that makes the texture point DOWN in tutorial mode; adding
        -- pi/2 rotates CCW 90 degrees, taking "down" to "right".
        local function refreshMinimapArrowStyle()
            local style = ns.GetIndicatorTexture and ns.GetIndicatorTexture()
                or { texture = "Interface\\AddOns\\EasyFind\\Images\\arrow-hq", preRotated = true }
            local color = ns.GetIndicatorColor and ns.GetIndicatorColor()
                or { 1.0, 0.82, 0.0 }
            minimapArrowTex:SetTexture(style.texture)
            if style.texCoord then
                minimapArrowTex:SetTexCoord(unpack(style.texCoord))
            else
                minimapArrowTex:SetTexCoord(0, 1, 0, 1)
            end
            minimapArrowTex:SetVertexColor(color[1], color[2], color[3], 1)
            local pointsDown
            if style.rotation then
                pointsDown = style.rotation
            elseif style.preRotated then
                pointsDown = 0
            else
                pointsDown = math.pi
            end
            minimapArrowTex:SetRotation(pointsDown + math.pi / 2)
        end
        minimapArrowFrame:HookScript("OnShow", refreshMinimapArrowStyle)
        minimapArrowFrame:Hide()

        -- Bounce horizontally toward the minimap. Same BOUNCE pattern as
        -- Highlight.lua's tutorial indicator, just sideways so the
        -- motion reinforces the pointing direction.
        local minimapArrowAG = minimapArrowFrame:CreateAnimationGroup()
        minimapArrowAG:SetLooping("BOUNCE")
        local arrowBounce = minimapArrowAG:CreateAnimation("Translation")
        arrowBounce:SetOffset(10, 0)
        arrowBounce:SetDuration(0.4)

        -- Attach real methods to the forward-declared minimapArrow table
        -- so upvalues in endDemo / cancelInFlight / resetDemoGameState
        -- see the live implementation.
        function minimapArrow:Show()
            minimapArrowFrame:Show()
            minimapArrowAG:Play()
        end
        function minimapArrow:Hide()
            minimapArrowAG:Stop()
            minimapArrowFrame:Hide()
        end
        function minimapArrow:SetPaused(isPaused)
            if not minimapArrowFrame:IsShown() then return end
            if isPaused then
                minimapArrowAG:Pause()
            else
                minimapArrowAG:Play()
            end
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
        -- Current Zone Map Search: rebuilds based on demoModeFast so
        -- the toggle button on the demo panel can flip between Fast
        -- and Guide variants without touching the user's saved
        -- localMapDirectOpen setting.
        ----------------------------------------------------------------
        -- All current-zone-map-search step functions live on a single
        -- table so this huge parent function only consumes one local
        -- for the whole bundle. `wantFast` params are the demo's
        -- desired mode (from demoModeFast), NOT the user's saved
        -- setting; each helper flips ensureLocalMapMode before its
        -- action so SelectResult / auto-track behave correctly.
        local msc = {}

        function msc.openMap(wantFast, done)
            if InCombatLockdown() then done(); return end
            ensureLocalMapMode(wantFast)
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

        function msc.clickResult(wantFast, done)
            ensureLocalMapMode(wantFast)
            local lastPOI = msc.lastBrowsePOI
            local target = (lastPOI and findMapResultByName(lastPOI.name))
                or findFirstVisibleMapResult()
            if not target then
                safeAfter(0.5, done)
                return
            end
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
                    if wantFast then
                        safeAfter(SETTLE_PAUSE, function()
                            minimapCallout:SetText("Notice how your target is now automatically tracked!")
                            minimapCallout:Show()
                            minimapArrow:Show()
                            moveCursorTo(minimapCalloutFrame, CURSOR_MOVE, function()
                                safeAfter(2.5, function()
                                    minimapCallout:Hide()
                                    minimapArrow:Hide()
                                    closeMapAndFinish(done)
                                end)
                            end, 0, -45)
                        end)
                    else
                        safeAfter(SETTLE_PAUSE, done)
                    end
                end)
            end)
        end

        function msc.clickPinTrackContinue(done)
            mapSearchCallout:SetText("Click the pin to place a waypoint and start tracking.")
            mapSearchCallout:Show()
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
                    end, 0, -45)
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
            local pois = ns.MapSearch:GetStaticLocations()
            if not pois then return {} end
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

        function msc.hoverSearchPreview(query, displayName, narration, isFirstVisit, keepPreview, done)
            local lsf = _G["EasyFindMapSearchFrame"]
            local editBox = lsf and lsf.editBox
            if not editBox then done(); return end
            local function afterFocus()
                backspaceMapTextKeepCaret(editBox, TYPE_DELAY, function()
                    typeMapTextKeepCaret(editBox, query, TYPE_DELAY, function()
                        safeAfter(SETTLE_PAUSE, function()
                            local row = findMapResultByName(displayName) or findFirstVisibleMapResult()
                            if not row then done(); return end
                            -- Tag the row so setHoveredRow fires OnEnter/OnLeave
                            -- in sync with the highlight (same placeCursorAt frame).
                            row._demoMapHover = true
                            moveCursorTo(row, CURSOR_MOVE, function()
                                mapSearchCallout:SetText(narration)
                                mapSearchCallout:Show()
                                safeAfter(2.2, function()
                                    if keepPreview then
                                        -- Leave _demoMapHover set so the preview
                                        -- persists until clickResult clears it.
                                        done()
                                    else
                                        -- Clear the tag; setHoveredRow will fire
                                        -- OnLeave when the cursor moves away.
                                        done()
                                    end
                                end)
                            end)
                        end)
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
            local function nextOne()
                idx = idx + 1
                if idx > #picks then
                    msc.lastBrowsePOI = picks[#picks]
                    mapSearchCallout:Hide()
                    done()
                    return
                end
                local poi = picks[idx]
                local query = slower(poi.name):sub(1, 3)
                local isLast = idx == #picks
                msc.hoverSearchPreview(query, poi.name, "Hovering over a result shows it on the map.", idx == 1, isLast, nextOne)
            end
            nextOne()
        end

        DEMOS.mapSearchCurrent.rebuild = function(def)
            msc.lastBrowsePOI = nil
            -- Capture the user's CURRENT mode as the snapshot so
            -- restoreUserSettings (which runs after rebuild) reverts
            -- any flips the demo's run/setupAfter make to the saved
            -- value. Demo's own fast/guide selection comes from
            -- demoModeFast, NOT the user's saved setting.
            savedLocalMapDirectOpen = EasyFind.db.localMapDirectOpen
            local isFast = demoModeFast["mapSearchCurrent"] ~= false
            local hasBrowse = #msc.pickDiversePOIs() > 0
            local openSnap = function()
                ensureLocalMapMode(isFast); openWorldMapToPlayerZone()
            end
            -- Snap to end-of-browse: map open with the last POI query
            -- typed and results visible, ready for "Click a result".
            local browseSnap = function()
                ensureLocalMapMode(isFast); openWorldMapToPlayerZone()
                local picks = msc.pickDiversePOIs()
                if #picks > 0 then
                    msc.lastBrowsePOI = picks[#picks]
                    local query = slower(picks[#picks].name):sub(1, 3)
                    if ns.MapSearch and ns.MapSearch.RunLocalSearch then
                        ns.MapSearch:RunLocalSearch(query)
                    end
                end
            end
            local doneSnap = function()
                clearDemoWaypoint(); resetMapSearchState(); closeWorldMap()
            end
            local modeLabel = isFast
                and "Make sure Fast Mode is enabled"
                or "Make sure Guide Mode is enabled"
            local modeStep = function(done) hoverLocalMapModeBtn(isFast, done) end
            if isFast then
                if hasBrowse then
                    def.stepDefs = {
                        { text = "Open the world map",       section = 1 },
                        { text = modeLabel,                  section = 1 },
                        { text = "Browse what's around",     section = 1 },
                        { text = "Click a result",           section = 1 },
                    }
                    def.sections = { { header = "", section = 1, firstStep = 1, lastStep = 4 } }
                    def.run = {
                        function(done) msc.openMap(true, done) end,
                        modeStep,
                        msc.browseWhatsAround,
                        function(done) msc.clickResult(true, done) end,
                    }
                    def.setupAfter = { openSnap, openSnap, browseSnap, doneSnap }
                else
                    def.disabled = true
                    def.disabledMessage = "No searchable POIs in this zone."
                end
            else
                if hasBrowse then
                    def.stepDefs = {
                        { text = "Open the world map",                       section = 1 },
                        { text = modeLabel,                                  section = 1 },
                        { text = "Browse what's around",                     section = 1 },
                        { text = "Click a result",                           section = 1 },
                        { text = "Click the pin to start tracking",          section = 1 },
                        { text = "Search again",                             section = 1 },
                        { text = "Click the nav pin to auto-track instead",  section = 1 },
                        { text = "Now you're tracking it on the minimap!",   section = 1 },
                    }
                    def.sections = { { header = "", section = 1, firstStep = 1, lastStep = 8 } }
                    def.run = {
                        function(done) msc.openMap(false, done) end,
                        modeStep,
                        msc.browseWhatsAround,
                        function(done) msc.clickResult(false, done) end,
                        msc.clickPinTrackContinue,
                        msc.retypeLastBrowse,
                        msc.clickNavBtnAutoTrack,
                        msc.minimapHintAndClose,
                    }
                    def.setupAfter = { openSnap, openSnap, browseSnap, openSnap, openSnap, browseSnap, openSnap, doneSnap }
                else
                    def.disabled = true
                    def.disabledMessage = "No searchable POIs in this zone."
                end
            end
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

        -- Combined filter steps: open filter → enable Map Search → confirm
        -- Local, all chained as a single demo step.
        function msui.enableLocalFilter(done)
            msui.stepFilterBtnClick(function()
                msui.openFilterDropdown()
                safeAfter(STEP_PAUSE, function()
                    msui.ensureMapFilterEnabled()
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
                end)
            end)
        end

        -- Combined filter steps: open filter → switch to Global.
        function msui.switchToGlobalFilter(done)
            msui.stepFilterBtnClick(function()
                msui.openFilterDropdown()
                safeAfter(STEP_PAUSE, function()
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

        -- After HandleUISearchClick has started a guide in standard mode,
        -- the EasyFind highlighter draws on QuestLogMicroButton. Wait
        -- briefly for the highlight to appear, then click the button to
        -- open the world map. The pending navigation registered by
        -- HandleUISearchClick fires when WorldMapFrame becomes visible.
        function msui.clickQuestLogMicroBtn(done)
            local btn = _G["QuestLogMicroButton"]
            if not btn then done(); return end
            safeAfter(0.6, function()
                moveCursorTo(btn, CURSOR_MOVE, function()
                    clickAnim(function()
                        if btn.Click then pcall(btn.Click, btn) end
                        -- Wait for map fade-in + pending navigation +
                        -- pin placement.
                        safeAfter(1.6, done)
                    end)
                end)
            end)
        end

        -- Click the EasyFindLocationPin to set a SuperTrack waypoint
        -- on it (the pin's OnMouseUp handler does this for left-click
        -- when the player is on the same map). Also fires the OnMouseUp
        -- script directly so the click registers even though the demo's
        -- click blocker eats real mouse events.
        function msui.clickLocalPin(done)
            local pin = _G["EasyFindLocationPin"]
            if not pin or not pin:IsShown() then
                safeAfter(0.5, done)
                return
            end
            moveCursorTo(pin, CURSOR_MOVE, function()
                clickAnim(function()
                    local handler = pin:GetScript("OnMouseUp")
                    if handler then pcall(handler, pin, "LeftButton") end
                    safeAfter(SETTLE_PAUSE, done)
                end)
            end)
        end

        local mapSearchUI_fastRun = {
            ----------------------------------------------------------------
            -- SECTION 1: Local Map POI search (flight master)
            ----------------------------------------------------------------
            -- 1: Make sure Fast Mode is enabled
            function(done) hoverModeButton(done) end,
            -- 2: Enable Local Map Search filter
            function(done) msui.enableLocalFilter(done) end,
            -- 3: Type "fli"
            function(done) msui.stepFocusAndType("fli", done) end,
            -- 6: Click the Flight Master result. Fast Mode places the
            -- waypoint directly (no map opens). Minimap hint, then
            -- transition to Global section.
            function(done)
                local target = msui.findResultRowByPartialName("flight master")
                if not target then
                    safeAfter(0.5, done)
                    return
                end
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        stopBlinkCursor()
                        if target.data and ns.MapSearch and ns.MapSearch.HandleUISearchClick then
                            pcall(ns.MapSearch.HandleUISearchClick, ns.MapSearch, target.data)
                        end
                        minimapCallout:SetText("Notice how your target is now automatically tracked!")
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
                end)
            end,
            ----------------------------------------------------------------
            -- SECTION 2: Global zone search (Eastern Plaguelands)
            ----------------------------------------------------------------
            -- 5: Enable Global Map Search filter
            function(done)
                transitionText:Hide()
                msui.switchToGlobalFilter(done)
            end,
            -- 6: Type "eas"
            function(done) msui.stepFocusAndType("eas", done) end,
            -- 10: Click the Eastern Plaguelands result. Strict name
            -- match: no fallback to first result. Fast Mode with a
            -- global zone result opens the map and navigates to the
            -- zone.
            function(done)
                local target = msui.findResultRowByPartialName("eastern plaguelands")
                if not target then
                    safeAfter(0.5, done)
                    return
                end
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        stopBlinkCursor()
                        if target.data and ns.MapSearch and ns.MapSearch.HandleUISearchClick then
                            pcall(ns.MapSearch.HandleUISearchClick, ns.MapSearch, target.data)
                        end
                        safeAfter(SETTLE_PAUSE + 1.5, function()
                            searchFrame.editBox:SetText("")
                            UI:OnSearchTextChanged("")
                            if searchFrame.editBox.placeholder then
                                searchFrame.editBox.placeholder:Show()
                            end
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
                    end)
                end)
            end,
        }

        -- Common "directOpen + map filter enabled, local/global" baseline
        -- every mapSearchUI setupAfter builds on. Reads demoModeFast so
        -- the same baseline reuses across both fast and guide variants.
        function msui.baseline(isLocal)
            EasyFind.db.directOpen = (demoModeFast["mapSearchUI"] ~= false)
            if ns.UpdateModeButtonVisual then
                pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
            end
            msui.ensureMapFilterEnabled()
            msui.setMapSubLocal(isLocal)
        end

        local mapSearchUI_fastSetupAfter = {
            -- 1: Fast mode enabled
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 2: Local filter enabled
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 3: "fli" typed
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("fli")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                UI:OnSearchTextChanged("fli")
                startBlinkCursor()
            end,
            -- 4: Flight master clicked, waypoint placed
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                clearDemoWaypoint()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
            end,
            -- 5: Global filter enabled
            function() msui.baseline(false); msui.closeFilterDropdown() end,
            -- 6: "eas" typed
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("eas")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                UI:OnSearchTextChanged("eas")
                startBlinkCursor()
            end,
            -- 7: Eastern Plaguelands clicked, map closed
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                clearDemoWaypoint()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
                resetMapSearchState(); closeWorldMap()
            end,
        }

        local mapSearchUI_fastStepDefs = {
            { text = "Make sure Fast Mode is enabled",          section = 1 },  -- 1
            { text = "Enable Local Map Search filter",          section = 1 },  -- 2
            { text = 'Start typing "Flight Master"',            section = 1 },  -- 3
            { text = "Click the Flight Master result",          section = 1 },  -- 4
            { text = "Enable Global Map Search filter",         section = 2 },  -- 5
            { text = 'Start typing "Eastern Plaguelands"',      section = 2 },  -- 6
            { text = "Click the Eastern Plaguelands result",    section = 2 },  -- 7
        }
        local mapSearchUI_fastSections = {
            { header = "Local Map POI search: Flight Master", section = 1, firstStep = 1, lastStep = 4 },
            { header = "Global zone search: Eastern Plaguelands", section = 2, firstStep = 5, lastStep = 7 },
        }

        -- Guide-mode variant: clicking a result triggers HandleUISearchClick's
        -- guide branch (StartGuide + SetPendingNavigation), so the demo
        -- has additional steps to walk through the guide: click the
        -- highlighted QuestLogMicroButton, follow any breadcrumbs, then
        -- click the destination pin to track.
        local mapSearchUI_guideStepDefs = {
            { text = "Make sure Guide Mode is enabled",                section = 1 },  -- 1
            { text = "Enable Local Map Search filter",                 section = 1 },  -- 2
            { text = 'Start typing "Flight Master"',                   section = 1 },  -- 3
            { text = "Click the Flight Master result",                 section = 1 },  -- 4
            { text = "Click the highlighted Quest Log button",         section = 1 },  -- 5
            { text = "Click the flight master pin to track",           section = 1 },  -- 6
            { text = "Enable Global Map Search filter",                section = 2 },  -- 7
            { text = 'Start typing "Eastern Plaguelands"',             section = 2 },  -- 8
            { text = "Click the Eastern Plaguelands result",           section = 2 },  -- 9
            { text = "Click the highlighted Quest Log button",         section = 2 },  -- 10
            { text = "Follow the breadcrumbs to the zone",             section = 2 },  -- 11
        }
        local mapSearchUI_guideSections = {
            { header = "Local Map POI search: Flight Master",   section = 1, firstStep = 1, lastStep = 6 },
            { header = "Global zone search: Eastern Plaguelands", section = 2, firstStep = 7, lastStep = 11 },
        }

        local mapSearchUI_guideRun = {
            -- 1: Switch to Guide Mode
            function(done) hoverModeButtonToGuide(done) end,
            -- 2: Enable Local Map Search filter
            function(done) msui.enableLocalFilter(done) end,
            -- 3: Type "fli"
            function(done) msui.stepFocusAndType("fli", done) end,
            -- 6: Click result (HandleUISearchClick → guide starts)
            function(done)
                local target = msui.findResultRowByPartialName("flight master")
                if not target then
                    safeAfter(0.5, done)
                    return
                end
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        stopBlinkCursor()
                        if target.data and ns.MapSearch and ns.MapSearch.HandleUISearchClick then
                            pcall(ns.MapSearch.HandleUISearchClick, ns.MapSearch, target.data)
                        end
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end,
            -- 7: Click highlighted Quest Log button → opens map
            function(done) msui.clickQuestLogMicroBtn(done) end,
            -- 8: Click pin to track → minimap hint → transition
            function(done)
                msui.clickLocalPin(function()
                    minimapCallout:SetText("Check your minimap: your target is now tracked!")
                    showMinimapHint(function()
                        minimapCallout:Hide()
                        minimapArrow:Hide()
                        clearDemoWaypoint()
                        local closeBtn = getMapCloseBtn()
                        local function finish()
                            resetMapSearchState()
                            closeWorldMap()
                            searchFrame.editBox:SetText("")
                            UI:OnSearchTextChanged("")
                            if searchFrame.editBox.placeholder then
                                searchFrame.editBox.placeholder:Show()
                            end
                            safeAfter(0.8, function()
                                transitionFS:SetText("Now let's try a global zone search to find Eastern Plaguelands.")
                                transitionText:Show()
                                beginSectionTransition(2)
                                safeAfter(3.5, done)
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
            -- 7: Enable Global Map Search filter
            function(done)
                transitionText:Hide()
                msui.switchToGlobalFilter(done)
            end,
            -- 8: Type "eas"
            function(done) msui.stepFocusAndType("eas", done) end,
            -- 12: Click result (guide starts)
            function(done)
                local target = msui.findResultRowByPartialName("eastern plaguelands")
                if not target then
                    safeAfter(0.5, done)
                    return
                end
                moveCursorTo(target, CURSOR_MOVE, function()
                    clickAnim(function()
                        stopBlinkCursor()
                        if target.data and ns.MapSearch and ns.MapSearch.HandleUISearchClick then
                            pcall(ns.MapSearch.HandleUISearchClick, ns.MapSearch, target.data)
                        end
                        safeAfter(SETTLE_PAUSE, done)
                    end)
                end)
            end,
            -- 13: Click highlighted Quest Log button → opens map
            function(done) msui.clickQuestLogMicroBtn(done) end,
            -- 14: Follow breadcrumbs to the zone, then close the map
            function(done)
                clickBreadcrumbsUntilArrived(function()
                    safeAfter(1.5, function()
                        local closeBtn = getMapCloseBtn()
                        local function finish()
                            resetMapSearchState()
                            closeWorldMap()
                            searchFrame.editBox:SetText("")
                            UI:OnSearchTextChanged("")
                            if searchFrame.editBox.placeholder then
                                searchFrame.editBox.placeholder:Show()
                            end
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

        local mapSearchUI_guideSetupAfter = {
            -- 1: Guide mode enabled
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 2: Local filter enabled
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 3: "fli" typed
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("fli")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Hide() end
                UI:OnSearchTextChanged("fli")
                startBlinkCursor()
            end,
            -- 4: Result clicked, guide started
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then
                    searchFrame.editBox.placeholder:Show()
                end
            end,
            -- 5: QuestLogMicroButton clicked, map open
            function() msui.baseline(true); msui.closeFilterDropdown() end,
            -- 6: Pin clicked, tracked, map closed (section 1 end)
            function()
                msui.baseline(true); msui.closeFilterDropdown()
                clearDemoWaypoint(); resetMapSearchState(); closeWorldMap()
            end,
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
            -- 9: Result clicked, guide started
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                searchFrame.editBox:SetText("")
                UI:OnSearchTextChanged("")
                if searchFrame.editBox.placeholder then searchFrame.editBox.placeholder:Show() end
            end,
            -- 10: QuestLogMicroButton clicked, map open
            function() msui.baseline(false); msui.closeFilterDropdown() end,
            -- 11: Breadcrumbs followed, map closed (final)
            function()
                msui.baseline(false); msui.closeFilterDropdown()
                resetMapSearchState(); closeWorldMap()
            end,
        }

        DEMOS.mapSearchUI.rebuild = function(def)
            savedDirectOpen = EasyFind.db.directOpen
            local isFast = demoModeFast["mapSearchUI"] ~= false
            if isFast then
                def.stepDefs   = mapSearchUI_fastStepDefs
                def.sections   = mapSearchUI_fastSections
                def.run        = mapSearchUI_fastRun
                def.setupAfter = mapSearchUI_fastSetupAfter
            else
                def.stepDefs   = mapSearchUI_guideStepDefs
                def.sections   = mapSearchUI_guideSections
                def.run        = mapSearchUI_guideRun
                def.setupAfter = mapSearchUI_guideSetupAfter
            end
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
                                        popup:Click()
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


        DEMOS.outfits.supportsModeToggle = false

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
            local savedDirectOpen = EasyFind.db.directOpen
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
                    EasyFind.db.directOpen = savedDirectOpen
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

        DEMOS.appearanceSets.supportsModeToggle = true

        DEMOS.appearanceSets.rebuild = function(def)
            local _, _, playerClassID = UnitClass("player")
            local myArmor = CLASS_ARMOR[playerClassID]
            local altClassID
            for cid, armor in pairs(CLASS_ARMOR) do
                if armor ~= myArmor then altClassID = cid; break end
            end
            local altClassName = altClassID and (GetClassInfo(altClassID)) or "another class"
            local isFast = demoModeFast["appearanceSets"] ~= false

            def.sections = {
                { header = "Preview on your character",          section = 1, firstStep = 1, lastStep = 3 },
                { header = isFast and "Open in Collections"
                                   or "Guide to Collections",   section = 2, firstStep = 4, lastStep = 5 },
                { header = "Try " .. altClassName .. "'s armor", section = 3, firstStep = 6, lastStep = 8 },
            }
            def.stepDefs = {
                { text = "Enable Appearance Sets search",                       section = 1 },
                { text = "Start typing an appearance set name",                 section = 1 },
                { text = "Ctrl+Click to preview on your character",             section = 1 },
                { text = "Search the same set again",                           section = 2 },
                { text = isFast and "Click to open it in Collections"
                                 or "Click to start the guide",                 section = 2 },
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
                    local fast = demoModeFast["appearanceSets"] ~= false
                    asd.regularClickSet(
                        fast and "A regular click opens the set in Collections."
                             or "A regular click starts the step-by-step guide.",
                        fast, done)
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
            -- Outfit demo cleanup (arrow, ticker, right-click icon, pin)
            if od then pcall(od.cleanup) end
            if clearDemoWaypoint then pcall(clearDemoWaypoint) end
            if resetMapSearchState then pcall(resetMapSearchState) end
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
        -- cursor, and clears stray visuals left by hoverModeButton.
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
            if minimapCallout then minimapCallout:Hide() end
            if minimapArrow then minimapArrow:Hide() end
            if mapSearchCallout then mapSearchCallout:Hide() end
            animatingIdx = 0
        end

        -- setupAfterStep[i] puts the game in the end-state of step i, no
        -- animation. These are used by Previous to rewind: reset to clean
        -- slate, then call setupAfterStep[target] for the new position.
        DEMOS.uiSearch.setupAfter = {
            -- 1: Fast mode enabled
            function()
                EasyFind.db.directOpen = true
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
            end,
            -- 2: Fast mode + "sp" typed + results showing
            function()
                EasyFind.db.directOpen = true
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
                searchFrame.editBox:SetText("sp")
                UI:OnSearchTextChanged("sp")
                startBlinkCursor()
            end,
            -- 3: Fast mode, Spellbook opened then cleaned up (the run
            -- function closes its window and clears the search before
            -- calling done), so the end state is just fast mode idle.
            function()
                EasyFind.db.directOpen = true
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
            end,
            -- 4: Guide mode toggled, clean state
            function()
                EasyFind.db.directOpen = false
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
            end,
            -- 5: Guide mode + "sp" typed + results showing
            function()
                EasyFind.db.directOpen = false
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
                searchFrame.editBox:SetText("sp")
                UI:OnSearchTextChanged("sp")
                startBlinkCursor()
            end,
            -- 6: Spellbook result selected in guide mode; Highlight
            -- system is now showing its first arrow on the micro
            -- button.
            function()
                EasyFind.db.directOpen = false
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
                UI:SelectResult(spellbookEntry)
            end,
            -- 7: PlayerSpellsFrame now open, Highlight advances to tab 3
            function()
                EasyFind.db.directOpen = false
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
                UI:SelectResult(spellbookEntry)
                if not InCombatLockdown() then
                    pcall(ShowUIPanel, _G["PlayerSpellsFrame"])
                end
            end,
            -- 8: Spellbook tab (3) selected
            function()
                EasyFind.db.directOpen = false
                if ns.UpdateModeButtonVisual then
                    pcall(ns.UpdateModeButtonVisual, searchFrame.modeBtn)
                end
                UI:SelectResult(spellbookEntry)
                if not InCombatLockdown() then
                    pcall(ShowUIPanel, _G["PlayerSpellsFrame"])
                end
                local psf = _G["PlayerSpellsFrame"]
                local tab
                if psf and psf.TabSystem and psf.TabSystem.tabs then
                    tab = psf.TabSystem.tabs[3]
                end
                if not tab then tab = _G["PlayerSpellsFrameTab3"] end
                if tab and tab.Click then pcall(tab.Click, tab) end
            end,
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
            refreshModeToggle()
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
