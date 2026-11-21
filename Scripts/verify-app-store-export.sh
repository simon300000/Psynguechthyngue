#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s --archive /absolute/path/App.xcarchive --ipa /absolute/path/App.ipa\n' "$0" >&2
    exit 64
}

archive=""
ipa=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --archive)
            [[ "$#" -ge 2 ]] || usage
            archive="$2"
            shift 2
            ;;
        --ipa)
            [[ "$#" -ge 2 ]] || usage
            ipa="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

[[ -n "${archive}" && -n "${ipa}" ]] || usage
[[ "${archive}" == /* && "${ipa}" == /* ]] || fail "archive and IPA paths must be absolute"
[[ -d "${archive}" && ! -L "${archive}" ]] || fail "archive must be a non-symlink directory"
[[ -f "${ipa}" && ! -L "${ipa}" ]] || fail "IPA must be a non-symlink regular file"

for command in awk codesign cmp dwarfdump file find grep lipo otool plutil security sed sort strings unzip; do
    command -v "${command}" >/dev/null 2>&1 || fail "required command not found: ${command}"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy is required for literal entitlement keys"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/psy-app-store-export.XXXXXX")"
cleanup() {
    rm -rf -- "${temporary_directory}"
}
trap cleanup EXIT INT TERM

entry_list="${temporary_directory}/ipa-entries.txt"
unzip -Z1 "${ipa}" >"${entry_list}"
while IFS= read -r entry; do
    case "${entry}" in
        /*|*'../'*|../*|*'\\'*) fail "IPA contains an unsafe entry path: ${entry}" ;;
    esac
done <"${entry_list}"

extracted="${temporary_directory}/extracted"
mkdir -p "${extracted}"
unzip -qq "${ipa}" -d "${extracted}"

exported_apps=()
while IFS= read -r candidate; do
    exported_apps+=("${candidate}")
done < <(find "${extracted}/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
[[ "${#exported_apps[@]}" -eq 1 ]] || fail "IPA must contain exactly one top-level app"
app="${exported_apps[0]}"
provider="${app}/PlugIns/PsyFileProvider.appex"
[[ -d "${provider}" && ! -L "${provider}" ]] || fail "embedded File Provider extension is missing"

archive_apps=()
while IFS= read -r candidate; do
    archive_apps+=("${candidate}")
done < <(find "${archive}/Products/Applications" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
[[ "${#archive_apps[@]}" -eq 1 ]] || fail "archive must contain exactly one application"

codesign --verify --deep --strict "${app}"
grep -Fq 'Authority=Apple Distribution:' < <(codesign -dv --verbose=4 "${app}" 2>&1) \
    || fail "app is not signed by an Apple Distribution identity"
grep -Fq 'Authority=Apple Distribution:' < <(codesign -dv --verbose=4 "${provider}" 2>&1) \
    || fail "extension is not signed by an Apple Distribution identity"

app_entitlements="${temporary_directory}/app-entitlements.plist"
provider_entitlements="${temporary_directory}/provider-entitlements.plist"
codesign -d --entitlements :- "${app}" >"${app_entitlements}" 2>/dev/null
codesign -d --entitlements :- "${provider}" >"${provider_entitlements}" 2>/dev/null
plutil -lint "${app_entitlements}" "${provider_entitlements}" >/dev/null

plist_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

literal_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

assert_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local description="$4"
    local actual

    actual="$(plist_value "${plist}" "${key}")" || fail "${description}: missing ${key}"
    [[ "${actual}" == "${expected}" ]] \
        || fail "${description}: expected '${expected}', found '${actual}'"
}

app_info="${app}/Info.plist"
provider_info="${provider}/Info.plist"
app_bundle_id="$(plist_value "${app_info}" CFBundleIdentifier)"
provider_bundle_id="$(plist_value "${provider_info}" CFBundleIdentifier)"
expected_version="$(plist_value "${ROOT_DIR}/App/Info.plist" CFBundleShortVersionString)"
expected_build="$(plist_value "${ROOT_DIR}/App/Info.plist" CFBundleVersion)"

[[ "${app_bundle_id}" != com.example.* ]] || fail "example app bundle identifier reached the IPA"
[[ "${provider_bundle_id}" == "${app_bundle_id}.FileProvider" ]] \
    || fail "extension bundle identifier is not the app identifier plus .FileProvider"
assert_plist_value "${app_info}" CFBundleShortVersionString "${expected_version}" "app version"
assert_plist_value "${app_info}" CFBundleVersion "${expected_build}" "app build"
assert_plist_value "${provider_info}" CFBundleShortVersionString "${expected_version}" "extension version"
assert_plist_value "${provider_info}" CFBundleVersion "${expected_build}" "extension build"
expected_min_os="$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET *= *//p' "${ROOT_DIR}/Config/Base.xcconfig" | head -1)"
assert_plist_value "${app_info}" MinimumOSVersion "${expected_min_os}" "app minimum OS"
assert_plist_value "${provider_info}" MinimumOSVersion "${expected_min_os}" "extension minimum OS"
assert_plist_value \
    "${provider_info}" NSExtension.NSExtensionPointIdentifier \
    com.apple.fileprovider-nonui "File Provider extension point"

team="$(literal_plist_value "${app_entitlements}" com.apple.developer.team-identifier)"
[[ -n "${team}" ]] || fail "signed app Team identifier is empty"
[[ "$(literal_plist_value "${provider_entitlements}" com.apple.developer.team-identifier)" == "${team}" ]] \
    || fail "extension Team identifier differs from the app"
[[ "$(literal_plist_value "${app_entitlements}" get-task-allow)" == false ]] \
    || fail "app distribution entitlement allows debugging"
[[ "$(literal_plist_value "${provider_entitlements}" get-task-allow)" == false ]] \
    || fail "extension distribution entitlement allows debugging"
[[ "$(literal_plist_value "${app_entitlements}" application-identifier)" == "${team}.${app_bundle_id}" ]] \
    || fail "app application identifier is not bound to the signed Team"
[[ "$(literal_plist_value "${provider_entitlements}" application-identifier)" == "${team}.${provider_bundle_id}" ]] \
    || fail "extension application identifier is not bound to the signed Team"

app_group="$(literal_plist_value "${app_entitlements}" com.apple.security.application-groups:0)"
provider_app_group="$(literal_plist_value "${provider_entitlements}" com.apple.security.application-groups:0)"
[[ "${app_group}" == group.* && "${provider_app_group}" == "${app_group}" ]] \
    || fail "app and extension App Group entitlements do not match"
assert_plist_value \
    "${provider_info}" NSExtension.NSExtensionFileProviderDocumentGroup "${app_group}" \
    "File Provider document group"

app_keychain_group="$(literal_plist_value "${app_entitlements}" keychain-access-groups:0)"
provider_keychain_group="$(literal_plist_value "${provider_entitlements}" keychain-access-groups:0)"
[[ "${app_keychain_group}" == "${team}.${app_bundle_id}" ]] \
    || fail "app Keychain group is not bound to the signed Team and app identifier"
[[ "${provider_keychain_group}" == "${app_keychain_group}" ]] \
    || fail "app and extension Keychain groups do not match"
assert_plist_value "${app_info}" PsyKeychainAccessGroup "${app_keychain_group}" "app Keychain plist value"
assert_plist_value \
    "${provider_info}" PsyKeychainAccessGroup "${app_keychain_group}" \
    "extension Keychain plist value"

verify_store_profile() {
    local bundle="$1"
    local entitlements="$2"
    local label="$3"
    local profile="${temporary_directory}/${label}-profile.plist"
    local bundle_id

    [[ -f "${bundle}/embedded.mobileprovision" ]] || fail "${label} Store profile is missing"
    security cms -D -i "${bundle}/embedded.mobileprovision" >"${profile}" 2>/dev/null \
        || fail "${label} Store profile cannot be decoded"
    plutil -lint "${profile}" >/dev/null
    if plutil -extract ProvisionedDevices raw -o - "${profile}" >/dev/null 2>&1; then
        fail "${label} profile contains device provisioning"
    fi
    if [[ "$(plist_value "${profile}" ProvisionsAllDevices || true)" == true ]]; then
        fail "${label} profile is an enterprise profile"
    fi
    assert_plist_value "${profile}" TeamIdentifier.0 "${team}" "${label} profile Team"
    [[ "$(literal_plist_value "${profile}" Entitlements:get-task-allow)" == false ]] \
        || fail "${label} Store profile allows debugging"
    bundle_id="$(plist_value "${bundle}/Info.plist" CFBundleIdentifier)"
    [[ "$(literal_plist_value "${profile}" Entitlements:application-identifier)" == "${team}.${bundle_id}" ]] \
        || fail "${label} profile application identifier differs from its bundle"
    [[ "$(literal_plist_value "${entitlements}" application-identifier)" == "${team}.${bundle_id}" ]] \
        || fail "${label} signed application identifier differs from its bundle"
}

verify_store_profile "${app}" "${app_entitlements}" app
verify_store_profile "${provider}" "${provider_entitlements}" extension

assert_exact_resource() {
    local source="$1"
    local bundled="$2"
    local description="$3"

    [[ -f "${bundled}" ]] || fail "${description} is missing from the exported app"
    cmp -s "${source}" "${bundled}" || fail "${description} differs from the release checkout"
}

assert_exact_resource "${ROOT_DIR}/LICENSE" "${app}/LICENSE" "project license"
assert_exact_resource "${ROOT_DIR}/NOTICE" "${app}/NOTICE" "project notice"
assert_exact_resource \
    "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${app}/THIRD_PARTY_NOTICES.md" \
    "third-party notices"
assert_exact_resource \
    "${ROOT_DIR}/App/Resources/PrivacyInfo.xcprivacy" "${app}/PrivacyInfo.xcprivacy" \
    "app privacy manifest"
assert_exact_resource \
    "${ROOT_DIR}/FileProvider/Resources/PrivacyInfo.xcprivacy" \
    "${provider}/PrivacyInfo.xcprivacy" "extension privacy manifest"

for executable in "${app}/Psynguechthyngue" "${provider}/PsyFileProvider"; do
    architectures="$(lipo -archs "${executable}")"
    grep -Eq '(^|[[:space:]])arm64($|[[:space:]])' <<<"${architectures}" \
        || fail "arm64 is missing from ${executable}"
    linked_libraries="$(otool -L "${executable}")"
    if grep -Fq PsyBridge <<<"${linked_libraries}"; then
        fail "PsyBridge is dynamically loaded by ${executable}"
    fi
    grep -Fq /usr/lib/libresolv <<<"${linked_libraries}" \
        || fail "libresolv is missing from ${executable}"
done

expected_core_revision="$(plutil -extract tag raw -o - "${ROOT_DIR}/GoBridge/SyncthingPin.json")"
[[ -n "${expected_core_revision}" ]] || fail "pinned Syncthing tag could not be read"
app_strings="${temporary_directory}/app-strings.txt"
strings "${app}/Psynguechthyngue" >"${app_strings}"
grep -Fq "${expected_core_revision}" "${app_strings}" \
    || fail "exported app does not contain the pinned Syncthing version"

binary_uuids() {
    dwarfdump --uuid "$1" | awk '{ gsub(/[()]/, "", $3); print $2 ":" $3 }' | sort
}

app_dsym="${archive}/dSYMs/Psynguechthyngue.app.dSYM/Contents/Resources/DWARF/Psynguechthyngue"
provider_dsym="${archive}/dSYMs/PsyFileProvider.appex.dSYM/Contents/Resources/DWARF/PsyFileProvider"
[[ -f "${app_dsym}" && -f "${provider_dsym}" ]] || fail "archive dSYMs are incomplete"
[[ "$(binary_uuids "${app}/Psynguechthyngue")" == "$(binary_uuids "${app_dsym}")" ]] \
    || fail "app binary and archive dSYM UUIDs differ"
[[ "$(binary_uuids "${provider}/PsyFileProvider")" == "$(binary_uuids "${provider_dsym}")" ]] \
    || fail "extension binary and archive dSYM UUIDs differ"

printf 'App Store export verified: %s (%s), Team %s, app/extension Store signing, exact resources, static core, and dSYMs.\n' \
    "${expected_version}" "${expected_build}" "${team}"
