#!/usr/bin/env bash
# A second backend, for tests only. It satisfies the whole core/backend contract
# (rootfs/usr/lib/halow/backend.sh) without touching any network, firewall, process or
# kernel state: every call is only recorded, so a test can prove exactly which contract
# operations the core issued, with which arguments, in which order.
#
# It is deliberately not a bridge implementation: it exists to show that the contract is a
# real seam (the core drives it unchanged) and to let the station-lifecycle tests run with
# any number of stations. It accepts both attachment kinds.
#
# It checks the call sequence itself and writes a `VIOLATION ...` line to the log when the
# core breaks it: a second attach, a station added before attach, a removal for a station
# that was never reported, or a removal naming a different port from the one the station
# was last reported on. Tests assert there are none.
#
# A station reported again on a different port has moved there (counted once).
#
# Controls (environment, all optional):
#   HALOW_DBL_LOG            file the calls are appended to (required)
#   HALOW_DBL_MAX_STATIONS   serve at most this many stations AT ONCE; more get return 10
#   HALOW_DBL_ATTACH_RC      make `attach` return this code (default 0)
#   HALOW_DBL_TEARDOWN_RC    make `teardown` return this code (default 0)
#   HALOW_DBL_HEALTH_RC      make `health` return this code (default 0)
#   HALOW_DBL_ADD_RC         make `station_added` fail hard with this code (the station is not served)
#   HALOW_DBL_REMOVE_RC      make `station_removed` fail hard with this code (the station is forgotten)
#   HALOW_DBL_FAIL_KIND      the failure kind a failing station operation reports through the
#                            contract (HALOW_BACKEND_FAIL_KIND; default other)
#
# State files next to the log: .attached, .ports (lines "<mac> <port>" for every station
# reported and not removed, served or not), .live (served MACs).

double_backend_ownership_keys() {
    printf '%s' "dbl_state"
}

double_backend_configure() {
    printf 'configure %s\n' "$*" >> "${HALOW_DBL_LOG:?}"
    return 0
}

double_backend_attach() {
    local kind="${1:-}" attachment="${2:-}"
    printf 'attach %s %s\n' "$kind" "$attachment" >> "${HALOW_DBL_LOG:?}"
    case "$kind" in
        station-interface|bridge) ;;
        *) return "$HALOW_BACKEND_RC_UNSUPPORTED" ;;
    esac
    if [ -f "${HALOW_DBL_LOG}.attached" ]; then
        printf 'VIOLATION second attach\n' >> "$HALOW_DBL_LOG"
        return "$HALOW_BACKEND_RC_LIMIT"
    fi
    if [ "${HALOW_DBL_ATTACH_RC:-0}" -eq 0 ]; then
        : > "${HALOW_DBL_LOG}.attached"
    fi
    return "${HALOW_DBL_ATTACH_RC:-0}"
}

_double_drop() { # _double_drop <file> <regex-anchored line>
    local f="$1" line="$2" tmp
    [ -f "$f" ] || return 0
    tmp="$f.tmp"
    grep -v -x -F -- "$line" "$f" > "$tmp" || true
    mv -f "$tmp" "$f"
}

double_backend_station_added() {
    local port="${1:-}" mac="${2:-}" live old
    printf 'station_added %s %s\n' "$port" "$mac" >> "${HALOW_DBL_LOG:?}"
    [ -f "${HALOW_DBL_LOG}.attached" ] || printf 'VIOLATION station_added before attach\n' >> "$HALOW_DBL_LOG"
    touch "${HALOW_DBL_LOG}.live" "${HALOW_DBL_LOG}.ports"
    old="$(awk -v m="$mac" '$1 == m {print $2}' "${HALOW_DBL_LOG}.ports")"
    [ -z "$old" ] || _double_drop "${HALOW_DBL_LOG}.ports" "$mac $old"
    printf '%s %s\n' "$mac" "$port" >> "${HALOW_DBL_LOG}.ports"
    HALOW_BACKEND_FAIL_KIND=""; HALOW_BACKEND_FAIL_DETAIL=""
    if [ "${HALOW_DBL_ADD_RC:-0}" -ne 0 ]; then
        HALOW_BACKEND_FAIL_KIND="${HALOW_DBL_FAIL_KIND:-other}"; HALOW_BACKEND_FAIL_DETAIL="double: add failed"
        _double_drop "${HALOW_DBL_LOG}.live" "$mac"
        return "$HALOW_DBL_ADD_RC"
    fi
    if grep -q -F -x -- "$mac" "${HALOW_DBL_LOG}.live"; then
        return 0   # idempotent (or a move to a new port): already served
    fi
    if [ -n "${HALOW_DBL_MAX_STATIONS:-}" ]; then
        live="$(grep -c . "${HALOW_DBL_LOG}.live" || true)"
        if [ "${live:-0}" -ge "$HALOW_DBL_MAX_STATIONS" ]; then
            return "$HALOW_BACKEND_RC_LIMIT"
        fi
    fi
    printf '%s\n' "$mac" >> "${HALOW_DBL_LOG}.live"
    return 0
}

double_backend_station_removed() {
    local port="${1:-}" mac="${2:-}" old
    printf 'station_removed %s %s\n' "$port" "$mac" >> "${HALOW_DBL_LOG:?}"
    touch "${HALOW_DBL_LOG}.live" "${HALOW_DBL_LOG}.ports"
    old="$(awk -v m="$mac" '$1 == m {print $2}' "${HALOW_DBL_LOG}.ports")"
    if [ -z "$old" ]; then
        printf 'VIOLATION station_removed for a station never reported: %s\n' "$mac" >> "$HALOW_DBL_LOG"
    elif [ "$old" != "$port" ]; then
        printf 'VIOLATION station_removed %s on %s but it was reported on %s\n' "$mac" "$port" "$old" >> "$HALOW_DBL_LOG"
    fi
    [ -z "$old" ] || _double_drop "${HALOW_DBL_LOG}.ports" "$mac $old"
    _double_drop "${HALOW_DBL_LOG}.live" "$mac"
    return "${HALOW_DBL_REMOVE_RC:-0}"
}

double_backend_teardown() {
    printf 'teardown\n' >> "${HALOW_DBL_LOG:?}"
    rm -f "${HALOW_DBL_LOG}.attached" "${HALOW_DBL_LOG}.live" "${HALOW_DBL_LOG}.ports"
    return "${HALOW_DBL_TEARDOWN_RC:-0}"
}

double_backend_health() {
    printf 'health\n' >> "${HALOW_DBL_LOG:?}"
    return "${HALOW_DBL_HEALTH_RC:-0}"
}
