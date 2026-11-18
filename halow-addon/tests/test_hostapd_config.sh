#!/usr/bin/env bash
# Tests hostapd_config.sh: correct interface/ssid substitution (including values that
# would have broken the project's own earlier `sed`-based substitution — '/' and '&'),
# passphrase length validation, idempotent passphrase append, and that the passphrase
# never appears in this script's own stdout/stderr.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_hostapd_config =="
halow_test_setup

template="$HALOW_TEST_TMP/hostapd_s1g.conf"
cat > "$template" <<'EOF'
interface=wlan0
ssid=test
country_code=AU
channel=43
op_class=53
wpa=2
wpa_key_mgmt=SAE
EOF

dest="$HALOW_TEST_TMP/rendered.conf"

assert_failure "a passphrase shorter than 8 characters is refused" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "short" "$dest"
assert_file_absent "$dest" "nothing is rendered when the passphrase is rejected"

assert_success "a valid passphrase renders successfully" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
assert_eq "interface=wlu1" "$(grep '^interface=' "$dest")" "interface= is substituted correctly"
assert_eq "ssid=MyNet" "$(grep '^ssid=' "$dest")" "ssid= is substituted correctly"
assert_eq "wpa_passphrase=a-valid-passphrase" "$(grep '^wpa_passphrase=' "$dest")" "wpa_passphrase= is appended"
assert_eq "8" "$(wc -l < "$dest" | tr -d ' ')" "no extra lines are introduced beyond the 7-line template plus the one appended passphrase line"

# A real defect class this project's own earlier `sed`-based substitution had: a
# replacement value containing '/' or '&' corrupts or redirects a sed substitution.
# awk -v treats the value as pure data, so both must now render correctly.
assert_success "an SSID containing a forward slash renders correctly (would have broken sed)" \
    halow_render_hostapd_config "$template" "wlu1" "My/Net" "a-valid-passphrase" "$dest"
assert_eq "ssid=My/Net" "$(grep '^ssid=' "$dest")" "the forward slash survives intact"

assert_success "an SSID containing an ampersand renders correctly (would have broken sed)" \
    halow_render_hostapd_config "$template" "wlu1" "My&Net" "a-valid-passphrase" "$dest"
assert_eq "ssid=My&Net" "$(grep '^ssid=' "$dest")" "the ampersand survives intact, not expanded to the whole matched line"

# Idempotent re-render from the pristine template never duplicates the line.
halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest" >/dev/null
count="$(grep -c '^wpa_passphrase=' "$dest")"
assert_eq "1" "$count" "re-rendering does not duplicate the wpa_passphrase line"

# The passphrase must never appear in this function's own logged output.
out="$(halow_render_hostapd_config "$template" "wlu1" "MyNet" "super-secret-value" "$dest" 2>&1)"
case "$out" in
    *super-secret-value*)
        echo "  FAIL: the passphrase leaked into logged output"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        ;;
    *)
        echo "  ok: the passphrase does not appear in logged output"
        ;;
esac
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))

echo "== test_hostapd_config: hardening (permissive umask, failure injection) =="

# Regression test: the rendered (password-bearing) file must be mode 600 even under a
# fully permissive inherited umask — not merely "whatever the umask allowed, then
# chmod'd afterward, assumed to have worked" (the exact defect this hardening fixes).
rm -f "$dest"
( umask 000; halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest" ) >/dev/null
assert_eq "600" "$(stat -c '%a' "$dest" 2>/dev/null)" \
    "the rendered file is mode 600 even under a fully permissive inherited umask (000)"

assert_failure "a missing template fails closed" \
    halow_render_hostapd_config "$HALOW_TEST_TMP/does-not-exist.conf" "wlu1" "MyNet" "a-valid-passphrase" "$dest"

# Failure injection: a chmod failure on the temporary (password-bearing) file must
# remove that temp file and return non-zero — never silently logging success afterward.
rm -f "$dest"
chmod() { return 1; }
assert_failure "a chmod failure on the temporary file fails closed, not merely logged" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
unset -f chmod
leftover="$(ls "$dest".halow-tmp.* 2>/dev/null || true)"
assert_eq "" "$leftover" "no stray password-bearing temporary file is left behind after a chmod failure"
assert_file_absent "$dest" "nothing was published after a chmod failure"

# Failure injection: the final publication (mv) itself failing must remove the
# password-bearing temporary file and return non-zero.
rm -f "$dest"
mv() { return 1; }
assert_failure "a failed final publication (mv) fails closed" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
unset -f mv
leftover="$(ls "$dest".halow-tmp.* 2>/dev/null || true)"
assert_eq "" "$leftover" "no stray password-bearing temporary file is left behind after a failed publication"
assert_file_absent "$dest" "nothing was published after a failed mv"

# Failure injection (the fail-closed gap this change fixes): if the FINAL file's own
# mode cannot be confirmed as exactly 600 after publication, the already-published,
# password-bearing file at $dest must itself be removed before returning failure — an
# earlier version reported the failure but left that file in place.
rm -f "$dest"
stat() { return 1; }
assert_failure "an unreadable post-publication mode fails closed" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
unset -f stat
assert_file_absent "$dest" "the published destination file is removed when its own mode cannot be read"
leftover="$(ls "$dest".halow-tmp.* 2>/dev/null || true)"
assert_eq "" "$leftover" "no stray password-bearing temporary file remains either"

rm -f "$dest"
stat() { echo "644"; }
assert_failure "a mismatching (non-600) post-publication mode fails closed" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
unset -f stat
assert_file_absent "$dest" "the published destination file is removed when its own mode does not match 600"
leftover="$(ls "$dest".halow-tmp.* 2>/dev/null || true)"
assert_eq "" "$leftover" "no stray password-bearing temporary file remains either"

# Confirm the normal successful path is unaffected by this fix: a real render (real,
# unstubbed `stat`) still succeeds and still produces a mode-600 destination file.
rm -f "$dest"
assert_success "the normal successful render still succeeds after this fix" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
assert_eq "600" "$(stat -c '%a' "$dest" 2>/dev/null)" \
    "the normal successful render still produces a mode-600 destination file"

# Failure injection: the passphrase-line write itself failing (simulated by a failing
# printf) must remove the temporary file — it may already hold the passphrase — and
# return non-zero, never leaving a half-written secret-bearing file behind.
rm -f "$dest"
printf() { return 1; }
assert_failure "a failed passphrase-line write fails closed" \
    halow_render_hostapd_config "$template" "wlu1" "MyNet" "a-valid-passphrase" "$dest"
unset -f printf
leftover="$(ls "$dest".halow-tmp.* 2>/dev/null || true)"
assert_eq "" "$leftover" "no stray password-bearing temporary file is left behind after a failed passphrase write"
assert_file_absent "$dest" "nothing was published after a failed passphrase write"

halow_test_teardown

echo "== test_hostapd_config: hostapd_s1g identity matching — all four outcomes, including the unreadable-candidate-wins-over-a-match fix =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"

# halow_test_setup re-sources every production lib exactly once, at the TOP of this
# setup/teardown pair -- it is NOT re-run between the scenarios below. `unset -f` on a
# shared helper therefore permanently DELETES it for the rest of this whole section, it
# does not "restore" the real definition. A real, if subtle, test-authoring defect this
# review's own adversarial pass found while re-verifying this very file: an earlier
# version of the "real, unrelated process, no stubbing" scenario below ran with
# halow_process_comm/halow_process_cmdline_contains already deleted by an `unset -f`
# two scenarios earlier, so it silently exercised bash's own "command not found" fallback
# (exit 127) rather than the real production functions it claimed to test -- happening to
# still report success only because a 127 exit, like a genuine mismatch, does not equal
# the function's own "0 = match" case. Real definitions are saved ONCE here and restored
# on demand instead of ever being deleted.
eval "$(declare -f halow_process_comm | sed '1s/halow_process_comm/_real_process_comm_for_test/')"
eval "$(declare -f halow_process_cmdline_contains | sed '1s/halow_process_cmdline_contains/_real_process_cmdline_contains_for_test/')"
_restore_real_process_helpers() {
    eval "$(declare -f _real_process_comm_for_test | sed '1s/_real_process_comm_for_test/halow_process_comm/')"
    eval "$(declare -f _real_process_cmdline_contains_for_test | sed '1s/_real_process_cmdline_contains_for_test/halow_process_cmdline_contains/')"
}

# --- Positive match: a real, alive process, with comm/cmdline stubbed to this package's
# own exact identity. ---
halow_process_comm() { echo "hostapd_s1g"; }
halow_process_cmdline_contains() { return 0; }
( sleep 30 ) &
matched_pid=$!
halow_hostapd_identity_matches "$matched_pid" "$hconf"
assert_eq "0" "$?" "a positively matching pid reports exit code 0 (MATCH)"
kill "$matched_pid" 2>/dev/null; wait "$matched_pid" 2>/dev/null || true
_restore_real_process_helpers

# --- Mismatched command line: comm matches, but the cmdline check (real or stubbed)
# reports a definite non-match -- this is a different process, by exact rule. ---
halow_process_comm() { echo "hostapd_s1g"; }
halow_process_cmdline_contains() { return 1; }
( sleep 30 ) &
mismatch_pid=$!
halow_hostapd_identity_matches "$mismatch_pid" "$hconf"
assert_eq "1" "$?" "a comm-match but cmdline-mismatch pid reports exit code 1 (MISMATCH), never signalled"
kill "$mismatch_pid" 2>/dev/null; wait "$mismatch_pid" 2>/dev/null || true
_restore_real_process_helpers

# --- Unrelated process entirely (comm itself does not match) -- a real `sleep`, no
# stubbing at all, confirms the real halow_process_comm genuinely distinguishes it. The
# restore above (not a delete) guarantees the REAL functions are genuinely in effect here. ---
( sleep 30 ) &
unrelated_pid=$!
halow_hostapd_identity_matches "$unrelated_pid" "$hconf"
assert_eq "1" "$?" "a real, unrelated process (comm 'sleep') reports exit code 1 (MISMATCH)"
kill "$unrelated_pid" 2>/dev/null; wait "$unrelated_pid" 2>/dev/null || true

# --- Unreadable cmdline: comm matches, but the cmdline cannot be read at all -- this is
# UNKNOWN, never treated as either a match or positive evidence of absence. ---
halow_process_comm() { echo "hostapd_s1g"; }
halow_process_cmdline_contains() { return 2; }
( sleep 30 ) &
unknown_pid=$!
halow_hostapd_identity_matches "$unknown_pid" "$hconf"
assert_eq "2" "$?" "an alive, comm-matching pid whose cmdline cannot be read reports exit code 2 (UNKNOWN), never a positive match"
kill "$unknown_pid" 2>/dev/null; wait "$unknown_pid" 2>/dev/null || true
_restore_real_process_helpers
unset -f _real_process_comm_for_test _real_process_cmdline_contains_for_test _restore_real_process_helpers 2>/dev/null || true

# --- Confirmed absent: a pid that is simply not alive at all. ---
( sleep 0.1 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
halow_hostapd_identity_matches "$dead_pid" "$hconf"
assert_eq "3" "$?" "a pid that is not alive at all reports exit code 3 (CONFIRMED ABSENT)"

halow_test_teardown

echo "== test_hostapd_config: halow_find_hostapd_by_identity — none / one / multiple / an unreadable candidate always wins =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
: > "$hconf"

halow_hostapd_identity_matches() { return 1; }
halow_find_hostapd_by_identity "$hconf" >/dev/null
assert_eq "1" "$?" "zero matches (every candidate's identity read cleanly and did not match) reports exit code 1, trustworthy"
unset -f halow_hostapd_identity_matches

# --- The specific bug fixed during development: one positively-matching candidate, PLUS a
# second same-comm candidate whose cmdline could not be read, must report UNKNOWN (3) --
# never the single positive match (0). An earlier version only consulted "was anything
# unreadable" when zero positive matches were found, so this exact combination would have
# confidently returned the one match as safe to signal, missing that the unreadable
# candidate's own identity could not be ruled out. Simulated by stubbing
# halow_hostapd_identity_matches itself (deterministic control over the scan's own
# per-candidate results, independent of how many real processes happen to exist on this
# host) to report one match for a chosen real pid and UNKNOWN for a second real pid, both
# alive for the scan to iterate over. ---
( sleep 30 ) & match_pid=$!
( sleep 30 ) & unknown_pid=$!
halow_hostapd_identity_matches() {
    case "$1" in
        "$match_pid") return 0 ;;
        "$unknown_pid") return 2 ;;
        *) return 1 ;;
    esac
}
halow_find_hostapd_by_identity "$hconf" >/dev/null
assert_eq "3" "$?" "one positive match plus one unreadable candidate reports UNKNOWN (3), never the single positive match"
unset -f halow_hostapd_identity_matches
kill "$match_pid" "$unknown_pid" 2>/dev/null
wait "$match_pid" "$unknown_pid" 2>/dev/null || true

halow_test_teardown

echo "== test_hostapd_config: halow_hostapd_determine_outcome — the shared decision, including mismatch's own mandatory secondary scan =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"

# See the identical note in the identity-matching section above: halow_test_setup only
# re-sources the real production libs ONCE, at the top of this whole setup/teardown pair
# -- an `unset -f` on either shared helper below would PERMANENTLY DELETE it for every
# later scenario in this section, not "restore" the real definition. The dead-pid scenario
# below genuinely needs the REAL halow_hostapd_identity_matches (so its own early
# `kill -0` check, not a stub, is what proves CONFIRMED ABSENT); real definitions are
# saved once and restored on demand instead of ever being deleted.
eval "$(declare -f halow_hostapd_identity_matches | sed '1s/halow_hostapd_identity_matches/_real_hostapd_identity_matches_for_test/')"
eval "$(declare -f halow_find_hostapd_by_identity | sed '1s/halow_find_hostapd_by_identity/_real_find_hostapd_by_identity_for_test/')"
_restore_real_hostapd_identity_fns() {
    eval "$(declare -f _real_hostapd_identity_matches_for_test | sed '1s/_real_hostapd_identity_matches_for_test/halow_hostapd_identity_matches/')"
    eval "$(declare -f _real_find_hostapd_by_identity_for_test | sed '1s/_real_find_hostapd_by_identity_for_test/halow_find_hostapd_by_identity/')"
}

# --- No pid file at all: falls straight to the scan. ---
rm -f "$hpidfile"
halow_find_hostapd_by_identity() { return 1; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "confirmed_absent" "$HALOW_HOSTAPD_OUTCOME" "no pid file + a clean scan finding nothing = confirmed_absent"
_restore_real_hostapd_identity_fns

# --- Pid file names a positively-matching, alive process: owned, directly, no scan. ---
( sleep 30 ) & owned_pid=$!
echo "$owned_pid" > "$hpidfile"
halow_hostapd_identity_matches() { [ "$1" = "$owned_pid" ] && return 0 || return 1; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "owned" "$HALOW_HOSTAPD_OUTCOME" "a pid file naming a positively-matching pid resolves directly to owned"
assert_eq "$owned_pid" "$HALOW_HOSTAPD_TARGET_PID" "the target pid is the one the pid file named"
kill "$owned_pid" 2>/dev/null; wait "$owned_pid" 2>/dev/null || true
_restore_real_hostapd_identity_fns

# --- Pid file names a DEAD pid (identity result 3) -- this alone proves only that THAT
# pid is gone, never that no instance of this package's own process is running elsewhere
# under a different pid. Fixed during development: an earlier version treated this as an
# immediate, terminal confirmed_absent, skipping the mandatory secondary scan entirely --
# exactly the same unresolvable-absence gap the mismatch case (below) already closes.
# A dead pid now falls through to the SAME mandatory secondary scan, resolved the SAME
# four ways. Uses a real, genuinely dead pid (so identity_matches's own early `kill -0`
# check is what genuinely produces outcome 3, not a stub standing in for it) throughout
# all four cases below; only halow_find_hostapd_by_identity (the secondary scan itself)
# is stubbed, to deterministically control its own result. ---
( sleep 0.1 ) & dead_pid=$!; wait "$dead_pid" 2>/dev/null || true
echo "$dead_pid" > "$hpidfile"

# Case 1: the secondary scan finds nothing -- confirmed_absent.
halow_find_hostapd_by_identity() { return 1; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "confirmed_absent" "$HALOW_HOSTAPD_OUTCOME" "a dead recorded pid whose secondary scan finds nothing resolves to confirmed_absent"

# Case 2: the secondary scan finds this package's own REAL instance alive under a
# DIFFERENT pid -- owned, with the scan's own pid as the target (never the dead one).
( sleep 30 ) & dead_case_real_pid=$!
halow_find_hostapd_by_identity() { printf '%s' "$dead_case_real_pid"; return 0; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "owned" "$HALOW_HOSTAPD_OUTCOME" "a dead recorded pid whose secondary scan finds a real instance elsewhere resolves to owned"
assert_eq "$dead_case_real_pid" "$HALOW_HOSTAPD_TARGET_PID" "the target pid is the one the secondary scan found, never the dead recorded pid"
kill "$dead_case_real_pid" 2>/dev/null; wait "$dead_case_real_pid" 2>/dev/null || true

# Case 3: the secondary scan finds more than one candidate -- ambiguous.
halow_find_hostapd_by_identity() { return 2; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "ambiguous" "$HALOW_HOSTAPD_OUTCOME" "a dead recorded pid whose secondary scan is ambiguous resolves to ambiguous, never guessed at"

# Case 4: the secondary scan itself encounters an unreadable same-name candidate --
# unknown, never conflated with "zero matches, confirmed absent".
halow_find_hostapd_by_identity() { return 3; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "unknown" "$HALOW_HOSTAPD_OUTCOME" "a dead recorded pid whose secondary scan encounters an unreadable candidate resolves to unknown, never confirmed_absent"
_restore_real_hostapd_identity_fns

# --- Pid file names a pid whose identity is unreadable: unknown directly, no scan. ---
( sleep 30 ) & unk_pid=$!
echo "$unk_pid" > "$hpidfile"
halow_hostapd_identity_matches() { [ "$1" = "$unk_pid" ] && return 2 || return 1; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "unknown" "$HALOW_HOSTAPD_OUTCOME" "a pid file naming a pid with unreadable identity resolves directly to unknown"
kill "$unk_pid" 2>/dev/null; wait "$unk_pid" 2>/dev/null || true
_restore_real_hostapd_identity_fns

# --- Pid file names a DEFINITE MISMATCH (an unrelated, real, live process) -- this must
# trigger a secondary, full scan, never settle for "mismatch" as a final answer. Case 1:
# the scan confirms our own process is genuinely absent elsewhere too -- the unrelated
# process at the stale recorded pid is NEVER touched or signalled; the overall outcome
# resolves to confirmed_absent via the scan. The REAL halow_hostapd_identity_matches
# (just restored above) is what must genuinely return MISMATCH (1) here against the real,
# unrelated `sleep` process -- not a missing-function coincidence. ---
( sleep 30 ) & unrelated_pid=$!
echo "$unrelated_pid" > "$hpidfile"
halow_find_hostapd_by_identity() { return 1; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "confirmed_absent" "$HALOW_HOSTAPD_OUTCOME" "a mismatch whose secondary scan finds nothing resolves to confirmed_absent -- the unrelated process is never touched"
assert_success "the unrelated process at the stale recorded pid is still alive (never touched)" kill -0 "$unrelated_pid"

# --- Case 2: the secondary scan finds this package's own REAL instance under a
# DIFFERENT pid than the one recorded -- the overall outcome adopts that pid as the
# target, again never touching the unrelated process at the originally recorded pid.
# (The pid file still names the same real, unrelated process from case 1 above -- its
# own real identity-mismatch is exercised again here, deliberately.) ---
( sleep 30 ) & real_owned_pid=$!
halow_find_hostapd_by_identity() { printf '%s' "$real_owned_pid"; return 0; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "owned" "$HALOW_HOSTAPD_OUTCOME" "a mismatch whose secondary scan finds a real instance elsewhere resolves to owned"
assert_eq "$real_owned_pid" "$HALOW_HOSTAPD_TARGET_PID" "the target pid is the one the SECONDARY SCAN found, not the originally recorded (mismatched) pid"
assert_success "the unrelated process at the originally recorded (mismatched) pid is still alive (never touched)" kill -0 "$unrelated_pid"
kill "$real_owned_pid" "$unrelated_pid" 2>/dev/null
wait "$real_owned_pid" "$unrelated_pid" 2>/dev/null || true

# --- Case 3: the secondary scan itself cannot resolve things (ambiguous/unknown) -- the
# overall outcome reflects THAT, not a bare, less-informative "mismatch". ---
( sleep 30 ) & unrelated_pid2=$!
echo "$unrelated_pid2" > "$hpidfile"
halow_find_hostapd_by_identity() { return 2; }
halow_hostapd_determine_outcome "$hconf"
assert_eq "ambiguous" "$HALOW_HOSTAPD_OUTCOME" "a mismatch whose secondary scan is itself ambiguous resolves to ambiguous, not a bare unresolved mismatch"
kill "$unrelated_pid2" 2>/dev/null; wait "$unrelated_pid2" 2>/dev/null || true
unset -f _real_hostapd_identity_matches_for_test _real_find_hostapd_by_identity_for_test _restore_real_hostapd_identity_fns 2>/dev/null || true

halow_test_teardown

echo "== test_hostapd_config: halow_start_hostapd — NOT called via command substitution; proves prompt return, a live pid, with ownership established beforehand =="
halow_test_setup
hbin="$HALOW_TEST_TMP/fake_hostapd.sh"
cat > "$hbin" <<'EOF'
#!/usr/bin/env bash
sleep 20
EOF
chmod +x "$hbin"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"

# Lifecycle ownership is established FIRST, exactly as the real orchestration (`run`)
# does -- halow_start_hostapd itself no longer marks ownership.
assert_success "halow_hostapd_pre_start_check succeeds against a clean state" \
    halow_hostapd_pre_start_check "$hconf"

# --- THE regression test for the command-substitution defect this change fixes. The
# child sleeps for 20 SECONDS -- a short-lived child whose own eventual exit could let a
# broken, blocking call "pass" by coincidence is deliberately NOT used here. Called as a
# PLAIN STATEMENT (never `$(...)`), exactly as `run` now does, reading the started pid
# back from HALOW_LAST_STARTED_PID afterward. ---
start_ts=$(date +%s)
halow_start_hostapd "$hbin" "$hlog" "$hconf"
start_status=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

assert_eq "0" "$start_status" "halow_start_hostapd succeeds"

# A generous upper bound: comfortably covers this function's own built-in 1-second
# liveness-check sleep plus real test-harness overhead, while remaining far short of the
# child's own full 20-second lifetime -- a regression to the command-substitution defect
# (which would block the ENTIRE call for the full 20 seconds) is unambiguously caught by
# this bound, not merely by coincidence of the child eventually exiting on its own.
if [ "$elapsed" -le 5 ]; then
    echo "  ok: halow_start_hostapd returned promptly (${elapsed}s) while its own child is a 20-second sleep, still running"
else
    echo "  FAIL: halow_start_hostapd took ${elapsed}s to return (expected <= 5s) -- it likely blocked on its own child's long lifetime, the exact command-substitution defect this test exists to catch"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))

assert_success "the pid returned via HALOW_LAST_STARTED_PID is still alive immediately after the call returns" \
    kill -0 "$HALOW_LAST_STARTED_PID"
assert_eq "$HALOW_LAST_STARTED_PID" "$(cat "$hpidfile")" "the same pid is persisted to its own pid file, for the separate finish process"
assert_success "ownership was already recorded (by the pre-start check, before this call)" halow_own_check "hostapd_process"

kill "$HALOW_LAST_STARTED_PID" 2>/dev/null; wait "$HALOW_LAST_STARTED_PID" 2>/dev/null || true
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile"

halow_test_teardown

echo "== test_hostapd_config: halow_start_hostapd runs hostapd_s1g with the environment it inherited: nothing is added to the child's PATH, and no helper program is looked up or needed =="
halow_test_setup
# hostapd_s1g talks to the driver over nl80211 vendor commands and runs no helper program,
# so the launcher must not put the artifacts directory (or anything else) on the child's PATH.
# The stand-in records the PATH it was started with and whether it can resolve the helper
# program that an earlier hostapd release line ran by bare name. Even with an executable of
# that name present in the artifacts directory, the child must not find it.
mc_out="$HALOW_TEST_TMP/child_env"
# This file is a canary on purpose: it must exist for the test to mean anything (it proves
# the child does NOT find an executable of that name through any PATH the launcher set up).
cat > "$HALOW_ARTIFACTS_DIR/morse_cli" <<'EOF'
#!/usr/bin/env bash
echo "helper-ran"
EOF
chmod +x "$HALOW_ARTIFACTS_DIR/morse_cli"
hbin="$HALOW_TEST_TMP/fake_hostapd_env.sh"
cat > "$hbin" <<EOF
#!/usr/bin/env bash
{ echo "child-path=\$PATH"; sh -c 'command -v morse_cli >/dev/null && echo CHILD_RESOLVES_HELPER || echo CHILD_DOES_NOT_RESOLVE_HELPER'; } > "$mc_out" 2>&1
sleep 3
EOF
chmod +x "$hbin"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"; hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"; : > "$hconf"
_path_before="$PATH"
halow_hostapd_pre_start_check "$hconf" >/dev/null 2>&1
halow_start_hostapd "$hbin" "$hlog" "$hconf"
sleep 1
assert_success "the stand-in child ran and recorded its environment" test -s "$mc_out"
assert_success "the child's PATH is exactly the PATH the launcher inherited" grep -qxF "child-path=$_path_before" "$mc_out"
assert_failure "the artifacts directory is not on the child's PATH" grep -qF "$HALOW_ARTIFACTS_DIR" "$mc_out"
assert_success "a shell started by the child cannot resolve the removed helper name, even with such a file present in the artifacts directory" grep -qx "CHILD_DOES_NOT_RESOLVE_HELPER" "$mc_out"
assert_eq "$_path_before" "$PATH" "the PATH of the calling shell is untouched"
# Static check on the launcher's own code (comments removed): no PATH assignment or
# prefix, and no reference to the removed helper program.
hc_code="$(sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#[[:space:]].*$//' "$HALOW_LIB_DIR/hostapd_config.sh" 2>/dev/null || true)"
assert_success "precondition: the launcher source was read" test -n "$hc_code"
assert_failure "hostapd_config.sh code does not assign or prefix PATH" grep -qE '(^|[[:space:];])(export[[:space:]]+)?PATH=' <<< "$hc_code"
assert_failure "hostapd_config.sh code does not refer to the removed helper program" grep -qi 'morse_cli' <<< "$hc_code"
# The launch is exactly: "$bin" -f "$log" "$conf" &  with no variable assignment of any kind
# in front of it (no PATH, LD_PRELOAD, LD_LIBRARY_PATH or other environment prefix).
launch_lines="$(grep -E -e '"\$bin"' <<< "$hc_code" | grep -E -e '-f "\$log"' || true)"
assert_eq "1" "$(grep -c . <<< "$launch_lines")" "there is exactly one line that launches hostapd_s1g"
assert_eq '"$bin" -f "$log" "$conf" &' "$(sed -E 's/^[[:space:]]+//' <<< "$launch_lines")" "the launch line is exactly the program, its log option, its log file and its configuration, in the background, with no environment prefix"
kill "$HALOW_LAST_STARTED_PID" 2>/dev/null; wait "$HALOW_LAST_STARTED_PID" 2>/dev/null || true
halow_own_clear "hostapd_process"; rm -f -- "$HALOW_STATE_DIR/hostapd_s1g.pid"
halow_test_teardown

echo "== test_hostapd_config: halow_hostapd_pre_start_check — own_mark failure fails closed (a code review found this exact failure boundary, present in production code since the ownership-first redesign, had zero test coverage, unlike its dnsmasq equivalent) =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
eval "$(declare -f halow_own_mark | sed '1s/halow_own_mark/_real_own_mark_for_hostapd_partial_start_test/')"
halow_own_mark() {
    [ "$1" = "hostapd_process" ] && return 1
    _real_own_mark_for_hostapd_partial_start_test "$@"
}
assert_failure "halow_hostapd_pre_start_check fails closed when the hostapd_process ownership marker cannot be recorded" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "no hostapd_process ownership is left after the marker-write failure" halow_own_check "hostapd_process"
unset -f halow_own_mark _real_own_mark_for_hostapd_partial_start_test
halow_test_teardown

echo "== test_hostapd_config: halow_start_hostapd — genuine partial-start: the executable itself fails to launch at all; the caller's own rollback fully recovers (hostapd's own mirror of dnsmasq's equivalent test) =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"
nonexistent_bin="$HALOW_TEST_TMP/no-such-hostapd-binary-$$"

assert_success "halow_hostapd_pre_start_check succeeds against a clean state" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "halow_start_hostapd reports failure when the executable itself fails to launch (exec failure)" \
    halow_start_hostapd "$nonexistent_bin" "$hlog" "$hconf"
assert_success "lifecycle ownership was already recorded before the config was even written (established ahead of any mutation, by the pre-start check)" \
    halow_own_check "hostapd_process"
assert_file_exists "$hconf" "the config WAS written (the failure happens after that point) -- an orphan the caller's own rollback must still find"
assert_file_absent "$hpidfile" "no pid file was ever written, since the process never stayed alive"

halow_stop_hostapd >"$HALOW_TEST_TMP/recover_hostapd_launch_fail.log" 2>&1
assert_failure "the caller's own rollback (halow_stop_hostapd), using the identity-scan fallback (no pid file existed), fully recovers from this orphaned config" \
    halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the orphaned config is removed by the caller's own rollback"

rm -f -- "$hconf" "$hpidfile" "$hlog"
halow_test_teardown

echo "== test_hostapd_config: halow_start_hostapd — genuine partial-start: process launches but its own pid file cannot be written; a live, untracked-by-file orphan is still found and stopped by rollback's scan fallback (hostapd's own mirror of dnsmasq's equivalent test) =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"
mkdir -p "$hpidfile"   # the pid file's own path is occupied by a directory, so `echo ... > "$hpidfile"` fails
hbin2="$HALOW_TEST_TMP/fake_hostapd_pidfile_fail.sh"
hbin2_pid_tracker="$HALOW_TEST_TMP/fake_hostapd_real_pid"
# This failure path returns before halow_start_hostapd itself ever sets
# HALOW_LAST_STARTED_PID (that variable is only set on full success, unlike dnsmasq's
# own separate pid-tracker mechanism) -- the fake binary below self-reports its own real
# pid via $$ instead (valid here since it is genuinely exec'd as its own process by
# "$bin" ... &, not a backgrounded shell function, where $$ would stay pinned to the
# original shell). It also self-renames its own comm to exactly "hostapd_s1g" via the
# standard /proc/self/comm mechanism (and never execs into anything else afterward, which
# would reset it) -- a plain shebang script otherwise reports its own INTERPRETER's name
# in comm (e.g. "bash"), never the script's own filename, which the real,
# completely-unstubbed halow_stop_hostapd used for recovery below requires to exactly
# match "hostapd_s1g" before it can find and stop this orphaned process at all.
cat > "$hbin2" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$hbin2_pid_tracker"
echo -n hostapd_s1g > /proc/self/comm 2>/dev/null || true
sleep 20
EOF
chmod +x "$hbin2"

assert_success "halow_hostapd_pre_start_check succeeds against a clean state" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "halow_start_hostapd reports failure when its own pid file cannot be written" \
    halow_start_hostapd "$hbin2" "$hlog" "$hconf"
assert_success "lifecycle ownership remains recorded, so the caller's own rollback can find this orphan" halow_own_check "hostapd_process"
started_pid="$(cat "$hbin2_pid_tracker" 2>/dev/null)"
assert_success "the hostapd process launched successfully and is genuinely alive, even though its own pid file write failed (a live, untracked-by-file orphan)" \
    kill -0 "$started_pid"

rmdir "$hpidfile" 2>/dev/null || true   # restore the pid-file path to a normal, non-existent state for the recovery pass below
halow_stop_hostapd >"$HALOW_TEST_TMP/recover_hostapd_pidfile_fail.log" 2>&1
assert_failure "the live orphaned process is found via the identity-scan fallback (no valid pid file ever existed) and ownership is fully cleared" \
    halow_own_check "hostapd_process"
assert_failure "the orphaned hostapd process is confirmed stopped by the recovery teardown" \
    kill -0 "$started_pid"

rm -rf -- "$hconf" "$hpidfile" "$hlog"
halow_test_teardown

echo "== test_hostapd_config: halow_hostapd_pre_start_check — refuses to start unless the prior state is POSITIVELY confirmed absent =="
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"
: > "$hconf"

assert_success "a clean state allows starting, and marks ownership" halow_hostapd_pre_start_check "$hconf"
assert_success "ownership was marked" halow_own_check "hostapd_process"
halow_own_clear "hostapd_process"

# --- An existing pid file naming a positively-matching, alive process: BLOCK starting a
# replacement -- "already running" is refused, not silently treated as fine to duplicate. ---
( sleep 30 ) & already_running_pid=$!
echo "$already_running_pid" > "$hpidfile"
halow_hostapd_identity_matches() { [ "$1" = "$already_running_pid" ] && return 0 || return 1; }
assert_failure "pre-start check refuses to start a second instance when one already matches this package's own identity" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "ownership is NOT marked when refused" halow_own_check "hostapd_process"
unset -f halow_hostapd_identity_matches
kill "$already_running_pid" 2>/dev/null; wait "$already_running_pid" 2>/dev/null || true
rm -f "$hpidfile"

# --- An existing pid file naming a pid whose identity is UNREADABLE: BLOCK starting --
# "not positively confirmed running" is never itself permission to start another. ---
( sleep 30 ) & unk_pid=$!
echo "$unk_pid" > "$hpidfile"
halow_hostapd_identity_matches() { [ "$1" = "$unk_pid" ] && return 2 || return 1; }
assert_failure "pre-start check refuses to start when the existing pid's own identity is unreadable (unknown)" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "ownership is NOT marked when refused" halow_own_check "hostapd_process"
unset -f halow_hostapd_identity_matches
kill "$unk_pid" 2>/dev/null; wait "$unk_pid" 2>/dev/null || true
rm -f "$hpidfile"

# --- A missing/malformed pid file triggers the strict scan -- an ambiguous scan result
# also BLOCKS starting. ---
printf 'not-a-pid\n' > "$hpidfile"
halow_find_hostapd_by_identity() { return 2; }
assert_failure "pre-start check refuses to start when a missing/malformed pid file's own fallback scan is ambiguous" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "ownership is NOT marked when refused" halow_own_check "hostapd_process"
unset -f halow_find_hostapd_by_identity
rm -f "$hpidfile"

# --- A missing pid file with a clean (confirmed-absent) scan: starting IS allowed, and
# ownership is marked. ---
halow_find_hostapd_by_identity() { return 1; }
assert_success "pre-start check allows starting when a missing pid file's own fallback scan confirms absence" \
    halow_hostapd_pre_start_check "$hconf"
assert_success "ownership is marked" halow_own_check "hostapd_process"
unset -f halow_find_hostapd_by_identity
halow_own_clear "hostapd_process"

# --- A recorded pid that is DEAD, but the mandatory secondary scan finds this package's
# own process genuinely alive elsewhere under a different pid: BLOCK starting a second
# instance -- a dead recorded pid must never, by itself, be read as "confirmed absent"
# permission to start, when the scan it is now required to trigger finds a real, live
# instance. ---
echo "999999" > "$hpidfile"   # never alive -- identity_matches always resolves this to 3 (dead)
( sleep 30 ) & dead_case_live_pid=$!
halow_hostapd_identity_matches() { [ "$1" = "999999" ] && return 3; [ "$1" = "$dead_case_live_pid" ] && return 0; return 1; }
halow_find_hostapd_by_identity() { printf '%s' "$dead_case_live_pid"; return 0; }
assert_failure "pre-start check refuses to start when a dead recorded pid's own mandatory secondary scan finds a real instance alive elsewhere" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "ownership is NOT marked when refused" halow_own_check "hostapd_process"
unset -f halow_hostapd_identity_matches halow_find_hostapd_by_identity
kill "$dead_case_live_pid" 2>/dev/null; wait "$dead_case_live_pid" 2>/dev/null || true
rm -f "$hpidfile"

# --- A recorded pid that is DEAD, but the mandatory secondary scan is itself UNKNOWN
# (an unreadable same-name candidate found): BLOCK starting -- "not positively confirmed
# running" is never itself permission to start another, even when the one thing that IS
# known is that the originally recorded pid specifically is dead. ---
echo "999999" > "$hpidfile"
halow_hostapd_identity_matches() { return 3; }
halow_find_hostapd_by_identity() { return 3; }
assert_failure "pre-start check refuses to start when a dead recorded pid's own mandatory secondary scan is itself unknown/unsafe" \
    halow_hostapd_pre_start_check "$hconf"
assert_failure "ownership is NOT marked when refused" halow_own_check "hostapd_process"
unset -f halow_hostapd_identity_matches halow_find_hostapd_by_identity
rm -f "$hpidfile"

halow_test_teardown

echo "== test_hostapd_config: halow_stop_hostapd — the full outcome matrix, including the mandatory fresh full scan after a kill =="
# Throughout this section, halow_hostapd_identity_matches and
# halow_find_hostapd_by_identity are stubbed DYNAMICALLY (checking the real, current
# `kill -0` state of specific, known test pids) rather than via comm/cmdline stubs --
# comm/cmdline stubs apply globally to EVERY process the real /proc scan would examine,
# which would make the scan's own post-kill behaviour meaningless once more than one
# process exists on the test host. A dynamic stub tied to actual process liveness lets
# the post-kill full scan (which this change newly requires) behave realistically.
halow_test_setup
hconf="$HALOW_STATE_DIR/hostapd_s1g.conf"
hlog="$HALOW_STATE_DIR/hostapd_s1g.log"
hpidfile="$HALOW_STATE_DIR/hostapd_s1g.pid"

# See the identical note earlier in this file: halow_test_setup only re-sources the real
# production libs ONCE, at the top of this setup/teardown pair -- `unset -f` on either
# shared helper below would PERMANENTLY DELETE it for every later scenario in this
# section. The already-dead-pid scenario below genuinely needs the REAL
# halow_hostapd_identity_matches (its own early `kill -0` check is what must prove
# CONFIRMED ABSENT); real definitions are saved once and restored on demand instead of
# ever being deleted.
eval "$(declare -f halow_hostapd_identity_matches | sed '1s/halow_hostapd_identity_matches/_real_hostapd_identity_matches_for_test/')"
eval "$(declare -f halow_find_hostapd_by_identity | sed '1s/halow_find_hostapd_by_identity/_real_find_hostapd_by_identity_for_test/')"
_restore_real_hostapd_identity_fns() {
    eval "$(declare -f _real_hostapd_identity_matches_for_test | sed '1s/_real_hostapd_identity_matches_for_test/halow_hostapd_identity_matches/')"
    eval "$(declare -f _real_find_hostapd_by_identity_for_test | sed '1s/_real_find_hostapd_by_identity_for_test/halow_find_hostapd_by_identity/')"
}

# --- No ownership at all: a safe no-op. ---
assert_success "halow_stop_hostapd is a safe no-op when nothing is owned" halow_stop_hostapd

# --- Owned, pid file present, process genuinely stops, AND the mandatory post-kill full
# scan independently confirms no instance remains anywhere: files removed, ownership
# cleared. The scan stub below dynamically reflects owned_pid's own real liveness, so the
# post-kill scan only reports "confirmed absent" once the real `kill` has actually taken
# effect -- this is not merely a re-check of the one pid just signalled. ---
: > "$hconf"; : > "$hlog"
( sleep 30 ) &
owned_pid=$!
echo "$owned_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$owned_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$owned_pid" 2>/dev/null && { printf '%s' "$owned_pid"; return 0; }; return 1; }
halow_stop_hostapd
assert_failure "hostapd_process ownership is cleared after a genuinely stopped process, confirmed by a fresh, complete scan" \
    halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the password-bearing config is removed after confirmed stop"
assert_file_absent "$hlog" "the log is removed after confirmed stop"
assert_file_absent "$hpidfile" "the pid file is removed after confirmed stop"
assert_failure "the stopped process is confirmed gone" kill -0 "$owned_pid"
_restore_real_hostapd_identity_fns

# --- Owned, pid file present, process genuinely stops but only ~3.5s after being
# signalled (past the old, single fixed one-second check this change's own independent
# code review found too short) -- confirmed absent and cleaned up correctly once
# the retrying post-kill scan gives it enough time, not prematurely reported as "still
# alive"/stuck. The process below genuinely traps SIGTERM and deliberately delays its own
# exit by ~2.5s past the moment it actually receives the signal (checked via a 1s-period
# foreground loop, not `exec`, since `exec` would discard the trap handler entirely). ---
: > "$hconf"; : > "$hlog"
( trap 'sleep 2.5; exit 0' TERM; while :; do sleep 1; done ) &
slow_pid=$!
echo "$slow_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$slow_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$slow_pid" 2>/dev/null && { printf '%s' "$slow_pid"; return 0; }; return 1; }
_slow_stop_start=$(date +%s)
halow_stop_hostapd
_slow_stop_elapsed=$(( $(date +%s) - _slow_stop_start ))
assert_failure "hostapd_process ownership is cleared for a process that takes several seconds (not one) to actually exit after being signalled" \
    halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the config is removed once the slow-to-exit process is eventually confirmed gone"
assert_file_absent "$hpidfile" "the pid file is removed once the slow-to-exit process is eventually confirmed gone"
if [ "$_slow_stop_elapsed" -ge 2 ]; then
    echo "  ok: the retry loop genuinely waited past the old, too-short one-second window (${_slow_stop_elapsed}s elapsed) rather than this test coincidentally passing within it"
else
    echo "  FAIL: halow_stop_hostapd returned in only ${_slow_stop_elapsed}s -- too fast to have actually retried past the old one-second window"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
_restore_real_hostapd_identity_fns

# --- Owned, pid file present, the process IS stopped, but the mandatory post-kill full
# scan finds ANOTHER live candidate still matching this package's own identity: this is
# NOT yet resolved -- files are left in place, ownership is kept. This is the scenario a
# simple "re-check only the one pid just killed" design would have missed entirely. ---
: > "$hconf"; : > "$hlog"
( sleep 30 ) & stoppable_pid=$!
( sleep 30 ) & second_instance_pid=$!
echo "$stoppable_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$stoppable_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$second_instance_pid" 2>/dev/null && { printf '%s' "$second_instance_pid"; return 0; }; return 1; }
halow_stop_hostapd
assert_failure "the recorded pid was genuinely stopped" kill -0 "$stoppable_pid"
assert_success "ownership is kept -- the post-kill full scan found a second, still-live candidate the pid file alone never named" \
    halow_own_check "hostapd_process"
assert_file_exists "$hconf" "the config is NOT removed while a second candidate is still unresolved"
_restore_real_hostapd_identity_fns
kill "$second_instance_pid" 2>/dev/null; wait "$stoppable_pid" "$second_instance_pid" 2>/dev/null || true
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- Owned, pid file names a stale pid reused by an unrelated, still-alive process:
# halow_hostapd_determine_outcome's own mandatory secondary scan resolves this (see the
# dedicated determine_outcome tests, above, for the full matrix) -- here, the scan finds
# nothing, so the overall effect is a confirmed-absent cleanup; the unrelated process
# itself is never touched. ---
: > "$hconf"; : > "$hlog"
( sleep 30 ) &
unrelated_pid=$!
echo "$unrelated_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$unrelated_pid" ] && return 1; return 1; }
halow_find_hostapd_by_identity() { return 1; }
halow_stop_hostapd
assert_success "the unrelated process at the stale recorded pid is still alive (never signalled)" kill -0 "$unrelated_pid"
assert_failure "ownership is cleared -- the mismatch's own secondary scan confirmed this package's own instance is genuinely absent" \
    halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the config is removed once the mismatch's own secondary scan confirms absence"
_restore_real_hostapd_identity_fns
kill "$unrelated_pid" 2>/dev/null; wait "$unrelated_pid" 2>/dev/null || true
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- Owned, pid file names a pid whose identity is unknown (cmdline unreadable): never
# signalled, ownership kept, files left in place. ---
: > "$hconf"; : > "$hlog"
( sleep 30 ) &
unknown_pid=$!
echo "$unknown_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$unknown_pid" ] && return 2; return 1; }
halow_stop_hostapd
assert_success "the unknown-identity process is still alive after halow_stop_hostapd (never signalled)" kill -0 "$unknown_pid"
assert_success "ownership is kept when identity cannot be positively confirmed" halow_own_check "hostapd_process"
kill "$unknown_pid" 2>/dev/null; wait "$unknown_pid" 2>/dev/null || true
_restore_real_hostapd_identity_fns
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- Owned, pid file names an already-dead pid: this alone proves only that THAT pid is
# gone, never that no instance of this package's own process is running anywhere else --
# fixed during development: an earlier version treated a dead recorded pid as immediate,
# terminal confirmed_absent, skipping the mandatory secondary scan entirely. Deliberately
# uses the REAL, just-restored halow_hostapd_identity_matches AND
# halow_find_hostapd_by_identity (not stubs), so the real mandatory secondary scan
# genuinely runs and genuinely finds nothing on this real test host before confirmed_absent
# is concluded and cleanup proceeds. ---
: > "$hconf"; : > "$hlog"
( sleep 0.1 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
echo "$dead_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_stop_hostapd
assert_failure "ownership is cleared when the recorded pid is confirmed dead AND the mandatory secondary scan independently confirms absence" halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the config is removed once the dead recorded pid's own mandatory secondary scan confirms absence"
assert_file_absent "$hpidfile" "the pid file is removed once the dead recorded pid's own mandatory secondary scan confirms absence"

# --- Owned, pid file missing/malformed, identity scan finds zero candidates: confirmed
# absent, files cleaned up. ---
: > "$hconf"; : > "$hlog"
halow_own_mark "hostapd_process"
halow_find_hostapd_by_identity() { return 1; }
halow_stop_hostapd
assert_failure "ownership is cleared when the pid file is missing and a full identity scan confirms absence" halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the config is removed when absence is confirmed via the identity scan"
unset -f halow_find_hostapd_by_identity

# --- Owned, pid file missing, identity scan finds more than one candidate: ambiguous,
# ownership kept, files left in place. ---
: > "$hconf"; : > "$hlog"
halow_own_mark "hostapd_process"
halow_find_hostapd_by_identity() { return 2; }
halow_stop_hostapd
assert_success "ownership is kept when the pid file is missing and more than one process matches this package's own identity" halow_own_check "hostapd_process"
assert_file_exists "$hconf" "the config is NOT removed while the result is ambiguous"
unset -f halow_find_hostapd_by_identity
halow_own_clear "hostapd_process"
rm -f -- "$hconf" "$hlog"

# --- Owned, pid file missing, identity scan itself is unknown/unsafe (an unreadable
# cmdline was found during the scan): ownership kept, files left in place -- never
# conflated with "zero matches, confirmed absent". ---
: > "$hconf"; : > "$hlog"
halow_own_mark "hostapd_process"
halow_find_hostapd_by_identity() { return 3; }
halow_stop_hostapd
assert_success "ownership is kept when the identity scan itself is unknown/unsafe" halow_own_check "hostapd_process"
assert_file_exists "$hconf" "the config is NOT removed while the scan result is unknown/unsafe"
unset -f halow_find_hostapd_by_identity
halow_own_clear "hostapd_process"
rm -f -- "$hconf" "$hlog"

# --- Owned, correctly identified process refuses to stop: ownership kept, files left in
# place -- never silently treated as cleaned up. Uses a process that genuinely traps and
# ignores SIGTERM (not merely a stub that claims "match" for every pid, which the
# mandatory post-kill FULL scan would apply to every other live process on the real test
# host too, making "ambiguous" the accidental, host-process-count-dependent reason
# ownership stays kept rather than a deterministic proof that THIS process specifically
# did not stop -- a false-positive-prone design this change's own adversarial pass must
# not repeat). Both identity functions are stubbed pid-specifically and dynamically (via
# a real `kill -0` check), so the test's own pass/fail genuinely tracks this one target
# process's real liveness, not an unrelated side effect of how many processes happen to
# be running on the host. ---
: > "$hconf"; : > "$hlog"
( trap '' TERM; exec sleep 30 ) &
wontstop_pid=$!
echo "$wontstop_pid" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "$wontstop_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$wontstop_pid" 2>/dev/null && { printf '%s' "$wontstop_pid"; return 0; }; return 1; }
halow_stop_hostapd
assert_success "ownership is kept when the identified hostapd_s1g process does not actually stop" halow_own_check "hostapd_process"
assert_success "the process that refuses to stop is confirmed still genuinely alive (SIGTERM-immune, not a stub artifact)" kill -0 "$wontstop_pid"
assert_file_exists "$hconf" "the config is NOT removed while the process is reported as not stopped"
_restore_real_hostapd_identity_fns
kill -KILL "$wontstop_pid" 2>/dev/null; wait "$wontstop_pid" 2>/dev/null || true
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- Failed file removal (`rm` itself fails): the files cannot be deleted even though
# the process is confirmed gone -- ownership must be KEPT, reported as a residual, never
# cleared. Tested independently for the pid file, the config, and the log. The recorded
# pid is dead (identity_matches returns 3), which this change's own correction now routes
# through the mandatory secondary scan rather than treating as directly, terminally
# confirmed_absent -- halow_find_hostapd_by_identity is therefore explicitly stubbed here
# too (not left to whatever a prior scenario's own stub/restore state happened to be),
# confirming that same scan finds nothing, so the test is deterministic regardless. ---
for _target_label in "hostapd_s1g.pid" "hostapd_s1g.conf" "hostapd_s1g.log"; do
    : > "$hconf"; : > "$hlog"
    echo "123456" > "$hpidfile"
    halow_own_mark "hostapd_process"
    halow_hostapd_identity_matches() { return 3; }
    halow_find_hostapd_by_identity() { return 1; }
    eval "rm() { case \"\$*\" in *${_target_label}*) return 1 ;; *) command rm \"\$@\" ;; esac; }"
    halow_stop_hostapd >"$HALOW_TEST_TMP/cleanup_fail.log" 2>&1
    unset -f rm
    assert_success "ownership is kept when $_target_label specifically cannot be removed" halow_own_check "hostapd_process"
    halow_own_clear "hostapd_process"
    rm -f -- "$hpidfile" "$hconf" "$hlog"
done
_restore_real_hostapd_identity_fns

# The config file specifically must log a distinct CRITICAL error (it is the
# password-bearing one) -- re-run that one case alone to check for it.
: > "$hconf"; : > "$hlog"
echo "123456" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { return 3; }
halow_find_hostapd_by_identity() { return 1; }
rm() { case "$*" in *hostapd_s1g.conf*) return 1 ;; *) command rm "$@" ;; esac; }
halow_stop_hostapd >"$HALOW_TEST_TMP/cleanup_fail.log" 2>&1
unset -f rm
grep -q "CRITICAL" "$HALOW_TEST_TMP/cleanup_fail.log" && echo "  ok: a distinct CRITICAL error is logged specifically for an unremovable password-bearing config" || { echo "  FAIL: no CRITICAL error logged for an unremovable password-bearing config"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)); }
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile" "$hconf" "$hlog"
_restore_real_hostapd_identity_fns

# --- Broken-symlink regression: a plain `[ -e <path> ]` reports FALSE for a dangling
# symlink (the target doesn't exist, so `-e` says "doesn't exist"), which could wrongly
# be read as "confirmed removed" even though a symlink entry still genuinely occupies
# that path. halow_path_still_present (used throughout halow_cleanup_hostapd_files)
# must correctly treat a dangling symlink left in place of the config as still present. ---
: > "$hconf"; : > "$hlog"
echo "123456" > "$hpidfile"
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { return 3; }
halow_find_hostapd_by_identity() { return 1; }
rm() {
    case "$*" in
        *hostapd_s1g.conf*)
            # Simulate a removal that leaves a DANGLING SYMLINK behind instead of
            # genuinely removing the path -- plain `[ -e ]` would call this "absent".
            command rm -f -- "$hconf"
            ln -s "/nonexistent-target-$$" "$hconf"
            return 0
            ;;
        *) command rm "$@" ;;
    esac
}
halow_stop_hostapd >/dev/null 2>&1
unset -f rm
assert_success "a dangling symlink left in place of the removed config is correctly detected as still present (ownership kept)" \
    halow_own_check "hostapd_process"
assert_success "the dangling symlink itself is still there, confirming this test's own simulation took effect" \
    bash -c "[ -L '$hconf' ]"
halow_own_clear "hostapd_process"
rm -f -- "$hpidfile" "$hconf" "$hlog"
_restore_real_hostapd_identity_fns

# --- Owned, pid file names a DEAD pid, but the mandatory secondary scan finds this
# package's own process genuinely alive under a DIFFERENT pid: this must be treated as
# OWNED (that found pid becomes the target), and the existing kill-then-rescan logic must
# run against it -- files are not removed and ownership is not cleared merely because the
# ORIGINALLY recorded pid was dead; a live instance found by the scan is handled safely
# (signalled, then re-confirmed absent by a fresh scan) before any cleanup. This is the
# exact end-to-end scenario the "dead pid resolves directly to confirmed_absent, no scan
# needed" design this change corrects would have missed entirely -- it would have cleaned
# up and cleared ownership while a real instance of this package's own hostapd_s1g was
# still running. ---
: > "$hconf"; : > "$hlog"
echo "999999" > "$hpidfile"   # a pid that is never alive -- always resolves identity_matches to 3 (dead)
( sleep 30 ) & real_instance_pid=$!
halow_own_mark "hostapd_process"
halow_hostapd_identity_matches() { [ "$1" = "999999" ] && return 3; [ "$1" = "$real_instance_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$real_instance_pid" 2>/dev/null && { printf '%s' "$real_instance_pid"; return 0; }; return 1; }
halow_stop_hostapd >"$HALOW_TEST_TMP/dead_pid_scan_finds_live.log" 2>&1
assert_failure "the real instance found by the dead-pid's own mandatory secondary scan was genuinely signalled and stopped" \
    kill -0 "$real_instance_pid"
assert_failure "ownership is cleared once the scan-found real instance is itself confirmed stopped by a fresh, complete re-scan" \
    halow_own_check "hostapd_process"
assert_file_absent "$hconf" "the config is removed once the scan-found real instance is confirmed stopped"
assert_file_absent "$hpidfile" "the (originally dead-pid-naming) pid file is removed once cleanup completes"
_restore_real_hostapd_identity_fns
wait "$real_instance_pid" 2>/dev/null || true
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- Repeated cleanup: calling halow_stop_hostapd again after a successful cleanup is a
# safe no-op (nothing owned, nothing to do). ---
assert_success "a second halow_stop_hostapd call after successful cleanup is a safe no-op" halow_stop_hostapd

# --- No hostapd_process ownership marker at all, but a real, live process positively
# matches this package's own identity: a code review found this
# function used to return success IMMEDIATELY whenever ownership was not held, WITHOUT
# EVER running the identity scan below -- meaning this exact case was silently invisible,
# and halow_rollback's own aggregate ownership-key check has no key to notice it either,
# since nothing was ever marked owned. Fixed: the scan now always runs regardless of
# ownership-marker state; a positively-identified-but-unowned process must still never be
# signalled, adopted, or have its files touched, but this condition must now be reported
# as a genuine failure (not silent "nothing to do"), via this function's own return
# value. ---
: > "$hconf"; : > "$hlog"
( sleep 30 ) &
unowned_live_pid=$!
echo "$unowned_live_pid" > "$hpidfile"
halow_hostapd_identity_matches() { [ "$1" = "$unowned_live_pid" ] && { kill -0 "$1" 2>/dev/null && return 0 || return 3; }; return 1; }
halow_find_hostapd_by_identity() { kill -0 "$unowned_live_pid" 2>/dev/null && { printf '%s' "$unowned_live_pid"; return 0; }; return 1; }
assert_failure "halow_stop_hostapd reports a hard failure (not silent success) when a positively-matching process is found with NO hostapd_process ownership marker held" \
    halow_stop_hostapd
assert_success "the unowned, identity-matching process remains completely untouched -- never signalled" kill -0 "$unowned_live_pid"
assert_failure "no hostapd_process ownership is adopted for it" halow_own_check "hostapd_process"
assert_file_exists "$hconf" "its config is not touched/removed"
assert_file_exists "$hpidfile" "its pid file is not touched/removed"
_restore_real_hostapd_identity_fns
kill "$unowned_live_pid" 2>/dev/null; wait "$unowned_live_pid" 2>/dev/null || true
rm -f -- "$hpidfile" "$hconf" "$hlog"

# --- No hostapd_process ownership marker at all, and nothing matches either (the
# overwhelmingly common, totally normal case -- hostapd_s1g was simply never started this
# run): must remain a silent, harmless, successful no-op, with no behaviour change or
# added noise from the fix above. ---
assert_success "halow_stop_hostapd remains a safe, silent no-op when nothing is owned AND nothing matches (the normal case)" halow_stop_hostapd

unset -f _real_hostapd_identity_matches_for_test _real_find_hostapd_by_identity_for_test _restore_real_hostapd_identity_fns 2>/dev/null || true
halow_test_teardown
echo "test_hostapd_config: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
