#!/usr/bin/env bash
# halow: the core/backend contract.
#
# The core (module loading, firmware, hostapd, NetworkManager handling, rollback, the
# station lifecycle) never calls a networking implementation by name. It registers ONE
# backend and talks to it only through the functions below, so a different backend can
# be added without touching the driver, access-point or rollback code.
#
# The shipped backend is `bridge` (backend_bridge.sh): one private internal bridge carries
# every station. The earlier routed/NAT backend (backend_routed_nat.sh) stays registrable
# by name for its contract tests only.
#
# ---------------------------------------------------------------------------------
# THE CONTRACT. A backend named <name> provides these functions (all required):
#
#   <name>_backend_ownership_keys
#       Print the space-separated ownership-marker keys this backend owns. Rollback adds
#       them to its aggregate "anything still owned means INCOMPLETE" check.
#
#   <name>_backend_configure key=value [key=value ...]
#       Hand the backend its own configuration (before attach). Each backend documents
#       its keys; the `bridge` backend refuses unknown or repeated keys.
#       Return 0 on success, 1 if a value is missing, unknown or invalid.
#
#   <name>_backend_attach <kind> <attachment>
#       Establish the backend's service on one ATTACHMENT. <kind> says what the
#       attachment is:
#         bridge             the private internal bridge carrying every station (what
#                            the core passes, once, at start, before any station is
#                            reported)
#         station-interface  a single per-station network interface (the earlier
#                            routed/NAT shape; the `bridge` backend refuses it with 2)
#       A backend that does not support <kind> must refuse with return code 2.
#       Return 0 attached, 1 failed (the backend has already undone what it could),
#       2 unsupported <kind>, 10 the backend serves only one attachment and already has it.
#
#   <name>_backend_station_added <port> <station-id>
#       A station associated and is reachable on <port>, a network interface that belongs to
#       the attachment: for a bridge attachment it is one of the bridge's ports (the
#       parent interface for an ordinary station, or the station's own per-station
#       interface for a four-address station); for a station-interface attachment the
#       first station's <port> IS the attachment. The backend knows its attachment from
#       attach, so only the port is passed. A station already served that is reported
#       again on a different port has MOVED there (an ordinary station whose per-station
#       interface appeared later); it is counted once.
#       Return 0 ONLY when the station really is served. Return 10 when the backend cannot
#       serve it because of an expected limit of its own shape or capacity (non-fatal: the
#       core records the station as not served and carries on). ANY other non-zero return is
#       a hard error: the core records the station as not served, treats the operation as
#       failed (fatal during start-up, a fault state while supervising) and never as success.
#
#   <name>_backend_station_removed <port> <station-id>
#       The station disassociated, or its port went away. Return 0 when the backend has
#       forgotten it. Any non-zero return is a hard error (never ignored by the core).
#
#   <name>_backend_teardown
#       Undo everything this backend did, idempotently, reading only durable state (it
#       runs in a process that shares nothing with the one that attached). Return 0 when
#       nothing needs operator attention, 1 when it positively found a live process or an
#       unresolved identity for which it holds no ownership (a "hard failure" that is not
#       representable as a residual ownership key). A residual owned resource is reported
#       through ownership_keys, not through this return code.
#
#   <name>_backend_health
#       Return 0 when the service is healthy.
#
# For station_added, return code 10 ("limit") is the one non-error, non-zero code; every caller must treat
# it as "not served", never as a fatal failure. (For attach, 10 is a failure to the core: it only
# ever attaches once.)
#
# Optional failure description: after a failing operation a backend may leave a one-line
# reason in HALOW_BACKEND_FAIL_DETAIL and the kind of failure in HALOW_BACKEND_FAIL_KIND
# ("nm" when NetworkManager could not be kept away from an interface, "other"
# otherwise), so the core can name the right error. Both describe the last operation
# only (reset at the start of each); the station lifecycle keeps the first station fault
# in HALOW_ST_FAULT_KIND.
# ---------------------------------------------------------------------------------

HALOW_BACKEND_NAME=""
HALOW_BACKEND_REQUIRED_OPS="ownership_keys configure attach station_added station_removed teardown health"
HALOW_BACKEND_RC_LIMIT=10
HALOW_BACKEND_RC_UNSUPPORTED=2
HALOW_BACKEND_FAIL_DETAIL=""
HALOW_BACKEND_FAIL_KIND=""

# halow_backend_check_contract <name>
# Return 0 if every required function exists for <name>; otherwise print each missing
# one to stderr and return 1. Pure: changes nothing.
halow_backend_check_contract() {
    local name="${1:-}" op missing=0
    if [ -z "$name" ]; then
        echo "backend: no backend name given" >&2
        return 1
    fi
    for op in $HALOW_BACKEND_REQUIRED_OPS; do
        if ! declare -F "${name}_backend_${op}" >/dev/null 2>&1; then
            echo "backend: '${name}' is missing ${name}_backend_${op}" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# halow_backend_register <name>
# Select the one backend this process talks to. Refuses (leaving any previous selection
# untouched) a backend that does not satisfy the whole contract.
halow_backend_register() {
    local name="${1:-}"
    if ! halow_backend_check_contract "$name"; then
        halow_log_error "backend: refusing to register '${name}' — it does not satisfy the backend contract"
        return 1
    fi
    HALOW_BACKEND_NAME="$name"
    return 0
}

# halow_backend_call <op> [args...]
# Dispatch one contract operation to the registered backend. With no backend registered
# the call fails (return 1), including teardown (a rollback that cannot reach a backend
# must report itself incomplete, never clean); only ownership_keys prints nothing.
halow_backend_call() {
    local op="${1:-}"
    shift || true
    if [ -z "$HALOW_BACKEND_NAME" ]; then
        case "$op" in
            teardown) halow_log_error "backend: teardown requested but no backend is registered; the network side cannot be undone from here"; return 1 ;;
            ownership_keys) return 0 ;;
            *) halow_log_error "backend: '${op}' requested but no backend is registered"; return 1 ;;
        esac
    fi
    case " $HALOW_BACKEND_REQUIRED_OPS " in
        *" $op "*) ;;
        *) halow_log_error "backend: '${op}' is not a contract operation"; return 1 ;;
    esac
    "${HALOW_BACKEND_NAME}_backend_${op}" "$@"
}

# halow_backend_ownership_keys — the registered backend's keys, or nothing.
halow_backend_ownership_keys() {
    halow_backend_call ownership_keys
}

# halow_backend_register_default — the backend this build ships with. The only place in
# the core that names a backend; swapping it is a one-line change here.
halow_backend_register_default() {
    halow_backend_register bridge
}
