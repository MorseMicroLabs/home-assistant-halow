#!/usr/bin/env bash
# Puts the fake `ip`, `bridge`, `ss` and `dnsmasq` (tests/doubles/bin) first on PATH for one
# test process. Call halow_fakes_install after halow_test_setup.
#
# It also redirects the /proc/sys root (HALOW_PROC_SYS_DIR) to a small fake tree: one
# net/ipv6/conf/<iface>/disable_ipv6 file (value 0) per fake interface, and
# net/ipv4/ip_forward (value 1), so a test can prove what was and was not written.

HALOW_FAKES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd)"

halow_fakes_install() {
    HALOW_FAKE_BIN="$HALOW_TEST_TMP/fakebin"
    mkdir -p "$HALOW_FAKE_BIN"
    cp "$HALOW_FAKES_SRC"/* "$HALOW_FAKE_BIN"/
    chmod +x "$HALOW_FAKE_BIN"/*
    case ":$PATH:" in *":$HALOW_FAKE_BIN:"*) ;; *) export PATH="$HALOW_FAKE_BIN:$PATH" ;; esac
    export HALOW_FAKE_LOG="$HALOW_TEST_TMP/fake.calls"
    : > "$HALOW_FAKE_LOG"
    export HALOW_IP=ip HALOW_BRIDGE_CMD=bridge HALOW_SS=ss
    export HALOW_PROC_SYS_DIR="$HALOW_TEST_TMP/fake-proc-sys"
    halow_fakes_mnt_install
    mkdir -p "$HALOW_PROC_SYS_DIR/net/ipv6/conf/all" "$HALOW_PROC_SYS_DIR/net/ipv6/conf/default" "$HALOW_PROC_SYS_DIR/net/ipv4"
    echo 0 > "$HALOW_PROC_SYS_DIR/net/ipv6/conf/all/disable_ipv6"
    echo 0 > "$HALOW_PROC_SYS_DIR/net/ipv6/conf/default/disable_ipv6"
    echo 1 > "$HALOW_PROC_SYS_DIR/net/ipv4/ip_forward"
    halow_fakes_reset
}

# halow_fakes_reset — clear injected failures and canned outputs.
halow_fakes_reset() {
    unset HALOW_FAKE_FAIL HALOW_FAKE_NOOP HALOW_FAKE_NEIGH HALOW_FAKE_FDB HALOW_FAKE_SS HALOW_FAKE_SS_RC
    unset HALOW_FAKE_DNSMASQ_EXIT HALOW_FAKE_DNSMASQ_LIFETIME HALOW_FAKE_MNT_FAIL HALOW_FAKE_MNT_CRASH HALOW_FAKE_WRITE
}

# halow_fakes_iface <name> — make an ordinary (non-bridge) interface exist (with its IPv6
# switch, value 0, in the fake /proc/sys tree when one is installed).
halow_fakes_iface() {
    mkdir -p "$HALOW_SYS_CLASS_NET_DIR/$1"
    [ -f "$HALOW_SYS_CLASS_NET_DIR/$1/address" ] || echo "aa:00:00:00:00:01" > "$HALOW_SYS_CLASS_NET_DIR/$1/address"
    if [ -n "${HALOW_PROC_SYS_DIR:-}" ] && [ -d "$HALOW_PROC_SYS_DIR/net/ipv6/conf" ]; then
        mkdir -p "$HALOW_PROC_SYS_DIR/net/ipv6/conf/$1"
        [ -f "$HALOW_PROC_SYS_DIR/net/ipv6/conf/$1/disable_ipv6" ] || echo 0 > "$HALOW_PROC_SYS_DIR/net/ipv6/conf/$1/disable_ipv6"
    fi
}

# halow_fakes_iface_gone <name> — the interface disappears (sysfs and its IPv6 switch).
halow_fakes_iface_gone() {
    rm -rf "${HALOW_SYS_CLASS_NET_DIR:?}/$1"
    [ -z "${HALOW_PROC_SYS_DIR:-}" ] || rm -rf "${HALOW_PROC_SYS_DIR:?}/net/ipv6/conf/$1"
}

# halow_fakes_calls <prefix> — the recorded calls starting with <prefix>.
halow_fakes_calls() {
    grep -E "^$1" "$HALOW_FAKE_LOG" || true
}

# halow_fakes_mnt_install — the fake mount layer for ipv6.sh's temporary bind mounts: the
# fake `mount` and `umount` (tests/doubles/bin) first on PATH, a stack-backed fake mount
# table (HALOW_PROC_MOUNTINFO) and a call log (HALOW_FAKE_MNT_DIR/calls). The real `mount`
# is never reached. Safe to call again (starts from an empty mount table).
halow_fakes_mnt_install() {
    export HALOW_FAKE_MNT_DIR="$HALOW_TEST_TMP/fakemnt"
    mkdir -p "$HALOW_FAKE_MNT_DIR"
    : > "$HALOW_FAKE_MNT_DIR/stack"; : > "$HALOW_FAKE_MNT_DIR/calls"
    export HALOW_PROC_MOUNTINFO="$HALOW_FAKE_MNT_DIR/mountinfo"
    HALOW_FAKE_BIN="${HALOW_FAKE_BIN:-$HALOW_TEST_TMP/fakebin}"
    mkdir -p "$HALOW_FAKE_BIN"
    cp "$HALOW_FAKES_SRC"/* "$HALOW_FAKE_BIN"/
    chmod +x "$HALOW_FAKE_BIN"/*
    case ":$PATH:" in *":$HALOW_FAKE_BIN:"*) ;; *) export PATH="$HALOW_FAKE_BIN:$PATH" ;; esac
    ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
    unset HALOW_FAKE_MNT_FAIL HALOW_FAKE_MNT_CRASH
}
