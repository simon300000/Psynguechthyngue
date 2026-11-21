#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regenerates Docs/SBOM.spdx.json from the Go modules linked into GoBridge/psybridge.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${ROOT_DIR}/Docs/SBOM.spdx.json}"
python3 -I "${ROOT_DIR}/Tools/licenses.py" sbom "${OUTPUT}"
