#!/usr/bin/env bash
# The bounded, secrets-safe access-point failure record (failure_record.sh): exit status
# collection in the start path, preservation before the destructive rollback, bounding
# (per record and ring), redaction (a sentinel passphrase and key-like lines never reach any
# record, state file, log, command line or test output), cleanup at stop, and an unchanged
# success path and retry policy.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_failure_record =="

SENTINEL='Zx9!Qv-7391-Kd#4mWp'
SENT_HEX="$(printf '%s' "$SENTINEL" | od -An -v -tx1 | tr -d ' \n')"
SENT_HEX_SPACED="$(printf '%s' "$SENTINEL" | od -An -v -tx1 | tr -s ' \n' ' ')"
OUT="$(mktemp)"
trap 'rm -f -- "$OUT"' EXIT

# frec_env - a fresh environment: real libraries, real renderer and template, a status
# snapshot, fake dmesg and ip, and a fake hostapd that exits at once.
frec_env() {
    radio_setup
    export HALOW_CFG_WIFI_PASSPHRASE="$SENTINEL"
    export HALOW_IFACE="wlu1" HALOW_BRIDGE_NAME="halow-br0" HALOW_CFG_REGION="AU" HALOW_CFG_BANDWIDTH="8" HALOW_CFG_RADIO_MODE="manual" HALOW_CFG_CHANNEL="43"
    export HALOW_MGR_ATTEMPT=2 HALOW_MGR_AP_FAILS=1 HALOW_AP_RETRY_LIMIT=3
    export HALOW_STATE_DIR="$HALOW_RUN_DIR"
    FR_BIN="$HALOW_TEST_TMP/bin"
    mkdir -p "$FR_BIN"
    cat > "$FR_BIN/dmesg_fake" <<EOF
#!/usr/bin/env bash
echo "[    1.000000] unrelated: nothing to see"
echo "[   10.000000] usb 1-1: new high-speed USB device number 3"
echo "[   11.000000] morse_usb 1-1:1.0: firmware loaded"
echo "[   12.000000] morse: wpa_passphrase=$SENTINEL leaked"
echo "[   13.000000] morse: key dump 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"
echo "[   14.000000] cfg80211: Failed to register wlu1 mac aa:bb:cc:dd:ee:ff"
echo "[   14.500000] wlu1: failed to bring the link up"
echo "[12345.678901] dot11ah: failed to start the firmware"
echo "[   16.000000] morse_usb 1-1: iSerial 3 ABC123"
echo "[   16.100000] morse_usb 1-1: SerialNo 98765"
echo "[   16.200000] morse: serial_number: XYZ"
echo "[   15.000000] mac80211: generic regdomain message"
echo "[   20.000000] usb 2-1: New USB device found, idVendor=1234, idProduct=5678"
echo "[   20.100000] usb 2-1: SerialNumber: OTHERDEVSERIAL99"
echo "[   20.200000] usb 2-1: Product: Some Other Gadget"
echo "[   20.300000] usb 1-1: New USB device found, idVendor=325b, idProduct=8100"
echo "[   20.400000] usb 1-1: SerialNumber: RADIOSERIAL77"
i=0; while [ "\${FAKE_DMESG_LINES:-0}" -gt "\$i" ]; do echo "[  \$i.000] morse: filler line number \$i"; i=\$((i + 1)); done
EOF
    cat > "$FR_BIN/ip_fake" <<EOF
#!/usr/bin/env bash
echo "lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>"
echo "wlu1             DOWN           aa:bb:cc:dd:ee:ff <BROADCAST,MULTICAST> $SENTINEL"
echo "halow-br0        UP             02:11:22:33:44:55 <BROADCAST,MULTICAST,UP,LOWER_UP>"
EOF
    cat > "$FR_BIN/hostapd_fail" <<'EOF'
#!/usr/bin/env bash
# args: -f <log> <conf>. Records its own argv, then behaves like a hostapd that fails.
log="$2"; conf="$3"
[ -z "${FAKE_ARGV_FILE:-}" ] || printf '%s\n' "$*" > "$FAKE_ARGV_FILE"
pp="$(sed -n 's/^wpa_passphrase=//p' "$conf")"
{
    echo "Configuration file: $conf"
    echo "nl80211: Could not configure driver mode"
    echo "ACS: Unable to collect survey data"
    echo "WPA: passphrase=$pp"
    echo "SAE: password $pp"
    echo "PSK (from passphrase) - hexdump(len=32): 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff"
    echo "PMK: 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00 11 22 33"
    echo "interface wlu1 dump: $FAKE_SENT_HEX_SPACED"
    echo "driver error code ${FAKE_SENT_HEX}"
    echo "Failed using ${pp:3:10} for the interface"
    echo "wlu1: blob 0xDE 0xAD 0xBE 0xEF 0xDE 0xAD 0xBE 0xEF done"
    echo "wlu1: grouped abcd ef01 2345 6789 abcd ef01 2345 6789 done"
    echo "wlu1: lengthy dGhpc2lzYXZlcnlsb25nYmFzZTY0c3RyaW5nMTIz done"
    echo "wlu1: p a s s w o r d spelled out"
    echo "wlu1: peer aa-bb-cc-dd-ee-ff gone"
    echo "wlu1: peer 112233445566 gone"
    echo "wlu1: channel 43 selected for the interface"
    echo "Interface initialization failed"
    echo "wlu1: using ${pp:0:2}.${pp:2:2}.${pp:4:15} as the value"
    echo "wlu1: peer aabb.ccdd.eeff gone"
    echo "completely unrelated chatter about gadgets"
    echo "wlu1: interface state UNINITIALIZED->DISABLED"
    echo "wlu1: STA aa:bb:cc:dd:ee:ff failed to associate"
    i=0; while [ "${FAKE_LOG_LINES:-0}" -gt "$i" ]; do echo "nl80211: error number $i in the driver while configuring the interface wlu1 padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding padding"; i=$((i + 1)); done
} > "$log"
echo "stdout: hostapd_s1g exiting"
echo "stderr: hostapd_s1g exiting" >&2
if [ "${FAKE_SIGNAL:-}" = "1" ]; then kill -SEGV $$; fi
exit "${FAKE_STATUS:-3}"
EOF
    chmod +x "$FR_BIN"/*
    export HALOW_FREC_DMESG_CMD="$FR_BIN/dmesg_fake" HALOW_FREC_IP_CMD="$FR_BIN/ip_fake"
    export FAKE_SENT_HEX="$SENT_HEX" FAKE_SENT_HEX_SPACED="$SENT_HEX_SPACED"
    HC="$HALOW_RUN_DIR/hostapd_s1g.conf"
    HL="$HALOW_RUN_DIR/hostapd_s1g.log"
    halow_state_init >/dev/null 2>&1
    halow_failure_record_clear
}

frec_render() {
    halow_radio_render AU manual 8 43 wlu1 "HaLowNet" "$SENTINEL" halow-br0 64 "$HC" >> "$OUT" 2>&1
}

# frec_fail_start - a failing start through the real start path, then the real capture,
# then the real rollback of the hostapd files. The start call is a plain statement.
frec_fail_start() {
    frec_render
    halow_hostapd_pre_start_check "$HC" >/dev/null 2>&1
    halow_start_hostapd "$FR_BIN/hostapd_fail" "$HL" "$HC" >> "$OUT" 2>&1
    FR_START_RC=$?
    halow_failure_record_capture start_exit "$HL" >> "$OUT" 2>&1
    halow_stop_hostapd >> "$OUT" 2>&1
}

diag() { printf '%s' "${_HALOW_ST_DIAG[$1]-}"; }
has_diag() { [ -n "${_HALOW_ST_DIAG[$1]+x}" ] && [ -n "${_HALOW_ST_DIAG[$1]}" ]; }
ring_present() { has_diag ap_failure_1 && has_diag ap_failure_2 && has_diag ap_failure_3; }
trunc_counted() { [ "$(diag ap_failure_truncations)" -ge 1 ]; }
newest_first() { grep -q "^record=5 " <<< "$(diag ap_failure_1)" && grep -q "^record=3 " <<< "$(diag ap_failure_3)"; }
snap_has_record() { halow_state_flush; grep -q '"ap_failure_1":' "$HALOW_STATUS_FILE" && grep -q '"ap_failure_count":"1"' "$HALOW_STATUS_FILE"; }
snap_valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HALOW_STATUS_FILE"; }
links_present() { grep -q "^wlu1 " <<< "$1" && grep -q "^halow-br0 " <<< "$1"; }
unavailable_stated() { grep -q "kernel log not available" <<< "$1" && grep -q "ip link state not available" <<< "$1" && grep -q "hostapd log not available" <<< "$1"; }
log_lines_le() { [ "$(grep -c "^nl80211: error number" <<< "$1")" -le "$2" ]; }

# every_piece_absent <dir-or-file> - none of the 8-character windows of the sentinel, nor
# its hex forms, appear anywhere below the path.
sentinel_absent_in() {
    local target="$1" i n=${#SENTINEL} piece
    for (( i = 0; i <= n - 8; i++ )); do
        piece="${SENTINEL:i:8}"
        if grep -rqF -- "$piece" "$target" 2>/dev/null; then echo "found piece '$piece' in $target"; return 1; fi
    done
    grep -rqiF -- "${SENT_HEX:0:16}" "$target" 2>/dev/null && { echo "found hex form"; return 1; }
    return 0
}

echo "-- start path: the exit status is collected; the success path is unchanged --"
frec_env
export FAKE_STATUS=7
frec_render
halow_hostapd_pre_start_check "$HC" >/dev/null 2>&1
halow_start_hostapd "$FR_BIN/hostapd_fail" "$HL" "$HC" >> "$OUT" 2>&1
assert_eq "1" "$?" "an immediately exiting hostapd_s1g still fails the start (as before)"
assert_eq "7" "$HALOW_HOSTAPD_EXIT_STATUS" "its exit status is collected"
assert_success "the time it was found ended is recorded (about the 1 s probe)" test -n "$HALOW_HOSTAPD_FAIL_MS"
assert_eq "" "$HALOW_LAST_STARTED_PID" "no started pid is reported"
assert_file_absent "$HALOW_RUN_DIR/hostapd_s1g.pid" "no pid file is written (unchanged)"
halow_stop_hostapd >/dev/null 2>&1
halow_test_teardown

frec_env
cat > "$FR_BIN/hostapd_ok" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_ARGV_FILE:-}" ] || printf '%s\n' "$*" > "$FAKE_ARGV_FILE"
echo "wlu1: AP-ENABLED" > "$2"
sleep 20
EOF
chmod +x "$FR_BIN/hostapd_ok"
export FAKE_ARGV_FILE="$HALOW_TEST_TMP/argv"
frec_render
halow_hostapd_pre_start_check "$HC" >/dev/null 2>&1
halow_start_hostapd "$FR_BIN/hostapd_ok" "$HL" "$HC" >> "$OUT" 2>&1
assert_eq "0" "$?" "a normal start succeeds"
assert_eq "" "$HALOW_HOSTAPD_EXIT_STATUS" "no exit status is recorded on the success path"
assert_eq "$HALOW_LAST_STARTED_PID" "$(cat "$HALOW_RUN_DIR/hostapd_s1g.pid")" "the pid file holds the started pid (unchanged)"
assert_eq "-f $HL $HC" "$(cat "$FAKE_ARGV_FILE")" "the command line is only -f <log> <conf>: no passphrase, no debug flag"
assert_failure "a normal start leaves no failure record" has_diag ap_failure_1
assert_failure "and none in the snapshot" grep -q ap_failure "$HALOW_STATUS_FILE"
kill "$HALOW_LAST_STARTED_PID" 2>/dev/null; wait "$HALOW_LAST_STARTED_PID" 2>/dev/null
halow_stop_hostapd >/dev/null 2>&1
unset FAKE_ARGV_FILE
halow_test_teardown

echo "-- preservation before rollback --"
frec_env
export FAKE_STATUS=7 FAKE_LOG_LINES=0
frec_fail_start
assert_eq "1" "$FR_START_RC" "the start failed"
assert_file_absent "$HL" "the rollback removed hostapd's log"
assert_file_absent "$HC" "the rollback removed the rendered configuration"
assert_success "the record exists after the rollback (ap_failure_1)" has_diag ap_failure_1
REC="$(diag ap_failure_1)"
assert_success "it holds hostapd's own reason, read from the log before it was deleted" grep -qF "nl80211: Could not configure driver mode" <<< "$REC"
assert_success "it holds the exit status" grep -q "hostapd_exit=status 7" <<< "$REC"
assert_success "it holds the retry counter and attempt" grep -q "attempt=2 consecutive_failures_before=1 retry_limit=3" <<< "$REC"
assert_success "it holds the selection mode, bandwidth and consumed channel (structured manager values)" grep -q "channel_selection_mode=manual bandwidth_mhz=8 channel=43" <<< "$REC"
assert_success "it holds the derived primary settings, labelled configured/derived and not read from the radio" grep -qF "primary_configured_derived (from the profile table, NOT read from the radio)=op_class=53 primary_bandwidth_mhz=1 primary_index=0" <<< "$REC"
assert_success "it holds the link state of the radio and the bridge" links_present "$REC"
assert_success "the link state is name and state only" grep -q "^wlu1 DOWN$" <<< "$REC"
assert_failure "no MAC address from the link table is kept" grep -q "aa:bb:cc" <<< "$REC"
assert_failure "no link flags are kept" grep -q "BROADCAST" <<< "$REC"
assert_success "it holds the kernel-log lines about the driver" grep -qF "morse_usb 1-1:1.0: firmware loaded" <<< "$REC"
assert_failure "unrelated kernel lines are not kept" grep -qF "unrelated: nothing to see" <<< "$REC"
assert_failure "a generic kernel line that names neither the driver nor the radio interface is not kept" grep -qF "regdomain" <<< "$REC"
assert_success "a kernel line that names the radio interface is kept" grep -qF "wlu1: failed to bring the link up" <<< "$REC"
assert_failure "a kernel line with a MAC address is dropped" grep -qF "Failed to register wlu1" <<< "$REC"
assert_failure "the rendered configuration is not reproduced (no section, no key lines, no SSID, no passphrase key)" grep -qE "hostapd_config|^[0-9]+: [a-z_0-9]+=|HaLowNet|wpa_passphrase" <<< "$REC"
assert_success "the record is published as diagnostics keys" snap_has_record
assert_success "the snapshot is valid JSON" snap_valid_json
halow_test_teardown

echo "-- signal exit --"
frec_env
export FAKE_STATUS=3 FAKE_SIGNAL=1
frec_fail_start
assert_success "a hostapd killed by a signal is recorded with the signal" grep -Eq "hostapd_exit=status 139 \(signal SEGV\)" <<< "$(diag ap_failure_1)"
unset FAKE_SIGNAL
halow_test_teardown

echo "-- automatic selection: no channel is consumed and no primary is derived --"
frec_env
export HALOW_CFG_RADIO_MODE=automatic HALOW_CFG_CHANNEL="" HALOW_RADIO_RENDER_MODE=automatic HALOW_RADIO_RENDER_CHANNEL=""
: > "$HL"
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
REC="$(diag ap_failure_1)"
assert_success "automatic mode records channel auto" grep -q "channel_selection_mode=automatic bandwidth_mhz=8 channel=auto" <<< "$REC"
assert_success "and no derived primary" grep -q "NOT read from the radio)=not available" <<< "$REC"
export HALOW_RADIO_RENDER_MODE=manual HALOW_RADIO_RENDER_CHANNEL=35
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
assert_success "an automatic start that fell back records what was rendered: manual, channel 35" grep -q "channel_selection_mode=manual bandwidth_mhz=8 channel=35" <<< "$(diag ap_failure_1)"
assert_success "and its derived primary" grep -q "NOT read from the radio)=op_class=53 primary_bandwidth_mhz=1 primary_index=0" <<< "$(diag ap_failure_1)"
halow_test_teardown

echo "-- redaction: the sentinel passphrase and key-like lines never appear anywhere --"
frec_env
export FAKE_STATUS=1 FAKE_LOG_LINES=0
frec_fail_start
REC="$(diag ap_failure_1)"
assert_failure "the passphrase is not in the record" grep -qF "$SENTINEL" <<< "$REC"
assert_failure "the passphrase line of hostapd's log is dropped" grep -q "WPA: pass" <<< "$REC"
assert_failure "the SAE password line is dropped" grep -q "SAE: password" <<< "$REC"
assert_failure "the PSK hexdump line is dropped" grep -qi "hexdump" <<< "$REC"
assert_failure "the PMK-like line is dropped" grep -q "PMK:" <<< "$REC"
assert_failure "a spaced hex dump without a keyword is dropped" grep -qF "${SENT_HEX_SPACED:0:20}" <<< "$REC"
assert_failure "a contiguous hex form of the passphrase is dropped" grep -qiF "${SENT_HEX:0:16}" <<< "$REC"
assert_failure "a line holding part of the passphrase is dropped" grep -qF "${SENTINEL:3:10}" <<< "$REC"
assert_failure "a passphrase re-delimited with dots is dropped" grep -qF "as the value" <<< "$REC"
assert_failure "a dotted MAC address is dropped" grep -qF "aabb.ccdd" <<< "$REC"
assert_success "a kernel line with a long-uptime timestamp (digits that run into hex letters) is still kept" grep -qF "failed to start the firmware" <<< "$REC"
assert_failure "serial lines are dropped in every spelling, even when they name the driver" grep -qE "ABC123|98765|XYZ" <<< "$REC"
assert_failure "the kernel line carrying the passphrase is dropped" grep -q "wpa_passphrase=$SENTINEL" <<< "$REC"
assert_failure "the kernel key dump is dropped" grep -q "key dump" <<< "$REC"
assert_success "safe lines of hostapd's log survive the filter" grep -qF "Interface initialization failed" <<< "$REC"
assert_success "dropped lines are counted, not shown" grep -Eq "dropped_sensitive=[1-9]" <<< "$REC"
assert_failure "a station MAC line of the log is dropped" grep -q "aa:bb:cc:dd:ee:ff" <<< "$REC"
assert_failure "a line with a hyphen-separated MAC is dropped" grep -q "peer aa-bb" <<< "$REC"
assert_failure "no hyphen-separated MAC tail" grep -q "dd-ee-ff" <<< "$REC"
assert_failure "a line with an unseparated 12-digit MAC is dropped" grep -q "peer 1122" <<< "$REC"
assert_failure "no unseparated MAC tail" grep -q "445566" <<< "$REC"
assert_failure "0x-prefixed spaced hex bytes are dropped" grep -qi "0xDE 0xAD" <<< "$REC"
assert_failure "spaced hex groups are dropped" grep -q "abcd ef01" <<< "$REC"
assert_failure "a 36-character base64-like run is dropped" grep -q "dGhpc2lz" <<< "$REC"
assert_failure "a spelled-out keyword is dropped" grep -q "spelled out" <<< "$REC"
assert_success "an ordinary line about the channel is still kept" grep -q "channel 43 selected for the interface" <<< "$REC"
assert_failure "a kernel line about a USB device that does not name the radio is dropped (even the radio's vendor id)" grep -q "idVendor=325b" <<< "$REC"
assert_failure "a line on no allowlisted hostapd subject is not kept" grep -q "unrelated chatter" <<< "$REC"
assert_failure "a kernel line about another USB device is dropped (vendor id)" grep -q "idVendor=1234" <<< "$REC"
assert_failure "another USB device's product name is dropped" grep -q "Some Other Gadget" <<< "$REC"
assert_failure "another USB device's serial number is dropped" grep -q "OTHERDEVSERIAL99" <<< "$REC"
assert_failure "the radio's own serial number line is dropped too" grep -q "RADIOSERIAL77" <<< "$REC"
halow_state_flush
assert_success "nothing of the sentinel is in the run directory or the snapshot" sentinel_absent_in "$HALOW_RUN_DIR"
assert_success "nor in the state directory" sentinel_absent_in "$HALOW_STATE_DIR"
assert_failure "nothing of the sentinel is in the output of the start, capture and rollback" grep -qF "$SENTINEL" "$OUT"
assert_failure "no piece of it is in that output either" bash -c 'for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do p="${1:$i:8}"; [ ${#p} -eq 8 ] && grep -qF -- "$p" "$2" && exit 0; done; exit 1' _ "$SENTINEL" "$OUT"
halow_test_teardown

echo "-- deny by default: the rendered configuration is never read --"
frec_env
cat > "$HC" <<EOF
interface=wlu1
ssid=CONFMARKER123
wpa_passphrase=$SENTINEL
sae_password=$SENTINEL
some_future_key=$SENTINEL
EOF
: > "$HL"
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
REC="$(diag ap_failure_1)"
assert_failure "no configuration value reaches the record (it is not read)" grep -qE "CONFMARKER123|some_future_key|sae_password|wpa_passphrase" <<< "$REC"
assert_failure "no part of the passphrase reaches the record" grep -qF "${SENTINEL:3:10}" <<< "$REC"
halow_test_teardown

echo "-- bounding --"
frec_env
export FAKE_STATUS=1 FAKE_LOG_LINES=6000 FAKE_DMESG_LINES=4000
frec_fail_start
REC="$(diag ap_failure_1)"
assert_success "a huge hostapd log and kernel log give a record within the bound ($HALOW_FREC_MAX_BYTES bytes)" test "${#REC}" -le "$HALOW_FREC_MAX_BYTES"
assert_success "the truncation is marked in the record" grep -q "truncated to" <<< "$REC"
assert_success "the truncation is counted" trunc_counted
assert_success "at most 30 hostapd log lines are kept" log_lines_le "$REC" 30
assert_success "the newest lines are the ones kept" grep -q "error number 5999" <<< "$REC"
export HALOW_FREC_MAX_BYTES=900
halow_failure_record_clear
frec_fail_start
REC="$(diag ap_failure_1)"
assert_success "the overall bound is enforced by truncation (900 bytes)" test "${#REC}" -le 900
assert_success "the record says it was truncated" grep -q "record truncated" <<< "$REC"
unset HALOW_FREC_MAX_BYTES FAKE_LOG_LINES FAKE_DMESG_LINES
halow_test_teardown

echo "-- ring of three; no growth across retries; no files written --"
frec_env
export FAKE_STATUS=1 FAKE_LOG_LINES=0
before="$(cd "$HALOW_RUN_DIR" && ls -A | tr '\n' ' ')"
for n in 1 2 3 4 5; do frec_render; halow_failure_record_capture start_exit "$HL" >> "$OUT" 2>&1; done
after="$(cd "$HALOW_RUN_DIR" && ls -A | tr '\n' ' ')"
assert_success "ap_failure_1..3 exist" ring_present
assert_failure "there is no fourth record" has_diag ap_failure_4
assert_eq "5" "$(diag ap_failure_count)" "five were captured"
assert_success "newest first: key 1 is record 5, key 3 is record 3" newest_first
assert_eq "3" "${#_HALOW_FREC_RING[@]}" "the in-memory ring holds three records, not five"
total=0; for k in 1 2 3; do total=$((total + ${#_HALOW_ST_DIAG[ap_failure_$k]})); done
assert_success "the three records together stay within 3 x the bound" test "$total" -le $((3 * HALOW_FREC_MAX_BYTES))
halow_state_flush
assert_success "the snapshot stays far below the 1 MiB cap of the status service" test "$(wc -c < "$HALOW_STATUS_FILE")" -lt 120000
rm -f "$HC"
after="$(cd "$HALOW_RUN_DIR" && ls -A | tr '\n' ' ')"
assert_eq "$before" "$after" "no file is left by the capture (only the snapshot and the rendered configuration, which the rollback removes)"
halow_test_teardown

echo "-- cleanup at stop --"
frec_env
export FAKE_STATUS=1 FAKE_LOG_LINES=0
frec_fail_start
assert_success "a record is held" has_diag ap_failure_1
halow_failure_record_clear
assert_failure "the record is gone after the clear" has_diag ap_failure_1
halow_state_flush
assert_failure "and so is every key in the snapshot" grep -q "ap_failure" "$HALOW_STATUS_FILE"
assert_success "the snapshot is still valid JSON" snap_valid_json
assert_eq "" "$(find "$HALOW_TEST_TMP" -name '*failure*' | tr '\n' ' ')" "no failure file exists anywhere"
halow_test_teardown

echo "-- best effort: missing tools and a missing log never fail the capture --"
frec_env
export HALOW_FREC_DMESG_CMD="$HALOW_TEST_TMP/no_such_dmesg" HALOW_FREC_IP_CMD="$HALOW_TEST_TMP/no_such_ip"
halow_failure_record_capture start_exit "$HALOW_RUN_DIR/missing.log"
assert_eq "0" "$?" "the capture returns 0"
REC="$(diag ap_failure_1)"
assert_success "unavailable sources are stated, not guessed" unavailable_stated "$REC"
ln -s /etc/passwd "$HALOW_RUN_DIR/linklog"
halow_failure_record_capture start_exit "$HALOW_RUN_DIR/linklog" >> "$OUT" 2>&1
assert_success "a symlink in place of the log is not followed" grep -q "hostapd log not available" <<< "$(diag ap_failure_1)"
halow_test_teardown

echo "-- a hanging tool cannot hold the capture --"
frec_env
printf '#!/usr/bin/env bash\nsleep 30\n' > "$FR_BIN/hang"; chmod +x "$FR_BIN/hang"
export HALOW_FREC_DMESG_CMD="$FR_BIN/hang" HALOW_FREC_IP_CMD="$FR_BIN/hang" HALOW_FREC_TOOL_TIMEOUT_S=1
t0=$SECONDS
halow_failure_record_capture start_exit "$HL" >> "$OUT" 2>&1
assert_success "both hanging tools are cut off within the bounds (took $((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 6
halow_test_teardown

echo "-- without a timeout command the ip and dmesg tools are skipped, never run unbounded --"
frec_env
printf '#!/usr/bin/env bash\nsleep 8\n' > "$FR_BIN/hang"; chmod +x "$FR_BIN/hang"
export HALOW_FREC_DMESG_CMD="$FR_BIN/hang" HALOW_FREC_IP_CMD="$FR_BIN/hang" HALOW_TIMEOUT_CMD="$HALOW_TEST_TMP/no_such_timeout"
t0=$SECONDS
halow_failure_record_capture start_exit "$HL" >> "$OUT" 2>&1
assert_success "the capture does not wait for the tools (took $((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 3
assert_success "both are reported as not available" bash -c 'grep -q "kernel log not available" <<< "$1" && grep -q "ip link state not available" <<< "$1"' _ "$(diag ap_failure_1)"
unset HALOW_TIMEOUT_CMD
halow_test_teardown

echo "-- the final exact-passphrase scrub: a leak that reaches the record through no filter is still removed --"
frec_env
: > "$HL"
( _halow_frec_links() { _HALOW_FREC_LNK="wlu1 UP ${SENTINEL}"; }
  _halow_frec_build direct "$HL" >> "$OUT" 2>&1
  printf '%s' "$_HALOW_FREC_RECORD" > "$HALOW_TEST_TMP/rec_scrub" )
assert_success "an injected passphrase passes through no filter but is scrubbed" grep -q "wlu1 UP \[redacted\]" "$HALOW_TEST_TMP/rec_scrub"
assert_failure "the built record holds no passphrase" grep -qF "$SENTINEL" "$HALOW_TEST_TMP/rec_scrub"
halow_test_teardown
frec_env
: > "$HL"
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
assert_failure "the real link table (which the fake gives a passphrase column) leaks nothing: name and state only" grep -qF "$SENTINEL" <<< "$(diag ap_failure_1)"
halow_test_teardown

echo "-- a flood: 20000 tiny hostapd log lines and 20000 kernel lines are scanned within a bound --"
frec_env
frec_render
yes 'ap-' | head -n 20000 > "$HL"
printf '#!/usr/bin/env bash\nyes "morse: m" | head -n 20000\n' > "$FR_BIN/dmesg_flood"; chmod +x "$FR_BIN/dmesg_flood"
export HALOW_FREC_DMESG_CMD="$FR_BIN/dmesg_flood"
t0=$SECONDS
halow_failure_record_capture start_exit "$HL" >> "$OUT" 2>&1
assert_success "the capture finishes within a generous bound (took $((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 15
assert_success "a record was produced" has_diag ap_failure_1
assert_success "at most the line limit of each tail is kept" bash -c '[ "$(grep -c "^ap-" <<< "$1")" -le "$2" ] && [ "$(grep -c "^morse: m" <<< "$1")" -le "$3" ]' _ "$(diag ap_failure_1)" "$HALOW_FREC_LOG_LINES" "$HALOW_FREC_KLOG_LINES"
halow_test_teardown

echo "-- a real child killed by a signal, collected in the capture's own pid branch --"
frec_env
frec_render
: > "$HL"
unset HALOW_HOSTAPD_EXIT_STATUS HALOW_HOSTAPD_FAIL_MS HALOW_HOSTAPD_LAST_PID
bash -c 'sleep 0.5; kill -SEGV $$' 2>/dev/null &
FR_CHILD=$!
HALOW_MGR_HOSTAPD_PID="$FR_CHILD"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$FR_CHILD" 2>/dev/null || break; sleep 0.5; done
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
assert_success "the child's own status is collected: 139 (signal SEGV)" grep -Eq "hostapd_exit=status 139 \(signal SEGV\)" <<< "$(diag ap_failure_1)"
HALOW_MGR_HOSTAPD_PID=""
halow_test_teardown

echo "-- status 127 is stated as an exec failure or an uncollectable status --"
frec_env
frec_render
: > "$HL"
export HALOW_HOSTAPD_EXIT_STATUS=127 HALOW_HOSTAPD_FAIL_MS=1004
halow_failure_record_capture direct "$HL" >> "$OUT" 2>&1
assert_success "127 (exec failed or not collectable)" grep -qF "hostapd_exit=status 127 (exec failed or not collectable)" <<< "$(diag ap_failure_1)"
unset HALOW_HOSTAPD_EXIT_STATUS HALOW_HOSTAPD_FAIL_MS
halow_test_teardown

echo "-- stale failure details of an earlier launch never describe a later one --"
frec_env
export FAKE_STATUS=7
frec_render
halow_hostapd_pre_start_check "$HC" >/dev/null 2>&1
halow_start_hostapd "$FR_BIN/hostapd_fail" "$HL" "$HC" >> "$OUT" 2>&1
assert_eq "7" "$HALOW_HOSTAPD_EXIT_STATUS" "the first launch leaves status 7"
# a second start that cannot even create its log file (a directory in its place)
rm -f "$HL"; mkdir "$HL"
halow_start_hostapd "$FR_BIN/hostapd_fail" "$HL" "$HC" >> "$OUT" 2>&1
assert_eq "1" "$?" "the start fails at once"
assert_eq "" "$HALOW_HOSTAPD_EXIT_STATUS" "no stale exit status"
assert_eq "" "$HALOW_HOSTAPD_FAIL_MS" "no stale time"
assert_eq "" "$HALOW_HOSTAPD_LAST_PID" "no stale pid"
unset HALOW_MGR_HOSTAPD_PID
halow_failure_record_capture start_exit "$HALOW_RUN_DIR/none.log" >> "$OUT" 2>&1
assert_failure "the record does not report the earlier launch's status" grep -q "hostapd_exit=status 7" <<< "$(diag ap_failure_1)"
rmdir "$HL" 2>/dev/null
halow_test_teardown

echo "-- retry policy unchanged --"
. "$HALOW_LIB_DIR/lifecycle.sh"
assert_eq "5 10 20" "$(halow_backoff_next 1) $(halow_backoff_next 2) $(halow_backoff_next 3)" "backoff 5, 10, 20"
assert_success "bounded: attempt 1 retries" halow_lifecycle_should_retry AP_START_FAILED 1
assert_success "bounded: attempt 2 retries" halow_lifecycle_should_retry AP_START_FAILED 2
assert_failure "bounded: the third failure holds" halow_lifecycle_should_retry AP_START_FAILED 3
assert_eq "bounded" "$(halow_lifecycle_retry_class AP_START_FAILED)" "AP_START_FAILED stays bounded"

echo
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then
    echo "test_failure_record: $HALOW_TEST_FAILURES of $HALOW_TEST_COUNT FAILED"
    exit 1
fi
echo "test_failure_record: $HALOW_TEST_COUNT/$HALOW_TEST_COUNT passed"
