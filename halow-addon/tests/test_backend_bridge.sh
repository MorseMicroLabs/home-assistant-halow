#!/usr/bin/env bash
# Tests the real `bridge` backend (rootfs/usr/lib/halow/backend_bridge.sh) end to end
# against the fake `ip`, `bridge`, `ss` and `dnsmasq` (tests/doubles/bin), with the
# firewall's NAT functions and NetworkManager calls replaced by recording stubs:
# contract conformance, configuration validation, attach order (address, DHCP, NAT last)
# and the undo of every earlier step when a later one fails, ordinary and four-address
# stations, the capacity limit, hard failures, teardown order and idempotency, teardown
# from a separate process, health, and the station lifecycle driving it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./doubles/fakes_env.sh

halow_test_setup
halow_fakes_install
SYS="$HALOW_SYS_CLASS_NET_DIR"
BR=halow-br0
CALLS="$HALOW_FAKE_LOG"
sleep() { return 0; }
halow_dnsmasq_sleep() { command sleep 0.3; }
halow_fw_install_nat() { echo "install_nat $*" >> "$CALLS"; halow_own_mark fw_nat "subnet=$2 uplink=$3"; return "${_nat_rc:-0}"; }
halow_fw_remove_nat() { echo "remove_nat" >> "$CALLS"; [ "${_rm_nat_rc:-0}" -ne 0 ] || halow_own_clear fw_nat; return "${_rm_nat_rc:-0}"; }
halow_nm_mark_unmanaged_if_known() { echo "nm_mark $1 $2" >> "$CALLS"; return "${_nm_mark_rc:-0}"; }
halow_nm_assert_no_device() { echo "nm_assert $1" >> "$CALLS"; return "${_nm_assert_rc:-0}"; }
# The IPv6 firewall check (firewall.sh) is stubbed: _gov_rc 0 = the IPv6 chains are verified.
halow_fw_ipv6_governed() { echo "ipv6_governed $*" >> "$CALLS"; return "${_gov_rc:-1}"; }
V6="$HALOW_PROC_SYS_DIR/net/ipv6/conf"
# dbus-send stand-in for the one-shot NetworkManager probe of per-station interfaces. Default
# "bus": an unanswerable query, so every test above this block takes the tolerant-mark path.
_nm_probe=bus
dbus-send() {
    echo "dbus-send $*" >> "$CALLS"
    case "$_nm_probe" in
        unknown) echo "Error org.freedesktop.NetworkManager.UnknownDevice: No device found for the requested iface." >&2; return 1 ;;
        listed)  echo '   object path "/org/freedesktop/NetworkManager/Devices/7"' ;;
        *)       echo "Error org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; return 1 ;;
    esac
}

# Write detection for the IPv4 forwarding switch: the fake /proc/sys tree's ip_forward is
# watched (content and modification time) and a `sysctl` on PATH records any call. No
# library may ever change it; checked at the end of this suite.
export HALOW_IP_FORWARD_FILE="$HALOW_PROC_SYS_DIR/net/ipv4/ip_forward"
touch -d '2001-01-01 00:00:00' "$HALOW_IP_FORWARD_FILE"
FWD_BEFORE="$(cat "$HALOW_IP_FORWARD_FILE") $(stat -c '%Y %s' "$HALOW_IP_FORWARD_FILE")"
printf '#!/bin/sh\necho "sysctl $*" >> "%s"\nexit 0\n' "$HALOW_TEST_TMP/sysctl.calls" > "$HALOW_FAKE_BIN/sysctl"
chmod +x "$HALOW_FAKE_BIN/sysctl"

CFG=(bridge=$BR subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 uplink=end0 parent=wlu1 max_stations=3)

live_dnsmasq() {
    local d out=""
    for d in /proc/[0-9]*; do
        [ "$(cat "$d/comm" 2>/dev/null)" = "dnsmasq" ] || continue
        if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qxF -- "--conf-file=$HALOW_RUN_DIR/dnsmasq.conf"; then out="$out ${d#/proc/}"; fi
    done
    printf '%s' "${out# }"
}
kill_dnsmasq() { local p; for p in $(live_dnsmasq); do kill "$p" 2>/dev/null; done; command sleep 0.3; }
line_of() { grep -n -F -- "$1" "$CALLS" | head -n1 | cut -d: -f1; }
owned() { local k out=""; for k in net_bridge_addr net_dnsmasq fw_nat; do halow_own_check "$k" && out="$out $k"; done; printf '%s' "${out# }"; }

fresh() {
    kill_dnsmasq
    bridge_backend_teardown >/dev/null 2>&1 || true
    halow_fakes_reset
    rm -rf "${SYS:?}"/* "${HALOW_STATE_DIR:?}/owns" "${HALOW_RUN_DIR:?}" "${V6:?}"/wlu1* "${V6:?}/$BR"
    mkdir -p "$HALOW_RUN_DIR"
    halow_fakes_iface wlu1; halow_fakes_iface end0
    halow_bridge_create "$BR" >/dev/null 2>&1
    : > "$CALLS"
    _nat_rc=0; _rm_nat_rc=0; _nm_mark_rc=0; _nm_assert_rc=0; _gov_rc=1
    HALOW_BB_ATTACHED=""; HALOW_BB_BRIDGE=""
    HALOW_BACKEND_NAME=""; halow_backend_register_default >/dev/null 2>&1
}
attached() { fresh; bridge_backend_configure "${CFG[@]}" && bridge_backend_attach bridge "$BR" >/dev/null 2>&1; : > "$CALLS"; }

echo "== test_backend_bridge: contract =="
fresh
assert_success "the bridge backend satisfies the whole contract" halow_backend_check_contract bridge
assert_eq "bridge" "$HALOW_BACKEND_NAME" "it is the registered default"
assert_eq "net_bridge_addr net_dnsmasq fw_nat" "$(halow_backend_ownership_keys)" "its ownership keys"

echo "== test_backend_bridge: configure =="
fresh
assert_success "a complete configuration is accepted" bridge_backend_configure "${CFG[@]}"
assert_eq "192.168.90.1" "$HALOW_BB_GATEWAY" "...the gateway is the subnet's own address"
assert_failure "a missing key is refused" bridge_backend_configure bridge=$BR subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 parent=wlu1 max_stations=3
assert_failure "a missing uplink is refused (the manager passes the detected one)" bridge_backend_configure "${CFG[@]/uplink=end0/uplink=}"
assert_failure "an unknown key is refused, not ignored" bridge_backend_configure "${CFG[@]}" colour=blue
_d="$(bridge_backend_configure "${CFG[@]}" colour=blue 2>&1)"
assert_success "...and the refusal names it" grep -q "unknown key 'colour'" <<< "$_d"
assert_failure "a repeated key is refused" bridge_backend_configure "${CFG[@]}" max_stations=4
assert_failure "a non key=value argument is refused" bridge_backend_configure "${CFG[@]}" stray
assert_failure "an invalid subnet is refused" bridge_backend_configure "${CFG[@]/subnet=192.168.90.1\/24/subnet=192.168.90.1/40}"
assert_failure "a DHCP range outside the subnet is refused" bridge_backend_configure "${CFG[@]/dhcp_start=192.168.90.50/dhcp_start=10.0.0.5}"
assert_failure "an invalid bridge name is refused" bridge_backend_configure "${CFG[@]/bridge=$BR/bridge=bad;br}"
assert_failure "max_stations 0 is refused" bridge_backend_configure "${CFG[@]/max_stations=3/max_stations=0}"
assert_failure "max_stations above 255 is refused" bridge_backend_configure "${CFG[@]/max_stations=3/max_stations=256}"
assert_failure "the uplink may not be the parent" bridge_backend_configure "${CFG[@]/uplink=end0/uplink=wlu1}"
assert_failure "an invalid lease time is refused" bridge_backend_configure "${CFG[@]}" 'lease_time=1;x'
assert_success "a valid lease time is accepted" bridge_backend_configure "${CFG[@]}" lease_time=6h

echo "== test_backend_bridge: attach =="
fresh
assert_exit 1 "attach before configure fails" bridge_backend_attach bridge "$BR"
bridge_backend_configure "${CFG[@]}"
assert_exit "$HALOW_BACKEND_RC_UNSUPPORTED" "a station-interface attachment is unsupported (2)" bridge_backend_attach station-interface wlu1.sta1
assert_exit 1 "attach to a different bridge name fails" bridge_backend_attach bridge other0
assert_eq "" "$(cat "$CALLS")" "...and none of these touched the host"
assert_exit 0 "attach to the bridge succeeds" bridge_backend_attach bridge "$BR"
_a="$(line_of "ip addr add 192.168.90.1/24 dev $BR")"; _d="$(line_of "dnsmasq --conf-file=")"; _n="$(line_of "install_nat")"
[ -n "$_a" ] && [ -n "$_d" ] && [ -n "$_n" ] && [ "$_a" -lt "$_d" ] && [ "$_d" -lt "$_n" ] && _ok=ok || _ok="bad($_a,$_d,$_n)"
assert_eq "ok" "$_ok" "order: gateway address, then dnsmasq, then the NAT chain LAST"
assert_eq "install_nat $BR 192.168.90.1/24 end0" "$(grep '^install_nat' "$CALLS")" "the NAT chain is installed for the bridge, the subnet and the uplink"
assert_success "the bridge has the gateway address" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_eq "$BR
192.168.90.1/24" "$(halow_own_get net_bridge_addr)" "net_bridge_addr records the bridge and the address (for a separate process)"
assert_eq "net_bridge_addr net_dnsmasq fw_nat" "$(owned)" "all three backend keys are owned"
assert_success "dnsmasq is running, bound to the bridge" grep -qx "interface=$BR" "$HALOW_RUN_DIR/dnsmasq.conf"
assert_eq "1" "$(live_dnsmasq | wc -w | tr -d ' ')" "exactly one dnsmasq is running"
assert_success "health: healthy" bridge_backend_health
assert_exit "$HALOW_BACKEND_RC_LIMIT" "a second attach is the limit (10)" bridge_backend_attach bridge "$BR"
assert_failure "configure while attached is refused" bridge_backend_configure "${CFG[@]}"
fresh
rm -rf "${SYS:?}/$BR"; halow_own_clear net_bridge
bridge_backend_configure "${CFG[@]}"
assert_exit 1 "attach to a bridge that does not exist fails" bridge_backend_attach bridge "$BR"

echo "== test_backend_bridge: attach isolates the parent the access point bridged =="
fresh; bridge_backend_configure "${CFG[@]}"
command ip link set dev wlu1 master "$BR"; : > "$CALLS"
assert_eq "0" "$(cat "$SYS/wlu1/brport/isolated")" "(the access point added the parent without isolation)"
assert_exit 0 "attach succeeds" bridge_backend_attach bridge "$BR"
assert_eq "1" "$(cat "$SYS/wlu1/brport/isolated")" "...the parent is isolated at attach, before any station"
_i="$(line_of "bridge link set dev wlu1 isolated on")"; _a="$(line_of "ip addr add 192.168.90.1/24 dev $BR")"
[ -n "$_i" ] && [ -n "$_a" ] && [ "$_i" -lt "$_a" ] && _ok=ok || _ok="bad($_i,$_a)"
assert_eq "ok" "$_ok" "...before the bridge gets its address and DHCP"
fresh; bridge_backend_configure "${CFG[@]}"
command ip link set dev wlu1 master "$BR"; : > "$CALLS"
export HALOW_FAKE_FAIL="bridge link set dev wlu1 *"
assert_exit 1 "a parent that cannot be isolated fails the attach" bridge_backend_attach bridge "$BR"
assert_eq "other" "$HALOW_BB_FAIL_KIND" "...an ordinary backend failure"
assert_eq "0" "$(grep -c -E '^(ip addr add|dnsmasq|install_nat)' "$CALLS")" "...before any address, DHCP or NAT"
assert_eq "" "$(owned)" "...nothing owned"
halow_fakes_reset
fresh; bridge_backend_configure "${CFG[@]}"
mkdir -p "$SYS/otherbr/brif"; ln -s ../otherbr "$SYS/wlu1/master"
assert_exit 1 "a parent that is a port of another bridge fails the attach" bridge_backend_attach bridge "$BR"
rm -f "$SYS/wlu1/master"

echo "== test_backend_bridge: a failure at each attach step undoes the earlier ones =="
fresh; bridge_backend_configure "${CFG[@]}"
export HALOW_FAKE_FAIL="ip addr add*"
assert_exit 1 "the address cannot be added: attach fails" bridge_backend_attach bridge "$BR"
assert_eq "" "$(owned)" "...nothing is left owned"
assert_eq "0" "$(grep -c -E '^(dnsmasq|install_nat)' "$CALLS")" "...and neither DHCP nor NAT was attempted"

fresh; bridge_backend_configure "${CFG[@]}"
SSF="$HALOW_TEST_TMP/ss.out"; echo "udp   UNCONN 0 0 0.0.0.0:53 0.0.0.0:*" > "$SSF"; export HALOW_FAKE_SS="$SSF"
assert_exit 1 "another DNS listener: attach fails" bridge_backend_attach bridge "$BR"
assert_success "...the failure detail names the port" grep -q "port 53/udp" <<< "$HALOW_BB_FAIL_DETAIL"
assert_failure "...the address is removed again" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_eq "" "$(owned)" "...nothing is left owned"
assert_eq "0" "$(grep -c '^dnsmasq ' "$CALLS")" "...dnsmasq was never started"
unset HALOW_FAKE_SS

fresh; bridge_backend_configure "${CFG[@]}"
export HALOW_FAKE_DNSMASQ_EXIT=1
assert_exit 1 "dnsmasq does not start: attach fails" bridge_backend_attach bridge "$BR"
assert_failure "...the address is removed again" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_eq "" "$(owned)" "...nothing is left owned"
assert_eq "0" "$(grep -c '^install_nat' "$CALLS")" "...and NAT was never installed"
unset HALOW_FAKE_DNSMASQ_EXIT

fresh; bridge_backend_configure "${CFG[@]}"
_nat_rc=1
assert_exit 1 "the NAT chain cannot be installed: attach fails" bridge_backend_attach bridge "$BR"
assert_eq "1" "$(grep -c '^remove_nat' "$CALLS")" "...the NAT chain is removed again"
assert_eq "" "$(live_dnsmasq)" "...dnsmasq is stopped"
assert_failure "...the address is removed" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_eq "" "$(owned)" "...and nothing is left owned"
assert_eq "" "$HALOW_BB_ATTACHED" "...and no attachment is recorded"

echo "== test_backend_bridge: stations =="
attached
assert_exit 0 "an ordinary station on the parent is served" bridge_backend_station_added wlu1 AA:BB:CC:00:00:01
assert_eq "$BR" "$(halow_bridge_port_master wlu1)" "...the parent is a bridge port"
assert_eq "1" "$(cat "$SYS/wlu1/brport/isolated")" "...with port isolation on"
assert_eq "0" "$(grep -c '^nm_' "$CALLS")" "...and the parent is left to the manager's NetworkManager handling"
halow_fakes_iface wlu1.sta1
assert_exit 0 "a four-address station on its own interface is served" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
assert_eq "nm_mark wlu1.sta1 nm_unmanaged_wds_wlu1.sta1
nm_assert wlu1.sta1" "$(grep '^nm_' "$CALLS")" "...it is kept away from NetworkManager (tolerant mark) and re-checked"
assert_eq "$BR" "$(halow_bridge_port_master wlu1.sta1)" "...it is a bridge port"
assert_eq "1" "$(cat "$SYS/wlu1.sta1/brport/isolated")" "...isolated"
_nm_before="$(grep -c '^nm_assert' "$CALLS")"
halow_own_mark nm_unmanaged_wds_wlu1.sta1 "x"
bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02 >/dev/null 2>&1
assert_eq "$_nm_before" "$(grep -c '^nm_assert' "$CALLS")" "when NetworkManager knew the interface and it was marked, no no-device assertion follows"
halow_own_clear nm_unmanaged_wds_wlu1.sta1
assert_exit 0 "re-adding a served station is idempotent" bridge_backend_station_added wlu1 aa:bb:cc:00:00:01
halow_fakes_iface wlu1.sta2
assert_exit 0 "an ordinary station that moves to its own interface is served there" bridge_backend_station_added wlu1.sta2 aa:bb:cc:00:00:01
assert_eq "wlu1.sta2" "${HALOW_BB_STATION_PORT[aa:bb:cc:00:00:01]}" "...and counted once, on its new port"
assert_exit 0 "a third station fits (max 3)" bridge_backend_station_added wlu1 aa:bb:cc:00:00:03
assert_exit "$HALOW_BACKEND_RC_LIMIT" "a fourth station is the documented limit (10)" bridge_backend_station_added wlu1 aa:bb:cc:00:00:04
bridge_backend_station_removed wlu1 aa:bb:cc:00:00:03 >/dev/null 2>&1
assert_exit 0 "...the fourth station now fits" bridge_backend_station_added wlu1 aa:bb:cc:00:00:04
assert_exit 1 "a port that is neither the parent nor wlu1.sta<N> is a hard error" bridge_backend_station_added eth0 aa:bb:cc:00:00:05
assert_exit 1 "a per-station port that does not exist is a hard error" bridge_backend_station_added wlu1.sta9 aa:bb:cc:00:00:05
assert_exit 1 "a station id that is not a MAC is a hard error" bridge_backend_station_added wlu1 not-a-mac
halow_fakes_iface wlu1.sta3
bridge_backend_station_removed wlu1 aa:bb:cc:00:00:04 >/dev/null 2>&1   # room below the limit for the failure cases
_nm_mark_rc=1
assert_exit 1 "a NetworkManager failure on a per-station interface is a hard error" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:00:06
_nm_mark_rc=0; _nm_assert_rc=1
assert_exit 1 "NetworkManager tracking the per-station interface is a hard error" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:00:06
_nm_assert_rc=0
export HALOW_FAKE_FAIL="bridge link set*"
assert_exit 1 "isolation that cannot be set is a hard error (the station is not served)" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:00:06
assert_eq "" "${HALOW_BB_STATION_PORT[aa:bb:cc:00:00:06]:-}" "...and it is not recorded as served"
assert_eq "" "$(halow_bridge_port_master wlu1.sta3)" "...and the un-isolated per-station port is taken out of the bridge again (fail closed)"
halow_fakes_reset
export HALOW_FAKE_FAIL="ip link set dev wlu1.sta3 master*"
assert_exit 1 "membership that cannot be set is a hard error" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:00:06
halow_fakes_reset
command ip addr del 192.168.90.1/24 dev "$BR"
assert_exit 1 "a bridge that lost its address cannot serve a station (hard error, never success)" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:00:06
assert_failure "...and health reports it" bridge_backend_health
command ip addr add 192.168.90.1/24 dev "$BR"

echo "== test_backend_bridge: station removal =="
: > "$CALLS"
assert_exit 0 "a four-address station leaving" bridge_backend_station_removed wlu1.sta2 aa:bb:cc:00:00:01
assert_eq "" "$(halow_bridge_port_master wlu1.sta2)" "...its port leaves the bridge"
assert_exit 0 "an ordinary station leaving" bridge_backend_station_removed wlu1 aa:bb:cc:00:00:04
assert_eq "$BR" "$(halow_bridge_port_master wlu1)" "...the parent stays a port"
assert_exit 0 "a removal for a port that is already gone is not an error" bridge_backend_station_removed wlu1.sta7 aa:bb:cc:00:00:07
export HALOW_FAKE_FAIL="ip link set dev wlu1.sta1 nomaster"
assert_exit 1 "a port that cannot be released is a hard error" bridge_backend_station_removed wlu1.sta1 aa:bb:cc:00:00:02
halow_fakes_reset

echo "== test_backend_bridge: per-station interfaces: isolation first, IPv6 off =="
attached
halow_fakes_iface wlu1.sta1
command ip link set dev wlu1.sta1 master "$BR"; : > "$CALLS"   # bridged by the access point
assert_exit 0 "a four-address station on a port the access point bridged is served" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:01:01
_i="$(line_of "bridge link set dev wlu1.sta1 isolated on")"; _n="$(line_of "nm_mark wlu1.sta1")"
[ -n "$_i" ] && [ -n "$_n" ] && [ "$_i" -lt "$_n" ] && _ok=ok || _ok="bad($_i,$_n)"
assert_eq "ok" "$_ok" "...its port is isolated before anything else is checked"
assert_eq "1" "$(cat "$V6/wlu1.sta1/disable_ipv6")" "...IPv6 is off on the per-station interface"
assert_eq "0" "$(halow_own_get ipv6_wlu1.sta1)" "...with the original value recorded"
assert_eq "" "$HALOW_BB_FAIL_KIND" "...and no failure kind after a success"
assert_eq "0" "$(cat "$V6/wlu1/disable_ipv6")" "the parent's IPv6 is not the backend's to change"
halow_fakes_iface wlu1.sta2
_halow_ipv6_write_saved="$(declare -f _halow_ipv6_write)"
_halow_ipv6_write() { return 1; }
_gov_rc=1
assert_exit 1 "IPv6 that cannot be turned off, with the IPv6 chains unverified, is a hard error" bridge_backend_station_added wlu1.sta2 aa:bb:cc:00:01:02
assert_success "...the detail names IPv6" grep -q "IPv6" <<< "$HALOW_BB_FAIL_DETAIL"
assert_eq "" "$(halow_bridge_port_master wlu1.sta2)" "...and the port is taken out of the bridge"
assert_eq "" "${HALOW_BB_STATION_PORT[aa:bb:cc:00:01:02]:-}" "...the station is not served"
_gov_rc=0
assert_exit 0 "with the IPv6 chains verified the station is served (the second layer holds)" bridge_backend_station_added wlu1.sta2 aa:bb:cc:00:01:02
assert_success "...after asking the firewall" grep -q "^ipv6_governed $BR" "$CALLS"
eval "$_halow_ipv6_write_saved"
halow_fakes_iface wlu1.sta3
_v6_saved="$(declare -f halow_ipv6_disable)"
halow_ipv6_disable() { return 2; }   # INCOMPLETE: a temporary writable mount is not confirmed removed
_gov_rc=0                            # the IPv6 chains WOULD be verified: rc 2 must not take that fallback
: > "$CALLS"
assert_exit 1 "rc 2 from the IPv6 library (a writable mount not confirmed removed) is a hard error even with the chains verified" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:01:03
assert_success "...the detail names the temporary writable mount" grep -q "temporary writable mount" <<< "$HALOW_BB_FAIL_DETAIL"
assert_failure "...the firewall fallback was not even consulted" grep -q "^ipv6_governed" "$CALLS"
assert_eq "" "$(halow_bridge_port_master wlu1.sta3)" "...the port is taken out of the bridge"
assert_eq "" "${HALOW_BB_STATION_PORT[aa:bb:cc:00:01:03]:-}" "...the station is not served"
halow_ipv6_disable() { return 1; }   # a refused write: the documented firewall fallback
: > "$CALLS"
assert_exit 0 "rc 1 (the write refused) with the chains verified still serves the station" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:01:03
assert_success "...after asking the firewall" grep -q "^ipv6_governed $BR" "$CALLS"
eval "$_v6_saved"
_gov_rc=1

echo "== test_backend_bridge: a station over the limit keeps no bridged port =="
attached
for n in 1 2 3; do halow_fakes_iface "wlu1.sta$n"; bridge_backend_station_added "wlu1.sta$n" "aa:bb:cc:00:02:0$n" >/dev/null 2>&1; done
halow_fakes_iface wlu1.sta4
command ip link set dev wlu1.sta4 master "$BR"   # bridged by the access point
assert_exit "$HALOW_BACKEND_RC_LIMIT" "a fourth four-address station is over the limit (10)" bridge_backend_station_added wlu1.sta4 aa:bb:cc:00:02:04
assert_eq "" "$(halow_bridge_port_master wlu1.sta4)" "...and its per-station port leaves the bridge"
command ip link set dev wlu1.sta4 master "$BR"
export HALOW_FAKE_FAIL="ip link set dev wlu1.sta4 nomaster"
assert_exit 1 "over the limit with a port that cannot be released is a hard error" bridge_backend_station_added wlu1.sta4 aa:bb:cc:00:02:04
assert_eq "1" "$(cat "$SYS/wlu1.sta4/brport/isolated")" "...the port was at least isolated first"
halow_fakes_reset
command ip link set dev wlu1 master "$BR"
assert_exit "$HALOW_BACKEND_RC_LIMIT" "an ordinary station over the limit is not served" bridge_backend_station_added wlu1 aa:bb:cc:00:02:05
assert_eq "$BR" "$(halow_bridge_port_master wlu1)" "...the parent stays a port (other stations use it)"

echo "== test_backend_bridge: the failure kind (NetworkManager or other) =="
attached
halow_fakes_iface wlu1.sta3
_nm_mark_rc=1
assert_exit 1 "NetworkManager refusing the per-station interface is a hard error" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:03:01
assert_eq "nm|nm" "$HALOW_BB_FAIL_KIND|$HALOW_BACKEND_FAIL_KIND" "...of kind nm (also under the contract's neutral name)"
_nm_mark_rc=0; _nm_assert_rc=1
assert_exit 1 "NetworkManager tracking the per-station interface is a hard error" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:03:01
assert_eq "nm" "$HALOW_BB_FAIL_KIND" "...of kind nm"
_nm_assert_rc=0
assert_exit 1 "a port that does not exist is a hard error" bridge_backend_station_added wlu1.sta8 aa:bb:cc:00:03:02
assert_eq "other" "$HALOW_BB_FAIL_KIND" "...of kind other"
assert_exit 0 "a later success" bridge_backend_station_added wlu1.sta3 aa:bb:cc:00:03:01
assert_eq "|" "$HALOW_BB_FAIL_KIND|$HALOW_BB_FAIL_DETAIL" "...resets the kind and detail"

echo "== test_backend_bridge: a vanished per-station interface drops its IPv6 record =="
attached
halow_fakes_iface wlu1.sta1
bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:04:01 >/dev/null 2>&1
bridge_backend_station_removed wlu1.sta1 aa:bb:cc:00:04:01 >/dev/null 2>&1
assert_success "an interface that still exists keeps its record (IPv6 stays off)" halow_own_check ipv6_wlu1.sta1
bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:04:01 >/dev/null 2>&1
halow_fakes_iface_gone wlu1.sta1
assert_exit 0 "removal of a station whose interface is gone" bridge_backend_station_removed wlu1.sta1 aa:bb:cc:00:04:01
assert_failure "...drops the record of the vanished interface" halow_own_check ipv6_wlu1.sta1

echo "== test_backend_bridge: not attached =="
fresh; bridge_backend_configure "${CFG[@]}"
assert_exit 1 "station_added before attach is a hard error" bridge_backend_station_added wlu1 aa:bb:cc:00:00:01
assert_failure "health before attach is unhealthy" bridge_backend_health

echo "== test_backend_bridge: health =="
attached
assert_success "healthy when attached" bridge_backend_health
kill_dnsmasq
assert_failure "unhealthy when dnsmasq is gone" bridge_backend_health

echo "== test_backend_bridge: teardown =="
attached
assert_exit 0 "teardown succeeds" bridge_backend_teardown
_s="$(line_of "remove_nat")"; _x="$(line_of "ip addr del 192.168.90.1/24 dev $BR")"
[ -n "$_s" ] && [ -n "$_x" ] && [ "$_s" -lt "$_x" ] && _ok=ok || _ok="bad($_s,$_x)"
assert_eq "ok" "$_ok" "order: DHCP (stopped first), the NAT chain, then the bridge address"
assert_eq "" "$(live_dnsmasq)" "dnsmasq is gone"
assert_eq "" "$(owned)" "every backend key is cleared"
assert_failure "the address is gone" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_file_exists "$HALOW_LEASE_DIR/dnsmasq.leases" "the persisted lease file is kept at teardown (an add-on restart keeps the leases)"
assert_file_absent "$HALOW_RUN_DIR/dnsmasq.leases" "...and no lease file is left in the run directory"
assert_exit 0 "a second teardown is idempotent" bridge_backend_teardown

attached
_rm_nat_rc=1
assert_exit 0 "a NAT chain that cannot be removed while fw_nat is owned is reported through the key" bridge_backend_teardown
assert_eq "fw_nat" "$(owned)" "...fw_nat is kept, the rest cleared"
halow_own_clear fw_nat
assert_exit 1 "a NAT chain that cannot be confirmed removed without a marker is a hard failure" bridge_backend_teardown
_rm_nat_rc=0

attached
halow_own_clear net_dnsmasq
assert_exit 1 "an identity-matching dnsmasq without a marker is a hard failure" bridge_backend_teardown
assert_eq "1" "$(live_dnsmasq | wc -w | tr -d ' ')" "...and it is not signalled"
kill_dnsmasq

attached
export HALOW_FAKE_FAIL="ip addr del*"
assert_exit 0 "an address that cannot be removed is reported through its key" bridge_backend_teardown
assert_eq "net_bridge_addr" "$(owned)" "...net_bridge_addr is kept"
halow_fakes_reset
assert_exit 0 "a later teardown completes it" bridge_backend_teardown
assert_eq "" "$(owned)" "...and clears it"

attached
command ip link del dev "$BR"
assert_exit 0 "an address on a bridge that is already gone needs no removal" bridge_backend_teardown
assert_eq "" "$(owned)" "...the key is cleared"

echo "== test_backend_bridge: teardown from a separate process (durable state only) =="
attached
CHILD="$HALOW_TEST_TMP/teardown_child.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_SYS_CLASS_NET_DIR="$SYS" PATH="$PATH" HALOW_FAKE_LOG="$CALLS"
for lib in constants common ownership validate iface_detect network_backend backend bridge dnsmasq backend_bridge; do . "$HALOW_LIB_DIR/\$lib.sh"; done
halow_dnsmasq_sleep() { command sleep 0.3; }
halow_fw_remove_nat() { echo remove_nat >> "$CALLS"; halow_own_clear fw_nat; }
HALOW_BACKEND_NAME=""
halow_backend_register_default
if halow_backend_call teardown; then echo td=0; else echo td=\$?; fi
echo CHILD_REACHED_THE_END
EOF
_out="$(bash "$CHILD" 2>&1)"; _rc=$?
assert_eq "0" "$_rc" "a fresh process under the strict options tears the backend down"
assert_success "...returning 0" grep -q "td=0" <<< "$_out"
assert_eq "" "$(owned)" "...every backend key cleared"
assert_failure "...the address removed (found from its marker alone)" grep -qxF "192.168.90.1/24" "$SYS/$BR/.addrs"
assert_eq "" "$(live_dnsmasq)" "...and dnsmasq stopped"
HALOW_BB_ATTACHED=""

echo "== test_backend_bridge: the real teardown and rollback from a fresh process remove the volatile lease fallback =="
FB="$HALOW_RUN_DIR/dnsmasq.leases"
PERS="$HALOW_TEST_TMP/pers-lease"; mkdir -p "$PERS"
GOOD_LEASE="5000 02:00:00:00:00:11 192.168.90.51 * *"
freshproc() { # <snippet> — a new process: only the durable environment, no HALOW_DNSMASQ_LEASE_ACTIVE
    env -i PATH="$PATH" HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_SYS_CLASS_NET_DIR="$SYS" \
        HALOW_LEASE_DIR="$PERS" HALOW_FAKE_LOG="$CALLS" HALOW_LIB_DIR="$HALOW_LIB_DIR" HALOW_IP=ip HALOW_BRIDGE_CMD=bridge HALOW_SS=ss \
        HALOW_PROC_SYS_DIR="$HALOW_PROC_SYS_DIR" HALOW_PROC_MOUNTINFO="${HALOW_PROC_MOUNTINFO:-}" \
        bash -c 'for lib in constants common ownership validate iface_detect network_backend backend bridge dnsmasq backend_bridge; do . "$HALOW_LIB_DIR/$lib.sh"; done
                 halow_dnsmasq_sleep() { command sleep 0.3; }
                 halow_fw_remove_nat() { echo remove_nat >> "$HALOW_FAKE_LOG"; halow_own_clear fw_nat; }
                 HALOW_BACKEND_NAME=""; halow_backend_register_default
                 '"$1"
}
_start_with_fallback() {
    fresh
    echo "$GOOD_LEASE" > "$PERS/dnsmasq.leases"; PERS_BEFORE="$(cat "$PERS/dnsmasq.leases")"
    local _s="$HALOW_LEASE_DIR"; HALOW_LEASE_DIR="$HALOW_TEST_TMP/not-a-dir-bb"; : > "$HALOW_LEASE_DIR"
    bridge_backend_configure "${CFG[@]}"
    bridge_backend_attach bridge "$BR" >/dev/null 2>&1
    HALOW_LEASE_DIR="$_s"
}
_start_with_fallback
assert_eq "$FB" "$HALOW_DNSMASQ_LEASE_ACTIVE" "the attach chose the volatile fallback (variable set in this process only)"
assert_success "...and dnsmasq.conf names it" grep -qxF "dhcp-leasefile=$FB" "$HALOW_RUN_DIR/dnsmasq.conf"
echo "$GOOD_LEASE" > "$FB"
# converse: dnsmasq still running and unconfirmable (no marker) => nothing is removed
halow_own_clear net_dnsmasq
assert_exit 1 "a fresh teardown with a live, unowned dnsmasq is a hard failure" freshproc 'bridge_backend_teardown'
assert_file_exists "$FB" "...and the fallback file is NOT removed"
assert_eq "$PERS_BEFORE" "$(cat "$PERS/dnsmasq.leases")" "...and the persistent database is untouched"
assert_success "...and dnsmasq is still running" test -n "$(live_dnsmasq)"
halow_own_mark net_dnsmasq
assert_exit 0 "marker restored: a fresh teardown (separate process, variable unset) succeeds" freshproc 'bridge_backend_teardown'
assert_eq "" "$(live_dnsmasq)" "...dnsmasq stopped"
assert_file_absent "$FB" "...the volatile fallback file is gone"
assert_eq "$PERS_BEFORE" "$(cat "$PERS/dnsmasq.leases")" "...the persistent lease database is byte-identical"
# the full rollback entry point (what the s6 finish hook runs), from a fresh process
_start_with_fallback; echo "$GOOD_LEASE" > "$FB"
_rb_out="$(freshproc 'for lib in "$HALOW_LIB_DIR"/*.sh; do case "$lib" in */libs.sh) continue ;; esac; . "$lib" 2>/dev/null || true; done
                      halow_dnsmasq_sleep() { command sleep 0.3; }
                      halow_fw_remove_nat() { echo remove_nat >> "$HALOW_FAKE_LOG"; halow_own_clear fw_nat; }
                      HALOW_BACKEND_NAME=""; halow_backend_register_default; halow_rollback >/dev/null 2>&1; echo "rb=$?"; echo "active=${HALOW_DNSMASQ_LEASE_ACTIVE:-unset}"' 2>&1)"
assert_success "halow_rollback ran in a fresh process with the variable unset" grep -q "active=unset" <<< "$_rb_out"
assert_eq "" "$(live_dnsmasq)" "...dnsmasq stopped by the rollback"
assert_file_absent "$FB" "...and the volatile fallback is gone after halow_rollback"
assert_eq "$PERS_BEFORE" "$(cat "$PERS/dnsmasq.leases")" "...the persistent database is byte-identical"
fresh

echo "== test_backend_bridge: the station lifecycle driving the real backend =="
attached
HALOW_BB_ATTACHED=""; HALOW_BB_STATION_PORT=()
kill_dnsmasq; bridge_backend_teardown >/dev/null 2>&1
bridge_backend_configure "${CFG[@]}"
halow_fakes_iface wlu1.sta1
LOG="$HALOW_TEST_TMP/hostapd.log"; : > "$LOG"
_clock=1000; halow_st_now() { printf '%s' "$_clock"; }
halow_st_reset "$LOG" wlu1 "$BR"
assert_success "the manager attaches the backend at start, with no station" halow_st_attach "$BR"
cat >> "$LOG" <<EOF
wlu1: AP-STA-CONNECTED aa:bb:cc:00:00:01
wlu1: AP-STA-CONNECTED aa:bb:cc:00:00:02
wlu1: WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=aa:bb:cc:00:00:02
EOF
assert_success "events are processed" halow_st_process_log
assert_eq "1" "${HALOW_ST_SERVED[aa:bb:cc:00:00:02]}" "the four-address station is served on its interface"
assert_eq "$BR" "$(halow_bridge_port_master wlu1.sta1)" "...which is a bridge port"
_clock=1003
assert_success "after the wait the other station is served" halow_st_process_log
assert_eq "ordinary|wlu1|1" "${HALOW_ST_KIND[aa:bb:cc:00:00:01]}|${HALOW_ST_IFACE[aa:bb:cc:00:00:01]}|${HALOW_ST_SERVED[aa:bb:cc:00:00:01]}" "...as an ordinary station on the parent"
assert_eq "$BR" "$(halow_bridge_port_master wlu1)" "...the parent is a bridge port"
echo "0 aa:bb:cc:00:00:01 192.168.90.60 sensor *" > "$HALOW_LEASE_DIR/dnsmasq.leases"
FDB="$HALOW_TEST_TMP/fdb"; export HALOW_FAKE_FDB="$FDB"
printf '%s\n' "aa:bb:cc:00:00:02 dev wlu1.sta1 master $BR" "de:ad:00:00:00:09 dev wlu1.sta1 master $BR" "02:11:22:33:44:55 dev wlu1.sta1 master $BR permanent" > "$FDB"
NEIGH="$HALOW_TEST_TMP/neigh"; export HALOW_FAKE_NEIGH="$NEIGH"
echo "192.168.90.77 lladdr de:ad:00:00:00:09 REACHABLE" > "$NEIGH"
assert_eq "S|aa:bb:cc:00:00:01|true|ordinary|1000|1000|0|log
SI|192.168.90.60|dhcp|0
S|aa:bb:cc:00:00:02|true|wds|1000|1000|0|log
D|de:ad:00:00:00:09
DI|192.168.90.77|neighbour|0" "$(halow_stations_snapshot_lines)" "the snapshot shows both stations with their kind, and the device behind the four-address one with its address"
echo "AP-STA-DISCONNECTED aa:bb:cc:00:00:02" >> "$LOG"
halow_st_process_log
assert_eq "" "$(halow_bridge_port_master wlu1.sta1)" "a departed four-address station's port leaves the bridge"
assert_eq "0" "$HALOW_ST_FAULT" "no fault was recorded"
halow_fakes_reset

echo "== test_backend_bridge: a NetworkManager fault stays recorded across passes, with its kind =="
attached
HALOW_BB_ATTACHED=""; HALOW_BB_STATION_PORT=()
kill_dnsmasq; bridge_backend_teardown >/dev/null 2>&1
bridge_backend_configure "${CFG[@]}"
LOG="$HALOW_TEST_TMP/hostapd2.log"; : > "$LOG"
_clock=2000
halow_st_reset "$LOG" wlu1 "$BR"
halow_st_attach "$BR" >/dev/null 2>&1
halow_fakes_iface wlu1.sta1; halow_fakes_iface wlu1.sta2
_nm_mark_rc=1
printf '%s\n' "wlu1: WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=aa:bb:cc:00:05:01" "wlu1: AP-STA-CONNECTED aa:bb:cc:00:05:01" >> "$LOG"
halow_st_process_log >/dev/null 2>&1
assert_eq "1|nm" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND" "pass 1: the NetworkManager failure is a fault of kind nm"
_first_msg="$HALOW_ST_FAULT_MSG"
assert_success "...its message carries the backend's reason" grep -q "NetworkManager" <<< "$_first_msg"
_nm_mark_rc=0
printf '%s\n' "wlu1: WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=aa:bb:cc:00:05:02" "wlu1: AP-STA-CONNECTED aa:bb:cc:00:05:02" >> "$LOG"
halow_st_process_log >/dev/null 2>&1
assert_eq "1" "${HALOW_ST_SERVED[aa:bb:cc:00:05:02]}" "pass 2: a later station is served"
assert_eq "1|nm" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND" "...but the fault and its kind stay recorded (sticky)"
assert_eq "nm" "$HALOW_BACKEND_FAIL_KIND" "...and the contract's failure kind still shows the fault after the pass"
assert_eq "$_first_msg" "$HALOW_ST_FAULT_MSG" "...with the first fault's message"
export HALOW_FAKE_FAIL="ip link set dev wlu1.sta2 nomaster"
echo "wlu1: AP-STA-DISCONNECTED aa:bb:cc:00:05:02" >> "$LOG"
if halow_st_process_log >/dev/null 2>&1; then _pl=0; else _pl=1; fi
assert_eq "1" "$_pl" "pass 3: a second, different failure is reported by the pass"
assert_eq "1|nm|$_first_msg" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND|$HALOW_ST_FAULT_MSG" "...but the recorded fault is still the first one"
halow_fakes_reset
_clock=2010; halow_st_process_log >/dev/null 2>&1
assert_eq "1|nm" "$HALOW_ST_FAULT|$HALOW_BACKEND_FAIL_KIND" "pass 4 (nothing new): the fault is still visible"

echo "== test_backend_bridge: per-station interface NetworkManager probe (UnknownDevice is expected, quiet, and not waited for) =="
attached
halow_fakes_iface wlu1.sta1
_nm_probe=unknown
_nmprobe_out="$(bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02 2>&1)"; _nmprobe_rc=$?
assert_eq "0" "$_nmprobe_rc" "UnknownDevice for a per-station interface: the station is served"
assert_eq "0" "$(printf '%s\n' "$_nmprobe_out" | grep -c -E 'ERROR|WARN')" "...with no ERROR and no WARNING line"
assert_eq "1" "$(printf '%s\n' "$_nmprobe_out" | grep -c 'INFO: bridge backend: NetworkManager has no Device for per-station interface wlu1.sta1')" "...and exactly one INFO line about it"
assert_eq "1" "$(grep -c '^dbus-send .*GetDeviceByIpIface string:wlu1.sta1' "$CALLS" | head -n1)" "...the wait loop is not entered: one immediate query before the post-check"
assert_eq "0" "$(grep -c '^nm_mark' "$CALLS")" "...the tolerant mark (10 s wait) is not called"
assert_eq "1" "$(grep -c '^nm_assert' "$CALLS")" "...the post-check after setup still runs"
assert_failure "...and no ownership record exists for the interface" halow_own_check nm_unmanaged_wds_wlu1.sta1
assert_eq "$BR" "$(halow_bridge_port_master wlu1.sta1)" "...it is an isolated bridge port as before"

attached; halow_fakes_iface wlu1.sta1
_nm_probe=listed
assert_exit 0 "a Device NetworkManager DOES list takes the unchanged mark-unmanaged path" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
assert_eq "1" "$(grep -c '^nm_mark wlu1.sta1 nm_unmanaged_wds_wlu1.sta1' "$CALLS")" "...the tolerant mark is called for it"
_nm_mark_rc=1
assert_exit 1 "...and its failure is still a hard error (fail closed)" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
_nm_mark_rc=0

attached; halow_fakes_iface wlu1.sta1
_nm_probe=bus
assert_exit 0 "an unanswerable query falls back to the unchanged tolerant mark" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
assert_eq "1" "$(grep -c '^nm_mark wlu1.sta1' "$CALLS")" "...the mark path was taken"
_nm_mark_rc=1
assert_exit 1 "...and when that cannot be answered either the station is refused (fail closed)" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
_nm_mark_rc=0

attached; halow_fakes_iface wlu1.sta1
_nm_probe=unknown; _nm_assert_rc=1
assert_exit 1 "UnknownDevice at the probe but a Device by the post-check: refused (fail closed)" bridge_backend_station_added wlu1.sta1 aa:bb:cc:00:00:02
_nm_assert_rc=0; _nm_probe=bus

attached
_nm_probe=unknown
bridge_backend_station_added wlu1 aa:bb:cc:00:00:01 >/dev/null 2>&1
assert_eq "0" "$(grep -c '^dbus-send' "$CALLS")" "an ordinary station on the parent never triggers the per-station probe"
_nm_probe=bus

echo "== test_backend_bridge: IPv4 forwarding is never written =="
assert_eq "$FWD_BEFORE" "$(cat "$HALOW_IP_FORWARD_FILE") $(stat -c '%Y %s' "$HALOW_IP_FORWARD_FILE")" "the watched ip_forward was not written by anything this suite ran"
assert_eq "" "$(cat "$HALOW_TEST_TMP/sysctl.calls" 2>/dev/null)" "...and sysctl was never called"
# Static: no library writes the switch. network_backend.sh, which still contains such a
# write, is carried only for the earlier routed backend that the shipped code never
# registers; that is asserted too.
LIBROOT="$HALOW_LIB_DIR/../../.."
_writes="$(grep -rnE -- '((^|[^0-9&>])>>?[[:space:]]*"?[$]?[{]?[A-Za-z_/]*(ip_forward|IP_FORWARD))|sysctl[^#]*(-w|=)[^#]*ip_forward|tee[^#|]*ip_forward|ipv4/conf/[^ ]*/forwarding' "$LIBROOT" | grep -v -- '/network_backend.sh:' || true)"
assert_eq "" "$_writes" "no product file (outside the carried earlier backend) writes ip_forward"
_selftest="$(printf '%s\n' 'printf 1 > "$HALOW_IP_FORWARD_FILE"' 'sysctl -w net.ipv4.ip_forward=1' 'echo 1 | tee /proc/sys/net/ipv4/ip_forward' 'v="$(cat -- "$HALOW_IP_FORWARD_FILE" 2>/dev/null)"' | grep -cE -- '((^|[^0-9&>])>>?[[:space:]]*"?[$]?[{]?[A-Za-z_/]*(ip_forward|IP_FORWARD))|sysctl[^#]*(-w|=)[^#]*ip_forward|tee[^#|]*ip_forward')"
assert_eq "3" "$_selftest" "...the scan recognises the three write forms and not a read"
assert_eq "bridge" "$(HALOW_BACKEND_NAME=''; halow_backend_register_default >/dev/null 2>&1; printf '%s' "$HALOW_BACKEND_NAME")" "the shipped default backend is the bridge backend"
_callers="$(grep -rlE -- 'halow_(apply|teardown)_network' "$HALOW_LIB_DIR" | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "backend_routed_nat.sh network_backend.sh " "$_callers" "only the earlier routed backend reaches the carried code that writes ip_forward"

kill_dnsmasq
halow_test_teardown
echo "test_backend_bridge: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
