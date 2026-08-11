#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

INSTANCE_LOCK_FILE="$TEST_DIR/vps-init.lock"
READY_FILE="$TEST_DIR/ready"

fail_test() {
    echo "Instance lock test failed: $1" >&2
    exit 1
}

# A previous long PID must be fully replaced, not partially overwritten through
# a file descriptor whose offset still points beyond the truncated file.
printf '99999999999999999999\n' > "$INSTANCE_LOCK_FILE"
acquire_instance_lock
[[ "$(<"$INSTANCE_LOCK_FILE")" == "$$" ]] || \
    fail_test "lock owner PID was not replaced exactly"

if bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    acquire_instance_lock
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" >/dev/null 2>&1; then
    fail_test "a concurrent process acquired the active lock"
fi

release_instance_lock
[[ ! -s "$INSTANCE_LOCK_FILE" ]] || fail_test "normal release left owner data behind"

# Stale text alone is not a lock. flock, rather than PID-file contents, is the
# source of truth.
printf '424242\n' > "$INSTANCE_LOCK_FILE"
bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    acquire_instance_lock
    release_instance_lock
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" || \
    fail_test "stale PID text permanently blocked execution"

# TERM must execute the same release function registered by main.
rm -f -- "$READY_FILE"
bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    trap release_instance_lock EXIT
    trap "handle_termination_signal TERM 143" TERM
    acquire_instance_lock
    printf ready > "$3"
    while true; do sleep 1; done
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" "$READY_FILE" &
child_pid=$!
for _ in {1..20}; do
    [[ -f "$READY_FILE" ]] && break
    sleep 0.1
done
[[ -f "$READY_FILE" ]] || fail_test "signal-test child never acquired the lock"
kill -TERM "$child_pid"
set +e
wait "$child_pid"
child_status=$?
set -e
[[ "$child_status" == "143" ]] || fail_test "TERM exit status was $child_status instead of 143"

bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    acquire_instance_lock
    release_instance_lock
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" || \
    fail_test "lock was not reusable after TERM"

# SIGKILL cannot execute a shell trap. The kernel must still release flock so
# stale PID text cannot permanently block later runs.
rm -f -- "$READY_FILE"
bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    acquire_instance_lock
    printf ready > "$3"
    while true; do sleep 1; done
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" "$READY_FILE" &
child_pid=$!
for _ in {1..20}; do
    [[ -f "$READY_FILE" ]] && break
    sleep 0.1
done
[[ -f "$READY_FILE" ]] || fail_test "SIGKILL-test child never acquired the lock"
kill -KILL "$child_pid"
set +e
wait "$child_pid" 2>/dev/null
child_status=$?
set -e
[[ "$child_status" == "137" ]] || fail_test "SIGKILL exit status was $child_status instead of 137"

bash -c '
    source "$1"
    INSTANCE_LOCK_FILE="$2"
    acquire_instance_lock
    release_instance_lock
' _ "$SCRIPT_DIR/../vps.sh" "$INSTANCE_LOCK_FILE" || \
    fail_test "kernel did not release flock after SIGKILL"

printf 'Instance lock tests passed.\n'
