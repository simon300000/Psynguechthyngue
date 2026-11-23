#!/bin/bash
# DEV/TEST ONLY: Files acceptance on the simulator against the official
# Syncthing (see e2e.py for topology and safety rules). Expects the phone
# instance running and `e2e.py setup` done. Usage: run-acceptance.sh <udid> [test-name...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="$1"; shift
export TEST_RUNNER_PSY_HARNESS_KEY="$(cat ~/SyncthingTest/wpc/phone-home/.harness-apikey)"
export TEST_RUNNER_PSY_HARNESS_REST="http://127.0.0.1:8484"
ARGS=()
for t in "$@"; do ARGS+=("-only-testing:FilesUITests/FilesAcceptanceUITests/$t"); done
xcodebuild -project "$HERE/PsyFilesHarness.xcodeproj" -scheme PsyFilesHarness -destination "id=$DEV" \
  -derivedDataPath "$HERE/build/dd" test "${ARGS[@]}" 2>&1 | tee "$HERE/build/acceptance.log" \
  | grep -E "Test Case .*(passed|failed)|error:|TEST (SUCC|FAIL)"
