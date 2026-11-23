#!/usr/bin/env bash
# Repository verification gate.
#
#   bash Scripts/verify.sh [all|sanity|swift|go|licenses|ios|ui|format]
#
# all = sanity + swift + go + licenses + ios + ui. `format` (swift-format lint)
# is opt-in. Build products live under .build/verify (PSY_VERIFY_BUILD_ROOT).
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

case "${MODE}" in
    all)
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
    *) fail "unknown mode '${MODE}'; expected all, sanity, format, swift, go, licenses, ios or ui" ;;
esac

log "Verification (${MODE}) completed successfully"
