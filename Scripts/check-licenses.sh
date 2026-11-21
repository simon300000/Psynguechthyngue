#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
SBOM="${ROOT_DIR}/Docs/SBOM.spdx.json"
LICENSE_MAP="${ROOT_DIR}/Docs/DEPENDENCY_LICENSE_MAP.json"
SYNCTHING_SOURCE_GATE="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
BUILD_CACHE="${PSY_LICENSE_BUILD_CACHE:-${ROOT_DIR}/.build/license-go-cache}"

[[ -f "${ROOT_DIR}/LICENSE" ]] || { printf 'error: root LICENSE is missing\n' >&2; exit 1; }
grep -F 'MIT License' "${ROOT_DIR}/LICENSE" >/dev/null || {
    printf 'error: original project license must remain MIT\n' >&2
    exit 1
}
for file in \
    NOTICE \
    THIRD_PARTY_NOTICES.md \
    Docs/LICENSE_AND_SOURCE.md \
    Docs/DEPENDENCY_LICENSE_MAP.json \
    Docs/RELEASE_SOURCE_OFFER.example.json \
    "${SBOM#"${ROOT_DIR}/"}"; do
    [[ -f "${ROOT_DIR}/${file}" ]] || { printf 'error: license input is missing: %s\n' "${file}" >&2; exit 1; }
done
[[ ! -e "${ROOT_DIR}/GoCore/vendor" && ! -L "${ROOT_DIR}/GoCore/vendor" ]] || {
    printf 'error: vendored Go source requires a separate covered-file and license review\n' >&2
    exit 1
}
mkdir -p "${BUILD_CACHE}"
export GOCACHE="${BUILD_CACHE}"
GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --prepare
expected_syncthing="$(GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --field moduleVersion)"
expected_commit="$(GOCACHE="${BUILD_CACHE}" sh "${SYNCTHING_SOURCE_GATE}" --field moduleCommit)"
grep -F "github.com/syncthing/syncthing ${expected_syncthing}" "${ROOT_DIR}/GoCore/go.mod" >/dev/null || {
    printf 'error: the reviewed Syncthing pseudo-version changed\n' >&2
    exit 1
}
grep -F "${expected_commit}" "${ROOT_DIR}/NOTICE" >/dev/null || {
    printf 'error: NOTICE does not identify the reviewed Syncthing commit\n' >&2
    exit 1
}
(
	cd "${ROOT_DIR}/GoCore"
	GOCACHE="${BUILD_CACHE}" GOENV=off GOFLAGS= GOWORK=off go mod verify
	tidy_output="$(GOCACHE="${BUILD_CACHE}" GOENV=off GOFLAGS= GOWORK=off go mod tidy -diff)"
	[[ -z "${tidy_output}" ]] || {
		printf '%s\n' "${tidy_output}" >&2
		exit 1
	}
)
grep -F 'independent, unofficial client' "${ROOT_DIR}/NOTICE" >/dev/null || {
    printf 'error: NOTICE is missing the independent-project trademark disclaimer\n' >&2
    exit 1
}

temporary="$(mktemp "${TMPDIR:-/tmp}/psy-sbom-check.XXXXXX")"
temporary_notices="$(mktemp "${TMPDIR:-/tmp}/psy-notices-check.XXXXXX")"
cleanup() { rm -f -- "${temporary}" "${temporary_notices}"; }
trap cleanup EXIT INT TERM
bash "${SCRIPT_DIR}/generate-sbom.sh" "${temporary}" >/dev/null
if ! cmp -s "${SBOM}" "${temporary}"; then
    printf 'error: Docs/SBOM.spdx.json is stale; run make sbom and review the dependency/license changes\n' >&2
    exit 1
fi

python3 "${ROOT_DIR}/Tools/license_release.py" render-notices \
    --map "${LICENSE_MAP}" \
    --sbom "${SBOM}" >"${temporary_notices}"
if ! cmp -s "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${temporary_notices}"; then
    printf 'error: THIRD_PARTY_NOTICES.md is stale; run make notices and review the exact dependency changes\n' >&2
    exit 1
fi

python3 - "${SBOM}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
assert document["spdxVersion"] == "SPDX-2.3"
packages = document["packages"]
assert any(package["name"] == "github.com/syncthing/syncthing" for package in packages)
linked = {
    relationship["relatedSpdxElement"]
    for relationship in document["relationships"]
    if relationship["relationshipType"] == "DEPENDS_ON"
}
unknown_linked = sorted(
    package["name"] for package in packages
    if package["SPDXID"] in linked and package["licenseDeclared"] == "NOASSERTION"
)
if unknown_linked:
    print("error: linked modules have no detected license candidate:", ", ".join(unknown_linked), file=sys.stderr)
    raise SystemExit(1)
if any(package["licenseConcluded"] != "NOASSERTION" for package in packages if package["SPDXID"] in linked):
    print("error: automated engineering evidence must not be presented as a legal license conclusion", file=sys.stderr)
    raise SystemExit(1)
print(f"SPDX inventory verified: {len(packages)} packages, {len(linked)} linked Go modules.")
PY

bash "${SCRIPT_DIR}/test-license-tools.sh"

printf 'License pins, controlled mapping, notices, deterministic SPDX inventory, and source bundle verified.\n'
