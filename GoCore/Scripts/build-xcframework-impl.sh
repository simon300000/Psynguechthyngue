#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

if [ "${PSY_XCFRAMEWORK_INTERNAL_ENTRY:-}" != 1 ]; then
	echo "build-xcframework-impl.sh is internal; use build-xcframework.sh" >&2
	exit 64
fi
unset PSY_XCFRAMEWORK_INTERNAL_ENTRY

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"
. "$repo_dir/Scripts/resolve-build-user-home.sh"
source_gate="$script_dir/verify-syncthing-source.sh"
# shellcheck source=xcframework-build-settings.sh
. "$script_dir/xcframework-build-settings.sh"

deployment_target=${IOS_DEPLOYMENT_TARGET:-$PSY_XCFRAMEWORK_DEFAULT_DEPLOYMENT_TARGET}
output=${1:-"$repo_dir/Artifacts/Mobilebridge.xcframework"}

if ! printf '%s\n' "$deployment_target" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+([.][0-9]+)?$'; then
	echo "Invalid iOS deployment target: $deployment_target" >&2
	exit 1
fi

case "$output" in
/*) ;;
*) output="$core_dir/$output" ;;
esac

sidecar="${output}.provenance.json"
output_parent=$(dirname -- "$output")
output_name=$(basename -- "$output")
if [ "$output_name" != "Mobilebridge.xcframework" ]; then
	echo "XCFramework output basename must be Mobilebridge.xcframework so gomobile preserves the audited module name" >&2
	exit 1
fi
build_lock="${output}.build-lock"
tools_dir=
tools_parent=
tools_leaf=
tools_marker=
stage_root=
build_cache_root=
sidecar_published=0
lock_held=0

valid_tools_root() {
	[ -n "${tools_dir:-}" ] && [ -n "${tools_parent:-}" ] && \
		[ -n "${tools_leaf:-}" ] && [ -n "${tools_marker:-}" ] || return 1
	case "$tools_dir" in /*) ;; *) return 1 ;; esac
	printf '%s\n' "$tools_leaf" | LC_ALL=C grep -Eq '^psy-mobilebridge-tools\.[A-Za-z0-9]+$' || return 1
	[ "$tools_dir" = "$tools_parent/$tools_leaf" ] || return 1
	[ -d "$tools_dir" ] && [ ! -L "$tools_dir" ] || return 1
	[ -f "$tools_marker" ] && [ ! -L "$tools_marker" ] || return 1
	[ "$(sed -n '1p' "$tools_marker")" = "$$" ] || return 1
}

remove_tools_root() {
	valid_tools_root || return 1
	/usr/bin/find "$tools_dir" -type d -exec /bin/chmod u+rwx {} + || return 1
	/usr/bin/find "$tools_dir" -type f -exec /bin/chmod u+rw {} + || return 1
	/bin/rm -rf -- "$tools_dir" || return 1
	[ ! -e "$tools_dir" ] && [ ! -L "$tools_dir" ]
}

cleanup() {
	cleanup_status=$?
	trap - EXIT INT TERM
	if [ "$cleanup_status" -ne 0 ] && [ "$sidecar_published" -eq 1 ] && [ ! -e "$output" ]; then
		rm -f -- "$sidecar" || true
	fi
	if [ -n "${stage_root:-}" ] && [ -d "$stage_root" ]; then
		if ! rm -rf -- "$stage_root"; then
			echo "Failed to remove the private XCFramework staging root" >&2
			[ "$cleanup_status" -ne 0 ] || cleanup_status=1
		fi
	fi
	if [ -n "${tools_dir:-}" ] && { [ -e "$tools_dir" ] || [ -L "$tools_dir" ]; }; then
		if ! remove_tools_root; then
			echo "Failed to remove the validated private XCFramework tools root" >&2
			[ "$cleanup_status" -ne 0 ] || cleanup_status=1
		fi
	fi
	if [ "$lock_held" -eq 1 ]; then
		rmdir -- "$build_lock" 2>/dev/null || true
	fi
	exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$output_parent"
if ! mkdir -- "$build_lock" 2>/dev/null; then
	echo "Another build owns the output lock: ${output_name}.build-lock" >&2
	exit 1
fi
lock_held=1

if [ -e "$output" ] || [ -L "$output" ]; then
	echo "Refusing to overwrite existing output: $output_name" >&2
	exit 1
fi
if [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
	echo "Refusing to overwrite existing provenance: ${output_name}.provenance.json" >&2
	exit 1
fi

tools_dir=$(mktemp -d "${TMPDIR:-/tmp}/psy-mobilebridge-tools.XXXXXX")
tools_dir=$(/bin/realpath -- "$tools_dir")
tools_parent=$(dirname -- "$tools_dir")
tools_leaf=$(basename -- "$tools_dir")
tools_marker="$tools_dir/.psy-mobilebridge-tools-root"
printf '%s\n' "$$" >"$tools_marker"
valid_tools_root || {
	echo "Private XCFramework tools root is unsafe" >&2
	exit 1
}
stage_root=$(mktemp -d "${output_parent}/.mobilebridge-xcframework.XXXXXX")
stage_output="${stage_root}/${output_name}"
stage_sidecar="${stage_output}.provenance.json"

# Never fall back to Go's user cache (for example ~/Library/Caches/go-build).
# Every official build uses an empty cache that is removed with tools_dir so a
# writable historical cache cannot become an unrecorded build input.
build_cache_root="$tools_dir/go-cache"
if [ -L "$build_cache_root" ]; then
	echo "Refusing symlinked XCFramework cache root" >&2
	exit 1
fi
mkdir -p \
	"$build_cache_root/go-build" \
	"$build_cache_root/go-tmp" \
	"$build_cache_root/go-path/pkg/mod" \
	"$build_cache_root/xdg-cache" \
	"$build_cache_root/xdg-config" \
	"$build_cache_root/xdg-data" \
	"$build_cache_root/xdg-state"
if [ ! -d "$build_cache_root/go-build" ] || [ -L "$build_cache_root/go-build" ] || \
	[ ! -d "$build_cache_root/go-tmp" ] || [ -L "$build_cache_root/go-tmp" ] || \
	[ ! -d "$build_cache_root/go-path" ] || [ -L "$build_cache_root/go-path" ] || \
	[ ! -d "$build_cache_root/go-path/pkg" ] || [ -L "$build_cache_root/go-path/pkg" ] || \
	[ ! -d "$build_cache_root/go-path/pkg/mod" ] || [ -L "$build_cache_root/go-path/pkg/mod" ]; then
	echo "XCFramework cache paths must be real directories" >&2
	exit 1
fi
export GOCACHE="$build_cache_root/go-build"
export GOTMPDIR="$build_cache_root/go-tmp"
export GOPATH="$build_cache_root/go-path"
export GOMODCACHE="$build_cache_root/go-path/pkg/mod"
export GOTELEMETRY=off
export XDG_CACHE_HOME="$build_cache_root/xdg-cache"
export XDG_CONFIG_HOME="$build_cache_root/xdg-config"
export XDG_DATA_HOME="$build_cache_root/xdg-data"
export XDG_STATE_HOME="$build_cache_root/xdg-state"

clang_module_cache="$tools_dir/clang-module-cache"
mkdir -p "$clang_module_cache"
export CLANG_MODULE_CACHE_PATH="$clang_module_cache"

# User workspace/compiler/linker settings are intentionally excluded from this
# pinned production build. Their values would otherwise bypass the recorded
# inputs. DEVELOPER_DIR remains supported because the selected Xcode/SDK
# versions are recorded and checked by the provenance sidecar. GOTOOLCHAIN is
# fixed by the public clean-environment wrapper.
export GO111MODULE=on
export GOENV=off
export GOFLAGS=
export GOEXPERIMENT=
export GOCACHEPROG=
export GOFIPS140=off
# The build cache above was created empty for this invocation, so production
# compilation does not need the slower historical-cache verification mode.
export GODEBUG=
export GOWORK=off
module_proxy_dir=${PSY_GO_MODULE_PROXY_DIR:-}
if [ -n "$module_proxy_dir" ]; then
	case "$module_proxy_dir" in
	/*) ;;
	*)
		echo "Internal Go module proxy path is not absolute" >&2
		exit 1
		;;
	esac
	if [ ! -d "$module_proxy_dir" ] || [ -L "$module_proxy_dir" ] || \
		[ "$(/bin/realpath -- "$module_proxy_dir")" != "$module_proxy_dir" ] || \
		[ -n "$(/usr/bin/find "$module_proxy_dir" \( -type l -o \! -type f \! -type d \) -print -quit)" ] || \
		[ ! -d "$module_proxy_dir/sumdb/sum.golang.org/lookup" ] || \
		[ ! -d "$module_proxy_dir/sumdb/sum.golang.org/tile" ]; then
		echo "Internal Go module proxy path is unsafe" >&2
		exit 1
	fi
	export GOPROXY="file://$module_proxy_dir"
	# Keep checksum verification enabled without permitting a network fallback.
	# Go verifies the cached lookup records and Merkle tiles with the embedded
	# sum.golang.org public key, including metadata loaded by gomobile's
	# temporary binding module that is not necessarily present in the root sum.
	export GOSUMDB="sum.golang.org file://$module_proxy_dir/sumdb/sum.golang.org"
else
	unset GOPROXY GOSUMDB
fi
unset \
	GOOS GOARCH GO386 GOARM GOARM64 GOAMD64 GOMIPS GOMIPS64 GOPPC64 GORISCV64 GOWASM \
	CGO_ENABLED CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS \
	CC CXX AR FC SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET \
	TVOS_DEPLOYMENT_TARGET WATCHOS_DEPLOYMENT_TARGET XROS_DEPLOYMENT_TARGET \
	DRIVERKIT_DEPLOYMENT_TARGET \
	SOURCE_DATE_EPOCH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
	LIBRARY_PATH PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
	SWIFT_MODULE_CACHE_PATH MODULE_CACHE_DIR CCACHE CCACHE_DIR CCACHE_BASEDIR \
	CCACHE_PREFIX CCACHE_PATH CCACHE_CONFIGPATH SCCACHE SCCACHE_DIR SCCACHE_CACHE_SIZE

sh "$source_gate" --prepare
source_hash_before=$(bash "$script_dir/xcframework-provenance.sh" source-hash)

cd "$core_dir"
go mod verify
host_sdk=$(xcrun --sdk macosx --show-sdk-path)
if [ ! -d "$host_sdk" ]; then
	echo "Xcode did not return a usable macOS SDK for host contract tests" >&2
	exit 1
fi
host_cc=$(xcrun --sdk macosx --find clang)
host_cxx=$(xcrun --sdk macosx --find clang++)
if [ ! -x "$host_cc" ] || [ ! -x "$host_cxx" ]; then
	echo "Xcode did not return usable macOS compilers for host contract tests" >&2
	exit 1
fi
SDKROOT="$host_sdk" CC="$host_cc" CXX="$host_cxx" \
	go test -tags "$PSY_XCFRAMEWORK_BUILD_TAGS" ./...

# Current gomobile locates gobind through PATH. Build that executable from the
# same pinned x/mobile module instead of installing an unpinned global copy.
go build -trimpath -o "$tools_dir/gobind" golang.org/x/mobile/cmd/gobind
gomobile_attempt=1
gomobile_max_attempts=4
while :; do
	if PATH="$tools_dir:$PATH" go tool gomobile bind \
		-target="$PSY_XCFRAMEWORK_TARGET" \
		-iosversion="$deployment_target" \
		-tags="$PSY_XCFRAMEWORK_BUILD_TAGS" \
		-trimpath \
		-ldflags="$PSY_XCFRAMEWORK_LDFLAGS" \
		-o "$stage_output" \
		./mobilebridge; then
		break
	fi
	if [ "$gomobile_attempt" -ge "$gomobile_max_attempts" ]; then
		echo "gomobile bind failed after ${gomobile_attempt} isolated-cache attempts" >&2
		exit 1
	fi
	case "$stage_output" in
	"$stage_root"/*) ;;
	*)
		echo "Refusing to clean an XCFramework retry outside the private staging root" >&2
		exit 1
		;;
	esac
	if [ -e "$stage_output" ] || [ -L "$stage_output" ]; then
		rm -rf -- "$stage_output"
	fi
	echo "gomobile bind attempt ${gomobile_attempt} failed; retrying with this invocation's verified module cache" >&2
	sleep $((gomobile_attempt * 2))
	gomobile_attempt=$((gomobile_attempt + 1))
done

simulator_framework_dir="$stage_output/ios-arm64_x86_64-simulator"
device_framework_dir="$stage_output/ios-arm64"
if [ ! -d "$device_framework_dir/Mobilebridge.framework" ] || \
	[ ! -d "$simulator_framework_dir/Mobilebridge.framework" ]; then
	echo "gomobile did not produce both required iOS device and Simulator framework slices" >&2
	/usr/bin/find "$stage_output" -maxdepth 3 -print >&2
	exit 1
fi
swift_module_cache="$tools_dir/swift-module-cache"
swift_smoke_binary="$tools_dir/mobilebridge-swift-smoke"
mkdir -p "$swift_module_cache"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc \
	-typecheck \
	-module-cache-path "$swift_module_cache" \
	-sdk "$simulator_sdk" \
	-target "arm64-apple-ios${deployment_target}-simulator" \
	-F "$simulator_framework_dir" \
	"$script_dir/swift-smoke.swift"
xcrun swiftc \
	-module-cache-path "$swift_module_cache" \
	-sdk "$simulator_sdk" \
	-target "arm64-apple-ios${deployment_target}-simulator" \
	-F "$simulator_framework_dir" \
	"$script_dir/swift-smoke.swift" \
	-framework Mobilebridge \
	-Xlinker -lresolv \
	-o "$swift_smoke_binary"

source_hash_after=$(bash "$script_dir/xcframework-provenance.sh" source-hash)
if [ "$source_hash_before" != "$source_hash_after" ]; then
	echo "GoCore production inputs changed while the XCFramework was building" >&2
	exit 1
fi

bash "$script_dir/xcframework-provenance.sh" \
	write "$stage_output" "$stage_sidecar" "$deployment_target" "$source_hash_before"
bash "$script_dir/xcframework-provenance.sh" \
	verify "$stage_output" "$stage_sidecar" "$deployment_target"

# Publish only a complete, verified pair. This command never removes or
# overwrites an existing artifact; bootstrap owns replacement transactions.
if [ -e "$output" ] || [ -L "$output" ] || [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
	echo "Output appeared while the verified XCFramework was being built; refusing to overwrite it" >&2
	exit 1
fi
mv -- "$stage_sidecar" "$sidecar"
sidecar_published=1
if ! mv -- "$stage_output" "$output"; then
	rm -f -- "$sidecar"
	sidecar_published=0
	echo "Failed to publish verified XCFramework" >&2
	exit 1
fi

echo "Built and provenance-verified $output_name"
echo "Source SHA-256: $source_hash_before"
echo "Verified Swift import and link for iOS ${deployment_target} simulator"
echo "Xcode targets importing this XCFramework must link libresolv."
