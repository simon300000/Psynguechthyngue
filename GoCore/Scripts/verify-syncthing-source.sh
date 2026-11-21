#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"
contract_tool="$repo_dir/Tools/syncthing_contract.go"
contract_check="$repo_dir/Tools/syncthing_contract_check.go"
preparer="$script_dir/prepare-syncthing-source.sh"

run_contract() {
	CGO_ENABLED= GOOS= GOARCH= GO111MODULE=off GOENV=off GOFLAGS= GOWORK=off \
		go run "$contract_check" "$contract_tool" "$@" "$core_dir"
}

run_preparer() {
	CGO_ENABLED= GOOS= GOARCH= GO111MODULE=on GOENV=off GOFLAGS= GOWORK=off \
		"$preparer" "$@"
}

mode=${1:---prepare}
case "$mode" in
--preflight)
	run_contract preflight
	;;
--prepare)
	run_contract preflight
	run_preparer >/dev/null
	run_contract verify
	;;
--verify)
	run_contract verify
	;;
--json)
	run_contract json
	;;
--field)
	[ "$#" -eq 2 ] || { printf 'usage: %s --field FIELD\n' "${0##*/}" >&2; exit 64; }
	CGO_ENABLED= GOOS= GOARCH= GO111MODULE=off GOENV=off GOFLAGS= GOWORK=off \
		go run "$contract_check" "$contract_tool" field "$core_dir" "$2"
	;;
--verify-upstream)
	[ "$#" -eq 3 ] || { printf 'usage: %s --verify-upstream DIRECTORY ZIP\n' "${0##*/}" >&2; exit 64; }
	CGO_ENABLED= GOOS= GOARCH= GO111MODULE=off GOENV=off GOFLAGS= GOWORK=off \
		go run "$contract_check" "$contract_tool" upstream "$core_dir" "$2" "$3"
	;;
*)
	printf 'usage: %s --preflight | --prepare | --verify | --json | --field FIELD | --verify-upstream DIRECTORY ZIP\n' "${0##*/}" >&2
	exit 64
	;;
esac
