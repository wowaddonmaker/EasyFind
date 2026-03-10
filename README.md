# EasyFind

EasyFind lets you search for any panel, tab, or setting in WoW's interface and any point of interest on the map. Type what you're looking for, and EasyFind walks you to it step by step, or if you prefer, opens it directly.

## Features

### UI Search
Find and navigate to any interface element:
- Character panels (titles, currency, reputation)
- Talents and spellbook
- Group Finder (dungeons, raids, PvP queues)
- Collections (mounts, pets, toys, transmog)
- Achievements and statistics (including nested categories)
- Guild and social features
- Professions
- All currencies from your character's Currency tab, including seasonal and legacy currencies (shows current amounts inline)
- Faction reputations with visual progress bars showing renown level, friendship rank, or traditional standing
- Player portrait menu options (Set Focus, Loot Specialization, Dungeon/Raid Difficulty, Edit Mode, PvP Flag, etc.)
- Coverage is always expanding. If a panel exists in the default UI, the goal is for EasyFind to reach it

**Pinned Paths**: Right-click any search result to pin it as a bookmark. Pinned items always appear at the top of your results and persist across sessions.

### Map Search
Locate important places across Azeroth:
- Portals and transport
- Banks and auction houses
- Flight masters
- Dungeon and raid entrances (search globally or within current map)
- Profession trainers

**Two search bars**: The local bar searches your current zone. The global bar searches zones, dungeons, raids, and delves across all of Azeroth. Both support category filters to narrow results by type.

**Click-to-Navigate**: Click any local search pin on the map to place a native WoW waypoint with minimap supertrack arrow. The waypoint auto-clears when you arrive. Navigate buttons are grayed out when you are viewing a zone your character is not in.

**Zone Abbreviations**: Type common shortcuts like `sw` (Stormwind), `dal` (Dalaran), `org` (Orgrimmar), `if` (Ironforge), `orib` (Oribos), and more.

### Two Navigation Modes
- **Guide Mode** (default): Walks you through each step to reach your destination. Highlights the correct button or tab with a yellow pulsing border and an animated arrow so you learn where things live.
- **Direct Open Mode**: For when you already know the UI and just want to get there. Opens panels and tabs directly with no extra steps.

## How to Use

Type at least 2 characters and results appear as you type. Click a result or press Enter to select the first match.

**Examples:**
- `talents` → opens the Talents panel
- `currency` → opens the Currency tab
- `3v3` → navigates to the 3v3 Arena queue in Group Finder
- `duel` → finds duel statistics in Achievements

Results show their full path so you always know where you're going:
- Character Info > Currency
- Group Finder > Player vs. Player > Rated

## First-Time Setup

When you install EasyFind for the first time, you'll see an interactive setup overlay that helps you position and resize the search bar. Simply drag the bar where you want it and use the corner handle to adjust the size, then click **Done** when ready. You can always reposition it later by holding **Shift** and dragging.

## Slash Commands

| Command | Description |
| --- | --- |
| `/ef o` | Open the options panel |
| `/ef hide` | Hide the search bar |
| `/ef show` | Show the search bar |
| `/ef clear` | Dismiss all active highlights and guides (UI search, map POI, zone, breadcrumb) |
| `/ef bug` | Get a link to submit a bug report on GitHub |
| `/ef feature` | Get a link to submit a feature request on GitHub |

Options are also available via ESC > Interface > AddOns > EasyFind.

## Keybinds

EasyFind provides customizable keybinds:

- **Toggle Bar**: Show/hide the search bar
- **Focus Bar**: Jump to the search bar and start typing (or unfocus if already active)
- **Toggle+Focus**: Opens and focuses the search bar in one press. Press again to close. When the world map is open, focuses the local map search bar instead
- **Clear All**: Dismiss all active highlights, map pins, zone highlights, and waypoints

**No keybinds are set by default.** Configure them in the Options panel or via ESC > Keybinds > EasyFind.

## Options
- **Indicator Style**: Choose from 5 arrow textures (EasyFind Arrow, Classic Quest Arrow, Minimap Player Arrow, Low-res Gauntlet, HD Gauntlet). All indicators update in real-time.
- **Indicator Color**: Pick from 8 color presets (Yellow, Gold, Orange, Red, Green, Blue, Purple, White).
- **Results Theme**: Choose between Classic (colorful tree lines) or Retail (quest log style) for the search results dropdown.
- **Open Panels Directly** (UI Search): Selecting a UI result opens the target panel immediately instead of guiding you through each step. Off by default.
- **Navigate Zones Directly** (Map Search): Selecting a zone jumps straight to it instead of stepping through parent zones. Off by default.
- **Smart Show**: Hide the search bar until you hover over it.
- **Static Opacity**: Keep the search bar at constant opacity while moving (off by default; bar fades while moving).
- **UI Results Above / Map Results Above**: Show search results above the bar instead of below, useful for bottom-of-screen placement.
- **Blinking Map Pins**: Pins and highlight boxes pulse in sync with the indicator arrow (on by default). The indicator arrow always bobs regardless.
- **Background Opacity**: Adjust search bar transparency.
- **Font Size**: Scale text and row height across all search bars.
- **Icon Size / Guide Circle Scale**: Unified sliders for map indicators and minimap guide circle.
- **Minimap Button**: Show or hide the minimap icon.
- **Show Login Message**: Show or hide the "EasyFind loaded!" chat message on login.
- **Visual Rescaler**: Drag handles on search bars and results panels to resize width, row count, and font size interactively.
- **Reset All Settings / Reset Positions**: Return settings or search bar positions to defaults.

## Moving the Search Bars

Both search bars can be repositioned by holding **Shift** and dragging. The map search bar stays constrained to the bottom of the map frame.

## Feedback

Found a bug or have an idea? You can submit feedback through GitHub Issues:

- **In-game**: Type `/ef bug` or `/ef feature`, or use the buttons at the bottom of the Options panel. A link will appear that you can copy and paste into your browser.
- **On GitHub**: Open an issue directly at the [Issues page](https://github.com/wowaddonmaker/EasyFind/issues/new/choose).
- **On CurseForge**: Leave a comment on the [CurseForge page](https://www.curseforge.com/wow/addons/easyfind).

## Links

- [GitHub](https://github.com/wowaddonmaker/EasyFind)
- [Changelog](https://github.com/wowaddonmaker/EasyFind/blob/main/CHANGELOG.md)
