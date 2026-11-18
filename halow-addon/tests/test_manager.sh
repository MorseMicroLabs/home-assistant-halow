#!/usr/bin/env bash
# End-to-end runs of halow_manager_main against stubs of every other module (see
# helpers_lifecycle.sh): the start-sequence order, every failure point with its catalogue
# code, rollback of exactly what was recorded, host_clean, the radio flow (automatic
# selection, fallback, manual), retry and backoff, stop handling, the persisted refusal,
# the verify-only forwarding check and the internal-error catch-all.
#
# Each run is a separate bash process with the strict shell options of the add-on base
# image and the service's TERM/INT trap; it ends when the stubbed sleep sends TERM.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_lifecycle.sh

echo "== test_manager =="

# scenario <text> — writes a scenario file sourced by the child after the stubs.
scenario() { printf '%s\n' "$1" > "$HL_DIR/scenario.sh"; printf '%s' "$HL_DIR/scenario.sh"; }

seq_of() {   # the given calls in order, from the first guard check to the first backend attach
    local want=" $* " fn out=""
    while IFS= read -r fn; do
        case "$want" in *" $fn "*) out="$out$fn " ;; esac
    done < <(hl_calls | sed -n '/^halow_guard_check$/,/^fake_backend_attach$/p')
    printf '%s' "${out% }"
}

# stop_rollback_logged — the stop routine's own log line, followed by the rollback's
# completion line, is in the manager's output (reconcile also logs a completed rollback
# at start, so the completion line alone proves nothing about the stop).
stop_rollback_logged() {
    awk '/stop signal received, rolling back/ {s = 1} s && /rollback: complete/ {f = 1} END {exit !f}' "$HL_DIR/out.log"
}
attention_code() { hl_last_attention | cut -d'|' -f2; }
attention_clean() { hl_last_attention | cut -d'|' -f4; }

# ---------------------------------------------------------------------------------------
echo "-- happy path (manual mode): call order, operating, stop rolls back everything --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=35')"
assert_eq "0" "$HL_EXIT" "the manager exits 0 after the stop signal and a confirmed rollback"
ORDER="halow_guard_check halow_verify_manifest halow_adapter_check halow_uplink_detect halow_fw_install_filters halow_load_dot11ah halow_derive_installed_slug halow_place_firmware halow_set_firmware_search_path halow_dmesg_watermark halow_load_morse halow_dmesg_since halow_check_bcf_match halow_restore_firmware_search_path halow_adapter_netdev_wait halow_adapter_netdev halow_verify_parent_iface halow_ipv6_disable halow_nm_mark_unmanaged halow_bridge_create halow_nm_mark_unmanaged_if_known halow_hostapd_pre_start_check halow_radio_render halow_start_hostapd halow_wait_for_pattern halow_bridge_enforce_isolation halow_radio_capture_effective halow_radio_check_effective fake_backend_configure fake_backend_attach"
got="$(seq_of $ORDER | awk '{for(i=1;i<=NF;i++) if(!s[$i]++) printf "%s ", $i}')"
assert_eq "$ORDER" "${got% }" "the start steps run in the documented order (guard, adapter, firewall, driver/firmware, interface, bridge, access point, effective values, backend)"
first_mut="$(hl_calls | grep -n -x -E "$(echo $HL_MUTATING | tr ' ' '|')" | head -n1 | cut -d: -f1)"
last_ro="$(hl_calls | grep -n -x -E 'halow_uplink_detect' | head -n1 | cut -d: -f1)"
assert_eq "1" "$([ "$last_ro" -lt "$first_mut" ] && echo 1 || echo 0)" "no add-on host change (other than the run-directory tmpfs and reconcile of its own residue) happens before the options, guard, checksum and adapter checks have all passed"
assert_success "state reached operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_success "effective radio recorded with source manual, channel 28, implemented" grep -q '^radio_effective|916000|28|1|manual|implemented|none$' "$HL_DIR/state.log"
assert_success "backend recorded applied with the bridge, network and gateway" grep -q '^backend|true|halow-br0|192.168.90.0/24|192.168.90.1$' "$HL_DIR/state.log"
assert_success "the station snapshot is handed to the status snapshot" grep -q '^stations_set|' "$HL_DIR/state.log"
assert_success "the supervise loop processes station events" hl_called halow_st_process_log
assert_success "the supervise loop checks dnsmasq" hl_called halow_dnsmasq_ensure_running
assert_success "the supervise loop checks adapter presence" hl_called halow_adapter_present
assert_success "the supervise loop checks the uplink" hl_called halow_uplink_changed
assert_success "the supervise loop asks the backend for its health" hl_called fake_backend_health
assert_success "the firewall jumps are re-asserted" hl_called halow_fw_reassert
assert_success "the firewall install got the network, gateway, uplink" grep -q '^halow_fw_install_filters halow-br0 192.168.90.0/24 192.168.90.1 end0' "$HL_DIR/calls.log"
assert_success "dot11ah is loaded with the scheme from the radio profile" grep -q '^halow_load_dot11ah .*/dot11ah.ko 2$' "$HL_DIR/calls.log"
assert_success "the backend is configured with every documented key" grep -q '^fake_backend_configure bridge=halow-br0 subnet=192.168.90.1/24 dhcp_start=192.168.90.50 dhcp_end=192.168.90.150 uplink=end0 parent=wlu1 max_stations=101$' "$HL_DIR/calls.log"
assert_success "the backend is attached to the bridge" grep -q '^fake_backend_attach bridge halow-br0$' "$HL_DIR/calls.log"
assert_success "the hostapd config is rendered into the run directory, never the persistent one" grep -q "^halow_radio_render AU manual 1 28 wlu1 HaLow-Test <passphrase> halow-br0 101 $HALOW_RUN_DIR/hostapd_s1g.conf\$" "$HL_DIR/calls.log"
assert_eq "$(hl_marks)" "$(hl_undos)" "the stop rollback undid exactly the markers the start recorded"
assert_eq " " "$(hl_owned) " "no ownership marker remains after the stop"
assert_failure "the passphrase never appears in the manager's output" grep -q 'correct-horse-battery' "$HL_DIR/out.log"
assert_failure "the refusal marker is not set after a clean stop" test -e "$HALOW_STATE_DIR/refusal"
assert_success "the boot id was recorded" test -s "$HALOW_STATE_DIR/boot_id"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- automatic mode, selection completes: source acs; a saved channel is ignored --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="40"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "1" "$(hl_count halow_radio_render)" "the configuration is rendered once"
assert_success "rendered in automatic mode with no channel (the saved 40 is never passed)" grep -q '^halow_radio_render AU automatic 1  wlu1 ' "$HL_DIR/calls.log"
assert_failure "the saved channel 40 reaches no stub call at all" grep -q -w '40' "$HL_DIR/calls.log"
assert_success "requested radio shows automatic with no channel" grep -q '^radio_requested|automatic|1|$' "$HL_DIR/state.log"
assert_success "effective source is acs on the selected channel" grep -q '^radio_effective|917000|30|1|acs|implemented|none$' "$HL_DIR/state.log"
assert_success "the effective check is against the selected channel" grep -q '^halow_radio_check_effective AU 1 30$' "$HL_DIR/calls.log"
assert_failure "no fallback advisory" grep -q '^advisory|RADIO_AUTO_FALLBACK' "$HL_DIR/state.log"
assert_failure "the fallback channel is not even looked up" hl_called halow_radio_fallback_channel
halow_test_teardown

for case_ in "1:failed" "2:timed out" "3:hostapd exited"; do
    rc="${case_%%:*}"; why="${case_#*:}"
    echo "-- automatic mode, selection ${why} (status $rc): fallback started, advisory, never stored as a selection --"
    hl_setup
    export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=6; HL_RC_halow_radio_acs_wait=$rc; HL_EFF_CHANNEL=42")"
    assert_eq "0" "$HL_EXIT" "exit 0 after stop"
    if [ "$rc" = "2" ]; then
        assert_eq "12" "$(hl_count halow_radio_acs_wait)" "the selection is waited for in 10 s slices up to the 120 s timeout"
    else
        assert_eq "1" "$(hl_count halow_radio_acs_wait)" "a definite selection result ends the wait at once"
    fi
    assert_success "hostapd is stopped before the fallback start" grep -q '^halow_stop_hostapd' "$HL_DIR/calls.log"
    assert_eq "halow_radio_render halow_start_hostapd halow_radio_acs_wait halow_radio_fallback_channel halow_stop_hostapd halow_radio_render halow_start_hostapd" "$(seq_of halow_radio_render halow_start_hostapd halow_radio_acs_wait halow_stop_hostapd halow_radio_fallback_channel | awk '{o="";p="";for(i=1;i<=NF;i++){if($i!=p)o=o $i " ";p=$i} print o}' | sed 's/ $//')" "render, start, wait, fallback lookup, stop, render, start"
    assert_success "the second render is the fallback mode on the fallback channel" grep -q '^halow_radio_render AU fallback 1 42 wlu1 ' "$HL_DIR/calls.log"
    assert_success "effective source is fallback (never acs), fallback not live-validated" grep -q '^radio_effective|923000|42|1|fallback|implemented|false$' "$HL_DIR/state.log"
    assert_failure "never reported as an automatic selection" grep -q '^radio_effective|.*|acs|' "$HL_DIR/state.log"
    assert_success "the RADIO_AUTO_FALLBACK advisory is raised" grep -q '^advisory|RADIO_AUTO_FALLBACK$' "$HL_DIR/state.log"
    assert_success "operating (the advisory is not an attention state)" grep -q '^overall|operating$' "$HL_DIR/state.log"
    assert_failure "no attention was raised" grep -q '^attention|' "$HL_DIR/state.log"
    _stored="$(cd "$HALOW_STATE_DIR" && ls -A | tr '\n' ' ')"
    assert_eq "boot_id owns " "$_stored" "nothing but the boot id and the ownership directory is persisted (no selection result)"
    halow_test_teardown
done

# ---------------------------------------------------------------------------------------
echo "-- manual mode never falls back: AP-ENABLED timeout is AP_START_FAILED, bounded to 3 attempts --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_wait_for_pattern=1')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_failure "no selection wait in manual mode" hl_called halow_radio_acs_wait
assert_failure "no fallback lookup in manual mode" hl_called halow_radio_fallback_channel
assert_failure "no fallback render" grep -q '^halow_radio_render AU fallback' "$HL_DIR/calls.log"
assert_eq "3" "$(hl_count halow_start_hostapd)" "exactly 3 consecutive attempts, then the manager stays in attention"
assert_eq "AP_START_FAILED" "$(attention_code)" "attention AP_START_FAILED"
assert_eq "true" "$(attention_clean)" "host_clean true (every attempt was rolled back)"
assert_success "retried with backoff 5 s then 10 s" bash -c "grep -q 'retrying in 5s (AP_START_FAILED' '$HL_DIR/out.log' && grep -q 'retrying in 10s (AP_START_FAILED' '$HL_DIR/out.log'"
assert_eq "3" "$(grep -o "record=[0-9]* trigger=ap_enabled_timeout" "$HL_DIR/state.log" | sort -u | wc -l | tr -d " ")" "each timed-out attempt left one failure record"
assert_eq " " "$(hl_owned) " "no marker remains"
halow_test_teardown

echo "-- a failed hostapd start: the failure record is captured BEFORE the rollback; the retry policy is unchanged --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { if grep -q "^halow_start_hostapd" "$HL_DIR/calls.log"; then grep -c "^diag_set|ap_failure_1|" "$HL_DIR/state.log" >> "$HL_DIR/rec_at_stop"; fi; hl_undo hostapd_process; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "3" "$(hl_count halow_start_hostapd)" "exactly 3 consecutive attempts, as before the failure record existed"
assert_eq "AP_START_FAILED" "$(attention_code)" "attention AP_START_FAILED"
assert_eq "true" "$(attention_clean)" "host_clean true (every attempt was rolled back)"
assert_success "retried with backoff 5 s then 10 s (unchanged)" bash -c "grep -q 'retrying in 5s (AP_START_FAILED' '$HL_DIR/out.log' && grep -q 'retrying in 10s (AP_START_FAILED' '$HL_DIR/out.log'"
assert_success "the record already existed at every rollback that followed a start attempt" bash -c "[ -s \"$HL_DIR/rec_at_stop\" ] && ! grep -qx 0 \"$HL_DIR/rec_at_stop\""
assert_eq "3" "$(grep -c '^diag_set|ap_failure_count|' "$HL_DIR/state.log")" "one record per failed attempt (3), not more"
assert_success "the last count published is 3" bash -c "grep '^diag_set|ap_failure_count|' '$HL_DIR/state.log' | tail -n 1 | grep -q '|3\$'"
assert_success "the record names its trigger and the retry counter" grep -q 'trigger=start_exit' "$HL_DIR/state.log"
assert_success "the first record is written before the first attention" bash -c "[ \"\$(grep -n '^diag_set|ap_failure_1|' '$HL_DIR/state.log' | head -n 1 | cut -d: -f1)\" -lt \"\$(grep -n '^attention|' '$HL_DIR/state.log' | head -n 1 | cut -d: -f1)\" ]"
assert_success "the stop clears the records" grep -q '^diag_unset|ap_failure_1' "$HL_DIR/state.log"
assert_failure "the passphrase is in no state call" grep -q 'correct-horse-battery' "$HL_DIR/state.log"
assert_failure "the passphrase is not in the manager's output" grep -q 'correct-horse-battery' "$HL_DIR/out.log"
halow_test_teardown

echo "-- hostapd dies while operating: the record (trigger and exit) is captured BEFORE the rollback --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_ALIVE_FOR=3; hl_act_halow_stop_hostapd() { grep -c "trigger=died_while_operating" "$HL_DIR/state.log" >> "$HL_DIR/rec_at_stop"; hl_undo hostapd_process; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "AP_DIED" "$(hl_last_attention | cut -d'|' -f2)" "attention AP_DIED"
assert_success "a record with trigger died_while_operating is published" grep -q 'trigger=died_while_operating' "$HL_DIR/state.log"
assert_success "it carries the hostapd exit line" grep -q '^hostapd_exit=' "$HL_DIR/state.log"
assert_success "the record already existed at the rollback that followed the death (the last stop of hostapd)" bash -c "[ \"\$(tail -n 1 \"$HL_DIR/rec_at_stop\")\" -ge 1 ]"
halow_test_teardown

echo "-- selection ends because hostapd exited and there is no fallback channel: the exit is recorded --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_radio_acs_wait=3; HL_RC_halow_radio_fallback_channel=1')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "AP_START_FAILED" "$(attention_code)" "attention AP_START_FAILED (no fallback channel)"
assert_success "the record names the trigger acs_hostapd_exited" grep -q 'trigger=acs_hostapd_exited' "$HL_DIR/state.log"
halow_test_teardown

echo "-- selection ends because hostapd exited, a fallback exists and its start fails: one record per failed attempt --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_radio_acs_wait=3; HL_RCSEQ_halow_start_hostapd="0 1"')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_failure "no separate record for the selection exit (the fallback start's record covers the attempt)" grep -q 'trigger=acs_hostapd_exited' "$HL_DIR/state.log"
assert_eq "3" "$(grep -c '^diag_set|ap_failure_count|' "$HL_DIR/state.log")" "three attempts, three records"
assert_success "the first record is the failed fallback start" bash -c "grep -m1 -o 'trigger=[a-z_]*' '$HL_DIR/state.log' | grep -qx 'trigger=start_exit'"
halow_test_teardown

echo "-- a failure INSIDE the capture changes neither the retries, the backoff, the codes nor the cleanup --"
for sab in \
    'halow_state_diag_set() { case "$1" in ap_failure*) return 1 ;; esac; hl_state_stub halow_state_diag_set "$@"; }' \
    'HALOW_FREC_DMESG_CMD=/nonexistent/dmesg; HALOW_FREC_IP_CMD=/nonexistent/ip; HALOW_TIMEOUT_CMD=/nonexistent/timeout; HALOW_FREC_MAX_BYTES=abc; HALOW_FREC_LINES=x' \
    'halow_failure_record_capture() { return 7; }' \
    '_halow_frec_build() { false; }' ; do
    hl_setup
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }; $sab")"
    assert_eq "0" "$HL_EXIT" "[$sab] exit 0 after stop"
    assert_eq "3" "$(hl_count halow_start_hostapd)" "[$sab] exactly 3 attempts"
    assert_eq "AP_START_FAILED" "$(attention_code)" "[$sab] attention AP_START_FAILED"
    assert_eq "true" "$(attention_clean)" "[$sab] host_clean true"
    assert_success "[$sab] backoff 5 s then 10 s" bash -c "grep -q 'retrying in 5s (AP_START_FAILED' '$HL_DIR/out.log' && grep -q 'retrying in 10s (AP_START_FAILED' '$HL_DIR/out.log'"
    assert_eq " " "$(hl_owned) " "[$sab] no marker remains"
    halow_test_teardown
done

echo "-- the success path calls no failure-record helper --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=35; halow_failure_record_capture() { echo "$*" >> "$HL_DIR/capture_called"; }; _halow_mgr_failure_record() { echo "$*" >> "$HL_DIR/capture_called"; }; _halow_frec_build() { echo build >> "$HL_DIR/capture_called"; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_success "state reached operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_failure "no capture helper was called" test -e "$HL_DIR/capture_called"
halow_test_teardown

echo "-- manual 8 MHz with channel 41 (valid for 2 MHz, not for 8 MHz): refused at start, nothing rendered or started --"
hl_setup
export HALOW_OPT_BANDWIDTH="8" HALOW_OPT_CHANNEL="41"
hl_run_manager "$(scenario '. "$HALOW_LIB_DIR/radio.sh"; HL_SLEEP_LIMIT=5')"
assert_eq "0" "$HL_EXIT" "the manager stayed up until the stop signal and then exited 0"
assert_eq "CONFIG_INVALID" "$(attention_code)" "attention CONFIG_INVALID"
assert_success "the detail names the channel option" grep -q '^attention|CONFIG_INVALID|option channel:' "$HL_DIR/state.log"
assert_failure "nothing is rendered" hl_called halow_radio_render
assert_failure "nothing is started" hl_called halow_start_hostapd
assert_success "no host change at all" hl_no_mutation
assert_failure "a configuration error is never retried" grep -q 'retrying in' "$HL_DIR/out.log"
halow_test_teardown

echo "-- a normal start records no failure and keeps the derived primary values in diagnostics only --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=35; halow_radio_primary_info() { HALOW_PRIM_OP_CLASS=50; HALOW_PRIM_CHANNEL=$3; HALOW_PRIM_WIDTH_MHZ=$2; HALOW_PRIM_CENTRE_KHZ=916000; HALOW_PRIM_BW_MHZ=1; HALOW_PRIM_INDEX=0; HALOW_PRIM_1MHZ_CHANNEL=28; HALOW_PRIM_1MHZ_KHZ=916000; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_failure "no failure record is published" grep -q '^diag_set|ap_failure_' "$HL_DIR/state.log"
assert_failure "nothing about the primary channel is recorded in the status snapshot" grep -q '^radio_primary|' "$HL_DIR/state.log"
assert_success "the derived values are in the diagnostics, labelled configured/derived and not read from the radio" grep -q '^diag_set|radio_primary_derived|configured/derived from the profile table, NOT read from the radio: op_class=50 channel=28 width_mhz=1 centre_khz=916000 primary_bandwidth_mhz=1 primary_index=0 primary_1mhz_channel=28 primary_1mhz_khz=916000$' "$HL_DIR/state.log"
halow_test_teardown

echo "-- an invalid manual channel is a configuration error: nothing starts, no retry, the container stays up --"
hl_setup
export HALOW_OPT_CHANNEL="99"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=8')"
assert_eq "0" "$HL_EXIT" "the manager stayed up until the stop signal and then exited 0"
assert_eq "CONFIG_INVALID" "$(attention_code)" "attention CONFIG_INVALID"
assert_success "the detail names the channel option" grep -q '^attention|CONFIG_INVALID|option channel: channel 99' "$HL_DIR/state.log"
assert_success "no host change at all" hl_no_mutation
assert_failure "the guard is never reached" hl_called halow_guard_check
assert_eq "8" "$(wc -l < "$HL_DIR/sleeps.log" | tr -d ' ')" "it waited (heartbeat loop) until the stop signal"
assert_success "the heartbeat kept the snapshot fresh while waiting" grep -q '^heartbeat$' "$HL_DIR/state.log"
assert_failure "a configuration error is never retried" grep -q 'retrying in' "$HL_DIR/out.log"
halow_test_teardown

echo "-- manual mode without a channel is a configuration error --"
hl_setup
export HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=3')"
assert_eq "CONFIG_INVALID" "$(attention_code)" "attention CONFIG_INVALID"
assert_success "the detail names the channel option" grep -q '^attention|CONFIG_INVALID|option channel:' "$HL_DIR/state.log"
assert_success "no host change" hl_no_mutation
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- read-only failures change nothing: region, guard, checksums, adapter, uplink, ip_forward --"
for c in \
    "REGION_UNVALIDATED|HL_RC_halow_radio_profile_exists=1" \
    "UNSUPPORTED_KERNEL|HL_RC_halow_guard_check=1" \
    "UNSUPPORTED_KERNEL|HL_RC_halow_guard_check=2" \
    "FIRMWARE_INVALID|HL_RC_halow_verify_manifest=1" \
    "NO_ADAPTER|HL_RC_halow_adapter_check=2" \
    "MULTIPLE_ADAPTERS|HL_RC_halow_adapter_check=3" \
    "NO_ADAPTER|HL_RC_halow_adapter_check=4" \
    "UPLINK_UNAVAILABLE|HL_RC_halow_uplink_detect=1" \
    "HOST_STATE_FAILED|printf '0\\n' > \"\$HALOW_IP_FORWARD_FILE\"" \
    "INTERNAL_ERROR|HL_RC_halow_adapter_check=7" ; do
    code="${c%%|*}"; setup="${c#*|}"
    hl_setup
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=4; $setup")"
    assert_eq "$code" "$(attention_code)" "[$setup] raises $code"
    assert_success "[$setup] no host change before the read-only checks pass" hl_no_mutation
    assert_eq "true" "$(attention_clean)" "[$setup] host_clean true"
    assert_eq "0" "$HL_EXIT" "[$setup] the manager stays up and exits 0 on stop"
    halow_test_teardown
done

echo "-- the real compatibility guard: a different host-module file with release, build string, banner and vermagic matching is UNSUPPORTED_KERNEL, nothing changed --"
. ./helpers_adapter.sh
for variant in official one-byte-different; do
    hl_setup
    hat_guard_world "$HALOW_TEST_TMP/gw" "$HALOW_ARTIFACTS_DIR"
    if [ "$variant" != "official" ]; then sed -i 's/official/officiaL/' "$HAT_GW_TREE/kernel/net/mac80211/mac80211.ko"; fi
    : > "$HL_DIR/gw_cmds.log"
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=4; export HAT_CALLS='$HL_DIR/gw_cmds.log'; PATH='$HAT_GW_BIN':\"\$PATH\"; . '$HALOW_LIB_DIR/guard.sh'")"
    assert_failure "[$variant] the real guard ran (not the stub)" hl_called halow_guard_check
    assert_success "[$variant] the real guard read the module tree" grep -q '^modinfo -b ' "$HL_DIR/gw_cmds.log"
    if [ "$variant" = "official" ]; then
        assert_success "[official] the guard passes and the start continues to the artifact checksums" hl_called halow_verify_manifest
        assert_failure "[official] no UNSUPPORTED_KERNEL" grep -q '^attention|UNSUPPORTED_KERNEL' "$HL_DIR/state.log"
    else
        assert_eq "UNSUPPORTED_KERNEL" "$(attention_code)" "[$variant] raises UNSUPPORTED_KERNEL"
        assert_success "[$variant] the detail names the module hash" grep -q '^attention|UNSUPPORTED_KERNEL|host module mac80211 SHA-256 ' "$HL_DIR/state.log"
        assert_eq "true" "$(attention_clean)" "[$variant] host_clean true"
        assert_success "[$variant] no host change (module load, firmware, firewall, bridge, hostapd, backend)" hl_no_mutation
        assert_failure "[$variant] the start stopped at the guard (no checksum or adapter step)" hl_called halow_verify_manifest
        assert_eq "0" "$HL_EXIT" "[$variant] the manager stays up and exits 0 on stop"
    fi
    halow_test_teardown
done

echo "-- ip_forward 0 is verified, never written --"
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=3; printf '0\\n' > \"\$HALOW_IP_FORWARD_FILE\"")"
assert_eq "0" "$(tr -d '[:space:]' < "$HALOW_IP_FORWARD_FILE")" "the forwarding flag is left at 0 (never written or restored)"
assert_success "the detail explains the forwarding flag" grep -q '^attention|HOST_STATE_FAILED|net.ipv4.ip_forward is 0' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- every failure point after the first host change: right code, exact rollback, host_clean true --"
for c in \
    "BACKEND_FAILED|halow_fw_install_filters" \
    "MODULE_LOAD_FAILED|halow_load_dot11ah" \
    "FIRMWARE_INVALID|halow_place_firmware" \
    "HOST_STATE_FAILED|halow_set_firmware_search_path" \
    "HOST_STATE_FAILED|halow_dmesg_watermark" \
    "MODULE_LOAD_FAILED|halow_load_morse" \
    "HOST_STATE_FAILED|halow_dmesg_since" \
    "FIRMWARE_INVALID|halow_check_bcf_match" \
    "MODULE_LOAD_FAILED|halow_adapter_netdev_wait" \
    "MODULE_LOAD_FAILED|halow_verify_parent_iface" \
    "NM_CHECK_FAILED|halow_nm_mark_unmanaged" \
    "BACKEND_FAILED|halow_bridge_create" \
    "NM_CHECK_FAILED|halow_nm_mark_unmanaged_if_known" \
    "AP_START_FAILED|halow_hostapd_pre_start_check" \
    "AP_START_FAILED|halow_radio_render" \
    "AP_START_FAILED|halow_start_hostapd" \
\
    "RADIO_MISMATCH|halow_radio_check_effective" \
    "BACKEND_FAILED|fake_backend_configure" \
    "BACKEND_FAILED|fake_backend_attach" ; do
    code="${c%%|*}"; fn="${c#*|}"
    hl_setup
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=40; HL_RC_$fn=1")"
    assert_eq "$code" "$(attention_code)" "$fn failing raises $code"
    assert_eq "true" "$(attention_clean)" "$fn: host_clean true"
    assert_eq "$(hl_marks)" "$(hl_undos)" "$fn: rollback undid exactly what was recorded ($(hl_marks))"
    assert_eq " " "$(hl_owned) " "$fn: no marker remains"
    assert_failure "$fn: never operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
    halow_test_teardown
done

echo "-- a region profile that gives no channelisation scheme is refused before the module load, never defaulted: REGION_UNVALIDATED, exact rollback --"
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=40; HL_SCHEME=")"
assert_eq "REGION_UNVALIDATED" "$(attention_code)" "an empty scheme raises REGION_UNVALIDATED"
assert_eq "0" "$(hl_count halow_load_dot11ah)" "the dot11ah module is never loaded without a scheme"
assert_eq "true" "$(attention_clean)" "empty scheme: host_clean true"
assert_eq "$(hl_marks)" "$(hl_undos)" "empty scheme: rollback undid exactly what was recorded ($(hl_marks))"
assert_eq " " "$(hl_owned) " "empty scheme: no marker remains"
halow_test_teardown

echo "-- a rollback that cannot be confirmed: ROLLBACK_INCOMPLETE, host_clean false, refusal persisted --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=10; HL_RC_halow_check_bcf_match=1; HL_UNDO_FAIL="module_morse"')"
assert_eq "ROLLBACK_INCOMPLETE" "$(attention_code)" "ROLLBACK_INCOMPLETE raised"
assert_success "the original error is kept in the detail with the residue" grep -q '^attention|ROLLBACK_INCOMPLETE|after FIRMWARE_INVALID .*still present: module_morse' "$HL_DIR/state.log"
assert_success "host_clean false" grep -q '^attention|ROLLBACK_INCOMPLETE|.*|false$' "$HL_DIR/state.log"
_first_att="$(grep '^attention|' "$HL_DIR/state_before_term.log" | head -n 1)"
assert_success "the FIRST attention record (written before any stop signal) is ROLLBACK_INCOMPLETE with host_clean false [$_first_att]" grep -q '^attention|ROLLBACK_INCOMPLETE|after FIRMWARE_INVALID .*|false$' <<< "$_first_att"
assert_success "the refusal marker was persisted before the stop signal (not by the stop)" test -e "$HL_DIR/refusal_before_term"
assert_success "the refusal marker is persisted" test -e "$HALOW_STATE_DIR/refusal"
assert_eq "1" "$(hl_count halow_load_dot11ah)" "no new start attempt over the unknown state"
assert_eq "1" "$HL_EXIT" "the stop exits non-zero (the rollback at stop could not be confirmed either)"
halow_test_teardown

echo "-- the persisted refusal: a new start retries only the rollback --"
hl_setup
halow_own_mark module_morse
printf 'ROLLBACK_INCOMPLETE\n0\n' > "$HALOW_STATE_DIR/refusal"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=30; HL_UNDO_FAIL="module_morse"')"
assert_eq "ROLLBACK_INCOMPLETE" "$(attention_code)" "attention ROLLBACK_INCOMPLETE"
assert_success "no host change while the refusal is present" hl_no_mutation
assert_failure "the options are not even acted on (no guard call)" hl_called halow_guard_check
assert_success "the refusal marker stays" test -e "$HALOW_STATE_DIR/refusal"
assert_success "rollback is retried (more than one unload attempt)" test "$(hl_count halow_unload_modules)" -ge 2
halow_test_teardown

echo "-- the refusal clears once rollback is confirmed, then a normal start follows --"
hl_setup
halow_own_mark module_morse
printf 'ROLLBACK_INCOMPLETE\n0\n' > "$HALOW_STATE_DIR/refusal"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=8')"
assert_failure "the refusal marker is cleared" test -e "$HALOW_STATE_DIR/refusal"
assert_success "the residual module marker was undone" grep -q '^UNDO module_morse$' "$HL_DIR/calls.log"
assert_success "the start then proceeded to operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- NO_ADAPTER is retried forever with backoff 5, 10, 20 s; each retry is a full start --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=30; HL_RCSEQ_halow_adapter_check="2 2 2 0"')"
assert_success "retry 1 after 5 s" grep -q 'retrying in 5s (NO_ADAPTER, attempt 1)' "$HL_DIR/out.log"
assert_success "retry 2 after 10 s" grep -q 'retrying in 10s (NO_ADAPTER, attempt 2)' "$HL_DIR/out.log"
assert_success "retry 3 after 20 s" grep -q 'retrying in 20s (NO_ADAPTER, attempt 3)' "$HL_DIR/out.log"
assert_eq "4" "$(hl_count halow_guard_check)" "every retry is a full start (guard checked 4 times)"
assert_success "the fourth attempt reached operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_eq "35" "$(awk '{s+=$1} END {print s}' <(head -n 7 "$HL_DIR/sleeps.log"))" "the waits before the fourth attempt add up to 5+10+20 s"
halow_test_teardown

echo "-- AP_DIED while operating: rolled back, retried at most 3 consecutive times --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=80; HL_ALIVE_FOR=2')"
assert_eq "AP_DIED" "$(attention_code)" "attention AP_DIED"
assert_eq "3" "$(hl_count halow_start_hostapd)" "three consecutive attempts, then attention"
assert_eq "true" "$(attention_clean)" "host_clean true"
halow_test_teardown

echo "-- adapter unplugged while operating: NO_ADAPTER, rolled back, retried --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=12; HL_RCSEQ_halow_adapter_present="0 1 0"')"
assert_success "NO_ADAPTER raised while operating" grep -q '^attention|NO_ADAPTER|the adapter was disconnected|true$' "$HL_DIR/state.log"
assert_success "retried after 5 s" grep -q 'retrying in 5s (NO_ADAPTER' "$HL_DIR/out.log"
assert_eq "2" "$(hl_count halow_load_dot11ah)" "a full second start"
halow_test_teardown

echo "-- uplink lost while operating: UPLINK_UNAVAILABLE --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=12; HL_RCSEQ_halow_uplink_changed="1 0 1"')"
assert_success "UPLINK_UNAVAILABLE raised" grep -q '^attention|UPLINK_UNAVAILABLE|' "$HL_DIR/state.log"
halow_test_teardown

echo "-- dnsmasq that cannot be kept running: BACKEND_FAILED, not retried --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=10; HL_RCSEQ_halow_dnsmasq_ensure_running="0 1"')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "BACKEND_FAILED"
assert_eq "1" "$(hl_count halow_load_dot11ah)" "not retried"
halow_test_teardown

echo "-- a station fault is BACKEND_FAILED --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; hl_act_halow_st_process_log() { HALOW_ST_FAULT=1; HALOW_ST_FAULT_MSG="station_added failed"; }')"
assert_success "BACKEND_FAILED with the station message" grep -q '^attention|BACKEND_FAILED|a station could not be served: station_added failed|true$' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- stop signal during a host change is deferred until the step has finished --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=100; HL_TERM_IN_MORSE=1')"
assert_eq "0" "$HL_EXIT" "exit 0 (rollback confirmed)"
assert_success "the deferral was logged" grep -q 'stop requested; finishing the current step (driver) first' "$HL_DIR/out.log"
assert_success "the module loaded in that step was recorded" grep -q '^MARK module_morse$' "$HL_DIR/calls.log"
assert_success "...and rolled back" grep -q '^UNDO module_morse$' "$HL_DIR/calls.log"
assert_failure "no later step ran" hl_called halow_adapter_netdev_wait
assert_eq " " "$(hl_owned) " "no marker remains"
halow_test_teardown

echo "-- stop signal while operating --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4')"
assert_eq "0" "$HL_EXIT" "exit 0"
assert_success "the stop rollback ran (hostapd stopped)" grep -q '^UNDO hostapd_process$' "$HL_DIR/calls.log"
assert_success "the effective radio values were cleared" grep -q '^radio_clear_effective$' "$HL_DIR/state.log"
halow_test_teardown

echo "-- stop with a rollback that cannot be confirmed exits non-zero and persists the refusal --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4; HL_UNDO_FAIL="net_bridge"')"
assert_eq "1" "$HL_EXIT" "exit 1"
assert_success "refusal persisted" test -e "$HALOW_STATE_DIR/refusal"
assert_success "attention ROLLBACK_INCOMPLETE host_clean false" grep -q '^attention|ROLLBACK_INCOMPLETE|the rollback at stop could not be confirmed; still present: net_bridge|false$' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- INTERNAL_ERROR: a missing function is caught before anything is done --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=3; unset -f halow_guard_report')"
assert_eq "INTERNAL_ERROR" "$(attention_code)" "INTERNAL_ERROR"
assert_success "the detail names the missing function" grep -q '^attention|INTERNAL_ERROR|this build is missing required functions: halow_guard_report|true$' "$HL_DIR/state.log"
assert_success "no host change" hl_no_mutation
assert_eq "0" "$HL_EXIT" "the manager stays up and exits 0 on stop"
halow_test_teardown

echo "-- INTERNAL_ERROR: a step failing without a reason --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=3; _halow_mgr_step_guard() { return 5; }')"
assert_eq "INTERNAL_ERROR" "$(attention_code)" "INTERNAL_ERROR"
assert_success "detail names the step" grep -q 'the start step guard failed unexpectedly (status 5)' "$HL_DIR/state.log"
halow_test_teardown

echo "-- INTERNAL_ERROR: an unknown code from a step is converted --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=3; _halow_mgr_step_guard() { _halow_mgr_fail BOGUS_CODE "x"; }')"
assert_eq "INTERNAL_ERROR" "$(attention_code)" "an unknown code becomes INTERNAL_ERROR"
halow_test_teardown

echo "-- the installed-slug guard refuses a foreign hostname (carried behaviour) --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4; HL_SLUG=homeassistant')"
assert_eq "HOST_STATE_FAILED" "$(attention_code)" "HOST_STATE_FAILED"
assert_failure "the firmware search path is never set" hl_called halow_set_firmware_search_path
halow_test_teardown

# =======================================================================================
echo "-- the stop handler only records the request: a stop that arrives inside a blocked 'IFS= read' still rolls back with the default field separator --"
READ_TERM='hl_act_halow_st_process_log() {
    [ -e "$HL_DIR/read_term_done" ] && return 0
    : > "$HL_DIR/read_term_done"
    local l
    while IFS= read -r l; do :; done < <(sleep 0.3; kill -TERM $$; sleep 0.7; echo x)
    echo READ_LOOP_FINISHED >> "$HL_DIR/calls.log"
    return 0
}'
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=1000; HL_UNDO_FAIL=net_bridge
$READ_TERM")"
assert_success "sanity: the signal was sent while the read loop was blocked" test -e "$HL_DIR/read_term_done"
assert_eq "1" "$HL_EXIT" "the stop exits 1: the bridge marker that could not be undone is detected (a rollback run inside the handler with IFS='' reported clean)"
assert_success "ROLLBACK_INCOMPLETE names the residue" grep -q '^attention|ROLLBACK_INCOMPLETE|the rollback at stop could not be confirmed; still present: net_bridge|false$' "$HL_DIR/state.log"
assert_success "the refusal is persisted" test -e "$HALOW_STATE_DIR/refusal"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=1000
$READ_TERM")"
assert_eq "0" "$HL_EXIT" "without residue the same stop exits 0"
assert_success "the handler did not act: the interrupted read loop finished before the stop was carried out" grep -q -x READ_LOOP_FINISHED "$HL_DIR/calls.log"
assert_eq "$(hl_marks)" "$(hl_undos)" "the stop rollback undid exactly the recorded markers"
assert_eq " " "$(hl_owned) " "no marker remains (intent and IPv6 records included)"
assert_success "the rollback ran after the handler returned (logged)" stop_rollback_logged
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- the run directory: a tmpfs is mounted first, then the ready file; nothing starts without it --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4')"
assert_eq "mount -t tmpfs -o mode=0755,size=32m,nosuid,nodev,noexec tmpfs $HALOW_RUN_DIR" "$(head -n 1 "$HL_DIR/calls.log")" "the first call of the manager is the tmpfs mount on the run directory"
assert_success "the ready file exists" test -e "$HALOW_RUN_DIR/.ready"
assert_success "...and the run reached operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
halow_test_teardown

hl_setup
printf 'tmpfs %s tmpfs rw 0 0\n' "$HALOW_RUN_DIR" >> "$HALOW_PROC_MOUNTS"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4')"
assert_failure "a run directory that already is a tmpfs is not mounted again" hl_called mount
assert_success "operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
halow_test_teardown

for c in "HL_MOUNT_FAILS=1|could not be mounted" "mount() { hl_log_call mount \"\$@\"; }|could not be confirmed memory-backed" "HALOW_PROC_MOUNTS=/nonexistent/mounts|mount table cannot be read"; do
    setup="${c%%|*}"; want="${c#*|}"
    hl_setup
    hl_run_manager "$(scenario "HL_SLEEP_LIMIT=4; $setup
halow_state_attention() { [ -e \"\$HALOW_RUN_DIR/.ready\" ] && r=yes || r=no; echo \"READY_AT_ATTENTION=\$r\" >> \"\$HL_DIR/state.log\"; hl_state_stub halow_state_attention \"\$@\"; }")"
    assert_eq "HOST_STATE_FAILED" "$(attention_code)" "[$setup] HOST_STATE_FAILED"
    assert_success "[$setup] the detail says why ($want)" grep -q "^attention|HOST_STATE_FAILED|.*$want" "$HL_DIR/state.log"
    assert_success "[$setup] no host change and nothing rendered" hl_no_mutation
    assert_failure "[$setup] not even reconcile runs (before the stop)" grep -q "^halow_unload_modules" "$HL_DIR/calls_before_term.log"
    assert_success "[$setup] the ready file is still created so the page can explain" test -e "$HALOW_RUN_DIR/.ready"
    assert_success "[$setup] the attention snapshot was written BEFORE the ready file existed" grep -q '^READY_AT_ATTENTION=no$' "$HL_DIR/state.log"
    assert_eq "" "$(find "$HALOW_TEST_TMP" -name 'hostapd_s1g.conf' -o -name '*.conf.tmp*' | tr '\n' ' ')" "[$setup] no access-point configuration file exists anywhere"
    assert_failure "[$setup] the renderer was never called" hl_called halow_radio_render
    assert_eq "0" "$HL_EXIT" "[$setup] the manager stays up and exits 0 on stop"
    halow_test_teardown
done

# ---------------------------------------------------------------------------------------
echo "-- the process-list preflight fails closed before reconcile --"
hl_setup
mkdir -p "$HL_DIR/emptyproc"
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=4; HALOW_PROC_DIR=$HL_DIR/emptyproc")"
assert_eq "HOST_STATE_FAILED" "$(attention_code)" "an unreadable process list is HOST_STATE_FAILED"
assert_success "the detail names the process list" grep -q '^attention|HOST_STATE_FAILED|the process list under .* cannot be read' "$HL_DIR/state.log"
assert_eq "true" "$(attention_clean)" "host_clean true (nothing recorded, nothing changed)"
assert_success "no host change" hl_no_mutation
assert_failure "reconcile (and its process scans) never ran before the stop" grep -q "^halow_unload_modules" "$HL_DIR/calls_before_term.log"
assert_failure "never retried" grep -q 'retrying in' "$HL_DIR/out.log"
halow_test_teardown

hl_setup
mkdir -p "$HL_DIR/emptyproc"
halow_own_mark module_morse
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=3; HALOW_PROC_DIR=$HL_DIR/emptyproc")"
assert_success "with a marker from an earlier run host_clean is false (no rollback was trusted)" grep -q '^attention|HOST_STATE_FAILED|.*|false$' "$HL_DIR/state_before_term.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- the firewall gets the catch-all for the parent interface; IPv6 off on the parent and the bridge --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4')"
assert_success "step 6 installs the chains before the interface is known (no parent argument)" grep -q -x 'halow_fw_install_filters halow-br0 192.168.90.0/24 192.168.90.1 end0 ' "$HL_DIR/calls.log"
assert_success "once the interface is known the parent is passed as the 6th argument" grep -q -x 'halow_fw_install_filters halow-br0 192.168.90.0/24 192.168.90.1 end0  wlu1' "$HL_DIR/calls.log"
_trace="$(grep -v -E '^(MARK|UNDO) ' "$HL_DIR/calls.log" | sed -n '/^halow_verify_parent_iface/,/^halow_hostapd_pre_start_check/p' | awk '{print $1, $NF}' | tr '\n' ';')"
assert_eq "halow_verify_parent_iface $HALOW_SYS_CLASS_NET_DIR;halow_fw_install_filters wlu1;halow_ipv6_disable wlu1;halow_nm_mark_unmanaged nm_unmanaged_parent;halow_bridge_create halow-br0;halow_ipv6_disable halow-br0;halow_nm_mark_unmanaged_if_known nm_unmanaged_bridge;halow_hostapd_pre_start_check $HALOW_RUN_DIR/hostapd_s1g.conf;" "$_trace" "interface check, catch-all, IPv6 off, NetworkManager; bridge, IPv6 off, NetworkManager; then hostapd"
assert_success "the IPv6 settings are restored by the stop rollback" grep -q '^UNDO ipv6_wlu1$' "$HL_DIR/calls.log"
assert_success "...for the bridge too" grep -q '^UNDO ipv6_halow-br0$' "$HL_DIR/calls.log"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4; HL_RC_halow_ipv6_disable=1')"
assert_success "IPv6 not disabled but the IPv6 chains verified: operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_success "...and the fact is recorded in diagnostics, prominently (held by the filter chains only)" grep -q '^diag_set|ipv6_wlu1|IPv6 is NOT off on the interface (its kernel switch could not be written); held by the IPv6 filter chains only$' "$HL_DIR/state.log"
assert_success "the chains were checked for the bridge" grep -q -x 'halow_fw_ipv6_governed halow-br0' "$HL_DIR/calls.log"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_halow_ipv6_disable=1; HL_RC_halow_fw_ipv6_governed=1')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "neither IPv6 control verified: BACKEND_FAILED"
assert_success "the detail names IPv6 and the interface" grep -q '^attention|BACKEND_FAILED|IPv6 could not be disabled on wlu1 and the IPv6 filter chains could not be verified|true$' "$HL_DIR/state.log"
assert_eq "$(hl_marks)" "$(hl_undos)" "rolled back exactly what was recorded"
assert_failure "hostapd never started" hl_called halow_start_hostapd
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_halow_ipv6_disable=2')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "a temporary writable mount not confirmed removed (rc 2): BACKEND_FAILED"
assert_success "the detail names the unconfirmed temporary writable mount" grep -q '^attention|BACKEND_FAILED|IPv6 could not be disabled on wlu1 and a temporary writable mount on its switch could not be confirmed removed|true$' "$HL_DIR/state.log"
assert_failure "the IPv6 filter chains were NOT consulted (no firewall-only fallback for rc 2)" grep -q -x 'halow_fw_ipv6_governed halow-br0' "$HL_DIR/calls.log"
assert_failure "the access point never started" hl_called halow_start_hostapd
assert_failure "the state never became operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RCSEQ_halow_fw_install_filters="0 1"')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "the catch-all install failing is BACKEND_FAILED"
assert_success "...naming the interface" grep -q '^attention|BACKEND_FAILED|the firewall catch-all for wlu1 could not be installed|true$' "$HL_DIR/state.log"
assert_failure "the parent is never handed to NetworkManager or hostapd" hl_called halow_nm_mark_unmanaged
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- client isolation: enforced right after AP-ENABLED and on every supervision tick; failure is fail-closed --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6')"
_iso_after="$(grep -v -E '^(MARK|UNDO) ' "$HL_DIR/calls.log" | awk '{print $1}' | sed -n '/^halow_wait_for_pattern$/,$p' | sed -n 2p)"
assert_eq "halow_bridge_enforce_isolation" "$_iso_after" "isolation is enforced right after AP-ENABLED, before anything else"
assert_success "on the bridge" grep -q -x 'halow_bridge_enforce_isolation halow-br0' "$HL_DIR/calls.log"
assert_success "and on every tick (at least once per supervision sleep)" test "$(hl_count halow_bridge_enforce_isolation)" -ge 6
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_halow_bridge_enforce_isolation=1')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "isolation that cannot be enforced after AP-ENABLED: BACKEND_FAILED"
assert_failure "never operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_eq "$(hl_marks)" "$(hl_undos)" "rolled back exactly what was recorded"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RCSEQ_halow_bridge_enforce_isolation="0 0 0 1"')"
assert_success "isolation failing while operating: BACKEND_FAILED" grep -q '^attention|BACKEND_FAILED|client isolation could not be enforced on every port of halow-br0|true$' "$HL_DIR/state.log"
assert_success "after operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_eq "1" "$(hl_count halow_load_dot11ah)" "not retried"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- supervision failure paths --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=40; HL_RC_halow_fw_reassert=1; HALOW_MGR_REASSERT_EVERY=3')"
assert_success "a firewall that cannot be re-asserted fails closed: BACKEND_FAILED" grep -q '^attention|BACKEND_FAILED|the firewall chains are not in force (a chain is missing or a jump could not be restored)|true$' "$HL_DIR/state.log"
assert_eq "1" "$(hl_count halow_fw_reassert)" "at the first re-assertion"
assert_eq "$(hl_marks)" "$(hl_undos)" "rolled back"
assert_eq "1" "$(hl_count halow_load_dot11ah)" "not retried"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=40; HL_RC_fake_backend_health=1; HALOW_MGR_HEALTH_EVERY=3')"
assert_success "backend health failing: BACKEND_FAILED" grep -q '^attention|BACKEND_FAILED|the bridge backend reported a problem|true$' "$HL_DIR/state.log"
assert_eq "1" "$(hl_count fake_backend_health)" "at the first health check"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=12; HL_RCSEQ_halow_adapter_check="0 0 3 0"')"
assert_success "a second adapter while operating: MULTIPLE_ADAPTERS, rolled back" grep -q '^attention|MULTIPLE_ADAPTERS|a second adapter was connected|true$' "$HL_DIR/state.log"
assert_success "recoverable: retried" grep -q 'retrying in 5s (MULTIPLE_ADAPTERS' "$HL_DIR/out.log"
halow_test_teardown

echo "-- a stable run resets the consecutive access-point failure count --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=80; HALOW_MGR_STABLE_S=5
halow_manager_pid_alive() { hl_stub alive_seq; }
HL_RCSEQ_alive_seq="1 1 0 0 0 0 0 0 0 1"')"
assert_eq "5" "$(hl_count halow_start_hostapd)" "two failures, a stable run (count reset), then three more failures: 5 starts"
assert_success "the reset is logged" grep -q 'the access-point failure count is reset' "$HL_DIR/out.log"
assert_eq "AP_DIED" "$(attention_code)" "then attention AP_DIED"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=80; HALOW_MGR_STABLE_S=50
halow_manager_pid_alive() { hl_stub alive_seq; }
HL_RCSEQ_alive_seq="1 1 0 0 0 0 0 0 0 1"')"
assert_eq "3" "$(hl_count halow_start_hostapd)" "control: the same run shorter than the stable time is not reset: 3 starts"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- NetworkManager failures reported by the backend are NM_CHECK_FAILED --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_fake_backend_attach=1; hl_act_fake_backend_attach() { HALOW_BACKEND_FAIL_KIND=nm; }')"
assert_eq "NM_CHECK_FAILED" "$(attention_code)" "attach failing with kind nm: NM_CHECK_FAILED"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_fake_backend_attach=1; hl_act_fake_backend_attach() { HALOW_BACKEND_FAIL_KIND=other; }')"
assert_eq "BACKEND_FAILED" "$(attention_code)" "attach failing with kind other: BACKEND_FAILED"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; hl_act_halow_st_process_log() { HALOW_ST_FAULT=1; HALOW_ST_FAULT_MSG="per-station interface unmanaged check failed"; HALOW_ST_FAULT_KIND=nm; }')"
assert_success "a station fault of kind nm: NM_CHECK_FAILED with the station message" grep -q '^attention|NM_CHECK_FAILED|a station could not be served: per-station interface unmanaged check failed (NetworkManager' "$HL_DIR/state.log"
halow_test_teardown
hl_setup
# One pass: a station operation fails with kind nm (the station lifecycle keeps the first
# fault's kind), then a later backend operation in the same pass succeeds and clears the
# per-operation kind. The manager must still report the NetworkManager failure.
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6
hl_act_halow_st_process_log() {
    HALOW_BACKEND_FAIL_KIND=nm; HALOW_ST_FAULT=1; HALOW_ST_FAULT_KIND=nm; HALOW_ST_FAULT_MSG="station_added wlu1.sta1 failed"
    halow_backend_call station_added wlu1.sta2 02:00:00:00:00:02 >/dev/null 2>&1 || true
    HALOW_BACKEND_FAIL_KIND=""
}')"
assert_success "a later successful operation in the same pass does not hide the NetworkManager fault" grep -q '^attention|NM_CHECK_FAILED|a station could not be served: station_added wlu1.sta1 failed' "$HL_DIR/state.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; hl_act_halow_st_process_log() { HALOW_ST_FAULT=1; HALOW_ST_FAULT_KIND=other; HALOW_BACKEND_FAIL_KIND=nm; HALOW_ST_FAULT_MSG="x"; }')"
assert_success "control: a first fault of kind other stays BACKEND_FAILED" grep -q '^attention|BACKEND_FAILED|a station could not be served: x|' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- effective radio values: unreadable is not a mismatch; a readable disagreement is --"
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; HL_RC_halow_radio_capture_effective=1; hl_act_halow_radio_capture_effective() { HALOW_EFF_STATE=unavailable; HALOW_EFF_REASON="no s1g_freq"; }')"
assert_success "the access point stays up: operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_failure "no attention" grep -q '^attention|' "$HL_DIR/state.log"
assert_failure "no effective values are recorded (the configured ones stay 'requested')" grep -q '^radio_effective|' "$HL_DIR/state.log"
assert_failure "nothing is checked against values that were not read" hl_called halow_radio_check_effective
assert_success "the reason is in diagnostics" grep -q '^diag_set|radio_effective|unconfirmed: the status output lacks the expected radio fields$' "$HL_DIR/state.log"
assert_success "the capture command is bounded by timeout" grep -q "^halow_radio_capture_effective timeout 5 .*/hostapd_cli_s1g -p /var/run/hostapd -i wlu1\$" "$HL_DIR/calls.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HL_RC_halow_radio_check_effective=1')"
assert_eq "RADIO_MISMATCH" "$(attention_code)" "a readable disagreement stays RADIO_MISMATCH"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- long waits: the bandwidth reaches the selection wait; heartbeats and stop check points inside every wait --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_OPT_BANDWIDTH="1"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4; HALOW_MGR_BEAT_EVERY_S=0
hl_act_halow_radio_acs_wait() {
    local i
    for i in 1 2 3; do echo "POLL $HALOW_RADIO_POLL_HOOK" >> "$HL_DIR/state.log"; "$HALOW_RADIO_POLL_HOOK" >/dev/null 2>&1 || :; done
    HALOW_ACS_CHANNEL=30; HALOW_ACS_FREQ_KHZ=917000
}')"
assert_success "the selection wait gets the region, skip 0 and the configured bandwidth" grep -q -x "halow_radio_acs_wait $HALOW_RUN_DIR/hostapd_s1g.log 4242 10 AU 0 1" "$HL_DIR/calls.log"
assert_success "the poll hook is the manager's" grep -q '^POLL _halow_mgr_poll_hook$' "$HL_DIR/state.log"
assert_eq "3" "$(grep -A1 '^POLL' "$HL_DIR/state.log" | grep -c '^heartbeat$')" "every poll refreshed the heartbeat"
assert_success "the selection result of the attempt is cleared first, then recorded" bash -c "grep -q '^diag_set|acs_result|\$' '$HL_DIR/state.log' && grep -q '^diag_set|acs_result|completed\$' '$HL_DIR/state.log'"
halow_test_teardown

hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=1000
hl_act_halow_radio_acs_wait() {
    kill -TERM $$
    "$HALOW_RADIO_POLL_HOOK" >/dev/null 2>&1 || :
    echo "AFTER_HOOK" >> "$HL_DIR/calls.log"
}')"
assert_eq "0" "$HL_EXIT" "a stop during automatic selection is acted on at the next poll: exit 0"
assert_success "the rollback run from the poll hook still logs (the radio library discards the hook's own output)" stop_rollback_logged
assert_failure "nothing after the poll hook ran" grep -q '^AFTER_HOOK$' "$HL_DIR/calls.log"
assert_failure "no fallback was started" hl_called halow_radio_fallback_channel
assert_eq " " "$(hl_owned) " "everything rolled back"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=20; HALOW_MGR_BEAT_EVERY_S=0; HL_RC_halow_wait_for_pattern=1; HALOW_AP_RETRY_LIMIT=1
hl_act_halow_wait_for_pattern() { echo "WAIT" >> "$HL_DIR/state.log"; }')"
assert_eq "15" "$(hl_count halow_wait_for_pattern)" "AP-ENABLED is waited for in 2 s slices up to 30 s (15 slices)"
assert_success "each slice is 2 s and watches hostapd" grep -q -x "halow_wait_for_pattern $HALOW_RUN_DIR/hostapd_s1g.log AP-ENABLED 2 4242" "$HL_DIR/calls.log"
assert_eq "14" "$(grep -A1 '^WAIT$' "$HL_DIR/state.log" | grep -c '^heartbeat$')" "a heartbeat between every two slices"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=1000; HL_RC_halow_wait_for_pattern=1
hl_act_halow_wait_for_pattern() { [ "$(grep -c "^halow_wait_for_pattern" "$HL_DIR/calls.log")" -eq 2 ] && kill -TERM $$; return 0; }')"
assert_eq "0" "$HL_EXIT" "a stop during the AP-ENABLED wait: exit 0"
assert_eq "2" "$(hl_count halow_wait_for_pattern)" "acted on right after the slice in which it arrived"
assert_eq " " "$(hl_owned) " "everything rolled back"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=40; HL_RC_halow_adapter_netdev_wait=1')"
assert_eq "10" "$(hl_count halow_adapter_netdev_wait)" "the interface is waited for in 2 s slices up to 20 s (10 slices)"
assert_success "each slice is 2 s" grep -q -x 'halow_adapter_netdev_wait 2' "$HL_DIR/calls.log"
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=1000; HL_RC_halow_adapter_netdev_wait=1
hl_act_halow_adapter_netdev_wait() { kill -TERM $$; return 0; }')"
assert_eq "0" "$HL_EXIT" "a stop during the interface wait: exit 0"
assert_eq "1" "$(hl_count halow_adapter_netdev_wait)" "acted on after the first slice"
assert_success "the stop rollback's log is not discarded by the wait's output redirection" stop_rollback_logged
halow_test_teardown

hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=6; HL_RC_halow_restore_firmware_search_path=3')"
assert_success "a failed firmware-path restore after the board-file match is shown in diagnostics" grep -q '^diag_set|fw_search_path_restore|not restored: /sys could not be confirmed back in its prior mount mode; retried on rollback$' "$HL_DIR/state.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4')"
assert_success "a successful restore is shown too" grep -q '^diag_set|fw_search_path_restore|restored after the board-file match$' "$HL_DIR/state.log"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- module load intents are recorded before each load and cleared by the rollback --"
hl_setup
printf 'cfg80211 1 0\n' > "$HL_DIR/mods"
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4
hl_act_halow_load_dot11ah() { [ "$1" -eq 0 ] && hl_mark module_dot11ah; echo "INTENT_DOT11AH [$(halow_own_get module_intent_dot11ah)]" >> "$HL_DIR/calls.log"; return 0; }
hl_act_halow_load_morse() { [ "$1" -eq 0 ] && hl_mark module_morse; echo "INTENT_MORSE [$(halow_own_get module_intent_morse)]" >> "$HL_DIR/calls.log"; return 0; }')"
assert_success "the dot11ah intent, holding the modules loaded before, exists when dot11ah is loaded" grep -q -x 'INTENT_DOT11AH \[cfg80211\]' "$HL_DIR/calls.log"
assert_success "the morse intent exists when morse is loaded" grep -q -x 'INTENT_MORSE \[cfg80211\]' "$HL_DIR/calls.log"
assert_eq " " "$(hl_owned) " "both intents are cleared by the stop rollback"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=4; HL_LSMOD_FAILS=1')"
assert_eq "MODULE_LOAD_FAILED" "$(attention_code)" "modules that cannot be listed before a load: MODULE_LOAD_FAILED"
assert_failure "nothing is loaded" hl_called halow_load_dot11ah
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- the status service is supervised directly (no network request) and restarted by s6 after two failed checks; never an attention --"
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=12; HALOW_MGR_STATUS_CHECK_S=2; hl_status_world")"
assert_success "s6 is asked for the machine-readable state of the status service directory" grep -q -x 's6-svstat -o up,pid /run/service/status' "$HL_DIR/calls.log"
assert_failure "NO request is made to the status listener: curl is never called" hl_called curl
assert_failure "...and no other network client either" bash -c 'grep -E "^(wget|nc|ncat|socat|telnet|python3) " "$0"' "$HL_DIR/calls.log"
assert_failure "...and the manager's own output has no connection attempt, HTTP request or /health" grep -q -i -E '/health|http://|connect' "$HL_DIR/out.log"
assert_success "a counter that never changes: the second consecutive failure asks s6 to restart the status service" grep -q -x 's6-svc -r /run/service/status' "$HL_DIR/calls.log"
_c1="$(grep -n -m1 -x 's6-svc -r /run/service/status' "$HL_DIR/calls.log" | cut -d: -f1)"
assert_eq "3" "$(head -n "$_c1" "$HL_DIR/calls.log" | grep -c '^s6-svstat ')" "...exactly after the third check: one baseline, then two failed checks (not after a single failure)"
assert_eq "2" "$(grep -c '^s6-svc ' "$HL_DIR/calls.log")" "one restart request per two failed checks (6 checks in this run: two requests)"
assert_success "the first failure is logged with its reason" grep -q 'manager: the status service did not answer (1 of 2): the liveness counter is not advancing' "$HL_DIR/out.log"
assert_success "the restart is logged" grep -q 'manager: the status service was asked to restart' "$HL_DIR/out.log"
assert_success "the diagnostic key is recorded" grep -q '^diag_set|status_service|restarted after not answering$' "$HL_DIR/state.log"
assert_failure "no attention for the status service" grep -q '^attention|' "$HL_DIR/state.log"
assert_success "operating throughout" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_eq "0" "$HL_EXIT" "the manager exits 0 after the stop signal"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=12; HALOW_MGR_STATUS_CHECK_S=2; HL_HB_ADVANCE=1; hl_status_world")"
assert_success "a status service whose counter advances is checked" hl_called s6-svstat
assert_eq "6" "$(hl_count s6-svstat)" "...at every interval"
assert_failure "...and never restarted" hl_called s6-svc
assert_failure "...and never contacted over the network" hl_called curl
assert_failure "no failure is logged" grep -q 'did not answer' "$HL_DIR/out.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=12; HALOW_MGR_STATUS_CHECK_S=2; HL_STATUS_DOWN=1; hl_status_world")"
assert_success "a service that s6 reports down is restarted after the second failed check" grep -q -x 's6-svc -r /run/service/status' "$HL_DIR/calls.log"
_c1="$(grep -n -m1 -x 's6-svc -r /run/service/status' "$HL_DIR/calls.log" | cut -d: -f1)"
assert_eq "2" "$(head -n "$_c1" "$HL_DIR/calls.log" | grep -c '^s6-svstat ')" "...exactly after the second failed check"
assert_success "the reason is logged" grep -q 'manager: the status service did not answer (2 of 2): the service is not running' "$HL_DIR/out.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=12; HALOW_MGR_STATUS_CHECK_S=2; HL_HB_ADVANCE=1; hl_status_world; rm -f \"\$HALOW_STATUS_PORT_FILE\"")"
assert_success "without the recorded port the check fails and restarts after two failures" hl_called s6-svc
assert_success "...and says which state was missing" grep -q 'the recorded port is missing or invalid' "$HL_DIR/out.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=12; HALOW_MGR_STATUS_CHECK_S=2; HL_RC_s6_svc=1; hl_status_world")"
assert_success "a stub name with a hyphen takes its return code from HL_RC_s6_svc: a failing restart request is logged as an error" grep -q 'manager: the status service could not be asked to restart' "$HL_DIR/out.log"
assert_success "...and recorded in the diagnostics" grep -q '^diag_set|status_service|not answering; restart request failed$' "$HL_DIR/state.log"
assert_failure "...and it is not reported as a restart" grep -q 'was asked to restart' "$HL_DIR/out.log"
assert_failure "...and is no attention state" grep -q '^attention|' "$HL_DIR/state.log"
halow_test_teardown
hl_setup
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=20; hl_status_world; HALOW_MGR_STATUS_CHECK_S=1000")"
assert_failure "no check before its interval (the check does not run on every second)" hl_called s6-svstat
halow_test_teardown
hl_setup
export HALOW_OPT_CHANNEL="99"
hl_run_manager "$(scenario "HL_SLEEP_LIMIT=8; HALOW_MGR_STATUS_CHECK_S=2; hl_status_world")"
assert_success "also supervised while holding in attention" hl_called s6-svc
assert_eq "CONFIG_INVALID" "$(attention_code)" "the attention stays the configuration error"
halow_test_teardown

# ---------------------------------------------------------------------------------------
echo "-- the uplink name is checked by the uplink rule (not the generic interface-name rule) --"
for u in hassio docker0 . ..; do
    hl_setup
    export HALOW_OPT_UPLINK_INTERFACE="$u"
    hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=3')"
    assert_success "uplink '$u' is CONFIG_INVALID naming uplink_interface" grep -q '^attention|CONFIG_INVALID|option uplink_interface: ' "$HL_DIR/state.log"
    assert_success "[$u] no host change" hl_no_mutation
    halow_test_teardown
done

# ---------------------------------------------------------------------------------------
echo "-- hang injection: a hostapd control client that never answers cannot hang the manager --"
hl_setup
hl_child_load
# one process that never answers, like a client blocked on an unresponsive socket
printf '#!/bin/bash\nexec sleep 30\n' > "$HL_DIR/hang_cli"; chmod +x "$HL_DIR/hang_cli"
HALOW_HOSTAPD_CLI="$HL_DIR/hang_cli"; HALOW_HOSTAPD_CLI_TIMEOUT_S=1; HALOW_IFACE=wlu1
halow_st_set_all_sta() { echo "[$1]" >> "$HL_DIR/allsta"; }
_t0=$SECONDS; _halow_mgr_all_sta; _dt=$((SECONDS - _t0))
assert_success "the all_sta poll returns within the bound (took ${_dt}s)" test "$_dt" -le 3
assert_eq "[]" "$(cat "$HL_DIR/allsta" 2>/dev/null)" "...and a timed-out answer is not handed on (the last answer is cleared instead, so the state comes from the log)"
HALOW_CFG_SUBNET_CIDR=192.168.90.1/24 HALOW_CFG_DHCP_START=192.168.90.50 HALOW_CFG_DHCP_END=192.168.90.150 HALOW_CFG_MAX_STATIONS=101
HALOW_MGR_UPLINK=end0; HALOW_MGR_SUBNET_NET=192.168.90.0/24; HALOW_MGR_GATEWAY=192.168.90.1
_halow_mgr_step_backend >/dev/null 2>&1
assert_eq "timeout 1 $HL_DIR/hang_cli" "${HALOW_ST_RELOG_CMD[*]:0:3}" "the log-rotation command is bounded by timeout"
_t0=$SECONDS; "${HALOW_ST_RELOG_CMD[@]}" >/dev/null 2>&1; _dt=$((SECONDS - _t0))
assert_success "...and returns within the bound (took ${_dt}s)" test "$_dt" -le 3
. "$HALOW_LIB_DIR/radio.sh"
_t0=$SECONDS
if halow_radio_capture_effective "$HALOW_TIMEOUT_CMD" "$HALOW_HOSTAPD_CLI_TIMEOUT_S" "$HALOW_HOSTAPD_CLI" -p /x -i wlu1 >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
_dt=$((SECONDS - _t0))
assert_eq "1" "$_rc" "the real capture with the manager's bounded command fails (cannot capture)"
assert_success "...within the bound (took ${_dt}s)" test "$_dt" -le 3
halow_test_teardown

# ---------------------------------------------------------------------------------------
# Automatic channel selection start robustness (an empty automatic-selection survey seen once on a supervised start):
# a bounded settle before the first launch and a bounded relaunch after an exit whose
# hostapd log carries exactly the empty-survey message. These are DEFENSIVE TIMING
# MITIGATIONS; the tests prove they are bounded, narrow and never hide a failure.
# The start stub below writes the real hostapd message into the log it was given.
SURVEY_ACT='hl_act_halow_start_hostapd() {
    local n=0 f="$HL_DIR/start_n"
    [ -f "$f" ] && n="$(cat "$f")"; n=$((n + 1)); printf "%s" "$n" > "$f"
    if [ "$1" -eq 0 ]; then HALOW_LAST_STARTED_PID=4242; fi
    case " ${HL_SURVEY_ON:-fail} " in
        *" $n "*|" fail ") if [ "$1" -ne 0 ] || [ -n "${HL_SURVEY_LOG_ALWAYS:-}" ]; then printf "ACS: Automatic channel selection started, this may take a bit\nACS: Unable to collect survey data\nACS: All study options have failed\nInterface initialization failed\n" > "$3"; fi ;;
    esac
    return 0
}'
sv_scenario() { scenario "$SURVEY_ACT; $1"; }

echo "-- automatic: the first launch ends with the empty-survey message, the second works: one bounded relaunch, no attention, no fallback --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=12; HL_RCSEQ_halow_start_hostapd="1 0"; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "2" "$(hl_count halow_start_hostapd)" "hostapd_s1g was launched twice (one relaunch)"
assert_eq "2" "$(hl_count halow_radio_render)" "the configuration is rendered for each launch"
assert_success "hostapd_s1g was stopped between the two launches" bash -c "awk '/^halow_start_hostapd/ {s++} /^halow_stop_hostapd/ && s==1 {f=1} END {exit !f}' '$HL_DIR/calls.log'"
assert_success "the relaunch is announced with its bound" grep -q 'could not collect survey data (hostapd_s1g ended); launching it again after 0s (retry 1 of 2)' "$HL_DIR/out.log"
assert_success "the first failure of the attempt has a record with its own trigger" grep -q 'trigger=acs_survey_retry' "$HL_DIR/state.log"
assert_failure "the fallback channel is never looked up" hl_called halow_radio_fallback_channel
assert_failure "no fallback advisory" grep -q '^advisory|RADIO_AUTO_FALLBACK' "$HL_DIR/state.log"
assert_success "state reached operating" grep -q '^overall|operating$' "$HL_DIR/state.log"
assert_failure "no attention state was raised for the recovered failure" grep -q '^attention|' "$HL_DIR/state.log"
assert_success "the effective source is acs" grep -q '^radio_effective|.*|acs|' "$HL_DIR/state.log"
assert_failure "the passphrase never appears in the output" grep -q 'correct-horse-battery' "$HL_DIR/out.log"
assert_failure "the passphrase never appears in the published state" grep -q 'correct-horse-battery' "$HL_DIR/state.log"
halow_test_teardown

echo "-- automatic: every launch ends with the empty-survey message: bounded (1 + 2 launches per attempt), reported, never hidden --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=80; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "9" "$(hl_count halow_start_hostapd)" "3 launches in each of the 3 bounded attempts, then attention (no unbounded loop)"
assert_eq "AP_START_FAILED" "$(attention_code)" "attention AP_START_FAILED"
assert_eq "true" "$(attention_clean)" "host_clean true"
assert_success "the final detail names the empty survey and the bounded retries" grep -q 'hostapd_s1g failed to start (automatic channel selection could not collect survey data; 2 bounded retries did not help)' "$HL_DIR/out.log"
assert_success "the ordinary retry policy still applies (backoff 5 s then 10 s)" bash -c "grep -q 'retrying in 5s (AP_START_FAILED' '$HL_DIR/out.log' && grep -q 'retrying in 10s (AP_START_FAILED' '$HL_DIR/out.log'"
assert_eq "3" "$(grep -o 'record=[0-9]* trigger=acs_survey_retry' "$HL_DIR/state.log" | sort -u | wc -l)" "exactly one distinct record per attempt (the first failure), so the ring keeps every attempt's evidence"
assert_eq "0" "$(grep -c 'trigger=start_exit' "$HL_DIR/state.log")" "no second record for the exhausted attempt"
assert_failure "the fallback channel is not used for a start that never got a scan result" hl_called halow_radio_fallback_channel
assert_eq " " "$(hl_owned) " "no marker remains"
assert_failure "the passphrase never appears in the output" grep -q 'correct-horse-battery' "$HL_DIR/out.log"
halow_test_teardown

echo "-- automatic: a failure WITHOUT the empty-survey message is not relaunched (usual 3 attempts, 1 launch each) --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "3" "$(hl_count halow_start_hostapd)" "exactly 3 launches"
assert_eq "AP_START_FAILED" "$(attention_code)" "attention AP_START_FAILED"
assert_failure "no survey-retry announcement" grep -q 'launching it again' "$HL_DIR/out.log"
assert_failure "no survey-retry record" grep -q 'trigger=acs_survey_retry' "$HL_DIR/state.log"
halow_test_teardown

echo "-- manual mode: the empty-survey message in the log changes nothing (there is no scan; no relaunch) --"
hl_setup
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="28"
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "3" "$(hl_count halow_start_hostapd)" "exactly 3 launches"
assert_failure "no survey-retry announcement" grep -q 'launching it again' "$HL_DIR/out.log"
assert_failure "no settle wait in manual mode" grep -q 'letting the radio interface settle' "$HL_DIR/out.log"
halow_test_teardown

echo "-- automatic: selection ends (hostapd exited) with the empty-survey message after the launch succeeded: relaunch before any fallback --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=14; HL_SURVEY_ON="1"; HL_SURVEY_LOG_ALWAYS=1; HL_RCSEQ_halow_radio_acs_wait="3 0"; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "2" "$(hl_count halow_start_hostapd)" "launched twice"
assert_eq "2" "$(hl_count halow_radio_acs_wait)" "selection waited for twice"
assert_failure "the fallback channel is never looked up" hl_called halow_radio_fallback_channel
assert_success "the effective source is acs, not fallback" grep -q '^radio_effective|.*|acs|' "$HL_DIR/state.log"
assert_success "a record was kept for the first failure" grep -q 'trigger=acs_survey_retry' "$HL_DIR/state.log"
halow_test_teardown

echo "-- automatic: the empty-survey exit keeps coming after launch: bounded, then the existing fallback decision applies --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=30; HL_SURVEY_ON="1 2 3"; HL_SURVEY_LOG_ALWAYS=1; HL_RC_halow_radio_acs_wait=3; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_success "three selection attempts happened (the original and two bounded relaunches) before the fallback" bash -c "[ \"\$(grep -c '^halow_radio_acs_wait' '$HL_DIR/calls.log')\" -ge 3 ]"
assert_success "the fallback was started afterwards and is announced as before" grep -q '^halow_radio_render AU fallback 1 42 wlu1 ' "$HL_DIR/calls.log"
assert_success "the fallback advisory is set (a persistent problem is shown, not hidden)" grep -q '^advisory|RADIO_AUTO_FALLBACK' "$HL_DIR/state.log"
halow_test_teardown

echo "-- the settle: announced once, bounded, off at 0, bad values fall back to the default, a stop request is honoured --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
export HALOW_ACS_PRESTART_SETTLE_S=2
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=14; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_eq "0" "$HL_EXIT" "exit 0 after stop"
assert_eq "1" "$(grep -c 'letting the radio interface settle for 2s before automatic channel selection' "$HL_DIR/out.log")" "announced once with its length"
assert_success "the settle comes before the first launch" bash -c "awk '/letting the radio interface settle/ {s=1} /automatic channel selection completed/ && s {f=1} END {exit !f}' '$HL_DIR/out.log'"
halow_test_teardown
for bad in abc 99999 -1 ""; do
    hl_setup
    export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
    export HALOW_ACS_PRESTART_SETTLE_S="$bad"
    hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=14; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
    assert_success "[$bad] an invalid value falls back to the 3 s default (never unbounded)" grep -q 'settle for 3s' "$HL_DIR/out.log"
    halow_test_teardown
done
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=14; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_failure "0 switches the settle off (no announcement)" grep -q 'letting the radio interface settle' "$HL_DIR/out.log"
halow_test_teardown
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
export HALOW_ACS_PRESTART_SETTLE_S=3
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=1; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_eq "0" "$HL_EXIT" "a stop during the settle ends the manager with exit 0"
assert_eq "0" "$(hl_count halow_start_hostapd)" "hostapd_s1g was never launched"
assert_success "the rollback completed" stop_rollback_logged
halow_test_teardown

echo "-- the relaunch bound: 0 switches it off, a bad value falls back to 2 --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
export HALOW_ACS_SURVEY_RETRIES=0
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "3" "$(hl_count halow_start_hostapd)" "0 retries: exactly 3 launches (one per attempt)"
assert_failure "nothing announced" grep -q 'launching it again' "$HL_DIR/out.log"
assert_success "the detail still names the empty survey" grep -q 'hostapd_s1g failed to start (automatic channel selection could not collect survey data)' "$HL_DIR/out.log"
halow_test_teardown
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
export HALOW_ACS_SURVEY_RETRIES=abc
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=80; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "9" "$(hl_count halow_start_hostapd)" "a bad value uses the default bound of 2 (9 launches over 3 attempts)"
halow_test_teardown
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { if [ -f "$HL_DIR/start_n" ] && [ ! -f "$HL_DIR/stop_failed" ]; then : > "$HL_DIR/stop_failed"; HL_ACT_RC=1; else hl_undo hostapd_process; fi; }')"
assert_success "a stop that fails before a relaunch is reported as AP_START_FAILED, not retried further" grep -q 'could not be stopped before the automatic channel selection retry' "$HL_DIR/out.log"
halow_test_teardown

echo "-- a different hostapd failure in the log (not the empty survey) is never relaunched here --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_start_hostapd() { printf "Could not set channel for kernel driver\nInterface initialization failed\n" > "$3"; return 0; }; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "3" "$(hl_count halow_start_hostapd)" "exactly 3 launches (one per attempt)"
assert_failure "no survey-retry announcement" grep -q 'launching it again' "$HL_DIR/out.log"
assert_failure "no survey-retry record" grep -q 'trigger=acs_survey_retry' "$HL_DIR/state.log"
halow_test_teardown

echo "-- the empty-survey text of an EARLIER launch is not mistaken for the current one (the log is truncated per launch) --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
hl_run_manager "$(scenario 'HL_SLEEP_LIMIT=60; HL_RC_halow_start_hostapd=1; hl_act_halow_start_hostapd() { local n=0 f="$HL_DIR/start_n"; [ -f "$f" ] && n="$(cat "$f")"; n=$((n + 1)); printf "%s" "$n" > "$f"; if [ "$n" -eq 1 ]; then printf "ACS: Unable to collect survey data\n" > "$3"; else : > "$3"; printf "Could not set channel for kernel driver\n" >> "$3"; fi; return 0; }; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_success "launch 1 is relaunched" grep -q 'launching it again after 0s (retry 1 of 2)' "$HL_DIR/out.log"
assert_eq "1" "$(grep -c 'launching it again' "$HL_DIR/out.log")" "launch 2 (a different failure, log truncated) is not relaunched in the same attempt"
halow_test_teardown

echo "-- the relaunch settle: its length is announced and slept, bad values use 3 s, a stop during it is honoured --"
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S=2
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=14; HL_RCSEQ_halow_start_hostapd="1 0"; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
assert_success "announced with its length" grep -q 'launching it again after 2s (retry 1 of 2)' "$HL_DIR/out.log"
assert_success "the two settle seconds were slept (the sleep count reached at least 2 before the second launch)" bash -c "[ \"\$(cat '$HL_DIR/sleep_count')\" -ge 2 ]"
halow_test_teardown
for bad in abc -1 99999 31; do
    hl_setup
    export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S="$bad"
    hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=14; HL_RCSEQ_halow_start_hostapd="1 0"; HL_ACS_CHANNEL=30; HL_EFF_CHANNEL=30')"
    assert_success "[$bad] an invalid or excessive value uses the 3 s default" grep -q 'launching it again after 3s' "$HL_DIR/out.log"
    halow_test_teardown
done
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S=30
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=2; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "0" "$HL_EXIT" "a stop during the relaunch settle ends the manager with exit 0"
assert_eq "1" "$(hl_count halow_start_hostapd)" "no launch follows the stop"
assert_success "stopped promptly, not after the full 30 s" bash -c "[ \"\$(cat '$HL_DIR/sleep_count')\" -le 6 ]"
halow_test_teardown
hl_setup
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S=2
hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=2; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
assert_eq "1" "$(hl_count halow_start_hostapd)" "the relaunch settle is exactly its length: a stop on the second of its two seconds ends it before any relaunch"
halow_test_teardown
export HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S=0
for bad in -1 99999 6; do
    hl_setup
    export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="" HALOW_ACS_SURVEY_RETRIES="$bad"
    hl_run_manager "$(sv_scenario 'HL_SLEEP_LIMIT=80; HL_RC_halow_start_hostapd=1; hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }')"
    assert_eq "9" "$(hl_count halow_start_hostapd)" "[$bad] an invalid or excessive retry bound uses the default of 2"
    halow_test_teardown
done
unset HALOW_ACS_SURVEY_RETRIES

echo "test_manager: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
