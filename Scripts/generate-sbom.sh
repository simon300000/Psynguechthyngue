#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
OUTPUT="${1:-${ROOT_DIR}/Docs/SBOM.spdx.json}"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"
LICENSE_MAP="${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"

command -v go >/dev/null 2>&1 || {
    printf 'error: go is required to generate the dependency SBOM\n' >&2
    exit 1
}
[[ -f "${LICENSE_MAP}" && ! -L "${LICENSE_MAP}" ]] || {
    printf 'error: controlled dependency license map is missing or unsafe\n' >&2
    exit 1
}

mkdir -p "$(dirname "${OUTPUT}")"
mkdir -p "${BUILD_CACHE}"
GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --prepare
temporary="$(mktemp "${TMPDIR:-/tmp}/psy-sbom.XXXXXX")"
cleanup() { rm -f -- "${temporary}"; }
trap cleanup EXIT INT TERM

(
    cd "${ROOT_DIR}/GoCore"
	GOCACHE="${BUILD_CACHE}" GOENV=off GOFLAGS= GOWORK=off go run \
		"${ROOT_DIR}/Tools/license_inventory.go" \
		"${ROOT_DIR}/Tools/syncthing_contract.go" \
		"${ROOT_DIR}/GoCore" "${LICENSE_MAP}"
) >"${temporary}"

mv "${temporary}" "${OUTPUT}"
trap - EXIT INT TERM
printf 'Generated %s\n' "${OUTPUT#"${ROOT_DIR}/"}"
