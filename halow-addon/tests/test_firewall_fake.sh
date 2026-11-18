#!/usr/bin/env bash
# Tests the fake iptables/ip6tables itself, so the firewall suites rest on a fake whose
# exit codes and ordering match the real tool where the product depends on them.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./fakes/fw_helpers.sh
fw_fake_setup

echo "== test_firewall_fake =="
I="$HALOW_IPTABLES"
assert_exit 1 "-C on an absent rule returns 1" "$I" -w -C INPUT -j ACCEPT
assert_exit 0 "-A appends" "$I" -w -A INPUT -i lo -j ACCEPT
assert_exit 0 "-C on a present rule returns 0" "$I" -w -C INPUT -i lo -j ACCEPT
assert_exit 1 "-N of an existing chain returns 1" "$I" -w -N INPUT
assert_exit 0 "-N creates a chain" "$I" -w -N T1
assert_exit 1 "-N of a chain that now exists returns 1" "$I" -w -N T1
assert_exit 2 "a jump to a missing chain is refused" "$I" -w -A INPUT -j NOPE
assert_exit 0 "-A to the new chain" "$I" -w -A T1 -j DROP
assert_exit 0 "-I at position 1" "$I" -w -I INPUT 1 -j T1
assert_eq "-j T1
-i lo -j ACCEPT" "$(fw_rules iptables filter INPUT)" "-I placed the rule first"
assert_exit 0 "-I at the end position" "$I" -w -I INPUT 3 -p tcp -j ACCEPT
assert_exit 1 "-I beyond the end returns 1" "$I" -w -I INPUT 9 -j ACCEPT
assert_exit 1 "-X of a non-empty chain returns 1" "$I" -w -X T1
assert_exit 0 "-F of a user chain" "$I" -w -F T1
assert_exit 1 "-X of a referenced chain returns 1" "$I" -w -X T1
assert_exit 0 "-D by spec" "$I" -w -D INPUT -j T1
assert_exit 1 "-D of an absent rule returns 1" "$I" -w -D INPUT -j T1
assert_exit 0 "-X of an empty, unreferenced chain" "$I" -w -X T1
assert_exit 1 "-S of a deleted chain returns 1" "$I" -w -S T1
assert_exit 2 "-X of a built-in chain is refused" "$I" -w -X INPUT
assert_exit 0 "-D by number" "$I" -w -D INPUT 2
assert_exit 1 "-D by a number out of range returns 1" "$I" -w -D INPUT 5
assert_eq "-A INPUT -i lo -j ACCEPT" "$("$I" -w -S INPUT 1)" "-S <chain> <n> prints one rule"
assert_exit 3 "an unknown table returns 3" "$I" -w -t mangle2 -S
assert_exit 1 "the nat table has POSTROUTING (-C of an absent rule there returns 1, not a chain error)" "$I" -w -t nat -C POSTROUTING -j ACCEPT
assert_exit 0 "the nat table accepts MASQUERADE in POSTROUTING" "$I" -w -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE
assert_exit 0 "-L -n lists" "$I" -w -L -n
assert_eq "-P INPUT ACCEPT" "$("$I" -w -S INPUT | sed -n 1p)" "-S prints the policy first for a built-in chain"
HALOW_FAKE_FW_FAIL_MATCH="-A INPUT -j DROP" assert_exit 4 "injected failure by match" "$I" -w -A INPUT -j DROP
assert_eq "0" "$(fw_rules iptables filter INPUT | grep -c -- '-j DROP')" "an injected failure changes nothing"
assert_success "ip6tables keeps separate state" test -z "$(fw_rules ip6tables filter INPUT)"
"$HALOW_IP6TABLES" -w -S >/dev/null
assert_success "the log records the invoked name" grep -q '^ip6tables -w -S$' "$HALOW_FAKE_FW_DIR/log"
assert_exit 0 "-w with a number of seconds is accepted" "$I" -w 5 -S INPUT
HALOW_FAKE_FW_LOCK_HELD=1 assert_exit 4 "lock held: a bounded wait (-w 5) gives up at once with 4" "$I" -w 5 -S
_t0=$SECONDS
HALOW_FAKE_FW_LOCK_HELD=1 HALOW_FAKE_FW_HANG_S=2 assert_exit 4 "lock held: a bare -w waits (the modelled hang) and then fails" "$I" -w -S
assert_success "...and it really waited" test $((SECONDS - _t0)) -ge 1
assert_eq "1" "$(grep -c '^LOCK-HANG$' "$HALOW_FAKE_FW_DIR/log")" "...recorded as a hang in the log"

halow_test_teardown
echo "test_firewall_fake: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
