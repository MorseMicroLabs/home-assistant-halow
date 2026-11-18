#!/usr/bin/env bash
# Tests common.sh's halow_wait_for_pattern: the primitive run uses to detect
# AP-ENABLED/AP-STA-CONNECTED from hostapd_s1g's own log file without depending on a
# particular control-socket API.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_common =="
halow_test_setup

logfile="$HALOW_TEST_TMP/hostapd.log"
: > "$logfile"

( sleep 2; echo "wlu1: AP-ENABLED" >> "$logfile" ) &
assert_success "wait_for_pattern succeeds once the pattern appears within the timeout" \
    halow_wait_for_pattern "$logfile" "AP-ENABLED" 10
wait

: > "$logfile"
assert_failure "wait_for_pattern times out when the pattern never appears" \
    halow_wait_for_pattern "$logfile" "AP-ENABLED" 2

# wait_for_pattern with a watch_pid: must detect the watched process exiting rather
# than waiting out the full timeout.
( sleep 1 ) &
watch_pid=$!
: > "$logfile"
assert_exit 2 "wait_for_pattern returns 2 promptly when the watched process exits first" \
    halow_wait_for_pattern "$logfile" "NEVER-APPEARS" 10 "$watch_pid"
wait "$watch_pid" 2>/dev/null || true

# --- dmesg watermark/since: scoping to "since this specific action" prevents a stale
# success message from an earlier, unrelated event being mistaken for the current
# one's result (the real defect class finding #7 of this change's own check named). ---
dmesg() { cat "$HALOW_TEST_TMP/fake_dmesg.log" 2>/dev/null; }
: > "$HALOW_TEST_TMP/fake_dmesg.log"
echo "[  100.000001] line1: an earlier, unrelated success message" >> "$HALOW_TEST_TMP/fake_dmesg.log"
echo "[  100.000002] line2: morse: bcf_boardtype_0807.bin loaded successfully" >> "$HALOW_TEST_TMP/fake_dmesg.log"

watermark="$(halow_dmesg_watermark)"
assert_eq "[  100.000002] line2: morse: bcf_boardtype_0807.bin loaded successfully" "$watermark" "the marker is the newest kernel-log record (a line count is not a position in an evicting ring; see test_bcf_verification.sh)"

echo "[  101.000003] line3: unrelated noise after the watermark" >> "$HALOW_TEST_TMP/fake_dmesg.log"
echo "[  101.000004] line4: morse: no matching bcf for this board type" >> "$HALOW_TEST_TMP/fake_dmesg.log"
since="$(halow_dmesg_since "$watermark")"
assert_eq "$(printf '[  101.000003] line3: unrelated noise after the watermark\n[  101.000004] line4: morse: no matching bcf for this board type')" "$since" \
    "dmesg_since returns only lines produced after the marker, excluding the stale earlier success"

unset -f dmesg

echo "== test_common (halow_derive_installed_slug) =="

assert_eq "local_morse_micro_halow_ap" "$(halow_derive_installed_slug "local-morse-micro-halow-ap")" \
    "a hyphenated hostname (Supervisor's own per-app hostname convention) is reversed to the real, repository-qualified slug"

assert_eq "morse_micro_halow_ap" "$(halow_derive_installed_slug "morse-micro-halow-ap")" \
    "a hostname with no repository prefix at all still reverses correctly"

assert_eq "already_has_underscores" "$(halow_derive_installed_slug "already_has_underscores")" \
    "a hostname with no hyphens at all is returned unchanged"

halow_test_teardown
echo "test_common: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
