# Changelog

All notable changes to EasyFind will be documented in this file.

---

## [3.2.0] - 2026-09-04

### Added
- **EasyFind links**: right-click a result and choose EasyFind link to send it to a chat channel, a whisper, or your clipboard. Anyone running EasyFind sees a clickable link that opens that result on their side, the same as clicking it in their own search; everyone else sees plain text. Abilities, talents, mounts, toys, outfits, and macros open where they live (spellbook, talent window, journal, toy box, transmog, macro window), since a chat link cannot cast or use. Catalog items, where the item link already shows everything, keep their normal link. Ctrl+Shift+C on a row copies its EasyFind link the way Ctrl+C copies its chat link
- **What's New remembers what you missed**: the update popup lists every release you skipped since you last logged in, newest first, instead of only the latest

### Changed
- **Snippets is its own addon**: it appears in the AddOns list as "EasyFind [Snippets]" and can be disabled there. Saved snippets stay in the core, and the Snippets row, filter, options tab, and tutorial slide hide while it is off
- Pasting a copied result into chat brings back the live link whether or not Snippets is enabled

### Fixed
- **Results no longer rearrange after you stop typing**: when a query pulled in a category that was still loading, the list painted once without it and again with it, so rows jumped around a moment after the last keystroke. The first paint now waits for that load
- **Achievement rows no longer shuffle the list a frame after each keystroke**: the game answers an achievement search one frame later, and the list used to paint without those rows and again with them mixed in; the first paint now waits that frame
- **Punctuation in what you type no longer hides rows**: a colon, hyphen or bracket in the query (`pattern:`, `raids (journal)`) made loot rows and multi-word names drop out the moment it was typed; the query is now cut into words the same way names are
- **Addon settings with colored or iconed names are searchable past the color**: an addon whose settings category name carries a color code or icon inside it (BetterBlizzFrames) matched only up to the color and vanished one letter later; the searchable name is now stripped of that markup
- **A swapped first pair counts as a typo**: `ocntrol` finds Control and `ramor` finds Armor; a wrong first letter is still not a match
- **Same-name rows keep a fixed order**: when an ability and a talent share a name (Swipe), the talent lists first every session instead of whichever loaded first
- **Dungeon teleports rank like everything else**: typing a dungeon's nickname such as `bran` no longer lifts its teleport above items and toys whose names start with it. Typing the dungeon name out still ranks the teleport like an exact match, and a query that says teleport, tp, portal, dungeon, keystone, or mythic still puts it first
- **Exact and long keyword matches outrank typo matches**: a result that answers to the word you typed, or to five or more letters of it, now ranks above results whose name is merely one letter off (`brack` finds Brackenhide before the Black rows)
- **Escape closes what is on top**: with a setting's dropdown or a right-click menu open, Escape closes that first instead of dismissing the results underneath it
- **Learned picks stop following a query they no longer match**: typing past a remembered query keeps its pick on top only while the pick still matches what you typed
- **Category words no longer bury name matches**: typing `dungeon` lists Dungeon Finder and the other rows named for it first, then the nearby dungeons, instead of the dungeons above everything

---

## [3.1.1] - 2026-09-03

### Fixed
- **Whispers no longer complete a name on their own**: typing `/w` and the first letters of a name filled in the rest of the name as if you had accepted it. The game's own suggestion works as before: the rest of the name stays highlighted and Tab accepts it

---

## [3.1.0] - 2026-09-02

### Added
- **Snippets, a new app**: save reusable text once and use it anywhere. Type `\keyword` in chat and it expands in place as you type, or send a snippet straight from its search result's menu. Placeholders (`{date}`, `{time}`, `{player}`, `{target}`, `{zone}`) fill in at use, and call-form keywords like `\greet(name)` take arguments. Typing a keyword in the macro editor expands and saves the macro in the same keystroke. Manage snippets from their Options tab, reached via the apps menu, searching "Snippets", or the `@snip` quick filter; a snippet shortkey fires the snippet directly
- **Choose the snippet trigger**: the activation character (`\` by default) can be changed to `!`, `#`, `~`, `&`, `+`, or `=` from the cog on the Create snippet button or in the editor's corner; one trigger applies to every snippet
- **Snippet call help**: typing `\keyword(` ghost-suggests the snippet's argument names the way the search bar's autocomplete does (typing narrows to the closest one, used args drop out), and typing `\keyword?` pops a tooltip with the call signature and the snippet text
- **Search inside the macro window**: the game's macro window gains a search bar that filters the macro grid on the current tab by name or body as you type. Clicking a filtered macro selects that macro, tab switches and edits keep the filter live, and clearing it restores the full grid
- **Ctrl+C copies a hovered result**: Ctrl+C on a result row copies a snippet's entire message or a link to the real clipboard, ready to paste wherever you want with Ctrl+V, with a "Copied" flash confirming. The Send menu's Clipboard option likewise now copies the full text instead of showing the shift-click link dialog
- **Ctrl+V pastes a real link into chat**: a copied item, spell, or achievement result pasted into the chat box becomes the live link (a snippet's embedded links come back too), while the same paste outside the game stays the readable name. The game strips link codes from anything pasted, so the copied text is recognized on arrival and swapped for its link in place
- The tutorial's Apps deck gains a Snippets slide, each Apps slide is titled with the app it shows, and updating players get a one-time pointer to the new app on the apps button

### Changed
- The options window and the tutorial are one settings row taller, and the aliases, blacklist, and snippets list cards align flush with the sidebar's bottom edge
- The row context menu's "Send link" entry is now just "Send"
- **The copy window is gone**: copy rows (Send > Clipboard, Wowhead, icon ID/name/path) wear a "Ctrl+C" hint and copy when you press Ctrl+C with the row engaged, by mouse or by keyboard, then read "Copied". Icon grid cells copy their ID with Ctrl+C directly, and either click opens the cell menu. Inline answers and the changelog link copy the same way. Only the `/ef bug` and `/ef feature` commands, which have nothing to hover, keep a small "Ctrl+C to copy" prompt at the cursor
- Searching "snippets" ranks the Snippets menu first and Create snippet second, ahead of whichever snippet was picked last

### Fixed
- Clicking an achievement result teaches the search again: learned picks (and aliases) on achievements were recorded but could never resurface, since achievement rows are built per query rather than stored
- Clicking an unpinnable row (Create snippet, the snippets menu) now teaches the search too; unpinnable had been treated as unlearnable
- Achievement results scroll the achievement window to the target again after a game update removed the function that did it; the guide and direct-open now scroll the list themselves when it is missing
- Snippet results appear on the first search after a reload instead of two seconds later: the snippets provider now loads the moment a query names it

---

## [3.0.1] - 2026-08-31

### Added
- **Find dungeon teleports by dungeon name**: type a dungeon's name or its common nickname (`boralus`, `mots`, `doti`) and your unlocked "Path of ..." teleport surfaces near the top, ready to cast; searching the flavor name is no longer required. Covers every teleport spell in the game across all expansions, with dungeon names localized in every language

---

## [3.0.0] - 2026-08-31

### Added
- **Icon Search, a new app**: type `@icons` (or open it from the apps menu, or search "Icon Search") to browse all game icons in a live-filtered grid. Left click opens a window to copy the icon's FileDataID; right click offers copy ID/name/path and creating a macro with that icon, blank-titled, plain or with a `#showtooltip` first line. Search understands words with plural matching (`swords`), alternatives (`sword/axe`, or comma-separated queries), exclusion (`-inv`), wildcards (`inv_sword_*`), IDs (`135274`, `#135274`), and the game's own link forms (`spell:133`, `item:6948`) including shift-clicked chat links
- **Search inside the macro icon picker**: the game's own icon picker (macro creation, and anywhere else it appears) gains an EasyFind search bar running the same engine. It steps aside automatically if another icon-picker addon is present, and can be turned off in Options > Search
- The entire Icon Search module (data, grid, picker bar) ships as the `EasyFind_Icons` companion addon, loaded on demand: it costs nothing at login and nothing ever until the first time icon search is actually used, and can be disabled entirely from the AddOns list
- **Fully keyboard-driven grid**: Down enters (or Tab from the search box), arrows and Alt+HJKL move, Enter copies, Tab opens the icon's menu, ESC steps back out. Same conventions as the rest of the search bar
- **Menu keyboard flow**: Right on a focused result row opens its context menu (Tab still works); Left or Shift+Tab backs out of any keyboard-opened menu to the row or cell that opened it, one level at a time through submenus. Hovering a menu row moves the keyboard selection to it, so exactly one row is ever highlighted: whichever input you used last wins

### Changed
- **New default look**: fresh installs start on the Midnight theme with window borders off; existing setups keep their saved choices
- **Filter button hover** drops the gold ring; the glow alone is the hover and focus look, matching the apps button
- **Tutorial texts condensed** so slides no longer overflow the wizard window

### Performance
- Typing no longer spikes the CPU: search work runs under a per-frame budget and spreads across frames, so the worst cold-cache keystroke went from several-hundred-millisecond stalls to under 50ms, and the average typing frame now costs the same as standing idle
- Memory comes back when you're done: closing the search bar or the world map sweeps that surface's caches and garbage, a settle pass after login reclaims one-time startup construction, and the icon dataset releases its working memory whenever the grid closes
- Idle CPU is now zero: menu and popup closers are event-driven (no per-frame polling), the scrollbar driver disarms itself when idle, and theme restyling runs only when the theme actually changed
- The searchable database (collections, achievements, currencies, ...) is built on first search-bar focus instead of at login, and the item and icon datasets load on demand: sessions that never search carry none of it
- The search index survives provider updates without rebuilding (removals cost one flag), and its posting lists are compressed to a fraction of their former memory
- Scrolling results no longer recomputes badges per frame, re-renders mid-scroll, or fires tooltip machinery for rows passing under the cursor

### Fixed
- **Catalog items get a real identity**: learned search, aliases, pins and shortkeys now key catalog items by item ID through the one shared identity system. Picking a catalog item after a search teaches the ranking like any other row; pinning one rarity variant no longer also pins its same-named siblings; and pinned catalog items show their proper icons in the pinned view without needing a search first
- A gear set's spec badge (and an outfit's lock overlay) could linger on unrelated rows that recycled the same row frame
- An active quick filter's view (including the icon grid) no longer gets replaced by pinned items when focus bounces off menus or popups
- Keyboard-focused menu rows show the normal themed highlight instead of a gold overlay
- Several tutorial slides and POI labels shipped untranslated in most locales; all translated, and a new CI check now blocks untranslated locale values from ever shipping again

---

## [2.4.5] - 2026-08-24

### Added
- **Calculator money math**: gold/silver/copper amounts work in any expression. `4g / 5` gives `80s`, `4g50s * 2` gives `9g`, and a lone amount like `450s` converts (`4g 50s`). Accepts `g`/`s`/`c` and `gold`/`silver`/`copper`, compounds like `4g 50s`, and decimals like `1.5g`. Gold results group thousands the way the game does (`25,000g`)

### Fixed
- **Keyboard menu navigation**: Tab to the apps button and Enter now opens a keyboard-navigable apps menu (arrows, Enter to launch, ESC back to the button); previously Enter opened a menu you couldn't drive
- **ESC in filter menus** closes one level at a time (submenu, then parent, then the menu) instead of tearing the whole chain down at once; ESC out of a keyboard-opened menu visibly reselects its toolbar button, so Enter reopens it and Tab moves on
- **Apps menu and filter menu** can no longer be open at the same time; opening one closes the other on every open path, including keyboard opens
- **Alt+number result shortcuts** no longer type the digit into the search box while activating the result
- **Tab-completing a filter token** (like `@mo` for Mounts) no longer re-appends the partially typed token to the search text
- **Copy window clicks**: closing the copy/link window no longer also closes the results list; clicks on EasyFind's own floating windows are no longer treated as clicks outside the search UI
- **Calculator icon** brightened to match the rest of the interface icons across all themes

---

## [2.4.4] - 2026-08-23

### Fixed
- **World Map tab compatibility**: switching from EasyFind's map tab to another addon's map tab no longer shows a blank gray panel on the first click, and closing the map from such a tab reopens correctly. EasyFind now only restores Blizzard's sidebar when its own panel closes with no successor tab

---

## [2.4.3] - 2026-08-18

### Added
- **Search learns from your picks**: pick a result after typing a query and it appears at the top the next time you type that search, or a lazier version of it (teach it on "glad mount" and "glad" is enough later). Works for everything searchable. Aliases you set yourself always outrank learned picks
- **Learn from picks toggle and Forget button**: both in Options > Search. The toggle stops learning and boosting; the button permanently forgets everything learned, after a confirmation, without touching aliases, shortkeys or any other setting

### Changed
- **Options panel**: content starts slightly higher in every tab

---

## [2.4.2] - 2026-08-18

### Added
- **Category words show your zone's results first**: typing a category word like "flight", "fm", "fp", "tp", "delve" or "bank" now puts your current zone's results of that category at the top of the list, no setup needed. A "This zone only" checkbox in the filter menu's Map Search flyout narrows category words to just your zone, hiding that category's other-zone results entirely
- **Whole-category aliases**: the Add alias dialog on map results gains a checkbox that binds your trigger to the whole category ("Flight Paths", "Portals") instead of one spot; the dialog title follows the choice. Category aliases always reach their category, even with map filters off

### Fixed
- **Duplicate map rows**: a map result boosted to the top by an alias no longer appears a second time further down the list

---

## [2.4.1] - 2026-08-16

### Fixed
- **Aliases now force their result to the top**: an aliased entry stayed at its natural rank when it also matched the search on its own, and typing past the alias text dropped the boost entirely. An alias now pins its result first for the whole query
- **Aliases match like result names do**: aliases now go through the same matching as every result name, prefixes, word starts, and typo tolerance included. The best alias match ranks first, and junk typed past an alias no longer keeps it pinned on top
- **Alias boosts follow the 2-character minimum**: a single keystroke no longer surfaces every alias containing that letter. A deliberate single-character alias still fires when typed exactly
- **Great Vault icon**: repointed to where patch 12.1 moved it on the sprite sheet

---

## [2.4.0] - 2026-08-15

### Added
- **Apps button**: a new dot-grid button on the search bar opens the apps menu. Calculator is the first app, with more on the way
- **Calculator can be disabled**: the calculator now ships as "EasyFind [Calculator]", its own entry in the AddOns list. Disable it there and every trace of it goes away; while enabled, inline math and searching "calculator" work exactly as before
- **Search options**: new "Show app button" and "Show filter button" toggles. Unchecked, the button stays hidden until you hover over its spot on the bar

### Changed
- **Calculator follows your theme**: the calculator window's keypad, input box, and result box now match the active theme and restyle live when you switch. Its icon wears the same theme color everywhere it appears
- **Search options layout**: the Wowhead language selector now sits with the other selector rows

### Fixed
- **Search results could close when clicking a popup**: clicks on confirmation dialogs and the calculator window no longer count as clicking outside the results

---

## [2.3.0] - 2026-08-14

### Added
- **Switch specialization from search**: your specs appear as Talents results; click one to swap
- **Load talent loadouts from search**: your current spec's saved loadouts load with one click, no talent window needed. The loadout and spec you are on are marked in green
- **Talents filter options**: new Specialization and Loadouts toggles in the Talents filter menu control whether these rows appear

---

## [2.2.1] - 2026-08-10

### Fixed
- **Updated for patch 12.1**: bumped the supported game version and repointed the icons the patch moved

---

## [2.2.0] - 2026-08-04

### Added
- **Professions search**: your recipes are now searchable by name. Enable it under Professions in the filter menu
- **Item catalog**: every item in the game is now searchable, not just the ones you own. Find it under Items in the filter menu, or type `@gen`
- **Bank search**: your bank and the warband bank are searchable from anywhere. `@bank` is yours, `@warband` is the account's. Enable it under Items in the filter menu
- **Items on your other characters**: search what your alts are carrying, bags and banks alike. Choose whose storage feeds your results in the filter menu
- **Inline answers**: type `gold`, `item level`, `durability`, `keystone`, `bag space`, `rating` or `speed` and the answer appears above your results. Click it to copy, gold included, which pastes as `1g 2s 3c`
- **Toy and pet filters**: toys filter by collected state, source and expansion; pets by collected state, source and family
- **Send item links to chat**: click or drag any item result to pick it up, then click a chat channel to link it there. Search results can also be added to a Note
- **Unearned titles**: the Titles filter can now list titles you have *not* earned. Hovering one shows the achievement that awards it, and clicking opens straight to it. Switch Titles to Incomplete or All in the filter menu
- **Statistics filter**: narrow statistics to Recorded or Not Recorded
- **Equipment Manager filters**: gear sets can be narrowed to a single specialization, and a set assigned to a spec shows that spec's icon on its row
- **Tooltips on hover**: achievement results show their full tooltip with progress, criteria and reward, and title results show the tooltip of the achievement that grants them
- **`/clear`** clears the chat window

### Changed
- **Loot results behave like every other item row**: click or drag links the drop, Alt opens the Encounter Journal, Ctrl previews it in the dressing room
- **Uncollected pets** open the Pet Journal when clicked, instead of doing nothing
- **Smaller download**: four textures right-sized to what is actually drawn, 1.8 MB down to 213 KB

### Fixed
- **Wowhead links for titles** pointed at an unrelated page. Titles now link to the achievement that awards them
- **Toys, mounts and outfits could stop working after a search**: revealing one in its journal left the game's own button unusable, so your next click on it did nothing
- **Escape could stop responding**: EasyFind held onto the key while having nothing to close. It now hands the key back the moment it has nothing to dismiss
- **The search bar could sink behind other windows while typing**
- **Multi-word statistic and achievement searches**: "gold per day" now matches "Average gold earned per day"
- **Reagent bag contents were unsearchable**
- **Missing icons**: uncollected pets lost theirs, and currency and reputation rows fell back to a question mark
- **Result names could be cut short** with room to spare
- **Menu hover highlights**: filter menu rows no longer lose their highlight behind the menu, and the filter button keeps its hover look while its menu is open

---

## [2.1.4] - 2026-07-21

### Added
- **Data broker support**: if you use a display bar that hosts data broker objects, EasyFind can now be launched from it instead of the minimap button. Left-click toggles the search bar, right-click opens the options. Every other way in still works, Auto-Hide included, and nothing changes if no such display is installed.

### Fixed
- **Welcome screen**: the version number is no longer cut off in the tutorial's welcome title

---

## [2.1.3] - 2026-07-19

### Fixed
- **IME input**: typing with a composition-based input method (Chinese pinyin, Korean, Japanese, and similar) should no longer corrupt the search text. Inline autocomplete now pauses while a composition is open and resumes the moment it commits or cancels, so completion keeps working in every language, including completing committed CJK text

### Added
- **Autocomplete toggles**: separate options to turn inline autocomplete off for the search bar (Search options) and the map tab search box (Map options)

---

## [2.1.2] - 2026-07-14

### Added
- **Themes**: choose how EasyFind looks from a set of themes, picked during setup and changeable at any time from the options menu
- **Blacklist**: right-click any result and choose Blacklist to keep it out of every search; manage and restore blacklisted results from the new Blacklist tab in the options menu
- **Icon visibility**: choose whether results show all icons, general icons only, or specific icons only
- **Rooms filter**: hide rooms from housing results, since rooms can't be opened from the housing dashboard
- **Shortkey import**: importing shortkeys that clash with existing ones now lets you replace or skip each one (or apply your choice to all), and warns you when an imported shortkey binds a system command

### Changed
- **Search window opacity**: can now be lowered all the way to 50%

### Fixed
- **Window border**: borders no longer reactivate when they aren't enabled
- **Mount and toy guides**: searching for a mount or toy now walks you to it in the Mount Journal or Toy Box
- **Chat frame toggle**: no longer shows an Alt-click settings hint for a menu it doesn't have
- **Achievements**: no longer disappear from search when the game's achievement search stops responding mid-session
- **Adventure Guide bosses**: no longer listed more than once when the same boss appears in several tiers

---

## [2.1.1] - 2026-07-11

### Added
- **Always Show**: a third visibility mode that keeps the search bar permanently on screen, with combat options (hide in combat, or dim it instead) and an optional dim while moving; the tutorial gained a slide for picking how the bar appears
- **Focus Search Bar keybind**: focuses the always-shown bar directly (enabled while Always Show is active)
- **Hide window border**: new option for a borderless search bar and menus
- **Manual resize**: back under the Size menu; dragging the height snaps to whole result rows and stays in sync with the Result Rows setting, and the scale presets stack on top
- **Expansion currency groups**: search an expansion plus "currencies" (like "midnight currencies") to list every currency from that expansion inline
- **Housing filter menu**: the Housing filter now carries the catalog's full Filter menu (sort and tag options), kept in sync with the catalog window in both directions
- **@housing and @commands quick filters**

### Changed
- The search bar now sits behind game windows like other HUD elements; open results and menus rise above the action bars while in use
- Toggle All in the filter menus now only affects its own level, and the Services submenu gained its own Toggle All
- The reset buttons now also reset window sizes and are named "Reset Size & Positions" and "Reset All Sizes & Positions"
- Better result ranking for short and common-word queries
- Download size reduced from 22 MB to under 5 MB and installed size from 82 MB to 14 MB: tutorial images now ship in the game's native compressed texture format, and unused image files were removed. No visual difference.
- The "Gear" filter is now called "Loot", matching the loot results it covers
- Consolidated tutorial slides: gear sets, outfits, and titles share one slide, as do macros with abilities and toys with slash commands, and the inline-settings slide moved to the Actionables walkthrough
- Search data for filtered-off categories is no longer loaded and indexed at all until the category is re-enabled

### Fixed
- Ability results now open the spellbook to the exact page in one click, including abilities not yet learned
- Opening the spellbook or talents from a search result no longer causes "EasyFind has been blocked" action-bar errors and spellbook cooldown errors during combat; both the open and the tab switch now run through the game's own protected input path
- Pressing Escape to close a window no longer risks the same combat errors (EasyFind windows now close via a temporary key binding instead of the game's window list)
- Result clicks now fire their action regardless of the game's cast-on-key-down combat setting (previously, turning that setting off silently broke mount, spell, and macro results)
- Shortkeys now bind immediately at login from saved data instead of waiting for search data to load
- Pressing a shortkey now always triggers the same action as left-clicking its row
- Loot results match their gear-slot keywords correctly again, and stat searches can combine two stats
- Dungeon and raid loot no longer permanently vanishes from search when the game's journal data hadn't finished arriving during a background scan; already-affected installs heal automatically on next login
- Characters without a specialization (below level 10) now get loot results for their whole class instead of none
- Toys, pets, titles, heirlooms, currencies, and reputations no longer stay empty in search for a whole session when the game hadn't finished loading their data at login; each now retries once its data arrives
- Pinned outfits update again when outfits are changed or reordered (an internal rename had disconnected that sync)

---

## [2.1.0] - 2026-07-07

### Added
- **Send link**: Right-click any result to share a clickable link in chat (Say, Yell, Party, Instance, Raid, Guild, a whisper by name, or a link box you can shift-click into any chat message); works for items, spells, mounts, pets, housing decor, achievements, currencies, and bosses, and statistics share as ready-made "name: value" text
- **Housing search**: Search housing decor, with a Housing filter (Collection, Dyeable Only, Collection Bonus, Placeable); clicking a result opens the catalog with that item searched
- **Filter subcategories**: Instances split into Raids/Dungeons/Delves, Travel gathers Flight Paths/Boats/Portals, and Services breaks out Banks, Auction House, Innkeepers, Mailboxes, Trainers, Vendors, and more, on both the map tab and the search bar filter menu
- **Menu keyboard navigation**: Tab from the search box reaches the filter menu, Tab or Right descends into filter flyouts and right-click submenus, Left backs out
- **Shortkeys**: Right-click any result to bind a key that opens it instantly, without typing or opening the search bar; managed from Aliases & shortkeys in the options
- **Wowhead links**: Right-click items, spells, mounts, achievements, currencies, and more for a copy-ready Wowhead URL
- **Account-wide keybinds**: EasyFind's keybinds now apply on every character (including with character-specific key bindings) and are set from EasyFind's options instead of Blizzard's keybinding panel
- **New fonts**: Inter, Lato, and Poppins available in the options
- **Updated tutorial**: New and reworked slides so the tutorial covers everything above

### Changed
- "vsync" now finds the Vertical Sync graphics setting
- Per-button action bar keybindings (such as "Action Bar 3 Button 3") no longer clutter search results; the action bars themselves still appear
- Removed the redundant "Achievements Tab" entry from search results
- Improved the reveal behavior for collection search results
- The hotkey step of the tutorial now shows the recommended keybinds
- Typing in the search bar stays smooth even with large collections and the housing catalog loaded
- During combat the search bar closes and shortkeys are disabled; everything comes back when combat ends

### Fixed
- Search now matches words that follow a hyphen, so "alias" finds "Anti-Aliasing" and "fov" finds "Field of View"
- Search results no longer vanish moments after they appear while an inline suggestion is showing
- Pinning a command now floats it to the pinned section immediately instead of appearing to do nothing
- Pinned macros now run when clicked, and always run the macro's current text even after edits
- Opening a raid or dungeon from search no longer triggers a blocked-action error when the Adventure Guide switches tabs
- The "Transfer" option in a currency's right-click menu highlights the currency, then the Transfer button on its popup
- Options on/off toggles flip the moment you click them, instead of waiting for the next mouse-over
- Several Smart Show fixes: the search bar no longer gets stuck hidden or stuck visible after selecting a result, and a toggled-off bar no longer intercepts clicks in its old spot
- Unchecking the Rares map filter now stops rare auto-tracking, and re-enabling auto-track refreshes the open map immediately
- Clicking options inside the row right-click menu's submenus no longer closes the menu without acting

---

## [2.0.1] - 2026-06-21

### Changed
- Updated for WoW patch 12.0.7

### Fixed
- The Statistics, Map Search, and Options filter icons display correctly after Blizzard reorganized the shared icon sheet in 12.0.7

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
  - `/ef hide` - Hide the search bar
  - `/ef show` - Show the search bar
  - `/ef clear` - Dismiss active highlights and guides

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
