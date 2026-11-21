#!/bin/sh
# SPDX-License-Identifier: MIT
# Source this file to validate the real login-directory identity required by
# dependencies that call os.UserHomeDir. This does not authorize HOME-backed
# caches or configuration as build inputs.

if [ "${PSY_BUILD_USER_HOME_RESOLVED:-}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

_psy_account_name=$(/usr/bin/id -un 2>/dev/null) || {
	printf 'error: could not resolve the build account name\n' >&2
	return 1 2>/dev/null || exit 1
}
_psy_account_uid=$(/usr/bin/id -u 2>/dev/null) || {
	printf 'error: could not resolve the build account UID\n' >&2
	return 1 2>/dev/null || exit 1
}
_psy_account_record=$(/usr/bin/id -P "$_psy_account_name" 2>/dev/null) || {
	printf 'error: could not read the build account record\n' >&2
	return 1 2>/dev/null || exit 1
}
_psy_record_uid=$(printf '%s\n' "$_psy_account_record" | /usr/bin/awk -F: 'NF == 10 { print $3 }')
_psy_record_directory=$(printf '%s\n' "$_psy_account_record" | /usr/bin/awk -F: 'NF == 10 { print $9 }')

[ "$_psy_record_uid" = "$_psy_account_uid" ] || {
	printf 'error: build account record UID mismatch\n' >&2
	return 1 2>/dev/null || exit 1
}
case "$_psy_record_directory" in
/*) ;;
*)
	printf 'error: build account record lacks an absolute login directory\n' >&2
	return 1 2>/dev/null || exit 1
	;;
esac
case "$_psy_record_directory" in
*'
'*|*'	'*)
	printf 'error: build account login directory contains unsupported characters\n' >&2
	return 1 2>/dev/null || exit 1
	;;
esac

_psy_record_directory=$(/bin/realpath -- "$_psy_record_directory" 2>/dev/null) || {
	printf 'error: build account login directory is unavailable\n' >&2
	return 1 2>/dev/null || exit 1
}
[ -d "$_psy_record_directory" ] && [ ! -L "$_psy_record_directory" ] || {
	printf 'error: build account login directory is unsafe\n' >&2
	return 1 2>/dev/null || exit 1
}
_psy_record_directory_uid=$(/usr/bin/stat -f '%u' "$_psy_record_directory" 2>/dev/null) || {
	printf 'error: could not inspect the build account login directory\n' >&2
	return 1 2>/dev/null || exit 1
}
[ "$_psy_record_directory_uid" = "$_psy_account_uid" ] || {
	printf 'error: build account does not own its login directory\n' >&2
	return 1 2>/dev/null || exit 1
}

_psy_inherited_directory=${HOME:-}
if [ -n "$_psy_inherited_directory" ]; then
	case "$_psy_inherited_directory" in
	/*) ;;
	*)
		printf 'error: inherited HOME is not absolute\n' >&2
		return 1 2>/dev/null || exit 1
		;;
	esac
	case "$_psy_inherited_directory" in
	*'
'*|*'	'*)
		printf 'error: inherited HOME contains unsupported characters\n' >&2
		return 1 2>/dev/null || exit 1
		;;
	esac
	_psy_inherited_directory=$(/bin/realpath -- "$_psy_inherited_directory" 2>/dev/null) || {
		printf 'error: inherited HOME is unavailable\n' >&2
		return 1 2>/dev/null || exit 1
	}
	[ "$_psy_inherited_directory" = "$_psy_record_directory" ] || {
		printf 'error: inherited HOME does not match the system account record\n' >&2
		return 1 2>/dev/null || exit 1
	}
fi

PSY_BUILD_USER_HOME=$_psy_record_directory
export PSY_BUILD_USER_HOME
readonly PSY_BUILD_USER_HOME
PSY_BUILD_USER_HOME_RESOLVED=1
readonly PSY_BUILD_USER_HOME_RESOLVED

unset \
	_psy_account_name _psy_account_uid _psy_account_record _psy_record_uid \
	_psy_record_directory _psy_record_directory_uid _psy_inherited_directory
