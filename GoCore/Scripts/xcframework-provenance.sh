#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${CORE_DIR}/.." && pwd)"
. "${REPO_DIR}/Scripts/hermetic-go-environment.sh"
SYNCTHING_SOURCE_GATE="${SCRIPT_DIR}/verify-syncthing-source.sh"
SYNCTHING_SOURCE_LOCK="${CORE_DIR}/SyncthingSource.lock.json"
# shellcheck source=xcframework-build-settings.sh
source "${SCRIPT_DIR}/xcframework-build-settings.sh"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_safe_token() {
    local label="$1"
    local value="$2"

    [[ -n "${value}" ]] || fail "${label} is empty"
    printf '%s\n' "${value}" | LC_ALL=C grep -Eq '^[A-Za-z0-9._+-]+$' || {
        fail "${label} contains unsupported characters"
    }
}

require_sha256() {
    local label="$1"
    local value="$2"

    printf '%s\n' "${value}" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || {
        fail "${label} is not a lowercase SHA-256 digest"
    }
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

file_size() {
    wc -c <"$1" | tr -d '[:space:]'
}

append_manifest_entry() {
    local manifest="$1"
    local base="$2"
    local relative_path="$3"
    local absolute_path="${base}/${relative_path}"
    local digest
    local bytes

    [[ "${relative_path}" != *$'\n'* && "${relative_path}" != *$'\t'* ]] || {
        fail "manifest input path contains a newline or tab"
    }
    [[ -f "${absolute_path}" && ! -L "${absolute_path}" ]] || {
        fail "manifest input must be a regular, non-symlink file: ${relative_path}"
    }
    digest="$(sha256_file "${absolute_path}")"
    bytes="$(file_size "${absolute_path}")"
    printf '%s\t%s\t%s\n' "${digest}" "${bytes}" "${relative_path}" >>"${manifest}"
}

source_hash() {
    local manifest
    local source_list
    local relative_path

	require_command find
	require_command shasum
	sh "${SYNCTHING_SOURCE_GATE}" --prepare
	manifest="$(mktemp)"
    source_list="$(mktemp)"
    trap 'rm -f -- "${manifest:-}" "${source_list:-}"' RETURN

    if find "${CORE_DIR}/mobilebridge" "${CORE_DIR}/Tools/preparelock" -type l -print -quit | grep -q .; then
		fail "Go production and preparation helper sources must not contain symlinks"
    fi

    (
        cd "${CORE_DIR}"
        find mobilebridge -type f -name '*.go' ! -name '*_test.go' -print | LC_ALL=C sort
		find Tools/preparelock -type f -name '*.go' -print | LC_ALL=C sort
    ) >"${source_list}"

	printf 'psy-xcframework-source-manifest-v4\n' >"${manifest}"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "go.mod"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "go.sum"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "SyncthingSource.lock.json"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Patches/syncthing-cluster-index-readiness.patch"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/build-xcframework.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/build-xcframework-impl.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/prepare-syncthing-source.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/test-prepare-lock.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/verify-syncthing-source.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/swift-smoke.swift"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/xcframework-build-settings.sh"
	append_manifest_entry "${manifest}" "${CORE_DIR}" "Scripts/xcframework-provenance.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/hermetic-go-environment.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/resolve-build-user-home.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/resolve-go-toolchain.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/test-go-toolchain-resolver.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/bootstrap.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Scripts/test-bootstrap-no-reuse.sh"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Tools/syncthing_contract.go"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Tools/syncthing_contract_check.go"
	append_manifest_entry "${manifest}" "${REPO_DIR}" "Tools/syncthing_contract_test.go"
    while IFS= read -r relative_path; do
        [[ -n "${relative_path}" ]] || continue
        append_manifest_entry "${manifest}" "${CORE_DIR}" "${relative_path}"
    done <"${source_list}"

    sha256_file "${manifest}"
    rm -f -- "${manifest}" "${source_list}"
    trap - RETURN
}

syncthing_contract_value() {
	local key="$1"
	local value

	value="$(plutil -extract "${key}" raw -o - "${SYNCTHING_SOURCE_LOCK}" 2>/dev/null)" || {
		fail "Syncthing source lock is missing ${key}"
	}
	[[ -n "${value}" ]] || fail "Syncthing source lock ${key} is empty"
	printf '%s\n' "${value}"
}

artifact_tree_hash() {
    local artifact="$1"
    local manifest
    local file_list
    local absolute_path
    local relative_path

    [[ -d "${artifact}" && ! -L "${artifact}" ]] || {
        fail "XCFramework must be a non-symlink directory"
    }
	if find "${artifact}" -type l -print -quit | grep -q .; then
		fail "XCFramework must not contain symlinks"
	fi
	if find "${artifact}" ! -type d ! -type f ! -type l -print -quit | grep -q .; then
		fail "XCFramework must not contain special filesystem nodes"
	fi

    manifest="$(mktemp)"
    file_list="$(mktemp)"
    trap 'rm -f -- "${manifest:-}" "${file_list:-}"' RETURN
    find "${artifact}" -type f -print | LC_ALL=C sort >"${file_list}"
    printf 'psy-xcframework-artifact-manifest-v1\n' >"${manifest}"
    while IFS= read -r absolute_path; do
        [[ -n "${absolute_path}" ]] || continue
        relative_path="${absolute_path#"${artifact}/"}"
        append_manifest_entry "${manifest}" "${artifact}" "${relative_path}"
    done <"${file_list}"
    sha256_file "${manifest}"
    rm -f -- "${manifest}" "${file_list}"
    trap - RETURN
}

module_version() {
    local module="$1"
    local version

    version="$(awk -v module="${module}" '$1 == module { print $2; exit }' "${CORE_DIR}/go.mod")"
    require_safe_token "${module} module version" "${version}"
    printf '%s\n' "${version}"
}

go_directive() {
    local version

    version="$(awk '$1 == "go" { print $2; exit }' "${CORE_DIR}/go.mod")"
    require_safe_token "Go directive" "${version}"
    printf '%s\n' "${version}"
}

current_tool_metadata() {
    local key="$1"
    local value

    case "${key}" in
        goVersion)
            value="${PSY_GO_VERSION}"
            ;;
        goExecutablePath)
            value="${PSY_GO_BINARY}"
            printf '%s\n' "${value}" | LC_ALL=C grep -Eq '^/[A-Za-z0-9/._+@%=-]+$' || {
                fail "${key} contains unsupported characters"
            }
            printf '%s\n' "${value}"
            return
            ;;
        goExecutableSHA256)
            value="${PSY_GO_BINARY_SHA256}"
            require_sha256 "${key}" "${value}"
            printf '%s\n' "${value}"
            return
            ;;
        goHostOS)
            value="$(go env GOHOSTOS)"
            ;;
        goHostArch)
            value="$(go env GOHOSTARCH)"
            ;;
        xcodeVersion)
            value="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
            ;;
        xcodeBuildVersion)
            value="$(xcodebuild -version | sed -n '2s/^Build version //p')"
            ;;
        iphoneOSSDKVersion)
            value="$(xcrun --sdk iphoneos --show-sdk-version)"
            ;;
        iphoneSimulatorSDKVersion)
            value="$(xcrun --sdk iphonesimulator --show-sdk-version)"
            ;;
        *)
            fail "unknown tool metadata key: ${key}"
            ;;
    esac
    require_safe_token "${key}" "${value}"
    printf '%s\n' "${value}"
}

plist_value() {
    local sidecar="$1"
    local key_path="$2"
    local description="$3"
    local value

    value="$(plutil -extract "${key_path}" raw -o - "${sidecar}" 2>/dev/null)" || {
        fail "provenance is missing ${description}"
    }
    printf '%s\n' "${value}"
}

validate_json() {
    local file="$1"

    plutil -convert xml1 -o /dev/null "${file}" >/dev/null 2>&1 || {
        fail "provenance sidecar is not valid JSON"
    }
}

assert_value() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "${actual}" == "${expected}" ]] || {
        fail "provenance ${description} mismatch (expected ${expected}, found ${actual})"
    }
}

validate_deployment_target() {
    local deployment_target="$1"

    printf '%s\n' "${deployment_target}" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+([.][0-9]+)?$' || {
        fail "invalid iOS deployment target: ${deployment_target}"
    }
}

verify_artifact_layout_and_abi() {
    local artifact="$1"
    local device_binary="${artifact}/ios-arm64/Mobilebridge.framework/Mobilebridge"
    local simulator_binary="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Mobilebridge"
    local bridge_header="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Headers/Mobilebridge.objc.h"
    local simulator_archs
    local simulator_arch
    local simulator_arch_count=0
    local simulator_has_arm64=false
    local simulator_has_x86_64=false
    local method
    local signature

    [[ -d "${artifact}" && ! -L "${artifact}" ]] || fail "XCFramework is missing or is a symlink"
    [[ -f "${artifact}/Info.plist" && ! -L "${artifact}/Info.plist" ]] || fail "XCFramework Info.plist is missing or unsafe"
    [[ -f "${device_binary}" && ! -L "${device_binary}" ]] || fail "XCFramework device binary is missing or unsafe"
    [[ -f "${simulator_binary}" && ! -L "${simulator_binary}" ]] || fail "XCFramework simulator binary is missing or unsafe"
    [[ -f "${bridge_header}" && ! -L "${bridge_header}" ]] || fail "XCFramework bridge header is missing or unsafe"
    if find "${artifact}" -type l -print -quit | grep -q .; then
        fail "XCFramework must not contain symlinks"
    fi

    assert_value "$(lipo -archs "${device_binary}")" "arm64" "device architectures"
    simulator_archs="$(lipo -archs "${simulator_binary}")"
    for simulator_arch in ${simulator_archs}; do
        simulator_arch_count=$((simulator_arch_count + 1))
        case "${simulator_arch}" in
            arm64)
                simulator_has_arm64=true
                ;;
            x86_64)
                simulator_has_x86_64=true
                ;;
            *)
                fail "XCFramework simulator slice contains unexpected architecture: ${simulator_arch}"
                ;;
        esac
    done
    [[ "${simulator_arch_count}" -eq 2 && "${simulator_has_arm64}" == true && "${simulator_has_x86_64}" == true ]] || {
        fail "XCFramework simulator slice must contain exactly arm64 and x86_64"
    }
    for method in snapshotJSON networkTransferTotalsJSON commandJSON queryJSON readRangeJSON; do
        grep -F -- "${method}:(NSString* _Nullable)request;" "${bridge_header}" >/dev/null || {
            fail "XCFramework lacks the single-envelope ${method} ABI"
        }
    done
    for signature in \
        'MobilebridgeCoreRevision(void);' \
        '(NSString* _Nonnull)deviceID;' \
        '(NSData* _Nullable)identityBlob;' \
        'acknowledgeCommand:(NSString* _Nullable)requestID;' \
        '- (void)requestCancel;'; do
        grep -F -- "${signature}" "${bridge_header}" >/dev/null || {
            fail "XCFramework lacks required ABI signature: ${signature}"
        }
    done
}

write_sidecar() {
    local artifact="$1"
    local sidecar="$2"
    local deployment_target="$3"
    local expected_source_hash="$4"
    local device_binary="${artifact}/ios-arm64/Mobilebridge.framework/Mobilebridge"
    local simulator_binary="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Mobilebridge"
    local bridge_header="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Headers/Mobilebridge.objc.h"
    local current_source_hash
    local tree_hash
    local device_hash
    local simulator_hash
    local header_hash
    local info_hash
	local syncthing_module_version
	local syncthing_module_commit
	local syncthing_module_sum
	local syncthing_local_replace
	local syncthing_patch_sha256
	local syncthing_tree_sha256
    local mobile_module_version
    local go_module_directive
    local go_version
    local go_executable_path
    local go_executable_sha256
    local go_host_os
    local go_host_arch
    local xcode_version
    local xcode_build_version
    local device_sdk_version
    local simulator_sdk_version
    local temporary_sidecar

    validate_deployment_target "${deployment_target}"
    require_sha256 "expected source hash" "${expected_source_hash}"
    [[ ! -e "${sidecar}" && ! -L "${sidecar}" ]] || fail "refusing to overwrite provenance sidecar"
    verify_artifact_layout_and_abi "${artifact}"

    current_source_hash="$(source_hash)"
    assert_value "${current_source_hash}" "${expected_source_hash}" "source hash changed during build"
    tree_hash="$(artifact_tree_hash "${artifact}")"
    device_hash="$(sha256_file "${device_binary}")"
    simulator_hash="$(sha256_file "${simulator_binary}")"
    header_hash="$(sha256_file "${bridge_header}")"
    info_hash="$(sha256_file "${artifact}/Info.plist")"
	syncthing_module_version="$(module_version github.com/syncthing/syncthing)"
	syncthing_module_commit="$(syncthing_contract_value moduleCommit)"
	syncthing_module_sum="$(syncthing_contract_value moduleSum)"
	syncthing_local_replace="$(syncthing_contract_value localReplacePath)"
	syncthing_patch_sha256="$(syncthing_contract_value patchSHA256)"
	syncthing_tree_sha256="$(syncthing_contract_value patchedTreeSHA256)"
    mobile_module_version="$(module_version golang.org/x/mobile)"
    go_module_directive="$(go_directive)"
    go_version="$(current_tool_metadata goVersion)"
    go_executable_path="$(current_tool_metadata goExecutablePath)"
    go_executable_sha256="$(current_tool_metadata goExecutableSHA256)"
    go_host_os="$(current_tool_metadata goHostOS)"
    go_host_arch="$(current_tool_metadata goHostArch)"
    xcode_version="$(current_tool_metadata xcodeVersion)"
    xcode_build_version="$(current_tool_metadata xcodeBuildVersion)"
    device_sdk_version="$(current_tool_metadata iphoneOSSDKVersion)"
    simulator_sdk_version="$(current_tool_metadata iphoneSimulatorSDKVersion)"

    temporary_sidecar="${sidecar}.tmp.$$"
    trap 'rm -f -- "${temporary_sidecar:-}"' RETURN
    [[ ! -e "${temporary_sidecar}" && ! -L "${temporary_sidecar}" ]] || fail "temporary provenance path already exists"
    {
        printf '{\n'
        printf '  "schemaVersion": %s,\n' "${PSY_XCFRAMEWORK_PROVENANCE_SCHEMA}"
        printf '  "sourceSHA256": "%s",\n' "${current_source_hash}"
        printf '  "artifactTreeSHA256": "%s",\n' "${tree_hash}"
        printf '  "target": {\n'
        printf '    "platform": "%s",\n' "${PSY_XCFRAMEWORK_TARGET}"
        printf '    "iosDeploymentTarget": "%s",\n' "${deployment_target}"
        printf '    "buildTags": "%s",\n' "${PSY_XCFRAMEWORK_BUILD_TAGS}"
        printf '    "trimpath": true\n'
        printf '  },\n'
        printf '  "pins": {\n'
        printf '    "goDirective": "%s",\n' "${go_module_directive}"
		printf '    "gomobileModuleVersion": "%s",\n' "${mobile_module_version}"
		printf '    "syncthingModuleVersion": "%s",\n' "${syncthing_module_version}"
		printf '    "syncthingModuleCommit": "%s",\n' "${syncthing_module_commit}"
		printf '    "syncthingModuleSum": "%s",\n' "${syncthing_module_sum}"
		printf '    "syncthingLocalReplace": "%s",\n' "${syncthing_local_replace}"
		printf '    "syncthingPatchSHA256": "%s",\n' "${syncthing_patch_sha256}"
		printf '    "syncthingPatchedTreeSHA256": "%s",\n' "${syncthing_tree_sha256}"
		printf '    "syncthingBuildVersion": "%s"\n' "${PSY_SYNCTHING_BUILD_VERSION}"
        printf '  },\n'
        printf '  "tools": {\n'
        printf '    "goVersion": "%s",\n' "${go_version}"
        printf '    "goExecutablePath": "%s",\n' "${go_executable_path}"
        printf '    "goExecutableSHA256": "%s",\n' "${go_executable_sha256}"
        printf '    "goHostOS": "%s",\n' "${go_host_os}"
        printf '    "goHostArch": "%s",\n' "${go_host_arch}"
        printf '    "xcodeVersion": "%s",\n' "${xcode_version}"
        printf '    "xcodeBuildVersion": "%s",\n' "${xcode_build_version}"
        printf '    "iphoneOSSDKVersion": "%s",\n' "${device_sdk_version}"
        printf '    "iphoneSimulatorSDKVersion": "%s"\n' "${simulator_sdk_version}"
        printf '  },\n'
        printf '  "abi": {\n'
        printf '    "bridgeHeaderSHA256": "%s",\n' "${header_hash}"
        printf '    "xcframeworkInfoSHA256": "%s"\n' "${info_hash}"
        printf '  },\n'
        printf '  "slices": {\n'
        printf '    "ios-arm64": {\n'
        printf '      "architectures": ["arm64"],\n'
        printf '      "byteCount": %s,\n' "$(file_size "${device_binary}")"
        printf '      "sha256": "%s"\n' "${device_hash}"
        printf '    },\n'
        printf '    "ios-arm64_x86_64-simulator": {\n'
        printf '      "architectures": ["arm64", "x86_64"],\n'
        printf '      "byteCount": %s,\n' "$(file_size "${simulator_binary}")"
        printf '      "sha256": "%s"\n' "${simulator_hash}"
        printf '    }\n'
        printf '  }\n'
        printf '}\n'
    } >"${temporary_sidecar}"
    validate_json "${temporary_sidecar}"
    mv -- "${temporary_sidecar}" "${sidecar}"
    trap - RETURN
}

verify_sidecar() {
    local artifact="$1"
    local sidecar="$2"
    local deployment_target="$3"
    local device_binary="${artifact}/ios-arm64/Mobilebridge.framework/Mobilebridge"
    local simulator_binary="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Mobilebridge"
    local bridge_header="${artifact}/ios-arm64_x86_64-simulator/Mobilebridge.framework/Headers/Mobilebridge.objc.h"
    local current_source_hash

    validate_deployment_target "${deployment_target}"
    [[ -f "${sidecar}" && ! -L "${sidecar}" ]] || fail "provenance sidecar is missing or unsafe"
    validate_json "${sidecar}"
    verify_artifact_layout_and_abi "${artifact}"

    assert_value "$(plist_value "${sidecar}" schemaVersion schemaVersion)" "${PSY_XCFRAMEWORK_PROVENANCE_SCHEMA}" "schema version"
    current_source_hash="$(source_hash)"
    assert_value "$(plist_value "${sidecar}" sourceSHA256 sourceSHA256)" "${current_source_hash}" "source hash"
    assert_value "$(plist_value "${sidecar}" artifactTreeSHA256 artifactTreeSHA256)" "$(artifact_tree_hash "${artifact}")" "artifact tree hash"

    assert_value "$(plist_value "${sidecar}" target.platform target.platform)" "${PSY_XCFRAMEWORK_TARGET}" "target platform"
    assert_value "$(plist_value "${sidecar}" target.iosDeploymentTarget target.iosDeploymentTarget)" "${deployment_target}" "deployment target"
    assert_value "$(plist_value "${sidecar}" target.buildTags target.buildTags)" "${PSY_XCFRAMEWORK_BUILD_TAGS}" "build tags"
    assert_value "$(plist_value "${sidecar}" target.trimpath target.trimpath)" "true" "trimpath setting"

    assert_value "$(plist_value "${sidecar}" pins.goDirective pins.goDirective)" "$(go_directive)" "Go directive"
    assert_value "$(plist_value "${sidecar}" pins.gomobileModuleVersion pins.gomobileModuleVersion)" "$(module_version golang.org/x/mobile)" "gomobile module pin"
	assert_value "$(plist_value "${sidecar}" pins.syncthingModuleVersion pins.syncthingModuleVersion)" "$(module_version github.com/syncthing/syncthing)" "Syncthing module pin"
	assert_value "$(plist_value "${sidecar}" pins.syncthingModuleCommit pins.syncthingModuleCommit)" "$(syncthing_contract_value moduleCommit)" "Syncthing commit pin"
	assert_value "$(plist_value "${sidecar}" pins.syncthingModuleSum pins.syncthingModuleSum)" "$(syncthing_contract_value moduleSum)" "Syncthing module sum"
	assert_value "$(plist_value "${sidecar}" pins.syncthingLocalReplace pins.syncthingLocalReplace)" "$(syncthing_contract_value localReplacePath)" "Syncthing local replacement"
	assert_value "$(plist_value "${sidecar}" pins.syncthingPatchSHA256 pins.syncthingPatchSHA256)" "$(syncthing_contract_value patchSHA256)" "Syncthing patch SHA-256"
	assert_value "$(plist_value "${sidecar}" pins.syncthingPatchedTreeSHA256 pins.syncthingPatchedTreeSHA256)" "$(syncthing_contract_value patchedTreeSHA256)" "Syncthing patched tree SHA-256"
    assert_value "$(plist_value "${sidecar}" pins.syncthingBuildVersion pins.syncthingBuildVersion)" "${PSY_SYNCTHING_BUILD_VERSION}" "Syncthing build version"

    assert_value "$(plist_value "${sidecar}" tools.goVersion tools.goVersion)" "$(current_tool_metadata goVersion)" "Go tool version"
    assert_value "$(plist_value "${sidecar}" tools.goExecutablePath tools.goExecutablePath)" "$(current_tool_metadata goExecutablePath)" "Go executable path"
    assert_value "$(plist_value "${sidecar}" tools.goExecutableSHA256 tools.goExecutableSHA256)" "$(current_tool_metadata goExecutableSHA256)" "Go executable SHA-256"
    assert_value "$(plist_value "${sidecar}" tools.goHostOS tools.goHostOS)" "$(current_tool_metadata goHostOS)" "Go host OS"
    assert_value "$(plist_value "${sidecar}" tools.goHostArch tools.goHostArch)" "$(current_tool_metadata goHostArch)" "Go host architecture"
    assert_value "$(plist_value "${sidecar}" tools.xcodeVersion tools.xcodeVersion)" "$(current_tool_metadata xcodeVersion)" "Xcode version"
    assert_value "$(plist_value "${sidecar}" tools.xcodeBuildVersion tools.xcodeBuildVersion)" "$(current_tool_metadata xcodeBuildVersion)" "Xcode build version"
    assert_value "$(plist_value "${sidecar}" tools.iphoneOSSDKVersion tools.iphoneOSSDKVersion)" "$(current_tool_metadata iphoneOSSDKVersion)" "iPhoneOS SDK version"
    assert_value "$(plist_value "${sidecar}" tools.iphoneSimulatorSDKVersion tools.iphoneSimulatorSDKVersion)" "$(current_tool_metadata iphoneSimulatorSDKVersion)" "iPhoneSimulator SDK version"

    assert_value "$(plist_value "${sidecar}" abi.bridgeHeaderSHA256 abi.bridgeHeaderSHA256)" "$(sha256_file "${bridge_header}")" "bridge header hash"
    assert_value "$(plist_value "${sidecar}" abi.xcframeworkInfoSHA256 abi.xcframeworkInfoSHA256)" "$(sha256_file "${artifact}/Info.plist")" "XCFramework Info.plist hash"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64.architectures device.architectures)" "1" "device architecture count"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64.architectures.0 device.architectures.0)" "arm64" "device architecture"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64.byteCount device byteCount)" "$(file_size "${device_binary}")" "device byte count"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64.sha256 device sha256)" "$(sha256_file "${device_binary}")" "device slice hash"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64_x86_64-simulator.architectures simulator.architectures)" "2" "simulator architecture count"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64_x86_64-simulator.architectures.0 simulator.architectures.0)" "arm64" "first simulator architecture"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64_x86_64-simulator.architectures.1 simulator.architectures.1)" "x86_64" "second simulator architecture"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64_x86_64-simulator.byteCount simulator byteCount)" "$(file_size "${simulator_binary}")" "simulator byte count"
    assert_value "$(plist_value "${sidecar}" slices.ios-arm64_x86_64-simulator.sha256 simulator sha256)" "$(sha256_file "${simulator_binary}")" "simulator slice hash"
}

usage() {
    printf 'usage: %s source-hash | write ARTIFACT SIDECAR DEPLOYMENT_TARGET EXPECTED_SOURCE_SHA256 | verify ARTIFACT SIDECAR DEPLOYMENT_TARGET\n' "${0##*/}" >&2
    exit 64
}

require_command awk
require_command grep
require_command shasum

case "${1:-}" in
    source-hash)
        [[ "$#" -eq 1 ]] || usage
        source_hash
        ;;
    write)
        [[ "$#" -eq 5 ]] || usage
        require_command go
        require_command lipo
        require_command plutil
        require_command xcodebuild
        require_command xcrun
        write_sidecar "$2" "$3" "$4" "$5"
        ;;
    verify)
        [[ "$#" -eq 4 ]] || usage
        require_command go
        require_command lipo
        require_command plutil
        require_command xcodebuild
        require_command xcrun
        verify_sidecar "$2" "$3" "$4"
        ;;
    *)
        usage
        ;;
esac
