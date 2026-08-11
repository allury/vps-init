#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

JOURNAL_AVAILABLE=0
BACKEND_AVAILABLE=0
CONFIG_TEST_STATUS=0
PING_READY_AFTER=1
PING_ALWAYS_FAIL=0
SERVICE_FAILED=0
PING_COUNT_FILE=""
CONFIG_TEST_COUNT_FILE=""
RESTART_COUNT_FILE=""
STOP_COUNT_FILE=""

fail_test() {
    echo "Fail2ban log source test failed: $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"

    grep -Fqx -- "$expected" "$file" || \
        fail_test "$file does not contain [$expected]"
}

assert_file_not_contains() {
    local file="$1"
    local unexpected="$2"

    if grep -Fqx -- "$unexpected" "$file"; then
        fail_test "$file unexpectedly contains [$unexpected]"
    fi
}

timeout() {
    shift
    "$@"
}

sleep() {
    return 0
}

chown() {
    return 0
}

chmod() {
    return 0
}

journalctl() {
    if [[ "$JOURNAL_AVAILABLE" == "1" ]]; then
        printf 'Aug 11 host sshd[123]: Accepted publickey\n'
        return 0
    fi
    return 1
}

python3() {
    if [[ "$BACKEND_AVAILABLE" == "1" ]]; then
        return 0
    fi
    printf 'No module named systemd\n' >&2
    return 1
}

systemctl() {
    case "${1:-} ${2:-}" in
        'is-active fail2ban')
            printf 'inactive\n'
            return 3
            ;;
        'is-enabled fail2ban')
            printf 'disabled\n'
            return 1
            ;;
        'is-enabled fail2ban.service')
            printf 'disabled\n'
            return 1
            ;;
        'restart fail2ban.service')
            printf '%s' "$(( $(<"$RESTART_COUNT_FILE") + 1 ))" > "$RESTART_COUNT_FILE"
            return 0
            ;;
        'is-failed fail2ban.service')
            if [[ "$SERVICE_FAILED" == "1" ]]; then
                printf 'failed\n'
                return 0
            fi
            printf 'active\n'
            return 1
            ;;
        'stop fail2ban')
            printf '%s' "$(( $(<"$STOP_COUNT_FILE") + 1 ))" > "$STOP_COUNT_FILE"
            return 0
            ;;
        'cat fail2ban.service')
            return 0
            ;;
    esac
    return 0
}

fail2ban-client() {
    local count=0

    if [[ "${1:-}" == "-t" ]]; then
        printf '%s' "$(( $(<"$CONFIG_TEST_COUNT_FILE") + 1 ))" > "$CONFIG_TEST_COUNT_FILE"
        return "$CONFIG_TEST_STATUS"
    fi
    if [[ "${1:-}" == "ping" ]]; then
        count=$(( $(<"$PING_COUNT_FILE") + 1 ))
        printf '%s' "$count" > "$PING_COUNT_FILE"
        if [[ "$PING_ALWAYS_FAIL" == "1" ]] || (( count < PING_READY_AFTER )); then
            printf 'Server not ready\n' >&2
            return 1
        fi
        printf 'Server replied: pong\n'
        return 0
    fi
    if [[ "${1:-} ${2:-}" == "status sshd" ]]; then
        printf 'Status for the jail: sshd\n'
        return 0
    fi
    case "${1:-} ${2:-} ${3:-}" in
        'get sshd maxretry') printf '5\n'; return 0 ;;
        'get sshd findtime') printf '3600\n'; return 0 ;;
        'get sshd bantime') printf '86400\n'; return 0 ;;
        'get sshd actions') printf "['iptables-multiport']\n"; return 0 ;;
    esac
    if [[ "${1:-} ${2:-} ${3:-} ${4:-}" == \
          'get sshd actionproperties iptables-multiport' ]]; then
        printf "['port', 'protocol']\n"
        return 0
    fi
    if [[ "${1:-} ${2:-} ${3:-} ${4:-} ${5:-}" == \
          'get sshd action iptables-multiport port' ]]; then
        printf '7066\n'
        return 0
    fi
    return 1
}

reset_case() {
    local name="$1"
    local case_dir="$TEST_DIR/$name"

    mkdir -p "$case_dir/jail.d"
    FAIL2BAN_JAIL_FILE="$case_dir/jail.local"
    FAIL2BAN_JAIL_D_DIR="$case_dir/jail.d"
    FAIL2BAN_AUTH_LOG_FILE="$case_dir/auth.log"
    BACKUP_DIR="$case_dir/backups"
    JOURNAL_AVAILABLE=0
    BACKEND_AVAILABLE=0
    CONFIG_TEST_STATUS=0
    PING_READY_AFTER=1
    PING_ALWAYS_FAIL=0
    SERVICE_FAILED=0
    PING_COUNT_FILE="$case_dir/ping-count"
    CONFIG_TEST_COUNT_FILE="$case_dir/config-test-count"
    RESTART_COUNT_FILE="$case_dir/restart-count"
    STOP_COUNT_FILE="$case_dir/stop-count"
    printf '0' > "$PING_COUNT_FILE"
    printf '0' > "$CONFIG_TEST_COUNT_FILE"
    printf '0' > "$RESTART_COUNT_FILE"
    printf '0' > "$STOP_COUNT_FILE"
    : > "$LOG_FILE"
}

reset_case systemd-success
JOURNAL_AVAILABLE=1
BACKEND_AVAILABLE=1
PING_READY_AFTER=3
update_fail2ban_sshd_jail 7066 full 1 || \
    fail_test "journald-only environment was rejected"
assert_file_contains "$FAIL2BAN_JAIL_FILE" 'backend = systemd'
assert_file_not_contains "$FAIL2BAN_JAIL_FILE" 'logpath = /var/log/auth.log'
[[ "$(<"$CONFIG_TEST_COUNT_FILE")" == "1" ]] || fail_test "configuration test was not run once"
[[ "$(<"$RESTART_COUNT_FILE")" == "1" ]] || fail_test "service was not restarted once"
(( $(<"$PING_COUNT_FILE") >= 3 )) || fail_test "delayed readiness was not retried"

reset_case file-success
printf 'Aug 11 host sshd[124]: Accepted publickey\n' > "$FAIL2BAN_AUTH_LOG_FILE"
update_fail2ban_sshd_jail 7066 full 1 || \
    fail_test "reliable file log environment was rejected"
assert_file_contains "$FAIL2BAN_JAIL_FILE" "logpath = $FAIL2BAN_AUTH_LOG_FILE"
assert_file_not_contains "$FAIL2BAN_JAIL_FILE" 'backend = systemd'

reset_case preserve-backend
printf '[sshd]\nbackend = poll\n' > "$FAIL2BAN_JAIL_FILE"
update_fail2ban_sshd_jail 7066 full 1 || \
    fail_test "explicit user backend was rejected"
assert_file_contains "$FAIL2BAN_JAIL_FILE" 'backend = poll'
assert_file_not_contains "$FAIL2BAN_JAIL_FILE" 'backend = systemd'

reset_case preserve-logpath
printf '[sshd]\nlogpath = /srv/log/secure-auth.log\n' > "$FAIL2BAN_JAIL_FILE"
update_fail2ban_sshd_jail 7066 full 1 || \
    fail_test "explicit user logpath was rejected"
assert_file_contains "$FAIL2BAN_JAIL_FILE" 'logpath = /srv/log/secure-auth.log'

reset_case no-source
if update_fail2ban_sshd_jail 7066 full 1; then
    fail_test "unknown log source was accepted"
fi
[[ ! -e "$FAIL2BAN_JAIL_FILE" ]] || fail_test "unknown source left a jail.local"
[[ ! -e "$BACKUP_DIR" ]] || fail_test "unknown source entered the backup transaction"
[[ "$(<"$CONFIG_TEST_COUNT_FILE")" == "0" ]] || fail_test "unknown source ran fail2ban-client -t"
[[ "$(<"$RESTART_COUNT_FILE")" == "0" ]] || fail_test "unknown source restarted Fail2ban"

reset_case config-test-rollback
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_FILE"
original_config=$(<"$FAIL2BAN_JAIL_FILE")
JOURNAL_AVAILABLE=1
BACKEND_AVAILABLE=1
CONFIG_TEST_STATUS=9
if update_fail2ban_sshd_jail 7066 full 1; then
    fail_test "failed systemd backend configuration test was accepted"
fi
[[ "$(<"$FAIL2BAN_JAIL_FILE")" == "$original_config" ]] || \
    fail_test "configuration-test failure did not restore the original jail.local"
[[ "$(<"$CONFIG_TEST_COUNT_FILE")" == "1" ]] || fail_test "configuration-test failure did not run -t"
[[ "$(<"$RESTART_COUNT_FILE")" == "0" ]] || fail_test "configuration-test failure restarted the service"
[[ "$(<"$STOP_COUNT_FILE")" == "1" ]] || fail_test "configuration-test rollback did not restore inactive state"
if grep -Fq '自动回滚不完整' "$LOG_FILE"; then
    fail_test "configuration-test failure reported an incomplete rollback"
fi

reset_case failed-service-rollback
printf '[DEFAULT]\nignoreip = 127.0.0.1/8\n' > "$FAIL2BAN_JAIL_FILE"
original_config=$(<"$FAIL2BAN_JAIL_FILE")
JOURNAL_AVAILABLE=1
BACKEND_AVAILABLE=1
PING_ALWAYS_FAIL=1
SERVICE_FAILED=1
if update_fail2ban_sshd_jail 7066 full 1; then
    fail_test "failed service was accepted"
fi
[[ "$(<"$FAIL2BAN_JAIL_FILE")" == "$original_config" ]] || \
    fail_test "failed service did not restore the original jail.local"
[[ "$(<"$RESTART_COUNT_FILE")" == "1" ]] || fail_test "failed service path did not attempt one restart"
if grep -Fq '自动回滚不完整' "$LOG_FILE"; then
    fail_test "failed service reported an incomplete rollback"
fi

printf 'Fail2ban log source tests passed.\n'
