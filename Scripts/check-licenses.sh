#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fails when SBOM / THIRD_PARTY_NOTICES.md are stale, a linked module has no
# detected license, or NOTICE lacks the disclaimer / pinned Syncthing commit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/psy-licenses.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM

python3 -I "${ROOT_DIR}/Tools/licenses.py" check
bash "${SCRIPT_DIR}/generate-sbom.sh" "${tmp}/sbom.json"
bash "${SCRIPT_DIR}/generate-third-party-notices.sh" "${tmp}/notices.md"
cmp -s "${tmp}/sbom.json" "${ROOT_DIR}/Docs/SBOM.spdx.json" || { echo "error: Docs/SBOM.spdx.json is stale; run Scripts/generate-sbom.sh" >&2; exit 1; }
cmp -s "${tmp}/notices.md" "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" || { echo "error: THIRD_PARTY_NOTICES.md is stale; run Scripts/generate-third-party-notices.sh" >&2; exit 1; }

commit="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "${ROOT_DIR}/GoBridge/SyncthingPin.json")"
tag="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["tag"])' "${ROOT_DIR}/GoBridge/SyncthingPin.json")"
grep -q "independent, unofficial client" "${ROOT_DIR}/NOTICE" || { echo "error: NOTICE lacks the unofficial-client disclaimer" >&2; exit 1; }
grep -q "${commit}" "${ROOT_DIR}/NOTICE" || { echo "error: NOTICE does not name pinned Syncthing commit ${commit}" >&2; exit 1; }
grep -q "${tag}" "${ROOT_DIR}/NOTICE" || { echo "error: NOTICE does not name Syncthing ${tag}" >&2; exit 1; }
echo "license check passed"
