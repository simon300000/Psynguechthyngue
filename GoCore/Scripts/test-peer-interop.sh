#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"

readonly expected_module_version="v1.30.0-rc.1.0.20260803213605-946e2b83a1f6"
readonly expected_release="v2.1.3"
readonly expected_release_tag_object="66afbbe2c4a957a5700d20bd16ac741a0a40d6f9"
readonly expected_release_commit="946e2b83a1f6c6ae119427c09e0a5802940b82ff"
readonly default_log="/private/tmp/Psynguechthyngue-peer-interop.latest.log"

peer_tmp=$(mktemp -d /private/tmp/psynguechthyngue-peer-interop.XXXXXX)
cleanup() {
	chmod -R u+w "$peer_tmp" 2>/dev/null || true
	rm -rf -- "$peer_tmp"
}
trap cleanup EXIT

mkdir -p "$peer_tmp/runtime" "$peer_tmp/go-cache" "$peer_tmp/go-tmp"
peer_binary="$peer_tmp/syncthing"
log_path=${PEER_INTEROP_LOG:-$default_log}
go_cache="$peer_tmp/go-cache"

cd "$core_dir"
"$script_dir/verify-syncthing-source.sh" --prepare
expected_module=$("$script_dir/verify-syncthing-source.sh" --field modulePath)
locked_module_version=$("$script_dir/verify-syncthing-source.sh" --field moduleVersion)
expected_commit=$("$script_dir/verify-syncthing-source.sh" --field moduleCommit)
expected_module_sum=$("$script_dir/verify-syncthing-source.sh" --field moduleSum)
[[ "$expected_commit" == "$expected_release_commit" ]] || {
	printf 'peer interop commit is inconsistent with the pinned official release tag\n' >&2
	exit 1
}
[[ "$locked_module_version" == "$expected_module_version" ]] || {
	printf 'peer interop module version is inconsistent with the reviewed release\n' >&2
	exit 1
}
download_json="$peer_tmp/upstream-module.json"
GOENV=off GOFLAGS= GOWORK=off go mod download -json \
	"${expected_module}@${locked_module_version}" >"$download_json"
module_fields_file="$peer_tmp/upstream-module-fields"
python3 - "$download_json" >"$module_fields_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
for key in ("Path", "Version", "Sum", "Dir", "Zip"):
    value = document.get(key)
    if not isinstance(value, str) or not value or any(character in value for character in "\n\r"):
        raise SystemExit(f"invalid go mod download field: {key}")
    print(value)
PY
field_lines=$(wc -l <"$module_fields_file" | tr -d '[:space:]')
[[ "$field_lines" == "5" ]] || {
	printf 'go mod download omitted required upstream module evidence\n' >&2
	exit 1
}
{
	IFS= read -r downloaded_module
	IFS= read -r downloaded_version
	IFS= read -r downloaded_sum
	IFS= read -r downloaded_dir
	IFS= read -r downloaded_zip
} <"$module_fields_file"
[[ "$downloaded_module" == "$expected_module" ]] || {
	printf 'downloaded upstream module path drifted\n' >&2
	exit 1
}
[[ "$downloaded_version" == "$locked_module_version" ]] || {
	printf 'downloaded upstream module version drifted\n' >&2
	exit 1
}
[[ "$downloaded_sum" == "$expected_module_sum" ]] || {
	printf 'downloaded upstream module checksum drifted\n' >&2
	exit 1
}
upstream_dir="$downloaded_dir"
"$script_dir/verify-syncthing-source.sh" --verify-upstream "$downloaded_dir" "$downloaded_zip"

peer_source="$peer_tmp/upstream-source"
mkdir -- "$peer_source"
cp -R -- "$upstream_dir/." "$peer_source/"
"$script_dir/verify-syncthing-source.sh" --verify-upstream "$peer_source" "$downloaded_zip"
(
	cd "$peer_source"
	GOENV=off GOFLAGS= GOWORK=off GODEBUG= GOCACHE="$go_cache" GOTMPDIR="$peer_tmp/go-tmp" go build \
		-mod=readonly \
		-tags 'noassets,noupgrade' \
		-trimpath \
		-ldflags "-buildid= -X github.com/syncthing/syncthing/lib/build.Version=$expected_release -X github.com/syncthing/syncthing/lib/build.Stamp=0 -X github.com/syncthing/syncthing/lib/build.User=peer-interop -X github.com/syncthing/syncthing/lib/build.Host=localhost -X github.com/syncthing/syncthing/lib/build.Tags=noassets,noupgrade,source-$expected_commit" \
		-o "$peer_binary" \
		./cmd/syncthing
	GOENV=off GOFLAGS= GOWORK=off GOCACHE="$go_cache" GOTMPDIR="$peer_tmp/go-tmp" go mod verify
)
"$script_dir/verify-syncthing-source.sh" --verify-upstream "$peer_source" "$downloaded_zip"

GOENV=off GOFLAGS= GOWORK=off go mod verify >/dev/null

peer_version=$("$peer_binary" version)
if [[ "$peer_version" != *"syncthing $expected_release"* || "$peer_version" != *"$expected_commit"* ]]; then
	printf 'built peer does not attest the pinned upstream source\n' >&2
	exit 1
fi

set +e
current_test_timeout=12m
if [[ -n "${PEER_INTEROP_SMALL_FILE_COUNT:-}" ]]; then
	current_test_timeout=30m
	case "$PEER_INTEROP_SMALL_FILE_COUNT" in
		*[!0-9]*)
			printf 'PEER_INTEROP_SMALL_FILE_COUNT must be decimal digits\n' >&2
			exit 1
			;;
	esac
	if [[ "$PEER_INTEROP_SMALL_FILE_COUNT" == 0* || ${#PEER_INTEROP_SMALL_FILE_COUNT} -gt 7 ]]; then
		printf 'PEER_INTEROP_SMALL_FILE_COUNT must be canonical and between 10000 and 1000000\n' >&2
		exit 1
	fi
	peer_interop_small_file_count=$((10#$PEER_INTEROP_SMALL_FILE_COUNT))
	if ((peer_interop_small_file_count < 10000 || peer_interop_small_file_count > 1000000)); then
		printf 'PEER_INTEROP_SMALL_FILE_COUNT must be between 10000 and 1000000\n' >&2
		exit 1
	fi
	if ((peer_interop_small_file_count >= 100000)); then
		# The test itself retains separate 20-minute transfer and 10-minute
		# deletion deadlines. Leave room for identity, directional, multi-GiB,
		# restart, conflict, and malicious-frame coverage instead of letting the
		# outer Go timeout preempt those more precise failure reports. A measured
		# 100k first scan spends most of its time in the pinned core's durable SQLite
		# index; deletion must then persist the corresponding tombstones. Keep both
		# operations, the post-scan digest, and the remaining scenarios reachable.
		current_test_timeout=150m
	fi
fi
current_test_output=$(
	TMPDIR="$peer_tmp/runtime" \
	GODEBUG= \
	GOCACHE="$go_cache" \
	GOTMPDIR="$peer_tmp/go-tmp" \
	PEER_INTEROP_SYNCTHING="$peer_binary" \
	PEER_INTEROP_UPSTREAM_COMMIT="$expected_commit" \
	PEER_INTEROP_RELEASE="$expected_release" \
	PEER_INTEROP_MULTI_GIB_BYTES=2148532224 \
	PEER_INTEROP_NONSPARSE_MULTI_GIB_BYTES=2148532224 \
	PEER_INTEROP_SMALL_FILE_COUNT="${PEER_INTEROP_SMALL_FILE_COUNT:-}" \
	GOENV=off GOFLAGS= GOWORK=off go test -tags 'peerinterop noassets' -count=1 -timeout="$current_test_timeout" \
		-run '^(TestConfiguredPeerRejectsLegacyAndMalformedProtocolWithoutStoppingCore|TestPeerInterop)$' \
		-v ./integration 2>&1
)
current_test_status=$?
set -e
test_output=$current_test_output
test_status=$current_test_status

safe_output=${test_output//"$peer_tmp"/'<temporary-path>'}
safe_output=${safe_output//"$core_dir"/'<repository>/GoCore'}
safe_output=$(printf '%s' "$safe_output" | sed -E \
	-e 's/([A-Z0-9]{7}-){7}[A-Z0-9]{7}/<device-id>/g' \
	-e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
	-e 's#tcp://[^[:space:]]+#<network-address>#g' \
	-e 's#127\.0\.0\.1:[0-9]+#<network-address>#g' \
	-e 's#\[::1\]:[0-9]+#<network-address>#g' \
	-e 's#/Users/[^[:space:]]+#<host-path>#g' \
	-e 's#/private/(tmp|var)/[^[:space:]]+#<temporary-path>#g')
safe_version=${peer_version//"$peer_tmp"/'<temporary-path>'}

mkdir -p "$(dirname -- "$log_path")"
{
	printf 'source_module=%s@%s\n' "$expected_module" "$expected_module_version"
	printf 'source_commit=%s\n' "$expected_commit"
	printf 'source_release_tag=%s\n' "$expected_release"
	printf 'source_release_tag_object=%s\n' "$expected_release_tag_object"
	printf 'peer_source=lock-pinned h1-verified pristine upstream module directory and zip\n'
	printf 'peer_binary=%s\n' "$safe_version"
	printf 'network=direct tcp4 localhost; discovery relay crash-reporting upgrade gui-http disabled; usage-report route fenced to the verified-unbound loopback GUI address\n'
	printf '%s\n' "$safe_output"
} >"$log_path"

privacy_failure=
if LC_ALL=C grep -Eq \
	'(/Users/|/private/(tmp|var)/|BEGIN [A-Z ]*PRIVATE KEY|key\.pem|cert\.pem|([A-Z0-9]{7}-){7}[A-Z0-9]{7}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})' \
	"$log_path"; then
	privacy_failure=path-key-or-identity
elif LC_ALL=C grep -Eq '(tcp://|127\.0\.0\.1:[0-9]+|\[::1\]:[0-9]+)' "$log_path"; then
	privacy_failure=network-address
elif LC_ALL=C grep -Eq 'connectionI[Dd]' "$log_path"; then
	privacy_failure=raw-connection-field
fi
if [[ -n "$privacy_failure" ]]; then
	rm -f -- "$log_path"
	printf 'peer interop log failed the privacy canary check (%s)\n' "$privacy_failure" >&2
	exit 1
fi

printf '%s\n' "$safe_output"
printf 'sanitized peer interop log written\n'
exit "$test_status"
