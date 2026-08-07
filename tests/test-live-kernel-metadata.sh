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
    echo "Live kernel metadata test failed: $1" >&2
    exit 1
}

OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)
OS_CODENAME=$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/"/, "", $2); print $2}' /etc/os-release)

case "$OS_ID" in
    debian)
        meta_package="linux-image-amd64"
        expected_flavor="amd64"
        ;;
    ubuntu)
        meta_package="linux-image-generic"
        expected_flavor="generic"
        ;;
    *)
        fail_test "unsupported test runner: $OS_ID"
        ;;
esac

candidate_version=$(get_candidate_package_version "$meta_package")
[[ -n "$candidate_version" && "$candidate_version" != "(none)" ]] || \
    fail_test "candidate version not found for $meta_package"
validate_official_candidate_source "$meta_package" "$candidate_version" || \
    fail_test "candidate source validation failed for $meta_package"
collect_candidate_kernel_images "$meta_package" || \
    fail_test "candidate kernel dependency resolution failed for $meta_package"
validate_candidate_kernel_images "$expected_flavor" || \
    fail_test "candidate kernel flavor validation failed for $meta_package"

printf 'Validated %s %s -> %s\n' \
    "$OS_ID" "$meta_package" "${CANDIDATE_KERNEL_IMAGES[*]}"
