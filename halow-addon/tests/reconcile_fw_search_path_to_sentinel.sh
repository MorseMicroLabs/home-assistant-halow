#!/usr/bin/env bash
# One-off, bounded, read-verified LIVE reconciliation of a Green whose firmware-search-path
# sysfs node still holds this add-on's own path after a failed run (rollback INCOMPLETE,
# active "fw_search_path" ownership held, recorded prior value EMPTY).
#
# development-build-only. Exact restoration to empty is not achievable on the test Green
# (a zero-byte and a single-NUL-byte write were both tried live and neither took effect),
# so this installs the inert, nonexistent sentinel path instead, via the add-on's own real
# halow_restore_firmware_search_path (never a hand-rolled re-implementation), clears
# active ownership, and sets "firmware_path_reboot_required". Exact restoration to empty is
# deferred to the controlled end-of-window reboot and verified afterwards with
# halow_verify_fw_search_path_rebooted_clean.
#
# Run INSIDE a disposable container started from the already-built, already-verified
# add-on image (the bare Green host shell is not real bash and cannot run this library),
# with the add-on's real host data directory bind-mounted at /data and the same
# capabilities/AppArmor setting the real add-on uses. NOT part of run_tests.sh.
#
# HOST-LEVEL PRECONDITION (cannot be checked from inside the container, whose /run is not
# the host's): the caller must first confirm from the HOST that the sentinel path does not
# exist, and must set HALOW_HOST_SENTINEL_CONFIRMED_ABSENT=1 only after doing so.
set -uo pipefail

# shellcheck source=/dev/null
. /usr/lib/halow/common.sh
# shellcheck source=/dev/null
. /usr/lib/halow/ownership.sh
# shellcheck source=/dev/null
. /usr/lib/halow/module_load.sh

fail_stop() {
    echo "STOP: $1"
    exit 1
}

echo "=== HALOW_STATE_DIR: $HALOW_STATE_DIR | sysfs: $HALOW_FW_SYSFS_PATH | sentinel: $HALOW_FW_SEARCH_SENTINEL ==="
[ "${HALOW_HOST_SENTINEL_CONFIRMED_ABSENT:-}" = "1" ] \
    || fail_stop "the caller has not confirmed from the HOST that the sentinel path does not exist (HALOW_HOST_SENTINEL_CONFIRMED_ABSENT=1)"

echo "=== Pre-check: current raw sysfs bytes ==="
od -c "$HALOW_FW_SYSFS_PATH"
_current_raw="$(cat "$HALOW_FW_SYSFS_PATH")"
echo "current: '$_current_raw'"

echo "=== Pre-check: ownership markers ==="
if halow_own_check "firmware_path_reboot_required"; then
    fail_stop "firmware_path_reboot_required is already held -- an earlier reconciliation already happened; stopping rather than guessing"
fi
halow_own_check "fw_search_path" \
    || fail_stop "no fw_search_path ownership marker is held -- nothing to reconcile; stopping rather than guessing"
_marker="$(halow_own_get "fw_search_path")"
od -c "$HALOW_STATE_DIR/owns/fw_search_path"
_state_field="${_marker%%$'\n'*}"
_rest="${_marker#*$'\n'}"
_prior_field="${_rest%%$'\n'*}"
_our_value_field="${_rest#*$'\n'}"
echo "marker state='$_state_field' prior='$_prior_field' our_value='$_our_value_field'"
[ "$_state_field" = "applied" ] || fail_stop "marker state is '$_state_field', expected 'applied'"
[ -z "$_prior_field" ] || fail_stop "recorded prior value is '$_prior_field', expected EMPTY"
[ "$_current_raw" = "$_our_value_field" ] || fail_stop "current sysfs value ('$_current_raw') does not equal the marker's recorded our_value ('$_our_value_field') -- some other actor may have changed it"

_mode="$(halow_sys_mount_mode)"
echo "/sys mount mode: $_mode"
[ "$_mode" = "ro" ] || fail_stop "/sys is not currently read-only (found: '$_mode')"

echo "=== All pre-checks passed. Invoking the real halow_restore_firmware_search_path ==="
if halow_restore_firmware_search_path; then
    _restore_rc=0
else
    _restore_rc=$?
fi
echo "halow_restore_firmware_search_path returned: $_restore_rc"

_mode_after="$(halow_sys_mount_mode)"
_node_after="$(cat "$HALOW_FW_SYSFS_PATH")"
echo "/sys mount mode after: $_mode_after | node after: '$_node_after'"
od -c "$HALOW_FW_SYSFS_PATH"
if halow_own_check "fw_search_path"; then _active_cleared=0; else _active_cleared=1; fi
if halow_own_check "firmware_path_reboot_required"; then _reboot_held=1; else _reboot_held=0; fi
echo "active marker cleared=$_active_cleared reboot_required held=$_reboot_held"

if [ "$_restore_rc" -eq 0 ] && [ "$_mode_after" = "ro" ] && [ "$_node_after" = "$HALOW_FW_SEARCH_SENTINEL" ] \
    && [ "$_active_cleared" -eq 1 ] && [ "$_reboot_held" -eq 1 ]; then
    echo "=== RESULT: SUCCESS -- sentinel installed and verified, /sys read-only, active marker cleared, firmware_path_reboot_required set ==="
    exit 0
fi
echo "=== RESULT: NOT fully confirmed -- see the checks above; markers are intentionally left as the real function left them (fail-closed) ==="
exit 1
