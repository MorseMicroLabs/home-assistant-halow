#!/usr/bin/env bash
# halow: automatic kernel-module loading.
#
# ERREXIT INCIDENT (2026-10-20, live test): `/usr/bin/bashio` -- the
# interpreter `run`'s own `#!/usr/bin/with-contenv bashio` shebang invokes, which
# sources `run` into its OWN shell rather than exec'ing it as a fresh process --
# unconditionally sets `set -o errexit` (+ `errtrace` + `nounset` + `pipefail` +
# `shopt -s inherit_errexit`), confirmed by reading `/usr/bin/bashio` directly inside
# the real built image. `run`'s own `set -uo pipefail` line only ADDS those two options
# on top of whatever bashio already set -- it does NOT, and cannot, disable `errexit`.
# This means every library function this add-on sources (this file included) actually
# executes with `errexit` active in production, even though none of this codebase's own
# off-device tests exercise that (the test harness sources these same files directly,
# with no `set -e` of its own), and even though reading `run`'s own `set -uo pipefail`
# line in isolation gives no hint of it.
#
# Under `errexit` (+ `errtrace` + `inherit_errexit`), a BARE command or function call —
# one that is not the condition of `if`/`while`/`until`, not part of `&&`/`||` (except
# the final element), not negated with `!`, and not the non-final stage of a pipeline —
# aborts the ENTIRE script the instant it returns non-zero, before the very next
# statement ever runs, even if that next statement is only `case $?` or `rc=$?` reading
# the result. A live-device test attempt hit exactly this: a bare
# `halow_sysfs_write_with_remount ...` call returning 1, immediately followed by
# `case $? in`, aborted `run` right there -- skipping the case statement's own cleanup
# logic entirely, never reaching `fail()`, and leaving a stale ownership marker behind
# that an otherwise-identical isolated reproduction (same code, same real AppArmor
# environment, but invoked directly rather than through bashio) did not exhibit, since
# that reproduction had no `errexit` active. Confirmed empirically, not inferred: a
# minimal reproduction with bashio's own exact `set -o` lines plus an `ERR` trap showed
# the trap firing, and execution halting, at the bare call -- before the very next line.
#
# Every capture of a 2-or-more-way return code throughout this file (and `run`,
# `rollback.sh`) therefore uses the explicit `if cmd; then rc=0; else rc=$?; fi` form —
# the command sits in `if`'s own test position, which `errexit` never reacts to,
# regardless of what the command returns. A bare `cmd; rc=$?` or `cmd; case $? in` is
# never safe in this codebase, no matter how harmless it looks in isolation off-device.
#
# Ownership discipline (fixed during development): ownership is marked immediately after
# `insmod` itself succeeds — not after the later `lsmod`/sysfs verification step — so
# that if verification then fails, the explicit unload path below (which is
# ownership-gated) can actually find and unload the module. Marking ownership only
# after verification would leave a module that failed verification untracked: nothing
# would know to unload it, and a later, unrelated failure elsewhere could leave it
# loaded indefinitely. Ownership is only ever cleared once `rmmod` has been confirmed to
# actually remove the module (checked via `lsmod`, not assumed from `rmmod`'s own exit
# status alone) — if `rmmod` fails or the module is still present afterwards, ownership
# is deliberately left in place so a repeated cleanup attempt keeps trying rather than
# silently forgetting about a module that is, in fact, still loaded.

# halow_set_firmware_search_path <host_dir>
# Points the host kernel's firmware-loader search path at <host_dir> — must be the
# HOST-ABSOLUTE path that this container's own firmware staging directory resolves to.
# Firmware filesystem-fallback loading always resolves this value against the host's own
# init mount namespace (confirmed from kernel source), never the calling container's own
# filesystem view, and the search is additive: the kernel's own compiled-in default
# paths are still tried afterward if nothing is found here, so this never blocks any
# other driver's or add-on's own firmware request on the shared host. Call this AFTER
# firmware files are staged and BEFORE loading the module that requests them.
#
# Ownership records BOTH the true prior value AND the value this package itself wrote
# ("our_value"), as THREE lines in one marker (state, prior, our_value; "state" is "prepared" or "applied", see below) (ownership.sh's own content-storage
# capability) — halow_restore_firmware_search_path needs both: "our_value" to detect a
# foreign actor changing the node after this package set it (never overwrite that), and
# the true prior value to actually restore. The prior value is stored FIRST and
# our_value LAST deliberately: ownership.sh's halow_own_get reads the marker back via
# command substitution, which strips ALL trailing newlines — if our_value (never empty)
# came first and an empty prior came last, "dir\n" and "dir" would become
# indistinguishable once read back, silently losing an empty prior. Putting prior first
# means a leading empty line (prior="") is preserved exactly, since only TRAILING
# newlines are stripped — found as a real defect while testing this exact scenario, not
# assumed correct from reading the code. Fail-closed throughout: ownership is cleared
# only when there is nothing left to restore (nothing was actually changed) or a restore
# has been positively confirmed by read-back — never merely attempted.
halow_set_firmware_search_path() {
    local dir="$1" sysfs="${HALOW_FW_SYSFS_PATH}" prior readback current write_rc fallback_rc
    local _m _m_state _m_rest _m_our restore_first_rc
    if halow_own_check "fw_search_path"; then
        if ! current="$(cat "$sysfs" 2>/dev/null)"; then
            halow_log_error "firmware-search-path: could not read $sysfs — refusing to proceed (fail closed)"
            return 1
        fi
        _m="$(halow_own_get "fw_search_path")"
        _m_state="${_m%%$'\n'*}"
        _m_rest="${_m#*$'\n'}"
        _m_our="${_m_rest#*$'\n'}"
        if [ "$_m_state" = "applied" ] && [ "$_m_our" = "$dir" ] && [ "$current" = "$dir" ]; then
            halow_log_info "firmware-search-path: $sysfs already set to $dir by this package, unchanged"
            return 0
        fi
        # A STRANDED marker from an earlier run (killed before its own restore finished)
        # must be reconciled by the restore state machine FIRST. Re-recording "prior" from
        # the node's current value here would overwrite the marker and lose the TRUE prior
        # value (and, for an interrupted sentinel install, the pending-reboot state).
        if halow_restore_firmware_search_path; then
            restore_first_rc=0
        else
            restore_first_rc=$?
        fi
        if [ "$restore_first_rc" -ne 0 ]; then
            halow_log_error "firmware-search-path: a stranded fw_search_path marker from an earlier run could not be reconciled (restore returned $restore_first_rc) — refusing to start a new set over it; ownership KEPT for manual review"
            return "$restore_first_rc"
        fi
    fi
    if ! prior="$(cat "$sysfs" 2>/dev/null)"; then
        halow_log_error "firmware-search-path: could not read $sysfs — refusing to proceed (fail closed)"
        return 1
    fi
    # Two-phase crash-safe state model (added 2026-10-20, following a real live
    # incident — see halow_restore_firmware_search_path's own header for the full
    # restore-side state machine this enables). The marker's own first field records
    # which phase this attempt has reached: "prepared" (ownership claimed, about to
    # attempt the write, NOT yet positively confirmed applied) or "applied" (the
    # post-write read-back below has positively confirmed it landed). An interruption
    # between these two points previously left a marker indistinguishable from a
    # genuine foreign modification.
    if ! halow_own_mark "fw_search_path" "$(printf 'prepared\n%s\n%s' "$prior" "$dir")"; then
        halow_log_error "firmware-search-path: could not record the prior value of $sysfs before changing it — refusing to proceed"
        return 1
    fi
    if halow_sysfs_write_with_remount "$sysfs" "$dir"; then
        write_rc=0
    else
        write_rc=$?
    fi
    case "$write_rc" in
        0) : ;;
        3)
            halow_log_error "firmware-search-path: CRITICAL — /sys could not be confirmed restored to its own prior mount mode after this write attempt; ownership KEPT (state: prepared) for manual review"
            return 3
            ;;
        *)
            halow_log_error "firmware-search-path: could not write $sysfs"
            readback="$(cat "$sysfs" 2>/dev/null || true)"
            if [ "$readback" = "$prior" ]; then
                # The failed write changed nothing — safe to drop the marker just
                # recorded for a change that never actually happened.
                halow_own_clear "fw_search_path"
            else
                halow_log_error "firmware-search-path: $sysfs no longer matches its own recorded prior value after a failed write (found '$readback', expected '$prior') — ownership KEPT (state: prepared) for manual review"
            fi
            return 1
            ;;
    esac
    readback="$(cat "$sysfs" 2>/dev/null || true)"
    if [ "$readback" != "$dir" ]; then
        halow_log_error "firmware-search-path: wrote '$dir' to $sysfs but read back '$readback'"
        if [ -z "$prior" ]; then
            # An exact write of the EMPTY prior value is not available on this device (see
            # halow_sysfs_write_with_remount's header), and halow_sysfs_write_with_remount
            # refuses an empty value outright. Fail closed instead of guessing: ownership
            # stays at "prepared" so rollback's restore pass (which handles the empty-prior
            # case via the sentinel, or refuses an unexplained value) decides, and a human
            # sees why.
            halow_log_error "firmware-search-path: the recorded prior value is empty, which cannot be written back exactly on this device — ownership KEPT (state: prepared) for rollback's own restore pass / manual review"
            return 1
        fi
        halow_log_error "firmware-search-path: attempting to restore the prior value"
        if halow_sysfs_write_with_remount "$sysfs" "$prior"; then
            fallback_rc=0
        else
            fallback_rc=$?
        fi
        if [ "$fallback_rc" -eq 3 ]; then
            # Distinct from an ordinary fallback-restore failure below: /sys's own mount
            # mode itself could not be confirmed restored, not merely the value. Must
            # propagate as 3, never collapse into the generic "ownership KEPT" return 1
            # below, exactly as halow_restore_firmware_search_path already does for the
            # equivalent case — found missing here by a code review, not
            # self-identified.
            halow_log_error "firmware-search-path: CRITICAL — /sys could not be confirmed restored to its own prior mount mode during this fallback restore attempt; ownership KEPT (state: prepared) for manual review"
            return 3
        fi
        if [ "$fallback_rc" -eq 0 ] && [ "$(cat "$sysfs" 2>/dev/null || true)" = "$prior" ]; then
            halow_own_clear "fw_search_path"
            halow_log_error "firmware-search-path: prior value restored after the failed set"
        else
            halow_log_error "firmware-search-path: could NOT confirm the prior value was restored after the failed set — ownership KEPT (state: prepared) for manual review"
        fi
        return 1
    fi
    # The write is now positively confirmed applied -- transition the marker from
    # "prepared" to "applied" BEFORE returning, so an interruption from this point
    # onward is handled by the restore function's own "applied, needs restoring"
    # branch, never mistaken for "nothing happened yet."
    if ! halow_own_mark "fw_search_path" "$(printf 'applied\n%s\n%s' "$prior" "$dir")"; then
        halow_log_error "firmware-search-path: wrote and verified $sysfs but could not record the 'applied' state — treating as CRITICAL (the write DID take effect; losing this record would misclassify it as never-applied on a future restore attempt)"
        return 4
    fi
    halow_log_info "firmware-search-path: $sysfs set to $dir"
}

# halow_restore_firmware_search_path
# Restores the sysfs node to whatever it held before this package changed it. Safe to
# call repeatedly, and a safe no-op if halow_set_firmware_search_path was never called
# (or already restored). Call this as soon as the BCF match is confirmed — do not hold
# this global, host-wide setting for the add-on's whole runtime, only for the brief
# window its own module load actually needs it.
#
# Hardened (this change): before writing anything, re-reads the node and compares it
# against the value THIS package itself last wrote (recorded alongside the true prior
# value by halow_set_firmware_search_path, above). If some other actor changed it since
# — a real possibility for genuinely global, un-namespaced kernel state — that foreign,
# newer value is never overwritten: this function fails visibly instead, keeps ownership,
# and logs both the unexpected current value and this package's own recorded prior value
# so a human can reconcile the two safely. Ownership is cleared only once the restore
# write has been positively confirmed by read-back, in every branch, never merely
# attempted.
#
# Crash-safe two-phase state machine (added 2026-10-20, following a real live
# incident: an interruption between "ownership claimed" and "write confirmed applied"
# left a marker this function could then only interpret as a foreign modification — see
# halow_set_firmware_search_path's own header). The marker's own first field is
# "prepared" or "applied":
#   - "prepared": the write was never positively confirmed to land. If the real current
#     value still equals the recorded TRUE PRIOR value, nothing ever actually changed —
#     safe to clear ownership directly, no write needed (the "interrupted before/during
#     the write attempt" case). If it instead equals the value this attempt was
#     PREPARING to write, the write actually succeeded despite the interruption
#     happening before the marker could be updated to "applied" — treated identically
#     to the "applied" case below. Any other value is genuinely unexplained and never
#     assumed safe.
#   - "applied": the write was positively confirmed at the time it was made. If the
#     current value already equals the recorded prior value, a PREVIOUS restore attempt
#     already completed the write but was itself interrupted before clearing the marker
#     — safe to just clear, no write needed (the "interrupted after restoring, before
#     clearing the marker" case). Otherwise, the existing foreign-change protection
#     applies unchanged: the current value must still equal what this package itself
#     wrote, or this refuses to overwrite a value some other actor may have since set.
#
# INERT SENTINEL (development-build-only accommodation, added 2026-10-20 — see
# HALOW_FW_SEARCH_SENTINEL's own header in common.sh for the full record and its
# kernel-source citation; NOT a production/customer mechanism). When the TRUE recorded
# prior value is empty, this function can no longer promise an exact ("") restoration —
# a live Green demonstrated neither a zero-byte nor a single-NUL-byte write actually
# clears this parameter on that device, for reasons that remain unexplained. Instead, it
# installs the safe, inert HALOW_FW_SEARCH_SENTINEL value (using the SAME, already
# proven-reliable non-empty write path — no new, unproven write technique is used),
# clears "fw_search_path" (this add-on's own active-use marker) only once that sentinel
# write is positively confirmed, and separately marks "firmware_path_reboot_required" —
# a DISTINCT, deliberately longer-lived marker — so this honestly-partial state is never
# mistaken for an exact restoration anywhere it is reported (see rollback.sh's own
# aggregate reporting) until a controlled host reboot and halow_verify_fw_search_path_rebooted_clean,
# below, positively confirm the true empty baseline. This add-on never creates or deletes
# the sentinel PATH itself; it is only ever an inert string value in the sysfs parameter.
# Three distinct states are therefore tracked, never conflated: (1) "fw_search_path" held
# = this add-on's own firmware path is active and owned; (2) "fw_search_path" cleared +
# "firmware_path_reboot_required" held = the sentinel is installed and exact restoration
# is pending a reboot; (3) both cleared = the exact baseline was restored and verified
# after a reboot. A later start while state (2) holds records the sentinel itself as its
# "prior" value (non-empty) and restores that exactly, leaving "firmware_path_reboot_required"
# untouched, so state (2) is never silently promoted to state (3).
# When the true recorded prior value is NOT empty, this function's behaviour is
# completely unchanged from before: an exact restore, no sentinel involved.
halow_restore_firmware_search_path() {
    local sysfs="${HALOW_FW_SYSFS_PATH}" sentinel="${HALOW_FW_SEARCH_SENTINEL}"
    local marker state rest prior our_value current readback restore_rc
    if ! halow_own_check "fw_search_path"; then
        return 0
    fi

    # SCOPE (corrected 2026-10-20): the mode checked here is THIS CONTAINER'S OWN /sys mount,
    # which Docker flags `ro` at the mount level (the host's superblock underneath is `rw`
    # and, with host_network, shared with the host). The remounts below are BIND remounts,
    # so they change only this container's mount flag and can never alter the host's /sys.
    # An unexpected `rw` therefore means an interrupted bracket inside this container, and
    # putting the container's own mount back to `ro` is always correct and host-neutral.
    #
    # Defensive, orthogonal to the ownership state-machine below: if this package was
    # interrupted (killed, crashed) between a remount-to-rw succeeding and the matching
    # remount-to-ro inside halow_sysfs_write_with_remount, /sys's own mount MODE itself
    # -- not just the sysfs value -- could be left writable, with no marker able to
    # record that (the marker only ever describes the VALUE, never the mount mode). No
    # userspace code can fully prevent an abrupt SIGKILL mid-syscall, but every ordinary
    # rollback/restore pass checks the real, live mode here and defensively restores it,
    # since this package is the only known actor in this add-on's own design that
    # legitimately touches it.
    if [ "$(halow_sys_mount_mode)" = "rw" ]; then
        if halow_sys_remount ro; then
            halow_log_info "firmware-search-path: /sys was unexpectedly mounted read-write (likely a prior interrupted remount) — defensively remounted back to read-only"
        else
            # FAIL CLOSED: /sys may remain writable. Return the distinct critical mount-state
            # code immediately -- no value restoration, no marker is read, cleared or
            # reclassified, so the evidence of the interrupted state is preserved exactly.
            halow_log_error "firmware-search-path: CRITICAL — /sys is unexpectedly mounted read-write (likely a prior interrupted remount) and could not be defensively remounted back to read-only; /sys may remain writable on this host; ownership and the sysfs value left untouched — manual intervention required"
            return 3
        fi
    fi

    marker="$(halow_own_get "fw_search_path")"
    state="${marker%%$'\n'*}"
    rest="${marker#*$'\n'}"
    prior="${rest%%$'\n'*}"
    our_value="${rest#*$'\n'}"

    if ! current="$(cat "$sysfs" 2>/dev/null)"; then
        halow_log_error "firmware-search-path: could not read $sysfs — refusing to guess; ownership KEPT"
        return 1
    fi

    # An unrecognised state field (e.g. a marker written by an older build that
    # persisted in /data across an add-on update) is never interpreted: refuse.
    case "$state" in
        prepared|applied) : ;;
        *)
            halow_log_error "firmware-search-path: fw_search_path marker has an unrecognised state '$state' — refusing to interpret it; ownership KEPT for manual review"
            return 1
            ;;
    esac

    # Sentinel-recovery case (checked BEFORE the state-machine below, for BOTH marker
    # states): the true prior value is empty and the node already holds the sentinel, yet
    # "fw_search_path" is still owned. Only this function ever writes the sentinel, and
    # only after its own readback-confirmed write, so a PREVIOUS sentinel install already
    # succeeded and was interrupted before its bookkeeping (marking
    # "firmware_path_reboot_required", clearing "fw_search_path") finished. The marker may
    # still say "prepared" here (a restore that began from a 'prepared + write-landed'
    # marker never rewrites it to "applied"), so this must not sit behind the
    # state-specific branches, which would otherwise refuse it as an unexplained value.
    # Finishing the bookkeeping is safe because the sentinel write is idempotent and was
    # already confirmed; never reached for a non-empty true prior value.
    if [ -z "$prior" ] && [ "$current" = "$sentinel" ]; then
        if ! halow_own_mark "firmware_path_reboot_required"; then
            halow_log_error "firmware-search-path: CRITICAL — the sentinel is confirmed installed but 'firmware_path_reboot_required' could not be (re-)recorded — ownership of fw_search_path KEPT for manual review"
            return 4
        fi
        halow_own_clear "fw_search_path"
        halow_log_warning "firmware-search-path: sentinel-install bookkeeping completed after an interruption (the sentinel write itself had already succeeded) — POC-only, reboot still required for exact restoration"
        return 0
    fi

    if [ "$state" = "prepared" ]; then
        if [ "$current" = "$prior" ]; then
            halow_own_clear "fw_search_path"
            halow_log_info "firmware-search-path: prepared-but-never-applied state confirmed ($sysfs already holds its own recorded prior value) — ownership cleared, no write needed"
            return 0
        fi
        if [ "$current" != "$our_value" ]; then
            halow_log_error "firmware-search-path: $sysfs holds neither its own recorded prior value ('$prior') nor the value this package was preparing to write ('$our_value') — found '$current' — refusing to guess; ownership KEPT for manual review"
            return 1
        fi
        halow_log_info "firmware-search-path: a 'prepared' marker was found, but $sysfs already holds the intended new value — the write had actually taken effect before being interrupted; proceeding to restore it"
        # Fall through to the same restore-to-prior logic "applied" uses below.
    elif [ "$current" = "$prior" ]; then
        # "applied" state, but the restore has already happened (e.g. a previous
        # restore attempt wrote the value back but was itself interrupted before
        # clearing the marker) — safe to just clear, no write needed.
        halow_own_clear "fw_search_path"
        halow_log_info "firmware-search-path: $sysfs already holds its own recorded prior value — ownership cleared, no write needed"
        return 0
    fi

    if [ "$current" != "$our_value" ]; then
        halow_log_error "firmware-search-path: $sysfs no longer holds the value this package set (expected '$our_value', found '$current') — some other actor changed it since; refusing to overwrite that foreign value. Ownership KEPT; this package's own recorded prior value (from before it ever touched this node) is '$prior', for manual reconciliation."
        return 1
    fi

    if [ -z "$prior" ]; then
        # development-build-only inert-sentinel path -- see this function's own header. The user-facing
        # requirement that the sentinel PATH itself must not already exist on the real
        # host filesystem cannot be checked HERE: firmware-loader resolution (like this
        # whole mechanism) always uses the host's own init mount namespace, never this
        # container's own filesystem view (see halow_set_firmware_search_path's own
        # header, above) -- this container has no visibility into the host's own /run to
        # check at all. That check is therefore a HOST-LEVEL precondition of the live
        # reconciliation procedure itself (see halow_sentinel_path_is_absent, below,
        # which the add-on's own normal run/rollback lifecycle never calls), performed
        # BEFORE this function is ever invoked for that purpose -- never inside it.
        if halow_sysfs_write_with_remount "$sysfs" "$sentinel"; then
            restore_rc=0
        else
            restore_rc=$?
        fi
        case "$restore_rc" in
            0) : ;;
            3)
                halow_log_error "firmware-search-path: CRITICAL — /sys could not be confirmed restored to its own prior mount mode after this sentinel-install attempt; ownership kept"
                return 3
                ;;
            *)
                halow_log_error "firmware-search-path: could not install the POC sentinel at $sysfs — ownership kept"
                return 1
                ;;
        esac
        readback="$(cat "$sysfs" 2>/dev/null || true)"
        if [ "$readback" != "$sentinel" ]; then
            halow_log_error "firmware-search-path: sentinel install at $sysfs did not take effect (read back '$readback', expected '$sentinel') — ownership kept"
            return 1
        fi
        if ! halow_own_mark "firmware_path_reboot_required"; then
            halow_log_error "firmware-search-path: CRITICAL — sentinel installed and verified but 'firmware_path_reboot_required' could not be recorded — ownership of fw_search_path KEPT for manual review (losing this record would misclassify the true baseline as already reached)"
            return 4
        fi
        halow_own_clear "fw_search_path"
        halow_log_warning "firmware-search-path: exact empty restoration of $sysfs is not reliably achievable live on this device (see this function's own header); installed the safe, inert development-build-only sentinel '$sentinel' instead — functionally equivalent for firmware loading (a nonexistent custom path falls through to the kernel's own default search paths, confirmed from source) but NOT an exact restoration. A controlled host reboot and its own post-reboot baseline verification are still required — see 'firmware_path_reboot_required'."
        return 0
    fi

    # Normal (non-empty true prior value) exact restore -- completely unchanged.
    if halow_sysfs_write_with_remount "$sysfs" "$prior"; then
        restore_rc=0
    else
        restore_rc=$?
    fi
    case "$restore_rc" in
        0) : ;;
        3)
            halow_log_error "firmware-search-path: CRITICAL — /sys could not be confirmed restored to its own prior mount mode after this restore attempt; ownership kept"
            return 3
            ;;
        *)
            halow_log_error "firmware-search-path: could not restore $sysfs to its prior value — ownership kept"
            return 1
            ;;
    esac
    readback="$(cat "$sysfs" 2>/dev/null || true)"
    if [ "$readback" != "$prior" ]; then
        halow_log_error "firmware-search-path: restore of $sysfs did not take effect (read back '$readback', expected '$prior') — ownership kept"
        return 1
    fi
    halow_own_clear "fw_search_path"
    halow_log_info "firmware-search-path: $sysfs restored to its prior value"
}

# halow_sentinel_path_is_absent
# HOST-LEVEL precondition check for the live reconciliation procedure ONLY — never called
# from the add-on's own normal run/rollback lifecycle, and meaningless if it were: this
# add-on's own container has no visibility into the host's own /run namespace (the same
# limitation documented in halow_set_firmware_search_path's own header — firmware-loader
# resolution always uses the host's own init mount namespace). Confirms the
# development-build sentinel PATH genuinely does not already exist, from WHATEVER
# filesystem view actually invokes this (the real host's own, when run as intended) —
# this add-on never creates, deletes, or modifies this path itself; it is used purely as
# an inert string VALUE in the sysfs parameter. Isolated into its own function
# specifically so the off-device test harness can point HALOW_FW_SEARCH_SENTINEL at a
# disposable test path and exercise both outcomes, matching this codebase's own
# established pattern (see halow_sys_mount_mode's own header).
halow_sentinel_path_is_absent() {
    [ ! -e "${HALOW_FW_SEARCH_SENTINEL}" ]
}

# halow_verify_fw_search_path_rebooted_clean
# Called ONLY as part of the development-build end-of-test-window controlled reboot
# procedure (never from run/rollback's own normal lifecycle) — positively confirms the
# real host has reached its true empty firmware-search-path baseline after a reboot, and
# clears "firmware_path_reboot_required" ONLY once that is confirmed. A safe no-op if
# that marker is not held (nothing pending). Never assumes a reboot alone is sufficient —
# the sysfs value itself is re-read and checked, not inferred from the reboot having
# happened. If the value is NOT genuinely empty, the marker is deliberately KEPT and this
# returns 1, so the overall procedure correctly treats this as a verification FAILURE,
# never a silent, unqualified "restored."
halow_verify_fw_search_path_rebooted_clean() {
    local sysfs="${HALOW_FW_SYSFS_PATH}" _hex
    if ! halow_own_check "firmware_path_reboot_required"; then
        return 0
    fi
    # BYTE-EXACT check. The bytes are never passed through a shell variable as data:
    # bash silently DROPS embedded NUL bytes in command substitution (a stored NUL would
    # otherwise look "empty"), and strips trailing newlines. `od` prints every byte as hex
    # on its own stdout, so a NUL (00), two newlines (0a0a), or any other byte is visible.
    # The only accepted representations of "empty" are: exactly one newline byte (0a) --
    # how a real kernel module-parameter node shows an empty value -- or, solely so the
    # off-device test harness can use a plain file, exactly zero bytes.
    #
    # READABILITY GATE (found during review running BusyBox in alpine:3.23):
    # BusyBox `od` exits 0 when it cannot open the file -- it only prints to stderr and
    # leaves stdout empty, which would look exactly like "zero bytes" (accepted). GNU od
    # exits non-zero, so the off-device harness cannot see this. Require that the node is a
    # readable regular file and that a plain read of it succeeds BEFORE trusting od's output.
    if [ ! -f "$sysfs" ] || [ ! -r "$sysfs" ] || ! cat "$sysfs" >/dev/null 2>&1; then
        halow_log_error "firmware-search-path: post-reboot baseline verification FAILED — $sysfs is not a readable regular file; 'firmware_path_reboot_required' KEPT"
        return 1
    fi
    if ! _hex="$(od -An -v -tx1 "$sysfs" 2>/dev/null)"; then
        halow_log_error "firmware-search-path: post-reboot baseline verification FAILED — could not read $sysfs; 'firmware_path_reboot_required' KEPT"
        return 1
    fi
    _hex="$(printf '%s' "$_hex" | tr -d ' \n')"
    case "$_hex" in
        ""|"0a") : ;;
        *)
            halow_log_error "firmware-search-path: post-reboot baseline verification FAILED — $sysfs is not exactly empty (bytes: ${_hex:0:64}); 'firmware_path_reboot_required' KEPT"
            return 1
            ;;
    esac
    halow_own_clear "firmware_path_reboot_required"
    halow_log_info "firmware-search-path: post-reboot baseline verified byte-exact empty; 'firmware_path_reboot_required' cleared"
    return 0
}

# halow_sys_mount_mode — prints "ro" or "rw" for the real /sys mount, read directly
# from /proc/mounts (never assumed, never parsed from `mount`'s own human-oriented
# output, which BusyBox's and util-linux's own `mount` format differently) — prints
# nothing if it cannot be determined, which every caller below treats as fail-closed,
# never as an implicit "rw". Isolated into its own function, matching this codebase's
# own established pattern (see common.sh's own halow_process_comm), specifically so
# the off-device test harness can stub it rather than ever touching the real test
# host's own /sys or /proc/mounts.
halow_sys_mount_mode() {
    awk '
        $2 == "/sys" {
            n = split($4, opts, ",")
            for (i = 1; i <= n; i++) {
                if (opts[i] == "ro") { print "ro"; exit }
                if (opts[i] == "rw") { print "rw"; exit }
            }
        }
    ' "${HALOW_PROC_MOUNTS:-/proc/mounts}" 2>/dev/null
}

# halow_sys_remount <ro|rw> — remounts /sys and POSITIVELY VERIFIES the change via
# halow_sys_mount_mode's own read-back before reporting success; never trusts a zero
# exit status from `mount` alone (consistent with this codebase's own established
# "verify by readback, not by exit status" discipline — see halow_set_firmware_search_path,
# above). Isolated for the same stubbing reason as halow_sys_mount_mode.
#
# BIND REMOUNT ONLY (found live 2026-10-20, a live-device test, by a reboot that revealed the true host
# baseline): with `host_network: true` this container shares the HOST's network namespace, and
# sysfs has one superblock per network namespace -- so the container's /sys and the host's /sys
# are the SAME superblock (same device number in /proc/self/mountinfo), with the container's
# mount merely flagged `ro` at the MOUNT level. A plain `mount -o remount,ro /sys` also changes
# the SUPERBLOCK flag, i.e. it made the HOST's /sys read-only (until the next reboot) after every
# run of this add-on's bracketed write. `mount -o remount,bind,<rw|ro> /sys` changes only this
# container's own mount flag and leaves the superblock -- the host -- untouched. Measured on the
# Green: bind,rw makes the firmware node openable for writing (EROFS before, success after,
# EROFS again after bind,ro) while the host's /sys stays `rw` throughout.
halow_sys_remount() {
    local want="$1"
    if ! mount -o "remount,bind,$want" /sys 2>/dev/null; then
        return 1
    fi
    if [ "$(halow_sys_mount_mode)" = "$want" ]; then
        return 0
    fi
    # The bind remount itself succeeded but the merged mode (mount flag AND superblock flag, as
    # /proc/mounts reports it) did not change: the SUPERBLOCK is read-only (e.g. a host left
    # read-only by an older build or by another actor), so this container cannot make /sys
    # writable. Put the container's own mount flag back to what it was rather than leaving a
    # `rw` flag behind that would silently become effective if the superblock later turned rw.
    if [ "$want" = "rw" ]; then
        halow_log_error "firmware-search-path: the bind remount to read-write succeeded but /sys still reads read-only — the host's sysfs superblock itself appears read-only, which this add-on never changes; reverting this container's own mount flag"
        mount -o "remount,bind,ro" /sys 2>/dev/null || true
    fi
    return 1
}

# halow_sysfs_write_with_remount <path> <value>
# Writes <value> to <path>, remounting /sys read-write around the write ONLY if /sys is
# not already writable, and UNCONDITIONALLY restoring /sys to the exact mount mode it
# had before this call — in every exit path, success or failure alike. Never leaves
# /sys writable as a side effect of calling this function. This is this codebase's own
# bounded, reversible answer to the live finding that a plain write to
# /sys/module/firmware_class/parameters/path can fail ("Read-only file system") under
# this add-on's privilege grant even with the needed capability held — rather than
# assuming any one privilege configuration (apparmor: false, full_access, or neither)
# makes /sys writable, this checks the REAL, live mount mode every time and reacts to
# what it actually finds.
#
# EMPTY VALUES ARE REFUSED (2026-10-20, live test; the record below is
# empirical, not a claim about kernel behaviour in general). Restoring this node to an
# EMPTY prior value was attempted live two ways on this Green (HAOS kernel 6.18.52-haos,
# aarch64), and BOTH failed to take effect: (1) a zero-byte write (`printf '%s' "" >
# path`), after which the host-global value still held this add-on's own path; and (2) a
# single literal NUL byte (`printf '\0' > path`), after which the node's mtime advanced
# (a real write(2) reached the kernel without any error and dmesg showed nothing) but the
# stored value was unchanged. Kernel-source review (mainline `param_set_copystring`,
# kernfs write path) gives no documented reason for either failure, and no HAOS-specific
# patch was found; the anomaly is UNEXPLAINED and neither technique is relied upon.
# Corrections on record: an earlier claim that the upstream kernel firmware-loader
# selftest corroborates the NUL-byte technique is WRONG and withdrawn -- that selftest's
# `printf '\000'` concerns an empty firmware REQUEST NAME, a different parameter, and its
# own handling of `firmware_class.path` uses an ordinary empty shell write. A newline is
# also not a substitute: `fw_get_filesystem_firmware` treats a stored "\n" as a
# zero-length custom-path PREFIX (a root-relative firmware lookup), not as "no custom
# path".
#
# Consequently this function REFUSES an empty <value> (return 1, nothing remounted,
# nothing written): no caller can silently depend on an empty write that has been shown
# not to work here. The only caller that used to need one -- restoring an empty prior
# value -- now installs an inert, nonexistent sentinel path instead and defers exact
# restoration to a controlled reboot (see halow_restore_firmware_search_path and
# HALOW_FW_SEARCH_SENTINEL in common.sh).
#
# Return codes: 0 = the write itself succeeded (the caller must still verify content by
# read-back, exactly as before — this function only reports whether the write syscall
# succeeded, never whether the value stuck); 1 = the write failed, OR /sys was read-only
# and could not be remounted read-write, OR the current mount mode could not be
# determined at all (fail closed — never attempts a write whose own remount bracket is
# not positively confirmed); 3 = CRITICAL — the write was attempted (and may have
# succeeded or failed) but /sys could NOT be confirmed restored to its own original
# mount mode afterward, meaning /sys may remain writable on this host. Callers must
# treat 3 as more severe than 1 — it is never safe to simply retry or ignore it, since
# the host's own /sys may now be in a materially different state than before this
# add-on ever ran.
halow_sysfs_write_with_remount() {
    local path="$1" value="$2" original_mode remounted_rw=0 write_rc

    if [ -z "$value" ]; then
        halow_log_error "firmware-search-path: refusing to write an EMPTY value to $path — an empty write was shown not to take effect on this device (see this function's header); no remount or write attempted"
        return 1
    fi

    original_mode="$(halow_sys_mount_mode)"
    case "$original_mode" in
        rw) : ;; # already writable — nothing to remount, nothing to restore afterward
        ro)
            if ! halow_sys_remount rw; then
                halow_log_error "firmware-search-path: /sys is read-only and could not be remounted read-write — refusing to write $path"
                return 1
            fi
            remounted_rw=1
            ;;
        *)
            halow_log_error "firmware-search-path: could not determine /sys's own current mount mode from /proc/mounts — refusing to write $path (fail closed)"
            return 1
            ;;
    esac

    # A bare `printf ... ; write_rc=$?` would abort THIS function right here, under
    # bashio's own inherited `errexit` (+ errtrace + inherit_errexit), the instant the
    # write fails -- skipping the unconditional remount-back-to-ro step immediately
    # below and directly violating this function's own safety contract ("never leaves
    # /sys writable as a side effect"). Confirmed live, 2026-10-20, as the root cause of
    # a real a live-device test incident (a DIFFERENT bare-call site in this same file, but the
    # identical class of bug) -- see this file's own module-level comment for the full
    # incident. The explicit `if cmd; then rc=0; else rc=$?; fi` form sits in `if`'s own
    # test position, which `errexit` never reacts to.
    #
    if printf '%s' "$value" > "$path" 2>/dev/null; then
        write_rc=0
    else
        write_rc=$?
    fi

    if [ "$remounted_rw" -eq 1 ]; then
        if ! halow_sys_remount ro; then
            halow_log_error "firmware-search-path: CRITICAL — could not remount /sys back to its own original read-only mode after writing $path; /sys may remain writable on this host"
            return 3
        fi
    fi

    return "$write_rc"
}

# halow_load_dot11ah <ko_path> [<scheme>]
# The channelization-scheme module parameter is read-only after load — it must be set
# at insmod time and is then confirmed by reading it straight back from sysfs, never
# merely assumed. The default of 1 for an omitted scheme is never used: the only caller
# (manager.sh) passes the scheme of the radio profile and refuses an empty one before this
# is called. The body is left unchanged because this privileged function is frozen by the
# privileged-equivalence test; a caller must always pass the scheme explicitly.
halow_load_dot11ah() {
    local ko_path="$1" scheme="${2:-1}" actual
    if [ ! -f "$ko_path" ]; then
        halow_log_error "module-load: dot11ah.ko not found at $ko_path"
        return 1
    fi
    if ! halow_run_logged insmod "$ko_path" channelization_scheme="$scheme"; then
        halow_log_error "module-load: insmod dot11ah.ko failed"
        return 1
    fi
    if ! halow_own_mark "module_dot11ah"; then
        halow_log_error "module-load: dot11ah.ko loaded but ownership could not be recorded — unloading (fail closed, never leave an untracked module loaded)"
        rmmod dot11ah 2>/dev/null || true
        if ! halow_module_confirmed_absent dot11ah; then
            halow_log_error "module-load: UNTRACKED RESIDUAL — dot11ah remains loaded after a failed ownership record and could not be confirmed unloaded (emergency: nothing can now find or clean up this module automatically)"
            return 3
        fi
        return 1
    fi

    actual="$(cat /sys/module/dot11ah/parameters/channelization_scheme 2>/dev/null || echo "")"
    if [ "$actual" != "$scheme" ]; then
        halow_log_error "module-load: dot11ah channelization_scheme read back as '$actual', expected '$scheme' — unloading"
        if halow_unload_one_module "dot11ah" "module_dot11ah"; then
            :
        else
            halow_log_error "module-load: dot11ah failed verification AND could not be confirmed unloaded — ownership kept so cleanup keeps retrying"
        fi
        return 1
    fi
    halow_log_info "module-load: dot11ah loaded, channelization_scheme=$scheme confirmed"
}

# halow_ensure_mac80211_loaded
# DEPENDENCY INCIDENT (2026-10-20, live test retry): a live `insmod
# morse.ko` failed with dozens of "Unknown symbol" errors (confirmed via dmesg: every
# one of them an `ieee80211_*`/`__ieee80211_*` export of the kernel's own `mac80211`
# module). Confirmed via `lsmod` that `cfg80211` was loaded but `mac80211` was not, and
# via the host filesystem that `mac80211.ko` exists at
# /lib/modules/<kernel>/kernel/net/mac80211/mac80211.ko (visible inside this container
# because `kernel_modules: true` already bind-mounts the host's own /lib/modules in,
# read-only — confirmed from Supervisor's own source, supervisor/docker/app.py). Unlike
# `insmod`, which loads exactly the one file handed to it and nothing else, `insmod`
# never resolves a module's own dependencies — `mac80211` must already be loaded before
# `morse.ko` is. `mac80211` is an ordinary in-tree module (unlike morse.ko, this add-on's
# own out-of-tree artifact, which is never assumed loadable via modprobe), so the
# dependency-aware `modprobe` is the correct mechanism for it specifically — confirmed
# via a disposable, non-destructive `modprobe -n -v mac80211` dry run inside this exact
# image with the same /lib/modules bind mount, which correctly resolved mac80211's own
# further dependency (`libarc4.ko`) and reported both `insmod` lines it would run,
# without actually loading anything.
#
# Ownership is claimed ONLY if this call actually loaded mac80211 itself. If some other
# driver or add-on already has it loaded, this package must never later unload a module
# it does not own — the same "never touch a foreign/pre-existing artefact" discipline
# this file's other load functions already follow. Mirrors
# halow_load_dot11ah/halow_load_morse's own "mark ownership right after the load
# succeeds, not after verification" discipline, for the same reason: a module that
# loaded but then failed verification must still be findable by the unload path.
#
# Known, accepted residual risk (flagged by a code review, documented rather
# than engineered around for this development build): there is a narrow check-then-act window between
# the `lsmod` check below and the `modprobe` call — if some other process loads mac80211
# in that exact window, `modprobe` is idempotent (a no-op success against an
# already-loaded module), so this call would still succeed and wrongly claim ownership
# of a module it did not actually load, meaning rollback would later unload a module
# some other consumer may still need. Unlike dot11ah/morse (this add-on's own exclusive,
# out-of-tree artifacts), mac80211 is common in-tree infrastructure another driver could
# plausibly load concurrently on a real multi-purpose Green. The window is sub-second
# and this is a desk-only development build with no locking mechanism; a production
# version would need one.
halow_ensure_mac80211_loaded() {
    local _pre_state
    if halow_module_state mac80211; then
        _pre_state=0
    else
        _pre_state=$?
    fi
    if [ "$_pre_state" -eq 0 ]; then
        halow_log_info "module-load: mac80211 already loaded (not add-on-owned); proceeding"
        return 0
    fi
    if [ "$_pre_state" -ne 1 ]; then
        # Cannot tell whether a foreign mac80211 is loaded; modprobe + an ownership claim
        # over a module this add-on did not load would later unload someone else's module.
        halow_log_error "module-load: cannot determine whether mac80211 is already loaded (lsmod failed) — refusing to proceed (fail closed)"
        return 1
    fi
    if ! halow_run_logged modprobe mac80211; then
        halow_log_error "module-load: modprobe mac80211 failed"
        return 1
    fi
    if ! halow_own_mark "module_mac80211"; then
        halow_log_error "module-load: mac80211 loaded but ownership could not be recorded — unloading (fail closed, never leave an untracked module loaded)"
        rmmod mac80211 2>/dev/null || true
        if ! halow_module_confirmed_absent mac80211; then
            halow_log_error "module-load: UNTRACKED RESIDUAL — mac80211 remains loaded after a failed ownership record and could not be confirmed unloaded (emergency: nothing can now find or clean up this module automatically)"
            return 3
        fi
        return 1
    fi
    if ! halow_module_loaded mac80211; then
        halow_log_error "module-load: mac80211 did not appear in lsmod after modprobe"
        if halow_unload_one_module "mac80211" "module_mac80211"; then
            :
        else
            halow_log_error "module-load: mac80211 failed verification AND could not be confirmed unloaded — ownership kept so cleanup keeps retrying"
        fi
        return 1
    fi
    halow_log_info "module-load: mac80211 loaded"
}

# halow_load_morse <ko_path>
halow_load_morse() {
    local ko_path="$1" mac80211_rc
    if [ ! -f "$ko_path" ]; then
        halow_log_error "module-load: morse.ko not found at $ko_path"
        return 1
    fi
    # morse.ko's own unresolved-symbol dependency on mac80211 -- see
    # halow_ensure_mac80211_loaded's own header for the full incident this fixes.
    if halow_ensure_mac80211_loaded; then
        mac80211_rc=0
    else
        mac80211_rc=$?
    fi
    if [ "$mac80211_rc" -ne 0 ]; then
        return "$mac80211_rc"
    fi
    if ! halow_run_logged insmod "$ko_path"; then
        halow_log_error "module-load: insmod morse.ko failed"
        return 1
    fi
    if ! halow_own_mark "module_morse"; then
        halow_log_error "module-load: morse.ko loaded but ownership could not be recorded — unloading (fail closed)"
        rmmod morse 2>/dev/null || true
        if ! halow_module_confirmed_absent morse; then
            halow_log_error "module-load: UNTRACKED RESIDUAL — morse remains loaded after a failed ownership record and could not be confirmed unloaded (emergency: nothing can now find or clean up this module automatically)"
            return 3
        fi
        return 1
    fi

    if ! halow_module_loaded morse; then
        halow_log_error "module-load: morse.ko did not appear in lsmod after insmod"
        if halow_unload_one_module "morse" "module_morse"; then
            :
        else
            halow_log_error "module-load: morse failed verification AND could not be confirmed unloaded — ownership kept so cleanup keeps retrying"
        fi
        return 1
    fi
    halow_log_info "module-load: morse loaded"
}

# halow_check_bcf_match <driver_log_text> <placed_bcf_file>
# Centralises the BCF match/no-match decision as a pure, testable text check (plus a read
# of the placed board file), shared by the real caller and the off-device test harness.
# <driver_log_text> must be ONLY the kernel-log records written since the marker taken
# immediately before this load attempt (halow_dmesg_watermark / halow_dmesg_since in
# common.sh, which fail closed when that window cannot be proven); this function never
# reads dmesg itself. <placed_bcf_file> is the verified board file the add-on placed.
#
# Accepted ONLY when, in the window, at or after the record of the morse module's own
# initialisation ("morse micro driver registration"), the driver logged
#     <dev>: Loaded BCF from <dir>/<name>, size <n>, crc32 0x<hex>
# and the name equals the placed file's name, <n> its byte size and crc32 its CRC-32. If
# the window holds several such records, ALL must match. Evidence from the defect that
# this replaces (observed on a long-running device): the earlier glob `*"BCF"*"loaded"*` matched whenever
# "BCF" appeared anywhere before the word "loaded", e.g. the generic later record
# "Driver loaded with kernel module parameters" after any record mentioning BCF; and it
# said nothing about WHICH board file. The generic driver-loaded record is never evidence.
# The explicit negative records stay hard failures. On failure HALOW_BCF_REASON says why.
halow_check_bcf_match() {
    local log_text="${1:-}" bcf_file="${2:-}" line anchored=0 matched=0
    local re_bcf='^\[[[:space:]]*[0-9]+\.[0-9]{6}\][[:space:]]+morse[a-z0-9_]*[[:space:]]+[^[:space:]]+:[[:space:]]+Loaded BCF from ([^[:space:],]+), size ([0-9]+), crc32 (0x[0-9a-fA-F]+)[[:space:]]*$'
    local want_name want_size want_crc got_name got_size got_crc
    HALOW_BCF_REASON=""
    case "$log_text" in
        *"no matching bcf"*|*"BCF"*"not found"*|*"no BCF"*)
            HALOW_BCF_REASON="the driver reported that no matching board file was found"
            return 1
            ;;
    esac
    if [ -z "$bcf_file" ] || [ ! -r "$bcf_file" ]; then
        HALOW_BCF_REASON="the placed board file cannot be read to compare with the driver's record"
        return 1
    fi
    want_name="${bcf_file##*/}"
    if ! want_size="$(wc -c < "$bcf_file" 2>/dev/null)"; then
        HALOW_BCF_REASON="the placed board file's size cannot be read"
        return 1
    fi
    want_size="$(( 10#${want_size//[[:space:]]/} ))"
    if ! want_crc="$(halow_crc32_file "$bcf_file")"; then
        HALOW_BCF_REASON="the placed board file's CRC-32 cannot be computed"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            *"morse micro driver registration"*) anchored=1; continue ;;
        esac
        [ "$anchored" -eq 1 ] || continue
        if [[ "$line" =~ $re_bcf ]]; then
            got_name="${BASH_REMATCH[1]##*/}"
            got_size="$(( 10#${BASH_REMATCH[2]} ))"
            got_crc="$(( ${BASH_REMATCH[3]} ))"
            if [ "$got_name" != "$want_name" ] || [ "$got_size" != "$want_size" ] \
               || [ "$got_crc" != "$(( want_crc ))" ]; then
                HALOW_BCF_REASON="the driver loaded a different board file than the one placed (driver: ${got_name}, ${got_size} bytes, crc32 ${BASH_REMATCH[3]}; placed: ${want_name}, ${want_size} bytes, crc32 ${want_crc})"
                return 1
            fi
            matched=1
        fi
    done <<< "$log_text"
    if [ "$anchored" -eq 0 ]; then
        HALOW_BCF_REASON="no record of this attempt's morse module initialisation in the kernel-log window"
        return 1
    fi
    if [ "$matched" -eq 0 ]; then
        HALOW_BCF_REASON="no 'Loaded BCF from ...' record from the morse driver after its initialisation in this attempt's kernel-log window"
        return 1
    fi
    return 0
}

# halow_module_state <name>
# Reports whether a kernel module is loaded: return 0 = loaded, 1 = confirmed absent,
# 2 = cannot be determined (lsmod itself failed). NEVER implemented as
# `lsmod | grep -q '^name '`:
#
# PIPEFAIL INCIDENT (2026-10-20, live test, root-caused on the Green):
# bashio runs everything with `set -o pipefail`. `grep -q` exits at the FIRST match, and
# kmod's `lsmod` writes its table line by line, so it is killed by SIGPIPE and the
# pipeline reports failure even though grep matched. Measured on the real Green inside this
# image: for a module that IS loaded, `lsmod | grep -q "^cfg80211 "` reported "absent" in
# 299 of 300 trials under pipefail (0 of 300 without -q or without pipefail). The live run
# therefore loaded mac80211 successfully, misread it as "did not appear", and unloaded it.
# The same bug would make every "confirmed absent" unload check claim success while the
# module was still loaded, clearing ownership for a module that remains in the kernel.
# This helper captures lsmod's complete output first and searches it with a here-string
# (no pipe, no early-exit writer), and distinguishes "absent" from "could not tell" so an
# lsmod failure can never be mistaken for confirmed absence. The off-device harness stubs
# `lsmod`, which this still honours.
halow_module_state() {
    local name="${1//-/_}" out
    if ! out="$(lsmod 2>/dev/null)"; then
        return 2
    fi
    if grep -q "^${name} " <<< "$out"; then
        return 0
    fi
    # Built-in code (not a loadable module) never appears in lsmod/proc/modules, but has a
    # /sys/module/<name> directory WITHOUT an `initstate` file. Report it as present so a
    # built-in mac80211 is never "claimed" as add-on-owned and never mis-reported as
    # confirmed-absent (it cannot be unloaded). The kernel names modules with underscores.
    local sm="${HALOW_SYS_MODULE_DIR:-/sys/module}/${name}"
    if [ -d "$sm" ] && [ ! -e "$sm/initstate" ]; then
        return 0
    fi
    return 1
}

# halow_module_confirmed_absent <name> — true ONLY when lsmod positively worked and the
# module is not listed. Both "still loaded" and "cannot tell" are false (fail closed).
halow_module_confirmed_absent() {
    local st
    if halow_module_state "$1"; then
        st=0
    else
        st=$?
    fi
    [ "$st" -eq 1 ]
}

# halow_module_loaded <name> — true ONLY when lsmod positively worked and lists the module.
halow_module_loaded() {
    halow_module_state "$1"
}

# halow_unload_one_module <name> <owner_key>
# Internal helper: attempts rmmod, then verifies via lsmod that it is actually gone
# before clearing ownership. Returns 0 only if the module is confirmed absent.
halow_unload_one_module() {
    local name="$1" owner_key="$2"
    rmmod "$name" 2>/dev/null || true
    if ! halow_module_confirmed_absent "$name"; then
        return 1
    fi
    halow_own_clear "$owner_key"
    halow_log_info "module-load: $name unloaded and confirmed absent"
    return 0
}

# halow_unload_modules — dependency-safe reverse order (morse, then any add-on-owned
# mac80211, then dot11ah), ownership-gated, safe to call repeatedly. mac80211 is only
# ever unloaded here if THIS add-on's own ownership marker says it loaded it — a
# pre-existing or foreign-owned mac80211 (no "module_mac80211" marker) is never touched,
# matching every other module's own foreign-artefact discipline in this file. Never
# clears ownership for a module that rmmod could not actually remove.
halow_unload_modules() {
    if halow_own_check "module_morse"; then
        if ! halow_unload_one_module "morse" "module_morse"; then
            halow_log_error "module-load: morse could not be confirmed unloaded — ownership kept"
        fi
    fi
    if halow_own_check "module_mac80211"; then
        if ! halow_unload_one_module "mac80211" "module_mac80211"; then
            halow_log_error "module-load: mac80211 could not be confirmed unloaded — ownership kept"
        fi
    fi
    if halow_own_check "module_dot11ah"; then
        if ! halow_unload_one_module "dot11ah" "module_dot11ah"; then
            halow_log_error "module-load: dot11ah could not be confirmed unloaded — ownership kept"
        fi
    fi
}
