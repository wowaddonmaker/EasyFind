# Changelog

All notable changes to EasyFind will be documented in this file.

---

## [1.2.7] - 2026-03-10

### Added
- **Keyboard Navigation**: Full arrow key, Tab, and Enter support for navigating search results without a mouse. Works in both UI search and map search bars
- **Tab Toggle Focus**: Tab/Shift+Tab toggles between a parent row and its expand/collapse button in both UI and map search results
- **Visual Rescaler**: New resize mode where you can drag handles on search bars and results panels to resize width, adjust row count, and change font size interactively. Shift+drag the search bar itself to reposition it along the map edge
- **Toggle+Focus Keybind**: New combined keybind that toggles the search bar and immediately focuses it in one keypress. Automatically targets the map search bar when the world map is open
- **Clear All Keybind**: Dedicated keybind to dismiss all highlights, map pins, zone highlights, and breadcrumbs
- **Bug Report and Feature Request**: `/ef bug` and `/ef feature` as well as buttons for each in options panel to open pre-filled GitHub issue URLs for easy reporting
- **Guide Circle Options**: New options for guide circle scale, minimap pin glow toggle, and separate minimap arrow glow toggle
- **Waypoint Options**: Auto-track new pins, auto-clear on arrival, and configurable arrival distance now in the Options panel
- **Class Trainer Category**: Class trainers now appear in map search results
- **Thunder Bluff POIs**: Added points of interest for Thunder Bluff
- **Separate Max Results**: UI search and map search now have independent max visible row counts (UI defaults to 10, map to 6)
- **Results Above**: Both UI and map search results can now be shown above the search bar for bottom-of-screen placement
- **Blizzard Pin Tracking**: Minimap glow and guide circle now work with Blizzard's own map pins (flight points, area POIs, vignettes), not just user waypoints
- **Pin Highlight Box Option**: Toggle the yellow highlight box around map pins on or off. Indicator arrow and pin icon remain visible either way
- **Map Smart Show**: Auto-hide map search bars until you hover over them, like the existing UI search Smart Show
- **Map Search Y-Offset**: New slider to adjust the vertical position of map search bars relative to the map bottom edge
- **Keyboard Preview**: Arrow keys in map search results now preview the pin location on the map before you confirm
- **Subsequence Matching**: Vowel-stripped abbreviations now match (e.g. "qtr" finds "quartermaster", "windrnr" finds "windrunner")
- **Multi-word Fuzzy Search**: Multi-word queries now match per-word with fuzzy and subsequence support (e.g. "twlght hghlnds" finds "Twilight Highlands")

### Changed
- **Indicator Arrow**: Arrow always bobs and pulses regardless of the Blinking Pins setting. Blinking Pins now only controls whether pins and highlight boxes pulse in sync
- **Blinking Pins Default**: Changed default to enabled (was disabled)
- **Filter Button Triangle**: Filter buttons show only the dropdown arrow by default; hovering reveals the full button with a blue highlight glow
- **Zone Navigation Arrows**: The arrows that guide you between maps now highlight with a shape that matches the button instead of a generic glow
- **Reputation Search**: Parent factions (e.g. "Horde Expedition") are now searchable in addition to individual reputations
- **Background Opacity**: Opacity slider now controls only the search bar background, keeping text and icons fully visible (default lowered to 0.75)
- **Options Panel**: Reorganized with Speed boxes, two-column keybinds, and tighter section spacing. Theme selector moved to General section
- **Keyword Scoring**: Short abbreviations (2-3 chars) like "bg" now boost exact keyword matches above initials matching so common abbreviations rank higher
- **Keyboard Shortcuts Text**: Reorganized into clearer "From the search box" and "From the results list" sections
- **Map Results Theme**: Map search results dropdown now matches the selected theme (Classic or Retail) and updates live on theme switch
- **Fuzzy Length Tolerance**: Queries of 6+ characters now allow 2-character length differences when fuzzy matching, reducing missed results for longer words
- **Filter Button Highlight**: Keyboard navigation now shows the filter button's own highlight style instead of an overlay rectangle

### Fixed
- **Escape from Results**: Escape now properly deselects without refocusing the search editbox. Results stay visible for re-entry
- **Stale Selection**: Clicking back into the editbox after Escape now resets the selection instead of leaving it stuck
- **Enter on Result**: Pressing Enter on a search result now closes results and unfocuses the editbox, matching click behavior
- **Enter on Toggle**: Pressing Enter on an expand/collapse toggle no longer refocuses the search bar
- **Pinned Items Navigation**: Arrow keys now work on pinned items shown from an empty focused editbox
- **Chromie Detection**: Chromie (timewalking NPC) now properly detected and included in search results with real icon
- **Zone Reguiding**: Clicking the wrong zone during step-by-step navigation now correctly reguides you back to the target instead of stopping
- **Zone Highlighting**: Fixed many zones not highlighting correctly on continent maps, including cities (Stormwind, Ironforge, etc.), remapped zones (Isle of Quel'Danas), and multi-step navigation between continents
- **Unclickable Zones**: Zones with bugged click regions (Uldum, Vale of Eternal Blossoms) now handled with fallback navigation
- **Dalaran and Dungeon-type Zones**: Fixed these zones missing from global search results
- **Instanced Zone Snap**: Fixed Vision of Stormwind/Orgrimmar and similar instanced zones snapping to wrong locations
- **Exodar/Azuremyst**: Fixed navigation trying to go backward instead of highlighting the zone directly
- **Currency/Reputation Navigation**: Fixed navigation sometimes failing when opening currencies and reputations
- **Adjacent Zone Filter**: Fixed filter incorrectly hiding some valid results like Conquest Quartermaster
- **Cross-zone Minimap Glow**: Minimap glow no longer appears for pins outside the player's current zone. Previously showed bogus arrows for pins on other continents or distant zones
- **Trailing Whitespace in Search**: Trailing spaces no longer break search scoring or category matching

### Technical Notes
- **Independent Indicator Animation**: Indicator arrow has its own Alpha animation group so it pulses independently of the parent highlight frame
- **Unified Animation Duration**: All animation durations consolidated into a single ANIM_DURATION constant
- **Atlas Zone Highlights**: Zone highlighting now supports atlas-based textures in addition to fileDataID textures
- **Shared Helpers**: Scroll, click, and frame-search patterns refactored into Utils.lua, reducing code duplication across Highlight and UI modules
- **Shared Constants**: Extracted duplicated constants (colors, sizes, string paths) into ns.* values in Utils.lua
- **Defensive Hardening**: Added pcall protection to waypoint tracker OnUpdate, flash ticker, and all initialization timers. Added SavedVariables type validation to prevent corrupted settings from breaking the addon
- **Results Layout**: Improved pin separator spacing and scroll position preservation when toggling category headers
- **Continent Projection Fallback**: Zones with very small scan areas now fall back to continent-level projection
- **Highlight Hover Timer**: Reduced minimum display time from 1.0s to 0.3s for snappier hover-dismiss behavior
- **GetScript Error**: Fixed error when calling GetScript on non-Button frames
- **Waypoint Tracker Performance**: Completely rewritten for zero per-frame memory allocations. Uses cached world-space coordinates and primitive API returns instead of creating objects every frame

---

## [1.2.6] - 2026-03-05

### Added
- **Map Search Filters**: Filter global and local search results by category - zones, dungeons, raids, travel, services, etc.
- **Minimap Button**: Optional minimap icon to toggle the search bar (left-click) or open options (right-click); draggable to reposition
- **Search Results**: Results list is now scrollable with no hard cutoff

### Changed
- **Waypoint Tracking**: Map pins now place a native WoW waypoint with full supertrack arrow support

### Fixed
- **Player Housing and Scenario Zones**: Clicking these in global search now navigates directly to the zone instead of placing a pin at the screen corner
- **Navigate Button**: Grayed out and blocked when viewing a zone the player is not currently in
- **UI Reload**: Modules now correctly initialize after `/reload`

---

## [1.2.5] - 2026-03-04

### Added
- **Arrival Distance Slider**: Waypoint auto-clear distance is now configurable (3–20 yards, default 10) via the Options panel
- **Show Login Message Toggle**: Option to hide the "EasyFind loaded!" chat message on login

### Changed
- **Navigate Button**: Waypoint pin icon now only appears on local map search results (removed from zone/instance global search results where it didn't apply)
- **Login Message**: Simplified to just mention `/ef o` for options

### Fixed
- **Results Dropdown Overflow**: Fixed search results spilling past the bottom of the screen; clamping now uses actual measured row heights instead of a fixed estimate
- **Map Close Cleanup**: Fixed bouncing arrow indicator remaining visible after closing the world map
- **Pin Persistence**: Map pins now auto-clear when you leave the zone; pins only restore on map reopen if you're still in the same zone
- **Missing Flight Masters**: Fixed Stormwind, Redridge, and other flight masters not appearing due to overly strict zone-name filtering

---

## [1.2.4] - 2026-02-16

### Added
- **Pinned Paths**: Right-click any UI or map search result to pin it as a bookmark. Pinned items appear at the top of results and persist across sessions. Collapsible header keeps things tidy
- **Click-to-Navigate Map Pins**: Click any local map search pin to place a native WoW waypoint and activate minimap tracking (no more Ctrl+clicking the map manually)
  - **Two-stage** visual guidance system for the placed waypoints:
    - **Far**: Pulsing gold star on the minimap perimeter over the standard Blizz arrow when waypoint is outside minimap range
    - **Near**: Rotating gold ring with directional arrowhead when waypoint enters minimap range; ring smoothly shrinks as you approach to avoid map pin going inside circle
  - Waypoint pin is automatically removed when the game reports "Reached Destination"

### Changed
- **Map Pin**
  - **Default Map Pin Size**: Map pin icons and highlight boxes reduced to ~50% of previous size for less visual clutter on the world map
  - **Map Pin Hover Behavior**: Local search pins now show a tooltip ("Click to track on minimap") instead of auto-dismissing on hover; global search pins retain the original hover-to-dismiss behavior
    - Can still remove local search pins by either right clicking them, hitting the clear button on the search bar, or with /ef clear
  - **Blinking Map Pins Option**: Map pins now solid by default, but there is a new toggle in Options panel to enable/disable the map pin pulse animations

### Fixed
- **Missing Icons**: Fixed missing icons for portrait menu items and other UI search results that previously showed blank

---

## [1.2.3] - 2026-02-13

### Added
- **Reputation Search**: Search and navigate to any faction reputation; shows standing progress bar with renown level, friendship rank, or traditional standing (Honored, Exalted, etc.)
- **Currency Amounts in Results**: Currency search results now display your current quantity inline
- **Movement Fade**: Search bar fades to lower opacity while your character is moving (can be disabled with Static Opacity option)
- **Match Highlighting**: Direct search matches are highlighted in gold to distinguish them from parent category context

### Changed
- **Search Abbreviations**: Common shorthand now works more consistently; "tww", "df", "bfa", "mop", "wod", "sl", "cata", "wotlk", "tbc", etc.
- **Smart Result Cap**: Results no longer cut off mid-category. If a header is the last visible row, its children are included automatically
- **`/ef show`**: No longer auto-focuses the search box. Bar appears without stealing your input
- **`/ef` command**: Bare `/ef` now shows usage help instead of toggling the bar; use `/ef show` and `/ef hide` instead
- **Escape in Map Search**: Pressing Escape now just unfocuses the search box instead of clearing your query, so you can click back in to resume
- **Container Browsing**: Category headers in search results can now be expanded to browse all their contents, not just matched items

### Fixed
- **Search Icons**: Fixed icons not displaying correctly in currency search results
- **Reset All Settings**: Properly resets everything to defaults

---

## [1.2.2] - 2026-02-12

### Added
- **Reputation**: Reputation panel of character info window now included in search results
### Changed
- **Default Keybinds**: No keybinds are set by default on new installs (previously `[` and `]`)
  - Users who want keybinds must configure them manually via Options panel
- **Unearned Currency Detection**: Unearned currencies (quantity = 0) now display grayed out in search results with a tooltip
  - Tooltip shows "Not yet earned" on hover using a custom tooltip frame (doesn't interfere with game tooltips)
  - Grayed-out currencies are non-clickable to prevent failed navigation attempts

### Fixed
- **Critical Keybind Bug**: Fixed addon automatically enabling character-specific keybinds and disabling all keybinds on characters without character-specific keybinds
- **Nested Currency Navigation**: Fixed guide failing to highlight nested currency headers (e.g., "Warlords of Draenor" under "Legacy")

---

## [1.2.1] - 2026-02-10

### Fixed
- **`/ef clear` now clears everything**: Previously only dismissed UI search highlights; now also clears map POI highlights, zone highlights, and breadcrumb navigation indicators
- **Breadcrumb arrow glow**: Glow was missing or clipped because the arrow frame was parented inside WorldMapFrame. Reparented to UIParent so the glow renders fully even when the arrow sits at the map edge
- **Breadcrumb arrow brightness**: Arrow and glow were dimmed by the parent highlight's blinking alpha animation; arrow now renders at full brightness
- **Arrow bob animations**: Standardized all arrow bob animations across the addon (UI search, map POI, zone, breadcrumb, multi-pin) to use consistent direction (toward target), offset (10px), and duration (0.4s)
- **Zone arrow directional bob**: Zone highlight arrows now bob in the direction they point (down, up, left, or right) instead of always bobbing upward
- **Breadcrumb arrow animation**: Breadcrumb arrow now bobs like all other arrows instead of being static
- **Glow intensity**: Reduced glow alpha from 0.7 to 0.35 so bright arrow colors (Yellow, Gold, White) don't wash out the arrow shape into a blob, especially against yellow zone highlights
- **Map search tooltip**: Tooltips now only appear when hovering the magnifying glass icon, not the entire search bar border
- **Breadcrumb arrow size**: Increased default from 24px to 48px to match all other arrow indicators

---

## [1.2.0] - 2026-02-10

### Added
- **Arrow Customization**: Full visual customization for all arrows and indicators
  - **Arrow Style**: Choose from 4 arrow textures (EasyFind Arrow, Classic Quest Arrow, Minimap Player Arrow, Cursor Point)
  - **Arrow Color**: Pick from 8 color presets (Yellow, Gold, Orange, Red, Green, Blue, Purple, White)
  - All arrows update in real-time across map search, zone highlights, UI search, and breadcrumb navigation
  - Unified sizing system: one Icon Size slider controls all arrows uniformly
- **Map Search Enhancements**:
  - **Additional Search Bar**: Added a separate search bar for global search instead of having just one with a toggle to make it easier to switch between local and global without additional mouse clicks
  - **Dungeon & Raid Entrance Search**: Find instance portals across the world through global map search bar (still tweaking things here)
  - **Zone Abbreviations**: Type common shortcuts like `sw` (Stormwind), `dal` (Dalaran), `org` (Orgrimmar), `if` (Ironforge), etc.
- **Keybinds**: Added customizable keybinds for quick access
  - Toggle UI Search Bar (default: `[`)
  - Focus Search Bar (default: `]`) (Jump to search input or toggle focus)
  - Configure via Options panel or ESC > Keybinds > EasyFind
- **First-Time Setup Overlay**: New users now get an interactive setup experience with a golden highlight overlay, drag-to-position, and corner resize handle. Setup completes automatically and won't appear again after clicking Done.
- **Smart Show**: Hide the search bar until you hover over it. Keeps your screen clean while staying accessible.
- **Search Bar Opacity Slider**: Adjust transparency of the UI search bar to see through it better.
- **Visual Themes for Results**: Choose between two dropdown themes in Options:
  - **Retail**: Uses retail Quest log style, as well as rounded edges for search bar
  - **Classic**: A more basic, barebones look reminiscent of addons in the Classic WoW days
- **New Slash Commands**:
  - `/ef hide` — Hide the search bar
  - `/ef show` — Show the search bar  
  - `/ef clear` — Dismiss active highlights and guides

### Changed
- **Search Bar Visual Improvements**:
  - Removed hide button in favor of new default Smart Show mode and/or keybind toggle
  - Removed clear highlights button in favor of /ef clear command since errors with persistent highlighting should be less common
- **Unified Icon Sizing**: Icons changed to be identical and changing settings for one affects all indicators (map arrows, UI arrows, zone arrows, pins)
- **Search Scoring Refactor**: ScoreName and ScoreKeywords moved to Database.lua for unified fuzzy matching across UI search, map POI search, and zone search
- **Zone Search Scoring**: Minimum score threshold raised from 0 to 50 for cleaner zone results
- **Default Theme**: Changed from Classic to Retail for new installs
- **Default Keybinds**: Set `[` and `]` as defaults on first install
- **Toggle Button Removed**: Deprecated the floating toggle button. Use keybinds or slash commands instead
- **Options Panel Redesign**: Complete 2-column layout redesign
  - Left column: Sliders (Icon Size, UI/Map Search scales, opacity)
  - Right column: Checkboxes, Results Theme, Arrow Style, Arrow Color, keybind configuration
  - Expandable Advanced Options section
  - Integrated keybind capture UI with shared helpers
  - Custom flyout dropdowns for theme/arrow selection (replaces UIDropDownMenu to avoid Blizzard global state pollution)

### Fixed
- **Canvas-to-UI Conversion**: icons now properly maintain consistent screen size across zoom levels
- **Arrow Auto-Refresh**: style/color changes now properly apply instantly when you change settings in options panel without manual refresh
- **Results Dropdown Gap**: Fixed visual gap between search bar and results frame by overlapping frames slightly
- **Shift+Click Behavior**: Holding Shift while clicking the search bar no longer focuses the editbox when you try to move the box around
- **Map Search UX**: Dungeon maps now excluded from zone navigation to prevent dead ends

### Technical Details
- Dungeon entrance caching: `ScanAllDungeonEntrances()` results cached per session to avoid redundant C_Map lookups
- Zone highlight stacking: 4 layers of zone texture with ADD blending for high-visibility continent map highlights

---

## [1.1.0] - 2026-02-08

### Added
- **Dynamic Currency Loading**: All currencies from your character's Currency tab are now automatically searchable, including new seasonal currencies and legacy currencies from past expansions
- **Missing Statistics Categories**: Added 10+ missing statistics categories including Kills, Quests, Skills, Travel, Social, Delves, Pet Battles, Proving Grounds, Legacy, and World Events

### Changed
- **Search Results Sorting**: Results now sort by relevance score first, then alphabetically (previously only alphabetical)
- **Currency Tree Structure**: Reorganized currency database into proper nested tree with multi-level header support

### Fixed
- **Improved DirectOpen Mode**: DirectOpen now executes all navigable steps automatically, only showing highlights for non-clickable UI regions
- **Achievement/Statistics Category Navigation**: Completely rewrote category navigation to use Blizzard's data provider API instead of unreliable text matching
  - Categories now highlight properly in all tabs (Achievements, Guild, Statistics)
  - Nested categories (like "World" under "Player vs. Player") now work correctly
  - Fixed infinite loop bug where guides would re-guide users after reaching subcategories
  - Instruction textboxes no longer appear for categories that exist in the sidebar
- **Prerequisite Validation**: Parent categories now check if they're expanded rather than selected, fixing navigation bugs with multi-level categories

### Technical Details
- Localized all global functions (math, string, table) for faster execution
- Pre-calculated search query lengths and pre-lowercased database entries
- Optimized frame iteration using `select()` instead of table allocations
- Added `Utils.lua` module for shared utilities and localized globals
- Implemented `PopulateDynamicCurrencies()` to scan `C_CurrencyInfo` API at login
- New data-driven category helpers: `FindCategoryElementData()`, `FindVisibleCategoryButton()`, `IsCategoryExpandedOrSelected()`
- Removed deprecated `FindWarModeButton()` in favor of direct frame paths
- Event frame cleanup: one-time events now properly unregister after firing

---

## [1.0.0] - Initial Release

### Added
- UI Search: Find and navigate to any interface element
- Map Search: Locate important places across Azeroth (portals, banks, trainers, etc.)
- Guide Mode: Step-by-step visual guidance with yellow highlights and arrows
- Direct Open Mode: Instantly open to your destination
- Achievement and Statistics navigation
- Draggable search bar with scale options
- Slash command `/ef` to toggle UI search

