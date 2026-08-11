#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export VPS_INIT_SSHD_CONFIG_FILE="$TEST_DIR/sshd_config"
export VPS_INIT_SSH_MANAGED_FILE="$TEST_DIR/sshd_config.d/00-00-vps-init.conf"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

BACKUP_DIR="$TEST_DIR/backups"
ACTIVE_COUNT_FILE="$TEST_DIR/active-count"
SSHD_STATUS=0
RESTART_STATUS=0
ACTIVE_AFTER=1
SERVICE_FAILED=0
MOCK_LISTENING_PORTS=22
MOCK_HANDSHAKE_STATUS=0

fail_test() {
    echo "SSH transaction test failed: $1" >&2
    exit 1
}

sleep() {
    return 0
}

sshd() {
    if (( SSHD_STATUS != 0 )); then
        echo "mock sshd syntax error" >&2
    fi
    return "$SSHD_STATUS"
}

systemctl() {
    local count=0

    case "${1:-} ${2:-} ${3:-}" in
        'cat ssh.service ')
            return 0
            ;;
        'is-enabled ssh.service ')
            printf 'enabled\n'
            return 0
            ;;
        'is-active ssh.service ')
            printf 'active\n'
            return 0
            ;;
        'restart ssh.service ')
            if (( RESTART_STATUS != 0 )); then
                echo "mock restart failure" >&2
            fi
            return "$RESTART_STATUS"
            ;;
        'is-active --quiet ssh.service')
            count=$(<"$ACTIVE_COUNT_FILE")
            count=$((count + 1))
            printf '%s' "$count" > "$ACTIVE_COUNT_FILE"
            (( count >= ACTIVE_AFTER ))
            return
            ;;
        'is-failed --quiet ssh.service')
            [[ "$SERVICE_FAILED" == "1" ]]
            return
            ;;
        'daemon-reload  '|'unmask ssh.service '|'enable ssh.service '|'disable ssh.service '|'stop ssh.service ')
            return 0
            ;;
    esac
    return 0
}

get_configured_ssh_ports() {
    local port=""

    if [[ -f "$SSH_MANAGED_FILE" ]]; then
        port=$(awk 'tolower($1)=="port" {print $2; exit}' "$SSH_MANAGED_FILE")
    fi
    if [[ -z "$port" && -f "$SSHD_CONFIG_FILE" ]]; then
        port=$(awk 'tolower($1)=="port" {print $2; exit}' "$SSHD_CONFIG_FILE")
    fi
    printf '%s\n' "${port:-22}"
}

get_listening_ssh_ports() {
    printf '%s\n' "$MOCK_LISTENING_PORTS"
}

ssh_ports_accept_loopback() {
    return "$MOCK_HANDSHAKE_STATUS"
}

reset_runtime() {
    printf '0' > "$ACTIVE_COUNT_FILE"
    SSHD_STATUS=0
    RESTART_STATUS=0
    ACTIVE_AFTER=1
    SERVICE_FAILED=0
    MOCK_LISTENING_PORTS=22
    MOCK_HANDSHAKE_STATUS=0
    SSH_RESTART_FAILURE=""
    SSH_CONFIG_FAILURE=""
}

mkdir -p "$(dirname "$SSH_MANAGED_FILE")"
printf 'Port 22\n' > "$SSHD_CONFIG_FILE"
printf 'Port 22\n' > "$SSH_MANAGED_FILE"

reset_runtime
SSHD_STATUS=7
if validate_sshd_syntax; then
    fail_test "invalid sshd syntax was accepted"
fi
[[ "$SSH_CONFIG_FAILURE" == *'exit=7'* ]] || \
    fail_test "sshd syntax exit code was not retained"
[[ "$SSH_CONFIG_FAILURE" == *'mock sshd syntax error'* ]] || \
    fail_test "sshd syntax stderr was not retained"

reset_runtime
RESTART_STATUS=5
if restart_ssh 22; then
    fail_test "failed ssh.service restart was accepted"
fi
[[ "$SSH_RESTART_FAILURE" == *'exit=5'* ]] || \
    fail_test "restart exit code was not retained"

reset_runtime
MOCK_LISTENING_PORTS=7066
if restart_ssh 22; then
    fail_test "wrong listening port was accepted"
fi
[[ "$SSH_RESTART_FAILURE" == *'10 秒内未通过'* ]] || \
    fail_test "listener timeout reason was not retained"

reset_runtime
MOCK_HANDSHAKE_STATUS=1
if restart_ssh 22; then
    fail_test "failed local SSH handshake was accepted"
fi

reset_runtime
ACTIVE_AFTER=3
restart_ssh 22 || fail_test "delayed ssh.service readiness was rejected"
[[ "$(<"$ACTIVE_COUNT_FILE")" == "3" ]] || \
    fail_test "ssh.service readiness did not wait until the third check"

reset_runtime
begin_ssh_transaction || fail_test "SSH transaction backup failed"
printf 'Port 7066\n' > "$SSHD_CONFIG_FILE"
printf 'Port 7066\n' > "$SSH_MANAGED_FILE"
MOCK_LISTENING_PORTS=22
restore_ssh_transaction || fail_test "SSH rollback failed"
[[ "$(<"$SSHD_CONFIG_FILE")" == 'Port 22' ]] || \
    fail_test "SSH rollback did not restore sshd_config"
[[ "$(<"$SSH_MANAGED_FILE")" == 'Port 22' ]] || \
    fail_test "SSH rollback did not restore the managed drop-in"

printf 'SSH transaction tests passed.\n'
