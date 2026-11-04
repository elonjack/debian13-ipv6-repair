#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export D13_IPV6_REPAIR_LIBRARY=1
# shellcheck disable=SC1091
source "$ROOT_DIR/debian13-ipv6-repair.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3
    [[ $expected == "$actual" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_success() {
    "$@" || fail "expected success: $*"
}

assert_failure() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

assert_eq "2001:db8::1" "$(trim_ipv6_prefix '2001:db8::1/64')" "prefix trimming"
assert_success validate_expected_ipv6 "2001:db8::1"
assert_success validate_expected_ipv6 "2001:db8::1/64"
assert_failure validate_expected_ipv6 "192.0.2.1"
assert_failure validate_expected_ipv6 "2001:db8::1/129"
assert_failure validate_expected_ipv6 "not-an-ip"
assert_failure validate_expected_ipv6 "::::"
assert_success validate_interface_name "ens3"
assert_success validate_interface_name "enp0s3.100"
assert_failure validate_interface_name "bad/name"
assert_failure validate_interface_name "interface-name-is-too-long"
assert_eq "1c00:4fff:fe00:fa" "$(eui64_iid_from_mac '1e:00:4f:00:00:fa')" "EUI-64 generation"
assert_success ipv6_matches_mac_eui64 "2402:a7c0:3003:104:1c00:4fff:fe00:fa" "1e:00:4f:00:00:fa"
assert_failure ipv6_matches_mac_eui64 "2402:a7c0:3003:104:c5f0:50fc:3ccc:4c6" "1e:00:4f:00:00:fa"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
DHCPCD_CONF="$tmp_dir/dhcpcd.conf"

cat >"$DHCPCD_CONF" <<'EOF'
slaac private
interface eth0
noipv6rs
interface ens3
ipv6rs
EOF
assert_success has_effective_noipv6rs eth0
assert_failure has_effective_noipv6rs ens3

cat >"$DHCPCD_CONF" <<'EOF'
noipv6rs
interface eth0
ipv6rs
EOF
assert_success has_effective_noipv6rs ens3

cat >"$DHCPCD_CONF" <<'EOF'
interface ens3
noipv6rs
interface ens3
ipv6rs
EOF
assert_failure has_effective_noipv6rs ens3

cat >"$DHCPCD_CONF" <<'EOF'
slaac private
EOF
ensure_dhcpcd_noipv6rs ens3
assert_success has_effective_noipv6rs ens3
ensure_dhcpcd_noipv6rs ens3
assert_eq "1" "$(grep -Fc "$MANAGED_BEGIN interface=ens3" "$DHCPCD_CONF")" "managed block idempotency"

printf 'All unit tests passed.\n'
