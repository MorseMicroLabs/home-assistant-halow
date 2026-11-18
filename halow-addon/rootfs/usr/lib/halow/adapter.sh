#!/usr/bin/env bash
# halow: detection of the one supported Wi-Fi HaLow USB adapter and derivation of its network
# interface. Read-only: scans the USB device tree, never changes anything.
#
# The adapter is recognised only by its USB identity (HALOW_ADAPTER_VENDOR_ID and
# HALOW_ADAPTER_PRODUCT_ID from constants.sh). A device with the same vendor id but another
# product id is unrecognised and, when it is the only candidate, makes the check fail closed.
# The network interface is found inside the recognised device's own sysfs subtree
# (<device>/**/net/<ifname>) after the driver has bound: never by guessing a name and never
# from a configuration option. The interface name is printed, never stored.
#
# Overridable for tests: HALOW_SYS_USB_DIR (default /sys/bus/usb/devices); halow_adapter_sleep
# (a function tests replace). External commands are called by name (find).
#
# State set by halow_adapter_scan:
#   HALOW_ADAPTER_COUNT               recognised devices
#   HALOW_ADAPTER_UNRECOGNISED_COUNT  devices with the adapter's vendor id and another product
#   HALOW_ADAPTER_SYSFS               canonical sysfs path of the single recognised device, or empty
#   HALOW_ADAPTER_IDENTITY            "<busnum>:<devnum>" of that device when readable, or empty

_halow_adapter_usb_dir() { printf '%s' "${HALOW_SYS_USB_DIR:-/sys/bus/usb/devices}"; }

_halow_adapter_log() { # _halow_adapter_log <info|warning|error> <message>
    local level="$1"; shift
    if declare -F "halow_log_${level}" >/dev/null 2>&1; then
        "halow_log_${level}" "$*"
    else
        printf '[halow] %s: %s\n' "$level" "$*" >&2
    fi
}

# halow_adapter_sleep <seconds>: the only wait used by this module (tests replace it).
halow_adapter_sleep() {
    sleep "$1"
}

# _halow_adapter_read_attr <file>: prints the attribute without blanks, lower case; 1 if unreadable.
_halow_adapter_read_attr() {
    local v
    [ -f "$1" ] || return 1
    if v="$(<"$1")"; then :; else return 1; fi
    v="${v//[[:space:]]/}"
    printf '%s' "${v,,}"
}

# _halow_adapter_canon <path>: prints the physical path (symlinks resolved), builtins only.
_halow_adapter_canon() {
    (cd -P -- "$1" 2>/dev/null && pwd -P)
}

_halow_adapter_identity_of() { # <device dir>: prints busnum:devnum or empty
    local b d
    if b="$(_halow_adapter_read_attr "$1/busnum")" && d="$(_halow_adapter_read_attr "$1/devnum")"; then
        printf '%s:%s' "$b" "$d"
    fi
}

# halow_adapter_scan: counts recognised and unrecognised devices. 0 on a completed scan; 1 if the
# USB device tree cannot be read (counts then stay 0).
halow_adapter_scan() {
    local root d vendor product want_vendor want_product canon
    HALOW_ADAPTER_COUNT=0
    HALOW_ADAPTER_UNRECOGNISED_COUNT=0
    HALOW_ADAPTER_SYSFS=""
    HALOW_ADAPTER_IDENTITY=""
    want_vendor="${HALOW_ADAPTER_VENDOR_ID:-325b}"; want_vendor="${want_vendor,,}"
    want_product="${HALOW_ADAPTER_PRODUCT_ID:-8100}"; want_product="${want_product,,}"
    root="$(_halow_adapter_usb_dir)"
    if [ ! -d "$root" ]; then
        _halow_adapter_log error "adapter: USB device tree $root not found"
        return 1
    fi
    for d in "$root"/*; do
        [ -e "$d/idVendor" ] || continue
        if ! vendor="$(_halow_adapter_read_attr "$d/idVendor")"; then continue; fi
        [ "$vendor" = "$want_vendor" ] || continue
        if product="$(_halow_adapter_read_attr "$d/idProduct")" && [ "$product" = "$want_product" ]; then
            HALOW_ADAPTER_COUNT=$((HALOW_ADAPTER_COUNT + 1))
            if canon="$(_halow_adapter_canon "$d")"; then :; else canon="$d"; fi
            HALOW_ADAPTER_SYSFS="$canon"
        else
            HALOW_ADAPTER_UNRECOGNISED_COUNT=$((HALOW_ADAPTER_UNRECOGNISED_COUNT + 1))
        fi
    done
    if [ "$HALOW_ADAPTER_COUNT" -eq 1 ]; then
        HALOW_ADAPTER_IDENTITY="$(_halow_adapter_identity_of "$HALOW_ADAPTER_SYSFS")"
    else
        HALOW_ADAPTER_SYSFS=""
    fi
    return 0
}

# halow_adapter_check: 0 exactly one recognised; 2 none; 3 several; 4 only an unrecognised device.
halow_adapter_check() {
    if ! halow_adapter_scan; then
        return 2
    fi
    if [ "$HALOW_ADAPTER_COUNT" -eq 1 ]; then
        if [ "$HALOW_ADAPTER_UNRECOGNISED_COUNT" -gt 0 ]; then
            _halow_adapter_log warning "adapter: ignoring $HALOW_ADAPTER_UNRECOGNISED_COUNT unrecognised device(s) with the adapter's vendor id"
        fi
        _halow_adapter_log info "adapter: exactly one supported adapter found"
        return 0
    fi
    if [ "$HALOW_ADAPTER_COUNT" -gt 1 ]; then
        _halow_adapter_log error "adapter: $HALOW_ADAPTER_COUNT supported adapters found; exactly one is supported"
        return 3
    fi
    if [ "$HALOW_ADAPTER_UNRECOGNISED_COUNT" -gt 0 ]; then
        _halow_adapter_log error "adapter: only an unrecognised device with the adapter's vendor id is present; refusing to use it"
        return 4
    fi
    _halow_adapter_log error "adapter: no supported adapter found"
    return 2
}

# halow_adapter_netdev: prints the adapter's network interface name. 1 if it has none yet (or
# no single adapter is known); 2 if several unrelated interfaces exist in its subtree.
halow_adapter_netdev() {
    local dev out netdir n name names=" " count=0 result="" base
    dev="${HALOW_ADAPTER_SYSFS:-}"
    if [ -z "$dev" ]; then
        if ! halow_adapter_scan || [ "$HALOW_ADAPTER_COUNT" -ne 1 ]; then
            return 1
        fi
        dev="$HALOW_ADAPTER_SYSFS"
    fi
    [ -d "$dev" ] || return 1
    if out="$(find "$dev" -mindepth 1 -maxdepth 8 -type d -name net 2>/dev/null)"; then
        :
    else
        return 1
    fi
    while IFS= read -r netdir; do
        [ -n "$netdir" ] || continue
        for n in "$netdir"/*; do
            [ -d "$n" ] || continue
            name="${n##*/}"
            [[ "$name" =~ ^[A-Za-z0-9._@-]+$ ]] || continue
            case "$names" in *" $name "*) continue ;; esac
            names="${names}${name} "
        done
    done <<< "$out"
    # A per-station interface "<parent>.sta<N>" of a parent that is also present is not the
    # adapter's own interface.
    for name in $names; do
        case "$name" in
            *.sta*)
                base="${name%.sta*}"
                if [[ "${name#"$base".sta}" =~ ^[0-9]+$ ]]; then
                    case "$names" in *" $base "*) continue ;; esac
                fi
                ;;
        esac
        count=$((count + 1))
        result="$name"
    done
    if [ "$count" -eq 0 ]; then
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        _halow_adapter_log error "adapter: several network interfaces under the adapter; refusing to guess"
        return 2
    fi
    printf '%s\n' "$result"
}

# halow_adapter_netdev_wait <timeout_s>: polls halow_adapter_netdev about once a second until an
# interface appears (0, printed), the timeout passes (1), the adapter disappears (1) or the
# result is ambiguous (2).
halow_adapter_netdev_wait() {
    local timeout="${1:-}" waited=0 out rc
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        _halow_adapter_log error "adapter: invalid wait timeout"
        return 1
    fi
    while :; do
        if out="$(halow_adapter_netdev)"; then
            printf '%s\n' "$out"
            return 0
        else
            rc=$?
        fi
        if [ "$rc" -ne 1 ]; then
            return "$rc"
        fi
        if ! halow_adapter_present; then
            _halow_adapter_log error "adapter: the adapter disappeared while waiting for its interface"
            return 1
        fi
        if [ "$waited" -ge "$timeout" ]; then
            _halow_adapter_log error "adapter: no network interface appeared within ${timeout}s"
            return 1
        fi
        halow_adapter_sleep 1
        waited=$((waited + 1))
    done
}

# halow_adapter_present: 0 if the device found by the last scan is still there with the same
# USB identity (path, vendor/product and bus/device number); 1 otherwise.
halow_adapter_present() {
    local dev vendor product want_vendor want_product
    dev="${HALOW_ADAPTER_SYSFS:-}"
    [ -n "$dev" ] || return 1
    [ -d "$dev" ] || return 1
    want_vendor="${HALOW_ADAPTER_VENDOR_ID:-325b}"; want_vendor="${want_vendor,,}"
    want_product="${HALOW_ADAPTER_PRODUCT_ID:-8100}"; want_product="${want_product,,}"
    if ! vendor="$(_halow_adapter_read_attr "$dev/idVendor")"; then return 1; fi
    if ! product="$(_halow_adapter_read_attr "$dev/idProduct")"; then return 1; fi
    [ "$vendor" = "$want_vendor" ] && [ "$product" = "$want_product" ] || return 1
    if [ -n "${HALOW_ADAPTER_IDENTITY:-}" ] && [ "$(_halow_adapter_identity_of "$dev")" != "$HALOW_ADAPTER_IDENTITY" ]; then
        return 1
    fi
    return 0
}
