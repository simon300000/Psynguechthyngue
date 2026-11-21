#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
CONFIGURATION="${PSY_XCODE_CONFIGURATION:-Debug}"
DERIVED_DATA_PARENT="${PSY_UI_DERIVED_DATA_PATH:-${VERIFY_ROOT}/ui-tests/DerivedData}"
DERIVED_DATA_ROOT=""
RESULT_BUNDLE_PARENT="${PSY_UI_RESULT_BUNDLE_PATH:-${VERIFY_ROOT}/ui-tests/TestResults}"
RESULT_BUNDLE_ROOT=""
UUIDGEN_BINARY="/usr/bin/uuidgen"
ID_BINARY="/usr/bin/id"
PS_BINARY="/bin/ps"
SIMULATOR_DELETE_RETRY_LIMIT=4
SIMULATOR_DELETE_RETRY_DELAY_SECONDS=1
UI_APP_BUNDLE_IDENTIFIER="com.example.Psynguechthyngue.UITesting"
UI_PROVIDER_BUNDLE_IDENTIFIER="com.example.Psynguechthyngue.UITesting.FileProvider"
UNIT_TEST_TARGET="PsynguechthyngueTests"
# The standard App-hosted iOS action discovers 599 XCTest cases.
# Repository-source and other platform-specific checks also run in SwiftPM;
# manually selected physical E2E cases are excluded from this action.
# Keep this frozen so a silently omitted test file fails the release gate.
EXPECTED_IOS_UNIT_TEST_COUNT="599"
UI_TEST_TARGET="PsynguechthyngueUITests"
UI_CLEAN_INSTALL_TEST="${UI_TEST_TARGET}/PsynguechthyngueUITests/testCleanInstallPublishesIdentityAndSyncNowReportsZeroFolderNoOp"
UI_ENGLISH_TEST="${UI_TEST_TARGET}/PsynguechthyngueUITests/testEnglishOverviewExposesStatusAndPrimaryActions"
UI_CHINESE_TEST="${UI_TEST_TARGET}/PsynguechthyngueUITests/testSimplifiedChineseOverviewUsesLocalizedAccessibleLabels"

for command in xcodebuild xcrun ruby; do
    command -v "${command}" >/dev/null 2>&1 || {
        printf 'error: %s is required for simulator UI tests\n' "${command}" >&2
        exit 1
    }
done
[[ -x "${UUIDGEN_BINARY}" ]] || {
    printf 'error: system uuidgen is required for collision-safe ephemeral simulator names\n' >&2
    exit 1
}
[[ -x "${ID_BINARY}" && -x "${PS_BINARY}" ]] || {
    printf 'error: system id and ps are required for CoreSimulator ownership preflight\n' >&2
    exit 1
}

assert_coresimulator_user_service_ownership() {
    local current_uid
    local process_list
    local unexpected_services

    current_uid="$("${ID_BINARY}" -u)"
    [[ "${current_uid}" =~ ^[0-9]+$ ]] || {
        printf 'error: could not determine the numeric UI-gate user ID\n' >&2
        return 1
    }
    process_list="$("${PS_BINARY}" -axo uid=,command=)" || {
        printf 'error: could not inspect CoreSimulator service ownership\n' >&2
        return 1
    }
    unexpected_services="$(
        printf '%s\n' "${process_list}" | awk -v expected_uid="${current_uid}" '
            $1 != expected_uid &&
            ($0 ~ /com\.apple\.CoreSimulator\.CoreSimulatorService(\.xpc)?\/Contents\/MacOS\/com\.apple\.CoreSimulator\.CoreSimulatorService$/ ||
             $0 ~ /SimulatorTrampoline(\.xpc)?\/Contents\/MacOS\/SimulatorTrampoline$/) {
                print
            }
        '
    )"
    if [[ -n "${unexpected_services}" ]]; then
        printf 'error: refusing to create ephemeral simulators while CoreSimulator user services run under another UID\n' >&2
        printf '%s\n' "${unexpected_services}" >&2
        printf 'Restart the Mac or terminate only those unexpected services with administrator authority, then rerun.\n' >&2
        return 1
    fi
}

assert_coresimulator_user_service_ownership

mkdir -p \
    "${VERIFY_ROOT}/ui-tests/clang-module-cache" \
    "${VERIFY_ROOT}/ui-tests/swiftpm-module-cache" \
    "${VERIFY_ROOT}/ui-tests/xdg-cache" \
    "${VERIFY_ROOT}/ui-tests/SourcePackages" \
    "${VERIFY_ROOT}/ui-tests/package-cache" \
    "${DERIVED_DATA_PARENT}" \
    "${RESULT_BUNDLE_PARENT}"

DERIVED_DATA_ROOT="$(mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX")"
RESULT_BUNDLE_ROOT="$(mktemp -d "${RESULT_BUNDLE_PARENT%/}/run.XXXXXX")"
printf 'Using fresh iOS test DerivedData: %s\n' "${DERIVED_DATA_ROOT}"
printf 'Writing fresh iOS test result bundles: %s\n' "${RESULT_BUNDLE_ROOT}"

export CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/ui-tests/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${VERIFY_ROOT}/ui-tests/swiftpm-module-cache"
export XDG_CACHE_HOME="${VERIFY_ROOT}/ui-tests/xdg-cache"

select_runtime() {
    xcrun simctl list runtimes available -j | ruby -rjson -e '
document = JSON.parse(STDIN.read)
candidates = document.fetch("runtimes", []).select do |runtime|
  runtime["isAvailable"] != false && runtime.fetch("identifier", "").include?("SimRuntime.iOS-")
end
selected = candidates.max_by do |runtime|
  runtime.fetch("version", runtime.fetch("name", "")).scan(/\d+/).map(&:to_i)
end
abort("no available iOS simulator runtime was found") unless selected
puts [selected.fetch("identifier"), selected.fetch("name")].join("\t")
'
}

select_device_type() {
    local family="$1"
    xcrun simctl list devicetypes -j | ruby -rjson -e '
family = ARGV.fetch(0)
prefix = family == "iphone" ? "iPhone" : "iPad"
document = JSON.parse(STDIN.read)
candidates = document.fetch("devicetypes", []).select do |device_type|
  device_type.fetch("name", "").start_with?(prefix)
end
selected = candidates.first
abort("no #{family} simulator device type was found") unless selected
puts [selected.fetch("identifier"), selected.fetch("name")].join("\t")
' "${family}"
}

CREATED_DEVICE_IDS=()
simulator_device_presence() {
    local exact_device_id="$1"

    xcrun simctl list devices -j | ruby -rjson -e '
device_id = ARGV.fetch(0)
devices = JSON.parse(STDIN.read).fetch("devices", {}).values.flatten
puts(devices.any? { |device| device["udid"] == device_id } ? "present" : "absent")
' "${exact_device_id}"
}

delete_exact_ephemeral_simulator() {
    local device_id="$1"
    local attempt
    local delete_output=""
    local presence="unknown"

    # CoreSimulator deletion is asynchronous and can report a transient error
    # after removing its registry entry. Retry only the UUID recorded at
    # creation, and stop as soon as that exact UUID is provably absent. Never
    # use `delete unavailable`, erase, a name match, or another broad cleanup.
    for ((attempt = 1; attempt <= SIMULATOR_DELETE_RETRY_LIMIT; attempt++)); do
        if delete_output="$(xcrun simctl delete "${device_id}" 2>&1)"; then
            return 0
        fi
        presence="$(simulator_device_presence "${device_id}" 2>/dev/null)" || presence="unknown"
        if [[ "${presence}" == "absent" ]]; then
            return 0
        fi
        if ((attempt < SIMULATOR_DELETE_RETRY_LIMIT)); then
            sleep "${SIMULATOR_DELETE_RETRY_DELAY_SECONDS}"
        fi
    done

    printf 'error: failed to delete exact ephemeral simulator %s after %s attempts (last presence: %s)\n' \
        "${device_id}" "${SIMULATOR_DELETE_RETRY_LIMIT}" "${presence}" >&2
    if [[ -n "${delete_output}" ]]; then
        printf '%s\n' "${delete_output}" >&2
    fi
    return 1
}

cleanup_created_simulators() {
    local status=$?
    local cleanup_failed=0
    local index
    local device_id

    trap - EXIT INT TERM
    for ((index = ${#CREATED_DEVICE_IDS[@]} - 1; index >= 0; index--)); do
        device_id="${CREATED_DEVICE_IDS[index]}"
        xcrun simctl shutdown "${device_id}" >/dev/null 2>&1 || true
        if ! delete_exact_ephemeral_simulator "${device_id}"; then
            cleanup_failed=1
        fi
    done

    if [[ "${status}" -ne 0 ]]; then
        exit "${status}"
    fi
    if [[ "${cleanup_failed}" -ne 0 ]]; then
        exit 1
    fi
    exit 0
}
trap cleanup_created_simulators EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CREATED_DEVICE_ID=""
register_created_device_id() {
    local candidate="$1"
    local existing

    for existing in "${CREATED_DEVICE_IDS[@]}"; do
        [[ "${existing}" != "${candidate}" ]] || return 0
    done
    CREATED_DEVICE_IDS+=("${candidate}")
}

simulator_device_id_named() {
    local exact_name="$1"

    xcrun simctl list devices -j | ruby -rjson -e '
name = ARGV.fetch(0)
devices = JSON.parse(STDIN.read).fetch("devices", {}).values.flatten
matches = devices.select { |device| device["name"] == name }
abort("multiple simulator devices matched #{name}") if matches.length > 1
puts matches.first.fetch("udid") if matches.length == 1
' "${exact_name}"
}

create_ephemeral_simulator() {
    local family="$1"
    local device_type_identifier="$2"
    local runtime_identifier="$3"
    local unique_name
    local create_output
    local create_status=0
    local preexisting_device_id=""
    local recovered_device_id=""
    local unique_suffix

    unique_suffix="$("${UUIDGEN_BINARY}")"
    [[ "${unique_suffix}" =~ ^[[:xdigit:]-]{36}$ ]] || {
        printf 'error: uuidgen returned an invalid simulator-name suffix: %s\n' "${unique_suffix}" >&2
        return 1
    }
    unique_name="Psynguechthyngue-ReleaseGate-${family}-${unique_suffix}"
    if ! preexisting_device_id="$(simulator_device_id_named "${unique_name}")"; then
        printf 'error: could not prove simulator name %s is unused before creation\n' \
            "${unique_name}" >&2
        return 1
    fi
    if [[ -n "${preexisting_device_id}" ]]; then
        printf 'error: refusing to create an ephemeral simulator with pre-existing name %s\n' \
            "${unique_name}" >&2
        return 1
    fi
    create_output="$(
        xcrun simctl create "${unique_name}" "${device_type_identifier}" "${runtime_identifier}"
    )" || create_status=$?
    if [[ "${create_status}" -eq 0 && "${create_output}" =~ ^[[:xdigit:]-]{36}$ ]]; then
        CREATED_DEVICE_ID="${create_output}"
        register_created_device_id "${CREATED_DEVICE_ID}"
        return
    fi

    # simctl can create the device before emitting malformed stdout or failing.
    # Recover only the preflight-clean system-UUID name so the EXIT trap can
    # still delete that device; never fall back to a broad delete/erase.
    recovered_device_id="$(simulator_device_id_named "${unique_name}")" || recovered_device_id=""
    if [[ "${recovered_device_id}" =~ ^[[:xdigit:]-]{36}$ ]]; then
        register_created_device_id "${recovered_device_id}"
    fi
    printf 'error: simctl create failed or returned an invalid %s simulator UDID (status %s): %s\n' \
        "${family}" "${create_status}" "${create_output}" >&2
    if [[ -n "${recovered_device_id}" ]]; then
        printf 'Recovered exact created simulator %s for cleanup.\n' "${recovered_device_id}" >&2
    fi
    CREATED_DEVICE_ID=""
    return 1
}

run_test_xcodebuild() {
    local action="$1"
    local destination="$2"
    shift 2

    xcodebuild \
        -quiet \
        -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
        -scheme Psynguechthyngue \
        -configuration "${CONFIGURATION}" \
        -destination "platform=iOS Simulator,id=${destination}" \
        -derivedDataPath "${DERIVED_DATA_ROOT}" \
        -clonedSourcePackagesDirPath "${VERIFY_ROOT}/ui-tests/SourcePackages" \
        -packageCachePath "${VERIFY_ROOT}/ui-tests/package-cache" \
        -xcconfig "${ROOT_DIR}/Config/UITests.xcconfig" \
        -skipPackageUpdates \
        -parallel-testing-enabled NO \
        "$@" \
        COMPILER_INDEX_STORE_ENABLE=NO \
        ENABLE_USER_SCRIPT_SANDBOXING=NO \
        CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/ui-tests/clang-module-cache" \
        SWIFT_MODULE_CACHE_PATH="${VERIFY_ROOT}/ui-tests/swiftpm-module-cache" \
        MODULE_CACHE_DIR="${VERIFY_ROOT}/ui-tests/clang-module-cache" \
        "${action}"
}

assert_xcresult_summary() {
    local label="$1"
    local result_bundle="$2"
    local expected_test_count="$3"
    local summary_json

    [[ -d "${result_bundle}" ]] || {
        printf 'error: %s did not create result bundle %s\n' "${label}" "${result_bundle}" >&2
        exit 1
    }
    summary_json="$(
        xcrun xcresulttool get test-results summary \
            --path "${result_bundle}" \
            --compact
    )"
    printf '%s\n' "${summary_json}" | ruby -rjson -e '
label = ARGV.fetch(0)
expected = Integer(ARGV.fetch(1), 10)
document = JSON.parse(STDIN.read)
integer_keys = %w[totalTestCount passedTests failedTests skippedTests expectedFailures]
counts = integer_keys.to_h do |key|
  value = document.fetch(key)
  abort("error: #{label} xcresult #{key} is not an integer") unless value.is_a?(Integer)
  [key, value]
end
total = counts.fetch("totalTestCount")
abort("error: #{label} xcresult result was not Passed") unless document.fetch("result") == "Passed"
abort("error: #{label} xcresult executed no tests") unless total.positive?
abort("error: #{label} xcresult passed #{counts.fetch("passedTests")} of #{total}") unless counts.fetch("passedTests") == total
%w[failedTests skippedTests expectedFailures].each do |key|
  abort("error: #{label} xcresult #{key}=#{counts.fetch(key)}, expected 0") unless counts.fetch(key).zero?
end
if expected <= 0
  abort("error: #{label} expected count is not frozen; observed #{total}. Set EXPECTED_IOS_UNIT_TEST_COUNT to #{total} and rerun the full gate")
end
abort("error: #{label} xcresult total #{total}, expected exactly #{expected}") unless total == expected
puts "#{label} xcresult passed exactly #{total} tests: #{ARGV.fetch(2)}"
' "${label}" "${expected_test_count}" "${result_bundle}"
}

run_test_action() {
    local label="$1"
    local destination="$2"
    local expected_test_count="$3"
    local result_bundle="${RESULT_BUNDLE_ROOT}/${label}.xcresult"
    shift 3

    [[ ! -e "${result_bundle}" ]] || {
        printf 'error: refusing to overwrite result bundle %s\n' "${result_bundle}" >&2
        exit 1
    }
    run_test_xcodebuild \
        test-without-building "${destination}" \
        -resultBundlePath "${result_bundle}" \
        "$@"
    assert_xcresult_summary "${label}" "${result_bundle}" "${expected_test_count}"
}

prepare_clean_ui_install() {
    local device_id="$1"
    local family="$2"

    # get_app_container is only authoritative once CoreSimulator has completed
    # booting the selected device. `simctl boot` is allowed to report that an
    # already-booted device cannot be booted again; bootstatus is the hard gate.
    xcrun simctl boot "${device_id}" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "${device_id}" -b

    xcrun simctl terminate "${device_id}" "${UI_APP_BUNDLE_IDENTIFIER}" >/dev/null 2>&1 || true
    xcrun simctl uninstall "${device_id}" "${UI_APP_BUNDLE_IDENTIFIER}" >/dev/null 2>&1 || true

    for bundle_identifier in "${UI_APP_BUNDLE_IDENTIFIER}" "${UI_PROVIDER_BUNDLE_IDENTIFIER}"; do
        if xcrun simctl get_app_container \
            "${device_id}" "${bundle_identifier}" app >/dev/null 2>&1; then
            printf 'error: %s simulator %s retained installed bundle %s after uninstall\n' \
                "${family}" "${device_id}" "${bundle_identifier}" >&2
            exit 1
        fi
    done

    printf 'Verified fixed bundles absent on fresh ephemeral %s simulator %s.\n' \
        "${family}" "${device_id}"
}

runtime_selection="$(select_runtime)"
runtime_identifier="${runtime_selection%%$'\t'*}"
runtime_name="${runtime_selection#*$'\t'}"
iphone_type_selection="$(select_device_type iphone)"
iphone_type_identifier="${iphone_type_selection%%$'\t'*}"
iphone_type_name="${iphone_type_selection#*$'\t'}"
ipad_type_selection="$(select_device_type ipad)"
ipad_type_identifier="${ipad_type_selection%%$'\t'*}"
ipad_type_name="${ipad_type_selection#*$'\t'}"

create_ephemeral_simulator iphone "${iphone_type_identifier}" "${runtime_identifier}"
iphone_device_id="${CREATED_DEVICE_ID}"
create_ephemeral_simulator ipad "${ipad_type_identifier}" "${runtime_identifier}"
ipad_device_id="${CREATED_DEVICE_ID}"
families=(iphone ipad)
device_ids=("${iphone_device_id}" "${ipad_device_id}")

printf 'Created fresh ephemeral simulator matrix on %s: %s (%s), %s (%s).\n' \
    "${runtime_name}" "${iphone_type_name}" "${iphone_device_id}" \
    "${ipad_type_name}" "${ipad_device_id}"

printf 'Building iOS unit and UI-test products once; shared scheme will freshly bootstrap Mobilebridge.\n'
run_test_xcodebuild build-for-testing "${iphone_device_id}"

for ((index = 0; index < ${#device_ids[@]}; index++)); do
    prepare_clean_ui_install "${device_ids[index]}" "${families[index]}"
    printf 'Running clean-install UI contract first on %s simulator %s\n' \
        "${families[index]}" "${device_ids[index]}"
    run_test_action \
        "${families[index]}-clean" "${device_ids[index]}" 1 \
        "-only-testing:${UI_CLEAN_INSTALL_TEST}"

    printf 'Running localized UI tests on %s simulator %s\n' "${families[index]}" "${device_ids[index]}"
    run_test_action \
        "${families[index]}-localized" "${device_ids[index]}" 2 \
        "-only-testing:${UI_ENGLISH_TEST}" \
        "-only-testing:${UI_CHINESE_TEST}"
done

printf 'Running the iOS unit-test target once after the clean-first UI matrix on iPhone simulator %s\n' \
    "${iphone_device_id}"
run_test_action \
    ios-unit "${iphone_device_id}" "${EXPECTED_IOS_UNIT_TEST_COUNT}" \
    "-only-testing:${UNIT_TEST_TARGET}"

printf 'iOS unit target and clean-state localized iPhone/iPad UI-test matrix passed.\n'
