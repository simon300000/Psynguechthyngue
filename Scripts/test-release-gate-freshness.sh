#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IOS_BUILD_SCRIPT="${ROOT_DIR}/Scripts/build-ios.sh"
UI_TEST_SCRIPT="${ROOT_DIR}/Scripts/test-ui.sh"
DEFINED_SYMBOL_CHECK="${ROOT_DIR}/Scripts/check-defined-symbol.sh"
LINK_IMAGE_CHECK="${ROOT_DIR}/Scripts/check-mobilebridge-link-image.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/psy-release-gate-freshness.XXXXXX")"

cleanup() {
    rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

grep -Fq 'mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX"' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS build gate does not allocate a fresh DerivedData run directory"
}
grep -Fq 'mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX"' "${UI_TEST_SCRIPT}" || {
    fail "iOS test gate does not allocate a fresh DerivedData run directory"
}
grep -Fq 'check-defined-symbol.sh' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS built-product gate does not use the defined-symbol checker"
}
grep -Fq 'check-mobilebridge-link-image.sh' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS built-product gate does not reject a dynamic Mobilebridge load"
}
grep -Fq 'app_launcher_image' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS built-product gate does not inspect the app launcher image"
}
grep -Fq 'provider_launcher_image' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS built-product gate does not inspect the File Provider launcher image"
}
grep -Fq 'no-dynamic-load' "${IOS_BUILD_SCRIPT}" || {
    fail "iOS built-product gate does not reject dynamic Mobilebridge loads from launchers"
}
grep -Fq -- '-resultBundlePath' "${UI_TEST_SCRIPT}" || {
    fail "iOS test actions do not persist unique xcresult bundles"
}
grep -Fq 'xcresulttool get test-results summary' "${UI_TEST_SCRIPT}" || {
    fail "iOS test actions do not machine-check xcresult summaries"
}
[[ -f "${DEFINED_SYMBOL_CHECK}" ]] || fail "defined-symbol checker is missing"
[[ -f "${LINK_IMAGE_CHECK}" ]] || fail "Mobilebridge link-image checker is missing"

mkdir -p "${FIXTURE_ROOT}/bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${PSY_FAKE_NM_MODE:?}" in' \
    '  undefined) printf '\''                 U _MobilebridgeNewCore\n'\'' ;;' \
    '  lowercase-undefined) printf '\''0000000000001000 u _MobilebridgeNewCore\n'\'' ;;' \
    '  indirect) printf '\''0000000000001000 I _MobilebridgeNewCore\n'\'' ;;' \
    '  common) printf '\''0000000000001000 C _MobilebridgeNewCore\n'\'' ;;' \
    '  weak) printf '\''0000000000001000 W _MobilebridgeNewCore\n'\'' ;;' \
    '  defined) printf '\''0000000000001000 T _MobilebridgeNewCore\n'\'' ;;' \
    '  unrelated) printf '\''0000000000001000 T _AnotherSymbol\n'\'' ;;' \
    '  *) exit 64 ;;' \
    'esac' >"${FIXTURE_ROOT}/bin/nm"
chmod +x "${FIXTURE_ROOT}/bin/nm"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${PSY_FAKE_OTOOL_MODE:?}" in' \
    '  static) printf '\''%s:\n\t/usr/lib/libresolv.9.dylib (compatibility version 1.0.0, current version 1.0.0)\n'\'' "${@: -1}" ;;' \
    '  launcher) printf '\''%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'\'' "${@: -1}" ;;' \
    '  dynamic) printf '\''%s:\n\t@rpath/Mobilebridge.framework/Mobilebridge (compatibility version 1.0.0, current version 1.0.0)\n\t/usr/lib/libresolv.9.dylib (compatibility version 1.0.0, current version 1.0.0)\n'\'' "${@: -1}" ;;' \
    '  noresolv) printf '\''%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'\'' "${@: -1}" ;;' \
    '  *) exit 64 ;;' \
    'esac' >"${FIXTURE_ROOT}/bin/otool"
chmod +x "${FIXTURE_ROOT}/bin/otool"

PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=defined \
    bash "${DEFINED_SYMBOL_CHECK}" /nonexistent/image arm64 _MobilebridgeNewCore
for rejected_nm_mode in undefined lowercase-undefined indirect common weak unrelated; do
    if PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE="${rejected_nm_mode}" \
        bash "${DEFINED_SYMBOL_CHECK}" /nonexistent/image arm64 _MobilebridgeNewCore >/dev/null 2>&1; then
        fail "Mobilebridge nm type ${rejected_nm_mode} passed the strong-text-definition gate"
    fi
done

PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=defined PSY_FAKE_OTOOL_MODE=static \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/image arm64 static-bridge
if PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=undefined PSY_FAKE_OTOOL_MODE=static \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/image arm64 static-bridge >/dev/null 2>&1; then
    fail "undefined Mobilebridge symbol passed the combined final-image gate"
fi
PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=unrelated PSY_FAKE_OTOOL_MODE=launcher \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/launcher arm64 no-dynamic-load
if PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=defined PSY_FAKE_OTOOL_MODE=dynamic \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/image arm64 static-bridge >/dev/null 2>&1; then
    fail "dynamic Mobilebridge framework load passed the final-image gate"
fi
if PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=unrelated PSY_FAKE_OTOOL_MODE=dynamic \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/launcher arm64 no-dynamic-load >/dev/null 2>&1; then
    fail "dynamic Mobilebridge framework load passed the launcher-image gate"
fi
if PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_FAKE_NM_MODE=defined PSY_FAKE_OTOOL_MODE=noresolv \
    bash "${LINK_IMAGE_CHECK}" /nonexistent/image arm64 static-bridge >/dev/null 2>&1; then
    fail "missing libresolv load passed the final-image gate"
fi

printf 'Fresh DerivedData plus defined, static Mobilebridge final-image gate tests passed.\n'
