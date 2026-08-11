#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export VPS_INIT_SYSCTL_SCAN_ROOT="$TEST_DIR/root"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

fail_test() {
    echo "BBR sysctl order test failed: $1" >&2
    exit 1
}

reset_tree() {
    rm -rf -- "$SYSCTL_SCAN_ROOT"
    mkdir -p \
        "$SYSCTL_SCAN_ROOT/etc/sysctl.d" \
        "$SYSCTL_SCAN_ROOT/run/sysctl.d" \
        "$SYSCTL_SCAN_ROOT/usr/local/lib/sysctl.d" \
        "$SYSCTL_SCAN_ROOT/usr/lib/sysctl.d" \
        "$SYSCTL_SCAN_ROOT/lib/sysctl.d"
}

reset_tree
cat > "$SYSCTL_SCAN_ROOT/usr/lib/sysctl.d/50-vendor.conf" <<'EOF'
net.core.default_qdisc = pfifo_fast
net.ipv4.tcp_congestion_control = cubic
EOF
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/50-vendor.conf" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
scan_sysctl_configs
[[ "${#EFFECTIVE_SYSCTL_FILES[@]}" == "1" ]] || \
    fail_test "same-name override did not suppress the vendor file"
[[ "${EFFECTIVE_SYSCTL_FILES[0]}" == "$SYSCTL_SCAN_ROOT/etc/sysctl.d/50-vendor.conf" ]] || \
    fail_test "/etc same-name override did not win"
[[ "$(get_effective_sysctl_value net.core.default_qdisc)" == "fq" ]] || \
    fail_test "effective fq value was not read from the override"
[[ "$(get_effective_sysctl_value net.ipv4.tcp_congestion_control)" == "bbr" ]] || \
    fail_test "effective bbr value was not read from the override"
bbr_persistence_is_complete || fail_test "complete BBR + fq persistence was rejected"

reset_tree
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/80-bbr.conf" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/99-late.conf" <<'EOF'
net.core.default_qdisc = cake
EOF
[[ "$(get_effective_sysctl_value net.core.default_qdisc)" == "cake" ]] || \
    fail_test "later filename did not override an earlier qdisc"
if bbr_persistence_is_complete; then
    fail_test "conflicting late qdisc was accepted as complete persistence"
fi

reset_tree
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/80-bbr.conf" <<'EOF'
net.ipv4.tcp_congestion_control = bbr
EOF
if bbr_persistence_is_complete; then
    fail_test "configuration missing fq was accepted"
fi

reset_tree
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/80-fq.conf" <<'EOF'
net.core.default_qdisc = fq
EOF
if bbr_persistence_is_complete; then
    fail_test "configuration missing bbr was accepted"
fi

reset_tree
if bbr_persistence_is_complete; then
    fail_test "an entirely unconfigured system was accepted"
fi

reset_tree
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/70-network.conf" <<'EOF'
net.ipv4.tcp_mtu_probing = 1
EOF
cat > "$SYSCTL_SCAN_ROOT/etc/sysctl.d/80-transport.conf" <<'EOF'
net.ipv4.tcp_slow_start_after_idle = 0
EOF
scan_sysctl_configs
[[ "${#ETC_TCP_FILES[@]}" == "2" ]] || \
    fail_test "multiple local TCP configuration files were not detected"

printf 'BBR sysctl loading-order tests passed.\n'
