# Changelog

All notable changes to EasyFind will be documented in this file.

---

## [2.0.1] - 2026-05-19

### Fixed
- Search now matches words that follow a hyphen, so "alias" finds "Anti-Aliasing" and "fov" finds "Field of View"
- The "Transfer" option in a currency's right-click menu now reliably opens the currency transfer window
- EasyFind's keybinds now apply on every character (including with character-specific key bindings) and are set from EasyFind's options instead of Blizzard's keybinding panel
- Options on/off toggles flip the moment you click them, instead of waiting for the next mouse-over
- Smart Show no longer leaves the search bar stuck hidden; the toggle keybind is disabled while Smart Show is on

### Changed
- "vsync" now finds the Vertical Sync graphics setting
- Per-button action bar keybindings (such as "Action Bar 3 Button 3") no longer clutter search results; the action bars themselves still appear
- Removed the redundant "Achievements Tab" entry from search results
- Improved the reveal behavior for collection search results
- The hotkey step of the tutorial now shows the recommended keybinds

---

## [2.0.0] - 2026-05-13

EasyFind 2.0 is a full rewrite of the search and map experience. Launch the in-game tutorial to see what's new.

---

## [1.5.0] - 2026-04-07

### Added
- **Loot Search**: Search dungeon and raid loot by item name, slot, stats, boss, or instance. Filter by class, specialization, and difficulty. Click a result to navigate directly to the item in the Encounter Journal
- **Transmog Outfit Search**: Your saved transmog outfits appear in search results. Click to equip, with cooldown tracking and active-outfit indicators
- **Outfit Lock Status**: Locked outfits display a visual overlay on their icon with lock details on hover
- **Transmog Browse Mode**: Opening the transmog window via search hides vendor-only controls and shows guidance messages. All controls restore when the window closes or when visiting a transmogrifier
- **Clear Button for Navigation**: The search bar clear button now appears during active step-by-step guides and dismisses highlights and arrows in addition to clearing text
- **Dynamic Category Ordering**: Search result categories (UI, Mounts, Loot, etc.) sort by best match score instead of a fixed order

---

## [1.4.0] - 2026-03-20

### Added
- **Rare Mob Tracking**: Active rare mobs in your zone appear as searchable pins on the world map. Search "rare" in the zone bar to see all nearby rares, or click individual rare names to track them with Blizzard waypoint tracking
- **Auto-track Rares**: Toggle in the zone search filter dropdown or the Map options tab. When enabled, all active rares are automatically pinned on the map without searching. Pins persist at last known position when rares leave detection range and clear when killed
- **Great Vault (Rewards)**: Great vault rewards panel now searchable in UI search
- **"NEW" Feature Labels**: New or experimental features display a glowing label with a tooltip encouraging feedback

### Fixed
- **Adventure Guide Fast Mode**: Direct open now works for all Adventure Guide tabs (Journeys, Dungeons, Raids, etc.)
- **Combat Lockdown**: Fixed errors that could occur when reloading the UI during combat or by taking portals

### Changed
- **StaticLocations Cleanup**: Standardized bank and guild vault naming across all zones

---

## [1.3.1] - 2026-03-17

### Added
- **Independent Map Navigation Modes**: Local and global map search bars now have separate direct-open toggles instead of a shared setting
- **Expanded POI Coverage**: Added portals in Tirisfal Glades, decor specialists, and additional innkeepers, auction houses, and mailboxes across multiple zones

### Changed
- **Slash Commands**: `/ef` now opens options directly. `/ef toggle` (shorthand `/ef t`) replaces `/ef show`/`/ef hide`. Added `/ef help` for a command overview
- **Options Panel Dropdowns**: Redesigned with WoW-style open/close arrows and indented child options

### Fixed
- **New Map POI Categories**: Decor specialists, crafting order NPCs, rostrum, pet and riding trainers, and training dummies now properly appear in map search results
- **Tooltip Clarity**: Map search bar editbox now shows bar identity (Zone/Global Search) and the current mode. Mode toggle button describes only the toggle action

---

## [1.3.0] - 2026-03-15

### Added
- **New UI Search Categories**: Enable each via the filter dropdown on the search bar
  - **Mounts**: Search your collected mounts by name. Click a result to summon. Icons show combat tint when unavailable
  - **Toys**: Search collected toys with cooldown sweep overlays. Click to use
  - **Battle Pets**: Search your collected battle pets by name. Click to summon a companion
  - **Map Search**: Search map POIs (zones, dungeon entrances, flight masters) directly from the UI search bar. Includes waypoint placement on hover
- **Mode Toggle Button**: Interactive fast/guide mode toggle flush-left in the search bar, replacing the static search icon. Syncs with the options panel checkbox
- **Filter Dropdown Enhancements**: Per-filter icons, "Toggle All" button, and Shift+Up/Down section jump for keyboard navigation
- **Independent Maximized Map Bars**: Zone and instance search bars position independently in full-screen map mode with separate saved positions
- **Hide Bars in Full Screen Map**: New option to hide both map search bars when the map is maximized

### Changed
- **Tab/Shift+Tab Navigation**: Now cycles through all toolbar controls (mode button, editbox, clear button, filter button) in left-to-right order

### Fixed
- **Quest Tracking Coexistence**: User waypoint auto-reclaim no longer overrides active quest tracking
- **Encounter Journal Fast Mode**: Protected tabs in the Encounter Journal now hand off to the guide system instead of failing silently
- **Short Query False Positives**: 2-char abbreviations like "fp" no longer match unrelated items through incidental keyword initials (e.g., "flight paths" in Travel Statistics)
- **Scrollbar Overlap**: Fixed map search results overlapping with scrollbar in certain configurations
- **Breadcrumb Arrow in Full Screen**: Arrow position, animation, and direction now update correctly when switching between maximized and windowed map modes

### Technical Notes
- **Search Performance**: Word-split cache, reusable Damerau-Levenshtein row tables, module-level sort comparator, pre-split query words, and incremental narrowing (extending a query re-scores only previous matches)
- **Memory Reduction**: Search results store `{data, score}` references instead of shallow copies. `__index` prototypes for bulk-injected mount/toy/pet entries. Staggered population across frames to avoid single-frame stutter
- **Keyword Initials Penalty**: Scaled by query length to eliminate noise from short queries while preserving useful matches for longer abbreviations

---

## [1.2.7] - 2026-03-10

### Added
- **Keyboard Navigation**: Full arrow key, Tab, and Enter support for navigating search results without a mouse. Works in both UI search and map search bars. Tab/Shift+Tab toggles between a parent row and its expand/collapse button. Arrow keys in map search preview the pin location before confirming
- **Visual Rescaler**: Drag handles on search bars and results panels to resize width, adjust row count, and change font size interactively. Shift+drag the search bar itself to reposition it along the map edge
- **Smarter Search**: Vowel-stripped abbreviations now match (e.g. "qtr" finds "quartermaster", "windrnr" finds "windrunner"). Multi-word queries match per-word with fuzzy and subsequence support (e.g. "twlght hghlnds" finds "Twilight Highlands")
- **Major POI Expansion**: Added points of interest for Stormwind, Orgrimmar, Ironforge, Thunder Bluff, Darnassus, Undercity, The Exodar, Silvermoon City, and Valdrakken. Includes class trainers, profession trainers, quartermasters, banks, inns, barbers, stable masters, guild services, and more
- **Bug Report and Feature Request**: `/ef bug` and `/ef feature` as well as buttons in the options panel to open pre-filled GitHub issue URLs for easy reporting
- **New options**:
  - Toggle+Focus keybind: combined show+focus in one keypress, targets map search bar when world map is open
  - Clear All keybind: dismiss all highlights, map pins, zone highlights, and breadcrumbs
  - Auto-track new pins and auto-clear on arrival
  - Pin highlight box toggle (show/hide yellow highlight square around map pins)
  - Map Smart Show (auto-hide map search bars until hover)
  - Map search Y-offset slider
  - Results above option for both UI and map search bars
  - Separate max visible row counts for UI search (default 10) and map search (default 6)

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
- **Fuzzy Length Tolerance**: Queries of 6+ characters now allow 2-character length differences when fuzzy matching, reducing missed results for longer words
- **Independent Indicator Animation**: Indicator arrow has its own Alpha animation group so it pulses independently of the parent highlight frame
- **Unified Animation Duration**: All animation durations consolidated into a single ANIM_DURATION constant
- **Atlas Zone Highlights**: Zone highlighting now supports atlas-based textures in addition to fileDataID textures
- **Shared Helpers**: Scroll, click, and frame-search patterns refactored into Utils.lua, reducing code duplication across Highlight and UI modules
- **Shared Constants**: Extracted duplicated constants (colors, sizes, string paths) into ns.* values in Utils.lua
- **Defensive Hardening**: Added pcall protection to flash ticker and all initialization timers. Added SavedVariables type validation to prevent corrupted settings from breaking the addon
- **Results Layout**: Improved pin separator spacing and scroll position preservation when toggling category headers
- **Continent Projection Fallback**: Zones with very small scan areas now fall back to continent-level projection
- **Highlight Hover Timer**: Reduced minimum display time from 1.0s to 0.3s for snappier hover-dismiss behavior
- **GetScript Error**: Fixed error when calling GetScript on non-Button frames

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
- **Click-to-Navigate Map Pins**: Click any local map search pin to place and track a native WoW waypoint
  - Waypoint pin is automatically removed when the game reports "Reached Destination"

### Changed
- **Map Pin**
  - **Default Map Pin Size**: Map pin icons and highlight boxes reduced to ~50% of previous size for less visual clutter on the world map
  - **Map Pin Hover Behavior**: Local search pins now show a waypoint tooltip instead of auto-dismissing on hover; global search pins retain the original hover-to-dismiss behavior
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
