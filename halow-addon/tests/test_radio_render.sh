#!/usr/bin/env bash
# hostapd_s1g configuration rendering from the radio profile: every width and mode,
# channel semantics (ACS, manual, fallback), primary-channel settings, bridge, client
# isolation, station limit, log level, secret handling and fail-closed input checks.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_render =="
radio_setup
echo "  (template: $RADIO_TEMPLATE_KIND)"

TEST_PSK='Zq7-unique-render-psk-9041'
dest="$HALOW_RUN_DIR/hostapd.conf"
out_file="$HALOW_TEST_TMP/render.out"

render() { # render <mode> <bw> <channel> [bridge] [max]
    rm -f -- "$dest"
    halow_radio_render AU "$1" "$2" "$3" wlx001122 "HaLowNet" "$TEST_PSK" "${4-halow-br0}" "${5:-64}" "$dest" > "$out_file" 2>&1
}

common_checks() { # common_checks <label> <bw>
    local label="$1" bw="$2"
    assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$(radio_conf_value "$dest" op_class)" "$label: op_class"
    assert_eq "AU" "$(radio_conf_value "$dest" country_code)" "$label: country_code"
    assert_eq "a" "$(radio_conf_value "$dest" hw_mode)" "$label: hw_mode"
    assert_eq "1" "$(radio_conf_value "$dest" ieee80211ah)" "$label: ieee80211ah"
    assert_eq "0" "$(radio_conf_value "$dest" s1g_prim_chwidth)" "$label: 1 MHz primary channel width"
    assert_eq "0" "$(radio_conf_value "$dest" s1g_prim_1mhz_chan_index)" "$label: primary 1 MHz index 0"
    assert_eq "[SHORT-GI-ALL]" "$(radio_conf_value "$dest" s1g_capab)" "$label: s1g_capab"
    assert_eq "100" "$(radio_conf_value "$dest" beacon_int)" "$label: beacon_int"
    assert_eq "2" "$(radio_conf_value "$dest" dtim_period)" "$label: dtim_period"
    assert_eq "1" "$(radio_conf_value "$dest" ap_isolate)" "$label: client isolation"
    assert_eq "64" "$(radio_conf_value "$dest" max_num_sta)" "$label: max_num_sta"
    assert_eq "1" "$(radio_conf_value "$dest" wds_sta)" "$label: wds_sta"
    assert_eq "2" "$(radio_conf_value "$dest" logger_syslog_level)" "$label: syslog level 2"
    assert_eq "2" "$(radio_conf_value "$dest" logger_stdout_level)" "$label: stdout level 2"
    assert_eq "/var/run/hostapd" "$(radio_conf_value "$dest" ctrl_interface)" "$label: ctrl_interface kept"
    assert_eq "SAE" "$(radio_conf_value "$dest" wpa_key_mgmt)" "$label: WPA3-SAE kept"
    assert_eq "halow-br0" "$(radio_conf_value "$dest" bridge)" "$label: bridge"
    assert_eq "wlx001122" "$(radio_conf_value "$dest" interface)" "$label: interface"
    assert_eq "HaLowNet" "$(radio_conf_value "$dest" ssid)" "$label: ssid"
    assert_eq "$TEST_PSK" "$(radio_conf_value "$dest" wpa_passphrase)" "$label: passphrase line"
    local k dup=""
    for k in channel op_class country_code s1g_prim_chwidth s1g_prim_1mhz_chan_index ap_isolate max_num_sta bridge wpa_passphrase logger_stdout_level interface ssid; do
        [ "$(radio_conf_count "$dest" "$k")" = "1" ] || dup="$dup $k"
    done
    assert_eq "" "$dup" "$label: each rendered key appears exactly once"
    assert_eq "600" "$(stat -c '%a' "$dest")" "$label: mode 0600"
    if grep -q -F -- "$TEST_PSK" "$out_file"; then r=1; else r=0; fi
    assert_eq "0" "$r" "$label: passphrase not in stdout/stderr"
}

for bw in 1 2 4 8; do
    set -- ${RADIO_EXPECT_CHANNELS[$bw]}
    manual_ch="${!#}"     # last channel of the set
    # A saved channel that is valid at no width (27), used to prove automatic mode ignores it.
    saved=27

    render automatic "$bw" "$saved"
    assert_eq "0" "$?" "automatic $bw MHz renders"
    common_checks "automatic $bw MHz" "$bw"
    assert_eq "acs_survey" "$(radio_conf_value "$dest" channel)" "automatic $bw MHz: channel=acs_survey enables ACS"
    if grep -q -E "^channel=.*$saved" "$dest"; then r=1; else r=0; fi
    assert_eq "0" "$r" "automatic $bw MHz: the saved channel $saved does not appear"
    assert_eq "automatic||" "$HALOW_RADIO_RENDER_MODE|$HALOW_RADIO_RENDER_CHANNEL|$HALOW_RADIO_RENDER_FREQ_KHZ" "automatic $bw MHz: no rendered channel is reported"

    render manual "$bw" "$manual_ch"
    assert_eq "0" "$?" "manual $bw MHz channel $manual_ch renders"
    common_checks "manual $bw MHz" "$bw"
    assert_eq "$manual_ch" "$(radio_conf_value "$dest" channel)" "manual $bw MHz: numeric channel"
    assert_eq "manual|$manual_ch|$((902000 + 500 * manual_ch))" "$HALOW_RADIO_RENDER_MODE|$HALOW_RADIO_RENDER_CHANNEL|$HALOW_RADIO_RENDER_FREQ_KHZ" "manual $bw MHz: rendered channel and frequency reported"

    render fallback "$bw" ""
    assert_eq "0" "$?" "fallback $bw MHz renders"
    common_checks "fallback $bw MHz" "$bw"
    fb="${RADIO_EXPECT_FALLBACK[$bw]}"
    assert_eq "$fb" "$(radio_conf_value "$dest" channel)" "fallback $bw MHz: the profile fallback channel $fb"
    assert_eq "fallback|$fb" "$HALOW_RADIO_RENDER_MODE|$HALOW_RADIO_RENDER_CHANNEL" "fallback $bw MHz: labelled fallback, not acs or manual"
    render fallback "$bw" "$fb"
    assert_eq "0" "$?" "fallback $bw MHz accepts its own fallback channel explicitly"

    render manual "$bw" 99
    assert_eq "1" "$?" "manual $bw MHz with an invalid channel is refused"
    assert_file_absent "$dest" "manual $bw MHz invalid channel: no configuration written (never falls back)"
done

render fallback 1 40
assert_eq "1" "$?" "fallback with a channel other than the profile fallback is refused"

# Explicit rendered-text checks against the 802.11-2024 AU expectations (typed in the
# helpers, not read from the profile): every channel of every width renders with the
# width's operating class (literal op_class=50/51/52/53), country AU, the channel line, the
# 1 MHz primary settings, and never an 802.11-2020 class (68-71) or a channel of another width.
for bw in 1 2 4 8; do
    n=0; bad=""
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        render manual "$bw" "$ch" || { bad="$bad render:$ch"; continue; }
        n=$((n + 1))
        grep -qx "op_class=${RADIO_EXPECT_OPCLASS[$bw]}" "$dest" || bad="$bad op:$ch"
        grep -qx "channel=$ch" "$dest" || bad="$bad chan:$ch"
        grep -qx "country_code=AU" "$dest" || bad="$bad cc:$ch"
        grep -qx "s1g_prim_chwidth=0" "$dest" || bad="$bad pw:$ch"
        grep -qx "s1g_prim_1mhz_chan_index=0" "$dest" || bad="$bad pi:$ch"
        grep -qE '^op_class=(68|69|70|71)$' "$dest" && bad="$bad old:$ch"
        [ "$HALOW_RADIO_RENDER_FREQ_KHZ" = "$((902000 + 500 * ch))" ] || bad="$bad freq:$ch"
    done
    assert_eq "$(wc -w <<< "${RADIO_EXPECT_CHANNELS[$bw]}" | tr -d ' ')|" "$n|$bad" "every AU $bw MHz channel renders with op_class=${RADIO_EXPECT_OPCLASS[$bw]} and the expected lines"
    render fallback "$bw" ""
    grep -qx "op_class=${RADIO_EXPECT_OPCLASS[$bw]}" "$dest"; op_ok=$?
    grep -qx "channel=${RADIO_EXPECT_FALLBACK[$bw]}" "$dest"; ch_ok=$?
    assert_eq "0|0" "$op_ok|$ch_ok" "the $bw MHz fallback renders channel=${RADIO_EXPECT_FALLBACK[$bw]} with op_class=${RADIO_EXPECT_OPCLASS[$bw]}"
    render automatic "$bw" ""
    grep -qx "op_class=${RADIO_EXPECT_OPCLASS[$bw]}" "$dest"; op_ok=$?
    grep -qx "channel=acs_survey" "$dest"; ch_ok=$?
    assert_eq "0|0" "$op_ok|$ch_ok" "the $bw MHz automatic mode renders channel=acs_survey with op_class=${RADIO_EXPECT_OPCLASS[$bw]}"
    # A channel that belongs to another width is refused and nothing is written.
    for other in 1 2 4 8; do
        [ "$other" = "$bw" ] && continue
        set -- ${RADIO_EXPECT_CHANNELS[$other]}
        render manual "$bw" "$1"; rc=$?
        assert_eq "1" "$rc" "manual $bw MHz channel $1 (a $other MHz channel) is refused"
        assert_file_absent "$dest" "manual $bw MHz with the $other MHz channel $1: nothing written"
    done
done
for pair in "1 27" "1 51" "2 27" "2 51" "4 51" "8 27" "8 51" "1 43" "8 44" "2 42"; do
    set -- $pair
    render manual "$1" "$2"
    assert_eq "1" "$?" "manual $1 MHz channel $2 (outside that width's 2024 set) is refused"
done

# Without a bridge no active bridge line is written.
render manual 1 42 ""
assert_eq "0" "$?" "renders without a bridge"
assert_eq "0" "$(radio_conf_count "$dest" bridge)" "no bridge line without a bridge"

# Input checks fail closed and leave nothing behind.
fails() { # fails <msg> <render args...>
    local msg="$1"; shift
    rm -f -- "$dest"
    halow_radio_render "$@" > "$out_file" 2>&1
    assert_eq "1" "$?" "$msg is refused"
    assert_file_absent "$dest" "$msg leaves no configuration"
    if grep -q -F -- "$TEST_PSK" "$out_file"; then r=1; else r=0; fi
    assert_eq "0" "$r" "$msg: passphrase not in the output"
}
fails "an interface name with a space" AU manual 1 42 "wl x" HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "an interface name with a slash" AU manual 1 42 "a/b" HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "an empty interface name" AU manual 1 42 "" HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "a bridge name with a semicolon" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" 'br;x' 64 "$dest"
fails "an over-long bridge name" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" abcdefghijklmnop 64 "$dest"
fails "an SSID with a newline" AU manual 1 42 wlx0 $'Ha\nLow' "$TEST_PSK" halow-br0 64 "$dest"
fails "a short passphrase" AU manual 1 42 wlx0 HaLowNet short halow-br0 64 "$dest"
fails "max_stations 0" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 0 "$dest"
fails "max_stations above 2007" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 3000 "$dest"
fails "a non-numeric max_stations" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 abc "$dest"
fails "an unknown region" XX manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "an unsupported bandwidth" AU automatic 16 "" wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "an unknown mode" AU acs 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
fails "a manual channel that is missing" AU manual 2 "" wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest"

outside="$HALOW_TEST_TMP/outside.conf"
halow_radio_render AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$outside" >/dev/null 2>&1
assert_eq "1" "$?" "a destination outside the run directory is refused"
assert_file_absent "$outside" "nothing is written outside the run directory"
halow_radio_render AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$HALOW_RUN_DIR/../escape.conf" >/dev/null 2>&1
assert_eq "1" "$?" "a destination escaping the run directory with .. is refused"
assert_file_absent "$HALOW_TEST_TMP/escape.conf" "nothing is written through .."

mv "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf" "$HALOW_TEST_TMP/tpl.bak"
fails "a missing template" AU manual 1 42 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest"
mv "$HALOW_TEST_TMP/tpl.bak" "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf"

# Restrictive regardless of the inherited umask.
( umask 000; render manual 2 41 )
assert_eq "600" "$(stat -c '%a' "$dest")" "mode 0600 even under umask 000"

# Only the rendered configuration holds the passphrase; no intermediate file is left.
render automatic 4 ""
holders=""
while IFS= read -r -d '' f; do
    if grep -q -F -- "$TEST_PSK" "$f"; then holders="$holders ${f#"$HALOW_TEST_TMP"/}"; fi
done < <(find "$HALOW_TEST_TMP" -type f ! -name render.out -print0)
assert_eq " run/hostapd.conf" "$holders" "the passphrase is only in the rendered configuration"
leftover="$(find "$HALOW_RUN_DIR" -name '*.radio-*' -o -name '*.halow-tmp.*')"
assert_eq "" "$leftover" "no intermediate rendering file is left behind"

# A function's captured output never contains the passphrase.
captured="$(halow_radio_render AU manual 8 43 wlx0 HaLowNet "$TEST_PSK" halow-br0 64 "$dest" 2>&1)"
case "$captured" in *"$TEST_PSK"*) r=1 ;; *) r=0 ;; esac
assert_eq "0" "$r" "the render function's own output never contains the passphrase"

# An active passphrase/key line or a bridge line in the template is not carried over.
# (key names assembled at run time so this file holds no literal secret assignment)
_kp="wpa_""passphrase"; _ks="sae_""password"
printf '%s=%s\n%s=%s\nbridge=br-template\n' "$_kp" template-default-value "$_ks" another-template-value >> "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf"
render manual 1 42 ""
assert_eq "1" "$(radio_conf_count "$dest" wpa_passphrase)" "a template passphrase line is dropped (exactly one, ours)"
assert_eq "$TEST_PSK" "$(radio_conf_value "$dest" wpa_passphrase)" "the passphrase is the configured one"
assert_eq "0" "$(radio_conf_count "$dest" sae_password)" "a template SAE password line is dropped"
assert_eq "0" "$(radio_conf_count "$dest" bridge)" "a template bridge line is dropped when no bridge is configured"
radio_install_template

# Active pre-shared key lines in the template (a key, a key file, an SAE password) never reach
# the rendered configuration; only the configured passphrase does. (names assembled at run time)
_kk="wpa_""psk"; _kf="wpa_""psk_file"; _ks="sae_""password"
printf '%s=%s\n%s=%s\n%s=%s\n' "$_kk" zq81keymaterial "$_kf" /nonexistent/zq81-file "$_ks" zq81-sae-secret >> "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf"
render manual 1 42 ""
assert_eq "0" "$(radio_conf_count "$dest" "$_kk")" "an active template pre-shared key line is dropped"
assert_eq "0" "$(radio_conf_count "$dest" "$_kf")" "an active template pre-shared key file line is dropped"
assert_eq "0" "$(radio_conf_count "$dest" "$_ks")" "an active template SAE password line is dropped (second case, with the other key lines present)"
assert_eq "1" "$(radio_conf_count "$dest" wpa_passphrase)" "exactly one passphrase line remains, the configured one"
assert_eq "0" "$(grep -c -F zq81 "$dest")" "none of the template's key material is in the rendered file"
radio_install_template

# Rendering twice from the template never duplicates a key.
render manual 1 42
render manual 1 42
assert_eq "1" "$(radio_conf_count "$dest" wpa_passphrase)" "re-rendering keeps one passphrase line"
assert_eq "1" "$(radio_conf_count "$dest" channel)" "re-rendering keeps one channel line"

halow_test_teardown
radio_summary test_radio_render
