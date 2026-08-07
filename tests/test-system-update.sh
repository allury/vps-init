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
    echo "System update test failed: $1" >&2
    exit 1
}

APT_SIMULATED_OUTPUT=""
INSTALLED_PACKAGE_LIST=""

apt-get() {
    printf '%s\n' "$APT_SIMULATED_OUTPUT"
}

package_is_installed() {
    grep -Fxq -- "$1" <<< "$INSTALLED_PACKAGE_LIST"
}

assert_meta_package() {
    is_kernel_meta_package_name "$1" || fail_test "$1 should be accepted as a kernel meta package"
}

assert_not_meta_package() {
    if is_kernel_meta_package_name "$1"; then
        fail_test "$1 should not be accepted as a kernel meta package"
    fi
}

OS_ID=debian
OS_CODENAME=trixie
assert_meta_package linux-image-amd64
assert_meta_package linux-image-cloud-amd64
assert_not_meta_package linux-headers-amd64
assert_not_meta_package linux-image-6.12.96+deb13-amd64
assert_not_meta_package linux-image-amd64-dbg
assert_not_meta_package linux-base

OS_ID=ubuntu
OS_CODENAME=noble
assert_meta_package linux-generic
assert_meta_package linux-generic-hwe-24.04
assert_meta_package linux-image-generic
assert_meta_package linux-virtual
assert_meta_package linux-aws
assert_not_meta_package linux-headers-generic
assert_not_meta_package linux-image-6.8.0-136-generic

OS_ID=debian
[[ "$(kernel_flavor_from_release 6.12.96+deb13-amd64)" == "amd64" ]] || \
    fail_test "Debian amd64 flavor was not detected"
[[ "$(kernel_flavor_from_release 6.12.96+deb13-cloud-amd64)" == "cloud-amd64" ]] || \
    fail_test "Debian cloud flavor was not detected"
[[ "$(kernel_flavor_from_release 6.1.0-37-cloud-amd64)" == "cloud-amd64" ]] || \
    fail_test "Debian legacy cloud flavor was not detected"

OS_ID=ubuntu
[[ "$(kernel_flavor_from_release 6.8.0-136-generic)" == "generic" ]] || \
    fail_test "Ubuntu generic flavor was not detected"
[[ "$(kernel_flavor_from_release 6.8.0-1030-aws)" == "aws" ]] || \
    fail_test "Ubuntu AWS flavor was not detected"

INSTALLED_META_PACKAGE_LIST=""
list_installed_kernel_root_meta_packages() {
    printf '%s\n' "$INSTALLED_META_PACKAGE_LIST"
}

OS_ID=debian
INSTALLED_META_PACKAGE_LIST=$'linux-image-amd64\nlinux-image-cloud-amd64\nlinux-headers-amd64'
collect_compatible_kernel_meta_packages 6.12.96+deb13-cloud-amd64 || \
    fail_test "Debian cloud meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == "linux-image-cloud-amd64" ]] || \
    fail_test "Debian cloud kernel selected the wrong meta-package route"

collect_compatible_kernel_meta_packages 6.12.96+deb13-amd64 || \
    fail_test "Debian standard meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == "linux-image-amd64" ]] || \
    fail_test "Debian standard kernel selected the wrong meta-package route"

OS_ID=ubuntu
INSTALLED_META_PACKAGE_LIST=$'linux-generic\nlinux-image-generic\nlinux-generic-hwe-24.04\nlinux-image-generic-hwe-24.04\nlinux-aws'
collect_compatible_kernel_meta_packages 6.8.0-136-generic || \
    fail_test "Ubuntu generic meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == $'linux-generic linux-generic-hwe-24.04' ]] || \
    fail_test "Ubuntu duplicate image meta-packages were not collapsed by route"

collect_compatible_kernel_meta_packages 6.8.0-1030-aws || \
    fail_test "Ubuntu AWS meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == "linux-aws" ]] || \
    fail_test "Ubuntu AWS kernel selected the wrong meta-package route"

OS_ID=debian
OS_CODENAME=trixie
kernel_source_record_allowed 'https://deb.debian.org/debian trixie/main amd64 Packages' || \
    fail_test "Debian stable source should be allowed"
kernel_source_record_allowed 'https://security.debian.org/debian-security trixie-security/main amd64 Packages' || \
    fail_test "Debian security source should be allowed"
if kernel_source_record_allowed 'https://deb.debian.org/debian trixie-backports/main amd64 Packages'; then
    fail_test "Debian backports source should not be allowed"
fi

OS_ID=ubuntu
OS_CODENAME=noble
kernel_source_record_allowed 'http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages' || \
    fail_test "Ubuntu updates source should be allowed"
if kernel_source_record_allowed 'http://archive.ubuntu.com/ubuntu noble-proposed/main amd64 Packages'; then
    fail_test "Ubuntu proposed source should not be allowed"
fi

actual=$(
    printf '%s\n' \
        'linux-generic' \
        '  Depends: linux-image-generic' \
        'linux-image-generic' \
        ' |Depends: <linux-image-6.8.0-136-generic>' \
        '  Depends: linux-modules-extra-6.8.0-136-generic' |
        parse_candidate_kernel_image_dependencies
)
[[ "$actual" == "linux-image-6.8.0-136-generic" ]] || \
    fail_test "candidate kernel image dependency parser returned an unexpected result"

is_kernel_update_package linux-base || fail_test "linux-base should be in the kernel update boundary"
is_kernel_update_package initramfs-tools || fail_test "initramfs-tools should be in the kernel update boundary"
is_kernel_update_package amd64-microcode || fail_test "AMD microcode should be in the kernel update boundary"
if is_kernel_update_package libc6; then
    fail_test "libc6 should be outside the kernel update boundary"
fi

APT_SIMULATED_OUTPUT=$'Inst bash [5.2] (5.3 stable [amd64])'
INSTALLED_PACKAGE_LIST="bash"
collect_update_plan regular || fail_test "regular update preview failed"
[[ "${UPDATE_UPGRADE_PACKAGES[*]}" == "bash" ]] || fail_test "regular upgrade package was not classified"
(( ${#UPDATE_NEW_PACKAGES[@]} == 0 )) || fail_test "regular preview unexpectedly classified a new package"
(( ${#UPDATE_REMOVE_PACKAGES[@]} == 0 )) || fail_test "regular preview unexpectedly classified a removal"
validate_regular_update_plan || fail_test "valid regular update preview was rejected"

APT_SIMULATED_OUTPUT=$'Inst bash [5.2] (5.3 stable [amd64])\nInst new-dependency (1.0 stable [amd64])\nRemv obsolete-package [1.0]'
INSTALLED_PACKAGE_LIST="bash"
collect_update_plan full || fail_test "full update preview failed"
[[ "${UPDATE_UPGRADE_PACKAGES[*]}" == "bash" ]] || fail_test "full update did not classify the existing package"
[[ "${UPDATE_NEW_PACKAGES[*]}" == "new-dependency" ]] || fail_test "full update did not classify the new dependency"
[[ "${UPDATE_REMOVE_PACKAGES[*]}" == "obsolete-package" ]] || fail_test "full update did not classify the removal"
if validate_regular_update_plan; then
    fail_test "unsafe regular update preview should have been rejected"
fi

APT_SIMULATED_OUTPUT=$'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 stable [amd64])\nInst linux-image-6.12.60+deb13-amd64 (6.12.60-1 stable [amd64])\nInst initramfs-tools [0.148] (0.149 stable [all])'
INSTALLED_PACKAGE_LIST=$'linux-image-amd64\ninitramfs-tools'
OS_ID=debian
collect_update_plan kernel linux-image-amd64 || fail_test "kernel update preview failed"
validate_kernel_update_plan || fail_test "valid kernel update preview was rejected"
[[ "${UPDATE_NEW_PACKAGES[*]}" == "linux-image-6.12.60+deb13-amd64" ]] || \
    fail_test "new versioned kernel package was not classified"
CANDIDATE_KERNEL_IMAGES=(linux-image-6.12.60+deb13-amd64)
validate_planned_kernel_images || fail_test "declared target kernel image was rejected"

UPDATE_NEW_PACKAGES=(linux-image-6.12.61+deb13-cloud-amd64)
if validate_planned_kernel_images; then
    fail_test "undeclared target kernel image should have been rejected"
fi

APT_SIMULATED_OUTPUT=$'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 stable [amd64])\nInst libc6 [2.40] (2.41 stable [amd64])'
INSTALLED_PACKAGE_LIST=$'linux-image-amd64\nlibc6'
collect_update_plan kernel linux-image-amd64 || fail_test "unexpected-package preview failed"
if validate_kernel_update_plan; then
    fail_test "kernel update preview containing libc6 should have been rejected"
fi

APT_SIMULATED_OUTPUT=$'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 stable [amd64])\nRemv old-support-package [1.0]'
INSTALLED_PACKAGE_LIST="linux-image-amd64"
collect_update_plan kernel linux-image-amd64 || fail_test "kernel removal preview failed"
if validate_kernel_update_plan; then
    fail_test "kernel update preview containing a removal should have been rejected"
fi

echo "System update tests passed."
