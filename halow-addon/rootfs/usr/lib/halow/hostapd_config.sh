#!/usr/bin/env bash
# halow: hostapd_s1g config rendering. Reuses the baked-in, already-proven AU/WPA3-SAE
# template unchanged — only `interface=`/`ssid=` are substituted and `wpa_passphrase=`
# appended once (idempotent on restart).
#
# Injection safety (fixed during development): substitution is done with `awk -v`, not
# `sed`, specifically because `sed`'s replacement text is itself parsed for `&` (whole
# match), `/` (delimiter), and embedded newlines — an SSID or interface name containing
# any of those could corrupt or redirect the substitution. `awk -v name=value` passes
# the value as pure data; it is never re-interpreted as part of the awk program text,
# so no customer-supplied value can inject additional awk code or additional config
# lines this way. Both values are additionally validated (validate.sh) before this
# function is ever called, and this function itself re-validates the passphrase length
# as a last-resort, defence-in-depth check.
#
# SECRET SAFETY: the passphrase is a required, customer-supplied add-on option (never a
# generated or fixed default) and is written directly to the rendered config file. It
# is never echoed, logged, or passed on any command line visible via `ps` — `printf`
# below is always bash's own builtin (never `command printf`/an external binary), so the
# expanded passphrase never becomes a separate process's own argv. Callers must never
# wrap a call to halow_render_hostapd_config in `set -x`.
#
# Hardened (this change, and a further fail-closed fix after it): the temporary file is
# created restrictive from the moment it exists (a scoped `umask 077`, not a `chmod`
# applied only afterward) — an earlier version created it under whatever umask the
# process inherited and relied on a `chmod` applied only to the FINAL file, after the
# move, leaving the passphrase-bearing temporary file protected by nothing but the
# inherited umask for the entire window it existed. Every write, the permission change,
# and the final move are now individually checked; any failure removes the temporary
# file (it may already hold the passphrase) and returns non-zero rather than continuing.
# The final published file's own mode is read back and confirmed to actually be 0600 —
# never merely assumed because `chmod` itself ran without an error — and if that
# confirmation fails (unreadable, or any mode other than exactly 600), the just-published
# file at $dest is itself removed (and that removal is itself verified, not assumed)
# before returning failure: an earlier version of this specific check reported failure
# but left the published, password-bearing file in place.

# halow_render_hostapd_config <template> <iface> <ssid> <passphrase> <dest>
halow_render_hostapd_config() {
    local template="$1" iface="$2" ssid="$3" passphrase="$4" dest="$5"
    local tmp="$dest.halow-tmp.$$"

    if [ ! -f "$template" ]; then
        halow_log_error "hostapd-config: template not found: $template"
        return 1
    fi
    if ! halow_validate_passphrase "$passphrase"; then
        return 1
    fi

    # Create the temp file empty, restrictive from this exact moment, regardless of the
    # inherited umask — scoped to a subshell so the umask change never leaks back out.
    if ! ( umask 077 && : > "$tmp" ); then
        halow_log_error "hostapd-config: could not create a restrictive temporary file at $tmp"
        rm -f -- "$tmp"
        return 1
    fi

    # `>` on an already-existing file truncates and rewrites it in place; it does not
    # recreate the inode or reset the permissions just established above.
    if ! awk -v iface="$iface" -v ssid="$ssid" '
        /^interface=/ { print "interface=" iface; next }
        /^ssid=/       { print "ssid=" ssid; next }
        { print }
    ' "$template" > "$tmp"; then
        halow_log_error "hostapd-config: awk rendering failed — removing the temporary file"
        rm -f -- "$tmp"
        return 1
    fi

    if ! grep -q '^wpa_passphrase=' "$tmp"; then
        # Appended once, never duplicated on a restart — halow_render_hostapd_config
        # always renders fresh from the pristine template, so this line is only ever
        # absent the first time. printf, not awk/sed, for the passphrase line itself:
        # the value never passes through anything that parses it as a pattern.
        if ! printf 'wpa_passphrase=%s\n' "$passphrase" >> "$tmp"; then
            halow_log_error "hostapd-config: could not write the passphrase line — removing the temporary file (never left behind holding a secret)"
            rm -f -- "$tmp"
            return 1
        fi
    fi

    if ! chmod 600 -- "$tmp"; then
        halow_log_error "hostapd-config: could not set restrictive permissions on the temporary file — removing it rather than publishing a possibly-unprotected copy"
        rm -f -- "$tmp"
        return 1
    fi

    if ! mv -f -- "$tmp" "$dest"; then
        halow_log_error "hostapd-config: could not publish $dest — removing the temporary file"
        rm -f -- "$tmp"
        return 1
    fi

    local actual_mode
    actual_mode="$(stat -c '%a' "$dest" 2>/dev/null)"
    if [ "$actual_mode" != "600" ]; then
        # Fail-closed gap fixed during development: an earlier version returned failure here
        # but left the just-published, password-bearing file at $dest in place — an
        # unreadable or wrong mode was reported as an error, but the file itself was
        # never removed. Remove it, and VERIFY the removal actually took effect (never
        # just trust `rm`'s own exit status) before deciding how to report this.
        halow_log_error "hostapd-config: $dest does not report mode 600 after publication (found '${actual_mode:-unreadable}') — removing it rather than leaving a password-bearing file whose own permissions could not be confirmed"
        rm -f -- "$dest"
        if [ -e "$dest" ]; then
            halow_log_error "hostapd-config: CRITICAL — a password-bearing file at $dest could NOT be removed after its own permissions could not be confirmed as 600; it may remain on disk with unconfirmed, possibly unsafe permissions — manual intervention required"
        fi
        return 1
    fi

    halow_log_info "hostapd-config: rendered $dest (interface=$iface, ssid=$ssid; passphrase not logged)"
}

# --- hostapd_s1g process lifecycle (this change) ----------------------------------
#
# Fixed during development: `run`'s own stop-signal trap previously held `hostapd_s1g`'s own
# PID only in a shell variable, private to that one process. The separate `finish`
# process (which must independently be able to stop and clean up hostapd after an
# abnormal `run` exit — the whole reason `finish` exists) had no way to find it, so an
# orphaned hostapd_s1g could survive `finish`'s own call to halow_rollback indefinitely,
# along with the password-bearing rendered config `finish` also had no way to know was
# safe to remove. This is fixed by the SAME design `network_backend.sh` already uses for
# `dnsmasq`: a persisted pid file plus a strict, fail-closed identity check (kernel `comm`
# exactly "hostapd_s1g", AND its cmdline containing this package's own exact rendered
# config path) — so ANY process that later calls halow_stop_hostapd (`run`'s own trap,
# then `finish`, then a repeated rollback attempt) positively re-derives the same answer
# from durable state, never from in-memory data private to the process that started it.
#
# Unlike dnsmasq's own identity check, an unreadable cmdline here is NEVER treated as a
# fallback positive match under any circumstance (dnsmasq's own check no longer does
# this either, after this change — see network_backend.sh) — ownership of a
# radio-transmitting process must never be assumed from `comm` alone.

# halow_hostapd_identity_matches <pid> <conf_path>
# Same four-outcome contract as halow_dnsmasq_identity_matches in network_backend.sh:
#   0 = POSITIVE MATCH (alive, comm exactly "hostapd_s1g", cmdline read and matches).
#   1 = POSITIVE MISMATCH (alive, but comm or cmdline definitely does not match).
#   2 = UNKNOWN (alive, comm matches, but cmdline could not be read — never treated as a
#       match, a mismatch, or absence).
#   3 = CONFIRMED ABSENT (not alive at all).
halow_hostapd_identity_matches() {
    local pid="$1" conf="$2" cmdline_status
    [ -n "$pid" ] || return 1
    if ! kill -0 "$pid" 2>/dev/null; then
        return 3
    fi
    if [ "$(halow_process_comm "$pid")" != "hostapd_s1g" ]; then
        return 1
    fi
    # A bare call here would abort this function (and its caller's own scan loop)
    # under bashio's inherited errexit the instant it returns 1 or 2 -- both routine,
    # expected outcomes of this exact comparison, not errors. See module_load.sh's own
    # module-level comment for the real incident this class of pattern caused elsewhere
    # in this codebase.
    if halow_process_cmdline_contains "$pid" "$conf"; then
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

# halow_find_hostapd_by_identity <conf_path>
# Same contract as halow_find_dnsmasq_by_identity, including the SAME fix (this change):
# any unreadable candidate's own cmdline makes the ENTIRE scan result UNKNOWN regardless
# of how many OTHER candidates were positively matched — never conflated with "zero
# matches, confirmed absent" merely because a count of exactly one, or zero, was also
# reached. exit 0 = exactly one match (printed); exit 1 = none found, trustworthy; exit 2
# = ambiguous (more than one positive match); exit 3 = unknown/unsafe.
halow_find_hostapd_by_identity() {
    local conf="$1" pid candidates="" count=0 d unreadable=0 status
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        # A bare call here would abort this ENTIRE scan loop under bashio's inherited
        # errexit on the very first /proc entry that does not match (status 1) --
        # virtually guaranteed on the first iteration of any real scan, since most PIDs
        # on a real system are not hostapd_s1g. This is almost certainly the single
        # highest-probability-of-triggering instance of this bug class in this codebase
        # -- see module_load.sh's own module-level comment for the real incident that
        # surfaced this class of pattern.
        if halow_hostapd_identity_matches "$pid" "$conf"; then
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
        halow_log_error "hostapd-lifecycle: at least one live hostapd_s1g-named process's own cmdline could not be read during the identity scan — its identity cannot be ruled out, regardless of any other candidate positively matched elsewhere in the same scan; this scan's own result cannot be trusted"
        return 3
    fi
    if [ "$count" -eq 0 ]; then
        return 1
    elif [ "$count" -gt 1 ]; then
        halow_log_error "hostapd-lifecycle: multiple live processes match this package's own hostapd_s1g identity ($candidates) with no pid file to disambiguate — refusing to guess"
        return 2
    fi
    printf '%s' "${candidates% }"
}

# halow_hostapd_determine_outcome <conf_path>
# Shared, side-effect-free outcome determination, used identically by the pre-start
# safety check and by halow_stop_hostapd — see halow_dnsmasq_determine_outcome in
# network_backend.sh for the full rationale (this is its exact hostapd_s1g counterpart,
# including the same "a definite mismatch, OR a confirmed-dead recorded pid, always
# triggers a secondary full scan before absence can be concluded, and the unrelated live
# process at a stale recorded pid is never itself touched" design). Sets
# HALOW_HOSTAPD_OUTCOME (confirmed_absent / owned / unknown / ambiguous) and
# HALOW_HOSTAPD_TARGET_PID (set only when OUTCOME=owned).
halow_hostapd_determine_outcome() {
    local conf="$1" pidfile="${HALOW_STATE_DIR:?}/hostapd_s1g.pid"
    local raw_pid=""
    HALOW_HOSTAPD_OUTCOME=""
    HALOW_HOSTAPD_TARGET_PID=""

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
        if halow_hostapd_identity_matches "$raw_pid" "$conf"; then
            _identity_rc=0
        else
            _identity_rc=$?
        fi
        case "$_identity_rc" in
            0) HALOW_HOSTAPD_OUTCOME="owned"; HALOW_HOSTAPD_TARGET_PID="$raw_pid"; return 0 ;;
            2) HALOW_HOSTAPD_OUTCOME="unknown"; return 0 ;;
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
    # function ever reaches its own case statement, let alone sets HALOW_HOSTAPD_OUTCOME
    # at all. Found during review, not self-identified.
    if scan_pid="$(halow_find_hostapd_by_identity "$conf")"; then
        _scan_rc=0
    else
        _scan_rc=$?
    fi
    case "$_scan_rc" in
        0) HALOW_HOSTAPD_OUTCOME="owned"; HALOW_HOSTAPD_TARGET_PID="$scan_pid" ;;
        1) HALOW_HOSTAPD_OUTCOME="confirmed_absent" ;;
        2) HALOW_HOSTAPD_OUTCOME="ambiguous" ;;
        3) HALOW_HOSTAPD_OUTCOME="unknown" ;;
    esac
}

# halow_hostapd_ms_since_launch - prints the milliseconds since the last hostapd_s1g launch
# (empty when the clock is not available).
halow_hostapd_ms_since_launch() {
    local now="${EPOCHREALTIME:-}" a b
    [ -n "$now" ] && [ -n "${HALOW_HOSTAPD_LAUNCH_US:-}" ] || return 0
    a="${now/./}"; b="${HALOW_HOSTAPD_LAUNCH_US/./}"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$(( (10#$a - 10#$b) / 1000 ))"
}

# halow_start_hostapd <bin> <log> <conf>
# Starts hostapd_s1g and persists its own pid file. MUST be called as a PLAIN STATEMENT
# in the current shell — NEVER via command substitution `$(...)`. Fixed during development,
# confirmed by direct empirical reproduction (see the regression test in
# tests/test_hostapd_config.sh): backgrounding a long-running child inside a function
# whose own output is captured by `$(...)` does NOT return promptly, because the
# backgrounded child inherits the write end of the substitution's own pipe as its own
# stdout/stderr, and a command substitution's pipe is not considered closed (so `$(...)`
# does not return) until EVERY process holding that write end closes it — including a
# "backgrounded" child that was never explicitly redirected away from it. The earlier
# design (`HOSTAPD_PID="$(halow_start_hostapd ...)"`, with the function printing the pid
# on stdout) therefore blocked `run` until hostapd_s1g itself exited, defeating
# backgrounding entirely. Fixed by never wrapping this call in command substitution: the
# started pid is instead returned through the deliberately, distinctly named global
# `HALOW_LAST_STARTED_PID`, set directly in the CALLING shell (this function is sourced,
# not exec'd, so a plain variable assignment is visible to the caller immediately, with
# no pipe involved at all) — `run` reads it immediately after this call returns.
#
# This function no longer marks "hostapd_process" ownership itself, and no longer does
# its own pre-start safety check — fixed during development to establish lifecycle ownership
# BEFORE any password-bearing file, log, pid file, or process is created at all (see
# halow_hostapd_pre_start_check, below, which the caller must invoke first, before
# halow_render_hostapd_config, and well before this function). Any failure in this
# function is deliberately left for the caller's own rollback to discover and clean up —
# via the identity-scan fallback, since no pid file will exist for anything that failed
# before reaching the point of writing one — rather than attempting a different, bespoke
# inline cleanup for each individual failure point.
halow_start_hostapd() {
    local bin="$1" log="$2" conf="$3"
    local pidfile="${HALOW_STATE_DIR:?}/hostapd_s1g.pid"
    HALOW_LAST_STARTED_PID=""
    # The failure details of an earlier launch are not this launch's (even when this call
    # returns before it launches anything).
    HALOW_HOSTAPD_EXIT_STATUS=""
    HALOW_HOSTAPD_FAIL_MS=""
    HALOW_HOSTAPD_LAST_PID=""

    if ! { : > "$log"; }; then
        halow_log_error "hostapd-lifecycle: could not create the hostapd_s1g log file at $log"
        return 1
    fi

    # hostapd_s1g talks to the driver over nl80211 vendor commands and runs no helper
    # program, so it is launched with the environment it inherited; nothing is added to its
    # PATH. (The hostapd release line this add-on shipped earlier ran a bare helper
    # executable and needed the artifacts directory on PATH; the release that matches the
    # shipped driver does not.)
    HALOW_HOSTAPD_LAUNCH_US="${EPOCHREALTIME:-}"
    "$bin" -f "$log" "$conf" &
    local pid=$!
    HALOW_HOSTAPD_LAST_PID="$pid"
    HALOW_HOSTAPD_EXIT_STATUS=""
    HALOW_HOSTAPD_FAIL_MS=""

    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        # Collect the exit status for the failure record (the process has already ended,
        # so this never blocks; bash keeps the status of the last background job).
        local _st
        if wait "$pid" 2>/dev/null; then _st=0; else _st=$?; fi
        HALOW_HOSTAPD_EXIT_STATUS="$_st"
        HALOW_HOSTAPD_FAIL_MS="$(halow_hostapd_ms_since_launch)"
        # 127 is also what wait reports when the status cannot be collected.
        [ "$_st" != "127" ] || _st="127 (exec failed or not collectable)"
        halow_log_error "hostapd-lifecycle: hostapd_s1g did not start successfully (exec likely failed; exit status $_st); the caller's own rollback will clean up via the identity-scan fallback, since no pid file was ever written"
        return 1
    fi

    if ! echo "$pid" > "$pidfile"; then
        halow_log_error "hostapd-lifecycle: hostapd_s1g started (pid $pid) but its own pid file could not be written — the caller's own rollback will find and stop it via the identity-scan fallback"
        return 1
    fi

    HALOW_LAST_STARTED_PID="$pid"
}

# halow_hostapd_pre_start_check <conf_path>
# Called BEFORE this package creates ANY hostapd_s1g file (config, log, pid) or process.
# Two things happen here, in order: (1) a safety check that refuses to start a new
# instance unless the prior state is POSITIVELY confirmed absent — an UNKNOWN or
# AMBIGUOUS prior state blocks starting, exactly like an already-running positive match
# does; "not positively confirmed running" is never itself treated as permission to start
# another instance; (2) establishing lifecycle ownership ("hostapd_process") — fixed in
# this change so that a failure recording ownership means NOTHING is created at all, not
# even the password-bearing rendered config, rather than ownership being recorded only
# after the config/process already exist.
halow_hostapd_pre_start_check() {
    local conf="$1"
    halow_hostapd_determine_outcome "$conf"
    case "$HALOW_HOSTAPD_OUTCOME" in
        confirmed_absent) : ;;
        owned)
            halow_log_error "hostapd-lifecycle: refusing to start — an existing instance (pid $HALOW_HOSTAPD_TARGET_PID) already positively matches this package's own identity"
            return 1
            ;;
        *)
            halow_log_error "hostapd-lifecycle: refusing to start — the prior state could not be positively confirmed absent (outcome: $HALOW_HOSTAPD_OUTCOME); 'not confirmed running' is never treated as permission to start another instance"
            return 1
            ;;
    esac
    if ! halow_own_mark "hostapd_process"; then
        halow_log_error "hostapd-lifecycle: could not record lifecycle ownership — refusing to create any hostapd_s1g file or process"
        return 1
    fi
}

# halow_cleanup_hostapd_files <pidfile> <conf> <log>
# Called only once hostapd_s1g itself is positively confirmed stopped or absent — never
# while it may still be running, and never merely because a marker exists. Removes the
# password-bearing rendered config, its pid file, and its log. Fixed during development:
# removal is verified with halow_path_still_present, not plain `[ -e ]`, which would
# wrongly report a dangling symlink as "already absent." Clears the "hostapd_process"
# ownership marker only once every removal is confirmed — a file that cannot be removed
# keeps ownership so a repeated cleanup attempt (the next rollback call) keeps trying.
# Never prints or logs the config file's own contents. Safe to call even when the
# process never actually started (e.g. a config-render failure before any process
# existed) — in that case, the files this function checks for are simply already absent,
# and it succeeds trivially.
halow_cleanup_hostapd_files() {
    local pidfile="$1" conf="$2" log="$3" failed=0
    rm -f -- "$pidfile"
    halow_path_still_present "$pidfile" && failed=1
    rm -f -- "$conf"
    if halow_path_still_present "$conf"; then
        halow_log_error "hostapd-lifecycle: CRITICAL — the password-bearing rendered config at $conf could not be removed"
        failed=1
    fi
    rm -f -- "$log"
    halow_path_still_present "$log" && failed=1
    if [ "$failed" -eq 1 ]; then
        halow_log_error "hostapd-lifecycle: one or more hostapd_s1g files could not be removed — ownership kept"
        return 1
    fi
    halow_own_clear "hostapd_process"
    halow_log_info "hostapd-lifecycle: hostapd_s1g confirmed stopped/absent; config/log/pid files removed and verified absent"
}

# halow_stop_hostapd
# The single, shared stop-and-cleanup entry point — called identically by `run`'s own
# stop-signal trap, by `finish`'s own independent call, and by any repeated rollback
# attempt. Operates ENTIRELY from durable, on-disk state (the "hostapd_process"
# ownership marker and the persisted pid file) — never from an in-memory PID passed by a
# caller. Idempotent: a second call after a successful first call is a safe no-op.
# Fixed during development: after stopping an identified process, a FRESH, COMPLETE identity
# scan is now required before removing any file or clearing ownership — never merely a
# re-check of the one pid just signalled, which could miss a second, as-yet-unseen
# instance of this package's own process.
halow_stop_hostapd() {
    local conf="${HALOW_STATE_DIR:?}/hostapd_s1g.conf"
    local log="${HALOW_STATE_DIR:?}/hostapd_s1g.log"
    local pidfile="${HALOW_STATE_DIR:?}/hostapd_s1g.pid"
    local was_owned=1
    halow_own_check "hostapd_process" || was_owned=0

    # Fixed during development (review found this, distinct from
    # the dnsmasq ownership defect this same round also fixes): this function used to
    # return success immediately whenever `hostapd_process` was not owned, WITHOUT EVER
    # running the identity scan below -- meaning a real, live, identity-matching
    # hostapd_s1g process (with its own password-bearing rendered config) that somehow
    # existed without this package's own ownership marker (e.g. as a direct consequence
    # of the dnsmasq-class defect, had it existed here too; marker loss; a bug elsewhere)
    # could never be discovered, and halow_rollback's own aggregate ownership-key check
    # has no key to notice either, since nothing was ever marked owned -- rollback would
    # report "complete" while that process and its password-bearing config remained. The
    # scan now ALWAYS runs regardless of ownership-marker state, so this condition can be
    # detected; a positively-identified-but-unowned process is still never signalled,
    # adopted, or have its files touched (this function has no established responsibility
    # for it), but it is no longer silently invisible either -- the overwhelmingly common
    # case (ownership never marked because hostapd_s1g was simply never started this run)
    # still resolves via the scan to CONFIRMED ABSENT and returns cleanly, with no change
    # in behaviour or noise.
    halow_hostapd_determine_outcome "$conf"

    if [ "$was_owned" -eq 0 ]; then
        case "$HALOW_HOSTAPD_OUTCOME" in
            confirmed_absent) return 0 ;;
            owned)
                halow_log_error "hostapd-lifecycle: a live process (pid $HALOW_HOSTAPD_TARGET_PID) exactly matches this package's own hostapd_s1g identity, but no hostapd_process lifecycle ownership marker is held for it -- refusing to signal it or touch its files; this requires manual investigation"
                return 1
                ;;
            *)
                halow_log_error "hostapd-lifecycle: hostapd_s1g's own identity could not be positively confirmed absent (outcome: $HALOW_HOSTAPD_OUTCOME), and no hostapd_process lifecycle ownership marker is held either -- this requires manual investigation"
                return 1
                ;;
        esac
    fi

    case "$HALOW_HOSTAPD_OUTCOME" in
        confirmed_absent)
            halow_cleanup_hostapd_files "$pidfile" "$conf" "$log"
            ;;
        owned)
            local target_pid="$HALOW_HOSTAPD_TARGET_PID" scan_status attempt
            kill "$target_pid" 2>/dev/null || true
            # Mandatory fresh, COMPLETE scan -- not a re-check of $target_pid alone. A
            # process that is genuinely exiting (e.g. hostapd_s1g tearing down its own
            # dynamic WDS/AP_VLAN interface) can legitimately take more than one second to
            # actually leave the process table after SIGTERM; a single fixed-delay scan
            # would misreport that normal, if slightly slow, exit as "a second live
            # instance found" (ownership incorrectly kept, and if this happens to be the
            # separate `finish` process's own single rollback attempt, a benign shutdown
            # would be reported as a halt-worthy failure). Retried here, briefly and
            # boundedly, re-running the SAME full scan each time, exiting the loop the
            # moment it reports CONFIRMED ABSENT -- never treated as "stuck" after only one
            # second when it may simply still be exiting.
            for attempt in 1 2 3 4 5; do
                sleep 1
                # A bare call here would abort under bashio's inherited errexit the
                # instant it returns 1 -- the EXPECTED, hoped-for outcome of this retry
                # loop (confirmed-absent), not an error. See module_load.sh's own
                # module-level comment for the real incident this class of pattern
                # caused elsewhere in this codebase.
                if halow_find_hostapd_by_identity "$conf" >/dev/null 2>&1; then
                    scan_status=0
                else
                    scan_status=$?
                fi
                [ "$scan_status" -eq 1 ] && break
            done
            case "$scan_status" in
                1) halow_cleanup_hostapd_files "$pidfile" "$conf" "$log" ;;
                0) halow_log_error "hostapd-lifecycle: hostapd_s1g (pid $target_pid) was signalled, but after retrying for up to ${attempt}s a fresh, complete scan still finds a live process matching this package's own identity (it may simply still be exiting, or it may be a genuinely second instance -- this scan cannot distinguish the two) — this is not yet resolved; ownership kept" ;;
                2) halow_log_error "hostapd-lifecycle: hostapd_s1g (pid $target_pid) was signalled, but after retrying for up to ${attempt}s the follow-up scan is ambiguous (more than one live candidate) — ownership kept" ;;
                *) halow_log_error "hostapd-lifecycle: hostapd_s1g (pid $target_pid) was signalled, but after retrying for up to ${attempt}s its own identity could still not be positively confirmed absent (an unreadable candidate was found) — this is NOT treated as confirmation it is gone — ownership kept" ;;
            esac
            ;;
        unknown)
            halow_log_error "hostapd-lifecycle: hostapd_s1g's own identity could not be positively confirmed (its cmdline could not be read) — refusing to treat this as either owned or absent; ownership kept for manual review"
            ;;
        ambiguous)
            halow_log_error "hostapd-lifecycle: pid file missing/malformed and more than one live process matches this package's own hostapd_s1g identity — refusing to guess; ownership kept"
            ;;
    esac
}
