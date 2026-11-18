#!/usr/bin/env bash
# The effective primary channel configuration: a table-driven check over EVERY AU width and
# channel that the rendered hostapd configuration and the derived primary 1 MHz channel are
# valid (in the AU 1 MHz list, inside the regulatory spans) and equal the documented
# derivation; golden files of the rendered configuration for 8 MHz channels 35 and 43
# (secret redacted); warm and cold renders are identical; and the derived primary values are
# kept out of the status snapshot (they are calculated, not read from the radio).
#
# Documented derivation (hostap src/utils/morse.c morse_calculate_primary_s1g_channel(), used
# for AU centre channels up to 50):
#   primary 1 MHz channel = centre - (width - 1) + 2 x index;  frequency = 902000 kHz + 500 kHz x channel
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_primary =="
radio_setup
PSK='Qm4-primary-golden-psk-2207'
dest="$HALOW_RUN_DIR/hostapd.conf"
render() { # render <mode> <bw> <channel>
    rm -f -- "$dest"
    halow_radio_render AU "$1" "$2" "$3" wlx001122 "HaLowNet" "$PSK" halow-br0 64 "$dest" > "$HALOW_TEST_TMP/render.out" 2>&1
}

# The primary 1 MHz channels typed out, independent of the formula and of the table:
# "<width>:<centre>=<primary>" for primary index 0.
declare -A LITERAL_PRIMARY=(
    ["2:29"]=28 ["2:33"]=32 ["2:37"]=36 ["2:41"]=40 ["2:45"]=44 ["2:49"]=48
    ["4:31"]=28 ["4:39"]=36 ["4:47"]=44
    ["8:35"]=28 ["8:43"]=36
)

echo "-- every AU width and channel: rendered values valid and equal to the documented derivation --"
count=0
for bw in 1 2 4 8; do
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        count=$((count + 1))
        label="${bw} MHz channel ${ch}"
        render manual "$bw" "$ch"
        assert_eq "0" "$?" "$label: renders"
        op="$(radio_conf_value "$dest" op_class)"
        pw="$(radio_conf_value "$dest" s1g_prim_chwidth)"
        pi="$(radio_conf_value "$dest" s1g_prim_1mhz_chan_index)"
        rch="$(radio_conf_value "$dest" channel)"
        assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$op" "$label: operating class"
        assert_eq "$ch" "$rch" "$label: rendered channel"
        assert_eq "0" "$pw" "$label: 1 MHz primary"
        assert_success "$label: primary index is within the channel (0 .. width-1)" test "$pi" -ge 0 -a "$pi" -le $((bw - 1))
        prim=$((ch - (bw - 1) + 2 * pi))
        pfreq=$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * prim))
        assert_success "$label: derived primary $prim is in the AU 1 MHz list" bash -c 'case " $1 " in *" $2 "*) exit 0;; esac; exit 1' _ "${RADIO_EXPECT_CHANNELS[1]}" "$prim"
        assert_success "$label: primary $pfreq kHz lies inside a regulatory span" radio_in_reg_span "$pfreq" 1
        assert_success "$label: primary lies inside the operating channel" test "$pfreq" -ge $((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * ch - bw * 500)) -a "$pfreq" -le $((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * ch + bw * 500))
        if [ "$bw" -ne 1 ]; then
            assert_eq "${LITERAL_PRIMARY["$bw:$ch"]}" "$prim" "$label: primary equals the documented value"
        else
            assert_eq "$ch" "$prim" "$label: a 1 MHz channel is its own primary"
        fi
        # The library's own derivation agrees with the independent one.
        halow_radio_primary_info AU "$bw" "$ch"
        assert_eq "$prim" "$HALOW_PRIM_1MHZ_CHANNEL" "$label: halow_radio_primary_info channel"
        assert_eq "$pfreq" "$HALOW_PRIM_1MHZ_KHZ" "$label: halow_radio_primary_info frequency"
        assert_eq "$op" "$HALOW_PRIM_OP_CLASS" "$label: halow_radio_primary_info operating class"
        assert_eq "$pi" "$HALOW_PRIM_INDEX" "$label: halow_radio_primary_info index"
        assert_eq "1" "$HALOW_PRIM_BW_MHZ" "$label: primary bandwidth 1 MHz"
        assert_eq "$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * ch))" "$HALOW_PRIM_CENTRE_KHZ" "$label: centre frequency"
    done
done
assert_eq "23" "$count" "all 23 AU channels were checked (12 + 6 + 3 + 2)"

echo "-- every valid primary index of every AU channel: a primary in the AU 1 MHz list, inside the operating channel --"
# The index ranges: 2 MHz 0-1, 4 MHz 0-3, 8 MHz 0-7. The primary 1 MHz channel is
# centre - (width - 1) + 2 x index (2 MHz: centre - 1 and centre + 1).
declare -A INDEX_MAX=( [2]=1 [4]=3 [8]=7 )
idx_checked=0
for bw in 2 4 8; do
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        lo=$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * ch - bw * 500))
        hi=$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * ch + bw * 500))
        seen=""
        for (( idx = 0; idx <= INDEX_MAX[$bw]; idx++ )); do
            idx_checked=$((idx_checked + 1))
            prim=$((ch - (bw - 1) + 2 * idx))
            pfreq=$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * prim))
            seen="$seen $prim"
            assert_success "${bw} MHz channel ${ch} index ${idx}: primary ${prim} is in the AU 1 MHz list" bash -c 'case " $1 " in *" $2 "*) exit 0;; esac; exit 1' _ "${RADIO_EXPECT_CHANNELS[1]}" "$prim"
            assert_success "${bw} MHz channel ${ch} index ${idx}: primary ${prim} lies inside the operating channel" test "$pfreq" -ge "$lo" -a "$pfreq" -le "$hi"
            assert_success "${bw} MHz channel ${ch} index ${idx}: primary ${prim} is an even channel in 28-50" bash -c '[ $(( $1 % 2 )) -eq 0 ] && [ "$1" -ge 28 ] && [ "$1" -le 50 ]' _ "$prim"
        done
        assert_eq "$((INDEX_MAX[$bw] + 1))" "$(printf '%s\n' $seen | sort -u | wc -l | tr -d ' ')" "${bw} MHz channel ${ch}: every index gives a different primary"
    done
done
assert_eq "$((6 * 2 + 3 * 4 + 2 * 8))" "$idx_checked" "all 40 (channel, index) pairs were checked (6 x 2 + 3 x 4 + 2 x 8)"

echo "-- values for the two 8 MHz channels, written out --"
halow_radio_primary_info AU 8 43
assert_eq "53 43 8 1 0 36 920000 923500" "$HALOW_PRIM_OP_CLASS $HALOW_PRIM_CHANNEL $HALOW_PRIM_WIDTH_MHZ $HALOW_PRIM_BW_MHZ $HALOW_PRIM_INDEX $HALOW_PRIM_1MHZ_CHANNEL $HALOW_PRIM_1MHZ_KHZ $HALOW_PRIM_CENTRE_KHZ" "channel 43: class 53, primary 1 MHz channel 36 at 920.0 MHz, index 0, centre 923.5 MHz"
halow_radio_primary_info AU 8 35
assert_eq "53 35 8 1 0 28 916000 919500" "$HALOW_PRIM_OP_CLASS $HALOW_PRIM_CHANNEL $HALOW_PRIM_WIDTH_MHZ $HALOW_PRIM_BW_MHZ $HALOW_PRIM_INDEX $HALOW_PRIM_1MHZ_CHANNEL $HALOW_PRIM_1MHZ_KHZ $HALOW_PRIM_CENTRE_KHZ" "channel 35: class 53, primary 1 MHz channel 28 at 916.0 MHz, index 0, centre 919.5 MHz"
assert_failure "an unknown channel is refused" halow_radio_primary_info AU 8 40
assert_eq "" "$HALOW_PRIM_1MHZ_CHANNEL" "and leaves no value behind"
assert_failure "an unknown width is refused" halow_radio_primary_info AU 3 35
assert_failure "an unknown region is refused" halow_radio_primary_info XX 8 35

echo "-- golden files: the rendered configuration of 8 MHz channels 35 and 43 (secret redacted) --"
# EVERY rendered key=value line, sorted, with only the passphrase value replaced (no key
# whitelist): a newly rendered key shows up as a diff against tests/fixtures.
golden_view() {
    awk -F= '
        /^[A-Za-z0-9_]+=/ { key = $1; if (key == "wpa_passphrase") { print key "=[redacted]"; next } print }
    ' "$1" | LC_ALL=C sort
}
for ch in 35 43; do
    # Labs release tree: the golden files were recorded against the staged hostapd template
    # (artifacts/, not committed); compare only where it is staged.
    if [ ! -f ../artifacts/hostapd_s1g.conf ]; then
        echo "  SKIP: ../artifacts/hostapd_s1g.conf is not staged; golden comparison for channel $ch not run"
        continue
    fi
    render manual 8 "$ch"
    golden="fixtures/hostapd_au_8mhz_ch${ch}.golden"
    golden_view "$dest" > "$HALOW_TEST_TMP/actual.golden"
    if [ -f "$golden" ]; then
        if diff -u "$golden" "$HALOW_TEST_TMP/actual.golden" > "$HALOW_TEST_TMP/golden.diff"; then
            assert_eq "0" "0" "the rendered configuration for 8 MHz channel $ch matches its golden file"
        else
            sed 's/^/    | /' "$HALOW_TEST_TMP/golden.diff"
            assert_eq "match" "differs" "the rendered configuration for 8 MHz channel $ch matches its golden file"
        fi
    else
        assert_eq "present" "missing" "golden file $golden exists"
    fi
    assert_failure "the golden view holds no passphrase" grep -qF "$PSK" "$HALOW_TEST_TMP/actual.golden"
done
assert_failure "the two goldens differ only in the channel" bash -c '[ "$(diff fixtures/hostapd_au_8mhz_ch35.golden fixtures/hostapd_au_8mhz_ch43.golden | grep -c "^[<>]")" -ne 2 ]'

echo "-- warm and cold renders are byte-identical --"
render manual 8 43; cp "$dest" "$HALOW_TEST_TMP/warm.conf"
render manual 8 35; rm -f "$dest"                       # a different run in between (the previous configuration is gone)
unset _HALOW_RADIO_REGION_ROW _HALOW_RADIO_WIDTH_ROW _HALOW_RADIO_WIDTHS _HALOW_RADIO_REGIONS    # a fresh process state: the table is parsed again
render manual 8 43; cp "$dest" "$HALOW_TEST_TMP/cold.conf"
assert_success "the cold render of channel 43 equals the warm one byte for byte" cmp -s "$HALOW_TEST_TMP/warm.conf" "$HALOW_TEST_TMP/cold.conf"
render automatic 8 ""; cp "$dest" "$HALOW_TEST_TMP/auto1.conf"
render automatic 8 ""; cp "$dest" "$HALOW_TEST_TMP/auto2.conf"
assert_success "two automatic renders are identical too" cmp -s "$HALOW_TEST_TMP/auto1.conf" "$HALOW_TEST_TMP/auto2.conf"

echo "-- the derived primary values are not in the status snapshot (they are not read from the radio) --"
halow_test_teardown
. ./helpers_status.sh
halow_status_test_setup
export HALOW_STATE_NOW=1000
halow_state_init >/dev/null 2>&1
halow_state_radio_effective 923500 43 8 manual implemented none >/dev/null
F="$HALOW_STATUS_FILE"
halow_state_flush
assert_eq "true" "$(json_get "$F" '"primary" not in d["radio"]')" "the snapshot's radio section carries no primary object"
assert_failure "the state function that stored the derived values no longer exists" declare -F halow_state_radio_primary
halow_state_radio_clear_effective
assert_eq "true" "$(json_get "$F" '"primary" not in d["radio"]')" "and none after the access point is down"
halow_state_diag_set radio_primary_derived "configured/derived from the profile table, NOT read from the radio: op_class=53"
halow_state_flush
assert_eq "configured/derived from the profile table, NOT read from the radio: op_class=53" "$(json_get "$F" 'd["diagnostics"]["radio_primary_derived"]')" "the derived values stay available as a labelled diagnostics entry"
halow_status_test_teardown

echo
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then
    echo "test_radio_primary: $HALOW_TEST_FAILURES of $HALOW_TEST_COUNT FAILED"
    exit 1
fi
echo "test_radio_primary: $HALOW_TEST_COUNT/$HALOW_TEST_COUNT passed"
