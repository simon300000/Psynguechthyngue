#!/bin/sh
# SPDX-License-Identifier: MIT
# Builds Artifacts/PsyBridge.xcframework (iOS device + iOS Simulator slices;
# Designed-for-iPad on Mac uses the iOS device slice) from GoBridge/psybridge
# with gomobile, stamping upstream build.Version from SyncthingPin.json.
#
# Usage: GoBridge/Scripts/build-xcframework.sh [output.xcframework]
# Env:   IOS_DEPLOYMENT_TARGET (default 17.0)
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bridge_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$bridge_dir/.." && pwd)
output=${1:-"$repo_dir/Artifacts/PsyBridge.xcframework"}
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
if [ "$(basename -- "$output")" != "PsyBridge.xcframework" ]; then
	echo "output must be named PsyBridge.xcframework (gomobile derives the module name from it)" >&2
	exit 64
fi
deployment_target=${IOS_DEPLOYMENT_TARGET:-17.0}

pin="$bridge_dir/SyncthingPin.json"
tag=$(/usr/bin/plutil -extract tag raw -o - "$pin")
module_version=$(/usr/bin/plutil -extract moduleVersion raw -o - "$pin")
commit=$(/usr/bin/plutil -extract commit raw -o - "$pin")
if ! grep -q "github.com/syncthing/syncthing $module_version\$" "$bridge_dir/go.mod"; then
	echo "go.mod does not pin $module_version from SyncthingPin.json" >&2
	exit 1
fi

tools=$(mktemp -d "${TMPDIR:-/tmp}/psybridge-tools.XXXXXX")
stage=$(mktemp -d "$(dirname -- "$output")/.psybridge-build.XXXXXX" 2>/dev/null || { mkdir -p "$(dirname -- "$output")"; mktemp -d "$(dirname -- "$output")/.psybridge-build.XXXXXX"; })
trap 'rm -rf "$tools" "$stage"' EXIT INT TERM

cd "$bridge_dir"
export GOFLAGS=-mod=readonly GOWORK=off GOTELEMETRY=off
go build -o "$tools/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$tools:$PATH"

ldflags="-s -w -X github.com/syncthing/syncthing/lib/build.Version=$tag"
echo "gomobile bind: syncthing $tag ($commit), iOS $deployment_target"
gomobile bind \
	-target=ios,iossimulator \
	-iosversion="$deployment_target" \
	-tags=noassets \
	-trimpath \
	-ldflags="$ldflags" \
	-o "$stage/PsyBridge.xcframework" \
	./psybridge

cat >"$stage/PsyBridge.xcframework.provenance.json" <<JSON
{
  "bridgeAPIVersion": 2,
  "syncthingTag": "$tag",
  "syncthingCommit": "$commit",
  "syncthingModuleVersion": "$module_version",
  "patches": [],
  "buildTags": ["noassets"],
  "iosDeploymentTarget": "$deployment_target",
  "go": "$(go env GOVERSION)",
  "bridgeSourceCommit": "$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)",
  "bridgeSourceDirty": $( [ -z "$(git -C "$repo_dir" status --porcelain -- GoBridge 2>/dev/null)" ] && echo false || echo true )
}
JSON

rm -rf "$output" "$output.provenance.json"
mv "$stage/PsyBridge.xcframework" "$output"
mv "$stage/PsyBridge.xcframework.provenance.json" "$output.provenance.json"
echo "built $output"
