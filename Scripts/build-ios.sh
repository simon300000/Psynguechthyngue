#!/usr/bin/env bash
# Builds the App + embedded File Provider for the iOS Simulator (Debug) and an
# unsigned generic iOS device (Release), then validates the products:
# identifiers, versions, legal resources, privacy manifests, and that
# PsyBridge is linked statically into both executables.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_ROOT="${PSY_VERIFY_BUILD_ROOT:-${ROOT_DIR}/.build/verify}"
DERIVED_DATA="${PSY_DERIVED_DATA_PATH:-${VERIFY_ROOT}/DerivedData}"
SIM_CONFIGURATION="${PSY_SIM_CONFIGURATION:-Debug}"
EXPECTED_VERSION="1.0.0"
EXPECTED_BUILD="1"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

plist_is() { # plist key expected
    local actual
    actual="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" || fail "$1: missing $2"
    [[ "${actual}" == "$3" ]] || fail "$1: $2 is '${actual}', expected '$3'"
}

same_file() { cmp -s "$1" "$2" || fail "bundled $(basename "$2") differs from $1"; }

has_psybridge() { # executable
    local image="$1"
    [[ -f "${image%/*}/$(basename "${image}").debug.dylib" ]] && image="${image%/*}/$(basename "${image}").debug.dylib"
    # Count (not grep -q) so nm never dies of SIGPIPE under pipefail.
    [[ "$(nm -U "${image}" 2>/dev/null | grep -c 'PsybridgeEngine')" -gt 0 ]] || fail "PsyBridge symbols missing from ${image}"
    [[ "$(otool -L "$1" | grep -c PsyBridge)" -eq 0 ]] || fail "PsyBridge must be linked statically: $1"
}

build() { # configuration destination
    xcodebuild -quiet \
        -project "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
        -scheme Psynguechthyngue \
        -configuration "$1" \
        -destination "$2" \
        -derivedDataPath "${DERIVED_DATA}" \
        -xcconfig "${ROOT_DIR}/Config/CI.xcconfig" \
        COMPILER_INDEX_STORE_ENABLE=NO \
        build
}

validate() { # products-dir platform
    local app="$1/Psynguechthyngue.app" platform="$2"
    local ext="${app}/PlugIns/PsyFileProvider.appex"
    [[ -f "${app}/Psynguechthyngue" ]] || fail "app executable missing in $1"
    [[ -f "${ext}/PsyFileProvider" ]] || fail "embedded File Provider missing in $1"
    plist_is "${app}/Info.plist" CFBundleIdentifier com.example.Psynguechthyngue.CI
    plist_is "${app}/Info.plist" CFBundleShortVersionString "${EXPECTED_VERSION}"
    plist_is "${app}/Info.plist" CFBundleVersion "${EXPECTED_BUILD}"
    plist_is "${app}/Info.plist" MinimumOSVersion 17.0
    plist_is "${app}/Info.plist" CFBundleSupportedPlatforms.0 "${platform}"
    plist_is "${app}/Info.plist" PsyKeychainAccessGroup com.example.Psynguechthyngue.CI
    plist_is "${ext}/Info.plist" CFBundleIdentifier com.example.Psynguechthyngue.CI.FileProvider
    plist_is "${ext}/Info.plist" CFBundleShortVersionString "${EXPECTED_VERSION}"
    plist_is "${ext}/Info.plist" NSExtension.NSExtensionPointIdentifier com.apple.fileprovider-nonui
    plist_is "${ext}/Info.plist" NSExtension.NSExtensionFileProviderDocumentGroup group.com.example.Psynguechthyngue.CI
    plist_is "${ext}/Info.plist" PsyKeychainAccessGroup com.example.Psynguechthyngue.CI
    same_file "${ROOT_DIR}/LICENSE" "${app}/LICENSE"
    same_file "${ROOT_DIR}/NOTICE" "${app}/NOTICE"
    same_file "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${app}/THIRD_PARTY_NOTICES.md"
    same_file "${ROOT_DIR}/App/Resources/PrivacyInfo.xcprivacy" "${app}/PrivacyInfo.xcprivacy"
    same_file "${ROOT_DIR}/FileProvider/Resources/PrivacyInfo.xcprivacy" "${ext}/PrivacyInfo.xcprivacy"
    [[ -f "${app}/zh-Hans.lproj/Localizable.strings" || -f "${app}/zh-Hans.lproj/Localizable.stringsdict" ]] \
        || fail "zh-Hans localization missing from app"
    has_psybridge "${app}/Psynguechthyngue"
    has_psybridge "${ext}/PsyFileProvider"
    printf 'validated %s\n' "${app#"${ROOT_DIR}/"}"
}

[[ -d "${ROOT_DIR}/Artifacts/PsyBridge.xcframework" ]] || fail "Artifacts/PsyBridge.xcframework missing; run make bootstrap"

printf 'Building %s for iOS Simulator\n' "${SIM_CONFIGURATION}"
build "${SIM_CONFIGURATION}" 'generic/platform=iOS Simulator'
validate "${DERIVED_DATA}/Build/Products/${SIM_CONFIGURATION}-iphonesimulator" iPhoneSimulator

printf 'Building unsigned Release for generic iOS device\n'
build Release 'generic/platform=iOS'
validate "${DERIVED_DATA}/Build/Products/Release-iphoneos" iPhoneOS

printf 'iOS builds validated.\n'
