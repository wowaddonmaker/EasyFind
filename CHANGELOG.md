# Changelog

All notable changes to EasyFind will be documented in this file.

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

