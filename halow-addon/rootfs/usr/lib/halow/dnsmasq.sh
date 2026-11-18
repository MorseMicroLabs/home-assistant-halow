#!/usr/bin/env bash
# halow: the DHCP/DNS service for the private bridge.
#
# dnsmasq is bound to the bridge (interface=<bridge>, bind-interfaces, never the loopback),
# serves DNS on the gateway address only and DHCP from the configured range. Its
# configuration and pid file live in HALOW_RUN_DIR (tmpfs).
#
# The LEASE FILE lives in HALOW_LEASE_DIR (/data/halow_leases, the add-on's private data
# folder), so an ordinary add-on restart keeps the leases: dnsmasq reads the file when it
# starts and goes on expiring every lease by its own expiry time (nothing here expires a
# lease). The directory is excluded from backups (config.yaml backup_exclude) and goes when
# the add-on is uninstalled. Client host names are never kept: dnsmasq is told to ignore
# client-supplied names (dhcp-ignore-names) and, before every start, the persisted file is
# rewritten with only the well-formed, unexpired leases inside the configured DHCP range
# (see _halow_dnsmasq_prepare_leases). A file that is oversized, unreadable or not a
# regular file is discarded, never trusted and never allowed to block the start; if the
# directory cannot be used at all, the lease file falls back to HALOW_RUN_DIR (tmpfs, lost
# at the next restart) and a warning is logged. An orderly stop keeps the persistent lease file
# and always removes the volatile fallback (a fixed path, found without any shell variable).
#
# Logging: dnsmasq runs with --no-daemon (it logs to the add-on log) and as root, as before
# the lease file moved. Without quiet-dhcp it logs every DHCP transaction (DHCPDISCOVER,
# DHCPOFFER, DHCPREQUEST, DHCPACK with the client MAC and IP address), so the configuration
# says quiet-dhcp: routine DHCP traffic is not logged; errors and important messages are.
#
# Process identity and ownership reuse the strict helpers that already exist for dnsmasq
# (network_backend.sh): halow_dnsmasq_identity_matches, halow_find_dnsmasq_by_identity and
# halow_dnsmasq_determine_outcome. Those read their pid file from "$HALOW_STATE_DIR"; this
# file calls them with HALOW_STATE_DIR set to the run directory for that one call only
# (a bash temporary assignment), so the same decision code applies to the run-directory
# files without changing the existing library. The `net_dnsmasq` ownership marker itself
# stays in the real state directory.
#
# An instance that matches this add-on's identity but for which no `net_dnsmasq` marker is
# held is never adopted, signalled or overwritten.
#
# External commands: dnsmasq, ss (HALOW_SS), both found on PATH.

HALOW_DNSMASQ_RESTART_LIMIT="${HALOW_DNSMASQ_RESTART_LIMIT:-3}"
HALOW_DNSMASQ_STABLE_S="${HALOW_DNSMASQ_STABLE_S:-60}"

halow_dnsmasq_conf_file() { printf '%s/dnsmasq.conf' "${HALOW_RUN_DIR:?}"; }
halow_dnsmasq_pid_file() { printf '%s/dnsmasq.pid' "${HALOW_RUN_DIR:?}"; }
# The ONE fixed, known path of the volatile fallback lease file (tmpfs). Everything that
# must find or remove the fallback derives it from here, never from a shell variable, so a
# separate process (the s6 finish hook, a rollback, a fresh manager) agrees with the one
# that chose it.
_halow_dnsmasq_fallback_lease_file() { printf '%s/dnsmasq.leases' "${HALOW_RUN_DIR:?}"; }
# The lease file in use. Within the process that started dnsmasq HALOW_DNSMASQ_LEASE_ACTIVE
# says which one was chosen; every other process reads the choice back from the durable
# dnsmasq configuration (dhcp-leasefile=), and anything but the exact fallback path means
# the persistent file. HALOW_DNSMASQ_LEASE_ACTIVE is only an optimisation, never required.
halow_dnsmasq_lease_file() {
    local fb conf
    if [ -n "${HALOW_DNSMASQ_LEASE_ACTIVE:-}" ]; then
        printf '%s' "$HALOW_DNSMASQ_LEASE_ACTIVE"
        return 0
    fi
    fb="$(_halow_dnsmasq_fallback_lease_file)"
    conf="$(halow_dnsmasq_conf_file)"
    if [ -f "$conf" ] && [ ! -L "$conf" ] && grep -qxF -- "dhcp-leasefile=$fb" "$conf" 2>/dev/null; then
        printf '%s' "$fb"
    else
        printf '%s/dnsmasq.leases' "${HALOW_LEASE_DIR:?}"
    fi
}
# _halow_dnsmasq_use_fallback — select the volatile fallback for this start: make sure the
# exact fallback path is a private (0600) regular file (whatever else sits there is
# discarded; a symbolic link is removed, never followed). A restart that again falls back
# keeps the file of the previous run: its names were already written as `*` and the run
# directory is root-only, so nothing sensitive is newly exposed and the leases survive a
# dnsmasq restart.
_halow_dnsmasq_use_fallback() {
    local fb
    fb="$(_halow_dnsmasq_fallback_lease_file)"
    if [ -L "$fb" ] || { [ -e "$fb" ] && [ ! -f "$fb" ]; }; then
        rm -rf -- "$fb" 2>/dev/null || true
    fi
    # The run directory must exist (the pre-creation below must not fail silently); it is made
    # like every other run-directory file here, with a plain mkdir -p.
    mkdir -p -- "${HALOW_RUN_DIR:?}" 2>/dev/null || true
    (umask 077; : >> "$fb") 2>/dev/null || true
    chmod 0600 -- "$fb" 2>/dev/null || true
    HALOW_DNSMASQ_LEASE_ACTIVE="$fb"
}
# _halow_dnsmasq_remove_fallback — remove the exact fallback path, whatever it is (regular
# file, symbolic link — the link itself, never its target — or anything unexpected). Only
# called once dnsmasq is confirmed stopped. Never touches the persistent lease file.
# 0 only if the path is confirmed gone.
_halow_dnsmasq_remove_fallback() {
    local fb
    fb="$(_halow_dnsmasq_fallback_lease_file)"
    # Never the persistent file, even if the two directories were configured to coincide.
    [ "$fb" != "${HALOW_LEASE_DIR:?}/dnsmasq.leases" ] || return 0
    if [ -L "$fb" ] || [ -f "$fb" ]; then
        rm -f -- "$fb" 2>/dev/null || true
    elif [ -e "$fb" ]; then
        rm -rf -- "$fb" 2>/dev/null || true
    fi
    ! halow_path_still_present "$fb"
}
# Bounds for a persisted lease file (a /24 holds at most 254 leases, about 100 bytes each).
: "${HALOW_LEASE_MAX_BYTES:=262144}"
: "${HALOW_LEASE_MAX_LINES:=4096}"
_halow_dnsmasq_restart_file() { printf '%s/dnsmasq.restarts' "${HALOW_RUN_DIR:?}"; }

# halow_dhcp_lease_file — the DHCP lease file, for the station view (a neutral name, so
# the station lifecycle need not know which DHCP server is used).
halow_dhcp_lease_file() { halow_dnsmasq_lease_file; }

# Seams for tests.
halow_dnsmasq_now() { date +%s; }
halow_dnsmasq_sleep() { sleep "$1"; }

# halow_dnsmasq_outcome_run
# halow_dnsmasq_determine_outcome for the run-directory configuration and pid file. Sets
# HALOW_DNSMASQ_OUTCOME (confirmed_absent | owned | unknown | ambiguous) and
# HALOW_DNSMASQ_TARGET_PID.
halow_dnsmasq_outcome_run() {
    local conf
    conf="$(halow_dnsmasq_conf_file)"
    HALOW_STATE_DIR="${HALOW_RUN_DIR:?}" halow_dnsmasq_determine_outcome "$conf"
}

# halow_dnsmasq_running — 0 only if the run-directory pid file names a process that
# positively matches this add-on's dnsmasq identity.
halow_dnsmasq_running() {
    local pidfile conf pid
    pidfile="$(halow_dnsmasq_pid_file)"
    conf="$(halow_dnsmasq_conf_file)"
    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if halow_dnsmasq_identity_matches "$pid" "$conf"; then
        return 0
    fi
    return 1
}

# halow_dnsmasq_port_conflict_check <address>
# Look for another listener that would stop dnsmasq serving <address>: UDP/TCP 53 or UDP 67
# bound to <address> or to a wildcard address. Uses `ss` (HALOW_SS). Returns 0 no conflict;
# 1 conflict, printing one line per conflict naming the port and protocol on stdout;
# 2 the listeners could not be read (printed on stdout; not treated as a conflict).
halow_dnsmasq_port_conflict_check() {
    local address="${1:-}" out line netid local_addr port host found=""
    if [ -z "$address" ]; then
        echo "no address given for the port check"
        return 2
    fi
    if ! out="$("${HALOW_SS:-ss}" -H -l -n -t -u 2>/dev/null)"; then
        echo "the listening sockets could not be read (ss failed)"
        return 2
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        read -r netid _ _ _ local_addr _ <<< "$line" || true
        [ -n "${local_addr:-}" ] || continue
        port="${local_addr##*:}"
        host="${local_addr%:*}"
        host="${host%%%*}"
        host="${host#[}"; host="${host%]}"
        case "$host" in
            "$address"|0.0.0.0|'*'|::|'') ;;
            *) continue ;;
        esac
        case "$netid:$port" in
            udp:53|tcp:53|udp:67)
                found="${found}port ${port}/${netid} is already in use on ${host:-*} by another listener"$'\n'
                ;;
        esac
    done <<< "$out"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 1
    fi
    return 0
}

# _halow_dnsmasq_prepare_leases <dhcp_start> <dhcp_end>
# Choose and prepare the lease file for this start (sets HALOW_DNSMASQ_LEASE_ACTIVE). Never
# fails: whatever is wrong with the persisted file or its directory is logged and worked
# around, because a lease file must never stop the DHCP service from starting.
#   - the directory is created with mode 0700 (it holds client addresses);
#   - a file that is a symbolic link, not a regular file, oversized or unreadable is
#     discarded (an empty file takes its place);
#   - every other line is kept only if it is a well-formed IPv4 lease (expiry in seconds
#     since the epoch, MAC, IPv4 address, host name, client id), is not expired (expiry 0
#     means infinite) and lies inside <dhcp_start>-<dhcp_end>; its host name is replaced by
#     "*" and the first line for an address wins. The file is replaced atomically.
# Only counts are logged, never an address.
_halow_dnsmasq_prepare_leases() {
    local start="$1" end="$2" dir file tmp now size
    local line exp mac ip host cid rest ipn sn en kept=0 dropped=0 lines=0 a b c d
    local -A seen=()
    dir="${HALOW_LEASE_DIR:?}"
    file="$dir/dnsmasq.leases"
    HALOW_DNSMASQ_LEASE_ACTIVE=""
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; } || ! (umask 077; mkdir -p -- "$dir") 2>/dev/null \
        || ! chmod 0700 -- "$dir" 2>/dev/null; then
        halow_log_warning "dnsmasq: the lease directory $dir cannot be used; DHCP leases will not survive a restart"
        _halow_dnsmasq_use_fallback
        return 0
    fi
    now="$(halow_dnsmasq_now)"
    rm -f -- "$dir"/.dnsmasq.leases.?????? "$dir"/.dnsmasq.leases.??????.n 2>/dev/null || true
    if ! tmp="$(mktemp "$dir/.dnsmasq.leases.XXXXXX" 2>/dev/null)"; then
        halow_log_warning "dnsmasq: the lease directory $dir cannot be written; DHCP leases will not survive a restart"
        _halow_dnsmasq_use_fallback
        return 0
    fi
    if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
        halow_log_warning "dnsmasq: the persisted lease file is not a regular file; discarding it"
        rm -rf -- "$file" 2>/dev/null || true
    elif [ -f "$file" ]; then
        size="$(wc -c < "$file" 2>/dev/null)" || size=""
        size="${size//[[:space:]]/}"
        if [ -z "$size" ] || [ ! -r "$file" ]; then
            halow_log_warning "dnsmasq: the persisted lease file cannot be read; discarding it"
            rm -f -- "$file" 2>/dev/null || true
        elif [ "$size" -gt "$HALOW_LEASE_MAX_BYTES" ]; then
            halow_log_warning "dnsmasq: the persisted lease file is larger than $HALOW_LEASE_MAX_BYTES bytes; discarding it"
            rm -f -- "$file" 2>/dev/null || true
        fi
    fi
    if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
        halow_log_warning "dnsmasq: the persisted lease file could not be discarded; DHCP leases will not survive a restart"
        _halow_dnsmasq_use_fallback
        return 0
    fi
    sn="$(halow_ipv4_to_int "$start")"
    en="$(halow_ipv4_to_int "$end")"
    if ! (
        umask 077
        : > "$tmp" || exit 1
        [ -f "$file" ] || exit 0
        while IFS= read -r line || [ -n "$line" ]; do
            lines=$((lines + 1))
            if [ "$lines" -gt "$HALOW_LEASE_MAX_LINES" ]; then dropped=$((dropped + 1)); continue; fi
            line="${line%$'\r'}"
            [ -n "$line" ] || continue
            exp="" mac="" ip="" host="" cid="" rest=""
            read -r exp mac ip host cid rest <<< "$line" || true
            if [[ ! $exp =~ ^[0-9]{1,12}$ ]] || [[ ! $mac =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]] \
               || [[ ! $ip =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || [ -n "$rest" ] || [ -z "$host" ]; then
                dropped=$((dropped + 1)); continue
            fi
            exp=$((10#$exp))
            if [ "$exp" -ne 0 ] && [ "$exp" -le "$now" ]; then dropped=$((dropped + 1)); continue; fi
            IFS=. read -r a b c d <<< "$ip"
            if [ "$a" -gt 255 ] || [ "$b" -gt 255 ] || [ "$c" -gt 255 ] || [ "$d" -gt 255 ]; then dropped=$((dropped + 1)); continue; fi
            ipn=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            if [ "$ipn" -lt "$sn" ] || [ "$ipn" -gt "$en" ] || [ -n "${seen[$ip]:-}" ]; then dropped=$((dropped + 1)); continue; fi
            [[ $cid =~ ^[0-9A-Fa-f:]{1,128}$ ]] || cid="*"
            seen[$ip]=1
            printf '%s %s %s * %s\n' "$exp" "${mac,,}" "$ip" "$cid" >> "$tmp" || exit 1
            kept=$((kept + 1))
        done < "$file"
        printf '%s %s\n' "$kept" "$dropped" > "$tmp.n"
    ) 2>/dev/null; then
        rm -f -- "$tmp" "$tmp.n" 2>/dev/null || true
        halow_log_warning "dnsmasq: the lease directory $dir cannot be written; DHCP leases will not survive a restart"
        _halow_dnsmasq_use_fallback
        return 0
    fi
    if [ -f "$tmp.n" ]; then
        read -r kept dropped < "$tmp.n" || true
        halow_log_info "dnsmasq: kept ${kept:-0} persisted DHCP lease(s), dropped ${dropped:-0} (expired, malformed, duplicate, beyond the line limit or outside the DHCP range)"
    fi
    rm -f -- "$tmp.n" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$file" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        halow_log_warning "dnsmasq: the lease file in $dir could not be replaced; DHCP leases will not survive a restart"
        _halow_dnsmasq_use_fallback
        return 0
    fi
    HALOW_DNSMASQ_LEASE_ACTIVE="$file"
    # The persistent file is in use: a volatile fallback left by an earlier start would only
    # be stale (dnsmasq is confirmed absent here), so it goes.
    _halow_dnsmasq_remove_fallback || true
    return 0
}

# halow_dnsmasq_write_conf <bridge> <gateway_ip> <dhcp_start> <dhcp_end> <lease_time>
halow_dnsmasq_write_conf() {
    local bridge="$1" gw="$2" start="$3" end="$4" lease="$5" conf tmp
    conf="$(halow_dnsmasq_conf_file)"
    tmp="${conf}.tmp.$$"
    if ! mkdir -p -- "${HALOW_RUN_DIR:?}"; then
        halow_log_error "dnsmasq: could not create ${HALOW_RUN_DIR}"
        return 1
    fi
    if ! cat > "$tmp" <<EOF
interface=$bridge
except-interface=lo
bind-interfaces
listen-address=$gw
dhcp-range=$start,$end,$lease
dhcp-option=3,$gw
dhcp-option=6,$gw
dhcp-ignore-names
quiet-dhcp
dhcp-leasefile=$(halow_dnsmasq_lease_file)
EOF
    then
        rm -f -- "$tmp"
        halow_log_error "dnsmasq: could not write $tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$conf"; then
        rm -f -- "$tmp"
        halow_log_error "dnsmasq: could not finalise $conf"
        return 1
    fi
    return 0
}

# halow_dnsmasq_start <bridge> <gateway_ip> <dhcp_start> <dhcp_end> [<lease_time>]
# Start dnsmasq for the bridge. Ownership (`net_dnsmasq`) is recorded before any file or
# process is created. A positively identified instance this add-on owns is left running
# (idempotent); an unowned or unidentifiable one blocks the start. Returns 0 or 1.
# The arguments are remembered for halow_dnsmasq_ensure_running.
halow_dnsmasq_start() {
    local bridge="${1:-}" gw="${2:-}" start="${3:-}" end="${4:-}" lease="${5:-12h}"
    local conf pidfile dm_pid
    conf="$(halow_dnsmasq_conf_file)"
    pidfile="$(halow_dnsmasq_pid_file)"
    if [ -z "$bridge" ] || [ -z "$gw" ] || [ -z "$start" ] || [ -z "$end" ]; then
        halow_log_error "dnsmasq: bridge, gateway and DHCP range are all required"
        return 1
    fi
    case "$lease" in
        infinite) ;;
        *) if ! [[ "$lease" =~ ^[0-9]+[smhd]?$ ]]; then halow_log_error "dnsmasq: invalid lease time '$lease'"; return 1; fi ;;
    esac
    HALOW_DNSMASQ_ARGS=("$bridge" "$gw" "$start" "$end" "$lease")

    halow_dnsmasq_outcome_run
    case "$HALOW_DNSMASQ_OUTCOME" in
        confirmed_absent) ;;
        owned)
            if halow_own_check "net_dnsmasq"; then
                halow_log_info "dnsmasq: already running (pid $HALOW_DNSMASQ_TARGET_PID) for this add-on; not starting a second instance"
                return 0
            fi
            halow_log_error "dnsmasq: a process (pid $HALOW_DNSMASQ_TARGET_PID) matches this add-on's dnsmasq identity but no ownership record is held for it; refusing to adopt, signal or replace it"
            return 1
            ;;
        *)
            halow_log_error "dnsmasq: refusing to start: an earlier instance could not be confirmed absent (outcome: $HALOW_DNSMASQ_OUTCOME)"
            return 1
            ;;
    esac

    if ! halow_own_mark "net_dnsmasq"; then
        halow_log_error "dnsmasq: could not record ownership; refusing to create any dnsmasq file or process"
        return 1
    fi
    _halow_dnsmasq_prepare_leases "$start" "$end"
    if ! halow_dnsmasq_write_conf "$bridge" "$gw" "$start" "$end" "$lease"; then
        return 1
    fi
    rm -f -- "$pidfile"
    dnsmasq --conf-file="$conf" --pid-file="$pidfile" --no-daemon &
    dm_pid=$!
    halow_dnsmasq_sleep 1
    if ! kill -0 "$dm_pid" 2>/dev/null; then
        halow_log_error "dnsmasq: did not stay running after start (exit or exec failure); see its own log lines"
        return 1
    fi
    if ! echo "$dm_pid" > "$pidfile"; then
        halow_log_error "dnsmasq: started (pid $dm_pid) but its pid file could not be written; the stop path finds it by identity"
        return 1
    fi
    halow_log_info "dnsmasq: started (pid $dm_pid) on $bridge, DHCP $start-$end, gateway and DNS $gw"
    return 0
}

# _halow_dnsmasq_remove_files — remove configuration and pid files (and the lease file only
# when it is the volatile run-directory fallback); 0 only if all are confirmed gone. The
# persisted lease file is deliberately kept: an add-on restart must not forget the leases.
_halow_dnsmasq_remove_files() {
    local f ok=0 files
    files=("$(halow_dnsmasq_pid_file)" "$(halow_dnsmasq_conf_file)")
    for f in "${files[@]}"; do
        rm -f -- "$f"
        if halow_path_still_present "$f"; then ok=1; fi
    done
    # The volatile fallback lease file is always removed (a fixed path, whichever file this
    # or any earlier start chose); the persistent lease file is never touched here.
    _halow_dnsmasq_remove_fallback || ok=1
    return "$ok"
}

# halow_dnsmasq_stop
# Stop this add-on's dnsmasq and remove its run-directory files. Always runs the identity
# scan, with or without the ownership marker. Clears `net_dnsmasq` only once the process
# is confirmed absent by a fresh, complete scan and the files are confirmed gone; any
# unresolved case keeps the marker. Returns 1 only for a HARD failure: a live process that
# matches this add-on's identity (or could not be ruled out) while no marker is held.
# Sets HALOW_DNSMASQ_UNOWNED_RESIDUAL (0/1).
halow_dnsmasq_stop() {
    local owned=1 target scan_rc=1 attempt conf
    conf="$(halow_dnsmasq_conf_file)"
    HALOW_DNSMASQ_UNOWNED_RESIDUAL=0
    halow_own_check "net_dnsmasq" || owned=0
    halow_dnsmasq_outcome_run

    if [ "$owned" -eq 0 ]; then
        case "$HALOW_DNSMASQ_OUTCOME" in
            confirmed_absent)
                # No instance exists: a volatile fallback lease file left by an earlier
                # crash is stale and is removed (the persistent file is never touched).
                _halow_dnsmasq_remove_fallback || true
                HALOW_DNSMASQ_LEASE_ACTIVE=""
                return 0
                ;;
            owned)
                halow_log_error "dnsmasq: a process (pid $HALOW_DNSMASQ_TARGET_PID) matches this add-on's dnsmasq identity but no ownership record is held; not signalling it or touching its files"
                ;;
            *)
                halow_log_error "dnsmasq: an instance could not be confirmed absent (outcome: $HALOW_DNSMASQ_OUTCOME) and no ownership record is held"
                ;;
        esac
        HALOW_DNSMASQ_UNOWNED_RESIDUAL=1
        return 1
    fi

    case "$HALOW_DNSMASQ_OUTCOME" in
        confirmed_absent) scan_rc=1 ;;
        owned)
            target="$HALOW_DNSMASQ_TARGET_PID"
            kill "$target" 2>/dev/null || true
            for attempt in 1 2 3 4 5; do
                halow_dnsmasq_sleep 1
                if halow_find_dnsmasq_by_identity "$conf" >/dev/null 2>&1; then scan_rc=0; else scan_rc=$?; fi
                [ "$scan_rc" -eq 1 ] && break
            done
            ;;
        *)
            halow_log_error "dnsmasq: identity could not be resolved (outcome: $HALOW_DNSMASQ_OUTCOME); ownership kept"
            return 0
            ;;
    esac
    if [ "$scan_rc" -ne 1 ]; then
        halow_log_error "dnsmasq: still present (or not confirmed absent) after being stopped; ownership kept"
        return 0
    fi
    if ! _halow_dnsmasq_remove_files; then
        halow_log_error "dnsmasq: stopped, but its run-directory files could not all be removed; ownership kept"
        return 0
    fi
    halow_own_clear "net_dnsmasq"
    HALOW_DNSMASQ_LEASE_ACTIVE=""
    rm -f -- "$(_halow_dnsmasq_restart_file)"
    halow_log_info "dnsmasq: stopped and confirmed absent; run-directory files removed (the lease file is kept)"
    return 0
}

# _halow_dnsmasq_restart_state — read "<count> <last_restart_epoch>".
_halow_dnsmasq_restart_state() {
    local f count=0 last=0
    f="$(_halow_dnsmasq_restart_file)"
    if [ -f "$f" ]; then
        read -r count last < "$f" || true
    fi
    case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
    case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
    printf '%s %s' "$count" "$last"
}

# halow_dnsmasq_ensure_running
# Called from the supervision loop. While dnsmasq is running nothing happens (and once it
# has stayed up for HALOW_DNSMASQ_STABLE_S after a restart, the restart count is reset).
# When it is not running it is restarted with the arguments of the last start, after a
# bounded backoff (1, 2, 4 s). A restart that does not stay up counts as failed; after
# HALOW_DNSMASQ_RESTART_LIMIT (3) consecutive restarts without a stable run this returns 1
# and does not try again. Returns 0 running (or restarted), 1 cannot be kept running.
halow_dnsmasq_ensure_running() {
    local state count last now f
    f="$(_halow_dnsmasq_restart_file)"
    state="$(_halow_dnsmasq_restart_state)"
    count="${state%% *}"; last="${state#* }"
    now="$(halow_dnsmasq_now)"
    if halow_dnsmasq_running; then
        if [ "$count" -gt 0 ] && [ $((now - last)) -ge "$HALOW_DNSMASQ_STABLE_S" ]; then
            rm -f -- "$f"
        fi
        return 0
    fi
    if [ "${#HALOW_DNSMASQ_ARGS[@]}" -eq 0 ]; then
        halow_log_error "dnsmasq: not running and never started by this process; cannot restart it"
        return 1
    fi
    if [ "$count" -ge "$HALOW_DNSMASQ_RESTART_LIMIT" ]; then
        halow_log_error "dnsmasq: not running after $count restarts; giving up"
        return 1
    fi
    count=$((count + 1))
    mkdir -p -- "${HALOW_RUN_DIR:?}" 2>/dev/null || true
    printf '%s %s\n' "$count" "$now" > "$f" 2>/dev/null || true
    halow_log_warning "dnsmasq: not running; restart $count of $HALOW_DNSMASQ_RESTART_LIMIT"
    halow_dnsmasq_sleep "$((1 << (count - 1)))"
    if halow_dnsmasq_start "${HALOW_DNSMASQ_ARGS[@]}" && halow_dnsmasq_running; then
        return 0
    fi
    if [ "$count" -ge "$HALOW_DNSMASQ_RESTART_LIMIT" ]; then
        halow_log_error "dnsmasq: restart $count failed; giving up"
        return 1
    fi
    halow_log_warning "dnsmasq: restart $count failed; will retry"
    return 0
}

# Arguments of the last start (for restarts).
declare -ga HALOW_DNSMASQ_ARGS=()
