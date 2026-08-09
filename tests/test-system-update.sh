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
APT_CAPTURED_ARGUMENTS=()

apt-get() {
    APT_CAPTURED_ARGUMENTS=("$@")
    if [[ -n "${APT_CAPTURE_FILE:-}" ]]; then
        printf '%s\n' "$@" > "$APT_CAPTURE_FILE"
    fi
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

apt_update_strict >/dev/null || fail_test "strict package index refresh failed"
[[ " ${APT_CAPTURED_ARGUMENTS[*]} " == *" Acquire::Retries=3 "* ]] || \
    fail_test "package index refresh did not configure retries"
[[ " ${APT_CAPTURED_ARGUMENTS[*]} " == *" APT::Update::Error-Mode=any "* ]] || \
    fail_test "package index refresh did not reject partial source failures"
[[ " ${APT_CAPTURED_ARGUMENTS[*]} " == *" update "* ]] || \
    fail_test "package index refresh did not invoke the update command"

APT_SIMULATED_OUTPUT=""
APT_CAPTURE_FILE="$TEST_DIR/apt-arguments"
validate_package_install_without_removals "test package" example-package || \
    fail_test "safe package installation preview was rejected"
grep -Fxq -- '--no-remove' "$APT_CAPTURE_FILE" || \
    fail_test "package installation preview did not enforce the no-removal boundary"
unset APT_CAPTURE_FILE

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

OS_ID=debian
[[ "$(latest_installed_kernel_for_current_flavor 6.12.96+deb13-amd64 \
    6.12.95+deb13-amd64 6.12.96+deb13-amd64 6.12.99+deb13-cloud-amd64)" == \
    "6.12.96+deb13-amd64" ]] || fail_test "another Debian kernel flavor affected the latest version"
[[ "$(latest_installed_kernel_for_current_flavor 6.12.96+deb13-amd64 \
    6.12.96+deb13-amd64 6.12.97+deb13-amd64)" == "6.12.97+deb13-amd64" ]] || \
    fail_test "the latest Debian running-flavor kernel was not selected"

OS_ID=ubuntu
[[ "$(latest_installed_kernel_for_current_flavor 6.8.0-136-generic \
    6.8.0-136-generic 6.8.0-200-aws)" == "6.8.0-136-generic" ]] || \
    fail_test "another Ubuntu kernel flavor affected the latest version"
if latest_installed_kernel_for_current_flavor custom-kernel \
    6.8.0-136-generic 6.8.0-200-aws >/dev/null 2>&1; then
    fail_test "an unrecognized running kernel should not produce a latest release"
fi

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
kernel_source_record_allowed $'https://deb.debian.org/debian trixie/main amd64 Packages\trelease v=13.6,o=Debian,a=stable,n=trixie,l=Debian,c=main,b=amd64\torigin deb.debian.org' || \
    fail_test "Debian stable source should be allowed"
kernel_source_record_allowed $'https://security.debian.org/debian-security trixie-security/main amd64 Packages\trelease v=13,o=Debian,a=stable-security,n=trixie-security,l=Debian-Security,c=main,b=amd64\torigin security.debian.org' || \
    fail_test "Debian security source should be allowed"
OS_CODENAME=bookworm
kernel_source_record_allowed $'https://deb.debian.org/debian oldstable/main amd64 Packages\trelease v=12.10,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\torigin deb.debian.org' || \
    fail_test "Debian oldstable alias matching the current codename should be allowed"
OS_CODENAME=trixie
kernel_source_record_allowed $'https://deb.debian.org/debian trixie/non-free-firmware amd64 Packages\trelease v=13.6,o=Debian,a=stable,n=trixie,l=Debian,c=non-free-firmware,b=amd64\torigin deb.debian.org' || \
    fail_test "Debian stable non-free-firmware source should be allowed"
if kernel_source_record_allowed $'https://deb.debian.org/debian trixie-backports/main amd64 Packages\trelease o=Debian Backports,a=stable-backports,n=trixie-backports,l=Debian Backports,c=main,b=amd64\torigin deb.debian.org'; then
    fail_test "Debian backports source should not be allowed"
fi
if kernel_source_record_allowed $'https://mirror.example/debian trixie/main amd64 Packages\trelease v=13.6,o=Example,a=stable,n=trixie,l=Example,c=main,b=amd64\torigin mirror.example'; then
    fail_test "a non-Debian release identity should not be allowed"
fi

OS_ID=ubuntu
OS_CODENAME=noble
kernel_source_record_allowed $'http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages\trelease v=24.04,o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=main,b=amd64\torigin archive.ubuntu.com' || \
    fail_test "Ubuntu updates source should be allowed"
kernel_source_record_allowed $'https://esm.ubuntu.com/infra/ubuntu noble-infra-security/main amd64 Packages\trelease v=24.04,o=UbuntuESM,a=noble-infra-security,n=noble,l=UbuntuESM,c=main,b=amd64\torigin esm.ubuntu.com' || \
    fail_test "Ubuntu ESM infrastructure security source should be allowed"
if kernel_source_record_allowed $'https://esm.ubuntu.com/apps/ubuntu noble-apps-security/main amd64 Packages\trelease v=24.04,o=UbuntuESM,a=noble-apps-security,n=noble,l=UbuntuESM,c=main,b=amd64\torigin esm.ubuntu.com'; then
    fail_test "Ubuntu ESM Apps source should require an explicit package-scope allowance"
fi
kernel_source_record_allowed \
    $'https://esm.ubuntu.com/apps/ubuntu noble-apps-security/main amd64 Packages\trelease v=24.04,o=UbuntuESM,a=noble-apps-security,n=noble,l=UbuntuESM,c=main,b=amd64\torigin esm.ubuntu.com' 1 || \
    fail_test "explicitly allowed Ubuntu ESM Apps source was rejected"
kernel_source_record_allowed $'http://archive.ubuntu.com/ubuntu noble-updates/restricted amd64 Packages\trelease v=24.04,o=Ubuntu,a=noble-updates,n=noble,l=Ubuntu,c=restricted,b=amd64\torigin archive.ubuntu.com' || \
    fail_test "Ubuntu updates restricted source should be allowed"
if kernel_source_record_allowed $'http://archive.ubuntu.com/ubuntu noble-proposed/main amd64 Packages\trelease v=24.04,o=Ubuntu,a=noble-proposed,n=noble,l=Ubuntu,c=main,b=amd64\torigin archive.ubuntu.com'; then
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

actual=$(
    printf '%s\n' \
        'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 Debian:13.0/stable [amd64])' \
        'Inst linux-image-6.12.60+deb13-amd64 (6.12.60-1 Debian:13.0/stable [amd64])' |
        parse_apt_simulated_install_versions
)
[[ "$actual" == $'linux-image-amd64\t6.12.60-1\nlinux-image-6.12.60+deb13-amd64\t6.12.60-1' ]] || \
    fail_test "APT simulated install version parser returned an unexpected result"

is_kernel_update_package linux-base || fail_test "linux-base should be in the kernel update boundary"
is_kernel_update_package initramfs-tools || fail_test "initramfs-tools should be in the kernel update boundary"
is_kernel_update_package amd64-microcode || fail_test "AMD microcode should be in the kernel update boundary"
if is_kernel_update_package libc6; then
    fail_test "libc6 should be outside the kernel update boundary"
fi
system_update_package_requires_release_validation base-files || \
    fail_test "base-files should be protected by the release boundary"
system_update_package_requires_release_validation libc6:amd64 || \
    fail_test "multiarch libc6 should be protected by the release boundary"
system_update_package_requires_release_validation linux-image-6.12.60+deb13-amd64 || \
    fail_test "kernel packages in a system upgrade should be protected by the release boundary"
if system_update_package_requires_release_validation bash; then
    fail_test "ordinary packages should not require official release-source validation"
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
APT_CAPTURE_FILE="$TEST_DIR/kernel-apt-arguments"
collect_update_plan kernel linux-image-amd64 || fail_test "kernel update preview failed"
grep -Fxq -- '--no-remove' "$APT_CAPTURE_FILE" || \
    fail_test "kernel update preview did not enforce the no-removal boundary"
unset APT_CAPTURE_FILE
validate_kernel_update_plan || fail_test "valid kernel update preview was rejected"
[[ "${UPDATE_NEW_PACKAGES[*]}" == "linux-image-6.12.60+deb13-amd64" ]] || \
    fail_test "new versioned kernel package was not classified"
CANDIDATE_KERNEL_IMAGES=(linux-image-6.12.60+deb13-amd64)
validate_planned_kernel_images || fail_test "declared target kernel image was rejected"

UPDATE_NEW_PACKAGES=(
    linux-image-6.12.60+deb13-amd64
    linux-headers-6.12.60+deb13-common
    linux-headers-6.12.60+deb13-amd64
)
validate_planned_kernel_images || \
    fail_test "same-release kernel headers were rejected"

UPDATE_NEW_PACKAGES=(
    linux-image-6.12.60+deb13-amd64
    linux-modules-6.12.61+deb13-cloud-amd64
)
if validate_planned_kernel_images; then
    fail_test "a versioned dependency from another kernel release should have been rejected"
fi

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

SOURCE_RECORD_MODE=official
list_package_version_sources() {
    printf 'https://deb.example/stable\trelease o=Debian,n=trixie,c=main\torigin Debian\n'
    if [[ "$SOURCE_RECORD_MODE" == "mixed" ]]; then
        printf 'https://mirror-user:mirror-secret@third-party.example/stable\trelease o=ThirdParty,n=trixie,c=main\torigin ThirdParty\n'
    fi
}
kernel_source_record_allowed() {
    [[ "$1" == *$'\trelease o=Debian,'* ]]
}
validate_official_candidate_source base-files 13.7 || \
    fail_test "an all-official candidate source set was rejected"
SOURCE_RECORD_MODE=mixed
source_failure_output=""
if source_failure_output=$(validate_official_candidate_source base-files 13.7 2>&1); then
    fail_test "a candidate version also supplied by an untrusted source was accepted"
fi
[[ "$source_failure_output" == *'https://***@third-party.example/stable'* ]] || \
    fail_test "rejected APT source credentials were not redacted"
if [[ "$source_failure_output" == *'mirror-user'* || \
      "$source_failure_output" == *'mirror-secret'* ]]; then
    fail_test "rejected APT source output exposed credentials"
fi

(
    INSTALL_VALIDATED_PAIRS=""
    validate_official_candidate_source() {
        INSTALL_VALIDATED_PAIRS+="$1=$2:apps=$3 "
    }
    APT_SIMULATED_OUTPUT=$'Inst fail2ban (1.0 stable [all])\nInst python3-systemd (235 stable [amd64])'
    validate_official_package_install_plan "Fail2ban" 1 fail2ban || \
        fail_test "official package installation plan was rejected"
    [[ "$INSTALL_VALIDATED_PAIRS" == *"fail2ban=1.0:apps=1 "* ]] || \
        fail_test "target package source was not validated"
    [[ "$INSTALL_VALIDATED_PAIRS" == *"python3-systemd=235:apps=1 "* ]] || \
        fail_test "installation dependency source was not validated"
    APT_SIMULATED_OUTPUT=$'Inst fail2ban (1.0 stable [all])\nRemv conflicting-package [1.0]'
    if validate_official_package_install_plan "Fail2ban" 1 fail2ban; then
        fail_test "package installation plan containing a removal was accepted"
    fi
)

VALIDATED_SOURCE_PAIRS=""
validate_official_candidate_source() {
    VALIDATED_SOURCE_PAIRS+="$1=$2 "
    [[ "$1" != "linux-firmware" ]]
}
UPDATE_SIMULATION_OUTPUT=$'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 stable [amd64])\nInst linux-image-6.12.60+deb13-amd64 (6.12.60-1 stable [amd64])'
UPDATE_UPGRADE_PACKAGES=(linux-image-amd64)
UPDATE_NEW_PACKAGES=(linux-image-6.12.60+deb13-amd64)
validate_kernel_update_sources || fail_test "valid kernel plan sources were rejected"
[[ "$VALIDATED_SOURCE_PAIRS" == *"linux-image-amd64=6.12.60-1 "* ]] || \
    fail_test "kernel meta-package source was not validated at its planned version"
[[ "$VALIDATED_SOURCE_PAIRS" == *"linux-image-6.12.60+deb13-amd64=6.12.60-1 "* ]] || \
    fail_test "versioned kernel source was not validated at its planned version"

VALIDATED_SOURCE_PAIRS=""
UPDATE_SIMULATION_OUTPUT=$'Inst base-files [13.6] (13.7 stable [amd64])\nInst bash [5.2] (5.3 stable [amd64])'
UPDATE_UPGRADE_PACKAGES=(base-files bash)
UPDATE_NEW_PACKAGES=()
validate_system_update_release_sources || \
    fail_test "current-release core package source validation failed"
[[ "$VALIDATED_SOURCE_PAIRS" == "base-files=13.7 " ]] || \
    fail_test "release-boundary validation checked an unexpected package set"

UPDATE_SIMULATION_OUTPUT=$'Inst linux-image-amd64 [6.12.50-1] (6.12.60-1 stable [amd64])\nInst linux-firmware [20240101] (20240202 stable [all])'
UPDATE_UPGRADE_PACKAGES=(linux-image-amd64 linux-firmware)
UPDATE_NEW_PACKAGES=()
if validate_kernel_update_sources; then
    fail_test "kernel plan accepted a dependency whose source validation failed"
fi

echo "System update tests passed."
