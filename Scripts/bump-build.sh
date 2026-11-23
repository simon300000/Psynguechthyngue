#!/usr/bin/env bash
# Sets CURRENT_PROJECT_VERSION in Config/Base.xcconfig to a UTC timestamp
# (YYYYMMDDHHMM) or an explicit number, for use before archiving for upload.
# Usage: Scripts/bump-build.sh [build-number]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${ROOT_DIR}/Config/Base.xcconfig"
BUILD="${1:-$(date -u +%Y%m%d%H%M)}"
[[ "${BUILD}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "invalid build number: ${BUILD}" >&2; exit 64; }
grep -q '^CURRENT_PROJECT_VERSION = ' "${FILE}" || { echo "CURRENT_PROJECT_VERSION missing in ${FILE}" >&2; exit 1; }
sed -i '' -E "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${BUILD}/" "${FILE}"
echo "CURRENT_PROJECT_VERSION = ${BUILD}"
