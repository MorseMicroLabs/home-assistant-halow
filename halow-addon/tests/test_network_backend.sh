#!/usr/bin/env bash
# Tests network_backend.sh: uplink auto-detection, scoped MASQUERADE, per-mutation
# ownership tracking (address/ip_forward/each iptables rule/dnsmasq, each independently
# restorable), foreign-pre-state preservation, dnsmasq process-identity checking,
# state persistence for the separate `finish` process, and idempotency — all via
# stubbed ip/iptables/sysctl/dnsmasq/ip_forward-accessor so no real root/network-
# namespace privilege is needed and the real test host's own settings cannot leak in.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_network_backend: uplink auto-detection =="
halow_test_setup

routes_one='default via 192.168.1.1 dev end0 proto dhcp metric 100'
result="$(halow_default_uplink_iface "$routes_one")"
assert_eq "end0" "$result" "the default-route interface is derived correctly (not hard-coded to eth0)"

# A literal empty string is deliberately NOT used here: halow_default_uplink_iface
# treats an empty override as "none given, fall back to the real `ip route` command"
# (the same convention iface_detect.sh's own functions use) — a single space is
# non-empty (so the override is honoured, not silently replaced by the real host's own
# route table) but still yields zero "default"/"dev" tokens, genuinely exercising the
# zero-routes path.
assert_failure "no default route fails closed (no guess)" \
    halow_default_uplink_iface " "

routes_conflicting='default via 192.168.1.1 dev end0 metric 100
default via 10.0.0.1 dev wlan1 metric 200'
assert_failure "multiple default routes on different interfaces fail closed (no guess)" \
    halow_default_uplink_iface "$routes_conflicting"

halow_test_teardown

# --- Shared dnsmasq identity-stub kit, used by every scenario below that fakes dnsmasq
# via a plain shell-function stub rather than invoking a real dnsmasq binary. ---
#
# This replaces an earlier, broken approach (globally stubbing the lower-level
# halow_process_comm/halow_process_cmdline_contains primitives to unconditionally
# report "this is dnsmasq, with a matching cmdline"). Those two primitives are also used
# by the REAL, full /proc scan inside halow_find_dnsmasq_by_identity — which this
# review's redesign now calls both as the mandatory PRE-START safety check and as the
# mandatory POST-KILL re-scan — so a blanket stub makes every single OTHER live process
# on the real test host appear to match too, turning an expected "confirmed absent" or
# "exactly one match" result into a host-process-count-dependent "ambiguous": a false-
# positive-prone test design this change's own adversarial pass must not repeat (the same
# defect class found and fixed in test_hostapd_config.sh's own outcome-matrix tests).
#
# Instead, the fake `dnsmasq` function records its own real, live pid (via $BASHPID, NOT
# $$ — bash keeps $$ as the ORIGINAL shell's pid even inside the subshell a backgrounded
# function call runs in, while $BASHPID reports the real, forked pid that becomes $! in
# the caller) into a tracker file. The two identity stubs below consult that tracker and
# answer "is this specific pid ours" / "is our own instance alive anywhere" dynamically,
# via a real `kill -0` check against that one real process — never a blanket claim.
halow_test_dnsmasq_pid_tracker() {
    printf '%s/dnsmasq_stub_pid\n' "$HALOW_TEST_TMP"
}

halow_test_install_dnsmasq_identity_stubs() {
    HALOW_TEST_DNSMASQ_TRACKER="$(halow_test_dnsmasq_pid_tracker)"
    rm -f -- "$HALOW_TEST_DNSMASQ_TRACKER"
    dnsmasq() {
        echo "dnsmasq $*" >> "${CALL_LOG:-/dev/null}"
        echo "$BASHPID" > "$HALOW_TEST_DNSMASQ_TRACKER"
        sleep 30
    }
    halow_dnsmasq_identity_matches() {
        local pid="$1" tracked=""
        [ -f "$HALOW_TEST_DNSMASQ_TRACKER" ] && tracked="$(cat "$HALOW_TEST_DNSMASQ_TRACKER" 2>/dev/null)"
        if [ -n "$tracked" ] && [ "$pid" = "$tracked" ]; then
            kill -0 "$pid" 2>/dev/null && return 0 || return 3
        fi
        return 1
    }
    halow_find_dnsmasq_by_identity() {
        local tracked=""
        [ -f "$HALOW_TEST_DNSMASQ_TRACKER" ] && tracked="$(cat "$HALOW_TEST_DNSMASQ_TRACKER" 2>/dev/null)"
        if [ -n "$tracked" ] && kill -0 "$tracked" 2>/dev/null; then
            printf '%s' "$tracked"
            return 0
        fi
        return 1
    }
}

halow_test_uninstall_dnsmasq_identity_stubs() {
    local tracked=""
    [ -n "${HALOW_TEST_DNSMASQ_TRACKER:-}" ] && [ -f "$HALOW_TEST_DNSMASQ_TRACKER" ] && tracked="$(cat "$HALOW_TEST_DNSMASQ_TRACKER" 2>/dev/null)"
    [ -n "$tracked" ] && { kill "$tracked" 2>/dev/null; wait "$tracked" 2>/dev/null; }
    unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity 2>/dev/null || true
    [ -n "${HALOW_TEST_DNSMASQ_TRACKER:-}" ] && rm -f -- "$HALOW_TEST_DNSMASQ_TRACKER"
}

echo "== test_network_backend: apply/teardown with stubbed commands =="
halow_test_setup

CALL_LOG="$HALOW_TEST_TMP/calls.log"
: > "$CALL_LOG"
STUB_ADDR_SET=0
STUB_NAT_RULE_SET=0
STUB_FWD_OUT_SET=0
STUB_FWD_IN_SET=0
STUB_IP_FORWARD=0

halow_read_ip_forward() { echo "$STUB_IP_FORWARD"; }

ip() {
    echo "ip $*" >> "$CALL_LOG"
    if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
        [ "$STUB_ADDR_SET" -eq 1 ] && echo "    inet 192.168.90.1/24 brd 192.168.90.255 scope global wlu1.sta1"
        return 0
    elif [ "$1" = "addr" ] && [ "$2" = "add" ]; then
        STUB_ADDR_SET=1; return 0
    elif [ "$1" = "addr" ] && [ "$2" = "del" ]; then
        STUB_ADDR_SET=0; return 0
    fi
    return 0
}
sysctl() {
    echo "sysctl $*" >> "$CALL_LOG"
    if [ "$1" = "-w" ] && [ "${2%%=*}" = "net.ipv4.ip_forward" ]; then
        STUB_IP_FORWARD="${2#*=}"
    fi
    return 0
}
iptables() {
    echo "iptables $*" >> "$CALL_LOG"
    if [ "$1" = "-t" ] && [ "$2" = "nat" ] && [ "$3" = "-C" ]; then
        [ "$STUB_NAT_RULE_SET" -eq 1 ] && return 0 || return 1
    elif [ "$1" = "-t" ] && [ "$2" = "nat" ] && [ "$3" = "-A" ]; then
        STUB_NAT_RULE_SET=1; return 0
    elif [ "$1" = "-t" ] && [ "$2" = "nat" ] && [ "$3" = "-D" ]; then
        STUB_NAT_RULE_SET=0; return 0
    elif [ "$1" = "-C" ] && [ "$4" = "wlu1.sta1" ]; then
        [ "$STUB_FWD_OUT_SET" -eq 1 ] && return 0 || return 1
    elif [ "$1" = "-A" ] && [ "$4" = "wlu1.sta1" ]; then
        STUB_FWD_OUT_SET=1; return 0
    elif [ "$1" = "-D" ] && [ "$4" = "wlu1.sta1" ]; then
        STUB_FWD_OUT_SET=0; return 0
    elif [ "$1" = "-C" ] && [ "$4" = "end0" ]; then
        [ "$STUB_FWD_IN_SET" -eq 1 ] && return 0 || return 1
    elif [ "$1" = "-A" ] && [ "$4" = "end0" ]; then
        STUB_FWD_IN_SET=1; return 0
    elif [ "$1" = "-D" ] && [ "$4" = "end0" ]; then
        STUB_FWD_IN_SET=0; return 0
    fi
    return 0
}
halow_test_install_dnsmasq_identity_stubs

halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0" \
    > "$HALOW_TEST_TMP/run1.log" 2>&1

assert_success "net_addr ownership recorded on first apply" halow_own_check "net_addr"
assert_success "net_ip_forward ownership recorded (it was 0, we changed it to 1)" halow_own_check "net_ip_forward"
assert_eq "0" "$(cat "$HALOW_STATE_DIR/orig_ip_forward")" "the original ip_forward value (0) was recorded before changing it"
assert_success "net_nat_rule ownership recorded on first apply" halow_own_check "net_nat_rule"
assert_success "net_fwd_rule_out ownership recorded on first apply" halow_own_check "net_fwd_rule_out"
assert_success "net_fwd_rule_in ownership recorded on first apply" halow_own_check "net_fwd_rule_in"
assert_success "net_dnsmasq ownership recorded on first apply" halow_own_check "net_dnsmasq"

nat_rule="$(grep -- '-t nat -A POSTROUTING' "$CALL_LOG" | head -n1)"
case "$nat_rule" in
    *"-s 192.168.90.1/24"*"-o end0"*) echo "  ok: MASQUERADE is scoped to the HaLow source subnet and the derived uplink" ;;
    *) echo "  FAIL: MASQUERADE rule not correctly scoped: $nat_rule"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)) ;;
esac
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))

first_pid_file="$HALOW_STATE_DIR/dnsmasq.pid"
first_pid="$(cat "$first_pid_file")"
first_tracked_pid="$(cat "$(halow_test_dnsmasq_pid_tracker)")"
assert_eq "$first_tracked_pid" "$first_pid" "the pid written to dnsmasq.pid is exactly the real, live backgrounded pid this test's own stub recorded"

assert_file_exists "$HALOW_STATE_DIR/network_values" "network values are persisted for the separate finish process"
(
  unset HALOW_NET_IFACE HALOW_NET_CIDR HALOW_NET_UPLINK
  halow_load_network_values
  assert_eq "wlu1.sta1" "$HALOW_NET_IFACE" "persisted iface value is correct"
  assert_eq "192.168.90.1/24" "$HALOW_NET_CIDR" "persisted cidr value is correct"
  assert_eq "end0" "$HALOW_NET_UPLINK" "persisted uplink value is correct (not hard-coded eth0)"
)

# --- Idempotent second apply: nothing is duplicated, ip_forward is not re-marked ---
halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0" \
    > "$HALOW_TEST_TMP/run2.log" 2>&1
nat_add_count="$(grep -c -- '-t nat -A POSTROUTING' "$CALL_LOG" || true)"
assert_eq "1" "$nat_add_count" "the NAT MASQUERADE rule is added only once across two applies"
dnsmasq_count="$(grep -c '^dnsmasq ' "$CALL_LOG" || true)"
assert_eq "1" "$dnsmasq_count" "dnsmasq is started only once across two applies"
second_pid="$(cat "$first_pid_file")"
assert_eq "$first_pid" "$second_pid" "the same dnsmasq pid is retained across the idempotent second apply"

# --- Full teardown: everything owned is removed and confirmed, ip_forward restored.
# Calls halow_teardown_dnsmasq then halow_teardown_network, in the same order
# halow_rollback itself now uses (dnsmasq's own teardown is unconditional and no
# longer part of halow_teardown_network — see network_backend.sh's own header on the
# split). ---
_test_full_teardown() {
    halow_teardown_dnsmasq && halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24"
}
assert_success "teardown succeeds" _test_full_teardown
for key in net_addr net_ip_forward net_nat_rule net_fwd_rule_out net_fwd_rule_in net_dnsmasq; do
    assert_failure "ownership cleared for $key after successful teardown" halow_own_check "$key"
done
assert_eq "0" "$STUB_IP_FORWARD" "ip_forward was restored to its original value (0)"
assert_file_absent "$first_pid_file" "dnsmasq pid file removed after teardown"
assert_failure "the real backgrounded dnsmasq-stub process is confirmed stopped after teardown" \
    bash -c "kill -0 '$first_tracked_pid' 2>/dev/null"
assert_success "a second teardown call is a safe no-op" _test_full_teardown
unset -f _test_full_teardown

halow_test_uninstall_dnsmasq_identity_stubs
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: halow_start_dnsmasq establishes lifecycle ownership BEFORE creating dnsmasq.conf, the pid file, or the process =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"

# halow_own_mark is overridden to record, the FIRST time it is called for "net_dnsmasq",
# whether dnsmasq.conf already existed at that exact moment — proving the ownership
# marker really is written before the config file, not merely that both end up present
# afterward (which an out-of-order implementation that happens to also finish quickly
# could otherwise still appear to satisfy).
eval "$(declare -f halow_own_mark | sed '1s/halow_own_mark/_real_own_mark_for_order_test/')"
CONF_EXISTED_AT_MARK_TIME="unset"
halow_own_mark() {
    if [ "$1" = "net_dnsmasq" ] && [ "$CONF_EXISTED_AT_MARK_TIME" = "unset" ]; then
        if [ -e "$conf" ]; then CONF_EXISTED_AT_MARK_TIME="yes"; else CONF_EXISTED_AT_MARK_TIME="no"; fi
    fi
    _real_own_mark_for_order_test "$@"
}
halow_test_install_dnsmasq_identity_stubs
halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150" >"$HALOW_TEST_TMP/order.log" 2>&1
assert_eq "no" "$CONF_EXISTED_AT_MARK_TIME" "net_dnsmasq ownership is recorded strictly BEFORE dnsmasq.conf is created"
halow_test_uninstall_dnsmasq_identity_stubs
unset -f halow_own_mark _real_own_mark_for_order_test 2>/dev/null || true
halow_own_clear "net_dnsmasq" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"
halow_test_teardown

echo "== test_network_backend: halow_start_dnsmasq — genuine partial-start: config is written, but the launched process exits immediately; the caller's own rollback fully recovers =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
ip() { return 0; }
sysctl() { return 0; }
iptables() { [ "$3" = "-C" ] && return 1; return 0; }
halow_test_install_dnsmasq_identity_stubs
dnsmasq() { echo "dnsmasq $*" >>"${CALL_LOG:-/dev/null}"; exit 1; }

assert_failure "halow_start_dnsmasq reports failure when the launched process exits immediately" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_success "lifecycle ownership was already recorded before the config was even written (established ahead of any mutation)" \
    halow_own_check "net_dnsmasq"
assert_file_exists "$conf" "the config WAS written (the failure happens after that point) -- an orphan the caller's own rollback must still find"
assert_file_absent "$pidfile" "no pid file was ever written, since the process never stayed alive"

halow_teardown_dnsmasq >"$HALOW_TEST_TMP/recover_launch_fail.log" 2>&1
assert_failure "the caller's own rollback (teardown), using the identity-scan fallback (no pid file existed), fully recovers from this orphaned config" \
    halow_own_check "net_dnsmasq"
assert_file_absent "$conf" "the orphaned config is removed by the caller's own rollback"

unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity ip sysctl iptables 2>/dev/null || true
rm -f -- "$conf" "$pidfile"
halow_test_teardown

echo "== test_network_backend: halow_start_dnsmasq — genuine partial-start: process launches but its own pid file cannot be written; a live, untracked-by-file orphan is still found and stopped by rollback's scan fallback =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
mkdir -p "$pidfile"   # the pid file's own path is occupied by a directory, so `echo ... > "$pidfile"` fails
ip() { return 0; }
sysctl() { return 0; }
iptables() { [ "$3" = "-C" ] && return 1; return 0; }
halow_test_install_dnsmasq_identity_stubs

assert_failure "halow_start_dnsmasq reports failure when its own pid file cannot be written" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
tracked_pid="$(cat "$(halow_test_dnsmasq_pid_tracker)" 2>/dev/null)"
assert_success "the dnsmasq process launched successfully and is genuinely alive, even though its own pid file write failed (a live, untracked-by-file orphan)" \
    bash -c "kill -0 '$tracked_pid' 2>/dev/null"
assert_success "lifecycle ownership remains recorded, so the caller's own rollback can find this orphan" halow_own_check "net_dnsmasq"

rmdir "$pidfile" 2>/dev/null || true   # restore the pid-file path to a normal, non-existent state for the recovery pass below
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/recover_pidfile_fail.log" 2>&1
assert_failure "the live orphaned process is found via the identity-scan fallback (no valid pid file ever existed) and ownership is fully cleared" \
    halow_own_check "net_dnsmasq"
assert_failure "the orphaned dnsmasq process is confirmed stopped by the recovery teardown" \
    bash -c "kill -0 '$tracked_pid' 2>/dev/null"

unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity ip sysctl iptables 2>/dev/null || true
rm -rf -- "$conf" "$pidfile"
halow_test_teardown

echo "== test_network_backend: halow_start_dnsmasq refuses to start unless the prior state is POSITIVELY confirmed absent ('not confirmed running' is never permission to start another instance) =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"

# --- Clean state (no pid file, scan finds nothing): allowed, and ownership is marked. ---
halow_test_install_dnsmasq_identity_stubs
assert_success "a clean prior state (confirmed absent) is allowed to start" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_success "ownership is marked for the newly started instance" halow_own_check "net_dnsmasq"
halow_test_uninstall_dnsmasq_identity_stubs
halow_own_clear "net_dnsmasq" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- An existing, positively matching, live instance: refused (idempotent no-op,
# ownership was already marked by that existing instance, left untouched). This is
# Part 3 item 1: matching live dnsmasq PLUS existing net_dnsmasq ownership -> success. ---
printf 'SENTINEL pre-existing conf content\n' > "$conf"
( sleep 30 ) & existing_pid=$!
echo "$existing_pid" > "$pidfile"
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { [ "$1" = "$existing_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
assert_success "a second start call against an already-owned, positively-matching instance (found directly via the pid file) is a safe idempotent no-op" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_success "the existing process remains untouched (item 5)" kill -0 "$existing_pid"
assert_eq "SENTINEL pre-existing conf content" "$(cat "$conf")" "the existing instance's own config is not overwritten (item 8)"
assert_eq "$existing_pid" "$(cat "$pidfile")" "the existing instance's own pid file is not overwritten (item 8)"
unset -f halow_dnsmasq_identity_matches
kill "$existing_pid" 2>/dev/null; wait "$existing_pid" 2>/dev/null || true
halow_own_clear "net_dnsmasq"
rm -f -- "$conf" "$pidfile"

# --- Part 3 item 1, the secondary-scan path: a DEAD recorded pid whose mandatory
# secondary scan finds this package's own real instance alive elsewhere, with
# net_dnsmasq ownership ALREADY correctly held (e.g. the marker survived even though the
# pid file itself went stale) -- still a safe, idempotent no-op; the rule from Part 2
# applies identically whether the match was found directly or via the scan. ---
printf 'SENTINEL pre-existing conf content (scan path)\n' > "$conf"
echo "999999" > "$pidfile"
( sleep 30 ) & scan_owned_live_pid=$!
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { [ "$1" = "999999" ] && return 3; [ "$1" = "$scan_owned_live_pid" ] && return 0; return 1; }
halow_find_dnsmasq_by_identity() { printf '%s' "$scan_owned_live_pid"; return 0; }
assert_success "a dead recorded pid whose own mandatory secondary scan finds a real instance alive elsewhere, with ownership already held, is a safe idempotent no-op" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_success "the existing process remains untouched (item 5)" kill -0 "$scan_owned_live_pid"
assert_eq "SENTINEL pre-existing conf content (scan path)" "$(cat "$conf")" "the existing instance's own config is not overwritten (item 8)"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$scan_owned_live_pid" 2>/dev/null; wait "$scan_owned_live_pid" 2>/dev/null || true
halow_own_clear "net_dnsmasq"
rm -f -- "$conf" "$pidfile"

# --- Part 3 item 2: a matching live dnsmasq found DIRECTLY via the recorded pid file,
# but net_dnsmasq ownership is ABSENT -- this is the exact known defect this round fixes.
# An earlier version of halow_start_dnsmasq treated ANY `owned` outcome as a safe,
# idempotent no-op regardless of whether this package's own ownership marker actually
# existed -- letting startup proceed using a process rollback has no ownership-marker-
# driven reason to ever discover, stop, or track. Fixed: `owned` without ownership now
# fails closed, never adopts/signals the process, never creates a fresh marker for it,
# and never touches its files. ---
printf 'SENTINEL pre-existing conf content (unowned direct match)\n' > "$conf"
( sleep 30 ) & direct_unowned_pid=$!
echo "$direct_unowned_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$direct_unowned_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
assert_failure "a matching live dnsmasq found directly via the pid file, with NO net_dnsmasq ownership held, fails closed (the known defect this round fixes)" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is adopted for the unowned process (item 7)" halow_own_check "net_dnsmasq"
assert_success "the unowned existing process remains untouched -- never signalled (item 5)" kill -0 "$direct_unowned_pid"
assert_eq "SENTINEL pre-existing conf content (unowned direct match)" "$(cat "$conf")" "the unowned existing instance's own config is not overwritten (item 8)"
assert_eq "$direct_unowned_pid" "$(cat "$pidfile")" "the unowned existing instance's own pid file is not overwritten (item 8)"
unset -f halow_dnsmasq_identity_matches
kill "$direct_unowned_pid" 2>/dev/null; wait "$direct_unowned_pid" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- Part 3 item 4 (mismatch variant): a recorded pid that is a definite MISMATCH (an
# unrelated, real process reusing that pid), whose own mandatory secondary scan finds
# this package's own real instance alive elsewhere, with NO net_dnsmasq ownership held
# for it either -- fails closed, exactly like the direct-match case above; the unrelated
# process at the mismatching pid is also never touched. ---
printf 'SENTINEL pre-existing conf content (unowned mismatch-then-scan match)\n' > "$conf"
( sleep 30 ) & mismatch_unrelated_pid=$!
( sleep 30 ) & mismatch_scan_found_pid=$!
echo "$mismatch_unrelated_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$mismatch_unrelated_pid" ] && return 1; [ "$1" = "$mismatch_scan_found_pid" ] && return 0; return 1; }
halow_find_dnsmasq_by_identity() { printf '%s' "$mismatch_scan_found_pid"; return 0; }
assert_failure "a mismatching recorded pid whose own secondary scan finds a real match elsewhere, with NO ownership held, fails closed" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is adopted for the unowned process (item 7)" halow_own_check "net_dnsmasq"
assert_success "the unrelated process at the mismatching recorded pid remains untouched (item 5)" kill -0 "$mismatch_unrelated_pid"
assert_success "the unowned process the scan found remains untouched (item 5)" kill -0 "$mismatch_scan_found_pid"
assert_eq "SENTINEL pre-existing conf content (unowned mismatch-then-scan match)" "$(cat "$conf")" "the config is not overwritten (item 8)"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$mismatch_unrelated_pid" "$mismatch_scan_found_pid" 2>/dev/null
wait "$mismatch_unrelated_pid" "$mismatch_scan_found_pid" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- Part 3 item 4 (missing-pidfile variant): no pid file at all, but the mandatory scan
# finds a real, live, identity-matching process, with NO net_dnsmasq ownership held for
# it -- fails closed, same as every other unowned-match case above. ---
printf 'SENTINEL pre-existing conf content (unowned missing-pidfile match)\n' > "$conf"
rm -f -- "$pidfile"
( sleep 30 ) & missing_pidfile_found_pid=$!
halow_find_dnsmasq_by_identity() { printf '%s' "$missing_pidfile_found_pid"; return 0; }
assert_failure "a missing pid file whose own scan finds a real match, with NO ownership held, fails closed" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is adopted for the unowned process (item 7)" halow_own_check "net_dnsmasq"
assert_success "the unowned process the scan found remains untouched (item 5)" kill -0 "$missing_pidfile_found_pid"
assert_eq "SENTINEL pre-existing conf content (unowned missing-pidfile match)" "$(cat "$conf")" "the config is not overwritten (item 8)"
assert_file_absent "$pidfile" "no pid file is created for the unowned process (item 6/8 -- no duplicate, nothing written)"
unset -f halow_find_dnsmasq_by_identity
kill "$missing_pidfile_found_pid" 2>/dev/null; wait "$missing_pidfile_found_pid" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- An existing live PID whose identity cannot be positively confirmed (unreadable
# cmdline): BLOCKS starting a replacement -- never treated as "not running". ---
( sleep 30 ) & unknown_pid=$!
echo "$unknown_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$unknown_pid" ] && return 2; return 1; }
assert_failure "an existing pid with an unreadable/unknown identity blocks starting a replacement" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is marked when the start is refused on an unknown prior identity" halow_own_check "net_dnsmasq"
unset -f halow_dnsmasq_identity_matches
kill "$unknown_pid" 2>/dev/null; wait "$unknown_pid" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- Missing/malformed pid file, but the identity scan itself is ambiguous (more than
# one live candidate): BLOCKS starting -- never guesses. ---
halow_find_dnsmasq_by_identity() { return 2; }
assert_failure "a missing pid file plus an ambiguous identity scan blocks starting a new instance" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is marked when the start is refused on an ambiguous scan" halow_own_check "net_dnsmasq"
unset -f halow_find_dnsmasq_by_identity
rm -f -- "$conf" "$pidfile"

# --- Part 3 item 3: a recorded pid that is DEAD, whose own mandatory secondary scan
# finds this package's own dnsmasq genuinely alive elsewhere under a different pid, with
# NO net_dnsmasq ownership held for it -- fails closed, exactly like the direct-match and
# mismatch variants above. A dead recorded pid must never, by itself, be read as
# "confirmed absent" permission to start another instance when the scan it is now
# required to trigger finds a real, live, UNOWNED one instead. ---
dnsmasq_call_count_before="$(grep -c '^dnsmasq ' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
printf 'SENTINEL pre-existing conf content (unowned dead-pid-then-scan match)\n' > "$conf"
echo "999999" > "$pidfile"   # never alive -- identity_matches always resolves this to 3 (dead)
( sleep 30 ) & dead_case_live_pid=$!
halow_dnsmasq_identity_matches() { [ "$1" = "999999" ] && return 3; [ "$1" = "$dead_case_live_pid" ] && return 0; return 1; }
halow_find_dnsmasq_by_identity() { printf '%s' "$dead_case_live_pid"; return 0; }
assert_failure "a dead recorded pid whose own mandatory secondary scan finds a real instance alive elsewhere, with NO ownership held, fails closed (the known defect this round fixes)" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is adopted for the unowned process (item 7)" halow_own_check "net_dnsmasq"
assert_success "the unowned existing process remains untouched -- never signalled (item 5)" kill -0 "$dead_case_live_pid"
assert_eq "SENTINEL pre-existing conf content (unowned dead-pid-then-scan match)" "$(cat "$conf")" "the config is not overwritten (item 8)"
dnsmasq_call_count_after="$(grep -c '^dnsmasq ' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
assert_eq "${dnsmasq_call_count_before:-0}" "${dnsmasq_call_count_after:-0}" "no duplicate dnsmasq process is actually launched (item 6)"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$dead_case_live_pid" 2>/dev/null; wait "$dead_case_live_pid" 2>/dev/null || true
rm -f -- "$conf" "$pidfile"

# --- A recorded pid that is DEAD, but the mandatory secondary scan is itself UNKNOWN (an
# unreadable same-name candidate found): BLOCK starting -- "not positively confirmed
# running" is never itself permission to start another, even when the one thing that IS
# known is that the originally recorded pid specifically is dead. ---
echo "999999" > "$pidfile"
halow_dnsmasq_identity_matches() { return 3; }
halow_find_dnsmasq_by_identity() { return 3; }
assert_failure "a dead recorded pid whose own mandatory secondary scan is itself unknown/unsafe blocks starting a second instance" \
    halow_start_dnsmasq "wlu1.sta1" "192.168.90.1" "192.168.90.50" "192.168.90.150"
assert_failure "no ownership is marked when the start is refused" halow_own_check "net_dnsmasq"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
rm -f -- "$conf" "$pidfile"

halow_test_teardown

echo "== test_network_backend: foreign pre-existing state is never claimed or removed =="
halow_test_setup
CALL_LOG="$HALOW_TEST_TMP/calls2.log"
: > "$CALL_LOG"
STUB_IP_FORWARD=1   # already enabled before this package ever runs
halow_read_ip_forward() { echo "$STUB_IP_FORWARD"; }
ip() {
    echo "ip $*" >> "$CALL_LOG"
    if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
        echo "    inet 192.168.90.1/24 brd 192.168.90.255 scope global wlu1.sta1"
        return 0
    fi
    return 0
}
sysctl() { echo "sysctl $*" >> "$CALL_LOG"; return 0; }
iptables() { echo "iptables $*" >> "$CALL_LOG"; [ "$3" = "-C" ] && return 0; return 0; }
halow_test_install_dnsmasq_identity_stubs

halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0" \
    > "$HALOW_TEST_TMP/run_foreign.log" 2>&1

assert_failure "a pre-existing address is never claimed as package-owned" halow_own_check "net_addr"
assert_failure "pre-existing ip_forward=1 is never claimed as package-changed" halow_own_check "net_ip_forward"
assert_failure "a pre-existing NAT rule is never claimed as package-owned" halow_own_check "net_nat_rule"
assert_failure "a pre-existing outbound FORWARD rule is never claimed as package-owned" halow_own_check "net_fwd_rule_out"
assert_failure "a pre-existing inbound FORWARD rule is never claimed as package-owned" halow_own_check "net_fwd_rule_in"

halow_teardown_dnsmasq >/dev/null 2>&1
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
addr_del_count="$(grep -c '^ip addr del' "$CALL_LOG" || true)"
assert_eq "0" "$addr_del_count" "teardown never attempts to remove an address this package did not add"
nat_del_count="$(grep -c -- '-t nat -D POSTROUTING' "$CALL_LOG" || true)"
assert_eq "0" "$nat_del_count" "teardown never attempts to remove a NAT rule this package did not add"
forward_restore_count="$(grep -c 'net.ipv4.ip_forward=' "$CALL_LOG" || true)"
assert_eq "0" "$forward_restore_count" "teardown never touches ip_forward it did not itself change"

halow_test_uninstall_dnsmasq_identity_stubs
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: failure injection at each stage leaves correct partial ownership =="
halow_test_setup
halow_read_ip_forward() { echo "0"; }
ip() { [ "$1" = "addr" ] && [ "$2" = "add" ] && return 1; return 0; }
sysctl() { return 0; }
iptables() { return 0; }
assert_failure "apply fails closed when the address cannot be added" \
    halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
assert_failure "no address ownership is recorded after a failed ip addr add" halow_own_check "net_addr"
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

halow_test_setup
halow_read_ip_forward() { echo "0"; }
ip() { return 0; }
sysctl() { return 0; }
STUB2_NAT=0
iptables() {
    if [ "$1" = "-t" ] && [ "$3" = "-C" ]; then [ "$STUB2_NAT" -eq 1 ] && return 0 || return 1; fi
    if [ "$1" = "-t" ] && [ "$3" = "-A" ]; then return 1; fi  # NAT rule add fails
    return 0
}
assert_failure "apply fails closed when the MASQUERADE rule cannot be added" \
    halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
assert_success "the address mutation that DID succeed is still correctly tracked for later rollback" \
    halow_own_check "net_addr"
assert_success "the ip_forward mutation that DID succeed is still correctly tracked for later rollback" \
    halow_own_check "net_ip_forward"
assert_failure "no NAT-rule ownership is recorded after a failed add" halow_own_check "net_nat_rule"
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: an unreadable current ip_forward value fails closed BEFORE any mutation (never creates an unrestorable residual) =="
halow_test_setup
halow_read_ip_forward() { echo ""; }
ip() { return 0; }
sysctl_called=0
sysctl() { sysctl_called=1; return 0; }
iptables() { return 0; }
assert_failure "apply fails closed when the current ip_forward value cannot be read at all" \
    halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
assert_eq "0" "$sysctl_called" "ip_forward is never touched when its own current value could not first be read (no unrestorable change is ever made)"
assert_failure "no net_ip_forward ownership is recorded" halow_own_check "net_ip_forward"
assert_file_absent "$HALOW_STATE_DIR/orig_ip_forward" "no empty/unusable original-value file is ever written"
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: dnsmasq identity check — real processes, real /proc/pid/comm and /proc/pid/cmdline, no stubbing =="
# Earlier scenarios in this file define `dnsmasq`, `halow_dnsmasq_identity_matches`, and
# `halow_find_dnsmasq_by_identity` as shell functions via the stub kit above — bash
# resolves a function before a PATH binary of the same name, and halow_test_setup only
# re-sources the real library definitions, it does not touch a test-only `dnsmasq()`
# shell function at all — so without explicitly unsetting all of these here, `dnsmasq
# --port=0 ...` below would silently call the leftover STUB, never the real binary.
unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity halow_process_comm halow_process_cmdline_contains 2>/dev/null || true
halow_test_setup
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
conf="$HALOW_STATE_DIR/dnsmasq.conf"
mkdir -p "$HALOW_STATE_DIR"
: > "$conf"

( sleep 30 ) &
not_dnsmasq_pid=$!
echo "$not_dnsmasq_pid" > "$pidfile"
assert_failure "a live PID that is not actually dnsmasq is not mistaken for a running instance" \
    halow_dnsmasq_is_running "$pidfile"
kill "$not_dnsmasq_pid" 2>/dev/null || true

if command -v dnsmasq >/dev/null 2>&1; then
    # Idle, harmless invocation: port=0 disables DNS, no dhcp-range means no DHCP
    # either — this process does nothing but prove the real binary's own comm AND
    # cmdline read as this package's own exact dnsmasq instance would, which no shell-
    # function or shebang-script stub can genuinely fake (confirmed empirically while
    # developing this test: both `exec -a dnsmasq ...` and a shebang script literally
    # named `dnsmasq` still report the real underlying interpreter/binary's own name in
    # /proc/pid/comm, not the invoked name — only a directly-exec'd binary of that exact
    # name does). Uses the SAME `--conf-file` path production code always uses
    # (`${HALOW_STATE_DIR}/dnsmasq.conf`) — not an arbitrary path like `/dev/null` — since
    # halow_dnsmasq_identity_matches now also requires the real cmdline to carry this
    # package's own exact `--conf-file=` argument, not comm alone.
    dnsmasq --port=0 --conf-file="$conf" --no-daemon --pid-file="$pidfile" &
    real_pid=$!
    # Real dnsmasq, run with --no-daemon, does not actually write its own --pid-file
    # (confirmed empirically while developing this test) — exactly why the production
    # code in network_backend.sh never relies on dnsmasq to write it either, and
    # instead writes $! into the pidfile itself immediately after backgrounding. This
    # test replicates that same real behaviour rather than assuming dnsmasq's own
    # --pid-file option does the job.
    echo "$real_pid" > "$pidfile"
    sleep 0.5
    assert_success "the real dnsmasq binary, invoked with this package's own exact --conf-file argument, is correctly identified as running" \
        halow_dnsmasq_is_running "$pidfile"
    assert_failure "the same real dnsmasq binary is NOT identified as this package's own instance under a different --conf-file path (cmdline identity, not comm alone, is what distinguishes it)" \
        halow_dnsmasq_identity_matches "$real_pid" "/some/other/dnsmasq.conf"
    kill "$real_pid" 2>/dev/null || true
    wait "$real_pid" 2>/dev/null || true
else
    echo "  (skipped: no real dnsmasq binary on PATH in this environment — the negative cases above, which do not need one, still ran)"
fi

halow_test_teardown

echo "== test_network_backend: halow_find_dnsmasq_by_identity — an unreadable candidate always wins over a positive match found elsewhere (the real scan function, two real processes, no black-box stubbing of the scan itself) =="
unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity halow_process_comm halow_process_cmdline_contains 2>/dev/null || true
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
mkdir -p "$HALOW_STATE_DIR"
: > "$conf"
( sleep 30 ) & match_pid=$!
( sleep 30 ) & unreadable_pid=$!
# Only the lowest-level comm/cmdline primitives are stubbed here, and PER-PID (not
# globally) — every other real pid on the host still goes through this same stub and is
# correctly reported as a non-match, so the real halow_find_dnsmasq_by_identity scan
# function itself (completely unstubbed) is what is actually under test.
halow_process_comm() {
    case "$1" in
        "$match_pid"|"$unreadable_pid") echo "dnsmasq" ;;
        *) echo "other" ;;
    esac
}
halow_process_cmdline_contains() {
    case "$1" in
        "$match_pid") return 0 ;;        # genuinely matches this package's own conf argument
        "$unreadable_pid") return 2 ;;   # cmdline could not be read
        *) return 1 ;;
    esac
}
halow_find_dnsmasq_by_identity "$conf"
scan_status=$?
assert_eq "3" "$scan_status" "an unreadable candidate's cmdline makes the WHOLE scan result UNKNOWN, even though a different, real candidate elsewhere positively matched"
unset -f halow_process_comm halow_process_cmdline_contains
kill "$match_pid" "$unreadable_pid" 2>/dev/null; wait "$match_pid" "$unreadable_pid" 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: halow_dnsmasq_determine_outcome — a definite MISMATCH against the recorded pid file always falls through to a mandatory secondary scan, resolving both ways, never touching the unrelated process =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
: > "$conf"

# --- Mismatch, secondary scan confirms absence: resolves to confirmed_absent; the
# unrelated process at the stale recorded pid is never touched or examined further. ---
( sleep 30 ) & unrelated_pid=$!
echo "$unrelated_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$unrelated_pid" ] && return 1; return 1; }
halow_find_dnsmasq_by_identity() { return 1; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "confirmed_absent" "$HALOW_DNSMASQ_OUTCOME" "a mismatch whose secondary scan finds nothing resolves to confirmed_absent"
assert_success "the unrelated process at the stale recorded pid was never touched by determine_outcome itself" kill -0 "$unrelated_pid"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$unrelated_pid" 2>/dev/null; wait "$unrelated_pid" 2>/dev/null || true
rm -f -- "$pidfile"

# --- Mismatch, secondary scan finds this package's own real instance under a DIFFERENT
# pid: resolves to owned, with the SCAN's pid as the target — the original unrelated
# process at the stale recorded pid remains untouched. ---
( sleep 30 ) & unrelated_pid2=$!
( sleep 30 ) & real_instance_pid=$!
echo "$unrelated_pid2" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$unrelated_pid2" ] && return 1; return 1; }
halow_find_dnsmasq_by_identity() { printf '%s' "$real_instance_pid"; return 0; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "owned" "$HALOW_DNSMASQ_OUTCOME" "a mismatch whose secondary scan finds a real instance elsewhere resolves to owned"
assert_eq "$real_instance_pid" "$HALOW_DNSMASQ_TARGET_PID" "the target pid is the one the secondary scan found, not the stale recorded one"
assert_success "the original unrelated process at the stale recorded pid remains untouched" kill -0 "$unrelated_pid2"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$unrelated_pid2" "$real_instance_pid" 2>/dev/null; wait "$unrelated_pid2" "$real_instance_pid" 2>/dev/null || true
rm -f -- "$pidfile"

# --- Mismatch, secondary scan is itself ambiguous: resolves to ambiguous, not mismatch. ---
( sleep 30 ) & unrelated_pid3=$!
echo "$unrelated_pid3" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$unrelated_pid3" ] && return 1; return 1; }
halow_find_dnsmasq_by_identity() { return 2; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "ambiguous" "$HALOW_DNSMASQ_OUTCOME" "a mismatch whose secondary scan is itself ambiguous resolves to ambiguous, never silently dropped"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$unrelated_pid3" 2>/dev/null; wait "$unrelated_pid3" 2>/dev/null || true
rm -f -- "$pidfile" "$conf"

# --- A recorded pid that is DEAD (identity result 3) -- this alone proves only that THAT
# pid is gone, never that no instance of this package's own process is running elsewhere
# under a different pid. Fixed during development: an earlier version treated this as an
# immediate, terminal confirmed_absent, skipping the mandatory secondary scan entirely --
# exactly the same unresolvable-absence gap the mismatch case (above) already closes. A
# dead pid now falls through to the SAME mandatory secondary scan, resolved the SAME four
# ways. halow_dnsmasq_identity_matches is explicitly stubbed for a fixed sentinel pid
# (never relying on whatever real-or-deleted state a PRIOR scenario in this section left
# that shared function in -- the mismatch scenarios above each `unset -f` it when done,
# which deletes it for the rest of this setup/teardown pair, not "restores" it); only
# halow_find_dnsmasq_by_identity (the secondary scan itself) then varies per case below,
# to deterministically control its own result. ---
: > "$conf"
dead_pid="999999"   # never alive -- identity_matches always resolves this to 3 (dead)
echo "$dead_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$dead_pid" ] && return 3; return 1; }

# Case 1: the secondary scan finds nothing -- confirmed_absent.
halow_find_dnsmasq_by_identity() { return 1; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "confirmed_absent" "$HALOW_DNSMASQ_OUTCOME" "a dead recorded pid whose secondary scan finds nothing resolves to confirmed_absent"

# Case 2: the secondary scan finds this package's own REAL instance alive under a
# DIFFERENT pid -- owned, with the scan's own pid as the target (never the dead one).
( sleep 30 ) & dead_case_real_pid=$!
halow_find_dnsmasq_by_identity() { printf '%s' "$dead_case_real_pid"; return 0; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "owned" "$HALOW_DNSMASQ_OUTCOME" "a dead recorded pid whose secondary scan finds a real instance elsewhere resolves to owned"
assert_eq "$dead_case_real_pid" "$HALOW_DNSMASQ_TARGET_PID" "the target pid is the one the secondary scan found, never the dead recorded pid"
kill "$dead_case_real_pid" 2>/dev/null; wait "$dead_case_real_pid" 2>/dev/null || true

# Case 3: the secondary scan finds more than one candidate -- ambiguous.
halow_find_dnsmasq_by_identity() { return 2; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "ambiguous" "$HALOW_DNSMASQ_OUTCOME" "a dead recorded pid whose secondary scan is ambiguous resolves to ambiguous, never guessed at"

# Case 4: the secondary scan itself encounters an unreadable same-name candidate --
# unknown, never conflated with "zero matches, confirmed absent".
halow_find_dnsmasq_by_identity() { return 3; }
halow_dnsmasq_determine_outcome "$conf"
assert_eq "unknown" "$HALOW_DNSMASQ_OUTCOME" "a dead recorded pid whose secondary scan encounters an unreadable candidate resolves to unknown, never confirmed_absent"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
rm -f -- "$pidfile" "$conf"

halow_test_teardown

echo "== test_network_backend: halow_teardown_dnsmasq never signals a mismatched/unrelated process (real processes, no stubbing) =="
unset -f dnsmasq halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity halow_process_comm halow_process_cmdline_contains 2>/dev/null || true
halow_test_setup
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
conf="$HALOW_STATE_DIR/dnsmasq.conf"
mkdir -p "$HALOW_STATE_DIR"

# --- A stale PID reused by an unrelated, still-alive process. The unrelated process must
# NEVER be signalled. Under this change's corrected design, halow_dnsmasq_determine_
# outcome's own mandatory secondary scan runs (here, genuinely, against the real /proc
# tree with no stubbing) and — finding no real dnsmasq matching this package's own exact
# conf path anywhere — correctly resolves this as confirmed_absent: the stale pid-file
# REFERENCE is safely cleaned up, while the unrelated process itself is left completely
# untouched. (An earlier draft of this test asserted the opposite — that ownership stays
# kept forever on any mismatch — which was correct for the OLD design but is exactly the
# unresolvable-mismatch gap item 4 of this change requires to be closed via the mandatory
# secondary scan.) ---
: > "$conf"
halow_own_mark "net_dnsmasq"
( sleep 30 ) &
unrelated_pid=$!
echo "$unrelated_pid" > "$pidfile"
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_mismatch.log" 2>&1
assert_success "the unrelated process is still alive after teardown (confirms it was never signalled)" \
    kill -0 "$unrelated_pid"
assert_failure "ownership is cleared once the mandatory secondary scan positively confirms this package's own instance is genuinely absent elsewhere" \
    halow_own_check "net_dnsmasq"
assert_file_absent "$pidfile" "the stale pid-file reference is removed once the secondary scan confirms this package's own absence"
assert_file_absent "$conf" "the orphaned config is removed once the secondary scan confirms this package's own absence"
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true

# --- A pid file naming a pid that is simply no longer alive at all: this alone proves
# only that THAT pid is gone, never that no instance of this package's own dnsmasq is
# running elsewhere under a different pid -- the dead recorded pid falls through to the
# SAME mandatory secondary scan a mismatch does (fixed during development: an earlier version
# treated a dead recorded pid as immediate, terminal confirmed_absent). Genuinely uses the
# REAL, completely unstubbed scan (no identity function is stubbed anywhere in this
# section), which genuinely finds nothing on this real test host, before ownership is
# cleared and the stale file removed. ---
: > "$conf"
halow_own_mark "net_dnsmasq"
( sleep 0.1 ) &
short_lived_pid=$!
wait "$short_lived_pid" 2>/dev/null || true
echo "$short_lived_pid" > "$pidfile"
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_dead.log" 2>&1
assert_failure "ownership is cleared when the recorded pid is confirmed dead AND the mandatory secondary scan independently confirms absence" \
    halow_own_check "net_dnsmasq"
assert_file_absent "$pidfile" "the pid file is removed once the dead recorded pid's own mandatory secondary scan confirms absence"

# --- Successful, verified cleanup of a genuinely owned dnsmasq (real binary, if present).
# The mandatory post-kill FRESH, COMPLETE scan must also independently confirm absence —
# here, genuinely, against the real /proc tree. ---
if command -v dnsmasq >/dev/null 2>&1; then
    conf="$HALOW_STATE_DIR/dnsmasq.conf"
    : > "$conf"
    halow_own_mark "net_dnsmasq"
    dnsmasq --port=0 --conf-file="$conf" --no-daemon --pid-file="$pidfile" &
    owned_pid=$!
    echo "$owned_pid" > "$pidfile"
    sleep 0.5
    halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_owned.log" 2>&1
    assert_failure "the genuinely owned dnsmasq process is confirmed gone after teardown" \
        kill -0 "$owned_pid"
    assert_failure "ownership is cleared only after the owned process is positively confirmed stopped by a fresh, complete post-kill scan" \
        halow_own_check "net_dnsmasq"
    assert_file_absent "$pidfile" "the pid file is removed after verified cleanup"
else
    echo "  (skipped: no real dnsmasq binary on PATH — the mismatch/stale-pid cases above, which do not need one, still ran)"
fi

halow_test_teardown

echo "== test_network_backend: halow_teardown_dnsmasq — a process that genuinely stops but only ~3.5s after being signalled (past the old, single fixed one-second check) is still correctly confirmed absent and cleaned up =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
: > "$conf"
( trap 'sleep 2.5; exit 0' TERM; while :; do sleep 1; done ) &
slow_pid=$!
echo "$slow_pid" > "$pidfile"
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { [ "$1" = "$slow_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$slow_pid" 2>/dev/null && { printf '%s' "$slow_pid"; return 0; }; return 1; }
_slow_stop_start=$(date +%s)
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_slow.log" 2>&1
_slow_stop_elapsed=$(( $(date +%s) - _slow_stop_start ))
assert_failure "net_dnsmasq ownership is cleared for a process that takes several seconds (not one) to actually exit after being signalled" \
    halow_own_check "net_dnsmasq"
assert_file_absent "$conf" "the config is removed once the slow-to-exit process is eventually confirmed gone"
assert_file_absent "$pidfile" "the pid file is removed once the slow-to-exit process is eventually confirmed gone"
if [ "$_slow_stop_elapsed" -ge 2 ]; then
    echo "  ok: the retry loop genuinely waited past the old, too-short one-second window (${_slow_stop_elapsed}s elapsed) rather than this test coincidentally passing within it"
else
    echo "  FAIL: halow_teardown_dnsmasq returned in only ${_slow_stop_elapsed}s -- too fast to have actually retried past the old one-second window"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
halow_test_teardown

echo "== test_network_backend: halow_teardown_dnsmasq — the mandatory fresh, COMPLETE scan after a kill can still find a second live instance, keeping ownership (not merely re-checking the one pid just signalled) =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
: > "$conf"
( sleep 30 ) & stoppable_pid=$!
( sleep 30 ) & second_instance_pid=$!
echo "$stoppable_pid" > "$pidfile"
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { [ "$1" = "$stoppable_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$second_instance_pid" 2>/dev/null && { printf '%s' "$second_instance_pid"; return 0; }; return 1; }
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_second_instance.log" 2>&1
assert_failure "the recorded pid was genuinely stopped" kill -0 "$stoppable_pid"
assert_success "ownership is kept -- the post-kill full scan found a second, still-live candidate the pid file alone never named" \
    halow_own_check "net_dnsmasq"
assert_file_exists "$conf" "the config is NOT removed while a second candidate is still unresolved"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$second_instance_pid" 2>/dev/null; wait "$stoppable_pid" "$second_instance_pid" 2>/dev/null || true
halow_own_clear "net_dnsmasq"
rm -f -- "$pidfile" "$conf"
halow_test_teardown

echo "== test_network_backend: missing/malformed pid file, the identity-based scan fallback, failure to stop, broken-symlink removal, and independent per-file failed-removal (stubbed, direct control of outcome) =="
halow_test_setup
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
conf="$HALOW_STATE_DIR/dnsmasq.conf"
mkdir -p "$HALOW_STATE_DIR"

# --- Missing pid file, and a thorough identity scan finds no matching process at all:
# this is positive evidence of absence (not merely assumed from the missing file alone)
# -- safe to clear ownership. ---
halow_find_dnsmasq_by_identity() { return 1; }
halow_own_mark "net_dnsmasq"
rm -f -- "$pidfile"
halow_teardown_dnsmasq >/dev/null 2>&1
assert_failure "ownership is cleared when the pid file is missing AND a full identity scan positively confirms no owned process exists" \
    halow_own_check "net_dnsmasq"
unset -f halow_find_dnsmasq_by_identity

# --- Missing pid file, and the identity scan finds more than one candidate: genuinely
# ambiguous -- must never guess which one is "ours"; ownership is kept. ---
halow_find_dnsmasq_by_identity() { return 2; }
halow_own_mark "net_dnsmasq"
rm -f -- "$pidfile"
halow_teardown_dnsmasq >/dev/null 2>&1
assert_success "ownership is kept when the pid file is missing and more than one process matches this package's own identity (refuses to guess)" \
    halow_own_check "net_dnsmasq"
unset -f halow_find_dnsmasq_by_identity
halow_own_clear "net_dnsmasq"

# --- A malformed (non-numeric) pid file is treated exactly like a missing one -- it must
# not be passed to `kill` as-is, and must not silently clear ownership either. ---
halow_find_dnsmasq_by_identity() { return 1; }
halow_own_mark "net_dnsmasq"
printf 'not-a-pid\n' > "$pidfile"
halow_teardown_dnsmasq >/dev/null 2>&1
assert_failure "a malformed pid file is handled the same as a missing one, not passed to kill, and ownership is cleared only once absence is positively confirmed by the identity scan" \
    halow_own_check "net_dnsmasq"
unset -f halow_find_dnsmasq_by_identity

# --- Recorded pid is alive and its `comm` genuinely matches "dnsmasq", but its cmdline
# cannot be read at all: this must be treated as UNKNOWN, never as a positive match (an
# earlier version of halow_dnsmasq_identity_matches treated this exact case as a
# fallback positive match, which this change fixes) and never as evidence the process is
# absent either. This is a DIRECT pidfile-check outcome (never escalated to the
# secondary scan — UNKNOWN from the primary check is always terminal, per item 4). ---
halow_process_comm() { echo "dnsmasq"; }
halow_process_cmdline_contains() { return 2; }
( sleep 30 ) &
unknown_identity_pid=$!
halow_own_mark "net_dnsmasq"
echo "$unknown_identity_pid" > "$pidfile"
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_unknown.log" 2>&1
assert_success "the unrelated/unknown-identity process is still alive after teardown (never signalled on an unknown identity)" \
    kill -0 "$unknown_identity_pid"
assert_success "ownership is kept, not cleared, when the process's own identity cannot be positively confirmed (unreadable cmdline)" \
    halow_own_check "net_dnsmasq"
assert_file_exists "$pidfile" "the pid file is left in place for manual review when identity is unknown, not deleted"
kill "$unknown_identity_pid" 2>/dev/null || true
wait "$unknown_identity_pid" 2>/dev/null || true
unset -f halow_process_comm halow_process_cmdline_contains
halow_own_clear "net_dnsmasq"

# --- The correctly identified, genuinely owned process refuses to stop: ownership kept
# and reported, never silently treated as cleaned up. Uses a process that genuinely traps
# and ignores SIGTERM (not merely a stub that claims "match" for every pid, which the
# mandatory post-kill FULL scan would apply to every other live process on the real test
# host too, making "ambiguous" the accidental, host-process-count-dependent reason
# ownership stays kept, rather than a deterministic proof that THIS process specifically
# did not stop). Both identity functions are stubbed pid-specifically and dynamically
# (via a real `kill -0` check), so this test's own pass/fail genuinely tracks this one
# target process's real liveness. ---
( trap '' TERM; exec sleep 30 ) &
wontstop_pid=$!
halow_own_mark "net_dnsmasq"
echo "$wontstop_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$wontstop_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$wontstop_pid" 2>/dev/null && { printf '%s' "$wontstop_pid"; return 0; }; return 1; }
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/teardown_wontstop.log" 2>&1
assert_success "ownership is kept when the identified process is reported as not having stopped" \
    halow_own_check "net_dnsmasq"
assert_success "the process that refuses to stop is confirmed still genuinely alive (SIGTERM-immune, not a stub artifact)" \
    kill -0 "$wontstop_pid"
assert_file_exists "$pidfile" "the pid file is left in place while the process is still reported as not stopped"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill -KILL "$wontstop_pid" 2>/dev/null; wait "$wontstop_pid" 2>/dev/null || true
halow_own_clear "net_dnsmasq"
rm -f -- "$pidfile" "$conf"

# --- Failed file removal (`rm` itself fails), tested independently for the pid file and
# the config: the files cannot be deleted even though the process is confirmed gone --
# ownership must be KEPT, reported as a residual, never cleared. The recorded pid is dead
# (identity_matches returns 3), which this change's own correction now routes through the
# mandatory secondary scan rather than treating as directly, terminally confirmed_absent --
# halow_find_dnsmasq_by_identity is therefore explicitly stubbed here too (not left to
# whatever a prior scenario's own stub/unset state happened to be), confirming that same
# scan finds nothing, so the test is deterministic regardless. ---
for _target_label in "dnsmasq.pid" "dnsmasq.conf"; do
    : > "$conf"
    echo "123456" > "$pidfile"
    halow_own_mark "net_dnsmasq"
    halow_dnsmasq_identity_matches() { return 3; }
    halow_find_dnsmasq_by_identity() { return 1; }
    eval "rm() { case \"\$*\" in *${_target_label}*) return 1 ;; *) command rm \"\$@\" ;; esac; }"
    halow_teardown_dnsmasq >"$HALOW_TEST_TMP/cleanup_fail_${_target_label}.log" 2>&1
    unset -f rm
    assert_success "ownership is kept when $_target_label specifically cannot be removed" halow_own_check "net_dnsmasq"
    halow_own_clear "net_dnsmasq"
    rm -f -- "$pidfile" "$conf"
done
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity

# --- Broken-symlink regression: a plain `[ -e <path> ]` reports FALSE for a dangling
# symlink, which could wrongly be read as "confirmed removed" even though a symlink entry
# still genuinely occupies that path. halow_path_still_present (used throughout
# halow_teardown_dnsmasq) must correctly treat a dangling symlink
# left in place of the config as still present. ---
: > "$conf"
echo "123456" > "$pidfile"
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { return 3; }
halow_find_dnsmasq_by_identity() { return 1; }
rm() {
    case "$*" in
        *dnsmasq.conf*)
            command rm -f -- "$conf"
            ln -s "/nonexistent-target-$$" "$conf"
            return 0
            ;;
        *) command rm "$@" ;;
    esac
}
halow_teardown_dnsmasq >/dev/null 2>&1
unset -f rm halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
assert_success "a dangling symlink left in place of the removed config is correctly detected as still present (ownership kept)" \
    halow_own_check "net_dnsmasq"
assert_success "the dangling symlink itself is still there, confirming this test's own simulation took effect" \
    bash -c "[ -L '$conf' ]"
halow_own_clear "net_dnsmasq"
rm -f -- "$pidfile" "$conf"

# --- Owned, pid file names a DEAD pid, but the mandatory secondary scan finds this
# package's own dnsmasq genuinely alive under a DIFFERENT pid: this must be treated as
# OWNED (that found pid becomes the target), and the existing kill-then-rescan logic must
# run against it -- files are not removed and ownership is not cleared merely because the
# ORIGINALLY recorded pid was dead; a live instance found by the scan is handled safely
# (signalled, then re-confirmed absent by a fresh scan) before any cleanup. ---
: > "$conf"
echo "999999" > "$pidfile"   # a pid that is never alive -- always resolves identity_matches to 3 (dead)
( sleep 30 ) & real_instance_pid=$!
halow_own_mark "net_dnsmasq"
halow_dnsmasq_identity_matches() { [ "$1" = "999999" ] && return 3; [ "$1" = "$real_instance_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$real_instance_pid" 2>/dev/null && { printf '%s' "$real_instance_pid"; return 0; }; return 1; }
halow_teardown_dnsmasq >"$HALOW_TEST_TMP/dead_pid_scan_finds_live.log" 2>&1
assert_failure "the real instance found by the dead-pid's own mandatory secondary scan was genuinely signalled and stopped" \
    kill -0 "$real_instance_pid"
assert_failure "ownership is cleared once the scan-found real instance is itself confirmed stopped by a fresh, complete re-scan" \
    halow_own_check "net_dnsmasq"
assert_file_absent "$conf" "the config is removed once the scan-found real instance is confirmed stopped"
assert_file_absent "$pidfile" "the (originally dead-pid-naming) pid file is removed once cleanup completes"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
wait "$real_instance_pid" 2>/dev/null || true
rm -f -- "$pidfile" "$conf"

# --- No net_dnsmasq ownership marker at all, but a real, live process positively matches
# this package's own identity: a code review found this teardown
# section used to be skipped ENTIRELY whenever ownership was not held, WITHOUT EVER
# running the identity scan -- meaning this exact case was silently invisible, and
# halow_rollback's own aggregate ownership-key check has no key to notice it either,
# since nothing was ever marked owned. Fixed: the scan now always runs regardless of
# ownership-marker state (halow_teardown_dnsmasq's own dedicated return value and the
# HALOW_DNSMASQ_UNOWNED_RESIDUAL global, both checked by halow_rollback, report this);
# a positively-identified-but-unowned process must still never be signalled, adopted, or
# have its files touched. ---
: > "$conf"
( sleep 30 ) &
unowned_live_pid=$!
echo "$unowned_live_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$unowned_live_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$unowned_live_pid" 2>/dev/null && { printf '%s' "$unowned_live_pid"; return 0; }; return 1; }
assert_failure "halow_teardown_dnsmasq reports a hard failure (not silent success) when a positively-matching dnsmasq process is found with NO net_dnsmasq ownership marker held" \
    halow_teardown_dnsmasq
assert_success "the unowned, identity-matching process remains completely untouched -- never signalled" kill -0 "$unowned_live_pid"
assert_failure "no net_dnsmasq ownership is adopted for it" halow_own_check "net_dnsmasq"
assert_file_exists "$conf" "its config is not touched/removed"
assert_file_exists "$pidfile" "its pid file is not touched/removed"
unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$unowned_live_pid" 2>/dev/null; wait "$unowned_live_pid" 2>/dev/null || true
rm -f -- "$pidfile" "$conf"

halow_test_teardown

# --- No net_dnsmasq ownership marker at all, and nothing matches either (the
# overwhelmingly common, totally normal case -- dnsmasq was simply never started this
# run): must remain a silent, harmless, successful no-op, with no behaviour change or
# added noise from the fix above. A fresh setup/teardown pair here, rather than
# continuing to share the previous one, guarantees the REAL, unstubbed
# halow_find_dnsmasq_by_identity is genuinely in effect (halow_test_setup only
# re-sources the real production libs at the START of a setup/teardown pair -- an
# `unset -f` earlier in a shared pair deletes a stub, it does not restore the real
# definition; this scenario is deliberately NOT sharing that earlier pair at all). ---
halow_test_setup
assert_success "halow_teardown_dnsmasq remains a safe, silent no-op when nothing is owned AND nothing matches (the normal case)" \
    halow_teardown_dnsmasq
halow_test_teardown

echo "== test_network_backend: network_values survives the unowned-dnsmasq-residual condition reported via halow_teardown_dnsmasq's own HALOW_DNSMASQ_UNOWNED_RESIDUAL global, even when every OTHER net_* key is also unowned (an earlier round's own fix, re-verified here against the later split of dnsmasq's own teardown into its own function) =="
# Without this fix, halow_remove_network_values (which only ever checks the six net_*
# OWNERSHIP keys, with no knowledge of any dnsmasq residual condition) could delete
# network_values on the VERY SAME PASS that first detects an unowned, matching dnsmasq
# process -- since net_dnsmasq itself genuinely reads as "not owned" in exactly this
# condition, and every other net_* key is unowned here too (the realistic trigger: a
# restart where the other, iface-scoped mutations were already freshly cleared).
#
# halow_teardown_dnsmasq (where this condition is actually detected) and
# halow_teardown_network (where halow_remove_network_values is actually called) are
# now two SEPARATE functions, communicating this specific condition only via the global
# HALOW_DNSMASQ_UNOWNED_RESIDUAL — this test calls them in the same order
# halow_rollback itself does, and checks the global directly, to prove that split
# did not reopen the gap the original fix closed. Proven here end-to-end: network_values
# is written for real (via the real halow_save_network_values, exactly as
# halow_apply_network itself would have), NO net_* key is owned (matching the realistic
# trigger), and a SECOND pass of both calls must still be ABLE to re-detect the same
# condition -- network_values must not have been lost in between.
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
halow_save_network_values "wlu1.sta1" "192.168.90.1/24" "end0"
values_file="$HALOW_STATE_DIR/network_values"
assert_file_exists "$values_file" "network_values is genuinely present before either pass, exactly as a real run would have left it"
: > "$conf"
( sleep 30 ) &
residual_pid=$!
echo "$residual_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$residual_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$residual_pid" 2>/dev/null && { printf '%s' "$residual_pid"; return 0; }; return 1; }

assert_failure "the first halow_teardown_dnsmasq call reports the hard failure, as before" \
    halow_teardown_dnsmasq
assert_eq "1" "$HALOW_DNSMASQ_UNOWNED_RESIDUAL" "the global halow_teardown_network relies on is set after the first pass"
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
assert_file_exists "$values_file" "network_values survives the very pass that first detects the unresolved residual -- not deleted just because every net_* ownership key reads as unowned"
assert_success "the residual process is still untouched after the first pass" kill -0 "$residual_pid"

assert_failure "a SECOND halow_teardown_dnsmasq call can still re-detect the same unresolved condition (network_values was not lost, so a future real rollback attempt is not silently skipped)" \
    halow_teardown_dnsmasq
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
assert_file_exists "$values_file" "network_values still survives after the second pass"
assert_success "the residual process is still untouched after the second pass too" kill -0 "$residual_pid"
assert_failure "still no net_dnsmasq ownership is adopted for it" halow_own_check "net_dnsmasq"

unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$residual_pid" 2>/dev/null; wait "$residual_pid" 2>/dev/null || true
rm -f -- "$pidfile" "$conf"
halow_test_teardown

echo "== test_network_backend: network_values survives the dnsmasq-residual condition even when halow_load_network_values itself FAILS (missing/malformed network_values) -- the exact earlier-defect gap: halow_teardown_dnsmasq must still run and set the global even though halow_teardown_network (and the network_values removal decision inside it) never runs at all in this case =="
# This is the scenario the original network_values-gating defect was invisible in: a
# missing or malformed network_values file used to skip the ENTIRE dnsmasq scan (it only
# ran as part of halow_teardown_network, itself only invoked when
# halow_load_network_values succeeded). Now that halow_teardown_dnsmasq needs no
# network_values at all, it must still detect and report an unowned-but-identity-
# matching process even with no network_values file present whatsoever.
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
values_file="$HALOW_STATE_DIR/network_values"
rm -f -- "$values_file"
assert_file_absent "$values_file" "network_values is genuinely absent for this scenario"
: > "$conf"
( sleep 30 ) &
no_values_residual_pid=$!
echo "$no_values_residual_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$no_values_residual_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$no_values_residual_pid" 2>/dev/null && { printf '%s' "$no_values_residual_pid"; return 0; }; return 1; }

assert_failure "halow_load_network_values correctly fails closed when network_values is missing (confirming this scenario's own premise)" \
    halow_load_network_values
assert_failure "halow_teardown_dnsmasq STILL reports the hard failure even though network_values is missing (the earlier-defect fix: this scan no longer depends on network_values at all)" \
    halow_teardown_dnsmasq
assert_eq "1" "$HALOW_DNSMASQ_UNOWNED_RESIDUAL" "the global is set even with no network_values on disk"
assert_success "the unowned, identity-matching process remains completely untouched" kill -0 "$no_values_residual_pid"
assert_failure "no net_dnsmasq ownership is adopted for it" halow_own_check "net_dnsmasq"

unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$no_values_residual_pid" 2>/dev/null; wait "$no_values_residual_pid" 2>/dev/null || true
rm -f -- "$pidfile" "$conf"
halow_test_teardown

echo "== test_network_backend: the SAME missing-network_values scenario, but with a MALFORMED (not merely absent) network_values file -- halow_teardown_dnsmasq's own detection must not depend on how halow_load_network_values specifically failed =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
mkdir -p "$HALOW_STATE_DIR"
values_file="$HALOW_STATE_DIR/network_values"
printf 'this is not valid KEY=VALUE network_values content\n' > "$values_file"
: > "$conf"
( sleep 30 ) &
malformed_values_residual_pid=$!
echo "$malformed_values_residual_pid" > "$pidfile"
halow_dnsmasq_identity_matches() { [ "$1" = "$malformed_values_residual_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_dnsmasq_by_identity() { kill -0 "$malformed_values_residual_pid" 2>/dev/null && { printf '%s' "$malformed_values_residual_pid"; return 0; }; return 1; }

assert_failure "halow_load_network_values correctly fails closed on a malformed network_values file (confirming this scenario's own premise)" \
    halow_load_network_values
assert_failure "halow_teardown_dnsmasq STILL reports the hard failure even with a malformed network_values file on disk" \
    halow_teardown_dnsmasq
assert_eq "1" "$HALOW_DNSMASQ_UNOWNED_RESIDUAL" "the global is set regardless of why network_values failed to load"
assert_success "the unowned, identity-matching process remains completely untouched" kill -0 "$malformed_values_residual_pid"
assert_file_exists "$values_file" "the malformed network_values file itself is left untouched by this scan -- it is not this function's job to remove or repair it"

unset -f halow_dnsmasq_identity_matches halow_find_dnsmasq_by_identity
kill "$malformed_values_residual_pid" 2>/dev/null; wait "$malformed_values_residual_pid" 2>/dev/null || true
rm -f -- "$pidfile" "$conf" "$values_file"
halow_test_teardown

echo "== test_network_backend: marker-write-failure undoes and verifies each mutation (fail-closed ownership discipline) =="
# Saves the real halow_own_mark under a different name so each scenario below can fail
# it for exactly one targeted key while still genuinely performing it for every other
# key — proving the undo-and-verify behaviour for that one mutation specifically, not
# merely that the whole function aborts somewhere.
eval "$(declare -f halow_own_mark | sed '1s/halow_own_mark/_real_own_mark_for_test/')"

_run_mark_failure_scenario() {
    local fail_key="$1"
    halow_test_setup
    halow_read_ip_forward() { echo "0"; }
    ip() {
        if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then return 0; fi
        return 0
    }
    sysctl() { return 0; }
    iptables() { case "$*" in *-C*) return 1 ;; *) return 0 ;; esac; }
    halow_test_install_dnsmasq_identity_stubs
    halow_own_mark() {
        if [ "$1" = "$fail_key" ]; then
            return 1
        fi
        _real_own_mark_for_test "$@"
    }

    assert_failure "apply_network fails closed when the '$fail_key' ownership marker cannot be recorded" \
        halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
    assert_failure "no ownership is left for '$fail_key' after its own marker-write failure" \
        halow_own_check "$fail_key"

    unset -f halow_own_mark ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
    halow_test_uninstall_dnsmasq_identity_stubs
    halow_test_teardown
}

for key in net_addr net_ip_forward net_nat_rule net_fwd_rule_out net_fwd_rule_in net_dnsmasq; do
    _run_mark_failure_scenario "$key"
done

echo "== test_network_backend: marker-write failure for 'net_addr' specifically undoes the address (verified via the ip stub's own state) =="
halow_test_setup
ADDR_STATE=0
halow_read_ip_forward() { echo "0"; }
ip() {
    if [ "$1" = "-4" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
        [ "$ADDR_STATE" -eq 1 ] && echo "    inet 192.168.90.1/24 brd 192.168.90.255 scope global wlu1.sta1"
        return 0
    elif [ "$1" = "addr" ] && [ "$2" = "add" ]; then
        ADDR_STATE=1; return 0
    elif [ "$1" = "addr" ] && [ "$2" = "del" ]; then
        ADDR_STATE=0; return 0
    fi
    return 0
}
halow_own_mark() {
    [ "$1" = "net_addr" ] && return 1
    _real_own_mark_for_test "$@"
}
halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0" >/dev/null 2>&1
assert_eq "0" "$ADDR_STATE" "the address is genuinely removed again (ip stub's own state), not merely ownership left unclaimed"
unset -f halow_own_mark ip halow_read_ip_forward 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: marker-write failure for 'net_dnsmasq' means NO dnsmasq config or process is EVER created (ownership-first ordering, not 'create then kill') =="
halow_test_setup
conf="$HALOW_STATE_DIR/dnsmasq.conf"
pidfile="$HALOW_STATE_DIR/dnsmasq.pid"
halow_read_ip_forward() { echo "0"; }
ip() { return 0; }
sysctl() { return 0; }
iptables() { [ "$3" = "-C" ] && return 0; return 0; }
halow_test_install_dnsmasq_identity_stubs
halow_own_mark() {
    [ "$1" = "net_dnsmasq" ] && return 1
    _real_own_mark_for_test "$@"
}
assert_failure "apply_network fails closed when the net_dnsmasq ownership marker cannot be recorded" \
    halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
assert_file_absent "$conf" "dnsmasq.conf is never created at all when lifecycle ownership could not be recorded first (ownership-first ordering, not 'create then discover we can't track it')"
assert_file_absent "$pidfile" "no dnsmasq process is ever started (and so no pid file is ever written) when lifecycle ownership could not be recorded first"
dnsmasq_call_count="$(grep -c '^dnsmasq ' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
assert_eq "0" "${dnsmasq_call_count:-0}" "the dnsmasq process itself is never even launched when its own ownership marker cannot be recorded"
unset -f halow_own_mark ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_uninstall_dnsmasq_identity_stubs
halow_test_teardown

echo "== test_network_backend: halow_save_network_values failure aborts BEFORE any mutation =="
halow_test_setup
mutation_attempted=0
ip() { mutation_attempted=1; return 0; }
sysctl() { mutation_attempted=1; return 0; }
iptables() { mutation_attempted=1; return 1; }
dnsmasq() { mutation_attempted=1; sleep 30; }
halow_save_network_values() { return 1; }
assert_failure "apply_network aborts immediately when network values cannot be persisted" \
    halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0"
assert_eq "0" "$mutation_attempted" "no mutation is attempted at all when the state file itself cannot be written"
unset -f halow_save_network_values ip sysctl iptables dnsmasq 2>/dev/null || true
halow_test_teardown

echo "== test_network_backend: network_values is parsed as DATA, never sourced as shell code =="
halow_test_setup
malicious_file="$HALOW_STATE_DIR/network_values"
mkdir -p "$HALOW_STATE_DIR"
{
    echo 'HALOW_NET_IFACE=wlu1.sta1'
    echo 'HALOW_NET_CIDR=192.168.90.1/24'
    echo 'HALOW_NET_UPLINK=end0; echo INJECTED > '"$HALOW_TEST_TMP"'/injected.txt'
} > "$malicious_file"
assert_failure "a line with injected shell syntax is rejected as an invalid interface name, not executed" \
    halow_load_network_values "$malicious_file"
assert_file_absent "$HALOW_TEST_TMP/injected.txt" "the injected command never actually ran"

: > "$malicious_file"
{
    echo 'HALOW_NET_IFACE=wlu1.sta1'
    echo 'HALOW_NET_IFACE=wlu2.sta1'
    echo 'HALOW_NET_CIDR=192.168.90.1/24'
    echo 'HALOW_NET_UPLINK=end0'
} > "$malicious_file"
assert_failure "a duplicate key is rejected as malformed" \
    halow_load_network_values "$malicious_file"

: > "$malicious_file"
{
    echo 'HALOW_NET_IFACE=wlu1.sta1'
    echo 'HALOW_NET_CIDR=192.168.90.1/24'
} > "$malicious_file"
assert_failure "a missing required key is rejected as malformed" \
    halow_load_network_values "$malicious_file"

: > "$malicious_file"
{
    echo 'HALOW_NET_IFACE=wlu1.sta1'
    echo 'HALOW_NET_CIDR=192.168.90.1/24'
    echo 'HALOW_NET_UPLINK=end0'
    echo 'SOME_UNEXPECTED_KEY=value'
} > "$malicious_file"
assert_failure "an unexpected/unknown key is rejected as malformed" \
    halow_load_network_values "$malicious_file"

: > "$malicious_file"
{
    echo 'HALOW_NET_IFACE=wlu1.sta1'
    echo 'HALOW_NET_CIDR=192.168.90.1/24'
    echo 'HALOW_NET_UPLINK=end0'
} > "$malicious_file"
assert_success "a well-formed file still loads correctly" \
    halow_load_network_values "$malicious_file"
assert_eq "wlu1.sta1" "$HALOW_NET_IFACE" "the well-formed value is loaded correctly after the malformed-file rejections above"

halow_test_teardown

echo "== test_network_backend: network_values is removed only once every network ownership marker is cleared =="
halow_test_setup
ip() { return 0; }
sysctl() { return 0; }
iptables() { case "$*" in *-C*) return 1 ;; *) return 0 ;; esac; }
halow_read_ip_forward() { echo "0"; }
halow_test_install_dnsmasq_identity_stubs
halow_apply_network "wlu1.sta1" "192.168.90.1/24" "192.168.90.50" "192.168.90.150" "end0" >/dev/null 2>&1
values_file="$HALOW_STATE_DIR/network_values"
assert_file_exists "$values_file" "network_values exists while mutations are still owned"
# Simulate one removal failing (NAT rule) so teardown cannot fully complete.
iptables() { [ "$1" = "-t" ] && [ "$3" = "-D" ] && return 1; [ "$3" = "-C" ] && return 0; return 0; }
halow_teardown_dnsmasq >/dev/null 2>&1
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
assert_file_exists "$values_file" "network_values is NOT removed while any network ownership marker remains"
unset -f ip sysctl iptables halow_read_ip_forward 2>/dev/null || true
halow_test_uninstall_dnsmasq_identity_stubs
halow_test_teardown

echo "== test_network_backend: halow_teardown_network's own \${HALOW_DNSMASQ_UNOWNED_RESIDUAL:-0} default does not error under set -u, and correctly treats 'never assigned at all' as 'no residual' =="
# In production this global is always assigned before halow_teardown_network could ever
# read it, since halow_rollback calls halow_teardown_dnsmasq (which assigns it
# unconditionally) before it can reach halow_teardown_network at all. This test exists
# purely to confirm the defensive ":-0" default itself holds standalone, under this
# file's own "set -uo pipefail" -- not merely that production's own call order happens to
# avoid ever exercising the unset case.
halow_test_setup
unset HALOW_DNSMASQ_UNOWNED_RESIDUAL
ip() { return 0; }
sysctl() { return 0; }
iptables() { case "$*" in *-C*) return 1 ;; *) return 0 ;; esac; }
assert_success "halow_teardown_network does not error under set -u when HALOW_DNSMASQ_UNOWNED_RESIDUAL was never assigned at all" \
    halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24"
unset -f ip sysctl iptables 2>/dev/null || true
halow_test_teardown

unset -f _real_own_mark_for_test _run_mark_failure_scenario 2>/dev/null || true


echo "== test_network_backend: net_addr teardown when the dynamic WDS interface has ALREADY vanished (client left/rebooted before the add-on was stopped) -- rollback must not stay INCOMPLETE forever (found by a code review) =="
halow_test_setup
ip() { case "$*" in "addr del"*) echo "Cannot find device \"wlu1.sta1\"" >&2; return 1 ;; esac; return 0; }
iptables() { return 0; }
sysctl() { return 0; }
halow_own_mark "net_addr"
# (a) interface positively gone (no /sys/class/net/<iface>) -> ownership cleared, teardown succeeds
rm -rf "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
assert_failure "interface gone: net_addr ownership is CLEARED (the address went with the interface)" halow_own_check "net_addr"
# (b) interface still exists but `ip addr del` fails -> ownership KEPT (never claimed removed)
halow_own_mark "net_addr"
mkdir -p "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
halow_teardown_network "wlu1.sta1" "end0" "192.168.90.1/24" >/dev/null 2>&1
assert_success "interface present but addr del fails: net_addr ownership is KEPT" halow_own_check "net_addr"
halow_own_clear "net_addr"
unset -f ip iptables sysctl
halow_test_teardown

echo "test_network_backend: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
