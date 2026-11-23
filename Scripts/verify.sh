#!/usr/bin/env bash
# Repository verification gate.
#
#   bash Scripts/verify.sh [all|serial|sanity|swift|go|licenses|ios|ui|format]
#
# all = sanity + swift + go + licenses + ios + ui. After sanity and one
# PsyBridge.xcframework bootstrap it runs three lanes at once (swift -> go ->
# licenses, ios, ui), each logging to .build/verify/logs/<lane>.log; `serial`
# (or PSY_VERIFY_SERIAL=1) runs the same steps one after another with output
# inline. `format` (swift-format lint) is opt-in. Build products live under
# .build/verify (PSY_VERIFY_BUILD_ROOT).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PSY_VERIFY_BUILD_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
MODE="${1:-all}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

verify_sanity() {
    log "Project and repository sanity"
    bash "${SCRIPT_DIR}/check-project.sh"
}

verify_format() {
    log "Swift formatting (swift-format lint)"
    xcrun swift-format lint --strict --recursive \
        "${ROOT_DIR}/App" "${ROOT_DIR}/FileProvider" "${ROOT_DIR}/Platform" \
        "${ROOT_DIR}/Sources" "${ROOT_DIR}/Tests"
}

verify_swift() {
    command -v swift >/dev/null 2>&1 || fail "swift is required"
    log "SwiftPM tests (PsySyncTests)"
    (cd "${ROOT_DIR}" && swift test --scratch-path "${PSY_VERIFY_BUILD_ROOT}/swiftpm")
}

verify_go() {
    command -v go >/dev/null 2>&1 || fail "go is required for GoBridge tests"
    log "GoBridge vet + tests + race (-tags noassets)"
    sh "${ROOT_DIR}/GoBridge/Scripts/test.sh"
}

verify_licenses() {
    log "Licenses, NOTICE, THIRD_PARTY_NOTICES and SBOM are current"
    bash "${SCRIPT_DIR}/check-licenses.sh"
}

verify_ios() {
    log "PsyBridge.xcframework, Debug simulator and unsigned Release device builds"
    bash "${SCRIPT_DIR}/bootstrap.sh"
    bash "${SCRIPT_DIR}/build-ios.sh"
}

verify_ui() {
    log "Simulator UI tests (iPhone + iPad, FakeSyncEngine fixtures)"
    bash "${SCRIPT_DIR}/bootstrap.sh"
    bash "${SCRIPT_DIR}/test-ui.sh"
}

# One parallel lane: runs the given modes in order, each as its own
# verify.sh process (so `set -e` holds inside it), stopping at the first
# failure. Output goes to the lane's log; exit status and seconds to
# <lane>.status.
run_lane() {
    local name="$1"; shift
    local started=$SECONDS status=0 mode
    for mode in "$@"; do
        bash "${SCRIPT_DIR}/verify.sh" "${mode}" >>"${LOG_DIR}/${name}.log" 2>&1 || { status=$?; break; }
    done
    printf '%s %s\n' "${status}" "$(( SECONDS - started ))" >"${LOG_DIR}/${name}.status"
}

verify_parallel() {
    local total_started=$SECONDS
    verify_sanity
    # Once, before the lanes: ios and ui both need the xcframework and would
    # otherwise build it concurrently.
    log "PsyBridge.xcframework"
    bash "${SCRIPT_DIR}/bootstrap.sh"

    LOG_DIR="${PSY_VERIFY_BUILD_ROOT}/logs"
    rm -rf "${LOG_DIR}"; mkdir -p "${LOG_DIR}"
    log "Running lanes in parallel (logs in ${LOG_DIR})"
    local lanes=(tests ios ui) pids=() lane
    run_lane tests swift go licenses & pids+=($!)
    run_lane ios ios & pids+=($!)
    run_lane ui ui & pids+=($!)
    trap 'kill "${pids[@]}" 2>/dev/null; exit 130' INT TERM
    wait "${pids[@]}" || true
    trap - INT TERM

    local failed=() status secs
    for lane in "${lanes[@]}"; do
        read -r status secs <"${LOG_DIR}/${lane}.status" 2>/dev/null || { status=1; secs=?; }
        if [[ "${status}" == 0 ]]; then
            printf '  %-6s passed in %ss\n' "${lane}" "${secs}"
        else
            printf '  %-6s FAILED (exit %s) in %ss\n' "${lane}" "${status}" "${secs}"
            failed+=("${lane}")
        fi
    done
    # Result lines a reader looks for, from the lane logs.
    grep -h -E 'Test run with [0-9]+ tests|UI tests: [0-9]+ passed' "${LOG_DIR}"/*.log 2>/dev/null | sed 's/^/  /' || true
    for lane in ${failed[@]+"${failed[@]}"}; do
        printf '\n--- last 60 lines of %s ---\n' "${LOG_DIR}/${lane}.log"
        tail -n 60 "${LOG_DIR}/${lane}.log"
    done
    printf '  total %ss\n' "$(( SECONDS - total_started ))"
    [[ ${#failed[@]} -eq 0 ]] || fail "lanes failed: ${failed[*]}"
}

[[ "${MODE}" == all && "${PSY_VERIFY_SERIAL:-0}" == 1 ]] && MODE=serial

case "${MODE}" in
    all) verify_parallel ;;
    serial)
        verify_sanity
        verify_swift
        verify_go
        verify_licenses
        verify_ios
        verify_ui
        ;;
    sanity) verify_sanity ;;
    format) verify_format ;;
    swift) verify_swift ;;
    go) verify_go ;;
    licenses) verify_licenses ;;
    ios) verify_ios ;;
    ui) verify_ui ;;
    *) fail "unknown mode '${MODE}'; expected all, serial, sanity, format, swift, go, licenses, ios or ui" ;;
esac

log "Verification (${MODE}) completed successfully"
