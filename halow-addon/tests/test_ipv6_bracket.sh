#!/usr/bin/env bash
# Tests the temporary-mount bracket of ipv6.sh against the fake mount layer (tests/doubles/bin
# mount and umount, tests/fakes/fake_ipv6_mount.sh): the exact sequence of operations and the
# exact set of paths touched, fail-closed refusals at every step with the mount always cleaned
# up, a cleanup that cannot be verified (INCOMPLETE, record kept), interrupted brackets (the
# manager killed at each step) found through the mount table and cleaned up idempotently,
# and the names that must never reach a mount call (all, default, ., .., invalid).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./doubles/fakes_env.sh
halow_fakes_mnt_install
. ./fakes/fake_ipv6_mount.sh
fake_ipv6_guard_install

echo "== test_ipv6_bracket =="
PROC="$HALOW_TEST_TMP/fake-proc-sys"
export HALOW_PROC_SYS_DIR="$PROC"
CONF="$PROC/net/ipv6/conf"
OUT="$HALOW_TEST_TMP/out"

reset_all() {
    halow_fakes_mnt_install
    unset HALOW_FAKE_WRITE
    rm -rf "${PROC:?}" "${HALOW_STATE_DIR:?}/owns"
    mkdir -p "$CONF/all" "$CONF/default" "$PROC/net/ipv4"
    echo 0 > "$CONF/all/disable_ipv6"; echo 0 > "$CONF/default/disable_ipv6"
    echo 1 > "$PROC/net/ipv4/ip_forward"
    echo 0 > "$PROC/net/ipv6_other_sysctl" 2>/dev/null || true
    local i
    for i in "$@"; do mkdir -p "$CONF/$i"; echo 0 > "$CONF/$i/disable_ipv6"; echo 5 > "$CONF/$i/accept_ra"; done
}
val() { cat "$CONF/$1/disable_ipv6"; }
file_of() { printf '%s/%s/disable_ipv6' "$CONF" "$1"; }
tree_view() { (cd "$PROC" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s=%s\n' "$f" "$(cat "$f")"; done); }
stack_lines() { grep -c . "$HALOW_FAKE_MNT_DIR/stack" || true; }
ops() { fake_ipv6_calls | awk '{ print $1 }' | tr '\n' ' '; }
listed() { awk -v p="$1" '$5 == p { c++ } END { print c + 0 }' "$HALOW_PROC_MOUNTINFO"; }
log_of() { "$@" 2>&1; }

# A child process (so that an injected SIGKILL ends only the "manager") running one command
# with the fake write guard.
child() {   # <env assignments...> -- <command ...>
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    cat > "$HALOW_TEST_TMP/child.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_PROC_SYS_DIR="$PROC"
for lib in constants common ownership validate ipv6; do . "$HALOW_LIB_DIR/\$lib.sh"; done
. "$PWD/fakes/fake_ipv6_mount.sh"
fake_ipv6_guard_install
"\$@"
EOF
    ( env "${envs[@]}" bash "$HALOW_TEST_TMP/child.sh" "$@" ) > "$OUT" 2>&1
}

P="$(file_of wlu1)"

echo "-- a successful disable: the exact bracket, nothing else touched --"
reset_all wlu1 halow-br0
BEFORE="$(tree_view)"
assert_success "disable succeeds through the bracket" halow_ipv6_disable wlu1
assert_eq "1" "$(val wlu1)" "...the host shows 1 afterwards"
assert_eq "write bind remount-rw write remount-ro umount write " "$(ops)" "...plain write probe (refused), bind, remount rw, the write, remount ro, umount, refusal probe"
assert_eq "$P" "$(fake_ipv6_paths)" "...every operation was on that one exact file"
assert_eq "" "$(fake_ipv6_violations)" "...the fakes saw no out-of-bounds call"
assert_eq "0" "$(listed "$P")" "...the mount table no longer lists the file"
assert_eq "0" "$(stack_lines)" "...no temporary mount is left"
assert_eq "none" "$(fake_ipv6_top_mode "$P")" "...and a write is refused again"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...the original value stays recorded"
EXPECTED="$(sed 's|^\./net/ipv6/conf/wlu1/disable_ipv6=0$|./net/ipv6/conf/wlu1/disable_ipv6=1|' <<< "$BEFORE")"
assert_eq "$EXPECTED" "$(tree_view)" "only that value changed: not its accept_ra, not the bridge, not all/default, not ip_forward"
fake_ipv6_reset_calls
assert_success "a repeated disable (already 1) needs no mount at all" halow_ipv6_disable wlu1
assert_eq "" "$(fake_ipv6_calls)" "...no mount, no write"

echo "-- the order: bracket record before the first mount; original value before that --"
reset_all wlu1
cat > "$HALOW_TEST_TMP/order.sh" <<EOF
#!/usr/bin/env bash
echo "bind: orig=\$([ -e "$HALOW_STATE_DIR/owns/ipv6_wlu1" ] && cat "$HALOW_STATE_DIR/owns/ipv6_wlu1") bracket=\$([ -e "$HALOW_STATE_DIR/owns/ipv6br_wlu1" ] && cat "$HALOW_STATE_DIR/owns/ipv6br_wlu1")" >> "$HALOW_TEST_TMP/order.log"
EOF
: > "$HALOW_TEST_TMP/order.log"
mount() { bash "$HALOW_TEST_TMP/order.sh"; command mount "$@"; }
halow_ipv6_disable wlu1 >/dev/null 2>&1
unset -f mount
assert_eq "bind: orig=0 bracket=ro" "$(grep '^bind' "$HALOW_TEST_TMP/order.log" | head -n 1)" "the original value and the bracket record exist when the first mount is made"

echo "-- restore goes through the same bracket --"
reset_all wlu1 halow-br0
halow_ipv6_disable wlu1 >/dev/null 2>&1
halow_ipv6_disable halow-br0 >/dev/null 2>&1
fake_ipv6_reset_calls
assert_success "restore_all succeeds" halow_ipv6_restore_all
assert_eq "0 0" "$(val wlu1) $(val halow-br0)" "...both interfaces have their recorded value back"
assert_eq "$(printf '%s\n%s' "$(file_of halow-br0)" "$P" | LC_ALL=C sort)" "$(fake_ipv6_paths)" "...only those two files were touched"
assert_eq "write bind remount-rw write remount-ro umount write write bind remount-rw write remount-ro umount write " "$(ops)" "...each through its own complete bracket (wlu1, then halow-br0)"
assert_eq "0" "$(stack_lines)" "...no temporary mount is left"
assert_eq "" "$(fake_ipv6_violations)" "...no out-of-bounds call"
assert_failure "...no record held" halow_ipv6_present
assert_eq "" "$(halow_own_list | grep -c '^ipv6br_' | grep -v '^0$' || true)" "...no bracket record held"

echo "-- a restore of an interface that was already off needs no bracket --"
reset_all wlu1
echo 1 > "$CONF/wlu1/disable_ipv6"
halow_ipv6_disable wlu1 >/dev/null 2>&1
fake_ipv6_reset_calls
assert_success "restore succeeds" halow_ipv6_restore_all
assert_eq "1" "$(val wlu1)" "...the value is as it was"
assert_eq "" "$(fake_ipv6_calls)" "...no mount and no write"

echo "-- refusals fail closed and the mount is always cleaned up --"
reset_all wlu1
HALOW_FAKE_MNT_FAIL=bind halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a refused bind mount: disable returns 1"
assert_success "...an error is logged" grep -q 'temporary bind mount.*refused' "$OUT"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
assert_eq "0" "$(stack_lines)" "...nothing is mounted"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...the original value record stays (as for any refused write)"
reset_all wlu1
HALOW_FAKE_MNT_FAIL=remount-rw halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a refused read-write remount: disable returns 1"
assert_success "...an error is logged" grep -q 'read-write remount.*refused' "$OUT"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
assert_eq "0" "$(stack_lines)" "...the bind mount was unmounted again"
assert_eq "0" "$(listed "$P")" "...and is not in the mount table"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
assert_eq "" "$(fake_ipv6_violations)" "...no out-of-bounds call"
reset_all wlu1
HALOW_FAKE_WRITE=refuse halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a write refused inside the bracket: disable returns 1"
assert_success "...an error is logged" grep -q 'write was refused' "$OUT"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
assert_eq "0" "$(stack_lines)" "...the cleanup still happened"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
reset_all wlu1
HALOW_FAKE_WRITE=noop halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a write that does not show on read-back: disable returns 1"
assert_success "...an error names the value read back" grep -q "reads '0' after turning it off" "$OUT"
assert_eq "0" "$(stack_lines)" "...the cleanup still happened"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
reset_all wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
HALOW_FAKE_MNT_FAIL=remount-rw halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a refused remount during restore: restore_all returns 1"
assert_success "...the record of the original value is kept" halow_own_check ipv6_wlu1
assert_eq "0" "$(stack_lines)" "...and nothing is left mounted"

echo "-- a cleanup that cannot be verified is INCOMPLETE and keeps its record --"
reset_all wlu1
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "2" "$rc" "umount refused: disable returns 2 (INCOMPLETE, stronger than 1)"
assert_success "...reported as INCOMPLETE" grep -q 'INCOMPLETE' "$OUT"
assert_eq "1" "$(listed "$P")" "...the mount is still listed (and the code saw it)"
assert_eq "ro" "$(fake_ipv6_top_mode "$P")" "...it was made read-only again as far as possible (remount ro)"
assert_success "...the bracket record is kept" halow_own_check ipv6br_wlu1
assert_success "...rollback sees it as residual ownership" grep -qx ipv6br_wlu1 <<< "$(halow_rollback_ipv6_keys)"
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "2" "$rc" "a second disable while the mount is still there (value already 1) does not answer 0"
assert_success "...and reports INCOMPLETE" grep -q INCOMPLETE "$OUT"
assert_success "halow_ipv6_present counts the held bracket record" halow_ipv6_present
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "restore_all returns 1 while the mount cannot be removed"
assert_success "...the bracket record and the original record are kept" bash -c '[ -e "$0/owns/ipv6br_wlu1" ] && [ -e "$0/owns/ipv6_wlu1" ]' "$HALOW_STATE_DIR"
assert_eq "1" "$(listed "$P")" "...the mount is still reported listed"
assert_success "a later restore (umount working again) cleans it up" halow_ipv6_restore_all
assert_eq "0" "$(stack_lines)" "...the mount is gone"
assert_failure "...bracket record cleared" halow_own_check ipv6br_wlu1
assert_failure "...no record held" halow_ipv6_present
assert_eq "0" "$(val wlu1)" "...and the recorded value is in place"

reset_all wlu1
echo 0 > "$HALOW_TEST_TMP/probe_n"
eval "$(declare -f _halow_ipv6_write | sed '1s/_halow_ipv6_write/_probe_orig_write/')"
_halow_ipv6_write() {   # refused for the first probe, then accepted even without any mount (a path that stayed writable)
    local n; n="$(cat "$HALOW_TEST_TMP/probe_n")"; echo $((n + 1)) > "$HALOW_TEST_TMP/probe_n"
    [ "$n" -ge 1 ] && { printf '%s\n' "$2" > "$1"; return 0; }
    return 1
}
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "2" "$rc" "a switch that still accepts writes after the unmount: disable returns 2 (INCOMPLETE)"
assert_success "...INCOMPLETE is reported" grep -q 'still accepts a write' "$OUT"
assert_success "...the bracket record is kept" halow_own_check ipv6br_wlu1
eval "$(declare -f _probe_orig_write | sed '1s/_probe_orig_write/_halow_ipv6_write/')"

reset_all wlu1
mkdir -p "$HALOW_TEST_TMP/nomt"
HALOW_PROC_MOUNTINFO="$HALOW_TEST_TMP/nomt/none" halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "an unreadable mount table: disable returns 1"
assert_eq "" "$(fake_ipv6_calls)" "...no mount and no write were attempted"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
HALOW_PROC_MOUNTINFO="$HALOW_TEST_TMP/nomt/none" halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "...and restore_all cannot claim success"

echo "-- interrupted brackets are found in the mount table and cleaned up --"
for crash in bind-before bind-after remount-rw-after write-after; do
    reset_all wlu1
    child HALOW_FAKE_MNT_CRASH="$crash" -- halow_ipv6_disable wlu1 2>/dev/null; rc=$?
    assert_eq "137" "$rc" "[$crash] the manager is killed at that step"
    assert_success "[$crash] the original value and the bracket record are on disk" bash -c '[ -e "$0/owns/ipv6br_wlu1" ] && [ "$(cat "$0/owns/ipv6_wlu1")" = 0 ]' "$HALOW_STATE_DIR"
    case "$crash" in
        bind-before) want_stack=0 ;;
        *) want_stack=1 ;;
    esac
    assert_eq "$want_stack" "$(stack_lines)" "[$crash] the stale mount state is as expected after the crash"
    if [ "$crash" = "remount-rw-after" ] || [ "$crash" = "write-after" ]; then
        assert_eq "rw" "$(fake_ipv6_top_mode "$P")" "[$crash] the stale mount is read-write (the dangerous state)"
    fi
    # A second manager run: rollback's restore finds it through the mount table.
    fake_ipv6_reset_calls
    halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
    assert_eq "0" "$rc" "[$crash] restore_all succeeds"
    assert_eq "0" "$(stack_lines)" "[$crash] the stale mount is gone"
    assert_eq "0" "$(listed "$P")" "[$crash] the mount table no longer lists it"
    assert_eq "none" "$(fake_ipv6_top_mode "$P")" "[$crash] a write is refused again"
    assert_failure "[$crash] the bracket record is cleared" halow_own_check ipv6br_wlu1
    assert_failure "[$crash] the original record is cleared" halow_own_check ipv6_wlu1
    assert_eq "0" "$(val wlu1)" "[$crash] the recorded original value is on the host"
    assert_eq "$P" "$(fake_ipv6_paths)" "[$crash] only that file was touched"
    assert_eq "" "$(fake_ipv6_violations)" "[$crash] no out-of-bounds call"
    fake_ipv6_reset_calls
    assert_success "[$crash] a repeated restore is idempotent" halow_ipv6_restore_all
    assert_eq "" "$(fake_ipv6_calls | grep -v '^write' || true)" "[$crash] ...with no mount operation at all"
done

reset_all wlu1
child HALOW_FAKE_MNT_CRASH=remount-rw-after -- halow_ipv6_disable wlu1 2>/dev/null
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "0" "$rc" "a new disable after a crash with a read-write mount left: succeeds"
assert_eq "1" "$(val wlu1)" "...IPv6 is off"
assert_eq "0" "$(stack_lines)" "...with no mount left (the stale one was cleaned first, not stacked on)"
assert_eq "0" "$(halow_own_get ipv6_wlu1)" "...and the first recorded value is kept"
assert_failure "...bracket record cleared" halow_own_check ipv6br_wlu1

echo "-- stacked and unrecorded mounts --"
reset_all wlu1 wlu1.sta1
printf '%s|rw\n%s|ro\n' "$P" "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
assert_eq "2" "$(listed "$P")" "(set-up) two mounts stacked on one file, no record at all"
assert_success "restore_all cleans a mount that has no record" halow_ipv6_restore_all
assert_eq "0" "$(listed "$P")" "...every stacked mount is gone"
assert_eq "" "$(fake_ipv6_violations)" "...no out-of-bounds call"
reset_all wlu1 wlu1.sta1
printf '%s|rw\n' "$(file_of wlu1.sta1)" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
halow_ipv6_disable wlu1 >/dev/null 2>&1
assert_eq "$(file_of wlu1.sta1)|rw" "$(cat "$HALOW_FAKE_MNT_DIR/stack")" "a disable of one interface leaves another interface's mount alone"
assert_eq "1" "$(val wlu1)" "...and still turned IPv6 off on its own interface"
assert_eq "$P" "$(fake_ipv6_paths | grep -v sta1)" "...touching only its own file"
reset_all wlu1
printf '%s|rw\n' "$CONF/all/disable_ipv6" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "0" "$rc" "a mount on the host-wide 'all' entry is not this add-on's: reported"
assert_success "...as a warning" grep -q "host-wide 'all'" "$OUT"
assert_eq "$CONF/all/disable_ipv6|rw" "$(cat "$HALOW_FAKE_MNT_DIR/stack")" "...and left alone (no umount call)"
assert_eq "" "$(fake_ipv6_calls | grep -v '^$' || true)" "...no operation was made on it"
reset_all wlu1
halow_own_mark ipv6br_default ro
halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a bracket record naming 'default' is never acted on and keeps the restore incomplete"
assert_eq "" "$(fake_ipv6_calls)" "...no mount call"

echo "-- a held record or a listed mount is never reported OK; an unrecorded stuck mount gets a record --"
reset_all wlu1
echo 1 > "$CONF/wlu1/disable_ipv6"
printf '%s|rw\n' "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "2" "$rc" "a writable mount that cannot be removed, value already 1: disable returns 2, not 0"
assert_success "...an INCOMPLETE line names it" grep -q 'INCOMPLETE' "$OUT"
assert_success "...an unrecorded mount got a bracket record before the failure" halow_own_check ipv6br_wlu1
assert_success "...rollback lists it as residual ownership" grep -qx ipv6br_wlu1 <<< "$(halow_rollback_ipv6_keys)"
assert_success "...and halow_ipv6_present counts the record alone" halow_ipv6_present
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "0" "$rc" "once the unmount works again the next disable cleans it up and returns 0"
assert_eq "0" "$(stack_lines)" "...with the mount gone"
assert_failure "...and the record cleared" halow_own_check ipv6br_wlu1
assert_eq "" "$(_halow_ipv6_bracket_marked)" "...no bracket record is held any more"
reset_all wlu1
printf '%s|rw\n' "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "restore_all with an unrecorded stuck mount that cannot be removed returns 1"
assert_success "...and leaves a bracket record (so rollback reports INCOMPLETE)" halow_own_check ipv6br_wlu1
assert_success "...which the rollback key list shows" grep -qx ipv6br_wlu1 <<< "$(halow_rollback_ipv6_keys)"
assert_success "a later restore_all (umount working) cleans it and the record" halow_ipv6_restore_all
assert_failure "...record cleared" halow_own_check ipv6br_wlu1
reset_all wlu1
halow_own_mark ipv6br_wlu1 ro
HALOW_PROC_MOUNTINFO="$HALOW_TEST_TMP/nomt/none" halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "2" "$rc" "an unreadable mount table with a held bracket record: disable returns 2"
reset_all wlu1
HALOW_PROC_MOUNTINFO="$HALOW_TEST_TMP/nomt/none" halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "an unreadable mount table and no record at all: the plain 1 (nothing of ours is known to be left)"
assert_failure "...no record was invented" halow_own_check ipv6br_wlu1

echo "-- the temporary-mount record list skips ownership temp files --"
reset_all wlu1
halow_own_mark ipv6br_wlu2 ro
: > "$HALOW_STATE_DIR/owns/ipv6br_wlu3.tmp.4242"
assert_eq "wlu2" "$(_halow_ipv6_bracket_marked)" "only the real record is listed, not ipv6br_wlu3.tmp.4242"
halow_ipv6_scrub_all >/dev/null 2>&1 || true
assert_eq "" "$(fake_ipv6_calls | grep -c wlu3 | grep -v '^0$' || true)" "...and the temp file never led to an operation on wlu3"
rm -f "$HALOW_STATE_DIR/owns/ipv6br_wlu3.tmp.4242"

echo "-- the interface is gone while a stale mount is listed --"
reset_all wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
rm -rf "${CONF:?}/wlu1"
printf '%s|rw\n' "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
halow_ipv6_restore_all > "$OUT" 2>&1; rc=$?
assert_eq "0" "$rc" "restore_all: interface gone, stale mount cleaned (readable table): 0"
assert_eq "0" "$(stack_lines)" "...the stale mount is gone"
assert_failure "...the record of the vanished interface is cleared" halow_own_check ipv6_wlu1
assert_failure "...no bracket record is left" halow_own_check ipv6br_wlu1
reset_all wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
rm -rf "${CONF:?}/wlu1"
printf '%s|rw\n' "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
assert_success "forget_if_gone: interface gone, stale mount listed: cleaned and forgotten" halow_ipv6_forget_if_gone wlu1
assert_eq "0" "$(stack_lines)" "...the stale mount is gone"
assert_failure "...the record is cleared" halow_own_check ipv6_wlu1
reset_all wlu1
halow_ipv6_disable wlu1 >/dev/null 2>&1
rm -rf "${CONF:?}/wlu1"
printf '%s|rw\n' "$P" > "$HALOW_FAKE_MNT_DIR/stack"; ( . "$HALOW_FAKE_BIN/_mntlib.sh"; fm_render )
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_forget_if_gone wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "forget_if_gone: the stale mount cannot be removed: 1"
assert_success "...the original record is kept" halow_own_check ipv6_wlu1
assert_success "...and a bracket record exists" halow_own_check ipv6br_wlu1

echo "-- the bracket's 'listed exactly once' guard --"
reset_all wlu1
mount() { case "$*" in "-o bind "*) return 0 ;; esac; command mount "$@"; }
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
unset -f mount
assert_eq "1" "$rc" "a bind that leaves NO entry in the mount table: disable fails closed (1)"
assert_success "...naming the guard" grep -q 'not listed exactly once' "$OUT"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
assert_eq "" "$(fake_ipv6_calls | grep remount-rw || true)" "...never remounted read-write"
assert_failure "...the bracket record is cleared (cleanup verified)" halow_own_check ipv6br_wlu1
reset_all wlu1
mount() { command mount "$@"; case "$*" in "-o bind "*) command mount "$@" ;; esac; }
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
unset -f mount
assert_eq "1" "$rc" "a bind that leaves TWO entries: disable fails closed (1)"
assert_success "...naming the guard" grep -q 'not listed exactly once' "$OUT"
assert_eq "0" "$(val wlu1)" "...the value is unchanged"
assert_eq "" "$(fake_ipv6_calls | grep remount-rw || true)" "...never remounted read-write"
assert_eq "0" "$(stack_lines)" "...both entries were unmounted"
assert_failure "...the bracket record is cleared" halow_own_check ipv6br_wlu1
reset_all wlu1
mount() { command mount "$@"; case "$*" in "-o bind "*) command mount "$@" ;; esac; }
HALOW_FAKE_MNT_FAIL=umount halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
unset -f mount
assert_eq "2" "$rc" "two entries and the unmount refused: INCOMPLETE (2), record kept"
assert_success "...the record is kept" halow_own_check ipv6br_wlu1

echo "-- names that never reach a mount call --"
reset_all wlu1
for bad in all default . .. 'wl/u1' '' 'a b' 'wlu1;x' '../all' 'toolonginterfacename'; do
    fake_ipv6_reset_calls
    halow_ipv6_disable "$bad" >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "disable '$bad' is refused"
    assert_eq "" "$(fake_ipv6_calls)" "...with no mount call and no write"
done
assert_eq "0 0" "$(cat "$CONF/all/disable_ipv6") $(cat "$CONF/default/disable_ipv6")" "all and default were not changed"
assert_eq "" "$(halow_own_list | grep -E '^ipv6(br)?_(all|default)$' || true)" "...and no record names them"
for bad in all default; do
    halow_own_mark "ipv6_$bad" 0
    fake_ipv6_reset_calls
    halow_ipv6_restore_all >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "a record for '$bad' is not restored (kept for review)"
    assert_eq "" "$(fake_ipv6_calls)" "...no mount call and no write"
    halow_own_clear "ipv6_$bad"
done
assert_eq "1" "$(_halow_ipv6_set all 1 2>/dev/null; echo $?)" "the primitive refuses 'all' by name too"
assert_eq "1" "$(_halow_ipv6_set wlu1 7; echo $?)" "...and a value other than 0 or 1"
assert_eq "" "$(fake_ipv6_calls)" "...with no mount call"

echo "-- the bracket record cannot be written: no mount call, failure --"
reset_all wlu1
BEFORE="$(tree_view)"
eval "$(declare -f halow_own_mark | sed '1s/^halow_own_mark/_real_own_mark/')"
halow_own_mark() { case "$1" in ipv6br_*) return 1 ;; esac; _real_own_mark "$@"; }
fake_ipv6_reset_calls
halow_ipv6_disable wlu1 > "$OUT" 2>&1; rc=$?
assert_eq "1" "$rc" "a failed bracket record write: disable returns 1"
assert_success "...an error is logged" grep -q 'could not record the temporary mount' "$OUT"
assert_eq "" "$(fake_ipv6_calls | grep -E '^(bind|remount-rw|remount-ro|umount)' || true)" "...no mount call of any kind was made"
assert_eq "$BEFORE" "$(tree_view)" "...and nothing was written"
assert_eq "0" "$(listed "$P")" "...the mount table does not list the file"
assert_eq "0" "$(stack_lines)" "...no temporary mount is left"
fake_ipv6_reset_calls
halow_ipv6_restore_all >/dev/null 2>&1
assert_eq "" "$(fake_ipv6_calls | grep -E '^(bind|remount-rw|remount-ro|umount)' || true)" "...restore makes no mount call either"
eval "$(declare -f _real_own_mark | sed '1s/^_real_own_mark/halow_own_mark/')"
unset -f _real_own_mark

echo "-- '.' and '..' never reach a mount even when the files they would name exist --"
reset_all wlu1
echo 0 > "$CONF/disable_ipv6"          # what "." would name
echo 0 > "$CONF/../disable_ipv6"       # what ".." would name
BEFORE="$(tree_view)"
for bad in . ..; do
    fake_ipv6_reset_calls
    halow_ipv6_disable "$bad" >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "disable '$bad' is refused with those files present"
    assert_eq "" "$(fake_ipv6_calls)" "...no mount call and no write"
    assert_failure "...no record names it" halow_own_check "ipv6_$bad"
    assert_eq "$BEFORE" "$(tree_view)" "...and nothing changed"
done
for bad in . ..; do
    halow_own_mark "ipv6_$bad" 0
    fake_ipv6_reset_calls
    halow_ipv6_restore_all >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "a record for '$bad' is not restored (kept for review)"
    assert_eq "" "$(fake_ipv6_calls)" "...no mount call and no write"
    halow_own_clear "ipv6_$bad"
done
assert_eq "$BEFORE" "$(tree_view)" "...the files are untouched"
assert_eq "1" "$(_halow_ipv6_set . 1 2>/dev/null; echo $?)" "the primitive refuses '.' by name too"
assert_eq "1" "$(_halow_ipv6_set .. 1 2>/dev/null; echo $?)" "...and '..'"
assert_eq "" "$(fake_ipv6_calls)" "...with no mount call"

echo "-- the real tools are never reached by these tests --"
assert_success "the fake mount is first on PATH" bash -c '[ "$(command -v mount)" = "$0/mount" ]' "$HALOW_FAKE_BIN"
assert_success "the fake umount is first on PATH" bash -c '[ "$(command -v umount)" = "$0/umount" ]' "$HALOW_FAKE_BIN"

echo "-- strict shell options and a corrupted IFS --"
reset_all wlu1 halow-br0
cat > "$HALOW_TEST_TMP/strict.sh" <<EOF
#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_PROC_SYS_DIR="$PROC"
for lib in constants common ownership validate ipv6; do . "$HALOW_LIB_DIR/\$lib.sh"; done
. "$PWD/fakes/fake_ipv6_mount.sh"
fake_ipv6_guard_install
halow_ipv6_disable wlu1
halow_ipv6_disable halow-br0
IFS='' halow_ipv6_restore_all
if HALOW_FAKE_MNT_FAIL=umount halow_ipv6_disable wlu1; then echo wrong; else echo failed=\$?; fi
echo STRICT_REACHED_THE_END
EOF
_out="$(bash "$HALOW_TEST_TMP/strict.sh" 2>&1)"; _rc=$?
assert_eq "0" "$_rc" "the bracket runs under errexit/nounset/pipefail/inherit_errexit"
assert_success "...an INCOMPLETE bracket returns 2 without aborting" grep -q "failed=2" <<< "$_out"
assert_success "...and the script reached its end" grep -q STRICT_REACHED_THE_END <<< "$_out"

halow_test_teardown
echo "test_ipv6_bracket: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
