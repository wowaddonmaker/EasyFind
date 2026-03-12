# EasyFind

EasyFind lets you search for any panel, tab, or setting in WoW's interface and any point of interest on the map. Type what you're looking for, and EasyFind walks you to it step by step, or if you prefer, opens it directly.

## Features

### UI Search

Find and navigate to any interface element such as:

*   Character panels (titles, currency, reputation)
*   Talents and spellbook
*   Group Finder (dungeons, raids, PvP queues)
*   Collections (mounts, pets, toys, transmog)
*   Achievements and statistics (including nested categories)
*   Guild and social features
*   Professions
*   All currencies from your character's Currency tab, including seasonal and legacy currencies (shows current amounts inline)
*   Player portrait menu options (Set Focus, Loot Specialization, Dungeon/Raid Difficulty, Edit Mode, PvP Flag, etc.)
*   Coverage is always expanding. If a panel exists in the default UI, the goal is for EasyFind to reach it

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/340/guide_nav-gif.gif" alt="guide mode"><br>
<em>Guide mode walks you through each step</em>
</p>

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/351/quick_nav-gif.gif" alt="direct open"><br>
<em>Direct open skips straight to the panel</em>
</p>

Currencies show your current amounts inline, and reputations display progress bars with renown level, friendship rank, or traditional standing.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/337/currency-png.png" alt="currency search">
<img src="https://media.forgecdn.net/attachments/1577/352/rep-png.png" alt="reputation search"><br>
<em>Currency amounts and reputation progress bars in search results</em>
</p>

Results are scrollable, so even broad searches like "rated" that would normally get cut off by the window show every match.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/354/scrollbar-png.png" alt="scrollable results"><br>
<em>Scrollable results with full category paths</em>
</p>

### Map Search

Locate places and NPCs across Azeroth:

*   Portals, zeppelins, boats, and trams
*   Banks and auction houses
*   Flight masters and city innkeepers
*   Dungeon, raid, and delve entrances (search globally or within current map)
*   Profession trainers and class trainers
*   Vendors, PvP vendors, and quartermasters
*   Mailboxes, barbers, transmogrifiers, and repair vendors
*   Stable masters, void storage, and guild services
*   The Great Vault, Creation Catalyst, and Trading Post
*   Chromie (Timewalking Campaigns)
*   Coming soon: improved main screen navigation and navigation to points outside your current zone

Search the zone of the map you're currently focused on with the local bar (left side), or search across all of Azeroth with the global bar (right side).

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/343/local_search_ah-gif.gif" alt="local search"><br>
<em>Local search finding the auction houses</em>
</p>

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/344/local_search_dungeon-gif.gif" alt="local dungeon search"><br>
<em>Local search finding a dungeon entrance</em>
</p>

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/339/global_raid_search-gif.gif" alt="global raid search"><br>
<em>Global search across all of Azeroth</em>
</p>

The global bar finds zones, dungeons, raids, and delves with full breadcrumb paths.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/345/map_zone_instance_search-png.png" alt="zone and instance search"><br>
<em>Zone and instance results with breadcrumb paths</em>
</p>

### Search Features

*   **Pinned Paths**: Right-click any search result to pin it as a bookmark. Pinned items always appear at the top of your results and persist across sessions.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/350/pinned-png.png" alt="pinned paths"><br>
<em>Pinned 3v3 Arena appears at the top of every search</em>
</p>

*   **Category Filters**: Narrow results by type. Filter global results by zones, dungeons, raids, and delves. Filter local results by instances, travel, and services.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/338/filter-png.png" alt="category filters"><br>
<em>Filter dropdown for global map search</em>
</p>

*   **Fuzzy and Abbreviation Matching**: Vowel-stripped abbreviations like `qtr` find "quartermaster". Multi-word queries like `twlght hghlnds` find "Twilight Highlands".
*   **Zone Abbreviations**: Type common shortcuts like `sw` (Stormwind), `dal` (Dalaran), `org` (Orgrimmar), `if` (Ironforge), `orib` (Oribos), and more.
*   **Keyboard Navigation**: Arrow keys, Tab, and Enter to browse and select results without a mouse.
*   **Click-to-Navigate**: Click any local search pin on the map to place a native WoW waypoint with minimap supertrack arrow. The waypoint auto-clears when you arrive (configurable arrival distance).
*   **Minimap Guide Circle**: When navigating to a nearby POI, a shrinking ring and directional arrow appear around your character on the minimap, guiding you to the exact spot.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/347/minimap_glow-png.png" alt="minimap glow">
<img src="https://media.forgecdn.net/attachments/1577/346/minimap_circle-png.png" alt="minimap guide circle"><br>
<em>Minimap glow arrow (far away) and guide circle (close up)</em>
</p>

### Two Navigation Modes

*   **Guide Mode** (default): Walks you through each step to reach your destination. Highlights the correct button or tab with a yellow pulsing border and an animated arrow so you learn where things live.
*   **Direct Open Mode**: Opens panels and tabs directly with no extra steps, for when you already know the UI and just want the convenience.

UI search and map search each have their own toggle. Enable **Open Panels Directly** (under UI Search options) to skip step-by-step guidance for interface panels. Enable **Navigate Zones Directly** (under Map Search options) to jump straight to a zone on the map instead of stepping through parent zones. Both are off by default.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/341/instant_nav_to_zone-gif.gif" alt="instant zone navigation"><br>
<em>Navigate Zones Directly jumps straight to the target zone</em>
</p>

## How to Use

Type at least 2 characters and results appear as you type. Click a result or press Enter to select the first match.

**Examples:**

*   `talents` → opens the Talents panel
*   `currency` → opens the Currency tab
*   `3v3` → navigates to the 3v3 Arena queue in Group Finder
*   `duel` → finds duel statistics in Achievements

Results show their full path so you always know where you're going:

*   Character Info > Currency
*   Group Finder > Player vs. Player > Rated

## First-Time Setup

When you install EasyFind for the first time, you'll see an interactive setup overlay that helps you position and resize the search bar. Simply drag the bar where you want it and use the corner handle to adjust the size, then click **Done** when ready. You can always resize it later through the options menu (/ef o) and reposition it later by holding **Shift** and dragging.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/348/new_player-png.png" alt="first-time setup"><br>
<em>First-time setup overlay</em>
</p>

## Slash Commands

| Command   |Description                          |
| --------- |------------------------------------ |
| <code>/ef o</code> |Open the options panel               |
| <code>/ef hide</code> |Hide the search bar                  |
| <code>/ef show</code> |Show the search bar                  |
| <code>/ef clear</code> |Dismiss all active highlights and guides |
| <code>/ef reset</code> |Reset all settings to defaults (opens confirmation dialog) |
| <code>/ef setup</code> |Re-run the first-time setup overlay |
| <code>/ef whatsnew</code> |Show the What's New dialog for the current version |
| <code>/ef bug</code> |Get a link to submit a bug report on GitHub |
| <code>/ef feature</code> |Get a link to submit a feature request on GitHub |

Options are also available via ESC > Interface > AddOns > EasyFind, or through the addon compartment button.

## Keybinds

EasyFind provides customizable keybinds:

*   **Toggle Bar**: Show/hide the search bar
*   **Focus Bar**: Jump to the search bar and start typing (or unfocus if already active)
*   **Toggle+Focus**: Opens and focuses the search bar in one press. Press again to close. When the world map is open, focuses the local map search bar instead
*   **Clear All**: Dismiss all active highlights, map pins, zone highlights, and waypoints

**No keybinds are set by default.** Configure them in the Options panel or via ESC > Keybinds > EasyFind.

## Options

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/349/options-png.png" alt="options panel"><br>
<em>Options panel</em>
</p>

### General
*   **Show Login Message**: Show or hide the "EasyFind loaded!" chat message on login.
*   **Minimap Button**: Show or hide the minimap icon. Drag to reposition.
*   **Indicator Style**: Choose from 5 arrow textures (EasyFind Arrow, Classic Quest Arrow, Minimap Player Arrow, Low-res Gauntlet, HD Gauntlet). All indicators update in real-time.
*   **Indicator Color**: Pick from 8 color presets (Yellow, Gold, Orange, Red, Green, Blue, Purple, White).
*   **Results Theme**: Choose between Classic (colorful tree lines) or Retail (quest log style) for the search results dropdown.
*   **Panel Opacity**: Adjust the options panel background transparency.

### UI Search
*   **Enable UI Search Module**: Toggle the entire UI search feature on or off (requires reload).
*   **Open Panels Directly**: Selecting a UI result opens the target panel immediately instead of guiding you through each step. Off by default.
*   **Smart Show**: Hide the search bar until you hover over it.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/355/smart_show-gif.gif" alt="smart show"><br>
<em>Smart Show hides the bar until you hover</em>
</p>

*   **Static Opacity**: Keep the search bar at constant opacity while moving (off by default; bar fades while moving).
*   **UI Results Above**: Show search results above the bar instead of below, useful for bottom-of-screen placement.
*   **UI Font Size**: Scale text and row height for the UI search bar independently.
*   **Background Opacity**: Adjust search bar transparency.
*   **Visual Rescaler**: Drag handles on search bars and results panels to resize width, row count, and font size interactively.

<p align="center">
<img src="https://media.forgecdn.net/attachments/1577/353/resize-png.png" alt="visual rescaler"><br>
<em>Visual rescaler with drag handles for width, rows, and font size</em>
</p>

### Map Search
*   **Enable Map Search Module**: Toggle the entire map search feature on or off (requires reload).
*   **Navigate Zones Directly**: Selecting a zone jumps straight to it instead of stepping through parent zones. Off by default.
*   **Map Results Above**: Show map search results above the bar instead of below.
*   **Map Font Size**: Scale text and row height for the map search bars independently.
*   **Icon Size**: Scale map indicator icons (default 80%).
*   **Arrival Distance**: How close (in yards) before a waypoint auto-clears. Default 10.
*   **Guide Circle Size**: Scale the minimap guide circle ring and arrow.
*   **Map Smart Show**: Auto-hide map search bars until you hover over them.
*   **Blinking Map Pins**: Pins and highlight boxes pulse in sync with the indicator arrow. Off by default. The indicator arrow always bobs regardless.
*   **Pin Highlight Box**: Toggle the yellow highlight box around map pins. Indicator arrow and pin icon remain visible either way.
*   **Minimap Arrow Glow**: Pulsing glow effect on the minimap perimeter arrow during navigation.
*   **Minimap Guide Circle**: Ring and directional arrow around your character on the minimap when navigating nearby.
*   **Map Pin Glow**: Pulsing glow on the map pin when the guide circle shrinks onto it.
*   **Auto Map Pin Clear**: Automatically clear map pins when you arrive at the destination.
*   **Auto Track Map Pins**: Automatically supertrack newly placed map pins for minimap arrow guidance.
*   **Map Search Y-Offset**: Adjust vertical position of map search bars relative to the map bottom edge.
*   **Category Filters**: Filter global results by zones, dungeons, raids, and delves. Filter local results by instances, travel, and services.

### Reset
*   **Reset All Settings**: Return all settings to defaults.
*   **Reset Positions**: Return search bar positions to defaults.

## Moving the Search Bars

Both search bars can be repositioned by holding **Shift** and dragging. The map search bar stays constrained to the bottom of the map frame.

## Feedback

Found a bug or have an idea? You can submit feedback through GitHub Issues:

*   **In-game**: Type `/ef bug` or `/ef feature`, or use the buttons at the bottom of the Options panel. A link will appear that you can copy and paste into your browser.
*   **On GitHub**: Open an issue directly at the [Issues page](https://github.com/wowaddonmaker/EasyFind/issues/new/choose).
*   **On CurseForge**: Leave a comment on the [CurseForge page](https://www.curseforge.com/wow/addons/easyfind).

## Links

*   [GitHub](https://github.com/wowaddonmaker/EasyFind)
*   [Changelog](https://github.com/wowaddonmaker/EasyFind/blob/main/CHANGELOG.md)
