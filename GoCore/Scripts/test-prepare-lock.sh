#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
core_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(CDPATH= cd -- "$core_dir/.." && pwd)
. "$repo_dir/Scripts/hermetic-go-environment.sh"
test_dir_raw=$(mktemp -d)
test_dir=$(CDPATH= cd -- "$test_dir_raw" && pwd -P)
case "$test_dir" in
/private/tmp/*|/tmp/*|/private/var/folders/*) ;;
*) printf 'error: unsafe temporary directory: %s\n' "$test_dir" >&2; exit 1 ;;
esac

background_pids=
release_markers=
cleanup() {
	for marker in $release_markers; do
		: >"$marker" 2>/dev/null || true
	done
	sleep 0.1
	for pid in $background_pids; do
		kill -TERM "$pid" 2>/dev/null || true
	done
	sleep 0.05
	for pid in $background_pids; do
		kill -KILL "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -rf -- "$test_dir"
}
trap cleanup EXIT INT TERM

helper="$test_dir/preparelock"
(
	cd "$core_dir/.."
	env GOENV=off GOFLAGS= GOWORK=off GO111MODULE=off CGO_ENABLED=0 GOTOOLCHAIN=local \
		go build -tags preparelocktest -o "$helper" ./GoCore/Tools/preparelock
)

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

expect_failure() {
	label=$1
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$label was accepted"
	fi
}

wait_for_file() {
	file=$1
	remaining=${2:-250}
	while [ ! -e "$file" ]; do
		remaining=$((remaining - 1))
		[ "$remaining" -gt 0 ] || return 1
		sleep 0.02
	done
}

wait_bounded() {
	pid=$1
	seconds=${2:-8}
	(
		trap - EXIT INT TERM
		sleep "$seconds"
		kill -TERM "$pid" 2>/dev/null || exit 0
		sleep 0.2
		kill -KILL "$pid" 2>/dev/null || true
	) &
	watchdog=$!
	background_pids="$background_pids $watchdog"
	status=0
	wait "$pid" || status=$?
	forget_pid "$pid"
	kill -KILL "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	forget_pid "$watchdog"
	return "$status"
}

forget_pid() {
	forgotten=$1
	retained=
	for tracked in $background_pids; do
		[ "$tracked" = "$forgotten" ] || retained="$retained $tracked"
	done
	background_pids=$retained
}

register_release() {
	release_markers="$release_markers $1"
}

run_helper() {
	repository=$1
	shift
	/usr/bin/env -C "$repository" "$helper" "$@"
}

start_helper() {
	repository=$1
	shift
	/usr/bin/env -C "$repository" "$helper" "$@" &
	started_pid=$!
	background_pids="$background_pids $started_pid"
}

start_helper_at_checkpoint() {
	acquired_file=$1
	release_file=$2
	repository=$3
	shift 3
	/usr/bin/env -C "$repository" \
		PSY_PREPARELOCK_TEST_ACQUIRED_FILE="$acquired_file" \
		PSY_PREPARELOCK_TEST_RELEASE_FILE="$release_file" \
		"$helper" "$@" &
	started_pid=$!
	background_pids="$background_pids $started_pid"
	register_release "$release_file"
}

if [ "${PSY_PREPARELOCK_CLEANUP_SELFTEST:-}" = 1 ]; then
	cleanup_repo=${PSY_PREPARELOCK_CLEANUP_REPO:?}
	cleanup_started="$cleanup_repo/started"
	cleanup_release="$cleanup_repo/release"
	register_release "$cleanup_release"
	start_helper "$cleanup_repo" .build/go cleanup.lock /bin/sh -c ': >"$1"; while [ ! -e "$2" ]; do sleep 0.02; done' child "$cleanup_started" "$cleanup_release"
	cleanup_helper_pid=$started_pid
	wait_for_file "$cleanup_started" || fail "cleanup self-test child did not start"
	kill -KILL "$cleanup_helper_pid"
	wait_bounded "$cleanup_helper_pid" 2>/dev/null || true
	exit 42
fi

# A missing parent is created component-by-component, the child runs from the
# descriptor-bound final parent, and an inherited duplicate verifies as owner.
basic_repo="$test_dir/basic"
mkdir "$basic_repo"
run_helper "$basic_repo" .build/go basic.lock "$helper" --verify-inherited basic.lock
[ -f "$basic_repo/.build/go/basic.lock" ] || fail "basic lock was not created"

# Every ancestor component is opened as an owned, non-writable directory with
# O_NOFOLLOW. Special files must fail quickly rather than block.
ancestor_real="$test_dir/ancestor-real"
mkdir "$ancestor_real"
ancestor_symlink="$test_dir/ancestor-symlink"
mkdir "$ancestor_symlink"
ln -s "$ancestor_real" "$ancestor_symlink/.build"
expect_failure "ancestor symlink" run_helper "$ancestor_symlink" .build/go lock /usr/bin/true

ancestor_regular="$test_dir/ancestor-regular"
mkdir "$ancestor_regular"
: >"$ancestor_regular/.build"
expect_failure "regular ancestor" run_helper "$ancestor_regular" .build/go lock /usr/bin/true

ancestor_fifo="$test_dir/ancestor-fifo"
mkdir "$ancestor_fifo"
mkfifo "$ancestor_fifo/.build"
expect_failure "FIFO ancestor" run_helper "$ancestor_fifo" .build/go lock /usr/bin/true

ancestor_nested="$test_dir/ancestor-nested"
mkdir -p "$ancestor_nested/.build"
ln -s "$ancestor_real" "$ancestor_nested/.build/go"
expect_failure "nested ancestor symlink" run_helper "$ancestor_nested" .build/go lock /usr/bin/true

ancestor_writable="$test_dir/ancestor-writable"
mkdir -p "$ancestor_writable/.build"
chmod 777 "$ancestor_writable/.build"
expect_failure "group-writable ancestor" run_helper "$ancestor_writable" .build/go lock /usr/bin/true

ancestor_socket="$test_dir/ancestor-socket"
mkdir "$ancestor_socket"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$ancestor_socket/.build"
expect_failure "socket ancestor" run_helper "$ancestor_socket" .build/go lock /usr/bin/true

# Lock leaves must be private single-link regular files.
leaf_repo="$test_dir/leaves"
mkdir -p "$leaf_repo/.build/go"
: >"$leaf_repo/target"
chmod 600 "$leaf_repo/target"
ln -s "$leaf_repo/target" "$leaf_repo/.build/go/symlink.lock"
expect_failure "lock symlink" run_helper "$leaf_repo" .build/go symlink.lock /usr/bin/true
mkdir "$leaf_repo/.build/go/directory.lock"
expect_failure "lock directory" run_helper "$leaf_repo" .build/go directory.lock /usr/bin/true
mkfifo "$leaf_repo/.build/go/fifo.lock"
expect_failure "lock FIFO" run_helper "$leaf_repo" .build/go fifo.lock /usr/bin/true
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$leaf_repo/.build/go/socket.lock"
expect_failure "lock socket" run_helper "$leaf_repo" .build/go socket.lock /usr/bin/true
ln "$leaf_repo/target" "$leaf_repo/.build/go/hardlink.lock"
expect_failure "hardlinked lock" run_helper "$leaf_repo" .build/go hardlink.lock /usr/bin/true
: >"$leaf_repo/.build/go/mode.lock"
chmod 644 "$leaf_repo/.build/go/mode.lock"
expect_failure "non-private lock" run_helper "$leaf_repo" .build/go mode.lock /usr/bin/true

# The verifier rejects closed, special, unrelated, unlocked, and independently
# locked descriptors. Only the duplicated open-file description inherited from
# the holder is accepted (covered by the basic case above).
fd_repo="$test_dir/fd"
mkdir -p "$fd_repo/.build/go"
: >"$fd_repo/.build/go/fd.lock"
chmod 600 "$fd_repo/.build/go/fd.lock"
: >"$fd_repo/unrelated"
chmod 600 "$fd_repo/unrelated"
expect_failure "closed fd3" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 3>&-; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "device fd3" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 3</dev/null; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "unrelated fd3" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 3<>"$1"; "$2" --verify-inherited fd.lock' child "$fd_repo/unrelated" "$helper"
expect_failure "unlocked correct fd3" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 5>&3; exec 3<>fd.lock; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "pipe fd3" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'printf x | (exec 3<&0; "$1" --verify-inherited fd.lock)' child "$helper"
expect_failure "closed fd4" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 4>&-; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "device fd4" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 4</dev/null; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "unlocked correct fd4" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'exec 5>&4; exec 4<.; "$1" --verify-inherited fd.lock' child "$helper"
expect_failure "cwd and parent fd mismatch" run_helper "$fd_repo" .build/go fd.lock /bin/sh -c 'cd /private/tmp; "$1" --verify-inherited fd.lock' child "$helper"

# Killing after flock but before child start releases immediately and never
# starts the child.
pre_repo="$test_dir/pre-child"
mkdir "$pre_repo"
pre_acquired="$test_dir/pre-acquired"
pre_release="$test_dir/pre-release"
pre_child="$test_dir/pre-child-ran"
start_helper_at_checkpoint "$pre_acquired" "$pre_release" "$pre_repo" .build/go pre.lock /bin/sh -c ': >"$1"' child "$pre_child"
pre_pid=$started_pid
wait_for_file "$pre_acquired" || fail "pre-child checkpoint was not reached"
kill -KILL "$pre_pid"
wait_bounded "$pre_pid" 2>/dev/null || true
run_helper "$pre_repo" .build/go pre.lock /usr/bin/true
[ ! -e "$pre_child" ] || fail "helper killed before child start launched its child"

# After child start, killing the helper does not release the inherited lock;
# the child owns the same open-file description until it exits.
post_repo="$test_dir/post-child"
mkdir "$post_repo"
post_started="$test_dir/post-started"
post_release="$test_dir/post-release"
post_finished="$test_dir/post-finished"
register_release "$post_release"
start_helper "$post_repo" .build/go post.lock /bin/sh -c ': >"$1"; while [ ! -e "$2" ]; do sleep 0.02; done; : >"$3"' child "$post_started" "$post_release" "$post_finished"
post_helper_pid=$started_pid
wait_for_file "$post_started" || fail "post-child holder did not start"
kill -KILL "$post_helper_pid"
wait_bounded "$post_helper_pid" 2>/dev/null || true
status=0
run_helper "$post_repo" --timeout=180ms .build/go post.lock /usr/bin/true >/dev/null 2>&1 || status=$?
[ "$status" -eq 75 ] || fail "post-child contender did not return stable timeout status (got $status)"
: >"$post_release"
wait_for_file "$post_finished" || fail "orphaned child did not finish"
run_helper "$post_repo" .build/go post.lock /usr/bin/true

# An intentional mid-test failure must trigger release markers before cleanup,
# allowing a fresh helper to acquire the orphan child's parent and leaf locks.
cleanup_self_repo="$test_dir/cleanup-self"
mkdir "$cleanup_self_repo"
status=0
PSY_PREPARELOCK_CLEANUP_SELFTEST=1 PSY_PREPARELOCK_CLEANUP_REPO="$cleanup_self_repo" \
	"$script_dir/test-prepare-lock.sh" >/dev/null 2>&1 || status=$?
[ "$status" -eq 42 ] || fail "cleanup self-test did not take its intentional failure path (got $status)"
run_helper "$cleanup_self_repo" --timeout=2s .build/go cleanup.lock /usr/bin/true

# Replacing the lock leaf cannot create a second writer because every helper
# first holds the descriptor-bound parent directory lock for the same deadline.
leaf_replace_repo="$test_dir/leaf-replace"
mkdir "$leaf_replace_repo"
leaf_replace_started="$test_dir/leaf-replace-started"
leaf_replace_release="$test_dir/leaf-replace-release"
register_release "$leaf_replace_release"
start_helper "$leaf_replace_repo" .build/go replace.lock /bin/sh -c ': >"$1"; while [ ! -e "$2" ]; do sleep 0.02; done' child "$leaf_replace_started" "$leaf_replace_release"
leaf_replace_pid=$started_pid
wait_for_file "$leaf_replace_started" || fail "leaf-replacement holder did not start"
mv "$leaf_replace_repo/.build/go/replace.lock" "$leaf_replace_repo/.build/go/replace.lock.old"
: >"$leaf_replace_repo/.build/go/replace.lock"
chmod 600 "$leaf_replace_repo/.build/go/replace.lock"
status=0
run_helper "$leaf_replace_repo" --timeout=180ms .build/go replace.lock /usr/bin/true >/dev/null 2>&1 || status=$?
[ "$status" -eq 75 ] || fail "replacement-leaf contender did not time out on the parent lock (got $status)"
: >"$leaf_replace_release"
wait_bounded "$leaf_replace_pid" || fail "leaf-replacement holder failed"
run_helper "$leaf_replace_repo" .build/go replace.lock /usr/bin/true

# Killing the child makes the waiting helper exit and release its descriptor.
child_repo="$test_dir/child-death"
mkdir "$child_repo"
child_started="$test_dir/child-death-started"
child_pid_file="$test_dir/child-pid"
child_release="$test_dir/child-death-release"
register_release "$child_release"
start_helper "$child_repo" .build/go child.lock /bin/sh -c 'printf "%s\n" "$$" >"$1"; : >"$2"; while [ ! -e "$3" ]; do sleep 0.02; done' child "$child_pid_file" "$child_started" "$child_release"
child_helper_pid=$started_pid
wait_for_file "$child_started" || fail "child-death holder did not start"
child_pid=$(sed -n '1p' "$child_pid_file")
kill -KILL "$child_pid"
if wait_bounded "$child_helper_pid" 3; then
	fail "helper reported success after child death"
fi
run_helper "$child_repo" .build/go child.lock /usr/bin/true

# A killed queued helper leaves no userspace claim. The next contender enters
# after the live holder exits.
queued_repo="$test_dir/queued"
mkdir "$queued_repo"
queued_holder_started="$test_dir/queued-holder-started"
queued_release="$test_dir/queued-release"
queued_child="$test_dir/queued-child"
register_release "$queued_release"
start_helper "$queued_repo" .build/go queued.lock /bin/sh -c ': >"$1"; while [ ! -e "$2" ]; do sleep 0.02; done' child "$queued_holder_started" "$queued_release"
queued_holder_pid=$started_pid
wait_for_file "$queued_holder_started" || fail "queued holder did not start"
start_helper "$queued_repo" .build/go queued.lock /bin/sh -c ': >"$1"' child "$queued_child"
queued_pid=$started_pid
sleep 0.1
kill -KILL "$queued_pid"
wait_bounded "$queued_pid" 2>/dev/null || true
: >"$queued_release"
wait_bounded "$queued_holder_pid" || fail "queued holder failed"
run_helper "$queued_repo" .build/go queued.lock /usr/bin/true
[ ! -e "$queued_child" ] || fail "killed queued helper started a child"

# A descriptor-bound cwd survives ancestor replacement: the first child writes
# only to the renamed inode, never to the replacement pathname.
rebind_repo="$test_dir/rebind"
mkdir "$rebind_repo"
rebind_acquired="$test_dir/rebind-acquired"
rebind_release="$test_dir/rebind-release"
start_helper_at_checkpoint "$rebind_acquired" "$rebind_release" "$rebind_repo" .build/go rebind.lock /bin/sh -c ': >bound-child'
rebind_pid=$started_pid
wait_for_file "$rebind_acquired" || fail "rebind checkpoint was not reached"
mv "$rebind_repo/.build" "$rebind_repo/.build.bound"
mkdir -p "$rebind_repo/.build/go"
: >"$rebind_release"
wait_bounded "$rebind_pid" || fail "descriptor-bound rebind child failed"
[ -e "$rebind_repo/.build.bound/go/bound-child" ] || fail "bound child did not write to original inode"
[ ! -e "$rebind_repo/.build/go/bound-child" ] || fail "bound child modified replacement directory"

# Sixteen concurrent contenders must each execute exactly once with a maximum
# active critical-section count of one.
concurrent_repo="$test_dir/concurrent"
mkdir "$concurrent_repo"
active_file="$test_dir/active"
max_file="$test_dir/max-active"
executions_file="$test_dir/executions"
: >"$active_file"
: >"$max_file"
: >"$executions_file"
concurrent_pids=
i=1
while [ "$i" -le 16 ]; do
	start_helper "$concurrent_repo" .build/go concurrent.lock /bin/sh -c '
		active=$(sed -n "1p" "$1"); active=${active:-0}; active=$((active + 1)); printf "%s\n" "$active" >"$1"
		maximum=$(sed -n "1p" "$2"); maximum=${maximum:-0}; [ "$active" -le "$maximum" ] || printf "%s\n" "$active" >"$2"
		sleep 0.03
		printf "%s\n" "$3" >>"$4"
		active=$((active - 1)); printf "%s\n" "$active" >"$1"
	' child "$active_file" "$max_file" "$i" "$executions_file"
	pid=$started_pid
	concurrent_pids="$concurrent_pids $pid"
	i=$((i + 1))
done
for pid in $concurrent_pids; do
	wait_bounded "$pid" 10 || fail "concurrent contender failed"
done
[ "$(sed -n '1p' "$max_file")" = 1 ] || fail "concurrent maxActive was not one"
[ "$(wc -l <"$executions_file" | tr -d '[:space:]')" = 16 ] || fail "a concurrent child ran zero or multiple times"

# Child status is propagated, the lock is released on failure, and a bounded
# contender exits with the stable timeout code instead of hanging.
failure_repo="$test_dir/failure"
mkdir "$failure_repo"
status=0
run_helper "$failure_repo" .build/go failure.lock /bin/sh -c 'exit 23' >/dev/null 2>&1 || status=$?
[ "$status" -eq 23 ] || fail "child exit status was not propagated (got $status)"
run_helper "$failure_repo" .build/go failure.lock /usr/bin/true

deadline_started="$test_dir/deadline-started"
deadline_release="$test_dir/deadline-release"
register_release "$deadline_release"
start_helper "$failure_repo" .build/go deadline.lock /bin/sh -c ': >"$1"; while [ ! -e "$2" ]; do sleep 0.02; done' child "$deadline_started" "$deadline_release"
deadline_holder_pid=$started_pid
wait_for_file "$deadline_started" || fail "deadline holder did not start"
status=0
run_helper "$failure_repo" --timeout=180ms .build/go deadline.lock /usr/bin/true >/dev/null 2>&1 || status=$?
[ "$status" -eq 75 ] || fail "deadline contender status was not 75 (got $status)"
: >"$deadline_release"
wait_bounded "$deadline_holder_pid" || fail "deadline holder failed"

printf 'preparelock path binding, verifier, kill-window, concurrency, and deadline tests passed\n'
