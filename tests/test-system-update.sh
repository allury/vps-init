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
APT_CAPTURE_FILE="$TEST_DIR/apt-arguments"

apt-get() {
    printf '%s\n' "$@" > "$APT_CAPTURE_FILE"
    printf '%s\n' "$APT_SIMULATED_OUTPUT"
}

apt_update_strict >/dev/null || fail_test "strict package index refresh failed"
grep -Fxq 'Acquire::Retries=3' "$APT_CAPTURE_FILE" || \
    fail_test "apt update did not configure retries"
grep -Fxq 'APT::Update::Error-Mode=any' "$APT_CAPTURE_FILE" || \
    fail_test "apt update did not reject partial index failures"
grep -Fxq update "$APT_CAPTURE_FILE" || fail_test "apt update was not invoked"

APT_SIMULATED_OUTPUT=$'Inst base-files [12.4] (12.12+deb12u1 Debian:12.12/oldstable [amd64])\nInst linux-image-amd64 [6.1.140-1] (6.1.148-1 Debian-Security:12/oldstable-security [amd64])'
mapfile -t installs < <(printf '%s\n' "$APT_SIMULATED_OUTPUT" | parse_apt_simulated_installs)
[[ "${installs[*]}" == "base-files linux-image-amd64" ]] || \
    fail_test "simulated install parser returned unexpected packages"
mapfile -t version_records < <(
    printf '%s\n' "$APT_SIMULATED_OUTPUT" | parse_apt_simulated_install_versions
)
[[ "${version_records[0]}" == $'base-files\t12.12+deb12u1' ]] || \
    fail_test "simulated install version parser rejected base-files"
[[ "${version_records[1]}" == $'linux-image-amd64\t6.1.148-1' ]] || \
    fail_test "simulated install version parser rejected kernel meta-package"

APT_SIMULATED_OUTPUT=$'Remv obsolete-package [1.0]\nPurg old-config [2.0]'
mapfile -t removals < <(printf '%s\n' "$APT_SIMULATED_OUTPUT" | parse_apt_simulated_removals)
[[ "${removals[*]}" == "obsolete-package old-config" ]] || \
    fail_test "simulated removal parser returned unexpected packages"
if validate_package_install_without_removals "unsafe plan" example-package >/dev/null 2>&1; then
    fail_test "an install preview containing removals was accepted"
fi

OS_ID=debian
OS_ARCH=amd64
for package in linux-image-amd64 linux-image-cloud-amd64; do
    is_kernel_meta_package_name "$package" || fail_test "$package was rejected"
done
for package in linux-image-6.1.0-31-amd64 linux-headers-6.1.0-31-amd64; do
    if is_kernel_meta_package_name "$package"; then
        fail_test "$package was accepted as a root meta-package"
    fi
done

assert_flavor() {
    local release="$1"
    local expected="$2"
    local actual=""

    actual=$(kernel_flavor_from_release "$release") || \
        fail_test "kernel flavor could not be parsed for $release"
    [[ "$actual" == "$expected" ]] || \
        fail_test "kernel flavor for $release expected $expected, got $actual"
}

assert_flavor 6.1.0-31-amd64 amd64
assert_flavor 6.1.0-31-cloud-amd64 cloud-amd64
assert_flavor 6.12.38+deb13-amd64 amd64
assert_flavor 6.12.38+deb13-cloud-amd64 cloud-amd64

latest=$(latest_installed_kernel_for_current_flavor \
    6.1.0-31-cloud-amd64 \
    6.1.0-31-amd64 \
    6.1.0-31-cloud-amd64 \
    6.1.0-40-cloud-amd64)
[[ "$latest" == "6.1.0-40-cloud-amd64" ]] || \
    fail_test "latest installed cloud kernel was not selected"

INSTALLED_METAS=$'linux-image-amd64\nlinux-image-cloud-amd64'
list_installed_kernel_root_meta_packages() {
    printf '%s\n' "$INSTALLED_METAS"
}

collect_compatible_kernel_meta_packages 6.1.0-31-amd64 || \
    fail_test "standard Debian meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == "linux-image-amd64" ]] || \
    fail_test "standard kernel selected an unrelated meta-package"
collect_compatible_kernel_meta_packages 6.1.0-31-cloud-amd64 || \
    fail_test "cloud Debian meta-package collection failed"
[[ "${KERNEL_META_CANDIDATES[*]}" == "linux-image-cloud-amd64" ]] || \
    fail_test "cloud kernel selected an unrelated meta-package"

OS_CODENAME=trixie
kernel_source_record_allowed \
    $'https://mirror.vendor.example/debian trixie/main amd64 Packages\trelease v=13.0,o=Debian,a=stable,n=trixie,l=Debian,c=main,b=amd64\torigin mirror.vendor.example' || \
    fail_test "official Trixie metadata from a non-default mirror hostname was rejected"
if kernel_source_record_allowed \
    $'https://mirror.vendor.example/debian sid/main amd64 Packages\trelease o=Debian,a=unstable,n=sid,l=Debian,c=main,b=amd64\torigin mirror.vendor.example'; then
    fail_test "unstable source metadata was accepted"
fi
if kernel_source_record_allowed \
    $'https://mirror.vendor.example/debian bookworm/main amd64 Packages\trelease o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\torigin mirror.vendor.example'; then
    fail_test "cross-version source metadata was accepted"
fi

printf 'Debian system update tests passed.\n'
