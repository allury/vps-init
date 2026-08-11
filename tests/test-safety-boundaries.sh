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
    echo "Safety boundary test failed: $1" >&2
    exit 1
}

for port in 22 1024 7066 65535; do
    is_valid_ssh_port "$port" || fail_test "valid SSH port $port was rejected"
done
for port in '' 0 21 23 999 65536 07066 123456 abc; do
    if is_valid_ssh_port "$port"; then
        fail_test "invalid SSH port [$port] was accepted"
    fi
done

SSHD_EFFECTIVE_CONFIG=$'port 22\nport 7066\nport 22\npasswordauthentication no'
sshd() {
    printf '%s\n' "$SSHD_EFFECTIVE_CONFIG"
}

[[ "$(get_configured_ssh_ports)" == "22,7066" ]] || \
    fail_test "multiple effective SSH ports were not collected and deduplicated"
ssh_uses_only_port 7066 7066 7066 || \
    fail_test "a single matching SSH port was rejected"
if ssh_uses_only_port 7066 22,7066 22,7066; then
    fail_test "multiple configured and listening SSH ports were accepted"
fi
if ssh_uses_only_port 7066 7066 22,7066; then
    fail_test "an additional listening SSH port was accepted"
fi

unset SSH_CONNECTION || true
if current_ssh_session_uses_ipv6; then
    fail_test "an absent SSH session was classified as IPv6"
fi
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22'
if current_ssh_session_uses_ipv6; then
    fail_test "an IPv4 SSH session was classified as IPv6"
fi
SSH_CONNECTION='2001:db8::10 50000 2001:db8::20 22'
current_ssh_session_uses_ipv6 || \
    fail_test "an IPv6 SSH session was not detected"
SSH_CONNECTION='malformed value'
if current_ssh_session_uses_ipv6; then
    fail_test "a malformed SSH session was classified as IPv6"
fi

(( $(swap_memory_headroom_bytes $((512 * 1024 * 1024))) == 64 * 1024 * 1024 )) || \
    fail_test "small-memory SWAP headroom is incorrect"
(( $(swap_memory_headroom_bytes $((2 * 1024 * 1024 * 1024))) == 214748364 )) || \
    fail_test "proportional SWAP headroom is incorrect"
swap_creation_capacity_is_safe $((1280 * 1024 * 1024)) $((1024 * 1024 * 1024)) || \
    fail_test "safe SWAP creation capacity was rejected"
if swap_creation_capacity_is_safe $((1280 * 1024 * 1024 - 1)) $((1024 * 1024 * 1024)); then
    fail_test "insufficient SWAP creation capacity was accepted"
fi
swap_removal_capacity_is_safe 1 0 $((1024 * 1024 * 1024)) || \
    fail_test "an unused SWAP could not be removed"
swap_removal_capacity_is_safe $((320 * 1024 * 1024)) $((128 * 1024 * 1024)) \
    $((1024 * 1024 * 1024)) || fail_test "safe SWAP removal capacity was rejected"
if swap_removal_capacity_is_safe $((192 * 1024 * 1024)) $((128 * 1024 * 1024)) \
    $((1024 * 1024 * 1024)); then
    fail_test "SWAP removal without memory headroom was accepted"
fi

FSTAB_NEWLINE_TEST="$TEST_DIR/fstab-newline"
printf '/dev/root / ext4 defaults 0 1' > "$FSTAB_NEWLINE_TEST"
ensure_text_file_ends_with_newline "$FSTAB_NEWLINE_TEST" || \
    fail_test "an unterminated fstab line could not be normalized"
printf '/swapfile none swap sw 0 0 # managed by vps-init\n' >> "$FSTAB_NEWLINE_TEST"
[[ "$(wc -l < "$FSTAB_NEWLINE_TEST")" == "2" ]] || \
    fail_test "a SWAP fstab entry was joined to an unterminated previous line"
ensure_text_file_ends_with_newline "$FSTAB_NEWLINE_TEST" || \
    fail_test "a terminated fstab file was rejected"
[[ "$(wc -l < "$FSTAB_NEWLINE_TEST")" == "2" ]] || \
    fail_test "newline normalization added an extra blank line"

SWAP_TEST_FSTAB="$TEST_DIR/fstab"
printf '# no swap\n' > "$SWAP_TEST_FSTAB"
SWAPON_TEST_OUTPUT=""
swapon() {
    printf '%s' "$SWAPON_TEST_OUTPUT"
}
if system_has_any_swap_configuration "$SWAP_TEST_FSTAB"; then
    fail_test "an empty swap configuration was classified as existing SWAP"
fi
SWAPON_TEST_OUTPUT='/dev/zram0\n'
system_has_any_swap_configuration "$SWAP_TEST_FSTAB" || \
    fail_test "an active non-file SWAP was not detected"
SWAPON_TEST_OUTPUT=""
printf '/swapfile none swap sw 0 0\n' > "$SWAP_TEST_FSTAB"
system_has_any_swap_configuration "$SWAP_TEST_FSTAB" || \
    fail_test "a persistent fstab SWAP was not detected"

SWAP_SYSCTL_FILE="$TEST_DIR/swap-user.conf"
printf 'vm.swappiness = 25\n' > "$SWAP_SYSCTL_FILE"
sysctl() {
    if [[ "$1" == "-n" && "$2" == "vm.swappiness" ]]; then
        printf '25\n'
        return 0
    fi
    return 1
}
remove_managed_swappiness || fail_test "unmanaged swappiness preservation failed"
grep -Fxq 'vm.swappiness = 25' "$SWAP_SYSCTL_FILE" || \
    fail_test "an unmarked user swappiness setting was modified"

PERSISTENT_CC=''
PERSISTENT_QDISC=''
get_effective_sysctl_value() {
    case "$1" in
        net.ipv4.tcp_congestion_control) printf '%s' "$PERSISTENT_CC" ;;
        net.core.default_qdisc) printf '%s' "$PERSISTENT_QDISC" ;;
    esac
}

PERSISTENT_CC=bbr
PERSISTENT_QDISC=fq
bbr_persistence_is_complete || fail_test "complete BBR persistence was rejected"
PERSISTENT_QDISC=pfifo_fast
if bbr_persistence_is_complete; then
    fail_test "incomplete BBR persistence was accepted"
fi

OS_ID=debian
for package in \
    linux-image-6.12.96+deb13-amd64 \
    linux-image-amd64 \
    linux-headers-amd64 \
    linux-base \
    linux-firmware \
    initramfs-tools \
    initramfs-tools-core \
    amd64-microcode \
    intel-microcode; do
    is_kernel_autoremove_protected_package "$package" || \
        fail_test "kernel package $package was not protected from regular cleanup"
done
if is_kernel_autoremove_protected_package libc6; then
    fail_test "a non-kernel package was protected from regular cleanup"
fi

APT_CLEANUP_PREVIEW=$'Purg ordinary-unused [1.0]\nPurg linux-image-6.12.95+deb13-amd64 [6.12.95-1]'
DPKG_CLEANUP_STATUS=$'ordinary-residual\trc\nlinux-image-6.12.94+deb13-amd64\trc'
apt-get() {
    printf '%s\n' "$APT_CLEANUP_PREVIEW"
}
dpkg-query() {
    printf '%s\n' "$DPKG_CLEANUP_STATUS"
}
collect_package_cleanup_candidates || fail_test "cleanup candidate classification failed"
array_contains_value AUTOREMOVE_PACKAGES ordinary-unused || \
    fail_test "an ordinary autoremove candidate was not retained"
array_contains_value RESIDUAL_PACKAGES ordinary-residual || \
    fail_test "an ordinary residual package was not retained"
array_contains_value AUTOREMOVE_KERNEL_PACKAGES linux-image-6.12.95+deb13-amd64 || \
    fail_test "an autoremove kernel was not separated"
array_contains_value AUTOREMOVE_KERNEL_PACKAGES linux-image-6.12.94+deb13-amd64 || \
    fail_test "a residual kernel package was not separated"
if array_contains_value RESIDUAL_PACKAGES linux-image-6.12.94+deb13-amd64; then
    fail_test "a residual kernel package entered regular cleanup"
fi

APT_PURGE_PREVIEW=$'Purg harmless-package [1.0]'
apt-get() {
    printf '%s\n' "$APT_PURGE_PREVIEW"
}
AUTOREMOVE_PACKAGES=(harmless-package)
validate_explicit_package_purge AUTOREMOVE_PACKAGES "test cleanup" || \
    fail_test "an exact package purge preview was rejected"
APT_PURGE_PREVIEW=$'Purg harmless-package [1.0]\nRemv linux-image-6.12.96+deb13-amd64 [6.12.96-1]'
if validate_explicit_package_purge AUTOREMOVE_PACKAGES "test cleanup"; then
    fail_test "a package purge preview with an unconfirmed removal was accepted"
fi
APT_PURGE_PREVIEW='Purg another-package [1.0]'
if validate_explicit_package_purge AUTOREMOVE_PACKAGES "test cleanup"; then
    fail_test "a package purge preview missing the requested package was accepted"
fi

OS_ID=debian
is_kernel_autoremove_protected_package linux-image-amd64 || \
    fail_test "the active Debian kernel meta-package was not protected from regular cleanup"
is_kernel_autoremove_protected_package linux-firmware || \
    fail_test "Debian kernel firmware was not protected from regular cleanup"

echo "Safety boundary tests passed."
