# Changelog

All notable changes to EasyFind will be documented in this file.

---

## [1.2.0] - 2026-02-10

### Added
- **Arrow Customization**: Full visual customization for all arrows and indicators
  - **Arrow Style**: Choose from 4 arrow textures (EasyFind Arrow, Classic Quest Arrow, Minimap Player Arrow, Cursor Point)
  - **Arrow Color**: Pick from 8 color presets (Yellow, Gold, Orange, Red, Green, Blue, Purple, White)
  - All arrows update in real-time across map search, zone highlights, UI search, and breadcrumb navigation
  - Unified sizing system: one Icon Size slider controls all arrows uniformly
- **Map Search Enhancements**:
  - **Dungeon & Raid Entrance Search**: Find instance portals across the world via Encounter Journal API
  - **Zone Abbreviations**: Type common shortcuts like `sw` (Stormwind), `dal` (Dalaran), `org` (Orgrimmar), `if` (Ironforge), etc.
  - **Improved Zone Navigation**: Parent map overrides fix incorrect routing (e.g., Undermine now correctly routes through Khaz Algar)
  - Dungeon/raid entrances show zone location in global search results: "Blackrock Depths (Searing Gorge)"
- **Keybinds**: Added customizable keybinds for quick access
  - Toggle UI Search Bar (default: `[`)
  - Focus Search Bar (default: `]`) — Jump to search input or toggle focus
  - Configure via Options panel or ESC > Keybinds > EasyFind
- **First-Time Setup Overlay**: New users now get an interactive setup experience with a golden highlight overlay, drag-to-position, and corner resize handle. Setup completes automatically and won't appear again after clicking Done.
- **Smart Show**: Hide the search bar until you hover over it. Keeps your screen clean while staying accessible.
- **Search Bar Opacity Slider**: Adjust transparency of the UI search bar to see through it better.
- **Visual Themes for Results**: Choose between two dropdown themes in Options:
  - **Retail**: Quest log style with warm golden tree lines, grey tooltip border, and Game15Font_Shadow headers
  - **Classic**: Colorful tree connectors with vibrant depth-based colors
- **Search Bar Visual Improvements**:
  - Rounded borders with lighter grey backdrop for Retail theme
  - Circle X clear button matching retail quest log style
  - Improved backdrop theming that updates when switching themes
- **New Slash Commands**:
  - `/ef hide` — Hide the search bar
  - `/ef show` — Show the search bar  
  - `/ef clear` — Dismiss active highlights and guides
  - `/ef test <texture>` — Preview arrow textures (e.g., `/ef test Interface\\MINIMAP\\MiniMap-QuestArrow`)
- **Options Panel Redesign**: Complete 2-column layout redesign
  - Left column: Sliders (Icon Size, UI/Map Search scales, opacity)
  - Right column: Checkboxes, Results Theme, Arrow Style, Arrow Color, keybind configuration
  - Expandable Advanced Options section
  - Integrated keybind capture UI with shared helpers
  - Custom flyout dropdowns for theme/arrow selection (replaces UIDropDownMenu to avoid Blizzard global state pollution)

### Changed
- **Unified Icon Sizing**: `mapIconScale` renamed to `iconScale` — one setting now controls all indicators (map arrows, UI arrows, zone arrows, pins)
- **Search Scoring Refactor**: ScoreName and ScoreKeywords moved to Database.lua for unified fuzzy matching across UI search, map POI search, and zone search
- **Map Search UX**: Dungeon and orphan maps now excluded from zone navigation to prevent dead ends
- **Zone Search Scoring**: Minimum score threshold raised from 0 to 50 for cleaner zone results
- **Default Theme**: Changed from Classic to Retail for new installs
- **Default Keybinds**: Set `[` and `]` as defaults on first install
- **Toggle Button Removed**: Deprecated the floating toggle button — use keybinds or slash commands instead
- **Shift+Click Behavior**: Holding Shift while clicking the search bar no longer focuses the editbox (Shift is now exclusively for dragging)
- **Results Dropdown Gap**: Fixed visual gap between search bar and results frame by overlapping frames slightly

### Fixed
- **UIDropDownMenu Global State Bug**: Theme selector was opening random currency/addon menus due to Blizzard's shared dropdown state. Replaced with custom flyout frame.
- **Search Bar Theme Not Updating**: Backdrop now properly re-applies when switching themes via `UpdateSearchBarTheme()` methods
- **RefreshResults Resurrecting Old Searches**: Fixed issue where changing themes would re-render old cached results even when results frame was hidden
- **Unified Icon System**: `ns.CreateArrowTextures()` and `ns.UpdateArrow()` ensure identical appearance across all arrows (map, UI, zone, breadcrumb)
- **Canvas-to-UI Conversion**: `ns.UIToCanvas()` converts UI-unit sizes to canvas units so icons maintain consistent screen size across zoom levels
- **Directional Rotation Helper**: `ns.GetDirectionalRotation()` computes correct rotation for any arrow style pointing up/down/left/right
- **Arrow Auto-Refresh**: OnShow hooks update arrows on every display so style/color changes apply instantly without manual refresh
- Zone highlight stacking: 4 layers of zone texture with ADD blending for high-visibility continent map highlights
- Added `Highlight:ClearAll()` method for programmatic highlight dismissal
- `Focus()` function now toggles focus state (focus → unfocus → focus)
- Options panel height expands by 30px when Advanced Options is toggled
- Search bar opacity dimmed during first-time setup for better overlay visibility
- Resize handle uses frame-by-frame cursor delta instead of absolute offset for smooth scaling
- Dungeon entrance caching: `ScanAllDungeonEntrances()` results cached per session to avoid redundant C_Map lookups
- `Focus()` function now toggles focus state (focus → unfocus → focus)
- Options panel height expands by 30px when Advanced Options is toggled
- Search bar opacity dimmed during first-time setup for better overlay visibility
- Resize handle uses frame-by-frame cursor delta instead of absolute offset for smooth scaling

---

## [1.1.0] - 2026-02-08

### Added
- **Dynamic Currency Loading**: All currencies from your character's Currency tab are now automatically searchable, including new seasonal currencies and legacy currencies from past expansions
- **Missing Statistics Categories**: Added 10+ missing statistics categories including Kills, Quests, Skills, Travel, Social, Delves, Pet Battles, Proving Grounds, Legacy, and World Events
- **Currency Navigation**: Full support for navigating multi-level currency headers (e.g., Legacy > War Within > Season 3)
- **Improved DirectOpen Mode**: DirectOpen now executes all navigable steps automatically, only showing highlights for non-clickable UI regions

### Fixed
- **Achievement/Statistics Category Navigation**: Completely rewrote category navigation to use Blizzard's data provider API instead of unreliable text matching
  - Categories now highlight properly in all tabs (Achievements, Guild, Statistics)
  - Nested categories (like "World" under "Player vs. Player") now work correctly
  - Fixed infinite loop bug where guides would re-guide users after reaching subcategories
  - Instruction textboxes no longer appear for categories that exist in the sidebar
- **Prerequisite Validation**: Parent categories now check if they're expanded rather than selected, fixing navigation bugs with multi-level categories

### Changed
- **Performance Improvements**: 
  - Localized all global functions (math, string, table) for faster execution
  - Pre-calculated search query lengths and pre-lowercased database entries
  - Optimized frame iteration using `select()` instead of table allocations
- **Search Results Sorting**: Results now sort by relevance score first, then alphabetically (previously only alphabetical)
- **Currency Tree Structure**: Reorganized currency database into proper nested tree with multi-level header support

### Technical Details
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

