#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/hermetic-go-environment.sh"
GO_BUILD_CACHE="${PSY_PROJECT_CHECK_BUILD_CACHE:-${ROOT_DIR}/.build/check-project-go-cache}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "required file is missing: ${1#"${ROOT_DIR}/"}"
}

assert_contains() {
    local file="$1"
    local expected="$2"
    local description="$3"

    grep -Fq -- "${expected}" "${file}" || fail "${description}: expected '${expected}' in ${file#"${ROOT_DIR}/"}"
}

assert_not_contains() {
    local file="$1"
    local rejected="$2"
    local description="$3"

    if grep -Fq -- "${rejected}" "${file}"; then
        fail "${description}: rejected '${rejected}' in ${file#"${ROOT_DIR}/"}"
    fi
}

assert_plist_value() {
    local file="$1"
    local key_path="$2"
    local expected="$3"
    local description="$4"
    local actual

    actual="$(plutil -extract "${key_path}" raw -o - "${file}")" || fail "${description}: missing key path ${key_path}"
    [[ "${actual}" == "${expected}" ]] || fail "${description}: expected '${expected}', found '${actual}'"
}

require_command bash
require_command awk
require_command diff
require_command git
require_command go
require_command grep
require_command plutil
require_command ruby
require_command xmllint

PROJECT_FILE="${ROOT_DIR}/Psynguechthyngue.xcodeproj/project.pbxproj"
SCHEME_FILE="${ROOT_DIR}/Psynguechthyngue.xcodeproj/xcshareddata/xcschemes/Psynguechthyngue.xcscheme"
PHYSICAL_E2E_SCHEME_FILE="${ROOT_DIR}/Psynguechthyngue.xcodeproj/xcshareddata/xcschemes/PsynguechthynguePhysicalE2E.xcscheme"
PHYSICAL_E2E_TEST="${ROOT_DIR}/Tests/PsyCoreTests/PhysicalFileProviderE2ETests.swift"
PHYSICAL_FILES_UI_TEST="${ROOT_DIR}/Tests/PsynguechthyngueUITests/PhysicalFilesUIE2ETests.swift"
APP_INFO="${ROOT_DIR}/App/Info.plist"
PROVIDER_INFO="${ROOT_DIR}/FileProvider/Info.plist"
APP_ENTITLEMENTS="${ROOT_DIR}/App/Psynguechthyngue.entitlements"
PROVIDER_ENTITLEMENTS="${ROOT_DIR}/FileProvider/PsyFileProvider.entitlements"
BASE_CONFIG="${ROOT_DIR}/Config/Base.xcconfig"
CI_CONFIG="${ROOT_DIR}/Config/CI.xcconfig"
UI_TEST_CONFIG="${ROOT_DIR}/Config/UITests.xcconfig"
APP_PRIVACY_MANIFEST="${ROOT_DIR}/App/Resources/PrivacyInfo.xcprivacy"
PROVIDER_PRIVACY_MANIFEST="${ROOT_DIR}/FileProvider/Resources/PrivacyInfo.xcprivacy"
PROJECT_LICENSE="${ROOT_DIR}/LICENSE"
PROJECT_NOTICE="${ROOT_DIR}/NOTICE"
THIRD_PARTY_NOTICES="${ROOT_DIR}/THIRD_PARTY_NOTICES.md"
IOS_BUILD_SCRIPT="${ROOT_DIR}/Scripts/build-ios.sh"
UI_TEST_SCRIPT="${ROOT_DIR}/Scripts/test-ui.sh"
PHYSICAL_FILES_UI_SCRIPT="${ROOT_DIR}/Scripts/test-physical-files-ui.sh"
UI_TEST_POLICY_TEST="${ROOT_DIR}/Scripts/test-ui-gate-policy.sh"
RELEASE_GATE_FRESHNESS_TEST="${ROOT_DIR}/Scripts/test-release-gate-freshness.sh"
DEFINED_SYMBOL_CHECK="${ROOT_DIR}/Scripts/check-defined-symbol.sh"
LINK_IMAGE_CHECK="${ROOT_DIR}/Scripts/check-mobilebridge-link-image.sh"
APP_STORE_EXPORT_CHECK="${ROOT_DIR}/Scripts/verify-app-store-export.sh"
PROJECT_GENERATOR="${ROOT_DIR}/Scripts/generate-xcodeproj.rb"
PROJECT_MEMBERSHIP_CHECK="${ROOT_DIR}/Scripts/check-xcode-project-membership.rb"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/Scripts/bootstrap.sh"
XCFRAMEWORK_BUILD_SCRIPT="${ROOT_DIR}/GoCore/Scripts/build-xcframework.sh"
XCFRAMEWORK_BUILD_IMPL="${ROOT_DIR}/GoCore/Scripts/build-xcframework-impl.sh"
SOURCE_GATE_SCRIPT="${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
PREPARER_SCRIPT="${ROOT_DIR}/GoCore/Scripts/prepare-syncthing-source.sh"
HERMETIC_GO_ENVIRONMENT="${ROOT_DIR}/Scripts/hermetic-go-environment.sh"
BUILD_USER_HOME_RESOLVER="${ROOT_DIR}/Scripts/resolve-build-user-home.sh"
GO_TOOLCHAIN_RESOLVER="${ROOT_DIR}/Scripts/resolve-go-toolchain.sh"
GO_TOOLCHAIN_RESOLVER_TEST="${ROOT_DIR}/Scripts/test-go-toolchain-resolver.sh"

hermetic_go_consumers=(
	"${ROOT_DIR}/Scripts/bootstrap.sh"
	"${ROOT_DIR}/Scripts/check-licenses.sh"
	"${ROOT_DIR}/Scripts/check-project.sh"
	"${ROOT_DIR}/Scripts/generate-sbom.sh"
	"${ROOT_DIR}/Scripts/generate-third-party-notices.sh"
	"${ROOT_DIR}/Scripts/prepare-release-source.sh"
	"${ROOT_DIR}/Scripts/test-bootstrap-no-reuse.sh"
	"${ROOT_DIR}/Scripts/test-license-tools.sh"
	"${ROOT_DIR}/Scripts/verify-release-licenses.sh"
		"${ROOT_DIR}/Scripts/verify.sh"
		"${ROOT_DIR}/GoCore/Scripts/build-xcframework.sh"
		"${ROOT_DIR}/GoCore/Scripts/build-xcframework-impl.sh"
	"${ROOT_DIR}/GoCore/Scripts/prepare-syncthing-source.sh"
	"${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh"
	"${ROOT_DIR}/GoCore/Scripts/test-prepare-lock.sh"
	"${ROOT_DIR}/GoCore/Scripts/test-xcframework-provenance.sh"
	"${ROOT_DIR}/GoCore/Scripts/test.sh"
	"${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
	"${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh"
)

required_files=(
    "${ROOT_DIR}/Package.swift"
    "${PROJECT_FILE}"
    "${SCHEME_FILE}"
    "${PHYSICAL_E2E_SCHEME_FILE}"
    "${PHYSICAL_E2E_TEST}"
    "${PHYSICAL_FILES_UI_TEST}"
    "${APP_INFO}"
    "${PROVIDER_INFO}"
    "${APP_ENTITLEMENTS}"
    "${PROVIDER_ENTITLEMENTS}"
    "${BASE_CONFIG}"
    "${ROOT_DIR}/Config/Local.xcconfig.example"
    "${CI_CONFIG}"
    "${UI_TEST_CONFIG}"
    "${APP_PRIVACY_MANIFEST}"
    "${PROVIDER_PRIVACY_MANIFEST}"
    "${PROJECT_LICENSE}"
    "${PROJECT_NOTICE}"
    "${THIRD_PARTY_NOTICES}"
    "${ROOT_DIR}/Tests/PsynguechthyngueUITests/PsynguechthyngueUITests.swift"
    "${PHYSICAL_FILES_UI_SCRIPT}"
    "${ROOT_DIR}/Platform/GoCoreClient.swift"
	"${ROOT_DIR}/GoCore/go.mod"
	"${ROOT_DIR}/GoCore/go.sum"
	"${ROOT_DIR}/GoCore/SyncthingSource.lock.json"
	"${ROOT_DIR}/GoCore/Patches/syncthing-cluster-index-readiness.patch"
	"${ROOT_DIR}/GoCore/Scripts/prepare-syncthing-source.sh"
	"${ROOT_DIR}/GoCore/Scripts/test-prepare-lock.sh"
	"${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh"
	"${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh"
	"${ROOT_DIR}/GoCore/Scripts/build-xcframework.sh"
	"${ROOT_DIR}/GoCore/Scripts/build-xcframework-impl.sh"
	"${ROOT_DIR}/GoCore/Scripts/swift-smoke.swift"
	"${ROOT_DIR}/GoCore/Scripts/test-xcframework-provenance.sh"
	"${ROOT_DIR}/GoCore/Scripts/xcframework-build-settings.sh"
	"${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh"
	"${ROOT_DIR}/GoCore/Tools/preparelock/checkpoint_default.go"
	"${ROOT_DIR}/GoCore/Tools/preparelock/checkpoint_preparelocktest.go"
	"${ROOT_DIR}/GoCore/Tools/preparelock/main_other.go"
	"${ROOT_DIR}/GoCore/Tools/preparelock/main_unix.go"
	"${ROOT_DIR}/Tools/syncthing_contract.go"
	"${ROOT_DIR}/Tools/syncthing_contract_check.go"
	"${ROOT_DIR}/Tools/syncthing_contract_test.go"
	    "${ROOT_DIR}/Scripts/hermetic-go-environment.sh"
	    "${BUILD_USER_HOME_RESOLVER}"
	    "${GO_TOOLCHAIN_RESOLVER}"
	    "${GO_TOOLCHAIN_RESOLVER_TEST}"
    "${ROOT_DIR}/Scripts/bootstrap.sh"
	"${ROOT_DIR}/Scripts/test-bootstrap-no-reuse.sh"
    "${PROJECT_GENERATOR}"
    "${PROJECT_MEMBERSHIP_CHECK}"
    "${IOS_BUILD_SCRIPT}"
    "${UI_TEST_SCRIPT}"
    "${UI_TEST_POLICY_TEST}"
    "${RELEASE_GATE_FRESHNESS_TEST}"
    "${DEFINED_SYMBOL_CHECK}"
    "${LINK_IMAGE_CHECK}"
    "${APP_STORE_EXPORT_CHECK}"
)

for file in "${required_files[@]}"; do
    require_file "${file}"
done

for consumer in "${hermetic_go_consumers[@]}"; do
	assert_contains "${consumer}" 'hermetic-go-environment.sh' "official Go consumer hermetic environment wiring"
done

for script in "${SCRIPT_DIR}"/*.sh; do
	bash -n "${script}"
done
for script in "${ROOT_DIR}/GoCore/Scripts"/*.sh; do
	bash -n "${script}"
done
assert_not_contains "${APP_STORE_EXPORT_CHECK}" 'mapfile' "App Store export Bash 3.2 compatibility"
ruby -c "${PROJECT_GENERATOR}" >/dev/null
ruby -c "${PROJECT_MEMBERSHIP_CHECK}" >/dev/null
ruby "${PROJECT_MEMBERSHIP_CHECK}"
assert_contains "${PROJECT_FILE}" "LICENSE in Resources" "project license app resource membership"
assert_contains "${PROJECT_FILE}" "NOTICE in Resources" "project notice app resource membership"
assert_contains "${PROJECT_FILE}" "THIRD_PARTY_NOTICES.md in Resources" "third-party notices app resource membership"
assert_contains "${IOS_BUILD_SCRIPT}" 'assert_built_resource_matches "${ROOT_DIR}/LICENSE" "${app_product}/LICENSE"' "built project license equality gate"
assert_contains "${IOS_BUILD_SCRIPT}" 'assert_built_resource_matches "${ROOT_DIR}/NOTICE" "${app_product}/NOTICE"' "built project notice equality gate"
assert_contains "${IOS_BUILD_SCRIPT}" '"${app_product}/THIRD_PARTY_NOTICES.md"' "built third-party notices equality gate"
bash "${UI_TEST_POLICY_TEST}"
bash "${RELEASE_GATE_FRESHNESS_TEST}"
bash "${GO_TOOLCHAIN_RESOLVER_TEST}"
mkdir -p "${GO_BUILD_CACHE}"
GOCACHE="${GO_BUILD_CACHE}" sh "${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh" --prepare
hostile_cacheprog_dir="$(mktemp -d "${TMPDIR:-/tmp}/psy-source-gate-cacheprog.XXXXXX")"
hostile_cacheprog="${hostile_cacheprog_dir}/cacheprog"
hostile_cacheprog_marker="${hostile_cacheprog_dir}/executed"
cleanup_hostile_cacheprog() {
	rm -rf -- "${hostile_cacheprog_dir}"
}
trap cleanup_hostile_cacheprog EXIT INT TERM
printf '%s\n' \
	'#!/bin/sh' \
	': >"'"${hostile_cacheprog_marker}"'"' \
	'exit 99' >"${hostile_cacheprog}"
chmod +x "${hostile_cacheprog}"
GOCACHEPROG="${hostile_cacheprog}" PSY_FAKE_GOCACHEPROG_MARKER="${hostile_cacheprog_marker}" \
	GOFIPS140=latest GODEBUG=gocacheverify=0 CPATH="${hostile_cacheprog_dir}/include" \
	GOCACHE="${GO_BUILD_CACHE}" sh "${SOURCE_GATE_SCRIPT}" --preflight
[[ ! -e "${hostile_cacheprog_marker}" ]] || fail "canonical source gate executed inherited GOCACHEPROG"
private_gate_cache="${hostile_cacheprog_dir}/private-go-cache"
mkdir -p "${private_gate_cache}"
GOCACHE="${private_gate_cache}" sh "${SOURCE_GATE_SCRIPT}" --preflight
[[ -n "$(find "${private_gate_cache}" -type f -print -quit)" ]] || fail "canonical source gate discarded its caller-owned private GOCACHE"
resolved_private_gate_cache="$(GOCACHE="${private_gate_cache}" /bin/sh -c '. "$1"; go env GOCACHE' sh "${HERMETIC_GO_ENVIRONMENT}")"
[[ "${resolved_private_gate_cache}" == "${private_gate_cache}" ]] || fail "hermetic Go environment changed caller-owned private GOCACHE"

builder_env_fixture="${hostile_cacheprog_dir}/builder-fixture"
builder_env_marker="${builder_env_fixture}/source-gate.executed"
hostile_clang_cache="${builder_env_fixture}/hostile-clang-cache"
mkdir -p "${builder_env_fixture}/GoCore/Scripts" "${hostile_clang_cache}"
cp -- "${XCFRAMEWORK_BUILD_SCRIPT}" "${builder_env_fixture}/GoCore/Scripts/build-xcframework.sh"
cp -- "${XCFRAMEWORK_BUILD_IMPL}" "${builder_env_fixture}/GoCore/Scripts/build-xcframework-impl.sh"
cp -- "${ROOT_DIR}/GoCore/Scripts/xcframework-build-settings.sh" \
	"${builder_env_fixture}/GoCore/Scripts/xcframework-build-settings.sh"
mkdir -p "${builder_env_fixture}/Scripts"
cp -- "${ROOT_DIR}/Scripts/hermetic-go-environment.sh" \
	"${builder_env_fixture}/Scripts/hermetic-go-environment.sh"
cp -- "${BUILD_USER_HOME_RESOLVER}" \
	"${builder_env_fixture}/Scripts/resolve-build-user-home.sh"
cp -- "${GO_TOOLCHAIN_RESOLVER}" \
	"${builder_env_fixture}/Scripts/resolve-go-toolchain.sh"
printf '%s\n' \
		'#!/bin/sh' \
		'set -eu' \
		'[ "${1:-}" = "--prepare" ]' \
		'script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
		'fixture_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)' \
		'if [ -n "${PSY_GO_MODULE_PROXY_DIR:-}" ]; then' \
		'  expected_proxy=$(/bin/realpath -- "$fixture_root/local-module-proxy")' \
		'  [ "$PSY_GO_MODULE_PROXY_DIR" = "$expected_proxy" ]' \
		'  [ "${GOPROXY:-}" = "file://$expected_proxy" ]' \
		'  [ "${GOSUMDB:-}" = "sum.golang.org file://$expected_proxy/sumdb/sum.golang.org" ]' \
		'  : >"$fixture_root/module-proxy.executed"' \
		'  exit 43' \
		'fi' \
		'[ -z "${GOPROXY:-}" ]' \
		'[ -z "${GOSUMDB:-}" ]' \
		'account_name=$(/usr/bin/id -un)' \
		'account_directory=$(/usr/bin/id -P "$account_name" | /usr/bin/awk -F: '\''NF == 10 { print $9 }'\'')' \
		'[ "$(/bin/realpath -- "$HOME")" = "$(/bin/realpath -- "$account_directory")" ]' \
		'[ -z "${GOCACHEPROG:-}" ]' \
	'[ "${GOFIPS140:-}" = off ]' \
	'[ -z "${GODEBUG:-}" ]' \
	'[ -n "${CLANG_MODULE_CACHE_PATH:-}" ]' \
	'[ "${CLANG_MODULE_CACHE_PATH}" != "$fixture_root/hostile-clang-cache" ]' \
	'[ -d "${CLANG_MODULE_CACHE_PATH}" ]' \
	'[ -z "${SWIFT_MODULE_CACHE_PATH:-}" ]' \
	'[ -z "${MODULE_CACHE_DIR:-}" ]' \
	'[ -z "${CCACHE_DIR:-}" ]' \
	'[ -z "${SCCACHE_DIR:-}" ]' \
	'[ -z "${CPATH:-}" ]' \
	'[ -z "${PKG_CONFIG_PATH:-}" ]' \
	'[ -n "${PSY_GO_BINARY:-}" ]' \
		'[ -n "${PSY_GO_BINARY_SHA256:-}" ]' \
		'[ "${PATH}" = "${PSY_GO_TOOLCHAIN_DIR}:/usr/bin:/bin:/usr/sbin:/sbin" ]' \
		'tools_root=${GOMODCACHE%/go-cache/go-path/pkg/mod}' \
		'[ "$GOMODCACHE" = "$tools_root/go-cache/go-path/pkg/mod" ]' \
		'case "$XDG_CACHE_HOME:$XDG_CONFIG_HOME:$XDG_DATA_HOME:$XDG_STATE_HOME" in "$tools_root"/*:"$tools_root"/*:"$tools_root"/*:"$tools_root"/*) ;; *) exit 95 ;; esac' \
		'printf "%s\n" "$tools_root" >"$fixture_root/tools-root.path"' \
		'mkdir -p "$fixture_root/synthetic-module"' \
		'printf "module example.invalid/isolated-builder\n\ngo 1.25\n" >"$fixture_root/synthetic-module/go.mod"' \
		'printf "package isolatedbuilder\n\nfunc Stable() bool { return true }\n" >"$fixture_root/synthetic-module/stable.go"' \
		'(cd "$fixture_root/synthetic-module" && go test -count=1 ./...)' \
		'mkdir -p "$GOMODCACHE/example.invalid/read-only"' \
		': >"$GOMODCACHE/example.invalid/read-only/module.txt"' \
		'chmod 0444 "$GOMODCACHE/example.invalid/read-only/module.txt"' \
		'chmod 0555 "$GOMODCACHE/example.invalid/read-only" "$GOMODCACHE/example.invalid" "$GOMODCACHE"' \
		': >"$fixture_root/source-gate.executed"' \
		'exit 42' >"${builder_env_fixture}/GoCore/Scripts/verify-syncthing-source.sh"
chmod +x "${builder_env_fixture}/GoCore/Scripts/verify-syncthing-source.sh"
builder_probe_tmp="${builder_env_fixture}/xcode-tmp"
builder_probe_log="${builder_env_fixture}/builder-probe.log"
mkdir -p "${builder_probe_tmp}"
if /usr/bin/env -i \
		PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${builder_probe_tmp}" \
		GOCACHEPROG="${hostile_cacheprog}" GOFIPS140=latest GODEBUG=gocacheverify=0 \
		CLANG_MODULE_CACHE_PATH="${hostile_clang_cache}" \
		SWIFT_MODULE_CACHE_PATH="${hostile_clang_cache}" MODULE_CACHE_DIR="${hostile_clang_cache}" \
		CCACHE_DIR="${hostile_clang_cache}" SCCACHE_DIR="${hostile_clang_cache}" \
		CPATH="${hostile_clang_cache}" PKG_CONFIG_PATH="${hostile_clang_cache}" \
		/bin/sh "${builder_env_fixture}/GoCore/Scripts/build-xcframework.sh" \
		"${builder_env_fixture}/Artifacts/Mobilebridge.xcframework" >"${builder_probe_log}" 2>&1; then
	fail "builder environment probe unexpectedly completed a production build"
fi
if [[ ! -e "${builder_env_marker}" ]]; then
	cat "${builder_probe_log}" >&2
	fail "XCFramework builder did not isolate hostile cache/compiler environment"
fi
[[ ! -e "${hostile_cacheprog_marker}" ]] || fail "XCFramework builder executed inherited GOCACHEPROG"
builder_tools_root="$(<"${builder_env_fixture}/tools-root.path")"
[[ ! -e "${builder_tools_root}" && ! -L "${builder_tools_root}" ]] || fail "XCFramework builder leaked its read-only private module cache"
if grep -Fq 'Permission denied' "${builder_probe_log}"; then
	fail "XCFramework builder cleanup emitted a module-cache permission error"
fi
rm -f -- "${builder_env_marker}" "${builder_env_fixture}/tools-root.path"

local_module_proxy="${builder_env_fixture}/local-module-proxy"
module_proxy_marker="${builder_env_fixture}/module-proxy.executed"
module_proxy_log="${builder_env_fixture}/module-proxy.log"
mkdir -p \
	"${local_module_proxy}/sumdb/sum.golang.org/lookup" \
	"${local_module_proxy}/sumdb/sum.golang.org/tile"
local_module_proxy="$(cd "${local_module_proxy}" && pwd -P)"
if PSY_GO_MODULE_PROXY_DIR="${local_module_proxy}" \
	/bin/sh "${builder_env_fixture}/GoCore/Scripts/build-xcframework.sh" \
	"${builder_env_fixture}/Artifacts/Mobilebridge.xcframework" >"${module_proxy_log}" 2>&1; then
	fail "local-module-proxy builder probe unexpectedly completed a production build"
fi
[[ -e "${module_proxy_marker}" ]] || {
	cat "${module_proxy_log}" >&2
	fail "XCFramework builder did not pass the validated local module proxy into its clean environment"
}
rm -f -- "${module_proxy_marker}"
ln -s -- "${local_module_proxy}" "${builder_env_fixture}/symlinked-module-proxy"
if PSY_GO_MODULE_PROXY_DIR="${builder_env_fixture}/symlinked-module-proxy" \
	/bin/sh "${builder_env_fixture}/GoCore/Scripts/build-xcframework.sh" \
	"${builder_env_fixture}/Artifacts/Mobilebridge.xcframework" >"${module_proxy_log}" 2>&1; then
	fail "XCFramework builder accepted a symlinked local module proxy"
fi
[[ ! -e "${module_proxy_marker}" ]] || fail "unsafe local module proxy reached the internal builder"
grep -Fq 'PSY_GO_MODULE_PROXY_DIR must be an absolute canonical non-symlink directory' \
	"${module_proxy_log}" || fail "unsafe local module proxy rejection was not explicit"

hostile_home_log="${builder_env_fixture}/hostile-home.log"
if /usr/bin/env -i \
		PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${builder_env_fixture}" TMPDIR="${builder_probe_tmp}" \
		/bin/sh "${builder_env_fixture}/GoCore/Scripts/build-xcframework.sh" \
		"${builder_env_fixture}/Artifacts/Mobilebridge.xcframework" >"${hostile_home_log}" 2>&1; then
	fail "XCFramework builder accepted HOME outside the system account record"
fi
[[ ! -e "${builder_env_marker}" ]] || fail "hostile HOME reached the internal XCFramework builder"
grep -Fq 'inherited HOME does not match the system account record' "${hostile_home_log}" || fail "hostile HOME rejection was not explicit"
GOCACHE="${GO_BUILD_CACHE}" \
	bash "${ROOT_DIR}/GoCore/Scripts/test-xcframework-provenance.sh" --source-only
CGO_ENABLED=0 GOOS=plan9 GOARCH=386 GO111MODULE=off GOFLAGS=-mod=vendor \
	GOWORK="${ROOT_DIR}/.build/hostile-source-gate.work" GOCACHE="${GO_BUILD_CACHE}" \
	sh "${ROOT_DIR}/GoCore/Scripts/verify-syncthing-source.sh" --prepare
GOCACHE="${GO_BUILD_CACHE}" GO111MODULE=off GOENV=off GOFLAGS= GOWORK=off go test \
	"${ROOT_DIR}/Tools/syncthing_contract.go" \
	"${ROOT_DIR}/Tools/syncthing_contract_test.go"
bash "${ROOT_DIR}/Scripts/test-bootstrap-no-reuse.sh"

plutil -lint \
    "${PROJECT_FILE}" \
    "${APP_INFO}" \
    "${PROVIDER_INFO}" \
    "${APP_ENTITLEMENTS}" \
    "${PROVIDER_ENTITLEMENTS}" \
    "${APP_PRIVACY_MANIFEST}" \
    "${PROVIDER_PRIVACY_MANIFEST}" >/dev/null
xmllint --noout "${SCHEME_FILE}"
grep -Fq 'key = "PSY_XCTEST_PERMISSIVE_ENVIRONMENT"' "${SCHEME_FILE}" \
	|| fail "shared TestAction must opt into deterministic XCTest environment capture"
grep -Fq 'shouldUseLaunchSchemeArgsEnv = "NO"' "${SCHEME_FILE}" \
	|| fail "shared TestAction must use its own deterministic environment"
grep -Fq 'value = "1"' "${SCHEME_FILE}" \
	|| fail "deterministic XCTest environment capture must use value 1"
grep -Fq 'isEnabled = "YES"' "${SCHEME_FILE}" \
	|| fail "deterministic XCTest environment capture must be enabled"

assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyTracking" "false" "app privacy tracking declaration"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryFileTimestamp" "app file timestamp API declaration"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0" "C617.1" "app App Group timestamp reason"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.1" "3B52.1" "app user-selected timestamp reason"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryDiskSpace" "app disk-space API declaration"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0" "E174.1" "app disk-space reason"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategorySystemBootTime" "app system boot-time API declaration"
assert_plist_value "${APP_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPITypeReasons.0" "35F9.1" "app system boot-time reason"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyTracking" "false" "extension privacy tracking declaration"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryFileTimestamp" "extension file timestamp API declaration"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0" "C617.1" "extension App Group timestamp reason"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryDiskSpace" "extension disk-space API declaration"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0" "E174.1" "extension disk-space reason"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategorySystemBootTime" "extension system boot-time API declaration"
assert_plist_value "${PROVIDER_PRIVACY_MANIFEST}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPITypeReasons.0" "35F9.1" "extension system boot-time reason"

assert_plist_value "${APP_INFO}" "CFBundlePackageType" "APPL" "app bundle type"
assert_plist_value "${APP_INFO}" "CFBundleShortVersionString" "1.0.0" "app marketing version"
assert_plist_value "${APP_INFO}" "CFBundleVersion" "1" "app build version"
assert_plist_value "${APP_INFO}" "PsyAppGroupIdentifier" '$(APP_GROUP_IDENTIFIER)' "app group indirection"
assert_plist_value "${APP_INFO}" "PsyKeychainAccessGroup" '$(KEYCHAIN_ACCESS_GROUP)' "app Keychain group indirection"
assert_plist_value "${PROVIDER_INFO}" "CFBundlePackageType" "XPC!" "extension bundle type"
assert_plist_value "${PROVIDER_INFO}" "CFBundleShortVersionString" "1.0.0" "extension marketing version"
assert_plist_value "${PROVIDER_INFO}" "CFBundleVersion" "1" "extension build version"
assert_plist_value "${PROVIDER_INFO}" "PsyAppGroupIdentifier" '$(APP_GROUP_IDENTIFIER)' "extension app group indirection"
assert_plist_value "${PROVIDER_INFO}" "PsyKeychainAccessGroup" '$(KEYCHAIN_ACCESS_GROUP)' "extension Keychain group indirection"
assert_plist_value "${PROVIDER_INFO}" "NSExtension.NSExtensionPointIdentifier" "com.apple.fileprovider-nonui" "File Provider extension point"
assert_plist_value "${PROVIDER_INFO}" "NSExtension.NSExtensionPrincipalClass" '$(PRODUCT_MODULE_NAME).FileProviderExtension' "File Provider principal class"
assert_plist_value "${PROVIDER_INFO}" "NSExtension.NSExtensionFileProviderDocumentGroup" '$(APP_GROUP_IDENTIFIER)' "File Provider document group"
assert_plist_value "${PROVIDER_INFO}" "NSExtension.NSExtensionFileProviderSupportsEnumeration" "true" "File Provider enumeration declaration"
assert_plist_value "${PROVIDER_INFO}" "NSExtensionFileProviderDownloadPipelineDepth" "1" "download pipeline depth"
assert_plist_value "${PROVIDER_INFO}" "NSExtensionFileProviderUploadPipelineDepth" "1" "upload pipeline depth"
assert_not_contains "${PROVIDER_INFO}" "NSExtensionFileProviderAppliesChangesAtomically" "atomic-change declaration requires a real atomic implementation"

APP_GROUP_KEY_PATH='com\.apple\.security\.application-groups.0'
assert_plist_value "${APP_ENTITLEMENTS}" "${APP_GROUP_KEY_PATH}" '$(APP_GROUP_IDENTIFIER)' "app App Group entitlement"
assert_plist_value "${PROVIDER_ENTITLEMENTS}" "${APP_GROUP_KEY_PATH}" '$(APP_GROUP_IDENTIFIER)' "extension App Group entitlement"
assert_plist_value "${APP_ENTITLEMENTS}" "keychain-access-groups.0" '$(KEYCHAIN_ACCESS_GROUP)' "app shared Keychain entitlement"
assert_plist_value "${PROVIDER_ENTITLEMENTS}" "keychain-access-groups.0" '$(KEYCHAIN_ACCESS_GROUP)' "extension shared Keychain entitlement"
assert_not_contains "${APP_ENTITLEMENTS}" "com.apple.developer.fileprovider.testing-mode" "production app entitlements"
assert_not_contains "${PROVIDER_ENTITLEMENTS}" "com.apple.developer.fileprovider.testing-mode" "production extension entitlements"

assert_contains "${BASE_CONFIG}" 'IPHONEOS_DEPLOYMENT_TARGET = 17.0' "deployment target"
assert_contains "${BASE_CONFIG}" 'SWIFT_VERSION = 6.0' "Swift language version"
assert_contains "${BASE_CONFIG}" 'SWIFT_STRICT_CONCURRENCY = complete' "strict concurrency"
assert_contains "${BASE_CONFIG}" 'ENABLE_USER_SCRIPT_SANDBOXING = NO' "audited Mobilebridge aggregate source builder"
assert_contains "${BASE_CONFIG}" 'KEYCHAIN_ACCESS_GROUP = $(AppIdentifierPrefix)$(APP_BUNDLE_IDENTIFIER)' "shared Keychain access group"
assert_contains "${BASE_CONFIG}" '#include? "Local.xcconfig"' "optional local configuration"

assert_contains "${CI_CONFIG}" '#include "Base.xcconfig"' "CI base configuration"
assert_contains "${CI_CONFIG}" 'APP_BUNDLE_IDENTIFIER = com.example.Psynguechthyngue.CI' "CI app identifier"
assert_contains "${CI_CONFIG}" 'FILE_PROVIDER_BUNDLE_IDENTIFIER = com.example.Psynguechthyngue.CI.FileProvider' "CI extension identifier"
assert_contains "${CI_CONFIG}" 'APP_GROUP_IDENTIFIER = group.com.example.Psynguechthyngue.CI' "CI App Group identifier"
assert_contains "${CI_CONFIG}" 'CODE_SIGNING_ALLOWED = NO' "unsigned CI build"

assert_contains "${UI_TEST_CONFIG}" '#include "Base.xcconfig"' "UI-test base configuration"
assert_contains "${UI_TEST_CONFIG}" 'APP_BUNDLE_IDENTIFIER = com.example.Psynguechthyngue.UITesting' "UI-test app identifier"
assert_contains "${UI_TEST_CONFIG}" 'CODE_SIGNING_ALLOWED = YES' "ad-hoc signed UI-test build"

assert_contains "${PROJECT_FILE}" 'objectVersion = 56;' "stable project object version"
assert_contains "${PROJECT_FILE}" 'productType = "com.apple.product-type.application";' "application target"
assert_contains "${PROJECT_FILE}" 'productType = "com.apple.product-type.app-extension";' "File Provider target"
assert_contains "${PROJECT_FILE}" 'productType = "com.apple.product-type.bundle.unit-test";' "unit-test target"
assert_contains "${PROJECT_FILE}" 'productType = "com.apple.product-type.bundle.ui-testing";' "UI-test target"
assert_contains "${PROJECT_FILE}" 'isa = XCLocalSwiftPackageReference;' "local Swift package reference"
assert_contains "${PROJECT_FILE}" 'productName = PsyCore;' "PsyCore package product"
assert_contains "${PROJECT_FILE}" 'name = "Embed App Extensions";' "app extension embed phase"
assert_contains "${PROJECT_FILE}" 'dstSubfolderSpec = 13;' "PlugIns embed destination"
assert_contains "${PROJECT_FILE}" 'CodeSignOnCopy' "embedded extension signing attribute"
assert_contains "${PROJECT_FILE}" 'APPLICATION_EXTENSION_API_ONLY = YES;' "extension-safe API setting"
assert_contains "${PROJECT_FILE}" 'SKIP_INSTALL = YES;' "extension install setting"
assert_contains "${PROJECT_FILE}" 'PRODUCT_BUNDLE_IDENTIFIER = "$(APP_BUNDLE_IDENTIFIER)";' "app bundle setting"
assert_contains "${PROJECT_FILE}" 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES;' "Designed-for-iPad Mac support setting"
assert_contains "${PROJECT_FILE}" 'PRODUCT_BUNDLE_IDENTIFIER = "$(FILE_PROVIDER_BUNDLE_IDENTIFIER)";' "extension bundle setting"
assert_not_contains "${PROJECT_FILE}" 'Mobilebridge.xcframework in Frameworks' "planning-time XCFramework file reference"
device_framework_search_count="$(grep -Fc '"FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]"' "${PROJECT_FILE}")"
simulator_framework_search_count="$(grep -Fc '"FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]"' "${PROJECT_FILE}")"
mobilebridge_link_flag_count="$(grep -Fc $'\t\t\t\t\tMobilebridge,' "${PROJECT_FILE}")"
[[ "${device_framework_search_count}" -eq 6 ]] || fail "app, extension, and hosted tests Debug/Release settings must select the Mobilebridge device slice"
[[ "${simulator_framework_search_count}" -eq 6 ]] || fail "app, extension, and hosted tests Debug/Release settings must select the Mobilebridge simulator slice"
[[ "${mobilebridge_link_flag_count}" -eq 4 ]] || fail "app and extension Debug/Release settings must link Mobilebridge explicitly"
assert_contains "${PROJECT_FILE}" 'GoCoreClient.swift in Sources' "Swift bridge adapter target membership"
privacy_resource_count="$(grep -Fc 'PrivacyInfo.xcprivacy in Resources' "${PROJECT_FILE}")"
[[ "${privacy_resource_count}" -ge 4 ]] || fail "app and extension privacy manifests must both be project resources"
assert_contains "${PROJECT_FILE}" 'TEST_TARGET_NAME = Psynguechthyngue;' "UI-test application target"
assert_contains "${PROJECT_FILE}" 'BUNDLE_LOADER = "$(TEST_HOST)";' "device-capable hosted unit-test bundle loader"
assert_contains "${PROJECT_FILE}" 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Psynguechthyngue.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Psynguechthyngue";' "device-capable unit-test host application"

assert_contains "${SCHEME_FILE}" 'BlueprintName = "Psynguechthyngue"' "shared app scheme"
assert_contains "${SCHEME_FILE}" 'BlueprintName = "PsyFileProvider"' "shared extension build entry"
assert_contains "${SCHEME_FILE}" 'BlueprintName = "PsynguechthyngueTests"' "shared test entry"
assert_contains "${SCHEME_FILE}" 'BlueprintName = "PsynguechthyngueUITests"' "shared UI-test entry"
assert_contains "${SCHEME_FILE}" 'Identifier = "PhysicalFileProviderE2ETests"' "ordinary suite excludes the physical E2E class"
assert_contains "${SCHEME_FILE}" 'Identifier = "PhysicalFilesUIE2ETests"' "ordinary suite excludes the physical Files UI class"
assert_contains "${SCHEME_FILE}" '<SkippedTests>' "ordinary suite physical E2E exclusion"
assert_contains "${SCHEME_FILE}" 'ReferencedContainer = "container:Psynguechthyngue.xcodeproj"' "shared scheme container"
assert_not_contains "${SCHEME_FILE}" 'regenerated.xcodeproj' "shared scheme must not retain a temporary project name"
assert_not_contains "${SCHEME_FILE}" '<PreActions>' "shared scheme duplicate bootstrap pre-action"
assert_contains "${PHYSICAL_E2E_SCHEME_FILE}" '<SelectedTests>' "physical E2E explicit selection"
assert_contains "${PHYSICAL_E2E_SCHEME_FILE}" 'PhysicalFileProviderE2ETests' "physical E2E class selection"
assert_contains "${PHYSICAL_E2E_SCHEME_FILE}" 'BlueprintName = "PsynguechthyngueUITests"' "physical Files UI testable entry"
assert_contains "${PHYSICAL_E2E_TEST}" 'testReportPhysicalPeerIdentityAndLANAddress' "physical peer discovery entry"
assert_contains "${PHYSICAL_E2E_TEST}" 'testConfigureTemporaryPeerAndShare' "physical temporary share setup"
assert_contains "${PHYSICAL_E2E_TEST}" 'testWaitForFilesUIRenamedDirectory' "physical Files UI peer projection proof"
assert_contains "${PHYSICAL_E2E_TEST}" 'testWaitForFilesUIDeletionAndCleanup' "physical Files UI deletion cleanup proof"
assert_contains "${PHYSICAL_FILES_UI_TEST}" 'XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")' "system Files app launch"
assert_contains "${PHYSICAL_FILES_UI_TEST}" 'testCreateAndRenameDirectoryInFiles' "system Files create/rename phase"
assert_contains "${PHYSICAL_FILES_UI_TEST}" 'testDeleteRenamedDirectoryInFiles' "system Files delete phase"
assert_contains "${ROOT_DIR}/Makefile" 'physical-files-ui-test:' "physical Files UI make entry"
assert_contains "${ROOT_DIR}/Makefile" 'bash Scripts/test-physical-files-ui.sh' "physical Files UI script routing"
assert_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'IPHONE_NAME="t"' "physical iPhone scope"
assert_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'IPAD_NAME="Simon的iPad"' "physical iPad scope"
assert_not_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'iPhone 17 Pro' "forbidden physical device target"
assert_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'trap cleanup_configuration EXIT INT TERM' "physical E2E failure cleanup"
assert_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'testCreateAndRenameDirectoryInFiles' "physical Files UI create phase routing"
assert_contains "${PHYSICAL_FILES_UI_SCRIPT}" 'testDeleteRenamedDirectoryInFiles' "physical Files UI delete phase routing"
assert_contains "${PROJECT_FILE}" 'isa = PBXAggregateTarget;' "Mobilebridge aggregate build target"
assert_contains "${PROJECT_FILE}" 'name = MobilebridgeBootstrap;' "Mobilebridge aggregate target name"
assert_contains "${PROJECT_FILE}" 'name = "Build current Mobilebridge source";' "Mobilebridge aggregate build phase"
assert_contains "${PROJECT_FILE}" 'alwaysOutOfDate = 1;' "Mobilebridge always-runs provenance gate"
assert_contains "${PROJECT_FILE}" '"$(SRCROOT)/Artifacts/Mobilebridge.xcframework"' "Mobilebridge declared artifact output"
assert_contains "${PROJECT_FILE}" '"$(SRCROOT)/Artifacts/Mobilebridge.xcframework.provenance.json"' "Mobilebridge declared provenance output"
assert_contains "${PROJECT_FILE}" '--reuse-verified' "Mobilebridge Debug verified-reuse command"
assert_contains "${PROJECT_FILE}" 'exec /bin/bash \"${SRCROOT}/Scripts/bootstrap.sh\"' "Mobilebridge Release fresh-build command"
assert_not_contains "${PROJECT_FILE}" 'PSY_XCFRAMEWORK_CACHE_ROOT' "Mobilebridge aggregate writable persistent cache injection"
assert_contains "${PROJECT_FILE}" 'showEnvVarsInLog = 0;' "Mobilebridge build environment redaction"
bootstrap_sandbox_override_count="$(grep -Fc 'ENABLE_USER_SCRIPT_SANDBOXING = NO;' "${PROJECT_FILE}")"
[[ "${bootstrap_sandbox_override_count}" -eq 2 ]] || fail "Mobilebridge aggregate Debug/Release configurations must permit the audited source build"
bootstrap_target_uuid="$(
    awk '
        /Begin PBXAggregateTarget section/ { in_aggregate_targets = 1; next }
        /End PBXAggregateTarget section/ { in_aggregate_targets = 0 }
        in_aggregate_targets && /\/\* MobilebridgeBootstrap \*\// { print $1; exit }
    ' "${PROJECT_FILE}"
)"
[[ "${bootstrap_target_uuid}" =~ ^[0-9A-F]{24}$ ]] || fail "Mobilebridge aggregate target UUID is missing or malformed"
bootstrap_dependency_count="$(grep -Fc "target = ${bootstrap_target_uuid} /* MobilebridgeBootstrap */;" "${PROJECT_FILE}")"
[[ "${bootstrap_dependency_count}" -eq 2 ]] || fail "app and extension must both depend on the Mobilebridge aggregate target"
app_target_uuid="$(
    awk '
        /Begin PBXNativeTarget section/ { in_native_targets = 1; next }
        /End PBXNativeTarget section/ { in_native_targets = 0 }
        in_native_targets && /\/\* Psynguechthyngue \*\// { print $1; exit }
    ' "${PROJECT_FILE}"
)"
[[ "${app_target_uuid}" =~ ^[0-9A-F]{24}$ ]] || fail "app target UUID is missing or malformed"
hosted_test_dependency_count="$(grep -Fc "target = ${app_target_uuid} /* Psynguechthyngue */;" "${PROJECT_FILE}")"
[[ "${hosted_test_dependency_count}" -eq 2 ]] || fail "unit and UI test targets must both depend on the app target"
assert_contains "${PROJECT_GENERATOR}" 'project.new_aggregate_target("MobilebridgeBootstrap")' "project generator Mobilebridge aggregate target"
assert_contains "${PROJECT_GENERATOR}" 'tests.add_dependency(app)' "project generator hosted unit-test dependency"
assert_not_contains "${PROJECT_GENERATOR}" 'artifacts_group.new_file("Mobilebridge.xcframework")' "project generator planning-time XCFramework reference"
assert_contains "${PROJECT_GENERATOR}" '"FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]"' "project generator Mobilebridge device search path"
assert_contains "${PROJECT_GENERATOR}" '"FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]"' "project generator Mobilebridge simulator search path"
assert_contains "${PROJECT_GENERATOR}" 'bootstrap_phase.always_out_of_date = "1"' "project generator always-runs provenance gate"
assert_contains "${PROJECT_GENERATOR}" '--reuse-verified' "project generator Debug verified-reuse command"
assert_not_contains "${PROJECT_GENERATOR}" 'PSY_XCFRAMEWORK_CACHE_ROOT' "project generator writable persistent cache injection"
assert_contains "${BOOTSTRAP_SCRIPT}" 'PSY_XCFRAMEWORK_CACHE_ROOT is unsupported; bootstrap requires an isolated cache' "bootstrap hostile cache rejection"
assert_contains "${BOOTSTRAP_SCRIPT}" '--reuse-verified' "bootstrap verified Debug reuse mode"
assert_contains "${BOOTSTRAP_SCRIPT}" 'Reusing provenance-verified Mobilebridge XCFramework for Debug build.' "bootstrap verified reuse result"
assert_contains "${BOOTSTRAP_SCRIPT}" 'rebuilding from current source by policy' "ordinary bootstrap fresh-build policy"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'PSY_XCFRAMEWORK_CACHE_ROOT is unsupported; XCFramework builds require an isolated cache' "XCFramework builder hostile cache rejection"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'build_cache_root="$tools_dir/go-cache"' "XCFramework builder isolated cache"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'GOPATH="$build_cache_root/go-path"' "XCFramework builder isolated GOPATH"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'GOMODCACHE="$build_cache_root/go-path/pkg/mod"' "XCFramework builder isolated module cache"
assert_contains "${ROOT_DIR}/GoCore/Scripts/xcframework-build-settings.sh" 'PSY_XCFRAMEWORK_TARGET=ios,iossimulator' "XCFramework device and Simulator target set"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'XCFramework output basename must be Mobilebridge.xcframework' "XCFramework audited module basename"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'PSY_GO_MODULE_PROXY_DIR must be an absolute canonical non-symlink directory' "XCFramework local module proxy validation"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'must contain the cached signed sum.golang.org lookup and tile trees' "XCFramework local checksum database validation"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'GOPROXY="file://$module_proxy_dir"' "XCFramework local module proxy transport"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'GOSUMDB="sum.golang.org file://$module_proxy_dir/sumdb/sum.golang.org"' "XCFramework signed local checksum database"
assert_not_contains "${XCFRAMEWORK_BUILD_IMPL}" 'GOSUMDB=off' "XCFramework checksum verification bypass"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'clang_module_cache="$tools_dir/clang-module-cache"' "XCFramework builder isolated Clang module cache"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'exec /usr/bin/env -i' "XCFramework builder clean environment re-exec"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'clean_path="$PSY_GO_TOOLCHAIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"' "XCFramework builder controlled Go/system PATH"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'PSY_GO_BINARY="$PSY_GO_BINARY" PSY_GO_BINARY_SHA256="$PSY_GO_BINARY_SHA256"' "XCFramework builder pinned Go identity propagation"
assert_not_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'PSY_XCFRAMEWORK_CLEAN_ENV' "XCFramework builder caller-controlled clean-environment skip"
[[ ! -x "${XCFRAMEWORK_BUILD_IMPL}" ]] || fail "internal XCFramework builder must not be executable"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'GOCACHEPROG=' "host cache helper reset"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'GOFIPS140=off' "host Go FIPS mode reset"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'GODEBUG=gocacheverify=1' "host Go disk-cache verification"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'GOROOT GOROOT_FINAL GO_EXTLINK_ENABLED' "host Go toolchain path reset"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH' "host compiler search path reset"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR' "host pkg-config reset"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" 'resolve-go-toolchain.sh' "hermetic environment audited Go resolver"
assert_contains "${HERMETIC_GO_ENVIRONMENT}" '"$PSY_GO_BINARY" "$@"' "hermetic environment absolute Go invocation"
assert_contains "${GO_TOOLCHAIN_RESOLVER}" 'arm64) _psy_go_homebrew=/opt/homebrew/bin/go' "Apple Silicon Homebrew Go fallback"
assert_contains "${GO_TOOLCHAIN_RESOLVER}" 'x86_64) _psy_go_homebrew=/usr/local/bin/go' "Intel Homebrew Go fallback"
assert_contains "${GO_TOOLCHAIN_RESOLVER}" 'Go 1.25 or newer is required' "minimum Go version gate"
assert_contains "${GO_TOOLCHAIN_RESOLVER}" '/usr/bin/env -i' "Go version probe clean environment"
assert_contains "${GO_TOOLCHAIN_RESOLVER}" 'PSY_GO_BINARY_SHA256' "resolved Go identity pin"
assert_contains "${BUILD_USER_HOME_RESOLVER}" '/usr/bin/id -P' "system account login-directory resolution"
assert_contains "${BUILD_USER_HOME_RESOLVER}" 'inherited HOME does not match the system account record' "hostile HOME rejection"
assert_contains "${XCFRAMEWORK_BUILD_SCRIPT}" 'HOME="$PSY_BUILD_USER_HOME"' "validated real HOME propagation"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'XDG_CONFIG_HOME="$build_cache_root/xdg-config"' "private build configuration root"
assert_contains "${XCFRAMEWORK_BUILD_IMPL}" 'remove_tools_root' "validated read-only module-cache cleanup"
assert_contains "${BOOTSTRAP_SCRIPT}" '"--preflight"' "non-mutating Mobilebridge bootstrap preflight"
assert_contains "${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh" 'Scripts/resolve-go-toolchain.sh' "Go resolver strict source manifest input"
assert_contains "${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh" 'goExecutablePath' "Go executable provenance path"
assert_contains "${ROOT_DIR}/GoCore/Scripts/xcframework-provenance.sh" 'goExecutableSHA256' "Go executable provenance identity"
assert_not_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'PEER_INTEROP_GOCACHE' "peer interop caller-owned build cache"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'go_cache="$peer_tmp/go-cache"' "peer interop isolated build cache"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'GODEBUG= GOCACHE="$go_cache"' "peer interop link cache verification override"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'TestConfiguredPeerRejectsLegacyAndMalformedProtocolWithoutStoppingCore' "protocol rejection integration test inclusion"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'TestPeerInterop' "standard peer integration test inclusion"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'PEER_INTEROP_MULTI_GIB_BYTES=2148532224' "multi-GiB real peer content gate"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'PEER_INTEROP_NONSPARSE_MULTI_GIB_BYTES=2148532224' "non-sparse multi-GiB full-content peer gate"
assert_contains "${ROOT_DIR}/Makefile" 'PEER_INTEROP_SMALL_FILE_COUNT=10000 bash Scripts/verify.sh interop' "10k physical small-file peer scale gate"
assert_contains "${ROOT_DIR}/Makefile" 'PEER_INTEROP_SMALL_FILE_COUNT=100000 bash Scripts/verify.sh interop' "100k physical small-file peer scale gate"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'current_test_timeout=150m' "100k peer scale outer timeout"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" 'interopRescanIntervalS    = 3600' "interop peers use realistic rescan interval"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" '"rescanIntervalS":    strconv.Itoa(interopRescanIntervalS)' "embedded peer uses realistic rescan interval"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" 'syncedFolder.RescanIntervalS = interopRescanIntervalS' "standard peer uses matching rescan interval"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" 'standardPeerWatcherDelay  = 10 * time.Second' "standard peer production watcher delay"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" 'time.Sleep(standardPeerWatcherSettle)' "directional tests await production watcher aggregation"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" "s#/Users/[^[:space:]]+#<host-path>#g" "peer failure-log host path redaction"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" '66afbbe2c4a957a5700d20bd16ac741a0a40d6f9' "current peer official tag object pin"
assert_not_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'build_historical_peer' "historical peer matrix removed"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'PEER_INTEROP_RELEASE=' "peer binary release attestation input"
assert_contains "${ROOT_DIR}/GoCore/Scripts/test-peer-interop.sh" 'usage-report route fenced to the verified-unbound loopback GUI address' "usage-report route disclosure"
assert_contains "${ROOT_DIR}/GoCore/integration/peer_interop_test.go" 'configuration.Options.URURL = "http://" + guiAddress' "usage-report loopback fence"
assert_contains "${SCRIPT_DIR}/verify.sh" 'GOCACHE="${race_go_cache}"' "race test isolated build cache"
assert_contains "${SCRIPT_DIR}/verify.sh" 'GOTMPDIR="${race_tmp}"' "race test isolated temporary linker directory"
final_release_xcode_order="$(
    awk '
        /^[[:space:]]*all\)/ { in_all = 1 }
        in_all && /^[[:space:]]*verify_(ui|ios)$/ { print $1 }
        in_all && /^[[:space:]]*;;$/ { exit }
    ' "${SCRIPT_DIR}/verify.sh"
)"
[[ "${final_release_xcode_order}" == $'verify_ui\nverify_ios' ]] || {
    fail "verify all must finish UI before the final iOS build/provenance gate"
}
assert_contains "${PROJECT_GENERATOR}" 'bootstrap_phase.show_env_vars_in_log = "0"' "project generator build environment redaction"
assert_contains "${PROJECT_GENERATOR}" 'configuration.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"' "project generator audited aggregate script sandbox override"
assert_not_contains "${IOS_BUILD_SCRIPT}" '/bootstrap.sh' "iOS wrapper duplicate bootstrap"
assert_not_contains "${UI_TEST_SCRIPT}" '/bootstrap.sh' "UI-test wrapper duplicate bootstrap"
assert_contains "${IOS_BUILD_SCRIPT}" 'generic/platform=iOS Simulator' "iOS Debug generic simulator destination"
assert_contains "${IOS_BUILD_SCRIPT}" 'generic/platform=iOS' "iOS Release generic device destination"
assert_contains "${IOS_BUILD_SCRIPT}" 'debug-simulator' "iOS Debug simulator product gate"
assert_contains "${IOS_BUILD_SCRIPT}" 'release-device' "iOS Release device product gate"
assert_contains "${IOS_BUILD_SCRIPT}" 'ios-arm64_x86_64-simulator' "Mobilebridge simulator slice validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'ios-arm64' "Mobilebridge device slice validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'CFBundleShortVersionString' "built marketing-version validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'CFBundleVersion' "built build-version validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX"' "fresh iOS build DerivedData"
assert_contains "${IOS_BUILD_SCRIPT}" 'check-defined-symbol.sh' "defined Mobilebridge symbol validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'check-mobilebridge-link-image.sh' "static Mobilebridge final-image validation"
assert_contains "${DEFINED_SYMBOL_CHECK}" '$(NF - 1) == "T"' "strong external Mobilebridge text definition"
assert_contains "${IOS_BUILD_SCRIPT}" 'app_launcher_image' "app launcher dynamic-load validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'provider_launcher_image' "File Provider launcher dynamic-load validation"
assert_contains "${IOS_BUILD_SCRIPT}" 'no-dynamic-load' "launcher Mobilebridge dynamic-load rejection"
assert_contains "${UI_TEST_SCRIPT}" 'run_test_xcodebuild build-for-testing' "iOS test single build action"
test_without_building_count="$(grep -Fc 'test-without-building' "${UI_TEST_SCRIPT}")"
[[ "${test_without_building_count}" -eq 1 ]] || fail "all five iOS test actions must pass through the single result-bundle wrapper"
assert_contains "${UI_TEST_SCRIPT}" '"-only-testing:${UNIT_TEST_TARGET}"' "iOS unit target execution"
assert_contains "${UI_TEST_SCRIPT}" 'EXPECTED_IOS_UNIT_TEST_COUNT="599"' "frozen real iOS unit-test count"
assert_not_contains "${UI_TEST_SCRIPT}" 'PSY_EXPECTED_IOS_UNIT_TEST_COUNT' "non-bypassable iOS unit-test count"
assert_contains "${UI_TEST_SCRIPT}" '-resultBundlePath "${result_bundle}"' "unique xcresult per iOS test action"
assert_contains "${UI_TEST_SCRIPT}" 'xcresulttool get test-results summary' "machine-readable xcresult summary"
assert_contains "${UI_TEST_SCRIPT}" 'totalTestCount' "positive xcresult total assertion"
assert_contains "${UI_TEST_SCRIPT}" 'passedTests' "xcresult passed-count assertion"
assert_contains "${UI_TEST_SCRIPT}" 'failedTests skippedTests expectedFailures' "xcresult zero-failure assertion"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl uninstall' "UI fixed-bundle uninstall"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl get_app_container' "UI clean install-state validation"
assert_contains "${UI_TEST_SCRIPT}" 'testCleanInstallPublishesIdentityAndSyncNowReportsZeroFolderNoOp' "UI clean-install contract selection"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl list runtimes available -j' "ephemeral UI runtime selection"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl list devicetypes -j' "ephemeral iPhone/iPad type selection"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl create' "fresh ephemeral simulator creation"
assert_contains "${UI_TEST_SCRIPT}" 'UUIDGEN_BINARY="/usr/bin/uuidgen"' "system-UUID simulator naming"
assert_contains "${UI_TEST_SCRIPT}" 'pre-existing name' "pre-existing simulator name collision guard"
assert_not_contains "${UI_TEST_SCRIPT}" '${RANDOM}' "collision-prone simulator naming"
assert_contains "${UI_TEST_SCRIPT}" 'Recovered exact created simulator' "malformed simctl create cleanup recovery"
simctl_create_count="$(grep -Fc 'xcrun simctl create' "${UI_TEST_SCRIPT}")"
[[ "${simctl_create_count}" -eq 1 ]] || fail "ephemeral simulator creation must have one live guarded call site"
assert_contains "${UI_TEST_SCRIPT}" 'xcrun simctl delete' "exact ephemeral simulator cleanup"
assert_contains "${UI_TEST_SCRIPT}" 'error: failed to delete exact ephemeral simulator' "ephemeral simulator cleanup hard failure"
assert_contains "${UI_TEST_SCRIPT}" 'assert_coresimulator_user_service_ownership' "CoreSimulator cross-UID ownership preflight"
assert_contains "${UI_TEST_SCRIPT}" 'SIMULATOR_DELETE_RETRY_LIMIT=4' "bounded exact simulator delete retry"
assert_contains "${UI_TEST_SCRIPT}" 'simulator_device_presence' "exact simulator absence proof"
assert_not_contains "${UI_TEST_SCRIPT}" 'simctl delete unavailable' "broad unavailable simulator deletion"
assert_not_contains "${UI_TEST_SCRIPT}" 'simctl erase' "user simulator preservation"
assert_not_contains "${UI_TEST_SCRIPT}" 'PSY_UI_TEST_DEVICE_CLASSES' "non-bypassable iPhone/iPad UI matrix"
assert_contains "${UI_TEST_SCRIPT}" 'mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX"' "fresh iOS test DerivedData"
assert_contains "${UI_TEST_SCRIPT}" 'mktemp -d "${RESULT_BUNDLE_PARENT%/}/run.XXXXXX"' "fresh iOS xcresult run directory"

for xcode_script in "${IOS_BUILD_SCRIPT}" "${UI_TEST_SCRIPT}"; do
    assert_contains "${xcode_script}" 'export XDG_CACHE_HOME=' "writable Xcode cache root"
    assert_not_contains "${xcode_script}" 'CFFIXED_USER_HOME' "system account home identity"
    assert_contains "${xcode_script}" 'SWIFT_MODULE_CACHE_PATH=' "Swift package manifest module cache"
    assert_contains "${xcode_script}" 'MODULE_CACHE_DIR=' "Clang package manifest module cache"
    assert_contains "${xcode_script}" 'ENABLE_USER_SCRIPT_SANDBOXING=NO' "audited Mobilebridge aggregate script override"
done

if git -C "${ROOT_DIR}" ls-files --error-unmatch Config/Local.xcconfig >/dev/null 2>&1; then
    fail "Config/Local.xcconfig contains local signing values and must not be tracked"
fi

git -C "${ROOT_DIR}" check-ignore -q -- Config/Local.xcconfig || fail "Config/Local.xcconfig must remain ignored"
git -C "${ROOT_DIR}" check-ignore -q -- Artifacts/Mobilebridge.xcframework || fail "generated Mobilebridge must remain ignored"
git -C "${ROOT_DIR}" check-ignore -q -- .build/go/syncthing-readiness-v1 || fail "generated Syncthing source must remain ignored"
if git -C "${ROOT_DIR}" check-ignore -q -- Config/CI.xcconfig; then
    fail "Config/CI.xcconfig must be committed, not ignored"
fi

printf 'Project, plist, entitlement, scheme, and configuration sanity checks passed.\n'
