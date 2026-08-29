#!/usr/bin/env python3
"""Locale value-leak check: no locale may ship enUS's English for a real
sentence. Parity (key sets) and reference checks live in CI/pre-commit
already; this closes the third hole, where a locale file carries the key
with the untranslated English VALUE pasted in (seven locales shipped the
Shortkeys tutorial slide in raw English for months this way).

A value is flagged when it is byte-identical to the enUS value AND the
English looks like prose (>= MIN_WORDS words of 2+ letters). Short
identical values -- brand names, "App", key tokens, "%d/%d" formats --
never trip it. Keys that are legitimately identical prose across a locale
belong in ALLOWED_IDENTICAL.

Exit 0 = clean, 1 = leaks found. Run from the addon root:
    python tests/check_locale_values.py
"""

import glob
import re
import sys

MIN_WORDS = 5

# key -> set of locale basenames allowed to keep the enUS value verbatim.
# Use "*" for all locales. Keep this list justified: every entry is a claim
# that the identical text is correct, not a missed translation.
ALLOWED_IDENTICAL = {
    # (none yet)
}

PAIR = re.compile(r'L\["([A-Z0-9_]+)"\]\s*=\s*(".*?")\s*(?:\.\.|\n|$)')


def read_values(path):
    """key -> full concatenated string literal source (multi-line .. chains
    are joined so a leak in any fragment still compares whole-for-whole)."""
    src = open(path, encoding="utf-8").read()
    values = {}
    # Concatenated literals: capture everything from = to the end of the
    # statement (the last quoted fragment not followed by ..).
    stmt = re.compile(
        r'L\["([A-Z0-9_]+)"\]\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*(?:\.\.\s*)?)+)')
    for m in stmt.finditer(src):
        key = m.group(1)
        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2))
        values[key] = "".join(parts)
    return values


def word_count(text):
    return len(re.findall(r"[A-Za-z]{2,}", text))


def main():
    enus = read_values("Locales/enUS.lua")
    if not enus:
        print("FAIL: could not parse Locales/enUS.lua")
        return 1
    leaks = 0
    for path in sorted(glob.glob("Locales/*.lua")):
        base = path.replace("\\", "/").rsplit("/", 1)[-1]
        if base in ("enUS.lua", "Localization.lua"):
            continue
        theirs = read_values(path)
        for key, value in theirs.items():
            en = enus.get(key)
            if en is None or value != en:
                continue
            if word_count(en) < MIN_WORDS:
                continue
            allowed = ALLOWED_IDENTICAL.get(key, set())
            if "*" in allowed or base in allowed:
                continue
            leaks += 1
            print(f"LEAK: {base} {key} is untranslated enUS text:")
            print(f"      {en[:120]}{'...' if len(en) > 120 else ''}")
    if leaks:
        print(f"\nFAIL: {leaks} untranslated value(s). Translate them, or if "
              f"the identical text is genuinely correct, add the key to "
              f"ALLOWED_IDENTICAL in tests/check_locale_values.py.")
        return 1
    print("Locale values OK: no untranslated enUS prose in any locale.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
