#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/psy-bootstrap-no-reuse.XXXXXX")"

cleanup() {
    rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

mkdir -p "${FIXTURE_ROOT}/Scripts" "${FIXTURE_ROOT}/GoCore/Scripts" "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/Artifacts"
cp -- "${ROOT_DIR}/Scripts/bootstrap.sh" "${FIXTURE_ROOT}/Scripts/bootstrap.sh"
cp -- "${ROOT_DIR}/Scripts/hermetic-go-environment.sh" "${FIXTURE_ROOT}/Scripts/hermetic-go-environment.sh"
cp -- "${ROOT_DIR}/Scripts/resolve-go-toolchain.sh" "${FIXTURE_ROOT}/Scripts/resolve-go-toolchain.sh"

apply_fixture_file() {
    local relative_path="$1"
    local content="$2"

    printf '%s' "${content}" >"${FIXTURE_ROOT}/${relative_path}"
}

apply_fixture_file "GoCore/Scripts/xcframework-build-settings.sh" '#!/bin/sh
PSY_XCFRAMEWORK_DEFAULT_DEPLOYMENT_TARGET=17.0
'
apply_fixture_file "GoCore/Scripts/verify-syncthing-source.sh" '#!/bin/sh
set -eu
[ "${1:-}" = "--prepare" ] || exit 64
'
apply_fixture_file "GoCore/Scripts/xcframework-provenance.sh" '#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "verify" && "$#" -eq 4 ]] || exit 64
artifact="$2"
sidecar="$3"
[[ -d "${artifact}" && ! -L "${artifact}" && -f "${sidecar}" && ! -L "${sidecar}" ]] || exit 1
sentinel="$(<"${artifact}/sentinel")"
record="$(<"${sidecar}")"
if [[ "${record}" == "schemaVersion=2" ]]; then
    printf "error: provenance schema version mismatch (expected 3, found 2)\n" >&2
    exit 1
fi
expected="$(printf "schemaVersion=3\n%s" "${sentinel}")"
[[ -n "${sentinel}" && "${record}" == "${expected}" ]]
'
apply_fixture_file "GoCore/Scripts/build-xcframework.sh" '#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GOCACHEPROG:-}" ]] || exit 91
[[ "${GOFIPS140:-}" == "off" ]] || exit 92
[[ "${GODEBUG:-}" == "gocacheverify=1" ]] || exit 93
[[ -z "${CPATH:-}" && -z "${PKG_CONFIG_PATH:-}" ]] || exit 94
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"
output="$1"
count_file="${root_dir}/builder.count"
count=0
[[ ! -f "${count_file}" ]] || count="$(<"${count_file}")"
count=$((count + 1))
printf "%s\n" "${count}" >"${count_file}"
mkdir -- "${output}"
printf "build-%s\n" "${count}" >"${output}/sentinel"
printf "schemaVersion=3\nbuild-%s\n" "${count}" >"${output}.provenance.json"
'
apply_fixture_file "bin/xcodebuild" '#!/bin/sh
exit 0
'
chmod +x "${FIXTURE_ROOT}/bin/xcodebuild"
[[ ! -e "${FIXTURE_ROOT}/GoCore/Scripts/test-xcframework-provenance.sh" ]] || fail "fixture unexpectedly supplied the release-only tamper probe"
apply_fixture_file "bin/cacheprog" '#!/bin/sh
: >"${PSY_FAKE_GOCACHEPROG_MARKER:?}"
exit 99
'
chmod +x "${FIXTURE_ROOT}/bin/cacheprog"

artifact="${FIXTURE_ROOT}/Artifacts/Mobilebridge.xcframework"
sidecar="${artifact}.provenance.json"
mkdir -- "${artifact}"
printf 'schema-two-old\n' >"${artifact}/sentinel"
printf 'schemaVersion=2\n' >"${sidecar}"

schema_probe_log="${FIXTURE_ROOT}/schema-probe.log"
if bash "${FIXTURE_ROOT}/GoCore/Scripts/xcframework-provenance.sh" \
    verify "${artifact}" "${sidecar}" 17.0 >"${schema_probe_log}" 2>&1; then
    fail "schema-2 fixture unexpectedly passed the schema-3 verifier"
fi
grep -Fq 'expected 3, found 2' "${schema_probe_log}" || fail "schema-2 fixture did not exercise the stale-schema probe"

if PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    PSY_XCFRAMEWORK_CACHE_ROOT="${FIXTURE_ROOT}/hostile-cache" \
    bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" >/dev/null 2>&1; then
    fail "bootstrap accepted an inherited writable XCFramework cache"
fi
[[ ! -e "${FIXTURE_ROOT}/builder.count" ]] || fail "rejected cache injection reached the builder"

cacheprog_marker="${FIXTURE_ROOT}/cacheprog.executed"
bootstrap_log="${FIXTURE_ROOT}/bootstrap.log"
PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    GOCACHEPROG="${FIXTURE_ROOT}/bin/cacheprog" PSY_FAKE_GOCACHEPROG_MARKER="${cacheprog_marker}" \
    GOFIPS140=latest GODEBUG=gocacheverify=0 CPATH="${FIXTURE_ROOT}/hostile-include" \
    PKG_CONFIG_PATH="${FIXTURE_ROOT}/hostile-pkgconfig" \
    bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" >"${bootstrap_log}" 2>&1
[[ ! -e "${cacheprog_marker}" ]] || fail "bootstrap executed inherited GOCACHEPROG"
[[ "$(<"${FIXTURE_ROOT}/builder.count")" == "1" ]] || fail "stale schema-2 artifact skipped the builder"
[[ "$(<"${artifact}/sentinel")" == "build-1" ]] || fail "schema-2 rebuild published the historical artifact"
[[ "$(sed -n '1p' "${sidecar}")" == "schemaVersion=3" ]] || fail "schema-2 rebuild did not publish schema 3"
if grep -Fq 'expected 3, found 2' "${bootstrap_log}"; then
    fail "bootstrap surfaced the expected stale-schema probe as a rebuild error"
fi

reuse_log="${FIXTURE_ROOT}/reuse.log"
PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" --reuse-verified >"${reuse_log}" 2>&1
[[ "$(<"${FIXTURE_ROOT}/builder.count")" == "1" ]] || fail "verified Debug reuse called the builder"
[[ "$(<"${artifact}/sentinel")" == "build-1" ]] || fail "verified Debug reuse changed the artifact"
grep -Fq 'Reusing provenance-verified Mobilebridge XCFramework for Debug build.' "${reuse_log}" || \
    fail "verified Debug reuse did not report the fast path"

printf 'mismatched-record\n' >"${sidecar}"
PATH="${FIXTURE_ROOT}/bin:${PATH}" \
    bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" --reuse-verified >/dev/null 2>&1
[[ "$(<"${FIXTURE_ROOT}/builder.count")" == "2" ]] || fail "stale Debug reuse did not call the builder"
[[ "$(<"${artifact}/sentinel")" == "build-2" ]] || fail "stale Debug reuse did not publish a fresh artifact"

PATH="${FIXTURE_ROOT}/bin:${PATH}" PSY_BOOTSTRAP_FORCE_REBUILD=0 \
    bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" >/dev/null 2>&1
[[ "$(<"${FIXTURE_ROOT}/builder.count")" == "3" ]] || fail "ordinary bootstrap reused a coherent current artifact"
[[ "$(<"${artifact}/sentinel")" == "build-3" ]] || fail "ordinary bootstrap did not publish its fresh build"

backup_artifact="${FIXTURE_ROOT}/Artifacts/.Mobilebridge.xcframework.previous"
backup_sidecar="${FIXTURE_ROOT}/Artifacts/.Mobilebridge.xcframework.provenance.json.previous"
mkdir -- "${backup_artifact}"
printf 'recoverable-old\n' >"${backup_artifact}/sentinel"
printf 'schemaVersion=3\nrecoverable-old\n' >"${backup_sidecar}"
printf 'interrupted-current\n' >"${artifact}/sentinel"
printf 'mismatched-record\n' >"${sidecar}"

PATH="${FIXTURE_ROOT}/bin:${PATH}" bash "${FIXTURE_ROOT}/Scripts/bootstrap.sh" >/dev/null
[[ "$(<"${FIXTURE_ROOT}/builder.count")" == "4" ]] || fail "interrupted replacement recovery skipped the builder"
[[ "$(<"${artifact}/sentinel")" == "build-4" ]] || fail "interrupted recovery published a historical artifact"
[[ ! -e "${backup_artifact}" && ! -e "${backup_sidecar}" ]] || fail "bootstrap left interrupted replacement backups"

printf 'Bootstrap verified-reuse, fresh-build, schema-rebuild, and interrupted-recovery policy tests passed.\n'
