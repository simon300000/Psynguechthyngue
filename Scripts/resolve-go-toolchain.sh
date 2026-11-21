#!/bin/sh
# SPDX-License-Identifier: MIT
# Source this file to select and pin the host Go executable used by official
# build and verification scripts.

if [ "${PSY_GO_TOOLCHAIN_RESOLVED:-}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

_psy_go_minimum_major=1
_psy_go_minimum_minor=25
_psy_go_selected=
_psy_go_selected_version=
_psy_go_last_version=
_psy_go_expected_sha256=${PSY_GO_BINARY_SHA256:-}

_psy_go_reject() {
	printf 'error: %s\n' "$1" >&2
	return 1
}

_psy_go_canonical_path() {
	_psy_go_path=$1
	case "$_psy_go_path" in
	/*) ;;
	*) return 1 ;;
	esac
	case "$_psy_go_path" in
	*'
'*|*'	'*) return 1 ;;
	esac
	_psy_go_path=$(/bin/realpath -- "$_psy_go_path" 2>/dev/null) || return 1
	case "$_psy_go_path" in
	/*) ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$_psy_go_path" | /usr/bin/grep -Eq '^/[A-Za-z0-9/._+@%=-]+$' || return 1
	[ -f "$_psy_go_path" ] && [ ! -L "$_psy_go_path" ] && [ -x "$_psy_go_path" ] || return 1
	printf '%s\n' "$_psy_go_path"
}

_psy_go_version_is_supported() {
	_psy_go_version=$1
	printf '%s\n' "$_psy_go_version" | /usr/bin/grep -Eq '^go[0-9]+\.[0-9]+(\.[0-9]+)?$' || return 1
	_psy_go_numbers=${_psy_go_version#go}
	_psy_go_major=${_psy_go_numbers%%.*}
	_psy_go_remainder=${_psy_go_numbers#*.}
	_psy_go_minor=${_psy_go_remainder%%.*}
	[ "$_psy_go_major" -gt "$_psy_go_minimum_major" ] || {
		[ "$_psy_go_major" -eq "$_psy_go_minimum_major" ] &&
			[ "$_psy_go_minor" -ge "$_psy_go_minimum_minor" ]
	}
}

_psy_go_try_candidate() {
	_psy_go_candidate=$(_psy_go_canonical_path "$1") || return 1
	_psy_go_version=$(
		/usr/bin/env -i \
			PATH=/usr/bin:/bin:/usr/sbin:/sbin \
			TMPDIR=/tmp LC_ALL=C LANG=C \
			GO111MODULE=on GOENV=off GOFLAGS= GOWORK=off GOTOOLCHAIN=local \
			GOEXPERIMENT= GOCACHEPROG= GOFIPS140=off GODEBUG= GOTELEMETRY=off \
			"$_psy_go_candidate" env GOVERSION 2>/dev/null
	) || return 1
	if printf '%s\n' "$_psy_go_version" | /usr/bin/grep -Eq '^go[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
		_psy_go_last_version=$_psy_go_version
	else
		_psy_go_last_version=
	fi
	_psy_go_version_is_supported "$_psy_go_version" || return 1
	_psy_go_selected=$_psy_go_candidate
	_psy_go_selected_version=$_psy_go_version
	return 0
}

_psy_go_explicit=
if [ -n "${PSY_GO_BINARY:-}" ] && [ -n "${GO:-}" ] && [ "$PSY_GO_BINARY" != "$GO" ]; then
	_psy_go_reject 'PSY_GO_BINARY and GO select different Go executables'
	return 1 2>/dev/null || exit 1
elif [ -n "${PSY_GO_BINARY:-}" ]; then
	_psy_go_explicit=$PSY_GO_BINARY
elif [ -n "${GO:-}" ]; then
	_psy_go_explicit=$GO
fi

if [ -n "$_psy_go_explicit" ]; then
	case "$_psy_go_explicit" in
	/*) ;;
	*)
		_psy_go_reject 'the explicit Go executable must be an absolute path'
		return 1 2>/dev/null || exit 1
		;;
	esac
	if ! _psy_go_try_candidate "$_psy_go_explicit"; then
		_psy_go_found=${_psy_go_last_version:-unavailable}
		_psy_go_reject "Go 1.25 or newer is required (found: $_psy_go_found)"
		return 1 2>/dev/null || exit 1
	fi
else
	_psy_go_path_remainder=${PATH:-}
	while :; do
		case "$_psy_go_path_remainder" in
		*:*)
			_psy_go_directory=${_psy_go_path_remainder%%:*}
			_psy_go_path_remainder=${_psy_go_path_remainder#*:}
			_psy_go_path_done=0
			;;
		*)
			_psy_go_directory=$_psy_go_path_remainder
			_psy_go_path_remainder=
			_psy_go_path_done=1
			;;
		esac
		if [ -z "$_psy_go_directory" ]; then
			[ "$_psy_go_path_done" -eq 1 ] && break
			continue
		fi
		case "$_psy_go_directory" in
		/*) ;;
		*)
			[ "$_psy_go_path_done" -eq 1 ] && break
			continue
			;;
		esac
		if _psy_go_try_candidate "$_psy_go_directory/go"; then
			break
		fi
		[ "$_psy_go_path_done" -eq 1 ] && break
	done

	if [ -z "$_psy_go_selected" ]; then
		_psy_go_host_arch=$(/usr/bin/uname -m 2>/dev/null || true)
		case "$_psy_go_host_arch" in
		arm64) _psy_go_homebrew=/opt/homebrew/bin/go ;;
		x86_64) _psy_go_homebrew=/usr/local/bin/go ;;
		*) _psy_go_homebrew= ;;
		esac
		if [ -n "$_psy_go_homebrew" ]; then
			_psy_go_try_candidate "$_psy_go_homebrew" || true
		fi
	fi

	if [ -z "$_psy_go_selected" ]; then
		_psy_go_found=${_psy_go_last_version:-unavailable}
		_psy_go_reject "Go 1.25 or newer is required (found: $_psy_go_found)"
		return 1 2>/dev/null || exit 1
	fi
fi

_psy_go_initial_path=$_psy_go_selected
_psy_go_initial_version=$_psy_go_selected_version
_psy_go_sha256=$(/usr/bin/shasum -a 256 "$_psy_go_initial_path" | /usr/bin/awk '{print $1}') || {
	_psy_go_reject 'could not hash the resolved Go executable'
	return 1 2>/dev/null || exit 1
}
_psy_go_try_candidate "$_psy_go_initial_path" || {
	_psy_go_reject 'resolved Go executable changed after version validation'
	return 1 2>/dev/null || exit 1
}
[ "$_psy_go_selected" = "$_psy_go_initial_path" ] &&
	[ "$_psy_go_selected_version" = "$_psy_go_initial_version" ] || {
	_psy_go_reject 'resolved Go executable changed after version validation'
	return 1 2>/dev/null || exit 1
}
_psy_go_sha256_after=$(/usr/bin/shasum -a 256 "$_psy_go_selected" | /usr/bin/awk '{print $1}') || {
	_psy_go_reject 'could not recheck the resolved Go executable'
	return 1 2>/dev/null || exit 1
}
[ "$_psy_go_sha256_after" = "$_psy_go_sha256" ] || {
	_psy_go_reject 'resolved Go executable changed during selection'
	return 1 2>/dev/null || exit 1
}
printf '%s\n' "$_psy_go_sha256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' || {
	_psy_go_reject 'resolved Go executable hash is malformed'
	return 1 2>/dev/null || exit 1
}
if [ -n "$_psy_go_expected_sha256" ] && [ "$_psy_go_sha256" != "$_psy_go_expected_sha256" ]; then
	_psy_go_reject 'resolved Go executable changed after selection'
	return 1 2>/dev/null || exit 1
fi

PSY_GO_BINARY=$_psy_go_selected
PSY_GO_VERSION=$_psy_go_selected_version
PSY_GO_BINARY_SHA256=$_psy_go_sha256
PSY_GO_TOOLCHAIN_DIR=${PSY_GO_BINARY%/*}
GO=$PSY_GO_BINARY
export PSY_GO_BINARY PSY_GO_VERSION PSY_GO_BINARY_SHA256 PSY_GO_TOOLCHAIN_DIR GO
readonly PSY_GO_BINARY PSY_GO_VERSION PSY_GO_BINARY_SHA256 PSY_GO_TOOLCHAIN_DIR
PSY_GO_TOOLCHAIN_RESOLVED=1
readonly PSY_GO_TOOLCHAIN_RESOLVED

unset \
	_psy_go_minimum_major _psy_go_minimum_minor _psy_go_selected \
	_psy_go_selected_version _psy_go_last_version _psy_go_expected_sha256 \
	_psy_go_explicit _psy_go_directory _psy_go_host_arch \
	_psy_go_homebrew _psy_go_sha256 _psy_go_path _psy_go_candidate \
	_psy_go_version _psy_go_numbers _psy_go_major _psy_go_remainder \
	_psy_go_minor _psy_go_found _psy_go_path_remainder _psy_go_path_done \
	_psy_go_initial_path _psy_go_initial_version _psy_go_sha256_after
