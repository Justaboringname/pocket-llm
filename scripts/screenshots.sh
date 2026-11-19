#!/usr/bin/env bash
# Captures the DEBUG demo scenes (LLM_UI_DEMO) in the simulator: every scene in dark and light,
# in English and Simplified Chinese, into .build/screenshots/ (gitignored).
#
# Usage: scripts/screenshots.sh [options]
#   --device NAME        simulator name (default "iPhone 18 Pro"; newest runtime wins)
#   --scenes "a b"       scenes (default: onboarding ready chat streaming hot models settings about
#                        thermal)
#   --appearances "a b"  dark and/or light (default: "dark light")
#   --languages "a b"    en and/or zh-Hans (default: "en zh-Hans")
#   --accent HEX         render with this accent (DEBUG LLM_ACCENT override)
#   --content-size SIZE  Dynamic Type, e.g. extra-extra-extra-large (reset afterwards)
#   --out DIR            output directory (default .build/screenshots)
#   --suffix TEXT        appended to file names
#   --no-build           reuse the last Debug simulator build
#   --keep-booted        leave the simulator running
#
# Files are named <scene>-<language>-<appearance><suffix>.png, written without an alpha channel
# (App Store Connect rejects screenshots with alpha). The script honours LLM_BUILD_GUARD (see
# below), boots the simulator only if needed and shuts down only a simulator it booted itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE="iPhone 18 Pro"
SCENES="onboarding ready chat streaming hot models settings about thermal"
APPEARANCES="dark light"
LANGUAGES="en zh-Hans"
ACCENT=""
CONTENT_SIZE=""
OUT="$ROOT/.build/screenshots"
SUFFIX=""
BUILD=1
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift ;;
    --scenes) SCENES="$2"; shift ;;
    --appearances) APPEARANCES="$2"; shift ;;
    --languages) LANGUAGES="$2"; shift ;;
    --accent) ACCENT="$2"; shift ;;
    --content-size) CONTENT_SIZE="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --suffix) SUFFIX="$2"; shift ;;
    --no-build) BUILD=0 ;;
    --keep-booted) KEEP=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Optional guard: LLM_BUILD_GUARD='<regex>' refuses to start while a process whose command line
# matches it (pgrep -if) is running, e.g. a game or a benchmark. Unset = no guard.
if [[ -n "${LLM_BUILD_GUARD:-}" && -n "$(pgrep -ifl "$LLM_BUILD_GUARD" | grep -v LLM_BUILD_GUARD || true)" ]]; then
  echo "LLM_BUILD_GUARD matches a running process; not starting." >&2
  exit 1
fi

if [[ $BUILD == 1 ]]; then
  APP="$(scripts/build-sim.sh | tail -1)"
else
  APP="$ROOT/.build/products/Debug-iphonesimulator/LLMOnIPhone.app"
fi
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }
# The bundle id carries the private prefix from Local.xcconfig: keep it in a variable, never print it.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"

UDID="$(xcrun simctl list -j devices available | python3 -c '
import json, re, sys
name = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(p) for p in re.findall(r"\d+", runtime.rsplit(".", 1)[-1])]
best = None
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    for d in entries:
        if d["name"] == name and (best is None or version(runtime) > version(best[0])):
            best = (runtime, d["udid"])
print(best[1] if best else "")
' "$DEVICE")"
[[ -n "$UDID" ]] || { echo "No simulator named $DEVICE" >&2; exit 1; }

BOOTED_HERE=0
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  xcrun simctl boot "$UDID"
  BOOTED_HERE=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

cleanup() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [[ -n "$CONTENT_SIZE" ]]; then xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1 || true; fi
  if [[ $BOOTED_HERE == 1 && $KEEP == 0 ]]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
if [[ -n "$CONTENT_SIZE" ]]; then xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE"; fi

mkdir -p "$OUT"
CAPTURED=()
for appearance in $APPEARANCES; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for language in $LANGUAGES; do
    case "$language" in
      zh-Hans) LOCALE="zh_CN" ;;
      *) LOCALE="en_US" ;;
    esac
    for scene in $SCENES; do
      xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
      SIMCTL_CHILD_LLM_UI_DEMO="$scene" SIMCTL_CHILD_LLM_ACCENT="$ACCENT" \
        xcrun simctl launch "$UDID" "$BUNDLE_ID" \
        -AppleLanguages "($language)" -AppleLocale "$LOCALE" >/dev/null
      case "$scene" in
        streaming|hot) sleep 6 ;;
        models|settings|about) sleep 3.5 ;;
        *) sleep 3 ;;
      esac
      FILE="$OUT/${scene}-${language}-${appearance}${SUFFIX}.png"
      xcrun simctl io "$UDID" screenshot --type=png "$FILE" >/dev/null 2>&1
      CAPTURED+=("$FILE")
      echo "$(basename "$FILE")"
    done
  done
done

# simctl writes RGBA PNGs; App Store Connect rejects alpha. Re-encode as opaque RGB.
swift scripts/strip-alpha.swift "${CAPTURED[@]}"

FIRST="$(ls "$OUT"/*.png | head -1)"
SIZE="$(sips -g pixelWidth -g pixelHeight "$FIRST" | awk '/pixel/ {print $2}' | paste -sd x -)"
echo "Captured into ${OUT#$ROOT/} ($SIZE px)"
