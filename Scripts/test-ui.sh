#!/usr/bin/env bash
# Runs PsynguechthyngueUITests (FakeSyncEngine fixtures, en + zh-Hans) on a
# fresh, ephemeral iPhone and iPad simulator, then deletes them.
#
# Env: PSY_UI_IPHONE / PSY_UI_IPAD   device type names (defaults: newest available)
#      PSY_XCODE_CONFIGURATION        Debug (default) or Release
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
DERIVED_DATA="${PSY_UI_DERIVED_DATA_PATH:-${VERIFY_ROOT}/ui-tests/DerivedData}"
RESULTS="${VERIFY_ROOT}/ui-tests/Results-$(date +%Y%m%d-%H%M%S).xcresult"
CONFIGURATION="${PSY_XCODE_CONFIGURATION:-Debug}"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Newest iOS runtime that supports both an iPhone and an iPad Pro, with the
# newest such device types. Device types are taken from the runtime's own
# supportedDeviceTypes, since not every installed type works with every
# runtime (some CI images ship runtimes limited to a few models).
IFS=$'\t' read -r runtime iphone_type ipad_type < <(xcrun simctl list runtimes -j | python3 -I -c '
import json, os, sys
want_iphone = os.environ.get("PSY_UI_IPHONE", "")
want_ipad = os.environ.get("PSY_UI_IPAD", "")
def pick(types, prefix, wanted):
    names = [t["name"] for t in types]
    if wanted:
        return wanted if wanted in names else ""
    names = [n for n in names if n.startswith(prefix) and "Max" not in n and "mini" not in n]
    return sorted(names)[-1] if names else ""
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["platform"] == "iOS"]
for r in sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")], reverse=True):
    types = r.get("supportedDeviceTypes", [])
    phone, pad = pick(types, "iPhone 1", want_iphone), pick(types, "iPad Pro", want_ipad)
    if phone and pad:
        print(r["identifier"], phone, pad, sep="\t")
        break
') || true
[[ -n "${runtime:-}" ]] || fail "no iOS runtime supports both an iPhone and an iPad Pro"
[[ -n "${iphone_type}" && -n "${ipad_type}" ]] || fail "no iPhone/iPad device types available"

created=()
cleanup() {
    for udid in ${created[@]+"${created[@]}"}; do
        xcrun simctl shutdown "${udid}" >/dev/null 2>&1 || true
        xcrun simctl delete "${udid}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

run_id="$(uuidgen | cut -c1-8)"
iphone="$(xcrun simctl create "psy-ui-${run_id}-iphone" "${iphone_type}" "${runtime}")"; created+=("${iphone}")
ipad="$(xcrun simctl create "psy-ui-${run_id}-ipad" "${ipad_type}" "${runtime}")"; created+=("${ipad}")
printf 'UI tests on %s and %s (%s, %s)\n' "${iphone_type}" "${ipad_type}" "${runtime##*.}" "${CONFIGURATION}"

mkdir -p "$(dirname "${RESULTS}")"
xcodebuild -quiet \
    -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
    -scheme Psynguechthyngue \
    -configuration "${CONFIGURATION}" \
    -destination "platform=iOS Simulator,id=${iphone}" \
    -destination "platform=iOS Simulator,id=${ipad}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${RESULTS}" \
    -xcconfig "${ROOT_DIR}/Config/UITests.xcconfig" \
    -parallel-testing-enabled NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    test

summary="$(xcrun xcresulttool get test-results summary --path "${RESULTS}" 2>/dev/null || true)"
printf '%s\n' "${summary}" | python3 -I -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("UI tests: %d passed, %d failed, %d skipped (total %d)" % (s.get("passedTests", 0), s.get("failedTests", 0), s.get("skippedTests", 0), s.get("totalTestCount", 0)))
sys.exit(1 if s.get("failedTests", 0) else 0)'
