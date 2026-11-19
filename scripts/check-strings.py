#!/usr/bin/env python3
"""Checks the String Catalogs against the strings the compiler extracted.

`xcodebuild` emits a `.stringsdata` file per Swift source (SWIFT_EMIT_LOC_STRINGS) but, unlike
the Xcode IDE, does not merge them into the source `.xcstrings`. This script compares the two
after a simulator build (scripts/build-sim.sh):

- keys used in code but missing from the catalog,
- keys in the catalog without a zh-Hans translation,
- catalog keys no longer used in code (stale; reported, not an error).

Exit code 1 when anything is missing.
"""

import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INTERMEDIATES = os.path.join(ROOT, ".build", "dd", "Build", "Intermediates.noindex")

TARGETS = [
    ("app", os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings"),
     "LLMOnIPhone.build/Debug-iphonesimulator/LLMOnIPhone.build/Objects-normal/arm64/*.stringsdata",
     os.path.join(ROOT, "App", "Sources")),
    ("LLMCore", os.path.join(ROOT, "Packages", "LLMCore", "Sources", "LLMCore", "Resources",
                             "Localizable.xcstrings"),
     "LLMCore.build/Debug-iphonesimulator/LLMCore*.build/Objects-normal/arm64/*.stringsdata",
     os.path.join(ROOT, "Packages", "LLMCore", "Sources")),
]


def extracted_keys(pattern, source_root):
    keys = {}
    for path in glob.glob(os.path.join(INTERMEDIATES, pattern), recursive=True):
        with open(path) as handle:
            data = json.load(handle)
        source = data.get("source", "")
        # Skip leftovers of deleted files and of other trees.
        if not source.startswith(source_root) or not os.path.exists(source):
            continue
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.setdefault(entry["key"], os.path.relpath(source, ROOT))
    return keys


def main():
    failed = False
    for name, catalog_path, pattern, source_root in TARGETS:
        with open(catalog_path) as handle:
            catalog = json.load(handle)["strings"]
        used = extracted_keys(pattern, source_root)
        manual = {k for k, v in catalog.items() if v.get("extractionState") == "manual"}
        missing = sorted(set(used) - set(catalog))
        untranslated = sorted(
            k for k, v in catalog.items()
            if v.get("shouldTranslate", True)
            and "zh-Hans" not in v.get("localizations", {}))
        stale = sorted(set(catalog) - set(used) - manual)
        print(f"[{name}] {len(used)} keys used, {len(catalog)} in catalog")
        for key in missing:
            print(f"  missing from catalog: {key!r}  ({used[key]})")
        for key in untranslated:
            print(f"  no zh-Hans: {key!r}")
        for key in stale:
            print(f"  stale (not used in code): {key!r}")
        if not used:
            print("  no .stringsdata found: build for the simulator first")
            failed = True
        failed = failed or bool(missing) or bool(untranslated)
    print("OK" if not failed else "FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
