# Changelog

All notable changes to EasyFind will be documented in this file.

---

## [Unreleased]

### Added
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
- **Options Panel Redesign**: Complete 2-column layout redesign
  - Left column: Sliders (scale, opacity, map scales)
  - Right column: Checkboxes, theme selector, keybind configuration
  - Expandable Advanced Options section
  - Integrated keybind capture UI with shared helpers
  - Custom flyout dropdown for theme selection (replaces UIDropDownMenu to avoid Blizzard global state pollution)

### Changed
- **Default Theme**: Changed from Classic to Retail for new installs
- **Default Keybinds**: Set `[` and `]` as defaults on first install
- **Toggle Button Removed**: Deprecated the floating toggle button — use keybinds or slash commands instead
- **Shift+Click Behavior**: Holding Shift while clicking the search bar no longer focuses the editbox (Shift is now exclusively for dragging)
- **Results Dropdown Gap**: Fixed visual gap between search bar and results frame by overlapping frames slightly

### Fixed
- **UIDropDownMenu Global State Bug**: Theme selector was opening random currency/addon menus due to Blizzard's shared dropdown state. Replaced with custom flyout frame.
- **Search Bar Theme Not Updating**: Backdrop now properly re-applies when switching themes via `UpdateSearchBarTheme()` methods
- **RefreshResults Resurrecting Old Searches**: Fixed issue where changing themes would re-render old cached results even when results frame was hidden
- **Focus Keybind Key Leak**: Added `C_Timer.After(0)` delay to prevent bound key from being typed into search box
- **Map Search Theme Updates**: Both map search frames now properly update backdrops when theme changes

### Technical
- Added `Highlight:ClearAll()` method for programmatic highlight dismissal
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

