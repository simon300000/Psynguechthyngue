#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

[[ "$#" -ge 2 && "$#" -le 3 ]] || {
    printf 'usage: %s IMAGE ARCH [static-bridge|no-dynamic-load]\n' "${0##*/}" >&2
    exit 64
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$1"
ARCH="$2"
MODE="${3:-static-bridge}"
DEFINED_SYMBOL_CHECK="${SCRIPT_DIR}/check-defined-symbol.sh"

command -v otool >/dev/null 2>&1 || {
    printf 'error: otool is required for Mobilebridge link-image validation\n' >&2
    exit 1
}
[[ -f "${DEFINED_SYMBOL_CHECK}" ]] || {
    printf 'error: defined-symbol validator is missing: %s\n' "${DEFINED_SYMBOL_CHECK}" >&2
    exit 1
}

case "${MODE}" in
    static-bridge)
        bash "${DEFINED_SYMBOL_CHECK}" "${IMAGE}" "${ARCH}" _MobilebridgeNewCore
        ;;
    no-dynamic-load)
        ;;
    *)
        printf 'error: unknown Mobilebridge link-image validation mode: %s\n' "${MODE}" >&2
        exit 64
        ;;
esac

linked_images="$(otool -arch "${ARCH}" -L "${IMAGE}")"
if printf '%s\n' "${linked_images}" | grep -F 'Mobilebridge.framework/' >/dev/null; then
    printf 'error: final image dynamically loads Mobilebridge.framework instead of containing the static bridge: %s\n' \
        "${IMAGE}" >&2
    exit 1
fi
printf '%s\n' "${linked_images}" | grep -F '/usr/lib/libresolv.9.dylib' >/dev/null || {
    if [[ "${MODE}" == "static-bridge" ]]; then
        printf 'error: libresolv is not linked into %s\n' "${IMAGE}" >&2
        exit 1
    fi
}
