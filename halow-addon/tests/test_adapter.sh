#!/usr/bin/env bash
# Tests adapter.sh against a fake USB sysfs tree laid out like the real one: entries under
# bus/usb/devices are symlinks into a devices/ hierarchy, every device has an interface entry
# without idVendor, and the network interface sits several directories below the device.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_adapter.sh

echo "== test_adapter =="
hat_setup

V="$HALOW_ADAPTER_VENDOR_ID"
P="$HALOW_ADAPTER_PRODUCT_ID"
SLEEPS="$HAT_TMP/sleeps"
halow_adapter_sleep() { printf 'sleep %s\n' "$1" >> "$SLEEPS"; }

reset_usb() {
    rm -rf "$HAT_TMP/sys"
    mkdir -p "$HALOW_SYS_USB_DIR" "$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1"
    unset HALOW_ADAPTER_SYSFS HALOW_ADAPTER_IDENTITY HALOW_ADAPTER_COUNT HALOW_ADAPTER_UNRECOGNISED_COUNT
    : > "$SLEEPS"
}

echo "-- constants --"
assert_eq "325b" "$V" "the supported vendor id comes from constants.sh"
assert_eq "8100" "$P" "the supported product id comes from constants.sh"

echo "-- detection --"
reset_usb
hat_usb_add 1-1 1d6b 0002          # an unrelated device (a hub)
assert_exit 2 "no adapter: NO_ADAPTER (2)" halow_adapter_check
assert_eq 0 "$HALOW_ADAPTER_COUNT" "no recognised device counted"
assert_eq "" "$HALOW_ADAPTER_SYSFS" "no device path recorded"

reset_usb
hat_usb_add 1-1 1d6b 0002
hat_usb_add 1-2 "$V" "$P" 1 3
assert_exit 0 "one adapter: accepted" halow_adapter_check
assert_eq 1 "$HALOW_ADAPTER_COUNT" "one recognised device counted"
assert_eq 0 "$HALOW_ADAPTER_UNRECOGNISED_COUNT" "no unrecognised device counted"
assert_eq "$(cd -P "$(hat_usb_phys 1-2)" && pwd -P)" "$HALOW_ADAPTER_SYSFS" "the recorded path is the physical device directory (symlink resolved)"
assert_eq "1:3" "$HALOW_ADAPTER_IDENTITY" "the bus/device identity is recorded"

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
hat_usb_add 1-3 "$V" "$P" 1 4
assert_exit 3 "two adapters: MULTIPLE_ADAPTERS (3)" halow_adapter_check
assert_eq 2 "$HALOW_ADAPTER_COUNT" "two recognised devices counted"
assert_eq "" "$HALOW_ADAPTER_SYSFS" "no device path recorded when ambiguous"
assert_exit 1 "no interface is derived when ambiguous" halow_adapter_netdev

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
hat_usb_add 1-3 "$V" 9999 1 4
assert_exit 0 "one recognised plus one unrecognised: the recognised one is used" halow_adapter_check
assert_eq 1 "$HALOW_ADAPTER_UNRECOGNISED_COUNT" "the unrecognised device is counted"
assert_eq "$(cd -P "$(hat_usb_phys 1-2)" && pwd -P)" "$HALOW_ADAPTER_SYSFS" "the recognised device is the one recorded"

reset_usb
hat_usb_add 1-3 "$V" 9999
assert_exit 4 "only an unrecognised device with the vendor id: fail closed (4)" halow_adapter_check
assert_eq 1 "$HALOW_ADAPTER_UNRECOGNISED_COUNT" "the unrecognised device is counted"

reset_usb
hat_usb_add 1-3 "$V" 8101
hat_usb_add 1-4 "$V" 0001
assert_exit 4 "same vendor, wrong products only: fail closed (4)" halow_adapter_check
assert_eq 2 "$HALOW_ADAPTER_UNRECOGNISED_COUNT" "both unrecognised devices are counted"

reset_usb
hat_usb_add 1-3 9999 "$P"
assert_exit 2 "another vendor with the same product id is not an adapter (2)" halow_adapter_check
assert_eq 0 "$HALOW_ADAPTER_UNRECOGNISED_COUNT" "a foreign vendor is not counted as unrecognised"

reset_usb
hat_usb_add 1-2 "325B" "8100" 1 3
printf '  325B \n' > "$(hat_usb_phys 1-2)/idVendor"
assert_exit 0 "ids are compared without blanks and case" halow_adapter_check

reset_usb
rm -rf "$HAT_TMP/sys"
assert_exit 2 "a missing USB tree means no adapter" halow_adapter_check

echo "-- interface derivation --"
reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
assert_exit 1 "no interface before the driver binds" halow_adapter_netdev
hat_usb_add_netdev 1-2 wlu1
out="$(halow_adapter_netdev)"; rc=$?
assert_eq 0 "$rc" "the interface is found once it exists"
assert_eq "wlu1" "$out" "the interface name comes from the device's own subtree, several levels down"
hat_usb_add 1-5 1d6b 0003
mkdir -p "$(hat_usb_phys 1-5)/1-5:1.0/net/eth9"
assert_eq "wlu1" "$(halow_adapter_netdev)" "an interface of another USB device is never picked"
mkdir -p "$(hat_usb_phys 1-2)/1-2:1.0/host0/wiphy-glue/net/wlu1.sta1" "$(hat_usb_phys 1-2)/1-2:1.0/host0/wiphy-glue/net/wlu1.sta12"
assert_eq "wlu1" "$(halow_adapter_netdev)" "per-station interfaces of the parent are not the adapter's interface"
mkdir -p "$(hat_usb_phys 1-2)/1-2:1.0/net/wlu7"
assert_exit 2 "two unrelated interfaces under the adapter: ambiguous, never guessed" halow_adapter_netdev

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
mkdir -p "$(hat_usb_phys 1-2)/1-2:1.0/net/wlu9"
assert_eq "wlu9" "$(halow_adapter_netdev)" "without a prior scan the single adapter is scanned first"
for v in HALOW_INTERFACE HALOW_CFG_HALOW_INTERFACE halow_interface; do
    export "$v=wrong0"
done
assert_eq "wlu9" "$(halow_adapter_netdev)" "an interface name from the environment is ignored"
unset HALOW_INTERFACE HALOW_CFG_HALOW_INTERFACE halow_interface
assert_eq 0 "$(declare -p 2>/dev/null | grep -c 'wlu9')" "the interface name is not stored in any shell variable"

echo "-- waiting for the interface --"
reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
# The interface appears after the third wait.
halow_adapter_sleep() {
    printf 'sleep %s\n' "$1" >> "$SLEEPS"
    local n; n="$(grep -c . "$SLEEPS")"
    if [ "$n" -ge 3 ]; then hat_usb_add_netdev 1-2 wlu1; fi
}
out="$(halow_adapter_netdev_wait 10)"; rc=$?
assert_eq 0 "$rc" "the wait succeeds when the interface appears later"
assert_eq "wlu1" "$out" "the wait prints the interface"
assert_eq 3 "$(grep -c . "$SLEEPS")" "it waited exactly until the interface appeared"
assert_eq "sleep 1" "$(sort -u "$SLEEPS")" "each wait is one second through the stubbable sleep"

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
halow_adapter_sleep() { printf 'sleep %s\n' "$1" >> "$SLEEPS"; }
assert_exit 1 "the wait times out when no interface appears" halow_adapter_netdev_wait 4
assert_eq 4 "$(grep -c . "$SLEEPS")" "the wait is bounded by the timeout"
: > "$SLEEPS"
assert_exit 1 "a zero timeout checks once and does not sleep" halow_adapter_netdev_wait 0
assert_eq 0 "$(grep -c . "$SLEEPS")" "no sleep with a zero timeout"
assert_exit 1 "an invalid timeout is refused" halow_adapter_netdev_wait abc

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
halow_adapter_sleep() { printf 'sleep %s\n' "$1" >> "$SLEEPS"; hat_usb_remove 1-2; }
assert_exit 1 "the wait stops when the adapter disappears" halow_adapter_netdev_wait 30
assert_eq 1 "$(grep -c . "$SLEEPS")" "it stopped right after the device vanished"

reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
mkdir -p "$(hat_usb_phys 1-2)/1-2:1.0/net/wlu1" "$(hat_usb_phys 1-2)/1-2:1.0/net/wlu2"
halow_adapter_sleep() { printf 'sleep %s\n' "$1" >> "$SLEEPS"; }
assert_exit 2 "an ambiguous result ends the wait at once" halow_adapter_netdev_wait 30
assert_eq 0 "$(grep -c . "$SLEEPS")" "an ambiguous result is never retried"

echo "-- presence --"
reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
assert_exit 0 "the adapter is present after detection" halow_adapter_present
hat_usb_remove 1-2
assert_exit 1 "a removed adapter is not present" halow_adapter_present
hat_usb_add 1-2 "$V" "$P" 1 7
assert_exit 1 "a re-enumerated device (new device number) is not the same adapter" halow_adapter_present
reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
halow_adapter_check >/dev/null 2>&1
printf '9999\n' > "$(hat_usb_phys 1-2)/idProduct"
assert_exit 1 "a device whose identity changed is not the adapter" halow_adapter_present
reset_usb
assert_exit 1 "nothing is present before any scan" halow_adapter_present

echo "-- read-only --"
reset_usb
hat_usb_add 1-2 "$V" "$P" 1 3
hat_usb_add_netdev 1-2 wlu1
RBIN="$HAT_TMP/rbin"
hat_recording_bin "$RBIN" find
restricted() { local PATH="$RBIN"; "$@"; }
before="$(hat_tree_listing "$HAT_TMP/sys")"
: > "$HAT_CALLS"
assert_exit 0 "check works with only the recording command directory on PATH" restricted halow_adapter_check
assert_exit 0 "netdev works with only the recording command directory on PATH" restricted halow_adapter_netdev
assert_exit 0 "present works with only the recording command directory on PATH" restricted halow_adapter_present
assert_eq " find " "$(hat_called_commands)" "find is the only external command run"
assert_eq "$before" "$(hat_tree_listing "$HAT_TMP/sys")" "the USB tree is unchanged"

echo "-- strict shell mode --"
STRICT="$HAT_TMP/strict.sh"
cat > "$STRICT" <<EOF
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_SYS_USB_DIR="$HALOW_SYS_USB_DIR"
. "$HAT_LIB_DIR/constants.sh"; . "$HAT_LIB_DIR/common.sh"; . "$HAT_LIB_DIR/adapter.sh"
halow_adapter_sleep() { :; }
f() {
    if halow_adapter_check 2>/dev/null; then echo "check=0"; else echo "check=\$?"; fi
    if n="\$(halow_adapter_netdev_wait 2 2>/dev/null)"; then echo "netdev=\$n"; else echo "netdev_rc=\$?"; fi
    if halow_adapter_present; then echo present; else echo absent; fi
}
f
EOF
assert_eq "check=0
netdev=wlu1
present" "$(bash "$STRICT")" "the functions run under errexit/nounset/pipefail (adapter with interface)"
reset_usb
assert_eq "check=2
netdev_rc=1
absent" "$(bash "$STRICT")" "the functions run under errexit/nounset/pipefail (no adapter)"
assert_success "adapter.sh can be sourced twice" bash -c ". '$HAT_LIB_DIR/adapter.sh'; . '$HAT_LIB_DIR/adapter.sh'; declare -F halow_adapter_check"

hat_teardown
echo "test_adapter: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
