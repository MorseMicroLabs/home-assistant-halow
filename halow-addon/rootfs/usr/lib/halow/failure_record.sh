#!/usr/bin/env bash
# halow: a small, bounded, secrets-safe record of an access-point (hostapd_s1g) failure.
#
# WHY: when hostapd_s1g exits at once, the rollback that follows deletes its log and its pid
# file within seconds, so the reason is lost. The manager calls halow_failure_record_capture
# BEFORE that rollback. Nothing here changes the start path, the retry count or the backoff:
# a capture is best effort, takes a few seconds at most, and always returns 0.
#
# WHAT A RECORD HOLDS (one text value, at most HALOW_FREC_MAX_BYTES bytes), and why:
#   - trigger, attempt, consecutive failures before this one, retry limit: which retry failed;
#   - the exit status (or signal) of hostapd_s1g and how long after launch it was found ended
#     (an upper bound on how long it ran): crash, clean refusal or exec failure;
#   - region, channel selection mode, bandwidth and the consumed channel, all taken from the
#     manager's structured values; with a manual channel also the operating class and the
#     primary settings, labelled configured/derived (calculated from the profile table, NOT
#     read from the radio);
#   - interface and bridge presence and link state only: was the radio interface still there;
#   - a short, allow-listed tail of hostapd's own log: the reason hostapd gave;
#   - a short tail of kernel-log lines that name the Morse driver or the radio interface:
#     a driver or firmware fault around the failure.
# The rendered hostapd configuration is NOT reproduced: every safe setting above comes from
# structured values, so the file that carries the passphrase is never read.
#
# SECRET HANDLING (deny by default). The tail of hostapd's log (at most HALOW_FREC_READ_BYTES)
#   and of the kernel log is read, then filtered line by line: a line is kept only when it
#   matches a short allowlist of subjects AND it is not sensitive. A line is sensitive when,
#   ignoring case, it (or a copy with 0x and every character that is not a letter or digit
#   removed, so no separator style survives) contains pass, psk, pmk, sae, secret, key, token,
#   wep, hexdump, dpp, wps, eapol or radius; or a run of 12 or more hex digits in that copy
#   (any MAC address, hex dump or key, whatever its separators); or 32 or more base64-like
#   characters; or any 8 consecutive characters of the configured passphrase (as written or in that copy).
#   A leading kernel timestamp is ignored for these checks. A line naming a serial number is
#   never kept. An SSID that hostapd echoes is not treated as secret. Kept lines are printable
#   ASCII and at most HALOW_FREC_LINE_MAX characters. The finished record is also scrubbed of
#   the exact passphrase, and it passes through halow_state_diag_set, whose redactor is a
#   further layer. hostapd is never started with -d, -dd or -K, and the passphrase is never
#   on a command line.
#
# DESIGN LIMIT: the guarantee is for the CONFIGURED passphrase, through the subject
# allowlist, the exact-passphrase scrub and the 8-character piece check (as written and on the squashed line)
# (so re-delimiting with spaces, punctuation or case does not help). A fragment of 7 or fewer
# characters, or a transformation other than removing separators, is not caught by the piece
# check.
#
# TIME: ip and dmesg each run under timeout (HALOW_FREC_TOOL_TIMEOUT_S, 2 s), so a capture
# takes about 4 s at most; with no timeout command those two tools are skipped, never run
# unbounded. The log tail is a read of a regular file.
#
# STORAGE: a ring of at most HALOW_FREC_MAX_RECORDS (3) records, newest first, held in the
# manager's memory and published as the diagnostics keys ap_failure_1 .. ap_failure_3
# (the status snapshot lives on the memory-backed run directory), with ap_failure_count and
# ap_failure_truncations. No file is written by this library. halow_failure_record_clear
# (called at stop) removes every key.
#
# Defines functions only; sourcing this file runs nothing.

: "${HALOW_FREC_MAX_RECORDS:=3}"
: "${HALOW_FREC_MAX_BYTES:=8192}"
: "${HALOW_FREC_LOG_LINES:=30}"
: "${HALOW_FREC_LOG_MAX:=3072}"
: "${HALOW_FREC_KLOG_LINES:=20}"
: "${HALOW_FREC_KLOG_MAX:=2048}"
: "${HALOW_FREC_LINE_MAX:=160}"
: "${HALOW_FREC_READ_BYTES:=8192}"
: "${HALOW_FREC_SCAN_LINES:=300}"
: "${HALOW_FREC_DMESG_TAIL_LINES:=1000}"
: "${HALOW_FREC_TOOL_TIMEOUT_S:=2}"
: "${HALOW_FREC_DMESG_CMD:=dmesg}"
: "${HALOW_FREC_IP_CMD:=ip}"

declare -ga _HALOW_FREC_RING
: "${_HALOW_FREC_SEQ:=0}"
: "${_HALOW_FREC_TRUNC:=0}"
: "${_HALOW_FREC_TRUNC_NOW:=0}"

HALOW_FREC_REDACTED="[redacted]"

# _halow_frec_run <command...> - the command under timeout; not run at all (127) without it.
_halow_frec_run() {
    local t="${HALOW_TIMEOUT_CMD:-timeout}"
    command -v "$t" >/dev/null 2>&1 || return 127
    "$t" "$HALOW_FREC_TOOL_TIMEOUT_S" "$@"
}

# _halow_frec_squash <string> - sets _HALOW_FREC_SQ to the lower-cased string with 0x and
# every character that is not a letter or digit removed (no subshell: it runs once per line).
_halow_frec_squash() {
    local s="${1,,}"
    s="${s//0x/}"
    _HALOW_FREC_SQ="${s//[^a-z0-9]/}"
}

# _halow_frec_pieces_in <needle> <haystack> - 0 when the haystack contains the needle or any
# 8 consecutive characters of it (a needle shorter than 8 must appear whole).
_halow_frec_pieces_in() {
    local v="$1" s="$2" n i
    n=${#v}
    [ "$n" -gt 0 ] && [ "${#s}" -ge $(( n < 8 ? n : 8 )) ] || return 1
    if [ "$n" -lt 8 ]; then
        [[ $s != *"$v"* ]] || return 0
        return 1
    fi
    for (( i = 0; i <= n - 8; i++ )); do
        [[ $s != *"${v:i:8}"* ]] || return 0
    done
    return 1
}

# _halow_frec_passphrase_piece <line> - 0 when the line holds the configured passphrase or 8
# consecutive characters of it, as written (lower case) or with every separator removed.
_halow_frec_passphrase_piece() {
    local pp="${HALOW_CFG_WIFI_PASSPHRASE:-}" line="$1" sq_pp sq_line
    [ -n "$pp" ] || return 1
    _halow_frec_pieces_in "${pp,,}" "${line,,}" && return 0
    _halow_frec_squash "$pp"; sq_pp="$_HALOW_FREC_SQ"
    _halow_frec_squash "$line"; sq_line="$_HALOW_FREC_SQ"
    _halow_frec_pieces_in "$sq_pp" "$sq_line"
}

# _halow_frec_sensitive <line> - 0 when the line must not be kept.
_halow_frec_sensitive() {
    local raw="$1" l s
    local ts='^\[[[:space:]0-9.]*\][[:space:]]*(.*)$'
    # a leading kernel timestamp is not part of the line's content (its digits would
    # otherwise run into the next word's hex letters)
    if [[ $raw =~ $ts ]]; then raw="${BASH_REMATCH[1]}"; fi
    l="${raw,,}"
    _halow_frec_squash "$raw"
    s="$_HALOW_FREC_SQ"
    case "$l$s" in
        *pass*|*psk*|*pmk*|*sae*|*secret*|*key*|*token*|*wep*|*hexdump*|*dpp*|*wps*|*eapol*|*radius*) return 0 ;;
    esac
    [[ $s =~ [0-9a-f]{12} ]] && return 0
    [[ $raw =~ [A-Za-z0-9+/=]{32} ]] && return 0
    _halow_frec_passphrase_piece "$raw" && return 0
    return 1
}

# _halow_frec_cap <varname> <max> - keeps the newest lines of the variable within <max> bytes
# and counts the truncation.
_halow_frec_cap() {
    local LC_ALL=C name="$1" max="$2" v
    v="${!name}"
    if [ "${#v}" -gt "$max" ]; then
        v="${v: -max}"
        v="${v#*$'\n'}"
        printf -v "$name" '[older lines dropped, truncated to %s bytes]\n%s' "$max" "$v"
        _HALOW_FREC_TRUNC_NOW=$((_HALOW_FREC_TRUNC_NOW + 1))
    fi
}

# _halow_frec_allowed <log|klog> <line> - 0 when the line is on the subject allowlist.
_halow_frec_allowed() {
    local l="${2,,}" iface="${HALOW_IFACE:-}"
    case "$l" in *serial*) return 1 ;; esac
    case "$1" in
        log)
            case "$l" in
                *hostapd*|*nl80211*|*interface*|*acs*|*ap-*|*"could not"*|*fail*|*error*|*"line "*|*channel*|*bridge*|*ctrl_iface*|*driver*|*country*|*"not found"*|*cannot*|*invalid*|*unsupported*|*terminat*|*segment*|*abort*|*wlu*|*firmware*|*morse*|*s1g*|*beacon*|*"not allowed"*) return 0 ;;
            esac
            ;;
        klog)
            case "$l" in *morse*|*dot11ah*|*halow*) return 0 ;; esac
            if [ -n "$iface" ]; then [[ $l != *"${iface,,}"* ]] || return 0; fi
            ;;
    esac
    return 1
}

# _halow_frec_filter <log|klog> <text> <max_lines> - sets _HALOW_FREC_SEC to the newest
# <max_lines> allowed, non-sensitive lines (printable ASCII, cut to HALOW_FREC_LINE_MAX), and
# _HALOW_FREC_KEPT / _HALOW_FREC_SENS (allowed lines dropped as sensitive).
_halow_frec_filter() {
    local LC_ALL=C mode="$1" text="$2" max="$3" line i start
    local -a lines=() kept=()
    _HALOW_FREC_SEC=""
    _HALOW_FREC_KEPT=0
    _HALOW_FREC_SENS=0
    [ -n "$text" ] || return 0
    mapfile -t lines <<< "$text"
    start=0
    if [ "${#lines[@]}" -gt "$HALOW_FREC_SCAN_LINES" ]; then
        start=$((${#lines[@]} - HALOW_FREC_SCAN_LINES))
    fi
    for (( i = start; i < ${#lines[@]}; i++ )); do
        line="${lines[i]%$'\r'}"
        [ -n "$line" ] || continue
        _halow_frec_allowed "$mode" "$line" || continue
        if _halow_frec_sensitive "$line"; then
            _HALOW_FREC_SENS=$((_HALOW_FREC_SENS + 1))
            continue
        fi
        line="${line//[^ -~]/?}"
        kept+=("${line:0:HALOW_FREC_LINE_MAX}")
        if [ "${#kept[@]}" -gt "$max" ]; then kept=("${kept[@]:1}"); fi
    done
    _HALOW_FREC_KEPT="${#kept[@]}"
    for line in "${kept[@]+"${kept[@]}"}"; do
        _HALOW_FREC_SEC+="${line}"$'\n'
    done
    _HALOW_FREC_SEC="${_HALOW_FREC_SEC%$'\n'}"
}

# _halow_frec_links <iface> <bridge> - sets _HALOW_FREC_LNK: "<name> <state>" or
# "<name> absent" for each, nothing else from `ip -br link` (no address, no flags).
_halow_frec_links() {
    local out name line f1 f2 found
    _HALOW_FREC_LNK=""
    if ! out="$(_halow_frec_run "$HALOW_FREC_IP_CMD" -br link show 2>/dev/null)" || [ -z "$out" ]; then
        _HALOW_FREC_LNK="(ip link state not available)"
        return 0
    fi
    for name in "$1" "$2"; do
        [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || continue
        found=0
        while read -r f1 f2 _; do
            f1="${f1%%@*}"
            if [ "$f1" = "$name" ]; then
                [[ $f2 =~ ^[A-Z-]+$ ]] || f2="?"
                _HALOW_FREC_LNK+="${name} ${f2}"$'\n'
                found=1
                break
            fi
        done <<< "$out"
        [ "$found" -eq 1 ] || _HALOW_FREC_LNK+="${name} absent"$'\n'
    done
    _HALOW_FREC_LNK="${_HALOW_FREC_LNK%$'\n'}"
}

# _halow_frec_exit <pid> - sets _HALOW_FREC_EXIT and _HALOW_FREC_AFTER_MS.
_halow_frec_exit() {
    local pid="${1:-}" st=""
    _HALOW_FREC_EXIT="unknown"
    _HALOW_FREC_AFTER_MS=""
    if [ -n "${HALOW_HOSTAPD_EXIT_STATUS:-}" ]; then
        st="$HALOW_HOSTAPD_EXIT_STATUS"
        _HALOW_FREC_AFTER_MS="${HALOW_HOSTAPD_FAIL_MS:-}"
    elif [[ $pid =~ ^[0-9]+$ ]]; then
        if kill -0 "$pid" 2>/dev/null; then
            _HALOW_FREC_EXIT="running (not ended when captured)"
            return 0
        fi
        if wait "$pid" 2>/dev/null; then st=0; else st=$?; fi
        if declare -F halow_hostapd_ms_since_launch >/dev/null 2>&1; then
            _HALOW_FREC_AFTER_MS="$(halow_hostapd_ms_since_launch)"
        fi
    fi
    [[ $st =~ ^[0-9]+$ ]] || return 0
    _HALOW_FREC_EXIT="status $st"
    if [ "$st" = "127" ]; then
        _HALOW_FREC_EXIT="status 127 (exec failed or not collectable)"
        return 0
    fi
    if [ "$st" -gt 128 ] && [ "$st" -lt 160 ]; then
        _HALOW_FREC_EXIT="status $st (signal $(kill -l $((st - 128)) 2>/dev/null || printf '%s' "$((st - 128))"))"
    fi
}

# _halow_frec_build <trigger> <log> - builds one record into _HALOW_FREC_RECORD.
_halow_frec_build() {
    local LC_ALL=C trigger="$1" log="$2" now raw="" kl="" rec="" nl=$'\n'
    local pid="${HALOW_MGR_HOSTAPD_PID:-}" mode ch derived="not available"
    [ -n "$pid" ] || pid="${HALOW_HOSTAPD_LAST_PID:-}"
    _HALOW_FREC_TRUNC_NOW=0
    _HALOW_FREC_RECORD=""
    printf -v now '%(%s)T' -1
    trigger="${trigger//[^A-Za-z0-9_]/_}"
    # The mode and channel the last rendering used (a fallback start renders manual with the
    # fallback channel, an automatic start renders no channel); the configured values only
    # when nothing was rendered.
    mode="${HALOW_RADIO_RENDER_MODE:-${HALOW_CFG_RADIO_MODE:-?}}"
    ch="auto"
    if [ -n "${HALOW_RADIO_RENDER_MODE:-}" ]; then
        [[ ${HALOW_RADIO_RENDER_CHANNEL:-} =~ ^[0-9]+$ ]] && ch="$HALOW_RADIO_RENDER_CHANNEL"
    elif [ "${HALOW_CFG_RADIO_MODE:-}" = "manual" ] && [[ ${HALOW_CFG_CHANNEL:-} =~ ^[0-9]+$ ]]; then
        ch="$HALOW_CFG_CHANNEL"
    fi
    if [ "$ch" != "auto" ] && declare -F halow_radio_primary_info >/dev/null 2>&1 \
        && halow_radio_primary_info "${HALOW_CFG_REGION:-}" "${HALOW_CFG_BANDWIDTH:-}" "$ch" 2>/dev/null; then
        derived="op_class=${HALOW_PRIM_OP_CLASS} primary_bandwidth_mhz=${HALOW_PRIM_BW_MHZ} primary_index=${HALOW_PRIM_INDEX}"
    fi

    _halow_frec_exit "$pid"
    _halow_frec_links "${HALOW_IFACE:-}" "${HALOW_BRIDGE_NAME:-}"

    local lsec="" lkept=0 lsens=0 ksec="" kkept=0 ksens=0
    if [ -f "$log" ] && [ ! -L "$log" ] && [ -r "$log" ]; then
        { raw="$(tail -c "$HALOW_FREC_READ_BYTES" -- "$log" 2>/dev/null)"; } 2>/dev/null || raw=""
        # A tail that starts mid-line: drop the partial first line.
        if [ "${#raw}" -ge $((HALOW_FREC_READ_BYTES - 2)) ]; then raw="${raw#*$'\n'}"; fi
        _halow_frec_filter log "$raw" "$HALOW_FREC_LOG_LINES"
        lsec="$_HALOW_FREC_SEC"; lkept="$_HALOW_FREC_KEPT"; lsens="$_HALOW_FREC_SENS"
    else
        lsec="(hostapd log not available)"
    fi
    if { kl="$(_halow_frec_run "$HALOW_FREC_DMESG_CMD" 2>/dev/null | tail -n "$HALOW_FREC_DMESG_TAIL_LINES")"; } 2>/dev/null && [ -n "$kl" ]; then
        _halow_frec_filter klog "$kl" "$HALOW_FREC_KLOG_LINES"
        ksec="$_HALOW_FREC_SEC"; kkept="$_HALOW_FREC_KEPT"; ksens="$_HALOW_FREC_SENS"
    else
        ksec="(kernel log not available)"
    fi
    _halow_frec_cap lsec "$HALOW_FREC_LOG_MAX"
    _halow_frec_cap ksec "$HALOW_FREC_KLOG_MAX"

    rec="record=$((_HALOW_FREC_SEQ + 1)) trigger=${trigger} captured_at=${now}${nl}"
    rec+="attempt=${HALOW_MGR_ATTEMPT:-?} consecutive_failures_before=${HALOW_MGR_AP_FAILS:-?} retry_limit=${HALOW_AP_RETRY_LIMIT:-?}${nl}"
    rec+="hostapd_exit=${_HALOW_FREC_EXIT} found_ended_after_ms=${_HALOW_FREC_AFTER_MS:-unknown} (upper bound on run time)${nl}"
    rec+="region=${HALOW_CFG_REGION:-?} channel_selection_mode=${mode} bandwidth_mhz=${HALOW_CFG_BANDWIDTH:-?} channel=${ch}${nl}"
    rec+="primary_configured_derived (from the profile table, NOT read from the radio)=${derived}${nl}"
    rec+="[links]${nl}${_HALOW_FREC_LNK}${nl}"
    rec+="[hostapd_log_filtered kept=${lkept} dropped_sensitive=${lsens}]${nl}${lsec}${nl}"
    rec+="[kernel_log_filtered kept=${kkept} dropped_sensitive=${ksens}]${nl}${ksec}${nl}"
    rec+="truncations=${_HALOW_FREC_TRUNC_NOW}"
    # Last line of defence: the exact passphrase never leaves this function.
    local pp="${HALOW_CFG_WIFI_PASSPHRASE:-}"
    if [ -n "$pp" ] && [[ $rec == *"$pp"* ]]; then rec="${rec//"$pp"/$HALOW_FREC_REDACTED}"; fi
    if [ "${#rec}" -gt "$HALOW_FREC_MAX_BYTES" ]; then
        rec="${rec:0:HALOW_FREC_MAX_BYTES-20}"
        rec+=$'\n[record truncated]'
        _HALOW_FREC_TRUNC_NOW=$((_HALOW_FREC_TRUNC_NOW + 1))
    fi
    _HALOW_FREC_RECORD="$rec"
}

# _halow_frec_publish - writes the ring to the diagnostics keys.
_halow_frec_publish() {
    local i
    for (( i = 1; i <= HALOW_FREC_MAX_RECORDS; i++ )); do
        if [ -n "${_HALOW_FREC_RING[$((i - 1))]-}" ]; then
            halow_state_diag_set "ap_failure_$i" "${_HALOW_FREC_RING[$((i - 1))]}" || true
        fi
    done
    halow_state_diag_set ap_failure_count "$_HALOW_FREC_SEQ" || true
    halow_state_diag_set ap_failure_truncations "$_HALOW_FREC_TRUNC" || true
}

# halow_failure_record_capture <trigger> [<hostapd log>]
# Builds a record from what exists now and pushes it onto the ring. Best effort: it never
# fails, never prints the record, and never changes the manager's course.
halow_failure_record_capture() {
    local trigger="${1:-unknown}"
    local log="${2:-${HALOW_RUN_DIR:-/run/halow}/hostapd_s1g.log}"
    if ! _halow_frec_build "$trigger" "$log" 2>/dev/null; then
        return 0
    fi
    [ -n "${_HALOW_FREC_RECORD:-}" ] || return 0
    _HALOW_FREC_SEQ=$((_HALOW_FREC_SEQ + 1))
    _HALOW_FREC_TRUNC=$((_HALOW_FREC_TRUNC + _HALOW_FREC_TRUNC_NOW))
    _HALOW_FREC_RING=("$_HALOW_FREC_RECORD" "${_HALOW_FREC_RING[@]+"${_HALOW_FREC_RING[@]}"}")
    while [ "${#_HALOW_FREC_RING[@]}" -gt "$HALOW_FREC_MAX_RECORDS" ]; do
        unset "_HALOW_FREC_RING[$((${#_HALOW_FREC_RING[@]} - 1))]"
    done
    _halow_frec_publish 2>/dev/null || true
    halow_log_info "failure-record: captured record ${_HALOW_FREC_SEQ} (${trigger}, hostapd ${_HALOW_FREC_EXIT}); see the diagnostics keys ap_failure_*" 2>/dev/null || true
    _HALOW_FREC_RECORD=""
    return 0
}

# halow_failure_record_clear - forgets every record (at stop).
halow_failure_record_clear() {
    local i
    for (( i = 1; i <= HALOW_FREC_MAX_RECORDS; i++ )); do
        halow_state_diag_unset "ap_failure_$i" 2>/dev/null || true
    done
    halow_state_diag_unset ap_failure_count 2>/dev/null || true
    halow_state_diag_unset ap_failure_truncations 2>/dev/null || true
    _HALOW_FREC_RING=()
    _HALOW_FREC_SEQ=0
    _HALOW_FREC_TRUNC=0
    return 0
}
