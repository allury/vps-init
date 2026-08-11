#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export VPS_INIT_SWAP_FILE="$TEST_DIR/swapfile"
export VPS_INIT_FSTAB_FILE="$TEST_DIR/fstab"
export VPS_INIT_SWAP_SYSCTL_FILE="$TEST_DIR/swappiness.conf"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

BACKUP_DIR="$TEST_DIR/backups"
CALL_LOG="$TEST_DIR/calls"
SHOW_COUNT_FILE="$TEST_DIR/show-count"
SYSCTL_COUNT_FILE="$TEST_DIR/sysctl-count"
FAIL_CONSUMED_FILE="$TEST_DIR/fail-consumed"
SWAP_ACTIVE_FILE="$TEST_DIR/swap-active"
FILESYSTEM_TYPE=ext4
FAIL_STAGE=""

fail_test() {
    echo "SWAP transaction test failed: $1" >&2
    exit 1
}

record_call() {
    printf '%s\n' "$1" >> "$CALL_LOG"
}

system_has_any_swap_configuration() {
    return 1
}

preflight_swap_creation() {
    return 0
}

findmnt() {
    printf '%s\n' "$FILESYSTEM_TYPE"
}

dd() {
    local argument=""
    local output_file=""
    local count=""

    record_call DD
    if [[ "$FAIL_STAGE" == "CREATE_FILE" ]]; then
        echo "mock dd failure" >&2
        return 31
    fi
    for argument in "$@"; do
        case "$argument" in
            of=*) output_file="${argument#of=}" ;;
            count=*) count="${argument#count=}" ;;
        esac
    done
    truncate -s "$((count * 1024 * 1024))" "$output_file"
}

btrfs() {
    if [[ "$1 $2" == "filesystem mkswapfile" ]]; then
        if [[ "${3:-}" == "--help" ]]; then
            return 0
        fi
        record_call BTRFS_MKSWAPFILE
        truncate -s 1048576 "${5}"
        return 0
    fi
    if [[ "$1 $2" == "inspect-internal map-swapfile" ]]; then
        return 0
    fi
    return 1
}

chmod() {
    local target="${*: -1}"

    if [[ "$target" == "$MANAGED_SWAP_FILE" && "$FAIL_STAGE" == "CHMOD" && ! -e "$FAIL_CONSUMED_FILE" ]]; then
        : > "$FAIL_CONSUMED_FILE"
        echo "mock chmod failure" >&2
        return 32
    fi
    command chmod "$@"
}

mkswap() {
    record_call MKSWAP
    if [[ "$FAIL_STAGE" == "MKSWAP" ]]; then
        echo "mock mkswap failure" >&2
        return 33
    fi
    return 0
}

swapon() {
    local count=0

    if [[ "${1:-}" == --show=* ]]; then
        count=$(<"$SHOW_COUNT_FILE")
        count=$((count + 1))
        printf '%s' "$count" > "$SHOW_COUNT_FILE"
        if [[ "$FAIL_STAGE" == "VERIFY" && "$count" == "3" ]]; then
            return 0
        fi
        if [[ "$(<"$SWAP_ACTIVE_FILE")" == "1" ]]; then
            printf '%s\n' "$MANAGED_SWAP_FILE"
        fi
        return 0
    fi

    record_call SWAPON
    if [[ "$FAIL_STAGE" == "SWAPON" ]]; then
        echo "swapon failed: Invalid argument" >&2
        return 255
    fi
    printf '1' > "$SWAP_ACTIVE_FILE"
}

swapoff() {
    record_call SWAPOFF
    printf '0' > "$SWAP_ACTIVE_FILE"
}

systemctl() {
    if [[ "${1:-}" == "daemon-reload" ]]; then
        record_call DAEMON_RELOAD
        return 0
    fi
    return 0
}

sysctl() {
    local count=0

    if [[ "${1:-}" == "-n" && "${2:-}" == "vm.swappiness" ]]; then
        count=$(<"$SYSCTL_COUNT_FILE")
        count=$((count + 1))
        printf '%s' "$count" > "$SYSCTL_COUNT_FILE"
        if [[ "$FAIL_STAGE" == "SWAPPINESS" && "$count" == "2" ]]; then
            printf 'unknown\n'
        else
            printf '60\n'
        fi
        return 0
    fi
    if [[ "${1:-}" == "-w" ]]; then
        return 0
    fi
    return 1
}

mv() {
    local target="${*: -1}"

    if [[ "$target" == "$FSTAB_FILE" && "$FAIL_STAGE" == "FSTAB" && ! -e "$FAIL_CONSUMED_FILE" ]]; then
        : > "$FAIL_CONSUMED_FILE"
        echo "mock fstab replacement failure" >&2
        return 34
    fi
    command mv "$@"
}

prepare_case() {
    local filesystem="$1"
    local failure="${2:-}"

    rm -rf -- "$BACKUP_DIR"
    rm -f -- "$MANAGED_SWAP_FILE" "$SWAP_SYSCTL_FILE" "$FAIL_CONSUMED_FILE"
    printf '# test fstab\n' > "$FSTAB_FILE"
    : > "$CALL_LOG"
    printf '0' > "$SHOW_COUNT_FILE"
    printf '0' > "$SYSCTL_COUNT_FILE"
    printf '0' > "$SWAP_ACTIVE_FILE"
    : > "$LOG_FILE"
    FILESYSTEM_TYPE="$filesystem"
    FAIL_STAGE="$failure"
}

assert_success_path() {
    local filesystem="$1"

    prepare_case "$filesystem"
    create_managed_swap 1M || fail_test "$filesystem success path failed"
    [[ "$(<"$SWAP_ACTIVE_FILE")" == "1" ]] || fail_test "$filesystem did not execute swapon"
    grep -Fxq SWAPON "$CALL_LOG" || fail_test "$filesystem did not call swapon"
    grep -Fq '# managed by vps-init' "$FSTAB_FILE" || \
        fail_test "$filesystem did not persist the fstab entry"
    grep -Fq '[SWAP][VERIFY]' "$LOG_FILE" || \
        fail_test "$filesystem did not log final verification"

    if [[ "$filesystem" == "btrfs" ]]; then
        grep -Fxq BTRFS_MKSWAPFILE "$CALL_LOG" || \
            fail_test "Btrfs did not use filesystem mkswapfile"
        if grep -Fxq MKSWAP "$CALL_LOG"; then
            fail_test "Btrfs repeated mkswap after mkswapfile"
        fi
    else
        grep -Fxq DD "$CALL_LOG" || fail_test "$filesystem did not create a fully allocated file"
        grep -Fxq MKSWAP "$CALL_LOG" || fail_test "$filesystem did not execute mkswap"
    fi
}

assert_failure_rolls_back() {
    local stage="$1"

    prepare_case ext4 "$stage"
    if create_managed_swap 1M >/dev/null 2>&1; then
        fail_test "$stage failure was incorrectly accepted"
    fi
    [[ "$(<"$SWAP_ACTIVE_FILE")" == "0" ]] || fail_test "$stage rollback left SWAP active"
    [[ ! -e "$MANAGED_SWAP_FILE" ]] || fail_test "$stage rollback left the swapfile behind"
    [[ "$(<"$FSTAB_FILE")" == "# test fstab" ]] || \
        fail_test "$stage rollback did not restore fstab"
    grep -Fq '[SWAP][ROLLBACK]' "$LOG_FILE" || \
        fail_test "$stage rollback was not logged"
}

assert_success_path ext4
assert_success_path xfs
assert_success_path btrfs

# Regression guard: mkswap returning zero must continue to swapon and succeed.
prepare_case ext4
create_managed_swap 1M || fail_test "mkswap exit=0 was treated as failure"
grep -Fxq MKSWAP "$CALL_LOG" || fail_test "regression case did not execute mkswap"
grep -Fxq SWAPON "$CALL_LOG" || fail_test "regression case stopped before swapon"

for failure_stage in CREATE_FILE CHMOD MKSWAP SWAPON FSTAB SWAPPINESS VERIFY; do
    assert_failure_rolls_back "$failure_stage"
done

printf 'SWAP transaction tests passed.\n'
