#!/usr/bin/env bash
# The configuration-form representation of `channel` and `uplink_interface`, tested through
# the REAL option loader and the REAL radio validator (test_options.sh stubs the radio
# validator): the schema keeps both always visible (channel is a list whose default is the
# sentinel "auto"; uplink_interface is a string whose default is empty), and the backend
# reads them exactly as it read the old absent values (a hidden optional entry).
#
#   - initial/default configuration (the defaults from config.yaml plus a passphrase)
#   - automatic mode: sentinel, integer, absent, empty and invalid channels are all ignored BY THE ADD-ON (Home Assistant itself refuses a value outside the schema list before the add-on runs)
#   - switching to manual mode: the sentinel is refused with the existing message, an
#     integer is checked against the selected bandwidth
#   - each bandwidth (1, 2, 4, 8) accepts exactly its own channels and refuses the others
#   - uplink: omitted, empty and explicit
#   - upgrade: saved options in which both optional keys are absent, and in which channel
#     is a saved integer (the Supervisor's list(...) check reads the value as a string)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_options_channel =="

CONFIG="../config.yaml"
PSV="../rootfs/usr/share/halow/radio_profiles.psv"

# The Australian IEEE 802.11-2024 channel sets, typed here independently of the radio profile
# table and of helpers_radio.sh, so that a wrong profile row or schema list fails the tests.
declare -A T_CH=(
    [1]="28 30 32 34 36 38 40 42 44 46 48 50"
    [2]="29 33 37 41 45 49"
    [4]="31 39 47"
    [8]="35 43"
)
T_UNION="$(printf '%s\n' ${T_CH[1]} ${T_CH[2]} ${T_CH[4]} ${T_CH[8]} | sort -n | paste -sd' ')"
assert_eq "$(seq 28 50 | paste -sd' ')" "$T_UNION" "table self-check: the four sets are disjoint and together exactly 28..50"

# setup <mode> <bandwidth> [channel]  — a complete valid set; channel left unset when omitted.
# The environment form stands in for bashio, as in test_options.sh.
setup() {
    radio_setup
    halow_subnet_collision() { return 0; }
    unset HALOW_OPT_CHANNEL HALOW_OPT_UPLINK_INTERFACE
    export HALOW_OPT_REGION="AU" HALOW_OPT_RADIO_MODE="$1" HALOW_OPT_BANDWIDTH="$2"
    [ "$#" -ge 3 ] && export HALOW_OPT_CHANNEL="$3"
    export HALOW_OPT_WIFI_SSID="HaLow-Network" HALOW_OPT_WIFI_PASSPHRASE="correct-horse-battery"
    export HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24" HALOW_OPT_DHCP_RANGE_START="192.168.90.50"
    export HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_ALLOWED_PORTS=""
}
run() { halow_options_load; halow_options_validate 2>/dev/null; }
check_ok() {   # <message>
    if run; then _r=0; else _r=$?; fi
    assert_eq "0" "$_r" "$1: valid"
}
check_refused() {   # <option> <reason substring> <message>
    if run; then _r=0; else _r=$?; fi
    assert_eq "1" "$_r" "$3: refused"
    assert_eq "CONFIG_INVALID" "$HALOW_CFG_ERROR_CODE" "$3: code"
    assert_eq "$1" "$HALOW_CFG_ERROR_OPTION" "$3: option named"
    case "$HALOW_CFG_ERROR_REASON" in *"$2"*) _r=0 ;; *) _r=1 ;; esac
    assert_eq "0" "$_r" "$3: reason mentions '$2' (got: $HALOW_CFG_ERROR_REASON)"
}

echo "-- initial configuration: the shipped defaults (channel auto, uplink empty) plus a passphrase --"
if python3 -c 'import yaml' >/dev/null 2>&1; then
    defaults="$(python3 - "$CONFIG" <<'PY'
import sys, yaml
o = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["options"]
for k in ("region", "radio_mode", "bandwidth", "channel", "uplink_interface"):
    print("%s=%s" % (k, o[k]))
PY
)"
    _d() { printf '%s\n' "$defaults" | sed -n "s/^$1=//p"; }
    radio_setup; halow_subnet_collision() { return 0; }
    export HALOW_OPT_REGION="$(_d region)" HALOW_OPT_RADIO_MODE="$(_d radio_mode)" HALOW_OPT_BANDWIDTH="$(_d bandwidth)"
    export HALOW_OPT_CHANNEL="$(_d channel)" HALOW_OPT_UPLINK_INTERFACE="$(_d uplink_interface)"
    export HALOW_OPT_WIFI_SSID="HaLow-Network" HALOW_OPT_WIFI_PASSPHRASE="correct-horse-battery"
    export HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24" HALOW_OPT_DHCP_RANGE_START="192.168.90.50"
    export HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_ALLOWED_PORTS=""
    assert_eq "auto" "$HALOW_OPT_CHANNEL" "the shipped channel default is the sentinel"
    check_ok "initial configuration from config.yaml defaults"
    assert_eq "" "$HALOW_CFG_CHANNEL" "initial configuration: no channel in effect"
    assert_eq "" "$HALOW_CFG_CHANNEL_SAVED" "initial configuration: the sentinel is not recorded as a 'saved channel'"
    assert_eq "" "$HALOW_CFG_UPLINK" "initial configuration: uplink empty (automatic)"
    halow_test_teardown

    echo "-- the form's list(...) check on a saved value (modelled on the Supervisor: membership of str(value)) --"
    schema_list="$(python3 - "$CONFIG" <<'PY'
import sys, re, yaml
s = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["schema"]["channel"]
print(re.match(r"^list\((.*)\)$", s).group(1))
PY
)"
    assert_eq "auto|$(printf '%s' "$T_UNION" | tr ' ' '|')" "$schema_list" "the schema list is exactly auto plus 28..50"
    psv_union="$(awk -F'|' '$1 == "width" { n = split($11, a, " "); for (i = 1; i <= n; i++) { split(a[i], c, ":"); print c[1] } }' "$PSV" | sort -nu | paste -sd' ')"
    assert_eq "$T_UNION" "$psv_union" "the union of the profile's per-width channel sets equals the table union (and so the schema list)"
    for bw in 1 2 4 8; do
        psv_bw="$(awk -F'|' -v bw="$bw" '$1 == "width" && $3 == "AU" && $4 == bw { n = split($11, a, " "); for (i = 1; i <= n; i++) { split(a[i], c, ":"); print c[1] } }' "$PSV" | sort -n | paste -sd' ')"
        assert_eq "${T_CH[$bw]}" "$psv_bw" "the profile's $bw MHz channel set equals the table"
    done
    # every non-auto schema value is valid for at least one bandwidth (through the real validator)
    for v in $(printf '%s' "$schema_list" | tr '|' ' '); do
        [ "$v" = "auto" ] && continue
        _any=0
        for bw in 1 2 4 8; do
            setup manual "$bw" "$v"
            if run; then _any=1; fi
            halow_test_teardown
        done
        assert_eq "1" "$_any" "schema channel $v is valid for at least one bandwidth"
    done
    for v in auto 28 29 35 42 43 44 50 "43"; do
        assert_success "the schema list accepts '$v'" python3 - "$CONFIG" "$v" <<'PY'
import sys, re, yaml
s = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["schema"]["channel"]
allowed = re.match(r"^list\((.*)\)$", s).group(1).split("|")
sys.exit(0 if str(sys.argv[2]) in allowed else 1)
PY
    done
    for v in 0 26 27 51 52 255 "" abc; do
        assert_failure "the schema list refuses '$v'" python3 - "$CONFIG" "$v" <<'PY'
import sys, re, yaml
s = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["schema"]["channel"]
allowed = re.match(r"^list\((.*)\)$", s).group(1).split("|")
sys.exit(0 if str(sys.argv[2]) in allowed else 1)
PY
    done
else
    YAML_MISSING=1
    echo "  note: python3 with the yaml module is not available; the config.yaml-driven checks were SKIPPED"
fi

echo "-- automatic mode: no channel value can influence it --"
for ch in auto "" 43 30 27 51 99 abc; do
    setup automatic 1 "$ch"
    check_ok "automatic, channel [$ch]"
    assert_eq "" "$HALOW_CFG_CHANNEL" "automatic, channel [$ch]: no channel in effect"
    halow_test_teardown
done
setup automatic 2
check_ok "automatic, channel key absent"
assert_eq "" "$HALOW_CFG_CHANNEL" "automatic, channel absent: no channel in effect"
halow_test_teardown
setup automatic 1 auto
run
assert_eq "" "$HALOW_CFG_CHANNEL_SAVED" "automatic, sentinel: nothing is reported as a saved channel"
halow_test_teardown
setup automatic 1 43
run
assert_eq "43" "$HALOW_CFG_CHANNEL_SAVED" "automatic, integer: kept for diagnostics only"
halow_test_teardown

echo "-- switching to manual mode --"
for ch in auto ""; do
    setup manual 1 "$ch"
    check_refused channel "manual mode requires a channel number" "manual, channel [$ch]"
    halow_test_teardown
done
setup manual 1
check_refused channel "manual mode requires a channel number" "manual, channel key absent"
halow_test_teardown
setup manual 1 42
check_ok "manual, 1 MHz, channel 42"
assert_eq "42" "$HALOW_CFG_CHANNEL" "manual: the chosen channel is the one in effect"
halow_test_teardown
setup manual 8 43
check_ok "manual, 8 MHz, channel 43"
assert_eq "43" "$HALOW_CFG_CHANNEL" "manual: the chosen channel is the one in effect"
halow_test_teardown
setup manual 1 abc
check_refused channel "manual mode requires a channel number" "manual, non-numeric channel"
halow_test_teardown

echo "-- every bandwidth accepts exactly its own channels in manual mode --"
# Every number from 26 to 52 (the 802.11-2024 range 28..50 and the numbers either side of it,
# which belong only to the earlier 2020 numbering) plus 0 and 99, against every bandwidth.
for bw in 1 2 4 8; do
    for ch in $(seq 26 52) 0 99; do
        setup manual "$bw" "$ch"
        if [[ " ${T_CH[$bw]} " == *" $ch "* ]]; then
            check_ok "${bw} MHz accepts channel $ch"
        else
            check_refused channel "channel $ch is not valid for $bw MHz" "${bw} MHz refuses channel $ch"
        fi
        halow_test_teardown
    done
done
echo "-- named cases from the 2024 channelisation --"
for bw_ch in "1 43" "8 44" "1 27" "1 51" "1 29" "2 30" "2 42" "4 32" "4 40" "4 48" "8 36" "8 28" "8 50" "4 35" "2 31"; do
    set -- $bw_ch
    setup manual "$1" "$2"
    check_refused channel "channel $2 is not valid for $1 MHz" "$1 MHz + $2"
    halow_test_teardown
done
for bw_ch in "8 35" "8 43" "4 31" "4 39" "4 47" "2 29" "2 33" "2 37" "2 41" "2 45" "2 49" "1 28" "1 44" "1 50"; do
    set -- $bw_ch
    setup manual "$1" "$2"
    check_ok "$1 MHz + $2"
    assert_eq "$2" "$HALOW_CFG_CHANNEL" "$1 MHz + $2: the chosen channel is in effect"
    halow_test_teardown
done
setup manual 3 43
check_refused bandwidth "bandwidth" "an unsupported bandwidth is still refused in manual mode"
halow_test_teardown

echo "-- uplink_interface: omitted, empty and explicit --"
setup automatic 1
check_ok "uplink omitted"
assert_eq "" "$HALOW_CFG_UPLINK" "uplink omitted: empty (default route)"
halow_test_teardown
setup automatic 1; export HALOW_OPT_UPLINK_INTERFACE=""
check_ok "uplink empty"
assert_eq "" "$HALOW_CFG_UPLINK" "uplink empty: empty (default route)"
halow_test_teardown
setup automatic 1; export HALOW_OPT_UPLINK_INTERFACE="end0"
check_ok "uplink explicit"
assert_eq "end0" "$HALOW_CFG_UPLINK" "uplink explicit: kept"
halow_test_teardown
setup automatic 1; export HALOW_OPT_UPLINK_INTERFACE="hassio"
check_refused uplink_interface "not an acceptable uplink" "uplink explicit but a container network"
halow_test_teardown
echo "-- omitted and empty uplink behave identically through bashio ('null' and '') --"
for form in null ""; do
    setup automatic 1
    bashio::config() { case "$1" in
        region) echo AU ;; radio_mode) echo automatic ;; bandwidth) echo 1 ;; channel) echo auto ;;
        wifi_ssid) echo HaLow-Network ;; wifi_passphrase) echo correct-horse-battery ;;
        halow_subnet_cidr) echo 192.168.90.1/24 ;; dhcp_range_start) echo 192.168.90.50 ;;
        dhcp_range_end) echo 192.168.90.150 ;; uplink_interface) printf '%s\n' "$form" ;; *) echo null ;; esac; }
    check_ok "bashio uplink [$form], channel auto"
    assert_eq "" "$HALOW_CFG_UPLINK" "bashio uplink [$form]: empty"
    assert_eq "" "$HALOW_CFG_CHANNEL" "bashio channel auto: no channel"
    unset -f bashio::config
    halow_test_teardown
done

echo "-- upgrade: saved options from a build where both optional keys were absent --"
# The Supervisor merges the new defaults (channel auto, uplink empty) under the saved
# options; the backend must also cope when the keys are simply missing.
setup automatic 1
check_ok "upgrade, keys absent, automatic mode"
assert_eq "" "$HALOW_CFG_CHANNEL" "upgrade, absent: no channel in effect"
assert_eq "" "$HALOW_CFG_UPLINK" "upgrade, absent: default-route uplink"
halow_test_teardown
setup manual 1
check_refused channel "manual mode requires a channel number" "upgrade, keys absent, manual mode (the same refusal as before)"
halow_test_teardown
echo "-- upgrade: a saved integer channel (the Supervisor hands the add-on the string \"43\") --"
setup manual 8 43
check_ok "upgrade, saved channel 43 (string form), manual 8 MHz"
assert_eq "43" "$HALOW_CFG_CHANNEL" "upgrade: the saved channel is used"
halow_test_teardown
setup manual 2 '"41"'
check_ok "upgrade, quoted saved channel, manual 2 MHz"
assert_eq "41" "$HALOW_CFG_CHANNEL" "upgrade: quoted value read as a number"
halow_test_teardown
setup manual 2 '"42"'
check_refused channel "channel 42 is not valid for 2 MHz" "upgrade, quoted saved 2020-era channel 42, manual 2 MHz"
halow_test_teardown
setup automatic 1 43
check_ok "upgrade, saved channel 43, automatic mode"
assert_eq "" "$HALOW_CFG_CHANNEL" "upgrade: ignored by the add-on in automatic mode"
halow_test_teardown

echo "-- upgrade: a manual channel saved by the earlier 802.11-2020 numbering --"
# The earlier build used another numbering (1 MHz odd 27..51, 2 MHz 30/34/38/42/46/50, 4 MHz
# 32/40/48, 8 MHz 44). Home Assistant's own list check refuses 27 and 51 before the add-on
# runs (asserted above); the others are in the list but are checked against the bandwidth by
# the add-on: a number that is not a channel of the saved bandwidth is refused at start,
# naming the channel option, and is never replaced by another channel.
for case_ in "1 27" "1 51" "1 43" "1 45" "2 30" "2 34" "2 50" "4 32" "4 48" "8 44"; do
    set -- $case_
    setup manual "$1" "$2"
    check_refused channel "channel $2 is not valid for $1 MHz" "legacy saved $1 MHz + $2"
    assert_eq "$2" "$HALOW_CFG_CHANNEL" "legacy saved $1 MHz + $2: the saved value is reported, not replaced"
    halow_test_teardown
done
# A legacy number that is also a valid 2024 channel for the saved bandwidth is accepted: the
# add-on cannot tell the two numberings apart (the README tells the user to review it).
setup manual 1 44
check_ok "legacy-looking 1 MHz + 44 is a valid 2024 channel"
halow_test_teardown
# Automatic mode ignores any saved channel, legacy or not.
for ch in 27 51 43 30 44; do
    setup automatic 1 "$ch"
    check_ok "legacy saved channel $ch, automatic mode"
    assert_eq "" "$HALOW_CFG_CHANNEL" "legacy saved channel $ch, automatic mode: ignored"
    halow_test_teardown
done

echo "test_options_channel: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then exit 1; fi
if [ "${YAML_MISSING:-0}" = "1" ]; then
    echo "SKIPPED: python3 with the yaml module is required for the structural checks (a skip is not a pass)"
    exit 77
fi
exit 0
