#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPHONE_NAME="t"
IPAD_NAME="Simon的iPad"
SCHEME="PsynguechthynguePhysicalE2E"
UNIT_TARGET="PsynguechthyngueTests"
UI_TARGET="PsynguechthyngueUITests"
UNIT_CLASS="PhysicalFileProviderE2ETests"
UI_CLASS="PhysicalFilesUIE2ETests"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for command in cp find grep plutil ruby xcodebuild xcrun; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command is unavailable: ${command}"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy is unavailable"

RUN_ROOT="$(mktemp -d /private/tmp/psy-physical-files-ui.XXXXXX)"
DERIVED_DATA="${RUN_ROOT}/DerivedData"
cleanup_needed=0

run_test() {
    local device_name="$1"
    local xctestrun="$2"
    local identifier="$3"
    local result_bundle="$4"
    local log_file="$5"
    xcodebuild \
        -xctestrun "${xctestrun}" \
        -destination "platform=iOS,name=${device_name}" \
        -resultBundlePath "${result_bundle}" \
        "-only-testing:${identifier}" \
        test-without-building >"${log_file}" 2>&1
}

assert_single_pass() {
    local result_bundle="$1"
    xcrun xcresulttool get test-results summary --path "${result_bundle}" \
        | ruby -rjson -e '
document = JSON.parse(STDIN.read)
abort "unexpected physical test result" unless
  document.fetch("result") == "Passed" &&
  document.fetch("totalTestCount") == 1 &&
  document.fetch("passedTests") == 1 &&
  document.fetch("failedTests") == 0 &&
  document.fetch("skippedTests") == 0 &&
  document.fetch("expectedFailures") == 0
' >/dev/null
}

run_pair() {
    local iphone_identifier="$1"
    local ipad_identifier="$2"
    local phase="$3"
    local iphone_result="${RUN_ROOT}/${phase}-iphone.xcresult"
    local ipad_result="${RUN_ROOT}/${phase}-ipad.xcresult"
    run_test \
        "${IPHONE_NAME}" "${IPHONE_XCTESTRUN}" "${iphone_identifier}" \
        "${iphone_result}" "${RUN_ROOT}/${phase}-iphone.log" &
    local iphone_pid=$!
    run_test \
        "${IPAD_NAME}" "${IPAD_XCTESTRUN}" "${ipad_identifier}" \
        "${ipad_result}" "${RUN_ROOT}/${phase}-ipad.log" &
    local ipad_pid=$!
    local status=0
    wait "${iphone_pid}" || status=1
    wait "${ipad_pid}" || status=1
    [[ "${status}" -eq 0 ]] || fail "${phase} failed; evidence: ${RUN_ROOT}"
    assert_single_pass "${iphone_result}"
    assert_single_pass "${ipad_result}"
}

cleanup_configuration() {
    [[ "${cleanup_needed}" -eq 1 ]] || return 0
    local identifier="${UNIT_TARGET}/${UNIT_CLASS}/testCleanupTemporaryPeerAndShare"
    run_test \
        "${IPHONE_NAME}" "${IPHONE_XCTESTRUN}" "${identifier}" \
        "${RUN_ROOT}/cleanup-trap-iphone.xcresult" "${RUN_ROOT}/cleanup-trap-iphone.log" &
    local iphone_pid=$!
    run_test \
        "${IPAD_NAME}" "${IPAD_XCTESTRUN}" "${identifier}" \
        "${RUN_ROOT}/cleanup-trap-ipad.xcresult" "${RUN_ROOT}/cleanup-trap-ipad.log" &
    local ipad_pid=$!
    wait "${iphone_pid}" || true
    wait "${ipad_pid}" || true
}
trap cleanup_configuration EXIT INT TERM

for device_name in "${IPHONE_NAME}" "${IPAD_NAME}"; do
    lock_state="$(
        xcrun devicectl device info lockState --device "${device_name}"
    )" || fail "${device_name} is not reachable through CoreDevice"
    grep -Fq 'unlockedSinceBoot: true' <<<"${lock_state}" \
        || fail "${device_name} has not been unlocked since reboot"
done

printf 'Building the source-matched signed physical Files UI gate...\n'
xcodebuild \
    -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination "platform=iOS,name=${IPAD_NAME}" \
    -derivedDataPath "${DERIVED_DATA}" \
    build-for-testing >"${RUN_ROOT}/build.log" 2>&1 \
    || fail "physical build-for-testing failed; evidence: ${RUN_ROOT}"

BASE_XCTESTRUN="$(
    find "${DERIVED_DATA}/Build/Products" -maxdepth 1 -name "${SCHEME}_*.xctestrun" -print
)"
[[ -n "${BASE_XCTESTRUN}" && "${BASE_XCTESTRUN}" != *$'\n'* ]] \
    || fail "expected one physical xctestrun"
IPHONE_XCTESTRUN="${DERIVED_DATA}/Build/Products/physical-iphone.xctestrun"
IPAD_XCTESTRUN="${DERIVED_DATA}/Build/Products/physical-ipad.xctestrun"
cp "${BASE_XCTESTRUN}" "${IPHONE_XCTESTRUN}"
cp "${BASE_XCTESTRUN}" "${IPAD_XCTESTRUN}"

discovery_identifier="${UNIT_TARGET}/${UNIT_CLASS}/testReportPhysicalPeerIdentityAndLANAddress"
run_pair "${discovery_identifier}" "${discovery_identifier}" "discovery"

extract_discovery() {
    local result_bundle="$1"
    xcrun xcresulttool get log --path "${result_bundle}" --type action --compact \
        | ruby -e '
text = STDIN.read
match = text.match(/PSY_PHYSICAL_E2E_DISCOVERY device=(?:iphone|ipad) deviceID=([A-Z0-9-]+) address=(tcp:\/\/[0-9.]+:22000) folders=([0-9]+)/)
abort "missing physical discovery marker" unless match
abort "physical gate requires an empty initial share set" unless match[3] == "0"
puts "#{match[1]}\t#{match[2]}"
'
}
IFS=$'\t' read -r iphone_device_id iphone_address < <(
    extract_discovery "${RUN_ROOT}/discovery-iphone.xcresult"
)
IFS=$'\t' read -r ipad_device_id ipad_address < <(
    extract_discovery "${RUN_ROOT}/discovery-ipad.xcresult"
)

inject_peer() {
    local plist="$1"
    local peer_id="$2"
    local peer_address="$3"
    /usr/libexec/PlistBuddy -c \
        "Add :${UNIT_TARGET}:EnvironmentVariables:PSY_PHYSICAL_E2E_PEER_ID string ${peer_id}" \
        "${plist}"
    /usr/libexec/PlistBuddy -c \
        "Add :${UNIT_TARGET}:EnvironmentVariables:PSY_PHYSICAL_E2E_PEER_ADDRESS string ${peer_address}" \
        "${plist}"
    plutil -lint "${plist}" >/dev/null
}
inject_peer "${IPHONE_XCTESTRUN}" "${ipad_device_id}" "${ipad_address}"
inject_peer "${IPAD_XCTESTRUN}" "${iphone_device_id}" "${iphone_address}"

cleanup_needed=1
setup_identifier="${UNIT_TARGET}/${UNIT_CLASS}/testConfigureTemporaryPeerAndShare"
run_pair "${setup_identifier}" "${setup_identifier}" "setup"

printf 'Running Files UI create/rename with peer synchronization...\n'
receive_identifier="${UNIT_TARGET}/${UNIT_CLASS}/testWaitForFilesUIRenamedDirectory"
ui_create_identifier="${UI_TARGET}/${UI_CLASS}/testCreateAndRenameDirectoryInFiles"
run_test \
    "${IPHONE_NAME}" "${IPHONE_XCTESTRUN}" "${receive_identifier}" \
    "${RUN_ROOT}/receive-iphone.xcresult" "${RUN_ROOT}/receive-iphone.log" &
receive_pid=$!
if ! run_test \
    "${IPAD_NAME}" "${IPAD_XCTESTRUN}" "${ui_create_identifier}" \
    "${RUN_ROOT}/ui-create-ipad.xcresult" "${RUN_ROOT}/ui-create-ipad.log"
then
    kill "${receive_pid}" >/dev/null 2>&1 || true
    wait "${receive_pid}" || true
    fail "Files UI create/rename failed; evidence: ${RUN_ROOT}"
fi
wait "${receive_pid}" || fail "peer did not receive Files UI rename; evidence: ${RUN_ROOT}"
assert_single_pass "${RUN_ROOT}/ui-create-ipad.xcresult"
assert_single_pass "${RUN_ROOT}/receive-iphone.xcresult"

printf 'Running reverse Files UI delete propagation...\n'
delete_wait_identifier="${UNIT_TARGET}/${UNIT_CLASS}/testWaitForFilesUIDeletionAndCleanup"
ui_delete_identifier="${UI_TARGET}/${UI_CLASS}/testDeleteRenamedDirectoryInFiles"
run_test \
    "${IPHONE_NAME}" "${IPHONE_XCTESTRUN}" "${delete_wait_identifier}" \
    "${RUN_ROOT}/delete-wait-iphone.xcresult" "${RUN_ROOT}/delete-wait-iphone.log" &
delete_wait_pid=$!
if ! run_test \
    "${IPAD_NAME}" "${IPAD_XCTESTRUN}" "${ui_delete_identifier}" \
    "${RUN_ROOT}/ui-delete-ipad.xcresult" "${RUN_ROOT}/ui-delete-ipad.log"
then
    kill "${delete_wait_pid}" >/dev/null 2>&1 || true
    wait "${delete_wait_pid}" || true
    fail "Files UI delete failed; evidence: ${RUN_ROOT}"
fi
wait "${delete_wait_pid}" || fail "Files UI delete did not propagate; evidence: ${RUN_ROOT}"
assert_single_pass "${RUN_ROOT}/ui-delete-ipad.xcresult"
assert_single_pass "${RUN_ROOT}/delete-wait-iphone.xcresult"

cleanup_identifier="${UNIT_TARGET}/${UNIT_CLASS}/testCleanupTemporaryPeerAndShare"
run_pair "${cleanup_identifier}" "${cleanup_identifier}" "cleanup"
cleanup_needed=0
trap - EXIT INT TERM
printf 'Physical Files UI create/rename/delete peer E2E passed. Evidence: %s\n' "${RUN_ROOT}"
