if GetLocale() ~= "deDE" then return end
local _, ns = ...
local L = ns.L
if not L then return end

-- German translations. Partial is fine - any key omitted falls back to
-- the enUS source. Wrap shorter terms first; long prose can land later.
-- Many Blizzard UI labels (Mounts, Achievements, Reputation, etc.) come
-- from `_G[KEY]` lookups in the source code and DO NOT need entries here.

-- Options panel essentials
L["OPT_TAB_HOME"]                       = "Start"
L["OPT_TAB_GENERAL_BINDS"]              = "Allgemein & Tasten"
L["OPT_TAB_SEARCH"]                     = "Suche"
L["OPT_TAB_MAP"]                        = "Karte"
L["OPT_TAB_ALIASES"]                    = "Aliase"
L["OPT_HOME_WELCOME"]                   = "Danke, dass du EasyFind ausprobierst!"
L["OPT_SHOW_LOGIN_MESSAGE"]             = "Anmeldenachricht anzeigen"
L["OPT_SHOW_MINIMAP_BUTTON"]            = "Minimap-Symbol anzeigen"
L["OPT_INDICATOR_STYLE"]                = "Indikatorstil"
L["OPT_INDICATOR_COLOR"]                = "Indikatorfarbe"
L["OPT_FONT"]                           = "Schriftart"
L["OPT_KEYBINDS_HEADER"]                = "Tastenbelegungen (gilt für jeden Charakter)"
L["OPT_KEYBIND_TOGGLE_SEARCH"]          = "Suchleiste umschalten"
L["OPT_KEYBIND_OPEN_MAP_TAB"]           = "Kartensuche öffnen"
L["OPT_KEYBIND_CLEAR_ALL"]              = "Alles löschen"
L["OPT_LOCK_POSITION"]                  = "Position sperren"
L["OPT_RESULTS_DIRECTION"]              = "Ergebnisrichtung"
L["OPT_RESULTS_BELOW"]                  = "Unten"
L["OPT_RESULTS_ABOVE"]                  = "Oben"
L["OPT_RESET_SETTINGS"]                 = "Einstellungen zurücksetzen"
L["OPT_RESET_POSITIONS"]                = "Positionen zurücksetzen"
L["OPT_SAVED_ALIASES"]                  = "Gespeicherte Aliase"
L["OPT_NO_SAVED_ALIASES"]               = "Keine gespeicherten Aliase."

-- Colors
L["OPT_COLOR_YELLOW"]                   = "Gelb"
L["OPT_COLOR_GOLD"]                     = "Gold"
L["OPT_COLOR_ORANGE"]                   = "Orange"
L["OPT_COLOR_RED"]                      = "Rot"
L["OPT_COLOR_GREEN"]                    = "Grün"
L["OPT_COLOR_BLUE"]                     = "Blau"
L["OPT_COLOR_PURPLE"]                   = "Lila"
L["OPT_COLOR_WHITE"]                    = "Weiß"

-- Tutorial wizard
L["TUT_WELCOME_TITLE"]                  = "Willkommen bei EasyFind v%s"
L["TUT_WELCOME_SUBTITLE"]               = "Dein Shortcut zu allem in WoW."
L["TUT_FEATURES_TITLE"]                 = "Was du tun kannst"
L["TUT_FEATURES_SUBTITLE"]              = "Einmal tippen. Alles finden."
L["TUT_BTN_OPEN_BAR"]                   = "Leiste öffnen"
L["TUT_BTN_GET_STARTED"]                = "Loslegen"
L["TUT_BTN_CONTINUE"]                   = "Weiter"

-- Context menu
L["CTX_ADD_ALIAS"]                      = "Alias hinzufügen"
L["CTX_PIN"]                            = "Anheften"
L["CTX_UNPIN"]                          = "Lösen"
L["CTX_GUIDE"]                          = "Anleitung"
L["CTX_TRACK"]                          = "Verfolgen"
L["CTX_UNTRACK"]                        = "Nicht verfolgen"
L["CTX_TRANSFER"]                       = "Übertragen"
L["CTX_SUMMON"]                         = "Beschwören"
L["CTX_RENAME"]                         = "Umbenennen"
L["CTX_RELEASE"]                        = "Freilassen"

L["HEADER_PINNED"]                      = "Angeheftet"
