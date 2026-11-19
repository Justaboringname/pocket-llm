#!/usr/bin/env bash
# Runs the UI tests (App/UITests) in the simulator against the DEBUG demo backend.
#
# Usage: scripts/test-ui.sh [--device NAME]   (default "iPhone 18 Pro"; newest runtime wins)
# The xcodebuild log goes to .build/logs/ui-tests.log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE="iPhone 18 Pro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
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

[[ -d LLMOnIPhone.xcodeproj ]] || xcodegen generate
mkdir -p .build/logs
LOG=".build/logs/ui-tests.log"
echo "Running UI tests on $DEVICE … (log: $LOG)"
set +e
xcodebuild test \
  -project LLMOnIPhone.xcodeproj \
  -scheme LLMOnIPhone \
  -destination "id=$UDID" \
  -derivedDataPath "$ROOT/.build/dd" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  > "$LOG" 2>&1
STATUS=$?
set -e
grep -E "Test Case .* (passed|failed)|error: |\*\* TEST" "$LOG" | sed -e 's/^.*Test Case/Test Case/' || true
exit "$STATUS"
