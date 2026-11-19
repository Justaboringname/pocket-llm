#!/usr/bin/env bash
# Builds the app for a physical iPhone, signed with the team in Config/Local.xcconfig.
#
# Usage: scripts/build-device.sh [--selftest] [--debug] [--destination '<xcodebuild destination>']
#   --selftest     compile the on-device self-test harness (SELFTEST condition)
#   --debug        Debug configuration (default: Release)
#   --destination  default: generic/platform=iOS (e.g. 'id=<device udid>' for one device)
#
# Prints the path of the built .app on the last line. Installing is a separate step, e.g.
#   xcrun devicectl device install app --device <udid> <path>
# The xcodebuild log (team id redacted) goes to .build/logs/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION=Release
SELFTEST=0
DESTINATION="generic/platform=iOS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1 ;;
    --debug) CONFIGURATION=Debug ;;
    --destination) DESTINATION="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "error: Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' Config/Local.xcconfig | head -1)"
if [[ -z "$TEAM" ]]; then
  echo "error: DEVELOPMENT_TEAM is empty in Config/Local.xcconfig." >&2
  exit 1
fi

# Optional guard: LLM_BUILD_GUARD='<regex>' refuses to start while a process whose command line
# matches it (pgrep -if) is running, e.g. a game or a benchmark. Unset = no guard.
if [[ -n "${LLM_BUILD_GUARD:-}" && -n "$(pgrep -ifl "$LLM_BUILD_GUARD" | grep -v LLM_BUILD_GUARD || true)" ]]; then
  echo "LLM_BUILD_GUARD matches a running process; not starting." >&2
  exit 1
fi

[[ -d LLMOnIPhone.xcodeproj ]] || xcodegen generate

DERIVED="$ROOT/.build/dd"
EXTRA=()
SUFFIX=""
if [[ $SELFTEST == 1 ]]; then
  EXTRA+=("SELFTEST_FLAG=SELFTEST")
  SUFFIX="-selftest"
fi

mkdir -p .build/logs
LOG=".build/logs/device-${CONFIGURATION}${SUFFIX}.log"
echo "Building $CONFIGURATION${SUFFIX:+ (selftest)} for $DESTINATION … (log: $LOG)"

set +e
xcodebuild \
  -project LLMOnIPhone.xcodeproj \
  -scheme LLMOnIPhone \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  build 2>&1 | sed -e "s/$TEAM/<team>/g" -e 's/Apple Development: [^"(]*/Apple Development: <redacted> /g' > "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

grep -E "(error|warning): " "$LOG" | grep -v "^ld: warning: ignoring duplicate" | sort -u | tail -40 || true
if [[ $STATUS -ne 0 ]]; then
  echo "BUILD FAILED (exit $STATUS). See $LOG" >&2
  exit "$STATUS"
fi

BUILT="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/LLMOnIPhone.app"
OUT="$ROOT/.build/products/${CONFIGURATION}${SUFFIX}-iphoneos"
mkdir -p "$OUT"
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$OUT/LLMOnIPhone.app"
ditto "$BUILT" "$OUT/LLMOnIPhone.app"
echo "BUILD SUCCEEDED"
echo "$OUT/LLMOnIPhone.app"
