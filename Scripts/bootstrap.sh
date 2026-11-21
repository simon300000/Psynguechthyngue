#!/usr/bin/env bash
# Builds Artifacts/PsyBridge.xcframework (GoBridge/psybridge, upstream Syncthing
# pinned in GoBridge/SyncthingPin.json) when it is missing or its Go inputs
# changed. The input digest is stored next to the artifact, so Xcode builds
# (PsyBridgeBootstrap target) only pay for gomobile when GoBridge changes.
#
# Usage: Scripts/bootstrap.sh [--check|--force]
#   --check  exit 1 if the artifact is missing or stale, build nothing
#   --force  rebuild unconditionally
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="${ROOT_DIR}/Artifacts/PsyBridge.xcframework"
STAMP="${ARTIFACT}.inputs.sha256"
MODE="${1:-}"

case "${MODE}" in
    ""|--check|--force) ;;
    *) echo "usage: ${0##*/} [--check|--force]" >&2; exit 64 ;;
esac

inputs_digest() {
    (
        cd "${ROOT_DIR}"
        find GoBridge/psybridge GoBridge/go.mod GoBridge/go.sum GoBridge/SyncthingPin.json \
            GoBridge/Scripts/build-xcframework.sh -type f ! -name '*_test.go' -print0 \
            | LC_ALL=C sort -z | xargs -0 shasum -a 256
    ) | shasum -a 256 | cut -d' ' -f1
}

want="$(inputs_digest)"
have="$(cat "${STAMP}" 2>/dev/null || true)"
fresh=0
[[ -d "${ARTIFACT}" && "${want}" == "${have}" ]] && fresh=1

if [[ "${MODE}" == "--check" ]]; then
    [[ ${fresh} -eq 1 ]] && { echo "PsyBridge.xcframework is up to date"; exit 0; }
    echo "PsyBridge.xcframework is missing or stale; run make bootstrap" >&2
    exit 1
fi
if [[ ${fresh} -eq 1 && "${MODE}" != "--force" ]]; then
    echo "PsyBridge.xcframework is up to date"
    exit 0
fi

command -v go >/dev/null || { echo "error: go is required to build PsyBridge.xcframework" >&2; exit 1; }
# Xcode build phases run with a minimal environment; gomobile needs the Xcode toolchain.
export PATH="/usr/local/go/bin:/opt/homebrew/bin:${PATH}"
sh "${ROOT_DIR}/GoBridge/Scripts/build-xcframework.sh" "${ARTIFACT}"
printf '%s\n' "${want}" >"${STAMP}"
