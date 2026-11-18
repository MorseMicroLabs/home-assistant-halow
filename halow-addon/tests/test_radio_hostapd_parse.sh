#!/usr/bin/env bash
# Real-parser check: the bundled aarch64 hostapd_s1g reads every configuration that
# halow_radio_render produces (every AU width, every manual channel, automatic channel
# selection, and the fallback channel) and its own S1G validation
# (hostapd_config_s1g_val(): country + operating class, and channel unless ACS, primary
# width and 1 MHz index) must accept it.
#
# How it works: hostapd_s1g runs under user-mode emulation (qemu-aarch64; directly on an
# aarch64 host). It reads and validates the whole configuration file first; only then does
# it initialise the nl80211 driver, which fails here (no wireless device, no netlink
# family, a non-existent interface). So:
#   accepted  = no "errors found in configuration file" line, the S1G operating class was
#               validated ("s1g oper class: <n>, validated: <m>" with m >= 0), and the run
#               reached the driver stage (an nl80211 / driver-initialisation line);
#   rejected  = "<n> errors found in configuration file";
#   anything else (no recognisable outcome) fails the suite rather than passing silently.
# Negative controls (a wrong operating-class/channel pair and an invalid primary index)
# must be rejected under the same harness, proving the check can fail.
#
# This is an off-device parser check only: acceptance says nothing about whether a width
# or channel works on the target device. Nothing is transmitted; no device is touched.
# Skips (counting no assertions) when the bundled binary, the bundled template or an
# emulator is missing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_hostapd_parse =="
BIN="$RADIO_ADDON_ROOT/artifacts/hostapd_s1g"
TPL="$RADIO_ADDON_ROOT/artifacts/hostapd_s1g.conf"

skip() { echo "  SKIP: $1"; echo "test_radio_hostapd_parse: skipped (0 assertions)"; exit 0; }
[ -f "$BIN" ] || skip "bundled artifacts/hostapd_s1g is not staged (run build.sh to stage the artifacts)"
[ -f "$TPL" ] || skip "bundled artifacts/hostapd_s1g.conf is not staged"
RUNNER=()
case "$(uname -m)" in
    aarch64|arm64) RUNNER=() ;;
    *)
        if [ -n "${HALOW_TEST_QEMU:-}" ] && [ -x "$HALOW_TEST_QEMU" ]; then
            RUNNER=("$HALOW_TEST_QEMU")
        elif command -v qemu-aarch64 >/dev/null 2>&1; then
            RUNNER=(qemu-aarch64)
        elif command -v qemu-aarch64-static >/dev/null 2>&1; then
            RUNNER=(qemu-aarch64-static)
        else
            skip "no qemu-aarch64 emulator found (set HALOW_TEST_QEMU to one)"
        fi
        ;;
esac
if ! command -v timeout >/dev/null 2>&1; then
    skip "the timeout command is not available"
fi

radio_setup
TEST_PSK='Zq7-unique-parse-psk-5521'
ctrl_dir="$HALOW_TEST_TMP/ctrl"
mkdir -p "$ctrl_dir"
outf="$HALOW_TEST_TMP/hostapd.out"

# run_parse <conf> : sets PARSE_OUTCOME accepted|rejected|unknown and PARSE_DETAIL.
run_parse() {
    local conf="$1" run_conf="$HALOW_TEST_TMP/run.conf" line validated="" cfg_err=0 driver=0
    # Keep the control socket directory inside the temp dir (hostapd never gets that far
    # here, but nothing may touch the host's /var/run).
    sed "s#^ctrl_interface=.*#ctrl_interface=$ctrl_dir#" "$conf" > "$run_conf"
    timeout 60 "${RUNNER[@]}" "$BIN" -dd "$run_conf" > "$outf" 2>&1 < /dev/null
    while IFS= read -r line; do
        case "$line" in
            *"errors found in configuration file"*) cfg_err=1 ;;
            "s1g oper class: "*", validated: "*) validated="${line##*validated: }" ;;
            *"Failed to initialize driver"*|"nl80211: "*|*"Could not read interface"*) driver=1 ;;
        esac
    done < "$outf"
    PARSE_VALIDATED="${validated:-}"
    PARSE_DETAIL="validated=${validated:-none} config_errors=$cfg_err driver_stage=$driver"
    if [ "$cfg_err" -eq 1 ]; then
        PARSE_OUTCOME="rejected"
    elif [ "$driver" -eq 1 ] && [ -n "$validated" ] && [ "${validated#-}" = "$validated" ]; then
        PARSE_OUTCOME="accepted"
    else
        PARSE_OUTCOME="unknown"
    fi
}

render_to() { # render_to <dest> <mode> <bw> <channel>
    halow_radio_render AU "$2" "$3" "$4" halowparse0 HaLowNet "$TEST_PSK" halow-br0 32 "$1" 2>/dev/null
}

expect_accept() { # expect_accept <label> <conf>
    run_parse "$2"
    assert_eq "accepted" "$PARSE_OUTCOME" "hostapd_s1g accepts $1 ($PARSE_DETAIL)"
}

conf="$HALOW_RUN_DIR/hostapd.conf"
# hostapd's own bookkeeping line for the country: it records global operating classes
# 48..53 of the AU country under its internal "REVmf" channelisation value (3); this is not
# the driver's scheme (the driver is loaded with scheme 2). The operating class itself is
# what selects the 2024 AU classes (50..53), whose position in hostapd's class table is
# printed as "validated: <n>" (au22..au25 -> 22..25).
for bw in 1 2 4 8; do
    want_validated=$(( ${RADIO_EXPECT_OPCLASS[$bw]} - 28 ))
    render_to "$conf" automatic "$bw" ""; assert_eq "0" "$?" "render automatic $bw MHz"
    expect_accept "automatic $bw MHz (ACS, op_class ${RADIO_EXPECT_OPCLASS[$bw]})" "$conf"
    assert_eq "$want_validated" "$PARSE_VALIDATED" "automatic $bw MHz: hostapd resolves op_class ${RADIO_EXPECT_OPCLASS[$bw]} to its AU class entry $want_validated"
    if grep -q "morse_ap_configure_channelization: channelization scheme 3 country AU" "$outf"; then r=0; else r=1; fi
    assert_eq "0" "$r" "automatic $bw MHz: hostapd's own bookkeeping line for country AU is the expected one"
    render_to "$conf" fallback "$bw" ""; assert_eq "0" "$?" "render fallback $bw MHz"
    expect_accept "fallback $bw MHz channel ${RADIO_EXPECT_FALLBACK[$bw]}" "$conf"
    if grep -q "^s1g channel ${RADIO_EXPECT_FALLBACK[$bw]}\$" "$outf"; then r=0; else r=1; fi
    assert_eq "0" "$r" "fallback $bw MHz: hostapd validated channel ${RADIO_EXPECT_FALLBACK[$bw]}"
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        render_to "$conf" manual "$bw" "$ch"
        expect_accept "manual $bw MHz channel $ch" "$conf"
        assert_eq "$want_validated" "$PARSE_VALIDATED" "manual $bw MHz channel $ch: op_class ${RADIO_EXPECT_OPCLASS[$bw]} resolved to AU class entry $want_validated"
        if grep -q "^s1g channel $ch\$" "$outf"; then r=0; else r=1; fi
        assert_eq "0" "$r" "manual $bw MHz channel $ch: hostapd validated that channel"
    done
done

# Negative controls: the same harness must report rejection. Each starts from a valid
# rendering and changes one thing, so a pass proves the check can fail and that hostapd
# itself enforces the AU class and channel masks (au22..au25; the 2024 and REVmf lists share
# them). The start-time query of the driver scheme and the switch to hostapd's 2024 data
# are not covered here: they need the driver and firmware and are live-only.
neg="$HALOW_TEST_TMP/negative.conf"
mutate_reject() { # mutate_reject <label> <bw> <channel> <sed expression>
    render_to "$conf" manual "$2" "$3"
    sed "$4" "$conf" > "$neg"
    run_parse "$neg"
    assert_eq "rejected" "$PARSE_OUTCOME" "negative control: $1 is rejected ($PARSE_DETAIL)"
}
mutate_reject "the 802.11-2020 class 68 with the 1 MHz channel 28" 1 28 's/^op_class=50$/op_class=68/'
mutate_reject "the 802.11-2020 class 70 with the 1 MHz channel 28" 1 28 's/^op_class=50$/op_class=70/'
mutate_reject "the 8 MHz class 53 with the 1 MHz channel 28" 1 28 's/^op_class=50$/op_class=53/'
mutate_reject "the 2 MHz class 51 with the 1 MHz channel 42" 1 42 's/^op_class=50$/op_class=51/'
mutate_reject "the 1 MHz class 50 with the 2 MHz channel 29" 2 29 's/^op_class=51$/op_class=50/'
mutate_reject "the 4 MHz class 52 with the 8 MHz channel 43" 8 43 's/^op_class=53$/op_class=52/'
mutate_reject "the 8 MHz class 53 with the 4 MHz channel 39" 4 39 's/^op_class=52$/op_class=53/'
mutate_reject "class 50 with the removed channel 27" 1 28 's/^channel=28$/channel=27/'
mutate_reject "class 50 with the removed channel 51" 1 28 's/^channel=28$/channel=51/'
mutate_reject "class 50 with the 8 MHz channel 43" 1 42 's/^channel=42$/channel=43/'
mutate_reject "class 50 with the 2 MHz channel 29" 1 28 's/^channel=28$/channel=29/'
mutate_reject "class 53 with the 1 MHz channel 44" 8 43 's/^channel=43$/channel=44/'
mutate_reject "class 51 with the 1 MHz channel 30" 2 29 's/^channel=29$/channel=30/'
mutate_reject "class 52 with the 1 MHz channel 32" 4 31 's/^channel=31$/channel=32/'
mutate_reject "primary 1 MHz index 2 at 2 MHz" 2 29 's/^s1g_prim_1mhz_chan_index=0$/s1g_prim_1mhz_chan_index=2/'
mutate_reject "a 2 MHz primary inside a 1 MHz channel" 1 28 's/^s1g_prim_chwidth=0$/s1g_prim_chwidth=1/'

rm -f -- "$outf" "$HALOW_TEST_TMP/run.conf" "$neg"
halow_test_teardown
radio_summary test_radio_hostapd_parse
