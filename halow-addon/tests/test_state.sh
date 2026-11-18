#!/usr/bin/env bash
# The status snapshot writer: schema, every setter, hostile input, JSON escaping,
# redaction, atomic writes, the bounded log tail, and strict-mode safety.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_status.sh

echo "== test_state =="
halow_status_test_setup
trap halow_status_test_teardown EXIT
F="$HALOW_STATUS_FILE"
PP="pass""phrase"
SECRET_VALUE="Tr0ub4dor-and-3-horses"

echo "-- init --"
export HALOW_STATE_NOW=1000
assert_file_absent "$HALOW_RUN_DIR" "run directory absent before init"
assert_success "halow_state_init succeeds" halow_state_init
# (assert_success runs in this shell, so the state is kept)
assert_file_exists "$F" "init writes the snapshot"
assert_success "snapshot is valid JSON" json_valid "$F"
assert_eq "644" "$(file_mode "$F")" "snapshot mode is 0644"
assert_eq '["schema", "updated_at", "started_at", "boot_id", "overall", "attention", "advisory", "region", "radio", "adapter", "backend", "stations", "diagnostics"]' \
    "$(json_get "$F" 'list(d.keys())')" "top-level keys exactly as schema 2"
assert_eq "2" "$(json_get "$F" 'd["schema"]')" "schema is 2"
assert_eq "starting" "$(json_get "$F" 'd["overall"]')" "overall starts as starting"
assert_eq "1000" "$(json_get "$F" 'd["started_at"]')" "started_at recorded"
assert_eq "1000" "$(json_get "$F" 'd["updated_at"]')" "updated_at recorded"
assert_eq "0d6c1a3e-7c55-4c1e-9d55-2f1f7f4b9a01" "$(json_get "$F" 'd["boot_id"]')" "boot_id read from the kernel file"
assert_eq "null" "$(json_get "$F" 'd["attention"]')" "attention null"
assert_eq "null" "$(json_get "$F" 'd["advisory"]')" "advisory null"
assert_eq '{"mode": "", "requested": {"bandwidth_mhz": null, "channel": null}, "effective": null, "last_applied": null}' \
    "$(json_get "$F" 'd["radio"]')" "radio defaults"
assert_eq '{"present": false, "interface": ""}' "$(json_get "$F" 'd["adapter"]')" "adapter defaults"
assert_eq '{"applied": false, "bridge": "", "subnet": "", "gateway": ""}' "$(json_get "$F" 'd["backend"]')" "backend defaults"
assert_eq "[]" "$(json_get "$F" 'd["stations"]')" "no stations"
assert_eq '{"log_tail": []}' "$(json_get "$F" 'd["diagnostics"]')" "empty diagnostics"
assert_eq "0" "$(find "$HALOW_RUN_DIR" -name '.status.json.*' | wc -l | tr -d ' ')" "no temporary file left behind"

echo "-- heartbeat --"
export HALOW_STATE_NOW=1010
halow_state_heartbeat
assert_eq "1010" "$(json_get "$F" 'd["updated_at"]')" "heartbeat refreshes updated_at"
assert_eq "1000" "$(json_get "$F" 'd["started_at"]')" "heartbeat keeps started_at"

echo "-- region and requested radio --"
halow_state_region AU
assert_eq "AU" "$(json_get "$F" 'd["region"]')" "region recorded and flushed"
halow_state_radio_requested automatic 2 5
assert_eq '["automatic", 2, null]' "$(json_get "$F" '[d["radio"]["mode"], d["radio"]["requested"]["bandwidth_mhz"], d["radio"]["requested"]["channel"]]')" \
    "automatic mode ignores the channel"
halow_state_radio_requested manual 4 12
assert_eq '["manual", 4, 12]' "$(json_get "$F" '[d["radio"]["mode"], d["radio"]["requested"]["bandwidth_mhz"], d["radio"]["requested"]["channel"]]')" \
    "manual mode keeps the channel"
assert_failure "an invalid mode is refused" halow_state_radio_requested sideways 1 1
assert_eq "manual" "$(json_get "$F" 'd["radio"]["mode"]')" "refused call changes nothing"
halow_state_radio_requested manual 008 ""
assert_eq '[8, null]' "$(json_get "$F" '[d["radio"]["requested"]["bandwidth_mhz"], d["radio"]["requested"]["channel"]]')" \
    "leading zeros normalised, empty channel is null"

echo "-- effective radio values and last applied --"
export HALOW_STATE_NOW=1100
halow_state_radio_effective 923000 42 1 acs implemented none
assert_eq '{"frequency_khz": 923000, "channel": 42, "bandwidth_mhz": 1, "source": "acs", "applied_at": 1100, "validation": "implemented", "fallback_validated": null}' \
    "$(json_get "$F" 'd["radio"]["effective"]')" "effective values with source and applied_at"
assert_failure "unknown source refused" halow_state_radio_effective 923000 42 1 guess implemented none
assert_failure "unknown validation refused" halow_state_radio_effective 923000 42 1 acs proven none
assert_failure "unknown fallback_validated refused" halow_state_radio_effective 923000 42 1 acs implemented maybe
assert_eq "acs" "$(json_get "$F" 'd["radio"]["effective"]["source"]')" "refused calls change nothing"
export HALOW_STATE_NOW=1200
halow_state_radio_clear_effective
assert_eq "null" "$(json_get "$F" 'd["radio"]["effective"]')" "AP down: effective null"
assert_eq '{"frequency_khz": 923000, "channel": 42, "bandwidth_mhz": 1, "source": "acs", "applied_at": 1100, "validation": "implemented", "fallback_validated": null}' \
    "$(json_get "$F" 'd["radio"]["last_applied"]')" "AP down: the last applied values keep when they were applied"
halow_state_radio_clear_effective
assert_eq "1100" "$(json_get "$F" 'd["radio"]["last_applied"]["applied_at"]')" "a second clear keeps last_applied"
halow_state_radio_effective 924000 30 2 fallback implemented false
assert_eq '["fallback", false]' "$(json_get "$F" '[d["radio"]["effective"]["source"], d["radio"]["effective"]["fallback_validated"]]')" \
    "fallback source and unvalidated fallback recorded"
halow_state_radio_effective 925000 31 1 manual live-validated true
assert_eq '["manual", "live-validated", true]' "$(json_get "$F" '[d["radio"]["effective"]["source"], d["radio"]["effective"]["validation"], d["radio"]["effective"]["fallback_validated"]]')" \
    "manual source recorded"

echo "-- adapter and backend --"
halow_state_adapter true wlan1
assert_eq '{"present": true, "interface": "wlan1"}' "$(json_get "$F" 'd["adapter"]')" "adapter present"
assert_failure "adapter presence must be true or false" halow_state_adapter yes wlan1
halow_state_adapter false ""
assert_eq '{"present": false, "interface": ""}' "$(json_get "$F" 'd["adapter"]')" "adapter absent"
halow_state_backend true halow-br0 10.42.0.0/24 10.42.0.1
assert_eq '{"applied": true, "bridge": "halow-br0", "subnet": "10.42.0.0/24", "gateway": "10.42.0.1"}' \
    "$(json_get "$F" 'd["backend"]')" "backend applied"
assert_failure "backend applied must be true or false" halow_state_backend 1 a b c

echo "-- attention and the catalogue entry --"
export HALOW_STATE_NOW=2000
halow_state_overall operating
halow_state_attention NO_ADAPTER "no device 325b:8100" true
assert_eq "attention" "$(json_get "$F" 'd["overall"]')" "attention sets overall"
assert_eq "NO_ADAPTER" "$(json_get "$F" 'd["attention"]["code"]')" "code recorded"
assert_eq "$(halow_error_summary NO_ADAPTER)" "$(json_get "$F" 'd["attention"]["summary"]')" "summary from the catalogue"
assert_eq "$(halow_error_action NO_ADAPTER)" "$(json_get "$F" 'd["attention"]["action"]')" "action from the catalogue"
assert_eq '["no device 325b:8100", 2000, true, true]' \
    "$(json_get "$F" '[d["attention"][k] for k in ("detail","since","host_clean","retryable")]')" "detail, since, host_clean, retryable"
export HALOW_STATE_NOW=2500
halow_state_attention NO_ADAPTER "still nothing" false
assert_eq '[2000, "still nothing", false]' "$(json_get "$F" '[d["attention"]["since"], d["attention"]["detail"], d["attention"]["host_clean"]]')" \
    "the same code again keeps since, updates detail and host_clean"
export HALOW_STATE_NOW=2600
halow_state_overall starting
assert_eq '["starting", null]' "$(json_get "$F" '[d["overall"], d["attention"]]')" "a new attempt (starting) removes the entry"
export HALOW_STATE_NOW=2700
halow_state_attention NO_ADAPTER "retry failed" true
assert_eq "2000" "$(json_get "$F" 'd["attention"]["since"]')" "since kept across a retry attempt with the same code"
export HALOW_STATE_NOW=2800
halow_state_attention AP_START_FAILED "hostapd exited" true
assert_eq '["AP_START_FAILED", 2800, false]' "$(json_get "$F" '[d["attention"]["code"], d["attention"]["since"], d["attention"]["retryable"]]')" \
    "a different code gets a new since and its own retry class"
halow_state_attention UPLINK_UNAVAILABLE "" maybe
assert_eq '[false, true]' "$(json_get "$F" '[d["attention"]["host_clean"], d["attention"]["retryable"]]')" \
    "host_clean other than true is recorded as false"
export HALOW_STATE_NOW=2900
halow_state_overall operating
assert_eq '["operating", null]' "$(json_get "$F" '[d["overall"], d["attention"]]')" "operating removes the entry"
export HALOW_STATE_NOW=3000
halow_state_attention UPLINK_UNAVAILABLE "lost" true
assert_eq "3000" "$(json_get "$F" 'd["attention"]["since"]')" "after operating, the same code starts a new incident"
halow_state_attention BOGUS_CODE "weird" true
assert_eq "INTERNAL_ERROR" "$(json_get "$F" 'd["attention"]["code"]')" "an unknown code is recorded as INTERNAL_ERROR"
assert_success "the unknown code is named in the detail" bash -c '[[ "$1" == *BOGUS_CODE*weird* ]]' _ "$(json_get "$F" 'd["attention"]["detail"]')"
halow_state_attention RADIO_AUTO_FALLBACK "x" true
assert_eq "INTERNAL_ERROR" "$(json_get "$F" 'd["attention"]["code"]')" "the advisory code cannot be an attention entry"
halow_state_clear_attention
assert_eq '["starting", null]' "$(json_get "$F" '[d["overall"], d["attention"]]')" "clear_attention removes the entry; attention becomes starting"
assert_failure "an invalid overall state is refused" halow_state_overall stopped
assert_eq "starting" "$(json_get "$F" 'd["overall"]')" "no page-level stopped state"

echo "-- the advisory never changes overall --"
halow_state_overall operating
export HALOW_STATE_NOW=3500
halow_state_advisory RADIO_AUTO_FALLBACK
assert_eq "operating" "$(json_get "$F" 'd["overall"]')" "advisory leaves overall operating"
assert_eq '["RADIO_AUTO_FALLBACK", 3500]' "$(json_get "$F" '[d["advisory"]["code"], d["advisory"]["since"]]')" "advisory recorded with since"
assert_eq "$(halow_error_summary RADIO_AUTO_FALLBACK)" "$(json_get "$F" 'd["advisory"]["summary"]')" "advisory summary from the catalogue"
assert_eq '["code", "summary", "action", "since"]' "$(json_get "$F" 'list(d["advisory"].keys())')" "advisory fields"
export HALOW_STATE_NOW=3600
halow_state_advisory RADIO_AUTO_FALLBACK
assert_eq "3500" "$(json_get "$F" 'd["advisory"]["since"]')" "advisory since kept when set again"
assert_failure "a non-advisory code is refused as advisory" halow_state_advisory NO_ADAPTER
halow_state_attention AP_DIED "gone" false
assert_eq '["attention", "RADIO_AUTO_FALLBACK"]' "$(json_get "$F" '[d["overall"], d["advisory"]["code"]]')" "attention and advisory are independent"
halow_state_clear_advisory
assert_eq '["attention", null]' "$(json_get "$F" '[d["overall"], d["advisory"]]')" "clear_advisory leaves overall alone"

echo "-- stations (schema 2: primary row, own addresses, downstream devices) --"
SF="$HALOW_TEST_TMP/stations.txt"
{
    # An ordinary station with a lease; an offline WDS station with nothing behind it; a WDS
    # station with several devices (one with two addresses, one with none, one conflicting).
    printf '%s\n' "S|02:11:22:33:44:55|true|ordinary|3700|3700|0"
    printf '%s\n' "SI|10.42.0.20|dhcp|0"
    printf '%s\n' "S|02:aa:bb:cc:dd:ee|false|wds||3600|0"
    printf '%s\n' "S|02:00:00:00:00:30|true|wds|3800|3800|2|hostapd"
    printf '%s\n' "D|02:00:00:00:00:31"
    printf '%s\n' "DI|10.42.0.31|dhcp+neighbour|0"
    printf '%s\n' "DI|10.42.0.32|neighbour|1"
    printf '%s\n' "D|02:00:00:00:00:33"
    printf '%s\n' "D|02:00:00:00:00:34"
    printf '%s\n' "DI|10.42.0.32|dhcp|1"
} > "$SF"
halow_state_stations_set "$SF"
assert_success "snapshot valid JSON" json_valid "$F"
assert_eq "2" "$(json_get "$F" 'd["schema"]')" "schema is 2"
assert_eq "3" "$(json_get "$F" 'len(d["stations"])')" "one primary row per station record"
assert_eq '{"mac": "02:11:22:33:44:55", "online": true, "online_source": "log", "kind": "ordinary", "connected_since": 3700, "state_changed_at": 3700, "ips": [{"ip": "10.42.0.20", "source": "dhcp", "conflict": false}], "devices": [], "devices_omitted": 0}' \
    "$(json_get "$F" 'd["stations"][0]')" "ordinary station: own address, no devices"
assert_eq '{"mac": "02:aa:bb:cc:dd:ee", "online": false, "online_source": "log", "kind": "wds", "connected_since": null, "state_changed_at": 3600, "ips": [], "devices": [], "devices_omitted": 0}' \
    "$(json_get "$F" 'd["stations"][1]')" "offline WDS station: no connected_since, no addresses, zero devices"
assert_eq '[3, 2]' "$(json_get "$F" '[len(d["stations"][2]["devices"]), d["stations"][2]["devices_omitted"]]')" "several downstream devices, omitted count carried"
assert_eq '[{"ip": "10.42.0.31", "source": "dhcp+neighbour", "conflict": false}, {"ip": "10.42.0.32", "source": "neighbour", "conflict": true}]' \
    "$(json_get "$F" 'd["stations"][2]["devices"][0]["ips"]')" "a device with two addresses, one marked conflicting"
assert_eq '[]' "$(json_get "$F" 'd["stations"][2]["devices"][1]["ips"]')" "a device without a mapping has an empty address list (shown as unknown)"
assert_eq '[{"ip": "10.42.0.32", "source": "dhcp", "conflict": true}]' "$(json_get "$F" 'd["stations"][2]["devices"][2]["ips"]')" "the other claimant of the conflicting address is marked too"
assert_eq '["log", "log", "hostapd"]' "$(json_get "$F" '[s["online_source"] for s in d["stations"]]')" "online_source: hostapd only when the writer is told so, otherwise log"
assert_failure "a missing station file is refused" halow_state_stations_set "$HALOW_TEST_TMP/nope"
assert_eq "3" "$(json_get "$F" 'len(d["stations"])')" "refused call keeps the list"

# Hostile and malformed records: nothing but validated values reaches the JSON.
{
    printf '%s\n' ""
    printf '%s\n' "S||true|ordinary|1|1|0"
    printf '%s\n' "SI|10.0.0.9|dhcp|0"
    printf '%s\n' 'S|x"<script>alert(1)</script>\|yes|alien|notanumber|"; rm -rf /|junk'
    printf '%s\n' 'SI|<b>1.2.3.4</b>|dhcp|0'
    printf '%s\n' 'D|02:00:00:00:00:41'
    printf '%s\n' 'DI|<img src=x onerror=alert(1)>|dhcp|0'
    printf '%s\n' 'DI|999.1.1.1|dhcp|0'
    printf '%s\n' 'DI|10.1.1.1|evil|0'
    printf '%s\n' 'DI|10.1.1.2|neighbour|0'
    printf '%s\r\n' "S|02:00:00:00:00:01|true|ordinary|3800|3900|abc"
    printf '%s\r\n' "SI|10.42.0.21|dhcp|0"
    printf '%s\n' 'SI|<b>x</b>|dhcp|0' 'SI|999.1.1.1|dhcp|0' 'SI|10.1.1.1|evil|0' 'SI|01.2.3.4|dhcp|0' 'SI|10.1.1.2|dhcp;rm|0'
    printf '%s\n' "S|02:00:00:00:00:02|maybe|alien||x|0|<b>hostapd</b>"
    printf '%s\n' 'D|"><script>'
    printf '%s\n' 'D|02:00:00:00:00:42'
    printf '%s\n' 'SI|10.0.0.77|dhcp|0'
} > "$SF"
halow_state_stations_set "$SF"
assert_success "snapshot valid JSON after hostile records" json_valid "$F"
assert_eq "2" "$(json_get "$F" 'len(d["stations"])')" "records with an invalid MAC are skipped (with everything under them)"
assert_eq '{"mac": "02:00:00:00:00:01", "online": true, "online_source": "log", "kind": "ordinary", "connected_since": 3800, "state_changed_at": 3900, "ips": [{"ip": "10.42.0.21", "source": "dhcp", "conflict": false}], "devices": [], "devices_omitted": 0}' \
    "$(json_get "$F" 'd["stations"][0]')" "CRLF line endings tolerated; a non-numeric omitted count becomes 0"
assert_eq '[false, "ordinary", null, null, "log"]' "$(json_get "$F" '[d["stations"][1][k] for k in ("online","kind","connected_since","state_changed_at","online_source")]')" "hostile fields normalised (an unknown online_source is log)"
assert_eq '["02:00:00:00:00:42"]' "$(json_get "$F" '[x["mac"] for x in d["stations"][1]["devices"]]')" "an invalid device MAC is skipped, a valid one kept"
assert_eq "0" "$(count_in_file "$F" "script")" "no hostile text reaches the file"
assert_eq "0" "$(count_in_file "$F" "onerror")" "...nor an invalid address"
assert_eq "0" "$(count_in_file "$F" "evil")" "...nor an unknown source"

# Bounds.
{
    printf '%s\n' "S|02:00:00:00:01:00|true|wds|1|1|0"
    for _i in $(seq 1 40); do printf 'D|02:00:00:00:02:%02x\n' "$_i"; done
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'SI|10.9.0.%d|dhcp|0\n' "$_i"; done
} > "$SF"
HALOW_STATE_DEVICES_PER_STATION_MAX=5 halow_state_stations_set "$SF"
assert_eq '[5, 35, 8]' "$(json_get "$F" '[len(d["stations"][0]["devices"]), d["stations"][0]["devices_omitted"], len(d["stations"][0]["ips"])]')" "devices per station and addresses per MAC are bounded, and the omitted devices counted"
: > "$SF"
halow_state_stations_set "$SF"
assert_eq "[]" "$(json_get "$F" 'd["stations"]')" "an empty file clears the list"

echo "-- JSON escaping --"
ESC_DIR="$HALOW_TEST_TMP/esc"; mkdir -p "$ESC_DIR"
check_escape() { # check_escape <name> <string>
    printf '%s' "$2" > "$ESC_DIR/raw"
    printf '"%s"' "$(halow_json_escape "$2")" > "$ESC_DIR/lit"
    python3 -I - "$ESC_DIR/raw" "$ESC_DIR/lit" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
lit = open(sys.argv[2], "rb").read()
value = json.loads(lit.decode("utf-8"))
try:
    expected = raw.decode("utf-8")
except UnicodeDecodeError:
    expected = None
if expected is not None:
    sys.exit(0 if value == expected else 1)
sys.exit(0 if "�" in value else 1)
PY
}
assert_success "plain ASCII round-trips" check_escape plain "hello world 123"
assert_success "quotes and backslashes round-trip" check_escape quotes 'a "quoted" \ back\\slash \" end\'
assert_success "control characters round-trip" check_escape ctl $'tab\there\nnewline\rcr\x01\x02\x1b[0m\x1f\x7f end'
assert_success "multi-byte UTF-8 round-trips" check_escape utf8 $'caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x98\x80 \xe2\x80\xa8'
assert_success "invalid UTF-8 becomes replacement characters" check_escape invalid $'bad \xff \xc3( \xe6\x97 \xed\xa0\x80 \xc0\xaf end'
assert_success "truncated sequence at the end is replaced" check_escape trunc $'end \xe2\x82'
assert_eq 'a\"b\\c\nd\u0001' "$(halow_json_escape $'a"b\\c\nd\x01')" "escape output form"
assert_eq "" "$(halow_json_escape "")" "empty string"
LC_ALL=C.UTF-8 bash -c '. "$1/errors.sh"; . "$1/state.sh"; halow_json_escape "x"; [ "${LC_ALL}" = "C.UTF-8" ]' _ "$HALOW_STATUS_LIB_DIR" >/dev/null
assert_eq "0" "$?" "the caller's locale is restored after escaping"

echo "-- redaction --"
assert_eq "hello 10.42.0.1 wlan0" "$(halow_redact "hello 10.42.0.1 wlan0")" "harmless text unchanged"
out="$(halow_redact "wpa_${PP}=${SECRET_VALUE} trailing")"
assert_success "wpa_${PP}= value removed" bash -c '[[ "$1" != *"$2"* && "$1" == "wpa_'"$PP"'=[redacted]" ]]' _ "$out" "$SECRET_VALUE"
out="$(halow_redact "options: ${PP}: ${SECRET_VALUE}")"
assert_success "${PP}: value removed" bash -c '[[ "$1" != *"$2"* ]]' _ "$out" "$SECRET_VALUE"
out="$(halow_redact "PASSWORD=${SECRET_VALUE}")"
assert_success "uppercase key redacted" bash -c '[[ "$1" != *"$2"* ]]' _ "$out" "$SECRET_VALUE"
out="$(halow_redact "{\"wifi_${PP}\": \"a\\\"${SECRET_VALUE} x\", \"ssid\":\"net\"}")"
assert_success "JSON-style value removed, structure kept" \
    bash -c '[[ "$1" != *"$2"* && "$1" == *"\"ssid\":\"net\""* && "$1" == *"[redacted]"* ]]' _ "$out" "$SECRET_VALUE"
HEX64="$(printf 'ab%.0s' {1..32})"
out="$(halow_redact "psk ${HEX64} end")"
assert_eq "psk [redacted] end" "$out" "64-hex key removed"
HEX63="${HEX64:0:63}"
assert_eq "id ${HEX63}" "$(halow_redact "id ${HEX63}")" "63 hex digits are not a key"
out="$(halow_redact $'line one\npassword=abc def\nline three')"
assert_eq $'line one\npassword=[redacted]\nline three' "$out" "per-line redaction keeps other lines"
out="$(HALOW_CFG_WIFI_PASSPHRASE="$SECRET_VALUE" halow_redact "hostapd said ${SECRET_VALUE} was wrong")"
assert_eq "hostapd said [redacted] was wrong" "$out" "the configured passphrase is removed wherever it appears"
out="$(halow_redact "SUPERVISOR_TOKEN=Zt0kenValue9 rest")"
assert_eq "SUPERVISOR_TOKEN=[redacted]" "$out" "a token assignment is redacted"
out="$(SUPERVISOR_TOKEN="Zt0kenValue9" halow_redact "curl said Zt0kenValue9 was refused")"
assert_eq "curl said [redacted] was refused" "$out" "the Supervisor token value is removed wherever it appears"
out="$(HASSIO_TOKEN="Hx0kenValue8" halow_redact "header Hx0kenValue8")"
assert_eq "header [redacted]" "$out" "the older token variable's value is removed too"
shopt -u nocasematch
halow_redact "password=x" >/dev/null
assert_failure "nocasematch is restored after redaction" shopt -q nocasematch

echo "-- secrets never reach the snapshot --"
export HALOW_CFG_WIFI_PASSPHRASE="$SECRET_VALUE"
halow_state_attention CONFIG_INVALID "option wifi_${PP}=${SECRET_VALUE} rejected" true
halow_state_region "AU ${PP}=${SECRET_VALUE}"
halow_state_diag_set config "wpa_${PP}=${SECRET_VALUE}"
halow_state_diag_set key "${HEX64}"
halow_state_diag_set note "the ${SECRET_VALUE} leaked"
halow_state_diag_log_append "hostapd: wpa_${PP}=${SECRET_VALUE}"
halow_state_diag_log_append "{\"${PP}\":\"${SECRET_VALUE}\"}"
printf '%s\n' "S|02:00:00:00:0a:01|true|wds|1|1|0" "SI|${SECRET_VALUE}|dhcp|0" "D|${SECRET_VALUE}" "DI|${HEX64}|dhcp|0" "D|02:00:00:00:0a:02" "DI|10.0.0.5|neighbour|0" > "$SF"
halow_state_stations_set "$SF"
halow_state_flush
unset HALOW_CFG_WIFI_PASSPHRASE
assert_success "snapshot still valid" json_valid "$F"
assert_eq "0" "$(count_in_file "$F" "$SECRET_VALUE")" "the passphrase never appears in the snapshot file"
assert_eq "0" "$(count_in_file "$F" "$HEX64")" "the 64-hex key never appears in the snapshot file"
assert_eq "[redacted]" "$(json_get "$F" 'd["diagnostics"]["key"]')" "the key entry is redacted"

echo "-- diagnostics entries and the bounded log tail --"
assert_failure "invalid diagnostics key refused" halow_state_diag_set 'bad key' v
assert_failure "reserved diagnostics key refused" halow_state_diag_set log_tail v
halow_state_diag_set op_class 50
assert_success "diag_set does not flush by itself" bash -c '! grep -q op_class "$1"' _ "$F"
halow_state_flush
assert_eq "50" "$(json_get "$F" 'd["diagnostics"]["op_class"]')" "diagnostics entry written by the next flush"
halow_state_diag_set op_class 52
halow_state_flush
assert_eq '[52, 1]' "$(json_get "$F" '[int(d["diagnostics"]["op_class"]), list(d["diagnostics"].keys()).count("op_class")]')" "re-setting a key replaces it"
for i in $(seq 1 250); do halow_state_diag_log_append "line $i"; done
halow_state_flush
assert_eq '[200, "line 51", "line 250"]' "$(json_get "$F" '[len(d["diagnostics"]["log_tail"]), d["diagnostics"]["log_tail"][0], d["diagnostics"]["log_tail"][-1]]')" \
    "log tail bounded to the newest 200 lines"
halow_state_diag_log_append "$(printf 'x%.0s' $(seq 1 3000))"
halow_state_flush
assert_eq "2000" "$(json_get "$F" 'len(d["diagnostics"]["log_tail"][-1])')" "a long log line is cut"

echo "-- hostile input everywhere keeps the snapshot valid --"
HOSTILE=$'q"uo\\te </script> \x01\x1f\x7f \n new\tline \xff\xfe caf\xc3\xa9 ${x} $(id) `id`'
halow_state_region "$HOSTILE"
halow_state_adapter true "$HOSTILE"
halow_state_backend true "$HOSTILE" "$HOSTILE" "$HOSTILE"
halow_state_attention INTERNAL_ERROR "$HOSTILE" false
halow_state_diag_set hostile "$HOSTILE"
halow_state_diag_log_append "$HOSTILE"
halow_state_flush
assert_success "snapshot valid JSON with hostile strings in every field" json_valid "$F"
assert_success "hostile region decodes to the same text (valid parts)" \
    bash -c '[[ "$1" == *"q\"uo\\te </script>"* && "$1" == *"café"* ]]' _ "$(json_get "$F" 'd["region"]')"
assert_eq '["$(id)", "`id`"]' "$(json_get "$F" '["$(id)" if "$(id)" in d["region"] else "", "`id`" if "`id`" in d["region"] else ""]')" \
    "no shell expansion of hostile text"

echo "-- atomic writes: a reader never sees a partial file --"
halow_state_init
for i in $(seq 1 60); do halow_state_diag_log_append "padding line $i $(printf 'y%.0s' $(seq 1 200))"; done
DONE="$HALOW_TEST_TMP/writer.done"
(
    for i in $(seq 1 120); do halow_state_region "R$i"; done
    : > "$DONE"
) &
WRITER=$!
READER_OUT="$(python3 -I - "$F" "$DONE" <<'PY'
import json, os, sys, time
path, done = sys.argv[1], sys.argv[2]
reads = bad = 0
deadline = time.time() + 120
while time.time() < deadline:
    finished = os.path.exists(done)
    try:
        with open(path, "rb") as handle:
            data = handle.read()
        json.loads(data.decode("utf-8"))
        reads += 1
    except FileNotFoundError:
        bad += 1
    except ValueError:
        bad += 1
    if finished:
        break
print("%d %d" % (reads, bad))
PY
)"
wait "$WRITER"
reads="${READER_OUT% *}"; bad="${READER_OUT#* }"
assert_eq "0" "$bad" "no partial or missing snapshot observed during $reads reads"
assert_success "the reader read the file many times" test "$reads" -gt 20
assert_eq "R120" "$(json_get "$F" 'd["region"]')" "last write wins"
assert_eq "0" "$(find "$HALOW_RUN_DIR" -name '.status.json.*' | wc -l | tr -d ' ')" "no temporary files left behind"

echo "-- a failed write is reported, not fatal --"
chmod 0555 "$HALOW_RUN_DIR"
assert_failure "flush fails when the directory is not writable" halow_state_flush
assert_success "a setter still returns 0 when the write fails" halow_state_region XX
chmod 0755 "$HALOW_RUN_DIR"
assert_eq "R120" "$(json_get "$F" 'd["region"]')" "the previous snapshot stays intact"
halow_state_flush
assert_eq "XX" "$(json_get "$F" 'd["region"]')" "the next flush writes the kept state"

echo "-- init creates nested directories and a traversable run directory --"
(
    umask 077
    export HALOW_RUN_DIR="$HALOW_TEST_TMP/deep/run"
    export HALOW_STATUS_FILE="$HALOW_RUN_DIR/status.json"
    halow_state_init
)
assert_file_exists "$HALOW_TEST_TMP/deep/run/status.json" "init creates HALOW_RUN_DIR"
assert_eq "711" "$(file_mode "$HALOW_TEST_TMP/deep/run")" "run directory traversable by the status user, not listable"
assert_eq "644" "$(file_mode "$HALOW_TEST_TMP/deep/run/status.json")" "snapshot 0644 even under umask 077"

echo "-- re-sourceable and strict-mode safe --"
halow_state_region KEEP
. "$HALOW_STATUS_LIB_DIR/state.sh"
. "$HALOW_STATUS_LIB_DIR/errors.sh"
halow_state_flush
assert_eq "KEEP" "$(json_get "$F" 'd["region"]')" "re-sourcing keeps the state"
assert_success "full sequence under errexit/nounset/pipefail/inherit_errexit, sourced in a function" \
    bash -c 'set -o errexit -o errtrace -o nounset -o pipefail; shopt -s inherit_errexit
             export HALOW_RUN_DIR="$2/strict" HALOW_STATUS_FILE="$2/strict/status.json"
             load() { . "$1/constants.sh"; . "$1/errors.sh"; . "$1/state.sh"; }
             load "$1"
             halow_state_init
             halow_state_region AU
             halow_state_radio_requested automatic 1 ""
             halow_state_adapter true wlan1
             halow_state_radio_effective 923000 42 1 fallback implemented false
             halow_state_advisory RADIO_AUTO_FALLBACK
             halow_state_backend true halow-br0 10.42.0.0/24 10.42.0.1
             halow_state_overall operating
             halow_state_diag_set a b
             halow_state_diag_log_append "x"
             halow_state_radio_clear_effective
             halow_state_attention AP_DIED "d" false
             halow_state_clear_attention
             halow_state_clear_advisory
             halow_state_heartbeat
             if halow_state_overall bogus; then exit 3; fi
             x="$(halow_redact "a")"; y="$(halow_json_escape "b")"
             python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$2/strict/status.json"' _ "$HALOW_STATUS_LIB_DIR" "$HALOW_TEST_TMP"

echo "test_state: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
