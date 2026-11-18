#!/usr/bin/env bash
# halow: the manager — the long-lived process that owns every host change.
#
# Before the first attempt the manager mounts a memory-backed filesystem on the run
# directory (so the rendered passphrase never reaches a disk) and then creates the
# ready file the status service waits for. A failure there is HOST_STATE_FAILED and
# nothing is ever rendered.
#
# One start attempt runs these steps in order (each raises the named catalogue code):
#    0. preflight: the process list under /proc is readable  HOST_STATE_FAILED
#       (the process-identity scans of reconcile and rollback depend on it)
#    1. refusal check: a persisted refusal allows only rollback retries
#    2. reconcile: residue from earlier runs undone, recognised from the host
#                                                          ROLLBACK_INCOMPLETE
#    3. options                                            CONFIG_INVALID REGION_UNVALIDATED
#    4. compatibility guard and artifact checksums         UNSUPPORTED_KERNEL FIRMWARE_INVALID
#    5. adapter, uplink, IPv4 forwarding (verify only)     NO_ADAPTER MULTIPLE_ADAPTERS
#                                                          UPLINK_UNAVAILABLE HOST_STATE_FAILED
#       (up to here the only host changes are the run-directory tmpfs above and
#       reconcile undoing this add-on's own residue; the guard runs before any other)
#    6. firewall filter chains, before anything else exists BACKEND_FAILED
#    7. driver and firmware (an intent record is written    MODULE_LOAD_FAILED HOST_STATE_FAILED
#       before each module load)                           FIRMWARE_INVALID
#    8. the adapter's interface: the firewall catch-all for  BACKEND_FAILED NM_CHECK_FAILED
#       it, IPv6 off, NetworkManager-unmanaged
#    9. the private bridge: IPv6 off, NetworkManager-       BACKEND_FAILED NM_CHECK_FAILED
#       unmanaged
#   10. the access point (automatic selection or manual),   AP_START_FAILED BACKEND_FAILED
#       client isolation on every bridge port
#   11. effective radio values checked (values that cannot  RADIO_MISMATCH
#       be read leave the access point up, unconfirmed)
#   12. the bridge backend (address, DHCP, NAT last)        BACKEND_FAILED NM_CHECK_FAILED
#   13. operating: supervision until something fails       AP_DIED NO_ADAPTER
#                                                          MULTIPLE_ADAPTERS UPLINK_UNAVAILABLE
#                                                          BACKEND_FAILED NM_CHECK_FAILED
# Any failure rolls back exactly what was recorded, records whether the host is clean, and
# sets "attention required"; lifecycle.sh decides whether a full new attempt follows (after
# a backoff) or the manager stays in attention. The process never exits on its own: it
# keeps the status snapshot fresh until the stop signal arrives, then rolls back and exits
# (0 when the rollback is confirmed, 1 otherwise). While waiting it also checks that the
# status service is alive and has s6 restart it when it is not (never an attention
# state: the status page is not the access point). The check makes no network request:
# it reads the s6 state, the process identity, the kernel's TCP table and the status
# server's liveness counter (see _halow_mgr_status_check).
#
# The TERM/INT handler only records that a stop was requested. The manager acts on it at
# its own check points: after every start step, between the slices of every long wait
# (automatic channel selection through the radio poll hook, AP-ENABLED, the adapter's
# interface), and in the supervision and attention loops. A stop requested while a host
# change is in progress therefore always waits until that step has finished and the
# rollback sees a consistent record, and the rollback never runs inside the signal
# handler (where the shell may still hold the temporary field separator of an
# interrupted `read`).
#
# Every step is called in the condition of an `if`, and every status is captured with
# `if cmd; then rc=0; else rc=$?; fi`, so the strict shell options of the add-on base
# image never end the process in the middle of a step; a step that fails without naming a
# catalogue code becomes INTERNAL_ERROR.
#
# The privileged sequence of step 7 (module load with the channelisation scheme, firmware
# placement and checksums, the firmware search path with its status handling, the kernel
# log watermark and board-file match, the installed-slug derivation) is carried over from
# the earlier, hardware-exercised build with the same calls, arguments and order.
#
# Defines functions and constants only.

: "${HALOW_HOSTAPD_CLI:=${HALOW_ARTIFACTS_DIR:-/opt/halow/artifacts}/hostapd_cli_s1g}"
: "${HALOW_HOSTAPD_CTRL_DIR:=/var/run/hostapd}"
: "${HALOW_IP_FORWARD_FILE:=/proc/sys/net/ipv4/ip_forward}"
: "${HALOW_AP_ENABLED_TIMEOUT_S:=30}"
: "${HALOW_ADAPTER_NETDEV_TIMEOUT_S:=20}"
# Seconds of one automatic-channel-selection wait slice (the heartbeat is refreshed
# between slices so a long selection never makes the status look stale).
: "${HALOW_MGR_ACS_SLICE_S:=10}"
# Automatic channel selection (ACS) start robustness. DEFENSIVE TIMING MITIGATIONS, not a
# root-cause fix (a failure-recorder capture from a supervised start, diagnostics key
# ap_failure_1; the cause was not established): once in a run of starts, hostapd_s1g's ACS scan returned no channel survey
# records ("ACS: Unable to collect survey data") within about a second of launch, while every
# other start scanned for about 14 s. The cause of the empty scan is NOT established; the
# strongest supported reading is a race between the first scan request on the radio
# interface and the host's NetworkManager/wpa_supplicant releasing it about a second
# earlier. Both values are bounded and, at 0, switch the behaviour off:
#   PRESTART_SETTLE_S  seconds to wait after the interface was handed over (marked
#                      NetworkManager-unmanaged) and before hostapd_s1g is first launched
#                      for automatic selection;
#   SURVEY_RETRIES     how many EXTRA bounded launches follow an exit whose hostapd log
#                      carries exactly the empty-survey message (no other failure is
#                      retried here), each after SURVEY_SETTLE_S seconds. The ordinary
#                      retry policy of lifecycle.sh (3 consecutive AP_START_FAILED, then
#                      attention) is unchanged and still applies when these are exhausted.
# Accepted values: PRESTART_SETTLE_S and SURVEY_SETTLE_S 0 to 30, SURVEY_RETRIES 0 to 5;
# anything else (non-numeric, negative, larger) uses the default.
: "${HALOW_ACS_PRESTART_SETTLE_S:=3}"
: "${HALOW_ACS_SURVEY_RETRIES:=2}"
: "${HALOW_ACS_SURVEY_SETTLE_S:=3}"
# Supervision cadence, in one-second ticks.
: "${HALOW_MGR_SNAPSHOT_EVERY:=5}"
: "${HALOW_MGR_HEALTH_EVERY:=10}"
: "${HALOW_MGR_REASSERT_EVERY:=30}"
# Operating this long resets the consecutive access-point failure count.
: "${HALOW_MGR_STABLE_S:=120}"
# Sleep between heartbeats while waiting in attention.
: "${HALOW_MGR_HOLD_TICK_S:=5}"
# Seconds of one slice of the AP-ENABLED and adapter-interface waits; the heartbeat is
# refreshed and a stop request acted on between slices.
: "${HALOW_MGR_WAIT_SLICE_S:=2}"
# Inside long waits the heartbeat is refreshed at most this often (seconds).
: "${HALOW_MGR_BEAT_EVERY_S:=5}"
# Status-service liveness: checked this often (seconds); this many consecutive failed
# checks have s6 restart the status service. The status server advances its counter about
# every 5 seconds (status_server.py), far below the check interval.
: "${HALOW_MGR_STATUS_CHECK_S:=30}"
: "${HALOW_MGR_STATUS_FAILS_MAX:=2}"
: "${HALOW_S6_SVC:=s6-svc}"
: "${HALOW_S6_SVSTAT:=s6-svstat}"
# The kernel's IPv4 TCP table (never opened as a socket; redirectable for tests) and the
# bounds of what is read from it, and from the status server's counter file.
: "${HALOW_PROC_NET_TCP:=/proc/net/tcp}"
: "${HALOW_MGR_TCP_TABLE_MAX_BYTES:=1048576}"
: "${HALOW_MGR_TCP_TABLE_MAX_LINES:=8192}"
: "${HALOW_MGR_HEARTBEAT_MAX_BYTES:=32}"
# A read of the counter or port file that takes longer than this (a FIFO in its place)
# is a failed check, never a hang of the manager.
: "${HALOW_MGR_FILE_READ_TIMEOUT_S:=2}"
: "${HALOW_S6_STATUS_SERVICE_DIR:=/run/service/status}"
# Every hostapd control-interface call is bounded by this command and limit.
: "${HALOW_TIMEOUT_CMD:=timeout}"
: "${HALOW_HOSTAPD_CLI_TIMEOUT_S:=5}"
# The process list and the mount table (redirectable for tests).
: "${HALOW_PROC_DIR:=/proc}"
: "${HALOW_PROC_MOUNTS:=/proc/mounts}"

HALOW_MGR_ERR_CODE=""
HALOW_MGR_ERR_DETAIL=""
HALOW_MGR_ORIG_CODE=""
HALOW_MGR_ORIG_DETAIL=""
HALOW_MGR_HOST_CLEAN="true"
HALOW_MGR_CRITICAL=0
HALOW_MGR_STOP_PENDING=0
HALOW_MGR_STOPPING=0
HALOW_MGR_PHASE=""
HALOW_MGR_AP_FAILS=0
HALOW_MGR_ATTEMPT=0
HALOW_MGR_HOSTAPD_PID=""
HALOW_MGR_RADIO_SOURCE=""
HALOW_MGR_RADIO_CHANNEL=""
HALOW_MGR_UPLINK=""
HALOW_MGR_UPLINK_DETECTED=0
HALOW_MGR_SUBNET_NET=""
HALOW_MGR_GATEWAY=""
HALOW_MGR_NO_ROLLBACK=0
HALOW_MGR_LAST_BEAT=""
HALOW_MGR_STATUS_ELAPSED=0
HALOW_MGR_STATUS_FAILS=0
HALOW_MGR_STATUS_HB_PID=""
HALOW_MGR_STATUS_HB_LAST=""
HALOW_MGR_STATUS_WHY=""
HALOW_MGR_READ_DATA=""
HALOW_MGR_FD_OUT=""
HALOW_MGR_FD_ERR=""
HALOW_IFACE=""

# Every function of another module the manager calls; checked before the first attempt.
HALOW_MGR_REQUIRED_FUNCS="halow_state_init halow_state_flush halow_state_heartbeat halow_state_overall halow_state_attention halow_state_clear_attention halow_state_advisory halow_state_clear_advisory halow_state_region halow_state_radio_requested halow_state_radio_effective halow_state_radio_clear_effective halow_state_adapter halow_state_backend halow_state_stations_set halow_state_diag_set halow_error_known halow_radio_scheme halow_radio_render halow_radio_acs_wait halow_radio_fallback_channel halow_radio_fallback_state halow_radio_width_state halow_radio_capture_effective halow_radio_check_effective halow_guard_check halow_guard_report halow_adapter_check halow_adapter_netdev_wait halow_adapter_netdev halow_adapter_present halow_uplink_detect halow_uplink_changed halow_fw_install_filters halow_fw_reassert halow_bridge_create halow_dnsmasq_ensure_running halow_stations_snapshot_lines halow_st_process_log halow_backend_register_default halow_backend_call halow_options_load halow_options_validate halow_reconcile halow_rollback halow_refusal_set halow_verify_manifest halow_checksum_for halow_place_firmware halow_set_firmware_search_path halow_restore_firmware_search_path halow_load_dot11ah halow_load_morse halow_dmesg_watermark halow_dmesg_since halow_check_bcf_match halow_derive_installed_slug halow_verify_parent_iface halow_nm_mark_unmanaged halow_nm_mark_unmanaged_if_known halow_hostapd_pre_start_check halow_start_hostapd halow_stop_hostapd halow_wait_for_pattern halow_ipv4_to_int halow_ipv4_mask_from_prefix halow_ipv6_disable halow_ipv6_restore_all halow_fw_ipv6_governed halow_bridge_enforce_isolation halow_validate_uplink_name halow_rollback_loaded_modules"

# --- Seams (time, sleep, process liveness, exit): the tests replace these. ---------

halow_manager_now() { date +%s; }

# halow_manager_sleep <seconds> — interruptible by a trapped signal.
halow_manager_sleep() {
    sleep "${1:-1}" &
    wait "$!" 2>/dev/null || true
}

halow_manager_pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

halow_manager_exit() {
    exit "${1:-0}"
}

# --- Small helpers -----------------------------------------------------------------

# _halow_mgr_st <state-function> [args...] — a status-snapshot update; its own failure
# is logged and never changes the manager's course.
_halow_mgr_st() {
    if ! declare -F "$1" >/dev/null 2>&1; then
        return 0
    fi
    if "$@"; then
        return 0
    fi
    halow_log_warning "manager: status update $1 failed"
    return 0
}

# _halow_mgr_failure_record <trigger> [<hostapd log>] - preserves a bounded, secrets-safe record of
# an access-point failure BEFORE the rollback removes hostapd_s1g's log (see failure_record.sh).
# Best effort: never changes the outcome.
_halow_mgr_failure_record() {
    if declare -F halow_failure_record_capture >/dev/null 2>&1; then
        halow_failure_record_capture "$1" "${2:-}" 2>/dev/null || true
    fi
    return 0
}

# _halow_mgr_fail <CODE> <detail> — records the step's failure; always returns 1.
# _halow_mgr_klog_reason — prints (and removes) the reason the kernel-log readers left in
# HALOW_KLOG_REASON_FILE, or a fallback when none was written.
_halow_mgr_klog_reason() {
    local r=""
    if [ -n "${HALOW_KLOG_REASON_FILE:-}" ] && [ -r "$HALOW_KLOG_REASON_FILE" ]; then
        r="$(head -n 1 -- "$HALOW_KLOG_REASON_FILE" 2>/dev/null || true)"
        rm -f -- "$HALOW_KLOG_REASON_FILE" 2>/dev/null || true
    fi
    printf '%s' "${r:-no reason recorded}"
}

_halow_mgr_fail() {
    HALOW_MGR_ERR_CODE="$1"
    HALOW_MGR_ERR_DETAIL="$2"
    halow_log_error "manager: $1: $2"
    _halow_mgr_st halow_state_diag_log_append "$1: $2"
    return 1
}

# _halow_mgr_check_stop — acts on a requested stop once no host change is in progress.
# A check point: called only from the manager's own code, never from the signal handler.
_halow_mgr_check_stop() {
    if [ "$HALOW_MGR_STOP_PENDING" -eq 1 ] && [ "$HALOW_MGR_CRITICAL" -eq 0 ] && [ "$HALOW_MGR_STOPPING" -eq 0 ]; then
        _halow_mgr_stop_now
    fi
    return 0
}

# _halow_mgr_beat — refreshes the heartbeat, at most once every HALOW_MGR_BEAT_EVERY_S
# seconds (used inside long waits so the snapshot never looks stale while starting).
_halow_mgr_beat() {
    if [ -n "$HALOW_MGR_LAST_BEAT" ] && [ $((SECONDS - HALOW_MGR_LAST_BEAT)) -lt "$HALOW_MGR_BEAT_EVERY_S" ]; then
        return 0
    fi
    HALOW_MGR_LAST_BEAT="$SECONDS"
    _halow_mgr_st halow_state_heartbeat
    return 0
}

# _halow_mgr_poll_hook — called by the radio library once per poll of the automatic
# channel selection wait: heartbeat and stop check point. Its status is ignored.
_halow_mgr_poll_hook() {
    # The radio library discards the hook's output; a stop acted on here (rollback) must
    # still log, so the manager's own output descriptors are used when they are open.
    if [ -n "$HALOW_MGR_FD_OUT" ] && [ -n "$HALOW_MGR_FD_ERR" ]; then
        { _halow_mgr_beat; _halow_mgr_check_stop; } >&"$HALOW_MGR_FD_OUT" 2>&"$HALOW_MGR_FD_ERR"
    else
        _halow_mgr_beat
        _halow_mgr_check_stop
    fi
    return 0
}

# _halow_mgr_markers_held — 0 when any ownership marker is held (persistent or run
# directory).
_halow_mgr_markers_held() {
    local a b
    a="$(halow_own_list 2>/dev/null || true)"
    b="$(HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_list 2>/dev/null || true)"
    [ -n "$a$b" ]
}

# --- Run directory, process list -----------------------------------------------------

# _halow_mgr_run_dir_is_tmpfs — 0 when HALOW_RUN_DIR is a tmpfs mount point (the last
# mount on that path counts); 1 when it is not; 2 when the mount table cannot be read.
_halow_mgr_run_dir_is_tmpfs() {
    local IFS=$' \t\n' dev mnt fstype rest found=1
    [ -r "$HALOW_PROC_MOUNTS" ] || return 2
    while read -r dev mnt fstype rest; do
        if [ "$mnt" = "$HALOW_RUN_DIR" ]; then
            if [ "$fstype" = "tmpfs" ]; then found=0; else found=1; fi
        fi
    done < "$HALOW_PROC_MOUNTS"
    return "$found"
}

# halow_manager_prepare_run_dir — the manager's first act: mounts a tmpfs on
# HALOW_RUN_DIR (unless it already is one, for example after a restart of the manager
# within the same container), then creates HALOW_RUN_READY_FILE for the status service.
# 0 ready; 1 with HOST_STATE_FAILED recorded (nothing may then be rendered).
halow_manager_prepare_run_dir() {
    local rc
    if ! mkdir -p -- "$HALOW_RUN_DIR" 2>/dev/null; then
        _halow_mgr_fail HOST_STATE_FAILED "the run directory $HALOW_RUN_DIR cannot be created"
        return 1
    fi
    if _halow_mgr_run_dir_is_tmpfs; then rc=0; else rc=$?; fi
    case "$rc" in
        0) halow_log_info "manager: the run directory is already memory-backed" ;;
        1)
            if ! mount -t tmpfs -o "mode=0755,size=${HALOW_RUN_TMPFS_SIZE},nosuid,nodev,noexec" tmpfs "$HALOW_RUN_DIR"; then
                _halow_mgr_fail HOST_STATE_FAILED "a memory-backed filesystem could not be mounted on $HALOW_RUN_DIR; nothing secret is written to disk, so the access point is not started"
                return 1
            fi
            if ! _halow_mgr_run_dir_is_tmpfs; then
                _halow_mgr_fail HOST_STATE_FAILED "the run directory $HALOW_RUN_DIR could not be confirmed memory-backed after mounting"
                return 1
            fi
            ;;
        *)
            _halow_mgr_fail HOST_STATE_FAILED "the mount table cannot be read, so the run directory cannot be confirmed memory-backed"
            return 1
            ;;
    esac
    if ! { : > "$HALOW_RUN_READY_FILE"; } 2>/dev/null; then
        _halow_mgr_fail HOST_STATE_FAILED "the ready file $HALOW_RUN_READY_FILE cannot be created"
        return 1
    fi
    chmod 0644 -- "$HALOW_RUN_READY_FILE" 2>/dev/null || true
    return 0
}

# _halow_mgr_signal_ready_anyway — when the run directory could not be prepared, the
# ready file is still created (best effort) so the status page can explain the problem;
# nothing secret is ever rendered in that state.
_halow_mgr_signal_ready_anyway() {
    mkdir -p -- "$HALOW_RUN_DIR" 2>/dev/null || true
    { : > "$HALOW_RUN_READY_FILE"; } 2>/dev/null || true
    return 0
}

# halow_manager_proc_preflight — 0 when the process list under HALOW_PROC_DIR can be
# listed (it contains at least the manager's own pid). The process-identity scans of
# reconcile and rollback read it; an empty listing would make them report a process as
# confirmed absent, so this fails closed with HOST_STATE_FAILED.
halow_manager_proc_preflight() {
    local d found=0
    for d in "$HALOW_PROC_DIR"/[0-9]*; do
        if [ "${d##*/}" = "$$" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -ne 1 ]; then
        HALOW_MGR_NO_ROLLBACK=1
        _halow_mgr_fail HOST_STATE_FAILED "the process list under $HALOW_PROC_DIR cannot be read, so running processes cannot be identified; nothing is changed on the host"
        return 1
    fi
    return 0
}

# --- Module load intent -------------------------------------------------------------

# _halow_mgr_module_intent <dot11ah|morse> — before a module load: records which kernel
# modules are already loaded (key module_intent_<name>). Rollback and reconcile compare
# the host with it, so a module this add-on loaded is recognised as its own even when the
# load ended before its own record was written (and mac80211's dependency libarc4, which
# is pulled in by the load, is covered by the same before/after comparison).
_halow_mgr_module_intent() {
    local name="$1" present
    if ! present="$(halow_rollback_loaded_modules)"; then
        _halow_mgr_fail MODULE_LOAD_FAILED "the loaded kernel modules cannot be listed before loading $name"
        return 1
    fi
    if ! halow_own_mark "module_intent_${name}" "$present"; then
        _halow_mgr_fail MODULE_LOAD_FAILED "the intent to load $name could not be recorded; nothing was loaded"
        return 1
    fi
    return 0
}

# --- IPv6 ---------------------------------------------------------------------------

# _halow_mgr_ipv6_off <iface> — IPv6 off on the interface (the primary control). When
# that cannot be verified, the IPv6 filter chains (the second control) must be verified
# in force; when neither is, BACKEND_FAILED naming IPv6.
_halow_mgr_ipv6_off() {
    local iface="$1" rc=0
    halow_ipv6_disable "$iface" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    # 2: a temporary writable mount on the switch is held or not confirmed removed. Never
    # the firewall-only fallback then: only the failure to write (1) takes that.
    if [ "$rc" -eq 2 ]; then
        _halow_mgr_fail BACKEND_FAILED "IPv6 could not be disabled on $iface and a temporary writable mount on its switch could not be confirmed removed"
        return 1
    fi
    if halow_fw_ipv6_governed "$HALOW_BRIDGE_NAME"; then
        halow_log_warning "manager: IPv6 could not be disabled on $iface; the IPv6 filter chains are verified in force"
        _halow_mgr_st halow_state_diag_set "ipv6_${iface}" "IPv6 is NOT off on the interface (its kernel switch could not be written); held by the IPv6 filter chains only"
        return 0
    fi
    _halow_mgr_fail BACKEND_FAILED "IPv6 could not be disabled on $iface and the IPv6 filter chains could not be verified"
}

# --- Status-service liveness ----------------------------------------------------------

# The status page is served only to the Supervisor's Ingress proxy, and the status server
# refuses every other peer, including this add-on's own processes on the host network. The
# manager therefore never connects to the status listener: it supervises the service
# directly, with the four checks below, every one of which needs no connection.

# _halow_mgr_read_bounded <file> <max bytes> — puts at most <max bytes> bytes of the file in
# HALOW_MGR_READ_DATA exactly as they are; 1 when the file cannot
# be read or the read does not finish within HALOW_MGR_FILE_READ_TIMEOUT_S seconds. It is
# bounded in size by head and in time by the timeout command, because the status user owns
# the directory of the liveness counter and can put a FIFO (a read of which blocks for ever
# when nobody writes to it) in place of the file between the check of its type and the read.
_halow_mgr_read_bounded() {
    local data rc
    HALOW_MGR_READ_DATA=""
    # The exit status is appended after the bytes (a pipe would hide the status of the
    # timeout). Command substitution removes NUL bytes, so the format checks see only the
    # bytes that remain: a file such as "1<NUL>2" is read as "12" and is accepted when what
    # is left is valid digits. That is an accepted residual: the value is only compared with
    # the previous reading and is never logged, and a writer that can plant NUL bytes is
    # the status user, which already controls the counter.
    { data="$("$HALOW_TIMEOUT_CMD" "$HALOW_MGR_FILE_READ_TIMEOUT_S" head -c "$2" -- "$1" 2>/dev/null; printf 'rc=%s' "$?")"; } 2>/dev/null
    rc="${data##*rc=}"
    [ "$rc" = "0" ] || return 1
    HALOW_MGR_READ_DATA="${data%rc=*}"
}

# _halow_mgr_status_port — prints the status server's recorded listening port (digits only,
# 1 to 65535, leading zeros dropped); 1 when the port file is missing, a symbolic link or
# invalid. At most 16 bytes are read, through the bounded, time-limited reader (the file
# is written by root in the root-only run directory, so this is a second layer).
_halow_mgr_status_port() {
    local port=""
    { [ -f "$HALOW_STATUS_PORT_FILE" ] && [ ! -L "$HALOW_STATUS_PORT_FILE" ]; } || return 1
    _halow_mgr_read_bounded "$HALOW_STATUS_PORT_FILE" 17 || return 1
    port="$HALOW_MGR_READ_DATA"
    [ "${#port}" -le 16 ] || return 1
    port="${port%$'\n'}"
    [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    printf '%s\n' "$((10#$port))"
}

# _halow_mgr_status_s6_pid — prints the pid s6 reports for the running status service; 1
# when it is down, s6-supervise is not running or the output is not as expected. Asks
# `s6-svstat -o up,pid <dir>`, whose output is one line: `true <pid>` for a service that
# is up (also while it is wanted down) and `false -1` for one that is down; with no
# supervisor it prints an error and exits 1 (the error text is never logged). The
# human-readable form (`up (pid N pgid N) 2 seconds, ...`) is not parsed: it has
# changed between s6 releases. Only the exact `true <pid>` form is accepted.
_halow_mgr_status_s6_pid() {
    local out
    out="$("$HALOW_S6_SVSTAT" -o up,pid "$HALOW_S6_STATUS_SERVICE_DIR" 2>/dev/null)" || return 1
    [[ $out =~ ^true\ ([1-9][0-9]{0,9})$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# _halow_mgr_status_uid — prints the numeric uid of the status user; 1 when unknown.
_halow_mgr_status_uid() {
    local uid
    uid="$(id -u "${HALOW_STATUS_USER:-halowstatus}" 2>/dev/null)" || return 1
    [[ $uid =~ ^[0-9]{1,10}$ ]] || return 1
    printf '%s\n' "$uid"
}

# _halow_mgr_status_identity <pid> <port> <uid> — 0 only when the process the s6 state
# names is the status server: its command line (at most 8 KiB read) holds the server
# program as one whole argument and "--port <port>" as consecutive arguments, and its real
# and effective user is the status user. A reused pid, another program, another port, a
# server that did not drop privileges, and an unreadable process entry all return 1.
_halow_mgr_status_identity() {
    local pid="$1" port="$2" uid="$3" dir="$HALOW_PROC_DIR/$1"
    local server="${HALOW_STATUS_SERVER:-${HALOW_LIB_DIR:-/usr/lib/halow}/status/status_server.py}"
    local lines arg prev="" has_server=0 has_port=0 line key ruid euid rest
    [ -r "$dir/cmdline" ] && [ -r "$dir/status" ] || return 1
    lines="$(tr '\0' '\n' < <(head -c 8192 -- "$dir/cmdline" 2>/dev/null) 2>/dev/null)" || return 1
    while IFS= read -r arg; do
        if [ "$arg" = "$server" ]; then has_server=1; fi
        if [ "$prev" = "--port" ] && [ "$arg" = "$port" ]; then has_port=1; fi
        prev="$arg"
    done <<< "$lines"
    [ "$has_server" -eq 1 ] && [ "$has_port" -eq 1 ] || return 1
    lines="$(head -c 8192 -- "$dir/status" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        case "$line" in
            Uid:*)
                read -r key ruid euid rest <<< "$line" || true
                [ "$ruid" = "$uid" ] && [ "$euid" = "$uid" ] && return 0
                return 1
                ;;
        esac
    done <<< "$lines"
    return 1
}

# _halow_mgr_ipv4_hex <dotted quad> — prints the address the way /proc/net/tcp prints it
# (eight upper-case hex digits, the bytes in memory order, which is reversed on a
# little-endian host); 1 when the argument is not a plain IPv4 address.
_halow_mgr_ipv4_hex() {
    local a b c d
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
    printf '%02X%02X%02X%02X\n' "$((10#$d))" "$((10#$c))" "$((10#$b))" "$((10#$a))"
}

# _halow_mgr_status_listening <port> <uid> — 0 only when the kernel's IPv4 TCP table
# (HALOW_PROC_NET_TCP; read, never connected to) holds exactly one socket in LISTEN state
# (0A, remote 0.0.0.0:0) on HALOW_STATUS_BIND:<port> and its owner is <uid>. Reads at most
# HALOW_MGR_TCP_TABLE_MAX_BYTES and looks at no more than HALOW_MGR_TCP_TABLE_MAX_LINES
# lines (the kernel lists listening sockets first). Lines that do not have every field
# of the kernel's format (a truncated last line included) are ignored; several listeners on
# the one address and port are ambiguous and fail. The status server binds an IPv4
# address (the Docker bridge gateway), so only the IPv4 table applies; a bind address that
# is not dotted-quad IPv4 fails.
_halow_mgr_status_listening() {
    local port="$1" uid="$2" want data line lineno=0 found=0 owner="" addr
    local -a f
    addr="$(_halow_mgr_ipv4_hex "${HALOW_STATUS_BIND:-172.30.32.1}")" || return 1
    want="${addr}:$(printf '%04X' "$port")"
    [ -r "$HALOW_PROC_NET_TCP" ] || return 1
    data=""
    IFS= read -r -N "$HALOW_MGR_TCP_TABLE_MAX_BYTES" data < "$HALOW_PROC_NET_TCP" 2>/dev/null || true
    [ -n "$data" ] || return 1
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        [ "$lineno" -le "$HALOW_MGR_TCP_TABLE_MAX_LINES" ] || break
        [ "$lineno" -gt 1 ] || continue
        read -r -a f <<< "$line" || true
        [ "${#f[@]}" -ge 10 ] || continue
        [[ ${f[0]} =~ ^[0-9]{1,7}:$ ]] || continue
        [[ ${f[1]} =~ ^[0-9A-F]{8}:[0-9A-F]{4}$ ]] || continue
        [[ ${f[2]} =~ ^[0-9A-F]{8}:[0-9A-F]{4}$ ]] || continue
        [[ ${f[3]} =~ ^[0-9A-F]{2}$ ]] || continue
        [[ ${f[7]} =~ ^[0-9]{1,10}$ ]] || continue
        if [ "${f[1]}" = "$want" ] && [ "${f[3]}" = "0A" ] && [ "${f[2]}" = "00000000:0000" ]; then
            found=$((found + 1))
            owner="${f[7]}"
        fi
    done <<< "$data"
    [ "$found" -eq 1 ] && [ "$owner" = "$uid" ]
}

# _halow_mgr_status_heartbeat — prints the status server's liveness counter: at most
# HALOW_MGR_HEARTBEAT_MAX_BYTES bytes (one more is read, to see that the file is longer) of
# a regular file (not a symbolic link), accepted only as 1 to 20 decimal digits and an
# optional final newline. Anything else (empty,
# oversized, non-numeric, signed, with leading garbage) returns 1. The value is never
# logged.
_halow_mgr_status_heartbeat() {
    local hb=""
    { [ -f "$HALOW_STATUS_HEARTBEAT_FILE" ] && [ ! -L "$HALOW_STATUS_HEARTBEAT_FILE" ] && [ -r "$HALOW_STATUS_HEARTBEAT_FILE" ]; } || return 1
    # The type checks above are only a first layer (the status user can swap the file after
    # them): the read itself is bounded in size and time.
    _halow_mgr_read_bounded "$HALOW_STATUS_HEARTBEAT_FILE" "$((HALOW_MGR_HEARTBEAT_MAX_BYTES + 1))" || return 1
    hb="$HALOW_MGR_READ_DATA"
    [ "${#hb}" -le "$HALOW_MGR_HEARTBEAT_MAX_BYTES" ] || return 1
    hb="${hb%$'\n'}"
    [[ $hb =~ ^[0-9]{1,20}$ ]] || return 1
    printf '%s\n' "$hb"
}

# _halow_mgr_status_probe — one liveness evaluation. 0 healthy; 1 not, with the reason (a
# fixed phrase, never a value read from a file) in HALOW_MGR_STATUS_WHY. Healthy means all
# of: (1) s6 reports the service up and the pid is the status server running as the status
# user; (2) the recorded port is in LISTEN state on the bind address; (3) the liveness
# counter is readable and valid; (4) the counter differs from the previous reading. The
# first reading for a process (a new pid after a restart, or after any failure of 1 to 3)
# is only a baseline and counts as healthy; a reading equal to the previous one is
# unhealthy. Different, not greater: a counter that starts again after a restart is a change.
_halow_mgr_status_probe() {
    local pid port uid hb
    HALOW_MGR_STATUS_WHY=""
    if ! pid="$(_halow_mgr_status_s6_pid)"; then
        HALOW_MGR_STATUS_WHY="the service is not running"
    elif ! port="$(_halow_mgr_status_port)"; then
        HALOW_MGR_STATUS_WHY="the recorded port is missing or invalid"
    elif ! uid="$(_halow_mgr_status_uid)"; then
        HALOW_MGR_STATUS_WHY="the status user is unknown"
    elif ! _halow_mgr_status_identity "$pid" "$port" "$uid"; then
        HALOW_MGR_STATUS_WHY="the running process is not the status server"
    elif ! _halow_mgr_status_listening "$port" "$uid"; then
        HALOW_MGR_STATUS_WHY="the port is not listening on the expected address"
    elif ! hb="$(_halow_mgr_status_heartbeat)"; then
        HALOW_MGR_STATUS_WHY="the liveness counter is missing or invalid"
    fi
    if [ -n "$HALOW_MGR_STATUS_WHY" ]; then
        HALOW_MGR_STATUS_HB_PID=""
        HALOW_MGR_STATUS_HB_LAST=""
        return 1
    fi
    if [ "$pid" != "$HALOW_MGR_STATUS_HB_PID" ] || [ -z "$HALOW_MGR_STATUS_HB_LAST" ]; then
        HALOW_MGR_STATUS_HB_PID="$pid"
        HALOW_MGR_STATUS_HB_LAST="$hb"
        return 0
    fi
    if [ "$hb" = "$HALOW_MGR_STATUS_HB_LAST" ]; then
        HALOW_MGR_STATUS_WHY="the liveness counter is not advancing"
        return 1
    fi
    HALOW_MGR_STATUS_HB_LAST="$hb"
    return 0
}

# _halow_mgr_status_check — one liveness check of the status service (see
# _halow_mgr_status_probe; no network request is made). HALOW_MGR_STATUS_FAILS_MAX
# consecutive failed checks ask s6 to restart it once and start the count again, and
# forget the counter baseline. With the 30 s ticks and two failures, a hung accept loop
# is restarted about 60 to 90 s after it hangs (the counter may still have changed since
# the last check; then the first unchanged reading comes one check later), plus the time
# s6 takes to restart; a dead or wrong process 30 to 60 s after. Start-up window: the
# service can be up, with its port recorded, before it listens or before its first
# counter value; that is at most one failed check, cleared by the next success, and
# never reaches the failure limit unless the service stays unready for a whole second
# interval. Never an attention state; always returns 0.
_halow_mgr_status_check() {
    local ok=0
    if _halow_mgr_status_probe; then
        ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        HALOW_MGR_STATUS_FAILS=0
        return 0
    fi
    HALOW_MGR_STATUS_FAILS=$((HALOW_MGR_STATUS_FAILS + 1))
    halow_log_warning "manager: the status service did not answer (${HALOW_MGR_STATUS_FAILS} of ${HALOW_MGR_STATUS_FAILS_MAX}): ${HALOW_MGR_STATUS_WHY}"
    if [ "$HALOW_MGR_STATUS_FAILS" -ge "$HALOW_MGR_STATUS_FAILS_MAX" ]; then
        HALOW_MGR_STATUS_FAILS=0
        HALOW_MGR_STATUS_HB_PID=""
        HALOW_MGR_STATUS_HB_LAST=""
        if "$HALOW_S6_SVC" -r "$HALOW_S6_STATUS_SERVICE_DIR" >/dev/null 2>&1; then
            halow_log_warning "manager: the status service was asked to restart"
            _halow_mgr_st halow_state_diag_set status_service "restarted after not answering"
        else
            halow_log_error "manager: the status service could not be asked to restart"
            _halow_mgr_st halow_state_diag_set status_service "not answering; restart request failed"
        fi
    fi
    return 0
}

# _halow_mgr_status_tick <seconds> — accounts waited time; checks when due.
_halow_mgr_status_tick() {
    HALOW_MGR_STATUS_ELAPSED=$((HALOW_MGR_STATUS_ELAPSED + ${1:-1}))
    if [ "$HALOW_MGR_STATUS_ELAPSED" -ge "$HALOW_MGR_STATUS_CHECK_S" ]; then
        HALOW_MGR_STATUS_ELAPSED=0
        _halow_mgr_status_check
    fi
    return 0
}

# _halow_mgr_hostapd_cli <args...> — the hostapd control client, bounded in time.
_halow_mgr_hostapd_cli() {
    "$HALOW_TIMEOUT_CMD" "$HALOW_HOSTAPD_CLI_TIMEOUT_S" "$HALOW_HOSTAPD_CLI" -p "$HALOW_HOSTAPD_CTRL_DIR" -i "$HALOW_IFACE" "$@"
}

# _halow_mgr_run_step <critical:0|1> <step-function>
_halow_mgr_run_step() {
    local critical="$1" step="$2" rc
    _halow_mgr_beat
    HALOW_MGR_PHASE="$step"
    HALOW_MGR_ERR_CODE=""
    HALOW_MGR_ERR_DETAIL=""
    HALOW_MGR_CRITICAL="$critical"
    if "$step"; then
        rc=0
    else
        rc=$?
    fi
    HALOW_MGR_CRITICAL=0
    _halow_mgr_check_stop
    if [ "$rc" -ne 0 ] && [ -z "$HALOW_MGR_ERR_CODE" ]; then
        _halow_mgr_fail INTERNAL_ERROR "the start step ${step#_halow_mgr_step_} failed unexpectedly (status $rc)" || true
    fi
    return "$rc"
}

# _halow_mgr_interruptible <command> [args...] — runs a long wait inside a critical step
# with stop deferral lifted (nothing is being changed during it).
_halow_mgr_interruptible() {
    local saved="$HALOW_MGR_CRITICAL" rc
    HALOW_MGR_CRITICAL=0
    _halow_mgr_check_stop
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    _halow_mgr_check_stop
    HALOW_MGR_CRITICAL="$saved"
    return "$rc"
}

# _halow_mgr_net_values — derives the gateway and the network of the configured subnet.
_halow_mgr_net_values() {
    local gw prefix mask net_i a b c d
    gw="${HALOW_CFG_SUBNET_CIDR%/*}"
    prefix="${HALOW_CFG_SUBNET_CIDR#*/}"
    mask="$(halow_ipv4_mask_from_prefix "$prefix")" || return 1
    net_i=$(( $(halow_ipv4_to_int "$gw") & mask ))
    a=$(( (net_i >> 24) & 255 )); b=$(( (net_i >> 16) & 255 )); c=$(( (net_i >> 8) & 255 )); d=$(( net_i & 255 ))
    HALOW_MGR_GATEWAY="$gw"
    HALOW_MGR_SUBNET_NET="${a}.${b}.${c}.${d}/${prefix}"
}

# halow_manager_ip_forward_check — verify only: 0 when IPv4 forwarding is on. The value is
# never written or restored (the host and its container runtime depend on it).
halow_manager_ip_forward_check() {
    local v
    if ! v="$(cat -- "$HALOW_IP_FORWARD_FILE" 2>/dev/null)"; then
        _halow_mgr_fail HOST_STATE_FAILED "net.ipv4.ip_forward cannot be read"
        return 1
    fi
    v="${v//[[:space:]]/}"
    if [ "$v" != "1" ]; then
        _halow_mgr_fail HOST_STATE_FAILED "net.ipv4.ip_forward is ${v:-empty} on the host; it must be 1 (this add-on never changes it)"
        return 1
    fi
    return 0
}

# --- Start steps ---------------------------------------------------------------------

_halow_mgr_step_reconcile() {
    if halow_refusal_present; then
        halow_log_warning "manager: a refusal is recorded; only rollback is retried"
    fi
    if halow_reconcile; then
        [ -z "${HALOW_RECONCILE_FOREIGN:-}" ] || _halow_mgr_st halow_state_diag_set reconcile_foreign "$HALOW_RECONCILE_FOREIGN"
        [ -z "${HALOW_RECONCILE_NOTES:-}" ] || _halow_mgr_st halow_state_diag_set reconcile_notes "$HALOW_RECONCILE_NOTES"
        return 0
    fi
    halow_refusal_set ROLLBACK_INCOMPLETE || true
    _halow_mgr_fail ROLLBACK_INCOMPLETE "residue from an earlier run could not be confirmed undone: ${HALOW_RECONCILE_RESIDUAL:-unknown}"
}

_halow_mgr_step_options() {
    if ! halow_options_load; then
        _halow_mgr_fail INTERNAL_ERROR "the options could not be read"
        return 1
    fi
    _halow_mgr_st halow_state_region "$HALOW_CFG_REGION"
    _halow_mgr_st halow_state_radio_requested "$HALOW_CFG_RADIO_MODE" "$HALOW_CFG_BANDWIDTH" "$HALOW_CFG_CHANNEL"
    if ! halow_options_validate; then
        _halow_mgr_fail "${HALOW_CFG_ERROR_CODE:-CONFIG_INVALID}" "option ${HALOW_CFG_ERROR_OPTION:-unknown}: ${HALOW_CFG_ERROR_REASON:-invalid}"
        return 1
    fi
    return 0
}

_halow_mgr_step_guard() {
    local rc line
    if halow_guard_check; then
        rc=0
    else
        rc=$?
    fi
    while IFS= read -r line; do
        case "$line" in
            guard_*=*) _halow_mgr_st halow_state_diag_set "${line%%=*}" "${line#*=}" ;;
            *=*) _halow_mgr_st halow_state_diag_set "guard_${line%%=*}" "${line#*=}" ;;
        esac
    done < <(halow_guard_report 2>/dev/null || true)
    case "$rc" in
        0) : ;;
        2) _halow_mgr_fail UNSUPPORTED_KERNEL "${HALOW_GUARD_REASON:-host compatibility could not be determined}"; return 1 ;;
        *) _halow_mgr_fail UNSUPPORTED_KERNEL "${HALOW_GUARD_REASON:-the host kernel is not supported by this build}"; return 1 ;;
    esac
    if ! halow_verify_manifest "${HALOW_ARTIFACTS_DIR}/MANIFEST.sha256" "${HALOW_ARTIFACTS_DIR}"; then
        _halow_mgr_fail FIRMWARE_INVALID "a shipped artifact does not match its recorded checksum"
        return 1
    fi
    return 0
}

_halow_mgr_step_adapter() {
    local rc up
    if halow_adapter_check; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0) : ;;
        2) _halow_mgr_st halow_state_adapter false ""; _halow_mgr_fail NO_ADAPTER "no supported adapter is connected"; return 1 ;;
        3) _halow_mgr_st halow_state_adapter false ""; _halow_mgr_fail MULTIPLE_ADAPTERS "more than one adapter is connected"; return 1 ;;
        4) _halow_mgr_st halow_state_adapter false ""; _halow_mgr_fail NO_ADAPTER "only an unrecognised device is connected"; return 1 ;;
        *) _halow_mgr_fail INTERNAL_ERROR "the adapter check returned an unexpected status ($rc)"; return 1 ;;
    esac
    _halow_mgr_st halow_state_adapter true ""
    HALOW_MGR_UPLINK=""
    HALOW_MGR_UPLINK_DETECTED=0
    if [ -n "$HALOW_CFG_UPLINK" ]; then
        if ! halow_kernel_iface_exists "$HALOW_CFG_UPLINK"; then
            _halow_mgr_fail UPLINK_UNAVAILABLE "the configured uplink interface $HALOW_CFG_UPLINK does not exist"
            return 1
        fi
        HALOW_MGR_UPLINK="$HALOW_CFG_UPLINK"
    else
        if ! up="$(halow_uplink_detect 2>/dev/null)" || [ -z "$up" ]; then
            _halow_mgr_fail UPLINK_UNAVAILABLE "no single default-route uplink interface was found"
            return 1
        fi
        HALOW_MGR_UPLINK="$up"
        HALOW_MGR_UPLINK_DETECTED=1
    fi
    halow_manager_ip_forward_check || return 1
    if ! _halow_mgr_net_values; then
        _halow_mgr_fail CONFIG_INVALID "option halow_subnet_cidr: cannot be interpreted"
        return 1
    fi
    return 0
}

_halow_mgr_step_firewall() {
    if ! halow_fw_install_filters "$HALOW_BRIDGE_NAME" "$HALOW_MGR_SUBNET_NET" "$HALOW_MGR_GATEWAY" "$HALOW_MGR_UPLINK" "$HALOW_CFG_ALLOWED_PORTS"; then
        _halow_mgr_fail BACKEND_FAILED "the firewall filter chains could not be installed"
        return 1
    fi
    return 0
}

# Step 7: driver and firmware. The call lines below are the earlier build's, unchanged.
_halow_mgr_step_driver() {
    local _status _installed_slug _fw_main_sha _fw_bcf_sha _dmesg_watermark _dmesg_new
    KO_DOT11AH="${HALOW_ARTIFACTS_DIR}/dot11ah.ko"
    KO_MORSE="${HALOW_ARTIFACTS_DIR}/morse.ko"
    if ! DOT11AH_SCHEME="$(halow_radio_scheme "$HALOW_CFG_REGION")" || [ -z "$DOT11AH_SCHEME" ]; then
        _halow_mgr_fail REGION_UNVALIDATED "no channelisation scheme for region $HALOW_CFG_REGION"
        return 1
    fi
    export HALOW_MM_VENDOR_ID="$HALOW_ADAPTER_VENDOR_ID" HALOW_MM_PRODUCT_ID="$HALOW_ADAPTER_PRODUCT_ID"

    _halow_mgr_module_intent dot11ah || return 1
    if halow_load_dot11ah "$KO_DOT11AH" "$DOT11AH_SCHEME"; then
        _status=0
    else
        _status=$?
    fi
    if [ "$_status" -eq 3 ]; then
        halow_log_error "manager: EMERGENCY — dot11ah may remain loaded, untracked; manual host intervention may be required"
        _halow_mgr_fail MODULE_LOAD_FAILED "dot11ah module load / channelization-scheme confirmation failed (untracked residual)"
        return 1
    elif [ "$_status" -ne 0 ]; then
        _halow_mgr_fail MODULE_LOAD_FAILED "dot11ah module load / channelization-scheme confirmation failed"
        return 1
    fi

    # The host-absolute equivalent of this container's /data is derived from the
    # container's hostname (the Supervisor names it after the repository-qualified slug)
    # and refused if it does not look like this add-on's own slug.
    if [ -z "${HALOW_FW_SEARCH_DIR_HOST:-}" ]; then
        if ! _installed_slug="$(halow_derive_installed_slug)"; then
            _halow_mgr_fail HOST_STATE_FAILED "could not derive this add-on's own installed slug from its container hostname"
            return 1
        fi
        case "$_installed_slug" in
            *morse_micro_halow_ap)
                halow_log_info "manager: derived installed app slug '$_installed_slug' from this container's own hostname"
                ;;
            *)
                _halow_mgr_fail HOST_STATE_FAILED "derived installed slug '$_installed_slug' does not look like this add-on's own config slug (morse_micro_halow_ap); refusing to guess a firmware search-path host directory from it"
                return 1
                ;;
        esac
        export HALOW_FW_SEARCH_DIR_HOST="${HALOW_SUPERVISOR_SHARE_HOST}/apps/data/${_installed_slug}/halow_fw"
    fi
    halow_log_info "manager: firmware search-path host directory resolved to $HALOW_FW_SEARCH_DIR_HOST"

    if ! _fw_main_sha="$(halow_checksum_for "$HALOW_FW_MAIN_NAME")"; then
        _halow_mgr_fail FIRMWARE_INVALID "no manifest entry for $HALOW_FW_MAIN_NAME"
        return 1
    fi
    if ! _fw_bcf_sha="$(halow_checksum_for "bcf/$HALOW_FW_BCF_NAME")"; then
        _halow_mgr_fail FIRMWARE_INVALID "no manifest entry for bcf/$HALOW_FW_BCF_NAME"
        return 1
    fi

    if halow_place_firmware "${HALOW_ARTIFACTS_DIR}/${HALOW_FW_MAIN_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" "$_fw_main_sha" "firmware_main" "firmware_dir"; then
        _status=0
    else
        _status=$?
    fi
    [ "$_status" -eq 1 ] && { _halow_mgr_fail FIRMWARE_INVALID "firmware placement failed for $HALOW_FW_MAIN_NAME"; return 1; }
    if halow_place_firmware "${HALOW_ARTIFACTS_DIR}/bcf/${HALOW_FW_BCF_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}" "$_fw_bcf_sha" "firmware_bcf" "firmware_dir"; then
        _status=0
    else
        _status=$?
    fi
    [ "$_status" -eq 1 ] && { _halow_mgr_fail FIRMWARE_INVALID "firmware placement failed for $HALOW_FW_BCF_NAME"; return 1; }

    if halow_set_firmware_search_path "$HALOW_FW_SEARCH_DIR_HOST"; then
        _status=0
    else
        _status=$?
    fi
    if [ "$_status" -eq 3 ]; then
        halow_log_error "manager: CRITICAL — /sys could not be confirmed restored to its own prior mount mode; it may remain writable on this host"
        _halow_mgr_fail HOST_STATE_FAILED "could not point the host kernel's firmware search path at $HALOW_FW_SEARCH_DIR_HOST (CRITICAL: /sys mount mode unconfirmed)"
        return 1
    elif [ "$_status" -ne 0 ]; then
        _halow_mgr_fail HOST_STATE_FAILED "could not point the host kernel's firmware search path at $HALOW_FW_SEARCH_DIR_HOST"
        return 1
    fi

    # Load morse; the board-file match is confirmed only in the kernel-log records written
    # after a marker (the newest record) taken immediately before this load -- never the
    # whole log, and never a line count (see halow_dmesg_watermark in common.sh) -- and
    # only by the driver's own "Loaded BCF from <name>, size, crc32" record matching the
    # board file placed above.
    # The readers run in command substitutions, so they pass their reason back in a file.
    HALOW_KLOG_REASON_FILE="${HALOW_RUN_DIR}/klog_reason"
    rm -f -- "$HALOW_KLOG_REASON_FILE" 2>/dev/null || true
    if ! _dmesg_watermark="$(halow_dmesg_watermark)"; then
        _halow_mgr_fail HOST_STATE_FAILED "cannot take a usable kernel-log marker before loading the driver ($(_halow_mgr_klog_reason)) — the BCF match could not be confirmed afterwards"
        return 1
    fi
    _halow_mgr_module_intent morse || return 1
    if halow_load_morse "$KO_MORSE"; then
        _status=0
    else
        _status=$?
    fi
    if [ "$_status" -eq 3 ]; then
        halow_log_error "manager: EMERGENCY — a kernel module this add-on loaded may remain loaded, untracked; see the module-load: UNTRACKED RESIDUAL log line immediately above for exactly which one; manual host intervention may be required"
        _halow_mgr_fail MODULE_LOAD_FAILED "morse/mac80211 module load failed (untracked residual — see the log line above for which module)"
        return 1
    elif [ "$_status" -ne 0 ]; then
        _halow_mgr_fail MODULE_LOAD_FAILED "morse module load failed"
        return 1
    fi
    if ! _dmesg_new="$(halow_dmesg_since "$_dmesg_watermark")"; then
        _halow_mgr_fail HOST_STATE_FAILED "cannot establish the kernel-log records of this driver load ($(_halow_mgr_klog_reason)) — BCF match not confirmed (no-match stop condition)"
        return 1
    fi
    if ! halow_check_bcf_match "$_dmesg_new" "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}"; then
        _halow_mgr_fail FIRMWARE_INVALID "BCF match not confirmed in the driver log produced by this load: ${HALOW_BCF_REASON:-no reason recorded} (no-match stop condition)"
        return 1
    fi

    # The search-path override is global host state: restore it as soon as it is no
    # longer needed; a failed restore is retried by rollback and shown in diagnostics.
    if halow_restore_firmware_search_path; then
        _status=0
    else
        _status=$?
    fi
    if [ "$_status" -eq 3 ]; then
        halow_log_error "manager: CRITICAL — /sys could not be confirmed restored to its own prior mount mode after this restore attempt; it may remain writable on this host — will keep retrying on rollback"
        _halow_mgr_st halow_state_diag_set fw_search_path_restore "not restored: /sys could not be confirmed back in its prior mount mode; retried on rollback"
    elif [ "$_status" -eq 4 ]; then
        halow_log_error "manager: CRITICAL — an ownership record could not be written during the firmware search-path restore (not a /sys mount-mode problem) — will keep retrying on rollback"
        _halow_mgr_st halow_state_diag_set fw_search_path_restore "not restored: an ownership record could not be written; retried on rollback"
    elif [ "$_status" -ne 0 ]; then
        halow_log_error "manager: could not restore the host firmware search path to its prior value — will keep retrying on rollback"
        _halow_mgr_st halow_state_diag_set fw_search_path_restore "not restored to its prior value (status $_status); retried on rollback"
    else
        _halow_mgr_st halow_state_diag_set fw_search_path_restore "restored after the board-file match"
    fi
    return 0
}

# _halow_mgr_netdev_wait — waits for the adapter's interface in slices (heartbeat and stop
# check point between slices) up to HALOW_ADAPTER_NETDEV_TIMEOUT_S. Only the waiting
# function's output (the interface name) is discarded; its log lines and anything a stop
# check point runs stay visible.
_halow_mgr_netdev_wait() {
    local total="$HALOW_ADAPTER_NETDEV_TIMEOUT_S" waited=0 slice
    while :; do
        slice="$HALOW_MGR_WAIT_SLICE_S"
        [ $((waited + slice)) -le "$total" ] || slice=$((total - waited))
        [ "$slice" -ge 1 ] || slice=1
        if halow_adapter_netdev_wait "$slice" >/dev/null; then
            return 0
        fi
        waited=$((waited + slice))
        [ "$waited" -lt "$total" ] || return 1
        _halow_mgr_beat
        _halow_mgr_check_stop
    done
}

_halow_mgr_step_iface() {
    if ! _halow_mgr_interruptible _halow_mgr_netdev_wait; then
        _halow_mgr_fail MODULE_LOAD_FAILED "the adapter's network interface did not appear after the driver loaded"
        return 1
    fi
    if ! HALOW_IFACE="$(halow_adapter_netdev)" || [ -z "$HALOW_IFACE" ]; then
        _halow_mgr_fail MODULE_LOAD_FAILED "the adapter has no network interface"
        return 1
    fi
    if ! halow_verify_parent_iface "$HALOW_IFACE" "$HALOW_ADAPTER_VENDOR_ID" "$HALOW_ADAPTER_PRODUCT_ID" "${HALOW_SYS_CLASS_NET_DIR:-/sys/class/net}"; then
        _halow_mgr_fail MODULE_LOAD_FAILED "could not verify $HALOW_IFACE is the intended Wi-Fi HaLow adapter's own network interface"
        return 1
    fi
    _halow_mgr_st halow_state_adapter true "$HALOW_IFACE"
    # Now that the interface name is known, the filter chains get the catch-all drops for
    # it and every per-station interface derived from it, so a radio interface that is not
    # (yet) a bridge port is never ungoverned.
    if ! halow_fw_install_filters "$HALOW_BRIDGE_NAME" "$HALOW_MGR_SUBNET_NET" "$HALOW_MGR_GATEWAY" "$HALOW_MGR_UPLINK" "$HALOW_CFG_ALLOWED_PORTS" "$HALOW_IFACE"; then
        _halow_mgr_fail BACKEND_FAILED "the firewall catch-all for $HALOW_IFACE could not be installed"
        return 1
    fi
    _halow_mgr_ipv6_off "$HALOW_IFACE" || return 1
    # The parent is marked unmanaged before hostapd ever starts (strict).
    halow_nm_mark_unmanaged "$HALOW_IFACE" "nm_unmanaged_parent" \
        || { _halow_mgr_fail NM_CHECK_FAILED "could not mark $HALOW_IFACE NetworkManager-unmanaged via D-Bus"; return 1; }
    return 0
}

_halow_mgr_step_bridge() {
    if ! halow_bridge_create "$HALOW_BRIDGE_NAME"; then
        _halow_mgr_fail BACKEND_FAILED "the private bridge $HALOW_BRIDGE_NAME could not be created"
        return 1
    fi
    _halow_mgr_ipv6_off "$HALOW_BRIDGE_NAME" || return 1
    # Tolerant: a bridge NetworkManager does not track (the host configuration may
    # already exclude bridges) is an accepted outcome.
    if ! halow_nm_mark_unmanaged_if_known "$HALOW_BRIDGE_NAME" "nm_unmanaged_bridge"; then
        _halow_mgr_fail NM_CHECK_FAILED "could not mark $HALOW_BRIDGE_NAME NetworkManager-unmanaged via D-Bus"
        return 1
    fi
    return 0
}

# _halow_mgr_isolate — client isolation on every port of the bridge; BACKEND_FAILED when
# a port can neither be isolated nor removed.
_halow_mgr_isolate() {
    if halow_bridge_enforce_isolation "$HALOW_BRIDGE_NAME"; then
        return 0
    fi
    _halow_mgr_fail BACKEND_FAILED "client isolation could not be enforced on every port of $HALOW_BRIDGE_NAME"
}

# _halow_mgr_uint_or <value> <default> <max> — the value when it is a plain unsigned
# integer of at most 4 digits that does not exceed <max>, else the default; a bad or
# excessive override never makes a bound unbounded or a wait very long.
_halow_mgr_uint_or() {
    local v
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2"; return 0 ;;
    esac
    [ "${#1}" -le 4 ] || { printf '%s' "$2"; return 0; }
    v=$((10#$1))
    if [ "$v" -le "$3" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# _halow_mgr_pause <seconds> — a bounded wait in one-second steps; the heartbeat is
# refreshed and a requested stop acted on between steps. Run it through
# _halow_mgr_interruptible (nothing is being changed during it).
_halow_mgr_pause() {
    local n="${1:-0}" i=0
    while [ "$i" -lt "$n" ]; do
        halow_manager_sleep 1
        i=$((i + 1))
        _halow_mgr_beat
        _halow_mgr_check_stop
    done
    return 0
}

# _halow_mgr_acs_survey_failed <hostapd log> — 0 when hostapd_s1g's own log carries exactly
# the empty-survey message of automatic channel selection (acs.c acs_study_survey_based:
# no channel was surveyed at all). The log is read, never printed.
_halow_mgr_acs_survey_failed() {
    [ -r "${1:-}" ] && grep -q -F 'ACS: Unable to collect survey data' -- "$1" 2>/dev/null
}

# _halow_mgr_survey_retry <hostapd log> — called after hostapd_s1g ended with the
# empty-survey message while its log still exists. DEFENSIVE TIMING MITIGATION (see the
# constants above). Returns 0 when one more bounded launch has been prepared (the first
# failure of the attempt gets a failure record, hostapd_s1g is stopped through the
# lifecycle scope, and the radio is given HALOW_ACS_SURVEY_SETTLE_S seconds), 1 when the
# bound is exhausted (nothing was changed; the caller reports the failure as it always
# did, so a persistent failure is never hidden), 2 when hostapd_s1g could not be stopped
# (the failure is already recorded as AP_START_FAILED).
HALOW_MGR_SURVEY_TRIES=0
_halow_mgr_survey_retry() {
    local log="${1:-}" limit settle
    limit="$(_halow_mgr_uint_or "$HALOW_ACS_SURVEY_RETRIES" 2 5)"
    settle="$(_halow_mgr_uint_or "$HALOW_ACS_SURVEY_SETTLE_S" 3 30)"
    [ "$HALOW_MGR_SURVEY_TRIES" -lt "$limit" ] || return 1
    HALOW_MGR_SURVEY_TRIES=$((HALOW_MGR_SURVEY_TRIES + 1))
    # One record for the first failure only: later launches of the same attempt would push
    # the evidence of the first out of the three-record ring.
    if [ "$HALOW_MGR_SURVEY_TRIES" -eq 1 ]; then
        _halow_mgr_failure_record acs_survey_retry "$log"
    fi
    halow_log_warning "manager: automatic channel selection could not collect survey data (hostapd_s1g ended); launching it again after ${settle}s (retry ${HALOW_MGR_SURVEY_TRIES} of ${limit})"
    if ! halow_rollback_hostapd_scope halow_stop_hostapd; then
        _halow_mgr_fail AP_START_FAILED "hostapd_s1g could not be stopped before the automatic channel selection retry"
        return 2
    fi
    _halow_mgr_interruptible _halow_mgr_pause "$settle"
    return 0
}

# _halow_mgr_ap_start <mode:automatic|manual|fallback> <channel-or-empty>
# In automatic mode an exit with the empty-survey message is launched again up to
# HALOW_ACS_SURVEY_RETRIES more times (bounded; see _halow_mgr_survey_retry); every other
# failure, and the exhaustion of the bound, is the same AP_START_FAILED as before.
_halow_mgr_ap_start() {
    local mode="$1" channel="$2" log="${HALOW_RUN_DIR}/hostapd_s1g.log" rc rr
    while :; do
        if _halow_mgr_ap_start_once "$mode" "$channel"; then
            return 0
        else
            rc=$?
        fi
        [ "$rc" -eq 4 ] || return "$rc"
        if _halow_mgr_survey_retry "$log"; then
            continue
        else
            rr=$?
        fi
        [ "$rr" -eq 1 ] || return 1
        # One failure record per attempt: the first failure of the attempt is already
        # recorded by the retry; a second record would push earlier evidence out of the ring.
        [ "$HALOW_MGR_SURVEY_TRIES" -gt 0 ] || _halow_mgr_failure_record start_exit "$log"
        if [ "$HALOW_MGR_SURVEY_TRIES" -gt 0 ]; then
            _halow_mgr_fail AP_START_FAILED "hostapd_s1g failed to start (automatic channel selection could not collect survey data; ${HALOW_MGR_SURVEY_TRIES} bounded retries did not help)"
        else
            _halow_mgr_fail AP_START_FAILED "hostapd_s1g failed to start (automatic channel selection could not collect survey data)"
        fi
        return 1
    done
}

# _halow_mgr_ap_start_once <mode> <channel> — one launch. Returns 0 started, 1 failed (the
# failure is recorded), 4 hostapd_s1g ended with the empty-survey message in automatic mode
# (its log still exists; the caller decides between a retry and the usual failure).
_halow_mgr_ap_start_once() {
    local mode="$1" channel="$2" conf="${HALOW_RUN_DIR}/hostapd_s1g.conf" log="${HALOW_RUN_DIR}/hostapd_s1g.log" old_umask rc
    mkdir -p -- "$HALOW_RUN_DIR" 2>/dev/null || true
    HALOW_MGR_HOSTAPD_PID=""
    if ! halow_rollback_hostapd_scope halow_hostapd_pre_start_check "$conf"; then
        _halow_mgr_fail AP_START_FAILED "could not establish hostapd_s1g lifecycle ownership"
        return 1
    fi
    old_umask="$(umask)"
    umask 077
    if halow_radio_render "$HALOW_CFG_REGION" "$mode" "$HALOW_CFG_BANDWIDTH" "$channel" "$HALOW_IFACE" "$HALOW_CFG_WIFI_SSID" "$HALOW_CFG_WIFI_PASSPHRASE" "$HALOW_BRIDGE_NAME" "$HALOW_CFG_MAX_STATIONS" "$conf"; then
        rc=0
    else
        rc=$?
    fi
    umask "$old_umask"
    if [ "$rc" -ne 0 ]; then
        _halow_mgr_fail AP_START_FAILED "the access point configuration could not be rendered ($mode)"
        return 1
    fi
    # A plain statement in this shell (never inside a command substitution): the started
    # pid comes back in HALOW_LAST_STARTED_PID.
    if ! halow_rollback_hostapd_scope halow_start_hostapd "${HALOW_ARTIFACTS_DIR}/hostapd_s1g" "$log" "$conf"; then
        # The empty-survey exit is handed to the caller before anything is recorded or
        # reported: it may be launched again (bounded), and the caller records and
        # reports the failure itself when it is not.
        if [ "$mode" = "automatic" ] && _halow_mgr_acs_survey_failed "$log"; then
            return 4
        fi
        _halow_mgr_failure_record start_exit "$log"
        _halow_mgr_fail AP_START_FAILED "hostapd_s1g failed to start"
        return 1
    fi
    HALOW_MGR_HOSTAPD_PID="${HALOW_LAST_STARTED_PID:-}"
    return 0
}

# _halow_mgr_acs_wait — waits for automatic channel selection in slices of
# HALOW_MGR_ACS_SLICE_S up to HALOW_ACS_TIMEOUT_S in total. The radio library calls the
# poll hook once per poll (heartbeat and stop check point), and only a completion on a
# channel of the configured width counts. Returns halow_radio_acs_wait's codes
# (0 completed, 1 failed, 2 timeout, 3 hostapd exited).
_halow_mgr_acs_wait() {
    local log="${HALOW_RUN_DIR}/hostapd_s1g.log" waited=0 slice rc
    local HALOW_RADIO_POLL_HOOK=_halow_mgr_poll_hook
    # Copies of this shell's output for the poll hook (see _halow_mgr_poll_hook).
    exec {HALOW_MGR_FD_OUT}>&1 {HALOW_MGR_FD_ERR}>&2
    rc=2
    while [ "$waited" -lt "$HALOW_ACS_TIMEOUT_S" ]; do
        slice="$HALOW_MGR_ACS_SLICE_S"
        [ $((waited + slice)) -le "$HALOW_ACS_TIMEOUT_S" ] || slice=$((HALOW_ACS_TIMEOUT_S - waited))
        if halow_radio_acs_wait "$log" "$HALOW_MGR_HOSTAPD_PID" "$slice" "$HALOW_CFG_REGION" 0 "$HALOW_CFG_BANDWIDTH"; then
            rc=0
        else
            rc=$?
        fi
        [ "$rc" -eq 2 ] || break
        waited=$((waited + slice))
        _halow_mgr_st halow_state_heartbeat
        _halow_mgr_check_stop
    done
    exec {HALOW_MGR_FD_OUT}>&- {HALOW_MGR_FD_ERR}>&-
    HALOW_MGR_FD_OUT=""
    HALOW_MGR_FD_ERR=""
    return "$rc"
}

# _halow_mgr_ap_enabled_wait — waits for AP-ENABLED in slices (heartbeat and stop check
# point between slices) up to HALOW_AP_ENABLED_TIMEOUT_S. 0 enabled; 1 timeout; 2 hostapd
# exited.
_halow_mgr_ap_enabled_wait() {
    local log="${HALOW_RUN_DIR}/hostapd_s1g.log" total="$HALOW_AP_ENABLED_TIMEOUT_S" waited=0 slice rc
    while :; do
        slice="$HALOW_MGR_WAIT_SLICE_S"
        [ $((waited + slice)) -le "$total" ] || slice=$((total - waited))
        [ "$slice" -ge 1 ] || slice=1
        if halow_wait_for_pattern "$log" "AP-ENABLED" "$slice" "$HALOW_MGR_HOSTAPD_PID"; then
            return 0
        else
            rc=$?
        fi
        [ "$rc" -eq 1 ] || return "$rc"
        waited=$((waited + slice))
        [ "$waited" -lt "$total" ] || return 1
        _halow_mgr_beat
        _halow_mgr_check_stop
    done
}

_halow_mgr_step_radio() {
    local rc rr settle fb why fb_ok=0
    HALOW_MGR_RADIO_SOURCE=""
    HALOW_MGR_RADIO_CHANNEL=""
    # The previous attempt's results are not this attempt's.
    _halow_mgr_st halow_state_diag_set acs_result ""
    _halow_mgr_st halow_state_diag_set radio_effective ""
    _halow_mgr_st halow_state_diag_set radio_primary_derived ""
    if [ "$HALOW_CFG_RADIO_MODE" = "automatic" ]; then
        # The configuration asks hostapd for automatic selection; a saved channel is
        # never passed.
        # DEFENSIVE TIMING MITIGATION (see the constants): a short settle between the
        # host handing the radio interface over (NetworkManager-unmanaged, a moment ago)
        # and the first automatic-selection scan.
        HALOW_MGR_SURVEY_TRIES=0
        settle="$(_halow_mgr_uint_or "$HALOW_ACS_PRESTART_SETTLE_S" 3 30)"
        if [ "$settle" -gt 0 ]; then
            halow_log_info "manager: letting the radio interface settle for ${settle}s before automatic channel selection"
            _halow_mgr_interruptible _halow_mgr_pause "$settle"
        fi
        while :; do
            _halow_mgr_ap_start automatic "" || return 1
            if _halow_mgr_interruptible _halow_mgr_acs_wait; then
                rc=0
            else
                rc=$?
            fi
            # hostapd_s1g ended (or reported failure) after the scan returned no survey
            # data: a bounded relaunch before the fallback channel is considered.
            if { [ "$rc" -eq 1 ] || [ "$rc" -eq 3 ]; } && _halow_mgr_acs_survey_failed "${HALOW_RUN_DIR}/hostapd_s1g.log"; then
                if _halow_mgr_survey_retry "${HALOW_RUN_DIR}/hostapd_s1g.log"; then
                    continue
                else
                    rr=$?
                fi
                [ "$rr" -eq 1 ] || return 1
            fi
            break
        done
        if [ "$rc" -eq 0 ]; then
            HALOW_MGR_RADIO_SOURCE="acs"
            HALOW_MGR_RADIO_CHANNEL="${HALOW_ACS_CHANNEL:-}"
            halow_log_info "manager: automatic channel selection completed (channel ${HALOW_MGR_RADIO_CHANNEL:-unknown})"
            _halow_mgr_st halow_state_diag_set acs_result "completed"
        else
            case "$rc" in
                1) why="failed" ;;
                2) why="timed out after ${HALOW_ACS_TIMEOUT_S}s" ;;
                3) why="ended because hostapd_s1g exited" ;;
                *) why="returned status $rc" ;;
            esac
            # One record per failed attempt: when the fallback start follows, a failure of
            # that start leaves its own record, and a second one for the same attempt would
            # push the first attempt's record out of the ring. The record of the selection
            # exit is therefore kept only when no fallback start will run.
            fb_ok=0
            if fb="$(halow_radio_fallback_channel "$HALOW_CFG_REGION" "$HALOW_CFG_BANDWIDTH")" && [ -n "$fb" ]; then fb_ok=1; fi
            if [ "$rc" -eq 3 ] && [ "$fb_ok" -ne 1 ]; then
                _halow_mgr_failure_record acs_hostapd_exited
            fi
            halow_log_warning "manager: automatic channel selection $why${HALOW_ACS_REASON:+ ($HALOW_ACS_REASON)}; starting the fallback channel"
            _halow_mgr_st halow_state_diag_set acs_result "$why${HALOW_ACS_REASON:+: $HALOW_ACS_REASON}"
            if ! halow_rollback_hostapd_scope halow_stop_hostapd; then
                _halow_mgr_fail AP_START_FAILED "hostapd_s1g could not be stopped after automatic channel selection $why"
                return 1
            fi
            if [ "$fb_ok" -ne 1 ]; then
                _halow_mgr_fail AP_START_FAILED "automatic channel selection $why and there is no fallback channel for ${HALOW_CFG_BANDWIDTH} MHz"
                return 1
            fi
            # The fallback is used for this run only; it is never recorded as a
            # selection result, and selection runs again at the next start.
            _halow_mgr_ap_start fallback "$fb" || return 1
            HALOW_MGR_RADIO_SOURCE="fallback"
            HALOW_MGR_RADIO_CHANNEL="$fb"
        fi
    else
        _halow_mgr_ap_start manual "$HALOW_CFG_CHANNEL" || return 1
        HALOW_MGR_RADIO_SOURCE="manual"
        HALOW_MGR_RADIO_CHANNEL="$HALOW_CFG_CHANNEL"
    fi

    if _halow_mgr_interruptible _halow_mgr_ap_enabled_wait; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0) halow_log_info "manager: AP-ENABLED on $HALOW_IFACE (channel source: $HALOW_MGR_RADIO_SOURCE)" ;;
        2) _halow_mgr_failure_record exited_before_ap_enabled; _halow_mgr_fail AP_START_FAILED "hostapd_s1g exited before reaching AP-ENABLED"; return 1 ;;
        *) _halow_mgr_failure_record ap_enabled_timeout; _halow_mgr_fail AP_START_FAILED "hostapd_s1g did not reach AP-ENABLED within ${HALOW_AP_ENABLED_TIMEOUT_S}s"; return 1 ;;
    esac
    # hostapd has added its interface to the bridge itself: isolation on every port now
    # (the supervision loop keeps enforcing it on every tick).
    _halow_mgr_isolate || return 1
    if [ "$HALOW_MGR_RADIO_SOURCE" = "fallback" ]; then
        _halow_mgr_st halow_state_advisory RADIO_AUTO_FALLBACK
    fi
    return 0
}

# _halow_mgr_record_primary <channel> - engineering diagnostics only. Derives the primary
# channel configuration from the profile table (no runtime tool, nothing read from the
# radio) and records it under a key and a prefix that say so. It is deliberately not in the
# status snapshot or on the status page: those show only values read back from the access
# point. Best effort: never changes the outcome.
_halow_mgr_record_primary() {
    declare -F halow_radio_primary_info >/dev/null 2>&1 || return 0
    halow_radio_primary_info "$HALOW_CFG_REGION" "$HALOW_CFG_BANDWIDTH" "${1:-}" 2>/dev/null || return 0
    _halow_mgr_st halow_state_diag_set radio_primary_derived "configured/derived from the profile table, NOT read from the radio: op_class=$HALOW_PRIM_OP_CLASS channel=$HALOW_PRIM_CHANNEL width_mhz=$HALOW_PRIM_WIDTH_MHZ centre_khz=$HALOW_PRIM_CENTRE_KHZ primary_bandwidth_mhz=$HALOW_PRIM_BW_MHZ primary_index=$HALOW_PRIM_INDEX primary_1mhz_channel=${HALOW_PRIM_1MHZ_CHANNEL:-none} primary_1mhz_khz=${HALOW_PRIM_1MHZ_KHZ:-none}"
    return 0
}

_halow_mgr_step_effective() {
    local out validation fb_state fb_validated="none" why
    if ! halow_radio_capture_effective "$HALOW_TIMEOUT_CMD" "$HALOW_HOSTAPD_CLI_TIMEOUT_S" "$HALOW_HOSTAPD_CLI" -p "$HALOW_HOSTAPD_CTRL_DIR" -i "$HALOW_IFACE" >/dev/null 2>&1; then
        # Values that cannot be read are not a mismatch: the access point stays up, the
        # effective values stay unset (the page shows the configured values as requested
        # only) and the reason is recorded. Only a readable disagreement is a mismatch.
        why="${HALOW_EFF_REASON:-the status output could not be read}"
        [ "${HALOW_EFF_STATE:-}" != "unavailable" ] || why="the status output lacks the expected radio fields"
        halow_log_warning "manager: the running access point's radio values could not be read ($why); they stay unconfirmed"
        _halow_mgr_st halow_state_diag_set radio_effective "unconfirmed: $why"
        return 0
    fi
    # Called in this shell (not a command substitution): on success it refines
    # HALOW_EFF_CHANNEL; its one-line reason goes to a file.
    out="${HALOW_RUN_DIR}/radio_check.out"
    if ! halow_radio_check_effective "$HALOW_CFG_REGION" "$HALOW_CFG_BANDWIDTH" "$HALOW_MGR_RADIO_CHANNEL" > "$out" 2>/dev/null; then
        _halow_mgr_fail RADIO_MISMATCH "$(head -n 1 "$out" 2>/dev/null || true)"
        [ -n "$HALOW_MGR_ERR_DETAIL" ] || HALOW_MGR_ERR_DETAIL="the running access point does not match the selected radio profile"
        return 1
    fi
    validation="$(halow_radio_width_state "$HALOW_CFG_REGION" "$HALOW_CFG_BANDWIDTH" 2>/dev/null || true)"
    case "$validation" in
        implemented|live-validated) : ;;
        *) validation="implemented" ;;
    esac
    if [ "$HALOW_MGR_RADIO_SOURCE" = "fallback" ]; then
        fb_state="$(halow_radio_fallback_state "$HALOW_CFG_REGION" "$HALOW_CFG_BANDWIDTH" 2>/dev/null || true)"
        if [ "$fb_state" = "live-validated" ]; then fb_validated="true"; else fb_validated="false"; fi
    fi
    _halow_mgr_st halow_state_radio_effective "${HALOW_EFF_FREQ_KHZ:-}" "${HALOW_EFF_CHANNEL:-$HALOW_MGR_RADIO_CHANNEL}" "${HALOW_EFF_BW_MHZ:-$HALOW_CFG_BANDWIDTH}" "$HALOW_MGR_RADIO_SOURCE" "$validation" "$fb_validated"
    _halow_mgr_st halow_state_diag_set radio_effective "confirmed"
    _halow_mgr_record_primary "${HALOW_EFF_CHANNEL:-$HALOW_MGR_RADIO_CHANNEL}"
    return 0
}

# _halow_mgr_backend_fail <kind> <detail> — a backend hard failure: NM_CHECK_FAILED when
# the kind is "nm" (NetworkManager could not be made to leave an interface alone),
# BACKEND_FAILED otherwise. The kind comes from the backend contract
# (HALOW_BACKEND_FAIL_KIND, the operation just made) or, for station faults, from the
# station lifecycle's sticky first-fault kind (HALOW_ST_FAULT_KIND).
_halow_mgr_backend_fail() {
    if [ "${1:-}" = "nm" ]; then
        _halow_mgr_fail NM_CHECK_FAILED "$2 (NetworkManager could not be made to leave a HaLow interface unmanaged)"
    else
        _halow_mgr_fail BACKEND_FAILED "$2"
    fi
}

_halow_mgr_step_backend() {
    HALOW_BACKEND_FAIL_KIND=""
    if ! halow_backend_call configure "bridge=$HALOW_BRIDGE_NAME" "subnet=$HALOW_CFG_SUBNET_CIDR" "dhcp_start=$HALOW_CFG_DHCP_START" "dhcp_end=$HALOW_CFG_DHCP_END" "uplink=$HALOW_MGR_UPLINK" "parent=$HALOW_IFACE" "max_stations=$HALOW_CFG_MAX_STATIONS"; then
        _halow_mgr_fail BACKEND_FAILED "the bridge backend rejected its configuration"
        return 1
    fi
    if ! halow_backend_call attach bridge "$HALOW_BRIDGE_NAME"; then
        _halow_mgr_backend_fail "${HALOW_BACKEND_FAIL_KIND:-}" "the bridge backend could not be attached (address, DHCP or NAT)"
        return 1
    fi
    _halow_mgr_st halow_state_backend true "$HALOW_BRIDGE_NAME" "$HALOW_MGR_SUBNET_NET" "$HALOW_MGR_GATEWAY"
    # The station lifecycle: the backend is already attached to the bridge (above), so the
    # first event pass takes the bridge as its attachment. The log is rotated through
    # hostapd's control interface.
    if declare -F halow_st_reset >/dev/null 2>&1; then
        halow_st_reset "${HALOW_RUN_DIR}/hostapd_s1g.log" "$HALOW_IFACE" "$HALOW_BRIDGE_NAME"
        declare -ga HALOW_ST_RELOG_CMD=("$HALOW_TIMEOUT_CMD" "$HALOW_HOSTAPD_CLI_TIMEOUT_S" "$HALOW_HOSTAPD_CLI" -p "$HALOW_HOSTAPD_CTRL_DIR" -i "$HALOW_IFACE" relog)
    fi
    return 0
}

# _halow_mgr_station_pass — one station-event pass (log rotation included when the
# station library offers it).
_halow_mgr_station_pass() {
    if declare -F halow_st_poll >/dev/null 2>&1; then
        halow_st_poll
    else
        halow_st_process_log
    fi
}

# _halow_mgr_all_sta — hands hostapd's all_sta listing to the station library (the
# authorised flag refines the online state); silently skipped when unavailable.
_halow_mgr_all_sta() {
    local out
    declare -F halow_st_set_all_sta >/dev/null 2>&1 || return 0
    # A call that cannot be made or fails forgets the last answer, so a stale authorised
    # flag never outlives the call that read it: the station view then says plainly that
    # the online state comes from the connection log (online_source "log").
    if [ ! -x "$HALOW_HOSTAPD_CLI" ]; then
        halow_st_set_all_sta "" || true
        return 0
    fi
    if out="$(_halow_mgr_hostapd_cli all_sta 2>/dev/null)"; then
        halow_st_set_all_sta "$out" valid || true
    else
        halow_st_set_all_sta "" || true
    fi
    return 0
}

# _halow_mgr_attempt — steps 1 to 12. 0 when operating; 1 with HALOW_MGR_ERR_* set.
_halow_mgr_attempt() {
    local step
    HALOW_IFACE=""
    HALOW_MGR_NO_ROLLBACK=0
    _halow_mgr_st halow_state_clear_advisory
    # The process list must be readable before reconcile relies on it.
    _halow_mgr_run_step 0 halow_manager_proc_preflight || return 1
    # Reconcile undoes residue (a host change, so a stop waits for it); the next three
    # steps only read.
    _halow_mgr_run_step 1 _halow_mgr_step_reconcile || return 1
    for step in options guard adapter; do
        _halow_mgr_run_step 0 "_halow_mgr_step_$step" || return 1
    done
    for step in firewall driver iface bridge radio effective backend; do
        _halow_mgr_run_step 1 "_halow_mgr_step_$step" || return 1
    done
    _halow_mgr_st halow_state_clear_attention
    _halow_mgr_st halow_state_overall operating
    _halow_mgr_st halow_state_heartbeat
    halow_log_info "manager: operating (bridge $HALOW_BRIDGE_NAME, uplink $HALOW_MGR_UPLINK, channel source $HALOW_MGR_RADIO_SOURCE)"
    return 0
}

# _halow_mgr_supervise — step 13. Returns 1 with HALOW_MGR_ERR_* set when the running
# stack fails.
_halow_mgr_supervise() {
    local tick=0 rc snap="${HALOW_RUN_DIR}/stations.snapshot" stable_done=0
    HALOW_MGR_PHASE="supervise"
    while :; do
        _halow_mgr_check_stop
        if ! _halow_mgr_station_pass; then
            halow_log_error "manager: a station event could not be handled; continuing"
        fi
        if [ "${HALOW_ST_FAULT:-0}" -ne 0 ]; then
            _halow_mgr_backend_fail "${HALOW_ST_FAULT_KIND:-}" "a station could not be served: ${HALOW_ST_FAULT_MSG:-station operation failed}"
            return 1
        fi
        if ! halow_manager_pid_alive "$HALOW_MGR_HOSTAPD_PID"; then
            _halow_mgr_failure_record died_while_operating
            _halow_mgr_fail AP_DIED "hostapd_s1g exited while operating"
            return 1
        fi
        # hostapd adds per-station ports to the bridge itself: isolation is enforced on
        # every port at every tick, independent of the station events.
        _halow_mgr_isolate || return 1
        if [ $((tick % HALOW_MGR_SNAPSHOT_EVERY)) -eq 0 ]; then
            _halow_mgr_all_sta
            if halow_stations_snapshot_lines > "$snap" 2>/dev/null; then
                _halow_mgr_st halow_state_stations_set "$snap"
            fi
            _halow_mgr_st halow_state_heartbeat
            if ! halow_dnsmasq_ensure_running; then
                _halow_mgr_fail BACKEND_FAILED "the DHCP and DNS service stopped and could not be restarted"
                return 1
            fi
            if ! halow_adapter_present; then
                _halow_mgr_st halow_state_adapter false ""
                _halow_mgr_fail NO_ADAPTER "the adapter was disconnected"
                return 1
            fi
            if halow_adapter_check; then rc=0; else rc=$?; fi
            if [ "$rc" -eq 3 ]; then
                _halow_mgr_fail MULTIPLE_ADAPTERS "a second adapter was connected"
                return 1
            fi
            if [ "$HALOW_MGR_UPLINK_DETECTED" -eq 1 ]; then
                if halow_uplink_changed "$HALOW_MGR_UPLINK"; then
                    _halow_mgr_fail UPLINK_UNAVAILABLE "the uplink interface $HALOW_MGR_UPLINK changed or was lost"
                    return 1
                fi
            elif ! halow_kernel_iface_exists "$HALOW_MGR_UPLINK"; then
                _halow_mgr_fail UPLINK_UNAVAILABLE "the configured uplink interface $HALOW_MGR_UPLINK disappeared"
                return 1
            fi
        fi
        if [ $((tick % HALOW_MGR_HEALTH_EVERY)) -eq 0 ] && [ "$tick" -gt 0 ]; then
            if ! halow_backend_call health; then
                _halow_mgr_fail BACKEND_FAILED "the bridge backend reported a problem"
                return 1
            fi
        fi
        if [ $((tick % HALOW_MGR_REASSERT_EVERY)) -eq 0 ] && [ "$tick" -gt 0 ]; then
            # Fail closed: without its chains and jumps the access point must not serve.
            if ! halow_fw_reassert; then
                _halow_mgr_fail BACKEND_FAILED "the firewall chains are not in force (a chain is missing or a jump could not be restored)"
                return 1
            fi
        fi
        if [ "$stable_done" -eq 0 ] && [ "$tick" -ge "$HALOW_MGR_STABLE_S" ]; then
            if [ "$HALOW_MGR_AP_FAILS" -ne 0 ]; then
                halow_log_info "manager: operating for ${HALOW_MGR_STABLE_S}s; the access-point failure count is reset"
            fi
            HALOW_MGR_AP_FAILS=0
            stable_done=1
        fi
        tick=$((tick + 1))
        halow_manager_sleep 1
        _halow_mgr_status_tick 1
    done
}

# --- Failure, attention and stop ---------------------------------------------------------

# _halow_mgr_handle_failure — rolls back exactly what was recorded and sets attention with
# a truthful host_clean. A rollback that cannot be confirmed turns the error into
# ROLLBACK_INCOMPLETE (the original error kept in the detail) and persists the refusal.
_halow_mgr_handle_failure() {
    local code="${HALOW_MGR_ERR_CODE:-INTERNAL_ERROR}" detail="${HALOW_MGR_ERR_DETAIL:-unexpected failure}"
    if ! halow_error_known "$code" 2>/dev/null; then
        detail="unknown error code $code: $detail"
        code="INTERNAL_ERROR"
    fi
    _halow_mgr_st halow_state_clear_advisory
    _halow_mgr_st halow_state_radio_clear_effective
    _halow_mgr_st halow_state_backend false "" "" ""
    HALOW_MGR_ORIG_CODE="$code"
    HALOW_MGR_ORIG_DETAIL="$detail"
    # A stop signal during this rollback is deferred until it has finished.
    HALOW_MGR_CRITICAL=1
    if [ "$code" = "ROLLBACK_INCOMPLETE" ]; then
        # Raised by reconcile, which has just tried rollback itself.
        HALOW_MGR_ORIG_CODE=""
        HALOW_MGR_ORIG_DETAIL=""
        HALOW_MGR_HOST_CLEAN="false"
    elif [ "$HALOW_MGR_NO_ROLLBACK" -eq 1 ]; then
        # Nothing was changed in this attempt and a rollback could not be trusted (it
        # identifies processes through the unreadable process list): the host is called
        # clean only when nothing at all is recorded.
        if _halow_mgr_markers_held; then HALOW_MGR_HOST_CLEAN="false"; else HALOW_MGR_HOST_CLEAN="true"; fi
    elif halow_rollback; then
        HALOW_MGR_HOST_CLEAN="true"
    else
        HALOW_MGR_HOST_CLEAN="false"
        detail="after $code ($detail) the rollback could not be confirmed; still present: ${HALOW_ROLLBACK_RESIDUAL:-unknown}"
        code="ROLLBACK_INCOMPLETE"
        halow_refusal_set ROLLBACK_INCOMPLETE || true
    fi
    HALOW_MGR_CRITICAL=0
    HALOW_MGR_ERR_CODE="$code"
    HALOW_MGR_ERR_DETAIL="$detail"
    _halow_mgr_st halow_state_attention "$code" "$detail" "$HALOW_MGR_HOST_CLEAN"
    halow_log_error "manager: attention required: $code (host clean: $HALOW_MGR_HOST_CLEAN)"
    _halow_mgr_check_stop
    return 0
}

# _halow_mgr_wait <seconds> — waits in attention, refreshing the heartbeat.
_halow_mgr_wait() {
    local left="${1:-1}" step
    while [ "$left" -gt 0 ]; do
        step="$HALOW_MGR_HOLD_TICK_S"
        [ "$step" -le "$left" ] || step="$left"
        halow_manager_sleep "$step"
        left=$((left - step))
        _halow_mgr_st halow_state_heartbeat
        _halow_mgr_check_stop
        _halow_mgr_status_tick "$step"
    done
}

# _halow_mgr_hold — stays in attention until the stop signal (never returns).
_halow_mgr_hold() {
    halow_log_warning "manager: staying in attention until the add-on is restarted"
    while :; do
        _halow_mgr_wait "$HALOW_MGR_HOLD_TICK_S"
    done
}

# _halow_mgr_retry_rollback — ROLLBACK_INCOMPLETE: retries only rollback and verification
# (through reconcile) with backoff. Returns 0 when the host is confirmed clean and a new
# attempt may follow; holds (never returns) when the original error is not retryable.
_halow_mgr_retry_rollback() {
    local n=0 wait_s orig="$HALOW_MGR_ORIG_CODE" orig_detail="$HALOW_MGR_ORIG_DETAIL" class
    while :; do
        n=$((n + 1))
        wait_s="$(halow_backoff_next "$n" 2>/dev/null)" || wait_s=5
        _halow_mgr_wait "$wait_s"
        HALOW_MGR_CRITICAL=1
        if halow_reconcile; then
            HALOW_MGR_CRITICAL=0
            _halow_mgr_check_stop
            break
        fi
        HALOW_MGR_CRITICAL=0
        _halow_mgr_check_stop
        _halow_mgr_st halow_state_attention ROLLBACK_INCOMPLETE "rollback retry $n: still present: ${HALOW_RECONCILE_RESIDUAL:-unknown}" false
    done
    HALOW_MGR_HOST_CLEAN="true"
    if [ -z "$orig" ]; then
        return 0
    fi
    _halow_mgr_st halow_state_attention "$orig" "$orig_detail" true
    class="$(halow_lifecycle_retry_class "$orig")"
    case "$class" in
        recoverable) return 0 ;;
        bounded) halow_lifecycle_should_retry "$orig" "$HALOW_MGR_AP_FAILS" && return 0 ;;
    esac
    _halow_mgr_hold
}

# halow_manager_on_stop — the TERM/INT handler. It only records the request; the
# manager acts on it at its next check point (see this file's header). Nothing else is
# done here: a handler can run inside an interrupted builtin (for example a `read` with a
# temporary field separator), where a rollback would not behave as written.
halow_manager_on_stop() {
    HALOW_MGR_STOP_PENDING=1
    if [ "$HALOW_MGR_STOPPING" -eq 0 ] && [ "$HALOW_MGR_CRITICAL" -eq 1 ]; then
        halow_log_warning "manager: stop requested; finishing the current step (${HALOW_MGR_PHASE#_halow_mgr_step_}) first"
    fi
    return 0
}

_halow_mgr_stop_now() {
    local IFS=$' \t\n'
    HALOW_MGR_STOPPING=1
    HALOW_MGR_STOP_PENDING=0
    halow_log_warning "manager: stop signal received, rolling back"
    if declare -F halow_failure_record_clear >/dev/null 2>&1; then halow_failure_record_clear || true; fi
    _halow_mgr_st halow_state_clear_advisory
    _halow_mgr_st halow_state_radio_clear_effective
    _halow_mgr_st halow_state_backend false "" "" ""
    if halow_rollback; then
        _halow_mgr_st halow_state_diag_set last_stop "rolled back cleanly"
        _halow_mgr_st halow_state_flush
        halow_manager_exit 0
    else
        halow_refusal_set ROLLBACK_INCOMPLETE || true
        _halow_mgr_st halow_state_attention ROLLBACK_INCOMPLETE "the rollback at stop could not be confirmed; still present: ${HALOW_ROLLBACK_RESIDUAL:-unknown}" false
        halow_log_error "manager: rollback did not fully complete on stop — see the rollback: INCOMPLETE line above"
        halow_manager_exit 1
    fi
}

# _halow_mgr_init — 0 ready; 1 with HALOW_MGR_ERR_* set (the manager then holds).
_halow_mgr_init() {
    local fn missing="" bid
    # First act: the memory-backed run directory and the ready file.
    if ! halow_manager_prepare_run_dir; then
        # The ready file follows the attention snapshot (halow_manager_main).
        mkdir -p -- "$HALOW_STATE_DIR" 2>/dev/null || true
        _halow_mgr_st halow_state_init
        return 1
    fi
    mkdir -p -- "$HALOW_STATE_DIR" 2>/dev/null || true
    _halow_mgr_st halow_state_init
    if bid="$(halow_boot_id_current 2>/dev/null)"; then
        _halow_mgr_st halow_state_diag_set boot_id "$bid"
    fi
    for fn in $HALOW_MGR_REQUIRED_FUNCS; do
        declare -F "$fn" >/dev/null 2>&1 || missing="${missing}${fn} "
    done
    if [ -n "$missing" ]; then
        _halow_mgr_fail INTERNAL_ERROR "this build is missing required functions: ${missing% }"
        return 1
    fi
    if ! halow_backend_register_default; then
        _halow_mgr_fail INTERNAL_ERROR "the networking backend could not be registered"
        return 1
    fi
    return 0
}

# halow_manager_main — the long-lived loop. Never returns on its own; the stop handler
# exits the process.
halow_manager_main() {
    local class wait_s attempt=0
    halow_log_info "manager: starting"
    if ! _halow_mgr_init; then
        # Nothing was changed; the host is called clean only when nothing is recorded.
        if _halow_mgr_markers_held; then HALOW_MGR_HOST_CLEAN="false"; else HALOW_MGR_HOST_CLEAN="true"; fi
        _halow_mgr_st halow_state_attention "${HALOW_MGR_ERR_CODE:-INTERNAL_ERROR}" "$HALOW_MGR_ERR_DETAIL" "$HALOW_MGR_HOST_CLEAN"
        # Written after the attention snapshot, so the status page can explain it (the
        # snapshot holds no secret; nothing is ever rendered in this state).
        [ -e "$HALOW_RUN_READY_FILE" ] || _halow_mgr_signal_ready_anyway
        _halow_mgr_hold
    fi
    while :; do
        HALOW_MGR_ATTEMPT=$((HALOW_MGR_ATTEMPT + 1))
        HALOW_MGR_ERR_CODE=""
        HALOW_MGR_ERR_DETAIL=""
        if _halow_mgr_attempt; then
            attempt=0
            if _halow_mgr_supervise; then
                :
            fi
        fi
        _halow_mgr_check_stop
        [ -n "$HALOW_MGR_ERR_CODE" ] || _halow_mgr_fail INTERNAL_ERROR "the manager left its run loop without a reason" || true
        _halow_mgr_handle_failure
        class="$(halow_lifecycle_retry_class "$HALOW_MGR_ERR_CODE")"
        case "$class" in
            recoverable)
                attempt=$((attempt + 1))
                wait_s="$(halow_backoff_next "$attempt" 2>/dev/null)" || wait_s=5
                halow_log_info "manager: retrying in ${wait_s}s (${HALOW_MGR_ERR_CODE}, attempt $attempt)"
                _halow_mgr_wait "$wait_s"
                ;;
            bounded)
                HALOW_MGR_AP_FAILS=$((HALOW_MGR_AP_FAILS + 1))
                if halow_lifecycle_should_retry "$HALOW_MGR_ERR_CODE" "$HALOW_MGR_AP_FAILS"; then
                    wait_s="$(halow_backoff_next "$HALOW_MGR_AP_FAILS" 2>/dev/null)" || wait_s=5
                    halow_log_info "manager: retrying in ${wait_s}s (${HALOW_MGR_ERR_CODE}, consecutive failure $HALOW_MGR_AP_FAILS of $HALOW_AP_RETRY_LIMIT)"
                    _halow_mgr_wait "$wait_s"
                else
                    _halow_mgr_hold
                fi
                ;;
            rollback)
                if [ "$(halow_lifecycle_retry_class "$HALOW_MGR_ORIG_CODE")" = "bounded" ]; then
                    HALOW_MGR_AP_FAILS=$((HALOW_MGR_AP_FAILS + 1))
                fi
                _halow_mgr_retry_rollback
                ;;
            *)
                _halow_mgr_hold
                ;;
        esac
    done
}
