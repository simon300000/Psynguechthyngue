#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regenerates THIRD_PARTY_NOTICES.md from the Go modules linked into GoBridge/psybridge.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${ROOT_DIR}/THIRD_PARTY_NOTICES.md}"
python3 -I "${ROOT_DIR}/Tools/licenses.py" notices "${OUTPUT}"
