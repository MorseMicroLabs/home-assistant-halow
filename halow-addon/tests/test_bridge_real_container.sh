#!/usr/bin/env bash
# Runs the REAL bridge.sh / backend_bridge.sh functions against the REAL iproute2 (ip, bridge),
# in a throw-away container with its own network namespace (--network none, only CAP_NET_ADMIN
# added; never --network host, never --privileged), with dummy interfaces as bridge ports, so
# nothing of the host is touched. The fake-based coverage is tests/test_bridge.sh and
# tests/test_backend_bridge.sh; this one proves that the generated command lines are accepted
# by the real tools and that the security-relevant bridge port isolation flag is really set
# and cleared (read back with `bridge -d link show`).
#
# The ip and bridge commands the product runs go through logging wrappers (HALOW_IP and
# HALOW_BRIDGE_CMD, which the product honours) that record the exact command line and then
# exec the real tool, so the accepted command text is the product's own.
#
# When Docker or the image is not available it prints "SKIPPED: <reason>" and exits 77 (a
# skip, not a pass; see run_tests.sh). The image is the product image (name another with
# HALOW_TEST_BRIDGE_IMAGE). The libraries come from this tree (mounted read-only).
# Nothing is left behind: the container runs with --rm and its interfaces vanish with it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup >/dev/null 2>&1

echo "== test_bridge_real_container =="
IMAGE="${HALOW_TEST_BRIDGE_IMAGE:-morse-micro-halow-ap:local}"
LIBDIR="$(cd ../rootfs/usr/lib/halow && pwd)"

skip() {
    echo "SKIPPED: $1"
    halow_test_teardown
    echo "test_bridge_real_container: skipped (not run)"
    exit 77
}
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable"
docker image inspect "$IMAGE" >/dev/null 2>&1 || skip "the image $IMAGE is not present (build it, or set HALOW_TEST_BRIDGE_IMAGE)"
case "$LIBDIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && LIBDIR="/mnt$LIBDIR" ;; esac
[ -d "$LIBDIR" ] || skip "the library directory is not reachable for docker"
docker run --rm --network none --cap-add NET_ADMIN --entrypoint sh "$IMAGE" -c \
    'ip link add probe0 type bridge && ip link add probed0 type dummy && ip link set dev probed0 master probe0 && bridge link set dev probed0 isolated on' >/dev/null 2>&1 \
    || skip "the kernel cannot create a bridge with isolated ports from a container here (bridge module missing?)"

INNER="$HALOW_TEST_TMP/inner.sh"
cat > "$INNER" <<'EOS'
#!/usr/bin/env bash
set -u
export HALOW_STATE_DIR=/tmp/halow_state
mkdir -p "$HALOW_STATE_DIR"
for lib in constants common ownership validate bridge iface_detect backend_bridge; do . "/halowlib/$lib.sh"; done
CMDLOG=/tmp/cmds.log; : > "$CMDLOG"
mkdir -p /tmp/w
REALIP="$(command -v ip)"; REALBR="$(command -v bridge)"
printf '#!/bin/sh\necho "ip $*" >> %s\nexec %s "$@"\n' "$CMDLOG" "$REALIP" > /tmp/w/ip
printf '#!/bin/sh\necho "bridge $*" >> %s\nexec %s "$@"\n' "$CMDLOG" "$REALBR" > /tmp/w/bridge
chmod +x /tmp/w/ip /tmp/w/bridge
export HALOW_IP=/tmp/w/ip HALOW_BRIDGE_CMD=/tmp/w/bridge
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; fi; }
nchk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL $name"; else echo "PASS $name"; fi; }
iso() { "$REALBR" -d link show dev "$1" | grep -q -w "isolated $2"; }   # <port> <on|off>
BR=halow-br0
ip link add wlu1 type dummy && ip link add wlu1.sta1 type dummy && ip link add other0 type dummy || { echo "FAIL setup-interfaces"; exit 0; }
echo "INFO $("$REALIP" -V) / $("$REALBR" -V)"

chk  "bridge-create" halow_bridge_create "$BR"
chk  "bridge-is-a-bridge-device" ip -d link show "$BR"
chk  "bridge-pinned-mac" test "$(ip -o link show "$BR" | grep -o 'link/ether [0-9a-f:]*' | cut -d' ' -f2)" = "$(halow_bridge_mac "$BR")"
chk  "bridge-stp-off" test "$(cat /sys/class/net/$BR/bridge/stp_state)" = "0"
chk  "bridge-recreate-idempotent" halow_bridge_create "$BR"
nchk "unowned-interface-not-adopted" halow_bridge_create other0

chk  "port-add-parent" halow_bridge_port_add "$BR" wlu1
chk  "port-add-station" halow_bridge_port_add "$BR" wlu1.sta1
chk  "parent-master-is-bridge" test "$(halow_bridge_port_master wlu1)" = "$BR"
chk  "ports-listed" test "$(halow_bridge_ports "$BR" | sort | tr '\n' ' ')" = "wlu1 wlu1.sta1 "
chk  "port-add-idempotent" halow_bridge_port_add "$BR" wlu1
nchk "port-isolation-default-off-parent" iso wlu1 on
chk  "isolate-on-parent" halow_bridge_port_isolate wlu1 on
chk  "bridge-d-shows-isolated-on-parent" iso wlu1 on
chk  "sysfs-isolated-1-parent" test "$(cat /sys/class/net/wlu1/brport/isolated)" = "1"
nchk "station-not-isolated-yet" iso wlu1.sta1 on
chk  "enforce-isolation-isolates-the-rest" halow_bridge_enforce_isolation "$BR"
chk  "bridge-d-shows-isolated-on-station" iso wlu1.sta1 on
chk  "isolate-off-station" halow_bridge_port_isolate wlu1.sta1 off
chk  "bridge-d-shows-isolated-off-station" iso wlu1.sta1 off
chk  "parent-still-isolated" iso wlu1 on
chk  "enforce-isolation-restores-station" halow_bridge_enforce_isolation "$BR"
chk  "station-isolated-again" iso wlu1.sta1 on
nchk "isolate-refused-for-non-port" halow_bridge_port_isolate other0 on
nchk "isolate-bad-mode-refused" halow_bridge_port_isolate wlu1 maybe

# The gateway address: the backend's own add / has-cidr / remove, with its exact command text.
HALOW_BB_SUBNET=192.168.90.1/24
chk  "addr-add" _halow_bb_ip addr add "$HALOW_BB_SUBNET" dev "$BR"
chk  "has-cidr-sees-the-address" _halow_bb_has_cidr "$BR" "$HALOW_BB_SUBNET"
halow_own_mark net_bridge_addr "$BR"$'\n'"$HALOW_BB_SUBNET"
chk  "remove-address" _halow_bb_remove_address
nchk "address-gone" _halow_bb_has_cidr "$BR" "$HALOW_BB_SUBNET"
chk  "address-record-cleared" test ! -e "$HALOW_STATE_DIR/owns/net_bridge_addr"

chk  "port-remove-station" halow_bridge_port_remove wlu1.sta1
chk  "station-no-master" test -z "$(halow_bridge_port_master wlu1.sta1)"
chk  "port-remove-idempotent" halow_bridge_port_remove wlu1.sta1
chk  "removed-port-has-no-brport" test ! -e /sys/class/net/wlu1.sta1/brport
chk  "bridge-delete" halow_bridge_delete "$BR"
nchk "bridge-gone" ip link show "$BR"
chk  "bridge-record-cleared" test ! -e "$HALOW_STATE_DIR/owns/net_bridge"
chk  "former-port-still-exists" ip link show wlu1
chk  "bridge-delete-idempotent" halow_bridge_delete "$BR"
echo "---- commands the product ran (all accepted by the real tools unless a FAIL is listed above) ----"
sed 's/^/CMD /' "$CMDLOG" | sort -u
echo DONE
EOS

OUTF="$HALOW_TEST_TMP/container.out"
docker run --rm -i --network none --cap-add NET_ADMIN \
    -v "$LIBDIR:/halowlib:ro" --entrypoint bash "$IMAGE" -s < "$INNER" > "$OUTF" 2>&1
rc=$?
grep -E '^(INFO|CMD)' "$OUTF" | sed 's/^/    /'
assert_eq "0" "$rc" "the container ran to its end"
assert_success "the script reached its end" grep -qx DONE "$OUTF"
assert_eq "" "$(grep -E '^FAIL' "$OUTF" || true)" "no check failed inside the container"
n_pass="$(grep -c '^PASS' "$OUTF" || true)"
assert_success "the checks ran ($n_pass passed)" test "$n_pass" -ge 35
for name in bridge-create bridge-pinned-mac bridge-stp-off port-add-parent bridge-d-shows-isolated-on-parent \
            bridge-d-shows-isolated-off-station station-isolated-again addr-add remove-address port-remove-station bridge-delete; do
    assert_success "check ran and passed: $name" grep -qx "PASS $name" "$OUTF"
done
for form in 'ip link add halow-br0 type bridge' 'ip link set dev halow-br0 address 02:' 'ip link set dev halow-br0 type bridge stp_state 0' \
            'ip link set dev wlu1 master halow-br0' 'bridge link set dev wlu1 isolated on' 'bridge link set dev wlu1.sta1 isolated off' \
            'ip addr add 192.168.90.1/24 dev halow-br0' 'ip link set dev wlu1.sta1 nomaster' 'ip link del dev halow-br0'; do
    assert_success "the product generated: $form" grep -q -F -- "CMD $form" "$OUTF"
done
if grep -q '^FAIL' "$OUTF"; then echo "---- container output ----"; cat "$OUTF"; fi

halow_test_teardown
echo "test_bridge_real_container: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
