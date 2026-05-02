#!/usr/bin/env bash
# run_perf_benchmarks.sh
#
# Runs the performance benchmark tests in Flutter profile mode so that AOT
# compilation and Dart VM optimisations closely match a release build.
#
# Profile mode produces more meaningful frame-timing data than the default
# debug/JIT mode used by `flutter test` without flags.
#
# Usage:
#   scripts/run_perf_benchmarks.sh [--device <device-id>] [-- <extra flutter test args>]
#
# Examples:
#   # Run all perf tests on the host VM (no physical device needed)
#   scripts/run_perf_benchmarks.sh
#
#   # Run on a connected iOS simulator
#   scripts/run_perf_benchmarks.sh --device "iPhone 16 Pro"
#
#   # Run with verbose output
#   scripts/run_perf_benchmarks.sh -- --reporter expanded
#
# Output:
#   Each PerfResult printed via debugPrint shows:
#     - Scenario name
#     - Total rebuild count (via RebuildTracker)
#     - Frame count (via FrameTimingCollector)
#     - Average frame-build duration in microseconds
#
# Interpreting results:
#   * rebuildCount == 1  → widget built exactly once; no spurious rebuilds.
#   * rebuildCount > expected → investigate unnecessary ancestor rebuilds or
#     missing const constructors.
#   * avg build time  → compare across PRs to catch regressions; absolute
#     values vary per device/VM so track relative deltas.
#
# Note: FrameTimingCollector reports FrameTiming.buildDuration which covers
# only the Dart build phase (not raster). Values in AutomatedTestWidgetsFlutterBinding
# (plain `flutter test`) are synthetic; run with --profile for real data.

set -euo pipefail

DEVICE_ARGS=()
EXTRA_ARGS=()
PERF_TEST_DIR="test/perf"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_ARGS=(--device-id "$2")
      shift 2
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--device <device-id>] [-- <extra flutter test args>]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$PERF_TEST_DIR" ]]; then
  echo "Error: perf test directory '$PERF_TEST_DIR' not found." >&2
  echo "Run this script from the repository root." >&2
  exit 1
fi

echo "=== Flutty performance benchmarks (profile mode) ==="
echo "Test dir : $PERF_TEST_DIR"
if [[ ${#DEVICE_ARGS[@]} -gt 0 ]]; then
  echo "Device   : ${DEVICE_ARGS[*]}"
else
  echo "Device   : host VM (no device specified)"
fi
echo ""

# Ensure dependencies are up to date before running
flutter pub get --quiet

flutter test \
  --profile \
  "${DEVICE_ARGS[@]}" \
  "$PERF_TEST_DIR" \
  "${EXTRA_ARGS[@]}"

echo ""
echo "=== Benchmarks complete ==="
