#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
DERIVED_DATA_PARENT="${PSY_DERIVED_DATA_PATH:-${VERIFY_ROOT}/DerivedData}"
DERIVED_DATA_ROOT=""
EXPECTED_MARKETING_VERSION="1.0.0"
EXPECTED_BUILD_VERSION="1"
DEFINED_SYMBOL_CHECK="${SCRIPT_DIR}/check-defined-symbol.sh"
LINK_IMAGE_CHECK="${SCRIPT_DIR}/check-mobilebridge-link-image.sh"

command -v xcodebuild >/dev/null 2>&1 || {
    printf 'error: xcodebuild is required for the iOS simulator build\n' >&2
    exit 1
}
command -v plutil >/dev/null 2>&1 || {
    printf 'error: plutil is required for built-product validation\n' >&2
    exit 1
}
command -v nm >/dev/null 2>&1 || {
    printf 'error: nm is required for bridge linkage validation\n' >&2
    exit 1
}
command -v otool >/dev/null 2>&1 || {
    printf 'error: otool is required for bridge linkage validation\n' >&2
    exit 1
}
command -v lipo >/dev/null 2>&1 || {
    printf 'error: lipo is required for built-product validation\n' >&2
    exit 1
}
command -v cmp >/dev/null 2>&1 || {
    printf 'error: cmp is required for bundled legal-resource validation\n' >&2
    exit 1
}
[[ -f "${DEFINED_SYMBOL_CHECK}" ]] || {
    printf 'error: defined-symbol validator is missing: %s\n' "${DEFINED_SYMBOL_CHECK}" >&2
    exit 1
}
[[ -f "${LINK_IMAGE_CHECK}" ]] || {
    printf 'error: Mobilebridge link-image validator is missing: %s\n' "${LINK_IMAGE_CHECK}" >&2
    exit 1
}

assert_built_plist_value() {
    local plist="$1"
    local key_path="$2"
    local expected="$3"
    local actual

    [[ -f "${plist}" ]] || {
        printf 'error: built plist is missing: %s\n' "${plist}" >&2
        exit 1
    }
    actual="$(plutil -extract "${key_path}" raw -o - "${plist}")"
    [[ "${actual}" == "${expected}" ]] || {
        printf "error: built plist %s key %s expected '%s', found '%s'\n" "${plist}" "${key_path}" "${expected}" "${actual}" >&2
        exit 1
    }
}

assert_built_privacy_manifest() {
    local manifest="$1"
    local expects_user_selected_reason="$2"

    assert_built_plist_value "${manifest}" "NSPrivacyTracking" "false"
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryFileTimestamp"
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0" "C617.1"
    if [[ "${expects_user_selected_reason}" == "true" ]]; then
        assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.1" "3B52.1"
    fi
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategoryDiskSpace"
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPITypeReasons.0" "E174.1"
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPIType" "NSPrivacyAccessedAPICategorySystemBootTime"
    assert_built_plist_value "${manifest}" "NSPrivacyAccessedAPITypes.2.NSPrivacyAccessedAPITypeReasons.0" "35F9.1"
}

assert_built_resource_matches() {
    local source="$1"
    local bundled="$2"

    [[ -f "${bundled}" ]] || {
        printf 'error: required bundled resource is missing: %s\n' "${bundled}" >&2
        exit 1
    }
    cmp -s "${source}" "${bundled}" || {
        printf 'error: bundled resource differs from repository source: %s\n' "${bundled}" >&2
        exit 1
    }
}

assert_arm64_image() {
    local image="$1"

    lipo -archs "${image}" | tr ' ' '\n' | grep -Fx 'arm64' >/dev/null || {
        printf 'error: arm64 is missing from built image %s\n' "${image}" >&2
        exit 1
    }
}

assert_framework_archive_platform() {
    local framework_binary="$1"
    local expected_platform="$2"
    local expected_minimum="$3"
    local platform_values
    local minimum_values

    platform_values="$(
        otool -l "${framework_binary}" \
            | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
                in_build && $1 == "platform" { print $2; in_build = 0 }'
    )"
    [[ -n "${platform_values}" ]] || {
        printf 'error: Mobilebridge archive has no LC_BUILD_VERSION platform records: %s\n' \
            "${framework_binary}" >&2
        exit 1
    }
    if printf '%s\n' "${platform_values}" | grep -Fvx "${expected_platform}" >/dev/null; then
        printf 'error: Mobilebridge archive contains a platform other than %s: %s\n' \
            "${expected_platform}" "${framework_binary}" >&2
        exit 1
    fi

    minimum_values="$(
        otool -l "${framework_binary}" \
            | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
                in_build && $1 == "minos" { print $2; in_build = 0 }'
    )"
    [[ -n "${minimum_values}" ]] || {
        printf 'error: Mobilebridge archive has no LC_BUILD_VERSION minimum-OS records: %s\n' \
            "${framework_binary}" >&2
        exit 1
    }
    if printf '%s\n' "${minimum_values}" | grep -Fvx "${expected_minimum}" >/dev/null; then
        printf 'error: Mobilebridge archive minimum OS differs from %s: %s\n' \
            "${expected_minimum}" "${framework_binary}" >&2
        exit 1
    fi
}

assert_effective_framework_slice() {
    local target="$1"
    local configuration="$2"
    local sdk="$3"
    local expected_slice="$4"
    local rejected_slice="$5"
    local settings
    local framework_search_paths
    local expected_path="${ROOT_DIR}/Artifacts/Mobilebridge.xcframework/${expected_slice}"
    local rejected_path="${ROOT_DIR}/Artifacts/Mobilebridge.xcframework/${rejected_slice}"

    settings="$(
        xcodebuild \
            -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
            -target "${target}" \
            -configuration "${configuration}" \
            -sdk "${sdk}" \
            -xcconfig "${ROOT_DIR}/Config/CI.xcconfig" \
            -clonedSourcePackagesDirPath "${VERIFY_ROOT}/SourcePackages" \
            -packageCachePath "${VERIFY_ROOT}/package-cache" \
            -skipPackageUpdates \
            COMPILER_INDEX_STORE_ENABLE=NO \
            CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/clang-module-cache" \
            SWIFT_MODULE_CACHE_PATH="${VERIFY_ROOT}/swiftpm-module-cache" \
            MODULE_CACHE_DIR="${VERIFY_ROOT}/clang-module-cache" \
            -showBuildSettings
    )"
    framework_search_paths="$(
        printf '%s\n' "${settings}" \
            | awk -F ' = ' '$1 ~ /^[[:space:]]*FRAMEWORK_SEARCH_PATHS$/ { print $2; exit }'
    )"
    [[ -n "${framework_search_paths}" ]] || {
        printf 'error: %s %s did not expose an effective FRAMEWORK_SEARCH_PATHS setting\n' \
            "${target}" "${sdk}" >&2
        exit 1
    }
    printf '%s\n' "${framework_search_paths}" | tr ' ' '\n' \
        | grep -Fx "${expected_path}" >/dev/null || {
        printf 'error: %s %s does not select Mobilebridge slice %s\n' \
            "${target}" "${sdk}" "${expected_slice}" >&2
        exit 1
    }
    if printf '%s\n' "${framework_search_paths}" | tr ' ' '\n' \
        | grep -Fx "${rejected_path}" >/dev/null; then
        printf 'error: %s %s also exposes the wrong Mobilebridge slice %s\n' \
            "${target}" "${sdk}" "${rejected_slice}" >&2
        exit 1
    fi
}

validate_product_pair() {
    local case_name="$1"
    local configuration="$2"
    local products_sdk="$3"
    local supported_platform="$4"
    local expected_slice="$5"
    local expected_archive_platform="$6"
    local derived_data_path="$7"
    local app_product
    local provider_product
    local app_launcher_image
    local provider_launcher_image
    local app_link_image
    local provider_link_image
    local framework_binary="${ROOT_DIR}/Artifacts/Mobilebridge.xcframework/${expected_slice}/Mobilebridge.framework/Mobilebridge"

    app_product="${derived_data_path}/Build/Products/${configuration}-${products_sdk}/Psynguechthyngue.app"
    provider_product="${app_product}/PlugIns/PsyFileProvider.appex"

    [[ -f "${app_product}/Psynguechthyngue" ]] || {
        printf 'error: %s built app executable is missing\n' "${case_name}" >&2
        exit 1
    }
    [[ -f "${provider_product}/PsyFileProvider" ]] || {
        printf 'error: %s embedded File Provider executable is missing\n' "${case_name}" >&2
        exit 1
    }
    [[ -f "${framework_binary}" ]] || {
        printf 'error: %s Mobilebridge slice is missing: %s\n' "${case_name}" "${expected_slice}" >&2
        exit 1
    }

    assert_built_plist_value "${app_product}/Info.plist" "CFBundleIdentifier" "com.example.Psynguechthyngue.CI"
    assert_built_plist_value "${app_product}/Info.plist" "CFBundleShortVersionString" "${EXPECTED_MARKETING_VERSION}"
    assert_built_plist_value "${app_product}/Info.plist" "CFBundleVersion" "${EXPECTED_BUILD_VERSION}"
    assert_built_plist_value "${app_product}/Info.plist" "MinimumOSVersion" "17.0"
    assert_built_plist_value "${app_product}/Info.plist" "CFBundleSupportedPlatforms.0" "${supported_platform}"
    assert_built_plist_value "${app_product}/Info.plist" "UIDeviceFamily.0" "1"
    assert_built_plist_value "${app_product}/Info.plist" "UIDeviceFamily.1" "2"
    assert_built_plist_value "${app_product}/Info.plist" "PsyKeychainAccessGroup" "com.example.Psynguechthyngue.CI"
    assert_built_plist_value "${provider_product}/Info.plist" "CFBundleIdentifier" "com.example.Psynguechthyngue.CI.FileProvider"
    assert_built_plist_value "${provider_product}/Info.plist" "CFBundleShortVersionString" "${EXPECTED_MARKETING_VERSION}"
    assert_built_plist_value "${provider_product}/Info.plist" "CFBundleVersion" "${EXPECTED_BUILD_VERSION}"
    assert_built_plist_value "${provider_product}/Info.plist" "MinimumOSVersion" "17.0"
    assert_built_plist_value "${provider_product}/Info.plist" "CFBundleSupportedPlatforms.0" "${supported_platform}"
    assert_built_plist_value "${provider_product}/Info.plist" "PsyKeychainAccessGroup" "com.example.Psynguechthyngue.CI"
    assert_built_plist_value "${provider_product}/Info.plist" "NSExtension.NSExtensionPointIdentifier" "com.apple.fileprovider-nonui"
    assert_built_plist_value "${provider_product}/Info.plist" "NSExtension.NSExtensionFileProviderDocumentGroup" "group.com.example.Psynguechthyngue.CI"
    assert_built_privacy_manifest "${app_product}/PrivacyInfo.xcprivacy" "true"
    assert_built_privacy_manifest "${provider_product}/PrivacyInfo.xcprivacy" "false"
    assert_built_resource_matches "${ROOT_DIR}/LICENSE" "${app_product}/LICENSE"
    assert_built_resource_matches "${ROOT_DIR}/NOTICE" "${app_product}/NOTICE"
    assert_built_resource_matches \
        "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" \
        "${app_product}/THIRD_PARTY_NOTICES.md"

    app_launcher_image="${app_product}/Psynguechthyngue"
    provider_launcher_image="${provider_product}/PsyFileProvider"
    app_link_image="${app_product}/Psynguechthyngue.debug.dylib"
    provider_link_image="${provider_product}/PsyFileProvider.debug.dylib"
    [[ -f "${app_link_image}" ]] || app_link_image="${app_launcher_image}"
    [[ -f "${provider_link_image}" ]] || provider_link_image="${provider_launcher_image}"

    assert_arm64_image "${app_launcher_image}"
    assert_arm64_image "${provider_launcher_image}"
    assert_arm64_image "${app_link_image}"
    assert_arm64_image "${provider_link_image}"
    assert_framework_archive_platform "${framework_binary}" "${expected_archive_platform}" "17.0"

    if [[ "${app_launcher_image}" != "${app_link_image}" ]]; then
        bash "${LINK_IMAGE_CHECK}" "${app_launcher_image}" arm64 no-dynamic-load
    fi
    if [[ "${provider_launcher_image}" != "${provider_link_image}" ]]; then
        bash "${LINK_IMAGE_CHECK}" "${provider_launcher_image}" arm64 no-dynamic-load
    fi
    bash "${LINK_IMAGE_CHECK}" "${app_link_image}" arm64 static-bridge
    bash "${LINK_IMAGE_CHECK}" "${provider_link_image}" arm64 static-bridge

    printf '%s app, embedded File Provider, %s Mobilebridge slice, and version %s (%s) validated.\n' \
        "${case_name}" "${expected_slice}" "${EXPECTED_MARKETING_VERSION}" "${EXPECTED_BUILD_VERSION}"
}

build_case() {
    local case_name="$1"
    local configuration="$2"
    local destination="$3"
    local sdk="$4"
    local products_sdk="$5"
    local supported_platform="$6"
    local expected_slice="$7"
    local rejected_slice="$8"
    local expected_archive_platform="$9"
    local derived_data_path="${DERIVED_DATA_ROOT}/${case_name}"

    assert_effective_framework_slice \
        Psynguechthyngue "${configuration}" "${sdk}" "${expected_slice}" "${rejected_slice}"
    assert_effective_framework_slice \
        PsyFileProvider "${configuration}" "${sdk}" "${expected_slice}" "${rejected_slice}"

    mkdir -p "${derived_data_path}"
    printf 'Building %s unsigned products with %s\n' \
        "${case_name}" "$(xcodebuild -version | tr '\n' ' ')"

    xcodebuild \
        -quiet \
        -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
        -scheme Psynguechthyngue \
        -configuration "${configuration}" \
        -destination "${destination}" \
        -derivedDataPath "${derived_data_path}" \
        -clonedSourcePackagesDirPath "${VERIFY_ROOT}/SourcePackages" \
        -packageCachePath "${VERIFY_ROOT}/package-cache" \
        -xcconfig "${ROOT_DIR}/Config/CI.xcconfig" \
        -skipPackageUpdates \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        COMPILER_INDEX_STORE_ENABLE=NO \
        ENABLE_USER_SCRIPT_SANDBOXING=NO \
        CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/clang-module-cache" \
        SWIFT_MODULE_CACHE_PATH="${VERIFY_ROOT}/swiftpm-module-cache" \
        MODULE_CACHE_DIR="${VERIFY_ROOT}/clang-module-cache" \
        build

    validate_product_pair \
        "${case_name}" "${configuration}" "${products_sdk}" "${supported_platform}" \
        "${expected_slice}" "${expected_archive_platform}" "${derived_data_path}"
}

mkdir -p \
    "${VERIFY_ROOT}/clang-module-cache" \
    "${VERIFY_ROOT}/swiftpm-module-cache" \
    "${VERIFY_ROOT}/xdg-cache" \
    "${VERIFY_ROOT}/SourcePackages" \
    "${VERIFY_ROOT}/package-cache" \
    "${DERIVED_DATA_PARENT}"

DERIVED_DATA_ROOT="$(mktemp -d "${DERIVED_DATA_PARENT%/}/run.XXXXXX")"
printf 'Using fresh iOS build DerivedData: %s\n' "${DERIVED_DATA_ROOT}"

export CLANG_MODULE_CACHE_PATH="${VERIFY_ROOT}/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${VERIFY_ROOT}/swiftpm-module-cache"
export XDG_CACHE_HOME="${VERIFY_ROOT}/xdg-cache"

build_case \
    debug-simulator \
    Debug \
    'generic/platform=iOS Simulator' \
    iphonesimulator \
    iphonesimulator \
    iPhoneSimulator \
    ios-arm64_x86_64-simulator \
    ios-arm64 \
    7

build_case \
    release-device \
    Release \
    'generic/platform=iOS' \
    iphoneos \
    iphoneos \
    iPhoneOS \
    ios-arm64 \
    ios-arm64_x86_64-simulator \
    2

printf 'Debug simulator and unsigned Release generic-device product matrices passed.\n'
