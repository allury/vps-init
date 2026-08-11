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
    echo "Kernel cleanup test failed: $1" >&2
    exit 1
}

assert_array_set() {
    local array_name="$1"
    local expected="$2"
    local actual
    local -n values="$array_name"

    actual=$(printf '%s\n' "${values[@]}" | sed '/^$/d' | sort -V)
    [[ "$actual" == "$expected" ]] || \
        fail_test "$array_name mismatch; expected [$expected], got [$actual]"
}

assert_cleanup_meta() {
    is_kernel_cleanup_meta_package "$1" || \
        fail_test "$1 should be accepted as a removable kernel route meta-package"
}

assert_not_cleanup_meta() {
    if is_kernel_cleanup_meta_package "$1"; then
        fail_test "$1 should not be accepted as a removable kernel route meta-package"
    fi
}

APT_SIMULATED_OUTPUT=""
apt-get() {
    printf '%s\n' "$APT_SIMULATED_OUTPUT"
}

OS_ID=debian
build_old_kernel_release_plan keep-fallback 6.12.96+deb13-amd64 \
    6.12.94+deb13-amd64 \
    6.12.95+deb13-amd64 \
    6.12.96+deb13-amd64 \
    6.12.99+deb13-cloud-amd64 || \
    fail_test "Debian mixed-route fallback plan was rejected"
assert_array_set RETAINED_KERNEL_RELEASES $'6.12.95+deb13-amd64\n6.12.96+deb13-amd64'
assert_array_set OLD_KERNEL_RELEASES $'6.12.94+deb13-amd64\n6.12.99+deb13-cloud-amd64'
[[ "$FALLBACK_KERNEL" == "6.12.95+deb13-amd64" ]] || \
    fail_test "Debian fallback kernel was not selected from the running flavor"

build_old_kernel_release_plan current-only 6.12.96+deb13-amd64 \
    6.12.94+deb13-amd64 \
    6.12.95+deb13-amd64 \
    6.12.96+deb13-amd64 \
    6.12.99+deb13-cloud-amd64 || \
    fail_test "Debian current-only plan was rejected"
assert_array_set RETAINED_KERNEL_RELEASES '6.12.96+deb13-amd64'
assert_array_set OLD_KERNEL_RELEASES $'6.12.94+deb13-amd64\n6.12.95+deb13-amd64\n6.12.99+deb13-cloud-amd64'

if build_old_kernel_release_plan keep-fallback 6.12.96+deb13-amd64 \
    6.12.96+deb13-amd64 6.12.97+deb13-amd64; then
    fail_test "cleanup should stop when a newer running-flavor kernel is installed"
fi

OS_ID=debian
assert_cleanup_meta linux-image-cloud-amd64
assert_cleanup_meta linux-headers-cloud-amd64
assert_not_cleanup_meta linux-image-6.12.99+deb13-cloud-amd64
assert_not_cleanup_meta linux-headers-6.12.99+deb13-cloud-amd64
assert_not_cleanup_meta linux-base

parsed_records=$(printf '%s\n' \
    $'linux-image-6.12.96+deb13-amd64:amd64\tii ' \
    $'linux-image-6.12.95+deb13-amd64:amd64\trc ' \
    $'linux-image-6.12.94+deb13-amd64:amd64\tun ' |
    parse_kernel_package_records)
[[ "$parsed_records" == $'linux-image-6.12.96+deb13-amd64\tii\nlinux-image-6.12.95+deb13-amd64\trc' ]] || \
    fail_test "installed/residual kernel package record parsing is incorrect"

RETAINED_KERNEL_RELEASES=(
    6.12.96+deb13-amd64
    6.12.95+deb13-amd64
)
kernel_versioned_package_matches_retained_release \
    linux-image-6.12.96+deb13-amd64 || \
    fail_test "current Debian image package was not protected"
kernel_versioned_package_matches_retained_release \
    linux-headers-6.12.96+deb13-common || \
    fail_test "shared Debian headers for a retained release were not protected"
if kernel_versioned_package_matches_retained_release \
    linux-image-6.12.94+deb13-amd64; then
    fail_test "old Debian image package was incorrectly protected"
fi

OLD_KERNEL_PACKAGES=(linux-image-6.12.99+deb13-cloud-amd64)
RETAINED_KERNEL_RELEASES=(6.12.96+deb13-amd64)
ACTIVE_KERNEL_META=linux-image-amd64
APT_SIMULATED_OUTPUT=$'Purg linux-image-6.12.99+deb13-cloud-amd64 [6.12.99-1]\nRemv linux-image-cloud-amd64:amd64 [6.12.99-1]'
OS_ID=debian
validate_old_kernel_removal_plan || \
    fail_test "safe removal of another Debian kernel route was rejected"
assert_array_set OLD_KERNEL_META_PACKAGES 'linux-image-cloud-amd64'

APT_SIMULATED_OUTPUT=$'Purg linux-image-6.12.99+deb13-cloud-amd64 [6.12.99-1]\nRemv linux-image-amd64 [6.12.99-1]'
if validate_old_kernel_removal_plan; then
    fail_test "removal of the active kernel meta-package should be rejected"
fi

APT_SIMULATED_OUTPUT=$'Purg linux-image-6.12.99+deb13-cloud-amd64 [6.12.99-1]\nRemv libc6 [2.40-1]'
if validate_old_kernel_removal_plan; then
    fail_test "non-kernel collateral removal should be rejected"
fi

APT_SIMULATED_OUTPUT='Remv linux-image-cloud-amd64 [6.12.99-1]'
if validate_old_kernel_removal_plan; then
    fail_test "a preview missing the requested versioned kernel should be rejected"
fi

ACTIVE_KERNEL_META=""
APT_SIMULATED_OUTPUT=$'Purg linux-image-6.12.99+deb13-cloud-amd64 [6.12.99-1]\nRemv linux-image-cloud-amd64 [6.12.99-1]'
if validate_old_kernel_removal_plan; then
    fail_test "meta-package removal should be rejected when the active route is unknown"
fi

ACTIVE_KERNEL_META=linux-image-amd64
OLD_KERNEL_PACKAGES=(linux-image-6.12.96+deb13-amd64)
APT_SIMULATED_OUTPUT='Purg linux-image-6.12.96+deb13-amd64 [6.12.96-1]'
if validate_old_kernel_removal_plan; then
    fail_test "a retained running kernel package should be rejected even if it reaches the plan"
fi

echo "Kernel cleanup tests passed."
