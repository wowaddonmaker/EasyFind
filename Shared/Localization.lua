local _, ns = ...

-- Localization bootstrap. Locale files run after this and populate `L`
-- with translations.
--
-- Load order (from .toc):
--   1. Shared/Localization.lua  (this file - creates ns.L)
--   2. Locales/enUS.lua         (always loaded; source of truth)
--   3. Locales/<client>.lua     (deDE, frFR, ...; selectively overrides)
--
-- Lookup behavior:
--   1. If the active locale file set L[key], that string wins.
--   2. Otherwise the enUS value (set first) is returned.
--   3. If no locale set the key, the literal key string is returned so
--      missing translations are visible during development rather than
--      crashing or returning nil.
--
-- Design choice: keys are stable identifiers like "OPT_SMART_SHOW", not
-- the English text itself. ID-keyed locales survive copy edits without
-- silently desyncing every locale file.

local L = {}
ns.L = L

setmetatable(L, { __index = function(_, k)
    if type(k) == "string" then return k end
    return ""
end })
