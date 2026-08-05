#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

fail_test() {
    echo "Action flow test failed: $1" >&2
    exit 1
}

if cancel_output=$(confirm_action "Confirm test?" <<< "n"); then
    fail_test "negative confirmation should return a non-zero status"
fi
grep -Fq "已取消" <<< "$cancel_output" || fail_test "cancellation result was not displayed"
grep -Fq "未做任何更改" <<< "$cancel_output" || fail_test "cancellation safety message was not displayed"

confirm_output=$(confirm_action "Confirm test?" <<< "y") || fail_test "positive confirmation should succeed"
[[ -z "$confirm_output" ]] || fail_test "positive confirmation should not add a cancellation result"

success_output=$(action_success "测试操作" "验证通过")
grep -Fq "测试操作" <<< "$success_output" || fail_test "success label was not displayed"
grep -Fq "已完成" <<< "$success_output" || fail_test "success state was not displayed"
grep -Fq "测试操作 已完成：验证通过" "$LOG_FILE" || fail_test "success result was not logged"

partial_output=$(action_partial "测试操作" "附属步骤失败")
grep -Fq "部分完成" <<< "$partial_output" || fail_test "partial state was not displayed"
grep -Fq "[WARN] 测试操作 部分完成：附属步骤失败" "$LOG_FILE" || \
    fail_test "partial result was not logged as a warning"

echo "Action flow tests passed."
