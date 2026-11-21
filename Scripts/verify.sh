#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
VERIFY_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
MODE="${1:-all}"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

prepare_swift_caches() {
    mkdir -p \
        "${VERIFY_ROOT}/clang-module-cache" \
        "${VERIFY_ROOT}/swiftpm-module-cache" \
        "${VERIFY_ROOT}/swiftpm-cache" \
        "${VERIFY_ROOT}/swiftpm-config" \
        "${VERIFY_ROOT}/swiftpm-security" \
        "${VERIFY_ROOT}/swiftpm-scratch"

    export CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/clang-module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="${VERIFY_ROOT}/swiftpm-module-cache"
}

verify_sanity() {
    log "Project and configuration sanity"
    bash "${SCRIPT_DIR}/check-project.sh"
}

verify_format() {
    command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for Swift formatting verification"
    log "Swift strict formatting"
    xcrun swift-format lint --strict --recursive \
        "${ROOT_DIR}/App" \
        "${ROOT_DIR}/FileProvider" \
        "${ROOT_DIR}/Platform" \
        "${ROOT_DIR}/Sources" \
        "${ROOT_DIR}/Tests"
}

verify_swift() {
    command -v swift >/dev/null 2>&1 || fail "swift is required"
    prepare_swift_caches
    log "SwiftPM tests"
    swift test \
        --cache-path "${VERIFY_ROOT}/swiftpm-cache" \
        --config-path "${VERIFY_ROOT}/swiftpm-config" \
        --security-path "${VERIFY_ROOT}/swiftpm-security" \
        --scratch-path "${VERIFY_ROOT}/swiftpm-scratch" \
        --disable-sandbox \
        --disable-dependency-cache
}

verify_go() {
    if [[ ! -e "${ROOT_DIR}/GoCore" ]]; then
        log "Go core verification skipped (GoCore is not present)"
        return
    fi

    [[ -d "${ROOT_DIR}/GoCore" ]] || fail "GoCore exists but is not a directory"
    [[ -f "${ROOT_DIR}/GoCore/go.mod" ]] || fail "GoCore exists but GoCore/go.mod is missing"
    command -v go >/dev/null 2>&1 || fail "GoCore exists but go is not installed"

	mkdir -p "${VERIFY_ROOT}/go-build-cache" "${VERIFY_ROOT}/go-module-cache"
	GOCACHE="${VERIFY_ROOT}/go-build-cache" \
		GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
		sh "${SYNCTHING_SOURCE_GATE}" --prepare

	log "Syncthing source preparation lock and tamper contracts"
	GOCACHE="${VERIFY_ROOT}/go-build-cache" \
		GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
		bash "${ROOT_DIR}/GoCore/Scripts/test-prepare-lock.sh"
	GOCACHE="${VERIFY_ROOT}/go-build-cache" GO111MODULE=off GOENV=off GOFLAGS= GOWORK=off \
		go test "${ROOT_DIR}/Tools/syncthing_contract.go" "${ROOT_DIR}/Tools/syncthing_contract_test.go"

	log "Audited upstream producer and atomic database contracts"
	(
		cd "${ROOT_DIR}/.build/go/syncthing-readiness-v1"
		GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			GOENV=off GOFLAGS= GOWORK=off \
			go test -count=1 -tags noassets \
				-run '^(TestClusterConfigReceivedEventCarriesAcceptedRemoteIndexes|TestAtomicIndexIDAndSequence)$' \
				./lib/model ./internal/db/sqlite
	)

	log "Go module integrity and bridge compilation tests"
    (
        cd "${ROOT_DIR}/GoCore"
		go_mod_sha_before="$(shasum -a 256 go.mod | awk '{print $1}')"
		go_sum_sha_before="$(shasum -a 256 go.sum | awk '{print $1}')"
		GOENV=off GOFLAGS= GOWORK=off \
			GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			go run \
				"${ROOT_DIR}/Tools/license_inventory.go" \
				"${ROOT_DIR}/Tools/syncthing_contract.go" \
				"${ROOT_DIR}/GoCore" "${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json" \
				>/dev/null
		[[ "$(shasum -a 256 go.mod | awk '{print $1}')" == "${go_mod_sha_before}" ]] || fail "explicit module prefetch modified GoCore/go.mod"
		[[ "$(shasum -a 256 go.sum | awk '{print $1}')" == "${go_sum_sha_before}" ]] || fail "explicit module prefetch modified GoCore/go.sum"
		GOENV=off GOFLAGS= GOWORK=off \
			GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			go mod verify
		GOENV=off GOFLAGS= GOWORK=off \
			GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			go test -count=1 -tags noassets ./...
		GOENV=off GOFLAGS= GOWORK=off \
			GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			go vet -tags noassets ./...
		race_cache="$(mktemp -d /private/tmp/psy-go-race-cache.XXXXXX)"
		trap 'rm -rf -- "${race_cache}"' EXIT
		race_go_cache="${race_cache}/go-cache"
		race_tmp="${race_cache}/go-tmp"
		mkdir -p "${race_go_cache}" "${race_tmp}"
		GOENV=off GOFLAGS= GOWORK=off \
			GODEBUG= GOCACHE="${race_go_cache}" GOTMPDIR="${race_tmp}" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
			go test -race -count=1 -tags noassets ./mobilebridge
        tidy_diff="${VERIFY_ROOT}/go-mod-tidy.diff"
        tidy_stderr="${VERIFY_ROOT}/go-mod-tidy.stderr"
        tidy_status=0
		GOENV=off GOFLAGS= GOWORK=off \
			GOCACHE="${VERIFY_ROOT}/go-build-cache" \
			GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
            go mod tidy -diff >"${tidy_diff}" 2>"${tidy_stderr}" || tidy_status=$?

		if [[ "${tidy_status}" -ne 0 || -s "${tidy_diff}" || -s "${tidy_stderr}" ]]; then
			[[ ! -s "${tidy_stderr}" ]] || cat "${tidy_stderr}" >&2
			[[ ! -s "${tidy_diff}" ]] || cat "${tidy_diff}" >&2
			fail "go mod tidy -diff must be strictly empty"
		fi
		rm -f -- "${tidy_diff}" "${tidy_stderr}"
    )
}

verify_peer_interop() {
    [[ -f "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" ]] || {
        fail "peer interoperability harness is missing"
    }
    command -v go >/dev/null 2>&1 || fail "go is required for peer interoperability verification"
    mkdir -p "${VERIFY_ROOT}/go-build-cache" "${VERIFY_ROOT}/go-module-cache" "${VERIFY_ROOT}/logs"

    log "Pinned standard Syncthing peer interoperability"
	GOCACHE="${VERIFY_ROOT}/go-build-cache" \
		GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
		GOENV=off GOFLAGS= GOWORK=off \
        PEER_INTEROP_LOG="${VERIFY_ROOT}/logs/peer-interop.log" \
        bash "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh"
}

verify_licenses() {
    log "License pins, controlled mapping, notices, SBOM, and source bundle"
    PSY_LICENSE_BUILD_CACHE="${VERIFY_ROOT}/license-go-cache" \
        GOMODCACHE="${VERIFY_ROOT}/go-module-cache" \
        bash "${SCRIPT_DIR}/check-licenses.sh"
}

verify_ios() {
    log "Debug simulator and unsigned Release generic-device builds"
    bash "${SCRIPT_DIR}/build-ios.sh"
    log "XCFramework provenance determinism and tamper probes"
    bash "${ROOT_DIR}/GoCore/Scripts/test-xcframework-provenance.sh" \
        "${ROOT_DIR}/Artifacts/Mobilebridge.xcframework" \
        "${ROOT_DIR}/Artifacts/Mobilebridge.xcframework.provenance.json" \
        17.0
}

verify_ui() {
    log "iOS unit tests plus clean-state localized iPhone and iPad UI tests"
    bash "${SCRIPT_DIR}/test-ui.sh"
}

case "${MODE}" in
    all)
        verify_sanity
        verify_format
        verify_swift
        verify_go
        verify_peer_interop
        verify_licenses
        verify_ui
        # The final artifact writer is followed immediately by the full
        # built-product and provenance/tamper gate.
        verify_ios
        ;;
    sanity)
        verify_sanity
        ;;
    format)
        verify_format
        ;;
    swift)
        verify_swift
        ;;
    go)
        verify_go
        ;;
    interop)
        verify_peer_interop
        ;;
    licenses)
        verify_licenses
        ;;
    ios)
        verify_ios
        ;;
    ui)
        verify_ui
        ;;
    *)
        fail "unknown mode '${MODE}'; expected all, sanity, format, swift, go, interop, licenses, ios, or ui"
        ;;
esac

log "Verification completed successfully"
