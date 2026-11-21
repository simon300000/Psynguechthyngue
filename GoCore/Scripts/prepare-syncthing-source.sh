#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"
patch_file="$core_dir/Patches/syncthing-cluster-index-readiness.patch"
patch_sha256=35020f4d9348ae14b16533df4902bc40f8fb67ef037436475d586074e569924b
module_path=github.com/syncthing/syncthing
module_version=v1.30.0-rc.1.0.20260803213605-946e2b83a1f6
module_commit=946e2b83a1f6c6ae119427c09e0a5802940b82ff
module_sum='h1:oVMlcznG5M2ueQq7LUkPPDgJ5w/usFpJ2sQj/OfCuA0='
patched_tree_sha256=f98acbde22b8e84f575567950f92b9d66ed4cf021ad363f17e7df9c13565fafd
generated_name=syncthing-readiness-v1
lock_leaf=syncthing-readiness-v1.lock
generated_parent="$repo_dir/.build/go"
generated_dir="$generated_parent/syncthing-readiness-v1"
generated_output="$generated_dir"
lock_file="$generated_parent/$lock_leaf"

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

locked=0
if [ "${1:-}" = "--locked" ]; then
	locked=1
	mode=${2:-}
	[ "${PSY_SYNCTHING_PREPARE_LOCK_FD:-}" = 3 ] || fail "internal locked mode requires an inherited kernel lock"
	[ "${PSY_SYNCTHING_PREPARE_PARENT_FD:-}" = 4 ] || fail "internal locked mode requires an inherited preparation parent"
	lock_verifier=${PSY_SYNCTHING_PREPARE_LOCK_VERIFIER:-}
	[ -n "$lock_verifier" ] && [ -x "$lock_verifier" ] || fail "internal locked mode requires the audited lock verifier"
	"$lock_verifier" --verify-inherited "$lock_leaf" || fail "verify inherited kernel lock"
	# The helper has fchdir'd to its descriptor-bound generated parent. Keep all
	# mutable publication paths relative to that inode for the entire body.
	generated_parent=.
	generated_dir=$generated_name
	lock_file=$lock_leaf
else
	mode=${1:-}
fi
case "$mode" in
''|--print-generated-dir|--print-upstream-dir) ;;
*) fail "unsupported argument" ;;
esac

emit_result() {
	case "$mode" in
	--print-generated-dir) printf '%s\n' "$generated_output" ;;
	--print-upstream-dir) printf '%s\n' "$upstream_dir" ;;
	'') printf 'Prepared audited Syncthing readiness source %s\n' "$patched_tree_sha256" ;;
	esac
}

tree_hash() {
	tree_dir=$1
	manifest=$(mktemp)
	if find "$tree_dir" ! -type d ! -type f -print -quit | grep -q . || find "$tree_dir" -type d -empty -print -quit | grep -q .; then
		rm -f -- "$manifest"
		return 1
	fi
	(
		cd "$tree_dir"
		find . -type f -print | LC_ALL=C sort | while IFS= read -r relative_path; do
			case "$relative_path" in *'\n'*|*'\t'*) exit 9 ;; esac
			digest=$(shasum -a 256 "$relative_path" | awk '{print $1}')
			bytes=$(wc -c <"$relative_path" | tr -d '[:space:]')
			printf '%s\t%s\t%s\n' "$digest" "$bytes" "${relative_path#./}"
		done
	) >"$manifest" || {
		rm -f -- "$manifest"
		return 1
	}
	shasum -a 256 "$manifest" | awk '{print $1}'
	rm -f -- "$manifest"
}

verify_patch() {
	[ -f "$patch_file" ] && [ ! -L "$patch_file" ] || return 1
	[ "$(shasum -a 256 "$patch_file" | awk '{print $1}')" = "$patch_sha256" ]
}

valid_generated_tree() {
	[ -d "$generated_dir" ] && [ ! -L "$generated_dir" ] || return 1
	[ "$(tree_hash "$generated_dir")" = "$patched_tree_sha256" ]
}

verify_patch || fail "audited Syncthing readiness patch identity drift"

if valid_generated_tree; then
	if [ "$mode" != "--print-upstream-dir" ]; then
		emit_result
		exit 0
	fi
fi

if [ "$locked" -eq 0 ] && [ "$mode" != "--print-upstream-dir" ]; then
	cd "$repo_dir"
	exec env GOENV=off GOFLAGS= GOWORK=off GO111MODULE=off CGO_ENABLED=0 GOTOOLCHAIN=local \
		PSY_PREPARELOCK_TEST_ACQUIRED_FILE= PSY_PREPARELOCK_TEST_RELEASE_FILE= \
		"$PSY_GO_BINARY" run ./GoCore/Tools/preparelock --timeout=60s .build/go "$lock_leaf" \
		/bin/sh "$script_dir/prepare-syncthing-source.sh" --locked "$mode"
fi

download_json=$(mktemp)
stage_dir=
previous_dir=
cleanup() {
	rm -f -- "$download_json"
	if [ -n "${stage_dir:-}" ] && [ -d "$stage_dir" ]; then
		rm -rf -- "$stage_dir"
	fi
	if [ -n "${previous_dir:-}" ] && [ -d "$previous_dir" ]; then
		if [ ! -e "$generated_dir" ] && [ ! -L "$generated_dir" ]; then
			mv -- "$previous_dir" "$generated_dir" 2>/dev/null || true
		elif valid_generated_tree; then
			rm -rf -- "$previous_dir"
		fi
	fi
}
trap cleanup EXIT INT TERM

(
	cd "$core_dir"
	env GOENV=off GOFLAGS= GOWORK=off GO111MODULE=on GOTOOLCHAIN=local \
		go mod download -json "$module_path@$module_version"
) >"$download_json" || fail "download exact Syncthing module"
downloaded_path=$(awk -F'"' '$2 == "Path" {print $4; exit}' "$download_json")
downloaded_version=$(awk -F'"' '$2 == "Version" {print $4; exit}' "$download_json")
downloaded_sum=$(awk -F'"' '$2 == "Sum" {print $4; exit}' "$download_json")
upstream_dir=$(awk -F'"' '$2 == "Dir" {print $4; exit}' "$download_json")
[ "$downloaded_path" = "$module_path" ] || fail "downloaded module path drift"
[ "$downloaded_version" = "$module_version" ] || fail "downloaded module version drift"
[ "$downloaded_sum" = "$module_sum" ] || fail "downloaded module checksum drift"
grep -F "\"Hash\": \"$module_commit\"" "$download_json" >/dev/null || fail "downloaded module origin drift"
[ -d "$upstream_dir" ] && [ ! -L "$upstream_dir" ] || fail "downloaded module source is unavailable or unsafe"

if [ "$mode" = "--print-upstream-dir" ]; then
	emit_result
	exit 0
fi

if valid_generated_tree; then
	emit_result
	exit 0
fi
if [ -L "$generated_dir" ] || { [ -e "$generated_dir" ] && [ ! -d "$generated_dir" ]; }; then
	fail "generated Syncthing source has an unsafe type"
fi
stage_dir=$(mktemp -d "./.syncthing-readiness-v1.XXXXXX")
cp -R "$upstream_dir"/. "$stage_dir/"
chmod -R u+w "$stage_dir"
(
	cd "$stage_dir"
	patch -s -p1 <"$patch_file"
) || fail "apply audited Syncthing readiness patch"
[ "$(tree_hash "$stage_dir")" = "$patched_tree_sha256" ] || fail "patched Syncthing tree hash drift"
if [ -d "$generated_dir" ]; then
	previous_dir=$(mktemp -d "./.syncthing-readiness-v1.previous.XXXXXX")
	rmdir -- "$previous_dir"
	mv -- "$generated_dir" "$previous_dir" || fail "quarantine stale generated Syncthing source"
fi
if ! mv -- "$stage_dir" "$generated_dir"; then
	if [ -n "$previous_dir" ] && [ -d "$previous_dir" ]; then
		mv -- "$previous_dir" "$generated_dir" 2>/dev/null || true
		previous_dir=
	fi
	fail "publish audited Syncthing readiness source"
fi
stage_dir=
if [ -n "$previous_dir" ]; then
	rm -rf -- "$previous_dir"
	previous_dir=
fi
emit_result
