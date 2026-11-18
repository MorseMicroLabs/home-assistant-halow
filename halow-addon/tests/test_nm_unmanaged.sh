#!/usr/bin/env bash
# Tests nm_unmanaged.sh: NetworkManager-unmanaged interface control via D-Bus —
# resolve/get/set primitives, the mark/verify/restore ownership
# cycle for two independent interfaces, the WDS-creation-race retry/timeout, a foreign
# concurrent change detected before restore, and a failed restoration. dbus-send is
# stubbed throughout — no real D-Bus daemon or NetworkManager is available or needed
# off-device.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_nm_unmanaged =="
halow_test_setup

# A small per-device state file backs the stub's own Managed state, defaulting to
# "true" (NetworkManager's own real default for a newly-registered device) until this
# package's own Set call changes it — exactly like test_rollback.sh's own stub.
DBUS_STATE_DIR="$HALOW_TEST_TMP/fake-nm-state"
mkdir -p "$DBUS_STATE_DIR"
# A separate flag file controls how many startup attempts GetDeviceByIpIface must make
# before it "finds" wlu1.sta1 — used to exercise the WDS-creation-race retry below
# without a real 1-second-per-attempt sleep dominating this test's own runtime.
WDS_READY_AFTER_ATTEMPTS="$HALOW_TEST_TMP/wds-ready-after"
WDS_ATTEMPT_COUNT="$HALOW_TEST_TMP/wds-attempt-count"
dbus-send() {
    case "$*" in
        *GetDeviceByIpIface*)
            local iface
            iface="$(printf '%s\n' "$@" | tail -1)"
            iface="${iface#string:}"
            case "$iface" in
                wlu1) echo '   object path "/org/freedesktop/NetworkManager/Devices/1"' ;;
                wlu1.sta1)
                    local n
                    n=$(( $(command cat "$WDS_ATTEMPT_COUNT" 2>/dev/null || echo 0) + 1 ))
                    echo "$n" > "$WDS_ATTEMPT_COUNT"
                    if [ "$n" -ge "$(command cat "$WDS_READY_AFTER_ATTEMPTS" 2>/dev/null || echo 1)" ]; then
                        echo '   object path "/org/freedesktop/NetworkManager/Devices/2"'
                    fi
                    ;;
                never-exists) : ;;
                *) exit 1 ;;
            esac
            ;;
        *Properties.Get*)
            local a dev
            for a in "$@"; do case "$a" in /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;; esac; done
            echo "   variant       boolean $(command cat "$DBUS_STATE_DIR/${dev##*/}" 2>/dev/null || echo true)"
            ;;
        *Properties.Set*)
            local a dev val
            for a in "$@"; do
                case "$a" in
                    /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;;
                    variant:boolean:*) val="${a#variant:boolean:}" ;;
                esac
            done
            echo "$val" > "$DBUS_STATE_DIR/${dev##*/}"
            ;;
        *) exit 1 ;;
    esac
}

echo "== test_nm_unmanaged: low-level resolve/get/set primitives =="

assert_eq "/org/freedesktop/NetworkManager/Devices/1" "$(halow_nm_resolve_device "wlu1")" \
    "resolve finds the parent interface's own device path"
assert_failure "resolve fails closed (not blocking forever) for an interface NetworkManager never registers" \
    halow_nm_resolve_device "never-exists" 2

assert_eq "true" "$(halow_nm_get_managed "/org/freedesktop/NetworkManager/Devices/1")" \
    "get reads the real default (managed=true) before anything touches it"

assert_success "set succeeds and is verified by read-back" \
    halow_nm_set_managed "/org/freedesktop/NetworkManager/Devices/1" "false"
assert_eq "false" "$(halow_nm_get_managed "/org/freedesktop/NetworkManager/Devices/1")" \
    "the device really shows Managed=false after set"
# Reset for the scenarios below.
rm -f "$DBUS_STATE_DIR/1"

echo "== test_nm_unmanaged: mark/restore ownership cycle (parent interface) =="

assert_success "mark_unmanaged succeeds for the parent interface" \
    halow_nm_mark_unmanaged "wlu1" "nm_unmanaged_parent"
assert_eq "false" "$(cat "$DBUS_STATE_DIR/1")" "the parent interface is really marked unmanaged"
assert_success "ownership recorded after a successful mark" \
    halow_own_check "nm_unmanaged_parent"

assert_success "re-marking the SAME interface is idempotent (does not disturb the tracked prior value)" \
    halow_nm_mark_unmanaged "wlu1" "nm_unmanaged_parent"

assert_success "restore succeeds" \
    halow_nm_restore_managed "nm_unmanaged_parent" "wlu1"
assert_eq "true" "$(cat "$DBUS_STATE_DIR/1")" \
    "the parent interface is restored to its true original (managed=true) value"
assert_failure "ownership cleared after a successful restore" \
    halow_own_check "nm_unmanaged_parent"

assert_success "restoring again when nothing is owned is a safe no-op" \
    halow_nm_restore_managed "nm_unmanaged_parent"

# Regression: an interface already unmanaged for an unrelated reason BEFORE this package
# ever touched it must be restored to that true prior value, never clobbered to "true".
printf '%s' "false" > "$DBUS_STATE_DIR/1"
assert_success "mark succeeds over an interface already unmanaged for an unrelated reason" \
    halow_nm_mark_unmanaged "wlu1" "nm_unmanaged_parent"
halow_nm_restore_managed "nm_unmanaged_parent" "wlu1" >/dev/null
assert_eq "false" "$(cat "$DBUS_STATE_DIR/1")" \
    "restore puts back the exact pre-existing (already-unmanaged) value, never assumed true"

echo "== test_nm_unmanaged: independent ownership (WDS interface, separate key) =="
rm -f "$DBUS_STATE_DIR/1" "$DBUS_STATE_DIR/2" "$WDS_READY_AFTER_ATTEMPTS" "$WDS_ATTEMPT_COUNT"

assert_success "mark_unmanaged succeeds for the WDS interface under its own, separate key" \
    halow_nm_mark_unmanaged "wlu1.sta1" "nm_unmanaged_wds"
assert_eq "false" "$(cat "$DBUS_STATE_DIR/2")" "the WDS interface is really marked unmanaged"
assert_failure "the parent interface's own key is untouched by marking the WDS interface" \
    halow_own_check "nm_unmanaged_parent"
halow_nm_restore_managed "nm_unmanaged_wds" >/dev/null

echo "== test_nm_unmanaged: the unavoidable WDS creation race =="
rm -f "$DBUS_STATE_DIR/2" "$WDS_ATTEMPT_COUNT"
echo 3 > "$WDS_READY_AFTER_ATTEMPTS"
assert_success "resolve retries until NetworkManager itself registers the just-created device (ready on the 3rd attempt)" \
    halow_nm_resolve_device "wlu1.sta1" 5
rm -f "$DBUS_STATE_DIR/2" "$WDS_ATTEMPT_COUNT"
echo 99 > "$WDS_READY_AFTER_ATTEMPTS"
assert_failure "resolve fails closed (does not block indefinitely) if NetworkManager never registers the device within the timeout" \
    halow_nm_resolve_device "wlu1.sta1" 2
rm -f "$WDS_READY_AFTER_ATTEMPTS" "$WDS_ATTEMPT_COUNT"

echo "== test_nm_unmanaged: hardening — foreign concurrent change and failed restoration =="
rm -f "$DBUS_STATE_DIR/1"

assert_success "fresh mark succeeds (foreign-change scenario setup)" \
    halow_nm_mark_unmanaged "wlu1" "nm_unmanaged_parent"
# Some other actor (a human, another tool) re-enables management on this interface.
printf '%s' "true" > "$DBUS_STATE_DIR/1"
assert_failure "restore refuses to overwrite a value changed by another actor since this package's own mark" \
    halow_nm_restore_managed "nm_unmanaged_parent" "wlu1"
assert_eq "true" "$(cat "$DBUS_STATE_DIR/1")" \
    "the foreign value is left completely untouched, never overwritten"
assert_success "ownership is NOT cleared when a foreign concurrent change is detected" \
    halow_own_check "nm_unmanaged_parent"
halow_own_clear "nm_unmanaged_parent"
rm -f "$DBUS_STATE_DIR/1"

# Failed restoration: halow_nm_set_managed's own internal post-write read-back (a
# SECOND Properties.Get call — the first is restore's own pre-restore "is it still what
# I set it to" check) disagrees with what was actually written. Exercised by swapping in
# a narrower dbus-send stub that only needs to handle Get/Set (restore never re-resolves
# the device, so GetDeviceByIpIface is never called here) and returns a wrong value on
# exactly the 2nd Properties.Get call, via a dedicated, stub-local file counter — not a
# cross-cutting `cat` counter, since this stub's own reads/writes are the only state that
# matters for this specific scenario.
assert_success "fresh mark succeeds (failed-restoration scenario setup)" \
    halow_nm_mark_unmanaged "wlu1" "nm_unmanaged_parent"
_get_call_file="$HALOW_TEST_TMP/get_call_count"
echo 0 > "$_get_call_file"
dbus-send() {
    case "$*" in
        *Properties.Get*)
            local a dev n
            for a in "$@"; do case "$a" in /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;; esac; done
            n=$(( $(command cat "$_get_call_file" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$_get_call_file"
            if [ "$n" -eq 2 ]; then
                # A valid boolean, but the WRONG one: restore is writing "true" back, so
                # a lying "false" here exercises the actual value-mismatch branch, not
                # get_managed's own separate not-a-valid-boolean failure branch.
                echo "   variant       boolean false"
            else
                echo "   variant       boolean $(command cat "$DBUS_STATE_DIR/${dev##*/}" 2>/dev/null || echo true)"
            fi
            ;;
        *Properties.Set*)
            local a dev val
            for a in "$@"; do
                case "$a" in
                    /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;;
                    variant:boolean:*) val="${a#variant:boolean:}" ;;
                esac
            done
            echo "$val" > "$DBUS_STATE_DIR/${dev##*/}"
            ;;
        *) exit 1 ;;
    esac
}
halow_nm_restore_managed "nm_unmanaged_parent" "wlu1"
_restore_status=$?
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_restore_status" -ne 0 ]; then
    echo "  ok: restore fails closed when its own post-restore read-back does not match the prior value"
else
    echo "  FAIL: restore fails closed when its own post-restore read-back does not match the prior value (got success)"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_success "ownership is NOT cleared when the restore read-back mismatches" \
    halow_own_check "nm_unmanaged_parent"
halow_own_clear "nm_unmanaged_parent"

echo "== test_nm_unmanaged: hardening — the interface itself has genuinely disappeared =="
# Restore the full (GetDeviceByIpIface-capable) stub, since mark_unmanaged needs it.
dbus-send() {
    case "$*" in
        *GetDeviceByIpIface*)
            local iface
            iface="$(printf '%s\n' "$@" | tail -1)"
            iface="${iface#string:}"
            case "$iface" in
                wlu1) echo '   object path "/org/freedesktop/NetworkManager/Devices/1"' ;;
                wlu1.sta1) echo '   object path "/org/freedesktop/NetworkManager/Devices/2"' ;;
                *) return 1 ;;
            esac
            ;;
        *Properties.Get*)
            local a dev
            for a in "$@"; do case "$a" in /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;; esac; done
            [ -f "$HALOW_TEST_TMP/wds-device-gone" ] && [ "$dev" = "/org/freedesktop/NetworkManager/Devices/2" ] && exit 1
            echo "   variant       boolean $(command cat "$DBUS_STATE_DIR/${dev##*/}" 2>/dev/null || echo true)"
            ;;
        *Properties.Set*)
            local a dev val
            for a in "$@"; do
                case "$a" in
                    /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;;
                    variant:boolean:*) val="${a#variant:boolean:}" ;;
                esac
            done
            [ -f "$HALOW_TEST_TMP/wds-device-gone" ] && [ "$dev" = "/org/freedesktop/NetworkManager/Devices/2" ] && exit 1
            echo "$val" > "$DBUS_STATE_DIR/${dev##*/}"
            ;;
        *) exit 1 ;;
    esac
}

# Regression test: once hostapd's own termination destroys the dynamic WDS interface,
# BOTH NetworkManager's own D-Bus view (simulated above) AND the kernel's own interface
# list genuinely lose it — confirmed via halow_kernel_iface_exists, not inferred from
# the D-Bus failure alone. Restore must recognise this as "nothing left to restore" and
# clear ownership, not get stuck.
mkdir -p "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
assert_success "fresh mark succeeds while the WDS interface still genuinely exists" \
    halow_nm_mark_unmanaged "wlu1.sta1" "nm_unmanaged_wds"
rm -rf "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
: > "$HALOW_TEST_TMP/wds-device-gone"
assert_success "restore succeeds (not fails) once the interface is confirmed genuinely gone, kernel-side" \
    halow_nm_restore_managed "nm_unmanaged_wds"
assert_failure "ownership is cleared once the interface is confirmed genuinely gone" \
    halow_own_check "nm_unmanaged_wds"

# Regression test, the critical safety distinction: a D-Bus failure to read/resolve the
# device must NEVER by itself be treated as "the interface is gone" — only the kernel's
# own, independently-checked interface list may say that. Simulated here by a D-Bus
# failure for a device whose own kernel interface is still very much present.
mkdir -p "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
rm -f "$HALOW_TEST_TMP/wds-device-gone"
assert_success "fresh mark succeeds (D-Bus-failure-but-kernel-still-present scenario setup)" \
    halow_nm_mark_unmanaged "wlu1.sta1" "nm_unmanaged_wds"
: > "$HALOW_TEST_TMP/wds-device-gone"
# The interface's own kernel presence is left in place this time — only the D-Bus side
# is made to fail, simulating e.g. a transient NetworkManager/D-Bus hiccup, never a
# genuinely destroyed interface.
assert_failure "restore refuses to clear ownership on a D-Bus failure alone, while the kernel interface itself still exists" \
    halow_nm_restore_managed "nm_unmanaged_wds"
assert_success "ownership is KEPT — a D-Bus failure is never, by itself, proof the interface is gone" \
    halow_own_check "nm_unmanaged_wds"
rm -f "$HALOW_TEST_TMP/wds-device-gone"
halow_own_clear "nm_unmanaged_wds"
rm -rf "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"


echo "== test_nm_unmanaged: the dynamic WDS interface may be UNKNOWN to NetworkManager (live-device test: NM never created a Device for wlu1.sta1) -- accepted ONLY on a definitive UnknownDevice answer + the kernel interface still present; every other failure stays fatal =="
sleep() { return 0; }
_nm_mode=normal
dbus-send() {
    case "$*" in
        *GetDeviceByIpIface*)
            case "$_nm_mode" in
                unknown) echo "Error org.freedesktop.NetworkManager.UnknownDevice: No device found for the requested iface." >&2; return 1 ;;
                buserr)  echo "Error org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; return 1 ;;
                mixed)   n=$(( $(cat "$HALOW_TEST_TMP/mixed_n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$HALOW_TEST_TMP/mixed_n"
                         if [ "$n" -eq 1 ]; then echo "Error org.freedesktop.NetworkManager.UnknownDevice: No device found for the requested iface." >&2; else echo "Error org.freedesktop.DBus.Error.AccessDenied: denied" >&2; fi; return 1 ;;
                normal)  echo '   object path "/org/freedesktop/NetworkManager/Devices/2"' ;;
            esac ;;
        *Properties.Get*) echo "   variant       boolean $(command cat "$DBUS_STATE_DIR/2" 2>/dev/null || echo true)" ;;
        *Properties.Set*)
            local a val; for a in "$@"; do case "$a" in variant:boolean:*) val="${a#variant:boolean:}" ;; esac; done
            echo "$val" > "$DBUS_STATE_DIR/2" ;;
        *) return 1 ;;
    esac
}
rm -f "$DBUS_STATE_DIR/2"
_nm_mode=unknown;  halow_nm_resolve_device wlu1.sta1 3 >/dev/null 2>&1; assert_eq "3" "$?" "resolve returns 3 when NetworkManager answers UnknownDevice on EVERY attempt"
_nm_mode=buserr;   halow_nm_resolve_device wlu1.sta1 3 >/dev/null 2>&1; assert_eq "1" "$?" "resolve returns 1 (could not tell) for a bus/service failure"
_nm_mode=mixed; rm -f "$HALOW_TEST_TMP/mixed_n"; halow_nm_resolve_device wlu1.sta1 3 >/dev/null 2>&1; assert_eq "1" "$?" "resolve returns 1 when ANY attempt failed some other way (not 'positively unknown')"

mkdir -p "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
_nm_mode=unknown
halow_nm_mark_unmanaged_if_known wlu1.sta1 nm_unmanaged_wds 3 >/dev/null 2>&1; assert_eq "0" "$?" "UnknownDevice + kernel interface present: accepted (NM does not manage it)"
assert_failure "no ownership marker is created for an interface NetworkManager never knew" halow_own_check nm_unmanaged_wds
rm -rf "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
halow_nm_mark_unmanaged_if_known wlu1.sta1 nm_unmanaged_wds 3 >/dev/null 2>&1; assert_eq "1" "$?" "UnknownDevice but the kernel interface is gone too: refused"
mkdir -p "$HALOW_SYS_CLASS_NET_DIR/wlu1.sta1"
_nm_mode=buserr
halow_nm_mark_unmanaged_if_known wlu1.sta1 nm_unmanaged_wds 3 >/dev/null 2>&1; assert_eq "1" "$?" "a D-Bus/service failure stays FATAL (never mistaken for 'NM does not know it')"
assert_failure "no marker after a fatal D-Bus failure" halow_own_check nm_unmanaged_wds
_nm_mode=mixed; rm -f "$HALOW_TEST_TMP/mixed_n"
halow_nm_mark_unmanaged_if_known wlu1.sta1 nm_unmanaged_wds 3 >/dev/null 2>&1; assert_eq "1" "$?" "a mixed unknown/other-failure sequence stays FATAL"
_nm_mode=normal
halow_nm_mark_unmanaged_if_known wlu1.sta1 nm_unmanaged_wds 3 >/dev/null 2>&1; assert_eq "0" "$?" "a device NM DOES know is still marked unmanaged exactly as before"
assert_success "ownership IS recorded when it was actually marked" halow_own_check nm_unmanaged_wds
halow_nm_restore_managed nm_unmanaged_wds >/dev/null 2>&1
assert_failure "and it is restored/cleared again by the normal path" halow_own_check nm_unmanaged_wds
# the PARENT interface keeps the strict behaviour: a device NM does not know is fatal there
_nm_mode=unknown
halow_nm_mark_unmanaged wlu1 nm_unmanaged_parent 3 >/dev/null 2>&1; assert_eq "3" "$?" "the plain (parent) mark still FAILS when NM does not know the interface"
assert_failure "no parent marker either" halow_own_check nm_unmanaged_parent
assert_success "the bridge backend uses the tolerant wrapper for the dynamic per-station interfaces (one key per interface)" \
    grep -q 'halow_nm_mark_unmanaged_if_known "$port" "$key"' "$HALOW_LIB_DIR/backend_bridge.sh"
assert_success "the manager uses the tolerant wrapper for the bridge (already excluded by the host configuration)" \
    grep -q 'halow_nm_mark_unmanaged_if_known "$HALOW_BRIDGE_NAME" "nm_unmanaged_bridge"' "$HALOW_LIB_DIR/manager.sh"
assert_success "and the strict function for the parent interface" \
    grep -q 'halow_nm_mark_unmanaged "$HALOW_IFACE" "nm_unmanaged_parent"' "$HALOW_LIB_DIR/manager.sh"
unset -f sleep

echo "-- post-check: after the network is applied, NetworkManager must STILL have no Device for the WDS interface (it adopting the interface could flush our address) --"
sleep() { return 0; }
dbus-send() {
    case "$_nm_mode" in
        unknown) echo "Error org.freedesktop.NetworkManager.UnknownDevice: No device found for the requested iface." >&2; return 1 ;;
        buserr)  echo "Error org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; return 1 ;;
        appeared) echo '   object path "/org/freedesktop/NetworkManager/Devices/9"' ;;
    esac
}
_nm_mode=unknown;  assert_success "still no Device (definitive UnknownDevice): passes" halow_nm_assert_no_device wlu1.sta1
_nm_mode=appeared; assert_failure "a Device appeared since: fails closed" halow_nm_assert_no_device wlu1.sta1
_nm_mode=buserr;   assert_failure "cannot ask NetworkManager: fails closed (never assumed fine)" halow_nm_assert_no_device wlu1.sta1
assert_success "the bridge backend performs the post-check for a per-station interface, only when no unmanaged marker is held for it" \
    bash -c 'f="$1"; grep -q "halow_own_check \"\$key\"" "$f" && grep -q "halow_nm_assert_no_device \"\$port\"" "$f"' _ "$HALOW_LIB_DIR/backend_bridge.sh"
assert_success "...and that post-check comes after the interface was made a bridge port (never before it could be adopted)" \
    bash -c 'f="$1"; a="$(grep -n "halow_bridge_port_add" "$f" | head -n1 | cut -d: -f1)"; b="$(grep -n "halow_nm_assert_no_device" "$f" | head -n1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$HALOW_LIB_DIR/backend_bridge.sh"
assert_success "the manager uses the strict function for the parent interface (the same call, moved)" \
    grep -q 'halow_nm_mark_unmanaged "$HALOW_IFACE" "nm_unmanaged_parent"' "$HALOW_LIB_DIR/manager.sh"
unset -f sleep dbus-send

halow_test_teardown
echo "test_nm_unmanaged: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
