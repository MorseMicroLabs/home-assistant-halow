#!/usr/bin/env bash
# Tests the private bridge (rootfs/usr/lib/halow/bridge.sh) against the fake `ip` and
# `bridge` commands (tests/doubles/bin), which record every call and keep a small fake
# sysfs tree: marker-before-mutation ordering, MAC pinning, STP off, port membership and
# isolation, removal order, absence confirmation, idempotency and failure rollback.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./doubles/fakes_env.sh

halow_test_setup
halow_fakes_install
SYS="$HALOW_SYS_CLASS_NET_DIR"
BR=halow-br0
sleep() { return 0; }

new_case() {
    halow_fakes_reset
    rm -rf "${SYS:?}"/*
    : > "$HALOW_FAKE_LOG"
    halow_own_clear net_bridge
}

echo "== test_bridge: the pinned MAC =="
_mac="$(halow_bridge_mac "$BR")"
assert_success "the pinned MAC is a well-formed address" bash -c '[[ "$1" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]' _ "$_mac"
assert_eq "02" "${_mac:0:2}" "...locally administered and unicast (first byte 02)"
assert_eq "$_mac" "$(halow_bridge_mac "$BR")" "...and deterministic for the same name"
[ "$_mac" != "$(halow_bridge_mac other-br0)" ] && _ok=ok || _ok=bad
assert_eq "ok" "$_ok" "...and different for a different name"

echo "== test_bridge: create =="
new_case
# The marker must already exist when the first mutating `ip` call runs.
_order="$HALOW_TEST_TMP/order"; : > "$_order"
ip() { if halow_own_check net_bridge; then echo "marker-present $*" >> "$_order"; else echo "marker-absent $*" >> "$_order"; fi; command ip "$@"; }
assert_success "the bridge is created" halow_bridge_create "$BR"
unset -f ip
assert_eq "marker-present link add $BR type bridge" "$(head -n1 "$_order")" "the ownership marker is written BEFORE the bridge is created"
assert_eq "$BR" "$(halow_own_get net_bridge)" "...and records the bridge name"
assert_eq "ip link add $BR type bridge
ip link set dev $BR address $_mac
ip link set dev $BR type bridge stp_state 0
ip link set dev $BR up" "$(cat "$HALOW_FAKE_LOG")" "create, pin the MAC, STP off, up, in that order"
assert_eq "$_mac" "$(cat "$SYS/$BR/address")" "the host shows the pinned MAC"
assert_eq "0" "$(cat "$SYS/$BR/bridge/stp_state")" "the host shows STP off"
assert_eq "up" "$(cat "$SYS/$BR/operstate")" "the bridge is up"
assert_success "halow_bridge_exists sees it" halow_bridge_exists "$BR"

: > "$HALOW_FAKE_LOG"
assert_success "creating it again (ours) is idempotent" halow_bridge_create "$BR"
assert_eq "0" "$(grep -c 'link add' "$HALOW_FAKE_LOG")" "...and creates nothing new"
assert_eq "1" "$(grep -c "address $_mac" "$HALOW_FAKE_LOG")" "...but re-applies the pinned MAC"

new_case
halow_fakes_iface "$BR"
assert_failure "an existing interface of that name that we do not own is refused" halow_bridge_create "$BR"
assert_failure "...and no marker is written for it" halow_own_check net_bridge
assert_eq "0" "$(grep -c 'link' "$HALOW_FAKE_LOG")" "...and nothing is changed on the host"

new_case
assert_failure "an invalid name is refused" halow_bridge_create 'bad;name'
assert_failure "...before any marker" halow_own_check net_bridge

echo "== test_bridge: create failures roll back =="
new_case
export HALOW_FAKE_FAIL="ip link add*"
assert_failure "a failed creation is reported" halow_bridge_create "$BR"
assert_failure "...and the marker is cleared again (nothing was created)" halow_own_check net_bridge
new_case
export HALOW_FAKE_FAIL="ip link set dev $BR address*"
assert_failure "a failed MAC pin is reported" halow_bridge_create "$BR"
assert_failure "...the half-made bridge is removed" halow_bridge_exists "$BR"
assert_failure "...and the marker cleared after confirming its absence" halow_own_check net_bridge
new_case
export HALOW_FAKE_NOOP="ip link set dev $BR address*"
assert_failure "a MAC that does not read back as pinned is a failure" halow_bridge_create "$BR"
assert_failure "...and the bridge is removed again" halow_bridge_exists "$BR"
new_case
export HALOW_FAKE_FAIL="ip link set dev $BR type bridge stp_state*"
assert_failure "a failure turning STP off is reported" halow_bridge_create "$BR"
assert_failure "...and the bridge is removed again" halow_bridge_exists "$BR"
new_case
export HALOW_FAKE_FAIL="ip link set dev $BR address*;ip link del*"
assert_failure "a failed set-up whose cleanup ALSO fails is reported" halow_bridge_create "$BR"
assert_success "...the bridge is still there" halow_bridge_exists "$BR"
assert_success "...so the marker is KEPT (never cleared on a guess)" halow_own_check net_bridge

echo "== test_bridge: ports and isolation =="
new_case
halow_bridge_create "$BR" 2>/dev/null
halow_fakes_iface wlu1; halow_fakes_iface wlu1.sta1
: > "$HALOW_FAKE_LOG"
assert_success "the parent becomes a port" halow_bridge_port_add "$BR" wlu1
assert_eq "$BR" "$(halow_bridge_port_master wlu1)" "...confirmed from the host"
assert_eq "ip link set dev wlu1 master $BR
ip link set dev wlu1 up" "$(cat "$HALOW_FAKE_LOG")" "...with master, then up"
: > "$HALOW_FAKE_LOG"
assert_success "adding it again is idempotent" halow_bridge_port_add "$BR" wlu1
assert_eq "" "$(cat "$HALOW_FAKE_LOG")" "...and runs no command"
assert_failure "a missing interface cannot become a port" halow_bridge_port_add "$BR" wlu1.sta9
assert_failure "a port cannot be added to a missing bridge" halow_bridge_port_add nobr0 wlu1.sta1
mkdir -p "$SYS/otherbr/brif"; ln -s ../otherbr "$SYS/wlu1.sta1/master"
assert_failure "a port of a different bridge is refused, not moved" halow_bridge_port_add "$BR" wlu1.sta1
rm -f "$SYS/wlu1.sta1/master"
export HALOW_FAKE_NOOP="ip link set dev wlu1.sta1 master*"
assert_failure "membership that does not show on the host is a failure" halow_bridge_port_add "$BR" wlu1.sta1
halow_fakes_reset
assert_success "a per-station interface becomes a port" halow_bridge_port_add "$BR" wlu1.sta1
assert_eq "wlu1
wlu1.sta1" "$(halow_bridge_ports "$BR")" "the bridge lists both ports"

: > "$HALOW_FAKE_LOG"
assert_success "isolation on" halow_bridge_port_isolate wlu1.sta1 on
assert_eq "bridge link set dev wlu1.sta1 isolated on" "$(cat "$HALOW_FAKE_LOG")" "...through the bridge command"
assert_eq "1" "$(cat "$SYS/wlu1.sta1/brport/isolated")" "...and the host shows the port isolated"
assert_success "isolation off" halow_bridge_port_isolate wlu1.sta1 off
assert_eq "0" "$(cat "$SYS/wlu1.sta1/brport/isolated")" "...the host shows it off"
assert_failure "an invalid mode is refused" halow_bridge_port_isolate wlu1.sta1 maybe
export HALOW_FAKE_NOOP="bridge link set*"
assert_failure "isolation that does not read back is a failure" halow_bridge_port_isolate wlu1.sta1 on
halow_fakes_reset
export HALOW_FAKE_FAIL="bridge link set*"
assert_failure "a failing bridge command is a failure" halow_bridge_port_isolate wlu1.sta1 on
halow_fakes_reset
halow_fakes_iface eth9
assert_failure "isolation on a non-port is refused" halow_bridge_port_isolate eth9 on

assert_success "a port is released" halow_bridge_port_remove wlu1.sta1
assert_eq "" "$(halow_bridge_port_master wlu1.sta1)" "...confirmed from the host"
assert_success "releasing it again is idempotent" halow_bridge_port_remove wlu1.sta1
assert_success "releasing an interface that no longer exists is not an error" halow_bridge_port_remove wlu1.sta7
halow_bridge_port_add "$BR" wlu1.sta1 2>/dev/null
export HALOW_FAKE_FAIL="ip link set dev wlu1.sta1 nomaster"
assert_failure "a port that cannot be released is a failure" halow_bridge_port_remove wlu1.sta1
halow_fakes_reset

echo "== test_bridge: delete =="
: > "$HALOW_FAKE_LOG"
assert_success "the bridge is deleted" halow_bridge_delete "$BR"
assert_eq "ip link set dev $BR down
ip link set dev wlu1 nomaster
ip link set dev wlu1.sta1 nomaster
ip link del dev $BR" "$(cat "$HALOW_FAKE_LOG")" "down, ports released, then deleted"
assert_failure "it is gone from the host" halow_bridge_exists "$BR"
assert_failure "...and only then is the marker cleared" halow_own_check net_bridge
assert_success "wlu1 still exists (a port is released, never deleted)" halow_bridge_exists wlu1
assert_success "deleting an absent bridge is idempotent" halow_bridge_delete "$BR"

new_case
halow_bridge_create "$BR" 2>/dev/null
export HALOW_FAKE_NOOP="ip link del*"
assert_exit 1 "absence that cannot be confirmed returns 1" halow_bridge_delete "$BR"
assert_success "...and the marker is kept" halow_own_check net_bridge
halow_fakes_reset
new_case
halow_bridge_create "$BR" 2>/dev/null
halow_own_clear net_bridge
assert_success "a bridge left without a marker (lost record) is still recognised by name and deleted" halow_bridge_delete "$BR"
assert_failure "...and is gone" halow_bridge_exists "$BR"

echo "== test_bridge: isolation enforced on every port, whoever added it =="
new_case
halow_bridge_create "$BR" 2>/dev/null
assert_success "an empty bridge is trivially isolated" halow_bridge_enforce_isolation "$BR"
for p in wlu1 wlu1.sta1 wlu1.sta2 wlu1.sta3 wlu1.sta4; do halow_fakes_iface "$p"; done
# The access point adds ports itself (here: plain `ip link set master`, isolation off).
for p in wlu1 wlu1.sta1 wlu1.sta2; do command ip link set dev "$p" master "$BR"; done
command bridge link set dev wlu1.sta2 isolated on
: > "$HALOW_FAKE_LOG"
assert_success "enforcement isolates every unisolated port" halow_bridge_enforce_isolation "$BR"
assert_eq "1 1 1" "$(cat "$SYS/wlu1/brport/isolated") $(cat "$SYS/wlu1.sta1/brport/isolated") $(cat "$SYS/wlu1.sta2/brport/isolated")" "...the host shows all three ports isolated"
assert_eq "bridge link set dev wlu1 isolated on
bridge link set dev wlu1.sta1 isolated on" "$(cat "$HALOW_FAKE_LOG")" "...and only the two unisolated ports were touched"
: > "$HALOW_FAKE_LOG"
assert_success "a second pass succeeds" halow_bridge_enforce_isolation "$BR"
assert_eq "" "$(cat "$HALOW_FAKE_LOG")" "...and runs no command when everything is isolated"
command ip link set dev wlu1.sta3 master "$BR"
export HALOW_FAKE_FAIL="bridge link set dev wlu1.sta3 *"
assert_success "a port that cannot be isolated is removed instead (fail closed)" halow_bridge_enforce_isolation "$BR"
assert_eq "" "$(halow_bridge_port_master wlu1.sta3)" "...it is no longer a bridge port"
assert_success "...but the interface itself still exists" halow_bridge_exists wlu1.sta3
halow_fakes_reset
command ip link set dev wlu1.sta3 master "$BR"
export HALOW_FAKE_NOOP="bridge link set dev wlu1.sta3 *"
assert_success "a port whose isolation does not read back is removed too" halow_bridge_enforce_isolation "$BR"
assert_eq "" "$(halow_bridge_port_master wlu1.sta3)" "...it left the bridge"
halow_fakes_reset
command ip link set dev wlu1.sta4 master "$BR"
export HALOW_FAKE_FAIL="bridge link set dev wlu1.sta4 *;ip link set dev wlu1.sta4 nomaster"
assert_exit 1 "a port that can be neither isolated nor removed fails the enforcement" halow_bridge_enforce_isolation "$BR"
assert_eq "$BR" "$(halow_bridge_port_master wlu1.sta4)" "...(it is still a port: reported, not hidden)"
assert_eq "1 1 1" "$(cat "$SYS/wlu1/brport/isolated") $(cat "$SYS/wlu1.sta1/brport/isolated") $(cat "$SYS/wlu1.sta2/brport/isolated")" "...the other ports stay isolated"
halow_fakes_reset
assert_success "once the port can be isolated, enforcement succeeds again" halow_bridge_enforce_isolation "$BR"
assert_eq "1" "$(cat "$SYS/wlu1.sta4/brport/isolated")" "...and it is isolated"
assert_exit 1 "a bridge that does not exist cannot be enforced (reported, never 'all isolated')" halow_bridge_enforce_isolation nobr0
assert_exit 1 "an invalid bridge name is refused" halow_bridge_enforce_isolation 'b;r'

echo "== test_bridge: a new port is information, a port that lost isolation is a warning =="
new_case
HALOW_BRIDGE_ISOLATED_IDX=()
halow_bridge_create "$BR" 2>/dev/null
for p in wlu1 wlu1.sta1; do halow_fakes_iface "$p"; done
echo 11 > "$SYS/wlu1/ifindex"; echo 21 > "$SYS/wlu1.sta1/ifindex"
command ip link set dev wlu1 master "$BR"
out="$(halow_bridge_enforce_isolation "$BR" 2>&1)"
assert_success "a port hostapd just added is logged as information (new port), never as a warning" bash -c "grep -q 'INFO: bridge: new port wlu1 of $BR (added by hostapd_s1g); isolating it' <<< \"\$1\" && ! grep -q WARN <<< \"\$1\"" _ "$out"
assert_eq "1" "$(cat "$SYS/wlu1/brport/isolated")" "...and it was isolated"
HALOW_BRIDGE_ISOLATED_IDX=([wlu1]=11)
command bridge link set dev wlu1 isolated off
out="$(halow_bridge_enforce_isolation "$BR" 2>&1)"
assert_success "the SAME port (same name and index) found non-isolated again is a warning: something else changed it" bash -c "grep -q 'WARN: bridge: port wlu1 of $BR is no longer isolated (something else changed it); isolating it again' <<< \"\$1\"" _ "$out"
assert_eq "1" "$(cat "$SYS/wlu1/brport/isolated")" "...and it is isolated again"
# A per-station interface recreated under the same name (new index) is a new port again.
command ip link set dev wlu1.sta1 master "$BR"
HALOW_BRIDGE_ISOLATED_IDX=([wlu1.sta1]=20)
out="$(halow_bridge_enforce_isolation "$BR" 2>&1)"
assert_success "a recreated station interface (same name, new index) is information, not a warning" bash -c "grep -q 'INFO: bridge: new port wlu1.sta1 of $BR' <<< \"\$1\" && ! grep -q WARN <<< \"\$1\"" _ "$out"
# Without an index (no sysfs file) the port is treated as new: never a false warning.
new_case
halow_bridge_create "$BR" 2>/dev/null
halow_fakes_iface wlu1
command ip link set dev wlu1 master "$BR"
HALOW_BRIDGE_ISOLATED_IDX=([wlu1]=11)
out="$(halow_bridge_enforce_isolation "$BR" 2>&1)"
assert_success "a port without a readable index is information (never a false warning)" bash -c "grep -q 'INFO: bridge: new port wlu1' <<< \"\$1\" && ! grep -q WARN <<< \"\$1\"" _ "$out"
assert_eq "1" "$(cat "$SYS/wlu1/brport/isolated")" "...and it is isolated"

# A bridge that is deleted and created again (an access point restart) starts afresh: the same
# parent interface (same name, same index) re-added by hostapd is a new port, not a warning.
new_case
HALOW_BRIDGE_ISOLATED_IDX=()
halow_bridge_create "$BR" 2>/dev/null
halow_fakes_iface wlu1
echo 11 > "$SYS/wlu1/ifindex"
command ip link set dev wlu1 master "$BR"
halow_bridge_enforce_isolation "$BR" >/dev/null 2>&1
assert_eq "11" "${HALOW_BRIDGE_ISOLATED_IDX[wlu1]:-}" "the isolated port and its index are remembered"
halow_bridge_delete "$BR" >/dev/null 2>&1
assert_eq "0" "${#HALOW_BRIDGE_ISOLATED_IDX[@]}" "deleting the bridge forgets its ports"
halow_bridge_create "$BR" 2>/dev/null
command ip link set dev wlu1 master "$BR"
command bridge link set dev wlu1 isolated off
out="$(halow_bridge_enforce_isolation "$BR" 2>&1)"
assert_success "after a delete and create the same port is information, never a false warning" bash -c "grep -q 'INFO: bridge: new port wlu1 of $BR' <<< \"\$1\" && ! grep -q WARN <<< \"\$1\"" _ "$out"

echo "== test_bridge: strict shell options =="
new_case
CHILD="$HALOW_TEST_TMP/strict_bridge.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_SYS_CLASS_NET_DIR="$SYS" PATH="$PATH" HALOW_FAKE_LOG="$HALOW_FAKE_LOG"
for lib in constants common ownership validate iface_detect bridge; do . "$HALOW_LIB_DIR/\$lib.sh"; done
sleep() { return 0; }
export HALOW_FAKE_FAIL="ip link add*"
if halow_bridge_create $BR; then echo first=0; else echo first=\$?; fi
unset HALOW_FAKE_FAIL
halow_bridge_create $BR
mkdir -p "$SYS/wlu1"
halow_bridge_port_add $BR wlu1
halow_bridge_port_isolate wlu1 on
if halow_bridge_port_isolate wlu1 bad; then echo bad=0; else echo bad=\$?; fi
halow_bridge_enforce_isolation $BR
if halow_bridge_enforce_isolation nobr0; then echo enf=0; else echo enf=\$?; fi
halow_bridge_delete $BR
echo CHILD_REACHED_THE_END
EOF
_out="$(bash "$CHILD" 2>&1)"; _rc=$?
assert_eq "0" "$_rc" "the bridge functions run under errexit/nounset/pipefail/inherit_errexit"
assert_success "...a refused create returns 1 without aborting the script" grep -q "first=1" <<< "$_out"
assert_success "...an invalid isolation mode returns 1 without aborting" grep -q "bad=1" <<< "$_out"
assert_success "...enforcement on a missing bridge returns 1 without aborting" grep -q "enf=1" <<< "$_out"
assert_success "...and the script reached its end" grep -q CHILD_REACHED_THE_END <<< "$_out"

halow_test_teardown
echo "test_bridge: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
