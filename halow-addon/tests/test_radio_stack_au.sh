#!/usr/bin/env bash
# Stack consistency checks for the access point program (hostapd_s1g, hostapd_cli_s1g and
# the configuration template) at the release that matches the bundled driver. Source level
# only (no device, no emulator, no Docker):
#   a. channel and primary-index rendering for AU: every width (1, 2, 4, 8 MHz) and every
#      channel, with the expected lines typed out here one by one (independent of the profile
#      table), and the two 8 MHz channels 35 and 43 written out in full;
#   b. the rendered configuration is WPA3-SAE only, with protected management frames
#      required, and the passphrase appears in exactly one line of one file;
#   c. automatic channel selection, the fallback channel and the S1G fields of the access
#      point's status output (in the form the hostap source prints them) round-trip through
#      the add-on's own rendering and parsing for every width and channel;
#   d. the separate helper program that an earlier hostapd release line ran is not shipped,
#      referenced or needed, and the staged programs and modules carry one release string.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_stack_au =="
SKIPPED=0
radio_setup
echo "  (template: $RADIO_TEMPLATE_KIND)"

PSK='Vt3-stack-matrix-psk-6617'
dest="$HALOW_RUN_DIR/hostapd.conf"
out_file="$HALOW_TEST_TMP/render.out"
render() { # render <mode> <bw> <channel>
    rm -f -- "$dest"
    halow_radio_render AU "$1" "$2" "$3" wlx001122 "HaLowNet" "$PSK" halow-br0 64 "$dest" > "$out_file" 2>&1
}

echo "-- a. every AU width and channel: the rendered radio lines, typed out --"
# "<width MHz>:<channel>:<operating class>". Operating classes 50 to 53 are the global AU
# classes for 1, 2, 4 and 8 MHz. Every channel is rendered with the 1 MHz primary width
# (s1g_prim_chwidth=0) and primary 1 MHz index 0.
CASES="
1:28:50 1:30:50 1:32:50 1:34:50 1:36:50 1:38:50 1:40:50 1:42:50 1:44:50 1:46:50 1:48:50 1:50:50
2:29:51 2:33:51 2:37:51 2:41:51 2:45:51 2:49:51
4:31:52 4:39:52 4:47:52
8:35:53 8:43:53"
n=0
for c in $CASES; do
    bw="${c%%:*}"; rest="${c#*:}"; ch="${rest%%:*}"; op="${rest##*:}"
    n=$((n + 1))
    label="AU $bw MHz channel $ch"
    render manual "$bw" "$ch"
    assert_eq "0" "$?" "$label renders"
    assert_success "$label: op_class=$op" grep -qx "op_class=$op" "$dest"
    assert_success "$label: channel=$ch" grep -qx "channel=$ch" "$dest"
    assert_success "$label: s1g_prim_chwidth=0" grep -qx "s1g_prim_chwidth=0" "$dest"
    assert_success "$label: s1g_prim_1mhz_chan_index=0" grep -qx "s1g_prim_1mhz_chan_index=0" "$dest"
    assert_success "$label: country_code=AU" grep -qx "country_code=AU" "$dest"
    assert_eq "$((902000 + 500 * ch))" "$HALOW_RADIO_RENDER_FREQ_KHZ" "$label: reported frequency"
done
assert_eq "23" "$n" "all 23 AU channels were rendered (12 + 6 + 3 + 2)"

echo "-- a. the two 8 MHz channels, in full --"
for ch in 35 43; do
    render manual 8 "$ch"
    assert_eq "0" "$?" "8 MHz channel $ch renders"
    got="$(grep -E '^(op_class|channel|s1g_prim_chwidth|s1g_prim_1mhz_chan_index|country_code|hw_mode|ieee80211ah)=' "$dest" | LC_ALL=C sort | tr '\n' ' ')"
    want="channel=$ch country_code=AU hw_mode=a ieee80211ah=1 op_class=53 s1g_prim_1mhz_chan_index=0 s1g_prim_chwidth=0 "
    assert_eq "$want" "$got" "8 MHz channel $ch: exactly these radio lines"
done
# The 1 MHz primary channel hostap derives for primary index 0 (taken from the executed
# source: centre minus 7 for 8 MHz) and its frequency.
halow_radio_primary_info AU 8 35
assert_eq "28 916000" "$HALOW_PRIM_1MHZ_CHANNEL $HALOW_PRIM_1MHZ_KHZ" "8 MHz channel 35: primary 1 MHz channel 28 (916.0 MHz)"
halow_radio_primary_info AU 8 43
assert_eq "36 920000" "$HALOW_PRIM_1MHZ_CHANNEL $HALOW_PRIM_1MHZ_KHZ" "8 MHz channel 43: primary 1 MHz channel 36 (920.0 MHz)"

echo "-- b. WPA3-SAE only, in every mode and width --"
chk_sae() { # chk_sae <label>
    local label="$1" k bad=""
    assert_success "$label: wpa=2" grep -qx 'wpa=2' "$dest"
    assert_success "$label: wpa_key_mgmt=SAE and nothing else" grep -qx 'wpa_key_mgmt=SAE' "$dest"
    assert_eq "1" "$(radio_conf_count "$dest" wpa_key_mgmt)" "$label: a single wpa_key_mgmt line"
    assert_success "$label: rsn_pairwise=CCMP" grep -qx 'rsn_pairwise=CCMP' "$dest"
    assert_success "$label: ieee80211w=2 (protected management frames required)" grep -qx 'ieee80211w=2' "$dest"
    assert_success "$label: sae_pwe=2 (both hunting-and-pecking and hash-to-element)" grep -qx 'sae_pwe=2' "$dest"
    assert_success "$label: wds_sta=1" grep -qx 'wds_sta=1' "$dest"
    assert_failure "$label: no WPA-PSK key management anywhere" grep -E '^[[:space:]]*wpa_key_mgmt=.*(PSK|EAP|OWE|DPP)' "$dest"
    for k in wpa_psk wpa_psk_file sae_password wpa_passphrase_file; do
        [ "$(radio_conf_count "$dest" "$k")" = "0" ] || bad="$bad $k"
    done
    assert_eq "" "$bad" "$label: no PSK or SAE password key other than wpa_passphrase"
    assert_eq "1" "$(radio_conf_count "$dest" wpa_passphrase)" "$label: exactly one wpa_passphrase line"
    assert_eq "1" "$(grep -c -F -- "$PSK" "$dest")" "$label: the passphrase appears on exactly one line"
    assert_failure "$label: the passphrase is not in the command output" grep -q -F -- "$PSK" "$out_file"
    assert_failure "$label: no other file in the run directory holds the passphrase" bash -c 'grep -rlF -- "$1" "$2" | grep -vxF "$3"' _ "$PSK" "$HALOW_RUN_DIR" "$dest"
    assert_eq "600" "$(stat -c '%a' "$dest")" "$label: mode 0600"
}
for bw in 1 2 4 8; do
    ch="$(printf '%s\n' ${RADIO_EXPECT_CHANNELS[$bw]} | tail -n1)"
    render automatic "$bw" "";  assert_eq "0" "$?" "automatic $bw MHz renders"; chk_sae "automatic $bw MHz"
    render manual "$bw" "$ch";  assert_eq "0" "$?" "manual $bw MHz renders";    chk_sae "manual $bw MHz"
    render fallback "$bw" "";   assert_eq "0" "$?" "fallback $bw MHz renders";  chk_sae "fallback $bw MHz"
done

echo "-- b/d. the bundled template: its own differences from the vendor sample are exactly these --"
TPL="$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf"
if [ "$RADIO_TEMPLATE_KIND" = "bundled" ]; then
    active="$(grep -E '^[A-Za-z0-9_]+=' "$TPL")"
    for k in wpa wpa_key_mgmt rsn_pairwise ieee80211w sae_pwe wds_sta; do
        assert_eq "1" "$(grep -c "^${k}=" <<< "$active")" "template: $k is an active line exactly once"
    done
    assert_eq "$(printf 'wpa=2\nwpa_key_mgmt=SAE\nrsn_pairwise=CCMP\nieee80211w=2\nsae_pwe=2\nwds_sta=1')" "$(tail -n 6 "$TPL")" "template: the last six lines are the WPA3-SAE and WDS settings"
    assert_eq "0" "$(grep -c '^eap_server=' "$TPL")" "template: the vendor line eap_server=0 is removed"
    assert_eq "0" "$(grep -c -E '^(wpa_passphrase|wpa_psk|sae_password|wpa_psk_file)=' "$TPL")" "template: no active secret line"
    assert_success "template: it is the sample of the 2.1.0 release (it carries the release's newer option notes)" grep -q '^#known_sta_identification=' "$TPL"
    assert_success "template: and the Australian country default" grep -qx 'country_code=AU' "$TPL"
else
    echo "  SKIP: artifacts are not staged here; the bundled-template checks (11 assertions) were not run"
    SKIPPED=$((SKIPPED + 11))
fi

echo "-- c. automatic selection, fallback and the status S1G fields, for every width and channel --"
# A status text in the order and with the field names the hostap source prints
# (s1g_freq, s1g_bw, s1g_prim_chwidth in MHz, s1g_prim_1mhz_chan_index, then state, the
# 5 GHz mapped freq and channel, bss lines).
status_text() { # status_text <s1g_freq_khz> <bw>
    printf 'state=ENABLED\nphy=phy0\nfreq=5805\nnum_sta_non_erp=0\nnum_sta_no_short_slot_time=0\n'
    printf 'olbc=0\nnum_sta_ht_no_gf=0\nchannel=161\nedmg_enable=0\nedmg_channel=0\nsecondary_channel=0\n'
    printf 's1g_freq=%s\ns1g_bw=%s\ns1g_prim_chwidth=1\ns1g_prim_1mhz_chan_index=0\n' "$1" "$2"
    printf 'bss[0]=wlx001122\nbssid[0]=02:00:00:00:00:01\nssid[0]=HaLowNet\nnum_sta[0]=0\n'
}
acs_log="$HALOW_RUN_DIR/hostapd.log"
export HALOW_RADIO_ACS_POLL_S=0.2
sleep 900 & live_pid=$!
for bw in 1 2 4 8; do
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        f=$((902000 + 500 * ch))
        render manual "$bw" "$ch"
        halow_radio_parse_status "$(status_text "$f" "$bw")"; rc=$?
        assert_eq "0|$ch|$f|$bw|1|0|ENABLED" "$rc|$HALOW_EFF_CHANNEL|$HALOW_EFF_FREQ_KHZ|$HALOW_EFF_BW_MHZ|$HALOW_EFF_PRIM_WIDTH|$HALOW_EFF_PRIM_INDEX|$HALOW_EFF_STATE" "status of $bw MHz channel $ch parses to the rendered channel, frequency, width, primary width and index"
        out="$(halow_radio_check_effective AU "$bw" "$ch")"; rc=$?
        assert_eq "0|" "$rc|$out" "status of $bw MHz channel $ch is consistent with the manual selection"
        # Automatic selection: the access point's own completion event for this channel.
        printf 'wlx001122: interface state UNINITIALIZED->ACS\nwlx001122: ACS-STARTED \nwlx001122: ACS-COMPLETED freq=%s channel=%s\n' "$f" "$ch" > "$acs_log"
        halow_radio_acs_wait "$acs_log" "$live_pid" 5 AU 0; rc=$?
        assert_eq "0|$f|$ch" "$rc|$HALOW_ACS_FREQ_KHZ|$HALOW_ACS_CHANNEL" "automatic selection of $bw MHz channel $ch is read from the completion event"
    done
    printf 'wlx001122: ACS-STARTED \nACS: Unable to collect survey data\nwlx001122: ACS-FAILED \n' > "$acs_log"
    halow_radio_acs_wait "$acs_log" "$live_pid" 5 AU 0; rc=$?
    assert_eq "1" "$rc" "an empty-survey failure is a failure ($bw MHz)"
    fb="${RADIO_EXPECT_FALLBACK[$bw]}"
    render fallback "$bw" ""
    assert_eq "0|fallback|$fb|$((902000 + 500 * fb))" "$?|$HALOW_RADIO_RENDER_MODE|$HALOW_RADIO_RENDER_CHANNEL|$HALOW_RADIO_RENDER_FREQ_KHZ" "the $bw MHz fallback is channel $fb and is labelled fallback"
done
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null || true

echo "-- d. the separate helper program is gone from the product --"
ROOT="$RADIO_ADDON_ROOT"
assert_eq "0" "$(grep -rIl -i 'morse_cli' "$ROOT/rootfs" | wc -l | tr -d ' ')" "nothing under rootfs/ (code, data tables, comments) mentions the helper program"
assert_failure "the rendered configuration does not mention it" grep -qi 'morse_cli' "$dest"
assert_failure "build.sh does not stage it" grep -qi 'morse_cli' "$ROOT/build.sh"
assert_failure "the Dockerfile does not mention it" grep -qi 'morse_cli' "$ROOT/Dockerfile"
assert_failure "the AppArmor profile does not mention it" grep -qi 'morse_cli' "$ROOT/apparmor.txt"
assert_failure "the artifact manifest has no entry for it" grep -qi 'morse_cli' "$ROOT/MANIFEST.sha256"
assert_failure "the provenance record has no row for it" grep -qi 'morse_cli' "$ROOT/provenance.psv"
assert_failure "the release-candidate checklist does not ask for it" grep -qi 'morse_cli' "$ROOT/tools/release_candidate_checklist.sh"
assert_failure "no staged copy exists" test -e "$ROOT/artifacts/morse_cli"
assert_eq "7" "$(grep -c 'copy_verified "' "$ROOT/build.sh" | tr -d ' ')" "build.sh stages seven files (the helper program is not one of them)"
if [ -f "$ROOT/artifacts/hostapd_s1g" ] && [ -f "$ROOT/artifacts/morse.ko" ]; then
    assert_eq "0" "$(grep -a -c 'morse_cli' "$ROOT/artifacts/hostapd_s1g")" "the staged hostapd_s1g contains no reference to the helper program"
    assert_eq "0" "$(grep -a -c 'morse_cli' "$ROOT/artifacts/hostapd_cli_s1g")" "the staged hostapd_cli_s1g contains no reference to the helper program"
    # CONFIG_MORSE_5GHZ_MAPPED must be compiled in. Without it the 2.1.0 probe-request filter
    # takes its fallback branch (channel and width -1) and drops EVERY probe request, and a
    # configuration parse would still pass. The log line below exists only in the mapped code.
    assert_success "the staged hostapd_s1g contains the mapped-channel code ('s1g mapped ht channel'), so CONFIG_MORSE_5GHZ_MAPPED was compiled in" grep -a -q -F 's1g mapped ht channel' "$ROOT/artifacts/hostapd_s1g"
    rel="rel_mm8108_2_1_0_2026_Jul_01"
    for f in hostapd_s1g hostapd_cli_s1g morse.ko dot11ah.ko; do
        assert_success "$f carries the release string $rel" grep -a -q -F -- "$rel" "$ROOT/artifacts/$f"
    done
else
    echo "  SKIP: the binaries are not staged here; the binary checks (no helper string, release strings, mapped-channel code: 8 assertions) were not run"
    SKIPPED=$((SKIPPED + 8))
fi

if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then
    echo "test_radio_stack_au: $HALOW_TEST_FAILURES of $HALOW_TEST_COUNT FAILED"
    exit 1
fi
echo "test_radio_stack_au: $HALOW_TEST_COUNT/$HALOW_TEST_COUNT passed, $SKIPPED assertions skipped (artifacts not staged; the release build must show 0 skipped)"
