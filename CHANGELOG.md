# Changelog

All notable changes to EasyFind will be documented in this file.

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

