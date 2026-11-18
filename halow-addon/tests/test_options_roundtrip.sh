#!/usr/bin/env bash
# Saved-options regression suite. A selected bandwidth (1, 2, 4 or 8 MHz) and the other saved
# options must reach the radio exactly as saved, in both channel selection modes, across a
# simulated restart (the Supervisor re-writes /data/options.json and the add-on reads it again):
#   - validation, parsing and the rendered access point configuration keep the selected width;
#   - automatic channel selection (success, failure with fallback, timeout) never replaces a
#     selected width with 1 MHz;
#   - absent and supplied values are told apart, and defaults apply only to a genuinely absent
#     (or empty) value;
#   - the manager's requested value, the radio's effective value and the status service's
#     displayed values agree, and the effective value comes from the radio;
#   - no shipped code writes, removes, normalizes or defaults the Supervisor's saved options;
#   - the passphrase never appears in logs, status output, diagnostics or this suite's output.
# Everything runs off-device against the real option, radio and state libraries; the manager
# runs with the recording stubs of helpers_lifecycle.sh. These tests show what the add-on
# reads, consumes, renders and reports. They cannot show what the Home Assistant Configuration
# page displays, whether the Supervisor persisted what the page sent, or whether any frontend
# or browser state is stale, and they do NOT show the Home Assistant form fixed: that is a live
# check (the W1 confirmation step in tools/release_candidate_checklist.sh). The channel
# transitions (8 MHz channel 43 and 35), form-reload simulation, restart cycles, mode
# transitions and the eleven-option round trip are in test_option_transitions.sh.
#
# Secret handling: the sentinel passphrase below is compared only through same_secret, which
# prints yes or no, never a value; no assertion in this suite passes it as an expected or
# actual argument.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh
. ./helpers_status.sh
. ./helpers_lifecycle.sh

echo "== test_options_roundtrip =="

ADDON_DIR="$(cd .. && pwd)"
ROOTFS="$ADDON_DIR/rootfs"
SENT_PASS="Sentinel-""Pp-7731-xyz"          # 12 to 63 plain ASCII characters, valid for the validator

# same_secret <a> <b> -> exit 0 when equal; prints nothing about the values.
same_secret() { [ "$1" = "$2" ]; }
# no_secret <file...> -> exit 0 when the sentinel appears in none of the files.
no_secret() { ! grep -q -F -- "$SENT_PASS" "$@" 2>/dev/null; }

# --- fixtures ---------------------------------------------------------------------------

# write_options <file> <bw-kind> <bw-value> <mode> <channel>
#   bw-kind: str (what the Supervisor writes for a list option), int, empty, null, absent.
write_options() {
    SENT="$SENT_PASS" python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, os, sys
path, kind, val, mode, chan = sys.argv[1:6]
d = {"region": "AU", "radio_mode": mode, "channel": chan,
     "wifi_ssid": "HaLow-Test", "wifi_passphrase": os.environ["SENT"],
     "halow_subnet_cidr": "192.168.90.1/24", "dhcp_range_start": "192.168.90.50",
     "dhcp_range_end": "192.168.90.150", "uplink_interface": "", "allowed_ports": []}
if kind == "str":
    d["bandwidth"] = val
elif kind == "int":
    d["bandwidth"] = int(val)
elif kind == "empty":
    d["bandwidth"] = ""
elif kind == "null":
    d["bandwidth"] = None
elif kind == "absent":
    pass
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh)
PY
}

# The emulation of bashio::config: one argument, read only, prints what bashio prints
# (the text of the value; "null" for a missing or null key; JSON text for a list).
BASHIO_EMUL='bashio::config() {
    python3 -I - "$HALOW_TEST_OPTIONS_JSON" "$1" <<"PY"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get(sys.argv[2])
if v is None:
    print("null")
elif isinstance(v, (list, dict)):
    print(json.dumps(v))
else:
    print(v)
PY
}'
use_bashio_emulation() { eval "$BASHIO_EMUL"; }
drop_bashio_emulation() { unset -f bashio::config; }

# Names of the loaded variables, reset between simulated starts so that nothing survives.
reset_cfg() { unset HALOW_CFG_REGION HALOW_CFG_RADIO_MODE HALOW_CFG_BANDWIDTH HALOW_CFG_CHANNEL HALOW_CFG_CHANNEL_SAVED HALOW_CFG_WIFI_SSID HALOW_CFG_WIFI_PASSPHRASE HALOW_CFG_SUBNET_CIDR HALOW_CFG_DHCP_START HALOW_CFG_DHCP_END HALOW_CFG_UPLINK HALOW_CFG_ALLOWED_PORTS HALOW_CFG_MAX_STATIONS; }

# real_setup: real libraries, a bundled or fixture hostapd template, the radio profile table,
# a neutral subnet collision check.
real_setup() {
    radio_setup
    halow_subnet_collision() { return 0; }
    OPTS="$HALOW_TEST_TMP/options.json"
    export HALOW_TEST_OPTIONS_JSON="$OPTS"
    ERR="$HALOW_TEST_TMP/err.log"; : > "$ERR"
    use_bashio_emulation
}

# cycle <mode> <bw-kind> <bw> <channel> : one simulated start from the options file:
# load, validate, render. Sets C_VALID (0/1) and C_OPCLASS.
cycle() {
    local mode="$1" kind="$2" bw="$3" chan="$4"
    write_options "$OPTS" "$kind" "$bw" "$mode" "$chan"
    reset_cfg
    halow_options_load
    if halow_options_validate 2>>"$ERR"; then C_VALID=0; else C_VALID=1; fi
    C_OPCLASS=""
    if [ "$C_VALID" -eq 0 ]; then
        rm -f -- "$HALOW_RUN_DIR/hostapd.conf"
        if halow_radio_render AU "$HALOW_CFG_RADIO_MODE" "$HALOW_CFG_BANDWIDTH" "$HALOW_CFG_CHANNEL" wlx001122 "$HALOW_CFG_WIFI_SSID" "$HALOW_CFG_WIFI_PASSPHRASE" halow-br0 64 "$HALOW_RUN_DIR/hostapd.conf" >> "$ERR" 2>&1; then
            C_OPCLASS="$(radio_conf_value "$HALOW_RUN_DIR/hostapd.conf" op_class)"
        else
            C_OPCLASS="render-failed"
        fi
    fi
}

# =========================================================================================
echo "-- 1 and 2: 1, 2, 4 and 8 MHz survive validation, parsing, rendering and restarts that re-read a re-written options file --"
real_setup
# One installation edited four times in a row: after each simulated restart the options file is
# written again with the next width (1, then 2, 4, 8, then back down), the load starts from an
# empty state, and the value read must be the one just saved, never the one of the start before.
for kind in str int; do
    for mode in automatic manual; do
        prev=""
        for bw in 1 2 4 8 4 2 1; do
            set -- ${RADIO_EXPECT_CHANNELS[$bw]}
            chan="auto"; [ "$mode" = "manual" ] && chan="${!#}"
            cycle "$mode" "$kind" "$bw" "$chan"
            assert_eq "0" "$C_VALID" "$mode, saved as $kind, restart with $bw MHz (after ${prev:-the first start}): validation passes"
            assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "$mode, saved as $kind, restart with $bw MHz: the option read is $bw, not the earlier value"
            assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$C_OPCLASS" "$mode, saved as $kind, restart with $bw MHz: the rendered operating class is the one of $bw MHz"
            prev="$bw"
        done
    done
done
echo "-- 1 and 2: the supplied forms of the environment path (1, \"1\", '1') --"
drop_bashio_emulation
for bw in 1 2 4 8; do
    for form in "$bw" "\"$bw\"" "'$bw'" " $bw "; do
        export HALOW_OPT_REGION="AU" HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_BANDWIDTH="$form" HALOW_OPT_CHANNEL="auto"
        export HALOW_OPT_WIFI_SSID="HaLow-Test" HALOW_OPT_WIFI_PASSPHRASE="$SENT_PASS" HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24"
        export HALOW_OPT_DHCP_RANGE_START="192.168.90.50" HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_UPLINK_INTERFACE="" HALOW_OPT_ALLOWED_PORTS=""
        reset_cfg; halow_options_load
        if halow_options_validate 2>>"$ERR"; then r=0; else r=1; fi
        assert_eq "0" "$r" "environment form [$form]: validation passes"
        assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "environment form [$form]: parsed as $bw"
    done
done
halow_test_teardown

# =========================================================================================
echo "-- 3: the fallback channel table covers every width (the manager cases below exercise the real flow) --"
real_setup
for bw in 1 2 4 8; do
    assert_eq "${RADIO_EXPECT_FALLBACK[$bw]}" "$(halow_radio_fallback_channel AU "$bw")" "the real fallback channel for $bw MHz is the one of that width"
    if halow_radio_validate AU manual "$bw" "${RADIO_EXPECT_FALLBACK[$bw]}" >/dev/null 2>&1; then r=0; else r=1; fi
    assert_eq "0" "$r" "the fallback channel of $bw MHz is a valid manual channel at $bw MHz"
done
halow_test_teardown

hl_replay_state() { # <statelog> <outfile>: the manager's state calls replayed into the real snapshot writer
    ( . ./helpers_status.sh; halow_status_test_setup; export HALOW_STATE_NOW=1000
      halow_state_init
      while IFS='|' read -r fn a b c d e f; do
          case "$fn" in
              radio_requested) halow_state_radio_requested "$a" "$b" "$c" ;;
              radio_effective) halow_state_radio_effective "$a" "$b" "$c" "$d" "$e" "$f" ;;
          esac
      done < "$1"
      cp "$HALOW_STATUS_FILE" "$2"
      halow_status_test_teardown ) >/dev/null 2>&1
}

STATUS_PY='
import sys
sys.path.insert(0, sys.argv[1])
import status_server as s
cfg = s.Config(sys.argv[2], 90, None, None)
view = s.build_view(cfg, now=1000)
mode = sys.argv[3]
if mode == "page":
    print(s.render_main(view))
else:
    print(s.public_json(view, True))
'
status_text() { python3 -I -B -c "$STATUS_PY" "$ROOTFS/usr/lib/halow/status" "$1" "$2"; }

for bw in 2 4 8; do
    exp_fb="${RADIO_EXPECT_FALLBACK[$bw]}"
    for case_ in "0:selection succeeds" "1:selection fails (fallback)" "2:selection times out (fallback)"; do
        rc="${case_%%:*}"; why="${case_#*:}"
        hl_setup
        export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_BANDWIDTH="$bw" HALOW_OPT_CHANNEL="auto"
        printf '%s\n' "HL_SLEEP_LIMIT=6; HL_ACS_CHANNEL=35; HL_FALLBACK_CH=$exp_fb; HL_RC_halow_radio_acs_wait=$rc; hl_act_halow_radio_capture_effective() { HALOW_EFF_CHANNEL=\"\${HL_ACS_CHANNEL}\"; HALOW_EFF_FREQ_KHZ=$((902000 + 500 * 35)); HALOW_EFF_BW_MHZ=$bw; return 0; }" > "$HL_DIR/scenario.sh"
        hl_run_manager "$HL_DIR/scenario.sh"
        assert_eq "0" "$HL_EXIT" "$bw MHz automatic, $why: the manager exits cleanly after the stop"
        renders="$(grep '^halow_radio_render ' "$HL_DIR/calls.log" | awk '{print $4}' | sort -u | tr '\n' ' ')"
        assert_eq "$bw " "$renders" "$bw MHz automatic, $why: every render call carries $bw MHz (never 1)"
        assert_failure "$bw MHz automatic, $why: no render call asks for 1 MHz" grep -q -E '^halow_radio_render AU [a-z]+ 1 ' "$HL_DIR/calls.log"
        if [ "$rc" != "0" ]; then
            assert_success "$bw MHz automatic, $why: the fallback channel is looked up for $bw MHz" grep -q "^halow_radio_fallback_channel AU $bw\$" "$HL_DIR/calls.log"
            assert_success "$bw MHz automatic, $why: the fallback is rendered at $bw MHz on the channel of that width" grep -q "^halow_radio_render AU fallback $bw $exp_fb " "$HL_DIR/calls.log"
        fi
        assert_success "$bw MHz automatic, $why: the requested state keeps $bw MHz" grep -q "^radio_requested|automatic|$bw|\$" "$HL_DIR/state.log"
        assert_failure "$bw MHz automatic, $why: the requested state is never 1 MHz" grep -q '^radio_requested|automatic|1|' "$HL_DIR/state.log"
        halow_test_teardown
    done
done

# =========================================================================================
echo "-- 4: absent, empty, null and supplied values are told apart; the default applies only to an absent or empty value --"
real_setup
# Facts of the code, stated here so that a change is noticed: bashio prints the text "null" for
# an absent or null key, and the reader turns that into an empty value; an empty value
# (including a pair of quotes or only whitespace) takes the default. A literal "null" that
# arrives through the environment form is not a number and is refused.
for kind in absent null empty; do
    cycle automatic "$kind" "" auto
    assert_eq "0" "$C_VALID" "bandwidth $kind in the saved options: valid"
    assert_eq "$HALOW_DEFAULT_BANDWIDTH_MHZ" "$HALOW_CFG_BANDWIDTH" "bandwidth $kind in the saved options takes the default ($HALOW_DEFAULT_BANDWIDTH_MHZ)"
done
for bw in 2 4 8; do
    cycle automatic str "$bw" auto
    assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "a supplied $bw is never replaced by the default"
done
drop_bashio_emulation
export HALOW_OPT_REGION="AU" HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="auto"
export HALOW_OPT_WIFI_SSID="HaLow-Test" HALOW_OPT_WIFI_PASSPHRASE="$SENT_PASS" HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24"
export HALOW_OPT_DHCP_RANGE_START="192.168.90.50" HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_UPLINK_INTERFACE="" HALOW_OPT_ALLOWED_PORTS=""
unset HALOW_OPT_BANDWIDTH
reset_cfg; halow_options_load
assert_eq "$HALOW_DEFAULT_BANDWIDTH_MHZ" "$HALOW_CFG_BANDWIDTH" "environment form: an unset variable takes the default"
for form in "" "  " '""' "''"; do
    export HALOW_OPT_BANDWIDTH="$form"
    reset_cfg; halow_options_load
    assert_eq "$HALOW_DEFAULT_BANDWIDTH_MHZ" "$HALOW_CFG_BANDWIDTH" "environment form: [$form] (empty, whitespace or an empty quote pair) takes the default"
done
for form in 0 -1 1MHz 3 null 16 "2 4"; do
    export HALOW_OPT_BANDWIDTH="$form"
    reset_cfg; halow_options_load
    if halow_options_validate 2>>"$ERR"; then r=0; else r=1; fi
    assert_eq "1" "$r" "environment form: [$form] is refused, never defaulted"
    assert_eq "CONFIG_INVALID" "$HALOW_CFG_ERROR_CODE" "environment form: [$form] is a CONFIG_INVALID error"
    assert_eq "bandwidth" "$HALOW_CFG_ERROR_OPTION" "environment form: [$form] names the bandwidth option"
done
halow_test_teardown

# =========================================================================================
echo "-- 4b: a default is logged exactly when it is applied, never when a value is supplied --"
real_setup
LOADLOG="$HALOW_TEST_TMP/load.log"
# load_logged <mode> <bw-kind> <bw> : one start from the options file; stderr (the log) kept.
load_logged() {
    write_options "$OPTS" "$2" "$3" "$1" auto
    reset_cfg; halow_options_load 2> "$LOADLOG"
}
for kind in absent null empty; do
    load_logged automatic "$kind" ""
    assert_success "bandwidth $kind: the log says the bandwidth was not supplied and the default applied" grep -q -F "options: bandwidth not supplied, using default $HALOW_DEFAULT_BANDWIDTH_MHZ MHz" "$LOADLOG"
    assert_failure "bandwidth $kind with a supplied mode: no radio_mode default line" grep -q -F "radio_mode" "$LOADLOG"
    assert_eq "bandwidth" "$HALOW_CFG_DEFAULTED" "bandwidth $kind: the applied default is recorded"
done
for bw in 1 2 4 8; do
    for kind in str int; do
        load_logged automatic "$kind" "$bw"
        assert_failure "bandwidth $bw supplied as $kind: no default line is logged" grep -q -F "not supplied" "$LOADLOG"
        assert_eq "" "$HALOW_CFG_DEFAULTED" "bandwidth $bw supplied as $kind: nothing is recorded as defaulted"
    done
done
# radio_mode: an empty string is read as not supplied (the Supervisor would write a list value).
SENT="$SENT_PASS" python3 -I - "$OPTS" <<'PY'
import json, os, sys
d = {"region": "AU", "radio_mode": "", "channel": "auto", "bandwidth": "4",
     "wifi_ssid": "HaLow-Test", "wifi_passphrase": os.environ["SENT"],
     "halow_subnet_cidr": "192.168.90.1/24", "dhcp_range_start": "192.168.90.50",
     "dhcp_range_end": "192.168.90.150", "uplink_interface": "", "allowed_ports": []}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PY
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_success "an empty radio_mode logs that the default automatic applied" grep -q -F "options: radio_mode (Channel selection mode) not supplied, using default automatic" "$LOADLOG"
assert_failure "a supplied bandwidth next to a defaulted mode logs no bandwidth line" grep -q -F "options: bandwidth" "$LOADLOG"
assert_eq "radio_mode" "$HALOW_CFG_DEFAULTED" "only the mode is recorded as defaulted"
assert_success "the log lines never hold the passphrase" no_secret "$LOADLOG"
# Both absent: two lines, and the summary of a valid start names them.
SENT="$SENT_PASS" python3 -I - "$OPTS" <<'PY'
import json, os, sys
d = {"region": "AU", "channel": "auto",
     "wifi_ssid": "HaLow-Test", "wifi_passphrase": os.environ["SENT"],
     "halow_subnet_cidr": "192.168.90.1/24", "dhcp_range_start": "192.168.90.50",
     "dhcp_range_end": "192.168.90.150", "uplink_interface": "", "allowed_ports": []}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PY
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "2" "$(grep -c -F "not supplied, using default" "$LOADLOG")" "two defaults applied: two lines"
halow_options_validate 2>> "$LOADLOG" || true
assert_success "the valid summary mentions the applied defaults" grep -q -F "options: valid (" "$LOADLOG"
assert_success "the valid summary names radio_mode and bandwidth as defaulted" grep -q -F "defaults applied for: radio_mode bandwidth" "$LOADLOG"
# Fully supplied: the summary has no defaults clause.
write_options "$OPTS" str 8 manual 35
reset_cfg; halow_options_load 2> "$LOADLOG"; halow_options_validate 2>> "$LOADLOG" || true
assert_failure "a fully supplied start mentions no defaults in the log" grep -q -F "default" "$LOADLOG"
assert_success "a fully supplied start still logs the valid summary" grep -q -F "options: valid (" "$LOADLOG"
assert_success "the radio_mode error text uses the label with the key in parentheses" bash -c 'grep -q "Channel selection mode (radio_mode) must be automatic or manual" "$1"' _ "$ADDON_DIR/rootfs/usr/lib/halow/options.sh"
halow_test_teardown

# =========================================================================================
echo "-- 5: every option is returned unchanged when supplied; only an empty radio_mode or bandwidth is defaulted --"
real_setup
drop_bashio_emulation
declare -A VARFOR=( [region]=REGION [radio_mode]=RADIO_MODE [bandwidth]=BANDWIDTH [channel]=CHANNEL [wifi_ssid]=WIFI_SSID [wifi_passphrase]=WIFI_PASSPHRASE [halow_subnet_cidr]=SUBNET_CIDR [dhcp_range_start]=DHCP_START [dhcp_range_end]=DHCP_END [uplink_interface]=UPLINK [allowed_ports]=ALLOWED_PORTS )
declare -A SUPPLY=( [region]=AU [radio_mode]=manual [bandwidth]=4 [channel]=31 [wifi_ssid]="My Net" [wifi_passphrase]="$SENT_PASS" [halow_subnet_cidr]=10.9.8.1/24 [dhcp_range_start]=10.9.8.20 [dhcp_range_end]=10.9.8.90 [uplink_interface]=end0 [allowed_ports]="tcp/1883" )
names_in_code="$(. "$ROOTFS/usr/lib/halow/options.sh"; printf '%s' "$HALOW_OPTIONS_NAMES")"
cfg_schema_keys="$(python3 -I - "$ADDON_DIR/config.yaml" <<'PY'
import sys, yaml
print(" ".join(sorted(yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["schema"])))
PY
)"
assert_eq "$cfg_schema_keys" "$(printf '%s\n' $names_in_code | sort | paste -sd' ')" "the option names the code reads equal the schema keys of config.yaml"
for name in $names_in_code; do
    for other in $names_in_code; do export "HALOW_OPT_${other^^}=${SUPPLY[$other]}"; done
    reset_cfg; halow_options_load
    var="HALOW_CFG_${VARFOR[$name]}"
    if [ "$name" = "wifi_passphrase" ]; then
        if same_secret "${!var}" "${SUPPLY[$name]}"; then r=yes; else r=no; fi
        assert_eq "yes" "$r" "option $name: a supplied value is returned unchanged (compared without printing)"
    else
        assert_eq "${SUPPLY[$name]}" "${!var}" "option $name: a supplied value is returned unchanged"
    fi
    export "HALOW_OPT_${name^^}="
    reset_cfg; halow_options_load
    case "$name" in
        radio_mode) assert_eq "automatic" "${!var}" "option $name: empty takes the default automatic" ;;
        bandwidth)  assert_eq "$HALOW_DEFAULT_BANDWIDTH_MHZ" "${!var}" "option $name: empty takes the default" ;;
        *)          assert_eq "" "${!var}" "option $name: empty stays empty (validation, not the reader, refuses or accepts it)" ;;
    esac
done
# The schema defaults, parsed independently of the code, match what an absent value means.
defaults="$(python3 -I - "$ADDON_DIR/config.yaml" <<'PY'
import sys, yaml
o = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["options"]
print("bandwidth_type=%s" % type(o["bandwidth"]).__name__)
print("bandwidth=%s" % o["bandwidth"])
print("radio_mode=%s" % o["radio_mode"])
print("channel=%s" % o["channel"])
print("uplink=%s" % o["uplink_interface"])
PY
)"
dget() { printf '%s\n' "$defaults" | awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'; }
assert_eq "str" "$(dget bandwidth_type)" "the saved bandwidth default is a quoted string, not a number"
assert_eq "$HALOW_DEFAULT_BANDWIDTH_MHZ" "$(dget bandwidth)" "the bandwidth default in config.yaml equals the code's default"
assert_eq "automatic" "$(dget radio_mode)" "the radio_mode default in config.yaml equals the code's default"
assert_eq "auto" "$(dget channel)" "the channel default is the sentinel auto (read as no channel)"
assert_eq "" "$(dget uplink)" "the uplink default is empty"
halow_test_teardown

# =========================================================================================
echo "-- 6: the manager's requested value, the radio's effective value and the status page agree --"
for pair in "2:2" "4:4" "8:8" "8:4"; do
    req="${pair%%:*}"; eff="${pair#*:}"
    hl_setup
    export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_BANDWIDTH="$req" HALOW_OPT_CHANNEL="auto"
    printf '%s\n' "HL_SLEEP_LIMIT=6; hl_act_halow_radio_capture_effective() { HALOW_EFF_CHANNEL=35; HALOW_EFF_FREQ_KHZ=919500; HALOW_EFF_BW_MHZ=$eff; return 0; }" > "$HL_DIR/scenario.sh"
    hl_run_manager "$HL_DIR/scenario.sh"
    assert_eq "0" "$HL_EXIT" "requested $req, radio reports $eff: the manager runs and stops cleanly"
    assert_success "requested $req, radio reports $eff: the manager requests $req MHz" grep -q "^radio_requested|automatic|$req|\$" "$HL_DIR/state.log"
    assert_success "requested $req, radio reports $eff: the effective value is the radio's $eff MHz" grep -q "^radio_effective|919500|35|$eff|acs|" "$HL_DIR/state.log"
    snap="$HL_DIR/snapshot.json"
    hl_replay_state "$HL_DIR/state.log" "$snap"
    assert_eq "$req" "$(json_get "$snap" 'd["radio"]["requested"]["bandwidth_mhz"]')" "requested $req, radio reports $eff: the snapshot's requested bandwidth is $req"
    assert_eq "$eff" "$(json_get "$snap" 'd["radio"]["effective"]["bandwidth_mhz"]')" "requested $req, radio reports $eff: the snapshot's effective bandwidth is $eff"
    page="$(status_text "$snap" page)"
    assert_success "requested $req, radio reports $eff: the page shows the requested value under Your settings" bash -c 'sed -e "s/.*<h3>Your settings<\/h3>//" -e "s/<h3>In use now<\/h3>.*//" <<< "$1" | grep -qF "<dt>Bandwidth setting</dt><dd>'"$req"' MHz</dd>"' _ "$page"
    assert_success "requested $req, radio reports $eff: the page shows the effective value under In use now" bash -c 'sed -e "s/.*<h3>In use now<\/h3>//" <<< "$1" | grep -qF "<dt>Bandwidth</dt><dd>'"$eff"' MHz</dd>"' _ "$page"
    halow_test_teardown
done
echo "-- 6: with no value from the radio the manager falls back to the requested one (current behavior, stated) --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_BANDWIDTH="4" HALOW_OPT_CHANNEL="auto"
printf '%s\n' "HL_SLEEP_LIMIT=6; hl_act_halow_radio_capture_effective() { HALOW_EFF_CHANNEL=39; HALOW_EFF_FREQ_KHZ=921500; HALOW_EFF_BW_MHZ=''; return 0; }" > "$HL_DIR/scenario.sh"
hl_run_manager "$HL_DIR/scenario.sh"
assert_success "an empty radio read-back is recorded as the requested 4 MHz" grep -q '^radio_effective|921500|39|4|acs|' "$HL_DIR/state.log"
halow_test_teardown

# =========================================================================================
echo "-- 7: no app path writes, removes, normalizes or defaults the Supervisor's saved options --"
violations="$(python3 -I - "$ROOTFS" "$ADDON_DIR" <<'PY'
import os, re, sys
root, addon = sys.argv[1], sys.argv[2]
files = []
for base, _dirs, names in os.walk(root):
    for n in names:
        files.append(os.path.join(base, n))
for extra in ("Dockerfile", "build.sh"):
    p = os.path.join(addon, extra)
    if os.path.isfile(p):
        files.append(p)
patterns = [
    (r"bashio::(addon|app)\.option", "options setter"),
    (r"\b(addon|app)\.options?\b", "options accessor"),
    (r"/(addons|apps)/self/options", "Supervisor options endpoint"),
    (r"/(addons|apps)/[A-Za-z0-9_.$\{\}]+/options", "Supervisor options endpoint (slug)"),
    (r"supervisor/(addons|apps)", "Supervisor API path"),
    (r"https?://supervisor", "Supervisor URL"),
    (r"hassio_api|hassio\.api", "Supervisor API"),
    (r"\bcurl\b|\bwget\b", "network client"),
    (r"options\.json", "options file"),
    (r"\bsed\s+-[a-zA-Z]*i", "in-place edit"),
    (r"\bjq\b", "jq"),
]
allowed_token_files = {
    "etc/cont-init.d/00-restrict-container-environment",
    "usr/lib/halow/state.sh",
    "usr/lib/halow/status/launcher.sh",
}
token_files = set()
bad = []
for path in sorted(files):
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines, 1):
        code = re.sub(r"^\s*#.*$", "", line)
        if not code.strip():
            continue
        for rx, what in patterns:
            # The image build may edit system files (for example the shadow entry of the
            # status user); only a build line that mentions the options is a violation.
            if what in ("in-place edit", "jq") and os.path.basename(path) in ("Dockerfile", "build.sh")                and "option" not in code.lower():
                continue
            if re.search(rx, code):
                bad.append("%s:%d: %s" % (rel, i, what))
        # bashio::config with a second argument would write; one argument only reads.
        for m in re.finditer(r"bashio::config\s+(\"[^\"]*\"|\S+)(\s+(\S+))?", code):
            if re.match(r"declare\s+-F", code.strip()):
                continue
            third = m.group(3)
            if third and not re.match(r"^(\d*[<>]|[|;&)])", third):
                bad.append("%s:%d: bashio::config with a second argument" % (rel, i))
        if re.search(r"SUPERVISOR_TOKEN|HASSIO_TOKEN", code):
            token_files.add(rel)
for rel in sorted(token_files - allowed_token_files):
    bad.append("%s: uses the Supervisor token outside the code that hides it" % rel)
for line in bad:
    print(line)
PY
)"
assert_eq "" "$violations" "no shipped file writes, removes or normalizes options, calls the Supervisor options API, or uses the token to do so"
assert_success "the only option read is bashio::config with one argument (options.sh)" bash -c 'test "$(grep -rn "bashio::config" "$1" | grep -v "^[^:]*:[0-9]*:[[:space:]]*#" | grep -v "declare -F" | wc -l)" -eq 1' _ "$ROOTFS"
assert_success "config.yaml requests no Supervisor API role" bash -c '! grep -qE "^(hassio_api|hassio_role|homeassistant_api):" "$1"' _ "$ADDON_DIR/config.yaml"

echo "-- 7: the saved options file is byte-identical after load, validation, render, a manager run and a stop --"
hl_setup
export HALOW_TEST_OPTIONS_JSON="$HL_DIR/options.json"
write_options "$HALOW_TEST_OPTIONS_JSON" str 4 automatic auto
printf '%s\n' "$BASHIO_EMUL" > "$HL_DIR/emul.sh"
sum_before="$(sha256sum "$HALOW_TEST_OPTIONS_JSON" | awk '{print $1}')"
printf '%s\n' ". '$HL_DIR/emul.sh'; HL_SLEEP_LIMIT=6" > "$HL_DIR/scenario.sh"
hl_run_manager "$HL_DIR/scenario.sh"
assert_eq "0" "$HL_EXIT" "the manager reads the options through the bashio emulation and stops cleanly"
assert_success "the manager consumed the saved 4 MHz from the options file" grep -q '^radio_requested|automatic|4|$' "$HL_DIR/state.log"
assert_eq "$sum_before" "$(sha256sum "$HALOW_TEST_OPTIONS_JSON" | awk '{print $1}')" "the options file is byte-identical after a manager start and stop"
hl_run_manager "$HL_DIR/scenario.sh"
assert_success "a second start (simulated restart) consumes the same 4 MHz" grep -q '^radio_requested|automatic|4|$' "$HL_DIR/state.log"
assert_eq "$sum_before" "$(sha256sum "$HALOW_TEST_OPTIONS_JSON" | awk '{print $1}')" "the options file is byte-identical after the restart"
assert_failure "no curl call (the manager never contacts the Supervisor)" hl_called curl
halow_test_teardown

# =========================================================================================
echo "-- 8: the schema's bandwidth is a string list, its default is a string, and every choice is documented --"
python3 -I - "$ADDON_DIR" > "${TMPDIR:-/tmp}/rt_schema.$$" <<'PY'
import sys, yaml, os
d = sys.argv[1]
cfg = yaml.safe_load(open(os.path.join(d, "config.yaml"), encoding="utf-8"))
tr = yaml.safe_load(open(os.path.join(d, "translations", "en.yaml"), encoding="utf-8"))
print("schema=%s" % cfg["schema"]["bandwidth"])
print("default_type=%s" % type(cfg["options"]["bandwidth"]).__name__)
widths = set()
for line in open(os.path.join(d, "rootfs", "usr", "share", "halow", "radio_profiles.psv"), encoding="utf-8"):
    f = line.rstrip("\n").split("|")
    if len(f) > 3 and f[0] == "width" and f[2] == "AU":
        widths.add(int(f[3]))
print("profile_widths=%s" % " ".join(str(w) for w in sorted(widths)))
desc = " ".join(str(tr["configuration"]["bandwidth"]["description"]).split())
print("translated=%s" % ("yes" if "Channel width in MHz: 1, 2, 4, or 8" in desc else "no"))
PY
sch="${TMPDIR:-/tmp}/rt_schema.$$"
assert_eq "schema=list(1|2|4|8)" "$(grep '^schema=' "$sch")" "the bandwidth schema is the string list list(1|2|4|8)"
assert_eq "default_type=str" "$(grep '^default_type=' "$sch")" "the bandwidth default is a quoted string (an integer would not match the list)"
assert_eq "profile_widths=1 2 4 8" "$(grep '^profile_widths=' "$sch")" "the radio profile table offers exactly the widths of the schema list"
assert_eq "translated=yes" "$(grep '^translated=' "$sch")" "the translation names every choice (Channel width in MHz: 1, 2, 4, or 8)"
rm -f "$sch"

# =========================================================================================
echo "-- 9: the passphrase never appears in logs, status output, diagnostics or this suite's output --"
real_setup
: > "$ERR"
cycle automatic str 2 auto
assert_eq "0" "$C_VALID" "a valid start with the sentinel passphrase"
write_options "$OPTS" str 2 automatic auto
bad_opts="$HALOW_TEST_TMP/options_bad.json"
SENT="$SENT_PASS" python3 -I - "$OPTS" "$bad_opts" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["halow_subnet_cidr"] = "not-a-subnet"
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
export HALOW_TEST_OPTIONS_JSON="$bad_opts"
reset_cfg; halow_options_load
halow_options_validate > "$HALOW_TEST_TMP/val.out" 2> "$HALOW_TEST_TMP/val.err" || true
assert_eq "halow_subnet_cidr" "$HALOW_CFG_ERROR_OPTION" "an invalid option set is refused naming the option"
assert_success "validation (valid and invalid cases) printed no passphrase" no_secret "$HALOW_TEST_TMP/val.out" "$HALOW_TEST_TMP/val.err" "$ERR"
render_out="$HALOW_TEST_TMP/render.out"
halow_radio_render AU automatic 2 "" wlx001122 "HaLow-Test" "$SENT_PASS" halow-br0 64 "$HALOW_RUN_DIR/hostapd.conf" > "$render_out" 2>&1
assert_success "the renderer printed no passphrase" no_secret "$render_out"
assert_eq "600" "$(stat -c '%a' "$HALOW_RUN_DIR/hostapd.conf")" "the only file that holds the passphrase is the 0600 rendered configuration"
halow_test_teardown

hl_setup
export HALOW_TEST_OPTIONS_JSON="$HL_DIR/options.json"
write_options "$HALOW_TEST_OPTIONS_JSON" str 2 automatic auto
printf '%s\n' "$BASHIO_EMUL" > "$HL_DIR/emul.sh"
printf '%s\n' ". '$HL_DIR/emul.sh'; HL_SLEEP_LIMIT=6; hl_act_halow_radio_capture_effective() { HALOW_EFF_CHANNEL=33; HALOW_EFF_FREQ_KHZ=918500; HALOW_EFF_BW_MHZ=2; return 0; }" > "$HL_DIR/scenario.sh"
hl_run_manager "$HL_DIR/scenario.sh"
assert_eq "0" "$HL_EXIT" "the manager started with the sentinel passphrase"
assert_success "the manager's output holds no passphrase" no_secret "$HL_DIR/out.log"
assert_success "the recorded calls (the renderer's passphrase argument is masked) hold no passphrase" no_secret "$HL_DIR/calls.log"
assert_success "the recorded state calls hold no passphrase" no_secret "$HL_DIR/state.log"
snap="$HL_DIR/snapshot.json"
( . ./helpers_status.sh; halow_status_test_setup; export HALOW_STATE_NOW=1000
  export HALOW_CFG_WIFI_PASSPHRASE="$SENT_PASS"
  halow_state_init
  halow_state_diag_set note "the passphrase was $SENT_PASS in a mistaken caller"
  halow_state_diag_log_append "options: saved passphrase $SENT_PASS"
  halow_state_radio_requested automatic 2 ""
  halow_state_attention CONFIG_INVALID "wifi_passphrase" "value $SENT_PASS is invalid" >/dev/null 2>&1 || true
  halow_state_flush
  cp "$HALOW_STATUS_FILE" "$snap"; halow_status_test_teardown ) >/dev/null 2>&1
assert_success "the snapshot file was written" test -s "$snap"
assert_success "the snapshot holds no passphrase even when a caller passes it by mistake" no_secret "$snap"
status_text "$snap" json > "$HL_DIR/diag.json"
status_text "$snap" page > "$HL_DIR/page.html"
assert_success "the served diagnostics hold no passphrase" no_secret "$HL_DIR/diag.json"
assert_success "the served status page holds no passphrase" no_secret "$HL_DIR/page.html"
halow_test_teardown
assert_eq "1" "$(grep -c -F "Pp-77""31" "${BASH_SOURCE[0]}")" "this suite's source names the sentinel exactly once, in its definition, and prints no secret"

# =========================================================================================
echo "-- 10: the customer text says changes take effect when the app is restarted and the status page shows what is in use --"
README_FLAT="$(tr '\n' ' ' < ../README.md | tr -s ' ')"
assert_success "the README says changes take effect when the app is restarted" grep -qF "Changes take effect when you restart the app" <<< "$README_FLAT"
assert_success "the README says the status page always shows what is in use" grep -qF "The status page always shows what is in use" <<< "$README_FLAT"
assert_success "the README lists the in-use frequency, channel and bandwidth on the status page" grep -qF "the frequency, channel, and bandwidth the access point is using" <<< "$README_FLAT"
assert_success "the channel translation points customers to the channel table on the Info page" bash -c 'tr "\n" " " < "$0" | tr -s " " | grep -qF "see the channel table on the Info page"' ../translations/en.yaml
assert_success "the status page tells the customer that option changes take effect after the app is restarted" grep -qF "Changes to the app options take effect after you restart the app" "$ROOTFS/usr/lib/halow/status/status_server.py"
assert_failure "the README and translations never say add-on except for the one explanation of the earlier name" bash -c 'cat ../README.md ../translations/en.yaml | tr "\n" " " | tr -s " " | sed "s/(called an add-on in earlier versions of Home Assistant)//" | grep -qi "add-on"'
assert_failure "HaLow never stands alone in the README or translations (always Wi-Fi HaLow)" bash -c 'cat ../README.md ../translations/en.yaml | tr "\n" " " | tr -s " " | sed -e "s/HaLow-Network//g" -e "s/Wi-Fi HaLow//g" -e "s/Wi-Fi-HaLow//g" | grep -q "HaLow"'
assert_failure "the device-session checklist mode no longer ships (it was an internal test procedure)" bash ../tools/release_candidate_checklist.sh live
echo "test_options_roundtrip: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then exit 1; fi
exit 0
