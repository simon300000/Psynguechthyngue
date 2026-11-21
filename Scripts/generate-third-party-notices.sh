#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
OUTPUT="${1:-${ROOT_DIR}/THIRD_PARTY_NOTICES.md}"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"
temporary="$(mktemp "${TMPDIR:-/tmp}/psy-third-party-notices.XXXXXX")"
cleanup() { rm -f -- "${temporary}"; }
trap cleanup EXIT INT TERM

mkdir -p "${BUILD_CACHE}"
export GOCACHE="${BUILD_CACHE}"
GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --prepare
python3 "${ROOT_DIR}/Tools/license_release.py" render-notices \
    --map "${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json" \
    --sbom "${ROOT_DIR}/Docs/SBOM.spdx.json" >"${temporary}"
mv "${temporary}" "${OUTPUT}"
trap - EXIT INT TERM
printf 'Generated %s\n' "${OUTPUT#"${ROOT_DIR}/"}"
