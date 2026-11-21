#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-go-toolchain.sh"
BUILD_USER_HOME_RESOLVER="${SCRIPT_DIR}/resolve-build-user-home.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/psy-go-resolver.XXXXXX")"

cleanup() {
    rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

resolve() {
    /usr/bin/env -i \
        PATH="${1}" TMPDIR=/tmp \
        "${@:2}" \
        /bin/sh -c 'set -e; . "$1"; printf "%s\t%s\t%s\n" "$PSY_GO_BINARY" "$PSY_GO_VERSION" "$PSY_GO_BINARY_SHA256"' \
        sh "${RESOLVER}"
}

resolve_build_user_home() {
    /usr/bin/env -i \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp \
        "$@" \
        /bin/sh -c 'set -e; . "$1"; printf "%s\n" "$PSY_BUILD_USER_HOME"' \
        sh "${BUILD_USER_HOME_RESOLVER}"
}

host_arch="$(/usr/bin/uname -m)"
case "${host_arch}" in
    arm64) homebrew_go=/opt/homebrew/bin/go ;;
    x86_64) homebrew_go=/usr/local/bin/go ;;
    *) fail "unsupported resolver-test host architecture: ${host_arch}" ;;
esac
[[ -f "${homebrew_go}" && -x "${homebrew_go}" ]] || fail "canonical Homebrew Go is unavailable for ${host_arch}"
real_go="$(/bin/realpath -- "${homebrew_go}")"
real_version="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp \
    GOENV=off GOTOOLCHAIN=local "${real_go}" env GOVERSION)"
real_hash="$(/usr/bin/shasum -a 256 "${real_go}" | /usr/bin/awk '{print $1}')"
system_user="$(/usr/bin/id -un)"
system_user_directory="$(/usr/bin/id -P "${system_user}" | /usr/bin/awk -F: 'NF == 10 { print $9 }')"
system_user_directory="$(/bin/realpath -- "${system_user_directory}")"

[[ "$(resolve_build_user_home)" == "${system_user_directory}" ]] || {
    fail "missing HOME was not restored from the system account record"
}
[[ "$(resolve_build_user_home "HOME=${system_user_directory}")" == "${system_user_directory}" ]] || {
    fail "the real inherited HOME was not preserved"
}
if resolve_build_user_home "HOME=${FIXTURE_ROOT}" >/dev/null 2>"${FIXTURE_ROOT}/hostile-home.err"; then
    fail "build HOME resolver accepted a non-account directory"
fi
grep -Fq 'does not match the system account record' "${FIXTURE_ROOT}/hostile-home.err" || {
    fail "hostile HOME rejection was not explicit"
}

xcode_path=/usr/bin:/bin:/usr/sbin:/sbin
resolved="$(resolve "${xcode_path}")"
[[ "${resolved}" == "${real_go}"$'\t'"${real_version}"$'\t'"${real_hash}" ]] || {
    fail "Xcode-like PATH did not fall back to the canonical Homebrew Go"
}

mkdir -p "${FIXTURE_ROOT}/path-bin" "${FIXTURE_ROOT}/explicit-bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "${real_go}" >"${FIXTURE_ROOT}/path-bin/go"
printf '#!/bin/sh\nexec "%s" "$@"\n' "${real_go}" >"${FIXTURE_ROOT}/explicit-bin/go-explicit"
chmod +x "${FIXTURE_ROOT}/path-bin/go" "${FIXTURE_ROOT}/explicit-bin/go-explicit"
path_go="$(/bin/realpath -- "${FIXTURE_ROOT}/path-bin/go")"
explicit_go="$(/bin/realpath -- "${FIXTURE_ROOT}/explicit-bin/go-explicit")"
path_go_hash="$(/usr/bin/shasum -a 256 "${path_go}" | /usr/bin/awk '{print $1}')"
explicit_go_hash="$(/usr/bin/shasum -a 256 "${explicit_go}" | /usr/bin/awk '{print $1}')"

resolved="$(resolve "${FIXTURE_ROOT}/path-bin:${xcode_path}")"
[[ "${resolved}" == "${path_go}"$'\t'"${real_version}"$'\t'"${path_go_hash}" ]] || {
    fail "resolver did not record the PATH-selected wrapper's own path, version response, and hash"
}

resolved="$(resolve "${FIXTURE_ROOT}/path-bin:${xcode_path}" "PSY_GO_BINARY=${explicit_go}")"
[[ "${resolved}" == "${explicit_go}"$'\t'"${real_version}"$'\t'"${explicit_go_hash}" ]] || {
    fail "PSY_GO_BINARY did not record the explicit wrapper's own path, version response, and hash"
}
resolved="$(resolve "${FIXTURE_ROOT}/path-bin:${xcode_path}" "GO=${explicit_go}")"
[[ "${resolved}" == "${explicit_go}"$'\t'"${real_version}"$'\t'"${explicit_go_hash}" ]] || {
    fail "GO did not record the explicit wrapper's own path, version response, and hash"
}

hostile_root="${FIXTURE_ROOT}/hostile-goroot"
mkdir -p "${hostile_root}"
resolved="$(resolve "${xcode_path}" \
    "GOROOT=${hostile_root}" "GOENV=${FIXTURE_ROOT}/hostile-goenv" \
    'GOTOOLCHAIN=auto' "GOCACHEPROG=${FIXTURE_ROOT}/hostile-cacheprog" \
    'CC=/tmp/hostile-cc' 'CXX=/tmp/hostile-cxx')"
[[ "${resolved%%$'\t'*}" == "${real_go}" ]] || fail "hostile Go/compiler environment influenced resolution"

old_go="${FIXTURE_ROOT}/old-go"
printf '%s\n' \
    '#!/bin/sh' \
    '[ "${1:-}" = env ] && [ "${2:-}" = GOVERSION ] || exit 90' \
    'printf "%s\\n" go1.24.9' >"${old_go}"
chmod +x "${old_go}"
if resolve "${xcode_path}" "PSY_GO_BINARY=${old_go}" >"${FIXTURE_ROOT}/old.out" 2>"${FIXTURE_ROOT}/old.err"; then
    fail "resolver accepted Go older than 1.25"
fi
grep -Fq 'found: go1.24.9' "${FIXTURE_ROOT}/old.err" || fail "old-version failure did not report the rejected version"

if resolve "${xcode_path}" 'PSY_GO_BINARY=relative/go' >/dev/null 2>"${FIXTURE_ROOT}/relative.err"; then
    fail "resolver accepted a relative explicit Go path"
fi
grep -Fq 'must be an absolute path' "${FIXTURE_ROOT}/relative.err" || fail "relative-path failure was not explicit"

if resolve "${xcode_path}" "PSY_GO_BINARY=${FIXTURE_ROOT}/missing-go" >/dev/null 2>"${FIXTURE_ROOT}/missing.err"; then
    fail "resolver accepted a missing explicit Go executable"
fi
grep -Fq 'found: unavailable' "${FIXTURE_ROOT}/missing.err" || fail "missing-Go failure did not report unavailable"

if resolve "${xcode_path}" "PSY_GO_BINARY=${FIXTURE_ROOT}" >/dev/null 2>"${FIXTURE_ROOT}/directory.err"; then
    fail "resolver accepted a directory as Go"
fi

if resolve "${xcode_path}" "PSY_GO_BINARY=${real_go}" \
    'PSY_GO_BINARY_SHA256=0000000000000000000000000000000000000000000000000000000000000000' \
    >/dev/null 2>"${FIXTURE_ROOT}/tamper.err"; then
    fail "resolver accepted a changed executable identity"
fi
grep -Fq 'changed after selection' "${FIXTURE_ROOT}/tamper.err" || fail "executable tamper failure was not explicit"

if /usr/bin/env -i PATH="${xcode_path}" TMPDIR=/tmp \
    /bin/sh -c '. "$1"; PSY_GO_BINARY=/tmp/replaced' sh "${RESOLVER}" >/dev/null 2>&1; then
    fail "resolved Go identity was mutable in the consumer shell"
fi

preflight_cache="${FIXTURE_ROOT}/preflight-go-cache"
preflight_gopath="${FIXTURE_ROOT}/preflight-go-path"
mkdir -p "${preflight_cache}" "${preflight_gopath}"
preflight_output="$(/usr/bin/env -i \
    PATH="${xcode_path}" TMPDIR=/tmp GOCACHE="${preflight_cache}" GOPATH="${preflight_gopath}" \
    /bin/bash "${ROOT_DIR}/Scripts/bootstrap.sh" --preflight)"
grep -Fq "${real_version}" <<<"${preflight_output}" || fail "bootstrap preflight omitted the resolved Go version"
grep -Fq "${real_go}" <<<"${preflight_output}" || fail "bootstrap preflight omitted the resolved Go path"

printf 'Go toolchain resolver and Xcode-like bootstrap preflight tests passed.\n'
