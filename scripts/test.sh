#!/bin/bash
# Runs the XCTest suite and prints a summary.
#
#   scripts/test.sh                              everything
#   scripts/test.sh ClipAppTests/TrimTests       one class (or Class/testMethod)
#
# The tests never launch ClipApp and need no permission: the media tests feed
# synthetic pictures and tones through the real encoder and writers.
set -uo pipefail
cd "$(dirname "$0")/.."

LOG=$(mktemp -t clipapp-tests)
trap 'rm -f "$LOG"' EXIT

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
ONLY=()
for target in "$@"; do ONLY+=("-only-testing:$target"); done

xcodebuild test -project ClipApp.xcodeproj -scheme ClipApp -configuration Debug -derivedDataPath build \
  ${ONLY[@]+"${ONLY[@]}"} >"$LOG" 2>&1
STATUS=$?

PASSED=$(grep -c "^Test Case .* passed" "$LOG")
FAILED=$(grep -c "^Test Case .* failed" "$LOG")

grep -E "^Test Suite '[A-Za-z]+Tests' (passed|failed)" "$LOG" | sed -E "s/^Test Suite '([A-Za-z]+)' (passed|failed).*/\2  \1/" | sort -k2
echo
if [[ $FAILED -gt 0 ]]; then
  echo "Failed tests:"
  grep -E "^Test Case .* failed" "$LOG" | sed -E "s/^Test Case '-\[ClipAppTests\.([^]]+)\]' failed.*/  \1/"
  echo
  grep -E ": error: -\[" "$LOG" | sed -E 's/^.*ClipAppTests\//  /'
  echo
fi
if [[ $((PASSED + FAILED)) -eq 0 ]]; then
  # Nothing ran: the build broke before the tests.
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "No tests ran (xcodebuild exit code $STATUS)."
  exit 1
fi
echo "$PASSED passed, $FAILED failed ($((PASSED + FAILED)) tests)"
[[ $STATUS -eq 0 && $FAILED -eq 0 ]]
