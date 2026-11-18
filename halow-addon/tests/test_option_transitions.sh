#!/usr/bin/env bash
# Option-transition regression suite (companion of test_options_roundtrip.sh).
#
# What it covers, off-device, against the real option, radio and state libraries and the real
# manager (with the recording stubs of helpers_lifecycle.sh):
#   1. direct manual 8 MHz changes between channel 43 and channel 35, in both directions and
#      repeated: the value consumed at each start equals the value supplied at that start, the
#      rendered access point configuration and the status "requested" state agree with it, and
#      nothing of the previous start (a status snapshot, decoy "last good" files, the previous
#      automatic or fallback channel) is ever fed back;
#   2. a form reload simulated as a re-read of a re-written options file, including a stale file
#      holding the old value while the environment path supplies the new one (the documented
#      reader: bashio inside the add-on, the HALOW_OPT_ variables otherwise; the file itself is
#      never read by the add-on);
#   3. app restart cycles through the manager, including automatic selection and its fallback;
#   4. automatic to manual and manual to automatic transitions at every bandwidth;
#   5. a bandwidth change with the channel unchanged, and the reverse;
#   6. every saved option (all eleven) through validation, parsing, rendering and the status
#      state, each consumed value equal to the supplied one;
#   7. no shipped code path writes or rewrites options, and the manager's "options: valid" line
#      and applied-default markers match what was consumed.
#
# LIMIT, stated plainly: these tests show what the add-on reads, consumes, renders and reports.
# They cannot show what the Home Assistant Configuration page displays, whether the Supervisor
# persists what the page sent, or whether any frontend, Core or browser state is stale, and
# they do NOT show the Home Assistant form fixed. That needs the live confirmation step in
# tools/release_candidate_checklist.sh.
#
# Secret handling: the sentinel passphrase is compared only through same_secret (prints
# nothing) and searched for with grep -q; it is never an expected or actual assertion value.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh
. ./helpers_status.sh
. ./helpers_lifecycle.sh

echo "== test_option_transitions =="

ADDON_DIR="$(cd .. && pwd)"
ROOTFS="$ADDON_DIR/rootfs"
SENT_PASS="Sentinel-""Qq-4417-abc"          # valid for the validator; named once, here

same_secret() { [ "$1" = "$2" ]; }
no_secret() { ! grep -q -F -- "$SENT_PASS" "$@" 2>/dev/null; }

# --- fixtures ---------------------------------------------------------------------------

# write_opts <file> [key=value ...]: a complete options file as the Supervisor writes it
# (strings for list options), with the given keys replaced. "json:<text>" sets a JSON value.
write_opts() {
    local f="$1"
    shift
    SENT="$SENT_PASS" python3 -I - "$f" "$@" <<'PY'
import json, os, sys
path, args = sys.argv[1], sys.argv[2:]
d = {"region": "AU", "radio_mode": "manual", "bandwidth": "8", "channel": "43",
     "wifi_ssid": "HaLow-Test", "wifi_passphrase": os.environ["SENT"],
     "halow_subnet_cidr": "192.168.90.1/24", "dhcp_range_start": "192.168.90.50",
     "dhcp_range_end": "192.168.90.150", "uplink_interface": "", "allowed_ports": []}
for a in args:
    k, v = a.split("=", 1)
    if v.startswith("json:"):
        v = json.loads(v[5:])
    d[k] = v
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh)
PY
}

# The emulation of bashio::config: one argument, read only, every call logged as
# "<argument count> <name>" in $HALOW_TEST_BASHIO_LOG; prints what bashio prints.
BASHIO_EMUL='bashio::config() {
    printf "%s %s\n" "$#" "${1:-}" >> "$HALOW_TEST_BASHIO_LOG"
    [ "$#" -eq 1 ] || return 64
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

OPT_NAMES="region radio_mode bandwidth channel wifi_ssid wifi_passphrase halow_subnet_cidr dhcp_range_start dhcp_range_end uplink_interface allowed_ports"

reset_cfg() { unset HALOW_CFG_REGION HALOW_CFG_RADIO_MODE HALOW_CFG_BANDWIDTH HALOW_CFG_CHANNEL HALOW_CFG_CHANNEL_SAVED HALOW_CFG_DEFAULTED HALOW_CFG_WIFI_SSID HALOW_CFG_WIFI_PASSPHRASE HALOW_CFG_SUBNET_CIDR HALOW_CFG_DHCP_START HALOW_CFG_DHCP_END HALOW_CFG_UPLINK HALOW_CFG_ALLOWED_PORTS HALOW_CFG_MAX_STATIONS; }

sum_of() { sha256sum "$1" | awk '{print $1}'; }

# lib_setup: real libraries, the radio profile table, a neutral subnet collision check, the
# options file stand-in, and decoy "last good" files that nothing may read or rewrite.
lib_setup() {
    radio_setup
    halow_subnet_collision() { return 0; }
    OPTS="$HALOW_TEST_TMP/options.json"
    export HALOW_TEST_OPTIONS_JSON="$OPTS"
    export HALOW_TEST_BASHIO_LOG="$HALOW_TEST_TMP/bashio.log"; : > "$HALOW_TEST_BASHIO_LOG"
    ERR="$HALOW_TEST_TMP/err.log"; : > "$ERR"
    LOADLOG="$HALOW_TEST_TMP/load.log"; : > "$LOADLOG"
    use_bashio_emulation
    mkdir -p "$HALOW_STATE_DIR"
    # Decoys that look like remembered selections; each holds a value that is wrong for every
    # start below (bandwidth 1, automatic, channel 99 and 40).
    printf '{"radio_mode":"automatic","bandwidth":"1","channel":"99"}\n' > "$HALOW_STATE_DIR/options.json"
    printf '{"radio_mode":"automatic","bandwidth":"1","channel":"99"}\n' > "$HALOW_STATE_DIR/last_good_options.json"
    printf '40\n' > "$HALOW_STATE_DIR/last_channel"
    printf '40\n' > "$HALOW_RUN_DIR/last_channel"
    DECOY_SUM="$(cat "$HALOW_STATE_DIR"/options.json "$HALOW_STATE_DIR"/last_good_options.json "$HALOW_STATE_DIR"/last_channel "$HALOW_RUN_DIR"/last_channel | sha256sum | awk '{print $1}')"
    PREV_SNAP=""
}
decoy_sum() { cat "$HALOW_STATE_DIR"/options.json "$HALOW_STATE_DIR"/last_good_options.json "$HALOW_STATE_DIR"/last_channel "$HALOW_RUN_DIR"/last_channel | sha256sum | awk '{print $1}'; }

# snap_requested <outfile> [stale-snapshot]: replays the manager's state calls for the options
# just consumed into the real snapshot writer, starting from the previous start's snapshot
# when one is given (a restart on the same state directory).
snap_requested() {
    ( . ./helpers_status.sh; halow_status_test_setup; export HALOW_STATE_NOW=1000
      if [ -n "${2:-}" ]; then mkdir -p "$HALOW_RUN_DIR"; cp "$2" "$HALOW_STATUS_FILE"; fi
      halow_state_init
      halow_state_region "$HALOW_CFG_REGION"
      halow_state_radio_requested "$HALOW_CFG_RADIO_MODE" "$HALOW_CFG_BANDWIDTH" "$HALOW_CFG_CHANNEL"
      halow_state_flush
      cp "$HALOW_STATUS_FILE" "$1"
      halow_status_test_teardown ) >/dev/null 2>&1
}

STATUS_PY='
import sys
sys.path.insert(0, sys.argv[1])
import status_server as s
cfg = s.Config(sys.argv[2], 90, None, None)
view = s.build_view(cfg, now=1000)
if sys.argv[3] == "page":
    print(s.render_main(view))
else:
    print(s.public_json(view, True))
'
status_text() { python3 -I -B -c "$STATUS_PY" "$ROOTFS/usr/lib/halow/status" "$1" "$2"; }

# start_lib: one simulated start from the current options file, in a clean variable state:
# load, validate, render (real renderer), replay the requested state. Sets S_VALID (0/1),
# S_CONF_CHANNEL, S_OPCLASS, S_CONF (the rendered file) and S_SNAP (the snapshot).
start_lib() {
    reset_cfg
    : > "$LOADLOG"
    halow_options_load 2>> "$LOADLOG"
    if halow_options_validate 2>> "$LOADLOG"; then S_VALID=0; else S_VALID=1; fi
    S_CONF="$HALOW_RUN_DIR/hostapd.conf"; S_CONF_CHANNEL=""; S_OPCLASS=""; S_SNAP="$HALOW_TEST_TMP/snap.$RANDOM.json"
    rm -f -- "$S_CONF"
    if [ "$S_VALID" -eq 0 ]; then
        if halow_radio_render "$HALOW_CFG_REGION" "$HALOW_CFG_RADIO_MODE" "$HALOW_CFG_BANDWIDTH" "$HALOW_CFG_CHANNEL" wlx001122 "$HALOW_CFG_WIFI_SSID" "$HALOW_CFG_WIFI_PASSPHRASE" halow-br0 "${HALOW_CFG_MAX_STATIONS:-64}" "$S_CONF" >> "$ERR" 2>&1; then
            S_CONF_CHANNEL="$(radio_conf_value "$S_CONF" channel)"
            S_OPCLASS="$(radio_conf_value "$S_CONF" op_class)"
        else
            S_OPCLASS="render-failed"
        fi
        snap_requested "$S_SNAP" "$PREV_SNAP"
        PREV_SNAP="$S_SNAP"
    fi
}

snap_field() { json_get "$S_SNAP" "$1"; }

# =========================================================================================
echo "-- 1: direct manual 8 MHz changes, channel 43 to 35 and 35 to 43, repeated --"
lib_setup
prev=""
for ch in 43 35 43 43 35 35 43 35; do
    write_opts "$OPTS" bandwidth=8 radio_mode=manual channel="$ch"
    before="$(sum_of "$OPTS")"
    start_lib
    t="manual 8 MHz channel $ch (previous start: ${prev:-none})"
    assert_eq "0" "$S_VALID" "$t: validation passes"
    assert_eq "$ch" "$HALOW_CFG_CHANNEL" "$t: the consumed channel equals the supplied channel"
    assert_eq "8" "$HALOW_CFG_BANDWIDTH" "$t: the consumed bandwidth is the supplied 8 MHz"
    assert_eq "manual" "$HALOW_CFG_RADIO_MODE" "$t: the consumed mode is the supplied manual"
    assert_eq "" "$HALOW_CFG_CHANNEL_SAVED" "$t: no saved-channel diagnostic is set in manual mode"
    assert_eq "" "$HALOW_CFG_DEFAULTED" "$t: no default was applied"
    if [ -n "$prev" ] && [ "$prev" != "$ch" ]; then
        if [ "$HALOW_CFG_CHANNEL" != "$prev" ]; then r=changed; else r=carried-over; fi
        assert_eq "changed" "$r" "$t: the previous run's channel $prev is not consumed"
    fi
    assert_eq "$ch" "$S_CONF_CHANNEL" "$t: the rendered configuration carries the supplied channel"
    assert_eq "53" "$S_OPCLASS" "$t: the rendered operating class is the 8 MHz class"
    assert_eq "manual" "$(snap_field 'd["radio"]["mode"]')" "$t: the status requested mode is manual"
    assert_eq "8" "$(snap_field 'd["radio"]["requested"]["bandwidth_mhz"]')" "$t: the status requested bandwidth is 8"
    assert_eq "$ch" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$t: the status requested channel equals the supplied channel"
    status_text "$S_SNAP" json > "$HALOW_TEST_TMP/served.json"
    assert_eq "$ch" "$(json_get "$HALOW_TEST_TMP/served.json" 'd["radio"]["requested"]["channel"]')" "$t: the served status JSON shows the same requested channel"
    assert_success "$t: the manager's valid line names exactly this mode, bandwidth and channel" grep -q -F "options: valid (region AU, manual mode, 8 MHz, channel $ch)" "$LOADLOG"
    assert_failure "$t: no default or ignored-channel marker in the log" grep -q -E "not supplied|defaults applied|ignored in automatic" "$LOADLOG"
    assert_eq "$before" "$(sum_of "$OPTS")" "$t: the options file is byte-identical after the start"
    assert_eq "$DECOY_SUM" "$(decoy_sum)" "$t: the decoy last-good and last-channel files were neither read into the options nor rewritten"
    prev="$ch"
done
echo "-- 1: every other valid channel of every width also round-trips from one start to the next --"
for bw in 1 2 4 8; do
    prev=""
    for ch in ${RADIO_EXPECT_CHANNELS[$bw]} $(printf '%s\n' ${RADIO_EXPECT_CHANNELS[$bw]} | sort -rn | tr '\n' ' '); do
        write_opts "$OPTS" bandwidth="$bw" radio_mode=manual channel="$ch"
        start_lib
        assert_eq "0" "$S_VALID" "$bw MHz manual channel $ch: valid"
        assert_eq "$ch|$bw" "$HALOW_CFG_CHANNEL|$HALOW_CFG_BANDWIDTH" "$bw MHz manual channel $ch (after ${prev:-the first start}): consumed channel and bandwidth equal the supplied ones"
        assert_eq "$ch" "$S_CONF_CHANNEL" "$bw MHz manual channel $ch: rendered channel equals the supplied one"
        assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$S_OPCLASS" "$bw MHz manual channel $ch: rendered operating class is that of $bw MHz"
        assert_eq "$ch" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$bw MHz manual channel $ch: requested state equals the supplied channel"
        prev="$ch"
    done
done
halow_test_teardown

# =========================================================================================
echo "-- 2: form reload simulated by re-reading a re-written options file; a stale file against the environment path --"
lib_setup
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=43
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "43" "$HALOW_CFG_CHANNEL" "the first read returns the saved 43"
# The user saves 35: the Supervisor stand-in file is re-written; the next read returns 35 at once.
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=35
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "35" "$HALOW_CFG_CHANNEL" "after the file is re-written the next read returns 35"
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=43
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "43" "$HALOW_CFG_CHANNEL" "after the file is re-written back the next read returns 43 (no memory of the earlier read)"
# Stale file holding the OLD value (43), the NEW value (35) supplied by the environment path.
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=43
export HALOW_OPT_REGION=AU HALOW_OPT_RADIO_MODE=manual HALOW_OPT_BANDWIDTH=8 HALOW_OPT_CHANNEL=35
export HALOW_OPT_WIFI_SSID="HaLow-Test" HALOW_OPT_WIFI_PASSPHRASE="$SENT_PASS" HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24"
export HALOW_OPT_DHCP_RANGE_START="192.168.90.50" HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_UPLINK_INTERFACE="" HALOW_OPT_ALLOWED_PORTS=""
file_sum="$(sum_of "$OPTS")"
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "43" "$HALOW_CFG_CHANNEL" "documented reader, bashio present: the Supervisor source wins (file 43) over a stale environment value 35"
drop_bashio_emulation
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "35" "$HALOW_CFG_CHANNEL" "documented reader, bashio absent: the environment path supplies 35 and the options file is never read"
assert_eq "$file_sum" "$(sum_of "$OPTS")" "neither path modified the options file"
# And the reverse: environment holds the old value, the Supervisor source the new one.
use_bashio_emulation
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=35
export HALOW_OPT_CHANNEL=43
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "35" "$HALOW_CFG_CHANNEL" "bashio present: a stale environment value 43 never overrides the saved 35"
unset HALOW_OPT_REGION HALOW_OPT_RADIO_MODE HALOW_OPT_BANDWIDTH HALOW_OPT_CHANNEL HALOW_OPT_WIFI_SSID HALOW_OPT_WIFI_PASSPHRASE HALOW_OPT_HALOW_SUBNET_CIDR HALOW_OPT_DHCP_RANGE_START HALOW_OPT_DHCP_RANGE_END HALOW_OPT_UPLINK_INTERFACE HALOW_OPT_ALLOWED_PORTS
assert_success "the reader source states the order (bashio inside the add-on, the environment otherwise)" grep -q -F "through bashio inside" "$ROOTFS/usr/lib/halow/options.sh"
# An existing installation keeps its saved network name on upgrade; the new default only applies to fresh option sets.
use_bashio_emulation
write_opts "$OPTS" bandwidth=8 radio_mode=manual channel=43 wifi_ssid=MyOwnName
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "MyOwnName" "$HALOW_CFG_WIFI_SSID" "upgrade: a saved wifi_ssid (MyOwnName) is consumed unchanged, not replaced by the new default"
assert_eq "" "$HALOW_CFG_DEFAULTED" "upgrade: a saved wifi_ssid is not marked as defaulted"
halow_test_teardown

# =========================================================================================
echo "-- 4: automatic to manual and manual to automatic at every bandwidth; the saved channel is never replaced --"
lib_setup
for bw in 1 2 4 8; do
    chs=(${RADIO_EXPECT_CHANNELS[$bw]})
    hi="${chs[$((${#chs[@]} - 1))]}"; lo="${chs[0]}"
    opc="${RADIO_EXPECT_OPCLASS[$bw]}"
    # manual hi -> automatic (the file still holds hi) -> manual hi -> automatic with "auto" -> manual lo
    steps=("manual:$hi" "automatic:$hi" "manual:$hi" "automatic:auto" "manual:$lo" "automatic:$lo" "manual:$hi")
    prev_step="none"
    for step in "${steps[@]}"; do
        mode="${step%%:*}"; ch="${step#*:}"
        write_opts "$OPTS" bandwidth="$bw" radio_mode="$mode" channel="$ch"
        before="$(sum_of "$OPTS")"
        start_lib
        t="$bw MHz $mode channel [$ch] (after $prev_step)"
        assert_eq "0" "$S_VALID" "$t: valid"
        assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "$t: the bandwidth is unchanged by the mode change"
        assert_eq "$mode" "$HALOW_CFG_RADIO_MODE" "$t: the consumed mode equals the supplied mode"
        assert_eq "$opc" "$S_OPCLASS" "$t: the rendered operating class is that of $bw MHz"
        assert_eq "$mode" "$(snap_field 'd["radio"]["mode"]')" "$t: the status requested mode equals the supplied mode"
        assert_eq "$bw" "$(snap_field 'd["radio"]["requested"]["bandwidth_mhz"]')" "$t: the status requested bandwidth equals the supplied one"
        if [ "$mode" = "manual" ]; then
            assert_eq "$ch" "$HALOW_CFG_CHANNEL" "$t: manual consumes the supplied channel"
            assert_eq "" "$HALOW_CFG_CHANNEL_SAVED" "$t: nothing is held back as a saved channel"
            assert_eq "$ch" "$S_CONF_CHANNEL" "$t: the rendered channel is the supplied one"
            assert_eq "$ch" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$t: the requested channel is the supplied one"
        else
            expect_saved=""; [ "$ch" = "auto" ] || expect_saved="$ch"
            assert_eq "" "$HALOW_CFG_CHANNEL" "$t: automatic consumes no channel"
            assert_eq "$expect_saved" "$HALOW_CFG_CHANNEL_SAVED" "$t: the saved channel is kept for diagnostics only, unchanged"
            assert_eq "acs_survey" "$S_CONF_CHANNEL" "$t: the rendered configuration asks for automatic channel selection, not the saved channel"
            assert_eq "null" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$t: the requested channel is empty"
            if [ -n "$expect_saved" ]; then
                assert_success "$t: the valid line says the saved channel is ignored in automatic mode" grep -q -F "saved channel $expect_saved ignored in automatic mode" "$LOADLOG"
            fi
        fi
        assert_eq "$before" "$(sum_of "$OPTS")" "$t: the saved options are untouched by the start"
        prev_step="$step"
    done
done
assert_eq "$DECOY_SUM" "$(decoy_sum)" "the decoy files were never read into the options or rewritten across all transitions"
halow_test_teardown

# =========================================================================================
echo "-- 5: a bandwidth change with the channel unchanged, and the reverse --"
lib_setup
# Channels of different widths never coincide in this region, so a manual bandwidth change with an
# unchanged channel is refused naming the channel, and the supplied values are still the ones read.
for a in 1 2 4 8; do
    ca="$(printf '%s\n' ${RADIO_EXPECT_CHANNELS[$a]} | tail -n 1)"
    for b in 1 2 4 8; do
        [ "$a" = "$b" ] && continue
        write_opts "$OPTS" bandwidth="$a" radio_mode=manual channel="$ca"
        start_lib
        assert_eq "0" "$S_VALID" "channel $ca at $a MHz: valid"
        write_opts "$OPTS" bandwidth="$b" radio_mode=manual channel="$ca"
        before="$(sum_of "$OPTS")"
        start_lib
        assert_eq "1" "$S_VALID" "bandwidth $a to $b MHz with channel $ca unchanged (not a channel of $b MHz): refused, not remapped"
        assert_eq "channel" "$HALOW_CFG_ERROR_OPTION" "bandwidth $a to $b MHz with channel $ca unchanged: the refusal names the channel option"
        assert_eq "CONFIG_INVALID" "$HALOW_CFG_ERROR_CODE" "bandwidth $a to $b MHz with channel $ca unchanged: CONFIG_INVALID"
        assert_eq "$b|$ca" "$HALOW_CFG_BANDWIDTH|$HALOW_CFG_CHANNEL" "bandwidth $a to $b MHz with channel $ca unchanged: the supplied bandwidth and channel are still the ones read"
        assert_eq "" "$S_OPCLASS" "bandwidth $a to $b MHz with channel $ca unchanged: nothing was rendered"
        assert_eq "$before" "$(sum_of "$OPTS")" "bandwidth $a to $b MHz with channel $ca unchanged: the options file is untouched"
    done
done
# Automatic mode: the saved channel is unchanged while the bandwidth walks up and down.
for bw in 1 2 4 8 4 2 1 8; do
    write_opts "$OPTS" bandwidth="$bw" radio_mode=automatic channel=43
    start_lib
    assert_eq "0" "$S_VALID" "automatic, saved channel 43 unchanged, bandwidth $bw: valid (the saved channel is not validated against the width)"
    assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "automatic, saved channel 43, bandwidth $bw: the bandwidth consumed is the supplied one, never 1"
    assert_eq "43" "$HALOW_CFG_CHANNEL_SAVED" "automatic, saved channel 43, bandwidth $bw: the saved channel is unchanged"
    assert_eq "${RADIO_EXPECT_OPCLASS[$bw]}" "$S_OPCLASS" "automatic, saved channel 43, bandwidth $bw: the rendered class is that of $bw MHz"
    assert_eq "$bw" "$(snap_field 'd["radio"]["requested"]["bandwidth_mhz"]')" "automatic, saved channel 43, bandwidth $bw: the requested bandwidth is $bw"
done
# Bandwidth unchanged, channel changes (the reverse): covered per channel in part 1; here the
# pair 8 MHz 43 -> 35 -> 43 is repeated with the bandwidth supplied as a number and as text.
for kind in str int; do
    for ch in 43 35 43; do
        SENT="$SENT_PASS" python3 -I - "$OPTS" "$kind" "$ch" <<'PY'
import json, os, sys
d = {"region": "AU", "radio_mode": "manual", "bandwidth": "8", "channel": sys.argv[3],
     "wifi_ssid": "HaLow-Test", "wifi_passphrase": os.environ["SENT"],
     "halow_subnet_cidr": "192.168.90.1/24", "dhcp_range_start": "192.168.90.50",
     "dhcp_range_end": "192.168.90.150", "uplink_interface": "", "allowed_ports": []}
if sys.argv[2] == "int":
    d["bandwidth"] = 8
    d["channel"] = int(sys.argv[3])
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PY
        start_lib
        assert_eq "0|8|$ch" "$S_VALID|$HALOW_CFG_BANDWIDTH|$HALOW_CFG_CHANNEL" "8 MHz channel $ch saved as $kind: valid and consumed unchanged"
        assert_eq "$ch" "$S_CONF_CHANNEL" "8 MHz channel $ch saved as $kind: rendered channel equals the supplied one"
    done
done
halow_test_teardown

# =========================================================================================
echo "-- 6: every saved option (all eleven) through validation, parsing, rendering and the status state --"
# roundtrip_set <label> <mode> <bw> <channel> <ssid> <subnet> <dhcp-start> <dhcp-end> <uplink> <ports-json> <expected-ports> <expected-max-stations> <expected-op-class> <expected-conf-channel>
roundtrip_set() {
    local label="$1" mode="$2" bw="$3" ch="$4" ssid="$5" subnet="$6" ds="$7" de="$8" up="$9" pj="${10}" ports="${11}" maxst="${12}" opc="${13}" confch="${14}"
    local n r
    lib_setup
    write_opts "$OPTS" region=AU radio_mode="$mode" bandwidth="$bw" channel="$ch" wifi_ssid="$ssid" halow_subnet_cidr="$subnet" dhcp_range_start="$ds" dhcp_range_end="$de" uplink_interface="$up" "allowed_ports=json:$pj"
    before="$(sum_of "$OPTS")"
    start_lib
    assert_eq "0" "$S_VALID" "$label: validation passes"
    assert_eq "AU" "$HALOW_CFG_REGION" "$label: region consumed unchanged"
    assert_eq "$mode" "$HALOW_CFG_RADIO_MODE" "$label: radio_mode consumed unchanged"
    assert_eq "$bw" "$HALOW_CFG_BANDWIDTH" "$label: bandwidth consumed unchanged"
    if [ "$mode" = "manual" ]; then
        assert_eq "$ch" "$HALOW_CFG_CHANNEL" "$label: channel consumed unchanged"
    else
        assert_eq "$ch" "$HALOW_CFG_CHANNEL_SAVED" "$label: channel kept unchanged as the saved channel (automatic mode consumes none)"
    fi
    assert_eq "$ssid" "$HALOW_CFG_WIFI_SSID" "$label: wifi_ssid consumed unchanged"
    if same_secret "$HALOW_CFG_WIFI_PASSPHRASE" "$SENT_PASS"; then r=yes; else r=no; fi
    assert_eq "yes" "$r" "$label: wifi_passphrase consumed unchanged (compared without printing)"
    assert_eq "$subnet" "$HALOW_CFG_SUBNET_CIDR" "$label: halow_subnet_cidr consumed unchanged"
    assert_eq "$ds" "$HALOW_CFG_DHCP_START" "$label: dhcp_range_start consumed unchanged"
    assert_eq "$de" "$HALOW_CFG_DHCP_END" "$label: dhcp_range_end consumed unchanged"
    assert_eq "$up" "$HALOW_CFG_UPLINK" "$label: uplink_interface consumed unchanged"
    assert_eq "$ports" "$HALOW_CFG_ALLOWED_PORTS" "$label: allowed_ports consumed unchanged"
    assert_eq "$maxst" "$HALOW_CFG_MAX_STATIONS" "$label: the pool size derived from the supplied DHCP range"
    assert_eq "" "$HALOW_CFG_DEFAULTED" "$label: every option was supplied, so nothing is marked defaulted"
    assert_failure "$label: no applied-default line in the log" grep -q -F "not supplied" "$LOADLOG"
    assert_success "$label: the valid line carries the consumed region, mode and bandwidth" grep -q -F "options: valid (region AU, $mode mode, $bw MHz" "$LOADLOG"
    # Rendering: the configuration carries what was supplied.
    assert_eq "$confch" "$S_CONF_CHANNEL" "$label: rendered channel"
    assert_eq "$opc" "$S_OPCLASS" "$label: rendered operating class"
    assert_eq "$ssid" "$(radio_conf_value "$S_CONF" ssid)" "$label: rendered ssid equals the supplied wifi_ssid"
    assert_eq "$maxst" "$(radio_conf_value "$S_CONF" max_num_sta)" "$label: rendered station limit equals the derived pool size"
    assert_success "$label: the rendered file (the only holder) carries the supplied passphrase" grep -q -F -- "$SENT_PASS" "$S_CONF"
    assert_eq "600" "$(stat -c '%a' "$S_CONF")" "$label: the rendered file is 0600"
    # Status and diagnostic state.
    assert_eq "AU" "$(snap_field 'd["region"]')" "$label: the status region equals the supplied region"
    assert_eq "$mode" "$(snap_field 'd["radio"]["mode"]')" "$label: the status requested mode equals the supplied one"
    assert_eq "$bw" "$(snap_field 'd["radio"]["requested"]["bandwidth_mhz"]')" "$label: the status requested bandwidth equals the supplied one"
    if [ "$mode" = "manual" ]; then
        assert_eq "$ch" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$label: the status requested channel equals the supplied one"
    else
        assert_eq "null" "$(snap_field 'd["radio"]["requested"]["channel"]')" "$label: no requested channel in automatic mode"
    fi
    status_text "$S_SNAP" json > "$HALOW_TEST_TMP/served.json"; status_text "$S_SNAP" page > "$HALOW_TEST_TMP/page.html"
    assert_success "$label: the passphrase is absent from the snapshot, the served JSON, the page and every log" no_secret "$S_SNAP" "$HALOW_TEST_TMP/served.json" "$HALOW_TEST_TMP/page.html" "$LOADLOG" "$ERR"
    assert_eq "$before" "$(sum_of "$OPTS")" "$label: the options file is byte-identical after the whole start"
    # Every option was read exactly once, with one argument.
    for n in $OPT_NAMES; do
        assert_eq "1 $n" "$(grep -x -F "1 $n" "$HALOW_TEST_BASHIO_LOG" | sort -u)" "$label: option $n was read through bashio::config with one argument"
        assert_eq "1" "$(grep -c -x -F "1 $n" "$HALOW_TEST_BASHIO_LOG")" "$label: option $n was read exactly once per start"
    done
    assert_eq "11" "$(wc -l < "$HALOW_TEST_BASHIO_LOG" | tr -d ' ')" "$label: exactly eleven reads, no other bashio call"
    halow_test_teardown
}
roundtrip_set "set A (manual 4 MHz channel 39)" manual 4 39 "My Net 7" 10.9.8.1/24 10.9.8.20 10.9.8.90 end0 '["tcp/1883","udp/5353"]' "tcp/1883 udp/5353" 71 52 39
roundtrip_set "set B (automatic 2 MHz, saved channel 41)" automatic 2 41 "HaLow-Z" 172.20.5.1/24 172.20.5.100 172.20.5.200 eth0 '["tcp/8123"]' "tcp/8123" 101 51 acs_survey
echo "-- 6: the list form that bashio prints (one entry per line) and the environment path --"
lib_setup
drop_bashio_emulation
export HALOW_OPT_REGION=AU HALOW_OPT_RADIO_MODE=manual HALOW_OPT_BANDWIDTH=4 HALOW_OPT_CHANNEL=39 HALOW_OPT_WIFI_SSID="My Net 7" HALOW_OPT_WIFI_PASSPHRASE="$SENT_PASS"
export HALOW_OPT_HALOW_SUBNET_CIDR=10.9.8.1/24 HALOW_OPT_DHCP_RANGE_START=10.9.8.20 HALOW_OPT_DHCP_RANGE_END=10.9.8.90 HALOW_OPT_UPLINK_INTERFACE=end0
export HALOW_OPT_ALLOWED_PORTS="tcp/1883
udp/5353"
reset_cfg; halow_options_load 2> "$LOADLOG"
assert_eq "tcp/1883 udp/5353" "$HALOW_CFG_ALLOWED_PORTS" "allowed_ports printed one per line is consumed unchanged"
assert_eq "My Net 7|end0|10.9.8.1/24" "$HALOW_CFG_WIFI_SSID|$HALOW_CFG_UPLINK|$HALOW_CFG_SUBNET_CIDR" "the environment path returns ssid, uplink and subnet unchanged"
unset HALOW_OPT_REGION HALOW_OPT_RADIO_MODE HALOW_OPT_BANDWIDTH HALOW_OPT_CHANNEL HALOW_OPT_WIFI_SSID HALOW_OPT_WIFI_PASSPHRASE HALOW_OPT_HALOW_SUBNET_CIDR HALOW_OPT_DHCP_RANGE_START HALOW_OPT_DHCP_RANGE_END HALOW_OPT_UPLINK_INTERFACE HALOW_OPT_ALLOWED_PORTS
halow_test_teardown

# =========================================================================================
echo "-- 3 and 7: restart cycles through the manager; consumed values, the valid line and the markers match the supplied ones --"
# mgr_start <mode> <bw> <channel-or-auto> [acs: ok|fail]: one manager start and stop on the options
# file. The recorded calls, state calls and log are cleared first (a new process, the same state
# directory, the same options file location).
MGR_VALID_TABLE=""
for w in 1 2 4 8; do MGR_VALID_TABLE="${MGR_VALID_TABLE}HL_VALID_$w=\"${RADIO_EXPECT_CHANNELS[$w]}\"; "; done
mgr_start() {
    local mode="$1" bw="$2" ch="$3" acs="${4:-ok}" rc=0 eff
    eff="$ch"; if [ "$mode" = "automatic" ]; then eff=35; [ "$acs" = "fail" ] && eff=43; fi
    write_opts "$HL_OPTS" radio_mode="$mode" bandwidth="$bw" channel="$ch"
    MGR_SUM="$(sum_of "$HL_OPTS")"
    : > "$HL_DIR/calls.log"; : > "$HL_DIR/state.log"; : > "$HALOW_TEST_BASHIO_LOG"; rm -f "$HL_DIR/write_attempt"
    [ "$acs" = "fail" ] && rc=1
    {
        printf '%s\n' ". '$HL_DIR/emul.sh'"
        printf '%s\n' "$MGR_VALID_TABLE"
        printf '%s\n' 'hl_act_halow_radio_validate() { local v="HL_VALID_$4"; if [ "$3" = manual ]; then case " ${!v:-} " in *" $5 "*) return 0 ;; esac; printf "OPTION=channel REASON=channel %s is not valid for %s MHz\n" "$5" "$4"; HL_ACT_RC=1; fi; return 0; }'
        printf '%s\n' "bashio::addon.option() { echo \"\$*\" >> '$HL_DIR/write_attempt'; }; bashio::app.option() { echo \"\$*\" >> '$HL_DIR/write_attempt'; }; wget() { echo \"\$*\" >> '$HL_DIR/write_attempt'; }; ha() { echo \"\$*\" >> '$HL_DIR/write_attempt'; }"
        printf '%s\n' "HL_SLEEP_LIMIT=6; HL_ACS_CHANNEL=35; HL_FALLBACK_CH=43; HL_RC_halow_radio_acs_wait=$rc"
        printf '%s\n' "hl_act_halow_radio_capture_effective() { HALOW_EFF_CHANNEL=$eff; HALOW_EFF_FREQ_KHZ=$((902000 + 500 * eff)); HALOW_EFF_BW_MHZ=$bw; return 0; }"
    } > "$HL_DIR/scenario.sh"
    hl_run_manager "$HL_DIR/scenario.sh"
}
hl_setup
export HALOW_TEST_BASHIO_LOG="$HL_DIR/bashio.log"; : > "$HALOW_TEST_BASHIO_LOG"
HL_OPTS="$HL_DIR/options.json"; export HALOW_TEST_OPTIONS_JSON="$HL_OPTS"
printf '%s\n' "$BASHIO_EMUL" > "$HL_DIR/emul.sh"
mkdir -p "$HALOW_STATE_DIR"
printf '40\n' > "$HALOW_STATE_DIR/last_channel"; printf '{"bandwidth":"1","channel":"99"}\n' > "$HALOW_STATE_DIR/last_good_options.json"
mgr_decoy="$(cat "$HALOW_STATE_DIR/last_channel" "$HALOW_STATE_DIR/last_good_options.json" | sha256sum | awk '{print $1}')"
prev_run="none"
# mode:bw:channel:acs (acs only matters in automatic mode); the ACS stand-in picks 35 and the
# fallback is 43, the two values most likely to be fed back into the next start if anything were.
for run in "manual:8:43:ok" "manual:8:35:ok" "manual:8:43:ok" "automatic:8:auto:ok" "manual:8:43:ok" "automatic:8:43:fail" "manual:8:35:ok" "automatic:8:auto:fail" "manual:8:43:ok" "manual:8:35:ok" "automatic:4:auto:ok" "manual:4:39:ok" "manual:2:41:ok" "manual:1:28:ok"; do
    IFS=: read -r mode bw ch acs <<< "$run"
    mgr_start "$mode" "$bw" "$ch" "$acs"
    t="manager start [$mode $bw MHz channel $ch, ACS $acs] after [$prev_run]"
    assert_eq "0" "$HL_EXIT" "$t: starts and stops cleanly"
    if [ "$mode" = "manual" ]; then
        assert_success "$t: the requested state is the supplied mode, bandwidth and channel" grep -q -x "radio_requested|manual|$bw|$ch" "$HL_DIR/state.log"
        assert_success "$t: the access point is rendered once with the supplied channel at the supplied bandwidth" grep -q "^halow_radio_render AU manual $bw $ch " "$HL_DIR/calls.log"
        assert_eq "1" "$(grep -c '^halow_radio_render ' "$HL_DIR/calls.log")" "$t: exactly one render"
        assert_success "$t: the effective state agrees (channel $ch, $bw MHz, manual)" grep -q "^radio_effective|[0-9]*|$ch|$bw|manual|" "$HL_DIR/state.log"
        assert_success "$t: the valid line names this mode, bandwidth and channel" grep -q -F "options: valid (region AU, manual mode, $bw MHz, channel $ch)" "$HL_DIR/out.log"
    else
        assert_success "$t: the requested state is automatic with the supplied bandwidth and no channel" grep -q -x "radio_requested|automatic|$bw|" "$HL_DIR/state.log"
        assert_eq "0" "$(grep '^halow_radio_render ' "$HL_DIR/calls.log" | grep -c -v "^halow_radio_render AU [a-z]* $bw ")" "$t: no render asks for a bandwidth other than $bw"
        if [ "$acs" = "ok" ]; then
            assert_success "$t: selection result recorded as the effective channel 35 (this run only)" grep -q "^radio_effective|[0-9]*|35|$bw|acs|" "$HL_DIR/state.log"
        else
            assert_success "$t: the fallback is rendered for this run only" grep -q "^halow_radio_render AU fallback $bw 43 " "$HL_DIR/calls.log"
        fi
        if [ "$ch" = "auto" ]; then
            assert_success "$t: the valid line has no channel and no ignored-channel clause" grep -q -F "options: valid (region AU, automatic mode, $bw MHz)" "$HL_DIR/out.log"
        else
            assert_success "$t: the valid line says the saved channel $ch is ignored" grep -q -F "options: valid (region AU, automatic mode, $bw MHz; saved channel $ch ignored in automatic mode)" "$HL_DIR/out.log"
        fi
    fi
    assert_failure "$t: no default was applied" grep -q -F "not supplied" "$HL_DIR/out.log"
    assert_failure "$t: no defaults clause in the valid line" grep -q -F "defaults applied" "$HL_DIR/out.log"
    assert_eq "$MGR_SUM" "$(sum_of "$HL_OPTS")" "$t: the options file is byte-identical after the start and stop"
    assert_eq "11" "$(wc -l < "$HALOW_TEST_BASHIO_LOG" | tr -d ' ')" "$t: exactly eleven bashio::config reads, one per option"
    assert_eq "0" "$(grep -c -v '^1 ' "$HALOW_TEST_BASHIO_LOG")" "$t: every bashio::config call had exactly one argument"
    assert_failure "$t: no option setter, wget or ha call was attempted" test -e "$HL_DIR/write_attempt"
    assert_failure "$t: no curl call" hl_called curl
    assert_success "$t: the passphrase is in no manager output, call record or state record" no_secret "$HL_DIR/out.log" "$HL_DIR/calls.log" "$HL_DIR/state.log"
    prev_run="$mode $bw $ch"
done
assert_eq "$mgr_decoy" "$(cat "$HALOW_STATE_DIR/last_channel" "$HALOW_STATE_DIR/last_good_options.json" | sha256sum | awk '{print $1}')" "the planted last-channel and last-good files were never rewritten across the restart cycles"
echo "-- 3: a genuinely absent bandwidth and mode are defaulted, and the markers say so exactly (and only then) --"
write_opts "$HL_OPTS" radio_mode= bandwidth= channel=auto
: > "$HL_DIR/calls.log"; : > "$HL_DIR/state.log"; : > "$HALOW_TEST_BASHIO_LOG"
printf '%s\n' ". '$HL_DIR/emul.sh'; HL_SLEEP_LIMIT=6" > "$HL_DIR/scenario.sh"
hl_run_manager "$HL_DIR/scenario.sh"
assert_success "empty mode and bandwidth: the requested state is the defaults (automatic, $HALOW_DEFAULT_BANDWIDTH_MHZ MHz)" grep -q -x "radio_requested|automatic|${HALOW_DEFAULT_BANDWIDTH_MHZ:-1}|" "$HL_DIR/state.log"
assert_success "empty mode and bandwidth: the valid line names both defaults" grep -q -F "defaults applied for: radio_mode bandwidth" "$HL_DIR/out.log"
assert_eq "2" "$(grep -c -F 'not supplied, using default' "$HL_DIR/out.log")" "empty mode and bandwidth: one marker line each"
halow_test_teardown

# =========================================================================================
echo "-- 7: no shipped code assigns the consumed options from anywhere but the option reader --"
violations="$(python3 -I - "$ROOTFS" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
assign = re.compile(r"(HALOW_CFG_[A-Z_]+)\s*\+?=|printf\s+-v\s+HALOW_CFG_|read\s+(-\S+\s+)*HALOW_CFG_|declare\s+(-\S+\s+)*HALOW_CFG_[A-Z_]+=|export\s+HALOW_CFG_[A-Z_]+=")
for base, _d, names in os.walk(root):
    for n in names:
        p = os.path.join(base, n)
        rel = os.path.relpath(p, root).replace(os.sep, "/")
        try:
            lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            code = re.sub(r"^\s*#.*$", "", line)
            if rel != "usr/lib/halow/options.sh" and assign.search(code):
                bad.append("%s:%d: assigns an option variable outside the option reader" % (rel, i))
            if rel == "usr/lib/halow/options.sh":
                if re.search(r"HALOW_STATE_DIR|HALOW_STATUS_FILE|HALOW_RUN_DIR|last_applied|req_bw|req_channel", code):
                    bad.append("%s:%d: the option reader refers to state" % (rel, i))
                if re.search(r"(^|[^<])<\s*[\"$/.\w]|\bcat\b|\bsource\b|^\s*\.\s+\S", code):
                    bad.append("%s:%d: the option reader reads a file" % (rel, i))
for b in bad:
    print(b)
PY
)"
assert_eq "" "$violations" "option variables are assigned only in options.sh, which reads neither files nor state"
assert_success "the manager reads the options in exactly one step" bash -c 'test "$(grep -c "halow_options_load" "$1")" -ge 1 && test "$(grep -n "halow_options_load" "$1" | grep -v "^[0-9]*:[[:space:]]*#" | grep -v "HALOW_MGR_REQUIRED_FUNCS" | wc -l)" -eq 1' _ "$ROOTFS/usr/lib/halow/manager.sh"
assert_success "this suite's source names the sentinel exactly once, in its definition" bash -c 'test "$(grep -c -F "Qq-44""17" "$1")" -eq 1' _ "${BASH_SOURCE[0]}"
assert_eq "0" "$(grep -c -P '\xe2\x80\x94' "${BASH_SOURCE[0]}")" "this suite's source has no em dash"

echo "test_option_transitions: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then exit 1; fi
exit 0
