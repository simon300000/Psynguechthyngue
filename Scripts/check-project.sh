#!/usr/bin/env bash
# Repository sanity: the Xcode project is exactly what the generator emits,
# removed components stay removed, and configuration files are present.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

for f in Package.swift Config/Base.xcconfig Config/CI.xcconfig Config/UITests.xcconfig \
    App/Info.plist App/Psynguechthyngue.entitlements FileProvider/Info.plist \
    FileProvider/PsyFileProvider.entitlements Platform/PsyBridgeAdapter.swift \
    GoBridge/go.mod GoBridge/SyncthingPin.json LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
    [[ -f "${ROOT_DIR}/${f}" ]] || fail "missing ${f}"
done

for gone in GoCore Sources/PsyCore Tests/PsyCoreTests Platform/GoCoreClient.swift; do
    [[ ! -e "${ROOT_DIR}/${gone}" ]] || fail "${gone} was removed and must not come back"
done

# No live references to the removed stack (docs archive and design history excepted).
hits="$(cd "${ROOT_DIR}" && git grep -n -I -i -E 'psycore|mobilebridge' -- \
    . ':!Docs' ':!Scripts/check-project.sh' ':!Sources/PsySync/Files/*.swift' \
    ':!Sources/PsySync/Live/KeychainIdentityStore.swift' 2>/dev/null || true)"
[[ -z "${hits}" ]] || { printf '%s\n' "${hits}" >&2; fail "references to PsyCore/mobilebridge remain"; }

# The committed project must equal the generator output.
command -v ruby >/dev/null || fail "ruby (with the xcodeproj gem) is required"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/psy-xcodeproj.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
PSY_XCODEPROJ_PATH="${tmp}/Psynguechthyngue.xcodeproj" ruby "${ROOT_DIR}/Scripts/generate-xcodeproj.rb" >/dev/null 2>&1 \
    || fail "Scripts/generate-xcodeproj.rb failed"
if ! out="$(diff -r "${tmp}/Psynguechthyngue.xcodeproj" "${ROOT_DIR}/Psynguechthyngue.xcodeproj" \
    -x xcuserdata -x project.xcworkspace)"; then
    printf '%s\n' "${out}" | head -40 >&2
    fail "Psynguechthyngue.xcodeproj is stale (or the xcodeproj gem is not 1.23.0); run: ruby Scripts/generate-xcodeproj.rb"
fi

printf 'Project and repository sanity passed.\n'
