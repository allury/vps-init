#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export MOCK_IP_COUNT_FILE="$TEST_DIR/ip-count"
mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
set -euo pipefail

count=0
[[ -s "$MOCK_IP_COUNT_FILE" ]] && count=$(<"$MOCK_IP_COUNT_FILE")
count=$((count + 1))
printf '%s' "$count" > "$MOCK_IP_COUNT_FILE"

case "${MOCK_IP_MODE:-missing}" in
    delayed)
        if (( count >= 3 )); then
            echo "default via fe80::1 dev eth0 proto ra metric 100"
        fi
        ;;
    immediate)
        echo "default via 192.0.2.1 dev eth0 proto dhcp metric 100"
        ;;
    wrong)
        echo "default via fe80::2 dev eth0 proto ra metric 100"
        ;;
esac
EOF
cat > "$TEST_DIR/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_DIR/bin/ip" "$TEST_DIR/bin/sleep"
export PATH="$TEST_DIR/bin:$PATH"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

fail_test() {
    echo "DNS route wait test failed: $1" >&2
    exit 1
}

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=delayed
wait_for_default_route 6 eth0 fe80::1 5 || fail_test "delayed IPv6 route should recover"
[[ "$DNS_ROUTE_WAITED" == "2" ]] || fail_test "unexpected IPv6 recovery wait: $DNS_ROUTE_WAITED"
grep -Fq "via fe80::1 " <<< "$DNS_ROUTE_AFTER" || fail_test "recovered IPv6 gateway was not retained"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=immediate
wait_for_default_route 4 eth0 192.0.2.1 3 || fail_test "existing IPv4 route should pass immediately"
[[ "$DNS_ROUTE_WAITED" == "0" ]] || fail_test "existing IPv4 route should not wait"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=wrong
if wait_for_default_route 6 eth0 fe80::1 2; then
    fail_test "wrong gateway should fail after the wait window"
fi
[[ "$DNS_ROUTE_WAITED" == "2" ]] || fail_test "wrong gateway timeout was not honored"
grep -Fq "via fe80::2 " <<< "$DNS_ROUTE_AFTER" || fail_test "last mismatched route was not retained"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=missing
if wait_for_default_route 6 eth0 fe80::1 1; then
    fail_test "missing route should fail after the wait window"
fi
[[ "$DNS_ROUTE_WAITED" == "1" ]] || fail_test "missing route timeout was not honored"
[[ -z "$DNS_ROUTE_AFTER" ]] || fail_test "missing route should leave an empty route result"

echo "DNS route wait tests passed."
