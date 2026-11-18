#!/usr/bin/env bash
# halow: IPv6 off on the add-on's own interfaces.
#
# HaLow clients get no IPv6 connectivity at all. The primary control is the kernel's
# per-interface switch net.ipv6.conf.<iface>.disable_ipv6 on the parent radio interface,
# the private bridge and every per-station interface: with it set the interface has no
# IPv6 address (not even link-local) and ignores router advertisements, so a client
# cannot give the host an address or a route. The IPv6 firewall chains (firewall.sh) are
# the second layer.
#
# Rules this file keeps:
#   - the interface's current value is recorded in the ownership marker ipv6_<iface>
#     BEFORE 1 is written, and the first recorded value is never overwritten by a later
#     call (so a repeated disable cannot record our own 1 as the original);
#   - every write is read back; nothing is reported done that the host does not show;
#   - a marker is cleared only after the recorded value is confirmed back on the host (an
#     interface that no longer exists took its setting with it and counts as restored);
#   - nothing else under /proc/sys is ever written (in particular not the forwarding
#     switches).
#
# How the write is made possible (proven off-device; not yet validated on the target
# device). The add-on container is not privileged, so Docker mounts /proc/sys read-only for
# it and every plain write to a disable_ipv6 file fails with EROFS. Each write is therefore
# made inside a short bracket on the ONE file concerned:
#     mount -o bind F F                 (a container-local bind mount of that exact file)
#     mount -o remount,bind,rw F        (flips only that bind mount to read-write)
#     write, then umount F              (the temporary mount is removed again at once)
# The bind mount lives in the container's own mount namespace; a bind remount changes only
# that mount's flag, never the proc superblock, /proc/sys, any other file or interface. The
# files of "all" and "default" are refused by name before any mount call; no other sysctl
# is ever touched. The bracket is crash-aware and idempotent:
#   - a bracket record ipv6br_<iface> (content: ro or rw, whether a plain write was refused
#     before the bracket) is written BEFORE the first mount; it is cleared only after the
#     cleanup is verified: the mount no longer appears in /proc/self/mountinfo for that exact
#     path, and (when a plain write was refused before) a write is refused again;
#   - before every bracket, and at every restore, rollback and reconcile (which runs
#     rollback), leftovers are looked for in the mount table itself, never only in the
#     record: every mount stacked on a disable_ipv6 path is made read-only and unmounted
#     until none is listed;
#   - a cleanup that cannot be verified reports INCOMPLETE and keeps the record, so rollback
#     reports residual ownership instead of success.
# A write that is refused still returns 1 and the caller decides (the firewall chains
# still drop IPv6 on the bridge). A temporary mount that is held or cannot be confirmed
# removed returns 2 from halow_ipv6_disable, which is stronger: the caller fails closed and
# never falls back to the firewall alone, because a writable mount may be left.
#
# The /proc/sys root is HALOW_PROC_SYS_DIR (default /proc/sys) and the mount table is
# HALOW_PROC_MOUNTINFO (default /proc/self/mountinfo), both redirectable for tests.
# Defines functions only; nothing runs when sourced. Depends on common.sh, ownership.sh
# and validate.sh.

# _halow_ipv6_conf_dir — the per-interface IPv6 configuration directory.
_halow_ipv6_conf_dir() {
    printf '%s/net/ipv6/conf' "${HALOW_PROC_SYS_DIR:-/proc/sys}"
}

# _halow_ipv6_read <file> — prints the first line of <file>; 1 if it cannot be read or
# is not 0 or 1.
_halow_ipv6_read() {
    local file="$1" value=""
    [ -r "$file" ] || return 1
    if IFS= read -r value < "$file"; then :; else
        [ -n "$value" ] || return 1
    fi
    case "$value" in
        0|1) printf '%s' "$value"; return 0 ;;
    esac
    return 1
}

# _halow_ipv6_write <file> <value> — 0 if the write itself succeeded.
_halow_ipv6_write() {
    local file="$1" value="$2"
    if { printf '%s\n' "$value" > "$file"; } 2>/dev/null; then
        return 0
    fi
    return 1
}

# _halow_ipv6_iface_ok <iface> — 0 for a name this file may ever touch. "all" and "default"
# (the host-wide entries) and the path components "." and ".." are refused here, by name,
# before any mount call is made; the rest must be a valid interface name.
_halow_ipv6_iface_ok() {
    local iface="${1:-}"
    case "$iface" in
        all|default)
            halow_log_error "ipv6: refusing '$iface': the host-wide IPv6 entries are never changed"
            return 1 ;;
        .|..)
            halow_log_error "ipv6: refusing '$iface': not an interface name"
            return 1 ;;
    esac
    halow_validate_iface_name "$iface"
}

# _halow_ipv6_mountinfo — the mount table that is consulted.
_halow_ipv6_mountinfo() {
    printf '%s' "${HALOW_PROC_MOUNTINFO:-/proc/self/mountinfo}"
}

# _halow_ipv6_mount_count <file> — prints how many mount table entries have exactly <file>
# as their mount point; 1 if the table cannot be read (callers fail closed).
_halow_ipv6_mount_count() {
    local mi n
    mi="$(_halow_ipv6_mountinfo)"
    [ -r "$mi" ] || return 1
    if n="$(awk -v p="$1" '$5 == p { c++ } END { print c + 0 }' "$mi" 2>/dev/null)"; then :; else return 1; fi
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$n"
}

# _halow_ipv6_mounted_ifaces — prints the interface of every mount table entry whose mount
# point is <conf dir>/<name>/disable_ipv6, one per line (all and default included, so they
# can be reported). 1 if the table cannot be read.
_halow_ipv6_mounted_ifaces() {
    local mi conf p rest
    mi="$(_halow_ipv6_mountinfo)"
    [ -r "$mi" ] || return 1
    conf="$(_halow_ipv6_conf_dir)"
    while IFS= read -r p; do
        case "$p" in "$conf"/*/disable_ipv6) ;; *) continue ;; esac
        rest="${p#"$conf"/}"
        rest="${rest%/disable_ipv6}"
        case "$rest" in ''|*/*) continue ;; esac
        printf '%s\n' "$rest"
    done < <(awk '{ print $5 }' "$mi" 2>/dev/null)
    return 0
}

# _halow_ipv6_unmount_all <file> — removes every mount stacked on exactly <file> (each is
# made read-only first, best effort, then unmounted) until none is listed. 0 only when the
# mount table, read afterwards, shows none; 1 otherwise (including an unreadable table).
_halow_ipv6_unmount_all() {
    local file="$1" n i=0
    while :; do
        n="$(_halow_ipv6_mount_count "$file")" || return 1
        [ "$n" -gt 0 ] || return 0
        [ "$i" -lt 8 ] || return 1
        i=$((i + 1))
        mount -o remount,bind,ro "$file" 2>/dev/null || true
        umount "$file" 2>/dev/null || true
    done
}

# _halow_ipv6_refused <file> — 0 when a write to <file> is refused (or the file is gone); 1
# when a write is accepted or cannot be decided. The test write puts back the value the file
# already holds, so it never changes anything.
_halow_ipv6_refused() {
    local file="$1" cur
    [ -e "$file" ] || return 0
    if cur="$(_halow_ipv6_read "$file")"; then :; else return 1; fi
    if _halow_ipv6_write "$file" "$cur"; then
        return 1
    fi
    return 0
}

# _halow_ipv6_close <iface> <ro|rw> — verifies the end of a bracket on <iface> and only then
# clears its record: no mount is listed for the exact path any more and, when a plain write
# was refused before the bracket (state ro), a write is refused again. 0 when verified; 1
# otherwise (INCOMPLETE; the record is kept).
_halow_ipv6_close() {
    local iface="$1" state="${2:-ro}" key="ipv6br_$1" file
    file="$(_halow_ipv6_conf_dir)/${iface}/disable_ipv6"
    if ! _halow_ipv6_unmount_all "$file"; then
        halow_log_error "ipv6: INCOMPLETE: the temporary mount on the IPv6 switch of $iface could not be confirmed removed (still listed, or the mount table cannot be read); the bracket record is kept"
        return 1
    fi
    if [ "$state" != "rw" ] && ! _halow_ipv6_refused "$file"; then
        halow_log_error "ipv6: INCOMPLETE: the IPv6 switch of $iface still accepts a write after its temporary mount was removed; the bracket record is kept"
        return 1
    fi
    halow_own_clear "$key"
    if halow_own_check "$key"; then
        halow_log_error "ipv6: INCOMPLETE: the bracket record of $iface could not be cleared"
        return 1
    fi
    return 0
}

# _halow_ipv6_scrub <iface> — finds the leftovers of an interrupted bracket on <iface> (a
# bracket record, or any mount listed on its exact path, the mount table being the evidence)
# and cleans them up, verified. 0 when nothing is left (or nothing was there); 1 when the
# cleanup could not be verified.
_halow_ipv6_scrub() {
    local iface="$1" key="ipv6br_$1" file n present=0 state=ro
    file="$(_halow_ipv6_conf_dir)/${iface}/disable_ipv6"
    if halow_own_check "$key"; then
        present=1
        if [ "$(halow_own_get "$key")" = "rw" ]; then state=rw; fi
    fi
    if ! n="$(_halow_ipv6_mount_count "$file")"; then
        halow_log_error "ipv6: INCOMPLETE: the mount table cannot be read; a leftover temporary mount on $iface cannot be excluded"
        return 1
    fi
    [ "$n" -eq 0 ] || present=1
    [ "$present" -eq 1 ] || return 0
    halow_log_warning "ipv6: an interrupted temporary mount of the IPv6 switch of $iface is being cleaned up"
    # A stale mount nobody recorded gets its record first, so that a cleanup that cannot be
    # verified leaves a record behind (rollback lists it) instead of vanishing.
    if ! halow_own_check "$key" && ! halow_own_mark "$key" "$state"; then
        halow_log_error "ipv6: the leftover temporary mount on $iface could not be recorded"
    fi
    _halow_ipv6_close "$iface" "$state"
}

# _halow_ipv6_bracket_marked — prints the interface of every ipv6br_* record, one per line.
_halow_ipv6_bracket_marked() {
    local dir="${HALOW_STATE_DIR:?}/owns" f name
    [ -d "$dir" ] || return 0
    for f in "$dir"/ipv6br_*; do
        [ -e "$f" ] || continue
        name="${f##*/}"
        case "$name" in *.tmp.*) continue ;; esac
        printf '%s\n' "${name#ipv6br_}"
    done
    return 0
}

# halow_ipv6_scrub_all — cleans up every interrupted bracket: the interfaces named by a
# bracket record and every interface the mount table shows a temporary mount on. A mount
# on the "all" or "default" entry is none of this add-on's making and is reported, not
# touched. 0 when everything is verified clean; 1 otherwise.
halow_ipv6_scrub_all() {
    local rc=0 iface mi
    local -a list=()
    mi="$(_halow_ipv6_mountinfo)"
    if [ ! -r "$mi" ]; then
        halow_log_error "ipv6: INCOMPLETE: the mount table cannot be read; leftover temporary mounts cannot be excluded"
        return 1
    fi
    mapfile -t list < <({ _halow_ipv6_mounted_ifaces; _halow_ipv6_bracket_marked; } | LC_ALL=C sort -u)
    for iface in "${list[@]}"; do
        [ -n "$iface" ] || continue
        case "$iface" in
            all|default)
                halow_log_warning "ipv6: a mount is listed on the host-wide '$iface' IPv6 switch; it is not this add-on's and is left alone"
                if halow_own_check "ipv6br_${iface}"; then
                    halow_log_error "ipv6: INCOMPLETE: a bracket record names the host-wide '$iface' entry, which this add-on never mounts; kept for manual review"
                    rc=1
                fi
                continue ;;
        esac
        if ! _halow_ipv6_iface_ok "$iface"; then
            halow_log_error "ipv6: INCOMPLETE: a bracket record or mount names an invalid interface; kept for manual review"
            rc=1
            continue
        fi
        _halow_ipv6_scrub "$iface" || rc=1
    done
    return "$rc"
}

# _halow_ipv6_set <iface> <0|1> — writes the value inside a bracket (see the header) and
# verifies the cleanup. 0 when the write was made and the bracket is verified closed; 1
# when the change failed (bracket verified closed, nothing left behind); 2 when the cleanup
# could not be verified (INCOMPLETE, the bracket record is kept). Never reads the value
# back; the caller does that, after the cleanup.
_halow_ipv6_set() {
    local iface="${1:-}" value="${2:-}" file cur state rc=0 n
    _halow_ipv6_iface_ok "$iface" || return 1
    case "$value" in 0|1) ;; *) return 1 ;; esac
    file="$(_halow_ipv6_conf_dir)/${iface}/disable_ipv6"
    # Idempotent start: leftovers of an earlier interrupted bracket go first.
    _halow_ipv6_scrub "$iface" || return 2
    if cur="$(_halow_ipv6_read "$file")"; then :; else
        halow_log_error "ipv6: cannot read the IPv6 switch of $iface; not changing it"
        return 1
    fi
    if ! _halow_ipv6_mount_count "$file" >/dev/null; then
        halow_log_error "ipv6: the mount table cannot be read; not changing the IPv6 switch of $iface"
        return 1
    fi
    # Whether a plain write is refused now decides what the cleanup must show afterwards.
    if _halow_ipv6_write "$file" "$cur"; then state=rw; else state=ro; fi
    # Recorded BEFORE the first mount.
    if ! halow_own_mark "ipv6br_${iface}" "$state"; then
        halow_log_error "ipv6: could not record the temporary mount of $iface; not changing it"
        return 1
    fi
    if ! mount -o bind "$file" "$file" 2>/dev/null; then
        halow_log_error "ipv6: the temporary bind mount on the IPv6 switch of $iface was refused"
        rc=1
    elif ! n="$(_halow_ipv6_mount_count "$file")" || [ "$n" != "1" ]; then
        halow_log_error "ipv6: the temporary mount on the IPv6 switch of $iface is not listed exactly once"
        rc=1
    elif ! mount -o remount,bind,rw "$file" 2>/dev/null; then
        halow_log_error "ipv6: the read-write remount of the temporary mount on $iface was refused"
        rc=1
    elif ! _halow_ipv6_write "$file" "$value"; then
        halow_log_error "ipv6: the write to the IPv6 switch of $iface was refused"
        rc=1
    fi
    if ! _halow_ipv6_close "$iface" "$state"; then
        return 2
    fi
    return "$rc"
}

# halow_ipv6_disable <iface>
# Records the current disable_ipv6 value of <iface> (marker ipv6_<iface>, written first,
# kept if already held), writes 1 and reads it back. 0 when the host shows 1; 1 when the
# value cannot be read, recorded, written or verified (the marker stays so a restore puts
# the recorded value back); 2 (INCOMPLETE, stronger than 1) when a temporary writable mount
# on the interface's switch is held or could not be confirmed removed: callers must not
# fall back to the firewall alone then, and 0 is never answered while one is left.
halow_ipv6_disable() {
    local iface="${1:-}" file cur key orig set_rc
    _halow_ipv6_iface_ok "$iface" || return 1
    # A held bracket record or a listed mount is cleaned up (verified) before anything else,
    # so a value that is already 1 can never hide a writable mount.
    if ! _halow_ipv6_scrub "$iface"; then
        # A held record or a readable table that still lists the mount: INCOMPLETE. Only an
        # unreadable table with no record at all cannot be decided; nothing of ours is known
        # to be left (a bracket always records before it mounts), so that is the plain 1.
        if halow_own_check "ipv6br_${iface}" || halow_ipv6_mount_table_readable; then
            halow_log_error "ipv6: INCOMPLETE: a temporary writable mount on the IPv6 switch of $iface could not be confirmed removed"
            return 2
        fi
        halow_log_error "ipv6: the mount table cannot be read; IPv6 on $iface is not verified off"
        return 1
    fi
    key="ipv6_${iface}"
    file="$(_halow_ipv6_conf_dir)/${iface}/disable_ipv6"
    if cur="$(_halow_ipv6_read "$file")"; then :; else
        halow_log_error "ipv6: cannot read disable_ipv6 of $iface; IPv6 on it is not verified off"
        return 1
    fi
    if halow_own_check "$key"; then
        orig="$(halow_own_get "$key")"
        case "$orig" in
            0|1) ;;
            *)
                halow_log_error "ipv6: the record of the original IPv6 setting of $iface is malformed; not changing it"
                return 1 ;;
        esac
    else
        if ! halow_own_mark "$key" "$cur"; then
            halow_log_error "ipv6: could not record the IPv6 setting of $iface; not changing it"
            return 1
        fi
    fi
    if [ "$cur" != "1" ]; then
        set_rc=0
        _halow_ipv6_set "$iface" 1 || set_rc=$?
        if [ "$set_rc" -eq 2 ]; then
            halow_log_error "ipv6: could not turn IPv6 off on $iface cleanly: the temporary write access is not confirmed removed (INCOMPLETE; see the preceding line)"
            return 2
        elif [ "$set_rc" -ne 0 ]; then
            halow_log_error "ipv6: could not turn IPv6 off on $iface (the write was refused)"
            return 1
        fi
        if cur="$(_halow_ipv6_read "$file")"; then :; else cur=""; fi
        if [ "$cur" != "1" ]; then
            halow_log_error "ipv6: IPv6 on $iface reads '$cur' after turning it off"
            return 1
        fi
    fi
    halow_log_info "ipv6: IPv6 is off on $iface"
    return 0
}

# _halow_ipv6_restore_one <iface> — 0 when the recorded value is confirmed on the host (or
# the interface is gone) and the marker was cleared; 1 otherwise (marker kept).
_halow_ipv6_restore_one() {
    local iface="$1" key="ipv6_$1" orig file dir cur set_rc
    orig="$(halow_own_get "$key")"
    case "$orig" in
        0|1) ;;
        *)
            halow_log_error "ipv6: the record of the original IPv6 setting of $iface is malformed; ownership kept for manual review"
            return 1 ;;
    esac
    if ! _halow_ipv6_iface_ok "$iface"; then
        halow_log_error "ipv6: the IPv6 record names an invalid interface; ownership kept for manual review"
        return 1
    fi
    # A temporary mount left by an interrupted bracket is removed first (verified).
    if ! _halow_ipv6_scrub "$iface"; then
        halow_log_error "ipv6: INCOMPLETE: a leftover temporary mount on $iface could not be cleaned up; ownership kept"
        return 1
    fi
    dir="$(_halow_ipv6_conf_dir)/${iface}"
    file="${dir}/disable_ipv6"
    if [ ! -e "$dir" ]; then
        if [ -d "$(_halow_ipv6_conf_dir)" ]; then
            halow_own_clear "$key"
            halow_log_info "ipv6: $iface no longer exists; its IPv6 setting went with it"
            return 0
        fi
        halow_log_error "ipv6: the IPv6 configuration directory cannot be read; the setting of $iface is not confirmed restored"
        return 1
    fi
    if cur="$(_halow_ipv6_read "$file")"; then :; else cur=""; fi
    if [ "$cur" != "$orig" ]; then
        set_rc=0
        _halow_ipv6_set "$iface" "$orig" || set_rc=$?
        if [ "$set_rc" -eq 2 ]; then
            halow_log_error "ipv6: INCOMPLETE: the temporary write access on $iface is not confirmed removed; ownership kept"
            return 1
        fi
        if cur="$(_halow_ipv6_read "$file")"; then :; else cur=""; fi
    fi
    if [ "$cur" = "$orig" ]; then
        halow_own_clear "$key"
        halow_log_info "ipv6: the IPv6 setting of $iface is restored ($orig)"
        return 0
    fi
    halow_log_error "ipv6: could not restore the IPv6 setting of $iface (reads '$cur', recorded '$orig'); ownership kept"
    return 1
}

# _halow_ipv6_marked — prints the interface of every ipv6_* marker, one per line.
_halow_ipv6_marked() {
    local dir="${HALOW_STATE_DIR:?}/owns" f name
    [ -d "$dir" ] || return 0
    for f in "$dir"/ipv6_*; do
        [ -e "$f" ] || continue
        name="${f##*/}"
        case "$name" in *.tmp.*) continue ;; esac
        printf '%s\n' "${name#ipv6_}"
    done
    return 0
}

# halow_ipv6_restore_all — restores every recorded interface. 0 when every marker was
# confirmed and cleared (or none was held); 1 if any stays unconfirmed.
halow_ipv6_restore_all() {
    local rc=0 iface
    local -a list=()
    # First, whatever an interrupted bracket left (found in the mount table, not only by
    # record); a leftover that cannot be cleaned up keeps this call from reporting success.
    halow_ipv6_scrub_all || rc=1
    mapfile -t list < <(_halow_ipv6_marked)
    for iface in "${list[@]}"; do
        [ -n "$iface" ] || continue
        _halow_ipv6_restore_one "$iface" || rc=1
    done
    return "$rc"
}

# halow_ipv6_forget_if_gone <iface> — clears the record of <iface> when the interface no
# longer exists (its setting went with it). 0 when no record remains or the interface
# still exists (the record is then kept and IPv6 stays off); 1 if it could not be decided.
halow_ipv6_forget_if_gone() {
    local iface="${1:-}"
    halow_validate_iface_name "$iface" || return 1
    halow_own_check "ipv6_${iface}" || return 0
    if [ -e "$(_halow_ipv6_conf_dir)/${iface}" ]; then
        return 0
    fi
    _halow_ipv6_restore_one "$iface"
}

# halow_ipv6_present — 0 if any ipv6_* marker (a setting still to restore) or ipv6br_*
# record (a temporary mount not verified closed) is held.
halow_ipv6_present() {
    local iface
    while IFS= read -r iface; do
        [ -n "$iface" ] && return 0
    done < <(_halow_ipv6_marked; _halow_ipv6_bracket_marked)
    return 1
}

# halow_ipv6_mount_table_readable — 0 when the mount table that leftover mounts are looked
# for in can be read (rollback uses it to tell a failure it can account for from one it cannot).
halow_ipv6_mount_table_readable() {
    [ -r "$(_halow_ipv6_mountinfo)" ]
}
