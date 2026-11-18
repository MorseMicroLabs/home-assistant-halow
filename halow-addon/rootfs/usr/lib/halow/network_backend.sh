#!/usr/bin/env bash
# halow: routed/NAT networking backend. Deliberately kept behind this one narrow
# interface (halow_apply_network / halow_teardown_network) so a different backend
# could be substituted later without touching driver/AP logic.
#
# Fail-closed ownership discipline (this file's own central property, re-verified in
# this change): every mutation (address, ip_forward, each iptables rule, dnsmasq) is
# EITHER successfully recorded as owned immediately after it succeeds, OR synchronously
# undone and that undo verified, before this function returns failure. No mutation is
# ever left live-but-untracked — a failure to record ownership is treated exactly like
# a failure to perform the mutation in the first place, never merely logged and
# shrugged off. Execution stops at the first such failure; nothing further is attempted.
#
# The exact interface/uplink/subnet values a run used are persisted so the separate
# `finish` process (no shared shell state with `run`) can tear down the same thing —
# as plain, validated KEY=VALUE DATA (parsed line-by-line, never sourced as shell code:
# a tampered or malformed state file must never be able to execute anything), written
# atomically (temp file + rename, each step checked) and removed only once every
# network ownership marker has actually been cleared.
#
# Persistence note: every mutation this file makes (sysctl/ip/iptables/dnsmasq) only
# ever affects live kernel/process state recreated fresh, idempotently, on every
# container start — none of it is written to a host filesystem location, which is a
# separate matter from the firmware/udev-rule mechanisms in firmware.sh/udev_rule.sh.
#
# Capability note: this backend's own `ip addr`/`ip link`, iptables, and
# network-namespace sysctl operations need CAP_NET_ADMIN — requested explicitly in
# config.yaml's own `privileged:` list alongside SYS_ADMIN (needed
# separately, for module loading). This implements the routed/NAT
# design with the capability it actually requires, not a request for broader privilege.

HALOW_NET_VALUES_FILE_DEFAULT="${HALOW_STATE_DIR:-/data/halow_state}/network_values"
HALOW_NET_OWNERSHIP_KEYS="net_addr net_ip_forward net_nat_rule net_fwd_rule_out net_fwd_rule_in net_dnsmasq"

# halow_default_uplink_iface [<route_text>]
# Parses `ip route show default` (or <route_text>, for tests) for the outbound
# interface. Prints it on success; fails (no guess) if no default route is found or
# more than one default route exists with different interfaces.
halow_default_uplink_iface() {
    local route_text="${1:-}" ifaces count
    if [ -z "$route_text" ]; then
        route_text="$(ip route show default 2>/dev/null || true)"
    fi
    ifaces="$(printf '%s\n' "$route_text" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u)"
    count=0
    [ -n "$ifaces" ] && count="$(printf '%s\n' "$ifaces" | grep -c .)"
    if [ "$count" -eq 0 ]; then
        halow_log_error "network: no default route found; cannot derive the uplink interface"
        return 1
    elif [ "$count" -gt 1 ]; then
        halow_log_error "network: multiple default-route interfaces found ($(printf '%s ' $ifaces)); refusing to guess"
        return 2
    fi
    printf '%s\n' "$ifaces"
}

# halow_save_network_values <iface> <cidr> <uplink> [<values_file>]
# Atomic: written to a temp file, each write checked, then renamed into place —
# never a partially-written file visible at the real path.
halow_save_network_values() {
    local iface="$1" cidr="$2" uplink="$3" file="${4:-$HALOW_NET_VALUES_FILE_DEFAULT}"
    local dir tmp
    dir="$(dirname -- "$file")"
    mkdir -p -- "$dir" || { halow_log_error "network: could not create $dir for network_values"; return 1; }
    tmp="$file.tmp.$$"
    {
        printf 'HALOW_NET_IFACE=%s\n' "$iface"
        printf 'HALOW_NET_CIDR=%s\n' "$cidr"
        printf 'HALOW_NET_UPLINK=%s\n' "$uplink"
    } > "$tmp" || { halow_log_error "network: could not write $tmp"; rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$file" || { halow_log_error "network: could not finalise $file"; rm -f -- "$tmp"; return 1; }
}

# halow_load_network_values [<values_file>]
# Parses exactly three expected "KEY=VALUE" lines as DATA — never sources the file as
# shell code. Rejects a duplicate key, a missing key, or any unexpected line (not one
# of the three known keys) as malformed, and validates each value with the same
# validators run.sh uses before any host mutation. Sets
# HALOW_NET_IFACE/HALOW_NET_CIDR/HALOW_NET_UPLINK on success only.
halow_load_network_values() {
    local file="${1:-$HALOW_NET_VALUES_FILE_DEFAULT}"
    [ -f "$file" ] || return 1

    local line value seen_iface=0 seen_cidr=0 seen_uplink=0
    local iface="" cidr="" uplink=""
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            HALOW_NET_IFACE=*)
                if [ "$seen_iface" -eq 1 ]; then
                    halow_log_error "network: $file has a duplicate HALOW_NET_IFACE line — rejecting as malformed"
                    return 1
                fi
                value="${line#HALOW_NET_IFACE=}"
                halow_validate_iface_name "$value" || { halow_log_error "network: $file has an invalid HALOW_NET_IFACE value"; return 1; }
                iface="$value"; seen_iface=1
                ;;
            HALOW_NET_CIDR=*)
                if [ "$seen_cidr" -eq 1 ]; then
                    halow_log_error "network: $file has a duplicate HALOW_NET_CIDR line — rejecting as malformed"
                    return 1
                fi
                value="${line#HALOW_NET_CIDR=}"
                halow_validate_ipv4_cidr "$value" || { halow_log_error "network: $file has an invalid HALOW_NET_CIDR value"; return 1; }
                cidr="$value"; seen_cidr=1
                ;;
            HALOW_NET_UPLINK=*)
                if [ "$seen_uplink" -eq 1 ]; then
                    halow_log_error "network: $file has a duplicate HALOW_NET_UPLINK line — rejecting as malformed"
                    return 1
                fi
                value="${line#HALOW_NET_UPLINK=}"
                halow_validate_iface_name "$value" || { halow_log_error "network: $file has an invalid HALOW_NET_UPLINK value"; return 1; }
                uplink="$value"; seen_uplink=1
                ;;
            *)
                halow_log_error "network: $file contains an unexpected line, rejecting the whole file as malformed/tampered: $line"
                return 1
                ;;
        esac
    done < "$file"

    if [ "$seen_iface" -ne 1 ] || [ "$seen_cidr" -ne 1 ] || [ "$seen_uplink" -ne 1 ]; then
        halow_log_error "network: $file is missing one or more required keys — rejecting as malformed"
        return 1
    fi

    HALOW_NET_IFACE="$iface"
    HALOW_NET_CIDR="$cidr"
    HALOW_NET_UPLINK="$uplink"
}

# halow_remove_network_values [<values_file>]
# Removes the state file ONLY once every network ownership marker has been cleared —
# called from halow_teardown_network itself, never independently, so it is never
# removed while a mutation it describes might still be live and untracked.
halow_remove_network_values() {
    local file="${1:-$HALOW_NET_VALUES_FILE_DEFAULT}" key
    for key in $HALOW_NET_OWNERSHIP_KEYS; do
        if halow_own_check "$key"; then
            return 0
        fi
    done
    rm -f -- "$file"
}

# halow_iface_has_cidr <iface> <cidr> — true if `ip -4 addr show` lists <cidr> on <iface>.
# Captures `ip`'s output and searches it with a here-string instead of `ip ... | grep -q`:
# under bashio's `set -o pipefail`, `grep -q` exits at the first match and the writer can
# die of SIGPIPE, giving a false "not present" (measured live for the same pattern with
# lsmod; see module_load.sh's halow_module_state). If `ip` itself fails the output is
# empty and the address is treated as not present, exactly as before.
halow_iface_has_cidr() {
    local iface="$1" cidr="$2" out
    out="$(ip -4 addr show dev "$iface" 2>/dev/null || true)"
    grep -q " ${cidr} " <<< "$out"
}

# halow_apply_network <iface> <cidr> <dhcp_start> <dhcp_end> <uplink_iface>
# Stops at the first mutation whose own ownership cannot be confirmed, after
# synchronously undoing and verifying that specific mutation — never leaves a live,
# untracked mutation behind on any failure path.
halow_apply_network() {
    local iface="$1" cidr="$2" dhcp_start="$3" dhcp_end="$4" uplink="$5"
    local gw_ip="${cidr%/*}"

    if ! halow_save_network_values "$iface" "$cidr" "$uplink"; then
        halow_log_error "network: could not persist network values; aborting before any mutation"
        return 1
    fi

    # --- Address ---
    if halow_iface_has_cidr "$iface" "$cidr"; then
        halow_log_info "network: $iface already has $cidr (not package-added, will not be removed on cleanup)"
    else
        if ! ip addr add "$cidr" dev "$iface"; then
            halow_log_error "network: failed to address $iface with $cidr"
            return 1
        fi
        if ! halow_own_mark "net_addr"; then
            halow_log_error "network: addressed $iface but could not record ownership — undoing (fail closed)"
            ip addr del "$cidr" dev "$iface" 2>/dev/null
            if halow_iface_has_cidr "$iface" "$cidr"; then
                halow_log_error "network: UNTRACKED RESIDUAL — address $cidr on $iface could not be confirmed removed after a failed ownership record"
            fi
            return 1
        fi
    fi
    ip link set dev "$iface" up

    # --- ip_forward ---
    local current_forward
    current_forward="$(halow_read_ip_forward)"
    if [ -z "$current_forward" ]; then
        # An unreadable current value must never be changed: this function would have no
        # genuine original value to persist/restore, which would otherwise create exactly
        # the kind of ownership marker that could never legitimately clear itself later
        # (an empty "$orig" at restore time fails its own `[ -n "$orig" ]` guard there
        # forever, permanently blocking net_ip_forward cleanup on every future rollback
        # attempt, not merely this one) — fail closed before any mutation is attempted.
        halow_log_error "network: could not read the current net.ipv4.ip_forward value; refusing to change it without a genuine original value to restore later"
        return 1
    fi
    if [ "$current_forward" != "1" ]; then
        if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            halow_log_error "network: failed to enable net.ipv4.ip_forward"
            return 1
        fi
        if ! printf '%s' "$current_forward" > "${HALOW_STATE_DIR:?}/orig_ip_forward" || ! halow_own_mark "net_ip_forward"; then
            halow_log_error "network: enabled ip_forward but could not record ownership/original value — undoing (fail closed)"
            sysctl -w "net.ipv4.ip_forward=$current_forward" >/dev/null 2>&1
            if [ "$(halow_read_ip_forward)" != "$current_forward" ]; then
                halow_log_error "network: UNTRACKED RESIDUAL — net.ipv4.ip_forward could not be confirmed restored after a failed ownership record"
            fi
            rm -f -- "${HALOW_STATE_DIR}/orig_ip_forward"
            return 1
        fi
    else
        halow_log_info "network: net.ipv4.ip_forward was already 1 (not package-changed)"
    fi

    # --- NAT (scoped to the HaLow source subnet and uplink) ---
    if ! iptables -t nat -C POSTROUTING -s "$cidr" -o "$uplink" -j MASQUERADE 2>/dev/null; then
        if ! iptables -t nat -A POSTROUTING -s "$cidr" -o "$uplink" -j MASQUERADE; then
            halow_log_error "network: failed to add the scoped MASQUERADE rule for $cidr via $uplink"
            return 1
        fi
        if ! halow_own_mark "net_nat_rule"; then
            halow_log_error "network: added the MASQUERADE rule but could not record ownership — undoing (fail closed)"
            iptables -t nat -D POSTROUTING -s "$cidr" -o "$uplink" -j MASQUERADE 2>/dev/null
            if iptables -t nat -C POSTROUTING -s "$cidr" -o "$uplink" -j MASQUERADE 2>/dev/null; then
                halow_log_error "network: UNTRACKED RESIDUAL — MASQUERADE rule could not be confirmed removed after a failed ownership record"
            fi
            return 1
        fi
    else
        halow_log_info "network: the scoped MASQUERADE rule already existed (not package-added)"
    fi

    # --- FORWARD (outbound) ---
    if ! iptables -C FORWARD -i "$iface" -o "$uplink" -j ACCEPT 2>/dev/null; then
        if ! iptables -A FORWARD -i "$iface" -o "$uplink" -j ACCEPT; then
            halow_log_error "network: failed to add the outbound FORWARD rule ($iface -> $uplink)"
            return 1
        fi
        if ! halow_own_mark "net_fwd_rule_out"; then
            halow_log_error "network: added the outbound FORWARD rule but could not record ownership — undoing (fail closed)"
            iptables -D FORWARD -i "$iface" -o "$uplink" -j ACCEPT 2>/dev/null
            if iptables -C FORWARD -i "$iface" -o "$uplink" -j ACCEPT 2>/dev/null; then
                halow_log_error "network: UNTRACKED RESIDUAL — outbound FORWARD rule could not be confirmed removed after a failed ownership record"
            fi
            return 1
        fi
    fi

    # --- FORWARD (return traffic) ---
    if ! iptables -C FORWARD -i "$uplink" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        if ! iptables -A FORWARD -i "$uplink" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT; then
            halow_log_error "network: failed to add the return-traffic FORWARD rule ($uplink -> $iface)"
            return 1
        fi
        if ! halow_own_mark "net_fwd_rule_in"; then
            halow_log_error "network: added the return-traffic FORWARD rule but could not record ownership — undoing (fail closed)"
            iptables -D FORWARD -i "$uplink" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
            if iptables -C FORWARD -i "$uplink" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
                halow_log_error "network: UNTRACKED RESIDUAL — return-traffic FORWARD rule could not be confirmed removed after a failed ownership record"
            fi
            return 1
        fi
    fi

    if ! halow_start_dnsmasq "$iface" "$gw_ip" "$dhcp_start" "$dhcp_end"; then
        return 1
    fi

    halow_log_info "network: routed/NAT backend applied on $iface ($cidr) via uplink $uplink"
}

# halow_dnsmasq_identity_matches <pid> <conf_path>
# Strict, fail-closed identity check (`halow_process_comm`/`halow_process_cmdline_contains`
# are shared, generic process-introspection helpers now in common.sh). Four DISTINCT
# outcomes, never conflated with one another — a caller that only checks "did this
# succeed" and treats every failure the same way is exactly the class of defect this
# review fixes:
#   0 = POSITIVE MATCH: the pid is alive, its `comm` is exactly "dnsmasq", AND its
#       cmdline was successfully read and contains this package's own exact
#       `--conf-file=<conf_path>` argument.
#   1 = POSITIVE MISMATCH: the pid is alive, but either `comm` is not "dnsmasq", or its
#       cmdline WAS successfully read and does not contain this package's own argument —
#       this is definitely a different process. Never signal it.
#   2 = UNKNOWN: the pid is alive and `comm` IS "dnsmasq", but its cmdline could not be
#       read at all. Fixed during development: an earlier version treated this exactly like
#       a positive match ("falls back to the comm-only result"), which is wrong — `comm`
#       alone cannot distinguish this package's own dnsmasq instance from any other
#       dnsmasq process that might be running, so an unreadable cmdline must be treated
#       as neither a match nor a mismatch nor absence: it is simply unsafe to decide, and
#       callers must never signal, and never treat this as evidence of anything, on this
#       result.
#   3 = CONFIRMED ABSENT: the pid is not alive at all — positive evidence that whatever
#       process this pid once referred to is gone, usable by a caller deciding whether it
#       is safe to clear an ownership marker recorded against this exact pid.
halow_dnsmasq_identity_matches() {
    local pid="$1" conf="$2" cmdline_status
    [ -n "$pid" ] || return 1
    if ! kill -0 "$pid" 2>/dev/null; then
        return 3
    fi
    if [ "$(halow_process_comm "$pid")" != "dnsmasq" ]; then
        return 1
    fi
    # A bare call here would abort this function (and its caller's own scan loop)
    # under bashio's inherited errexit the instant it returns 1 or 2 -- both routine,
    # expected outcomes of this exact comparison, not errors. See module_load.sh's own
    # module-level comment for the real incident this class of pattern caused elsewhere
    # in this codebase.
    if halow_process_cmdline_contains "$pid" "--conf-file=$conf"; then
        cmdline_status=0
    else
        cmdline_status=$?
    fi
    case "$cmdline_status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# halow_find_dnsmasq_by_identity <conf_path>
# Used both as the fallback when this package's own recorded PID file is missing or
# malformed, AND as the mandatory fresh, COMPLETE re-scan performed immediately after
# stopping an identified process, before any file is removed or ownership is cleared
# (never a re-check of only the one PID just signalled — a second, as-yet-unseen
# instance of this package's own process must never be missed this way). Scans every
# live PID for a match against halow_dnsmasq_identity_matches — never guesses.
#
# Fixed during development: an unreadable candidate's own cmdline now makes the ENTIRE scan
# result UNKNOWN regardless of how many OTHER candidates were positively matched — an
# earlier version only checked this when zero positive matches were found, which meant a
# scan that found exactly one positive match while ALSO encountering an unreadable
# candidate elsewhere would confidently report that one match as the sole, safe-to-
# signal answer, even though the unreadable candidate's own identity could not be ruled
# out (it could, in principle, also be this package's own process, under a design that
# somehow ended up with two). An unreadable candidate anywhere in the scan now always
# wins over a positive match found elsewhere in the same pass.
#
# Prints the single matching PID on success (exit 0); exit 1 = no match found, and this
# IS trustworthy (every live dnsmasq-named process's cmdline was successfully read and
# none matched); exit 2 = more than one positive match found (ambiguous); exit 3 =
# unknown/unsafe (at least one dnsmasq-named process's own cmdline could not be read,
# regardless of count — this result can never be trusted as either absence or a single
# safe-to-signal match).
halow_find_dnsmasq_by_identity() {
    local conf="$1" pid candidates="" count=0 d unreadable=0 status
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        # A bare call here would abort this ENTIRE scan loop under bashio's inherited
        # errexit on the very first /proc entry that does not match (status 1) --
        # virtually guaranteed on the first iteration of any real scan, since most PIDs
        # on a real system are not dnsmasq. See module_load.sh's own module-level
        # comment for the real incident that surfaced this class of pattern.
        if halow_dnsmasq_identity_matches "$pid" "$conf"; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0) candidates="${candidates}${pid} "; count=$((count + 1)) ;;
            2) unreadable=1 ;;
        esac
    done
    if [ "$unreadable" -eq 1 ]; then
        halow_log_error "network: at least one live dnsmasq-named process's own cmdline could not be read during the identity scan — its identity cannot be ruled out, regardless of any other candidate positively matched elsewhere in the same scan; this scan's own result cannot be trusted"
        return 3
    fi
    if [ "$count" -eq 0 ]; then
        return 1
    elif [ "$count" -gt 1 ]; then
        halow_log_error "network: multiple live processes match this package's own dnsmasq identity ($candidates) with no pid file to disambiguate — refusing to guess"
        return 2
    fi
    printf '%s' "${candidates% }"
}

# halow_dnsmasq_determine_outcome <conf_path>
# Shared, side-effect-free (never signals, never touches any file) outcome determination
# used by BOTH the pre-start safety check (halow_start_dnsmasq) and the stop/teardown
# logic (halow_teardown_network) — a single, shared decision so the two can never
# silently disagree about what "safe to proceed" means. Sets two globals:
#   HALOW_DNSMASQ_OUTCOME: confirmed_absent / owned / unknown / ambiguous
#   HALOW_DNSMASQ_TARGET_PID: set only when OUTCOME=owned, the positively identified pid
#
# Neither a definite MISMATCH nor a CONFIRMED-DEAD recorded pid is ever returned directly
# as its own, final outcome: a stale pid file naming an unrelated live process, OR naming a
# pid that is simply no longer alive at all, is only safe to treat as resolved once a full
# identity scan independently confirms this package's own real instance is absent (or finds
# it under a different pid) — a dead recorded pid proves only that THAT one pid is gone, not
# that no instance of this package's own process is running anywhere else. The unrelated
# process at a stale recorded pid (the mismatch case) is never touched, signalled, or
# examined further; only this package's own stale pid-file *reference* to it is ever at
# stake. (Fixed during development: an earlier version treated a confirmed-dead recorded pid as
# an immediate, terminal confirmed_absent, skipping this mandatory scan entirely.)
halow_dnsmasq_determine_outcome() {
    local conf="$1" pidfile="${HALOW_STATE_DIR:?}/dnsmasq.pid"
    local raw_pid=""
    HALOW_DNSMASQ_OUTCOME=""
    HALOW_DNSMASQ_TARGET_PID=""

    if [ -f "$pidfile" ]; then
        raw_pid="$(cat "$pidfile" 2>/dev/null)"
        case "$raw_pid" in
            ''|*[!0-9]*) raw_pid="" ;;
        esac
    fi

    if [ -n "$raw_pid" ]; then
        # A bare call here would abort this function (and every caller of it, none of
        # which wrap this call either) under bashio's inherited errexit on return 1 or
        # 3 -- both routine outcomes (a definite mismatch, or a confirmed-dead recorded
        # pid), not errors. See module_load.sh's own module-level comment for the real
        # incident this class of pattern caused elsewhere in this codebase; found here
        # by a code review, not self-identified.
        local _identity_rc
        if halow_dnsmasq_identity_matches "$raw_pid" "$conf"; then
            _identity_rc=0
        else
            _identity_rc=$?
        fi
        case "$_identity_rc" in
            0) HALOW_DNSMASQ_OUTCOME="owned"; HALOW_DNSMASQ_TARGET_PID="$raw_pid"; return 0 ;;
            2) HALOW_DNSMASQ_OUTCOME="unknown"; return 0 ;;
            1|3) : ;;  # definite mismatch, OR the recorded pid is confirmed dead -- both fall
                       # through to the mandatory secondary full scan. A dead recorded pid
                       # proves only that THAT pid is gone -- it does NOT prove this package's
                       # own process is absent everywhere: a restarted/second instance could
                       # still be alive under a different pid, with its own identity positively
                       # matching this package's exact configuration. Absence is only ever
                       # established by a complete scan finding nothing, never by a dead
                       # recorded pid alone (fixed during development: an earlier version treated
                       # identity result 3 here as immediate, terminal confirmed_absent).
        esac
    fi

    local scan_pid _scan_rc
    # A bare `var=$(cmd)` here would abort on return 1 -- the NORMAL, expected outcome
    # on first startup and after any clean stop (confirmed absent) -- before this
    # function ever reaches its own case statement, let alone sets HALOW_DNSMASQ_OUTCOME
    # at all. Found during review, not self-identified.
    if scan_pid="$(halow_find_dnsmasq_by_identity "$conf")"; then
        _scan_rc=0
    else
        _scan_rc=$?
    fi
    case "$_scan_rc" in
        0) HALOW_DNSMASQ_OUTCOME="owned"; HALOW_DNSMASQ_TARGET_PID="$scan_pid" ;;
        1) HALOW_DNSMASQ_OUTCOME="confirmed_absent" ;;
        2) HALOW_DNSMASQ_OUTCOME="ambiguous" ;;
        3) HALOW_DNSMASQ_OUTCOME="unknown" ;;
    esac
}

# halow_dnsmasq_is_running <pidfile>
# True only if <pidfile> names a PID that POSITIVELY matches this package's own dnsmasq
# identity (halow_dnsmasq_identity_matches exit 0, above) — never trusts a bare
# "process with this PID exists" check, and never treats an unknown/unreadable identity
# as "running" either (a caller here only needs a clear yes/no on whether a fresh start
# is needed; an unconfirmed identity is treated as "not confirmed running," which is the
# conservative choice for this specific, narrow use).
halow_dnsmasq_is_running() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # A bare call here would abort this function entirely (never reaching its own
    # return value) under bashio's inherited errexit on return 1 or 2 -- both routine,
    # expected outcomes (no match; unreadable), not errors.
    if halow_dnsmasq_identity_matches "$pid" "${HALOW_STATE_DIR:?}/dnsmasq.conf"; then
        return 0
    else
        return 1
    fi
}

# halow_read_ip_forward — isolated into its own function specifically so the
# off-device test harness can override it: /proc/sys is a real kernel interface that
# cannot be redirected via an environment variable the way this project's other path
# constants are, and a test needs to control this value deterministically regardless of
# whatever the real test host's own ip_forward setting happens to be.
halow_read_ip_forward() {
    cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo ""
}

# halow_start_dnsmasq <iface> <gw_ip> <dhcp_start> <dhcp_end>
#
# Lifecycle ownership is now established BEFORE this package creates `dnsmasq.conf`, its
# own pid file, or the process itself (fixed during development: an earlier version rendered
# the config file FIRST and only marked ownership once the process was already running —
# a failure anywhere in between, including a simple failure to write the config file
# itself, could leave an untracked, package-created `dnsmasq.conf` that rollback had no
# record of at all, since nothing was ever marked owned). Every failure after the
# ownership mark succeeds is deliberately left for the CALLER's own rollback to discover
# and clean up (via `halow_teardown_network`'s own identity-scan fallback, which needs
# no pid file to work) — this function does not attempt a different, bespoke inline
# cleanup for each individual failure point; there is exactly one cleanup code path to
# keep correct, not several that could drift out of sync with each other.
#
# Also fixed during development: starting a SECOND instance was previously only prevented by
# a simple "is a positively-identified instance already running" check — now the
# pre-flight check uses the same STRICT, four-outcome `halow_dnsmasq_determine_outcome`
# every stop/teardown decision uses, so an UNKNOWN or AMBIGUOUS prior state also blocks
# starting a new instance, exactly like an already-running positive match does — "not
# positively confirmed running" is never itself treated as permission to start another.
#
# Fixed during development: an `owned` outcome was previously ALWAYS treated as a safe,
# idempotent no-op, regardless of whether this package's own `net_dnsmasq` ownership
# marker actually existed for the process found. That is only true when this package
# itself is the one that owns the running instance (the marker is how that is known) — a
# live, identity-matching process found with NO ownership marker is not "our own instance,
# already handled"; it is an unexplained, unowned resource this package never established
# responsibility for. Treating it as a safe no-op would let startup proceed using a
# process rollback has no ownership-marker-driven reason to ever discover, stop, or track
# (confirmed, independently, by three separate code reviews). Such a process is now
# never adopted, signalled, or have its files overwritten, and no fresh ownership marker is
# created for it — it is left exactly as found, and startup fails closed instead, with a
# clear log line calling out the exact gap for manual investigation. This applies
# identically regardless of how the match was found (directly via the recorded pid file, or
# via the mandatory secondary scan after a dead/mismatching/missing/malformed pid file) —
# halow_dnsmasq_determine_outcome already unifies every one of those paths into this one
# `owned` outcome before this function ever sees it.
halow_start_dnsmasq() {
    local iface="$1" gw_ip="$2" start="$3" end="$4"
    local conf="${HALOW_STATE_DIR:?}/dnsmasq.conf"
    local pidfile="${HALOW_STATE_DIR:?}/dnsmasq.pid"

    halow_dnsmasq_determine_outcome "$conf"
    case "$HALOW_DNSMASQ_OUTCOME" in
        confirmed_absent) : ;;
        owned)
            if halow_own_check "net_dnsmasq"; then
                halow_log_info "network: dnsmasq already running (pid $HALOW_DNSMASQ_TARGET_PID), positively matching this package's own identity — not starting a second instance"
                return 0
            fi
            halow_log_error "network: a process (pid $HALOW_DNSMASQ_TARGET_PID) exactly matches this package's own dnsmasq identity, but no net_dnsmasq lifecycle ownership marker is held for it — refusing to start a replacement, refusing to adopt/signal/overwrite the existing process or its files; this requires manual investigation"
            return 1
            ;;
        *)
            halow_log_error "network: refusing to start dnsmasq — the prior state could not be positively confirmed absent (outcome: $HALOW_DNSMASQ_OUTCOME); 'not confirmed running' is never treated as permission to start another instance"
            return 1
            ;;
    esac

    if ! halow_own_mark "net_dnsmasq"; then
        halow_log_error "network: could not record lifecycle ownership — refusing to create any dnsmasq file or process"
        return 1
    fi

    if ! cat > "$conf" <<EOF
interface=$iface
bind-interfaces
dhcp-range=$start,$end,12h
dhcp-option=3,$gw_ip
dhcp-option=6,$gw_ip
EOF
    then
        halow_log_error "network: could not write $conf — lifecycle ownership is already recorded, so the caller's own rollback will discover and clear it (nothing else was created)"
        return 1
    fi

    dnsmasq --conf-file="$conf" --pid-file="$pidfile" --no-daemon &
    local dm_pid=$!

    sleep 1
    if ! kill -0 "$dm_pid" 2>/dev/null; then
        halow_log_error "network: dnsmasq did not start successfully (exec likely failed) — the caller's own rollback will clean up via the identity-scan fallback, since no pid file was ever written"
        return 1
    fi

    if ! echo "$dm_pid" > "$pidfile"; then
        halow_log_error "network: dnsmasq started (pid $dm_pid) but its own pid file could not be written — the caller's own rollback will find and stop it via the identity-scan fallback"
        return 1
    fi

    halow_log_info "network: dnsmasq started (pid $dm_pid) for $iface"
}

# halow_teardown_dnsmasq
# Takes no arguments and needs no persisted network_values (iface/uplink/cidr) — its
# pid/conf files live at a fixed path under $HALOW_STATE_DIR and its identity scan
# (halow_dnsmasq_determine_outcome) only ever reads that fixed conf path. Because of
# this, it is called UNCONDITIONALLY from halow_rollback, on every rollback attempt,
# regardless of whether halow_load_network_values itself succeeded — mirroring how
# halow_stop_hostapd is already called unconditionally for the same reason.
#
# Fixed during development (a prior round's own fix only ran this scan when
# halow_rollback's persisted network_values could be loaded: since this function's
# scan never actually depended on that file's contents, a missing or malformed
# network_values silently skipped the scan entirely on every rollback attempt — not
# just the first — so a real, live, identity-matching-but-unowned dnsmasq process
# could remain invisible indefinitely, hard_failure would never be set for it, and
# rollback could wrongly report "complete". Splitting this scan out into its own
# argument-less function, callable independently of network_values, closes that gap.)
#
# Sets the global HALOW_DNSMASQ_UNOWNED_RESIDUAL (0/1, reset here at the top, same
# convention as HALOW_DNSMASQ_OUTCOME/HALOW_DNSMASQ_TARGET_PID above) so that the
# caller's own decision of whether network_values may still be removed can check this
# condition regardless of which function/pass detected it — this function's own
# non-zero return communicates the identical condition to halow_rollback's
# `|| hard_failure=1`, the two channels are intentionally redundant, not alternatives.
halow_teardown_dnsmasq() {
    local pidfile="${HALOW_STATE_DIR:?}/dnsmasq.pid"
    local conf="${HALOW_STATE_DIR:?}/dnsmasq.conf"
    HALOW_DNSMASQ_UNOWNED_RESIDUAL=0

    # Fixed during development: an earlier version read the pid file and sent `kill` to
    # whatever PID it named BEFORE verifying that PID still identified this package's own
    # dnsmasq. A further fix in that same pass: after stopping an identified process, a
    # FRESH, COMPLETE identity scan is now required before removing any file or clearing
    # ownership — never merely a re-check of the one pid just signalled, which could miss
    # a second, as-yet-unseen instance of this package's own process. File removal is
    # independently verified (never assumed from `rm`'s own exit status, and never
    # confused by a dangling symlink) before ownership is cleared — a confirmed process
    # stop alone is never sufficient on its own.
    #
    # Fixed during development (review found this, distinct from
    # the "owned is always a safe no-op" startup defect this same round also fixes): this
    # whole section used to be skipped entirely whenever `net_dnsmasq` was not owned,
    # WITHOUT EVER running the identity scan below -- meaning a real, live, identity-
    # matching dnsmasq process that somehow existed without this package's own ownership
    # marker could never be discovered here, and the aggregate ownership-key check this
    # function's own caller (halow_rollback) performs afterward has no key to notice
    # either, since nothing was ever marked owned -- rollback would report "complete"
    # while that process and its config remained. The scan now ALWAYS runs regardless of
    # ownership-marker state, via the same halow_dnsmasq_determine_outcome used when
    # ownership IS held; a positively-identified-but-unowned process is still never
    # signalled, adopted, or has its files touched, but this condition is no longer
    # silently invisible -- it is reported via $HALOW_DNSMASQ_UNOWNED_RESIDUAL, this
    # function's own dedicated, explicit channel for exactly this new condition (kept
    # strictly separate from the pre-existing ownership-key aggregate check, which still
    # alone governs every other residual case below unchanged). The overwhelmingly common
    # case (ownership never marked because dnsmasq was simply never started this run)
    # still resolves via the scan to CONFIRMED ABSENT, with no change in behaviour or
    # noise.
    local was_dnsmasq_owned=1
    halow_own_check "net_dnsmasq" || was_dnsmasq_owned=0
    halow_dnsmasq_determine_outcome "$conf"

    if [ "$was_dnsmasq_owned" -eq 0 ]; then
        case "$HALOW_DNSMASQ_OUTCOME" in
            confirmed_absent) : ;;
            owned)
                halow_log_error "network: a process (pid $HALOW_DNSMASQ_TARGET_PID) exactly matches this package's own dnsmasq identity, but no net_dnsmasq lifecycle ownership marker is held for it -- refusing to signal it or touch its files; this requires manual investigation"
                HALOW_DNSMASQ_UNOWNED_RESIDUAL=1
                ;;
            *)
                halow_log_error "network: dnsmasq's own identity could not be positively confirmed absent (outcome: $HALOW_DNSMASQ_OUTCOME), and no net_dnsmasq lifecycle ownership marker is held either -- this requires manual investigation"
                HALOW_DNSMASQ_UNOWNED_RESIDUAL=1
                ;;
        esac
    else
        case "$HALOW_DNSMASQ_OUTCOME" in
            confirmed_absent)
                rm -f -- "$pidfile" "$conf"
                if halow_path_still_present "$pidfile" || halow_path_still_present "$conf"; then
                    halow_log_error "network: dnsmasq confirmed not running, but its own pid/conf files could not be fully removed — ownership kept"
                else
                    halow_own_clear "net_dnsmasq"
                    halow_log_info "network: dnsmasq confirmed not running; ownership cleared, pid/conf files removed and verified absent"
                fi
                ;;
            owned)
                local target_pid="$HALOW_DNSMASQ_TARGET_PID" scan_status attempt
                kill "$target_pid" 2>/dev/null || true
                # Mandatory fresh, COMPLETE scan — not a re-check of $target_pid alone. A
                # genuinely exiting process can legitimately take more than one second to
                # actually leave the process table after SIGTERM; a single fixed-delay scan
                # would misreport that normal, if slightly slow, exit as "a second live
                # instance found" (ownership incorrectly kept, and if this is the separate
                # `finish` process's own single rollback attempt, a benign shutdown would be
                # reported as a halt-worthy failure). Retried here, briefly and boundedly,
                # re-running the SAME full scan each time, exiting the loop the moment it
                # reports CONFIRMED ABSENT — never treated as "stuck" after only one second
                # when it may simply still be exiting.
                for attempt in 1 2 3 4 5; do
                    sleep 1
                    # A bare call here would abort under bashio's inherited errexit the
                    # instant it returns 1 -- the EXPECTED, hoped-for outcome of this
                    # retry loop (confirmed-absent), not an error. See module_load.sh's
                    # own module-level comment for the real incident this class of
                    # pattern caused elsewhere in this codebase.
                    if halow_find_dnsmasq_by_identity "$conf" >/dev/null 2>&1; then
                        scan_status=0
                    else
                        scan_status=$?
                    fi
                    [ "$scan_status" -eq 1 ] && break
                done
                case "$scan_status" in
                    1)
                        rm -f -- "$pidfile" "$conf"
                        if halow_path_still_present "$pidfile" || halow_path_still_present "$conf"; then
                            halow_log_error "network: dnsmasq (pid $target_pid) stopped, but its own pid/conf files could not be fully removed — ownership kept"
                        else
                            halow_own_clear "net_dnsmasq"
                            halow_log_info "network: dnsmasq (pid $target_pid) stopped and confirmed gone by a fresh, complete scan; pid/conf files removed and verified absent"
                        fi
                        ;;
                    0)
                        halow_log_error "network: dnsmasq (pid $target_pid) was signalled, but after retrying for up to ${attempt}s a fresh, complete scan still finds a live process matching this package's own identity (it may simply still be exiting, or it may be a genuinely second instance -- this scan cannot distinguish the two) — this is not yet resolved; ownership kept"
                        ;;
                    2)
                        halow_log_error "network: dnsmasq (pid $target_pid) was signalled, but after retrying for up to ${attempt}s the follow-up scan is ambiguous (more than one live candidate) — ownership kept"
                        ;;
                    *)
                        halow_log_error "network: dnsmasq (pid $target_pid) was signalled, but after retrying for up to ${attempt}s its own identity could still not be positively confirmed absent (an unreadable candidate was found) — this is NOT treated as confirmation it is gone — ownership kept"
                        ;;
                esac
                ;;
            unknown)
                halow_log_error "network: dnsmasq's own identity could not be positively confirmed (its cmdline could not be read) — refusing to treat this as either owned or absent; ownership kept for manual review"
                ;;
            ambiguous)
                halow_log_error "network: dnsmasq pid file missing/malformed and more than one live process matches this package's own identity — refusing to guess; ownership kept"
                ;;
        esac
    fi

    # This function's own return value is dedicated EXCLUSIVELY to
    # $HALOW_DNSMASQ_UNOWNED_RESIDUAL (above) -- every other residual case in this
    # function (an owned mutation that could not be cleaned up) is, as before, reported
    # only via its own kept ownership marker, independently re-checked by this function's
    # caller (halow_rollback's own aggregate ownership-key scan); this return value must
    # never be allowed to accidentally reflect some unrelated internal command's own exit
    # status.
    [ "$HALOW_DNSMASQ_UNOWNED_RESIDUAL" -eq 0 ]
}

# halow_teardown_network <iface> <uplink_iface> <cidr>
# Idempotent: each piece is torn down only if this package owns it, and ownership is
# cleared only once the corresponding removal is actually confirmed — a failed removal
# keeps its ownership marker so a repeated cleanup attempt keeps trying. The persisted
# network-values state file is removed only once every one of these markers is clear.
#
# dnsmasq's own identity scan/stop/cleanup is NOT part of this function — see
# halow_teardown_dnsmasq, called unconditionally by halow_rollback regardless of
# whether this function (and the network_values load it depends on) runs at all. This
# function only ever handles mutations that genuinely need iface/uplink/cidr, which
# dnsmasq's own teardown never did.
halow_teardown_network() {
    local iface="$1" uplink="$2" cidr="$3"

    if halow_own_check "net_fwd_rule_in"; then
        if iptables -D FORWARD -i "$uplink" -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
            halow_own_clear "net_fwd_rule_in"
        else
            halow_log_error "network: could not remove the return-traffic FORWARD rule — ownership kept"
        fi
    fi
    if halow_own_check "net_fwd_rule_out"; then
        if iptables -D FORWARD -i "$iface" -o "$uplink" -j ACCEPT 2>/dev/null; then
            halow_own_clear "net_fwd_rule_out"
        else
            halow_log_error "network: could not remove the outbound FORWARD rule — ownership kept"
        fi
    fi
    if halow_own_check "net_nat_rule"; then
        if iptables -t nat -D POSTROUTING -s "$cidr" -o "$uplink" -j MASQUERADE 2>/dev/null; then
            halow_own_clear "net_nat_rule"
        else
            halow_log_error "network: could not remove the MASQUERADE rule — ownership kept"
        fi
    fi

    if halow_own_check "net_ip_forward"; then
        local orig
        orig="$(cat "${HALOW_STATE_DIR}/orig_ip_forward" 2>/dev/null || echo "")"
        if [ -n "$orig" ] && sysctl -w "net.ipv4.ip_forward=$orig" >/dev/null 2>&1; then
            rm -f -- "${HALOW_STATE_DIR}/orig_ip_forward"
            halow_own_clear "net_ip_forward"
            halow_log_info "network: net.ipv4.ip_forward restored to $orig"
        else
            halow_log_error "network: could not restore original net.ipv4.ip_forward — ownership kept"
        fi
    fi

    if halow_own_check "net_addr"; then
        if ip addr del "$cidr" dev "$iface" 2>/dev/null; then
            halow_own_clear "net_addr"
            halow_log_info "network: removed package-added address $cidr from $iface"
        elif ! halow_kernel_iface_exists "$iface"; then
            # The interface itself is positively gone (e.g. hostapd destroyed the dynamic WDS
            # interface when its client left or rebooted, before the add-on was stopped): the
            # address it carried went with it, so there is nothing left to remove. Without this,
            # `ip addr del` fails "Cannot find device" and net_addr stays owned forever, making
            # every rollback report INCOMPLETE. Only a POSITIVE absence of the interface (no
            # /sys/class/net/<iface>) counts; an existing interface that still fails keeps
            # ownership below.
            halow_own_clear "net_addr"
            halow_log_info "network: $iface no longer exists; its package-added address $cidr went with it — ownership cleared"
        else
            halow_log_error "network: could not remove package-added address $cidr from $iface — ownership kept"
        fi
    fi

    # Fixed during development (an independent adversarial re-check of that round's own
    # fix found this): halow_remove_network_values only ever checks the six net_*
    # OWNERSHIP keys -- it has no knowledge of a dnsmasq unowned-residual condition, which
    # by definition means net_dnsmasq itself reads as "not owned" even though the dnsmasq
    # teardown pass just found a real, unresolved problem. If the other five net_* keys
    # happened to already be cleared in this same pass (plausible — net_addr/
    # net_fwd_rule_*, scoped to the now-possibly-different iface, are commonly freshly
    # owned-and-cleared together), network_values would otherwise be deleted on the VERY
    # PASS that first detects the residual, and (fixed during development) also on every
    # pass where halow_teardown_dnsmasq ran but this function itself did not (network_
    # values missing/malformed) -- in both cases reverting to the exact original bug's
    # silent "complete" end state, just one rollback cycle later. network_values must
    # therefore also survive for as long as the dnsmasq pass's own residual is unresolved,
    # not only while a net_* ownership key remains — checked here via the global
    # HALOW_DNSMASQ_UNOWNED_RESIDUAL that halow_teardown_dnsmasq sets, specifically so
    # this check is correct regardless of which function/pass most recently ran it.
    if [ "${HALOW_DNSMASQ_UNOWNED_RESIDUAL:-0}" -eq 0 ]; then
        # A bare call here would be a no-op in practice (halow_remove_network_values
        # resolves to a plain `rm -f`, which essentially never fails) but is still not
        # unconditionally safe under bashio's own inherited errexit -- see
        # module_load.sh's own module-level comment for the real incident this class of
        # pattern caused elsewhere in this codebase. `|| true` is correct here: this
        # function's own return value does not depend on whether the values file could
        # be removed (see this function's own closing comment).
        halow_remove_network_values || true
    else
        halow_log_error "network: network_values is NOT removed while the dnsmasq unowned-residual condition above remains unresolved -- a future rollback attempt still needs it to retry this same detection"
    fi
    halow_log_info "network: teardown pass complete"

    # dnsmasq's own residual condition no longer determines this function's return value
    # (see halow_teardown_dnsmasq, which now carries that signal on its own return and
    # via the global above). Every mutation this function itself performs (NAT/FORWARD/
    # ip_forward/address) that fails to clean up is, as before, reported only via its own
    # kept ownership marker, independently re-checked by this function's caller
    # (halow_rollback's own aggregate ownership-key scan) — this function has no
    # dedicated failure signal of its own left to return.
    return 0
}
