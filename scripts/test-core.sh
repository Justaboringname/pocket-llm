#!/usr/bin/env bash
# Builds and tests the MLX-free core package on the Mac host (no Metal toolchain needed).
set -euo pipefail
cd "$(dirname "$0")/../Packages/LLMCore"
swift test "$@"
