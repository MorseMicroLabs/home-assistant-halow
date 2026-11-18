#!/usr/bin/env bash
# Tests that `run`'s/`rollback.sh`'s OWN actual calling pattern for
# halow_set_firmware_search_path / halow_restore_firmware_search_path —
# `if cmd; then rc=0; else rc=$?; fi` — genuinely survives and executes its own
# follow-up logic under the REAL shell options `/usr/bin/bashio` sets (confirmed by
# reading that file directly inside the real built image, 2026-10-20): errexit,
# errtrace, nounset, pipefail, and `inherit_errexit`. Every other test file in this
# suite is sourced by run_tests.sh WITHOUT these options active, so none of them can
# actually prove this property.
#
# A live test incident found the ORIGINAL, now-fixed pattern — a bare
# (non-conditional) call immediately followed by `case $?`/`rc=$?` — silently aborts the
# whole script under these exact options, before the very next line ever runs, skipping
# ownership cleanup and fail()'s own rollback trigger entirely.
#
# Important bash semantic this test's own design depends on, confirmed empirically
# while writing it (not assumed): wrapping a function call in `if cmd; then ... else
# ... fi` suspends `errexit` for EVERYTHING that call does internally too, recursively
# through any further function calls it makes — not just for the outermost call itself.
# This means testing these two functions by calling them the exact way `run`/
# `rollback.sh` now do (if-wrapped) is the right, representative test of the real fix;
# it does NOT, and cannot, separately prove that every nested bare call inside them
# would also be safe if invoked some other way — that is a distinct, secondary (and
# unavoidable, since `halow_sysfs_write_with_remount` is a 2/3-way-return function)
# property, already separately hardened for defence-in-depth (see module_load.sh's own
# internal `if cmd; then ... else ... fi` calls) and covered functionally, under the
# ordinary (non-errexit) test harness, by test_module_load.sh.
#
# Each scenario runs a small, disposable child script (never a nested, multiply-escaped
# inline `bash -c '...'` — this project's own repeated, documented experience is that
# nested shell-quoting across layers silently mangles `$` expansions) with the same
# shell options bashio sets, calling the function under test exactly the if-wrapped way
# `run`/`rollback.sh` themselves do.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_errexit_safety =="
halow_test_setup

CHILD_SCRIPT="$HALOW_TEST_TMP/errexit_child.sh"

echo "-- halow_set_firmware_search_path, called the exact if-wrapped way run.sh now does, survives, logs its own 'could not write' line, and clears ownership, when the remount fails — the EXACT sequence a live-device test attempt found skipped entirely under the ORIGINAL, now-fixed bare-call pattern --"
: > "$HALOW_FW_SYSFS_PATH"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
halow_sys_mount_mode() { printf "ro"; }
halow_sys_remount() { return 1; }
if halow_set_firmware_search_path "/data/halow_fw"; then
    _status=0
else
    _status=\$?
fi
echo "STATUS=\$_status"
if halow_own_check "fw_search_path"; then
    echo "OWNERSHIP_STILL_HELD"
else
    echo "OWNERSHIP_CLEARED"
fi
echo SURVIVED
CHILD_EOF
_out="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "the child script survived to its own final echo" \
    grep -qF SURVIVED <<< "$_out"
assert_success "halow_set_firmware_search_path itself returned 1 (reached its own return statement)" \
    grep -qF 'STATUS=1' <<< "$_out"
assert_success "the function's own 'could not write' log line was actually reached and printed (proof the case statement after the internal failing call ran)" \
    grep -qF 'could not write' <<< "$_out"
assert_success "ownership was correctly cleared by the code that runs AFTER the internal failing call" \
    grep -qF OWNERSHIP_CLEARED <<< "$_out"

echo "-- halow_restore_firmware_search_path, called the same if-wrapped way rollback.sh now does, survives and completes its own ownership-clearing logic on a stale 'prepared' marker --"
: > "$HALOW_FW_SYSFS_PATH"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
# Hermetic: never depend on the test host's real /proc/mounts (WSL's /sys is rw, which the
# fail-closed defensive branch now correctly refuses).
halow_sys_mount_mode() { printf "ro"; }
halow_sys_remount() { return 0; }
halow_own_mark "fw_search_path" "\$(printf 'prepared\n\n/data/halow_fw')"
if halow_restore_firmware_search_path; then
    _status=0
else
    _status=\$?
fi
echo "STATUS=\$_status"
if halow_own_check "fw_search_path"; then
    echo "OWNERSHIP_STILL_HELD"
else
    echo "OWNERSHIP_CLEARED"
fi
echo SURVIVED
CHILD_EOF
_out2="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "the child script survived" \
    grep -qF SURVIVED <<< "$_out2"
assert_success "restore returned 0" \
    grep -qF 'STATUS=0' <<< "$_out2"
assert_success "ownership was cleared" \
    grep -qF OWNERSHIP_CLEARED <<< "$_out2"

echo "-- halow_dnsmasq_determine_outcome, called bare exactly as halow_start_dnsmasq/halow_teardown_dnsmasq themselves do, survives and correctly sets HALOW_DNSMASQ_OUTCOME=confirmed_absent on the NORMAL first-startup/post-clean-stop path — found broken here by a code review (network_backend.sh's own internal halow_dnsmasq_identity_matches / halow_find_dnsmasq_by_identity calls), not self-identified --"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/network_backend.sh"
# No pidfile, and nothing in this disposable test environment is a real dnsmasq
# process -- the real (unstubbed) scan genuinely finds nothing, exactly the NORMAL
# "confirmed absent" case on first startup or after any clean stop, which is exactly
# the path the code review found this function aborts on.
halow_dnsmasq_determine_outcome "${HALOW_STATE_DIR}/dnsmasq.conf"
echo "OUTCOME=\$HALOW_DNSMASQ_OUTCOME"
echo SURVIVED
CHILD_EOF
_out4="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "the child script survived (did not abort on the confirmed-absent path)" \
    grep -qF SURVIVED <<< "$_out4"
assert_success "HALOW_DNSMASQ_OUTCOME was correctly set to confirmed_absent" \
    grep -qF 'OUTCOME=confirmed_absent' <<< "$_out4"

echo "-- halow_hostapd_determine_outcome, called bare exactly as halow_hostapd_pre_start_check/halow_stop_hostapd themselves do, survives and correctly sets HALOW_HOSTAPD_OUTCOME=confirmed_absent on the same NORMAL path --"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/hostapd_config.sh"
halow_hostapd_determine_outcome "${HALOW_STATE_DIR}/hostapd_s1g.conf"
echo "OUTCOME=\$HALOW_HOSTAPD_OUTCOME"
echo SURVIVED
CHILD_EOF
_out5="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "the child script survived (did not abort on the confirmed-absent path)" \
    grep -qF SURVIVED <<< "$_out5"
assert_success "HALOW_HOSTAPD_OUTCOME was correctly set to confirmed_absent" \
    grep -qF 'OUTCOME=confirmed_absent' <<< "$_out5"

echo "-- halow_load_morse, called the exact if-wrapped way run's own real call site does, survives and correctly reports failure (never a silent abort) when its own new mac80211 dependency-load step fails — the new call chain this change's mac80211 fix adds --"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_ARTIFACTS_DIR="$HALOW_TEST_TMP"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
: > "\$HALOW_ARTIFACTS_DIR/morse.ko"
lsmod() { true; }
modprobe() { return 1; }
if halow_load_morse "\$HALOW_ARTIFACTS_DIR/morse.ko"; then
    _status=0
else
    _status=\$?
fi
echo "STATUS=\$_status"
if halow_own_check "module_mac80211"; then
    echo "MAC80211_OWNED"
else
    echo "MAC80211_NOT_OWNED"
fi
echo SURVIVED
CHILD_EOF
_out6="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "the child script survived to its own final echo (no silent abort inside the new mac80211 call chain)" \
    grep -qF SURVIVED <<< "$_out6"
assert_success "halow_load_morse itself returned 1 (reached its own return statement after the dependency failure)" \
    grep -qF 'STATUS=1' <<< "$_out6"
assert_success "no mac80211 ownership was left behind when its own modprobe failed" \
    grep -qF MAC80211_NOT_OWNED <<< "$_out6"

echo "-- halow_restore_firmware_search_path on the EMPTY-prior (inert sentinel) path, called the if-wrapped way rollback.sh does, under bashio's real shell options: the success branch installs the sentinel, sets the reboot-required marker and clears active ownership; the failure branch (remount refused) survives and keeps ownership --"
for _scenario in success remount_fails; do
    : > "$HALOW_FW_SYSFS_PATH"
    rm -rf "$HALOW_STATE_DIR/owns"
    if [ "$_scenario" = "success" ]; then
        _remount_body='return 0'; _mode='rw'
    else
        _remount_body='return 1'; _mode='ro'
    fi
    cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
halow_sys_mount_mode() { printf "$_mode"; }
halow_sys_remount() { $_remount_body; }
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "\$(printf 'applied\n\n/data/halow_fw')"
if halow_restore_firmware_search_path; then
    _status=0
else
    _status=\$?
fi
echo "STATUS=\$_status"
if halow_own_check "fw_search_path"; then echo "ACTIVE_HELD"; else echo "ACTIVE_CLEARED"; fi
if halow_own_check "firmware_path_reboot_required"; then echo "REBOOT_MARKER_HELD"; else echo "REBOOT_MARKER_ABSENT"; fi
echo "NODE=\$(cat "$HALOW_FW_SYSFS_PATH")"
echo SURVIVED
CHILD_EOF
    _outs="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
    assert_success "[$_scenario] the child script survived to its own final echo" \
        grep -qF SURVIVED <<< "$_outs"
    if [ "$_scenario" = "success" ]; then
        assert_success "[success] restore returned 0" grep -qF 'STATUS=0' <<< "$_outs"
        assert_success "[success] active ownership cleared" grep -qF ACTIVE_CLEARED <<< "$_outs"
        assert_success "[success] reboot-required marker set" grep -qF REBOOT_MARKER_HELD <<< "$_outs"
        assert_success "[success] the node holds the sentinel" grep -qF "NODE=$HALOW_FW_SEARCH_SENTINEL" <<< "$_outs"
    else
        assert_success "[remount_fails] restore returned 1 (reached its own return statement)" grep -qF 'STATUS=1' <<< "$_outs"
        assert_success "[remount_fails] active ownership KEPT" grep -qF ACTIVE_HELD <<< "$_outs"
        assert_success "[remount_fails] no reboot-required marker" grep -qF REBOOT_MARKER_ABSENT <<< "$_outs"
        assert_success "[remount_fails] the node is untouched" grep -qF "NODE=/data/halow_fw" <<< "$_outs"
    fi
done
rm -rf "$HALOW_STATE_DIR/owns"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- halow_verify_fw_search_path_rebooted_clean under bashio's real shell options: a non-empty node returns 1 (survives, marker KEPT); an empty node returns 0 (marker cleared) --"
for _scenario in nonempty empty; do
    rm -rf "$HALOW_STATE_DIR/owns"
    if [ "$_scenario" = "nonempty" ]; then _node="$HALOW_FW_SEARCH_SENTINEL"; else _node=""; fi
    cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
printf '%s' "$_node" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "firmware_path_reboot_required"
if halow_verify_fw_search_path_rebooted_clean; then
    _status=0
else
    _status=\$?
fi
echo "STATUS=\$_status"
if halow_own_check "firmware_path_reboot_required"; then echo "MARKER_HELD"; else echo "MARKER_CLEARED"; fi
echo SURVIVED
CHILD_EOF
    _outv="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
    assert_success "[$_scenario] the child script survived" grep -qF SURVIVED <<< "$_outv"
    if [ "$_scenario" = "nonempty" ]; then
        assert_success "[nonempty] verification returned 1" grep -qF 'STATUS=1' <<< "$_outv"
        assert_success "[nonempty] marker KEPT" grep -qF MARKER_HELD <<< "$_outv"
    else
        assert_success "[empty] verification returned 0" grep -qF 'STATUS=0' <<< "$_outv"
        assert_success "[empty] marker cleared" grep -qF MARKER_CLEARED <<< "$_outv"
    fi
done
rm -rf "$HALOW_STATE_DIR/owns"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- PIPEFAIL + grep -q false negative (the live-device test mac80211 incident): a loaded module must be reported loaded even when lsmod keeps writing after the matching line (SIGPIPE) --"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
# A stub lsmod whose FIRST line is the module being looked for and which then keeps writing a
# lot more: a reader that exits at the first match (grep -q) kills the writer with SIGPIPE,
# and under pipefail the pipeline then reports failure although grep matched. kmod's real
# lsmod behaves exactly like this (measured on the Green: 299/300 false negatives).
lsmod() {
    printf 'mac80211              696320  0\n'
    local i=0
    while [ "\$i" -lt 20000 ]; do
        printf 'padding_module_%05d 4096 0\n' "\$i" || return 141
        i=\$((i + 1))
    done
}
# 1) the OLD, broken pattern must be shown to give a false negative here (proves the harness
#    can detect the incident; if this ever prints OLD_PATTERN_OK the stub no longer reproduces it)
if lsmod | grep -q '^mac80211 '; then echo OLD_PATTERN_OK; else echo OLD_PATTERN_FALSE_NEGATIVE; fi
# 2) the fixed helpers
if halow_module_state mac80211; then echo "STATE_LOADED"; else echo "STATE_RC=\$?"; fi
if halow_module_loaded mac80211; then echo "LOADED_TRUE"; else echo "LOADED_FALSE"; fi
if halow_module_confirmed_absent mac80211; then echo "ABSENT_TRUE"; else echo "ABSENT_FALSE"; fi
if halow_module_state not_a_module; then echo "NOTMOD_LOADED"; else echo "NOTMOD_RC=\$?"; fi
# 3) unloading a module that rmmod could not remove must NOT be reported as confirmed absent
rmmod() { return 0; }
halow_own_mark "module_mac80211"
if halow_unload_one_module mac80211 module_mac80211; then echo "UNLOAD_CLAIMED_SUCCESS"; else echo "UNLOAD_REFUSED"; fi
if halow_own_check module_mac80211; then echo "OWNERSHIP_KEPT"; else echo "OWNERSHIP_CLEARED"; fi
echo SURVIVED
CHILD_EOF
_outp="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "child survived" grep -qF SURVIVED <<< "$_outp"
assert_success "the OLD lsmod|grep -q pattern really does give a false negative under pipefail+SIGPIPE (the stub reproduces the incident)" \
    grep -qF OLD_PATTERN_FALSE_NEGATIVE <<< "$_outp"
assert_success "halow_module_state reports the loaded module as loaded (rc 0) despite SIGPIPE" grep -qF STATE_LOADED <<< "$_outp"
assert_success "halow_module_loaded is true" grep -qF LOADED_TRUE <<< "$_outp"
assert_success "halow_module_confirmed_absent is false for a loaded module" grep -qF ABSENT_FALSE <<< "$_outp"
assert_success "an absent module is reported absent (rc 1)" grep -qF 'NOTMOD_RC=1' <<< "$_outp"
assert_success "unloading a module rmmod could not remove is NOT claimed successful (this was the dangerous direction of the bug)" \
    grep -qF UNLOAD_REFUSED <<< "$_outp"
assert_success "ownership is KEPT for a module that is still loaded" grep -qF OWNERSHIP_KEPT <<< "$_outp"
rm -rf "$HALOW_STATE_DIR/owns"

echo "-- END-TO-END incident reproduction: halow_ensure_mac80211_loaded and halow_load_morse with a SIGPIPE-prone lsmod must report success, keep ownership, and never unload a module that loaded correctly --"
_fake_ko="$HALOW_TEST_TMP/morse_fake.ko"; : > "$_fake_ko"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
LOADED="$HALOW_TEST_TMP/loaded_mods"; : > "\$LOADED"
RMMOD_LOG="$HALOW_TEST_TMP/rmmod_log"; : > "\$RMMOD_LOG"
# lsmod lists the most recently loaded module FIRST, then a long tail (like the real one), so
# a reader that exits at the first match kills the writer with SIGPIPE.
lsmod() {
    printf 'Module                  Size  Used by\n'
    local m i=0
    # newest first
    for m in \$(tac "\$LOADED"); do printf '%s 696320 0\n' "\$m"; done
    while [ "\$i" -lt 20000 ]; do
        printf 'padding_module_%05d 4096 0\n' "\$i" || return 141
        i=\$((i + 1))
    done
}
modprobe() { echo mac80211 >> "\$LOADED"; }          # loads mac80211 successfully, silently
insmod() { echo morse >> "\$LOADED"; }                # loads morse successfully
rmmod() { echo "\$1" >> "\$RMMOD_LOG"; }              # must NEVER be called for a good load
if halow_ensure_mac80211_loaded; then echo "ENSURE_RC=0"; else echo "ENSURE_RC=\$?"; fi
if halow_own_check module_mac80211; then echo "MAC80211_OWNED"; else echo "MAC80211_NOT_OWNED"; fi
: > "\$LOADED"; rm -rf "$HALOW_STATE_DIR/owns"
if halow_load_morse "$_fake_ko"; then echo "LOADMORSE_RC=0"; else echo "LOADMORSE_RC=\$?"; fi
if halow_own_check module_morse; then echo "MORSE_OWNED"; else echo "MORSE_NOT_OWNED"; fi
if halow_own_check module_mac80211; then echo "MAC80211_OWNED2"; else echo "MAC80211_NOT_OWNED2"; fi
echo "RMMOD_CALLS=\$(wc -l < "\$RMMOD_LOG" | tr -d ' ')"
echo SURVIVED
CHILD_EOF
_oute="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_success "child survived" grep -qF SURVIVED <<< "$_oute"
assert_success "ensure_mac80211_loaded reports success for a module that loaded (this exact check failed live)" grep -qF 'ENSURE_RC=0' <<< "$_oute"
assert_success "mac80211 ownership is recorded" grep -qF MAC80211_OWNED <<< "$_oute"
assert_success "load_morse reports success" grep -qF 'LOADMORSE_RC=0' <<< "$_oute"
assert_success "morse ownership is recorded" grep -qF 'MORSE_OWNED' <<< "$_oute"
assert_success "no module that loaded correctly was unloaded again (rmmod never called)" grep -qF 'RMMOD_CALLS=0' <<< "$_oute"
rm -rf "$HALOW_STATE_DIR/owns"

echo "-- regression guard, proving this test can actually fail: the SAME scenario as above, but with the ORIGINAL (pre-fix) bare-call pattern reconstructed inline, must be shown to abort before its own follow-up logic runs --"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR"
export HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/checksum.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
halow_sys_mount_mode() { printf "ro"; }
halow_sys_remount() { return 1; }
# The ORIGINAL, now-fixed pattern this whole file exists to guard against: a bare call
# immediately followed by reading \$? -- deliberately reconstructed here, once, to
# prove this test harness can actually detect the real incident, not merely pass by
# construction.
halow_set_firmware_search_path "/data/halow_fw"
_status=\$?
echo "STATUS=\$_status"
echo SURVIVED
CHILD_EOF
_out3="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
assert_failure "the ORIGINAL bare-call pattern does NOT reach its own follow-up echo lines (proving this test harness can genuinely detect the real incident, not just pass unconditionally)" \
    grep -qF SURVIVED <<< "$_out3"

# --- The manager's own libraries under the same options ------------------------------
# Every failure path below is driven to its end inside one strict child; each prints a
# marker only if execution reached the line after the call. The stub layer of
# helpers_lifecycle.sh stands in for the other subsystems.
echo "-- the lifecycle libraries under bashio's options: sourced inside a function, twice; every failure path returns instead of aborting --"
printf '1\n' > "$HALOW_IP_FORWARD_FILE"
printf '11111111-2222-3333-4444-555555555555\n' > "$HALOW_BOOT_ID_FILE"
mkdir -p "$HALOW_RUN_DIR"
cat > "$CHILD_SCRIPT" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_LIB_DIR="$HALOW_LIB_DIR"
export HALOW_BOOT_ID_FILE="$HALOW_BOOT_ID_FILE" HALOW_IP_FORWARD_FILE="$HALOW_IP_FORWARD_FILE" HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH"
export HL_DIR="$HALOW_TEST_TMP/hl"; mkdir -p "\$HL_DIR"; : > "\$HL_DIR/calls.log"; : > "\$HL_DIR/state.log"
. "$(pwd)/helpers_lifecycle.sh"
loader() { hl_child_load; }
loader
loader
echo RESOURCED
. "$HALOW_LIB_DIR/libs.sh"
if halow_source_all_libs "$HALOW_TEST_TMP/no-such-dir"; then echo LIBS_OK; else echo "LIBS_MISSING_REPORTED"; fi
if halow_boot_id_changed; then r=0; else r=\$?; fi; echo "BOOT_RC=\$r"
halow_own_mark module_morse
HL_UNDO_FAIL="module_morse"
if halow_rollback; then echo ROLLBACK_OK; else echo "ROLLBACK_FAILED_RETURNED"; fi
if halow_reconcile; then echo RECONCILE_OK; else echo "RECONCILE_FAILED_RETURNED"; fi
export HALOW_OPT_WIFI_SSID="" HALOW_OPT_REGION="AU"
halow_options_load
if halow_options_validate; then echo OPTIONS_OK; else echo "OPTIONS_FAILED_RETURNED=\$HALOW_CFG_ERROR_OPTION"; fi
if halow_lifecycle_should_retry AP_DIED 5; then echo RETRY; else echo "NO_RETRY_RETURNED"; fi
if halow_refusal_present; then echo REFUSAL_PRESENT; else echo NO_REFUSAL; fi
if halow_manager_ip_forward_check; then echo FWD_OK; else echo FWD_FAIL; fi
printf '0\n' > "\$HALOW_IP_FORWARD_FILE"
if halow_manager_ip_forward_check; then echo FWD_OK2; else echo "FWD_ZERO_RETURNED"; fi
echo SURVIVED
CHILD_EOF
_outm="$(bash "$CHILD_SCRIPT" 2>&1 || true)"
for m in RESOURCED LIBS_MISSING_REPORTED BOOT_RC=2 ROLLBACK_FAILED_RETURNED RECONCILE_FAILED_RETURNED OPTIONS_FAILED_RETURNED=wifi_ssid NO_RETRY_RETURNED NO_REFUSAL FWD_OK FWD_ZERO_RETURNED SURVIVED; do
    assert_success "strict child reached: $m" grep -qxF "$m" <<< "$_outm"
done

halow_test_teardown
echo "test_errexit_safety: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
