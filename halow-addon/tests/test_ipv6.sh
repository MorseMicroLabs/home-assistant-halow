#!/usr/bin/env bash
# Tests ipv6.sh against a fake /proc/sys tree (HALOW_PROC_SYS_DIR): the original value is
# recorded before the write and never overwritten, every write is read back, refusals and
# unreadable values fail, restore puts the recorded value back and clears the record only
# once confirmed (a vanished interface counts as restored), nothing else under /proc/sys is
# written, and the functions behave under the strict shell options and a corrupted IFS.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./doubles/fakes_env.sh
halow_fakes_mnt_install
. ./fakes/fake_ipv6_mount.sh
fake_ipv6_guard_install

echo "== test_ipv6 =="
PROC="$HALOW_TEST_TMP/fake-proc-sys"
export HALOW_PROC_SYS_DIR="$PROC"
CONF="$PROC/net/ipv6/conf"

reset_proc() {
    halow_fakes_mnt_install
    rm -rf "${PROC:?}" "${HALOW_STATE_DIR:?}/owns"
    mkdir -p "$CONF/all" "$CONF/default" "$PROC/net/ipv4"
    echo 0 > "$CONF/all/disable_ipv6"; echo 0 > "$CONF/default/disable_ipv6"
    echo 1 > "$PROC/net/ipv4/ip_forward"
    local i
    for i in "$@"; do mkdir -p "$CONF/$i"; echo 0 > "$CONF/$i/disable_ipv6"; done
}
val() { cat "$CONF/$1/disable_ipv6"; }
tree_view() { (cd "$PROC" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s=%s\n' "$f" "$(cat "$f")"; done); }

echo "-- disable --"
reset_proc wlu1 halow-br0
BEFORE="$(tree_view)"
assert_success "IPv6 is turned off on the parent" halow_ipv6_disable wlu1
assert_eq "1" "$(val wlu1)" "...the host shows disable_ipv6=1"
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...the original value 0 is recorded"
assert_success "...and the bridge too" halow_ipv6_disable halow-br0
EXPECTED="$(sed -e 's|^\./net/ipv6/conf/wlu1/disable_ipv6=0$|./net/ipv6/conf/wlu1/disable_ipv6=1|' -e 's|^\./net/ipv6/conf/halow-br0/disable_ipv6=0$|./net/ipv6/conf/halow-br0/disable_ipv6=1|' <<< "$BEFORE")"
assert_eq "$EXPECTED" "$(tree_view)" "nothing else under /proc/sys changed (not all/default, not ip_forward)"
assert_success "a repeated disable succeeds" halow_ipv6_disable wlu1
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...and keeps the FIRST recorded value (never records its own 1)"
assert_success "halow_ipv6_present sees the records" halow_ipv6_present

echo "-- the record is written before the write --"
reset_proc wlu1
_order="$HALOW_TEST_TMP/order"; : > "$_order"
eval "$(declare -f _halow_ipv6_write | sed '1s/_halow_ipv6_write/_orig_ipv6_write/')"
_halow_ipv6_write() { if halow_own_check "ipv6_wlu1"; then echo marker-present >> "$_order"; else echo marker-absent >> "$_order"; fi; _orig_ipv6_write "$@"; }
halow_ipv6_disable wlu1 >/dev/null 2>&1
assert_eq "marker-present" "$(sort -u "$_order")" "the record exists when the value is written"
reset_proc wlu1
halow_own_mark() { return 1; }
assert_failure "a record that cannot be written stops the change" halow_ipv6_disable wlu1
assert_eq "0" "$(val wlu1)" "...the host value is unchanged"
unset -f halow_own_mark
. "$HALOW_LIB_DIR/ownership.sh"

echo "-- failures are reported, never hidden --"
reset_proc wlu1
_halow_ipv6_write() { return 1; }
assert_exit 1 "a refused write returns 1" halow_ipv6_disable wlu1
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...the record stays (restore is a no-op that clears it)"
_halow_ipv6_write() { return 0; }
assert_exit 1 "a write that does not read back returns 1" halow_ipv6_disable wlu1
eval "$(declare -f _orig_ipv6_write | sed '1s/_orig_ipv6_write/_halow_ipv6_write/')"
assert_success "...restore then confirms the unchanged value and clears the record" halow_ipv6_restore_all
assert_failure "...no record left" halow_ipv6_present
reset_proc wlu1
assert_exit 1 "an interface without an IPv6 switch returns 1" halow_ipv6_disable wlu9
assert_failure "...and records nothing" halow_own_check ipv6_wlu9
echo 7 > "$CONF/wlu1/disable_ipv6"
assert_exit 1 "an unexpected value returns 1" halow_ipv6_disable wlu1
assert_eq "7" "$(val wlu1)" "...and is left alone"
assert_exit 1 "an invalid interface name is refused" halow_ipv6_disable 'wl/u1'
assert_exit 1 "an empty interface name is refused" halow_ipv6_disable ''
reset_proc wlu1
halow_own_mark ipv6_wlu1 "x"
assert_exit 1 "a malformed earlier record stops the change" halow_ipv6_disable wlu1
assert_eq "0" "$(val wlu1)" "...the host value is unchanged"

echo "-- an interface that was already off --"
reset_proc wlu1
echo 1 > "$CONF/wlu1/disable_ipv6"
assert_success "disable succeeds" halow_ipv6_disable wlu1
assert_eq "1" "$(halow_own_get ipv6_wlu1)" "...recording 1 as the original"
assert_success "restore succeeds" halow_ipv6_restore_all
assert_eq "1" "$(val wlu1)" "...and leaves it off, as it was"

echo "-- restore --"
reset_proc wlu1 halow-br0 wlu1.sta1 wlu1.sta2
echo 1 > "$CONF/wlu1.sta2/disable_ipv6"
for i in wlu1 halow-br0 wlu1.sta1 wlu1.sta2; do halow_ipv6_disable "$i" >/dev/null 2>&1; done
rm -rf "${CONF:?}/wlu1.sta1"   # a per-station interface that went away
assert_success "restore_all succeeds" halow_ipv6_restore_all
assert_eq "0 0 1" "$(val wlu1) $(val halow-br0) $(val wlu1.sta2)" "every surviving interface has its recorded value back"
assert_eq "" "$(halow_own_list | grep '^ipv6_' || true)" "every record is cleared, the vanished interface's too"
assert_failure "halow_ipv6_present: nothing held" halow_ipv6_present
assert_success "restore with nothing recorded is a no-op" halow_ipv6_restore_all

reset_proc wlu1 halow-br0
halow_ipv6_disable wlu1 >/dev/null 2>&1; halow_ipv6_disable halow-br0 >/dev/null 2>&1
_halow_ipv6_write() { case "$1" in *halow-br0*) return 1 ;; esac; _orig_ipv6_write "$@"; }
assert_exit 1 "a value that cannot be put back makes restore_all return 1" halow_ipv6_restore_all
assert_eq "0" "$(val wlu1)" "...the others are still restored"
assert_failure "...and their records cleared" halow_own_check ipv6_wlu1
assert_success "...the unconfirmed record is kept" halow_own_check ipv6_halow-br0
assert_success "...and reported as present" halow_ipv6_present
eval "$(declare -f _orig_ipv6_write | sed '1s/_orig_ipv6_write/_halow_ipv6_write/')"
assert_success "a later restore completes it" halow_ipv6_restore_all
assert_eq "0" "$(val halow-br0)" "...restored"

reset_proc wlu1
halow_own_mark ipv6_wlu1 "garbage"
assert_exit 1 "a malformed record is never cleared on a guess" halow_ipv6_restore_all
assert_success "...it is kept" halow_own_check ipv6_wlu1
reset_proc wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
rm -rf "${PROC:?}/net/ipv6"
assert_exit 1 "an unreadable IPv6 configuration is not taken as 'interface gone'" halow_ipv6_restore_all
assert_success "...the record is kept" halow_own_check ipv6_wlu1
reset_proc wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
mkdir -p "$HALOW_STATE_DIR/owns"; : > "$HALOW_STATE_DIR/owns/ipv6_wlu1.tmp.123"
halow_ipv6_restore_all >/dev/null 2>&1
assert_failure "a half-written record file is not taken for a record" halow_ipv6_present

echo "-- forget a vanished per-station interface --"
reset_proc wlu1.sta1
halow_ipv6_disable wlu1.sta1 >/dev/null 2>&1
assert_success "an interface that still exists keeps its record" halow_ipv6_forget_if_gone wlu1.sta1
assert_success "...(record kept)" halow_own_check ipv6_wlu1.sta1
assert_eq "1" "$(val wlu1.sta1)" "...and IPv6 stays off on it"
rm -rf "${CONF:?}/wlu1.sta1"
assert_success "a vanished interface's record is dropped" halow_ipv6_forget_if_gone wlu1.sta1
assert_failure "...(record gone)" halow_own_check ipv6_wlu1.sta1
assert_success "an interface without a record needs nothing" halow_ipv6_forget_if_gone wlu1.sta5

echo "-- a corrupted IFS (as inside an interrupted read loop) --"
reset_proc wlu1 halow-br0 wlu1.sta1
for i in wlu1 halow-br0 wlu1.sta1; do halow_ipv6_disable "$i" >/dev/null 2>&1; done
_rc=0; IFS='' halow_ipv6_restore_all >/dev/null 2>&1 || _rc=$?
assert_eq "0" "$_rc" "restore_all succeeds with IFS empty"
assert_eq "0 0 0" "$(val wlu1) $(val halow-br0) $(val wlu1.sta1)" "...and restored every interface"
assert_failure "...leaving no record" halow_ipv6_present

echo "-- strict shell options --"
reset_proc wlu1
CHILD="$HALOW_TEST_TMP/strict_ipv6.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_PROC_SYS_DIR="$PROC"
for lib in constants common ownership validate ipv6; do . "$HALOW_LIB_DIR/\$lib.sh"; done
halow_ipv6_disable wlu1
if halow_ipv6_disable wlu9; then echo missing=0; else echo missing=\$?; fi
if halow_ipv6_present; then echo present=0; else echo present=\$?; fi
halow_ipv6_restore_all
if halow_ipv6_present; then echo present2=0; else echo present2=\$?; fi
echo CHILD_REACHED_THE_END
EOF
_out="$(bash "$CHILD" 2>&1)"; _rc=$?
assert_eq "0" "$_rc" "the IPv6 functions run under errexit/nounset/pipefail/inherit_errexit"
assert_success "...a missing interface returns 1 without aborting" grep -q "missing=1" <<< "$_out"
assert_success "...present reports the record" grep -q "present=0" <<< "$_out"
assert_success "...and nothing after the restore" grep -q "present2=1" <<< "$_out"
assert_success "...the script reached its end" grep -q CHILD_REACHED_THE_END <<< "$_out"

halow_test_teardown
echo "test_ipv6: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
