#!/usr/bin/env bash
# halow: the one list of libraries the manager service needs.
#
# Both the manager's `run` and its separate `finish` process call halow_source_all_libs,
# so the two can never source different sets of libraries (a missing library in only one
# of them turns a call into "command not found", which an `if` reads as an ordinary
# failure and can silently take the wrong branch).
#
# Defines functions and constants only; sourcing this file runs nothing.

# The order matters only in that constants and common come first (every other library
# uses their values and logging). Every name below is a file <name>.sh in the library
# directory.
HALOW_LIBS_REQUIRED="constants common checksum ownership validate firmware nm_unmanaged iface_detect module_load hostapd_config backend state errors radio guard adapter bridge ipv6 backend_bridge dnsmasq stations firewall allowlist uplink bootid reconcile lifecycle options rollback failure_record manager"
# Carried libraries some of the above may still use; sourced when present.
HALOW_LIBS_OPTIONAL="network_backend backend_routed_nat health"

# halow_libs_dir — the directory this file was sourced from.
halow_libs_dir() {
    local here="${BASH_SOURCE[0]}"
    printf '%s' "$(cd "$(dirname -- "$here")" 2>/dev/null && pwd)"
}

# halow_source_all_libs [<dir>]
# Sources every required library, then every optional one that exists, from <dir>
# (default: the directory of this file). Returns 0 when every required library was found
# and sourced; 1 otherwise, with HALOW_LIBS_MISSING listing the missing ones (every
# library that does exist is still sourced, so the caller can report the problem).
halow_source_all_libs() {
    local dir="${1:-}" lib
    [ -n "$dir" ] || dir="$(halow_libs_dir)"
    HALOW_LIBS_MISSING=""
    for lib in $HALOW_LIBS_REQUIRED; do
        if [ -f "$dir/${lib}.sh" ]; then
            # shellcheck source=/dev/null
            . "$dir/${lib}.sh"
        else
            HALOW_LIBS_MISSING="${HALOW_LIBS_MISSING}${lib} "
        fi
    done
    for lib in $HALOW_LIBS_OPTIONAL; do
        if [ -f "$dir/${lib}.sh" ]; then
            # shellcheck source=/dev/null
            . "$dir/${lib}.sh"
        fi
    done
    HALOW_LIBS_MISSING="${HALOW_LIBS_MISSING% }"
    [ -z "$HALOW_LIBS_MISSING" ]
}
