#!/usr/bin/env bash
# halow: basic health reporting — a named log provider plus a simple marker file, not
# a new HaLow-specific diagnostics mechanism. No first-class Home Assistant entity,
# sensor, Repair issue, or panel surfaces a HaLow client's own connection attempts or
# failures; that gap is disclosed in README.md, not silently closed here.

# halow_report_healthy <message>
halow_report_healthy() {
    local msg="$1"
    halow_log_info "health: $msg"
    mkdir -p -- "${HALOW_STATE_DIR:?}"
    : > "${HALOW_STATE_DIR}/healthy"
}

# halow_report_unhealthy
halow_report_unhealthy() {
    rm -f -- "${HALOW_STATE_DIR:?}/healthy" 2>/dev/null || true
}

# halow_is_healthy — exit 0 if the marker is currently present (for tests/diagnostics).
halow_is_healthy() {
    [ -e "${HALOW_STATE_DIR:?}/healthy" ]
}
