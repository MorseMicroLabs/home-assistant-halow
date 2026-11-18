#!/usr/bin/env bash
# halow: start-up reconcile and the persisted refusal.
#
# Every start begins here, before the options are even read. The ownership markers are
# hints; the host is the truth:
#   - the host boot id is compared with the one recorded at the previous start. A changed
#     id means the host rebooted, so every runtime-only change this add-on made (modules,
#     firmware search path, bridge, firewall chains, NetworkManager flags, processes) was
#     reset: runtime-only markers are checked against the host and cleared, and a pending
#     "reboot required" firmware-path marker is verified byte-exact automatically;
#   - residue is recognised from the host itself (add-on firewall chains and jumps, the
#     bridge by name, hostapd and dnsmasq by their identity scans, the inert firmware-path
#     sentinel) and undone through halow_rollback;
#   - a radio module loaded with no record of its own but with this add-on's load intent
#     recorded (the load ended before its record was written) is this add-on's and is
#     unloaded by rollback when the host shows it appeared after the intent;
#   - anything unrecognised (for example a radio module loaded by someone else) is left
#     alone and reported, never removed.
#
# The refusal marker (persistent) records that an earlier rollback could not be
# confirmed. While it is present nothing new may be changed on the host: only rollback
# and its verification are retried, and the marker is cleared only once they succeed.
#
# Defines functions and constants only.

HALOW_RECONCILE_FOREIGN=""
HALOW_RECONCILE_RESIDUAL=""
HALOW_RECONCILE_NOTES=""

# Module markers and the kernel module each one names.
HALOW_RECONCILE_MODULE_KEYS="module_morse:morse module_mac80211:mac80211 module_dot11ah:dot11ah"

# --- The persisted refusal ---------------------------------------------------------

halow_refusal_file() {
    printf '%s/refusal' "${HALOW_STATE_DIR:?}"
}

# halow_refusal_set <reason> — persist the refusal (atomic). 1 if it cannot be written.
halow_refusal_set() {
    local reason="${1:-ROLLBACK_INCOMPLETE}" f now
    f="$(halow_refusal_file)"
    now="$(date +%s 2>/dev/null || echo 0)"
    mkdir -p -- "${HALOW_STATE_DIR:?}" 2>/dev/null || true
    if ! printf '%s\n%s\n' "$reason" "$now" > "${f}.tmp.$$" 2>/dev/null; then
        rm -f -- "${f}.tmp.$$"
        halow_log_error "reconcile: CRITICAL — could not persist the refusal marker ($reason)"
        return 1
    fi
    if ! mv -f -- "${f}.tmp.$$" "$f" 2>/dev/null; then
        rm -f -- "${f}.tmp.$$"
        halow_log_error "reconcile: CRITICAL — could not persist the refusal marker ($reason)"
        return 1
    fi
    halow_log_warning "reconcile: refusal recorded ($reason): no new host changes until rollback is confirmed"
    return 0
}

# halow_refusal_present — 0 if the refusal marker is present.
halow_refusal_present() {
    [ -e "$(halow_refusal_file)" ]
}

# halow_refusal_reason — prints the recorded reason (empty if none).
halow_refusal_reason() {
    local f line=""
    f="$(halow_refusal_file)"
    [ -f "$f" ] || return 0
    IFS= read -r line < "$f" 2>/dev/null || true
    printf '%s' "$line"
}

# halow_refusal_clear — remove the marker and confirm it is gone. 1 if it remains.
halow_refusal_clear() {
    local f
    f="$(halow_refusal_file)"
    rm -f -- "$f" 2>/dev/null || true
    if halow_path_still_present "$f"; then
        halow_log_error "reconcile: the refusal marker could not be removed"
        return 1
    fi
    return 0
}

# --- Helpers -----------------------------------------------------------------------

_halow_reconcile_note() {
    HALOW_RECONCILE_NOTES="${HALOW_RECONCILE_NOTES}$1; "
    halow_log_info "reconcile: $1"
}

_halow_reconcile_foreign() {
    HALOW_RECONCILE_FOREIGN="${HALOW_RECONCILE_FOREIGN}$1; "
    halow_log_warning "reconcile: left alone (not recognised as this add-on's): $1"
}

_halow_reconcile_residual() {
    HALOW_RECONCILE_RESIDUAL="${HALOW_RECONCILE_RESIDUAL}$1 "
    halow_log_error "reconcile: could not be confirmed undone: $1"
}

# _halow_reconcile_sysfs_value — prints the firmware search-path node's current value;
# 1 if it cannot be read.
_halow_reconcile_sysfs_value() {
    cat -- "${HALOW_FW_SYSFS_PATH}" 2>/dev/null
}

# _halow_reconcile_after_reboot
# The host rebooted since the markers were written. Runtime-only markers describe state
# the reboot reset; each is checked against the host before it is cleared.
_halow_reconcile_after_reboot() {
    local pair key mod st marker rest our_value current

    # Modules: a module the marker names that is absent now was unloaded by the reboot.
    # One that is loaded now was loaded by someone else after the reboot: it is never
    # unloaded by this add-on; the stale marker is cleared and the module reported.
    for pair in $HALOW_RECONCILE_MODULE_KEYS; do
        key="${pair%%:*}"
        mod="${pair#*:}"
        halow_own_check "$key" || continue
        if halow_module_state "$mod"; then
            st=0
        else
            st=$?
        fi
        case "$st" in
            1)
                halow_own_clear "$key"
                _halow_reconcile_note "stale marker $key cleared after a reboot ($mod confirmed not loaded)"
                ;;
            0)
                halow_own_clear "$key"
                _halow_reconcile_foreign "module:$mod (loaded after the reboot by something else; its stale marker was cleared, the module is not touched)"
                ;;
            *)
                _halow_reconcile_note "marker $key kept: whether $mod is loaded cannot be determined"
                ;;
        esac
    done

    # Firmware search path: an active marker whose value is no longer on the node was
    # reset by the reboot.
    if halow_own_check "fw_search_path"; then
        marker="$(halow_own_get "fw_search_path")"
        rest="${marker#*$'\n'}"
        our_value="${rest#*$'\n'}"
        if current="$(_halow_reconcile_sysfs_value)"; then
            if [ "$current" != "$our_value" ] && [ "$current" != "${HALOW_FW_SEARCH_SENTINEL}" ]; then
                halow_own_clear "fw_search_path"
                _halow_reconcile_note "stale marker fw_search_path cleared after a reboot (the node no longer holds this add-on's value)"
            fi
        fi
    fi

    # The pending exact-empty verification: runs automatically now; the marker is
    # cleared only on a byte-exact pass and kept otherwise.
    if halow_own_check "firmware_path_reboot_required"; then
        if halow_verify_fw_search_path_rebooted_clean; then
            _halow_reconcile_note "firmware search path verified empty after the reboot; reboot-required marker cleared"
        else
            _halow_reconcile_note "firmware search path not verified empty after the reboot; reboot-required marker kept"
        fi
    fi

    # Load intents and recorded IPv6 settings describe the previous boot only: modules and
    # interfaces were reset by the reboot (a module loaded now is someone else's, and an
    # interface present now was created after the reboot).
    for key in module_intent_morse module_intent_dot11ah; do
        if halow_own_check "$key"; then
            halow_own_clear "$key"
            _halow_reconcile_note "stale marker $key cleared after a reboot"
        fi
    done
    while IFS= read -r key; do
        case "$key" in
            ipv6_*|ipv6br_*)
                # (A temporary mount cannot outlive the reboot; the rollback below still
                # looks for one in the mount table, never only in a record.)
                halow_own_clear "$key"
                _halow_reconcile_note "stale marker $key cleared after a reboot"
                ;;
        esac
    done < <(halow_own_list)

    # The bridge and the firewall chains do not survive a reboot; their markers are
    # cleared when the host confirms they are absent (otherwise rollback handles them).
    if halow_own_check "net_bridge" && declare -F halow_bridge_exists >/dev/null 2>&1; then
        if ! halow_bridge_exists "$HALOW_BRIDGE_NAME"; then
            halow_own_clear "net_bridge"
            _halow_reconcile_note "stale marker net_bridge cleared after a reboot (bridge absent)"
        fi
    fi
    # A record that this add-on created an INPUT base chain describes the previous boot:
    # whatever INPUT chain exists now was not created by this add-on, so the claim is
    # dropped and the chain is never removed.
    for key in fw_created_input4 fw_created_input6; do
        if halow_own_check "$key"; then
            halow_own_clear "$key"
            _halow_reconcile_note "stale marker $key cleared after a reboot (an INPUT base chain present now is not this add-on's)"
        fi
    done
    if declare -F halow_fw_present >/dev/null 2>&1 && ! halow_fw_present >/dev/null 2>&1; then
        for key in fw_filter fw_nat; do
            if halow_own_check "$key"; then
                halow_own_clear "$key"
                _halow_reconcile_note "stale marker $key cleared after a reboot (no add-on chain present)"
            fi
        done
    fi
    # NetworkManager marks, addresses and dnsmasq/hostapd are handled by rollback, whose
    # undo steps already decide from the host (an interface that no longer exists, a
    # process that is confirmed absent).
}

# _halow_reconcile_recognise_host
# Residue recognised from the host without relying on markers. Records what was seen;
# the actual undo is halow_rollback's.
_halow_reconcile_recognise_host() {
    local current rc pair mod
    if declare -F halow_fw_present >/dev/null 2>&1 && halow_fw_present >/dev/null 2>&1; then
        _halow_reconcile_note "add-on firewall chains or jumps present on the host; they will be removed"
    fi
    if declare -F halow_bridge_exists >/dev/null 2>&1 && halow_bridge_exists "$HALOW_BRIDGE_NAME"; then
        _halow_reconcile_note "bridge $HALOW_BRIDGE_NAME present on the host; it will be removed"
    fi

    # The inert firmware-path sentinel: only this add-on writes it. With no record, the
    # record was lost (for example the persistent data was removed): adopt the pending
    # reboot-required state so it stays visible.
    if current="$(_halow_reconcile_sysfs_value)"; then
        if [ "$current" = "${HALOW_FW_SEARCH_SENTINEL}" ] && ! halow_own_check "fw_search_path" \
            && ! halow_own_check "firmware_path_reboot_required"; then
            if halow_own_mark "firmware_path_reboot_required"; then
                _halow_reconcile_note "the inert firmware-path sentinel is on the host without a record; reboot-required state re-recorded"
            else
                _halow_reconcile_residual "fw_search_path:sentinel-unrecorded"
            fi
        fi
        # Slug note (comment only): the pattern below matches only this add-on's slug. A
        # firmware directory left by an earlier development slug is NOT recognised here
        # (only the inert sentinel above is, whichever slug wrote it), so such residue is
        # not reported; the README tells the owner to reboot the Green in that case.
        # This add-on's own firmware directory on the node with no record: it cannot be
        # restored exactly (the true prior value is unknown).
        case "$current" in
            */apps/data/*morse_micro_halow_ap/halow_fw)
                if ! halow_own_check "fw_search_path"; then
                    # The node holds this add-on's directory with no record of its prior
                    # value, so it cannot be restored exactly; a host reboot resets it.
                    _halow_reconcile_residual "fw_search_path:unrecorded"
                fi
                ;;
        esac
    fi

    if halow_ipv6_present; then
        _halow_reconcile_note "IPv6 settings changed by this add-on are recorded; they will be restored"
    fi

    # Radio modules loaded without a marker are not this add-on's to unload, unless a load
    # intent shows this add-on loaded them (rollback compares the host with the intent).
    for pair in $HALOW_RECONCILE_MODULE_KEYS; do
        mod="${pair#*:}"
        [ "$mod" = "mac80211" ] && continue
        halow_own_check "${pair%%:*}" && continue
        if halow_own_check "module_intent_${mod}"; then
            _halow_reconcile_note "a load intent for $mod is recorded; rollback decides from the host whether this add-on loaded it"
            continue
        fi
        if halow_module_state "$mod"; then
            rc=0
        else
            rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            _halow_reconcile_foreign "module:$mod (loaded with no record of this add-on loading it)"
        fi
    done
}

# halow_reconcile
# 0 host verified clean of this add-on's residue; 1 something could not be confirmed
# undone (HALOW_RECONCILE_RESIDUAL lists it). The caller raises ROLLBACK_INCOMPLETE and
# sets the refusal marker on 1. With the refusal marker present this only retries
# rollback and verification, and clears the marker once both succeed.
halow_reconcile() {
    local IFS=$' \t\n' boot_rc rb_rc
    HALOW_RECONCILE_FOREIGN=""
    HALOW_RECONCILE_RESIDUAL=""
    HALOW_RECONCILE_NOTES=""

    if halow_refusal_present; then
        halow_log_warning "reconcile: an earlier rollback was not confirmed ($(halow_refusal_reason)); retrying rollback only"
    fi

    if halow_boot_id_changed; then
        boot_rc=0
    else
        boot_rc=$?
    fi
    case "$boot_rc" in
        0)
            _halow_reconcile_note "the host rebooted since the last start"
            _halow_reconcile_after_reboot
            ;;
        1) : ;;
        2) _halow_reconcile_note "no boot id recorded yet" ;;
        *) _halow_reconcile_note "the host boot id cannot be read; markers are not treated as stale" ;;
    esac

    _halow_reconcile_recognise_host

    if halow_rollback; then
        rb_rc=0
    else
        rb_rc=$?
    fi
    if [ "$rb_rc" -ne 0 ]; then
        _halow_reconcile_residual "${HALOW_ROLLBACK_RESIDUAL:-rollback}"
    fi

    # Record this boot only after the stale-marker handling above, so a failed start
    # cannot hide a reboot from the next one.
    if [ "$boot_rc" -ne 3 ]; then
        if ! halow_boot_id_record; then
            halow_log_warning "reconcile: the current boot id could not be recorded; the next start cannot detect a reboot"
        fi
    fi

    HALOW_RECONCILE_FOREIGN="${HALOW_RECONCILE_FOREIGN%; }"
    HALOW_RECONCILE_RESIDUAL="${HALOW_RECONCILE_RESIDUAL% }"
    if [ -n "$HALOW_RECONCILE_RESIDUAL" ]; then
        halow_log_error "reconcile: host NOT verified clean: [$HALOW_RECONCILE_RESIDUAL]"
        return 1
    fi
    if halow_refusal_present; then
        if ! halow_refusal_clear; then
            _halow_reconcile_residual "refusal-marker"
            return 1
        fi
        halow_log_info "reconcile: rollback confirmed; the refusal marker is cleared"
    fi
    halow_log_info "reconcile: host verified clean of this add-on's residue"
    return 0
}
