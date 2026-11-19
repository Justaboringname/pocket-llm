#!/usr/bin/env bash
# Runs the SELFTEST harness in the simulator (mock store + mock engine): three chat turns through
# ChatViewModel with the real UI on screen, then copies the result JSON and the per-turn
# screenshots to .build/selftest/.
#
# Usage: scripts/selftest-sim.sh [--model ID] [--device NAME] [--thinking] [--greedy] [--no-build]
#   --model    catalog id (default qwen3-0.6b-4bit)
#   --device   simulator name (default "iPhone 18 Pro"; newest runtime wins)
#   --thinking enable thinking for the turns
#   --greedy   temperature 0 for every turn (the mock ignores it; checks the plumbing)
# Exit code 0 when the self-test passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODEL="qwen3-0.6b-4bit"
DEVICE="iPhone 18 Pro"
THINKING=0
GREEDY=0
BUILD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift ;;
    --device) DEVICE="$2"; shift ;;
    --thinking) THINKING=1 ;;
    --greedy) GREEDY=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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
  APP="$(scripts/build-sim.sh --selftest | tail -1)"
else
  APP="$ROOT/.build/products/Debug-selftest-iphonesimulator/LLMOnIPhone.app"
fi
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
cleanup() {
  if [[ $BOOTED_HERE == 1 ]]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

OUT="$ROOT/.build/selftest"
mkdir -p "$OUT"
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
FILES=(selftest-result.json selftest-turn1.png selftest-turn2.png selftest-turn3.png)
# Remove results of earlier runs so a crash cannot leave a stale "passed".
for file in "${FILES[@]}"; do
  for path in "$DATA/Documents/$file" "$OUT/$file"; do
    if [[ -f "$path" ]]; then python3 -c 'import os,sys; os.remove(sys.argv[1])' "$path"; fi
  done
done
LOG="$OUT/selftest-$MODEL.out"
SIMCTL_CHILD_LLM_SELFTEST="$MODEL" SIMCTL_CHILD_LLM_SELFTEST_SCREENSHOTS=1 \
  SIMCTL_CHILD_LLM_SELFTEST_THINKING="$THINKING" SIMCTL_CHILD_LLM_SELFTEST_GREEDY="$GREEDY" \
  xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" \
  | tee "$LOG" | grep --line-buffered '^SELFTEST' | cut -c1-200 || true

for file in "${FILES[@]}"; do
  if [[ -f "$DATA/Documents/$file" ]]; then cp "$DATA/Documents/$file" "$OUT/"; fi
done
python3 - "$OUT/selftest-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(f"passed={result['passed']} failure={result.get('failure')} format={result.get('formatVersion')} "
      f"greedy={result.get('greedy')} longTurnCheck={result.get('longTurnCheck')} "
      f"turns={[t['answer'][:60] for t in result['turns']]}")
for t in result["turns"]:
    sp = t.get("sampling") or {}
    print(f"  turn {t['turn']}: {t['state']}, {(t.get('stats') or {}).get('generatedTokens')} tokens, "
          f"sampler {sp.get('sampler')} T={sp.get('temperature')}")
sys.exit(0 if result["passed"] else 1)
PY
