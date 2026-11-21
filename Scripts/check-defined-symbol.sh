#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

[[ "$#" -eq 3 ]] || {
    printf 'usage: %s IMAGE ARCH SYMBOL\n' "${0##*/}" >&2
    exit 64
}

IMAGE="$1"
ARCH="$2"
SYMBOL="$3"

command -v nm >/dev/null 2>&1 || {
    printf 'error: nm is required for defined-symbol validation\n' >&2
    exit 1
}

if ! nm -arch "${ARCH}" "${IMAGE}" | awk -v expected_symbol="${SYMBOL}" '
    NF >= 2 && $NF == expected_symbol && $(NF - 1) == "T" { found = 1 }
    END { exit(found ? 0 : 1) }
'; then
    printf 'error: %s has no strong external text (T) definition for %s in %s\n' \
        "${SYMBOL}" "${ARCH}" "${IMAGE}" >&2
    exit 1
fi
