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

    [[ "$actual" == "$expected" ]] || \
        fail_test "$label; expected [$expected], got [$actual]"
}

file_has_exact_line() {
    local file="$1"
    local expected="$2"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$expected" ]] && return 0
    done < "$file"
    return 1
}

file_key_count() {
    local file="$1"
    local expected_key="${2,,}"
    local line
    local key
    local count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        key="${line%%[[:space:]]*}"
        [[ "${key,,}" == "$expected_key" ]] && count=$((count + 1))
    done < "$file"
    printf '%s\n' "$count"
}

assert_maintenance() {
    local date_value="$1"
    local os_id="$2"
    local os_version="$3"
    local expected="$4"

    assert_equal \
        "$(VPS_INIT_TODAY="$date_value" get_os_maintenance_code "$os_id" "$os_version")" \
        "$expected" "$os_id $os_version maintenance at $date_value"
}

assert_maintenance 20260711 debian 12 standard
assert_maintenance 20260712 debian 12 lts
assert_maintenance 20280630 debian 12 lts
assert_maintenance 20280701 debian 12 eol
assert_maintenance 20280809 debian 13 standard
assert_maintenance 20280810 debian 13 lts
assert_maintenance 20300630 debian 13 lts
assert_maintenance 20300701 debian 13 eol
assert_maintenance 20250531 ubuntu 20.04 standard
assert_maintenance 20250601 ubuntu 20.04 esm
assert_maintenance 20300531 ubuntu 20.04 esm
assert_maintenance 20300601 ubuntu 20.04 legacy
assert_maintenance 20350531 ubuntu 20.04 legacy
assert_maintenance 20350601 ubuntu 20.04 eol
assert_maintenance 20320531 ubuntu 22.04 esm
assert_maintenance 20320601 ubuntu 22.04 legacy
assert_maintenance 20390531 ubuntu 24.04 legacy
assert_maintenance 20390601 ubuntu 24.04 eol
assert_maintenance invalid debian 12 unknown
assert_maintenance 20320532 ubuntu 22.04 unknown

for os_tuple in \
    'debian 12 bookworm' \
    'debian 13 trixie' \
    'ubuntu 20.04 focal' \
    'ubuntu 22.04 jammy' \
    'ubuntu 24.04 noble'; do
    read -r test_os test_version test_codename <<< "$os_tuple"
    os_codename_matches_version "$test_os" "$test_version" "$test_codename" || \
        fail_test "valid operating-system codename tuple $os_tuple was rejected"
done
for os_tuple in \
    'debian 12 trixie' \
    'debian 13 bookworm' \
    'ubuntu 20.04 jammy' \
    'ubuntu 22.04 noble' \
    'ubuntu 24.04 focal' \
    'ubuntu 24.04 unknown'; do
    read -r test_os test_version test_codename <<< "$os_tuple"
    if os_codename_matches_version "$test_os" "$test_version" "$test_codename"; then
        fail_test "mismatched operating-system codename tuple $os_tuple was accepted"
    fi
done

for os_tuple in \
    'debian 12 amd64' \
    'debian 12 mips64el' \
    'debian 13 amd64' \
    'debian 13 riscv64' \
    'ubuntu 20.04 armhf' \
    'ubuntu 22.04 s390x' \
    'ubuntu 24.04 ppc64el'; do
    read -r test_os test_version test_arch <<< "$os_tuple"
    os_arch_is_supported "$test_os" "$test_version" "$test_arch" || \
        fail_test "supported architecture tuple $os_tuple was rejected"
done
for os_tuple in \
    'debian 13 i386' \
    'debian 13 armel' \
    'ubuntu 24.04 i386' \
    'ubuntu 22.04 mipsel'; do
    read -r test_os test_version test_arch <<< "$os_tuple"
    if os_arch_is_supported "$test_os" "$test_version" "$test_arch"; then
        fail_test "unsupported architecture tuple $os_tuple was accepted"
    fi
done

fail2ban_port_list_is_safe 22 || fail_test "single Fail2ban port was rejected"
fail2ban_port_list_is_safe 22,7066 || fail_test "multiple Fail2ban ports were rejected"
for port_list in '' 0 22, 22,,7066 65536 '22;action=bad'; do
    if fail2ban_port_list_is_safe "$port_list"; then
        fail_test "unsafe Fail2ban port list [$port_list] was accepted"
    fi
done

OS_ID=ubuntu
OS_VERSION=24.04
ssh_uses_ubuntu_socket_generator || fail_test "Ubuntu 24.04 socket generator was not detected"
OS_VERSION=22.04
if ssh_uses_ubuntu_socket_generator; then
    fail_test "Ubuntu 22.04 was incorrectly classified as generator-managed"
fi
OS_ID=debian
OS_VERSION=13
if ssh_uses_ubuntu_socket_generator; then
    fail_test "Debian socket activation was incorrectly classified as Ubuntu-managed"
fi

for unit_state in \
    'enabled active' \
    'enabled-runtime inactive' \
    'disabled inactive' \
    'static active' \
    'indirect inactive' \
    'masked inactive' \
    'masked-runtime inactive'; do
    read -r test_enablement test_activity <<< "$unit_state"
    unit_transaction_state_is_supported "$test_enablement" "$test_activity" || \
        fail_test "restorable systemd state $unit_state was rejected"
done
for unit_state in \
    'linked active' \
    'linked-runtime inactive' \
    'alias active' \
    'masked active' \
    'masked-runtime active' \
    'unknown inactive'; do
    read -r test_enablement test_activity <<< "$unit_state"
    if unit_transaction_state_is_supported "$test_enablement" "$test_activity"; then
        fail_test "non-transactional systemd state $unit_state was accepted"
    fi
done

mock_list_contains() {
    local list="$1"
    local expected="$2"

    [[ " $list " == *" $expected "* ]]
}

systemctl() {
    local command_name="$1"
    local unit_name="${2:-}"

    case "$command_name" in
        cat)
            mock_list_contains "$MOCK_TIME_INSTALLED" "$unit_name"
            ;;
        show)
            unit_name="${5:-}"
            if [[ "$unit_name" == "ntp.service" && "${MOCK_TIME_ALIAS_NTP:-0}" == "1" ]]; then
                printf 'ntpsec.service\n'
            else
                printf '%s\n' "$unit_name"
            fi
            ;;
        is-active)
            if mock_list_contains "$MOCK_TIME_ACTIVE" "$unit_name"; then
                printf 'active\n'
                return 0
            fi
            printf 'inactive\n'
            return 3
            ;;
        is-enabled)
            if mock_list_contains "$MOCK_TIME_ENABLED" "$unit_name"; then
                printf 'enabled\n'
                return 0
            fi
            if mock_list_contains "$MOCK_TIME_STATIC" "$unit_name"; then
                printf 'static\n'
                return 0
            fi
            printf 'disabled\n'
            return 1
            ;;
        *) return 1 ;;
    esac
}

MOCK_TIME_INSTALLED='systemd-timesyncd.service'
MOCK_TIME_ACTIVE='systemd-timesyncd.service'
MOCK_TIME_ENABLED='systemd-timesyncd.service'
MOCK_TIME_STATIC=''
MOCK_TIME_ALIAS_NTP=0
select_time_sync_service || fail_test "the sole active time service was not selected"
assert_equal "$TIME_SYNC_SERVICE" systemd-timesyncd.service "active time service selection"
assert_equal "$TIME_SYNC_SERVICE_STATE" active "active time service state"

MOCK_TIME_INSTALLED='chrony.service systemd-timesyncd.service'
MOCK_TIME_ACTIVE=''
MOCK_TIME_ENABLED='chrony.service'
select_time_sync_service || fail_test "the sole enabled time service was not selected"
assert_equal "$TIME_SYNC_SERVICE" chrony.service "enabled time service selection"
assert_equal "$TIME_SYNC_SERVICE_STATE" enabled "enabled time service state"

MOCK_TIME_ACTIVE='systemd-timesyncd.service'
MOCK_TIME_ENABLED='chrony.service'
if select_time_sync_service; then
    fail_test "an active service plus a different enabled service was accepted"
else
    selection_status=$?
fi
assert_equal "$selection_status" 2 "active/enabled time service conflict status"

MOCK_TIME_ACTIVE=''
MOCK_TIME_ENABLED='chrony.service systemd-timesyncd.service'
if select_time_sync_service; then
    fail_test "multiple enabled time services were accepted"
else
    selection_status=$?
fi
assert_equal "$selection_status" 2 "multiple enabled time service conflict status"

MOCK_TIME_INSTALLED='ntpsec.service ntp.service'
MOCK_TIME_ENABLED='ntpsec.service'
MOCK_TIME_ALIAS_NTP=1
select_time_sync_service || fail_test "aliases for one time service were treated as a conflict"
assert_equal "$TIME_SYNC_SERVICE" ntpsec.service "time service alias canonicalization"

MOCK_TIME_INSTALLED='chrony.service'
MOCK_TIME_ACTIVE=''
MOCK_TIME_ENABLED=''
MOCK_TIME_STATIC='chrony.service'
MOCK_TIME_ALIAS_NTP=0
if select_time_sync_service; then
    fail_test "a static time service was treated as persistently enableable"
else
    selection_status=$?
fi
assert_equal "$selection_status" 2 "static time service conflict status"

unset -f systemctl

for architecture in amd64 i386 arm64 armhf ppc64el; do
    debian_lts_arch_is_supported 12 "$architecture" || \
        fail_test "Debian 12 LTS architecture $architecture was rejected"
done
if debian_lts_arch_is_supported 12 s390x; then
    fail_test "Debian 12 s390x should not be classified as LTS-covered"
fi

for version_arch in \
    '20.04 amd64' \
    '20.04 arm64' \
    '20.04 ppc64el' \
    '20.04 riscv64' \
    '20.04 s390x'; do
    read -r test_version test_arch <<< "$version_arch"
    ubuntu_extended_maintenance_arch_is_supported "$test_version" "$test_arch" || \
        fail_test "Ubuntu extended-maintenance tuple $version_arch was rejected"
done
for version_arch in '20.04 armhf' '22.04 amd64' '24.04 amd64'; do
    read -r test_version test_arch <<< "$version_arch"
    if ubuntu_extended_maintenance_arch_is_supported "$test_version" "$test_arch"; then
        fail_test "unsupported Ubuntu extended-maintenance tuple $version_arch was accepted"
    fi
done
debian_lts_arch_data_is_available 12 || \
    fail_test "Debian 12 LTS architecture data should be available"
if debian_lts_arch_data_is_available 13; then
    fail_test "future Debian 13 LTS architecture coverage should not be guessed"
fi
ubuntu_extended_maintenance_arch_data_is_available 20.04 esm || \
    fail_test "Ubuntu 20.04 ESM architecture data should be available"
if ubuntu_extended_maintenance_arch_data_is_available 22.04 esm || \
   ubuntu_extended_maintenance_arch_data_is_available 20.04 legacy; then
    fail_test "future Ubuntu extended-maintenance architecture coverage should not be guessed"
fi

VALID_PRO_ATTACHMENT_JSON='{"is_attached_and_contract_valid": true}'
VALID_PRO_SERVICES_JSON='{"enabled_services":[{"name":"esm-infra","variant_enabled":false}]}'
WRAPPED_PRO_ATTACHMENT_JSON='{"result":"success","data":{"attributes":{"is_attached_and_contract_valid":true}}}'
WRAPPED_PRO_SERVICES_JSON='{"result":"success","data":{"attributes":{"enabled_services":[{"name":"esm-infra"}]}}}'

ubuntu_pro_attachment_json_is_valid "$VALID_PRO_ATTACHMENT_JSON" || \
    fail_test "documented direct Pro attachment response was rejected"
ubuntu_pro_attachment_json_is_valid "$WRAPPED_PRO_ATTACHMENT_JSON" || \
    fail_test "wrapped Pro attachment response was rejected"
if ubuntu_pro_attachment_json_is_valid \
    '{"result":"failure","data":{"attributes":{"is_attached_and_contract_valid":true}}}'; then
    fail_test "failed Pro API wrapper was accepted"
fi
if ubuntu_pro_attachment_json_is_valid '{"is_attached_and_contract_valid":false}'; then
    fail_test "expired or unattached Pro contract was accepted"
fi
ubuntu_pro_enabled_services_json_has_esm_infra "$VALID_PRO_SERVICES_JSON" || \
    fail_test "documented enabled-services response was rejected"
ubuntu_pro_enabled_services_json_has_esm_infra "$WRAPPED_PRO_SERVICES_JSON" || \
    fail_test "wrapped enabled-services response was rejected"
ubuntu_pro_enabled_services_json_has_service \
    '{"enabled_services":[{"name":"esm-apps"}]}' esm-apps || \
    fail_test "generic Pro enabled-service parser rejected esm-apps"
if ubuntu_pro_enabled_services_json_has_service \
    '{"enabled_services":[{"name":"esm-apps"}]}' 'esm-apps.*'; then
    fail_test "unsafe Pro service name was accepted"
fi
if ubuntu_pro_enabled_services_json_has_esm_infra \
    '{"enabled_services":[{"name":"esm-apps"}]}'; then
    fail_test "Pro response without esm-infra was accepted"
fi

PRO_ATTACHMENT_JSON="$VALID_PRO_ATTACHMENT_JSON"
PRO_SERVICES_JSON="$VALID_PRO_SERVICES_JSON"
timeout() {
    shift
    "$@"
}
pro() {
    [[ "$1" == "api" ]] || return 1
    case "$2" in
        u.pro.status.is_attached.v1) printf '%s\n' "$PRO_ATTACHMENT_JSON" ;;
        u.pro.status.enabled_services.v1) printf '%s\n' "$PRO_SERVICES_JSON" ;;
        *) return 1 ;;
    esac
}
ubuntu_pro_esm_infra_is_active || \
    fail_test "valid Pro contract with esm-infra enabled was rejected"
PRO_SERVICES_JSON='{"enabled_services":[{"name":"esm-apps"}]}'
if ubuntu_pro_esm_infra_is_active; then
    fail_test "Pro contract without esm-infra was accepted"
fi
[[ "$UBUNTU_PRO_ESM_STATUS_REASON" == "esm-infra 未启用" ]] || \
    fail_test "missing esm-infra did not produce a precise reason"
PRO_SERVICES_JSON='{"enabled_services":[{"name":"esm-apps"}]}'
ubuntu_pro_esm_apps_is_active || \
    fail_test "enabled esm-apps service was rejected"

timeout() {
    shift
    "$@"
}

fail2ban-client() {
    case "$*" in
        ping) return 0 ;;
        'status sshd') return 1 ;;
        *) return 1 ;;
    esac
}

verify_fail2ban_sshd_runtime port 0 || \
    fail_test "inactive sshd jail should be allowed for a port-only sync when it was already inactive"
if verify_fail2ban_sshd_runtime port 1; then
    fail_test "required sshd jail runtime validation accepted an inactive jail"
fi

SSH_CONNECTION='192.0.2.10 42000 198.51.100.10 22'
current_ssh_session_uses_ipv4 || fail_test "IPv4 SSH session was not detected"
if current_ssh_session_uses_ipv6; then
    fail_test "IPv4 SSH session was misclassified as IPv6"
fi
SSH_CONNECTION='2001:db8::10 42000 2001:db8::20 22'
current_ssh_session_uses_ipv6 || fail_test "IPv6 SSH session was not detected"
if current_ssh_session_uses_ipv4; then
    fail_test "IPv6 SSH session was misclassified as IPv4"
fi
unset SSH_CONNECTION

for address in \
    1.1.1.1 \
    2606:4700:4700::1111 \
    ::1 \
    2001:db8:0:1:2:3:4:5 \
    ::ffff:192.0.2.1; do
    validate_dns_address "$address" || fail_test "valid DNS address $address was rejected"
done

dns_addresses_equal 2001:0DB8:0:0:0:0:0:1 2001:db8::1 || \
    fail_test "equivalent IPv6 text forms were not normalized"
dns_addresses_equal ::ffff:192.0.2.1 0:0:0:0:0:ffff:c000:0201 || \
    fail_test "IPv4-embedded IPv6 text forms were not normalized"
if dns_addresses_equal 2001:db8::1 2001:db8::2; then
    fail_test "different IPv6 addresses were treated as equal"
fi
for address in \
    256.1.1.1 \
    1.2.3 \
    2001:::1 \
    2001:db8:0:1:2:3:4:5:6 \
    ::ffff:999.0.2.1 \
    example.com; do
    if validate_dns_address "$address"; then
        fail_test "invalid DNS address $address was accepted"
    fi
done

for address in 1.1.1.1 127.0.0.1 10.0.0.53 ::1 2001:db8::53 fd00::53; do
    dns_address_is_usable_server "$address" || \
        fail_test "usable unicast DNS server $address was rejected"
done
for address in 0.0.0.0 224.0.0.1 239.255.255.250 255.255.255.255 :: ff02::1 fe80::53; do
    if dns_address_is_usable_server "$address"; then
        fail_test "non-global or scoped DNS server address $address was accepted"
    fi
done

dns_default_routes_share_interface eth0 eth0 || \
    fail_test "matching IPv4/IPv6 default interfaces were rejected"
dns_default_routes_share_interface eth0 '' || \
    fail_test "an IPv4-only default interface was rejected"
if dns_default_routes_share_interface eth0 eth1; then
    fail_test "different IPv4/IPv6 default interfaces were accepted"
fi

assert_equal \
    "$(limit_dns_server_list '1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001' 3)" \
    "1.1.1.1 1.0.0.1 2606:4700:4700::1111" \
    "static resolver nameserver limit"

RESOLV_SOURCE="$TEST_DIR/resolv.conf"
RESOLV_RENDERED="$TEST_DIR/resolv.rendered"
printf '# provider comment\nsearch example.test\noptions timeout:2\nnameserver 192.0.2.53\n' > "$RESOLV_SOURCE"
render_static_resolv_conf "$RESOLV_SOURCE" "$RESOLV_RENDERED" '1.1.1.1 1.0.0.1' || \
    fail_test "static resolv.conf rendering failed"
file_has_exact_line "$RESOLV_RENDERED" 'search example.test' || \
    fail_test "static resolv.conf search domain was not preserved"
file_has_exact_line "$RESOLV_RENDERED" 'options timeout:2' || \
    fail_test "static resolv.conf options were not preserved"
[[ "$(file_key_count "$RESOLV_RENDERED" nameserver)" == "2" ]] || \
    fail_test "static resolv.conf retained an old nameserver"

RESOLVECTL_OUTPUT=$'Global: 1.1.1.1 1.0.0.1\nLink 2 (eth0): 192.0.2.53'
assert_equal "$(extract_resolvectl_global_domains "$RESOLVECTL_OUTPUT")" \
    "1.1.1.1 1.0.0.1" "global resolvectl value extraction"
LINK_OUTPUT=$'Link 2 (eth0): 1.1.1.1\n                 1.0.0.1'
assert_equal "$(extract_resolvectl_values "$LINK_OUTPUT")" \
    "1.1.1.1 1.0.0.1" "multiline link value extraction"
assert_equal "$(resolved_domains_with_route_all 'corp.example ~internal.example bad=value')" \
    "corp.example ~internal.example ~." "resolved domain preservation"
assert_equal "$(resolved_domains_with_route_all '--help ~-unsafe.example valid.example')" \
    "valid.example ~." "resolved option-like domain rejection"
assert_equal "$(sanitize_resolved_dns_servers '1.1.1.1 1.1.1.1#53 fe80::1%eth0 invalid')" \
    "1.1.1.1 fe80::1" "resolved DNS server sanitization"
assert_equal "$(sanitize_resolved_dns_server_tokens \
    '1.1.1.1#dns.example [2001:db8::1]:853#dns.example fe80::1%eth0 1.1.1.1#--help [2001:db8::2]:70000')" \
    "1.1.1.1#dns.example [2001:db8::1]:853#dns.example fe80::1%eth0" \
    "resolved DNS rollback token preservation"

INTERFACES_FILE="$TEST_DIR/interfaces"
INTERFACES_DIR="$TEST_DIR/interfaces.d"
mkdir -p "$INTERFACES_DIR"
cat > "$INTERFACES_FILE" <<'EOF'
auto eth0
iface eth0 inet dhcp
    metric 100
source interfaces.d/*
EOF
assert_equal "$(interfaces_ipv4_method_from_file "$INTERFACES_FILE" eth0)" dhcp \
    "ifupdown IPv4 method detection"
printf 'iface eth0 inet static\n' >> "$INTERFACES_FILE"
if interfaces_ipv4_method_from_file "$INTERFACES_FILE" eth0 >/dev/null; then
    fail_test "duplicate ifupdown stanzas were treated as a unique owner"
fi

printf 'iface eth1 inet dhcp\n' > "$INTERFACES_DIR/50-cloud-init"
interfaces_file_is_loaded "$INTERFACES_DIR/50-cloud-init" "$INTERFACES_FILE" || \
    fail_test "a file matched by an ifupdown source directive was rejected"
printf 'iface eth2 inet dhcp\n' > "$INTERFACES_DIR/not-loaded.conf"
sed -i '/^source /d' "$INTERFACES_FILE"
if interfaces_file_is_loaded "$INTERFACES_DIR/not-loaded.conf" "$INTERFACES_FILE"; then
    fail_test "an ifupdown split file without a source directive was treated as loaded"
fi
printf 'source-directory interfaces.d\n' >> "$INTERFACES_FILE"
interfaces_file_is_loaded "$INTERFACES_DIR/50-cloud-init" "$INTERFACES_FILE" || \
    fail_test "a valid source-directory filename was rejected"
if interfaces_file_is_loaded "$INTERFACES_DIR/not-loaded.conf" "$INTERFACES_FILE"; then
    fail_test "source-directory accepted a filename containing a dot"
fi

netplan_interface_name_is_safe eth0 || fail_test "ordinary netplan interface was rejected"
netplan_interface_name_is_safe enp0s3-foo || fail_test "hyphenated netplan interface was rejected"
if netplan_interface_name_is_safe 'eth0.bad'; then
    fail_test "ambiguous dotted netplan path was accepted"
fi

netplan() {
    [[ "$1" == "get" && "$2" == "--help" ]] || return 1
    return "$MOCK_NETPLAN_GET_STATUS"
}
MOCK_NETPLAN_GET_STATUS=0
netplan_get_is_supported || fail_test "a working netplan get command was rejected"
MOCK_NETPLAN_GET_STATUS=2
if netplan_get_is_supported; then
    fail_test "a netplan installation without get support was accepted"
fi

EMPTY_GAI="$TEST_DIR/gai-empty.conf"
MANAGED_GAI="$TEST_DIR/gai-managed.conf"
printf '# existing comment\n' > "$EMPTY_GAI"
render_gai_preference_file "$EMPTY_GAI" "$MANAGED_GAI" ipv4 0 || \
    fail_test "managed gai.conf could not be rendered"
assert_equal "$(get_gai_preference_mode "$MANAGED_GAI")" ipv4 \
    "complete managed gai.conf detection"
sed -i 's/precedence ::\/96         20/precedence ::\/96         19/' "$MANAGED_GAI"
assert_equal "$(get_gai_preference_mode "$MANAGED_GAI")" malformed \
    "modified managed gai.conf detection"
printf 'precedence ::ffff:0:0/96 100\n' > "$MANAGED_GAI"
assert_equal "$(get_gai_preference_mode "$MANAGED_GAI")" legacy-ipv4 \
    "legacy IPv4 preference detection"
printf 'precedence 2001:db8::/32 60\n' > "$MANAGED_GAI"
assert_equal "$(get_gai_preference_mode "$MANAGED_GAI")" custom \
    "custom preference detection"

SSH_MANAGED_FILE="$TEST_DIR/sshd-managed.conf"
printf 'X11Forwarding no\nPasswordAuthentication yes' > "$SSH_MANAGED_FILE"
write_sshd_keys_atomic \
    PubkeyAuthentication yes \
    PasswordAuthentication no \
    KbdInteractiveAuthentication no \
    ChallengeResponseAuthentication no || \
    fail_test "atomic SSH managed-file update failed"
file_has_exact_line "$SSH_MANAGED_FILE" 'X11Forwarding no' || \
    fail_test "unmanaged SSH setting was not preserved"
[[ "$(file_key_count "$SSH_MANAGED_FILE" PasswordAuthentication)" == "1" ]] || \
    fail_test "SSH key replacement left duplicate settings"
file_has_exact_line "$SSH_MANAGED_FILE" 'PasswordAuthentication no' || \
    fail_test "SSH password setting was not updated"

SYSCTL_ATOMIC_TEST="$TEST_DIR/sysctl-atomic.conf"
printf 'vm.swappiness = 25' > "$SYSCTL_ATOMIC_TEST"
write_sysctl_keys_atomic "$SYSCTL_ATOMIC_TEST" \
    net.core.default_qdisc fq \
    net.ipv4.tcp_congestion_control bbr || \
    fail_test "atomic sysctl update failed for an unterminated source file"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'vm.swappiness = 25' || \
    fail_test "atomic sysctl update joined a managed key to existing content"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'net.core.default_qdisc = fq' || \
    fail_test "atomic sysctl update did not add FQ"
file_has_exact_line "$SYSCTL_ATOMIC_TEST" 'net.ipv4.tcp_congestion_control = bbr' || \
    fail_test "atomic sysctl update did not add BBR"

FAIL2BAN_SOURCE="$TEST_DIR/jail.local"
FAIL2BAN_OUTPUT="$TEST_DIR/jail.rendered"
cat > "$FAIL2BAN_SOURCE" <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8

[sshd]
port = 22
enabled = false
filter = sshd-aggressive
backend = systemd
logpath = /var/log/custom-auth.log
ignorecommand = /usr/local/bin/check-ip
EOF
render_fail2ban_sshd_section "$FAIL2BAN_SOURCE" "$FAIL2BAN_OUTPUT" 7066 full || \
    fail_test "Fail2ban section rendering failed"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'ignoreip = 127.0.0.1/8' || \
    fail_test "Fail2ban DEFAULT settings were not preserved"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'ignorecommand = /usr/local/bin/check-ip' || \
    fail_test "unmanaged Fail2ban sshd setting was not preserved"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'filter = sshd-aggressive' || \
    fail_test "Fail2ban filter override was not preserved"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'backend = systemd' || \
    fail_test "Fail2ban backend override was not preserved"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'logpath = /var/log/custom-auth.log' || \
    fail_test "Fail2ban logpath override was not preserved"
file_has_exact_line "$FAIL2BAN_OUTPUT" 'port = 7066' || fail_test "Fail2ban port was not updated"
[[ "$(file_key_count "$FAIL2BAN_OUTPUT" '[sshd]')" == "1" ]] || \
    fail_test "Fail2ban rendering changed the sshd section count"

printf '[sshd]\nenabled = false\n' > "$FAIL2BAN_SOURCE"
render_fail2ban_sshd_section "$FAIL2BAN_SOURCE" "$FAIL2BAN_OUTPUT" 7066 full || \
    fail_test "minimal Fail2ban section rendering failed"
if grep -Eq '^[[:space:]]*(filter|backend|logpath)[[:space:]]*=' "$FAIL2BAN_OUTPUT"; then
    fail_test "Fail2ban renderer invented distribution-owned filter, backend, or logpath settings"
fi

cat > "$FAIL2BAN_SOURCE" <<'EOF'
[INCLUDES]
before = paths-debian.conf

[sshd]
enabled = true
EOF
if fail2ban_file_has_after_include "$FAIL2BAN_SOURCE"; then
    fail_test "a Fail2ban before include was classified as a late override"
fi
cat > "$FAIL2BAN_SOURCE" <<'EOF'
[INCLUDES]
after = provider.local
EOF
fail2ban_file_has_after_include "$FAIL2BAN_SOURCE" || \
    fail_test "a Fail2ban after include was not detected"

printf '[Resolve]\nDNS=1.1.1.1\n' > "$TEST_DIR/resolved.conf"
resolved_dropin_has_dns_setting "$TEST_DIR/resolved.conf" || \
    fail_test "resolved DNS setting was not detected"
printf '[Resolve]\nDNSSEC=yes\n' > "$TEST_DIR/resolved.conf"
if resolved_dropin_has_dns_setting "$TEST_DIR/resolved.conf"; then
    fail_test "unrelated resolved setting was classified as a DNS override"
fi

RESOLVED_RENDERED="$TEST_DIR/resolved.rendered"
cat > "$TEST_DIR/resolved.conf" <<'EOF'
[Resolve]
DNSSEC=yes
DNS=192.0.2.53
Domains=example.test
DNSOverTLS=opportunistic

[Unrelated]
Value=keep-me
EOF
render_resolved_dns_file "$TEST_DIR/resolved.conf" "$RESOLVED_RENDERED" \
    '1.1.1.1 1.0.0.1' '~.' || fail_test "resolved DNS rendering failed"
file_has_exact_line "$RESOLVED_RENDERED" 'DNSSEC=yes' || \
    fail_test "resolved DNS rendering removed DNSSEC"
file_has_exact_line "$RESOLVED_RENDERED" 'DNSOverTLS=opportunistic' || \
    fail_test "resolved DNS rendering removed DNSOverTLS"
file_has_exact_line "$RESOLVED_RENDERED" 'Value=keep-me' || \
    fail_test "resolved DNS rendering removed an unrelated section"
file_has_exact_line "$RESOLVED_RENDERED" 'DNS=1.1.1.1 1.0.0.1' || \
    fail_test "resolved DNS rendering did not write the requested servers"
if grep -Fxq 'DNS=192.0.2.53' "$RESOLVED_RENDERED"; then
    fail_test "resolved DNS rendering retained an old DNS server"
fi
[[ "$(grep -c '^DNS=' "$RESOLVED_RENDERED")" == "2" ]] || \
    fail_test "resolved DNS rendering did not produce one reset and one assignment"

NETPLAN_MANAGED="$TEST_DIR/netplan-managed.yaml"
printf '%s\nnetwork:\n  version: 2\n' "$NETPLAN_DNS_MANAGED_MARKER" > "$NETPLAN_MANAGED"
netplan_dns_override_is_managed "$NETPLAN_MANAGED" || \
    fail_test "marked netplan DNS override was not recognized"
NETPLAN_LEGACY="$TEST_DIR/netplan-legacy.yaml"
cat > "$NETPLAN_LEGACY" <<'EOF'
network:
  version: 2
  ethernets:
    "eth0":
      nameservers:
        addresses: [1.1.1.1, 1.0.0.1]
      dhcp4-overrides:
        use-dns: false
EOF
netplan_dns_override_is_managed "$NETPLAN_LEGACY" || \
    fail_test "legacy vps-init netplan DNS override was not recognized"
printf '      routes: []\n' >> "$NETPLAN_LEGACY"
if netplan_dns_override_is_managed "$NETPLAN_LEGACY"; then
    fail_test "an unmarked netplan file with unrelated settings was treated as managed"
fi

printf 'net.ipv6.conf.eth0.disable_ipv6 = 1\n' > "$TEST_DIR/sysctl.conf"
sysctl_file_has_ipv6_disable_setting "$TEST_DIR/sysctl.conf" || \
    fail_test "interface-specific IPv6 setting was not detected"
sysctl_file_ipv6_disable_values_match "$TEST_DIR/sysctl.conf" 1 || \
    fail_test "matching standalone IPv6 value was rejected"
if sysctl_file_ipv6_disable_values_match "$TEST_DIR/sysctl.conf" 0; then
    fail_test "conflicting standalone IPv6 value was accepted"
fi
sysctl_file_ipv6_interface_values_match "$TEST_DIR/sysctl.conf" 1 || \
    fail_test "matching interface-specific IPv6 value was rejected"
if sysctl_file_ipv6_interface_values_match "$TEST_DIR/sysctl.conf" 0; then
    fail_test "conflicting interface-specific IPv6 value was accepted"
fi
printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$TEST_DIR/sysctl.conf"
sysctl_file_ipv6_interface_values_match "$TEST_DIR/sysctl.conf" 0 || \
    fail_test "global IPv6 value was misclassified as an interface-specific conflict"
ipv6_persistent_value_matches '' 0 || \
    fail_test "the kernel's default enabled IPv6 state was not treated as persistent"
ipv6_persistent_value_matches 0 0 || \
    fail_test "an explicit persistent IPv6 enabled value was rejected"
if ipv6_persistent_value_matches '' 1; then
    fail_test "an absent IPv6 disable value was treated as persistently disabled"
fi

cat > "$TEST_DIR/sysctl-bbr.conf" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
sysctl_file_keys_match_values "$TEST_DIR/sysctl-bbr.conf" \
    net.ipv4.tcp_congestion_control bbr \
    net.core.default_qdisc fq || \
    fail_test "matching standalone BBR values were rejected"
sed -i 's/default_qdisc = fq/default_qdisc = cake/' "$TEST_DIR/sysctl-bbr.conf"
if sysctl_file_keys_match_values "$TEST_DIR/sysctl-bbr.conf" \
    net.ipv4.tcp_congestion_control bbr \
    net.core.default_qdisc fq; then
    fail_test "conflicting standalone BBR value was accepted"
fi

SYSCTL_FINAL="$TEST_DIR/sysctl-final.conf"
SYSCTL_TARGET_TEST="$TEST_DIR/sysctl-target.conf"
printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FINAL"
printf '# managed target\n' > "$SYSCTL_TARGET_TEST"
if sysctl_final_pass_bbr_is_compatible "$SYSCTL_FINAL" "$SYSCTL_TARGET_TEST"; then
    fail_test "a conflicting final sysctl.conf pass was accepted"
fi
sysctl_final_pass_bbr_is_compatible "$SYSCTL_FINAL" "$SYSCTL_FINAL" || \
    fail_test "a final sysctl.conf path identical to the update target was rejected"
printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$SYSCTL_FINAL"
if sysctl_final_pass_ipv6_is_compatible "$SYSCTL_FINAL" "$SYSCTL_TARGET_TEST" 0; then
    fail_test "a conflicting final IPv6 sysctl.conf pass was accepted"
fi
sysctl_final_pass_ipv6_is_compatible "$SYSCTL_FINAL" "$SYSCTL_FINAL" 0 || \
    fail_test "an IPv6 sysctl.conf path identical to the update target was rejected"
SYSCTL_LINK="$TEST_DIR/sysctl-link.conf"
if ln -s "$SYSCTL_FINAL" "$SYSCTL_LINK" 2>/dev/null; then
    paths_resolve_to_same_file "$SYSCTL_LINK" "$SYSCTL_FINAL" || \
        fail_test "a sysctl.conf symlink to the update target was not recognized"
fi

DNS_PERSIST_CALLS=""
MOCK_NETPLAN_CONFIGURED=1
MOCK_NETPLAN_RESULT=0
MOCK_INTERFACES_RESULT=0
sync_netplan_dns() {
    DNS_PERSIST_CALLS+="netplan "
    DNS_NETPLAN_CONFIGURED="$MOCK_NETPLAN_CONFIGURED"
    return "$MOCK_NETPLAN_RESULT"
}
sync_interfaces_dns() {
    DNS_PERSIST_CALLS+="interfaces "
    MOCK_INTERFACES_RESOLVER_MODE="${2:-}"
    return "$MOCK_INTERFACES_RESULT"
}

DNS_NETPLAN_CONFIGURED=0
persist_dns_network_layer '1.1.1.1 1.0.0.1' || \
    fail_test "netplan DNS persistence path failed"
assert_equal "$DNS_PERSIST_CALLS" "netplan " \
    "interfaces persistence should not run after a netplan configuration was written"

DNS_PERSIST_CALLS=""
MOCK_NETPLAN_CONFIGURED=0
persist_dns_network_layer '1.1.1.1 1.0.0.1' static || \
    fail_test "interfaces DNS persistence fallback failed"
assert_equal "$DNS_PERSIST_CALLS" "netplan interfaces " \
    "interfaces persistence fallback sequence"
assert_equal "$MOCK_INTERFACES_RESOLVER_MODE" static \
    "resolver ownership mode forwarding"

DNS_PERSIST_CALLS=""
MOCK_NETPLAN_RESULT=1
if persist_dns_network_layer '1.1.1.1'; then
    fail_test "DNS persistence accepted a failed netplan validation"
fi
assert_equal "$DNS_PERSIST_CALLS" "netplan " \
    "interfaces persistence ran after a failed netplan validation"

netplan_configuration_is_present() {
    return 0
}
netplan_get_is_supported() {
    return 1
}
systemctl() {
    return 1
}
if apply_dns_servers '1.1.1.1'; then
    fail_test "DNS automation accepted Netplan without merged-config inspection support"
fi

netplan_configuration_is_present() {
    return 1
}
systemctl() {
    [[ "$1" == "is-active" && "$2" == "NetworkManager" ]]
}
if apply_dns_servers '1.1.1.1'; then
    fail_test "DNS automation accepted an active NetworkManager owner"
fi

echo "Configuration policy tests passed."
