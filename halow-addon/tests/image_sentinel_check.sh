#!/usr/bin/env bash
# in-image check of the inert-sentinel firmware-search-path
# lifecycle, run with THIS image's own real bash and BusyBox utilities (cat, printf, od,
# sed, awk, mkdir, rm) rather than the Ubuntu/WSL host's GNU coreutils. The sysfs node is
# a plain file under /tmp and /sys mount-mode handling is stubbed, so nothing here touches
# a real kernel parameter; what it proves is that the REAL production functions behave as
# designed under the image's real shell and utilities:
#   empty prior -> sentinel + reboot marker; non-empty prior -> exact restore;
#   empty writes refused; post-reboot verification clears the marker only on exact empty.
# Invoked by tests/verify_image.sh as:
#   docker run --entrypoint /bin/bash <image> <this file>
set -eu
set -o pipefail

export HALOW_STATE_DIR=/tmp/_halow_sentinel_state
export HALOW_FW_SYSFS_PATH=/tmp/_halow_sentinel_node
rm -rf "$HALOW_STATE_DIR" "$HALOW_FW_SYSFS_PATH"
: > "$HALOW_FW_SYSFS_PATH"

# shellcheck source=/dev/null
. /usr/lib/halow/common.sh
# shellcheck source=/dev/null
. /usr/lib/halow/ownership.sh
# shellcheck source=/dev/null
. /usr/lib/halow/module_load.sh

halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

fails=0
check() { # check <description> <command...>
    local d="$1"; shift
    if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fails=$((fails + 1)); fi
}
eq() { [ "$1" = "$2" ]; }

echo "-- empty prior -> sentinel, reboot marker, active marker cleared --"
halow_set_firmware_search_path /data/halow_fw
check "node holds the add-on path" eq "$(cat "$HALOW_FW_SYSFS_PATH")" /data/halow_fw
halow_restore_firmware_search_path
check "node holds the sentinel" eq "$(cat "$HALOW_FW_SYSFS_PATH")" /run/halow-firmware-search-disabled
check "active marker cleared" bash -c '! [ -e "$0/owns/fw_search_path" ]' "$HALOW_STATE_DIR"
check "reboot-required marker held" [ -e "$HALOW_STATE_DIR/owns/firmware_path_reboot_required" ]
check "no byte beyond the sentinel text was written (no NUL, no newline)" eq "$(wc -c < "$HALOW_FW_SYSFS_PATH" | tr -d ' ')" "$(printf '%s' /run/halow-firmware-search-disabled | wc -c | tr -d ' ')"

echo "-- verification refuses while the sentinel is still installed --"
if halow_verify_fw_search_path_rebooted_clean; then check "verification must fail while the sentinel is installed" false; else check "verification failed as required" true; fi
check "reboot-required marker KEPT after the failed verification" [ -e "$HALOW_STATE_DIR/owns/firmware_path_reboot_required" ]

echo "-- simulated post-reboot exact-empty node -> verification clears the marker --"
: > "$HALOW_FW_SYSFS_PATH"
halow_verify_fw_search_path_rebooted_clean
check "reboot-required marker cleared only now" bash -c '! [ -e "$0/owns/firmware_path_reboot_required" ]' "$HALOW_STATE_DIR"

echo "-- BusyBox od exits 0 on an unreadable file (GNU od does not): verification must STILL fail closed and keep the marker for a missing node, a directory, and NUL / multi-byte content --"
halow_own_mark "firmware_path_reboot_required"
_real_node="$HALOW_FW_SYSFS_PATH"
for _bad in /tmp/_halow_does_not_exist /tmp; do
    HALOW_FW_SYSFS_PATH="$_bad"
    if halow_verify_fw_search_path_rebooted_clean; then check "verification must fail for unreadable/non-regular node $_bad" false; else check "verification failed for $_bad" true; fi
    check "reboot-required marker KEPT for $_bad" [ -e "$HALOW_STATE_DIR/owns/firmware_path_reboot_required" ]
done
HALOW_FW_SYSFS_PATH="$_real_node"
printf '\0' > "$HALOW_FW_SYSFS_PATH"
if halow_verify_fw_search_path_rebooted_clean; then check "a NUL byte must NOT verify as empty" false; else check "a NUL byte is rejected under BusyBox od" true; fi
printf '\n\n' > "$HALOW_FW_SYSFS_PATH"
if halow_verify_fw_search_path_rebooted_clean; then check "two newlines must NOT verify as empty" false; else check "two newlines are rejected under BusyBox od" true; fi
printf '\n' > "$HALOW_FW_SYSFS_PATH"
if halow_verify_fw_search_path_rebooted_clean; then check "exactly one newline verifies as empty" true; else check "exactly one newline must verify as empty" false; fi
check "marker cleared only after the byte-exact pass" bash -c '! [ -e "$0/owns/firmware_path_reboot_required" ]' "$HALOW_STATE_DIR"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- non-empty prior -> exact restoration, no sentinel, no reboot marker --"
printf '%s' /some/pre-existing/path > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path /data/halow_fw
halow_restore_firmware_search_path
check "exact prior restored" eq "$(cat "$HALOW_FW_SYSFS_PATH")" /some/pre-existing/path
check "no reboot-required marker" bash -c '! [ -e "$0/owns/firmware_path_reboot_required" ]' "$HALOW_STATE_DIR"

echo "-- an empty write is refused and leaves the node untouched --"
if halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" ""; then check "empty write must be refused" false; else check "empty write refused" true; fi
check "node untouched by the refused write" eq "$(cat "$HALOW_FW_SYSFS_PATH")" /some/pre-existing/path


echo "-- hostapd_s1g is started with the environment it inherited: through the REAL halow_start_hostapd a stand-in records its PATH and tries to resolve the removed helper program by bare name; neither the artifacts directory nor any helper may be found --"
# shellcheck source=/dev/null
. /usr/lib/halow/hostapd_config.sh
mkdir -p /tmp/_hs_state; export HALOW_STATE_DIR=/tmp/_hs_state
cat > /tmp/_hs_fake_hostapd.sh <<'FAKE'
#!/usr/bin/env bash
{ echo "child-path=$PATH"; sh -c 'command -v morse_cli >/dev/null && echo CHILD_RESOLVES_HELPER || echo CHILD_DOES_NOT_RESOLVE_HELPER'; } > /tmp/_hs_result 2>&1
sleep 3
FAKE
chmod +x /tmp/_hs_fake_hostapd.sh
: > /tmp/_hs_conf
_hs_path_before="$PATH"
halow_hostapd_pre_start_check /tmp/_hs_conf >/dev/null 2>&1 || true
halow_start_hostapd /tmp/_hs_fake_hostapd.sh /tmp/_hs_log /tmp/_hs_conf || true
sleep 1
check "the child's PATH is the PATH the launcher inherited" grep -qxF "child-path=$_hs_path_before" /tmp/_hs_result
check "the artifacts directory is not on the child's PATH" bash -c '! grep -qF /opt/halow/artifacts /tmp/_hs_result'
# Note: in the image no executable of the removed helper's name exists anywhere, so the
# next check is vacuous here (it is always true). The discriminating lines are the child-path
# equality and the no-artifacts-directory check above; the same check is meaningful in
# tests/test_hostapd_config.sh, where a canary executable of that name is placed in the
# artifacts directory.
check "a shell started by the child resolves no helper program by bare name (vacuous in the image)" grep -qx "CHILD_DOES_NOT_RESOLVE_HELPER" /tmp/_hs_result
check "the image carries no copy of the removed helper program" bash -c '! test -e /opt/halow/artifacts/morse_cli'
check "the calling shell's own PATH was not changed" test "$PATH" = "$_hs_path_before"
kill "${HALOW_LAST_STARTED_PID:-0}" 2>/dev/null || true
rm -rf /tmp/_hs_state /tmp/_hs_fake_hostapd.sh /tmp/_hs_result /tmp/_hs_conf /tmp/_hs_log
rm -rf "$HALOW_STATE_DIR" "$HALOW_FW_SYSFS_PATH"
if [ "$fails" -ne 0 ]; then echo "image_sentinel_check: $fails FAILED"; exit 1; fi
echo "image_sentinel_check: all passed"
