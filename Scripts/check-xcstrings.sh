#!/usr/bin/env bash
# Localization gate for ComiNavi.
#
# English is the source language and Japanese is a translation. This script
# fails when:
#   - the project's developmentRegion is not `en`, or `en` is missing from knownRegions;
#   - a string catalog does not use `en` as its source language, or has no `en` units;
#   - a catalog key contains CJK text (keys must be English source strings);
#   - a translatable entry lacks a translated ja, ko, zh-Hans, or zh-Hant value;
#   - a translation uses different format placeholders than its key;
#   - a Swift string literal in the app target (not tests or fixtures) contains CJK text.
#
# Legitimate exceptions (Japanese data that the app parses or matches, such as
# hall names and space codes) go in scripts/xcstrings-allowlist.txt, or on a
# single line with a trailing `// l10n-allow-cjk` comment.
#
# Usage: scripts/check-xcstrings.sh [repo-root]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$script_dir/.." && pwd)}"

exec python3 -I - "$root" "$script_dir/xcstrings-allowlist.txt" <<'PY'
import glob
import json
import os
import re
import sys

root, allowlist_path = sys.argv[1], sys.argv[2]
cjk = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯＀-￯]")
placeholder = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(lld|ld|lu|llu|d|i|u|f|@|s|c|x|X|e|g)")
literal = re.compile(r'"(?:[^"\\\n]|\\.)*"')
languages = ["ja", "ko", "zh-Hans", "zh-Hant"]

allowed_files, allowed_keys = set(), set()
if os.path.exists(allowlist_path):
    for raw in open(allowlist_path, encoding="utf-8"):
        line = raw.split("  #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        kind, _, value = line.partition(":")
        if kind == "file":
            allowed_files.add(value.strip())
        elif kind == "key":
            allowed_keys.add(value.strip())

errors = []

def placeholders(text):
    # Positional specifiers (%2$@) may reorder arguments, so compare the sorted types.
    return sorted(kind for _, kind in placeholder.findall(text))

def values(localization):
    if "stringUnit" in localization:
        unit = localization["stringUnit"]
        return [(unit.get("state"), unit.get("value", ""))]
    found = []
    for variation in localization.get("variations", {}).values():
        for case in variation.values():
            found.extend(values(case))
    return found

project = open(os.path.join(root, "ComiNavi.xcodeproj/project.pbxproj"), encoding="utf-8").read()
if "developmentRegion = en;" not in project:
    errors.append("project.pbxproj: developmentRegion must be en")
regions = re.search(r"knownRegions = \(([^)]*)\)", project)
if not regions or not re.search(r"(?m)^\s*en,\s*$", regions.group(1)):
    errors.append("project.pbxproj: knownRegions must contain en")

for path in sorted(glob.glob(os.path.join(root, "ComiNavi", "**", "*.xcstrings"), recursive=True)):
    name = os.path.relpath(path, root)
    catalog = json.load(open(path, encoding="utf-8"))
    if catalog.get("sourceLanguage") != "en":
        errors.append(f"{name}: sourceLanguage must be en")
    strings = catalog.get("strings", {})
    if strings and not any("en" in entry.get("localizations", {}) for entry in strings.values()):
        errors.append(f"{name}: table has no en units")
    for key, entry in strings.items():
        if cjk.search(key) and key not in allowed_keys:
            errors.append(f"{name}: key contains CJK text: {key!r}")
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        for language in languages:
            found = values(localizations.get(language, {}))
            if not found or any(state != "translated" or not value for state, value in found):
                errors.append(f"{name}: {language} translation missing or not reviewed: {key!r}")
                continue
            expected = placeholders(key)
            for _, value in found:
                if placeholders(value) != expected:
                    errors.append(f"{name}: {language} placeholders differ from key: {key!r}")
                    break

for path in sorted(glob.glob(os.path.join(root, "ComiNavi", "**", "*.swift"), recursive=True)):
    name = os.path.relpath(path, root)
    if name in allowed_files or "/Fixtures/" in name:
        continue
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        stripped = line.strip()
        if stripped.startswith("//") or "l10n-allow-cjk" in line:
            continue
        for match in literal.finditer(line):
            if cjk.search(match.group()) and match.group()[1:-1] not in allowed_keys:
                errors.append(f"{name}:{number}: Swift literal contains CJK text: {match.group()}")

if errors:
    print("\n".join(errors))
    print(f"\ncheck-xcstrings: {len(errors)} problem(s)", file=sys.stderr)
    sys.exit(1)
print("check-xcstrings: OK")
PY
