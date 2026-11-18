#!/usr/bin/env bash
# Tests module_load.sh's pure, testable logic: the BCF match/no-match decision
# (halow_check_bcf_match) shared between real driver-log parsing and this test harness.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_module_load =="
halow_test_setup

# The full matrix (name/size/CRC-32, anchor, wrap, successive starts) is in
# test_bcf_verification.sh; here the basic accept/reject contract, with the driver's real
# record format and the shipped board file.
_bcf="$(cd .. && pwd)/artifacts/bcf/bcf_boardtype_0807.bin"
_anchor="[  300.543372] morse micro driver registration. Version 0-rel_mm8108_2_1_0_2026_Jul_01"
_good="[  300.561563] morse_usb 1-1:1.0: Loaded BCF from morse/bcf_boardtype_0807.bin, size 2510, crc32 0xc8af8c0d"
# Labs release tree: the board file is a staged binary artifact (not committed); the
# assertion that needs the real file runs only where it is staged.
if [ -f "$_bcf" ]; then
assert_success "a log with the driver's Loaded-BCF record for the placed board file is recognised" \
    halow_check_bcf_match "$(printf '%s\n%s\n' "$_anchor" "$_good")" "$_bcf"
else
    echo "  SKIP: $_bcf is not staged; 1 assertion not run"
fi

assert_failure "a log reporting no matching BCF is fail-closed" \
    halow_check_bcf_match "morse: no matching bcf for this board type" "$_bcf"

assert_failure "the old free-text 'bcf ... loaded successfully' line is no longer accepted as evidence" \
    halow_check_bcf_match "morse: bcf_boardtype_0807.bin loaded successfully" "$_bcf"

assert_failure "an empty/unrecognised log is treated fail-closed, never assumed success" \
    halow_check_bcf_match "" "$_bcf"

assert_failure "unrelated log text is treated fail-closed" \
    halow_check_bcf_match "some unrelated kernel message" "$_bcf"

# --- Regression test: a stale success from an earlier, unrelated load must never be
# mistaken for this load's own result once the caller correctly scopes its input to
# "dmesg since this load" (common.sh's own halow_dmesg_watermark/halow_dmesg_since) —
# this is the actual, full fix, not just the pure-function check in isolation above. ---
dmesg() { cat "$HALOW_TEST_TMP/fake_dmesg.log" 2>/dev/null; }
: > "$HALOW_TEST_TMP/fake_dmesg.log"
printf '%s\n%s\n' "$_anchor" "$_good" >> "$HALOW_TEST_TMP/fake_dmesg.log"
watermark="$(halow_dmesg_watermark)"
echo "[  400.000001] morse: no matching bcf for this board type" >> "$HALOW_TEST_TMP/fake_dmesg.log"
scoped="$(halow_dmesg_since "$watermark")"
assert_failure "a genuine new failure is correctly detected even though an earlier, stale success exists in the full log" \
    halow_check_bcf_match "$scoped" "$_bcf"
unset -f dmesg

echo "== test_module_load (ownership discipline, stubbed insmod/rmmod/lsmod) =="
halow_test_setup

ko="$HALOW_ARTIFACTS_DIR/morse.ko"
: > "$ko"
# File-based state, not a shell variable: halow_load_morse pipes insmod's own output
# through halow_log_pipe (`insmod ... | halow_log_pipe`), and bash runs the left side
# of a pipe in a SUBSHELL — a shell variable `insmod` itself mutated would never be
# visible back in this script. A state file survives across that subshell boundary; a
# shell variable would not (found as a real test-authoring defect while writing this
# very test, not assumed correct without running it).
state_file="$HALOW_TEST_TMP/morse_loaded"
echo 0 > "$state_file"
# mac80211 reported already loaded throughout this block -- this block is specifically
# about MORSE's own ownership discipline (unchanged by this change's separate mac80211
# dependency fix, covered in its own dedicated block below), so halow_ensure_mac80211_loaded
# must return immediately without ever touching modprobe here.
insmod() { case "$1" in *morse.ko) echo 1 > "$state_file" ;; esac; return 0; }
lsmod() { echo "mac80211 500000 1 morse"; [ "$(cat "$state_file")" = "1" ] && echo "morse 12345 0" || true; }
rmmod() { case "$1" in morse) echo 0 > "$state_file" ;; esac; return 0; }

assert_success "morse loads successfully with a working insmod/lsmod" \
    halow_load_morse "$ko"
assert_success "ownership is recorded immediately on successful insmod" \
    halow_own_check "module_morse"

# Simulate insmod succeeding but the module never actually appearing in lsmod — a real
# defect class this change named: ownership must already be recorded (so the explicit
# unload path below can find and unload it), and must only be CLEARED once rmmod is
# confirmed to have actually removed it.
halow_own_clear "module_morse"
echo 0 > "$state_file"
insmod() { echo 1 > "$state_file"; return 0; }   # "succeeds" but...
lsmod() { echo "mac80211 500000 1 morse"; true; }  # ...never reports morse as loaded (mac80211 still present)
RMMOD_CALLED=0
rmmod() { RMMOD_CALLED=$((RMMOD_CALLED + 1)); case "$1" in morse) MORSE_LOADED=0 ;; esac; return 0; }

assert_failure "load reports failure when lsmod never confirms the module" \
    halow_load_morse "$ko"
assert_eq "1" "$RMMOD_CALLED" "the explicit unload path was invoked after the verification failure"
assert_failure "ownership is cleared once rmmod is confirmed to have actually removed it" \
    halow_own_check "module_morse"

# Simulate rmmod failing to actually unload the module (lsmod still reports it
# afterwards) — ownership must be KEPT, not cleared, so cleanup keeps retrying.
halow_own_mark "module_morse"
MORSE_LOADED=1
rmmod() { RMMOD_CALLED=$((RMMOD_CALLED + 1)); return 0; }   # "succeeds" but doesn't actually unload
lsmod() { echo "mac80211 500000 1 morse"; echo "morse 12345 0"; }   # still loaded afterwards
halow_unload_modules
assert_success "ownership is NOT cleared when rmmod does not actually remove the module" \
    halow_own_check "module_morse"

echo "== test_module_load (firmware search-path sysfs set/restore) =="
halow_test_setup
# Stubbed "always already rw, nothing to remount" for this entire block -- these tests
# predate halow_sysfs_write_with_remount and are about the set/restore/ownership logic
# layered on top of it, not the remount mechanism itself (covered separately, below, and
# in the dedicated remount-bracketed-write block further down). Never depends on the
# real test host's own /proc/mounts: a real, unstubbed halow_sys_mount_mode found no
# `/sys` entry at all in one real reviewer's own test environment (Git Bash on Windows,
# unlike this project's own WSL2/Ubuntu execution environment, which does have one),
# which made this entire block fail closed there -- found by a code review, not
# self-identified; every other block in this file already stubs this, this one just
# hadn't been updated when halow_set_firmware_search_path/halow_restore_firmware_search_path
# were changed to route through it.
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

assert_file_exists "$HALOW_FW_SYSFS_PATH" "the fake sysfs node exists before any change (simulating a real, always-present kernel parameter)"
assert_eq "" "$(cat "$HALOW_FW_SYSFS_PATH")" "the fake sysfs node starts out empty, like the real kernel default"

assert_success "fresh set succeeds" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" "the sysfs node now holds the new search path"
assert_success "ownership recorded after a successful set" \
    halow_own_check "fw_search_path"

assert_success "re-setting the SAME path is idempotent (does not disturb the tracked prior value)" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" "the sysfs node is unchanged after the idempotent re-set"

assert_success "restore succeeds" \
    halow_restore_firmware_search_path
# The recorded prior value here is EMPTY, which cannot be written back exactly on the
# test Green (see halow_sysfs_write_with_remount's header), so the development-build-only inert
# sentinel is installed instead -- NOT an exact restoration; the dedicated sentinel block
# at the end of this file covers that mechanism in depth.
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" "an empty prior value is replaced by the inert sentinel, never by an intermediate value and never by an attempted empty write"
assert_failure "active ownership cleared after a successful (sentinel) restore" \
    halow_own_check "fw_search_path"
assert_success "exact restoration is recorded as still pending (firmware_path_reboot_required held), never as complete" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"

assert_success "restoring again when nothing is owned is a safe no-op" \
    halow_restore_firmware_search_path

# Regression test: a non-empty PRIOR value (simulating some other, legitimate reason the
# node was already set before this package ever touched it) must be captured and
# restored exactly, never clobbered to empty.
printf '%s' "/some/other/pre-existing/path" > "$HALOW_FW_SYSFS_PATH"
assert_success "set succeeds over a non-empty pre-existing value" \
    halow_set_firmware_search_path "/data/halow_fw"
halow_restore_firmware_search_path
assert_eq "/some/other/pre-existing/path" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "restore puts back the exact pre-existing value, not empty"

# Regression test: if the write never actually takes effect, the function must fail
# closed and must NOT leave ownership recorded — a real-world analogue of /sys being
# unexpectedly read-only. A directory in place of the sysfs file makes the write
# redirection fail reliably regardless of which user runs this test (unlike chmod, whose
# effect on root is platform/environment-dependent).
rm -f "$HALOW_FW_SYSFS_PATH"
mkdir -p "$HALOW_FW_SYSFS_PATH"
assert_failure "set fails closed when the write does not take effect (e.g. a read-only sysfs node)" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_failure "no ownership is left behind after a failed set" \
    halow_own_check "fw_search_path"
rm -rf "$HALOW_FW_SYSFS_PATH"
: > "$HALOW_FW_SYSFS_PATH"

# Regression test (hardening, this change): if some OTHER actor changes the sysfs node
# after this package set it — a real possibility for genuinely global, un-namespaced
# kernel state — restore must refuse to overwrite that foreign, newer value, must fail
# visibly, and must keep ownership so the conflict surfaces rather than silently losing
# whatever the other actor wrote.
assert_success "fresh set succeeds (foreign-change scenario setup)" \
    halow_set_firmware_search_path "/data/halow_fw"
printf '%s' "/someone/elses/value" > "$HALOW_FW_SYSFS_PATH"
assert_failure "restore refuses to overwrite a value changed by another actor since this package's own set" \
    halow_restore_firmware_search_path
assert_eq "/someone/elses/value" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the foreign value is left completely untouched, never overwritten"
assert_success "ownership is NOT cleared when a foreign concurrent change is detected" \
    halow_own_check "fw_search_path"
# Clean up directly (the real mechanism is deliberately refusing to touch this node).
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

# Regression test (hardening, this change): if the restore write's OWN read-back shows
# the node did not actually end up holding the prior value (e.g. a race, or the write
# being silently rejected/truncated) — distinct from a failed INITIAL set, already
# covered above — the function must fail closed and must NOT clear ownership. A plain
# `printf ... > file` stub does not work for this: bash sets up the `>` redirection
# itself (truncating the file) before invoking printf at all, regardless of what a
# stubbed printf function does or returns — found as a real test-authoring defect while
# writing this very test, not assumed correct without running it. Instead, `cat` (used
# for every read in these two functions) is stubbed with a call counter so only the
# THIRD call — the post-write read-back specifically — returns a value that does not
# match what was actually written, while the two calls before it (the ownership-marker
# read and the pre-write foreign-change check) see the real file content. The counter
# itself MUST be file-based, not a shell variable: `current="$(cat ...)"` runs the stub
# inside a command-substitution SUBSHELL, so a plain variable increment is lost the
# instant that subshell exits — the exact same class of defect this project's own test
# suite already found once before (an insmod-pipeline subshell losing a shell-variable
# mutation), not assumed correct without running it here too.
assert_success "fresh set succeeds (failed-restoration scenario setup)" \
    halow_set_firmware_search_path "/data/halow_fw"
_cat_call_file="$HALOW_TEST_TMP/cat_call_count"
echo 0 > "$_cat_call_file"
cat() {
    local n
    n=$(( $(command cat "$_cat_call_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$_cat_call_file"
    if [ "$n" -eq 3 ]; then
        printf '%s' "unexpectedly-different-value"
    else
        command cat "$@"
    fi
}
halow_restore_firmware_search_path
_restore_status=$?
unset -f cat
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_restore_status" -ne 0 ]; then
    echo "  ok: restore fails closed when its own post-write read-back does not match the prior value"
else
    echo "  FAIL: restore fails closed when its own post-write read-back does not match the prior value (got success)"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_success "ownership is NOT cleared when the restore read-back mismatches" \
    halow_own_check "fw_search_path"
# Clean up: the real (unstubbed) write did actually go through — the sysfs node
# genuinely holds the sentinel now (the prior value was empty), only the STUBBED read-back
# claimed otherwise — so reconcile ownership with that real state directly. The
# reboot-required marker must NOT have been set, since the (stubbed) readback never
# confirmed the sentinel.
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the real sysfs node did receive the sentinel write — only this test's own stubbed read-back disagreed"
assert_failure "no reboot-required marker is set when the readback could not confirm the sentinel" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"
# Re-source, never `unset -f`, to restore the REAL halow_sys_mount_mode/
# halow_sys_remount for the block below, which tests them directly: redefining a
# function (by sourcing again) correctly restores it, but `unset -f` on a function this
# file itself has redefined removes it entirely with no original left to fall back to —
# the exact "unset -f silently deletes the real production function" class of defect
# this project's own test suite has already hit more than once (found again here while
# fixing the hermeticity gap above, not self-identified the first time either).
# shellcheck source=/dev/null
. "$HALOW_LIB_DIR/module_load.sh"

echo "== test_module_load (halow_sys_mount_mode — direct parsing unit tests) =="
# Genuinely unit-tests the parsing logic itself, not merely stubbing it away — a
# disposable fake /proc/mounts-format file, never the real test host's own.
_fake_mounts="$HALOW_TEST_TMP/fake-proc-mounts"
printf 'tmpfs /run tmpfs rw,nosuid,nodev,size=1024k 0 0\nsysfs /sys sysfs ro,nosuid,nodev,noexec,relatime 0 0\n' > "$_fake_mounts"
assert_eq "ro" "$(HALOW_PROC_MOUNTS="$_fake_mounts" halow_sys_mount_mode)" \
    "halow_sys_mount_mode correctly parses a read-only /sys entry from a realistic multi-line mounts file"
printf 'sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0\n' > "$_fake_mounts"
assert_eq "rw" "$(HALOW_PROC_MOUNTS="$_fake_mounts" halow_sys_mount_mode)" \
    "halow_sys_mount_mode correctly parses a read-write /sys entry"
printf 'tmpfs /run tmpfs rw 0 0\n' > "$_fake_mounts"
assert_eq "" "$(HALOW_PROC_MOUNTS="$_fake_mounts" halow_sys_mount_mode)" \
    "halow_sys_mount_mode prints nothing (never a guess) when /sys has no entry at all"
rm -f "$_fake_mounts"


echo "== test_module_load (halow_sys_remount uses BIND remounts only -- a plain remount flips the HOST's shared sysfs superblock; found live at a live-device test) =="
_mnt_log="$HALOW_TEST_TMP/mount_calls"; : > "$_mnt_log"
mount() { echo "$*" >> "$_mnt_log"; return 0; }
halow_sys_mount_mode() { printf '%s' "$_want_mode"; }
_want_mode=rw; halow_sys_remount rw
assert_eq "-o remount,bind,rw /sys" "$(sed -n 1p "$_mnt_log")" "remount to rw is a BIND remount (mount flag only), never a superblock remount"
_want_mode=ro; halow_sys_remount ro
assert_eq "-o remount,bind,ro /sys" "$(sed -n 2p "$_mnt_log")" "remount back to ro is a BIND remount too"
assert_success "no mount invocation ever lacks the 'bind' option" bash -c '! grep -v -F "bind" "$0" | grep -q .' "$_mnt_log"
_want_mode=ro; assert_failure "success still requires the read-back to show the requested mode" halow_sys_remount rw
assert_eq "-o remount,bind,ro /sys" "$(sed -n 4p "$_mnt_log")" "when the bind rw succeeded but the read-back stays ro (the host's superblock is read-only), the container's own mount flag is reverted to ro"
assert_eq "4" "$(wc -l < "$_mnt_log" | tr -d ' ')" "exactly one revert call (rw attempt + one revert), no retry loop"
_want_mode=rw; : > "$_mnt_log"; halow_sys_remount ro
assert_eq "1" "$(wc -l < "$_mnt_log" | tr -d ' ')" "a failed remount to ro makes no extra revert call"
assert_success "the production source contains no plain 'remount,\$want' form" \
    bash -c '! grep -n "remount,\$want\"" "$0"' "$HALOW_LIB_DIR/module_load.sh"
unset -f mount halow_sys_mount_mode
. "$HALOW_LIB_DIR/module_load.sh"

echo "== test_module_load (firmware search-path: the /sys remount-bracketed write path — the 2026-10-20 live regression) =="
# Regression coverage for the live finding that a plain write to
# /sys/module/firmware_class/parameters/path can fail ("Read-only file system") even
# with the needed capability held. halow_sys_mount_mode/halow_sys_remount are stubbed
# for every scenario below (never the real test host's own /sys or /proc/mounts,
# consistent with run_tests.sh's own "nothing here touches the real host filesystem"
# guarantee) — only halow_sysfs_write_with_remount's own bracketing logic, and its two
# callers' handling of every one of its return codes (0/1/3), is under test.

echo "-- command failure: /sys starts read-only and the remount-to-rw command itself fails --"
: > "$HALOW_FW_SYSFS_PATH"
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() { return 1; }
assert_failure "set fails closed when /sys is read-only and the remount-to-rw command fails" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_failure "no ownership is left behind when the remount-to-rw command fails" \
    halow_own_check "fw_search_path"
assert_eq "" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sysfs node is untouched -- a failed remount must never reach the write at all"
unset -f halow_sys_mount_mode halow_sys_remount

echo "-- write failure: the remount-to-rw succeeds, but the write itself still fails, and /sys is still correctly restored to read-only afterward --"
rm -f "$HALOW_FW_SYSFS_PATH"
mkdir -p "$HALOW_FW_SYSFS_PATH"   # a directory here makes the write redirection fail reliably
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    case "$1" in
        rw) _mount_mode="rw"; return 0 ;;
        ro) _mount_mode="ro"; return 0 ;;
    esac
    return 1
}
assert_failure "set fails closed when the remount-to-rw succeeds but the write itself still fails" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_eq "ro" "$_mount_mode" \
    "/sys is still correctly remounted back to read-only even though the write itself failed"
assert_failure "no ownership is left behind when the write itself fails" \
    halow_own_check "fw_search_path"
unset -f halow_sys_mount_mode halow_sys_remount
rm -rf "$HALOW_FW_SYSFS_PATH"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- full successful cycle: /sys starts read-only, is remounted read-write, written, verified, and restored to read-only -- exactly once each --"
_mount_mode="ro"
_remount_calls=0
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    _remount_calls=$((_remount_calls + 1))
    case "$1" in
        rw) _mount_mode="rw"; return 0 ;;
        ro) _mount_mode="ro"; return 0 ;;
    esac
    return 1
}
assert_success "set succeeds via an explicit bounded remount when /sys starts read-only" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sysfs node holds the new search path after the remount-bracketed write"
assert_eq "ro" "$_mount_mode" \
    "/sys is left read-only again after a successful remount-bracketed write -- never left writable"
assert_eq "2" "$_remount_calls" \
    "exactly one remount to rw and one back to ro occurred -- not zero, not more"
unset -f halow_sys_mount_mode halow_sys_remount
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- restoration failure (CRITICAL): the write succeeds, but /sys cannot be confirmed restored to read-only afterward -- this must be reported distinctly (exit 3), never silently treated as an ordinary failure, and ownership must be KEPT for manual review --"
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    if [ "$1" = "rw" ]; then _mount_mode="rw"; return 0; fi
    return 1   # the remount back to ro always fails
}
halow_set_firmware_search_path "/data/halow_fw"
_set_status=$?
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_set_status" -eq 3 ]; then
    echo "  ok: set reports CRITICAL (exit 3), distinct from an ordinary failure, when /sys cannot be confirmed restored to read-only afterward"
else
    echo "  FAIL: set reports CRITICAL (exit 3) when /sys cannot be confirmed restored to read-only afterward (got $_set_status)"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the write itself genuinely succeeded -- the CRITICAL failure is specifically the restore-mode step, not the write"
assert_success "ownership is KEPT (not cleared) after a CRITICAL restore-mode failure, for manual review" \
    halow_own_check "fw_search_path"
unset -f halow_sys_mount_mode halow_sys_remount
# Manual cleanup: the real mechanism deliberately keeps ownership here (by design, for
# manual review), so this test's own teardown reconciles it directly.
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- restoration failure (CRITICAL), specifically during SET's own readback-mismatch fallback restore -- found missing by a code review, not self-identified: the first write-with-remount cycle (writing the new value) must fully succeed, so the OUTER function's own post-write readback check sees a mismatch and attempts its own fallback restore-to-prior, and THAT SECOND write-with-remount cycle's own final remount-back-to-ro is what fails -- distinct from the scenario above, where the very first write's own remount-back-to-ro fails --"
# The prior value must be NON-EMPTY here: this fallback restore writes the prior value
# back, and an empty prior is deliberately never written (see the empty-prior fallback
# scenario further below).
printf '%s' "/pre/existing/path" > "$HALOW_FW_SYSFS_PATH"
_mount_mode="ro"
_remount_call_n=0
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    _remount_call_n=$((_remount_call_n + 1))
    case "$1" in
        rw) _mount_mode="rw"; return 0 ;;
        ro)
            # Calls 1-2 are the first (successful) write-with-remount cycle; call 3 is
            # the fallback restore's own remount-to-rw (handled by the rw case above);
            # call 4 is specifically the fallback restore's own final remount-to-ro --
            # the one this scenario exists to make fail.
            if [ "$_remount_call_n" -ge 4 ]; then
                return 1
            fi
            _mount_mode="ro"
            return 0
            ;;
    esac
    return 1
}
_cat_call_file2="$HALOW_TEST_TMP/cat_call_count_2"
echo 0 > "$_cat_call_file2"
cat() {
    local n
    n=$(( $(command cat "$_cat_call_file2" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$_cat_call_file2"
    # halow_own_check is false at this point (no own_mark call reads here); the 1st
    # real `cat "$sysfs"` is the prior-value read before writing; the 2nd is this
    # function's own post-write readback check (comparing against the intended new
    # value) -- halow_sysfs_write_with_remount itself makes no `cat` calls (its own
    # verification goes through the separately-stubbed halow_sys_mount_mode). Made to
    # lie on this 2nd call, simulating a write that landed a different value than
    # intended, to reach the readback-mismatch fallback-restore branch under test.
    if [ "$n" -eq 2 ]; then
        printf '%s' "unexpectedly-different-value"
    else
        command cat "$@"
    fi
}
halow_set_firmware_search_path "/data/halow_fw"
_set_status=$?
unset -f cat
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_set_status" -eq 3 ]; then
    echo "  ok: set propagates CRITICAL (exit 3), not an ordinary failure, when its own readback-mismatch FALLBACK RESTORE is the step whose remount-to-ro cannot be confirmed"
else
    echo "  FAIL: set propagates CRITICAL (exit 3) when its own fallback restore's remount-to-ro fails (got $_set_status) -- this is exactly the return-code collapse a code review found and this test now guards against"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_success "ownership is KEPT (not cleared) after this CRITICAL fallback-restore failure, for manual review" \
    halow_own_check "fw_search_path"
unset -f halow_sys_mount_mode halow_sys_remount
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- readback-mismatch fallback with an EMPTY prior value: no empty write is ever attempted (it cannot be done exactly on this device); fail closed with ownership KEPT at 'prepared' --"
_mount_mode="ro"
_remount_calls=0
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    _remount_calls=$((_remount_calls + 1))
    case "$1" in
        rw) _mount_mode="rw"; return 0 ;;
        ro) _mount_mode="ro"; return 0 ;;
    esac
    return 1
}
_cat_call_file3="$HALOW_TEST_TMP/cat_call_count_3"
echo 0 > "$_cat_call_file3"
cat() {
    local n
    n=$(( $(command cat "$_cat_call_file3" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$_cat_call_file3"
    if [ "$n" -eq 2 ]; then printf '%s' "unexpectedly-different-value"; else command cat "$@"; fi
}
halow_set_firmware_search_path "/data/halow_fw"
_set_status=$?
unset -f cat
assert_eq "1" "$_set_status" "set fails closed (ordinary failure) when the readback mismatches and the prior value is empty"
assert_eq "2" "$_remount_calls" "exactly one remount to rw and one back to ro (the single write of the new value) -- no second, fallback write cycle was attempted"
assert_eq "ro" "$_mount_mode" "/sys is left read-only"
assert_success "ownership is KEPT for rollback's own restore pass / manual review" \
    halow_own_check "fw_search_path"
assert_eq "prepared" "$(halow_own_get fw_search_path | head -n1)" "the kept marker is still 'prepared' (the write was never confirmed applied)"
unset -f halow_sys_mount_mode halow_sys_remount
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "== test_module_load (crash-safe two-phase ownership state model — the 2026-10-20 rollback-INCOMPLETE regression) =="
# Each scenario below directly constructs the marker a real interruption (kill, crash,
# the errexit incident documented at the top of module_load.sh) would leave behind at
# that EXACT point, then calls ONLY halow_restore_firmware_search_path -- exactly what
# a subsequent rollback pass does, since the interrupted process itself is gone and
# cannot resume. No live sysfs write actually occurs in these tests unless the scenario
# itself requires one (the fake sysfs file stands in for it, as elsewhere in this file).

echo "-- interruption 1: after recording the prior value but before remount was ever attempted --"
: > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
assert_success "restore succeeds (nothing to undo)" \
    halow_restore_firmware_search_path
assert_eq "" "$(cat "$HALOW_FW_SYSFS_PATH")" "the sysfs node is untouched"
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"

echo "-- interruption 2: after remount-to-rw was attempted and failed (functionally identical on-disk state to interruption 1, listed separately since the user-facing scenario is distinct) --"
: > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
assert_success "restore succeeds (nothing to undo)" \
    halow_restore_firmware_search_path
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"

echo "-- interruption 3: after a successful remount-to-rw but before the write -- /sys's own MOUNT MODE (not just the sysfs value) could be left writable; the ownership marker alone cannot record that, so this is checked and defensively corrected independently of the marker's own state --"
: > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
_mount_mode="rw"
_remount_calls=0
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    _remount_calls=$((_remount_calls + 1))
    [ "$1" = "ro" ] && _mount_mode="ro"
    return 0
}
assert_success "restore succeeds" \
    halow_restore_firmware_search_path
assert_eq "ro" "$_mount_mode" \
    "the defensive check found /sys unexpectedly mounted rw and remounted it back to ro"
assert_eq "1" "$_remount_calls" \
    "exactly one defensive remount-to-ro occurred"
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"
unset -f halow_sys_mount_mode halow_sys_remount

echo "-- interruption 3b (FAIL CLOSED): /sys is unexpectedly rw AND the defensive remount-to-ro cannot be confirmed -- restore returns 3 IMMEDIATELY, touches neither the sysfs value nor any marker --"
for _marker_case in "applied|/data/halow_fw" "prepared|" ; do
    _mstate="${_marker_case%%|*}"; _mnode="${_marker_case#*|}"
    printf '%s' "$_mnode" > "$HALOW_FW_SYSFS_PATH"
    # 'prepared' with the node still at the empty prior is the case that, WITHOUT the early
    # return, would have been silently CLEARED as "nothing changed" while /sys stayed rw.
    halow_own_mark "fw_search_path" "$(printf '%s\n\n%s' "$_mstate" "/data/halow_fw")"
    _remount_calls=0
    halow_sys_mount_mode() { printf 'rw'; }
    halow_sys_remount() { _remount_calls=$((_remount_calls + 1)); return 1; }
    halow_restore_firmware_search_path; _rc=$?
    assert_eq "3" "$_rc" "[$_mstate] restore returns the distinct critical mount-state code 3"
    assert_eq "1" "$_remount_calls" "[$_mstate] exactly one defensive remount attempt, no write cycle"
    assert_eq "$_mnode" "$(cat "$HALOW_FW_SYSFS_PATH")" "[$_mstate] the sysfs value is untouched"
    assert_success "[$_mstate] fw_search_path ownership is KEPT, not cleared" halow_own_check "fw_search_path"
    assert_eq "$_mstate" "$(halow_own_get fw_search_path | head -n1)" "[$_mstate] the marker state is not reclassified"
    assert_failure "[$_mstate] no reboot-required marker is invented" halow_own_check "firmware_path_reboot_required"
    halow_own_clear "fw_search_path"
done
: > "$HALOW_FW_SYSFS_PATH"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

echo "-- interruption 4: after the write succeeded but before the marker could be promoted to 'applied' -- the marker still says 'prepared', but the sysfs node already holds the NEW (intended) value, not the prior one --"
# Explicitly (re-)stubbed here, never relying on an earlier test block's own stub still
# being in place -- `unset -f` on a function this file itself previously redefined
# removes it entirely rather than reverting to module_load.sh's own real definition
# (the exact "unset -f silently deletes the real production function" class of defect
# this project's own test suite has already found once before elsewhere).
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
assert_success "restore succeeds (promotes and restores)" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the (empty) prior value is replaced by the inert sentinel, even though the marker said 'prepared', not 'applied'"
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"
assert_success "exact restoration is recorded as pending (firmware_path_reboot_required held)" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- interruption 4b: a restore that began from the 'prepared + write landed' marker above installed the sentinel, then was interrupted before ANY bookkeeping -- the marker STILL says 'prepared' and the node already holds the sentinel; recovery must finish the bookkeeping, never refuse the sentinel as an unexplained foreign value --"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
assert_success "restore recovers from the 'prepared' + sentinel-installed state" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel is undisturbed by the recovery"
assert_failure "active ownership is cleared" \
    halow_own_check "fw_search_path"
assert_success "exact restoration is recorded as pending (firmware_path_reboot_required held)" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- interruption 5: during restoration itself -- marker says 'applied', the sysfs node still holds the value this package wrote (the restore write has not happened yet) --"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n/data/halow_fw')"
assert_success "restore succeeds" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel was installed in place of the (empty) prior value"
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"
assert_success "exact restoration is recorded as pending (firmware_path_reboot_required held)" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
unset -f halow_sys_mount_mode halow_sys_remount
: > "$HALOW_FW_SYSFS_PATH"

echo "-- interruption 6: after restoration completed but before the marker was removed -- marker says 'applied', but the sysfs node ALREADY holds the prior value (a previous restore attempt's own write succeeded, only the marker-clearing step was interrupted) --"
: > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n/data/halow_fw')"
assert_success "restore succeeds (no write needed, already restored)" \
    halow_restore_firmware_search_path
assert_eq "" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sysfs node is unchanged (no write was needed or attempted)"
assert_failure "ownership is cleared" \
    halow_own_check "fw_search_path"

echo "-- regression guard: a GENUINE foreign change while 'prepared' (current matches neither prior nor our_value) is still refused, never guessed --"
printf '%s' "/someone/elses/completely/different/value" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n/data/halow_fw')"
assert_failure "restore refuses to guess" \
    halow_restore_firmware_search_path
assert_eq "/someone/elses/completely/different/value" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the foreign value is left completely untouched"
assert_success "ownership is KEPT for manual review" \
    halow_own_check "fw_search_path"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "== test_module_load (empty values are REFUSED by the sysfs write helper -- neither a zero-byte nor a single-NUL-byte write restored this parameter to empty on the test Green, so nothing may rely on an empty write) =="
# Implementation-level behaviour of halow_sysfs_write_with_remount only. It documents
# what the helper does; it is NOT evidence that any empty-value technique works on any
# device. Both a zero-byte and a one-NUL-byte write were tried live and neither took
# effect (see the helper's own header); the production path for an empty prior value is
# the inert sentinel, covered in the dedicated sentinel block below.
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

printf '%s' "/pre/existing/path" > "$HALOW_FW_SYSFS_PATH"
assert_failure "an empty desired value is refused outright" \
    halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" ""
assert_eq "/pre/existing/path" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "a refused empty write leaves the node completely untouched (nothing was truncated or written)"
assert_eq "18" "$(wc -c < "$HALOW_FW_SYSFS_PATH")" \
    "byte-exact: the node still holds exactly its original 18 bytes -- no NUL byte, newline, or truncation"

_remount_calls=0
halow_sys_mount_mode() { printf 'ro'; }
halow_sys_remount() { _remount_calls=$((_remount_calls + 1)); return 0; }
halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" "" >/dev/null 2>&1
assert_eq "0" "$_remount_calls" \
    "a refused empty write never remounts /sys at all (no needless rw window)"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

: > "$HALOW_FW_SYSFS_PATH"
assert_success "a non-empty desired value is still written" \
    halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" "/data/halow_fw"
assert_eq "14" "$(wc -c < "$HALOW_FW_SYSFS_PATH")" \
    "a non-empty desired value is written as exactly its own byte length, with no NUL or newline appended"
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "a non-empty desired value's content is exact"

echo "-- a non-empty write that fails (target is not a writable regular file) fails closed --"
rm -f "$HALOW_FW_SYSFS_PATH"
mkdir -p "$HALOW_FW_SYSFS_PATH"
assert_failure "a failed non-empty write is reported as a failure" \
    halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" "/data/halow_fw"
rm -rf "$HALOW_FW_SYSFS_PATH"
: > "$HALOW_FW_SYSFS_PATH"

unset -f halow_sys_mount_mode halow_sys_remount
: > "$HALOW_FW_SYSFS_PATH"

echo "== test_module_load (mac80211 dependency loading — the 2026-10-20 live 'Unknown symbol' a live-device test incident) =="
halow_test_setup
ko="$HALOW_ARTIFACTS_DIR/morse.ko"
: > "$ko"

mac80211_state="$HALOW_TEST_TMP/mac80211_loaded"
morse_state="$HALOW_TEST_TMP/morse_loaded"
modprobe_calls="$HALOW_TEST_TMP/modprobe_calls"
# File-based state throughout, not shell variables -- insmod/modprobe are piped through
# halow_log_pipe (`... | halow_log_pipe`), and bash runs a pipeline's left side in a
# SUBSHELL, so a shell-variable mutation inside these stubs would never be visible back
# here (the exact class of defect this file's own morse/dot11ah tests already found and
# documented, above).
lsmod() {
    { [ "$(cat "$mac80211_state" 2>/dev/null)" = "1" ] && echo "mac80211 500000 1 morse"; } 2>/dev/null
    { [ "$(cat "$morse_state" 2>/dev/null)" = "1" ] && echo "morse 12345 0"; } 2>/dev/null
    true
}

echo "-- mac80211 already loaded: halow_load_morse proceeds straight to insmod morse.ko, never calls modprobe, and never claims ownership of a module it did not itself load --"
echo 1 > "$mac80211_state"
echo 0 > "$morse_state"
echo 0 > "$modprobe_calls"
modprobe() { echo "$(( $(cat "$modprobe_calls") + 1 ))" > "$modprobe_calls"; case "$1" in mac80211) echo 1 > "$mac80211_state" ;; esac; return 0; }
insmod() { case "$1" in *morse.ko) echo 1 > "$morse_state" ;; esac; return 0; }
rmmod() { case "$1" in mac80211) echo 0 > "$mac80211_state" ;; morse) echo 0 > "$morse_state" ;; esac; return 0; }

assert_success "morse loads successfully when mac80211 is already present" \
    halow_load_morse "$ko"
assert_eq "0" "$(cat "$modprobe_calls")" \
    "modprobe is never called when mac80211 is already loaded"
assert_failure "mac80211 is NOT marked as add-on-owned when it was already loaded by something else" \
    halow_own_check "module_mac80211"
assert_success "morse's own ownership is recorded as usual" \
    halow_own_check "module_morse"
halow_own_clear "module_morse"

echo "-- mac80211 absent and successfully loaded: modprobe is called exactly once, ownership is claimed, and morse then loads --"
echo 0 > "$mac80211_state"
echo 0 > "$morse_state"
echo 0 > "$modprobe_calls"
assert_success "morse loads successfully after mac80211 is loaded on demand" \
    halow_load_morse "$ko"
assert_eq "1" "$(cat "$modprobe_calls")" \
    "modprobe mac80211 is called exactly once"
assert_success "mac80211 is marked as add-on-owned, since this add-on itself loaded it" \
    halow_own_check "module_mac80211"
assert_success "morse's own ownership is recorded" \
    halow_own_check "module_morse"
halow_own_clear "module_mac80211"
halow_own_clear "module_morse"

echo "-- dependency-load failure: modprobe mac80211 fails, morse.ko's own insmod is never even attempted, and nothing is left owned --"
echo 0 > "$mac80211_state"
echo 0 > "$morse_state"
insmod_morse_calls="$HALOW_TEST_TMP/insmod_morse_calls"
echo 0 > "$insmod_morse_calls"
modprobe() { return 1; }
insmod() { echo "$(( $(cat "$insmod_morse_calls") + 1 ))" > "$insmod_morse_calls"; case "$1" in *morse.ko) echo 1 > "$morse_state" ;; esac; return 0; }
assert_failure "morse load fails when the mac80211 dependency cannot be loaded" \
    halow_load_morse "$ko"
assert_eq "0" "$(cat "$insmod_morse_calls")" \
    "morse.ko's own insmod is never even attempted when its mac80211 dependency fails to load"
assert_failure "no ownership is left for mac80211" \
    halow_own_check "module_mac80211"
assert_failure "no ownership is left for morse" \
    halow_own_check "module_morse"

echo "-- morse fails after mac80211 was loaded by this add-on: mac80211's own ownership is RETAINED, never unwound by halow_load_morse itself -- exactly mirroring the existing dot11ah/morse relationship, where an earlier independent step's own success is only ever unwound by the broader rollback path, never by a later, unrelated step's own failure --"
echo 0 > "$mac80211_state"
echo 0 > "$morse_state"
modprobe() { echo 1 > "$mac80211_state"; return 0; }
insmod() { return 1; }
assert_failure "morse load fails when morse.ko's own insmod fails outright" \
    halow_load_morse "$ko"
assert_success "mac80211 ownership is RETAINED -- it loaded successfully and unloading it is the broader rollback path's own job" \
    halow_own_check "module_mac80211"
assert_failure "morse's own ownership is not recorded, since its insmod never succeeded" \
    halow_own_check "module_morse"

echo "-- rollback (halow_unload_modules) then unloads the add-on-owned mac80211, positively verified, continuing directly from the scenario above --"
rmmod_calls_file="$HALOW_TEST_TMP/rmmod_calls"
: > "$rmmod_calls_file"
rmmod() { echo "$1" >> "$rmmod_calls_file"; case "$1" in mac80211) echo 0 > "$mac80211_state" ;; morse) echo 0 > "$morse_state" ;; esac; return 0; }
halow_unload_modules
assert_eq "mac80211" "$(tr '\n' ' ' < "$rmmod_calls_file" | sed 's/ *$//')" \
    "only mac80211 is actually unloaded -- morse was never owned (its insmod failed above) and dot11ah was never loaded in this scenario, so rmmod is called exactly once, for mac80211"
assert_failure "mac80211 ownership is cleared once rmmod is confirmed to have actually removed it" \
    halow_own_check "module_mac80211"

echo "-- rollback never unloads a pre-existing/foreign mac80211 -- no ownership marker means hands off, exactly like every other module this file tracks --"
echo 1 > "$mac80211_state"
halow_own_clear "module_mac80211"
: > "$rmmod_calls_file"
halow_unload_modules
assert_eq "" "$(cat "$rmmod_calls_file")" \
    "rmmod is never called for mac80211 when this add-on never recorded owning it"
assert_eq "1" "$(cat "$mac80211_state")" \
    "the foreign mac80211 is left loaded, completely untouched"

echo "-- mac80211 unload failure: rmmod \"succeeds\" (exit 0) but lsmod still reports it loaded afterward -- ownership must be KEPT, not cleared, so cleanup keeps retrying --"
echo 1 > "$mac80211_state"
halow_own_mark "module_mac80211"
rmmod() { case "$1" in mac80211) : ;; esac; return 0; }
halow_unload_modules
assert_success "mac80211 ownership is NOT cleared when rmmod does not actually remove it" \
    halow_own_check "module_mac80211"
halow_own_clear "module_mac80211"
echo 0 > "$mac80211_state"

echo "== test_module_load (development-build-only inert sentinel — the 2026-10-20 second live restore-failure incident) =="
# SENTINEL is this test file's own fixed stand-in value, deliberately distinct from
# HALOW_FW_SEARCH_SENTINEL's own real default, so a test asserting the two are not
# confused with each other (e.g. our_value) is actually meaningful -- but HALOW_FW_SEARCH_SENTINEL
# itself is read directly from common.sh's own default throughout, never hardcoded here,
# so a change to that default is automatically exercised by these tests too.
halow_test_setup
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

echo "-- empty original value transitions to the verified sentinel, never attempts an empty write --"
: > "$HALOW_FW_SYSFS_PATH"
assert_success "fresh set succeeds (true prior is empty)" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_success "restore succeeds (installs the sentinel instead of empty)" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sysfs node now holds the POC sentinel value, not an attempted empty write"
assert_failure "the active fw_search_path marker is cleared" \
    halow_own_check "fw_search_path"
assert_success "the distinct firmware_path_reboot_required marker is set instead" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- non-empty original values still restore EXACTLY, completely unaffected by the sentinel mechanism --"
printf '%s' "/some/other/pre-existing/path" > "$HALOW_FW_SYSFS_PATH"
assert_success "set succeeds over a non-empty pre-existing value" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_success "restore succeeds" \
    halow_restore_firmware_search_path
assert_eq "/some/other/pre-existing/path" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the exact pre-existing value is restored, never the sentinel"
assert_failure "no reboot-required marker is set for a non-empty-prior restore" \
    halow_own_check "firmware_path_reboot_required"
assert_failure "the active marker is cleared" \
    halow_own_check "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- sentinel path existence check (host-level live-reconciliation precondition; never called by the add-on's own normal lifecycle) -- 'sentinel unexpectedly exists' is a STOP, not a silent proceed --"
# A disposable child script, never a nested, multiply-escaped inline `bash -c` -- this
# project's own repeated, documented experience is that nested shell-quoting across
# layers silently mangles variable expansion (see test_errexit_safety.sh's own header).
_sentinel_check_script="$HALOW_TEST_TMP/sentinel_check.sh"
_sentinel_test_path="$HALOW_TEST_TMP/fake-sentinel-path"
cat > "$_sentinel_check_script" <<CHILD_EOF
#!/usr/bin/env bash
export HALOW_FW_SEARCH_SENTINEL="$_sentinel_test_path"
. "$HALOW_LIB_DIR/common.sh"
. "$HALOW_LIB_DIR/ownership.sh"
. "$HALOW_LIB_DIR/module_load.sh"
halow_sentinel_path_is_absent
CHILD_EOF
rm -f "$_sentinel_test_path"
assert_success "reports absent when the sentinel path genuinely does not exist" \
    bash "$_sentinel_check_script"
: > "$_sentinel_test_path"
assert_failure "reports NOT absent (i.e. 'exists' -- the live procedure must stop) when the sentinel path unexpectedly exists" \
    bash "$_sentinel_check_script"
rm -f "$_sentinel_test_path"

echo "-- sentinel write failure: /sys cannot be remounted (empty-prior case) -- ownership kept, no reboot-required marker set --"
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() { return 1; }
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
assert_failure "restore fails closed when the sentinel write's own remount-to-rw fails" \
    halow_restore_firmware_search_path
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sysfs node is untouched -- a failed remount must never reach the write at all"
assert_success "ownership is kept" \
    halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set when the sentinel was never actually written" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }
: > "$HALOW_FW_SYSFS_PATH"

echo "-- sentinel readback failure: the write-with-remount call reports success, but the node does not actually read back as the sentinel -- ownership kept, no reboot-required marker set --"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
# PATH-AWARE lie (never call-counted: halow_own_get also uses `cat`, so a counter lands
# on the wrong read and silently tests a different branch -- found by an independent
# review). The lie arms only AFTER the stubbed write has really happened, and applies
# only to reads of the sysfs node itself, so it targets exactly the post-write readback.
eval "_real_sysfs_write() $(declare -f halow_sysfs_write_with_remount | tail -n +2)"
_lie_armed="$HALOW_TEST_TMP/lie_armed"
rm -f "$_lie_armed"
halow_sysfs_write_with_remount() { _real_sysfs_write "$@"; local rc=$?; touch "$_lie_armed"; return $rc; }
cat() {
    if [ "${1:-}" = "$HALOW_FW_SYSFS_PATH" ] && [ -e "$_lie_armed" ]; then
        printf '%s' "not-the-expected-value"
    else
        command cat "$@"
    fi
}
halow_restore_firmware_search_path
_sentinel_readback_status=$?
unset -f cat
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_sentinel_readback_status" -ne 0 ]; then
    echo "  ok: restore fails closed when the sentinel's own post-write readback does not match"
else
    echo "  FAIL: restore fails closed when the sentinel's own post-write readback does not match (got success)"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_success "ownership is KEPT when the sentinel readback mismatches" \
    halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set when the sentinel readback could not be confirmed" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- remount-back-to-read-only failure (CRITICAL) during sentinel install: the write succeeds, but /sys cannot be confirmed restored to read-only afterward -- exit 3, ownership KEPT, no reboot-required marker --"
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    if [ "$1" = "rw" ]; then _mount_mode="rw"; return 0; fi
    return 1
}
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
halow_restore_firmware_search_path
_sentinel_critical_status=$?
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$_sentinel_critical_status" -eq 3 ]; then
    echo "  ok: sentinel install reports CRITICAL (exit 3) when /sys cannot be confirmed restored to read-only afterward"
else
    echo "  FAIL: sentinel install reports CRITICAL (exit 3) when /sys cannot be confirmed restored to read-only afterward (got $_sentinel_critical_status)"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel write itself genuinely succeeded -- the CRITICAL failure is specifically the restore-mode step"
assert_success "ownership is KEPT (not cleared) after a CRITICAL restore-mode failure, for manual review" \
    halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set when /sys's own mount mode could not be confirmed restored" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }
: > "$HALOW_FW_SYSFS_PATH"

echo "-- active marker versus reboot-required marker: the two are tracked completely independently --"
: > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
halow_restore_firmware_search_path >/dev/null
assert_failure "fw_search_path (active) is cleared after a successful sentinel install" \
    halow_own_check "fw_search_path"
assert_success "firmware_path_reboot_required is held after a successful sentinel install" \
    halow_own_check "firmware_path_reboot_required"
# A fresh, unrelated active-use cycle must not disturb the already-set reboot-required
# marker left over from the scenario above -- distinct keys, distinct lifecycles.
printf '%s' "/some/other/pre-existing/path" > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw_2" >/dev/null
assert_success "firmware_path_reboot_required remains held, untouched by an unrelated active-use cycle starting" \
    halow_own_check "firmware_path_reboot_required"
halow_restore_firmware_search_path >/dev/null
assert_success "firmware_path_reboot_required remains held after that unrelated cycle's own EXACT (non-empty-prior) restore too" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- repeated rollback with the sentinel already installed is a safe no-op (fw_search_path already unowned) --"
: > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
halow_restore_firmware_search_path >/dev/null
assert_success "restoring again when fw_search_path is already unowned is a safe no-op" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel value is undisturbed by the repeated, no-op call"
assert_success "firmware_path_reboot_required remains held, undisturbed by the repeated no-op call" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- foreign modification is still refused even on the sentinel path -- the existing foreign-change check runs BEFORE the empty-prior/sentinel branch is ever reached --"
: > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
printf '%s' "/someone/elses/value" > "$HALOW_FW_SYSFS_PATH"
assert_failure "restore refuses to install the sentinel over a value some other actor set since this package's own set" \
    halow_restore_firmware_search_path
assert_eq "/someone/elses/value" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the foreign value is left completely untouched, never overwritten with the sentinel"
assert_success "ownership is KEPT, not cleared, on a foreign-change refusal" \
    halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set on a foreign-change refusal" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- interruption: sentinel write already succeeded (confirmed by readback at the time) but the bookkeeping (reboot-required mark + active-marker clear) was interrupted before it finished -- recovered safely and idempotently on the next call --"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
assert_success "restore recovers cleanly: finishes the interrupted bookkeeping rather than re-attempting or refusing" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel value itself is undisturbed by the recovery"
assert_failure "the active marker is now cleared" \
    halow_own_check "fw_search_path"
assert_success "the reboot-required marker is now set" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- sentinel write failure with a SUCCESSFUL remount: the write itself fails, /sys is still restored to read-only, ownership KEPT, no reboot-required marker --"
_mount_mode="ro"
halow_sys_mount_mode() { printf '%s' "$_mount_mode"; }
halow_sys_remount() {
    case "$1" in
        rw) _mount_mode="rw"; return 0 ;;
        ro) _mount_mode="ro"; return 0 ;;
    esac
    return 1
}
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
# Swap the node for a directory only AFTER the pre-write comparison would read it: the
# restore reads `current` first, so make the node unwritable by replacing it with a
# directory whose own read yields nothing -- instead, stub the read via a second node.
_real_sysfs="$HALOW_FW_SYSFS_PATH"
_saved_value="/data/halow_fw"
rm -f "$_real_sysfs"
mkdir -p "$_real_sysfs"
cat() {
    # Reads of the (now directory) node report the value this package wrote, so the
    # restore reaches its sentinel write; the write itself then fails on the directory.
    if [ "${1:-}" = "$_real_sysfs" ]; then printf '%s' "$_saved_value"; else command cat "$@"; fi
}
halow_restore_firmware_search_path
_sentinel_wf_status=$?
unset -f cat
assert_eq "1" "$_sentinel_wf_status" "restore reports an ordinary failure when the sentinel write itself fails"
assert_eq "ro" "$_mount_mode" "/sys is still correctly remounted back to read-only after the failed sentinel write"
assert_success "ownership is KEPT after a failed sentinel write" \
    halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set when the sentinel was never written" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
rm -rf "$_real_sysfs"
: > "$HALOW_FW_SYSFS_PATH"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }

echo "-- a SECOND start while the sentinel is still installed (reboot pending): the sentinel is recorded as the (non-empty) prior value and restored exactly; the reboot-required marker is neither lost nor prematurely cleared --"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "firmware_path_reboot_required"
assert_success "set succeeds over the sentinel" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(halow_own_get fw_search_path | sed -n 2p)" \
    "the recorded prior value is the sentinel itself"
assert_success "restore succeeds" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" \
    "the sentinel is restored exactly (a non-empty prior is restored exactly, never 'upgraded' to empty)"
assert_failure "active ownership is cleared" \
    halow_own_check "fw_search_path"
assert_success "the reboot-required marker is still held -- exact restoration is still pending" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- post-reboot baseline verification: clears the reboot-required marker ONLY once the real value is confirmed genuinely empty --"
assert_success "a safe no-op when nothing is pending" \
    halow_verify_fw_search_path_rebooted_clean
halow_own_mark "firmware_path_reboot_required"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
assert_failure "verification FAILS (and the marker is KEPT) while the sysfs node still holds the sentinel, not genuine empty" \
    halow_verify_fw_search_path_rebooted_clean
assert_success "the reboot-required marker is still held after a failed verification" \
    halow_own_check "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"
assert_success "verification SUCCEEDS once the sysfs node is genuinely empty" \
    halow_verify_fw_search_path_rebooted_clean
assert_failure "the reboot-required marker is cleared only now, after genuine confirmation" \
    halow_own_check "firmware_path_reboot_required"

echo "-- verification fails CLOSED when the node cannot be read at all (an unreadable node must never be mistaken for 'exactly empty') --"
halow_own_mark "firmware_path_reboot_required"
_saved_sysfs="$HALOW_FW_SYSFS_PATH"
HALOW_FW_SYSFS_PATH="$HALOW_TEST_TMP/does-not-exist"
assert_failure "verification fails when the sysfs node is unreadable" \
    halow_verify_fw_search_path_rebooted_clean
assert_success "the reboot-required marker is KEPT after an unreadable-node verification" \
    halow_own_check "firmware_path_reboot_required"
HALOW_FW_SYSFS_PATH="$_saved_sysfs"
halow_own_clear "firmware_path_reboot_required"

echo "-- STRANDED marker, scenario A (found by code review): an earlier run wrote the sentinel and was killed before ANY bookkeeping; the next start's SET must reconcile that first, never re-record the sentinel as 'prior' and lose the pending-reboot state --"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
assert_success "set succeeds after reconciling the stranded marker first" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_success "the interrupted sentinel install's reboot-required marker was recorded by the reconciliation" \
    halow_own_check "firmware_path_reboot_required"
assert_success "restore after the new set succeeds" \
    halow_restore_firmware_search_path
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" "the node ends on the sentinel"
assert_success "the reboot-required marker is STILL held -- never silently promoted to state (3)" \
    halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- STRANDED marker, scenario B (found by code review): stale marker for /old/dir, node at /old/dir, new run uses a DIFFERENT dir; the true (empty) prior must not be replaced by /old/dir --"
printf '%s' "/old/dir" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/old/dir")"
assert_success "set succeeds after reconciling the stranded marker first" \
    halow_set_firmware_search_path "/new/dir"
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(halow_own_get fw_search_path | sed -n 2p)" \
    "the new marker's prior is the sentinel the reconciliation installed (never the stale /old/dir)"
assert_success "reconciliation recorded exact restoration as pending" \
    halow_own_check "firmware_path_reboot_required"
halow_restore_firmware_search_path >/dev/null
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- a stranded marker that CANNOT be reconciled makes SET refuse (ownership kept, node untouched) --"
printf '%s' "/someone/elses/value" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/old/dir")"
assert_failure "set refuses to proceed over a stranded marker whose node holds a foreign value" \
    halow_set_firmware_search_path "/new/dir"
assert_eq "/someone/elses/value" "$(cat "$HALOW_FW_SYSFS_PATH")" "the foreign value is untouched"
assert_success "the stranded marker is kept for manual review" \
    halow_own_check "fw_search_path"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- an unrecognised marker state is refused, never interpreted --"
halow_own_mark "fw_search_path" "$(printf 'legacy\n\n%s' "/data/halow_fw")"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
assert_failure "restore refuses an unrecognised marker state" \
    halow_restore_firmware_search_path
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" "the node is untouched"
assert_success "ownership is kept" halow_own_check "fw_search_path"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- SET fails closed when the node cannot be read (no marker is created) --"
HALOW_FW_SYSFS_PATH="$HALOW_TEST_TMP/does-not-exist"
assert_failure "set refuses when it cannot read the prior value" \
    halow_set_firmware_search_path "/data/halow_fw"
assert_failure "no ownership marker is created" halow_own_check "fw_search_path"
HALOW_FW_SYSFS_PATH="$_saved_sysfs"

echo "-- ownership-marker transition: a confirmed write promotes the marker prepared -> applied (found by code review: no test read the state field after a successful set) --"
: > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
assert_eq "applied" "$(halow_own_get fw_search_path | head -n1)" "the marker state is 'applied' after a confirmed write"
assert_eq "/data/halow_fw" "$(halow_own_get fw_search_path | sed -n 3p)" "the marker records our_value"
halow_restore_firmware_search_path >/dev/null
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- exact (NON-empty prior) restore: a readback mismatch fails closed, ownership kept (found by code review: only the sentinel branch was covered) --"
printf '%s' "/some/other/pre-existing/path" > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
rm -f "$_lie_armed"
cat() {
    if [ "${1:-}" = "$HALOW_FW_SYSFS_PATH" ] && [ -e "$_lie_armed" ]; then printf '%s' "not-the-expected-value"; else command cat "$@"; fi
}
halow_restore_firmware_search_path
_exact_rb_status=$?
unset -f cat
assert_eq "1" "$_exact_rb_status" "exact restore reports failure when its own readback does not match"
assert_success "ownership is KEPT" halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is set on the exact-restore path" halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- ownership-record write failures return the DISTINCT code 4 (never 3, which means /sys mode) and never claim success --"
eval "_real_own_mark() $(declare -f halow_own_mark | tail -n +2)"
halow_own_mark() { if [ "$1" = "firmware_path_reboot_required" ]; then return 1; fi; _real_own_mark "$@"; }
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
_real_own_mark "fw_search_path" "$(printf 'applied\n\n%s' "/data/halow_fw")"
halow_restore_firmware_search_path; _rc=$?
assert_eq "4" "$_rc" "sentinel install whose reboot-required record cannot be written returns 4"
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" "the sentinel write itself did happen"
assert_success "fw_search_path ownership is KEPT (never silently dropped)" halow_own_check "fw_search_path"
assert_failure "no reboot-required marker exists" halow_own_check "firmware_path_reboot_required"
# recovery branch: node already holds the sentinel
halow_restore_firmware_search_path; _rc=$?
assert_eq "4" "$_rc" "the interrupted-bookkeeping recovery branch also returns 4 when the record cannot be written"
assert_success "fw_search_path ownership still KEPT" halow_own_check "fw_search_path"
halow_own_clear "fw_search_path"
halow_own_mark() { if [ "$1" = "fw_search_path" ] && case "${2:-}" in applied*) true ;; *) false ;; esac; then return 1; fi; _real_own_mark "$@"; }
: > "$HALOW_FW_SYSFS_PATH"
halow_set_firmware_search_path "/data/halow_fw"; _rc=$?
assert_eq "4" "$_rc" "set returns 4 when the 'applied' record cannot be written after a confirmed write"
assert_eq "/data/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" "the write DID take effect"
assert_eq "prepared" "$(halow_own_get fw_search_path | head -n1)" "the marker is still 'prepared' (so restore will treat a landed write correctly)"
halow_own_mark() { _real_own_mark "$@"; }
halow_restore_firmware_search_path >/dev/null
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- /sys mount mode undeterminable: the write helper refuses (fail closed), never remounts, never writes --"
_remount_calls=0
halow_sys_mount_mode() { :; }
halow_sys_remount() { _remount_calls=$((_remount_calls + 1)); return 0; }
printf '%s' "/orig" > "$HALOW_FW_SYSFS_PATH"
assert_failure "write refused when the mode cannot be determined" halow_sysfs_write_with_remount "$HALOW_FW_SYSFS_PATH" "/data/halow_fw"
assert_eq "/orig" "$(cat "$HALOW_FW_SYSFS_PATH")" "node untouched"
assert_eq "0" "$_remount_calls" "no remount attempted"
halow_sys_mount_mode() { printf 'rw'; }
halow_sys_remount() { return 0; }
: > "$HALOW_FW_SYSFS_PATH"

echo "-- SET's 'already set' shortcut requires an APPLIED marker whose our_value equals dir; a 'prepared' marker with current==dir is reconciled, not trusted --"
printf '%s' "/data/halow_fw" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'prepared\n\n%s' "/data/halow_fw")"
halow_set_firmware_search_path "/data/halow_fw" >/dev/null
assert_success "the stranded 'prepared' marker was reconciled first (empty prior -> sentinel -> reboot-required recorded)" \
    halow_own_check "firmware_path_reboot_required"
assert_eq "applied" "$(halow_own_get fw_search_path | head -n1)" "a fresh 'applied' marker now exists for the new set"
halow_restore_firmware_search_path >/dev/null
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- negative control: a NON-empty prior plus a node that happens to hold the sentinel is a FOREIGN value, never 'interrupted sentinel bookkeeping' --"
printf '%s' "$HALOW_FW_SEARCH_SENTINEL" > "$HALOW_FW_SYSFS_PATH"
halow_own_mark "fw_search_path" "$(printf 'applied\n%s\n%s' "/x" "/data/halow_fw")"
assert_failure "restore refuses" halow_restore_firmware_search_path
assert_success "fw_search_path ownership KEPT" halow_own_check "fw_search_path"
assert_failure "no reboot-required marker is invented" halow_own_check "firmware_path_reboot_required"
halow_own_clear "fw_search_path"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- unload ORDER with all three modules owned: morse, then mac80211, then dot11ah --"
_mods="$HALOW_TEST_TMP/mods_loaded"
printf 'morse\nmac80211\ndot11ah\n' > "$_mods"
_order="$HALOW_TEST_TMP/unload_order"; : > "$_order"
lsmod() { local m; while read -r m; do echo "$m 1000 0"; done < "$_mods"; }
rmmod() { echo "$1" >> "$_order"; grep -vx "$1" "$_mods" > "$_mods.n" || true; mv "$_mods.n" "$_mods"; return 0; }
halow_own_mark "module_morse"; halow_own_mark "module_mac80211"; halow_own_mark "module_dot11ah"
halow_unload_modules
assert_eq "morse mac80211 dot11ah" "$(tr '\n' ' ' < "$_order" | sed 's/ *$//')" "modules are removed in dependency order"
assert_failure "morse ownership cleared" halow_own_check "module_morse"
assert_failure "mac80211 ownership cleared" halow_own_check "module_mac80211"
assert_failure "dot11ah ownership cleared" halow_own_check "module_dot11ah"
unset -f lsmod rmmod

echo "-- post-reboot verification is RAW-byte exact: a lone newline (an empty kernel parameter shows as exactly one) passes; two newlines or any other byte do not --"
halow_own_mark "firmware_path_reboot_required"
printf '\n' > "$HALOW_FW_SYSFS_PATH"
assert_success "a single newline (how a real empty module parameter reads) is accepted as empty" halow_verify_fw_search_path_rebooted_clean
halow_own_clear "firmware_path_reboot_required"
: > "$HALOW_FW_SYSFS_PATH"

echo "-- BYTE-EXACT verification: every byte pattern other than zero bytes or exactly one newline FAILS and KEEPS the marker (bash drops NUL bytes in command substitution, so a \$(cat) based check would have wrongly accepted a NUL) --"
_verify_bytes_case() { # _verify_bytes_case <expected: pass|fail> <printf-format> <description>
    local expected="$1" fmt="$2" desc="$3"
    halow_own_mark "firmware_path_reboot_required"
    printf "$fmt" > "$HALOW_FW_SYSFS_PATH"
    if [ "$expected" = "pass" ]; then
        assert_success "$desc: accepted" halow_verify_fw_search_path_rebooted_clean
        assert_failure "$desc: marker cleared" halow_own_check "firmware_path_reboot_required"
    else
        assert_failure "$desc: REJECTED" halow_verify_fw_search_path_rebooted_clean
        assert_success "$desc: marker KEPT" halow_own_check "firmware_path_reboot_required"
        halow_own_clear "firmware_path_reboot_required"
    fi
}
_verify_bytes_case pass '' "zero bytes (plain-file harness only)"
_verify_bytes_case pass '\n' "exactly one newline (the real sysfs empty representation)"
_verify_bytes_case fail '\0' "a single NUL byte (00)"
_verify_bytes_case fail '\0\n' "NUL then newline (00 0a)"
_verify_bytes_case fail '\n\0' "newline then NUL (0a 00)"
_verify_bytes_case fail '\0\0' "two NUL bytes"
_verify_bytes_case fail '\n\n' "two newlines (0a 0a)"
_verify_bytes_case fail '\n\n\n' "three newlines"
_verify_bytes_case fail ' ' "a single space"
_verify_bytes_case fail ' \n' "space then newline"
_verify_bytes_case fail 'x' "a plain character"
_verify_bytes_case fail '/run/halow-firmware-search-disabled\n' "the sentinel itself"
_verify_bytes_case fail '\r\n' "carriage return + newline"
echo "-- non-regular / unreadable node: fails closed even though BusyBox od would exit 0 (covered under real BusyBox od by tests/image_sentinel_check.sh) --"
halow_own_mark "firmware_path_reboot_required"
rm -f "$HALOW_FW_SYSFS_PATH"; mkdir -p "$HALOW_FW_SYSFS_PATH"
assert_failure "a directory in place of the node is rejected" halow_verify_fw_search_path_rebooted_clean
assert_success "marker KEPT (directory)" halow_own_check "firmware_path_reboot_required"
rmdir "$HALOW_FW_SYSFS_PATH"
assert_failure "a missing node is rejected" halow_verify_fw_search_path_rebooted_clean
assert_success "marker KEPT (missing)" halow_own_check "firmware_path_reboot_required"
halow_own_clear "firmware_path_reboot_required"

echo "== test_module_load (halow_module_state: three-way loaded / absent / cannot-tell; lsmod failure must never read as 'confirmed absent' -- the pipefail incident's fail-closed half) =="
lsmod() { printf 'Module Size Used by\nmac80211 696320 0\nlibarc4 12288 1 mac80211\n'; }
halow_module_state mac80211; assert_eq "0" "$?" "a listed module is reported loaded (0)"
halow_module_state libarc4; assert_eq "0" "$?" "a second listed module is reported loaded (0)"
halow_module_state morse; assert_eq "1" "$?" "an unlisted module is reported absent (1)"
halow_module_state mac8021; assert_eq "1" "$?" "a name that is only a PREFIX of a listed module is not a match"
assert_failure "confirmed_absent is false for a loaded module" halow_module_confirmed_absent mac80211
assert_success "confirmed_absent is true for an unlisted module" halow_module_confirmed_absent morse
lsmod() { return 1; }
halow_module_state mac80211; assert_eq "2" "$?" "lsmod failing is 'cannot determine' (2), never 'absent'"
assert_failure "confirmed_absent is FALSE when lsmod fails (fail closed)" halow_module_confirmed_absent mac80211
assert_failure "module_loaded is false when lsmod fails" halow_module_loaded mac80211
rmmod() { return 0; }
halow_own_mark "module_morse"
assert_failure "unload_one_module does NOT claim success when lsmod cannot confirm absence" halow_unload_one_module morse module_morse
assert_success "ownership is KEPT when absence could not be confirmed" halow_own_check "module_morse"
halow_own_clear "module_morse"
modprobe() { echo "modprobe-called" >> "$HALOW_TEST_TMP/modprobe_calls"; return 0; }
: > "$HALOW_TEST_TMP/modprobe_calls"
assert_failure "ensure_mac80211_loaded refuses to proceed when lsmod fails (it must not claim a possibly-foreign module)" halow_ensure_mac80211_loaded
assert_eq "" "$(cat "$HALOW_TEST_TMP/modprobe_calls")" "modprobe was never called"
assert_failure "no mac80211 ownership was claimed" halow_own_check "module_mac80211"
unset -f lsmod rmmod modprobe

echo "-- built-in modules (a /sys/module/<name> directory WITHOUT initstate) are reported PRESENT, never 'absent'; dashes normalise to underscores --"
lsmod() { printf 'Module Size Used by\ncfg80211 491520 0\n'; }
mkdir -p "$HALOW_SYS_MODULE_DIR/mac80211"
halow_module_state mac80211; assert_eq "0" "$?" "a built-in module (no initstate) is reported loaded/present"
assert_failure "a built-in module is never 'confirmed absent' (it cannot be unloaded)" halow_module_confirmed_absent mac80211
mkdir -p "$HALOW_SYS_MODULE_DIR/ghost"; : > "$HALOW_SYS_MODULE_DIR/ghost/initstate"
halow_module_state ghost; assert_eq "1" "$?" "a directory WITH initstate that lsmod does not list is not built-in (absent)"
lsmod() { printf 'Module Size Used by\nsome_module 1 0\n'; }
halow_module_state some-module; assert_eq "0" "$?" "a dashed name matches the kernel's underscore spelling"
unset -f lsmod
rm -rf "$HALOW_SYS_MODULE_DIR/mac80211" "$HALOW_SYS_MODULE_DIR/ghost"

echo "-- halow_run_logged returns THE COMMAND'S status, regardless of the logging path (pipefail-proof) --"
_ok_cmd() { echo "line one"; echo "line two"; return 0; }
_bad_cmd() { echo "oops" >&2; return 7; }
halow_run_logged _ok_cmd; assert_eq "0" "$?" "a successful command returns 0"
halow_run_logged _bad_cmd; assert_eq "7" "$?" "a failing command's own exit status is preserved"
halow_log_pipe() { return 9; }
halow_run_logged _ok_cmd; assert_eq "0" "$?" "a failing log sink does NOT turn a successful command into a failure (the 'loaded but never owned' hazard)"
. "$HALOW_LIB_DIR/common.sh"
unset -f _ok_cmd _bad_cmd

echo "-- dmesg helpers: explicit failure status, no silent pipeline failure --"
dmesg() { return 1; }
assert_failure "halow_dmesg_watermark fails explicitly when dmesg cannot be read" halow_dmesg_watermark
assert_exit 1 "halow_dmesg_since fails explicitly (status 1) when dmesg cannot be read, even with a valid marker" halow_dmesg_since "[    1.000003] c"
dmesg() { printf '[    1.000001] a\n[    1.000002] b\n[    1.000003] c\n[    1.000004] d\n'; }
assert_eq "[    1.000004] d" "$(halow_dmesg_watermark)" "the marker is the newest record (not a line count)"
assert_eq "[    1.000004] d" "$(halow_dmesg_since "[    1.000003] c")" "only records after the marker are returned"
dmesg() { :; }
assert_failure "an empty log gives no marker (fail closed; the old line-count design returned 0 here)" halow_dmesg_watermark
unset -f dmesg

echo "-- UNTRACKED RESIDUAL branches (ownership cannot be recorded after a successful load): rc 3 + log when rmmod cannot remove it, rc 1 when it can -- with a SIGPIPE-prone lsmod that LISTS the module --"
_rs_dir="$HALOW_TEST_TMP/residual"; mkdir -p "$_rs_dir"
_rs_state="$_rs_dir/loaded"; _rs_ko="$_rs_dir/morse_fake.ko"; _rs_ko_d="$_rs_dir/dot11ah_fake.ko"; : > "$_rs_ko"; : > "$_rs_ko_d"
lsmod() {
    printf 'Module Size Used by\n'
    local m i=0
    for m in $(tac "$_rs_state" 2>/dev/null); do printf '%s 696320 0\n' "$m"; done
    while [ "$i" -lt 5000 ]; do printf 'padding_%05d 4096 0\n' "$i" || return 141; i=$((i + 1)); done
}
modprobe() { echo mac80211 >> "$_rs_state"; }
insmod() { case "$*" in *dot11ah*) echo dot11ah >> "$_rs_state" ;; *) echo morse >> "$_rs_state" ;; esac; }
halow_own_mark() { case "$1" in module_*) return 1 ;; esac; _real_own_mark "$@"; }
_rs_run() { # _rs_run <label> <expected-rc> <rmmod-mode: stuck|clean> <preloaded> -- <function> <args...>
    local label="$1" expect="$2" mode="$3" pre="$4"; shift 5
    printf '%s' "$pre" > "$_rs_state"; [ -n "$pre" ] && printf '\n' >> "$_rs_state"
    if [ "$mode" = clean ]; then
        rmmod() { grep -vx "$1" "$_rs_state" > "$_rs_state.n" || true; mv "$_rs_state.n" "$_rs_state"; return 0; }
    else
        rmmod() { return 0; }   # rmmod "succeeds" but the module stays loaded
    fi
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    assert_eq "$expect" "$rc" "$label: return code"
    if [ "$expect" = 3 ]; then
        assert_success "$label: UNTRACKED RESIDUAL is logged" grep -qF "UNTRACKED RESIDUAL" <<< "$out"
    else
        assert_failure "$label: no UNTRACKED RESIDUAL claim when the module was removed" grep -qF "UNTRACKED RESIDUAL" <<< "$out"
    fi
}
_rs_run "dot11ah, rmmod cannot remove" 3 stuck "" -- halow_load_dot11ah "$_rs_ko_d" 1
_rs_run "dot11ah, rmmod removes it"    1 clean "" -- halow_load_dot11ah "$_rs_ko_d" 1
_rs_run "mac80211, rmmod cannot remove" 3 stuck "" -- halow_ensure_mac80211_loaded
_rs_run "mac80211, rmmod removes it"    1 clean "" -- halow_ensure_mac80211_loaded
_rs_run "morse, rmmod cannot remove" 3 stuck "mac80211" -- halow_load_morse "$_rs_ko"
_rs_run "morse, rmmod removes it"    1 clean "mac80211" -- halow_load_morse "$_rs_ko"
halow_own_mark() { _real_own_mark "$@"; }
unset -f lsmod modprobe insmod rmmod
: > "$HALOW_FW_SYSFS_PATH"

unset -f halow_sys_mount_mode halow_sys_remount
: > "$HALOW_FW_SYSFS_PATH"

halow_test_teardown
echo "test_module_load: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
