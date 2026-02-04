# FindIt

A World of Warcraft addon that helps you quickly find UI elements and map locations.

## Features

### UI Search
Find and navigate to any interface element:
- Character panels (stats, reputation, currency)
- Talents and spellbook
- Group Finder (dungeons, raids, PvP)
- Collections (mounts, pets, toys, transmog)
- Achievements and statistics (including nested categories like duel statistics)
- Guild and social features
- Professions
- And more

### Map Search
Locate important places across Azeroth:
- Portals
- Banks and auction houses
- Flight masters
- Profession trainers
- Quest hubs

### Navigation Modes
- **Guide Mode** (default): Step-by-step visual guidance with yellow highlights and arrows
- **Direct Open Mode**: Instantly opens to your destination (can be enabled in options)

## Usage

### Opening FindIt
- Open by default. Type /find, /findit, or /whereis in chat if it gets closed and you can't seem to recover it
### Searching
Type at least 2 characters to see results. The search shows a hierarchical list of matches. Click any result or press Enter to select the first one.

**Search Examples:**
- "talents" opens the Talents panel
- "currency" opens the Currency tab in your character panel
- "3v3" navigates to the 3v3 Arena queue in the Group Finder
- "duel" finds duel statistics in the Achievements window

### Result Display
Results show their location path:
- Character Info > Currency
- Group Finder > Player vs. Player > Rated

Gray text indicates parent categories, gold text shows the actual destinations.

### Visual Guidance
When using guide mode, FindIt shows:
- Yellow pulsing border around the correct button or tab
- Animated arrow pointing down at the target
- Instructions for hard-to-reach elements

## Options

Access settings via /findit o or ESC > Interface > AddOns > FindIt:
- Toggle between Guide Mode and Direct Open Mode
- Adjust UI search bar scale
- Reset search bar position

## Moving the UI

Both search bars can be repositioned:
- **UI Search**: Hold Shift and drag
- **Map Search**: Hold Shift and drag (constrained to bottom of map)

## Requirements

World of Warcraft Retail (Patch 12.0.0 or later)

## Known Issues

- Some protected frames cannot be highlighted due to API restrictions
- Map locations are manually added and may not cover all zones

## License

Free to use and modify.

---

**Enjoy using FindIt! Never lose track of your UI again!**
