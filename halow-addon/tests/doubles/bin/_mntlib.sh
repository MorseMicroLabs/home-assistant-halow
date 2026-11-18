#!/usr/bin/env bash
# Shared state of the fake mount layer (sourced by the fake `mount` and `umount`).
# State: $HALOW_FAKE_MNT_DIR/stack, one "<mountpoint>|<ro|rw>" line per mount, top of the
# stack last; the mount table the code under test reads ($HALOW_PROC_MOUNTINFO) is rendered
# from it after every change. Every operation is logged to $HALOW_FAKE_MNT_DIR/calls.
# Injected faults (HALOW_FAKE_MNT_FAIL, comma list): bind, remount-rw, remount-ro, umount.
# Injected crashes (HALOW_FAKE_MNT_CRASH): bind-before, bind-after, remount-rw-after kill
# the parent process (the "manager") with SIGKILL at that point, leaving the state as is.
FM_DIR="${HALOW_FAKE_MNT_DIR:?}"
FM_STACK="$FM_DIR/stack"
FM_LOG="$FM_DIR/calls"
[ -e "$FM_STACK" ] || : > "$FM_STACK"

fm_log() { printf '%s\n' "$*" >> "$FM_LOG"; }

fm_render() {
    local n=100 p m
    {
        echo "24 1 0:21 /sys /proc/sys ro,nosuid,nodev,noexec,relatime - proc proc rw"
        while IFS='|' read -r p m; do
            [ -n "$p" ] || continue
            n=$((n + 1))
            echo "$n 24 0:21 /sys/net/ipv6/conf/x/disable_ipv6 $p $m,nosuid,nodev,noexec,relatime - proc proc rw"
        done < "$FM_STACK"
    } > "$FM_DIR/mountinfo.tmp" && mv -f "$FM_DIR/mountinfo.tmp" "$FM_DIR/mountinfo"
}

# fm_path_ok <path> — only a per-interface disable_ipv6 file, never all/default.
fm_path_ok() {
    local rest iface
    case "$1" in */net/ipv6/conf/*/disable_ipv6) ;; *) return 1 ;; esac
    rest="${1##*/net/ipv6/conf/}"
    iface="${rest%/disable_ipv6}"
    case "$iface" in ''|*/*|all|default|.|..) return 1 ;; esac
    return 0
}

fm_fail() { case ",${HALOW_FAKE_MNT_FAIL:-}," in *",$1,"*) return 0 ;; esac; return 1; }
fm_crash() { if [ "${HALOW_FAKE_MNT_CRASH:-}" = "$1" ]; then kill -9 "$PPID"; exit 137; fi; return 0; }
