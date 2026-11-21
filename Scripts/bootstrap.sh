#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${PSY_XCFRAMEWORK_CACHE_ROOT:-}" ]]; then
    printf 'error: PSY_XCFRAMEWORK_CACHE_ROOT is unsupported; bootstrap requires an isolated cache\n' >&2
    exit 1
fi
unset PSY_XCFRAMEWORK_CACHE_ROOT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
ARTIFACTS_DIR="${ROOT_DIR}/Artifacts"
ARTIFACT="${ARTIFACTS_DIR}/Mobilebridge.xcframework"
SIDECAR="${ARTIFACT}.provenance.json"
BACKUP_ARTIFACT="${ARTIFACTS_DIR}/.Mobilebridge.xcframework.previous"
BACKUP_SIDECAR="${ARTIFACTS_DIR}/.Mobilebridge.xcframework.provenance.json.previous"
LOCK_DIR="${ARTIFACTS_DIR}/.mobilebridge-bootstrap.lock"
PROVENANCE_TOOL="${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh"
BUILD_TOOL="${ROOT_DIR}/GoCore/Scripts/build-xcframework.sh"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
# shellcheck source=../GoCore/Scripts/xcframework-build-settings.sh
source "${ROOT_DIR}/GoCore/Scripts/xcframework-build-settings.sh"

DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-${PSY_XCFRAMEWORK_DEFAULT_DEPLOYMENT_TARGET}}"
BOOTSTRAP_MODE="${1:-}"
BUILD_ROOT=""
LOCK_HELD=0
REPLACEMENT_STARTED=0
NEW_ARTIFACT_PUBLISHED=0
NEW_SIDECAR_PUBLISHED=0

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

case "${BOOTSTRAP_MODE}" in
    ""|--preflight|--reuse-verified) ;;
    *) fail "usage: ${0##*/} [--preflight|--reuse-verified]" ;;
esac
[[ "$#" -le 1 ]] || fail "usage: ${0##*/} [--preflight|--reuse-verified]"

remove_generated_path() {
    local path="$1"

    if [[ -L "${path}" || -f "${path}" ]]; then
        rm -f -- "${path}"
    elif [[ -d "${path}" ]]; then
        rm -rf -- "${path}"
    elif [[ -e "${path}" ]]; then
        fail "refusing to remove unsupported generated path type"
    fi
}

rollback_replacement() {
    if [[ -e "${BACKUP_ARTIFACT}" || -L "${BACKUP_ARTIFACT}" ]]; then
        remove_generated_path "${ARTIFACT}"
        mv -- "${BACKUP_ARTIFACT}" "${ARTIFACT}"
    elif [[ "${NEW_ARTIFACT_PUBLISHED}" -eq 1 ]]; then
        remove_generated_path "${ARTIFACT}"
    fi
    if [[ -e "${BACKUP_SIDECAR}" || -L "${BACKUP_SIDECAR}" ]]; then
        remove_generated_path "${SIDECAR}"
        mv -- "${BACKUP_SIDECAR}" "${SIDECAR}"
    elif [[ "${NEW_SIDECAR_PUBLISHED}" -eq 1 ]]; then
        remove_generated_path "${SIDECAR}"
    fi
}

cleanup() {
    local status=$?

    trap - EXIT INT TERM
    if [[ "${REPLACEMENT_STARTED}" -eq 1 ]]; then
        rollback_replacement
    fi
    if [[ -n "${BUILD_ROOT}" && -d "${BUILD_ROOT}" ]]; then
        rm -rf -- "${BUILD_ROOT}"
    fi
    if [[ "${LOCK_HELD}" -eq 1 ]]; then
        rm -f -- "${LOCK_DIR}/pid"
        rmdir -- "${LOCK_DIR}" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_artifact() {
    bash "${PROVENANCE_TOOL}" verify "${ARTIFACT}" "${SIDECAR}" "${DEPLOYMENT_TARGET}"
}

acquire_lock() {
    local owner_pid=""

    if mkdir -- "${LOCK_DIR}" 2>/dev/null; then
        LOCK_HELD=1
    else
        [[ -d "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || fail "bootstrap lock path is unsafe"
        if [[ -f "${LOCK_DIR}/pid" && ! -L "${LOCK_DIR}/pid" ]]; then
            IFS= read -r owner_pid <"${LOCK_DIR}/pid" || true
        fi
        if [[ "${owner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${owner_pid}" 2>/dev/null; then
            fail "another Mobilebridge bootstrap is already running"
        fi
        rm -f -- "${LOCK_DIR}/pid"
        rmdir -- "${LOCK_DIR}" 2>/dev/null || fail "could not recover stale bootstrap lock"
        mkdir -- "${LOCK_DIR}" 2>/dev/null || fail "another Mobilebridge bootstrap acquired the lock"
        LOCK_HELD=1
    fi
    printf '%s\n' "$$" >"${LOCK_DIR}/pid"
}

recover_interrupted_replacement() {
    if [[ -e "${BACKUP_ARTIFACT}" || -L "${BACKUP_ARTIFACT}" ]]; then
        [[ -d "${BACKUP_ARTIFACT}" && ! -L "${BACKUP_ARTIFACT}" ]] || {
            fail "previous XCFramework backup is unsafe"
        }
        if [[ -d "${ARTIFACT}" && -f "${SIDECAR}" ]] && verify_artifact >/dev/null 2>&1; then
            remove_generated_path "${BACKUP_ARTIFACT}"
            remove_generated_path "${BACKUP_SIDECAR}"
        else
            remove_generated_path "${ARTIFACT}"
            remove_generated_path "${SIDECAR}"
            mv -- "${BACKUP_ARTIFACT}" "${ARTIFACT}"
            if [[ -e "${BACKUP_SIDECAR}" || -L "${BACKUP_SIDECAR}" ]]; then
                mv -- "${BACKUP_SIDECAR}" "${SIDECAR}"
            fi
            printf 'Recovered the previous Mobilebridge artifact after an interrupted replacement.\n'
        fi
    elif [[ -e "${BACKUP_SIDECAR}" || -L "${BACKUP_SIDECAR}" ]]; then
        remove_generated_path "${BACKUP_SIDECAR}"
    fi
}

replace_with_verified_artifact() {
    local new_artifact="$1"
    local new_sidecar="$2"

    [[ -d "${new_artifact}" && ! -L "${new_artifact}" ]] || fail "verified replacement artifact disappeared"
    [[ -f "${new_sidecar}" && ! -L "${new_sidecar}" ]] || fail "verified replacement provenance disappeared"
    [[ ! -e "${BACKUP_ARTIFACT}" && ! -L "${BACKUP_ARTIFACT}" ]] || fail "replacement backup was not cleaned"
    [[ ! -e "${BACKUP_SIDECAR}" && ! -L "${BACKUP_SIDECAR}" ]] || fail "replacement provenance backup was not cleaned"

    REPLACEMENT_STARTED=1
    if [[ -e "${ARTIFACT}" || -L "${ARTIFACT}" ]]; then
        mv -- "${ARTIFACT}" "${BACKUP_ARTIFACT}"
    fi
    if [[ -e "${SIDECAR}" || -L "${SIDECAR}" ]]; then
        mv -- "${SIDECAR}" "${BACKUP_SIDECAR}"
    fi
    mv -- "${new_sidecar}" "${SIDECAR}"
    NEW_SIDECAR_PUBLISHED=1
    mv -- "${new_artifact}" "${ARTIFACT}"
    NEW_ARTIFACT_PUBLISHED=1
    verify_artifact

    REPLACEMENT_STARTED=0
    NEW_ARTIFACT_PUBLISHED=0
    NEW_SIDECAR_PUBLISHED=0
    remove_generated_path "${BACKUP_ARTIFACT}"
    remove_generated_path "${BACKUP_SIDECAR}"
}

[[ -f "${PROVENANCE_TOOL}" && -f "${BUILD_TOOL}" && -f "${SYNCTHING_SOURCE_GATE}" ]] || {
    fail "Mobilebridge build/provenance scripts are incomplete"
}

if [[ "${BOOTSTRAP_MODE}" == "--preflight" ]]; then
    GOENV=off GOFLAGS= GOWORK=off sh "${SYNCTHING_SOURCE_GATE}" --preflight
    command -v xcodebuild >/dev/null 2>&1 || fail "Xcode is required to build Mobilebridge"
    printf 'Mobilebridge bootstrap preflight passed with %s at %s.\n' \
        "${PSY_GO_VERSION}" "${PSY_GO_BINARY}"
    exit 0
fi

if [[ "${BOOTSTRAP_MODE}" != "--reuse-verified" ]]; then
    GOENV=off GOFLAGS= GOWORK=off sh "${SYNCTHING_SOURCE_GATE}" --prepare
fi

if [[ -e "${ARTIFACTS_DIR}" || -L "${ARTIFACTS_DIR}" ]]; then
    [[ -d "${ARTIFACTS_DIR}" && ! -L "${ARTIFACTS_DIR}" ]] || fail "Artifacts path must be a non-symlink directory"
else
    mkdir -- "${ARTIFACTS_DIR}"
fi

acquire_lock
recover_interrupted_replacement

if [[ "${BOOTSTRAP_MODE}" == "--reuse-verified" && -d "${ARTIFACT}" && -f "${SIDECAR}" ]] \
    && verify_artifact >/dev/null 2>&1; then
    printf 'Reusing provenance-verified Mobilebridge XCFramework for Debug build.\n'
    exit 0
fi
if [[ "${BOOTSTRAP_MODE}" == "--reuse-verified" ]]; then
    GOENV=off GOFLAGS= GOWORK=off sh "${SYNCTHING_SOURCE_GATE}" --prepare
fi

if [[ -n "${PSY_BOOTSTRAP_FORCE_REBUILD:-}" ]]; then
    printf 'PSY_BOOTSTRAP_FORCE_REBUILD is deprecated; bootstrap always rebuilds current source.\n' >&2
fi

if [[ -d "${ARTIFACT}" && -f "${SIDECAR}" ]]; then
    if verify_artifact >/dev/null 2>&1; then
        printf 'Existing Mobilebridge build record is coherent; rebuilding from current source by policy.\n'
    else
        printf 'Existing Mobilebridge build record is stale; rebuilding without modifying the old artifact first.\n'
    fi
elif [[ -e "${ARTIFACT}" || -L "${ARTIFACT}" || -e "${SIDECAR}" || -L "${SIDECAR}" ]]; then
    printf 'Mobilebridge artifact/build-record pair is incomplete; rebuilding without modifying the old files first.\n'
else
    printf 'Building Mobilebridge from current source.\n'
fi

command -v xcodebuild >/dev/null 2>&1 || fail "Xcode is required to build Mobilebridge"

BUILD_ROOT="$(mktemp -d "${ARTIFACTS_DIR}/.mobilebridge-bootstrap-build.XXXXXX")"
NEW_ARTIFACT="${BUILD_ROOT}/Mobilebridge.xcframework"
NEW_SIDECAR="${NEW_ARTIFACT}.provenance.json"

IOS_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" sh "${BUILD_TOOL}" "${NEW_ARTIFACT}"
bash "${PROVENANCE_TOOL}" verify "${NEW_ARTIFACT}" "${NEW_SIDECAR}" "${DEPLOYMENT_TARGET}"
replace_with_verified_artifact "${NEW_ARTIFACT}" "${NEW_SIDECAR}"

printf 'Bootstrap completed with a freshly built, provenance-verified Mobilebridge XCFramework.\n'
