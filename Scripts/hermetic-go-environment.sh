#!/bin/sh
# SPDX-License-Identifier: MIT
# Source this file before any official consumer invokes the host Go toolchain.

_psy_hermetic_source=${BASH_SOURCE:-}
_psy_hermetic_first_arg=${1:-}
if [ -z "$_psy_hermetic_source" ] && [ "${_psy_hermetic_first_arg##*/}" = hermetic-go-environment.sh ] && [ -f "$_psy_hermetic_first_arg" ]; then
	_psy_hermetic_source=$_psy_hermetic_first_arg
fi
if [ -z "$_psy_hermetic_source" ]; then
	_psy_hermetic_consumer_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_psy_hermetic_consumer_dir/resolve-go-toolchain.sh" ]; then
		_psy_hermetic_source="$_psy_hermetic_consumer_dir/hermetic-go-environment.sh"
	elif [ -f "$_psy_hermetic_consumer_dir/../../Scripts/resolve-go-toolchain.sh" ]; then
		_psy_hermetic_source="$_psy_hermetic_consumer_dir/../../Scripts/hermetic-go-environment.sh"
	else
		printf 'error: could not locate the audited Go resolver\n' >&2
		return 1 2>/dev/null || exit 1
	fi
fi
_psy_hermetic_script_dir=$(CDPATH= cd -- "$(dirname -- "$_psy_hermetic_source")" && pwd)
. "$_psy_hermetic_script_dir/resolve-go-toolchain.sh"
unset _psy_hermetic_source _psy_hermetic_first_arg _psy_hermetic_consumer_dir _psy_hermetic_script_dir

GO111MODULE=on
GOENV=off
GOFLAGS=
GOWORK=off
GOTOOLCHAIN=local
GOEXPERIMENT=
GOCACHEPROG=
GOFIPS140=off
GODEBUG=gocacheverify=1
GOTELEMETRY=off
export \
	GO111MODULE GOENV GOFLAGS GOWORK GOTOOLCHAIN GOEXPERIMENT \
	GOCACHEPROG GOFIPS140 GODEBUG GOTELEMETRY

unset \
	GOOS GOARCH GO386 GOARM GOARM64 GOAMD64 GOMIPS GOMIPS64 GOPPC64 GORISCV64 GOWASM \
	CGO_ENABLED CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS \
	CC CXX AR FC SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET \
	TVOS_DEPLOYMENT_TARGET WATCHOS_DEPLOYMENT_TARGET XROS_DEPLOYMENT_TARGET \
	DRIVERKIT_DEPLOYMENT_TARGET CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH \
	OBJC_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR \
	PKG_CONFIG_SYSROOT_DIR CLANG_MODULE_CACHE_PATH SWIFT_MODULE_CACHE_PATH \
	MODULE_CACHE_DIR CCACHE CCACHE_DIR CCACHE_BASEDIR CCACHE_PREFIX CCACHE_PATH \
	CCACHE_CONFIGPATH SCCACHE SCCACHE_DIR SCCACHE_CACHE_SIZE CFLAGS CPPFLAGS CXXFLAGS \
	LDFLAGS XCODE_XCCONFIG_FILE TOOLCHAINS ARCHS VALID_ARCHS EXCLUDED_ARCHS \
	OTHER_CFLAGS OTHER_CPLUSPLUSFLAGS OTHER_LDFLAGS HEADER_SEARCH_PATHS \
	LIBRARY_SEARCH_PATHS FRAMEWORK_SEARCH_PATHS \
	GOPROXY GONOPROXY GOPRIVATE GONOSUMDB GOSUMDB GOVCS GOAUTH GOINSECURE \
	GOROOT GOROOT_FINAL GO_EXTLINK_ENABLED CGO_FFLAGS COMPILER_PATH GCC_EXEC_PREFIX \
	DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
	DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH LD_PRELOAD

go() {
	"$PSY_GO_BINARY" "$@"
}
