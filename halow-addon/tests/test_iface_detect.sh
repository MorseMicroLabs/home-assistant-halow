#!/usr/bin/env bash
# Tests iface_detect.sh: zero/one/multiple dynamic WDS-interface candidates, using
# simulated `ip -o link show` output — exactly the technique an earlier manual test's own
# correction passes used for this same detection logic.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_iface_detect =="
halow_test_setup

links_zero='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
3: wlu1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'

links_one='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
3: wlu1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
4: wlu1.sta1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'

links_multi='1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
3: wlu1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
4: wlu1.sta1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
5: wlu1.sta2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'

assert_failure "zero WDS candidates fails safely (does not guess)" \
    halow_detect_wds_iface "wlu1" "$links_zero"

result="$(halow_detect_wds_iface "wlu1" "$links_one")"
assert_eq "wlu1.sta1" "$result" "exactly one WDS candidate is detected correctly"

assert_failure "multiple WDS candidates fails safely (does not guess)" \
    halow_detect_wds_iface "wlu1" "$links_multi"

# A plain interface-name prefix match (e.g. "wlu10") must not be confused with "wlu1"'s
# own WDS children — the match is anchored on the exact parent name.
links_similar_name='3: wlu1: <UP> mtu 1500
4: wlu10.sta1: <UP> mtu 1500'
assert_failure "a differently-named interface's own WDS child is not mistaken for wlu1's" \
    halow_detect_wds_iface "wlu1" "$links_similar_name"

# Regression test: the "." separator must be matched literally, never as "any character".
# An earlier implementation built a dynamic awk regex via `awk -v re=...`, which silently
# consumed the pattern's own backslash escape (the intended literal "\." became a plain
# "."), so a name with ANY character in the separator position — not just "." — would be
# wrongly accepted as a WDS interface. None of these must match.
links_non_literal_separator='3: wlu1: <UP> mtu 1500
4: wlu1Xsta1: <UP> mtu 1500
5: wlu1-sta1: <UP> mtu 1500
6: wlu1_sta1: <UP> mtu 1500'
assert_failure "a non-'.' separator (any single character) is never accepted as the WDS prefix join" \
    halow_detect_wds_iface "wlu1" "$links_non_literal_separator"


echo "== test_iface_detect: halow_detect_wds_iface_retry -- the 4-address WDS netdev may appear shortly AFTER AP-STA-CONNECTED; retry while NONE exists, never retry an ambiguous result =="
_ifd_calls="$HALOW_TEST_TMP/ip_calls"; echo 0 > "$_ifd_calls"; _ifd_appear_after=3; _ifd_mode=appear
sleep() { return 0; }
ip() {
    local n; n=$(( $(cat "$_ifd_calls") + 1 )); echo "$n" > "$_ifd_calls"
    case "$_ifd_mode" in
        appear)    [ "$n" -gt "$_ifd_appear_after" ] && echo '7: wlu1.sta1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500' ;;
        never)     : ;;
        ambiguous) printf '7: wlu1.sta1: <UP> mtu 1500\n8: wlu1.sta2: <UP> mtu 1500\n' ;;
    esac
    return 0
}
_ifd_mode=appear; echo 0 > "$_ifd_calls"
out="$(halow_detect_wds_iface_retry wlu1 10 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "an interface that appears after a few attempts is detected (rc 0)"
assert_eq "wlu1.sta1" "$out" "and the right name is printed"
assert_eq "4" "$(cat "$_ifd_calls")" "it looked 4 times: 3 misses then the hit"
_ifd_mode=never; echo 0 > "$_ifd_calls"
halow_detect_wds_iface_retry wlu1 5 >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "an interface that never appears fails with rc 1 after the bounded wait"
assert_eq "6" "$(cat "$_ifd_calls")" "bounded: 1 initial + 5 retries, no more"
_ifd_mode=ambiguous; echo 0 > "$_ifd_calls"
halow_detect_wds_iface_retry wlu1 5 >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "several candidates is rc 2 (refuse to guess)"
assert_eq "1" "$(cat "$_ifd_calls")" "an ambiguous result is NEVER retried"
unset -f ip sleep
assert_success "the manager derives the adapter's interface from its sysfs tree with a bounded wait (never a customer-entered name)" \
    bash -c 'grep -q "halow_adapter_netdev_wait" "$1" && grep -q "HALOW_IFACE=\"\$(halow_adapter_netdev)\"" "$1"' _ "$HALOW_LIB_DIR/manager.sh"

halow_test_teardown
echo "test_iface_detect: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
