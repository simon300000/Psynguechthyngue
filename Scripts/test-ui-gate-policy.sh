#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/psy-ui-gate-policy.XXXXXX")"

cleanup() {
    rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

mkdir -p "${FIXTURE_ROOT}/Scripts" "${FIXTURE_ROOT}/bin"
cp -- "${ROOT_DIR}/Scripts/test-ui.sh" "${FIXTURE_ROOT}/Scripts/test-ui.sh"
FIXTURE_UUID="33333333-3333-3333-3333-333333333333"
FIXTURE_UUIDGEN="${FIXTURE_ROOT}/bin/uuidgen"
FIXTURE_ID="${FIXTURE_ROOT}/bin/id"
FIXTURE_PS="${FIXTURE_ROOT}/bin/ps"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf '\''%s\n'\'' '\''33333333-3333-3333-3333-333333333333'\''' >"${FIXTURE_UUIDGEN}"
chmod +x "${FIXTURE_UUIDGEN}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "${1:-}" == -u && $# -eq 1 ]] || exit 64' \
    'printf '\''%s\n'\'' 501' >"${FIXTURE_ID}"
chmod +x "${FIXTURE_ID}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "${1:-}" == -axo && "${2:-}" == "uid=,command=" && $# -eq 2 ]] || exit 64' \
    'printf '\''%s\n'\'' "501 /fixture/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService"' \
    'if [[ "${PSY_UI_POLICY_PS_MODE:-user-only}" == root-duplicate ]]; then' \
    '  printf '\''%s\n'\'' "0 /fixture/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline"' \
    'fi' >"${FIXTURE_PS}"
chmod +x "${FIXTURE_PS}"

# Replace the production count only in this copied fixture so the fake result
# proves the script compares against its configured exact value rather than a
# second hard-coded number in the parser.
FIXTURE_UNIT_TEST_COUNT="47"
ruby -e '
path, count, fixture_uuidgen, fixture_id, fixture_ps = ARGV
text = File.read(path)
pattern = /^EXPECTED_IOS_UNIT_TEST_COUNT="[0-9]+"$/
abort("expected exactly one iOS unit-count constant") unless text.scan(pattern).length == 1
text = text.sub(pattern, %(EXPECTED_IOS_UNIT_TEST_COUNT="#{count}"))
uuidgen_pattern = /^UUIDGEN_BINARY="\/usr\/bin\/uuidgen"$/
abort("expected exactly one system uuidgen constant") unless text.scan(uuidgen_pattern).length == 1
text = text.sub(uuidgen_pattern, %(UUIDGEN_BINARY="#{fixture_uuidgen}"))
id_pattern = /^ID_BINARY="\/usr\/bin\/id"$/
abort("expected exactly one system id constant") unless text.scan(id_pattern).length == 1
text = text.sub(id_pattern, %(ID_BINARY="#{fixture_id}"))
ps_pattern = /^PS_BINARY="\/bin\/ps"$/
abort("expected exactly one system ps constant") unless text.scan(ps_pattern).length == 1
text = text.sub(ps_pattern, %(PS_BINARY="#{fixture_ps}"))
delay_pattern = /^SIMULATOR_DELETE_RETRY_DELAY_SECONDS=1$/
abort("expected exactly one simulator delete retry delay") unless text.scan(delay_pattern).length == 1
text = text.sub(delay_pattern, "SIMULATOR_DELETE_RETRY_DELAY_SECONDS=0")
File.write(path, text)
' "${FIXTURE_ROOT}/Scripts/test-ui.sh" "${FIXTURE_UNIT_TEST_COUNT}" "${FIXTURE_UUIDGEN}" "${FIXTURE_ID}" "${FIXTURE_PS}"

POLICY_LOG="${FIXTURE_ROOT}/policy.log"
RUN_LOG="${FIXTURE_ROOT}/run.log"
EXPECTED_LOG="${FIXTURE_ROOT}/expected.log"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'log="${PSY_UI_POLICY_LOG:?}"' \
    'state_root="${PSY_UI_POLICY_STATE_ROOT:?}"' \
    'mkdir -p "${state_root}"' \
    'case "${1:-}" in' \
    '  simctl)' \
    '    case "${2:-}" in' \
    '      list)' \
    '        case "${3:-}" in' \
    '          runtimes)' \
    '            printf '\''%s\n'\'' '\''{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","name":"iOS 26.5","version":"26.5","isAvailable":true}]}'\''' \
    '            ;;' \
    '          devicetypes)' \
    '            printf '\''%s\n'\'' '\''{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","name":"iPhone 17 Pro"},{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5","name":"iPad Pro 13-inch (M5)"}]}'\''' \
    '            ;;' \
    '          devices)' \
    '            printf '\''{"devices":{"fixture":['\''' \
    '            separator=' \
    '            if [[ -f "${state_root}/devices.tsv" ]]; then' \
    '              while IFS=$'\''\t'\'' read -r device_id device_name; do' \
    '                printf '\''%s{"udid":"%s","name":"%s"}'\'' "${separator}" "${device_id}" "${device_name}"' \
    '                separator=,' \
    '              done <"${state_root}/devices.tsv"' \
    '            fi' \
    '            printf '\'']} }\n'\''' \
    '            ;;' \
    '          *) exit 64 ;;' \
    '        esac' \
    '        ;;' \
    '      create)' \
    '        case "${3:-}" in' \
    '          *-iphone-*) device_id=11111111-1111-1111-1111-111111111111; family=iphone ;;' \
    '          *-ipad-*) device_id=22222222-2222-2222-2222-222222222222; family=ipad ;;' \
    '          *) exit 65 ;;' \
    '        esac' \
    '        printf '\''create:%s:%s\n'\'' "${family}" "${device_id}" >>"${log}"' \
    '        printf '\''%s\t%s\n'\'' "${device_id}" "${3:-}" >>"${state_root}/devices.tsv"' \
    '        if [[ "${PSY_UI_POLICY_CREATE_MODE:-valid}" == malformed-iphone && "${family}" == iphone ]]; then' \
    '          printf '\''not-a-udid\n'\''' \
    '        else' \
    '          printf '\''%s\n'\'' "${device_id}"' \
    '        fi' \
    '        ;;' \
    '      boot|bootstatus|terminate|shutdown)' \
    '        exit 0' \
    '        ;;' \
    '      uninstall)' \
    '        printf '\''uninstall:%s:%s\n'\'' "${3:-}" "${4:-}" >>"${log}"' \
    '        ;;' \
    '      get_app_container)' \
    '        printf '\''absence-probe:%s:%s:%s\n'\'' "${3:-}" "${4:-}" "${5:-}" >>"${log}"' \
    '        exit 1' \
    '        ;;' \
    '      delete)' \
    '        printf '\''delete:%s\n'\'' "${3:-}" >>"${log}"' \
    '        delete_count_file="${state_root}/delete-${3:-}.count"' \
    '        delete_count=0' \
    '        [[ ! -f "${delete_count_file}" ]] || delete_count="$(cat "${delete_count_file}")"' \
    '        ((delete_count += 1))' \
    '        printf '\''%s\n'\'' "${delete_count}" >"${delete_count_file}"' \
    '        case "${PSY_UI_POLICY_DELETE_MODE:-pass}" in' \
    '          pass) ;;' \
    '          flaky) [[ "${delete_count}" -gt 1 ]] || exit 69 ;;' \
    '          fail) exit 69 ;;' \
    '          *) exit 70 ;;' \
    '        esac' \
    '        if [[ -f "${state_root}/devices.tsv" ]]; then' \
    '          awk -F '\''\t'\'' -v id="${3:-}" '\''$1 != id'\'' "${state_root}/devices.tsv" >"${state_root}/devices.next"' \
    '          mv "${state_root}/devices.next" "${state_root}/devices.tsv"' \
    '        fi' \
    '        ;;' \
    '      *) exit 64 ;;' \
    '    esac' \
    '    ;;' \
    '  xcresulttool)' \
    '    [[ "${2:-}" == get && "${3:-}" == test-results && "${4:-}" == summary ]] || exit 64' \
    '    result_bundle=' \
    '    compact=0' \
    '    index=5' \
    '    while ((index <= $#)); do' \
    '      argument="${!index}"' \
    '      case "${argument}" in' \
    '        --path)' \
    '          ((index += 1))' \
    '          result_bundle="${!index:-}"' \
    '          ;;' \
    '        --compact) compact=1 ;;' \
    '        *) exit 64 ;;' \
    '      esac' \
    '      ((index += 1))' \
    '    done' \
    '    [[ "${compact}" -eq 1 && -d "${result_bundle}" ]] || exit 65' \
    '    result_name="$(basename "${result_bundle}")"' \
    '    case "${result_name}" in' \
    '      iphone-clean.xcresult|ipad-clean.xcresult) total=1 ;;' \
    '      iphone-localized.xcresult|ipad-localized.xcresult) total=2 ;;' \
    '      ios-unit.xcresult) total="${PSY_UI_POLICY_UNIT_COUNT:?}" ;;' \
    '      *) exit 66 ;;' \
    '    esac' \
    '    result=Passed' \
    '    passed="${total}"' \
    '    failed=0' \
    '    skipped=0' \
    '    expected_failures=0' \
    '    if [[ "${result_name}" == iphone-clean.xcresult ]]; then' \
    '      case "${PSY_UI_POLICY_RESULT_MODE:-pass}" in' \
    '        pass) ;;' \
    '        zero) total=0; passed=0 ;;' \
    '        partial) passed=0 ;;' \
    '        failed) failed=1 ;;' \
    '        skipped) skipped=1 ;;' \
    '        expected) expected_failures=1 ;;' \
    '        wrong-total) total=2; passed=2 ;;' \
    '        failed-result) result=Failed ;;' \
    '        *) exit 67 ;;' \
    '      esac' \
    '    fi' \
    '    printf '\''xcresult:%s:%s\n'\'' "${result_name}" "${total}" >>"${log}"' \
    '    printf '\''{"result":"%s","totalTestCount":%s,"passedTests":%s,"failedTests":%s,"skippedTests":%s,"expectedFailures":%s}\n'\'' "${result}" "${total}" "${passed}" "${failed}" "${skipped}" "${expected_failures}"' \
    '    ;;' \
    '  *) exit 64 ;;' \
    'esac' >"${FIXTURE_ROOT}/bin/xcrun"
chmod +x "${FIXTURE_ROOT}/bin/xcrun"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'log="${PSY_UI_POLICY_LOG:?}"' \
    'device_id=' \
    'action=' \
    'result_bundle=' \
    'clean_selector=0' \
    'english_selector=0' \
    'chinese_selector=0' \
    'unit_selector=0' \
    'selector_count=0' \
    'arguments=("$@")' \
    'for ((index = 0; index < ${#arguments[@]}; index++)); do' \
    '  argument="${arguments[index]}"' \
    '  case "${argument}" in' \
    '    platform=iOS\ Simulator,id=*) device_id="${argument##*=}" ;;' \
    '    build-for-testing) action=build ;;' \
    '    test-without-building) action=test ;;' \
    '    -resultBundlePath)' \
    '      ((index += 1))' \
    '      result_bundle="${arguments[index]:-}"' \
    '      ;;' \
    '    -only-testing:PsynguechthyngueTests)' \
    '      unit_selector=1' \
    '      ((selector_count += 1))' \
    '      ;;' \
    '    *testCleanInstallPublishesIdentityAndSyncNowReportsZeroFolderNoOp)' \
    '      clean_selector=1' \
    '      ((selector_count += 1))' \
    '      ;;' \
    '    *testEnglishOverviewExposesStatusAndPrimaryActions)' \
    '      english_selector=1' \
    '      ((selector_count += 1))' \
    '      ;;' \
    '    *testSimplifiedChineseOverviewUsesLocalizedAccessibleLabels)' \
    '      chinese_selector=1' \
    '      ((selector_count += 1))' \
    '      ;;' \
    '    -only-testing:*) exit 65 ;;' \
    '  esac' \
    'done' \
    '[[ -n "${device_id}" && -n "${action}" ]] || exit 64' \
    'if [[ "${action}" == build ]]; then' \
    '  [[ -z "${result_bundle}" && "${selector_count}" -eq 0 ]] || exit 66' \
    '  printf '\''xcodebuild:build:%s\n'\'' "${device_id}" >>"${log}"' \
    '  exit 0' \
    'fi' \
    '[[ -n "${result_bundle}" && ! -e "${result_bundle}" ]] || exit 67' \
    'case "${clean_selector}:${english_selector}:${chinese_selector}:${unit_selector}:${selector_count}" in' \
    '  1:0:0:0:1) kind=clean-ui ;;' \
    '  0:1:1:0:2) kind=localized-ui ;;' \
    '  0:0:0:1:1) kind=unit ;;' \
    '  *) exit 68 ;;' \
    'esac' \
    'mkdir -p "${result_bundle}"' \
    'printf '\''xcodebuild:%s:%s:%s\n'\'' "${kind}" "${device_id}" "$(basename "${result_bundle}")" >>"${log}"' \
    'exit 0' >"${FIXTURE_ROOT}/bin/xcodebuild"
chmod +x "${FIXTURE_ROOT}/bin/xcodebuild"

if ! PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${POLICY_LOG}" \
    PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-happy" \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >"${RUN_LOG}" 2>&1; then
    cat "${RUN_LOG}" >&2
    fail "UI gate policy fixture failed"
fi

IPHONE_ID="11111111-1111-1111-1111-111111111111"
IPAD_ID="22222222-2222-2222-2222-222222222222"
APP_ID="com.example.Psynguechthyngue.UITesting"
PROVIDER_ID="com.example.Psynguechthyngue.UITesting.FileProvider"
printf '%s\n' \
    "create:iphone:${IPHONE_ID}" \
    "create:ipad:${IPAD_ID}" \
    "xcodebuild:build:${IPHONE_ID}" \
    "uninstall:${IPHONE_ID}:${APP_ID}" \
    "absence-probe:${IPHONE_ID}:${APP_ID}:app" \
    "absence-probe:${IPHONE_ID}:${PROVIDER_ID}:app" \
    "xcodebuild:clean-ui:${IPHONE_ID}:iphone-clean.xcresult" \
    "xcresult:iphone-clean.xcresult:1" \
    "xcodebuild:localized-ui:${IPHONE_ID}:iphone-localized.xcresult" \
    "xcresult:iphone-localized.xcresult:2" \
    "uninstall:${IPAD_ID}:${APP_ID}" \
    "absence-probe:${IPAD_ID}:${APP_ID}:app" \
    "absence-probe:${IPAD_ID}:${PROVIDER_ID}:app" \
    "xcodebuild:clean-ui:${IPAD_ID}:ipad-clean.xcresult" \
    "xcresult:ipad-clean.xcresult:1" \
    "xcodebuild:localized-ui:${IPAD_ID}:ipad-localized.xcresult" \
    "xcresult:ipad-localized.xcresult:2" \
    "xcodebuild:unit:${IPHONE_ID}:ios-unit.xcresult" \
    "xcresult:ios-unit.xcresult:${FIXTURE_UNIT_TEST_COUNT}" \
    "delete:${IPAD_ID}" \
    "delete:${IPHONE_ID}" >"${EXPECTED_LOG}"

diff -u "${EXPECTED_LOG}" "${POLICY_LOG}" || fail "UI gate action order or cleanup policy drifted"

root_service_log="${FIXTURE_ROOT}/root-service.log"
: >"${root_service_log}"
if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${root_service_log}" \
    PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-root-service" \
    PSY_UI_POLICY_PS_MODE=root-duplicate \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/root-service/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
    fail "unexpected root CoreSimulator service passed the UI gate preflight"
fi
[[ ! -s "${root_service_log}" ]] || {
    fail "CoreSimulator ownership preflight touched simulator state"
}

for result_mode in zero partial failed skipped expected wrong-total failed-result; do
    negative_log="${FIXTURE_ROOT}/negative-${result_mode}.log"
    if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
        PSY_UI_POLICY_LOG="${negative_log}" \
        PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-negative-${result_mode}" \
        PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
        PSY_UI_POLICY_RESULT_MODE="${result_mode}" \
        PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/negative-${result_mode}/verify" \
        bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
        fail "xcresult summary mode ${result_mode} passed the UI gate"
    fi
done

malformed_log="${FIXTURE_ROOT}/malformed-create.log"
if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${malformed_log}" \
    PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-malformed-create" \
    PSY_UI_POLICY_CREATE_MODE=malformed-iphone \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/malformed-create/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
    fail "malformed simctl create output passed the UI gate"
fi
printf '%s\n' \
    "create:iphone:${IPHONE_ID}" \
    "delete:${IPHONE_ID}" >"${FIXTURE_ROOT}/malformed-create.expected"
diff -u "${FIXTURE_ROOT}/malformed-create.expected" "${malformed_log}" || {
    fail "malformed simctl create did not recover and delete the exact created device"
}

preexisting_log="${FIXTURE_ROOT}/preexisting-name.log"
preexisting_state="${FIXTURE_ROOT}/state-preexisting-name"
preexisting_id="44444444-4444-4444-4444-444444444444"
mkdir -p "${preexisting_state}"
: >"${preexisting_log}"
printf '%s\t%s\n' \
    "${preexisting_id}" \
    "Psynguechthyngue-ReleaseGate-iphone-${FIXTURE_UUID}" \
    >"${preexisting_state}/devices.tsv"
if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${preexisting_log}" \
    PSY_UI_POLICY_STATE_ROOT="${preexisting_state}" \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/preexisting-name/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
    fail "pre-existing exact simulator name passed the create guard"
fi
[[ ! -s "${preexisting_log}" ]] || {
    fail "create-name collision touched or deleted a pre-existing simulator"
}

flaky_delete_log="${FIXTURE_ROOT}/flaky-delete.log"
if ! PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${flaky_delete_log}" \
    PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-flaky-delete" \
    PSY_UI_POLICY_DELETE_MODE=flaky \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/flaky-delete/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
    fail "transient exact simctl delete failure did not recover"
fi
[[ "$(grep -Fc 'delete:' "${flaky_delete_log}")" -eq 4 ]] || {
    fail "transient cleanup did not retry each exact ephemeral device once"
}
[[ "$(grep -Fxc "delete:${IPAD_ID}" "${flaky_delete_log}")" -eq 2 ]] || {
    fail "transient cleanup did not retry the exact ephemeral iPad"
}
[[ "$(grep -Fxc "delete:${IPHONE_ID}" "${flaky_delete_log}")" -eq 2 ]] || {
    fail "transient cleanup did not retry the exact ephemeral iPhone"
}

delete_failure_log="${FIXTURE_ROOT}/delete-failure.log"
if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_UI_POLICY_LOG="${delete_failure_log}" \
    PSY_UI_POLICY_STATE_ROOT="${FIXTURE_ROOT}/state-delete-failure" \
    PSY_UI_POLICY_DELETE_MODE=fail \
    PSY_UI_POLICY_UNIT_COUNT="${FIXTURE_UNIT_TEST_COUNT}" \
    PSY_VERIFY_BUILD_ROOT="${FIXTURE_ROOT}/delete-failure/verify" \
    bash "${FIXTURE_ROOT}/Scripts/test-ui.sh" >/dev/null 2>&1; then
    fail "simctl delete failure did not fail the UI gate"
fi
[[ "$(grep -Fc 'delete:' "${delete_failure_log}")" -eq 8 ]] || {
    fail "cleanup did not exhaust bounded retries for both exact ephemeral devices"
}
[[ "$(grep -Fxc "delete:${IPAD_ID}" "${delete_failure_log}")" -eq 4 ]] || {
    fail "cleanup did not exhaust bounded retries for the exact ephemeral iPad"
}
[[ "$(grep -Fxc "delete:${IPHONE_ID}" "${delete_failure_log}")" -eq 4 ]] || {
    fail "cleanup did not exhaust bounded retries for the exact ephemeral iPhone"
}

printf 'Ephemeral iPhone/iPad, exact action/selectors/results/cleanup, and negative policy tests passed.\n'
