# EasyFind

EasyFind lets you search for any panel, tab, or setting in WoW's interface and any point of interest on the map. Type what you're looking for, and EasyFind walks you to it step by step, or if you prefer, opens it directly.

## Features

### UI Search
Find and navigate to any interface element:
- Character panels (titles, currency)
- Talents and spellbook
- Group Finder (dungeons, raids, PvP queues)
- Collections (mounts, pets, toys, transmog)
- Achievements and statistics (including nested categories)
- Guild and social features
- Professions
- All currencies from your character's Currency tab, including seasonal and legacy currencies
- Coming soon: ability to search reputations
- Coverage is always expanding. If a panel exists in the default UI, the goal is for EasyFind to reach it

### Map Search
Locate important places across Azeroth:
- Portals and transport
- Banks and auction houses
- Flight masters
- Dungeon and raid entrances (uses Encounter Journal API; search globally or within current map)
- Coming soon: profession trainers, vendors and services, quest hubs, etc.

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
| `/ef` | Toggle the EasyFind search bar |
| `/ef o` | Open the options panel |
| `/ef hide` | Hide the search bar |
| `/ef show` | Show the search bar |
| `/ef clear` | Dismiss all active highlights and guides (UI search, map POI, zone, breadcrumb) |

Options are also available via ESC > Interface > AddOns > EasyFind.

## Keybinds

EasyFind provides customizable keybinds (defaults shown):

- **Toggle UI Search Bar** (default: `[`) — Show/hide the search bar
- **Focus Search Bar** (default: `]`) — Jump to the search bar and start typing (or unfocus if already active)

Configure these in the Options panel or via ESC > Keybinds > EasyFind.

## Options
- **Arrow Style**: Choose from 4 arrow textures (EasyFind Arrow, Classic Quest Arrow, Minimap Player Arrow, Cursor Point). All arrows update in real-time.
- **Arrow Color**: Pick from 8 color presets (Yellow, Gold, Orange, Red, Green, Blue, Purple, White).
- **Icon Size**: Unified slider controls all search indicators (map pins, UI arrows, zone highlights) at once.
- **Open Panels Directly** (UI Search): When enabled, selecting a UI result opens the target panel immediately instead of guiding you through each step. Off by default.
- **Navigate to Zones Directly** (Map Search): When enabled, selecting a map result jumps straight to the zone on the map instead of stepping through parent zones. Off by default.
- **Smart Show**: Hide the search bar until you hover over it. Keeps your screen clean while staying accessible.
- **Results Theme**: Choose between Classic (colorful tree lines) or Retail (quest log style) for the search results dropdown.
- **Search Bar Opacity**: Adjust transparency to see through the search bar.
- **UI/Map Search Bar Scales**: Resize each search bar independently.
- **Reset search bar positions**: Return search bars to default positions
- **Reset search bar position**: Return the search bar to default top-center position.

## Moving the Search Bars

Both search bars can be repositioned by holding **Shift** and dragging. The map search bar stays constrained to the bottom of the map frame.

## Links

- [GitHub](https://github.com/wowaddonmaker/EasyFind)
- [Changelog](https://github.com/wowaddonmaker/EasyFind/blob/main/CHANGELOG.md)
