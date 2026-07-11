# EasyFind

EasyFind is WoW's Raycast, Spotlight, or Alfred: a fast command bar that lets you search anything in World of Warcraft.

## How to Use

Press `Ctrl+Space` (the default Search Bar keybind, changeable during the tutorial or in EasyFind options) to show and focus the search bar, type what you want, then select a result. Press the keybind again or click anywhere outside EasyFind to close it.

## Features

### Main Search

Search across:

- UI panels, tabs, options, addon settings, and Blizzard settings.
- Achievements, statistics, titles, reputations, currencies, talents, abilities, and spellbook entries.
- Mounts, pets, toys, transmogs, outfits, heirlooms, gear sets, macros, bosses, loot, bag items, and housing decor.
- Zones, dungeons, raids, delves, services, travel points, rares, and other map destinations.

Supported results can do more than just open a panel:

- Mount up, summon pets, use toys, equip outfits, run macros, and cast or use abilities directly from search.
- Shift-click supported abilities from results to drag them to action bars.
- Use consumables, equip gear, or Ctrl-click supported bag items to open and highlight the item in your bags.
- Open boss and loot entries in the Encounter Journal.
- Guide to collection entries, favorite pets, rename pets, and open supported collection tools.
- Open map destinations in the Map Search tab and track or preview them from the world map.

### Map Search Tab

Search from the world map with nested results built for location-first browsing:

- **"This Zone"** shows matches on the map currently being viewed.
- **"Across the World"** groups broader matches by continent and zone.
- Hover map results for POI previews, navigate between zones, place pins, and track destinations.
- The same map results can also be found from the main search bar, just without the nested map layout.

### Search Tools

- **Right-click menu**: Every result has a context menu.
  - On nearly every result:
    - **Pin**: Keep it visible before typing.
    - **Shortkey**: Bind a key that opens or uses the result instantly, without opening the search bar or taking up action bar slots.
    - **Add Alias**: Add your own search terms. Aliases are shared between normal search and map search where applicable.
    - **Guide**: Walk to the result with step-by-step highlights.
    - **Send link**: Share a clickable link in chat (Say, Yell, Party, Instance, Raid, Guild, a whisper, or a link box you can shift-click into any chat message).
    - **Wowhead link**: Copy-ready Wowhead URL.
  - Row-specific extras, for example:
    - **Achievements**: objective tracking.
    - **Currencies**: backpack pinning and currency transfer.
    - **Reputations**: watched-faction toggle.
    - **Pets**: summon, rename, favorite, cage or release.
    - **Transmog sets**: favorite toggle.
    - **Bag items**: destroy.
- **Guide mode and direct open**: Learn where things live with step-by-step highlights, or open supported destinations directly.
- **Quick filters**: Type `@` to search within a category such as pets, mounts, bags, macros, abilities, achievements, statistics, bosses, gear, currencies, reputations, talents, titles, collections, or map results.
- **Slash-command results**: Type `/` in the search bar to see supported EasyFind commands such as `/reset` and `/options`.
- **Calculator**: Type math directly into search, including arithmetic, trig functions, and factorials, or open the full calculator with `Alt+C`.
- **Keyboard control**: Use arrows, Enter, Tab, Alt+number row shortcuts, or Alt+H/J/K/L navigation.

### Options

Configure:

- Search behavior, visibility mode (auto-hide, hover show, or always show with combat options), result placement, visible row count, window border, fonts and font size, and Alt+number hints.
- Map Search behavior, map pins, icon sizing, tracking, recent searches, and result categories.
- Aliases, keybindings, indicator style/color, search window sizing, and reset tools.

## Examples

- `talents` opens or guides to the Talents panel.
- `3v3` finds Rated Arena.
- `@pets beetle` searches pets only.
- `calculator` shows the full calculator launcher.
- `sin30 + 12/3` shows an inline calculator result.
- `nexus` can find map results and open the Map Search tab.

## Commands

- `/ef` or `/ef o`: open EasyFind options.
- `/ef clear` or `/ef c`: clear active highlights, guides, pins, and map indicators.
- `/ef reset` or `/ef r`: reset the search position and size after confirmation.
- `/ef setup`: run the tutorial again.
- `/ef bug`: show the bug-report link.
- `/ef feature`: show the feature-request link.

Search-bar commands are also available by typing `/` directly in the EasyFind search bar.

## Keybinds

Two binds ship enabled by default, account-wide: `Ctrl+Space` (Search Bar) and `Ctrl+M` (Map Search Tab). If one of these keys is already bound to something else, EasyFind's bind takes precedence while it is set; your existing bind is not cleared and works again as soon as you rebind or remove EasyFind's.

Change or remove them in EasyFind options. Available binds:

- Search Bar
- Map Search Tab
- Clear All

## Languages

Fully translated into English, German, French, Italian, Spanish (EU and Latin America), Korean, Portuguese, Russian, and Chinese (Simplified and Traditional). The addon follows your game client's language automatically; anything missing a translation falls back to English. Translation fixes are welcome through GitHub issues.

## Feedback

- GitHub issues: https://github.com/wowaddonmaker/EasyFind/issues/new/choose
- CurseForge: https://www.curseforge.com/wow/addons/easyfind

## Links

- GitHub: https://github.com/wowaddonmaker/EasyFind
- Changelog: https://github.com/wowaddonmaker/EasyFind/blob/main/CHANGELOG.md
