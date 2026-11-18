#!/usr/bin/env bash
# Tests iface_detect.sh's halow_verify_usb_device_present (the pre-module-load check)
# and halow_verify_parent_iface (the post-module-load check) — proving the intended USB
# device is physically present before any module load, and that the configured
# interface exists and belongs to that device before any RF-adjacent operation, using a
# fake sysfs tree so no real hardware or root privilege is needed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_iface_safety: halow_verify_usb_device_present (pre-module-load, no net interface needed) =="
halow_test_setup

fake_usb="$HALOW_TEST_TMP/bus-usb-devices"
mkdir -p "$fake_usb/1-1"
echo "325b" > "$fake_usb/1-1/idVendor"
echo "8100" > "$fake_usb/1-1/idProduct"

assert_success "the intended USB device is confirmed present, with no net interface required to exist" \
    halow_verify_usb_device_present "325b" "8100" "$fake_usb"

rm -rf "$fake_usb"
mkdir -p "$fake_usb"
assert_failure "no matching USB device at all fails closed (no net interface, no device)" \
    halow_verify_usb_device_present "325b" "8100" "$fake_usb"

mkdir -p "$fake_usb/1-1" "$fake_usb/1-2"
echo "325b" > "$fake_usb/1-1/idVendor"; echo "8100" > "$fake_usb/1-1/idProduct"
echo "325b" > "$fake_usb/1-2/idVendor"; echo "8100" > "$fake_usb/1-2/idProduct"
assert_failure "two matching USB devices fails closed (refuses to guess which one)" \
    halow_verify_usb_device_present "325b" "8100" "$fake_usb"

mkdir -p "$fake_usb/1-3"
echo "8086" > "$fake_usb/1-3/idVendor"
echo "1234" > "$fake_usb/1-3/idProduct"
rm -rf "$fake_usb/1-2"
assert_success "an unrelated USB device present alongside the intended one does not confuse the count" \
    halow_verify_usb_device_present "325b" "8100" "$fake_usb"

assert_failure "a nonexistent USB sysfs root fails closed rather than silently finding nothing" \
    halow_verify_usb_device_present "325b" "8100" "$HALOW_TEST_TMP/does-not-exist"

halow_test_teardown

echo "== test_iface_safety: halow_verify_parent_iface (post-module-load) =="
halow_test_setup

fake_sysfs="$HALOW_TEST_TMP/sys-class-net"
mkdir -p "$fake_sysfs/wlu1/device"
echo "325b" > "$fake_sysfs/wlu1/device/idVendor"
echo "8100" > "$fake_sysfs/wlu1/device/idProduct"

assert_success "the correct interface with a matching USB ID is verified" \
    halow_verify_parent_iface "wlu1" "325b" "8100" "$fake_sysfs"

assert_failure "a non-existent interface name is rejected" \
    halow_verify_parent_iface "wlu99" "325b" "8100" "$fake_sysfs"

mkdir -p "$fake_sysfs/eth0/device"
echo "8086" > "$fake_sysfs/eth0/device/idVendor"
echo "1234" > "$fake_sysfs/eth0/device/idProduct"
assert_failure "a real interface belonging to a different USB device is rejected (never a typo reaching hostapd)" \
    halow_verify_parent_iface "eth0" "325b" "8100" "$fake_sysfs"

mkdir -p "$fake_sysfs/lo"
assert_failure "an interface with no discoverable idVendor/idProduct at all is rejected" \
    halow_verify_parent_iface "lo" "325b" "8100" "$fake_sysfs"

# This function verifies USB-ID ownership only; NetworkManager-unmanaged status is a
# separate, real step performed afterward by nm_unmanaged.sh (this add-on now has
# `host_dbus: true` and real D-Bus access) — confirm this function no longer claims
# otherwise (a stale claim from before that mechanism existed).
out="$(halow_verify_parent_iface "wlu1" "325b" "8100" "$fake_sysfs" 2>&1)"
case "$out" in
    *"cannot be verified"*|*"relying on the udev rule"*)
        echo "  FAIL: a stale no-D-Bus-access claim was still reported"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        ;;
    *) echo "  ok: no stale no-D-Bus-access claim is reported" ;;
esac
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))

halow_test_teardown
echo "test_iface_safety: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
