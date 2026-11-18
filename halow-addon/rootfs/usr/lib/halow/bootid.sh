#!/usr/bin/env bash
# halow: host boot identity.
#
# Nearly every host change this add-on makes is runtime-only (loaded modules, the
# firmware search path, firewall chains, the bridge, NetworkManager flags) and is reset
# by a host reboot, while the ownership markers live on the persistent /data volume. The
# kernel's per-boot random id tells a start whether the host rebooted since the markers
# were written: if it did, runtime-only markers are stale and are cleared after the host
# has been checked (see reconcile.sh).
#
# Defines functions and constants only.

: "${HALOW_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"

# halow_boot_id_record_file — where the boot id of the last start is kept.
halow_boot_id_record_file() {
    printf '%s/boot_id' "${HALOW_STATE_DIR:?}"
}

# halow_boot_id_current — prints the host's current boot id; 1 if it cannot be read.
halow_boot_id_current() {
    local id
    if ! id="$(cat -- "$HALOW_BOOT_ID_FILE" 2>/dev/null)"; then
        return 1
    fi
    id="${id//[[:space:]]/}"
    case "$id" in
        ''|*[!0-9a-fA-F-]*) return 1 ;;
    esac
    printf '%s' "$id"
}

# halow_boot_id_recorded — prints the boot id recorded at the last start; 1 if none.
halow_boot_id_recorded() {
    local id f
    f="$(halow_boot_id_record_file)"
    [ -f "$f" ] || return 1
    id="$(cat -- "$f" 2>/dev/null || true)"
    id="${id//[[:space:]]/}"
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}

# halow_boot_id_changed
#   0  the host rebooted since the recorded start (the ids differ)
#   1  same boot as the recorded start
#   2  nothing recorded yet (first start, or the persistent data was lost)
#   3  the current boot id cannot be read (nothing can be concluded)
halow_boot_id_changed() {
    local cur rec
    if ! cur="$(halow_boot_id_current)"; then
        return 3
    fi
    if ! rec="$(halow_boot_id_recorded)"; then
        return 2
    fi
    if [ "$cur" = "$rec" ]; then
        return 1
    fi
    return 0
}

# halow_boot_id_record — records the current boot id (atomic replace). 1 on failure.
halow_boot_id_record() {
    local cur f
    if ! cur="$(halow_boot_id_current)"; then
        return 1
    fi
    f="$(halow_boot_id_record_file)"
    mkdir -p -- "${HALOW_STATE_DIR:?}" 2>/dev/null || return 1
    if ! printf '%s\n' "$cur" > "${f}.tmp.$$" 2>/dev/null; then
        rm -f -- "${f}.tmp.$$"
        return 1
    fi
    if ! mv -f -- "${f}.tmp.$$" "$f" 2>/dev/null; then
        rm -f -- "${f}.tmp.$$"
        return 1
    fi
    return 0
}
