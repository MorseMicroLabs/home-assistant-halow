#!/usr/bin/env bash
# Tests the core/backend contract (rootfs/usr/lib/halow/backend.sh):
#   - the bridge backend, the earlier routed/NAT backend and the test double satisfy it;
#   - a backend that does not is refused, and refusing it changes nothing;
#   - the default registration is the bridge backend; routed/NAT stays registrable by name;
#   - the dispatcher behaves with and without a registered backend;
#   - rollback reaches the backend only through the contract (teardown, ownership keys),
#     with different backends;
#   - the routed/NAT adapter's own contract behaviour (attachment kinds, the single
#     attachment limit, teardown ordering and return code);
#   - static: the core files never name a networking implementation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_backend_contract: conformance =="
halow_test_setup
. ./doubles/backend_double.sh

assert_success "the bridge backend satisfies the whole contract" halow_backend_check_contract bridge
assert_success "the routed/NAT backend satisfies the whole contract" halow_backend_check_contract routed_nat
assert_success "the test-double backend satisfies the whole contract" halow_backend_check_contract double
assert_failure "a name with no functions at all is not a backend" halow_backend_check_contract nosuchbackend
assert_failure "an empty name is not a backend" halow_backend_check_contract ""

partial_backend_ownership_keys() { :; }
partial_backend_configure() { :; }
partial_backend_attach() { :; }
partial_backend_station_added() { :; }
partial_backend_station_removed() { :; }
partial_backend_teardown() { :; }
# (no partial_backend_health)
assert_failure "a backend missing one operation is refused" halow_backend_check_contract partial_backend
assert_success "the refusal names the missing operation" \
    bash -c 'grep -q "partial_backend_backend_health" <<< "$1"' _ "$(halow_backend_check_contract partial_backend 2>&1)"

echo "== test_backend_contract: registration =="
HALOW_BACKEND_NAME=""
assert_success "the default registration succeeds" halow_backend_register_default
assert_eq "bridge" "$HALOW_BACKEND_NAME" "...and selects the bridge backend"
assert_eq "net_bridge_addr net_dnsmasq fw_nat" "$(halow_backend_ownership_keys)" "...whose ownership keys are the documented three"
assert_failure "registering a non-conforming backend fails" halow_backend_register partial_backend
assert_eq "bridge" "$HALOW_BACKEND_NAME" "...and leaves the previous selection untouched"
assert_success "the routed/NAT backend is still registrable by name" halow_backend_register routed_nat
assert_eq "routed_nat" "$HALOW_BACKEND_NAME" "...and selected"
assert_success "registering the double succeeds" halow_backend_register double
assert_eq "double" "$HALOW_BACKEND_NAME" "...and switches the selection"

echo "== test_backend_contract: dispatch =="
export HALOW_DBL_LOG="$HALOW_TEST_TMP/double.calls"
: > "$HALOW_DBL_LOG"
halow_backend_call configure bridge=halow-br0 subnet=192.168.90.1/24 >/dev/null
halow_backend_call attach bridge halow-br0 >/dev/null
halow_backend_call station_added wlu1 aa:bb:cc:dd:ee:01 >/dev/null
halow_backend_call station_added wlu1.sta1 aa:bb:cc:dd:ee:02 >/dev/null
halow_backend_call station_removed wlu1.sta1 aa:bb:cc:dd:ee:02 >/dev/null
halow_backend_call teardown >/dev/null
assert_eq "configure bridge=halow-br0 subnet=192.168.90.1/24
attach bridge halow-br0
station_added wlu1 aa:bb:cc:dd:ee:01
station_added wlu1.sta1 aa:bb:cc:dd:ee:02
station_removed wlu1.sta1 aa:bb:cc:dd:ee:02
teardown" "$(cat "$HALOW_DBL_LOG")" "every operation reaches the registered backend with its own arguments, in order"
assert_eq "0" "$(grep -c VIOLATION "$HALOW_DBL_LOG")" "...with no sequence violation"
: > "$HALOW_DBL_LOG"
halow_backend_call station_added wlu1 aa:bb:cc:dd:ee:01 >/dev/null
halow_backend_call attach bridge halow-br0 >/dev/null
halow_backend_call attach bridge halow-br0 >/dev/null
halow_backend_call station_removed wlu1 aa:bb:cc:dd:ee:09 >/dev/null
halow_backend_call station_removed wlu1.sta3 aa:bb:cc:dd:ee:01 >/dev/null
assert_eq "4" "$(grep -c VIOLATION "$HALOW_DBL_LOG")" "the double flags add-before-attach, a second attach, an unknown removal and a wrong-port removal"
halow_backend_call teardown >/dev/null
assert_failure "an operation outside the contract is refused" halow_backend_call frobnicate
assert_eq "dbl_state" "$(halow_backend_ownership_keys)" "ownership keys come from the registered backend"
HALOW_BACKEND_NAME=""
assert_failure "with no backend, attach is refused (never silently ignored)" halow_backend_call attach bridge halow-br0
assert_failure "with no backend, teardown FAILS (a rollback that cannot reach a backend must not look clean)" halow_backend_call teardown
assert_eq "" "$(halow_backend_ownership_keys)" "with no backend there are no backend ownership keys"

echo "== test_backend_contract: rollback goes through the contract only =="
# Everything outside the backend is stubbed to "clean", so the backend alone decides.
rmmod() { return 0; }
lsmod() { return 0; }
halow_fw_remove_filters() { return 0; }
halow_fw_remove_nat() { halow_own_clear fw_nat; return 0; }
halow_fw_present() { return 1; }
HALOW_BACKEND_NAME=""
halow_backend_register double
: > "$HALOW_DBL_LOG"
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "0" "$_rb_rc" "rollback with the double backend and nothing owned returns 0"
assert_success "rollback asked the registered backend to tear down" grep -qx "teardown" "$HALOW_DBL_LOG"
export HALOW_DBL_TEARDOWN_RC=1
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "1" "$_rb_rc" "a backend teardown that reports a hard failure makes rollback INCOMPLETE (return 1)"
unset HALOW_DBL_TEARDOWN_RC
halow_own_mark "dbl_state"
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "1" "$_rb_rc" "a still-owned BACKEND key (dbl_state) makes rollback INCOMPLETE"
assert_success "...and the output names exactly that key" bash -c 'grep -q "\[dbl_state\]" <<< "$1"' _ "$_rb_out"
halow_own_clear "dbl_state"
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "0" "$_rb_rc" "once the backend's key is cleared, rollback completes"
halow_own_mark "net_bridge_addr" "$(printf 'halow-br0\n192.168.90.1/24')"
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "0" "$_rb_rc" "with a different backend registered, the bridge backend's keys are not rollback's business"
halow_own_clear "net_bridge_addr"
HALOW_BACKEND_NAME=""; halow_backend_register_default
halow_own_mark "net_bridge_addr" "$(printf 'halow-br0\n192.168.90.1/24')"
mkdir -p "$HALOW_SYS_CLASS_NET_DIR/halow-br0"
ip() { case "$*" in "-4 addr show dev halow-br0") echo "    inet 192.168.90.1/24 scope global halow-br0" ;; *) return 1 ;; esac; }
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "1" "$_rb_rc" "with the bridge backend registered, an address it cannot remove (net_bridge_addr kept) makes rollback INCOMPLETE"
assert_success "...and the output names that backend key" bash -c 'grep -q "net_bridge_addr" <<< "$1"' _ "$_rb_out"
unset -f ip
rm -rf "${HALOW_SYS_CLASS_NET_DIR:?}/halow-br0"
halow_own_clear "net_bridge_addr"
HALOW_BACKEND_NAME=""
_rb_out="$(halow_rollback 2>&1)"; _rb_rc=$?
assert_eq "1" "$_rb_rc" "with no backend registered, rollback reports INCOMPLETE rather than clean"
HALOW_BACKEND_NAME=""; halow_backend_register_default
unset -f rmmod lsmod halow_fw_remove_filters halow_fw_remove_nat halow_fw_present

echo "== test_backend_contract: the routed/NAT adapter (kept for these tests only) =="
HALOW_BACKEND_NAME=""; halow_backend_register routed_nat
halow_dnsmasq_is_running() { return 0; }
assert_success "health: healthy while dnsmasq matches this package's identity" routed_nat_backend_health
halow_dnsmasq_is_running() { return 1; }
assert_failure "health: unhealthy when it does not" routed_nat_backend_health
unset -f halow_dnsmasq_is_running
assert_eq "$HALOW_NET_OWNERSHIP_KEYS" "$(halow_backend_ownership_keys)" "its ownership keys are exactly the network backend's own list"
assert_failure "configure without every required value fails" routed_nat_backend_configure subnet=192.168.90.1/24
assert_failure "configure rejects an invalid subnet" \
    routed_nat_backend_configure subnet=192.168.90.1/99 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 uplink=end0
assert_failure "configure rejects a DHCP range outside the subnet" \
    routed_nat_backend_configure subnet=192.168.90.1/24 dhcp_start=10.0.0.5 dhcp_end=10.0.0.9 uplink=end0
assert_failure "configure rejects an invalid uplink interface name" \
    routed_nat_backend_configure subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 'uplink=bad name;'
halow_default_uplink_iface() { printf 'end1'; }
routed_nat_backend_configure subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150
assert_eq "end1" "$HALOW_RN_UPLINK" "configure without an uplink derives the default-route interface"
halow_default_uplink_iface() { return 1; }
assert_failure "configure without an uplink fails when none can be derived (no guessing)" \
    routed_nat_backend_configure subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150
unset -f halow_default_uplink_iface
routed_nat_backend_configure subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 uplink=end0
assert_eq "end0" "$HALOW_RN_UPLINK" "an explicit uplink is used as given"
_apply_calls="$HALOW_TEST_TMP/apply.calls"; : > "$_apply_calls"
halow_apply_network() { echo "$*" >> "$_apply_calls"; return "${_apply_rc:-0}"; }
_apply_rc=0
assert_exit "$HALOW_BACKEND_RC_UNSUPPORTED" "a bridge attachment is refused as unsupported" routed_nat_backend_attach bridge br0
assert_eq "0" "$(wc -l < "$_apply_calls" | tr -d ' ')" "...and nothing was applied"
assert_exit 1 "an empty attachment name is refused" routed_nat_backend_attach station-interface ""
_apply_rc=1
assert_exit 1 "a failed apply is reported as failure and does not record an attachment" routed_nat_backend_attach station-interface wlu1.sta1
assert_eq "" "$HALOW_RN_ATTACHMENT" "...no attachment is recorded"
_apply_rc=0
assert_exit 0 "a station interface is attached" routed_nat_backend_attach station-interface wlu1.sta1
assert_eq "wlu1.sta1 192.168.90.1/24 192.168.90.50 192.168.90.150 end0" "$(tail -n1 "$_apply_calls")" "...with exactly the configured network values"
assert_exit "$HALOW_BACKEND_RC_LIMIT" "a second attachment is reported as the limit (10), not as an error" routed_nat_backend_attach station-interface wlu1.sta2
halow_iface_has_cidr() { return 1; }
assert_exit 1 "station_added with the configured address missing is a HARD error, not success" routed_nat_backend_station_added wlu1.sta1 aa:bb:cc:dd:ee:01
halow_iface_has_cidr() { return 0; }
assert_exit 0 "station_added with the address present is success" routed_nat_backend_station_added wlu1.sta1 aa:bb:cc:dd:ee:01
unset -f halow_iface_has_cidr
assert_exit "$HALOW_BACKEND_RC_LIMIT" "a station on any other interface is reported as the limit" routed_nat_backend_station_added wlu1.sta2 aa:bb:cc:dd:ee:02
assert_exit 0 "a station leaving is accepted" routed_nat_backend_station_removed wlu1.sta1 aa:bb:cc:dd:ee:01
_td_calls="$HALOW_TEST_TMP/td.calls"; : > "$_td_calls"
halow_teardown_dnsmasq() { echo dnsmasq >> "$_td_calls"; return "${_td_dns_rc:-0}"; }
halow_teardown_network() { echo "network $*" >> "$_td_calls"; return 0; }
halow_load_network_values() { HALOW_NET_IFACE=wlu1.sta1; HALOW_NET_CIDR=192.168.90.1/24; HALOW_NET_UPLINK=end0; return "${_vals_rc:-0}"; }
_td_dns_rc=0; _vals_rc=0
assert_exit 0 "teardown with nothing wrong returns 0" routed_nat_backend_teardown
assert_eq "dnsmasq
network wlu1.sta1 end0 192.168.90.1/24" "$(cat "$_td_calls")" "dnsmasq is torn down FIRST, then the network, with the persisted values"
: > "$_td_calls"; _td_dns_rc=1
routed_nat_backend_teardown >/dev/null 2>&1; _rc=$?
assert_eq "1" "$_rc" "a dnsmasq hard failure is the teardown's return code (1)"
assert_eq "" "$HALOW_RN_ATTACHMENT" "teardown forgets the attachment"
unset -f halow_apply_network halow_teardown_dnsmasq halow_teardown_network halow_load_network_values
HALOW_BACKEND_NAME=""; halow_backend_register_default

echo "== test_backend_contract: the core never names a networking implementation =="
# Strip full-line comments, then look for anything that belongs to a networking
# implementation. Only backend.sh (the one place that selects the default) may name one.
CORE_FILES=("$HALOW_LIB_DIR/rollback.sh" "$HALOW_LIB_DIR/stations.sh")
for _f in "${CORE_FILES[@]}"; do
    _code="$(grep -v -E "^[[:space:]]*#" "$_f")"
    assert_failure "$(basename "$_f"): no network-implementation function, key, tool or file is referenced" \
        grep -q -E 'halow_apply_network|halow_teardown_network|halow_teardown_dnsmasq|halow_load_network_values|halow_save_network_values|halow_start_dnsmasq|halow_dnsmasq_|net_addr|net_bridge_addr|net_ip_forward|net_nat_rule|net_fwd_rule|net_dnsmasq|iptables|sysctl|dnsmasq' <<< "$_code"
    assert_failure "$(basename "$_f"): no backend is named (only backend.sh selects the default)" \
        grep -q -E 'routed_nat|HALOW_RN_|bridge_backend_|HALOW_BB_' <<< "$_code"
done
assert_success "backend.sh is the single place that names the default backend" \
    grep -q 'halow_backend_register bridge' "$HALOW_LIB_DIR/backend.sh"

halow_test_teardown
echo "test_backend_contract: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
