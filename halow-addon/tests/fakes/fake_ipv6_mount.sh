#!/usr/bin/env bash
# The write side of the fake IPv6 mount layer (the mount side is tests/doubles/bin/mount and
# umount, installed by halow_fakes_mnt_install). Source this after ipv6.sh.
#
# fake_ipv6_guard_install wraps ipv6.sh's _halow_ipv6_write so that, like the real
# read-only /proc/sys, a write succeeds only while the topmost fake mount on that exact path
# is read-write (otherwise it is refused, as EROFS is). Every write attempt is logged to the
# fake mount call log. Injected behaviour (HALOW_FAKE_WRITE, comma list): refuse (the write
# is refused even through a read-write mount), noop (the write succeeds but changes nothing).
# HALOW_FAKE_MNT_CRASH=write-after kills the calling shell right after the write.
#
# fake_ipv6_top_mode <file> prints ro, rw or none (no mount on that path).
# fake_ipv6_calls prints the operations recorded so far; fake_ipv6_paths the sorted unique
# paths they touched; fake_ipv6_violations any call the fakes refused as out of bounds.

fake_ipv6_top_mode() {
    local mode=none p m
    while IFS='|' read -r p m; do
        [ "$p" = "$1" ] && mode="$m"
    done < "${HALOW_FAKE_MNT_DIR:?}/stack"
    printf '%s' "$mode"
}

fake_ipv6_guard_install() {
    if ! declare -F _fake_ipv6_orig_write >/dev/null 2>&1; then
        eval "$(declare -f _halow_ipv6_write | sed '1s/_halow_ipv6_write/_fake_ipv6_orig_write/')"
    fi
    _halow_ipv6_write() {
        local file="$1" value="$2" top rc
        printf 'write %s\n' "$file" >> "${HALOW_FAKE_MNT_DIR:?}/calls"
        top="$(fake_ipv6_top_mode "$file")"
        [ "$top" = "rw" ] || return 1
        case ",${HALOW_FAKE_WRITE:-}," in
            *,refuse,*) return 1 ;;
            *,noop,*) return 0 ;;
        esac
        _fake_ipv6_orig_write "$file" "$value"; rc=$?
        if [ "${HALOW_FAKE_MNT_CRASH:-}" = "write-after" ]; then kill -9 "$$"; fi
        return "$rc"
    }
}

fake_ipv6_calls() { cat "${HALOW_FAKE_MNT_DIR:?}/calls" 2>/dev/null || true; }
fake_ipv6_paths() { fake_ipv6_calls | awk '{ print $2 }' | LC_ALL=C sort -u; }
fake_ipv6_violations() { fake_ipv6_calls | grep '^VIOLATION' || true; }
fake_ipv6_reset_calls() { : > "${HALOW_FAKE_MNT_DIR:?}/calls"; }
