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
    echo "Kernel storage test failed: $1" >&2
    exit 1
}

assert_released() {
    local expected="$1"
    shift
    local actual

    actual=$(calculate_kernel_released_bytes "$@")
    [[ "$actual" == "$expected" ]] || \
        fail_test "expected released=$expected, got $actual"
}

df() {
    printf '       Used\n'
    printf '2416510000\n'
}

large_value=$(get_filesystem_used_bytes /) || \
    fail_test "a valid large df byte count was rejected"
[[ "$large_value" == "2416510000" ]] || \
    fail_test "df byte count was converted to [$large_value] instead of preserving decimal digits"

# / and /boot are the same filesystem: only the root delta is counted.
assert_released 429496729 \
    10737418240 10307921511 \
    10737418240 10307921511 \
    same same 100 100 100 100

# /boot is separate: positive root and boot deltas are added.
assert_released 419430400 \
    5368709120 5316280320 \
    524288000 157286400 \
    separate separate 100 100 200 200

# The root filesystem is unchanged, but a separate /boot shrinks.
assert_released 367001600 \
    5368709120 5368709120 \
    524288000 157286400 \
    separate separate 100 100 200 200

# Missing or unavailable /boot safely falls back to the comparable root delta.
assert_released 10485760 \
    5368709120 5358223360 \
    '' '' \
    missing missing 100 100 '' ''
assert_released 10485760 \
    5368709120 5358223360 \
    '' '' \
    separate-unavailable separate-unavailable 100 100 200 200

# Invalid df/stat-derived values do not enter arithmetic or create a large result.
assert_released 0 \
    '2.41651e+09' '' \
    524288000 157286400 \
    unknown unknown '' '' '' ''
assert_released 0 \
    5368709120 5358223360 \
    524288000 157286400 \
    separate separate 100 101 200 201

# Filesystem usage growth is clamped to zero rather than becoming negative.
assert_released 0 \
    1000 2000 \
    3000 4000 \
    separate separate 100 100 200 200

printf 'Kernel storage tests passed.\n'
