#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export VPS_INIT_LOG_MAX_BYTES=4096
export VPS_INIT_LOG_KEEP_LINES=12

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

fail_test() {
    echo "Logging test failed: $1" >&2
    exit 1
}

[[ -f "$LOG_FILE" ]] || fail_test "log file was not created"
if command -v stat >/dev/null 2>&1; then
    [[ "$(stat -c '%a' "$LOG_FILE")" == "600" ]] || fail_test "log file permissions are not 600"
fi

detail_output=$(detail "DNS" "VERIFY_TEST" $'\033[31mfirst line\033[0m\nsecond line')
[[ -z "$detail_output" ]] || fail_test "detail output should not be written to the terminal"
grep -Fq '[DETAIL] [DNS][VERIFY_TEST] first line second line' "$LOG_FILE" || \
    fail_test "detail context was not written as one line"
if LC_ALL=C grep -q $'\033' "$LOG_FILE"; then
    fail_test "ANSI escape sequences were not removed"
fi
detail "APT" "ERROR" 'source=https://user:pass@example.test/repo token=top-secret'
grep -Fq 'source=https://***@example.test/repo token=***' "$LOG_FILE" || \
    fail_test "credentials were not redacted from diagnostic logs"
if grep -Fq 'top-secret' "$LOG_FILE" || grep -Fq 'user:pass' "$LOG_FILE"; then
    fail_test "diagnostic log retained a credential value"
fi

mock_failed_command() {
    echo 'apt mock stderr token=command-secret' >&2
    return 42
}
if run_command_with_diagnostic "APT" "MOCK_FAILURE" mock_failed_command >/dev/null; then
    fail_test "diagnostic command runner inverted a nonzero exit status"
fi
grep -Fq '[DETAIL] [APT][MOCK_FAILURE] exit=42' "$LOG_FILE" || \
    fail_test "diagnostic command runner did not preserve the command exit code"
if grep -Fq 'command-secret' "$LOG_FILE"; then
    fail_test "diagnostic command runner logged a secret"
fi

DNS_VERIFY_FAILURE=""
if dns_verify_fail "VERIFY_SERVER" "requested server missing" "expected=1.1.1.1 actual=10.0.0.2"; then
    fail_test "dns_verify_fail should return a failure status"
fi
[[ "$DNS_VERIFY_FAILURE" == "requested server missing" ]] || \
    fail_test "DNS failure summary was not preserved"
grep -Fq '[DETAIL] [DNS][VERIFY_SERVER] expected=1.1.1.1 actual=10.0.0.2' "$LOG_FILE" || \
    fail_test "DNS diagnostics were not written"

long_message=$(printf 'x%.0s' {1..3000})
detail "TEST" "LIMIT" "$long_message"
last_line_size=$(tail -n 1 "$LOG_FILE" | wc -c)
(( last_line_size <= LOG_DETAIL_LIMIT + 100 )) || fail_test "detail line limit was not enforced"

for (( index=1; index<=300; index++ )); do
    printf '[2026-08-04 00:00:00] [DETAIL] [TEST][COMPACT] line-%03d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' \
        "$index" >> "$LOG_FILE"
done
compact_log_file

log_size=$(wc -c < "$LOG_FILE")
log_lines=$(wc -l < "$LOG_FILE")
(( log_size <= LOG_MAX_BYTES )) || fail_test "compacted log exceeds the configured size limit"
(( log_lines <= LOG_KEEP_LINES )) || fail_test "compacted log exceeds the configured line limit"
grep -Fq 'line-300-' "$LOG_FILE" || fail_test "latest log entries were not retained"
if command -v stat >/dev/null 2>&1; then
    [[ "$(stat -c '%a' "$LOG_FILE")" == "600" ]] || fail_test "compaction changed log permissions"
fi

echo "Logging tests passed."
