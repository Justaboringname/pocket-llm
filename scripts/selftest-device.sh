#!/usr/bin/env bash
# Runs the SELFTEST harness on the one connected physical iPhone: build (Release, --selftest),
# install, launch with the console attached, collect the result JSON and the three per-turn
# screenshots, and print a compact summary.
#
# Usage: scripts/selftest-device.sh [options]
#   --model ID       catalog id (default qwen3-1.7b-4bit)
#   --thinking       turn thinking on for every turn
#   --greedy         temperature 0 for every turn (deterministic; compare with a reference)
#   --delete-after   unload and delete the model after a passing run
#   --keep-alive     leave the app running afterwards (the script stops waiting at "done")
#   --no-build       reuse .build/products/Release-selftest-iphoneos/LLMOnIPhone.app
#   --no-install     do not install; the app must already be on the phone
#   --timeout SEC    limit for the launched run, download included (default 5400)
#   --dry-run        read-only: query the phone, print the (redacted) commands, change nothing
#   --summary FILE   only print the summary of an existing selftest-result.json
# Output: .build/selftest-device/<model>/ (console.log, selftest-result.json, selftest-turn1..3.png).
# --summary reads result formats 2 (two turns) and 3 (three turns, sampling, retries; newer
# format-3 results may add a per-turn thinkingPromoted flag).
# Exit code 0 when the self-test passed. The device identifier, team id and bundle id are never
# printed; console.log has the device identifier and bundle id redacted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODEL="qwen3-1.7b-4bit"
THINKING=0
GREEDY=0
DELETE_AFTER=0
KEEP_ALIVE=0
BUILD=1
INSTALL=1
TIMEOUT=5400
DRY_RUN=0
SUMMARY_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift ;;
    --thinking) THINKING=1 ;;
    --greedy) GREEDY=1 ;;
    --delete-after) DELETE_AFTER=1 ;;
    --keep-alive) KEEP_ALIVE=1 ;;
    --no-build) BUILD=0 ;;
    --no-install) INSTALL=0 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --summary) SUMMARY_ONLY="$2"; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Prints a compact summary of a selftest-result.json; exits 0 only for a passing, fresh result.
# Second argument: earliest acceptable start time (epoch seconds), 0 = do not check.
summarize() {
  python3 - "$1" "${2:-0}" <<'PY'
import json, sys
from datetime import datetime

path, not_before = sys.argv[1], float(sys.argv[2])
try:
    r = json.load(open(path))
except (OSError, ValueError) as error:
    print(f"FAIL  no readable result ({error})")
    sys.exit(1)

def gb(value):
    return "?" if value is None else f"{value / 1e9:.2f} GB"

def num(value, fmt):
    return "?" if value is None else format(value, fmt)

def limit(memory):
    if not memory or memory.get("availableBytes") is None:
        return None
    return memory["availableBytes"] + memory["footprintBytes"]

def started(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None

def sampling_text(sp):
    seed = sp.get("seed")
    note = "" if sp.get("seedControlsSampling") else " (not used by the sampler)"
    return (f"{sp.get('sampler', '?')} T={num(sp.get('temperature'), 'g')} "
            f"topP={num(sp.get('topP'), 'g')} topK={sp.get('topK', '?')} "
            f"minP={num(sp.get('minP'), 'g')} maxTokens={sp.get('maxTokens', '?')} "
            f"seed={seed}{note if seed is not None else ''}")

stale = not_before > 0 and (started(r.get("startedAt")) or 0) < not_before
passed = bool(r.get("passed")) and not stale
device = r.get("device") or {}
ent = r.get("entitlements") or device.get("entitlements") or {}
# Format 2 has two turns and no greedy/longTurnCheck/sampling/retries; format 3 adds them.
print(f"{'PASS' if passed else 'FAIL'}  {r.get('modelID')}  thinking={'on' if r.get('thinking') else 'off'}"
      f"  greedy={'on' if r.get('greedy') else 'off'}"
      f"  lastStage={r.get('lastStage')}  dependentTurnCheck={r.get('dependentTurnCheck')}"
      + (f"  longTurnCheck={r.get('longTurnCheck')}" if "longTurnCheck" in r else "")
      + f"  (format {r.get('formatVersion', '?')})")
if stale:
    print("  stale result: it is older than this run (the app may have crashed before writing)")
if r.get("error"):
    e = r["error"]
    print(f"  error: [{e.get('stage')}] {e.get('type')}: {e.get('message')}")
print(f"  device: {device.get('machine', '?')}, iOS {device.get('systemVersion', '?')}, "
      f"thermal at start {device.get('thermalState', '?')}, low power {device.get('lowPowerMode', '?')}")
download = r.get("download") or {}
if download:
    retries = download.get("retries")
    took = "already on the phone" if download.get("alreadyPresent") else f"{num(download.get('seconds'), '.1f')} s"
    count = "" if retries is None else f", {len(retries)} automatic retr{'y' if len(retries) == 1 else 'ies'}"
    print(f"  download: {took}, {gb(download.get('bytesOnDisk'))} on disk{count}")
    for x in retries or []:
        print(f"    retry {x.get('retry')}: {x.get('errorDomain')} {x.get('errorCode')} "
              f"({x.get('errorMessage')}), waited {num(x.get('delaySeconds'), 'g')} s")
    if download.get("failureMessage"):
        print(f"    shown to the user: {download['failureMessage']}")
load = r.get("load") or {}
if load:
    mem = load.get("memory") or {}
    print(f"  load: {num(load.get('seconds'), '.1f')} s, fit {load.get('memoryFit')}, "
          f"footprint {gb(mem.get('footprintBytes'))}, process limit {gb(limit(mem))}")
print(f"  increased-memory-limit: signed={ent.get('increasedMemoryLimitSigned')} "
      f"profile={ent.get('increasedMemoryLimitInProfile')}")
for turn in r.get("turns", []):
    s = turn.get("stats") or {}
    mem = turn.get("memory") or {}
    answer = (turn.get("answer") or "").replace("\n", " ")
    chars = turn.get("answerCharacters")
    # thinkingPromoted is an optional key (absent in older format-3 results).
    print(f"  turn {turn.get('turn')}: {turn.get('state')}"
          f"{' (length limit)' if turn.get('truncated') else ''}"
          f"{' (thinking never closed; shown as the answer)' if turn.get('thinkingPromoted') else ''}, "
          f"{num(s.get('tokensPerSecond'), '.1f')} tok/s, "
          f"prompt {s.get('promptTokens', '?')} tok @ {num(s.get('promptTokensPerSecond'), '.0f')} tok/s, "
          f"TTFT {num(s.get('timeToFirstToken'), '.2f')} s, "
          f"{s.get('generatedTokens', '?')} tokens, stop {s.get('stopReason', '?')}, "
          f"thermal {turn.get('thermalState')}, footprint {gb(mem.get('footprintBytes'))}, "
          f"answer {answer[:40]!r}{'' if chars is None else f' ({chars} chars)'}")
    sp = turn.get("sampling") or s.get("sampling")
    if sp:
        print(f"    sampling: {sampling_text(sp)}")
final = r.get("finalMemory") or {}
print(f"  end: thermal {r.get('finalThermalState', '?')}, footprint {gb(final.get('footprintBytes'))}, "
      f"process limit {gb(limit(final))}")
cleanup = r.get("cleanup")
if cleanup:
    if cleanup.get("deleted"):
        print(f"  cleanup: deleted, freed {gb(cleanup.get('freedBytes'))}")
    else:
        print(f"  cleanup: not deleted ({cleanup.get('skippedReason') or (cleanup.get('error') or {}).get('message')})")
sys.exit(0 if passed else 1)
PY
}

if [[ -n "$SUMMARY_ONLY" ]]; then
  summarize "$SUMMARY_ONLY"
  exit $?
fi

# Optional guard: LLM_BUILD_GUARD='<regex>' refuses to start while a process whose command line
# matches it (pgrep -if) is running, e.g. a game or a benchmark. Unset = no guard.
if [[ -n "${LLM_BUILD_GUARD:-}" && -n "$(pgrep -ifl "$LLM_BUILD_GUARD" | grep -v LLM_BUILD_GUARD || true)" ]]; then
  echo "LLM_BUILD_GUARD matches a running process; not starting." >&2
  exit 1
fi

# Catalog ids: an `id: "…"` line directly followed by a `repoID:` line in ModelCatalog.swift.
KNOWN_MODELS="$(awk '/^[[:space:]]*id: "/ { id = $0; getline next_line
  if (next_line ~ /repoID:/) { gsub(/.*id: "|",?[[:space:]]*$/, "", id); printf "%s ", id } }' \
  Packages/LLMCore/Sources/LLMCore/Catalog/ModelCatalog.swift)"
if [[ " $KNOWN_MODELS " != *" $MODEL "* ]]; then
  echo "Unknown model '$MODEL'. Known: $KNOWN_MODELS" >&2
  exit 2
fi

DEVICECTL="$(xcrun -f devicectl)"
TMP="$(mktemp -d)"
cleanup_tmp() { python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$TMP"; }
trap cleanup_tmp EXIT

# Prints a command with the identifiers replaced, for --dry-run.
show() {
  local line="$*"
  [[ -n "${DEV:-}" ]] && line="${line//$DEV/<device>}"
  [[ -n "${BID:-}" ]] && line="${line//$BID/<bundle-id>}"
  line="${line//$ROOT\//}"
  echo "  $line"
}

# 1. The one connected physical iPhone (read-only query).
DEV=""
"$DEVICECTL" list devices --json-output "$TMP/devices.json" --quiet --timeout 60 >/dev/null 2>&1 || true
DEVICE_LINE="$(python3 - "$TMP/devices.json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, ValueError, KeyError):
    print("error\tcould not list devices"); sys.exit()
phones = [d for d in devices
          if d.get("properties", {}).get("hardware", {}).get("reality") == "physical"
          and d.get("properties", {}).get("hardware", {}).get("deviceType") == "iPhone"
          and d.get("properties", {}).get("connection", {}).get("pairingState") == "paired"]
if len(phones) != 1:
    names = ", ".join(p["properties"]["hardware"].get("marketingName", "iPhone") for p in phones)
    print(f"error\tfound {len(phones)} paired physical iPhones{': ' + names if names else ''}")
else:
    p = phones[0]["properties"]
    # Other identifiers of the same phone, only so they can be redacted from the console log.
    aliases = ",".join(str(v) for v in (p["hardware"].get("udid"), p["hardware"].get("ecid"),
                                         p["hardware"].get("serialNumber")) if v)
    version = p.get("software", {}).get("osVersionNumber", "?")
    if isinstance(version, dict):
        version = version.get("stringValue", "?")
    print(f"ok\t{phones[0]['identifier']}\t{p['hardware'].get('marketingName', 'iPhone')}\t"
          f"{version}\t{aliases}")
PY
)"
IFS=$'\t' read -r DEVICE_STATUS DEVICE_FIELD2 DEVICE_NAME DEVICE_OS DEVICE_ALIASES <<<"$DEVICE_LINE"
if [[ "$DEVICE_STATUS" == "ok" ]]; then
  DEV="$DEVICE_FIELD2"
  echo "Device: $DEVICE_NAME, iOS $DEVICE_OS"
elif [[ $DRY_RUN == 1 ]]; then
  echo "Device: none usable ($DEVICE_FIELD2); continuing the dry run with placeholders"
  DEV="<device>"
else
  echo "Need exactly one paired physical iPhone: $DEVICE_FIELD2" >&2
  exit 1
fi

# 2. The app to install (the bundle id is read from it and never printed).
APP="$ROOT/.build/products/Release-selftest-iphoneos/LLMOnIPhone.app"
BUILD_CMD="scripts/build-device.sh --selftest"
if [[ $BUILD == 1 ]]; then
  if [[ $DRY_RUN == 1 ]]; then
    echo "Would build:"; show "$BUILD_CMD"
  else
    APP="$($BUILD_CMD | tail -1)"
  fi
fi
BID=""
if [[ -f "$APP/Info.plist" ]]; then
  BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
  if ! grep -q "selftest-result.json" < <(strings "$APP/LLMOnIPhone"); then
    if [[ $DRY_RUN == 1 ]]; then
      echo "Note: the current build at ${APP#$ROOT/} has no self-test harness (build with --selftest)."
    else
      echo "${APP#$ROOT/} was built without the self-test harness. Rebuild with scripts/build-device.sh --selftest." >&2
      exit 1
    fi
  fi
elif [[ $DRY_RUN == 1 ]]; then
  BID="<bundle-id>"
else
  echo "No app at ${APP#$ROOT/}. Run without --no-build." >&2
  exit 1
fi

# 3. Free Personal Team: at most 3 development-signed apps per device (read-only query).
APPS_STATUS="unknown"
if [[ "$DEVICE_STATUS" == "ok" ]]; then
  if "$DEVICECTL" device info apps --device "$DEV" --json-output "$TMP/apps.json" --quiet --timeout 120 >/dev/null 2>&1; then
    APPS_STATUS="$(python3 - "$TMP/apps.json" "$BID" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1])).get("result", {}).get("apps", [])
ours = any(a.get("bundleIdentifier") == sys.argv[2] for a in apps)
others = [a.get("name") or "?" for a in apps
          if a.get("builtByDeveloper") and a.get("bundleIdentifier") != sys.argv[2]]
print(("installed" if ours else "missing") + "\t" + str(len(others)) + "\t" + ", ".join(others))
PY
)"
  else
    APPS_STATUS="unknown"
    if [[ $DRY_RUN == 1 ]]; then
      echo "Could not list the apps on the phone (locked, asleep or off the network?)."
    else
      echo "Could not list the apps on the phone (locked, asleep or off the network?). Unlock it, keep it awake and run again." >&2
      exit 1
    fi
  fi
fi
IFS=$'\t' read -r INSTALLED OTHER_COUNT OTHER_NAMES <<<"$APPS_STATUS"
if [[ "$INSTALLED" == "missing" && "${OTHER_COUNT:-0}" -ge 3 ]]; then
  echo "This app is not installed and the phone already has $OTHER_COUNT other development-signed apps:" >&2
  echo "  $OTHER_NAMES" >&2
  echo "A free Personal Team allows 3 per device. Remove one yourself, then run this again." >&2
  exit 1
fi
if [[ "$INSTALLED" == "missing" && $INSTALL == 0 ]]; then
  echo "The app is not installed on the phone; run without --no-install." >&2
  exit 1
fi
[[ "$INSTALLED" != "unknown" ]] && echo "Development-signed apps already on the phone (excluding this one): ${OTHER_COUNT:-0}"

OUT="$ROOT/.build/selftest-device/$MODEL"
LOG="$OUT/console.log"
ENV_JSON="$(python3 -c '
import json, sys
model, thinking, greedy, delete_after, keep_alive = sys.argv[1:6]
env = {"LLM_SELFTEST": model, "LLM_SELFTEST_SCREENSHOTS": "1"}
if thinking == "1": env["LLM_SELFTEST_THINKING"] = "1"
if greedy == "1": env["LLM_SELFTEST_GREEDY"] = "1"
if delete_after == "1": env["LLM_SELFTEST_DELETE_AFTER"] = "1"
if keep_alive == "1": env["LLM_SELFTEST_KEEP_ALIVE"] = "1"
print(json.dumps(env, sort_keys=True))
' "$MODEL" "$THINKING" "$GREEDY" "$DELETE_AFTER" "$KEEP_ALIVE")"
INSTALL_CMD=("$DEVICECTL" device install app --device "$DEV" "$APP" --quiet --timeout 900)
LAUNCH_CMD=("$DEVICECTL" device process launch --device "$DEV" --terminate-existing --console
  --timeout "$TIMEOUT" --environment-variables "$ENV_JSON" "$BID")
FILES=(selftest-result.json selftest-turn1.png selftest-turn2.png selftest-turn3.png)

if [[ $DRY_RUN == 1 ]]; then
  echo "Would run:"
  [[ $INSTALL == 1 ]] && show "${INSTALL_CMD[*]}"
  show "${LAUNCH_CMD[*]}  > ${LOG#$ROOT/}"
  for file in "${FILES[@]}"; do
    show "$DEVICECTL device copy from --device $DEV --domain-type appDataContainer --domain-identifier $BID --source Documents/$file --destination ${OUT#$ROOT/}/$file --quiet --timeout 120"
  done
  echo "Then: scripts/selftest-device.sh --summary ${OUT#$ROOT/}/selftest-result.json"
  exit 0
fi

# 4. Install.
if [[ $INSTALL == 1 ]]; then
  echo "Installing…"
  "${INSTALL_CMD[@]}" >/dev/null
fi

# 5. Launch with the console attached; the run downloads the model if needed, so it can be long.
mkdir -p "$OUT"
for file in "${FILES[@]}" console.log; do
  if [[ -f "$OUT/$file" ]]; then python3 -c 'import os,sys; os.remove(sys.argv[1])' "$OUT/$file"; fi
done
START_EPOCH="$(python3 -c 'import time; print(int(time.time()) - 5)')"
echo "Launching the self-test ($MODEL, thinking $([[ $THINKING == 1 ]] && echo on || echo off), greedy $([[ $GREEDY == 1 ]] && echo on || echo off)); keep the phone unlocked."
# Redact the device identifiers and the bundle id in everything devicectl prints.
REDACT=(python3 -u -c '
import sys
device, aliases, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
secrets = [(s, "<device>") for s in [device] + aliases.split(",") if s] + [(bundle, "<bundle-id>")]
for line in sys.stdin:
    for secret, label in secrets:
        line = line.replace(secret, label)
    sys.stdout.write(line)
    sys.stdout.flush()
' "$DEV" "${DEVICE_ALIASES:-}" "$BID")
{
  # stdin from /dev/null: a background job that reads the terminal would be stopped (SIGTTIN).
  "${LAUNCH_CMD[@]}" </dev/null &
  echo $! >"$TMP/launch.pid"
  set +e
  wait $!
  echo $? >"$TMP/launch.status"
} 2>&1 | "${REDACT[@]}" >"$LOG" &
PIPELINE=$!
while [[ ! -s "$TMP/launch.pid" ]]; do sleep 0.2; done
LAUNCH_PID="$(cat "$TMP/launch.pid")"

SEEN=0
print_new_lines() {
  local total
  total="$(wc -l <"$LOG" | tr -d ' ')"
  if [[ "$total" -gt "$SEEN" ]]; then
    sed -n "$((SEEN + 1)),${total}p" "$LOG" | grep '^SELFTEST' | cut -c1-160 || true
    SEEN="$total"
  fi
}
while kill -0 "$LAUNCH_PID" 2>/dev/null; do
  sleep 2
  print_new_lines
  if [[ $KEEP_ALIVE == 1 ]] && grep -q '^SELFTEST .*"event":"done"' "$LOG"; then
    # SIGKILL is not forwarded to the app (catchable signals are), so the app keeps running.
    kill -9 "$LAUNCH_PID" 2>/dev/null || true
    break
  fi
done
wait "$PIPELINE" 2>/dev/null || true
print_new_lines
LAUNCH_STATUS="$(cat "$TMP/launch.status" 2>/dev/null || echo "?")"
[[ "$LAUNCH_STATUS" == "0" || $KEEP_ALIVE == 1 ]] || echo "devicectl launch exited with status $LAUNCH_STATUS"

# 6. Collect the result and screenshots from the app's data container.
for file in "${FILES[@]}"; do
  if "$DEVICECTL" device copy from --device "$DEV" --domain-type appDataContainer \
    --domain-identifier "$BID" --source "Documents/$file" --destination "$OUT/$file" \
    --quiet --timeout 120 >/dev/null 2>&1; then
    echo "Copied $file"
  else
    echo "Could not copy $file"
  fi
done

echo "Results in ${OUT#$ROOT/}/"
summarize "$OUT/selftest-result.json" "$START_EPOCH"
