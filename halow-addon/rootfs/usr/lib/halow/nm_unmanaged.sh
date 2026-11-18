#!/usr/bin/env bash
# halow: NetworkManager-unmanaged interface control via D-Bus. Supersedes the
# package-created-udev-rule mechanism (udev_rule.sh), confirmed non-functional:
# Supervisor's own `udev: true` mounts /run/udev read-only
# (see udev_rule.sh's own header), so no write from inside this container can ever reach
# it. This mechanism instead requests `host_dbus: true` (confirmed from Supervisor
# source to be a full, unscoped bind-mount of the real host system D-Bus socket) and
# talks to NetworkManager directly over it, using `dbus-send` (this add-on's own
# Dockerfile installs the `dbus` package for it).
#
# NetworkManager's `Device.Managed` property is the applicable mechanism on HAOS's
# actual shipped NetworkManager version (1.44.2, confirmed from the home-assistant/
# buildroot fork's own network-manager.mk — predates the newer SetManaged() method
# introduced in NM 1.58).
#
# Protects BOTH interfaces this add-on ever touches, independently, each under its own
# ownership key: the PARENT HaLow interface (marked unmanaged right after the driver
# binds it and halow_verify_parent_iface confirms it, BEFORE hostapd ever starts —
# closing the exact window the original proactive udev-rule design existed to close) and
# the dynamically-created WDS/AP_VLAN interface (marked unmanaged immediately after
# halow_detect_wds_iface confirms it, once a client associates).
#
# A real, unavoidable race: the WDS interface is created by the driver itself only at
# association time, and NetworkManager must independently observe and register it as its
# own D-Bus Device object before GetDeviceByIpIface can resolve it at all — resolution
# below retries with a bounded timeout rather than failing or blocking indefinitely.
#
# Hardening is identical in kind to module_load.sh's own firmware search-path mechanism:
# the TRUE prior Managed value of each interface is recorded (never assumed
# true — an interface could already be unmanaged for an unrelated reason), restoration
# refuses to overwrite a value some other actor changed since this package's own set,
# and ownership is cleared only once a restore is positively confirmed by reading the
# property back — never merely attempted. One further case this mechanism specifically
# has to handle, which the sysfs mechanism does not: the dynamic WDS/AP_VLAN interface
# this add-on marks unmanaged is routinely DESTROYED by this add-on's own later actions
# (stopping hostapd removes it) — a D-Bus failure to resolve/read it afterward must never
# be treated as "safely gone" without independently confirming the underlying kernel
# interface is actually gone too (see halow_nm_restore_managed, below, and
# halow_kernel_iface_exists in iface_detect.sh).

HALOW_NM_BUS_NAME="org.freedesktop.NetworkManager"
HALOW_NM_IFACE_DEVICE="org.freedesktop.NetworkManager.Device"
HALOW_NM_PROPS_IFACE="org.freedesktop.DBus.Properties"

# halow_nm_resolve_device <iface> [<timeout_seconds>]
# Resolves <iface>'s own NetworkManager D-Bus object path via GetDeviceByIpIface,
# retrying once a second until NetworkManager itself has registered the device (see this
# file's own header on the WDS creation race) or <timeout_seconds> (default 10) elapses.
# Prints the object path on success; returns 1 on timeout — never guesses, never blocks
# indefinitely.
halow_nm_resolve_device() {
    local iface="$1" timeout="${2:-10}" waited=0 reply path unknown_every_time=1
    while [ "$waited" -lt "$timeout" ]; do
        reply="$(dbus-send --system --print-reply --dest="$HALOW_NM_BUS_NAME" \
            /org/freedesktop/NetworkManager \
            "${HALOW_NM_BUS_NAME}.GetDeviceByIpIface" "string:${iface}" 2>&1 || true)"
        path="$(printf '%s\n' "$reply" | awk '/object path/ {print $3}' | tr -d '"')"
        if [ -n "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
        # NetworkManager's own definitive "I do not know this interface" answer
        # (org.freedesktop.NetworkManager.UnknownDevice) is tracked separately from every other
        # failure (bus unreachable, permission denied, NetworkManager not running...).
        case "$reply" in
            *"org.freedesktop.NetworkManager.UnknownDevice"*) : ;;
            *) unknown_every_time=0 ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done
    halow_log_error "nm-unmanaged: NetworkManager never exposed a Device object for $iface within ${timeout}s"
    # return 3 = NetworkManager answered UnknownDevice on EVERY attempt (it positively does not
    # know the interface); return 1 = anything else (could not tell).
    if [ "$unknown_every_time" -eq 1 ]; then
        return 3
    fi
    return 1
}

# halow_nm_get_managed <device_path>
# Prints exactly "true" or "false", read fresh every call — never cached. Returns 1 if
# the property could not be read at all, so callers never confuse "unknown" with a
# successfully-read "false".
halow_nm_get_managed() {
    local device_path="$1" reply value
    reply="$(dbus-send --system --print-reply --dest="$HALOW_NM_BUS_NAME" "$device_path" \
        "${HALOW_NM_PROPS_IFACE}.Get" "string:${HALOW_NM_IFACE_DEVICE}" "string:Managed" 2>/dev/null || true)"
    value="$(printf '%s\n' "$reply" | awk '/boolean/ {print $3}')"
    case "$value" in
        true|false)
            printf '%s\n' "$value"
            ;;
        *)
            halow_log_error "nm-unmanaged: could not read the Managed property of $device_path"
            return 1
            ;;
    esac
}

# halow_nm_set_managed <device_path> <true|false>
# Sets Managed, then reads it straight back to CONFIRM the write actually took effect —
# never assumed from the Set call's own (lack of) error alone.
halow_nm_set_managed() {
    local device_path="$1" value="$2" readback
    if ! dbus-send --system --print-reply --dest="$HALOW_NM_BUS_NAME" "$device_path" \
        "${HALOW_NM_PROPS_IFACE}.Set" "string:${HALOW_NM_IFACE_DEVICE}" "string:Managed" "variant:boolean:${value}" \
        >/dev/null 2>&1; then
        halow_log_error "nm-unmanaged: the D-Bus Set call itself failed for $device_path (Managed=$value)"
        return 1
    fi
    readback="$(halow_nm_get_managed "$device_path")" || return 1
    if [ "$readback" != "$value" ]; then
        halow_log_error "nm-unmanaged: set Managed=$value on $device_path but read back '$readback'"
        return 1
    fi
}

# halow_nm_mark_unmanaged <iface> <owner_key> [<resolve_timeout_seconds>]
# Resolves <iface>'s own NetworkManager device, records its TRUE current Managed value
# (never assumed true) together with its own device path and interface name under
# <owner_key> (ownership.sh's own content-storage capability, as three lines: prior
# value, device path, interface name — the interface name is recorded too, not just the
# device path, so halow_nm_restore_managed can still check the KERNEL's own interface
# list by name later, from a separate process (`finish`) that never itself called this
# function and has no other way to know which real interface name a given owner_key
# refers to), sets Managed=false, and verifies by reading it back. Idempotent: if this
# package already owns <owner_key> and the device already reads back unmanaged, this is
# a no-op. Fail-closed throughout — never leaves a half-recorded, half-applied state.
halow_nm_mark_unmanaged() {
    local iface="$1" owner_key="$2" resolve_timeout="${3:-10}"
    local device_path prior current

    local resolve_rc
    if device_path="$(halow_nm_resolve_device "$iface" "$resolve_timeout")"; then
        resolve_rc=0
    else
        resolve_rc=$?
    fi
    if [ "$resolve_rc" -ne 0 ]; then
        return "$resolve_rc"   # 3 = NetworkManager positively does not know this interface; 1 = could not tell
    fi

    if halow_own_check "$owner_key"; then
        current="$(halow_nm_get_managed "$device_path" 2>/dev/null || true)"
        if [ "$current" = "false" ]; then
            halow_log_info "nm-unmanaged: $iface already marked unmanaged by this package, unchanged"
            return 0
        fi
    fi

    prior="$(halow_nm_get_managed "$device_path")" || {
        halow_log_error "nm-unmanaged: could not read $iface's own current Managed state before changing it — refusing to proceed"
        return 1
    }

    if ! halow_own_mark "$owner_key" "$(printf '%s\n%s\n%s' "$prior" "$device_path" "$iface")"; then
        halow_log_error "nm-unmanaged: could not record $iface's own prior Managed state — refusing to proceed"
        return 1
    fi

    if ! halow_nm_set_managed "$device_path" "false"; then
        halow_log_error "nm-unmanaged: could not mark $iface unmanaged (set-and-verify failed) — rolling back the ownership record just made"
        halow_own_clear "$owner_key"
        return 1
    fi

    halow_log_info "nm-unmanaged: $iface ($device_path) marked unmanaged (was: $prior)"
}

# halow_nm_restore_managed <owner_key>
# Restores the interface <owner_key> tracks to its TRUE prior Managed value. Safe to
# call repeatedly, and a safe no-op if nothing is owned under <owner_key> (e.g. this
# interface's own mark_unmanaged call was never reached this run — a partial-startup
# failure must still be able to restore whichever interface(s) it did reach,
# independently).
#
# Three possible outcomes, in order:
#   1. The device still resolves and still shows exactly "false" (as this package left
#      it): restore its true prior value, verify by reading it back, clear ownership
#      only once confirmed.
#   2. The device still resolves but shows something ELSE: some other actor changed it
#      since this package set it — a real possibility for live NetworkManager state,
#      exactly like the firmware search-path mechanism's own global kernel state. That
#      foreign, newer value is NEVER overwritten; ownership is kept, for manual
#      reconciliation, and this is logged loudly.
#   3. The device cannot be resolved/read via D-Bus at all. This is EXPECTED and SAFE
#      when the underlying kernel interface is genuinely gone — most notably, hostapd's
#      own termination destroys the dynamic WDS/AP_VLAN interface it created, and once
#      that happens there is no live Managed state left for anything to be wrong about.
#      But a D-Bus failure for ANY OTHER reason (the bus unreachable, permission denied,
#      NetworkManager itself not running) must NEVER be silently treated this way — this
#      is decided by directly checking the KERNEL's own interface list
#      (halow_kernel_iface_exists), never inferred from the D-Bus failure alone. Only
#      when the kernel interface is also confirmed gone is ownership cleared; otherwise
#      it is kept, exactly as in outcome 2.
halow_nm_restore_managed() {
    local owner_key="$1"
    local marker prior device_path iface rest current
    if ! halow_own_check "$owner_key"; then
        return 0
    fi
    marker="$(halow_own_get "$owner_key")"
    prior="${marker%%$'\n'*}"
    rest="${marker#*$'\n'}"
    device_path="${rest%%$'\n'*}"
    iface="${rest#*$'\n'}"

    current="$(halow_nm_get_managed "$device_path" 2>/dev/null || true)"

    if [ "$current" = "false" ]; then
        if ! halow_nm_set_managed "$device_path" "$prior"; then
            halow_log_error "nm-unmanaged: could not restore $iface ($device_path) to its prior Managed value ($prior) — ownership kept"
            return 1
        fi
        halow_own_clear "$owner_key"
        halow_log_info "nm-unmanaged: $iface ($device_path) restored to Managed=$prior"
        return 0
    fi

    if [ -n "$current" ]; then
        halow_log_error "nm-unmanaged: $iface ($device_path) no longer shows Managed=false (found '$current') — some other actor changed it since this package set it; refusing to overwrite that foreign value. Ownership KEPT; this package's own recorded prior value is '$prior', for manual reconciliation."
        return 1
    fi

    # current is empty: the device could not be resolved/read via D-Bus at all. Decide
    # purely from the kernel's own state, never from the D-Bus failure itself.
    if halow_kernel_iface_exists "$iface"; then
        halow_log_error "nm-unmanaged: could not read $iface's ($device_path) current Managed state via D-Bus, but the kernel interface itself still exists — NOT treated as safely gone. Ownership KEPT for manual review; this package's own recorded prior value is '$prior'."
        return 1
    fi

    halow_log_info "nm-unmanaged: $iface's own kernel interface no longer exists (confirmed directly, not inferred from the D-Bus failure) — nothing live left to restore; clearing ownership."
    halow_own_clear "$owner_key"
}

# halow_nm_mark_unmanaged_if_known <iface> <owner_key> [<resolve_timeout_seconds>]
# For the DYNAMIC WDS/AP_VLAN interface only (the PARENT interface must still be resolvable
# and keeps using halow_nm_mark_unmanaged directly, so a failure there stays fatal).
#
# LIVE FINDING (2026-10-20, live test, evidence: NetworkManager's own journal and
# `ip monitor`): on this HAOS (NetworkManager 1.50.2) NetworkManager NEVER creates a Device for
# the 4-address WDS netdev `wlu1.staN` -- not one NM log line for it during its whole life --
# while the kernel interface exists, comes up, and is later deleted. NetworkManager answers
# GetDeviceByIpIface with org.freedesktop.NetworkManager.UnknownDevice. An interface
# NetworkManager has no Device for is, by construction, not managed by it, so there is nothing to
# mark unmanaged and nothing to restore. Treating that as a hard failure stopped the whole run.
#
# Accepted ONLY when ALL hold: NetworkManager positively answered UnknownDevice on every attempt
# for the full wait (resolve_device returns 3 -- never for a bus/permission/not-running failure,
# which return 1 and stay fatal), AND the KERNEL interface still exists now (an interface that
# vanished is a different problem and is refused). No ownership marker is created (nothing was
# changed, so nothing is owned and rollback has nothing to restore). Every other outcome -- including
# a successful mark -- behaves exactly like halow_nm_mark_unmanaged.
halow_nm_mark_unmanaged_if_known() {
    local iface="$1" owner_key="$2" resolve_timeout="${3:-10}" rc
    if halow_nm_mark_unmanaged "$iface" "$owner_key" "$resolve_timeout"; then
        return 0
    else
        rc=$?
    fi
    if [ "$rc" -ne 3 ]; then
        return "$rc"
    fi
    if halow_kernel_iface_exists "$iface"; then
        halow_log_warning "nm-unmanaged: NetworkManager has no Device for $iface (it answered UnknownDevice for the whole wait) although the kernel interface exists — NetworkManager does not manage this interface, so there is nothing to mark unmanaged; continuing without an ownership record"
        return 0
    fi
    halow_log_error "nm-unmanaged: NetworkManager has no Device for $iface and the kernel interface no longer exists either — refusing to continue"
    return 1
}

# halow_nm_assert_no_device <iface>
# Post-check for the "NetworkManager has no Device for the dynamic WDS interface" outcome of
# halow_nm_mark_unmanaged_if_known: re-asks NetworkManager ONCE, after the routed/NAT backend has
# been applied, and returns 0 only if it still positively answers UnknownDevice. If a Device HAS
# appeared since (NetworkManager started tracking the interface after the wait), or the answer
# cannot be obtained, this returns non-zero so `run` fails closed and rolls back -- NetworkManager
# adopting the interface could otherwise flush this add-on's address and stop DHCP serving.
halow_nm_assert_no_device() {
    local iface="$1" reply path
    reply="$(dbus-send --system --print-reply --dest="$HALOW_NM_BUS_NAME" \
        /org/freedesktop/NetworkManager \
        "${HALOW_NM_BUS_NAME}.GetDeviceByIpIface" "string:${iface}" 2>&1 || true)"
    path="$(printf '%s\n' "$reply" | awk '/^[[:space:]]*object path "\// {print $3}' | tr -d '"')"
    if [ -n "$path" ]; then
        halow_log_error "nm-unmanaged: NetworkManager now has a Device ($path) for $iface, which it did not have when the interface appeared — it may start managing it; refusing to continue"
        return 1
    fi
    case "$reply" in
        *"org.freedesktop.NetworkManager.UnknownDevice"*)
            halow_log_info "nm-unmanaged: re-check: NetworkManager still has no Device for $iface"
            return 0
            ;;
    esac
    halow_log_error "nm-unmanaged: could not re-check whether NetworkManager has a Device for $iface — refusing to continue (fail closed)"
    return 1
}
