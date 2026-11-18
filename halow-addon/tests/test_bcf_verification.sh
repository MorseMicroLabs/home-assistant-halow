#!/usr/bin/env bash
# Focused tests for the board-file (BCF) verification after the morse driver load:
#   * the kernel-log marker / "records since the marker" mechanism (common.sh), which
#     replaced a line-count watermark that the kernel log ring defeated (observed on a long-running
#     device: the ring evicts old lines, so the line count shrank or stood still
#     while new records existed, the slice came out empty and every start failed closed);
#   * the BCF decision itself (module_load.sh halow_check_bcf_match): only the driver's own
#     "Loaded BCF from <name>, size <n>, crc32 <x>" record of THIS attempt, naming the
#     placed board file with its size and CRC-32, is evidence; the generic later record
#     "Driver loaded with kernel module parameters" never is.
# The record formats below are the real ones (measured kernel log of the reference device).
#
# Mutation check: HALOW_BCF_TEST_MUTANT=<file> sources that file after the libraries, so a
# deliberately broken or the old implementation can be run against this suite to prove every
# test here can fail (mutants were run by hand when the suite was written). It is unset in normal runs.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_bcf_verification =="
# Labs release tree: the board file is a staged binary artifact (not committed). Without it
# this suite cannot run; a skip is not a pass (run_tests.sh counts and lists it).
if [ ! -f "$(cd .. && pwd)/artifacts/bcf/bcf_boardtype_0807.bin" ]; then
    echo "SKIPPED: ../artifacts/bcf/bcf_boardtype_0807.bin is not staged (run build.sh with the verified artifact bundle first)"
    exit 77
fi
halow_test_setup
[ -n "${HALOW_BCF_TEST_MUTANT:-}" ] && . "$HALOW_BCF_TEST_MUTANT"

# The real board file the add-on ships, and the values the driver logged for it on the
# reference device ("Loaded BCF from morse/bcf_boardtype_0807.bin, size 2510, crc32 0xc8af8c0d").
BCF_NAME="bcf_boardtype_0807.bin"
BCF="$(cd .. && pwd)/artifacts/bcf/$BCF_NAME"
BCF_SIZE=2510
BCF_CRC="0xc8af8c0d"
FW_REC="morse_usb 1-1:1.0: Loaded firmware from morse/mm8108b2-rl.bin, size 501348, crc32 0x5152467b"
DRV_REC="morse_usb 1-1:1.0: Driver loaded with kernel module parameters"

# rec <seconds> <micro> <text> — one kernel-log line in dmesg's format
rec() { printf '[%7d.%06d] %s\n' "$1" "$2" "$3"; }
# load_records <seconds> [<bcf_name> <size> <crc>] — the driver's records of one load, with
# the genuine values unless overridden; load_records_nobcf has the generic record only
load_records() {
    local t="$1" name="${2:-$BCF_NAME}" size="${3:-$BCF_SIZE}" crc="${4:-$BCF_CRC}"
    rec "$t" 543372 "morse micro driver registration. Version 0-rel_mm8108_2_1_0_2026_Jul_01"
    rec "$t" 543534 "morse_usb 1-1:1.0: USB Morse device now attached to Morse driver (minor=-1)"
    rec "$t" 561224 "$FW_REC"
    rec "$t" 561563 "morse_usb 1-1:1.0: Loaded BCF from morse/$name, size $size, crc32 $crc"
    rec "$((t + 1))" 531837 "$DRV_REC"
}
load_records_nobcf() {
    local t="$1"
    rec "$t" 543372 "morse micro driver registration. Version 0-rel_mm8108_2_1_0_2026_Jul_01"
    rec "$t" 561224 "$FW_REC"
    rec "$((t + 1))" 531837 "$DRV_REC"
}
noise() { local i; for (( i = 0; i < $2; i++ )); do rec "$(( $1 + i ))" 100000 "hassio: port 5(vethf120b12) entered forwarding state"; done; }

LOG="$HALOW_TEST_TMP/fake_klog"
dmesg() { cat "$LOG" 2>/dev/null; }

# ------------------------------------------------------------------ CRC-32 helper
echo "-- halow_crc32_file: the driver's CRC-32 form, checked against the measured live value --"
assert_eq "$BCF_CRC" "$(halow_crc32_file "$BCF")" "the shipped BCF's CRC-32 equals the one the driver logged on the reference device"
printf '123456789' > "$HALOW_TEST_TMP/check.bin"
assert_eq "0xcbf43926" "$(halow_crc32_file "$HALOW_TEST_TMP/check.bin")" "the CRC-32 of '123456789' is the standard check value"
: > "$HALOW_TEST_TMP/empty.bin"
assert_eq "0x00000000" "$(halow_crc32_file "$HALOW_TEST_TMP/empty.bin")" "the CRC-32 of an empty file is zero"
assert_failure "an unreadable file has no CRC-32 (fail closed)" halow_crc32_file "$HALOW_TEST_TMP/does-not-exist"

# ------------------------------------------------------------------ timestamp parsing
echo "-- halow_klog_ts_us --"
assert_eq "203561224" "$(halow_klog_ts_us "[  203.561224] morse_usb 1-1:1.0: x")" "a padded kernel timestamp is read in microseconds"
assert_eq "1000000" "$(halow_klog_ts_us "[    1.000000] x")" "one second"
assert_failure "a line without a kernel timestamp has none" halow_klog_ts_us "morse_usb: no timestamp here"

# ------------------------------------------------------------------ marker -> records (pure)
echo "-- halow_klog_after_marker: normal append --"
{ noise 10 5; } > "$HALOW_TEST_TMP/pre"
marker="$(tail -n 1 "$HALOW_TEST_TMP/pre")"
{ cat "$HALOW_TEST_TMP/pre"; load_records 300; } > "$HALOW_TEST_TMP/post"
got="$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")")"
assert_eq "$(load_records 300)" "$got" "exactly the records written after the marker are returned"
assert_eq "5" "$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")" | wc -l | tr -d ' ')" "and nothing before it"
assert_eq "" "$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/pre")")" "no new records after the marker gives an empty window, status 0"
assert_success "an empty window is a success status (the BCF decision then fails it)" halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/pre")"

echo "-- halow_klog_after_marker: ring wrap / truncation --"
# The measured live case: the ring is full, so each new record evicts the oldest; the log
# has FEWER lines afterwards although new records exist. The marker is still there.
{ noise 10 30; } > "$HALOW_TEST_TMP/pre"
before_lines="$(wc -l < "$HALOW_TEST_TMP/pre" | tr -d ' ')"
marker="$(tail -n 1 "$HALOW_TEST_TMP/pre")"
{ cat "$HALOW_TEST_TMP/pre"; load_records 300; } | tail -n +"$(( 5 + 8 ))" > "$HALOW_TEST_TMP/post"   # 12 oldest lines evicted, 5 added
after_lines="$(wc -l < "$HALOW_TEST_TMP/post" | tr -d ' ')"
assert_eq "yes" "$([ "$after_lines" -lt "$before_lines" ] && echo yes || echo no)" "precondition: the line count SHRANK ($before_lines -> $after_lines), as measured on the reference device"
assert_eq "$(load_records 300)" "$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")")" "the new records are still found exactly, despite the shrunken line count"
# The marker itself evicted: the records between it and the first survivor are unknown.
{ noise 10 30; load_records 300; } | tail -n +"$(( 30 + 3 ))" > "$HALOW_TEST_TMP/post"   # oldest 32 gone, incl. the marker
assert_exit 2 "a marker older than the oldest retained record fails closed (status 2)" \
    halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")"
assert_eq "" "$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")" 2>/dev/null)" "and returns no records to be mistaken for evidence"
# A log that was cleared by someone else (dmesg -c) during the load behaves the same.
assert_exit 2 "a cleared log (marker gone) fails closed" \
    halow_klog_after_marker "$marker" "$(load_records 300)"

echo "-- halow_klog_after_marker: repeated identical messages, bad markers, foreign logs --"
# Earlier loads left identical record texts (different timestamps) in the log. The marker
# is a whole line, timestamp included, so earlier look-alikes cannot move the window.
{ load_records 100; noise 120 3; } > "$HALOW_TEST_TMP/pre"
marker="$(tail -n 1 "$HALOW_TEST_TMP/pre")"
{ cat "$HALOW_TEST_TMP/pre"; load_records_nobcf 300; } > "$HALOW_TEST_TMP/post"
assert_eq "$(load_records_nobcf 300)" "$(halow_klog_after_marker "$marker" "$(cat "$HALOW_TEST_TMP/post")")" "records of an earlier load before the marker are excluded even though their texts repeat"
# The same marker text twice (identical timestamp and text): the later one is used, never
# an earlier one, so the window can only shrink (fail closed), never widen.
{ rec 50 1 "dup"; rec 51 1 "between"; rec 50 1 "dup"; rec 60 1 "after"; } > "$HALOW_TEST_TMP/dup"
assert_eq "$(rec 60 1 after | tr -d '\n')" "$(halow_klog_after_marker "$(rec 50 1 dup | tr -d '\n')" "$(cat "$HALOW_TEST_TMP/dup")")" "with a duplicated marker line the LAST occurrence anchors the window"
assert_exit 1 "an empty marker is unusable (fail closed)" halow_klog_after_marker "" "$(cat "$HALOW_TEST_TMP/post")"
assert_exit 1 "a marker without a kernel timestamp is unusable (it could be any repeated line)" \
    halow_klog_after_marker "Driver loaded with kernel module parameters" "$(printf 'Driver loaded with kernel module parameters\nx\n')"
{ rec 400 0 "marker line"; rec 10 5 "record from a different boot"; } > "$HALOW_TEST_TMP/boot"
assert_exit 3 "a record after the marker that is older than the marker (reboot / different log) fails closed" \
    halow_klog_after_marker "$(rec 400 0 "marker line" | tr -d '\n')" "$(cat "$HALOW_TEST_TMP/boot")"

echo "-- halow_klog_after_marker: tolerance for timestamp inversions (SMP printk, coarse clock sync) --"
# printk stamps a record before it takes its place in the ring, so a stored-later record can
# carry a slightly older timestamp; up to HALOW_KLOG_SKEW_US (100000 us = 100 ms) is accepted.
# The marker must still be a whole timestamped line, so this is only a secondary detector.
tm="$(rec 400 0 "marker line" | tr -d '\n')"
nl=$'\n'
assert_eq "100000" "${HALOW_KLOG_SKEW_US}" "the documented tolerance is 100000 microseconds (100 ms)"
assert_exit 0 "a later-stored record exactly at the tolerance (100000 us older) is accepted" \
    halow_klog_after_marker "$tm" "${tm}${nl}$(rec 399 900000 "inverted by 100000 us")"
assert_exit 0 "a later-stored record 1 us inside the tolerance is accepted" \
    halow_klog_after_marker "$tm" "${tm}${nl}$(rec 399 900001 "inverted by 99999 us")"
assert_exit 3 "a later-stored record 1 us outside the tolerance (100001 us older) fails closed" \
    halow_klog_after_marker "$tm" "${tm}${nl}$(rec 399 899999 "inverted by 100001 us")"
# a log cleared and refilled with clearly older timestamps, containing the same marker text
{ printf '%s\n' "$tm"; noise 5 4; } > "$HALOW_TEST_TMP/refilled"
assert_exit 3 "a log that restarted with clearly older timestamps after an identical marker line fails closed" \
    halow_klog_after_marker "$tm" "$(cat "$HALOW_TEST_TMP/refilled")"
{ noise 5 4; } > "$HALOW_TEST_TMP/refilled"
assert_exit 2 "a log refilled with older timestamps and no marker line fails closed" \
    halow_klog_after_marker "$tm" "$(cat "$HALOW_TEST_TMP/refilled")"

# ------------------------------------------------------------------ the readers
echo "-- halow_dmesg_watermark / halow_dmesg_since (thin readers over dmesg) --"
{ noise 10 3; } > "$LOG"
assert_eq "$(noise 12 1 | tr -d '\n')" "$(halow_dmesg_watermark)" "the marker is the newest record, whole line"
printf '%s\n\n' "$(noise 20 1 | tr -d '\n')" > "$LOG"
assert_eq "$(noise 20 1 | tr -d '\n')" "$(halow_dmesg_watermark)" "trailing blank lines do not hide the newest record"
: > "$LOG"
assert_failure "an empty kernel log gives no marker (fail closed)" halow_dmesg_watermark
printf 'a line without a timestamp\n' > "$LOG"
assert_failure "a log in which no record has a kernel timestamp gives no marker (fail closed)" halow_dmesg_watermark
{ noise 10 2; printf 'continuation line without a timestamp
'; } > "$LOG"
assert_eq "$(noise 11 1 | tr -d '
')" "$(halow_dmesg_watermark)" "a newest line without a timestamp does not prevent a marker: the newest TIMESTAMPED record is used"
marker="$(halow_dmesg_watermark)"; { load_records 300; printf 'another continuation line
'; } >> "$LOG"
assert_eq "$(printf 'continuation line without a timestamp
'; load_records 300; printf 'another continuation line')" "$(halow_dmesg_since "$marker")" "the untimestamped line after the marker is simply part of the window"
assert_success "and the genuine records after such a marker are accepted" halow_check_bcf_match "$(halow_dmesg_since "$marker")" "$BCF"
dmesg() { return 1; }
assert_failure "an unreadable kernel log gives no marker" halow_dmesg_watermark
# VALID marker and a dmesg that fails: only the unreadable-dmesg branch can produce status 1
# here (an invalid marker or an empty log would fail through other branches).
valid_marker="$(noise 1 1 | tr -d '\n')"
assert_exit 1 "an unreadable kernel log gives no records (valid marker, dmesg exits non-zero): status 1" halow_dmesg_since "$valid_marker"
assert_eq "" "$(halow_dmesg_since "$valid_marker" 2>/dev/null)" "and prints no records"
assert_eq "[halow] kernel-log: the kernel log (dmesg) cannot be read" "$(halow_dmesg_since "$valid_marker" 2>&1 >/dev/null)" "and says why on stderr"
dmesg() { cat "$LOG" 2>/dev/null; }
echo "-- the reason survives a command substitution (HALOW_KLOG_REASON_FILE) --"
RF="$HALOW_TEST_TMP/klog_reason"
{ noise 10 3; } > "$LOG"
marker="$(halow_dmesg_watermark)"
{ noise 50 3; } > "$LOG"
rm -f "$RF"; HALOW_KLOG_REASON_FILE="$RF"; res="$(halow_dmesg_since "$marker" 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "marker lost: status 2 through a command substitution"
assert_eq "yes" "$(grep -q 'no longer in the kernel log' "$RF" && echo yes)" "marker lost: the concrete reason reached the reason file"
: > "$LOG"; rm -f "$RF"
res="$(halow_dmesg_watermark 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "empty log: no marker (status 1)"
assert_eq "yes" "$(grep -q 'no usable marker' "$RF" && echo yes)" "empty log: the concrete reason reached the reason file"
printf 'plain line one\nplain line two\n' > "$LOG"; rm -f "$RF"
res="$(halow_dmesg_watermark 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "log without any kernel timestamp: no marker (status 1)"
assert_eq "yes" "$(grep -q 'no record has a kernel timestamp' "$RF" && echo yes)" "no timestamp: the concrete reason reached the reason file"
rm -f "$RF"; { noise 10 3; } > "$LOG"; marker="$(halow_dmesg_watermark)"; load_records 300 >> "$LOG"
res="$(halow_dmesg_since "$marker" 2>/dev/null)"
assert_eq "no" "$([ -e "$RF" ] && echo yes || echo no)" "a successful read writes no reason file"
unset HALOW_KLOG_REASON_FILE
{ noise 10 3; } > "$LOG"
marker="$(halow_dmesg_watermark)"
load_records 300 >> "$LOG"
assert_eq "$(load_records 300)" "$(halow_dmesg_since "$marker")" "since returns the records written after the marker"
: > "$LOG"
assert_exit 2 "since fails closed (2) when the marker is no longer in the log" halow_dmesg_since "$marker"
assert_exit 1 "since fails closed (1) without a marker" halow_dmesg_since ""

# ------------------------------------------------------------------ the BCF decision (pure)
echo "-- halow_check_bcf_match: only the driver's own Loaded-BCF record for the placed file --"
assert_success "the genuine records of a load (real format and values) are accepted" \
    halow_check_bcf_match "$(load_records 300)" "$BCF"
assert_success "a CRC-32 printed in upper case / without leading zeros is compared numerically" \
    halow_check_bcf_match "$(load_records 300 "$BCF_NAME" "$BCF_SIZE" 0xC8AF8C0D)" "$BCF"
assert_failure "the generic later 'Driver loaded with kernel module parameters' record alone is not evidence" \
    halow_check_bcf_match "$(load_records_nobcf 300)" "$BCF"
assert_failure "that record after an earlier line that merely mentions BCF is not evidence either (the old glob matched this)" \
    halow_check_bcf_match "$({ rec 300 1 "morse micro driver registration. Version 0-rel"; rec 300 2 "morse_usb 1-1:1.0: BCF file requested: morse/$BCF_NAME"; rec 301 1 "$DRV_REC"; })" "$BCF"
assert_failure "a different board file NAME is rejected" \
    halow_check_bcf_match "$(load_records 300 bcf_boardtype_0999.bin)" "$BCF"
assert_failure "a different SIZE is rejected" \
    halow_check_bcf_match "$(load_records 300 "$BCF_NAME" 2511)" "$BCF"
assert_failure "a different CRC-32 is rejected" \
    halow_check_bcf_match "$(load_records 300 "$BCF_NAME" "$BCF_SIZE" 0xdeadbeef)" "$BCF"
assert_failure "a record for the right file name from a stale/different file (size AND crc differ) is rejected" \
    halow_check_bcf_match "$(load_records 300 "$BCF_NAME" 6 0x12345678)" "$BCF"
assert_failure "when the window holds a matching AND a non-matching BCF record, the mismatch fails it" \
    halow_check_bcf_match "$({ load_records 300; rec 302 1 "morse_usb 1-1:1.0: Loaded BCF from morse/other.bin, size 10, crc32 0x1"; })" "$BCF"
assert_failure "the explicit negative record is a hard failure even next to a matching record" \
    halow_check_bcf_match "$({ load_records 300; rec 302 1 "morse_usb 1-1:1.0: no matching bcf for this board type"; })" "$BCF"
assert_failure "'BCF ... not found' is a hard failure" \
    halow_check_bcf_match "$({ load_records_nobcf 300; rec 302 1 "morse_usb 1-1:1.0: BCF morse/$BCF_NAME not found"; })" "$BCF"
assert_failure "a matching BCF record from a source that is not the morse driver is rejected" \
    halow_check_bcf_match "$({ rec 300 1 "morse micro driver registration. Version 0-rel"; rec 300 2 "someotherdev 1-1: Loaded BCF from morse/$BCF_NAME, size $BCF_SIZE, crc32 $BCF_CRC"; })" "$BCF"
assert_failure "a matching BCF record BEFORE the morse initialisation record of the window is not this load's" \
    halow_check_bcf_match "$({ rec 299 1 "morse_usb 1-1:1.0: Loaded BCF from morse/$BCF_NAME, size $BCF_SIZE, crc32 $BCF_CRC"; load_records_nobcf 300; })" "$BCF"
assert_failure "no record of the morse module initialisation in the window: rejected" \
    halow_check_bcf_match "$(rec 300 1 "morse_usb 1-1:1.0: Loaded BCF from morse/$BCF_NAME, size $BCF_SIZE, crc32 $BCF_CRC")" "$BCF"
assert_failure "an empty window is rejected" halow_check_bcf_match "" "$BCF"
assert_failure "unrelated text is rejected" halow_check_bcf_match "some unrelated kernel message" "$BCF"
assert_failure "without the placed board file to compare with, nothing is accepted" halow_check_bcf_match "$(load_records 300)"
assert_failure "an unreadable placed board file is rejected" halow_check_bcf_match "$(load_records 300)" "$HALOW_TEST_TMP/missing.bin"
halow_check_bcf_match "$(load_records 300 "$BCF_NAME" 2511)" "$BCF"
assert_eq "yes" "$(case "$HALOW_BCF_REASON" in *"different board file"*) echo yes ;; esac)" "the failure reason names the mismatch"

# ------------------------------------------------------------------ end to end (marker -> load -> since -> decision)
echo "-- attempts end to end: marker, simulated load, window, decision --"
# attempt <appender...> — takes the marker, runs the appender (the simulated load), reads the window, decides
attempt() {
    local m w
    m="$(halow_dmesg_watermark 2>/dev/null)" || return 11
    "$@"
    w="$(halow_dmesg_since "$m" 2>/dev/null)" || return 12
    halow_check_bcf_match "$w" "$BCF"
}
ap_good()        { load_records "${T:-300}" >> "$LOG"; }
ap_nobcf()       { load_records_nobcf "${T:-300}" >> "$LOG"; }
ap_wrongbcf()    { load_records "${T:-300}" "$BCF_NAME" "$BCF_SIZE" 0xdeadbeef >> "$LOG"; }
ap_good_wrap()   { load_records "${T:-300}" >> "$LOG"; tail -n +9 "$LOG" > "$LOG.t"; mv "$LOG.t" "$LOG"; }   # 8 oldest evicted, 5 added: net shrink
ap_wipe()        { : > "$LOG"; load_records "${T:-300}" >> "$LOG"; }   # log cleared during the load

{ noise 10 40; } > "$LOG"
assert_exit 0  "normal append: the current load's own BCF record is accepted" attempt ap_good
{ noise 10 40; } > "$LOG"
assert_exit 0  "ring wrap: accepted although the kernel log has fewer lines than before the load" attempt ap_good_wrap
{ noise 10 40; } > "$LOG"
assert_exit 1  "missing current evidence: the load produced no BCF record, only the generic driver message" attempt ap_nobcf
{ noise 10 40; } > "$LOG"
assert_exit 1  "a BCF record for a different file/CRC is rejected" attempt ap_wrongbcf
{ noise 10 40; } > "$LOG"
assert_exit 12 "the log is cleared during the load: marker lost, fail closed" attempt ap_wipe
: > "$LOG"
assert_exit 11 "an empty log before the load: no marker, fail closed" attempt ap_good

echo "-- repeated prior messages: earlier loads' genuine records must not satisfy a current attempt --"
{ noise 10 20; load_records 100; noise 120 20; load_records 200; noise 220 5; } > "$LOG"
assert_exit 1  "two earlier good loads are in the log; the current load produces no BCF record: rejected" attempt ap_nobcf
{ noise 10 20; load_records 100; noise 120 20; load_records 200; noise 220 5; } > "$LOG"
assert_exit 0  "the same history, current load genuine: accepted (the window is only the current load)" attempt ap_good

echo "-- successive starts: the second attempt is not satisfied by the first one's records --"
{ noise 10 40; } > "$LOG"
T=300 assert_exit 0 "first start (T=300): accepted" attempt ap_good
T=400 assert_exit 1 "second start (T=400), driver logs no BCF record: rejected although the first start's genuine record is in the log" attempt ap_nobcf
T=500 assert_exit 0 "third start (T=500), genuine: accepted" attempt ap_good
T=600 assert_exit 1 "fourth start, wrong BCF: rejected although two earlier starts were genuine" attempt ap_wrongbcf
# the window of the second attempt, shown directly: it contains none of the first's records
{ noise 10 40; } > "$LOG"
T=300 attempt ap_good >/dev/null
m2="$(halow_dmesg_watermark)"
T=400 ap_nobcf
w2="$(halow_dmesg_since "$m2")"
assert_eq "0" "$(printf '%s\n' "$w2" | grep -c 'Loaded BCF')" "the second attempt's window holds no 'Loaded BCF' record at all"
assert_eq "3" "$(printf '%s\n' "$w2" | wc -l | tr -d ' ')" "and exactly the three records of the second attempt"

unset -f dmesg
halow_test_teardown
echo "test_bcf_verification: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
