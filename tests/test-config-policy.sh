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
    echo "Configuration policy test failed: $1" >&2
    exit 1
}

assert_equal() {
    local actual="$1"
    local expected="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        fail_test "$label; expected [$expected], got [$actual]"
    fi
}

assert_maintenance() {
    local date_value="$1"
    local os_version="$2"
    local expected="$3"

    assert_equal \
        "$(VPS_INIT_TODAY="$date_value" get_os_maintenance_code debian "$os_version")" \
        "$expected" "Debian $os_version maintenance at $date_value"
}

file_has_exact_line() {
    local file="$1"
    local expected="$2"
    local line=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$expected" ]]; then
            return 0
        fi
    done < "$file"
    return 1
}

os_version_is_supported debian 12 || fail_test "Debian 12 was rejected"
os_version_is_supported debian 13 || fail_test "Debian 13 was rejected"
if os_version_is_supported debian 11; then
    fail_test "Debian 11 was accepted"
fi
if os_version_is_supported alpine 3.20; then
    fail_test "an unrelated distribution was accepted"
fi

os_codename_matches_version debian 12 bookworm || fail_test "Bookworm mapping was rejected"
os_codename_matches_version debian 13 trixie || fail_test "Trixie mapping was rejected"
if os_codename_matches_version debian 12 trixie; then
    fail_test "cross-release codename mapping was accepted"
fi

for version_arch in '12 amd64' '12 arm64' '13 amd64' '13 arm64'; do
    read -r version architecture <<< "$version_arch"
    os_arch_is_supported debian "$version" "$architecture" || \
        fail_test "supported tuple Debian $version/$architecture was rejected"
done
for version_arch in '12 i386' '12 armhf' '13 riscv64' '13 s390x'; do
    read -r version architecture <<< "$version_arch"
    if os_arch_is_supported debian "$version" "$architecture"; then
        fail_test "out-of-scope tuple Debian $version/$architecture was accepted"
    fi
done

assert_maintenance 20260711 12 standard
assert_maintenance 20260712 12 lts
assert_maintenance 20280630 12 lts
assert_maintenance 20280701 12 eol
assert_maintenance 20280809 13 standard
assert_maintenance 20280810 13 lts
assert_maintenance 20300630 13 lts
assert_maintenance 20300701 13 eol
assert_maintenance 20261340 13 unknown

OS_ID=debian
OS_CODENAME=bookworm
kernel_source_record_allowed \
    $'https://mirror.example/debian bookworm/main amd64 Packages\trelease v=12.0,o=Debian,a=oldstable,n=bookworm,l=Debian,c=main,b=amd64\torigin mirror.example' || \
    fail_test "official Bookworm base metadata was rejected"
kernel_source_record_allowed \
    $'https://mirror.example/debian bookworm-updates/main amd64 Packages\trelease v=12-updates,o=Debian,a=oldstable-updates,n=bookworm-updates,l=Debian,c=main,b=amd64\torigin mirror.example' || \
    fail_test "official Bookworm updates metadata was rejected"
kernel_source_record_allowed \
    $'https://security.example/debian-security bookworm-security/main amd64 Packages\trelease v=12,o=Debian,a=oldstable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64\torigin security.example' || \
    fail_test "official Bookworm security metadata was rejected"
if kernel_source_record_allowed \
    $'https://mirror.example/debian testing/main amd64 Packages\trelease o=Debian,a=testing,n=trixie,l=Debian,c=main,b=amd64\torigin mirror.example'; then
    fail_test "cross-release testing metadata was accepted"
fi
if kernel_source_record_allowed \
    $'https://mirror.example/debian sid/main amd64 Packages\trelease o=Debian,a=unstable,n=sid,l=Debian,c=main,b=amd64\torigin mirror.example'; then
    fail_test "sid metadata was accepted"
fi
if kernel_source_record_allowed \
    $'https://mirror.example/debian bookworm/main amd64 Packages\trelease o=Vendor,a=oldstable,n=bookworm,l=Vendor,c=main,b=amd64\torigin mirror.example'; then
    fail_test "non-Debian Origin was accepted"
fi

for package in linux-image-amd64 linux-image-cloud-amd64 linux-image-arm64 linux-image-cloud-arm64; do
    is_kernel_meta_package_name "$package" || fail_test "$package was rejected as a Debian kernel meta-package"
done
for package in linux-image-6.1.0-31-amd64 linux-headers-6.1.0-31-amd64; do
    if is_kernel_meta_package_name "$package"; then
        fail_test "$package was incorrectly classified as a meta-package"
    fi
done

assert_equal "$(kernel_flavor_from_release 6.1.0-31-amd64)" amd64 \
    "standard Debian kernel flavor"
assert_equal "$(kernel_flavor_from_release 6.1.0-31-cloud-amd64)" cloud-amd64 \
    "cloud Debian kernel flavor"

SYSCTL_ATOMIC_TEST="$TEST_DIR/sysctl-atomic.conf"
printf 'vm.swappiness = 25' > "$SYSCTL_ATOMIC_TEST"
write_sysctl_keys_atomic "$SYSCTL_ATOMIC_TEST" \
    net.core.default_qdisc fq \
    net.ipv4.tcp_congestion_control bbr || \
    fail_test "atomic sysctl update failed"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'vm.swappiness = 25' || \
    fail_test "atomic sysctl update removed an unrelated key"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'net.core.default_qdisc = fq' || \
    fail_test "atomic sysctl update did not add fq"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'net.ipv4.tcp_congestion_control = bbr' || \
    fail_test "atomic sysctl update did not add bbr"

SYSCTL_FINAL="$TEST_DIR/sysctl-final.conf"
SYSCTL_TARGET_TEST="$TEST_DIR/sysctl-target.conf"
printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FINAL"
printf '# managed target\n' > "$SYSCTL_TARGET_TEST"
if sysctl_final_pass_bbr_is_compatible "$SYSCTL_FINAL" "$SYSCTL_TARGET_TEST"; then
    fail_test "a conflicting final sysctl pass was accepted"
fi
sysctl_final_pass_bbr_is_compatible "$SYSCTL_FINAL" "$SYSCTL_FINAL" || \
    fail_test "an identical final sysctl target was rejected"

FAIL2BAN_SOURCE="$TEST_DIR/jail.local"
FAIL2BAN_OUTPUT="$TEST_DIR/jail.rendered"
cat > "$FAIL2BAN_SOURCE" <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8

[sshd]
enabled = false
port = 22
filter = sshd-aggressive
backend = systemd
ignorecommand = /usr/local/bin/check-ip
EOF
render_fail2ban_sshd_section "$FAIL2BAN_SOURCE" "$FAIL2BAN_OUTPUT" 7066 full || \
    fail_test "Fail2ban section rendering failed"
for expected in \
    'ignoreip = 127.0.0.1/8' \
    'enabled = true' \
    'port = 7066' \
    'maxretry = 5' \
    'findtime = 3600' \
    'bantime = 86400' \
    'filter = sshd-aggressive' \
    'backend = systemd' \
    'ignorecommand = /usr/local/bin/check-ip'; do
    file_has_exact_line "$FAIL2BAN_OUTPUT" "$expected" || \
        fail_test "Fail2ban output is missing [$expected]"
done

validate_dns_address 1.1.1.1 || fail_test "valid IPv4 DNS was rejected"
validate_dns_address 2606:4700:4700::1111 || fail_test "valid IPv6 DNS was rejected"
if dns_address_is_usable_server 0.0.0.0; then
    fail_test "unspecified IPv4 address was accepted as DNS"
fi
if dns_address_is_usable_server fe80::1; then
    fail_test "unscoped link-local IPv6 address was accepted as DNS"
fi

printf 'Debian-only configuration policy tests passed.\n'
