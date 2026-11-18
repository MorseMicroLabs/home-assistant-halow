#!/usr/bin/env bash
# halow: full rollback. Every step below is individually ownership-gated or recognises its
# resource from the host itself, and is idempotent, so calling halow_rollback is always
# safe: from a complete running state, from any partial-start state, from the separate
# `finish` process (which shares no shell state with the manager), and more than once in a
# row.
#
# Order (each step runs while what it depends on still exists):
#   1. the registered networking backend (DHCP, NAT chain and jump)
#   2. NetworkManager marks of per-station interfaces (keys nm_unmanaged_wds*)
#   3. hostapd_s1g (identified strictly from durable state, never from a caller's pid)
#   4. the private bridge
#   5. NetworkManager marks of the bridge and of the parent interface, then the IPv6
#      setting of every interface this add-on turned IPv6 off on (keys ipv6_*)
#   6. the remaining firewall jumps, then the filter chains, then an INPUT base chain this
#      add-on created (recorded as fw_created_input4/6)
#   7. kernel modules this add-on loaded: those with their own record, then those an
#      intent record (module_intent_*) shows were loaded by this add-on although the
#      load ended before its own record was written, and mac80211's dependency libarc4
#      when the load brought it in (the host compared with the modules recorded before)
#   8. the host firmware search path
#   9. the staged firmware files
# The privileged steps (2/5 restore, 3 stop, 7 unload, 8 restore, 9 remove) keep the same
# calls in the same relative order as the earlier, hardware-exercised build.
#
# Honest aggregate reporting: after every step, anything still owned (an ownership marker
# that the step could not clear because the undo was not confirmed), or still present on
# the host (the bridge or an add-on firewall chain recognised by name), is collected; the
# function then logs "rollback: INCOMPLETE" with the exact list, sets
# HALOW_ROLLBACK_RESIDUAL to it and returns non-zero. Callers must surface this.
#
# hostapd's lifecycle files (its rendered configuration, which holds the passphrase, its
# log and pid file) and its "hostapd_process" marker live in the volatile run directory,
# not in the persistent state directory: hostapd_config.sh keeps them beside the ownership
# markers of whatever state directory it is given, so its calls are made with the run
# directory as that state directory (halow_rollback_hostapd_scope). A hostapd process
# cannot outlive its container, so a volatile marker is the correct lifetime for it. A
# marker left in the persistent directory by an earlier build is still honoured.

# The ownership keys the CORE owns. The registered backend's keys are asked for at
# rollback time; the core never lists a backend's keys. Every key starting with
# nm_unmanaged_wds is also treated as core-owned.
HALOW_CORE_OWNERSHIP_KEYS_BEFORE_BACKEND="firmware_main firmware_bcf firmware_dir fw_search_path nm_unmanaged_parent nm_unmanaged_bridge module_dot11ah module_mac80211 module_morse module_libarc4 module_intent_morse module_intent_dot11ah net_bridge fw_filter fw_created_input4 fw_created_input6"
HALOW_CORE_OWNERSHIP_KEYS_AFTER_BACKEND="hostapd_process"
HALOW_ALL_OWNERSHIP_KEYS=""
HALOW_ROLLBACK_RESIDUAL=""

# The modules each load intent covers, in unload order (dependants first). The morse
# load also loads mac80211 (and through it libarc4) when they are not loaded yet.
HALOW_ROLLBACK_INTENT_MODULES="morse:morse,mac80211,libarc4 dot11ah:dot11ah"

# halow_rollback_loaded_modules — prints the names of the loaded (loadable) kernel modules
# from lsmod on one line, space-separated; 1 (nothing printed) when lsmod fails.
halow_rollback_loaded_modules() {
    local IFS=$' \t\n' out line name list=""
    if ! out="$(lsmod 2>/dev/null)"; then
        return 1
    fi
    while IFS= read -r line; do
        name="${line%%[[:space:]]*}"
        case "$name" in ''|Module) continue ;; esac
        list="${list}${name} "
    done <<< "$out"
    printf '%s' "${list% }"
}

# _halow_rollback_module_intents — step 7b: for every intent record, each covered module
# that is loaded now, was not loaded when the intent was recorded and holds no record of
# its own, is this add-on's: its record is written first, then it is unloaded and
# confirmed absent. The intent record is cleared only when every covered module is
# confirmed absent or was already loaded before. A module whose own record is still
# held (its unload already failed) keeps the intent record too.
_halow_rollback_module_intents() {
    local IFS=$' \t\n' entry name mods m before now ok
    for entry in $HALOW_ROLLBACK_INTENT_MODULES; do
        name="${entry%%:*}"
        mods="${entry#*:}"
        halow_own_check "module_intent_${name}" || continue
        before=" $(halow_own_get "module_intent_${name}") "
        ok=1
        for m in ${mods//,/ }; do
            if ! now="$(halow_rollback_loaded_modules)"; then
                halow_log_error "rollback: the loaded modules cannot be listed; the load intent for $name is kept"
                ok=0
                break
            fi
            case " $now " in *" $m "*) ;; *) continue ;; esac
            case "$before" in *" $m "*) continue ;; esac
            if halow_own_check "module_${m}"; then
                ok=0
                continue
            fi
            if ! halow_own_mark "module_${m}"; then
                halow_log_error "rollback: $m (loaded by this add-on) could not be recorded; it is left loaded"
                ok=0
                continue
            fi
            if halow_unload_one_module "$m" "module_${m}"; then
                halow_log_info "rollback: $m, loaded by this add-on without its own record, unloaded"
            else
                halow_log_error "rollback: $m (loaded by this add-on) could not be confirmed unloaded"
                ok=0
            fi
        done
        if [ "$ok" -eq 1 ]; then
            halow_own_clear "module_intent_${name}"
        fi
    done
    return 0
}

# halow_rollback_ipv6_keys — prints every held ipv6_* key (a recorded setting) and every held
# ipv6br_* key (a temporary-mount bracket not verified closed), one per line.
halow_rollback_ipv6_keys() {
    local key
    while IFS= read -r key; do
        case "$key" in
            ipv6_*|ipv6br_*) printf '%s\n' "$key" ;;
        esac
    done < <(halow_own_list)
}

# halow_rollback_hostapd_scope <command> [args...]
# Runs a hostapd_config.sh lifecycle call with the volatile run directory as its state
# directory (see this file's header). Returns the command's own status.
halow_rollback_hostapd_scope() {
    HALOW_STATE_DIR="${HALOW_RUN_DIR:?}" "$@"
}

# halow_rollback_wds_keys — prints every held nm_unmanaged_wds* key, one per line.
halow_rollback_wds_keys() {
    local key
    while IFS= read -r key; do
        case "$key" in
            nm_unmanaged_wds*) printf '%s\n' "$key" ;;
        esac
    done < <(halow_own_list)
}

# halow_rollback
# Returns 0 only if every tracked mutation was confirmed undone (no core or backend
# ownership marker remains, no add-on bridge or firewall chain is still present on the
# host, and no step found a live process this package could not account for); returns 1
# otherwise, having logged exactly what remains (also in HALOW_ROLLBACK_RESIDUAL).
halow_rollback() {
    # The default field separator, whatever the caller's context (word splitting of the
    # key lists below depends on it).
    local IFS=$' \t\n'
    halow_log_info "rollback: beginning teardown"
    HALOW_ROLLBACK_RESIDUAL=""

    # A hard failure is a step that positively identified a live process (or an
    # unresolved identity) this package holds no ownership marker for. It is tracked
    # separately from the ownership-key aggregate, which only catches "we owned this and
    # could not undo it".
    local hard_failure=0 host_residual="" key _rc

    # 1. The registered backend, while the bridge and interfaces it uses still exist.
    if halow_backend_call teardown; then
        _rc=0
    else
        _rc=$?
    fi
    [ "$_rc" -eq 0 ] || hard_failure=1

    # 2. Per-station interfaces' NetworkManager state, before hostapd (stopping hostapd
    # destroys those interfaces; restoring while they exist is the clean path, and the
    # restore function handles an interface that has already gone).
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        halow_nm_restore_managed "$key" || true
    done < <(halow_rollback_wds_keys)

    # 3. hostapd_s1g, identified strictly from durable state.
    if halow_rollback_hostapd_scope halow_stop_hostapd; then
        _rc=0
    else
        _rc=$?
    fi
    [ "$_rc" -eq 0 ] || hard_failure=1
    if halow_own_check "hostapd_process"; then
        # A marker left in the persistent state directory by an earlier build.
        halow_stop_hostapd || hard_failure=1
    fi

    # 4. The private bridge: undone when owned, and also when it is recognised on the
    # host by its name (residue whose marker was lost).
    if declare -F halow_bridge_delete >/dev/null 2>&1; then
        if halow_own_check "net_bridge" || halow_bridge_exists "$HALOW_BRIDGE_NAME"; then
            if halow_bridge_delete "$HALOW_BRIDGE_NAME"; then
                _rc=0
            else
                _rc=$?
            fi
            if [ "$_rc" -ne 0 ]; then
                halow_log_error "rollback: the bridge $HALOW_BRIDGE_NAME could not be confirmed deleted"
            fi
        fi
    fi

    # 5. NetworkManager state of the bridge, then of the parent interface (the parent
    # persists until the modules are unloaded in step 7).
    halow_nm_restore_managed "nm_unmanaged_bridge" || true
    halow_nm_restore_managed "nm_unmanaged_parent" || true

    # 5b. The IPv6 setting of every interface it was turned off on (an interface that no
    # longer exists counts as restored; a marker is cleared only after confirmation, so
    # anything unconfirmed shows in the aggregate below).
    if ! halow_ipv6_restore_all; then
        halow_log_error "rollback: the IPv6 setting of at least one interface could not be confirmed restored"
        # A leftover temporary mount is recorded when its cleanup fails, so that shows in the
        # aggregate below. A failure that leaves no record while the mount table is readable
        # (for example a mount on a name that cannot be recorded) must not read as complete;
        # an unreadable table with nothing listed and nothing recorded is only logged (the
        # set side already fails closed), so it cannot refuse forever.
        if [ -z "$(halow_rollback_ipv6_keys)" ] && halow_ipv6_mount_table_readable; then
            host_residual="${host_residual}ipv6-switch-mount "
        fi
    fi

    # 6. Remaining firewall jumps, then the filter chains (recognised by chain name on
    # the host, independent of markers).
    if declare -F halow_fw_remove_filters >/dev/null 2>&1; then
        if halow_fw_remove_filters; then
            _rc=0
        else
            _rc=$?
        fi
        if [ "$_rc" -ne 0 ]; then
            halow_log_error "rollback: the add-on firewall filter chains could not be confirmed removed"
        fi
    fi

    # 7. Kernel modules, only now that every interface's NetworkManager state is handled
    # (unloading destroys the parent interface).
    halow_unload_modules
    # 7b. Modules a load intent shows this add-on loaded without their own record.
    _halow_rollback_module_intents

    # 8. The firmware search path. Normally already restored by the manager right after
    # the board-file match; this closes the gap after a crash or an earlier failed
    # restore. Exit 3 (CRITICAL: /sys may remain writable) and 4 (a record could not be
    # written) are logged distinctly; the aggregate below reports the kept marker.
    local _fw_restore_rc
    if halow_restore_firmware_search_path; then
        _fw_restore_rc=0
    else
        _fw_restore_rc=$?
    fi
    if [ "$_fw_restore_rc" -eq 3 ]; then
        halow_log_error "rollback: CRITICAL — /sys could not be confirmed restored to its own prior mount mode during this restore attempt; it may remain writable on this host"
    elif [ "$_fw_restore_rc" -eq 4 ]; then
        halow_log_error "rollback: CRITICAL — an ownership record (the 'applied' state or 'firmware_path_reboot_required') could not be written during the firmware search-path restore; the host value may hold the sentinel or this add-on's path without a matching record — manual review required (this is NOT a /sys mount-mode problem)"
    fi

    # 9. The staged firmware files, re-verified against the shipped manifest before
    # removal (the manifest is the one source both the manager and finish can re-derive).
    halow_remove_firmware \
        "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" \
        "$(halow_checksum_for "$HALOW_FW_MAIN_NAME" 2>/dev/null)" \
        "firmware_main" "firmware_dir" || true
    halow_remove_firmware \
        "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}" \
        "$(halow_checksum_for "bcf/$HALOW_FW_BCF_NAME" 2>/dev/null)" \
        "firmware_bcf" "firmware_dir" || true

    # --- Aggregate: markers still held, and add-on resources still on the host. ---
    HALOW_ALL_OWNERSHIP_KEYS="$HALOW_CORE_OWNERSHIP_KEYS_BEFORE_BACKEND $(halow_backend_ownership_keys 2>/dev/null || true) $HALOW_CORE_OWNERSHIP_KEYS_AFTER_BACKEND"
    local residual_keys=""
    for key in $HALOW_ALL_OWNERSHIP_KEYS; do
        if halow_own_check "$key"; then
            residual_keys="${residual_keys}${key} "
        fi
    done
    if halow_rollback_hostapd_scope halow_own_check "hostapd_process"; then
        case " $residual_keys " in
            *" hostapd_process "*) ;;
            *) residual_keys="${residual_keys}hostapd_process " ;;
        esac
    fi
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        residual_keys="${residual_keys}${key} "
    done < <(halow_rollback_wds_keys; halow_rollback_ipv6_keys)

    if declare -F halow_bridge_exists >/dev/null 2>&1 && halow_bridge_exists "$HALOW_BRIDGE_NAME"; then
        host_residual="${host_residual}bridge:${HALOW_BRIDGE_NAME} "
    fi
    if declare -F halow_fw_present >/dev/null 2>&1 && halow_fw_present >/dev/null 2>&1; then
        host_residual="${host_residual}firewall-chains "
    fi

    if [ -n "$residual_keys" ] || [ -n "$host_residual" ] || [ "$hard_failure" -ne 0 ]; then
        if halow_own_check "firmware_path_reboot_required"; then
            halow_log_warning "rollback: 'firmware_path_reboot_required' is ALSO held — the firmware search path holds the inert sentinel and exact (empty) restoration is still pending a host reboot and its post-reboot verification"
        fi
        if [ -n "$residual_keys" ]; then
            halow_log_error "rollback: INCOMPLETE — residual ownership: [${residual_keys% }]"
        fi
        if [ -n "$host_residual" ]; then
            halow_log_error "rollback: INCOMPLETE — still present on the host: [${host_residual% }]"
        fi
        if [ "$hard_failure" -ne 0 ]; then
            halow_log_error "rollback: INCOMPLETE — at least one step found a positively-identified process or an unresolved identity with no corresponding ownership marker (see the preceding error lines for which); it was not signalled"
        fi
        HALOW_ROLLBACK_RESIDUAL="${residual_keys}${host_residual}"
        [ "$hard_failure" -eq 0 ] || HALOW_ROLLBACK_RESIDUAL="${HALOW_ROLLBACK_RESIDUAL}unowned-process "
        HALOW_ROLLBACK_RESIDUAL="${HALOW_ROLLBACK_RESIDUAL% }"
        return 1
    fi

    # "firmware_path_reboot_required" is deliberately not in the aggregate: after an
    # empty prior value the inert sentinel is installed by design, which is not a cleanup
    # failure — but it is also not an exact restoration, so it is reported as its own
    # third state.
    if halow_own_check "firmware_path_reboot_required"; then
        halow_log_warning "rollback: complete, EXCEPT that the host firmware search path holds the inert sentinel instead of its true empty value; 'firmware_path_reboot_required' stays held until a host reboot and the post-reboot verification clear it. This is NOT an exact restoration."
        return 0
    fi

    halow_log_info "rollback: complete"
    return 0
}

# halow_finish_decide <rollback_ok_0_or_1> <app_exit_code>
# Pure decision logic for the separate `finish` process's own halt-vs-clean choice —
# called directly by `finish`, so this logic has exactly one copy.
#
# Returns 0 ("clean" — nothing further needed) when rollback succeeded AND the app's own
# exit looked clean (exit code 0, or 256 — s6-overlay's own convention for "no exit code,
# killed by a signal"). Returns 1 ("halt needed") otherwise, printing the exact exit code
# the caller must write to the s6 results file before halting:
#   - if the app itself already exited with a real failure code (anything other than 0
#     or 256), that exact code is preserved and takes priority;
#   - otherwise, if rollback failed despite a clean-looking app exit, a generic non-zero
#     code (1) is used — the app's own exit does not excuse an incomplete cleanup.
halow_finish_decide() {
    local rollback_ok="$1" app_exit_code="$2"
    if [ "$app_exit_code" -ne 0 ] && [ "$app_exit_code" -ne 256 ]; then
        printf '%s' "$app_exit_code"
        return 1
    fi
    if [ "$rollback_ok" -ne 0 ]; then
        printf '%s' "1"
        return 1
    fi
    return 0
}
