#!/usr/bin/env bash
# Effective radio values: parsing "hostapd_cli status" output (field names and units from
# the pinned hostap source; they await live validation), capture through a status
# command, consistency checks against the selected profile, and the fallback labelling
# flow (ACS failure -> fallback channel -> source fallback, never acs).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_effective =="
radio_setup

status_sample() { # status_sample <s1g_freq> <s1g_bw> [prim_w] [prim_i] [state] [ht_freq] [ht_chan]
    printf 's1g_freq=%s\ns1g_bw=%s\ns1g_prim_chwidth=%s\ns1g_prim_1mhz_chan_index=%s\n' "$1" "$2" "${3:-1}" "${4:-0}"
    printf 'state=%s\nphy=phy0\nfreq=%s\nnum_sta_non_erp=0\nnum_sta_no_short_slot_time=0\n' "${5:-ENABLED}" "${6:-5805}"
    printf 'olbc=0\nnum_sta_ht_no_gf=0\nchannel=%s\nedmg_enable=0\nedmg_channel=0\nsecondary_channel=0\n' "${7:-161}"
    printf 'bss[0]=wlx0\nbssid[0]=02:00:00:00:00:01\nssid[0]=HaLowNet\nnum_sta[0]=0\n'
}

# --- parsing -----------------------------------------------------------------------------
halow_radio_parse_status "$(status_sample 923000 1)"; rc=$?
assert_eq "0" "$rc" "a realistic 1 MHz status parses"
assert_eq "923000|1|1|0|42" "$HALOW_EFF_FREQ_KHZ|$HALOW_EFF_BW_MHZ|$HALOW_EFF_PRIM_WIDTH|$HALOW_EFF_PRIM_INDEX|$HALOW_EFF_CHANNEL" "S1G values parsed and the channel derived from the frequency"
assert_eq "5805|161|ENABLED" "$HALOW_EFF_HT_FREQ_MHZ|$HALOW_EFF_HT_CHANNEL|$HALOW_EFF_STATE" "HT-mapped values and state recorded separately"

for bw in 2 4 8; do
    fb="${RADIO_EXPECT_FALLBACK[$bw]}"
    halow_radio_parse_status "$(status_sample $((902000 + 500 * fb)) "$bw")"; rc=$?
    assert_eq "0|$fb" "$rc|$HALOW_EFF_CHANNEL" "a $bw MHz status parses to channel $fb"
    halow_radio_check_effective AU "$bw" "$fb" >/dev/null; rc=$?
    assert_eq "0" "$rc" "$bw MHz on channel $fb is consistent with the profile"
done

crlf="$(status_sample 923000 1 | sed 's/$/\r/')"
halow_radio_parse_status "$crlf"; rc=$?
assert_eq "0|42" "$rc|$HALOW_EFF_CHANNEL" "CRLF line endings are tolerated"

halow_radio_parse_status "$(status_sample 923000 1)"
halow_radio_parse_status "$(printf 's1g_bw=1\ns1g_prim_chwidth=1\ns1g_prim_1mhz_chan_index=0\nfreq=5805\n')"; rc=$?
assert_eq "1" "$rc" "a status without s1g_freq cannot be captured"
assert_eq "|||||" "$HALOW_EFF_FREQ_KHZ|$HALOW_EFF_BW_MHZ|$HALOW_EFF_PRIM_WIDTH|$HALOW_EFF_PRIM_INDEX|$HALOW_EFF_CHANNEL|" "a failed parse clears earlier values (never reports stale ones)"
halow_radio_parse_status "$(printf 's1g_freq=923500\ns1g_bw=1\n')"; rc=$?
assert_eq "1" "$rc" "a status without the primary-channel fields cannot be captured"
halow_radio_parse_status "$(status_sample 923500 x)"; rc=$?
assert_eq "1" "$rc" "a garbled s1g_bw cannot be captured"
halow_radio_parse_status "$(status_sample -1 1)"; rc=$?
assert_eq "1" "$rc" "an error value (-1) for s1g_freq cannot be captured"
halow_radio_parse_status "$(status_sample 5805 1)"; rc=$?
assert_eq "1" "$rc" "an HT frequency in s1g_freq cannot be captured"
halow_radio_parse_status "$(status_sample 923500 1 3)"; rc=$?
assert_eq "1" "$rc" "a primary width other than 1 or 2 cannot be captured"
halow_radio_parse_status "$(status_sample 923000 1 3)"; rc=$?
assert_eq "1|" "$rc|$HALOW_EFF_CHANNEL" "a primary width of 3 is rejected even when every other field is a valid 1 MHz channel (and no value is left behind)"
halow_radio_parse_status "$(status_sample 923500 1 1 z)"; rc=$?
assert_eq "1" "$rc" "a garbled primary index cannot be captured"
halow_radio_parse_status ""; rc=$?
assert_eq "1" "$rc" "empty output cannot be captured"
halow_radio_parse_status "FAIL"; rc=$?
assert_eq "1" "$rc" "a control-interface FAIL reply cannot be captured"
[ -n "$HALOW_EFF_REASON" ]; assert_eq "0" "$?" "a failed parse sets HALOW_EFF_REASON"

# --- consistency checks ------------------------------------------------------------------
mismatch() { # mismatch <msg> <reason substring> <check args...>
    local msg="$1" sub="$2" out rc; shift 2
    out="$(halow_radio_check_effective "$@")"; rc=$?
    assert_eq "1" "$rc" "$msg: RADIO_MISMATCH"
    case "$out" in *"$sub"*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "$msg: reason says '$sub' ($out)"
}
consistent() { # consistent <msg> <check args...>
    local msg="$1" out rc; shift
    out="$(halow_radio_check_effective "$@")"; rc=$?
    assert_eq "0|" "$rc|$out" "$msg"
}

HALOW_EFF_FREQ_KHZ="" HALOW_EFF_BW_MHZ=""
mismatch "nothing captured" "cannot check" AU 1 42

halow_radio_parse_status "$(status_sample 923000 1)"
consistent "manual 1 MHz channel 42 matches" AU 1 42
consistent "automatic 1 MHz: any channel of the set matches" AU 1 ""
mismatch "manual expected 44, running on 42" "selected channel 44" AU 1 44
mismatch "selected 2 MHz, running 1 MHz" "operating width is 1 MHz, selected 2 MHz" AU 2 ""
mismatch "an unknown region" "cannot check" XX 1 ""

halow_radio_parse_status "$(status_sample 923500 1)"
mismatch "1 MHz on a frequency that is not a 1 MHz channel" "not a 1 MHz channel" AU 1 ""
halow_radio_parse_status "$(status_sample 931500 1)"
mismatch "1 MHz outside the AU band" "not a 1 MHz channel" AU 1 ""
halow_radio_parse_status "$(status_sample 923000 1 2 0)"
mismatch "primary width differs from the profile" "primary channel width is 2 MHz" AU 1 ""
halow_radio_parse_status "$(status_sample 922500 2 1 1)"
mismatch "primary index differs from the profile" "primary 1 MHz channel index is 1" AU 2 41
halow_radio_parse_status "$(status_sample 923000 1 1 0 ACS)"
mismatch "an access point still selecting a channel" "state is ACS" AU 1 ""
halow_radio_parse_status "$(status_sample 923000 1 1 0 DISABLED)"
mismatch "a disabled access point" "state is DISABLED" AU 1 42

halow_radio_parse_status "$(status_sample 923500 8)"
consistent "automatic 8 MHz on 43 matches" AU 8 ""
halow_radio_check_effective AU 8 "" >/dev/null
assert_eq "43" "$HALOW_EFF_CHANNEL" "a consistent check records the derived channel"

# Matrix against the explicit 2024 AU tables (helpers_radio.sh): every channel running at
# its own width is consistent (automatic and manual); the same frequency reported at any
# other width is a mismatch; frequencies of the removed edge channels never match.
mx_bad=""
for w in 1 2 4 8; do
    set -- ${RADIO_EXPECT_FREQS[$w]}
    i=0
    for c in ${RADIO_EXPECT_CHANNELS[$w]}; do
        i=$((i + 1)); eval "f=\${$i}"
        for rep in 1 2 4 8; do
            halow_radio_parse_status "$(status_sample "$f" "$rep")"
            if [ "$rep" = "$w" ]; then
                halow_radio_check_effective AU "$w" "" >/dev/null || mx_bad="$mx_bad auto:$w/$c"
                halow_radio_check_effective AU "$w" "$c" >/dev/null || mx_bad="$mx_bad manual:$w/$c"
                halow_radio_check_effective AU "$w" "$((c + 2))" >/dev/null && mx_bad="$mx_bad wrongsel:$w/$c"
            else
                halow_radio_check_effective AU "$rep" "" >/dev/null && mx_bad="$mx_bad other:$w/$c@$rep"
            fi
        done
    done
done
assert_eq "" "$mx_bad" "effective check: each AU channel is consistent only at its own width, and a different selected channel is a mismatch"
edge_bad=""
for f in 915500 927500; do
    for w in 1 2 4 8; do
        halow_radio_parse_status "$(status_sample "$f" "$w")"
        halow_radio_check_effective AU "$w" "" >/dev/null && edge_bad="$edge_bad $f@$w"
    done
done
assert_eq "" "$edge_bad" "effective check: the removed edge-channel frequencies (channels 27 and 51) never match any width"

# --- capture through a status command ----------------------------------------------------
bin="$HALOW_TEST_TMP/bin"; mkdir -p "$bin"
calls="$HALOW_TEST_TMP/cli_calls"
cat > "$bin/hostapd_cli_s1g" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls"
case "\${FAKE_CLI_MODE:-ok}" in
    ok) printf 's1g_freq=921500\ns1g_bw=4\ns1g_prim_chwidth=1\ns1g_prim_1mhz_chan_index=0\nstate=ENABLED\nfreq=5775\nchannel=155\n' ;;
    garbage) printf 'Failed to connect to hostapd - wpa_ctrl_open: No such file or directory\n' ;;
    fail) exit 1 ;;
esac
EOF
chmod +x "$bin/hostapd_cli_s1g"
PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -p /var/run/hostapd -i wlx0; rc=$?
assert_eq "0" "$rc" "capture through the status command succeeds"
assert_eq "-p /var/run/hostapd -i wlx0 status" "$(cat "$calls")" "the command is run with 'status' appended"
assert_eq "921500|4|39" "$HALOW_EFF_FREQ_KHZ|$HALOW_EFF_BW_MHZ|$HALOW_EFF_CHANNEL" "captured values"
consistent "captured 4 MHz on 39 matches" AU 4 39
FAKE_CLI_MODE=garbage PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -i wlx0; rc=$?
assert_eq "1" "$rc" "an unreachable control interface cannot be captured"
assert_eq "" "$HALOW_EFF_FREQ_KHZ" "and leaves no stale value"
FAKE_CLI_MODE=fail PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -i wlx0; rc=$?
assert_eq "1" "$rc" "a failing status command cannot be captured"
halow_radio_capture_effective; rc=$?
assert_eq "1" "$rc" "no command cannot be captured"
halow_radio_capture_effective "$HALOW_TEST_TMP/does-not-exist"; rc=$?
assert_eq "1" "$rc" "a missing command cannot be captured"

# --- "cannot capture" is marked, and is not a mismatch ----------------------------------
PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -i wlx0
assert_eq "ENABLED" "$HALOW_EFF_STATE" "a readable status keeps the reported state"
for mode in garbage fail; do
    FAKE_CLI_MODE=$mode PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -i wlx0; rc=$?
    assert_eq "1|unavailable" "$rc|$HALOW_EFF_STATE" "capture failure ($mode) sets HALOW_EFF_STATE=unavailable"
done
halow_radio_capture_effective; rc=$?
assert_eq "1|unavailable" "$rc|$HALOW_EFF_STATE" "no command: HALOW_EFF_STATE=unavailable"
cat > "$bin/hostapd_cli_partial" <<'EOF'
#!/usr/bin/env bash
printf 's1g_freq=923500\nstate=ENABLED\n'
EOF
chmod +x "$bin/hostapd_cli_partial"
PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_partial; rc=$?
assert_eq "1|unavailable" "$rc|$HALOW_EFF_STATE" "a status lacking the S1G fields is unavailable, not ENABLED"
cat > "$bin/hostapd_cli_disabled" <<'EOF'
#!/usr/bin/env bash
printf 's1g_freq=923000\ns1g_bw=1\ns1g_prim_chwidth=1\ns1g_prim_1mhz_chan_index=0\nstate=DISABLED\n'
EOF
chmod +x "$bin/hostapd_cli_disabled"
PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_disabled; rc=$?
assert_eq "0|DISABLED" "$rc|$HALOW_EFF_STATE" "a readable status that disagrees is captured (not unavailable)"
mismatch "a readable disagreement stays a mismatch" "state is DISABLED" AU 1 42

# --- the status command cannot hang the caller --------------------------------------------
cat > "$bin/hostapd_cli_hang" <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
chmod +x "$bin/hostapd_cli_hang"
t0=$SECONDS
HALOW_RADIO_CLI_TIMEOUT_S=1 PATH="$bin:$PATH" halow_radio_capture_effective hostapd_cli_hang -i wlx0; rc=$?
elapsed=$((SECONDS - t0))
assert_eq "1|unavailable" "$rc|$HALOW_EFF_STATE" "a status command that never answers is cut off: cannot capture"
[ "$elapsed" -lt 20 ]; assert_eq "0" "$?" "the capture returns long before the hanging command would ($elapsed s)"
tbin="$HALOW_TEST_TMP/tbin"; mkdir -p "$tbin"
cat > "$tbin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$HALOW_TEST_TMP/timeout.args"
shift
exec "\$@"
EOF
chmod +x "$tbin/timeout"
PATH="$tbin:$bin:$PATH" halow_radio_capture_effective hostapd_cli_s1g -p /var/run/hostapd -i wlx0; rc=$?
assert_eq "0|5 hostapd_cli_s1g -p /var/run/hostapd -i wlx0 status" "$rc|$(cat "$HALOW_TEST_TMP/timeout.args" 2>/dev/null)" \
    "the status command runs through 'timeout 5' by default"

# --- fallback labelling flow -------------------------------------------------------------
# ACS fails -> the manager renders the fallback; the render result is labelled fallback,
# the selected channel is the profile's candidate, and the effective check uses it.
log="$HALOW_RUN_DIR/hostapd.log"
printf 'wlx0: ACS-STARTED \nwlx0: ACS-FAILED \n' > "$log"
HALOW_RADIO_ACS_POLL_S=0.2 halow_radio_acs_wait "$log" "" 3; acs_rc=$?
assert_eq "1" "$acs_rc" "flow: ACS failed"
assert_eq "" "$HALOW_ACS_CHANNEL" "flow: no ACS channel is recorded for a failure"
dest="$HALOW_RUN_DIR/hostapd.conf"
halow_radio_render AU fallback 2 "" wlx0 HaLowNet 'Zq7-unique-effective-psk-1' halow-br0 32 "$dest" 2>/dev/null; rc=$?
assert_eq "0" "$rc" "flow: the fallback configuration renders"
assert_eq "fallback|41" "$HALOW_RADIO_RENDER_MODE|$HALOW_RADIO_RENDER_CHANNEL" "flow: the source is fallback (not acs) on the candidate channel"
assert_eq "candidate" "$(halow_radio_fallback_state AU 2)" "flow: the fallback used is labelled a candidate"
halow_radio_parse_status "$(status_sample 922500 2)"
consistent "flow: the running fallback matches its selected channel" AU 2 "$HALOW_RADIO_RENDER_CHANNEL"
halow_radio_parse_status "$(status_sample 918500 2)"
mismatch "flow: a fallback running elsewhere is a mismatch" "selected channel 41" AU 2 "$HALOW_RADIO_RENDER_CHANNEL"

halow_test_teardown
radio_summary test_radio_effective
