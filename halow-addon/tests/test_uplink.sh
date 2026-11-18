#!/usr/bin/env bash
# Tests uplink.sh against a fake `ip`: default-route uplink detection (none, one, several,
# multipath), uplink change, subnet collisions with addresses, routes and the reserved
# Supervisor network, and DHCP pool / station bound arithmetic.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./fakes/fw_helpers.sh
fw_ip_fake_setup

echo "== test_uplink =="
D="$HALOW_FAKE_IP_DIR"

echo "-- uplink detection --"
printf 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.10 metric 100\n' > "$D/route_default"
assert_eq "eth0" "$(halow_uplink_detect)" "the default-route interface is detected"
printf 'default via 192.168.1.1 dev eth0 proto dhcp metric 100\ndefault via 192.168.1.1 dev eth0 proto static metric 200\n' > "$D/route_default"
assert_eq "eth0" "$(halow_uplink_detect)" "two default routes through the same interface are not ambiguous"
printf 'default via 192.168.1.1 dev eth0 metric 100\ndefault via 10.0.0.1 dev wlan0 metric 600\n' > "$D/route_default"
assert_failure "default routes through two interfaces are ambiguous" halow_uplink_detect
printf 'default proto static metric 100\n\tnexthop via 192.168.1.1 dev eth0 weight 1\n\tnexthop via 10.0.0.1 dev eth1 weight 1\n' > "$D/route_default"
assert_failure "a multipath default route through two interfaces is ambiguous" halow_uplink_detect
: > "$D/route_default"
assert_failure "no default route fails" halow_uplink_detect
assert_eq "" "$(halow_uplink_detect 2>/dev/null)" "nothing printed when there is no uplink"
printf 'default dev wg0 scope link\n' > "$D/route_default"
assert_eq "wg0" "$(halow_uplink_detect)" "a device-only default route is detected"
printf 'default via 1.2.3.4 dev bad;name\n' > "$D/route_default"
assert_failure "an unacceptable interface name is refused" halow_uplink_detect
touch "$D/fail_route_default"
assert_failure "an unreadable route table fails" halow_uplink_detect
rm -f "$D/fail_route_default"

echo "-- uplink change --"
printf 'default via 192.168.1.1 dev eth0\n' > "$D/route_default"
assert_failure "unchanged uplink is not a change" halow_uplink_changed eth0
assert_success "a different uplink is a change" halow_uplink_changed wlan0
: > "$D/route_default"
assert_success "a lost uplink is a change" halow_uplink_changed eth0
printf 'default via 192.168.1.1 dev eth0\ndefault via 10.0.0.1 dev eth1\n' > "$D/route_default"
assert_success "an uplink that became ambiguous is a change" halow_uplink_changed eth0

echo "-- subnet collisions --"
cat > "$D/addr" <<'EOF'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global dynamic eth0\       valid_lft 86000sec preferred_lft 86000sec
4: hassio    inet 172.30.32.1/23 brd 172.30.33.255 scope global hassio\       valid_lft forever preferred_lft forever
5: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever
9: halow-br0    inet 192.168.90.1/24 brd 192.168.90.255 scope global halow-br0\       valid_lft forever preferred_lft forever
EOF
cat > "$D/route" <<'EOF'
default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.10 metric 100
10.20.0.0/16 via 192.168.1.254 dev eth0 proto static
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
172.30.32.0/23 dev hassio proto kernel scope link src 172.30.32.1
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10 metric 100
192.168.90.0/24 dev halow-br0 proto kernel scope link src 192.168.90.1
unreachable 10.99.0.0/16
203.0.113.7 via 192.168.1.1 dev eth0
EOF
assert_success "a free subnet does not collide" halow_subnet_collision 192.168.90.1/24
assert_success "the add-on's own bridge address is not a collision with itself" halow_subnet_collision 192.168.90.1/24
out="$(halow_subnet_collision 192.168.1.1/24)"; rc=$?
assert_eq "1" "$rc" "the LAN subnet collides"
assert_success "the conflicting prefix is printed" grep -q "192.168.1.0/24" <<< "$out"
out="$(halow_subnet_collision 192.168.1.128/25)"; rc=$?
assert_eq "1" "$rc" "a subnet inside the LAN collides (narrower than an existing prefix)"
out="$(halow_subnet_collision 192.168.0.1/16)"; rc=$?
assert_eq "1" "$rc" "a subnet containing the LAN collides (wider than an existing prefix)"
out="$(halow_subnet_collision 172.30.33.1/24)"; rc=$?
assert_eq "1" "$rc" "the Supervisor network collides"
assert_success "the Supervisor network is named" grep -q "172.30.32.0/23" <<< "$out"
assert_failure "docker0's network collides" halow_subnet_collision 172.17.5.1/24
assert_failure "a statically routed network collides" halow_subnet_collision 10.20.30.1/24
assert_failure "an unreachable route collides" halow_subnet_collision 10.99.1.1/24
out="$(halow_subnet_collision 203.0.113.1/24)"; rc=$?
assert_eq "1" "$rc" "a host route inside the subnet collides"
assert_success "the host route is named as a /32" grep -q "203.0.113.7/32" <<< "$out"
assert_failure "loopback collides" halow_subnet_collision 127.1.0.1/16
assert_success "a neighbouring /24 does not collide" halow_subnet_collision 192.168.2.1/24
assert_success "10.21.0.1/24 does not collide with 10.20.0.0/16" halow_subnet_collision 10.21.0.1/24
: > "$D/addr"; : > "$D/route"
out="$(halow_subnet_collision 172.30.32.5/28)"; rc=$?
assert_eq "1" "$rc" "the reserved Supervisor range collides even without a route for it"
HALOW_RESERVED_CIDRS="" assert_success "the reserved list is overridable" halow_subnet_collision 172.30.32.5/28
assert_failure "an invalid subnet is reported" halow_subnet_collision 192.168.300.1/24
assert_failure "a subnet without a prefix is reported" halow_subnet_collision 192.168.90.1
touch "$D/fail_addr"
out="$(halow_subnet_collision 192.168.90.1/24)"; rc=$?
assert_eq "1" "$rc" "an unreadable address list fails closed"
rm -f "$D/fail_addr"
touch "$D/fail_route"
assert_failure "an unreadable route list fails closed" halow_subnet_collision 192.168.90.1/24
rm -f "$D/fail_route"

echo "-- network form --"
assert_eq "192.168.90.0/24" "$(halow_uplink_network 192.168.90.77/24)" "host form to network form"
assert_eq "10.0.0.0/8" "$(halow_uplink_network 10.1.2.3/8)" "a /8"
assert_eq "1.2.3.4/32" "$(halow_uplink_network 1.2.3.4)" "a bare address is a /32"
assert_eq "0.0.0.0/0" "$(halow_uplink_network 9.9.9.9/0)" "a /0"
assert_failure "a non-address is refused" halow_uplink_network fe80::1/64

echo "-- DHCP pool and station bound --"
assert_eq "101" "$(halow_dhcp_pool_size 192.168.90.50 192.168.90.150)" "pool size is inclusive"
assert_eq "1" "$(halow_dhcp_pool_size 192.168.90.50 192.168.90.50)" "a single-address pool"
assert_failure "a reversed range fails" halow_dhcp_pool_size 192.168.90.150 192.168.90.50
assert_failure "an invalid address fails" halow_dhcp_pool_size 192.168.90.x 192.168.90.50
assert_eq "101" "$(halow_max_stations 192.168.90.50 192.168.90.150)" "stations bounded by the pool"
assert_eq "255" "$(halow_max_stations 10.0.0.10 10.0.10.10)" "stations capped at 255"
assert_eq "1" "$(halow_max_stations 10.0.0.10 10.0.0.10)" "at least one station"
assert_failure "station bound fails for a reversed range" halow_max_stations 10.0.0.10 10.0.0.9

halow_test_teardown
echo "test_uplink: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
