#!/usr/bin/env bash
# Builds the app for the iOS Simulator (mock store + mock engine; MLX cannot run there).
#
# Usage: scripts/build-sim.sh [--selftest] [--release] [--destination '<xcodebuild destination>']
#   default destination: generic/platform=iOS Simulator
# Prints the path of the built .app on the last line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION=Debug
SELFTEST=0
DESTINATION="generic/platform=iOS Simulator"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1 ;;
    --release) CONFIGURATION=Release ;;
    --destination) DESTINATION="$2"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
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

[[ -d LLMOnIPhone.xcodeproj ]] || xcodegen generate

DERIVED="$ROOT/.build/dd"
EXTRA=()
SUFFIX=""
if [[ $SELFTEST == 1 ]]; then
  EXTRA+=("SELFTEST_FLAG=SELFTEST")
  SUFFIX="-selftest"
fi

mkdir -p .build/logs
LOG=".build/logs/sim-${CONFIGURATION}${SUFFIX}.log"
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
  ${EXTRA[@]+"${EXTRA[@]}"} \
  build > "$LOG" 2>&1
STATUS=$?
set -e

grep -E "(error|warning): " "$LOG" | sort -u | tail -40 || true
if [[ $STATUS -ne 0 ]]; then
  echo "BUILD FAILED (exit $STATUS). See $LOG" >&2
  exit "$STATUS"
fi

BUILT="$DERIVED/Build/Products/${CONFIGURATION}-iphonesimulator/LLMOnIPhone.app"
OUT="$ROOT/.build/products/${CONFIGURATION}${SUFFIX}-iphonesimulator"
mkdir -p "$OUT"
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$OUT/LLMOnIPhone.app"
ditto "$BUILT" "$OUT/LLMOnIPhone.app"
echo "BUILD SUCCEEDED"
echo "$OUT/LLMOnIPhone.app"
