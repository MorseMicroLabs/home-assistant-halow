#!/usr/bin/env bash
# Automatic channel selection wait against synthetic hostapd logs: completed, failed,
# timeout, hostapd exit, stale events from an earlier run, and frequency-based channel
# derivation. The event format follows the pinned hostap source (ACS-STARTED,
# "ACS-COMPLETED freq=<S1G kHz> channel=<n>", ACS-FAILED); it awaits live validation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_acs =="
radio_setup
export HALOW_RADIO_ACS_POLL_S=0.2

log="$HALOW_RUN_DIR/hostapd.log"
sleep 900 &
live_pid=$!
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null

wait_rc() { # wait_rc <timeout> [region] [skip]
    halow_radio_acs_wait "$log" "$live_pid" "$1" "${2:-}" "${3:-0}"
}

printf 'wlx0: interface state UNINITIALIZED->ACS\nwlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\n' > "$log"
wait_rc 5; rc=$?
assert_eq "0" "$rc" "a completion is reported as 0"
assert_eq "923500|43|43" "$HALOW_ACS_FREQ_KHZ|$HALOW_ACS_CHANNEL|$HALOW_ACS_REPORTED_CHANNEL" "frequency and channel parsed"

printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923000 channel=159\n' > "$log"
wait_rc 5; rc=$?
assert_eq "0" "$rc" "a completion with an HT-style channel number is still a completion"
assert_eq "923000|42|159" "$HALOW_ACS_FREQ_KHZ|$HALOW_ACS_CHANNEL|$HALOW_ACS_REPORTED_CHANNEL" "the S1G channel is derived from the frequency, not taken from the reported number"

printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=924 channel=44\n' > "$log"
wait_rc 5 AU; rc=$?
assert_eq "0|924000|44" "$rc|$HALOW_ACS_FREQ_KHZ|$HALOW_ACS_CHANNEL" "an integer MHz frequency is normalised to kHz"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=922.5 channel=41\n' > "$log"
wait_rc 5 AU; rc=$?
assert_eq "0|922500|41" "$rc|$HALOW_ACS_FREQ_KHZ|$HALOW_ACS_CHANNEL" "a decimal MHz frequency is normalised to kHz"

printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=903000 channel=2\n' > "$log"
wait_rc 5; rc=$?
assert_eq "1" "$rc" "a completion on a frequency outside the region's channels is not trusted (failure)"
assert_eq "" "$HALOW_ACS_CHANNEL" "no channel is reported for an untrusted completion"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=abc channel=43\n' > "$log"
wait_rc 5; rc=$?
assert_eq "1" "$rc" "a completion with a garbled frequency is a failure"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=5805 channel=161\n' > "$log"
wait_rc 5; rc=$?
assert_eq "1" "$rc" "an HT (5 GHz) frequency is not accepted as an S1G result"

printf 'wlx0: ACS-STARTED \nACS: Unable to collect survey data\nwlx0: ACS-FAILED \n' > "$log"
wait_rc 5; rc=$?
assert_eq "1" "$rc" "ACS-FAILED is reported as 1"
assert_eq "" "$HALOW_ACS_FREQ_KHZ$HALOW_ACS_CHANNEL" "no result values on failure"

printf 'wlx0: ACS-STARTED \n' > "$log"
t0=$SECONDS
wait_rc 1; rc=$?
assert_eq "2" "$rc" "no outcome within the timeout is reported as 2"
[ $((SECONDS - t0)) -ge 1 ]; assert_eq "0" "$?" "the timeout is honoured, not cut short"

# The upper bound is checked against a fake clock, so machine load cannot make it flaky:
# the fake sleep advances bash's SECONDS by one per poll and records each poll.
fake_clock_wait() { # fake_clock_wait <timeout> : sets FC_SLEEPS FC_ELAPSED FC_RC
    FC_SLEEPS=0
    sleep() { FC_SLEEPS=$((FC_SLEEPS + 1)); SECONDS=$((SECONDS + 1)); }
    local s0=$SECONDS
    HALOW_RADIO_ACS_POLL_S=1 halow_radio_acs_wait "$log" "$live_pid" "$1"; FC_RC=$?
    FC_ELAPSED=$((SECONDS - s0))
    unset -f sleep
}
fake_clock_wait 5
assert_eq "2" "$FC_RC" "fake clock: a timeout is reported as 2"
[ "$FC_SLEEPS" -ge 4 ] && [ "$FC_SLEEPS" -le 5 ]; assert_eq "0" "$?" "fake clock: the wait polls about once per second up to the timeout ($FC_SLEEPS polls)"
[ "$FC_ELAPSED" -le 6 ]; assert_eq "0" "$?" "fake clock: the wait ends within one poll after the timeout ($FC_ELAPSED s)"

# --- the per-poll hook (keeps a caller's heartbeat alive during long waits) --------------
HOOK_CALLS=0
acs_test_hook() { HOOK_CALLS=$((HOOK_CALLS + 1)); echo "hook output is discarded"; return 7; }
HOOK_CALLS=0
out="$(HALOW_RADIO_POLL_HOOK=acs_test_hook fake_clock_wait 3; printf '%s|%s|%s' "$FC_RC" "$FC_SLEEPS" "$HOOK_CALLS")"
IFS='|' read -r h_rc h_sleeps h_calls <<< "$out"
assert_eq "2" "$h_rc" "hook: a failing hook does not change the outcome"
assert_eq "$((h_sleeps + 1))" "$h_calls" "hook: called once per poll iteration ($h_calls calls, $h_sleeps sleeps)"
[ "$h_calls" -ge 3 ]; assert_eq "0" "$?" "hook: called on every iteration of a 3 s wait"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\n' > "$log"
HOOK_CALLS=0
HALOW_RADIO_POLL_HOOK=acs_test_hook halow_radio_acs_wait "$log" "$live_pid" 5 > "$HALOW_TEST_TMP/hook.out"; rc=$?
assert_eq "0|1" "$rc|$HOOK_CALLS" "hook: also called when the outcome is already there"
assert_eq "" "$(cat "$HALOW_TEST_TMP/hook.out")" "hook: its output never reaches the caller's stdout"
HALOW_RADIO_POLL_HOOK=no_such_function halow_radio_acs_wait "$log" "$live_pid" 5; rc=$?
assert_eq "0" "$rc" "hook: a name that is not a function is ignored"
HALOW_RADIO_POLL_HOOK='echo injected' halow_radio_acs_wait "$log" "$live_pid" 5 > "$HALOW_TEST_TMP/hook.out"; rc=$?
assert_eq "0|" "$rc|$(cat "$HALOW_TEST_TMP/hook.out")" "hook: a command string is never run"
( set -o errexit -o nounset -o pipefail; HALOW_RADIO_POLL_HOOK=acs_test_hook halow_radio_acs_wait "$log" "$live_pid" 5 >/dev/null; echo survived ) > "$HALOW_TEST_TMP/hook.out" 2>&1
assert_eq "survived" "$(cat "$HALOW_TEST_TMP/hook.out")" "hook: a failing hook is safe under errexit"

# --- the selected width (6th argument) ---------------------------------------------------
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\n' > "$log"
halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 4; rc=$?
assert_eq "1|" "$rc|$HALOW_ACS_CHANNEL" "width: an 8 MHz completion while 4 MHz is selected is a failure (fallback follows)"
case "$HALOW_ACS_REASON" in *"not a 4 MHz channel"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "width: the reason names the selected width ($HALOW_ACS_REASON)"
halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 8; rc=$?
assert_eq "0|43" "$rc|$HALOW_ACS_CHANNEL" "width: an 8 MHz completion (43 at 923.5 MHz) while 8 MHz is selected is accepted"
for pair in "1:923000:42" "2:922500:41" "4:921500:39" "8:923500:43"; do
    w="${pair%%:*}"; rest="${pair#*:}"; f="${rest%%:*}"; c="${rest#*:}"
    printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=%s channel=%s\n' "$f" "$c" > "$log"
    halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 "$w"; rc=$?
    assert_eq "0|$c" "$rc|$HALOW_ACS_CHANNEL" "width: $w MHz completion on $f kHz accepted as channel $c"
    other=1; [ "$w" = 1 ] && other=4
    halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 "$other"; rc=$?
    assert_eq "1" "$rc" "width: the same $w MHz completion is refused when $other MHz is selected"
done
# Full matrix against the explicit 2024 AU tables (helpers_radio.sh): every channel's frequency
# is accepted at its own width and refused at every other width; frequencies of the
# earlier 2020 numbering that are no channel at that width (and the band edges) are refused.
matrix_bad=""
for w in 1 2 4 8; do
    i=0
    set -- ${RADIO_EXPECT_FREQS[$w]}
    for c in ${RADIO_EXPECT_CHANNELS[$w]}; do
        i=$((i + 1)); eval "f=\${$i}"
        printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=%s channel=%s\n' "$f" "$((c + 100))" > "$log"
        for sel in 1 2 4 8; do
            halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 "$sel"; rc=$?
            if [ "$sel" = "$w" ]; then
                { [ "$rc" = 0 ] && [ "$HALOW_ACS_CHANNEL" = "$c" ] && [ "$HALOW_ACS_FREQ_KHZ" = "$f" ]; } || matrix_bad="$matrix_bad ok:$w/$c@$sel"
            else
                [ "$rc" = 1 ] || matrix_bad="$matrix_bad bad:$w/$c@$sel"
            fi
        done
    done
done
assert_eq "" "$matrix_bad" "width matrix: every 2024 AU channel frequency is accepted only at its own width"
edge_bad=""
for f in 915000 915500 927500 928000 903000 922750; do
    printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=%s channel=1\n' "$f" > "$log"
    for sel in "" 1 2 4 8; do
        halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 "$sel"; rc=$?
        [ "$rc" = 1 ] || edge_bad="$edge_bad $f@${sel:-any}"
    done
done
assert_eq "" "$edge_bad" "frequencies of removed channels 27/51 and off-grid values are refused at every width"
halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 x; rc=$?
assert_eq "1" "$rc" "width: a garbled width is refused"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\n' > "$log"
halow_radio_acs_wait "$log" "$live_pid" 5 AU 0 ""; rc=$?
assert_eq "0" "$rc" "width: an empty width keeps the earlier behaviour (any width of the region)"

rm -f "$log"
wait_rc 1; rc=$?
assert_eq "2" "$rc" "a missing log with a live process times out"

printf 'wlx0: ACS-STARTED \n' > "$log"
halow_radio_acs_wait "$log" "$dead_pid" 5; rc=$?
assert_eq "3" "$rc" "hostapd exiting without a result is reported as 3"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-FAILED \n' > "$log"
halow_radio_acs_wait "$log" "$dead_pid" 5; rc=$?
assert_eq "1" "$rc" "an ACS-FAILED written before hostapd exited is still reported as a failure"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\n' > "$log"
halow_radio_acs_wait "$log" "$dead_pid" 5; rc=$?
assert_eq "0" "$rc" "a completion written before hostapd exited is still reported"

# Stale events from an earlier run in the same log.
printf 'wlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=923500 channel=43\nwlx0: ACS-STARTED \n' > "$log"
wait_rc 1; rc=$?
assert_eq "2" "$rc" "a completion before the latest ACS-STARTED does not count"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-FAILED \nwlx0: ACS-STARTED \nwlx0: ACS-COMPLETED freq=926000 channel=48\n' > "$log"
wait_rc 5; rc=$?
assert_eq "0|48" "$rc|$HALOW_ACS_CHANNEL" "only the outcome after the latest ACS-STARTED counts"
printf 'wlx0: ACS-COMPLETED freq=923500 channel=43\nwlx0: interface state ENABLED->DISABLED\n' > "$log"
wait_rc 1 "" 1; rc=$?
assert_eq "2" "$rc" "lines before the given start line do not count"

# An outcome that arrives while waiting.
printf 'wlx0: ACS-STARTED \n' > "$log"
( sleep 1; printf 'wlx0: ACS-COMPLETED freq=918000 channel=32\n' >> "$log" ) &
writer=$!
t0=$SECONDS
wait_rc 10; rc=$?
wait "$writer" 2>/dev/null
assert_eq "0|32" "$rc|$HALOW_ACS_CHANNEL" "a completion that arrives while waiting is picked up"
[ $((SECONDS - t0)) -lt 9 ]; assert_eq "0" "$?" "the wait returns before its 10 s timeout once the completion arrives"

# No pid: only the log and the timeout matter.
printf 'wlx0: ACS-STARTED \n' > "$log"
halow_radio_acs_wait "$log" "" 1; rc=$?
assert_eq "2" "$rc" "without a pid the wait still times out"

halow_radio_acs_wait "$log" "$live_pid" 0; rc=$?
assert_eq "1" "$rc" "a zero timeout is refused"
halow_radio_acs_wait "$log" "$live_pid" abc; rc=$?
assert_eq "1" "$rc" "a non-numeric timeout is refused"

kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null
halow_test_teardown
radio_summary test_radio_acs
