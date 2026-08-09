#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export NO_COLOR=1
export VPS_INIT_LOG_FILE="$TEST_DIR/vps_init.log"
export MOCK_IP_COUNT_FILE="$TEST_DIR/ip-count"

# shellcheck source=../vps.sh
source "$SCRIPT_DIR/../vps.sh"

ip() {
    local count=0

    [[ -s "$MOCK_IP_COUNT_FILE" ]] && count=$(<"$MOCK_IP_COUNT_FILE")
    count=$((count + 1))
    printf '%s' "$count" > "$MOCK_IP_COUNT_FILE"

    if [[ "${2:-}" == "route" && "${3:-}" == "get" ]]; then
        case "${MOCK_IP_MODE:-target-error}" in
            target-ok)
                if [[ "${1:-}" == "-6" ]]; then
                    echo "${4:-::1} via fe80::1 dev eth0 src 2001:db8::2 metric 100"
                else
                    echo "${4:-127.0.0.1} via 192.0.2.1 dev eth0 src 192.0.2.2"
                fi
                ;;
            target-unreachable)
                echo "unreachable ${4:-unknown} dev lo metric 4294967295 error -101"
                ;;
            target-prohibit)
                echo "prohibit ${4:-unknown} dev lo metric 4294967295 error -13"
                ;;
            target-empty)
                ;;
            *)
                echo "RTNETLINK answers: Network is unreachable" >&2
                return 2
                ;;
        esac
        return 0
    fi

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
        direct)
            echo "default dev ppp0 scope link"
            ;;
    esac
}

sleep() {
    return 0
}

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
wait_for_default_route 6 eth0 fe80::1 2 || \
    fail_test "a renewed IPv6 gateway on the same interface should be accepted"
[[ "$DNS_ROUTE_WAITED" == "0" ]] || fail_test "a renewed gateway should pass immediately"
grep -Fq "via fe80::2 " <<< "$DNS_ROUTE_AFTER" || fail_test "renewed route was not retained"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=direct
[[ "$(get_default_route_interface 4)" == "ppp0" ]] || \
    fail_test "a direct default route interface was not parsed"
[[ -z "$(get_default_route_gateway 4)" ]] || \
    fail_test "a direct default route should not invent a gateway"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=missing
if wait_for_default_route 6 eth0 fe80::1 1; then
    fail_test "missing route should fail after the wait window"
fi
[[ "$DNS_ROUTE_WAITED" == "1" ]] || fail_test "missing route timeout was not honored"
[[ -z "$DNS_ROUTE_AFTER" ]] || fail_test "missing route should leave an empty route result"

printf '0' > "$MOCK_IP_COUNT_FILE"
export MOCK_IP_MODE=target-ok
dns_server_route_is_available 1.1.1.1 || fail_test "a routed IPv4 DNS target should pass"
grep -Fq "1.1.1.1 via 192.0.2.1" <<< "$DNS_TARGET_ROUTE_AFTER" || \
    fail_test "the IPv4 target route was not retained"
dns_server_route_is_available 2606:4700:4700::1111 || \
    fail_test "a routed IPv6 DNS target should pass"
grep -Fq "2606:4700:4700::1111 via fe80::1" <<< "$DNS_TARGET_ROUTE_AFTER" || \
    fail_test "the IPv6 target route was not retained"

export MOCK_IP_MODE=target-unreachable
if dns_server_route_is_available 2606:4700:4700::1111; then
    fail_test "an explicit unreachable IPv6 route should fail"
fi
grep -Fq "unreachable 2606:4700:4700::1111" <<< "$DNS_TARGET_ROUTE_AFTER" || \
    fail_test "the unreachable route diagnostic was not retained"

export MOCK_IP_MODE=target-prohibit
if dns_server_route_is_available 1.1.1.1; then
    fail_test "an explicit prohibit route should fail"
fi

export MOCK_IP_MODE=target-empty
if dns_server_route_is_available 1.1.1.1; then
    fail_test "an empty route lookup should fail"
fi

export MOCK_IP_MODE=target-error
if dns_server_route_is_available 1.1.1.1; then
    fail_test "a failed route lookup should fail"
fi
grep -Fq "Network is unreachable" <<< "$DNS_TARGET_ROUTE_AFTER" || \
    fail_test "the route command error was not retained"

declare -f apply_dns_servers | grep -Fq 'PREFLIGHT_TARGET_ROUTE' || \
    fail_test "DNS application does not preflight target routes"
declare -f verify_dns_change | grep -Fq 'VERIFY_TARGET_ROUTE' || \
    fail_test "DNS verification does not recheck target routes"

echo "DNS route wait tests passed."
