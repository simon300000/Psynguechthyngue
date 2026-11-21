#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
root_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$root_dir/Scripts/hermetic-go-environment.sh"
source_gate="$script_dir/verify-syncthing-source.sh"

for shell_script in "$script_dir"/*.sh; do
	bash -n "$shell_script"
done

sh "$source_gate" --prepare
GO111MODULE=off go test "$root_dir/Tools/syncthing_contract.go" "$root_dir/Tools/syncthing_contract_test.go"
bash "$script_dir/test-prepare-lock.sh"

(
	cd "$root_dir/.build/go/syncthing-readiness-v1"
	GOENV=off GOFLAGS= GOWORK=off go test -count=1 -tags noassets \
		-run '^(TestClusterConfigReceivedEventCarriesAcceptedRemoteIndexes|TestAtomicIndexIDAndSequence)$' \
		./lib/model ./internal/db/sqlite
)

cd "$core_dir"
GOENV=off GOFLAGS= GOWORK=off go mod verify
GOENV=off GOFLAGS= GOWORK=off go test -tags noassets ./...

artifact="$root_dir/Artifacts/Mobilebridge.xcframework"
sidecar="${artifact}.provenance.json"
if [ -d "$artifact" ] && [ -f "$sidecar" ]; then
	bash "$script_dir/test-xcframework-provenance.sh" "$artifact" "$sidecar" \
		"${IOS_DEPLOYMENT_TARGET:-17.0}"
elif [ -e "$artifact" ] || [ -e "$sidecar" ]; then
	echo "Mobilebridge artifact/provenance pair is incomplete; run make bootstrap" >&2
	exit 1
fi
