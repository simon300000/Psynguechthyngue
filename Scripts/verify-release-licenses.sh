#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
SOURCE_OFFER="${1:-}"
LICENSE_MAP="${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json"
SBOM="${ROOT_DIR}/Docs/SBOM.spdx.json"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"

[[ -n "${SOURCE_OFFER}" && -f "${SOURCE_OFFER}" && ! -L "${SOURCE_OFFER}" ]] || {
    printf 'error: pass a regular, published release source-offer JSON file\n' >&2
    exit 1
}
command -v curl >/dev/null 2>&1 || {
    printf 'error: curl is required to verify the published source offer\n' >&2
    exit 1
}
[[ -z "$(git -C "${ROOT_DIR}" status --porcelain)" ]] || {
    printf 'error: published release license verification requires a clean checkout\n' >&2
    exit 1
}
expected_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
mkdir -p "${BUILD_CACHE}"
export GOCACHE="${BUILD_CACHE}"

bash "${SCRIPT_DIR}/check-licenses.sh"
source_url="$(python3 "${ROOT_DIR}/Tools/license_release.py" offer-url --offer "${SOURCE_OFFER}" --field sourceURL)"
notices_url="$(python3 "${ROOT_DIR}/Tools/license_release.py" offer-url --offer "${SOURCE_OFFER}" --field noticesURL)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/psy-release-license.XXXXXX")"
cleanup() { rm -rf -- "${temporary_dir}"; }
trap cleanup EXIT INT TERM
archive="${temporary_dir}/release-sources.tar.gz"
notices="${temporary_dir}/THIRD_PARTY_NOTICES.md"

curl --proto '=https' --tlsv1.2 --fail --show-error --location --max-redirs 3 --retry 2 \
    --output "${archive}" "${source_url}"
curl --proto '=https' --tlsv1.2 --fail --show-error --location --max-redirs 3 --retry 2 \
    --output "${notices}" "${notices_url}"

python3 "${ROOT_DIR}/Tools/license_release.py" verify-offer \
    --map "${LICENSE_MAP}" \
    --sbom "${SBOM}" \
    --project-root "${ROOT_DIR}" \
    --archive "${archive}" \
    --offer "${SOURCE_OFFER}" \
    --expected-commit "${expected_commit}"
cmp -s "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${notices}" || {
    printf 'error: published third-party notices differ from the release checkout\n' >&2
    exit 1
}
[[ "$(git -C "${ROOT_DIR}" rev-parse HEAD)" == "${expected_commit}" ]] || {
    printf 'error: release checkout commit changed during published-material verification\n' >&2
    exit 1
}
[[ -z "$(git -C "${ROOT_DIR}" status --porcelain)" ]] || {
    printf 'error: release checkout changed during published-material verification\n' >&2
    exit 1
}

printf 'Published source archive and third-party notices verified.\n'
