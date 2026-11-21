#!/bin/sh
# SPDX-License-Identifier: MIT
# Measures the restricted fetch's memory inside the iOS Simulator.
#
# 1. Builds GoBridge/integration/simfetch (Swift, links PsySync, the adapter
#    and Artifacts/PsyBridge.xcframework) for the Simulator.
# 2. Creates a throwaway Simulator device (wp-a-simfetch-*), boots it.
# 3. Runs TestSimulatorFetchFootprint: a temporary official Syncthing peer
#    (own home and ports, never the user's instance) serves a file, and the
#    probe fetches it inside the Simulator, printing phys_footprint per phase.
# 4. Deletes the device.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/psy-simfetch.XXXXXX")
udid=""
cleanup() {
	if [ -n "$udid" ]; then
		xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
		xcrun simctl delete "$udid" >/dev/null 2>&1 || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

[ -d "$repo/Artifacts/PsyBridge.xcframework" ] || "$repo/GoBridge/Scripts/build-xcframework.sh"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
target=arm64-apple-ios17.0-simulator
cd "$repo"
xcrun swiftc -sdk "$sdk" -target "$target" -O -parse-as-library -emit-module -emit-library -static \
	-module-name PsySync -o "$work/libPsySync.a" -emit-module-path "$work/PsySync.swiftmodule" \
	$(find Sources/PsySync -name '*.swift') 2>/dev/null
xcrun swiftc -sdk "$sdk" -target "$target" -O -I "$work" \
	-F Artifacts/PsyBridge.xcframework/ios-arm64_x86_64-simulator -framework PsyBridge \
	-L "$work" -lPsySync -lresolv \
	Platform/PsyBridgeAdapter.swift GoBridge/integration/simfetch/main.swift -o "$work/simfetch"

runtime=$(xcrun simctl list runtimes | awk '/^iOS/ {r=$NF} END {print r}')
# Device type of the first available iPhone on that runtime.
dtype=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
for rt, devs in json.load(sys.stdin)["devices"].items():
    if rt == sys.argv[1]:
        for x in devs:
            if x["name"].startswith("iPhone"):
                print(x["deviceTypeIdentifier"]); sys.exit()
' "$runtime")
udid=$(xcrun simctl create "wp-a-simfetch-$$" "$dtype" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null

cd "$repo/GoBridge"
PSY_SIM_UDID="$udid" PSY_SIM_FETCH_BIN="$work/simfetch" \
	go test -tags noassets -count=1 -run TestSimulatorFetchFootprint -v ./integration 2>&1 |
	grep -E "SIMFETCH|footprint|^(ok|FAIL|---)"
