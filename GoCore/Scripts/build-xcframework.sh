#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

if [ -n "${PSY_XCFRAMEWORK_CACHE_ROOT:-}" ]; then
	echo "PSY_XCFRAMEWORK_CACHE_ROOT is unsupported; XCFramework builds require an isolated cache" >&2
	exit 1
fi

module_proxy_dir=${PSY_GO_MODULE_PROXY_DIR:-}
if [ -n "$module_proxy_dir" ]; then
	case "$module_proxy_dir" in
	/*) ;;
	*)
		echo "PSY_GO_MODULE_PROXY_DIR must be an absolute canonical directory" >&2
		exit 1
		;;
	esac
	if [ ! -d "$module_proxy_dir" ] || [ -L "$module_proxy_dir" ] || \
		[ "$(/bin/realpath -- "$module_proxy_dir")" != "$module_proxy_dir" ]; then
		echo "PSY_GO_MODULE_PROXY_DIR must be an absolute canonical non-symlink directory" >&2
		exit 1
	fi
	if [ -n "$(/usr/bin/find "$module_proxy_dir" \( -type l -o \! -type f \! -type d \) -print -quit)" ]; then
		echo "PSY_GO_MODULE_PROXY_DIR must contain only regular files and real directories" >&2
		exit 1
	fi
	if [ ! -d "$module_proxy_dir/sumdb/sum.golang.org/lookup" ] || \
		[ ! -d "$module_proxy_dir/sumdb/sum.golang.org/tile" ]; then
		echo "PSY_GO_MODULE_PROXY_DIR must contain the cached signed sum.golang.org lookup and tile trees" >&2
		exit 1
	fi
fi

script_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"
. "$repo_dir/Scripts/resolve-build-user-home.sh"
implementation="$script_dir/build-xcframework-impl.sh"
if [ ! -f "$implementation" ] || [ -L "$implementation" ]; then
	echo "Internal XCFramework builder is missing or unsafe" >&2
	exit 1
fi

clean_path="$PSY_GO_TOOLCHAIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
clean_tmpdir=${TMPDIR:-/tmp}
clean_deployment_target=${IOS_DEPLOYMENT_TARGET:-}
if [ -n "${DEVELOPER_DIR:-}" ]; then
	exec /usr/bin/env -i \
		PATH="$clean_path" HOME="$PSY_BUILD_USER_HOME" TMPDIR="$clean_tmpdir" \
		DEVELOPER_DIR="$DEVELOPER_DIR" LC_ALL=C LANG=C \
		PSY_GO_BINARY="$PSY_GO_BINARY" PSY_GO_BINARY_SHA256="$PSY_GO_BINARY_SHA256" \
		GO111MODULE=on GOENV=off GOFLAGS= GOWORK=off GOTOOLCHAIN=local \
		GOCACHEPROG= GOFIPS140=off GODEBUG=gocacheverify=1 GOTELEMETRY=off \
		PSY_GO_MODULE_PROXY_DIR="$module_proxy_dir" \
		IOS_DEPLOYMENT_TARGET="$clean_deployment_target" \
		PSY_XCFRAMEWORK_INTERNAL_ENTRY=1 /bin/sh "$implementation" "$@"
fi
exec /usr/bin/env -i \
	PATH="$clean_path" HOME="$PSY_BUILD_USER_HOME" TMPDIR="$clean_tmpdir" \
	LC_ALL=C LANG=C \
	PSY_GO_BINARY="$PSY_GO_BINARY" PSY_GO_BINARY_SHA256="$PSY_GO_BINARY_SHA256" \
	GO111MODULE=on GOENV=off GOFLAGS= GOWORK=off GOTOOLCHAIN=local \
	GOCACHEPROG= GOFIPS140=off GODEBUG=gocacheverify=1 GOTELEMETRY=off \
	PSY_GO_MODULE_PROXY_DIR="$module_proxy_dir" \
	IOS_DEPLOYMENT_TARGET="$clean_deployment_target" \
	PSY_XCFRAMEWORK_INTERNAL_ENTRY=1 /bin/sh "$implementation" "$@"
