#!/usr/bin/env bash
# Test helpers for the lifecycle suites (manager, reconcile, rollback, options, hand-off).
#
# The manager integrates libraries owned by other subsystems. These helpers replace every
# one of those functions (and the privileged host mechanisms) with a recording stub, so the
# manager's own logic is tested against the documented contract alone:
#   - every stub call is appended to $HL_DIR/calls.log as "<function> <args...>" (the
#     passphrase argument of the renderer is masked);
#   - status-snapshot calls go to $HL_DIR/state.log instead;
#   - a stub returns $HL_RC_<function> (default 0), or the next value of the
#     space-separated list $HL_RCSEQ_<function> (the last value repeats);
#   - stubs of functions that change the host emulate the ownership markers the real
#     functions write, and the undo stubs log "UNDO <key>" for each marker they clear,
#     so a test can compare what was recorded with what was rolled back.
#
# hl_run_manager runs halow_manager_main in a separate bash process with the strict
# shell options of the add-on base image and the same TERM/INT trap as the service; the
# stubbed halow_manager_sleep sends TERM to that process after $HL_SLEEP_LIMIT sleeps.

HL_HELPERS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers_lifecycle.sh"
# shellcheck source=/dev/null
. "$(dirname "$HL_HELPERS_FILE")/helpers_s6.sh"

# The libraries the stub suites load for real (the manager's own, and the protected
# common pieces they build on). Everything else is a stub.
HL_REAL_LIBS="constants common ownership validate backend bootid reconcile lifecycle options rollback failure_record manager"

HL_STATE_STUBS="halow_state_init halow_state_flush halow_state_heartbeat halow_state_overall halow_state_attention halow_state_clear_attention halow_state_advisory halow_state_clear_advisory halow_state_region halow_state_radio_requested halow_state_radio_effective halow_state_radio_clear_effective halow_state_adapter halow_state_backend halow_state_stations_set halow_state_diag_set halow_state_diag_unset halow_state_radio_primary halow_state_diag_log_append"

HL_STUBS="halow_radio_profile_exists halow_radio_validate halow_radio_fallback_channel halow_radio_fallback_state halow_radio_width_state halow_radio_scheme halow_radio_render halow_radio_acs_wait halow_radio_capture_effective halow_radio_check_effective \
halow_guard_check halow_guard_report halow_adapter_check halow_adapter_netdev_wait halow_adapter_netdev halow_adapter_present halow_kernel_iface_exists \
halow_uplink_detect halow_uplink_changed halow_subnet_collision halow_max_stations halow_allowlist_validate \
halow_fw_install_filters halow_fw_reassert halow_fw_remove_filters halow_fw_present halow_bridge_create halow_bridge_delete halow_bridge_exists \
halow_dnsmasq_ensure_running halow_stations_snapshot_lines halow_st_process_log halow_st_reset \
halow_load_dot11ah halow_load_morse halow_place_firmware halow_set_firmware_search_path halow_restore_firmware_search_path halow_dmesg_watermark halow_dmesg_since halow_check_bcf_match halow_derive_installed_slug halow_checksum_for halow_verify_manifest halow_verify_parent_iface \
halow_nm_mark_unmanaged halow_nm_mark_unmanaged_if_known halow_nm_restore_managed halow_hostapd_pre_start_check halow_start_hostapd halow_stop_hostapd halow_wait_for_pattern \
halow_unload_modules halow_remove_firmware halow_module_state halow_verify_fw_search_path_rebooted_clean \
halow_ipv6_disable halow_ipv6_restore_all halow_ipv6_present halow_ipv6_mount_table_readable halow_fw_ipv6_governed halow_bridge_enforce_isolation \
fake_backend_ownership_keys fake_backend_configure fake_backend_attach fake_backend_station_added fake_backend_station_removed fake_backend_teardown fake_backend_health"

# The calls that change the host (none may appear before the read-only checks pass).
HL_MUTATING="halow_fw_install_filters halow_load_dot11ah halow_load_morse halow_place_firmware halow_set_firmware_search_path halow_nm_mark_unmanaged halow_nm_mark_unmanaged_if_known halow_bridge_create halow_ipv6_disable halow_bridge_enforce_isolation halow_hostapd_pre_start_check halow_radio_render halow_start_hostapd fake_backend_configure fake_backend_attach"

HL_CATALOGUE="NO_ADAPTER MULTIPLE_ADAPTERS UNSUPPORTED_KERNEL REGION_UNVALIDATED CONFIG_INVALID FIRMWARE_INVALID MODULE_LOAD_FAILED HOST_STATE_FAILED AP_START_FAILED AP_DIED BACKEND_FAILED NM_CHECK_FAILED UPLINK_UNAVAILABLE ROLLBACK_INCOMPLETE STATUS_STALE RADIO_MISMATCH INTERNAL_ERROR RADIO_AUTO_FALLBACK"

# --- the recording stub ---------------------------------------------------------------

hl_log_call() {
    local fn="$1" i=0 a line="$1"
    shift
    for a in "$@"; do
        i=$((i + 1))
        if [ "$fn" = "halow_radio_render" ] && [ "$i" -eq 7 ]; then a="<passphrase>"; fi
        line="$line $a"
    done
    printf '%s\n' "$line" >> "$HL_DIR/calls.log"
}

# hl_next_rc <fn> — the return code for this call of <fn>.
hl_next_rc() {
    # a hyphen is not valid in a variable name (s6-svc, s6-svstat): HL_RC_s6_svc
    local fn="$1" seqvar="HL_RCSEQ_${1//-/_}" rcvar="HL_RC_${1//-/_}" seq n=0 cnt i=0 v last=0
    seq="${!seqvar:-}"
    if [ -n "$seq" ]; then
        cnt="$HL_DIR/cnt_$fn"
        [ -f "$cnt" ] && n="$(cat "$cnt")"
        n=$((n + 1))
        printf '%s' "$n" > "$cnt"
        for v in $seq; do
            i=$((i + 1))
            last="$v"
            if [ "$i" -eq "$n" ]; then printf '%s' "$v"; return 0; fi
        done
        printf '%s' "$last"
        return 0
    fi
    printf '%s' "${!rcvar:-0}"
}

hl_stub() {
    local fn="$1" rc
    shift
    hl_log_call "$fn" "$@"
    rc="$(hl_next_rc "$fn")"
    HL_ACT_RC=""
    if declare -F "hl_act_$fn" >/dev/null 2>&1; then
        "hl_act_$fn" "$rc" "$@" || true
    fi
    # An action may decide the return code itself (HL_ACT_RC).
    [ -z "$HL_ACT_RC" ] || rc="$HL_ACT_RC"
    return "$rc"
}

hl_state_stub() {
    local fn="$1" line
    shift
    line="${fn#halow_state_}"
    local a
    for a in "$@"; do line="$line|$a"; done
    printf '%s\n' "$line" >> "$HL_DIR/state.log"
    return 0
}

hl_define_stubs() {
    local fn
    for fn in $HL_STUBS; do
        eval "$fn() { hl_stub $fn \"\$@\"; }"
    done
    for fn in $HL_STATE_STUBS; do
        eval "$fn() { hl_state_stub $fn \"\$@\"; }"
    done
    halow_error_known() { case " $HL_CATALOGUE " in *" ${1:-} "*) return 0 ;; esac; return 1; }
    halow_backend_register_default() { halow_backend_register fake; }
    halow_manager_sleep() {
        local n=0
        printf '%s\n' "${1:-1}" >> "$HL_DIR/sleeps.log"
        [ -f "$HL_DIR/sleep_count" ] && n="$(cat "$HL_DIR/sleep_count")"
        n=$((n + 1))
        printf '%s' "$n" > "$HL_DIR/sleep_count"
        if [ "$n" -ge "${HL_SLEEP_LIMIT:-40}" ] && [ ! -f "$HL_DIR/term_sent" ]; then
            : > "$HL_DIR/term_sent"
            # What was persisted before the stop signal (a test can tell it from what the
            # stop itself wrote).
            [ -e "$HALOW_STATE_DIR/refusal" ] && : > "$HL_DIR/refusal_before_term"
            cp "$HL_DIR/state.log" "$HL_DIR/state_before_term.log" 2>/dev/null || true
            cp "$HL_DIR/calls.log" "$HL_DIR/calls_before_term.log" 2>/dev/null || true
            kill -TERM "$$"
        fi
        if [ "$n" -ge $(( ${HL_SLEEP_LIMIT:-40} + 50 )) ]; then
            echo "HL: the manager ignored the stop signal" >&2
            exit 99
        fi
        return 0
    }
    halow_manager_pid_alive() {
        local n=0
        [ -f "$HL_DIR/alive_count" ] && n="$(cat "$HL_DIR/alive_count")"
        n=$((n + 1))
        printf '%s' "$n" > "$HL_DIR/alive_count"
        [ "$n" -le "${HL_ALIVE_FOR:-100000}" ]
    }
    # Host commands the manager calls by name: recorded; the mount makes the run
    # directory a tmpfs in the fake mount table; lsmod lists $HL_DIR/mods.
    mount() {
        hl_log_call mount "$@"
        [ "${HL_MOUNT_FAILS:-0}" -eq 0 ] || return 32
        printf 'tmpfs %s tmpfs rw,nosuid,nodev,noexec 0 0\n' "${*: -1}" >> "$HALOW_PROC_MOUNTS"
    }
    lsmod() {
        [ "${HL_LSMOD_FAILS:-0}" -eq 0 ] || return 1
        echo "Module Size Used by"
        cat "$HL_DIR/mods" 2>/dev/null || true
    }
    # The manager never connects to the status service: any call of a network client is a
    # recorded call a test can assert to be absent.
    curl() { hl_stub curl "$@"; }
    s6-svc() { hl_stub s6-svc "$@"; }
    # Without hl_status_world there is no status service: s6-svstat prints what the real
    # program prints when no supervisor runs (tests/fixtures/s6-svstat-real.txt) and fails.
    s6-svstat() { hl_log_call s6-svstat "$@"; s6_fixture_print missing_o 0; }
}

# hl_status_world — in a scenario: a healthy status service for the manager's liveness
# check, built from fakes in the kernel's own formats: s6-svstat reports the service up as
# pid 4300 (its /proc entry: the status server with its port, running as the status user),
# the recorded port, a LISTEN line for it on the bind address and a counter file. The
# counter advances on every s6-svstat call (that is, on every check) when
# HL_HB_ADVANCE=1 and stays put otherwise. HL_STATUS_DOWN=1 makes s6-svstat report the
# service down. A fake /proc holds only the manager itself ($$) and pid 4300.
hl_status_world() {
    local uid port=63000 hexport
    uid="$(id -u)"
    hexport="$(printf '%04X' "$port")"
    HALOW_STATUS_USER="$(id -un)"
    HALOW_PROC_DIR="$HL_DIR/proc"
    mkdir -p "$HALOW_PROC_DIR/$$" "$HALOW_PROC_DIR/4300" "$HL_DIR/hb"
    printf 'python3\0%s\0--port\0%s\0' "$HALOW_LIB_DIR/status/status_server.py" "$port" > "$HALOW_PROC_DIR/4300/cmdline"
    printf '%s\n' "Uid:$(printf '\t%s' "$uid" "$uid" "$uid" "$uid")" > "$HALOW_PROC_DIR/4300/status"
    HALOW_PROC_NET_TCP="$HL_DIR/tcp"
    {
        printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
        printf '   0: 01201EAC:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000 %5d        0 20001 1 0000000000000000 100 0 0 10 0\n' "$hexport" "$uid"
    } > "$HALOW_PROC_NET_TCP"
    HALOW_STATUS_PORT_FILE="$HL_DIR/status.port"
    printf '%s\n' "$port" > "$HALOW_STATUS_PORT_FILE"
    HALOW_STATUS_HEARTBEAT_FILE="$HL_DIR/hb/heartbeat"
    printf '100\n' > "$HALOW_STATUS_HEARTBEAT_FILE"
    s6-svstat() {
        local n
        hl_log_call s6-svstat "$@"
        if [ "${HL_STATUS_DOWN:-0}" = 1 ]; then
            s6_fixture_print stopped_o 0
            return 0
        fi
        if [ "${HL_HB_ADVANCE:-0}" = 1 ]; then
            n="$(cat "$HALOW_STATUS_HEARTBEAT_FILE")"
            printf '%s\n' "$((n + 1))" > "$HALOW_STATUS_HEARTBEAT_FILE"
        fi
        s6_fixture_print up_o 4300
    }
}

# --- marker emulation of the host-changing stubs ----------------------------------------

hl_mark() { halow_own_mark "$1"; printf 'MARK %s\n' "$1" >> "$HL_DIR/calls.log"; }
hl_undo() {
    local key="$1"
    if halow_own_check "$key"; then
        case " ${HL_UNDO_FAIL:-} " in
            *" $key "*) printf 'UNDO-FAILED %s\n' "$key" >> "$HL_DIR/calls.log"; return 1 ;;
        esac
        halow_own_clear "$key"
        printf 'UNDO %s\n' "$key" >> "$HL_DIR/calls.log"
    fi
    return 0
}

hl_act_halow_fw_install_filters() { [ "$1" -eq 0 ] && hl_mark fw_filter; return 0; }
hl_act_halow_fw_remove_filters() { hl_undo fw_filter; }
hl_act_halow_load_dot11ah() { [ "$1" -eq 0 ] && hl_mark module_dot11ah; return 0; }
hl_act_halow_load_morse() {
    if [ -n "${HL_TERM_IN_MORSE:-}" ]; then kill -TERM "$$"; fi
    [ "$1" -eq 0 ] && hl_mark module_morse
    return 0
}
hl_act_halow_place_firmware() { [ "$1" -eq 0 ] && hl_mark "$5"; return 0; }
hl_act_halow_set_firmware_search_path() { [ "$1" -eq 0 ] && hl_mark fw_search_path; return 0; }
hl_act_halow_restore_firmware_search_path() { hl_undo fw_search_path; }
hl_act_halow_nm_mark_unmanaged() { [ "$1" -eq 0 ] && hl_mark "$3"; return 0; }
hl_act_halow_nm_mark_unmanaged_if_known() { [ "$1" -eq 0 ] && hl_mark "$3"; return 0; }
hl_act_halow_nm_restore_managed() { hl_undo "$2"; }
hl_act_halow_bridge_create() { [ "$1" -eq 0 ] && hl_mark net_bridge; return 0; }
hl_act_halow_bridge_delete() { hl_undo net_bridge; }
hl_act_halow_hostapd_pre_start_check() { [ "$1" -eq 0 ] && hl_mark hostapd_process; return 0; }
hl_act_halow_start_hostapd() { [ "$1" -eq 0 ] && HALOW_LAST_STARTED_PID=4242; return 0; }
hl_act_halow_stop_hostapd() { hl_undo hostapd_process; }
hl_act_halow_unload_modules() { hl_undo module_morse; hl_undo module_mac80211; hl_undo module_dot11ah; }
hl_act_halow_remove_firmware() { hl_undo "$4"; hl_undo "$5"; }
hl_act_fake_backend_attach() { [ "$1" -eq 0 ] && { hl_mark net_bridge_addr; hl_mark net_dnsmasq; hl_mark fw_nat; }; return 0; }
hl_act_fake_backend_teardown() { hl_undo fw_nat; hl_undo net_dnsmasq; hl_undo net_bridge_addr; }
hl_act_fake_backend_ownership_keys() { printf 'net_bridge_addr net_dnsmasq fw_nat'; }
hl_act_halow_radio_acs_wait() {
    if [ "$1" -eq 0 ]; then HALOW_ACS_CHANNEL="${HL_ACS_CHANNEL:-30}"; HALOW_ACS_FREQ_KHZ="$((902000 + 500 * HALOW_ACS_CHANNEL))"; fi
    return 0
}
hl_act_halow_radio_capture_effective() {
    HALOW_EFF_CHANNEL="${HL_EFF_CHANNEL:-28}"; HALOW_EFF_FREQ_KHZ="$((902000 + 500 * HALOW_EFF_CHANNEL))"; HALOW_EFF_BW_MHZ="${HALOW_CFG_BANDWIDTH:-1}"
    return 0
}
hl_act_halow_radio_fallback_channel() { [ "$1" -eq 0 ] && printf '%s' "${HL_FALLBACK_CH:-42}"; return 0; }
hl_act_halow_radio_fallback_state() { printf 'candidate'; }
hl_act_halow_radio_width_state() { printf 'implemented'; }
hl_act_halow_radio_scheme() { printf '%s' "${HL_SCHEME-2}"; }
hl_act_halow_radio_profile_exists() { return 0; }
hl_act_halow_radio_validate() {
    # manual mode: channels 28 30 32 42 are valid in the stub profile (1 MHz, IEEE 802.11-2024 numbering)
    if [ "$3" = "manual" ]; then
        case " 28 30 32 42 " in *" $5 "*) return 0 ;; esac
        printf 'OPTION=channel REASON=channel %s is not valid for %s MHz\n' "$5" "$4"
        HL_ACT_RC=1
    fi
    return 0
}
hl_act_halow_guard_report() { printf 'kernel=6.18.58\nmodules_hash=match\n'; }
hl_act_halow_adapter_netdev() { printf 'wlu1'; }
hl_act_halow_uplink_detect() { printf 'end0'; }
hl_act_halow_max_stations() { printf '101'; }
hl_act_halow_dmesg_watermark() { printf '0'; }
hl_act_halow_dmesg_since() { printf 'morse: bcf loaded'; }
hl_act_halow_derive_installed_slug() { printf '%s' "${HL_SLUG:-local_morse_micro_halow_ap}"; }
hl_act_halow_checksum_for() { printf '0123abcd'; }
hl_act_halow_stations_snapshot_lines() { printf '02:00:00:00:00:01|true|192.168.90.50|100|ordinary\n'; }
hl_act_halow_ipv6_disable() { [ "$1" -eq 0 ] && hl_mark "ipv6_$2"; return 0; }
hl_act_halow_ipv6_restore_all() {
    local k
    while IFS= read -r k; do
        case "$k" in ipv6_*) hl_undo "$k" || HL_ACT_RC=1 ;; esac
    done < <(halow_own_list)
    return 0
}
hl_act_halow_ipv6_present() {
    case " $(halow_own_list | tr '\n' ' ') " in *" ipv6_"*) HL_ACT_RC=0 ;; *) HL_ACT_RC=1 ;; esac
    return 0
}

# --- setup ------------------------------------------------------------------------------

# hl_child_load — sources the real lifecycle libraries and defines every stub (used in the
# child process, and by in-process tests that want the same environment).
hl_child_load() {
    local lib
    for lib in $HL_REAL_LIBS; do
        # shellcheck source=/dev/null
        . "$HALOW_LIB_DIR/${lib}.sh"
    done
    hl_define_stubs
    # Host-query defaults: nothing of this add-on's is present on the host, modules are not
    # loaded, the uplink has not changed.
    HL_RC_halow_module_state="${HL_RC_halow_module_state:-1}"
    HL_RC_halow_bridge_exists="${HL_RC_halow_bridge_exists:-1}"
    HL_RC_halow_fw_present="${HL_RC_halow_fw_present:-1}"
    HL_RC_halow_uplink_changed="${HL_RC_halow_uplink_changed:-1}"
    HALOW_BACKEND_NAME=""
    halow_backend_register fake >/dev/null 2>&1 || true
}

# hl_setup — a fresh disposable environment (paths as halow_test_setup sets them).
hl_setup() {
    halow_test_setup >/dev/null 2>&1 || true
    export HL_DIR="$HALOW_TEST_TMP/hl"
    mkdir -p "$HL_DIR" "$HALOW_RUN_DIR"
    : > "$HL_DIR/calls.log"
    : > "$HL_DIR/state.log"
    : > "$HL_DIR/sleeps.log"
    : > "$HL_DIR/mods"
    export HALOW_PROC_MOUNTS="$HL_DIR/mounts"
    printf 'overlay / overlay rw 0 0\n' > "$HALOW_PROC_MOUNTS"
    printf '1\n' > "$HALOW_IP_FORWARD_FILE"
    printf '11111111-2222-3333-4444-555555555555\n' > "$HALOW_BOOT_ID_FILE"
    export HALOW_FW_SEARCH_DIR_HOST=""
    # A complete, valid option set (environment form, no bashio).
    export HALOW_OPT_REGION="AU" HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_BANDWIDTH="1" HALOW_OPT_CHANNEL="28"
    export HALOW_OPT_WIFI_SSID="HaLow-Test" HALOW_OPT_WIFI_PASSPHRASE="correct-horse-battery" HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24"
    export HALOW_FREC_DMESG_CMD=true HALOW_FREC_IP_CMD=true
    # The automatic-selection settle waits are real seconds in production; the stubbed
    # sleep counts them, so the suites that depend on the sleep count run with none.
    export HALOW_ACS_PRESTART_SETTLE_S=0 HALOW_ACS_SURVEY_SETTLE_S=0
    export HALOW_OPT_DHCP_RANGE_START="192.168.90.50" HALOW_OPT_DHCP_RANGE_END="192.168.90.150" HALOW_OPT_UPLINK_INTERFACE="" HALOW_OPT_ALLOWED_PORTS=""
}

# hl_run_manager [<scenario-file>] — runs the manager in a child process; sets HL_EXIT.
hl_run_manager() {
    local scen="${1:-/dev/null}"
    cat > "$HL_DIR/child.sh" <<CHILD
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
. "$HL_HELPERS_FILE"
hl_child_load
. "$scen"
trap 'halow_manager_on_stop' TERM INT
halow_manager_main
CHILD
    rm -f "$HL_DIR/sleep_count" "$HL_DIR/term_sent" "$HL_DIR/alive_count" "$HL_DIR"/cnt_*
    if timeout 120 bash "$HL_DIR/child.sh" > "$HL_DIR/out.log" 2>&1; then
        HL_EXIT=0
    else
        HL_EXIT=$?
    fi
}

# --- query helpers ----------------------------------------------------------------------

hl_calls() { grep -v -E '^(MARK|UNDO|UNDO-FAILED) ' "$HL_DIR/calls.log" | awk '{print $1}'; }
hl_count() { local n; n="$(hl_calls | grep -c -x -- "$1" || true)"; printf '%s' "${n:-0}"; }
# Never `hl_calls | grep -q`: under pipefail the early-exiting grep can make the writer die
# of SIGPIPE on a long log and the pipeline report "not called" for a call that was made.
hl_called() { local all; all="$(hl_calls)"; grep -q -x -- "$1" <<< "$all"; }
hl_last_attention() { grep '^attention|' "$HL_DIR/state.log" | tail -n 1; }
hl_marks() { grep '^MARK ' "$HL_DIR/calls.log" | awk '{print $2}' | sort -u | tr '\n' ' '; }
hl_undos() { grep '^UNDO ' "$HL_DIR/calls.log" | awk '{print $2}' | sort -u | tr '\n' ' '; }
hl_owned() { halow_own_list | tr '\n' ' '; HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_list | tr '\n' ' '; }
hl_no_mutation() {
    local fn
    for fn in $HL_MUTATING; do
        if hl_called "$fn"; then echo "mutating call found: $fn"; return 1; fi
    done
    return 0
}
