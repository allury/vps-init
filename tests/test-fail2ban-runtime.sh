#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

PING_COUNT_FILE="$TEST_DIR/ping-count"
RESTART_COUNT_FILE="$TEST_DIR/restart-count"
PING_READY_AFTER=1
PING_ALWAYS_FAIL=0
SERVICE_FAILED=0
RESTART_STATUS=0
JAIL_STATUS=0
RUNTIME_MAXRETRY=5
RUNTIME_FINDTIME=3600
RUNTIME_BANTIME=86400
RUNTIME_PORT=7066

fail_test() {
    echo "Fail2ban runtime test failed: $1" >&2
    exit 1
}

timeout() {
    shift
    "$@"
}

sleep() {
    return 0
}

systemctl() {
    case "${1:-} ${2:-}" in
        'restart fail2ban.service')
            printf '1' > "$RESTART_COUNT_FILE"
            if (( RESTART_STATUS != 0 )); then
                echo "mock restart failure" >&2
            fi
            return "$RESTART_STATUS"
            ;;
        'is-failed fail2ban.service')
            if [[ "$SERVICE_FAILED" == "1" ]]; then
                printf 'failed\n'
                return 0
            fi
            printf 'active\n'
            return 1
            ;;
    esac
    return 0
}

fail2ban-client() {
    local count=0

    if [[ "${1:-}" == "ping" ]]; then
        count=$(<"$PING_COUNT_FILE")
        count=$((count + 1))
        printf '%s' "$count" > "$PING_COUNT_FILE"
        if [[ "$PING_ALWAYS_FAIL" == "1" ]] || (( count < PING_READY_AFTER )); then
            echo "Server not ready" >&2
            return 1
        fi
        printf 'Server replied: pong\n'
        return 0
    fi
    if [[ "${1:-} ${2:-}" == "status sshd" ]]; then
        if (( JAIL_STATUS != 0 )); then
            echo "Sorry but the jail 'sshd' does not exist" >&2
            return "$JAIL_STATUS"
        fi
        printf 'Status for the jail: sshd\n'
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "get sshd maxretry" ]]; then
        printf '%s\n' "$RUNTIME_MAXRETRY"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "get sshd findtime" ]]; then
        printf '%s\n' "$RUNTIME_FINDTIME"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "get sshd bantime" ]]; then
        printf '%s\n' "$RUNTIME_BANTIME"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-}" == "get sshd actions" ]]; then
        printf "['iptables-multiport']\n"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-} ${4:-}" == "get sshd actionproperties iptables-multiport" ]]; then
        printf "['port', 'protocol']\n"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-} ${4:-} ${5:-}" == "get sshd action iptables-multiport port" ]]; then
        printf '%s\n' "$RUNTIME_PORT"
        return 0
    fi
    return 1
}

reset_case() {
    printf '0' > "$PING_COUNT_FILE"
    printf '0' > "$RESTART_COUNT_FILE"
    : > "$LOG_FILE"
    PING_READY_AFTER=1
    PING_ALWAYS_FAIL=0
    SERVICE_FAILED=0
    RESTART_STATUS=0
    JAIL_STATUS=0
    RUNTIME_MAXRETRY=5
    RUNTIME_FINDTIME=3600
    RUNTIME_BANTIME=86400
    RUNTIME_PORT=7066
}

reset_case
PING_READY_AFTER=3
restart_fail2ban_and_wait || \
    fail_test "restart followed by delayed readiness was rejected"
[[ "$(<"$RESTART_COUNT_FILE")" == "1" ]] || fail_test "service restart was not executed"
[[ "$(<"$PING_COUNT_FILE")" == "3" ]] || fail_test "readiness loop did not retry until the third ping"

reset_case
PING_ALWAYS_FAIL=1
if wait_for_fail2ban_ready; then
    fail_test "a service that never answered ping was accepted"
fi
[[ "$(<"$PING_COUNT_FILE")" == "15" ]] || fail_test "readiness loop did not stop after 15 attempts"
[[ "$FAIL2BAN_VERIFY_FAILURE" == *'15 秒内未就绪'* ]] || \
    fail_test "readiness timeout did not produce a precise reason"

reset_case
PING_ALWAYS_FAIL=1
SERVICE_FAILED=1
if wait_for_fail2ban_ready; then
    fail_test "a service in failed state was accepted"
fi
[[ "$(<"$PING_COUNT_FILE")" == "1" ]] || fail_test "failed service did not terminate readiness checks early"
[[ "$FAIL2BAN_VERIFY_FAILURE" == *'服务进入 failed'* ]] || \
    fail_test "failed service reason was not recorded"

reset_case
RESTART_STATUS=7
if restart_fail2ban_and_wait; then
    fail_test "a failed systemctl restart was accepted"
fi
[[ "$FAIL2BAN_VERIFY_FAILURE" == *'exit=7'* ]] || \
    fail_test "restart exit status was not retained"

reset_case
verify_fail2ban_sshd_runtime full 1 7066 || \
    fail_test "valid sshd jail runtime parameters were rejected"

reset_case
JAIL_STATUS=1
if verify_fail2ban_sshd_runtime full 1 7066; then
    fail_test "a missing sshd jail was accepted"
fi

reset_case
RUNTIME_MAXRETRY=6
if verify_fail2ban_sshd_runtime full 1 7066; then
    fail_test "an incorrect maxretry value was accepted"
fi

reset_case
RUNTIME_PORT=22
if verify_fail2ban_sshd_runtime full 1 7066; then
    fail_test "an incorrect Fail2ban SSH port was accepted"
fi

printf 'Fail2ban runtime tests passed.\n'
