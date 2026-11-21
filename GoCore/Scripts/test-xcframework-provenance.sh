#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${CORE_DIR}/.." && pwd)"
. "${ROOT_DIR}/Scripts/hermetic-go-environment.sh"
PROVENANCE_TOOL="${SCRIPT_DIR}/xcframework-provenance.sh"
SOURCE_ONLY=false
if [[ "${1:-}" == "--source-only" ]]; then
    SOURCE_ONLY=true
    shift
fi
ARTIFACT="${1:-${ROOT_DIR}/Artifacts/Mobilebridge.xcframework}"
SIDECAR="${2:-${ARTIFACT}.provenance.json}"
DEPLOYMENT_TARGET="${3:-17.0}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

expect_verification_failure() {
    local description="$1"
    local candidate_sidecar="$2"
    local candidate_target="${3:-${DEPLOYMENT_TARGET}}"

    if bash "${PROVENANCE_TOOL}" verify "${ARTIFACT}" "${candidate_sidecar}" "${candidate_target}" >/dev/null 2>&1; then
        fail "provenance verification unexpectedly accepted ${description}"
    fi
}

expect_source_hash_failure() {
	local description="$1"
	local provenance_tool="$2"

	if bash "${provenance_tool}" source-hash >/dev/null 2>&1; then
		fail "source hashing unexpectedly accepted ${description}"
	fi
}

hash_one="$(bash "${PROVENANCE_TOOL}" source-hash)"
hash_two="$(bash "${PROVENANCE_TOOL}" source-hash)"
[[ "${hash_one}" == "${hash_two}" ]] || fail "source input hash is not deterministic"
printf '%s\n' "${hash_one}" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || fail "source input hash is malformed"

probe_dir="$(mktemp -d)"
cleanup() {
    rm -rf -- "${probe_dir}"
}
trap cleanup EXIT INT TERM

source_fixture="${probe_dir}/source-fixture"
fixture_core="${source_fixture}/GoCore"
fixture_tools="${source_fixture}/Tools"
fixture_generated="${source_fixture}/.build/go/syncthing-readiness-v1"
mkdir -p \
	"${fixture_core}/Patches" \
	"${fixture_core}/Scripts" \
	"${fixture_core}/Tools/preparelock" \
	"${fixture_tools}" \
	"${source_fixture}/Scripts" \
	"${source_fixture}/.build/go"
cp -- "${CORE_DIR}/go.mod" "${CORE_DIR}/go.sum" "${CORE_DIR}/SyncthingSource.lock.json" "${fixture_core}/"
cp -- "${CORE_DIR}/Patches/syncthing-cluster-index-readiness.patch" "${fixture_core}/Patches/"
for input in \
	build-xcframework.sh \
	build-xcframework-impl.sh \
		prepare-syncthing-source.sh \
		swift-smoke.swift \
		test-prepare-lock.sh \
	verify-syncthing-source.sh \
	xcframework-build-settings.sh \
	xcframework-provenance.sh; do
	cp -- "${CORE_DIR}/Scripts/${input}" "${fixture_core}/Scripts/${input}"
done
cp -R "${CORE_DIR}/mobilebridge" "${fixture_core}/mobilebridge"
cp -- \
	"${ROOT_DIR}/Tools/syncthing_contract.go" \
	"${ROOT_DIR}/Tools/syncthing_contract_check.go" \
	"${ROOT_DIR}/Tools/syncthing_contract_test.go" \
	"${fixture_tools}/"
cp -- "${CORE_DIR}"/Tools/preparelock/*.go "${fixture_core}/Tools/preparelock/"
	cp -- \
		"${ROOT_DIR}/Scripts/hermetic-go-environment.sh" \
		"${ROOT_DIR}/Scripts/resolve-build-user-home.sh" \
		"${ROOT_DIR}/Scripts/resolve-go-toolchain.sh" \
		"${ROOT_DIR}/Scripts/test-go-toolchain-resolver.sh" \
		"${ROOT_DIR}/Scripts/bootstrap.sh" \
		"${ROOT_DIR}/Scripts/test-bootstrap-no-reuse.sh" \
		"${source_fixture}/Scripts/"
cp -R "${ROOT_DIR}/.build/go/syncthing-readiness-v1" "${fixture_generated}"

fixture_provenance="${fixture_core}/Scripts/xcframework-provenance.sh"
fixture_hash="$(bash "${fixture_provenance}" source-hash)"
[[ "${fixture_hash}" == "${hash_one}" ]] || fail "relocated source fixture changed the path-free production source hash"

fixture_patch="${fixture_core}/Patches/syncthing-cluster-index-readiness.patch"
cp -- "${fixture_patch}" "${probe_dir}/original.patch"
printf '\nprovenance patch tamper\n' >>"${fixture_patch}"
expect_source_hash_failure "Syncthing patch tamper" "${fixture_provenance}"
mv -- "${probe_dir}/original.patch" "${fixture_patch}"

fixture_tree_file="${fixture_generated}/lib/model/model.go"
cp -- "${fixture_tree_file}" "${probe_dir}/original-model.go"
printf '\n// provenance generated-tree tamper\n' >>"${fixture_tree_file}"
expect_source_hash_failure "Syncthing generated-tree tamper" "${fixture_provenance}"
mv -- "${probe_dir}/original-model.go" "${fixture_tree_file}"

fixture_go_mod="${fixture_core}/go.mod"
cp -- "${fixture_go_mod}" "${probe_dir}/original.go.mod"
printf '\nreplace example.com/unaudited => ../unaudited\n' >>"${fixture_go_mod}"
expect_source_hash_failure "an additional local Go replacement" "${fixture_provenance}"
mv -- "${probe_dir}/original.go.mod" "${fixture_go_mod}"

fixture_prepare="${fixture_core}/Scripts/prepare-syncthing-source.sh"
cp -- "${fixture_prepare}" "${probe_dir}/original-prepare.sh"
printf '\n# provenance preparer input tamper\n' >>"${fixture_prepare}"
changed_fixture_hash="$(bash "${fixture_provenance}" source-hash)"
[[ "${changed_fixture_hash}" != "${fixture_hash}" ]] || fail "source hash ignored Syncthing preparer drift"
mv -- "${probe_dir}/original-prepare.sh" "${fixture_prepare}"

fixture_helper="${fixture_core}/Tools/preparelock/main_unix.go"
cp -- "${fixture_helper}" "${probe_dir}/original-main-unix.go"
printf '\n// provenance preparelock helper tamper\n' >>"${fixture_helper}"
changed_fixture_hash="$(bash "${fixture_provenance}" source-hash)"
[[ "${changed_fixture_hash}" != "${fixture_hash}" ]] || fail "source hash ignored preparelock helper drift"
mv -- "${probe_dir}/original-main-unix.go" "${fixture_helper}"

fixture_go_environment="${source_fixture}/Scripts/hermetic-go-environment.sh"
cp -- "${fixture_go_environment}" "${probe_dir}/original-hermetic-go-environment.sh"
printf '\n# provenance hermetic environment tamper\n' >>"${fixture_go_environment}"
changed_fixture_hash="$(bash "${fixture_provenance}" source-hash)"
[[ "${changed_fixture_hash}" != "${fixture_hash}" ]] || fail "source hash ignored hermetic Go environment drift"
	mv -- "${probe_dir}/original-hermetic-go-environment.sh" "${fixture_go_environment}"

	fixture_go_resolver="${source_fixture}/Scripts/resolve-go-toolchain.sh"
	cp -- "${fixture_go_resolver}" "${probe_dir}/original-resolve-go-toolchain.sh"
	printf '\n# provenance Go resolver tamper\n' >>"${fixture_go_resolver}"
	changed_fixture_hash="$(bash "${fixture_provenance}" source-hash)"
	[[ "${changed_fixture_hash}" != "${fixture_hash}" ]] || fail "source hash ignored Go resolver drift"
	mv -- "${probe_dir}/original-resolve-go-toolchain.sh" "${fixture_go_resolver}"

if [[ "${SOURCE_ONLY}" == true ]]; then
    printf 'XCFramework strict source-manifest determinism and tamper probes passed.\n'
    exit 0
fi

[[ -d "${ARTIFACT}" && -f "${SIDECAR}" ]] || fail "a built XCFramework and provenance sidecar are required"
command -v plutil >/dev/null 2>&1 || fail "plutil is required"
bash "${PROVENANCE_TOOL}" verify "${ARTIFACT}" "${SIDECAR}" "${DEPLOYMENT_TARGET}"
if grep -Fq -- "${ROOT_DIR}" "${SIDECAR}"; then
    fail "provenance sidecar leaks the repository absolute path"
fi

	source_tamper="${probe_dir}/source-tamper.json"
cp -- "${SIDECAR}" "${source_tamper}"
plutil -replace sourceSHA256 -string '0000000000000000000000000000000000000000000000000000000000000000' "${source_tamper}"
expect_verification_failure "a stale source hash" "${source_tamper}"

slice_tamper="${probe_dir}/slice-tamper.json"
cp -- "${SIDECAR}" "${slice_tamper}"
plutil -replace slices.ios-arm64.sha256 -string '0000000000000000000000000000000000000000000000000000000000000000' "${slice_tamper}"
expect_verification_failure "a mismatched device slice hash" "${slice_tamper}"

architecture_tamper="${probe_dir}/architecture-tamper.json"
cp -- "${SIDECAR}" "${architecture_tamper}"
plutil -replace slices.ios-arm64.architectures.0 -string 'x86_64' "${architecture_tamper}"
expect_verification_failure "a mismatched device architecture field" "${architecture_tamper}"

architecture_extra="${probe_dir}/architecture-extra.json"
cp -- "${SIDECAR}" "${architecture_extra}"
plutil -insert slices.ios-arm64.architectures.1 -string 'armv7' "${architecture_extra}"
expect_verification_failure "an extra device architecture field" "${architecture_extra}"

real_lipo="$(command -v lipo)"
fake_bin="${probe_dir}/fake-bin"
mkdir -- "${fake_bin}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$#" -eq 2 && "$1" == "-archs" && "$2" == *ios-arm64_x86_64-simulator* ]]; then' \
    '    printf "%s\\n" "arm64 x86_64 armv7"' \
    '    exit 0' \
    'fi' \
    'exec "${PSY_TEST_REAL_LIPO:?}" "$@"' >"${fake_bin}/lipo"
chmod +x "${fake_bin}/lipo"
if PATH="${fake_bin}:${PATH}" PSY_TEST_REAL_LIPO="${real_lipo}" \
    bash "${PROVENANCE_TOOL}" verify "${ARTIFACT}" "${SIDECAR}" "${DEPLOYMENT_TARGET}" >/dev/null 2>&1; then
    fail "provenance verification unexpectedly accepted an extra simulator binary architecture"
fi

tool_tamper="${probe_dir}/tool-tamper.json"
cp -- "${SIDECAR}" "${tool_tamper}"
	plutil -replace tools.goVersion -string 'go0.0.0' "${tool_tamper}"
	expect_verification_failure "a mismatched Go tool version" "${tool_tamper}"

	tool_path_tamper="${probe_dir}/tool-path-tamper.json"
	cp -- "${SIDECAR}" "${tool_path_tamper}"
	plutil -replace tools.goExecutablePath -string '/tmp/unrecorded-go' "${tool_path_tamper}"
	expect_verification_failure "a mismatched Go executable path" "${tool_path_tamper}"

	tool_hash_tamper="${probe_dir}/tool-hash-tamper.json"
	cp -- "${SIDECAR}" "${tool_hash_tamper}"
	plutil -replace tools.goExecutableSHA256 -string '0000000000000000000000000000000000000000000000000000000000000000' "${tool_hash_tamper}"
	expect_verification_failure "a mismatched Go executable SHA-256" "${tool_hash_tamper}"

expect_verification_failure "a mismatched deployment target" "${SIDECAR}" "99.0"
expect_verification_failure "a missing sidecar" "${probe_dir}/missing.json"

printf 'XCFramework provenance determinism and tamper probes passed.\n'
