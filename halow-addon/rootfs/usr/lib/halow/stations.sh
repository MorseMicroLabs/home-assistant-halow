#!/usr/bin/env bash
# halow: the station lifecycle in the core.
#
# hostapd reports every association on its own log. This file turns those lines into
# station events and hands each one to the registered backend through the contract
# (backend.sh); it never names a networking implementation. It serves ANY NUMBER of
# stations, arriving and leaving in any order, of BOTH kinds:
#
#   - a four-address station gets its own per-station interface (<parent>.sta<N>), which
#     hostapd announces with WDS-STA-INTERFACE-ADDED; that interface is its port
#     (kind `wds`);
#   - a station for which no interface is announced within HALOW_ST_ORDINARY_WAIT_S
#     seconds (default 3) of its association is an ORDINARY station on the parent
#     interface (kind `ordinary`, port = the parent);
#   - an ordinary station whose interface is announced later is rebound to it exactly
#     once (one further station_added on the new port; the backend treats that as a move
#     and counts the station once).
#
# A station is identified by its MAC address. An interface announcement may come before
# or after its station; announcements that name the station (sta_addr=<mac>, as the
# shipped hostapd prints them) pair by MAC, others pair in order of arrival.
#
# How the manager drives this file:
#   halow_st_reset <hostapd_log> <parent_iface> [<bridge>]
#   halow_st_attach <bridge>          attach the backend to the bridge, ONCE, at start
#                                     (before any station is processed; the access point
#                                     comes up with zero stations). NetworkManager handling
#                                     of the parent and the bridge is the manager's job;
#                                     per-station interfaces are handled by the backend.
#                                     A caller that attached the backend itself
#                                     (halow_backend_call attach bridge <bridge>) may skip
#                                     this: the first halow_st_process_log then takes the
#                                     bridge given to halow_st_reset (default
#                                     HALOW_BRIDGE_NAME) as the attachment.
#   halow_st_poll                     each supervision tick: bounded log rotation, then
#                                     every new log line (halow_st_process_log)
#   halow_st_set_all_sta <text>       optional: the output of `hostapd_cli all_sta`; the
#                                     authorised flag in it overrides the log-derived
#                                     online state in the snapshot
#   halow_stations_snapshot_lines     the station records (see that function) for every known station
#   halow_st_check_health             keep the healthy marker honest
#
# Strict error semantics: any non-zero return from a backend station operation other than
# 10 is a HARD error. It records a sticky fault (HALOW_ST_FAULT, HALOW_ST_FAULT_MSG and
# HALOW_ST_FAULT_KIND: "nm" when the backend reported that NetworkManager could not be
# kept away from an interface, else "other"; the first fault is kept until
# halow_st_reset) and withdraws the healthy marker; 10 means "not served" and is not a
# fault. After each pass the recorded fault is also left in the contract's
# HALOW_BACKEND_FAIL_KIND and HALOW_BACKEND_FAIL_DETAIL.
#
# Bounded log: halow_st_rotate_log_if_large moves the log aside, asks hostapd to reopen
# its log file (the control-interface RELOG command), drains the moved file completely
# and removes it, so no event is lost or read twice. The command used for RELOG is the
# array HALOW_ST_RELOG_CMD (for example: hostapd_cli -p <ctrl dir> -i <iface> relog);
# when it is empty and HALOW_HOSTAPD_CLI is set, "$HALOW_HOSTAPD_CLI -i <parent> relog"
# is used; with neither, the log is not rotated.

: "${HALOW_ST_ORDINARY_WAIT_S:=3}"
: "${HALOW_ST_LOG_MAX_BYTES:=1048576}"

# halow_st_reset <hostapd_log_file> <parent_iface> [<bridge>]
# (Re)initialise all state. Arrays are declared global because this file is normally
# sourced from inside a function.
halow_st_reset() {
    declare -gA HALOW_ST_IFACE=()      # station mac -> bound port ("" while unknown)
    declare -gA HALOW_ST_KIND=()       # station mac -> wds | ordinary (last known)
    declare -gA HALOW_ST_STATE=()      # station mac -> associated | offline
    declare -gA HALOW_ST_CHANGED_AT=() # station mac -> epoch seconds of its last connection event (connect or disconnect)
    declare -gA HALOW_ST_CONNECTED_AT=() # station mac -> epoch seconds of its latest connection, while associated
    declare -gA HALOW_ST_ASSOC_AT=()   # station mac -> epoch seconds of its association
    declare -gA HALOW_ST_SERVED=()     # station mac -> 1 backend serves it, 0 it does not
    declare -gA HALOW_ST_PREPAIR=()    # station mac -> interface announced before it associated
    declare -gA HALOW_ST_ALLSTA=()     # station mac -> true|false from the last all_sta text
    HALOW_ST_ALLSTA_VALID=0
    HALOW_ST_PENDING_IFACES=""         # announced interfaces not yet paired with a station
    HALOW_ST_AWAITING_MACS=""          # associated stations with no port yet
    HALOW_ST_ATTACHMENT=""             # the bridge the backend is attached to
    HALOW_ST_ATTACHMENT_LOST=0         # kept for callers; the bridge model never sets it
    HALOW_ST_HEALTH_REPORTED=1
    HALOW_ST_FAULT=0                   # 1 after a backend station operation failed hard (sticky)
    HALOW_ST_FAULT_MSG=""              # the first fault's message (kept while the fault is sticky)
    HALOW_ST_FAULT_KIND=""             # the first fault's kind: nm (NetworkManager) | other
    HALOW_ST_HEALTH_TICK=0
    HALOW_ST_LOG_FILE="${1:-}"
    HALOW_ST_PARENT="${2:-}"
    HALOW_ST_BRIDGE="${3:-${HALOW_BRIDGE_NAME:-}}"
    HALOW_ST_LOG_LINES=0
    HALOW_ST_ROTATE_WARNED=0
    if ! declare -p HALOW_ST_RELOG_CMD >/dev/null 2>&1; then
        declare -ga HALOW_ST_RELOG_CMD=()
    fi
}

# Seam for tests (the clock used for last-seen and the ordinary-station wait).
halow_st_now() { date +%s; }

# halow_st_attach <bridge>
# Attach the registered backend to the bridge. Returns 0, or 1 (the backend's own return
# code is logged; 10 is a failure here too: the core attaches exactly once).
halow_st_attach() {
    local bridge="${1:-$HALOW_ST_BRIDGE}" rc
    if [ -n "$HALOW_ST_ATTACHMENT" ]; then
        halow_log_error "stations: the backend is already attached to $HALOW_ST_ATTACHMENT"
        return 1
    fi
    if [ -z "$bridge" ]; then
        halow_log_error "stations: no bridge to attach the backend to"
        return 1
    fi
    if halow_backend_call attach bridge "$bridge"; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        halow_log_error "stations: the backend could not attach to $bridge (return $rc)"
        return 1
    fi
    HALOW_ST_ATTACHMENT="$bridge"
    HALOW_ST_BRIDGE="$bridge"
    halow_log_info "stations: the backend is attached to $bridge"
    return 0
}

# halow_st_parse_event <log line>
# Sets HALOW_ST_EV_KIND (station_added | station_removed | iface_added | iface_removed),
# HALOW_ST_EV_MAC and HALOW_ST_EV_IFACE. Returns 0 for a recognised event, 1 otherwise.
halow_st_parse_event() {
    local line="$1" mac_re='([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})'
    HALOW_ST_EV_KIND="" HALOW_ST_EV_MAC="" HALOW_ST_EV_IFACE=""
    case "$line" in
        *AP-STA-CONNECTED*)
            HALOW_ST_EV_KIND="station_added"
            [[ "${line#*AP-STA-CONNECTED}" =~ $mac_re ]] || return 1
            ;;
        *AP-STA-DISCONNECTED*)
            HALOW_ST_EV_KIND="station_removed"
            [[ "${line#*AP-STA-DISCONNECTED}" =~ $mac_re ]] || return 1
            ;;
        *WDS-STA-INTERFACE-ADDED*)
            HALOW_ST_EV_KIND="iface_added"
            ;;
        *WDS-STA-INTERFACE-REMOVED*)
            HALOW_ST_EV_KIND="iface_removed"
            ;;
        *) return 1 ;;
    esac
    if [ "$HALOW_ST_EV_KIND" = "station_added" ] || [ "$HALOW_ST_EV_KIND" = "station_removed" ]; then
        HALOW_ST_EV_MAC="${BASH_REMATCH[1],,}"
        return 0
    fi
    # interface events: ifname=<name>, optionally sta_addr=<mac> (what hostapd_s1g prints);
    # sta= and addr= are accepted too.
    local rest="${line#*WDS-STA-INTERFACE-}" tok toks=()
    read -r -a toks <<< "$rest" || true
    for tok in "${toks[@]}"; do
        case "$tok" in
            ifname=*) HALOW_ST_EV_IFACE="${tok#ifname=}" ;;
            sta_addr=*|sta=*|addr=*)
                if [[ "${tok#*=}" =~ ^$mac_re$ ]]; then HALOW_ST_EV_MAC="${BASH_REMATCH[1],,}"; fi
                ;;
            *) ;;
        esac
    done
    [ -n "$HALOW_ST_EV_IFACE" ] || return 1
    halow_validate_iface_name "$HALOW_ST_EV_IFACE" || return 1
    return 0
}

# halow_st_remove_word <list> <item> — print <list> without <item>.
halow_st_remove_word() {
    local list="$1" item="$2" w out=""
    for w in $list; do
        [ "$w" = "$item" ] || out="${out}${out:+ }${w}"
    done
    printf '%s' "$out"
}

# halow_st_fault <message> [<kind:nm|other>]
# A station operation failed hard: record a sticky fault and withdraw the healthy marker.
# The FIRST fault is kept (message and kind) until halow_st_reset: later passes, whether
# they succeed or fail, never clear or overwrite it.
halow_st_fault() {
    if [ "${HALOW_ST_FAULT:-0}" -ne 1 ]; then
        HALOW_ST_FAULT_MSG="$1"
        HALOW_ST_FAULT_KIND="${2:-other}"
    fi
    HALOW_ST_FAULT=1
    halow_log_error "stations: $1"
    halow_report_unhealthy
    HALOW_ST_HEALTH_REPORTED=0
}

# _halow_st_backend_reason — ": <detail>" from the backend's last failure (empty if none).
_halow_st_backend_reason() {
    local d="${HALOW_BACKEND_FAIL_DETAIL:-}"
    [ -n "$d" ] && printf ': %s' "$d"
    return 0
}

# _halow_st_backend_kind — the backend's failure kind (nm|other).
_halow_st_backend_kind() {
    case "${HALOW_BACKEND_FAIL_KIND:-}" in nm) printf 'nm' ;; *) printf 'other' ;; esac
}

# _halow_st_republish_fault — after a pass, leave the recorded fault's kind and reason in
# the backend's failure variables too, so a caller that reads those after the pass sees
# the fault that matters (later successful calls in the same pass reset them).
_halow_st_republish_fault() {
    if [ "${HALOW_ST_FAULT:-0}" -eq 1 ]; then
        HALOW_BACKEND_FAIL_KIND="${HALOW_ST_FAULT_KIND:-other}"
        HALOW_BACKEND_FAIL_DETAIL="${HALOW_ST_FAULT_MSG:-}"
    fi
    return 0
}

# halow_st_report_added <mac> <port>
# Tell the backend a station is reachable on <port> and record whether it serves it.
halow_st_report_added() {
    local mac="$1" port="$2" rc
    if halow_backend_call station_added "$port" "$mac"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) HALOW_ST_SERVED["$mac"]=1 ;;
        "$HALOW_BACKEND_RC_LIMIT")
            HALOW_ST_SERVED["$mac"]=0
            halow_log_warning "stations: the backend does not serve station $mac on $port"
            ;;
        *)
            HALOW_ST_SERVED["$mac"]=0
            halow_st_fault "the backend failed to add station $mac on $port (return $rc)$(_halow_st_backend_reason)" "$(_halow_st_backend_kind)"
            return 1
            ;;
    esac
    return 0
}

# halow_st_report_removed <mac> <port>
# Tell the backend a station (or its port) is gone. Returns 1 on a backend hard error,
# after recording the fault; the caller has already cleared its own state.
halow_st_report_removed() {
    local mac="$1" port="$2" rc
    if halow_backend_call station_removed "$port" "$mac"; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        halow_st_fault "the backend failed to remove station $mac from $port (return $rc)$(_halow_st_backend_reason)" "$(_halow_st_backend_kind)"
        return 1
    fi
    return 0
}

# halow_st_bind_wds <mac> <iface>
# Bind a station to its own per-station interface. The name must be <parent>.sta<N> and
# exist in the kernel: a name taken from a log line alone is never trusted. Returns 0, or
# 1 (refused, or the backend failed hard).
halow_st_bind_wds() {
    local mac="$1" iface="$2" rest
    rest="${iface#"${HALOW_ST_PARENT}".sta}"
    if [ "$rest" = "$iface" ] || ! [[ "$rest" =~ ^[0-9]+$ ]] || ! halow_kernel_iface_exists "$iface"; then
        halow_log_error "stations: '$iface' is not an existing ${HALOW_ST_PARENT}.sta<N> interface; not binding station $mac to it"
        # An associated station without a port keeps waiting (its own interface, or the
        # parent once the ordinary-station wait has passed).
        if [ "${HALOW_ST_STATE[$mac]:-}" = "associated" ] && [ -z "${HALOW_ST_IFACE[$mac]:-}" ]; then
            case " $HALOW_ST_AWAITING_MACS " in
                *" $mac "*) ;;
                *) HALOW_ST_AWAITING_MACS="${HALOW_ST_AWAITING_MACS}${HALOW_ST_AWAITING_MACS:+ }$mac" ;;
            esac
        fi
        return 1
    fi
    HALOW_ST_AWAITING_MACS="$(halow_st_remove_word "$HALOW_ST_AWAITING_MACS" "$mac")"
    if [ "${HALOW_ST_KIND[$mac]:-}" = "ordinary" ] && [ "${HALOW_ST_IFACE[$mac]:-}" = "$HALOW_ST_PARENT" ]; then
        halow_log_info "stations: station $mac (ordinary until now) has its own interface $iface; moving it there"
    fi
    HALOW_ST_IFACE["$mac"]="$iface"
    HALOW_ST_KIND["$mac"]="wds"
    halow_st_report_added "$mac" "$iface" || return 1
    return 0
}

# halow_st_bind_ordinary <mac> — serve a station on the parent interface.
halow_st_bind_ordinary() {
    local mac="$1"
    HALOW_ST_AWAITING_MACS="$(halow_st_remove_word "$HALOW_ST_AWAITING_MACS" "$mac")"
    HALOW_ST_IFACE["$mac"]="$HALOW_ST_PARENT"
    HALOW_ST_KIND["$mac"]="ordinary"
    halow_log_info "stations: station $mac has no own interface after ${HALOW_ST_ORDINARY_WAIT_S}s; serving it on $HALOW_ST_PARENT"
    halow_st_report_added "$mac" "$HALOW_ST_PARENT" || return 1
    return 0
}

# halow_st_dispatch — act on the event halow_st_parse_event just recognised.
# Returns 0, or 1 on a failure.
halow_st_dispatch() {
    local mac="$HALOW_ST_EV_MAC" iface="$HALOW_ST_EV_IFACE" now first pre bound gone rm_failed=0
    now="$(halow_st_now)"
    case "$HALOW_ST_EV_KIND" in
        station_added)
            if [ "${HALOW_ST_STATE[$mac]:-}" != "associated" ]; then HALOW_ST_CONNECTED_AT["$mac"]="$now"; fi
            HALOW_ST_STATE["$mac"]="associated"
            HALOW_ST_CHANGED_AT["$mac"]="$now"
            if [ -n "${HALOW_ST_IFACE[$mac]:-}" ]; then
                # Repeated association with a known port: report it again (the backend's
                # answer, not a stale one, decides whether it is served).
                halow_st_report_added "$mac" "${HALOW_ST_IFACE[$mac]}" || return 1
                return 0
            fi
            HALOW_ST_ASSOC_AT["$mac"]="$now"
            pre="${HALOW_ST_PREPAIR[$mac]:-}"
            if [ -n "$pre" ]; then
                unset 'HALOW_ST_PREPAIR[$mac]'
                halow_st_bind_wds "$mac" "$pre" || return 1
                return 0
            fi
            first="${HALOW_ST_PENDING_IFACES%% *}"
            if [ -n "$first" ]; then
                HALOW_ST_PENDING_IFACES="$(halow_st_remove_word "$HALOW_ST_PENDING_IFACES" "$first")"
                halow_st_bind_wds "$mac" "$first" || return 1
            else
                case " $HALOW_ST_AWAITING_MACS " in
                    *" $mac "*) ;;
                    *) HALOW_ST_AWAITING_MACS="${HALOW_ST_AWAITING_MACS}${HALOW_ST_AWAITING_MACS:+ }$mac" ;;
                esac
            fi
            ;;
        iface_added)
            # An announcement for an interface a station is already bound to is not new.
            for bound in "${!HALOW_ST_IFACE[@]}"; do
                if [ "${HALOW_ST_IFACE[$bound]}" = "$iface" ]; then
                    return 0
                fi
            done
            if [ -n "$mac" ]; then
                if [ "${HALOW_ST_STATE[$mac]:-}" = "associated" ]; then
                    gone="${HALOW_ST_IFACE[$mac]:-}"
                    if [ -n "$gone" ] && [ "$gone" != "$HALOW_ST_PARENT" ]; then
                        # Bound to a different per-station interface: that port is gone.
                        HALOW_ST_IFACE["$mac"]=""
                        halow_st_report_removed "$mac" "$gone" || rm_failed=1
                    fi
                    halow_st_bind_wds "$mac" "$iface" || return 1
                    [ "$rm_failed" -eq 0 ] || return 1
                else
                    # Named for a station that has not associated yet: remember the pairing
                    # and report the station once it associates (never before).
                    HALOW_ST_PREPAIR["$mac"]="$iface"
                fi
                return 0
            fi
            first="${HALOW_ST_AWAITING_MACS%% *}"
            if [ -n "$first" ]; then
                halow_st_bind_wds "$first" "$iface" || return 1
            else
                HALOW_ST_PENDING_IFACES="${HALOW_ST_PENDING_IFACES}${HALOW_ST_PENDING_IFACES:+ }$iface"
            fi
            ;;
        station_removed)
            HALOW_ST_STATE["$mac"]="offline"
            HALOW_ST_CHANGED_AT["$mac"]="$now"
            unset 'HALOW_ST_CONNECTED_AT[$mac]'
            HALOW_ST_AWAITING_MACS="$(halow_st_remove_word "$HALOW_ST_AWAITING_MACS" "$mac")"
            unset 'HALOW_ST_PREPAIR[$mac]'
            unset 'HALOW_ST_ASSOC_AT[$mac]'
            if [ -n "${HALOW_ST_IFACE[$mac]:-}" ]; then
                gone="${HALOW_ST_IFACE[$mac]}"
                HALOW_ST_IFACE["$mac"]=""
                HALOW_ST_SERVED["$mac"]=0
                halow_st_report_removed "$mac" "$gone" || return 1
            fi
            ;;
        iface_removed)
            HALOW_ST_PENDING_IFACES="$(halow_st_remove_word "$HALOW_ST_PENDING_IFACES" "$iface")"
            for bound in "${!HALOW_ST_PREPAIR[@]}"; do
                [ "${HALOW_ST_PREPAIR[$bound]}" != "$iface" ] || unset 'HALOW_ST_PREPAIR[$bound]'
            done
            # A station still bound to the vanished interface loses its port, so a new
            # interface that reuses the name is not mistaken for it. If it is still
            # associated it waits for a new port again (its own interface, or the parent
            # once the ordinary-station wait has passed).
            for bound in "${!HALOW_ST_IFACE[@]}"; do
                if [ "${HALOW_ST_IFACE[$bound]}" = "$iface" ]; then
                    HALOW_ST_IFACE["$bound"]=""
                    HALOW_ST_SERVED["$bound"]=0
                    halow_st_report_removed "$bound" "$iface" || rm_failed=1
                    if [ "${HALOW_ST_STATE[$bound]:-}" = "associated" ]; then
                        HALOW_ST_ASSOC_AT["$bound"]="$now"
                        HALOW_ST_AWAITING_MACS="${HALOW_ST_AWAITING_MACS}${HALOW_ST_AWAITING_MACS:+ }$bound"
                    fi
                fi
            done
            [ "$rm_failed" -eq 0 ] || return 1
            ;;
        *) ;;
    esac
    return 0
}

# halow_st_promote_ordinary
# Every associated station that has waited HALOW_ST_ORDINARY_WAIT_S without an interface
# becomes an ordinary station on the parent. Returns 0, or 1 if a backend call failed.
halow_st_promote_ordinary() {
    local now mac at failed=0
    [ -n "$HALOW_ST_AWAITING_MACS" ] || return 0
    now="$(halow_st_now)"
    for mac in $HALOW_ST_AWAITING_MACS; do
        [ "${HALOW_ST_STATE[$mac]:-}" = "associated" ] || continue
        at="${HALOW_ST_ASSOC_AT[$mac]:-$now}"
        if [ $((now - at)) -ge "$HALOW_ST_ORDINARY_WAIT_S" ]; then
            halow_st_bind_ordinary "$mac" || failed=1
        fi
    done
    return "$failed"
}

# _halow_st_process_file <file> <final:0|1>
# Dispatch every complete line after the first HALOW_ST_LOG_LINES lines of <file>. With
# final=1 an incomplete last line is processed too (nothing more will be appended).
_halow_st_process_file() {
    local file="$1" final="$2" total line failed=0 last=""
    [ -f "$file" ] || return 0
    total="$(wc -l < "$file" 2>/dev/null)" || total=0
    total="${total//[[:space:]]/}"
    [ -n "$total" ] || total=0
    if [ "$total" -gt "$HALOW_ST_LOG_LINES" ]; then
        while IFS= read -r line; do
            HALOW_ST_LOG_LINES=$((HALOW_ST_LOG_LINES + 1))
            if halow_st_parse_event "$line"; then
                halow_st_dispatch || failed=1
            fi
        done < <(sed -n "$((HALOW_ST_LOG_LINES + 1)),${total}p" "$file")
    fi
    if [ "$final" -eq 1 ]; then
        last="$(tail -c 1 "$file" 2>/dev/null || true)"
        if [ -n "$last" ]; then
            line="$(sed -n "$((total + 1))p" "$file")"
            HALOW_ST_LOG_LINES=$((HALOW_ST_LOG_LINES + 1))
            if halow_st_parse_event "$line"; then
                halow_st_dispatch || failed=1
            fi
        fi
    fi
    return "$failed"
}

# halow_st_process_log
# Read the hostapd log lines added since the last call, dispatch every recognised event in
# order, then serve stations that have waited long enough as ordinary stations. Every
# line is consumed even if one of them fails. Returns 0, or 1 if any event failed (or the
# backend is not attached yet, in which case nothing is read).
halow_st_process_log() {
    local failed=0
    if [ -z "$HALOW_ST_ATTACHMENT" ]; then
        if [ -z "$HALOW_ST_BRIDGE" ]; then
            halow_log_error "stations: no bridge is known; station events are not read"
            return 1
        fi
        # The caller attached the backend itself (halow_backend_call attach bridge ...)
        # before supervising, without halow_st_attach: take the bridge as the attachment.
        halow_log_info "stations: taking $HALOW_ST_BRIDGE as the backend's attachment (attached by the caller)"
        HALOW_ST_ATTACHMENT="$HALOW_ST_BRIDGE"
    fi
    _halow_st_process_file "$HALOW_ST_LOG_FILE" 0 || failed=1
    halow_st_promote_ordinary || failed=1
    _halow_st_republish_fault
    return "$failed"
}

# _halow_st_relog — ask hostapd to reopen its log file. 0 only on a positive "OK".
_halow_st_relog() {
    local out
    if [ "${#HALOW_ST_RELOG_CMD[@]}" -gt 0 ]; then
        out="$("${HALOW_ST_RELOG_CMD[@]}" 2>&1)" || return 1
    elif [ -n "${HALOW_HOSTAPD_CLI:-}" ]; then
        out="$("$HALOW_HOSTAPD_CLI" -i "$HALOW_ST_PARENT" relog 2>&1)" || return 1
    else
        return 2
    fi
    case $'\n'"$out"$'\n' in
        *$'\n'OK$'\n'*) return 0 ;;
    esac
    return 1
}

# halow_st_rotate_log_if_large [<max_bytes>]
# When the hostapd log exceeds <max_bytes> (default HALOW_ST_LOG_MAX_BYTES): process it,
# move it aside (hostapd keeps writing to the moved file), ask hostapd to reopen its log
# (RELOG), then drain the moved file to its very end and remove it, and continue from the
# start of the new file. If RELOG fails the file is moved back unchanged. Never loses or
# replays an event. Returns 0 (rotated or nothing to do), 1 rotation failed (log intact).
halow_st_rotate_log_if_large() {
    local max="${1:-$HALOW_ST_LOG_MAX_BYTES}" file="$HALOW_ST_LOG_FILE" size old rc
    [ -n "$HALOW_ST_ATTACHMENT" ] || return 0
    [ -f "$file" ] || return 0
    size="$(wc -c < "$file" 2>/dev/null)" || return 0
    size="${size//[[:space:]]/}"
    [ "${size:-0}" -gt "$max" ] || return 0
    if [ "${#HALOW_ST_RELOG_CMD[@]}" -eq 0 ] && [ -z "${HALOW_HOSTAPD_CLI:-}" ]; then
        if [ "$HALOW_ST_ROTATE_WARNED" -eq 0 ]; then
            halow_log_warning "stations: the hostapd log is larger than $max bytes but no command to reopen it is configured; not rotating"
            HALOW_ST_ROTATE_WARNED=1
        fi
        return 0
    fi
    _halow_st_process_file "$file" 0 || true
    old="${file}.1"
    rm -f -- "$old"
    if ! mv -f -- "$file" "$old"; then
        halow_log_error "stations: could not move the hostapd log aside; not rotating"
        return 1
    fi
    if _halow_st_relog; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ] && [ ! -e "$file" ]; then
        # hostapd did not reopen: it is still writing to the moved file (same inode).
        if mv -f -- "$old" "$file"; then
            halow_log_error "stations: hostapd did not reopen its log; rotation skipped"
        else
            halow_log_error "stations: hostapd did not reopen its log and the log could not be moved back; continuing on the moved file"
            HALOW_ST_LOG_FILE="$old"
        fi
        return 1
    fi
    # hostapd now writes to a new file at the original path; nothing more reaches $old.
    _halow_st_process_file "$old" 1 || true
    rm -f -- "$old"
    HALOW_ST_LOG_LINES=0
    : >> "$file" 2>/dev/null || true
    halow_log_info "stations: hostapd log rotated at $size bytes"
    return 0
}

# halow_st_poll — one supervision tick: bounded rotation, then the new events.
halow_st_poll() {
    local failed=0
    halow_st_rotate_log_if_large || true
    halow_st_process_log || failed=1
    return "$failed"
}

# halow_st_associated_count — how many stations are currently associated.
halow_st_associated_count() {
    local mac n=0
    for mac in "${!HALOW_ST_STATE[@]}"; do
        if [ "${HALOW_ST_STATE[$mac]}" = "associated" ]; then n=$((n + 1)); fi
    done
    printf '%s' "$n"
}

# halow_st_set_all_sta <text>
# Parse `hostapd_cli all_sta` output: a line holding only a MAC starts a station; its
# flags= line says whether it is [AUTHORIZED]. An empty argument forgets the last parse
# (the snapshot then uses the log-derived state).
halow_st_set_all_sta() {
    local text="${1:-}" line cur="" mac_re='^([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5})$'
    HALOW_ST_ALLSTA=()
    HALOW_ST_ALLSTA_VALID=0
    # An empty text forgets the answer, unless the caller says (second argument "valid") that
    # the call succeeded and simply listed no station.
    if [ -z "$text" ] && [ "${2:-}" != "valid" ]; then return 0; fi
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $mac_re ]]; then
            cur="${BASH_REMATCH[1],,}"
            HALOW_ST_ALLSTA["$cur"]="false"
        elif [ -n "$cur" ]; then
            case "$line" in
                flags=*"[AUTHORIZED]"*) HALOW_ST_ALLSTA["$cur"]="true" ;;
            esac
        fi
    done <<< "$text"
    HALOW_ST_ALLSTA_VALID=1
    return 0
}

# ---------------------------------------------------------------------------------------
# The snapshot view: one record per HaLow station, with the addresses known for it
# ---------------------------------------------------------------------------------------
#
# Sources (all read-only; each is optional and a missing one just contributes nothing):
#   DHCP leases   the lease file of the DHCP service (halow_dhcp_lease_file); only unexpired
#                 leases count (the DHCP server expires them by its own times; an expiry of
#                 0 is an infinite lease)
#   neighbour     `ip neigh show dev <bridge>`, IPv4 only; FAILED and INCOMPLETE entries
#                 are not mappings
#   forwarding    `bridge fdb show br <bridge>`: the MACs learned behind a four-address
#                 station's own port (never permanent or local entries, group addresses,
#                 the station's own MAC or another HaLow station's MAC)
# A MAC is attributed to a station ONLY by the forwarding table (a device behind a WDS
# station's port) or by being the station's own MAC. A lease or neighbour entry for a MAC
# that is not behind any port is never attributed to a station.
#
# A MAC may have several addresses, and each is listed with where it came from. An address
# claimed by more than one MAC (in the union of the unexpired leases and the neighbour
# entries) is marked as conflicting on every MAC that claims it, never resolved by a guess.

: "${HALOW_ST_DEVICES_MAX:=16}"
: "${HALOW_ST_IPS_MAX:=4}"

_halow_st_is_mac() { [[ "${1-}" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]]; }

_halow_st_is_ipv4() {
    local ip="${1-}" a b c d
    [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

# _halow_st_add_mapping <mac> <ip> <d|n>
# Record that <ip> maps to <mac> from a source (d = DHCP lease, n = neighbour table).
_halow_st_add_mapping() {
    local mac="$1" ip="$2" src="$3" key
    key="$mac|$ip"
    case "${_HALOW_ST_A_SRC[$key]:-}" in
        '')
            _HALOW_ST_A_SRC["$key"]="$src"
            _HALOW_ST_A_IPS["$mac"]="${_HALOW_ST_A_IPS[$mac]:-}${_HALOW_ST_A_IPS[$mac]:+ }$ip"
            case " ${_HALOW_ST_A_IPMACS[$ip]:-} " in
                *" $mac "*) ;;
                *) _HALOW_ST_A_IPMACS["$ip"]="${_HALOW_ST_A_IPMACS[$ip]:-}${_HALOW_ST_A_IPMACS[$ip]:+ }$mac" ;;
            esac
            ;;
        "$src"|dn) ;;
        *) _HALOW_ST_A_SRC["$key"]="dn" ;;
    esac
}

# _halow_st_load_addresses <now> <neigh_text>
# Fill _HALOW_ST_A_IPS (mac -> addresses), _HALOW_ST_A_SRC (mac|ip -> d, n or dn) and
# _HALOW_ST_A_IPMACS (ip -> the MACs that claim it) from the leases and the neighbour text.
_halow_st_load_addresses() {
    local now="$1" text="$2" file exp lmac ip _rest line i
    local -a f
    declare -gA _HALOW_ST_A_IPS=() _HALOW_ST_A_SRC=() _HALOW_ST_A_IPMACS=()
    if declare -F halow_dhcp_lease_file >/dev/null 2>&1; then
        file="$(halow_dhcp_lease_file)"
        if [ -f "$file" ] && [ -r "$file" ]; then
            while read -r exp lmac ip _rest; do
                lmac="${lmac,,}"
                case "$exp" in ''|*[!0-9]*) continue ;; esac
                [ "${#exp}" -le 12 ] || continue
                _halow_st_is_mac "$lmac" || continue
                _halow_st_is_ipv4 "$ip" || continue
                exp=$((10#$exp))
                if [ "$exp" -ne 0 ] && [ "$exp" -le "$now" ]; then continue; fi
                _halow_st_add_mapping "$lmac" "$ip" d
            done < <(head -c 1048576 "$file" 2>/dev/null || true)
        fi
    fi
    while IFS= read -r line; do
        read -r -a f <<< "$line" || true
        [ "${#f[@]}" -ge 3 ] || continue
        case "$line" in *FAILED*|*INCOMPLETE*) continue ;; esac
        ip="${f[0]}"
        _halow_st_is_ipv4 "$ip" || continue
        lmac=""
        for ((i = 1; i < ${#f[@]} - 1; i++)); do
            if [ "${f[$i]}" = "lladdr" ]; then lmac="${f[$((i + 1))],,}"; break; fi
        done
        _halow_st_is_mac "$lmac" || continue
        _halow_st_add_mapping "$lmac" "$ip" n
    done <<< "$text"
}

# _halow_st_emit_addresses <tag> <mac>
# Print "<tag>|<ip>|<source>|<conflict 0|1>" for each address of <mac>, in address order,
# at most HALOW_ST_IPS_MAX of them.
_halow_st_emit_addresses() {
    local tag="$1" mac="$2" ip src nm n=0 list claimants
    list="${_HALOW_ST_A_IPS[$mac]:-}"
    [ -n "$list" ] || return 0
    while read -r ip; do
        [ -n "$ip" ] || continue
        n=$((n + 1))
        [ "$n" -le "$HALOW_ST_IPS_MAX" ] || break
        case "${_HALOW_ST_A_SRC[$mac|$ip]:-}" in
            d) src="dhcp" ;;
            n) src="neighbour" ;;
            *) src="dhcp+neighbour" ;;
        esac
        read -r -a claimants <<< "${_HALOW_ST_A_IPMACS[$ip]:-}"
        nm=0
        if [ "${#claimants[@]}" -gt 1 ]; then nm=1; fi
        printf '%s|%s|%s|%s\n' "$tag" "$ip" "$src" "$nm"
    done < <(printf '%s\n' $list | sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
}

# _halow_st_devices_behind_port <port> <station_mac> <fdb_text>
# Print the distinct MACs learned behind <port> in the bridge forwarding table, sorted:
# never the station's own MAC, another known HaLow station's MAC, a group (multicast or
# broadcast) address, or a permanent, local or static (administrator-created, not learned)
# entry.
_halow_st_devices_behind_port() {
    local port="$1" smac="$2" text="$3" line m
    local -a f
    while IFS= read -r line; do
        read -r -a f <<< "$line" || true
        [ "${#f[@]}" -ge 3 ] || continue
        [ "${f[1]}" = "dev" ] && [ "${f[2]}" = "$port" ] || continue
        case " $line " in *" permanent "*|*" self "*|*" static "*) continue ;; esac
        m="${f[0],,}"
        _halow_st_is_mac "$m" || continue
        # (the station's own MAC and every other HaLow station's MAC are known stations: excluded below)
        [ $(( 0x${m:0:2} & 1 )) -eq 0 ] || continue
        [ -z "${HALOW_ST_STATE[$m]+x}" ] || continue
        printf '%s\n' "$m"
    done <<< "$text" | sort -u
}

# halow_stations_snapshot_lines
# Print the station records, sorted by station MAC, as lines of four kinds (consumed by
# halow_state_stations_set in state.sh):
#   S|<mac>|<online true|false>|<kind ordinary|wds>|<connected_since epoch or empty>|<changed_at epoch or empty>|<devices_omitted>|<online_source hostapd|log>
#   SI|<ip>|<source dhcp|neighbour|dhcp+neighbour>|<conflict 0|1>     an address of the station's own MAC
#   D|<mac>                                                           a device behind this (wds) station
#   DI|<ip>|<source>|<conflict>                                       an address of the last D
# online: the [AUTHORIZED] flag from the last all_sta text when one was given
#         (halow_st_set_all_sta), else the log-derived association state. The
#         source is reported per station (online_source: hostapd when the flag was used,
#         log when only the connection log says so; the manager clears the all_sta text
#         whenever hostapd_cli all_sta fails, so a stale answer is never kept). A DHCP lease
#         never makes a station online.
# connected_since: only for an online station that the log shows associated: the time of
#         its latest connection (AP-STA-CONNECTED) after its last disconnect; a repeated
#         association line without a disconnect in between does not move it.
# changed_at: the time of the latest connection event (connect or disconnect) for the
#         station. It says nothing about whether the station is passing traffic.
halow_stations_snapshot_lines() {
    local mac online kind port now neigh="" fdb="" bridge="${HALOW_ST_ATTACHMENT:-$HALOW_ST_BRIDGE}"
    local since dev omitted osrc
    local -a macs=() devs=()
    now="$(halow_st_now)"
    for mac in "${!HALOW_ST_STATE[@]}"; do macs+=("$mac"); done
    [ "${#macs[@]}" -gt 0 ] || return 0
    if [ -n "$bridge" ]; then
        neigh="$("${HALOW_IP:-ip}" neigh show dev "$bridge" 2>/dev/null || true)"
        fdb="$("${HALOW_BRIDGE_CMD:-bridge}" fdb show br "$bridge" 2>/dev/null || true)"
    fi
    _halow_st_load_addresses "$now" "$neigh"
    while IFS= read -r mac; do
        [ -n "$mac" ] || continue
        if [ "$HALOW_ST_ALLSTA_VALID" -eq 1 ]; then
            online="${HALOW_ST_ALLSTA[$mac]:-false}"
            osrc=hostapd
        elif [ "${HALOW_ST_STATE[$mac]}" = "associated" ]; then
            online=true
            osrc=log
        else
            online=false
            osrc=log
        fi
        kind="${HALOW_ST_KIND[$mac]:-ordinary}"
        port="${HALOW_ST_IFACE[$mac]:-}"
        since=""
        if [ "$online" = "true" ] && [ "${HALOW_ST_STATE[$mac]}" = "associated" ]; then
            since="${HALOW_ST_CONNECTED_AT[$mac]:-}"
        fi
        devs=(); omitted=0
        if [ "$kind" = "wds" ] && [ -n "$port" ]; then
            while IFS= read -r dev; do
                [ -n "$dev" ] || continue
                devs+=("$dev")
            done < <(_halow_st_devices_behind_port "$port" "$mac" "$fdb")
            if [ "${#devs[@]}" -gt "$HALOW_ST_DEVICES_MAX" ]; then
                omitted=$(( ${#devs[@]} - HALOW_ST_DEVICES_MAX ))
                devs=("${devs[@]:0:HALOW_ST_DEVICES_MAX}")
            fi
        fi
        printf 'S|%s|%s|%s|%s|%s|%s|%s\n' "$mac" "$online" "$kind" "$since" "${HALOW_ST_CHANGED_AT[$mac]:-}" "$omitted" "$osrc"
        _halow_st_emit_addresses SI "$mac"
        for dev in "${devs[@]}"; do
            printf 'D|%s\n' "$dev"
            _halow_st_emit_addresses DI "$dev"
        done
    done < <(printf '%s\n' "${macs[@]}" | sort)
    return 0
}

# halow_st_check_health
# Keep the healthy marker honest: withdrawn while a station fault is recorded or the
# backend reports a problem, restored when it recovers (never while a fault is sticky).
# Does nothing before the attachment.
halow_st_check_health() {
    local ok=1
    [ -n "$HALOW_ST_ATTACHMENT" ] || return 0
    if [ "$HALOW_ST_ATTACHMENT_LOST" -eq 1 ] || [ "$HALOW_ST_FAULT" -eq 1 ]; then ok=0; fi
    if [ "$ok" -eq 1 ] && ! halow_backend_call health; then ok=0; fi
    if [ "$ok" -eq 0 ] && [ "$HALOW_ST_HEALTH_REPORTED" -eq 1 ]; then
        halow_log_warning "stations: the networking backend is not healthy; withdrawing the healthy marker"
        halow_report_unhealthy
        HALOW_ST_HEALTH_REPORTED=0
    elif [ "$ok" -eq 1 ] && [ "$HALOW_ST_HEALTH_REPORTED" -eq 0 ]; then
        halow_report_healthy "the networking backend is healthy again"
        HALOW_ST_HEALTH_REPORTED=1
    fi
    return 0
}

# halow_st_supervise <hostapd_pid>
# While hostapd runs, poll station events once a second (and check health every 10 s);
# when it exits, return its exit status. A failure while processing is logged and does not
# stop the supervision. A signal received during the wait runs the caller's own trap.
halow_st_supervise() {
    local pid="$1" rc
    while kill -0 "$pid" 2>/dev/null; do
        if ! halow_st_poll; then
            halow_log_error "stations: a station event could not be handled; continuing to supervise hostapd"
        fi
        HALOW_ST_HEALTH_TICK=$((HALOW_ST_HEALTH_TICK + 1))
        if [ "$HALOW_ST_HEALTH_TICK" -ge 10 ]; then HALOW_ST_HEALTH_TICK=0; halow_st_check_health; fi
        sleep 1 &
        wait "$!" 2>/dev/null || true
    done
    if ! halow_st_process_log; then halow_log_error "stations: the final pass over the hostapd log failed"; fi
    if wait "$pid"; then rc=0; else rc=$?; fi
    return "$rc"
}
