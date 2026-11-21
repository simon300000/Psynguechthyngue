#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCALE_ROOT="${PSY_SCALE_BUILD_ROOT:-${ROOT_DIR}/.build/scale}"

mkdir -p \
    "${SCALE_ROOT}/clang-module-cache" \
    "${SCALE_ROOT}/swiftpm-module-cache" \
    "${SCALE_ROOT}/swiftpm-cache" \
    "${SCALE_ROOT}/swiftpm-config" \
    "${SCALE_ROOT}/swiftpm-security" \
    "${SCALE_ROOT}/swiftpm-scratch"

export CLANG_MODULE_CACHE_PATH="${SCALE_ROOT}/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${SCALE_ROOT}/swiftpm-module-cache"
export PSY_INDEX_SCALE_ITEM_COUNT=1000000

printf '==> One-million-item metadata index scale gate\n'
swift test \
    --cache-path "${SCALE_ROOT}/swiftpm-cache" \
    --config-path "${SCALE_ROOT}/swiftpm-config" \
    --security-path "${SCALE_ROOT}/swiftpm-security" \
    --scratch-path "${SCALE_ROOT}/swiftpm-scratch" \
    --disable-sandbox \
    --disable-dependency-cache \
    --filter IndexedMetadataStoreTests.testLargeIndexRemainsFastAndQueriesStayBounded
