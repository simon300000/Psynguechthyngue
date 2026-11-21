#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
LICENSE_MAP="${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json"
SBOM="${ROOT_DIR}/Docs/SBOM.spdx.json"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/psy-license-tools.XXXXXX")"
cleanup() { rm -rf -- "${temporary_dir}"; }
trap cleanup EXIT INT TERM

mkdir -p "${BUILD_CACHE}"
export GOCACHE="${BUILD_CACHE}"
GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --prepare
GOCACHE="${BUILD_CACHE}" GOENV=off GOFLAGS= GOWORK=off go test \
	"${ROOT_DIR}/Tools/license_inventory.go" \
	"${ROOT_DIR}/Tools/syncthing_contract.go" \
	"${ROOT_DIR}/Tools/license_inventory_test.go"
GOCACHE="${BUILD_CACHE}" GOENV=off GOFLAGS= GOWORK=off go test \
	"${ROOT_DIR}/Tools/syncthing_contract.go" "${ROOT_DIR}/Tools/syncthing_contract_test.go"
python3 -m unittest "${ROOT_DIR}/Tools/test_license_release.py"

for output in "${temporary_dir}/first.tar.gz" "${temporary_dir}/second.tar.gz"; do
    python3 "${ROOT_DIR}/Tools/license_release.py" bundle \
        --map "${LICENSE_MAP}" \
        --sbom "${SBOM}" \
        --go-core "${ROOT_DIR}/GoCore" \
        --project-root "${ROOT_DIR}" \
        --output "${output}" >/dev/null
    python3 "${ROOT_DIR}/Tools/license_release.py" verify-bundle \
        --map "${LICENSE_MAP}" \
        --sbom "${SBOM}" \
        --project-root "${ROOT_DIR}" \
        --archive "${output}" >/dev/null
done
cmp -s "${temporary_dir}/first.tar.gz" "${temporary_dir}/second.tar.gz" || {
    printf 'error: release source bundle is not deterministic\n' >&2
    exit 1
}

env \
	GO111MODULE=off \
	GOOS=plan9 \
	GOARCH=386 \
	CGO_ENABLED=0 \
	GOFLAGS=-mod=vendor \
	GOWORK="${temporary_dir}/hostile.work" \
	GOCACHE="${BUILD_CACHE}" \
	python3 "${ROOT_DIR}/Tools/license_release.py" bundle \
		--map "${LICENSE_MAP}" \
		--sbom "${SBOM}" \
		--go-core "${ROOT_DIR}/GoCore" \
		--project-root "${ROOT_DIR}" \
		--output "${temporary_dir}/hostile.tar.gz" >/dev/null
python3 "${ROOT_DIR}/Tools/license_release.py" verify-bundle \
	--map "${LICENSE_MAP}" \
	--sbom "${SBOM}" \
	--project-root "${ROOT_DIR}" \
	--archive "${temporary_dir}/hostile.tar.gz" >/dev/null
cmp -s "${temporary_dir}/first.tar.gz" "${temporary_dir}/hostile.tar.gz" || {
	printf 'error: hostile inherited Go environment changed the release source bundle\n' >&2
	exit 1
}

printf 'License-map fail-closed tests and deterministic source bundle tests passed.\n'
