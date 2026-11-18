#!/usr/bin/env bash
# Radio profile table: integrity of the AU entries against the pinned sources, the
# per-width and per-fallback states, extensibility to further regions, fail-closed
# behaviour, and the release-readiness check (function and standalone tool).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_profiles =="
radio_setup

# --- AU table integrity -----------------------------------------------------------------
# Every expectation comes from the explicit tables in helpers_radio.sh (typed from the
# pinned driver/hostap sources), never from the profile file itself.
assert_success "AU has a profile for the supported adapter" halow_radio_profile_exists AU
assert_eq "1 2 4 8" "$(halow_radio_widths AU)" "AU offers exactly 1, 2, 4 and 8 MHz, none missing"
assert_eq "AU" "$(halow_radio_country AU)" "AU country code"
assert_eq "$RADIO_EXPECT_SCHEME" "$(halow_radio_scheme AU)" "AU uses channelisation scheme 2 (IEEE 802.11-2024)"
assert_eq "2" "$(halow_radio_scheme AU)" "AU channelisation scheme is the literal 2, not 1 (IEEE 802.11-2020)"

all_union=""
for bw in 1 2 4 8; do
    got="$(halow_radio_channels AU "$bw")"
    chans=""; freqs=""; formula_ok=1; span_ok=1; n=0
    while read -r c f; do
        [ -n "$c" ] || continue
        n=$((n + 1))
        chans="${chans}${chans:+ }$c"; freqs="${freqs}${freqs:+ }$f"
        [ "$f" -eq $((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * c)) ] || formula_ok=0
        radio_in_reg_span "$f" "$bw" || span_ok=0
        all_union="$all_union $c"
    done <<< "$got"
    assert_eq "${RADIO_EXPECT_CHANNELS[$bw]}" "$chans" "AU $bw MHz channel set is exactly the 802.11-2024 set"
    assert_eq "${RADIO_EXPECT_FREQS[$bw]}" "$freqs" "AU $bw MHz centre frequencies (kHz) are exactly the expected list"
    assert_eq "$(wc -w <<< "${RADIO_EXPECT_CHANNELS[$bw]}" | tr -d ' ')" "$n" "AU $bw MHz channel count"
    assert_eq "1" "$formula_ok" "AU $bw MHz frequencies are 902000 + 500 x channel kHz"
    assert_eq "1" "$span_ok" "AU $bw MHz channels lie inside the regulatory spans (915.5-923.5, 919.5-927.5 MHz)"
    assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$(halow_radio_op_class AU "$bw")" "AU $bw MHz operating class (50/51/52/53)"
    assert_eq "implemented" "$(halow_radio_width_state AU "$bw")" "AU $bw MHz is implemented, not live-validated"
    fb="$(halow_radio_fallback_channel AU "$bw")"
    assert_eq "${RADIO_EXPECT_FALLBACK[$bw]}" "$fb" "AU $bw MHz fallback candidate channel"
    assert_eq "$(radio_expect_nearest "$bw")" "$fb" "AU $bw MHz fallback is the channel nearest 923.5 MHz (lower on a tie)"
    in_set=0
    for c in ${RADIO_EXPECT_CHANNELS[$bw]}; do [ "$c" = "$fb" ] && in_set=1; done
    assert_eq "1" "$in_set" "AU $bw MHz fallback is in that width's channel set"
    assert_eq "candidate" "$(halow_radio_fallback_state AU "$bw")" "AU $bw MHz fallback is a candidate"
    assert_eq "$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * fb))" "$(halow_radio_channel_freq AU "$bw" "$fb")" "AU $bw MHz fallback frequency"
    # The removed edge channels, and every channel of another width, are not in this set.
    for ch in 27 51; do
        assert_failure "AU $bw MHz does not contain channel $ch" halow_radio_channel_freq AU "$bw" "$ch"
    done
    r=0
    for other in 1 2 4 8; do
        [ "$other" = "$bw" ] && continue
        for ch in ${RADIO_EXPECT_CHANNELS[$other]}; do
            if halow_radio_channel_freq AU "$bw" "$ch" >/dev/null 2>&1; then r=1; fi
        done
    done
    assert_eq "0" "$r" "AU $bw MHz contains no channel of any other width's set"
done
ops="$(halow_radio_op_class AU 1) $(halow_radio_op_class AU 2) $(halow_radio_op_class AU 4) $(halow_radio_op_class AU 8)"
assert_eq "50 51 52 53" "$ops" "AU operating classes are 50 51 52 53 for 1 2 4 8 MHz"
case " $ops " in *" 68 "*|*" 69 "*|*" 70 "*|*" 71 "*) r=1 ;; *) r=0 ;; esac
assert_eq "0" "$r" "no 802.11-2020 operating class (68-71) is reported"
assert_eq "0" "$(grep -c -E '^width\|[^|]*\|[^|]*\|[0-9]+\|(68|69|70|71)\|' "$RADIO_TABLE_SRC")" "no width row of the table carries operating class 68-71"
# The union of all channels is exactly 28..50, each channel in exactly one width.
union_sorted="$(printf '%s\n' $all_union | sort -n | tr '\n' ' ')"
all_28_50=""; for c in $(seq 28 50); do all_28_50="$all_28_50$c "; done
assert_eq "$all_28_50" "$union_sorted" "the union of all AU channels is exactly 28..50, each channel in exactly one width"
assert_eq "923500" "$(halow_radio_channel_freq AU 8 43)" "8 MHz channel 43 is 923.5 MHz"
assert_eq "924000" "$(halow_radio_channel_freq AU 1 44)" "1 MHz channel 44 is 924.0 MHz"
assert_eq "923000" "$(halow_radio_channel_freq AU 1 42)" "1 MHz channel 42 is 923.0 MHz"
assert_failure "1 MHz channel 43 does not exist (it is an 8 MHz channel)" halow_radio_channel_freq AU 1 43
assert_failure "8 MHz channel 44 does not exist (it is a 1 MHz channel)" halow_radio_channel_freq AU 8 44
assert_failure "2 MHz channel 42 does not exist (it is a 1 MHz channel)" halow_radio_channel_freq AU 2 42
assert_eq "12" "$(halow_radio_channels AU 1 | wc -l | tr -d ' ')" "12 channels at 1 MHz"
assert_eq "6" "$(halow_radio_channels AU 2 | wc -l | tr -d ' ')" "6 channels at 2 MHz"
assert_eq "3" "$(halow_radio_channels AU 4 | wc -l | tr -d ' ')" "3 channels at 4 MHz"
assert_eq "2" "$(halow_radio_channels AU 8 | wc -l | tr -d ' ')" "2 channels at 8 MHz"

live_rows=0
while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; *live-validated*) live_rows=$((live_rows + 1)) ;; esac
done < "$RADIO_TABLE_SRC"
assert_eq "0" "$live_rows" "no row of the shipped table is marked live-validated"

# The region row, read raw: scheme 2, hw_mode a, ah 1, frequency start/separation, beacon,
# DTIM and capabilities.
region_row=""
while IFS= read -r line; do
    case "$line" in "region|325b:8100|AU|"*) region_row="$line" ;; esac
done < "$RADIO_TABLE_SRC"
assert_eq "region|325b:8100|AU|AU|2|a|1|902000|500|100|2|[SHORT-GI-ALL]" "$region_row" "the AU region row: scheme 2, hw_mode a, ah 1, start 902000, separation 500, beacon 100, DTIM 2"

# Primary channel: a 1 MHz primary at index 0 for every width; the driver derives the primary
# channel as centre - 1 / - 3 / - 7 (2 / 4 / 8 MHz), which must be a channel of the 1 MHz set.
prim_ok=1; derived_ok=1; derived_list=""
for bw in 1 2 4 8; do
    row=""
    while IFS= read -r line; do
        case "$line" in "width|325b:8100|AU|$bw|"*) row="$line" ;; esac
    done < "$RADIO_TABLE_SRC"
    IFS='|' read -r _k _a _r _w _op _st pw pi _rest <<< "$row"
    [ "$pw" = "$RADIO_EXPECT_PRIM_WIDTH" ] || prim_ok=0
    [ "$pi" = "$RADIO_EXPECT_PRIM_INDEX" ] || prim_ok=0
    for c in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        p=$((c - RADIO_EXPECT_PRIM_OFFSET[$bw])); in1=0
        for c1 in ${RADIO_EXPECT_CHANNELS[1]}; do [ "$c1" = "$p" ] && in1=1; done
        [ "$in1" = 1 ] || derived_ok=0
        [ "$bw" = 1 ] || derived_list="$derived_list $bw:$c>$p"
    done
done
assert_eq "1" "$prim_ok" "every AU row has primary width 0 (1 MHz) and 1 MHz primary index 0"
assert_eq "1" "$derived_ok" "every derived primary channel (centre - 1/3/7) is a channel of the 1 MHz set"
assert_eq " 2:29>28 2:33>32 2:37>36 2:41>40 2:45>44 2:49>48 4:31>28 4:39>36 4:47>44 8:35>28 8:43>36" "$derived_list" "derived primary channels are 28/32/36/40/44/48, 28/36/44 and 28/36"

# --- unknown region / adapter fail closed --------------------------------------------------
assert_failure "an unknown region has no profile" halow_radio_profile_exists NZ
assert_failure "an empty region has no profile" halow_radio_profile_exists ""
assert_failure "widths of an unknown region fail" halow_radio_widths XX
assert_failure "an unsupported width has no state" halow_radio_width_state AU 16
assert_failure "an unsupported width has no channels" halow_radio_channels AU 3
assert_failure "an unsupported width has no fallback" halow_radio_fallback_channel AU 16
(
    HALOW_ADAPTER_PRODUCT_ID=9999
    if halow_radio_profile_exists AU; then exit 1; fi
    if halow_radio_widths AU >/dev/null 2>&1; then exit 1; fi
    exit 0
) 2>/dev/null
assert_eq "0" "$?" "an unknown adapter identity fails closed for AU"

# --- a synthetic second region in a copy of the table ------------------------------------
copy="$(radio_table_copy)"
cat >> "$copy" <<'EOF'
region|325b:8100|ZZ|ZZ|7|a|1|800000|500|100|2|[SHORT-GI-ALL]
width|325b:8100|ZZ|1|90|implemented|0|0|3|candidate|1:800500 3:801500 5:802500
width|325b:8100|ZZ|2|91|live-validated|0|1|4|live-validated|4:802000
region|abcd:0001|AU|AU|2|a|1|902000|500|100|2|[SHORT-GI-ALL]
width|abcd:0001|AU|1|50|implemented|0|0|42|candidate|42:923000
region|325b:8100|YY|YY|1|a|1|863000|500|100|2|[SHORT-GI-ALL]
width|325b:8100|YY|1|95|implemented|0|0|29|candidate|27:876500 29:877500
width|325b:8100|YY|4|96|implemented|0|0|31|candidate|31:878500
EOF
(
    HALOW_RADIO_PROFILES="$copy"
    rc=0
    halow_radio_profile_exists ZZ || rc=1
    [ "$(halow_radio_widths ZZ)" = "1 2" ] || rc=2
    [ "$(halow_radio_country ZZ)" = "ZZ" ] || rc=3
    [ "$(halow_radio_scheme ZZ)" = "7" ] || rc=4
    [ "$(halow_radio_width_state ZZ 2)" = "live-validated" ] || rc=5
    [ "$(halow_radio_fallback_channel ZZ 1)" = "3" ] || rc=6
    halow_radio_validate ZZ manual 1 5 >/dev/null || rc=7
    halow_radio_validate ZZ manual 1 4 >/dev/null && rc=8
    [ "$(halow_radio_widths AU)" = "1 2 4 8" ] || rc=9
    exit "$rc"
)
assert_eq "0" "$?" "a synthetic second region added to a copy of the table is accepted by the query and validation functions"
# A second, hypothetical scheme (1, different frequency start and operating classes) in the
# same copy is consumed by the same functions, including rendering, with no code change, and
# does not disturb AU (scheme 2).
(
    HALOW_RADIO_PROFILES="$copy"
    rc=0
    [ "$(halow_radio_scheme YY)" = "1" ] || rc=1
    [ "$(halow_radio_scheme AU)" = "2" ] || rc=2
    [ "$(halow_radio_widths YY)" = "1 4" ] || rc=3
    [ "$(halow_radio_op_class YY 1)" = "95" ] || rc=4
    [ "$(halow_radio_channel_freq YY 1 29)" = "877500" ] || rc=5
    halow_radio_validate YY manual 1 27 >/dev/null || rc=6
    halow_radio_validate AU manual 1 27 >/dev/null 2>&1 && rc=7
    halow_radio_validate YY manual 1 28 >/dev/null 2>&1 && rc=8
    halow_radio_validate YY manual 2 29 >/dev/null 2>&1 && rc=9
    [ "$(halow_radio_fallback_channel YY 4)" = "31" ] || rc=10
    [ "$(halow_radio_channel_freq AU 1 42)" = "923000" ] || rc=11
    exit "$rc"
)
assert_eq "0" "$?" "a second scheme (YY, scheme 1) coexists with AU (scheme 2) in one table: queries and validation are per region"
(
    HALOW_RADIO_PROFILES="$copy"
    rc=0
    dest="$HALOW_RUN_DIR/ext.conf"
    halow_radio_render YY manual 1 27 wlx0 HaLowNet 'Zq7-unique-ext-psk-3310' halow-br0 8 "$dest" >/dev/null 2>&1 || rc=1
    [ "$(radio_conf_value "$dest" country_code)" = "YY" ] || rc=2
    [ "$(radio_conf_value "$dest" op_class)" = "95" ] || rc=3
    [ "$(radio_conf_value "$dest" channel)" = "27" ] || rc=4
    halow_radio_render AU manual 1 42 wlx0 HaLowNet 'Zq7-unique-ext-psk-3310' halow-br0 8 "$dest" >/dev/null 2>&1 || rc=5
    [ "$(radio_conf_value "$dest" op_class)" = "50" ] || rc=6
    [ "$(radio_conf_value "$dest" channel)" = "42" ] || rc=7
    rm -f -- "$dest"
    exit "$rc"
)
assert_eq "0" "$?" "a hypothetical second region renders its own country code, operating class and channel with no code change"
(
    HALOW_RADIO_PROFILES="$copy"
    HALOW_ADAPTER_VENDOR_ID=abcd; HALOW_ADAPTER_PRODUCT_ID=0001
    rc=0
    [ "$(halow_radio_widths AU)" = "1" ] || rc=1
    halow_radio_profile_exists ZZ && rc=2
    exit "$rc"
)
assert_eq "0" "$?" "profiles are keyed by adapter identity: another adapter sees only its own rows"

# --- malformed tables fail closed ----------------------------------------------------------
bad="$HALOW_TEST_TMP/bad.psv"
for variant in \
    'width|325b:8100|AU|1|50|validated|0|0|42|candidate|42:923000' \
    'width|325b:8100|AU|1|50|implemented|0|0|43|candidate|42:923000' \
    'width|325b:8100|AU|2|51|implemented|0|2|41|candidate|41:922500' \
    'width|325b:8100|AU|1|50|implemented|1|0|42|candidate|42:923000' \
    'width|325b:8100|AU|1|50|implemented|0|0|42|candidate|42-923000' \
    'width|325b:8100|QQ|1|50|implemented|0|0|42|candidate|42:923000' \
    'bogus|325b:8100|AU|1'; do
    { printf 'region|325b:8100|AU|AU|2|a|1|902000|500|100|2|[SHORT-GI-ALL]\n'; printf '%s\n' "$variant"; } > "$bad"
    ( HALOW_RADIO_PROFILES="$bad"; halow_radio_profile_exists AU ) 2>/dev/null
    assert_eq "1" "$?" "a malformed table fails closed: $variant"
done
( HALOW_RADIO_PROFILES="$HALOW_TEST_TMP/missing.psv"; halow_radio_profile_exists AU ) 2>/dev/null
assert_eq "1" "$?" "a missing table fails closed"

# --- release readiness -------------------------------------------------------------------
out="$(halow_radio_release_readiness)"; rc=$?
assert_eq "1" "$rc" "release readiness fails while widths and fallbacks are unvalidated"
for bw in 1 2 4 8; do
    case "$out" in *"region=AU width_mhz=$bw state=implemented OUTSTANDING"*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "readiness lists AU $bw MHz as outstanding"
    case "$out" in *"region=AU width_mhz=$bw fallback_channel=${RADIO_EXPECT_FALLBACK[$bw]} fallback_state=candidate OUTSTANDING"*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "readiness lists the AU $bw MHz fallback as outstanding"
done
case "$out" in *"outstanding=8 of 8"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "readiness counts 8 outstanding items (four widths, four fallbacks)"
rw=""; rf=""
while IFS= read -r line; do
    case "$line" in
        "region=AU width_mhz="*" state="*) w="${line#*width_mhz=}"; rw="$rw${rw:+ }${w%% *}" ;;
        "region=AU width_mhz="*" fallback_channel="*) f="${line#*fallback_channel=}"; rf="$rf${rf:+ }${f%% *}" ;;
        "region="*) case "$line" in "region=AU "*) : ;; *) rw="$rw other-region" ;; esac ;;
    esac
done <<< "$out"
assert_eq "1 2 4 8" "$rw" "readiness reports exactly the AU width set 1 2 4 8 (no other region, none missing)"
assert_eq "${RADIO_EXPECT_FALLBACK[1]} ${RADIO_EXPECT_FALLBACK[2]} ${RADIO_EXPECT_FALLBACK[4]} ${RADIO_EXPECT_FALLBACK[8]}" "$rf" "readiness reports the fallback channels 42 41 39 43 in width order"

allv="$HALOW_TEST_TMP/all_validated.psv"
while IFS= read -r line; do
    line="${line//|implemented|/|live-validated|}"
    line="${line//|candidate|/|live-validated|}"
    printf '%s\n' "$line"
done < "$RADIO_TABLE_SRC" > "$allv"
( HALOW_RADIO_PROFILES="$allv"; halow_radio_release_readiness >/dev/null )
assert_eq "0" "$?" "readiness passes only when every width and fallback is live-validated"
partial="$HALOW_TEST_TMP/partial.psv"
sed 's/^width|325b:8100|AU|4|52|live-validated|/width|325b:8100|AU|4|52|implemented|/' "$allv" > "$partial"
out="$( HALOW_RADIO_PROFILES="$partial"; halow_radio_release_readiness )"; rc=$?
assert_eq "1" "$rc" "one unvalidated width keeps readiness failing"
case "$out" in *"width_mhz=4 state=implemented OUTSTANDING"*"outstanding=1 of 8"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "and names exactly that width"
( HALOW_RADIO_PROFILES="$HALOW_TEST_TMP/missing.psv"; halow_radio_release_readiness >/dev/null 2>&1 )
assert_eq "1" "$?" "readiness fails on a missing table"
for w in 1 2 4 8; do
    nowidth="$HALOW_TEST_TMP/no_${w}.psv"
    grep -v "^width|325b:8100|AU|$w|" "$allv" > "$nowidth"
    out="$( HALOW_RADIO_PROFILES="$nowidth"; halow_radio_release_readiness )"; rc=$?
    assert_eq "1" "$rc" "readiness fails when the required AU $w MHz width is missing (rest validated)"
    case "$out" in *"region=AU width_mhz=$w MISSING OUTSTANDING"*"outstanding=1 of 7"*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "and names the missing $w MHz width"
done
out="$( HALOW_RADIO_PROFILES="$allv"; HALOW_RADIO_REQUIRED_WIDTHS="AU:1 2 4 8 16"; halow_radio_release_readiness )"; rc=$?
assert_eq "1" "$rc" "a width required but absent from the table keeps readiness failing"
case "$out" in *"region=AU width_mhz=16 MISSING"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "and names it"
out="$( HALOW_RADIO_PROFILES="$allv"; HALOW_RADIO_REQUIRED_WIDTHS="AU:1 2 4 8;NZ:1"; halow_radio_release_readiness )"; rc=$?
assert_eq "1" "$rc" "a required region missing from the table keeps readiness failing"
case "$out" in *"region=NZ width_mhz=1 MISSING"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "and names the region's missing width"

tool="$RADIO_ADDON_ROOT/tools/release_readiness.sh"
out="$(env -u HALOW_RADIO_PROFILES bash "$tool" 2>&1)"; rc=$?
assert_eq "1" "$rc" "tools/release_readiness.sh exits non-zero for this build"
case "$out" in *"region=AU width_mhz=8 state=implemented OUTSTANDING"*"NOT release-ready"*) r=0 ;; *) r=1 ;; esac
assert_eq "0" "$r" "the tool reports the outstanding widths from the source-tree table"
HALOW_RADIO_PROFILES="$allv" bash "$tool" >/dev/null 2>&1
assert_eq "0" "$?" "the tool exits 0 for a fully validated table"

halow_test_teardown
radio_summary test_radio_profiles
