#!/usr/bin/env bash
# Tests allowlist.sh: entry format, port range, duplicates, the entry bound, the
# denylist (SSH, the host's developer SSH port, the Supervisor observer port, the Ingress
# range) and the one-line "<entry>: <reason>" report.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup

echo "== test_allowlist =="

assert_success "an empty list is valid" halow_allowlist_validate
assert_success "an empty string is valid" halow_allowlist_validate ""
assert_success "tcp and udp entries are valid" halow_allowlist_validate tcp/1883 udp/5683
assert_success "Home Assistant's own port is allowed" halow_allowlist_validate tcp/8123
assert_success "80 and 443 are allowed (reverse-proxy add-ons)" halow_allowlist_validate tcp/80 tcp/443
assert_success "entries in one comma/space separated argument" halow_allowlist_validate "tcp/1883, udp/5683 tcp/8883"
assert_success "port 1 and 65535 are valid" halow_allowlist_validate tcp/1 udp/65535
assert_success "61999 and 65501 (outside the Ingress range) are valid" halow_allowlist_validate tcp/61999 tcp/65501
assert_success "the same port with different protocols is valid" halow_allowlist_validate tcp/1883 udp/1883

check_reject() { # check_reject <msg> <expected entry> <args…>
    local msg="$1" exp="$2" out rc
    shift 2
    out="$(halow_allowlist_validate "$@")"; rc=$?
    assert_eq "1" "$rc" "$msg: rejected"
    assert_eq "$exp" "${out%%:*}" "$msg: the offending entry is named"
    assert_success "$msg: a reason is given" test -n "${out#*: }" -a "${out#*: }" != "$out"
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "$msg: exactly one line on stdout"
}
check_reject "SSH" tcp/22 tcp/1883 tcp/22
check_reject "SSH over udp" udp/22 udp/22
check_reject "developer SSH" tcp/22222 tcp/22222
check_reject "Supervisor observer" tcp/4357 tcp/4357
check_reject "Ingress range start" tcp/62000 tcp/62000
check_reject "Ingress range end" udp/65500 udp/65500
check_reject "Ingress range middle" tcp/63210 tcp/63210
check_reject "port 0" tcp/0 tcp/0
check_reject "port above 65535" tcp/65536 tcp/65536
check_reject "huge port" tcp/9999999999 tcp/9999999999
check_reject "leading zero" tcp/0080 tcp/0080
check_reject "no port" tcp/ tcp/
check_reject "non-numeric port" tcp/http tcp/http
check_reject "unknown protocol" sctp/80 sctp/80
check_reject "upper case protocol" TCP/80 TCP/80
check_reject "missing protocol" 80 80
check_reject "port range syntax" tcp/80-90 tcp/80-90
check_reject "duplicate" tcp/1883 tcp/1883 udp/1 tcp/1883
check_reject "shell metacharacters" 'tcp/80;rm' 'tcp/80;rm'

many=""
for p in $(seq 1000 1032); do many="$many tcp/$p"; done
out="$(halow_allowlist_validate $many)"; rc=$?
assert_eq "1" "$rc" "33 entries exceed the bound of 32"
assert_success "the bound is reported" grep -q "more than 32" <<< "$out"
many=""
for p in $(seq 1000 1031); do many="$many tcp/$p"; done
assert_success "32 entries are within the bound" halow_allowlist_validate $many

assert_eq "tcp/1
udp/2
tcp/3" "$(halow_allowlist_entries "tcp/1,udp/2" " tcp/3 ")" "entries are split on commas and whitespace"
assert_eq "" "$(halow_allowlist_entries "")" "no entries from an empty string"
assert_eq "" "$(halow_allowlist_validate tcp/1883 2>&1)" "a valid list prints nothing"

halow_test_teardown
echo "test_allowlist: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
