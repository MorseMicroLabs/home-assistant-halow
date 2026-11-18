#!/usr/bin/env bash
# halow: interface detection and safety checks. Fails safe (never guesses) when zero or
# more than one candidate matches, and never lets an unverified interface name reach
# hostapd or any RF-adjacent operation.

# halow_detect_wds_iface <parent_iface> [<links_text>]
# Detects the single dynamically-created AP_VLAN/WDS station interface
# "<parent_iface>.sta<AID>" after a client associates — its name is assigned at
# association time and must never be assumed in advance. Matching is done with a
# literal bash `case` prefix check plus a digits-only suffix check, never a dynamic
# regex: an earlier version built the match pattern as a string and passed it through
# `awk -v re=...`, which silently consumes the string's own backslash escapes (the
# intended literal "\." becomes a plain "."), so the "separator" would then match ANY
# character — e.g. a name like "<parent>Xsta1" could be wrongly accepted as a WDS
# interface. A `case` pattern has no such escaping step: "." in the prefix is always
# literal. Exit codes: 0 = exactly one match (printed); 1 = zero matches; 2 = more than
# one match (listed in the error log, never guessed at).
halow_detect_wds_iface() {
    local parent="$1" links="${2:-}" prefix name suffix line candidates="" count=0
    prefix="${parent}.sta"
    if [ -z "$links" ]; then
        links="$(ip -o link show 2>/dev/null || true)"
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line#*: }"
        name="${name%%: *}"
        name="${name%%@*}"
        case "$name" in
            "$prefix"*)
                suffix="${name#"$prefix"}"
                case "$suffix" in
                    ''|*[!0-9]*) continue ;;
                esac
                candidates="${candidates}${name}
"
                count=$((count + 1))
                ;;
        esac
    done <<< "$links"
    if [ "$count" -eq 0 ]; then
        halow_log_error "iface-detect: no interface matching literal prefix '${prefix}' + digits found"
        return 1
    elif [ "$count" -gt 1 ]; then
        halow_log_error "iface-detect: multiple candidates matching '${prefix}'+digits, refusing to guess: $(printf '%s ' $candidates)"
        return 2
    fi
    printf '%s' "$candidates"
}

# halow_verify_usb_device_present <expected_vendor_hex> <expected_product_hex> [<usb_devices_root>]
# Proves the intended Wi-Fi HaLow USB device is physically present BEFORE any module is
# loaded and BEFORE any network interface can possibly exist for it — the live
# earlier live record established that the driver's own network interface (e.g. the
# `wlu1` observed live) does not exist until the kernel module binds to the device, so
# a check that requires a net interface cannot run at this point in startup. This scans
# USB bus sysfs directly (`idVendor`/`idProduct` at the top level of each enumerated USB
# device node — not per-interface descriptors, which do not repeat these files),
# independent of any driver or network state. <usb_devices_root> defaults to
# /sys/bus/usb/devices and is overridable for the off-device test harness. Fails safe on
# zero or more than one matching device, exactly like every other detector in this file.
halow_verify_usb_device_present() {
    local expected_vendor="$1" expected_product="$2" usb_root="${3:-/sys/bus/usb/devices}"
    local match_count=0 d actual_vendor actual_product

    if [ ! -d "$usb_root" ]; then
        halow_log_error "iface-safety: USB sysfs root $usb_root not found — cannot verify device presence"
        return 1
    fi

    for d in "$usb_root"/*; do
        [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
        actual_vendor="$(tr -d '[:space:]' < "$d/idVendor" 2>/dev/null)"
        actual_product="$(tr -d '[:space:]' < "$d/idProduct" 2>/dev/null)"
        if [ "$actual_vendor" = "$expected_vendor" ] && [ "$actual_product" = "$expected_product" ]; then
            match_count=$((match_count + 1))
        fi
    done

    if [ "$match_count" -eq 0 ]; then
        halow_log_error "iface-safety: no USB device matching ${expected_vendor}:${expected_product} is physically present"
        return 1
    elif [ "$match_count" -gt 1 ]; then
        halow_log_error "iface-safety: multiple USB devices matching ${expected_vendor}:${expected_product} found; refusing to guess which one to use"
        return 2
    fi

    halow_log_info "iface-safety: confirmed exactly one USB device present matching ${expected_vendor}:${expected_product}"
    return 0
}

# halow_kernel_iface_exists <iface> [<sysfs_root>]
# Plain existence check against the kernel's own interface list only — no USB/driver
# ownership verification (see halow_verify_parent_iface for that). Used by
# nm_unmanaged.sh to distinguish "this interface genuinely no longer exists" (e.g. a
# dynamic WDS/AP_VLAN interface destroyed when hostapd stopped — safe to stop tracking
# it) from any other D-Bus failure (never safe to assume gone just because a D-Bus call
# failed). <sysfs_root> defaults to $HALOW_SYS_CLASS_NET_DIR (itself defaulting to the
# real /sys/class/net) so the off-device test harness can override it without having to
# thread an extra parameter through every caller.
halow_detect_wds_iface_retry() {
    # halow_detect_wds_iface_retry <parent_iface> [max_wait_seconds]
    # `AP-STA-CONNECTED` is logged when the station is authorised; the 4-address WDS netdev
    # is created by the driver/hostapd around association and may appear slightly later. A
    # single look straight after the log line could fail a perfectly working association.
    # Retry (about once a second, default 10 s) ONLY while NO candidate exists (rc 1); an
    # ambiguous result (rc 2, several candidates) is a hard stop and never retried.
    local parent="$1" max="${2:-${HALOW_WDS_DETECT_TIMEOUT:-10}}" waited=0 out rc
    while :; do
        if out="$(halow_detect_wds_iface "$parent")"; then
            printf '%s' "$out"
            return 0
        else
            rc=$?
        fi
        if [ "$rc" -ne 1 ]; then
            return "$rc"
        fi
        if [ "$waited" -ge "$max" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

halow_kernel_iface_exists() {
    local iface="$1" sysfs_root="${2:-${HALOW_SYS_CLASS_NET_DIR:-/sys/class/net}}"
    [ -d "$sysfs_root/$iface" ]
}

# halow_verify_parent_iface <iface> <expected_vendor_hex> <expected_product_hex> [<sysfs_root>]
# Proves, before any hostapd/RF operation, that the configured interface (a customer-
# supplied add-on option — never trust it blindly) actually exists and belongs to the
# intended USB device, by reading its own driver-exposed sysfs attributes — not by
# assuming the name the installer typed is correct. <sysfs_root> defaults to
# /sys/class/net and is overridable for the off-device test harness.
#
# This does NOT itself verify the interface is NetworkManager-unmanaged: that is a
# separate step, performed immediately afterward by nm_unmanaged.sh's own
# halow_nm_mark_unmanaged (reachable via this add-on's `host_dbus: true` option and
# NetworkManager's real D-Bus API), which verifies by reading the property back rather
# than assuming a write succeeded.
halow_verify_parent_iface() {
    local iface="$1" expected_vendor="$2" expected_product="$3" sysfs_root="${4:-/sys/class/net}"
    local dev_dir="$sysfs_root/$iface/device"
    local vendor_file product_file actual_vendor actual_product

    if [ ! -d "$sysfs_root/$iface" ]; then
        halow_log_error "iface-safety: configured interface '$iface' does not exist (checked $sysfs_root/$iface)"
        return 1
    fi

    # USB network devices expose idVendor/idProduct on an ancestor of the net device's
    # own sysfs node; try the immediate device directory first, then one level up (the
    # exact depth depends on the driver's own sysfs topology).
    for candidate in "$dev_dir" "$dev_dir/.." "$dev_dir/../.."; do
        if [ -f "$candidate/idVendor" ] && [ -f "$candidate/idProduct" ]; then
            vendor_file="$candidate/idVendor"
            product_file="$candidate/idProduct"
            break
        fi
    done

    if [ -z "${vendor_file:-}" ]; then
        halow_log_error "iface-safety: could not find idVendor/idProduct for '$iface' under $dev_dir — refusing to proceed without confirming this is the intended device"
        return 1
    fi

    actual_vendor="$(tr -d '[:space:]' < "$vendor_file" 2>/dev/null)"
    actual_product="$(tr -d '[:space:]' < "$product_file" 2>/dev/null)"

    if [ "$actual_vendor" != "$expected_vendor" ] || [ "$actual_product" != "$expected_product" ]; then
        halow_log_error "iface-safety: '$iface' reports USB ID ${actual_vendor}:${actual_product}, expected ${expected_vendor}:${expected_product} — refusing to use this interface (a typo or a different device must never reach hostapd)"
        return 1
    fi

    halow_log_info "iface-safety: '$iface' confirmed as USB ${actual_vendor}:${actual_product}"
    return 0
}
