#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
VERSION="${1:-unpublished}"
OUTPUT="${2:-${ROOT_DIR}/.build/release/Psynguechthyngue-${VERSION}-release-sources.tar.gz}"
LICENSE_MAP="${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json"
SBOM="${ROOT_DIR}/Docs/SBOM.spdx.json"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"

[[ "${VERSION}" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$ ]] || {
    printf 'error: release source version is unsafe\n' >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf 'error: python3 is required to prepare release source materials\n' >&2
    exit 1
}
mkdir -p "${BUILD_CACHE}"
export GOCACHE="${BUILD_CACHE}"

bash "${SCRIPT_DIR}/check-licenses.sh"
python3 "${ROOT_DIR}/Tools/license_release.py" bundle \
    --map "${LICENSE_MAP}" \
    --sbom "${SBOM}" \
    --go-core "${ROOT_DIR}/GoCore" \
    --project-root "${ROOT_DIR}" \
    --output "${OUTPUT}"
python3 "${ROOT_DIR}/Tools/license_release.py" verify-bundle \
    --map "${LICENSE_MAP}" \
    --sbom "${SBOM}" \
    --project-root "${ROOT_DIR}" \
    --archive "${OUTPUT}"

shasum -a 256 "${OUTPUT}"
